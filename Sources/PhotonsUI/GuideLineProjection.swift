import CoreGraphics
import PhotonsCore

// MARK: - 354 · 引导线: one projection, `P → R → view`
//
// The endpoints of a guide line are **source pixels** — what the photograph holds — and they are the
// only thing stored. This type is the one place they are turned into something on the screen:
//
//     source px ──norm──▶ P ──×(W,H)──▶ R(θ) about (W/2, H/2) ──▶ canvas px ──camera──▶ view px
//
// `P` is `PerspectiveMap.forward` on the photo-normalized domain and `R` is a turn about the
// photograph's own centre in pixels — `CropMath.perspectiveCanvas`'s `R · P`, the order the kernel
// takes.
//
// **Two halves, and both are somebody else's function.**
//
//   · In the crop workspace (`LoupeMapping.transform.canvasRole == .document`, the only place guide
//     lines exist) the walk is `CropGeometry.documentPointInCanvas` + `LoupeMapping.documentView` — the exact
//     pair `CropTool.layout` draws the crop quad with (`CropTool.swift:328-332`). Nothing here
//     re-derives a corner, and `GuideLines354DisplayTests` §A measures the distance as 0.00e+00 px
//     over `P = 0/±60`, `s = 0/±9°`, fit and 400 %.
//   · Anywhere else (a `.export` mapping — what a finished document is drawn with, and what the
//     337/348 fixtures build) it is `FrameTransform.sourceToView`, 261's one per-frame transform,
//     because that is the walk whose own inverse (`viewPointToSource`) reads every drag in the app.
//
// **Nothing is cached.** The projection is a value built from the document and the current
// `LoupeMapping`; a zoom, a pan, a fit, a keystone move or a straighten produces a new value, and the
// lines are re-derived from their source endpoints on every draw pass. There is no invalidation key
// to get wrong because there is no cache to invalidate.
//
// **Why not `mapping.frameView(R·P(p))` alone.** That window is centred on the *crop rect*, while the
// document canvas is the AABB of the warped quad; for `P = 60` on a 1200 px frame the two centres are
// 32 px apart, so a line placed that way lands 32 px off the picture (measured, §1 of the report).

/// One guide line endpoint, decided by `P`, `R` and the camera in that order.
public struct GuideLineProjection: Sendable, Equatable {

    /// The source grid the endpoints are measured in — the **oriented** source (the quarter turn is
    /// already in it), the same `ImageSize` the mapping was built from.
    public var source: ImageSize
    /// The document's keystone. `nil` (or 0/0) is the identity, i.e. every pre-183 document.
    public var perspective: PerspectiveMap?
    /// The document's straighten, in degrees.
    public var straightenDegrees: Double
    /// The camera: fit / zoom / pan, in device pixels.
    public var mapping: LoupeMapping

    /// **Reverse gate ①** — display skips `P` (only `R · view` is applied). `false` ships; the
    /// acceptance sets it and watches 「跟随透视」 go red.
    public let omitsPerspective: Bool
    /// **Reverse gate ②** — display stops before the camera (the line is drawn in frame pixels, so
    /// zooming does not stretch it). `false` ships; the acceptance sets it and watches 「跟随缩放」 go
    /// red.
    public let omitsViewScale: Bool

    /// 324's `P → R` in document-canvas pixels, with the **displayed** perspective (gate ① cleared)…
    private let display: CropGeometry
    /// …and with the document's own, which is what a drag's inverse must use — a gate is a display
    /// question and never a write.
    private let material: CropGeometry

    public init(source: ImageSize,
                perspective: PerspectiveMap? = nil,
                straightenDegrees: Double = 0,
                mapping: LoupeMapping,
                omitsPerspective: Bool = false,
                omitsViewScale: Bool = false) {
        self.source = source
        self.perspective = perspective
        let angle = straightenDegrees.isFinite ? straightenDegrees : 0
        self.straightenDegrees = angle
        self.mapping = mapping
        self.omitsPerspective = omitsPerspective
        self.omitsViewScale = omitsViewScale
        let shown = perspective.flatMap { $0.hasWarp && !omitsPerspective ? $0 : nil }
        self.display = Self.geometry(source: source, straighten: angle, perspective: shown)
        self.material = Self.geometry(source: source, straighten: angle,
                                      perspective: perspective.flatMap { $0.hasWarp ? $0 : nil })
    }

    private static func geometry(source: ImageSize, straighten: Double,
                                 perspective: PerspectiveMap?) -> CropGeometry {
        CropGeometry(
            geometry: GeometryGroup(crop: .full,
                                    rotationDegrees: straighten,
                                    aspectLock: .original,
                                    quarterTurns: 0,
                                    perspectiveVertical: perspective?.vertical ?? 0,
                                    perspectiveHorizontal: perspective?.horizontal ?? 0,
                                    cropSpace: .source),
            source: source)
    }

    // MARK: the geometry

    /// The keystone as the display reads it — `nil` under gate ①.
    private var warp: PerspectiveMap? {
        guard !omitsPerspective, let perspective, perspective.hasWarp else { return nil }
        return perspective
    }

    /// The crop workspace's own canvas — the one `CropTool.layout` draws the quad on.
    private var usesDocumentCanvas: Bool { mapping.transform?.canvasRole == .document }

    private var width: Double { Double(max(source.width, 1)) }
    private var height: Double { Double(max(source.height, 1)) }

    // MARK: source → screen

    /// A **source** pixel on the screen, `P → R → view`. The one function the overlay, the hit tests
    /// and the acceptance all ask.
    public func screenPoint(_ point: CGPoint) -> CGPoint {
        if omitsViewScale {
            // Gate ②: the line stops before the camera, so a zoom cannot stretch it.
            return framePixel(point)
        }
        if usesDocumentCanvas {
            let doc = display.documentPointInCanvas(normalizedX: Double(point.x) / width,
                                            Double(point.y) / height)
            if let drawn = mapping.documentView(doc) { return drawn }
        }
        if let transform = mapping.transform {
            let v = transform.sourceToView(SIMD2(Double(point.x), Double(point.y)))
            return CGPoint(x: v.x, y: v.y)
        }
        // No camera to ask (a mapping built without a `FrameTransform`): the picture's own `R` and
        // then the frame window — `LoupeMapping.viewPoint`'s arithmetic, term for term.
        let v = mapping.viewPoint(sourceX: Double(point.x), sourceY: Double(point.y))
        return CGPoint(x: v.x, y: v.y)
    }

    /// The picture's own pixel (`P` then `R`) — no camera. Gate ②'s answer, and the one space a
    /// length can be measured in without the view entering it.
    private func framePixel(_ point: CGPoint) -> CGPoint {
        let w = width, h = height
        var nx = Double(point.x) / w, ny = Double(point.y) / h
        if let warp {
            let warped = warp.forward(x: nx, y: ny)
            nx = warped.x
            ny = warped.y
        }
        let turned = turn(x: nx * w - w / 2, y: ny * h - h / 2)
        return CGPoint(x: turned.x + w / 2, y: turned.y + h / 2)
    }

    /// The whole line, on the screen.
    public func segments(of lines: [GuideLine]) -> [CropToolSegment] {
        lines.map { CropToolSegment(a: screenPoint($0.a), b: screenPoint($0.b)) }
    }

    // MARK: screen → source

    /// A **view** point back in source pixels — the exact inverse of `screenPoint`, which is what a
    /// drag writes: 「屏幕落点 → 反算源像素 → 存 → 重新求解」. The gates are deliberately ignored: a
    /// display switch must never change what a drag stores.
    public func sourcePoint(viewX: Double, viewY: Double) -> CGPoint {
        let w = width, h = height
        if usesDocumentCanvas, let doc = mapping.documentPoint(viewX: viewX, viewY: viewY) {
            let normalised = material.photoNormalized(documentX: doc.x, doc.y)
            return CGPoint(x: normalised.x * w, y: normalised.y * h)
        }
        if let transform = mapping.transform {
            let p = transform.viewPointToSource(SIMD2(viewX, viewY))
            return CGPoint(x: p.x, y: p.y)
        }
        let frame = mapping.framePoint(viewX: viewX, viewY: viewY)
        let turned = turn(x: frame.x - w / 2, y: frame.y - h / 2, inverse: true)
        return CGPoint(x: turned.x + w / 2, y: turned.y + h / 2)
    }

    // MARK: the turn

    private func turn(x: Double, y: Double, inverse: Bool = false) -> (x: Double, y: Double) {
        let r = CropGeometry.RotationMatrix(degrees: inverse ? -straightenDegrees : straightenDegrees)
        return r.apply(x: x, y: y)
    }
}
