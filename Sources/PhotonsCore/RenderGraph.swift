import Foundation
import Metal
import simd
import CryptoKit

// MARK: - inputs / outputs

public struct RenderInput: Sendable {
    public let image: LinearImage
    /// Identity of the decoded buffer (the `DecodeCacheKey.digest`, not a pixel hash — hashing 60 MP
    /// on every render would cost more than the render itself).
    public let identity: String

    public init(image: LinearImage, identity: String) {
        self.image = image
        self.identity = identity
    }
}

public struct RenderOptions: Sendable {
    /// Output canvas. `nil` = the content size (export). A viewport passes its own size and the
    /// photograph is letterboxed inside it, which is what the screen actually shows.
    public var canvas: ImageSize?
    /// Output pixels relative to crop pixels. 1 = 1:1, 0.25 = quarter-size preview.
    public var scale: Double
    public var display: DisplayOptions
    /// Stage reuse. Off for benchmarks (otherwise iteration 2 measures a cache hit, not a frame).
    public var useCache: Bool
    /// Copy the result back to the CPU. Off for the on-screen path, where the cost is a real
    /// regression: 2560×1600 rgba16Float is 32 MB per frame.
    public var wantsPixels: Bool

    public init(canvas: ImageSize? = nil,
                scale: Double = 1,
                display: DisplayOptions = DisplayOptions(),
                useCache: Bool = true,
                wantsPixels: Bool = true) {
        self.canvas = canvas
        self.scale = scale
        self.display = display
        self.useCache = useCache
        self.wantsPixels = wantsPixels
    }
}

/// Display-encoded pixels (0…1, sRGB transfer already applied) plus the primaries they are in.
public struct DisplayImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [Float16]
    public let primaries: OutputPrimaries
    public let bitDepth: Int

    public init(width: Int, height: Int, rgba: [Float16], primaries: OutputPrimaries, bitDepth: Int) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.primaries = primaries
        self.bitDepth = bitDepth
    }

    public var size: ImageSize { ImageSize(width: width, height: height) }

    public func sha256() -> String {
        var hasher = SHA256()
        rgba.withUnsafeBytes { raw in
            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: raw.count))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public final class RenderResult {
    public let canvas: ImageSize
    public let content: ImageSize
    public let keys: StageKeys
    public let trace: RenderTrace
    /// Present when `RenderOptions.wantsPixels` was set.
    public let display: DisplayImage?
    /// Present when the caller asked for the GPU texture instead of pixels (the on-screen path).
    /// Hand it back with `RenderGraph.recycle(output:)` or the pool will not get it back.
    public let output: MTLTexture?

    init(canvas: ImageSize, content: ImageSize, keys: StageKeys, trace: RenderTrace,
         display: DisplayImage?, output: MTLTexture?) {
        self.canvas = canvas
        self.content = content
        self.keys = keys
        self.trace = trace
        self.display = display
        self.output = output
    }
}

// MARK: - uniform blocks (must mirror the .metal structs byte for byte)

private struct S0Params {
    var a: SIMD4<Float>   // canvasSize.xy, contentOrigin.xy
    var b: SIMD4<Float>   // contentSize.xy, srcSize.xy
    var c: SIMD4<Float>   // crop rect
    var d: SIMD4<Float>   // cos, sin, flipH, flipV
    var e: SIMD4<Float>   // identity
}

private struct S1Params {
    var a: SIMD4<Float>   // gain, wbR, wbG, wbB
    var b: SIMD4<Float>   // recovery, identity
}

private struct S2Params {
    var a: SIMD4<Float>   // blacks, whites, contrast, pivot
    var b: SIMD4<Float>   // highlights, shadows, identity
}

private struct CurveParams {
    var a: SIMD4<Float>   // identity, tableSize
}

private struct ColorParams {
    var a: SIMD4<Float>   // vibrance, saturation, identity
}

private struct VignetteParams {
    var a: SIMD4<Float>   // amount, midpoint, feather, roundness
    var b: SIMD4<Float>   // contentWidth, contentHeight, originX, originY
    var c: SIMD4<Float>   // identity
}

private struct DisplayParams {
    var m: simd_float4x4
    var a: SIMD4<Float>   // identityMatrix
}

extension ColorGroup {
    /// Lightroom's eight band centres, in degrees on the HSL colour wheel.
    public static let bandCentresDegrees: [Double] = [0, 30, 60, 120, 180, 240, 285, 315]
}

// MARK: - graph

/// The editing graph: five stages, seven GPU passes, one code path.
///
/// Thumbnail, preview and export all come through here and differ only by `scale` (and the canvas
/// for a viewport). Every stage boundary is a cache key, so a slider that only touches S3 cannot
/// re-run S1 (docs/architecture-decisions.md D5/D6/D12).
public final class RenderGraph {
    public let deviceName: String
    /// Decoded source dimensions.
    public let sourceSize: ImageSize

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let kernels: KernelLibrary
    private let input: RenderInput
    private let sourceTexture: MTLTexture
    private let pool: TexturePool
    private let cacheBudgetBytes: Int

    private struct CacheEntry {
        let key: String
        let texture: MTLTexture
    }

    private var cache: [RenderStage: CacheEntry] = [:]
    private var cacheOrder: [RenderStage] = []
    private var cacheBytes = 0

    private var lutBuffers: [String: (buffer: MTLBuffer, isIdentity: Bool)] = [:]
    private var bandBuffers: [String: MTLBuffer] = [:]

    public init(input: RenderInput, cacheBudgetBytes: Int = 1_500_000_000) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.noMetalDevice }
        self.device = device
        self.queue = queue
        self.deviceName = device.name
        self.kernels = KernelLibrary(device: device)
        self.input = input
        self.cacheBudgetBytes = cacheBudgetBytes
        self.pool = TexturePool(device: device)
        self.sourceSize = ImageSize(width: input.image.width, height: input.image.height)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: input.image.width,
                                                            height: input.image.height,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw RenderError.allocationFailed(sourceSize.keyString)
        }
        input.image.rgba.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, input.image.width, input.image.height),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: input.image.width * 8)
        }
        self.sourceTexture = tex
    }

    deinit {
        // Nothing to tear down explicitly: Metal objects are ARC-managed.
    }

    // MARK: plan

    private struct Plan {
        let canvas: ImageSize
        let content: ImageSize
        let origin: SIMD2<Float>
        let crop: NormalizedRect
        let keys: StageKeys
    }

    private func plan(_ edit: EditModel, _ options: RenderOptions) -> Plan {
        let crop = edit.geometry.crop.clamped()
        let cropPixels = ImageSize(width: Int((Double(sourceSize.width) * crop.width).rounded()),
                                   height: Int((Double(sourceSize.height) * crop.height).rounded()))
        let scale = max(0.01, options.scale)
        let requested = ImageSize(width: Int((Double(cropPixels.width) * scale).rounded()),
                                  height: Int((Double(cropPixels.height) * scale).rounded()))
        let canvas = options.canvas ?? requested
        let content = canvas == requested ? requested : ImageSize.fit(requested, in: canvas)
        let origin = SIMD2<Float>(Float((canvas.width - content.width) / 2),
                                  Float((canvas.height - content.height) / 2))

        let geoKey = KeyBuilder("photons-render-v1")
            .add(input.identity)
            .add(sourceSize)
            .add(canvas)
            .add(content)
            .add(edit.keyMaterial(.geometry))
            .digest()

        let linKey = KeyBuilder(geoKey).add(edit.keyMaterial(.sceneLinear)).digest()
        let preNRKey = KeyBuilder(linKey).add(edit.keyMaterial(.toneMap)).digest()
        let curveKey = KeyBuilder(preNRKey).add(edit.keyMaterial(.curve)).digest()
        let colorKey = KeyBuilder(curveKey).add(edit.keyMaterial(.color)).digest()
        let vignetteKey = KeyBuilder(colorKey).add(edit.keyMaterial(.vignette)).digest()
        let displayKey = KeyBuilder(vignetteKey)
            .add(options.display.keyString)
            .add(canvas)
            .digest()

        let keys = StageKeys(inputIdentity: input.identity,
                             geometry: geoKey,
                             sceneLinear: linKey,
                             toneMap: preNRKey,
                             curve: curveKey,
                             color: colorKey,
                             vignette: vignetteKey,
                             display: displayKey)
        return Plan(canvas: canvas, content: content, origin: origin, crop: crop, keys: keys)
    }

    // MARK: render

    public func render(_ edit: EditModel, options: RenderOptions = RenderOptions()) throws -> RenderResult {
        let plan = plan(edit, options)
        var trace = RenderTrace()

        guard let cb = queue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }

        var current = sourceTexture
        var transient: [MTLTexture] = []
        var finish: MTLTexture?

        for stage in RenderStage.allCases {
            let key = plan.keys.key(for: stage)

            // S4 is never cached: its output is handed to the caller (or read back), so it must not
            // be a texture the pool or the cache could later reuse.
            if stage != .display, options.useCache, let hit = cache[stage], hit.key == key {
                trace.record(stage, executed: false)
                current = hit.texture
                continue
            }

            let out = try pool.obtain(plan.canvas)
            try encode(stage, cb: cb, into: out, from: current, edit: edit, plan: plan, options: options)
            trace.record(stage, executed: true)

            if options.useCache && stage != .display {
                insertCache(stage, key: key, texture: out)
            } else if stage != .display {
                transient.append(out)
            }
            current = out
            if stage == .display { finish = out }
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        cb.commit()
        cb.waitUntilCompleted()
        let wall = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if let err = cb.error {
            throw RenderError.executeFailed(err.localizedDescription)
        }
        let gpu = (cb.gpuEndTime > 0 && cb.gpuEndTime > cb.gpuStartTime)
            ? (cb.gpuEndTime - cb.gpuStartTime) * 1000
            : wall
        trace.gpuMilliseconds = gpu

        for t in transient { pool.recycle(t) }

        guard let finalTexture = finish else { throw RenderError.executeFailed("no display output") }

        if options.wantsPixels {
            let pixels = readback(finalTexture, primaries: options.display.primaries, bitDepth: options.display.bitDepth)
            pool.recycle(finalTexture)
            return RenderResult(canvas: plan.canvas, content: plan.content, keys: plan.keys,
                                trace: trace, display: pixels, output: nil)
        }
        return RenderResult(canvas: plan.canvas, content: plan.content, keys: plan.keys,
                            trace: trace, display: nil, output: finalTexture)
    }

    /// Return a texture handed out by `render(..., wantsPixels: false)`.
    public func recycle(output: MTLTexture) {
        pool.recycle(output)
    }

    public func invalidateCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
    }

    private func insertCache(_ stage: RenderStage, key: String, texture: MTLTexture) {
        if let old = cache[stage] {
            cacheBytes -= Int(old.texture.width * old.texture.height * 8)
            cacheOrder.removeAll { $0 == stage }
            pool.recycle(old.texture)
        }
        cache[stage] = CacheEntry(key: key, texture: texture)
        cacheOrder.append(stage)
        cacheBytes += Int(texture.width * texture.height * 8)
        while cacheBytes > cacheBudgetBytes, cacheOrder.count > 1 {
            let victim = cacheOrder.removeFirst()
            if let entry = cache.removeValue(forKey: victim) {
                cacheBytes -= Int(entry.texture.width * entry.texture.height * 8)
                pool.recycle(entry.texture)
            }
        }
    }

    private func readback(_ texture: MTLTexture, primaries: OutputPrimaries, bitDepth: Int) -> DisplayImage {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!,
                             bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0)
        }
        let rgba = raw.map { Float16(bitPattern: $0) }
        return DisplayImage(width: w, height: h, rgba: rgba, primaries: primaries, bitDepth: bitDepth)
    }

    // MARK: encoding

    private func encoder(_ cb: MTLCommandBuffer, _ pipeline: MTLComputePipelineState,
                         in src: MTLTexture, out dst: MTLTexture) throws -> MTLComputeCommandEncoder {
        guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        return enc
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, _ size: ImageSize) {
        let tw = pipeline.threadExecutionWidth
        let th = max(1, pipeline.maxTotalThreadsPerThreadgroup / tw)
        let threads = MTLSize(width: tw, height: th, depth: 1)
        let groups = MTLSize(width: (size.width + tw - 1) / tw,
                             height: (size.height + th - 1) / th,
                             depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }

    private func encode(_ stage: RenderStage, cb: MTLCommandBuffer, into out: MTLTexture,
                        from src: MTLTexture, edit: EditModel, plan: Plan,
                        options: RenderOptions) throws {
        switch stage {
        case .geometry:
            let p = try kernels.pipeline(file: "s0_geometry", function: "s0_geometry")
            let identity = plan.crop == .full
                && edit.geometry.rotationDegrees == 0
                && !edit.geometry.flipHorizontal && !edit.geometry.flipVertical
                && plan.content == sourceSize && plan.canvas == sourceSize
            var params = S0Params(
                a: SIMD4(Float(plan.canvas.width), Float(plan.canvas.height), plan.origin.x, plan.origin.y),
                b: SIMD4(Float(plan.content.width), Float(plan.content.height),
                         Float(sourceSize.width), Float(sourceSize.height)),
                c: SIMD4(Float(plan.crop.x), Float(plan.crop.y), Float(plan.crop.width), Float(plan.crop.height)),
                d: SIMD4(costheta(edit), sintheta(edit),
                         edit.geometry.flipHorizontal ? 1 : 0, edit.geometry.flipVertical ? 1 : 0),
                e: SIMD4(identity ? 1 : 0, 0, 0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<S0Params>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .sceneLinear:
            let p = try kernels.pipeline(file: "s1_scene_linear", function: "s1_scene_linear")
            let wb = edit.light.whiteBalanceGains
            let identity = edit.light.isIdentity
            var params = S1Params(
                a: SIMD4(edit.light.exposureGain, wb.r, wb.g, wb.b),
                b: SIMD4(Float(min(max(edit.light.highlightRecovery, 0), 1)), identity ? 1 : 0, 0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<S1Params>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .toneMap:
            let p = try kernels.pipeline(file: "s2_tone_map", function: "s2_tone_map")
            let identity = edit.light.contrast == 0 && edit.light.highlights == 0
                && edit.light.shadows == 0 && edit.light.whites == 0 && edit.light.blacks == 0
            var params = S2Params(
                a: SIMD4(Float(edit.light.blacks), Float(edit.light.whites),
                         Float(edit.light.contrast), 0.18),
                b: SIMD4(Float(edit.light.highlights), Float(edit.light.shadows), identity ? 1 : 0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<S2Params>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .curve:
            let p = try kernels.pipeline(file: "s3_curve", function: "s3_curve")
            let lut = try lutBuffer(for: edit.curve)
            var params = CurveParams(a: SIMD4(lut.isIdentity ? 1 : 0, Float(CurveLUT.size), 0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<CurveParams>.stride, index: 0)
            enc.setBuffer(lut.buffer, offset: 0, index: 1)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .color:
            let p = try kernels.pipeline(file: "s3_color", function: "s3_color")
            let bands = try bandBuffer(for: edit.color)
            var params = ColorParams(a: SIMD4(Float(edit.color.vibrance), Float(edit.color.saturation),
                                              edit.color.isIdentity ? 1 : 0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
            enc.setBuffer(bands.buffer, offset: 0, index: 1)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .vignette:
            let p = try kernels.pipeline(file: "s3_vignette", function: "s3_vignette")
            let identity = edit.effects.vignetteAmount == 0
            var params = VignetteParams(
                a: SIMD4(Float(edit.effects.vignetteAmount), Float(edit.effects.vignetteMidpoint),
                         Float(edit.effects.vignetteFeather), Float(edit.effects.vignetteRoundness)),
                b: SIMD4(Float(plan.content.width), Float(plan.content.height), plan.origin.x, plan.origin.y),
                c: SIMD4(identity ? 1 : 0, 0, 0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<VignetteParams>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .display:
            let p = try kernels.pipeline(file: "s4_display", function: "s4_display")
            let primaries = options.display.primaries
            let matrix = RenderGraph.primariesMatrix(from: .sRGB, to: primaries)
            var params = DisplayParams(m: matrix,
                                       a: SIMD4(primaries == .sRGB ? 1 : 0,
                                                Float(options.display.headroom), 0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()
        }
    }

    private func costheta(_ edit: EditModel) -> Float {
        Float(cos(edit.geometry.rotationDegrees * .pi / 180))
    }

    private func sintheta(_ edit: EditModel) -> Float {
        Float(sin(edit.geometry.rotationDegrees * .pi / 180))
    }

    // MARK: resource caches

    private struct LUTResource {
        let buffer: MTLBuffer
        let isIdentity: Bool
    }

    private func lutBuffer(for curve: CurveGroup) throws -> LUTResource {
        let key = curve.keyString
        if let hit = lutBuffers[key] {
            return LUTResource(buffer: hit.buffer, isIdentity: hit.isIdentity)
        }
        let tables = CurveLUT.build(curve)
        guard let b = device.makeBuffer(bytes: tables,
                                        length: tables.count * MemoryLayout<Float>.size,
                                        options: .storageModeShared) else {
            throw RenderError.allocationFailed("curve LUT")
        }
        let identity = CurveLUT.tablesAreIdentity(tables)
        lutBuffers[key] = (b, identity)
        return LUTResource(buffer: b, isIdentity: identity)
    }

    private func bandBuffer(for color: ColorGroup) throws -> LUTResource {
        let key = color.keyString
        if let b = bandBuffers[key] {
            return LUTResource(buffer: b, isIdentity: color.isIdentity)
        }
        var words: [SIMD4<Float>] = []
        for (i, band) in color.bands.prefix(ColorGroup.bandCount).enumerated() {
            let centre = ColorGroup.bandCentresDegrees[min(i, ColorGroup.bandCentresDegrees.count - 1)]
            words.append(SIMD4(Float(band.hue), Float(band.saturation), Float(band.luminance), Float(centre)))
        }
        guard let b = device.makeBuffer(bytes: words,
                                        length: MemoryLayout<SIMD4<Float>>.stride * words.count,
                                        options: .storageModeShared) else {
            throw RenderError.allocationFailed("HSL bands")
        }
        bandBuffers[key] = b
        return LUTResource(buffer: b, isIdentity: color.isIdentity)
    }

    // MARK: primaries

    /// linear sRGB → linear output primaries. Derived from the sRGB → XYZ (D65) and XYZ → P3
    /// matrices; identical to the constants used by Apple's own P3 conversions.
    static func primariesMatrix(from: OutputPrimaries, to: OutputPrimaries) -> simd_float4x4 {
        let identity = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        guard from == .sRGB, to == .displayP3 else { return identity }
        return simd_float4x4(columns: (SIMD4(0.8224621, 0.0331941, 0.0170827, 0),
                                       SIMD4(0.1775380, 0.9668058, 0.0723974, 0),
                                       SIMD4(0.0000000, 0.0000000, 0.9105199, 0),
                                       SIMD4(0, 0, 0, 1)))
    }
}

// MARK: - texture pool

/// Frame-time work must not pay for `makeTexture`. Textures are recycled per (size) instead, which
/// is what makes a second identical render measurably cheaper than the first.
final class TexturePool {
    private let device: MTLDevice
    private var free: [String: [MTLTexture]] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func obtain(_ size: ImageSize) throws -> MTLTexture {
        let key = size.keyString
        if var list = free[key], let t = list.popLast() {
            free[key] = list
            return t
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                           width: size.width,
                                                           height: size.height,
                                                           mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: desc) else {
            throw RenderError.allocationFailed(key)
        }
        return t
    }

    func recycle(_ texture: MTLTexture) {
        let key = "\(texture.width)x\(texture.height)"
        free[key, default: []].append(texture)
    }
}
