import Photos
import SwiftUI
import UIKit

struct ExportPreviewView: View {
  let export: PreparedCollageExport
  let formatTitle: String
  let existingPhotoAssetIdentifier: String?
  let onSave: (PhotoLibraryExportMode) async throws -> Void
  let onShare: () async throws -> Void
  let onCancel: () -> Void

  @State private var isSaving = false
  @State private var errorMessage: String?
  @State private var isPhotoExportChoicePresented = false
  @State private var pendingPhotoLibraryExportMode: PhotoLibraryExportMode?

  var body: some View {
    NavigationStack {
      ZoomableImageViewer(
        image: export.previewImage,
        maximumScale: 8,
        accessibilityTitle: "Exported collage preview"
      )
      .background(Color.black.ignoresSafeArea())
      .navigationTitle("Export Preview")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.black, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Back", systemImage: "chevron.left", action: onCancel)
            .disabled(isSaving)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("Share", systemImage: "square.and.arrow.up") {
            shareExport()
          }
          .disabled(isSaving)
        }
      }
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 8) {
          Label(export.fileURL.lastPathComponent, systemImage: "doc")
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(exportDetails)
          .font(.caption)
          .foregroundStyle(.secondary)
          if export.includesWatermark {
            Label("Free export · MixaFrame watermark included", systemImage: "info.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          Button {
            if existingPhotoAssetIdentifier != nil {
              isPhotoExportChoicePresented = true
            } else {
              saveToPhotos(mode: .createNew)
            }
          } label: {
            HStack {
              if isSaving { ProgressView().tint(.white) }
              Label(
                isSaving ? "Saving…" : "Save to Photos",
                systemImage: "square.and.arrow.down"
              )
            }
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .disabled(isSaving)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
      }
    }
    .interactiveDismissDisabled(true)
    .sheet(isPresented: $isPhotoExportChoicePresented, onDismiss: completePhotoExportChoice) {
      if let existingPhotoAssetIdentifier {
        ExistingPhotoExportChoiceView(
          assetIdentifier: existingPhotoAssetIdentifier,
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
    .alert(
      "Save Failed",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "The collage could not be saved.")
    }
  }

  private func saveToPhotos(mode: PhotoLibraryExportMode) {
    isSaving = true
    Task {
      do {
        try await onSave(mode)
      } catch {
        errorMessage = error.localizedDescription
      }
      isSaving = false
    }
  }

  private var exportDetails: String {
    var details = [
      "\(Int(export.outputSize.width)) × \(Int(export.outputSize.height)) px",
      formatTitle,
    ]
    if let fileSizeDescription {
      details.append(fileSizeDescription)
    }
    return details.joined(separator: " · ")
  }

  private var fileSizeDescription: String? {
    guard
      let resourceValues = try? export.fileURL.resourceValues(forKeys: [.fileSizeKey]),
      let fileSize = resourceValues.fileSize
    else { return nil }
    return ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
  }

  private func completePhotoExportChoice() {
    guard let mode = pendingPhotoLibraryExportMode else { return }
    pendingPhotoLibraryExportMode = nil
    saveToPhotos(mode: mode)
  }

  private func shareExport() {
    isSaving = true
    Task {
      do {
        try await onShare()
      } catch {
        errorMessage = error.localizedDescription
      }
      isSaving = false
    }
  }
}

struct ExistingPhotoExportChoiceView: View {
  let assetIdentifier: String
  let onSelect: (PhotoLibraryExportMode) -> Void
  let onCancel: () -> Void

  @State private var previewImage: UIImage?
  @State private var exportedAt: Date?
  @State private var isLoading = true
  @State private var canReplace = false
  @State private var loadMessage: String?

  var body: some View {
    NavigationStack {
      VStack(spacing: 14) {
        Group {
          if let previewImage {
            Image(uiImage: previewImage)
              .resizable()
              .scaledToFit()
          } else if isLoading {
            ProgressView("Loading previous export…")
          } else {
            ContentUnavailableView(
              "Preview Unavailable",
              systemImage: "photo.badge.exclamationmark",
              description: Text(loadMessage ?? "The previous photo could not be loaded.")
            )
          }
        }
        .frame(maxWidth: .infinity, minHeight: 130, maxHeight: 170)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .clipShape(RoundedRectangle(cornerRadius: 14))

        if let exportedAt {
          Text(
            "Previously exported "
              + exportedAt.formatted(date: .abbreviated, time: .shortened)
          )
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Button("Replace Existing Photo") {
          onSelect(.replaceExisting)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
        .disabled(!canReplace)

        Button("Create New Photo") {
          onSelect(.createNew)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .frame(maxWidth: .infinity)
      }
      .padding(16)
      .navigationTitle("Photo Already Exported")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
        }
      }
      .task {
        await loadExistingPhoto()
      }
    }
  }

  private func loadExistingPhoto() async {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard status == .authorized || status == .limited else {
      isLoading = false
      loadMessage = "Allow Photo Library access to preview or replace the previous export."
      return
    }

    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil)
      .firstObject
    else {
      isLoading = false
      loadMessage = "The previous export may have been deleted. Create a new photo to continue."
      return
    }

    exportedAt = asset.creationDate
    canReplace = true
    previewImage = await requestPreview(for: asset)
    isLoading = false
    if previewImage == nil {
      loadMessage = "The photo exists, but its preview could not be loaded."
    }
  }

  private func requestPreview(for asset: PHAsset) async -> UIImage? {
    await withCheckedContinuation { continuation in
      let options = PHImageRequestOptions()
      options.deliveryMode = .highQualityFormat
      options.resizeMode = .fast
      options.isNetworkAccessAllowed = true
      PHImageManager.default().requestImage(
        for: asset,
        targetSize: CGSize(width: 900, height: 600),
        contentMode: .aspectFit,
        options: options
      ) { image, _ in
        continuation.resume(returning: image)
      }
    }
  }
}

struct OriginalPhotoViewer: View {
  let photo: CollagePhoto
  let loadOriginal: () async -> UIImage?
  let cropConfiguration: CollagePhotoCropConfiguration
  let onSelectFocus: (CGPoint) -> Void
  let onAdjustCropZoom: (Double) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var image: UIImage?
  @State private var didFailToLoad = false
  @State private var showsFocusGuides = true
  @State private var focusPoint: CGPoint
  @State private var cropZoom: Double

  init(
    photo: CollagePhoto,
    loadOriginal: @escaping () async -> UIImage?,
    cropConfiguration: CollagePhotoCropConfiguration,
    onSelectFocus: @escaping (CGPoint) -> Void,
    onAdjustCropZoom: @escaping (Double) -> Void
  ) {
    self.photo = photo
    self.loadOriginal = loadOriginal
    self.cropConfiguration = cropConfiguration
    self.onSelectFocus = onSelectFocus
    self.onAdjustCropZoom = onAdjustCropZoom
    _focusPoint = State(initialValue: CGPoint(x: photo.focalX, y: photo.focalY))
    _cropZoom = State(initialValue: photo.effectiveZoom)
  }

  var body: some View {
    NavigationStack {
      Group {
        if let image {
          ZoomableImageViewer(
            image: image,
            maximumScale: 32,
            accessibilityTitle: "Original full-resolution photo",
            focusArea: photo.detectedFocusArea,
            focusPoint: focusPoint,
            showsFocusGuides: showsFocusGuides,
            cropConfiguration: cropConfiguration,
            collageCropZoom: cropZoom,
            onSelectFocus: selectFocus
          )
        } else if didFailToLoad {
          ContentUnavailableView(
            "Photo Unavailable",
            systemImage: "photo.badge.exclamationmark",
            description: Text(
              "The saved copy and its referenced original in Photos could not be loaded."
            )
          )
        } else {
          VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Loading original photo…")
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color.black.ignoresSafeArea())
      .navigationTitle("Original Photo")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.black, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close", systemImage: "xmark", action: dismiss.callAsFunction)
        }
      }
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 8) {
          Toggle(isOn: $showsFocusGuides) {
            Label("Show Focus Area", systemImage: "viewfinder")
              .font(.subheadline.weight(.medium))
          }
          .tint(.indigo)

          if !cropConfiguration.usesAspectFit {
            HStack(spacing: 10) {
              Label("Crop", systemImage: "crop")
                .font(.caption.weight(.medium))
              Slider(
                value: Binding(
                  get: { cropZoom },
                  set: { selectCropZoom($0) }
                ),
                in: 1...4
              )
              Text("\(cropZoom, specifier: "%.1f")×")
                .font(.caption.monospacedDigit())
                .frame(width: 34, alignment: .trailing)
            }
            .tint(.yellow)

            Text("Drag the yellow crop shape to reposition it, or use the slider to resize it.")
              .font(.caption)
              .foregroundStyle(.white.opacity(0.78))
          } else {
            Text("This layout uses the complete photo without cropping.")
              .font(.caption)
              .foregroundStyle(.white.opacity(0.78))
          }

          Text("\(photo.pixelWidth) × \(photo.pixelHeight) px · Original resolution")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.82))
      }
    }
    .preferredColorScheme(.dark)
    .interactiveDismissDisabled(true)
    .task(id: photo.id) {
      image = await loadOriginal()
      didFailToLoad = image == nil
    }
  }

  private func selectFocus(_ point: CGPoint) {
    focusPoint = point
    onSelectFocus(point)
  }

  private func selectCropZoom(_ zoom: Double) {
    cropZoom = min(4, max(1, zoom))
    onAdjustCropZoom(cropZoom)
  }
}

struct CollagePhotoCropConfiguration {
  let destinationAspectRatio: CGFloat
  let cornerRadiusFraction: CGFloat
  var normalizedClipPolygon: [CGPoint]? = nil
  let usesAspectFit: Bool
}

private struct ZoomableImageViewer: View {
  let image: UIImage
  let maximumScale: CGFloat
  let accessibilityTitle: String
  var focusArea: PhotoFocusArea? = nil
  var focusPoint: CGPoint? = nil
  var showsFocusGuides = false
  var cropConfiguration: CollagePhotoCropConfiguration?
  var collageCropZoom: Double = 1
  var onSelectFocus: ((CGPoint) -> Void)?

  @State private var scale: CGFloat = 1
  @State private var settledScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var settledOffset: CGSize = .zero
  @State private var cropDragStart: CGPoint?
  @State private var isAdjustingCrop = false
  @State private var isMagnifying = false

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color.black
        ZStack {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: proxy.size.width, height: proxy.size.height)

          if showsFocusGuides {
            focusGuides(in: proxy.size)
          }

          if cropConfiguration != nil {
            collageCropGuide(in: proxy.size)
          }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .scaleEffect(scale)
        .offset(offset)
      }
      .clipped()
      .coordinateSpace(name: "original-photo-viewer")
      .contentShape(Rectangle())
      .gesture(dragGesture(in: proxy.size))
      .simultaneousGesture(magnificationGesture(in: proxy.size))
      .simultaneousGesture(
        doubleTapGesture(in: proxy.size).exclusively(
          before: focusSelectionGesture(in: proxy.size)
        )
      )
      .overlay(alignment: .bottom) {
        HStack(spacing: 18) {
          Button {
            setScale(scale / 1.5, in: proxy.size)
          } label: {
            Image(systemName: "minus.magnifyingglass")
          }
          .accessibilityLabel("Zoom Out")
          Text("\(Int((scale * 100).rounded()))%")
            .font(.caption.monospacedDigit())
            .frame(minWidth: 44)
          Button {
            setScale(scale * 1.5, in: proxy.size)
          } label: {
            Image(systemName: "plus.magnifyingglass")
          }
          .accessibilityLabel("Zoom In")
          Button("Reset", systemImage: "arrow.counterclockwise", action: resetView)
            .labelStyle(.iconOnly)
            .accessibilityLabel("Reset Zoom and Position")
          if onSelectFocus != nil {
            Button {
              selectFocus(
                at: CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2), in: proxy.size)
            } label: {
              Image(systemName: "scope")
            }
            .accessibilityLabel("Use View Center as Collage Focus")
          }
        }
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.68), in: Capsule())
        .padding(.bottom, 12)
      }
      .accessibilityLabel(accessibilityTitle)
      .accessibilityHint(
        onSelectFocus == nil
          ? "Pinch to zoom and drag to move the preview. Double tap to zoom or reset."
          : "Drag the crop shape or tap a point to reposition the collage crop. Pinch to zoom the viewer, or double tap to zoom and reset."
      )
    }
  }

  @ViewBuilder
  private func collageCropGuide(in viewportSize: CGSize) -> some View {
    if let cropConfiguration, let focusPoint {
      let imageRect = fittedImageRect(in: viewportSize)
      let inverseScale = 1 / max(scale, 0.001)
      let normalizedCrop =
        cropConfiguration.usesAspectFit
        ? CGRect(x: 0, y: 0, width: 1, height: 1)
        : PhotoCropGeometry.normalizedCropRect(
          sourceAspectRatio: image.size.width / max(image.size.height, 1),
          destinationAspectRatio: cropConfiguration.destinationAspectRatio,
          focalPoint: focusPoint,
          zoom: CGFloat(collageCropZoom)
        )
      let cropSize = CGSize(
        width: normalizedCrop.width * imageRect.width,
        height: normalizedCrop.height * imageRect.height
      )

      LayoutFrameShape(
        cornerRadiusFraction: cropConfiguration.cornerRadiusFraction,
        normalizedClipPolygon: cropConfiguration.normalizedClipPolygon
      )
      .fill(.yellow.opacity(0.08))
      .overlay {
        LayoutFrameShape(
          cornerRadiusFraction: cropConfiguration.cornerRadiusFraction,
          normalizedClipPolygon: cropConfiguration.normalizedClipPolygon
        )
        .stroke(.yellow, style: StrokeStyle(lineWidth: 3 * inverseScale, dash: [8, 4]))
      }
      .overlay(alignment: .topLeading) {
        Text("COLLAGE CROP")
          .font(.system(size: 10 * inverseScale, weight: .bold))
          .foregroundStyle(.black)
          .padding(.horizontal, 5 * inverseScale)
          .padding(.vertical, 3 * inverseScale)
          .background(.yellow, in: Capsule())
          .padding(5 * inverseScale)
      }
      .frame(width: cropSize.width, height: cropSize.height)
      .contentShape(Rectangle())
      .position(
        x: imageRect.minX + normalizedCrop.midX * imageRect.width,
        y: imageRect.minY + normalizedCrop.midY * imageRect.height
      )
      .highPriorityGesture(
        cropDragGesture(
          normalizedCrop: normalizedCrop,
          imageRect: imageRect
        )
      )
      .allowsHitTesting(!cropConfiguration.usesAspectFit)
      .accessibilityLabel("Area used in the collage")
      .accessibilityHint("Drag to reposition this crop area")
    }
  }

  @ViewBuilder
  private func focusGuides(in viewportSize: CGSize) -> some View {
    let imageRect = fittedImageRect(in: viewportSize)
    let inverseScale = 1 / max(scale, 0.001)

    if let focusArea {
      let area = focusArea.rect
      Rectangle()
        .fill(.red.opacity(0.22))
        .overlay {
          Rectangle().stroke(.red, lineWidth: 2 * inverseScale)
        }
        .frame(
          width: max(2 * inverseScale, area.width * imageRect.width),
          height: max(2 * inverseScale, area.height * imageRect.height)
        )
        .position(
          x: imageRect.minX + area.midX * imageRect.width,
          y: imageRect.minY + area.midY * imageRect.height
        )
    }

    if let focusPoint {
      ZStack {
        Circle()
          .fill(.indigo.opacity(0.45))
          .overlay {
            Circle().stroke(.white, lineWidth: 2 * inverseScale)
          }
        Circle()
          .fill(.white)
          .frame(width: 5 * inverseScale, height: 5 * inverseScale)
      }
      .frame(width: 28 * inverseScale, height: 28 * inverseScale)
      .position(
        x: imageRect.minX + focusPoint.x * imageRect.width,
        y: imageRect.minY + focusPoint.y * imageRect.height
      )
    }
  }

  private func doubleTapGesture(in viewportSize: CGSize) -> some Gesture {
    SpatialTapGesture(count: 2)
      .onEnded { value in
        if scale > 1.01 {
          resetView()
        } else {
          setScale(2, around: value.location, in: viewportSize)
        }
      }
  }

  private func focusSelectionGesture(in viewportSize: CGSize) -> some Gesture {
    SpatialTapGesture()
      .onEnded { value in
        selectFocus(at: value.location, in: viewportSize)
      }
  }

  private func dragGesture(in viewportSize: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        guard !isAdjustingCrop, !isMagnifying, scale > 1.01 else { return }
        let proposedOffset = CGSize(
          width: settledOffset.width + value.translation.width,
          height: settledOffset.height + value.translation.height
        )
        offset = constrainedOffset(proposedOffset, at: scale, in: viewportSize)
      }
      .onEnded { _ in
        offset = constrainedOffset(offset, at: scale, in: viewportSize)
        settledOffset = offset
      }
  }

  private func cropDragGesture(normalizedCrop: CGRect, imageRect: CGRect) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named("original-photo-viewer"))
      .onChanged { value in
        guard let onSelectFocus else { return }
        isAdjustingCrop = true
        if cropDragStart == nil {
          cropDragStart = CGPoint(x: normalizedCrop.midX, y: normalizedCrop.midY)
        }
        guard let cropDragStart else { return }
        let point = CGPoint(
          x: min(
            1,
            max(0, cropDragStart.x + value.translation.width / max(imageRect.width * scale, 1))
          ),
          y: min(
            1,
            max(0, cropDragStart.y + value.translation.height / max(imageRect.height * scale, 1))
          )
        )
        onSelectFocus(point)
      }
      .onEnded { _ in
        cropDragStart = nil
        isAdjustingCrop = false
      }
  }

  private func magnificationGesture(in viewportSize: CGSize) -> some Gesture {
    MagnifyGesture()
      .onChanged { value in
        isMagnifying = true
        let newScale = min(maximumScale, max(1, settledScale * value.magnification))
        let proposedOffset = offsetKeepingAnchorFixed(
          value.startLocation,
          fromScale: settledScale,
          toScale: newScale,
          startingOffset: settledOffset,
          viewportSize: viewportSize
        )
        scale = newScale
        offset = constrainedOffset(proposedOffset, at: newScale, in: viewportSize)
      }
      .onEnded { _ in
        isMagnifying = false
        settledScale = scale
        if scale <= 1.01 {
          resetView()
        } else {
          offset = constrainedOffset(offset, at: scale, in: viewportSize)
          settledOffset = offset
        }
      }
  }

  private func setScale(
    _ requestedScale: CGFloat,
    around anchor: CGPoint? = nil,
    in viewportSize: CGSize
  ) {
    let newScale = min(maximumScale, max(1, requestedScale))
    let zoomAnchor = anchor ?? CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    let proposedOffset = offsetKeepingAnchorFixed(
      zoomAnchor,
      fromScale: scale,
      toScale: newScale,
      startingOffset: offset,
      viewportSize: viewportSize
    )
    let newOffset = constrainedOffset(proposedOffset, at: newScale, in: viewportSize)
    withAnimation(.easeInOut(duration: 0.2)) {
      scale = newScale
      settledScale = newScale
      offset = newOffset
      settledOffset = newOffset
    }
  }

  private func offsetKeepingAnchorFixed(
    _ anchor: CGPoint,
    fromScale: CGFloat,
    toScale: CGFloat,
    startingOffset: CGSize,
    viewportSize: CGSize
  ) -> CGSize {
    let center = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    let ratio = toScale / max(fromScale, 0.001)
    return CGSize(
      width: anchor.x - center.x - (anchor.x - center.x - startingOffset.width) * ratio,
      height: anchor.y - center.y - (anchor.y - center.y - startingOffset.height) * ratio
    )
  }

  private func constrainedOffset(
    _ proposedOffset: CGSize,
    at scale: CGFloat,
    in viewportSize: CGSize
  ) -> CGSize {
    let imageRect = fittedImageRect(in: viewportSize)
    let maximumX = max(0, (imageRect.width * scale - viewportSize.width) / 2)
    let maximumY = max(0, (imageRect.height * scale - viewportSize.height) / 2)
    return CGSize(
      width: min(maximumX, max(-maximumX, proposedOffset.width)),
      height: min(maximumY, max(-maximumY, proposedOffset.height))
    )
  }

  private func resetView() {
    withAnimation(.easeInOut(duration: 0.2)) {
      scale = 1
      settledScale = 1
      offset = .zero
      settledOffset = .zero
    }
  }

  private func selectFocus(at location: CGPoint, in viewportSize: CGSize) {
    guard let onSelectFocus,
      let point = normalizedImagePoint(at: location, in: viewportSize)
    else { return }
    onSelectFocus(point)
  }

  private func normalizedImagePoint(at location: CGPoint, in viewportSize: CGSize) -> CGPoint? {
    let imageRect = fittedImageRect(in: viewportSize)
    let viewportCenter = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    let untransformedPoint = CGPoint(
      x: viewportCenter.x + (location.x - offset.width - viewportCenter.x) / max(scale, 0.001),
      y: viewportCenter.y + (location.y - offset.height - viewportCenter.y) / max(scale, 0.001)
    )
    guard imageRect.contains(untransformedPoint) else { return nil }
    return CGPoint(
      x: min(1, max(0, (untransformedPoint.x - imageRect.minX) / max(imageRect.width, 1))),
      y: min(1, max(0, (untransformedPoint.y - imageRect.minY) / max(imageRect.height, 1)))
    )
  }

  private func fittedImageRect(in viewportSize: CGSize) -> CGRect {
    let imageSize = image.size
    let fitScale = min(
      viewportSize.width / max(imageSize.width, 1),
      viewportSize.height / max(imageSize.height, 1)
    )
    let displayedSize = CGSize(
      width: imageSize.width * fitScale,
      height: imageSize.height * fitScale
    )
    return CGRect(
      x: (viewportSize.width - displayedSize.width) / 2,
      y: (viewportSize.height - displayedSize.height) / 2,
      width: displayedSize.width,
      height: displayedSize.height
    )
  }
}
