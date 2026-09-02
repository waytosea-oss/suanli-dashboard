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

  struct TBWindow {
    var label: String
    var percent: Double?
    var reset: Date?
    var hourScale: Bool
    var color: NSColor
    /// 预付费平台：数字位置显示金额（"¥12.30"）而不是百分比；nil 走百分比
    var valueText: String? = nil
  }

  struct ToolData {
    var letter: String
    var windows: [TBWindow]
    var bottleneckIndex: Int

    var bottleneck: TBWindow? {
      windows.indices.contains(bottleneckIndex) ? windows[bottleneckIndex] : windows.first
    }
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

  func setEnabled(_ enabled: Bool) {
    guard isSupported else { return }
    if enabled {
      // 只装 Control Strip 里的小图标，不自动铺开全宽面板。
      //
      // 全宽面板走 presentSystemModalTouchBar，那个 API 会整条接管 Touch Bar，
      // 系统的亮度/音量/Siri 全部被盖住。启动就自动铺开的话，用户每次开机
      // 都会丢掉控制条，而且没有明显的退回方式。
      //
      // 常驻状态 = 小图标（显示余额数字，与系统控制条并存）；
      // 想看大数字面板时点一下小图标展开，再点一下收回。
      installIfNeeded()
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

  func setResetProgressAscending(_ ascending: Bool) {
    panelView.resetProgressAscending = ascending
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

  /// 按启用顺序传入任意个平台；空数组 = 全部关闭
  func update(tools: [ToolData]) {
    guard installed else { return }
    updateTrayText(tools: tools)
    panelView.tools = tools
    panelView.invalidateIntrinsicContentSize()
    panelView.needsDisplay = true
  }

  // MARK: - 托盘紧凑块

  private func updateTrayText(tools: [ToolData]) {
    let text = NSMutableAttributedString()
    func tighter(_ tool: ToolData) -> (Double?, NSColor) {
      guard let bottleneck = tool.bottleneck else { return (nil, .white) }
      return (bottleneck.percent, bottleneck.color)
    }
    let maxTrayWidth: CGFloat = 200   // 控制条右侧空间有限，过宽会被系统整个丢掉
    for (index, tool) in tools.enumerated() {
      let piece = NSMutableAttributedString()
      if index > 0 {
        piece.append(NSAttributedString(string: "  ", attributes: [.font: NSFont.systemFont(ofSize: 6)]))
      }
      let (percent, color) = tighter(tool)
      let effective = (percent ?? 100) < 20 ? NSColor.systemRed : color
      piece.append(NSAttributedString(string: tool.letter, attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .heavy),
        .foregroundColor: effective.withAlphaComponent(0.85),
        .baselineOffset: 2.5
      ]))
      let value = tool.bottleneck?.valueText ?? (percent.map { "\(Int($0.rounded()))" } ?? "--")
      piece.append(NSAttributedString(string: value, attributes: [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .heavy),
        .foregroundColor: effective
      ]))
      let remaining = tools.count - index
      let reserve: CGFloat = remaining > 1 ? 26 : 0   // 给 "+n" 留位
      if index > 0, text.size().width + piece.size().width + reserve > maxTrayWidth {
        text.append(NSAttributedString(string: " +\(remaining)", attributes: [
          .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .heavy),
          .foregroundColor: NSColor.white.withAlphaComponent(0.6)
        ]))
        break
      }
      text.append(piece)
    }
    trayButton.attributedTitle = text
    trayWidthConstraint?.constant = min(maxTrayWidth + 22, max(96, ceil(text.size().width) + 22))
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

  /// 进程退出前必须调用：把整条 Touch Bar 还给系统。
  /// 全宽面板走的是 presentSystemModalTouchBar（私有 API），它会整条接管 Touch Bar，
  /// 系统的亮度/音量控制条会被完全盖住。若进程在"面板已铺开"时被强杀（pkill/崩溃），
  /// dismiss 没机会执行，接管状态就烂在 TouchBarServer 里，用户的亮度音量条会一直消失，
  /// 只能靠 killall ControlStrip 手动救。这里做成幂等，可安全重复调用。
  func releaseTouchBar() {
    dismissPanel()
    panelPresented = false
    uninstall()
  }

  /// 全宽面板当前是否铺开（用于点击切换）
  private var panelPresented = false

  @objc private func handleTrayTap() {
    // 点小图标 = 展开/收回 切换。
    // 必须能收回：全宽面板会盖住系统亮度/音量条，
    // 只能展开不能收的话，用户看完就回不去了。
    if panelPresented {
      dismissPanel()
      panelPresented = false
    } else {
      presentPanel()
      panelPresented = true
    }
  }
}

/// 全宽 Touch Bar 余额面板：两组（Codex/Claude），每组 = 字母章 + 5时/7天两条进度条（含百分比+倒计时）
@MainActor
private final class BalanceStripView: NSView {
  /// 已启用的平台，按显示顺序
  var tools: [TouchBarStripController.ToolData] = []
  var style: TouchBarPanelStyle = .barsQuad
  var showsPercentSign = true
  var showsWindowTags = true
  var sessions: [RecentSessionChip] = []
  /// false=倒计时（深色段=剩余等待），true=正计时（深色段=已走过，充满即刷新）
  var resetProgressAscending = false
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

  /// 平台 ≥4 个时全数字样式每个平台只画瓶颈窗口那一个数字，否则总宽远超 Touch Bar
  private var numbersOnlyBottleneck: Bool { tools.count >= 4 }

  /// 会话区开启且是进度条样式时收紧余额区，避免总宽超出 Touch Bar 被裁掉
  private var isTight: Bool {
    !sessions.isEmpty && (style == .barsQuad || style == .bars)
  }

  override var intrinsicContentSize: NSSize {
    let count = max(1, tools.count)
    let maxWindows = CGFloat(max(tools.map(\.windows.count).max() ?? 0, 1))
    var perTool: CGFloat
    switch style {
    // 全数字：每个窗口都是等大数字（22pt 重体，含 % 约 52pt）+ 窗口间距 10pt；
    // 带竖排标签时每项再加约 14pt。
    case .numbersAll:
      let perWindow: CGFloat = (showsPercentSign ? 52 : 40) + (showsWindowTags ? 14 : 0)
      let windowsShown: CGFloat = numbersOnlyBottleneck ? 1 : maxWindows
      perTool = perWindow * windowsShown + 10 * (windowsShown - 1) + 16
    case .barsQuad: perTool = (isTight ? 140 : 200) + maxWindows * 37
    case .bars: perTool = isTight ? 204 : 292
    case .badgeQuad: perTool = 130 + (maxWindows - 1) * 26
    case .badge: perTool = 106 + (maxWindows > 1 ? 10 : 0)
    }
    if !showsWindowTags && style != .numbersAll { perTool -= (style == .badgeQuad ? 24 : 12) }
    let chipWidth: CGFloat = sessions.count == 1 ? 216 : (sessions.count == 2 ? 148 : 118)
    var sessionsWidth = sessions.isEmpty ? 0 : CGFloat(sessions.count) * chipWidth + 16
    // 全数字样式：数字是主角，绝不能被会话条目挤掉。
    // 先算出数字区需要多少，剩下的才给会话区。
    if style == .numbersAll {
      let toolsWidth = perTool * CGFloat(count) + 24 * CGFloat(count - 1) + 64
      let available = (measuredWidth ?? 920) - 8 - toolsWidth - 52
      sessionsWidth = max(0, min(sessionsWidth, available))
    }
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
    let limit = bounds.width - 10
    for (index, tool) in tools.enumerated() {
      if index > 0 {
        // 剩余宽度连一个最小平台块（字母块 + "--"）都放不下：画 "+n" 收尾，绝不画一半
        if x + 24 + 70 > limit {
          draw(text: "+\(tools.count - index)", at: NSPoint(x: x + 14, y: bounds.midY),
               font: .monospacedDigitSystemFont(ofSize: 12, weight: .heavy),
               color: NSColor.white.withAlphaComponent(0.6))
          break
        }
        x += 12
        drawSeparator(at: x)
        x += 12
      }
      x = drawTool(tool, startX: x)
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

  /// 一个工具组，按当前样式绘制（主视觉=瓶颈窗口，其余为卫星），返回结束 x 坐标
  @discardableResult
  private func drawTool(_ tool: TouchBarStripController.ToolData, startX: CGFloat) -> CGFloat {
    var x = startX
    let midY = bounds.midY
    let bottleneck = tool.bottleneck
    let heroColor = bottleneck?.color ?? .white

    let chipRect = NSRect(x: x, y: midY - 10, width: 20, height: 20)
    let chipPath = NSBezierPath(roundedRect: chipRect, xRadius: 5, yRadius: 5)
    heroColor.withAlphaComponent(0.92).setFill()
    chipPath.fill()
    draw(text: tool.letter, at: NSPoint(x: chipRect.midX, y: midY), font: .systemFont(ofSize: 12, weight: .black), color: .black, centered: true)
    x = chipRect.maxX + 8

    let percentSuffix = showsPercentSign ? "%" : ""

    switch style {
    case .barsQuad:
      // 全窗条：上=瓶颈主条行，下=全部窗口卫星微条行
      let topY = bounds.height * 0.70
      let bottomY = bounds.height * 0.26
      let barWidth: CGFloat = isTight ? 62 : 108
      let widthTop = drawWindowRow(
        label: bottleneck?.label ?? "--", percent: bottleneck?.percent,
        reset: bottleneck?.reset, mode: (bottleneck?.hourScale ?? false) ? .hours : .days,
        color: heroColor, startX: x, centerY: topY, barWidth: barWidth, showsCountdown: !isTight,
        valueText: bottleneck?.valueText
      )
      var sx = x
      for (index, window) in tool.windows.enumerated() {
        let tint = window.color
        let micro = NSRect(x: sx, y: bottomY - 1.5, width: 16, height: 3)
        tint.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: micro, xRadius: 1.5, yRadius: 1.5).fill()
        let ratio = max(0, min(1, (window.percent ?? 0) / 100))
        if ratio > 0.02 {
          tint.setFill()
          NSBezierPath(roundedRect: NSRect(x: sx, y: bottomY - 1.5, width: 16 * ratio, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if index == tool.bottleneckIndex {
          NSColor.white.withAlphaComponent(0.55).setStroke()
          let outline = NSBezierPath(roundedRect: micro.insetBy(dx: -0.5, dy: -0.5), xRadius: 2, yRadius: 2)
          outline.lineWidth = 0.5
          outline.stroke()
        }
        sx += 16 + 3
        draw(text: window.percent.map { "\(Int($0.rounded()))" } ?? "--",
             at: NSPoint(x: sx, y: bottomY),
             font: .monospacedDigitSystemFont(ofSize: 8, weight: .bold),
             color: tint)
        sx += 18
      }
      return x + max(widthTop, sx - x)
    case .bars:
      // 单条：瓶颈窗口一条大进度条 + 大数字
      let width = drawWindowRow(
        label: bottleneck?.label ?? "--", percent: bottleneck?.percent,
        reset: bottleneck?.reset, mode: (bottleneck?.hourScale ?? false) ? .hours : .days,
        color: heroColor, startX: x, centerY: midY, barWidth: isTight ? 72 : 128,
        percentFontSize: 22, percentAdvance: 60, showsCountdown: !isTight,
        valueText: bottleneck?.valueText
      )
      return x + width
    case .numbersAll:
      // 全数字：每个窗口一个等大数字 + 正下方倒计时条，不区分主次。
      // 用户最常盯的是 Fable，而瓶颈规则会把"最紧的那个"放大、其余缩成小点，
      // 导致 Fable 有时是大数字有时是小点，位置还会跳。这里全部等大、位置固定。
      var cx = x
      if tool.windows.isEmpty {
        // 没数据（未填 Key / 接口失败）：老实画 "--"，不能只剩一个字母块
        return cx + drawBigNumber("--", at: cx, centerY: midY + 2, color: NSColor.white.withAlphaComponent(0.35))
      }
      let shown = numbersOnlyBottleneck ? [bottleneck ?? tool.windows[0]] : displayOrdered(tool.windows)
      for (index, window) in shown.enumerated() {
        if index > 0 { cx += 10 }
        let effective = (window.percent ?? 100) < 20 ? NSColor.systemRed : window.color
        if showsWindowTags {
          cx += drawVerticalLabel(shortLabel(window), at: cx, centerY: midY,
                                  color: NSColor.white.withAlphaComponent(0.55)) + 3
        }
        let text = valueString(window, suffix: percentSuffix)
        let numberWidth = drawBigNumber(text, at: cx, centerY: midY + 2, color: effective)
        drawResetUnderline(
          x: cx, width: numberWidth, reset: window.reset,
          mode: window.hourScale ? .hours : .days, color: effective
        )
        cx += numberWidth
      }
      return cx
    case .badgeQuad:
      // 详述：瓶颈大数字（竖排标签+下划线）+ 其余窗口 chips [色点+小数字]
      var cx = x
      let effective = (bottleneck?.percent ?? 100) < 20 ? NSColor.systemRed : heroColor
      if showsWindowTags, let label = bottleneck?.label {
        cx += drawVerticalLabel(label, at: cx, centerY: midY, color: NSColor.white.withAlphaComponent(0.55)) + 3
      }
      let text = valueString(bottleneck, suffix: percentSuffix)
      let numberWidth = drawBigNumber(text, at: cx, centerY: midY + 2, color: effective)
      drawResetUnderline(
        x: cx, width: numberWidth, reset: bottleneck?.reset,
        mode: (bottleneck?.hourScale ?? false) ? .hours : .days, color: effective
      )
      cx += numberWidth + 8
      for (index, window) in tool.windows.enumerated() where index != tool.bottleneckIndex {
        let dot = NSRect(x: cx, y: midY - 2, width: 4, height: 4)
        window.color.setFill()
        NSBezierPath(ovalIn: dot).fill()
        cx += 6
        draw(text: window.percent.map { "\(Int($0.rounded()))" } ?? "--",
             at: NSPoint(x: cx, y: midY),
             font: .monospacedDigitSystemFont(ofSize: 9, weight: .bold),
             color: window.color)
        cx += 20
      }
      return cx
    case .badge:
      // 数字微：瓶颈大数字 + 右侧竖排卫星点列
      var cx = x
      let effective = (bottleneck?.percent ?? 100) < 20 ? NSColor.systemRed : heroColor
      if showsWindowTags, let label = bottleneck?.label {
        cx += drawVerticalLabel(label, at: cx, centerY: midY, color: NSColor.white.withAlphaComponent(0.55)) + 3
      }
      let text = valueString(bottleneck, suffix: percentSuffix)
      let numberWidth = drawBigNumber(text, at: cx, centerY: midY + 2, color: effective)
      drawResetUnderline(
        x: cx, width: numberWidth, reset: bottleneck?.reset,
        mode: (bottleneck?.hourScale ?? false) ? .hours : .days, color: effective
      )
      cx += numberWidth
      if tool.windows.count > 1 {
        cx += 4
        let dotCount = tool.windows.count
        let totalH = CGFloat(dotCount) * 4 + CGFloat(dotCount - 1) * 2
        var dy = midY + totalH / 2 - 2
        for (index, window) in tool.windows.enumerated() {
          let used = 1 - max(0, min(1, (window.percent ?? 100) / 100))
          window.color.withAlphaComponent(0.3 + 0.7 * used).setFill()
          NSBezierPath(ovalIn: NSRect(x: cx, y: dy - 2, width: 4, height: 4)).fill()
          if index == tool.bottleneckIndex {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: cx - 0.5, y: dy - 2.5, width: 5, height: 5))
            ring.lineWidth = 0.5
            ring.stroke()
          }
          dy -= 6
        }
        cx += 6
      }
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
    showsCountdown: Bool = true,
    valueText: String? = nil
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

    let percentText = valueText ?? (percent.map { "\(Int($0.rounded()))\(showsPercentSign ? "%" : "")" } ?? "--")
    let percentString = NSAttributedString(
      string: percentText,
      attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: percentFontSize, weight: .heavy), .foregroundColor: effective]
    )
    let percentY = percentFontSize >= 18 ? centerY + 2 : centerY
    percentString.draw(at: NSPoint(x: x, y: percentY - percentString.size().height / 2))
    if percentFontSize >= 18 {
      // 大数字模式：数字下方画「距刷新」下划线进度条
      drawResetUnderline(x: x, width: percentString.size().width, reset: reset, mode: mode, color: effective)
    }
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

  /// 数字下方的「距刷新」下划线：淡色轨道 = 完整窗口，深色段 = 还要等的时间。
  /// 深色段走完（长度归零）即刷新。reset 为空时不画。
  private func drawResetUnderline(x: CGFloat, width: CGFloat, reset: Date?, mode: CountdownMode, color: NSColor) {
    guard let reset, width > 10 else { return }
    let windowSeconds: TimeInterval = mode == .hours ? 5 * 3600 : 7 * 24 * 3600
    let remaining = reset.timeIntervalSinceNow
    guard remaining > 0 else { return }
    let remainingFraction = max(0, min(1, remaining / windowSeconds))
    let fraction = resetProgressAscending ? 1 - remainingFraction : remainingFraction

    let barHeight: CGFloat = 3
    let y: CGFloat = 1.5
    let track = NSRect(x: x, y: y, width: width, height: barHeight)
    NSGraphicsContext.current?.saveGraphicsState()
    NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).addClip()
    color.withAlphaComponent(0.28).setFill()
    track.fill()
    color.setFill()
    NSRect(x: x, y: y, width: width * fraction, height: barHeight).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
  }

  /// 「全数字」样式的短标签：竖排每字符占 10pt，而 Touch Bar 只有 30pt 高，
  /// 所以最多 2 个字符，否则会顶出边界。
  ///   5 小时窗口      → 5时
  ///   模型专属周窗口  → 模型名前 2 字（如 Fable → Fa），靠颜色进一步区分
  ///   账号级周窗口    → 7天（和 Codex 的写法保持一致）
  /// 数字位置的文本：预付费平台显示金额，其余显示百分比
  private func valueString(_ w: TouchBarStripController.TBWindow?, suffix: String) -> String {
    if let text = w?.valueText { return text }
    return w?.percent.map { "\(Int($0.rounded()))\(suffix)" } ?? "--"
  }

  private func shortLabel(_ w: TouchBarStripController.TBWindow) -> String {
    if w.valueText != nil { return "余额" }   // 预付费平台：金额本身就是标签，这里只标性质
    if w.hourScale { return "5时" }
    if let range = w.label.range(of: "·"), !w.label.contains("全部") {
      let model = String(w.label[range.upperBound...])
      return String(model.prefix(2))
    }
    return "7天"
  }

  /// 「全数字」样式的窗口顺序：模型专属（如 周·Fable）→ 小时窗口（5时）→ 账号级周窗口。
  /// 用户最关心模型专属额度，放最左；顺序固定，不随瓶颈变化而跳位。
  private func displayOrdered(_ windows: [TouchBarStripController.TBWindow])
    -> [TouchBarStripController.TBWindow] {
    func rank(_ w: TouchBarStripController.TBWindow) -> Int {
      if w.hourScale { return 1 }                       // 5 小时窗口
      if w.label.contains("·") && !w.label.contains("全部") { return 0 }  // 模型专属，如 周·Fable
      return 2                                          // 周·全部 等账号级
    }
    return windows.enumerated()
      .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
      .map(\.element)
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
