import SwiftUI

@main
struct MixaFrameApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var store = AppStore()
  @StateObject private var subscriptions = SubscriptionStore()

  var body: some Scene {
    WindowGroup {
      ProjectListView()
        .environmentObject(store)
        .environmentObject(subscriptions)
        .tint(.indigo)
        .onChange(of: scenePhase) { _, phase in
          guard phase == .active else { return }
          Task { await subscriptions.refreshEntitlements() }
        }
    }
  }
}
