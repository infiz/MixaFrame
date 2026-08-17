import PhotosUI
import SwiftUI
import UIKit

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
  @State private var customLayoutBuilder: CustomLayoutBuilderRequest?
  @State private var customLayoutNameRequest: CustomLayoutNameRequest?
  @State private var pendingCustomLayoutName = ""
  @State private var customLayoutPendingDeletion: SavedCustomLayout?
  @State private var pendingExportAction: PendingExportAction?

  init(projectID: UUID, task: CollageTask?) {
    let initialTask = task ?? CollageTask.new(projectID: projectID)
    _draft = State(initialValue: initialTask)
    _savedSnapshot = State(initialValue: initialTask)
    _isControlsHidden = State(initialValue: task != nil)
    _activeEditorTool = State(initialValue: .photos)
    _selectedLayoutFamily = State(
      initialValue: LayoutEngine.selectedTemplate(for: initialTask).family.browserFamily)
  }

  var body: some View {
    NavigationStack {
      GeometryReader { proxy in
        ZStack(alignment: .trailing) {
          previewWorkspace(
            maximumHeight: previewMaximumHeight(for: proxy.size),
            showsFooter: !isControlsHidden
          )
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
          Button {
            requestExportAction(.openControls)
          } label: {
            Label("Export", systemImage: "square.and.arrow.up")
              .labelStyle(.iconOnly)
          }
          .accessibilityHint("Opens export settings and preview options")
          .disabled(isImporting || isSaving || isExporting)

          Button("Save") {
            beginSaving(dismissAfterSave: false)
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
          onSave: { try await savePreparedExportToPhotos(export) },
          onShare: { try await sharePreparedExport(export) },
          onCancel: { cancelPreparedExport(export) }
        )
      }
      .fullScreenCover(item: $originalPhotoPreview) { photo in
        let cropConfiguration = cropConfiguration(for: photo.id)
        OriginalPhotoViewer(
          photo: photo,
          originalURL: store.imageURL(for: photo),
          cropConfiguration: cropConfiguration,
          onSelectFocus: { adjustCrop(photoID: photo.id, focalPoint: $0) },
          onAdjustCropZoom: { adjustZoom(photoID: photo.id, zoom: $0) }
        )
      }
      .fullScreenCover(item: $customLayoutBuilder) { request in
        CustomLayoutBuilderView(
          photoCount: draft.photos.count,
          canvas: draft.canvas,
          initialName: request.layout?.name ?? "Custom Layout",
          initialFrames: request.layout?.frames,
          updatesExistingLayout: request.layout != nil,
          onComplete: { name, frames, savesLayout in
            completeCustomLayoutBuilder(
              request: request,
              name: name,
              frames: frames,
              savesLayout: savesLayout
            )
          }
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
      .alert(
        customLayoutNameRequest?.title ?? "Layout Name",
        isPresented: Binding(
          get: { customLayoutNameRequest != nil },
          set: { if !$0 { customLayoutNameRequest = nil } }
        )
      ) {
        TextField("Layout name", text: $pendingCustomLayoutName)
        Button("Cancel", role: .cancel) { customLayoutNameRequest = nil }
        Button("Save") { completeCustomLayoutNameRequest() }
          .disabled(pendingCustomLayoutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .confirmationDialog(
        "Delete Custom Layout?",
        isPresented: Binding(
          get: { customLayoutPendingDeletion != nil },
          set: { if !$0 { customLayoutPendingDeletion = nil } }
        ),
        presenting: customLayoutPendingDeletion
      ) { layout in
        Button("Delete \"\(layout.name)\"", role: .destructive) {
          deleteCustomLayout(layout)
        }
        Button("Cancel", role: .cancel) {}
      } message: { layout in
        Text(
          "Existing collages keep their current frames. This removes the reusable layout from My Layouts."
        )
      }
      .confirmationDialog(
        "Save Changes Before Exporting?",
        isPresented: Binding(
          get: { pendingExportAction != nil },
          set: { if !$0 { pendingExportAction = nil } }
        ),
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
        "Save changes before going back?",
        isPresented: $isExitConfirmationPresented,
        titleVisibility: .visible
      ) {
        if draft.photos.count >= 2 {
          Button("Save and Go Back") {
            beginSaving(dismissAfterSave: true)
          }
        }
        Button("Discard Changes", role: .destructive) {
          store.discardUnsavedPhotoFiles(from: draft)
          dismiss()
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        if draft.photos.count >= 2 {
          Text("Save this collage task, discard unsaved changes, or continue editing.")
        } else {
          Text("Add at least two photos to save this collage task, or discard it and go back.")
        }
      }
    }
  }

  private func previewWorkspace(maximumHeight: CGFloat, showsFooter: Bool) -> some View {
    VStack(spacing: 6) {
      CollagePreview(
        task: draft,
        imageLoader: store.previewImage(for:),
        onViewPhoto: { showOriginalPhoto(id: $0) },
        onMovePhoto: { swapPhotos(sourceID: $0, targetID: $1) },
        onAdjustCrop: { adjustCrop(photoID: $0, focalPoint: $1) },
        onAdjustZoom: { adjustZoom(photoID: $0, zoom: $1) },
        showsLayoutDividers: !isControlsHidden && activeEditorTool == .layout,
        onAdjustLayoutDivider: adjustLayoutDivider,
        maximumHeight: maximumHeight
      )

      if showsFooter {
        HStack(spacing: 8) {
          Button {
            toggleControls()
          } label: {
            Label("Full Canvas", systemImage: "arrow.up.left.and.arrow.down.right")
          }
          .buttonStyle(.borderless)
          Spacer()
          if draft.photos.isEmpty {
            Text("Add at least 2 photos")
          } else {
            let outputSize = LayoutEngine.outputSize(for: draft)
            Text("\(Int(outputSize.width)) × \(Int(outputSize.height)) px")
              .monospacedDigit()
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        if !draft.photos.isEmpty {
          Text(
            "Hold briefly, then drag to crop · Pinch to zoom · Double-tap for original · Hold longer to swap"
          )
          .font(.caption2)
          .foregroundStyle(.tertiary)
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.top, 6)
    .padding(.bottom, 8)
    .frame(maxWidth: .infinity)
    .background(Color(uiColor: .systemBackground))
  }

  private func editorControls(availableSize: CGSize) -> some View {
    let panelWidth = min(680, max(1, availableSize.width - 16))
    let controlsHeight = max(180, min(520, availableSize.height * 0.5 - 8))
    let toolBarHeight: CGFloat = 54
    let settingsHeight = max(118, controlsHeight - toolBarHeight - 8)

    return ZStack(alignment: .bottom) {
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

  private func previewMaximumHeight(for availableSize: CGSize) -> CGFloat {
    if isControlsHidden {
      return max(140, availableSize.height - 12)
    }
    return max(140, availableSize.height * 0.42)
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

  private func openExportControls() {
    hideKeyboard()
    withAnimation(.easeInOut(duration: 0.2)) {
      activeEditorTool = .output
      isControlsHidden = false
    }
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
    case .openControls:
      openExportControls()
    case .preview:
      beginExport()
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
        Label(tool.title, systemImage: tool.symbol)
          .font(.headline)
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

      Form {
        settingsSections(for: tool)
      }
      .scrollContentBackground(.hidden)
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
  private func settingsSections(for tool: EditorTool) -> some View {
    switch tool {
    case .photos:
      Section {
        PhotosPicker(
          selection: $pickerItems,
          maxSelectionCount: max(0, 12 - draft.photos.count),
          matching: .images
        ) {
          Label("Add Photos", systemImage: "photo.badge.plus")
        }
        .disabled(isImporting || draft.photos.count >= 12)

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
      } header: {
        Text("\(draft.photos.count) of 12 photos")
      } footer: {
        Text(
          "Tap a photo row to view the original photo. Touch and hold a photo on the canvas, then drag it onto another frame to swap."
        )
      }

    case .layout:
      Section {
        Picker(
          "Aspect Ratio",
          selection: Binding(
            get: { draft.canvas },
            set: { selectCanvas($0) }
          )
        ) {
          ForEach(CanvasPreset.allCases) { preset in
            Text(preset.title).tag(preset)
          }
        }
        .disabled(LayoutEngine.isNaturalVerticalStrip(draft))

        customLayoutsSelector
        layoutSelector
        if LayoutEngine.isNaturalVerticalStrip(draft) {
          let outputWidth = Int(LayoutEngine.outputSize(for: draft).width)
          Label(
            "Every photo initially spans the \(outputWidth) px output width at its natural aspect ratio. Drag a divider to customize photo heights.",
            systemImage: "rectangle.portrait.on.rectangle.portrait"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else if draft.photos.count > 1 {
          Label(
            "Drag the handles on the collage to resize neighboring rows and columns.",
            systemImage: "square.grid.2x2"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } else {
          Label(
            "Add another photo to create an adjustable divider.",
            systemImage: "info.circle"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
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
        if draft.usesAutomaticPhotoArrangement {
          Label("Photos arranged by layout fit", systemImage: "checkmark.circle.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Button {
            refitPhotosForCurrentLayout()
          } label: {
            Label("Arrange Photos by Best Fit", systemImage: "wand.and.stars")
          }
        }
      }

    case .canvas:
      Section("Collage") {
        Picker("Background", selection: $draft.background) {
          ForEach(CollageBackground.allCases) { background in
            Label(background.title, systemImage: background.symbol).tag(background)
          }
        }
        .pickerStyle(.segmented)

      }

      Section("Resolution") {
        ForEach(ResolutionPreset.allCases) { preset in
          Button {
            draft.outputMaxDimension = preset.rawValue
          } label: {
            HStack {
              Text(preset.title)
              Spacer()
              if draft.outputMaxDimension == preset.rawValue {
                Image(systemName: "checkmark").foregroundStyle(.indigo)
              }
            }
          }
          .foregroundStyle(.primary)
        }
        Stepper(
          "Custom · \(draft.outputMaxDimension) px",
          value: $draft.outputMaxDimension,
          in: 512...8192,
          step: 128
        )
      }

    case .output:
      Section("Output") {
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

      Section {
        Button {
          requestExportAction(.preview)
        } label: {
          Label("Preview Export", systemImage: "eye")
        }
        if subscriptions.hasPremiumAccess {
          Label("Premium export · No watermark", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
        } else {
          Button {
            showingSubscription = true
          } label: {
            Label("Free export · MixaFrame watermark included", systemImage: "crown")
          }
        }
      } footer: {
        Text(
          subscriptions.hasPremiumAccess
            ? "Review, zoom, and move the finished image before saving or sharing it."
            : "Editing stays free. Start the 7-day trial to export without the MixaFrame watermark."
        )
      }
      .disabled(
        draft.photos.count < 2 || isExporting || !subscriptions.hasLoadedEntitlements
      )
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
    let availableLayoutCount = fittedLayouts.values.reduce(0) { $0 + $1.count }
    let selectedTemplate = LayoutEngine.selectedTemplate(for: draft)

    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Layout")
        Spacer()
        Text("\(selectedTemplate.title) · \(availableLayoutCount) options")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

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
          }
        }
        .padding(.vertical, 2)
      }

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
          }
        }
        .padding(.vertical, 2)
      }

      Text(
        displayedFamily == .hero
          ? "All distinct Featured layouts are shown and ranked for these photos."
          : "Ranked for these photos. Layouts that would crop too much are hidden."
      )
      .font(.caption2)
      .foregroundStyle(.secondary)
    }
  }

  private var customLayoutsSelector: some View {
    let matchingLayouts = store.savedCustomLayouts.filter { $0.photoCount == draft.photos.count }
    let selectedID = draft.savedCustomLayoutID

    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("My Layouts")
        Spacer()
        Button {
          customLayoutBuilder = CustomLayoutBuilderRequest(layout: nil)
        } label: {
          Label("Create", systemImage: "rectangle.split.2x2")
        }
        .disabled(draft.photos.count < 2)
      }

      if matchingLayouts.isEmpty {
        Text(
          draft.photos.count < 2
            ? "Add at least two photos to create a custom layout."
            : "Create reusable cuts for this photo count."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(spacing: 9) {
            ForEach(matchingLayouts) { layout in
              Button {
                applyCustomLayout(layout.frames, savedLayoutID: layout.id)
              } label: {
                VStack(spacing: 4) {
                  CustomLayoutThumbnail(
                    frames: layout.frames,
                    canvas: draft.canvas,
                    backgroundHex: draft.backgroundHex,
                    isSelected: selectedID == layout.id
                  )
                  Text(layout.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 82)
                }
              }
              .buttonStyle(.plain)
              .accessibilityLabel(layout.name)
              .accessibilityAddTraits(selectedID == layout.id ? .isSelected : [])
              .contextMenu {
                Button {
                  customLayoutBuilder = CustomLayoutBuilderRequest(layout: layout)
                } label: {
                  Label("Edit Cuts", systemImage: "rectangle.split.2x2")
                }
                Button {
                  beginRenamingCustomLayout(layout)
                } label: {
                  Label("Rename", systemImage: "pencil")
                }
                Button {
                  _ = store.duplicateCustomLayout(id: layout.id)
                } label: {
                  Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button(role: .destructive) {
                  customLayoutPendingDeletion = layout
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            }
          }
          .padding(.vertical, 2)
        }
      }

      if let customFrames = draft.customLayoutFrames,
        customFrames.count == draft.photos.count
      {
        HStack {
          Button {
            beginSavingCurrentCustomLayout()
          } label: {
            Label("Save as New", systemImage: "square.and.arrow.down")
          }
          if let selectedID,
            store.savedCustomLayouts.contains(where: { $0.id == selectedID })
          {
            Button {
              store.updateCustomLayout(id: selectedID, frames: customFrames)
            } label: {
              Label("Update Saved", systemImage: "arrow.triangle.2.circlepath")
            }
          }
        }
        .font(.caption)
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
      } else {
        draft.layout = .smartGrid
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

  private func completeCustomLayoutBuilder(
    request: CustomLayoutBuilderRequest,
    name: String,
    frames: [NormalizedLayoutFrame],
    savesLayout: Bool
  ) {
    var savedLayoutID: UUID?
    if savesLayout {
      if let existing = request.layout {
        store.updateCustomLayout(id: existing.id, name: name, frames: frames)
        savedLayoutID = existing.id
      } else {
        savedLayoutID = store.createCustomLayout(
          name: name,
          photoCount: draft.photos.count,
          frames: frames
        )
      }
    }
    applyCustomLayout(frames, savedLayoutID: savedLayoutID)
    customLayoutBuilder = nil
  }

  private func applyCustomLayout(
    _ frames: [NormalizedLayoutFrame],
    savedLayoutID: UUID?
  ) {
    guard frames.count == draft.photos.count, frames.allSatisfy(\.isValid) else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      draft.clearLayoutCustomization(invalidateExport: true)
      draft.clearSavedLayoutSnapshot()
      draft.layoutID = LayoutCatalog.customTemplate(photoCount: draft.photos.count).id
      draft.layout = .smartGrid
      draft.mainPhotoCount = nil
      draft.customLayoutFrames = frames
      draft.savedCustomLayoutID = savedLayoutID
      draft.resetPhotosForAutomaticFit()
      lockCurrentAutomaticArrangement()
    }
  }

  private func beginSavingCurrentCustomLayout() {
    pendingCustomLayoutName = "Custom Layout"
    customLayoutNameRequest = CustomLayoutNameRequest(action: .saveCurrent)
  }

  private func beginRenamingCustomLayout(_ layout: SavedCustomLayout) {
    pendingCustomLayoutName = layout.name
    customLayoutNameRequest = CustomLayoutNameRequest(action: .rename(layout.id))
  }

  private func completeCustomLayoutNameRequest() {
    guard let request = customLayoutNameRequest else { return }
    let name = pendingCustomLayoutName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    switch request.action {
    case .saveCurrent:
      guard let frames = draft.customLayoutFrames else { break }
      let id = store.createCustomLayout(
        name: name,
        photoCount: draft.photos.count,
        frames: frames
      )
      draft.savedCustomLayoutID = id
    case .rename(let id):
      store.updateCustomLayout(id: id, name: name)
    }
    customLayoutNameRequest = nil
  }

  private func deleteCustomLayout(_ layout: SavedCustomLayout) {
    store.deleteCustomLayout(id: layout.id)
    if draft.savedCustomLayoutID == layout.id {
      draft.savedCustomLayoutID = nil
    }
    customLayoutPendingDeletion = nil
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

  private func saveDraft() {
    draft = store.saveTask(draft)
    savedSnapshot = draft
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
      saveDraft()
      if dismissAfterSave {
        dismiss()
      } else {
        isSaving = false
        completion?()
      }
    }
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
    let wasEmpty = draft.photos.isEmpty
    Task {
      var failures = 0
      for batchStart in stride(from: 0, to: items.count, by: 2) {
        let indexes = Array(batchStart..<min(batchStart + 2, items.count))
        let outcomes = await withTaskGroup(of: (Int, CollagePhoto?).self) { group in
          for index in indexes {
            let item = items[index]
            group.addTask {
              do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                  return (index, nil)
                }
                return (index, try await store.importPhotoData(data))
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
          draft.clearLayoutCustomization(invalidateExport: true)
          draft.clearCustomLayout()
          draft.clearSavedLayoutSnapshot()
          draft.photos.append(contentsOf: importedPhotos)
        }
      }
      if wasEmpty && !draft.photos.isEmpty {
        applyAutomaticRecommendations()
      } else {
        normalizeLayoutSelection()
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
    draft.layout = .smartGrid
    draft.layoutID = recommendation.template.id
    selectedLayoutFamily = recommendation.template.family.browserFamily
  }

  private func removePhoto(id: UUID) {
    let removedPhoto = draft.photos.first { $0.id == id }
    draft.photos.removeAll { $0.id == id }
    draft.clearLayoutCustomization(invalidateExport: true)
    draft.clearCustomLayout()
    draft.clearSavedLayoutSnapshot()
    if let removedPhoto {
      store.discardPhotoIfUnreferenced(removedPhoto)
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
    guard sourceID != targetID,
      let sourceIndex = draft.photos.firstIndex(where: { $0.id == sourceID }),
      let targetIndex = draft.photos.firstIndex(where: { $0.id == targetID })
    else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      draft.photos.swapAt(sourceIndex, targetIndex)
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

  private func beginExport() {
    guard draft.photos.count >= 2 else { return }
    isExporting = true
    let task = draft
    let photoDirectory = store.photoDirectory
    let projectName = store.project(id: task.projectID)?.name ?? "Project"
    let includesWatermark = !subscriptions.hasPremiumAccess

    Task {
      do {
        let export = try await Task.detached(priority: .userInitiated) {
          try CollageRenderer.prepareExport(
            task: task,
            photoDirectory: photoDirectory,
            projectName: projectName,
            includesWatermark: includesWatermark
          )
        }.value
        exportPreview = export
      } catch {
        message = EditorMessage(
          title: "Export Failed", detail: error.localizedDescription)
      }
      isExporting = false
    }
  }

  private func savePreparedExportToPhotos(_ export: PreparedCollageExport) async throws {
    try await CollageRenderer.saveToPhotoLibrary(fileURL: export.fileURL)
    _ = try persistPreparedExport(export)
    try? FileManager.default.removeItem(at: export.fileURL)
    exportPreview = nil
    message = EditorMessage(
      title: "Saved to Photos",
      detail: "Your reviewed full-resolution collage is now in the Photo Library."
    )
  }

  private func sharePreparedExport(_ export: PreparedCollageExport) async throws {
    let persistedURL = try persistPreparedExport(export)
    try? FileManager.default.removeItem(at: export.fileURL)
    exportPreview = nil
    try? await Task.sleep(nanoseconds: 250_000_000)
    shareItem = ShareItem(url: persistedURL)
  }

  private func persistPreparedExport(_ export: PreparedCollageExport) throws -> URL {
    let persistedURL = try store.persistExport(from: export.fileURL, for: draft)
    draft.latestExportFileName = persistedURL.lastPathComponent
    saveDraft()
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

private struct CustomLayoutThumbnail: View {
  let frames: [NormalizedLayoutFrame]
  let canvas: CanvasPreset
  let backgroundHex: String
  let isSelected: Bool

  private let displaySize = CGSize(width: 76, height: 52)

  var body: some View {
    let ratio = canvas.aspectRatio
    let canvasSize: CGSize =
      ratio >= displaySize.width / displaySize.height
      ? CGSize(width: displaySize.width, height: displaySize.width / ratio)
      : CGSize(width: displaySize.height * ratio, height: displaySize.height)
    let origin = CGPoint(
      x: (displaySize.width - canvasSize.width) / 2,
      y: (displaySize.height - canvasSize.height) / 2
    )

    ZStack(alignment: .topLeading) {
      Color(uiColor: .tertiarySystemBackground)
      Color(uiColor: UIColor(hex: backgroundHex))
        .frame(width: canvasSize.width, height: canvasSize.height)
        .offset(x: origin.x, y: origin.y)
      ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
        let rect = CGRect(
          x: origin.x + CGFloat(frame.x) * canvasSize.width,
          y: origin.y + CGFloat(frame.y) * canvasSize.height,
          width: CGFloat(frame.width) * canvasSize.width,
          height: CGFloat(frame.height) * canvasSize.height
        ).insetBy(dx: 0.7, dy: 0.7)
        Rectangle()
          .fill(Color.indigo.opacity(index.isMultiple(of: 2) ? 0.78 : 0.48))
          .frame(width: max(1, rect.width), height: max(1, rect.height))
          .offset(x: rect.minX, y: rect.minY)
      }
    }
    .frame(width: displaySize.width, height: displaySize.height)
    .clipped()
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(
          isSelected ? Color.indigo : Color.secondary.opacity(0.25),
          lineWidth: isSelected ? 3 : 1
        )
    }
  }
}

private struct CustomLayoutBuilderView: View {
  @Environment(\.dismiss) private var dismiss
  let photoCount: Int
  let canvas: CanvasPreset
  let updatesExistingLayout: Bool
  let onComplete: (String, [NormalizedLayoutFrame], Bool) -> Void

  @State private var name: String
  @State private var frames: [NormalizedLayoutFrame]
  @State private var selectedIndex = 0
  @State private var history: [[NormalizedLayoutFrame]] = []

  init(
    photoCount: Int,
    canvas: CanvasPreset,
    initialName: String,
    initialFrames: [NormalizedLayoutFrame]?,
    updatesExistingLayout: Bool,
    onComplete: @escaping (String, [NormalizedLayoutFrame], Bool) -> Void
  ) {
    self.photoCount = max(1, min(photoCount, 12))
    self.canvas = canvas
    self.updatesExistingLayout = updatesExistingLayout
    self.onComplete = onComplete
    _name = State(initialValue: initialName)
    let validInitial =
      initialFrames?.count == photoCount
      && initialFrames?.allSatisfy(\.isValid) == true
    _frames = State(
      initialValue: validInitial
        ? initialFrames ?? []
        : [NormalizedLayoutFrame(x: 0, y: 0, width: 1, height: 1)]
    )
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 18) {
        GeometryReader { proxy in
          let canvasSize = fittedCanvasSize(in: proxy.size)
          let origin = CGPoint(
            x: (proxy.size.width - canvasSize.width) / 2,
            y: (proxy.size.height - canvasSize.height) / 2
          )
          ZStack(alignment: .topLeading) {
            Color(uiColor: .secondarySystemBackground)
              .frame(width: canvasSize.width, height: canvasSize.height)
              .offset(x: origin.x, y: origin.y)
            ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
              let rect = CGRect(
                x: origin.x + CGFloat(frame.x) * canvasSize.width,
                y: origin.y + CGFloat(frame.y) * canvasSize.height,
                width: CGFloat(frame.width) * canvasSize.width,
                height: CGFloat(frame.height) * canvasSize.height
              ).insetBy(dx: 2, dy: 2)
              Button {
                selectedIndex = index
              } label: {
                ZStack {
                  Rectangle()
                    .fill(Color.indigo.opacity(index.isMultiple(of: 2) ? 0.72 : 0.48))
                  Text("\(index + 1)")
                    .font(.headline)
                    .foregroundStyle(.white)
                }
                .overlay {
                  Rectangle()
                    .stroke(index == selectedIndex ? Color.yellow : Color.clear, lineWidth: 4)
                }
              }
              .buttonStyle(.plain)
              .frame(width: max(1, rect.width), height: max(1, rect.height))
              .offset(x: rect.minX, y: rect.minY)
              .accessibilityLabel("Frame \(index + 1)")
              .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
            }
          }
        }
        .frame(maxHeight: 430)
        .padding(.horizontal)

        VStack(spacing: 12) {
          HStack {
            Label("\(frames.count) of \(photoCount) frames", systemImage: "photo.on.rectangle")
            Spacer()
            Button("Undo", action: undo)
              .disabled(history.isEmpty)
            Button("Start Over", action: reset)
          }

          HStack(spacing: 12) {
            Button {
              splitSelected(axis: .vertical)
            } label: {
              Label("Side by Side", systemImage: "rectangle.split.2x1")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
              splitSelected(axis: .horizontal)
            } label: {
              Label("Stack", systemImage: "rectangle.split.1x2")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
          }
          .disabled(frames.count >= photoCount)

          TextField("Layout name", text: $name)
            .textFieldStyle(.roundedBorder)

          if frames.count < photoCount {
            Text("Select a frame and split it. Add \(photoCount - frames.count) more cut(s).")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("Apply the layout, then drag its dividers directly on the collage to resize it.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          HStack(spacing: 12) {
            Button("Apply Once") {
              onComplete(resolvedName, frames, false)
              dismiss()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)

            Button(updatesExistingLayout ? "Update & Apply" : "Save & Apply") {
              onComplete(resolvedName, frames, true)
              dismiss()
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity)
          }
          .disabled(!isComplete)
        }
        .padding(.horizontal)
        .padding(.bottom)
      }
      .navigationTitle("Custom Cuts")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private var resolvedName: String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Custom Layout" : trimmed
  }

  private var isComplete: Bool {
    frames.count == photoCount
      && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func fittedCanvasSize(in available: CGSize) -> CGSize {
    let ratio = canvas.aspectRatio
    let maximum = CGSize(width: max(1, available.width), height: max(1, available.height))
    if maximum.width / maximum.height > ratio {
      return CGSize(width: maximum.height * ratio, height: maximum.height)
    }
    return CGSize(width: maximum.width, height: maximum.width / ratio)
  }

  private func splitSelected(axis: LayoutAxis) {
    guard frames.count < photoCount, frames.indices.contains(selectedIndex) else { return }
    history.append(frames)
    let frame = frames[selectedIndex]
    let first: NormalizedLayoutFrame
    let second: NormalizedLayoutFrame
    switch axis {
    case .horizontal:
      first = NormalizedLayoutFrame(
        x: frame.x, y: frame.y, width: frame.width, height: frame.height / 2)
      second = NormalizedLayoutFrame(
        x: frame.x, y: frame.y + frame.height / 2,
        width: frame.width, height: frame.height / 2)
    case .vertical:
      first = NormalizedLayoutFrame(
        x: frame.x, y: frame.y, width: frame.width / 2, height: frame.height)
      second = NormalizedLayoutFrame(
        x: frame.x + frame.width / 2, y: frame.y,
        width: frame.width / 2, height: frame.height)
    }
    frames.replaceSubrange(selectedIndex...selectedIndex, with: [first, second])
  }

  private func undo() {
    guard let previous = history.popLast() else { return }
    frames = previous
    selectedIndex = min(selectedIndex, max(0, frames.count - 1))
  }

  private func reset() {
    if frames.count != 1 { history.append(frames) }
    frames = [NormalizedLayoutFrame(x: 0, y: 0, width: 1, height: 1)]
    selectedIndex = 0
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

private struct CustomLayoutBuilderRequest: Identifiable {
  let id = UUID()
  let layout: SavedCustomLayout?
}

private enum PendingExportAction {
  case openControls
  case preview
}

private struct CustomLayoutNameRequest: Identifiable {
  enum Action {
    case saveCurrent
    case rename(UUID)
  }

  let id = UUID()
  let action: Action

  var title: String {
    switch action {
    case .saveCurrent: "Save Custom Layout"
    case .rename: "Rename Custom Layout"
    }
  }
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
