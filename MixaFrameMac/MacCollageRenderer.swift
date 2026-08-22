import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import SDWebImageWebPCoder
import UniformTypeIdentifiers

enum MacCollageRenderer {
  static func export(
    project: Project,
    photoDirectory: URL,
    destination: URL,
    includesWatermark: Bool = false
  ) throws {
    guard project.photos.count >= 2 else { throw MacCollageRenderError.notEnoughPhotos }
    let requestedSize = LayoutEngine.outputSize(for: project)
    let outputSize = safeOutputSize(requestedSize)
    let width = max(1, Int(outputSize.width.rounded()))
    let height = max(1, Int(outputSize.height.rounded()))
    guard let context = CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw MacCollageRenderError.renderingFailed }

    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    context.clear(canvas)
    if !project.outputFormat.supportsTransparency {
      context.setFillColor(CGColor.mixaFrame(hex: project.backgroundHex))
      context.fill(canvas)
    }
    context.saveGState()
    context.addPath(
      CGPath(
        roundedRect: canvas,
        cornerWidth: min(canvas.width, canvas.height) * CGFloat(project.canvasCornerRadius / 100),
        cornerHeight: min(canvas.width, canvas.height) * CGFloat(project.canvasCornerRadius / 100),
        transform: nil
      ))
    context.clip()
    context.setFillColor(CGColor.mixaFrame(hex: project.backgroundHex))
    context.fill(canvas)

    let scaleX = outputSize.width / max(requestedSize.width, 1)
    let scaleY = outputSize.height / max(requestedSize.height, 1)
    let frames = LayoutEngine.layoutFrames(for: project, in: requestedSize).map { source in
      var scaled = source
      scaled.rect = CGRect(
        x: source.rect.minX * scaleX,
        y: source.rect.minY * scaleY,
        width: source.rect.width * scaleX,
        height: source.rect.height * scaleY
      )
      return scaled
    }

    for index in project.photos.indices where frames.indices.contains(index) {
      let photo = project.photos[index]
      let frame = frames[index]
      let url = photoDirectory.appendingPathComponent(photo.fileName)
      guard let image = orientedImage(at: url, maximumPixelSize: max(width, height)) else {
        throw MacCollageRenderError.missingPhoto
      }
      draw(photo: photo, image: image, frame: frame, in: context)
    }
    if includesWatermark {
      drawWatermark(in: canvas, context: context)
    }
    context.restoreGState()

    guard let image = context.makeImage() else { throw MacCollageRenderError.renderingFailed }
    if project.outputFormat == .webP {
      let macImage = NSImage(
        cgImage: image,
        size: NSSize(width: image.width, height: image.height)
      )
      guard let data = SDImageWebPCoder.shared.encodedData(
        with: macImage,
        format: .webP,
        options: [.encodeCompressionQuality: project.quality.compressionQuality]
      ) else { throw MacCollageRenderError.encodingUnavailable(project.outputFormat.title) }
      try data.write(to: destination, options: .atomic)
      return
    }
    guard
      let destinationType = destinationType(for: project.outputFormat),
      let writer = CGImageDestinationCreateWithURL(
        destination as CFURL, destinationType as CFString, 1, nil)
    else { throw MacCollageRenderError.encodingUnavailable(project.outputFormat.title) }
    let properties: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: project.quality.compressionQuality
    ]
    CGImageDestinationAddImage(writer, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(writer) else {
      throw MacCollageRenderError.encodingUnavailable(project.outputFormat.title)
    }
  }

  private static func draw(
    photo: CollagePhoto,
    image: CGImage,
    frame: LayoutFrame,
    in context: CGContext
  ) {
    context.saveGState()
    defer { context.restoreGState() }
    if frame.rotationDegrees != 0 {
      context.translateBy(x: frame.rect.midX, y: frame.rect.midY)
      context.rotate(by: frame.rotationDegrees * .pi / 180)
      context.translateBy(x: -frame.rect.midX, y: -frame.rect.midY)
    }
    context.addPath(clippingPath(for: frame))
    context.clip()

    if frame.usesAspectFit {
      let imageRatio = CGFloat(image.width) / max(CGFloat(image.height), 1)
      let frameRatio = frame.rect.width / max(frame.rect.height, 1)
      let size = imageRatio > frameRatio
        ? CGSize(width: frame.rect.width, height: frame.rect.width / imageRatio)
        : CGSize(width: frame.rect.height * imageRatio, height: frame.rect.height)
      let target = CGRect(
        x: frame.rect.midX - size.width / 2,
        y: frame.rect.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
      context.draw(image, in: target)
      return
    }

    let crop = PhotoCropGeometry.normalizedCropRect(
      sourceAspectRatio: photo.aspectRatio,
      destinationAspectRatio: frame.rect.width / max(frame.rect.height, 1),
      focalPoint: CGPoint(x: photo.focalX, y: photo.focalY),
      zoom: CGFloat(photo.effectiveZoom)
    )
    let pixelCrop = CGRect(
      x: crop.minX * CGFloat(image.width),
      y: crop.minY * CGFloat(image.height),
      width: crop.width * CGFloat(image.width),
      height: crop.height * CGFloat(image.height)
    ).integral
    guard let cropped = image.cropping(to: pixelCrop) else { return }
    context.draw(cropped, in: frame.rect)
  }

  private static func clippingPath(for frame: LayoutFrame) -> CGPath {
    if let points = frame.normalizedClipPolygon, points.count >= 3 {
      let path = CGMutablePath()
      for (index, point) in points.enumerated() {
        let resolved = CGPoint(
          x: frame.rect.minX + point.x * frame.rect.width,
          y: frame.rect.minY + point.y * frame.rect.height
        )
        index == 0 ? path.move(to: resolved) : path.addLine(to: resolved)
      }
      path.closeSubpath()
      return path
    }
    if frame.cornerRadiusFraction >= 0.49 {
      return CGPath(ellipseIn: frame.rect, transform: nil)
    }
    let radius = min(frame.rect.width, frame.rect.height) * max(0, frame.cornerRadiusFraction)
    return CGPath(
      roundedRect: frame.rect,
      cornerWidth: radius,
      cornerHeight: radius,
      transform: nil
    )
  }

  private static func orientedImage(at url: URL, maximumPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func safeOutputSize(_ requested: CGSize) -> CGSize {
    let maximumPixels: CGFloat = 70_000_000
    let maximumSide: CGFloat = 32_000
    let pixelScale = sqrt(maximumPixels / max(1, requested.width * requested.height))
    let sideScale = maximumSide / max(requested.width, requested.height, 1)
    let scale = min(1, pixelScale, sideScale)
    return CGSize(
      width: max(1, floor(requested.width * scale)),
      height: max(1, floor(requested.height * scale))
    )
  }

  private static func drawWatermark(in canvasRect: CGRect, context: CGContext) {
    context.saveGState()
    defer { context.restoreGState() }

    let fontSize = max(18, min(canvasRect.width, canvasRect.height) * 0.04)
    let brandFont =
      NSFont(name: "AvenirNext-DemiBold", size: fontSize)
      ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)
    let captionFontSize = max(6, fontSize * 0.3)
    let captionFont = NSFont.systemFont(ofSize: captionFontSize, weight: .bold)
    let brandLine = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: "MixaFrame",
        attributes: [
          .font: brandFont,
          .foregroundColor: NSColor.white,
          .kern: fontSize * 0.018,
        ]
      )
    )
    let captionLine = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: "CREATED WITH",
        attributes: [
          .font: captionFont,
          .foregroundColor: NSColor.white.withAlphaComponent(0.82),
          .kern: captionFontSize * 0.14,
        ]
      )
    )

    var brandAscent: CGFloat = 0
    var brandDescent: CGFloat = 0
    var captionAscent: CGFloat = 0
    var captionDescent: CGFloat = 0
    let brandWidth = CGFloat(
      CTLineGetTypographicBounds(brandLine, &brandAscent, &brandDescent, nil))
    let captionWidth = CGFloat(
      CTLineGetTypographicBounds(captionLine, &captionAscent, &captionDescent, nil))
    let brandHeight = brandAscent + brandDescent
    let captionHeight = captionAscent + captionDescent
    let horizontalPadding = fontSize * 0.78
    let verticalPadding = fontSize * 0.38
    let lineSpacing = fontSize * 0.08
    let margin = max(fontSize * 0.72, min(canvasRect.width, canvasRect.height) * 0.025)
    let contentWidth = max(brandWidth, captionWidth)
    let contentHeight = captionHeight + lineSpacing + brandHeight
    let backgroundSize = CGSize(
      width: contentWidth + horizontalPadding * 2,
      height: contentHeight + verticalPadding * 2
    )
    let backgroundRect = CGRect(
      x: canvasRect.maxX - backgroundSize.width - margin,
      y: canvasRect.minY + margin,
      width: backgroundSize.width,
      height: backgroundSize.height
    )

    context.addPath(
      CGPath(
        roundedRect: backgroundRect,
        cornerWidth: backgroundRect.height / 2,
        cornerHeight: backgroundRect.height / 2,
        transform: nil
      ))
    context.setFillColor(NSColor.black.withAlphaComponent(0.68).cgColor)
    context.fillPath()
    context.addPath(
      CGPath(
        roundedRect: backgroundRect,
        cornerWidth: backgroundRect.height / 2,
        cornerHeight: backgroundRect.height / 2,
        transform: nil
      ))
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    context.setLineWidth(max(1, fontSize * 0.025))
    context.strokePath()

    let contentBottom = backgroundRect.midY - contentHeight / 2
    let brandBaseline = contentBottom + brandDescent
    let captionBaseline = contentBottom + brandHeight + lineSpacing + captionDescent
    context.textPosition = CGPoint(
      x: backgroundRect.midX - brandWidth / 2,
      y: brandBaseline
    )
    context.setShadow(
      offset: CGSize(width: 0, height: -fontSize * 0.06),
      blur: fontSize * 0.12,
      color: NSColor.black.withAlphaComponent(0.45).cgColor
    )
    CTLineDraw(brandLine, context)
    context.setShadow(offset: .zero, blur: 0, color: nil)
    context.textPosition = CGPoint(
      x: backgroundRect.midX - captionWidth / 2,
      y: captionBaseline
    )
    CTLineDraw(captionLine, context)
  }

  private static func destinationType(for format: OutputFormat) -> String? {
    switch format {
    case .jpeg: UTType.jpeg.identifier
    case .png: UTType.png.identifier
    case .heif: UTType.heic.identifier
    case .webP: nil
    }
  }
}

enum MacCollageRenderError: LocalizedError {
  case notEnoughPhotos
  case missingPhoto
  case renderingFailed
  case encodingUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .notEnoughPhotos: "Add at least two photos before exporting."
    case .missingPhoto: "One of this project’s source photos is missing."
    case .renderingFailed: "The project could not be rendered."
    case .encodingUnavailable(let format): "\(format) encoding is not available on this Mac."
    }
  }
}

private extension CGColor {
  static func mixaFrame(hex: String) -> CGColor {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var value: UInt64 = 0xFFFFFF
    Scanner(string: cleaned).scanHexInt64(&value)
    return CGColor(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }
}
