import Foundation

/// 读取 Claude Code 本机数据：
/// - token 用量：~/.claude/projects/<项目目录哈希>/<会话uuid>.jsonl 中 assistant 行的 message.usage，
///   按消息 uuid 跨文件去重，跳过 model == "<synthetic>" 的本地合成占位行。
/// - 余额/限额：读取已有 OAuth 凭据（Keychain「Claude Code-credentials」或 ~/.claude/.credentials.json）
///   调用官方 usage 接口；凭据不存在或接口失败时返回 nil（UI 显示「暂无数据」灰环），绝不发起登录。
/// - 官方按天总量：暂无可靠来源，恒为 nil。
public final class ClaudeStatusReader: @unchecked Sendable {
  private struct ParsedClaudeFile {
    var modified: Date
    var fileSize: Int
    var events: [ClaudeUsageEvent]
  }

  struct ClaudeUsageEvent {
    var uuid: String
    var timestamp: Date
    var inputTokens: Int
    var cacheCreationInputTokens: Int
    var cacheReadInputTokens: Int
    var outputTokens: Int
    var projectName: String
    var projectPath: String
    var sourceName: String

    /// 口径：含 cache_read（见功能说明 3.1，诊断中注明）
    var totalTokens: Int {
      inputTokens + cacheCreationInputTokens + cacheReadInputTokens + outputTokens
    }
  }

  private let fileManager: FileManager
  private let projectRoots: [URL]
  private let claudeHome: URL
  private let maxSessionFiles: Int
  private let rateLimitSource: ClaudeOAuthUsageSource?
  private let usageSyncStore: CodexUsageSyncStore?
  private var fileCache: [String: ParsedClaudeFile] = [:]
  private let cacheLock = NSLock()

  public init(
    claudeHome: URL? = nil,
    maxSessionFiles: Int = 1000,
    preferLiveStatus: Bool = true,
    fileManager: FileManager = .default
  ) {
    let defaultHome = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    let resolvedHome = claudeHome ?? defaultHome
    self.fileManager = fileManager
    self.claudeHome = resolvedHome
    self.projectRoots = [resolvedHome.appendingPathComponent("projects")]
    self.maxSessionFiles = maxSessionFiles
    self.rateLimitSource = preferLiveStatus && claudeHome == nil
      ? ClaudeOAuthUsageSource(claudeHome: resolvedHome, fileManager: fileManager)
      : nil
    self.usageSyncStore = preferLiveStatus && claudeHome == nil
      ? CodexUsageSyncStore(app: .claude, fileManager: fileManager)
      : nil
  }

  public func read(now: Date = Date()) throws -> CodexStatus {
    let files = listJSONLFiles()
    let activePaths = Set(files.map(\.path))
    cacheLock.lock()
    fileCache = fileCache.filter { activePaths.contains($0.key) }
    cacheLock.unlock()

    var seenUUIDs = Set<String>()
    var events: [ClaudeUsageEvent] = []
    for file in files.sorted(by: { $0.path < $1.path }) {
      for event in parseEvents(in: file) where seenUUIDs.insert(event.uuid).inserted {
        events.append(event)
      }
    }
    events.sort { $0.timestamp < $1.timestamp }

    let liveEvents = rateLimitSource?.cachedRateLimitEvents(now: now) ?? []
    rateLimitSource?.refreshInBackground()

    var tokenStats = buildTokenStats(from: events, now: now)
    tokenStats.deviceUsage = usageSyncStore?.persistAndReadSnapshots(from: tokenStats, now: now) ?? []

    let main = liveEvents.first
    return CodexStatus(
      generatedAt: now,
      codexHome: claudeHome.path,
      sessionsRoot: projectRoots.map(\.path).joined(separator: " | "),
      scannedFiles: files.count,
      eventCount: events.count,
      main: main,
      limits: liveEvents,
      trend: liveEvents,
      tokenStats: tokenStats,
      recentEvents: liveEvents
    )
  }

  public func readFast(now: Date = Date()) throws -> CodexStatus {
    let liveEvents = rateLimitSource?.freshRateLimitEvents(now: now) ?? []

    // Claude 日志文件很少（按会话），且 parseEvents 按 (modified,fileSize) 缓存，
    // 这里顺带算本地 token，让「今日 Token」每次快速刷新都即时更新，
    // 不必等 180 秒一次的全量刷新（避免切换模型等时刻出现「今日数据为 0」的空窗）。
    let files = listJSONLFiles()
    let activePaths = Set(files.map(\.path))
    cacheLock.lock()
    fileCache = fileCache.filter { activePaths.contains($0.key) }
    cacheLock.unlock()
    var seenUUIDs = Set<String>()
    var events: [ClaudeUsageEvent] = []
    for file in files.sorted(by: { $0.path < $1.path }) {
      for event in parseEvents(in: file) where seenUUIDs.insert(event.uuid).inserted {
        events.append(event)
      }
    }
    events.sort { $0.timestamp < $1.timestamp }

    var tokenStats = buildTokenStats(from: events, now: now)
    tokenStats.deviceUsage = usageSyncStore?.readSnapshots() ?? []
    return CodexStatus(
      generatedAt: now,
      codexHome: claudeHome.path,
      sessionsRoot: projectRoots.map(\.path).joined(separator: " | "),
      scannedFiles: files.count,
      eventCount: events.count,
      main: liveEvents.first,
      limits: liveEvents,
      trend: liveEvents,
      tokenStats: tokenStats,
      recentEvents: liveEvents
    )
  }

  private func listJSONLFiles() -> [URL] {
    var files: [(url: URL, modified: Date)] = []
    for root in projectRoots {
      guard fileManager.fileExists(atPath: root.path),
            let enumerator = fileManager.enumerator(
              at: root,
              includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
              options: [.skipsHiddenFiles]
            )
      else { continue }

      for case let url as URL in enumerator where url.pathExtension == "jsonl" {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true
        else { continue }
        files.append((url, values.contentModificationDate ?? .distantPast))
      }
    }
    return files
      .sorted { $0.modified > $1.modified }
      .prefix(maxSessionFiles)
      .map(\.url)
  }

  private func parseEvents(in file: URL) -> [ClaudeUsageEvent] {
    let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    let modified = values?.contentModificationDate ?? .distantPast
    let fileSize = values?.fileSize ?? -1
    cacheLock.lock()
    let cachedEntry = fileCache[file.path]
    cacheLock.unlock()
    if let cached = cachedEntry,
       cached.modified == modified,
       cached.fileSize == fileSize {
      return cached.events
    }

    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }

    let usageNeedle = Array(#""usage""#.utf8)
    let assistantNeedle = Array(#""type":"assistant""#.utf8)
    var events: [ClaudeUsageEvent] = []
    var currentProjectPath = ""
    var currentProjectName = "未知项目".coreL10n

    for lineSlice in text.split(separator: "\n", omittingEmptySubsequences: true) {
      let prefix = lineSlice.prefix(16384)
      if currentProjectPath.isEmpty,
         let cwd = Self.jsonStringField("cwd", in: String(prefix)),
         !cwd.isEmpty {
        currentProjectPath = cwd
        currentProjectName = Self.projectName(fromPath: cwd)
      }
      guard claudeAsciiContains(prefix.utf8, assistantNeedle),
            claudeAsciiContains(lineSlice.utf8, usageNeedle)
      else { continue }

      guard let data = String(lineSlice).data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["type"] as? String == "assistant",
            let uuid = object["uuid"] as? String,
            let timestampString = object["timestamp"] as? String,
            let timestamp = ISO8601DateFormatter.claudeDate(from: timestampString),
            let message = object["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any]
      else { continue }

      // 跳过 CLI 本地合成的占位行（usage 全 0，且会虚高 calls 计数）
      if message["model"] as? String == "<synthetic>" { continue }

      let event = ClaudeUsageEvent(
        uuid: uuid,
        timestamp: timestamp,
        inputTokens: claudeInteger(usage["input_tokens"]),
        cacheCreationInputTokens: claudeInteger(usage["cache_creation_input_tokens"]),
        cacheReadInputTokens: claudeInteger(usage["cache_read_input_tokens"]),
        outputTokens: claudeInteger(usage["output_tokens"]),
        projectName: currentProjectName,
        projectPath: currentProjectPath,
        sourceName: file.lastPathComponent
      )
      guard event.totalTokens > 0 else { continue }
      events.append(event)
    }

    cacheLock.lock()
    fileCache[file.path] = ParsedClaudeFile(modified: modified, fileSize: fileSize, events: events)
    cacheLock.unlock()
    return events
  }

  private func buildTokenStats(from events: [ClaudeUsageEvent], now: Date) -> TokenStats {
    var daily: [String: TokenBucket] = [:]
    var monthly: [String: TokenBucket] = [:]
    var usageEvents: [TokenUsageEvent] = []

    for event in events {
      add(event, to: &daily, key: Self.periodKey(event.timestamp, monthly: false))
      add(event, to: &monthly, key: Self.periodKey(event.timestamp, monthly: true))
      usageEvents.append(
        TokenUsageEvent(
          timestamp: event.timestamp,
          sourceName: event.sourceName,
          totalTokens: event.totalTokens,
          inputTokens: event.inputTokens + event.cacheCreationInputTokens + event.cacheReadInputTokens,
          outputTokens: event.outputTokens,
          reasoningOutputTokens: 0,
          category: .other,
          projectName: event.projectName,
          projectPath: event.projectPath
        )
      )
    }

    let todayKey = Self.periodKey(now, monthly: false)
    let monthKey = Self.periodKey(now, monthly: true)
    let calendar = Calendar.current
    let dailyKeys: [String] = (0..<14).compactMap { index in
      calendar.date(byAdding: .day, value: -(13 - index), to: now)
        .map { Self.periodKey($0, monthly: false) }
    }
    let monthlyKeys: [String] = (0..<6).compactMap { index in
      calendar.date(byAdding: .month, value: -(5 - index), to: now)
        .map { Self.periodKey($0, monthly: true) }
    }
    let last7Keys = Set(dailyKeys.suffix(7))
    let last7Tokens = daily
      .filter { last7Keys.contains($0.key) }
      .reduce(0) { $0 + $1.value.totalTokens }

    return TokenStats(
      todayTokens: daily[todayKey]?.totalTokens ?? 0,
      monthTokens: monthly[monthKey]?.totalTokens ?? 0,
      last7DaysTokens: last7Tokens,
      sampleCount: events.count,
      daily: dailyKeys.map { daily[$0] ?? TokenBucket(key: $0, label: Self.periodLabel($0)) },
      monthly: monthlyKeys.map { monthly[$0] ?? TokenBucket(key: $0, label: Self.periodLabel($0)) },
      categoryBreakdown: [],
      todayTopProjects: topProjects(from: usageEvents.filter { Self.periodKey($0.timestamp, monthly: false) == todayKey }),
      monthTopProjects: topProjects(from: usageEvents.filter { Self.periodKey($0.timestamp, monthly: true) == monthKey }),
      recentUsageEvents: Array(usageEvents.suffix(12).reversed())
    )
  }

  private func add(_ event: ClaudeUsageEvent, to buckets: inout [String: TokenBucket], key: String) {
    var bucket = buckets[key] ?? TokenBucket(key: key, label: Self.periodLabel(key))
    bucket.totalTokens += event.totalTokens
    bucket.inputTokens += event.inputTokens
    bucket.outputTokens += event.outputTokens
    bucket.cacheCreationInputTokens += event.cacheCreationInputTokens
    bucket.cacheReadInputTokens += event.cacheReadInputTokens
    bucket.calls += 1
    buckets[key] = bucket
  }

  private func topProjects(from events: [TokenUsageEvent], limit: Int = 3) -> [TokenProjectBucket] {
    var rows: [String: TokenProjectBucket] = [:]
    for event in events {
      let key = event.projectPath.isEmpty ? event.projectName : event.projectPath
      var bucket = rows[key] ?? TokenProjectBucket(projectName: event.projectName, projectPath: event.projectPath)
      bucket.totalTokens += event.totalTokens
      bucket.calls += 1
      rows[key] = bucket
    }
    return rows.values
      .sorted {
        if $0.totalTokens == $1.totalTokens { return $0.projectName < $1.projectName }
        return $0.totalTokens > $1.totalTokens
      }
      .prefix(limit)
      .map { $0 }
  }

  static func periodKey(_ date: Date, monthly: Bool) -> String {
    let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
    if monthly {
      return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }
    return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
  }

  static func periodLabel(_ key: String) -> String {
    let parts = key.split(separator: "-")
    if parts.count == 2 { return "\(parts[0])/\(parts[1])" }
    if parts.count == 3 { return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)" }
    return key
  }

  static func projectName(fromPath path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "未知项目".coreL10n }
    let name = URL(fileURLWithPath: trimmed).lastPathComponent
    return name.isEmpty ? trimmed : name
  }

  static func jsonStringField(_ key: String, in text: String) -> String? {
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
}

/// 读取已有 Claude OAuth 凭据并调用官方 usage 接口获取 5 小时 / 7 天窗口用量。
/// 只读凭据，绝不发起登录，绝不把凭据写入日志或输出。
final class ClaudeOAuthUsageSource: @unchecked Sendable {
  private let claudeHome: URL
  private let fileManager: FileManager
  private let cacheLock = NSLock()
  private var cachedEvents: [RateLimitEvent] = []
  private var cachedAt: Date?
  private var refreshInFlight = false
  private var failedUntil: Date?

  init(claudeHome: URL, fileManager: FileManager) {
    self.claudeHome = claudeHome
    self.fileManager = fileManager
  }

  // 余额变化缓慢，且官方 usage 接口对高频请求会 429。
  // 拉取节流到约 4 分钟一次（既避免限流，又把误差控制在 ~1-2%）。
  private static let fetchInterval: TimeInterval = 240

  func cachedRateLimitEvents(now: Date, maxAge: TimeInterval = 600) -> [RateLimitEvent] {
    cacheLock.lock()
    defer { cacheLock.unlock() }
    guard let cachedAt, now.timeIntervalSince(cachedAt) <= maxAge else { return [] }
    return cachedEvents
  }

  func freshRateLimitEvents(now: Date, maxAge: TimeInterval = fetchInterval) -> [RateLimitEvent] {
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

    let events = fetchEvents(now: now)
    storeFetchResult(events)
    return events
  }

  func refreshInBackground() {
    let now = Date()
    cacheLock.lock()
    if refreshInFlight || (failedUntil.map { $0 > now } ?? false) {
      cacheLock.unlock()
      return
    }
    if let cachedAt, now.timeIntervalSince(cachedAt) < Self.fetchInterval {
      cacheLock.unlock()
      return
    }
    refreshInFlight = true
    cacheLock.unlock()

    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      let events = self.fetchEvents(now: Date())
      self.storeFetchResult(events)
    }
  }

  private func storeFetchResult(_ events: [RateLimitEvent]) {
    cacheLock.lock()
    if events.isEmpty {
      // 拉取失败（多为 429 限流）：退避 2 分钟再试，期间继续沿用上次成功值
      failedUntil = Date().addingTimeInterval(120)
    } else {
      cachedEvents = events
      cachedAt = Date()
      failedUntil = nil
    }
    refreshInFlight = false
    cacheLock.unlock()
  }

  private func fetchEvents(now: Date) -> [RateLimitEvent] {
    guard let accessToken = readAccessToken(),
          let url = URL(string: "https://api.anthropic.com/api/oauth/usage")
    else { return [] }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 12
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let semaphore = DispatchSemaphore(value: 0)
    let box = ClaudeFetchBox()
    URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { semaphore.signal() }
      guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return }
      box.set(object)
    }.resume()
    _ = semaphore.wait(timeout: .now() + 12)

    guard let object = box.value else { return [] }
    return events(from: object, now: now)
  }

  private func events(from object: [String: Any], now: Date) -> [RateLimitEvent] {
    var fiveHour = window(from: object["five_hour"] as? [String: Any], windowMinutes: 5 * 60)
    var sevenDay = window(from: object["seven_day"] as? [String: Any], windowMinutes: 7 * 24 * 60)
    var limitName = "Claude 账号额度".coreL10n

    // 2026-07 起接口提供 limits 数组：session / weekly_all / weekly_scoped（模型专属周限，如 Fable）。
    // 以它为准：内环取 session；外环取「最紧的周限」——全模型与模型专属谁用量高听谁的，
    // 否则模型专属限额快打满时码表还显示宽松，会误导。
    var labeledWindows: [LabeledWindow] = []
    if let limits = object["limits"] as? [[String: Any]] {
      var tightestWeekly: LimitWindow?
      var tightestScope: String?
      for limit in limits {
        let percentValue: Double?
        if let value = limit["percent"] as? Double { percentValue = value }
        else if let value = limit["percent"] as? Int { percentValue = Double(value) }
        else { percentValue = nil }
        guard let percent = percentValue else { continue }
        let used = max(0, min(100, percent))
        let resets = (limit["resets_at"] as? String).flatMap { ISO8601DateFormatter.claudeDate(from: $0) }
        let group = (limit["group"] as? String) ?? (limit["kind"] as? String) ?? ""
        let scopeName = (((limit["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String)

        if group == "session" {
          let window = LimitWindow(
            usedPercent: used, remainingPercent: max(0, 100 - used),
            windowMinutes: 5 * 60, resetsAt: resets
          )
          fiveHour = window
          labeledWindows.append(LabeledWindow(label: "5时".coreL10n, window: window, isHourScale: true))
        } else if group == "weekly" {
          let window = LimitWindow(
            usedPercent: used, remainingPercent: max(0, 100 - used),
            windowMinutes: 7 * 24 * 60, resetsAt: resets
          )
          if let scopeName, !scopeName.isEmpty {
            // 模型专属周限：0 用量时不占位，有用量才出现
            if used > 0 {
              labeledWindows.append(LabeledWindow(label: LC("周·%@", scopeName), window: window, isHourScale: false))
            }
          } else {
            labeledWindows.append(LabeledWindow(label: "周·全部".coreL10n, window: window, isHourScale: false))
          }
          if tightestWeekly == nil || window.usedPercent > tightestWeekly!.usedPercent {
            tightestWeekly = window
            tightestScope = scopeName
          }
        }
      }
      if let tightestWeekly {
        sevenDay = tightestWeekly
        if let tightestScope, !tightestScope.isEmpty {
          limitName = LC("Claude 账号额度（%@ 周限更紧）", tightestScope)
        }
      }
    }

    guard fiveHour != nil || sevenDay != nil else { return [] }

    return [
      RateLimitEvent(
        timestamp: now,
        sourceName: "Claude usage 接口".coreL10n,
        sourcePath: "api/oauth/usage",
        limitID: "claude",
        limitName: limitName,
        primary: fiveHour,
        secondary: sevenDay,
        windows: labeledWindows
      )
    ]
  }

  private func window(from object: [String: Any]?, windowMinutes: Double) -> LimitWindow? {
    guard let object else { return nil }
    let utilization: Double
    if let value = object["utilization"] as? Double {
      utilization = value
    } else if let value = object["utilization"] as? Int {
      utilization = Double(value)
    } else {
      return nil
    }
    let used = max(0, min(100, utilization))
    let resetsAt: Date?
    if let resetString = object["resets_at"] as? String {
      resetsAt = ISO8601DateFormatter.claudeDate(from: resetString)
    } else if let resetSeconds = object["resets_at"] as? Double, resetSeconds > 0 {
      resetsAt = Date(timeIntervalSince1970: resetSeconds)
    } else {
      resetsAt = nil
    }
    return LimitWindow(
      usedPercent: used,
      remainingPercent: max(0, min(100, 100 - used)),
      windowMinutes: windowMinutes,
      resetsAt: resetsAt
    )
  }

  private struct ClaudeOAuthCredentials {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?

    var isAccessTokenValid: Bool {
      guard let accessToken, !accessToken.isEmpty else { return false }
      guard let expiresAt else { return true }
      return expiresAt > Date().addingTimeInterval(60)
    }
  }

  private func readAccessToken() -> String? {
    // 凭据来源只有两个：自有缓存（续期在此滚动）与 Claude 的明文凭据文件（如存在）。
    // 钥匙串访问已从本程序中彻底移除——SecItemCopyMatching 会触发系统授权弹框，
    // 历史上造成过五次密码风暴。链断裂时的恢复统一走外部脚本
    // （修复Claude连接.command，用 Apple 签名的 security 工具读取，永不弹框）。
    let cached = readRefreshCache()
    if let cached, cached.isAccessTokenValid {
      return cached.accessToken
    }
    if let refreshToken = cached?.refreshToken {
      switch renewAccessTokenDetailed(refreshToken: refreshToken) {
      case .success(let renewed):
        writeRefreshCache(renewed)
        return renewed.accessToken
      case .networkFailure:
        return nil // 断网/超时：与凭据无关，等下轮重试
      case .authRejected:
        break // 链死，试凭据文件
      }
    }
    // 明文凭据文件（部分安装形态存在；纯文件读取，无任何系统弹框）
    if let credentials = readCredentialsFileCredentials() {
      if credentials.isAccessTokenValid {
        writeRefreshCache(credentials)
        return credentials.accessToken
      }
      if let refreshToken = credentials.refreshToken,
         refreshToken != cached?.refreshToken,
         let renewed = renewAccessToken(refreshToken: refreshToken) {
        writeRefreshCache(renewed)
        return renewed.accessToken
      }
    }
    return nil
  }

  private var refreshCacheURL: URL {
    fileManager.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexBalanceDashboard/claude-oauth-cache.json")
  }

  private func readRefreshCache() -> ClaudeOAuthCredentials? {
    guard let data = try? Data(contentsOf: refreshCacheURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return ClaudeOAuthCredentials(
      accessToken: object["accessToken"] as? String,
      refreshToken: object["refreshToken"] as? String,
      expiresAt: (object["expiresAtEpoch"] as? Double).map { Date(timeIntervalSince1970: $0) }
    )
  }

  private func writeRefreshCache(_ credentials: ClaudeOAuthCredentials) {
    var object: [String: Any] = [:]
    if let accessToken = credentials.accessToken { object["accessToken"] = accessToken }
    if let refreshToken = credentials.refreshToken { object["refreshToken"] = refreshToken }
    if let expiresAt = credentials.expiresAt { object["expiresAtEpoch"] = expiresAt.timeIntervalSince1970 }
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    try? fileManager.createDirectory(
      at: refreshCacheURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try? data.write(to: refreshCacheURL, options: [.atomic, .completeFileProtection])
  }

  private enum RenewOutcome {
    case success(ClaudeOAuthCredentials)
    case authRejected      // 4xx：refreshToken 已作废，链死
    case networkFailure    // 超时/断网/5xx：与凭据无关，稍后重试即可
  }

  private func renewAccessToken(refreshToken: String) -> ClaudeOAuthCredentials? {
    if case .success(let credentials) = renewAccessTokenDetailed(refreshToken: refreshToken) {
      return credentials
    }
    return nil
  }

  // 续期节流：续期失败后至少隔 5 分钟再试。
  // 没有这道闸，一旦 token 过期而续期又失败，每轮刷新都会打一次
  // token 接口，很快就会被 429 限流，然后陷入"越失败越请求"的循环。
  private static let renewThrottle = ClaudeRenewThrottle(interval: 300)

  private static func renewAllowed() -> Bool { renewThrottle.allowed() }

  private static func noteRenewResult(success: Bool) { renewThrottle.note(success: success) }

  private func renewAccessTokenDetailed(refreshToken: String) -> RenewOutcome {
    guard Self.renewAllowed() else { return .networkFailure }
    guard let url = URL(string: "https://console.anthropic.com/v1/oauth/token") else { return .networkFailure }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 12
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload: [String: Any] = [
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return .networkFailure }
    request.httpBody = body

    let semaphore = DispatchSemaphore(value: 0)
    let box = ClaudeFetchBox()
    let statusBox = ClaudeStatusBox()
    URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { semaphore.signal() }
      if let httpResponse = response as? HTTPURLResponse {
        statusBox.set(httpResponse.statusCode)
      }
      guard let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let data,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
      else { return }
      box.set(object)
    }.resume()
    _ = semaphore.wait(timeout: .now() + 12)

    if let object = box.value,
       let accessToken = object["access_token"] as? String,
       !accessToken.isEmpty {
      let expiresIn = (object["expires_in"] as? Double) ?? 3600
      Self.noteRenewResult(success: true)
      return .success(ClaudeOAuthCredentials(
        accessToken: accessToken,
        refreshToken: (object["refresh_token"] as? String) ?? refreshToken,
        expiresAt: Date().addingTimeInterval(expiresIn)
      ))
    }
    // 凭据被拒（链死）只有 400/401/403 三种；
    // 429 是限流、408 是超时，都属于"稍后再试"，绝不能当成链死——
    // 误判会让 App 放弃续期并退回不存在的明文文件，Claude 侧就此卡在过期值上。
    let code = statusBox.value
    Self.noteRenewResult(success: false)
    switch code {
    case 400, 401, 403:
      return .authRejected
    default:
      return .networkFailure
    }
  }

  private func readCredentialsFileCredentials() -> ClaudeOAuthCredentials? {
    let file = claudeHome.appendingPathComponent(".credentials.json")
    guard fileManager.fileExists(atPath: file.path),
          let data = try? Data(contentsOf: file)
    else { return nil }
    return credentials(fromCredentialsData: data)
  }

  private func credentials(fromCredentialsData data: Data) -> ClaudeOAuthCredentials? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let oauth = object["claudeAiOauth"] as? [String: Any]
    else { return nil }
    let accessToken = (oauth["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let refreshToken = (oauth["refreshToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let expiresAt = (oauth["expiresAt"] as? Double).flatMap {
      $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil
    }
    guard accessToken != nil || refreshToken != nil else { return nil }
    return ClaudeOAuthCredentials(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: expiresAt
    )
  }
}

private final class ClaudeStatusBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0
  var value: Int {
    lock.lock(); defer { lock.unlock() }
    return storage
  }
  func set(_ value: Int) {
    lock.lock(); storage = value; lock.unlock()
  }
}

private final class ClaudeFetchBox: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [String: Any]?

  var value: [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func set(_ value: [String: Any]) {
    lock.lock()
    storage = value
    lock.unlock()
  }
}

extension ISO8601DateFormatter {
  static func claudeDate(from string: String) -> Date? {
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

private func claudeInteger(_ value: Any?) -> Int {
  if let value = value as? Int { return value }
  if let value = value as? Double { return Int(value) }
  if let value = value as? NSNumber { return value.intValue }
  return 0
}

private func claudeAsciiContains<S: Sequence>(_ haystack: S, _ needle: [UInt8]) -> Bool where S.Element == UInt8 {
  guard !needle.isEmpty else { return true }
  var matched = 0
  for byte in haystack {
    if byte == needle[matched] {
      matched += 1
      if matched == needle.count { return true }
    } else {
      matched = byte == needle[0] ? 1 : 0
    }
  }
  return false
}

/// 续期节流器：失败后指数退避，避免把自己打进（或长期困在）限流。
/// 间隔序列 5→10→20→40→60 分钟封顶；一次成功即复位。
/// 固定间隔不够用：Anthropic 的限流是按出口 IP 计的，
/// 每 5 分钟一次的持续叩门会让限流窗口迟迟不退。
private final class ClaudeRenewThrottle: @unchecked Sendable {
  private let lock = NSLock()
  private let base: TimeInterval
  private let cap: TimeInterval
  private var lastFailureAt: Date?
  private var consecutiveFailures = 0

  init(interval: TimeInterval, cap: TimeInterval = 3600) {
    self.base = interval
    self.cap = cap
  }

  private var currentDelay: TimeInterval {
    guard consecutiveFailures > 0 else { return 0 }
    let factor = pow(2.0, Double(consecutiveFailures - 1))
    return min(base * factor, cap)
  }

  func allowed() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard let last = lastFailureAt else { return true }
    return Date().timeIntervalSince(last) >= currentDelay
  }

  func note(success: Bool) {
    lock.lock(); defer { lock.unlock() }
    if success {
      lastFailureAt = nil
      consecutiveFailures = 0
    } else {
      lastFailureAt = Date()
      consecutiveFailures = min(consecutiveFailures + 1, 8)
    }
  }
}
