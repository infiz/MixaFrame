import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import MixaFrame

final class LayoutEngineTests: XCTestCase {
  func testFourKSquareOutput() {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .square
    task.outputMaxDimension = 4096

    XCTAssertEqual(LayoutEngine.outputSize(for: task), CGSize(width: 4096, height: 4096))
  }

  func testEightKOutputIsAvailableForEveryStandardCanvasShape() {
    var task = CollageTask.new(projectID: UUID())
    task.outputMaxDimension = 8192

    task.canvas = .square
    XCTAssertEqual(LayoutEngine.outputSize(for: task), CGSize(width: 8192, height: 8192))
    XCTAssertGreaterThanOrEqual(CollageRenderer.maximumPixelCount, 8192 * 8192)

    task.canvas = .landscape
    XCTAssertEqual(LayoutEngine.outputSize(for: task), CGSize(width: 8192, height: 5461))

    task.canvas = .portrait
    XCTAssertEqual(LayoutEngine.outputSize(for: task), CGSize(width: 6554, height: 8192))
  }

  func testPhotoCropGeometryMatchesAspectFillZoomAndEdgeClamping() {
    let centered = PhotoCropGeometry.normalizedCropRect(
      sourceAspectRatio: 2,
      destinationAspectRatio: 1,
      focalPoint: CGPoint(x: 0.5, y: 0.5),
      zoom: 2
    )
    XCTAssertEqual(centered.minX, 0.375, accuracy: 0.0001)
    XCTAssertEqual(centered.minY, 0.25, accuracy: 0.0001)
    XCTAssertEqual(centered.width, 0.25, accuracy: 0.0001)
    XCTAssertEqual(centered.height, 0.5, accuracy: 0.0001)

    let edge = PhotoCropGeometry.normalizedCropRect(
      sourceAspectRatio: 0.5,
      destinationAspectRatio: 1,
      focalPoint: CGPoint(x: 1, y: 0),
      zoom: 1
    )
    XCTAssertEqual(edge, CGRect(x: 0, y: 0, width: 1, height: 0.5))

    let clampedFocalPoint = PhotoCropGeometry.clampedFocalPoint(
      sourceAspectRatio: 0.5,
      destinationAspectRatio: 1,
      focalPoint: CGPoint(x: 1, y: 0),
      zoom: 1
    )
    XCTAssertEqual(clampedFocalPoint.x, 0.5, accuracy: 0.0001)
    XCTAssertEqual(clampedFocalPoint.y, 0.25, accuracy: 0.0001)
  }

  func testBackgroundChoiceUsesStableExportColors() {
    var task = CollageTask.new(projectID: UUID())

    XCTAssertEqual(task.background, .white)
    XCTAssertEqual(task.backgroundHex, "FFFFFF")

    task.background = .dark

    XCTAssertEqual(task.background, .dark)
    XCTAssertEqual(task.backgroundHex, "111111")
  }

  func testDefaultCollageTitleCanBeReplacedWithoutClearingItFirst() {
    var task = CollageTask.new(projectID: UUID())
    XCTAssertEqual(task.name, CollageTask.defaultName)
    XCTAssertEqual(task.titleForEditing, "")

    task.name = "Summer Trip"
    XCTAssertEqual(task.titleForEditing, "Summer Trip")
  }

  func testExportFileNameUsesLocalTimestampProjectAndCollageNames() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let date = try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: 2026, month: 8, day: 14, hour: 16, minute: 5, second: 9)))
    let localTimeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -7 * 60 * 60))

    let name = CollageRenderer.exportFileName(
      projectName: "Summer Trip",
      collageName: "Beach Day",
      format: .jpeg,
      date: date,
      timeZone: localTimeZone
    )

    XCTAssertEqual(name, "20260814-090509-Summer-Trip-Beach-Day.jpg")

    let sanitized = CollageRenderer.exportFileName(
      projectName: "Family / Summer: 2026",
      collageName: "Kids?*<>|\" 😀",
      format: .png,
      date: date,
      timeZone: localTimeZone
    )
    XCTAssertEqual(sanitized, "20260814-090509-Family-Summer-2026-Kids.png")

    let bounded = CollageRenderer.exportFileName(
      projectName: String(repeating: "é", count: 200),
      collageName: String(repeating: "Album", count: 100),
      format: .webP,
      date: date,
      timeZone: localTimeZone
    )
    XCTAssertLessThan(bounded.utf8.count, 200)
    XCTAssertFalse(bounded.contains("/"))
  }

  func testSubjectDetectionConvertsVisionBoundsToTopLeadingCoordinates() throws {
    let detection = SubjectDetector.detection(for: [
      CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.3),
      CGRect(x: 0.4, y: 0.5, width: 0.3, height: 0.2),
    ])
    let area = try XCTUnwrap(detection.focusArea)

    XCTAssertEqual(area.x, 0.1, accuracy: 0.000_001)
    XCTAssertEqual(area.y, 0.3, accuracy: 0.000_001)
    XCTAssertEqual(area.width, 0.6, accuracy: 0.000_001)
    XCTAssertEqual(area.height, 0.5, accuracy: 0.000_001)
    XCTAssertEqual(detection.focusPoint.x, 0.4, accuracy: 0.000_001)
    XCTAssertEqual(detection.focusPoint.y, 0.55, accuracy: 0.000_001)
  }

  func testEditorDirtyStateTracksOnlyUserEditableChanges() {
    var saved = CollageTask.new(projectID: UUID())
    saved.photos = [CollagePhoto(fileName: "photo", pixelWidth: 1200, pixelHeight: 800)]
    var draft = saved

    draft.modifiedAt = Date().addingTimeInterval(60)
    draft.photos[0].detectedFocusArea = PhotoFocusArea(
      CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4))
    draft.photos[0].hasCompletedFocusDetection = true
    XCTAssertFalse(draft.hasUserChanges(comparedTo: saved))

    draft.spacing += 1
    XCTAssertTrue(draft.hasUserChanges(comparedTo: saved))

    draft = saved
    draft.canvasCornerRadius = 12
    XCTAssertTrue(draft.hasUserChanges(comparedTo: saved))

    draft = saved
    draft.layoutRowWeights = [1.4, 0.6]
    XCTAssertTrue(draft.hasUserChanges(comparedTo: saved))
  }

  func testCanvasCornerSizeDoesNotRoundIndividualPhotoFrames() {
    var task = CollageTask.new(projectID: UUID())
    task.photos = (0..<4).map {
      CollagePhoto(fileName: "photo-\($0)", pixelWidth: 1200, pixelHeight: 900)
    }
    task.canvasCornerRadius = 18

    let standardFrames = LayoutEngine.layoutFrames(
      for: task,
      in: CGSize(width: 1000, height: 1000)
    )
    XCTAssertTrue(
      standardFrames.allSatisfy { $0.cornerRadiusFraction == 0 },
      "The canvas corner size must not round individual photo frames"
    )
  }

  func testPhotoPipelineCreatesBoundedDerivedImagesAndPreservesOriginal() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFramePipelineTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let sourceImage = UIGraphicsImageRenderer(
      size: CGSize(width: 1800, height: 900), format: format
    ).image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 900, height: 900))
      UIColor.systemOrange.setFill()
      context.fill(CGRect(x: 900, y: 0, width: 900, height: 900))
    }
    let sourceData = try XCTUnwrap(sourceImage.jpegData(compressionQuality: 0.95))
    let id = UUID()
    let originalURL = directory.appendingPathComponent("\(id.uuidString).image")
    let previewURL = directory.appendingPathComponent("\(id.uuidString)-preview.jpg")
    let thumbnailURL = directory.appendingPathComponent("\(id.uuidString)-thumbnail.jpg")

    let asset = try PhotoImagePipeline.importPhoto(
      data: sourceData,
      id: id,
      originalURL: originalURL,
      previewURL: previewURL,
      thumbnailURL: thumbnailURL
    )

    XCTAssertEqual(try Data(contentsOf: originalURL), sourceData)
    XCTAssertEqual(asset.photo.pixelWidth, 1800)
    XCTAssertEqual(asset.photo.pixelHeight, 900)
    XCTAssertEqual(maximumPixelDimension(of: asset.images.preview), 1600)
    XCTAssertLessThanOrEqual(
      maximumPixelDimension(of: asset.images.thumbnail),
      PhotoImagePipeline.thumbnailMaximumPixelSize
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: previewURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))

    try FileManager.default.removeItem(at: previewURL)
    let regenerated = try PhotoImagePipeline.prepareDerivedImages(
      originalURL: originalURL,
      previewURL: previewURL,
      thumbnailURL: thumbnailURL
    )
    XCTAssertEqual(maximumPixelDimension(of: regenerated.preview), 1600)
    XCTAssertEqual(try Data(contentsOf: originalURL), sourceData)
  }

  func testPhotoPipelineAppliesSourceOrientation() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFrameOrientationTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let sourceImage = UIGraphicsImageRenderer(
      size: CGSize(width: 1200, height: 800), format: format
    ).image { context in
      UIColor.systemGreen.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
    }
    let cgImage = try XCTUnwrap(sourceImage.cgImage)
    let orientedData = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        orientedData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      ))
    CGImageDestinationAddImage(
      destination,
      cgImage,
      [kCGImagePropertyOrientation: 6] as CFDictionary
    )
    XCTAssertTrue(CGImageDestinationFinalize(destination))

    let id = UUID()
    let asset = try PhotoImagePipeline.importPhoto(
      data: orientedData as Data,
      id: id,
      originalURL: directory.appendingPathComponent("original.image"),
      previewURL: directory.appendingPathComponent("preview.jpg"),
      thumbnailURL: directory.appendingPathComponent("thumbnail.jpg")
    )

    XCTAssertEqual(asset.photo.pixelWidth, 800)
    XCTAssertEqual(asset.photo.pixelHeight, 1200)
    XCTAssertEqual(asset.images.preview.cgImage?.width, 800)
    XCTAssertEqual(asset.images.preview.cgImage?.height, 1200)
  }

  @MainActor
  func testSavingPhotoRemovalCleansOnlyUnreferencedGeneratedAssets() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFrameCleanupTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = AppStore(rootDirectory: directory)
    let projectID = store.createProject(name: "Cleanup")
    let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200)).image { context in
      UIColor.systemPurple.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    }
    let photo = try await store.importPhotoData(
      try XCTUnwrap(image.jpegData(compressionQuality: 0.9)))

    var firstTask = CollageTask.new(projectID: projectID)
    firstTask.photos = [photo]
    store.saveTask(firstTask)
    var secondTask = CollageTask.new(projectID: projectID)
    secondTask.photos = [photo]
    store.saveTask(secondTask)

    let temporaryExport = directory.appendingPathComponent("temporary-export.jpg")
    try Data("export".utf8).write(to: temporaryExport)
    let persistedExport = try store.persistExport(from: temporaryExport, for: firstTask)
    XCTAssertEqual(persistedExport.lastPathComponent, temporaryExport.lastPathComponent)
    firstTask.latestExportFileName = persistedExport.lastPathComponent
    store.saveTask(firstTask)

    firstTask.photos = []
    firstTask.latestExportFileName = nil
    store.saveTask(firstTask)

    XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageURL(for: photo).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.previewURL(for: photo).path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.thumbnailURL(for: photo).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: persistedExport.path))

    secondTask.photos = []
    store.saveTask(secondTask)

    XCTAssertFalse(FileManager.default.fileExists(atPath: store.imageURL(for: photo).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.previewURL(for: photo).path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.thumbnailURL(for: photo).path))
    XCTAssertNil(store.previewImage(for: photo))
    XCTAssertNil(store.thumbnailImage(for: photo))
  }

  @MainActor
  func testSavedCollageThumbnailPersistsAcrossStoreReload() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "MixaFrameSavedThumbnailTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = AppStore(rootDirectory: directory)
    let projectID = store.createProject(name: "Thumbnail Persistence")
    var photos: [CollagePhoto] = []
    for color in [UIColor.systemOrange, UIColor.systemBlue] {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 220)).image {
        context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 220))
      }
      photos.append(
        try await store.importPhotoData(
          try XCTUnwrap(image.jpegData(compressionQuality: 0.9))))
    }

    var task = CollageTask.new(projectID: projectID)
    task.photos = photos
    store.saveTask(task)
    let thumbnailURL = store.collageThumbnailURL(for: task)
    XCTAssertTrue(FileManager.default.fileExists(atPath: thumbnailURL.path))
    XCTAssertNotNil(store.collageThumbnailImage(for: task))

    let reloadedStore = AppStore(rootDirectory: directory)
    let reloadedTask = try XCTUnwrap(reloadedStore.project(id: projectID)?.tasks.first)
    XCTAssertNotNil(reloadedTask.savedLayoutSnapshot)
    reloadedStore.preloadPersistedThumbnails(for: reloadedTask.photos)
    XCTAssertTrue(reloadedTask.photos.allSatisfy { reloadedStore.thumbnailImage(for: $0) != nil })
    XCTAssertTrue(reloadedTask.photos.allSatisfy { reloadedStore.previewImage(for: $0) != nil })
    await reloadedStore.prepareDerivedImages(for: reloadedTask.photos)
    XCTAssertTrue(reloadedTask.photos.allSatisfy { reloadedStore.thumbnailImage(for: $0) != nil })
    XCTAssertTrue(reloadedTask.photos.allSatisfy { reloadedStore.previewImage(for: $0) != nil })
    let reloadedThumbnail = try XCTUnwrap(
      reloadedStore.collageThumbnailImage(for: reloadedTask)
    )
    XCTAssertGreaterThan(reloadedThumbnail.size.width, 0)
    XCTAssertGreaterThan(reloadedThumbnail.size.height, 0)
  }

  func testGridProducesAFrameForEveryPhoto() {
    var task = CollageTask.new(projectID: UUID())
    task.photos = (0..<5).map { index in
      CollagePhoto(fileName: "\(index)", pixelWidth: 1200, pixelHeight: 800)
    }

    let size = LayoutEngine.outputSize(for: task)
    let frames = LayoutEngine.frames(for: task, in: size)

    XCTAssertEqual(frames.count, task.photos.count)
    XCTAssertTrue(frames.allSatisfy { $0.minX >= 0 && $0.minY >= 0 })
    XCTAssertTrue(frames.allSatisfy { $0.maxX <= size.width + 0.5 && $0.maxY <= size.height + 0.5 })
  }

  func testCustomDividerWeightsResizeRowsAndColumnsAndPersist() throws {
    var task = CollageTask.new(projectID: UUID())
    task.photos = (0..<4).map { index in
      CollagePhoto(fileName: "photo-\(index)", pixelWidth: 1200, pixelHeight: 900)
    }
    task.layoutID = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 4).first(where: {
        $0.legacyLayout == .smartGrid
      })
    ).id
    task.spacing = 0
    task.isPhotoOrderManuallyAdjusted = true
    task.layoutRowWeights = [1.5, 0.5]
    task.layoutColumnWeights = [[0.5, 1.5], [1, 1]]

    let size = CGSize(width: 1000, height: 1000)
    let frames = LayoutEngine.layoutFrames(for: task, in: size)
    XCTAssertEqual(frames.count, 4)
    XCTAssertEqual(frames[0].rect.height, 750, accuracy: 0.5)
    XCTAssertEqual(frames[2].rect.height, 250, accuracy: 0.5)
    XCTAssertEqual(frames[0].rect.width, 250, accuracy: 0.5)
    XCTAssertEqual(frames[1].rect.width, 750, accuracy: 0.5)

    let dividers = LayoutEngine.layoutDividers(for: task, in: size)
    XCTAssertEqual(dividers.filter { $0.axis == .horizontal }.count, 1)
    XCTAssertEqual(dividers.filter { $0.axis == .vertical }.count, 2)
    let horizontalDivider = try XCTUnwrap(
      dividers.first(where: { $0.axis == .horizontal })
    )
    XCTAssertEqual(horizontalDivider.midpoint.y, 750, accuracy: 0.5)

    let decoded = try JSONDecoder().decode(
      CollageTask.self,
      from: JSONEncoder().encode(task)
    )
    XCTAssertEqual(decoded.layoutRowWeights, task.layoutRowWeights)
    XCTAssertEqual(decoded.layoutColumnWeights, task.layoutColumnWeights)
  }

  func testCustomDividerWeightsPreserveSlantedMosaicGeometry() throws {
    var task = CollageTask.new(projectID: UUID())
    task.photos = (0..<6).map { index in
      CollagePhoto(fileName: "photo-\(index)", pixelWidth: 1200, pixelHeight: 900)
    }
    task.layoutID = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 6).first(where: { $0.family == .slanted })
    ).id
    task.spacing = 0
    task.isPhotoOrderManuallyAdjusted = true
    let size = CGSize(width: 1000, height: 1000)
    let defaultFrames = LayoutEngine.layoutFrames(for: task, in: size)
    let adjustment = try XCTUnwrap(LayoutEngine.layoutAdjustmentGrid(for: task, in: size))
    XCTAssertEqual(adjustment.rowCounts, [3, 3])

    task.layoutRowWeights = [0.7, 1.3]
    task.layoutColumnWeights = [[1.5, 0.5, 1], [1, 1, 1]]
    let adjustedFrames = LayoutEngine.layoutFrames(for: task, in: size)
    XCTAssertEqual(adjustedFrames.count, 6)
    XCTAssertTrue(adjustedFrames.allSatisfy { $0.normalizedClipPolygon?.count == 4 })
    XCTAssertGreaterThan(adjustedFrames[0].rect.width, defaultFrames[0].rect.width)
    XCTAssertLessThan(adjustedFrames[0].rect.height, defaultFrames[0].rect.height)

    let dividers = LayoutEngine.layoutDividers(for: task, in: size)
    XCTAssertEqual(dividers.count, 5)
    XCTAssertTrue(
      dividers.contains { divider in
        switch divider.axis {
        case .horizontal: abs(divider.start.y - divider.end.y) > 1
        case .vertical: abs(divider.start.x - divider.end.x) > 1
        }
      }
    )
  }

  func testEveryMultiPhotoLayoutOffersAnAdjustableDivider() {
    for photoCount in 2...12 {
      var task = CollageTask.new(projectID: UUID())
      task.photos = (0..<photoCount).map { index in
        CollagePhoto(
          fileName: "photo-\(index)",
          pixelWidth: index.isMultiple(of: 2) ? 1600 : 900,
          pixelHeight: index.isMultiple(of: 2) ? 900 : 1400
        )
      }
      task.isPhotoOrderManuallyAdjusted = true
      for template in LayoutCatalog.templates(photoCount: photoCount) {
        task.layoutID = template.id
        task.layoutRowWeights = nil
        task.layoutColumnWeights = nil
        task.layoutFrameOverrides = nil
        let size = LayoutEngine.outputSize(for: task)
        XCTAssertFalse(
          LayoutEngine.layoutDividers(for: task, in: size).isEmpty,
          "\(template.id) should expose at least one adjustable divider"
        )
      }
    }
  }

  func testNewPartitionLayoutsFillCanvasWithoutOverlap() {
    let size = CGSize(width: 1200, height: 900)
    var testedLayoutCount = 0

    for photoCount in 3...12 {
      var task = CollageTask.new(projectID: UUID())
      task.photos = (0..<photoCount).map { index in
        CollagePhoto(
          fileName: "partition-\(photoCount)-\(index)",
          pixelWidth: index.isMultiple(of: 2) ? 1600 : 1000,
          pixelHeight: index.isMultiple(of: 2) ? 1000 : 1400
        )
      }
      task.spacing = 0
      task.isPhotoOrderManuallyAdjusted = true

      for template in LayoutCatalog.templates(photoCount: photoCount) {
        guard case .partition = template.recipe else { continue }
        testedLayoutCount += 1
        task.layoutID = template.id
        task.clearLayoutCustomization()
        let frames = LayoutEngine.frames(for: task, in: size)

        XCTAssertEqual(frames.count, photoCount, template.id)
        XCTAssertEqual(
          frames.reduce(CGFloat.zero) { $0 + $1.width * $1.height },
          size.width * size.height,
          accuracy: 2,
          template.id
        )
        XCTAssertTrue(
          frames.allSatisfy {
            $0.minX >= -0.01 && $0.minY >= -0.01
              && $0.maxX <= size.width + 0.01 && $0.maxY <= size.height + 0.01
          },
          template.id
        )
        for first in frames.indices {
          for second in frames.indices where second > first {
            let overlap = frames[first].intersection(frames[second])
            XCTAssertTrue(
              overlap.isNull || overlap.width * overlap.height < 0.01,
              "\(template.id) overlaps frames \(first) and \(second)"
            )
          }
        }
        XCTAssertFalse(LayoutEngine.layoutDividers(for: task, in: size).isEmpty, template.id)
      }
    }

    XCTAssertGreaterThan(testedLayoutCount, 25)
  }

  func testCustomCutsResizeAndPersistWithTask() throws {
    var task = CollageTask.new(projectID: UUID())
    task.photos = (0..<3).map {
      CollagePhoto(fileName: "custom-\($0)", pixelWidth: 1200, pixelHeight: 900)
    }
    task.spacing = 0
    task.isPhotoOrderManuallyAdjusted = true
    task.layoutID = LayoutCatalog.customTemplate(photoCount: 3).id
    task.customLayoutFrames = [
      NormalizedLayoutFrame(x: 0, y: 0, width: 0.6, height: 1),
      NormalizedLayoutFrame(x: 0.6, y: 0, width: 0.4, height: 0.5),
      NormalizedLayoutFrame(x: 0.6, y: 0.5, width: 0.4, height: 0.5),
    ]
    task.savedCustomLayoutID = UUID()

    let size = CGSize(width: 1000, height: 1000)
    let frames = LayoutEngine.frames(for: task, in: size)
    XCTAssertEqual(frames[0], CGRect(x: 0, y: 0, width: 600, height: 1000))
    let divider = try XCTUnwrap(
      LayoutEngine.layoutDividers(for: task, in: size).first(where: {
        $0.axis == .vertical && $0.start.y < 1 && $0.end.y > 999
      })
    )
    task.customLayoutFrames = try XCTUnwrap(
      LayoutEngine.adjustedCustomLayoutFrames(
        for: task,
        moving: divider,
        normalizedDelta: 0.1
      )
    )
    let resized = LayoutEngine.frames(for: task, in: size)
    XCTAssertEqual(resized[0].width, 700, accuracy: 0.5)
    XCTAssertEqual(resized[1].minX, 700, accuracy: 0.5)

    let decoded = try JSONDecoder().decode(
      CollageTask.self,
      from: JSONEncoder().encode(task)
    )
    XCTAssertEqual(decoded.customLayoutFrames, task.customLayoutFrames)
    XCTAssertEqual(decoded.savedCustomLayoutID, task.savedCustomLayoutID)
  }

  @MainActor
  func testReusableCustomLayoutsPersistRenameDuplicateAndDelete() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFrameCustomLayouts-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let frames = [
      NormalizedLayoutFrame(x: 0, y: 0, width: 0.5, height: 1),
      NormalizedLayoutFrame(x: 0.5, y: 0, width: 0.5, height: 1),
    ]

    let store = AppStore(rootDirectory: directory)
    let originalID = try XCTUnwrap(
      store.createCustomLayout(name: "Pair", photoCount: 2, frames: frames)
    )
    store.updateCustomLayout(id: originalID, name: "Side Pair")
    let duplicateID = try XCTUnwrap(store.duplicateCustomLayout(id: originalID))
    XCTAssertEqual(store.savedCustomLayouts.count, 2)

    let reloadedStore = AppStore(rootDirectory: directory)
    XCTAssertEqual(reloadedStore.savedCustomLayouts.count, 2)
    XCTAssertEqual(
      reloadedStore.savedCustomLayouts.first(where: { $0.id == originalID })?.name,
      "Side Pair"
    )
    XCTAssertEqual(
      reloadedStore.savedCustomLayouts.first(where: { $0.id == duplicateID })?.frames,
      frames
    )

    reloadedStore.deleteCustomLayout(id: duplicateID)
    let finalStore = AppStore(rootDirectory: directory)
    XCTAssertEqual(finalStore.savedCustomLayouts.map(\.id), [originalID])
  }

  func testIrregularLayoutDividerOverridesResizeAndPersist() throws {
    var task = CollageTask.new(projectID: UUID())
    task.photos = (0..<6).map { index in
      CollagePhoto(fileName: "photo-\(index)", pixelWidth: 1200, pixelHeight: 900)
    }
    task.layoutID = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 6).first(where: { $0.family == .mosaic })
    ).id
    task.spacing = 12
    task.isPhotoOrderManuallyAdjusted = true
    let size = LayoutEngine.outputSize(for: task)
    let originalFrames = LayoutEngine.frames(for: task, in: size)
    let divider = try XCTUnwrap(
      LayoutEngine.layoutDividers(for: task, in: size).first(where: {
        if case .frames = $0.adjustment { return true }
        return false
      })
    )

    task.layoutFrameOverrides = try XCTUnwrap(
      LayoutEngine.adjustedFrameOverrides(for: task, moving: divider, normalizedDelta: 0.06)
    )
    let adjustedFrames = LayoutEngine.frames(for: task, in: size)
    XCTAssertNotEqual(adjustedFrames, originalFrames)
    XCTAssertTrue(
      adjustedFrames.allSatisfy { frame in
        frame.minX >= -0.5 && frame.minY >= -0.5
          && frame.maxX <= size.width + 0.5 && frame.maxY <= size.height + 0.5
      })

    let decoded = try JSONDecoder().decode(
      CollageTask.self,
      from: JSONEncoder().encode(task)
    )
    XCTAssertEqual(decoded.layoutFrameOverrides, task.layoutFrameOverrides)
  }

  func testSavedLayoutGeometrySurvivesDeletedCatalogTemplate() throws {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .portrait
    task.spacing = 14
    task.isPhotoOrderManuallyAdjusted = true
    task.photos = (0..<6).map { index in
      CollagePhoto(
        fileName: "photo-\(index)",
        pixelWidth: index.isMultiple(of: 2) ? 1600 : 1000,
        pixelHeight: index.isMultiple(of: 2) ? 1000 : 1600
      )
    }
    let template = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 6).first(where: { $0.family == .slanted })
    )
    task.layoutID = template.id
    let originalSize = LayoutEngine.outputSize(for: task)
    let originalFrames = LayoutEngine.layoutFrames(for: task, in: originalSize)
    XCTAssertTrue(originalFrames.contains { $0.normalizedClipPolygon != nil })

    var snapshot = try XCTUnwrap(LayoutEngine.savedLayoutSnapshot(for: task))
    snapshot.sourceLayoutID = "n6-removed-from-future-catalog"
    snapshot.sourceLayoutTitle = "Saved Slanted Layout"
    task.layoutID = snapshot.sourceLayoutID
    task.savedLayoutSnapshot = snapshot

    let decoded = try JSONDecoder().decode(
      CollageTask.self,
      from: JSONEncoder().encode(task)
    )
    XCTAssertEqual(LayoutEngine.outputSize(for: decoded), originalSize)
    XCTAssertEqual(LayoutEngine.selectedTemplate(for: decoded).title, "Saved Slanted Layout")
    let restoredFrames = LayoutEngine.layoutFrames(for: decoded, in: originalSize)
    XCTAssertEqual(restoredFrames.count, originalFrames.count)
    for (original, restored) in zip(originalFrames, restoredFrames) {
      XCTAssertEqual(restored.rect.minX, original.rect.minX, accuracy: 0.001)
      XCTAssertEqual(restored.rect.minY, original.rect.minY, accuracy: 0.001)
      XCTAssertEqual(restored.rect.width, original.rect.width, accuracy: 0.001)
      XCTAssertEqual(restored.rect.height, original.rect.height, accuracy: 0.001)
      XCTAssertEqual(restored.normalizedClipPolygon, original.normalizedClipPolygon)
      XCTAssertEqual(restored.rotationDegrees, original.rotationDegrees, accuracy: 0.001)
      XCTAssertEqual(restored.cornerRadiusFraction, original.cornerRadiusFraction, accuracy: 0.001)
      XCTAssertEqual(restored.usesAspectFit, original.usesAspectFit)
    }
    XCTAssertTrue(
      LayoutEngine.layoutDividers(for: decoded, in: originalSize).allSatisfy {
        if case .frames = $0.adjustment { return true }
        return false
      }
    )
  }

  func testSmartGridUsesThreeCompleteRowsForTwelveLandscapePhotos() throws {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .landscape
    task.photos = (0..<12).map { index in
      CollagePhoto(fileName: "landscape-\(index)", pixelWidth: 1500, pixelHeight: 1000)
    }
    task.layoutID = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 12).first(where: { $0.legacyLayout == .smartGrid })
    ).id

    let frames = LayoutEngine.frames(for: task, in: LayoutEngine.outputSize(for: task))
    let rowCounts = Dictionary(grouping: frames, by: \.minY).values.map(\.count).sorted()

    XCTAssertEqual(rowCounts, [4, 4, 4])
  }

  func testSmartGridAdaptsToSourcePhotoAspectRatios() throws {
    func rowCounts(pixelWidth: Int, pixelHeight: Int) throws -> [Int] {
      var task = CollageTask.new(projectID: UUID())
      task.canvas = .landscape
      task.photos = (0..<12).map { index in
        CollagePhoto(
          fileName: "photo-\(index)", pixelWidth: pixelWidth, pixelHeight: pixelHeight)
      }
      task.layoutID = try XCTUnwrap(
        LayoutCatalog.templates(photoCount: 12).first(where: { $0.legacyLayout == .smartGrid })
      ).id
      let frames = LayoutEngine.frames(for: task, in: LayoutEngine.outputSize(for: task))
      return Dictionary(grouping: frames, by: \.minY).values.map(\.count).sorted()
    }

    XCTAssertEqual(try rowCounts(pixelWidth: 1500, pixelHeight: 1000), [4, 4, 4])
    XCTAssertEqual(try rowCounts(pixelWidth: 1000, pixelHeight: 1500), [6, 6])
  }

  func testSmartGridThumbnailUsesTheSameGeometryAsTheCollage() throws {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .landscape
    task.photos = (0..<12).map { index in
      CollagePhoto(
        fileName: "landscape-\(index)",
        pixelWidth: index.isMultiple(of: 2) ? 1800 : 1500,
        pixelHeight: 1000
      )
    }
    let template = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 12).first(where: { $0.legacyLayout == .smartGrid })
    )
    task.layoutID = template.id
    task.layoutRowWeights = [1.2, 0.8, 1]
    task.layoutColumnWeights = [
      [1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 1],
    ]
    let size = LayoutEngine.outputSize(for: task)

    let collageFrames = LayoutEngine.layoutFrames(for: task, in: size)
    let thumbnailFrames = LayoutEngine.previewFrames(
      template: template,
      task: task,
      in: size,
      preservesCurrentAdjustments: true
    )

    XCTAssertEqual(thumbnailFrames, collageFrames)
  }

  func testSmartGridFillsUnevenLastRowAndAssignsBestFitPhoto() throws {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .portrait
    task.photos = [
      CollagePhoto(fileName: "widest", pixelWidth: 2000, pixelHeight: 1000),
      CollagePhoto(fileName: "landscape-1", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(fileName: "landscape-2", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(fileName: "landscape-3", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(fileName: "landscape-4", pixelWidth: 1500, pixelHeight: 1000),
    ]
    task.layoutID = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 5).first(where: { $0.legacyLayout == .smartGrid })
    ).id

    let size = LayoutEngine.outputSize(for: task)
    let frames = LayoutEngine.frames(for: task, in: size)
    let rowCounts = Dictionary(grouping: frames, by: \.minY).values.map(\.count).sorted()
    let visualOrder = LayoutEngine.photoIndicesInVisualOrder(for: task, in: size)

    XCTAssertEqual(rowCounts, [1, 2, 2])
    XCTAssertEqual(frames[0].width, size.width, accuracy: 0.5)
    XCTAssertEqual(visualOrder.last, 0)
  }

  func testManualPhotoOrderOverridesSmartGridBestFitAssignment() throws {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .portrait
    task.photos = [
      CollagePhoto(fileName: "widest", pixelWidth: 2000, pixelHeight: 1000),
      CollagePhoto(fileName: "landscape-1", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(fileName: "landscape-2", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(fileName: "landscape-3", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(fileName: "landscape-4", pixelWidth: 1500, pixelHeight: 1000),
    ]
    task.layoutID = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 5).first(where: { $0.legacyLayout == .smartGrid })
    ).id
    task.isPhotoOrderManuallyAdjusted = true

    let size = LayoutEngine.outputSize(for: task)
    let frames = LayoutEngine.frames(for: task, in: size)

    XCTAssertLessThan(frames[0].width, size.width)
    XCTAssertEqual(frames[4].width, size.width, accuracy: 0.5)
    XCTAssertEqual(LayoutEngine.photoIndicesInVisualOrder(for: task, in: size), Array(0..<5))
  }

  func testResetPhotosForAutomaticFitRestoresDetectedFocusAndZoom() throws {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .portrait
    task.photos = [
      CollagePhoto(
        fileName: "wide", pixelWidth: 2000, pixelHeight: 1000, focalX: 0.1, focalY: 0.9,
        focusSource: .manual,
        detectedFocusArea: PhotoFocusArea(CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.4)),
        zoom: 3
      ),
      CollagePhoto(
        fileName: "portrait", pixelWidth: 1000, pixelHeight: 2000, focalX: 0.8, focalY: 0.1,
        focusSource: .manual, zoom: 2
      ),
    ]
    task.layoutID = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 2).first(where: { $0.legacyLayout == .smartGrid })
    ).id
    task.isPhotoOrderManuallyAdjusted = true

    task.resetPhotosForAutomaticFit()

    XCTAssertTrue(task.usesAutomaticPhotoArrangement)
    XCTAssertEqual(task.photos[0].focalX, 0.7, accuracy: 0.0001)
    XCTAssertEqual(task.photos[0].focalY, 0.4, accuracy: 0.0001)
    XCTAssertEqual(task.photos[1].focalX, 0.5, accuracy: 0.0001)
    XCTAssertEqual(task.photos[1].focalY, 0.5, accuracy: 0.0001)
    XCTAssertTrue(task.photos.allSatisfy { $0.focusSource == .automatic })
    XCTAssertTrue(task.photos.allSatisfy { $0.zoom == nil })
  }

  func testBestFitPlacementIsIndependentOfPickerOrder() throws {
    let highResolutionID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000005"))
    let photos = [
      CollagePhoto(
        id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
        fileName: "small-1", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(
        id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002")),
        fileName: "small-2", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(
        id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
        fileName: "small-3", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(
        id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000004")),
        fileName: "small-4", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(
        id: highResolutionID,
        fileName: "large", pixelWidth: 6000, pixelHeight: 4000),
    ]

    func placements(for photos: [CollagePhoto]) throws -> [UUID: CGRect] {
      var task = CollageTask.new(projectID: UUID())
      task.canvas = .portrait
      task.photos = photos
      task.layoutID = try XCTUnwrap(
        LayoutCatalog.templates(photoCount: 5).first(where: { $0.legacyLayout == .smartGrid })
      ).id
      let size = LayoutEngine.outputSize(for: task)
      let frames = LayoutEngine.frames(for: task, in: size)
      return Dictionary(uniqueKeysWithValues: zip(task.photos, frames).map { ($0.id, $1) })
    }

    let forward = try placements(for: photos)
    let reversed = try placements(for: Array(photos.reversed()))

    for photo in photos {
      XCTAssertEqual(forward[photo.id], reversed[photo.id])
    }
    let highResolutionFrame = try XCTUnwrap(forward[highResolutionID])
    let regularFrame = try XCTUnwrap(forward[photos[0].id])
    XCTAssertGreaterThan(highResolutionFrame.width, regularFrame.width)
  }

  func testBestFitPlacementAppliesToFeaturedLayouts() throws {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .landscape
    task.photos = [
      CollagePhoto(fileName: "portrait", pixelWidth: 1200, pixelHeight: 2400),
      CollagePhoto(fileName: "square", pixelWidth: 1800, pixelHeight: 1800),
      CollagePhoto(fileName: "landscape", pixelWidth: 2400, pixelHeight: 1200),
    ]
    task.layoutID = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 3).first(where: { $0.legacyLayout == .featuredTop })
    ).id

    let size = LayoutEngine.outputSize(for: task)
    let frames = LayoutEngine.frames(for: task, in: size)

    XCTAssertEqual(frames[2].minY, 0, accuracy: 0.5)
    XCTAssertEqual(frames[2].width, size.width, accuracy: 0.5)
  }

  func testStripLayoutsAreRemovedAndLegacyStripTasksUseSmartGrid() throws {
    var task = CollageTask.new(projectID: UUID())
    task.layoutID = "n2-natural-vertical"
    task.layout = .verticalStrip
    task.photos = [
      CollagePhoto(fileName: "one", pixelWidth: 1200, pixelHeight: 800),
      CollagePhoto(fileName: "two", pixelWidth: 800, pixelHeight: 1200),
    ]

    XCTAssertFalse(LayoutFamily.browserCases.contains(where: { $0.rawValue == "strip" }))
    XCTAssertFalse(
      (2...12).flatMap { LayoutCatalog.templates(photoCount: $0) }.contains(where: {
        switch $0.recipe {
        case .strip, .naturalVerticalStrip: true
        default: false
        }
      })
    )
    XCTAssertEqual(LayoutCatalog.selectedTemplate(for: task).id, "n2-smart-grid")
  }

  func testGridUsesPhotoCountSpecificFullWidthRowPatterns() throws {
    func rowPatterns(photoCount: Int) -> [[Int]] {
      LayoutCatalog.templates(photoCount: photoCount).compactMap { template in
        guard template.family == .grid,
          case .adaptiveGrid(let counts) = template.recipe
        else { return nil }
        return counts
      }
    }

    XCTAssertTrue(rowPatterns(photoCount: 8).contains([3, 2, 3]))
    XCTAssertTrue(rowPatterns(photoCount: 8).contains([2, 3, 3]))
    XCTAssertTrue(rowPatterns(photoCount: 11).contains([4, 4, 3]))
    XCTAssertTrue(rowPatterns(photoCount: 11).contains([4, 3, 4]))

    for photoCount in 2...12 {
      let patterns = rowPatterns(photoCount: photoCount)
      XCTAssertFalse(patterns.isEmpty)
      XCTAssertTrue(patterns.allSatisfy { $0.reduce(0, +) == photoCount })

      var task = CollageTask.new(projectID: UUID())
      task.photos = (0..<photoCount).map {
        CollagePhoto(fileName: "photo-\($0)", pixelWidth: 1200, pixelHeight: 900)
      }
      task.spacing = 0
      for template in LayoutCatalog.templates(photoCount: photoCount)
      where template.family == .grid {
        task.layoutID = template.id
        let size = CGSize(width: 1200, height: 1600)
        let frames = LayoutEngine.frames(for: task, in: size)
        let rows = Dictionary(grouping: frames, by: { round($0.minY * 100) / 100 })
        XCTAssertEqual(frames.count, photoCount)
        for row in rows.values {
          XCTAssertEqual(row.map(\.width).reduce(0, +), size.width, accuracy: 0.5)
        }
      }
    }
  }

  func testAdaptiveGridRetainsMostOfMixedAspectRatioPhotos() throws {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .square
    task.photos = [
      CollagePhoto(fileName: "wide", pixelWidth: 2000, pixelHeight: 1000),
      CollagePhoto(fileName: "tall", pixelWidth: 1000, pixelHeight: 2000),
      CollagePhoto(fileName: "landscape", pixelWidth: 1500, pixelHeight: 1000),
      CollagePhoto(fileName: "portrait", pixelWidth: 1000, pixelHeight: 1500),
    ]
    let template = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 4).first(where: { $0.id == "n4-grid-rows-2-2" })
    )

    let fit = LayoutEngine.photoFit(for: template, task: task)

    XCTAssertGreaterThan(fit.averageVisibleFraction, 0.8)
    XCTAssertGreaterThan(fit.minimumVisibleFraction, 0.8)
  }

  func testOfferedLayoutsMeetPhotoVisibilityGoalAndRecommendationIsBestFit() {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .landscape
    task.photos = (0..<8).map { index in
      CollagePhoto(
        fileName: "landscape-\(index)",
        pixelWidth: index.isMultiple(of: 3) ? 1800 : 1500,
        pixelHeight: 1000
      )
    }

    var offeredLayouts: [CollageLayoutTemplate] = []
    for family in LayoutFamily.browserCases {
      offeredLayouts += LayoutEngine.fittingLayoutSamples(
        family: family,
        task: task,
        mainPhotoCount: 1
      )
    }

    XCTAssertFalse(offeredLayouts.isEmpty)
    for template in offeredLayouts {
      let fit = LayoutEngine.photoFit(for: template, task: task)
      XCTAssertGreaterThanOrEqual(fit.averageVisibleFraction, 0.68, template.title)
      XCTAssertGreaterThanOrEqual(fit.minimumVisibleFraction, 0.42, template.title)
    }

    let recommendation = LayoutEngine.recommendedTemplate(for: task)
    let recommendedFit = LayoutEngine.photoFit(for: recommendation, task: task)
    XCTAssertGreaterThanOrEqual(recommendedFit.averageVisibleFraction, 0.68)
    XCTAssertGreaterThanOrEqual(recommendedFit.minimumVisibleFraction, 0.42)
    XCTAssertEqual(recommendation.family, .grid)
  }

  func testSmartGridIsTheFirstOfferedGridOption() throws {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .landscape
    task.photos = (0..<8).map {
      CollagePhoto(fileName: "photo-\($0)", pixelWidth: 1500, pixelHeight: 1000)
    }

    let gridLayouts = LayoutEngine.fittingLayoutSamples(
      family: .grid,
      task: task,
      mainPhotoCount: 1
    )

    XCTAssertEqual(try XCTUnwrap(gridLayouts.first).legacyLayout, .smartGrid)
  }

  func testAutomaticRecommendationOptimizesCanvasAndLayoutTogether() {
    var task = CollageTask.new(projectID: UUID())
    task.canvas = .landscape
    task.photos = (0..<2).map {
      CollagePhoto(fileName: "landscape-\($0)", pixelWidth: 1500, pixelHeight: 1000)
    }

    let recommendation = LayoutEngine.recommendedCanvasAndTemplate(for: task)
    task.canvas = recommendation.canvas
    let fit = LayoutEngine.photoFit(for: recommendation.template, task: task)

    XCTAssertNotEqual(recommendation.canvas, .landscape)
    XCTAssertGreaterThan(fit.averageVisibleFraction, 0.9)
    XCTAssertGreaterThan(fit.minimumVisibleFraction, 0.9)
  }

  func testEveryLayoutProducesValidFrames() {
    var task = CollageTask.new(projectID: UUID())
    task.outputMaxDimension = 1920
    task.photos = (0..<7).map { index in
      CollagePhoto(fileName: "photo-\(index)", pixelWidth: 1200, pixelHeight: 900)
    }

    for layout in CollageLayout.allCases {
      task.layout = layout
      let size = LayoutEngine.outputSize(for: task)
      let frames = LayoutEngine.frames(for: task, in: size)

      XCTAssertEqual(frames.count, task.photos.count, "Wrong frame count for \(layout.title)")
      XCTAssertTrue(
        frames.allSatisfy { $0.width > 0 && $0.height > 0 }, "Empty frame in \(layout.title)")
      XCTAssertTrue(
        frames.allSatisfy { $0.minX >= 0 && $0.minY >= 0 }, "Negative frame in \(layout.title)")
      XCTAssertTrue(
        frames.allSatisfy { $0.maxX <= size.width + 0.5 && $0.maxY <= size.height + 0.5 },
        "Out-of-bounds frame in \(layout.title)"
      )
    }
  }

  func testCatalogContainsOnlyDistinctCompatibleLayouts() {
    var total = 0

    for photoCount in 1...12 {
      let layouts = LayoutCatalog.templates(photoCount: photoCount)
      let expectedCount = LayoutCatalog.targetCounts[photoCount - 1]
      total += layouts.count

      XCTAssertEqual(layouts.count, expectedCount, "Wrong catalog size for \(photoCount) photos")
      XCTAssertEqual(Set(layouts.map(\.id)).count, layouts.count, "Duplicate ID for \(photoCount)")
      XCTAssertEqual(
        Set(layouts.map(\.recipe)).count,
        layouts.count,
        "Duplicate recipe for \(photoCount)"
      )

      if photoCount >= 2 {
        XCTAssertEqual(
          Set(layouts.map { $0.family.browserFamily }),
          Set(LayoutFamily.browserCases),
          "Missing family for \(photoCount) photos"
        )
      }
    }

    XCTAssertEqual(total, LayoutCatalog.totalTemplateCount)
  }

  func testCatalogOmitsCloseLayoutVariantsAndMigratesTheirSelections() {
    let singlePhotoLayouts = LayoutCatalog.templates(photoCount: 1)
    XCTAssertEqual(
      Set(singlePhotoLayouts.map(\.id)),
      ["n1-full-bleed", "n1-gallery-matte"]
    )
    XCTAssertEqual(
      LayoutCatalog.compatibleTemplate(id: "n1-poster-matte", photoCount: 1)?.id,
      "n1-gallery-matte"
    )

    let expectedSlantedTitles: [Int: Set<String>] = [
      2: ["Gentle Cascade", "Gentle Rise", "Bold Cascade", "Zigzag Mosaic"],
      3: [
        "Gentle Cascade", "Gentle Rise", "Bold Cascade", "Zigzag Mosaic", "Lead Mosaic",
        "Finale Mosaic",
      ],
    ]
    for photoCount in 2...12 {
      let layouts = LayoutCatalog.templates(photoCount: photoCount)
      let mondrianSeeds = Set(
        layouts.compactMap { layout -> Int? in
          guard case .mosaic(let seed) = layout.recipe else { return nil }
          return seed
        })
      XCTAssertEqual(mondrianSeeds, [0, 1, 5, 6])
      XCTAssertFalse(layouts.contains(where: { $0.title == "Bold Brick" }))

      if let expectedTitles = expectedSlantedTitles[photoCount] {
        XCTAssertEqual(
          Set(layouts.filter { $0.family == .slanted }.map(\.title)),
          expectedTitles
        )
      }
    }

    XCTAssertNil(LayoutCatalog.template(id: "n3-featured-corner-anchor-main-2", photoCount: 3))
    XCTAssertNil(LayoutCatalog.template(id: "n4-featured-corner-anchor-main-3", photoCount: 4))
    XCTAssertNil(LayoutCatalog.template(id: "n4-featured-dual-anchor-main-3", photoCount: 4))
    for photoCount in 5...6 {
      for mainCount in 1...3 {
        XCTAssertNil(
          LayoutCatalog.template(
            id: "n\(photoCount)-featured-center-window-main-\(mainCount)",
            photoCount: photoCount
          ))
      }
    }
    XCTAssertNotNil(LayoutCatalog.template(id: "n7-featured-center-window-main-1", photoCount: 7))

    XCTAssertEqual(
      LayoutCatalog.compatibleTemplate(id: "n5-featured-center-window-main-2", photoCount: 5)?.id,
      "n5-editorial-three-row-center-main-2"
    )
    XCTAssertEqual(
      LayoutCatalog.compatibleTemplate(id: "n8-mondrian-2", photoCount: 8)?.id,
      "n8-mondrian-6"
    )
    XCTAssertEqual(
      LayoutCatalog.compatibleTemplate(id: "n8-brick-bold", photoCount: 8)?.id,
      "n8-brick-soft"
    )
  }

  func testSlantedLayoutsReplaceCreativeLayoutsForEveryPhotoCount() {
    for photoCount in 1...12 {
      let layouts = LayoutCatalog.templates(photoCount: photoCount)
      XCTAssertFalse(
        layouts.contains(where: {
          switch $0.recipe {
          case .cards, .bubbles: true
          default: false
          }
        }),
        "Creative card and bubble layouts should not be offered"
      )

      guard photoCount > 1 else {
        XCTAssertFalse(layouts.contains(where: { $0.family == .slanted }))
        continue
      }
      let expectedCount = photoCount == 2 ? 4 : (photoCount == 3 ? 6 : 9)
      XCTAssertEqual(layouts.filter { $0.family == .slanted }.count, expectedCount)
      var task = CollageTask.new(projectID: UUID())
      task.photos = (0..<photoCount).map {
        CollagePhoto(fileName: "photo-\($0)", pixelWidth: 1200, pixelHeight: 900)
      }
      let slantedLayouts = layouts.filter { $0.family == .slanted }
      for layout in slantedLayouts {
        guard case .slantedMosaic(let rowCounts, _, _, _, _) = layout.recipe else {
          XCTFail("Slanted layout should use a mosaic recipe")
          continue
        }
        XCTAssertEqual(rowCounts.reduce(0, +), photoCount)
        if photoCount >= 3 {
          XCTAssertGreaterThan(rowCounts.count, 1, "Slanted layouts should span multiple rows")
          XCTAssertTrue(rowCounts.contains(where: { $0 > 1 }))
        }
        if photoCount >= 4 {
          XCTAssertTrue(
            rowCounts.allSatisfy { $0 >= 2 },
            "Slanted mosaics should avoid single-photo rows when pairs are possible"
          )
        }
        task.layoutID = layout.id
        let frames = LayoutEngine.layoutFrames(
          for: task,
          in: CGSize(width: 1200, height: 1600)
        )
        XCTAssertEqual(frames.count, photoCount)
        XCTAssertTrue(
          frames.allSatisfy { frame in
            guard let polygon = frame.normalizedClipPolygon else { return false }
            return polygon.count == 4
              && polygon.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
          })
      }
    }
  }

  func testHeroAndEditorialCatalogContainsOnlyDistinctStructures() throws {
    for photoCount in 2...12 {
      let layouts = LayoutCatalog.templates(photoCount: photoCount)
      let heroLayouts = layouts.filter { $0.family == .hero }
      let maximumMainCount = min(3, photoCount - 1)
      let anchorMainCount = min(3, max(0, photoCount - 2))
      let featuredLayoutCount =
        (photoCount >= 3 ? anchorMainCount : 0)
        + (photoCount >= 4 ? anchorMainCount : 0)
        + (photoCount >= 7 ? maximumMainCount : 0)
      XCTAssertEqual(
        heroLayouts.count,
        4 * maximumMainCount + featuredLayoutCount
      )
      let heroStructures = Set(
        heroLayouts.compactMap { template -> String? in
          switch template.recipe {
          case .hero(let edge, _):
            return "\(edge)-1"
          case .multiHero(let edge, let mainCount, _):
            return "\(edge)-\(mainCount)"
          case .partition(let style, let mainCount):
            return "\(style.rawValue)-\(mainCount ?? 0)"
          default:
            return nil
          }
        })
      XCTAssertEqual(heroStructures.count, heroLayouts.count)

      let editorialLayouts = layouts.filter { $0.family == .editorial }
      XCTAssertEqual(editorialLayouts.count, photoCount >= 5 ? 18 : 0)
      let editorialStructures = Set(
        editorialLayouts.compactMap { template -> String? in
          guard case .bands(let axis, let counts, let weights) = template.recipe else { return nil }
          let mainIndex = weights.indices.max(by: { weights[$0] < weights[$1] }) ?? 0
          return "\(axis)-\(counts.count)-\(mainIndex)-\(counts[mainIndex])"
        })
      XCTAssertEqual(editorialStructures.count, editorialLayouts.count)

      if photoCount >= 3 {
        var migratedTask = CollageTask.new(projectID: UUID())
        migratedTask.photos = (0..<photoCount).map { index in
          CollagePhoto(fileName: "photo-\(index)", pixelWidth: 1200, pixelHeight: 900)
        }
        migratedTask.layoutID = "n\(photoCount)-editorial-right-main-2"
        XCTAssertEqual(LayoutEngine.mainPhotoCount(for: migratedTask), 2)
        XCTAssertEqual(LayoutEngine.selectedTemplate(for: migratedTask).family, .hero)
      }
    }
  }

  func testEveryHeroAndEditorialTemplateCanChangeMainPhotoCount() throws {
    for photoCount in 2...12 {
      var task = CollageTask.new(projectID: UUID())
      task.photos = (0..<photoCount).map { index in
        CollagePhoto(fileName: "photo-\(index)", pixelWidth: 1200, pixelHeight: 900)
      }
      task.isPhotoOrderManuallyAdjusted = true
      task.spacing = 0
      let maximumMainCount = min(3, photoCount - 1)
      let templates = LayoutCatalog.templates(photoCount: photoCount).filter {
        $0.family == .hero || $0.family == .editorial
      }

      for template in templates {
        task.layoutID = template.id
        for mainCount in 1...maximumMainCount {
          task.mainPhotoCount = mainCount
          let resolvedTemplate = LayoutEngine.selectedTemplate(for: task)
          switch resolvedTemplate.recipe {
          case .multiHero(_, let resolvedMainCount, _):
            XCTAssertEqual(
              resolvedMainCount,
              mainCount,
              "\(template.id) did not apply \(mainCount) main photos"
            )
          case .bands(_, let counts, let weights):
            let mainBand = weights.indices.max(by: { weights[$0] < weights[$1] }) ?? 0
            XCTAssertEqual(
              counts[mainBand],
              mainCount,
              "\(template.id) did not apply \(mainCount) main photos"
            )
          case .partition(_, let resolvedMainCount):
            XCTAssertEqual(
              resolvedMainCount,
              mainCount,
              "\(template.id) did not apply \(mainCount) main photos"
            )
          default:
            XCTFail("\(template.id) does not expose an adjustable main-photo recipe")
          }
          XCTAssertEqual(
            LayoutEngine.layoutFrames(for: task, in: CGSize(width: 1200, height: 1200)).count,
            photoCount
          )
        }
      }
    }
  }

  func testHeroAndEditorialSamplesFollowSelectedMainPhotoCount() throws {
    for photoCount in 2...12 {
      for mainCount in 1...min(3, photoCount - 1) {
        let featuredSamples = LayoutEngine.layoutSamples(
          family: .hero,
          photoCount: photoCount,
          mainPhotoCount: mainCount
        )
        let featuredStyleCount =
          (photoCount >= 3 && photoCount - mainCount > 1 ? 1 : 0)
          + (photoCount >= 4 && photoCount - mainCount > 1 ? 1 : 0)
          + (photoCount >= 7 ? 1 : 0)
        XCTAssertEqual(
          featuredSamples.count,
          4 + featuredStyleCount + (photoCount >= 5 ? 6 : 0)
        )
        XCTAssertTrue(
          featuredSamples.allSatisfy { LayoutEngine.mainPhotoCount(for: $0) == mainCount }
        )

        for template in featuredSamples {
          let matching = try XCTUnwrap(
            LayoutEngine.matchingMainPhotoTemplate(
              for: template,
              photoCount: photoCount,
              mainPhotoCount: mainCount
            )
          )
          XCTAssertEqual(LayoutEngine.mainPhotoCount(for: matching), mainCount)
        }
      }
    }
  }

  func testFeaturedBrowserShowsEveryMainCountWithoutDuplicateGeometry() {
    for photoCount in 2...12 {
      var task = CollageTask.new(projectID: UUID())
      task.canvas = .square
      task.spacing = 0
      task.isPhotoOrderManuallyAdjusted = true
      task.photos = (0..<photoCount).map { index in
        CollagePhoto(
          fileName: "photo-\(index)",
          pixelWidth: index.isMultiple(of: 2) ? 1600 : 1000,
          pixelHeight: index.isMultiple(of: 2) ? 1000 : 1600
        )
      }

      let layouts = LayoutEngine.fittingLayoutSamples(family: .hero, task: task)
      XCTAssertEqual(
        Set(layouts.compactMap(LayoutEngine.mainPhotoCount(for:))),
        Set(1...min(3, photoCount - 1))
      )

      var geometryKeys: Set<String> = []
      for template in layouts {
        task.layoutID = template.id
        task.mainPhotoCount = LayoutEngine.mainPhotoCount(for: template)
        let size = LayoutEngine.outputSize(for: task)
        let frameKeys = LayoutEngine.layoutFrames(for: task, in: size).map { frame in
          let values = [
            frame.rect.minX / size.width,
            frame.rect.minY / size.height,
            frame.rect.width / size.width,
            frame.rect.height / size.height,
          ]
          return values.map { String(format: "%.4f", Double($0)) }.joined(separator: ",")
        }
        let key = frameKeys.sorted().joined(separator: "|")
        XCTAssertTrue(
          geometryKeys.insert(key).inserted,
          "Featured browser contains duplicate geometry for \(template.id)"
        )
      }
    }
  }

  func testEveryCatalogLayoutProducesValidFrames() {
    for photoCount in 1...12 {
      var task = CollageTask.new(projectID: UUID())
      task.outputMaxDimension = 1024
      task.photos = (0..<photoCount).map { index in
        CollagePhoto(
          fileName: "photo-\(index)",
          pixelWidth: index.isMultiple(of: 2) ? 1200 : 900,
          pixelHeight: index.isMultiple(of: 2) ? 900 : 1200
        )
      }

      for layout in LayoutCatalog.templates(photoCount: photoCount) {
        task.layoutID = layout.id
        let size = LayoutEngine.outputSize(for: task)
        let frames = LayoutEngine.layoutFrames(for: task, in: size)

        XCTAssertEqual(
          frames.count,
          photoCount,
          "Wrong frame count for \(photoCount)-photo \(layout.title)"
        )
        XCTAssertTrue(
          frames.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 },
          "Empty frame in \(layout.title)"
        )
        XCTAssertTrue(
          frames.allSatisfy { $0.rect.minX >= -0.5 && $0.rect.minY >= -0.5 },
          "Negative frame in \(layout.title)"
        )
        XCTAssertTrue(
          frames.allSatisfy {
            $0.rect.maxX <= size.width + 0.5 && $0.rect.maxY <= size.height + 0.5
          },
          "Out-of-bounds frame in \(layout.title)"
        )
      }
    }
  }

  func testLayoutSelectionPersistsThroughCoding() throws {
    var task = CollageTask.new(projectID: UUID())
    task.photos = (0..<6).map {
      CollagePhoto(fileName: "photo-\($0)", pixelWidth: 1200, pixelHeight: 900)
    }
    task.layoutID = try XCTUnwrap(
      LayoutCatalog.templates(photoCount: 6).first(where: { $0.family == .mosaic })
    ).id
    task.canvasCornerRadius = 14

    let encoded = try JSONEncoder().encode(task)
    let decoded = try JSONDecoder().decode(CollageTask.self, from: encoded)

    XCTAssertEqual(decoded.layoutID, task.layoutID)
    XCTAssertEqual(decoded.canvasCornerRadius, 14)
    XCTAssertEqual(LayoutEngine.selectedTemplate(for: decoded).id, task.layoutID)
  }

  func testCanvasCornersAreAppliedToTheRenderedCanvas() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFrameCanvasCornerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceNames = ["first.image", "second.image"]
    for (name, color) in zip(sourceNames, [UIColor.systemPink, UIColor.systemTeal]) {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
      }
      try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }

    var task = CollageTask.new(projectID: UUID())
    task.outputMaxDimension = 512
    task.outputFormat = .png
    task.canvasCornerRadius = 50
    task.spacing = 0
    task.photos = sourceNames.map {
      CollagePhoto(fileName: $0, pixelWidth: 100, pixelHeight: 100)
    }

    let rendered = try CollageRenderer.render(task: task, photoDirectory: directory)
    XCTAssertLessThan(alphaValue(in: rendered, at: .zero), 0.05)
    XCTAssertGreaterThan(alphaValue(in: rendered, at: CGPoint(x: 256, y: 256)), 0.95)
  }

  func testRendererExportsAllRequiredFormats() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFrameTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceNames = ["red.image", "blue.image"]
    for (name, color) in zip(sourceNames, [UIColor.red, UIColor.blue]) {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100)).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
      }
      try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }

    var task = CollageTask.new(projectID: UUID())
    task.outputMaxDimension = 512
    task.photos = sourceNames.map {
      CollagePhoto(fileName: $0, pixelWidth: 160, pixelHeight: 100)
    }

    for format in OutputFormat.allCases {
      task.outputFormat = format
      let result = try CollageRenderer.export(task: task, photoDirectory: directory)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: result.path), "Missing \(format.title) export")
      XCTAssertGreaterThan(try Data(contentsOf: result).count, 100)
      try? FileManager.default.removeItem(at: result)
    }
  }

  func testFreeExportIncludesWatermarkAndPremiumRenderDoesNot() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFrameWatermarkTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceNames = ["first.image", "second.image"]
    for name in sourceNames {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100)).image { context in
        UIColor.systemIndigo.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
      }
      try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name))
    }

    var task = CollageTask.new(projectID: UUID())
    task.outputMaxDimension = 512
    task.outputFormat = .png
    task.photos = sourceNames.map {
      CollagePhoto(fileName: $0, pixelWidth: 160, pixelHeight: 100)
    }

    let premiumImage = try CollageRenderer.render(task: task, photoDirectory: directory)
    let freeImage = try CollageRenderer.render(
      task: task,
      photoDirectory: directory,
      includesWatermark: true
    )
    XCTAssertNotEqual(premiumImage.pngData(), freeImage.pngData())

    let export = try CollageRenderer.prepareExport(
      task: task,
      photoDirectory: directory,
      includesWatermark: true
    )
    defer { try? FileManager.default.removeItem(at: export.fileURL) }
    XCTAssertTrue(export.includesWatermark)

    XCTAssertEqual(
      CollageRenderer.watermarkFontSize(
        in: CGRect(origin: .zero, size: CGSize(width: 512, height: 512))
      ),
      20.48,
      accuracy: 0.001
    )
    XCTAssertEqual(
      CollageRenderer.watermarkFontSize(
        in: CGRect(origin: .zero, size: CGSize(width: 4096, height: 4096))
      ),
      163.84,
      accuracy: 0.001
    )
    XCTAssertTrue(CollageRenderer.watermarkFont(ofSize: 28).fontName.contains("AvenirNext"))
  }

  func testPreparedExportKeepsFullResolutionAndBoundsReviewImage() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MixaFrameExportPreviewTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let sourceNames = ["first.image", "second.image"]
    for (name, color) in zip(sourceNames, [UIColor.systemPink, UIColor.systemTeal]) {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      let image = UIGraphicsImageRenderer(
        size: CGSize(width: 320, height: 200), format: format
      ).image { context in
        color.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
      }
      try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(
        to: directory.appendingPathComponent(name))
    }

    var task = CollageTask.new(projectID: UUID())
    task.canvas = .landscape
    task.outputMaxDimension = 4096
    task.photos = sourceNames.map {
      CollagePhoto(fileName: $0, pixelWidth: 320, pixelHeight: 200)
    }
    let export = try CollageRenderer.prepareExport(task: task, photoDirectory: directory)
    defer { try? FileManager.default.removeItem(at: export.fileURL) }

    XCTAssertEqual(export.outputSize.width, 4096)
    XCTAssertEqual(export.outputSize.height, 2731)
    let reviewCGImage = try XCTUnwrap(export.previewImage.cgImage)
    XCTAssertLessThanOrEqual(
      CGFloat(reviewCGImage.width * reviewCGImage.height),
      CollageRenderer.previewMaximumPixelCount + 5_000
    )
    let fullSource = try XCTUnwrap(CGImageSourceCreateWithURL(export.fileURL as CFURL, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(fullSource, 0, nil) as? [CFString: Any])
    XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 4096)
    XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 2731)
  }

  private func maximumPixelDimension(of image: UIImage) -> Int {
    guard let cgImage = image.cgImage else { return 0 }
    return max(cgImage.width, cgImage.height)
  }

  private func alphaValue(in image: UIImage, at point: CGPoint) -> CGFloat {
    guard let cgImage = image.cgImage else { return -1 }
    var pixel = [UInt8](repeating: 0, count: 4)
    pixel.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: 1,
          height: 1,
          bitsPerComponent: 8,
          bytesPerRow: 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      else { return }
      context.draw(
        cgImage,
        in: CGRect(
          x: -point.x,
          y: -point.y,
          width: CGFloat(cgImage.width),
          height: CGFloat(cgImage.height)
        )
      )
    }
    return CGFloat(pixel[3]) / 255
  }
}
