import CoreGraphics
import Foundation
import PhotonsCore

// MARK: - mask control points (task 032)
//
// A mask that exists should be **draggable on the canvas**, not only editable as numbers in the
// inspector. This file is that layer, and it is deliberately pure: no view, no window, no session.
// Everything here is a function of
//
//     (shape, upright source size, LoupeMapping, backing scale)  →  positions / shapes
//
// so the four questions the canvas asks each have exactly one answer, and each can be measured
// without a screen:
//
//   1. **What grips does this shape have?** `handles(for:source:)` — 位置 / 形状 / 角度 / 渐变比例,
//      and *nothing* for the shapes that have no geometry (colour, luminance, semantic) or whose
//      geometry is a stroke rather than a frame (brush: it gets a dashed boundary, not N dots —
//      turning one stroke into 400 draggable points is the thing this rule exists to avoid).
//   2. **Where are they on screen?** `layout(…)` — grips in **view points**, plus the guides that
//      explain them (the two iso-lines of a ramp and its axis, the ellipse and its feather ring,
//      the brush's bounds). The overlay draws this and nothing else; hit-testing reads it too, so
//      what is drawn and what is grabbable cannot drift apart.
//   3. **Which one did the click land on?** `hit(_:in:)` — a distance in **points**, so the target is
//      the same size at 25 % and at 400 % zoom. A distance measured in source pixels or in the
//      normalised frame would grow with the zoom, which is the classic way this goes wrong.
//   4. **What does the drag mean?** `MaskHandleDrag.shape(at:source:uniform:)` — a pure function of
//      the shape at mouse-down, the point where the hand grabbed it, and the point it is at now.
//      Absolute, not incremental: a drag cannot accumulate rounding drift, a clamped value cannot
//      ratchet, and the same gesture replayed twice gives the same document.
//
// The frame is `ImageSize` and every distance is divided by its **short edge** (`MaskFrame`), which
// is the unit `RadialGradientShape.radius` and `Stroke.radius` are already expressed in. Callers pass
// `CatalogSession.maskSourceSize` — the upright frame the renderer ingested (task 028) — never
// `asset.width/height`, which are the *stored* dimensions and are transposed for EXIF 5…8.
//
// Borrowed from the MIT references (see the report): Brightroom's crop handles inflate their hit
// target by a fixed **16 pt** around each control point and let the container itself fall through
// (`CropView._InteractiveCropGuideView.swift:39,56-63,323-334`), and its interaction layer decides
// who owns a gesture *before* the drag starts (`CropView.swift:2245-2274`). Both are adopted here:
// a constant point radius (`hitRadiusPoints`), and a hit test that runs before the pan.

// MARK: - what a grip writes

/// The four things the task asks a mask to expose, in the order the report lists them.
public enum MaskControlParameter: String, Sendable, CaseIterable, Equatable, Hashable {
    /// Where the mask sits (a ramp's band, an ellipse's centre).
    case position
    /// How big it is (an ellipse's radii).
    case shape
    /// Which way it points (a ramp's direction, an ellipse's `angle`).
    case angle
    /// How wide the transition is (a ramp's band width).
    case ratio

    public var label: String {
        switch self {
        case .position: return "位置"
        case .shape: return "形状"
        case .angle: return "角度"
        case .ratio: return "渐变比例"
        }
    }
}

/// A linear ramp has two iso-lines: the 100 % one (`start`) and the 0 % one (`end`).
public enum MaskGradientEnd: String, Sendable, Equatable, Hashable {
    case start
    case end
}

/// The four rim grips of an ellipse, in the frame's own axes (y down, so `top` is −y).
public enum MaskRimEdge: String, Sendable, Equatable, Hashable, CaseIterable {
    case left
    case right
    case top
    case bottom

    var isHorizontal: Bool { self == .left || self == .right }
}

public enum MaskHandleKind: Sendable, Equatable, Hashable {
    /// A whole iso-line of a linear ramp. Dragging it **across** the ramp translates the band;
    /// dragging it **along** the ramp resizes it (the 渐变比例 grip). One dot, two axes — see
    /// `MaskHandleDrag` for why that is not two ambiguous grips but a decomposition with no mode.
    case linearLine(MaskGradientEnd)
    /// The stem beyond the 0 % line that rotates the ramp about its centre.
    case linearAngle
    case radialCenter
    /// One rim grip: changes that axis' radius (⇧ keeps the ellipse's aspect).
    case radialEdge(MaskRimEdge)
    /// The stem on the ellipse's diagonal that writes `angle`.
    case radialAngle

    /// Which of the four parameters this grip moves — the assertion behind the task's table.
    public var parameters: [MaskControlParameter] {
        switch self {
        case .linearLine: return [.position, .ratio]
        case .linearAngle: return [.angle]
        case .radialCenter: return [.position]
        case .radialEdge: return [.shape]
        case .radialAngle: return [.angle]
        }
    }

    /// Stable text for the status/QA line (no UI reads it in a test).
    public var label: String {
        switch self {
        case .linearLine(.start): return "起点线"
        case .linearLine(.end): return "终点线"
        case .linearAngle: return "渐变角度"
        case .radialCenter: return "中心"
        case .radialEdge(.left): return "左边界"
        case .radialEdge(.right): return "右边界"
        case .radialEdge(.top): return "上边界"
        case .radialEdge(.bottom): return "下边界"
        case .radialAngle: return "椭圆角度"
        }
    }
}

/// One grip, in **normalised upright source coordinates** (0…1, y down) — the space every mask
/// parameter lives in. The view-space version is `MaskHandlesLayout.Grip`.
public struct MaskHandle: Sendable, Equatable {
    public var kind: MaskHandleKind
    public var point: NormalizedPoint

    public init(kind: MaskHandleKind, point: NormalizedPoint) {
        self.kind = kind
        self.point = point
    }

    public var parameters: [MaskControlParameter] { kind.parameters }
}

// MARK: - the frame (normalised ⇄ short-edge units)

/// The two coordinate systems a mask uses, and the one conversion between them.
///
/// A point is normalised to the frame (0…1 per axis); a distance is divided by the **short edge**, so
/// the same number means the same physical size in a portrait and a landscape frame. Both existing
/// geometry rules (`MaskDragGeometry`, `Stroke.radius`) use exactly this, and so does the drag maths
/// here — which is why a rim dragged 60 px on a portrait file is 60 px wide and not 90.
struct MaskFrame {
    let source: ImageSize

    var width: Double { Double(max(1, source.width)) }
    var height: Double { Double(max(1, source.height)) }
    var shortEdge: Double { min(width, height) }

    /// Normalised delta → short-edge units.
    func short(_ dx: Double, _ dy: Double) -> (x: Double, y: Double) {
        (dx * width / shortEdge, dy * height / shortEdge)
    }

    /// Short-edge units → normalised delta (the inverse).
    func normalized(_ dx: Double, _ dy: Double) -> (x: Double, y: Double) {
        (dx * shortEdge / width, dy * shortEdge / height)
    }
}

// MARK: - layout (what the canvas draws and hit-tests)

public enum MaskGuideStyle: String, Sendable, Equatable {
    /// An iso-line of a ramp (100 % / 0 %).
    case isoLine
    /// The ramp's axis: the dashed line a rotation is measured along.
    case axis
    /// The ellipse.
    case rim
    /// The inner ring `feather` covers (`1 − feather` of the radius) — the soft edge, drawn dashed.
    case featherRing
    /// The bounds of a painted stroke — dashed, and **not** draggable.
    case brushBounds
}

/// Everything the canvas needs about one mask's controls, in **view points** (y down, flipped).
public struct MaskHandlesLayout: Sendable, Equatable {
    public struct Segment: Sendable, Equatable {
        public var a: CGPoint
        public var b: CGPoint
        public init(a: CGPoint, b: CGPoint) { self.a = a; self.b = b }
    }

    /// A grip and the line it belongs to. `line` is the grabbable extent of an iso-line (a click
    /// anywhere on it starts the same drag); `nil` for the dot grips, which are a circle.
    public struct Grip: Sendable, Equatable {
        public var kind: MaskHandleKind
        /// The dot, in view points.
        public var point: CGPoint
        public var line: Segment?
    }

    public struct Guide: Sendable, Equatable {
        public var points: [CGPoint]
        public var isClosed: Bool
        public var style: MaskGuideStyle
    }

    public var grips: [Grip]
    public var guides: [Guide]

    public init(grips: [Grip] = [], guides: [Guide] = []) {
        self.grips = grips
        self.guides = guides
    }

    public var isEmpty: Bool { grips.isEmpty && guides.isEmpty }
}

public enum MaskHandles {

    // MARK: constants

    /// Hit radius, in **points** — constant on screen at every zoom, which is the acceptance
    /// criterion. Brightroom's crop handles use a 16 pt inflation around a 44 pt corner target
    /// (`CropView._InteractiveCropGuideView.swift:56-63`); a 6 pt dot with 11 pt around it is the
    /// same idea for a smaller grip, and it is small enough that two rims of a tight ellipse do not
    /// swallow each other's clicks.
    public static let hitRadiusPoints: Double = 11

    /// A ramp's band width, in short-edge units. The upper bound is "one short edge" — a ramp wider
    /// than the frame is a ramp whose two lines cannot both be seen, and the lower bound is the
    /// floor a zero-width ramp would otherwise divide by.
    public static let ratioRange: ClosedRange<Double> = 1e-3 ... 1

    /// An ellipse's radii, in short-edge units. The floor is `MaskDragGeometry.radial`'s 0.005;
    /// the ceiling is twice the frame's short edge (the inspector's slider stops at 1.2).
    public static let radiusRange: ClosedRange<Double> = 0.005 ... 4

    /// How far the angle stem sticks out, in short-edge units — far enough not to sit under a rim
    /// grip, near enough to stay on screen for a mask that fills the frame.
    static let angleArm: Double = 0.10

    /// How much of an iso-line is grabbable, either side of its dot (short-edge units).
    static let lineHalfLength: Double = 0.30

    // MARK: the task's table, as data

    /// The parameters a shape exposes on the canvas. Empty for every shape without geometry:
    /// brush (its geometry is a stroke, and the toolbar owns size/flow), colour range, luminance
    /// range and semantic mattes (panel-only, 005e §5.1).
    public static func controls(for shape: MaskShape) -> [MaskControlParameter] {
        var seen: Set<MaskControlParameter> = []
        for handle in handles(for: shape, source: ImageSize(width: 1, height: 1)) {
            seen.formUnion(handle.parameters)
        }
        return MaskControlParameter.allCases.filter { seen.contains($0) }
    }

    /// True when a drag can adjust this shape's geometry at all.
    public static func isDraggable(_ shape: MaskShape) -> Bool {
        switch shape {
        case .linearGradient, .radialGradient: return true
        default: return false
        }
    }

    // MARK: grips

    /// The grips of `shape`, in normalised upright source coordinates.
    public static func handles(for shape: MaskShape, source: ImageSize) -> [MaskHandle] {
        let frame = MaskFrame(source: source)
        switch shape {
        case .linearGradient(let g):
            let axis = frame.short(g.end.x - g.start.x, g.end.y - g.start.y)
            let length = (axis.x * axis.x + axis.y * axis.y).squareRoot()
            // A degenerate ramp (two coincident lines) has no direction to rotate: the documented
            // default is the vertical one, so the angle stem still lands somewhere meaningful.
            let u: (x: Double, y: Double) = length > 1e-9
                ? (x: axis.x / length, y: axis.y / length)
                : (x: 0, y: 1)
            let stem = frame.normalized(u.x * angleArm, u.y * angleArm)
            return [
                MaskHandle(kind: .linearLine(.start), point: g.start),
                MaskHandle(kind: .linearLine(.end), point: g.end),
                MaskHandle(kind: .linearAngle,
                           point: NormalizedPoint(g.end.x + stem.x, g.end.y + stem.y)),
            ]
        case .radialGradient(let e):
            let a = e.angle * .pi / 180
            let axR = (x: cos(a), y: sin(a))
            let axD = (x: -sin(a), y: cos(a))
            func local(_ u: Double, _ v: Double) -> NormalizedPoint {
                let x = u * axR.x + v * axD.x
                let y = u * axR.y + v * axD.y
                let n = frame.normalized(x, y)
                return NormalizedPoint(e.center.x + n.x, e.center.y + n.y)
            }
            let rx = e.radius.x, ry = e.radius.y
            // The stem sits on the ellipse's own diagonal, outside it: it rotates with the shape, so
            // it reads as "this is the angle" rather than as a fifth rim.
            let stemU = (rx + angleArm) * 0.7071, stemV = -(ry + angleArm) * 0.7071
            return [
                MaskHandle(kind: .radialCenter, point: e.center),
                MaskHandle(kind: .radialEdge(.right), point: local(rx, 0)),
                MaskHandle(kind: .radialEdge(.left), point: local(-rx, 0)),
                MaskHandle(kind: .radialEdge(.top), point: local(0, -ry)),
                MaskHandle(kind: .radialEdge(.bottom), point: local(0, ry)),
                MaskHandle(kind: .radialAngle, point: local(stemU, stemV)),
            ]
        default:
            return []
        }
    }

    /// A ramp's band width in short-edge units, clamped to `ratioRange` — the number behind
    /// 「渐变比例」. The acceptance test drags an end and reads this: it must move by the drag's own
    /// along-axis distance, linearly, and stop at the two ends of the range.
    public static func gradientRatio(_ shape: LinearGradientShape, source: ImageSize) -> Double {
        let frame = MaskFrame(source: source)
        let d = frame.short(shape.end.x - shape.start.x, shape.end.y - shape.start.y)
        let width = (d.x * d.x + d.y * d.y).squareRoot()
        return min(max(width, ratioRange.lowerBound), ratioRange.upperBound)
    }

    // MARK: layout

    /// Grips and guides in **view points**, ready to draw and to hit-test.
    ///
    /// `pointScale` is the backing scale (device pixels per point) and is only ever a divisor: the
    /// mapping produces device pixels because the renderer works in them, and everything a hand
    /// touches is in points.
    public static func layout(shape: MaskShape,
                             feather: Double,
                             source: ImageSize,
                             mapping: LoupeMapping,
                             pointScale: Double = 1) -> MaskHandlesLayout {
        let scale = pointScale > 0 ? pointScale : 1
        func view(_ p: NormalizedPoint) -> CGPoint {
            let v = mapping.viewPoint(sourceX: p.x * Double(source.width),
                                      sourceY: p.y * Double(source.height))
            return CGPoint(x: v.x / scale, y: v.y / scale)
        }

        var layout = MaskHandlesLayout()
        let frame = MaskFrame(source: source)

        switch shape {
        case .linearGradient(let g):
            let axis = frame.short(g.end.x - g.start.x, g.end.y - g.start.y)
            let length = (axis.x * axis.x + axis.y * axis.y).squareRoot()
            let u: (x: Double, y: Double) = length > 1e-9
                ? (x: axis.x / length, y: axis.y / length)
                : (x: 0, y: 1)
            let n = (x: -u.y, y: u.x)
            let half = frame.normalized(n.x * lineHalfLength, n.y * lineHalfLength)
            for handle in handles(for: shape, source: source) {
                let dot = view(handle.point)
                var line: MaskHandlesLayout.Segment?
                if case .linearLine = handle.kind {
                    line = MaskHandlesLayout.Segment(
                        a: view(NormalizedPoint(handle.point.x - half.x, handle.point.y - half.y)),
                        b: view(NormalizedPoint(handle.point.x + half.x, handle.point.y + half.y)))
                }
                layout.grips.append(.init(kind: handle.kind, point: dot, line: line))
            }
            layout.guides.append(.init(points: [view(g.start), view(g.end)], isClosed: false,
                                       style: .axis))
            for end in [MaskGradientEnd.start, .end] {
                let p = end == .start ? g.start : g.end
                layout.guides.append(.init(
                    points: [view(NormalizedPoint(p.x - half.x, p.y - half.y)),
                             view(NormalizedPoint(p.x + half.x, p.y + half.y))],
                    isClosed: false, style: .isoLine))
            }
        case .radialGradient(let e):
            for handle in handles(for: shape, source: source) {
                layout.grips.append(.init(kind: handle.kind, point: view(handle.point), line: nil))
            }
            let a = e.angle * .pi / 180
            func ring(_ rx: Double, _ ry: Double, style: MaskGuideStyle) {
                let steps = 64
                var points: [CGPoint] = []
                points.reserveCapacity(steps)
                for i in 0..<steps {
                    let t = Double(i) / Double(steps) * 2 * .pi
                    let u = rx * cos(t), v = ry * sin(t)
                    let x = u * cos(a) - v * sin(a)
                    let y = u * sin(a) + v * cos(a)
                    let n = frame.normalized(x, y)
                    points.append(view(NormalizedPoint(e.center.x + n.x, e.center.y + n.y)))
                }
                layout.guides.append(.init(points: points, isClosed: true, style: style))
            }
            ring(e.radius.x, e.radius.y, style: .rim)
            // `radial_alpha` ramps between r(1−f) and r, so the inner ring is exactly the soft edge.
            let keep = min(max(1 - feather, 0.05), 1)
            if keep < 0.999 {
                ring(e.radius.x * keep, e.radius.y * keep, style: .featherRing)
            }
        case .brush(let b):
            guard let box = Self.bounds(of: b, source: source) else { return layout }
            let corners = [NormalizedPoint(box.minX, box.minY), NormalizedPoint(box.maxX, box.minY),
                           NormalizedPoint(box.maxX, box.maxY), NormalizedPoint(box.minX, box.maxY)]
            layout.guides.append(.init(points: corners.map(view), isClosed: true, style: .brushBounds))
        default:
            break
        }
        return layout
    }

    /// The bounding box of a brush, normalised, covering every stroke point by its own radius.
    /// Dashed on the canvas; **no grips** — the strokes are the geometry and the toolbar owns the
    /// brush, so one stroke never turns into a cloud of dots.
    public static func bounds(of brush: BrushShape, source: ImageSize)
        -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        let frame = MaskFrame(source: source)
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        var any = false
        for stroke in brush.strokes {
            let pad = frame.normalized(stroke.radius, stroke.radius)
            var i = 0
            while i + 1 < stroke.points.count {
                let x = Double(stroke.points[i]), y = Double(stroke.points[i + 1])
                minX = min(minX, x - pad.x); maxX = max(maxX, x + pad.x)
                minY = min(minY, y - pad.y); maxY = max(maxY, y + pad.y)
                any = true
                i += 2
            }
        }
        guard any else { return nil }
        return (minX, minY, maxX, maxY)
    }

    // MARK: hit test

    /// The grip a click lands on, or `nil` — in which case the click belongs to whoever is next in
    /// the gesture stack (the shape-adjust drag, or the pan).
    ///
    /// Distance is measured in **points** and compared with `radiusPoints`, so the target is the
    /// same size on screen at 25 % and at 400 %: both the click and the grips are already in view
    /// points, and the zoom is inside the mapping that produced them.
    public static func hit(_ viewPoint: CGPoint,
                           in layout: MaskHandlesLayout,
                           radiusPoints: Double = hitRadiusPoints) -> MaskHandleKind? {
        var best: (kind: MaskHandleKind, distance: Double)?
        for grip in layout.grips {
            let distance = grip.line.map { distanceToSegment(viewPoint, $0) }
                ?? hypot(Double(viewPoint.x - grip.point.x), Double(viewPoint.y - grip.point.y))
            guard distance <= radiusPoints else { continue }
            if let current = best, current.distance <= distance { continue }
            best = (grip.kind, distance)
        }
        return best?.kind
    }

    /// The handle a kind names, re-resolved against the current shape (a drag needs the grip's
    /// source point, and the layout only keeps view points).
    public static func handle(_ kind: MaskHandleKind, in shape: MaskShape,
                              source: ImageSize) -> MaskHandle? {
        handles(for: shape, source: source).first { $0.kind == kind }
    }

    static func distanceToSegment(_ p: CGPoint, _ s: MaskHandlesLayout.Segment) -> Double {
        let px = Double(p.x), py = Double(p.y)
        let ax = Double(s.a.x), ay = Double(s.a.y)
        let bx = Double(s.b.x), by = Double(s.b.y)
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 1e-12 else { return hypot(px - ax, py - ay) }
        let t = min(max(((px - ax) * dx + (py - ay) * dy) / lengthSquared, 0), 1)
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }
}

// MARK: - one drag, as a pure function

/// The state a control-point drag needs: the grip, the shape as it was at mouse-down, and the point
/// the hand grabbed it at.
///
/// Every update is computed from those three plus "where the hand is now" — never from the previous
/// tick's result. Three properties follow, and all three are tested:
///
///   · a drag cannot drift, because nothing accumulates;
///   · a clamped value cannot ratchet (drag past the limit and back, and the shape returns exactly);
///   · one drag is one document change, so one commit is one ⌘Z.
public struct MaskHandleDrag: Sendable, Equatable {
    public let handle: MaskHandle
    public let shape: MaskShape
    /// Where the hand grabbed, in normalised upright source coordinates.
    public let grab: NormalizedPoint

    public init(handle: MaskHandle, shape: MaskShape, grab: NormalizedPoint) {
        self.handle = handle
        self.shape = shape
        self.grab = grab
    }

    /// The shape this drag means at `point`. `uniform` is ⇧ (an ellipse keeps its aspect).
    public func shape(at point: NormalizedPoint, source: ImageSize,
                      uniform: Bool = false) -> MaskShape? {
        let frame = MaskFrame(source: source)
        switch (shape, handle.kind) {
        case (.linearGradient(let g), .linearLine(let end)):
            return .linearGradient(Self.ramp(g, moving: end, grab: grab, to: point, frame: frame))

        case (.linearGradient(let g), .linearAngle):
            let centre = Self.centre(of: g)
            let degrees = Self.rotation(from: grab, to: point, about: centre, frame: frame)
            return .linearGradient(Self.rotated(g, by: degrees, frame: frame))

        case (.radialGradient(let e), .radialCenter):
            let dx = point.x - grab.x, dy = point.y - grab.y
            var next = e
            next.center = NormalizedPoint(e.center.x + dx, e.center.y + dy)
            return .radialGradient(next)

        case (.radialGradient(let e), .radialEdge(let edge)):
            return .radialGradient(Self.resized(e, edge: edge, grab: grab, to: point,
                                                frame: frame, uniform: uniform))

        case (.radialGradient(let e), .radialAngle):
            let degrees = Self.rotation(from: grab, to: point, about: (e.center.x, e.center.y),
                                        frame: frame)
            var next = e
            next.angle = Self.wrap(e.angle + degrees)
            return .radialGradient(next)

        default:
            return nil
        }
    }

    // MARK: linear

    /// A ramp dragged by one of its iso-lines.
    ///
    /// The motion is decomposed in the ramp's own axes, which is what makes one dot serve both
    /// halves of the spec without a mode switch:
    ///
    ///   · **across** the ramp (perpendicular) → both lines move together: 平移;
    ///   · **along** the ramp (`±u`) → the band gets wider or narrower, the opposite line pinned in
    ///     place, clamped to `ratioRange`: 渐变比例. Width grows when the 0 % line is pushed away
    ///     from the 100 % one, and shrinks when the 100 % line is pushed towards it.
    static func ramp(_ g: LinearGradientShape, moving end: MaskGradientEnd,
                     grab: NormalizedPoint, to point: NormalizedPoint,
                     frame: MaskFrame) -> LinearGradientShape {
        let d = frame.short(point.x - grab.x, point.y - grab.y)
        let axis = frame.short(g.end.x - g.start.x, g.end.y - g.start.y)
        let length = (axis.x * axis.x + axis.y * axis.y).squareRoot()
        let u: (x: Double, y: Double) = length > 1e-9
            ? (x: axis.x / length, y: axis.y / length)
            : (x: 0, y: 1)
        let n = (x: -u.y, y: u.x)
        let along = d.x * u.x + d.y * u.y
        let across = d.x * n.x + d.y * n.y

        let width0 = min(max(length, MaskHandles.ratioRange.lowerBound),
                         MaskHandles.ratioRange.upperBound)
        let signed = end == .end ? along : -along
        let width = min(max(width0 + signed, MaskHandles.ratioRange.lowerBound),
                        MaskHandles.ratioRange.upperBound)

        let shift = frame.normalized(n.x * across, n.y * across)
        let a = NormalizedPoint(g.start.x + shift.x, g.start.y + shift.y)
        let b = NormalizedPoint(g.end.x + shift.x, g.end.y + shift.y)
        let full = frame.normalized(u.x * width, u.y * width)
        // The **opposite** line is pinned, and the dragged one is placed at the new width from it:
        // dragging the 0 % line away from the 100 % one widens the band by exactly that distance, and
        // dragging it past the 100 % line stops at the floor instead of inverting the ramp.
        switch end {
        case .end:
            return LinearGradientShape(start: a,
                                       end: NormalizedPoint(a.x + full.x, a.y + full.y),
                                       midpoint: g.midpoint)
        case .start:
            return LinearGradientShape(start: NormalizedPoint(b.x - full.x, b.y - full.y),
                                       end: b, midpoint: g.midpoint)
        }
    }

    static func centre(of g: LinearGradientShape) -> (x: Double, y: Double) {
        ((g.start.x + g.end.x) / 2, (g.start.y + g.end.y) / 2)
    }

    /// Rotate a ramp about its own centre: the two lines stay where they are in the band, the
    /// direction turns. Measured in short-edge units, so a rotated ramp looks rotated on screen
    /// whatever the frame's aspect.
    static func rotated(_ g: LinearGradientShape, by degrees: Double,
                        frame: MaskFrame) -> LinearGradientShape {
        let c = centre(of: g)
        let radians = degrees * .pi / 180
        let s = sin(radians), co = cos(radians)
        func turn(_ p: NormalizedPoint) -> NormalizedPoint {
            let v = frame.short(p.x - c.x, p.y - c.y)
            let n = frame.normalized(v.x * co - v.y * s, v.x * s + v.y * co)
            return NormalizedPoint(c.x + n.x, c.y + n.y)
        }
        return LinearGradientShape(start: turn(g.start), end: turn(g.end), midpoint: g.midpoint)
    }

    // MARK: radial

    /// One rim grip: that axis' radius follows the drag projected onto the axis, ⇧ scales both.
    static func resized(_ e: RadialGradientShape, edge: MaskRimEdge,
                        grab: NormalizedPoint, to point: NormalizedPoint,
                        frame: MaskFrame, uniform: Bool) -> RadialGradientShape {
        let a = e.angle * .pi / 180
        let axR = (x: cos(a), y: sin(a))
        let axD = (x: -sin(a), y: cos(a))
        let d = frame.short(point.x - grab.x, point.y - grab.y)
        let du = d.x * axR.x + d.y * axR.y
        let dv = d.x * axD.x + d.y * axD.y

        let rx0 = max(e.radius.x, MaskHandles.radiusRange.lowerBound)
        let ry0 = max(e.radius.y, MaskHandles.radiusRange.lowerBound)
        var rx = rx0, ry = ry0
        switch edge {
        case .right: rx = du + rx0
        case .left: rx = rx0 - du
        case .bottom: ry = dv + ry0
        case .top: ry = ry0 - dv
        }
        rx = min(max(rx, MaskHandles.radiusRange.lowerBound), MaskHandles.radiusRange.upperBound)
        ry = min(max(ry, MaskHandles.radiusRange.lowerBound), MaskHandles.radiusRange.upperBound)

        if uniform {
            if edge.isHorizontal {
                ry = min(max(ry0 * (rx / rx0), MaskHandles.radiusRange.lowerBound),
                         MaskHandles.radiusRange.upperBound)
            } else {
                rx = min(max(rx0 * (ry / ry0), MaskHandles.radiusRange.lowerBound),
                         MaskHandles.radiusRange.upperBound)
            }
        }
        var next = e
        next.radius = NormalizedPoint(rx, ry)
        return next
    }

    // MARK: shared

    /// Screen rotation between two points about a centre, in degrees, signed (positive = clockwise
    /// on screen, which is the sign `RadialGradientShape.angle` documents).
    static func rotation(from a: NormalizedPoint, to b: NormalizedPoint,
                         about centre: (x: Double, y: Double), frame: MaskFrame) -> Double {
        let g = frame.short(a.x - centre.x, a.y - centre.y)
        let p = frame.short(b.x - centre.x, b.y - centre.y)
        guard (g.x * g.x + g.y * g.y).squareRoot() > 1e-6,
              (p.x * p.x + p.y * p.y).squareRoot() > 1e-6 else { return 0 }
        return wrap((atan2(p.y, p.x) - atan2(g.y, g.x)) * 180 / .pi)
    }

    /// Into (−180, 180] — so a rotation is the short way round and an angle never reads 400°.
    static func wrap(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}
