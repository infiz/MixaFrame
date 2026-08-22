import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct MacEditorAlert: Identifiable {
  let id = UUID()
  let title: String
  let message: String

  static func error(_ error: Error) -> MacEditorAlert {
    MacEditorAlert(title: "MixaFrame", message: error.localizedDescription)
  }
}

private enum MacEditorTool: String, CaseIterable, Identifiable {
  case photos
  case layout
  case canvas
  case output

  var id: String { rawValue }

  var title: String {
    switch self {
    case .photos: "Photos"
    case .layout: "Layouts"
    case .canvas: "Canvas"
    case .output: "Export"
    }
  }

  var symbol: String {
    switch self {
    case .photos: "photo.on.rectangle.angled"
    case .layout: "square.grid.3x3"
    case .canvas: "aspectratio"
    case .output: "square.and.arrow.up"
    }
  }
}

private enum MacPendingExitAction {
  case saveAndExport
  case saveAndLeave
  case discard
  case subscribe
}

struct MacProjectEditorView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var subscriptions: SubscriptionStore
  @Environment(\.dismiss) private var dismiss
  let collectionID: UUID
  @State private var draft: Project
  @State private var savedSnapshot: Project
  @State private var selectedPhotoID: UUID?
  @State private var selectedFamily: LayoutFamily
  @State private var isImporting = false
  @State private var isSaving = false
  @State private var isExporting = false
  @State private var presentedAlert: MacEditorAlert?
  @State private var isDropTargeted = false
  @State private var activeEditorTool: MacEditorTool = .photos
  @State private var isControlsHidden = false
  @State private var isRenamePresented = false
  @State private var pendingTitle = ""
  @State private var isExitConfirmationPresented = false
  @State private var isSaveChoicePresented = false
  @State private var pendingExitAction: MacPendingExitAction?
  @State private var showingSubscription = false

  init(collectionID: UUID, project: Project) {
    self.collectionID = collectionID
    _draft = State(initialValue: project)
    _savedSnapshot = State(initialValue: project)
    _selectedPhotoID = State(initialValue: project.photos.first?.id)
    _selectedFamily = State(
      initialValue: LayoutEngine.selectedTemplate(for: project).family.browserFamily)
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack(alignment: .trailing) {
        editorLayout(size: proxy.size)

        if isControlsHidden {
          fullCanvasRestoreButton
            .padding(12)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle(displayName)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          if hasUnsavedChanges {
            pendingExitAction = nil
            isExitConfirmationPresented = true
          } else {
            dismiss()
          }
        } label: {
          Label("Back", systemImage: "chevron.left")
        }
        .disabled(isBusy)
      }

      ToolbarItem(placement: .principal) {
        Button {
          pendingTitle = draft.name
          isRenamePresented = true
        } label: {
          HStack(spacing: 5) {
            Text(displayName)
              .font(.headline)
              .lineLimit(1)
            Image(systemName: "pencil")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit project title")
        .disabled(isBusy)
      }

      ToolbarItem(placement: .primaryAction) {
        Button("Save") { presentSaveChoices() }
          .disabled(isBusy || draft.photos.count < 2)
      }
    }
    .sheet(isPresented: $isExitConfirmationPresented, onDismiss: completeExitAction) {
      unsavedChangesSheet
    }
    .sheet(isPresented: $isSaveChoicePresented) {
      saveProjectSheet
    }
    .sheet(isPresented: $showingSubscription) {
      SubscriptionView()
        .environmentObject(subscriptions)
    }
    .alert("Edit Project Title", isPresented: $isRenamePresented) {
      TextField("Project title", text: $pendingTitle)
      Button("Cancel", role: .cancel) {}
      Button("Done") {
        let title = pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { draft.name = title }
      }
      .disabled(pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    } message: {
      Text("Enter the title shown for this project.")
    }
    .alert(item: $presentedAlert) { alert in
      Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard !urls.isEmpty, !isBusy else { return false }
      importPhotos(urls)
      return true
    } isTargeted: { isTargeted in
      isDropTargeted = isTargeted
    }
    .overlay {
      if isDropTargeted {
        MacPhotoDropOverlay()
          .allowsHitTesting(false)
      }
    }
  }

  private var unsavedChangesSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Unsaved Changes")
          .font(.title2.bold())
        Spacer()
        Button("Keep Editing") {
          isExitConfirmationPresented = false
        }
      }

      Divider()

      if draft.photos.count >= 2 {
        Button {
          chooseExitAction(.saveAndExport)
        } label: {
          Label("Save and Export", systemImage: "square.and.arrow.down")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)

        Button {
          chooseExitAction(.saveAndLeave)
        } label: {
          Label("Save and Leave", systemImage: "rectangle.portrait.and.arrow.right")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
      }

      if !subscriptions.hasPremiumAccess {
        Button {
          chooseExitAction(.subscribe)
        } label: {
          HStack(spacing: 10) {
            Label("Subscribe to remove the watermark", systemImage: "crown.fill")
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
          }
          .font(.subheadline.weight(.semibold))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.indigo)
        .disabled(!subscriptions.hasLoadedEntitlements)
        .accessibilityHint("Opens MixaFrame Premium subscription options")
      }

      Button(role: .destructive) {
        chooseExitAction(.discard)
      } label: {
        Label("Discard Changes", systemImage: "trash")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
    }
    .padding(20)
    .frame(width: 420)
  }

  private var saveProjectSheet: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Save Project")
          .font(.title2.bold())
        Spacer()
        Button("Cancel") { isSaveChoicePresented = false }
      }

      Divider()

      Button {
        isSaveChoicePresented = false
        beginSaving(dismissAfterSave: false) { export() }
      } label: {
        Label("Save and Export", systemImage: "square.and.arrow.down")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)

      Button {
        isSaveChoicePresented = false
        beginSaving(dismissAfterSave: false)
      } label: {
        Label("Save and Keep Editing", systemImage: "square.and.pencil")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
    }
    .padding(20)
    .frame(width: 420)
  }

  private func chooseExitAction(_ action: MacPendingExitAction) {
    pendingExitAction = action
    isExitConfirmationPresented = false
  }

  private func completeExitAction() {
    guard let action = pendingExitAction else { return }
    pendingExitAction = nil

    switch action {
    case .saveAndExport:
      beginSaving(dismissAfterSave: false) { export() }
    case .saveAndLeave:
      beginSaving(dismissAfterSave: true)
    case .discard:
      let discardedDraft = draft
      Task {
        await store.discardUnsavedProjectFiles(from: discardedDraft)
        dismiss()
      }
    case .subscribe:
      showingSubscription = true
    }
  }

  @ViewBuilder
  private func editorLayout(size: CGSize) -> some View {
    let usesSideControls = size.width >= 960

    if isControlsHidden {
      previewStage
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if usesSideControls {
      HStack(spacing: 8) {
        previewStage
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .layoutPriority(1)

        HStack(spacing: 8) {
          settingsPanel
          rightToolBar
            .frame(width: 54)
        }
        .padding(.vertical, 8)
        .padding(.trailing, 8)
        .frame(width: min(540, max(410, size.width * 0.4)))
      }
    } else {
      VStack(spacing: 8) {
        previewStage
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .layoutPriority(1)

        VStack(spacing: 8) {
          settingsPanel
          bottomToolBar
            .frame(height: 54)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(height: min(430, max(320, size.height * 0.5)))
      }
    }
  }

  private var previewStage: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)
      if draft.photos.isEmpty {
        ContentUnavailableView {
          Label("No Photos", systemImage: "photo.on.rectangle.angled")
        } description: {
          Text("Choose Add Photos or drop image files anywhere in the editor.")
        } actions: {
          Button("Add Photos") { presentPhotoImporter() }
            .buttonStyle(.borderedProminent)
        }
      } else {
        MacCollageCanvas(project: draft, imageLoader: store.image(for:))
          .padding(30)
      }

      if isBusy {
        VStack(spacing: 12) {
          ProgressView()
          Text(
            isExporting
              ? "Rendering full-resolution project…" : isImporting ? "Importing photos…" : "Saving…"
          )
          .font(.headline)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
      }
    }
    .clipped()
  }

  private var settingsPanel: some View {
    VStack(spacing: 0) {
      HStack {
        Label(activeEditorTool.title, systemImage: activeEditorTool.symbol)
          .font(.headline)

        if activeEditorTool == .photos {
          Text("\(draft.photos.count)/12")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.secondary)

          Button("Add Photos") { presentPhotoImporter() }
            .buttonStyle(.link)
            .disabled(isBusy || draft.photos.count >= 12)
        } else if activeEditorTool == .layout {
          canvasPicker
        } else if activeEditorTool == .canvas {
          backgroundToggle
        }

        Spacer()

        Button {
          withAnimation(.easeInOut(duration: 0.2)) { isControlsHidden = true }
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close tools")
      }
      .padding(.horizontal, 16)
      .frame(height: 48)

      Divider()

      Form {
        settingsSections(for: activeEditorTool)
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
  }

  @ViewBuilder
  private func settingsSections(for tool: MacEditorTool) -> some View {
    switch tool {
    case .photos:
      photosSettings
    case .layout:
      layoutSettings
    case .canvas:
      canvasSettings
    case .output:
      outputSettings
    }
  }

  private var photosSettings: some View {
    Group {
      Section {
        if isImporting {
          HStack {
            ProgressView()
            Text("Preparing fast previews and finding subjects…")
              .foregroundStyle(.secondary)
          }
        }

        ForEach(Array(draft.photos.enumerated()), id: \.element.id) { index, photo in
          Button {
            selectedPhotoID = photo.id
          } label: {
            HStack(spacing: 12) {
              Group {
                if let image = store.image(for: photo) {
                  Image(nsImage: image).resizable().scaledToFill()
                } else {
                  Color.secondary.opacity(0.15)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                }
              }
              .frame(width: 58, height: 44)
              .clipShape(RoundedRectangle(cornerRadius: 8))

              VStack(alignment: .leading, spacing: 3) {
                Text("Photo \(index + 1)")
                  .font(.subheadline.weight(.semibold))
                Text("\(photo.pixelWidth) × \(photo.pixelHeight)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Spacer()

              if selectedPhotoID == photo.id {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.indigo)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }

      if let selectedIndex {
        Section("Selected Photo") {
          LabeledContent("Position", value: "\(selectedIndex + 1) of \(draft.photos.count)")
          LabeledContent("Horizontal Focus") {
            Slider(value: focalBinding(index: selectedIndex, keyPath: \.focalX), in: 0...1)
          }
          LabeledContent("Vertical Focus") {
            Slider(value: focalBinding(index: selectedIndex, keyPath: \.focalY), in: 0...1)
          }
          LabeledContent("Zoom") {
            Slider(value: zoomBinding(index: selectedIndex), in: 1...4)
          }
          HStack {
            Button("Move Left", systemImage: "arrow.left") { moveSelected(by: -1) }
              .disabled(selectedIndex == 0)
            Button("Move Right", systemImage: "arrow.right") { moveSelected(by: 1) }
              .disabled(selectedIndex == draft.photos.count - 1)
          }
          Button("Remove Photo", systemImage: "trash", role: .destructive) {
            removeSelected()
          }
        }
      }
    }
  }

  private var layoutSettings: some View {
    Section {
      Picker("Family", selection: $selectedFamily) {
        ForEach(availableFamilies) { family in
          Label(family.title, systemImage: family.symbol).tag(family)
        }
      }
      .pickerStyle(.segmented)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
        ForEach(familyLayouts) { template in
          Button {
            selectLayout(template)
          } label: {
            HStack(spacing: 7) {
              Image(systemName: template.symbol)
              Text(template.title).lineLimit(1)
              Spacer(minLength: 0)
              if selectedTemplate.id == template.id {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.indigo)
              }
            }
            .font(.caption)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
              selectedTemplate.id == template.id
                ? Color.indigo.opacity(0.14) : Color.secondary.opacity(0.08),
              in: RoundedRectangle(cornerRadius: 9)
            )
          }
          .buttonStyle(.plain)
        }
      }

      valueSlider(
        title: "Spacing",
        value: spacingBinding,
        range: 0...40,
        valueLabel: "\(Int(draft.spacing))"
      )
      valueSlider(
        title: "Canvas Corners",
        value: $draft.canvasCornerRadius,
        range: 0...50,
        valueLabel: "\(Int(draft.canvasCornerRadius))%"
      )

      if !draft.usesAutomaticPhotoArrangement {
        Button("Arrange Photos by Best Fit", systemImage: "wand.and.stars") {
          draft.resetPhotosForAutomaticFit()
        }
      }
    }
  }

  private var canvasSettings: some View {
    Section {
      Text("Resolution")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
        ForEach(ResolutionPreset.allCases) { preset in
          Button {
            draft.outputMaxDimension = preset.rawValue
          } label: {
            HStack(spacing: 6) {
              Text(preset.title).lineLimit(1)
              Spacer(minLength: 0)
              if draft.outputMaxDimension == preset.rawValue {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.indigo)
              }
            }
            .font(.subheadline)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(
              draft.outputMaxDimension == preset.rawValue
                ? Color.indigo.opacity(0.12) : Color.secondary.opacity(0.08),
              in: RoundedRectangle(cornerRadius: 10)
            )
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  private var outputSettings: some View {
    Section {
      Button {
        export()
      } label: {
        HStack(spacing: 7) {
          Label("Export Image", systemImage: "square.and.arrow.up")
          if subscriptions.hasPremiumAccess {
            Image(systemName: "crown.fill")
              .foregroundStyle(.green)
              .accessibilityLabel("Premium active")
          }
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(
        isBusy || draft.photos.count < 2 || !subscriptions.hasLoadedEntitlements
      )

      if !subscriptions.hasPremiumAccess {
        Button {
          showingSubscription = true
        } label: {
          Label("Subscribe to remove the watermark", systemImage: "crown")
            .font(.subheadline)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.indigo)
        .disabled(!subscriptions.hasLoadedEntitlements)
      }

      Text("Output")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)

      Picker("Format", selection: $draft.outputFormat) {
        ForEach(OutputFormat.allCases) { format in
          Text(format.title).tag(format)
        }
      }
      .pickerStyle(.segmented)

      Text(draft.outputFormat.summary)
        .font(.caption)
        .foregroundStyle(.secondary)

      if draft.outputFormat == .png {
        LabeledContent("Quality", value: "Lossless")
      } else {
        Picker("Quality", selection: $draft.quality) {
          ForEach(OutputQuality.allCases) { quality in
            Text(quality.title).tag(quality)
          }
        }

        ForEach(OutputQuality.allCases) { quality in
          HStack {
            Text(quality.title)
            Spacer()
            Text(quality.summary)
              .font(.caption)
              .foregroundStyle(quality == draft.quality ? .primary : .secondary)
          }
        }
      }
    }
  }

  private var canvasPicker: some View {
    Picker(
      "Canvas",
      selection: Binding(
        get: { draft.canvas },
        set: { selectCanvas($0) }
      )
    ) {
      ForEach(CanvasPreset.allCases) { preset in
        Text(preset.title).tag(preset)
      }
    }
    .labelsHidden()
    .fixedSize()
  }

  private var backgroundToggle: some View {
    HStack(spacing: 6) {
      Image(systemName: draft.background.symbol)
        .foregroundStyle(.secondary)
      Toggle(
        "Project Background",
        isOn: Binding(
          get: { draft.background == .dark },
          set: { draft.background = $0 ? .dark : .white }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Project Background")
    .accessibilityValue(draft.background.title)
  }

  private var spacingBinding: Binding<Double> {
    Binding(
      get: { draft.spacing },
      set: { spacing in
        guard draft.spacing != spacing else { return }
        draft.spacing = spacing
        draft.layoutFrameOverrides = nil
        draft.clearSavedLayoutSnapshot()
      }
    )
  }

  private func valueSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    valueLabel: String
  ) -> some View {
    VStack(alignment: .leading) {
      HStack {
        Text(title)
        Spacer()
        Text(valueLabel)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      Slider(value: value, in: range, step: 1)
    }
  }

  private var bottomToolBar: some View {
    HStack(spacing: 12) {
      ForEach(MacEditorTool.allCases) { tool in
        toolButton(tool)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
  }

  private var rightToolBar: some View {
    VStack(spacing: 12) {
      ForEach(MacEditorTool.allCases) { tool in
        toolButton(tool)
      }
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 10)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    .overlay {
      RoundedRectangle(cornerRadius: 16)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
  }

  private func toolButton(_ tool: MacEditorTool) -> some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) { activeEditorTool = tool }
    } label: {
      Image(systemName: tool.symbol)
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 42, height: 42)
        .foregroundStyle(activeEditorTool == tool ? Color.white : Color.primary)
        .background(
          activeEditorTool == tool ? Color.indigo : Color.clear,
          in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay(alignment: .topTrailing) {
          if tool == .photos {
            Text("\(draft.photos.count)")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.white)
              .frame(minWidth: 17, minHeight: 17)
              .background(.indigo, in: Circle())
              .offset(x: 3, y: -3)
          }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tool.title)
    .accessibilityAddTraits(activeEditorTool == tool ? .isSelected : [])
  }

  private var fullCanvasRestoreButton: some View {
    Button {
      withAnimation(.easeInOut(duration: 0.2)) { isControlsHidden = false }
    } label: {
      Label("Edit", systemImage: "slider.horizontal.3")
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1) }
    }
    .buttonStyle(.plain)
    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
  }

  private var availableFamilies: [LayoutFamily] {
    LayoutFamily.browserCases.filter {
      !LayoutEngine.fittingLayoutSamples(family: $0, project: draft).isEmpty
    }
  }

  private var familyLayouts: [CollageLayoutTemplate] {
    LayoutEngine.fittingLayoutSamples(family: selectedFamily, project: draft)
  }

  private var selectedTemplate: CollageLayoutTemplate {
    LayoutEngine.selectedTemplate(for: draft)
  }

  private var selectedIndex: Int? {
    guard let selectedPhotoID else { return nil }
    return draft.photos.firstIndex { $0.id == selectedPhotoID }
  }

  private var displayName: String {
    draft.name
  }

  private var isBusy: Bool { isImporting || isSaving || isExporting }
  private var hasUnsavedChanges: Bool { draft.hasUserChanges(comparedTo: savedSnapshot) }

  private func selectLayout(_ template: CollageLayoutTemplate) {
    draft.layoutID = template.id
    draft.clearLayoutCustomization(invalidateExport: true)
    draft.clearCustomLayout()
    draft.clearSavedLayoutSnapshot()
    if let legacy = template.legacyLayout { draft.layout = legacy }
    draft.mainPhotoCount = LayoutEngine.mainPhotoCount(for: template)
    draft.resetPhotosForAutomaticFit()
  }

  private func selectCanvas(_ canvas: CanvasPreset) {
    guard draft.canvas != canvas else { return }
    draft.canvas = canvas
    draft.clearSavedLayoutSnapshot()
    draft.resetPhotosForAutomaticFit()
  }

  private func presentPhotoImporter() {
    let panel = NSOpenPanel()
    panel.title = "Add Photos"
    panel.message = "Choose the photos you want to add to this project."
    panel.prompt = "Add"
    panel.allowedContentTypes = MacMediaImportService.photoContentTypes
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.resolvesAliases = true

    let hostWindow = NSApp.keyWindow ?? NSApp.mainWindow
    let hostSize = hostWindow?.contentLayoutRect.size ?? NSSize(width: 1_200, height: 800)
    let visibleSize =
      hostWindow?.screen?.visibleFrame.size
      ?? NSScreen.main?.visibleFrame.size
      ?? NSSize(width: 1_440, height: 900)
    panel.minSize = NSSize(width: 900, height: 620)
    panel.setContentSize(
      NSSize(
        width: min(max(900, hostSize.width * 0.8), min(1_200, visibleSize.width - 100)),
        height: min(max(620, hostSize.height * 0.8), min(820, visibleSize.height - 120))
      )
    )

    let completion: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK else { return }
      importPhotos(panel.urls)
    }
    if let hostWindow {
      panel.beginSheetModal(for: hostWindow, completionHandler: completion)
    } else {
      panel.begin(completionHandler: completion)
    }
  }

  private func importPhotos(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    isImporting = true
    Task {
      let capacity = max(0, 12 - draft.photos.count)
      let result = await MacMediaImportService.importPhotos(
        from: urls,
        maximumCount: capacity,
        using: store
      )
      if !result.photos.isEmpty {
        draft.photos.append(contentsOf: result.photos)
        draft.clearLayoutCustomization(invalidateExport: true)
        draft.clearCustomLayout()
        draft.clearSavedLayoutSnapshot()
        draft.isPhotoOrderManuallyAdjusted = false
        let recommendation = LayoutEngine.recommendedCanvasAndTemplate(for: draft)
        draft.canvas = recommendation.canvas
        draft.layoutID = recommendation.template.id
        if let legacy = recommendation.template.legacyLayout { draft.layout = legacy }
        draft.mainPhotoCount = LayoutEngine.mainPhotoCount(for: recommendation.template)
        selectedFamily = recommendation.template.family.browserFamily
        selectedPhotoID = selectedPhotoID ?? result.photos.first?.id
      }
      isImporting = false
      if !result.ignoredFiles.isEmpty {
        presentedAlert = ignoredFilesAlert(
          result.ignoredFiles,
          importedCount: result.photos.count
        )
      }
    }
  }

  private func ignoredFilesAlert(
    _ ignoredFiles: [MacIgnoredPhotoFile],
    importedCount: Int
  ) -> MacEditorAlert {
    let summary =
      importedCount == 0
      ? "No files were imported."
      : "Imported \(importedCount) supported file\(importedCount == 1 ? "" : "s")."
    let details = ignoredFiles.map { "• \($0.filename): \($0.reason)" }.joined(separator: "\n")
    return MacEditorAlert(
      title: ignoredFiles.count == 1 ? "A File Was Ignored" : "Some Files Were Ignored",
      message: "\(summary)\n\n\(details)"
    )
  }

  @discardableResult
  private func saveDraft() async -> Bool {
    guard let saved = await store.saveProject(draft) else {
      presentedAlert = MacEditorAlert(
        title: "MixaFrame",
        message: store.alertMessage ?? "The project could not be saved."
      )
      return false
    }
    draft = saved
    savedSnapshot = saved
    return true
  }

  private func beginSaving(
    dismissAfterSave: Bool,
    completion: (() -> Void)? = nil
  ) {
    guard !isSaving else { return }
    isSaving = true
    Task { @MainActor in
      await Task.yield()
      guard await saveDraft() else {
        isSaving = false
        return
      }
      isSaving = false
      if dismissAfterSave {
        dismiss()
      } else {
        completion?()
      }
    }
  }

  private func presentSaveChoices() {
    Task { @MainActor in
      await Task.yield()
      isSaveChoicePresented = true
    }
  }

  private func export() {
    guard subscriptions.hasLoadedEntitlements else {
      Task {
        await subscriptions.refreshEntitlements()
        export()
      }
      return
    }
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [contentType(for: draft.outputFormat)]
    panel.nameFieldStringValue = CollageExportFileName.make(
      collectionName: store.collection(id: draft.collectionID)?.name ?? "Collection",
      projectName: draft.name,
      format: draft.outputFormat
    )
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    isExporting = true
    let exportDraft = draft
    let photoDirectory = store.photoDirectory
    let includesWatermark = !subscriptions.hasPremiumAccess
    Task {
      do {
        try await Task.detached(priority: .userInitiated) {
          try MacCollageRenderer.export(
            project: exportDraft,
            photoDirectory: photoDirectory,
            destination: destination,
            includesWatermark: includesWatermark
          )
        }.value
        if let saved = await store.saveProject(exportDraft) {
          draft = saved
          savedSnapshot = saved
        }
      } catch {
        presentedAlert = .error(error)
      }
      isExporting = false
    }
  }

  private func focalBinding(
    index: Int,
    keyPath: WritableKeyPath<CollagePhoto, Double>
  ) -> Binding<Double> {
    Binding(
      get: { draft.photos[index][keyPath: keyPath] },
      set: {
        draft.photos[index][keyPath: keyPath] = $0
        draft.photos[index].focusSource = .manual
      }
    )
  }

  private func zoomBinding(index: Int) -> Binding<Double> {
    Binding(
      get: { draft.photos[index].effectiveZoom },
      set: { draft.photos[index].zoom = $0 }
    )
  }

  private func moveSelected(by offset: Int) {
    lockCurrentAutomaticArrangement()
    guard let index = selectedIndex else { return }
    let destination = index + offset
    guard draft.photos.indices.contains(destination) else { return }
    _ = draft.swapPhotosForAutomaticFit(
      sourceID: draft.photos[index].id,
      targetID: draft.photos[destination].id
    )
  }

  private func lockCurrentAutomaticArrangement() {
    guard draft.usesAutomaticPhotoArrangement else {
      draft.isPhotoOrderManuallyAdjusted = true
      return
    }
    let size = LayoutEngine.outputSize(for: draft)
    let order = LayoutEngine.photoIndicesInVisualOrder(for: draft, in: size)
    if order.count == draft.photos.count {
      draft.photos = order.map { draft.photos[$0] }
    }
    draft.isPhotoOrderManuallyAdjusted = true
  }

  private func removeSelected() {
    guard let index = selectedIndex else { return }
    draft.photos.remove(at: index)
    draft.clearLayoutCustomization(invalidateExport: true)
    draft.clearCustomLayout()
    draft.clearSavedLayoutSnapshot()
    selectedPhotoID =
      draft.photos.indices.contains(index)
      ? draft.photos[index].id : draft.photos.last?.id
    let count = max(1, draft.photos.count)
    if LayoutCatalog.template(id: draft.layoutID, photoCount: count) == nil {
      let fallback =
        LayoutCatalog.compatibleTemplate(id: draft.layoutID, photoCount: count)
        ?? LayoutCatalog.selectedTemplate(for: draft)
      draft.layoutID = fallback.id
      selectedFamily = fallback.family.browserFamily
    }
  }

  private func contentType(for format: OutputFormat) -> UTType {
    switch format {
    case .jpeg: .jpeg
    case .png: .png
    case .heif: .heic
    case .webP: .webP
    }
  }

}

private struct MacPhotoDropOverlay: View {
  var body: some View {
    ZStack {
      Color.indigo.opacity(0.12)

      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(
          Color.indigo,
          style: StrokeStyle(lineWidth: 4, dash: [12, 8])
        )
        .padding(16)

      VStack(spacing: 12) {
        Image(systemName: "arrow.down.doc.fill")
          .font(.system(size: 44, weight: .semibold))
        Text("Drop Photos to Import")
          .font(.title2.bold())
        Text("Unsupported files will be ignored and listed after import.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(24)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Drop photos to import")
  }
}

struct MacCollageCanvas: View {
  let project: Project
  let imageLoader: (CollagePhoto) -> NSImage?

  var body: some View {
    GeometryReader { proxy in
      let outputSize = LayoutEngine.outputSize(for: project)
      let canvasSize = aspectFitSize(content: outputSize, container: proxy.size)
      let scaleX = canvasSize.width / max(outputSize.width, 1)
      let scaleY = canvasSize.height / max(outputSize.height, 1)
      let frames = LayoutEngine.layoutFrames(for: project, in: outputSize)

      ZStack(alignment: .topLeading) {
        Color.mixaFrame(hex: project.backgroundHex)
        ForEach(project.photos.indices, id: \.self) { index in
          if frames.indices.contains(index), let image = imageLoader(project.photos[index]) {
            let frame = scaledFrame(frames[index], x: scaleX, y: scaleY)
            MacPhotoCanvasCell(photo: project.photos[index], image: image, frame: frame)
              .frame(width: frame.rect.width, height: frame.rect.height)
              .position(x: frame.rect.midX, y: frame.rect.midY)
              .rotationEffect(.degrees(frame.rotationDegrees))
              .zIndex(Double(frame.zIndex))
          }
        }
      }
      .frame(width: canvasSize.width, height: canvasSize.height)
      .clipShape(
        RoundedRectangle(
          cornerRadius: min(canvasSize.width, canvasSize.height)
            * CGFloat(project.canvasCornerRadius / 100)
        )
      )
      .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
  }

  private func scaledFrame(_ frame: LayoutFrame, x: CGFloat, y: CGFloat) -> LayoutFrame {
    var result = frame
    result.rect = CGRect(
      x: frame.rect.minX * x,
      y: frame.rect.minY * y,
      width: frame.rect.width * x,
      height: frame.rect.height * y
    )
    return result
  }

  private func aspectFitSize(content: CGSize, container: CGSize) -> CGSize {
    let scale = min(
      container.width / max(content.width, 1),
      container.height / max(content.height, 1)
    )
    return CGSize(width: max(1, content.width * scale), height: max(1, content.height * scale))
  }
}

private struct MacPhotoCanvasCell: View {
  let photo: CollagePhoto
  let image: NSImage
  let frame: LayoutFrame

  var body: some View {
    GeometryReader { proxy in
      if frame.usesAspectFit {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(width: proxy.size.width, height: proxy.size.height)
      } else {
        let imageRatio = image.size.width / max(image.size.height, 1)
        let frameRatio = proxy.size.width / max(proxy.size.height, 1)
        let baseSize =
          imageRatio > frameRatio
          ? CGSize(width: proxy.size.height * imageRatio, height: proxy.size.height)
          : CGSize(width: proxy.size.width, height: proxy.size.width / max(imageRatio, 0.0001))
        let zoom = CGFloat(photo.effectiveZoom)
        let overflowX = max(0, baseSize.width * zoom - proxy.size.width)
        let overflowY = max(0, baseSize.height * zoom - proxy.size.height)
        Image(nsImage: image)
          .resizable()
          .frame(width: baseSize.width, height: baseSize.height)
          .scaleEffect(zoom)
          .offset(
            x: (0.5 - photo.focalX) * overflowX,
            y: (0.5 - photo.focalY) * overflowY
          )
          .frame(width: proxy.size.width, height: proxy.size.height)
      }
    }
    .clipShape(MacFrameClipShape(frame: frame))
  }
}

private struct MacFrameClipShape: Shape {
  let frame: LayoutFrame

  func path(in rect: CGRect) -> Path {
    if let points = frame.normalizedClipPolygon, points.count >= 3 {
      var path = Path()
      for (index, point) in points.enumerated() {
        let resolved = CGPoint(x: point.x * rect.width, y: point.y * rect.height)
        index == 0 ? path.move(to: resolved) : path.addLine(to: resolved)
      }
      path.closeSubpath()
      return path
    }
    if frame.cornerRadiusFraction >= 0.49 {
      return Path(ellipseIn: rect)
    }
    return Path(
      roundedRect: rect,
      cornerRadius: min(rect.width, rect.height) * max(0, frame.cornerRadiusFraction)
    )
  }
}

extension Color {
  fileprivate static func mixaFrame(hex: String) -> Color {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var value: UInt64 = 0xFFFFFF
    Scanner(string: cleaned).scanHexInt64(&value)
    return Color(
      red: Double((value >> 16) & 0xFF) / 255,
      green: Double((value >> 8) & 0xFF) / 255,
      blue: Double(value & 0xFF) / 255
    )
  }
}
