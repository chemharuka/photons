import CoreGraphics
import Foundation
import PhotonsCore

// MARK: - the crop tool's geometry (task 035)
//
// The interaction layer for 旋转/裁切, and deliberately **pure**: no view, no window, no session.
// Everything is a function of
//
//     (crop rect, upright source size, LoupeMapping, backing scale)  →  what to draw / what a drag means
//
// so the four questions a canvas asks each have one answer and each can be measured without a
// screen — exactly the shape `MaskHandles` (task 032) established for the mask grips:
//
//   1. **What is on screen?** `layout(…)` — the crop quad in **view points**, the eight handles, and
//      the rule-of-thirds lines. The overlay draws this and nothing else; the hit test reads it too,
//      so what is drawn and what is grabbable cannot drift apart.
//   2. **Which grip did the click land on?** `hit(_:in:)` — corners before edges before "inside",
//      all distances in **points**, so a grip is the same size on screen at 25 % and at 400 %.
//   3. **What does the drag mean?** `CropToolDrag.crop(at:source:lock:)` — a pure function of the rect
//      at mouse-down, the point the hand grabbed and the point it is at now. Absolute, not
//      incremental: a drag cannot accumulate rounding drift and replaying it gives the same rect.
//   4. **What is the ratio rule?** `constrain` (a drag pins the opposite corner) and `matching`
//      (picking a preset keeps the centre and the area).
//
// **One projection.** Nothing here computes a screen coordinate itself: every point goes through
// `LoupeMapping.viewPoint`, the inverse of S0 that the mask grips and the loupe already share. That
// is what makes a portrait file (EXIF 6/8, stored 240×160, upright 160×240) as accurate as a
// landscape one — the frame handed in is `CatalogSession.maskSourceSize`, the **upright** frame the
// renderer ingested, never `asset.width/height`.
//
// Borrowed from the MIT references (see the report for the line numbers):
//   · Brightroom's eight control points — four corners that move two edges and four edges that move
//     one — with a fixed point inflation around each (`CropView._InteractiveCropGuideView.swift`
//     `:51-59`, `:100-174`, `:613-963`), and its aspect constraint activated *for the duration of the
//     drag* (`:589-598`);
//   · its minimum size floor (`:72`) and its "inside drag scrolls the picture, outside drag builds a
//     new frame" split (`CropView.swift:2245-2274`);
//   · Phos's contract that a precision tool is a **temporary fit** over the session viewport
//     (`WINDOW_INTEGRATION.md:14`) and that `cropMode` is view state, not a document field
//     (`Sources/Phos/AppMain.swift:124`).

// MARK: - which grip

/// The eight grips of a crop frame plus the two "not a grip" answers.
///
/// The names are **source edges**, not screen edges: `.left` moves `CropRect.left`. A flipped or
/// straightened picture therefore draws the grip somewhere else on screen, while a drag on it still
/// moves the edge under the hand — the pointer is converted back through `LoupeMapping`, which
/// already undoes the rotation and the flips, so no case here needs to know about either.
public enum CropToolHandle: String, Sendable, Equatable, Hashable, CaseIterable {
    case topLeft
    case topRight
    case bottomRight
    case bottomLeft
    case top
    case right
    case bottom
    case left
    /// The hand landed inside the frame: the picture moves under it (the frame does not move).
    case inside
    /// The hand landed outside the frame: a new frame is being drawn.
    case outside

    public var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: return true
        default: return false
        }
    }

    public var isEdge: Bool {
        switch self {
        case .top, .right, .bottom, .left: return true
        default: return false
        }
    }

    /// True for the nine grips that resize the frame (everything but `.inside` / `.outside`).
    public var isResizing: Bool { isCorner || isEdge }

    /// **355 — which edges this grip moves**, for the per-tick 「不出像素」 press. `.inside` (a move)
    /// and `.outside` (a new frame) have none: a move never resizes (310), and a new frame is already
    /// bounded by the canvas it is drawn in.
    public var draggedEdges: CropEdges? {
        switch self {
        case .topLeft: return [.top, .left]
        case .topRight: return [.top, .right]
        case .bottomRight: return [.bottom, .right]
        case .bottomLeft: return [.bottom, .left]
        case .top: return [.top]
        case .right: return [.right]
        case .bottom: return [.bottom]
        case .left: return [.left]
        case .inside, .outside: return nil
        }
    }

    /// Where the *opposite* side stays pinned while this grip is dragged.
    public var anchor: CropToolAnchor {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomRight: return .topLeft
        case .bottomLeft: return .topRight
        case .top: return .bottom
        case .right: return .left
        case .bottom: return .top
        case .left: return .right
        case .inside, .outside: return .center
        }
    }

    public var label: String {
        switch self {
        case .topLeft: return "左上角"
        case .topRight: return "右上角"
        case .bottomRight: return "右下角"
        case .bottomLeft: return "左下角"
        case .top: return "上边"
        case .right: return "右边"
        case .bottom: return "下边"
        case .left: return "左边"
        case .inside: return "框内"
        case .outside: return "框外"
        }
    }
}

/// The point of the frame that a resize keeps fixed.
public enum CropToolAnchor: Sendable, Equatable, Hashable {
    case topLeft, topRight, bottomRight, bottomLeft
    case top, bottom, left, right
    case center
}

public struct CropToolSegment: Sendable, Equatable {
    public var a: CGPoint
    public var b: CGPoint

    public init(a: CGPoint, b: CGPoint) {
        self.a = a
        self.b = b
    }
}

// MARK: - layout (what the canvas draws and hit-tests)

/// Everything the canvas needs about the crop frame, in **view points** (y down, flipped).
public struct CropToolLayout: Sendable, Equatable {
    public struct Grip: Sendable, Equatable {
        public var kind: CropToolHandle
        /// The grip's centre, in view points.
        public var point: CGPoint
    }

    /// The four corners of the crop rect projected through the mapping, in source order
    /// (top-left, top-right, bottom-right, bottom-left). With a straighten angle this is a
    /// **rotated** quad — the box turns with the picture, which is what Lightroom shows too.
    public var corners: [CGPoint]
    public var grips: [Grip]
    /// Rule-of-thirds lines (only when the grid is on).
    public var grid: [CropToolSegment]
    /// 132: the frame covers pixels outside the photograph (including the rotated-out margins). The
    /// overlay paints its stroke and grips red. A **view fact only** — it never moves the rect, never
    /// writes the document and never enters a render key.
    public var exceedsPicture: Bool

    public init(corners: [CGPoint] = [], grips: [Grip] = [], grid: [CropToolSegment] = [],
                exceedsPicture: Bool = false) {
        self.corners = corners
        self.grips = grips
        self.grid = grid
        self.exceedsPicture = exceedsPicture
    }

    public var isEmpty: Bool { corners.count < 4 }

    public var center: CGPoint {
        guard corners.count == 4 else { return .zero }
        return CGPoint(x: (corners[0].x + corners[1].x + corners[2].x + corners[3].x) / 4,
                       y: (corners[0].y + corners[1].y + corners[2].y + corners[3].y) / 4)
    }

    /// Width and height of the frame in points — the numbers the bar prints next to the ratio.
    public var sizeInPoints: CGSize {
        guard corners.count == 4 else { return .zero }
        return CGSize(width: hypot(corners[1].x - corners[0].x, corners[1].y - corners[0].y),
                      height: hypot(corners[3].x - corners[0].x, corners[3].y - corners[0].y))
    }
}

// MARK: - the picture's screen transform, mid-animation

/// `p ↦ scale·p + offset`, in **device pixels, y down** — the screen transform the zoom bridge draws
/// the picture with while a stop change is travelling.
///
/// It exists because a bridge frame is not a camera: the pixels on the canvas are the previous
/// projection's, carried by a similarity (`LoupeZoomBridge.map(atProgress:)`). Projecting the crop
/// rect through that same similarity is what makes the frame, its eight grips and its grid sit on the
/// picture *the eye is looking at* on every frame of the transition, instead of jumping to the target
/// geometry on the first one (2026-10-27: 「裁切框在缩放动画中不跟着动」).
///
/// `.identity` is the no-animation case, and it is exactly the old arithmetic.
public struct CropCarry: Sendable, Equatable {
    public var scale: Double
    public var offsetX: Double
    public var offsetY: Double

    public init(scale: Double = 1, offsetX: Double = 0, offsetY: Double = 0) {
        self.scale = scale
        self.offsetX = offsetX
        self.offsetY = offsetY
    }

    public static let identity = CropCarry()

    public func applyX(_ x: Double) -> Double { scale * x + offsetX }
    public func applyY(_ y: Double) -> Double { scale * y + offsetY }

    /// The carry one bridge frame is drawn with, read off the bridge's own map — the value the present
    /// pass used for that same frame, not a second interpolation of our own.
    public init(_ map: (scale: Double, x: Double, y: Double)) {
        self.init(scale: map.scale, offsetX: map.x, offsetY: map.y)
    }
}

// MARK: - 362: the one projection (drawn with it, read back with it)

/// **The one map between a crop rect's own normalized space and view points.**
///
/// The overlay draws every corner, grip and grid line with `view(u, v)`; a pointer is read back with
/// `normalized(viewX:viewY:)`, which is this same value's exact inverse. Before 362 the drawing had a
/// private `view` closure inside `CropTool.layout` and the drag had `CropToolController.cropBoxPoint`
/// — its own chain of branches over `liveCropSpace` / `livePerspective`. Two spellings of one map,
/// each free to pick a different walk: that is the class of bug 355 could not see, because its
/// acceptance compared the *input* map with the *input* map.
///
/// One struct, one branch decision, and the walk every reader already trusts:
///
///   · `.canvas` (330) — a rectangle of the document canvas: `documentView(u·W, v·H)` with
///     `(W, H) = photoQuadExtent`, and its inverse `documentPoint ÷ (W, H)`;
///   · `.keystone` — a rectangle of the photograph on a warped document: `P → R → documentView`,
///     inverted by `photoNormalized`;
///   · `.frame` — the un-warped case: `R(−θ)` about the photograph's centre + the camera's frame map,
///     inverted by `framePoint` + `R(+θ)`.
///
/// **368 — the drag has no second map.** `layout` draws through this value and `cropBoxPoint` reads
/// the pointer back through the same value; the branch above is the *document's* space (330's
/// one-time decision), not a per-tick conversion. The tick's rect stays in that one space from the
/// pointer read to the single `draft.crop` write.
public struct CropToolProjection {

    /// Pixels per unit of the rect's own space, on each axis. `[0,1]²` of a `.source` rect is the
    /// photograph; of a `.canvas` rect it is the document canvas (`photoQuadExtent`) — which is why a
    /// size law (a ratio lock, the minimum span) must ask this instead of the source size.
    public let units: CropUnits

    enum Space {
        case canvas(CropGeometry, LoupeMapping)
        case keystone(CropGeometry, LoupeMapping)
        case frame(CropGeometry.RotationMatrix, LoupeMapping, width: Double, height: Double)
    }

    let space: Space
    let scale: Double
    let carry: CropCarry

    /// The rect's own space → view points (y down). The one exit the overlay draws through.
    public func view(_ u: Double, _ v: Double) -> CGPoint {
        let drawn: CGPoint
        switch space {
        case .canvas(let geometry, let mapping):
            let e = geometry.photoQuadExtent
            guard let p = mapping.documentView(DocumentPoint(u * e.width, v * e.height)) else {
                return .zero
            }
            drawn = p
        case .keystone(let geometry, let mapping):
            guard let p = mapping.documentView(geometry.documentPointInCanvas(normalizedX: u, v)) else {
                return .zero
            }
            drawn = p
        case .frame(let rotation, let mapping, let width, let height):
            let dx = u * width - width / 2, dy = v * height - height / 2
            let turned = rotation.invert(x: dx, y: dy)
            let q = mapping.frameView(frameX: width / 2 + turned.x, frameY: height / 2 + turned.y)
            drawn = CGPoint(x: q.x, y: q.y)
        }
        return CGPoint(x: carry.applyX(Double(drawn.x)) / scale,
                       y: carry.applyY(Double(drawn.y)) / scale)
    }

    /// View points → the rect's own space. **The inverse of `view`**, branch for branch.
    public func normalized(viewX: Double, viewY: Double) -> NormalizedPoint? {
        let x = (viewX * scale - carry.offsetX) / (carry.scale == 0 ? 1 : carry.scale)
        let y = (viewY * scale - carry.offsetY) / (carry.scale == 0 ? 1 : carry.scale)
        switch space {
        case .canvas(let geometry, let mapping):
            guard let document = mapping.documentPoint(viewX: x, viewY: y) else { return nil }
            let e = geometry.photoQuadExtent
            guard e.width > 0, e.height > 0 else { return nil }
            return NormalizedPoint(document.x / e.width, document.y / e.height)
        case .keystone(let geometry, let mapping):
            guard let document = mapping.documentPoint(viewX: x, viewY: y) else { return nil }
            return geometry.photoNormalized(documentX: document.x, document.y)
        case .frame(let rotation, let mapping, let width, let height):
            let p = mapping.framePoint(viewX: x, viewY: y)
            guard p.x.isFinite, p.y.isFinite else { return nil }
            let turned = rotation.apply(x: p.x - width / 2, y: p.y - height / 2)
            return NormalizedPoint((width / 2 + turned.x) / width, (height / 2 + turned.y) / height)
        }
    }
}

/// Pixels per unit of a crop rect's own space — the unit a **size** law has to convert with.
public struct CropUnits: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// The photograph's own grid — every `.source` rect.
    public init(_ source: ImageSize) {
        self.init(width: Double(max(source.width, 1)), height: Double(max(source.height, 1)))
    }
}

// MARK: - the tool

public enum CropTool {

    // MARK: constants

    /// Hit radius for a corner, in **points**. A corner is the grip the hand reaches for first, so
    /// it is the bigger target; Brightroom inflates its 44 pt corner targets by 16 pt on every side
    /// (`CropView._InteractiveCropGuideView.swift:51-59`, `:322-324`), and 12 pt around a 0-size
    /// point is the same idea at this scale.
    public static let cornerHitRadiusPoints: Double = 12

    /// Hit radius for an edge, in points. Smaller than a corner's so the two corners of a narrow
    /// frame cannot swallow an edge click.
    public static let edgeHitRadiusPoints: Double = 9

    /// The smallest frame a drag may leave behind, in **pixels of the upright source**: 32 px is
    /// small enough to crop a postage stamp at 100 % and large enough that a stray twitch cannot
    /// collapse the frame to nothing (Brightroom's floor is 80 pt, `:72`).
    public static let minimumSpanPixels: Double = 32

    /// The straighten range, re-exported from the document's own limit so the slider and the kernel
    /// cannot disagree.
    public static var straightenLimit: Double { GeometryGroup.straightenLimit }

    // MARK: layout

    /// The frame, its grips and its grid in **view points**.
    ///
    /// `pointScale` is the backing scale (device pixels per point) and is only ever a divisor: the
    /// mapping produces device pixels because the renderer works in them, and everything a hand
    /// touches is in points.
    ///
    /// `carry` is the **picture's own screen transform** — `p ↦ scale·p + offset` in device pixels,
    /// applied after the projection (2026-10-27, the overlay-follows-the-zoom-animation fix). During a
    /// stop change the pixels on the canvas are the *old* picture carried by `LoupeZoomBridge`'s
    /// similarity, and a bridge frame is not any camera, so no `LoupeMapping` describes it: the frame
    /// has to be projected by the old mapping and then carried. Identity (the default, and every
    /// non-animating call) leaves the arithmetic exactly as it was — `1·p + 0` is `p`.
    ///
    /// `quadRotationDegrees` is 088's 「图不转、框转」: while the 转动 slider is being dragged the
    /// canvas still holds the document's pixels (`mapping` is the document's framing, no draft angle),
    /// so the crop rect — which lives axis-aligned in the **rotated image space** — is turned by
    /// `−(θ − θ₀)` about the image centre *before* it reaches `frameView`. The four corners, the eight
    /// grips and the grid all go through this one function, so they cannot disagree. At the committed
    /// angle the delta is 0 and the arithmetic is the old, axis-aligned one.
    public static func layout(crop: CropRect,
                              source: ImageSize,
                              mapping: LoupeMapping,
                              pointScale: Double = 1,
                              showsGrid: Bool = true,
                              carry: CropCarry = .identity,
                              quadRotationDegrees: Double = 0,
                              cropSpace: CropSpace = .source,
                              exceedsPicture: Bool = false) -> CropToolLayout {
        // 362 — the layout and the pointer read are the **same** projection: this entry only decides
        // the three inputs of it (space, angle, keystone) and hands the drawing to it.
        let projection = projection(source: source, mapping: mapping,
                                    angle: quadRotationDegrees,
                                    cropSpace: cropSpace,
                                    perspective: mapping.transform?.perspective,
                                    pointScale: pointScale,
                                    carry: carry)
        return layout(crop: crop, projection: projection, showsGrid: showsGrid,
                      exceedsPicture: exceedsPicture)
    }

    /// **362 — the one layout.** Corner for corner a function of `projection.view`, so what the overlay
    /// draws and what a pointer is read through cannot be two different maps.
    public static func layout(crop: CropRect,
                              projection: CropToolProjection,
                              showsGrid: Bool = true,
                              exceedsPicture: Bool = false) -> CropToolLayout {
        let c = crop.clamped(allowsOutsideSource: true)
        func view(_ u: Double, _ v: Double) -> CGPoint { projection.view(u, v) }

        let corners = [view(c.left, c.top), view(c.right, c.top),
                       view(c.right, c.bottom), view(c.left, c.bottom)]
        var layout = CropToolLayout(corners: corners, exceedsPicture: exceedsPicture)

        // Corners first: they are drawn on top and they win the hit test, so the order here is the
        // order of precedence, not an accident.
        layout.grips = [
            .init(kind: .topLeft, point: corners[0]),
            .init(kind: .topRight, point: corners[1]),
            .init(kind: .bottomRight, point: corners[2]),
            .init(kind: .bottomLeft, point: corners[3]),
            .init(kind: .top, point: view(c.centerX, c.top)),
            .init(kind: .right, point: view(c.right, c.centerY)),
            .init(kind: .bottom, point: view(c.centerX, c.bottom)),
            .init(kind: .left, point: view(c.left, c.centerY)),
        ]

        if showsGrid {
            let corners45: [Double] = [1.0 / 3.0, 2.0 / 3.0]
            var lines: [CropToolSegment] = []
            for t in corners45 {
                lines.append(.init(a: view(c.left, c.top + t * c.height),
                                   b: view(c.right, c.top + t * c.height)))
                lines.append(.init(a: view(c.left + t * c.width, c.top),
                                   b: view(c.left + t * c.width, c.bottom)))
            }
            layout.grid = lines
        }
        return layout
    }

    // MARK: 362 — the projection, built once

    /// The projection the frame is drawn with and the pointer is read through.
    ///
    /// The three branches are 330's, 327's and 088's, spelled **once**:
    ///
    ///   · `cropSpace == .canvas` — the frame is a rectangle of the document canvas. Its `(W, H)` is
    ///     `photoQuadExtent` of a geometry turned by **the framing's angle plus the quad's own** (355's
    ///     correction: the draft-vs-document delta alone is 0 at rest, and the canvas it claimed to be
    ///     a window on was then the 0° AABB — 6403×4016 for a 6578×4909 canvas at 9°/+60).
    ///   · a keystone on a `.source` rect — `P → R` then the camera (327).
    ///   · neither — `R(−θ)` about the photograph's centre plus the camera's frame map (088).
    public static func projection(source: ImageSize,
                                  mapping: LoupeMapping,
                                  angle: Double,
                                  cropSpace: CropSpace,
                                  perspective: PerspectiveMap?,
                                  pointScale: Double = 1,
                                  carry: CropCarry = .identity) -> CropToolProjection {
        let scale = pointScale > 0 ? pointScale : 1
        let clamped = clampStraighten(angle)
        if cropSpace == .canvas {
            // 355 — the canvas' angle is the **total** turn: the framing's own plus the quad's delta.
            let framing = mapping.transform?.straightenDegrees ?? 0
            let geometry = CropGeometry(
                geometry: GeometryGroup(crop: .full,
                                        rotationDegrees: clampStraighten(framing + clamped),
                                        aspectLock: .original,
                                        quarterTurns: 0,
                                        perspectiveVertical: perspective?.vertical ?? 0,
                                        perspectiveHorizontal: perspective?.horizontal ?? 0,
                                        cropSpace: .canvas),
                source: source)
            let e = geometry.photoQuadExtent
            return CropToolProjection(units: CropUnits(width: e.width, height: e.height),
                                      space: .canvas(geometry, mapping), scale: scale, carry: carry)
        }
        if let perspective, perspective.hasWarp {
            let geometry = CropGeometry(
                geometry: GeometryGroup(crop: .full,
                                        rotationDegrees: clamped,
                                        aspectLock: .original,
                                        quarterTurns: 0,
                                        perspectiveVertical: perspective.vertical,
                                        perspectiveHorizontal: perspective.horizontal),
                source: source)
            return CropToolProjection(units: CropUnits(source),
                                      space: .keystone(geometry, mapping), scale: scale, carry: carry)
        }
        return CropToolProjection(units: CropUnits(source),
                                  space: .frame(CropGeometry.RotationMatrix(degrees: clamped), mapping,
                                                width: Double(max(source.width, 1)),
                                                height: Double(max(source.height, 1))),
                                  scale: scale, carry: carry)
    }

    // MARK: the document-canvas clamp (224 → 2026-11-02)

    /// **The one containment arithmetic**: the frame is a rectangle of the **document**, and the
    /// document's canvas is the box that holds every pixel of the whole photograph once it is turned
    /// (`CropGeometry.documentCanvasCropRect`). At θ = 0 that box *is* `[0,1]²`, so an upright document
    /// keeps 224's arithmetic bit for bit; at an angle it is the AABB of the turned photograph, which
    /// is wider than the photograph — the frame may therefore enter the black corners a straighten
    /// opens (user 2026-11-02: 「旋转之后，裁剪框能移动的范围应该是画布，不是原始图片」).
    ///
    /// The bound is read from the rect, the source and the angle alone — never from the viewport, the
    /// zoom or the window — so the same candidate yields the same answer at every framing.
    ///
    /// Moving is preferred: a rect that fits is translated the least amount that brings it inside.
    /// Only a rect genuinely larger than the canvas is shrunk, uniformly about its centre, so an
    /// aspect lock survives. The picture's turned quad is a **warning** (`frameExceedsPicture`),
    /// never a bound: the frame may cover the black corners a straighten cuts off.
    ///
    /// `mapping` is kept for the call sites (a drag tick, a camera move, a 转动 tick); the law itself
    /// reads none of it, which is what makes the result screen-free.
    public static func clampToCanvas(_ rect: CropRect,
                                     mapping: LoupeMapping,
                                     source: ImageSize,
                                     degrees: Double = 0,
                                     perspective: PerspectiveMap? = nil,
                                     cropSpace: CropSpace = .source,
                                     tolerance: Double = 0,
                                     shrinkTicks: UnsafeMutablePointer<Int>? = nil) -> CropRect {
        // 330 — a **canvas-spaced** rect is already measured in the document canvas' own
        // coordinates, so 「不出画布」 is the rectangle `[0,1]²`: two slabs, no quad, no keystone
        // branch. The frame is a rectangle of the canvas by definition, which is the whole point.
        if cropSpace == .canvas {
            return clampInsideUnitSquare(rect, shrinkTicks: shrinkTicks)
        }
        // 324 — with a keystone the canvas is the AABB of the photo **quad**, and the frame is a
        // rectangle of the crop's axes, so 「不出 AABB」 is four corner half-planes, not two slabs.
        // One geometry, one quad (`CropGeometry.photoQuad()`); no second AABB is derived here.
        if let perspective, perspective.hasWarp {
            return clampToKeystoneCanvas(rect, source: source, degrees: degrees,
                                          perspective: perspective, shrinkTicks: shrinkTicks)
        }
        let c = rect.clamped(allowsOutsideSource: true)
        // 2026-11-02 — the **document canvas**, not `[0,1]²`. `documentCanvasCropRect` degenerates to
        // `[0,1]²` at every right angle, so nothing that used to be legal became illegal and every
        // un-straightened number is the one 224 produced.
        let legal = CropGeometry.documentCanvasCropRect(in: source, degrees: degrees)
        var result = c

        // Shrink only a rect that is genuinely larger than the canvas — about its centre, so a ratio
        // lock is preserved. A rect that already fits is never resized.
        if result.width > legal.width || result.height > legal.height {
            let shrink = min(1, legal.width / max(result.width, 1e-9),
                             legal.height / max(result.height, 1e-9))
            let width = result.width * shrink, height = result.height * shrink
            result = CropRect(left: result.centerX - width / 2,
                              top: result.centerY - height / 2,
                              right: result.centerX + width / 2,
                              bottom: result.centerY + height / 2)
            // 310 — the branch is **counted**, because the claim «拖动不改尺寸» is exactly «this line
            // never fires while the user moves a frame». A non-zero number means the rect was
            // genuinely larger than the canvas, which after 307 can only happen to a frame that no
            // drag produced.
            shrinkTicks?.pointee &+= 1
        }

        // Move the least amount that puts the rect inside the canvas. Horizontal and vertical slides
        // are independent, so a corner overhang is pulled on both axes in one step.
        var du = 0.0, dv = 0.0
        if result.left < legal.left { du = legal.left - result.left }
        else if result.right > legal.right { du = legal.right - result.right }
        if result.top < legal.top { dv = legal.top - result.top }
        else if result.bottom > legal.bottom { dv = legal.bottom - result.bottom }

        _ = mapping      // kept for the call sites; the law is screen-free by construction
        _ = tolerance
        // The exact statement of the law: four edges inside the canvas, zero slack, whatever rounding
        // the slide above produced. `allowsOutsideSource` keeps the frame's ability to sit in the
        // black corners — this last pass only keeps the span finite and positive.
        return CropRect(left: result.left + du, top: result.top + dv,
                        right: result.right + du, bottom: result.bottom + dv)
            .clamped(allowsOutsideSource: true)
    }


    /// **330 — the canvas-space stop.** `rect` (canvas-normalized) inside `[0,1]²`: shrink about the
    /// centre only if it is genuinely larger than the canvas, then slide the least amount. Identical
    /// law to the pre-keystone branch above, in the crop's own (canvas) coordinates — no quad, no
    /// mapping, and **only a translation** while a drag is running (`shrinkTicks` counts the escape
    /// hatch, which is what makes 「拖动不改尺寸」 measurable).
    static func clampInsideUnitSquare(_ rect: CropRect,
                                      shrinkTicks: UnsafeMutablePointer<Int>?) -> CropRect {
        let legal = CropRect.full
        var result = rect.clamped(allowsOutsideSource: true)
        if result.width > legal.width || result.height > legal.height {
            let shrink = min(1, legal.width / max(result.width, 1e-9),
                             legal.height / max(result.height, 1e-9))
            let width = result.width * shrink, height = result.height * shrink
            result = CropRect(left: result.centerX - width / 2, top: result.centerY - height / 2,
                              right: result.centerX + width / 2, bottom: result.centerY + height / 2)
            shrinkTicks?.pointee &+= 1
        }
        var du = 0.0, dv = 0.0
        if result.left < legal.left { du = legal.left - result.left }
        else if result.right > legal.right { du = legal.right - result.right }
        if result.top < legal.top { dv = legal.top - result.top }
        else if result.bottom > legal.bottom { dv = legal.bottom - result.bottom }
        return CropRect(left: result.left + du, top: result.top + dv,
                        right: result.right + du, bottom: result.bottom + dv)
            .clamped(allowsOutsideSource: true)
    }

    /// **324 — the keystoned stop.** 「框可以进 000000，不能出 AABB」 with the canvas being the AABB of
    /// the photo **quad**: the frame's four document corners (`documentQuad(of:)`) must stay inside
    /// that box, and the move is a **translation** — the size is whatever the drag made it (310).
    ///
    /// The only resize is the escape hatch the rectangle path has always had: a frame that no
    /// translation can hold (a rect larger than the canvas) is scaled about its centre until it
    /// fits, and the branch is counted (`shrinkTicks`) because 「拖动不改尺寸」 is exactly 「this line
    /// never fires while the user moves a frame」.
    private static func clampToKeystoneCanvas(_ rect: CropRect,
                                              source: ImageSize,
                                              degrees: Double,
                                              perspective: PerspectiveMap,
                                              shrinkTicks: UnsafeMutablePointer<Int>?) -> CropRect {
        let geometry = CropGeometry(
            geometry: GeometryGroup(crop: .full,
                                    rotationDegrees: CropTool.clampStraighten(degrees),
                                    aspectLock: .original,
                                    quarterTurns: 0,
                                    perspectiveVertical: perspective.vertical,
                                    perspectiveHorizontal: perspective.horizontal),
            source: source)
        var candidate = rect.clamped(allowsOutsideSource: true)
        if let placed = geometry.translatedInsidePhotoCanvas(candidate) {
            return placed
        }
        // Genuinely larger than the canvas: shrink uniformly about the centre, then place it.
        let extent = geometry.photoQuadExtent
        let quad = geometry.documentQuad(of: candidate)
        let xs = quad.map(\.x), ys = quad.map(\.y)
        let quadW = max((xs.max() ?? 0) - (xs.min() ?? 0), 1e-9)
        let quadH = max((ys.max() ?? 0) - (ys.min() ?? 0), 1e-9)
        let shrink = min(1, extent.width / quadW, extent.height / quadH)
        let width = candidate.width * shrink, height = candidate.height * shrink
        candidate = CropRect(left: candidate.centerX - width / 2,
                             top: candidate.centerY - height / 2,
                             right: candidate.centerX + width / 2,
                             bottom: candidate.centerY + height / 2)
        shrinkTicks?.pointee &+= 1
        return geometry.translatedInsidePhotoCanvas(candidate) ?? candidate
    }

    // MARK: hit test

    /// The grip a click landed on. Never `nil`: a click that misses every grip is still either
    /// **inside** the frame (the picture moves) or **outside** it (a new frame starts).
    ///
    /// Distances are measured in points against the same layout the overlay drew, so the target is
    /// the same size on screen at every zoom — the layout already carries the zoom inside the
    /// mapping's two points.
    public static func hit(_ viewPoint: CGPoint,
                           in layout: CropToolLayout,
                           cornerRadius: Double = cornerHitRadiusPoints,
                           edgeRadius: Double = edgeHitRadiusPoints) -> CropToolHandle {
        var best: (kind: CropToolHandle, distance: Double)?
        for grip in layout.grips {
            let distance = hypot(Double(viewPoint.x - grip.point.x),
                                 Double(viewPoint.y - grip.point.y))
            let radius = grip.kind.isCorner ? cornerRadius : edgeRadius
            guard distance <= radius else { continue }
            // A corner beats an edge at equal distance, and the nearer grip always wins.
            if let current = best {
                if current.kind.isCorner && !grip.kind.isCorner { continue }
                if current.kind.isCorner == grip.kind.isCorner, current.distance <= distance { continue }
            }
            best = (grip.kind, distance)
        }
        if let best { return best.kind }
        return contains(viewPoint, in: layout) ? .inside : .outside
    }

    /// Point-in-quad (the quad is convex unless the mapping is degenerate, which it never is:
    /// rotation and flips are affine).
    public static func contains(_ point: CGPoint, in layout: CropToolLayout) -> Bool {
        guard layout.corners.count == 4 else { return false }
        var sign = 0
        for i in 0..<4 {
            let a = layout.corners[i], b = layout.corners[(i + 1) % 4]
            let cross = Double(b.x - a.x) * Double(point.y - a.y)
                - Double(b.y - a.y) * Double(point.x - a.x)
            if abs(cross) < 1e-9 { continue }
            let s = cross > 0 ? 1 : -1
            if sign == 0 { sign = s } else if sign != s { return false }
        }
        return true
    }

    // MARK: minimum size

    /// The smallest normalized width/height a drag may leave, in the frame's own units.
    public static func minimumSpan(source: ImageSize) -> (width: Double, height: Double) {
        minimumSpan(units: CropUnits(source))
    }

    /// **362** — the same floor in the **rect's own** units: `32 px` of the grid the rect is measured
    /// in (the photograph, or the document canvas for a `.canvas` rect).
    public static func minimumSpan(units: CropUnits) -> (width: Double, height: Double) {
        let w = max(units.width, 1), h = max(units.height, 1)
        return (min(1, minimumSpanPixels / w), min(1, minimumSpanPixels / h))
    }

    // MARK: aspect ratio

    /// The ratio a lock constrains to, expressed in **normalized** units.
    ///
    /// A 3:2 crop of a 9520×6336 frame is 3:2 in pixels, not in normalized coordinates — the same
    /// conversion `CropMath.fittedCrop` makes, spelled once here so a drag and a preset switch
    /// cannot disagree.
    public static func normalizedAspect(_ ratio: Double, source: ImageSize) -> Double? {
        normalizedAspect(ratio, units: CropUnits(source))
    }

    /// **362** — the lock's ratio in the units the rect is **actually measured in**. For a `.canvas`
    /// rect that is the document canvas (`photoQuadExtent`), not the photograph: at 9°/+60 they differ
    /// by 6553/4909 = 1.335 against the photograph's 6000/4000 = 1.5, so reading the source here
    /// re-cut a locked frame ~11 % on every tick — the 「框的大小经常跳变」 of the report.
    public static func normalizedAspect(_ ratio: Double, units: CropUnits) -> Double? {
        guard ratio.isFinite, ratio > 0 else { return nil }
        let value = ratio * max(units.height, 1) / max(units.width, 1)
        return (value.isFinite && value > 0) ? value : nil
    }

    /// A drag's rect, reshaped to `lock` with `anchor` pinned.
    ///
    /// The free rect is what the hand drew; the lock then keeps the ratio by shrinking its longer
    /// dimension (never growing past what the hand asked for), and the rect is placed so the
    /// **opposite corner or edge stays exactly where it was**. That is why dragging the bottom-right
    /// corner with 1:1 on does not creep: the top-left corner is a fixed point of the whole gesture.
    ///
    /// `bounds` is the document canvas the caller allows (2026-11-02): `[0,1]²` for an upright
    /// document, the turned photograph's AABB otherwise. The default is the historical frame, so a
    /// caller that never passes one gets the pre-2026-11-02 numbers.
    public static func constrain(_ rect: CropRect,
                                 lock: AspectLock,
                                 source: ImageSize,
                                 anchor: CropToolAnchor,
                                 bounds: CropRect = .full) -> CropRect {
        constrain(rect, lock: lock, units: CropUnits(source), anchor: anchor, bounds: bounds)
    }

    /// **362** — `constrain` in the rect's **own** units (the photograph, or the document canvas for a
    /// `.canvas` rect). The ratio and the 32 px floor are pixel facts, so they have to be converted
    /// with the grid the rect is measured in.
    public static func constrain(_ rect: CropRect,
                                 lock: AspectLock,
                                 units: CropUnits,
                                 anchor: CropToolAnchor,
                                 bounds: CropRect? = .full) -> CropRect {
        let c = rect.clamped(allowsOutsideSource: true)
        guard let ratio = lock.ratio, let na = normalizedAspect(ratio, units: units) else {
            return c
        }
        var w = c.width, h = c.height
        guard w > 0, h > 0 else { return c }
        if w / h > na { w = h * na } else { h = w / na }

        var left = c.left, top = c.top
        switch anchor {
        case .topLeft:
            left = c.left; top = c.top
        case .topRight:
            left = c.right - w; top = c.top
        case .bottomLeft:
            left = c.left; top = c.bottom - h
        case .bottomRight:
            left = c.right - w; top = c.bottom - h
        case .left:
            left = c.left; top = c.centerY - h / 2
        case .right:
            left = c.right - w; top = c.centerY - h / 2
        case .top:
            left = c.centerX - w / 2; top = c.top
        case .bottom:
            left = c.centerX - w / 2; top = c.bottom - h
        case .center:
            left = c.centerX - w / 2; top = c.centerY - h / 2
        }
        let span = minimumSpan(units: units)
        // 368 — `nil` is the drag tick's **single-space** path: the hand's rect is only shaped by the
        // lock here, and the canvas is a separate, later clamp (`CropTool.clampToCanvas`). Doing the
        // canvas' position clamp inside the lock's reshape let the frame slide under the hand and the
        // next tick's press read that moved edge (the jump 368 removes).
        guard let bounds else {
            let width = max(w, span.width)
            let height = max(h, span.height)
            return CropRect(left: left, top: top, right: left + width, bottom: top + height)
        }
        // A rect that no longer fits the frame is *moved* into it, not resized: the ratio is the
        // rule the user chose, and a shift keeps it while a shrink would silently drop it.
        let width = min(max(w, span.width), max(bounds.width, span.width))
        let height = min(max(h, span.height), max(bounds.height, span.height))
        let x = min(max(left, bounds.left), bounds.right - width)
        let y = min(max(top, bounds.top), bounds.bottom - height)
        return CropRect(left: x, top: y, right: x + width, bottom: y + height)
    }

    /// The rect a ratio **preset** produces: same centre, and the same **area** where the frame
    /// allows it.
    ///
    /// `CropMath.fittedCrop` only ever shrinks (it fits a ratio inside a rect), which is right for
    /// "the lock wins over a rect that disagrees with it" at render time but wrong for a click on
    /// 1:1: the user asked for a different shape, not a smaller picture. So the area is preserved
    /// when the new shape fits inside the frame, and the call falls back to the fit when it does not.
    public static func matching(_ lock: AspectLock,
                                crop: CropRect,
                                source: ImageSize) -> CropRect {
        let c = crop.clamped()
        guard let ratio = lock.ratio, let na = normalizedAspect(ratio, source: source) else {
            return c
        }
        let area = c.width * c.height
        guard area > 0 else { return c }
        var width = (area * na).squareRoot()
        var height = width / na
        if width > 1 || height > 1 {
            // Fall back to the largest centred rect of that ratio the frame holds — the same answer
            // `CropMath.fittedCrop` gives, which is why it is called rather than re-derived.
            return CropMath.fittedCrop(aspect: ratio, in: CropRect.full, source: source)
        }
        var left = c.centerX - width / 2
        var top = c.centerY - height / 2
        left = min(max(left, 0), 1 - width)
        top = min(max(top, 0), 1 - height)
        // `width`/`height` are already inside the frame; the two lines above only move the rect.
        width = min(width, 1); height = min(height, 1)
        return CropRect(left: left, top: top, right: left + width, bottom: top + height)
    }

    // MARK: straighten

    /// The straighten angle after the hand drags `grab` → `point` around the frame's centre.
    ///
    /// Two conventions meet here and both have to be respected:
    ///
    ///  · the hand moves on **screen**, so the sweep is measured in pixels (`v · source.height`) — an
    ///    angle in normalized units is an angle only for a square picture;
    ///  · S0 rotates in **normalized crop space** (`r = R(θ)(uv − ½) + ½`, then `px = crop · srcSize`,
    ///    `CanvasPresenter.swift:17-28`), so a picture turned by the document's `θ` appears on screen
    ///    turned by `atan(tan θ · H / W)`. A 12° document angle is 8.1° of screen rotation on a 3:2
    ///    frame; that is the renderer's convention and this tool does not get to change it.
    ///
    /// So the hand's screen sweep Δ is converted to the document angle that *reproduces it*:
    /// `θ = atan(tan Δ · W / H)`. The picture then follows the hand exactly, and the number the bar
    /// shows is the number S0 will render. (`atan2(sin Δ · W, cos Δ · H)` rather than `tan`, so a
    /// quarter-turn sweep is 90°, not an infinity that has to be clamped by accident.)
    public static func straighten(_ start: Double,
                                  grab: NormalizedPoint,
                                  to point: NormalizedPoint,
                                  centre: NormalizedPoint,
                                  source: ImageSize) -> Double {
        let w = Double(max(1, source.width)), h = Double(max(1, source.height))
        let gx = (grab.x - centre.x) * w, gy = (grab.y - centre.y) * h
        let px = (point.x - centre.x) * w, py = (point.y - centre.y) * h
        guard (gx * gx + gy * gy).squareRoot() > 2, (px * px + py * py).squareRoot() > 2 else {
            return clampStraighten(start)
        }
        // y is down on screen, so `atan2(dy, dx)` already grows clockwise.
        var screen = (atan2(py, px) - atan2(gy, gx)) * 180 / .pi
        screen = screen.truncatingRemainder(dividingBy: 360)
        if screen > 180 { screen -= 360 }
        if screen < -180 { screen += 360 }
        // S0 rotates in **pixels** now (`s0_geometry.metal`: `o = (uv − ½)·frameSize`, R(θ), back), so
        // a document angle θ is a screen rotation of θ — on a 3:2 frame as much as on a square one.
        // The old `atan2(sin Δ·W, cos Δ·H)` existed only to undo the kernel's anisotropic rotation,
        // which is the shear this task removes.
        let documentAngle = screen
        // **Minus**, and the sign is worth spelling out: the document's angle is in normalized
        // (y-up) space, where a positive rotation reads clockwise, while the screen is y-down — the
        // same flip that makes the straighten look counter-clockwise on the canvas
        // (`testAStraightenedFrameTurnsWithThePicture`). To make the *picture* follow a clockwise
        // hand, the document has to be told the opposite angle. Lightroom's Angle slider has the
        // same sign: negative turns the picture clockwise.
        return clampStraighten(start - documentAngle)
    }

    /// ±45°, the document's own limit — the dial cannot ask S0 for an angle the document would clamp
    /// away, so the number on screen is always the number that renders.
    public static func clampStraighten(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        return min(max(degrees, -straightenLimit), straightenLimit)
    }

    /// Does this rect, straightened by `degrees`, still sample only inside the sensor? The bar uses
    /// it to say so; nothing is clamped behind the user's back.
    public static func fitsInsideSource(_ crop: CropRect, source: ImageSize,
                                        degrees: Double) -> Bool {
        CropMath.fitsInsideSource(crop, in: source, degrees: degrees)
    }

    // MARK: a custom ratio the user typed (072 §C2)

    /// `"4:3" → 4/3`, `"16:9" → 1.777…`, `"1.5" → 1.5`, `"4/3" → 4/3`. `nil` for anything that is not a
    /// positive, finite ratio.
    ///
    /// Pure, so the dialog's validation can be asserted without a window: the bar does not guess, it
    /// asks this, and a `nil` is a beep plus the old ratio kept (nothing is written). Zero, a negative
    /// side, an empty field, a non-number and a ratio with either side at or below zero are all
    /// rejections — 「非法输入拒绝且不改当前比例」.
    public static func ratio(from text: String,
                             limit: ClosedRange<Double> = 0.01...100) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(whereSeparator: { $0 == ":" || $0 == "/" })
        var ratio: Double?
        if parts.count == 2 {
            // A `W:H` pair — both sides must parse as numbers on their own, so "-3:2" and "4:0" fail.
            guard let w = strictNumber(String(parts[0])),
                  let h = strictNumber(String(parts[1])),
                  w > 0, h > 0 else { return nil }
            ratio = w / h
        } else if parts.count == 1 {
            ratio = strictNumber(String(parts[0]))
        }
        guard let ratio, ratio.isFinite, ratio > 0, limit.contains(ratio) else { return nil }
        return ratio
    }

    /// `Double(String)` says yes to `"1e5"`, `"inf"` and `"0x1p3"`; a ratio field should not.
    private static func strictNumber(_ text: String) -> Double? {
        let body = text.hasPrefix("-") || text.hasPrefix("+") ? String(text.dropFirst()) : text
        let digits = body.filter { $0 != "." }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              body.filter({ $0 == "." }).count <= 1 else { return nil }
        return Double(text)
    }
}

// MARK: - one drag, as a pure function

/// The state a crop drag needs: the grip, the rect as it was at mouse-down, and the point the hand
/// grabbed it at (normalized upright source coordinates).
///
/// Every update is computed from those three plus "where the hand is now" — never from the previous
/// tick's result — so a drag cannot drift, a clamped edge cannot ratchet, and replaying the same
/// points gives the same rect. Nothing is written to the document until 应用.
public struct CropToolDrag: Sendable, Equatable {
    public let handle: CropToolHandle
    /// The rect at mouse-down.
    public let crop: CropRect
    /// Where the hand grabbed, in normalized upright source coordinates.
    public let grab: NormalizedPoint

    public init(handle: CropToolHandle, crop: CropRect, grab: NormalizedPoint) {
        self.handle = handle
        self.crop = crop
        self.grab = grab
    }

    /// The rect this drag means at `point`.
    ///
    /// The four corners move two edges, the four edges move one, inside moves the picture (the kept
    /// region travels *against* the hand, which is what "平移画面" means when the frame is the output)
    /// and outside draws a new frame from the grab to the pointer. `lock` is applied last, anchored on
    /// the opposite side, and the minimum span is enforced before it.
    public func crop(at point: NormalizedPoint,
                     source: ImageSize,
                     lock: AspectLock = .original,
                     bounds: CropRect = .full) -> CropRect {
        crop(at: point, units: CropUnits(source), lock: lock, bounds: bounds)
    }

    /// **362** — the same drag in the rect's own units. `units` is what the lock's ratio and the 32 px
    /// floor are converted with; for a `.canvas` rect it is the document canvas, not the photograph.
    ///
    /// **368** — `bounds` defaults to `nil` here: the drag tick's rect is shaped by the hand and the
    /// lock only, and the document canvas is applied **once**, after the pixel press, by
    /// `CropTool.clampToCanvas`. A non-`nil` value keeps the historical early move-into-bounds.
    public func crop(at point: NormalizedPoint,
                     units: CropUnits,
                     lock: AspectLock = .original,
                     bounds: CropRect? = nil) -> CropRect {
        let span = CropTool.minimumSpan(units: units)
        // 2026-11-02: the rect under the hand may sit in the black corners a straighten opens, so the
        // mouse-down snapshot is *not* pulled back inside the photograph. `bounds` (the document
        // canvas) is what the caller clamps against afterwards.
        let base = crop.clamped(allowsOutsideSource: true)
        var left = base.left, top = base.top, right = base.right, bottom = base.bottom

        switch handle {
        case .inside:
            // The frame is dragged **with** the hand. It used to be `base.left - dx`, i.e. the frame
            // travelled against the pointer: a left drag moved the box right, which a user reads as
            // 「拖的是画布，而且方向反了」. Same sign, same magnitude, clamped at the frame's edge.
            let dx = point.x - grab.x, dy = point.y - grab.y
            let width = base.width, height = base.height
            // 132: no 0…1 bounds — the frame is the output and may be dragged off the picture.
            left = base.left + dx
            top = base.top + dy
            right = left + width
            bottom = top + height
            return CropRect(left: left, top: top, right: right, bottom: bottom)
                .clamped(allowsOutsideSource: true)

        case .outside:
            // A frame drawn from the grab to the pointer; both directions are legal, so the two
            // coordinates are ordered rather than trusted.
            left = min(grab.x, point.x)
            right = max(grab.x, point.x)
            top = min(grab.y, point.y)
            bottom = max(grab.y, point.y)
            if right - left < span.width { right = left + span.width }
            if bottom - top < span.height { bottom = top + span.height }
            return CropRect(left: left, top: top, right: right, bottom: bottom)
                .clamped(allowsOutsideSource: true)

        case .topLeft, .topRight, .bottomRight, .bottomLeft,
             .top, .right, .bottom, .left:
            let movesLeft = handle == .topLeft || handle == .bottomLeft || handle == .left
            let movesRight = handle == .topRight || handle == .bottomRight || handle == .right
            let movesTop = handle == .topLeft || handle == .topRight || handle == .top
            let movesBottom = handle == .bottomLeft || handle == .bottomRight || handle == .bottom

            if movesLeft { left = min(point.x, right - span.width) }
            if movesRight { right = max(point.x, left + span.width) }
            if movesTop { top = min(point.y, bottom - span.height) }
            if movesBottom { bottom = max(point.y, top + span.height) }
        }

        let free = CropRect(left: left, top: top, right: right, bottom: bottom)
            .clamped(allowsOutsideSource: true)
        guard lock.ratio != nil else { return free }
        return CropTool.constrain(free, lock: lock, units: units, anchor: handle.anchor,
                                  bounds: bounds)
    }
}
