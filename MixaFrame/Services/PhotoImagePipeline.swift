import Foundation
import ImageIO
import UIKit

struct DerivedPhotoImages {
  let preview: UIImage
  let thumbnail: UIImage
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
      guard let previewCGImage = images.preview.cgImage else { throw AppError.invalidImage }
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
    existingPreview: UIImage? = nil,
    existingThumbnail: UIImage? = nil
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
  ) throws -> UIImage {
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
    let image = UIImage(cgImage: cgImage)
    guard let data = image.jpegData(compressionQuality: compressionQuality) else {
      throw AppError.invalidImage
    }
    try data.write(to: destination, options: .atomic)
    return image
  }

  private static func preparedImage(at url: URL) -> UIImage? {
    guard let image = UIImage(contentsOfFile: url.path) else { return nil }
    return image.preparingForDisplay() ?? image
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
