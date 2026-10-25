import CoreGraphics
import Foundation
import PhotonsCore

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

    /// The pinch/drag ceiling. Above 8:1 a 60 MP frame is being shown through 64 canvas pixels per
    /// source pixel — there is no information left to reveal, only interpolation to admire.
    public static let maximumZoom: Double = 8
    public static let minimumZoom: Double = 1

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

    /// 1…8, the interactive domain (fit is a separate mode, not a zoom value).
    public static func clampZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return minimumZoom }
        return min(max(zoom, minimumZoom), maximumZoom)
    }

    /// "fit" / "1:1" / "4.0:1" — what the status chip and `--ui-smoke` print.
    public var zoomLabel: String {
        switch mode {
        case .fit: return "fit"
        case .actual:
            let z = Self.clampZoom(zoom)
            return abs(z - 1) < 0.005 ? "1:1" : String(format: "%.1f:1", z)
        }
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
    /// `min(1, …)`: an image smaller than the viewport is shown at 1:1, never blown up — the M3 rule,
    /// and the reason `fit ≤ 1:1 ≤ zoom` holds for every image, which is what lets pinching stay in
    /// the single interval 1…8 instead of straddling the fit scale.
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

    /// The visible window, in source pixels.
    ///
    /// At `fit` it is the whole crop. At `actual` it is `viewport ÷ zoom`, clamped to the crop so a
    /// window that would reach past the frame instead shrinks and letterboxes — which is exactly how
    /// "fit" itself is rendered, so both modes go through one path.
    public func windowSize(of state: LoupeViewState) -> (width: Double, height: Double) {
        guard state.mode == .actual else {
            return (cropWidthPixels, cropHeightPixels)
        }
        let z = zoom(of: state)
        return (min(cropWidthPixels, Double(viewport.width) / z),
                min(cropHeightPixels, Double(viewport.height) / z))
    }

    /// Window centre in source pixels, clamped so the window stays inside the crop.
    public func windowCenter(of state: LoupeViewState) -> (x: Double, y: Double) {
        let size = windowSize(of: state)
        guard state.mode == .actual else {
            return (cropOriginX + cropWidthPixels / 2, cropOriginY + cropHeightPixels / 2)
        }
        return clampedCenter(x: state.centerX, y: state.centerY, window: size)
    }

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
        let centre = clampedCenter(x: state.centerX + dx, y: state.centerY + dy,
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
        let shifted = clampedCenter(x: centre.x + (mapped.x - anchor.x),
                                    y: centre.y + (mapped.y - anchor.y),
                                    window: windowSize(of: next))
        next.centerX = shifted.x
        next.centerY = shifted.y
        return next
    }

    /// Centre the window on a source pixel (double-click into 1:1, "zoom in here").
    public func centering(_ state: LoupeViewState, onSource point: (x: Double, y: Double)) -> LoupeViewState {
        var next = state
        let centre = clampedCenter(x: point.x, y: point.y, window: windowSize(of: next))
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
