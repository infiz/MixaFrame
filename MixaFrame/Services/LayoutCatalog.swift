import CoreGraphics
import Foundation

enum LayoutFamily: String, CaseIterable, Identifiable {
  case grid
  case hero
  case editorial
  case mosaic
  case slanted
  case custom

  var id: String { rawValue }

  static let browserCases: [LayoutFamily] = [.grid, .hero, .mosaic, .slanted]

  var browserFamily: LayoutFamily {
    self == .editorial ? .hero : self
  }

  var title: String {
    self == .hero ? "Featured" : rawValue.capitalized
  }

  var symbol: String {
    switch self {
    case .grid: "square.grid.2x2"
    case .hero: "rectangle.inset.filled"
    case .editorial: "newspaper"
    case .mosaic: "square.grid.3x3.topleft.filled"
    case .slanted: "square.split.diagonal.2x2"
    case .custom: "rectangle.split.2x2"
    }
  }
}

enum PartitionLayoutStyle: String, Hashable {
  case aspectAware
  case cornerAnchor
  case dualAnchor
  case pinwheel
  case centerWindow
  case goldenSpiral
  case tJunction
}

enum LayoutAxis: Hashable {
  case horizontal
  case vertical
}

enum LayoutEdge: Hashable {
  case top
  case bottom
  case left
  case right
}

enum LastRowAlignment: Hashable {
  case center
  case stretch
}

enum LayoutRecipe: Hashable {
  case smartGrid
  case grid(columns: Int, lastRow: LastRowAlignment)
  case adaptiveGrid(rowCounts: [Int])
  case hero(edge: LayoutEdge, fraction: CGFloat)
  case multiHero(edge: LayoutEdge, mainCount: Int, fraction: CGFloat)
  case bands(axis: LayoutAxis, counts: [Int], weights: [CGFloat])
  case mosaic(seed: Int)
  case masonry(columns: Int, seed: Int)
  case brick(rows: Int, offset: CGFloat)
  case strip(axis: LayoutAxis, featuredIndex: Int?, featuredWeight: CGFloat)
  case naturalVerticalStrip
  case slantedMosaic(
    rowCounts: [Int], rowWeights: [CGFloat], horizontalSlope: CGFloat,
    verticalSlope: CGFloat, alternating: Bool)
  case partition(style: PartitionLayoutStyle, mainCount: Int?)
  case custom
  case cards(rotation: CGFloat, spread: CGFloat)
  case bubbles(columns: Int)
  case inset(scale: CGFloat, rotation: CGFloat, cornerRadius: CGFloat)
}

struct CollageLayoutTemplate: Identifiable, Hashable {
  let id: String
  let title: String
  let family: LayoutFamily
  let recipe: LayoutRecipe
  let legacyLayout: CollageLayout?

  var symbol: String { legacyLayout?.symbol ?? family.symbol }
}

struct LayoutFrame: Hashable {
  var rect: CGRect
  var normalizedClipPolygon: [CGPoint]? = nil
  var cornerRadiusFraction: CGFloat = 0
  var rotationDegrees: CGFloat = 0
  var zIndex: Int = 0
  var usesAspectFit = false
}

enum LayoutCatalog {
  private static let templatesByPhotoCount = (1...12).map(buildTemplates)
  private static let templatesByPhotoCountAndID = templatesByPhotoCount.map { templates in
    Dictionary(uniqueKeysWithValues: templates.map { ($0.id, $0) })
  }

  static var targetCounts: [Int] {
    templatesByPhotoCount.map(\.count)
  }

  static var totalTemplateCount: Int { targetCounts.reduce(0, +) }

  static func templates(photoCount rawCount: Int) -> [CollageLayoutTemplate] {
    let count = max(1, min(rawCount, 12))
    return templatesByPhotoCount[count - 1]
  }

  private static func buildTemplates(photoCount count: Int) -> [CollageLayoutTemplate] {
    if count == 1 { return singlePhotoTemplates }

    var result = legacyTemplates(photoCount: count)
    for family in LayoutFamily.allCases {
      for candidate in candidates(for: family, photoCount: count)
      where !result.contains(where: { $0.id == candidate.id || $0.recipe == candidate.recipe }) {
        result.append(candidate)
      }
    }
    return result
  }

  static func template(id: String?, photoCount: Int) -> CollageLayoutTemplate? {
    guard let id else { return nil }
    let count = max(1, min(photoCount, 12))
    if id == customTemplate(photoCount: count).id { return customTemplate(photoCount: count) }
    return templatesByPhotoCountAndID[count - 1][id]
  }

  static func customTemplate(photoCount rawCount: Int) -> CollageLayoutTemplate {
    let count = max(1, min(rawCount, 12))
    return template(count, "custom-cuts", "Custom Cuts", .custom, .custom)
  }

  static func compatibleTemplate(id: String?, photoCount: Int) -> CollageLayoutTemplate? {
    guard let id, let separator = id.firstIndex(of: "-") else { return nil }
    let key = String(id[id.index(after: separator)...])
    let count = max(1, min(photoCount, 12))
    let layouts = templates(photoCount: count)
    if let exact = layouts.first(where: { candidate in
      guard let candidateSeparator = candidate.id.firstIndex(of: "-") else { return false }
      return candidate.id[candidate.id.index(after: candidateSeparator)...] == key
    }) {
      return exact
    }

    let replacementKey: String?
    let directReplacements = [
      "poster-matte": "gallery-matte",
      "brick-bold": "brick-soft",
      "mondrian-2": "mondrian-6",
      "mondrian-3": "mondrian-1",
      "mondrian-4": "mondrian-0",
      "mondrian-7": "mondrian-5",
    ]
    if let directReplacement = directReplacements[key] {
      replacementKey = directReplacement
    } else if count <= 3 && key == "slanted-bold-rise" {
      replacementKey = "slanted-gentle-rise"
    } else if count <= 3 && (key == "slanted-center" || key == "slanted-rhythm") {
      replacementKey = "slanted-zigzag"
    } else if count == 2 && (key == "slanted-lead" || key == "slanted-finale") {
      replacementKey = "slanted-gentle-fall"
    } else if count == 3 && key == "featured-corner-anchor-main-2" {
      replacementKey = "hero-left-main-2"
    } else if count == 4 && key == "featured-corner-anchor-main-3" {
      replacementKey = "hero-left-main-3"
    } else if count == 4 && key == "featured-dual-anchor-main-3" {
      replacementKey = "hero-top-main-3"
    } else if count <= 6 && key.hasPrefix("featured-center-window-main-") {
      let mainCount = key.last.flatMap { Int(String($0)) } ?? 1
      replacementKey =
        mainCount == 1
        ? "editorial-three-row-center"
        : "editorial-three-row-center-main-\(mainCount)"
    } else if key.hasPrefix("hero-top-") {
      replacementKey = "hero-top-58"
    } else if key.hasPrefix("hero-bottom-") {
      replacementKey = "hero-bottom-58"
    } else if key.hasPrefix("hero-left-") {
      replacementKey = "hero-left-58"
    } else if key.hasPrefix("hero-right-") {
      replacementKey = "hero-right-58"
    } else if key.hasPrefix("editorial-top-") || key.hasPrefix("bands-row-weighted-") {
      replacementKey = "hero-top-58"
    } else if key.hasPrefix("editorial-bottom-") {
      replacementKey = "hero-bottom-58"
    } else if key.hasPrefix("editorial-left-") {
      replacementKey = "hero-left-58"
    } else if key.hasPrefix("editorial-right-") {
      replacementKey = "hero-right-58"
    } else if key.hasPrefix("bands-three-row-") {
      replacementKey = "editorial-three-row-center"
    } else if key.hasPrefix("bands-three-column-") {
      replacementKey = "editorial-three-column-center"
    } else if key.hasPrefix("bands-row-") {
      replacementKey = "hero-top-58"
    } else if key.hasPrefix("bands-column-") {
      replacementKey = "hero-left-58"
    } else if key == "natural-vertical" || key == "equal-rows" || key == "equal-columns"
      || key.hasPrefix("strip-")
    {
      replacementKey = "smart-grid"
    } else {
      replacementKey = nil
    }
    guard let replacementKey else { return nil }
    return layouts.first { $0.id == "n\(count)-\(replacementKey)" }
  }

  static func selectedTemplate(for task: CollageTask) -> CollageLayoutTemplate {
    let count = max(task.photos.count, 1)
    if let selected = template(id: task.layoutID, photoCount: count) { return selected }
    if let compatible = compatibleTemplate(id: task.layoutID, photoCount: count) {
      return compatible
    }
    return templates(photoCount: count).first(where: { $0.legacyLayout == task.layout })
      ?? templates(photoCount: count)[0]
  }

  static func recommendedTemplate(photoCount: Int, canvasRatio: CGFloat) -> CollageLayoutTemplate {
    let layouts = templates(photoCount: max(photoCount, 1))
    if photoCount == 2 {
      let legacy: CollageLayout = canvasRatio >= 1 ? .columns : .rows
      return layouts.first(where: { $0.legacyLayout == legacy }) ?? layouts[0]
    }
    return layouts.first(where: { $0.legacyLayout == .smartGrid }) ?? layouts[0]
  }

  private static var singlePhotoTemplates: [CollageLayoutTemplate] {
    [
      template(
        1, "full-bleed", "Full Bleed", .grid, .grid(columns: 1, lastRow: .stretch), .smartGrid),
      template(
        1, "gallery-matte", "Gallery Matte", .grid,
        .inset(scale: 0.84, rotation: 0, cornerRadius: 0)),
    ]
  }

  private static func legacyTemplates(photoCount count: Int) -> [CollageLayoutTemplate] {
    return [
      template(
        count, "smart-grid", "Smart Grid", .grid, .smartGrid, .smartGrid),
      template(
        count, "hero-top-58", "Hero Top", .hero, .hero(edge: .top, fraction: 0.58), .featuredTop),
      template(
        count, "hero-bottom-58", "Hero Bottom", .hero, .hero(edge: .bottom, fraction: 0.58),
        .featuredBottom),
      template(
        count, "hero-left-58", "Hero Left", .hero, .hero(edge: .left, fraction: 0.58), .featuredLeft
      ),
      template(
        count, "hero-right-58", "Hero Right", .hero, .hero(edge: .right, fraction: 0.58),
        .featuredRight),
      template(
        count, "brick-story", "Brick Story", .mosaic,
        .brick(rows: Int(ceil(Double(count) / 2)), offset: 0.12), .staggered),
    ]
  }

  private static func candidates(for family: LayoutFamily, photoCount count: Int)
    -> [CollageLayoutTemplate]
  {
    switch family {
    case .grid:
      return gridRowPatterns(photoCount: count).map { rowCounts in
        let key = rowCounts.map(String.init).joined(separator: "-")
        let title = rowCounts.map(String.init).joined(separator: " · ")
        return template(
          count, "grid-rows-\(key)", title, .grid,
          .adaptiveGrid(rowCounts: rowCounts)
        )
      }

    case .hero:
      let edges: [(LayoutEdge, String)] = [
        (.top, "Top"), (.bottom, "Bottom"), (.left, "Left"), (.right, "Right"),
      ]
      var layouts = edges.flatMap { edge, edgeName in
        (1...min(3, count - 1)).map { mainCount in
          if mainCount == 1 {
            return template(
              count, "hero-\(edgeName.lowercased())-58", "1 Main · \(edgeName)",
              .hero, .hero(edge: edge, fraction: 0.58))
          }
          return template(
            count, "hero-\(edgeName.lowercased())-main-\(mainCount)",
            "\(mainCount) Main · \(edgeName)", .hero,
            .multiHero(
              edge: edge, mainCount: mainCount,
              fraction: heroMainFraction(photoCount: count, mainCount: mainCount)))
        }
      }
      let maximumMainCount = min(3, count - 1)
      let featuredStyles: [(PartitionLayoutStyle, String, String, Int)] = [
        (.cornerAnchor, "corner-anchor", "Corner Anchor", 3),
        (.dualAnchor, "dual-anchor", "Dual Anchor", 4),
        (.centerWindow, "center-window", "Center Window", 5),
      ]
      for (style, key, title, minimumPhotoCount) in featuredStyles
      where count >= minimumPhotoCount {
        layouts += (1...maximumMainCount).compactMap { mainCount in
          guard
            isDistinctFeaturedLayout(
              style: style,
              photoCount: count,
              mainCount: mainCount
            )
          else { return nil }
          return template(
            count, "featured-\(key)-main-\(mainCount)",
            "\(mainCount) Main · \(title)", .hero,
            .partition(style: style, mainCount: mainCount))
        }
      }
      return layouts

    case .editorial:
      var layouts: [CollageLayoutTemplate] = []
      if count >= 5 {
        for mainCount in 1...3 {
          let remaining = count - mainCount
          let firstSecondary = Int(ceil(Double(remaining) / 2))
          let secondSecondary = remaining - firstSecondary
          let mainWeight = max(1.8, CGFloat(mainCount) * 3 / CGFloat(remaining))
          let threeBandLayouts: [(String, String, LayoutAxis, [Int], [CGFloat])] = [
            (
              "three-row-top", "Three Rows · Top", .vertical,
              [mainCount, firstSecondary, secondSecondary], [mainWeight, 1, 1]
            ),
            (
              "three-row-center", "Three Rows · Center", .vertical,
              [firstSecondary, mainCount, secondSecondary], [1, mainWeight, 1]
            ),
            (
              "three-row-bottom", "Three Rows · Bottom", .vertical,
              [firstSecondary, secondSecondary, mainCount], [1, 1, mainWeight]
            ),
            (
              "three-column-left", "Three Columns · Left", .horizontal,
              [mainCount, firstSecondary, secondSecondary], [mainWeight, 1, 1]
            ),
            (
              "three-column-center", "Three Columns · Center", .horizontal,
              [firstSecondary, mainCount, secondSecondary], [1, mainWeight, 1]
            ),
            (
              "three-column-right", "Three Columns · Right", .horizontal,
              [firstSecondary, secondSecondary, mainCount], [1, 1, mainWeight]
            ),
          ]
          layouts += threeBandLayouts.map { key, title, axis, counts, weights in
            let resolvedKey = mainCount == 1 ? key : "\(key)-main-\(mainCount)"
            return template(
              count, "editorial-\(resolvedKey)", "\(mainCount) Main · \(title)", .editorial,
              .bands(axis: axis, counts: counts, weights: weights))
          }
        }
      }
      return layouts

    case .mosaic:
      let mondrianSeeds = [0, 1, 5, 6]
      var layouts = mondrianSeeds.enumerated().map { displayIndex, seed in
        template(
          count, "mondrian-\(seed)", "Mondrian \(displayIndex + 1)", .mosaic,
          .mosaic(seed: seed))
      }
      for columns in 2...min(4, count) {
        for seed in 0..<2 {
          layouts.append(
            template(
              count, "masonry-\(columns)-\(seed)", "Masonry \(columns) · \(seed + 1)", .mosaic,
              .masonry(columns: columns, seed: seed)))
        }
      }
      layouts.append(
        template(
          count, "brick-soft", "Soft Brick", .mosaic,
          .brick(rows: max(2, Int(round(sqrt(Double(count))))), offset: 0.08)))
      if count >= 3 {
        layouts.append(
          template(
            count, "aspect-aware-slice", "Aspect-Aware Slice", .mosaic,
            .partition(style: .aspectAware, mainCount: nil)))
      }
      if count >= 4 {
        layouts.append(
          template(
            count, "t-junction-quilt", "T-Junction Quilt", .mosaic,
            .partition(style: .tJunction, mainCount: nil)))
      }
      if count >= 5 {
        layouts.append(
          template(
            count, "pinwheel", "Pinwheel", .mosaic,
            .partition(style: .pinwheel, mainCount: nil)))
      }
      if (4...10).contains(count) {
        layouts.append(
          template(
            count, "golden-spiral", "Golden Spiral", .mosaic,
            .partition(style: .goldenSpiral, mainCount: nil)))
      }
      return layouts

    case .slanted:
      let leadingRows = slantedRowCounts(photoCount: count, remainderPlacement: .leading)
      let centeredRows = slantedRowCounts(photoCount: count, remainderPlacement: .center)
      let trailingRows = slantedRowCounts(photoCount: count, remainderPlacement: .trailing)
      let equalWeights = Array(repeating: CGFloat(1), count: centeredRows.count)
      var leadWeights = equalWeights
      leadWeights[0] = 1.55
      var centerWeights = equalWeights
      centerWeights[centerWeights.count / 2] = 1.55
      var finaleWeights = equalWeights
      finaleWeights[finaleWeights.count - 1] = 1.55
      let rhythmWeights = (0..<centeredRows.count).map {
        $0.isMultiple(of: 2) ? CGFloat(1.2) : 0.85
      }
      let layouts = [
        template(
          count, "slanted-gentle-fall", "Gentle Cascade", .slanted,
          .slantedMosaic(
            rowCounts: leadingRows, rowWeights: Array(repeating: 1, count: leadingRows.count),
            horizontalSlope: 0.045, verticalSlope: 0.035, alternating: false)),
        template(
          count, "slanted-gentle-rise", "Gentle Rise", .slanted,
          .slantedMosaic(
            rowCounts: trailingRows, rowWeights: Array(repeating: 1, count: trailingRows.count),
            horizontalSlope: -0.045, verticalSlope: -0.035, alternating: false)),
        template(
          count, "slanted-bold-fall", "Bold Cascade", .slanted,
          .slantedMosaic(
            rowCounts: centeredRows, rowWeights: equalWeights, horizontalSlope: 0.085,
            verticalSlope: 0.065, alternating: false)),
        template(
          count, "slanted-bold-rise", "Bold Rise", .slanted,
          .slantedMosaic(
            rowCounts: Array(centeredRows.reversed()), rowWeights: equalWeights,
            horizontalSlope: -0.085, verticalSlope: -0.065, alternating: false)),
        template(
          count, "slanted-zigzag", "Zigzag Mosaic", .slanted,
          .slantedMosaic(
            rowCounts: leadingRows, rowWeights: Array(repeating: 1, count: leadingRows.count),
            horizontalSlope: 0.07, verticalSlope: 0.07, alternating: true)),
        template(
          count, "slanted-lead", "Lead Mosaic", .slanted,
          .slantedMosaic(
            rowCounts: centeredRows, rowWeights: leadWeights, horizontalSlope: 0.06,
            verticalSlope: -0.05, alternating: false)),
        template(
          count, "slanted-center", "Center Mosaic", .slanted,
          .slantedMosaic(
            rowCounts: centeredRows, rowWeights: centerWeights, horizontalSlope: -0.06,
            verticalSlope: 0.055, alternating: true)),
        template(
          count, "slanted-finale", "Finale Mosaic", .slanted,
          .slantedMosaic(
            rowCounts: centeredRows, rowWeights: finaleWeights, horizontalSlope: 0.06,
            verticalSlope: 0.05, alternating: false)),
        template(
          count, "slanted-rhythm", "Slanted Rhythm", .slanted,
          .slantedMosaic(
            rowCounts: trailingRows, rowWeights: rhythmWeights, horizontalSlope: -0.07,
            verticalSlope: 0.075, alternating: true)),
      ]
      let retainedKeys: Set<String>
      switch count {
      case 2:
        retainedKeys = [
          "slanted-gentle-fall", "slanted-gentle-rise", "slanted-bold-fall",
          "slanted-zigzag",
        ]
      case 3:
        retainedKeys = [
          "slanted-gentle-fall", "slanted-gentle-rise", "slanted-bold-fall",
          "slanted-zigzag", "slanted-lead", "slanted-finale",
        ]
      default:
        return layouts
      }
      return layouts.filter { retainedKeys.contains(layoutKey(for: $0.id)) }

    case .custom:
      return []
    }
  }

  private enum RemainderPlacement {
    case leading
    case center
    case trailing
  }

  private static func isDistinctFeaturedLayout(
    style: PartitionLayoutStyle,
    photoCount: Int,
    mainCount: Int
  ) -> Bool {
    switch style {
    case .cornerAnchor, .dualAnchor:
      return photoCount - mainCount > 1
    case .centerWindow:
      return photoCount >= 7
    default:
      return true
    }
  }

  private static func layoutKey(for id: String) -> String {
    guard let separator = id.firstIndex(of: "-") else { return id }
    return String(id[id.index(after: separator)...])
  }

  private static func gridRowPatterns(photoCount: Int) -> [[Int]] {
    switch photoCount {
    case 2:
      [[2]]
    case 3:
      [[2, 1], [1, 2], [3]]
    case 4:
      [[2, 2], [3, 1], [1, 3], [4]]
    case 5:
      [[3, 2], [2, 3], [2, 1, 2], [2, 2, 1], [1, 2, 2]]
    case 6:
      [[3, 3], [2, 2, 2], [4, 2], [2, 4], [2, 3, 1], [1, 3, 2]]
    case 7:
      [[3, 2, 2], [2, 3, 2], [2, 2, 3], [4, 3], [3, 4]]
    case 8:
      [
        [3, 2, 3], [2, 3, 3], [3, 3, 2], [4, 2, 2], [2, 4, 2], [2, 2, 4], [4, 4],
        [2, 2, 2, 2],
      ]
    case 9:
      [
        [3, 3, 3], [4, 3, 2], [4, 2, 3], [3, 4, 2], [3, 2, 4], [2, 4, 3], [2, 3, 4],
        [2, 2, 2, 3], [2, 2, 3, 2], [2, 3, 2, 2], [3, 2, 2, 2],
      ]
    case 10:
      [
        [4, 3, 3], [3, 4, 3], [3, 3, 4], [4, 4, 2], [4, 2, 4], [2, 4, 4],
        [2, 2, 3, 3], [2, 3, 2, 3], [2, 3, 3, 2], [3, 2, 2, 3], [3, 2, 3, 2],
        [3, 3, 2, 2], [2, 2, 2, 2, 2],
      ]
    case 11:
      [
        [4, 4, 3], [4, 3, 4], [3, 4, 4], [3, 3, 3, 2], [3, 3, 2, 3], [3, 2, 3, 3],
        [2, 3, 3, 3], [4, 3, 2, 2], [4, 2, 3, 2], [4, 2, 2, 3], [3, 4, 2, 2],
        [3, 2, 4, 2], [3, 2, 2, 4], [2, 4, 3, 2], [2, 4, 2, 3], [2, 3, 4, 2],
        [2, 3, 2, 4], [2, 2, 4, 3], [2, 2, 3, 4],
      ]
    case 12:
      [
        [4, 4, 4], [3, 3, 3, 3], [4, 3, 3, 2], [4, 3, 2, 3], [4, 2, 3, 3],
        [3, 4, 3, 2], [3, 4, 2, 3], [3, 3, 4, 2], [3, 3, 2, 4], [3, 2, 4, 3],
        [3, 2, 3, 4], [2, 4, 3, 3], [2, 3, 4, 3], [2, 3, 3, 4], [4, 4, 2, 2],
        [4, 2, 4, 2], [4, 2, 2, 4], [2, 4, 4, 2], [2, 4, 2, 4], [2, 2, 4, 4],
        [2, 2, 2, 2, 2, 2],
      ]
    default:
      []
    }
  }

  private static func heroMainFraction(photoCount: Int, mainCount: Int) -> CGFloat {
    let smallCount = max(1, photoCount - mainCount)
    let emphasizedMainArea =
      CGFloat(mainCount) * 1.5 / (CGFloat(smallCount) + CGFloat(mainCount) * 1.5)
    return min(0.84, max(0.62, emphasizedMainArea))
  }

  private static func slantedRowCounts(
    photoCount: Int,
    remainderPlacement: RemainderPlacement
  ) -> [Int] {
    guard photoCount > 2 else { return [photoCount] }
    if photoCount == 3 {
      switch remainderPlacement {
      case .leading:
        return [2, 1]
      case .center, .trailing:
        return [1, 2]
      }
    }
    let maximumRowsWithPairs = max(1, photoCount / 2)
    let rowCount = min(
      maximumRowsWithPairs,
      max(2, Int(sqrt(Double(photoCount)).rounded()))
    )
    let baseCount = photoCount / rowCount
    let remainder = photoCount % rowCount
    var result = Array(repeating: baseCount, count: rowCount)
    let remainderIndices: [Int]
    switch remainderPlacement {
    case .leading:
      remainderIndices = Array(result.indices)
    case .center:
      remainderIndices = result.indices.sorted {
        abs($0 - rowCount / 2) < abs($1 - rowCount / 2)
      }
    case .trailing:
      remainderIndices = Array(result.indices.reversed())
    }
    for index in remainderIndices.prefix(remainder) {
      result[index] += 1
    }
    return result
  }

  private static func template(
    _ photoCount: Int,
    _ key: String,
    _ title: String,
    _ family: LayoutFamily,
    _ recipe: LayoutRecipe,
    _ legacyLayout: CollageLayout? = nil
  ) -> CollageLayoutTemplate {
    CollageLayoutTemplate(
      id: "n\(photoCount)-\(key)",
      title: title,
      family: family,
      recipe: recipe,
      legacyLayout: legacyLayout
    )
  }
}
