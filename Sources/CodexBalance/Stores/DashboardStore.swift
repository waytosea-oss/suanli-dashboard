import AppKit
import CodexBalanceCore
import Foundation
import OSLog
import SwiftUI

private let dashboardLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "dev.codex.balance-dashboard",
  category: "DashboardStore"
)

enum DashboardToolTab: String, CaseIterable, Identifiable, Hashable {
  case codex
  case claude
  case all

  var id: String { rawValue }

  var title: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude"
    case .all: "全部"
    }
  }
}

enum CompactStyle: String, CaseIterable, Identifiable, Hashable {
  case rings
  case bars
  case badge

  var id: String { rawValue }

  var title: String {
    switch self {
    case .rings: "双环"
    case .bars: "长条"
    case .badge: "徽章"
    }
  }

  var subtitle: String {
    switch self {
    case .rings: "经典同心双环"
    case .bars: "双进度条，更省空间"
    case .badge: "极简数字，占用最小"
    }
  }
}

enum CompactSizeMode: String, CaseIterable, Identifiable, Hashable {
  case standard
  case mini

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: "标准"
    case .mini: "迷你"
    }
  }
}

enum RefreshIntervalOption: String, CaseIterable, Identifiable, Hashable {
  case five = "5"
  case ten = "10"
  case thirty = "30"

  var id: String { rawValue }

  var title: String { "\(rawValue)s" }

  var seconds: TimeInterval {
    TimeInterval(Double(rawValue) ?? 5)
  }
}

@MainActor
final class DashboardStore: ObservableObject {
  @Published private(set) var status: CodexStatus?
  @Published private(set) var claudeStatus: CodexStatus?
  @Published var selectedToolTab: DashboardToolTab {
    didSet {
      UserDefaults.standard.set(selectedToolTab.rawValue, forKey: "selectedToolTab")
    }
  }
  @Published private(set) var lastRefresh: Date?
  @Published private(set) var errorMessage: String?
  @Published private(set) var isLoading = false
  @Published var isCompact = true {
    didSet { applyWindowVisibility() }
  }
  @Published var compactSizeMode: CompactSizeMode {
    didSet {
      UserDefaults.standard.set(compactSizeMode.rawValue, forKey: "compactSizeMode")
    }
  }
  @Published var compactStyle: CompactStyle {
    didSet {
      UserDefaults.standard.set(compactStyle.rawValue, forKey: "compactStyle")
    }
  }
  @Published var autoDodgeEnabled: Bool {
    didSet {
      UserDefaults.standard.set(autoDodgeEnabled, forKey: "autoDodgeEnabled")
    }
  }
  @Published var touchBarEnabled: Bool {
    didSet {
      UserDefaults.standard.set(touchBarEnabled, forKey: "touchBarEnabled")
      TouchBarStripController.shared.setEnabled(touchBarEnabled)
      TouchBarStripController.shared.setKeepAwake(touchBarKeepAwake && touchBarEnabled)
      updateTouchBar()
      applyWindowVisibility()
    }
  }

  /// Touch Bar 常驻开启后，折叠态浮窗自动隐身（点 Touch Bar 项唤出展开面板）。
  /// 用 alpha+忽略鼠标而不是 orderOut，保证 SwiftUI 视图继续活着、定时刷新不中断。
  private func applyWindowVisibility() {
    guard let window = NSApp.windows.first(where: { $0.title == "算力码表" }) else { return }
    let shouldHide = touchBarEnabled && isCompact
    window.alphaValue = shouldHide ? 0 : 1
    window.ignoresMouseEvents = shouldHide
    if !shouldHide {
      window.makeKeyAndOrderFront(nil)
    }
  }

  @Published var touchBarKeepAwake: Bool {
    didSet {
      UserDefaults.standard.set(touchBarKeepAwake, forKey: "touchBarKeepAwake")
      TouchBarStripController.shared.setKeepAwake(touchBarKeepAwake && touchBarEnabled)
    }
  }

  var touchBarSupported: Bool {
    TouchBarStripController.shared.isSupported
  }
  @Published var palette: DashboardPalette {
    didSet {
      UserDefaults.standard.set(palette.rawValue, forKey: DashboardPalette.userDefaultsKey)
    }
  }
  @Published var compactBackgroundOpacity: Double {
    didSet {
      let clamped = min(0.94, max(0.30, compactBackgroundOpacity))
      if compactBackgroundOpacity != clamped {
        compactBackgroundOpacity = clamped
        return
      }
      UserDefaults.standard.set(compactBackgroundOpacity, forKey: "compactBackgroundOpacity")
    }
  }
  @Published var refreshIntervalOption: RefreshIntervalOption {
    didSet {
      UserDefaults.standard.set(refreshIntervalOption.rawValue, forKey: "refreshIntervalOption")
      restartAutoRefreshIfNeeded()
    }
  }
  @Published private(set) var launchWithCodexEnabled = CodexWatcherManager.isEnabled()
  @Published private(set) var settingsMessage: String?

  private let fastReader = CodexStatusReader()
  private let fullReader = CodexStatusReader()
  private let claudeFastReader = ClaudeStatusReader()
  private let claudeFullReader = ClaudeStatusReader()
  private var refreshTimer: Timer?
  private var quickRetryTask: Task<Void, Never>?
  private var fullRefreshInFlight = false
  private var lastFullRefresh: Date?

  init() {
    let storedMode = UserDefaults.standard.string(forKey: "compactSizeMode")
    compactSizeMode = storedMode.flatMap(CompactSizeMode.init(rawValue:)) ?? .standard
    let storedStyle = UserDefaults.standard.string(forKey: "compactStyle")
    compactStyle = storedStyle.flatMap(CompactStyle.init(rawValue:)) ?? .rings
    autoDodgeEnabled = UserDefaults.standard.object(forKey: "autoDodgeEnabled") as? Bool ?? false
    touchBarEnabled = UserDefaults.standard.object(forKey: "touchBarEnabled") as? Bool ?? false
    touchBarKeepAwake = UserDefaults.standard.object(forKey: "touchBarKeepAwake") as? Bool ?? false
    let storedPalette = UserDefaults.standard.string(forKey: DashboardPalette.userDefaultsKey)
    palette = storedPalette.flatMap(DashboardPalette.init(rawValue:)) ?? .mintDawn
    let storedOpacity = UserDefaults.standard.object(forKey: "compactBackgroundOpacity") as? Double
    compactBackgroundOpacity = min(0.94, max(0.30, storedOpacity ?? 0.72))
    let storedTab = UserDefaults.standard.string(forKey: "selectedToolTab")
    selectedToolTab = storedTab.flatMap(DashboardToolTab.init(rawValue:)) ?? .codex
    let storedInterval = UserDefaults.standard.string(forKey: "refreshIntervalOption")
    refreshIntervalOption = storedInterval.flatMap(RefreshIntervalOption.init(rawValue:)) ?? .five
    repairLaunchWatcherIfNeeded(showMessage: false)
    TouchBarStripController.shared.onOpenPanel = { [weak self] in
      guard let self else { return }
      self.isCompact = false
      self.refresh()
    }
    TouchBarStripController.shared.setEnabled(touchBarEnabled)
    TouchBarStripController.shared.setKeepAwake(touchBarKeepAwake && touchBarEnabled)
    DispatchQueue.main.async { [weak self] in
      self?.startAutoRefresh()
    }
  }

  /// 把两个工具的 5时/7天 完整余额数据推给 Touch Bar（托盘紧凑块 + 全宽面板）
  private func updateTouchBar() {
    guard touchBarEnabled else { return }
    func toolData(_ event: RateLimitEvent?, letter: String, c5: Color, c7: Color) -> TouchBarStripController.ToolData {
      TouchBarStripController.ToolData(
        letter: letter,
        color5: NSColor(c5),
        color7: NSColor(c7),
        percent5: event?.primary?.remainingPercent,
        percent7: event?.secondary?.remainingPercent,
        reset5: event?.primary?.resetsAt,
        reset7: event?.secondary?.resetsAt
      )
    }
    TouchBarStripController.shared.update(
      codex: toolData(status?.main, letter: "C", c5: palette.fiveHour, c7: palette.weekly),
      claude: toolData(claudeStatus?.main, letter: "A", c5: palette.claudeFiveHour, c7: palette.claudeWeekly)
    )
  }

  var primary: LimitWindow? {
    status?.main?.primary
  }

  var secondary: LimitWindow? {
    status?.main?.secondary
  }

  var tokenStats: TokenStats {
    status?.tokenStats ?? TokenStats()
  }

  var claudePrimary: LimitWindow? {
    claudeStatus?.main?.primary
  }

  var claudeSecondary: LimitWindow? {
    claudeStatus?.main?.secondary
  }

  var claudeTokenStats: TokenStats {
    claudeStatus?.tokenStats ?? TokenStats()
  }

  /// Claude 余额来源是否可用；不可用时双环显示「暂无数据」灰环
  var claudeBalanceAvailable: Bool {
    claudeStatus?.main != nil
  }

  func startAutoRefresh() {
    guard refreshTimer == nil else { return }
    NSLog("CodexBalance dashboard startAutoRefresh interval=\(refreshIntervalOption.rawValue)s")
    dashboardLogger.notice("Starting auto refresh interval=\(self.refreshIntervalOption.rawValue, privacy: .public)s")
    refresh()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshIntervalOption.seconds, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refresh()
      }
    }
  }

  func stopAutoRefresh() {
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  private func restartAutoRefreshIfNeeded() {
    guard refreshTimer != nil else { return }
    stopAutoRefresh()
    startAutoRefresh()
  }

  func refresh() {
    guard !isLoading else { return }
    isLoading = true
    let reader = fastReader
    NSLog("CodexBalance dashboard fast refresh requested")
    dashboardLogger.notice("Fast refresh requested")

    Task {
      do {
        let nextStatus = try await Task.detached(priority: .userInitiated) {
          try reader.readFast()
        }.value
        status = mergeFastStatus(nextStatus, withExisting: status)
        updateTouchBar()
        NSLog(
          "CodexBalance dashboard fast refresh result main=\(nextStatus.main == nil ? "nil" : "ok") primary=\(nextStatus.main?.primary?.remainingPercent ?? -1) secondary=\(nextStatus.main?.secondary?.remainingPercent ?? -1) events=\(nextStatus.eventCount)"
        )
        lastRefresh = nextStatus.generatedAt
        errorMessage = nil
        dashboardLogger.notice(
          "Fast refresh main=\(nextStatus.main == nil ? "nil" : "ok", privacy: .public) source=\(nextStatus.main?.sourceName ?? "nil", privacy: .public) primary=\(nextStatus.main?.primary?.remainingPercent ?? -1, privacy: .public) secondary=\(nextStatus.main?.secondary?.remainingPercent ?? -1, privacy: .public) events=\(nextStatus.eventCount, privacy: .public)"
        )
        scheduleQuickRetryIfNeeded(after: nextStatus)
        scheduleFullRefreshIfNeeded()
      } catch {
        errorMessage = error.localizedDescription
        dashboardLogger.error("Fast refresh failed: \(error.localizedDescription, privacy: .public)")
      }
      isLoading = false
    }

    let claudeReader = claudeFastReader
    Task {
      do {
        let nextClaude = try await Task.detached(priority: .userInitiated) {
          try claudeReader.readFast()
        }.value
        claudeStatus = mergeClaudeFastStatus(nextClaude, withExisting: claudeStatus)
        updateTouchBar()
      } catch {
        dashboardLogger.error("Claude fast refresh failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func toggleCompactSizeMode() {
    compactSizeMode = compactSizeMode == .standard ? .mini : .standard
  }

  func refreshSettingsState() {
    repairLaunchWatcherIfNeeded(showMessage: false)
  }

  func setLaunchWithCodexEnabled(_ enabled: Bool) {
    do {
      try CodexWatcherManager.setEnabled(enabled, appURL: Bundle.main.bundleURL)
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      settingsMessage = enabled ? "已开启：打开 Codex 或 Claude Code 时会自动启动算力码表" : "已关闭：不再跟随 Codex / Claude 自动启动"
    } catch {
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      settingsMessage = "设置失败：\(error.localizedDescription)"
    }
  }

  private func repairLaunchWatcherIfNeeded(showMessage: Bool) {
    do {
      try CodexWatcherManager.refreshIfEnabled(appURL: Bundle.main.bundleURL)
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      if showMessage, launchWithCodexEnabled {
        settingsMessage = "已修复：自动启动会打开当前这个算力码表"
      }
    } catch {
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      settingsMessage = "自动启动修复失败：\(error.localizedDescription)"
    }
  }

  private func scheduleQuickRetryIfNeeded(after status: CodexStatus) {
    if status.main != nil {
      quickRetryTask?.cancel()
      quickRetryTask = nil
      return
    }
    guard quickRetryTask == nil else { return }
    quickRetryTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      await MainActor.run {
        guard let self else { return }
        self.quickRetryTask = nil
        if self.status?.main == nil {
          self.refresh()
        }
      }
    }
  }

  private func scheduleFullRefreshIfNeeded() {
    guard !fullRefreshInFlight else { return }
    if let lastFullRefresh,
       Date().timeIntervalSince(lastFullRefresh) < 180 {
      return
    }

    fullRefreshInFlight = true
    let reader = fullReader
    Task {
      do {
        let fullStatus = try await Task.detached(priority: .utility) {
          try reader.read()
        }.value
        status = mergeFullStatus(fullStatus, withExisting: status)
        lastRefresh = status?.generatedAt ?? fullStatus.generatedAt
        lastFullRefresh = Date()
        errorMessage = nil
        dashboardLogger.notice(
          "Full refresh samples=\(fullStatus.tokenStats.sampleCount, privacy: .public) scanned=\(fullStatus.scannedFiles, privacy: .public) events=\(fullStatus.eventCount, privacy: .public)"
        )
      } catch {
        if status == nil {
          errorMessage = error.localizedDescription
        }
        dashboardLogger.error("Full refresh failed: \(error.localizedDescription, privacy: .public)")
      }
      fullRefreshInFlight = false
    }

    let claudeReader = claudeFullReader
    Task {
      do {
        let fullClaude = try await Task.detached(priority: .utility) {
          try claudeReader.read()
        }.value
        var merged = fullClaude
        if merged.main == nil, let existingMain = claudeStatus?.main,
           Date().timeIntervalSince(existingMain.timestamp) < 10 * 60 {
          merged.main = existingMain
        }
        claudeStatus = merged
      } catch {
        dashboardLogger.error("Claude full refresh failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  private func mergeClaudeFastStatus(_ fastStatus: CodexStatus, withExisting existing: CodexStatus?) -> CodexStatus {
    var merged = fastStatus
    if merged.main == nil, let existingMain = existing?.main,
       Date().timeIntervalSince(existingMain.timestamp) < 10 * 60 {
      merged.main = existingMain
    }
    if let previousStats = existing?.tokenStats, fastStatus.tokenStats.sampleCount == 0 {
      var stats = previousStats
      if !fastStatus.tokenStats.deviceUsage.isEmpty {
        stats.deviceUsage = fastStatus.tokenStats.deviceUsage
      }
      merged.tokenStats = stats
    }
    return merged
  }

  private func mergeFastStatus(_ fastStatus: CodexStatus, withExisting existing: CodexStatus?) -> CodexStatus {
    guard var previousStats = existing?.tokenStats,
          fastStatus.tokenStats.sampleCount == 0
    else {
      return fastStatus
    }

    if let accountUsage = fastStatus.tokenStats.accountUsage {
      previousStats.accountUsage = accountUsage
    }
    if !fastStatus.tokenStats.deviceUsage.isEmpty {
      previousStats.deviceUsage = fastStatus.tokenStats.deviceUsage
    }

    var merged = fastStatus
    merged.tokenStats = previousStats
    return merged
  }

  private func mergeFullStatus(_ fullStatus: CodexStatus, withExisting existing: CodexStatus?) -> CodexStatus {
    guard let existing,
          existing.generatedAt > fullStatus.generatedAt,
          existing.main != nil
    else {
      return fullStatus
    }

    var merged = existing
    merged.tokenStats = fullStatus.tokenStats
    merged.scannedFiles = fullStatus.scannedFiles
    merged.eventCount = fullStatus.eventCount
    merged.recentEvents = fullStatus.recentEvents
    return merged
  }
}
