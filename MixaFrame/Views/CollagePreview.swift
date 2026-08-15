import SwiftUI
import UIKit

struct CollagePreview: View {
  let task: CollageTask
  let imageLoader: (CollagePhoto) -> UIImage?
  let onViewPhoto: (UUID) -> Void
  let onMovePhoto: (UUID, UUID) -> Void
  let onAdjustCrop: (UUID, CGPoint) -> Void
  let onAdjustZoom: (UUID, Double) -> Void

  var showsLayoutDividers = false
  var onAdjustLayoutDivider: (LayoutDivider, Double) -> Void = { _, _ in }
  var maximumHeight: CGFloat = 480

  @State private var isManipulatingPhoto = false

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
      } else if LayoutEngine.isNaturalVerticalStrip(task) {
        GeometryReader { proxy in
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
              onManipulationChanged: { isManipulatingPhoto = $0 },
              showsLayoutDividers: showsLayoutDividers,
              onAdjustLayoutDivider: onAdjustLayoutDivider
            )
            .frame(width: width, height: height)
          }
          .scrollDisabled(isManipulatingPhoto)
          .clipped()
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
            onManipulationChanged: { isManipulatingPhoto = $0 },
            showsLayoutDividers: showsLayoutDividers,
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
      if task.outputFormat == .jpeg {
        Color.white
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
  let onManipulationChanged: (Bool) -> Void
  let showsLayoutDividers: Bool
  let onAdjustLayoutDivider: (LayoutDivider, Double) -> Void

  @State private var swapTargetPhotoID: UUID?
  @State private var swapDragPreview: PhotoSwapDragState?

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
            onViewPhoto: { onViewPhoto(photo.id) },
            onSwapDragChanged: { location in
              swapDragPreview = PhotoSwapDragState(photoID: photo.id, location: location)
              swapTargetPhotoID = swapTarget(
                at: location,
                excluding: photo.id,
                frames: sourceFrames,
                scaleX: scaleX,
                scaleY: scaleY
              )
            },
            onSwapDragEnded: {
              let targetPhotoID = swapTargetPhotoID
              swapTargetPhotoID = nil
              swapDragPreview = nil
              if let targetPhotoID {
                onMovePhoto(photo.id, targetPhotoID)
              }
            },
            onAdjustCrop: { onAdjustCrop(photo.id, $0) },
            onAdjustZoom: { onAdjustZoom(photo.id, $0) },
            onManipulationChanged: onManipulationChanged
          )
          .frame(width: frame.width, height: frame.height)
          .rotationEffect(.degrees(sourceLayoutFrame.rotationDegrees))
          .offset(x: frame.minX, y: frame.minY)
          .zIndex(Double(sourceLayoutFrame.zIndex))
        }
      }

      if showsLayoutDividers {
        ForEach(LayoutEngine.layoutDividers(for: task, in: outputSize)) { divider in
          let displayDivider = LayoutDivider(
            axis: divider.axis,
            rowIndex: divider.rowIndex,
            dividerIndex: divider.dividerIndex,
            start: CGPoint(x: divider.start.x * scaleX, y: divider.start.y * scaleY),
            end: CGPoint(x: divider.end.x * scaleX, y: divider.end.y * scaleY)
          )
          LayoutDividerHandle(divider: displayDivider) { delta in
            let dimension =
              displayDivider.axis == .horizontal ? displaySize.height : displaySize.width
            onAdjustLayoutDivider(divider, Double(delta / max(dimension, 1)))
          }
          .frame(width: displaySize.width, height: displaySize.height)
          .zIndex(9_000)
        }
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
      if task.outputFormat == .jpeg {
        Color.white
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
  let onMove: (CGFloat) -> Void

  @State private var lastDragLocation: CGPoint?

  var body: some View {
    ZStack {
      dividerPath
        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 5, lineCap: .round))
      dividerPath
        .stroke(.indigo, style: StrokeStyle(lineWidth: 2, lineCap: .round))
      dividerPath
        .stroke(Color.black.opacity(0.001), style: StrokeStyle(lineWidth: 30, lineCap: .round))
        .gesture(dragGesture)

      Image(systemName: divider.axis == .horizontal ? "arrow.up.and.down" : "arrow.left.and.right")
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .frame(width: 32, height: 32)
        .background(.indigo, in: Circle())
        .overlay { Circle().stroke(.white, lineWidth: 2) }
        .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
        .position(divider.midpoint)
        .gesture(dragGesture)
    }
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
          self.lastDragLocation = value.location
          return
        }
        let delta =
          divider.axis == .horizontal
          ? value.location.y - lastDragLocation.y : value.location.x - lastDragLocation.x
        self.lastDragLocation = value.location
        onMove(delta)
      }
      .onEnded { _ in lastDragLocation = nil }
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
  let onViewPhoto: () -> Void
  let onSwapDragChanged: (CGPoint) -> Void
  let onSwapDragEnded: () -> Void
  let onAdjustCrop: (CGPoint) -> Void
  let onAdjustZoom: (Double) -> Void
  let onManipulationChanged: (Bool) -> Void

  @State private var dragStart: CGPoint?
  @State private var touchBeganAt: Date?
  @State private var dragMode: PhotoDragMode?
  @State private var zoomStart: Double?
  @State private var isManipulating = false

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
      if isManipulating && !isDropTarget {
        LayoutFrameShape(
          cornerRadiusFraction: cornerRadiusFraction,
          normalizedClipPolygon: normalizedClipPolygon
        )
        .stroke(.white.opacity(0.9), lineWidth: 2)
      }
    }
    .overlay {
      if isDropTarget {
        LayoutFrameShape(
          cornerRadiusFraction: cornerRadiusFraction,
          normalizedClipPolygon: normalizedClipPolygon
        )
        .fill(.indigo.opacity(0.18))
        .stroke(.indigo, lineWidth: 4)
      }
    }
    .overlay(alignment: .topTrailing) {
      if isDropTarget {
        Image(systemName: "arrow.left.arrow.right.circle.fill")
          .font(.system(size: 26, weight: .semibold))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .indigo)
          .padding(7)
          .transition(.scale.combined(with: .opacity))
      }
    }
    .scaleEffect(isDropTarget ? 0.97 : 1)
    .animation(.easeOut(duration: 0.14), value: isDropTarget)
    .contentShape(Rectangle())
    .onTapGesture(count: 2, perform: onViewPhoto)
    .simultaneousGesture(photoDragGesture)
    .simultaneousGesture(zoomGesture)
    .accessibilityHint(
      usesAspectFit
        ? "Double tap to view the original photo. Touch and hold, then drag to swap."
        : "Double tap to view the original photo. Hold briefly, then drag to reposition; pinch to zoom; or hold longer to swap."
    )
  }

  private var photoDragGesture: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named("collageCanvas"))
      .onChanged { value in
        if touchBeganAt == nil {
          touchBeganAt = Date()
          dragStart = CGPoint(x: photo.focalX, y: photo.focalY)
        }
        guard zoomStart == nil else { return }
        let travel = hypot(value.translation.width, value.translation.height)
        guard travel >= 3 else { return }

        if dragMode == nil {
          let heldDuration = Date().timeIntervalSince(touchBeganAt ?? Date())
          if usesAspectFit || heldDuration >= 0.72 {
            guard heldDuration >= 0.72 else { return }
            dragMode = .swap
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
          } else {
            guard heldDuration >= 0.12 else { return }
            dragMode = .crop
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
          }
          isManipulating = true
          onManipulationChanged(true)
        }

        switch dragMode {
        case .crop:
          guard let dragStart else { return }
          let imageWidth = max(CGFloat(photo.pixelWidth), 1)
          let imageHeight = max(CGFloat(photo.pixelHeight), 1)
          let zoom = max(CGFloat(photo.effectiveZoom), 1)
          let scale =
            max(frameSize.width / imageWidth, frameSize.height / imageHeight) * zoom
          let scaledWidth = max(imageWidth * scale, 1)
          let scaledHeight = max(imageHeight * scale, 1)
          let x = dragStart.x - value.translation.width / scaledWidth
          let y = dragStart.y - value.translation.height / scaledHeight
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
        case .swap:
          onSwapDragChanged(value.location)
        case nil:
          break
        }
      }
      .onEnded { _ in
        if dragMode == .swap {
          onSwapDragEnded()
        }
        dragStart = nil
        touchBeganAt = nil
        dragMode = nil
        isManipulating = false
        onManipulationChanged(false)
      }
  }

  private var zoomGesture: some Gesture {
    MagnificationGesture()
      .onChanged { value in
        guard !usesAspectFit else { return }
        if zoomStart == nil {
          zoomStart = photo.effectiveZoom
          isManipulating = true
          onManipulationChanged(true)
        }
        guard let zoomStart else { return }
        onAdjustZoom(min(4, max(1, zoomStart * value)))
      }
      .onEnded { _ in
        zoomStart = nil
        isManipulating = false
        onManipulationChanged(false)
      }
  }
}

private enum PhotoDragMode {
  case crop
  case swap
}

private struct PhotoSwapDragState {
  let photoID: UUID
  let location: CGPoint
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
