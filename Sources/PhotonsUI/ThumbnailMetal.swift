import AppKit
import CoreGraphics
import CoreImage
import Metal
import QuartzCore

/// 227 — the thumbnail surface is a **CAMetalLayer**, not a CALayer with EDR contents.
///
/// `CALayer` lets macOS tone map HDR contents; on an HDR panel it lifted reference white towards the
/// panel's maximum ("SDR white = screen max brightness"). A `CAMetalLayer` does not tone map: EDR
/// `1.0` is SDR white, values above 1 are rendered as far as the current headroom allows and clipped
/// beyond it. The picture therefore keeps its HDR highlights without moving SDR white.
///
/// One shared device/queue/pipeline; one texture per visible cell (the CPU bitmap stays in the
/// provider's LRU — this texture is the GPU copy for the layer).
final class ThumbnailMetalRenderer {
    static let shared = ThumbnailMetalRenderer()

    let device: MTLDevice?
    let queue: MTLCommandQueue?
    let pipeline: MTLRenderPipelineState?
    let ciContext: CIContext?

    var isAvailable: Bool { pipeline != nil }

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            self.device = nil
            self.queue = nil
            self.pipeline = nil
            self.ciContext = nil
            return
        }
        self.device = device
        self.queue = queue
        self.pipeline = Self.makePipeline(device: device)
        self.ciContext = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
                ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            .workingFormat: CIFormat.RGBAh,
        ])
    }

    private static func makePipeline(device: MTLDevice) -> MTLRenderPipelineState? {
        // Runtime compilation: SwiftPM has no dependable Metal build step, and this is one tiny
        // pass-through shader compiled once per process (the same reason `KernelLibrary` does it).
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct ThumbParams { float4 uv; };
        struct ThumbOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex ThumbOut thumbnail_vertex(uint vid [[vertex_id]]) {
            const float2 pos[4] = { float2(-1.0, -1.0), float2(1.0, -1.0),
                                    float2(-1.0,  1.0), float2(1.0,  1.0) };
            // Texture row 0 is the top row of the CGImage data. Clip-space +1 is the top of the
            // drawable, so top-left reads (0, 0) and bottom-left reads (0, 1).
            const float2 uv[4] = { float2(0.0, 1.0), float2(1.0, 1.0),
                                   float2(0.0, 0.0), float2(1.0, 0.0) };
            ThumbOut out;
            out.position = float4(pos[vid], 0.0, 1.0);
            out.uv = uv[vid];
            return out;
        }

        fragment float4 thumbnail_fragment(ThumbOut in [[stage_in]],
                                           texture2d<float> src [[texture(0)]],
                                           constant ThumbParams &p [[buffer(0)]]) {
            constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
            float2 uv = p.uv.xy + in.uv * p.uv.zw;
            return float4(src.sample(smp, uv).rgb, 1.0);
        }
        """
        guard let library = try? device.makeLibrary(source: source, options: nil),
              let vertex = library.makeFunction(name: "thumbnail_vertex"),
              let fragment = library.makeFunction(name: "thumbnail_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "thumbnail-linear-pass"
        desc.vertexFunction = vertex
        desc.fragmentFunction = fragment
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        return try? device.makeRenderPipelineState(descriptor: desc)
    }
}

/// One cell's `CAMetalLayer` + its GPU copy of the decoded float bitmap.
final class ThumbnailMetalSurface {
    let layer: CAMetalLayer
    private let renderer = ThumbnailMetalRenderer.shared
    private var texture: MTLTexture?
    private var textureSource: CGImage?
    private var image: CGImage?
    private var lastDrawableSize = CGSize.zero
    private var drawGeneration = 0
    private var pendingUnhide: (() -> Void)?
    private(set) var presentCount = 0
    private(set) var lastFailure: String?

    init(layer: CAMetalLayer, cornerRadius: CGFloat) {
        self.layer = layer
        layer.device = renderer.device
        layer.pixelFormat = .rgba16Float
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        layer.framebufferOnly = true
        // Transparent at the rounded corners so the card's placeholder gradient stays visible there.
        layer.isOpaque = false
        layer.displaySyncEnabled = false
        layer.masksToBounds = true
        layer.cornerRadius = cornerRadius
        if #available(macOS 26.0, *) {
            layer.preferredDynamicRange = .high
        }
        // EDR 1.0 is reference white; the drawable's values keep that meaning (no tone map).
        layer.wantsExtendedDynamicRangeContent = true
    }

    /// 227 — replace the layer's contents. `onPresented` runs only after the **new** drawable has
    /// reached the compositor, so a recycled cell cannot show the previous photo's frame while the
    /// new one is still in flight.
    func setImage(_ image: CGImage?, onPresented: (() -> Void)? = nil) {
        self.image = image
        texture = nil
        textureSource = nil
        drawGeneration &+= 1
        pendingUnhide = image == nil ? nil : onPresented
        drawIfPossible()
    }

    func layout(size: CGSize, scale: CGFloat) {
        let s = max(1, scale)
        layer.contentsScale = s
        let pixels = CGSize(width: max(1, (size.width * s).rounded()),
                            height: max(1, (size.height * s).rounded()))
        if layer.drawableSize != pixels { layer.drawableSize = pixels }
        drawIfPossible()
    }

    /// Offscreen pass for the orientation/HDR test: same texture, same shader, same pipeline, but
    /// into a readable `rgba16Float` target instead of a drawable. `nil` when Metal is unavailable.
    func renderOffscreen(width: Int, height: Int) -> MTLTexture? {
        guard width > 0, height > 0,
              renderer.isAvailable,
              let device = renderer.device,
              let queue = renderer.queue,
              let pipeline = renderer.pipeline,
              let image else { return nil }
        if texture == nil || textureSource !== image {
            texture = makeTexture(image, device: device)
            textureSource = image
        }
        guard let texture else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let target = device.makeTexture(descriptor: descriptor) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let command = queue.makeCommandBuffer(),
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setViewport(MTLViewport(originX: 0, originY: 0,
                                        width: Double(width), height: Double(height),
                                        znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        var params = aspectFillWindow(image: image,
                                      drawable: CGSize(width: width, height: height))
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        if !device.hasUnifiedMemory, let blit = command.makeBlitCommandEncoder() {
            blit.synchronize(resource: target)
            blit.endEncoding()
        }
        command.commit()
        command.waitUntilCompleted()
        return command.error == nil ? target : nil
    }

    private func drawIfPossible() {
        guard renderer.isAvailable,
              let device = renderer.device,
              let queue = renderer.queue,
              let pipeline = renderer.pipeline,
              let image,
              layer.drawableSize.width >= 1, layer.drawableSize.height >= 1 else { return }

        if texture == nil || textureSource !== image {
            texture = makeTexture(image, device: device)
            textureSource = image
        }
        guard let texture else { lastFailure = "no texture"; return }

        guard let drawable = layer.nextDrawable() else {
            lastFailure = "CAMetalLayer returned no drawable"
            return
        }
        guard let command = queue.makeCommandBuffer() else {
            lastFailure = "no command buffer"
            return
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            lastFailure = "no render encoder"
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        var params = aspectFillWindow(image: image, drawable: layer.drawableSize)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        if let pendingUnhide {
            let generation = drawGeneration
            // Unhide on the drawable's **presented** callback, not on GPU completion: the compositor
            // may still be showing the previous drawable until this one is actually presented.
            drawable.addPresentedHandler { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.drawGeneration == generation else { return }
                    self.pendingUnhide = nil
                    pendingUnhide()
                }
            }
        }
        command.present(drawable)
        command.commit()
        presentCount += 1
        lastFailure = nil
    }

    /// The same crop `contentsGravity = .resizeAspectFill` used to apply: the image is already
    /// decoded at the cell's pixel size, so this is normally the unit rectangle.
    private func aspectFillWindow(image: CGImage, drawable: CGSize) -> SIMD4<Float> {
        let imageAspect = Double(image.width) / Double(max(1, image.height))
        let viewAspect = Double(drawable.width) / Double(max(1, drawable.height))
        var uv = SIMD4<Float>(0, 0, 1, 1)
        if imageAspect > viewAspect {
            let visible = Float(viewAspect / imageAspect)
            uv.x = (1 - visible) / 2
            uv.z = visible
        } else if imageAspect < viewAspect {
            let visible = Float(imageAspect / viewAspect)
            uv.y = (1 - visible) / 2
            uv.w = visible
        }
        return uv
    }

    private func makeTexture(_ image: CGImage, device: MTLDevice) -> MTLTexture? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        // The HD thumbnail is already half-float RGBA in extended linear P3: upload it directly.
        let directBytes: UnsafePointer<UInt8>? = {
            guard image.bitsPerComponent == 16, image.bitsPerPixel == 64,
                  image.bytesPerRow >= width * 8,
                  let data = image.dataProvider?.data else { return nil }
            return CFDataGetBytePtr(data)
        }()

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        // 313 — `.shaderWrite` is **not** optional for the Core Image branch: `CIContext.render(_:to:)`
        // runs its kernels through Metal *compute*, and a texture that only declares `.shaderRead` is
        // silently left untouched — no error, no assert, an all-zero texture. Nothing noticed while
        // every payload was the half-float bitmap below (a `replace` upload needs `.shaderRead`
        // alone); 308 moved the grid to an 8-bit PQ JPEG, every cell took the Core Image branch, and
        // the whole grid and filmstrip went black.
        descriptor.usage = directBytes == nil ? [.shaderRead, .shaderWrite, .renderTarget]
                                              : .shaderRead
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        if let bytes = directBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0, withBytes: bytes, bytesPerRow: image.bytesPerRow)
            return texture
        }

        // Legacy 8-bit JPEG (or an unexpected layout): let Core Image convert and upload once.
        guard let context = renderer.ciContext else { return nil }
        let ci = CIImage(cgImage: image)
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else { return nil }
        // 316 — **the second time this convention bit us** (the first is `ThumbnailHDRDecoder.makeCGImage`,
        // 241). The two payloads are written into the *same* texture, which the shader samples with
        // texture row 0 at the top of the drawable:
        //
        //   · `texture.replace` copies the `CGImage` bytes verbatim ⇒ row 0 = image top. Upright.
        //   · `CIContext.render(_:to: MTLTexture)` writes the image with its **bottom** row at texture
        //     row 0 (Core Image is y-up, a texture's row 0 is the top). Uploaded as-is the cell shows
        //     the picture upside down — invisible until 313 gave this branch `.shaderWrite` and it
        //     stopped being all-black (316 measured: top band 0.021, bottom band 1.501).
        //
        // So the CI branch flips its own image before the render, nothing else: the alternative
        // ("render into an `RGBAh` CGImage, then `replace`") would unify the two paths but costs an
        // extra full-size CPU round trip (~20 MB at 1920×1278) on every cell. A CIImage transform is a
        // coordinate change the render fuses into its sampling, so it is the cheap side of the tie.
        // If a third upload path is ever added, it must be checked against `ThumbnailPQOrientationTests`,
        // which measures the texture's top/bottom bands for both families.
        let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .concatenating(CGAffineTransform(translationX: 0, y: CGFloat(height))))
        context.render(flipped, to: texture, commandBuffer: nil,
                       bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: space)
        return texture
    }
}
