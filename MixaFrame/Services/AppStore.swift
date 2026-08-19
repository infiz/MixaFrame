import Foundation
import ImageIO
import Photos
import UIKit

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
  @Published private(set) var projects: [CollageProject] = []
  @Published private(set) var savedCustomLayouts: [SavedCustomLayout] = []
  @Published private(set) var isLoaded = false
  @Published var alertMessage: String?
  @Published private(set) var imageCacheRevision = 0
  @Published private(set) var imageCacheReloadGeneration = 0

  private let rootDirectoryOverride: URL?
  private let persistence: AppStorePersistence
  private let previewCache = NSCache<NSString, UIImage>()
  private let thumbnailCache = NSCache<NSString, UIImage>()
  private let collageThumbnailCache = NSCache<NSString, UIImage>()
  private let derivedImagePreparationPermits = AsyncPermitPool(limit: 2)
  private var memoryWarningObserver: NSObjectProtocol?
  private var loadingTask: Task<Void, Never>?

  init(rootDirectory: URL? = nil) {
    rootDirectoryOverride = rootDirectory
    persistence = AppStorePersistence(rootDirectory: rootDirectory ?? Self.defaultRootDirectory())
    previewCache.totalCostLimit = 96 * 1024 * 1024
    thumbnailCache.totalCostLimit = 12 * 1024 * 1024
    collageThumbnailCache.totalCostLimit = 16 * 1024 * 1024
    memoryWarningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.clearImageCaches() }
    }
    loadingTask = Task { [weak self] in
      await self?.loadFromDisk()
    }
  }

  deinit {
    loadingTask?.cancel()
    if let memoryWarningObserver {
      NotificationCenter.default.removeObserver(memoryWarningObserver)
    }
  }

  var rootDirectory: URL {
    if let rootDirectoryOverride { return rootDirectoryOverride }
    return Self.defaultRootDirectory()
  }

  private static func defaultRootDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("MixaFrame", isDirectory: true)
  }

  func waitUntilLoaded() async {
    await loadingTask?.value
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

  var collageThumbnailDirectory: URL {
    rootDirectory.appendingPathComponent("CollageThumbnails", isDirectory: true)
  }

  func project(id: UUID) -> CollageProject? {
    projects.first { $0.id == id }
  }

  func createProject(name: String) async -> UUID {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let project = CollageProject(name: trimmed.isEmpty ? "New Project" : trimmed)
    let previousProjects = projects
    projects.insert(project, at: 0)
    do {
      try await persistence.persistProjects(projects)
    } catch {
      projects = previousProjects
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
    }
    return project.id
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

  func renameProject(id: UUID, name: String) async {
    guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let previousProjects = projects
    projects[index].name = trimmed
    projects[index].modifiedAt = Date()
    do {
      try await persistence.persistProjects(projects)
    } catch {
      projects = previousProjects
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
    }
  }

  func deleteProjects(at offsets: IndexSet) async {
    let previousProjects = projects
    var removedTasks: [CollageTask] = []
    for index in offsets.sorted(by: >) {
      removedTasks.append(contentsOf: projects.remove(at: index).tasks)
    }
    do {
      try await persistence.persistProjects(projects)
    } catch {
      projects = previousProjects
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
      return
    }
    for task in removedTasks { await cleanUpUnreferencedAssets(for: task) }
  }

  func deleteProject(id: UUID) async {
    guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
    let previousProjects = projects
    let project = projects.remove(at: index)
    do {
      try await persistence.persistProjects(projects)
    } catch {
      projects = previousProjects
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
      return
    }
    for task in project.tasks { await cleanUpUnreferencedAssets(for: task) }
  }

  func deleteTask(projectID: UUID, taskID: UUID) async {
    guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
      let taskIndex = projects[projectIndex].tasks.firstIndex(where: { $0.id == taskID })
    else { return }
    let previousProjects = projects
    let task = projects[projectIndex].tasks.remove(at: taskIndex)
    projects[projectIndex].modifiedAt = Date()
    do {
      try await persistence.persistProjects(projects)
    } catch {
      projects = previousProjects
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
      return
    }
    await cleanUpUnreferencedAssets(for: task)
  }

  @discardableResult
  func saveTask(_ task: CollageTask) async -> CollageTask? {
    guard let projectIndex = projects.firstIndex(where: { $0.id == task.projectID }) else {
      alertMessage = "The project for this collage could not be found."
      return nil
    }
    let previousProjects = projects
    var updated = task
    updated.savedLayoutSnapshot = LayoutEngine.savedLayoutSnapshot(for: updated)
    updated.modifiedAt = Date()
    var removedPhotos: [CollagePhoto] = []
    var replacedExportFileName: String?
    if let taskIndex = projects[projectIndex].tasks.firstIndex(where: { $0.id == task.id }) {
      let previousTask = projects[projectIndex].tasks[taskIndex]
      let retainedPhotoIDs = Set(updated.photos.map(\.id))
      removedPhotos = previousTask.photos.filter {
        !retainedPhotoIDs.contains($0.id)
      }
      if previousTask.photos.map(\.id) != updated.photos.map(\.id) {
        updated.invalidateExport()
      }
      let previousExport = previousTask.latestExportFileName
      if previousExport != updated.latestExportFileName { replacedExportFileName = previousExport }
      projects[projectIndex].tasks[taskIndex] = updated
    } else {
      projects[projectIndex].tasks.insert(updated, at: 0)
    }
    projects[projectIndex].modifiedAt = Date()
    do {
      try await persistence.persistProjects(projects)
    } catch {
      projects = previousProjects
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
      return nil
    }
    for photo in removedPhotos { await cleanUpUnreferencedPhotoAssets(photo) }
    if let replacedExportFileName {
      await removeExportIfUnreferenced(fileName: replacedExportFileName)
    }
    await persistCollageThumbnail(for: updated, usesExisting: false)
    return updated
  }

  func discardUnsavedPhotoFiles(from task: CollageTask) async {
    for photo in task.photos { await discardPhotoIfUnreferenced(photo) }
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

  func collageThumbnailURL(for task: CollageTask) -> URL {
    collageThumbnailDirectory.appendingPathComponent("\(task.id.uuidString).png")
  }

  func previewImage(for photo: CollagePhoto) -> UIImage? {
    previewCache.object(forKey: cacheKey(for: photo))
      ?? thumbnailCache.object(forKey: cacheKey(for: photo))
  }

  func thumbnailImage(for photo: CollagePhoto) -> UIImage? {
    thumbnailCache.object(forKey: cacheKey(for: photo))
      ?? previewCache.object(forKey: cacheKey(for: photo))
  }

  func preloadPersistedThumbnails(for photos: [CollagePhoto]) async {
    await prepareDerivedImages(for: photos)
  }

  func collageThumbnailImage(for task: CollageTask) -> UIImage? {
    collageThumbnailCache.object(forKey: collageThumbnailCacheKey(for: task))
  }

  func prepareCollageThumbnails(for tasks: [CollageTask]) async {
    for task in tasks where collageThumbnailImage(for: task) == nil {
      guard !Task.isCancelled else { return }
      await persistCollageThumbnail(for: task)
    }
  }

  func persistExport(from temporaryURL: URL, for task: CollageTask) async throws -> URL {
    let exportDirectory = exportDirectory
    let previousName = task.latestExportFileName
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
      try AppStorePersistence.ensureDirectories(
        at: originalURL.deletingLastPathComponent().deletingLastPathComponent())
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
      try AppStorePersistence.ensureDirectories(
        at: originalURL.deletingLastPathComponent().deletingLastPathComponent())
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

  func originalImage(for photo: CollagePhoto) async -> UIImage? {
    do {
      try await restoreOriginalIfNeeded(for: photo)
    } catch {
      return nil
    }
    let path = imageURL(for: photo).path
    return await Task.detached(priority: .userInitiated) {
      autoreleasepool {
        guard let source = UIImage(contentsOfFile: path) else { return nil }
        return source.preparingForDisplay() ?? source
      }
    }.value
  }

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
      projects = loaded.projects
      savedCustomLayouts = loaded.customLayouts.filter { layout in
        (1...12).contains(layout.photoCount)
          && layout.frames.count == layout.photoCount
          && layout.frames.allSatisfy(\.isValid)
      }
    } catch {
      alertMessage = "Saved projects could not be loaded: \(error.localizedDescription)"
    }
    isLoaded = true
  }

  private func cleanUpUnreferencedAssets(for task: CollageTask) async {
    for photo in task.photos { await cleanUpUnreferencedPhotoAssets(photo) }
    if let export = task.latestExportFileName {
      await removeExportIfUnreferenced(fileName: export)
    }
    let thumbnailURL = collageThumbnailURL(for: task)
    await Task.detached(priority: .utility) {
      try? FileManager.default.removeItem(at: thumbnailURL)
    }.value
    collageThumbnailCache.removeObject(forKey: collageThumbnailCacheKey(for: task))
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

  private func memoryCost(of image: UIImage) -> Int {
    guard let cgImage = image.cgImage else { return 0 }
    return cgImage.bytesPerRow * cgImage.height
  }

  private func clearImageCaches() {
    previewCache.removeAllObjects()
    thumbnailCache.removeAllObjects()
    collageThumbnailCache.removeAllObjects()
    imageCacheRevision &+= 1
    imageCacheReloadGeneration &+= 1
  }

  private func cleanUpUnreferencedPhotoAssets(_ photo: CollagePhoto) async {
    let referencedPhotos = projects.flatMap(\.tasks).flatMap(\.photos)
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
    let isReferenced = projects.flatMap(\.tasks).contains {
      $0.latestExportFileName == fileName
    }
    if !isReferenced {
      let url = exportDirectory.appendingPathComponent(fileName)
      await Task.detached(priority: .utility) {
        try? FileManager.default.removeItem(at: url)
      }.value
    }
  }

  private func persistCollageThumbnail(
    for task: CollageTask,
    usesExisting: Bool = true
  ) async {
    let destination = collageThumbnailURL(for: task)
    guard !task.photos.isEmpty else {
      await Task.detached(priority: .utility) {
        try? FileManager.default.removeItem(at: destination)
      }.value
      collageThumbnailCache.removeObject(forKey: collageThumbnailCacheKey(for: task))
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
      collageThumbnailCache.setObject(
        persisted,
        forKey: collageThumbnailCacheKey(for: task),
        cost: memoryCost(of: persisted)
      )
      imageCacheRevision &+= 1
      return
    }

    let cachedImages = task.photos.map { photo in
      thumbnailCache.object(forKey: cacheKey(for: photo))
        ?? previewCache.object(forKey: cacheKey(for: photo))
    }
    let thumbnailURLs = task.photos.map(thumbnailURL(for:))
    let previewURLs = task.photos.map(previewURL(for:))
    let thumbnail = await Task.detached(priority: .utility) {
      let images = cachedImages.indices.map { index in
        cachedImages[index]
          ?? UIImage(contentsOfFile: thumbnailURLs[index].path)
          ?? UIImage(contentsOfFile: previewURLs[index].path)
      }
      guard images.contains(where: { $0 != nil }),
        let thumbnail = CollageRenderer.renderThumbnail(task: task, images: images),
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
      collageThumbnailCache.setObject(
        thumbnail,
        forKey: collageThumbnailCacheKey(for: task),
        cost: memoryCost(of: thumbnail)
      )
      imageCacheRevision &+= 1
    }
  }

  private func collageThumbnailCacheKey(for task: CollageTask) -> NSString {
    task.id.uuidString as NSString
  }
}

private struct AppStoreLoadResult: @unchecked Sendable {
  let projects: [CollageProject]
  let customLayouts: [SavedCustomLayout]
}

private actor AppStorePersistence {
  private let rootDirectory: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder

  init(rootDirectory: URL) {
    self.rootDirectory = rootDirectory
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
  }

  func ensureDirectories() throws {
    try Self.ensureDirectories(at: rootDirectory)
  }

  nonisolated static func ensureDirectories(at rootDirectory: URL) throws {
    let fileManager = FileManager.default
    for name in ["Photos", "Exports", "Previews", "Thumbnails", "CollageThumbnails"] {
      try fileManager.createDirectory(
        at: rootDirectory.appendingPathComponent(name, isDirectory: true),
        withIntermediateDirectories: true
      )
    }
  }

  func load() throws -> AppStoreLoadResult {
    try ensureDirectories()
    let fileManager = FileManager.default
    let databaseURL = rootDirectory.appendingPathComponent("projects.json")
    let customLayoutsURL = rootDirectory.appendingPathComponent("custom-layouts.json")
    let projects: [CollageProject]
    if fileManager.fileExists(atPath: databaseURL.path) {
      projects = try decoder.decode([CollageProject].self, from: Data(contentsOf: databaseURL))
    } else {
      projects = []
    }
    let customLayouts: [SavedCustomLayout]
    if fileManager.fileExists(atPath: customLayoutsURL.path) {
      customLayouts = try decoder.decode(
        [SavedCustomLayout].self,
        from: Data(contentsOf: customLayoutsURL)
      )
    } else {
      customLayouts = []
    }
    return AppStoreLoadResult(projects: projects, customLayouts: customLayouts)
  }

  func persistProjects(_ projects: [CollageProject]) throws {
    try ensureDirectories()
    let url = rootDirectory.appendingPathComponent("projects.json")
    try encoder.encode(projects).write(to: url, options: .atomic)
  }

  func persistCustomLayouts(_ layouts: [SavedCustomLayout]) throws {
    try ensureDirectories()
    let url = rootDirectory.appendingPathComponent("custom-layouts.json")
    try encoder.encode(layouts).write(to: url, options: .atomic)
  }
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
    case .persistenceFailed: "The collage could not be saved. Try again before closing it."
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
