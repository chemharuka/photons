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
                              exceedsPicture: Bool = false) -> CropToolLayout {
        let scale = pointScale > 0 ? pointScale : 1
        let c = crop.clamped(allowsOutsideSource: true)
        let centreX = Double(max(source.width, 1)) / 2
        let centreY = Double(max(source.height, 1)) / 2
        let rotation = CropGeometry.RotationMatrix(degrees: quadRotationDegrees.isFinite ? quadRotationDegrees : 0)
        func imagePoint(_ u: Double, _ v: Double) -> (x: Double, y: Double) {
            let dx = u * Double(source.width) - centreX
            let dy = v * Double(source.height) - centreY
            // R(−θ): the image is shown un-turned, so the rectangle (axis-aligned in the turned space)
            // reads as a quad turned the other way. The matrix lives in `CropGeometry` (123), so this
            // file no longer carries a second `cos`/`sin`.
            let turned = rotation.invert(x: dx, y: dy)
            return (centreX + turned.x, centreY + turned.y)
        }
        func view(_ u: Double, _ v: Double) -> CGPoint {
            // **Frame space, not source space** (see `LoupeMapping.frameView`): the crop rect is a
            // rectangle of the *straightened* frame, so its four sides stay axis-aligned on screen and
            // a straightened picture turns under a still frame. The quad is turned in image space
            // first (088), then projected by the document's framing — never re-fitted per angle.
            let q = imagePoint(u, v)
            let p = mapping.frameView(frameX: q.x, frameY: q.y)
            return CGPoint(x: carry.applyX(p.x) / scale, y: carry.applyY(p.y) / scale)
        }

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
        let w = Double(max(1, source.width)), h = Double(max(1, source.height))
        return (min(1, minimumSpanPixels / w), min(1, minimumSpanPixels / h))
    }

    // MARK: aspect ratio

    /// The ratio a lock constrains to, expressed in **normalized** units.
    ///
    /// A 3:2 crop of a 9520×6336 frame is 3:2 in pixels, not in normalized coordinates — the same
    /// conversion `CropMath.fittedCrop` makes, spelled once here so a drag and a preset switch
    /// cannot disagree.
    public static func normalizedAspect(_ ratio: Double, source: ImageSize) -> Double? {
        guard ratio.isFinite, ratio > 0 else { return nil }
        let value = ratio * Double(max(source.height, 1)) / Double(max(source.width, 1))
        return (value.isFinite && value > 0) ? value : nil
    }

    /// A drag's rect, reshaped to `lock` with `anchor` pinned.
    ///
    /// The free rect is what the hand drew; the lock then keeps the ratio by shrinking its longer
    /// dimension (never growing past what the hand asked for), and the rect is placed so the
    /// **opposite corner or edge stays exactly where it was**. That is why dragging the bottom-right
    /// corner with 1:1 on does not creep: the top-left corner is a fixed point of the whole gesture.
    public static func constrain(_ rect: CropRect,
                                 lock: AspectLock,
                                 source: ImageSize,
                                 anchor: CropToolAnchor) -> CropRect {
        let c = rect.clamped(allowsOutsideSource: true)
        guard let ratio = lock.ratio, let na = normalizedAspect(ratio, source: source) else {
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
        // A rect that no longer fits the frame is *moved* into it, not resized: the ratio is the
        // rule the user chose, and a shift keeps it while a shrink would silently drop it.
        let span = minimumSpan(source: source)
        let width = min(max(w, span.width), 1)
        let height = min(max(h, span.height), 1)
        let x = min(max(left, 0), 1 - width)
        let y = min(max(top, 0), 1 - height)
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
                     lock: AspectLock = .original) -> CropRect {
        let span = CropTool.minimumSpan(source: source)
        let base = crop.clamped()
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
        return CropTool.constrain(free, lock: lock, source: source, anchor: handle.anchor)
    }
}
