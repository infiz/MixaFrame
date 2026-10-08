import Foundation

struct StoragePaths: Sendable {
  let rootDirectory: URL

  init(rootDirectory: URL = Self.defaultRootDirectory()) {
    self.rootDirectory = rootDirectory
  }

  var photoDirectory: URL {
    rootDirectory.appendingPathComponent("Photos", isDirectory: true)
  }

  var exportDirectory: URL {
    rootDirectory.appendingPathComponent("Exports", isDirectory: true)
  }

  var previewDirectory: URL {
    rootDirectory.appendingPathComponent("Previews", isDirectory: true)
  }

  var thumbnailDirectory: URL {
    rootDirectory.appendingPathComponent("Thumbnails", isDirectory: true)
  }

  var projectThumbnailDirectory: URL {
    rootDirectory.appendingPathComponent("ProjectThumbnails", isDirectory: true)
  }

  var draftDirectory: URL {
    rootDirectory.appendingPathComponent("Drafts", isDirectory: true)
  }

  func draftURL(projectID: UUID) -> URL {
    draftDirectory.appendingPathComponent("\(projectID.uuidString).json")
  }

  var collectionsDatabaseURL: URL {
    rootDirectory.appendingPathComponent("collections.json")
  }

  var customLayoutsDatabaseURL: URL {
    rootDirectory.appendingPathComponent("custom-layouts.json")
  }

  func ensureDirectories() throws {
    let fileManager = FileManager.default
    for directory in [
      photoDirectory,
      exportDirectory,
      previewDirectory,
      thumbnailDirectory,
      projectThumbnailDirectory,
      draftDirectory,
    ] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  static func defaultRootDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MixaFrame", isDirectory: true)
  }
}
