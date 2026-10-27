import AppKit
import SwiftUI
import PhotonsCore

// MARK: - the six mask shapes, as something a menu can offer
//
// M4 shipped the whole shape union in Core (`MaskShape`: brush, linear, radial, colour range,
// luminance range, semantic matte) and exactly one of them in the UI. This file closes that gap:
//
//   · `MaskCreationKind` is the *menu* vocabulary — one case per shape, with the label the inspector
//     prints and the one property that changes how it is created (`isDragCreated`).
//   · the geometry helpers turn two normalised source points into a real `LinearGradientShape` /
//     `RadialGradientShape`, in the units `Mask`/`MaskShape` define: points are
//     normalised to the *uncropped source*, radii are divided by the short edge. That is why the
//     same drag produces the same ellipse at fit, at 1:1 and in an export.
//   · the session extension is the only writer. Creating a mask is **one** `commitEdit`, so ⌘Z takes
//     the new mask away in a single press — the same granularity as a preset or a brush stroke.
//
// What this deliberately does *not* do: invent coverage. A semantic mask is created with the
// provider the route table says can answer its kind, and if the OS cannot produce a matte the render
// reports `semanticUnavailable` and the mask covers nothing (005e §5.1). The UI shows the reason
// instead of drawing a guess.

public enum MaskCreationKind: String, Sendable, CaseIterable {
    case brush
    case linearGradient
    case radialGradient
    case colorRange
    case luminanceRange
    case semantic

    /// What the 新建 menu says.
    public var label: String {
        switch self {
        case .brush: return "画笔"
        case .linearGradient: return "线性渐变"
        case .radialGradient: return "径向渐变"
        case .colorRange: return "颜色范围"
        case .luminanceRange: return "亮度范围"
        case .semantic: return "语义"
        }
    }

    /// The symbol the menu and the list row use.
    public var symbol: String {
        switch self {
        case .brush: return "paintbrush.pointed"
        case .linearGradient: return "square.righthalf.filled"
        case .radialGradient: return "circle.dashed"
        case .colorRange: return "eyedropper.halffull"
        case .luminanceRange: return "circle.lefthalf.filled"
        case .semantic: return "person.and.background.dotted"
        }
    }

    /// The `MaskShape.kind` string this creates — what the document stores and what the list reads.
    public var shapeKind: String {
        switch self {
        case .brush: return MaskShape.brushKind
        case .linearGradient: return MaskShape.linearKind
        case .radialGradient: return MaskShape.radialKind
        case .colorRange: return MaskShape.colorRangeKind
        case .luminanceRange: return MaskShape.luminanceRangeKind
        case .semantic: return MaskShape.semanticKind
        }
    }

    /// True for the two shapes whose parameters **are** a gesture: they are created on mouse-up,
    /// with the geometry the user dragged, so the creation and the placement are one undo step.
    public var isDragCreated: Bool {
        self == .linearGradient || self == .radialGradient
    }

    /// True for shapes a drag can keep adjusting after creation (start/end, centre/radius).
    public var isAdjustable: Bool { isDragCreated }

    /// The kind a stored shape is, for reading a document back into this vocabulary.
    public static func of(_ shape: MaskShape) -> MaskCreationKind? {
        switch shape {
        case .brush: return .brush
        case .linearGradient: return .linearGradient
        case .radialGradient: return .radialGradient
        case .colorRange: return .colorRange
        case .luminanceRange: return .luminanceRange
        case .semantic: return .semantic
        case .unsupported: return nil
        }
    }
}

// MARK: - the rubber band
//
// What a gradient drag looks like before it is a mask: a dashed line between the two points (linear)
// or a dashed ellipse from centre to rim (radial). Drawn in **view points**, in the canvas's own
// flipped coordinate space, so it sits exactly under the hand at fit, at 1:1 and at 8:1 — and it is
// not a render: the document is not touched until mouse-up.

/// One instant of a gradient rubber band, in **view points** — what `MaskDraftOverlayView` draws.
///
/// A value of its own (rather than a tuple) because the loupe keeps one of these per animation frame
/// in its overlay log, and a claim about "what was drawn on frame t" has to be comparable
/// (`LoupeController.MaskOverlayFrame.draft`). The *source* of these numbers is not here:
/// `LoupeController` stores the drag in source pixels and re-projects it every frame — a rubber band
/// kept in view points could not follow a pan, which was the defect.
public struct MaskDraftShape: Equatable, Sendable {
    public var kind: MaskCreationKind
    /// The mouse-down point, in view points.
    public var start: CGPoint
    /// Where the hand is now, in view points.
    public var current: CGPoint

    public init(kind: MaskCreationKind, start: CGPoint, current: CGPoint) {
        self.kind = kind
        self.start = start
        self.current = current
    }
}

final class MaskDraftOverlayView: NSView {
    var draft: MaskDraftShape? {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    /// Never a hit target: the drag it is drawing belongs to the canvas underneath it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let draft, bounds.width > 1, bounds.height > 1 else { return }
        let colour = NSColor.controlAccentColor
        colour.withAlphaComponent(0.9).setStroke()

        let line = NSBezierPath()
        line.lineWidth = 1.5
        line.setLineDash([4, 3], count: 2, phase: 0)

        switch draft.kind {
        case .radialGradient:
            let rx = abs(draft.current.x - draft.start.x)
            let ry = abs(draft.current.y - draft.start.y)
            let rect = NSRect(x: draft.start.x - rx, y: draft.start.y - ry,
                              width: max(rx * 2, 2), height: max(ry * 2, 2))
            line.appendOval(in: rect)
            // The two axes, so a very thin drag still reads as an ellipse rather than a line.
            line.move(to: CGPoint(x: draft.start.x, y: draft.start.y))
            line.line(to: draft.current)
            colour.withAlphaComponent(0.10).setFill()
            NSBezierPath(ovalIn: rect).fill()
        default:
            line.move(to: draft.start)
            line.line(to: draft.current)
            // Perpendicular ticks: the two "lines" of a linear gradient, 26 pt long, so the
            // direction of the ramp is visible at a glance.
            let dx = draft.current.x - draft.start.x
            let dy = draft.current.y - draft.start.y
            let length = max((dx * dx + dy * dy).squareRoot(), 0.001)
            let nx = -dy / length * 13
            let ny = dx / length * 13
            for p in [draft.start, draft.current] {
                line.move(to: CGPoint(x: p.x - nx, y: p.y - ny))
                line.line(to: CGPoint(x: p.x + nx, y: p.y + ny))
            }
        }
        line.stroke()
        _ = dirtyRect
    }
}

// MARK: - the control points, drawn
//
// The other half of the rubber band: once a mask exists its geometry is on the canvas as grips the
// hand can take (task 032), instead of only as numbers in the inspector. The *positions* are not
// computed here — `MaskHandles.layout` does that, from the shape and the one projection
// (`LoupeFraming`/`LoupeMapping`), so what is drawn and what is grabbable cannot drift apart.
//
// The view itself is `hitTest → nil`, exactly like the draft overlay and like Brightroom's crop
// guide container (`CropView._InteractiveCropGuideView.swift:326-334`): a click that misses a grip
// belongs to the canvas underneath (a pan, or the gradient adjust drag), never to a transparent
// view that happens to be in front of it.

final class MaskHandlesOverlayView: NSView {

    /// Grips and guides in view points, from `MaskHandles.layout`.
    var layout: MaskHandlesLayout? {
        didSet { if oldValue != layout { needsDisplay = true } }
    }

    /// The grip under the hand, drawn filled with the accent colour.
    var active: MaskHandleKind? {
        didSet { if oldValue != active { needsDisplay = true } }
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }

    /// Never a hit target — the canvas owns every click, and the grips are hit-tested there.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let dotRadius: CGFloat = 5.5
    private static let centerRadius: CGFloat = 7

    override func draw(_ dirtyRect: NSRect) {
        guard let layout, bounds.width > 1, bounds.height > 1 else { return }
        _ = dirtyRect

        for guide in layout.guides {
            guard guide.points.count > 1 else { continue }
            let path = NSBezierPath()
            path.lineWidth = guide.style == .rim ? 1.5 : 1
            switch guide.style {
            case .isoLine:
                NSColor.white.withAlphaComponent(0.55).setStroke()
                path.setLineDash([5, 3], count: 2, phase: 0)
            case .axis:
                NSColor.white.withAlphaComponent(0.30).setStroke()
                path.setLineDash([2, 4], count: 2, phase: 0)
            case .rim:
                NSColor.white.withAlphaComponent(0.75).setStroke()
            case .featherRing:
                NSColor.white.withAlphaComponent(0.45).setStroke()
                path.setLineDash([3, 3], count: 2, phase: 0)
            case .brushBounds:
                NSColor.white.withAlphaComponent(0.50).setStroke()
                path.setLineDash([4, 4], count: 2, phase: 0)
            }
            path.move(to: guide.points[0])
            for p in guide.points.dropFirst() { path.line(to: p) }
            if guide.isClosed { path.close() }
            path.stroke()
        }

        // The grabbable extent of an iso-line, faintly: the whole line takes the drag, so it should
        // look like it does.
        for grip in layout.grips {
            guard let line = grip.line else { continue }
            let path = NSBezierPath()
            path.lineWidth = 3
            path.setLineDash([2, 2], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(0.20).setStroke()
            path.move(to: line.a)
            path.line(to: line.b)
            path.stroke()
        }

        for grip in layout.grips {
            let radius = grip.isCenter ? Self.centerRadius : Self.dotRadius
            let rect = NSRect(x: grip.point.x - radius, y: grip.point.y - radius,
                              width: radius * 2, height: radius * 2)
            let dot = NSBezierPath(ovalIn: rect)
            let isActive = grip.kind == active
            (isActive ? NSColor.controlAccentColor : NSColor.white).setFill()
            dot.fill()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: -0.75, dy: -0.75))
            ring.lineWidth = 1.5
            (isActive ? NSColor.white : NSColor.black.withAlphaComponent(0.55)).setStroke()
            ring.stroke()
        }
    }
}

private extension MaskHandlesLayout.Grip {
    var isCenter: Bool {
        if case .radialCenter = kind { return true }
        return false
    }
}

extension SemanticKind {
    /// What the inspector prints for this kind (the menu's submenu and the mask list row).
    public var displayName: String {
        switch self {
        case .sky: return "天空"
        case .subject: return "主体"
        case .person: return "人物"
        case .hair: return "头发"
        case .skin: return "皮肤"
        case .teeth: return "牙齿"
        case .glasses: return "眼镜"
        case .foreground: return "主体（旧）"
        }
    }
}

public enum MaskDragGeometry {
    /// A drag shorter than this fraction of the short edge is not a shape; it is a click. Creating a
    /// 1-pixel gradient from a stray click would be a mask the user cannot see and cannot undo
    /// knowingly, so the gesture is refused instead.
    public static let minimumDragFraction = 0.02

    /// Where a linear gradient's two lines go for a drag: `start` is the 0 % end, `end` the 100 %.
    public static func linear(from start: NormalizedPoint, to end: NormalizedPoint)
        -> LinearGradientShape {
        LinearGradientShape(start: start, end: end, midpoint: 0.5)
    }

    /// A radial gradient from centre → rim. `radius` is stored in **short-edge units** (§4.3), one
    /// number per axis, so a drag that is not square makes a genuine ellipse rather than a circle
    /// that ignores the hand.
    public static func radial(center: NormalizedPoint, to rim: NormalizedPoint,
                              source: ImageSize) -> RadialGradientShape {
        let shortEdge = Double(max(1, min(source.width, source.height)))
        let rx = abs(rim.x - center.x) * Double(max(1, source.width)) / shortEdge
        let ry = abs(rim.y - center.y) * Double(max(1, source.height)) / shortEdge
        // A zero axis is legal (a line, not an ellipse) but a *negative* one is not; both axes keep
        // a floor so the kernel's `max(abs(radius), 1e-4)` is not the only thing standing between a
        // stray click and a divide by zero.
        return RadialGradientShape(center: center,
                                   radius: NormalizedPoint(max(rx, 0.005), max(ry, 0.005)),
                                   angle: 0)
    }

    /// True when the drag is long enough to mean something, in short-edge units.
    public static func isMeaningful(from start: NormalizedPoint, to end: NormalizedPoint,
                                    source: ImageSize) -> Bool {
        let shortEdge = Double(max(1, min(source.width, source.height)))
        let dx = (end.x - start.x) * Double(max(1, source.width)) / shortEdge
        let dy = (end.y - start.y) * Double(max(1, source.height)) / shortEdge
        return (dx * dx + dy * dy).squareRoot() >= minimumDragFraction
    }
}

// MARK: - session: create a mask of a given shape

extension CatalogSession {

    /// The source size the normalised geometry is expressed against — **one** answer for the drag
    /// maths, the brush's spacing metric and the loupe's pre-decode framing.
    ///
    /// It is the *upright* frame (`MaskSourceFrame`): the catalog row's dimensions are the stored ones
    /// and are transposed for EXIF 5…8, which is what made a portrait drag render as a landscape-shaped
    /// ellipse (task 028).
    var maskSourceSize: ImageSize {
        let asset = anchorAsset
        let ingested = ingestedSourceFrame.flatMap { $0.assetID == asset?.id ? $0.size : nil }
        return MaskSourceFrame.size(ingested: ingested,
                                    storedWidth: asset?.width,
                                    storedHeight: asset?.height)
    }

    /// Arm the next drag (linear/radial) or create the mask outright (everything else).
    ///
    /// One entry point for the menu, so "what does choosing 径向渐变 do" has a single answer: the
    /// menu never has to know which kinds need a gesture.
    @discardableResult
    public func createMask(_ kind: MaskCreationKind, semanticKind: SemanticKind? = nil) -> Mask? {
        if kind.isDragCreated {
            pendingMaskShape = kind
            pendingSemanticKind = semanticKind ?? pendingSemanticKind
            maskTool = .off
            return nil
        }
        return addMask(kind: kind, semanticKind: semanticKind)
    }

    /// A new mask holding one component of `kind`, with a default geometry that covers something.
    ///
    /// The defaults are deliberately *visible*: a new gradient that covered nothing would look like
    /// a broken feature. They are also not the interesting case — the drag-created ones replace
    /// them entirely.
    @discardableResult
    public func addMask(kind: MaskCreationKind, semanticKind: SemanticKind? = nil) -> Mask? {
        guard edit.masks.count < Mask.maxCount else { return nil }
        let kindForSemantic = semanticKind ?? pendingSemanticKind
        let component = MaskComponent(id: "c-\(UUID().uuidString)", op: .add, invert: false,
                                      feather: defaultFeather(for: kind),
                                      shape: defaultShape(for: kind, semanticKind: kindForSemantic))
        let mask = Mask(name: "\(kind.label) \(edit.masks.count + 1)", components: [component])
        applyEdit { $0.masks.append(mask) }
        guard edit.masks.contains(where: { $0.id == mask.id }) else { return nil }
        commitEdit(label: "新建\(kind.label)蒙版")
        pendingMaskShape = nil
        setSelectedMaskID(mask.id)
        maskTool = kind == .brush ? .brush : .off
        return mask
    }

    /// The drag-created path: one mask, one snapshot, the geometry the hand drew.
    @discardableResult
    public func addShapeMask(_ kind: MaskCreationKind,
                             from start: NormalizedPoint, to end: NormalizedPoint) -> Mask? {
        guard edit.masks.count < Mask.maxCount, kind.isDragCreated else { return nil }
        let source = maskSourceSize
        guard MaskDragGeometry.isMeaningful(from: start, to: end, source: source) else { return nil }
        let shape: MaskShape
        switch kind {
        case .linearGradient:
            shape = .linearGradient(MaskDragGeometry.linear(from: start, to: end))
        case .radialGradient:
            shape = .radialGradient(MaskDragGeometry.radial(center: start, to: end, source: source))
        default:
            return nil
        }
        let component = MaskComponent(id: "c-\(UUID().uuidString)", op: .add, invert: false,
                                      feather: defaultFeather(for: kind), shape: shape)
        let mask = Mask(name: "\(kind.label) \(edit.masks.count + 1)", components: [component])
        applyEdit { $0.masks.append(mask) }
        guard edit.masks.contains(where: { $0.id == mask.id }) else { return nil }
        commitEdit(label: "新建\(kind.label)蒙版")
        pendingMaskShape = nil
        setSelectedMaskID(mask.id)
        maskTool = .off
        return mask
    }

    /// Rewrite one component's shape. `commit == false` is the live-drag case (one snapshot per
    /// gesture, not per mouse move): the pixels follow the hand, the history does not.
    public func setMaskComponentShape(_ maskID: String, component: Int,
                                      shape: MaskShape, commit: Bool, label: String) {
        guard let maskIndex = edit.masks.firstIndex(where: { $0.id == maskID }),
              edit.masks[maskIndex].components.indices.contains(component) else { return }
        applyEdit { $0.masks[maskIndex].components[component].shape = shape }
        if commit { commitEdit(label: label) }
    }

    /// The selected mask's adjustable component, when it has one — what a canvas drag adjusts.
    public func selectedAdjustableShape() -> (maskID: String, component: Int,
                                              kind: MaskCreationKind,
                                              shape: MaskShape)? {
        guard let id = selectedMaskID,
              let mask = edit.masks.first(where: { $0.id == id }) else { return nil }
        // The last adjustable component, i.e. the one the user most recently created.
        for index in stride(from: mask.components.count - 1, through: 0, by: -1) {
            let component = mask.components[index]
            guard let kind = MaskCreationKind.of(component.shape), kind.isAdjustable else { continue }
            return (mask.id, index, kind, component.shape)
        }
        return nil
    }

    // MARK: defaults

    func defaultFeather(for kind: MaskCreationKind) -> Double {
        switch kind {
        case .brush: return 0.5
        case .linearGradient, .radialGradient: return 0.5
        case .colorRange, .luminanceRange, .semantic: return 0.5
        }
    }

    func defaultShape(for kind: MaskCreationKind, semanticKind: SemanticKind) -> MaskShape {
        switch kind {
        case .brush:
            return .brush(BrushShape(size: brushSize, strokes: []))
        case .linearGradient:
            // Top → bottom, 15 % in from each edge: the "sky/foreground" divider every editor starts
            // with, and the drag replaces it the moment the user draws one.
            return .linearGradient(LinearGradientShape(start: NormalizedPoint(0.5, 0.15),
                                                       end: NormalizedPoint(0.5, 0.85),
                                                       midpoint: 0.5))
        case .radialGradient:
            return .radialGradient(RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                                       radius: NormalizedPoint(0.30, 0.30),
                                                       angle: 0))
        case .colorRange:
            // A mid-grey sample with the documented default tolerance: a starting point the user
            // replaces by picking a colour, and one that covers the mid-tones of most pictures
            // rather than nothing at all.
            return .colorRange(ColorRangeShape(samples: [[0.5, 0.5, 0.5]],
                                               tolerance: 0.30, smoothness: 0.50))
        case .luminanceRange:
            return .luminanceRange(LuminanceRangeShape(low: 0.0, high: 1.0,
                                                       lowFeather: 0.10, highFeather: 0.10))
        case .semantic:
            // The route table decides the provider, not the menu: `CIRAWFilter` answers sky/hair/
            // skin/teeth/glasses/person, Vision answers subject/person. Asking the wrong one would
            // be a mask that covers nothing for a reason the UI could have known in advance.
            let route: SemanticProvider = SemanticRoute.systemMatteSupports(semanticKind)
                ? .systemMatte : .visionForeground
            return .semantic(SemanticShape(kind: semanticKind, provider: route, softEdge: 0.20))
        }
    }
}
