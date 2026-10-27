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
    /// The file the buffer was decoded from, when the caller knows it.
    ///
    /// 005e uses it for exactly one thing: the `CIRAWFilter` semantic-matte probe, which needs to
    /// open the file (§5.1). Without it a semantic mask still works through Vision — the file is a
    /// route, not a requirement.
    public let sourceURL: URL?

    public init(image: LinearImage, identity: String, sourceURL: URL? = nil) {
        self.image = image
        self.identity = identity
        self.sourceURL = sourceURL
    }
}

public struct RenderOptions: Sendable {
    /// Output canvas. `nil` = the content size (export). A viewport passes its own size and the
    /// photograph is letterboxed inside it, which is what the screen actually shows.
    public var canvas: ImageSize?
    /// Output pixels relative to crop pixels. 1 = 1:1, 0.25 = quarter-size preview.
    public var scale: Double
    /// Render only this part of the frame, in **content pixels** — the cropped picture's own pixel
    /// grid at `scale` (`LoupeFraming` computes it for a 1:1 loupe window).
    ///
    /// `nil` (the default) is the whole frame and is what every pre-window caller gets: thumbnails,
    /// fit, export. A window is *not* a crop: S0 still rotates/crops/flips the **whole frame** and
    /// then takes the window out of it, so
    ///
    ///   · a window render is the whole-frame render with a rectangle cut out of it — the same
    ///     projection to within a texel of rounding, not a different one (a crop-shaped window at
    ///     9° straighten was ~0.29 % off, because S0 rotated in crop space);
    ///   · S3c's vignette and the mask descriptors' feather normalize to the **whole frame**, so a
    ///     vignette or a feather keeps its physical size at 1:1 instead of shrinking to the window.
    ///
    /// The rect is clamped into the frame and a window covering the whole frame is normalized to
    /// `nil`, so "1:1 on an image smaller than the viewport" costs no extra key.
    ///
    /// One honest limitation: the mask atlas is a canvas-sized texture, so a **neighbourhood**
    /// operator (feather blur, guided refine) clamps at the window's edge instead of the frame's.
    /// The radii themselves are the frame's, so the affected band is at most `feather + guided` pixels
    /// wide, at the window's border — the same edge-clamp rule the frame's own border has always had,
    /// measured in `WindowTests.testMaskFeatherKeepsItsPhysicalSizeInsideAWindow`.
    public var outputWindow: ImageRect?
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

    /// Measure a histogram of the picture, before the display transform (see `Histogram`).
    ///
    /// Off by default and free when off: no readback, no extra texture, no extra key, and the pixels
    /// are bit-identical either way. When on, the frame's own command buffer gains nothing — the
    /// measurement reads the texture S3 wrote *before* S4 encodes it, so a frame render's measurement
    /// describes the frame it drew and costs one readback of that frame
    /// (`testPixelsAndKeysAreIdenticalWithAndWithout`).
    ///
    /// **The card does not set this.** `measureHistogram(_:bins:headroom:)` is the shipped entry: it
    /// renders the whole picture at thumbnail scale and measures that, which is what makes the numbers
    /// independent of the camera and the panel. This flag stays because the measurement has to happen
    /// inside a render (the pre-S4 texture is never handed out), and the CLI and the tests want the
    /// measurement of a render they choose.
    public var collectHistogram: Bool
    /// Bins per channel for `collectHistogram`; 256 is an 8-bit output's own resolution.
    public var histogramBins: Int
    /// Long edge of the grid `collectHistogram` measures, or **0** for the whole-canvas readback.
    ///
    /// The whole-canvas readback is right when the canvas *is* the picture at thumbnail scale
    /// (`measureHistogram`: 0.58 Mpx), and wrong for a frame: a 4.1 Mpx canvas is 33 MB of half float
    /// per frame. With this set, the measurement is a **stride-sampled grid** of the pre-S4 texture
    /// (long edge as asked, 256 = 36 k texels = 0.29 MB), read out of the same command buffer with
    /// `histogram_sample_linear`. Same pixels policy as the frame-sample path: one texel per output
    /// texel on a deterministic stride, over the picture's own rect, so the grid estimates the
    /// distribution instead of averaging it flat (070).
    ///
    /// Only the *sampling* changes: the domain is the scene-linear texture in both cases, so a grid
    /// measurement and a canvas measurement of the same render differ by sampling error and nothing else.
    public var histogramSampleLongEdge: Int

    /// **Tests only.** Render S1.7 with the arithmetic path even when the tables are the identity.
    ///
    /// The identity branch is a byte copy (`s1_7_hdr_curve.metal` rule 1), which is the right thing
    /// for the product and a blind spot for measurement: it is the one way to check that the
    /// identity curve is *arithmetically* the identity too (shaper round trip, table interpolation,
    /// rule 4's slope of exactly 1 above +4 EV). Never part of a key and never set by the app — the
    /// pixels it produces differ from the shipped path by ≤ 2.4e-6 relative, which is the point of
    /// measuring them. **Pair it with `useCache: false`**: a cached texture keyed by the same
    /// document would otherwise be reused across the two paths, which compare equal in every key.
    public var forceCurveArithmetic: Bool

    /// 080 — **which pixels this render is of**: the document (`edited`, the default) or the decode
    /// (`decoded`, i.e. 「显示原图」).
    ///
    /// `.decoded` shortens the pipeline to `S0 → S4` with an **identity geometry**, so the output is
    /// `OETF(M_working→out · M_decoded→working · decode)` — the decode, display-encoded, and nothing
    /// else. It changes no cache key and writes no document; the two sources are two renders over one
    /// resident buffer, which is why showing the original costs a pass and never a decode.
    public var source: RenderSource

    /// **Tests only.** Make `.decoded` render the **parameters-cleared** document through the whole
    /// pipeline instead — the spelling 「参数清零后的渲染」 that `\` must not be.
    ///
    /// It exists so the acceptance's first assertion can be shown to be load-bearing rather than
    /// claimed: `BeforeAfterTests.testTheRefutationTurnsTheFirstAssertionRed` renders both spellings
    /// and prints that the decode and this one are the *same bytes* when the flag is on, i.e. the
    /// assertion "the two differ" fails.
    public var originalRendersAsParametersCleared: Bool

    public init(canvas: ImageSize? = nil,
                scale: Double = 1,
                outputWindow: ImageRect? = nil,
                display: DisplayOptions = DisplayOptions(),
                useCache: Bool = true,
                wantsPixels: Bool = true,
                maskTiling: MaskTiling = .auto,
                collectHistogram: Bool = false,
                histogramBins: Int = 256,
                histogramSampleLongEdge: Int = 0,
                forceCurveArithmetic: Bool = false,
                source: RenderSource = .edited,
                originalRendersAsParametersCleared: Bool = false) {
        self.canvas = canvas
        self.scale = scale
        self.outputWindow = outputWindow
        self.display = display
        self.useCache = useCache
        self.wantsPixels = wantsPixels
        self.maskTiling = maskTiling
        self.collectHistogram = collectHistogram
        self.histogramBins = histogramBins
        self.histogramSampleLongEdge = histogramSampleLongEdge
        self.forceCurveArithmetic = forceCurveArithmetic
        self.source = source
        self.originalRendersAsParametersCleared = originalRendersAsParametersCleared
    }
}

/// How the local stage is dispatched: the mask atlas is built first, then the local pass reads it
/// per tile and the combination step folds the result back into the frame.
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
    /// Where the photograph itself was drawn **inside this frame's texture** — canvas pixels, origin
    /// top-left, half-open on the far edge (048).
    ///
    /// This is the rect a per-frame measurement has to use. `canvas` and `content` alone cannot say
    /// it: they describe the letterbox, and `(canvas − content) / 2` is the picture's rect only when
    /// the window does not reach past the frame. Hand that guess a 1:1 window on a picture smaller
    /// than the viewport — the photograph is drawn at an offset with background around it — and the
    /// measured "picture" is the window, so bin 0 collects every background pixel (measured 37 % of
    /// the sample on a 1600×1002 window over a 2400×800 picture). The graph knows where S0 wrote the
    /// picture (`plan.drawnRect`), so nobody has to infer it.
    public let drawnRect: ImageRect
    /// The part of the frame these pixels are, in content pixels of the full frame at this render's
    /// `scale`; the whole frame when no window was asked for.
    public let window: ImageRect
    public let keys: StageKeys
    public let trace: RenderTrace
    /// Present when `RenderOptions.wantsPixels` was set.
    public let display: DisplayImage?
    /// Present when the caller asked for the GPU texture instead of pixels (the on-screen path).
    /// Hand it back with `RenderGraph.recycle(output:)` or the pool will not get it back.
    public let output: MTLTexture?
    /// 005d: what the mask stages actually did — the kernels they ran and the tile plan they
    /// dispatched. `nil` for a document without masks (the stages do not exist then). 005e adds the
    /// semantic-matte receipts to it.
    public let maskReport: MaskStageReport?
    /// 005e: true when the `showMask` overlay pass actually ran, i.e. `showMaskID` was set **and**
    /// named an enabled mask whose atlas slice existed. False means the pixels are the document's
    /// own, which is what makes "`showMask == nil` changes nothing" checkable per frame rather than
    /// by inspection.
    public let showsMask: Bool
    /// Present when `RenderOptions.collectHistogram` was set: R/G/B/luma over the display-encoded
    /// output, with the clipping ratios and the ROI it was measured over. `nil` otherwise, so
    /// "nothing was measured" and "everything was black" cannot be confused.
    public let histogram: Histogram?
    /// What the histogram cost inside this render: the reduced-grid readback plus the CPU binning
    /// (070 — the GPU pass itself is part of the frame's own command buffer, so its milliseconds are
    /// in `trace.gpuMilliseconds`, not here). 0 when nothing was measured.
    public let histogramMilliseconds: Double
    /// The **scene-linear sample** the histogram was counted from, when the render produced one
    /// (2026-10-27, for the pointer's readout): the ≤ 256-long-edge grid of the picture's pixels
    /// *before* S4, i.e. exactly the bytes `histogram` was binned from.
    ///
    /// It is handed out because a per-pixel question ("what is under the cursor") cannot be answered
    /// from `histogram` — bins are counts, not pixels — and cannot be answered from `output` either,
    /// which S4 has already clamped at the panel's headroom. This is the same lattice the plot draws,
    /// so the number under the pointer and the bin under the pointer are one measurement. `nil` when no
    /// grid was asked for.
    public let histogramSample: LinearSample?

    init(canvas: ImageSize, content: ImageSize, drawnRect: ImageRect, window: ImageRect,
         keys: StageKeys, trace: RenderTrace, display: DisplayImage?, output: MTLTexture?,
         maskReport: MaskStageReport? = nil, showsMask: Bool = false,
         histogram: Histogram? = nil, histogramMilliseconds: Double = 0,
         histogramSample: LinearSample? = nil) {
        self.canvas = canvas
        self.content = content
        self.drawnRect = drawnRect
        self.window = window
        self.keys = keys
        self.trace = trace
        self.display = display
        self.output = output
        self.maskReport = maskReport
        self.showsMask = showsMask
        self.histogram = histogram
        self.histogramMilliseconds = histogramMilliseconds
        self.histogramSample = histogramSample
    }
}

/// One mask component's semantic outcome, as a value the UI can print verbatim.
///
/// §5.1 requires "zero coverage **and** a reason" — so the unavailable case carries the reason rather
/// than a nil, and the graph never throws for a matte the OS cannot produce.
public enum MaskSemanticEvent: Sendable, Equatable {
    case semanticAvailable(maskID: String, componentID: String, kind: SemanticKind,
                           provider: SemanticProvider, digest: String)
    case semanticUnavailable(maskID: String, componentID: String, kind: SemanticKind,
                             reason: SemanticUnavailableReason)
    /// The document recorded a `rasterDigest` and the OS produced a different one: the model changed
    /// under the selection (§5.3). Reported, never applied silently.
    case semanticDigestChanged(maskID: String, kind: SemanticKind,
                               stored: String, produced: String)

    public var kind: SemanticKind {
        switch self {
        case .semanticAvailable(_, _, let k, _, _): return k
        case .semanticUnavailable(_, _, let k, _): return k
        case .semanticDigestChanged(_, let k, _, _): return k
        }
    }

    public var isAvailable: Bool {
        if case .semanticAvailable = self { return true }
        return false
    }

    /// Canonical text for key material and for a log line; sorted before it enters a key.
    public var keyString: String {
        switch self {
        case .semanticAvailable(let m, let c, let k, let p, let d):
            return "sem=\(k.rawValue)@\(m)/\(c)=\(p.rawValue):\(d.prefix(16))"
        case .semanticUnavailable(let m, let c, let k, let r):
            return "sem=\(k.rawValue)@\(m)/\(c)=unavailable(\(r.rawValue))"
        case .semanticDigestChanged(let m, let k, let stored, let produced):
            return "sem=\(k.rawValue)@\(m)=digest(\(stored.prefix(8))→\(produced.prefix(8)))"
        }
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
    /// 005e: one entry per semantic component — resolved with a digest, or unavailable with a reason.
    public var semanticEvents: [MaskSemanticEvent] = []
    /// 005e: the mask the `showMask` overlay painted, and the atlas slice it read (proof that the
    /// overlay and S1.6 consumed the same buffer, §6 005e ⑤).
    public var showMaskID: String?
    public var showMaskSlice: Int?

    public init() {}

    /// Total pixels the S1.6 pass wrote.
    public var localPixelCount: Int { localPlan.pixelCount }
    public var localPixelFraction: Double { localPlan.fraction }

    /// The kinds this frame could not produce a matte for, in report order (deduplicated).
    public var semanticUnavailableKinds: [SemanticKind] {
        var seen = Set<SemanticKind>()
        var out: [SemanticKind] = []
        for e in semanticEvents {
            guard case .semanticUnavailable(_, _, let kind, _) = e else { continue }
            if seen.insert(kind).inserted { out.append(kind) }
        }
        return out
    }

    /// The resolved rasters' digests, in report order — the "did the model change" answer.
    public var semanticDigests: [String] {
        semanticEvents.compactMap { e in
            if case .semanticAvailable(_, _, _, _, let d) = e { return d }
            return nil
        }
    }
}

// MARK: - mask atlas readback

/// The S1.5 output, copied back to the CPU: one slice per enabled mask, in id order.
///
/// This exists for verification (`photonsctl maskdump`, the 005b acceptance tests) and for the
/// `showMask` overlay, which reads the same buffer instead of re-evaluating the predicate a second
/// way: a mask is a predicate over normalised source pixels, evaluated once into an atlas so the
/// local pass never re-evaluates the shape per tile.
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

/// Mirror of `Kernels/s0_geometry.metal`, byte for byte: **7 float4 = 112 bytes** (a mismatch reads
/// the wrong uniform and does not fail, so `ChromaticAberrationTests` asserts the number on both
/// sides).
struct S0Params {
    var a: SIMD4<Float>   // canvasSize.xy, contentOrigin.xy
    var b: SIMD4<Float>   // contentSize.xy, srcSize.xy
    var c: SIMD4<Float>   // crop rect
    var d: SIMD4<Float>   // cos, sin, flipH, flipV
    var e: SIMD4<Float>   // identity, backgroundOutside, pureCA, pad
    var f: SIMD4<Float>   // frameSize.xy, frameOrigin.xy (content pixels of the whole frame)
    var g: SIMD4<Float>   // caRed, caBlue, pad, pad (029)
}

private struct S1Params {
    var a: SIMD4<Float>   // gain, wbR, wbG, wbB
    var b: SIMD4<Float>   // recovery, identity, blacks, whites
    // contentOrigin.xy, contentSize.xy in canvas pixels — the letterbox guard (派单 008 B), in S1
    // because the dropper's level and 071's offset both move the matte's 0. Same convention as S0's
    // `a`/`b` and S3c's `c`. (073B's knee keeps 0 at 0, but the other two spellings do not.)
    var c: SIMD4<Float>
    // 030: blackLevel, whiteLevel, hasBlack, hasWhite. Read only by the `kLevels` entry point — the
    // black/white *sliders* are an EV window now (073B) and never arrive here as a level.
    var d: SIMD4<Float>
    // 071: blackOffset, pad, pad, pad — the additive linear trim, applied between the level and the
    // gain. 0 for every document that never used the control, and then the kernel's `kTrim` is false.
    var e: SIMD4<Float>
}

private struct S2Params {
    var a: SIMD4<Float>   // contrast, pivot, pad, pad
    var b: SIMD4<Float>   // highlights, shadows, identity
    // contentOrigin.xy, contentSize.xy in canvas pixels — the letterbox guard (派单 008 B). Without
    // it the shadows/highlights lifts treat the matte's 0 as a picture pixel and the viewport's
    // background bars light up. Same convention as S0's `a`/`b`, S1's `c` and S3c's `c`.
    var c: SIMD4<Float>
}

/// Mirror of `HDRCurveParams` in `s1_7_hdr_curve.metal`, byte for byte (派单 030).
///
/// `whiteU` / `hdrPerStop` come from `HDRCurveAxis` — the kernel has no axis constants of its own,
/// so the CPU reference and the GPU shaper cannot drift apart. 062 replaced 044's `x0`/`K` with the
/// two numbers of the histogram-aligned axis (SDR = display code over half of `u`, HDR = 12.5 % of
/// `u` per stop). The slopes are rule 4's continuation: the last segment of each table, so a curve
/// keeps going above +4 EV instead of being clamped.
private struct HDRCurveParams {
    var a: SIMD4<Float>   // identity, tableSize, whiteU, hdrPerStop
    // contentOrigin.xy, contentSize.xy in canvas pixels — the letterbox guard (派单 008 C). A curve
    // with its black end lifted lifts the matte's 0 too, and the bars turn grey. Same convention as
    // S2's `c` and S3c's `c`.
    var b: SIMD4<Float>
    var c: SIMD4<Float>   // slopeW, slopeR, slopeG, slopeB
    var d: SIMD4<Float>   // lumaR, lumaG, lumaB, identity mask (062: bit0 = W, 1 = R, 2 = G, 3 = B)
    // The black point (first control point's x) of each table, W/R/G/B — 派单 061. The kernel takes
    // rule 3's sub-black pass-through only where this is 0, because a raised black point is a clip and
    // the clip has to include the negatives (`s1_7_hdr_curve.metal` rule 3, `CurveLUT.blackPoints`).
    var e: SIMD4<Float>
}

private struct ColorParams {
    var a: SIMD4<Float>   // vibrance, saturation, identity
    var b: SIMD4<Float>   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
}

/// Mirror of `Kernels/s3_6_hsl.metal`'s two structs (派单 076).
private struct HSLParamsU {
    var a: SIMD4<Float>   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
}

/// One band as the kernel reads it: the three slider values in units, and the reach towards the
/// previous/next centre in **OKLCh degrees** (which is what makes the weights a partition of unity).
private struct HSLBandU {
    var v: SIMD4<Float>   // hue, saturation, luminance (units), centre (OKLCh degrees)
    var e: SIMD4<Float>   // halfWidth to the previous centre, halfWidth to the next, pad, pad
}

private struct VignetteParams {
    var a: SIMD4<Float>   // amount, midpoint, feather, roundness
    var b: SIMD4<Float>   // frameSize.xy, frameOrigin.xy (the whole frame, in content pixels)
    var c: SIMD4<Float>   // identity, contentOrigin.x, contentOrigin.y, pad
}

/// Mirror of `Kernels/s3_7_grain.metal`, byte for byte — the same geometry convention as S3c's
/// (`p.b`/`p.c` are shared verbatim), so grain is a property of the frame and not of the window.
private struct GrainParams {
    var a: SIMD4<Float>   // amount, size, roughness, seed
    var b: SIMD4<Float>   // frameSize.xy, frameOrigin.xy (the whole frame, in content pixels)
    var c: SIMD4<Float>   // identity, contentOrigin.x, contentOrigin.y, pad
}

private struct DisplayParams {
    var m: simd_float4x4
    var a: SIMD4<Float>   // identityMatrix
}

/// Mirror of `Kernels/histogram_sample.metal`, byte for byte: the picture's rect inside the frame
/// (in texels) and the stride each output texel jumps.
private struct HistSampleParams {
    var a: SIMD4<Float>   // origin.xy, size.xy
    var b: SIMD4<Float>   // step.xy, dstSize.xy
}

/// 080 — mirror of `CompareParams` in `s5_before_after.metal`, byte for byte.
///
/// The boundary arrives as a **pixel index**, not a fraction: `CompareSplit.dividerPixel(canvas:)`
/// is the one derivation, so the composite cannot put a pixel on the other side of the line than
/// `CompareSplit.side(x:y:canvas:)` says owns it.
private struct CompareParams {
    var a: SIMD4<Float>   // divider index, axis (0 vertical / 1 horizontal), line width, pad
}

// MARK: - mask uniforms (mirror of s1_5_mask_atlas.metal / s1_6_local.metal, byte for byte)

private struct MaskAtlasParams {
    var a: SIMD4<Float>   // canvasSize.xy, contentOrigin.xy
    var b: SIMD4<Float>   // contentSize.xy, sourceSize.xy
    var c: SIMD4<Float>   // crop rect
    var d: SIMD4<Float>   // cos, sin, flipH, flipV
    var e: SIMD4<Int32>   // maskCount
    var f: SIMD4<Float>   // frameSize.xy, frameOrigin.xy (content pixels of the whole frame)
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
    var c: SIMD4<Float>   // blacks, pad, pad, enabled
}

/// 056 — the mirror of `LocalColorDesc` in `s3_5_local_color.metal`. Its own buffer rather than a
/// reuse of `LocalAdjustU`: S1.6 no longer carries hue/saturation, and a stage that reads two
/// numbers should be handed those two numbers, not a struct it has to interpret.
private struct LocalColorU {
    var a: SIMD4<Float>   // hue (units), saturation (units), amountScale (0…1), enabled
}

/// 056 — mirror of `LocalColorParams` in `s3_5_local_color.metal`.
private struct LocalColorParamsU {
    var a: SIMD4<Int32>   // anyActive, maskCount, pad, pad
    var b: SIMD4<Float>   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
}

/// 005e — mirror of `ShowMaskParams` in `s4_show_mask.metal`.
private struct ShowMaskParams {
    var a: SIMD4<Int32>   // slice, pad, pad, pad
    var b: SIMD4<Float>   // strength, red.r, red.g, red.b
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
    /// 056 — S3.5's per-mask descriptors, same atlas order as `adjust`.
    let colorAdjust: [LocalColorU]
    let strokes: [MaskStrokeDescU]
    let points: [SIMD4<Float>]
    let colours: [SIMD4<Float>]
    /// The atlas's declared neighbourhood: `featherRadius + guidedRadius`, per mask, in series.
    let dependency: TileDependency
    let maskBuffer: MTLBuffer
    let shapeBuffer: MTLBuffer
    let adjustBuffer: MTLBuffer
    let colorAdjustBuffer: MTLBuffer
    let strokeBuffer: MTLBuffer
    let pointBuffer: MTLBuffer
    let colourBuffer: MTLBuffer
}

extension ColorGroup {
    /// The eight band centres, as **hue angles in the graph's working primaries**.
    ///
    /// **076 note.** These are *not* what S3.6 weights against any more: the bands left S3 (linear
    /// light) for S3.6 (OKLCh), and a band's centre is now an **OKLCh** hue —
    /// `HSLBands.centresDegrees`, the same eight physical colours measured in the space the maths runs
    /// in. What survives here is the *wheel*: `LocalColorStageTests` builds its fixture pixels at these
    /// angles (a mask's hue is still an HSL angle, so "the colour Lightroom calls red" has to be
    /// addressable in HSL), and `linearHSL` below is the conversion both derivations share.
    ///
    /// Lightroom's wheel is `[0, 30, 60, 120, 180, 240, 285, 315]` **in sRGB**. A hue angle is not a
    /// physical colour — it is a direction from grey in whatever RGB basis the three numbers happen to
    /// be written in — so the moment the working space became Rec.2020 (075) those eight numbers
    /// stopped naming the colours the bands are named after: measured, a pixel on Lightroom's green
    /// centre reads **102.6°** in Rec.2020, 17.4° away from 120°, which put it at 0.61 of the green
    /// tent's weight and made `hue +100` on the green band do 61 % of what the user asked for
    /// (075 §2.2, `LocalColorStageTests.testFullCanvasHueMatchesTheGlobalBandHue`).
    ///
    /// **The decision (owner, 2026-10-27, option A): the hue controls follow the working space.** So
    /// the centres are re-derived — same eight physical colours, new angles — rather than the hue
    /// being measured in a display-referred space on the side. The price is that an *existing*
    /// document's hue band now acts on a slightly different slice of colour than it did (a saturated
    /// red's band moves by 5.2°, green's by −17.4° in code angle but acts on the same green); the
    /// benefit is that the local and global hue controls stay one control with one definition, and no
    /// second sRGB↔Rec.2020 conversion appears anywhere in a frame.
    ///
    /// **Cost: none per frame.** This is a `static let` evaluated once; the numbers travel in the same
    /// eight `float4`s that already carried the centres (`RenderGraph.bandBuffer`).
    ///
    /// The sample colour is `hsl(h, 0.85, 0.5)` — the middle of the shades the fixtures and the panel
    /// use. The hue spread across saturations is ≈0.3° (a linear basis change keeps the *ordering*
    /// and, nearly, the angle), which is inside the 0.5° the local/global equality test allows.
    public static let bandCentresDegrees: [Double] = {
        let lightroom: [Double] = [0, 30, 60, 120, 180, 240, 285, 315]
        let toWorking = ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)
        return lightroom.map { degrees in
            let w = toWorking.applying(to: linearHSL(h: degrees / 360, s: 0.85, l: 0.5))
            return linearHSLHue(w) * 360
        }
    }()

    /// `hsl → linear RGB`, the same arithmetic as `color_hsl.metal`'s inverse (and as the colour maths
    /// in `LocalColorStageTests`, which is deliberately an independent implementation).
    ///
    /// Internal since 076: `HSLBands.centresDegrees` builds the eight band colours with it, so the
    /// wheel's colours and the HSL stage's centres are the same eight physical colours by construction.
    static func linearHSL(h: Double, s: Double, l: Double) -> SIMD3<Double> {
        func channel(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }
        if s < 1e-9 { return SIMD3(l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return SIMD3(channel(p, q, h + 1.0 / 3.0), channel(p, q, h), channel(p, q, h - 1.0 / 3.0))
    }

    /// The hue of a linear RGB triple, in turns — `rgb_to_hsl`'s `h`, which is what the band tent is
    /// measured against (`hueDeg = rgb_to_hsl(v).x * 360`).
    static func linearHSLHue(_ c: SIMD3<Double>) -> Double {
        let mx = max(c.x, max(c.y, c.z)), mn = min(c.x, min(c.y, c.z))
        let d = mx - mn
        if d < 1e-9 { return 0 }
        var h: Double
        if mx == c.x { h = (c.y - c.z) / d + (c.y < c.z ? 6 : 0) }
        else if mx == c.y { h = (c.z - c.x) / d + 2 }
        else { h = (c.x - c.y) / d + 4 }
        return h / 6
    }
}

// MARK: - graph

/// The editing graph: five stages, seven GPU passes, one code path.
///
/// Thumbnail, preview and export all come through here and differ only by `scale` (and the canvas
/// for a viewport). Every stage boundary is a cache key, so a slider that only touches S3 cannot
/// re-run S1 (docs/architecture-decisions.md D5/D6/D12). S1 and S1.6 have slots of their own
/// (`S1Entry`, §073) because the linear pass must be decided by *its own* inputs and its cost is
/// what a red-vs-blue slider step is measured in.
public final class RenderGraph {
    public let deviceName: String
    /// Upright source dimensions.
    ///
    /// Orientation is applied **before S0** (here, at ingestion), so every stage below sees the
    /// picture the way the photographer saw it: crop math, mask radii, straighten and the canvas
    /// aspect are all expressed in this frame, never in the stored-buffer frame. For `.up` — every
    /// file this build has ever decoded — `oriented()` is `self` and nothing is copied.
    public let sourceSize: ImageSize
    /// The orientation that ingestion resolved, kept so the render key can name it.
    public let orientation: ImageOrientation

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let kernels: KernelLibrary
    private let input: RenderInput
    private let sourceTexture: MTLTexture
    /// The source after orientation, i.e. exactly what `sourceTexture` holds. Identical to
    /// `input.image` for `.up` (no copy), so the semantic matte raster and the GPU texture can
    /// never disagree about which way up the picture is.
    private let uprightImage: LinearImage
    private let pool: TexturePool
    private let cacheBudgetBytes: Int

    private struct CacheEntry {
        let key: String
        let texture: MTLTexture
    }

    private var cache: [RenderStage: CacheEntry] = [:]
    private var cacheOrder: [RenderStage] = []
    private var cacheBytes = 0

    /// 073 — **S1's output has its own slot**, and it is keyed by S1's own inputs.
    ///
    /// The user's report: 「每次动蓝色滑块，黑电平校准还得跑一次」. S1 is the linear-domain pass
    /// (levels → black trim → exposure gain → highlight recovery), so a *red* change must re-run it
    /// and nothing else should. The chain has had a per-stage cache since D5/D6 — a stage whose key
    /// did not move is a hit — but S1 was sharing the generic slot with six other stages, which made
    /// three things impossible to state or to test:
    ///
    ///   · **how often S1 runs** was only derivable from a frame's trace, never a number;
    ///   · the entry was the **first victim** of the generic budget (`cacheOrder.removeFirst()`), so on
    ///     a canvas big enough to exceed 1.5 GB — a 60 Mpx export is 480 MB *per stage* — S1 was evicted
    ///     on every frame and re-ran even when its key had not moved;
    ///   · the key was "whatever `RenderKeyChain` says", which is right but not *narrow*: this slot
    ///     names the exact inputs S1 reads (`s1Key`) and proves, byte for byte, that dropping any of
    ///     them serves a stale picture (`S1CacheTests.testRedGroupIsLoadBearing`).
    ///
    /// Exactly **one** texture lives here (4.10 Mpx rgba16Float = 33 MB); a key change replaces it and
    /// gives the old one back to the pool, and `invalidateCache()` frees it.
    private struct S1Entry {
        let key: String
        let texture: MTLTexture
    }
    private var s1Entry: S1Entry?
    /// Whether the red group (blacks/whites sliders, the absolute levels and 071's trim) is part of
    /// `s1Key`. **Never false in the app.** `S1CacheTests` sets it to false to demonstrate what a key
    /// that ignores the red group does: it serves a red change the previous linear buffer, and the
    /// byte-identical assertion has to fail. A cache whose key cannot be shown to be load-bearing is a
    /// cache nobody can trust.
    private let s1KeyIncludesRedGroup: Bool

    /// 073 — how many times each stage **ran**, and how many times its output came out of a cache,
    /// over the life of this graph. Merged from the frame's own trace at the end of `render`, so the
    /// counters cannot disagree with what the frame reported (`.sceneLinear` and `.localApply`
    /// included, both of which now have slots of their own).
    public private(set) var stageRuns: [RenderStage: Int] = [:]
    public private(set) var stageHits: [RenderStage: Int] = [:]
    /// The number the acceptance of 073 reads: 1 for a burst of blue slider steps, one per red step.
    public var s1Passes: Int { stageRuns[.sceneLinear] ?? 0 }
    public var s1Hits: Int { stageHits[.sceneLinear] ?? 0 }
    /// S1.6 (`localApply`) — the mask stage a blue mask slider re-runs and S1 must not.
    public var s1_6Passes: Int { stageRuns[.localApply] ?? 0 }
    public var s1_7Passes: Int { stageRuns[.curve] ?? 0 }
    /// How many S1 textures are being held (0 or 1) and what they cost.
    public var s1CacheTextures: Int { s1Entry == nil ? 0 : 1 }
    public var s1CacheBytes: Int {
        guard let e = s1Entry else { return 0 }
        return e.texture.width * e.texture.height * 8
    }
    public var s1CacheKey: String? { s1Entry?.key }

    /// 030: **one** 64 KB buffer, rewritten in place per changed table (§6.4).
    ///
    /// The old `lutBuffers: [String: …]` dictionary grew without bound — 16 KB per distinct curve
    /// key, and the curve panel would drag a new key onto it sixty times a second. One buffer plus
    /// four keys answers the same question with a bounded cost: compare four point lists, rebuild
    /// only the slices whose key moved, `copyMemory` 16 KB each.
    private var curveTablesCache: HDRCurveTableCache?

    /// 005e: the semantic routes (system matte, then Vision) and the in-memory raster cache of §5.2.
    /// The cache lives with the graph because its lifetime is the session's, and it is keyed by
    /// `contentHash + kind + modelVersion` — no disk, deliberately.
    private let semanticProvider: SemanticMatteProvider
    private let semanticStore: SemanticMatteStore
    /// One reusable array texture holding the resolved mattes, recreated only when the digests move.
    private var semanticTextureCache: (key: String, texture: MTLTexture)?
    /// A 1×1 stand-in bound when the document has no semantic component. Metal requires a texture at
    /// the binding even when the kernel never samples it.
    private var semanticDummyTexture: MTLTexture?

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

    public init(input: RenderInput, cacheBudgetBytes: Int = 1_500_000_000,
                semanticMatte: SemanticMatteProvider = SystemSemanticMatteProvider(),
                textureRetention: TextureRetention = .oneFrame,
                s1KeyIncludesRedGroup: Bool = true) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.noMetalDevice }
        self.device = device
        self.queue = queue
        self.deviceName = device.name
        self.kernels = KernelLibrary(device: device)
        self.input = input
        self.cacheBudgetBytes = cacheBudgetBytes
        self.s1KeyIncludesRedGroup = s1KeyIncludesRedGroup
        self.pool = TexturePool(device: device, retention: textureRetention)
        self.semanticProvider = semanticMatte
        self.semanticStore = SemanticMatteStore()
        // Orientation is applied here, once, before S0 sees a pixel (§11.2). `oriented()` is
        // identity for `.up`, so the pre-orientation path allocates nothing and its output is
        // byte-identical to before.
        self.orientation = input.image.orientation
        let upright = input.image.oriented()
        self.uprightImage = upright
        self.sourceSize = ImageSize(width: upright.width, height: upright.height)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: upright.width,
                                                            height: upright.height,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw RenderError.allocationFailed(sourceSize.keyString)
        }
        upright.rgba.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0, 0, upright.width, upright.height),
                        mipmapLevel: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: upright.width * 8)
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
        /// The whole cropped frame's own pixel grid at this render's `scale`. `RenderOptions.outputWindow`
        /// is expressed in it, and it is the frame every spatially normalized parameter belongs to.
        let frame: ImageSize
        /// The part of `frame` this render produces, or `nil` for the whole frame (the pre-window
        /// behaviour, and what every caller that does not name a window gets).
        let window: ImageRect?
        /// `frame` and `window.origin` in **content pixels** — the units S0/S1.5/S3c address a pixel
        /// in. They differ from `frame`'s own units only when letterboxing rescaled the content rect
        /// (`content < requested`), which is the same proportional squeeze the whole-frame path has
        /// always applied.
        let frameSize: SIMD2<Float>
        let frameOrigin: SIMD2<Float>
        /// `frame` in canvas pixels: what mask radii (feather, guided) normalize against (§4.6), so a
        /// feather keeps its physical size inside a window. Equal to `content` without a window, so
        /// the no-window path keeps 005d's exact numbers.
        let frameInCanvas: ImageSize
        /// The window reaches past the frame — the loupe's "let the picture leave the edge" camera.
        /// S0 writes **background** (`float4(0)`) where the window misses the picture instead of
        /// stretching the frame's edge texels outward, which is what bare clamp-to-edge would do.
        /// Always false for a window that names a rect inside the frame, so every pre-existing key,
        /// golden and edge-sample behaviour is untouched.
        let backgroundOutside: Bool
        let keys: StageKeys
        /// S0's two fast paths (029). Decided once, here, so the kernel's branch and the trace cannot
        /// disagree about which one a frame took.
        ///
        /// `s0Identity`: nothing to transform and no CA — copy texels, bit-exact.
        /// `s0PureCA`: nothing to transform **but** α ≠ 0 — the frame *is* the source pixel grid, so
        /// S0 hands `framePx` to the sampler directly instead of round-tripping through uv (which
        /// can lose an ulp at large sizes and would move green).
        let s0Identity: Bool
        let s0PureCA: Bool
        /// Where the photograph ended up **inside the canvas**, in canvas pixels, origin top-left
        /// (row 0 = texture row 0). One derivation, from the same `origin`/`frameOrigin`/`frameSize`
        /// S0 is handed — see `plan(_:_:)`. This is the rect a measurement of the frame's picture
        /// has to use; `origin + content` is only the same thing when the window does not reach past
        /// the frame.
        let drawnRect: ImageRect

        /// Seven stages, or nine when masks are active. Driven by the key set, so "does this
        /// document have masks" has exactly one answer on the whole render path.
        var stages: [RenderStage] { keys.pipeline }

        var isFullFrame: Bool { window == nil }

        /// The window as pixels, for the result and for the tests.
        var windowRect: ImageRect {
            window ?? ImageRect(x: 0, y: 0, width: frame.width, height: frame.height)
        }
    }

    private func plan(_ edit: EditModel, _ options: RenderOptions) -> Plan {
        // The aspect lock and the ±45 straighten limit are resolved here, once: S0 receives a plain
        // normalized rect plus cos/sin, exactly the shape it always had.
        let crop = edit.geometry.renderCrop(source: sourceSize)
        let cropPixels = CropMath.outputSize(crop, in: sourceSize)
        let scale = max(0.01, options.scale)
        // The frame: the full cropped picture at this scale. Its pixel grid is what a window indexes,
        // which is why the window is resolved after it and not before.
        let frame = ImageSize(width: Int((Double(cropPixels.width) * scale).rounded()),
                              height: Int((Double(cropPixels.height) * scale).rounded()))
        let whole = ImageRect(x: 0, y: 0, width: frame.width, height: frame.height)
        // A window covering the frame *is* no window: normalizing here means "1:1 on a picture smaller
        // than the viewport" shares the whole-frame key instead of minting one for a full-frame cut.
        //
        // A window that reaches **outside** the frame is not clamped into it — it is the loupe's
        // canvas-space camera (`LoupeFraming.windowSize` is the viewport at the zoom, unclipped), and
        // clamping it would silently re-frame the picture: the render would come back smaller than
        // the canvas and the canvas would letterbox it, which is a jump, not a crop. Those pixels are
        // background instead (`backgroundOutside`), and a window wholly inside the frame keeps the
        // `clamped(in:)` rule it has always had.
        let requestedWindow = options.outputWindow
        let backgroundOutside = requestedWindow.map { w in
            w.x < 0 || w.y < 0
                || w.x + w.width > frame.width || w.y + w.height > frame.height
        } ?? false
        let window = requestedWindow
            .map { backgroundOutside ? $0 : $0.clamped(in: frame) }
            .flatMap { $0 == whole ? nil : $0 }

        let requested = window.map { ImageSize(width: $0.width, height: $0.height) } ?? frame
        let canvas = options.canvas ?? requested
        let content = canvas == requested ? requested : ImageSize.fit(requested, in: canvas)
        let origin = SIMD2<Float>(Float((canvas.width - content.width) / 2),
                                  Float((canvas.height - content.height) / 2))

        // Content pixels per frame pixel: 1 unless letterboxing rescaled the content rect. Pre-scaling
        // the frame here is what lets the kernels stay one add and one divide per pixel.
        let kx = Float(Double(content.width) / Double(requested.width))
        let ky = Float(Double(content.height) / Double(requested.height))
        let frameSize = SIMD2<Float>(Float(frame.width) * kx, Float(frame.height) * ky)
        let frameOrigin = SIMD2<Float>(Float(window?.x ?? 0) * kx, Float(window?.y ?? 0) * ky)
        let frameInCanvas = window == nil ? content
            : ImageSize(width: Int((Double(frameSize.x)).rounded()),
                        height: Int((Double(frameSize.y)).rounded()))

        // Where the photograph was **drawn**, in canvas pixels — the one place this is worked out
        // (048).
        //
        // S0 writes content pixel `gid` at frame pixel `gid + 0.5 − origin + frameOrigin`
        // (`s0_geometry.metal`), so the frame (i.e. the photograph) occupies content pixels
        // `[−frameOrigin, frameSize − frameOrigin)` and canvas pixels
        // `origin − frameOrigin + frameSize` — origin top-left, row-major, the same space the texture
        // is read back in and `histogram_sample.metal` indexes. With no window, `frameOrigin == 0`
        // and this is exactly `origin + content`, which is what every pre-048 caller assumed; with a
        // window that reaches past the frame (`backgroundOutside`) the picture sits *off-centre*
        // inside `content` and the canvas holds background around it, so `origin + content` is the
        // window, not the picture, and measuring over it counts that background into bin 0.
        //
        // Clipped, not moved (`intersected(in:)`): the part of the picture outside the canvas was not
        // drawn, so it is not part of what a measurement can count.
        let pictureRaw = ImageRect(x: Int((origin.x - frameOrigin.x).rounded()),
                                   y: Int((origin.y - frameOrigin.y).rounded()),
                                   width: Int((Double(frameSize.x)).rounded()),
                                   height: Int((Double(frameSize.y)).rounded()))
        let drawnRect = pictureRaw.intersected(in: canvas)
        // The bounds assertion the派单 asks for, in the form that can fail loudly: a rect that is not
        // inside the canvas would let a measurement read someone else's pixels.
        assert(drawnRect.x >= 0 && drawnRect.y >= 0
               && drawnRect.maxX <= canvas.width && drawnRect.maxY <= canvas.height,
               "the picture's rect \(drawnRect) left the canvas \(canvas)")
        assert(canvas.width > 0 && canvas.height > 0, "a canvas with no pixels")

        let keys = RenderKeyChain.keys(RenderKeyChain.links(identity: input.identity,
                                                            sourceSize: sourceSize,
                                                            canvas: canvas,
                                                            content: content,
                                                            edit: edit,
                                                            display: options.display,
                                                            outputWindow: window,
                                                            orientation: orientation),
                                       identity: input.identity)
        // 029: S0's fast paths. "Nothing to transform" is the pre-029 identity condition; on top of
        // it, CA either keeps the frame the identity copy (α = 0) or needs the three-sample branch
        // with `framePx` taken directly (α ≠ 0). A CA document with a crop, a rotation or a scale
        // falls through to the general path — same `px` as before, only R/B from a scaled radius.
        let untransformed = crop == .full
            && edit.geometry.rotationDegrees == 0
            && !edit.geometry.flipHorizontal && !edit.geometry.flipVertical
            && content == sourceSize && canvas == sourceSize
            && window == nil
        let caOn = !edit.optics.isIdentity
        return Plan(canvas: canvas, content: content, origin: origin, crop: crop, frame: frame,
                    window: window, frameSize: frameSize, frameOrigin: frameOrigin,
                    frameInCanvas: frameInCanvas, backgroundOutside: backgroundOutside, keys: keys,
                    s0Identity: untransformed && !caOn,
                    s0PureCA: untransformed && caOn, drawnRect: drawnRect)
    }

    // MARK: - S1's key (073)

    /// 073 — the key of the linear pass: **everything S1 reads, and nothing else**.
    ///
    /// Two halves, and both are already the chain's own words:
    ///
    ///   · `plan.keys.geometry` — the decode identity (`DecodeInputs.key` + photo id), the source and
    ///     canvas sizes, EXIF orientation, the output window, and crop/straighten/flip/CA. This is S0's
    ///     key, and S1 reads S0's output, so it is S1's input too: a crop or a zoom miss is a different
    ///     buffer, not a cache the linear pass may serve from.
    ///   · `edit.keyMaterial(.sceneLinear)` — the levels (`blk`/`wht` sliders, `blackLevel`,
    ///     `whiteLevel`), 071's `blackOffset`, the exposure gain, white balance (a decode input, so the
    ///     identity moves with it) and highlight recovery.
    ///
    /// **What is deliberately absent** is everything from S1.6 down — mask adjustments, the curve, the
    /// tone map's contrast/highlights/shadows, colour, vignette, display — which is why a blue step
    /// reaches this texture instead of re-deriving the linear domain.
    ///
    /// One honest caveat, and it is a fact about where the arithmetic lives rather than about the
    /// cache: the **exposure**, **whites**, **blacks** and **highlight recovery** sliders are blue in
    /// the inspector (they belong to the render, not to the decode) but their arithmetic is inside S1
    /// (`s1_scene_linear.metal` ①②③). Moving them out of the key would serve a stale frame — that is
    /// exactly what `testRedGroupIsLoadBearing` demonstrates — so they are in it, and a step of one of
    /// those sliders costs one S1 pass. `S1CacheTests` prints the measured cost of both kinds.
    ///
    /// `s1KeyIncludesRedGroup: false` (tests only) deletes the red half — the sliders, the two absolute
    /// levels and the trim — from the material, which is the refutation 073 asks for.
    private func s1Key(_ edit: EditModel, _ plan: Plan) -> String {
        guard !s1KeyIncludesRedGroup else { return plan.keys.key(for: .sceneLinear) }
        var stripped = edit
        stripped.light.blacks = 0
        stripped.light.whites = 0
        stripped.light.blackOffset = 0
        stripped.light.blackLevel = nil
        stripped.light.whiteLevel = nil
        // The same two-step construction `RenderKeyChain.links` + `keys` use, so the neutral red group
        // is the *only* difference: `H(geometryKey | material)` and then the digest.
        let canonical = KeyBuilder(plan.keys.geometry)
            .add(stripped.keyMaterial(.sceneLinear))
            .canonical
        return KeyBuilder.digest(of: canonical)
    }

    // MARK: render

    /// Render the document, or — with `options.source == .decoded` — the **decode** it was developed
    /// from (080: 「显示原图」, see `RenderSource`).
    ///
    /// The two sources are one function on purpose: everything downstream (the pool, the stage cache,
    /// the readback, the histogram plumbing) is the same machinery, and the only difference is which
    /// document reaches the plan and which stages the plan visits. `.decoded` resolves the document to
    /// `disregardingGeometry` — so S0 crops nothing, turns nothing and flips nothing — and visits
    /// `[.geometry, .display]`, i.e. the decode, display-encoded.
    ///
    /// Nothing here can write to `edit`: the resolution is a copy.
    public func render(_ edit: EditModel, options: RenderOptions = RenderOptions()) throws -> RenderResult {
        let document: EditModel
        switch (options.source, options.originalRendersAsParametersCleared) {
        case (.decoded, false):
            // The shipped spelling: the decode, i.e. the document with no geometry at all.
            document = edit.disregardingGeometry
        case (.decoded, true):
            // The refutation's spelling: 「参数清零后的渲染」 — geometry kept, every parameter zeroed.
            document = edit.disregardingParameters
        case (.edited, _):
            document = edit
        }
        return try renderResolved(document, options: options)
    }

    private func renderResolved(_ edit: EditModel, options: RenderOptions) throws -> RenderResult {
        // P1b: a graph that retains nothing (`textureRetention: .none`) keeps its idle list only for
        // the duration of one frame — that list is the frame reusing itself (see `oneShotChurn`), not
        // a cache for the next one. Released here, on every exit, including a throw.
        defer { if pool.retainsNothing { pool.releaseIdle() } }
        // P1b — whether a stage's input may go back to the pool as soon as the next stage has been
        // encoded. Two cases want it, for the same reason: nothing else is holding the texture, so
        // leaving it in the frame's `transient` list until the commit is what makes a frame hold
        // eleven intermediates instead of two.
        //
        //   · `.none` retention — the export's pool, which keeps nothing past the frame;
        //   · a cacheless frame **whose textures are big enough for it to pay** — see
        //     `TexturePool.eagerRecycleFloorBytes`. At 60 Mpx it is worth 41 % of the frame
        //     (p05 151 → 89 ms: without it every stage pays a 483 MB `makeTexture`); at 4.10 Mpx it
        //     is not, because a 32.8 MB allocation is cheaper than the barrier that reusing the
        //     texture forces between two passes (p50 8–13 ms vs 6.2 ms cold, p05 equal).
        // 080: the decode path. `true` for the shipped spelling; the test hook
        // (`originalRendersAsParametersCleared`) turns it off and renders the whole pipeline of the
        // parameters-cleared document instead, which is the refutation.
        let decodeOnly = options.source == .decoded && !options.originalRendersAsParametersCleared
        let plan = plan(edit, options)
        let recyclesEachStage = pool.retainsNothing
            || (!options.useCache && plan.canvas.pixelCount * 8 >= TexturePool.eagerRecycleFloorBytes)
        var trace = RenderTrace()
        trace.s0PureCA = plan.s0PureCA
        // 005e: the semantic mattes are resolved before the table is built, because a semantic
        // component's descriptor carries the slice index of its raster. The resolution is cached
        // (contentHash + kind + modelVersion), so this is free on every frame but the first.
        let semantics = resolveSemantics(edit)
        // The radii normalize to the frame, not to the visible window: a feather is 10 % of the
        // *picture's* short edge, so 1:1 must not soften differently from fit (§4.6).
        //
        // 080: the decode path has no mask stage at all, so it neither builds a table nor releases
        // the cached atlas — a `\` frame must leave every cache exactly as it found it, or leaving
        // 原图 would pay for an atlas rebuild it did not cause (`BeforeAfterUITests`).
        let table = decodeOnly ? nil : try maskTable(for: edit, content: plan.frameInCanvas, semantics: semantics)
        if !decodeOnly, table == nil { atlasCache = nil }

        // 005d: the tiling material joins the two mask keys. A local-stage texture computed under a
        // different tile lattice (or with a different declared halo) must never be reused as this
        // frame's output — `TileDependency` is a promise about *pixels*, and a promise belongs in the
        // key, not only in a comment. Off (the 005c path) leaves both keys byte-identical.
        let tilingSuffix = maskTilingSuffix(options: options, table: table)
        // 005e: what the OS answered is environment, not document — so it cannot enter the document's
        // key material. It enters the *stage* key instead, exactly like the tiling suffix: two frames
        // whose mattes differ must never share a cached atlas.
        let semanticSuffix = semantics.keyMaterial.isEmpty
            ? "" : "|" + KeyBuilder.digest(of: semantics.keyMaterial)
        var report: MaskStageReport? = table == nil ? nil : MaskStageReport()
        report?.semanticEvents = semantics.events

        guard let cb = queue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }

        var current = sourceTexture
        var transient: [MTLTexture] = []
        /// P1b — the one-shot recycle chute. When the pool retains nothing (an export), a stage's
        /// input goes back to the pool **the moment the next stage has been encoded**, instead of at
        /// the end of the frame: a 60 Mpx export then holds two 483 MB frame textures rather than
        /// eleven (5.3 GB). Reuse inside one command buffer is already what the cache-eviction path
        /// does on this canvas — Metal's tracked hazards order the write after the read — so this
        /// changes which texture object holds a stage's result, never the arithmetic that produced it.
        var currentIsTransient = false
        var finish: MTLTexture?
        /// Set when `collectHistogram` asks: the texture S4 read, i.e. the scene-linear picture.
        var histogramSource: MTLTexture?

        // 080: the decode path visits S0 and S4 and nothing between them. `plan.stages` is the
        // document's pipeline (seven, or nine-plus with masks); the decode is the two passes that
        // stand either side of every tone, colour and effect stage.
        let stages: [RenderStage] = decodeOnly ? [.geometry, .display] : plan.stages
        for stage in stages {
            // The environment suffix has to reach **every** stage the atlas feeds, not just the two
            // mask stages: the document's key chain cannot know that a matte appeared (it is not in
            // the document), so a downstream cache hit would otherwise hand back a frame computed
            // from a different selection.
            let key = plan.keys.key(for: stage)
                + (stage.isMaskStage ? tilingSuffix : "")
                + (stage.index >= RenderStage.maskAtlas.index ? semanticSuffix : "")

            // 073 — S1 has a slot of its own (see `S1Entry`), so the linear pass is decided here
            // rather than by the generic stage cache below. The key is `s1Key`, i.e. decode identity ×
            // geometry × **everything S1 reads** — a blue slider moves nothing in it, so those frames
            // reach S1's texture and skip the pass; a red one moves `boff`/`blL`/`whL` and misses.
            if stage == .sceneLinear {
                let s1Key = self.s1Key(edit, plan)
                if options.useCache, let e = s1Entry, e.key == s1Key,
                   e.texture.width == plan.canvas.width, e.texture.height == plan.canvas.height {
                    trace.record(stage, executed: false)
                    current = e.texture
                    currentIsTransient = false
                    continue
                }
                let out = try pool.obtain(plan.canvas)
                let consumed = current
                let consumedIsTransient = currentIsTransient
                try encode(stage, cb: cb, into: out, from: current, edit: edit, plan: plan,
                           options: options, table: table, report: &report)
                trace.record(stage, executed: true)
                // P1b: S1's input is consumed — a one-shot graph gives it back before the next
                // `obtain`, so the export's frame textures do not accumulate.
                if recyclesEachStage, consumedIsTransient { pool.recycle(consumed) }
                if options.useCache {
                    // The old texture goes back **after** the new one is in hand, so a failed
                    // allocation cannot leave the slot pointing at a recycled texture.
                    if let old = s1Entry, old.texture !== out { pool.recycle(old.texture) }
                    s1Entry = S1Entry(key: s1Key, texture: out)
                    currentIsTransient = false
                } else {
                    if !recyclesEachStage { transient.append(out) }
                    currentIsTransient = true
                }
                current = out
                continue
            }

            // S1.6 keeps its own slot (like the atlas) because it can be updated **in place**: the
            // same texture, a smaller dispatch. A plain stage-cache entry cannot express that.
            if stage == .localApply {
                guard let table, let atlas = atlasCache else {
                    throw RenderError.executeFailed("local stage without an atlas")
                }
                let atlasKey = plan.keys.key(for: .maskAtlas) + tilingSuffix + semanticSuffix
                let localKey = plan.keys.key(for: .localApply) + tilingSuffix + semanticSuffix
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
                    currentIsTransient = false
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
                    currentIsTransient = false
                    continue
                }

                // (c) cold: a full pass, or a tiled pass over a fresh texture with the source copied
                // in first (the `.load` that makes the untouched pixels right).
                let out = try pool.obtain(plan.canvas)
                let consumed = current
                let consumedIsTransient = currentIsTransient
                let tilePlan = localTilePlan(edit: edit, plan: plan, options: options)
                try encodeLocal(cb: cb, into: out, from: current, atlas: atlas.texture,
                                table: table, tilePlan: tilePlan, blitSource: tilePlan.tiled)
                trace.record(stage, executed: true)
                if report != nil { report?.localPlan = tilePlan }
                if recyclesEachStage, consumedIsTransient { pool.recycle(consumed) }
                if options.useCache {
                    if let old = localEntry, old.texture !== out { pool.recycle(old.texture) }
                    localEntry = LocalEntry(atlasKey: atlasKey, applyKeys: applyKeys, key: localKey,
                                            texture: out, bounds: localBounds(edit: edit, plan: plan))
                    currentIsTransient = false
                } else {
                    if !recyclesEachStage { transient.append(out) }
                    currentIsTransient = true
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
                                                  plan: plan, edit: edit, semantics: semantics)
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
                currentIsTransient = false
                continue
            }

            // The histogram reads what S4 is about to read: scene-linear RGB after S2/S3, before the
            // primaries matrix, the transfer function and the headroom clamp. Captured here rather
            // than looked up afterwards because S4's output is the only texture a caller ever sees.
            if stage == .display, options.collectHistogram || options.histogramSampleLongEdge > 0 {
                histogramSource = current
            }

            let out = try pool.obtain(plan.canvas)
            let consumed = current
            let consumedIsTransient = currentIsTransient
            try encode(stage, cb: cb, into: out, from: current, edit: edit, plan: plan,
                       options: options, table: table, report: &report)
            trace.record(stage, executed: true)
            // `histogramSource` is read **after** the commit, so the texture S4 read cannot go back to
            // the pool yet: the mask overlay below is the same canvas and an `obtain` would hand this
            // very texture back to be overwritten (which would measure the overlay, not the picture).
            let readAfterCommit = histogramSource.map { $0 === consumed } ?? false
            if recyclesEachStage, consumedIsTransient, !readAfterCommit { pool.recycle(consumed) }

            if options.useCache && stage != .display {
                insertCache(stage, key: key, texture: out)
                currentIsTransient = false
            } else if stage != .display {
                if !recyclesEachStage { transient.append(out) }
                currentIsTransient = true
            } else {
                currentIsTransient = false
            }
            current = out
            if stage == .display { finish = out }
        }

        // 005e — `showMask`, the atlas's second exit (§3.1). One pointwise pass on the display-encoded
        // frame, reading the slice S1.6 consumed. When no id is set — or the id names no enabled mask
        // — nothing is encoded and `finish` is the frame the document produced, byte for byte.
        var showsMask = false
        if !decodeOnly, let wanted = edit.showMaskID, let atlas = atlasCache, let shown = finish,
           let slice = atlas.ids.firstIndex(of: wanted) {
            let overlay = try pool.obtain(plan.canvas)
            let p = try kernels.pipeline(file: "s4_show_mask", function: "s4_show_mask")
            guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            enc.setComputePipelineState(p)
            enc.setTexture(shown, index: 0)
            enc.setTexture(atlas.texture, index: 1)
            enc.setTexture(overlay, index: 2)
            var params = ShowMaskParams(a: SIMD4(Int32(slice), 0, 0, 0),
                                        b: SIMD4(0.5, 1, 0, 0))
            enc.setBytes(&params, length: MemoryLayout<ShowMaskParams>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()
            // The display texture is never a cache entry (`render` skips the cache for `.display`),
            // so recycling it here is what keeps the pool honest.
            pool.recycle(shown)
            finish = overlay
            showsMask = true
            report?.showMaskID = wanted
            report?.showMaskSlice = slice
        }

        // MARK: the histogram's sample (005, 2026-10-26: the picture, before the display transform)
        //
        // The measurement reads the texture S3 wrote -- `current` on the way into S4 -- and never the
        // frame S4 produced. That one choice is what makes the plot screen-independent: S4 applies the
        // primaries matrix, the transfer function and the headroom clamp in a single pass, and all
        // three are properties of a *panel*. Measuring its input means an SDR screen can still see that
        // a picture has three stops of highlight above white, and that two panels with different
        // headroom get the same bins.
        //
        // Nothing here runs when `collectHistogram` is false: no readback, no texture, so the frame is
        // byte-for-byte and cycle-for-cycle the pre-005f frame. When it does run it costs one readback
        // of the frame's own pre-S4 texture; the *size* of that texture is the caller's business, and
        // `measureHistogram` makes it a thumbnail.
        //
        // The region is the picture inside the canvas, never the canvas: a canvas whose aspect differs
        // from the picture's has matte bars, and a histogram of the matte is a histogram of the output
        // *surface* -- bin 0 collects every black bar, so 削底 reads 30 % on a photo with no blacks at
        // all. `plan.origin + plan.content` is the whole canvas exactly when there is no letterboxing.

        // 070 — the measured grid, encoded **here** rather than read back afterwards.
        //
        // The pre-S4 texture is a transient: the commit below is the last moment anything can be
        // sampled from it, and a frame is far too big to read back whole (33 MB of half float at
        // 4.10 Mpx, per frame, inside a slider drag). So the stride read happens on the GPU in this
        // frame's own command buffer, into a ≤ 256-long-edge grid, and the CPU counts that: one extra
        // dispatch of 36 k threads and 0.29 MB of readback, which is what the card can afford on every
        // frame that changes the picture.
        var sampleGrid: (texture: MTLTexture, size: ImageSize)?
        if options.histogramSampleLongEdge > 0,
           let source = histogramSource, !plan.drawnRect.isEmpty {
            let picture = plan.drawnRect
            let grid = Histogram.frameSampleSize(for: picture,
                                                 longEdge: options.histogramSampleLongEdge)
            let texture = try pool.obtain(grid)
            let pipeline = try kernels.pipeline(file: "histogram_sample",
                                                function: "histogram_sample_linear")
            guard let enc = cb.makeComputeCommandEncoder() else {
                pool.recycle(texture)
                throw RenderError.commandBufferFailed
            }
            enc.setComputePipelineState(pipeline)
            enc.setTexture(source, index: 0)
            enc.setTexture(texture, index: 1)
            // The same arithmetic `measureFrameHistogram` uses for its grid, so the two sample the
            // same texel of the same rect: `(i + 0.5) · step`, origin added once.
            var params = HistSampleParams(
                a: SIMD4(Float(picture.x), Float(picture.y),
                         Float(picture.width), Float(picture.height)),
                b: SIMD4(Float(Double(picture.width) / Double(grid.width)),
                         Float(Double(picture.height) / Double(grid.height)),
                         Float(grid.width), Float(grid.height)))
            enc.setBytes(&params, length: MemoryLayout<HistSampleParams>.stride, index: 0)
            dispatch(enc, pipeline, grid)
            enc.endEncoding()
            sampleGrid = (texture, grid)
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
        // 073 — the per-stage counters, merged from the frame's own trace so the two can never
        // disagree about what this frame ran (`s1Passes` and `s1_6Passes` are read by S1CacheTests).
        for stage in trace.executed { stageRuns[stage, default: 0] += 1 }
        for stage in trace.skipped { stageHits[stage, default: 0] += 1 }

        // The measurement's one readback, of the pre-S4 texture — read *before* the transients go back
        // to the pool, so what is counted is the texture this frame wrote and not whatever the pool
        // hands out next. The CPU then counts its pixels: at the thumbnail scale `measureHistogram`
        // asks for, that is ~0.58 Mpx, not 4.10 M — let alone the 60 M of a full export.
        var histogramPayload: Histogram?
        var histogramMilliseconds = 0.0
        /// The grid itself, kept when one was built: the pointer's readout asks it for the texel under
        /// the cursor (2026-10-27). 0.29 MB for a 256-long-edge grid — the frame texture beside it is
        /// 33 MB, so this is the cheap half of a frame.
        var histogramSample: LinearSample?
        if let source = histogramSource {
            let bins = min(max(options.histogramBins, 2), 1 << 16)
            // The picture, from the layout S0 actually drew with — not the content rect, which holds
            // background around a window that reaches past the frame (048).
            let picture = plan.drawnRect
            if let grid = sampleGrid {
                // The readback happens even for a frame nothing measures: a pan changes the camera and
                // not the picture, so no key moves and no plot is updated — but the pixels under the
                // pointer did move, and the readout has to follow them.
                let tSample = CFAbsoluteTimeGetCurrent()
                let sample = readSample(grid.texture)
                histogramSample = sample
                if options.collectHistogram {
                    // 070: the picture's own pixels, sampled off the scene-linear texture (not S4's
                    // clamped output, which cannot hold anything above the panel's headroom).
                    // Labelled with the **picture's** own grid, exactly as `measureFrameHistogram`
                    // labels its numbers, so the card's canvas/ROI and 「采样 N px」 mean the same thing
                    // whichever path measured: the render's canvas is a viewport (or a backdrop's
                    // 4096), and neither is the picture.
                    let pixels = CropMath.outputSize(edit.geometry.renderCrop(source: sourceSize),
                                                     in: sourceSize)
                    let own = ImageRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
                    histogramPayload = Histogram.compute(sample, bins: bins, rect: nil,
                                                         headroom: options.display.headroom)
                        .relabelled(canvas: pixels, roi: own)
                    histogramMilliseconds = (CFAbsoluteTimeGetCurrent() - tSample) * 1000
                }
                pool.recycle(grid.texture)
            } else if options.collectHistogram {
                let sample = readSample(source)
                histogramPayload = Histogram.compute(sample, bins: bins, rect: picture,
                                                     headroom: options.display.headroom)
                    .relabelled(canvas: plan.canvas, roi: picture)
            }
        }

        for t in transient { pool.recycle(t) }


        guard let finalTexture = finish else { throw RenderError.executeFailed("no display output") }

        if options.wantsPixels {
            let pixels = readback(finalTexture, primaries: options.display.primaries, bitDepth: options.display.bitDepth)
            pool.recycle(finalTexture)
            return RenderResult(canvas: plan.canvas, content: plan.content,
                                drawnRect: plan.drawnRect,
                                window: plan.windowRect, keys: plan.keys,
                                trace: trace, display: pixels, output: nil, maskReport: report,
                                showsMask: showsMask, histogram: histogramPayload,
                                histogramMilliseconds: histogramMilliseconds,
                                histogramSample: histogramSample)
        }
        return RenderResult(canvas: plan.canvas, content: plan.content,
                            drawnRect: plan.drawnRect,
                            window: plan.windowRect, keys: plan.keys,
                            trace: trace, display: nil, output: finalTexture, maskReport: report,
                            showsMask: showsMask, histogram: histogramPayload,
                            histogramMilliseconds: histogramMilliseconds,
                            histogramSample: histogramSample)
    }

    /// Return a texture handed out by `render(..., wantsPixels: false)`.
    public func recycle(output: MTLTexture) {
        pool.recycle(output)
    }

    // MARK: - 080: the 前后对比 composite

    /// Two display-encoded frames, one canvas, split at a draggable line.
    ///
    /// - Parameters:
    ///   - original: the decode (`RenderSource.decoded`) — left / top of the line.
    ///   - edited: the document (`RenderSource.edited`) — right / bottom.
    ///   - split: where the line is and which way it runs. Its `dividerPixel(canvas:)` is what the
    ///     kernel receives, so a pixel's owner is the same answer here and in
    ///     `CompareSplit.side(x:y:canvas:)`.
    ///
    /// The result is a texture of the **same canvas**, from the same pool every frame comes from, so
    /// the loupe presents it through the one present path it already has. Nothing is cached, nothing
    /// is keyed, and no document is read: this pass runs *after* both renders exist, which is the
    /// whole reason entering, dragging and leaving 对比 cannot move a stage key or a history row.
    ///
    /// Hand the result back with `recycle(output:)` like any other frame.
    public func composite(original: MTLTexture, edited: MTLTexture,
                          split: CompareSplit) throws -> MTLTexture {
        guard original.width == edited.width, original.height == edited.height else {
            throw RenderError.executeFailed(
                "compare needs two frames of one canvas, got "
                + "\(original.width)×\(original.height) and \(edited.width)×\(edited.height)")
        }
        let canvas = ImageSize(width: edited.width, height: edited.height)
        let out = try pool.obtain(canvas)
        do {
            guard let cb = queue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
            let pipeline = try kernels.pipeline(file: "s5_before_after", function: "s5_before_after")
            guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            enc.setComputePipelineState(pipeline)
            enc.setTexture(original, index: 0)
            enc.setTexture(edited, index: 1)
            enc.setTexture(out, index: 2)
            let numbers = split.compareParams(canvas: canvas)
            var params = CompareParams(a: SIMD4<Float>(numbers.divider, numbers.axis,
                                                       numbers.lineWidth, 0))
            enc.setBytes(&params, length: MemoryLayout<CompareParams>.stride, index: 0)
            dispatch(enc, pipeline, canvas)
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            if let error = cb.error { throw RenderError.executeFailed(error.localizedDescription) }
            return out
        } catch {
            pool.recycle(out)
            throw error
        }
    }

    /// The histogram of the **whole picture**, independent of the camera and of the panel.
    ///
    /// One thumbnail render (long edge ≤ `Histogram.maxLongEdge`) plus one readback of the texture S3
    /// produced, then the CPU counts ~0.58 Mpx. Nothing about it depends on a viewport, a window, a
    /// zoom or a display: the same photo and the same edit give the same bins at fit, at 1:1 and at
    /// 400 %, and a `headroom` change moves `clippedCeiling` alone.
    ///
    /// Deliberately its own render rather than a dispatch inside a frame's command buffer: a frame is
    /// the *window* the camera is showing, and one measurement per picture has to be of the picture.
    /// The cost is the whole pipeline at 1/7 of the pixels of a 4.10 Mpx frame (0.58 M), once per edit;
    /// `HistogramTests` prints the milliseconds.
    ///
    /// `useCache: false` on purpose — the stage cache is keyed by canvas, so a thumbnail render's
    /// entries could only evict the frame's own; the pool still recycles every texture.
    public func measureHistogram(_ edit: EditModel, bins: Int = 256,
                                 headroom: Double = 1) throws -> Histogram {
        let cropPixels = CropMath.outputSize(edit.geometry.renderCrop(source: sourceSize),
                                             in: sourceSize)
        let picture = ImageRect(x: 0, y: 0, width: cropPixels.width, height: cropPixels.height)
        let options = RenderOptions(
            scale: Histogram.sampleScale(for: cropPixels),
            // `headroom` reaches the counters, not the pixels: S4's ceiling cannot move a bin any
            // more, it only decides what `clippedCeiling` reports for this screen.
            display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: headroom),
            useCache: false, wantsPixels: false,
            collectHistogram: true, histogramBins: bins)
        let result = try render(edit, options: options)
        if let texture = result.output { recycle(output: texture) }
        guard let measured = result.histogram else {
            return Histogram.empty(bins: bins, canvas: cropPixels, roi: picture, headroom: headroom)
        }
        // The sample *is* the picture, so the reported region is the picture's own pixel grid: that is
        // the denominator 「采样 N px」 stands against, and it is the same number at every zoom.
        return measured.relabelled(canvas: cropPixels, roi: picture)
    }

    // MARK: - 027: the histogram of the frame that was just drawn
    //
    // The measurement above renders the picture a second time, at thumbnail scale, because a
    // histogram of *the picture* has to be independent of the camera. That costs ~11 ms, so the card
    // could only afford it once an edit had settled (a 120 ms debounce), and a slider drag therefore
    // moved the picture while the plot stood still.
    //
    // This one reads the frame S4 has **already written** — the texture the caller is about to put on
    // screen — so the only work it adds to a frame is a stride read of a few thousand texels, one
    // small readback and the CPU binning. That is affordable *every* frame, which is what makes the
    // plot track a drag.
    //
    // ## What it measures, and how it differs from the shipped path
    //
    // The frame is **display-referred**: S4 applied the primaries matrix, the sRGB OETF and the
    // `min(v, headroom)` clamp, and the only thing a caller can hand back is that result. The shipped
    // path samples the texture *before* S4 instead (scene-linear, see `Histogram`), so the two are
    // not the same domain, and that difference is worth stating exactly:
    //
    //   · **Below white they agree.** S4's code is `srgbEncode(v)`, which is the axis `Histogram`
    //     derives per sample (`combinedIndex`): the SDR bins are the same statistic of the same
    //     pixels, not an approximation of it. `computeEncoded` is used on purpose — decoding the code
    //     and re-encoding it would move a value that sits exactly on a bin edge (0.5 of code comes
    //     back 0.4999997 and lands a bin low), which is a bug this file has already had once.
    //   · **Above white they agree only if the frame had headroom.** With `headroom = 1` S4 clamps
    //     everything above white to code 1.0, so the tail is *gone*: those samples are counted in the
    //     last SDR bin (as the shipped path also counts a clipped sample there) but they cannot be
    //     placed on the 1/64-stop axis, and `hdrBins` is empty. With `headroom > 1` the codes above
    //     1.0 survive, and `computeEncoded` decodes them back to the same tail bins the shipped path
    //     reports. So a picture with highlights above white measures the same in an EDR frame and
    //     reads "clipped" in an SDR one — which is the honest answer to "what does this screen have".
    //   · **Half float rounds the code.** The frame stores codes as `Float16`; the shipped path bins
    //     the `Float` the OETF produced. A value within half an ULP of a bin edge (≈0.00012 of code
    //     near 0.5, i.e. ~3 % of a bin's width) can land one bin over. `HistogramSampleTests` prints
    //     the actual per-bin difference rather than claiming zero.
    //
    // Luma is the one series a display-referred sample cannot derive from its three codes and still
    // match: the shipped path weights **linear** light and encodes the sum, while `Σw·code` is a
    // different number (the OETF is concave, so the code-space mean sits below it — up to ~0.02 of code
    // near white, which is five bins). So the sample kernel computes the shipped definition itself and
    // carries it in the texture's unused alpha channel; `Histogram.computeFrameSample` reads it. Four
    // `pow`s per sample texel on the GPU (36 k threads) instead of on the CPU inside a frame budget.
    // With that, all four series are the *same statistic* as the shipped measurement on the same
    // pixels, and the tail is the only thing the frame cannot carry.
    //
    // ## The sample
    //
    // `histogram_sample` reads one texel per output texel on a deterministic stride
    // (`(i + 0.5) · step`), from the **picture's rect inside the frame** — never from a centred patch,
    // which would be a systematic bias rather than a cheaper measurement. `ImageSize`-fitted to a
    // 256-texel long edge, so a 4.10 Mpx frame becomes 141×256 = 36 k samples and the readback is
    // 0.29 MB instead of the frame's 33 MB. Stride sampling is not a box filter, and that is the
    // point: the sample is an unbiased estimate of the distribution instead of 36 k local means
    // (which would pull every sample toward its neighbourhood and flatten the ends of the plot).
    //
    // The matte is excluded without being told where it is: the plan letterboxes a picture into a
    // canvas of a different aspect, and `framePictureRect` accepts the `fit` hypothesis only when the
    // band outside it is measurably matte (exactly 0 in all three channels). Bin 0 collecting every
    // matte pixel would report 30 % blacks on a photo with none.
    //
    // ## Determinism
    //
    // Same frame + same edit + same bins → the same texels, the same bytes, the same bins, in this
    // process and the next: the step is an integer ratio computed in `double` and narrowed once, and
    // the index is a `floor`. Nothing here depends on a seed, a clock or the order of dispatch.
    //
    // Call it from the thread that renders — the graph owns one command queue and one texture pool,
    // so it is not safe to measure from two threads at once (no renderer in this app does).

    /// What one `measureFrameHistogram` cost, in the units the acceptance numbers are quoted in.
    public struct FrameHistogramCost: Sendable {
        /// The grid the frame was reduced to (`≤ 256` on the long edge by default).
        public var sampleSize = ImageSize(width: 0, height: 0)
        /// Bytes read back: `sampleSize.pixelCount × 8` (rgba16Float).
        public var readbackBytes = 0
        /// The downsample pass alone, from the command buffer's own GPU timestamps.
        public var gpuMilliseconds: Double = 0
        /// The CPU binning of the readback.
        public var cpuMilliseconds: Double = 0
        /// Dispatch → wait → binning, as the caller experiences it.
        public var wallMilliseconds: Double = 0
    }

    /// One frame measurement: the plot, the samples it came from, and what it cost.
    ///
    /// `sample` is the downsampled, display-encoded grid itself — the exact bytes the CPU counted, so
    /// "two calls are byte-identical" is checkable with `sample.sha256()`, and so a test can re-count
    /// them to separate a binning bug from a sampling one. **Its alpha is not alpha**: the kernel
    /// spends that channel on the luma (`Histogram.computeFrameSample`), so a recount must use
    /// `Histogram.computeFrameSample(sample, rect: rect)`, not `computeEncoded`.
    public struct FrameMeasurement: Sendable {
        public let histogram: Histogram
        public let sample: DisplayImage
        /// The region of `sample` the bins were counted over — the picture, i.e. `sample` minus any
        /// letterbox band.
        public let rect: ImageRect
        public let cost: FrameHistogramCost
    }

    /// Measure the histogram of a frame that has **already been rendered** (see the note above).
    ///
    /// - Parameters:
    ///   - texture: the frame S4 wrote — `RenderResult.output`, or the texture the loupe is showing.
    ///   - edit: the document the frame was rendered with; it is what says how big the picture is
    ///     (for the `canvas`/`roi` the numbers are labelled with) and where a letterbox band would be.
    ///   - content: the picture's rect **inside `texture`**, in texture pixels — origin **top-left,
    ///     row 0 = the texture's first row**, the same space S0 writes (`gid`) and the sample kernel
    ///     reads (`src.read`). `RenderResult.drawnRect` is this rect exactly, and is what a caller
    ///     that drew the frame should pass. `nil` → the whole texture, with a matte band detected and
    ///     excluded if one is there. Passing it skips the probe and samples the picture's own pixels,
    ///     which is the right call for any letterboxed frame. A rect that hangs off the texture is
    ///     clipped to it (`PixelRect.intersected(in:)`), and one that misses the texture entirely
    ///     measures nothing rather than crashing.
    ///   - sampleLongEdge: long edge of the sampled grid; the default is the 0.29 MB one.
    ///   - headroom / primaries: what the frame was rendered with (`RenderOptions.display`), so the
    ///     ceiling ratio and the colour space the codes are in are labelled truthfully.
    ///
    /// **A frame is a window, so this measures what the window shows.** At fit the canvas holds the
    /// whole picture and the plot is the picture's; at 1:1 or 400 % the frame holds a crop and so does
    /// the plot — the pixels outside it are not in the texture and nothing can recover them
    /// (`Histogram.sampleFraction` then reads far below the grid's own share of the picture, which is
    /// the tell). A caller that must plot the picture should measure only frames that contain it, and
    /// use the shipped `measureHistogram(_:bins:headroom:)` for the settled reading.
    public func measureHistogram(fromFrame texture: MTLTexture, edit: EditModel,
                                 bins: Int = 256,
                                 content: ImageRect? = nil,
                                 sampleLongEdge: Int = Histogram.frameSampleLongEdge,
                                 primaries: OutputPrimaries = .sRGB,
                                 headroom: Double = 1) throws -> Histogram {
        try measureFrameHistogram(fromFrame: texture, edit: edit, bins: bins, content: content,
                                 sampleLongEdge: sampleLongEdge, primaries: primaries,
                                 headroom: headroom).histogram
    }

    /// The same measurement, with the receipts (`cost`, and the bytes that were counted).
    public func measureFrameHistogram(fromFrame texture: MTLTexture, edit: EditModel,
                                      bins: Int = 256,
                                      content: ImageRect? = nil,
                                      sampleLongEdge: Int = Histogram.frameSampleLongEdge,
                                      primaries: OutputPrimaries = .sRGB,
                                      headroom: Double = 1) throws -> FrameMeasurement {
        let tStart = CFAbsoluteTimeGetCurrent()
        let canvas = ImageSize(width: texture.width, height: texture.height)
        guard texture.pixelFormat == .rgba16Float else {
            throw RenderError.executeFailed(
                "the frame histogram reads a display-encoded rgba16Float frame, got pixelFormat "
                + "\(texture.pixelFormat.rawValue)")
        }
        // The picture's own pixel grid: the denominator 「采样 N px」 stands against, and the same
        // number the shipped path reports, so the two plots are labelled in one coordinate system.
        let cropPixels = CropMath.outputSize(edit.geometry.renderCrop(source: sourceSize),
                                             in: sourceSize)
        let binCount = min(max(bins, 2), 1 << 16)
        // The rect as a *description of where the picture was drawn*, so clipping is an intersection
        // and not a move (048): `clamped(in:)` would slide a picture that hangs off the edge back to
        // 0 and then measure whatever is there instead. An empty result means nothing of the picture
        // is in this texture — early out before the grid arithmetic, which divides by these numbers.
        let rect = (content ?? ImageRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            .intersected(in: canvas)
        guard !rect.isEmpty else {
            return FrameMeasurement(
                histogram: Histogram.empty(bins: binCount, canvas: cropPixels,
                                           roi: ImageRect(x: 0, y: 0, width: 0, height: 0),
                                           primaries: primaries, headroom: headroom),
                sample: DisplayImage(width: 1, height: 1, rgba: [0, 0, 0, 0],
                                     primaries: primaries, bitDepth: 16),
                rect: ImageRect(x: 0, y: 0, width: 0, height: 0),
                cost: FrameHistogramCost())
        }
        let grid = Histogram.frameSampleSize(for: rect, longEdge: sampleLongEdge)

        let sample = try pool.obtain(grid)
        defer { pool.recycle(sample) }

        let pipeline = try kernels.pipeline(file: "histogram_sample", function: "histogram_sample")
        guard let cb = queue.makeCommandBuffer() else { throw RenderError.commandBufferFailed }
        guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(texture, index: 0)
        enc.setTexture(sample, index: 1)
        // The step is a ratio of integers taken through `double` and narrowed once: the same frame
        // and grid choose the same source texels in every process (see the note above).
        var params = HistSampleParams(
            a: SIMD4(Float(rect.x), Float(rect.y), Float(rect.width), Float(rect.height)),
            b: SIMD4(Float(Double(rect.width) / Double(grid.width)),
                     Float(Double(rect.height) / Double(grid.height)),
                     Float(grid.width), Float(grid.height)))
        enc.setBytes(&params, length: MemoryLayout<HistSampleParams>.stride, index: 0)
        dispatch(enc, pipeline, grid)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error {
            throw RenderError.executeFailed(err.localizedDescription)
        }
        let gpu = (cb.gpuEndTime > 0 && cb.gpuEndTime > cb.gpuStartTime)
            ? (cb.gpuEndTime - cb.gpuStartTime) * 1000
            : 0

        // Half float out of a half-float texture is a copy, not a conversion — the same one `getBytes`
        // the shipped path does, over ~36 k pixels instead of 0.58 M.
        var rgba = [Float16](repeating: 0, count: grid.pixelCount * 4)
        rgba.withUnsafeMutableBytes { buf in
            sample.getBytes(buf.baseAddress!,
                            bytesPerRow: grid.width * 4 * MemoryLayout<Float16>.size,
                            from: MTLRegionMake2D(0, 0, grid.width, grid.height),
                            mipmapLevel: 0)
        }
        let display = DisplayImage(width: grid.width, height: grid.height, rgba: rgba,
                                   primaries: primaries, bitDepth: 16)
        // The matte probe reads the bytes that are already here, so it costs nothing on the GPU.
        let counted = content == nil
            ? framePictureRect(in: rgba, sample: grid, canvas: canvas, picture: cropPixels)
            : ImageRect(x: 0, y: 0, width: grid.width, height: grid.height)

        let tCpu = CFAbsoluteTimeGetCurrent()
        // `computeFrameSample`, not `computeEncoded`: the sample's fourth channel is the shipped
        // path's luma (`srgbEncode(Σw·linear)`), which is what keeps the luma series on the same axis
        // as the plot it will be swapped with.
        let histogram = Histogram.computeFrameSample(display, bins: binCount, rect: counted,
                                                     headroom: headroom)
            .relabelled(canvas: cropPixels,
                        roi: ImageRect(x: 0, y: 0, width: cropPixels.width, height: cropPixels.height))
        let cpu = (CFAbsoluteTimeGetCurrent() - tCpu) * 1000

        var cost = FrameHistogramCost()
        cost.sampleSize = grid
        cost.readbackBytes = grid.pixelCount * 8
        cost.gpuMilliseconds = gpu
        cost.cpuMilliseconds = cpu
        cost.wallMilliseconds = (CFAbsoluteTimeGetCurrent() - tStart) * 1000
        return FrameMeasurement(histogram: histogram, sample: display, rect: counted, cost: cost)
    }

    /// The picture's rect inside a frame, when the caller did not say where it is.
    ///
    /// A frame is a *canvas* — the viewport's device-pixel size, of which the picture occupies the
    /// centred `ImageSize.fit` rect (S0 letterboxes the rest, S2/S3 guard it, S4 encodes 0 as 0). So
    /// the hypothesis is checkable rather than assumed: `fit(crop, canvas)` is accepted only when the
    /// band outside it really is matte, i.e. every sample in it is exactly 0 in all three channels. A
    /// 1:1 window fills its canvas with picture, fails the probe (there is no band to check) and gets
    /// the whole sample — which is correct, because that window *is* all picture.
    ///
    /// The failure this cannot see: a picture whose own top or left edge is a hard black band is
    /// indistinguishable from a matte there. The cost of that mistake is the bin-0 counts of one
    /// band, not a wrong rect, and a caller that knows the rect should pass `content:`.
    ///
    /// A second failure, measured (048): a frame whose window reached **past** the picture has
    /// background on all sides at an offset, not a letterbox computed by `fit`, so the hypothesis is
    /// not even the right shape and the whole sample is returned — 37.0 % of it in bin 0 on a
    /// 1600×1002 window over a 2400×800 picture. This function cannot know the window (it is not in
    /// the texture), so the fix is not here: the renderer knows where it drew (`plan.drawnRect`)
    /// and hands that over. `content:` is the only honest answer for a windowed frame.
    private func framePictureRect(in rgba: [Float16], sample: ImageSize, canvas: ImageSize,
                                  picture: ImageSize) -> ImageRect {
        let whole = ImageRect(x: 0, y: 0, width: sample.width, height: sample.height)
        let fitted = ImageSize.fit(picture, in: canvas)
        guard fitted != canvas else { return whole }
        let sx = Double(sample.width) / Double(canvas.width)
        let sy = Double(sample.height) / Double(canvas.height)
        let x = Int((Double((canvas.width - fitted.width) / 2) * sx).rounded())
        let y = Int((Double((canvas.height - fitted.height) / 2) * sy).rounded())
        let w = Int((Double(fitted.width) * sx).rounded())
        let h = Int((Double(fitted.height) * sy).rounded())
        // A band has to exist *in the sample* for the probe to mean anything.
        guard x >= 0, y >= 0, w > 0, h > 0, x + w <= sample.width, y + h <= sample.height,
              w < sample.width || h < sample.height else { return whole }

        @inline(__always) func isMatte(_ px: Int, _ py: Int) -> Bool {
            let o = (py * sample.width + px) * 4
            return rgba[o] == 0 && rgba[o + 1] == 0 && rgba[o + 2] == 0
        }
        var bandIsMatte = true
        for py in 0..<sample.height {
            let rowOutside = py < y || py >= y + h
            for px in 0..<sample.width where rowOutside || px < x || px >= x + w {
                if !isMatte(px, py) { bandIsMatte = false; break }
            }
            if !bandIsMatte { break }
        }
        return bandIsMatte ? ImageRect(x: x, y: y, width: w, height: h) : whole
    }

    public func invalidateCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        cacheBytes = 0
        s1Entry = nil
        atlasCache = nil
        localEntry = nil
    }

    // MARK: - 2026-10-28 (P1b): what this graph is holding, and how to give it back

    /// Bytes of frame texture this graph keeps **for a later frame**: the stage cache, S1's and S1.6's
    /// slots and the mask atlas. A document that is open but idle costs this.
    public var heldTextureBytes: Int {
        var bytes = cacheBytes + s1CacheBytes
        if let e = localEntry { bytes += e.texture.width * e.texture.height * 8 }
        if let a = atlasPool {
            bytes += a.texture.width * a.texture.height * 2 * a.texture.arrayLength
        }
        return bytes
    }

    /// Bytes the texture pool is holding **idle** — recycled, waiting for the next frame. Bounded by
    /// `TextureRetention` (`oneFrame` = one canvas, `none` = zero).
    public var idleTextureBytes: Int { pool.idleBytes }
    /// How many idle textures that is, and the budget they are held against.
    public var idleTextureCount: Int { pool.idleCount }
    public var idleTextureBudgetBytes: Int { pool.budgetBytes }
    /// Every `makeTexture` this graph has paid for, and how many `obtain`s the idle list served. The
    /// ratio is what a retention allowance buys, and it is what `TexturePoolTests` asserts on.
    public var textureAllocations: Int { pool.allocations }
    public var textureReuses: Int { pool.reuses }
    /// Bytes the pool has released instead of keeping (budget overflow, or `none` retention).
    public var textureBytesDropped: Int { pool.droppedBytes }

    /// Give the idle textures back to the device **now**, and report the bytes that released.
    ///
    /// The three moments this is right (`local/perf/perf-baseline-2026-10-28.md` §5): an export has
    /// finished, the loupe switches rung/photo, and the document is closed. They all mean "no frame
    /// is coming for this canvas", which is the only thing the idle list exists for. A frame's cache
    /// is untouched — that is `invalidateCache`'s business, and dropping it would cost the next frame
    /// its hits.
    @discardableResult
    public func releaseIdleTextures() -> Int {
        pool.releaseIdle()
    }

    /// Give **everything** back: the stage cache, the S1/S1.6 slots, the atlas and the idle list. The
    /// graph stays usable — the next frame recomputes what it needs — but it holds no frame textures.
    ///
    /// This is the export path's end (`RenderGraph` built with `textureRetention: .none`), where a
    /// 60 Mpx export's eleven intermediates are 5.3 GB and nothing will ever ask for them again.
    @discardableResult
    public func releaseAllTextures() -> Int {
        let held = heldTextureBytes
        invalidateCache()
        atlasPool = nil
        return held + pool.releaseIdle()
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

    /// The histogram's readback: half float out of a half-float texture is a **copy**, not a
    /// conversion, so it is one `getBytes` straight into `[Float16]`.
    ///
    /// `readback(_:primaries:bitDepth:)` is the general path and maps 4·w·h `UInt16`s through
    /// `Float16(bitPattern:)`; the bits are identical either way, but that map is O(n) of closure
    /// work on a buffer that is already in the right format.
    private func readSample(_ texture: MTLTexture) -> LinearSample {
        let w = texture.width, h = texture.height
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!,
                             bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                             from: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0)
        }
        return LinearSample(width: w, height: h, rgba: rgba)
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
            // Two entry points in one shader file (see the shader header): `s0_geometry` has no
            // `× frameSize` / `÷ frameSize` round trip in it at all, so a cropped-but-not-rotated
            // document maps `uv − ½` back to `+ ½` and its pixels are byte-identical to the
            // pre-cropfix ones. The turn itself (pixel-space, the cropfix similarity) lives only in
            // `s0_geometry_rot`.
            // The choice is a *dispatch* choice, not a branch inside the kernel: `(uv−½)·f/f+½` is
            // 1 ulp away from `uv`, and having the expression in the code is enough to move the
            // pixels — exactly the lesson `s1_scene_linear` learned about its black offset.
            let p = try kernels.pipeline(file: "s0_geometry",
                                         function: s0Rotates(edit) ? "s0_geometry_rot" : "s0_geometry")
            // The identity/pure-CA decision lives in `plan(_:_:)` (`s0Identity`/`s0PureCA`): one
            // place, so the kernel's branch and the trace cannot disagree (029).
            let identity = plan.s0Identity
            var params = S0Params(
                a: SIMD4(Float(plan.canvas.width), Float(plan.canvas.height), plan.origin.x, plan.origin.y),
                b: SIMD4(Float(plan.content.width), Float(plan.content.height),
                         Float(sourceSize.width), Float(sourceSize.height)),
                c: SIMD4(Float(plan.crop.left), Float(plan.crop.top),
                         Float(plan.crop.width), Float(plan.crop.height)),
                d: SIMD4(costheta(edit), sintheta(edit),
                         edit.geometry.flipHorizontal ? 1 : 0, edit.geometry.flipVertical ? 1 : 0),
                // e.y: the window reaches past the frame, so the miss renders as background. Zero on
                // every in-frame render, which is why this changes no existing pixel.
                // e.z: pure-CA fast path (029) — the frame is the source pixel grid, so `px` is taken
                // directly and green stays a texel copy.
                e: SIMD4(identity ? 1 : 0, plan.backgroundOutside ? 1 : 0,
                         plan.s0PureCA ? 1 : 0, 0),
                f: SIMD4(plan.frameSize.x, plan.frameSize.y, plan.frameOrigin.x, plan.frameOrigin.y),
                // g: the two dimensionless radial ratios; 0/0 for every document that has not
                // touched the sliders, which is what keeps the CA-off path byte-identical.
                g: SIMD4(Float(edit.optics.caRed), Float(edit.optics.caBlue), 0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<S0Params>.stride, index: 0)
            // 075 — the **exit matrix**: what the decoder wrote (linear sRGB) → the graph's working
            // primaries. A separate buffer (index 1) rather than a field of `S0Params`, whose 112
            // bytes `ChromaticAberrationTests` pins on both sides; the numbers come from
            // `ColorPrimaries`, never from literals here or in the kernel.
            var primaries = RenderGraph.primariesMatrix(from: ColorPrimaries.decoded,
                                                        to: ColorPrimaries.working)
            enc.setBytes(&primaries, length: MemoryLayout<simd_float4x4>.stride, index: 1)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .sceneLinear:
            // 073B/073C: eight entry points in one shader file, chosen on the CPU by the same
            // conditions as the key material — see the shader header for the table and for why this
            // is a *dispatch* choice rather than `if (blacks != 0)` inside one kernel (071 measured
            // that spelling moving 2980/12309 samples of the push document by an ULP).
            //
            //   · no dropper level, `blacks == whites == 0` → 019's arithmetic without any new code;
            //   · `blacks`/`whites` ≠ 0, `|blacks| ≤ 50`        → the end-point (knee) model, 073B;
            //   · `|blacks| > 50`                             → 073C: the same toe plus the black-point
            //     level move. The threshold is exactly the zero of the blend factor `m(a)`, so the two
            //     instantiations agree bit for bit where they meet — the switch is invisible in the
            //     picture, and the whole first half of the travel keeps 073B's bytes;
            //   · a dropper level (`blackLevel`/`whiteLevel`) → 030's affine level, unchanged. The two
            //     spellings never coexist in a document (`LightGroup.levels`), and the absolute one
            //     wins if a hand-edited file somehow sets both — the pre-073 precedence.
            //   · 071's trim is orthogonal: `_trim` for each of the three.
            let hasLevels = edit.light.blackLevel != nil || edit.light.whiteLevel != nil
            let knee = !hasLevels && (edit.light.blacks != 0 || edit.light.whites != 0)
            let hybrid = knee && abs(edit.light.blacks) > LightGroup.blacksEVToLevelSplit
            let trim = edit.light.blackOffset != 0
            let function: String
            switch (hasLevels, knee, hybrid, trim) {
            case (true, _, _, false): function = "s1_scene_linear_levels"
            case (true, _, _, true): function = "s1_scene_linear_levels_trim"
            case (false, false, _, false): function = "s1_scene_linear"
            case (false, false, _, true): function = "s1_scene_linear_trim"
            case (false, true, true, false): function = "s1_scene_linear_hybrid"
            case (false, true, true, true): function = "s1_scene_linear_hybrid_trim"
            case (false, true, false, false): function = "s1_scene_linear_knee"
            case (false, true, false, true): function = "s1_scene_linear_knee_trim"
            }
            let p = try kernels.pipeline(file: "s1_scene_linear", function: function)
            // ── S1 is end points + exposure + highlight recovery ────────────────────────────────
            // 073B/073C: the sliders are **not** a level any more. `blacks` is a multiplicative EV at
            // the dark end (±3 EV over a 7 EV toe) for the first half of its travel, and blends a
            // black-point level move into the second half (073C, `B_LEV = 0.005` over its own 2.5 EV
            // window) so that full travel can really move the black end — down to 0 on the crush side,
            // up off the floor on the lift side. `whites` is EV (91 %) + a small level (9 %), both
            // weighted by an EV window so the mid-tones are outside the knee. The affine span
            // `(v − blk)/max(wht − blk, 1e−3)` that 019 put here is gone from the slider path — it
            // changed the slope of the whole picture, which is not what the owner asked for — and
            // survives only as 030's dropper level, where "this sample is black" *is* a level.
            //
            // White balance is a **decode** setting now: `light.temperature`/`tint` go to
            // `CIRAWFilter.neutralTemperature`/`neutralTint` and the RAW is developed again, so the
            // pixels arriving here are already balanced. The gains below are literally (1, 1, 1) —
            // the old Planckian fit here would be a *second* correction on top of the decoder's, and
            // the two would disagree (measured: at 3500 K / +30 the gain path and the decode path are
            // not the same picture; see `WhiteBalanceTests`).
            let identity = edit.light.exposure == 0 && edit.light.highlightRecovery <= 0
                && edit.light.blacks == 0 && edit.light.whites == 0
                && edit.light.blackLevel == nil && edit.light.whiteLevel == nil
                // 071: a trim on its own is *not* the identity — it moves pixels — so it takes the
                // copy branch away exactly like a level does.
                && edit.light.blackOffset == 0
            let levels = edit.light.levels
            var params = S1Params(
                a: SIMD4(edit.light.exposureGain, 1, 1, 1),
                b: SIMD4(Float(min(max(edit.light.highlightRecovery, 0), 1)), identity ? 1 : 0,
                         Float(edit.light.blacks), Float(edit.light.whites)),
                // The content rect travels with the levels, because a lifted black point maps the
                // matte's 0 to a positive value in *this* pass (派单 019 §3 item ①). Dispatch stays
                // the whole canvas — one guard per pixel is cheaper than a second encoder.
                c: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)),
                // 030: the absolute levels, resolved through `LevelPair` so the envelope and the
                // `white ≥ black + 1e-3` constraint are applied in **one** place. The flags are what
                // tell the kernel to ignore the sliders; a document without them sends 0/0 and gets
                // 019's arithmetic bit for bit.
                d: SIMD4(Float(levels.black), Float(levels.white),
                         edit.light.blackLevel == nil ? 0 : 1,
                         edit.light.whiteLevel == nil ? 0 : 1),
                // 071: the additive linear trim, clamped once (`clampedBlackOffset`) so the number in
                // the key material and the number the kernel adds cannot disagree. 0 → the kernel's
                // branch is not taken at all.
                e: SIMD4(Float(edit.light.clampedBlackOffset), 0, 0, 0))
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
            // Only what bends the 0…1 range: contrast and the two region lifts. Blacks/whites are a
            // level and moved to S1 (派单 019), so they no longer appear here — neither in the identity
            // test nor in `keyMaterial(.toneMap)`.
            let identity = edit.light.contrast == 0 && edit.light.highlights == 0
                && edit.light.shadows == 0
            var params = S2Params(
                a: SIMD4(Float(edit.light.contrast), 0.18, 0, 0),
                b: SIMD4(Float(edit.light.highlights), Float(edit.light.shadows), identity ? 1 : 0, 0),
                // The content rect, so the matte outside it is never tone-mapped (派单 008 B). The
                // dispatch stays the whole canvas: one guard per pixel is cheaper than a second
                // encoder, and the guard is what makes "shadows" leave the letterbox alone.
                c: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<S2Params>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .curve:
            // S1.7 — the one curve, in the log-light domain (派单 030). It reads the scene-linear
            // buffer S1.6 (or S1) produced, unbounded and still signed, and hands S2 a value that is
            // still scene-referred: that is what lets a −12 EV shadow and a +4 EV highlight be bent
            // on one axis, which no curve after the tone map can do.
            let p = try kernels.pipeline(file: "s1_7_hdr_curve", function: "s1_7_hdr_curve")
            let tables = try hdrCurveTables(for: edit.curve)
            let axis = HDRCurve.axis
            // 061: where each curve's black point sits. `0` on every table — the shipped default and
            // every document 051 could produce — leaves the kernel's arithmetic untouched, so the
            // identity branch, the golden hashes and 018's sub-black all come out as they did.
            let blackPoints = CurveLUT.blackPoints(edit.curve)
            var params = HDRCurveParams(
                a: SIMD4(tables.isIdentity && !options.forceCurveArithmetic ? 1 : 0,
                         Float(CurveLUT.size), Float(axis.whiteU), Float(axis.hdrPerStop)),
                // The content rect, so the curve never runs on the matte (派单 008 C). Whole-canvas
                // dispatch, one guard per pixel — the same shape as S2's, so the two passes cannot
                // drift apart.
                b: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)),
                c: SIMD4(tables.slopes[0], tables.slopes[1], tables.slopes[2], tables.slopes[3]),
                // The luma weights are a parameter, not a constant: changing the working space is one
                // number in `HDRCurve.lumaWeights` (which reads `ColorPrimaries`) and nothing here —
                // 075 did exactly that move and this line did not change. `.w` is
                // the identity mask (062): which of the four tables need the shaper at all. Forcing
                // the arithmetic path (the tests' `forceCurveArithmetic`) clears it, so the identity
                // really does go through the shaper.
                d: SIMD4(Float(HDRCurve.lumaWeights.r), Float(HDRCurve.lumaWeights.g),
                         Float(HDRCurve.lumaWeights.b),
                         Float(options.forceCurveArithmetic ? 0 : tables.identityMask)),
                e: SIMD4(blackPoints[0], blackPoints[1], blackPoints[2], blackPoints[3]))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<HDRCurveParams>.stride, index: 0)
            enc.setBuffer(tables.buffer, offset: 0, index: 1)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .color:
            // 076: vibrance and saturation only — the eight bands live in S3.6 now (OKLCh). The
            // `isIdentity` flag still means "nothing to do", which is why it reads the two fields this
            // pass actually consumes rather than the whole group.
            let p = try kernels.pipeline(file: "s3_color", function: "s3_color")
            var params = ColorParams(
                a: SIMD4(Float(edit.color.vibrance), Float(edit.color.saturation),
                         edit.color.vibrance == 0 && edit.color.saturation == 0 ? 1 : 0, 0),
                b: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<ColorParams>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .hsl:
            // 076 — the eight bands, in OKLCh, on display-referred data. One buffer: eight
            // `HSLBandU`s (values + the reach towards each neighbour). The centres come from
            // `HSLBands.centresDegrees`, i.e. the same eight physical colours the wheel names,
            // measured in the space this pass computes in.
            let p = try kernels.pipeline(file: "s3_6_hsl", function: "s3_6_hsl")
            let bands = try hslBandBuffer(for: edit.color)
            var params = HSLParamsU(
                a: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<HSLParamsU>.stride, index: 0)
            enc.setBuffer(bands, offset: 0, index: 1)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .localColor:
            // 056 — a mask's hue/saturation, on display-referred data. Reads the pipeline image S3
            // produced and the **same atlas slice** S1.6 read (canvas coordinates, coverage from
            // S1.5), so a full-canvas mask at saturation +40 is the global slider's own arithmetic.
            guard let table, let atlas = atlasCache?.texture else {
                throw RenderError.executeFailed("local colour stage without an atlas")
            }
            let p = try kernels.pipeline(file: "s3_5_local_color", function: "s3_5_local_color")
            var params = LocalColorParamsU(
                a: SIMD4(table.colorAdjust.contains { $0.a.w > 0.5 } ? 1 : 0,
                         Int32(table.colorAdjust.count), 0, 0),
                // The content rect, so the letterbox stays exactly 0 (派单 008 C's rule, the one S2,
                // S1.7 and S3 already carry).
                b: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)))
            guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            enc.setComputePipelineState(p)
            enc.setTexture(src, index: 0)
            enc.setTexture(atlas, index: 1)
            enc.setTexture(out, index: 2)
            enc.setBytes(&params, length: MemoryLayout<LocalColorParamsU>.stride, index: 0)
            enc.setBuffer(table.colorAdjustBuffer, offset: 0, index: 1)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .vignette:
            let p = try kernels.pipeline(file: "s3_vignette", function: "s3_vignette")
            let identity = edit.effects.vignetteAmount == 0
            var params = VignetteParams(
                a: SIMD4(Float(edit.effects.vignetteAmount), Float(edit.effects.vignetteMidpoint),
                         Float(edit.effects.vignetteFeather), Float(edit.effects.vignetteRoundness)),
                // Frame-relative, not content-relative: a vignette is a property of the photograph, so
                // a 1:1 window sees the same falloff in the same physical place as the whole frame.
                b: SIMD4(plan.frameSize.x, plan.frameSize.y, plan.frameOrigin.x, plan.frameOrigin.y),
                c: SIMD4(identity ? 1 : 0, plan.origin.x, plan.origin.y, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<VignetteParams>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .grain:
            // S3.7 — 颗粒 (2026-10-28). Encoded **only** for documents that have grain
            // (`RenderStage.pipeline(hasGrain:)`), so a neutral document's frame is the pre-S3.7 frame
            // by construction rather than by arithmetic: there is no pass to be neutral in.
            let p = try kernels.pipeline(file: "s3_7_grain", function: "s3_7_grain")
            let identity = edit.effects.grain <= 0
            var params = GrainParams(
                a: SIMD4(Float(edit.effects.grain), Float(edit.effects.grainSize),
                         Float(edit.effects.grainRoughness),
                         Float(edit.effects.grainSeedValue)),
                // Frame-relative, exactly like S3c: a 1:1 window must show the same grain in the same
                // physical place as the whole frame, and the letterbox is never grained.
                b: SIMD4(plan.frameSize.x, plan.frameSize.y, plan.frameOrigin.x, plan.frameOrigin.y),
                c: SIMD4(identity ? 1 : 0, plan.origin.x, plan.origin.y, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<GrainParams>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .display:
            let p = try kernels.pipeline(file: "s4_display", function: "s4_display")
            // 075: the source is the **working** space, not sRGB — the S0 exit matrix put every
            // number into it. `primariesMatrix` is exhaustive over (source, target) and returns the
            // exact identity only when the two are equal; the kernel's `p.a.x` flag mirrors that
            // same comparison so the fast path and the matrix can never disagree.
            let target = RenderGraph.outputPrimaries(options.display.primaries)
            let matrix = RenderGraph.primariesMatrix(from: ColorPrimaries.working, to: target)
            var params = DisplayParams(m: matrix,
                                       a: SIMD4(ColorPrimaries.working == target ? 1 : 0,
                                                Float(options.display.headroom), 0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<DisplayParams>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()
        }
    }

    // S0 and the mask atlas must rotate by the same angle, so both read `straightenDegrees`
    // (the stored value clamped to the ±45 straighten range) instead of the raw field.
    //
    // `s0Rotates` is the *dispatch* condition for S0's two entry points and is deliberately derived
    // from the same field as `costheta`/`sintheta`: at `straightenDegrees == 0` those are exactly
    // (1, 0), so the turn is a no-op and `s0_geometry` (the one with no `× f / ÷ f` in it) is
    // bit-exact. Any other value — including a 90° rotation or a clamped ±45 — takes `_rot`.
    private func s0Rotates(_ edit: EditModel) -> Bool {
        edit.geometry.straightenDegrees != 0
    }

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
    // The budget is p95 ≤ 16.7 ms at 4.1 Mpx — three masks with feather and refine have to fit in
    // one 60 fps frame. The refine case is the
    // expensive one by a wide margin: its reconstruction is a full-resolution pass per mask, and it is
    // only worth having while the atlas is being rebuilt (a selection or S1 change), which is exactly
    // what the numbers above measure.
    //
    // The feather is a running sum, not an O(r) convolution: at radius 273 (feather 1.0) it costs what
    // radius 4 costs, which is why the maximum feather is not a frame-time cliff.

    // MARK: - 005e: semantic mattes

    /// What the OS answered for this document's semantic components, in atlas order.
    ///
    /// `slices[mask][component]` is the raster's index in the matte array texture, or `nil` when no
    /// route could produce one. `keyMaterial` is the canonical text of the events: it enters the two
    /// mask stage keys and the descriptor-table key, so a frame rendered before and after the model
    /// changed can never share a cached atlas.
    struct SemanticResolution {
        var rasters: [SemanticRaster] = []
        var slices: [[Int?]] = []
        var events: [MaskSemanticEvent] = []
        var keyMaterial: String = ""

        func slice(mask: Int, component: Int) -> Int? {
            guard slices.indices.contains(mask), slices[mask].indices.contains(component) else {
                return nil
            }
            return slices[mask][component]
        }
    }

    /// Resolve every semantic component of the enabled masks, one cached provider call per
    /// `(contentHash, kind, modelVersion, route)`.
    ///
    /// A `nil` result is a value: the component keeps its place in the combination order with zero
    /// coverage, so `add` leaves the other components' union alone and `intersect` empties the
    /// selection — the same arithmetic any other empty shape gets (§3.3).
    private func resolveSemantics(_ edit: EditModel) -> SemanticResolution {
        var out = SemanticResolution()
        let active = edit.activeMasks
        let wantsMatte = active.contains { mask in
            mask.components.contains { component in
                if case .semantic = component.shape { return true }
                return false
            }
        }
        guard wantsMatte else { return out }

        let source = SemanticMatteSource(image: uprightImage, contentHash: input.identity,
                                        url: input.sourceURL)
        // Two components asking for the same kind share one slice: the raster is identical, and a
        // 4 MB copy per duplicate is not.
        var sliceForDigest: [String: Int] = [:]

        for mask in active {
            var row: [Int?] = []
            for component in mask.components {
                guard case .semantic(let semantic) = component.shape else {
                    row.append(nil)
                    continue
                }
                let result = semanticStore.resolve(kind: semantic.kind, route: semantic.provider,
                                                   source: source, provider: semanticProvider)
                switch result {
                case .raster(let raster):
                    let slice: Int
                    if let existing = sliceForDigest[raster.digest] {
                        slice = existing
                    } else {
                        out.rasters.append(raster)
                        slice = out.rasters.count - 1
                        sliceForDigest[raster.digest] = slice
                    }
                    row.append(slice)
                    out.events.append(.semanticAvailable(maskID: mask.id,
                                                         componentID: component.id,
                                                         kind: semantic.kind,
                                                         provider: raster.provider,
                                                         digest: raster.digest))
                    if let stored = semantic.rasterDigest, stored != raster.digest {
                        out.events.append(.semanticDigestChanged(maskID: mask.id,
                                                                kind: semantic.kind,
                                                                stored: stored,
                                                                produced: raster.digest))
                    }
                case .unavailable(let reason):
                    row.append(nil)
                    out.events.append(.semanticUnavailable(maskID: mask.id,
                                                          componentID: component.id,
                                                          kind: semantic.kind,
                                                          reason: reason))
                }
            }
            out.slices.append(row)
        }
        // Sorted so two processes produce the same key text (D6): the events are already in atlas
        // order, but the sort also makes a duplicated kind's ordering irrelevant.
        out.keyMaterial = out.events.map(\.keyString).sorted().joined(separator: ";")
        return out
    }

    /// One array texture for the resolved mattes, R32F (a mask is not a display value; 32-bit keeps
    /// the digest and the sampled number the same quantity). Recreated only when a digest moves.
    private func semanticTexture(for rasters: [SemanticRaster]) throws -> MTLTexture {
        guard !rasters.isEmpty else { return try semanticDummy() }
        let key = rasters.map(\.digest).joined(separator: "|")
        if let hit = semanticTextureCache, hit.key == key { return hit.texture }

        // One size for every slice — `resized` is bilinear on the same texel-centre grid the kernel
        // samples, so the resize adds no shift.
        let w = rasters.map(\.width).max() ?? 1
        let h = rasters.map(\.height).max() ?? 1
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .r32Float
        desc.width = w
        desc.height = h
        desc.arrayLength = rasters.count
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RenderError.allocationFailed("semantic mattes \(w)x\(h)x\(rasters.count)")
        }
        for (slice, raster) in rasters.enumerated() {
            let values = raster.resized(width: w, height: h)
            values.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, slice: slice,
                                withBytes: raw.baseAddress!, bytesPerRow: w * 4,
                                bytesPerImage: w * h * 4)
            }
        }
        semanticTextureCache = (key, texture)
        return texture
    }

    /// 1×1 zero, bound where the kernel declares `texture(2)` but no semantic component exists.
    private func semanticDummy() throws -> MTLTexture {
        if let hit = semanticDummyTexture { return hit }
        let desc = MTLTextureDescriptor()
        desc.textureType = .type2DArray
        desc.pixelFormat = .r32Float
        desc.width = 1
        desc.height = 1
        desc.arrayLength = 1
        desc.mipmapLevelCount = 1
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else {
            throw RenderError.allocationFailed("semantic dummy")
        }
        var zero: Float = 0
        withUnsafeBytes(of: &zero) { raw in
            texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, slice: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: 4, bytesPerImage: 4)
        }
        semanticDummyTexture = texture
        return texture
    }

    /// Descriptor tables for the enabled masks, in atlas order. Cached on the two key materials so a
    /// frame that only moves a slider reuses the buffers.
    private func maskTable(for edit: EditModel, content: ImageSize,
                           semantics: SemanticResolution) throws -> MaskTable? {
        let active = edit.activeMasks
        guard !active.isEmpty else { return nil }

        let selection = edit.maskSelectionMaterial
        let apply = edit.maskApplyMaterial
        // The content size is part of the key because the two radii (feather, guided) are pixel
        // lengths derived from it: the same document at thumbnail and at export must produce
        // different descriptors from the same selection key. 005e adds the semantic material for the
        // same reason: which slice a semantic component points at is not in the document.
        let cacheKey = selection + "##" + apply + "##" + content.keyString
            + "##" + semantics.keyMaterial
        if let hit = maskTables[cacheKey] { return hit }

        var masks: [MaskDescU] = []
        var shapes: [MaskShapeDescU] = []
        var adjust: [LocalAdjustU] = []
        var colorAdjust: [LocalColorU] = []
        var strokes: [MaskStrokeDescU] = []
        var points: [SIMD4<Float>] = []
        var colours: [SIMD4<Float>] = []
        var dependency: TileDependency = .pointwise
        for (maskIndex, m) in active.enumerated() {
            let first = Int32(shapes.count)
            for (componentIndex, c) in m.components.enumerated() {
                let slice = semantics.slice(mask: maskIndex, component: componentIndex)
                shapes.append(shapeDesc(c, slice: slice, strokes: &strokes,
                                        points: &points, colours: &colours))
            }
            // 005d: the atlas's two neighbourhood operators, in canvas pixels (§4.6, `MaskRadius`).
            let featherPx = Float(MaskRadius.featherPixels(m.feather, content: content))
            let guidedPx = Float(MaskRadius.guidedRadiusPixels(m.refine, content: content))
            dependency = dependency.widest(MaskRadius.atlasDependency(of: m, content: content))
            masks.append(MaskDescU(meta: SIMD4(first, Int32(m.components.count), m.invert ? 1 : 0, 0),
                                   misc: SIMD4(Float(min(max(m.opacity, 0), 1)), featherPx,
                                               Float(min(max(m.refine, 0), 1)), guidedPx)))
            adjust.append(adjustDesc(m.adjustments, enabled: m.isEnabled))
            colorAdjust.append(colorAdjustDesc(m.adjustments, enabled: m.isEnabled))
        }
        // Metal requires a bound buffer even when the count is zero; one neutral entry keeps the
        // binding valid without inventing a mask.
        if masks.isEmpty { masks.append(MaskDescU(meta: .zero, misc: .zero)) }
        if shapes.isEmpty { shapes.append(MaskShapeDescU(meta: .zero, p0: .zero, p1: .zero)) }
        if adjust.isEmpty { adjust.append(LocalAdjustU(a: SIMD4(1, 1, 1, 0), b: .zero, c: SIMD4(0, 0, 0, 0))) }
        if colorAdjust.isEmpty { colorAdjust.append(LocalColorU(a: .zero)) }
        if strokes.isEmpty {
            strokes.append(MaskStrokeDescU(meta: .zero, misc: .zero, bmin: .zero, bmax: .zero))
        }
        if points.isEmpty { points.append(.zero) }
        if colours.isEmpty { colours.append(.zero) }

        let table = MaskTable(ids: active.map(\.id),
                              masks: masks, shapes: shapes, adjust: adjust,
                              colorAdjust: colorAdjust,
                              strokes: strokes, points: points, colours: colours,
                              dependency: dependency,
                              maskBuffer: try buffer(masks, "mask descs"),
                              shapeBuffer: try buffer(shapes, "mask shapes"),
                              adjustBuffer: try buffer(adjust, "mask adjustments"),
                              colorAdjustBuffer: try buffer(colorAdjust, "mask local colour"),
                              strokeBuffer: try buffer(strokes, "mask strokes"),
                              pointBuffer: try buffer(points, "mask brush points"),
                              colourBuffer: try buffer(colours, "mask colour samples"))
        if maskTables.count > 8 { maskTables.removeAll() }
        maskTables[cacheKey] = table
        return table
    }

    /// One component → the GPU's fixed-layout descriptor, appending any variable-length payload
    /// (brush points, colour samples) to the shared side arrays. `slice` is the semantic raster's
    /// index in the matte array texture, or `nil` when the OS could not produce one (then the
    /// component covers 0 and the report says why).
    private func shapeDesc(_ c: MaskComponent, slice: Int?,
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
        case .semantic(let s):
            // 005e: kind 5 samples the OS raster at this component's slice, then applies `softEdge`.
            // No raster ⇒ kind −1, i.e. exactly the pre-005e "zero coverage, never a guess".
            guard let slice else {
                return MaskShapeDescU(meta: SIMD4(-1, invert, op, 0), p0: .zero, p1: .zero)
            }
            return MaskShapeDescU(meta: SIMD4(5, invert, op, 0),
                                  p0: SIMD4(Float(slice), 0, 0, 0),
                                  p1: SIMD4(Float(min(max(s.softEdge, 0), 1)), feather, 0, 0))
        case .unsupported:
            // Not evaluated by this pass: zero coverage, never a guess.
            return MaskShapeDescU(meta: SIMD4(-1, invert, op, 0), p0: .zero, p1: .zero)
        }
    }

    private func adjustDesc(_ a: LocalAdjustments, enabled: Bool) -> LocalAdjustU {
        let gain = a.gain
        // 056: `hasSceneLinearWork`, not `!isIdentity` — a mask whose only sliders are hue/saturation
        // has nothing for S1.6 to do, and sending it through `local_adjust` would round pixels at the
        // neutral settings instead of copying them.
        let active = enabled && a.hasSceneLinearWork
        return LocalAdjustU(
            a: SIMD4(gain.r, gain.g, gain.b, Float(min(max(a.amount, 0), 100) / 100)),
            b: SIMD4(Float(a.contrast), Float(a.highlights), Float(a.shadows), Float(a.whites)),
            c: SIMD4(Float(a.blacks), 0, 0, active ? 1 : 0))
    }

    /// 056 — S3.5's descriptor. `enabled` is false for a mask with no hue/saturation, so the kernel
    /// skips it before reading the atlas: a mask with only exposure costs nothing in that pass.
    private func colorAdjustDesc(_ a: LocalAdjustments, enabled: Bool) -> LocalColorU {
        let active = enabled && a.amount > 0 && a.contributesLocalColor
        return LocalColorU(a: SIMD4(Float(a.hue), Float(a.saturation),
                                    Float(min(max(a.amount, 0), 100) / 100), active ? 1 : 0))
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
                             table: MaskTable, plan: Plan, edit: EditModel,
                             semantics: SemanticResolution) throws -> MaskStageReport {
        var report = MaskStageReport()
        let count = table.ids.count
        let canvas = plan.canvas

        // 1 — the pointwise coverage of 005b/005c, unchanged: `opacity · combine · invert`.
        //
        // Two entry points, chosen by the same condition S0 uses (`s0Rotates`): the rotating
        // instantiation turns the pixel offsets, the other has no `× frameSize` / `÷ frameSize` in it
        // and therefore reproduces the recorded atlases bit for bit at `straighten == 0`. 派单 080:
        // the atlas kept turning `uv − ½` after 073 moved S0 to pixels, so a 7° straighten on a
        // 9504×6336 frame evaluated the mask 273 px away from the pixels it selected.
        let atlasRotates = s0Rotates(edit)
        let atlasFunction = atlasRotates ? "s1_5_mask_atlas_rot" : "s1_5_mask_atlas"
        let p = try kernels.pipeline(file: "s1_5_mask_atlas", function: atlasFunction)
        var params = MaskAtlasParams(
            a: SIMD4(Float(canvas.width), Float(canvas.height), plan.origin.x, plan.origin.y),
            b: SIMD4(Float(plan.content.width), Float(plan.content.height),
                     Float(sourceSize.width), Float(sourceSize.height)),
            c: SIMD4(Float(plan.crop.left), Float(plan.crop.top),
                         Float(plan.crop.width), Float(plan.crop.height)),
            d: SIMD4(costheta(edit), sintheta(edit),
                     edit.geometry.flipHorizontal ? 1 : 0, edit.geometry.flipVertical ? 1 : 0),
            e: SIMD4(Int32(count), 0, 0, 0),
            // Masks live in the *frame* (§4). A 1:1 window must therefore evaluate them through the
            // same frame-relative mapping S0 used, or the selection would slide with the window.
            f: SIMD4(plan.frameSize.x, plan.frameSize.y, plan.frameOrigin.x, plan.frameOrigin.y))
        guard let enc = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        enc.setComputePipelineState(p)
        enc.setTexture(src, index: 0)
        enc.setTexture(atlas, index: 1)
        // 005e: the resolved mattes (or the 1×1 stand-in). The kernel only samples this for kind 5.
        enc.setTexture(try semanticTexture(for: semantics.rasters), index: 2)
        enc.setBytes(&params, length: MemoryLayout<MaskAtlasParams>.stride, index: 0)
        enc.setBuffer(table.maskBuffer, offset: 0, index: 1)
        enc.setBuffer(table.shapeBuffer, offset: 0, index: 2)
        enc.setBuffer(table.strokeBuffer, offset: 0, index: 3)
        enc.setBuffer(table.pointBuffer, offset: 0, index: 4)
        enc.setBuffer(table.colourBuffer, offset: 0, index: 5)
        dispatch(enc, p, canvas)
        enc.endEncoding()
        report.atlasPasses.append(atlasFunction)

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
        let mapping = canvasMapping(edit, plan)
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
                // The guided filter's luma, in the **working** primaries (075 batch B): this is the
                // only luma weight outside a kernel file, which is why it was the easiest one to miss.
                b: SIMD4(Float(MaskRadius.guidedEpsilon(Double(strength))),
                         Float(HDRCurve.lumaWeights.r), Float(HDRCurve.lumaWeights.g),
                         Float(HDRCurve.lumaWeights.b)),
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

        let mapping = canvasMapping(edit, plan)
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
        let mapping = canvasMapping(edit, plan)
        var out: [String: MaskRect] = [:]
        for m in edit.activeMasks {
            if let r = MaskBounds.canvasRect(for: m, mapping: mapping) { out[m.id] = r }
        }
        return out
    }

    /// S0's mapping, in the form the bounds code needs — for the **frame**, never for the window.
    ///
    /// `MaskCanvasMapping` walks normalized source coordinates to canvas pixels; giving it the frame's
    /// size and the frame's origin inside the canvas is what makes its bounds comparable with the atlas
    /// pixels of a windowed render (the atlas also measures against the frame). Without a window both
    /// numbers are the content rect and its centring, i.e. exactly what 005c/005d used.
    private func canvasMapping(_ edit: EditModel, _ plan: Plan) -> MaskCanvasMapping {
        MaskCanvasMapping(geometry: edit.geometry, source: sourceSize,
                          content: plan.frameInCanvas, canvas: plan.canvas,
                          origin: (Double(plan.origin.x - plan.frameOrigin.x),
                                   Double(plan.origin.y - plan.frameOrigin.y)))
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

    /// The four S1.7 tables, in one buffer, plus what says whether they still match the document.
    private struct HDRCurveTableCache {
        let buffer: MTLBuffer
        /// One key per table (W, R, G, B): the canonical text of that point list. Comparing four
        /// short strings is what keeps a drag to one rebuild instead of four.
        var keys: [String]
        var slopes: [Float]
        var identity: [Bool]
        var allIdentity: Bool { identity.allSatisfy { $0 } }
        var identityMask: Int { identity.enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) } }
    }

    /// The S1.7 tables for `curve`, rebuilding only what moved.
    ///
    /// Measured on this machine (`swiftc -O`, the same code path, `HDRCurveTests` prints it in
    /// Debug): **one table 0.023 ms** (p95 0.024), **all four 0.099 ms** (p95 0.35) — a drag is one
    /// table, a document switch is four, and both are two orders below a frame. §6.4's budgets
    /// (0.5 ms / 2 ms) hold with ~20× margin. Under `-Onone` (how `swift test` runs) the same work
    /// is 2.4 ms / 8.9 ms, which is why the test's assertions are structural.
    ///
    /// The render path itself stays quiet: a per-frame `print` on a drag is one log line per frame.
    /// The identity mask (062): bit 0 = W, 1 = R, 2 = G, 3 = B, set for every table that is the
    /// identity. The kernel skips those tables outright — an identity step through the shaper would
    /// come back within 5e-7 and flip one fp16 bit at a rounding boundary, which is exactly what
    /// `HDRCurveTests` ⑩ measures. `forceCurveArithmetic` clears the mask, because the whole point of
    /// forcing the arithmetic path is to run the identity *through* the shaper.
    private func hdrCurveTables(for curve: CurveGroup) throws -> (buffer: MTLBuffer, slopes: [Float],
                                                                  isIdentity: Bool,
                                                                  identityMask: Int) {
        let n = CurveLUT.size
        let sliceBytes = n * MemoryLayout<Float>.size
        let points = curve.tables
        let keys = points.map { $0.map(\.keyString).joined(separator: ";") }

        if var cache = curveTablesCache, cache.buffer.length == CurveLUT.tableCount * sliceBytes {
            for t in 0..<CurveLUT.tableCount where cache.keys[t] != keys[t] {
                let table = CurveLUT.buildOne(points[t])
                cache.buffer.contents().advanced(by: t * sliceBytes).copyMemory(
                    from: table, byteCount: sliceBytes)
                cache.keys[t] = keys[t]
                cache.identity[t] = CurveLUT.isIdentityTable(table)
                cache.slopes[t] = CurveLUT.slope(of: table)
            }
            curveTablesCache = cache
            return (cache.buffer, cache.slopes, cache.allIdentity, cache.identityMask)
        }

        let tables = CurveLUT.build(curve)
        guard let b = device.makeBuffer(bytes: tables,
                                        length: tables.count * MemoryLayout<Float>.size,
                                        options: .storageModeShared) else {
            throw RenderError.allocationFailed("S1.7 curve tables")
        }
        let identity = (0..<CurveLUT.tableCount).map {
            CurveLUT.isIdentityTable(tables[$0 * n..<($0 + 1) * n])
        }
        let cache = HDRCurveTableCache(buffer: b, keys: keys, slopes: CurveLUT.slopes(tables),
                                       identity: identity)
        curveTablesCache = cache
        return (b, cache.slopes, cache.allIdentity, cache.identityMask)
    }

    /// The eight bands as S3.6 reads them (派单 076): three slider values in units and the reach towards
    /// each neighbour, in **OKLCh degrees**, from `HSLBands`.
    ///
    /// **Not cached.** The geometry (the eight centres and their reaches) is a constant — `HSLBands`'
    /// `static let` — so the only thing that changes per frame is 24 floats, and a 264-byte buffer per
    /// render is cheaper than a dictionary that would grow by one entry per slider tick during a drag
    /// (which is what the pre-076 `bandBuffers` cache did).
    private func hslBandBuffer(for color: ColorGroup) throws -> MTLBuffer {
        var words: [HSLBandU] = []
        words.reserveCapacity(ColorGroup.bandCount)
        for (i, band) in color.bands.prefix(ColorGroup.bandCount).enumerated() {
            let centre = HSLBands.centresDegrees[min(i, HSLBands.centresDegrees.count - 1)]
            let extent = HSLBands.extents[min(i, HSLBands.extents.count - 1)]
            words.append(HSLBandU(v: SIMD4(Float(band.hue), Float(band.saturation),
                                           Float(band.luminance), centre),
                                  e: SIMD4(extent.left, extent.right, 0, 0)))
        }
        guard let b = device.makeBuffer(bytes: words,
                                        length: MemoryLayout<HSLBandU>.stride * words.count,
                                        options: .storageModeShared) else {
            throw RenderError.allocationFailed("HSL bands")
        }
        return b
    }

    // MARK: primaries

    /// `ColorPrimaries` → `OutputPrimaries`. Exhaustive on purpose: adding an output target without
    /// teaching this switch about it is a **compile error**, which is the cheap half of 075 §3.2.
    static func outputPrimaries(_ target: OutputPrimaries) -> ColorPrimaries {
        switch target {
        case .sRGB: return .sRGB
        case .displayP3: return .displayP3
        }
    }

    /// `source` primaries → `target` primaries, column-major, straight out of `ColorPrimaries`.
    ///
    /// **075 §3.2 — the silent identity is gone.** This used to be
    /// `guard from == .sRGB, to == .displayP3 else { return identity }`: one hard-written pair, and
    /// *everything else* — including the pair the migration was about to produce on every frame —
    /// fell through to the identity matrix, i.e. sRGB screens would have been handed Rec.2020 numbers
    /// with no error, no crash, and a test suite that only covered `sRGB → P3`.
    ///
    /// Now the table is `ColorPrimaries.conversion`, which is defined for **all nine** (source,
    /// target) pairs by construction (it is `toXYZ(target)⁻¹ · toXYZ(source)`), and there is no
    /// fallback branch left to be wrong:
    ///
    ///   · `source == target` returns the *exact* identity — `conversion` leaves a ~1e-16 residue on
    ///     the diagonal, and the identity case is the one where "no matrix at all" must be true, not
    ///     approximately true;
    ///   · every other pair is asserted to be a real conversion before it is returned: white-point
    ///     preserving (row sums 1) and **not** the identity. A failure here is a bug in the derivation
    ///     or in the enum, and there is no valid pixel output for either.
    static func primariesMatrix(from source: ColorPrimaries, to target: ColorPrimaries) -> simd_float4x4 {
        if source == target { return identityMatrix }
        let m = ColorPrimaries.conversion(from: source, to: target)
        precondition(m.preservesWhitePoint(within: 1e-9),
                     "\(source.rawValue) → \(target.rawValue) does not preserve the D65 white point — "
                     + "a converted neutral would change colour, which no output stage can fix")
        precondition(m.maxAbsoluteDifference(from: .identity) > 1e-6,
                     "\(source.rawValue) → \(target.rawValue) came out as the identity matrix — "
                     + "the exact failure 075 §3.2 was written about (a silent no-op conversion)")
        return simd_float4x4(columns: (SIMD4(Float(m[0, 0]), Float(m[1, 0]), Float(m[2, 0]), 0),
                                       SIMD4(Float(m[0, 1]), Float(m[1, 1]), Float(m[2, 1]), 0),
                                       SIMD4(Float(m[0, 2]), Float(m[1, 2]), Float(m[2, 2]), 0),
                                       SIMD4(0, 0, 0, 1)))
    }

    /// The 4×4 identity, in the same (column-major) shape `primariesMatrix` returns.
    static var identityMatrix: simd_float4x4 {
        simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    }
}

// MARK: - texture pool

/// How much texture memory a `RenderGraph` holds **between** frames.
///
/// 2026-10-28 (P1b) — the pool is bounded now, and this is the knob. It used to be append-only:
/// `recycle` grew a dictionary and nothing ever took a texture back, so a graph's footprint was the
/// high-water mark of every canvas it had ever rendered. On a 60 Mpx export one frame leaves eleven
/// 483 MB intermediates behind and the pool kept them for the life of the document (measured 10.6 GB
/// of Metal for a six-frame export — `local/perf/perf-baseline-2026-10-28.md` §5,
/// 「纹理池只增不减」).
///
/// Retention is capped in **bytes**, not in textures, because what a texture costs is its canvas and
/// a count-based cap is a different number at every zoom level: four 4.10 Mpx frames are 131 MB, four
/// 60 Mpx frames are 1.9 GB. The unit is therefore the pool's own `frameBytes` — the largest canvas
/// it has handed out — so one allowance means the same thing on every picture.
public enum TextureRetention: Sendable, Equatable {
    /// Keep at most `TexturePool.frameAllowance` canvases' worth of idle textures: enough for the
    /// next frame of the same canvas to be allocation-free, which is the only reuse a hot path can
    /// spend. The interactive default.
    case oneFrame
    /// Keep nothing **between** frames: every recycled texture is released when the frame ends, so an
    /// export's bytes are back before the next picture decodes. Inside one frame the pool still hands
    /// textures back (see `TexturePool.oneShotChurn`) — that is the frame reusing itself, not
    /// retention, and without it a 60 Mpx export pays ten `makeTexture` calls of 483 MB.
    case none
    /// Keep at most `bytes` — the explicit knob, used by `TexturePoolTests` to show what an
    /// unbounded pool does.
    case bytes(Int)
}

/// Frame-time work must not pay for `makeTexture`. Textures are recycled per (size) instead, which
/// is what makes a second identical render measurably cheaper than the first.
///
/// The allowance is **1**: at 60 Mpx keeping two extra 483 MB intermediates changed the hot frame by
/// nothing (p05 56.1 ms with three cache entries and an empty idle list vs 56.7 ms with one and one),
/// so the constant holds the *cheapest* configuration that does not pay `makeTexture` again, not the
/// largest one that fits.
final class TexturePool {

    /// Canvases' worth of idle texture the pool keeps for the next frame: **two**, because a frame
    /// that recycles as it goes (see `recyclesEachStage`) has one texture being read and one being
    /// written when it commits, and both are what the next frame asks for first. Measured at 60 Mpx
    /// with one allowance: p05 89 ms and two `makeTexture` calls per frame; with two, the same two
    /// allocations and no retained texture is ever wasted.
    static let frameAllowance = 2
    /// A one-shot frame's **in-flight** churn: with `render` recycling each stage's input as soon as
    /// the next stage has been encoded, two textures are alive at once (the one being read, the one
    /// being written). That is not retention — it is the frame reusing itself — so `Retention.none`
    /// allows exactly this much and releases the rest when the frame ends.
    static let oneShotChurn = 2
    /// A cacheless frame reuses its own textures in place only when one is at least this big
    /// (**128 MB** = 16.8 Mpx rgba16f). Both sides of it are measured:
    ///
    ///   · 60.3 Mpx (483 MB): p05 **151 → 89 ms**, 109 → 24 `makeTexture` calls. The allocation is the
    ///     cost, and 483 MB of fresh pages per stage is far more than the barrier reusing one forces;
    ///   · 4.10 Mpx (32.8 MB): p05 unchanged, but p50 6.2 → 8–13 ms. Here the allocation is cheap and
    ///     the per-pass barrier is not, so the reuse is a pessimisation.
    ///
    /// 128 MB sits between the two measured sizes; nothing was measured in between, and the number is
    /// a floor on "the allocation dominates", not a tuned optimum.
    static let eagerRecycleFloorBytes = 128_000_000

    private let device: MTLDevice
    private let retention: TextureRetention
    /// Idle textures, keyed by size, newest last within a key.
    private var free: [String: [MTLTexture]] = [:]
    /// The order textures were recycled in, oldest first — the eviction order when over budget.
    private var freeOrder: [String] = []

    /// Bytes currently held idle. This is the number the budget is expressed against.
    private(set) var idleBytes = 0
    /// The largest canvas this pool has handed out — the unit `Retention.oneFrame` counts in.
    private(set) var frameBytes = 0
    /// `makeTexture` calls, `obtain`s served from the idle list, and bytes released instead of kept.
    private(set) var allocations = 0
    private(set) var reuses = 0
    private(set) var droppedBytes = 0

    init(device: MTLDevice, retention: TextureRetention = .oneFrame) {
        self.device = device
        self.retention = retention
    }

    /// Whether the pool keeps nothing — the one-shot export policy. `render` reads this to decide
    /// whether a stage's input may go back to the pool the moment it has been consumed.
    var retainsNothing: Bool { retention == .none }

    /// The byte budget idle textures are held against, for the current `frameBytes`.
    var budgetBytes: Int {
        switch retention {
        case .none: return frameBytes * TexturePool.oneShotChurn
        case .bytes(let b): return b
        case .oneFrame: return frameBytes * TexturePool.frameAllowance
        }
    }

    var idleCount: Int { free.values.reduce(0) { $0 + $1.count } }

    func obtain(_ size: ImageSize) throws -> MTLTexture {
        let key = size.keyString
        let bytes = size.width * size.height * 8
        if bytes > frameBytes { frameBytes = bytes }
        if var list = free[key], let t = list.popLast() {
            if list.isEmpty { free[key] = nil } else { free[key] = list }
            idleBytes -= bytes
            if let i = freeOrder.lastIndex(of: key) { freeOrder.remove(at: i) }
            reuses += 1
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
        allocations += 1
        return t
    }

    func recycle(_ texture: MTLTexture) {
        let key = "\(texture.width)x\(texture.height)"
        let bytes = texture.width * texture.height * 8
        idleBytes += bytes
        free[key, default: []].append(texture)
        freeOrder.append(key)
        trim()
    }

    /// Release the oldest idle textures until the budget holds. Oldest first (FIFO) rather than
    /// biggest first: the texture a frame is about to ask for is the one that was recycled last.
    private func trim() {
        while idleBytes > budgetBytes, let key = freeOrder.first {
            freeOrder.removeFirst()
            guard var list = free[key], !list.isEmpty else { continue }
            let dropped = list.removeFirst()
            if list.isEmpty { free[key] = nil } else { free[key] = list }
            let bytes = dropped.width * dropped.height * 8
            idleBytes -= bytes
            droppedBytes += bytes
        }
    }

    /// Hand every idle texture back to the device now, and report the bytes that released.
    @discardableResult
    func releaseIdle() -> Int {
        let bytes = idleBytes
        free.removeAll()
        freeOrder.removeAll()
        idleBytes = 0
        return bytes
    }
}
