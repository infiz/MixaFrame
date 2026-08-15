import CoreGraphics
import Foundation

struct LayoutAdjustmentGrid: Equatable {
  var rowCounts: [Int]
  var rowWeights: [Double]
  var columnWeights: [[Double]]
}

struct LayoutPhotoFit: Equatable {
  let averageVisibleFraction: Double
  let minimumVisibleFraction: Double

  var score: Double {
    averageVisibleFraction * 0.75 + minimumVisibleFraction * 0.25
  }
}

struct LayoutDivider: Identifiable, Hashable {
  enum Axis: Hashable {
    case horizontal
    case vertical
  }

  let axis: Axis
  let rowIndex: Int
  let dividerIndex: Int
  let start: CGPoint
  let end: CGPoint
  let adjustment: LayoutDividerAdjustment

  init(
    axis: Axis,
    rowIndex: Int,
    dividerIndex: Int,
    start: CGPoint,
    end: CGPoint,
    adjustment: LayoutDividerAdjustment = .weights
  ) {
    self.axis = axis
    self.rowIndex = rowIndex
    self.dividerIndex = dividerIndex
    self.start = start
    self.end = end
    self.adjustment = adjustment
  }

  var id: String { "\(axis)-\(rowIndex)-\(dividerIndex)" }
  var midpoint: CGPoint {
    CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
  }
}

enum LayoutDividerAdjustment: Hashable {
  case weights
  case frames(leading: [Int], trailing: [Int])
}

enum LayoutEngine {
  static func outputSize(for task: CollageTask) -> CGSize {
    let maxDimension = CGFloat(max(512, min(task.outputMaxDimension, 8192)))

    if isNaturalVerticalStrip(task) {
      let spacing = scaledSpacing(task.spacing, outputWidth: maxDimension)
      let photoHeight = task.photos.reduce(CGFloat.zero) { partial, photo in
        partial + maxDimension / max(photo.aspectRatio, 0.05)
      }
      let gaps = CGFloat(max(0, task.photos.count - 1)) * spacing
      return CGSize(width: maxDimension, height: max(1, photoHeight + gaps))
    }

    let ratio = task.canvas.aspectRatio
    if ratio >= 1 {
      return CGSize(width: maxDimension, height: (maxDimension / ratio).rounded())
    }
    return CGSize(width: (maxDimension * ratio).rounded(), height: maxDimension)
  }

  static func selectedTemplate(for task: CollageTask) -> CollageLayoutTemplate {
    let template = LayoutCatalog.selectedTemplate(for: task)
    guard template.family == .hero || template.family == .editorial,
      let requestedMainCount = mainPhotoCount(for: task)
    else { return template }

    let mainCount = min(max(1, requestedMainCount), max(1, min(3, task.photos.count - 1)))
    let recipe: LayoutRecipe
    switch template.recipe {
    case .hero(let edge, let fraction):
      recipe = .multiHero(
        edge: edge,
        mainCount: mainCount,
        fraction: max(
          fraction, recommendedMainFraction(photoCount: task.photos.count, mainCount: mainCount))
      )
    case .multiHero(let edge, _, let fraction):
      recipe = .multiHero(
        edge: edge,
        mainCount: mainCount,
        fraction: max(
          fraction, recommendedMainFraction(photoCount: task.photos.count, mainCount: mainCount))
      )
    case .bands(let axis, let counts, let weights):
      let adjusted = editorialBands(
        counts: counts,
        weights: weights,
        photoCount: task.photos.count,
        mainCount: mainCount
      )
      recipe = .bands(axis: axis, counts: adjusted.counts, weights: adjusted.weights)
    default:
      return template
    }
    let title =
      defaultMainPhotoCount(for: template.recipe) == mainCount
      ? template.title : "\(template.title) · \(mainCount) Main"
    return CollageLayoutTemplate(
      id: template.id,
      title: title,
      family: template.family,
      recipe: recipe,
      legacyLayout: template.legacyLayout
    )
  }

  static func mainPhotoCount(for task: CollageTask) -> Int? {
    let template = LayoutCatalog.selectedTemplate(for: task)
    guard template.family == .hero || template.family == .editorial,
      task.photos.count > 1
    else { return nil }
    if let requested = task.mainPhotoCount {
      return min(max(1, requested), min(3, task.photos.count - 1))
    }
    if let legacyMainCount = legacyMainPhotoCount(from: task.layoutID) {
      return min(max(1, legacyMainCount), min(3, task.photos.count - 1))
    }
    switch template.recipe {
    case .hero:
      return 1
    case .multiHero(_, let mainCount, _):
      return min(max(1, mainCount), min(3, task.photos.count - 1))
    case .bands(_, let counts, let weights):
      guard !counts.isEmpty else { return 1 }
      return min(
        max(1, counts[editorialMainBandIndex(counts: counts, weights: weights)]),
        min(3, task.photos.count - 1)
      )
    default:
      return nil
    }
  }

  static func mainPhotoCount(for template: CollageLayoutTemplate) -> Int? {
    defaultMainPhotoCount(for: template.recipe)
  }

  static func layoutSamples(
    family: LayoutFamily,
    photoCount: Int,
    mainPhotoCount: Int
  ) -> [CollageLayoutTemplate] {
    let layouts = LayoutCatalog.templates(photoCount: max(1, photoCount)).filter { template in
      switch family.browserFamily {
      case .hero:
        if template.family == .hero { return true }
        guard template.family == .editorial,
          case .bands(_, let counts, _) = template.recipe
        else { return false }
        return counts.count == 3
      default:
        return template.family == family
      }
    }
    guard family.browserFamily == .hero, photoCount > 1 else { return layouts }
    let resolvedMainCount = min(max(1, mainPhotoCount), min(3, photoCount - 1))
    return layouts.filter { defaultMainPhotoCount(for: $0.recipe) == resolvedMainCount }
  }

  static func fittingLayoutSamples(
    family: LayoutFamily,
    task: CollageTask,
    mainPhotoCount: Int
  ) -> [CollageLayoutTemplate] {
    let samples = layoutSamples(
      family: family,
      photoCount: max(1, task.photos.count),
      mainPhotoCount: mainPhotoCount
    )
    guard task.photos.count > 1 else { return samples }

    let assessed = samples.map { template in
      (template, photoFit(for: template, task: task))
    }
    let bestScore = assessed.map { $0.1.score }.max() ?? 0
    let relativeFloor = bestScore - 0.1
    let stronglyFitting = assessed.filter { _, fit in
      fit.averageVisibleFraction >= 0.68 && fit.minimumVisibleFraction >= 0.42
    }
    let candidates = stronglyFitting.isEmpty ? assessed : stronglyFitting
    return
      candidates
      .filter { _, fit in
        fit.score >= relativeFloor
      }
      .sorted { left, right in
        if family == .grid {
          let leftIsSmartGrid = left.0.legacyLayout == .smartGrid
          let rightIsSmartGrid = right.0.legacyLayout == .smartGrid
          if leftIsSmartGrid != rightIsSmartGrid { return leftIsSmartGrid }
        }
        if abs(left.1.score - right.1.score) > 0.000_001 {
          return left.1.score > right.1.score
        }
        return left.0.id < right.0.id
      }
      .map(\.0)
  }

  static func recommendedCanvasAndTemplate(
    for task: CollageTask
  ) -> (canvas: CanvasPreset, template: CollageLayoutTemplate) {
    let layouts = LayoutCatalog.templates(photoCount: max(1, task.photos.count))
    guard task.photos.count > 1 else { return (task.canvas, layouts[0]) }

    var recommendations: [(CanvasPreset, CollageLayoutTemplate, LayoutPhotoFit)] = []
    for canvas in CanvasPreset.allCases {
      var candidateTask = task
      candidateTask.canvas = canvas
      for template in layouts {
        recommendations.append((canvas, template, photoFit(for: template, task: candidateTask)))
      }
    }
    let recommendation = recommendations.max { left, right in
      if abs(left.2.score - right.2.score) > 0.000_001 {
        return left.2.score < right.2.score
      }
      if left.1.family == .grid, right.1.family != .grid { return false }
      if left.1.family != .grid, right.1.family == .grid { return true }
      if left.0 == .square, right.0 != .square { return false }
      if left.0 != .square, right.0 == .square { return true }
      return left.1.id > right.1.id
    }
    return recommendation.map { ($0.0, $0.1) } ?? (task.canvas, layouts[0])
  }

  static func recommendedTemplate(for task: CollageTask) -> CollageLayoutTemplate {
    let layouts = LayoutCatalog.templates(photoCount: max(1, task.photos.count))
    guard task.photos.count > 1 else { return layouts[0] }
    let assessed = layouts.map { template in
      (template, photoFit(for: template, task: task))
    }
    let qualified = assessed.filter { _, fit in
      fit.averageVisibleFraction >= 0.68 && fit.minimumVisibleFraction >= 0.42
    }
    return (qualified.isEmpty ? assessed : qualified).max { left, right in
      if abs(left.1.score - right.1.score) > 0.000_001 {
        return left.1.score < right.1.score
      }
      if left.0.family == .grid, right.0.family != .grid { return false }
      if left.0.family != .grid, right.0.family == .grid { return true }
      return left.0.id > right.0.id
    }?.0 ?? layouts[0]
  }

  static func photoFit(
    for template: CollageLayoutTemplate,
    task: CollageTask
  ) -> LayoutPhotoFit {
    guard !task.photos.isEmpty else {
      return LayoutPhotoFit(averageVisibleFraction: 1, minimumVisibleFraction: 1)
    }
    var candidateTask = task
    candidateTask.layoutID = template.id
    candidateTask.clearLayoutCustomization()
    candidateTask.isPhotoOrderManuallyAdjusted = true
    candidateTask.mainPhotoCount = defaultMainPhotoCount(for: template.recipe)
    let frames = layoutFrames(for: candidateTask, in: outputSize(for: candidateTask))
    guard frames.count == task.photos.count else {
      return LayoutPhotoFit(averageVisibleFraction: 0, minimumVisibleFraction: 0)
    }

    let photoRatios = task.photos.map { max(0.05, Double($0.aspectRatio)) }.sorted()
    let frameDescriptors = frames.map { frame in
      (
        ratio: max(0.05, Double(frame.rect.width / max(frame.rect.height, 1))),
        shapeArea: normalizedShapeArea(of: frame)
      )
    }.sorted { $0.ratio < $1.ratio }
    let visibleFractions = zip(photoRatios, frameDescriptors).map { photoRatio, frame in
      min(photoRatio / frame.ratio, frame.ratio / photoRatio) * frame.shapeArea
    }
    return LayoutPhotoFit(
      averageVisibleFraction: visibleFractions.reduce(0, +) / Double(visibleFractions.count),
      minimumVisibleFraction: visibleFractions.min() ?? 0
    )
  }

  static func matchingMainPhotoTemplate(
    for template: CollageLayoutTemplate,
    photoCount: Int,
    mainPhotoCount: Int
  ) -> CollageLayoutTemplate? {
    guard let structureKey = mainPhotoStructureKey(for: template.recipe) else { return nil }
    return layoutSamples(
      family: template.family,
      photoCount: photoCount,
      mainPhotoCount: mainPhotoCount
    ).first { mainPhotoStructureKey(for: $0.recipe) == structureKey }
  }

  static func isNaturalVerticalStrip(_ task: CollageTask) -> Bool {
    if case .naturalVerticalStrip = selectedTemplate(for: task).recipe { return true }
    return false
  }

  static func frames(for task: CollageTask, in size: CGSize) -> [CGRect] {
    layoutFrames(for: task, in: size).map(\.rect)
  }

  static func photoIndicesInVisualOrder(for task: CollageTask, in size: CGSize) -> [Int] {
    let frames = layoutFrames(for: task, in: size)
    return frames.indices.sorted { left, right in
      let leftRect = frames[left].rect
      let rightRect = frames[right].rect
      if abs(leftRect.minY - rightRect.minY) > 0.5 { return leftRect.minY < rightRect.minY }
      if abs(leftRect.minX - rightRect.minX) > 0.5 { return leftRect.minX < rightRect.minX }
      return left < right
    }
  }

  static func layoutFrames(for task: CollageTask, in size: CGSize) -> [LayoutFrame] {
    guard !task.photos.isEmpty else { return [] }
    let spacing = scaledSpacing(task.spacing, outputWidth: size.width)
    var frames = layoutFrames(
      template: selectedTemplate(for: task),
      photoCount: task.photos.count,
      photoAspectRatios: task.photos.map(\.aspectRatio),
      photos: task.photos,
      in: CGRect(origin: .zero, size: size),
      spacing: spacing,
      layoutAdjustment: layoutAdjustmentGrid(for: task, in: size),
      optimizesPhotoPlacement: task.usesAutomaticPhotoArrangement
    )
    if let overrides = task.layoutFrameOverrides,
      overrides.count == frames.count,
      overrides.allSatisfy({ override in
        override.x.isFinite && override.y.isFinite && override.width.isFinite
          && override.height.isFinite && override.width > 0 && override.height > 0
      })
    {
      for index in frames.indices {
        frames[index].rect = overrides[index].rect(in: size)
        if isNaturalVerticalStrip(task) {
          frames[index].usesAspectFit = false
        }
      }
    }
    return frames
  }

  static func previewFrames(
    template: CollageLayoutTemplate,
    task: CollageTask,
    in size: CGSize,
    preservesCurrentAdjustments: Bool
  ) -> [LayoutFrame] {
    guard !task.photos.isEmpty else {
      return layoutFrames(
        template: template,
        photoCount: 1,
        photoAspectRatios: [1],
        photos: [],
        in: CGRect(origin: .zero, size: size),
        spacing: 2,
        layoutAdjustment: nil,
        optimizesPhotoPlacement: false
      )
    }
    var previewTask = task
    previewTask.layoutID = template.id
    previewTask.mainPhotoCount = mainPhotoCount(for: template)
    if !preservesCurrentAdjustments {
      previewTask.clearLayoutCustomization()
    }
    return layoutFrames(for: previewTask, in: size)
  }

  static func layoutAdjustmentGrid(
    for task: CollageTask,
    in size: CGSize
  ) -> LayoutAdjustmentGrid? {
    let count = task.photos.count
    guard count > 1 else { return nil }
    let template = selectedTemplate(for: task)
    let spacing = scaledSpacing(task.spacing, outputWidth: size.width)
    let rowCounts: [Int]
    let defaultRowWeights: [Double]
    let defaultColumnWeights: [[Double]]

    switch template.recipe {
    case .smartGrid:
      let columns = smartGridColumnCount(
        photoCount: count,
        photoAspectRatios: task.photos.map(\.aspectRatio),
        in: CGRect(origin: .zero, size: size),
        spacing: spacing
      )
      rowCounts = gridRowCounts(count: count, columns: columns)
      defaultRowWeights = Array(repeating: 1, count: rowCounts.count)
      defaultColumnWeights = rowCounts.map { Array(repeating: 1, count: $0) }

    case .grid(let columns, let lastRow) where lastRow == .stretch:
      rowCounts = gridRowCounts(count: count, columns: columns)
      defaultRowWeights = Array(repeating: 1, count: rowCounts.count)
      defaultColumnWeights = rowCounts.map { Array(repeating: 1, count: $0) }

    case .adaptiveGrid(let requestedCounts):
      rowCounts = resolvedRowCounts(requestedCounts, photoCount: count)
      let weights = adaptiveGridWeights(
        rowCounts: rowCounts,
        photoAspectRatios: task.photos.map(\.aspectRatio),
        availableWidth: size.width,
        spacing: spacing
      )
      defaultRowWeights = weights.rows
      defaultColumnWeights = weights.columns

    case .bands(.vertical, let requestedCounts, let weights):
      rowCounts = resolvedRowCounts(requestedCounts, photoCount: count)
      defaultRowWeights = rowCounts.indices.map { index in
        Double(index < weights.count ? max(weights[index], 0.1) : 1)
      }
      defaultColumnWeights = rowCounts.map { Array(repeating: 1, count: $0) }

    case .strip(.vertical, let featuredIndex, let featuredWeight):
      rowCounts = Array(repeating: 1, count: count)
      defaultRowWeights = (0..<count).map { index in
        index == featuredIndex ? Double(max(1, featuredWeight)) : 1
      }
      defaultColumnWeights = rowCounts.map { _ in [1] }

    case .strip(.horizontal, let featuredIndex, let featuredWeight):
      rowCounts = [count]
      defaultRowWeights = [1]
      defaultColumnWeights = [
        (0..<count).map { index in
          index == featuredIndex ? Double(max(1, featuredWeight)) : 1
        }
      ]

    case .slantedMosaic(let requestedCounts, let weights, _, _, _):
      rowCounts = resolvedRowCounts(requestedCounts, photoCount: count)
      defaultRowWeights = rowCounts.indices.map { index in
        Double(index < weights.count ? max(weights[index], 0.1) : 1)
      }
      defaultColumnWeights = rowCounts.map { Array(repeating: 1, count: $0) }

    default:
      return nil
    }

    let resolvedRowWeights = validatedWeights(
      task.layoutRowWeights,
      defaults: defaultRowWeights
    )
    let resolvedColumnWeights: [[Double]]
    if let customWeights = task.layoutColumnWeights,
      customWeights.count == defaultColumnWeights.count,
      zip(customWeights, defaultColumnWeights).allSatisfy({ custom, defaults in
        custom.count == defaults.count && custom.allSatisfy { $0.isFinite && $0 > 0 }
      })
    {
      resolvedColumnWeights = customWeights
    } else {
      resolvedColumnWeights = defaultColumnWeights
    }
    return LayoutAdjustmentGrid(
      rowCounts: rowCounts,
      rowWeights: resolvedRowWeights,
      columnWeights: resolvedColumnWeights
    )
  }

  static func layoutDividers(for task: CollageTask, in size: CGSize) -> [LayoutDivider] {
    guard task.photos.count > 1 else { return [] }
    guard let adjustment = layoutAdjustmentGrid(for: task, in: size) else {
      return frameOverrideDividers(for: task, in: size)
    }
    let rect = CGRect(origin: .zero, size: size)
    let frames = layoutFrames(
      template: selectedTemplate(for: task),
      photoCount: task.photos.count,
      photoAspectRatios: task.photos.map(\.aspectRatio),
      photos: [],
      in: rect,
      spacing: scaledSpacing(task.spacing, outputWidth: size.width),
      layoutAdjustment: adjustment,
      optimizesPhotoPlacement: false
    )
    guard frames.count == task.photos.count else { return [] }

    var rows: [[LayoutFrame]] = []
    var frameIndex = 0
    for count in adjustment.rowCounts {
      let endIndex = min(frameIndex + count, frames.count)
      guard frameIndex < endIndex else { break }
      rows.append(Array(frames[frameIndex..<endIndex]))
      frameIndex = endIndex
    }

    var result: [LayoutDivider] = []
    for rowIndex in rows.indices {
      let row = rows[rowIndex]
      for dividerIndex in 0..<max(0, row.count - 1) {
        let leftPoints = globalPoints(for: row[dividerIndex])
        let rightPoints = globalPoints(for: row[dividerIndex + 1])
        result.append(
          LayoutDivider(
            axis: .vertical,
            rowIndex: rowIndex,
            dividerIndex: dividerIndex,
            start: midpoint(leftPoints[1], rightPoints[0]),
            end: midpoint(leftPoints[2], rightPoints[3])
          ))
      }

      guard rowIndex < rows.count - 1,
        let currentFirst = row.first,
        let currentLast = row.last,
        let nextFirst = rows[rowIndex + 1].first,
        let nextLast = rows[rowIndex + 1].last
      else { continue }
      let currentFirstPoints = globalPoints(for: currentFirst)
      let currentLastPoints = globalPoints(for: currentLast)
      let nextFirstPoints = globalPoints(for: nextFirst)
      let nextLastPoints = globalPoints(for: nextLast)
      result.append(
        LayoutDivider(
          axis: .horizontal,
          rowIndex: rowIndex,
          dividerIndex: rowIndex,
          start: midpoint(currentFirstPoints[3], nextFirstPoints[0]),
          end: midpoint(currentLastPoints[2], nextLastPoints[1])
        ))
    }
    return result
  }

  static func adjustedFrameOverrides(
    for task: CollageTask,
    moving divider: LayoutDivider,
    normalizedDelta: Double
  ) -> [NormalizedLayoutFrame]? {
    guard
      case .frames(let leadingIndices, let trailingIndices) = divider.adjustment,
      !leadingIndices.isEmpty,
      !trailingIndices.isEmpty,
      (leadingIndices + trailingIndices).allSatisfy({ task.photos.indices.contains($0) })
    else { return nil }

    let size = outputSize(for: task)
    var frames = layoutFrames(for: task, in: size).map(\.rect)
    guard frames.count == task.photos.count else { return nil }
    let dimension = divider.axis == .horizontal ? size.height : size.width
    let requestedDelta = CGFloat(normalizedDelta) * dimension
    let minimumLength = max(1, dimension * 0.04)

    let maximumNegativeDelta: CGFloat
    let maximumPositiveDelta: CGFloat
    switch divider.axis {
    case .horizontal:
      maximumNegativeDelta = leadingIndices.reduce(-CGFloat.greatestFiniteMagnitude) {
        max($0, minimumLength - frames[$1].height)
      }
      maximumPositiveDelta = trailingIndices.reduce(CGFloat.greatestFiniteMagnitude) {
        min($0, frames[$1].height - minimumLength)
      }
    case .vertical:
      maximumNegativeDelta = leadingIndices.reduce(-CGFloat.greatestFiniteMagnitude) {
        max($0, minimumLength - frames[$1].width)
      }
      maximumPositiveDelta = trailingIndices.reduce(CGFloat.greatestFiniteMagnitude) {
        min($0, frames[$1].width - minimumLength)
      }
    }
    let delta = min(maximumPositiveDelta, max(maximumNegativeDelta, requestedDelta))
    guard delta.isFinite, abs(delta) > 0.001 else {
      return frames.map { NormalizedLayoutFrame(rect: $0, in: size) }
    }

    for index in leadingIndices where frames.indices.contains(index) {
      switch divider.axis {
      case .horizontal:
        frames[index].size.height += delta
      case .vertical:
        frames[index].size.width += delta
      }
    }
    for index in trailingIndices where frames.indices.contains(index) {
      switch divider.axis {
      case .horizontal:
        frames[index].origin.y += delta
        frames[index].size.height -= delta
      case .vertical:
        frames[index].origin.x += delta
        frames[index].size.width -= delta
      }
    }
    return frames.map { NormalizedLayoutFrame(rect: $0, in: size) }
  }

  private static func frameOverrideDividers(
    for task: CollageTask,
    in size: CGSize
  ) -> [LayoutDivider] {
    let frames = layoutFrames(for: task, in: size).map(\.rect)
    guard frames.count > 1 else { return [] }
    let spacing = scaledSpacing(task.spacing, outputWidth: size.width)
    let coordinateTolerance = max(1, min(size.width, size.height) * 0.0015)
    let gapTolerance = max(2, spacing * 0.3, coordinateTolerance)
    let minimumOverlap = max(2, min(size.width, size.height) * 0.005)
    var candidates: [FrameDividerCandidate] = []

    for firstIndex in frames.indices {
      for secondIndex in frames.indices where secondIndex != firstIndex {
        let first = frames[firstIndex]
        let second = frames[secondIndex]

        let horizontalGap = second.minX - first.maxX
        let verticalOverlapStart = max(first.minY, second.minY)
        let verticalOverlapEnd = min(first.maxY, second.maxY)
        if abs(horizontalGap - spacing) <= gapTolerance,
          verticalOverlapEnd - verticalOverlapStart >= minimumOverlap
        {
          candidates.append(
            FrameDividerCandidate(
              axis: .vertical,
              position: (first.maxX + second.minX) / 2,
              start: verticalOverlapStart,
              end: verticalOverlapEnd,
              leading: [firstIndex],
              trailing: [secondIndex]
            ))
        }

        let verticalGap = second.minY - first.maxY
        let horizontalOverlapStart = max(first.minX, second.minX)
        let horizontalOverlapEnd = min(first.maxX, second.maxX)
        if abs(verticalGap - spacing) <= gapTolerance,
          horizontalOverlapEnd - horizontalOverlapStart >= minimumOverlap
        {
          candidates.append(
            FrameDividerCandidate(
              axis: .horizontal,
              position: (first.maxY + second.minY) / 2,
              start: horizontalOverlapStart,
              end: horizontalOverlapEnd,
              leading: [firstIndex],
              trailing: [secondIndex]
            ))
        }
      }
    }

    let mergeDistance = max(gapTolerance, spacing * 1.5)
    let sortedCandidates = candidates.sorted { first, second in
      if first.axis != second.axis {
        return first.axis == .horizontal
      }
      if abs(first.position - second.position) > coordinateTolerance {
        return first.position < second.position
      }
      return first.start < second.start
    }
    var groups: [FrameDividerCandidate] = []
    for candidate in sortedCandidates {
      if let index = groups.lastIndex(where: { group in
        group.axis == candidate.axis
          && abs(group.position - candidate.position) <= coordinateTolerance
          && candidate.start <= group.end + mergeDistance
          && candidate.end >= group.start - mergeDistance
      }) {
        groups[index].position = (groups[index].position + candidate.position) / 2
        groups[index].start = min(groups[index].start, candidate.start)
        groups[index].end = max(groups[index].end, candidate.end)
        groups[index].leading = Array(Set(groups[index].leading + candidate.leading)).sorted()
        groups[index].trailing = Array(Set(groups[index].trailing + candidate.trailing)).sorted()
      } else {
        groups.append(candidate)
      }
    }

    return groups.enumerated().map { index, group in
      let start: CGPoint
      let end: CGPoint
      switch group.axis {
      case .horizontal:
        start = CGPoint(x: group.start, y: group.position)
        end = CGPoint(x: group.end, y: group.position)
      case .vertical:
        start = CGPoint(x: group.position, y: group.start)
        end = CGPoint(x: group.position, y: group.end)
      }
      return LayoutDivider(
        axis: group.axis,
        rowIndex: index,
        dividerIndex: index,
        start: start,
        end: end,
        adjustment: .frames(leading: group.leading, trailing: group.trailing)
      )
    }
  }

  private struct FrameDividerCandidate {
    let axis: LayoutDivider.Axis
    var position: CGFloat
    var start: CGFloat
    var end: CGFloat
    var leading: [Int]
    var trailing: [Int]
  }

  static func scaledSpacing(_ points: Double, outputWidth: CGFloat) -> CGFloat {
    CGFloat(points) * outputWidth / 1000
  }

  private static func recommendedMainFraction(photoCount: Int, mainCount: Int) -> CGFloat {
    let smallCount = max(1, photoCount - mainCount)
    let emphasizedArea =
      CGFloat(mainCount) * 1.5 / (CGFloat(smallCount) + CGFloat(mainCount) * 1.5)
    return min(0.84, max(0.58, emphasizedArea))
  }

  private static func legacyMainPhotoCount(from layoutID: String?) -> Int? {
    guard let layoutID else { return nil }
    let components = layoutID.split(separator: "-")
    guard let mainIndex = components.firstIndex(of: "main"),
      components.indices.contains(mainIndex + 1),
      let count = Int(components[mainIndex + 1]),
      (1...3).contains(count)
    else { return nil }
    return count
  }

  private static func defaultMainPhotoCount(for recipe: LayoutRecipe) -> Int? {
    switch recipe {
    case .hero:
      return 1
    case .multiHero(_, let mainCount, _):
      return mainCount
    case .bands(_, let counts, let weights):
      guard !counts.isEmpty else { return nil }
      return counts[editorialMainBandIndex(counts: counts, weights: weights)]
    default:
      return nil
    }
  }

  private static func mainPhotoStructureKey(for recipe: LayoutRecipe) -> String? {
    switch recipe {
    case .hero(let edge, _), .multiHero(let edge, _, _):
      return "hero-\(edge)"
    case .bands(let axis, let counts, let weights):
      guard !counts.isEmpty else { return nil }
      let mainIndex = editorialMainBandIndex(counts: counts, weights: weights)
      return "editorial-\(axis)-\(counts.count)-\(mainIndex)"
    default:
      return nil
    }
  }

  private static func editorialMainBandIndex(counts: [Int], weights: [CGFloat]) -> Int {
    guard !counts.isEmpty else { return 0 }
    let safeWeights = counts.indices.map { index in
      index < weights.count ? max(weights[index], 0.1) : 1
    }
    if let maximumWeight = safeWeights.max(), let minimumWeight = safeWeights.min(),
      maximumWeight - minimumWeight > 0.01
    {
      return safeWeights.firstIndex(of: maximumWeight) ?? 0
    }
    return counts.indices.min { left, right in
      if counts[left] != counts[right] { return counts[left] < counts[right] }
      return left < right
    } ?? 0
  }

  private static func editorialBands(
    counts: [Int],
    weights: [CGFloat],
    photoCount: Int,
    mainCount: Int
  ) -> (counts: [Int], weights: [CGFloat]) {
    let resolvedCounts = resolvedRowCounts(counts, photoCount: photoCount)
    guard resolvedCounts.count > 1 else { return (resolvedCounts, weights) }
    let mainIndex = editorialMainBandIndex(counts: resolvedCounts, weights: weights)
    let maximumMainCount = max(1, photoCount - (resolvedCounts.count - 1))
    let resolvedMainCount = min(mainCount, maximumMainCount)
    var adjustedCounts = Array(repeating: 1, count: resolvedCounts.count)
    adjustedCounts[mainIndex] = resolvedMainCount

    let otherIndices = resolvedCounts.indices.filter { $0 != mainIndex }
    var extras = photoCount - adjustedCounts.reduce(0, +)
    while extras > 0,
      let index = otherIndices.min(by: { left, right in
        let leftFill = Double(adjustedCounts[left]) / Double(max(1, resolvedCounts[left]))
        let rightFill = Double(adjustedCounts[right]) / Double(max(1, resolvedCounts[right]))
        if abs(leftFill - rightFill) > 0.000_001 { return leftFill < rightFill }
        return left < right
      })
    {
      adjustedCounts[index] += 1
      extras -= 1
    }

    var adjustedWeights = resolvedCounts.indices.map { index in
      index < weights.count ? max(weights[index], 0.1) : 1
    }
    let otherWeight = otherIndices.reduce(CGFloat.zero) { $0 + adjustedWeights[$1] }
    let otherPhotos = max(1, otherIndices.reduce(0) { $0 + adjustedCounts[$1] })
    let minimumMainWeight =
      CGFloat(resolvedMainCount) * (otherWeight / CGFloat(otherPhotos)) * 1.5
    adjustedWeights[mainIndex] = max(adjustedWeights[mainIndex], minimumMainWeight)
    return (adjustedCounts, adjustedWeights)
  }

  private static func gridRowCounts(count: Int, columns requestedColumns: Int) -> [Int] {
    let columns = max(1, min(count, requestedColumns))
    return stride(from: 0, to: count, by: columns).map { min(columns, count - $0) }
  }

  private static func resolvedRowCounts(_ requested: [Int], photoCount: Int) -> [Int] {
    var remaining = photoCount
    var result: [Int] = []
    for count in requested where remaining > 0 {
      let resolved = min(max(1, count), remaining)
      result.append(resolved)
      remaining -= resolved
    }
    if remaining > 0 { result.append(remaining) }
    return result
  }

  private static func adaptiveGridWeights(
    rowCounts: [Int],
    photoAspectRatios: [CGFloat],
    availableWidth: CGFloat,
    spacing: CGFloat
  ) -> (rows: [Double], columns: [[Double]]) {
    let normalizedRatios = photoAspectRatios.map {
      min(4, max(0.25, Double($0)))
    }.sorted(by: >)
    var photoIndex = 0
    var rowWeights: [Double] = []
    var columnWeights: [[Double]] = []

    for rowCount in rowCounts {
      let ratios = (0..<rowCount).map { offset -> Double in
        let index = photoIndex + offset
        return index < normalizedRatios.count ? normalizedRatios[index] : 1
      }
      let usableWidth = max(1, availableWidth - CGFloat(max(0, rowCount - 1)) * spacing)
      rowWeights.append(Double(usableWidth) / max(ratios.reduce(0, +), 0.01))
      columnWeights.append(ratios)
      photoIndex += rowCount
    }
    return (rowWeights, columnWeights)
  }

  private static func normalizedShapeArea(of frame: LayoutFrame) -> Double {
    if let polygon = frame.normalizedClipPolygon, polygon.count >= 3 {
      let doubledArea = polygon.indices.reduce(0.0) { partial, index in
        let point = polygon[index]
        let next = polygon[(index + 1) % polygon.count]
        return partial + Double(point.x * next.y - next.x * point.y)
      }
      return min(1, max(0, abs(doubledArea) / 2))
    }
    let radius = min(0.5, max(0, Double(frame.cornerRadiusFraction)))
    return 1 - (4 - Double.pi) * radius * radius
  }

  private static func validatedWeights(
    _ custom: [Double]?,
    defaults: [Double]
  ) -> [Double] {
    guard let custom, custom.count == defaults.count,
      custom.allSatisfy({ $0.isFinite && $0 > 0 })
    else { return defaults }
    return custom
  }

  private static func globalPoints(for frame: LayoutFrame) -> [CGPoint] {
    if let polygon = frame.normalizedClipPolygon, polygon.count == 4 {
      return polygon.map {
        CGPoint(
          x: frame.rect.minX + $0.x * frame.rect.width,
          y: frame.rect.minY + $0.y * frame.rect.height
        )
      }
    }
    return [
      CGPoint(x: frame.rect.minX, y: frame.rect.minY),
      CGPoint(x: frame.rect.maxX, y: frame.rect.minY),
      CGPoint(x: frame.rect.maxX, y: frame.rect.maxY),
      CGPoint(x: frame.rect.minX, y: frame.rect.maxY),
    ]
  }

  private static func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
    CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
  }

  private static func layoutFrames(
    template: CollageLayoutTemplate,
    photoCount: Int,
    photoAspectRatios: [CGFloat],
    photos: [CollagePhoto],
    in rect: CGRect,
    spacing: CGFloat,
    layoutAdjustment: LayoutAdjustmentGrid?,
    optimizesPhotoPlacement: Bool
  ) -> [LayoutFrame] {
    guard photoCount > 0 else { return [] }

    func arranged(_ frames: [LayoutFrame]) -> [LayoutFrame] {
      guard optimizesPhotoPlacement, photos.count == frames.count else { return frames }
      return framesAssignedByPhoto(visualFrames: frames, photos: photos)
    }

    switch template.recipe {
    case .smartGrid:
      if let layoutAdjustment {
        return arranged(
          weightedGridFrames(
            rowCounts: layoutAdjustment.rowCounts,
            rowWeights: layoutAdjustment.rowWeights,
            columnWeights: layoutAdjustment.columnWeights,
            in: rect,
            spacing: spacing
          ).map { LayoutFrame(rect: $0) })
      }
      let columns = smartGridColumnCount(
        photoCount: photoCount,
        photoAspectRatios: photoAspectRatios,
        in: rect,
        spacing: spacing
      )
      let filledFrames = gridFrames(
        count: photoCount, in: rect, spacing: spacing, columns: columns, lastRow: .stretch
      ).map { LayoutFrame(rect: $0) }
      return arranged(filledFrames)

    case .grid(let columns, let lastRow):
      if lastRow == .stretch, let layoutAdjustment {
        return arranged(
          weightedGridFrames(
            rowCounts: layoutAdjustment.rowCounts,
            rowWeights: layoutAdjustment.rowWeights,
            columnWeights: layoutAdjustment.columnWeights,
            in: rect,
            spacing: spacing
          ).map { LayoutFrame(rect: $0) })
      }
      return arranged(
        gridFrames(
          count: photoCount, in: rect, spacing: spacing, columns: columns, lastRow: lastRow
        ).map { LayoutFrame(rect: $0) })

    case .adaptiveGrid(let requestedCounts):
      let rowCounts = resolvedRowCounts(requestedCounts, photoCount: photoCount)
      let weights = adaptiveGridWeights(
        rowCounts: rowCounts,
        photoAspectRatios: photoAspectRatios,
        availableWidth: rect.width,
        spacing: spacing
      )
      return arranged(
        weightedGridFrames(
          rowCounts: rowCounts,
          rowWeights: layoutAdjustment?.rowWeights ?? weights.rows,
          columnWeights: layoutAdjustment?.columnWeights ?? weights.columns,
          in: rect,
          spacing: spacing
        ).map { LayoutFrame(rect: $0) })

    case .hero(let edge, let fraction):
      return arranged(
        heroFrames(
          count: photoCount, mainCount: 1, in: rect, spacing: spacing, edge: edge,
          fraction: fraction
        ).map { LayoutFrame(rect: $0) })

    case .multiHero(let edge, let mainCount, let fraction):
      return arranged(
        heroFrames(
          count: photoCount, mainCount: mainCount, in: rect, spacing: spacing, edge: edge,
          fraction: fraction
        ).map { LayoutFrame(rect: $0) })

    case .bands(let axis, let counts, let weights):
      if axis == .vertical, let layoutAdjustment {
        return arranged(
          weightedGridFrames(
            rowCounts: layoutAdjustment.rowCounts,
            rowWeights: layoutAdjustment.rowWeights,
            columnWeights: layoutAdjustment.columnWeights,
            in: rect,
            spacing: spacing
          ).map { LayoutFrame(rect: $0) })
      }
      return arranged(
        bandFrames(
          counts: counts, weights: weights, axis: axis, in: rect, spacing: spacing
        ).prefix(photoCount).map { LayoutFrame(rect: $0) })

    case .mosaic(let seed):
      return arranged(
        mosaicFrames(count: photoCount, in: rect, spacing: spacing, seed: seed)
          .map { LayoutFrame(rect: $0) })

    case .masonry(let columns, let seed):
      return arranged(
        masonryFrames(
          count: photoCount, columns: columns, seed: seed, in: rect, spacing: spacing
        ).map { LayoutFrame(rect: $0) })

    case .brick(let rows, let offset):
      return arranged(
        brickFrames(
          count: photoCount, rows: rows, offset: offset, in: rect, spacing: spacing
        ).map { LayoutFrame(rect: $0) })

    case .strip(let axis, let featuredIndex, let featuredWeight):
      if let layoutAdjustment {
        return arranged(
          weightedGridFrames(
            rowCounts: layoutAdjustment.rowCounts,
            rowWeights: layoutAdjustment.rowWeights,
            columnWeights: layoutAdjustment.columnWeights,
            in: rect,
            spacing: spacing
          ).map { LayoutFrame(rect: $0) })
      }
      return arranged(
        stripFrames(
          count: photoCount, axis: axis, featuredIndex: featuredIndex,
          featuredWeight: featuredWeight, in: rect, spacing: spacing
        ).map { LayoutFrame(rect: $0) })

    case .naturalVerticalStrip:
      var y = rect.minY
      return (0..<photoCount).map { index in
        let ratio = index < photoAspectRatios.count ? photoAspectRatios[index] : 1
        let height = rect.width / max(ratio, 0.05)
        defer { y += height + spacing }
        return LayoutFrame(
          rect: CGRect(x: rect.minX, y: y, width: rect.width, height: height)
        )
      }

    case .slantedMosaic(
      let rowCounts, let rowWeights, let horizontalSlope, let verticalSlope, let alternating):
      let adjustedRowWeights = layoutAdjustment?.rowWeights.map { CGFloat($0) } ?? rowWeights
      let adjustedColumnWeights = layoutAdjustment?.columnWeights.map { row in
        row.map { CGFloat($0) }
      }
      let frames = slantedMosaicFrames(
        count: photoCount,
        rowCounts: rowCounts,
        rowWeights: adjustedRowWeights,
        columnWeights: adjustedColumnWeights,
        horizontalSlope: horizontalSlope,
        verticalSlope: verticalSlope,
        alternating: alternating,
        in: rect,
        spacing: spacing
      )
      return arranged(frames)

    case .cards(let rotation, let spread):
      return arranged(
        cardFrames(count: photoCount, rotation: rotation, spread: spread, in: rect))

    case .bubbles(let columns):
      return arranged(
        gridFrames(
          count: photoCount, in: rect.insetBy(dx: rect.width * 0.025, dy: rect.height * 0.025),
          spacing: max(spacing, min(rect.width, rect.height) * 0.025), columns: columns,
          lastRow: .center
        ).map { LayoutFrame(rect: $0, cornerRadiusFraction: 0.5) })

    case .inset(let scale, let rotation, let cornerRadius):
      let width = rect.width * scale
      let height = rect.height * scale
      return arranged([
        LayoutFrame(
          rect: CGRect(
            x: rect.midX - width / 2, y: rect.midY - height / 2,
            width: width, height: height
          ),
          cornerRadiusFraction: cornerRadius,
          rotationDegrees: rotation
        )
      ])
    }
  }

  private static func slantedMosaicFrames(
    count: Int,
    rowCounts requestedRowCounts: [Int],
    rowWeights: [CGFloat],
    columnWeights: [[CGFloat]]?,
    horizontalSlope: CGFloat,
    verticalSlope: CGFloat,
    alternating: Bool,
    in rect: CGRect,
    spacing: CGFloat
  ) -> [LayoutFrame] {
    guard count > 1 else { return [LayoutFrame(rect: rect)] }

    var remaining = count
    var rowCounts: [Int] = []
    for requestedCount in requestedRowCounts where remaining > 0 {
      let resolvedCount = min(max(1, requestedCount), remaining)
      rowCounts.append(resolvedCount)
      remaining -= resolvedCount
    }
    if remaining > 0 { rowCounts.append(remaining) }

    let safeWeights = rowCounts.indices.map { index in
      max(index < rowWeights.count ? rowWeights[index] : 1, 0.1)
    }
    let totalWeight = max(safeWeights.reduce(0, +), 0.1)
    let rowHeights = safeWeights.map { rect.height * $0 / totalWeight }
    let smallestRowHeight = rowHeights.min() ?? rect.height
    let largestColumnCount = max(rowCounts.max() ?? 1, 1)
    let smallestColumnWidth = rect.width / CGFloat(largestColumnCount)
    let separator = min(
      max(0, spacing),
      min(smallestRowHeight, smallestColumnWidth) * 0.24
    )
    let horizontalMagnitude = min(
      abs(horizontalSlope) * rect.height,
      smallestRowHeight * 0.50
    )
    let verticalMagnitude = min(
      abs(verticalSlope) * rect.width,
      smallestColumnWidth * 0.45
    )

    var boundaries: [(left: CGFloat, right: CGFloat)] = []
    var cumulativeHeight: CGFloat = 0
    for boundaryIndex in 0..<max(0, rowCounts.count - 1) {
      cumulativeHeight += rowHeights[boundaryIndex]
      let alternatesDown = !alternating || boundaryIndex.isMultiple(of: 2)
      let signedSlant =
        horizontalMagnitude * (horizontalSlope < 0 ? -1 : 1)
        * (alternatesDown ? 1 : -1)
      let centerY = rect.minY + cumulativeHeight
      boundaries.append(
        (
          left: centerY - signedSlant / 2,
          right: centerY + signedSlant / 2
        ))
    }

    func boundaryY(_ boundary: (left: CGFloat, right: CGFloat), at x: CGFloat) -> CGFloat {
      let progress = (x - rect.minX) / max(rect.width, 1)
      return boundary.left + (boundary.right - boundary.left) * progress
    }

    var frames: [LayoutFrame] = []
    for rowIndex in rowCounts.indices {
      let columnCount = rowCounts[rowIndex]
      let safeColumnWeights = (0..<columnCount).map { columnIndex in
        if let columnWeights, rowIndex < columnWeights.count,
          columnIndex < columnWeights[rowIndex].count
        {
          return max(columnWeights[rowIndex][columnIndex], 0.1)
        }
        return CGFloat(1)
      }
      let totalColumnWeight = max(safeColumnWeights.reduce(0, +), 0.1)
      let topBoundary =
        rowIndex == 0 ? (left: rect.minY, right: rect.minY) : boundaries[rowIndex - 1]
      let bottomBoundary =
        rowIndex == rowCounts.count - 1
        ? (left: rect.maxY, right: rect.maxY) : boundaries[rowIndex]
      let topInset = rowIndex == 0 ? CGFloat.zero : separator / 2
      let bottomInset = rowIndex == rowCounts.count - 1 ? CGFloat.zero : separator / 2

      var verticalBoundaries: [(top: CGFloat, bottom: CGFloat)] = []
      for boundaryIndex in 0...columnCount {
        if boundaryIndex == 0 {
          verticalBoundaries.append((top: rect.minX, bottom: rect.minX))
        } else if boundaryIndex == columnCount {
          verticalBoundaries.append((top: rect.maxX, bottom: rect.maxX))
        } else {
          let precedingWeight = safeColumnWeights.prefix(boundaryIndex).reduce(0, +)
          let baseX = rect.minX + rect.width * precedingWeight / totalColumnWeight
          let alternatesRight =
            !alternating || (rowIndex + boundaryIndex).isMultiple(of: 2)
          let signedSlant =
            verticalMagnitude * (verticalSlope < 0 ? -1 : 1)
            * (alternatesRight ? 1 : -1)
          verticalBoundaries.append(
            (top: baseX - signedSlant / 2, bottom: baseX + signedSlant / 2)
          )
        }
      }

      for columnIndex in 0..<columnCount {
        let leftBoundary = verticalBoundaries[columnIndex]
        let rightBoundary = verticalBoundaries[columnIndex + 1]
        let leftInset = columnIndex == 0 ? CGFloat.zero : separator / 2
        let rightInset = columnIndex == columnCount - 1 ? CGFloat.zero : separator / 2
        let topLeftX = leftBoundary.top + leftInset
        let bottomLeftX = leftBoundary.bottom + leftInset
        let topRightX = rightBoundary.top - rightInset
        let bottomRightX = rightBoundary.bottom - rightInset
        let points = [
          CGPoint(x: topLeftX, y: boundaryY(topBoundary, at: topLeftX) + topInset),
          CGPoint(x: topRightX, y: boundaryY(topBoundary, at: topRightX) + topInset),
          CGPoint(x: bottomRightX, y: boundaryY(bottomBoundary, at: bottomRightX) - bottomInset),
          CGPoint(x: bottomLeftX, y: boundaryY(bottomBoundary, at: bottomLeftX) - bottomInset),
        ]
        let minX = points.map(\.x).min() ?? rect.minX
        let maxX = points.map(\.x).max() ?? rect.maxX
        let minY = points.map(\.y).min() ?? rect.minY
        let maxY = points.map(\.y).max() ?? rect.maxY
        let frame = CGRect(
          x: minX,
          y: minY,
          width: max(1, maxX - minX),
          height: max(1, maxY - minY)
        )
        let normalizedPoints = points.map {
          CGPoint(
            x: ($0.x - frame.minX) / frame.width,
            y: ($0.y - frame.minY) / frame.height
          )
        }
        frames.append(LayoutFrame(rect: frame, normalizedClipPolygon: normalizedPoints))
      }
    }
    return Array(frames.prefix(count))
  }

  private static func smartGridColumnCount(
    photoCount: Int,
    photoAspectRatios: [CGFloat],
    in rect: CGRect,
    spacing: CGFloat
  ) -> Int {
    guard photoCount > 1 else { return 1 }

    let safeRatios = photoAspectRatios.prefix(photoCount).map {
      min(4, max(0.25, Double($0)))
    }
    let ratios = safeRatios.isEmpty ? Array(repeating: 1.0, count: photoCount) : safeRatios
    let canvasAspectRatio = Double(rect.width / max(rect.height, 1))
    let canvasIsLandscape = canvasAspectRatio >= 1

    func score(columns: Int) -> Double {
      let rows = Int(ceil(Double(photoCount) / Double(columns)))
      let capacity = rows * columns
      let emptyCells = capacity - photoCount
      let lastRowCount = photoCount - (rows - 1) * columns
      let candidateFrameRatios = gridFrames(
        count: photoCount,
        in: rect,
        spacing: spacing,
        columns: columns,
        lastRow: .stretch
      ).map { frame in
        min(4, max(0.25, Double(frame.width / max(frame.height, 1))))
      }

      // Sorted log-ratio matching is the minimum total crop distance for these slots.
      let cropCost =
        zip(ratios.sorted(), candidateFrameRatios.sorted()).reduce(0.0) {
          total, pair in
          total + abs(log(pair.0 / pair.1))
        } / Double(photoCount)
      let unusedCellCost = Double(emptyCells) / Double(capacity) * 1.6
      let incompleteRowCost =
        emptyCells == 0
        ? 0
        : (1 - Double(lastRowCount) / Double(columns)) * 0.55
      let orientationCost: Double
      if (canvasIsLandscape && columns < rows) || (!canvasIsLandscape && columns > rows) {
        orientationCost = 0.18
      } else {
        orientationCost = 0
      }

      return cropCost + unusedCellCost + incompleteRowCost + orientationCost
    }

    return (1...photoCount).min { left, right in
      let leftScore = score(columns: left)
      let rightScore = score(columns: right)
      if abs(leftScore - rightScore) > 0.000_001 {
        return leftScore < rightScore
      }
      return canvasIsLandscape ? left > right : left < right
    } ?? 1
  }

  private static func framesAssignedByPhoto(
    visualFrames: [LayoutFrame],
    photos: [CollagePhoto]
  ) -> [LayoutFrame] {
    let count = visualFrames.count
    guard count > 1, photos.count == count else { return visualFrames }

    // Stable identity order means equally suitable photos do not fall back to picker order.
    let photoOrder = photos.indices.sorted {
      photos[$0].id.uuidString < photos[$1].id.uuidString
    }
    let stateCount = 1 << count
    var bestCosts = Array(repeating: Double.infinity, count: stateCount)
    var parentMasks = Array(repeating: -1, count: stateCount)
    var parentFrames = Array(repeating: -1, count: stateCount)
    bestCosts[0] = 0

    for mask in 0..<stateCount {
      let photoPosition = mask.nonzeroBitCount
      guard photoPosition < count, bestCosts[mask].isFinite else { continue }
      let photo = photos[photoOrder[photoPosition]]

      for frameIndex in visualFrames.indices where mask & (1 << frameIndex) == 0 {
        let nextMask = mask | (1 << frameIndex)
        let nextCost =
          bestCosts[mask] + placementCost(photo: photo, frame: visualFrames[frameIndex])
        if nextCost < bestCosts[nextMask] - 0.000_000_1 {
          bestCosts[nextMask] = nextCost
          parentMasks[nextMask] = mask
          parentFrames[nextMask] = frameIndex
        }
      }
    }

    var frameForPhoto = Array(repeating: 0, count: count)
    var mask = stateCount - 1
    while mask != 0 {
      let frameIndex = parentFrames[mask]
      let previousMask = parentMasks[mask]
      guard frameIndex >= 0, previousMask >= 0 else { return visualFrames }
      let photoPosition = previousMask.nonzeroBitCount
      frameForPhoto[photoOrder[photoPosition]] = frameIndex
      mask = previousMask
    }

    var result = visualFrames
    for (photoIndex, frameIndex) in frameForPhoto.enumerated() {
      result[photoIndex] = visualFrames[frameIndex]
    }
    return result
  }

  private static func placementCost(photo: CollagePhoto, frame: LayoutFrame) -> Double {
    let photoRatio = max(0.05, Double(photo.aspectRatio))
    let frameRatio = max(0.05, Double(frame.rect.width / max(frame.rect.height, 1)))
    let aspectCropCost = abs(log(photoRatio / frameRatio))

    let sourceWidth = max(1, Double(photo.pixelWidth))
    let sourceHeight = max(1, Double(photo.pixelHeight))
    let coverScale = max(
      Double(frame.rect.width) / sourceWidth,
      Double(frame.rect.height) / sourceHeight
    )
    let upscaleCost = max(0, log2(coverScale)) * 0.14

    let visibleFraction = min(photoRatio / frameRatio, frameRatio / photoRatio)
    let placementFocus: CGPoint
    if photo.focusSource == .manual {
      if let detectedFocusArea = photo.detectedFocusArea?.rect {
        placementFocus = CGPoint(x: detectedFocusArea.midX, y: detectedFocusArea.midY)
      } else {
        placementFocus = CGPoint(x: 0.5, y: 0.5)
      }
    } else {
      placementFocus = CGPoint(x: photo.focalX, y: photo.focalY)
    }
    let subjectEdgeCost: Double
    if photoRatio > frameRatio {
      subjectEdgeCost = focalEdgeCost(
        position: placementFocus.x,
        visibleFraction: visibleFraction
      )
    } else {
      subjectEdgeCost = focalEdgeCost(
        position: placementFocus.y,
        visibleFraction: visibleFraction
      )
    }

    return aspectCropCost + upscaleCost + subjectEdgeCost * (1 - visibleFraction) * 0.18
  }

  private static func focalEdgeCost(position: Double, visibleFraction: Double) -> Double {
    let visible = min(1, max(0.01, visibleFraction))
    let origin = min(max(position - visible / 2, 0), 1 - visible)
    let positionInCrop = min(1, max(0, (position - origin) / visible))
    return 1 - min(positionInCrop, 1 - positionInCrop) * 2
  }

  private static func weightedGridFrames(
    rowCounts: [Int],
    rowWeights: [Double],
    columnWeights: [[Double]],
    in rect: CGRect,
    spacing: CGFloat
  ) -> [CGRect] {
    guard !rowCounts.isEmpty else { return [] }
    let safeRowWeights = rowCounts.indices.map { index in
      max(index < rowWeights.count ? CGFloat(rowWeights[index]) : 1, 0.01)
    }
    let totalRowWeight = max(safeRowWeights.reduce(0, +), 0.01)
    let availableHeight = max(1, rect.height - CGFloat(rowCounts.count - 1) * spacing)
    var y = rect.minY
    var frames: [CGRect] = []

    for rowIndex in rowCounts.indices {
      let columnCount = max(1, rowCounts[rowIndex])
      let height = availableHeight * safeRowWeights[rowIndex] / totalRowWeight
      let safeColumnWeights = (0..<columnCount).map { columnIndex in
        if rowIndex < columnWeights.count, columnIndex < columnWeights[rowIndex].count {
          return max(CGFloat(columnWeights[rowIndex][columnIndex]), 0.01)
        }
        return CGFloat(1)
      }
      let totalColumnWeight = max(safeColumnWeights.reduce(0, +), 0.01)
      let availableWidth = max(1, rect.width - CGFloat(columnCount - 1) * spacing)
      var x = rect.minX
      for columnIndex in 0..<columnCount {
        let width = availableWidth * safeColumnWeights[columnIndex] / totalColumnWeight
        frames.append(CGRect(x: x, y: y, width: width, height: height))
        x += width + spacing
      }
      y += height + spacing
    }
    return frames
  }

  private static func gridFrames(
    count: Int,
    in rect: CGRect,
    spacing: CGFloat,
    columns requestedColumns: Int,
    lastRow: LastRowAlignment
  ) -> [CGRect] {
    guard count > 0 else { return [] }
    let columns = max(1, min(count, requestedColumns))
    let rows = Int(ceil(Double(count) / Double(columns)))
    let cellHeight = max(1, (rect.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))
    let regularWidth = max(1, (rect.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))

    return (0..<count).map { index in
      let row = index / columns
      let column = index % columns
      let itemsInRow = min(columns, count - row * columns)
      let width: CGFloat
      let offset: CGFloat

      if lastRow == .stretch && itemsInRow < columns {
        width = max(1, (rect.width - CGFloat(itemsInRow - 1) * spacing) / CGFloat(itemsInRow))
        offset = 0
      } else {
        width = regularWidth
        offset = CGFloat(columns - itemsInRow) * (regularWidth + spacing) / 2
      }

      return CGRect(
        x: rect.minX + offset + CGFloat(column) * (width + spacing),
        y: rect.minY + CGFloat(row) * (cellHeight + spacing),
        width: width,
        height: cellHeight
      )
    }
  }

  private static func heroFrames(
    count: Int,
    mainCount requestedMainCount: Int,
    in rect: CGRect,
    spacing: CGFloat,
    edge: LayoutEdge,
    fraction: CGFloat
  ) -> [CGRect] {
    guard count > 1 else { return [rect] }
    let mainCount = min(max(1, requestedMainCount), count - 1)
    let secondaryCount = count - mainCount
    let safeFraction = min(0.86, max(0.4, fraction))
    let mainRegion: CGRect
    let remainder: CGRect

    switch edge {
    case .top:
      let height = max(1, (rect.height - spacing) * safeFraction)
      mainRegion = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
      remainder = CGRect(
        x: rect.minX, y: mainRegion.maxY + spacing, width: rect.width,
        height: max(1, rect.height - height - spacing))
    case .bottom:
      let height = max(1, (rect.height - spacing) * safeFraction)
      remainder = CGRect(
        x: rect.minX, y: rect.minY, width: rect.width,
        height: max(1, rect.height - height - spacing))
      mainRegion = CGRect(
        x: rect.minX, y: remainder.maxY + spacing, width: rect.width, height: height)
    case .left:
      let width = max(1, (rect.width - spacing) * safeFraction)
      mainRegion = CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height)
      remainder = CGRect(
        x: mainRegion.maxX + spacing, y: rect.minY,
        width: max(1, rect.width - width - spacing), height: rect.height)
    case .right:
      let width = max(1, (rect.width - spacing) * safeFraction)
      remainder = CGRect(
        x: rect.minX, y: rect.minY,
        width: max(1, rect.width - width - spacing), height: rect.height)
      mainRegion = CGRect(
        x: remainder.maxX + spacing, y: rect.minY, width: width, height: rect.height)
    }

    let mainFrames: [CGRect]
    switch edge {
    case .top, .bottom:
      mainFrames = gridFrames(
        count: mainCount, in: mainRegion, spacing: spacing, columns: mainCount,
        lastRow: .stretch)
    case .left, .right:
      mainFrames = gridFrames(
        count: mainCount, in: mainRegion, spacing: spacing, columns: 1,
        lastRow: .stretch)
    }

    let secondaryColumns: Int
    switch edge {
    case .top, .bottom:
      secondaryColumns = max(
        1, Int(ceil(sqrt(Double(secondaryCount) * Double(rect.width / max(rect.height, 1))))))
    case .left, .right:
      secondaryColumns = max(
        1,
        Int(
          ceil(
            sqrt(Double(secondaryCount) * Double(remainder.width / max(remainder.height, 1)))))
      )
    }
    return mainFrames
      + gridFrames(
        count: secondaryCount, in: remainder, spacing: spacing,
        columns: secondaryColumns, lastRow: .stretch)
  }

  private static func bandFrames(
    counts: [Int],
    weights: [CGFloat],
    axis: LayoutAxis,
    in rect: CGRect,
    spacing: CGFloat
  ) -> [CGRect] {
    let usableCounts = counts.filter { $0 > 0 }
    guard !usableCounts.isEmpty else { return [] }
    let usableWeights = usableCounts.indices.map { index in
      index < weights.count ? max(weights[index], 0.1) : 1
    }
    let totalWeight = usableWeights.reduce(0, +)
    let totalSpacing = CGFloat(usableCounts.count - 1) * spacing
    let available = max(1, (axis == .vertical ? rect.height : rect.width) - totalSpacing)
    var cursor = axis == .vertical ? rect.minY : rect.minX
    var result: [CGRect] = []

    for index in usableCounts.indices {
      let length = available * usableWeights[index] / totalWeight
      let bandRect: CGRect
      if axis == .vertical {
        bandRect = CGRect(x: rect.minX, y: cursor, width: rect.width, height: length)
        result += gridFrames(
          count: usableCounts[index], in: bandRect, spacing: spacing,
          columns: usableCounts[index], lastRow: .stretch)
      } else {
        bandRect = CGRect(x: cursor, y: rect.minY, width: length, height: rect.height)
        result += gridFrames(
          count: usableCounts[index], in: bandRect, spacing: spacing,
          columns: 1, lastRow: .stretch)
      }
      cursor += length + spacing
    }
    return result
  }

  private static func mosaicFrames(
    count: Int,
    in rect: CGRect,
    spacing: CGFloat,
    seed: Int
  ) -> [CGRect] {
    var frames = [rect]
    let biases: [CGFloat] = [0.38, 0.45, 0.55, 0.62]

    for splitIndex in 1..<count {
      guard
        let largestIndex = frames.indices.max(by: {
          frames[$0].width * frames[$0].height < frames[$1].width * frames[$1].height
        })
      else { break }
      let frame = frames.remove(at: largestIndex)
      let alternatesAxis = (splitIndex + seed).isMultiple(of: 3)
      let splitVertically =
        alternatesAxis ? frame.width >= frame.height * 0.72 : frame.width >= frame.height
      let bias = biases[(splitIndex + seed) % biases.count]

      if splitVertically {
        let available = max(2, frame.width - spacing)
        let firstWidth = available * bias
        frames.insert(
          CGRect(
            x: frame.minX + firstWidth + spacing, y: frame.minY, width: available - firstWidth,
            height: frame.height),
          at: largestIndex)
        frames.insert(
          CGRect(x: frame.minX, y: frame.minY, width: firstWidth, height: frame.height),
          at: largestIndex)
      } else {
        let available = max(2, frame.height - spacing)
        let firstHeight = available * bias
        frames.insert(
          CGRect(
            x: frame.minX, y: frame.minY + firstHeight + spacing, width: frame.width,
            height: available - firstHeight),
          at: largestIndex)
        frames.insert(
          CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: firstHeight),
          at: largestIndex)
      }
    }
    return frames
  }

  private static func masonryFrames(
    count: Int,
    columns requestedColumns: Int,
    seed: Int,
    in rect: CGRect,
    spacing: CGFloat
  ) -> [CGRect] {
    let columns = max(1, min(count, requestedColumns))
    var groups = Array(repeating: [Int](), count: columns)
    for index in 0..<count { groups[index % columns].append(index) }
    let columnWidth = max(1, (rect.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    var indexedFrames: [(Int, CGRect)] = []
    let pattern: [CGFloat] = [1.25, 0.8, 1.05, 0.7]

    for column in groups.indices {
      let indices = groups[column]
      let weights = indices.indices.map { pattern[($0 + column + seed) % pattern.count] }
      let totalWeight = weights.reduce(0, +)
      let availableHeight = max(1, rect.height - CGFloat(max(0, indices.count - 1)) * spacing)
      var y = rect.minY
      for localIndex in indices.indices {
        let height = availableHeight * weights[localIndex] / totalWeight
        indexedFrames.append(
          (
            indices[localIndex],
            CGRect(
              x: rect.minX + CGFloat(column) * (columnWidth + spacing), y: y,
              width: columnWidth, height: height
            )
          ))
        y += height + spacing
      }
    }
    return indexedFrames.sorted { $0.0 < $1.0 }.map(\.1)
  }

  private static func brickFrames(
    count: Int,
    rows requestedRows: Int,
    offset: CGFloat,
    in rect: CGRect,
    spacing: CGFloat
  ) -> [CGRect] {
    let rows = max(1, min(count, requestedRows))
    let baseCount = count / rows
    let extra = count % rows
    let counts = (0..<rows).map { baseCount + ($0 < extra ? 1 : 0) }
    let rowHeight = max(1, (rect.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))
    var result: [CGRect] = []

    for row in 0..<rows {
      let itemCount = counts[row]
      let availableWidth = max(1, rect.width - CGFloat(itemCount - 1) * spacing)
      var weights = Array(repeating: CGFloat(1), count: itemCount)
      if itemCount > 1 {
        if row.isMultiple(of: 2) {
          weights[0] += offset * CGFloat(itemCount)
          weights[itemCount - 1] = max(0.25, weights[itemCount - 1] - offset * CGFloat(itemCount))
        } else {
          weights[itemCount - 1] += offset * CGFloat(itemCount)
          weights[0] = max(0.25, weights[0] - offset * CGFloat(itemCount))
        }
      }
      let totalWeight = weights.reduce(0, +)
      var x = rect.minX
      for weight in weights {
        let width = availableWidth * weight / totalWeight
        result.append(
          CGRect(
            x: x, y: rect.minY + CGFloat(row) * (rowHeight + spacing),
            width: width, height: rowHeight
          ))
        x += width + spacing
      }
    }
    return result
  }

  private static func stripFrames(
    count: Int,
    axis: LayoutAxis,
    featuredIndex: Int?,
    featuredWeight: CGFloat,
    in rect: CGRect,
    spacing: CGFloat
  ) -> [CGRect] {
    var weights = Array(repeating: CGFloat(1), count: count)
    if let featuredIndex, weights.indices.contains(featuredIndex) {
      weights[featuredIndex] = max(1, featuredWeight)
    }
    let totalWeight = weights.reduce(0, +)
    let available = max(
      1, (axis == .vertical ? rect.height : rect.width) - CGFloat(count - 1) * spacing)
    var cursor = axis == .vertical ? rect.minY : rect.minX
    return weights.map { weight in
      let length = available * weight / totalWeight
      defer { cursor += length + spacing }
      if axis == .vertical {
        return CGRect(x: rect.minX, y: cursor, width: rect.width, height: length)
      }
      return CGRect(x: cursor, y: rect.minY, width: length, height: rect.height)
    }
  }

  private static func cardFrames(
    count: Int,
    rotation: CGFloat,
    spread: CGFloat,
    in rect: CGRect
  ) -> [LayoutFrame] {
    let normalizedCount = CGFloat(max(1, count - 1))
    let widthFraction = max(0.34, 0.72 - CGFloat(max(0, count - 4)) * 0.025)
    let heightFraction = max(0.48, 0.84 - CGFloat(max(0, count - 4)) * 0.02)
    let width = rect.width * widthFraction
    let height = rect.height * heightFraction
    let travel = max(0, rect.width - width) * min(max(spread, 0.15), 0.8)
    let startX = rect.midX - width / 2 - travel / 2

    return (0..<count).map { index in
      let progress = count == 1 ? 0.5 : CGFloat(index) / normalizedCount
      let centered = progress * 2 - 1
      return LayoutFrame(
        rect: CGRect(
          x: startX + travel * progress,
          y: rect.midY - height / 2 + abs(centered) * rect.height * 0.035,
          width: width,
          height: height
        ),
        cornerRadiusFraction: 0.035,
        rotationDegrees: centered * rotation,
        zIndex: index
      )
    }
  }
}
