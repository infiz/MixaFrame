import Foundation
import ImageIO
#if canImport(UIKit)
import Photos
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private actor AsyncPermitPool {
  private var availablePermits: Int
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    availablePermits = max(1, limit)
  }

  func acquire() async {
    if availablePermits > 0 {
      availablePermits -= 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    if waiters.isEmpty {
      availablePermits += 1
    } else {
      waiters.removeFirst().resume()
    }
  }
}

@MainActor
final class AppStore: ObservableObject {
  @Published private(set) var collections: [Collection] = []
  @Published private(set) var savedCustomLayouts: [SavedCustomLayout] = []
  @Published private(set) var isLoaded = false
  @Published var alertMessage: String?
  @Published private(set) var imageCacheRevision = 0
  @Published private(set) var imageCacheReloadGeneration = 0

  private let storagePaths: StoragePaths
  private let persistence: LibraryPersistence
  private let previewCache = NSCache<NSString, PlatformImage>()
  private let thumbnailCache = NSCache<NSString, PlatformImage>()
#if canImport(UIKit)
  private let projectThumbnailCache = NSCache<NSString, UIImage>()
#endif
  private let derivedImagePreparationPermits = AsyncPermitPool(limit: 2)
#if canImport(UIKit)
  private var memoryWarningObserver: NSObjectProtocol?
#endif
  private var loadingTask: Task<Void, Never>?

  init(rootDirectory: URL? = nil) {
    let storagePaths = StoragePaths(rootDirectory: rootDirectory ?? StoragePaths.defaultRootDirectory())
    self.storagePaths = storagePaths
    persistence = LibraryPersistence(paths: storagePaths)
    previewCache.totalCostLimit = 96 * 1024 * 1024
    thumbnailCache.totalCostLimit = 12 * 1024 * 1024
#if canImport(UIKit)
    projectThumbnailCache.totalCostLimit = 16 * 1024 * 1024
    memoryWarningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.clearImageCaches() }
    }
#endif
    loadingTask = Task { [weak self] in
      await self?.loadFromDisk()
    }
  }

  deinit {
    loadingTask?.cancel()
#if canImport(UIKit)
    if let memoryWarningObserver {
      NotificationCenter.default.removeObserver(memoryWarningObserver)
    }
#endif
  }

  var rootDirectory: URL {
    storagePaths.rootDirectory
  }

  func waitUntilLoaded() async {
    await loadingTask?.value
  }

  func resumeImageCacheLoading() {
    // NSCache can discard images while the app is suspended without sending a memory warning.
    // Restart the visible views' disk-backed image preparation whenever the scene becomes active.
    imageCacheReloadGeneration &+= 1
  }

  var photoDirectory: URL {
    storagePaths.photoDirectory
  }

  var exportDirectory: URL {
    storagePaths.exportDirectory
  }

  var previewDirectory: URL {
    storagePaths.previewDirectory
  }

  var thumbnailDirectory: URL {
    storagePaths.thumbnailDirectory
  }

  var projectThumbnailDirectory: URL {
    storagePaths.projectThumbnailDirectory
  }

  func collection(id: UUID) -> Collection? {
    collections.first { $0.id == id }
  }

  func createCollection(name: String) async -> UUID {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let collection = Collection(name: trimmed.isEmpty ? "New Collection" : trimmed)
    let previousCollections = collections
    collections.insert(collection, at: 0)
    do {
      try await persistence.persistCollections(collections)
    } catch {
      collections = previousCollections
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
    }
    return collection.id
  }

  @discardableResult
  func createCustomLayout(
    name: String,
    photoCount: Int,
    frames: [NormalizedLayoutFrame]
  ) async -> UUID? {
    let resolvedCount = max(1, min(photoCount, 12))
    guard frames.count == resolvedCount, frames.allSatisfy(\.isValid) else { return nil }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let layout = SavedCustomLayout(
      name: trimmed.isEmpty ? "Custom Layout" : trimmed,
      photoCount: resolvedCount,
      frames: frames
    )
    let previousLayouts = savedCustomLayouts
    savedCustomLayouts.insert(layout, at: 0)
    do {
      try await persistence.persistCustomLayouts(savedCustomLayouts)
    } catch {
      savedCustomLayouts = previousLayouts
      alertMessage = "Custom layouts could not be saved: \(error.localizedDescription)"
      return nil
    }
    return layout.id
  }

  func updateCustomLayout(
    id: UUID,
    name: String? = nil,
    frames: [NormalizedLayoutFrame]? = nil
  ) async {
    guard let index = savedCustomLayouts.firstIndex(where: { $0.id == id }) else { return }
    let previousLayouts = savedCustomLayouts
    if let name {
      let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty { savedCustomLayouts[index].name = trimmed }
    }
    if let frames,
      frames.count == savedCustomLayouts[index].photoCount,
      frames.allSatisfy(\.isValid)
    {
      savedCustomLayouts[index].frames = frames
    }
    savedCustomLayouts[index].modifiedAt = Date()
    do {
      try await persistence.persistCustomLayouts(savedCustomLayouts)
    } catch {
      savedCustomLayouts = previousLayouts
      alertMessage = "Custom layouts could not be saved: \(error.localizedDescription)"
    }
  }

  @discardableResult
  func duplicateCustomLayout(id: UUID) async -> UUID? {
    guard let source = savedCustomLayouts.first(where: { $0.id == id }) else { return nil }
    return await createCustomLayout(
      name: "\(source.name) Copy",
      photoCount: source.photoCount,
      frames: source.frames
    )
  }

  func deleteCustomLayout(id: UUID) async {
    let previousLayouts = savedCustomLayouts
    savedCustomLayouts.removeAll { $0.id == id }
    do {
      try await persistence.persistCustomLayouts(savedCustomLayouts)
    } catch {
      savedCustomLayouts = previousLayouts
      alertMessage = "Custom layouts could not be saved: \(error.localizedDescription)"
    }
  }

  func renameCollection(id: UUID, name: String) async {
    guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let previousCollections = collections
    collections[index].name = trimmed
    collections[index].modifiedAt = Date()
    do {
      try await persistence.persistCollections(collections)
    } catch {
      collections = previousCollections
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
    }
  }

  func deleteCollections(at offsets: IndexSet) async {
    let previousCollections = collections
    var removedProjects: [Project] = []
    for index in offsets.sorted(by: >) {
      removedProjects.append(contentsOf: collections.remove(at: index).projects)
    }
    do {
      try await persistence.persistCollections(collections)
    } catch {
      collections = previousCollections
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
      return
    }
    for project in removedProjects { await cleanUpUnreferencedAssets(for: project) }
  }

  func deleteCollection(id: UUID) async {
    guard let index = collections.firstIndex(where: { $0.id == id }) else { return }
    let previousCollections = collections
    let collection = collections.remove(at: index)
    do {
      try await persistence.persistCollections(collections)
    } catch {
      collections = previousCollections
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
      return
    }
    for project in collection.projects { await cleanUpUnreferencedAssets(for: project) }
  }

  func deleteProject(collectionID: UUID, projectID: UUID) async {
    guard let collectionIndex = collections.firstIndex(where: { $0.id == collectionID }),
      let projectIndex = collections[collectionIndex].projects.firstIndex(where: { $0.id == projectID })
    else { return }
    let previousCollections = collections
    let project = collections[collectionIndex].projects.remove(at: projectIndex)
    collections[collectionIndex].modifiedAt = Date()
    do {
      try await persistence.persistCollections(collections)
    } catch {
      collections = previousCollections
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
      return
    }
    await cleanUpUnreferencedAssets(for: project)
  }

  @discardableResult
  func saveProject(_ project: Project) async -> Project? {
    guard let collectionIndex = collections.firstIndex(where: { $0.id == project.collectionID }) else {
      alertMessage = "The collection for this project could not be found."
      return nil
    }
    let previousCollections = collections
    var updated = project
    updated.savedLayoutSnapshot = LayoutEngine.savedLayoutSnapshot(for: updated)
    updated.modifiedAt = Date()
    var removedPhotos: [CollagePhoto] = []
    var replacedExportFileName: String?
    if let projectIndex = collections[collectionIndex].projects.firstIndex(where: { $0.id == project.id }) {
      let previousProject = collections[collectionIndex].projects[projectIndex]
      let retainedPhotoIDs = Set(updated.photos.map(\.id))
      removedPhotos = previousProject.photos.filter {
        !retainedPhotoIDs.contains($0.id)
      }
      if previousProject.photos.map(\.id) != updated.photos.map(\.id) {
        updated.invalidateExport()
      }
      let previousExport = previousProject.latestExportFileName
      if previousExport != updated.latestExportFileName { replacedExportFileName = previousExport }
      collections[collectionIndex].projects[projectIndex] = updated
    } else {
      collections[collectionIndex].projects.insert(updated, at: 0)
    }
    collections[collectionIndex].modifiedAt = Date()
    do {
      try await persistence.persistCollections(collections)
    } catch {
      collections = previousCollections
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
      return nil
    }
    for photo in removedPhotos { await cleanUpUnreferencedPhotoAssets(photo) }
    if let replacedExportFileName {
      await removeExportIfUnreferenced(fileName: replacedExportFileName)
    }
#if canImport(UIKit)
    await persistProjectThumbnail(for: updated, usesExisting: false)
#endif
    return updated
  }

  func discardUnsavedProjectFiles(from project: Project) async {
    for photo in project.photos { await discardPhotoIfUnreferenced(photo) }
  }

  func discardPhotoIfUnreferenced(_ photo: CollagePhoto) async {
    await cleanUpUnreferencedPhotoAssets(photo)
  }

  func imageURL(for photo: CollagePhoto) -> URL {
    photoDirectory.appendingPathComponent(photo.fileName)
  }

  func previewURL(for photo: CollagePhoto) -> URL {
    previewDirectory.appendingPathComponent("\(photo.id.uuidString).jpg")
  }

  func thumbnailURL(for photo: CollagePhoto) -> URL {
    thumbnailDirectory.appendingPathComponent("\(photo.id.uuidString).jpg")
  }

  func projectThumbnailURL(for project: Project) -> URL {
    projectThumbnailDirectory.appendingPathComponent("\(project.id.uuidString).png")
  }

  func previewImage(for photo: CollagePhoto) -> PlatformImage? {
    previewCache.object(forKey: cacheKey(for: photo))
      ?? thumbnailCache.object(forKey: cacheKey(for: photo))
  }

  func thumbnailImage(for photo: CollagePhoto) -> PlatformImage? {
    thumbnailCache.object(forKey: cacheKey(for: photo))
      ?? previewCache.object(forKey: cacheKey(for: photo))
  }

  func preloadPersistedThumbnails(for photos: [CollagePhoto]) async {
    await prepareDerivedImages(for: photos)
  }

#if canImport(UIKit)
  func projectThumbnailImage(for project: Project) -> UIImage? {
    projectThumbnailCache.object(forKey: projectThumbnailCacheKey(for: project))
  }

  func prepareProjectThumbnails(for projects: [Project]) async {
    for project in projects where projectThumbnailImage(for: project) == nil {
      guard !Task.isCancelled else { return }
      await persistProjectThumbnail(for: project)
    }
  }
#endif

  func persistExport(from temporaryURL: URL, for project: Project) async throws -> URL {
    let exportDirectory = exportDirectory
    let previousName = project.latestExportFileName
    let fileName = temporaryURL.lastPathComponent
    let destination = exportDirectory.appendingPathComponent(fileName)
    try await Task.detached(priority: .utility) {
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
      if let previousName {
        try? fileManager.removeItem(at: exportDirectory.appendingPathComponent(previousName))
      }
      try? fileManager.removeItem(at: destination)
      try fileManager.copyItem(at: temporaryURL, to: destination)
    }.value
    return destination
  }

  func importPhotoData(
    _ data: Data,
    photoLibraryAssetIdentifier: String? = nil
  ) async throws -> CollagePhoto {
    let id = UUID()
    let fileName = "\(id.uuidString).image"
    let originalURL = photoDirectory.appendingPathComponent(fileName)
    let previewURL = previewDirectory.appendingPathComponent("\(id.uuidString).jpg")
    let thumbnailURL = thumbnailDirectory.appendingPathComponent("\(id.uuidString).jpg")
    let asset = try await Task.detached(priority: .userInitiated) {
      try StoragePaths(
        rootDirectory: originalURL.deletingLastPathComponent().deletingLastPathComponent()
      ).ensureDirectories()
      return try PhotoImagePipeline.importPhoto(
        data: data,
        id: id,
        photoLibraryAssetIdentifier: photoLibraryAssetIdentifier,
        originalURL: originalURL,
        previewURL: previewURL,
        thumbnailURL: thumbnailURL
      )
    }.value
    cache(asset.images, for: asset.photo)
    return asset.photo
  }

  func importPhotoFile(
    at fileURL: URL,
    photoLibraryAssetIdentifier: String? = nil
  ) async throws -> CollagePhoto {
    let id = UUID()
    let fileName = "\(id.uuidString).image"
    let originalURL = photoDirectory.appendingPathComponent(fileName)
    let previewURL = previewDirectory.appendingPathComponent("\(id.uuidString).jpg")
    let thumbnailURL = thumbnailDirectory.appendingPathComponent("\(id.uuidString).jpg")
    let asset = try await Task.detached(priority: .userInitiated) {
      try StoragePaths(
        rootDirectory: originalURL.deletingLastPathComponent().deletingLastPathComponent()
      ).ensureDirectories()
      return try PhotoImagePipeline.importPhoto(
        fileURL: fileURL,
        id: id,
        photoLibraryAssetIdentifier: photoLibraryAssetIdentifier,
        originalURL: originalURL,
        previewURL: previewURL,
        thumbnailURL: thumbnailURL
      )
    }.value
    cache(asset.images, for: asset.photo)
    return asset.photo
  }

  func originalImage(for photo: CollagePhoto) async -> PlatformImage? {
    do {
      try await restoreOriginalIfNeeded(for: photo)
    } catch {
      return nil
    }
    let path = imageURL(for: photo).path
    return await Task.detached(priority: .userInitiated) {
      autoreleasepool {
#if canImport(UIKit)
        guard let source = UIImage(contentsOfFile: path) else { return nil }
        return source.preparingForDisplay() ?? source
#elseif canImport(AppKit)
        return NSImage(contentsOfFile: path)
#endif
      }
    }.value
  }

#if canImport(AppKit)
  func image(for photo: CollagePhoto) -> NSImage? {
    let key = cacheKey(for: photo)
    if let cached = previewCache.object(forKey: key) { return cached }
    guard let image = NSImage(contentsOf: imageURL(for: photo)) else { return nil }
    previewCache.setObject(image, forKey: key, cost: memoryCost(of: image))
    return image
  }
#endif

  func restoreOriginalsIfNeeded(for photos: [CollagePhoto]) async throws {
    for photo in photos {
      try await restoreOriginalIfNeeded(for: photo)
    }
  }

  private func restoreOriginalIfNeeded(for photo: CollagePhoto) async throws {
    let destination = imageURL(for: photo)
    let hasValidOriginal = await Task.detached(priority: .utility) {
      FileManager.default.fileExists(atPath: destination.path)
        && CGImageSourceCreateWithURL(destination as CFURL, nil) != nil
    }.value
    if hasValidOriginal { return }
    await Task.detached(priority: .utility) {
      try? FileManager.default.removeItem(at: destination)
    }.value
#if canImport(UIKit)
    guard let assetIdentifier = photo.photoLibraryAssetIdentifier else {
      throw AppError.imageMissing
    }
    try await persistence.ensureDirectories()
    do {
      try await PhotoLibraryOriginalRestorer.copyOriginal(
        assetIdentifier: assetIdentifier,
        to: destination
      )
      let restoredImageIsValid = await Task.detached(priority: .utility) {
        CGImageSourceCreateWithURL(destination as CFURL, nil) != nil
      }.value
      guard restoredImageIsValid else {
        throw AppError.invalidImage
      }
    } catch {
      await Task.detached(priority: .utility) {
        try? FileManager.default.removeItem(at: destination)
      }.value
      throw error
    }
#else
    throw AppError.imageMissing
#endif
  }

  func prepareDerivedImages(for photos: [CollagePhoto]) async {
    var seenPhotoIDs = Set<UUID>()
    let pending = photos.filter { photo in
      guard seenPhotoIDs.insert(photo.id).inserted else { return false }
      let key = cacheKey(for: photo)
      return previewCache.object(forKey: key) == nil || thumbnailCache.object(forKey: key) == nil
    }
    guard !pending.isEmpty else { return }

    for batchStart in stride(from: 0, to: pending.count, by: 2) {
      guard !Task.isCancelled else { return }
      let batch = Array(pending[batchStart..<min(batchStart + 2, pending.count)])
      for photo in batch {
        try? await restoreOriginalIfNeeded(for: photo)
      }
      let requests = batch.map { photo in
        (
          photo: photo,
          originalURL: imageURL(for: photo),
          previewURL: previewURL(for: photo),
          thumbnailURL: thumbnailURL(for: photo)
        )
      }
      let preparationPermits = derivedImagePreparationPermits
      await withTaskGroup(of: (CollagePhoto, DerivedPhotoImages?).self) { group in
        for request in requests {
          group.addTask {
            await preparationPermits.acquire()
            guard !Task.isCancelled else {
              await preparationPermits.release()
              return (request.photo, nil)
            }
            let images = try? PhotoImagePipeline.prepareDerivedImages(
              originalURL: request.originalURL,
              previewURL: request.previewURL,
              thumbnailURL: request.thumbnailURL
            )
            await preparationPermits.release()
            return (request.photo, images)
          }
        }
        for await (photo, images) in group {
          if let images { cache(images, for: photo) }
        }
      }
    }
  }

  private func loadFromDisk() async {
    do {
      let loaded = try await persistence.load()
      guard !Task.isCancelled else { return }
      collections = loaded.collections
      savedCustomLayouts = loaded.customLayouts.filter { layout in
        (1...12).contains(layout.photoCount)
          && layout.frames.count == layout.photoCount
          && layout.frames.allSatisfy(\.isValid)
      }
    } catch {
      alertMessage = "Saved collections could not be loaded: \(error.localizedDescription)"
    }
    isLoaded = true
  }

  private func cleanUpUnreferencedAssets(for project: Project) async {
    for photo in project.photos { await cleanUpUnreferencedPhotoAssets(photo) }
    if let export = project.latestExportFileName {
      await removeExportIfUnreferenced(fileName: export)
    }
    let thumbnailURL = projectThumbnailURL(for: project)
    await Task.detached(priority: .utility) {
      try? FileManager.default.removeItem(at: thumbnailURL)
    }.value
#if canImport(UIKit)
    projectThumbnailCache.removeObject(forKey: projectThumbnailCacheKey(for: project))
#endif
  }

  private func cache(_ images: DerivedPhotoImages, for photo: CollagePhoto) {
    let key = cacheKey(for: photo)
    previewCache.setObject(images.preview, forKey: key, cost: memoryCost(of: images.preview))
    thumbnailCache.setObject(
      images.thumbnail, forKey: key, cost: memoryCost(of: images.thumbnail))
    imageCacheRevision &+= 1
  }

  private func cacheKey(for photo: CollagePhoto) -> NSString {
    photo.id.uuidString as NSString
  }

  private func memoryCost(of image: PlatformImage) -> Int {
#if canImport(UIKit)
    guard let cgImage = image.cgImage else { return 0 }
#elseif canImport(AppKit)
    var rect = CGRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
      return 0
    }
#endif
    return cgImage.bytesPerRow * cgImage.height
  }

  private func clearImageCaches() {
    previewCache.removeAllObjects()
    thumbnailCache.removeAllObjects()
#if canImport(UIKit)
    projectThumbnailCache.removeAllObjects()
#endif
    imageCacheRevision &+= 1
    imageCacheReloadGeneration &+= 1
  }

  private func cleanUpUnreferencedPhotoAssets(_ photo: CollagePhoto) async {
    let referencedPhotos = collections.flatMap(\.projects).flatMap(\.photos)
    let removesOriginal = !referencedPhotos.contains(where: { $0.fileName == photo.fileName })
    let removesDerived = !referencedPhotos.contains(where: { $0.id == photo.id })
    let originalURL = imageURL(for: photo)
    let previewURL = previewURL(for: photo)
    let thumbnailURL = thumbnailURL(for: photo)
    await Task.detached(priority: .utility) {
      let fileManager = FileManager.default
      if removesOriginal { try? fileManager.removeItem(at: originalURL) }
      if removesDerived {
        try? fileManager.removeItem(at: previewURL)
        try? fileManager.removeItem(at: thumbnailURL)
      }
    }.value
    if removesDerived {
      let key = cacheKey(for: photo)
      previewCache.removeObject(forKey: key)
      thumbnailCache.removeObject(forKey: key)
      imageCacheRevision &+= 1
    }
  }

  private func removeExportIfUnreferenced(fileName: String) async {
    let isReferenced = collections.flatMap(\.projects).contains {
      $0.latestExportFileName == fileName
    }
    if !isReferenced {
      let url = exportDirectory.appendingPathComponent(fileName)
      await Task.detached(priority: .utility) {
        try? FileManager.default.removeItem(at: url)
      }.value
    }
  }

#if canImport(UIKit)
  private func persistProjectThumbnail(
    for project: Project,
    usesExisting: Bool = true
  ) async {
    let destination = projectThumbnailURL(for: project)
    guard !project.photos.isEmpty else {
      await Task.detached(priority: .utility) {
        try? FileManager.default.removeItem(at: destination)
      }.value
      projectThumbnailCache.removeObject(forKey: projectThumbnailCacheKey(for: project))
      return
    }
    if usesExisting,
      let persisted = await Task.detached(
        priority: .utility,
        operation: {
          UIImage(contentsOfFile: destination.path)?.preparingForDisplay()
        }
      ).value
    {
      projectThumbnailCache.setObject(
        persisted,
        forKey: projectThumbnailCacheKey(for: project),
        cost: memoryCost(of: persisted)
      )
      imageCacheRevision &+= 1
      return
    }

    let cachedImages = project.photos.map { photo in
      thumbnailCache.object(forKey: cacheKey(for: photo))
        ?? previewCache.object(forKey: cacheKey(for: photo))
    }
    let thumbnailURLs = project.photos.map(thumbnailURL(for:))
    let previewURLs = project.photos.map(previewURL(for:))
    let thumbnail = await Task.detached(priority: .utility) {
      let images = cachedImages.indices.map { index in
        cachedImages[index]
          ?? UIImage(contentsOfFile: thumbnailURLs[index].path)
          ?? UIImage(contentsOfFile: previewURLs[index].path)
      }
      guard images.contains(where: { $0 != nil }),
        let thumbnail = CollageRenderer.renderThumbnail(project: project, images: images),
        let data = thumbnail.pngData()
      else { return nil as UIImage? }
      do {
        try FileManager.default.createDirectory(
          at: destination.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return thumbnail
      } catch {
        return nil
      }
    }.value
    if let thumbnail {
      projectThumbnailCache.setObject(
        thumbnail,
        forKey: projectThumbnailCacheKey(for: project),
        cost: memoryCost(of: thumbnail)
      )
      imageCacheRevision &+= 1
    }
  }

  private func projectThumbnailCacheKey(for project: Project) -> NSString {
    project.id.uuidString as NSString
  }
#endif
}

enum AppError: LocalizedError {
  case invalidImage
  case noPhotos
  case imageMissing
  case persistenceFailed
  case photoLibraryAccessRequired
  case photoLibraryAssetMissing
  case imageTooLarge
  case encodingUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidImage: "One of the selected items is not a readable image."
    case .noPhotos: "Select at least two photos before exporting."
    case .imageMissing: "A source photo is missing. Remove or replace it before exporting."
    case .persistenceFailed: "The project could not be saved. Try again before closing it."
    case .photoLibraryAccessRequired:
      "Allow MixaFrame to read the selected photos in Settings, then try again."
    case .photoLibraryAssetMissing:
      "The original photo is no longer available in the Photos library."
    case .imageTooLarge:
      "This photo strip is too large to render safely. Reduce the resolution or remove some photos."
    case .encodingUnavailable(let format):
      "\(format) encoding is not available on this device. Choose another format."
    }
  }
}

#if canImport(UIKit)
private enum PhotoLibraryOriginalRestorer {
  static func copyOriginal(assetIdentifier: String, to destination: URL) async throws {
    let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    let status =
      currentStatus == .notDetermined
      ? await PHPhotoLibrary.requestAuthorization(for: .readWrite)
      : currentStatus
    guard status == .authorized || status == .limited else {
      throw AppError.photoLibraryAccessRequired
    }

    let results = PHAsset.fetchAssets(
      withLocalIdentifiers: [assetIdentifier],
      options: nil
    )
    guard let asset = results.firstObject else {
      throw AppError.photoLibraryAssetMissing
    }
    let resources = PHAssetResource.assetResources(for: asset)
    guard
      let resource = resources.first(where: { $0.type == .fullSizePhoto })
        ?? resources.first(where: { $0.type == .photo })
        ?? resources.first
    else {
      throw AppError.photoLibraryAssetMissing
    }

    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      PHAssetResourceManager.default().writeData(
        for: resource,
        toFile: destination,
        options: options
      ) { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

extension UIImage {
  var normalizedCGImage: CGImage? {
    if imageOrientation == .up, let cgImage { return cgImage }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }.cgImage
  }
}
#endif
