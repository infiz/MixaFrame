import CoreGraphics
import Foundation

struct CollageProject: Identifiable, Codable, Hashable {
  var id = UUID()
  var name: String
  var createdAt = Date()
  var modifiedAt = Date()
  var tasks: [CollageTask] = []
}

struct CollageTask: Identifiable, Codable, Hashable {
  var id = UUID()
  var projectID: UUID
  var name: String
  var createdAt = Date()
  var modifiedAt = Date()
  var photos: [CollagePhoto] = []
  var layout: CollageLayout = .staggered
  var layoutID: String?
  var mainPhotoCount: Int?
  var isPhotoOrderManuallyAdjusted: Bool?
  var canvas: CanvasPreset = .square
  var outputMaxDimension: Int = 4096
  var outputFormat: OutputFormat = .jpeg
  var quality: OutputQuality = .balanced
  var spacing: Double = 12
  var cornerRadiusPercent: Double?
  var layoutRowWeights: [Double]?
  var layoutColumnWeights: [[Double]]?
  var layoutFrameOverrides: [NormalizedLayoutFrame]?
  var customLayoutFrames: [NormalizedLayoutFrame]?
  var savedCustomLayoutID: UUID?
  var savedLayoutSnapshot: SavedLayoutSnapshot?
  var backgroundHex: String = "FFFFFF"
  var latestExportFileName: String?
  var exportedPhotoLibraryAssetIdentifier: String?

  var canvasCornerRadius: Double {
    get { cornerRadiusPercent ?? 0 }
    set { cornerRadiusPercent = min(50, max(0, newValue)) }
  }

  var titleForEditing: String {
    name
  }

  var background: CollageBackground {
    get { CollageBackground(rawValue: backgroundHex.uppercased()) ?? .white }
    set { backgroundHex = newValue.rawValue }
  }

  var usesAutomaticPhotoArrangement: Bool {
    isPhotoOrderManuallyAdjusted != true
  }

  mutating func clearLayoutCustomization(invalidateExport: Bool = false) {
    layoutRowWeights = nil
    layoutColumnWeights = nil
    layoutFrameOverrides = nil
    if invalidateExport { latestExportFileName = nil }
  }

  mutating func clearCustomLayout() {
    customLayoutFrames = nil
    savedCustomLayoutID = nil
  }

  mutating func clearSavedLayoutSnapshot() {
    savedLayoutSnapshot = nil
  }

  mutating func invalidateExport() {
    latestExportFileName = nil
  }

  static func new(projectID: UUID) -> CollageTask {
    CollageTask(
      projectID: projectID,
      name: "",
      cornerRadiusPercent: 0
    )
  }
}

enum MixaFrameExportPreferences {
  private static let formatKey = "exportPreferences.outputFormat"
  private static let qualityKey = "exportPreferences.outputQuality"
  private static let resolutionKey = "exportPreferences.outputMaxDimension"
  private static let backgroundKey = "exportPreferences.collageBackground"
  private static let spacingKey = "exportPreferences.layoutSpacing"
  private static let canvasCornerRadiusKey = "exportPreferences.canvasCornerRadius"

  static func apply(
    to task: inout CollageTask,
    defaults: UserDefaults = .standard
  ) {
    if let rawFormat = defaults.string(forKey: formatKey),
      let format = OutputFormat(rawValue: rawFormat)
    {
      task.outputFormat = format
    }
    if let rawQuality = defaults.string(forKey: qualityKey),
      let quality = OutputQuality(rawValue: rawQuality)
    {
      task.quality = quality
    }
    let resolution = defaults.integer(forKey: resolutionKey)
    if (512...8192).contains(resolution) {
      task.outputMaxDimension = resolution
    }
    if let rawBackground = defaults.string(forKey: backgroundKey),
      let background = CollageBackground(rawValue: rawBackground)
    {
      task.background = background
    }
    if defaults.object(forKey: spacingKey) != nil {
      task.spacing = min(40, max(0, defaults.double(forKey: spacingKey)))
    }
    if defaults.object(forKey: canvasCornerRadiusKey) != nil {
      task.canvasCornerRadius = defaults.double(forKey: canvasCornerRadiusKey)
    }
  }

  static func save(outputFormat: OutputFormat, defaults: UserDefaults = .standard) {
    defaults.set(outputFormat.rawValue, forKey: formatKey)
  }

  static func save(quality: OutputQuality, defaults: UserDefaults = .standard) {
    defaults.set(quality.rawValue, forKey: qualityKey)
  }

  static func save(outputMaxDimension: Int, defaults: UserDefaults = .standard) {
    defaults.set(outputMaxDimension, forKey: resolutionKey)
  }

  static func save(background: CollageBackground, defaults: UserDefaults = .standard) {
    defaults.set(background.rawValue, forKey: backgroundKey)
  }

  static func save(spacing: Double, defaults: UserDefaults = .standard) {
    defaults.set(min(40, max(0, spacing)), forKey: spacingKey)
  }

  static func save(canvasCornerRadius: Double, defaults: UserDefaults = .standard) {
    defaults.set(min(50, max(0, canvasCornerRadius)), forKey: canvasCornerRadiusKey)
  }
}

struct CollageTaskEditorState: Equatable {
  let name: String
  let photos: [CollagePhotoEditorState]
  let layout: CollageLayout
  let layoutID: String?
  let mainPhotoCount: Int?
  let usesManualPhotoOrder: Bool
  let canvas: CanvasPreset
  let outputMaxDimension: Int
  let outputFormat: OutputFormat
  let quality: OutputQuality
  let spacing: Double
  let canvasCornerRadius: Double
  let layoutRowWeights: [Double]?
  let layoutColumnWeights: [[Double]]?
  let layoutFrameOverrides: [NormalizedLayoutFrame]?
  let customLayoutFrames: [NormalizedLayoutFrame]?
  let savedCustomLayoutID: UUID?
  let backgroundHex: String
  let latestExportFileName: String?
}

struct CollagePhotoEditorState: Equatable {
  let id: UUID
  let fileName: String
  let photoLibraryAssetIdentifier: String?
  let pixelWidth: Int
  let pixelHeight: Int
  let focalX: Double
  let focalY: Double
  let focusSource: FocusSource
  let zoom: Double
}

extension CollageTask {
  var editorState: CollageTaskEditorState {
    CollageTaskEditorState(
      name: name,
      photos: photos.map {
        CollagePhotoEditorState(
          id: $0.id,
          fileName: $0.fileName,
          photoLibraryAssetIdentifier: $0.photoLibraryAssetIdentifier,
          pixelWidth: $0.pixelWidth,
          pixelHeight: $0.pixelHeight,
          focalX: $0.focalX,
          focalY: $0.focalY,
          focusSource: $0.focusSource,
          zoom: $0.effectiveZoom
        )
      },
      layout: layout,
      layoutID: layoutID,
      mainPhotoCount: mainPhotoCount,
      usesManualPhotoOrder: isPhotoOrderManuallyAdjusted == true,
      canvas: canvas,
      outputMaxDimension: outputMaxDimension,
      outputFormat: outputFormat,
      quality: quality,
      spacing: spacing,
      canvasCornerRadius: canvasCornerRadius,
      layoutRowWeights: layoutRowWeights,
      layoutColumnWeights: layoutColumnWeights,
      layoutFrameOverrides: layoutFrameOverrides,
      customLayoutFrames: customLayoutFrames,
      savedCustomLayoutID: savedCustomLayoutID,
      backgroundHex: backgroundHex.uppercased(),
      latestExportFileName: latestExportFileName
    )
  }

  func hasUserChanges(comparedTo savedTask: CollageTask) -> Bool {
    editorState != savedTask.editorState
  }

  mutating func resetPhotosForAutomaticFit() {
    isPhotoOrderManuallyAdjusted = false
    for index in photos.indices {
      let detectedArea = photos[index].detectedFocusArea?.rect
      photos[index].focalX = detectedArea.map { Double($0.midX) } ?? 0.5
      photos[index].focalY = detectedArea.map { Double($0.midY) } ?? 0.5
      photos[index].focusSource = .automatic
      photos[index].zoom = nil
    }
  }
}

struct SavedCustomLayout: Identifiable, Codable, Hashable {
  var id = UUID()
  var name: String
  var photoCount: Int
  var frames: [NormalizedLayoutFrame]
  var createdAt = Date()
  var modifiedAt = Date()
}

struct SavedLayoutSnapshot: Codable, Hashable {
  var sourceLayoutID: String?
  var sourceLayoutTitle: String
  var sourceLayoutFamily: String
  var photoCount: Int
  var outputAspectRatio: Double
  var frames: [SavedLayoutFrame]
}

struct SavedLayoutFrame: Codable, Hashable {
  var rect: NormalizedLayoutFrame
  var clipPolygon: [NormalizedLayoutPoint]?
  var cornerRadiusFraction: Double
  var rotationDegrees: Double
  var zIndex: Int
  var usesAspectFit: Bool
}

struct NormalizedLayoutPoint: Codable, Hashable {
  var x: Double
  var y: Double
}

struct NormalizedLayoutFrame: Codable, Hashable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double

  init(rect: CGRect, in size: CGSize) {
    x = Double(rect.minX / max(size.width, 1))
    y = Double(rect.minY / max(size.height, 1))
    width = Double(rect.width / max(size.width, 1))
    height = Double(rect.height / max(size.height, 1))
  }

  init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  var isValid: Bool {
    x.isFinite && y.isFinite && width.isFinite && height.isFinite
      && width > 0 && height > 0
      && x >= -0.000_001 && y >= -0.000_001
      && x + width <= 1.000_001 && y + height <= 1.000_001
  }

  func rect(in size: CGSize) -> CGRect {
    CGRect(
      x: CGFloat(x) * size.width,
      y: CGFloat(y) * size.height,
      width: CGFloat(width) * size.width,
      height: CGFloat(height) * size.height
    )
  }
}

enum CollageBackground: String, CaseIterable, Identifiable {
  case white = "FFFFFF"
  case dark = "111111"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .white: "White"
    case .dark: "Dark"
    }
  }

  var symbol: String {
    switch self {
    case .white: "sun.max.fill"
    case .dark: "moon.fill"
    }
  }
}

struct CollagePhoto: Identifiable, Codable, Hashable {
  var id = UUID()
  var fileName: String
  var photoLibraryAssetIdentifier: String?
  var pixelWidth: Int
  var pixelHeight: Int
  var focalX: Double = 0.5
  var focalY: Double = 0.5
  var focusSource: FocusSource = .automatic
  var detectedFocusArea: PhotoFocusArea?
  var hasCompletedFocusDetection: Bool?
  var zoom: Double?

  var aspectRatio: CGFloat {
    guard pixelHeight > 0 else { return 1 }
    return CGFloat(pixelWidth) / CGFloat(pixelHeight)
  }

  var effectiveZoom: Double {
    max(1, min(zoom ?? 1, 4))
  }
}

struct PhotoFocusArea: Codable, Hashable, Sendable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double

  init(_ rect: CGRect) {
    x = rect.minX
    y = rect.minY
    width = rect.width
    height = rect.height
  }

  var rect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }
}

enum PhotoCropGeometry {
  static func clampedFocalPoint(
    sourceAspectRatio: CGFloat,
    destinationAspectRatio: CGFloat,
    focalPoint: CGPoint,
    zoom: CGFloat
  ) -> CGPoint {
    let cropRect = normalizedCropRect(
      sourceAspectRatio: sourceAspectRatio,
      destinationAspectRatio: destinationAspectRatio,
      focalPoint: focalPoint,
      zoom: zoom
    )
    return CGPoint(x: cropRect.midX, y: cropRect.midY)
  }

  static func normalizedCropRect(
    sourceAspectRatio: CGFloat,
    destinationAspectRatio: CGFloat,
    focalPoint: CGPoint,
    zoom: CGFloat
  ) -> CGRect {
    let sourceRatio = max(sourceAspectRatio, 0.0001)
    let destinationRatio = max(destinationAspectRatio, 0.0001)
    var size: CGSize

    if sourceRatio > destinationRatio {
      size = CGSize(width: destinationRatio / sourceRatio, height: 1)
    } else {
      size = CGSize(width: 1, height: sourceRatio / destinationRatio)
    }

    let safeZoom = max(1, min(zoom, 4))
    size.width /= safeZoom
    size.height /= safeZoom
    let origin = CGPoint(
      x: min(1 - size.width, max(0, focalPoint.x - size.width / 2)),
      y: min(1 - size.height, max(0, focalPoint.y - size.height / 2))
    )
    return CGRect(origin: origin, size: size)
  }
}

enum FocusSource: String, Codable, CaseIterable {
  case automatic
  case manual
}

enum CollageLayout: String, Codable, CaseIterable, Identifiable {
  case featuredTop
  case featuredBottom
  case featuredLeft
  case featuredRight
  case staggered
  case rows
  case columns
  case verticalStrip

  var id: String { rawValue }

  var title: String {
    switch self {
    case .featuredTop: "Hero Top"
    case .featuredBottom: "Hero Bottom"
    case .featuredLeft: "Hero Left"
    case .featuredRight: "Hero Right"
    case .staggered: "Staggered"
    case .rows: "Stacked Rows"
    case .columns: "Side-by-Side"
    case .verticalStrip: "Full-Width Tall Strip"
    }
  }

  var symbol: String {
    switch self {
    case .featuredTop: "rectangle.tophalf.inset.filled"
    case .featuredBottom: "rectangle.bottomhalf.inset.filled"
    case .featuredLeft: "rectangle.lefthalf.inset.filled"
    case .featuredRight: "rectangle.righthalf.inset.filled"
    case .staggered: "square.grid.3x2"
    case .rows: "rectangle.split.3x1"
    case .columns: "rectangle.split.1x2"
    case .verticalStrip: "rectangle.portrait.on.rectangle.portrait"
    }
  }
}

enum CanvasPreset: String, Codable, CaseIterable, Identifiable {
  case square
  case portrait
  case landscape
  case story

  var id: String { rawValue }

  var title: String {
    switch self {
    case .square: "Square · 1:1"
    case .portrait: "Portrait · 4:5"
    case .landscape: "Landscape · 3:2"
    case .story: "Story · 9:16"
    }
  }

  var aspectRatio: CGFloat {
    switch self {
    case .square: 1
    case .portrait: 4 / 5
    case .landscape: 3 / 2
    case .story: 9 / 16
    }
  }
}

enum OutputFormat: String, Codable, CaseIterable, Identifiable {
  case jpeg
  case png
  case webP
  case heif

  var id: String { rawValue }

  var title: String {
    switch self {
    case .jpeg: "JPEG"
    case .png: "PNG"
    case .webP: "WebP"
    case .heif: "HEIF"
    }
  }

  var fileExtension: String {
    switch self {
    case .jpeg: "jpg"
    case .png: "png"
    case .webP: "webp"
    case .heif: "heic"
    }
  }

  var summary: String {
    switch self {
    case .jpeg: "Small, widely compatible photo files"
    case .png: "Lossless quality and larger files"
    case .webP: "Efficient modern compression"
    case .heif: "Apple-efficient photos with smaller files"
    }
  }

  var supportsTransparency: Bool {
    self == .png || self == .webP
  }
}

enum OutputQuality: String, Codable, CaseIterable, Identifiable {
  case spaceSaver
  case balanced
  case best

  var id: String { rawValue }

  var title: String {
    switch self {
    case .spaceSaver: "Space Saver"
    case .balanced: "Balanced"
    case .best: "Best Quality"
    }
  }

  var summary: String {
    switch self {
    case .spaceSaver: "Lower quality · Smallest file"
    case .balanced: "High quality · Moderate file"
    case .best: "Highest quality · Largest file"
    }
  }

  var compressionQuality: CGFloat {
    switch self {
    case .spaceSaver: 0.60
    case .balanced: 0.82
    case .best: 0.98
    }
  }
}

enum PhotoLibraryExportMode {
  case createNew
  case replaceExisting
}

enum ResolutionPreset: Int, CaseIterable, Identifiable {
  case fullHD = 1920
  case qhd = 2560
  case fourK = 4096
  case eightK = 8192

  var id: Int { rawValue }

  var title: String {
    switch self {
    case .fullHD: "HD · 1920 px"
    case .qhd: "QHD · 2560 px"
    case .fourK: "4K · 4096 px"
    case .eightK: "8K · 8192 px"
    }
  }
}
