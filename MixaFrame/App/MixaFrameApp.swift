import SwiftUI

@main
struct MixaFrameApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            ProjectListView()
                .environmentObject(store)
                .tint(.indigo)
        }
    }
}
