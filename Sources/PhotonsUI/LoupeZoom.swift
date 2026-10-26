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
    /// The stop floor. Below 1:2 the frame is smaller than the fit view, which is what `mode == .fit`
    /// already means, so 0.5 is the last rung before the whole frame.
    ///
    /// Not to be confused with the *fit ratio*: `LoupeFraming.fitZoom` is a property of the window and
    /// the crop (0.31 for a 60 MP frame in a 2560-px viewport, 0.72 for a 24 MP one, 1.0 for a small
    /// file) and is **not** one of the stops. The ladder is `levels(fitZoom:)`, and it inserts the live
    /// fit ratio wherever it actually falls.
    public static let minimumZoom: Double = 0.5

    /// The discrete stops, ascending. `fit` is a mode rather than a number (`levels(fitZoom:)` puts
    /// the live ratio in its place), so this is the numeric half of the ladder.
    public static let zoomStops: [Double] = [0.5, 1, 2, 3, 4]

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

    /// 0.5…4, the interactive domain (fit is a separate mode, not a zoom value).
    public static func clampZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return minimumZoom }
        return min(max(zoom, minimumZoom), maximumZoom)
    }

    /// `"适应"` for the whole-frame mode, otherwise the stop as a percentage: `"100%"` is 1:1.
    ///
    /// The fit rung's real ratio is not in here on purpose — a `LoupeViewState` does not know the
    /// window, so it cannot know what `fitZoom` is. `LoupeController.zoomLabel` adds it
    /// (`"适应 31%"`); the ladder's own `LoupeZoomLevel.displayLabel` does the same from a known ratio.
    public var zoomLabel: String {
        switch mode {
        case .fit: return "适应"
        case .actual: return Self.percentLabel(of: Self.clampZoom(zoom))
        }
    }

    /// `0.5 → "50%"`, `1 → "100%"`, `3 → "300%"`. Whole percent: the stops are all whole numbers of
    /// percent, and a readout with decimals is a readout nobody asked for.
    public static func percentLabel(of zoom: Double) -> String {
        let z = zoom.isFinite ? zoom : 1
        return "\(Int((z * 100).rounded()))%"
    }
}

// MARK: - the ladder

/// One rung of the zoom ladder: a stop, or the frame's own fit ratio.
///
/// `fit` is a rung whose *value* moves with the window and the crop, which is why the ladder is a
/// function (`LoupeViewState.levels(fitZoom:)`) and not a constant. For a 60 MP frame in a 2560-px
/// viewport it is 0.31 and the ladder is `[0.31 适应, 0.5, 1, 2, 3, 4]`; for a 24 MP frame it can be
/// 0.72 and the ladder is `[0.5, 0.72 适应, 1, 2, 3, 4]`; for a file smaller than the viewport it is
/// 1.0 and the 100 % stop folds into it. Nothing here may assume the fit ratio sits below 50 %.
public struct LoupeZoomLevel: Equatable, Sendable, Comparable {

    /// Canvas pixels per source pixel. For `isFit` this is the live `LoupeFraming.fitZoom`.
    public let zoom: Double
    /// The rung `mode == .fit` corresponds to. Exactly one ladder entry carries it.
    public let isFit: Bool

    public init(zoom: Double, isFit: Bool = false) {
        self.zoom = zoom
        self.isFit = isFit
    }

    /// `"适应"` / `"50%"` — what the 倍率 menu and the six-state readout use.
    public var label: String { isFit ? "适应" : LoupeViewState.percentLabel(of: zoom) }

    /// `"适应 31%"` / `"50%"` — the status strip, where the fit ratio is worth printing because the
    /// user can see it move with the window.
    public var displayLabel: String {
        isFit ? "适应 \(LoupeViewState.percentLabel(of: zoom))" : label
    }

    public static func < (a: LoupeZoomLevel, b: LoupeZoomLevel) -> Bool { a.zoom < b.zoom }

    /// Two rungs this close are the same rung: 0.72 and 0.5 must not both appear, and a fit ratio of
    /// 0.998 must not sit next to 100 %.
    public static let tolerance = 0.005
}

extension LoupeViewState {

    /// The ladder for a frame whose fit ratio is `fitZoom`: the fit rung plus the five stops, sorted
    /// by value and de-duplicated (`LoupeZoomLevel.tolerance`).
    ///
    /// Recomputed per call rather than cached: `fitZoom` moves with the window size, the crop and the
    /// straighten, so a cached table would be a stale table the moment the user resizes. When the fit
    /// ratio coincides with a stop the **fit rung wins** — `mode == .fit` is the state the camera is
    /// actually in, and a second entry 0.002 away would be a menu item that does nothing.
    public static func levels(fitZoom: Double) -> [LoupeZoomLevel] {
        let fit = fitZoom.isFinite && fitZoom > 0 ? fitZoom : 1
        let candidates = [LoupeZoomLevel(zoom: fit, isFit: true)]
            + zoomStops.map { LoupeZoomLevel(zoom: $0) }
        var out: [LoupeZoomLevel] = []
        // Ties sort fit-first so the fold below always keeps the fit rung.
        for level in candidates.sorted(by: { $0.zoom < $1.zoom || ($0.zoom == $1.zoom && $0.isFit) }) {
            if let last = out.last, abs(last.zoom - level.zoom) < LoupeZoomLevel.tolerance { continue }
            out.append(level)
        }
        return out
    }

    /// The rung a raw zoom value lands on: **the largest rung not above it**.
    ///
    /// This is the "自动往下走一级" rule from one place instead of four event handlers. It is a floor,
    /// not a nearest-value round: a pinch to 0.9 on a 60 MP frame lands on 50 %, never on 100 %.
    /// Below the lowest rung the camera shows the whole frame — there is nothing further out than
    /// fit, and pinching out from fit must not skip the 50 % rung on its way to 100 %.
    public static func snappedLevel(for target: Double, fitZoom: Double) -> LoupeZoomLevel {
        let ladder = levels(fitZoom: fitZoom)
        let t = target.isFinite ? target : 1
        if let level = ladder.last(where: { $0.zoom <= t + 1e-9 }) { return level }
        return ladder.first(where: { $0.isFit }) ?? LoupeZoomLevel(zoom: fitZoom, isFit: true)
    }
}

// MARK: - the scaling bridge (every stop change)

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

    public init(fromContent: ImageSize, toContent: ImageSize,
                fromMapping: LoupeMapping, toMapping: LoupeMapping, canvas: ImageSize,
                startScale: Double = 1, startOffsetX: Double = 0, startOffsetY: Double = 0,
                duration: CFTimeInterval = LoupeZoomBridge.defaultDuration) {
        self.fromContent = fromContent
        self.toContent = toContent
        self.fromMapping = fromMapping
        self.toMapping = toMapping
        self.canvas = canvas
        self.startScale = startScale
        self.startOffsetX = startOffsetX
        self.startOffsetY = startOffsetY
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

    // MARK: the layer transform

    /// `CATransform3D` for `aN(p) = s · aO(p) + o`, expressed in the layer's own coordinates.
    ///
    /// `CALayer.transform` is applied about the **anchor point** (the canvas centre here), and its
    /// coordinates are points with y **up** from the layer's bottom-left, while every number above is
    /// device pixels with y **down** from the top-left. The two conversions cancel in a way worth
    /// writing down, since a sign error here slides the picture by half a viewport:
    ///
    ///     v_yup = (canvas.height / backingScale) − v_ydown / backingScale
    ///     t_up  = (o.x / k, (1 − s) · H − o.y / k)         with H = canvas.height / k
    ///     τ     = t_up − (1 − s) · (W/2, H/2)              (what the anchor-point conjugation leaves)
    ///
    /// so `m41 = o.x/k − (1 − s)·W/2` and `m42 = (1 − s)·H/2 − o.y/k`, with `m11 = m22 = s`.
    public func transform(scale s: Double, offset o: (x: Double, y: Double),
                          backingScale: Double) -> CATransform3D {
        let k = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let w = Double(canvas.width) / k
        let h = Double(canvas.height) / k
        var m = CATransform3DIdentity
        m.m11 = CGFloat(s)
        m.m22 = CGFloat(s)
        m.m41 = CGFloat(o.x / k - (1 - s) * w / 2)
        m.m42 = CGFloat((1 - s) * h / 2 - o.y / k)
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

    /// Canvas pixel (device pixels, y down) → layer point (points, y up). The test-side half of the
    /// conversion above, so the map can be asserted in the space it was derived in.
    public func layerPoint(canvasX: Double, canvasY: Double, backingScale: Double) -> CGPoint {
        let k = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        return CGPoint(x: canvasX / k, y: (Double(canvas.height) - canvasY) / k)
    }

    /// The layer's anchor point in its own points — the canvas centre, which is where `CALayer`
    /// applies the transform about (the default `anchorPoint` is `(0.5, 0.5)`).
    public func layerAnchor(backingScale: Double) -> CGPoint {
        let k = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        return CGPoint(x: Double(canvas.width) / k / 2, y: Double(canvas.height) / k / 2)
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
    public static func offset(ofLayerTransform m: CATransform3D, canvas: ImageSize,
                              backingScale: Double) -> (scale: Double, x: Double, y: Double) {
        let k = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let w = Double(canvas.width) / k
        let h = Double(canvas.height) / k
        let s = Double(m.m11)
        guard s.isFinite, s > 0 else { return (1, 0, 0) }
        return (s, k * (Double(m.m41) + (1 - s) * w / 2), k * ((1 - s) * h / 2 - Double(m.m42)))
    }

    // MARK: how long

    /// 120 ms for the smallest step, 260 ms for the longest, `+60 ms` per **octave** in between.
    ///
    /// The span is `|log2(scale)|` and not a difference of percentages, because what the eye reads is
    /// the *rate of growth*: 100 → 200 % and 200 → 400 % are the same event (one octave, 180 ms),
    /// while 300 → 400 % is half of one (145 ms) and 100 → 50 % → fit is a shrink of the same size as
    /// the growth that left them. 180 ms is also what the fit ↔ 100 % bridge has always used, so the
    /// crossing the app was tuned on keeps its feel. Below 120 ms a 2× change still reads as a cut
    /// (that is one 60 Hz frame plus a bit); above 260 ms the wait for the sharp frame is what the
    /// user notices instead of the motion.
    public static let durationPerOctave: CFTimeInterval = 0.060
    public static let minimumDuration: CFTimeInterval = 0.120
    public static let maximumDuration: CFTimeInterval = 0.260
    public static let defaultDuration: CFTimeInterval = 0.180

    public static func duration(from startScale: Double, to endScale: Double) -> CFTimeInterval {
        guard startScale > 0, endScale > 0,
              startScale.isFinite, endScale.isFinite else { return defaultDuration }
        let octaves = abs(log2(endScale / startScale))
        let raw = minimumDuration + durationPerOctave * octaves
        return min(max(raw, minimumDuration), maximumDuration)
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

    /// Canvas pixels per source pixel when the whole crop is fitted into the viewport.
    ///
    /// `min(1, …)`: an image smaller than the viewport is shown at 1:1, never blown up — the M3 rule.
    /// The result is therefore always in `(0, 1]`, and it is usually **not** one of the zoom stops:
    /// 0.31 for a 60 MP frame in a 2560-px viewport, 0.72 for a 24 MP one, exactly 1.0 for a file that
    /// already fits. The ladder (`LoupeViewState.levels(fitZoom:)`) inserts this value as its own rung
    /// wherever it falls, so the stops (0.5…4) and fit are ordered by value, not by convention —
    /// nothing may assume fit sits below 50 %, and nothing may assume the current zoom is ≥ fit.
    public var fitZoom: Double {
        let z = min(Double(viewport.width) / max(cropWidthPixels, 1e-9),
                    Double(viewport.height) / max(cropHeightPixels, 1e-9))
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
            flipV: flipV)
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

    public init(viewport: ImageSize, contentWidth: Double, contentHeight: Double,
                cropLeft: Double, cropTop: Double, cropWidth: Double, cropHeight: Double,
                cosT: Double, sinT: Double, flipH: Bool, flipV: Bool) {
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
    }

    public var originX: Double { (Double(viewport.width) - contentWidth) / 2 }
    public var originY: Double { (Double(viewport.height) - contentHeight) / 2 }

    /// Canvas pixels per source pixel this projection draws at — `contentWidth / cropWidth`, which is
    /// `zoom` for an `actual` camera and `fitZoom` for the whole-frame one. The uniform scale between
    /// two cameras is the ratio of these (`LoupeZoomBridge.scale`).
    public var canvasPerSource: Double { contentWidth / max(cropWidth, 1e-9) }

    /// Device pixel → source pixel.
    public func sourcePoint(viewX: Double, viewY: Double) -> (x: Double, y: Double) {
        var u = (viewX - originX) / max(contentWidth, 1e-9)
        var v = (viewY - originY) / max(contentHeight, 1e-9)
        if flipH { u = 1 - u }
        if flipV { v = 1 - v }
        let ox = u - 0.5, oy = v - 0.5
        let rx = ox * cosT - oy * sinT
        let ry = ox * sinT + oy * cosT
        return (cropLeft + (rx + 0.5) * cropWidth,
                cropTop + (ry + 0.5) * cropHeight)
    }

    /// Source pixel → device pixel (the inverse of the above; `sourcePoint(viewPoint(p)) == p`).
    public func viewPoint(sourceX: Double, sourceY: Double) -> (x: Double, y: Double) {
        let rx = (sourceX - cropLeft) / max(cropWidth, 1e-9) - 0.5
        let ry = (sourceY - cropTop) / max(cropHeight, 1e-9) - 0.5
        // Kernel applies R(θ); the inverse applies R(−θ).
        let ox = rx * cosT + ry * sinT
        let oy = -rx * sinT + ry * cosT
        var u = ox + 0.5
        var v = oy + 0.5
        if flipH { u = 1 - u }
        if flipV { v = 1 - v }
        return (originX + u * contentWidth, originY + v * contentHeight)
    }
}
