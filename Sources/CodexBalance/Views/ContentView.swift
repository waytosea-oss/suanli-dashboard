import AppKit
import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var store: DashboardStore
  @State private var configuredWindow: NSWindow?
  @State private var lastManualMove: Date?
  @State private var isAutoMoving = false
  private let dodgeTimer = Timer.publish(every: 45, on: .main, in: .common).autoconnect()

  var body: some View {
    Group {
      if store.isCompact {
        CompactDashboardView()
          .frame(
            width: WindowConfigurator.compactSize(for: store.compactSizeMode, style: store.compactStyle).width,
            height: WindowConfigurator.compactSize(for: store.compactSizeMode, style: store.compactStyle).height
          )
      } else {
        ExpandedDashboardView()
          .frame(width: WindowConfigurator.expandedSize.width, height: WindowConfigurator.expandedSize.height)
      }
    }
    .background(WindowAccessor { window in
      guard configuredWindow !== window else { return }
      configuredWindow = window
      WindowConfigurator.configure(
        window,
        compact: store.isCompact,
        compactSizeMode: store.compactSizeMode,
        compactStyle: store.compactStyle,
        keepPosition: false
      )
      autoDodgeIfNeeded(force: true)
    })
    .onAppear {
      store.startAutoRefresh()
    }
    .onDisappear {
      store.stopAutoRefresh()
    }
    .onChange(of: store.isCompact) { _, isCompact in
      if let configuredWindow {
        WindowConfigurator.configure(
          configuredWindow,
          compact: isCompact,
          compactSizeMode: store.compactSizeMode,
          compactStyle: store.compactStyle,
          keepPosition: false
        )
        autoDodgeIfNeeded(force: true)
      }
    }
    .onChange(of: store.compactSizeMode) { _, compactSizeMode in
      if let configuredWindow, store.isCompact {
        WindowConfigurator.configure(
          configuredWindow,
          compact: true,
          compactSizeMode: compactSizeMode,
          compactStyle: store.compactStyle,
          keepPosition: false
        )
      }
    }
    .onChange(of: store.compactStyle) { _, compactStyle in
      if let configuredWindow, store.isCompact {
        WindowConfigurator.configure(
          configuredWindow,
          compact: true,
          compactSizeMode: store.compactSizeMode,
          compactStyle: compactStyle,
          keepPosition: true
        )
      }
    }
    .onChange(of: store.autoDodgeEnabled) { _, enabled in
      if enabled { autoDodgeIfNeeded(force: true) }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMoveNotification)) { notification in
      guard let window = notification.object as? NSWindow,
            window === configuredWindow,
            !isAutoMoving
      else { return }
      lastManualMove = Date()
    }
    .onReceive(dodgeTimer) { _ in
      autoDodgeIfNeeded(force: false)
    }
  }

  /// 自动避让：把折叠浮窗挪到「被其他窗口覆盖最少」的角落。
  /// force=true（启动/开关切换/收起时）立即执行；定时触发则尊重用户手动拖动（10 分钟内不打扰）。
  private func autoDodgeIfNeeded(force: Bool) {
    guard store.autoDodgeEnabled,
          store.isCompact,
          let window = configuredWindow
    else { return }
    if !force,
       let lastManualMove,
       Date().timeIntervalSince(lastManualMove) < 600 {
      return
    }
    let size = WindowConfigurator.compactSize(for: store.compactSizeMode, style: store.compactStyle)
    guard let origin = WindowAutoPlacer.bestCornerOrigin(for: size, window: window) else { return }
    let current = window.frame.origin
    guard abs(current.x - origin.x) > 2 || abs(current.y - origin.y) > 2 else { return }
    isAutoMoving = true
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.28
      window.animator().setFrameOrigin(origin)
    }, completionHandler: {
      Task { @MainActor in isAutoMoving = false }
    })
  }
}
