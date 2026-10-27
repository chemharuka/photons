import CoreGraphics
import Foundation
import PhotonsCore
import QuartzCore

// MARK: - state

/// Where the loupe is looking — in **source image pixels**, never in view coordinates.
///
/// The one rule this type exists to enforce: the viewport changes with window size *and* with the
/// backing scale, and the decode ladder changes the pixel size of the buffer the renderer samples
/// (0.5 → 1.0). A zoom/pan state kept in either would jump on a resize and on the second rung of the
/// ladder. Source pixels are the frame both of those leave alone, so they are the frame we store:
///
///   · `zoom` is **canvas (device) pixels per source pixel**: `1` is 1:1, `4` is 4:1.
///   · `centerX/centerY` is the source pixel that lands on the middle of the viewport.
///
/// `mode == .fit` keeps the old M3 behaviour (whole crop, letterboxed, never magnified) and the
/// stored centre is ignored; `zoom` is then only a memory of what to return to.
public struct LoupeViewState: Equatable, Sendable {

    public enum Mode: String, Sendable, Codable {
        /// Whole crop letterboxed into the viewport (M3's only mode).
        case fit
        /// 1:1 and beyond: a source-pixel window re-rendered into the viewport at `zoom`.
        case actual
    }

    /// The stop ceiling. Above 4:1 a 60 MP frame is being shown through sixteen canvas pixels per
    /// source pixel — there is no information left to reveal, only interpolation to admire.
    public static let maximumZoom: Double = 4
    /// The stop floor: a quarter of 1:1. Below it there is nothing left to see (the whole frame is
    /// `mode == .fit`, a separate entry, not a number), and 25 % is the widest *numeric* stop.
    public static let minimumZoom: Double = 0.25

    /// The eight numeric stops, ascending — the whole ladder, and the only values a stop change can
    /// name.
    ///
    /// `fit` (适应窗口) is deliberately **not** in here. It is a mode, not a rung, and where it belongs
    /// in the UI is a decision the user has not made yet (see `LoupeController.zoomFitEntryPoint`).
    /// Nothing on this ladder may assume anything about the fit ratio: on a 60 MP frame in a 2560-px
    /// viewport it is 0.31, so it happens to sit between 25 % and 33.3 %; on a 24 MP frame it is 0.72;
    /// on a file smaller than the viewport it is above 1. The ladder does not care, because the ladder
    /// no longer contains it.
    ///
    /// The thirds are **exact** (`1.0/3.0`, `2.0/3.0`), not 0.333/0.667: they are real zoom factors
    /// used by the anchor arithmetic, the bridge ratio and the menu's identity, and only their *label*
    /// is rounded to one decimal (`33.3%`, `66.7%`). Written as divisions so they cannot drift.
    public static let zoomStops: [Double] = [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1, 2, 3, 4]

    /// Index of `zoom` in `zoomStops` when it is exactly on a stop, `nil` between stops.
    ///
    /// `1e-9`, not `==`: a zoom that came back from a menu index, a pinch or a bridge ratio is the
    /// result of a `Double` chain, and the stop table's own values are the ones that must match.
    public static func stopIndex(of zoom: Double) -> Int? {
        zoomStops.firstIndex { abs($0 - zoom) < 1e-9 }
    }

    public var mode: Mode
    public var zoom: Double
    public var centerX: Double
    public var centerY: Double

    public init(mode: Mode = .fit, zoom: Double = 1, centerX: Double = 0, centerY: Double = 0) {
        self.mode = mode
        self.zoom = Self.clampZoom(zoom)
        self.centerX = centerX
        self.centerY = centerY
    }

    public static let fit = LoupeViewState()

    public var isActualSize: Bool { mode == .actual }

    /// 0.25…4, the interactive domain (fit is a separate mode, not a zoom value).
    ///
    /// The ends clamp rather than wrap, and a non-finite value goes to the end it names: `+∞` is
    /// "past 400 %" → 400 %, `−∞` → 25 %, `NaN` → the floor (a number that is not a number cannot ask
    /// for magnification).
    public static func clampZoom(_ zoom: Double) -> Double {
        if zoom.isNaN { return minimumZoom }
        return min(max(zoom, minimumZoom), maximumZoom)
    }

    /// `"适应"` for the whole-frame mode, otherwise the stop as a percentage: `"100%"` is 1:1.
    ///
    /// The fit ratio is not in here on purpose — a `LoupeViewState` does not know the window, so it
    /// cannot know what `LoupeFraming.fitZoom` is. `LoupeController.statusText` adds it where the
    /// reader can see it move (`"适应 31%"`).
    public var zoomLabel: String {
        switch mode {
        case .fit: return "适应"
        case .actual: return Self.percentLabel(of: Self.clampZoom(zoom))
        }
    }

    /// `0.25 → "25%"`, `1 → "100%"`, `1/3 → "33.3%"`, `2/3 → "66.7%"`, `3 → "300%"`.
    ///
    /// Whole percent for the stops that are whole percentages, **one decimal** for the thirds — and
    /// only in the *label*: `33.3%` is `1.0/3.0` internally, and rounding it to 33 % here would make
    /// the readout disagree with the stop it names.
    public static func percentLabel(of zoom: Double) -> String {
        let z = zoom.isFinite ? zoom : 1
        let percent = z * 100
        let whole = percent.rounded()
        if abs(percent - whole) < 1e-6 { return "\(Int(whole))%" }
        return String(format: "%.1f%%", percent)
    }
}

// MARK: - the ladder

/// One rung of the zoom ladder: a numeric stop and nothing else.
///
/// The ladder is the eight values of `LoupeViewState.zoomStops`, ascending, and it is a *constant* —
/// `fit` is not in it (and never was a value: it is a mode, entered through its own menu item /
/// shortcut, `LoupeController.zoomFitEntryPoint`), so nothing here depends on the window, the crop or
/// the fit ratio.
public struct LoupeZoomLevel: Equatable, Sendable, Comparable {

    /// Canvas pixels per source pixel: 0.25, 1/3, 0.5, 2/3, 1, 2, 3, 4.
    public let zoom: Double

    public init(zoom: Double) {
        self.zoom = zoom
    }

    /// `"50%"`, `"33.3%"` — what the 倍率 menu and the status readout print.
    public var label: String { LoupeViewState.percentLabel(of: zoom) }

    public static func < (a: LoupeZoomLevel, b: LoupeZoomLevel) -> Bool { a.zoom < b.zoom }

    /// Two rungs this close are the same rung. The table has no duplicates, so this is only a guard
    /// for values that came through arithmetic (a pinch, a bridge ratio).
    public static let tolerance = 0.005
}

extension LoupeViewState {

    /// The ladder: the eight numeric stops, ascending, de-duplicated. No arguments — nothing about it
    /// depends on the frame any more.
    public static let levels: [LoupeZoomLevel] = zoomStops.map { LoupeZoomLevel(zoom: $0) }

    /// The rung a raw zoom value lands on: **the largest rung not above it** — "自动往下走一级".
    ///
    /// A floor, not a nearest-value round: a pinch to 0.9 lands on 66.7 %, never on 100 %; a pinch to
    /// 0.34 lands on 33.3 %. Below the lowest rung (25 %) the answer is 25 %: the ladder's floor is a
    /// stop, and going further out is `fit`, which is an explicit action (`zoomToFit()`), not a snap.
    /// The comparison uses the table's exact values, so `1.0/3.0` is reachable and nothing hides
    /// between the rungs.
    public static func snappedLevel(for target: Double) -> LoupeZoomLevel {
        let t = target.isFinite ? target : 1
        return levels.last(where: { $0.zoom <= t + 1e-9 }) ?? levels[0]
    }
}

// MARK: - the scaling bridge (every stop change)

/// Where a stop change is pinned: the point of the canvas that does **not** move while the picture
/// grows or shrinks.
///
/// It is a parameter of the bridge, not something the two endpoint projections happen to agree on
/// (025). `fit ↔ actual` and every pointer command pin the pixel under the pointer; the glass zoom
/// slider pins the centre, on purpose (a slider has no pointer of its own).
///
/// Canvas device pixels, y down — the space `LoupeMapping` works in.
public enum LoupeZoomAnchor: Equatable, Sendable {
    /// The cursor's pixel, in canvas pixels.
    case pointer(x: Double, y: Double)
    /// The middle of the canvas: what the zoom slider means and what a command with no pointer over
    /// the canvas falls back to.
    case center

    public func point(in canvas: ImageSize) -> (x: Double, y: Double) {
        switch self {
        case .pointer(let x, let y): return (x, y)
        case .center: return (Double(canvas.width) / 2, Double(canvas.height) / 2)
        }
    }

    /// Device-pixel anchor from a view point (the space `NSEvent` and the tests speak).
    public static func pointer(viewPoint: CGPoint, backingScale k: Double) -> LoupeZoomAnchor {
        .pointer(x: Double(viewPoint.x) * k, y: Double(viewPoint.y) * k)
    }
}

/// The one geometric transition the loupe draws, and the only thing in `PhotonsUI` that animates.
///
/// It exists because of a **gap**, not because of a taste for motion: the camera jumps to the new
/// stop the moment the user asks for it, but the pixels for that stop are not on the canvas yet —
/// they are being rendered (5 ms from a resident rung, 52–900 ms if a development is in the way).
/// The canvas meanwhile holds a picture laid out for the *old* camera, so the change reads as a cut.
/// That was tolerable while the ladder was 40 rungs of ~10 % (1.0, 1.1, …, 4.0 — the ladder the
/// report says felt smooth); with five stops the same cut is a 2× jump.
///
/// So the picture already on screen is carried to where the new camera will put it: one
/// `CATransform3D` on the canvas layer, from the presentation's current value to the target's.
///
/// **The map is a similarity, not a scale about the anchor point.** Both cameras lay the picture out
/// against the crop (`origin = (canvas − content) / 2`, and the window inside it is the source
/// rectangle the camera shows), so the transform that turns one into the other is
///
///     aN(p) = scale · aO(p) + offset,   scale = zoomN / zoomO,  a = projection in canvas pixels
///
/// — a uniform scale `zoomN/zoomO` plus a translation. The translation is what keeps the **cursor's
/// source pixel under the cursor** while the picture grows around it, and it also absorbs the case
/// where the window had to be pulled back inside the crop (the anchor cannot be honoured there, and
/// the offset is then exactly that pull-back, no more). A pure scale about the canvas centre — what
/// the old `fit ↔ actual` bridge did — only happens to be right when both cameras are centred and
/// the cursor is in the middle, which is the one case a five-stop ladder almost never lands on.
public struct LoupeZoomBridge: Equatable, Sendable {

    /// The rect the picture occupies in canvas pixels under the camera that produced it.
    public let fromContent: ImageSize
    /// The rect the target camera's frame will occupy.
    public let toContent: ImageSize
    /// The projection the texture **on the canvas** was laid out with.
    public let fromMapping: LoupeMapping
    /// The projection the target camera will lay out.
    public let toMapping: LoupeMapping
    /// The canvas in device pixels (layer bounds × backing scale), y down.
    public let canvas: ImageSize
    /// Where the composite already is when the bridge arms: the presentation's own scale and offset.
    /// A retarget that started from identity would jump the picture back to where it was before the
    /// previous stop change — the "回跳" of a held ⌘=.
    public let startScale: Double
    public let startOffsetX: Double
    public let startOffsetY: Double
    /// How long this bridge takes, in seconds (already scaled to the span it covers).
    public let duration: CFTimeInterval
    /// The `CALayer.anchorPoint` of the layer this transform is applied to.
    ///
    /// **Not `(0.5, 0.5)`.** A view's backing layer in AppKit has `anchorPoint == (0, 0)` — `frame`
    /// and `position` are kept equal to the view's frame so that the two agree — and the canvas's layer
    /// is a backing layer, so a `CATransform3D` on it is applied about the **bottom-left corner**.
    /// Assuming the centre is a scale about the corner: the picture grows into the top-right and
    /// shrinks into the bottom-left, which is exactly the reported bug (「缩小是左下的位置 放大是右上
    /// 位置」). The bridge therefore takes the anchor from the layer instead of assuming one, and the
    /// canvas pins it in `LoupeCanvasView.layout()` so the two can never drift apart.
    public let layerAnchorPoint: CGPoint
    /// `CALayer.isGeometryFlipped` — `true` for the canvas, whose view is flipped, so the layer's
    /// points run y **down** from the top-left, the same way every number in this type does.
    public let layerIsFlipped: Bool
    /// Where the change is pinned. The bridge holds this point still on **every** frame of the
    /// transition, not just at the two ends (025).
    public let anchor: LoupeZoomAnchor

    // 067: the bridge no longer carries `photoRect`. It existed so every bridge frame could hand the
    // present pass the rect to paint `#0F0F0F` outside (054b) — and it was the *held frame's* rect,
    // not this frame's, so during a zoom the grey band stayed where the old camera had put the
    // photograph while the picture moved under it (the user's 「放大时边缘 0f 的遮罩会固定住，渲染完了
    // 突然消失」). The present pass takes its geometry from the window now, so a bridge frame's quad
    // follows `window(atProgress:)` by construction and there is no second number to carry.

    public init(fromContent: ImageSize, toContent: ImageSize,
                fromMapping: LoupeMapping, toMapping: LoupeMapping, canvas: ImageSize,
                startScale: Double = 1, startOffsetX: Double = 0, startOffsetY: Double = 0,
                layerAnchorPoint: CGPoint = .zero, layerIsFlipped: Bool = true,
                anchor: LoupeZoomAnchor = .center,
                duration: CFTimeInterval = LoupeZoomBridge.defaultDuration) {
        self.fromContent = fromContent
        self.toContent = toContent
        self.fromMapping = fromMapping
        self.toMapping = toMapping
        self.canvas = canvas
        self.startScale = startScale
        self.startOffsetX = startOffsetX
        self.startOffsetY = startOffsetY
        self.layerAnchorPoint = layerAnchorPoint
        self.layerIsFlipped = layerIsFlipped
        self.anchor = anchor
        self.duration = duration
    }

    // MARK: the map

    /// The uniform scale from the canvas texture to the target camera: `zoomN / zoomO`.
    ///
    /// Uniform because both projections are similarities (the straighten rotation, the flips and the
    /// half-pixel convention are the same in both), so the only thing that differs is how many canvas
    /// pixels a source pixel is worth. `100 → 200 %` is 1 → 2; `fit → 100 %` on a 60 MP frame in a
    /// 2560-px viewport is 0.31 → 1.
    public var scale: Double {
        let o = fromMapping.canvasPerSource
        let n = toMapping.canvasPerSource
        guard o > 1e-12, n.isFinite else { return 1 }
        return n / o
    }

    /// The translation, in device pixels, y down: `aN(p) = scale · aO(p) + offset`.
    ///
    /// Taken from the target window's centre — any source pixel names the same map, and this one is
    /// inside both windows, so it never divides by something degenerate.
    public var offset: (x: Double, y: Double) {
        let px = toMapping.cropLeft + toMapping.cropWidth / 2
        let py = toMapping.cropTop + toMapping.cropHeight / 2
        let o = fromMapping.viewPoint(sourceX: px, sourceY: py)
        let n = toMapping.viewPoint(sourceX: px, sourceY: py)
        let s = scale
        return (n.x - s * o.x, n.y - s * o.y)
    }

    /// A change that lays the picture out identically has nothing to bridge — a pan at a fixed zoom,
    /// or `fit` and `100 %` on a file small enough that they coincide (the frame is already right).
    /// A rect thinner than this is a broken frame, not a picture to scale by 2560×.
    private static let minimumContentSide = 8

    public var isVisible: Bool {
        let s = scale
        guard s.isFinite, s > 0,
              fromContent.width >= Self.minimumContentSide,
              fromContent.height >= Self.minimumContentSide,
              toContent.width >= Self.minimumContentSide,
              toContent.height >= Self.minimumContentSide,
              canvas.width >= Self.minimumContentSide,
              canvas.height >= Self.minimumContentSide else { return false }
        let o = offset
        return abs(s - 1) > 0.002 || abs(o.x) > 0.5 || abs(o.y) > 0.5
    }

    // MARK: the map, frame by frame (025)

    /// The fixed point of `v ↦ scale·v + offset` at the **end** of the bridge: the canvas pixel that
    /// does not move. `nil` when the end map is a pure translation (`scale == 1`), which has none.
    public var targetFixedPoint: (x: Double, y: Double)? {
        let s = scale
        guard abs(1 - s) > 1e-9 else { return nil }
        let o = offset
        return (o.x / (1 - s), o.y / (1 - s))
    }

    /// The fixed point the transition **starts** from. `nil` for a bridge armed from rest (the
    /// picture on the canvas is at 1×, so the map is the identity and every point is fixed).
    public var startFixedPoint: (x: Double, y: Double)? {
        guard abs(1 - startScale) > 1e-9 else { return nil }
        return (startOffsetX / (1 - startScale), startOffsetY / (1 - startScale))
    }

    /// The point every frame holds: the end map's fixed point, or — when the change has no scale at
    /// its end, i.e. nothing to see — the anchor that was named.
    public var anchorPoint: (x: Double, y: Double) {
        targetFixedPoint ?? anchor.point(in: canvas)
    }

    /// Canvas pixels per canvas pixel at `progress` — 0 is the picture already on the canvas, 1 the
    /// new camera. Linear in the scale, which is what `CAMediaTimingFunction(.easeOut)` distorts
    /// (the curve picks *which* progress, it never changes what a progress means).
    public func scale(atProgress t: Double) -> Double {
        let p = t.isFinite ? min(max(t, 0), 1) : 0
        return startScale + p * (scale - startScale)
    }

    /// The translation at `progress`, chosen so the anchor is **still on every frame**:
    ///
    ///     offset(t) = (1 − scale(t)) · F(t),   F(t) = lerp(F_start, F_end)
    ///
    /// This is the whole of 025's first bug. Interpolating the two endpoint *offsets* (which is what
    /// a `CABasicAnimation` between two `CATransform3D`s does) only keeps the anchor still when both
    /// ends happen to share it; expressing the frame as "this scale about this point" makes it true by
    /// construction, for a fresh bridge and for a retarget of a running one alike.
    public func offset(atProgress t: Double) -> (x: Double, y: Double) {
        let p = t.isFinite ? min(max(t, 0), 1) : 0
        let s = scale(atProgress: p)
        let end = anchorPoint
        let start = startFixedPoint ?? end
        let fx = start.x + p * (end.x - start.x)
        let fy = start.y + p * (end.y - start.y)
        return ((1 - s) * fx, (1 - s) * fy)
    }

    /// `(scale, offset)` at `progress` — the same pair the layer transform used to carry, read back
    /// for a retarget so the next bridge continues from where the eye is.
    public func map(atProgress t: Double) -> (scale: Double, x: Double, y: Double) {
        let o = offset(atProgress: t)
        return (scale(atProgress: t), o.x, o.y)
    }

    /// Where a canvas point lands at `progress`: `p ↦ scale(t)·p + offset(t)`. The composite the eye
    /// sees, for a test to project the anchored pixel through at every frame.
    public func canvasPoint(atProgress t: Double,
                            of p: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let s = scale(atProgress: t), o = offset(atProgress: t)
        return (s * p.x + o.x, s * p.y + o.y)
    }

    /// The sampling window that draws frame `t` of the transition into the canvas-sized drawable.
    ///
    /// A window instead of a layer transform is what 025 asks for: the drawable stays the canvas size
    /// (nothing can be drawn over the browser pane), and a shrinking window is *larger* than the
    /// texture, so the picture's own edge pixels fill the canvas (`clamp_to_edge`) instead of an
    /// unrendered black band.
    public func window(atProgress t: Double, textureSize: ImageSize) -> PresentWindow {
        let o = offset(atProgress: t)
        return PresentWindow(scale: scale(atProgress: t), originX: o.x, originY: o.y,
                             canvas: canvas, texture: textureSize)
    }

    // MARK: the layer transform

    /// `CATransform3D` for `aN(p) = s · aO(p) + o`, expressed in the layer's own coordinates.
    ///
    /// Three facts have to be right at once, and any of them wrong slides the picture by part of a
    /// viewport — which is why they are written as one derivation instead of three sign fixes:
    ///
    ///   1. `CALayer.transform` is applied about the **anchor point**, and it is a *point* of the
    ///      layer's bounds, not the centre: `anchor = anchorPoint · (W, H)` in points. On a view's
    ///      backing layer `anchorPoint` is `(0, 0)`, so "about the anchor" means "about the bottom-left
    ///      corner" — the bug this type shipped with, because it conjugated by `(W/2, H/2)`.
    ///   2. Layer points are points, not device pixels: `÷ backingScale`.
    ///   3. The layer's y axis is flipped when `isGeometryFlipped` is set (a flipped `NSView`), and then
    ///      layer points already run y **down** from the top-left, exactly like `canvas`:
    ///
    ///            v_layer = (v.x / k,            v.y / k)        flipped
    ///            v_layer = (v.x / k,  H − v.y / k)              not flipped
    ///
    /// A similarity `v ↦ s·v + o` in device pixels is the same similarity in layer points, with a
    /// translation that is just `o/k` when the axes agree and `((1 − s)·H − o.y/k)` on the y axis when
    /// they do not. The conjugation by the anchor turns that translation into
    ///
    ///     m41 = t.x − (1 − s)·anchor.x        m42 = t.y − (1 − s)·anchor.y
    ///
    /// (because `anchor + s·(v − anchor) + t = s·v + t − (1 − s)·anchor`). With the canvas's real
    /// geometry — anchor `(0, 0)`, flipped — this collapses to `m41 = o.x/k`, `m42 = o.y/k`: the layer
    /// *is* the device-pixel grid, which is the whole reason `layerPoint` below is a division.
    public func transform(scale s: Double, offset o: (x: Double, y: Double),
                          backingScale: Double) -> CATransform3D {
        let k = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let w = Double(canvas.width) / k
        let h = Double(canvas.height) / k
        let anchor = CGPoint(x: layerAnchorPoint.x * w, y: layerAnchorPoint.y * h)
        // The device-pixel translation, said in layer points.
        let tx = o.x / k
        let ty = layerIsFlipped ? o.y / k : (1 - s) * h - o.y / k
        var m = CATransform3DIdentity
        m.m11 = CGFloat(s)
        m.m22 = CGFloat(s)
        m.m41 = CGFloat(tx - (1 - s) * Double(anchor.x))
        m.m42 = CGFloat(ty - (1 - s) * Double(anchor.y))
        return m
    }

    /// The transform the animation ends on.
    public func targetTransform(backingScale: Double) -> CATransform3D {
        transform(scale: scale, offset: offset, backingScale: backingScale)
    }

    /// The transform the animation starts on: identity for a fresh bridge, the presentation's own
    /// value for one that replaced a running bridge.
    public func startTransform(backingScale: Double) -> CATransform3D {
        transform(scale: startScale, offset: (startOffsetX, startOffsetY), backingScale: backingScale)
    }

    /// Canvas pixel (device pixels, y down) → layer point (points, in the layer's own y direction).
    /// The test-side half of the conversion above, so the map can be asserted in the space it was
    /// derived in.
    public func layerPoint(canvasX: Double, canvasY: Double, backingScale: Double) -> CGPoint {
        let k = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let y = canvasY / k
        return CGPoint(x: canvasX / k,
                       y: layerIsFlipped ? y : Double(canvas.height) / k - y)
    }

    /// The layer's anchor in its own points — `anchorPoint · (W, H)`, which is where `CALayer`
    /// applies the transform about.
    public func layerAnchor(backingScale: Double) -> CGPoint {
        let k = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        return CGPoint(x: layerAnchorPoint.x * Double(canvas.width) / k,
                       y: layerAnchorPoint.y * Double(canvas.height) / k)
    }

    /// Apply a layer transform the way `CALayer` does: about the anchor point, not the origin.
    ///
    /// `v' = anchor + M · (v − anchor)`. A plain matrix application would be off by `(1 − scale) ·
    /// anchor` — half a viewport of drift at 2×, which is exactly the kind of bug this helper exists
    /// to make impossible to write into a test.
    public static func apply(_ m: CATransform3D, to v: CGPoint, anchor: CGPoint) -> CGPoint {
        let x = v.x - anchor.x, y = v.y - anchor.y
        return CGPoint(x: anchor.x + m.m11 * x + m.m21 * y + m.m41,
                       y: anchor.y + m.m12 * x + m.m22 * y + m.m42)
    }

    /// Read `(scale, offset)` back out of a layer transform — the inverse of `transform(scale:offset:)`,
    /// used to continue a running animation from the value the eye is looking at.
    ///
    /// `anchorPoint` / `isFlipped` are the layer's **real** geometry (the same pair
    /// `transform(scale:offset:)` was given); the defaults are the canvas's own. An inverse that
    /// assumed a different anchor than the forward map is a jump of `(1 − s) · anchor` on the second
    /// ⌘= of a held key, which is why the pair is a parameter and not a constant.
    public static func offset(ofLayerTransform m: CATransform3D, canvas: ImageSize,
                              backingScale: Double,
                              anchorPoint: CGPoint = .zero,
                              isFlipped: Bool = true) -> (scale: Double, x: Double, y: Double) {
        let k = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let w = Double(canvas.width) / k
        let h = Double(canvas.height) / k
        let s = Double(m.m11)
        guard s.isFinite, s > 0 else { return (1, 0, 0) }
        // Undo the anchor conjugation first, then the y direction.
        let tx = Double(m.m41) + (1 - s) * Double(anchorPoint.x) * w
        let ty = Double(m.m42) + (1 - s) * Double(anchorPoint.y) * h
        return (s,
                k * tx,
                isFlipped ? k * ty : k * ((1 - s) * h - ty))
    }

    // MARK: how long

    /// 180 ms, easeOut, for **every** stop change — one duration, not a function of the span.
    ///
    /// The user's rule: every zoom moves, and it moves by the same beat. A variable duration (60 ms
    /// per octave, say) makes a 25 % → 33.3 % step feel like a different mechanism than a 100 % → 400 %
    /// one, and the 2× step the app was tuned on is the one that has to keep its feel. 180 ms is also
    /// what the original `fit ↔ 100 %` bridge used; it is long enough to read as motion at 60 Hz and
    /// short enough that the wait for a sharp frame is not what the eye lands on.
    ///
    /// The animation is **never waited on**: a real frame that arrives mid-flight retargets the
    /// composite (or the bridge is cut short at its own target — `LoupeController.finishZoomBridge`),
    /// and the camera is already on the new stop before the first animation frame is drawn.
    public static let defaultDuration: CFTimeInterval = 0.180
}

// MARK: - the timeline

/// The bridge's timing curve, as a function — the transition is drawn by the loupe now, frame by
/// frame, so `CAMediaTimingFunction(name: .easeOut)` no longer runs it and the same curve has to be
/// written down where both the presenter and a test can reach it.
///
/// It is `CAMediaTimingFunction`'s own easeOut: a cubic Bézier with control points `(0, 0)` and
/// `(0.58, 1)`. `x(t)` is solved for the progress and `y(t)` is the answer — the curve decelerates
/// into the stop, which is what makes a stop change read as *arriving* rather than being cut off.
public enum LoupeZoomCurve {

    private static let x1 = 0.0, y1 = 0.0
    private static let x2 = 0.58, y2 = 1.0

    /// Progress `0…1` → eased progress `0…1`. Monotone, `0 → 0`, `1 → 1`, and never outside the unit
    /// interval (a curve that overshot would make the picture pass the stop and come back).
    public static func easeOut(_ progress: Double) -> Double {
        let p = progress.isFinite ? min(max(progress, 0), 1) : 0
        if p <= 0 { return 0 }
        if p >= 1 { return 1 }
        // 20 halvings on [0, 1] is 1e-6 of a frame at any duration: the curve does not need Newton.
        var low = 0.0, high = 1.0
        for _ in 0..<20 {
            let mid = (low + high) / 2
            if bezier(mid, x1, x2) < p { low = mid } else { high = mid }
        }
        return bezier((low + high) / 2, y1, y2)
    }

    /// One coordinate of a cubic Bézier whose end points are 0 and 1.
    private static func bezier(_ t: Double, _ c1: Double, _ c2: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t
    }
}

// MARK: - framing (viewport + crop → all the numbers)

/// The projection between the viewport, the crop frame and the source: one struct, one source of
/// truth for hit-testing, for the crop handed to `RenderGraph`, and for the tests.
///
/// The formulas mirror `s0_geometry.metal` exactly — the kernel is the definition, this type is its
/// inverse. For an output pixel at `gid`, S0 computes
///
///     local = gid + 0.5 − origin
///     uv    = local / content                       (then flipped in place)
///     r     = R(θ)·(uv − 0.5) + 0.5
///     px    = (crop.xy + r·crop.zw) · srcSize
///
/// so `sourcePixel ↔ viewPixel` here has to use the same 0.5-pixel centres, or 1:1 would be visibly
/// half a pixel off from the fit frame it replaced.
public struct LoupeFraming: Equatable, Sendable {

    /// Viewport in device pixels (points × backing scale) — the canvas size the renderer is asked for.
    public var viewport: ImageSize
    /// Full-resolution source pixels. Decoded size ÷ decode scale, so it does not move when the
    /// ladder swaps a 0.5 buffer for a 1.0 one.
    public var sourceWidth: Double
    public var sourceHeight: Double
    /// The document's crop, already resolved through its aspect lock (normalized source coords).
    public var crop: CropRect
    public var straightenDegrees: Double
    public var flipH: Bool
    public var flipV: Bool

    public init(viewport: ImageSize, sourceWidth: Double, sourceHeight: Double,
                crop: CropRect = .full, straightenDegrees: Double = 0,
                flipH: Bool = false, flipV: Bool = false) {
        self.viewport = viewport
        self.sourceWidth = max(sourceWidth, 1)
        self.sourceHeight = max(sourceHeight, 1)
        self.crop = crop.clamped()
        self.straightenDegrees = min(max(straightenDegrees, -GeometryGroup.straightenLimit),
                                     GeometryGroup.straightenLimit)
        self.flipH = flipH
        self.flipV = flipV
    }

    /// The constructor the loupe uses: the same `lockedCrop` call — in the same *decoded* pixel
    /// space — that `RenderGraph` would make, so `fit` stays pixel-identical to M3.
    public init(viewport: ImageSize, decoded: ImageSize, decodeScale: Double, edit: EditModel) {
        let ds = decodeScale > 0 && decodeScale.isFinite ? decodeScale : 1
        let crop = CropMath.lockedCrop(edit.geometry.aspectLock,
                                      in: edit.geometry.cropRect,
                                      source: decoded)
        self.init(viewport: viewport,
                  sourceWidth: Double(decoded.width) / ds,
                  sourceHeight: Double(decoded.height) / ds,
                  crop: crop,
                  straightenDegrees: edit.geometry.straightenDegrees,
                  flipH: edit.geometry.flipHorizontal,
                  flipV: edit.geometry.flipVertical)
    }

    // MARK: crop metrics

    public var cropWidthPixels: Double { crop.width * sourceWidth }
    public var cropHeightPixels: Double { crop.height * sourceHeight }
    public var cropOriginX: Double { crop.left * sourceWidth }
    public var cropOriginY: Double { crop.top * sourceHeight }

    /// Canvas pixels per source pixel when the **whole source frame** is fitted into the viewport.
    ///
    /// 072 §A0 — the base is the full frame (`sourceWidth`/`sourceHeight`: the upright frame S0
    /// ingested, before any crop), and the crop is only the *visible window*. It used to be measured
    /// on the crop (`cropWidthPixels`), which made fit mean "blow the kept part up to the viewport":
    /// a 50 % crop was drawn at twice the scale of the picture it was cut out of, so `fit`, `1:1` and
    /// `2:1` were three different ratios depending on the document's crop rect. One invariant now:
    ///
    ///     fit  = the whole frame fits the viewport      (a 50 % crop covers half of it)
    ///     1:1  = one source pixel → one device pixel    (crop or no crop)
    ///     2:1  = two device pixels per source pixel     (crop or no crop)
    ///
    /// `min(1, …)`: an image smaller than the viewport is shown at 1:1, never blown up — the M3 rule.
    /// The result is therefore always in `(0, 1]`, and it is usually **not** one of the zoom stops:
    /// 0.31 for a 60 MP frame in a 2560-px viewport, 0.72 for a 24 MP one, exactly 1.0 for a file that
    /// already fits. It is also not *in* the ladder — `fit` is a mode, and its ratio is only ever used
    /// to lay the frame out and to label the readout (`适应 31%`). Nothing may assume fit sits below
    /// 25 %, below 50 %, or below the current zoom.
    public var fitZoom: Double {
        let z = min(Double(viewport.width) / max(sourceWidth, 1e-9),
                    Double(viewport.height) / max(sourceHeight, 1e-9))
        guard z.isFinite, z > 0 else { return 1 }
        return min(1, z)
    }

    public func zoom(of state: LoupeViewState) -> Double {
        state.mode == .actual ? LoupeViewState.clampZoom(state.zoom) : fitZoom
    }

    // MARK: window

    /// How much of the window must keep covering the picture when the camera leaves the crop.
    ///
    /// The camera is allowed to walk off the edge of the photograph — a zoom anchored on a pixel near
    /// the corner, or a zoom *out* from a corner, pushes the window outward, and stopping it there
    /// would move the very pixel the gesture is about. What it may not do is walk so far that the user
    /// is looking at nothing: the window's centre stays **on the picture**, so at least half of the
    /// canvas always shows photograph and the way back is always visible. Half is the value that does
    /// that without a second rule — it needs no knowledge of the zoom, the window or the crop, and it
    /// fails gracefully: a window bigger than the crop (zoomed out on a small file) has no legal
    /// excursion at all and is centred, which is what it was always doing.
    ///
    /// At the limit the camera **stops**; it does not rubber-band or spring back, so letting go of a
    /// drag never moves the picture.
    public static let minimumPictureCoverage: Double = 0.5

    /// The visible window, in source pixels: the viewport at `zoom`, **not** clipped to the crop.
    ///
    /// It used to be `min(crop, viewport / zoom)`, which silently rescaled the picture whenever the
    /// crop was smaller than the viewport — a second, invisible zoom. The window is now the canvas at
    /// the camera's scale; the part of it that misses the picture is background (`s0_geometry` writes
    /// zero there, it does not stretch the edge), and `limitedCenter` is what keeps that part from
    /// taking over the screen.
    public func windowSize(of state: LoupeViewState) -> (width: Double, height: Double) {
        guard state.mode == .actual else {
            return (cropWidthPixels, cropHeightPixels)
        }
        let z = zoom(of: state)
        return (Double(viewport.width) / z, Double(viewport.height) / z)
    }

    /// Window centre in source pixels, limited by `minimumPictureCoverage`.
    public func windowCenter(of state: LoupeViewState) -> (x: Double, y: Double) {
        let size = windowSize(of: state)
        guard state.mode == .actual else {
            return (cropOriginX + cropWidthPixels / 2, cropOriginY + cropHeightPixels / 2)
        }
        return limitedCenter(x: state.centerX, y: state.centerY, window: size)
    }

    /// The legal range for a window centre: far enough out that `minimumPictureCoverage` of the window
    /// still lands on the picture, and no further.
    ///
    /// With the coverage rule at ½ this reduces to "the centre stays inside the crop", which is the
    /// whole policy in one line. The interval is empty for a window larger than the crop — nothing can
    /// reach ½ coverage then — and a window that big has exactly one sensible place to be.
    public func limitedCenter(x: Double, y: Double,
                              window: (width: Double, height: Double)) -> (x: Double, y: Double) {
        let n = Self.minimumPictureCoverage
        let minX = cropOriginX + n * window.width - window.width / 2
        let maxX = cropOriginX + cropWidthPixels + window.width / 2 - n * window.width
        let minY = cropOriginY + n * window.height - window.height / 2
        let maxY = cropOriginY + cropHeightPixels + window.height / 2 - n * window.height
        let cx = maxX <= minX ? cropOriginX + cropWidthPixels / 2 : min(max(x, minX), maxX)
        let cy = maxY <= minY ? cropOriginY + cropHeightPixels / 2 : min(max(y, minY), maxY)
        return (cx, cy)
    }

    /// Kept under its old name for the callers that spelled the containment rule out: a centre that
    /// keeps the **whole** window inside the crop. Nothing in the camera uses it any more — the loupe
    /// allows the picture to leave the frame (`limitedCenter`) — but a document-level crop still wants
    /// this, and it is the honest name for "strictly inside".
    public func clampedCenter(x: Double, y: Double,
                              window: (width: Double, height: Double)) -> (x: Double, y: Double) {
        let halfWidth = window.width / 2, halfHeight = window.height / 2
        let minX = cropOriginX + halfWidth, maxX = cropOriginX + cropWidthPixels - halfWidth
        let minY = cropOriginY + halfHeight, maxY = cropOriginY + cropHeightPixels - halfHeight
        // A window at least as big as the crop has exactly one legal centre.
        let cx = maxX <= minX ? cropOriginX + cropWidthPixels / 2 : min(max(x, minX), maxX)
        let cy = maxY <= minY ? cropOriginY + cropHeightPixels / 2 : min(max(y, minY), maxY)
        return (cx, cy)
    }

    /// The window as a normalized crop rect — what the renderer is handed (as the derived document).
    public func cropRect(of state: LoupeViewState) -> CropRect {
        guard state.mode == .actual else { return crop }
        let size = windowSize(of: state)
        let centre = windowCenter(of: state)
        return CropRect(left: (centre.x - size.width / 2) / sourceWidth,
                        top: (centre.y - size.height / 2) / sourceHeight,
                        right: (centre.x + size.width / 2) / sourceWidth,
                        bottom: (centre.y + size.height / 2) / sourceHeight).clamped()
    }

    /// What the renderer draws, in device pixels (before the crop's integer rounding).
    public func contentSize(of state: LoupeViewState) -> (width: Double, height: Double) {
        let size = windowSize(of: state)
        let z = zoom(of: state)
        return (size.width * z, size.height * z)
    }

    /// `RenderOptions.scale` for this state: output pixels per **decoded** pixel.
    ///
    /// The requested output is `window × zoom` device pixels by definition; `RenderGraph` computes
    /// it as `cropPixels × scale` where `cropPixels` is measured on the decoded buffer, hence the
    /// division by the decode scale.
    public func renderScale(of state: LoupeViewState, decodeScale: Double) -> Double {
        let ds = decodeScale > 0 ? decodeScale : 1
        return zoom(of: state) / ds
    }

    /// The visible window in **source** pixels (what `cropRect(of:)` covers).
    public func windowPixels(of state: LoupeViewState) -> ImageSize {
        let size = windowSize(of: state)
        return ImageSize(width: Int(size.width.rounded()), height: Int(size.height.rounded()))
    }

    /// The picture the canvas receives, in device pixels: the window at `zoom`.
    public func contentPixels(of state: LoupeViewState) -> ImageSize {
        let content = contentSize(of: state)
        return ImageSize(width: Int(content.width.rounded()), height: Int(content.height.rounded()))
    }

    /// The window as `RenderOptions.outputWindow`: **content pixels** of the full crop frame at the
    /// state's `scale`. `nil` for `fit`, which is the whole frame by definition.
    ///
    /// This is the render-side description of a 1:1 window: the frame is cropped/straightened/flipped
    /// once, and this rect is the part of *that* picture the viewport shows. One source pixel is
    /// `zoom` content pixels, so the arithmetic is the source-pixel window minus the crop's origin,
    /// scaled by `zoom` — no rotation of its own, because the window lives in the frame, not in the
    /// source (`ZoomedEditCarriesTheWindow…` pins the two descriptions against each other).
    public func outputWindow(of state: LoupeViewState) -> ImageRect? {
        guard state.mode == .actual else { return nil }
        let z = zoom(of: state)
        guard z.isFinite, z > 0 else { return nil }
        let size = windowSize(of: state)
        let centre = windowCenter(of: state)
        let left = (centre.x - size.width / 2 - cropOriginX) * z
        let top = (centre.y - size.height / 2 - cropOriginY) * z
        return ImageRect(x: Int(left.rounded()), y: Int(top.rounded()),
                         width: Int((size.width * z).rounded()),
                         height: Int((size.height * z).rounded()))
    }

    /// The document the renderer should be given for this state, **as an output window** routed
    /// through the crop (`zoomedEdit`) — kept only as the mapping's own expression of the window.
    ///
    /// `outputWindow(of:)` is what the loupe actually renders with: it hands the frame's crop to S0
    /// untouched and names the window, so the projection, the vignette and the mask feather all stay
    /// frame-relative. Expressing the window as a crop instead costs three things, all inherited from
    /// S0/S3c being written before windows existed:
    ///   · S0 rotates in *normalized crop* space, so a window whose aspect differs from the crop's
    ///     is a slightly different projection (~0.3 % of the window at 9° straighten);
    ///   · S3c vignette and the mask feather normalize to the content rect, which for a 1:1 window is
    ///     the window — a vignette measured against what is visible rather than the frame;
    ///   · the derivation has to keep the user's aspect lock out of the way.
    /// `WindowTests` measures all three. What this function is still good for is the *mapping*: the
    /// rect it produces and `outputWindow(of:)` name the same region, which
    /// `testOutputWindowAndTheDerivedCropNameTheSameRegion` checks.
    public func zoomedEdit(_ edit: EditModel, for state: LoupeViewState) -> EditModel {
        guard state.mode == .actual else { return edit }
        var e = edit
        e.geometry.crop = cropRect(of: state).normalizedRect
        // The window is not the user's aspect lock; the rect above is already the resolved one.
        e.geometry.aspectLock = .original
        return e
    }

    // MARK: mapping

    public func mapping(of state: LoupeViewState) -> LoupeMapping {
        let content = contentSize(of: state)
        let size = windowSize(of: state)
        let centre = windowCenter(of: state)
        let theta = straightenDegrees * .pi / 180
        return LoupeMapping(
            viewport: viewport,
            contentWidth: content.width,
            contentHeight: content.height,
            cropLeft: centre.x - size.width / 2,
            cropTop: centre.y - size.height / 2,
            cropWidth: size.width,
            cropHeight: size.height,
            cosT: cos(theta),
            sinT: sin(theta),
            flipH: flipH,
            flipV: flipV,
            frameWidth: sourceWidth,
            frameHeight: sourceHeight)
    }

    /// Where a canvas-sized frame texture sits on the **whole picture** (058) — the input the backdrop
    /// needs to convert the frame's window into the picture's coordinates
    /// (`PresentWindow.onWholePicture`).
    ///
    /// `mapping` is the projection the texture was rendered for (`LoupeMapping`): its content rect is
    /// where the photograph is inside the canvas, and its window is which part of the photograph the
    /// texture holds. Both halves are needed and neither is the identity in general:
    ///
    ///     region = (cropLeft − cropOrigin) / cropSize  …  + cropWidth / cropSize     (source px)
    ///     rect   = (originX, originY, contentWidth, contentHeight) / viewport         (device px)
    ///
    /// The region is expressed in the picture's own **display** order, so a flipped document mirrors
    /// it (`u ↦ 1 − u`): the whole-picture texture is rendered with the same flip, and a window on the
    /// left of the source is on the right of that texture. Straighten contributes nothing here, for
    /// the reason `outputWindow(of:)` gives: the window lives in the frame, not in the source.
    public func framePlacement(of mapping: LoupeMapping) -> FramePlacement {
        let cw = max(cropWidthPixels, 1e-9), ch = max(cropHeightPixels, 1e-9)
        var u0 = (mapping.cropLeft - cropOriginX) / cw
        var u1 = u0 + mapping.cropWidth / cw
        var v0 = (mapping.cropTop - cropOriginY) / ch
        var v1 = v0 + mapping.cropHeight / ch
        if mapping.flipH { (u0, u1) = (1 - u1, 1 - u0) }
        if mapping.flipV { (v0, v1) = (1 - v1, 1 - v0) }
        let vp = mapping.viewport
        let w = Double(max(vp.width, 1)), h = Double(max(vp.height, 1))
        let rect = PresentWindow(u0: Float(mapping.originX / w), v0: Float(mapping.originY / h),
                                 du: Float(mapping.contentWidth / w),
                                 dv: Float(mapping.contentHeight / h))
        return FramePlacement(region: CropRect(x: u0, y: v0, width: u1 - u0, height: v1 - v0),
                              rect: rect)
    }

    /// View point (points, from `NSEvent`, y down) → source pixel.
    public func sourcePoint(of state: LoupeViewState, viewX: Double, viewY: Double,
                            backingScale: Double = 1) -> (x: Double, y: Double) {
        mapping(of: state).sourcePoint(viewX: viewX * backingScale, viewY: viewY * backingScale)
    }

    /// Source pixel → view point (points, y down).
    public func viewPoint(of state: LoupeViewState, sourceX: Double, sourceY: Double,
                          backingScale: Double = 1) -> (x: Double, y: Double) {
        let p = mapping(of: state).viewPoint(sourceX: sourceX, sourceY: sourceY)
        return (p.x / backingScale, p.y / backingScale)
    }

    // MARK: interactions

    /// Move the window by a **content** delta in device pixels (drag right → the picture moves right,
    /// so the window moves left).
    ///
    /// The delta is rotated into source space: with straighten the S0 sampling applies R(θ) to the
    /// window offset, so a pan of `d` canvas pixels is `R(θ)·d / zoom` source pixels. Flips need no
    /// term of their own — they mirror *inside* the window, so the window moves with the hand.
    public func panning(_ state: LoupeViewState, byContent delta: (x: Double, y: Double)) -> LoupeViewState {
        guard state.mode == .actual else { return state }
        let z = zoom(of: state)
        guard z > 0 else { return state }
        let theta = straightenDegrees * .pi / 180
        let cs = cos(theta), sn = sin(theta)
        let dx = (delta.x * cs - delta.y * sn) / z
        let dy = (delta.x * sn + delta.y * cs) / z
        // A drag that runs off the edge of the picture keeps its picture: the window may hang over the
        // edge (`minimumPictureCoverage`), it stops where the canvas would stop being photograph, and
        // it stays there when the hand lets go.
        let centre = limitedCenter(x: state.centerX + dx, y: state.centerY + dy,
                                   window: windowSize(of: state))
        var next = state
        next.centerX = centre.x
        next.centerY = centre.y
        return next
    }

    /// Zoom to `zoom` while keeping the source pixel under `view` (points) where it is — the pinch
    /// and the "double-click at 1:1" rule. One affine step is exact: the centre enters the mapping
    /// with slope 1.
    public func zooming(_ state: LoupeViewState, to zoom: Double, aroundView view: CGPoint,
                        backingScale: Double = 1) -> LoupeViewState {
        // A fit state carries no meaningful centre (it shows the whole crop); start from the
        // crop's centre so the "keep this pixel under the cursor" step has a real pivot.
        var base = state
        if base.mode != .actual {
            base.mode = .actual
            let fitCentre = windowCenter(of: state)
            base.centerX = fitCentre.x
            base.centerY = fitCentre.y
        }
        var next = base
        next.mode = .actual
        next.zoom = LoupeViewState.clampZoom(zoom)
        // With the new zoom and the *old* centre, the cursor sits on `anchor`; the old state put
        // `mapped` there. Shifting the centre by (mapped − anchor) is exact: the centre enters the
        // mapping with slope 1.
        let anchor = mapping(of: next).sourcePoint(viewX: Double(view.x) * backingScale,
                                                   viewY: Double(view.y) * backingScale)
        // `mapped` comes from the *current* projection, which for a fit state is the fit zoom —
        // `base` only exists to give `next` a real centre, and its placeholder 1:1 is not it.
        let mapped = mapping(of: state).sourcePoint(viewX: Double(view.x) * backingScale,
                                                    viewY: Double(view.y) * backingScale)
        let centre = windowCenter(of: state)
        // The anchored pixel stays put, exactly, unless the window would end up with less than
        // `minimumPictureCoverage` of itself on the picture — then it stops at the limit, and this is
        // the only case in which a zoom moves the pixel it was told to keep.
        let shifted = limitedCenter(x: centre.x + (mapped.x - anchor.x),
                                    y: centre.y + (mapped.y - anchor.y),
                                    window: windowSize(of: next))
        next.centerX = shifted.x
        next.centerY = shifted.y
        return next
    }

    /// Centre the window on a source pixel (double-click into 1:1, "zoom in here").
    public func centering(_ state: LoupeViewState, onSource point: (x: Double, y: Double)) -> LoupeViewState {
        var next = state
        let centre = limitedCenter(x: point.x, y: point.y, window: windowSize(of: next))
        next.centerX = centre.x
        next.centerY = centre.y
        return next
    }

    /// The source point the viewport is centred on — what `fit` has to remember before it leaves.
    public func visibleCenter(of state: LoupeViewState) -> (x: Double, y: Double) {
        windowCenter(of: state)
    }
}

// MARK: - mapping

/// The view ↔ source projection for one resolved state. Affine, invertible, and written against the
/// same half-pixel conventions as `s0_geometry.metal`.
public struct LoupeMapping: Equatable, Sendable {
    public let viewport: ImageSize
    /// Content rect in device pixels (the letterboxed picture inside the viewport).
    public let contentWidth: Double
    public let contentHeight: Double
    /// The window rect in source pixels.
    public let cropLeft: Double
    public let cropTop: Double
    public let cropWidth: Double
    public let cropHeight: Double
    public let cosT: Double
    public let sinT: Double
    public let flipH: Bool
    public let flipV: Bool
    /// The **upright frame** the rotation turns about, in source pixels. Zero falls back to the
    /// window (`cropWidth`/`cropHeight`) for a caller that has no frame of its own.
    ///
    /// Load-bearing: the rotation has to be applied about *some* centre in *uniform* units, and
    /// `s0_geometry` turns the whole frame about its centre in frame pixels. Applying it to
    /// `(u − ½, v − ½)` — the normalised window — is what sheared the picture (the u axis is divided
    /// by the width and the v axis by the height, so `R(θ)` is followed by a non-uniform scale).
    public let frameWidth: Double
    public let frameHeight: Double

    public init(viewport: ImageSize, contentWidth: Double, contentHeight: Double,
                cropLeft: Double, cropTop: Double, cropWidth: Double, cropHeight: Double,
                cosT: Double, sinT: Double, flipH: Bool, flipV: Bool,
                frameWidth: Double = 0, frameHeight: Double = 0) {
        self.viewport = viewport
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.cropLeft = cropLeft
        self.cropTop = cropTop
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.cosT = cosT
        self.sinT = sinT
        self.flipH = flipH
        self.flipV = flipV
        self.frameWidth = frameWidth > 0 ? frameWidth : max(cropWidth, 1e-9)
        self.frameHeight = frameHeight > 0 ? frameHeight : max(cropHeight, 1e-9)
    }

    public var originX: Double { (Double(viewport.width) - contentWidth) / 2 }
    public var originY: Double { (Double(viewport.height) - contentHeight) / 2 }

    /// Canvas pixels per source pixel this projection draws at — `contentWidth / cropWidth`, which is
    /// `zoom` for an `actual` camera and `fitZoom` for the whole-frame one. The uniform scale between
    /// two cameras is the ratio of these (`LoupeZoomBridge.scale`).
    public var canvasPerSource: Double { contentWidth / max(cropWidth, 1e-9) }

    // MARK: the two spaces a view point can mean
    //
    //   view  ──(axis-aligned zoom, no rotation)──▶  frame / display space  ──(R(θ), θ = 0 for the
    //                                                                        crop tool)──▶  source
    //
    // The **crop rect lives in frame space**: `s0_geometry` crops the straightened frame, so a
    // rectangle in that space is a rectangle on screen. Everything the crop tool draws (corners,
    // grips, grid) and every drag it interprets therefore goes through `framePoint`/`frameView`, and
    // the rotation never reaches the overlay — which is what keeps the eight grips axis-aligned.

    /// Device pixel → the straightened frame, in source pixels. **No rotation** (that belongs to
    /// `sourcePoint`, i.e. to the picture, not to the frame a crop is drawn in).
    public func framePoint(viewX: Double, viewY: Double) -> (x: Double, y: Double) {
        (cropLeft + (viewX - originX) * cropWidth / max(contentWidth, 1e-9),
         cropTop + (viewY - originY) * cropHeight / max(contentHeight, 1e-9))
    }

    /// The straightened frame → device pixel; the inverse of `framePoint`, and the one the overlay
    /// draws with.
    public func frameView(frameX: Double, frameY: Double) -> (x: Double, y: Double) {
        (originX + (frameX - cropLeft) * contentWidth / max(cropWidth, 1e-9),
         originY + (frameY - cropTop) * contentHeight / max(cropHeight, 1e-9))
    }

    /// Device pixel → source pixel.
    ///
    /// Two steps, and the split is the whole fix:
    ///
    ///   1. view → the frame, in pixels (`u` across the window, flips as before, then `cropLeft + u·cropWidth`);
    ///   2. the frame → the source, by turning the **pixel offsets** about the frame's centre.
    ///
    /// Step 2 used to rotate `(u − ½, v − ½)` — coordinates normalised *per axis* — and then scale by
    /// the crop's width and height, which is `R(θ)` followed by a non-uniform scale: the two basis
    /// vectors come out unequal and non-orthogonal (a shear whose factor is the frame's W/H, so a
    /// portrait file shears the other way). `s0_geometry.metal` now turns pixel offsets for the same
    /// reason, so this really is the kernel's inverse and not merely a plausible-looking map.
    public func sourcePoint(viewX: Double, viewY: Double) -> (x: Double, y: Double) {
        // 1. view → the frame, in pixels — axis-aligned, flips and all, about the **window's own**
        //    centre. Same centre and same order as the projection this replaced, so pan/zoom anchoring
        //    and flipped documents behave exactly as they did.
        let cx = cropLeft + cropWidth / 2, cy = cropTop + cropHeight / 2
        var fx = cropLeft + (viewX - originX) * cropWidth / max(contentWidth, 1e-9)
        var fy = cropTop + (viewY - originY) * cropHeight / max(contentHeight, 1e-9)
        if flipH { fx = 2 * cx - fx }
        if flipV { fy = 2 * cy - fy }
        // 2. the rotation — of **pixel** offsets, about that centre. This is the one line the shear
        //    lived on: rotating `(u − ½, v − ½)` (u divided by the width, v by the height) and then
        //    scaling by `cropWidth`/`cropHeight` is `R(θ)` followed by a non-uniform scale, so the basis
        //    came out unequal (1.022 at 9° on 3:2, 1.5 at 45°) and non-orthogonal (cos −0.13). In pixels
        //    the map is a similarity and `s0_geometry.metal` matches it.
        let qx = fx - cx, qy = fy - cy
        let rx = qx * cosT - qy * sinT
        let ry = qx * sinT + qy * cosT
        return (rx + cx, ry + cy)
    }

    /// Source pixel → device pixel (the inverse of the above; `sourcePoint(viewPoint(p)) == p`).
    public func viewPoint(sourceX: Double, sourceY: Double) -> (x: Double, y: Double) {
        let cx = cropLeft + cropWidth / 2, cy = cropTop + cropHeight / 2
        let qx = sourceX - cx, qy = sourceY - cy
        // Kernel applies R(θ); the inverse applies R(−θ) — in pixels, so it is a pure rotation.
        let rx = qx * cosT + qy * sinT
        let ry = -qx * sinT + qy * cosT
        var fx = rx + cx, fy = ry + cy
        if flipH { fx = 2 * cx - fx }
        if flipV { fy = 2 * cy - fy }
        return (originX + (fx - cropLeft) * contentWidth / max(cropWidth, 1e-9),
                originY + (fy - cropTop) * contentHeight / max(cropHeight, 1e-9))
    }
}
