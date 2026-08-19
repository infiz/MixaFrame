import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CollagePreview: View {
  let task: CollageTask
  let imageLoader: (CollagePhoto) -> UIImage?
  let onViewPhoto: (UUID) -> Void
  let onMovePhoto: (UUID, UUID) -> Void
  let onAdjustCrop: (UUID, CGPoint) -> Void
  let onAdjustZoom: (UUID, Double) -> Void

  var onAdjustLayoutDivider: (LayoutDivider, Double) -> Void = { _, _ in }
  var maximumHeight: CGFloat = 480

  private var outputSize: CGSize { LayoutEngine.outputSize(for: task) }

  var body: some View {
    Group {
      if task.photos.isEmpty {
        GeometryReader { proxy in
          let side = min(proxy.size.width, proxy.size.height)
          RoundedRectangle(cornerRadius: 16)
            .fill(.quaternary)
            .frame(width: side, height: side)
            .overlay {
              Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 46))
                .foregroundStyle(.tertiary)
            }
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .frame(height: maximumHeight)
      } else if let flowAxis = LayoutEngine.flowAxis(for: task) {
        GeometryReader { proxy in
          if flowAxis == .vertical {
            ScrollView(.vertical) {
              let width = proxy.size.width
              let height = width * outputSize.height / max(outputSize.width, 1)
              CollageCanvasContent(
                task: task,
                displaySize: CGSize(width: width, height: height),
                imageLoader: imageLoader,
                onViewPhoto: onViewPhoto,
                onMovePhoto: onMovePhoto,
                onAdjustCrop: onAdjustCrop,
                onAdjustZoom: onAdjustZoom,
                onAdjustLayoutDivider: onAdjustLayoutDivider
              )
              .frame(width: width, height: height)
            }
            .clipped()
          } else {
            ScrollView(.horizontal) {
              let height = proxy.size.height
              let width = height * outputSize.width / max(outputSize.height, 1)
              CollageCanvasContent(
                task: task,
                displaySize: CGSize(width: width, height: height),
                imageLoader: imageLoader,
                onViewPhoto: onViewPhoto,
                onMovePhoto: onMovePhoto,
                onAdjustCrop: onAdjustCrop,
                onAdjustZoom: onAdjustZoom,
                onAdjustLayoutDivider: onAdjustLayoutDivider
              )
              .frame(width: width, height: height)
            }
            .clipped()
          }
        }
        .frame(height: maximumHeight)
      } else {
        GeometryReader { proxy in
          let canvasSize = aspectFitSize(content: outputSize, container: proxy.size)
          CollageCanvasContent(
            task: task,
            displaySize: canvasSize,
            imageLoader: imageLoader,
            onViewPhoto: onViewPhoto,
            onMovePhoto: onMovePhoto,
            onAdjustCrop: onAdjustCrop,
            onAdjustZoom: onAdjustZoom,
            onAdjustLayoutDivider: onAdjustLayoutDivider
          )
          .frame(width: canvasSize.width, height: canvasSize.height)
          .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .frame(height: maximumHeight)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: task.layoutID)
    .animation(.easeInOut(duration: 0.2), value: task.canvas)
    .accessibilityLabel("Collage preview with \(task.photos.count) photos")
  }
}

struct CollageTaskThumbnail: View {
  let task: CollageTask
  let persistedImage: UIImage?
  let imageLoader: (CollagePhoto) -> UIImage?

  var body: some View {
    GeometryReader { proxy in
      let outputSize = LayoutEngine.outputSize(for: task)
      let canvasSize = aspectFitSize(content: outputSize, container: proxy.size)

      ZStack {
        Color(uiColor: .tertiarySystemBackground)
        if let persistedImage {
          Image(uiImage: persistedImage)
            .resizable()
            .scaledToFit()
            .frame(width: canvasSize.width, height: canvasSize.height)
        } else {
          PassiveCollageCanvas(task: task, displaySize: canvasSize, imageLoader: imageLoader)
            .frame(width: canvasSize.width, height: canvasSize.height)
        }

        if persistedImage == nil && !task.photos.isEmpty
          && !task.photos.contains(where: { imageLoader($0) != nil })
        {
          ProgressView().controlSize(.mini)
        }
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
    }
    .accessibilityHidden(true)
  }
}

private func aspectFitSize(content: CGSize, container: CGSize) -> CGSize {
  let scale = min(
    container.width / max(content.width, 1),
    container.height / max(content.height, 1)
  )
  return CGSize(width: content.width * scale, height: content.height * scale)
}

private struct PassiveCollageCanvas: View {
  let task: CollageTask
  let displaySize: CGSize
  let imageLoader: (CollagePhoto) -> UIImage?

  var body: some View {
    let outputSize = LayoutEngine.outputSize(for: task)
    let frames = LayoutEngine.layoutFrames(for: task, in: outputSize)
    let scaleX = displaySize.width / max(outputSize.width, 1)
    let scaleY = displaySize.height / max(outputSize.height, 1)

    ZStack(alignment: .topLeading) {
      Color(uiColor: UIColor(hex: task.backgroundHex))
      ForEach(Array(task.photos.enumerated()), id: \.element.id) { index, photo in
        if index < frames.count {
          let layoutFrame = frames[index]
          let sourceFrame = layoutFrame.rect
          let frame = sourceFrame.scaled(x: scaleX, y: scaleY)

          Group {
            if let image = imageLoader(photo) {
              FocalPhotoView(
                image: image,
                focalPoint: CGPoint(x: photo.focalX, y: photo.focalY),
                zoom: CGFloat(photo.effectiveZoom),
                usesAspectFit: layoutFrame.usesAspectFit
              )
            } else {
              Rectangle().fill(.quaternary)
            }
          }
          .frame(width: frame.width, height: frame.height)
          .clipShape(
            LayoutFrameShape(
              cornerRadiusFraction: layoutFrame.cornerRadiusFraction,
              normalizedClipPolygon: layoutFrame.normalizedClipPolygon
            )
          )
          .rotationEffect(.degrees(layoutFrame.rotationDegrees))
          .offset(x: frame.minX, y: frame.minY)
          .zIndex(Double(layoutFrame.zIndex))
        }
      }
    }
    .clipShape(
      LayoutFrameShape(cornerRadiusFraction: CGFloat(task.canvasCornerRadius / 100))
    )
    .background {
      if !task.outputFormat.supportsTransparency {
        Color(uiColor: UIColor(hex: task.backgroundHex))
      }
    }
    .clipped()
  }
}

private struct CollageCanvasContent: View {
  let task: CollageTask
  let displaySize: CGSize
  let imageLoader: (CollagePhoto) -> UIImage?
  let onViewPhoto: (UUID) -> Void
  let onMovePhoto: (UUID, UUID) -> Void
  let onAdjustCrop: (UUID, CGPoint) -> Void
  let onAdjustZoom: (UUID, Double) -> Void
  let onAdjustLayoutDivider: (LayoutDivider, Double) -> Void

  @State private var swapTargetPhotoID: UUID?
  @State private var swapDragPreview: PhotoSwapDragState?
  @State private var isDraggingLayoutDivider = false
  @State private var selectedFlowPhotoID: UUID?

  var body: some View {
    let outputSize = LayoutEngine.outputSize(for: task)
    let sourceFrames = LayoutEngine.layoutFrames(for: task, in: outputSize)
    let scaleX = displaySize.width / max(outputSize.width, 1)
    let scaleY = displaySize.height / max(outputSize.height, 1)

    ZStack(alignment: .topLeading) {
      Color(uiColor: UIColor(hex: task.backgroundHex))
      ForEach(Array(task.photos.enumerated()), id: \.element.id) { index, photo in
        if index < sourceFrames.count {
          let sourceLayoutFrame = sourceFrames[index]
          let sourceFrame = sourceLayoutFrame.rect
          let frame = sourceFrame.scaled(x: scaleX, y: scaleY)
          InteractivePhotoFrame(
            photo: photo,
            image: imageLoader(photo),
            isDropTarget: swapTargetPhotoID == photo.id,
            usesAspectFit: sourceLayoutFrame.usesAspectFit,
            cornerRadiusFraction: sourceLayoutFrame.cornerRadiusFraction,
            normalizedClipPolygon: sourceLayoutFrame.normalizedClipPolygon,
            rotationDegrees: sourceLayoutFrame.rotationDegrees,
            frameSize: frame.size,
            usesFlowDragAndDrop: LayoutEngine.isFlowLayout(task),
            isFlowPhotoSelected: selectedFlowPhotoID == photo.id,
            onViewPhoto: { onViewPhoto(photo.id) },
            onSelectFlowPhoto: {
              selectedFlowPhotoID = selectedFlowPhotoID == photo.id ? nil : photo.id
            },
            onBeginFlowSwap: { selectedFlowPhotoID = photo.id },
            onDropPhoto: { sourceID in
              guard sourceID != photo.id else { return }
              onMovePhoto(sourceID, photo.id)
            },
            onSwapDragChanged: { location in
              guard !isDraggingLayoutDivider else { return }
              let newTargetPhotoID = swapTarget(
                at: location,
                excluding: photo.id,
                frames: sourceFrames,
                scaleX: scaleX,
                scaleY: scaleY
              )
              if newTargetPhotoID != nil, newTargetPhotoID != swapTargetPhotoID {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
              }
              swapTargetPhotoID = newTargetPhotoID
              swapDragPreview =
                newTargetPhotoID == nil
                ? nil : PhotoSwapDragState(photoID: photo.id, location: location)
            },
            onSwapDragEnded: {
              let targetPhotoID = isDraggingLayoutDivider ? nil : swapTargetPhotoID
              swapTargetPhotoID = nil
              swapDragPreview = nil
              if let targetPhotoID {
                onMovePhoto(photo.id, targetPhotoID)
              }
            },
            onAdjustCrop: { focalPoint in
              guard !isDraggingLayoutDivider else { return }
              onAdjustCrop(photo.id, focalPoint)
            },
            onAdjustZoom: { zoom in
              guard !isDraggingLayoutDivider else { return }
              onAdjustZoom(photo.id, zoom)
            }
          )
          .frame(width: frame.width, height: frame.height)
          .rotationEffect(.degrees(sourceLayoutFrame.rotationDegrees))
          .offset(x: frame.minX, y: frame.minY)
          .zIndex(Double(sourceLayoutFrame.zIndex))
        }
      }

      ForEach(LayoutEngine.layoutDividers(for: task, in: outputSize)) { divider in
        let displayDivider = LayoutDivider(
          axis: divider.axis,
          rowIndex: divider.rowIndex,
          dividerIndex: divider.dividerIndex,
          start: CGPoint(x: divider.start.x * scaleX, y: divider.start.y * scaleY),
          end: CGPoint(x: divider.end.x * scaleX, y: divider.end.y * scaleY)
        )
        LayoutDividerHandle(
          divider: displayDivider,
          sourceDivider: divider,
          onMove: { draggedDivider, delta in
            let dimension =
              draggedDivider.axis == .horizontal ? displaySize.height : displaySize.width
            onAdjustLayoutDivider(draggedDivider, Double(delta / max(dimension, 1)))
          },
          onDraggingChanged: { isDragging in
            isDraggingLayoutDivider = isDragging
            if isDragging {
              swapTargetPhotoID = nil
              swapDragPreview = nil
            }
          }
        )
        .frame(width: displaySize.width, height: displaySize.height)
        .zIndex(9_000)
      }

      if let swapDragPreview,
        let sourceIndex = task.photos.firstIndex(where: { $0.id == swapDragPreview.photoID }),
        sourceIndex < sourceFrames.count
      {
        let photo = task.photos[sourceIndex]
        let layoutFrame = sourceFrames[sourceIndex]
        let sourceRect = layoutFrame.rect
        let displayFrameSize = sourceRect.scaled(x: scaleX, y: scaleY).size
        let previewSize = floatingPreviewSize(for: displayFrameSize)

        FloatingSwapPhotoPreview(
          photo: photo,
          image: imageLoader(photo),
          usesAspectFit: layoutFrame.usesAspectFit,
          cornerRadiusFraction: layoutFrame.cornerRadiusFraction,
          normalizedClipPolygon: layoutFrame.normalizedClipPolygon
        )
        .frame(width: previewSize.width, height: previewSize.height)
        .position(
          floatingPreviewPosition(
            for: swapDragPreview.location,
            previewSize: previewSize
          )
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .zIndex(10_000)
        .transition(.scale(scale: 0.88).combined(with: .opacity))
      }
    }
    .clipShape(
      LayoutFrameShape(cornerRadiusFraction: CGFloat(task.canvasCornerRadius / 100))
    )
    .background {
      if !task.outputFormat.supportsTransparency {
        Color(uiColor: UIColor(hex: task.backgroundHex))
      }
    }
    .clipped()
    .coordinateSpace(name: "collageCanvas")
  }

  private func floatingPreviewSize(for sourceSize: CGSize) -> CGSize {
    let longestSide = max(max(sourceSize.width, sourceSize.height), 1)
    let scale = min(1, 128 / longestSide)
    return CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
  }

  private func floatingPreviewPosition(
    for location: CGPoint,
    previewSize: CGSize
  ) -> CGPoint {
    let inset: CGFloat = 5
    let proposedY = location.y - previewSize.height * 0.18
    return CGPoint(
      x: min(
        max(location.x, previewSize.width / 2 + inset),
        displaySize.width - previewSize.width / 2 - inset
      ),
      y: min(
        max(proposedY, previewSize.height / 2 + inset),
        displaySize.height - previewSize.height / 2 - inset
      )
    )
  }

  private func swapTarget(
    at location: CGPoint,
    excluding sourcePhotoID: UUID,
    frames: [LayoutFrame],
    scaleX: CGFloat,
    scaleY: CGFloat
  ) -> UUID? {
    for index in task.photos.indices.reversed() where index < frames.count {
      let candidate = task.photos[index]
      guard candidate.id != sourcePhotoID else { continue }
      let layoutFrame = frames[index]
      let displayRect = layoutFrame.rect.scaled(x: scaleX, y: scaleY)
      if frameContains(location, layoutFrame: layoutFrame, displayRect: displayRect) {
        return candidate.id
      }
    }
    return nil
  }

  private func frameContains(
    _ location: CGPoint,
    layoutFrame: LayoutFrame,
    displayRect: CGRect
  ) -> Bool {
    let angle = layoutFrame.rotationDegrees * .pi / 180
    let center = CGPoint(x: displayRect.midX, y: displayRect.midY)
    let deltaX = location.x - center.x
    let deltaY = location.y - center.y
    let hitLocation = CGPoint(
      x: center.x + deltaX * cos(angle) + deltaY * sin(angle),
      y: center.y - deltaX * sin(angle) + deltaY * cos(angle)
    )

    if let polygon = layoutFrame.normalizedClipPolygon, polygon.count >= 3 {
      let path = UIBezierPath()
      for (index, point) in polygon.enumerated() {
        let resolvedPoint = CGPoint(
          x: displayRect.minX + point.x * displayRect.width,
          y: displayRect.minY + point.y * displayRect.height
        )
        if index == 0 {
          path.move(to: resolvedPoint)
        } else {
          path.addLine(to: resolvedPoint)
        }
      }
      path.close()
      return path.contains(hitLocation)
    }
    if layoutFrame.cornerRadiusFraction >= 0.49 {
      return UIBezierPath(ovalIn: displayRect).contains(hitLocation)
    }
    let radius = min(displayRect.width, displayRect.height) * layoutFrame.cornerRadiusFraction
    return UIBezierPath(roundedRect: displayRect, cornerRadius: radius).contains(hitLocation)
  }
}

private struct LayoutDividerHandle: View {
  let divider: LayoutDivider
  let sourceDivider: LayoutDivider
  let onMove: (LayoutDivider, CGFloat) -> Void
  let onDraggingChanged: (Bool) -> Void

  @State private var draggedDivider: LayoutDivider?
  @State private var lastDragLocation: CGPoint?

  var body: some View {
    dividerPath
      .stroke(Color.black.opacity(0.001), style: StrokeStyle(lineWidth: 30, lineCap: .round))
      .gesture(dragGesture)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        divider.axis == .horizontal ? "Resize adjacent rows" : "Resize adjacent columns"
      )
      .accessibilityHint("Drag to change the neighboring photo frame sizes")
  }

  private var dividerPath: Path {
    var path = Path()
    path.move(to: divider.start)
    path.addLine(to: divider.end)
    return path
  }

  private var dragGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named("collageCanvas"))
      .onChanged { value in
        guard let lastDragLocation else {
          draggedDivider = sourceDivider
          self.lastDragLocation = value.location
          onDraggingChanged(true)
          return
        }
        let delta =
          divider.axis == .horizontal
          ? value.location.y - lastDragLocation.y : value.location.x - lastDragLocation.x
        self.lastDragLocation = value.location
        if let draggedDivider {
          onMove(draggedDivider, delta)
        }
      }
      .onEnded { _ in
        draggedDivider = nil
        lastDragLocation = nil
        onDraggingChanged(false)
      }
  }
}

private struct InteractivePhotoFrame: View {
  let photo: CollagePhoto
  let image: UIImage?
  let isDropTarget: Bool
  let usesAspectFit: Bool
  let cornerRadiusFraction: CGFloat
  let normalizedClipPolygon: [CGPoint]?
  let rotationDegrees: CGFloat
  let frameSize: CGSize
  let usesFlowDragAndDrop: Bool
  let isFlowPhotoSelected: Bool
  let onViewPhoto: () -> Void
  let onSelectFlowPhoto: () -> Void
  let onBeginFlowSwap: () -> Void
  let onDropPhoto: (UUID) -> Void
  let onSwapDragChanged: (CGPoint) -> Void
  let onSwapDragEnded: () -> Void
  let onAdjustCrop: (CGPoint) -> Void
  let onAdjustZoom: (Double) -> Void

  @State private var dragStart: CGPoint?
  @State private var zoomStart: Double?
  @State private var isManipulating = false
  @State private var isFlowDropTarget = false

  @ViewBuilder
  var body: some View {
    let content = FocalPhotoView(
      image: image,
      focalPoint: CGPoint(x: photo.focalX, y: photo.focalY),
      zoom: CGFloat(photo.effectiveZoom),
      usesAspectFit: usesAspectFit
    )
    .clipShape(
      LayoutFrameShape(
        cornerRadiusFraction: cornerRadiusFraction,
        normalizedClipPolygon: normalizedClipPolygon
      )
    )
    .overlay {
      if isManipulating && !showsDropTarget {
        LayoutFrameShape(
          cornerRadiusFraction: cornerRadiusFraction,
          normalizedClipPolygon: normalizedClipPolygon
        )
        .stroke(.white.opacity(0.9), lineWidth: 2)
      }
    }
    .overlay {
      if isFlowPhotoSelected && !showsDropTarget {
        LayoutFrameShape(
          cornerRadiusFraction: cornerRadiusFraction,
          normalizedClipPolygon: normalizedClipPolygon
        )
        .stroke(.indigo, lineWidth: 3)
      }
    }
    .overlay {
      if showsDropTarget {
        LayoutFrameShape(
          cornerRadiusFraction: cornerRadiusFraction,
          normalizedClipPolygon: normalizedClipPolygon
        )
        .fill(.indigo.opacity(0.18))
        .stroke(.indigo, lineWidth: 4)
      }
    }
    .overlay(alignment: .topTrailing) {
      if showsDropTarget {
        Image(systemName: "arrow.left.arrow.right.circle.fill")
          .font(.system(size: 26, weight: .semibold))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .indigo)
          .padding(7)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .scaleEffect(showsDropTarget ? 0.97 : 1)
    .animation(.easeOut(duration: 0.14), value: showsDropTarget)
    .contentShape(Rectangle())
    .accessibilityHint(
      usesFlowDragAndDrop
        ? isFlowPhotoSelected
          ? "Selected for editing. Double tap to view the original, pinch to zoom, drag with two fingers to reposition, swipe with one finger to scroll, or touch and hold to swap."
          : "Tap to select, double tap to view the original, swipe to scroll, or touch and hold to swap."
        : usesAspectFit
          ? "Double tap to view the original photo. Drag onto another photo to swap."
          : "Double tap to view the original photo. Drag to reposition, move onto another photo to swap, or pinch to zoom."
    )

    if usesFlowDragAndDrop {
      Group {
        if isFlowPhotoSelected {
          content.overlay {
            FlowPhotoEditingGestureOverlay(
              onSingleTap: {
                onSelectFlowPhoto()
                UISelectionFeedbackGenerator().selectionChanged()
              },
              onDoubleTap: onViewPhoto,
              onPinchChanged: updateZoom,
              onPinchEnded: finishZoom,
              onPanChanged: updateFlowPosition,
              onPanEnded: finishFlowPosition
            )
          }
        } else {
          content
            .onTapGesture(count: 2, perform: onViewPhoto)
            .onTapGesture {
              onSelectFlowPhoto()
              UISelectionFeedbackGenerator().selectionChanged()
            }
        }
      }
      .onDrag {
        onBeginFlowSwap()
        return NSItemProvider(object: photo.id.uuidString as NSString)
      } preview: {
        FlowSwapPhotoPreview(
          photo: photo,
          image: image,
          usesAspectFit: usesAspectFit,
          cornerRadiusFraction: cornerRadiusFraction,
          normalizedClipPolygon: normalizedClipPolygon
        )
        .frame(width: frameSize.width, height: frameSize.height)
      }
      .onDrop(
        of: [UTType.plainText],
        delegate: FlowPhotoDropDelegate(
          targetPhotoID: photo.id,
          isTargeted: $isFlowDropTarget,
          onDropPhoto: onDropPhoto
        )
      )
    } else {
      content
        .onTapGesture(count: 2, perform: onViewPhoto)
        .simultaneousGesture(photoDragGesture)
        .simultaneousGesture(zoomGesture)
    }
  }

  private var showsDropTarget: Bool {
    isDropTarget || isFlowDropTarget
  }

  private var photoDragGesture: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named("collageCanvas"))
      .onChanged { value in
        guard zoomStart == nil else { return }
        if dragStart == nil {
          dragStart = CGPoint(x: photo.focalX, y: photo.focalY)
          isManipulating = true
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }

        onSwapDragChanged(value.location)

        updateCrop(translation: value.translation)
      }
      .onEnded { _ in
        onSwapDragEnded()
        dragStart = nil
        isManipulating = false
      }
  }

  private func updateFlowPosition(_ translation: CGSize) {
    guard photo.effectiveZoom > 1.000_1, zoomStart == nil else { return }
    if dragStart == nil {
      dragStart = CGPoint(x: photo.focalX, y: photo.focalY)
      isManipulating = true
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    updateCrop(translation: translation)
  }

  private func finishFlowPosition() {
    dragStart = nil
    isManipulating = false
  }

  private func updateCrop(translation: CGSize) {
    guard !usesAspectFit, let dragStart else { return }
    let imageWidth = max(CGFloat(photo.pixelWidth), 1)
    let imageHeight = max(CGFloat(photo.pixelHeight), 1)
    let zoom = max(CGFloat(photo.effectiveZoom), 1)
    let scale = max(frameSize.width / imageWidth, frameSize.height / imageHeight) * zoom
    let scaledWidth = max(imageWidth * scale, 1)
    let scaledHeight = max(imageHeight * scale, 1)
    let x = dragStart.x - translation.width / scaledWidth
    let y = dragStart.y - translation.height / scaledHeight
    let focalPoint = PhotoCropGeometry.clampedFocalPoint(
      sourceAspectRatio: imageWidth / imageHeight,
      destinationAspectRatio: frameSize.width / max(frameSize.height, 1),
      focalPoint: CGPoint(x: x, y: y),
      zoom: zoom
    )
    let currentFocalPoint = CGPoint(x: photo.focalX, y: photo.focalY)
    guard
      hypot(
        focalPoint.x - currentFocalPoint.x,
        focalPoint.y - currentFocalPoint.y
      ) > 0.000_001
    else { return }
    onAdjustCrop(focalPoint)
  }

  private var zoomGesture: some Gesture {
    MagnificationGesture()
      .onChanged(updateZoom)
      .onEnded { _ in finishZoom() }
  }

  private func updateZoom(_ magnification: CGFloat) {
    guard !usesAspectFit else { return }
    if zoomStart == nil {
      zoomStart = photo.effectiveZoom
      isManipulating = true
    }
    guard let zoomStart else { return }
    onAdjustZoom(min(4, max(1, zoomStart * magnification)))
  }

  private func finishZoom() {
    zoomStart = nil
    isManipulating = false
  }
}

private struct FlowPhotoEditingGestureOverlay: UIViewRepresentable {
  let onSingleTap: () -> Void
  let onDoubleTap: () -> Void
  let onPinchChanged: (CGFloat) -> Void
  let onPinchEnded: () -> Void
  let onPanChanged: (CGSize) -> Void
  let onPanEnded: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(owner: self)
  }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .clear
    view.isAccessibilityElement = false

    let doubleTap = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleDoubleTap(_:))
    )
    doubleTap.numberOfTapsRequired = 2
    doubleTap.cancelsTouchesInView = false
    doubleTap.delegate = context.coordinator
    view.addGestureRecognizer(doubleTap)

    let singleTap = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleSingleTap(_:))
    )
    singleTap.numberOfTapsRequired = 1
    singleTap.cancelsTouchesInView = false
    singleTap.delegate = context.coordinator
    singleTap.require(toFail: doubleTap)
    view.addGestureRecognizer(singleTap)

    let pinch = UIPinchGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handlePinch(_:))
    )
    pinch.cancelsTouchesInView = false
    pinch.delegate = context.coordinator
    view.addGestureRecognizer(pinch)

    let pan = UIPanGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handlePan(_:))
    )
    pan.minimumNumberOfTouches = 2
    pan.maximumNumberOfTouches = 2
    pan.cancelsTouchesInView = false
    pan.delegate = context.coordinator
    view.addGestureRecognizer(pan)

    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    context.coordinator.owner = self
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var owner: FlowPhotoEditingGestureOverlay

    init(owner: FlowPhotoEditingGestureOverlay) {
      self.owner = owner
    }

    @objc func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      owner.onSingleTap()
    }

    @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .ended else { return }
      owner.onDoubleTap()
    }

    @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      switch recognizer.state {
      case .began, .changed:
        owner.onPinchChanged(recognizer.scale)
      case .ended, .cancelled, .failed:
        owner.onPinchEnded()
      default:
        break
      }
    }

    @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
      switch recognizer.state {
      case .began, .changed:
        let translation = recognizer.translation(in: recognizer.view)
        owner.onPanChanged(CGSize(width: translation.x, height: translation.y))
      case .ended, .cancelled, .failed:
        owner.onPanEnded()
      default:
        break
      }
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

private struct FlowPhotoDropDelegate: DropDelegate {
  let targetPhotoID: UUID
  @Binding var isTargeted: Bool
  let onDropPhoto: (UUID) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    info.hasItemsConforming(to: [UTType.plainText])
  }

  func dropEntered(info: DropInfo) {
    isTargeted = true
  }

  func dropExited(info: DropInfo) {
    isTargeted = false
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: .move)
  }

  func performDrop(info: DropInfo) -> Bool {
    isTargeted = false
    guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
    provider.loadObject(ofClass: NSString.self) { object, _ in
      guard let rawSourceID = object as? NSString,
        let sourceID = UUID(uuidString: rawSourceID as String),
        sourceID != targetPhotoID
      else { return }
      Task { @MainActor in onDropPhoto(sourceID) }
    }
    return true
  }
}

private struct PhotoSwapDragState {
  let photoID: UUID
  let location: CGPoint
}

private struct FlowSwapPhotoPreview: View {
  let photo: CollagePhoto
  let image: UIImage?
  let usesAspectFit: Bool
  let cornerRadiusFraction: CGFloat
  let normalizedClipPolygon: [CGPoint]?

  var body: some View {
    FocalPhotoView(
      image: image,
      focalPoint: CGPoint(x: photo.focalX, y: photo.focalY),
      zoom: CGFloat(photo.effectiveZoom),
      usesAspectFit: usesAspectFit
    )
    .clipShape(
      LayoutFrameShape(
        cornerRadiusFraction: cornerRadiusFraction,
        normalizedClipPolygon: normalizedClipPolygon
      )
    )
    .overlay(alignment: .topTrailing) {
      Image(systemName: "arrow.left.arrow.right.circle.fill")
        .font(.system(size: 27, weight: .semibold))
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, .indigo)
        .padding(6)
    }
    .shadow(color: .black.opacity(0.32), radius: 9, y: 5)
  }
}

private struct FloatingSwapPhotoPreview: View {
  let photo: CollagePhoto
  let image: UIImage?
  let usesAspectFit: Bool
  let cornerRadiusFraction: CGFloat
  let normalizedClipPolygon: [CGPoint]?

  var body: some View {
    FocalPhotoView(
      image: image,
      focalPoint: CGPoint(x: photo.focalX, y: photo.focalY),
      zoom: CGFloat(photo.effectiveZoom),
      usesAspectFit: usesAspectFit
    )
    .clipShape(
      LayoutFrameShape(
        cornerRadiusFraction: cornerRadiusFraction,
        normalizedClipPolygon: normalizedClipPolygon
      )
    )
    .overlay {
      LayoutFrameShape(
        cornerRadiusFraction: cornerRadiusFraction,
        normalizedClipPolygon: normalizedClipPolygon
      )
      .stroke(.white, lineWidth: 2.5)
    }
    .overlay(alignment: .topTrailing) {
      Image(systemName: "arrow.left.arrow.right.circle.fill")
        .font(.system(size: 27, weight: .semibold))
        .symbolRenderingMode(.palette)
        .foregroundStyle(.white, .indigo)
        .padding(6)
    }
    .shadow(color: .black.opacity(0.32), radius: 9, y: 5)
  }
}

struct LayoutFrameShape: Shape {
  let cornerRadiusFraction: CGFloat
  var normalizedClipPolygon: [CGPoint]? = nil

  func path(in rect: CGRect) -> Path {
    if let normalizedClipPolygon, normalizedClipPolygon.count >= 3 {
      var path = Path()
      for (index, point) in normalizedClipPolygon.enumerated() {
        let resolvedPoint = CGPoint(
          x: rect.minX + point.x * rect.width,
          y: rect.minY + point.y * rect.height
        )
        if index == 0 {
          path.move(to: resolvedPoint)
        } else {
          path.addLine(to: resolvedPoint)
        }
      }
      path.closeSubpath()
      return path
    }
    if cornerRadiusFraction >= 0.49 {
      return Path(ellipseIn: rect)
    }
    let radius = min(rect.width, rect.height) * max(0, cornerRadiusFraction)
    return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
  }
}

private struct FocalPhotoView: View {
  let image: UIImage?
  let focalPoint: CGPoint
  let zoom: CGFloat
  let usesAspectFit: Bool

  var body: some View {
    GeometryReader { proxy in
      if let image {
        if usesAspectFit {
          Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: proxy.size.width, height: proxy.size.height)
        } else {
          let imageSize = image.size
          let scale =
            max(
              proxy.size.width / max(imageSize.width, 1),
              proxy.size.height / max(imageSize.height, 1)
            ) * max(1, zoom)
          let scaledWidth = imageSize.width * scale
          let scaledHeight = imageSize.height * scale
          let x = min(
            0,
            max(proxy.size.width - scaledWidth, proxy.size.width / 2 - focalPoint.x * scaledWidth))
          let y = min(
            0,
            max(
              proxy.size.height - scaledHeight, proxy.size.height / 2 - focalPoint.y * scaledHeight)
          )
          Image(uiImage: image)
            .resizable()
            .frame(width: scaledWidth, height: scaledHeight)
            .offset(x: x, y: y)
        }
      } else {
        Rectangle().fill(.quaternary)
          .overlay {
            VStack(spacing: 6) {
              ProgressView()
              Text("Preparing")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
      }
    }
    .clipped()
  }
}

extension CGRect {
  fileprivate func scaled(x scaleX: CGFloat, y scaleY: CGFloat) -> CGRect {
    CGRect(
      x: minX * scaleX,
      y: minY * scaleY,
      width: width * scaleX,
      height: height * scaleY
    )
  }
}
