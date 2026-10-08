import AppKit
import SwiftUI

@MainActor
final class MacAppTerminationController: NSObject, NSApplicationDelegate, ObservableObject {
  var shouldTerminate: (() -> Bool)?
  private var allowsNextTermination = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if allowsNextTermination {
      allowsNextTermination = false
      return .terminateNow
    }
    return shouldTerminate?() == false ? .terminateCancel : .terminateNow
  }

  func terminateAfterResolvingChanges() {
    allowsNextTermination = true
    NSApp.terminate(nil)
  }
}

struct MacWindowCloseGuard: NSViewRepresentable {
  let shouldClose: () -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(shouldClose: shouldClose)
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async { context.coordinator.attach(to: view.window) }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.shouldClose = shouldClose
    DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.detach(from: nsView.window)
  }

  final class Coordinator: NSObject, NSWindowDelegate {
    var shouldClose: () -> Bool
    private weak var window: NSWindow?
    private weak var forwardedDelegate: NSWindowDelegate?

    init(shouldClose: @escaping () -> Bool) {
      self.shouldClose = shouldClose
    }

    func attach(to window: NSWindow?) {
      guard let window, window.delegate !== self else { return }
      detach(from: self.window)
      forwardedDelegate = window.delegate
      self.window = window
      window.delegate = self
    }

    func detach(from window: NSWindow?) {
      guard let window, window.delegate === self else { return }
      window.delegate = forwardedDelegate
      self.window = nil
      forwardedDelegate = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      guard shouldClose() else { return false }
      return forwardedDelegate?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
      super.responds(to: selector) || forwardedDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
      if forwardedDelegate?.responds(to: selector) == true { return forwardedDelegate }
      return super.forwardingTarget(for: selector)
    }
  }
}

struct MacEditorCommandActions {
  let save: () -> Void
  let addPhotos: () -> Void
  let export: () -> Void
  let toggleControls: () -> Void
}

private struct MacEditorCommandActionsKey: FocusedValueKey {
  typealias Value = MacEditorCommandActions
}

extension FocusedValues {
  var macEditorCommandActions: MacEditorCommandActions? {
    get { self[MacEditorCommandActionsKey.self] }
    set { self[MacEditorCommandActionsKey.self] = newValue }
  }
}

private struct MacWindowCommands: Commands {
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(after: .windowList) {
      Button("Show MixaFrame Window") {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }
      .keyboardShortcut("0", modifiers: .command)
    }
  }
}

private struct MacProjectCommands: Commands {
  @FocusedValue(\.macEditorCommandActions) private var actions

  var body: some Commands {
    CommandGroup(replacing: .saveItem) {
      Button("Save Project") { actions?.save() }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(actions == nil)
    }

    CommandMenu("Project") {
      Button("Add Photos…") { actions?.addPhotos() }
        .keyboardShortcut("o", modifiers: .command)
        .disabled(actions == nil)
      Button("Export Preview…") { actions?.export() }
        .keyboardShortcut("e", modifiers: [.command, .shift])
        .disabled(actions == nil)
      Divider()
      Button("Show or Hide Editing Tools") { actions?.toggleControls() }
        .keyboardShortcut("\\", modifiers: .command)
        .disabled(actions == nil)
    }
  }
}

@main
struct MixaFrameMacApp: App {
  @NSApplicationDelegateAdaptor(MacAppTerminationController.self)
  private var terminationController
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
    Window("MixaFrame", id: "main") {
      MacLibraryView()
        .environmentObject(store)
        .environmentObject(subscriptions)
        .environmentObject(terminationController)
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
      MacWindowCommands()
      MacProjectCommands()
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
