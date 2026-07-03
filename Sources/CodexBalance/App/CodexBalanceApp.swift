import SwiftUI

@main
struct CodexBalanceApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var store = DashboardStore()

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
