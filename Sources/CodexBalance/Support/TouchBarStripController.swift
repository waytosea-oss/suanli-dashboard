import AppKit
import CodexBalanceCore
import IOKit.pwr_mgt

/// 把余额做成 Touch Bar 常驻显示（DFRFoundation 非公开接口，Pock/BetterTouchTool 同款机制）。
/// 结构：Control Strip 常驻一个紧凑数字块（锚点）+ 点按后展开的「全宽余额面板」，
/// 全宽面板用整条 Touch Bar 显示 Codex/Claude 各两条进度条（5时/7天）带百分比与重置倒计时。
/// 无 Touch Bar 的机型所有调用安全空转。
@MainActor
final class TouchBarStripController: NSObject, NSTouchBarDelegate {
  static let shared = TouchBarStripController()

  nonisolated static let trayIdentifier = NSTouchBarItem.Identifier("dev.codex.balance-dashboard.strip")
  nonisolated static let panelIdentifier = NSTouchBarItem.Identifier("dev.codex.balance-dashboard.panel")

  struct ToolData {
    var letter: String
    var color5: NSColor
    var color7: NSColor
    var percent5: Double?
    var percent7: Double?
    var reset5: Date?
    var reset7: Date?
  }

  private var trayItem: NSCustomTouchBarItem?
  private let trayButton: NSButton
  private var trayWidthConstraint: NSLayoutConstraint?
  private var panelTouchBar: NSTouchBar?
  private let panelView = BalanceStripView()
  private var installed = false
  var onOpenPanel: (() -> Void)?

  private typealias SetPresenceFunc = @convention(c) (CFString, DarwinBoolean) -> Void
  private let setPresence: SetPresenceFunc?

  override private init() {
    trayButton = NSButton(title: "--", target: nil, action: nil)
    if let handle = dlopen(
      "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
      RTLD_LAZY
    ), let symbol = dlsym(handle, "DFRElementSetControlStripPresenceForIdentifier") {
      setPresence = unsafeBitCast(symbol, to: SetPresenceFunc.self)
    } else {
      setPresence = nil
    }
    super.init()
    trayButton.target = self
    trayButton.action = #selector(handleTrayTap)
    trayButton.bezelStyle = .rounded
    trayButton.font = .monospacedDigitSystemFont(ofSize: 14, weight: .heavy)
    trayButton.cell?.lineBreakMode = .byClipping
    trayButton.translatesAutoresizingMaskIntoConstraints = false
    trayWidthConstraint = trayButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
    trayWidthConstraint?.isActive = true
    panelView.onOpenPanel = { [weak self] in self?.onOpenPanel?() }
  }

  var isSupported: Bool {
    setPresence != nil
  }

  // MARK: - 保持常亮（防 Touch Bar 息屏）

  private var awakeTimer: Timer?

  /// 周期性申报用户活跃，重置系统空闲计时，让 Touch Bar 不调暗熄灭。
  /// 副作用：主屏幕也不会自动休眠（同一空闲计时器），由设置里的独立开关控制。
  func setKeepAwake(_ enabled: Bool) {
    awakeTimer?.invalidate()
    awakeTimer = nil
    guard enabled else { return }
    let timer = Timer(timeInterval: 30, repeats: true) { _ in
      var assertionID: IOPMAssertionID = 0
      IOPMAssertionDeclareUserActivity(
        "CodexBalance Touch Bar keep-awake" as CFString,
        kIOPMUserActiveLocal,
        &assertionID
      )
      // Touch Bar 的调暗计时只认真实 HID 输入：发一个「原地鼠标移动」合成事件重置它。
      // 位置不变（光标不动、用户无感知），但系统按真输入处理，Touch Bar 不再进入息屏。
      let location = NSEvent.mouseLocation
      let screenHeight = NSScreen.screens.first?.frame.maxY ?? 0
      let cgPoint = CGPoint(x: location.x, y: screenHeight - location.y)
      if let event = CGEvent(
        mouseEventSource: nil,
        mouseType: .mouseMoved,
        mouseCursorPosition: cgPoint,
        mouseButton: .left
      ) {
        event.post(tap: .cghidEventTap)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    timer.fire()
    awakeTimer = timer
  }

  func setEnabled(_ enabled: Bool) {
    guard isSupported else { return }
    if enabled {
      installIfNeeded()
      presentPanel()
    } else {
      dismissPanel()
      uninstall()
    }
  }

  func setPanelStyle(_ style: TouchBarPanelStyle) {
    panelView.style = style
    panelView.invalidateIntrinsicContentSize()
    panelView.needsDisplay = true
  }

  func setDisplayOptions(showsPercentSign: Bool, showsWindowTags: Bool) {
    panelView.showsPercentSign = showsPercentSign
    panelView.showsWindowTags = showsWindowTags
    panelView.invalidateIntrinsicContentSize()
    panelView.needsDisplay = true
  }

  func updateSessions(_ sessions: [RecentSessionChip]) {
    panelView.sessions = sessions
    panelView.invalidateIntrinsicContentSize()
    panelView.needsDisplay = true
  }

  func update(codex: ToolData?, claude: ToolData?) {
    guard installed else { return }
    updateTrayText(tools: [codex, claude].compactMap { $0 })
    panelView.codex = codex
    panelView.claude = claude
    panelView.invalidateIntrinsicContentSize()
    panelView.needsDisplay = true
  }

  // MARK: - 托盘紧凑块

  private func updateTrayText(tools: [ToolData]) {
    let text = NSMutableAttributedString()
    func tighter(_ tool: ToolData) -> (Double?, NSColor) {
      let pairs: [(Double, NSColor)] = [
        tool.percent5.map { ($0, tool.color5) },
        tool.percent7.map { ($0, tool.color7) }
      ].compactMap { $0 }
      guard let minPair = pairs.min(by: { $0.0 < $1.0 }) else { return (nil, tool.color5) }
      return (minPair.0, minPair.1)
    }
    for (index, tool) in tools.enumerated() {
      if index > 0 {
        text.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
      }
      let (percent, color) = tighter(tool)
      let effective = (percent ?? 100) < 20 ? NSColor.systemRed : color
      text.append(NSAttributedString(string: tool.letter, attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .heavy),
        .foregroundColor: effective.withAlphaComponent(0.85),
        .baselineOffset: 2.5
      ]))
      text.append(NSAttributedString(string: percent.map { "\(Int($0.rounded()))" } ?? "--", attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .heavy),
        .foregroundColor: effective
      ]))
    }
    trayButton.attributedTitle = text
    trayWidthConstraint?.constant = max(96, ceil(text.size().width) + 22)
  }

  // MARK: - 全宽面板

  func makePanelTouchBar() -> NSTouchBar {
    let bar = NSTouchBar()
    bar.delegate = self
    bar.defaultItemIdentifiers = [Self.panelIdentifier]
    return bar
  }

  nonisolated func touchBar(
    _ touchBar: NSTouchBar,
    makeItemForIdentifier identifier: NSTouchBarItem.Identifier
  ) -> NSTouchBarItem? {
    guard identifier == Self.panelIdentifier else { return nil }
    return MainActor.assumeIsolated {
      let item = NSCustomTouchBarItem(identifier: identifier)
      item.view = panelView
      return item
    }
  }

  private func presentPanel() {
    guard installed else { return }
    if panelTouchBar == nil {
      panelTouchBar = makePanelTouchBar()
    }
    guard let panelTouchBar else { return }
    // +[NSTouchBar presentSystemModalTouchBar:systemTrayItemIdentifier:]（私有）
    let selector = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    let legacySelector = NSSelectorFromString("presentSystemModalFunctionBar:systemTrayItemIdentifier:")
    if NSTouchBar.responds(to: selector) {
      NSLog("CodexBalance touchbar: presenting system modal touch bar")
      _ = NSTouchBar.perform(selector, with: panelTouchBar, with: Self.trayIdentifier.rawValue)
    } else if NSTouchBar.responds(to: legacySelector) {
      NSLog("CodexBalance touchbar: presenting legacy system modal function bar")
      _ = NSTouchBar.perform(legacySelector, with: panelTouchBar, with: Self.trayIdentifier.rawValue)
    } else {
      NSLog("CodexBalance touchbar: NO system modal selector available")
    }
  }

  private func dismissPanel() {
    guard let panelTouchBar else { return }
    let selector = NSSelectorFromString("dismissSystemModalTouchBar:")
    if NSTouchBar.responds(to: selector) {
      _ = NSTouchBar.perform(selector, with: panelTouchBar)
    }
    self.panelTouchBar = nil
  }

  private func installIfNeeded() {
    guard !installed else { return }
    let newItem = NSCustomTouchBarItem(identifier: Self.trayIdentifier)
    newItem.view = trayButton
    let addSelector = NSSelectorFromString("addSystemTrayItem:")
    guard NSTouchBarItem.responds(to: addSelector) else { return }
    NSTouchBarItem.perform(addSelector, with: newItem)
    setPresence?(Self.trayIdentifier.rawValue as CFString, true)
    trayItem = newItem
    installed = true
  }

  private func uninstall() {
    guard installed, let trayItem else {
      installed = false
      return
    }
    setPresence?(Self.trayIdentifier.rawValue as CFString, false)
    let removeSelector = NSSelectorFromString("removeSystemTrayItem:")
    if NSTouchBarItem.responds(to: removeSelector) {
      NSTouchBarItem.perform(removeSelector, with: trayItem)
    }
    self.trayItem = nil
    installed = false
  }

  @objc private func handleTrayTap() {
    // 点托盘小块 → 重新铺开全宽面板
    presentPanel()
  }
}

/// 全宽 Touch Bar 余额面板：两组（Codex/Claude），每组 = 字母章 + 5时/7天两条进度条（含百分比+倒计时）
@MainActor
private final class BalanceStripView: NSView {
  var codex: TouchBarStripController.ToolData?
  var claude: TouchBarStripController.ToolData?
  var style: TouchBarPanelStyle = .barsQuad
  var showsPercentSign = true
  var showsWindowTags = true
  var sessions: [RecentSessionChip] = []
  var onOpenPanel: (() -> Void)?
  private var sessionHitRects: [(rect: NSRect, tool: ToolID)] = []
  /// Touch Bar 实际可用宽度（挂上窗口后实测，之前是猜的会溢出）
  private var measuredWidth: CGFloat?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    remeasureWidth()
  }

  override func layout() {
    super.layout()
    remeasureWidth()
  }

  private func remeasureWidth() {
    guard let windowWidth = window?.frame.width, windowWidth > 100 else { return }
    if measuredWidth != windowWidth {
      measuredWidth = windowWidth
      invalidateIntrinsicContentSize()
      needsDisplay = true
    }
  }

  private let openButton = NSButton(title: "⤢", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    // Touch Bar 点按是 direct touch，不是鼠标事件；必须声明才能收到 touchesBegan/Ended
    allowedTouchTypes = [.direct]
    openButton.target = self
    openButton.action = #selector(openPanel)
    openButton.bezelStyle = .rounded
    openButton.font = .systemFont(ofSize: 15, weight: .heavy)
    openButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(openButton)
    NSLayoutConstraint.activate([
      openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
      openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      openButton.widthAnchor.constraint(equalToConstant: 36)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  /// 会话区开启且是进度条样式时收紧余额区，避免总宽超出 Touch Bar 被裁掉
  private var isTight: Bool {
    !sessions.isEmpty && (style == .barsQuad || style == .bars)
  }

  override var intrinsicContentSize: NSSize {
    let count = max(1, [codex, claude].compactMap { $0 }.count)
    var perTool: CGFloat
    switch style {
    case .barsQuad: perTool = isTight ? 178 : 268
    case .bars: perTool = isTight ? 204 : 292
    case .badgeQuad: perTool = 188
    case .badge: perTool = 106
    }
    if !showsWindowTags { perTool -= (style == .badgeQuad ? 24 : 12) }
    let chipWidth: CGFloat = sessions.count == 1 ? 216 : (sessions.count == 2 ? 148 : 118)
    let sessionsWidth = sessions.isEmpty ? 0 : CGFloat(sessions.count) * chipWidth + 16
    let ideal = perTool * CGFloat(count) + 24 * CGFloat(count - 1) + 64 + sessionsWidth
    // 封顶在实测的 Touch Bar 宽度内（未挂窗口时先给保守值），
    // 右侧 ⤢ 按钮永远可见，会话区在 draw 里按剩余空间自适应
    let cap = measuredWidth.map { $0 - 8 } ?? 920
    return NSSize(width: min(ideal + 52, cap), height: 30)
  }

  @objc private func openPanel() {
    NSApp.activate(ignoringOtherApps: true)
    onOpenPanel?()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.black.setFill()
    bounds.fill()

    sessionHitRects = []
    var x: CGFloat = 52 // 最左侧是 ⤢ 按钮的固定区域
    if let codex {
      x = drawTool(codex, startX: x)
      x += 12
      drawSeparator(at: x)
      x += 12
    }
    if let claude {
      x = drawTool(claude, startX: x)
    }
    if !sessions.isEmpty {
      x += 12
      drawSeparator(at: x)
      x += 10
      drawSessionChips(startX: x, maxX: bounds.width - 10)
    }
  }

  /// 最近会话小条目：工具色点 + 标题；进行中的加呼吸点。点击激活对应 App。
  private func drawSessionChips(startX: CGFloat, maxX: CGFloat) {
    var x = startX
    let midY = bounds.midY

    // 剩余空间不够时：先缩条目宽度，再减条目数量；按钮区域绝不侵占
    let available = maxX - startX
    guard available > 60 else { return }
    var visible = sessions
    let idealWidth: CGFloat = visible.count == 1 ? 210 : (visible.count == 2 ? 142 : 112)
    var chipWidth = idealWidth
    while visible.count > 1 {
      chipWidth = min(idealWidth, (available - CGFloat(visible.count - 1) * 6) / CGFloat(visible.count))
      if chipWidth >= 84 { break }
      visible.removeLast()
    }
    if visible.count == 1 {
      chipWidth = min(210, available)
    }
    let chipHeight: CGFloat = visible.count == 1 ? 28 : 22
    let fontSize: CGFloat = visible.count == 1 ? 15 : (visible.count == 2 ? 12 : 10.5)
    let dotSize: CGFloat = visible.count == 1 ? 8 : 6

    for session in visible {
      let chipRect = NSRect(x: x, y: midY - chipHeight / 2, width: chipWidth, height: chipHeight)
      let path = NSBezierPath(roundedRect: chipRect, xRadius: chipHeight / 3.2, yRadius: chipHeight / 3.2)
      NSColor.white.withAlphaComponent(0.08).setFill()
      path.fill()

      let toolColor: NSColor = session.tool == .codex
        ? NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.24, alpha: 1)
        : NSColor(calibratedRed: 0.55, green: 0.72, blue: 1.0, alpha: 1)
      let dotRect = NSRect(x: chipRect.minX + 8, y: midY - dotSize / 2, width: dotSize, height: dotSize)
      (session.isActive ? NSColor.systemGreen : toolColor).setFill()
      NSBezierPath(ovalIn: dotRect).fill()

      let title = NSAttributedString(
        string: session.title,
        attributes: [
          .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
          .foregroundColor: NSColor.white.withAlphaComponent(0.88)
        ]
      )
      let maxWidth = chipRect.width - dotSize - 22
      let size = title.size()
      let drawRect = NSRect(
        x: dotRect.maxX + 6,
        y: midY - size.height / 2,
        width: min(size.width, maxWidth),
        height: size.height
      )
      title.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

      sessionHitRects.append((chipRect, session.tool))
      x = chipRect.maxX + 6
    }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if handleTap(at: point) { return }
    super.mouseDown(with: event)
  }

  override func touchesEnded(with event: NSEvent) {
    for touch in event.touches(matching: .ended, in: self) {
      let point = touch.location(in: self)
      if handleTap(at: point) { return }
    }
    super.touchesEnded(with: event)
  }

  private func handleTap(at point: NSPoint) -> Bool {
    for hit in sessionHitRects where hit.rect.insetBy(dx: -4, dy: -5).contains(point) {
      SessionAppLauncher.open(tool: hit.tool)
      return true
    }
    return false
  }

  private func drawSeparator(at x: CGFloat) {
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSRect(x: x, y: 4, width: 1, height: bounds.height - 8).fill()
  }

  /// 一个工具组，按当前样式绘制，返回结束 x 坐标
  @discardableResult
  private func drawTool(_ tool: TouchBarStripController.ToolData, startX: CGFloat) -> CGFloat {
    var x = startX
    let midY = bounds.midY

    let chipRect = NSRect(x: x, y: midY - 10, width: 20, height: 20)
    let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: 5, yRadius: 5)
    tool.color5.withAlphaComponent(0.92).setFill()
    chipPath.fill()
    draw(text: tool.letter, at: NSPoint(x: chipRect.midX, y: midY), font: .systemFont(ofSize: 12, weight: .black), color: .black, centered: true)
    x = chipRect.maxX + 8

    let percentSuffix = showsPercentSign ? "%" : ""
    func tighter() -> (Double?, Date?, CountdownMode, NSColor, String) {
      let p5 = tool.percent5 ?? .infinity
      let p7 = tool.percent7 ?? .infinity
      if p5 <= p7 {
        return (tool.percent5, tool.reset5, .hours, tool.color5, "5时")
      }
      return (tool.percent7, tool.reset7, .days, tool.color7, "7天")
    }

    switch style {
    case .barsQuad:
      // 两行：上 5时、下 7天；紧凑模式下条变短、省倒计时
      let topY = bounds.height * 0.72
      let bottomY = bounds.height * 0.28
      let barWidth: CGFloat = isTight ? 62 : 116
      let widthTop = drawWindowRow(
        label: "5时", percent: tool.percent5, reset: tool.reset5, mode: .hours, color: tool.color5,
        startX: x, centerY: topY, barWidth: barWidth, showsCountdown: !isTight
      )
      let widthBottom = drawWindowRow(
        label: "7天", percent: tool.percent7, reset: tool.reset7, mode: .days, color: tool.color7,
        startX: x, centerY: bottomY, barWidth: barWidth, showsCountdown: !isTight
      )
      return x + max(widthTop, widthBottom)
    case .bars:
      // 单行：更紧张窗口一条大进度条 + 顶满高度的大数字
      let (percent, reset, mode, color, tag) = tighter()
      let width = drawWindowRow(
        label: tag, percent: percent, reset: reset, mode: mode, color: color,
        startX: x, centerY: midY, barWidth: isTight ? 72 : 128,
        percentFontSize: 22, percentAdvance: 60, showsCountdown: !isTight
      )
      return x + width
    case .badgeQuad:
      // 无进度条：竖排小标签在左、大号数字顶满高度
      var cx = x
      for (percent, color, tag) in [(tool.percent5, tool.color5, "5时"), (tool.percent7, tool.color7, "7天")] {
        let effective = (percent ?? 100) < 20 ? NSColor.systemRed : color
        if showsWindowTags {
          cx += drawVerticalLabel(tag, at: cx, centerY: midY, color: NSColor.white.withAlphaComponent(0.55)) + 3
        }
        let text = percent.map { "\(Int($0.rounded()))\(percentSuffix)" } ?? "--"
        cx += drawBigNumber(text, at: cx, centerY: midY, color: effective) + 10
      }
      return cx
    case .badge:
      // 只有一个大数字（更紧张窗口），竖排标签在左
      let (percent, _, _, color, tag) = tighter()
      let effective = (percent ?? 100) < 20 ? NSColor.systemRed : color
      var cx = x
      if showsWindowTags {
        cx += drawVerticalLabel(tag, at: cx, centerY: midY, color: NSColor.white.withAlphaComponent(0.55)) + 3
      }
      let text = percent.map { "\(Int($0.rounded()))\(percentSuffix)" } ?? "--"
      cx += drawBigNumber(text, at: cx, centerY: midY, color: effective)
      return cx
    }
  }

  /// 单行：标签 + 进度条 + 百分比 + 倒计时（紧凑行高），返回行宽
  private func drawWindowRow(
    label: String,
    percent: Double?,
    reset: Date?,
    mode: CountdownMode,
    color: NSColor,
    startX: CGFloat,
    centerY: CGFloat,
    barWidth: CGFloat = 116,
    percentFontSize: CGFloat = 11,
    percentAdvance: CGFloat = 36,
    showsCountdown: Bool = true
  ) -> CGFloat {
    var x = startX
    let effective = (percent ?? 100) < 20 ? NSColor.systemRed : color

    if showsWindowTags {
      draw(text: label, at: NSPoint(x: x, y: centerY), font: .systemFont(ofSize: 9, weight: .heavy), color: NSColor.white.withAlphaComponent(0.55))
      x += 22
    }
    let track = NSRect(x: x, y: centerY - 3, width: barWidth, height: 6)
    effective.withAlphaComponent(0.22).setFill()
    NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
    let ratio = max(0, min(1, (percent ?? 0) / 100))
    if ratio > 0.01 {
      let fillRect = NSRect(x: x, y: centerY - 3, width: barWidth * ratio, height: 6)
      effective.setFill()
      NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
    }
    x += barWidth + 6

    let percentText = percent.map { "\(Int($0.rounded()))\(showsPercentSign ? "%" : "")" } ?? "--"
    draw(text: percentText, at: NSPoint(x: x, y: centerY), font: .monospacedDigitSystemFont(ofSize: percentFontSize, weight: .heavy), color: effective)
    x += percentAdvance

    if showsCountdown {
      let resetText = BalanceFormatters.resetCountdownShort(reset, mode: mode)
      draw(text: resetText, at: NSPoint(x: x, y: centerY), font: .monospacedDigitSystemFont(ofSize: 9, weight: .bold), color: NSColor.white.withAlphaComponent(0.48))
      x += 50
    }
    return x - startX
  }

  /// 竖排小标签（如「5时」上下两个字），返回占用宽度
  private func drawVerticalLabel(_ text: String, at x: CGFloat, centerY: CGFloat, color: NSColor) -> CGFloat {
    let font = NSFont.systemFont(ofSize: 8.5, weight: .heavy)
    let characters = text.map(String.init)
    let lineHeight: CGFloat = 10
    let totalHeight = CGFloat(characters.count) * lineHeight
    var y = centerY + totalHeight / 2 - lineHeight / 2
    var maxWidth: CGFloat = 0
    for character in characters {
      let string = NSAttributedString(string: character, attributes: [.font: font, .foregroundColor: color])
      let size = string.size()
      maxWidth = max(maxWidth, size.width)
      string.draw(at: NSPoint(x: x, y: y - size.height / 2))
      y -= lineHeight
    }
    return maxWidth
  }

  /// 顶满 Touch Bar 高度的大号数字，返回实际宽度
  private func drawBigNumber(_ text: String, at x: CGFloat, centerY: CGFloat, color: NSColor) -> CGFloat {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .heavy)
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let size = string.size()
    string.draw(at: NSPoint(x: x, y: centerY - size.height / 2))
    return size.width
  }

  private func draw(
    text: String,
    at point: NSPoint,
    font: NSFont,
    color: NSColor,
    centered: Bool = false
  ) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    let origin = centered
      ? NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
      : NSPoint(x: point.x, y: point.y - size.height / 2)
    string.draw(at: origin)
  }
}
