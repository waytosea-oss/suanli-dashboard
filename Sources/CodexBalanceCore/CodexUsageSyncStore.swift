import Foundation

public final class CodexUsageSyncStore: @unchecked Sendable {
  public let syncRoot: URL?
  public let app: ToolID
  public let deviceID: CodexDeviceID
  public let deviceName: String
  public let hostName: String

  private let fileManager: FileManager
  private var didMigrateLegacy = false

  public init(
    syncRoot: URL? = nil,
    app: ToolID = .codex,
    deviceID: CodexDeviceID? = nil,
    deviceName: String? = nil,
    hostName: String? = nil,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.fileManager = fileManager
    self.app = app
    self.syncRoot = syncRoot ?? Self.resolveSyncRoot(fileManager: fileManager, environment: environment)
    self.hostName = hostName ?? Self.currentHostName()
    self.deviceID = deviceID ?? Self.resolveDeviceID(hostName: self.hostName, environment: environment)
    self.deviceName = deviceName
      ?? environment["CODEX_BALANCE_DEVICE_NAME"]
      ?? self.deviceID.displayName
  }

  public func makeSnapshot(from stats: TokenStats, now: Date = Date()) -> CodexDeviceTokenUsage {
    CodexDeviceTokenUsage(
      app: app,
      deviceID: deviceID,
      deviceName: deviceName,
      hostName: hostName,
      updatedAt: now,
      todayTokens: stats.todayTokens,
      monthTokens: stats.monthTokens,
      sampleCount: stats.sampleCount,
      daily: stats.daily,
      monthly: stats.monthly
    )
  }

  public func persistAndReadSnapshots(
    from stats: TokenStats,
    now: Date = Date()
  ) -> [CodexDeviceTokenUsage] {
    let localSnapshot = makeSnapshot(from: stats, now: now)
    try? write(localSnapshot)
    return readSnapshots(including: localSnapshot)
  }

  public func write(_ snapshot: CodexDeviceTokenUsage) throws {
    guard let syncRoot else { return }
    try fileManager.createDirectory(at: syncRoot, withIntermediateDirectories: true)
    let data = try Self.encoder.encode(snapshot)
    try data.write(to: syncRoot.appendingPathComponent(snapshot.deviceID.fileName(for: snapshot.app)), options: [.atomic])
  }

  public func readSnapshots(including localSnapshot: CodexDeviceTokenUsage? = nil) -> [CodexDeviceTokenUsage] {
    migrateLegacyFilesIfNeeded()

    var snapshots: [CodexDeviceID: CodexDeviceTokenUsage] = [:]
    if let localSnapshot, localSnapshot.app == app {
      snapshots[localSnapshot.deviceID] = localSnapshot
    }

    guard let syncRoot else {
      return orderedSnapshots(snapshots)
    }

    let urls = (try? fileManager.contentsOfDirectory(
      at: syncRoot,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []

    for url in urls where url.pathExtension.lowercased() == "json" {
      guard
        let data = try? Data(contentsOf: url),
        let snapshot = try? Self.decoder.decode(CodexDeviceTokenUsage.self, from: data),
        snapshot.app == app
      else { continue }

      if let existing = snapshots[snapshot.deviceID],
         existing.updatedAt >= snapshot.updatedAt {
        continue
      }
      snapshots[snapshot.deviceID] = snapshot
    }

    return orderedSnapshots(snapshots)
  }

  /// 首次升级：把旧版 Codex 同步文件（APP安装包/算力码表/sync/<设备>.json，schemaVersion 1）
  /// 迁移为新目录下的 <设备>-codex.json。旧文件保留不删，之后只写新文件。
  private func migrateLegacyFilesIfNeeded() {
    guard !didMigrateLegacy, app == .codex, let syncRoot else { return }
    didMigrateLegacy = true

    let legacyRoots = [
      Self.legacySyncRoot(fileManager: fileManager),
      syncRoot
    ].compactMap { $0 }

    for legacyRoot in legacyRoots {
      for deviceID in CodexDeviceID.allCases {
        let legacyURL = legacyRoot.appendingPathComponent(deviceID.fileName)
        let migratedURL = syncRoot.appendingPathComponent(deviceID.fileName(for: .codex))
        guard fileManager.fileExists(atPath: legacyURL.path),
              !fileManager.fileExists(atPath: migratedURL.path),
              let data = try? Data(contentsOf: legacyURL),
              var snapshot = try? Self.decoder.decode(CodexDeviceTokenUsage.self, from: data)
        else { continue }

        snapshot.schemaVersion = 2
        snapshot.app = .codex
        try? write(snapshot)
      }
    }
  }

  private func orderedSnapshots(_ snapshots: [CodexDeviceID: CodexDeviceTokenUsage]) -> [CodexDeviceTokenUsage] {
    CodexDeviceID.allCases.compactMap { snapshots[$0] }
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }

  private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  private static func resolveSyncRoot(fileManager: FileManager, environment: [String: String]) -> URL? {
    if let override = environment["CODEX_BALANCE_SYNC_DIR"], !override.isEmpty {
      return URL(fileURLWithPath: override).standardizedFileURL
    }

    guard let cloudDocs = cloudDocsRoot(fileManager: fileManager) else { return nil }

    return cloudDocs
      .appendingPathComponent("算力码表")
      .appendingPathComponent("设备统计")
  }

  private static func legacySyncRoot(fileManager: FileManager) -> URL? {
    guard let cloudDocs = cloudDocsRoot(fileManager: fileManager) else { return nil }

    return cloudDocs
      .appendingPathComponent("APP安装包")
      .appendingPathComponent("算力码表")
      .appendingPathComponent("sync")
  }

  private static func cloudDocsRoot(fileManager: FileManager) -> URL? {
    let cloudDocs = fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library")
      .appendingPathComponent("Mobile Documents")
      .appendingPathComponent("com~apple~CloudDocs")
    guard fileManager.fileExists(atPath: cloudDocs.path) else { return nil }
    return cloudDocs
  }

  private static func resolveDeviceID(hostName: String, environment: [String: String]) -> CodexDeviceID {
    if let override = environment["CODEX_BALANCE_DEVICE_ID"],
       let id = parseDeviceID(override) {
      return id
    }

    let normalized = hostName.lowercased()
    if normalized.contains("macbook") || normalized.contains("book") || normalized.contains("mbp") {
      return .macBookPro
    }
    return .macStudio
  }

  private static func parseDeviceID(_ value: String) -> CodexDeviceID? {
    let normalized = value
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
      .replacingOccurrences(of: " ", with: "-")
    switch normalized {
    case "macbook-pro", "macbookpro", "mbp":
      return .macBookPro
    case "mac-studio", "macstudio", "studio":
      return .macStudio
    default:
      return CodexDeviceID(rawValue: normalized)
    }
  }

  private static func currentHostName() -> String {
    let processHost = ProcessInfo.processInfo.hostName
    if !processHost.isEmpty { return processHost }
    return Host.current().localizedName ?? "unknown-mac"
  }
}
