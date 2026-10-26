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
    /// A layer that refuses a 16-bit drawable (`nextDrawable()` returning nil) falls back to the
    /// 8-bit sRGB path **once**, and keeps that choice: silently retrying every frame would halve the
    /// frame rate on exactly the machines where it failed.
    @discardableResult
    public func present(_ texture: MTLTexture, in layer: CAMetalLayer, wantsEDR: Bool = false,
                        drawableSize: ImageSize? = nil, window: PresentWindow = .whole,
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
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            lastFailure = "no render encoder"
            return false
        }

        do {
            let pipeline = try kernels.renderPipeline(file: "present", vertex: "present_vertex",
                                                      fragment: "present_fragment",
                                                      pixelFormat: drawable.texture.pixelFormat)
            var params = PresentParams(a: SIMD4(storage == .linear16 ? 1 : 0, 0, 0, 0),
                                       b: SIMD4(window.u0, window.v0, window.du, window.dv))
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
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
    @discardableResult
    public func render(_ texture: MTLTexture, window: PresentWindow = .whole,
                       into target: MTLTexture, linearize: Bool? = nil) -> Bool {
        guard let cb = queue.makeCommandBuffer() else {
            lastFailure = "no command buffer"
            return false
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            lastFailure = "no render encoder"
            return false
        }
        do {
            let pipeline = try kernels.renderPipeline(file: "present", vertex: "present_vertex",
                                                      fragment: "present_fragment",
                                                      pixelFormat: target.pixelFormat)
            let linear = linearize ?? (target.pixelFormat == .rgba16Float)
            var params = PresentParams(a: SIMD4(linear ? 1 : 0, 0, 0, 0),
                                       b: SIMD4(window.u0, window.v0, window.du, window.dv))
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
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

    private struct PresentParams {
        var a: SIMD4<Float>   // linearize, pad, pad, pad
        /// The sampled window: `xy` = origin, `zw` = size, both in normalised texture coordinates.
        var b: SIMD4<Float>
    }
}
