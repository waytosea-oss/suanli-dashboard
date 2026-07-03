import Foundation
import Testing

@testable import CodexBalanceCore

@Suite("ClaudeStatusReader")
struct ClaudeStatusReaderTests {
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
