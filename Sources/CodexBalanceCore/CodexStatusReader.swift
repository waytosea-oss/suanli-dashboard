import Foundation
#if canImport(Darwin)
import Darwin
#endif

private struct ParsedFileCache {
  var modified: Date
  var fileSize: Int
  var pendingScores: [TokenUsageCategory: Int]
  var pendingProjectName: String
  var pendingProjectPath: String
  var events: [RateLimitEvent]
}

private struct TokenStatsCache {
  var signature: String
  var dayKey: String
  var stats: TokenStats
}

private struct UsageKeywordRule {
  var bytes: [UInt8]
  var weight: Int

  init(_ keyword: String, _ weight: Int) {
    bytes = Array(keyword.utf8)
    self.weight = weight
  }
}

private let tokenCountNeedle = Array(#""type":"token_count""#.utf8)
private let developerRoleNeedle = Array(#""role":"developer""#.utf8)
private let systemRoleNeedle = Array(#""role":"system""#.utf8)
private let turnContextNeedle = Array(#""type":"turn_context""#.utf8)
private let sessionMetaNeedle = Array(#""type":"session_meta""#.utf8)
private let functionOutputNeedle = Array(#""type":"function_call_output""#.utf8)
private let cwdNeedle = Array(#""cwd""#.utf8)
private let userRoleNeedle = Array(#""role":"user""#.utf8)
private let assistantRoleNeedle = Array(#""role":"assistant""#.utf8)
private let userMessageNeedle = Array(#""type":"user_message""#.utf8)
private let functionCallNeedle = Array(#""type":"function_call""#.utf8)
private let presentationKeywordRules = [
  UsageKeywordRule("pptx", 10),
  UsageKeywordRule("powerpoint", 10),
  UsageKeywordRule("演示文稿", 10),
  UsageKeywordRule("幻灯片", 10),
  UsageKeywordRule("slide deck", 9),
  UsageKeywordRule("presentation deck", 9),
  UsageKeywordRule("slides", 7),
  UsageKeywordRule("slide", 5),
  UsageKeywordRule("presentations:", 7),
  UsageKeywordRule("presentations", 6),
  UsageKeywordRule("generate_deck", 7),
  UsageKeywordRule("powerpoint:", 7),
  UsageKeywordRule("ppt", 4)
]
private let imageKeywordRules = [
  UsageKeywordRule("imagegen", 10),
  UsageKeywordRule("生成图片", 9),
  UsageKeywordRule("做图", 9),
  UsageKeywordRule("图片", 5),
  UsageKeywordRule("图像", 5),
  UsageKeywordRule("海报", 5),
  UsageKeywordRule("插画", 5),
  UsageKeywordRule("视觉", 4),
  UsageKeywordRule("figma", 6),
  UsageKeywordRule("canva", 6),
  UsageKeywordRule("png", 3),
  UsageKeywordRule("jpg", 3)
]
private let documentKeywordRules = [
  UsageKeywordRule("docx", 10),
  UsageKeywordRule("word", 7),
  UsageKeywordRule("申请表", 9),
  UsageKeywordRule("文档", 5),
  UsageKeywordRule("表格", 5),
  UsageKeywordRule("填写", 4),
  UsageKeywordRule("documents", 6),
  UsageKeywordRule("render_docx", 8),
  UsageKeywordRule("xlsx", 7),
  UsageKeywordRule("spreadsheet", 6),
  UsageKeywordRule("excel", 6)
]
private let codingKeywordRules = [
  UsageKeywordRule("apply_patch", 10),
  UsageKeywordRule("swift test", 8),
  UsageKeywordRule("npm run", 7),
  UsageKeywordRule("package.swift", 6),
  UsageKeywordRule(".swift", 4),
  UsageKeywordRule(".jsx", 4),
  UsageKeywordRule(".tsx", 4),
  UsageKeywordRule("代码", 5),
  UsageKeywordRule("编程", 6),
  UsageKeywordRule("修复", 3),
  UsageKeywordRule("bug", 4),
  UsageKeywordRule("构建", 3),
  UsageKeywordRule("git diff", 5)
]
private let researchKeywordRules = [
  UsageKeywordRule("search_query", 8),
  UsageKeywordRule("web.run", 8),
  UsageKeywordRule("browse", 5),
  UsageKeywordRule("搜索", 5),
  UsageKeywordRule("调研", 6),
  UsageKeywordRule("引用", 4),
  UsageKeywordRule("citations", 5),
  UsageKeywordRule("sourceurl", 4),
  UsageKeywordRule("联网", 4)
]

public final class CodexStatusReader: @unchecked Sendable {
  private let fileManager: FileManager
  private let codexHome: URL
  private let sessionRoots: [URL]
  private let maxSessionFiles: Int
  private let liveRateLimitSource: CodexAppServerRateLimitSource?
  private let accountUsageSource: CodexProfileUsageSource?
  private let usageSyncStore: CodexUsageSyncStore?
  private var eventCache: [String: ParsedFileCache] = [:]
  private var tokenStatsCache: TokenStatsCache?
  private var workspaceRootLabels: [String: String] = [:]

  public init(
    codexHome: URL? = nil,
    sessionsRoot: URL? = nil,
    maxSessionFiles: Int = 1000,
    preferLiveStatus: Bool = true,
    fileManager: FileManager = .default
  ) {
    let environmentHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
      .flatMap { URL(fileURLWithPath: $0).standardizedFileURL }
    let defaultHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    let resolvedHome = codexHome
      ?? environmentHome
      ?? defaultHome

    self.fileManager = fileManager
    if let sessionsRoot {
      self.codexHome = resolvedHome
      self.sessionRoots = [sessionsRoot]
    } else if codexHome != nil || environmentHome != nil {
      self.codexHome = resolvedHome
      self.sessionRoots = [resolvedHome.appendingPathComponent("sessions")]
    } else {
      self.codexHome = resolvedHome
      let discoveredRoots = Self.discoverSessionRoots(fileManager: fileManager)
      self.sessionRoots = discoveredRoots.isEmpty ? [resolvedHome.appendingPathComponent("sessions")] : discoveredRoots
    }
    self.maxSessionFiles = maxSessionFiles
    self.liveRateLimitSource = preferLiveStatus && codexHome == nil && sessionsRoot == nil
      ? CodexAppServerRateLimitSource()
      : nil
    self.accountUsageSource = preferLiveStatus && sessionsRoot == nil
      ? CodexProfileUsageSource(codexHome: resolvedHome, fileManager: fileManager)
      : nil
    self.usageSyncStore = preferLiveStatus && codexHome == nil && sessionsRoot == nil
      ? CodexUsageSyncStore(fileManager: fileManager)
      : nil
  }

  public func read(now: Date = Date()) throws -> CodexStatus {
    workspaceRootLabels = loadWorkspaceRootLabels()
    let files = listJSONLFiles()
    let activePaths = Set(files.map(\.path))
    eventCache = eventCache.filter { activePaths.contains($0.key) }
    let events = files
      .flatMap { parseEvents(in: $0, now: now) }
      .sorted { $0.timestamp < $1.timestamp }
    let liveEvents = liveRateLimitSource?.cachedRateLimitEvents(now: now) ?? []
    liveRateLimitSource?.refreshInBackground()
    let accountUsage = accountUsageSource?.cachedUsage(now: now)
    accountUsageSource?.refreshInBackground(now: now)
    let combinedEvents = (events + liveEvents).sorted { $0.timestamp < $1.timestamp }

    let latestByLimit = Self.latestByLimit(from: combinedEvents)

    let limits = latestByLimit.values.sorted {
      let lhsUsed = $0.primary?.usedPercent ?? 0
      let rhsUsed = $1.primary?.usedPercent ?? 0
      if lhsUsed == rhsUsed { return $0.timestamp > $1.timestamp }
      return lhsUsed > rhsUsed
    }
    let main = limits.first { $0.limitID == "codex" } ?? limits.first
    let trend = main.map { selected in
      combinedEvents.filter { $0.limitID == selected.limitID }.suffix(48)
    } ?? []
    let recentEvents = combinedEvents
    var tokenStats = buildCachedTokenStats(from: events, now: now)
    tokenStats.accountUsage = accountUsage
    tokenStats.deviceUsage = usageSyncStore?.persistAndReadSnapshots(from: tokenStats, now: now) ?? []

    return CodexStatus(
      generatedAt: now,
      codexHome: codexHome.path,
      sessionsRoot: sessionRoots.map(\.path).joined(separator: " | "),
      scannedFiles: files.count,
      eventCount: events.count,
      main: main,
      limits: limits,
      trend: Array(trend),
      tokenStats: tokenStats,
      recentEvents: Array(recentEvents.suffix(18).reversed())
    )
  }

  public func readFast(
    now: Date = Date(),
    fileLimit: Int = 8,
    tailBytes: Int = 768 * 1024
  ) throws -> CodexStatus {
    workspaceRootLabels = loadWorkspaceRootLabels()
    let files = Array(listJSONLFiles().prefix(fileLimit))
    let events = files
      .flatMap { parseRecentEvents(in: $0, now: now, tailBytes: tailBytes) }
      .sorted { $0.timestamp < $1.timestamp }
    let liveEvents = liveRateLimitSource?.freshRateLimitEvents(now: now) ?? []
    let accountUsage = accountUsageSource?.cachedUsage(now: now)
    accountUsageSource?.refreshInBackground(now: now)
    let combinedEvents = (events + liveEvents).sorted { $0.timestamp < $1.timestamp }

    let latestByLimit = Self.latestByLimit(from: combinedEvents)
    let limits = latestByLimit.values.sorted {
      let lhsUsed = $0.primary?.usedPercent ?? 0
      let rhsUsed = $1.primary?.usedPercent ?? 0
      if lhsUsed == rhsUsed { return $0.timestamp > $1.timestamp }
      return lhsUsed > rhsUsed
    }
    let main = limits.first { $0.limitID == "codex" } ?? limits.first
    let trend = main.map { selected in
      combinedEvents.filter { $0.limitID == selected.limitID }.suffix(48)
    } ?? []
    var tokenStats = TokenStats()
    tokenStats.accountUsage = accountUsage
    tokenStats.deviceUsage = usageSyncStore?.readSnapshots() ?? []

    return CodexStatus(
      generatedAt: now,
      codexHome: codexHome.path,
      sessionsRoot: sessionRoots.map(\.path).joined(separator: " | "),
      scannedFiles: files.count,
      eventCount: events.count,
      main: main,
      limits: limits,
      trend: Array(trend),
      tokenStats: tokenStats,
      recentEvents: Array(combinedEvents.suffix(18).reversed())
    )
  }

  static func latestByLimit(from events: [RateLimitEvent]) -> [String: RateLimitEvent] {
    var latestByLimit: [String: RateLimitEvent] = [:]
    for event in events {
      if let existing = latestByLimit[event.limitID],
         shouldKeep(existing: existing, over: event) {
        continue
      }
      latestByLimit[event.limitID] = event
    }
    return latestByLimit
  }

  private static func shouldKeep(existing: RateLimitEvent, over candidate: RateLimitEvent) -> Bool {
    let existingIsLive = existing.sourceName == "Codex app-server"
    let candidateIsLive = candidate.sourceName == "Codex app-server"
    let freshStatusGrace: TimeInterval = 120

    if existing.timestamp == candidate.timestamp {
      return !existingIsLive || candidateIsLive
    }

    if existing.timestamp > candidate.timestamp {
      if existingIsLive,
         !candidateIsLive,
         existing.timestamp.timeIntervalSince(candidate.timestamp) <= freshStatusGrace {
        return false
      }
      return true
    }

    if !existingIsLive,
       candidateIsLive,
       candidate.timestamp.timeIntervalSince(existing.timestamp) <= freshStatusGrace {
      return true
    }
    return false
  }

  private func listJSONLFiles() -> [URL] {
    var files: [(url: URL, modified: Date)] = []
    var seenPaths = Set<String>()

    for root in sessionRoots {
      guard fileManager.fileExists(atPath: root.path),
            let enumerator = fileManager.enumerator(
              at: root,
              includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
              options: [.skipsHiddenFiles]
            )
      else {
        continue
      }

      for case let url as URL in enumerator where url.pathExtension == "jsonl" {
        let path = url.standardizedFileURL.path
        guard seenPaths.insert(path).inserted,
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true
        else {
          continue
        }
        files.append((url, values.contentModificationDate ?? .distantPast))
      }
    }

    return files
      .sorted { $0.modified > $1.modified }
      .prefix(maxSessionFiles)
      .map(\.url)
  }

  private static func discoverSessionRoots(fileManager: FileManager) -> [URL] {
    let home = fileManager.homeDirectoryForCurrentUser
    let candidates = [
      home.appendingPathComponent(".codex/sessions"),
      home.appendingPathComponent(".codex/browser/sessions"),
      home.appendingPathComponent("Library/Application Support/Codex/sessions"),
      home.appendingPathComponent("Library/Application Support/com.openai.codex/sessions")
    ]

    return candidates.filter { containsJSONL(in: $0, fileManager: fileManager) }
  }

  private static func containsJSONL(in root: URL, fileManager: FileManager) -> Bool {
    guard fileManager.fileExists(atPath: root.path),
          let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          )
    else {
      return false
    }

    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
            values.isRegularFile == true
      else {
        continue
      }
      return true
    }

    return false
  }

  private func parseEvents(in file: URL, now: Date) -> [RateLimitEvent] {
    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let modified = values?.contentModificationDate ?? .distantPast
    let fileSize = values?.fileSize ?? -1
    let cacheKey = file.path
    if let cached = eventCache[cacheKey],
       cached.modified == modified,
       cached.fileSize == fileSize {
      return cached.events
    }

    let isActiveToday = Calendar.current.isDate(modified, inSameDayAs: now)
    if let cached = eventCache[cacheKey],
       !isActiveToday,
       fileSize >= cached.fileSize,
       let appendedText = readText(in: file, fromOffset: cached.fileSize) {
      let parsed = parseEventLines(
        appendedText,
        file: file,
        initialScores: cached.pendingScores,
        initialProjectName: cached.pendingProjectName,
        initialProjectPath: cached.pendingProjectPath
      )
      let newEvents = parsed.events
      let nextEvents = newEvents.isEmpty ? cached.events : cached.events + newEvents
      eventCache[cacheKey] = ParsedFileCache(
        modified: modified,
        fileSize: fileSize,
        pendingScores: parsed.pendingScores,
        pendingProjectName: parsed.pendingProjectName,
        pendingProjectPath: parsed.pendingProjectPath,
        events: nextEvents
      )
      return nextEvents
    }

    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
      return []
    }

    let fallbackProjectName = projectName(fromPath: file.deletingPathExtension().lastPathComponent)
    let parsed = parseEventLines(
      text,
      file: file,
      initialScores: emptyCategoryScores(),
      initialProjectName: fallbackProjectName,
      initialProjectPath: file.path
    )

    eventCache[cacheKey] = ParsedFileCache(
      modified: modified,
      fileSize: fileSize,
      pendingScores: parsed.pendingScores,
      pendingProjectName: parsed.pendingProjectName,
      pendingProjectPath: parsed.pendingProjectPath,
      events: parsed.events
    )
    return parsed.events
  }

  private func parseRecentEvents(in file: URL, now: Date, tailBytes: Int) -> [RateLimitEvent] {
    guard let text = readTailText(in: file, maxBytes: tailBytes) else {
      return []
    }
    let fallbackProjectName = projectName(fromPath: file.deletingPathExtension().lastPathComponent)
    return parseEventLines(
      text,
      file: file,
      initialScores: emptyCategoryScores(),
      initialProjectName: fallbackProjectName,
      initialProjectPath: file.path
    ).events
  }

  private func parseEventLines(
    _ text: String,
    file: URL,
    initialScores: [TokenUsageCategory: Int],
    initialProjectName: String,
    initialProjectPath: String
  ) -> (
    events: [RateLimitEvent],
    pendingScores: [TokenUsageCategory: Int],
    pendingProjectName: String,
    pendingProjectPath: String
  ) {
    var events: [RateLimitEvent] = []
    var contextScores = initialScores
    var currentProjectName = initialProjectName
    var currentProjectPath = initialProjectPath

    for lineSlice in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let linePrefix = lineSlice.prefix(8192)
      guard asciiContains(linePrefix.utf8, tokenCountNeedle) else {
        updateProjectContextIfPresent(
          linePrefix,
          projectName: &currentProjectName,
          projectPath: &currentProjectPath
        )
        scoreContextLineIfRelevant(linePrefix, into: &contextScores)
        continue
      }

      let line = String(lineSlice)
      let usageCategory = category(from: contextScores)
      guard let data = line.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let rateLimits = payload["rate_limits"] as? [String: Any],
            rateLimits["primary"] is [String: Any],
            let timestampString = object["timestamp"] as? String,
            let timestamp = ISO8601DateFormatter.codexDate(from: timestampString)
      else {
        continue
      }

      let limitID = rateLimits["limit_id"] as? String ?? "codex"
      let limitName = rateLimits["limit_name"] as? String ?? (limitID == "codex" ? "Codex 默认额度".coreL10n : limitID)
      let event = RateLimitEvent(
        timestamp: timestamp,
        sourceName: file.lastPathComponent,
        sourcePath: file.path,
        limitID: limitID,
        limitName: limitName,
        planType: rateLimits["plan_type"] as? String,
        primary: normalizeWindow(rateLimits["primary"] as? [String: Any]),
        secondary: normalizeWindow(rateLimits["secondary"] as? [String: Any]),
        reachedType: rateLimits["rate_limit_reached_type"] as? String,
        usage: normalizeUsage(payload["info"] as? [String: Any]),
        usageCategory: usageCategory,
        projectName: currentProjectName,
        projectPath: currentProjectPath
      )
      events.append(event)
      contextScores = emptyCategoryScores()
    }

    return (events, contextScores, currentProjectName, currentProjectPath)
  }

  private func readText(in file: URL, fromOffset offset: Int) -> String? {
    guard offset > 0 else {
      return try? String(contentsOf: file, encoding: .utf8)
    }

    do {
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      try handle.seek(toOffset: UInt64(offset))
      guard let data = try handle.readToEnd(), !data.isEmpty else {
        return ""
      }
      return String(data: data, encoding: .utf8)
    } catch {
      return nil
    }
  }

  private func readTailText(in file: URL, maxBytes: Int) -> String? {
    guard maxBytes > 0 else { return nil }

    do {
      let handle = try FileHandle(forReadingFrom: file)
      defer { try? handle.close() }
      let size = try handle.seekToEnd()
      let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
      try handle.seek(toOffset: offset)
      guard let data = try handle.readToEnd(), !data.isEmpty else {
        return ""
      }
      var text = String(data: data, encoding: .utf8) ?? ""
      if offset > 0,
         let firstLineBreak = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: firstLineBreak)...])
      }
      return text
    } catch {
      return nil
    }
  }

  private func updateProjectContextIfPresent(
    _ line: Substring,
    projectName: inout String,
    projectPath: inout String
  ) {
    guard asciiContains(line.utf8, cwdNeedle),
          let cwd = Self.jsonStringField("cwd", in: String(line)),
          cwd.isEmpty == false
    else {
      return
    }

    projectPath = cwd
    projectName = Self.projectName(fromPath: cwd)
  }

  private static func projectName(fromPath path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.isEmpty == false else { return "未知项目".coreL10n }
    let name = URL(fileURLWithPath: trimmed).lastPathComponent
    return name.isEmpty ? trimmed : name
  }

  private func projectName(fromPath path: String) -> String {
    Self.projectName(fromPath: path)
  }

  private func loadWorkspaceRootLabels() -> [String: String] {
    let stateFile = codexHome.appendingPathComponent(".codex-global-state.json")
    guard let data = try? Data(contentsOf: stateFile),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }

    let persistedState = object["electron-persisted-atom-state"] as? [String: Any] ?? [:]
    guard let labels = object["electron-workspace-root-labels"] as? [String: Any]
            ?? persistedState["electron-workspace-root-labels"] as? [String: Any]
    else {
      return [:]
    }

    var normalized: [String: String] = [:]
    for (path, value) in labels {
      guard let label = value as? String else { continue }
      let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmedLabel.isEmpty == false else { continue }
      normalized[Self.standardizedPath(path)] = trimmedLabel
    }
    return normalized
  }

  private func workspaceLabel(for path: String) -> String? {
    let normalizedPath = Self.standardizedPath(path)
    if let label = workspaceRootLabels[normalizedPath] {
      return label
    }

    return workspaceRootLabels
      .filter { root, _ in normalizedPath == root || normalizedPath.hasPrefix(root + "/") }
      .max { lhs, rhs in lhs.key.count < rhs.key.count }?
      .value
  }

  private func workspaceLabelSignature() -> String {
    workspaceRootLabels
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\($0.value)" }
      .joined(separator: "\u{1f}")
  }

  private static func standardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private static func jsonStringField(_ key: String, in text: String) -> String? {
    guard let range = text.range(of: "\"\(key)\":\"") else { return nil }
    var value = ""
    var isEscaping = false

    for character in text[range.upperBound...] {
      if isEscaping {
        switch character {
        case "n": value.append("\n")
        case "r": value.append("\r")
        case "t": value.append("\t")
        default: value.append(character)
        }
        isEscaping = false
      } else if character == "\\" {
        isEscaping = true
      } else if character == "\"" {
        return value
      } else {
        value.append(character)
      }
    }

    return nil
  }

  private func normalizeWindow(_ window: [String: Any]?) -> LimitWindow? {
    guard let window else { return nil }
    let used = clamp(percentValue(in: window, keys: ["used_percent", "usedPercent", "used_percentage", "used"]) ?? 0)
    let remaining = percentValue(
      in: window,
      keys: [
        "remaining_percent",
        "remainingPercent",
        "remaining_percentage",
        "available_percent",
        "availablePercent",
        "available_percentage",
        "left_percent",
        "balance_percent",
        "remaining",
        "available",
        "left"
      ]
    ).map(clamp) ?? clamp(100 - used)
    let windowMinutes = double(window["window_minutes"])
    let resetsAtSeconds = double(window["resets_at"])
    return LimitWindow(
      usedPercent: used,
      remainingPercent: remaining,
      windowMinutes: windowMinutes,
      resetsAt: resetsAtSeconds > 0 ? Date(timeIntervalSince1970: resetsAtSeconds) : nil
    )
  }

  private func percentValue(in dictionary: [String: Any], keys: [String]) -> Double? {
    for key in keys where dictionary.keys.contains(key) {
      return double(dictionary[key])
    }
    return nil
  }

  private func normalizeUsage(_ info: [String: Any]?) -> TokenUsage {
    let total = info?["total_token_usage"] as? [String: Any] ?? [:]
    let last = info?["last_token_usage"] as? [String: Any] ?? [:]
    return TokenUsage(
      totalTokens: integer(total["total_tokens"]),
      inputTokens: integer(total["input_tokens"]),
      cachedInputTokens: integer(total["cached_input_tokens"]),
      outputTokens: integer(total["output_tokens"]),
      reasoningOutputTokens: integer(total["reasoning_output_tokens"]),
      lastTotalTokens: integer(last["total_tokens"]),
      lastInputTokens: integer(last["input_tokens"]),
      lastOutputTokens: integer(last["output_tokens"]),
      lastReasoningOutputTokens: integer(last["reasoning_output_tokens"])
    )
  }

  private func emptyCategoryScores() -> [TokenUsageCategory: Int] {
    Dictionary(uniqueKeysWithValues: TokenUsageCategory.allCases.map { ($0, 0) })
  }

  private func scoreContextLineIfRelevant(
    _ line: Substring,
    into scores: inout [TokenUsageCategory: Int]
  ) {
    let bytes = line.utf8
    guard isScorableContextLine(bytes) else { return }

    let sample = String(line).lowercased()

    addScore(&scores, .presentation, sample.utf8, presentationKeywordRules)
    addScore(&scores, .imageDesign, sample.utf8, imageKeywordRules)
    addScore(&scores, .documents, sample.utf8, documentKeywordRules)
    addScore(&scores, .coding, sample.utf8, codingKeywordRules)
    addScore(&scores, .research, sample.utf8, researchKeywordRules)
  }

  private func isScorableContextLine<S: Sequence>(_ bytes: S) -> Bool where S.Element == UInt8 {
    if asciiContains(bytes, developerRoleNeedle) ||
       asciiContains(bytes, systemRoleNeedle) ||
       asciiContains(bytes, turnContextNeedle) ||
       asciiContains(bytes, sessionMetaNeedle) ||
       asciiContains(bytes, functionOutputNeedle) {
      return false
    }

    return asciiContains(bytes, userRoleNeedle) ||
      asciiContains(bytes, assistantRoleNeedle) ||
      asciiContains(bytes, userMessageNeedle) ||
      asciiContains(bytes, functionCallNeedle)
  }

  private func category(from scores: [TokenUsageCategory: Int]) -> TokenUsageCategory {
    return scores
      .filter { $0.key != .other }
      .max { lhs, rhs in
        if lhs.value == rhs.value {
          return categoryPriority(lhs.key) < categoryPriority(rhs.key)
        }
        return lhs.value < rhs.value
      }
      .flatMap { $0.value > 0 ? $0.key : nil } ?? .other
  }

  private func addScore(
    _ scores: inout [TokenUsageCategory: Int],
    _ category: TokenUsageCategory,
    _ text: String.UTF8View,
    _ rules: [UsageKeywordRule]
  ) {
    for rule in rules where asciiContains(text, rule.bytes) {
      scores[category, default: 0] += rule.weight
    }
  }

  private func categoryPriority(_ category: TokenUsageCategory) -> Int {
    switch category {
    case .presentation: 6
    case .imageDesign: 5
    case .documents: 4
    case .coding: 3
    case .research: 2
    case .other: 1
    }
  }

  private func buildCachedTokenStats(from events: [RateLimitEvent], now: Date) -> TokenStats {
    let dayKey = periodKey(now, period: .day)
    let signature = tokenStatsSignature(for: events)
    if let cached = tokenStatsCache,
       cached.signature == signature,
       cached.dayKey == dayKey {
      return cached.stats
    }

    let stats = buildTokenStats(from: events, now: now)
    tokenStatsCache = TokenStatsCache(signature: signature, dayKey: dayKey, stats: stats)
    return stats
  }

  private func tokenStatsSignature(for events: [RateLimitEvent]) -> String {
    guard let last = events.last else { return "empty" }
    return [
      String(events.count),
      last.sourcePath,
      String(last.timestamp.timeIntervalSince1970),
      String(last.usage.totalTokens),
      String(last.usage.lastTotalTokens),
      workspaceLabelSignature()
    ].joined(separator: "|")
  }

  private func buildTokenStats(from events: [RateLimitEvent], now: Date) -> TokenStats {
    let usageEvents = buildTokenUsageEvents(from: events)
    var daily: [String: TokenBucket] = [:]
    var monthly: [String: TokenBucket] = [:]

    for event in usageEvents {
      add(event, to: &daily, key: periodKey(event.timestamp, period: .day))
      add(event, to: &monthly, key: periodKey(event.timestamp, period: .month))
    }

    let dailyRows = fillDailyRows(daily, count: 14, now: now)
    let monthlyRows = fillMonthlyRows(monthly, count: 6, now: now)
    let todayKey = periodKey(now, period: .day)
    let monthKey = periodKey(now, period: .month)
    let last7Keys = Set(fillDailyKeys(count: 7, now: now))
    let last7Tokens = daily
      .filter { last7Keys.contains($0.key) }
      .reduce(0) { $0 + $1.value.totalTokens }
    let categoryBreakdown = buildCategoryBreakdown(
      from: usageEvents.filter { periodKey($0.timestamp, period: .month) == monthKey }
    )
    let todayTopProjects = buildProjectBreakdown(
      from: usageEvents.filter { periodKey($0.timestamp, period: .day) == todayKey },
      limit: 3
    )
    let monthTopProjects = buildProjectBreakdown(
      from: usageEvents.filter { periodKey($0.timestamp, period: .month) == monthKey },
      limit: 3
    )

    return TokenStats(
      todayTokens: daily[todayKey]?.totalTokens ?? 0,
      monthTokens: monthly[monthKey]?.totalTokens ?? 0,
      last7DaysTokens: last7Tokens,
      sampleCount: usageEvents.count,
      daily: dailyRows,
      monthly: monthlyRows,
      categoryBreakdown: categoryBreakdown,
      todayTopProjects: todayTopProjects,
      monthTopProjects: monthTopProjects,
      recentUsageEvents: Array(usageEvents.suffix(12).reversed())
    )
  }

  private func buildTokenUsageEvents(from events: [RateLimitEvent]) -> [TokenUsageEvent] {
    var unique: [String: TokenUsageEvent] = [:]
    for event in events where event.usage.lastTotalTokens > 0 && event.usage.totalTokens > 0 {
      let key = "\(event.sourcePath):\(event.usage.totalTokens):\(event.usage.lastTotalTokens)"
      let displayProjectName = workspaceLabel(for: event.projectPath) ?? event.projectName
      let usageEvent = TokenUsageEvent(
        timestamp: event.timestamp,
        sourceName: event.sourceName,
        totalTokens: event.usage.lastTotalTokens,
        inputTokens: event.usage.lastInputTokens,
        outputTokens: event.usage.lastOutputTokens,
        reasoningOutputTokens: event.usage.lastReasoningOutputTokens,
        category: event.usageCategory,
        projectName: displayProjectName,
        projectPath: event.projectPath
      )
      if unique[key]?.timestamp ?? .distantFuture > usageEvent.timestamp {
        unique[key] = usageEvent
      }
    }
    return unique.values.sorted { $0.timestamp < $1.timestamp }
  }

  private func add(_ event: TokenUsageEvent, to buckets: inout [String: TokenBucket], key: String) {
    var bucket = buckets[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    bucket.totalTokens += event.totalTokens
    bucket.inputTokens += event.inputTokens
    bucket.outputTokens += event.outputTokens
    bucket.reasoningOutputTokens += event.reasoningOutputTokens
    bucket.calls += 1
    buckets[key] = bucket
  }

  private func buildCategoryBreakdown(from events: [TokenUsageEvent]) -> [TokenCategoryBucket] {
    var rows = Dictionary(
      uniqueKeysWithValues: TokenUsageCategory.allCases.map {
        ($0, TokenCategoryBucket(category: $0))
      }
    )

    for event in events {
      var bucket = rows[event.category] ?? TokenCategoryBucket(category: event.category)
      bucket.totalTokens += event.totalTokens
      bucket.inputTokens += event.inputTokens
      bucket.outputTokens += event.outputTokens
      bucket.reasoningOutputTokens += event.reasoningOutputTokens
      bucket.calls += 1
      rows[event.category] = bucket
    }

    return TokenUsageCategory.allCases.compactMap { rows[$0] }
  }

  private func buildProjectBreakdown(from events: [TokenUsageEvent], limit: Int) -> [TokenProjectBucket] {
    var rows: [String: TokenProjectBucket] = [:]
    for event in events {
      let key = event.projectPath.isEmpty ? event.projectName : event.projectPath
      var bucket = rows[key] ?? TokenProjectBucket(
        projectName: event.projectName,
        projectPath: event.projectPath
      )
      bucket.totalTokens += event.totalTokens
      bucket.calls += 1
      rows[key] = bucket
    }

    return rows.values
      .sorted {
        if $0.totalTokens == $1.totalTokens {
          return $0.projectName < $1.projectName
        }
        return $0.totalTokens > $1.totalTokens
      }
      .prefix(limit)
      .map { $0 }
  }

  private func fillDailyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    fillDailyKeys(count: count, now: now).map { rows[$0] ?? TokenBucket(key: $0, label: formatPeriodLabel($0)) }
  }

  private func fillDailyKeys(count: Int, now: Date) -> [String] {
    let calendar = Calendar.current
    return (0..<count).compactMap { index in
      let offset = count - 1 - index
      return calendar.date(byAdding: .day, value: -offset, to: now).map { periodKey($0, period: .day) }
    }
  }

  private func fillMonthlyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    let calendar = Calendar.current
    return (0..<count).compactMap { index -> TokenBucket? in
      let offset = count - 1 - index
      guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { return nil }
      let key = periodKey(date, period: .month)
      return rows[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    }
  }

  private enum Period {
    case day
    case month
  }

  private func periodKey(_ date: Date, period: Period) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    let year = components.year ?? 0
    let month = components.month ?? 0
    if period == .month {
      return String(format: "%04d-%02d", year, month)
    }
    return String(format: "%04d-%02d-%02d", year, month, components.day ?? 0)
  }

  private func formatPeriodLabel(_ key: String) -> String {
    let parts = key.split(separator: "-")
    if parts.count == 2 {
      return "\(parts[0])/\(parts[1])"
    }
    if parts.count == 3 {
      return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }
    return key
  }
}

private extension ISO8601DateFormatter {
  static func codexDate(from string: String) -> Date? {
    let withFractionalSeconds = ISO8601DateFormatter()
    withFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFractionalSeconds.date(from: string) {
      return date
    }

    let withoutFractionalSeconds = ISO8601DateFormatter()
    withoutFractionalSeconds.formatOptions = [.withInternetDateTime]
    return withoutFractionalSeconds.date(from: string)
  }
}

private final class ProfileUsageFetchResult: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: AccountTokenUsage?

  var value: AccountTokenUsage? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func set(_ usage: AccountTokenUsage) {
    lock.lock()
    storage = usage
    lock.unlock()
  }
}

private final class CodexProfileUsageSource: @unchecked Sendable {
  private struct AuthFile: Decodable {
    var tokens: Tokens?

    struct Tokens: Decodable {
      var accessToken: String?

      enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
      }
    }
  }

  private struct ProfilePayload: Decodable {
    var stats: Stats?

    struct Stats: Decodable {
      var dailyUsageBuckets: [DailyUsageBucket]?

      enum CodingKeys: String, CodingKey {
        case dailyUsageBuckets = "daily_usage_buckets"
      }
    }
  }

  private struct DailyUsageBucket: Decodable {
    var tokens: Int
    var startDate: String

    enum CodingKeys: String, CodingKey {
      case tokens
      case startDate = "start_date"
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      startDate = try container.decode(String.self, forKey: .startDate)
      if let integerValue = try? container.decode(Int.self, forKey: .tokens) {
        tokens = integerValue
      } else if let doubleValue = try? container.decode(Double.self, forKey: .tokens) {
        tokens = Int(doubleValue)
      } else {
        tokens = 0
      }
    }
  }

  private enum Period {
    case day
    case month
  }

  private let codexHome: URL
  private let fileManager: FileManager
  private let cacheLock = NSLock()
  private var cachedUsage: AccountTokenUsage?
  private var cachedAt: Date?
  private var refreshInFlight = false
  private var failedUntil: Date?

  init(codexHome: URL, fileManager: FileManager) {
    self.codexHome = codexHome
    self.fileManager = fileManager
  }

  func cachedUsage(now: Date, maxAge: TimeInterval = 120) -> AccountTokenUsage? {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    guard let cachedAt, now.timeIntervalSince(cachedAt) <= maxAge else {
      return nil
    }
    return cachedUsage
  }

  func refreshInBackground(now: Date) {
    cacheLock.lock()
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false) {
      cacheLock.unlock()
      return
    }
    if let cachedAt, now.timeIntervalSince(cachedAt) < 45 {
      cacheLock.unlock()
      return
    }
    refreshInFlight = true
    cacheLock.unlock()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let usage = self.fetchUsage(now: Date())

      self.cacheLock.lock()
      if let usage {
        self.cachedUsage = usage
        self.cachedAt = Date()
        self.failedUntil = nil
      } else {
        self.failedUntil = Date().addingTimeInterval(60)
      }
      self.refreshInFlight = false
      self.cacheLock.unlock()
    }
  }

  private func fetchUsage(now: Date) -> AccountTokenUsage? {
    guard let accessToken = readAccessToken() else {
      return nil
    }
    guard let url = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me") else {
      return nil
    }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 12
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("en", forHTTPHeaderField: "OAI-Language")
    request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
    request.setValue("codex_desktop", forHTTPHeaderField: "OpenAI-Beta")

    let semaphore = DispatchSemaphore(value: 0)
    let result = ProfileUsageFetchResult()
    URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { semaphore.signal() }
      guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let data,
            let payload = try? JSONDecoder().decode(ProfilePayload.self, from: data)
      else {
        return
      }
      result.set(self.usage(from: payload, now: now))
    }.resume()

    _ = semaphore.wait(timeout: .now() + 12)
    return result.value
  }

  private func readAccessToken() -> String? {
    let authFile = codexHome.appendingPathComponent("auth.json")
    guard fileManager.fileExists(atPath: authFile.path),
          let data = try? Data(contentsOf: authFile),
          let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
          let token = auth.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
          token.isEmpty == false
    else {
      return nil
    }
    return token
  }

  private func usage(from payload: ProfilePayload, now: Date) -> AccountTokenUsage {
    let buckets = payload.stats?.dailyUsageBuckets ?? []
    var daily: [String: TokenBucket] = [:]
    var monthly: [String: TokenBucket] = [:]

    for bucket in buckets {
      let key = normalizedDayKey(bucket.startDate)
      guard key.isEmpty == false else { continue }
      let tokens = max(0, bucket.tokens)
      var dayBucket = daily[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
      dayBucket.totalTokens += tokens
      daily[key] = dayBucket

      let monthKey = String(key.prefix(7))
      var monthBucket = monthly[monthKey] ?? TokenBucket(key: monthKey, label: formatPeriodLabel(monthKey))
      monthBucket.totalTokens += tokens
      monthly[monthKey] = monthBucket
    }

    return AccountTokenUsage(
      daily: fillDailyRows(daily, count: 14, now: now),
      monthly: fillMonthlyRows(monthly, count: 6, now: now),
      updatedAt: now
    )
  }

  private func normalizedDayKey(_ rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 10 else { return "" }
    let candidate = String(trimmed.prefix(10))
    let parts = candidate.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          parts[0] > 2000,
          (1...12).contains(parts[1]),
          (1...31).contains(parts[2])
    else {
      return ""
    }
    return String(format: "%04d-%02d-%02d", parts[0], parts[1], parts[2])
  }

  private func fillDailyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    (0..<count).compactMap { index in
      let offset = count - 1 - index
      guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: now) else {
        return nil
      }
      let key = periodKey(date, period: .day)
      return rows[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    }
  }

  private func fillMonthlyRows(_ rows: [String: TokenBucket], count: Int, now: Date) -> [TokenBucket] {
    (0..<count).compactMap { index in
      let offset = count - 1 - index
      guard let date = Calendar.current.date(byAdding: .month, value: -offset, to: now) else {
        return nil
      }
      let key = periodKey(date, period: .month)
      return rows[key] ?? TokenBucket(key: key, label: formatPeriodLabel(key))
    }
  }

  private func periodKey(_ date: Date, period: Period) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    let year = components.year ?? 0
    let month = components.month ?? 0
    if period == .month {
      return String(format: "%04d-%02d", year, month)
    }
    return String(format: "%04d-%02d-%02d", year, month, components.day ?? 0)
  }

  private func formatPeriodLabel(_ key: String) -> String {
    let parts = key.split(separator: "-")
    if parts.count == 2 {
      return "\(parts[0])/\(parts[1])"
    }
    if parts.count == 3 {
      return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }
    return key
  }
}

private final class CodexAppServerRateLimitSource: @unchecked Sendable {
  private struct RPCErrorPayload: Decodable {
    var code: Int?
    var message: String
  }

  private struct RPCResponse<Result: Decodable>: Decodable {
    var id: Int
    var result: Result?
    var error: RPCErrorPayload?
  }

  private struct LiveRateLimitsPayload: Decodable {
    var rateLimits: LiveRateLimitSnapshot
    var rateLimitsByLimitId: [String: LiveRateLimitSnapshot]?
  }

  private struct LiveRateLimitSnapshot: Decodable {
    var limitId: String?
    var limitName: String?
    var primary: LiveRateLimitWindow?
    var secondary: LiveRateLimitWindow?
    var planType: String?
    var rateLimitReachedType: String?
  }

  private struct LiveRateLimitWindow: Decodable {
    var usedPercent: Double
    var windowDurationMins: Double?
    var resetsAt: Double?
  }

  private let condition = NSCondition()
  private var process: Process?
  private var inputPipe: Pipe?
  private var outputPipe: Pipe?
  private var errorPipe: Pipe?
  private var outputBuffer = Data()
  private var responses: [Int: Data] = [:]
  private var nextRequestID = 1
  private var initialized = false
  private var completedLiveRead = false
  private let cacheLock = NSLock()
  private var cachedEvents: [RateLimitEvent] = []
  private var cachedAt: Date?
  private var refreshInFlight = false
  private var failedUntil: Date?

  deinit {
    stop()
  }

  func cachedRateLimitEvents(now: Date, maxAge: TimeInterval = 20) -> [RateLimitEvent] {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    guard let cachedAt, now.timeIntervalSince(cachedAt) <= maxAge else {
      return []
    }
    return cachedEvents
  }

  func freshRateLimitEvents(now: Date, maxAge: TimeInterval = 20) -> [RateLimitEvent] {
    cacheLock.lock()
    if let cachedAt, now.timeIntervalSince(cachedAt) <= maxAge {
      let events = cachedEvents
      cacheLock.unlock()
      return events
    }
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false) {
      let events = cachedEvents
      cacheLock.unlock()
      return events
    }
    refreshInFlight = true
    cacheLock.unlock()

    let events = fetchRateLimitEvents(now: now)
    cacheLock.lock()
    if events.isEmpty == false {
      cachedEvents = events
      cachedAt = Date()
    }
    refreshInFlight = false
    cacheLock.unlock()
    return events
  }

  func refreshInBackground() {
    let now = Date()
    cacheLock.lock()
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false) {
      cacheLock.unlock()
      return
    }
    refreshInFlight = true
    cacheLock.unlock()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let events = self.fetchRateLimitEvents(now: Date())

      self.cacheLock.lock()
      if events.isEmpty == false {
        self.cachedEvents = events
        self.cachedAt = Date()
      }
      self.refreshInFlight = false
      self.cacheLock.unlock()
    }
  }

  private func fetchRateLimitEvents(now: Date) -> [RateLimitEvent] {
    do {
      try ensureInitialized()
      let id = nextID()
      try send([
        "jsonrpc": "2.0",
        "id": id,
        "method": "account/rateLimits/read"
      ])
      let data = try waitForResponse(id: id, timeout: completedLiveRead ? 3.0 : 12.0)
      let response = try JSONDecoder().decode(RPCResponse<LiveRateLimitsPayload>.self, from: data)
      if let error = response.error {
        throw LiveRateLimitError.server(error.message)
      }
      guard let payload = response.result else {
        throw LiveRateLimitError.emptyResponse
      }
      clearFailureCooldown()
      completedLiveRead = true
      return events(from: payload, now: now)
    } catch {
      NSLog("CodexBalance live rate limit source failed: \(error.localizedDescription)")
      stop()
      markFailureCooldown(seconds: 15)
      return []
    }
  }

  private func ensureInitialized() throws {
    if initialized, process?.isRunning == true {
      return
    }

    try start()
    let id = nextID()
    try send([
      "jsonrpc": "2.0",
      "id": id,
      "method": "initialize",
      "params": [
        "clientInfo": [
          "name": "CodexBalance",
          "version": "1"
        ]
      ]
    ])
    _ = try waitForResponse(id: id, timeout: 8)
    try send([
      "jsonrpc": "2.0",
      "method": "initialized"
    ])
    initialized = true
  }

  private func start() throws {
    if process?.isRunning == true {
      return
    }

    guard let executableURL = Self.codexExecutableURL() else {
      NSLog("CodexBalance live rate limit source failed: codex executable missing")
      throw LiveRateLimitError.codexExecutableMissing
    }

    let nextProcess = Process()
    let nextInputPipe = Pipe()
    let nextOutputPipe = Pipe()
    let nextErrorPipe = Pipe()
    nextProcess.executableURL = executableURL
    nextProcess.arguments = ["app-server", "--listen", "stdio://"]
    nextProcess.standardInput = nextInputPipe
    nextProcess.standardOutput = nextOutputPipe
    nextProcess.standardError = nextErrorPipe

    nextOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard data.isEmpty == false else {
        self?.handleProcessExit()
        return
      }
      self?.appendOutput(data)
    }
    nextErrorPipe.fileHandleForReading.readabilityHandler = { handle in
      _ = handle.availableData
    }
    nextProcess.terminationHandler = { [weak self] _ in
      self?.handleProcessExit()
    }

    condition.lock()
    process = nextProcess
    inputPipe = nextInputPipe
    outputPipe = nextOutputPipe
    errorPipe = nextErrorPipe
    outputBuffer.removeAll(keepingCapacity: true)
    responses.removeAll()
    initialized = false
    completedLiveRead = false
    condition.unlock()

    try nextProcess.run()
  }

  private func stop() {
    condition.lock()
    let currentProcess = process
    outputPipe?.fileHandleForReading.readabilityHandler = nil
    errorPipe?.fileHandleForReading.readabilityHandler = nil
    process = nil
    inputPipe = nil
    outputPipe = nil
    errorPipe = nil
    outputBuffer.removeAll(keepingCapacity: true)
    responses.removeAll()
    initialized = false
    completedLiveRead = false
    condition.broadcast()
    condition.unlock()

    if let currentProcess, currentProcess.isRunning {
      currentProcess.terminate()
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
        guard currentProcess.isRunning else { return }
        #if canImport(Darwin)
        Darwin.kill(currentProcess.processIdentifier, SIGKILL)
        #else
        currentProcess.terminate()
        #endif
      }
    }
  }

  private func handleProcessExit() {
    condition.lock()
    process = nil
    inputPipe = nil
    outputPipe = nil
    errorPipe = nil
    initialized = false
    completedLiveRead = false
    condition.broadcast()
    condition.unlock()
  }

  private func appendOutput(_ data: Data) {
    condition.lock()
    outputBuffer.append(data)
    while let newlineIndex = outputBuffer.firstIndex(of: 10) {
      let lineData = outputBuffer[..<newlineIndex]
      outputBuffer.removeSubrange(...newlineIndex)
      guard lineData.isEmpty == false,
            let object = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any],
            let id = Self.integerID(object["id"])
      else {
        continue
      }
      responses[id] = Data(lineData)
      condition.broadcast()
    }
    condition.unlock()
  }

  private func nextID() -> Int {
    condition.lock()
    defer { condition.unlock() }
    let id = nextRequestID
    nextRequestID += 1
    return id
  }

  private func send(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object)
    guard var line = String(data: data, encoding: .utf8)?.data(using: .utf8) else {
      throw LiveRateLimitError.encodingFailed
    }
    line.append(10)
    guard let inputPipe else {
      throw LiveRateLimitError.processExited
    }
    try inputPipe.fileHandleForWriting.write(contentsOf: line)
  }

  private func waitForResponse(id: Int, timeout: TimeInterval) throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    condition.lock()
    defer { condition.unlock() }

    while responses[id] == nil {
      if process?.isRunning != true {
        throw LiveRateLimitError.processExited
      }
      if Date() >= deadline {
        throw LiveRateLimitError.timeout
      }
      condition.wait(until: deadline)
    }

    return responses.removeValue(forKey: id) ?? Data()
  }

  private func events(from payload: LiveRateLimitsPayload, now: Date) -> [RateLimitEvent] {
    var snapshots = payload.rateLimitsByLimitId ?? [:]
    let mainID = payload.rateLimits.limitId ?? "codex"
    snapshots[mainID] = payload.rateLimits

    return snapshots
      .values
      .compactMap { snapshot in
        guard let limitID = snapshot.limitId, limitID.isEmpty == false else {
          return nil
        }
        return RateLimitEvent(
          timestamp: now,
          sourceName: "Codex app-server",
          sourcePath: "account/rateLimits/read",
          limitID: limitID,
          limitName: snapshot.limitName ?? (limitID == "codex" ? "Codex 默认额度".coreL10n : limitID),
          planType: snapshot.planType,
          primary: normalize(snapshot.primary),
          secondary: normalize(snapshot.secondary),
          reachedType: snapshot.rateLimitReachedType
        )
      }
  }

  private func normalize(_ window: LiveRateLimitWindow?) -> LimitWindow? {
    guard let window else { return nil }
    let used = clamp(window.usedPercent)
    return LimitWindow(
      usedPercent: used,
      remainingPercent: clamp(100 - used),
      windowMinutes: window.windowDurationMins ?? 0,
      resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }
    )
  }

  private static func codexExecutableURL() -> URL? {
    let candidates = [
      "/Applications/Codex.app/Contents/Resources/codex",
      "/opt/homebrew/bin/codex",
      "/usr/local/bin/codex",
      "/usr/bin/codex"
    ]
    return candidates
      .map(URL.init(fileURLWithPath:))
      .first { FileManager.default.isExecutableFile(atPath: $0.path) }
  }

  private static func integerID(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    if let value = value as? String { return Int(value) }
    return nil
  }

  private func markFailureCooldown(seconds: TimeInterval) {
    cacheLock.lock()
    failedUntil = Date().addingTimeInterval(seconds)
    cacheLock.unlock()
  }

  private func clearFailureCooldown() {
    cacheLock.lock()
    failedUntil = nil
    cacheLock.unlock()
  }
}

private enum LiveRateLimitError: LocalizedError {
  case codexExecutableMissing
  case encodingFailed
  case processExited
  case timeout
  case emptyResponse
  case server(String)

  var errorDescription: String? {
    switch self {
    case .codexExecutableMissing: "找不到 Codex 可执行文件".coreL10n
    case .encodingFailed: "无法编码 Codex app-server 请求".coreL10n
    case .processExited: "Codex app-server 已退出".coreL10n
    case .timeout: "Codex app-server 响应超时".coreL10n
    case .emptyResponse: "Codex app-server 返回空结果".coreL10n
    case let .server(message): message
    }
  }
}

private func integer(_ value: Any?) -> Int {
  if let value = value as? Int { return value }
  if let value = value as? Double { return Int(value) }
  if let value = value as? NSNumber { return value.intValue }
  if let value = value as? String { return Int(value) ?? 0 }
  return 0
}

private func double(_ value: Any?) -> Double {
  if let value = value as? Double { return value }
  if let value = value as? Int { return Double(value) }
  if let value = value as? NSNumber { return value.doubleValue }
  if let value = value as? String { return Double(value) ?? 0 }
  return 0
}

private func clamp(_ value: Double) -> Double {
  guard value.isFinite else { return 0 }
  return max(0, min(100, value))
}

private func asciiContains<S: Sequence>(_ haystack: S, _ needle: [UInt8]) -> Bool where S.Element == UInt8 {
  guard !needle.isEmpty else { return true }
  var matched = 0
  for byte in haystack {
    if byte == needle[matched] {
      matched += 1
      if matched == needle.count {
        return true
      }
    } else {
      matched = byte == needle[0] ? 1 : 0
    }
  }
  return false
}
