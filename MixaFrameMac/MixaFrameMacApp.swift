import SwiftUI

@main
struct MixaFrameMacApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var store = AppStore()
  @StateObject private var subscriptions = SubscriptionStore()

  var body: some Scene {
    WindowGroup {
      MacLibraryView()
        .environmentObject(store)
        .environmentObject(subscriptions)
        .tint(.indigo)
        .frame(
          minWidth: 820,
          maxWidth: .infinity,
          minHeight: 680,
          maxHeight: .infinity
        )
        .onChange(of: scenePhase) { _, phase in
          guard phase == .active else { return }
          store.resumeImageCacheLoading()
          Task { await subscriptions.refreshEntitlements() }
        }
    }
    .defaultSize(width: 1_440, height: 900)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) { }
    }
  }
}
