import Foundation
import Security

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
    fileCache = fileCache.filter { activePaths.contains($0.key) }

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
    fileCache = fileCache.filter { activePaths.contains($0.key) }
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
    if let cached = fileCache[file.path],
       cached.modified == modified,
       cached.fileSize == fileSize {
      return cached.events
    }

    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }

    let usageNeedle = Array(#""usage""#.utf8)
    let assistantNeedle = Array(#""type":"assistant""#.utf8)
    var events: [ClaudeUsageEvent] = []
    var currentProjectPath = ""
    var currentProjectName = "未知项目"

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

    fileCache[file.path] = ParsedClaudeFile(modified: modified, fileSize: fileSize, events: events)
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
    guard !trimmed.isEmpty else { return "未知项目" }
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
    let fiveHour = window(from: object["five_hour"] as? [String: Any], windowMinutes: 5 * 60)
    let sevenDay = window(from: object["seven_day"] as? [String: Any], windowMinutes: 7 * 24 * 60)
    guard fiveHour != nil || sevenDay != nil else { return [] }

    return [
      RateLimitEvent(
        timestamp: now,
        sourceName: "Claude usage 接口",
        sourcePath: "api/oauth/usage",
        limitID: "claude",
        limitName: "Claude 账号额度",
        primary: fiveHour,
        secondary: sevenDay
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
    // 先用自己缓存的续期 token（不碰钥匙串，避免频繁触发钥匙串授权弹框）；
    // 只有缓存无效时才去读钥匙串/凭据文件。
    let cached = readRefreshCache()
    if let cached, cached.isAccessTokenValid {
      return cached.accessToken
    }
    let credentials = readKeychainCredentials() ?? readCredentialsFileCredentials()
    if let credentials, credentials.isAccessTokenValid {
      // 顺手写进自己的缓存：下次直接用缓存，几小时内不再读钥匙串
      writeRefreshCache(credentials)
      return credentials.accessToken
    }
    // refreshToken 是一次性轮换的：每次续期 Anthropic 会发一个新的 refreshToken。
    // 缓存里的（上次续期换回的）通常比钥匙串里的更新，故先试缓存、再退回钥匙串，
    // 兼顾「正常轮换」与「用户重新登录后钥匙串更新」两种情况；任一成功即写回缓存。
    var refreshCandidates: [String] = []
    if let token = cached?.refreshToken { refreshCandidates.append(token) }
    if let token = credentials?.refreshToken, !refreshCandidates.contains(token) {
      refreshCandidates.append(token)
    }
    for refreshToken in refreshCandidates {
      if let renewed = renewAccessToken(refreshToken: refreshToken) {
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

  private func renewAccessToken(refreshToken: String) -> ClaudeOAuthCredentials? {
    guard let url = URL(string: "https://console.anthropic.com/v1/oauth/token") else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 12
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let payload: [String: Any] = [
      "grant_type": "refresh_token",
      "refresh_token": refreshToken,
      "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    ]
    guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    request.httpBody = body

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

    guard let object = box.value,
          let accessToken = object["access_token"] as? String,
          !accessToken.isEmpty
    else { return nil }
    let expiresIn = (object["expires_in"] as? Double) ?? 3600
    return ClaudeOAuthCredentials(
      accessToken: accessToken,
      refreshToken: (object["refresh_token"] as? String) ?? refreshToken,
      expiresAt: Date().addingTimeInterval(expiresIn)
    )
  }

  private func readKeychainCredentials() -> ClaudeOAuthCredentials? {
    // 新版 Claude Code 把凭据存到带账号哈希后缀的服务名（如 "Claude Code-credentials-0a7b6ecb"），
    // 旧的无后缀条目可能残留且已过期。
    // 第 1 步：只列出服务名（不取数据，不需授权）；
    // 第 2 步：对每个候选单独取数据（kSecMatchLimitOne 会触发钥匙串授权弹框，用户点「始终允许」即长期授权），
    // 选其中 accessToken 未过期者；都过期则取 expiresAt 最新的（其 refreshToken 也最可能有效）。
    let listQuery: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll
    ]
    var listResult: CFTypeRef?
    guard SecItemCopyMatching(listQuery as CFDictionary, &listResult) == errSecSuccess,
          let items = listResult as? [[String: Any]]
    else {
      return readKeychainCredentials(service: "Claude Code-credentials")
    }

    var services: [String] = []
    for item in items {
      guard let service = item[kSecAttrService as String] as? String,
            service.hasPrefix("Claude Code-credentials")
      else { continue }
      services.append(service)
    }
    if services.isEmpty { services = ["Claude Code-credentials"] }
    // 带后缀的（新版）优先于无后缀旧条目，减少无谓的过期条目授权弹框
    services.sort { ($0.count, $0) > ($1.count, $1) }
    // 上次成功读到账号凭据的条目排最前：正常情况下只触碰这一个条目，
    // 其余条目（可能只装 MCP 插件授权）不再逐个读取，避免连环授权弹框
    if let lastGood = UserDefaults.standard.string(forKey: Self.lastGoodServiceKey),
       let index = services.firstIndex(of: lastGood) {
      services.remove(at: index)
      services.insert(lastGood, at: 0)
    }

    var candidates: [ClaudeOAuthCredentials] = []
    for service in services {
      if let parsed = readKeychainCredentials(service: service) {
        candidates.append(parsed)
        if parsed.isAccessTokenValid {
          UserDefaults.standard.set(service, forKey: Self.lastGoodServiceKey)
          return parsed
        }
      }
    }
    if candidates.isEmpty { return nil }
    return candidates.max { lhs, rhs in
      let l = lhs.expiresAt ?? .distantPast
      let r = rhs.expiresAt ?? .distantPast
      if l == r { return (rhs.refreshToken != nil) && (lhs.refreshToken == nil) }
      return l < r
    }
  }

  private static let lastGoodServiceKey = "claudeKeychainLastGoodService"

  private func readKeychainCredentials(service: String) -> ClaudeOAuthCredentials? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else { return nil }
    return credentials(fromCredentialsData: data)
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
