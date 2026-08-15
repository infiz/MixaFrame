import CoreGraphics
import Vision

struct SubjectDetection: Sendable {
  let focusPoint: CGPoint
  let focusArea: PhotoFocusArea?
}

enum SubjectDetector {
  static func detect(in image: CGImage) -> SubjectDetection {
    let faceRequest = VNDetectFaceRectanglesRequest()
    let saliencyRequest = VNGenerateAttentionBasedSaliencyImageRequest()
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up)

    do {
      try handler.perform([faceRequest, saliencyRequest])

      if let faces = faceRequest.results, !faces.isEmpty {
        return detection(for: faces.map(\.boundingBox))
      }

      if let objects = saliencyRequest.results?.first?.salientObjects, !objects.isEmpty {
        return detection(for: Array(objects.prefix(4).map(\.boundingBox)))
      }
    } catch {
      return SubjectDetection(focusPoint: CGPoint(x: 0.5, y: 0.5), focusArea: nil)
    }

    return SubjectDetection(focusPoint: CGPoint(x: 0.5, y: 0.5), focusArea: nil)
  }

  static func detection(for boxes: [CGRect]) -> SubjectDetection {
    guard let first = boxes.first else {
      return SubjectDetection(focusPoint: CGPoint(x: 0.5, y: 0.5), focusArea: nil)
    }
    let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    let union = boxes.dropFirst().reduce(first.standardized) { $0.union($1.standardized) }
      .intersection(unitRect)
    guard !union.isNull, union.width > 0, union.height > 0 else {
      return SubjectDetection(focusPoint: CGPoint(x: 0.5, y: 0.5), focusArea: nil)
    }

    let topLeadingArea = CGRect(
      x: union.minX,
      y: 1 - union.maxY,
      width: union.width,
      height: union.height
    )
    return SubjectDetection(
      focusPoint: CGPoint(x: topLeadingArea.midX, y: topLeadingArea.midY),
      focusArea: PhotoFocusArea(topLeadingArea)
    )
  }
}
