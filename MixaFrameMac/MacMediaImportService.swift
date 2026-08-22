import Foundation
import UniformTypeIdentifiers

enum MacPhotoImportError: LocalizedError {
  case unsupportedFile(String)
  case unreadableFile(String)

  var errorDescription: String? {
    switch self {
    case .unsupportedFile(let name):
      "\(name) is not a supported photo file."
    case .unreadableFile(let name):
      "\(name) could not be read."
    }
  }

  var ignoredReason: String {
    switch self {
    case .unsupportedFile:
      "Unsupported format"
    case .unreadableFile:
      "The file could not be read"
    }
  }
}

struct MacIgnoredPhotoFile: Equatable {
  let filename: String
  let reason: String
}

struct MacPhotoImportResult {
  let photos: [CollagePhoto]
  let ignoredFiles: [MacIgnoredPhotoFile]
}

enum MacMediaImportService {
  static let photoContentTypes: [UTType] = [.image]

  /// Imports every supported item independently so one invalid Finder file
  /// cannot prevent the rest of a picker or drag-and-drop batch from loading.
  @MainActor
  static func importPhotos(
    from urls: [URL],
    maximumCount: Int,
    using store: AppStore
  ) async -> MacPhotoImportResult {
    var imported: [CollagePhoto] = []
    var ignoredFiles: [MacIgnoredPhotoFile] = []
    imported.reserveCapacity(min(urls.count, maximumCount))
    ignoredFiles.reserveCapacity(urls.count)

    for url in urls {
      let hasSecurityScope = url.startAccessingSecurityScopedResource()
      defer {
        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
      }

      do {
        guard contentType(for: url)?.conforms(to: .image) == true else {
          throw MacPhotoImportError.unsupportedFile(url.lastPathComponent)
        }
        guard imported.count < maximumCount else {
          ignoredFiles.append(
            MacIgnoredPhotoFile(
              filename: url.lastPathComponent,
              reason: "The project already contains the maximum of 12 photos"
            )
          )
          continue
        }
        imported.append(try await store.importPhotoFile(at: url))
      } catch let error as MacPhotoImportError {
        ignoredFiles.append(
          MacIgnoredPhotoFile(filename: url.lastPathComponent, reason: error.ignoredReason)
        )
      } catch {
        ignoredFiles.append(
          MacIgnoredPhotoFile(
            filename: url.lastPathComponent,
            reason: error.localizedDescription.isEmpty
              ? MacPhotoImportError.unreadableFile(url.lastPathComponent).ignoredReason
              : error.localizedDescription
          )
        )
      }
    }

    return MacPhotoImportResult(photos: imported, ignoredFiles: ignoredFiles)
  }

  private static func contentType(for url: URL) -> UTType? {
    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
      return type
    }
    guard !url.pathExtension.isEmpty else { return nil }
    return UTType(filenameExtension: url.pathExtension)
  }
}
