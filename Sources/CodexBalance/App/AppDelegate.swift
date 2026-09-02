import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 退出时把 Touch Bar 还给系统。
  /// 全宽面板用 presentSystemModalTouchBar 整条接管 Touch Bar，系统亮度/音量条会被盖住；
  /// 不还回去的话，即使本进程没了，TouchBarServer 里的接管状态仍在，
  /// 用户的控制条会一直消失，只能手动 killall ControlStrip 才能救回来。
  func applicationWillTerminate(_ notification: Notification) {
    TouchBarStripController.shared.releaseTouchBar()
  }

  /// pkill / kill 发的是 SIGTERM，不会走 applicationWillTerminate。
  /// 这里装信号处理器，保证被强杀时也先把 Touch Bar 交还。
  /// 用 DispatchSource 而非 signal(2) 的回调：后者只能调异步信号安全函数，
  /// 而 DispatchSource 的 handler 跑在正常线程上，可以安全调 AppKit。
  @MainActor private static var termSources: [DispatchSourceSignal] = []

  @MainActor
  static func installTerminationGuards() {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
      signal(sig, SIG_IGN)   // 交给 DispatchSource 接管，屏蔽默认「立即终止」行为
      let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      src.setEventHandler {
        MainActor.assumeIsolated {
          TouchBarStripController.shared.releaseTouchBar()
        }
        exit(0)
      }
      src.resume()
      termSources.append(src)
    }
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    Self.installTerminationGuards()
    // 单实例锁：LaunchAgent 守护 + 登录项 + 手动打开可能同时拉起多个副本，
    // 每个副本都会各自去读钥匙串 → 授权弹框风暴。这里只放行第一个，后来者立即退出。
    guard Self.acquireSingleInstanceLockEarly() else {
      // 已有实例在跑：把它带到前台，本副本退出
      let others = NSRunningApplication.runningApplications(
        withBundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.codex.balance-dashboard"
      ).filter { $0 != NSRunningApplication.current }
      others.first?.activate(options: [.activateAllWindows])
      NSApp.terminate(nil)
      return
    }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  nonisolated(unsafe) private static var lockFileDescriptor: Int32 = -1

  /// App.init 里的最早入口：在任何业务对象创建前抢锁（幂等）
  static func acquireSingleInstanceLockEarly() -> Bool {
    if lockFileDescriptor >= 0 { return true }
    return acquireSingleInstanceLock()
  }

  /// 用文件锁保证全局单实例（跨「不同路径的同一程序」也有效，比 bundleID 判断更稳）
  private static func acquireSingleInstanceLock() -> Bool {
    let lockPath = NSHomeDirectory()
      + "/Library/Application Support/CodexBalanceDashboard/.instance.lock"
    try? FileManager.default.createDirectory(
      atPath: (lockPath as NSString).deletingLastPathComponent,
      withIntermediateDirectories: true
    )
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return true } // 拿不到锁文件就不拦，避免误杀
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
      close(fd)
      return false // 已被另一实例持有
    }
    lockFileDescriptor = fd // 持有到进程退出，OS 自动释放
    return true
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
