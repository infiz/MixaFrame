import AppKit
import CoreTransferable
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let macPhotoDropTypeIdentifiers = [UTType.image.identifier, UTType.fileURL.identifier]

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

private enum MacExitDestination {
  case library
  case terminate
}

struct MacProjectEditorView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var subscriptions: SubscriptionStore
  @EnvironmentObject private var terminationController: MacAppTerminationController
  @Environment(\.dismiss) private var dismiss
  @Environment(\.undoManager) private var undoManager
  let collectionID: UUID
  @StateObject private var undoHistory = ProjectUndoHistory()
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
  @State private var pendingExitDestination: MacExitDestination = .library
  @State private var showingSubscription = false
  @State private var preparedExport: MacPreparedCollageExport?
  @State private var viewingPhotoID: UUID?
  @State private var photoPickerItems: [PhotosPickerItem] = []
  @State private var recoverableDraft: RecoverableProjectDraft?
  @State private var draftCheckpointTask: Task<Void, Never>?
  @State private var exitsAfterSuccessfulExport = false
  @State private var completedMeaningfulWork = false
  @State private var continuousInteractionDepth = 0
  @State private var continuousInteractionSnapshot: Project?
  private let shouldPromptForRecovery: Bool
  private let onEditorClosed: () -> Void

  init(
    collectionID: UUID,
    project: Project,
    isExistingProject: Bool,
    savedProject: Project? = nil,
    isRecoveredDraft: Bool = false,
    onEditorClosed: @escaping () -> Void = {}
  ) {
    self.collectionID = collectionID
    _draft = State(initialValue: project)
    _savedSnapshot = State(initialValue: savedProject ?? project)
    _selectedPhotoID = State(initialValue: project.photos.first?.id)
    _selectedFamily = State(
      initialValue: LayoutEngine.selectedTemplate(for: project).family.browserFamily)
    _isControlsHidden = State(initialValue: isExistingProject)
    shouldPromptForRecovery = !isRecoveredDraft
    self.onEditorClosed = onEditorClosed
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
    .background {
      MacWindowCloseGuard {
        guard !isBusy else { return false }
        guard hasUnsavedChanges else { return true }
        requestExit(to: .terminate)
        return false
      }
    }
    .background {
      MacPhotoPromiseDropReceiver(
        isEnabled: !isBusy,
        isTargeted: $isDropTargeted,
        onReceive: { urls in
          importPhotos(urls, temporaryURLs: urls)
        },
        onFailure: {
          presentedAlert = MacEditorAlert(
            title: "Photos Could Not Be Imported",
            message: "The Photos app did not finish providing the selected files. Please try the drag again."
          )
        }
      )
    }
    .focusedSceneValue(
      \.macEditorCommandActions,
      MacEditorCommandActions(
        save: presentSaveChoices,
        addPhotos: presentPhotoImporter,
        export: export,
        toggleControls: toggleControls
      )
    )
    .navigationTitle(displayName)
    .navigationBarBackButtonHidden(true)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button {
          requestExit(to: .library)
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
          .keyboardShortcut("s", modifiers: .command)
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
    .sheet(item: $preparedExport, onDismiss: removePreparedExport) { export in
      MacExportPreviewView(
        export: export,
        suggestedFileName: CollageExportFileName.make(
          collectionName: store.collection(id: draft.collectionID)?.name ?? "Collection",
        projectName: draft.displayName,
          format: draft.outputFormat
        ),
        contentType: contentType(for: draft.outputFormat),
        onExported: exportPreparedFile,
        onShareStarted: persistSharedExport,
        onCancel: { exitsAfterSuccessfulExport = false },
        onSubscribe: subscriptions.hasPremiumAccess ? nil : { showingSubscription = true }
      )
    }
    .sheet(
      isPresented: Binding(
        get: { viewingPhotoID != nil },
        set: { if !$0 { viewingPhotoID = nil } }
      )
    ) {
      if let photoID = viewingPhotoID,
        let photo = draft.photos.first(where: { $0.id == photoID }),
        let image = store.image(for: photo)
      {
        MacOriginalPhotoViewer(
          image: image,
          focalX: photoBinding(id: photoID, keyPath: \.focalX),
          focalY: photoBinding(id: photoID, keyPath: \.focalY),
          zoom: photoZoomBinding(id: photoID),
          onDone: { viewingPhotoID = nil },
          onContinuousInteractionChanged: continuousInteractionChanged
        )
      }
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
    .alert(item: $recoverableDraft) { recovery in
      Alert(
        title: Text("Recover Unsaved Changes?"),
        message: Text("MixaFrame found a recovery copy from \(recovery.savedAt.formatted(date: .abbreviated, time: .shortened))."),
        primaryButton: .default(Text("Recover")) {
          undoHistory.reset()
          draft = recovery.project
          selectedFamily = LayoutEngine.selectedTemplate(for: recovery.project).family.browserFamily
          isControlsHidden = false
        },
        secondaryButton: .destructive(Text("Discard")) {
          Task {
            await store.discardDraft(projectID: recovery.id, removesUncommittedAssets: true)
          }
        }
      )
    }
    .onDrop(
      of: macPhotoDropTypeIdentifiers,
      isTargeted: $isDropTargeted,
      perform: importDroppedPhotos
    )
    .overlay {
      if isDropTargeted {
        MacPhotoDropOverlay()
          .allowsHitTesting(false)
      }
    }
    .onAppear {
      undoHistory.connect(undoManager: undoManager) { recoveredProject in
        draft = recoveredProject
        selectedFamily = LayoutEngine.selectedTemplate(for: recoveredProject).family.browserFamily
        selectedPhotoID = recoveredProject.photos.first?.id
      }
      if shouldPromptForRecovery {
        Task { await presentRecoveryIfNeeded() }
      }
      terminationController.shouldTerminate = {
        guard !isBusy else { return false }
        guard hasUnsavedChanges else { return true }
        requestExit(to: .terminate)
        return false
      }
    }
    .onDisappear {
      draftCheckpointTask?.cancel()
      terminationController.shouldTerminate = nil
      removePreparedExport()
    }
    .onChange(of: exportPreferenceSnapshot) { _, snapshot in snapshot.save() }
    .onChange(of: draft) { previous, current in
      guard continuousInteractionSnapshot == nil else { return }
      undoHistory.record(previous: previous, current: current)
      scheduleDraftCheckpoint(current)
    }
    .onChange(of: photoPickerItems) { _, items in
      guard !items.isEmpty else { return }
      importPhotosFromLibrary(items)
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
      exitsAfterSuccessfulExport = true
      beginSaving(dismissAfterSave: false) { export() }
    case .saveAndLeave:
      beginSaving(dismissAfterSave: false) { completeResolvedExit() }
    case .discard:
      completedMeaningfulWork = false
      let discardedDraft = draft
      Task {
        await store.discardDraft(projectID: discardedDraft.id)
        await store.discardUnsavedProjectFiles(from: discardedDraft)
        completeResolvedExit()
      }
    case .subscribe:
      showingSubscription = true
    }
  }

  private func requestExit(to destination: MacExitDestination) {
    guard !isBusy else { return }
    pendingExitDestination = destination
    if hasUnsavedChanges {
      pendingExitAction = nil
      isExitConfirmationPresented = true
    } else {
      completeResolvedExit()
    }
  }

  private func completeResolvedExit() {
    switch pendingExitDestination {
    case .library:
      if completedMeaningfulWork, draft.photos.count >= 2 {
        store.reviewPromptPolicy.recordCompletedUsage()
        completedMeaningfulWork = false
      }
      dismiss()
      Task { @MainActor in
        await Task.yield()
        onEditorClosed()
      }
    case .terminate:
      terminationController.terminateAfterResolvingChanges()
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
        interactiveProjectPreview
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

  @ViewBuilder
  private var interactiveProjectPreview: some View {
    if let flowAxis = LayoutEngine.flowAxis(for: draft) {
      GeometryReader { proxy in
        if flowAxis == .vertical {
          ScrollView(.vertical) {
            let width = max(1, proxy.size.width - 60)
            let outputSize = LayoutEngine.outputSize(for: draft)
            let height = width * outputSize.height / max(outputSize.width, 1)
            interactiveCanvas
              .frame(width: width, height: height)
              .padding(.horizontal, 30)
              .padding(.vertical, 24)
          }
        } else {
          ScrollView(.horizontal) {
            let height = max(1, proxy.size.height - 48)
            let outputSize = LayoutEngine.outputSize(for: draft)
            let width = height * outputSize.width / max(outputSize.height, 1)
            interactiveCanvas
              .frame(width: width, height: height)
              .padding(.horizontal, 24)
              .padding(.vertical, 24)
          }
        }
      }
    } else {
      interactiveCanvas.padding(30)
    }
  }

  private var interactiveCanvas: some View {
    MacCollageCanvas(
      project: draft,
      isInteractive: true,
      selectedPhotoID: selectedPhotoID,
      imageLoader: store.image(for:),
      onSelectPhoto: { selectedPhotoID = $0 },
      onViewPhoto: { viewingPhotoID = $0 },
      onAdjustCrop: adjustCrop,
      onAdjustZoom: adjustZoom,
      onMovePhoto: movePhoto,
      onRemovePhoto: removePhoto,
      onAdjustLayoutDivider: adjustLayoutDivider,
      onContinuousInteractionChanged: continuousInteractionChanged
    )
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

          PhotosPicker(
            selection: $photoPickerItems,
            maxSelectionCount: max(0, 12 - draft.photos.count),
            matching: .images
          ) {
            Text("Photos Library")
          }
          .buttonStyle(.link)
          .disabled(isBusy || draft.photos.count >= 12)

          Button("Files…") { presentPhotoImporter() }
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
            Slider(
              value: focalBinding(index: selectedIndex, keyPath: \.focalX),
              in: 0...1,
              onEditingChanged: continuousInteractionChanged
            )
          }
          LabeledContent("Vertical Focus") {
            Slider(
              value: focalBinding(index: selectedIndex, keyPath: \.focalY),
              in: 0...1,
              onEditingChanged: continuousInteractionChanged
            )
          }
          LabeledContent("Zoom") {
            Slider(
              value: zoomBinding(index: selectedIndex),
              in: 1...4,
              onEditingChanged: continuousInteractionChanged
            )
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
      VStack(alignment: .leading, spacing: 7) {
        Text("Family")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.secondary)

        ScrollViewReader { familyProxy in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(availableFamilies) { family in
                Button {
                  selectedFamily = family
                } label: {
                  Label(family.title, systemImage: family.symbol)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .foregroundStyle(selectedFamily == family ? Color.white : Color.primary)
                    .background(
                      selectedFamily == family
                        ? Color.indigo : Color(nsColor: .controlBackgroundColor),
                      in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedFamily == family ? .isSelected : [])
                .id(family)
              }
            }
            .padding(.vertical, 2)
          }
          .onAppear { familyProxy.scrollTo(selectedFamily, anchor: .center) }
          .onChange(of: selectedFamily) { _, family in
            withAnimation(.easeInOut(duration: 0.2)) {
              familyProxy.scrollTo(family, anchor: .center)
            }
          }
        }
      }

      LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
        ForEach(familyLayouts) { template in
          Button {
            selectLayout(template)
          } label: {
            VStack(spacing: 7) {
              MacLayoutThumbnail(
                template: template,
                project: draft,
                isSelected: selectedTemplate.id == template.id
              )
              HStack(spacing: 5) {
                Text(template.title).lineLimit(1)
                Spacer(minLength: 0)
              }
              if selectedTemplate.id == template.id {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.indigo)
              }
            }
            .font(.caption)
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 92)
            .background(
              selectedTemplate.id == template.id
                ? Color.indigo.opacity(0.14) : Color.secondary.opacity(0.08),
              in: RoundedRectangle(cornerRadius: 9)
            )
          }
          .buttonStyle(.plain)
        }
      }

      if selectedFamily == .custom {
        if !matchingSavedCustomLayouts.isEmpty {
          Text("My Layouts")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
          ForEach(matchingSavedCustomLayouts) { layout in
            Button {
              selectSavedCustomLayout(layout)
            } label: {
              Label(
                layout.name,
                systemImage: draft.savedCustomLayoutID == layout.id
                  ? "checkmark.circle.fill" : "rectangle.split.2x2"
              )
            }
          }
        }
        Button("Save Current as My Layout", systemImage: "plus.rectangle.on.rectangle") {
          saveCurrentCustomLayout()
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

      VStack(alignment: .leading, spacing: 6) {
        HStack {
          Text("Custom")
          Spacer()
          Text("\(draft.outputMaxDimension) px")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Slider(
          value: Binding(
            get: { Double(draft.outputMaxDimension) },
            set: { draft.outputMaxDimension = Int($0.rounded()) }
          ),
          in: 512...8192,
          step: 128,
          onEditingChanged: continuousInteractionChanged
        )
      }

      let requestedSize = LayoutEngine.outputSize(for: draft)
      let renderedSize = MacCollageRenderer.renderedOutputSize(for: draft)
      LabeledContent(
        "Export Size",
        value: "\(Int(renderedSize.width)) × \(Int(renderedSize.height)) px"
      )
      if abs(requestedSize.width - renderedSize.width) > 0.5
        || abs(requestedSize.height - renderedSize.height) > 0.5
      {
        Text("This Flow layout is proportionally reduced to stay within a safe image size.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
        Text("PNG always preserves full image quality, so compression quality does not apply.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
      Slider(
        value: value,
        in: range,
        step: 1,
        onEditingChanged: continuousInteractionChanged
      )
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
    draft.displayName
  }

  private var isBusy: Bool { isImporting || isSaving || isExporting }
  private var hasUnsavedChanges: Bool { draft.hasUserChanges(comparedTo: savedSnapshot) }

  private func selectLayout(_ template: CollageLayoutTemplate) {
    let startingCustomFrames: [NormalizedLayoutFrame]? = {
      guard case .custom = template.recipe else { return nil }
      return normalizedCurrentLayoutFrames()
    }()
    draft.layoutID = template.id
    draft.clearLayoutCustomization(invalidateExport: true)
    draft.clearCustomLayout()
    draft.customLayoutFrames = startingCustomFrames
    draft.clearSavedLayoutSnapshot()
    if let legacy = template.legacyLayout { draft.layout = legacy }
    draft.mainPhotoCount = LayoutEngine.mainPhotoCount(for: template)
    draft.resetPhotosForAutomaticFit()
  }

  private var matchingSavedCustomLayouts: [SavedCustomLayout] {
    store.savedCustomLayouts.filter { $0.photoCount == draft.photos.count }
  }

  private func normalizedCurrentLayoutFrames() -> [NormalizedLayoutFrame] {
    var structuralProject = draft
    structuralProject.spacing = 0
    let size = LayoutEngine.outputSize(for: structuralProject)
    return LayoutEngine.layoutFrames(for: structuralProject, in: size).map {
      NormalizedLayoutFrame(rect: $0.rect, in: size)
    }
  }

  private func selectSavedCustomLayout(_ layout: SavedCustomLayout) {
    guard layout.photoCount == draft.photos.count else { return }
    draft.layoutID = LayoutCatalog.customTemplate(photoCount: draft.photos.count).id
    draft.customLayoutFrames = layout.frames
    draft.savedCustomLayoutID = layout.id
    draft.clearSavedLayoutSnapshot()
    draft.clearLayoutCustomization(invalidateExport: true)
    selectedFamily = .custom
    draft.resetPhotosForAutomaticFit()
  }

  private func saveCurrentCustomLayout() {
    let frames = normalizedCurrentLayoutFrames()
    guard frames.count == draft.photos.count else { return }
    Task {
      let sequence = matchingSavedCustomLayouts.count + 1
      guard let id = await store.createCustomLayout(
        name: "My Layout \(sequence)",
        photoCount: draft.photos.count,
        frames: frames
      ) else { return }
      draft.layoutID = LayoutCatalog.customTemplate(photoCount: draft.photos.count).id
      draft.customLayoutFrames = frames
      draft.savedCustomLayoutID = id
      draft.clearSavedLayoutSnapshot()
      draft.clearLayoutCustomization(invalidateExport: true)
      selectedFamily = .custom
    }
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

  private func importPhotosFromLibrary(_ items: [PhotosPickerItem]) {
    isImporting = true
    photoPickerItems = []
    Task {
      var temporaryURLs: [URL] = []
      var ignored: [MacIgnoredPhotoFile] = []
      for item in items.prefix(max(0, 12 - draft.photos.count)) {
        do {
          if let file = try await item.loadTransferable(type: MacImportedPhotoFile.self) {
            temporaryURLs.append(file.url)
          } else {
            ignored.append(
              MacIgnoredPhotoFile(filename: "Photos Library item", reason: "The photo could not be read")
            )
          }
        } catch {
          ignored.append(
            MacIgnoredPhotoFile(filename: "Photos Library item", reason: error.localizedDescription)
          )
        }
      }
      isImporting = false
      if temporaryURLs.isEmpty {
        if !ignored.isEmpty { presentedAlert = ignoredFilesAlert(ignored, importedCount: 0) }
      } else {
        importPhotos(
          temporaryURLs,
          temporaryURLs: temporaryURLs,
          additionalIgnoredFiles: ignored
        )
      }
    }
  }

  private func importPhotos(
    _ urls: [URL],
    temporaryURLs: [URL] = [],
    additionalIgnoredFiles: [MacIgnoredPhotoFile] = []
  ) {
    guard !urls.isEmpty else { return }
    isImporting = true
    Task {
      defer {
        for url in temporaryURLs {
          try? FileManager.default.removeItem(at: url)
        }
        let promiseDirectories = Set(
          temporaryURLs
            .map { $0.deletingLastPathComponent() }
            .filter { $0.lastPathComponent.hasPrefix("MixaFrame-Promised-") }
        )
        for directory in promiseDirectories {
          try? FileManager.default.removeItem(at: directory)
        }
      }
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
      let ignoredFiles = additionalIgnoredFiles + result.ignoredFiles
      if !ignoredFiles.isEmpty {
        presentedAlert = ignoredFilesAlert(
          ignoredFiles,
          importedCount: result.photos.count
        )
      }
    }
  }

  private func importDroppedPhotos(_ providers: [NSItemProvider]) -> Bool {
    guard !providers.isEmpty, !isBusy else { return false }
    isImporting = true
    Task {
      let maximumCount = max(0, 12 - draft.photos.count)
      var temporaryURLs: [URL] = []
      var ignoredFiles: [MacIgnoredPhotoFile] = []

      for provider in providers.prefix(maximumCount) {
        if let url = await materializeDroppedPhoto(from: provider) {
          temporaryURLs.append(url)
        } else {
          ignoredFiles.append(
            MacIgnoredPhotoFile(
              filename: provider.suggestedName ?? "Dropped photo",
              reason: "The photo could not be received from the source app"
            )
          )
        }
      }

      if providers.count > maximumCount {
        for provider in providers.dropFirst(maximumCount) {
          ignoredFiles.append(
            MacIgnoredPhotoFile(
              filename: provider.suggestedName ?? "Dropped photo",
              reason: "The project already contains the maximum of 12 photos"
            )
          )
        }
      }

      guard !temporaryURLs.isEmpty else {
        isImporting = false
        if !ignoredFiles.isEmpty {
          presentedAlert = ignoredFilesAlert(ignoredFiles, importedCount: 0)
        }
        return
      }

      isImporting = false
      importPhotos(
        temporaryURLs,
        temporaryURLs: temporaryURLs,
        additionalIgnoredFiles: ignoredFiles
      )
    }
    return true
  }

  private func materializeDroppedPhoto(from provider: NSItemProvider) async -> URL? {
    let suggestedName = provider.suggestedName
    let registeredIdentifiers = provider.registeredTypeIdentifiers
    let imageIdentifiers = registeredIdentifiers.filter { identifier in
      UTType(identifier)?.conforms(to: .image) == true
    }
    let promiseIdentifiers = registeredIdentifiers.filter { identifier in
      !imageIdentifiers.contains(identifier)
        && identifier != UTType.fileURL.identifier
        && identifier != "com.apple.NSFilePromiseItemMetaData"
        && identifier != "com.apple.pasteboard.promised-file-content-type"
    }

    for identifier in imageIdentifiers + promiseIdentifiers {
      if let url = await loadDroppedFileRepresentation(
        from: provider,
        typeIdentifier: identifier,
        suggestedName: suggestedName
      ) {
        return url
      }
    }

    guard provider.canLoadObject(ofClass: NSURL.self) else { return nil }
    return await withCheckedContinuation { continuation in
      provider.loadObject(ofClass: NSURL.self) { object, _ in
        guard let sourceURL = object as? URL else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(
          returning: copyDroppedPhotoToTemporaryStorage(
            from: sourceURL,
            typeIdentifier: UTType(filenameExtension: sourceURL.pathExtension)?.identifier,
            suggestedName: suggestedName
          )
        )
      }
    }
  }

  private func loadDroppedFileRepresentation(
    from provider: NSItemProvider,
    typeIdentifier: String,
    suggestedName: String?
  ) async -> URL? {
    await withCheckedContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { sourceURL, _ in
        guard let sourceURL else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(
          returning: copyDroppedPhotoToTemporaryStorage(
            from: sourceURL,
            typeIdentifier: typeIdentifier,
            suggestedName: suggestedName
          )
        )
      }
    }
  }

  private func copyDroppedPhotoToTemporaryStorage(
    from sourceURL: URL,
    typeIdentifier: String?,
    suggestedName: String?
  ) -> URL? {
    let suggestedExtension = suggestedName.map { URL(fileURLWithPath: $0).pathExtension }
    let fileExtension = [sourceURL.pathExtension, suggestedExtension]
      .compactMap { $0 }
      .first(where: { !$0.isEmpty })
      ?? typeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension }
      ?? "image"
    let destination = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFrame-Drop-\(UUID().uuidString)")
      .appendingPathExtension(fileExtension)
    do {
      try FileManager.default.copyItem(at: sourceURL, to: destination)
      return destination
    } catch {
      return nil
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
    let pendingCheckpoint = draftCheckpointTask
    pendingCheckpoint?.cancel()
    await pendingCheckpoint?.value
    draftCheckpointTask = nil
    let savedChanges = draft.hasUserChanges(comparedTo: savedSnapshot)
    guard let saved = await store.saveProject(draft) else {
      presentedAlert = MacEditorAlert(
        title: "MixaFrame",
        message: store.alertMessage ?? "The project could not be saved."
      )
      return false
    }
    completedMeaningfulWork = completedMeaningfulWork || savedChanges
    draft = saved
    savedSnapshot = saved
    await store.discardDraft(projectID: saved.id)
    undoHistory.reset()
    return true
  }

  private func presentRecoveryIfNeeded() async {
    guard let recovery = store.recoverableDraft(projectID: draft.id) else { return }
    if recovery.project.editorState == savedSnapshot.editorState {
      await store.discardDraft(projectID: recovery.id)
    } else {
      recoverableDraft = recovery
    }
  }

  private func scheduleDraftCheckpoint(_ project: Project) {
    draftCheckpointTask?.cancel()
    guard project.hasUserChanges(comparedTo: savedSnapshot) else {
      Task { await store.discardDraft(projectID: project.id) }
      return
    }
    draftCheckpointTask = Task {
      try? await Task.sleep(for: .milliseconds(700))
      guard !Task.isCancelled else { return }
      await store.persistDraft(project)
    }
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

  private func toggleControls() {
    guard !isBusy else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      isControlsHidden.toggle()
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
    isExporting = true
    let exportDraft = draft
    let photoDirectory = store.photoDirectory
    let includesWatermark = !subscriptions.hasPremiumAccess
    Task {
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          try MacCollageRenderer.prepareExport(
            project: exportDraft,
            photoDirectory: photoDirectory,
            includesWatermark: includesWatermark
          )
        }.value
        preparedExport = result
      } catch {
        presentedAlert = .error(error)
      }
      isExporting = false
    }
  }

  private func exportPreparedFile(_ export: MacPreparedCollageExport, to destination: URL) {
    let handoffURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFrame-Export-Handoff-\(UUID().uuidString)")
      .appendingPathExtension(export.fileURL.pathExtension)
    do {
      try FileManager.default.copyItem(at: export.fileURL, to: handoffURL)
    } catch {
      presentedAlert = .error(error)
      return
    }
    isExporting = true
    Task {
      defer { try? FileManager.default.removeItem(at: handoffURL) }
      do {
        try await Task.detached(priority: .userInitiated) {
          if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
          }
          try FileManager.default.copyItem(at: handoffURL, to: destination)
        }.value
        let persistedURL = try await store.persistExport(from: handoffURL, for: draft)
        draft.latestExportFileName = persistedURL.lastPathComponent
        guard await saveDraft() else { throw AppError.persistenceFailed }
        completedMeaningfulWork = true
        presentedAlert = MacEditorAlert(
          title: "Export Complete",
          message: "Your collage was saved as \(destination.lastPathComponent)."
        )
        if exitsAfterSuccessfulExport {
          exitsAfterSuccessfulExport = false
          completeResolvedExit()
        }
      } catch {
        presentedAlert = .error(error)
      }
      isExporting = false
    }
  }

  private func persistSharedExport(_ export: MacPreparedCollageExport) {
    Task {
      do {
        let persistedURL = try await store.persistExport(from: export.fileURL, for: draft)
        draft.latestExportFileName = persistedURL.lastPathComponent
        if await saveDraft() {
          completedMeaningfulWork = true
        }
      } catch {
        presentedAlert = .error(error)
      }
    }
  }

  private func removePreparedExport() {
    guard let preparedExport else { return }
    try? FileManager.default.removeItem(at: preparedExport.fileURL)
    self.preparedExport = nil
  }

  private var exportPreferenceSnapshot: MacExportPreferenceSnapshot {
    MacExportPreferenceSnapshot(project: draft)
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

  private func photoBinding(
    id: UUID,
    keyPath: WritableKeyPath<CollagePhoto, Double>
  ) -> Binding<Double> {
    Binding(
      get: { draft.photos.first(where: { $0.id == id })?[keyPath: keyPath] ?? 0 },
      set: { value in
        guard let index = draft.photos.firstIndex(where: { $0.id == id }) else { return }
        draft.photos[index][keyPath: keyPath] = value
        if keyPath == \.focalX || keyPath == \.focalY {
          draft.photos[index].focusSource = .manual
        }
      }
    )
  }

  private func adjustCrop(_ id: UUID, _ focalPoint: CGPoint) {
    guard let index = draft.photos.firstIndex(where: { $0.id == id }) else { return }
    draft.photos[index].focalX = min(1, max(0, focalPoint.x))
    draft.photos[index].focalY = min(1, max(0, focalPoint.y))
    draft.photos[index].focusSource = .manual
  }

  private func photoZoomBinding(id: UUID) -> Binding<Double> {
    Binding(
      get: { draft.photos.first(where: { $0.id == id })?.effectiveZoom ?? 1 },
      set: { value in
        guard let index = draft.photos.firstIndex(where: { $0.id == id }) else { return }
        draft.photos[index].zoom = min(4, max(1, value))
      }
    )
  }

  private func adjustZoom(_ id: UUID, _ zoom: Double) {
    guard let index = draft.photos.firstIndex(where: { $0.id == id }) else { return }
    draft.photos[index].zoom = min(4, max(1, zoom))
  }

  private func continuousInteractionChanged(_ isActive: Bool) {
    if isActive {
      if continuousInteractionDepth == 0 {
        continuousInteractionSnapshot = draft
        draftCheckpointTask?.cancel()
      }
      continuousInteractionDepth += 1
      return
    }

    continuousInteractionDepth = max(0, continuousInteractionDepth - 1)
    guard continuousInteractionDepth == 0, let startingProject = continuousInteractionSnapshot else {
      return
    }
    continuousInteractionSnapshot = nil
    undoHistory.record(previous: startingProject, current: draft)
    scheduleDraftCheckpoint(draft)
  }

  private func movePhoto(_ sourceID: UUID, _ targetID: UUID) {
    lockCurrentAutomaticArrangement()
    _ = draft.swapPhotosForAutomaticFit(sourceID: sourceID, targetID: targetID)
    selectedPhotoID = sourceID
  }

  private func removePhoto(_ id: UUID) {
    selectedPhotoID = id
    removeSelected()
  }

  private func adjustLayoutDivider(_ divider: LayoutDivider, delta: Double) {
    guard abs(delta) > 0.000_01 else { return }
    if var snapshot = LayoutEngine.activeSavedLayoutSnapshot(for: draft),
      let frames = LayoutEngine.adjustedSavedLayoutFrames(
        for: draft,
        moving: divider,
        normalizedDelta: delta
      )
    {
      snapshot.frames = frames
      draft.savedLayoutSnapshot = snapshot
      draft.invalidateExport()
      return
    }
    if draft.customLayoutFrames != nil,
      case .custom = LayoutEngine.selectedTemplate(for: draft).recipe
    {
      draft.customLayoutFrames = LayoutEngine.adjustedCustomLayoutFrames(
        for: draft,
        moving: divider,
        normalizedDelta: delta
      )
      draft.invalidateExport()
      return
    }
    if case .frames = divider.adjustment {
      draft.layoutFrameOverrides = LayoutEngine.adjustedFrameOverrides(
        for: draft,
        moving: divider,
        normalizedDelta: delta
      )
      draft.invalidateExport()
      return
    }
    let size = LayoutEngine.outputSize(for: draft)
    guard var adjustment = LayoutEngine.layoutAdjustmentGrid(for: draft, in: size) else { return }
    switch divider.axis {
    case .horizontal:
      resizeAdjacentWeights(
        &adjustment.rowWeights,
        firstIndex: divider.rowIndex,
        secondIndex: divider.rowIndex + 1,
        normalizedDelta: delta
      )
    case .vertical:
      guard adjustment.columnWeights.indices.contains(divider.rowIndex) else { return }
      resizeAdjacentWeights(
        &adjustment.columnWeights[divider.rowIndex],
        firstIndex: divider.dividerIndex,
        secondIndex: divider.dividerIndex + 1,
        normalizedDelta: delta
      )
    }
    draft.layoutRowWeights = adjustment.rowWeights
    draft.layoutColumnWeights = adjustment.columnWeights
    draft.invalidateExport()
  }

  private func resizeAdjacentWeights(
    _ weights: inout [Double],
    firstIndex: Int,
    secondIndex: Int,
    normalizedDelta: Double
  ) {
    guard weights.indices.contains(firstIndex), weights.indices.contains(secondIndex) else { return }
    let total = max(weights.reduce(0, +), 0.01)
    let combined = weights[firstIndex] + weights[secondIndex]
    let minimum = max(combined * 0.12, total * 0.04)
    let first = min(combined - minimum, max(minimum, weights[firstIndex] + normalizedDelta * total))
    weights[firstIndex] = first
    weights[secondIndex] = combined - first
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

private struct MacExportPreferenceSnapshot: Equatable {
  let outputFormat: OutputFormat
  let quality: OutputQuality
  let outputMaxDimension: Int
  let background: CollageBackground
  let spacing: Double
  let canvasCornerRadius: Double

  init(project: Project) {
    outputFormat = project.outputFormat
    quality = project.quality
    outputMaxDimension = project.outputMaxDimension
    background = project.background
    spacing = project.spacing
    canvasCornerRadius = project.canvasCornerRadius
  }

  func save() {
    MixaFrameExportPreferences.save(outputFormat: outputFormat)
    MixaFrameExportPreferences.save(quality: quality)
    MixaFrameExportPreferences.save(outputMaxDimension: outputMaxDimension)
    MixaFrameExportPreferences.save(background: background)
    MixaFrameExportPreferences.save(spacing: spacing)
    MixaFrameExportPreferences.save(canvasCornerRadius: canvasCornerRadius)
  }
}

private struct MacExportPreviewView: View {
  @Environment(\.dismiss) private var dismiss
  let export: MacPreparedCollageExport
  let suggestedFileName: String
  let contentType: UTType
  let onExported: (MacPreparedCollageExport, URL) -> Void
  let onShareStarted: (MacPreparedCollageExport) -> Void
  let onCancel: () -> Void
  let onSubscribe: (() -> Void)?
  @State private var zoom: CGFloat = 1

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Export Preview")
            .font(.title2.bold())
          Text("Review the final image before saving or sharing.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done") {
          onCancel()
          dismiss()
        }
          .keyboardShortcut(.cancelAction)
      }
      .padding(18)

      Divider()

      ScrollView([.horizontal, .vertical]) {
        Image(nsImage: export.previewImage)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(
            width: basePreviewSize.width * zoom,
            height: basePreviewSize.height * zoom
          )
          .padding(40)
      }
      .background(Color(nsColor: .underPageBackgroundColor))

      Divider()

      HStack(spacing: 14) {
        VStack(alignment: .leading, spacing: 3) {
          Text("\(Int(export.renderedSize.width)) × \(Int(export.renderedSize.height)) px")
            .font(.subheadline.weight(.semibold).monospacedDigit())
          if export.wasScaledForSafety {
            Text("Reduced proportionally from \(Int(export.requestedSize.width)) × \(Int(export.requestedSize.height)) for safe export.")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("Final rendered dimensions")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          if export.includesWatermark {
            Button("Watermark included · Remove with Premium") { onSubscribe?() }
              .buttonStyle(.link)
              .disabled(onSubscribe == nil)
          }
        }

        Spacer()

        HStack(spacing: 6) {
          Image(systemName: "minus.magnifyingglass")
          Slider(value: $zoom, in: 0.25...2, step: 0.05)
            .frame(width: 140)
          Image(systemName: "plus.magnifyingglass")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview zoom")

        ShareLink(item: export.fileURL) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
        .simultaneousGesture(TapGesture().onEnded { onShareStarted(export) })

        Button {
          saveExport()
        } label: {
          Label("Export…", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut("e", modifiers: [.command, .shift])
      }
      .padding(16)
    }
    .frame(minWidth: 760, idealWidth: 940, minHeight: 580, idealHeight: 720)
  }

  private var basePreviewSize: CGSize {
    macAspectFitSize(content: export.previewImage.size, container: CGSize(width: 720, height: 440))
  }

  private func saveExport() {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [contentType]
    panel.nameFieldStringValue = suggestedFileName
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    onExported(export, destination)
    dismiss()
  }
}

private struct MacLayoutThumbnail: View {
  let template: CollageLayoutTemplate
  let project: Project
  let isSelected: Bool

  private let displaySize = CGSize(width: 92, height: 56)

  var body: some View {
    let logicalSize: CGSize = {
      guard !isSelected else { return LayoutEngine.outputSize(for: project) }
      var previewProject = project
      previewProject.layoutID = template.id
      previewProject.mainPhotoCount = LayoutEngine.mainPhotoCount(for: template)
      previewProject.clearLayoutCustomization()
      previewProject.clearCustomLayout()
      previewProject.clearSavedLayoutSnapshot()
      return LayoutEngine.outputSize(for: previewProject)
    }()
    let frames = LayoutEngine.previewFrames(
      template: template,
      project: project,
      in: logicalSize,
      preservesCurrentAdjustments: isSelected
    )
    let scale = min(
      displaySize.width / max(logicalSize.width, 1),
      displaySize.height / max(logicalSize.height, 1)
    )
    let canvasSize = CGSize(width: logicalSize.width * scale, height: logicalSize.height * scale)
    let origin = CGPoint(
      x: (displaySize.width - canvasSize.width) / 2,
      y: (displaySize.height - canvasSize.height) / 2
    )

    ZStack(alignment: .topLeading) {
      Color(nsColor: .tertiaryLabelColor).opacity(0.12)
      Color.mixaFrame(hex: project.backgroundHex)
        .frame(width: canvasSize.width, height: canvasSize.height)
        .offset(x: origin.x, y: origin.y)
      ForEach(Array(frames.enumerated()), id: \.offset) { index, layoutFrame in
        let rect = CGRect(
          x: origin.x + layoutFrame.rect.minX * scale,
          y: origin.y + layoutFrame.rect.minY * scale,
          width: layoutFrame.rect.width * scale,
          height: layoutFrame.rect.height * scale
        )
        MacFrameClipShape(frame: layoutFrame)
          .fill(Color.indigo.opacity(index.isMultiple(of: 2) ? 0.78 : 0.46))
          .overlay { MacFrameClipShape(frame: layoutFrame).stroke(.white.opacity(0.7), lineWidth: 0.7) }
          .frame(width: rect.width, height: rect.height)
          .rotationEffect(.degrees(layoutFrame.rotationDegrees))
          .offset(x: rect.minX, y: rect.minY)
          .zIndex(Double(layoutFrame.zIndex))
      }
    }
    .frame(width: displaySize.width, height: displaySize.height)
    .clipped()
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(isSelected ? Color.indigo : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
    }
  }
}

private struct MacOriginalPhotoViewer: View {
  let image: NSImage
  @Binding var focalX: Double
  @Binding var focalY: Double
  @Binding var zoom: Double
  let onDone: () -> Void
  let onContinuousInteractionChanged: (Bool) -> Void
  @State private var previewZoom: CGFloat = 1

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("Adjust Photo")
            .font(.title2.bold())
          Text("Match the focus and zoom controls available on iPhone and iPad.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Done", action: onDone)
          .keyboardShortcut(.defaultAction)
      }
      .padding(18)

      Divider()

      ScrollView([.horizontal, .vertical]) {
        Image(nsImage: image)
          .resizable()
          .scaledToFit()
          .frame(
            width: basePreviewSize.width * previewZoom,
            height: basePreviewSize.height * previewZoom
          )
          .padding(40)
      }
      .background(Color(nsColor: .underPageBackgroundColor))

      Divider()

      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Horizontal Focus")
          Slider(
            value: $focalX,
            in: 0...1,
            onEditingChanged: onContinuousInteractionChanged
          )
          Text(focalX, format: .number.precision(.fractionLength(2))).monospacedDigit()
        }
        GridRow {
          Text("Vertical Focus")
          Slider(
            value: $focalY,
            in: 0...1,
            onEditingChanged: onContinuousInteractionChanged
          )
          Text(focalY, format: .number.precision(.fractionLength(2))).monospacedDigit()
        }
        GridRow {
          Text("Crop Zoom")
          Slider(
            value: $zoom,
            in: 1...4,
            onEditingChanged: onContinuousInteractionChanged
          )
          Text(zoom, format: .number.precision(.fractionLength(2))).monospacedDigit()
        }
        GridRow {
          Text("Viewer Zoom")
          Slider(value: $previewZoom, in: 0.25...2)
          Text(previewZoom, format: .number.precision(.fractionLength(2))).monospacedDigit()
        }
      }
      .frame(maxWidth: 620)
      .padding(18)
    }
    .frame(minWidth: 720, idealWidth: 900, minHeight: 560, idealHeight: 700)
  }

  private var basePreviewSize: CGSize {
    macAspectFitSize(content: image.size, container: CGSize(width: 680, height: 400))
  }
}

private func macAspectFitSize(content: CGSize, container: CGSize) -> CGSize {
  let scale = min(
    container.width / max(content.width, 1),
    container.height / max(content.height, 1)
  )
  return CGSize(width: max(1, content.width * scale), height: max(1, content.height * scale))
}

private struct MacImportedPhotoFile: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { receivedFile in
      let fileExtension = receivedFile.file.pathExtension.isEmpty
        ? "image" : receivedFile.file.pathExtension
      let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("MixaFrame-Photos-\(UUID().uuidString)")
        .appendingPathExtension(fileExtension)
      try FileManager.default.copyItem(at: receivedFile.file, to: temporaryURL)
      return MacImportedPhotoFile(url: temporaryURL)
    }
  }
}

private struct MacPhotoPromiseDropReceiver: NSViewRepresentable {
  let isEnabled: Bool
  @Binding var isTargeted: Bool
  let onReceive: ([URL]) -> Void
  let onFailure: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      isEnabled: isEnabled,
      onTargetedChange: { isTargeted = $0 },
      onReceive: onReceive,
      onFailure: onFailure
    )
  }

  func makeNSView(context: Context) -> NSView {
    let attachmentView = NSView(frame: .zero)
    DispatchQueue.main.async { context.coordinator.attach(to: attachmentView.window) }
    return attachmentView
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.isEnabled = isEnabled
    context.coordinator.onTargetedChange = { isTargeted = $0 }
    context.coordinator.onReceive = onReceive
    context.coordinator.onFailure = onFailure
    DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) }
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.detach()
  }

  final class Coordinator: NSObject {
    var isEnabled: Bool
    var onTargetedChange: (Bool) -> Void
    var onReceive: ([URL]) -> Void
    var onFailure: () -> Void
    private weak var window: NSWindow?
    private var originalContentView: NSView?
    private var originalTranslatesAutoresizingMaskIntoConstraints = true
    private var dropContainer: PromiseDropContainerView?

    init(
      isEnabled: Bool,
      onTargetedChange: @escaping (Bool) -> Void,
      onReceive: @escaping ([URL]) -> Void,
      onFailure: @escaping () -> Void
    ) {
      self.isEnabled = isEnabled
      self.onTargetedChange = onTargetedChange
      self.onReceive = onReceive
      self.onFailure = onFailure
    }

    func attach(to window: NSWindow?) {
      guard let window else { return }
      if self.window === window, window.contentView === dropContainer {
        updateContainerCallbacks()
        return
      }
      detach()
      guard let originalContentView = window.contentView else { return }

      let container = PromiseDropContainerView(frame: originalContentView.frame)
      container.autoresizingMask = [.width, .height]
      container.isEnabled = isEnabled
      container.onTargetedChange = onTargetedChange
      container.onReceive = onReceive
      container.onFailure = onFailure

      self.window = window
      self.originalContentView = originalContentView
      originalTranslatesAutoresizingMaskIntoConstraints =
        originalContentView.translatesAutoresizingMaskIntoConstraints
      self.dropContainer = container

      window.contentView = container
      originalContentView.translatesAutoresizingMaskIntoConstraints = true
      originalContentView.frame = container.bounds
      originalContentView.autoresizingMask = [.width, .height]
      container.addSubview(originalContentView)
    }

    func detach() {
      guard let window, let container = dropContainer, let originalContentView else {
        window = nil
        originalContentView = nil
        dropContainer = nil
        return
      }
      if window.contentView === container {
        originalContentView.removeFromSuperview()
        originalContentView.translatesAutoresizingMaskIntoConstraints =
          originalTranslatesAutoresizingMaskIntoConstraints
        window.contentView = originalContentView
      }
      self.window = nil
      self.originalContentView = nil
      self.dropContainer = nil
    }

    private func updateContainerCallbacks() {
      dropContainer?.isEnabled = isEnabled
      dropContainer?.onTargetedChange = onTargetedChange
      dropContainer?.onReceive = onReceive
      dropContainer?.onFailure = onFailure
    }
  }

  final class PromiseDropContainerView: NSView {
    var isEnabled = true
    var onTargetedChange: (Bool) -> Void = { _ in }
    var onReceive: ([URL]) -> Void = { _ in }
    var onFailure: () -> Void = {}

    override init(frame frameRect: NSRect) {
      super.init(frame: frameRect)
      registerForDraggedTypes(
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
      )
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      registerForDraggedTypes(
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
      )
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
      guard isEnabled, containsFilePromises(sender.draggingPasteboard) else { return [] }
      onTargetedChange(true)
      return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
      guard isEnabled, containsFilePromises(sender.draggingPasteboard) else { return [] }
      onTargetedChange(true)
      return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
      onTargetedChange(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
      onTargetedChange(false)
      guard isEnabled,
        let promises = sender.draggingPasteboard.readObjects(
          forClasses: [NSFilePromiseReceiver.self],
          options: nil
        ) as? [NSFilePromiseReceiver],
        !promises.isEmpty
      else { return false }

      receive(promises)
      return true
    }

    private func containsFilePromises(_ pasteboard: NSPasteboard) -> Bool {
      pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
    }

    private func receive(_ promises: [NSFilePromiseReceiver]) {
      let destinationDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MixaFrame-Promised-\(UUID().uuidString)", isDirectory: true)
      do {
        try FileManager.default.createDirectory(
          at: destinationDirectory,
          withIntermediateDirectories: true
        )
      } catch {
        onFailure()
        return
      }

      let operationQueue = OperationQueue()
      operationQueue.name = "MixaFrame Photos Drop"
      operationQueue.qualityOfService = .userInitiated
      operationQueue.maxConcurrentOperationCount = 2
      let lock = NSLock()
      var receivedURLs: [URL] = []
      var receivedAnError = false

      for promise in promises {
        promise.receivePromisedFiles(
          atDestination: destinationDirectory,
          options: [:],
          operationQueue: operationQueue
        ) { fileURL, error in
          lock.lock()
          if error == nil {
            receivedURLs.append(fileURL)
          } else {
            receivedAnError = true
          }
          lock.unlock()
        }
      }

      operationQueue.addBarrierBlock { [weak self] in
        lock.lock()
        let urls = receivedURLs
        let failed = receivedAnError
        lock.unlock()
        DispatchQueue.main.async {
          guard let self else { return }
          if !urls.isEmpty {
            self.onReceive(urls)
          } else {
            try? FileManager.default.removeItem(at: destinationDirectory)
            self.onFailure()
          }
          if failed && !urls.isEmpty {
            self.onFailure()
          }
        }
      }
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
  private static let interactionCoordinateSpace = "macProjectCanvas"

  let project: Project
  var isInteractive = false
  var selectedPhotoID: UUID? = nil
  let imageLoader: (CollagePhoto) -> NSImage?
  var onSelectPhoto: (UUID) -> Void = { _ in }
  var onViewPhoto: (UUID) -> Void = { _ in }
  var onAdjustCrop: (UUID, CGPoint) -> Void = { _, _ in }
  var onAdjustZoom: (UUID, Double) -> Void = { _, _ in }
  var onMovePhoto: (UUID, UUID) -> Void = { _, _ in }
  var onRemovePhoto: (UUID) -> Void = { _ in }
  var onAdjustLayoutDivider: (LayoutDivider, Double) -> Void = { _, _ in }
  var onContinuousInteractionChanged: (Bool) -> Void = { _ in }

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
            photoCell(
              project.photos[index],
              index: index,
              image: image,
              frame: frame
            )
          }
        }

        if isInteractive {
          ForEach(LayoutEngine.layoutDividers(for: project, in: outputSize)) { divider in
            let displayDivider = LayoutDivider(
              axis: divider.axis,
              rowIndex: divider.rowIndex,
              dividerIndex: divider.dividerIndex,
              start: CGPoint(x: divider.start.x * scaleX, y: divider.start.y * scaleY),
              end: CGPoint(x: divider.end.x * scaleX, y: divider.end.y * scaleY),
              adjustment: divider.adjustment
            )
            MacLayoutDividerHandle(
              divider: displayDivider,
              sourceDivider: divider,
              canvasSize: canvasSize,
              coordinateSpaceName: Self.interactionCoordinateSpace,
              onMove: onAdjustLayoutDivider,
              onInteractionChanged: onContinuousInteractionChanged
            )
            .frame(width: canvasSize.width, height: canvasSize.height)
            .zIndex(9_000)
          }
        }
      }
      .frame(width: canvasSize.width, height: canvasSize.height)
      .coordinateSpace(name: Self.interactionCoordinateSpace)
      .clipShape(
        RoundedRectangle(
          cornerRadius: min(canvasSize.width, canvasSize.height)
            * CGFloat(project.canvasCornerRadius / 100)
        )
      )
      .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
    }
  }

  private func photoCell(
    _ photo: CollagePhoto,
    index: Int,
    image: NSImage,
    frame: LayoutFrame
  ) -> some View {
    MacPhotoCanvasCell(photo: photo, image: image, frame: frame)
      .overlay {
        if selectedPhotoID == photo.id {
          MacFrameClipShape(frame: frame)
            .stroke(Color.accentColor, lineWidth: 3)
            .allowsHitTesting(false)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { onSelectPhoto(photo.id) }
      .onTapGesture(count: 2) { onViewPhoto(photo.id) }
      .modifier(
        MacPhotoInteractionModifier(
          photo: photo,
          imageSize: image.size,
          frameSize: frame.rect.size,
          coordinateSpaceName: Self.interactionCoordinateSpace,
          onCrop: { onAdjustCrop(photo.id, $0) },
          onZoom: { onAdjustZoom(photo.id, $0) },
          onInteractionChanged: onContinuousInteractionChanged
        )
      )
      .contextMenu { photoContextMenu(photo, index: index) }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Photo \(index + 1) of \(project.photos.count)")
      .accessibilityValue("\(photo.pixelWidth) by \(photo.pixelHeight) pixels")
      .accessibilityHint("Double click to view the original; drag to reposition")
      .accessibilityAction(named: "View Original") { onViewPhoto(photo.id) }
      .accessibilityAction(named: "Move Earlier") { movePhoto(photo, from: index, offset: -1) }
      .accessibilityAction(named: "Move Later") { movePhoto(photo, from: index, offset: 1) }
      .accessibilityAction(named: "Remove Photo") { onRemovePhoto(photo.id) }
      .accessibilityAdjustableAction { direction in
        let increment = direction == .increment ? 0.25 : -0.25
        onAdjustZoom(photo.id, min(4, max(1, photo.effectiveZoom + increment)))
      }
      .allowsHitTesting(isInteractive)
      .frame(width: frame.rect.width, height: frame.rect.height)
      .position(x: frame.rect.midX, y: frame.rect.midY)
      .rotationEffect(.degrees(frame.rotationDegrees))
      .zIndex(Double(frame.zIndex))
  }

  @ViewBuilder
  private func photoContextMenu(_ photo: CollagePhoto, index: Int) -> some View {
    Button("View Original") { onViewPhoto(photo.id) }
    if index > 0 {
      Button("Move Left") { movePhoto(photo, from: index, offset: -1) }
    }
    if index + 1 < project.photos.count {
      Button("Move Right") { movePhoto(photo, from: index, offset: 1) }
    }
    Divider()
    Button("Remove Photo", role: .destructive) { onRemovePhoto(photo.id) }
  }

  private func movePhoto(_ photo: CollagePhoto, from index: Int, offset: Int) {
    let destination = index + offset
    guard project.photos.indices.contains(destination) else { return }
    onMovePhoto(photo.id, project.photos[destination].id)
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

private struct MacPhotoInteractionModifier: ViewModifier {
  let photo: CollagePhoto
  let imageSize: CGSize
  let frameSize: CGSize
  let coordinateSpaceName: String
  let onCrop: (CGPoint) -> Void
  let onZoom: (Double) -> Void
  let onInteractionChanged: (Bool) -> Void
  @State private var dragStartFocal: CGPoint?
  @State private var magnifyStartZoom: Double?

  func body(content: Content) -> some View {
    content
      .gesture(
        DragGesture(minimumDistance: 3, coordinateSpace: .named(coordinateSpaceName))
          .onChanged { value in
            let start = dragStartFocal ?? CGPoint(x: photo.focalX, y: photo.focalY)
            if dragStartFocal == nil {
              dragStartFocal = start
              onInteractionChanged(true)
            }
            let overflow = cropOverflow
            let focalX = overflow.width > 0
              ? start.x - value.translation.width / overflow.width : start.x
            let focalY = overflow.height > 0
              ? start.y - value.translation.height / overflow.height : start.y
            onCrop(CGPoint(x: min(1, max(0, focalX)), y: min(1, max(0, focalY))))
          }
          .onEnded { _ in
            dragStartFocal = nil
            onInteractionChanged(false)
          }
      )
      .simultaneousGesture(
        MagnifyGesture()
          .onChanged { value in
            let start = magnifyStartZoom ?? photo.effectiveZoom
            if magnifyStartZoom == nil {
              magnifyStartZoom = start
              onInteractionChanged(true)
            }
            onZoom(start * Double(value.magnification))
          }
          .onEnded { _ in
            magnifyStartZoom = nil
            onInteractionChanged(false)
          }
      )
  }

  private var cropOverflow: CGSize {
        let imageRatio = imageSize.width / max(imageSize.height, 1)
        let frameRatio = frameSize.width / max(frameSize.height, 1)
        let baseSize = imageRatio > frameRatio
          ? CGSize(width: frameSize.height * imageRatio, height: frameSize.height)
          : CGSize(width: frameSize.width, height: frameSize.width / max(imageRatio, 0.0001))
        let zoom = CGFloat(photo.effectiveZoom)
    return CGSize(
      width: max(0, baseSize.width * zoom - frameSize.width),
      height: max(0, baseSize.height * zoom - frameSize.height)
    )
  }
}

private struct MacLayoutDividerHandle: View {
  let divider: LayoutDivider
  let sourceDivider: LayoutDivider
  let canvasSize: CGSize
  let coordinateSpaceName: String
  let onMove: (LayoutDivider, Double) -> Void
  let onInteractionChanged: (Bool) -> Void
  @State private var lastTranslation: CGSize?

  var body: some View {
    let hitTarget = path.strokedPath(
      StrokeStyle(lineWidth: 24, lineCap: .round, lineJoin: .round)
    )

    path
      .stroke(Color.black.opacity(0.001), style: StrokeStyle(lineWidth: 24, lineCap: .round))
      .contentShape(.interaction, hitTarget)
      .gesture(
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
          .onChanged { value in
            if lastTranslation == nil {
              onInteractionChanged(true)
            }
            let previousTranslation = lastTranslation ?? .zero
            let rawDelta = divider.axis == .horizontal
              ? value.translation.height - previousTranslation.height
              : value.translation.width - previousTranslation.width
            let dimension = divider.axis == .horizontal ? canvasSize.height : canvasSize.width
            lastTranslation = value.translation
            onMove(sourceDivider, Double(rawDelta / max(dimension, 1)))
          }
          .onEnded { _ in
            lastTranslation = nil
            onInteractionChanged(false)
          }
      )
      .accessibilityLabel(divider.axis == .horizontal ? "Resize adjacent rows" : "Resize adjacent columns")
      .accessibilityHint("Adjust to change the neighboring photo frame sizes")
      .accessibilityAdjustableAction { direction in
        onMove(sourceDivider, direction == .increment ? 0.02 : -0.02)
      }
  }

  private var path: Path {
    var path = Path()
    path.move(to: divider.start)
    path.addLine(to: divider.end)
    return path
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
