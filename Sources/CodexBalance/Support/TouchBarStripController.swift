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

  func update(codex: ToolData, claude: ToolData) {
    guard installed else { return }
    updateTrayText(codex: codex, claude: claude)
    panelView.codex = codex
    panelView.claude = claude
    panelView.needsDisplay = true
  }

  // MARK: - 托盘紧凑块

  private func updateTrayText(codex: ToolData, claude: ToolData) {
    let text = NSMutableAttributedString()
    func tighter(_ tool: ToolData) -> (Double?, NSColor) {
      let pairs: [(Double, NSColor)] = [
        tool.percent5.map { ($0, tool.color5) },
        tool.percent7.map { ($0, tool.color7) }
      ].compactMap { $0 }
      guard let minPair = pairs.min(by: { $0.0 < $1.0 }) else { return (nil, tool.color5) }
      return (minPair.0, minPair.1)
    }
    for (index, tool) in [codex, claude].enumerated() {
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
  var onOpenPanel: (() -> Void)?

  private let openButton = NSButton(title: "⤢", target: nil, action: nil)

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.cgColor
    openButton.target = self
    openButton.action = #selector(openPanel)
    openButton.bezelStyle = .rounded
    openButton.font = .systemFont(ofSize: 15, weight: .heavy)
    openButton.translatesAutoresizingMaskIntoConstraints = false
    addSubview(openButton)
    NSLayoutConstraint.activate([
      openButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
      openButton.widthAnchor.constraint(equalToConstant: 36)
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 640, height: 30)
  }

  @objc private func openPanel() {
    NSApp.activate(ignoringOtherApps: true)
    onOpenPanel?()
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor.black.setFill()
    bounds.fill()

    var x: CGFloat = 8
    if let codex {
      x = drawTool(codex, startX: x)
      x += 12
      drawSeparator(at: x)
      x += 12
    }
    if let claude {
      _ = drawTool(claude, startX: x)
    }
  }

  private func drawSeparator(at x: CGFloat) {
    NSColor.white.withAlphaComponent(0.16).setFill()
    NSRect(x: x, y: 4, width: 1, height: bounds.height - 8).fill()
  }

  /// 一个工具组：左边字母章，右边 5时/7天 两行上下叠放
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

    // 两行：上 5时、下 7天
    let topY = bounds.height * 0.72
    let bottomY = bounds.height * 0.28
    let widthTop = drawWindowRow(label: "5时", percent: tool.percent5, reset: tool.reset5, mode: .hours, color: tool.color5, startX: x, centerY: topY)
    let widthBottom = drawWindowRow(label: "7天", percent: tool.percent7, reset: tool.reset7, mode: .days, color: tool.color7, startX: x, centerY: bottomY)
    return x + max(widthTop, widthBottom)
  }

  /// 单行：标签 + 进度条 + 百分比 + 倒计时（紧凑行高），返回行宽
  private func drawWindowRow(
    label: String,
    percent: Double?,
    reset: Date?,
    mode: CountdownMode,
    color: NSColor,
    startX: CGFloat,
    centerY: CGFloat
  ) -> CGFloat {
    var x = startX
    let effective = (percent ?? 100) < 20 ? NSColor.systemRed : color

    draw(text: label, at: NSPoint(x: x, y: centerY), font: .systemFont(ofSize: 9, weight: .heavy), color: NSColor.white.withAlphaComponent(0.55))
    x += 22

    let barWidth: CGFloat = 116
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

    let percentText = percent.map { "\(Int($0.rounded()))%" } ?? "--"
    draw(text: percentText, at: NSPoint(x: x, y: centerY), font: .monospacedDigitSystemFont(ofSize: 11, weight: .heavy), color: effective)
    x += 36

    let resetText = BalanceFormatters.resetCountdownShort(reset, mode: mode)
    draw(text: resetText, at: NSPoint(x: x, y: centerY), font: .monospacedDigitSystemFont(ofSize: 9, weight: .bold), color: NSColor.white.withAlphaComponent(0.48))
    x += 50
    return x - startX
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
