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
    case .all: "全部".l10n
    }
  }
}

enum AppLanguage: String, CaseIterable, Identifiable, Hashable {
  case system
  case zhHans = "zh-Hans"
  case zhHant = "zh-Hant"
  case en
  case ja
  case ko
  case es
  case fr
  case de
  case ru
  case ptBR = "pt-BR"

  var id: String { rawValue }

  /// 语言名用母语写法，不参与翻译
  var title: String {
    switch self {
    case .system: "跟随系统".l10n
    case .zhHans: "简体中文"
    case .zhHant: "繁體中文"
    case .en: "English"
    case .ja: "日本語"
    case .ko: "한국어"
    case .es: "Español"
    case .fr: "Français"
    case .de: "Deutsch"
    case .ru: "Русский"
    case .ptBR: "Português (Brasil)"
    }
  }
}

enum CompactStyle: String, CaseIterable, Identifiable, Hashable {
  case rings
  case bars
  case barsQuad
  case badge
  case badgeQuad

  var id: String { rawValue }

  var title: String {
    switch self {
    case .rings: "双环".l10n
    case .bars: "长条".l10n
    case .barsQuad: "长条·全".l10n
    case .badge: "徽章".l10n
    case .badgeQuad: "徽章·全".l10n
    }
  }

  var subtitle: String {
    switch self {
    case .rings: "经典同心双环".l10n
    case .bars: "每工具一条更紧张窗口".l10n
    case .barsQuad: "每工具 5时+7天 双条".l10n
    case .badge: "极简数字，占用最小".l10n
    case .badgeQuad: "四个数字全览".l10n
    }
  }
}

/// Touch Bar 全宽面板的显示样式（与屏幕悬浮样式独立选择）
enum TouchBarPanelStyle: String, CaseIterable, Identifiable, Hashable {
  case barsQuad
  case bars
  case badgeQuad
  case badge

  var id: String { rawValue }

  var title: String {
    switch self {
    case .barsQuad: "四进度条".l10n
    case .bars: "双进度条".l10n
    case .badgeQuad: "四数字".l10n
    case .badge: "双数字".l10n
    }
  }
}

enum CompactSizeMode: String, CaseIterable, Identifiable, Hashable {
  case standard
  case mini

  var id: String { rawValue }

  var title: String {
    switch self {
    case .standard: "标准".l10n
    case .mini: "迷你".l10n
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
  @Published var codexToolEnabled: Bool {
    didSet {
      if !codexToolEnabled && !claudeToolEnabled {
        codexToolEnabled = true
        return
      }
      UserDefaults.standard.set(codexToolEnabled, forKey: "toolEnabled.codex")
      handleToolSelectionChange()
    }
  }
  @Published var claudeToolEnabled: Bool {
    didSet {
      if !codexToolEnabled && !claudeToolEnabled {
        claudeToolEnabled = true
        return
      }
      UserDefaults.standard.set(claudeToolEnabled, forKey: "toolEnabled.claude")
      handleToolSelectionChange()
    }
  }
  @Published var appLanguage: AppLanguage {
    didSet {
      guard appLanguage != oldValue else { return }
      if appLanguage == .system {
        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
      } else {
        UserDefaults.standard.set([appLanguage.rawValue], forKey: "AppleLanguages")
      }
      relaunchApp()
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
  /// 语言切换需要重启才能重新加载本地化资源；自动完成，无需用户手动
  private func relaunchApp() {
    let bundlePath = Bundle.main.bundlePath
    let command: String
    if bundlePath.hasSuffix(".app") {
      command = "sleep 0.6; /usr/bin/open \"\(bundlePath)\""
    } else {
      // 开发态直接跑的裸二进制
      let binary = CommandLine.arguments[0]
      command = "sleep 0.6; \"\(binary)\" &"
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", command]
    try? task.run()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
      NSApp.terminate(nil)
    }
  }

  private func applyWindowVisibility() {
    guard let window = NSApp.windows.first(where: { $0.title == "算力码表" }) else { return }
    let shouldHide = touchBarEnabled && isCompact && !clamshellActive
    window.alphaValue = shouldHide ? 0 : 1
    window.ignoresMouseEvents = shouldHide
    if !shouldHide {
      window.makeKeyAndOrderFront(nil)
    }
  }

  private func updateClamshellState(initial: Bool) {
    let screens = NSScreen.screens
    let builtInPresent = screens.contains { screen in
      guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
      else { return false }
      return CGDisplayIsBuiltin(id) != 0
    }
    let nextValue = !screens.isEmpty && !builtInPresent
    guard nextValue != clamshellActive || initial else { return }
    clamshellActive = nextValue
    applyWindowVisibility()

    // 进入合盖模式时，把浮窗挪到外接屏可见位置（旧坐标可能落在已消失的内建屏上）
    if nextValue, isCompact,
       let window = NSApp.windows.first(where: { $0.title == "算力码表" }),
       let visible = NSScreen.main?.visibleFrame {
      let size = window.frame.size
      let origin = NSPoint(
        x: visible.maxX - size.width - 18,
        y: visible.maxY - size.height - 18
      )
      window.setFrameOrigin(origin)
    }
  }

  @Published var touchBarStyle: TouchBarPanelStyle {
    didSet {
      UserDefaults.standard.set(touchBarStyle.rawValue, forKey: "touchBarStyle")
      TouchBarStripController.shared.setPanelStyle(touchBarStyle)
      updateTouchBar()
    }
  }
  @Published var touchBarShowsPercentSign: Bool {
    didSet {
      UserDefaults.standard.set(touchBarShowsPercentSign, forKey: "touchBarShowsPercentSign")
      TouchBarStripController.shared.setDisplayOptions(
        showsPercentSign: touchBarShowsPercentSign, showsWindowTags: touchBarShowsWindowTags
      )
    }
  }
  @Published var touchBarShowsWindowTags: Bool {
    didSet {
      UserDefaults.standard.set(touchBarShowsWindowTags, forKey: "touchBarShowsWindowTags")
      TouchBarStripController.shared.setDisplayOptions(
        showsPercentSign: touchBarShowsPercentSign, showsWindowTags: touchBarShowsWindowTags
      )
    }
  }
  @Published var touchBarShowsSessions: Bool {
    didSet {
      UserDefaults.standard.set(touchBarShowsSessions, forKey: "touchBarShowsSessions")
      pushSessionsToTouchBar()
    }
  }
  @Published var touchBarSessionCount: Int {
    didSet {
      UserDefaults.standard.set(touchBarSessionCount, forKey: "touchBarSessionCount")
      pushSessionsToTouchBar()
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

  var enabledToolCount: Int {
    (codexToolEnabled ? 1 : 0) + (claudeToolEnabled ? 1 : 0)
  }

  /// 展开面板可用的分段：单工具时只有该工具；双工具时含「全部」
  var enabledToolTabs: [DashboardToolTab] {
    var tabs: [DashboardToolTab] = []
    if codexToolEnabled { tabs.append(.codex) }
    if claudeToolEnabled { tabs.append(.claude) }
    if tabs.count > 1 { tabs.append(.all) }
    return tabs
  }

  private func handleToolSelectionChange() {
    if !enabledToolTabs.contains(selectedToolTab) {
      selectedToolTab = enabledToolTabs.first ?? .codex
    }
    if !codexToolEnabled { status = nil }
    if !claudeToolEnabled { claudeStatus = nil }
    updateTouchBar()
    refresh()
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

  /// 合盖外接模式：内建屏幕从系统消失（合上盖子 + 外接显示器）。
  /// 此时 Touch Bar 不可见，即使开了 Touch Bar 模式也要把浮窗放出来。
  @Published private(set) var clamshellActive = false

  private let fastReader = CodexStatusReader()
  private let fullReader = CodexStatusReader()
  private let claudeFastReader = ClaudeStatusReader()
  private let claudeFullReader = ClaudeStatusReader()
  private var refreshTimer: Timer?
  private var claudeFastInFlight = false
  private var quickRetryTask: Task<Void, Never>?
  private var fullRefreshInFlight = false
  private var lastFullRefresh: Date?

  init() {
    let storedMode = UserDefaults.standard.string(forKey: "compactSizeMode")
    compactSizeMode = storedMode.flatMap(CompactSizeMode.init(rawValue:)) ?? .standard
    let defaults = UserDefaults.standard
    if defaults.object(forKey: "toolEnabled.codex") == nil && defaults.object(forKey: "toolEnabled.claude") == nil {
      let home = FileManager.default.homeDirectoryForCurrentUser
      let hasCodex = FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
      let hasClaude = FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
      // 都没装或都装了 → 全开；只装一个 → 只开那个
      codexToolEnabled = hasCodex || !hasClaude
      claudeToolEnabled = hasClaude || !hasCodex
    } else {
      codexToolEnabled = defaults.object(forKey: "toolEnabled.codex") as? Bool ?? true
      claudeToolEnabled = defaults.object(forKey: "toolEnabled.claude") as? Bool ?? true
    }
    let storedLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
    appLanguage = storedLanguages?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    let storedStyle = UserDefaults.standard.string(forKey: "compactStyle")
    compactStyle = storedStyle.flatMap(CompactStyle.init(rawValue:)) ?? .rings
    autoDodgeEnabled = UserDefaults.standard.object(forKey: "autoDodgeEnabled") as? Bool ?? false
    touchBarEnabled = UserDefaults.standard.object(forKey: "touchBarEnabled") as? Bool ?? false
    touchBarKeepAwake = UserDefaults.standard.object(forKey: "touchBarKeepAwake") as? Bool ?? false
    let storedTouchBarStyle = UserDefaults.standard.string(forKey: "touchBarStyle")
    touchBarStyle = storedTouchBarStyle.flatMap(TouchBarPanelStyle.init(rawValue:)) ?? .barsQuad
    touchBarShowsPercentSign = UserDefaults.standard.object(forKey: "touchBarShowsPercentSign") as? Bool ?? true
    touchBarShowsWindowTags = UserDefaults.standard.object(forKey: "touchBarShowsWindowTags") as? Bool ?? true
    touchBarShowsSessions = UserDefaults.standard.object(forKey: "touchBarShowsSessions") as? Bool ?? true
    let storedSessionCount = UserDefaults.standard.object(forKey: "touchBarSessionCount") as? Int ?? 3
    touchBarSessionCount = min(3, max(1, storedSessionCount))
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
    updateClamshellState(initial: true)
    NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.updateClamshellState(initial: false)
      }
    }
    TouchBarStripController.shared.setPanelStyle(touchBarStyle)
    TouchBarStripController.shared.setDisplayOptions(
      showsPercentSign: touchBarShowsPercentSign, showsWindowTags: touchBarShowsWindowTags
    )
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
      codex: codexToolEnabled
        ? toolData(status?.main, letter: "C", c5: palette.fiveHour, c7: palette.weekly)
        : nil,
      claude: claudeToolEnabled
        ? toolData(claudeStatus?.main, letter: "A", c5: palette.claudeFiveHour, c7: palette.claudeWeekly)
        : nil
    )
    pushSessionsToTouchBar()
  }

  /// 后台扫最近会话并推给 Touch Bar（扫描器自带 20 秒缓存）
  private func pushSessionsToTouchBar() {
    guard touchBarEnabled else { return }
    guard touchBarShowsSessions else {
      TouchBarStripController.shared.updateSessions([])
      return
    }
    let codexOn = codexToolEnabled
    let claudeOn = claudeToolEnabled
    let limit = touchBarSessionCount
    Task.detached(priority: .utility) {
      let sessions = RecentSessionScanner.shared.recentSessions(limit: limit)
        .filter { ($0.tool == .codex && codexOn) || ($0.tool == .claude && claudeOn) }
      await MainActor.run {
        TouchBarStripController.shared.updateSessions(sessions)
      }
    }
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
    guard codexToolEnabled else {
      scheduleFullRefreshIfNeeded()
      refreshClaudeFast()
      return
    }
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

    refreshClaudeFast()
  }

  private func refreshClaudeFast() {
    guard claudeToolEnabled, !claudeFastInFlight else { return }
    claudeFastInFlight = true
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
      claudeFastInFlight = false
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
      settingsMessage = enabled ? "已开启：打开 Codex 或 Claude Code 时会自动启动算力码表".l10n : "已关闭：不再跟随 Codex / Claude 自动启动".l10n
    } catch {
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      settingsMessage = L("设置失败：%@", error.localizedDescription)
    }
  }

  private func repairLaunchWatcherIfNeeded(showMessage: Bool) {
    do {
      try CodexWatcherManager.refreshIfEnabled(appURL: Bundle.main.bundleURL)
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      if showMessage, launchWithCodexEnabled {
        settingsMessage = "已修复：自动启动会打开当前这个算力码表".l10n
      }
    } catch {
      launchWithCodexEnabled = CodexWatcherManager.isEnabled()
      settingsMessage = L("自动启动修复失败：%@", error.localizedDescription)
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
    guard codexToolEnabled else {
      scheduleClaudeFullRefresh()
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

    scheduleClaudeFullRefresh()
  }

  private func scheduleClaudeFullRefresh() {
    guard claudeToolEnabled else { return }
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
