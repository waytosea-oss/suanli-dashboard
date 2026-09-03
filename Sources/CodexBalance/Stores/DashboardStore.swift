import AppKit
import CodexBalanceCore
import Foundation
import OSLog
import SwiftUI

private let dashboardLogger = Logger(
  subsystem: Bundle.main.bundleIdentifier ?? "dev.codex.balance-dashboard",
  category: "DashboardStore"
)

/// 展开面板顶部的分段：每个已启用平台一个 + 「全部」。
/// rawValue 用于持久化（"codex" / "deepseek" / "all"），老用户存的 "codex"/"claude" 直接兼容。
enum DashboardToolTab: Hashable, Identifiable {
  case tool(ToolID)
  case all

  static let codex = DashboardToolTab.tool(.codex)
  static let claude = DashboardToolTab.tool(.claude)

  init?(rawValue: String) {
    if rawValue == "all" { self = .all; return }
    guard let tool = ToolID(rawValue: rawValue) else { return nil }
    self = .tool(tool)
  }

  var rawValue: String {
    switch self {
    case .tool(let tool): tool.rawValue
    case .all: "all"
    }
  }

  var id: String { rawValue }

  var tool: ToolID? {
    if case .tool(let tool) = self { return tool }
    return nil
  }

  var title: String {
    switch self {
    case .tool(let tool): tool.displayName
    case .all: "全部".l10n
    }
  }
}

/// 展示层统一消费的「一个平台」：名字、颜色族、可用状态、以及一个可以直接喂给现有
/// 环/条/徽章视图的 RateLimitEvent。订阅制平台就是真实事件；预付费平台由余额合成。
struct DisplayTool: Identifiable, Equatable {
  var id: ToolID
  var event: RateLimitEvent?
  var unavailable: Bool
  var balance: BalanceMetric?
  var errorMessage: String?

  var name: String { id.displayName }
  var letter: String { id.letter }
  var colorFamily: Int { id.colorFamily }
  /// 兼容旧视图参数：Claude 及后续平台走「冷色族」逻辑的地方用
  var cool: Bool { id != .codex }
  /// 环心显示的文本：订阅制显示百分比；预付费显示金额
  var centerText: String? { balance?.amountText }
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
  case numbersAll
  case barsQuad
  case bars
  case badgeQuad
  case badge

  var id: String { rawValue }

  var title: String {
    switch self {
    case .numbersAll: "全数字".l10n
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
  /// 已启用的平台，**有序**——顺序就是浮窗 / Touch Bar / 面板里从左到右的顺序。
  /// 至少保留一个；持久化为 JSON 字符串数组（"enabledProviders"）。
  @Published var enabledProviders: [ToolID] {
    didSet {
      if enabledProviders.isEmpty {
        enabledProviders = oldValue.isEmpty ? [.codex] : oldValue
        return
      }
      if let data = try? JSONEncoder().encode(enabledProviders.map(\.rawValue)) {
        UserDefaults.standard.set(String(decoding: data, as: UTF8.self), forKey: "enabledProviders")
      }
      // 旧键同步写一份，老版本回退时不至于全灭
      UserDefaults.standard.set(enabledProviders.contains(.codex), forKey: "toolEnabled.codex")
      UserDefaults.standard.set(enabledProviders.contains(.claude), forKey: "toolEnabled.claude")
      handleToolSelectionChange()
    }
  }

  /// 第三方平台的余额快照（DeepSeek / Kimi / SiliconFlow / OpenRouter …）
  @Published private(set) var providerSnapshots: [ToolID: ProviderSnapshot] = [:]

  /// 兼容旧代码路径：Codex / Claude 的日志抓取与 token 看板仍按这两个开关走
  var codexToolEnabled: Bool { enabledProviders.contains(.codex) }
  var claudeToolEnabled: Bool { enabledProviders.contains(.claude) }

  func isEnabled(_ provider: ToolID) -> Bool { enabledProviders.contains(provider) }

  func enable(_ provider: ToolID) {
    guard !enabledProviders.contains(provider) else { return }
    enabledProviders.append(provider)
    if provider.usesAPIKey { refreshAPIProviders(force: true) }
  }

  func disable(_ provider: ToolID) {
    enabledProviders.removeAll { $0 == provider }
  }

  func move(_ provider: ToolID, direction: Int) {
    guard let index = enabledProviders.firstIndex(of: provider) else { return }
    let target = index + direction
    guard enabledProviders.indices.contains(target) else { return }
    enabledProviders.swapAt(index, target)
  }

  /// 还没启用、可以从「添加平台」菜单里挑的
  var availableProviders: [ToolID] {
    ToolID.allCases.filter { !enabledProviders.contains($0) }
  }

  /// 展示层统一入口：按启用顺序给出每个平台的可绘制数据
  var displayTools: [DisplayTool] {
    enabledProviders.map { provider in
      switch provider {
      case .codex:
        return DisplayTool(id: .codex, event: status?.main, unavailable: status?.main == nil)
      case .claude:
        return DisplayTool(id: .claude, event: claudeStatus?.main, unavailable: !claudeBalanceAvailable)
      default:
        let snapshot = providerSnapshots[provider]
        let event: RateLimitEvent? = snapshot.flatMap { snap in
          guard snap.isAvailable else { return nil }
          return RateLimitEvent(
            timestamp: snap.fetchedAt,
            sourceName: snap.sourceName,
            sourcePath: "",
            limitID: provider.rawValue,
            limitName: provider.vendorName,
            windows: snap.resolvedWindows
          )
        }
        return DisplayTool(
          id: provider,
          event: event,
          unavailable: event == nil,
          balance: snapshot?.balance,
          errorMessage: snapshot?.errorMessage
        )
      }
    }
  }

  // MARK: 第三方平台 API Key

  func apiKey(for provider: ToolID) -> String {
    providerKeyStore.entry(for: provider)?.apiKey ?? ""
  }

  func setAPIKey(_ key: String, for provider: ToolID) {
    providerKeyStore.setAPIKey(key, for: provider)
    providerSnapshots[provider] = nil
    if isEnabled(provider) { refreshAPIProviders(force: true) }
  }

  func referenceAmount(for provider: ToolID) -> Double? {
    providerKeyStore.entry(for: provider)?.referenceAmount
  }

  func setReferenceAmount(_ amount: Double?, for provider: ToolID) {
    providerKeyStore.setReferenceAmount(amount, for: provider)
    refreshAPIProviders(force: true)
  }

  /// 拉取所有已启用的预付费平台余额（各自 4 分钟节流 + 失败退避）
  func refreshAPIProviders(force: Bool = false) {
    for provider in enabledProviders where provider.usesAPIKey {
      providerBalanceSource.refreshInBackground(provider, force: force) { [weak self] snapshot in
        Task { @MainActor in
          guard let self else { return }
          self.providerSnapshots[provider] = snapshot
          self.updateTouchBar()
        }
      }
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
      updateTouchBar()
      applyWindowVisibility()
    }
  }
  /// Touch Bar 常驻开着时，收起后浮窗默认隐身（数字在 Touch Bar 上看）。
  /// 有人会以为码表"不见了"，这个开关让浮窗在收起后也留在屏幕上。
  @Published var floatingStaysVisible: Bool {
    didSet {
      UserDefaults.standard.set(floatingStaysVisible, forKey: "floatingStaysVisible")
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
    let shouldHide = touchBarEnabled && isCompact && !clamshellActive && !floatingStaysVisible
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
  /// 刷新进度条方向：false=倒计时（深色段走完刷新），true=正计时（充满刷新）
  @Published var resetProgressAscending: Bool {
    didSet {
      UserDefaults.standard.set(resetProgressAscending, forKey: "resetProgressAscending")
      TouchBarStripController.shared.setResetProgressAscending(resetProgressAscending)
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

  var touchBarSupported: Bool {
    TouchBarStripController.shared.isSupported
  }

  var enabledToolCount: Int { enabledProviders.count }

  /// 展开面板可用的分段：每个已启用平台一个；两个及以上时含「全部」
  var enabledToolTabs: [DashboardToolTab] {
    var tabs = enabledProviders.map(DashboardToolTab.tool)
    if tabs.count > 1 { tabs.append(.all) }
    return tabs
  }

  private func handleToolSelectionChange() {
    if !enabledToolTabs.contains(selectedToolTab) {
      selectedToolTab = enabledToolTabs.first ?? .codex
    }
    if !codexToolEnabled { status = nil }
    if !claudeToolEnabled { claudeStatus = nil }
    for provider in providerSnapshots.keys where !enabledProviders.contains(provider) {
      providerSnapshots[provider] = nil
    }
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
  /// 第三方平台 API Key（明文文件 0600，不进钥匙串——见 ProviderKeyStore 注释）
  private let providerKeyStore = ProviderKeyStore()
  private lazy var providerBalanceSource = APIKeyBalanceSource(keyStore: providerKeyStore)
  private var refreshTimer: Timer?
  private var claudeFastInFlight = false
  private var quickRetryTask: Task<Void, Never>?
  private var fullRefreshInFlight = false
  private var lastFullRefresh: Date?

  init() {
    let storedMode = UserDefaults.standard.string(forKey: "compactSizeMode")
    compactSizeMode = storedMode.flatMap(CompactSizeMode.init(rawValue:)) ?? .standard
    let defaults = UserDefaults.standard
    if let raw = defaults.string(forKey: "enabledProviders"),
       let names = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) {
      // 新版：有序平台列表
      let decoded = names.compactMap(ToolID.init(rawValue:))
      enabledProviders = decoded.isEmpty ? [.codex] : decoded
    } else if defaults.object(forKey: "toolEnabled.codex") != nil || defaults.object(forKey: "toolEnabled.claude") != nil {
      // 老用户：从两个布尔开关迁移
      var migrated: [ToolID] = []
      if defaults.object(forKey: "toolEnabled.codex") as? Bool ?? true { migrated.append(.codex) }
      if defaults.object(forKey: "toolEnabled.claude") as? Bool ?? true { migrated.append(.claude) }
      enabledProviders = migrated.isEmpty ? [.codex] : migrated
    } else {
      // 首次启动：按本机装了哪个自动探测；都没装或都装了 → 全开
      let home = FileManager.default.homeDirectoryForCurrentUser
      let hasCodex = FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path)
      let hasClaude = FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path)
      var detected: [ToolID] = []
      if hasCodex || !hasClaude { detected.append(.codex) }
      if hasClaude || !hasCodex { detected.append(.claude) }
      enabledProviders = detected
    }
    let storedLanguages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String]
    appLanguage = storedLanguages?.first.flatMap(AppLanguage.init(rawValue:)) ?? .system
    let storedStyle = UserDefaults.standard.string(forKey: "compactStyle")
    compactStyle = storedStyle.flatMap(CompactStyle.init(rawValue:)) ?? .rings
    autoDodgeEnabled = UserDefaults.standard.object(forKey: "autoDodgeEnabled") as? Bool ?? false
    touchBarEnabled = UserDefaults.standard.object(forKey: "touchBarEnabled") as? Bool ?? false
    floatingStaysVisible = UserDefaults.standard.object(forKey: "floatingStaysVisible") as? Bool ?? false
    resetProgressAscending = UserDefaults.standard.object(forKey: "resetProgressAscending") as? Bool ?? false
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

  /// 每次余额刷新落一份实时 JSON（仅百分比与重置时间的数字），
  /// 供局域网伴侣设备（如小度屏保叠加层）经由本机服务器读取。
  private func writeLiveBalanceFile() {
    func toolJSON(_ event: RateLimitEvent?, stats: TokenStats?, enabled: Bool) -> [String: Any]? {
      guard enabled else { return nil }
      var object: [String: Any] = [:]
      if let event {
        // 旧字段保留（小度旧版兼容）
        if let p5 = event.primary?.remainingPercent { object["p5"] = p5 }
        if let p7 = event.secondary?.remainingPercent { object["p7"] = p7 }
        if let r5 = event.primary?.resetsAt { object["r5"] = r5.timeIntervalSince1970 }
        if let r7 = event.secondary?.resetsAt { object["r7"] = r7.timeIntervalSince1970 }
        // 新结构：N 窗口列表
        let windowList: [[String: Any]] = event.resolvedWindows.map { labeled in
          var item: [String: Any] = [
            "label": labeled.label,
            "pct": labeled.window.remainingPercent,
            "hourScale": labeled.isHourScale
          ]
          if let resets = labeled.window.resetsAt { item["reset"] = resets.timeIntervalSince1970 }
          return item
        }
        if !windowList.isEmpty { object["windows"] = windowList }
      }
      if let stats, stats.sampleCount > 0 || stats.todayTokens > 0 {
        object["today"] = stats.todayTokens
        object["week"] = stats.last7DaysTokens
        object["month"] = stats.monthTokens
        object["samples"] = stats.sampleCount
        // 最近 14 天日趋势：给小度/外部面板画曲线用
        object["trend"] = stats.daily.suffix(14).map { ["label": $0.label, "tokens": $0.totalTokens] }
        // 本月用途分布
        let categories = stats.categoryBreakdown
          .filter { $0.totalTokens > 0 }
          .sorted { $0.totalTokens > $1.totalTokens }
          .prefix(6)
          .map { ["label": $0.category.label, "tokens": $0.totalTokens] }
        if !categories.isEmpty { object["categories"] = Array(categories) }
        // 今日项目 Top 3
        let projects = stats.todayTopProjects.prefix(3)
          .map { ["name": $0.projectName, "tokens": $0.totalTokens] }
        if !projects.isEmpty { object["projects"] = Array(projects) }
      }
      return object.isEmpty ? nil : object
    }
    var root: [String: Any] = ["updatedAt": Date().timeIntervalSince1970]
    if let codex = toolJSON(status?.main, stats: status?.tokenStats, enabled: codexToolEnabled) { root["codex"] = codex }
    if let claude = toolJSON(claudeStatus?.main, stats: claudeStatus?.tokenStats, enabled: claudeToolEnabled) { root["claude"] = claude }
    // 通用结构：所有已启用平台按顺序排一遍（含上面两个），伴侣设备只认这一份即可。
    // 预付费平台多给 amount / currency / reference 三个字段。
    let providers: [[String: Any]] = displayTools.map { tool in
      var item: [String: Any] = [
        "id": tool.id.rawValue,
        "name": tool.name,
        "letter": tool.letter,
        "kind": tool.id.kind.rawValue,
        "available": !tool.unavailable
      ]
      if let event = tool.event {
        item["windows"] = event.resolvedWindows.map { labeled -> [String: Any] in
          var w: [String: Any] = ["label": labeled.label, "pct": labeled.window.remainingPercent, "hourScale": labeled.isHourScale]
          if let resets = labeled.window.resetsAt { w["reset"] = resets.timeIntervalSince1970 }
          return w
        }
      }
      if let balance = tool.balance {
        item["amount"] = balance.amount
        item["currency"] = balance.currencySymbol
        if let reference = balance.reference { item["reference"] = reference }
      }
      if let error = tool.errorMessage { item["error"] = error }
      return item
    }
    root["providers"] = providers
    guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/CodexBalanceDashboard")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? data.write(to: dir.appendingPathComponent("live-balance.json"), options: [.atomic])
  }

  /// 把两个工具的 5时/7天 完整余额数据推给 Touch Bar（托盘紧凑块 + 全宽面板）
  private func updateTouchBar() {
    writeLiveBalanceFile()
    guard touchBarEnabled else { return }
    let tools: [TouchBarStripController.ToolData] = displayTools.map { tool in
      let event = tool.event
      let windows = (event?.resolvedWindows ?? []).enumerated().map { index, labeled in
        TouchBarStripController.TBWindow(
          label: labeled.label,
          percent: tool.unavailable ? nil : labeled.window.remainingPercent,
          reset: labeled.window.resetsAt,
          hourScale: labeled.isHourScale,
          color: NSColor(palette.windowColor(family: tool.colorFamily, index: index)),
          // 预付费平台：数字位置显示金额而不是百分比
          valueText: tool.centerText
        )
      }
      let bottleneckIndex = event?.bottleneckWindow.flatMap { bottleneck in
        event?.resolvedWindows.firstIndex { $0.label == bottleneck.label }
      } ?? 0
      return TouchBarStripController.ToolData(
        letter: tool.letter, windows: windows, bottleneckIndex: bottleneckIndex
      )
    }
    TouchBarStripController.shared.update(tools: tools)
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
    refreshAPIProviders()
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
