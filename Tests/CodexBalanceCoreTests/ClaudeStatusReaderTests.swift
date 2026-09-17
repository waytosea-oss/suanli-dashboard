import Foundation
import Testing

@testable import CodexBalanceCore

@Suite("ClaudeStatusReader")
struct ClaudeStatusReaderTests {
  @Test func rateLimitingIsNotReportedAsNetworkFailure() {
    let limited = ClaudeOAuthUsageSource.requestFailureReason(statusCode: 429)
    #expect(limited.contains("429"))
    #expect(limited != ClaudeOAuthUsageSource.requestFailureReason(statusCode: 0))
    #expect(limited != ClaudeOAuthUsageSource.requestFailureReason(statusCode: 401))
    #expect(limited != ClaudeOAuthUsageSource.requestFailureReason(statusCode: 503))
  }

  private func makeClaudeHome() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("claude-reader-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("projects/-Users-test-Demo"),
      withIntermediateDirectories: true
    )
    return root
  }

  private func assistantLine(
    uuid: String,
    timestamp: String,
    input: Int,
    cacheCreation: Int,
    cacheRead: Int,
    output: Int,
    model: String = "claude-sonnet-4-6",
    cwd: String? = "/Users/test/Demo"
  ) -> String {
    let cwdField = cwd.map { "\"cwd\":\"\($0)\"," } ?? ""
    return """
    {"type":"assistant",\(cwdField)"uuid":"\(uuid)","timestamp":"\(timestamp)","message":{"model":"\(model)","usage":{"input_tokens":\(input),"cache_creation_input_tokens":\(cacheCreation),"cache_read_input_tokens":\(cacheRead),"output_tokens":\(output)}}}
    """
  }

  @Test func usageEventsAreParsedWithCacheReadIncluded() throws {
    let home = try makeClaudeHome()
    let sessionFile = home.appendingPathComponent("projects/-Users-test-Demo/a.jsonl")
    let lines = [
      assistantLine(uuid: "u1", timestamp: "2026-06-12T01:00:00.000Z", input: 3, cacheCreation: 100, cacheRead: 1000, output: 50),
      assistantLine(uuid: "u2", timestamp: "2026-06-12T01:01:00.000Z", input: 7, cacheCreation: 0, cacheRead: 2000, output: 40)
    ]
    try lines.joined(separator: "\n").write(to: sessionFile, atomically: true, encoding: .utf8)

    let reader = ClaudeStatusReader(claudeHome: home)
    let status = try reader.read(now: ISO8601DateFormatter().date(from: "2026-06-12T02:00:00Z")!)

    #expect(status.tokenStats.sampleCount == 2)
    // 口径含 cache_read：(3+100+1000+50) + (7+0+2000+40) = 3200
    #expect(status.tokenStats.todayTokens == 3200)
  }

  @Test func duplicateUUIDsAreDedupedAcrossFiles() throws {
    let home = try makeClaudeHome()
    let dir = home.appendingPathComponent("projects/-Users-test-Demo")
    let original = assistantLine(uuid: "shared", timestamp: "2026-06-12T01:00:00.000Z", input: 10, cacheCreation: 0, cacheRead: 0, output: 10)
    try original.write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
    // resume/fork 产生的新文件携带旧消息（相同 uuid），只能计一次
    let forked = [
      original,
      assistantLine(uuid: "fresh", timestamp: "2026-06-12T01:05:00.000Z", input: 5, cacheCreation: 0, cacheRead: 0, output: 5)
    ].joined(separator: "\n")
    try forked.write(to: dir.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)

    let reader = ClaudeStatusReader(claudeHome: home)
    let status = try reader.read(now: ISO8601DateFormatter().date(from: "2026-06-12T02:00:00Z")!)

    #expect(status.tokenStats.sampleCount == 2)
    #expect(status.tokenStats.todayTokens == 30)
  }

  @Test func syntheticPlaceholderRowsAreSkipped() throws {
    let home = try makeClaudeHome()
    let dir = home.appendingPathComponent("projects/-Users-test-Demo")
    let lines = [
      assistantLine(uuid: "real", timestamp: "2026-06-12T01:00:00.000Z", input: 10, cacheCreation: 0, cacheRead: 0, output: 10),
      assistantLine(uuid: "ghost", timestamp: "2026-06-12T01:01:00.000Z", input: 0, cacheCreation: 0, cacheRead: 0, output: 0, model: "<synthetic>")
    ]
    try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)

    let reader = ClaudeStatusReader(claudeHome: home)
    let status = try reader.read(now: ISO8601DateFormatter().date(from: "2026-06-12T02:00:00Z")!)

    #expect(status.tokenStats.sampleCount == 1)
    #expect(status.tokenStats.todayTokens == 20)
  }

  @Test func balanceIsUnavailableWithoutCredentials() throws {
    let home = try makeClaudeHome()
    let reader = ClaudeStatusReader(claudeHome: home)
    let status = try reader.read()
    // 没有 OAuth 来源时绝不虚构余额：main 必须为 nil（UI 显示「暂无数据」灰环）
    #expect(status.main == nil)
  }
}

@Suite("CodexUsageSyncStore 双工具命名")
struct SyncStoreToolNamingTests {
  @Test func deviceFileNamesCarryToolSuffix() {
    #expect(DeviceIdentity.fileName(deviceID: "macbook-pro", app: .codex) == "macbook-pro-codex.json")
    #expect(DeviceIdentity.fileName(deviceID: "mac-studio", app: .claude) == "mac-studio-claude.json")
  }

  @Test func claudeSnapshotsKeepCacheFieldsSeparate() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-store-tests-\(UUID().uuidString)")
    let store = CodexUsageSyncStore(
      syncRoot: root,
      app: .claude,
      deviceID: "macbook-pro",
      deviceName: "MacBook Pro",
      hostName: "test-host"
    )
    var stats = TokenStats()
    stats.todayTokens = 42
    let snapshot = store.makeSnapshot(from: stats)
    #expect(snapshot.app == ToolID.claude)
    #expect(snapshot.schemaVersion == 2)
    try store.write(snapshot)
    let written = root.appendingPathComponent("macbook-pro-claude.json")
    #expect(FileManager.default.fileExists(atPath: written.path))
    let text = try String(contentsOf: written, encoding: .utf8)
    #expect(text.contains("\"app\" : \"claude\""))
  }
}

@Suite("Claude OAuth recovery", .serialized)
struct ClaudeOAuthRecoveryTests {
  private final class State: @unchecked Sendable {
    var keychain: Data?
    var requests: [URLRequest] = []
  }

  private func oauth(_ token: String, expiry: TimeInterval, refresh: String = "refresh-new") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
      "accessToken": token, "refreshToken": refresh, "expiresAt": expiry * 1000
    ]])
  }

  private func fixture(cachedToken: String = "old", expiry: TimeInterval = 0) throws -> (URL, URL, State, URLSession) {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let cache = home.appendingPathComponent("cache.json")
    try JSONSerialization.data(withJSONObject: ["accessToken": cachedToken, "refreshToken": "refresh-old",
                                                "expiresAtEpoch": expiry]).write(to: cache)
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ClaudeMockProtocol.self]
    return (home, cache, State(), URLSession(configuration: config))
  }

  private static var usage: [String: Any] { ["five_hour": ["utilization": 21], "seven_day": ["utilization": 2]] }

  @Test func automaticallyImportsNewLoginBeforeRenewingExpiredCache() throws {
    let (home, cache, state, session) = try fixture()
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    state.keychain = try oauth("fresh-login", expiry: Date().timeIntervalSince1970 + 3600)
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      #expect(request.url?.path == "/api/oauth/usage")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fresh-login")
      return (200, [:], Self.usage)
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { state.keychain })
    #expect(reader.freshRateLimitEvents(now: Date()).first?.primary?.remainingPercent == 79)
    #expect(state.requests.count == 1)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
    #expect(saved["accessToken"] as? String == "fresh-login")
    let permissions = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
  }

  @Test func emptyOrOlderKeychainDoesNotOverwriteRenewedCache() throws {
    let now = Date()
    let (home, cache, state, session) = try fixture(cachedToken: "new-cache", expiry: now.timeIntervalSince1970 + 7200)
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    state.keychain = try oauth("older-keychain", expiry: now.timeIntervalSince1970 + 3600)
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-cache")
      return (200, [:], Self.usage)
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { state.keychain })
    #expect(!reader.freshRateLimitEvents(now: now).isEmpty)
    state.keychain = try oauth("", expiry: 0, refresh: "")
    #expect(!reader.freshRateLimitEvents(now: now.addingTimeInterval(241)).isEmpty)
    #expect(state.requests.count == 2)
  }

  @Test func credentialsFileIsUsedBeforeOldRefreshToken() throws {
    let (home, cache, state, session) = try fixture()
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    try oauth("file-login", expiry: Date().timeIntervalSince1970 + 3600)
      .write(to: home.appendingPathComponent(".credentials.json"))
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      #expect(request.url?.path == "/api/oauth/usage")
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer file-login")
      return (200, [:], Self.usage)
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { nil })
    #expect(!reader.freshRateLimitEvents(now: Date()).isEmpty)
    #expect(state.requests.count == 1)
  }

  @Test func unauthorizedUsageResyncsNewLoginWithoutRestart() throws {
    let now = Date()
    let (home, cache, state, session) = try fixture(expiry: now.timeIntervalSince1970 + 3600)
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    let newLogin = try oauth("replacement", expiry: now.timeIntervalSince1970 + 7200)
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      if state.requests.count == 1 {
        state.keychain = newLogin
        return (401, [:], [:])
      }
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement")
      return (200, [:], Self.usage)
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { state.keychain })
    #expect(!reader.freshRateLimitEvents(now: now).isEmpty)
    #expect(state.requests.count == 2)
  }

  @Test func expiredTokenRenewsAndSavesRotatedRefreshToken() throws {
    let (home, cache, state, session) = try fixture()
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      if request.url?.path == "/v1/oauth/token" {
        return (200, [:], ["access_token": "renewed", "refresh_token": "rotated", "expires_in": 3600])
      }
      #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer renewed")
      return (200, [:], Self.usage)
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { nil })
    #expect(!reader.freshRateLimitEvents(now: Date()).isEmpty)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as! [String: Any]
    #expect(saved["refreshToken"] as? String == "rotated")
    #expect(state.requests.count == 2)
  }

  @Test func rateLimitSurvivesRestartAndRespectsRetryAfter() throws {
    let now = Date()
    let (home, cache, state, session) = try fixture(expiry: now.timeIntervalSince1970 + 3600)
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      return (429, ["Retry-After": "900"], [:])
    }
    let first = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                      session: session, keychainRead: { nil })
    #expect(first.freshRateLimitEvents(now: now).isEmpty)
    let restarted = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                          session: session, keychainRead: { nil })
    #expect(restarted.freshRateLimitEvents(now: now.addingTimeInterval(600)).isEmpty)
    #expect(state.requests.count == 1)
    #expect(ClaudeOAuthUsageSource.lastFailureReason?.contains("429") == true)
  }

  @Test func loginChangeRecoversAfterRejectedRenewal() throws {
    let now = Date()
    let (home, cache, state, session) = try fixture()
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      return request.url?.path == "/v1/oauth/token" ? (400, [:], [:]) : (200, [:], Self.usage)
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { state.keychain })
    #expect(reader.freshRateLimitEvents(now: now).isEmpty)
    state.keychain = try oauth("new-login", expiry: now.timeIntervalSince1970 + 3600)
    #expect(!reader.freshRateLimitEvents(now: now.addingTimeInterval(121)).isEmpty)
    #expect(state.requests.count == 2)
    #expect(state.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer new-login")
  }
  @Test func unauthorizedThenRateLimitedKeepsActualRenewalError() throws {
    let now = Date()
    let (home, cache, state, session) = try fixture(expiry: now.timeIntervalSince1970 + 3600)
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      return request.url?.path == "/api/oauth/usage" ? (401, [:], [:]) : (429, ["Retry-After": "600"], [:])
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { nil })
    #expect(reader.freshRateLimitEvents(now: now).isEmpty)
    #expect(state.requests.count == 2)
    #expect(ClaudeOAuthUsageSource.lastFailureReason?.contains("429") == true)
  }

  @Test func newRefreshTokenDoesNotInheritRejectedTokenThrottle() throws {
    let now = Date()
    let (home, cache, state, session) = try fixture()
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      if state.requests.count == 1 { return (400, [:], [:]) }
      if request.url?.path == "/v1/oauth/token" {
        return (200, [:], ["access_token": "renewed-new-login", "refresh_token": "new-chain", "expires_in": 3600])
      }
      return (200, [:], Self.usage)
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { state.keychain })
    #expect(reader.freshRateLimitEvents(now: now).isEmpty)
    state.keychain = try oauth("expired-new-login", expiry: now.timeIntervalSince1970 - 1)
    #expect(!reader.freshRateLimitEvents(now: now.addingTimeInterval(121)).isEmpty)
    #expect(state.requests.count == 3)
  }

  @Test func repeatedUnauthorizedResponseDoesNotLoop() throws {
    let now = Date()
    let (home, cache, state, session) = try fixture(expiry: now.timeIntervalSince1970 + 3600)
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      if request.url?.path == "/v1/oauth/token" {
        return (200, [:], ["access_token": "also-rejected", "expires_in": 3600])
      }
      return (401, [:], [:])
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { nil })
    #expect(reader.freshRateLimitEvents(now: now).isEmpty)
    #expect(state.requests.count == 3)
    #expect(ClaudeOAuthUsageSource.lastFailureReason?.contains("claude auth login") == true)
  }

  @Test func temporaryFailureRetainsOnlyRecentSuccessfulUsage() throws {
    let now = Date()
    let (home, cache, state, session) = try fixture(expiry: now.timeIntervalSince1970 + 3600)
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      return state.requests.count == 1 ? (200, [:], Self.usage) : (429, ["Retry-After": "1800"], [:])
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { nil })
    #expect(!reader.freshRateLimitEvents(now: now).isEmpty)
    #expect(!reader.freshRateLimitEvents(now: now.addingTimeInterval(241)).isEmpty)
    #expect(reader.freshRateLimitEvents(now: now.addingTimeInterval(601)).isEmpty)
    #expect(state.requests.count == 2)
  }

  @Test func dedicatedServiceMatchesClaudeCodeConfigurationHash() {
    let home = URL(fileURLWithPath: "/tmp/suanli-test-auth")
    #expect(ClaudeKeychainReader.dedicatedService(configHome: home) == "Claude Code-credentials-8ec774c7")
    #expect(ClaudeKeychainReader.dedicatedService(configHome: home) != ClaudeKeychainReader.service)
  }

  @Test func renewalUsesOfficialScopeAndTimeout() throws {
    let (home, cache, state, session) = try fixture()
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { request in
      state.requests.append(request)
      if request.url?.path == "/v1/oauth/token" {
        #expect(request.timeoutInterval == 30)
        // URLProtocol exposes a body stream on some Foundation versions.
        let stream = request.httpBodyStream
        stream?.open()
        defer { stream?.close() }
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream {
          var buffer = [UInt8](repeating: 0, count: 2048)
          while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            bytes.append(contentsOf: buffer.prefix(n))
          }
        }
        let payload = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any]
        #expect((payload?["scope"] as? String)?.contains("user:profile") == true)
        #expect(payload?["grant_type"] as? String == "refresh_token")
        return (200, [:], ["access_token": "rotated", "refresh_token": "rotated-refresh", "expires_in": 3600])
      }
      return (200, [:], Self.usage)
    }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { nil })
    #expect(!reader.freshRateLimitEvents(now: Date()).isEmpty)
  }

  @Test func nonGrant400IsNotMisreportedAsRevokedLogin() throws {
    let (home, cache, _, session) = try fixture()
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { _ in (400, [:], ["error": "invalid_request"]) }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { nil })
    #expect(reader.freshRateLimitEvents(now: Date()).isEmpty)
    #expect(ClaudeOAuthUsageSource.lastFailureReason?.contains("400") == true)
    let metadata = try String(contentsOf: cache.appendingPathExtension("last-error"), encoding: .utf8)
    #expect(!metadata.contains("refresh-old"))
    #expect(!metadata.contains("accessToken"))
  }

  @Test func invalidGrantIsReportedAndRecordedWithoutSecrets() throws {
    let (home, cache, _, session) = try fixture()
    defer { try? FileManager.default.removeItem(at: home); session.invalidateAndCancel() }
    ClaudeMockProtocol.handler = { _ in (400, [:], ["error": "invalid_grant"]) }
    let reader = ClaudeOAuthUsageSource(claudeHome: home, fileManager: .default, cacheURL: cache,
                                       session: session, keychainRead: { nil })
    #expect(reader.freshRateLimitEvents(now: Date()).isEmpty)
    #expect(ClaudeOAuthUsageSource.lastFailureReason?.contains("claude auth login") == true)
    let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: cache.appendingPathExtension("last-error"))) as! [String: Any]
    #expect(metadata["invalidGrant"] as? Bool == true)
  }

}

private final class ClaudeMockProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, [String: String], [String: Any]))?
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    guard let handler = Self.handler else { return }
    let (status, headers, object) = handler(request)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
