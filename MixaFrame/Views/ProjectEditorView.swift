import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ProjectEditorView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var subscriptions: SubscriptionStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.undoManager) private var undoManager
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @StateObject private var undoHistory = ProjectUndoHistory()
  @State private var draft: Project
  @State private var savedSnapshot: Project
  @State private var pickerItems: [PhotosPickerItem] = []
  @State private var showingExpandedPhotoPicker = false
  @State private var isImporting = false
  @State private var isSaving = false
  @State private var isExporting = false
  @State private var isControlsHidden = false
  @State private var isExitConfirmationPresented = false
  @State private var isRenamePresented = false
  @State private var pendingTitle = ""
  @State private var activeEditorTool: EditorTool
  @State private var selectedLayoutFamily: LayoutFamily
  @State private var shareItem: ShareItem?
  @State private var exportPreview: PreparedCollageExport?
  @State private var originalPhotoPreview: CollagePhoto?
  @State private var message: EditorMessage?
  @State private var showingSubscription = false
  @State private var pendingExportAction: PendingExportAction?
  @State private var isSaveChoicePresented = false
  @State private var pendingExitAction: PendingExitAction?
  @State private var isPhotoExportChoicePresented = false
  @State private var pendingPhotoLibraryExportMode: PhotoLibraryExportMode?
  @State private var recoverableDraft: RecoverableProjectDraft?
  @State private var draftCheckpointTask: Task<Void, Never>?
  @State private var exitsAfterSuccessfulExport = false
  @State private var completedMeaningfulWork = false
  private let shouldPromptForRecovery: Bool

  init(
    collectionID: UUID,
    project: Project?,
    savedProject: Project? = nil,
    isRecoveredDraft: Bool = false
  ) {
    let initialProject = Self.initialDraft(collectionID: collectionID, project: project)
    _draft = State(initialValue: initialProject)
    _savedSnapshot = State(initialValue: savedProject ?? initialProject)
    _isControlsHidden = State(initialValue: project != nil && !isRecoveredDraft)
    _activeEditorTool = State(initialValue: .photos)
    _selectedLayoutFamily = State(
      initialValue: LayoutEngine.selectedTemplate(for: initialProject).family.browserFamily)
    shouldPromptForRecovery = !isRecoveredDraft
  }

  static func initialDraft(
    collectionID: UUID,
    project: Project?,
    defaults: UserDefaults = .standard
  ) -> Project {
    if let project { return project }
    var draft = Project.new(collectionID: collectionID)
    MixaFrameExportPreferences.apply(to: &draft, defaults: defaults)
    return draft
  }

  private var exportPreferenceSnapshot: ExportPreferenceSnapshot {
    ExportPreferenceSnapshot(project: draft)
  }

  var body: some View {
    editorContent
      .onAppear {
        undoHistory.connect(undoManager: undoManager) { recoveredProject in
          draft = recoveredProject
          selectedLayoutFamily = LayoutEngine.selectedTemplate(for: recoveredProject).family.browserFamily
        }
        if shouldPromptForRecovery {
          Task { await presentRecoveryIfNeeded() }
        }
      }
      .onChange(of: draft) { previous, current in
        undoHistory.record(previous: previous, current: current)
        scheduleDraftCheckpoint(current)
      }
      .onDisappear { draftCheckpointTask?.cancel() }
      .alert(item: $recoverableDraft) { recovery in
        Alert(
          title: Text("Recover Unsaved Changes?"),
          message: Text("MixaFrame found a recovery copy from \(recovery.savedAt.formatted(date: .abbreviated, time: .shortened))."),
          primaryButton: .default(Text("Recover")) {
            undoHistory.reset()
            draft = recovery.project
            selectedLayoutFamily = LayoutEngine.selectedTemplate(for: recovery.project).family.browserFamily
            isControlsHidden = false
          },
          secondaryButton: .destructive(Text("Discard")) {
            Task {
              await store.discardDraft(
                projectID: recovery.id,
                removesUncommittedAssets: true
              )
            }
          }
        )
      }
      .sheet(isPresented: $isExitConfirmationPresented, onDismiss: completeExitAction) {
        unsavedChangesSheet
      }
      .sheet(isPresented: $isSaveChoicePresented) {
        saveProjectSheet
      }
      .sheet(isPresented: $isPhotoExportChoicePresented, onDismiss: completePhotoExportChoice) {
        if let identifier = draft.exportedPhotoLibraryAssetIdentifier {
          ExistingPhotoExportChoiceView(
            assetIdentifier: identifier,
            onSelect: { mode in
              pendingPhotoLibraryExportMode = mode
              isPhotoExportChoicePresented = false
            },
            onCancel: {
              pendingPhotoLibraryExportMode = nil
              isPhotoExportChoicePresented = false
            }
          )
          .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
          .presentationDragIndicator(.visible)
        }
      }
  }

  private var unsavedChangesSheet: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if draft.photos.count >= 2 {
            Button {
              chooseExitAction(.saveAndExport)
            } label: {
              Label("Save and Export", systemImage: "square.and.arrow.down")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
          }

          if draft.photos.count >= 2 {
            Button {
              chooseExitAction(.saveAndLeave)
            } label: {
              Label("Save and Leave", systemImage: "rectangle.portrait.and.arrow.right")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
          }

          Button(role: .destructive) {
            chooseExitAction(.discard)
          } label: {
            Label("Discard Changes", systemImage: "trash")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          .controlSize(.large)

          if !subscriptions.hasPremiumAccess {
            Button {
              chooseExitAction(.subscribe)
            } label: {
              HStack(alignment: .top, spacing: 10) {
                Image(systemName: "crown.fill")
                  .dynamicTypeSize(...DynamicTypeSize.large)
                  .accessibilityHidden(true)
                Text("Subscribe to remove the watermark")
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.semibold))
                  .dynamicTypeSize(...DynamicTypeSize.large)
                  .accessibilityHidden(true)
              }
              .font(.subheadline.weight(.semibold))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.indigo)
            .accessibilityHint("Opens MixaFrame Premium subscription options")
          }
        }
        .padding(20)
      }
      .navigationTitle("Unsaved Changes")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Keep Editing", systemImage: "xmark") {
            isExitConfirmationPresented = false
          }
        }
      }
    }
    .presentationDetents(dynamicTypeSize.isAccessibilitySize
      ? [.large] : [.height(subscriptions.hasPremiumAccess ? 300 : 350), .large])
    .presentationDragIndicator(.visible)
  }

  private var saveProjectSheet: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          Button {
            isSaveChoicePresented = false
            beginSaving(dismissAfterSave: false) {
              performExportAction(.saveToPhotos)
            }
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

          Button("Cancel", role: .cancel) {
            isSaveChoicePresented = false
          }
          .frame(maxWidth: .infinity)
        }
        .padding(20)
      }
      .navigationTitle("Save Project")
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(250), .large])
    .presentationDragIndicator(.visible)
  }

  private var renameProjectSheet: some View {
    NavigationStack {
      Form {
        Section {
          TextField("Project title", text: $pendingTitle, axis: .vertical)
            .lineLimit(1...4)
            .submitLabel(.done)
            .onSubmit(applyProjectTitle)
        } footer: {
          Text("The title shown for this project.")
        }
      }
      .navigationTitle("Project Title")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { isRenamePresented = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done", action: applyProjectTitle)
            .disabled(pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private func applyProjectTitle() {
    let title = pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    draft.name = title
    isRenamePresented = false
  }

  private func chooseExitAction(_ action: PendingExitAction) {
    pendingExitAction = action
    isExitConfirmationPresented = false
  }

  private func completeExitAction() {
    guard let action = pendingExitAction else { return }
    pendingExitAction = nil
    switch action {
    case .saveAndExport:
      exitsAfterSuccessfulExport = true
      beginSaving(dismissAfterSave: false) {
        performExportAction(.saveToPhotos)
      }
    case .saveAndLeave:
      beginSaving(dismissAfterSave: true)
    case .discard:
      let discardedDraft = draft
      Task {
        await store.discardDraft(projectID: discardedDraft.id)
        await store.discardUnsavedProjectFiles(from: discardedDraft)
        dismiss()
      }
    case .subscribe:
      showingSubscription = true
    }
  }

  private var editorContent: some View {
    NavigationStack {
      GeometryReader { proxy in
        let isLandscapeEditing =
          !isControlsHidden && workspaceLayout(for: proxy.size).usesSideBySide
        let workspaceWidth =
          isLandscapeEditing
          ? landscapePreviewWorkspaceWidth(for: proxy.size)
          : proxy.size.width

        ZStack(alignment: .trailing) {
          previewWorkspace(maximumHeight: previewMaximumHeight(for: proxy.size))
            .frame(width: workspaceWidth)
            .frame(
              maxWidth: .infinity,
              maxHeight: .infinity,
              alignment: isLandscapeEditing ? .leading : .top
            )
            .animation(.easeInOut(duration: 0.22), value: activeEditorTool)

          if isControlsHidden {
            fullCanvasRestoreButton
              .padding(12)
              .transition(.opacity.combined(with: .scale(scale: 0.9)))
          } else {
            editorControls(availableSize: proxy.size)
              .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
        .clipped()
      }
      .background(Color(uiColor: .systemGroupedBackground))
      .onChange(of: exportPreferenceSnapshot) { _, updatedPreferences in
        updatedPreferences.save()
      }
      .navigationTitle(draft.displayName)
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(true)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            hideKeyboard()
            if hasUnsavedChanges {
              pendingExitAction = nil
              isExitConfirmationPresented = true
            } else {
              finishEditing()
            }
          } label: {
            Label("Back", systemImage: "chevron.left")
          }
          .disabled(isImporting || isSaving || isExporting)
        }
        ToolbarItem(placement: .principal) {
          Button {
            pendingTitle = draft.titleForEditing
            isRenamePresented = true
          } label: {
            HStack(spacing: 5) {
              Text(draft.displayName)
                .font(.headline)
                .lineLimit(1)
              Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Edit project title")
          .disabled(isImporting || isSaving || isExporting)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("Save") {
            presentSaveChoices()
          }
          .keyboardShortcut("s", modifiers: .command)
          .disabled(draft.photos.count < 2 || isSaving || isExporting)
        }
        ToolbarItemGroup(placement: .keyboard) {
          Spacer()
          Button {
            hideKeyboard()
          } label: {
            Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down")
          }
        }
      }
      .overlay {
        if isSaving {
          ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 14) {
              Text("Saving project…").font(.headline)
              ProgressView()
                .progressViewStyle(.linear)
                .frame(width: 220)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
          }
        } else if isExporting {
          ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 12) {
              ProgressView().controlSize(.large)
              Text("Rendering full-resolution project…").font(.headline)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
          }
        }
      }
      .onChange(of: pickerItems) { _, newItems in
        guard !newItems.isEmpty else { return }
        importPhotos(newItems)
      }
      .task(id: store.imageCacheReloadGeneration) {
        await prepareEditorImagesAndFocusAreas()
      }
      .sheet(item: $shareItem) { item in
        ShareSheet(items: [item.url])
      }
      .sheet(isPresented: $showingSubscription) {
        SubscriptionView()
          .environmentObject(subscriptions)
      }
      .fullScreenCover(item: $exportPreview) { export in
        ExportPreviewView(
          export: export,
          formatTitle: draft.outputFormat.title,
          existingPhotoAssetIdentifier: draft.exportedPhotoLibraryAssetIdentifier,
          onSave: { mode in try await savePreparedExportToPhotos(export, mode: mode) },
          onShare: { try await sharePreparedExport(export) },
          onCancel: { cancelPreparedExport(export) }
        )
      }
      .fullScreenCover(item: $originalPhotoPreview) { photo in
        let cropConfiguration = cropConfiguration(for: photo.id)
        OriginalPhotoViewer(
          photo: photo,
          loadOriginal: { await store.originalImage(for: photo) },
          cropConfiguration: cropConfiguration,
          onSelectFocus: { adjustCrop(photoID: photo.id, focalPoint: $0) },
          onAdjustCropZoom: { adjustZoom(photoID: photo.id, zoom: $0) }
        )
      }
      .fullScreenCover(isPresented: $showingExpandedPhotoPicker) {
        ExpandedPhotoPicker(selectionLimit: max(0, 12 - draft.photos.count)) { selections in
          showingExpandedPhotoPicker = false
          guard !selections.isEmpty else { return }
          importPhotos(selections)
        }
        .ignoresSafeArea()
      }
      .sheet(isPresented: $isRenamePresented) {
        renameProjectSheet
      }
      .alert(item: $message) { message in
        Alert(
          title: Text(message.title), message: Text(message.detail),
          dismissButton: .default(Text("OK")))
      }
      .confirmationDialog(
        "Save Changes Before Exporting?",
        isPresented: isExportSaveDialogPresented,
        titleVisibility: .visible
      ) {
        Button("Save and Continue") {
          saveAndContinueExportAction()
        }
        Button("Continue Without Saving") {
          continueExportActionWithoutSaving()
        }
        Button("Cancel", role: .cancel) { pendingExportAction = nil }
      } message: {
        Text(
          "This project has changed since it was last saved. Save now so the exported image and saved project stay in sync."
        )
      }
    }
  }

  private func previewWorkspace(maximumHeight: CGFloat) -> some View {
    ProjectPreview(
      project: draft,
      imageLoader: store.previewImage(for:),
      onViewPhoto: { showOriginalPhoto(id: $0) },
      onMovePhoto: { swapPhotos(sourceID: $0, targetID: $1) },
      onAdjustCrop: { adjustCrop(photoID: $0, focalPoint: $1) },
      onAdjustZoom: { adjustZoom(photoID: $0, zoom: $1) },
      onAdjustLayoutDivider: adjustLayoutDivider,
      maximumHeight: maximumHeight
    )
    .padding(.horizontal, 16)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity)
    .background(Color(uiColor: .systemBackground))
  }

  @ViewBuilder
  private func editorControls(availableSize: CGSize) -> some View {
    let layout = workspaceLayout(for: availableSize)
    let panelWidth = layout.panelWidth
    let toolBarHeight: CGFloat = 56
    let settingsHeight = layout.settingsHeight

    if layout.usesSideBySide {
      let landscapePanelWidth = layout.panelWidth
      let landscapeControlsHeight = layout.settingsHeight

      ZStack(alignment: .trailing) {
        HStack(spacing: 8) {
          settingsPanel(
            for: activeEditorTool,
            width: landscapePanelWidth,
            height: landscapeControlsHeight
          )

          rightToolBar
            .frame(width: toolBarHeight)
        }
        .padding(.trailing, 8)
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
      .animation(.easeInOut(duration: 0.22), value: activeEditorTool)
    } else {
      ZStack(alignment: .bottom) {
        VStack(spacing: 8) {
          settingsPanel(
            for: activeEditorTool,
            width: panelWidth,
            height: settingsHeight
          )

          bottomToolBar
            .frame(width: panelWidth, height: toolBarHeight)
        }
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
      .animation(.easeInOut(duration: 0.22), value: activeEditorTool)
    }
  }

  private func workspaceLayout(for size: CGSize) -> EditorWorkspaceLayout {
    EditorWorkspaceLayout(
      size: size,
      controlsHidden: isControlsHidden,
      squareCanvas: usesSquareCanvas,
      accessibilityText: dynamicTypeSize.isAccessibilitySize
    )
  }

  private func previewMaximumHeight(for availableSize: CGSize) -> CGFloat {
    workspaceLayout(for: availableSize).previewHeight
  }

  private func landscapePreviewWorkspaceWidth(for availableSize: CGSize) -> CGFloat {
    workspaceLayout(for: availableSize).previewWidth
  }

  private var usesSquareCanvas: Bool {
    let outputSize = LayoutEngine.outputSize(for: draft)
    return abs(outputSize.width - outputSize.height) < 0.5
  }

  private var bottomToolBar: some View {
    HStack(spacing: 12) {
      ForEach(EditorTool.allCases) { tool in
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
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
  }

  private var rightToolBar: some View {
    VStack(spacing: 12) {
      ForEach(EditorTool.allCases) { tool in
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
    .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
  }

  private func toolButton(_ tool: EditorTool) -> some View {
    Button {
      hideKeyboard()
      withAnimation(.easeInOut(duration: 0.2)) {
        activeEditorTool = tool
      }
    } label: {
      Image(systemName: tool.symbol)
        .font(.system(size: 18, weight: .semibold))
        .frame(width: 44, height: 44)
        .foregroundStyle(activeEditorTool == tool ? Color.white : Color.primary)
        .background(
          activeEditorTool == tool ? Color.indigo : Color.clear,
          in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay(alignment: .topTrailing) {
          if tool == .photos {
            Text("\(draft.photos.count)")
              .font(.caption2.weight(.bold))
              .dynamicTypeSize(...DynamicTypeSize.large)
              .foregroundStyle(.white)
              .frame(minWidth: 17, minHeight: 17)
              .background(.indigo, in: Circle())
              .offset(x: 3, y: -3)
          }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tool.title)
    .accessibilityHint(activeEditorTool == tool ? "Current settings panel" : "Shows this panel")
    .accessibilityAddTraits(activeEditorTool == tool ? .isSelected : [])
  }

  private func requestExportAction(_ action: PendingExportAction) {
    hideKeyboard()
    guard draft.photos.count >= 2, hasUnsavedChanges else {
      performExportAction(action)
      return
    }
    pendingExportAction = action
  }

  private func saveAndContinueExportAction() {
    guard let action = pendingExportAction else { return }
    pendingExportAction = nil
    beginSaving(dismissAfterSave: false) {
      performExportAction(action)
    }
  }

  private func continueExportActionWithoutSaving() {
    guard let action = pendingExportAction else { return }
    pendingExportAction = nil
    performExportAction(action)
  }

  private func performExportAction(_ action: PendingExportAction) {
    switch action {
    case .preview:
      beginExport(destination: .preview)
    case .saveToPhotos:
      if draft.exportedPhotoLibraryAssetIdentifier == nil {
        beginExport(destination: .photoLibrary(.createNew))
      } else {
        isPhotoExportChoicePresented = true
      }
    }
  }

  private var fullCanvasRestoreButton: some View {
    Button {
      toggleControls()
    } label: {
      Label("Edit", systemImage: "slider.horizontal.3")
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 13)
        .frame(minHeight: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1) }
    }
    .buttonStyle(.plain)
    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
  }

  private func settingsPanel(for tool: EditorTool, width: CGFloat, height: CGFloat) -> some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 8) {
          (dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: 8))) {
            Text(tool.title).font(.headline)
            if tool == .photos {
              Text("\(draft.photos.count)/12")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            }
          }
          Spacer(minLength: 0)
          if !dynamicTypeSize.isAccessibilitySize {
            panelAccessory(for: tool)
          }
          Button { toggleControls() } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.title3)
              .foregroundStyle(.secondary)
              .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Close tools")
        }
        if dynamicTypeSize.isAccessibilitySize {
          panelAccessory(for: tool)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
      .fixedSize(horizontal: false, vertical: true)

      Divider()

      settingsForm(for: tool)
    }
    .frame(width: width, height: height)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    .clipShape(RoundedRectangle(cornerRadius: 18))
    .overlay {
      RoundedRectangle(cornerRadius: 18)
        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
  }

  @ViewBuilder
  private func panelAccessory(for tool: EditorTool) -> some View {
    if tool == .photos {
      Group {
        if UIDevice.current.userInterfaceIdiom == .pad {
          Button("Add Photos") { showingExpandedPhotoPicker = true }
        } else {
          PhotosPicker(
            selection: $pickerItems,
            maxSelectionCount: max(0, 12 - draft.photos.count),
            matching: .images
          ) { Text("Add Photos") }
        }
      }
      .font(.subheadline.weight(.semibold))
      .disabled(isImporting || draft.photos.count >= 12)
    } else if tool == .canvas {
      collageBackgroundToggle
    } else if tool == .layout {
      aspectRatioMenu
    }
  }

  @ViewBuilder
  private func settingsForm(for tool: EditorTool) -> some View {
    let form = Form {
      settingsSections(for: tool)
    }
    .scrollContentBackground(.hidden)

    if tool == .photos || tool == .layout || tool == .canvas || tool == .output {
      form.contentMargins(.top, 0, for: .scrollContent)
    } else {
      form
    }
  }

  private var collageBackgroundToggle: some View {
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

  private var aspectRatioMenu: some View {
    Menu {
      ForEach(CanvasPreset.allCases) { preset in
        Button {
          selectCanvas(preset)
        } label: {
          if draft.canvas == preset {
            Label(preset.title, systemImage: "checkmark")
          } else {
            Text(preset.title)
          }
        }
      }
    } label: {
      HStack(spacing: 3) {
        Text(LayoutEngine.isFlowLayout(draft) ? "Ratio · Flow" : "Ratio · \(canvasRatioLabel)")
        if !LayoutEngine.isFlowLayout(draft) {
          Image(systemName: "chevron.down")
            .font(.caption2.weight(.semibold))
        }
      }
      .font(.subheadline.weight(.semibold))
      .lineLimit(1)
    }
    .disabled(LayoutEngine.isFlowLayout(draft))
    .accessibilityLabel("Aspect Ratio")
    .accessibilityValue(
      LayoutEngine.isFlowLayout(draft)
        ? "Determined by the photos" : draft.canvas.title
    )
  }

  private var canvasRatioLabel: String {
    switch draft.canvas {
    case .square: "1:1"
    case .portrait: "4:5"
    case .landscape: "3:2"
    case .story: "9:16"
    }
  }

  private var resolutionControlsLayout: AnyLayout {
    dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(spacing: 6))
  }

  private var exportActionsLayout: AnyLayout {
    dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
      : AnyLayout(HStackLayout(spacing: 12))
  }

  @ViewBuilder
  private func settingsSections(for tool: EditorTool) -> some View {
    switch tool {
    case .photos:
      Section {
        if isImporting {
          HStack {
            ProgressView()
            Text("Preparing fast previews and finding subjects…")
              .foregroundStyle(.secondary)
          }
        }

        ForEach(Array(draft.photos.enumerated()), id: \.element.id) { index, photo in
          PhotoRow(
            photo: photo,
            position: index + 1,
            totalCount: draft.photos.count,
            image: store.thumbnailImage(for: photo),
            viewOriginal: { showOriginalPhoto(id: photo.id) },
            remove: { removePhoto(id: photo.id) }
          )
        }
        .onMove(perform: movePhotos)
      }

    case .layout:
      Section {
        layoutSelector
          .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 8, trailing: 16))

        VStack(alignment: .leading) {
          HStack {
            Text("Spacing")
            Spacer()
            Text("\(Int(draft.spacing))")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          Slider(
            value: Binding(
              get: { draft.spacing },
              set: { spacing in
                if draft.spacing != spacing {
                  draft.spacing = spacing
                  draft.layoutFrameOverrides = nil
                  draft.clearSavedLayoutSnapshot()
                }
              }
            ),
            in: 0...40,
            step: 1
          )
        }
        VStack(alignment: .leading) {
          HStack {
            Text("Canvas Corners")
            Spacer()
            Text("\(Int(draft.canvasCornerRadius))%")
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
          Slider(
            value: Binding(
              get: { draft.canvasCornerRadius },
              set: { draft.canvasCornerRadius = $0 }
            ),
            in: 0...50,
            step: 1
          )
          .accessibilityValue("\(Int(draft.canvasCornerRadius)) percent")
        }

        if draft.layoutRowWeights != nil || draft.layoutColumnWeights != nil
          || draft.layoutFrameOverrides != nil
        {
          Button {
            resetLayoutDividerSizes()
          } label: {
            Label("Reset Divider Sizes", systemImage: "arrow.counterclockwise")
          }
        }
        if !draft.usesAutomaticPhotoArrangement {
          Button {
            refitPhotosForCurrentLayout()
          } label: {
            Label("Arrange Photos by Best Fit", systemImage: "wand.and.stars")
          }
        }
      }

    case .canvas:
      Section {
        let requestedSize = LayoutEngine.outputSize(for: draft)
        let safeExportSize = CollageRenderer.exportOutputSize(for: draft)
        VStack(alignment: .leading, spacing: 8) {
          Text("Resolution")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 3) {
            LazyVGrid(
              columns: Array(
                repeating: GridItem(.flexible(), spacing: 10),
                count: dynamicTypeSize.isAccessibilitySize ? 1 : 2
              ),
              spacing: 10
            ) {
              ForEach(ResolutionPreset.allCases) { preset in
                Button {
                  draft.outputMaxDimension = preset.rawValue
                } label: {
                  HStack(spacing: 6) {
                    Text(preset.title)
                      .lineLimit(1)
                      .minimumScaleFactor(0.75)
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
                .foregroundStyle(.primary)
              }
            }

            resolutionControlsLayout {
              HStack(spacing: 6) {
                Text("Custom · \(draft.outputMaxDimension) px")
                  .lineLimit(1)
                  .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                if ResolutionPreset(rawValue: draft.outputMaxDimension) == nil {
                  Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.indigo)
                }
              }
              .font(.subheadline)
              .padding(.horizontal, 10)
              .frame(maxWidth: .infinity, minHeight: 42)
              .background(
                ResolutionPreset(rawValue: draft.outputMaxDimension) == nil
                  ? Color.indigo.opacity(0.12) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
              )

              Stepper(
                "Custom resolution",
                value: $draft.outputMaxDimension,
                in: 512...8192,
                step: 128
              )
              .labelsHidden()
              .fixedSize()
            }
          }

          if abs(requestedSize.width - safeExportSize.width) >= 1
            || abs(requestedSize.height - safeExportSize.height) >= 1
          {
            Label(
              "The complete Flow strip will export at \(Int(safeExportSize.width)) × \(Int(safeExportSize.height)) px to fit safely.",
              systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }

    case .output:
      Section {
        VStack(alignment: .leading, spacing: 8) {
          exportActionsLayout {
            Button {
              requestExportAction(.preview)
            } label: {
              HStack(spacing: 5) {
                Image(systemName: "eye")
                Text("Preview")
              }
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
              requestExportAction(.saveToPhotos)
            } label: {
              HStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down")
                Text("Export")
                if subscriptions.hasPremiumAccess {
                  Image(systemName: "crown.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Premium active")
                }
              }
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .controlSize(.small)
          }
          .disabled(
            draft.photos.count < 2 || isExporting || !subscriptions.hasLoadedEntitlements
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
            .padding(.top, 2)

          Picker("Format", selection: $draft.outputFormat) {
            ForEach(OutputFormat.allCases) { format in
              Text(format.title).tag(format)
            }
          }
          .modifier(AdaptiveFormatPickerStyle())

          Text(draft.outputFormat.summary)
            .font(.caption)
            .foregroundStyle(.secondary)

          if draft.outputFormat == .png {
            LabeledContent("Quality", value: "Lossless")
            Label(
              "PNG preserves image fidelity; compression affects encoding time rather than visual quality.",
              systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else {
            Picker("Quality", selection: $draft.quality) {
              ForEach(OutputQuality.allCases) { quality in
                Text(quality.title).tag(quality)
              }
            }
            ForEach(OutputQuality.allCases) { quality in
              qualityDescriptionLayout {
                Text(quality.title)
                  .fontWeight(quality == draft.quality ? .semibold : .regular)
                if !dynamicTypeSize.isAccessibilitySize {
                  Spacer(minLength: 12)
                }
                Text(quality.summary)
                  .font(.caption)
                  .foregroundStyle(quality == draft.quality ? .primary : .secondary)
              }
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityElement(children: .combine)
            }
          }
        }
      }

    }
  }

  private var qualityDescriptionLayout: AnyLayout {
    dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
      : AnyLayout(HStackLayout())
  }

  private var layoutSelector: some View {
    let fittedLayouts = Dictionary(
      uniqueKeysWithValues: LayoutFamily.browserCases.map { family in
        (
          family,
          LayoutEngine.fittingLayoutSamples(
            family: family,
            project: draft
          )
        )
      }
    )
    let availableFamilies = LayoutFamily.browserCases.filter {
      !(fittedLayouts[$0] ?? []).isEmpty
    }
    let displayedFamily =
      availableFamilies.contains(selectedLayoutFamily)
      ? selectedLayoutFamily : availableFamilies.first ?? .grid
    let familyLayouts = fittedLayouts[displayedFamily] ?? []
    let selectedTemplate = LayoutEngine.selectedTemplate(for: draft)

    return VStack(alignment: .leading, spacing: 8) {
      ScrollViewReader { categoryProxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 6) {
            ForEach(availableFamilies) { family in
              Button {
                selectedLayoutFamily = family
              } label: {
                Label(family.title, systemImage: family.symbol)
                  .font(.caption.weight(.medium))
                  .padding(.horizontal, 9)
                  .frame(minHeight: 44)
                  .foregroundStyle(displayedFamily == family ? Color.white : Color.primary)
                  .background(
                    displayedFamily == family
                      ? Color.indigo : Color(uiColor: .secondarySystemBackground),
                    in: Capsule()
                  )
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(displayedFamily == family ? .isSelected : [])
              .id(family)
            }
          }
          .padding(.vertical, 2)
        }
        .onAppear {
          categoryProxy.scrollTo(displayedFamily, anchor: .center)
        }
        .onChange(of: displayedFamily) { _, family in
          withAnimation(.easeInOut(duration: 0.2)) {
            categoryProxy.scrollTo(family, anchor: .center)
          }
        }
      }

      ScrollViewReader { layoutProxy in
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 9) {
            ForEach(familyLayouts) { template in
              Button {
                selectLayout(template)
              } label: {
                VStack(spacing: 4) {
                  LayoutThumbnail(
                    template: selectedTemplate.id == template.id ? selectedTemplate : template,
                    project: draft,
                    isSelected: selectedTemplate.id == template.id
                  )
                  Text(template.title)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: dynamicTypeSize.isAccessibilitySize ? 160 : 90)
                }
              }
              .buttonStyle(.plain)
              .accessibilityLabel(template.title)
              .accessibilityAddTraits(selectedTemplate.id == template.id ? .isSelected : [])
              .id(template.id)
            }
          }
          .padding(.vertical, 2)
        }
        .onAppear {
          if familyLayouts.contains(where: { $0.id == selectedTemplate.id }) {
            layoutProxy.scrollTo(selectedTemplate.id, anchor: .center)
          }
        }
        .onChange(of: selectedTemplate.id) { _, templateID in
          if familyLayouts.contains(where: { $0.id == templateID }) {
            withAnimation(.easeInOut(duration: 0.2)) {
              layoutProxy.scrollTo(templateID, anchor: .center)
            }
          }
        }
      }

      if displayedFamily == .custom {
        Divider()
        if !matchingSavedCustomLayouts.isEmpty {
          Text("My Layouts")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              ForEach(matchingSavedCustomLayouts) { layout in
                Button {
                  selectSavedCustomLayout(layout)
                } label: {
                  Label(
                    layout.name,
                    systemImage: draft.savedCustomLayoutID == layout.id
                      ? "checkmark.circle.fill" : "rectangle.split.2x2"
                  )
                  .font(.caption)
                }
                .buttonStyle(.bordered)
              }
            }
          }
        }
        Button("Save Current as My Layout", systemImage: "plus.rectangle.on.rectangle") {
          saveCurrentCustomLayout()
        }
        .font(.caption.weight(.semibold))
      }
    }
  }

  private var matchingSavedCustomLayouts: [SavedCustomLayout] {
    store.savedCustomLayouts.filter { $0.photoCount == draft.photos.count }
  }

  private func selectLayout(_ template: CollageLayoutTemplate) {
    guard draft.layoutID != template.id else { return }
    let startingCustomFrames: [NormalizedLayoutFrame]? = {
      guard case .custom = template.recipe else { return nil }
      return normalizedCurrentLayoutFrames()
    }()
    withAnimation(.easeInOut(duration: 0.2)) {
      draft.layoutID = template.id
      draft.clearCustomLayout()
      draft.customLayoutFrames = startingCustomFrames
      draft.clearSavedLayoutSnapshot()
      switch template.recipe {
      case .hero:
        draft.mainPhotoCount = 1
      case .multiHero(_, let mainCount, _):
        draft.mainPhotoCount = mainCount
      case .bands(_, let counts, let weights) where template.family == .editorial:
        let mainIndex = weights.indices.max(by: { weights[$0] < weights[$1] }) ?? 0
        if counts.indices.contains(mainIndex) {
          draft.mainPhotoCount = min(3, max(1, counts[mainIndex]))
        }
      case .partition(_, let mainCount):
        draft.mainPhotoCount = mainCount
      default:
        break
      }
      if let legacyLayout = template.legacyLayout {
        draft.layout = legacyLayout
      }
      resetLayoutDividerSizes()
      refitPhotosForCurrentLayout()
    }
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
    withAnimation(.easeInOut(duration: 0.2)) {
      draft.layoutID = LayoutCatalog.customTemplate(photoCount: draft.photos.count).id
      draft.customLayoutFrames = layout.frames
      draft.savedCustomLayoutID = layout.id
      draft.clearSavedLayoutSnapshot()
      draft.clearLayoutCustomization(invalidateExport: true)
      selectedLayoutFamily = .custom
      refitPhotosForCurrentLayout()
    }
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
      selectedLayoutFamily = .custom
    }
  }

  private func selectCanvas(_ canvas: CanvasPreset) {
    guard draft.canvas != canvas else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      draft.canvas = canvas
      draft.clearSavedLayoutSnapshot()
      refitPhotosForCurrentLayout()
    }
  }

  private func refitPhotosForCurrentLayout() {
    draft.resetPhotosForAutomaticFit()
  }

  private func adjustLayoutDivider(_ divider: LayoutDivider, delta: Double) {
    guard abs(delta) > 0.000_01 else { return }
    if var snapshot = LayoutEngine.activeSavedLayoutSnapshot(for: draft),
      let adjustedFrames = LayoutEngine.adjustedSavedLayoutFrames(
        for: draft,
        moving: divider,
        normalizedDelta: delta
      )
    {
      snapshot.frames = adjustedFrames
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

    let outputSize = LayoutEngine.outputSize(for: draft)
    guard var adjustment = LayoutEngine.layoutAdjustmentGrid(for: draft, in: outputSize) else {
      return
    }

    switch divider.axis {
    case .horizontal:
      let firstIndex = divider.rowIndex
      let secondIndex = firstIndex + 1
      guard adjustment.rowWeights.indices.contains(firstIndex),
        adjustment.rowWeights.indices.contains(secondIndex)
      else { return }
      resizeAdjacentWeights(
        &adjustment.rowWeights,
        firstIndex: firstIndex,
        secondIndex: secondIndex,
        normalizedDelta: delta
      )

    case .vertical:
      guard adjustment.columnWeights.indices.contains(divider.rowIndex) else { return }
      let firstIndex = divider.dividerIndex
      let secondIndex = firstIndex + 1
      guard adjustment.columnWeights[divider.rowIndex].indices.contains(firstIndex),
        adjustment.columnWeights[divider.rowIndex].indices.contains(secondIndex)
      else { return }
      resizeAdjacentWeights(
        &adjustment.columnWeights[divider.rowIndex],
        firstIndex: firstIndex,
        secondIndex: secondIndex,
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
    let totalWeight = max(weights.reduce(0, +), 0.01)
    let combinedWeight = weights[firstIndex] + weights[secondIndex]
    let minimumWeight = max(combinedWeight * 0.12, totalWeight * 0.04)
    let proposedFirst = weights[firstIndex] + normalizedDelta * totalWeight
    let firstWeight = min(
      combinedWeight - minimumWeight,
      max(minimumWeight, proposedFirst)
    )
    weights[firstIndex] = firstWeight
    weights[secondIndex] = combinedWeight - firstWeight
  }

  private func resetLayoutDividerSizes() {
    draft.clearSavedLayoutSnapshot()
    draft.clearLayoutCustomization(invalidateExport: true)
  }

  private func toggleControls() {
    hideKeyboard()
    withAnimation(.easeInOut(duration: 0.2)) {
      isControlsHidden.toggle()
    }
  }

  private var hasUnsavedChanges: Bool {
    draft.hasUserChanges(comparedTo: savedSnapshot)
  }

  private var isExportSaveDialogPresented: Binding<Bool> {
    Binding(
      get: { pendingExportAction != nil },
      set: { isPresented in
        if !isPresented {
          pendingExportAction = nil
        }
      }
    )
  }

  @discardableResult
  private func saveDraft() async -> Bool {
    let pendingCheckpoint = draftCheckpointTask
    pendingCheckpoint?.cancel()
    await pendingCheckpoint?.value
    draftCheckpointTask = nil
    let savedChanges = draft.hasUserChanges(comparedTo: savedSnapshot)
    guard let savedDraft = await store.saveProject(draft) else { return false }
    completedMeaningfulWork = completedMeaningfulWork || savedChanges
    draft = savedDraft
    savedSnapshot = savedDraft
    await store.discardDraft(projectID: savedDraft.id)
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
    hideKeyboard()
    isSaving = true
    Task { @MainActor in
      // Give SwiftUI a frame to present the progress overlay before thumbnail rendering begins.
      try? await Task.sleep(for: .milliseconds(80))
      await store.prepareDerivedImages(for: draft.photos)
      guard await saveDraft() else {
        isSaving = false
        return
      }
      if dismissAfterSave {
        finishEditing()
      } else {
        isSaving = false
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

  private func completePhotoExportChoice() {
    guard let mode = pendingPhotoLibraryExportMode else { return }
    pendingPhotoLibraryExportMode = nil
    beginExport(destination: .photoLibrary(mode))
  }

  private func prepareEditorImagesAndFocusAreas() async {
    await store.prepareDerivedImages(for: draft.photos)
    let requests: [(UUID, CGImage)] = draft.photos.compactMap { photo in
      guard photo.focusSource == .automatic,
        photo.hasCompletedFocusDetection != true,
        let image = store.previewImage(for: photo)?.cgImage
      else { return nil }
      return (photo.id, image)
    }
    guard !requests.isEmpty else { return }

    let results = await Task.detached(priority: .utility) {
      requests.map { photoID, image in
        (photoID, SubjectDetector.detect(in: image))
      }
    }.value
    guard !Task.isCancelled else { return }

    for (photoID, detection) in results {
      guard let index = draft.photos.firstIndex(where: { $0.id == photoID }) else { continue }
      draft.photos[index].detectedFocusArea = detection.focusArea
      draft.photos[index].hasCompletedFocusDetection = true
    }
  }

  private func importPhotos(_ items: [PhotosPickerItem]) {
    isImporting = true
    pickerItems = []
    Task {
      var failures = 0
      var didImportPhotos = false
      for batchStart in stride(from: 0, to: items.count, by: 2) {
        let indexes = Array(batchStart..<min(batchStart + 2, items.count))
        let outcomes = await withTaskGroup(of: (Int, CollagePhoto?).self) { group in
          for index in indexes {
            let item = items[index]
            let assetIdentifier = item.itemIdentifier
            group.addTask {
              do {
                guard
                  let transferredFile = try await item.loadTransferable(
                    type: ImportedPhotoFile.self
                  )
                else {
                  return (index, nil)
                }
                defer { try? FileManager.default.removeItem(at: transferredFile.url) }
                return (
                  index,
                  try await store.importPhotoFile(
                    at: transferredFile.url,
                    photoLibraryAssetIdentifier: assetIdentifier
                  )
                )
              } catch {
                return (index, nil)
              }
            }
          }
          var results: [(Int, CollagePhoto?)] = []
          for await result in group { results.append(result) }
          return results.sorted { $0.0 < $1.0 }
        }
        let importedPhotos = outcomes.compactMap(\.1)
        failures += outcomes.count - importedPhotos.count
        if !importedPhotos.isEmpty {
          didImportPhotos = true
          draft.clearLayoutCustomization(invalidateExport: true)
          draft.clearCustomLayout()
          draft.clearSavedLayoutSnapshot()
          draft.photos.append(contentsOf: importedPhotos)
        }
      }
      if didImportPhotos {
        applyAutomaticRecommendations()
      }
      isImporting = false
      if failures > 0 {
        message = EditorMessage(
          title: "Some Photos Weren't Added",
          detail: "\(failures) selected item(s) could not be read.")
      }
    }
  }

  private func importPhotos(_ selections: [ExpandedPhotoSelection]) {
    isImporting = true
    Task {
      var failures = 0
      var didImportPhotos = false
      for batchStart in stride(from: 0, to: selections.count, by: 2) {
        let indexes = Array(batchStart..<min(batchStart + 2, selections.count))
        let outcomes = await withTaskGroup(of: (Int, CollagePhoto?).self) { group in
          for index in indexes {
            let selection = selections[index]
            group.addTask {
              do {
                guard
                  let transferredFile = try await loadImportedPhotoFile(
                    from: selection.itemProvider
                  )
                else {
                  return (index, nil)
                }
                defer { try? FileManager.default.removeItem(at: transferredFile.url) }
                return (
                  index,
                  try await store.importPhotoFile(
                    at: transferredFile.url,
                    photoLibraryAssetIdentifier: selection.assetIdentifier
                  )
                )
              } catch {
                return (index, nil)
              }
            }
          }
          var results: [(Int, CollagePhoto?)] = []
          for await result in group { results.append(result) }
          return results.sorted { $0.0 < $1.0 }
        }
        let importedPhotos = outcomes.compactMap(\.1)
        failures += outcomes.count - importedPhotos.count
        if !importedPhotos.isEmpty {
          didImportPhotos = true
          draft.clearLayoutCustomization(invalidateExport: true)
          draft.clearCustomLayout()
          draft.clearSavedLayoutSnapshot()
          draft.photos.append(contentsOf: importedPhotos)
        }
      }
      if didImportPhotos {
        applyAutomaticRecommendations()
      }
      isImporting = false
      if failures > 0 {
        message = EditorMessage(
          title: "Some Photos Weren't Added",
          detail: "\(failures) selected item(s) could not be read.")
      }
    }
  }

  private func applyAutomaticRecommendations() {
    draft.isPhotoOrderManuallyAdjusted = false
    draft.clearLayoutCustomization()
    draft.clearCustomLayout()
    draft.clearSavedLayoutSnapshot()
    let recommendation = LayoutEngine.recommendedCanvasAndTemplate(for: draft)
    draft.canvas = recommendation.canvas
    if let legacyLayout = recommendation.template.legacyLayout {
      draft.layout = legacyLayout
    }
    draft.layoutID = recommendation.template.id
    draft.mainPhotoCount = LayoutEngine.mainPhotoCount(for: recommendation.template)
    selectedLayoutFamily = .smart
  }

  private func removePhoto(id: UUID) {
    let removedPhoto = draft.photos.first { $0.id == id }
    draft.photos.removeAll { $0.id == id }
    draft.clearLayoutCustomization(invalidateExport: true)
    draft.clearCustomLayout()
    draft.clearSavedLayoutSnapshot()
    if let removedPhoto {
      Task { await store.discardPhotoIfUnreferenced(removedPhoto) }
    }
    normalizeLayoutSelection()
  }

  private func normalizeLayoutSelection() {
    let count = max(draft.photos.count, 1)
    guard LayoutCatalog.template(id: draft.layoutID, photoCount: count) == nil else { return }
    let fallback =
      LayoutCatalog.compatibleTemplate(id: draft.layoutID, photoCount: count)
      ?? LayoutCatalog.selectedTemplate(for: draft)
    draft.layoutID = fallback.id
    draft.clearLayoutCustomization(invalidateExport: true)
    selectedLayoutFamily = fallback.family.browserFamily
  }

  private func movePhotos(from offsets: IndexSet, to destination: Int) {
    draft.isPhotoOrderManuallyAdjusted = true
    draft.photos.move(fromOffsets: offsets, toOffset: destination)
  }

  private func swapPhotos(sourceID: UUID, targetID: UUID) {
    lockCurrentAutomaticArrangement()
    withAnimation(.easeInOut(duration: 0.2)) {
      _ = draft.swapPhotosForAutomaticFit(sourceID: sourceID, targetID: targetID)
    }
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

  private func adjustCrop(photoID: UUID, focalPoint: CGPoint) {
    guard let index = draft.photos.firstIndex(where: { $0.id == photoID }) else { return }
    draft.photos[index].focalX = Double(focalPoint.x)
    draft.photos[index].focalY = Double(focalPoint.y)
    draft.photos[index].focusSource = .manual
  }

  private func adjustZoom(photoID: UUID, zoom: Double) {
    guard let index = draft.photos.firstIndex(where: { $0.id == photoID }) else { return }
    draft.photos[index].zoom = min(4, max(1, zoom))
    draft.photos[index].focusSource = .manual
  }

  private func showOriginalPhoto(id: UUID) {
    guard let photo = draft.photos.first(where: { $0.id == id }) else { return }
    originalPhotoPreview = photo
  }

  private func cropConfiguration(for photoID: UUID) -> CollagePhotoCropConfiguration {
    guard let index = draft.photos.firstIndex(where: { $0.id == photoID }) else {
      return CollagePhotoCropConfiguration(
        destinationAspectRatio: 1,
        cornerRadiusFraction: 0,
        usesAspectFit: false
      )
    }
    let outputSize = LayoutEngine.outputSize(for: draft)
    let frames = LayoutEngine.layoutFrames(for: draft, in: outputSize)
    guard index < frames.count else {
      return CollagePhotoCropConfiguration(
        destinationAspectRatio: draft.photos[index].aspectRatio,
        cornerRadiusFraction: 0,
        usesAspectFit: false
      )
    }
    let frame = frames[index]
    return CollagePhotoCropConfiguration(
      destinationAspectRatio: frame.rect.width / max(frame.rect.height, 1),
      cornerRadiusFraction: frame.cornerRadiusFraction,
      normalizedClipPolygon: frame.normalizedClipPolygon,
      usesAspectFit: frame.usesAspectFit
    )
  }

  private func beginExport(destination: ExportDestination) {
    guard draft.photos.count >= 2 else { return }
    isExporting = true
    let project = draft
    let photoDirectory = store.photoDirectory
    let collectionName = store.collection(id: project.collectionID)?.name ?? "Collection"
    let includesWatermark = !subscriptions.hasPremiumAccess

    Task {
      do {
        try await store.restoreOriginalsIfNeeded(for: project.photos)
        let export = try await Task.detached(priority: .userInitiated) {
          try CollageRenderer.prepareExport(
            project: project,
            photoDirectory: photoDirectory,
            collectionName: collectionName,
            includesWatermark: includesWatermark
          )
        }.value
        switch destination {
        case .preview:
          exportPreview = export
        case .photoLibrary(let mode):
          try await savePreparedExportToPhotos(
            export,
            mode: mode,
            successDetail: "Your full-resolution project is now in the Photo Library."
          )
        }
      } catch {
        message = EditorMessage(
          title: "Export Failed", detail: error.localizedDescription)
      }
      isExporting = false
    }
  }

  private func savePreparedExportToPhotos(
    _ export: PreparedCollageExport,
    mode: PhotoLibraryExportMode,
    successDetail: String = "Your reviewed full-resolution project is now in the Photo Library."
  ) async throws {
    switch mode {
    case .createNew:
      draft.exportedPhotoLibraryAssetIdentifier =
        try await CollageRenderer.saveToPhotoLibrary(fileURL: export.fileURL)
    case .replaceExisting:
      guard let identifier = draft.exportedPhotoLibraryAssetIdentifier else {
        throw AppError.persistenceFailed
      }
      try await CollageRenderer.replacePhotoLibraryAsset(
        identifier: identifier,
        with: export.fileURL,
        format: draft.outputFormat
      )
    }
    _ = try await persistPreparedExport(export)
    completedMeaningfulWork = true
    try? FileManager.default.removeItem(at: export.fileURL)
    exportPreview = nil
    message = EditorMessage(
      title: "Saved to Photos",
      detail: successDetail
    )
    if exitsAfterSuccessfulExport {
      exitsAfterSuccessfulExport = false
      finishEditing()
    }
  }

  private func sharePreparedExport(_ export: PreparedCollageExport) async throws {
    let persistedURL = try await persistPreparedExport(export)
    completedMeaningfulWork = true
    try? FileManager.default.removeItem(at: export.fileURL)
    exportPreview = nil
    try? await Task.sleep(nanoseconds: 250_000_000)
    shareItem = ShareItem(url: persistedURL)
  }

  private func persistPreparedExport(_ export: PreparedCollageExport) async throws -> URL {
    let persistedURL = try await store.persistExport(from: export.fileURL, for: draft)
    draft.latestExportFileName = persistedURL.lastPathComponent
    guard await saveDraft() else { throw AppError.persistenceFailed }
    return persistedURL
  }

  private func cancelPreparedExport(_ export: PreparedCollageExport) {
    try? FileManager.default.removeItem(at: export.fileURL)
    exportPreview = nil
  }

  private func hideKeyboard() {
    UIApplication.shared.sendAction(
      #selector(UIResponder.resignFirstResponder),
      to: nil,
      from: nil,
      for: nil
    )
  }

  private func finishEditing() {
    if completedMeaningfulWork, draft.photos.count >= 2 {
      store.reviewPromptPolicy.recordCompletedUsage()
      completedMeaningfulWork = false
    }
    dismiss()
  }
}

private struct ImportedPhotoFile: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { receivedFile in
      let temporaryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(receivedFile.file.pathExtension)
      try FileManager.default.copyItem(at: receivedFile.file, to: temporaryURL)
      return ImportedPhotoFile(url: temporaryURL)
    }
  }
}

private struct ExpandedPhotoSelection: @unchecked Sendable {
  let itemProvider: NSItemProvider
  let assetIdentifier: String?

  init(_ result: PHPickerResult) {
    itemProvider = result.itemProvider
    assetIdentifier = result.assetIdentifier
  }
}

private struct ExpandedPhotoPicker: UIViewControllerRepresentable {
  let selectionLimit: Int
  let onFinish: ([ExpandedPhotoSelection]) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onFinish: onFinish)
  }

  func makeUIViewController(context: Context) -> PHPickerViewController {
    var configuration = PHPickerConfiguration(photoLibrary: .shared())
    configuration.filter = .images
    configuration.selectionLimit = max(1, selectionLimit)
    configuration.selection = .ordered
    configuration.preferredAssetRepresentationMode = .current
    configuration.mode = .default

    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

  final class Coordinator: NSObject, PHPickerViewControllerDelegate {
    let onFinish: ([ExpandedPhotoSelection]) -> Void

    init(onFinish: @escaping ([ExpandedPhotoSelection]) -> Void) {
      self.onFinish = onFinish
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
      onFinish(results.map(ExpandedPhotoSelection.init))
    }
  }
}

private func loadImportedPhotoFile(from provider: NSItemProvider) async throws
  -> ImportedPhotoFile?
{
  try await withCheckedThrowingContinuation { continuation in
    _ = provider.loadTransferable(type: ImportedPhotoFile.self) { result in
      continuation.resume(with: result)
    }
  }
}

private struct ExportPreferenceSnapshot: Equatable {
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

private struct LayoutThumbnail: View {
  let template: CollageLayoutTemplate
  let project: Project
  let isSelected: Bool

  private let displaySize = CGSize(width: 76, height: 52)

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
    let canvasOrigin = CGPoint(
      x: (displaySize.width - canvasSize.width) / 2,
      y: (displaySize.height - canvasSize.height) / 2
    )

    ZStack(alignment: .topLeading) {
      Color(uiColor: .tertiarySystemBackground)
      Color(uiColor: UIColor(hex: project.backgroundHex))
        .frame(width: canvasSize.width, height: canvasSize.height)
        .offset(x: canvasOrigin.x, y: canvasOrigin.y)
      ForEach(Array(frames.enumerated()), id: \.offset) { index, layoutFrame in
        let frame = CGRect(
          x: canvasOrigin.x + layoutFrame.rect.minX * scale,
          y: canvasOrigin.y + layoutFrame.rect.minY * scale,
          width: layoutFrame.rect.width * scale,
          height: layoutFrame.rect.height * scale
        )
        thumbnailFrame(index: index, layoutFrame: layoutFrame)
          .frame(width: frame.width, height: frame.height)
          .rotationEffect(.degrees(layoutFrame.rotationDegrees))
          .offset(x: frame.minX, y: frame.minY)
          .zIndex(Double(layoutFrame.zIndex))
      }
    }
    .frame(width: displaySize.width, height: displaySize.height)
    .clipped()
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          isSelected ? Color.indigo : Color.secondary.opacity(0.25), lineWidth: isSelected ? 3 : 1)
    }
  }

  @ViewBuilder
  private func thumbnailFrame(index: Int, layoutFrame: LayoutFrame) -> some View {
    let color = Color.indigo.opacity(index.isMultiple(of: 2) ? 0.78 : 0.48)
    LayoutFrameShape(
      cornerRadiusFraction: layoutFrame.cornerRadiusFraction,
      normalizedClipPolygon: layoutFrame.normalizedClipPolygon
    )
    .fill(color)
    .overlay {
      LayoutFrameShape(
        cornerRadiusFraction: layoutFrame.cornerRadiusFraction,
        normalizedClipPolygon: layoutFrame.normalizedClipPolygon
      )
      .stroke(.white.opacity(0.7), lineWidth: 0.7)
    }
  }
}

private struct PhotoRow: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let photo: CollagePhoto
  let position: Int
  let totalCount: Int
  let image: UIImage?
  let viewOriginal: () -> Void
  let remove: () -> Void

  var body: some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            thumbnail
            Spacer()
            actions
          }
          metadata
        }
      } else {
        HStack(spacing: 12) {
          thumbnail
          metadata
          actions
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Photo \(position) of \(totalCount)")
    .accessibilityValue(
      "\(photo.pixelWidth) by \(photo.pixelHeight) pixels, "
        + (photo.focusSource == .automatic ? "subject focus detected" : "focus adjusted")
    )
    .accessibilityHint("Double tap to view the original photo")
    .accessibilityAction(.default, viewOriginal)
    .accessibilityAction(named: "Remove Photo", remove)
  }

  private var thumbnail: some View {
    Button(action: viewOriginal) {
      Group {
        if let image {
          Image(uiImage: image).resizable().scaledToFill()
        } else {
          Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
        }
      }
      .frame(width: 54, height: 54)
      .background(.quaternary)
      .overlay {
        if let image, let focusArea = photo.detectedFocusArea {
          DetectedFocusAreaOverlay(area: focusArea, imageSize: image.size)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("View original photo")
  }

  private var metadata: some View {
    Button(action: viewOriginal) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Photo \(photo.pixelWidth) × \(photo.pixelHeight)")
          .font(.subheadline.weight(.medium))
        Label(
          photo.focusSource == .automatic ? "Subject focus detected" : "Focus adjusted",
          systemImage: photo.focusSource == .automatic ? "viewfinder" : "hand.draw"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var actions: some View {
    HStack(spacing: 0) {
      Button(action: viewOriginal) {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("View original photo")
      Button(role: .destructive, action: remove) {
        Image(systemName: "minus.circle.fill")
          .frame(width: 44, height: 44)
      }
      .accessibilityLabel("Remove Photo")
    }
    .font(.system(size: 20))
    .buttonStyle(.plain)
  }
}

private struct DetectedFocusAreaOverlay: View {
  let area: PhotoFocusArea
  let imageSize: CGSize

  var body: some View {
    GeometryReader { proxy in
      let scale = max(
        proxy.size.width / max(imageSize.width, 1),
        proxy.size.height / max(imageSize.height, 1)
      )
      let displayedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
      let imageOrigin = CGPoint(
        x: (proxy.size.width - displayedSize.width) / 2,
        y: (proxy.size.height - displayedSize.height) / 2
      )
      let focusRect = area.rect

      Rectangle()
        .fill(.red.opacity(0.2))
        .overlay { Rectangle().stroke(.red, lineWidth: 1.5) }
        .frame(
          width: max(2, focusRect.width * displayedSize.width),
          height: max(2, focusRect.height * displayedSize.height)
        )
        .offset(
          x: imageOrigin.x + focusRect.minX * displayedSize.width,
          y: imageOrigin.y + focusRect.minY * displayedSize.height
        )
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct EditorMessage: Identifiable {
  let id = UUID()
  let title: String
  let detail: String
}

private enum PendingExportAction {
  case preview
  case saveToPhotos
}

private enum PendingExitAction {
  case saveAndExport
  case saveAndLeave
  case discard
  case subscribe
}

private enum ExportDestination {
  case preview
  case photoLibrary(PhotoLibraryExportMode)
}

private enum EditorTool: String, CaseIterable, Identifiable {
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

private struct ShareItem: Identifiable {
  let id = UUID()
  let url: URL
}

/// Allocates disjoint canvas and tool regions from the current window, including fold transitions.
struct EditorWorkspaceLayout {
  let usesSideBySide: Bool
  let previewWidth: CGFloat
  let previewHeight: CGFloat
  let panelWidth: CGFloat
  let settingsHeight: CGFloat

  init(size: CGSize, controlsHidden: Bool, squareCanvas: Bool, accessibilityText: Bool) {
    let width = max(1, size.width)
    let height = max(1, size.height)
    usesSideBySide = !controlsHidden && width > height && width >= 600 && height >= 260
    if controlsHidden {
      previewWidth = width
      previewHeight = max(1, height - 12)
      panelWidth = 0
      settingsHeight = 0
    } else if usesSideBySide {
      panelWidth = min(520, width * (accessibilityText ? 0.5 : 0.42))
      previewWidth = max(1, width - panelWidth - 80)
      previewHeight = max(1, height - 14)
      settingsHeight = max(1, height - 16)
    } else {
      previewWidth = width
      panelWidth = max(1, width - 16)
      let minimumControls = min(height * 0.65, accessibilityText ? 340.0 : 240.0)
      let desiredPreview = accessibilityText ? height * 0.28
        : squareCanvas ? width - 32 : height * 0.42
      previewHeight = max(1, min(desiredPreview, height - minimumControls - 24))
      // Preview includes eight points of bottom padding; tools have a 56-point rail,
      // eight-point gap and eight-point bottom margin, with another eight points between regions.
      settingsHeight = max(1, height - previewHeight - 88)
    }
  }
}

private struct AdaptiveFormatPickerStyle: ViewModifier {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  @ViewBuilder
  func body(content: Content) -> some View {
    if dynamicTypeSize.isAccessibilitySize {
      content.pickerStyle(.menu)
    } else {
      content.pickerStyle(.segmented)
    }
  }
}
