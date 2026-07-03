import Testing
import Foundation
@testable import CodexBalanceCore

@Suite
struct CodexStatusReaderTests {
  @Test
  func readsCodexRateLimitsAndTokenStats() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions/2026/05")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let primaryReset = now.addingTimeInterval(47 * 60)
    let secondaryReset = now.addingTimeInterval((3 * 24 + 20) * 60 * 60)
    let file = sessions.appendingPathComponent("session.jsonl")
    let lines = [
      tokenEventLine(
        timestamp: "2026-05-19T09:52:00.000Z",
        limitID: "other",
        primaryUsed: 91,
        secondaryUsed: 87,
        primaryReset: primaryReset,
        secondaryReset: secondaryReset,
        totalTokens: 1000,
        lastTokens: 100
      ),
      tokenEventLine(
        timestamp: "2026-05-19T09:58:00Z",
        limitID: "codex",
        primaryUsed: 4,
        secondaryUsed: 55,
        primaryReset: primaryReset,
        secondaryReset: secondaryReset,
        totalTokens: 1800,
        lastTokens: 800
      )
    ].joined(separator: "\n")
    try lines.write(to: file, atomically: true, encoding: .utf8)

    let reader = CodexStatusReader(codexHome: root, maxSessionFiles: 20)
    let status = try reader.read(now: now)

    #expect(status.scannedFiles == 1)
    #expect(status.eventCount == 2)
    #expect(status.main?.limitID == "codex")
    #expect(status.main?.primary?.remainingPercent == 96)
    #expect(status.main?.secondary?.remainingPercent == 45)
    #expect(status.tokenStats.todayTokens == 900)
    #expect(status.tokenStats.monthTokens == 900)
    #expect(status.tokenStats.last7DaysTokens == 900)
    #expect(status.tokenStats.sampleCount == 2)
  }

  @Test
  func usageSyncStoreWritesAndReadsDeviceSnapshots() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let macBookStore = CodexUsageSyncStore(
      syncRoot: root,
      deviceID: "macbook-pro",
      deviceName: "MacBook Pro",
      hostName: "demo-mbp"
    )
    let macStudioStore = CodexUsageSyncStore(
      syncRoot: root,
      deviceID: "mac-studio",
      deviceName: "Mac Studio",
      hostName: "demo-studio"
    )

    try macBookStore.write(macBookStore.makeSnapshot(
      from: TokenStats(
        todayTokens: 120,
        monthTokens: 220,
        sampleCount: 2,
        daily: [TokenBucket(key: "2026-05-19", label: "5/19", totalTokens: 120, calls: 2)],
        monthly: [TokenBucket(key: "2026-05", label: "5月", totalTokens: 220, calls: 2)]
      ),
      now: now
    ))
    try macStudioStore.write(macStudioStore.makeSnapshot(
      from: TokenStats(
        todayTokens: 300,
        monthTokens: 500,
        sampleCount: 3,
        daily: [TokenBucket(key: "2026-05-19", label: "5/19", totalTokens: 300, calls: 3)],
        monthly: [TokenBucket(key: "2026-05", label: "5月", totalTokens: 500, calls: 3)]
      ),
      now: now.addingTimeInterval(10)
    ))

    let snapshots = macStudioStore.readSnapshots()

    #expect(Set(snapshots.map(\.deviceID)) == ["macbook-pro", "mac-studio"])
    #expect(snapshots.first { $0.deviceID == "macbook-pro" }?.todayTokens == 120)
    #expect(snapshots.first { $0.deviceID == "mac-studio" }?.monthTokens == 500)
  }

  @Test
  func testCodexHomeReaderDoesNotEnableICloudDeviceSync() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let file = sessions.appendingPathComponent("session.jsonl")
    try tokenEventLine(
      timestamp: "2026-05-19T09:58:00Z",
      limitID: "codex",
      primaryUsed: 4,
      secondaryUsed: 55,
      primaryReset: now.addingTimeInterval(60 * 60),
      secondaryReset: now.addingTimeInterval(24 * 60 * 60),
      totalTokens: 1800,
      lastTokens: 800
    ).write(to: file, atomically: true, encoding: .utf8)

    let status = try CodexStatusReader(codexHome: root).read(now: now)

    #expect(status.tokenStats.deviceUsage.isEmpty)
  }

  @Test
  func expiredResetKeepsLastRecordedPercentWithoutGuessing() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let file = sessions.appendingPathComponent("session.jsonl")
    let line = tokenEventLine(
      timestamp: "2026-05-19T04:50:00Z",
      limitID: "codex",
      primaryUsed: 72,
      secondaryUsed: 31,
      primaryReset: now.addingTimeInterval(-10 * 60),
      secondaryReset: now.addingTimeInterval(2 * 24 * 60 * 60),
      totalTokens: 500,
      lastTokens: 500
    )
    try line.write(to: file, atomically: true, encoding: .utf8)

    let status = try CodexStatusReader(codexHome: root).read(now: now)

    #expect(status.main?.primary?.remainingPercent == 28)
    #expect(status.main?.primary?.usedPercent == 72)
    #expect(status.main?.primary?.inferredReset == false)
    #expect(status.main?.secondary?.remainingPercent == 69)
  }

  @Test
  func directRemainingPercentTakesPriorityWhenPresent() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let file = sessions.appendingPathComponent("remaining.jsonl")
    let line = """
    {"timestamp":"2026-05-19T09:58:00Z","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","limit_name":"Codex","primary":{"used_percent":20,"remaining_percent":73,"window_minutes":300,"resets_at":\(now.addingTimeInterval(60 * 60).timeIntervalSince1970)},"secondary":{"used_percent":50,"available_percent":44,"window_minutes":10080,"resets_at":\(now.addingTimeInterval(24 * 60 * 60).timeIntervalSince1970)}},"info":{"total_token_usage":{"total_tokens":1000},"last_token_usage":{"total_tokens":1000}}}}
    """
    try line.write(to: file, atomically: true, encoding: .utf8)

    let status = try CodexStatusReader(codexHome: root).read(now: now)

    #expect(status.main?.primary?.remainingPercent == 73)
    #expect(status.main?.primary?.usedPercent == 20)
    #expect(status.main?.secondary?.remainingPercent == 44)
  }

  @Test
  func latestRateLimitSelectionDoesNotLetStaleLiveCacheOverwriteLogs() throws {
    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let logEvent = RateLimitEvent(
      timestamp: now,
      sourceName: "session.jsonl",
      sourcePath: "/tmp/session.jsonl",
      limitID: "codex",
      limitName: "Codex",
      primary: LimitWindow(usedPercent: 27, remainingPercent: 73, windowMinutes: 300, resetsAt: nil),
      secondary: LimitWindow(usedPercent: 55, remainingPercent: 45, windowMinutes: 10080, resetsAt: nil)
    )
    let staleLiveEvent = RateLimitEvent(
      timestamp: now.addingTimeInterval(-30),
      sourceName: "Codex app-server",
      sourcePath: "account/rateLimits/read",
      limitID: "codex",
      limitName: "Codex",
      primary: LimitWindow(usedPercent: 20, remainingPercent: 80, windowMinutes: 300, resetsAt: nil),
      secondary: LimitWindow(usedPercent: 54, remainingPercent: 46, windowMinutes: 10080, resetsAt: nil)
    )

    let latest = CodexStatusReader.latestByLimit(from: [logEvent, staleLiveEvent])

    #expect(latest["codex"]?.primary?.remainingPercent == 73)
    #expect(latest["codex"]?.secondary?.remainingPercent == 45)
  }

  @Test
  func latestRateLimitSelectionKeepsFreshStatusLogOverNearlyImmediateLiveRead() throws {
    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let statusLogEvent = RateLimitEvent(
      timestamp: now,
      sourceName: "session.jsonl",
      sourcePath: "/tmp/session.jsonl",
      limitID: "codex",
      limitName: "Codex",
      primary: LimitWindow(usedPercent: 27, remainingPercent: 73, windowMinutes: 300, resetsAt: nil),
      secondary: LimitWindow(usedPercent: 55, remainingPercent: 45, windowMinutes: 10080, resetsAt: nil)
    )
    let liveEvent = RateLimitEvent(
      timestamp: now.addingTimeInterval(5),
      sourceName: "Codex app-server",
      sourcePath: "account/rateLimits/read",
      limitID: "codex",
      limitName: "Codex",
      primary: LimitWindow(usedPercent: 20, remainingPercent: 80, windowMinutes: 300, resetsAt: nil),
      secondary: LimitWindow(usedPercent: 54, remainingPercent: 46, windowMinutes: 10080, resetsAt: nil)
    )

    let latest = CodexStatusReader.latestByLimit(from: [statusLogEvent, liveEvent])

    #expect(latest["codex"]?.primary?.remainingPercent == 73)
    #expect(latest["codex"]?.secondary?.remainingPercent == 45)
  }

  @Test
  func tokenUsageCanBeGroupedByInferredWorkType() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let presentationFile = sessions.appendingPathComponent("presentation.jsonl")
    let codingFile = sessions.appendingPathComponent("coding.jsonl")
    let presentationLines = [
      #"{"timestamp":"2026-05-19T09:50:00Z","payload":{"type":"user_message","text":"帮我做一份 PPT 幻灯片演示文稿"}}"#,
      tokenEventLine(
        timestamp: "2026-05-19T09:51:00Z",
        limitID: "codex",
        primaryUsed: 10,
        secondaryUsed: 20,
        primaryReset: now.addingTimeInterval(60 * 60),
        secondaryReset: now.addingTimeInterval(24 * 60 * 60),
        totalTokens: 100,
        lastTokens: 100
      )
    ].joined(separator: "\n")
    let codingLines = [
      #"{"timestamp":"2026-05-19T09:55:00Z","payload":{"type":"function_call","role":"assistant","text":"apply_patch Sources/App.swift swift test 编程修复"}}"#,
      tokenEventLine(
        timestamp: "2026-05-19T09:56:00Z",
        limitID: "codex",
        primaryUsed: 11,
        secondaryUsed: 21,
        primaryReset: now.addingTimeInterval(60 * 60),
        secondaryReset: now.addingTimeInterval(24 * 60 * 60),
        totalTokens: 300,
        lastTokens: 200
      )
    ].joined(separator: "\n")
    try presentationLines.write(to: presentationFile, atomically: true, encoding: .utf8)
    try codingLines.write(to: codingFile, atomically: true, encoding: .utf8)

    let status = try CodexStatusReader(codexHome: root).read(now: now)
    let categories = Dictionary(uniqueKeysWithValues: status.tokenStats.categoryBreakdown.map { ($0.category, $0.totalTokens) })

    #expect(categories[.presentation] == 100)
    #expect(categories[.coding] == 200)
  }

  @Test
  func tokenUsageCanBeGroupedByProjectTopThree() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let file = sessions.appendingPathComponent("projects.jsonl")
    let lines = [
      turnContextLine(cwd: "/Users/example/Alpha"),
      tokenEventLine(
        timestamp: "2026-05-19T09:01:00Z",
        limitID: "codex",
        primaryUsed: 10,
        secondaryUsed: 20,
        primaryReset: now.addingTimeInterval(60 * 60),
        secondaryReset: now.addingTimeInterval(24 * 60 * 60),
        totalTokens: 100,
        lastTokens: 100
      ),
      turnContextLine(cwd: "/Users/example/Beta"),
      tokenEventLine(
        timestamp: "2026-05-19T09:02:00Z",
        limitID: "codex",
        primaryUsed: 11,
        secondaryUsed: 21,
        primaryReset: now.addingTimeInterval(60 * 60),
        secondaryReset: now.addingTimeInterval(24 * 60 * 60),
        totalTokens: 500,
        lastTokens: 400
      ),
      turnContextLine(cwd: "/Users/example/Gamma"),
      tokenEventLine(
        timestamp: "2026-05-19T09:03:00Z",
        limitID: "codex",
        primaryUsed: 12,
        secondaryUsed: 22,
        primaryReset: now.addingTimeInterval(60 * 60),
        secondaryReset: now.addingTimeInterval(24 * 60 * 60),
        totalTokens: 800,
        lastTokens: 300
      ),
      turnContextLine(cwd: "/Users/example/Delta"),
      tokenEventLine(
        timestamp: "2026-05-19T09:04:00Z",
        limitID: "codex",
        primaryUsed: 13,
        secondaryUsed: 23,
        primaryReset: now.addingTimeInterval(60 * 60),
        secondaryReset: now.addingTimeInterval(24 * 60 * 60),
        totalTokens: 1000,
        lastTokens: 200
      )
    ].joined(separator: "\n")
    try lines.write(to: file, atomically: true, encoding: .utf8)

    let status = try CodexStatusReader(codexHome: root).read(now: now)

    #expect(status.tokenStats.todayTopProjects.map(\.projectName) == ["Beta", "Gamma", "Delta"])
    #expect(status.tokenStats.todayTopProjects.map(\.totalTokens) == [400, 300, 200])
    #expect(status.tokenStats.monthTopProjects.map(\.projectName) == ["Beta", "Gamma", "Delta"])
  }

  @Test
  func projectTopThreeUsesCodexWorkspaceLabelWhenAvailable() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let cwd = "/Users/example/New project"
    try workspaceLabelsJSON([cwd: "问各种杂问题"])
      .write(to: root.appendingPathComponent(".codex-global-state.json"), atomically: true, encoding: .utf8)

    let file = sessions.appendingPathComponent("renamed-project.jsonl")
    let lines = [
      turnContextLine(cwd: cwd),
      tokenEventLine(
        timestamp: "2026-05-19T09:01:00Z",
        limitID: "codex",
        primaryUsed: 10,
        secondaryUsed: 20,
        primaryReset: now.addingTimeInterval(60 * 60),
        secondaryReset: now.addingTimeInterval(24 * 60 * 60),
        totalTokens: 100,
        lastTokens: 100
      )
    ].joined(separator: "\n")
    try lines.write(to: file, atomically: true, encoding: .utf8)

    let reader = CodexStatusReader(codexHome: root)
    var status = try reader.read(now: now)

    #expect(status.tokenStats.todayTopProjects.first?.projectName == "问各种杂问题")
    #expect(status.tokenStats.todayTopProjects.first?.projectPath == cwd)

    try workspaceLabelsJSON([cwd: "后来改的新名字"])
      .write(to: root.appendingPathComponent(".codex-global-state.json"), atomically: true, encoding: .utf8)
    status = try reader.read(now: now)

    #expect(status.tokenStats.todayTopProjects.first?.projectName == "后来改的新名字")
  }

  @Test
  func developerSkillDescriptionsDoNotInflateDocumentUsage() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let file = sessions.appendingPathComponent("session.jsonl")
    let lines = [
      #"{"timestamp":"2026-05-19T09:48:00Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"documents spreadsheets docx excel 表格 文档"}]}}"#,
      #"{"timestamp":"2026-05-19T09:50:00Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"帮我做一份 PPT，结构像正式 presentation deck"}]}}"#,
      tokenEventLine(
        timestamp: "2026-05-19T09:51:00Z",
        limitID: "codex",
        primaryUsed: 10,
        secondaryUsed: 20,
        primaryReset: now.addingTimeInterval(60 * 60),
        secondaryReset: now.addingTimeInterval(24 * 60 * 60),
        totalTokens: 100,
        lastTokens: 100
      )
    ].joined(separator: "\n")
    try lines.write(to: file, atomically: true, encoding: .utf8)

    let status = try CodexStatusReader(codexHome: root).read(now: now)
    let categories = Dictionary(uniqueKeysWithValues: status.tokenStats.categoryBreakdown.map { ($0.category, $0.totalTokens) })

    #expect(categories[.presentation] == 100)
    #expect(categories[.documents] == 0)
  }

  @Test
  func readerKeepsCachedEventsWhenSessionFileAppends() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let file = sessions.appendingPathComponent("session.jsonl")
    let firstLine = tokenEventLine(
      timestamp: "2026-05-19T09:51:00Z",
      limitID: "codex",
      primaryUsed: 10,
      secondaryUsed: 20,
      primaryReset: now.addingTimeInterval(60 * 60),
      secondaryReset: now.addingTimeInterval(24 * 60 * 60),
      totalTokens: 100,
      lastTokens: 100
    )
    try firstLine.write(to: file, atomically: true, encoding: .utf8)

    let reader = CodexStatusReader(codexHome: root)
    #expect(try reader.read(now: now).tokenStats.sampleCount == 1)

    let appendedLine = "\n" + tokenEventLine(
      timestamp: "2026-05-19T09:56:00Z",
      limitID: "codex",
      primaryUsed: 11,
      secondaryUsed: 21,
      primaryReset: now.addingTimeInterval(60 * 60),
      secondaryReset: now.addingTimeInterval(24 * 60 * 60),
      totalTokens: 200,
      lastTokens: 100
    )
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(appendedLine.utf8))

    let status = try reader.read(now: now)
    #expect(status.tokenStats.sampleCount == 2)
    #expect(status.tokenStats.todayTokens == 200)
  }

  @Test
  func activeSessionReparsesWholeFileWhenAppendCompletesTokenLine() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let sessions = root.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

    let now = try #require(makeDate("2026-05-19T10:00:00Z"))
    let file = sessions.appendingPathComponent("active-session.jsonl")
    let fullLine = tokenEventLine(
      timestamp: "2026-05-19T09:59:00Z",
      limitID: "codex",
      primaryUsed: 11,
      secondaryUsed: 21,
      primaryReset: now.addingTimeInterval(60 * 60),
      secondaryReset: now.addingTimeInterval(24 * 60 * 60),
      totalTokens: 600,
      lastTokens: 600
    )
    let splitIndex = try #require(fullLine.range(of: #""type":"token_count""#)?.lowerBound)
    try String(fullLine[..<splitIndex]).write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)

    let reader = CodexStatusReader(codexHome: root)
    #expect(try reader.read(now: now).tokenStats.sampleCount == 0)

    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(String(fullLine[splitIndex...]).utf8))
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(1)], ofItemAtPath: file.path)

    let status = try reader.read(now: now.addingTimeInterval(1))
    #expect(status.tokenStats.sampleCount == 1)
    #expect(status.tokenStats.todayTokens == 600)
  }

  @Test
  func missingSessionsDirectoryReturnsEmptyStatus() throws {
    let root = try makeTemporaryCodexHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let status = try CodexStatusReader(codexHome: root).read(now: Date())

    #expect(status.scannedFiles == 0)
    #expect(status.eventCount == 0)
    #expect(status.main == nil)
    #expect(status.tokenStats.daily.count > 0)
    #expect(status.tokenStats.monthly.count > 0)
  }
}

private func turnContextLine(cwd: String) -> String {
  #"{"timestamp":"2026-05-19T09:00:00Z","type":"turn_context","payload":{"cwd":"\#(cwd)"}}"#
}

private func workspaceLabelsJSON(_ labels: [String: String]) throws -> String {
  let object: [String: Any] = [
    "electron-persisted-atom-state": [
      "electron-workspace-root-labels": labels
    ]
  ]
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  return String(data: data, encoding: .utf8) ?? "{}"
}

private func makeTemporaryCodexHome() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("CodexBalanceTests-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func tokenEventLine(
  timestamp: String,
  limitID: String,
  primaryUsed: Double,
  secondaryUsed: Double,
  primaryReset: Date,
  secondaryReset: Date,
  totalTokens: Int,
  lastTokens: Int
) -> String {
  """
  {"timestamp":"\(timestamp)","payload":{"type":"token_count","rate_limits":{"limit_id":"\(limitID)","limit_name":"Codex","plan_type":"pro","primary":{"used_percent":\(primaryUsed),"window_minutes":300,"resets_at":\(primaryReset.timeIntervalSince1970)},"secondary":{"used_percent":\(secondaryUsed),"window_minutes":10080,"resets_at":\(secondaryReset.timeIntervalSince1970)}},"info":{"total_token_usage":{"total_tokens":\(totalTokens),"input_tokens":\(totalTokens / 2),"cached_input_tokens":0,"output_tokens":\(totalTokens / 2),"reasoning_output_tokens":0},"last_token_usage":{"total_tokens":\(lastTokens),"input_tokens":\(lastTokens / 2),"output_tokens":\(lastTokens / 2),"reasoning_output_tokens":0}}}}
  """
}

private func makeDate(_ string: String) -> Date? {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: string)
}
