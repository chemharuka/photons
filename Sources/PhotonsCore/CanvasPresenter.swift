import Foundation
import Metal
import QuartzCore
import CoreGraphics

/// Which part of a texture a draw reads — `uv = window.xy + canvasPosition · window.zw`.
///
/// The window is expressed against the **canvas**, not against the quad: a frame texture is
/// canvas-sized, and the window is the map that places it there. Two consequences, both load-bearing
/// since 067:
///
///   · the quad that draws the photograph is *derived* from this window and the photograph's rect in
///     the texture (`PresentRequest`), so the geometry and the sampling cannot disagree;
///   · a quad that covers the whole canvas reads exactly this window, which is why the covering case
///     is bit-identical to 025's full-screen pass.
///
/// `size` and `origin` are deliberately **not** clamped: a shrunk frame sampled through a wider
/// window used to be how 025 filled the canvas, and the arithmetic here is still what places a frame
/// on a canvas of a different size (`stretched(to:from:)`). What changed in 067 is that the *quad*
/// is bounded, so no fragment ever reads past the picture: the window describes the map, the quad
/// describes the coverage, and only the second one decides where the canvas gets paint.
public struct PresentWindow: Equatable, Sendable {
    public var u0: Float
    public var v0: Float
    public var du: Float
    public var dv: Float

    public init(u0: Float = 0, v0: Float = 0, du: Float = 1, dv: Float = 1) {
        self.u0 = u0.isFinite ? u0 : 0
        self.v0 = v0.isFinite ? v0 : 0
        self.du = du.isFinite ? du : 1
        self.dv = dv.isFinite ? dv : 1
    }

    /// The whole texture, the identity — what every pre-window caller means.
    public static let whole = PresentWindow()

    /// The window that draws the picture **scaled by `s` and moved by `(originX, originY)`** — the map
    /// `canvasPoint ↦ s·canvasPoint + origin` in canvas pixels — onto a canvas of `canvas` pixels from
    /// a texture of `texture` pixels.
    ///
    /// The canvas *samples* the inverse of that map (`texel = (p − origin) / s`), which is why a
    /// shrinking window (`s < 1`) comes out **larger** than the texture and a growing one (`s > 1`) is
    /// a sub-rect.
    public init(scale s: Double, originX: Double, originY: Double,
                canvas: ImageSize, texture: ImageSize) {
        let w = Double(max(texture.width, 1)), h = Double(max(texture.height, 1))
        guard s.isFinite, s > 1e-9 else { self.init(); return }
        let inv = 1 / s
        self.init(u0: Float(-originX * inv / w), v0: Float(-originY * inv / h),
                  du: Float(inv * Double(max(canvas.width, 1)) / w),
                  dv: Float(inv * Double(max(canvas.height, 1)) / h))
    }

    /// Does this window cover every texel of the texture — i.e. does the canvas, read through it,
    /// contain no area the picture does not reach? True for the identity and for every *shrinking*
    /// window; false when zooming in (there the canvas shows a sub-rect, which is real content too).
    public var coversWholeTexture: Bool {
        let eps: Float = 1e-6
        return u0 <= eps && v0 <= eps && u0 + du >= 1 - eps && v0 + dv >= 1 - eps
    }

    /// The texel a canvas point reads, before the sampler's clamp — `(u, v)` in `[0, 1]` for a point
    /// inside the picture. Public because it is the whole of the window's arithmetic and a test can
    /// pin it without a drawable.
    public func texel(canvasX: Double, canvasY: Double, canvas: ImageSize) -> (u: Double, v: Double) {
        let w = Double(max(canvas.width, 1)), h = Double(max(canvas.height, 1))
        return (Double(u0) + canvasX / w * Double(du), Double(v0) + canvasY / h * Double(dv))
    }

    /// This window read as a window on the **whole picture** (058): the same canvas rectangle, said
    /// in the coordinates of the low-resolution whole-picture texture the backdrop is.
    ///
    /// A window is expressed in the frame **texture** (`uv = u0 + canvasUV · du`), and a frame texture
    /// is not the whole picture: it is a canvas-sized render of one part of it, with the photograph
    /// letterboxed inside. `placement` is that relationship — which part of the picture the texture
    /// covers, and where the picture sits inside the texture — so the composition below is the affine
    /// map `canvas → picture`:
    ///
    ///     f   = (uv − rect.origin) / rect.size      // where in the texture's photograph this is
    ///     u_p = region.origin + f · region.size     // the same point of the whole picture
    ///
    /// Two properties come out of it and are what the backdrop needs: a window that reaches every
    /// canvas pixel maps into `[0, 1]` (the picture *is* the canvas there), and a window that draws the
    /// whole picture into the canvas — 适应 — maps to exactly `[0, 1]`, so the backdrop's own texels
    /// land on the canvas untruncated.
    public func onWholePicture(_ placement: FramePlacement) -> PresentWindow {
        let r = placement.rect, g = placement.region
        // A degenerate placement has no rect to normalise against; `0` size is the honest answer and
        // `PresentWindow`'s initialiser keeps it finite.
        let sx = Double(r.du) > 1e-12 ? g.width / Double(r.du) : 0
        let sy = Double(r.dv) > 1e-12 ? g.height / Double(r.dv) : 0
        return PresentWindow(u0: Float(g.left + (Double(u0) - Double(r.u0)) * sx),
                             v0: Float(g.top + (Double(v0) - Double(r.v0)) * sy),
                             du: Float(Double(du) * sx),
                             dv: Float(Double(dv) * sy))
    }

    /// The same map on a canvas that has changed size while the picture has not moved — 067's
    /// live-resize geometry.
    ///
    /// `uv` is a texture coordinate and `canvasPosition` is a *fraction* of the canvas, so keeping the
    /// uv of a canvas **pixel** fixed while the canvas grows or shrinks means scaling the window's
    /// size by the ratio and leaving its origin alone:
    ///
    ///     uv(p_px) = u0 + p_px / W_new · du_new = u0 + p_px / W_old · du_old
    ///
    /// A window stretched this way draws the same picture at the same canvas pixels: a smaller
    /// drawable crops it, a larger one shows more of it, and nothing is rescaled. That is exactly the
    /// behaviour a window drag wants — the picture must not stretch while the hand is moving
    /// (「变扁」), and the area a grown canvas exposes is filled by the backdrop through this same
    /// map, i.e. with the picture's own low-resolution continuation instead of a colour or a black
    /// band. `PresentRequest` derives both quads from the window, so the frozen case needs no
    /// geometry of its own.
    public func stretched(to newCanvas: ImageSize, from oldCanvas: ImageSize) -> PresentWindow {
        guard oldCanvas.width > 0, oldCanvas.height > 0,
              newCanvas.width > 0, newCanvas.height > 0 else { return self }
        let sx = Float(newCanvas.width) / Float(oldCanvas.width)
        let sy = Float(newCanvas.height) / Float(oldCanvas.height)
        return PresentWindow(u0: u0, v0: v0, du: du * sx, dv: dv * sy)
    }

    /// The canvas rectangle — normalised, y down — where a texture sub-rect lands through this window.
    /// The inverse of the shader's map: `canvasPosition = (uv − u0) / du`.
    ///
    /// `nil` for a degenerate axis (a zero window has no rectangle; `makeParams` used to divide by it
    /// and the fragment had to floor the divisor to survive), which the callers turn into an empty
    /// quad instead of a divide-by-zero.
    public func canvasRect(ofTexture u: Double, _ v: Double,
                           _ width: Double, _ height: Double)
        -> (x: Double, y: Double, width: Double, height: Double)? {
        let dx = Double(du), dy = Double(dv)
        guard abs(dx) > 1e-9, abs(dy) > 1e-9 else { return nil }
        return ((u - Double(u0)) / dx, (v - Double(v0)) / dy, width / dx, height / dy)
    }

    /// The same rectangle in **canvas pixels**, rounded to whole pixels and clipped to the canvas.
    ///
    /// Clipping is not a correction — the GPU would clip the quad anyway — but it keeps the numbers
    /// the pass is handed inside the surface it draws on, which is what `PresentQuadInvariantTests`
    /// asserts (a quad that is inside the canvas by construction cannot be the reason a band appears).
    /// Rounding is the cost of `ImageRect` being integral: on a *settled* frame the rect comes from the
    /// render's own receipt and is exact; on a bridge frame it is off by less than one pixel, and the
    /// sampling is unaffected because the shader takes its uv from the canvas position, not from the
    /// quad's local coordinates.
    public func canvasRect(of textureRect: ImageRect, texture: ImageSize,
                           canvas: ImageSize) -> ImageRect {
        let w = Double(max(texture.width, 1)), h = Double(max(texture.height, 1))
        guard let r = canvasRect(ofTexture: Double(textureRect.x) / w,
                                 Double(textureRect.y) / h,
                                 Double(textureRect.width) / w,
                                 Double(textureRect.height) / h) else { return Self.noRect }
        let cw = Double(max(canvas.width, 1)), ch = Double(max(canvas.height, 1))
        let x0 = (r.x * cw).rounded(), y0 = (r.y * ch).rounded()
        let x1 = ((r.x + r.width) * cw).rounded(), y1 = ((r.y + r.height) * ch).rounded()
        return ImageRect(x: Int(x0), y: Int(y0),
                         width: Int(max(0, x1 - x0)), height: Int(max(0, y1 - y0)))
            .intersected(in: canvas)
    }

    /// A rect with no area — "nothing of this is on the canvas".
    static var noRect: ImageRect { ImageRect(x: 0, y: 0, width: 0, height: 0) }
}

/// Where a canvas-sized frame texture sits on the **whole picture** (058) — the second coordinate
/// system the backdrop needs, and the one 053 was missing.
///
/// A frame texture is rendered *for the canvas* (`RenderOptions.canvas`): the photograph is letterboxed
/// inside it, and the part of the photograph it holds is whatever the camera was looking at. Neither
/// half is the identity, and both move with the zoom:
///
///   · at 300 %, `region` is a ninth of the picture but `rect` is the whole canvas — the texture is all
///     photograph, of a small region;
///   · at 适应, `region` is the whole picture but `rect` is the letterboxed rectangle inside the canvas,
///     so the picture covers `[0, 1]` of the texture only when its aspect matches the canvas's.
///
/// `region` is deliberately **not** clamped to `[0, 1]`: the camera may walk off the picture's edge
/// (`LoupeFraming.minimumPictureCoverage`), and then the texture's own black beyond the photograph is
/// beyond the picture too — clamping would move the photograph instead of letting it end where it ends.
public struct FramePlacement: Equatable, Sendable {
    /// The part of the whole picture the frame texture covers, in picture-normalised coordinates.
    public var region: CropRect
    /// The photograph's rect inside the canvas, in canvas-normalised coordinates: `xy` = origin,
    /// `zw` = size. The identity means the photograph fills the canvas, which is what a window render
    /// at the camera's own zoom produces.
    public var rect: PresentWindow

    public init(region: CropRect, rect: PresentWindow) {
        self.region = region
        self.rect = rect
    }

    /// A texture that *is* the whole picture, filling the canvas: the composition is the identity, and
    /// `window.onWholePicture(.whole)` is `window` — 053's assumption, true only in this case.
    public static let whole = FramePlacement(region: .full, rect: .whole)

    /// Does the texture hold the whole picture (so a frame window and a picture window are the same
    /// number)? True at 适应 with no letterbox, and for a texture rendered without a canvas.
    public var coversPicture: Bool {
        let eps = 1e-6
        return abs(region.left) < eps && abs(region.top) < eps
            && abs(region.right - 1) < eps && abs(region.bottom - 1) < eps
    }

    /// The composition is the identity: the texture *is* the picture, canvas and picture edges alike.
    public var isIdentity: Bool { coversPicture && rect == .whole }
}

/// **The one thing a present takes** (067).
///
/// 054–065 passed the picture's rectangle through four call sites (settled frame, bridge frame,
/// bridge stop, bridge teardown) and three of them could forget or mis-space it; the fragment then
/// painted the frame's `float4(0)` letterbox as black, or painted `#0F0F0F` at a rect the picture had
/// already left. A request cannot be forgotten — there is no overload without one — and its geometry
/// is derived, not passed alongside:
///
///   · `pictureQuad` is where the photograph lands on the canvas. It follows from `window` and
///     `photoRect` (the photograph's rect *inside* the frame texture, which is the render's own
///     receipt) by inversion, so a bridge frame's quad moves with the bridge's map instead of staying
///     where the held frame's rect was;
///   · `backdropQuad` is where the whole picture lands, which follows from `backdropWindow` alone.
///
/// The pass then draws at most two quads into a cleared surface; the fragment never asks whether a
/// texel is the photograph. See `present.metal`.
public struct PresentRequest {

    /// This frame's texture: the photograph, letterboxed with zeros outside `photoRect`.
    public let picture: MTLTexture
    /// The canvas every rect in this request is expressed in, in pixels — the surface the quads were
    /// computed for. `present` draws into a drawable of exactly this size: a surface of another size
    /// is the photograph at another aspect, which is the 066 bug, and the one thing this type refuses
    /// to do quietly.
    public let canvas: ImageSize
    /// Where the photograph goes on the canvas, in canvas pixels. **The** geometry of the picture.
    public let pictureQuad: ImageRect
    /// The texels of `picture` the quad reads: the frame's window (identity for a settled frame).
    public let window: PresentWindow
    /// The whole picture at low resolution, drawn *behind* the picture quad. `nil` = none.
    public let backdrop: MTLTexture?
    /// Where the whole picture goes on the canvas, in canvas pixels. Derived from `backdropWindow`.
    public let backdropQuad: ImageRect?
    /// The texels of `backdrop` its quad reads — picture coordinates (058).
    public let backdropWindow: PresentWindow

    /// The request every call site builds: the geometry is inverted from the frame's own window.
    ///
    /// `photoRect` is the photograph's rect inside `picture` in that texture's pixels — for a
    /// settled frame, `RenderResult.photoRect`; for the frame held on the canvas during a zoom,
    /// its own receipt. `canvas` is the surface the pass will draw into (the drawable), which is what
    /// makes the quad resolution-independent.
    public init(picture: MTLTexture, photoRect: ImageRect, window: PresentWindow,
                canvas: ImageSize, backdrop: MTLTexture? = nil,
                backdropWindow: PresentWindow = .whole) {
        let texture = ImageSize(width: picture.width, height: picture.height)
        let quad = window.canvasRect(of: photoRect, texture: texture, canvas: canvas)
        var backdropQuad: ImageRect?
        if let backdrop {
            let low = ImageSize(width: backdrop.width, height: backdrop.height)
            let whole = ImageRect(x: 0, y: 0, width: low.width, height: low.height)
            let derived = backdropWindow.canvasRect(of: whole, texture: low, canvas: canvas)
            backdropQuad = derived.isEmpty ? nil : derived
        }
        self.init(picture: picture, canvas: canvas, pictureQuad: quad, window: window,
                  backdrop: backdrop, backdropQuad: backdropQuad, backdropWindow: backdropWindow)
    }

    /// Explicit geometry — for a caller that has the quads and not the windows (a test that wants to
    /// place a quad by hand) and for the initialiser above. The window still decides the sampling, so
    /// the two cannot be independent numbers in practice.
    public init(picture: MTLTexture, canvas: ImageSize, pictureQuad: ImageRect,
                window: PresentWindow, backdrop: MTLTexture? = nil,
                backdropQuad: ImageRect? = nil, backdropWindow: PresentWindow = .whole) {
        self.picture = picture
        self.canvas = canvas
        self.pictureQuad = pictureQuad
        self.window = window
        self.backdrop = backdropQuad == nil ? nil : backdrop
        self.backdropQuad = backdropQuad
        self.backdropWindow = backdropWindow
    }

    /// Nothing to draw on the picture: a degenerate window, or a quad the canvas does not hold. The
    /// pass still clears, which is the honest picture of "the frame reached nothing here".
    public var hasPicture: Bool { !pictureQuad.isEmpty && window.du != 0 && window.dv != 0 }

    /// What the pass will draw, in painter's order: the backdrop first, the picture over it.
    public var quads: [(rect: ImageRect, window: PresentWindow, texture: MTLTexture)] {
        var out: [(rect: ImageRect, window: PresentWindow, texture: MTLTexture)] = []
        if let backdrop, let backdropQuad {
            out.append((backdropQuad, backdropWindow, backdrop))
        }
        if hasPicture {
            out.append((pictureQuad, window, picture))
        }
        return out
    }
}

/// Presents an S4 output texture into a `CAMetalLayer` — the last hand-off of the on-screen path.
///
/// The loupe canvas is a plain `NSView` whose backing layer is a `CAMetalLayer`; nothing in the view
/// does zooming or layer transforms (research `ui-stack.md` F6: every editor that got 1:1 right
/// re-renders at the new scale instead of scaling a layer). This type owns the one GPU pass between
/// `RenderGraph` and the drawable.
public final class CanvasPresenter {

    /// 054 — the colour of the canvas **around** the picture: `#0F0F0F`.
    ///
    /// Since 067 this colour has exactly **one** producer on screen: the render pass's clear colour.
    /// The shader does not carry it any more (it used to paint it per fragment from `photoRect`,
    /// which is how a present that forgot the rect drew black instead), and the two layer backgrounds
    /// in `LoupeController` keep it for the frames before the first drawable arrives. The bands around
    /// a fitted picture are *not* a layer colour and no longer anything the pass computes: S2/S4 write
    /// `float4(0)` outside the photograph, the picture quad simply does not cover those pixels, and
    /// the clear colour shows through. The texture's zeros are never sampled — which is also what
    /// leaves the photograph's bytes and the histogram (measured on S4 over the photograph) untouched.
    ///
    /// The value is a **display-encoded** (`sRGB`-encoded) 8-bit code, because that is the space
    /// `#0F0F0F` is written in. The 16-bit layer stores linear light, so that path needs `linear` —
    /// the same number through the sRGB EOTF.
    public enum CanvasMatte {
        /// `#0F` — 15 of 255.
        public static let eightBitValue: UInt8 = 0x0F
        /// `0F0F0F` as the display-encoded value every 8-bit path stores.
        public static let displayEncoded: Double = Double(eightBitValue) / 255
        /// The same colour as linear light, for the `rgba16Float` / extended-linear drawable.
        public static let linear: Double = {
            let v = displayEncoded
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }()

        /// The render pass's clear colour, in the transfer function of the attachment.
        public static func clearColor(linear: Bool) -> MTLClearColor {
            let v = linear ? self.linear : displayEncoded
            return MTLClearColor(red: v, green: v, blue: v, alpha: 1)
        }
    }

    /// How the drawable stores its pixels. Chosen by what the layer accepts, not by a preference.
    public enum Storage: String, Sendable {
        /// rgba16Float + `extendedLinearDisplayP3`; values are linear light, >1 allowed (EDR-ready).
        case linear16
        /// bgra8Unorm + sRGB; values stay display-encoded and clamped. Fallback.
        case srgb8

        public var pixelFormat: MTLPixelFormat {
            switch self {
            case .linear16: return .rgba16Float
            case .srgb8: return .bgra8Unorm
            }
        }

        public var colorSpace: CGColorSpace? {
            switch self {
            case .linear16: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            case .srgb8: return CGColorSpace(name: CGColorSpace.sRGB)
            }
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let kernels: KernelLibrary
    public private(set) var storage: Storage

    /// Why the last frame did not reach the screen (`nil` = it did).
    public private(set) var lastFailure: String?

    // MARK: what the layer was actually handed (068)

    /// One present that reached a drawable: the canvas its quads were computed for, the drawable it
    /// actually drew into, and the two quads. A resize test asserts on this instead of on the picture:
    /// `drawableSize == canvas` is the invariant (068's check makes it structural), and `canvas` is a
    /// pixel rectangle of the canvas that was on screen when the pass ran.
    public struct PresentedGeometry: Equatable, Sendable {
        public let canvas: ImageSize
        public let drawableSize: ImageSize
        public let pictureQuad: ImageRect
        public let backdropQuad: ImageRect?
    }

    /// The last present that reached a drawable (nil before the first drawable).
    public private(set) var presentedGeometry: PresentedGeometry?
    /// Presents that reached a drawable — the number a coalescing test counts. It is a *draw*, not a
    /// request: a resize that is merged into one runloop tick shows up here once.
    public private(set) var presentCount = 0
    /// Requests refused because their quads belonged to another canvas (see `present`). 0 in the app;
    /// the counter exists so "a frame for the old canvas was never drawn" is a number, not a promise.
    public private(set) var droppedStaleFrameCount = 0

    public init(device: MTLDevice? = nil, storage: Storage = .linear16) throws {
        guard let d = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noMetalDevice
        }
        guard let q = d.makeCommandQueue() else { throw RenderError.noMetalDevice }
        self.device = d
        self.queue = q
        self.kernels = KernelLibrary(device: d)
        self.storage = storage
    }

    /// The canvas contract, in one place (§11.8 item 3): M3 opens no EDR picture, so the flag stays
    /// false. Turning EDR on in M3.5 is this boolean plus `DisplayOptions.headroom`.
    public static func configure(_ layer: CAMetalLayer, storage: Storage, wantsEDR: Bool = false) {
        // A CAMetalLayer with no device answers `nextDrawable()` with nil forever. Setting it here
        // (rather than relying on the view) keeps every canvas on the same device as the renderer.
        layer.device = MTLCreateSystemDefaultDevice()
        layer.pixelFormat = storage.pixelFormat
        layer.colorspace = storage.colorSpace
        layer.wantsExtendedDynamicRangeContent = wantsEDR
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.displaySyncEnabled = true
    }

    /// Draw one request into `layer`. Returns true when a frame was actually presented.
    ///
    /// **`drawableSize` is the canvas, and it must be the canvas that is on screen now** (025, 066):
    /// a texture rendered for another size can never be drawn correctly — the quads are pixel
    /// rectangles, so an old-canvas frame in a new drawable is the photograph at the wrong aspect
    /// (「变扁」). This parameter is the size the quads were computed against, and it is the layer's
    /// size that has to follow it, not the other way round.
    ///
    /// 068 makes that a **check**, not a convention: a request whose canvas is not the drawable asked
    /// for is refused before `nextDrawable()` — the pass would draw the photograph at another aspect,
    /// and taking a drawable for it costs a vsync on the main thread (which, inside a drag, is the
    /// jelly). `droppedStaleFrameCount` is the number of times it happened, and it is 0 in the app.
    ///
    /// A layer that refuses a 16-bit drawable (`nextDrawable()` returning nil) falls back to the
    /// 8-bit sRGB path **once**, and keeps that choice: silently retrying every frame would halve the
    /// frame rate on exactly the machines where it failed.
    @discardableResult
    public func present(_ request: PresentRequest, in layer: CAMetalLayer, wantsEDR: Bool = false,
                        drawableSize: ImageSize? = nil, onComplete: (() -> Void)? = nil) -> Bool {
        if let drawableSize, drawableSize != request.canvas {
            droppedStaleFrameCount += 1
            lastFailure = "request is for a \(request.canvas.keyString) canvas, drawable is "
                + "\(drawableSize.keyString) — refused before the GPU work"
            return false
        }
        // The quads are pixel rectangles of the request's canvas, so that — not the texture's own
        // size, and not "whatever the layer last had" — is the drawable they belong in.
        let target = drawableSize ?? request.canvas
        let size = CGSize(width: max(1, target.width), height: max(1, target.height))
        if layer.drawableSize != size { layer.drawableSize = size }

        var drawable = layer.nextDrawable()
        if drawable == nil, storage == .linear16 {
            storage = .srgb8
            Self.configure(layer, storage: .srgb8, wantsEDR: false)
            layer.drawableSize = size
            drawable = layer.nextDrawable()
        }
        guard let drawable else {
            lastFailure = "CAMetalLayer returned no drawable (offscreen or headless session)"
            return false
        }

        guard let cb = queue.makeCommandBuffer() else {
            lastFailure = "no command buffer"
            return false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // 067: the clear colour is the *whole* canvas colour. Everything a quad does not cover is
        // this, from the first drawable on — there is no second producer of the matte anywhere.
        pass.colorAttachments[0].clearColor = CanvasMatte.clearColor(linear: storage == .linear16)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            lastFailure = "no render encoder"
            return false
        }

        do {
            try draw(request, into: enc, linearize: storage == .linear16,
                     format: drawable.texture.pixelFormat)
            enc.endEncoding()
        } catch {
            enc.endEncoding()
            lastFailure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return false
        }

        cb.present(drawable)
        if let onComplete {
            cb.addCompletedHandler { _ in onComplete() }
        }
        cb.commit()
        // Recorded only when a drawable was actually handed the pixels: this is the log a resize test
        // reads for "every frame that reached the screen was drawn for the canvas on screen".
        presentedGeometry = PresentedGeometry(canvas: request.canvas, drawableSize: target,
                                              pictureQuad: request.pictureQuad,
                                              backdropQuad: request.backdropQuad)
        presentCount += 1
        lastFailure = nil
        return true
    }

    /// The same pass, into an ordinary texture instead of a drawable — the present kernel's own
    /// arithmetic with no window server in the way.
    ///
    /// The on-screen path cannot be read back (`framebufferOnly`), so this is how a test looks at
    /// *pixels*: what the quads (and the clear) do to a canvas is visible here and nowhere else. It is
    /// the same pipeline and the same `PresentParams` the drawable gets, not a test-only copy.
    @discardableResult
    public func render(_ request: PresentRequest, into target: MTLTexture,
                       linearize: Bool? = nil) -> Bool {
        guard let cb = queue.makeCommandBuffer() else {
            lastFailure = "no command buffer"
            return false
        }
        let linear = linearize ?? (target.pixelFormat == .rgba16Float)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = CanvasMatte.clearColor(linear: linear)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            lastFailure = "no render encoder"
            return false
        }
        do {
            try draw(request, into: enc, linearize: linear, format: target.pixelFormat)
            enc.endEncoding()
        } catch {
            enc.endEncoding()
            lastFailure = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            return false
        }
        cb.commit()
        cb.waitUntilCompleted()
        lastFailure = cb.error.map { "\($0)" }
        return cb.error == nil
    }

    // MARK: - the one draw

    /// **The only place this type draws.** At most two quads — the low-resolution whole picture, then
    /// the photograph — into one encoder that has already cleared the canvas to `#0F0F0F`.
    ///
    /// They are separate draws, not one shader with a branch, for the reason 037 gave and 067 keeps:
    /// a GPU cannot predicate a texture fetch, so a uniform branch still pays for the fetch. Two draws
    /// of four vertices is the cheap way to have the picture read the frame and the band read the
    /// backdrop. Painter's order does the compositing: no blending, no depth buffer, the later quad
    /// simply replaces the earlier one where it lands.
    private func draw(_ request: PresentRequest, into enc: MTLRenderCommandEncoder,
                      linearize: Bool, format: MTLPixelFormat) throws {
        let quads = request.quads
        guard !quads.isEmpty else { return }
        // One pipeline for every quad: the fragment does not know which texture it reads, which is the
        // whole point — it samples what the binding says and transfers it.
        let pipeline = try kernels.renderPipeline(file: "present", vertex: "present_vertex",
                                                  fragment: "present_fragment",
                                                  pixelFormat: format)
        enc.setRenderPipelineState(pipeline)
        let canvas = request.canvas
        for quad in quads {
            var params = PresentParams(quad: Self.normalised(quad.rect, canvas: canvas),
                                       window: SIMD4(quad.window.u0, quad.window.v0,
                                                     quad.window.du, quad.window.dv),
                                       misc: SIMD4(linearize ? 1 : 0, 0, 0, 0))
            enc.setFragmentTexture(quad.texture, index: 0)
            enc.setVertexBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    /// A quad in canvas-normalised coordinates — the space the vertex stage draws in, and the space the
    /// window's `uv = u0 + p · du` is written against.
    static func normalised(_ rect: ImageRect, canvas: ImageSize) -> SIMD4<Float> {
        let w = Float(max(canvas.width, 1)), h = Float(max(canvas.height, 1))
        return SIMD4(Float(rect.x) / w, Float(rect.y) / h,
                     Float(rect.width) / w, Float(rect.height) / h)
    }

    /// The CPU half of the struct both sides must agree on.
    ///
    /// `PresentParams` is handed to the GPU as raw bytes (`setVertexBytes`/`setFragmentBytes`), so the
    /// Swift layout and the `present.metal` declaration are one contract with no compiler check
    /// between them — and this project has already read a stale parameter silently once. Three
    /// `float4`s, 16 bytes each, stride 48; `BackdropPresenterTests` parses `present.metal` and pins
    /// both sides against these numbers.
    struct PresentParams {
        /// The rectangle this draw covers, **canvas-normalised**: `xy` = origin, `zw` = size.
        var quad: SIMD4<Float>
        /// The uv window the quad reads: `xy` = origin, `zw` = size, normalised texture coordinates.
        var window: SIMD4<Float>
        /// `x` = linearize; the rest is padding so the field stays a `float4`.
        var misc: SIMD4<Float>

        init(quad: SIMD4<Float>, window: SIMD4<Float>, misc: SIMD4<Float>) {
            self.quad = quad
            self.window = window
            self.misc = misc
        }
    }
}
