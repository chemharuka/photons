// PhotonsDepth — Depth Anything V2 Small (Core ML, F16) inference surface.
//
// **Scaffold written by the dispatch session, not by a worker.** The public API below is the contract;
// the bodies that are `throw`/`fatalError` are the work. Keep the names: `DepthMap`, `DepthModel`,
// `DepthError` and the `revison` constant are referenced by the spec (task 120) and by the cache key.
//
// Licence: the weights are Apache-2.0 (`apple/coreml-depth-anything-v2-small`); see
// `Resources/Depth-Anything-V2-LICENSE.txt` and `THIRD_PARTY_NOTICES.md`. Never claim endorsement.
import CoreML
import Foundation
import PhotonsCore

/// A relative depth map, in the model's own units: **larger value = nearer** (the model emits disparity).
/// Consumers must not assume `0…1`; normalise first (`normalised()`), and never let the sign flip
/// between the dehaze assist and the depth mask — that is the same bug class as a mirrored mask.
public struct DepthMap: Sendable {
    public let width: Int
    public let height: Int
    /// Row-major, `width * height`, disparity (near = large). Float16 keeps a 4096-long-edge map at ~32 MB.
    public let values: [Float16]

    public init(width: Int, height: Int, values: [Float16]) {
        self.width = width
        self.height = height
        self.values = values
    }

    /// Min-max normalised copy in `0…1` (near = 1). Returns `nil` for a flat map (no range to stretch).
    public func normalised() -> DepthMap? { nil }
}

public enum DepthError: Error, CustomStringConvertible {
    case modelMissing(String)
    case badInputSize(expected: (Int, Int), got: (Int, Int))
    case featureMismatch(String)
    case inferenceFailed(String)

    public var description: String {
        switch self {
        case .modelMissing(let what): return "depth model missing: \(what)"
        case .badInputSize(let e, let g): return "depth input size \(g) != model \(e)"
        case .featureMismatch(let s): return "depth feature mismatch: \(s)"
        case .inferenceFailed(let s): return "depth inference failed: \(s)"
        }
    }
}

/// Loads `DepthAnythingV2SmallF16.mlmodelc` from the app bundle and runs one inference per image.
///
/// The input geometry is read from `MLModelDescription` at load time — never hard-code 518×396. The
/// model card's 518 is an *evaluation* size; the description is the only truth.
public final class DepthModel: @unchecked Sendable {
    /// Bumped whenever the weights change. Part of every depth cache key; keep the weight SHA in it.
    public static let revision = "dav2s-f16@cfef6f6"

    public let inputWidth: Int
    public let inputHeight: Int

    public init(bundle: Bundle = .main) throws {
        throw DepthError.modelMissing("DepthAnythingV2SmallF16.mlmodelc (scaffold — implement me)")
    }

    /// One inference on an already-decoded pixel buffer. Caller owns the resize to `inputWidth×inputHeight`.
    public func infer(pixelBuffer: CVPixelBuffer) throws -> DepthMap {
        throw DepthError.inferenceFailed("scaffold — implement me")
    }
}
