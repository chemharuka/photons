import Foundation
import Metal
import QuartzCore
import CoreGraphics

/// Which part of the source texture the present quad reads — `uv = origin + corner · size`.
///
/// The quad itself always covers the whole drawable, so this is the *only* thing that moves the
/// picture: it is how the loupe carries the frame on screen from one camera to the next without
/// touching the layer's geometry (a layer transform would scale the drawable past the canvas and
/// expose the window behind it — the two bugs 025 reports).
///
/// `size` and `origin` are in normalised texture coordinates and are deliberately **not** clamped to
/// `[0, 1]`: a shrinking window is larger than the texture, and `clamp_to_edge` in the fragment
/// sampler is what extends the picture's own edge pixels over the rest of the canvas, so a shrink
/// never shows an unrendered band.
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
    /// shrinking window (`s < 1`) comes out **larger** than the texture: its `du` is `1/s`, the UVs run
    /// past `[0, 1]`, and `clamp_to_edge` is what fills the canvas. A growing one (`s > 1`) is a
    /// sub-rect — the canvas then shows part of the picture, which is exactly what zooming in means.
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
    /// One definition for the four places that must not drift: the shader's matte (`present.metal`),
    /// the render pass's clear colour, and the two layer backgrounds in `LoupeController`. The bands
    /// around a fitted picture are *not* a layer colour — S2/S4 write `float4(0)` outside the
    /// photograph, so the black lives **in the canvas texture** and the matte has to be painted by the
    /// present pass. The layer colour only covers the frame before the first drawable arrives, and the
    /// clear colour only the area a triangle does not reach; both are set to the same value so the
    /// canvas never flashes black on its way to grey.
    ///
    /// The value is a **display-encoded** (`sRGB`-encoded) 8-bit code, because that is the space
    /// `#0F0F0F` is written in. The 16-bit layer stores linear light, so that path needs
    /// `linear` — the same number through the sRGB EOTF — and `present.metal` gets it by running the
    /// display value through `present_transfer`, exactly as it does for every photograph pixel.
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

    /// Draw `texture` into `layer`. Returns true when a frame was actually presented.
    ///
    /// **`drawableSize` is the canvas, and it is not the texture's own size** (025): a texture larger
    /// than the canvas must never reach the drawable, or the picture would spill over the browser
    /// pane, the inspector and the top bar. The size is passed in by the caller that owns the layout
    /// (`LoupeController.viewportPixels`) and the part of the texture to show is named separately.
    ///
    /// **`backdrop`** (037) is a low-resolution copy of *the whole picture*, passed while a shrink is
    /// in flight: see `render(_:window:backdrop:backdropWindow:into:linearize:)` for what the pass
    /// does with it. `nil` — the default, and every caller that has not been wired up yet — keeps the
    /// 025 behaviour exactly (`clamp_to_edge` stretching the picture's own edge).
    ///
    /// A layer that refuses a 16-bit drawable (`nextDrawable()` returning nil) falls back to the
    /// 8-bit sRGB path **once**, and keeps that choice: silently retrying every frame would halve the
    /// frame rate on exactly the machines where it failed.
    ///
    /// **`pictureRect`** (054) is where the photograph sits **inside the frame texture**, in canvas
    /// pixels of the drawable — `RenderResult.pictureRect` for a settled frame. The pass paints
    /// `#0F0F0F` outside it, which is the letterbox the user sees in fit mode; inside it every byte is
    /// unchanged. `nil` — every caller that has not been wired up, and every caller whose texture is
    /// the picture itself — means "the picture is the whole canvas", i.e. no matte at all, and is
    /// bit-for-bit 025's output. Pass it only when the texture was rendered for exactly this drawable
    /// size: the rect is normalised by the drawable, so a frame rendered for a different canvas would
    /// put the boundary in the wrong place. With a `backdrop` the matte is not drawn at all (the canvas
    /// outside the main window is the picture's own low-res continuation), so the rect is ignored.
    @discardableResult
    public func present(_ texture: MTLTexture, in layer: CAMetalLayer, wantsEDR: Bool = false,
                        drawableSize: ImageSize? = nil, window: PresentWindow = .whole,
                        backdrop: MTLTexture? = nil, backdropWindow: PresentWindow = .whole,
                        pictureRect: ImageRect? = nil,
                        onComplete: (() -> Void)? = nil) -> Bool {
        let target = drawableSize ?? ImageSize(width: texture.width, height: texture.height)
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
        // 054: the same matte the fragment paints, so the frame a drawable does not cover (first frame,
        // a clipped edge) is grey from the very first present instead of flashing black.
        pass.colorAttachments[0].clearColor = CanvasMatte.clearColor(linear: storage == .linear16)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            lastFailure = "no render encoder"
            return false
        }

        do {
            let pipeline = try kernels.renderPipeline(file: "present", vertex: "present_vertex",
                                                      fragment: Self.fragmentName(backdrop),
                                                      pixelFormat: drawable.texture.pixelFormat)
            var params = Self.makeParams(linearize: storage == .linear16, window: window,
                                         backdrop: backdrop, backdropWindow: backdropWindow,
                                         canvas: target, pictureRect: pictureRect)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
            // Bound even when there is no backdrop: the fragment's two-sample branch is uniform but
            // the compiler still emits the fetch, and a nil texture there trips the debug layer.
            enc.setFragmentTexture(backdrop ?? texture, index: 1)
            enc.setVertexBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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
        lastFailure = nil
        return true
    }

    /// The same pass, into an ordinary texture instead of a drawable — the present kernel's own
    /// arithmetic with no window server in the way.
    ///
    /// The on-screen path cannot be read back (`framebufferOnly`), so this is how a test looks at
    /// *pixels*: what a window does to the canvas is visible here and nowhere else. It is also the
    /// shape any future offscreen consumer wants, which is why it is the same pipeline and the same
    /// params rather than a test-only copy of the shader.
    ///
    /// ### `backdrop` (037)
    ///
    /// A shrinking window is larger than the texture, so the canvas has area the main frame does not
    /// reach; 025 filled it with the picture's own edge (`clamp_to_edge`), which the user sees as a
    /// band of stretched colour around the picture. `backdrop` is the *whole picture* at low
    /// resolution (`backdropWindow` = where the canvas reads it, normally `.whole`): the pass samples
    /// it for the canvas outside the main window and cross-fades over a `backdropFeatherPixels`-wide
    /// band so the two do not meet on a hard seam. Zoomed in the main window covers the canvas, so
    /// the whole canvas is main-frame colour and the backdrop fetch changes nothing.
    ///
    /// `backdrop == nil` is the 025 path unchanged: one sample, `clamp_to_edge`, and the output is
    /// **byte for byte** what it was before this parameter existed (pinned by
    /// `BackdropPresenterTests.testNoBackdropOutputIsByteIdenticalTo025`).
    ///
    /// `pictureRect` (054) is the same argument `present` takes: the photograph's rect inside the
    /// frame texture, in canvas pixels of `target`. Outside it the pass writes `#0F0F0F`. It is the
    /// only way a test can look at the matte, since the on-screen drawable is `framebufferOnly`.
    @discardableResult
    public func render(_ texture: MTLTexture, window: PresentWindow = .whole,
                       backdrop: MTLTexture? = nil, backdropWindow: PresentWindow = .whole,
                       pictureRect: ImageRect? = nil,
                       into target: MTLTexture, linearize: Bool? = nil) -> Bool {
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
            let pipeline = try kernels.renderPipeline(file: "present", vertex: "present_vertex",
                                                      fragment: Self.fragmentName(backdrop),
                                                      pixelFormat: target.pixelFormat)
            var params = Self.makeParams(linearize: linear, window: window,
                                         backdrop: backdrop, backdropWindow: backdropWindow,
                                         canvas: ImageSize(width: target.width, height: target.height),
                                         pictureRect: pictureRect)
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentTexture(backdrop ?? texture, index: 1)
            enc.setVertexBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<PresentParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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

    // MARK: - the CPU half of the kernel contract

    /// The width, in canvas pixels, of the cross-fade between the main frame and the backdrop.
    ///
    /// Two pixels, measured **inside** the picture's own edge: wide enough that a low-resolution
    /// backdrop does not meet the sharp frame on a visible step, narrow enough that the picture is not
    /// visibly soft while a zoom runs. Outside the edge the backdrop is what is drawn, unchanged.
    public static let backdropFeatherPixels: Double = 2

    /// Which of `present.metal`'s two fragments to draw with.
    ///
    /// Two entry points rather than one shader with a branch: a uniform branch is not free on a GPU
    /// that cannot predicate a texture fetch (measured at +0.03 ms per 4.10 Mpx frame), and the
    /// no-backdrop path is supposed to cost what it cost before 037. `present_fragment` is 025's
    /// fragment; `present_fragment_backdrop` is the one that reads `backdrop`.
    static func fragmentName(_ backdrop: MTLTexture?) -> String {
        backdrop == nil ? "present_fragment" : "present_fragment_backdrop"
    }

    /// Fills every field of `PresentParams`. One place, so `present` and `render` cannot disagree —
    /// and so a test can pin the values without a drawable.
    ///
    /// `d` is the one field whose *source* depends on the fragment that will read it, because the two
    /// fragments ask different questions:
    ///
    /// - with a **backdrop** the feather ramps against the main window's rect on the canvas, which is
    ///   the window (`-u0/du`, `1/du`) — 037's meaning, untouched;
    /// - without one, `d` is where the **photograph** is (`pictureRect`, 054), and the fragment paints
    ///   `#0F0F0F` outside it. No picture rect means `(0, 0, 1, 1)` — "the picture is the whole
    ///   canvas", no matte — which is what every pre-054 caller gets, and why the pinned 025 hashes
    ///   (identity, shrink, zoom) do not move.
    static func makeParams(linearize: Bool, window: PresentWindow,
                           backdrop: MTLTexture?, backdropWindow: PresentWindow,
                           canvas: ImageSize, pictureRect: ImageRect? = nil) -> PresentParams {
        // A degenerate window has no rectangle to feather against; treat it as "no backdrop" rather
        // than dividing by zero and blending against garbage.
        let usable = backdrop != nil && window.du > 1e-9 && window.dv > 1e-9
        let du = Double(usable ? window.du : 1), dv = Double(usable ? window.dv : 1)
        let u0 = Double(usable ? window.u0 : 0), v0 = Double(usable ? window.v0 : 0)
        // uv = u0 + p·du, so the picture occupies p ∈ [-u0/du, (1-u0)/du] — the rect in
        // canvas-normalised coordinates that the fragment feathers against.
        let windowRect = SIMD4<Float>(Float(-u0 / du), Float(-v0 / dv), Float(1 / du), Float(1 / dv))
        // 054: the photograph's own rect, normalised by the canvas the fragment works in. Only the
        // no-backdrop fragment reads it (the backdrop path is the picture everywhere), so a backdrop
        // request keeps 037's window rect and cannot be pulled off its feather by this argument.
        let picture: SIMD4<Float>
        if let pictureRect, !pictureRect.isEmpty, canvas.width > 0, canvas.height > 0 {
            let w = Float(canvas.width), h = Float(canvas.height)
            picture = SIMD4(Float(pictureRect.x) / w, Float(pictureRect.y) / h,
                            Float(pictureRect.width) / w, Float(pictureRect.height) / h)
        } else {
            picture = SIMD4(0, 0, 1, 1)
        }
        let rect = usable ? windowRect : picture
        let featherPixels = Self.backdropFeatherPixels
        let feather = SIMD4<Float>(Float(featherPixels / Double(canvas.width)),
                                   Float(featherPixels / Double(canvas.height)),
                                   usable ? 1 : 0, 0)
        return PresentParams(a: SIMD4(linearize ? 1 : 0, 0, 0, 0),
                             b: SIMD4(window.u0, window.v0, window.du, window.dv),
                             c: SIMD4(backdropWindow.u0, backdropWindow.v0,
                                      backdropWindow.du, backdropWindow.dv),
                             d: rect, e: feather)
    }

    /// The CPU side of the struct both sides must agree on.
    ///
    /// `PresentParams` is handed to the GPU as raw bytes (`setVertexBytes`/`setFragmentBytes`), so the
    /// Swift layout and the `present.metal` declaration are one contract with no compiler check
    /// between them — and this project has already read a stale parameter silently once. Five
    /// `float4`s, 16 bytes each, stride 80; `BackdropPresenterTests` parses `present.metal` and pins
    /// both sides against these numbers.
    struct PresentParams {
        /// linearize, pad, pad, pad
        var a: SIMD4<Float>
        /// The main frame's sampled window: `xy` = origin, `zw` = size, normalised texture
        /// coordinates (values outside `[0, 1]` on a shrink are what `clamp_to_edge` fills from).
        var b: SIMD4<Float>
        /// The backdrop's sampled window, same encoding. Only read when `e.z != 0`.
        var c: SIMD4<Float>
        /// The picture's rectangle **on the canvas**, normalised: `xy` = origin, `zw` = size.
        /// Read by `present_fragment` (054: the matte is painted outside it) and by the backdrop
        /// fragment's feather (037: the main window's rect). See `makeParams` for which one it holds.
        var d: SIMD4<Float>
        /// `xy` = the feather width per axis (canvas-normalised, measured inside the rect),
        /// `z` = has backdrop.
        var e: SIMD4<Float>
    }
}
