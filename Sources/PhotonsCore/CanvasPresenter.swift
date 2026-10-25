import Foundation
import Metal
import QuartzCore
import CoreGraphics

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
    /// A layer that refuses a 16-bit drawable (`nextDrawable()` returning nil) falls back to the
    /// 8-bit sRGB path **once**, and keeps that choice: silently retrying every frame would halve the
    /// frame rate on exactly the machines where it failed.
    @discardableResult
    public func present(_ texture: MTLTexture, in layer: CAMetalLayer, wantsEDR: Bool = false,
                        onComplete: (() -> Void)? = nil) -> Bool {
        let size = CGSize(width: texture.width, height: texture.height)
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
            var params = PresentParams(a: SIMD4(storage == .linear16 ? 1 : 0, 0, 0, 0))
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentTexture(texture, index: 0)
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

    private struct PresentParams {
        var a: SIMD4<Float>   // linearize, pad, pad, pad
    }
}
