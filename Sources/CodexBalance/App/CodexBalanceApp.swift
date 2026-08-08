import SwiftUI

@main
struct CodexBalanceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = DashboardStore()

  init() {
    // 单实例锁必须在 DashboardStore 创建之前判定：
    // 开机时登录项+守护会同时拉起多个副本，若锁检查晚于 Store 初始化，
    // 输掉的副本已经开始刷新流程（可能触碰钥匙串授权）才退出——正是
    // 开机密码风暴的放大器之一。这里在一切业务对象诞生前就出局。
    if !AppDelegate.acquireSingleInstanceLockEarly() {
      exit(0)
    }
  }

  var body: some Scene {
    WindowGroup("算力码表") {
      ContentView()
        .environmentObject(store)
    }
    .windowResizability(.contentSize)
    .commands {
      CommandGroup(replacing: .newItem) {}
    }
  }
}
