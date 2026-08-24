import SwiftUI

@main
struct MixaFrameMacApp: App {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var store: AppStore
  @StateObject private var subscriptions = SubscriptionStore()

  init() {
    #if DEBUG
      let screenshotRoot = ProcessInfo.processInfo.environment["MIXAFRAME_SCREENSHOT_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
      _store = StateObject(wrappedValue: AppStore(rootDirectory: screenshotRoot))
    #else
      _store = StateObject(wrappedValue: AppStore())
    #endif
  }

  var body: some Scene {
    WindowGroup {
      MacLibraryView()
        .environmentObject(store)
        .environmentObject(subscriptions)
        .preferredColorScheme(screenshotColorScheme)
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

  private var screenshotColorScheme: ColorScheme? {
    #if DEBUG
      ProcessInfo.processInfo.environment["MIXAFRAME_SCREENSHOT_ROOT"] == nil ? nil : .light
    #else
      nil
    #endif
  }
}
