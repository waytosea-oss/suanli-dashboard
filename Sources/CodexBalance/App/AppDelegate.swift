import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // 单实例锁：LaunchAgent 守护 + 登录项 + 手动打开可能同时拉起多个副本，
    // 每个副本都会各自去读钥匙串 → 授权弹框风暴。这里只放行第一个，后来者立即退出。
    guard Self.acquireSingleInstanceLock() else {
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
