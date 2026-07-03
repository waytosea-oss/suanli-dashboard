import AppKit
import CodexBalanceCore

/// Touch Bar 会话小条目
struct RecentSessionChip {
  var title: String
  var tool: ToolID
  var isActive: Bool     // 最近 2 分钟内仍在写日志 = 进行中
  var modified: Date
}

/// 扫描 Claude / Codex 的本地会话日志，取最近会话的标题（只读，不写任何文件）。
/// 标题取首条用户消息的前若干字；取不到时退回项目目录名。结果缓存 20 秒。
final class RecentSessionScanner: @unchecked Sendable {
  static let shared = RecentSessionScanner()

  private let fileManager = FileManager.default
  private let lock = NSLock()
  private var cache: [RecentSessionChip] = []
  private var cachedAt: Date?
  private var titleCache: [String: (mtime: Date, title: String)] = [:]

  func recentSessions(limit: Int = 3, now: Date = Date()) -> [RecentSessionChip] {
    lock.lock()
    if let cachedAt, now.timeIntervalSince(cachedAt) < 20 {
      let result = Array(cache.prefix(limit))
      lock.unlock()
      return result
    }
    lock.unlock()

    var sessions: [RecentSessionChip] = []
    sessions += scanClaudeSessions()
    sessions += scanCodexSessions()
    sessions.sort { $0.modified > $1.modified }

    lock.lock()
    cache = sessions
    cachedAt = now
    let result = Array(sessions.prefix(limit))
    lock.unlock()
    return result
  }

  // MARK: - Claude：~/.claude/projects/<项目>/<会话>.jsonl

  private func scanClaudeSessions() -> [RecentSessionChip] {
    let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    var chips: [RecentSessionChip] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
      else { continue }
      let title = sessionTitle(for: url, modified: modified) ?? claudeProjectName(url)
      chips.append(RecentSessionChip(
        title: title,
        tool: .claude,
        isActive: Date().timeIntervalSince(modified) < 120,
        modified: modified
      ))
    }
    return chips
  }

  private func claudeProjectName(_ url: URL) -> String {
    // 项目目录名形如 "-Users-name-Downloads"，取最后一段
    let dir = url.deletingLastPathComponent().lastPathComponent
    return dir.split(separator: "-").last.map(String.init) ?? "Claude 会话".l10n
  }

  /// 首条用户消息的截断文本（读文件头部，按 mtime 缓存）
  private func sessionTitle(for url: URL, modified: Date) -> String? {
    lock.lock()
    if let cached = titleCache[url.path], cached.mtime == modified {
      lock.unlock()
      return cached.title
    }
    lock.unlock()

    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 128 * 1024),
          let text = String(data: data, encoding: .utf8)
    else { return nil }

    for line in text.split(separator: "\n") {
      guard line.contains(#""type":"user""#) || line.contains(#""type":"user_message""#),
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
      else { continue }

      var content: String?
      if let message = object["message"] as? [String: Any] {
        if let string = message["content"] as? String {
          content = string
        } else if let parts = message["content"] as? [[String: Any]] {
          content = parts.compactMap { $0["text"] as? String }.first
        }
      } else if let payload = object["payload"] as? [String: Any] {
        content = payload["message"] as? String
      }

      if let content {
        let cleaned = content
          .replacingOccurrences(of: "\n", with: " ")
          .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("<") else { continue }
        let title = String(cleaned.prefix(14))
        lock.lock()
        titleCache[url.path] = (modified, title)
        lock.unlock()
        return title
      }
    }
    return nil
  }

  // MARK: - Codex：~/.codex/sessions/**/rollout-*.jsonl

  private func scanCodexSessions() -> [RecentSessionChip] {
    let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    var chips: [RecentSessionChip] = []
    for case let url as URL in enumerator where url.pathExtension == "jsonl" {
      guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
            // Codex 历史会话很多，只看 3 天内的，避免全量扫
            Date().timeIntervalSince(modified) < 3 * 24 * 3600
      else { continue }
      let title = sessionTitle(for: url, modified: modified) ?? codexProjectName(url) ?? "Codex 会话".l10n
      chips.append(RecentSessionChip(
        title: title,
        tool: .codex,
        isActive: Date().timeIntervalSince(modified) < 120,
        modified: modified
      ))
    }
    return chips
  }

  private func codexProjectName(_ url: URL) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let data = try? handle.read(upToCount: 32 * 1024),
          let text = String(data: data, encoding: .utf8),
          let range = text.range(of: #""cwd":""#),
          let end = text[range.upperBound...].firstIndex(of: "\"")
    else { return nil }
    let cwd = String(text[range.upperBound..<end])
    return URL(fileURLWithPath: cwd).lastPathComponent
  }
}

/// 点击会话条目 → 激活对应工具的桌面 App（会话级深链官方未开放，激活 App 是最稳做法）
@MainActor
enum SessionAppLauncher {
  static func open(tool: ToolID) {
    let bundleIDs: [String]
    switch tool {
    case .claude: bundleIDs = ["com.anthropic.claudefordesktop"]
    case .codex: bundleIDs = ["com.openai.codex"]
    }
    for bundleID in bundleIDs {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return
      }
    }
  }
}
