import SwiftUI

@main
struct MixaFrameMacApp: App {
  @StateObject private var store = AppStore()

  var body: some Scene {
    WindowGroup {
      MacLibraryView()
        .environmentObject(store)
        .tint(.indigo)
        .frame(
          minWidth: 820,
          maxWidth: .infinity,
          minHeight: 680,
          maxHeight: .infinity
        )
    }
    .defaultSize(width: 1_440, height: 900)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(replacing: .newItem) { }
    }
  }
}
