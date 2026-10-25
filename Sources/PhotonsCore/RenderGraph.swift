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
    /// Patch-level recomputation of the local stage (005d, §3.4).
    ///
    /// `.off` is the 005c behaviour (one full-canvas dispatch) and is what the recorded goldens were
    /// made with; `.auto` tiles when the mask bounds cover less than half the canvas. The two must
    /// produce the *same bytes* — `MaskTests.testTiledLocalStageIsByteIdenticalToFullFrame` hashes
    /// both — so this is a cost knob, never a quality knob.
    public var maskTiling: MaskTiling

    public init(canvas: ImageSize? = nil,
                scale: Double = 1,
                display: DisplayOptions = DisplayOptions(),
                useCache: Bool = true,
                wantsPixels: Bool = true,
                maskTiling: MaskTiling = .auto) {
        self.canvas = canvas
        self.scale = scale
        self.display = display
        self.useCache = useCache
        self.wantsPixels = wantsPixels
        self.maskTiling = maskTiling
    }
}

/// How the local stage is dispatched (docs/tasks/005-masks.md §3.4 step 3).
///
/// The three cases exist because the two dispatches have different economics, and the measurement
/// (see the cost note in `RenderGraph`) is the reason:
///
///   · A **cold** tiled pass has to copy the source into its destination first — the `.load` of
///     §3.4 — and that copy of a full 4.1 Mpx rgba16 frame costs about what the pass it replaces
///     costs. So `.auto` does not tile a cold frame; `.tiles` does, and exists so a test can prove
///     the two are byte-identical.
///   · An **incremental** pass writes into the texture the previous frame produced, so the `.load` is
///     already true and the saving is real (measured: 2.46 ms → 2.34 ms on a slider drag, where most
///     of the frame is the downstream stages the drag dirties anyway).
public enum MaskTiling: String, Sendable, Codable, CaseIterable {
    /// One dispatch over the whole canvas — the 005c path, and the basis of the recorded goldens.
    case off
    /// Update the cached local texture in place inside the changed masks' tiles; cold frames take the
    /// full pass. This is the default because it is the only mode that cannot be slower.
    case auto
    /// Tile every dispatch, cold frames included (over a fresh texture, with the source copied in
    /// first). Byte-identical to `.off`; the mode the tiling tests use.
    case tiles
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
    /// 005d: what the mask stages actually did — the kernels they ran and the tile plan they
    /// dispatched. `nil` for a document without masks (the stages do not exist then).
    public let maskReport: MaskStageReport?

    init(canvas: ImageSize, content: ImageSize, keys: StageKeys, trace: RenderTrace,
         display: DisplayImage?, output: MTLTexture?, maskReport: MaskStageReport? = nil) {
        self.canvas = canvas
        self.content = content
        self.keys = keys
        self.trace = trace
        self.display = display
        self.output = output
        self.maskReport = maskReport
    }
}

/// 005d's receipts: the atlas kernels in execution order and the region the local stage dispatched.
/// A test can (and does) assert on this instead of on a stopwatch, so "the tile path really ran and it
/// really covered less than the frame" is a fact rather than an impression.
public struct MaskStageReport: Sendable {
    /// Atlas kernel functions, in order (`s1_5_mask_atlas`, `s1_7_mask_blur_h`, …).
    public var atlasPasses: [String] = []
    /// Masks with a non-zero feather (a blur pass exists because of them).
    public var featherMaskCount: Int = 0
    /// Masks with `refine > 0`.
    public var refineMaskCount: Int = 0
    /// The neighbourhood the atlas declares: `featherRadius + guidedRadius`.
    public var atlasDependency: TileDependency = .pointwise
    /// Per-mask canvas bounds, halo included.
    public var bounds: [String: MaskRect] = [:]
    /// The local stage's plan: tiles, pixels and the dependency that justifies it.
    public var localPlan: TilePlan = .fullFrame(ImageSize(width: 1, height: 1))
    /// The tile lattice the plan used.
    public var grid: TileGrid = TileGrid()

    public init() {}

    /// Total pixels the S1.6 pass wrote.
    public var localPixelCount: Int { localPlan.pixelCount }
    public var localPixelFraction: Double { localPlan.fraction }
}

// MARK: - mask atlas readback

/// The S1.5 output, copied back to the CPU: one slice per enabled mask, in id order.
///
/// This exists for verification (`photonsctl maskdump`, the 005b acceptance tests) and for the
/// `showMask` overlay, which reads the same buffer instead of re-evaluating the predicate a second
/// way (docs/tasks/005-masks.md §3.1).
public struct MaskAtlasDump: Sendable {
    public let width: Int
    public let height: Int
    /// `Mask.id` per slice, ascending — the order the atlas was built in.
    public let maskIDs: [String]
    /// Slice-major rows: `slices[slice][y * width + x]`, coverage in 0…1.
    public let slices: [[Float]]

    public init(width: Int, height: Int, maskIDs: [String], slices: [[Float]]) {
        self.width = width
        self.height = height
        self.maskIDs = maskIDs
        self.slices = slices
    }

    public func value(slice: Int, x: Int, y: Int) -> Float? {
        guard slices.indices.contains(slice), x >= 0, y >= 0, x < width, y < height else { return nil }
        return slices[slice][y * width + x]
    }

    public func slice(forMask id: String) -> [Float]? {
        guard let i = maskIDs.firstIndex(of: id) else { return nil }
        return slices[i]
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

// MARK: - mask uniforms (mirror of s1_5_mask_atlas.metal / s1_6_local.metal, byte for byte)

private struct MaskAtlasParams {
    var a: SIMD4<Float>   // canvasSize.xy, contentOrigin.xy
    var b: SIMD4<Float>   // contentSize.xy, sourceSize.xy
    var c: SIMD4<Float>   // crop rect
    var d: SIMD4<Float>   // cos, sin, flipH, flipV
    var e: SIMD4<Int32>   // maskCount
}

private struct MaskDescU {
    var meta: SIMD4<Int32>   // firstComponent, componentCount, invert, pad
    var misc: SIMD4<Float>   // opacity
}

private struct MaskShapeDescU {
    var meta: SIMD4<Int32>   // kind (0 linear, 1 radial, 2 brush, 3 colour, 4 luma, −1 not evaluated), componentInvert, op, pad
    var p0: SIMD4<Float>     // linear: start.xy end.xy | radial: centre.xy radius.xy
                             // brush: firstStroke, strokeCount | colour: firstSample, count, tol, smooth
                             // luma: low, high, lowFeather, highFeather
    var p1: SIMD4<Float>     // linear: midpoint, feather | radial: cos, sin, feather
}

/// One brush stroke, flattened for the GPU. The point list lives in a separate `float4` array
/// (`x, y, pressure`); the document keeps the same three pieces — points, radius, flow — and never a
/// bitmap (§2).
private struct MaskStrokeDescU {
    var meta: SIMD4<Int32>   // pointFirst, pointCount, closed, pad
    var misc: SIMD4<Float>   // radius (short edge), feather, flow, erase
    var bmin: SIMD4<Float>   // bounding box in normalised source, already grown by the radius
    var bmax: SIMD4<Float>
}

private struct LocalParamsU {
    var a: SIMD4<Int32>   // anyActive, maskCount
}

private struct LocalAdjustU {
    var a: SIMD4<Float>   // gainR, gainG, gainB, amountScale
    var b: SIMD4<Float>   // contrast, highlights, shadows, whites
    var c: SIMD4<Float>   // blacks, hueDegrees, saturation, enabled
}

/// 005d — mirror of `MaskBlurParams` in `s1_7_mask_neighbourhood.metal`.
private struct MaskBlurParams {
    var a: SIMD4<Int32>   // canvasW, canvasH, segment length, sliceCount
}

/// 005d — mirror of `RefineParams` in `s1_7_mask_neighbourhood.metal`.
private struct RefineParams {
    var a: SIMD4<Int32>   // canvasW, canvasH, q, guided radius in the 1/q domain
    var b: SIMD4<Float>   // epsilon, lumaR, lumaG, lumaB
    var c: SIMD4<Float>   // strength, pad, pad, pad
    var d: SIMD4<Int32>   // qW, qH, segment length, pad
}

/// Per-render mask tables, derived from `EditModel.masks` in atlas order. Buffers are cached by the
/// two key materials, so a frame with unchanged masks allocates nothing.
private struct MaskTable {
    let ids: [String]
    let masks: [MaskDescU]
    let shapes: [MaskShapeDescU]
    let adjust: [LocalAdjustU]
    let strokes: [MaskStrokeDescU]
    let points: [SIMD4<Float>]
    let colours: [SIMD4<Float>]
    /// The atlas's declared neighbourhood: `featherRadius + guidedRadius`, per mask, in series.
    let dependency: TileDependency
    let maskBuffer: MTLBuffer
    let shapeBuffer: MTLBuffer
    let adjustBuffer: MTLBuffer
    let strokeBuffer: MTLBuffer
    let pointBuffer: MTLBuffer
    let colourBuffer: MTLBuffer
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

    /// The atlas is a side output, so it lives beside the stage cache instead of in it: one slot,
    /// keyed by `maskAtlasKey`. `ids` is the slice order the atlas was built in.
    private struct AtlasEntry {
        let key: String
        let texture: MTLTexture
        let ids: [String]
    }
    private var atlasCache: AtlasEntry?

    /// §3.4 step 3, the "same key" rule taken literally: the local stage's output is updated **in
    /// place** when the *atlas* key — i.e. the selection, the canvas and the tiling — is unchanged and
    /// only some masks' `applyKey` moved. Then the cached texture already holds the right pixels
    /// everywhere outside the changed masks' bounds, and a `.load` is what the texture already has,
    /// not a full-frame copy that must be paid for first (measured: that copy costs as much as the
    /// compute it saves, so without this the tile path is a pessimisation).
    private struct LocalEntry {
        /// `maskAtlasKey`: the region-level key. Everything that determines *where* coverage is.
        let atlasKey: String
        /// Per-mask `applyKey`, so "which masks moved" is answerable without re-deriving the table.
        let applyKeys: [String: String]
        /// The full local key (tiling suffix included) that produced `texture`.
        let key: String
        let texture: MTLTexture
        /// Bounds per mask, at the time it was written.
        let bounds: [String: MaskRect]
    }
    private var localEntry: LocalEntry?
    /// One reusable array texture (allocation on a size/count change only).
    private var atlasPool: (key: String, texture: MTLTexture)?
    private var maskTables: [String: MaskTable] = [:]

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
        /// Edge-spelled crop, already resolved from `aspectLock` and clamped: what S0 samples.
        let crop: CropRect
        let keys: StageKeys

        /// Seven stages, or nine when masks are active. Driven by the key set, so "does this
        /// document have masks" has exactly one answer on the whole render path.
        var stages: [RenderStage] { keys.pipeline }
    }

    private func plan(_ edit: EditModel, _ options: RenderOptions) -> Plan {
        // The aspect lock and the ±45 straighten limit are resolved here, once: S0 receives a plain
        // normalized rect plus cos/sin, exactly the shape it always had.
        let crop = edit.geometry.renderCrop(source: sourceSize)
        let cropPixels = CropMath.outputSize(crop, in: sourceSize)
        let scale = max(0.01, options.scale)
        let requested = ImageSize(width: Int((Double(cropPixels.width) * scale).rounded()),
                                  height: Int((Double(cropPixels.height) * scale).rounded()))
        let canvas = options.canvas ?? requested
        let content = canvas == requested ? requested : ImageSize.fit(requested, in: canvas)
        let origin = SIMD2<Float>(Float((canvas.width - content.width) / 2),
                                  Float((canvas.height - content.height) / 2))

        let keys = RenderKeyChain.keys(RenderKeyChain.links(identity: input.identity,
                                                            sourceSize: sourceSize,
                                                            canvas: canvas,
                                                            content: content,
                                                            edit: edit,
                                                            display: options.display),
                                       identity: input.identity)
        return Plan(canvas: canvas, content: content, origin: origin, crop: crop, keys: keys)
    }

    // MARK: render

    public func render(_ edit: EditModel, options: RenderOptions = RenderOptions()) throws -> RenderResult {
        let plan = plan(edit, options)
        var trace = RenderTrace()
        let table = try maskTable(for: edit, content: plan.content)
        if table == nil { atlasCache = nil }

        // 005d: the tiling material joins the two mask keys. A local-stage texture computed under a
        // different tile lattice (or with a different declared halo) must never be reused as this
        // frame's output — `TileDependency` is a promise about *pixels*, and a promise belongs in the
        // key, not only in a comment. Off (the 005c path) leaves both keys byte-identical.
        let tilingSuffix = maskTilingSuffix(options: options, table: table)
        var report: MaskStageReport? = table == nil ? nil : MaskStageReport()

        guard let cb = queue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }

        var current = sourceTexture
        var transient: [MTLTexture] = []
        var finish: MTLTexture?

        for stage in plan.stages {
            let key = plan.keys.key(for: stage) + (stage.isMaskStage ? tilingSuffix : "")

            // S1.6 keeps its own slot (like the atlas) because it can be updated **in place**: the
            // same texture, a smaller dispatch. A plain stage-cache entry cannot express that.
            if stage == .localApply {
                guard let table, let atlas = atlasCache else {
                    throw RenderError.executeFailed("local stage without an atlas")
                }
                let atlasKey = plan.keys.key(for: .maskAtlas) + tilingSuffix
                let localKey = plan.keys.key(for: .localApply) + tilingSuffix
                let applyKeys = Dictionary(uniqueKeysWithValues: edit.activeMasks.map { ($0.id, $0.applyKey) })

                // (a) nothing moved: the whole stage is a hit.
                if options.useCache, let e = localEntry, e.key == localKey,
                   e.texture.width == plan.canvas.width, e.texture.height == plan.canvas.height {
                    trace.record(stage, executed: false)
                    if report != nil {
                        report?.localPlan = TilePlan(tiles: [], pixelCount: 0,
                                                     canvasPixelCount: plan.canvas.pixelCount,
                                                     dependency: .pointwise, tiled: false)
                    }
                    current = e.texture
                    continue
                }

                // (b) only some `applyKey`s moved and the selection did not: rewrite just those
                // masks' bounds inside the cached texture. This is the case a slider drag produces
                // hundreds of times per second, and the only one where tiling is a win.
                if options.useCache, options.maskTiling != .off, let e = localEntry,
                   e.atlasKey == atlasKey,
                   e.texture.width == plan.canvas.width, e.texture.height == plan.canvas.height,
                   let incremental = incrementalTilePlan(previous: e, applyKeys: applyKeys,
                                                         edit: edit, plan: plan, options: options) {
                    try encodeLocal(cb: cb, into: e.texture, from: current, atlas: atlas.texture,
                                    table: table, tilePlan: incremental.plan, blitSource: false)
                    trace.record(stage, executed: true)
                    if report != nil { report?.localPlan = incremental.plan }
                    localEntry = LocalEntry(atlasKey: atlasKey, applyKeys: applyKeys, key: localKey,
                                            texture: e.texture, bounds: incremental.bounds)
                    current = e.texture
                    continue
                }

                // (c) cold: a full pass, or a tiled pass over a fresh texture with the source copied
                // in first (the `.load` that makes the untouched pixels right).
                let out = try pool.obtain(plan.canvas)
                let tilePlan = localTilePlan(edit: edit, plan: plan, options: options)
                try encodeLocal(cb: cb, into: out, from: current, atlas: atlas.texture,
                                table: table, tilePlan: tilePlan, blitSource: tilePlan.tiled)
                trace.record(stage, executed: true)
                if report != nil { report?.localPlan = tilePlan }
                if options.useCache {
                    if let old = localEntry, old.texture !== out { pool.recycle(old.texture) }
                    localEntry = LocalEntry(atlasKey: atlasKey, applyKeys: applyKeys, key: localKey,
                                            texture: out, bounds: localBounds(edit: edit, plan: plan))
                } else {
                    transient.append(out)
                }
                current = out
                continue
            }
            // S1.5 writes a side texture (`texture2d_array`, one slice per mask) rather than the
            // pipeline image: it is the predicate every later consumer reads, so it is cached on its
            // own and `current` keeps pointing at S1's output.
            if stage == .maskAtlas {
                if options.useCache, let hit = atlasCache, hit.key == key {
                    trace.record(stage, executed: false)
                    continue
                }
                guard let table else {
                    throw RenderError.executeFailed("mask stage present without a mask table")
                }
                let atlas = try atlasTexture(for: table, size: plan.canvas)
                let stageReport = try encodeAtlas(cb: cb, into: atlas, from: current, table: table,
                                                  plan: plan, edit: edit)
                if report != nil {
                    report?.atlasPasses = stageReport.atlasPasses
                    report?.featherMaskCount = stageReport.featherMaskCount
                    report?.refineMaskCount = stageReport.refineMaskCount
                    report?.atlasDependency = stageReport.atlasDependency
                    report?.bounds = stageReport.bounds
                }
                trace.record(stage, executed: true)
                atlasCache = AtlasEntry(key: key, texture: atlas, ids: table.ids)
                continue
            }

            // S4 is never cached: its output is handed to the caller (or read back), so it must not
            // be a texture the pool or the cache could later reuse.
            if stage != .display, options.useCache, let hit = cache[stage], hit.key == key {
                trace.record(stage, executed: false)
                current = hit.texture
                continue
            }

            let out = try pool.obtain(plan.canvas)
            try encode(stage, cb: cb, into: out, from: current, edit: edit, plan: plan,
                       options: options, table: table, report: &report)
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
                                trace: trace, display: pixels, output: nil, maskReport: report)
        }
        return RenderResult(canvas: plan.canvas, content: plan.content, keys: plan.keys,
                            trace: trace, display: nil, output: finalTexture, maskReport: report)
    }

    /// Return a texture handed out by `render(..., wantsPixels: false)`.
    public func recycle(output: MTLTexture) {
        pool.recycle(output)
    }

    public func invalidateCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
        atlasCache = nil
        localEntry = nil
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
                        options: RenderOptions, table: MaskTable?,
                        report: inout MaskStageReport?) throws {
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
                c: SIMD4(Float(plan.crop.left), Float(plan.crop.top),
                         Float(plan.crop.width), Float(plan.crop.height)),
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

        case .localApply:
            // Handled before the stage loop: it owns a cache slot that can be updated in place.
            throw RenderError.executeFailed("local stage must be encoded by encodeLocal")

        case .maskAtlas:
            // Handled before the stage loop: it writes a side texture, not the pipeline image.
            throw RenderError.executeFailed("mask atlas must be encoded by encodeAtlas")

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

    // S0 and the mask atlas must rotate by the same angle, so both read `straightenDegrees`
    // (the stored value clamped to the ±45 straighten range) instead of the raw field.
    private func costheta(_ edit: EditModel) -> Float {
        Float(cos(edit.geometry.straightenDegrees * .pi / 180))
    }

    private func sintheta(_ edit: EditModel) -> Float {
        Float(sin(edit.geometry.straightenDegrees * .pi / 180))
    }

    // MARK: - masks (S1.5 / S1.6)
    //
    // Cost, measured on this machine (M1 Pro, macOS 27.2, 1500×2731 = 4.10 Mpx canvas, cache off, so
    // every frame is a complete S0→S4 chain — the number `MaskTests.testFrameBudgetWithThreeMasks`
    // prints with `PHOTONS_BENCH=1`):
    //
    //   3 masks, feather 0.15, refine 0            p50 6.42 ms   p95 7.86 ms
    //   3 masks, feather 0.15, refine 0.5          p50 14.02 ms  p95 15.49 ms
    //   slider drag on one of two masks            full pass 2.46 ms → tiled increment 2.34 ms
    //
    // The budget is p95 ≤ 16.7 ms (docs/tasks/005-masks.md §6, 005c item ⑦). The refine case is the
    // expensive one by a wide margin: its reconstruction is a full-resolution pass per mask, and it is
    // only worth having while the atlas is being rebuilt (a selection or S1 change), which is exactly
    // what the numbers above measure.
    //
    // The feather is a running sum, not an O(r) convolution: at radius 273 (feather 1.0) it costs what
    // radius 4 costs, which is why the maximum feather is not a frame-time cliff.

    /// Descriptor tables for the enabled masks, in atlas order. Cached on the two key materials so a
    /// frame that only moves a slider reuses the buffers.
    private func maskTable(for edit: EditModel, content: ImageSize) throws -> MaskTable? {
        let active = edit.activeMasks
        guard !active.isEmpty else { return nil }

        let selection = edit.maskSelectionMaterial
        let apply = edit.maskApplyMaterial
        // The content size is part of the key because the two radii (feather, guided) are pixel
        // lengths derived from it: the same document at thumbnail and at export must produce
        // different descriptors from the same selection key.
        let cacheKey = selection + "##" + apply + "##" + content.keyString
        if let hit = maskTables[cacheKey] { return hit }

        var masks: [MaskDescU] = []
        var shapes: [MaskShapeDescU] = []
        var adjust: [LocalAdjustU] = []
        var strokes: [MaskStrokeDescU] = []
        var points: [SIMD4<Float>] = []
        var colours: [SIMD4<Float>] = []
        var dependency: TileDependency = .pointwise
        for m in active {
            let first = Int32(shapes.count)
            for c in m.components {
                shapes.append(shapeDesc(c, strokes: &strokes, points: &points, colours: &colours))
            }
            // 005d: the atlas's two neighbourhood operators, in canvas pixels (§4.6, `MaskRadius`).
            let featherPx = Float(MaskRadius.featherPixels(m.feather, content: content))
            let guidedPx = Float(MaskRadius.guidedRadiusPixels(m.refine, content: content))
            dependency = dependency.widest(MaskRadius.atlasDependency(of: m, content: content))
            masks.append(MaskDescU(meta: SIMD4(first, Int32(m.components.count), m.invert ? 1 : 0, 0),
                                   misc: SIMD4(Float(min(max(m.opacity, 0), 1)), featherPx,
                                               Float(min(max(m.refine, 0), 1)), guidedPx)))
            adjust.append(adjustDesc(m.adjustments, enabled: m.isEnabled))
        }
        // Metal requires a bound buffer even when the count is zero; one neutral entry keeps the
        // binding valid without inventing a mask.
        if masks.isEmpty { masks.append(MaskDescU(meta: .zero, misc: .zero)) }
        if shapes.isEmpty { shapes.append(MaskShapeDescU(meta: .zero, p0: .zero, p1: .zero)) }
        if adjust.isEmpty { adjust.append(LocalAdjustU(a: SIMD4(1, 1, 1, 0), b: .zero, c: SIMD4(0, 0, 0, 0))) }
        if strokes.isEmpty {
            strokes.append(MaskStrokeDescU(meta: .zero, misc: .zero, bmin: .zero, bmax: .zero))
        }
        if points.isEmpty { points.append(.zero) }
        if colours.isEmpty { colours.append(.zero) }

        let table = MaskTable(ids: active.map(\.id),
                              masks: masks, shapes: shapes, adjust: adjust,
                              strokes: strokes, points: points, colours: colours,
                              dependency: dependency,
                              maskBuffer: try buffer(masks, "mask descs"),
                              shapeBuffer: try buffer(shapes, "mask shapes"),
                              adjustBuffer: try buffer(adjust, "mask adjustments"),
                              strokeBuffer: try buffer(strokes, "mask strokes"),
                              pointBuffer: try buffer(points, "mask brush points"),
                              colourBuffer: try buffer(colours, "mask colour samples"))
        if maskTables.count > 8 { maskTables.removeAll() }
        maskTables[cacheKey] = table
        return table
    }

    /// One component → the GPU's fixed-layout descriptor, appending any variable-length payload
    /// (brush points, colour samples) to the shared side arrays.
    private func shapeDesc(_ c: MaskComponent,
                           strokes: inout [MaskStrokeDescU],
                           points: inout [SIMD4<Float>],
                           colours: inout [SIMD4<Float>]) -> MaskShapeDescU {
        let op: Int32 = c.op == .subtract ? 1 : (c.op == .intersect ? 2 : 0)
        let invert: Int32 = c.invert ? 1 : 0
        let feather = Float(min(max(c.feather, 0), 1))
        switch c.shape {
        case .linearGradient(let g):
            return MaskShapeDescU(meta: SIMD4(0, invert, op, 0),
                                  p0: SIMD4(Float(g.start.x), Float(g.start.y),
                                            Float(g.end.x), Float(g.end.y)),
                                  p1: SIMD4(Float(g.midpoint), feather, 0, 0))
        case .radialGradient(let g):
            // cos/sin are computed in double and handed over as floats so the reference
            // implementation in the tests and the kernel rotate identically.
            let radians = g.angle * .pi / 180
            return MaskShapeDescU(meta: SIMD4(1, invert, op, 0),
                                  p0: SIMD4(Float(g.center.x), Float(g.center.y),
                                            Float(max(g.radius.x, 0)), Float(max(g.radius.y, 0))),
                                  p1: SIMD4(Float(cos(radians)), Float(sin(radians)), feather, 0))
        case .brush(let b):
            let first = Int32(strokes.count)
            let minSide = Double(min(sourceSize.width, sourceSize.height))
            for stroke in b.strokes {
                let r = min(max(stroke.resolvedRadius(fallbackSize: b.size), 0), 1)
                let pointFirst = Int32(points.count)
                // Pressure only scales the radius (§4.1). Absent pressure is a constant 1 so the
                // kernel has no second layout to handle.
                let n = stroke.points.count / 2
                var lo = SIMD4<Float>(Float.infinity, Float.infinity, 0, 0)
                var hi = SIMD4<Float>(-Float.infinity, -Float.infinity, 0, 0)
                for i in 0..<n {
                    let x = Float(stroke.points[i * 2])
                    let y = Float(stroke.points[i * 2 + 1])
                    let p = i < stroke.pressure.count ? max(stroke.pressure[i], 0.02) : 1
                    points.append(SIMD4(x, y, p, 0))
                    lo.x = min(lo.x, x); lo.y = min(lo.y, y)
                    hi.x = max(hi.x, x); hi.y = max(hi.y, y)
                }
                // The bounding box is grown by the radius in *its own* axis units: the radius is a
                // short-edge length, so it covers `r·minSide/W` in x and `r·minSide/H` in y.
                if n > 0 {
                    let rx = Float(r * minSide / Double(max(sourceSize.width, 1)))
                    let ry = Float(r * minSide / Double(max(sourceSize.height, 1)))
                    lo.x -= rx; lo.y -= ry
                    hi.x += rx; hi.y += ry
                } else {
                    lo = .zero
                    hi = .zero
                }
                strokes.append(MaskStrokeDescU(
                    meta: SIMD4(pointFirst, Int32(n), stroke.closed ? 1 : 0, 0),
                    misc: SIMD4(Float(r), Float(min(max(stroke.feather, 0), 0.999)),
                                Float(min(max(stroke.flow, 0), 1)), stroke.erase ? 1 : 0),
                    bmin: lo, bmax: hi))
            }
            return MaskShapeDescU(meta: SIMD4(2, invert, op, 0),
                                  p0: SIMD4(Float(first), Float(b.strokes.count), 0, 0),
                                  p1: SIMD4(feather, 0, 0, 0))
        case .colorRange(let g):
            let first = Int32(colours.count)
            for s in g.metricSamples {
                colours.append(SIMD4(Float(s[0]), Float(s[1]), Float(s[2]), 0))
            }
            return MaskShapeDescU(meta: SIMD4(3, invert, op, 0),
                                  p0: SIMD4(Float(first), Float(g.metricSamples.count),
                                            Float(max(g.tolerance, 0)),
                                            Float(min(max(g.smoothness, 0), 1))),
                                  p1: SIMD4(feather, 0, 0, 0))
        case .luminanceRange(let g):
            // An inverted pair is repaired here, once, so the kernel and every reference agree on
            // the same ordered window (§4.5).
            let o = g.ordered
            return MaskShapeDescU(meta: SIMD4(4, invert, op, 0),
                                  p0: SIMD4(Float(o.low), Float(o.high),
                                            Float(o.lowFeather), Float(o.highFeather)),
                                  p1: SIMD4(feather, 0, 0, 0))
        case .semantic, .unsupported:
            // Not evaluated by this pass: zero coverage, never a guess.
            return MaskShapeDescU(meta: SIMD4(-1, invert, op, 0), p0: .zero, p1: .zero)
        }
    }

    private func adjustDesc(_ a: LocalAdjustments, enabled: Bool) -> LocalAdjustU {
        let gain = a.gain
        let active = enabled && !a.isIdentity
        return LocalAdjustU(
            a: SIMD4(gain.r, gain.g, gain.b, Float(min(max(a.amount, 0), 100) / 100)),
            b: SIMD4(Float(a.contrast), Float(a.highlights), Float(a.shadows), Float(a.whites)),
            c: SIMD4(Float(a.blacks), Float(a.hue), Float(a.saturation), active ? 1 : 0))
    }

    private func buffer<T>(_ values: [T], _ label: String) throws -> MTLBuffer {
        let length = MemoryLayout<T>.stride * values.count
        guard let b = device.makeBuffer(bytes: values, length: length, options: .storageModeShared) else {
            throw RenderError.allocationFailed(label)
        }
        return b
    }

    private func atlasTexture(for table: MaskTable, size: ImageSize) throws -> MTLTexture {
        let key = "\(size.keyString)x\(table.ids.count)"
        if let hit = atlasPool, hit.key == key { return hit.texture }

        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .r16Float
        desc.width = size.width
        desc.height = size.height
        desc.arrayLength = max(1, table.ids.count)
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let t = device.makeTexture(descriptor: desc) else {
            throw RenderError.allocationFailed("mask atlas \(key)")
        }
        atlasPool = (key, t)
        return t
    }

    private func encodeAtlas(cb: MTLCommandBuffer, into atlas: MTLTexture, from src: MTLTexture,
                             table: MaskTable, plan: Plan, edit: EditModel) throws -> MaskStageReport {
        var report = MaskStageReport()
        let count = table.ids.count
        let canvas = plan.canvas

        // 1 — the pointwise coverage of 005b/005c, unchanged: `opacity · combine · invert`.
        let p = try kernels.pipeline(file: "s1_5_mask_atlas", function: "s1_5_mask_atlas")
        var params = MaskAtlasParams(
            a: SIMD4(Float(canvas.width), Float(canvas.height), plan.origin.x, plan.origin.y),
            b: SIMD4(Float(plan.content.width), Float(plan.content.height),
                     Float(sourceSize.width), Float(sourceSize.height)),
            c: SIMD4(Float(plan.crop.left), Float(plan.crop.top),
                         Float(plan.crop.width), Float(plan.crop.height)),
            d: SIMD4(costheta(edit), sintheta(edit),
                     edit.geometry.flipHorizontal ? 1 : 0, edit.geometry.flipVertical ? 1 : 0),
            e: SIMD4(Int32(count), 0, 0, 0))
        guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        enc.setComputePipelineState(p)
        enc.setTexture(src, index: 0)
        enc.setTexture(atlas, index: 1)
        enc.setBytes(&params, length: MemoryLayout<MaskAtlasParams>.stride, index: 0)
        enc.setBuffer(table.maskBuffer, offset: 0, index: 1)
        enc.setBuffer(table.shapeBuffer, offset: 0, index: 2)
        enc.setBuffer(table.strokeBuffer, offset: 0, index: 3)
        enc.setBuffer(table.pointBuffer, offset: 0, index: 4)
        enc.setBuffer(table.colourBuffer, offset: 0, index: 5)
        dispatch(enc, p, canvas)
        enc.endEncoding()
        report.atlasPasses.append("s1_5_mask_atlas")

        // 2 — mask-level feather: a separable box blur, edge-clamped, radius per slice (§3.4/§4.6).
        // Skipped entirely when no mask asks for it, which is what keeps `feather = 0` bit-identical
        // to the 005c output: no pass runs, so nothing can round differently.
        let radii = table.masks.prefix(count).map { max(0, Int($0.misc.y.rounded())) }
        report.featherMaskCount = radii.filter { $0 > 0 }.count
        if report.featherMaskCount > 0 {
            let tmp = try scratch("mask-blur", width: canvas.width, height: canvas.height,
                                  format: .r16Float, arrayLength: count, asArray: true)
            // A segment is at least as long as the window, so the warm-up cost never dominates the
            // sliding sum; 64 px granularity keeps the thread count a multiple of the SIMD width.
            let segment = max(256, ((2 * (radii.max() ?? 0) + 63) / 64) * 64)
            var bp = MaskBlurParams(a: SIMD4(Int32(canvas.width), Int32(canvas.height),
                                             Int32(segment), Int32(count)))
            let passes: [(String, MTLTexture, MTLTexture, MTLSize, MTLSize)] = [
                ("s1_7_mask_blur_h", atlas, tmp,
                 MTLSize(width: (canvas.width + segment - 1) / segment, height: (canvas.height + 31) / 32, depth: count),
                 MTLSize(width: 1, height: 32, depth: 1)),
                ("s1_7_mask_blur_v", tmp, atlas,
                 MTLSize(width: (canvas.width + 31) / 32, height: (canvas.height + segment - 1) / segment, depth: count),
                 MTLSize(width: 32, height: 1, depth: 1)),
            ]
            for (fn, source, destination, groups, threads) in passes {
                let pipe = try kernels.pipeline(file: "s1_7_mask_neighbourhood", function: fn)
                guard let e = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
                e.setComputePipelineState(pipe)
                e.setTexture(source, index: 0)
                e.setTexture(destination, index: 1)
                e.setBytes(&bp, length: MemoryLayout<MaskBlurParams>.stride, index: 0)
                e.setBuffer(table.maskBuffer, offset: 0, index: 1)
                e.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
                e.endEncoding()
                report.atlasPasses.append(fn)
            }
        }

        // 3 — guided refine, one mask at a time (§4.6): regression at 1/q, bilinear coefficient
        // upsample, full-resolution reconstruction. The atlas stays a full-frame pass on purpose: a
        // neighbourhood operator needs a complete input, and only S1.6 (pointwise) is worth tiling.
        let refineMasks = table.masks.prefix(count).filter { $0.misc.z > 0 && $0.misc.w >= 0.5 }
        report.refineMaskCount = refineMasks.count
        if report.refineMaskCount > 0 {
            try encodeRefine(cb: cb, atlas: atlas, guide: src, table: table,
                             canvas: canvas, report: &report)
        }

        // 4 — the receipts: per-mask bounds (halo included) and the dependency they justify.
        let mapping = MaskCanvasMapping(geometry: edit.geometry, source: sourceSize,
                                        content: plan.content, canvas: canvas,
                                        origin: (Double(plan.origin.x), Double(plan.origin.y)))
        for m in edit.activeMasks {
            if let r = MaskBounds.canvasRect(for: m, mapping: mapping) { report.bounds[m.id] = r }
        }
        report.atlasDependency = table.dependency
        return report
    }

    /// §4.6's guided filter, per mask, with every buffer named for what it holds.
    private func encodeRefine(cb: MTLCommandBuffer, atlas: MTLTexture, guide: MTLTexture,
                              table: MaskTable, canvas: ImageSize,
                              report: inout MaskStageReport) throws {
        let q = 4
        let qW = (canvas.width + q - 1) / q
        let qH = (canvas.height + q - 1) / q
        let inTex = try scratch("refine-in", width: canvas.width, height: canvas.height, format: .r16Float)
        let outTex = try scratch("refine-out", width: canvas.width, height: canvas.height, format: .r16Float)
        let packed = try scratch("refine-packed", width: qW, height: qH, format: .rgba16Float)
        let statsA = try scratch("refine-statsA", width: qW, height: qH, format: .rgba16Float)
        let statsB = try scratch("refine-statsB", width: qW, height: qH, format: .rgba16Float)
        let coeffA = try scratch("refine-coeffA", width: qW, height: qH, format: .rgba16Float)
        let coeffB = try scratch("refine-coeffB", width: qW, height: qH, format: .rgba16Float)

        for (slice, m) in table.masks.prefix(table.ids.count).enumerated() where m.misc.z > 0 {
            let strength = min(max(m.misc.z, 0), 1)
            var rp = RefineParams(
                a: SIMD4(Int32(canvas.width), Int32(canvas.height), Int32(q),
                         Int32(max(1, (m.misc.w / Float(q)).rounded()))),
                b: SIMD4(Float(MaskRadius.guidedEpsilon(Double(strength))),
                         0.2126, 0.7152, 0.0722),
                c: SIMD4(strength, 0, 0, 0),
                // One thread per column/row in the 1/q domain: the q-domain rows are at most a few
                // hundred texels, so a single running sum per thread beats a segmented dispatch.
                d: SIMD4(Int32(qW), Int32(qH), 1, 0))

            // (a) the slice is an array layer; the guided filter works on 2-D textures, so it is
            //     copied out and back rather than viewed (views of `.shared` array slices are not
            //     writable on every family, a blob is one code path).
            try copy(cb: cb, from: atlas, slice: slice, to: inTex, size: canvas)

            // (b) pack (I, p, I², I·p) at 1/q, then the two separable box means of the window.
            let pack = try kernels.pipeline(file: "s1_7_mask_neighbourhood", function: "s1_7_refine_pack")
            guard let e0 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            e0.setComputePipelineState(pack)
            e0.setTexture(guide, index: 0)
            e0.setTexture(inTex, index: 1)
            e0.setTexture(packed, index: 2)
            e0.setBytes(&rp, length: MemoryLayout<RefineParams>.stride, index: 0)
            dispatch(e0, pack, ImageSize(width: qW, height: qH))
            e0.endEncoding()
            report.atlasPasses.append("s1_7_refine_pack")

            try boxPass(cb: cb, from: packed, to: statsA, params: &rp, qW: qW, qH: qH,
                        name: "s1_7_box4_h", report: &report)
            try boxPass(cb: cb, from: statsA, to: statsB, params: &rp, qW: qW, qH: qH,
                        name: "s1_7_box4_v", report: &report)

            // (c) a, b from the window stats (single-channel guide ⇒ scalar coefficients).
            let coeff = try kernels.pipeline(file: "s1_7_mask_neighbourhood", function: "s1_7_refine_coeff")
            guard let e1 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            e1.setComputePipelineState(coeff)
            e1.setTexture(statsB, index: 0)
            e1.setTexture(coeffA, index: 1)
            e1.setBytes(&rp, length: MemoryLayout<RefineParams>.stride, index: 0)
            dispatch(e1, coeff, ImageSize(width: qW, height: qH))
            e1.endEncoding()
            report.atlasPasses.append("s1_7_refine_coeff")

            // (d) smooth the coefficients over the same window, then reconstruct at full resolution.
            try boxPass(cb: cb, from: coeffA, to: coeffB, params: &rp, qW: qW, qH: qH,
                        name: "s1_7_box4_h", report: &report)
            try boxPass(cb: cb, from: coeffB, to: coeffA, params: &rp, qW: qW, qH: qH,
                        name: "s1_7_box4_v", report: &report)

            let apply = try kernels.pipeline(file: "s1_7_mask_neighbourhood", function: "s1_7_refine_apply")
            guard let e2 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            e2.setComputePipelineState(apply)
            e2.setTexture(guide, index: 0)
            e2.setTexture(coeffA, index: 1)
            e2.setTexture(inTex, index: 2)
            e2.setTexture(outTex, index: 3)
            e2.setBytes(&rp, length: MemoryLayout<RefineParams>.stride, index: 0)
            dispatch(e2, apply, canvas)
            e2.endEncoding()
            report.atlasPasses.append("s1_7_refine_apply")

            // (e) back into the slice. The blit is what makes the refine transparent to every later
            //     consumer: same texture, same layout, one extra neighbourhood applied.
            try copy(cb: cb, from: outTex, to: atlas, slice: slice, size: canvas)
        }
    }

    private func boxPass(cb: MTLCommandBuffer, from source: MTLTexture, to destination: MTLTexture,
                         params: inout RefineParams, qW: Int, qH: Int, name: String,
                         report: inout MaskStageReport) throws {
        let pipe = try kernels.pipeline(file: "s1_7_mask_neighbourhood", function: name)
        let horizontal = name.hasSuffix("_h")
        let groups = horizontal
            ? MTLSize(width: max(1, qW / 32 + 1), height: qH, depth: 1)
            : MTLSize(width: qW, height: max(1, qH / 32 + 1), depth: 1)
        let threads = horizontal ? MTLSize(width: 32, height: 1, depth: 1)
                                 : MTLSize(width: 1, height: 32, depth: 1)
        guard let e = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e.setComputePipelineState(pipe)
        e.setTexture(source, index: 0)
        e.setTexture(destination, index: 1)
        e.setBytes(&params, length: MemoryLayout<RefineParams>.stride, index: 0)
        e.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        e.endEncoding()
        report.atlasPasses.append(name)
    }

    /// Whole-texture copy between a 2-D texture and one slice of the atlas array.
    private func copy(cb: MTLCommandBuffer, from: MTLTexture, slice: Int, to: MTLTexture,
                      size: ImageSize) throws {
        guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
        blit.copy(from: from, sourceSlice: slice, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
                  to: to, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    private func copy(cb: MTLCommandBuffer, from: MTLTexture, to: MTLTexture, slice: Int,
                      size: ImageSize) throws {
        guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
        blit.copy(from: from, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: size.width, height: size.height, depth: 1),
                  to: to, destinationSlice: slice, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    /// Cached scratch textures for the neighbourhood passes, keyed by label + description. They only
    /// exist when a mask actually asks for feather/refine, and they are dropped when the canvas
    /// changes, so a preview-sized graph never holds export-sized buffers.
    private var scratchTextures: [String: MTLTexture] = [:]

    private func scratch(_ label: String, width: Int, height: Int, format: MTLPixelFormat,
                         arrayLength: Int = 1, asArray: Bool = false) throws -> MTLTexture {
        let key = "\(label):\(width)x\(height):\(format.rawValue):\(arrayLength):\(asArray)"
        if let hit = scratchTextures[key] { return hit }
        if scratchTextures.count > 16 { scratchTextures.removeAll() }
        let desc = MTLTextureDescriptor()
        // A one-slice array is still an array: binding a `type2D` texture where the kernel declares
        // `texture2d_array` is not an error Metal reports, it is an error it renders as zeros.
        desc.textureType = (asArray || arrayLength > 1) ? .type2DArray : .type2D
        desc.pixelFormat = format
        desc.width = max(1, width)
        desc.height = max(1, height)
        desc.arrayLength = max(1, arrayLength)
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let t = device.makeTexture(descriptor: desc) else {
            throw RenderError.allocationFailed(key)
        }
        scratchTextures[key] = t
        return t
    }

    /// The tiling material of the two mask keys: empty for `.off`, so the 005c keys (and the recorded
    /// goldens) do not move.
    private func maskTilingSuffix(options: RenderOptions, table: MaskTable?) -> String {
        guard options.maskTiling != .off, let table else { return "" }
        let grid = TileGrid.forScale(options.scale)
        return "|" + grid.keyString + ";" + table.dependency.keyString
    }

    /// §3.4 step 3: which tiles S1.6 has to write.
    private func localTilePlan(edit: EditModel, plan: Plan, options: RenderOptions) -> TilePlan {
        let canvas = plan.canvas
        let full = TilePlan.fullFrame(canvas)
        // Only `.tiles` tiles a cold frame: see `MaskTiling` and the cost note for the measurement
        // that made `.auto` incremental-only.
        guard options.maskTiling == .tiles else { return full }

        let active = edit.activeMasks
        let adjusted = active.filter { !$0.adjustments.isIdentity }
        guard !adjusted.isEmpty else { return full }

        // The dependency closure: a mask that consumes another mask's selection is only correct if
        // its producer is in the union of bounds as well (§3.4 step 4). With M4's edgeless graph the
        // closure is the identity, which is exactly why it is tested on a synthetic chain.
        let graph = MaskGraph.from(active)
        let order = graph.executionOrder(for: Set(adjusted.map(\.id)))
        guard !order.isEmpty else { return full }
        let needed = active.filter { order.contains($0.id) }

        let mapping = MaskCanvasMapping(geometry: edit.geometry, source: sourceSize,
                                        content: plan.content, canvas: canvas,
                                        origin: (Double(plan.origin.x), Double(plan.origin.y)))
        let dirty = MaskBounds.dirtySet(needed, mapping: mapping)
        guard !dirty.isEmpty else { return full }

        let grid = TileGrid.forScale(options.scale)
        let tiles = grid.tiles(covering: dirty, canvas: canvas)
        guard !tiles.isEmpty else { return full }
        let pixelCount = RectSet(tiles).unionPixelCount
        guard pixelCount > 0, pixelCount < canvas.pixelCount else { return full }
        return TilePlan(tiles: tiles, pixelCount: pixelCount, canvasPixelCount: canvas.pixelCount,
                        dependency: .pointwise, tiled: true)
    }

    /// Per-mask canvas bounds for the enabled masks (halo included) — the same numbers the atlas report
    /// carries, kept on the entry so a later frame can answer "which region holds this mask".
    private func localBounds(edit: EditModel, plan: Plan) -> [String: MaskRect] {
        let mapping = MaskCanvasMapping(geometry: edit.geometry, source: sourceSize,
                                       content: plan.content, canvas: plan.canvas,
                                       origin: (Double(plan.origin.x), Double(plan.origin.y)))
        var out: [String: MaskRect] = [:]
        for m in edit.activeMasks {
            if let r = MaskBounds.canvasRect(for: m, mapping: mapping) { out[m.id] = r }
        }
        return out
    }

    /// §3.4 step 3, the incremental case: which tiles hold the masks whose `applyKey` moved.
    /// `nil` means "not provably confined, do the full pass" — the conservative answer, which is why a
    /// wrong region can only cost time, never a pixel.
    private func incrementalTilePlan(previous: LocalEntry, applyKeys: [String: String],
                                     edit: EditModel, plan: Plan,
                                     options: RenderOptions) -> (plan: TilePlan, bounds: [String: MaskRect])? {
        guard previous.bounds.keys.sorted() == applyKeys.keys.sorted() else { return nil }
        let moved = applyKeys.filter { previous.applyKeys[$0.key] != $0.value }.map(\.key)
        guard !moved.isEmpty else { return nil }

        // The bounds of the masks that did not move must be *identical*, or their pixels would be left
        // stale inside a region no tile covers.
        let bounds = localBounds(edit: edit, plan: plan)
        for (id, old) in previous.bounds where !moved.contains(id) {
            guard bounds[id] == old else { return nil }
        }

        // A mask that moved has to be rewritten over its whole bounds — including the part where its
        // coverage is 0 and its old effect has to be undone.
        var dirty = RectSet()
        for id in moved where bounds[id] != nil { dirty.insert(bounds[id]!) }
        guard !dirty.isEmpty else { return nil }

        let grid = TileGrid.forScale(options.scale)
        let tiles = grid.tiles(covering: dirty, canvas: plan.canvas)
        guard !tiles.isEmpty else { return nil }
        let pixelCount = RectSet(tiles).unionPixelCount
        guard pixelCount > 0, pixelCount < plan.canvas.pixelCount else { return nil }
        let tilePlan = TilePlan(tiles: tiles, pixelCount: pixelCount,
                                canvasPixelCount: plan.canvas.pixelCount,
                                dependency: .pointwise, tiled: true)
        return (tilePlan, bounds)
    }

    /// One encoder, one dispatch per tile. `blitSource` is the `.load`: a **fresh** destination must
    /// first hold the source everywhere the tiles do not reach. An in-place update passes `false`,
    /// because the texture it writes already holds exactly those pixels — and that is the difference
    /// between tiling paying for itself and tiling merely moving the work around.
    private func encodeLocal(cb: MTLCommandBuffer, into out: MTLTexture, from src: MTLTexture,
                             atlas: MTLTexture, table: MaskTable, tilePlan: TilePlan,
                             blitSource: Bool) throws {
        if blitSource {
            guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
            blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: out.width, height: out.height, depth: 1),
                      to: out, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        let p = try kernels.pipeline(file: "s1_6_local", function: "s1_6_local")
        let anyActive = table.adjust.contains { $0.c.w > 0.5 }
        guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        enc.setComputePipelineState(p)
        enc.setTexture(src, index: 0)
        enc.setTexture(atlas, index: 1)
        enc.setTexture(out, index: 2)
        enc.setBuffer(table.adjustBuffer, offset: 0, index: 1)
        for tile in tilePlan.tiles {
            var params = LocalParamsU(a: SIMD4(anyActive ? 1 : 0, Int32(table.adjust.count),
                                               Int32(tile.x0), Int32(tile.y0)))
            enc.setBytes(&params, length: MemoryLayout<LocalParamsU>.stride, index: 0)
            dispatch(enc, p, ImageSize(width: tile.width, height: tile.height))
        }
        enc.endEncoding()
    }

    /// Render `edit` and hand back the atlas it produced: the same numbers S1.6 consumed, so a test
    /// (or `photonsctl maskdump`) can compare against the analytic reference instead of eyeballing a
    /// picture. `nil` when the document has no enabled mask — the stage does not exist then.
    public func maskAtlas(_ edit: EditModel,
                          options: RenderOptions = RenderOptions()) throws -> MaskAtlasDump? {
        try maskAtlasWithReport(edit, options: options)?.dump
    }

    /// The atlas **and** 005d's receipts (tile plan, bounds, the kernels that ran), from one render —
    /// so a test can prove "the tile path covered 18 % of the canvas" and "the pixels are identical to
    /// the full-frame path" about the same frame instead of two runs that might disagree.
    public func maskAtlasWithReport(_ edit: EditModel, options: RenderOptions = RenderOptions())
        throws -> (dump: MaskAtlasDump, report: MaskStageReport)? {
        guard edit.hasActiveMasks else { return nil }
        var opts = options
        opts.wantsPixels = false
        let result = try render(edit, options: opts)
        if let t = result.output { pool.recycle(t) }
        guard let entry = atlasCache else { return nil }

        let tex = entry.texture
        let w = tex.width, h = tex.height
        var slices: [[Float]] = []
        slices.reserveCapacity(tex.arrayLength)
        for s in 0..<tex.arrayLength {
            var raw = [UInt16](repeating: 0, count: w * h)
            raw.withUnsafeMutableBytes { buf in
                tex.getBytes(buf.baseAddress!,
                             bytesPerRow: w * 2,
                             bytesPerImage: w * h * 2,
                             from: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0,
                             slice: s)
            }
            slices.append(raw.map { Float(Float16(bitPattern: $0)) })
        }
        let dump = MaskAtlasDump(width: w, height: h, maskIDs: entry.ids, slices: slices)
        return (dump, result.maskReport ?? MaskStageReport())
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
