import Foundation
import ImageIO
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif

struct DerivedPhotoImages {
  let preview: PlatformImage
  let thumbnail: PlatformImage
}

struct ImportedPhotoAsset {
  let photo: CollagePhoto
  let images: DerivedPhotoImages
}

enum PhotoImagePipeline {
  static let previewMaximumPixelSize = 1600
  static let thumbnailMaximumPixelSize = 256

  static func importPhoto(
    data: Data,
    id: UUID,
    photoLibraryAssetIdentifier: String? = nil,
    originalURL: URL,
    previewURL: URL,
    thumbnailURL: URL
  ) throws -> ImportedPhotoAsset {
    try importPhoto(
      id: id,
      photoLibraryAssetIdentifier: photoLibraryAssetIdentifier,
      originalURL: originalURL,
      previewURL: previewURL,
      thumbnailURL: thumbnailURL
    ) {
      try data.write(to: originalURL, options: .atomic)
    }
  }

  static func importPhoto(
    fileURL: URL,
    id: UUID,
    photoLibraryAssetIdentifier: String? = nil,
    originalURL: URL,
    previewURL: URL,
    thumbnailURL: URL
  ) throws -> ImportedPhotoAsset {
    try importPhoto(
      id: id,
      photoLibraryAssetIdentifier: photoLibraryAssetIdentifier,
      originalURL: originalURL,
      previewURL: previewURL,
      thumbnailURL: thumbnailURL
    ) {
      try FileManager.default.copyItem(at: fileURL, to: originalURL)
    }
  }

  private static func importPhoto(
    id: UUID,
    photoLibraryAssetIdentifier: String?,
    originalURL: URL,
    previewURL: URL,
    thumbnailURL: URL,
    writeOriginal: () throws -> Void
  ) throws -> ImportedPhotoAsset {
    do {
      try writeOriginal()
      guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil) else {
        throw AppError.invalidImage
      }
      let dimensions = try orientedPixelDimensions(from: source)
      let images = try createDerivedImages(
        from: source,
        previewURL: previewURL,
        thumbnailURL: thumbnailURL
      )
      guard let previewCGImage = cgImage(from: images.preview) else { throw AppError.invalidImage }
      let detection = SubjectDetector.detect(in: previewCGImage)
      let photo = CollagePhoto(
        id: id,
        fileName: originalURL.lastPathComponent,
        photoLibraryAssetIdentifier: photoLibraryAssetIdentifier,
        pixelWidth: dimensions.width,
        pixelHeight: dimensions.height,
        focalX: detection.focusPoint.x,
        focalY: detection.focusPoint.y,
        detectedFocusArea: detection.focusArea,
        hasCompletedFocusDetection: true
      )
      return ImportedPhotoAsset(photo: photo, images: images)
    } catch {
      try? FileManager.default.removeItem(at: originalURL)
      try? FileManager.default.removeItem(at: previewURL)
      try? FileManager.default.removeItem(at: thumbnailURL)
      throw error
    }
  }

  static func prepareDerivedImages(
    originalURL: URL,
    previewURL: URL,
    thumbnailURL: URL
  ) throws -> DerivedPhotoImages {
    let preview = preparedImage(at: previewURL)
    let thumbnail = preparedImage(at: thumbnailURL)
    if let preview, let thumbnail {
      return DerivedPhotoImages(preview: preview, thumbnail: thumbnail)
    }

    guard let source = CGImageSourceCreateWithURL(originalURL as CFURL, nil) else {
      throw AppError.imageMissing
    }
    return try createDerivedImages(
      from: source,
      previewURL: previewURL,
      thumbnailURL: thumbnailURL,
      existingPreview: preview,
      existingThumbnail: thumbnail
    )
  }

  private static func createDerivedImages(
    from source: CGImageSource,
    previewURL: URL,
    thumbnailURL: URL,
    existingPreview: PlatformImage? = nil,
    existingThumbnail: PlatformImage? = nil
  ) throws -> DerivedPhotoImages {
    let preview =
      try existingPreview
      ?? createDerivedImage(
        from: source,
        maximumPixelSize: previewMaximumPixelSize,
        destination: previewURL,
        compressionQuality: 0.86
      )
    let thumbnail =
      try existingThumbnail
      ?? createDerivedImage(
        from: source,
        maximumPixelSize: thumbnailMaximumPixelSize,
        destination: thumbnailURL,
        compressionQuality: 0.78
      )
    return DerivedPhotoImages(preview: preview, thumbnail: thumbnail)
  }

  private static func createDerivedImage(
    from source: CGImageSource,
    maximumPixelSize: Int,
    destination: URL,
    compressionQuality: CGFloat
  ) throws -> PlatformImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    else {
      throw AppError.invalidImage
    }
    let image = platformImage(from: cgImage)
    guard let data = jpegData(from: image, compressionQuality: compressionQuality) else {
      throw AppError.invalidImage
    }
    try data.write(to: destination, options: .atomic)
    return image
  }

  private static func preparedImage(at url: URL) -> PlatformImage? {
#if canImport(UIKit)
    guard let image = UIImage(contentsOfFile: url.path) else { return nil }
    return image.preparingForDisplay() ?? image
#elseif canImport(AppKit)
    return NSImage(contentsOf: url)
#endif
  }

  private static func platformImage(from cgImage: CGImage) -> PlatformImage {
#if canImport(UIKit)
    UIImage(cgImage: cgImage)
#elseif canImport(AppKit)
    NSImage(cgImage: cgImage, size: .zero)
#endif
  }

  private static func jpegData(
    from image: PlatformImage,
    compressionQuality: CGFloat
  ) -> Data? {
#if canImport(UIKit)
    image.jpegData(compressionQuality: compressionQuality)
#elseif canImport(AppKit)
    guard let cgImage = cgImage(from: image) else { return nil }
    return NSBitmapImageRep(cgImage: cgImage).representation(
      using: .jpeg,
      properties: [.compressionFactor: compressionQuality]
    )
#endif
  }

  private static func cgImage(from image: PlatformImage) -> CGImage? {
#if canImport(UIKit)
    image.cgImage
#elseif canImport(AppKit)
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
#endif
  }

  private static func orientedPixelDimensions(from source: CGImageSource) throws -> (
    width: Int, height: Int
  ) {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        as? [CFString: Any],
      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
      width > 0,
      height > 0
    else {
      throw AppError.invalidImage
    }
    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    return (5...8).contains(orientation) ? (height, width) : (width, height)
  }
}
