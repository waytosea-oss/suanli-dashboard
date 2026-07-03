import Foundation

public final class CodexUsageSyncStore: @unchecked Sendable {
  public let syncRoot: URL?
  public let app: ToolID
  public let deviceID: String
  public let deviceName: String
  public let hostName: String

  private let fileManager: FileManager
  private var didMigrateLegacy = false

  public init(
    syncRoot: URL? = nil,
    app: ToolID = .codex,
    deviceID: String? = nil,
    deviceName: String? = nil,
    hostName: String? = nil,
    fileManager: FileManager = .default,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.fileManager = fileManager
    self.app = app
    self.syncRoot = syncRoot ?? Self.resolveSyncRoot(fileManager: fileManager, environment: environment)
    self.hostName = hostName ?? Self.currentHostName()
    let computerName = Self.currentComputerName() ?? self.hostName
    let resolvedID = deviceID
      ?? environment["CODEX_BALANCE_DEVICE_ID"].map { DeviceIdentity.slug(from: $0) }
      ?? Self.legacyDeviceID(hostName: self.hostName, syncRoot: self.syncRoot, app: app, fileManager: fileManager)
      ?? DeviceIdentity.slug(from: computerName)
    self.deviceID = resolvedID
    // 显示名优先级：显式参数 > 环境变量 > 本机已有同步文件里的名字（保持两台机器图例稳定）> 电脑名
    self.deviceName = deviceName
      ?? environment["CODEX_BALANCE_DEVICE_NAME"]
      ?? Self.existingDeviceName(deviceID: resolvedID, syncRoot: self.syncRoot, app: app, fileManager: fileManager)
      ?? computerName
  }

  /// 老用户平滑升级：本机主机名匹配旧的两台设备命名时，沿用旧 deviceID，
  /// 这样历史 iCloud 文件（macbook-pro-*.json / mac-studio-*.json）继续归属本机。
  private static func legacyDeviceID(
    hostName: String,
    syncRoot: URL?,
    app: ToolID,
    fileManager: FileManager
  ) -> String? {
    guard let syncRoot else { return nil }
    let normalized = hostName.lowercased()
    let candidate: String
    if normalized.contains("macbook") || normalized.contains("book") || normalized.contains("mbp") {
      candidate = "macbook-pro"
    } else if normalized.contains("studio") {
      candidate = "mac-studio"
    } else {
      return nil
    }
    let file = syncRoot.appendingPathComponent(DeviceIdentity.fileName(deviceID: candidate, app: app))
    return fileManager.fileExists(atPath: file.path) ? candidate : nil
  }

  private static func existingDeviceName(
    deviceID: String,
    syncRoot: URL?,
    app: ToolID,
    fileManager: FileManager
  ) -> String? {
    guard let syncRoot else { return nil }
    let file = syncRoot.appendingPathComponent(DeviceIdentity.fileName(deviceID: deviceID, app: app))
    guard let data = try? Data(contentsOf: file),
          let snapshot = try? decoder.decode(CodexDeviceTokenUsage.self, from: data),
          !snapshot.deviceName.isEmpty
    else { return nil }
    return snapshot.deviceName
  }

  private static func currentComputerName() -> String? {
    Host.current().localizedName
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
    try data.write(
      to: syncRoot.appendingPathComponent(DeviceIdentity.fileName(deviceID: snapshot.deviceID, app: snapshot.app)),
      options: [.atomic]
    )
  }

  public func readSnapshots(including localSnapshot: CodexDeviceTokenUsage? = nil) -> [CodexDeviceTokenUsage] {
    migrateLegacyFilesIfNeeded()

    var snapshots: [String: CodexDeviceTokenUsage] = [:]
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
      for deviceID in ["macbook-pro", "mac-studio"] {
        let legacyURL = legacyRoot.appendingPathComponent("\(deviceID).json")
        let migratedURL = syncRoot.appendingPathComponent(DeviceIdentity.fileName(deviceID: deviceID, app: .codex))
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

  /// 本机排最前，其余按显示名排序（支持任意台数设备）
  private func orderedSnapshots(_ snapshots: [String: CodexDeviceTokenUsage]) -> [CodexDeviceTokenUsage] {
    snapshots.values.sorted { lhs, rhs in
      if lhs.deviceID == deviceID { return true }
      if rhs.deviceID == deviceID { return false }
      return lhs.deviceName.localizedStandardCompare(rhs.deviceName) == .orderedAscending
    }
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

  private static func currentHostName() -> String {
    let processHost = ProcessInfo.processInfo.hostName
    if !processHost.isEmpty { return processHost }
    return Host.current().localizedName ?? "unknown-mac"
  }
}
