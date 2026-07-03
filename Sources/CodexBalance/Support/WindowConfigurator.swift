import AppKit

@MainActor
enum WindowConfigurator {
  // 方案 B：并排双组双环，胶囊加宽
  static let compactSize = NSSize(width: 320, height: 196)
  static let miniCompactSize = NSSize(width: 236, height: 148)
  static let expandedSize = NSSize(width: 620, height: 820)

  static func compactSize(
    for mode: CompactSizeMode,
    style: CompactStyle = .rings,
    toolCount: Int = 2
  ) -> NSSize {
    let dual = toolCount >= 2
    switch style {
    case .rings:
      if mode == .mini {
        return dual ? miniCompactSize : NSSize(width: 138, height: 148)
      }
      return dual ? compactSize : NSSize(width: 184, height: 196)
    case .bars:
      if mode == .mini {
        return NSSize(width: 212, height: dual ? 62 : 42)
      }
      return NSSize(width: 248, height: dual ? 74 : 50)
    case .barsQuad:
      if mode == .mini {
        return NSSize(width: 212, height: dual ? 104 : 62)
      }
      return NSSize(width: 248, height: dual ? 122 : 74)
    case .badge:
      if mode == .mini {
        return NSSize(width: dual ? 138 : 80, height: 34)
      }
      return NSSize(width: dual ? 158 : 92, height: 40)
    case .badgeQuad:
      if mode == .mini {
        return NSSize(width: dual ? 208 : 118, height: 34)
      }
      return NSSize(width: dual ? 238 : 134, height: 40)
    }
  }

  static func configure(
    _ window: NSWindow,
    compact: Bool,
    compactSizeMode: CompactSizeMode = .standard,
    compactStyle: CompactStyle = .rings,
    toolCount: Int = 2,
    keepPosition: Bool = true
  ) {
    window.title = "算力码表"
    window.styleMask = [.borderless, .resizable]
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.level = .floating
    window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    window.isMovableByWindowBackground = true
    let resolvedCompactSize = compactSize(for: compactSizeMode, style: compactStyle, toolCount: toolCount)
    window.minSize = compact ? resolvedCompactSize : NSSize(width: 560, height: 720)
    window.maxSize = compact ? resolvedCompactSize : NSSize(width: 760, height: 940)

    let targetSize = compact ? resolvedCompactSize : expandedSize
    let origin = keepPosition ? window.frame.origin : topRightOrigin(for: targetSize, window: window)
    window.setFrame(NSRect(origin: origin, size: targetSize), display: true, animate: true)
  }

  private static func topRightOrigin(for size: NSSize, window: NSWindow) -> NSPoint {
    let screen = window.screen ?? NSScreen.main
    guard let visible = screen?.visibleFrame else {
      return NSPoint(x: 80, y: 80)
    }
    return NSPoint(
      x: visible.maxX - size.width - 18,
      y: visible.maxY - size.height - 18
    )
  }
}

/// 自动避让：把浮窗挪到四个角落中「被其他窗口覆盖最少」的那个。
/// 只用 CGWindowList 的窗口边界（现代 macOS 上无需屏幕录制权限；窗口标题才需要，这里不读标题）。
@MainActor
enum WindowAutoPlacer {
  private static let margin: CGFloat = 18

  /// 返回最优角落的 origin；nil 表示无法计算（保持原位）。
  static func bestCornerOrigin(for size: NSSize, window: NSWindow) -> NSPoint? {
    guard let screen = window.screen ?? NSScreen.main else { return nil }
    let visible = screen.visibleFrame

    // 其他 App 在屏的窗口边界（Cocoa 坐标）
    let others = onScreenWindowRects(excludingPID: ProcessInfo.processInfo.processIdentifier)

    let candidates: [NSPoint] = [
      NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin), // 右上
      NSPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin),              // 左上
      NSPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin),               // 右下
      NSPoint(x: visible.minX + margin, y: visible.minY + margin)                             // 左下
    ]

    var best: (origin: NSPoint, overlap: CGFloat)?
    for origin in candidates {
      let rect = NSRect(origin: origin, size: size)
      let overlap = others.reduce(CGFloat(0)) { $0 + $1.intersection(rect).area }
      if best == nil || overlap < best!.overlap {
        best = (origin, overlap)
      }
      if overlap == 0 { break } // 候选按优先级排列，遇到完全空白的角落直接用
    }
    return best?.origin
  }

  /// 读取所有在屏窗口的边界并转换为 Cocoa 坐标（原点左下）。
  private static func onScreenWindowRects(excludingPID pid: Int32) -> [NSRect] {
    guard let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements],
      kCGNullWindowID
    ) as? [[String: Any]] else {
      return []
    }

    // CGWindow 坐标原点在主屏左上；转 Cocoa 需要主屏高度
    let mainScreenHeight = NSScreen.screens.first?.frame.maxY ?? 0

    var rects: [NSRect] = []
    for item in info {
      guard let ownerPID = item[kCGWindowOwnerPID as String] as? Int32,
            ownerPID != pid,
            let layer = item[kCGWindowLayer as String] as? Int,
            layer == 0, // 只统计普通应用窗口，忽略菜单栏/Dock/悬浮层
            let boundsDict = item[kCGWindowBounds as String] as? [String: CGFloat],
            let x = boundsDict["X"], let y = boundsDict["Y"],
            let w = boundsDict["Width"], let h = boundsDict["Height"],
            w > 40, h > 40, // 忽略微型辅助窗口
            let alpha = item[kCGWindowAlpha as String] as? CGFloat, alpha > 0.05
      else { continue }
      let cocoaY = mainScreenHeight - y - h
      rects.append(NSRect(x: x, y: cocoaY, width: w, height: h))
    }
    return rects
  }
}

private extension NSRect {
  var area: CGFloat {
    isEmpty ? 0 : width * height
  }
}
