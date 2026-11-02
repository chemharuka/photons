import Foundation
import CoreGraphics
import Vision

// MARK: - 229 · the Vision half of 红眼
//
// One click, one request pair, on a ≤ 1024-long-edge sRGB copy — **never** in the render path.
//
//   · `VNDetectFaceLandmarksRequest` gives `leftEye` / `rightEye` regions. Their bounding box is
//     used only to size the search radius when the click lands on an eye; the pupil itself is still
//     found by `RedEye.detect`, from the pixels.
//   · `VNRecognizeAnimalsRequest` gives a species and a box. There are **no** dog/cat eye
//     landmarks in Vision, so a pet click gets a box-sized seed and the user's point. This type
//     never claims a pupil it did not measure.
//
// The request is synchronous and happens on the click only. `LinearImage` → sRGB CGImage reuses
// `SemanticMatteSource.sRGBImage(longEdge:)`, the codebase's one linear→encoded conversion.

/// One Vision observation in **image-normalised** coordinates (origin top-left, row 0 = top),
/// matching `NormalizedPoint`/`NormalizedRect` and the rest of the document.
public struct RedEyeFaceHint: Sendable, Equatable {

    public enum Kind: String, Sendable, Equatable {
        case face
        case animal
    }

    public let kind: Kind
    /// The face or animal box.
    public let bounds: NormalizedRect
    /// `leftEye` + `rightEye` boxes for a face; always empty for an animal.
    public let eyeBounds: [NormalizedRect]
    /// `VNRecognizedObjectObservation.labels` for an animal; empty for a face.
    public let labels: [String]

    public init(kind: Kind, bounds: NormalizedRect, eyeBounds: [NormalizedRect],
                labels: [String] = []) {
        self.kind = kind
        self.bounds = bounds
        self.eyeBounds = eyeBounds
        self.labels = labels
    }
}

public enum RedEyeVision {

    /// The analysis budget from §5.2: the model never sees the full frame.
    public static let analysisLongEdge = 1024

    /// Run faces + animals once. Returns `[]` on any Vision failure — a click with no hint simply
    /// falls back to the slider radius, which is the pre-detection path, not an error.
    public static func hints(in image: LinearImage, longEdge: Int = analysisLongEdge) -> [RedEyeFaceHint] {
        guard image.width > 1, image.height > 1 else { return [] }
        let source = SemanticMatteSource(width: image.width, height: image.height,
                                         rgba: image.rgba, contentHash: "")
        guard let cg = source.sRGBImage(longEdge: longEdge) else { return [] }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let faces = VNDetectFaceLandmarksRequest()
        let animals = VNRecognizeAnimalsRequest()
        do {
            try handler.perform([faces, animals])
        } catch {
            return []
        }

        var out: [RedEyeFaceHint] = []
        for observation in faces.results ?? [] {
            var eyes: [NormalizedRect] = []
            if let landmarks = observation.landmarks {
                for region in [landmarks.leftEye, landmarks.rightEye].compactMap({ $0 }) {
                    if let rect = eyeRect(faceBounds: observation.boundingBox,
                                          points: region.normalizedPoints) {
                        eyes.append(rect)
                    }
                }
            }
            out.append(RedEyeFaceHint(kind: .face,
                                      bounds: imageRect(observation.boundingBox),
                                      eyeBounds: eyes))
        }
        for observation in animals.results ?? [] {
            let labels = observation.labels.map(\.identifier)
            out.append(RedEyeFaceHint(kind: .animal,
                                      bounds: imageRect(observation.boundingBox),
                                      eyeBounds: [], labels: labels))
        }
        return out
    }

    /// Vision's normalised box (origin bottom-left) → the document's (origin top-left).
    public static func imageRect(_ box: CGRect) -> NormalizedRect {
        NormalizedRect(x: Double(box.minX),
                       y: Double(1 - box.maxY),
                       width: Double(box.width),
                       height: Double(box.height)).clamped()
    }

    /// The landmark region's box in **image-normalised** coordinates.
    ///
    /// `normalizedPoints` are relative to the face box and use Vision's bottom-left origin, so the
    /// conversion is: face box in image space → landmark box in face space → flip y. Kept public and
    /// pure so the geometry can be tested without a camera or a model.
    public static func eyeRect(faceBounds: CGRect, points: [CGPoint]) -> NormalizedRect? {
        guard !points.isEmpty else { return nil }
        let xs = points.map { Double($0.x) }
        let ys = points.map { Double($0.y) }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        let x = Double(faceBounds.minX) + minX * Double(faceBounds.width)
        let width = (maxX - minX) * Double(faceBounds.width)
        let height = (maxY - minY) * Double(faceBounds.height)
        let bottom = Double(faceBounds.minY) + minY * Double(faceBounds.height)
        let y = 1 - (bottom + height)
        guard width > 0, height > 0 else { return nil }
        return NormalizedRect(x: x, y: y, width: width, height: height).clamped()
    }
}
