import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CollageEditorView: View {
  @EnvironmentObject private var store: AppStore
  @EnvironmentObject private var subscriptions: SubscriptionStore
  @Environment(\.dismiss) private var dismiss
  @State private var draft: CollageTask
  @State private var savedSnapshot: CollageTask
  @State private var pickerItems: [PhotosPickerItem] = []
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
  @State private var shouldPresentSubscriptionAfterSaveChoice = false
  @State private var isPhotoExportChoicePresented = false
  @State private var pendingPhotoLibraryExportMode: PhotoLibraryExportMode?

  init(projectID: UUID, task: CollageTask?) {
    let initialTask = Self.initialDraft(projectID: projectID, task: task)
    _draft = State(initialValue: initialTask)
    _savedSnapshot = State(initialValue: initialTask)
    _isControlsHidden = State(initialValue: task != nil)
    _activeEditorTool = State(initialValue: .photos)
    _selectedLayoutFamily = State(
      initialValue: LayoutEngine.selectedTemplate(for: initialTask).family.browserFamily)
  }

  static func initialDraft(
    projectID: UUID,
    task: CollageTask?,
    defaults: UserDefaults = .standard
  ) -> CollageTask {
    if let task { return task }
    var draft = CollageTask.new(projectID: projectID)
    MixaFrameExportPreferences.apply(to: &draft, defaults: defaults)
    return draft
  }

  private var exportPreferenceSnapshot: ExportPreferenceSnapshot {
    ExportPreferenceSnapshot(task: draft)
  }

  var body: some View {
    editorContent
      .sheet(isPresented: $isSaveChoicePresented, onDismiss: completeSaveChoiceDismissal) {
        saveCollageSheet
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
          .presentationDetents([.medium])
          .presentationDragIndicator(.visible)
        }
      }
  }

  private var saveCollageSheet: some View {
    NavigationStack {
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

        if !subscriptions.hasPremiumAccess {
          Button {
            shouldPresentSubscriptionAfterSaveChoice = true
            isSaveChoicePresented = false
          } label: {
            Label("Subscribe to remove the watermark", systemImage: "crown")
              .font(.subheadline)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          .buttonStyle(.plain)
          .foregroundStyle(.indigo)
          .disabled(!subscriptions.hasLoadedEntitlements)
        }

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
      .frame(maxHeight: .infinity, alignment: .top)
      .navigationTitle("Save Collage")
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.height(subscriptions.hasPremiumAccess ? 250 : 280)])
    .presentationDragIndicator(.visible)
  }

  private func completeSaveChoiceDismissal() {
    guard shouldPresentSubscriptionAfterSaveChoice else { return }
    shouldPresentSubscriptionAfterSaveChoice = false
    showingSubscription = true
  }

  private var editorContent: some View {
    NavigationStack {
      GeometryReader { proxy in
        let isLandscapeEditing =
          !isControlsHidden && proxy.size.width > proxy.size.height
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
      .navigationTitle(draft.name)
      .navigationBarTitleDisplayMode(.inline)
      .interactiveDismissDisabled(true)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            hideKeyboard()
            if hasUnsavedChanges {
              isExitConfirmationPresented = true
            } else {
              dismiss()
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
              Text(draft.name)
                .font(.headline)
                .lineLimit(1)
              Image(systemName: "pencil")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Edit collage title")
          .disabled(isImporting || isSaving || isExporting)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button("Save") {
            presentSaveChoices()
          }
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
              Text("Saving collage…").font(.headline)
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
              Text("Rendering full-resolution collage…").font(.headline)
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
      .alert("Edit Collage Title", isPresented: $isRenamePresented) {
        TextField("Collage title", text: $pendingTitle)
        Button("Cancel", role: .cancel) {}
        Button("Done") {
          let title = pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
          if !title.isEmpty {
            draft.name = title
          }
        }
        .disabled(pendingTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      } message: {
        Text("Enter the title shown for this collage task.")
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
          "This collage has changed since it was last saved. Save now so the exported image and saved task stay in sync."
        )
      }
      .confirmationDialog(
        "Save Changes?",
        isPresented: $isExitConfirmationPresented,
        titleVisibility: .visible
      ) {
        if draft.photos.count >= 2 {
          Button("Save") {
            presentSaveChoices()
          }
        }
        Button("Discard Changes", role: .destructive) {
          let discardedDraft = draft
          Task {
            await store.discardUnsavedPhotoFiles(from: discardedDraft)
            dismiss()
          }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        if draft.photos.count >= 2 {
          Text(
            "This collage has unsaved changes. Save it and choose whether to export, or discard the changes."
          )
        } else {
          Text("Add at least two photos to save this collage task, or discard it and go back.")
        }
      }
    }
  }

  private func previewWorkspace(maximumHeight: CGFloat) -> some View {
    CollagePreview(
      task: draft,
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
    let isLandscape = availableSize.width > availableSize.height
    let panelWidth = min(680, max(1, availableSize.width - 16))
    let defaultControlsHeight = availableSize.height * 0.5 - 8
    let availableControlsHeight =
      availableSize.height
      - previewMaximumHeight(for: availableSize)
      - editorPortraitReservedVerticalSpace
    let controlsHeight = max(
      editorMinimumControlsHeight,
      min(
        520,
        usesSquareCanvas ? availableControlsHeight : defaultControlsHeight
      )
    )
    let toolBarHeight: CGFloat = 54
    let settingsHeight = max(118, controlsHeight - toolBarHeight - 8)

    if isLandscape {
      let landscapePanelWidth = landscapeSettingsPanelWidth(for: availableSize)
      let landscapeControlsHeight = min(520, max(180, availableSize.height - 16))

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

  private func previewMaximumHeight(for availableSize: CGSize) -> CGFloat {
    if isControlsHidden {
      return max(140, availableSize.height - 12)
    }
    if availableSize.width > availableSize.height {
      return max(140, availableSize.height - 14)
    }
    if usesSquareCanvas {
      let fullWidthSquare = max(140, availableSize.width - 32)
      let heightBeforeControls = max(
        140,
        availableSize.height
          - editorMinimumControlsHeight
          - editorPortraitReservedVerticalSpace
      )
      return min(fullWidthSquare, heightBeforeControls)
    }
    return max(140, availableSize.height * 0.42)
  }

  private func landscapePreviewWorkspaceWidth(for availableSize: CGSize) -> CGFloat {
    let controlsWidth =
      landscapeSettingsPanelWidth(for: availableSize)
      + editorLandscapeToolbarWidth
      + 16
    return max(140, availableSize.width - controlsWidth - 8)
  }

  private func landscapeSettingsPanelWidth(for availableSize: CGSize) -> CGFloat {
    min(420, max(260, availableSize.width * 0.42))
  }

  private var usesSquareCanvas: Bool {
    let outputSize = LayoutEngine.outputSize(for: draft)
    return abs(outputSize.width - outputSize.height) < 0.5
  }

  private var editorMinimumControlsHeight: CGFloat { 180 }
  private var editorPortraitReservedVerticalSpace: CGFloat { 24 }
  private var editorLandscapeToolbarWidth: CGFloat { 54 }

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
        .frame(height: 42)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 1) }
    }
    .buttonStyle(.plain)
    .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
  }

  private func settingsPanel(for tool: EditorTool, width: CGFloat, height: CGFloat) -> some View {
    VStack(spacing: 0) {
      HStack {
        if tool == .photos {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(tool.title, systemImage: tool.symbol)
              .font(.headline)

            Text("\(draft.photos.count)/12")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .monospacedDigit()

            PhotosPicker(
              selection: $pickerItems,
              maxSelectionCount: max(0, 12 - draft.photos.count),
              matching: .images
            ) {
              Text("Add Photos")
                .font(.subheadline.weight(.semibold))
            }
            .offset(y: 1)
            .disabled(isImporting || draft.photos.count >= 12)
          }
        } else {
          Label(tool.title, systemImage: tool.symbol)
            .font(.headline)

          if tool == .canvas {
            collageBackgroundToggle
          } else if tool == .layout {
            aspectRatioMenu
          }
        }

        Spacer()
        Button {
          toggleControls()
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
        "Collage Background",
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
    .accessibilityLabel("Collage Background")
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
        Text("Ratio · \(canvasRatioLabel)")
        Image(systemName: "chevron.down")
          .font(.caption2.weight(.semibold))
      }
      .font(.subheadline.weight(.semibold))
      .lineLimit(1)
    }
    .disabled(LayoutEngine.isNaturalVerticalStrip(draft))
    .accessibilityLabel("Aspect Ratio")
    .accessibilityValue(draft.canvas.title)
  }

  private var canvasRatioLabel: String {
    switch draft.canvas {
    case .square: "1:1"
    case .portrait: "4:5"
    case .landscape: "3:2"
    case .story: "9:16"
    }
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

        ForEach(draft.photos) { photo in
          PhotoRow(
            photo: photo,
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
        VStack(alignment: .leading, spacing: 8) {
          Text("Resolution")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)

          VStack(alignment: .leading, spacing: 3) {
            LazyVGrid(
              columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10),
              ],
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

            HStack(spacing: 6) {
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
        }
      }

    case .output:
      Section {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
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
          .pickerStyle(.segmented)

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

    }
  }

  private var layoutSelector: some View {
    let fittedLayouts = Dictionary(
      uniqueKeysWithValues: LayoutFamily.browserCases.map { family in
        (
          family,
          LayoutEngine.fittingLayoutSamples(
            family: family,
            task: draft
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
                  .frame(height: 30)
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
                    task: draft,
                    isSelected: selectedTemplate.id == template.id
                  )
                  Text(template.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 82)
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
    }
  }

  private func selectLayout(_ template: CollageLayoutTemplate) {
    guard draft.layoutID != template.id else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      draft.layoutID = template.id
      draft.clearCustomLayout()
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
      } else if case .naturalVerticalStrip = template.recipe {
        draft.layout = .verticalStrip
      }
      resetLayoutDividerSizes()
      refitPhotosForCurrentLayout()
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
    guard let savedDraft = await store.saveTask(draft) else { return false }
    draft = savedDraft
    savedSnapshot = savedDraft
    return true
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
        dismiss()
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
      draft.swapPhotosForAutomaticFit(sourceID: sourceID, targetID: targetID)
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
    let task = draft
    let photoDirectory = store.photoDirectory
    let projectName = store.project(id: task.projectID)?.name ?? "Project"
    let includesWatermark = !subscriptions.hasPremiumAccess

    Task {
      do {
        try await store.restoreOriginalsIfNeeded(for: task.photos)
        let export = try await Task.detached(priority: .userInitiated) {
          try CollageRenderer.prepareExport(
            task: task,
            photoDirectory: photoDirectory,
            projectName: projectName,
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
            successDetail: "Your full-resolution collage is now in the Photo Library."
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
    successDetail: String = "Your reviewed full-resolution collage is now in the Photo Library."
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
    try? FileManager.default.removeItem(at: export.fileURL)
    exportPreview = nil
    message = EditorMessage(
      title: "Saved to Photos",
      detail: successDetail
    )
  }

  private func sharePreparedExport(_ export: PreparedCollageExport) async throws {
    let persistedURL = try await persistPreparedExport(export)
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

private struct ExportPreferenceSnapshot: Equatable {
  let outputFormat: OutputFormat
  let quality: OutputQuality
  let outputMaxDimension: Int
  let background: CollageBackground
  let spacing: Double
  let canvasCornerRadius: Double

  init(task: CollageTask) {
    outputFormat = task.outputFormat
    quality = task.quality
    outputMaxDimension = task.outputMaxDimension
    background = task.background
    spacing = task.spacing
    canvasCornerRadius = task.canvasCornerRadius
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
  let task: CollageTask
  let isSelected: Bool

  private let displaySize = CGSize(width: 76, height: 52)

  var body: some View {
    let logicalSize = LayoutEngine.outputSize(for: task)
    let frames = LayoutEngine.previewFrames(
      template: template,
      task: task,
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
      Color(uiColor: UIColor(hex: task.backgroundHex))
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
  let photo: CollagePhoto
  let image: UIImage?
  let viewOriginal: () -> Void
  let remove: () -> Void

  var body: some View {
    HStack(spacing: 12) {
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
      .accessibilityHint("Opens the full-resolution photo with zoom and pan controls")

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("View original photo")
      .accessibilityHint("Opens the full-resolution photo with zoom and pan controls")
      Button(action: viewOriginal) {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
      }
      .buttonStyle(.plain)
      .accessibilityLabel("View original photo")
      Button(role: .destructive, action: remove) {
        Image(systemName: "minus.circle.fill")
      }
      .buttonStyle(.plain)
    }
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
