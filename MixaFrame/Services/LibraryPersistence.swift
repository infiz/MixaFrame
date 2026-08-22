import Foundation

struct LibraryLoadResult: @unchecked Sendable {
  let collections: [Collection]
  let customLayouts: [SavedCustomLayout]
}

actor LibraryPersistence {
  private let paths: StoragePaths
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(paths: StoragePaths) {
    self.paths = paths
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func ensureDirectories() throws {
    try paths.ensureDirectories()
  }

  func load() throws -> LibraryLoadResult {
    try paths.ensureDirectories()
    let fileManager = FileManager.default
    let collections = try decodeIfPresent(
      [Collection].self,
      from: paths.collectionsDatabaseURL,
      fileManager: fileManager
    ) ?? []
    let customLayouts = try decodeIfPresent(
      [SavedCustomLayout].self,
      from: paths.customLayoutsDatabaseURL,
      fileManager: fileManager
    ) ?? []
    return LibraryLoadResult(collections: collections, customLayouts: customLayouts)
  }

  func persistCollections(_ collections: [Collection]) throws {
    try paths.ensureDirectories()
    try encoder.encode(collections).write(to: paths.collectionsDatabaseURL, options: .atomic)
  }

  func persistCustomLayouts(_ layouts: [SavedCustomLayout]) throws {
    try paths.ensureDirectories()
    try encoder.encode(layouts).write(to: paths.customLayoutsDatabaseURL, options: .atomic)
  }

  private func decodeIfPresent<Value: Decodable>(
    _ type: Value.Type,
    from url: URL,
    fileManager: FileManager
  ) throws -> Value? {
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    return try decoder.decode(type, from: Data(contentsOf: url))
  }
}
