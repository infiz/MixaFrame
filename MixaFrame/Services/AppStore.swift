import Foundation
import UIKit

@MainActor
final class AppStore: ObservableObject {
  @Published private(set) var projects: [CollageProject] = []
  @Published var alertMessage: String?
  @Published private(set) var imageCacheRevision = 0
  @Published private(set) var imageCacheReloadGeneration = 0

  private let fileManager = FileManager.default
  private let rootDirectoryOverride: URL?
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let previewCache = NSCache<NSString, UIImage>()
  private let thumbnailCache = NSCache<NSString, UIImage>()
  private let collageThumbnailCache = NSCache<NSString, UIImage>()
  private var memoryWarningObserver: NSObjectProtocol?

  init(rootDirectory: URL? = nil) {
    rootDirectoryOverride = rootDirectory
    encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    previewCache.totalCostLimit = 96 * 1024 * 1024
    thumbnailCache.totalCostLimit = 12 * 1024 * 1024
    collageThumbnailCache.totalCostLimit = 16 * 1024 * 1024
    if load() { pruneUnreferencedGeneratedFiles() }
    memoryWarningObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.clearImageCaches() }
    }
  }

  deinit {
    if let memoryWarningObserver {
      NotificationCenter.default.removeObserver(memoryWarningObserver)
    }
  }

  var rootDirectory: URL {
    if let rootDirectoryOverride { return rootDirectoryOverride }
    let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("MixaFrame", isDirectory: true)
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

  func createProject(name: String) -> UUID {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    let project = CollageProject(name: trimmed.isEmpty ? "New Project" : trimmed)
    projects.insert(project, at: 0)
    persist()
    return project.id
  }

  func renameProject(id: UUID, name: String) {
    guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    projects[index].name = trimmed
    projects[index].modifiedAt = Date()
    persist()
  }

  func deleteProjects(at offsets: IndexSet) {
    var removedTasks: [CollageTask] = []
    for index in offsets.sorted(by: >) {
      removedTasks.append(contentsOf: projects.remove(at: index).tasks)
    }
    removedTasks.forEach(cleanUpUnreferencedAssets)
    persist()
  }

  func deleteProject(id: UUID) {
    guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
    let project = projects.remove(at: index)
    project.tasks.forEach(cleanUpUnreferencedAssets)
    persist()
  }

  func deleteTask(projectID: UUID, taskID: UUID) {
    guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }),
      let taskIndex = projects[projectIndex].tasks.firstIndex(where: { $0.id == taskID })
    else { return }
    let task = projects[projectIndex].tasks.remove(at: taskIndex)
    cleanUpUnreferencedAssets(for: task)
    projects[projectIndex].modifiedAt = Date()
    persist()
  }

  func saveTask(_ task: CollageTask) {
    guard let projectIndex = projects.firstIndex(where: { $0.id == task.projectID }) else { return }
    var updated = task
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
    removedPhotos.forEach(cleanUpUnreferencedPhotoAssets)
    if let replacedExportFileName { removeExportIfUnreferenced(fileName: replacedExportFileName) }
    persistCollageThumbnail(for: updated)
    persist()
  }

  func discardUnsavedPhotoFiles(from task: CollageTask) {
    task.photos.forEach(discardPhotoIfUnreferenced)
  }

  func discardPhotoIfUnreferenced(_ photo: CollagePhoto) {
    cleanUpUnreferencedPhotoAssets(photo)
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
    let key = cacheKey(for: photo)
    if let preview = previewCache.object(forKey: key) { return preview }
    if let preview = UIImage(contentsOfFile: previewURL(for: photo).path) {
      previewCache.setObject(preview, forKey: key, cost: memoryCost(of: preview))
      return preview
    }
    if let thumbnail = thumbnailCache.object(forKey: key) { return thumbnail }
    if let thumbnail = UIImage(contentsOfFile: thumbnailURL(for: photo).path) {
      thumbnailCache.setObject(thumbnail, forKey: key, cost: memoryCost(of: thumbnail))
      return thumbnail
    }
    return nil
  }

  func thumbnailImage(for photo: CollagePhoto) -> UIImage? {
    let key = cacheKey(for: photo)
    if let thumbnail = thumbnailCache.object(forKey: key) { return thumbnail }
    if let thumbnail = UIImage(contentsOfFile: thumbnailURL(for: photo).path) {
      thumbnailCache.setObject(thumbnail, forKey: key, cost: memoryCost(of: thumbnail))
      return thumbnail
    }
    if let preview = previewCache.object(forKey: key) { return preview }
    if let preview = UIImage(contentsOfFile: previewURL(for: photo).path) {
      previewCache.setObject(preview, forKey: key, cost: memoryCost(of: preview))
      return preview
    }
    return nil
  }

  func collageThumbnailImage(for task: CollageTask) -> UIImage? {
    let key = collageThumbnailCacheKey(for: task)
    if let cached = collageThumbnailCache.object(forKey: key) { return cached }
    guard let image = UIImage(contentsOfFile: collageThumbnailURL(for: task).path) else {
      return nil
    }
    collageThumbnailCache.setObject(image, forKey: key, cost: memoryCost(of: image))
    return image
  }

  func prepareCollageThumbnails(for tasks: [CollageTask]) {
    for task in tasks where collageThumbnailImage(for: task) == nil {
      persistCollageThumbnail(for: task)
    }
  }

  func persistExport(from temporaryURL: URL, for task: CollageTask) throws -> URL {
    try ensureDirectories()
    if let previousName = task.latestExportFileName {
      try? fileManager.removeItem(at: exportDirectory.appendingPathComponent(previousName))
    }
    let fileName = temporaryURL.lastPathComponent
    let destination = exportDirectory.appendingPathComponent(fileName)
    try? fileManager.removeItem(at: destination)
    try fileManager.copyItem(at: temporaryURL, to: destination)
    return destination
  }

  func importPhotoData(_ data: Data) async throws -> CollagePhoto {
    let id = UUID()
    let fileName = "\(id.uuidString).image"
    try ensureDirectories()
    let originalURL = photoDirectory.appendingPathComponent(fileName)
    let previewURL = previewDirectory.appendingPathComponent("\(id.uuidString).jpg")
    let thumbnailURL = thumbnailDirectory.appendingPathComponent("\(id.uuidString).jpg")
    let asset = try await Task.detached(priority: .userInitiated) {
      try PhotoImagePipeline.importPhoto(
        data: data,
        id: id,
        originalURL: originalURL,
        previewURL: previewURL,
        thumbnailURL: thumbnailURL
      )
    }.value
    cache(asset.images, for: asset.photo)
    return asset.photo
  }

  func prepareDerivedImages(for photos: [CollagePhoto]) async {
    let pending = photos.filter {
      previewCache.object(forKey: cacheKey(for: $0)) == nil
        || thumbnailCache.object(forKey: cacheKey(for: $0)) == nil
    }
    guard !pending.isEmpty else { return }

    for batchStart in stride(from: 0, to: pending.count, by: 2) {
      let batch = Array(pending[batchStart..<min(batchStart + 2, pending.count)])
      let requests = batch.map { photo in
        (
          photo: photo,
          originalURL: imageURL(for: photo),
          previewURL: previewURL(for: photo),
          thumbnailURL: thumbnailURL(for: photo)
        )
      }
      await withTaskGroup(of: (CollagePhoto, DerivedPhotoImages?).self) { group in
        for request in requests {
          group.addTask {
            let images = try? PhotoImagePipeline.prepareDerivedImages(
              originalURL: request.originalURL,
              previewURL: request.previewURL,
              thumbnailURL: request.thumbnailURL
            )
            return (request.photo, images)
          }
        }
        for await (photo, images) in group {
          if let images { cache(images, for: photo) }
        }
      }
    }
  }

  private var databaseURL: URL {
    rootDirectory.appendingPathComponent("projects.json")
  }

  private func ensureDirectories() throws {
    try fileManager.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: thumbnailDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: collageThumbnailDirectory,
      withIntermediateDirectories: true
    )
  }

  private func load() -> Bool {
    do {
      try ensureDirectories()
      guard fileManager.fileExists(atPath: databaseURL.path) else { return true }
      let data = try Data(contentsOf: databaseURL)
      projects = try decoder.decode([CollageProject].self, from: data)
      return true
    } catch {
      alertMessage = "Saved projects could not be loaded: \(error.localizedDescription)"
      return false
    }
  }

  private func pruneUnreferencedGeneratedFiles() {
    let tasks = projects.flatMap(\.tasks)
    let referencedOriginals = Set(tasks.flatMap(\.photos).map(\.fileName))
    let referencedDerived = Set(tasks.flatMap(\.photos).map { "\($0.id.uuidString).jpg" })
    let referencedCollageThumbnails = Set(tasks.map { "\($0.id.uuidString).png" })
    let referencedExports = Set(tasks.compactMap(\.latestExportFileName))

    pruneFiles(in: photoDirectory, keeping: referencedOriginals)
    pruneFiles(in: previewDirectory, keeping: referencedDerived)
    pruneFiles(in: thumbnailDirectory, keeping: referencedDerived)
    pruneFiles(in: collageThumbnailDirectory, keeping: referencedCollageThumbnails)
    pruneFiles(in: exportDirectory, keeping: referencedExports)
  }

  private func pruneFiles(in directory: URL, keeping fileNames: Set<String>) {
    guard
      let files = try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else { return }
    for file in files where !fileNames.contains(file.lastPathComponent) {
      try? fileManager.removeItem(at: file)
    }
  }

  private func persist() {
    do {
      try ensureDirectories()
      try encoder.encode(projects).write(to: databaseURL, options: .atomic)
    } catch {
      alertMessage = "Changes could not be saved: \(error.localizedDescription)"
    }
  }

  private func cleanUpUnreferencedAssets(for task: CollageTask) {
    task.photos.forEach(cleanUpUnreferencedPhotoAssets)
    if let export = task.latestExportFileName { removeExportIfUnreferenced(fileName: export) }
    try? fileManager.removeItem(at: collageThumbnailURL(for: task))
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

  private func cleanUpUnreferencedPhotoAssets(_ photo: CollagePhoto) {
    let referencedPhotos = projects.flatMap(\.tasks).flatMap(\.photos)
    if !referencedPhotos.contains(where: { $0.fileName == photo.fileName }) {
      try? fileManager.removeItem(at: imageURL(for: photo))
    }
    if !referencedPhotos.contains(where: { $0.id == photo.id }) {
      try? fileManager.removeItem(at: previewURL(for: photo))
      try? fileManager.removeItem(at: thumbnailURL(for: photo))
      let key = cacheKey(for: photo)
      previewCache.removeObject(forKey: key)
      thumbnailCache.removeObject(forKey: key)
      imageCacheRevision &+= 1
    }
  }

  private func removeExportIfUnreferenced(fileName: String) {
    let isReferenced = projects.flatMap(\.tasks).contains {
      $0.latestExportFileName == fileName
    }
    if !isReferenced {
      try? fileManager.removeItem(at: exportDirectory.appendingPathComponent(fileName))
    }
  }

  private func persistCollageThumbnail(for task: CollageTask) {
    guard !task.photos.isEmpty else {
      try? fileManager.removeItem(at: collageThumbnailURL(for: task))
      collageThumbnailCache.removeObject(forKey: collageThumbnailCacheKey(for: task))
      return
    }
    let images = task.photos.map { photo in
      previewCache.object(forKey: cacheKey(for: photo))
        ?? thumbnailCache.object(forKey: cacheKey(for: photo))
        ?? UIImage(contentsOfFile: previewURL(for: photo).path)
        ?? UIImage(contentsOfFile: thumbnailURL(for: photo).path)
    }
    guard images.contains(where: { $0 != nil }) else { return }
    guard
      let thumbnail = CollageRenderer.renderThumbnail(task: task, images: images),
      let data = thumbnail.pngData()
    else { return }
    do {
      try ensureDirectories()
      try data.write(to: collageThumbnailURL(for: task), options: .atomic)
      collageThumbnailCache.setObject(
        thumbnail,
        forKey: collageThumbnailCacheKey(for: task),
        cost: memoryCost(of: thumbnail)
      )
      imageCacheRevision &+= 1
    } catch {
      // The saved task remains valid; a missing thumbnail is regenerated when its list is opened.
    }
  }

  private func collageThumbnailCacheKey(for task: CollageTask) -> NSString {
    task.id.uuidString as NSString
  }
}

enum AppError: LocalizedError {
  case invalidImage
  case noPhotos
  case imageMissing
  case imageTooLarge
  case encodingUnavailable(String)

  var errorDescription: String? {
    switch self {
    case .invalidImage: "One of the selected items is not a readable image."
    case .noPhotos: "Select at least two photos before exporting."
    case .imageMissing: "A source photo is missing. Remove or replace it before exporting."
    case .imageTooLarge:
      "This photo strip is too large to render safely. Reduce the resolution or remove some photos."
    case .encodingUnavailable(let format):
      "\(format) encoding is not available on this device. Choose another format."
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
