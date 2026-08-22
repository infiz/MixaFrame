import ImageIO
import Photos
import SDWebImageWebPCoder
import UIKit
import UniformTypeIdentifiers

struct PreparedCollageExport: Identifiable {
  let id = UUID()
  let fileURL: URL
  let previewImage: UIImage
  let outputSize: CGSize
  let requestedOutputSize: CGSize
  let includesWatermark: Bool

  var wasScaledForSafety: Bool {
    abs(outputSize.width - requestedOutputSize.width) >= 1
      || abs(outputSize.height - requestedOutputSize.height) >= 1
  }
}

enum CollageRenderer {
  static let maximumPixelCount: CGFloat = 70_000_000
  static let maximumSide: CGFloat = 32_000
  static let previewMaximumPixelCount: CGFloat = 8_000_000
  static let previewMaximumSide: CGFloat = 12_000

  static func exportOutputSize(for project: Project) -> CGSize {
    let requestedSize = LayoutEngine.outputSize(for: project)
    let pixelCount = max(1, requestedSize.width * requestedSize.height)
    let pixelScale = sqrt(maximumPixelCount / pixelCount)
    let sideScale = maximumSide / max(requestedSize.width, requestedSize.height, 1)
    let scale = min(1, pixelScale, sideScale)
    guard scale < 0.999_999 else { return requestedSize }
    return CGSize(
      width: max(1, floor(requestedSize.width * scale)),
      height: max(1, floor(requestedSize.height * scale))
    )
  }

  static func renderThumbnail(
    project: Project,
    images: [UIImage?],
    maximumPixelDimension: CGFloat = 512
  ) -> UIImage? {
    guard !project.photos.isEmpty, images.count == project.photos.count else { return nil }
    let outputSize = LayoutEngine.outputSize(for: project)
    let scale = min(1, maximumPixelDimension / max(outputSize.width, outputSize.height, 1))
    let thumbnailSize = CGSize(
      width: max(1, (outputSize.width * scale).rounded()),
      height: max(1, (outputSize.height * scale).rounded())
    )
    let scaleX = thumbnailSize.width / max(outputSize.width, 1)
    let scaleY = thumbnailSize.height / max(outputSize.height, 1)
    let layoutFrames = LayoutEngine.layoutFrames(for: project, in: outputSize)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    let cgImages = images.map { $0?.normalizedCGImage }

    return UIGraphicsImageRenderer(size: thumbnailSize, format: format).image { context in
      context.cgContext.scaleBy(x: scaleX, y: scaleY)
      draw(
        project: project,
        layoutFrames: layoutFrames,
        images: cgImages,
        canvasRect: CGRect(origin: .zero, size: outputSize),
        context: context,
        includesWatermark: false
      )
    }
  }

  static func render(
    project: Project,
    photoDirectory: URL,
    includesWatermark: Bool = false
  ) throws -> UIImage {
    guard project.photos.count >= 2 else { throw AppError.noPhotos }
    let requestedOutputSize = LayoutEngine.outputSize(for: project)
    let outputSize = exportOutputSize(for: project)

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = !project.outputFormat.supportsTransparency
    let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
    let scaleX = outputSize.width / max(requestedOutputSize.width, 1)
    let scaleY = outputSize.height / max(requestedOutputSize.height, 1)
    let layoutFrames = LayoutEngine.layoutFrames(for: project, in: requestedOutputSize).map { frame in
      var scaledFrame = frame
      scaledFrame.rect = CGRect(
        x: frame.rect.minX * scaleX,
        y: frame.rect.minY * scaleY,
        width: frame.rect.width * scaleX,
        height: frame.rect.height * scaleY
      )
      return scaledFrame
    }
    var renderingError: Error?
    let image = renderer.image { context in
      let canvasRect = CGRect(origin: .zero, size: outputSize)
      prepareCanvas(project: project, canvasRect: canvasRect, context: context)

      for index in project.photos.indices {
        guard renderingError == nil, layoutFrames.indices.contains(index) else { break }
        autoreleasepool {
          do {
            let photo = project.photos[index]
            let layoutFrame = layoutFrames[index]
            let url = photoDirectory.appendingPathComponent(photo.fileName)
            let cgImage = try exportSourceImage(
              for: photo,
              layoutFrame: layoutFrame,
              at: url
            )
            drawPhoto(
              photo: photo,
              layoutFrame: layoutFrame,
              cgImage: cgImage,
              context: context
            )
          } catch {
            renderingError = error
          }
        }
      }

      if renderingError == nil, includesWatermark {
        drawWatermark(in: canvasRect)
      }
      context.cgContext.restoreGState()
    }
    if let renderingError { throw renderingError }
    return image
  }

  private static func draw(
    project: Project,
    layoutFrames: [LayoutFrame],
    images: [CGImage?],
    canvasRect: CGRect,
    context: UIGraphicsImageRendererContext,
    includesWatermark: Bool
  ) {
    prepareCanvas(project: project, canvasRect: canvasRect, context: context)

    for index in project.photos.indices {
      guard layoutFrames.indices.contains(index), images.indices.contains(index),
        let cgImage = images[index]
      else { continue }
      drawPhoto(
        photo: project.photos[index],
        layoutFrame: layoutFrames[index],
        cgImage: cgImage,
        context: context
      )
    }

    if includesWatermark {
      drawWatermark(in: canvasRect)
    }
    context.cgContext.restoreGState()
  }

  private static func prepareCanvas(
    project: Project,
    canvasRect: CGRect,
    context: UIGraphicsImageRendererContext
  ) {
    if !project.outputFormat.supportsTransparency {
      UIColor(hex: project.backgroundHex).setFill()
      context.fill(canvasRect)
    } else {
      context.cgContext.clear(canvasRect)
    }

    context.cgContext.saveGState()
    canvasClippingPath(for: project, in: canvasRect).addClip()
    UIColor(hex: project.backgroundHex).setFill()
    context.fill(canvasRect)
  }

  private static func drawPhoto(
    photo: CollagePhoto,
    layoutFrame: LayoutFrame,
    cgImage: CGImage,
    context: UIGraphicsImageRendererContext
  ) {
    let frame = layoutFrame.rect
    context.cgContext.saveGState()
    defer { context.cgContext.restoreGState() }
    if layoutFrame.rotationDegrees != 0 {
      context.cgContext.translateBy(x: frame.midX, y: frame.midY)
      context.cgContext.rotate(by: layoutFrame.rotationDegrees * .pi / 180)
      context.cgContext.translateBy(x: -frame.midX, y: -frame.midY)
    }
    clippingPath(for: layoutFrame).addClip()
    if layoutFrame.usesAspectFit {
      UIImage(cgImage: cgImage).draw(in: frame)
    } else {
      drawAspectFill(
        cgImage: cgImage,
        in: frame,
        focalPoint: CGPoint(x: photo.focalX, y: photo.focalY),
        zoom: CGFloat(photo.effectiveZoom)
      )
    }
  }

  private static func exportSourceImage(
    for photo: CollagePhoto,
    layoutFrame: LayoutFrame,
    at url: URL
  ) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw AppError.imageMissing
    }

    let maximumPixelSize = requiredSourceMaximumPixelSize(
      for: photo,
      layoutFrame: layoutFrame
    )
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw AppError.invalidImage
    }
    return image
  }

  static func requiredSourceMaximumPixelSize(
    for photo: CollagePhoto,
    layoutFrame: LayoutFrame
  ) -> Int {
    let frame = layoutFrame.rect
    let cropRect =
      layoutFrame.usesAspectFit
      ? CGRect(x: 0, y: 0, width: 1, height: 1)
      : PhotoCropGeometry.normalizedCropRect(
        sourceAspectRatio: photo.aspectRatio,
        destinationAspectRatio: frame.width / max(frame.height, 1),
        focalPoint: CGPoint(x: photo.focalX, y: photo.focalY),
        zoom: CGFloat(photo.effectiveZoom)
      )
    let requiredFullWidth = frame.width / max(cropRect.width, 0.000_1)
    let requiredFullHeight = frame.height / max(cropRect.height, 0.000_1)
    let maximumPixelSize = Int(
      ceil(
        min(
          CGFloat(max(photo.pixelWidth, photo.pixelHeight)),
          max(requiredFullWidth, requiredFullHeight) * 1.05))
    )
    return max(1, maximumPixelSize)
  }

  static func export(
    project: Project,
    photoDirectory: URL,
    collectionName: String = "Collection",
    date: Date = Date(),
    includesWatermark: Bool = false
  ) throws -> URL {
    let image = try render(
      project: project,
      photoDirectory: photoDirectory,
      includesWatermark: includesWatermark
    )
    return try writeExport(image: image, project: project, collectionName: collectionName, date: date)
  }

  static func prepareExport(
    project: Project,
    photoDirectory: URL,
    collectionName: String = "Collection",
    date: Date = Date(),
    includesWatermark: Bool = false
  ) throws
    -> PreparedCollageExport
  {
    let requestedOutputSize = LayoutEngine.outputSize(for: project)
    let image = try render(
      project: project,
      photoDirectory: photoDirectory,
      includesWatermark: includesWatermark
    )
    let url = try writeExport(image: image, project: project, collectionName: collectionName, date: date)
    return PreparedCollageExport(
      fileURL: url,
      previewImage: exportPreviewImage(from: image),
      outputSize: image.size,
      requestedOutputSize: requestedOutputSize,
      includesWatermark: includesWatermark
    )
  }

  private static func writeExport(
    image: UIImage,
    project: Project,
    collectionName: String,
    date: Date
  ) throws -> URL {
    let fileName = exportFileName(
      collectionName: collectionName,
      projectName: project.name,
      format: project.outputFormat,
      date: date
    )
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
    try writeEncodedImage(image, to: url, format: project.outputFormat, quality: project.quality)
    return url
  }

  private static func exportPreviewImage(from image: UIImage) -> UIImage {
    let size = image.size
    let pixelCount = max(1, size.width * size.height)
    let pixelScale = sqrt(previewMaximumPixelCount / pixelCount)
    let sideScale = previewMaximumSide / max(size.width, size.height, 1)
    let scale = min(1, pixelScale, sideScale)
    guard scale < 0.999 else { return image }

    let previewSize = CGSize(
      width: max(1, (size.width * scale).rounded()),
      height: max(1, (size.height * scale).rounded())
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    return UIGraphicsImageRenderer(size: previewSize, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: previewSize))
    }
  }

  static func saveToPhotoLibrary(fileURL: URL) async throws -> String {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
      throw NSError(
        domain: "MixaFrame.PhotoLibrary",
        code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "Photo Library access is required to save the project."
        ]
      )
    }

    var assetIdentifier: String?
    try await PHPhotoLibrary.shared().performChanges {
      let request = PHAssetCreationRequest.forAsset()
      let options = PHAssetResourceCreationOptions()
      options.originalFilename = fileURL.lastPathComponent
      request.addResource(with: .photo, fileURL: fileURL, options: options)
      assetIdentifier = request.placeholderForCreatedAsset?.localIdentifier
    }
    guard let assetIdentifier else {
      throw photoLibraryError("Photos did not return an identifier for the saved project.")
    }
    return assetIdentifier
  }

  static func replacePhotoLibraryAsset(
    identifier: String,
    with fileURL: URL,
    format: OutputFormat
  ) async throws {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard status == .authorized || status == .limited else {
      throw photoLibraryError(
        "Full Photo Library access is required to replace an existing project."
      )
    }

    guard
      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        .firstObject
    else {
      throw photoLibraryError(
        "The previously exported photo is no longer available. Choose Create New Photo instead."
      )
    }

    let input = try await contentEditingInput(for: asset)
    let output = PHContentEditingOutput(contentEditingInput: input)
    let renderedURL = try output.renderedContentURL(for: uniformType(for: format))
    try? FileManager.default.removeItem(at: renderedURL)
    try FileManager.default.copyItem(at: fileURL, to: renderedURL)
    output.adjustmentData = PHAdjustmentData(
      formatIdentifier: "com.infiz.MixaFrame.project",
      formatVersion: "1.0",
      data: Data(UUID().uuidString.utf8)
    )

    try await PHPhotoLibrary.shared().performChanges {
      PHAssetChangeRequest(for: asset).contentEditingOutput = output
    }
  }

  private static func contentEditingInput(for asset: PHAsset) async throws
    -> PHContentEditingInput
  {
    try await withCheckedThrowingContinuation { continuation in
      let options = PHContentEditingInputRequestOptions()
      options.isNetworkAccessAllowed = true
      asset.requestContentEditingInput(with: options) { input, info in
        if let input {
          continuation.resume(returning: input)
        } else if let error = info[PHContentEditingInputErrorKey] as? Error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(
            throwing: photoLibraryError(
              "Photos could not prepare the existing project for editing."
            )
          )
        }
      }
    }
  }

  private static func uniformType(for format: OutputFormat) -> UTType {
    switch format {
    case .jpeg: .jpeg
    case .png: .png
    case .webP: .webP
    case .heif: .heic
    }
  }

  private static func photoLibraryError(_ detail: String) -> NSError {
    NSError(
      domain: "MixaFrame.PhotoLibrary",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: detail]
    )
  }

  private static func writeEncodedImage(
    _ image: UIImage,
    to url: URL,
    format: OutputFormat,
    quality: OutputQuality
  ) throws {
    try? FileManager.default.removeItem(at: url)
    do {
      if format == .webP {
        guard
          let data = SDImageWebPCoder.shared.encodedData(
            with: image,
            format: .webP,
            options: [.encodeCompressionQuality: quality.compressionQuality]
          )
        else {
          throw AppError.encodingUnavailable(format.title)
        }
        try data.write(to: url, options: .atomic)
        return
      }

      guard let cgImage = image.normalizedCGImage,
        let destination = CGImageDestinationCreateWithURL(
          url as CFURL,
          uniformType(for: format).identifier as CFString,
          1,
          nil
        )
      else {
        throw AppError.encodingUnavailable(format.title)
      }
      let properties: CFDictionary? =
        switch format {
        case .jpeg, .heif:
          [kCGImageDestinationLossyCompressionQuality: quality.compressionQuality] as CFDictionary
        case .png:
          nil
        case .webP:
          nil
        }
      CGImageDestinationAddImage(destination, cgImage, properties)
      guard CGImageDestinationFinalize(destination) else {
        throw AppError.encodingUnavailable(format.title)
      }
    } catch {
      try? FileManager.default.removeItem(at: url)
      throw error
    }
  }

  private static func drawAspectFill(
    cgImage: CGImage,
    in frame: CGRect,
    focalPoint: CGPoint,
    zoom: CGFloat
  ) {
    let sourceWidth = CGFloat(cgImage.width)
    let sourceHeight = CGFloat(cgImage.height)
    let sourceRatio = sourceWidth / sourceHeight
    let destinationRatio = frame.width / frame.height
    let normalizedCrop = PhotoCropGeometry.normalizedCropRect(
      sourceAspectRatio: sourceRatio,
      destinationAspectRatio: destinationRatio,
      focalPoint: focalPoint,
      zoom: zoom
    )
    let crop = CGRect(
      x: normalizedCrop.minX * sourceWidth,
      y: normalizedCrop.minY * sourceHeight,
      width: normalizedCrop.width * sourceWidth,
      height: normalizedCrop.height * sourceHeight
    )

    guard let cropped = cgImage.cropping(to: crop.integral) else { return }
    UIImage(cgImage: cropped).draw(in: frame)
  }

  private static func drawWatermark(in canvasRect: CGRect) {
    let fontSize = watermarkFontSize(in: canvasRect)
    let font = watermarkFont(ofSize: fontSize)
    let brandText = "MixaFrame" as NSString
    let captionText = "CREATED WITH" as NSString
    let shadow = NSShadow()
    shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
    shadow.shadowBlurRadius = fontSize * 0.12
    shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.06)
    let brandAttributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: UIColor.white,
      .kern: fontSize * 0.018,
      .shadow: shadow,
    ]
    let captionFontSize = max(6, fontSize * 0.3)
    let captionAttributes: [NSAttributedString.Key: Any] = [
      .font: UIFont.systemFont(ofSize: captionFontSize, weight: .bold),
      .foregroundColor: UIColor.white.withAlphaComponent(0.82),
      .kern: captionFontSize * 0.14,
    ]
    let brandSize = brandText.size(withAttributes: brandAttributes)
    let captionSize = captionText.size(withAttributes: captionAttributes)
    let horizontalPadding = fontSize * 0.78
    let verticalPadding = fontSize * 0.38
    let lineSpacing = fontSize * 0.08
    let margin = max(fontSize * 0.72, min(canvasRect.width, canvasRect.height) * 0.025)
    let contentWidth = max(brandSize.width, captionSize.width)
    let contentHeight = captionSize.height + lineSpacing + brandSize.height
    let backgroundSize = CGSize(
      width: contentWidth + horizontalPadding * 2,
      height: contentHeight + verticalPadding * 2
    )
    let backgroundRect = CGRect(
      x: canvasRect.maxX - backgroundSize.width - margin,
      y: canvasRect.maxY - backgroundSize.height - margin,
      width: backgroundSize.width,
      height: backgroundSize.height
    )
    let contentTop = backgroundRect.midY - contentHeight / 2

    let badgePath = UIBezierPath(
      roundedRect: backgroundRect,
      cornerRadius: backgroundRect.height / 2
    )
    UIColor.black.withAlphaComponent(0.68).setFill()
    badgePath.fill()
    UIColor.white.withAlphaComponent(0.22).setStroke()
    badgePath.lineWidth = max(1, fontSize * 0.025)
    badgePath.stroke()

    captionText.draw(
      at: CGPoint(
        x: backgroundRect.midX - captionSize.width / 2,
        y: contentTop
      ),
      withAttributes: captionAttributes
    )
    brandText.draw(
      at: CGPoint(
        x: backgroundRect.midX - brandSize.width / 2,
        y: contentTop + captionSize.height + lineSpacing
      ),
      withAttributes: brandAttributes
    )
  }

  static func watermarkFontSize(in canvasRect: CGRect) -> CGFloat {
    max(18, min(canvasRect.width, canvasRect.height) * 0.04)
  }

  static func watermarkFont(ofSize size: CGFloat) -> UIFont {
    if let avenirNext = UIFont(name: "AvenirNext-DemiBold", size: size) {
      return avenirNext
    }
    let systemFont = UIFont.systemFont(ofSize: size, weight: .bold)
    guard let roundedDescriptor = systemFont.fontDescriptor.withDesign(.rounded) else {
      return systemFont
    }
    return UIFont(descriptor: roundedDescriptor, size: size)
  }

  private static func clippingPath(for layoutFrame: LayoutFrame) -> UIBezierPath {
    let frame = layoutFrame.rect
    if let normalizedClipPolygon = layoutFrame.normalizedClipPolygon,
      normalizedClipPolygon.count >= 3
    {
      let path = UIBezierPath()
      for (index, point) in normalizedClipPolygon.enumerated() {
        let resolvedPoint = CGPoint(
          x: frame.minX + point.x * frame.width,
          y: frame.minY + point.y * frame.height
        )
        if index == 0 {
          path.move(to: resolvedPoint)
        } else {
          path.addLine(to: resolvedPoint)
        }
      }
      path.close()
      return path
    }
    if layoutFrame.cornerRadiusFraction >= 0.49 {
      return UIBezierPath(ovalIn: frame)
    }
    let radius = min(frame.width, frame.height) * max(0, layoutFrame.cornerRadiusFraction)
    return UIBezierPath(roundedRect: frame, cornerRadius: radius)
  }

  private static func canvasClippingPath(for project: Project, in rect: CGRect) -> UIBezierPath {
    let radius = min(rect.width, rect.height) * CGFloat(project.canvasCornerRadius / 100)
    return UIBezierPath(roundedRect: rect, cornerRadius: radius)
  }

  static func exportFileName(
    collectionName: String,
    projectName: String,
    format: OutputFormat,
    date: Date = Date(),
    timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let timestamp = formatter.string(from: date)
    return [
      timestamp,
      sanitizedFileNameComponent(collectionName, fallback: "Collection"),
      sanitizedFileNameComponent(projectName, fallback: "Project"),
    ].joined(separator: "-") + "." + format.fileExtension
  }

  private static func sanitizedFileNameComponent(_ value: String, fallback: String) -> String {
    let normalized = value.precomposedStringWithCanonicalMapping
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    var result = ""

    for character in normalized {
      let isAllowed = character.unicodeScalars.allSatisfy { allowed.contains($0) }
      if isAllowed {
        if character == "-", result.last == "-" { continue }
        result.append(character)
      } else if !result.isEmpty, result.last != "-" {
        result.append("-")
      }
    }

    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    guard !trimmed.isEmpty else { return fallback }

    let maximumUTF8Bytes = 80
    var safeName = ""
    var byteCount = 0
    for character in trimmed {
      let characterBytes = String(character).utf8.count
      guard byteCount + characterBytes <= maximumUTF8Bytes else { break }
      safeName.append(character)
      byteCount += characterBytes
    }
    safeName = safeName.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return safeName.isEmpty ? fallback : safeName
  }
}

extension UIColor {
  convenience init(hex: String) {
    let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    var value: UInt64 = 0xFFFFFF
    Scanner(string: cleaned).scanHexInt64(&value)
    self.init(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }
}
