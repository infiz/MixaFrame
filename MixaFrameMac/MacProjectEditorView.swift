import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacProjectEditorView: View {
  @EnvironmentObject private var store: AppStore
  let collectionID: UUID
  @State private var draft: Project
  @State private var savedSnapshot: Project
  @State private var selectedPhotoID: UUID?
  @State private var selectedFamily: LayoutFamily
  @State private var showingImporter = false
  @State private var isImporting = false
  @State private var isSaving = false
  @State private var isExporting = false
  @State private var errorMessage: String?

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
      VStack(spacing: 0) {
        previewStage
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .layoutPriority(1)

        Divider()

        bottomWorkspace(width: proxy.size.width)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .navigationTitle(displayName)
    .fileImporter(
      isPresented: $showingImporter,
      allowedContentTypes: [.image],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls): importPhotos(urls)
      case .failure(let error): errorMessage = error.localizedDescription
      }
    }
    .alert(
      "MixaFrame",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "The operation could not be completed.")
    }
  }

  private func bottomWorkspace(width: CGFloat) -> some View {
    let usesSingleControlRow = width >= 1_020

    return VStack(spacing: 0) {
      photoTray
        .frame(height: photoTrayHeight)

      Divider()

      Group {
        if usesSingleControlRow {
          HStack(spacing: 1) {
            projectInspector
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            exportInspector
              .frame(width: min(420, max(330, width * 0.32)))
              .frame(maxHeight: .infinity)
          }
        } else {
          VStack(spacing: 1) {
            projectInspector
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            exportInspector
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        }
      }
      .frame(height: usesSingleControlRow ? 240 : 300)
    }
    .frame(maxWidth: .infinity)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var previewStage: some View {
    ZStack {
      Color.black.opacity(0.92)
      if draft.photos.isEmpty {
        ContentUnavailableView {
          Label("No Photos", systemImage: "photo.on.rectangle.angled")
        } description: {
          Text("Import photos from Finder to begin your project.")
        } actions: {
          Button("Add Photos") { showingImporter = true }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
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

  private var projectInspector: some View {
    Form {
      Section("Project") {
        TextField("Title", text: $draft.name)
        Picker("Canvas", selection: $draft.canvas) {
          ForEach(CanvasPreset.allCases) { preset in
            Text(preset.title).tag(preset)
          }
        }
        Picker("Background", selection: $draft.background) {
          ForEach(CollageBackground.allCases) { background in
            Label(background.title, systemImage: background.symbol).tag(background)
          }
        }
        LabeledContent("Spacing") {
          HStack {
            Slider(value: $draft.spacing, in: 0...40, step: 1)
              .frame(minWidth: 120)
            Text("\(Int(draft.spacing))").monospacedDigit().frame(width: 26)
          }
        }
        LabeledContent("Canvas corners") {
          HStack {
            Slider(value: $draft.canvasCornerRadius, in: 0...50, step: 1)
              .frame(minWidth: 120)
            Text("\(Int(draft.canvasCornerRadius))%")
              .monospacedDigit().frame(width: 38)
          }
        }
      }

      Section("Layout") {
        Picker("Family", selection: $selectedFamily) {
          ForEach(availableFamilies) { family in
            Label(family.title, systemImage: family.symbol).tag(family)
          }
        }
        .pickerStyle(.menu)

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 8)], spacing: 8) {
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
              .frame(maxWidth: .infinity, minHeight: 36)
              .background(
                selectedTemplate.id == template.id
                  ? Color.indigo.opacity(0.14) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8)
              )
            }
            .buttonStyle(.plain)
          }
        }
      }

      if let selectedIndex {
        Section("Selected Photo") {
          LabeledContent("Position") {
            Text("\(selectedIndex + 1) of \(draft.photos.count)")
          }
          LabeledContent("Horizontal focus") {
            Slider(value: focalBinding(index: selectedIndex, keyPath: \.focalX), in: 0...1)
              .frame(minWidth: 150)
          }
          LabeledContent("Vertical focus") {
            Slider(value: focalBinding(index: selectedIndex, keyPath: \.focalY), in: 0...1)
              .frame(minWidth: 150)
          }
          LabeledContent("Zoom") {
            Slider(value: zoomBinding(index: selectedIndex), in: 1...4)
              .frame(minWidth: 150)
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
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var exportInspector: some View {
    Form {
      Section("Export Settings") {
        Picker("Format", selection: $draft.outputFormat) {
          ForEach(OutputFormat.allCases) { format in
            Text(format.title).tag(format)
          }
        }
        Picker("Quality", selection: $draft.quality) {
          ForEach(OutputQuality.allCases) { quality in
            Text(quality.title).tag(quality)
          }
        }
        Picker("Maximum size", selection: $draft.outputMaxDimension) {
          ForEach(ResolutionPreset.allCases) { preset in
            Text(preset.title).tag(preset.rawValue)
          }
        }
      }
    }
    .formStyle(.grouped)
    .scrollContentBackground(.hidden)
    .background(Color(nsColor: .controlBackgroundColor))
  }

  private var photoTray: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Photos").font(.headline)
        Text("\(draft.photos.count)/12")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        Button("Add Photos", systemImage: "plus") { showingImporter = true }
          .disabled(isBusy || draft.photos.count >= 12)
          .controlSize(.large)
        Button("Save Project", systemImage: "square.and.arrow.down") { save() }
          .disabled(isBusy || draft.photos.count < 2 || !hasUnsavedChanges)
          .controlSize(.large)
        Button("Export Image", systemImage: "square.and.arrow.up") { export() }
          .buttonStyle(.borderedProminent)
          .disabled(isBusy || draft.photos.count < 2)
          .controlSize(.large)
      }
      ScrollView(.horizontal) {
        LazyHStack(spacing: 10) {
          ForEach(Array(draft.photos.enumerated()), id: \.element.id) { index, photo in
            Button {
              selectedPhotoID = photo.id
            } label: {
              VStack(spacing: 5) {
                Group {
                  if let image = store.image(for: photo) {
                    Image(nsImage: image).resizable().scaledToFill()
                  } else {
                    Color.secondary.opacity(0.15)
                      .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                  }
                }
                .frame(width: 112, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay {
                  RoundedRectangle(cornerRadius: 9)
                    .stroke(selectedPhotoID == photo.id ? Color.indigo : .clear, lineWidth: 3)
                }
                Text("Photo \(index + 1)").font(.caption).foregroundStyle(.secondary)
              }
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.vertical, 2)
      }
    }
    .padding(14)
    .background(.bar)
  }

  private var photoTrayHeight: CGFloat {
    draft.photos.isEmpty ? 74 : 174
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
    draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Untitled Project" : draft.name
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

  private func importPhotos(_ urls: [URL]) {
    guard !urls.isEmpty else { return }
    isImporting = true
    Task {
      let capacity = max(0, 12 - draft.photos.count)
      let imported = await MacMediaImportService.importPhotos(
        from: Array(urls.prefix(capacity)),
        using: store
      )
      if !imported.isEmpty {
        draft.photos.append(contentsOf: imported)
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
        selectedPhotoID = selectedPhotoID ?? imported.first?.id
      }
      isImporting = false
    }
  }

  private func save() {
    isSaving = true
    Task {
      if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        draft.name = "Project"
      }
      if let saved = await store.saveProject(draft) {
        draft = saved
        savedSnapshot = saved
      }
      isSaving = false
    }
  }

  private func export() {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [contentType(for: draft.outputFormat)]
    panel.nameFieldStringValue = "\(safeFileName(displayName)).\(draft.outputFormat.fileExtension)"
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    isExporting = true
    let exportDraft = draft
    let photoDirectory = store.photoDirectory
    Task {
      do {
        try await Task.detached(priority: .userInitiated) {
          try MacCollageRenderer.export(
            project: exportDraft,
            photoDirectory: photoDirectory,
            destination: destination
          )
        }.value
        if let saved = await store.saveProject(exportDraft) {
          draft = saved
          savedSnapshot = saved
        }
      } catch {
        errorMessage = error.localizedDescription
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
    guard let index = selectedIndex else { return }
    let destination = index + offset
    guard draft.photos.indices.contains(destination) else { return }
    draft.photos.swapAt(index, destination)
    draft.isPhotoOrderManuallyAdjusted = true
    draft.clearSavedLayoutSnapshot()
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

  private func safeFileName(_ value: String) -> String {
    let invalid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted
    return value.components(separatedBy: invalid).joined().trimmingCharacters(in: .whitespaces)
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
