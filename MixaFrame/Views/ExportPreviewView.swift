import SwiftUI
import UIKit

struct ExportPreviewView: View {
  let export: PreparedCollageExport
  let formatTitle: String
  let onSave: () async throws -> Void
  let onShare: () async throws -> Void
  let onCancel: () -> Void

  @State private var isSaving = false
  @State private var errorMessage: String?

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
          Text(
            "\(Int(export.outputSize.width)) × \(Int(export.outputSize.height)) px · \(formatTitle)"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          Button {
            saveToPhotos()
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

  private func saveToPhotos() {
    isSaving = true
    Task {
      do {
        try await onSave()
      } catch {
        errorMessage = error.localizedDescription
      }
      isSaving = false
    }
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

struct OriginalPhotoViewer: View {
  let photo: CollagePhoto
  let originalURL: URL
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
    originalURL: URL,
    cropConfiguration: CollagePhotoCropConfiguration,
    onSelectFocus: @escaping (CGPoint) -> Void,
    onAdjustCropZoom: @escaping (Double) -> Void
  ) {
    self.photo = photo
    self.originalURL = originalURL
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
            description: Text("The original photo file could not be loaded.")
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
    .task(id: originalURL) {
      let path = originalURL.path
      image = await Task.detached(priority: .userInitiated) {
        autoreleasepool {
          guard let source = UIImage(contentsOfFile: path) else { return nil }
          return source.preparingForDisplay() ?? source
        }
      }.value
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
      .coordinateSpace(name: "original-photo-viewer")
      .contentShape(Rectangle())
      .gesture(dragGesture)
      .simultaneousGesture(magnificationGesture)
      .simultaneousGesture(
        doubleTapGesture.exclusively(before: focusSelectionGesture(in: proxy.size))
      )
      .overlay(alignment: .bottom) {
        HStack(spacing: 18) {
          Button {
            setScale(scale / 1.5)
          } label: {
            Image(systemName: "minus.magnifyingglass")
          }
          .accessibilityLabel("Zoom Out")
          Text("\(Int((scale * 100).rounded()))%")
            .font(.caption.monospacedDigit())
            .frame(minWidth: 44)
          Button {
            setScale(scale * 1.5)
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

  private var doubleTapGesture: some Gesture {
    SpatialTapGesture(count: 2)
      .onEnded { _ in
        if scale > 1.01 {
          resetView()
        } else {
          setScale(2)
        }
      }
  }

  private func focusSelectionGesture(in viewportSize: CGSize) -> some Gesture {
    SpatialTapGesture()
      .onEnded { value in
        selectFocus(at: value.location, in: viewportSize)
      }
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 2)
      .onChanged { value in
        guard !isAdjustingCrop else { return }
        offset = CGSize(
          width: settledOffset.width + value.translation.width,
          height: settledOffset.height + value.translation.height
        )
      }
      .onEnded { _ in settledOffset = offset }
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

  private var magnificationGesture: some Gesture {
    MagnificationGesture()
      .onChanged { value in scale = min(maximumScale, max(1, settledScale * value)) }
      .onEnded { _ in
        settledScale = scale
        if scale <= 1.01 { resetView() }
      }
  }

  private func setScale(_ newScale: CGFloat) {
    withAnimation(.easeInOut(duration: 0.2)) {
      scale = min(maximumScale, max(1, newScale))
      settledScale = scale
      if scale <= 1.01 {
        offset = .zero
        settledOffset = .zero
      }
    }
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
