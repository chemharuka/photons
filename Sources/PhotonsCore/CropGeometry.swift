import Foundation
import Observation

// MARK: - 123: the transform's one geometry
//
// The rotation used to be derived in three places — the slider wrote an angle, the overlay turned
// its quad by its own `cos`/`sin`, and S0 computed the matrix a third time. Each copy was free to
// pick a sign, which is exactly the class of bug the 122 patch was chasing. `CropGeometry` is the
// one value: it is built from the document's `GeometryGroup` plus the upright source size and holds
// the rotation matrix, the crop rect and the effective canvas. Every reader (the overlay, the
// renderer's `S0Params`, the pixel readouts) asks this type instead of doing its own trigonometry.
//
// `rotation` is the **picture** rotation in screen (y-down) coordinates: `+θ` turns the picture
// clockwise. S0 walks the other way (canvas pixel → source pixel), so it reads the inverse
// (`inverseCosine` / `inverseSine`). The sign is therefore stated once, here, and a second caller
// cannot disagree with it by accident.
public struct CropGeometry: Sendable, Equatable {

    /// A rotation in y-down (screen) pixel space. `+degrees` is clockwise on screen.
    public struct RotationMatrix: Sendable, Equatable {
        public let cosine: Double
        public let sine: Double

        public init(degrees: Double) {
            let radians = (degrees.isFinite ? degrees : 0) * .pi / 180
            self.cosine = cos(radians)
            self.sine = sin(radians)
        }

        public init(cosine: Double, sine: Double) {
            self.cosine = cosine
            self.sine = sine
        }

        /// Picture → screen: `(x·c − y·s, x·s + y·c)`.
        public func apply(x: Double, y: Double) -> (x: Double, y: Double) {
            (x * cosine - y * sine, x * sine + y * cosine)
        }

        /// Screen → picture. The inverse of a rotation is its transpose.
        public func invert(x: Double, y: Double) -> (x: Double, y: Double) {
            (x * cosine + y * sine, -x * sine + y * cosine)
        }
    }

    /// The straighten angle in the document's own convention (positive = the angle stored by the
    /// picker before 123; the UI maps its positive slider through `TransformSession.setAngle`).
    public let rotationDegrees: Double
    public let rotation: RotationMatrix
    /// The crop rectangle, measured in the **turned** frame — the same rect S0 receives (`p.c`).
    public let crop: CropRect
    /// The source frame in the document's direction (quarter turn applied).
    public let source: ImageSize
    /// The picture the crop will produce, in pixels.
    public let canvas: ImageSize
    public let quarterTurns: Int
    public let flipHorizontal: Bool
    public let flipVertical: Bool
    public let aspectLock: AspectLock

    /// Aliases for the three things the spec names: matrix, crop rect, effective canvas.
    public var rotationMatrix: RotationMatrix { rotation }
    public var cropRect: CropRect { crop }
    public var effectiveCanvas: ImageSize { canvas }

    public init(geometry: GeometryGroup, source: ImageSize) {
        let oriented = geometry.orientedSource(source)
        let crop = geometry.renderCrop(source: source)
        self.rotationDegrees = geometry.straightenDegrees
        self.rotation = RotationMatrix(degrees: geometry.straightenDegrees)
        self.crop = crop
        self.source = oriented
        self.canvas = CropMath.outputSize(crop, in: oriented)
        self.quarterTurns = GeometryGroup.normalizedQuarterTurns(geometry.quarterTurns)
        self.flipHorizontal = geometry.flipHorizontal
        self.flipVertical = geometry.flipVertical
        self.aspectLock = geometry.aspectLock
    }

    /// The picture rotation's own cosine/sine — what the renderer needs for a canvas→source walk.
    public var cosine: Double { rotation.cosine }
    public var sine: Double { rotation.sine }
    /// S0 maps a canvas position back into the picture, so it uses the inverse rotation.
    public var inverseCosine: Double { rotation.cosine }
    public var inverseSine: Double { -rotation.sine }

    /// A normalized picture point turned by the picture's rotation about the picture centre.
    public func rotatedPoint(x: Double, y: Double) -> NormalizedPoint {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let dx = x - 0.5, dy = y - 0.5
        let turned = rotation.apply(x: dx * w, y: dy * h)
        return NormalizedPoint(0.5 + turned.x / w, 0.5 + turned.y / h)
    }

    /// The inverse of `rotatedPoint` — the walk an overlay or a drag does on an un-turned picture.
    public func unrotatedPoint(x: Double, y: Double) -> NormalizedPoint {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
        let dx = x - 0.5, dy = y - 0.5
        let turned = rotation.invert(x: dx * w, y: dy * h)
        return NormalizedPoint(0.5 + turned.x / w, 0.5 + turned.y / h)
    }

    /// `true` when the frame needs no resample at all.
    public var isIdentityRotation: Bool { rotationDegrees == 0 }
}

// MARK: - 123: the transform session (draft → document)

/// How a transform session ends. The three doors the acceptance names — ↵, Esc and the card's
/// 完成/应用 button — all funnel through `TransformSession.finish(_:)` (and, in the app,
/// `CropToolController.finish(_:)`), so their bookkeeping cannot drift.
public enum TransformFinish: String, Sendable, Equatable, CaseIterable {
    /// ↵ / 应用: write the draft once.
    case confirm
    /// Esc: throw the draft away; the document stays byte-identical.
    case cancel
    /// The card's 完成 button: the same write as `confirm`, a different UI spelling.
    case done
}

/// What a finish did: the geometry to write (`nil` for cancel), and whether the document moved.
public struct TransformCompletion: Sendable, Equatable {
    public let geometry: GeometryGroup?
    public let changed: Bool

    public init(geometry: GeometryGroup?, changed: Bool) {
        self.geometry = geometry
        self.changed = changed
    }

    public static let unchanged = TransformCompletion(geometry: nil, changed: false)
}

/// The transform workspace's draft: a document geometry seeded from the document, edited by the
/// UI, and written back only by `commit()` / `finish(.confirm)`.
///
/// **The UI→document sign lives in `setAngle(uiValue:)`.** Everything else (the overlay, S0, the
/// readouts) consumes the resulting `CropGeometry`; nobody else decides which way positive turns.
public struct TransformSession: Sendable, Equatable {

    /// The geometry the session started from — Esc's target and `hasChanges`' baseline.
    public private(set) var base: GeometryGroup
    public private(set) var draft: GeometryGroup
    /// The upright source frame the crop is measured in (before the quarter turn).
    public var source: ImageSize

    public init(geometry: GeometryGroup = .identity, source: ImageSize) {
        self.base = geometry
        self.draft = geometry
        self.source = source
    }

    /// Convenience for callers that spell the document rather than its geometry group.
    public init(document: EditModel, source: ImageSize) {
        self.init(geometry: document.geometry, source: source)
    }

    public var hasChanges: Bool { draft != base }
    public var isDirty: Bool { hasChanges }
    public var geometry: GeometryGroup { draft }
    public var committedGeometry: GeometryGroup { base }

    /// The one geometry both the overlay and the renderer consume.
    public var cropGeometry: CropGeometry {
        CropGeometry(geometry: draft, source: source)
    }

    public var effectiveCanvas: ImageSize { cropGeometry.canvas }

    /// The UI's slider value. `setAngle(uiValue:)` is the only place the sign is chosen.
    public var angleUIValue: Double { -draft.straightenDegrees }

    /// Slider positive → picture turns **clockwise**. The document's `rotationDegrees` is stored in
    /// the sign S0 has always consumed, so the UI's positive value is written negated — here and
    /// nowhere else.
    public mutating func setAngle(uiValue: Double) {
        let limit = GeometryGroup.straightenLimit
        let clamped = min(max(uiValue.isFinite ? uiValue : 0, -limit), limit)
        draft.rotationDegrees = -clamped
    }

    /// A ratio preset's lock, with the crop re-cut to it around the same centre.
    public mutating func setAspect(_ lock: AspectLock, source: ImageSize? = nil) {
        let src = draft.orientedSource(source ?? self.source)
        draft.aspectLock = lock
        draft.crop = CropMath.lockedCrop(lock, in: draft.cropRect, source: src).normalizedRect
    }

    public mutating func flip(horizontal: Bool) {
        if horizontal { draft.flipHorizontal.toggle() } else { draft.flipVertical.toggle() }
    }

    public mutating func rotate90(clockwise: Bool) {
        draft.turn(clockwise: clockwise)
    }

    /// Write the draft. Returns the new geometry (or `nil` when the document already matched it).
    @discardableResult
    public mutating func commit() -> GeometryGroup? {
        guard hasChanges else { return nil }
        base = draft
        return draft
    }

    /// Drop the draft; the document is untouched.
    @discardableResult
    public mutating func revert() -> GeometryGroup {
        draft = base
        return base
    }

    /// The one finish path: `confirm` / `done` commit, `cancel` reverts.
    @discardableResult
    public mutating func finish(_ outcome: TransformFinish) -> TransformCompletion {
        switch outcome {
        case .confirm, .done:
            guard let geometry = commit() else { return .unchanged }
            return TransformCompletion(geometry: geometry, changed: true)
        case .cancel:
            _ = revert()
            return .unchanged
        }
    }
}

/// An observable holder around `TransformSession` for SwiftUI readers. The value stays a value; the
/// holder only republishes the draft so the card redraws.
@Observable
public final class TransformSessionHolder {

    public var session: TransformSession

    public init(_ session: TransformSession) {
        self.session = session
    }

    public convenience init(geometry: GeometryGroup = .identity, source: ImageSize) {
        self.init(TransformSession(geometry: geometry, source: source))
    }

    public var cropGeometry: CropGeometry { session.cropGeometry }
    public var hasChanges: Bool { session.hasChanges }

    public func update(_ mutate: (inout TransformSession) -> Void) {
        var next = session
        mutate(&next)
        session = next
    }
}
