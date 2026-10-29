import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
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

    /// The file's lens profile, when it has one (097 DNG / 103 Panasonic RW2).
    ///
    /// A **decode-time file fact**, carried on the same path as `identity`/`sourceURL` rather than
    /// inside `EditModel`: it describes how the raw pixels must be sampled, not what the user asked
    /// for. When this is nil and `sourceURL` is present, the initializer reads it from the file —
    /// every caller that already hands us a URL (loupe, export, CLI) therefore gets the correction
    /// without a second plumbing path. A caller with a synthetic image can pass it explicitly.
    ///
    /// S0 uses it only when `requiresOwnWarp`: three *different* DNG planes, or any usable Panasonic
    /// warp. A single DNG plane means Apple's own correction already ran and the graph must not warp
    /// twice.
    public let lensProfile: LensProfile?

    public init(image: LinearImage, identity: String, sourceURL: URL? = nil,
                lensProfile: LensProfile? = nil) {
        self.image = image
        self.identity = identity
        self.sourceURL = sourceURL
        self.lensProfile = lensProfile ?? sourceURL.flatMap {
            LensProfile.read(from: $0) ?? LensProfile.readPanasonic(from: $0)
        }
    }

    /// Does S0 apply the file's own lens warp? DNG: exactly when it carries three distinct planes;
    /// RW2: whenever a usable Panasonic profile was parsed. Both cases are the ones `RAWDecoder`
    /// turned Apple's correction off for.
    public var hasPerPlaneLensWarp: Bool { lensProfile?.requiresOwnWarp == true }
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

    /// **Tests only.** Compute S3.4's grey **once per channel** (`L` of `(r,r,r)`, of `(g,g,g)`, of
    /// `(b,b,b)`) instead of once per pixel and writing it three times — the plausible mistake a
    /// monochrome pass can make, and the one the acceptance's "the three channels are equal" assertion
    /// exists for.
    ///
    /// `BlackAndWhiteTests.testTheRefutationTintsTheGrey` turns it on and shows the measured
    /// max-channel-difference going from 0 to something a cast would need — i.e. the assertion is
    /// load-bearing, not a tautology about a kernel that only ever had one number to write. Never set
    /// by the app, never part of a key.
    public var bwIndependentChannels: Bool

    /// **Tests only.** Compute S3.8's region weights as `(1/3, 1/3, 1/3)` for every pixel — i.e. forget
    /// the luminance windows and let every wheel reach the whole frame, which is the plausible mistake
    /// this stage's whole design exists to avoid.
    ///
    /// `ColorGradingTests.testTheRefutationMakesTheIsolationFail` turns it on and measures the
    /// highlight zone of a shadow-only document going from **0** changed pixels to most of them — the
    /// proof that 「只改阴影轮，高光区 0 变化」 is a claim about the windows and not about the maths
    /// happening to be small. `ColorGrade.apply(globalWeights:)` takes the same flag, so the CPU
    /// reference and the kernel can be shown to be wrong in the same way. Never set by the app, never
    /// part of a key.
    public var gradeGlobalWeights: Bool

    /// **Tests only.** Make S1.9's `heal` behave as a plain **copy** — zero the boundary plane, i.e.
    /// skip the Poisson step and keep only the texture. That is the plausible mistake this stage's
    /// whole design exists to avoid: a copy that is masked by a feather looks like a heal in the
    /// middle and is *wrong at the rim*, which is the one place a repair has to be invisible.
    ///
    /// `HealTests.testTheRefutationMakesTheBoundaryJumpFail` turns it on and measures the acceptance's
    /// 「边界跳变 ≤ 2 码」 going from a number to a much larger one — the proof that assertion is about
    /// the arithmetic and not about the blend ramp. The kernel reads it as `HealParamsU.b.y`; it is
    /// never set by the app and never part of a key.
    public var healWithoutBoundaryMatch: Bool

    /// **Tests only.** Read the 1 × 1 airlight texture back to the CPU after the frame, into
    /// `RenderGraph.lastDehazeAirlight` (117's acceptance needs to compare the estimated `A` with the
    /// synthetic veil). The shipped path never reads it back: `s1_9_dehaze_apply` samples the texture
    /// on the GPU, and this flag adds only a 4-byte blit when it is on. Never part of a key.
    public var probesDehazeAirlight: Bool

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
                originalRendersAsParametersCleared: Bool = false,
                bwIndependentChannels: Bool = false,
                gradeGlobalWeights: Bool = false,
                healWithoutBoundaryMatch: Bool = false,
                probesDehazeAirlight: Bool = false) {
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
        self.bwIndependentChannels = bwIndependentChannels
        self.gradeGlobalWeights = gradeGlobalWeights
        self.healWithoutBoundaryMatch = healWithoutBoundaryMatch
        self.probesDehazeAirlight = probesDehazeAirlight
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

/// 112 — the two numbers that drive the export's SDR tone map, named after toGainMapHDR's flags.
///
/// `measurementRatio` is `-r`: the peak is measured on the frame scaled down by `1/r` (larger =
/// keep less highlight). `maxHeadroom` is `-R`: the most headroom the map will spend, as a linear
/// ratio (6 = three stops above white), not an EV count. The defaults are toGainMapHDR's own.
public struct SDRToneMap: Sendable, Equatable {
    public var measurementRatio: Float
    public var maxHeadroom: Float

    public init(measurementRatio: Float = 3, maxHeadroom: Float = 6) {
        self.measurementRatio = Swift.max(1, measurementRatio)
        self.maxHeadroom = Swift.max(1, maxHeadroom)
    }

    /// `-r 3`, `-R 6` — what the export uses unless a caller says otherwise.
    public static let global = SDRToneMap()
}

/// 100 — extended-range **linear** pixels from `s4_display_linear`: same primaries as the SDR base,
/// values are linear light (no OETF), may exceed 1.
///
/// A distinct type from `DisplayImage` on purpose: the two are the same picture in different
/// domains, and mixing them up (feeding linear pixels to the file encoder or OETF-decoding an
/// already-linear map) is a silent colour error. It also keeps `DisplayImage` non-recursive.
public struct LinearPixels: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [Float16]
    public let primaries: OutputPrimaries

    public init(width: Int, height: Int, rgba: [Float16], primaries: OutputPrimaries) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.primaries = primaries
    }

    public init(_ image: DisplayImage) {
        self.init(width: image.width, height: image.height, rgba: image.rgba,
                  primaries: image.primaries)
    }

    /// 113/112 — the **SDR base** of an export: the linear frame first, then the optional global tone
    /// map, then the OETF.
    ///
    /// The order matters. Deriving the base from a separate `s4_display` render would clamp *before*
    /// anything else had a say, so the gain map's ratio would be measured against a picture that was
    /// hard-cut at display white. Here both halves come from the same extended-range frame.
    ///
    /// `toneMap == nil` is the historical path: OETF over `min(v, 1)`, byte-identical to
    /// `s4_display`. `.global` rolls the highlights off with Core Image's `CIToneMapHeadroom`, the
    /// same system filter `toGainMapHDR` uses. A frame whose peak is below 1.05 takes the hard-clamp
    /// path even when `.global` is asked for, so an ordinary SDR document still exports unchanged.
    ///
    /// `srgb_encode` is a function of the half value, so it is table-driven over all 65 536 half bit
    /// patterns: a 60 Mpx frame is 180 M lookups instead of 180 M `pow` calls (measured 0.06 s vs 3.9 s).
    public func displaySDR(bitDepth: Int, toneMap: SDRToneMap? = nil) -> DisplayImage {
        let source = toneMap.flatMap {
            Self.toneMapped(rgba, width: width, height: height, primaries: primaries, map: $0)
        } ?? rgba
        var out = [Float16](repeating: 0, count: source.count)
        let table = Self.srgbHalfTable
        source.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var i = 0
                let n = src.count
                while i < n {
                    // RGB go through the transfer function; alpha is copied verbatim.
                    dst[i] = Float16(bitPattern: table[Int(src[i].bitPattern)])
                    dst[i + 1] = Float16(bitPattern: table[Int(src[i + 1].bitPattern)])
                    dst[i + 2] = Float16(bitPattern: table[Int(src[i + 2].bitPattern)])
                    dst[i + 3] = src[i + 3]
                    i += 4
                }
            }
        }
        // `linear` stays the **input** frame: for an HDR export it is the gain map's numerator, and
        // the tone map above only ever produced the SDR denominator.
        return DisplayImage(width: width, height: height, rgba: out, primaries: primaries,
                            bitDepth: bitDepth, linear: self)
    }

    /// The global roll-off, kept in the **linear** domain so the OETF above stays the single
    /// implementation.
    ///
    /// Same two numbers as `toGainMapHDR`: the peak is measured on the frame scaled by `1/-r`, capped
    /// at `-R`, then Core Image maps `sourceHeadroom → 1` with `CIToneMapHeadroom`. Returns `nil`
    /// when the frame is already SDR (`P < 1.05`), when the used headroom is 1, or when Core Image
    /// cannot produce the map — all three mean "use the byte-identical hard clamp".
    private static func toneMapped(_ rgba: [Float16], width: Int, height: Int,
                                   primaries: OutputPrimaries, map: SDRToneMap) -> [Float16]? {
        guard #available(macOS 15.0, *) else { return nil }

        var peak: Float = 0
        rgba.withUnsafeBufferPointer { src in
            var i = 0
            while i < src.count {
                peak = Swift.max(peak, Swift.max(Float(src[i]),
                                                 Swift.max(Float(src[i + 1]), Float(src[i + 2]))))
                i += 4
            }
        }
        // toGainMapHDR's warning branch: `picHeadroom < 1.05` means the input is effectively SDR.
        guard peak >= 1.05,
              let space = extendedLinearColorSpace(for: primaries) else { return nil }

        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.floatComponents.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16,
                                  bitsPerPixel: 64, bytesPerRow: width * 8, space: space,
                                  bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            return nil
        }
        let context = CIContext(options: [.workingColorSpace: space])
        let input = CIImage(cgImage: image)

        // `-r` — measure the peak on the frame shrunk by `1/r`, so a handful of hot pixels cannot
        // spend the whole highlight range. `areaMaximum` is toGainMapHDR's `maxChannelValue`.
        var sampledPeak = peak
        let ratio = CGFloat(map.measurementRatio)
        if ratio > 1.0001 {
            let scaled = input.transformed(by: CGAffineTransform(scaleX: 1 / ratio,
                                                                y: 1 / ratio))
            let area = CIFilter.areaMaximum()
            area.inputImage = scaled
            area.extent = scaled.extent
            if let maximum = area.outputImage {
                var pixel = [Float](repeating: 0, count: 4)
                context.render(maximum, toBitmap: &pixel,
                               rowBytes: 4 * MemoryLayout<Float>.size,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBAf, colorSpace: nil)
                sampledPeak = Swift.max(pixel[0], Swift.max(pixel[1], pixel[2]))
            }
        }
        if !(sampledPeak >= 1) { sampledPeak = 1 }
        // `-R` — the most headroom the map may spend. `-R` is a ratio (6 = three stops), not an EV
        // count; `toGainMapHDR` warns and clips beyond it, which is exactly this `min`.
        let headroom = Swift.min(sampledPeak, map.maxHeadroom)
        guard headroom > 1.0001 else { return nil }

        let filter = CIFilter.toneMapHeadroom()
        filter.inputImage = input
        filter.sourceHeadroom = headroom
        filter.targetHeadroom = 1
        guard let output = filter.outputImage,
              let mapped = context.createCGImage(output, from: input.extent,
                                                 format: .RGBAh, colorSpace: space) else {
            return nil
        }
        // Read the filtered linear frame back in the same extended space: `createCGImage` may return
        // a lazily backed image, and the batch worker must not hold the CI context.
        var out = [Float16](repeating: 0, count: rgba.count)
        guard let bitmap = CGContext(data: &out, width: width, height: height,
                                     bitsPerComponent: 16, bytesPerRow: width * 8,
                                     space: space, bitmapInfo: info) else { return nil }
        bitmap.draw(mapped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return out
    }

    /// The extended-range linear space matching the output primaries, so Core Image does no colour
    /// conversion — only the headroom roll-off.
    static func extendedLinearColorSpace(for primaries: OutputPrimaries) -> CGColorSpace? {
        switch primaries {
        case .sRGB: return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        case .rec2020: return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        }
    }

    /// `texture → half`, for every half bit pattern: `srgb_encode(min(max(v, 0), 1))`.
    private static let srgbHalfTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 1 << 16)
        for bits in 0..<(1 << 16) {
            let v = Float(Float16(bitPattern: UInt16(bits)))
            let clamped = Swift.min(Swift.max(v, 0), 1)
            let encoded: Float
            if clamped <= 0.0031308 {
                encoded = 12.92 * clamped
            } else {
                encoded = 1.055 * powf(clamped, 1.0 / 2.4) - 0.055
            }
            table[bits] = Float16(encoded).bitPattern
        }
        return table
    }()
}

/// Display-encoded pixels (0…1, sRGB transfer already applied) plus the primaries they are in.
public struct DisplayImage: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [Float16]
    public let primaries: OutputPrimaries
    public let bitDepth: Int
    /// 100 — the **linear** companion for HDR export: the same picture through `s4_display_linear`,
    /// in the same primaries, with extended-range values intact. `nil` for every screen/thumbnail/SDR
    /// render, which is what keeps the default path allocation-free.
    ///
    /// It rides on `DisplayImage` rather than a second return value so the batch engine's
    /// `render -> DisplayImage` closure can carry both halves without a second export pipeline
    /// (`BatchExport.swift` is 099's file and must not be forked).
    public let linear: LinearPixels?

    public init(width: Int, height: Int, rgba: [Float16], primaries: OutputPrimaries, bitDepth: Int,
                linear: LinearPixels? = nil) {
        self.width = width
        self.height = height
        self.rgba = rgba
        self.primaries = primaries
        self.bitDepth = bitDepth
        self.linear = linear
    }

    /// Attach (or clear) the linear companion. Used by the export renderer after the SDR frame.
    public func withLinear(_ image: LinearPixels?) -> DisplayImage {
        DisplayImage(width: width, height: height, rgba: rgba, primaries: primaries,
                     bitDepth: bitDepth, linear: image)
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

/// P1d — the two halves of a histogram measurement inside one frame, as nanoseconds.
///
/// Split deliberately: they have nothing in common to fix. `readback` is `getBytes` of the sampled
/// grid (0.29 MB at 256 long edge, a `.shared` texture — memcpy speed, ~0.03 ms and not movable);
/// `binning` is `Histogram.compute`'s counting loop, which is where the 1.4–1.8 ms used to live.
public struct HistogramCost: Sendable, Equatable {
    /// The sample grid's own dispatch: `pool.obtain` + pipeline lookup + one compute encoder + the
    /// 36 k-thread encode. Small, but it is inside the caller's wall and it is not the binning.
    public var encodeNanoseconds: Int = 0
    /// `getBytes` of the sampled grid.
    public var readbackNanoseconds: Int = 0
    /// `Histogram.compute`'s counting sweep.
    public var binningNanoseconds: Int = 0
    public var totalMilliseconds: Double {
        Double(encodeNanoseconds + readbackNanoseconds + binningNanoseconds) / 1e6
    }
    public static let zero = HistogramCost()
    public init(encodeNanoseconds: Int = 0, readbackNanoseconds: Int = 0,
                binningNanoseconds: Int = 0) {
        self.encodeNanoseconds = encodeNanoseconds
        self.readbackNanoseconds = readbackNanoseconds
        self.binningNanoseconds = binningNanoseconds
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
    /// P1d — what the measurement cost, part by part, in this frame. `histogramMilliseconds` is the
    /// sum of the two, kept because the card prints one number; this is what a stopwatch argues with.
    ///
    /// The split exists because the two halves have different fixes: the readback is a fixed 0.29–0.35
    /// MB copy (already at memcpy speed), and the binning was a single-threaded loop with four `pow`
    /// calls per pixel (~1.5 ms at a 43 k-pixel grid) — `Histogram.measure` now spreads the rows over
    /// the cores, and this is the receipt that says which half moved.
    public let histogramCost: HistogramCost

    init(canvas: ImageSize, content: ImageSize, drawnRect: ImageRect, window: ImageRect,
         keys: StageKeys, trace: RenderTrace, display: DisplayImage?, output: MTLTexture?,
         maskReport: MaskStageReport? = nil, showsMask: Bool = false,
         histogram: Histogram? = nil, histogramMilliseconds: Double = 0,
         histogramSample: LinearSample? = nil, histogramCost: HistogramCost = .zero) {
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
        self.histogramCost = histogramCost
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
    /// P1e — true when those pixels came from the reused slot instead of a pass in **this** frame.
    ///
    /// The overlay is one pointwise pass over the display frame (0.46 ms at 4.10 Mpx). Its output is a
    /// pure function of (display frame, atlas slice, mask id), so a frame whose key chain did not move
    /// — no drag, no parameter, no mask switch, no camera move — would compute the same bytes again.
    /// `showMaskReused` is the receipt that it did not: the pass count over a static run is a fact the
    /// report states per frame rather than something a reader has to believe.
    public var showMaskReused: Bool = false

    /// 081 — pixels the S1.5 kernels *evaluated*, summed over slices (`Σ w·h` of each mask's raster
    /// box), next to what the same atlas would have evaluated with a full-canvas dispatch
    /// (`canvas pixels × slices`). The gap is the saving; `testAtlasRasterIsConfinedToMaskBounds`
    /// asserts on both numbers, so reverting the box to the whole canvas turns it red.
    public var atlasRasterPixels: Int = 0
    public var atlasCanvasPixels: Int = 0
    /// Share of a full-canvas dispatch the atlas actually evaluated (0…1).
    public var atlasRasterFraction: Double {
        atlasCanvasPixels > 0 ? Double(atlasRasterPixels) / Double(atlasCanvasPixels) : 0
    }

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

/// Mirror of `Kernels/s0_geometry.metal`, byte for byte: **7 float4 + float4x4 = 176 bytes** (a
/// mismatch reads the wrong uniform and does not fail, so `ChromaticAberrationTests` asserts the
/// number on both sides).
struct S0Params {
    var a: SIMD4<Float>   // canvasSize.xy, contentOrigin.xy
    var b: SIMD4<Float>   // contentSize.xy, srcSize.xy
    var c: SIMD4<Float>   // crop rect
    var d: SIMD4<Float>   // cos, sin, flipH, flipV
    var e: SIMD4<Float>   // identity, backgroundOutside, pureCA, pad
    var f: SIMD4<Float>   // frameSize.xy, frameOrigin.xy (content pixels of the whole frame)
    var g: SIMD4<Float>   // caRed, caBlue, quarterTurns, pad (029 / P0-10)
    /// 097: columns 0/1/2 = R/G/B radial coefficients (kr0…kr3), column 3 = normalized centre.
    /// Read only by the `_lens` entry points; identity for every other document.
    var lens: simd_float4x4
}

private struct S1Params {
    var a: SIMD4<Float>   // gain, wbR, wbG, wbB
    var b: SIMD4<Float>   // recovery, identity, blacks, whites
    // contentOrigin.xy, contentSize.xy in canvas pixels — the letterbox guard (派单 008 B), in S1
    // because the dropper's level and 071's offset both move the matte's 0. Same convention as S0's
    // `a`/`b` and S3c's `c`. (073B's knee keeps 0 at 0, but the other two spellings do not.)
    var c: SIMD4<Float>
    // 071: blackOffset, pad, pad, pad — the additive linear trim, applied between the level and the
    // gain. 0 for every document that never used the control, and then the kernel's `kTrim` is false.
    var e: SIMD4<Float>
}

private struct S2Params {
    // 085 — dShadow, dMid, dHighlight (all EV, already gated by `S2Regions.travelEV`), identity.
    var b: SIMD4<Float>
    // contentOrigin.xy, contentSize.xy in canvas pixels — the letterbox guard (派单 008 B). Without
    // it the region lifts treat the matte's 0 as a picture pixel and the viewport's background bars
    // light up. Same convention as S0's `a`/`b`, S1's `c` and S3c's `c`.
    var c: SIMD4<Float>
}

/// 098 — mirror of `ContrastParams` in `Kernels/s1_8_contrast.metal`, byte for byte. One struct for
/// every pass of the stage; each kernel reads the fields it needs.
private struct ContrastParamsU {
    var a: SIMD4<Float>    // t (= contrast/100), pivot EV, coarse ε, mid ε
    var b: SIMD4<Float>    // k_c, k_m, k_f, gate lower knee
    var c: SIMD4<Float>    // gate upper knee, pad, pad, pad
    var luma: SIMD4<Float> // Rec2020 luma weights, pad
    var rect: SIMD4<Float> // contentOrigin.xy, contentSize.xy (canvas pixels)
    var d: SIMD4<Int32>    // canvasW, canvasH, q, coarse radius in the 1/q domain
    var e: SIMD4<Int32>    // qW, qH, segment length, mid radius in the 1/q domain
    var f: SIMD4<Int32>    // mode (0 = G statistics, 1 = D1 statistics), pad, pad, pad
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

/// Mirror of `Kernels/s3_6_hsl.metal`'s two structs (派单 076, global triplet 101).
private struct HSLParamsU {
    var a: SIMD4<Float>   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    var g: SIMD4<Float>   // 101 — global: hue, saturation, luminance (slider units), pad
}

/// Mirror of `Kernels/s3_4_bw.metal` (2026-10-28, P0-4). The band table is the **same**
/// `HSLBandU` array S3.6 uploads — one band geometry, two consumers.
private struct BWParamsU {
    var a: SIMD4<Float>   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    var b: SIMD4<Float>   // perChannelGrey (tests only), stops per full mix, pad, pad
}

/// One band as the kernel reads it: the three slider values in units, and the reach towards the
/// previous/next centre in **OKLCh degrees** (which is what makes the weights a partition of unity).
private struct HSLBandU {
    var v: SIMD4<Float>   // hue, saturation, luminance (units), centre (OKLCh degrees)
    var e: SIMD4<Float>   // halfWidth to the previous centre, halfWidth to the next, pad, pad
}

/// Mirror of `Kernels/s3_8_grade.metal` (2026-10-28, P0 色彩分级), byte for byte.
///
/// Three `float4`s — one per wheel, each `(hue, saturation, lightness)` in slider units — plus the
/// content rect and the one test-only flag. Slider units, not converted values: the kernel converts
/// after blending (`ColorGrade.effective` does the same on the host), which is what makes a neutral
/// wheel deliver exactly zero in its own region.
private struct GradeParams {
    var a: SIMD4<Float>   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    var b: SIMD4<Float>   // globalWeights (tests only), pad, pad, pad
    var sh: SIMD4<Float>  // shadows:    hue, saturation, lightness, 0
    var mid: SIMD4<Float> // midtones:   hue, saturation, lightness, 0
    var hi: SIMD4<Float>  // highlights: hue, saturation, lightness, 0
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

/// Mirror of `Kernels/s3_8_detail_fx.metal`, byte for byte. One struct for every pass of the stage:
/// each kernel reads the two or three fields it needs and ignores the rest, so the CPU side has one
/// object to keep in step with one header.
private struct DetailFXParamsU {
    var a: SIMD4<Float>    // texture, clarity amounts (−1…1 = the document's −100…100 /100), pad, pad
    var luma: SIMD4<Float> // Rec.709 luma weights, pad
    var d: SIMD4<Float>    // epsilon (this band's), unread, unread, unread
    var e: SIMD4<Float>    // gradient gate: g0, g1 (luma per 1/q texel), pad, pad
    var b: SIMD4<Int32>    // canvasW, canvasH, q (statistics block), radius in the 1/q domain
    var c: SIMD4<Int32>    // qW, qH, segment length, pad
}

/// Mirror of `Kernels/s1_9_dehaze.metal`, byte for byte (117).
private struct DehazeParamsU {
    var a: SIMD4<Float>   // amount (−1…1), ω, t0, "no haze" threshold for A
    var b: SIMD4<Float>   // content rect: origin x, origin y, width, height (canvas pixels)
    var c: SIMD4<Int32>   // canvasW, canvasH, q (block size), qW
    var d: SIMD4<Int32>   // qH, pad, pad, pad
}

private struct DisplayParams {
    var m: simd_float4x4
    var a: SIMD4<Float>   // identityMatrix
}

// MARK: - heal uniforms (mirror of s1_9_heal.metal, byte for byte)

/// One spot, in **canvas pixels**: `center = origin − frameOrigin + c·frameSize`, `radius` and the
/// offset scaled by the frame's short edge (`HealSpotU` in the kernel's own words).
private struct HealSpotU {
    var a: SIMD4<Float>   // centerCanvas.xy, radiusPx, feather
    var b: SIMD4<Float>   // offsetCanvas.xy, opacity, mode (0 heal, 1 clone)
}

private struct HealParamsU {
    var a: SIMD4<Float>   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    var b: SIMD4<Float>   // spotCount, boundaryMatch, 0, 0
}

/// The fitted boundary plane, one record per spot (`HealStatU` in the kernel).
private struct HealStatU {
    var c0: SIMD4<Float>   // R: a0, a1, b1, 0
    var c1: SIMD4<Float>   // G
    var c2: SIMD4<Float>   // B
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
    // `w` is 1 when any component reads the picture (kind 3/4) — the kernel's `needsPicture`.
    var meta: SIMD4<Int32>   // firstComponent, componentCount, invert, needsPicture
    var misc: SIMD4<Float>   // opacity
    // 081 — the canvas box this slice can be non-zero in, half-open (`x0, y0, x1, y1`).
    var rect: SIMD4<Int32>
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
    var b: SIMD4<Float>   // contrast, **dHighlight EV**, **dShadow EV**, whites (085: the two lifts
                          // arrive as gated EV displacements, exactly like S2's `b`)
    // blacks, contrast travel (079 §2.1.2: the EV of bend at |contrast| = 100, `S2Contrast.travel`'s
    // derivation — was a pad until the masked contrast became 0107's bounded bend), pad, enabled.
    var c: SIMD4<Float>
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
    /// 081 — the dispatch window's origin inside the unchanged lattice (see the kernel).
    var b: SIMD4<Int32>   // xFirst, yFirst, pad, pad
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
        /// 081 — the **same texture**, addressable a second way: by the key of the *composite*, i.e. of
        /// the last stage in the pipeline that owns a generic entry.
        ///
        /// The two keys answer two different questions. `key` is the per-stage key the walk consults
        /// ("would this stage's output be the one this document asks for?"). `resumeKey` is the
        /// question a frame with an unchanged document can ask in one go ("is the *whole chain* up to
        /// here the same?"), and only the last stage stores one. See `compositeKey(_:_:…)`.
        let resumeKey: String?
        let texture: MTLTexture
    }

    private var cache: [RenderStage: CacheEntry] = [:]
    private var cacheOrder: [RenderStage] = []
    /// 081 — **the cache is asked the composite question, and its budget did not move.**
    ///
    /// `local/perf/perf-baseline-2026-10-28.md` §3.3 measured a 60.32 Mpx export frame whose document
    /// was **untouched** at 59 ms against 85 ms with nothing reused: it re-ran **8 of the 11** stages
    /// (`s0 s1.7 s2 s3-color s3.5 s3.6 s3-vignette s4`). The cause was not an algorithm but arithmetic:
    /// the budget was the constant `1_500_000_000` bytes, one intermediate at this canvas is 483 MB, so
    /// three fit while seven stages own an entry — and because a frame inserts as it walks, the three
    /// that survived were the *last* three, with S0 always the first victim. At 4.10 Mpx the same code
    /// is perfect (1.5 GB = forty-five 32.8 MB frames) and the hot frame is S4 alone, 0.38 ms.
    ///
    /// There are two ways to make 60 Mpx behave like that, and they are not equivalent:
    ///
    ///   · **raise the budget** to one frame per stage (3.38 GB at 60 Mpx). Measured: hot 5.47 ms, one
    ///     stage — and **+1.93 GB of Metal** (4.0 more live 483 MB textures, 8.3 → 10.2 GB at the
    ///     steady state), because a retained entry is a texture the pool can no longer hand to the next
    ///     stage. It buys the number with memory at exactly the scale where memory is the constraint.
    ///   · **make the cache answer once what it is about to be asked eight times.** The key chain is a
    ///     hash chain (`RenderKeyChain.links`: each link is `H(digest(previous) | own material)`), so
    ///     "the last stage's composite key is unchanged" *implies* "every upstream stage's key is
    ///     unchanged". A frame can therefore check the composite **before walking**, and if it hits,
    ///     start at S4. The composite entry is the last stage's own texture — no extra texture, no
    ///     budget change, no change at 4.10 Mpx.
    ///
    /// This is the second one. The trade it makes: the win applies to the frame that changed *nothing*
    /// (the one the user sees when they are not dragging: release-after-drag, zoom/pan, a re-paint, the
    /// export's repeat frame), and a frame that changed one slider still runs its suffix — which is
    /// correct, since its suffix genuinely has to be recomputed. It also means the cache can stay
    /// 1.5 GB at every canvas size: nothing here claims a big canvas deserves a bigger cache.
    public private(set) var cacheBytes = 0
    public var cacheEntryCount: Int { cache.count }
    /// How many frames started from the composite instead of walking the pipeline, over this graph's
    /// life. The number the acceptance reads (it must be 1 per unchanged frame after the first).
    public private(set) var compositeResumes = 0

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

    /// Whether S3.4 is put into the pipeline **even for a colour document**. **Never true in the
    /// app.**
    ///
    /// `BlackAndWhiteTests.testTheRefutationRunsTheKernelWithTheSwitchOff` sets it and shows what the
    /// structural claim buys: the same colour document, with the pass encoded, comes back as a
    /// different frame — so "the frame is byte-identical because the stage does not exist" is a fact
    /// about the pipeline rather than a hope about the kernel's arithmetic. It forces the *key* to say
    /// `bw=1` too (the stage has to exist for the trace, which is what the key set drives), which is
    /// why the forced render also changes the chain: a stage that runs must be a stage that is keyed.
    private let bwStageAlwaysRuns: Bool

    /// 073 — how many times each stage **ran**, and how many times its output came out of a cache,
    /// over the life of this graph. Merged from the frame's own trace at the end of `render`, so the
    /// counters cannot disagree with what the frame reported (`.sceneLinear` and `.localApply`
    /// included, both of which now have slots of their own).
    public private(set) var stageRuns: [RenderStage: Int] = [:]
    public private(set) var stageHits: [RenderStage: Int] = [:]
    /// **Tests only** — the airlight `A` S1.9 estimated on the last frame, when
    /// `RenderOptions.probesDehazeAirlight` asked for it. `nil` when the stage did not run or the flag
    /// is off, which is what makes "the production path never reads it back" checkable.
    public private(set) var lastDehazeAirlight: Double?
    /// The 4-byte readback the probe queues inside the frame's command buffer; consumed after commit.
    private var dehazeAirlightProbe: MTLBuffer?
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
    /// P1e — the `showMask` overlay's own reuse slot: the display frame with the overlay painted, plus
    /// the key it was painted for.
    ///
    /// The pass is one pointwise compute over the whole canvas reading the atlas slice, and its output
    /// is a pure function of the display frame the key chain already names, the slice, and the mask id.
    /// A frame that moved none of those (a workspace switch, a redraw after the window regained focus,
    /// an animation that never touched the document) used to pay it again — 0.46 ms at 4.10 Mpx, a whole
    /// S4 for pixels that would be byte-identical. This slot is what turns that into a lookup.
    ///
    /// The texture here is the graph's, not the pool's: it is handed out as a frame so the canvas can
    /// present it, and `recycle(output:)` refuses to pool it (see there). Dropped whenever a frame shows
    /// no overlay, so hiding the mask returns the canvas-sized texture instead of holding 32.8 MB.
    private struct ShowMaskEntry {
        /// Everything the pass reads: the upstream chain's resume key, the display key, the atlas key,
        /// the mask id and the slice. Equal key ⇒ equal pixels.
        let key: String
        let texture: MTLTexture
    }
    private var showMaskEntry: ShowMaskEntry?
    /// How many times the overlay pass has actually run on this graph. The counter exists for the same
    /// reason `compositeResumes` does: "it was skipped 20 times" is a measurement, not an opinion.
    public private(set) var showMaskPasses: Int = 0
    /// One reusable array texture (allocation on a size/count change only).
    private var atlasPool: (key: String, texture: MTLTexture)?
    private var maskTables: [String: MaskTable] = [:]

    public init(input: RenderInput, cacheBudgetBytes: Int = 1_500_000_000,
                semanticMatte: SemanticMatteProvider = SystemSemanticMatteProvider(),
                textureRetention: TextureRetention = .oneFrame,
                s1KeyIncludesRedGroup: Bool = true,
                bwStageAlwaysRuns: Bool = false) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noMetalDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.noMetalDevice }
        self.device = device
        self.queue = queue
        self.deviceName = device.name
        self.kernels = KernelLibrary(device: device)
        self.input = input
        self.cacheBudgetBytes = cacheBudgetBytes
        self.s1KeyIncludesRedGroup = s1KeyIncludesRedGroup
        self.bwStageAlwaysRuns = bwStageAlwaysRuns
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
        /// 2026-10-28 (P0-10): the document is *only* turned (full crop, no straighten, no flips, no
        /// CA, 1:1, no window), so S0's map is a permutation of the source's texels and the kernel
        /// may index them in integers. `s0_geometry.metal`'s `p.e.w`.
        let s0PureTurn: Bool
        /// 097 / 103: this frame must run the file's own lens warp (DNG per-plane or Panasonic). It
        /// turns the three fast paths off, because each of them is a sampling shortcut that would
        /// bypass the warp.
        let s0LensWarp: Bool
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

    /// The document the key chain sees. Identical to `edit` except under `bwStageAlwaysRuns`, where it
    /// is the same document with the 黑白 switch forced **on**, so S3.4 gets a link and therefore a
    /// place in `Plan.stages` — the refutation described on that property.
    private func keyEdit(_ edit: EditModel) -> EditModel {
        guard bwStageAlwaysRuns, !edit.hasBlackAndWhite else { return edit }
        var forced = edit
        forced.color.blackAndWhite = true
        return forced
    }

    private func plan(_ edit: EditModel, _ options: RenderOptions) -> Plan {
        // The aspect lock and the ±45 straighten limit are resolved here, once: S0 receives a plain
        // normalized rect plus cos/sin, exactly the shape it always had.
        // Schema 9 (P0-10): the crop rect is measured in the **turned** frame, so the picture's
        // pixel size is the rect against the turned source. For `quarterTurns == 0`
        // `orientedSource` is the identity and this is the pre-9 line, byte for byte.
        let crop = edit.geometry.renderCrop(source: sourceSize)
        let orientedSource = edit.geometry.orientedSource(sourceSize)
        let cropPixels = CropMath.outputSize(crop, in: orientedSource)
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

        // 097: the lens profile is a **file** fact that changes which source pixel each channel
        // reads, so it belongs in S0's geometry link when — and only when — we are the ones warping.
        // The Apple path (one plane) and every pre-097 file append nothing, keeping their keys.
        let lensWarp = input.hasPerPlaneLensWarp
        let keys = RenderKeyChain.keys(RenderKeyChain.links(identity: input.identity,
                                                            sourceSize: sourceSize,
                                                            canvas: canvas,
                                                            content: content,
                                                            edit: keyEdit(edit),
                                                            display: options.display,
                                                            outputWindow: window,
                                                            orientation: orientation,
                                                            lens: lensWarp ? input.lensProfile?.recipeComponent : nil),
                                       identity: input.identity)
        // 029: S0's fast paths. "Nothing to transform" is the pre-029 identity condition; on top of
        // it, CA either keeps the frame the identity copy (α = 0) or needs the three-sample branch
        // with `framePx` taken directly (α ≠ 0). A CA document with a crop, a rotation or a scale
        // falls through to the general path — same `px` as before, only R/B from a scaled radius.
        let untransformed = crop == .full
            && edit.geometry.rotationDegrees == 0
            && edit.geometry.quarterTurns == 0
            && !edit.geometry.flipHorizontal && !edit.geometry.flipVertical
            && content == sourceSize && canvas == sourceSize
            && window == nil
        let caOn = !edit.optics.isIdentity
        // 2026-10-28 (P0-10): the turn's own fast path — the document is *only* turned, full crop,
        // 1:1, no window, no CA. Then S0's map is a lattice permutation of the source and the kernel
        // indexes it in `int`s (`s0_geometry.metal`, `p.e.w`) instead of round-tripping through
        // `uv × srcSize`, which at 9504 px is worth ~1e-3 of a texel: a resample of an operation that
        // has no arithmetic in it, and four of them would not give the original bytes back.
        let s0PureTurn = edit.geometry.quarterTurns != 0
            && crop == .full
            && edit.geometry.rotationDegrees == 0
            && !edit.geometry.flipHorizontal && !edit.geometry.flipVertical
            && !caOn
            && content == orientedSource && canvas == orientedSource
            && window == nil
        return Plan(canvas: canvas, content: content, origin: origin, crop: crop, frame: frame,
                    window: window, frameSize: frameSize, frameOrigin: frameOrigin,
                    frameInCanvas: frameInCanvas, backgroundOutside: backgroundOutside, keys: keys,
                    s0Identity: untransformed && !caOn && !lensWarp,
                    s0PureCA: untransformed && caOn && !lensWarp,
                    s0PureTurn: s0PureTurn && !lensWarp,
                    s0LensWarp: lensWarp, drawnRect: drawnRect)
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
    ///   · `edit.keyMaterial(.sceneLinear)` — the levels (`blk`/`wht` sliders) and 071's
    ///     `blackOffset` (schema 11 deleted 030's absolute `blackLevel`/`whiteLevel`, so they no longer
    ///     appear here), the exposure gain, white balance (a decode input, so the
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
    ///
    /// 081 — the key that lets a frame skip the walk: **everything the pipeline's stages are keyed by,
    /// in one string.**
    ///
    /// `RenderKeyChain.links` is a hash chain — each link is `H(digest(previous) | own material)` — so
    /// the last link being equal already implies every earlier one is. This string is written out
    /// explicitly rather than leaned on for two reasons: the walk's own keys are the link **plus** the
    /// environment suffixes (`tilingSuffix`, `semanticSuffix`) that live outside the chain, and S1's slot
    /// key is a *narrowing* of its link (`s1Key`, 073) which the chain cannot be trusted to imply when
    /// the test hook strips the red group. Concatenating both is a few hundred bytes and removes the
    /// question.
    ///
    /// The composite is the **last stage that owns a generic cache entry** — the stage whose output
    /// feeds S4. Its entry is the texture the pipeline already produced, so the resume costs no texture.
    ///
    /// (Separate from `s1Key` below, which is 073's slot key: this one composes that key *with* the
    /// chain's last link; neither replaces the other.)
    private func compositeKey(_ edit: EditModel, _ plan: Plan, stage: RenderStage,
                              tilingSuffix: String, semanticSuffix: String) -> String {
        plan.keys.key(for: stage)
            + (stage.isMaskStage ? tilingSuffix : "")
            + (stage.index >= RenderStage.maskAtlas.index ? semanticSuffix : "")
            + "|s1:" + s1Key(edit, plan)
    }

    /// Whether a stage keeps an entry in the **generic** cache: not S4 (its texture is handed to the
    /// caller), not S1.5 (a side output in `atlasCache`), not S1 (`s1Entry`) and not S1.6 (`localEntry`),
    /// which all have slots of their own.
    private static func ownsGenericCacheEntry(_ stage: RenderStage) -> Bool {
        stage != .display && stage != .sceneLinear && stage != .maskAtlas && stage != .localApply
    }

    private func s1Key(_ edit: EditModel, _ plan: Plan) -> String {
        guard !s1KeyIncludesRedGroup else { return plan.keys.key(for: .sceneLinear) }
        var stripped = edit
        stripped.light.blacks = 0
        stripped.light.whites = 0
        stripped.light.blackOffset = 0
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
        // 117: the airlight probe is per frame. A stale value from an earlier probed render must not
        // look like this frame's estimate, and a frame without the flag reports `nil`.
        dehazeAirlightProbe = nil
        lastDehazeAirlight = nil
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
        let table = decodeOnly ? nil : try maskTable(for: edit, plan: plan, semantics: semantics)
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

        // 081 — the frame that changed nothing asks the cache **one** question instead of eleven.
        //
        // The composite is the last stage with a generic entry (`s3-vignette` on a full document,
        // `s3-color` without a vignette, `s0` on the decode path). If its `resumeKey` still matches, then
        // every stage above it would have been a hit anyway — the chain is a hash chain and the resume
        // key spells out the link, the environment suffixes and S1's own slot key (see `compositeKey`) —
        // so the walk starts at S4 and the frame costs one pass instead of the 8 this canvas used to pay.
        //
        // Both halves are gated on `useCache`, so a cache-off frame runs exactly the code it ran before
        // 081: not a comparison, not a concatenation. That is what keeps the cold number a number this
        // change cannot move.
        let compositeStage = options.useCache
            ? stages.last { RenderGraph.ownsGenericCacheEntry($0) } : nil
        let compositeKey = compositeStage.map {
            compositeKey(edit, plan, stage: $0, tilingSuffix: tilingSuffix, semanticSuffix: semanticSuffix)
        }
        var firstStage = 0
        if options.useCache, let compositeStage, let compositeKey,
           let entry = cache[compositeStage], entry.resumeKey == compositeKey,
           entry.texture.width == plan.canvas.width, entry.texture.height == plan.canvas.height,
           // `showMask` draws from the atlas S1.5 built; a resume would start after it.
           edit.showMaskID == nil || atlasCache != nil {
            let compositeIndex = stages.firstIndex(of: compositeStage) ?? (stages.count - 1)
            for stage in stages[...compositeIndex] { trace.record(stage, executed: false) }
            touchCache(compositeStage)
            current = entry.texture
            firstStage = compositeIndex + 1
            compositeResumes += 1
            // The all-hit walk leaves exactly this behind for the mask report: the local stage did not
            // run, so there are no tiles — the same `TilePlan` the S1.6 hit branch records.
            if report != nil {
                report?.localPlan = TilePlan(tiles: [], pixelCount: 0,
                                             canvasPixelCount: plan.canvas.pixelCount,
                                             dependency: .pointwise, tiled: false)
            }
        }
        for stage in stages[firstStage...] {
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
                    report?.atlasRasterPixels = stageReport.atlasRasterPixels
                    report?.atlasCanvasPixels = stageReport.atlasCanvasPixels
                }
                trace.record(stage, executed: true)
                atlasCache = AtlasEntry(key: key, texture: atlas, ids: table.ids)
                continue
            }

            // S4 is never cached: its output is handed to the caller (or read back), so it must not
            // be a texture the pool or the cache could later reuse.
            if stage != .display, options.useCache, let hit = cache[stage], hit.key == key {
                trace.record(stage, executed: false)
                touchCache(stage)
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
                insertCache(stage, key: key, texture: out,
                            resumeKey: stage == compositeStage ? compositeKey : nil)
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
        var pendingOverlay: ShowMaskEntry?
        /// Textures this frame has finished reading but that must not come back to the pool until the
        /// command buffer that reads them has run.
        ///
        /// `shown` is the overlay pass's input, and it is still an input when its encoder ends — encoding
        /// is not executing. Pooling it at that line was safe only while nothing else asked for a canvas
        /// between there and the commit, and the histogram grid is exactly that ask whenever the picture
        /// is small enough for the grid to be the canvas (`frameSampleSize` returns the picture's own
        /// size below 256 on the long edge). The grid is then handed `shown` back and a later encoder in
        /// the same command buffer writes the sampled pre-S4 picture into it: the overlay pass reads it
        /// first (encoders run in order, so the wash survives), but on a reuse hit `shown` *is* the frame
        /// being presented, and the readback then reads the grid instead of the frame. Deferring the
        /// recycle is what makes the frame's own recycles independent of the encoders' order.
        var finishedReading: [MTLTexture] = []
        if !decodeOnly, let wanted = edit.showMaskID, let atlas = atlasCache, let shown = finish,
           let slice = atlas.ids.firstIndex(of: wanted) {
            // P1e — the key this pass's output is a function of. `compositeKey` is the resume key of the
            // last stage above S4 (081): when it matches, every stage upstream of S4 would have been a
            // hit, so the frame S4 read is the same bytes the slot was painted over. The display key
            // adds the panel options S4 encodes with, the atlas key adds the selection and the tiling
            // the slice came from, and the id/slice name which slice was painted.
            let atlasKey = plan.keys.key(for: .maskAtlas) + tilingSuffix + semanticSuffix
            // The window and the drawn rect are in the key as well even though the display key should
            // already name them: a false miss costs one pass, a false hit shows yesterday's frame, so
            // the gate errs on the side of painting.
            let window = plan.windowRect
            let drawn = plan.drawnRect
            let overlayKey = [compositeKey ?? "", plan.keys.key(for: .display), atlasKey,
                              wanted, "\(slice)", "\(plan.canvas.width)x\(plan.canvas.height)",
                              "\(window.x),\(window.y),\(window.width),\(window.height)",
                              "\(drawn.x),\(drawn.y),\(drawn.width),\(drawn.height)"]
                .joined(separator: "|")
            if let entry = showMaskEntry, entry.key == overlayKey {
                // Nothing the pass reads moved: the pixels it would write are the ones already in hand.
                // The display frame this frame just produced is not needed — give it straight back so
                // the pool is left exactly as a cached frame leaves it.
                finishedReading.append(shown)
                finish = entry.texture
                if report != nil {
                    report?.showMaskID = wanted
                    report?.showMaskSlice = slice
                    report?.showMaskReused = true
                }
            } else {
                let overlay = try pool.obtain(plan.canvas)
                let p = try kernels.pipeline(file: "s4_show_mask", function: "s4_show_mask")
                guard let enc = cb.makeComputeCommandEncoder() else {
                    pool.recycle(overlay)
                    throw RenderError.commandBufferFailed
                }
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
                // so recycling it here is what keeps the pool honest — but only once the pass above has
                // actually run it (see `finishedReading`).
                finishedReading.append(shown)
                finish = overlay
                // Not committed to the slot yet: the pass is only a pass once the command buffer
                // succeeded, and a slot pointing at a texture from a frame that threw would hand the
                // next frame an uninitialised canvas.
                pendingOverlay = ShowMaskEntry(key: overlayKey, texture: overlay)
                if report != nil {
                    report?.showMaskID = wanted
                    report?.showMaskSlice = slice
                    report?.showMaskReused = false
                }
            }
            showsMask = true
        } else if !decodeOnly, edit.showMaskID == nil {
            // Hiding the overlay releases the slot: a canvas-sized texture (32.8 MB at 4.10 Mpx) held
            // for a pass that is not being shown is memory the next frame's stages want.
            if let old = showMaskEntry {
                pool.disown(old.texture)
                pool.recycle(old.texture)
            }
            showMaskEntry = nil
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
        var histogramCost = HistogramCost.zero
        let gridEncodeStart = DispatchTime.now().uptimeNanoseconds
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
            histogramCost.encodeNanoseconds = Int(DispatchTime.now().uptimeNanoseconds - gridEncodeStart)
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        cb.commit()
        cb.waitUntilCompleted()
        let wall = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        if let err = cb.error {
            throw RenderError.executeFailed(err.localizedDescription)
        }
        if let probe = dehazeAirlightProbe {
            let bits = probe.contents().load(as: UInt16.self)
            lastDehazeAirlight = Double(Float16(bitPattern: bits))
            dehazeAirlightProbe = nil
        }
        // The frame's inputs go back to the pool only now — after the command buffer that reads them
        // has run, and before the next frame asks for a canvas.
        for t in finishedReading { pool.recycle(t) }
        let gpu = (cb.gpuEndTime > 0 && cb.gpuEndTime > cb.gpuStartTime)
            ? (cb.gpuEndTime - cb.gpuStartTime) * 1000
            : wall
        trace.gpuMilliseconds = gpu
        // P1e — the overlay pass's output becomes the slot only now that it really ran. What the slot
        // replaces is the graph's own texture, so it goes back to the pool here rather than being
        // dropped on the floor (`recycle(output:)` refuses to pool the slot's texture, so nothing else
        // could have taken it).
        if let pending = pendingOverlay {
            if let old = showMaskEntry, old.texture !== pending.texture {
                pool.disown(old.texture)
                pool.recycle(old.texture)
            }
            // The slot's texture leaves circulation here: `render` hands it out as this frame's pixels,
            // and the next frame may present it untouched. Any caller that returns the frame — through
            // `recycle(output:)` or straight into `pool.recycle` — now hits a pool that refuses it.
            pool.own(pending.texture)
            showMaskEntry = pending
            showMaskPasses += 1
        }
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
                let rbStart = DispatchTime.now().uptimeNanoseconds
                let sample = readSample(grid.texture)
                let rbEnd = DispatchTime.now().uptimeNanoseconds
                histogramSample = sample
                histogramCost.readbackNanoseconds = Int(rbEnd - rbStart)
                if options.collectHistogram {
                    // 070: the picture's own pixels, sampled off the scene-linear texture (not S4's
                    // clamped output, which cannot hold anything above the panel's headroom).
                    // Labelled with the **picture's** own grid, exactly as `measureFrameHistogram`
                    // labels its numbers, so the card's canvas/ROI and 「采样 N px」 mean the same thing
                    // whichever path measured: the render's canvas is a viewport (or a backdrop's
                    // 4096), and neither is the picture.
                    let pixels = edit.geometry.outputPixels(in: sourceSize)
                    let own = ImageRect(x: 0, y: 0, width: pixels.width, height: pixels.height)
                    let binStart = DispatchTime.now().uptimeNanoseconds
                    histogramPayload = Histogram.compute(sample, bins: bins, rect: nil,
                                                         headroom: options.display.headroom)
                        .relabelled(canvas: pixels, roi: own)
                    histogramCost.binningNanoseconds =
                        Int(DispatchTime.now().uptimeNanoseconds - binStart)
                    histogramMilliseconds = histogramCost.totalMilliseconds
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
            // The overlay's slot texture is the graph's (see `recycle(output:)`); recycling it here
            // would hand the next frame's stages a texture the slot still points at.
            if showMaskEntry?.texture !== finalTexture { pool.recycle(finalTexture) }
            return RenderResult(canvas: plan.canvas, content: plan.content,
                                drawnRect: plan.drawnRect,
                                window: plan.windowRect, keys: plan.keys,
                                trace: trace, display: pixels, output: nil, maskReport: report,
                                showsMask: showsMask, histogram: histogramPayload,
                                histogramMilliseconds: histogramMilliseconds,
                                histogramSample: histogramSample,
                                histogramCost: histogramCost)
        }
        return RenderResult(canvas: plan.canvas, content: plan.content,
                            drawnRect: plan.drawnRect,
                            window: plan.windowRect, keys: plan.keys,
                            trace: trace, display: nil, output: finalTexture, maskReport: report,
                            showsMask: showsMask, histogram: histogramPayload,
                            histogramMilliseconds: histogramMilliseconds,
                            histogramSample: histogramSample,
                            histogramCost: histogramCost)
    }

    /// Return a texture handed out by `render(..., wantsPixels: false)`.
    ///
    /// One texture is the exception: the `showMask` overlay's slot (P1e). Its output is handed out as a
    /// frame so the canvas can present it, but the graph keeps it as the next static frame's pixels —
    /// pooling it would let the next stage allocation overwrite the very bytes the slot promises to
    /// reuse, and the frame after that would present a corrupted overlay. It is the graph's texture, so
    /// "returning" it is a no-op; it goes back to the pool when the slot is replaced (`invalidateCache`,
    /// a new overlay key, or the overlay being hidden).
    public func recycle(output: MTLTexture) {
        // Belt and braces: `TexturePool.recycle` refuses an owned texture too, which is what protects
        // the callers that never come through here (`maskAtlasWithReport` did not).
        if let e = showMaskEntry, e.texture === output { return }
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
        let cropPixels = edit.geometry.outputPixels(in: sourceSize)
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
        let cropPixels = edit.geometry.outputPixels(in: sourceSize)
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
        if let e = showMaskEntry {
            pool.disown(e.texture)
            pool.recycle(e.texture)
        }
        showMaskEntry = nil
    }

    // MARK: - 2026-10-28 (P1b): what this graph is holding, and how to give it back

    /// Bytes of frame texture this graph keeps **for a later frame**: the stage cache, S1's and S1.6's
    /// slots and the mask atlas. A document that is open but idle costs this.
    public var heldTextureBytes: Int {
        var bytes = cacheBytes + s1CacheBytes
        if let e = localEntry { bytes += e.texture.width * e.texture.height * 8 }
        if let e = showMaskEntry { bytes += e.texture.width * e.texture.height * 8 }
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

    /// Least-recently-**used**, not least-recently-inserted.
    ///
    /// The old policy was FIFO (`cacheOrder.removeFirst()`), and on a cache that cannot hold the whole
    /// pipeline FIFO evicts exactly the wrong entry: a frame always walks S0 → S4, so insertion order
    /// *is* pipeline order, and the oldest insertion is the most upstream — the one every downstream
    /// stage is built from. A hit now moves the entry to the back, so what a budget squeeze throws
    /// away is the stage nobody has asked for in the longest time.
    private func touchCache(_ stage: RenderStage) {
        guard let i = cacheOrder.lastIndex(of: stage), i != cacheOrder.count - 1 else { return }
        cacheOrder.remove(at: i)
        cacheOrder.append(stage)
    }

    private func insertCache(_ stage: RenderStage, key: String, texture: MTLTexture,
                             resumeKey: String? = nil) {
        if let old = cache[stage] {
            // 081: a stage that used to be the composite is no longer addressable that way.
            cacheBytes -= Int(old.texture.width * old.texture.height * 8)
            cacheOrder.removeAll { $0 == stage }
            pool.recycle(old.texture)
        }
        cache[stage] = CacheEntry(key: key, resumeKey: resumeKey, texture: texture)
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
        let count = w * h * 4
        // P1d — `unsafeUninitializedCapacity` instead of `repeating: 0`: `getBytes` writes every byte of
        // the buffer below, so zeroing 0.35 MB first is a memset (and a page fault) this path pays for
        // nothing, once per measured frame. `initializedCount` is only raised after the copy, so a
        // buffer that was not fully written can never be handed out as a sample.
        let rgba: [Float16] = Array(unsafeUninitializedCapacity: count) { buffer, initializedCount in
            texture.getBytes(buffer.baseAddress!,
                             bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                             from: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0)
            initializedCount = count
        }
        return LinearSample(width: w, height: h, rgba: rgba)
    }

    // MARK: - S1.9 — 修复 / 克隆 (078 P0-1)

    /// The spot list as the kernel reads it: **canvas pixels**, derived from the frame the plan
    /// resolved. One conversion, here, so the pass and any measurement of it cannot disagree about
    /// where a disk is.
    ///
    /// `center_canvas = origin − frameOrigin + c·frameSize`, `radius = r·min(frameSize)`,
    /// `offset = o·min(frameSize)`. That is exactly the mapping S0 uses to place the picture in the
    /// canvas (`s0_geometry.metal`: content pixel `gid` ← frame pixel `gid + 0.5 − origin +
    /// frameOrigin`), so a spot defined at 0.5, 0.5 covers the frame's centre at every scale and in
    /// a 1:1 loupe window too — a window render puts the same disk on the same photograph, which is
    /// the property `HealTests.testAWindowPutsTheSpotOnTheSameTexels` measures.
    private func healSpotU(_ edit: EditModel, plan: Plan) -> [HealSpotU] {
        let shortEdge = max(min(plan.frameSize.x, plan.frameSize.y), 1)
        let base = SIMD2<Float>(plan.origin.x - plan.frameOrigin.x,
                                plan.origin.y - plan.frameOrigin.y)
        return edit.activeHealSpots.map { spot in
            let c = base + SIMD2<Float>(Float(spot.center.x) * plan.frameSize.x,
                                        Float(spot.center.y) * plan.frameSize.y)
            let r = Float(spot.clampedRadius) * shortEdge
            return HealSpotU(a: SIMD4(c.x, c.y, max(r, 0.5), Float(spot.feather)),
                             b: SIMD4(Float(spot.sourceOffset.x) * shortEdge,
                                      Float(spot.sourceOffset.y) * shortEdge,
                                      Float(spot.opacity),
                                      spot.mode == .clone ? 1 : 0))
        }
    }

    /// S1.9, two passes in one command buffer:
    ///
    ///   1. `s1_9_heal_stats` — one thread per spot walks the rim ring (`HealSpotU.a.xy` + `radius`)
    ///      and fits the correction plane `a₀ + a₁u + b₁v` to `dst − src` there. 256 texel reads per
    ///      spot, once per frame — the ring's mean and gradient is the whole of the Poisson step this
    ///      build ships (`Kernels/s1_9_heal.metal` has the derivation and the truncation error).
    ///   2. `s1_9_heal_apply` — every canvas pixel, every spot in document order, always reading the
    ///      **input** texture as the source (so a spot's source is the picture S1.6 produced, never
    ///      its own or a neighbour's output — that is what makes three spots independent).
    ///
    /// The two encoders are in one command buffer, so the stats are written before the apply reads
    /// them (Metal orders encoders in a buffer); both bind the *same* pipeline texture, the first as
    /// `access::read` for the identity copy and the second as `access::read` + `access::sample` for
    /// the sub-texel source position.
    private func encodeHeal(cb: MTLCommandBuffer, into out: MTLTexture,
                            from src: MTLTexture, edit: EditModel, plan: Plan,
                            options: RenderOptions) throws {
        let spots = healSpotU(edit, plan: plan)
        var params = HealParamsU(a: SIMD4(plan.origin.x, plan.origin.y,
                                         Float(plan.content.width), Float(plan.content.height)),
                                 b: SIMD4(Float(spots.count),
                                          options.healWithoutBoundaryMatch ? 0 : 1, 0, 0))
        let apply = try kernels.pipeline(file: "s1_9_heal", function: "s1_9_heal_apply")
        guard !spots.isEmpty else {
            // Not reachable through `pipeline(hasHeal:)` — a stage with no spot does not exist — but a
            // caller that asked anyway gets a **copy** rather than an uninitialised texture.
            let enc = try encoder(cb, apply, in: src, out: out)
            enc.setTexture(src, index: 2)
            enc.setBytes(&params, length: MemoryLayout<HealParamsU>.stride, index: 1)
            dispatch(enc, apply, plan.canvas)
            enc.endEncoding()
            return
        }

        let stride = MemoryLayout<HealStatU>.stride
        guard let statBuffer = device.makeBuffer(length: stride * spots.count,
                                                options: .storageModeShared) else {
            throw RenderError.commandBufferFailed
        }
        // 1 — the boundary ring.
        let stats = try kernels.pipeline(file: "s1_9_heal", function: "s1_9_heal_stats")
        var spotArray = spots
        guard let e0 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e0.setComputePipelineState(stats)
        e0.setTexture(src, index: 0)
        e0.setTexture(src, index: 1)
        e0.setBytes(&spotArray, length: MemoryLayout<HealSpotU>.stride * spots.count, index: 0)
        e0.setBytes(&params, length: MemoryLayout<HealParamsU>.stride, index: 1)
        e0.setBuffer(statBuffer, offset: 0, index: 2)
        let tw = min(stats.threadExecutionWidth, spots.count)
        e0.dispatchThreadgroups(MTLSize(width: (spots.count + tw - 1) / tw, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
        e0.endEncoding()

        // 2 — the pixels.
        guard let e1 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e1.setComputePipelineState(apply)
        e1.setTexture(src, index: 0)
        e1.setTexture(out, index: 1)
        e1.setTexture(src, index: 2)
        e1.setBytes(&spotArray, length: MemoryLayout<HealSpotU>.stride * spots.count, index: 0)
        e1.setBytes(&params, length: MemoryLayout<HealParamsU>.stride, index: 1)
        e1.setBuffer(statBuffer, offset: 0, index: 2)
        dispatch(e1, apply, plan.canvas)
        e1.endEncoding()
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
            // 2026-10-28 (P0-10): four entry points now — the 90° turn is a second template
            // parameter, so `s0_geometry_turn` (turn, no straighten) carries no `× f / ÷ f` either.
            // A rotate press therefore never resamples: at 1:1 it is the pure-turn branch below, and
            // everywhere else the un-turn is exact coordinate arithmetic.
            let turns = edit.geometry.quarterTurns
            // 097: the four `_lens` entries are the same bodies with `HAS_LENS_WARP == true`; the
            // default entries never contain that block, so a file without three distinct planes
            // keeps the pre-097 machine code (and bytes).
            let function: String
            switch (turns != 0, s0Rotates(edit), plan.s0LensWarp) {
            case (false, false, false): function = "s0_geometry"
            case (false, true, false): function = "s0_geometry_rot"
            case (true, false, false): function = "s0_geometry_turn"
            case (true, true, false): function = "s0_geometry_turn_rot"
            case (false, false, true): function = "s0_geometry_lens"
            case (false, true, true): function = "s0_geometry_lens_rot"
            case (true, false, true): function = "s0_geometry_lens_turn"
            case (true, true, true): function = "s0_geometry_lens_turn_rot"
            }
            let p = try kernels.pipeline(file: "s0_geometry", function: function)
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
                         plan.s0PureCA ? 1 : 0, plan.s0PureTurn ? 1 : 0),
                f: SIMD4(plan.frameSize.x, plan.frameSize.y, plan.frameOrigin.x, plan.frameOrigin.y),
                // g: the two dimensionless radial ratios, then the document's quarter turn. 0/0/0
                // for every document that has not touched the sliders or the rotate buttons, which
                // is what keeps the CA-off and the un-turned path byte-identical.
                g: SIMD4(Float(edit.optics.caRed), Float(edit.optics.caBlue),
                         Float(edit.geometry.quarterTurns), 0),
                lens: Self.lensMatrix(plan.s0LensWarp ? input.lensProfile : nil))
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
            //   · 071's trim is orthogonal: `_trim` for each of the two.
            //
            // schema 11: there is no dropper level any more, so `kLevels` (030's affine remap) is not
            // one of the choices — `blackOffset` and the two end-point sliders are the whole travel.
            let knee = edit.light.blacks != 0 || edit.light.whites != 0
            let hybrid = knee && abs(edit.light.blacks) > LightGroup.blacksEVToLevelSplit
            let trim = edit.light.blackOffset != 0
            let function: String
            switch (knee, hybrid, trim) {
            case (false, _, false): function = "s1_scene_linear"
            case (false, _, true): function = "s1_scene_linear_trim"
            case (true, true, false): function = "s1_scene_linear_hybrid"
            case (true, true, true): function = "s1_scene_linear_hybrid_trim"
            case (true, false, false): function = "s1_scene_linear_knee"
            case (true, false, true): function = "s1_scene_linear_knee_trim"
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
                // 071: a trim on its own is *not* the identity — it moves pixels — so it takes the
                // copy branch away exactly like a level does.
                && edit.light.blackOffset == 0
            var params = S1Params(
                a: SIMD4(edit.light.exposureGain, 1, 1, 1),
                b: SIMD4(Float(min(max(edit.light.highlightRecovery, 0), 1)), identity ? 1 : 0,
                         Float(edit.light.blacks), Float(edit.light.whites)),
                // The content rect travels with the levels, because a lifted black point maps the
                // matte's 0 to a positive value in *this* pass (派单 019 §3 item ①). Dispatch stays
                // the whole canvas — one guard per pixel is cheaper than a second encoder.
                c: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)),
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

        case .heal:
            // S1.9 — 修复 / 克隆 (2026-10-28, 078 P0-1). Encoded **only** for documents that carry a
            // spot (`RenderStage.pipeline(hasHeal:)`), so a document that never used the 修复画笔
            // renders the pre-S1.9 frame by construction: there is no pass to be neutral in.
            try encodeHeal(cb: cb, into: out, from: src, edit: edit, plan: plan, options: options)

        case .toneMap:
            // 098: contrast moved to S1.8, so this stage is one entry point again: the three region
            // lifts and the final clamp. It reads whatever the curve (or S1.8) produced.
            let p = try kernels.pipeline(file: "s2_tone_map", function: "s2_tone_map")
            let identity = edit.light.highlights == 0
                && edit.light.midtones == 0 && edit.light.shadows == 0
            // 085: the slider → EV map and its monotonicity gate live on the CPU (`S2Regions`); the
            // kernel only weights and exponentiates.
            let d = S2Regions.travelEV(shadows: edit.light.shadows,
                                       midtones: edit.light.midtones,
                                       highlights: edit.light.highlights)
            var params = S2Params(
                b: SIMD4(Float(d.shadow), Float(d.mid), Float(d.high), identity ? 1 : 0),
                // The content rect, so the matte outside it is never tone-mapped (派单 008 B). The
                // dispatch stays the whole canvas: one guard per pixel is cheaper than a second
                // encoder, and the guard is what makes "shadows" leave the letterbox alone.
                c: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<S2Params>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .contrast:
            // S1.8 — 098: the multiscale, edge-aware decomposition of Y in the scene-linear domain.
            // Encoded **only** for documents whose contrast is non-zero (`hasContrastStage`), so a
            // neutral document has no pass to be neutral in.
            try encodeContrast(cb: cb, into: out, from: src, edit: edit, plan: plan)

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

        case .bw:
            // S3.4 — 黑白 (2026-10-28, P0-4). Encoded **only** for documents whose 黑白 switch is on
            // (`RenderStage.pipeline(hasBW:)`), so a colour document's frame is the pre-S3.4 frame by
            // construction rather than by arithmetic: there is no pass to be neutral in. The mix table
            // is the HSL stage's own eight bands, with `band.mix` in `.v.x`.
            let p = try kernels.pipeline(file: "s3_4_bw", function: "s3_4_bw")
            let bands = try bwBandBuffer(for: edit.color)
            var params = BWParamsU(
                a: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)),
                b: SIMD4(options.bwIndependentChannels ? 1 : 0, Float(HSLBands.mixStopsPerFull),
                         0, 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<BWParamsU>.stride, index: 0)
            enc.setBuffer(bands, offset: 0, index: 1)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()

        case .hsl:
            // 076 — the eight bands, in OKLCh, on display-referred data. One buffer: eight
            // `HSLBandU`s (values + the reach towards each neighbour). The centres come from
            // `HSLBands.centresDegrees`, i.e. the same eight physical colours the wheel names,
            // measured in the space this pass computes in.
            //
            // 101 — the ninth selector (「全局」) rides the same pass but a **different instantiation**:
            // only a document with a non-zero global triplet compiles/executes the global arithmetic,
            // so every pre-101 document keeps 076's kernel byte for byte.
            let function = edit.color.hasGlobal ? "s3_6_hsl_global" : "s3_6_hsl"
            let p = try kernels.pipeline(file: "s3_6_hsl", function: function)
            let bands = try hslBandBuffer(for: edit.color)
            var params = HSLParamsU(
                a: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)),
                g: SIMD4(Float(edit.color.global.hue), Float(edit.color.global.saturation),
                         Float(edit.color.global.luminance), 0))
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

        case .grade:
            // S3.8 — 色彩分级 (2026-10-28, P0). Encoded **only** for documents whose grade group is not
            // neutral (`RenderStage.pipeline(hasGrade:)`), so a document that never touched the card
            // renders the pre-S3.8 frame by construction rather than by arithmetic: there is no pass to
            // be neutral in. The nine numbers go up in slider units — the kernel blends them by the
            // luminance weight and converts once, exactly as `ColorGrade.effective` does on the host.
            let p = try kernels.pipeline(file: "s3_8_grade", function: "s3_8_grade")
            let wheels = edit.colorGrading.wheels
            var params = GradeParams(
                a: SIMD4(plan.origin.x, plan.origin.y,
                         Float(plan.content.width), Float(plan.content.height)),
                b: SIMD4(options.gradeGlobalWeights ? 1 : 0, 0, 0, 0),
                sh: SIMD4(Float(wheels[0].hue), Float(wheels[0].saturation),
                          Float(wheels[0].lightness), 0),
                mid: SIMD4(Float(wheels[1].hue), Float(wheels[1].saturation),
                           Float(wheels[1].lightness), 0),
                hi: SIMD4(Float(wheels[2].hue), Float(wheels[2].saturation),
                          Float(wheels[2].lightness), 0))
            let enc = try encoder(cb, p, in: src, out: out)
            enc.setBytes(&params, length: MemoryLayout<GradeParams>.stride, index: 0)
            dispatch(enc, p, plan.canvas)
            enc.endEncoding()
        case .detailFX:
            // S3.9 — 纹理 / 清晰度 (2026-10-28, P0-6). Encoded **only** for documents whose two numbers
            // are not both 0 (`RenderStage.pipeline(hasDetailFX:)`), so a neutral document's frame is
            // the pre-S3.9 frame by construction: there is no pass to be neutral in.
            //
            // The two detail operators are chained in the order the panel names them (texture →
            // clarity), each writing the next texture: texture before clarity because the fine band is
            // a subset of the mid one. 去雾 is S1.9 now (117).
            try encodeDetailFX(cb: cb, into: out, from: src, edit: edit, plan: plan)

        case .dehaze:
            // S1.9 — 117: 去雾 in the scene-linear domain. Encoded **only** when `effects.dehaze != 0`
            // (`RenderStage.pipeline(hasDehaze:)`), so a neutral document has no pass to be neutral in.
            try encodeDehaze(cb: cb, into: out, from: src, edit: edit, plan: plan, options: options)

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
            // 100: HDR export asks for the linear exit (`s4_display_linear`) — same matrix, no OETF
            // and no headroom clamp. The default branch names `s4_display` exactly as before, so the
            // shipped path is untouched down to the pipeline function's name.
            let linear = options.display.linearOutput
            let p = try kernels.pipeline(file: "s4_display",
                                         function: linear ? "s4_display_linear" : "s4_display")
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

    // MARK: - S1.8 contrast (098)

    /// The stage: coarse guided filter → mid guided filter on the coarse residual → one full-resolution
    /// apply that rebuilds `B_c`, `B_m`, `D_f` and applies the three gains.
    ///
    /// The second filter's **input statistics** are built at `1/q` from the coarse coefficient map,
    /// so the frame is only read at full resolution twice (pack + apply), not once per band.
    private func encodeContrast(cb: MTLCommandBuffer, into out: MTLTexture,
                                from src: MTLTexture, edit: EditModel, plan: Plan) throws {
        let w = plan.canvas.width, h = plan.canvas.height
        let q = MultiscaleContrast.block
        let qW = max(1, (w + q - 1) / q), qH = max(1, (h + q - 1) / q)
        let frameShort = Double(min(plan.frameSize.x, plan.frameSize.y))
        let radiusC = Int32(MultiscaleContrast.radiusQ(
            fraction: MultiscaleContrast.coarseRadiusFraction,
            cap: MultiscaleContrast.coarseRadiusCap, shortEdge: frameShort))
        let radiusM = Int32(MultiscaleContrast.radiusQ(
            fraction: MultiscaleContrast.midRadiusFraction,
            cap: MultiscaleContrast.midRadiusCap, shortEdge: frameShort))
        let gains = MultiscaleContrast.scaleGains(t: edit.light.contrast / 100)
        let lw = ColorPrimaries.working.luminanceWeights

        var params = ContrastParamsU(
            a: SIMD4(Float(edit.light.contrast / 100), Float(MultiscaleContrast.pivotEV),
                     Float(MultiscaleContrast.coarseEpsilon),
                     Float(MultiscaleContrast.midEpsilon)),
            b: SIMD4(Float(gains.coarse), Float(gains.mid), Float(gains.fine),
                     Float(MultiscaleContrast.gateLo)),
            c: SIMD4(Float(MultiscaleContrast.gateHi), 0, 0, 0),
            luma: SIMD4(Float(lw.x), Float(lw.y), Float(lw.z), 0),
            rect: SIMD4(plan.origin.x, plan.origin.y,
                        Float(plan.content.width), Float(plan.content.height)),
            d: SIMD4(Int32(w), Int32(h), Int32(q), radiusC),
            e: SIMD4(Int32(qW), Int32(qH), 32, radiusM),
            f: SIMD4(0, 0, 0, 0))

        let base = try scratch("contrast-g-base", width: qW, height: qH, format: .rgba32Float)
        let tmp = try scratch("contrast-g-tmp", width: qW, height: qH, format: .rgba32Float)
        let boxedC = try scratch("contrast-g-coarse", width: qW, height: qH, format: .rgba32Float)
        let coeffC = try scratch("contrast-g-coeff-c", width: qW, height: qH, format: .rgba16Float)
        let statsM = try scratch("contrast-g-mid", width: qW, height: qH, format: .rgba32Float)
        let boxedM = try scratch("contrast-g-mid-boxed", width: qW, height: qH, format: .rgba32Float)
        let coeffM = try scratch("contrast-g-coeff-m", width: qW, height: qH, format: .rgba16Float)

        // 1. Pack G's block statistics at full resolution.
        let pack = try kernels.pipeline(file: "s1_8_contrast", function: "s1_8_g_contrast_pack")
        guard let e0 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e0.setComputePipelineState(pack)
        e0.setTexture(src, index: 0)
        e0.setTexture(base, index: 1)
        // Mode 0 never reads these two; bind the textures the later passes will write rather than
        // aliasing `base` as both a read and a write binding.
        e0.setTexture(coeffC, index: 2)
        e0.setTexture(statsM, index: 3)
        e0.setBytes(&params, length: MemoryLayout<ContrastParamsU>.stride, index: 0)
        dispatch(e0, pack, ImageSize(width: qW, height: qH))
        e0.endEncoding()

        // 2. Coarse guided filter: box the statistics, then solve (a, b, gate).
        params.e.w = radiusC
        try contrastBox(cb: cb, from: base, tmp: tmp, to: boxedC, params: &params, qW: qW, qH: qH)
        params.f.x = 0
        let coeffPipe = try kernels.pipeline(file: "s1_8_contrast",
                                             function: "s1_8_g_contrast_coeff")
        guard let e1 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e1.setComputePipelineState(coeffPipe)
        e1.setTexture(boxedC, index: 0)
        e1.setTexture(coeffC, index: 1)
        e1.setBytes(&params, length: MemoryLayout<ContrastParamsU>.stride, index: 0)
        dispatch(e1, coeffPipe, ImageSize(width: qW, height: qH))
        e1.endEncoding()

        // 3. The mid band's input: `D1 = G − (a_c·G + b_c)` per pixel, packed as block statistics.
        // The residual has to be sampled per pixel: its block mean from the *block* mean of G is
        // always zero, because the self-guided base passes through that mean.
        params.f.x = 1
        guard let e2 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e2.setComputePipelineState(pack)
        e2.setTexture(src, index: 0)
        e2.setTexture(statsM, index: 1)
        e2.setTexture(coeffC, index: 2)
        e2.setTexture(statsM, index: 3)
        e2.setBytes(&params, length: MemoryLayout<ContrastParamsU>.stride, index: 0)
        dispatch(e2, pack, ImageSize(width: qW, height: qH))
        e2.endEncoding()

        // 4. Mid guided filter on `D1`.
        params.e.w = radiusM
        try contrastBox(cb: cb, from: statsM, tmp: tmp, to: boxedM, params: &params, qW: qW, qH: qH)
        params.f.x = 1
        guard let e3 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e3.setComputePipelineState(coeffPipe)
        e3.setTexture(boxedM, index: 0)
        e3.setTexture(coeffM, index: 1)
        e3.setBytes(&params, length: MemoryLayout<ContrastParamsU>.stride, index: 0)
        dispatch(e3, coeffPipe, ImageSize(width: qW, height: qH))
        e3.endEncoding()

        // 5. Full-resolution apply: one gain for all three channels.
        let apply = try kernels.pipeline(file: "s1_8_contrast", function: "s1_8_g_contrast_apply")
        guard let e4 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e4.setComputePipelineState(apply)
        e4.setTexture(src, index: 0)
        e4.setTexture(coeffC, index: 1)
        e4.setTexture(coeffM, index: 2)
        e4.setTexture(out, index: 3)
        e4.setBytes(&params, length: MemoryLayout<ContrastParamsU>.stride, index: 0)
        dispatch(e4, apply, plan.canvas)
        e4.endEncoding()
    }

    /// The separable box mean of one statistics map: `from → tmp → to`.
    private func contrastBox(cb: MTLCommandBuffer, from: MTLTexture, tmp: MTLTexture,
                             to: MTLTexture, params: inout ContrastParamsU,
                             qW: Int, qH: Int) throws {
        let h = try kernels.pipeline(file: "s1_8_contrast", function: "s1_8_g_contrast_box_h")
        guard let e0 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e0.setComputePipelineState(h)
        e0.setTexture(from, index: 0)
        e0.setTexture(tmp, index: 1)
        e0.setBytes(&params, length: MemoryLayout<ContrastParamsU>.stride, index: 0)
        dispatchSegments(e0, qW: qW, qH: qH)
        e0.endEncoding()

        let v = try kernels.pipeline(file: "s1_8_contrast", function: "s1_8_g_contrast_box_v")
        guard let e1 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e1.setComputePipelineState(v)
        e1.setTexture(tmp, index: 0)
        e1.setTexture(to, index: 1)
        e1.setBytes(&params, length: MemoryLayout<ContrastParamsU>.stride, index: 0)
        dispatchSegments(e1, qW: qW, qH: qH)
        e1.endEncoding()
    }

    // MARK: - S3.9 纹理 / 清晰度 (2026-10-28, P0-6; 117 split 去雾 out)
    //
    // The statistics block. `4` is not a knob: at 4×4 averaging a 2…8 px pattern is gone from the
    // regression while a step edge is not, which is the whole reason the guided filter's gate follows
    // *structure* and not merely variance. It also makes the two chains a sixteenth of the frame
    // instead of two full ones.
    private static let detailFXBlock = 4

    /// The stage: up to two chains, in the panel's order (纹理 → 清晰度).
    ///
    /// Each chain reads the previous chain's texture, so only the first sees `src` and only the last
    /// writes `out`. A document with one number set pays one chain, not two. 去雾 is S1.9 now.
    private func encodeDetailFX(cb: MTLCommandBuffer, into out: MTLTexture,
                                from src: MTLTexture, edit: EditModel, plan: Plan) throws {
        let w = plan.canvas.width, h = plan.canvas.height
        let q = RenderGraph.detailFXBlock
        let qW = max(1, (w + q - 1) / q), qH = max(1, (h + q - 1) / q)

        // Radii are **frame fractions**, not canvas pixels: a 1:1 window, a fit preview and an export
        // must show the same band in the same physical place (S3c's and S3.7's rule). Expressed in the
        // 1/q domain, where the filter actually runs, with a floor of one texel so the chain always has
        // a window and a cap so a 60 Mpx export cannot ask for a radius the band has no use for.
        let frameShort = Double(min(plan.frameSize.x, plan.frameSize.y))
        func radiusQ(_ fraction: Double, cap capQ: Int32) -> Int32 {
            let texels = (fraction * frameShort / Double(q)).rounded()
            return min(max(Int32(texels), 1), capQ)
        }
        let textureRadius = radiusQ(0.0015, cap: 4)      // ≈ 4 px at a 2731 px frame
        let clarityRadius = radiusQ(0.02, cap: 24)       // ≈ 55 px at a 2731 px frame

        let textureAmount = Float(edit.effects.texture) / 100
        let clarityAmount = Float(edit.effects.clarity) / 100

        var params = DetailFXParamsU(
            a: SIMD4(textureAmount, clarityAmount, 0, 0),
            luma: SIMD4(0.2126, 0.7152, 0.0722, 0),
            d: SIMD4(0.0, 0, 0, 0),
            // The gate's knee, in **luma per 1/q texel**: a 0.44 step is 0.11 per 4 px texel, a 0.1
            // step is 0.025, a sky gradient over 100 px is 0.001. 0.015…0.06 therefore passes every
            // gradual transition and stops every step — which is where an unsharp mask draws its halo.
            e: SIMD4(0.015, 0.06, 0, 0),
            b: SIMD4(Int32(w), Int32(h), Int32(q), 0),
            c: SIMD4(Int32(qW), Int32(qH), 32, 0))

        let bandsActive = textureAmount != 0 || clarityAmount != 0
        var current = src

        // 2 + 3. 纹理 / 清晰度 — the same guided-filter chain, two bands, **one** full-resolution
        // apply. One statistics pack (the 4×4 block means), one separable box per band (the two
        // radii differ), one coefficient map per band, then a single apply that adds both residuals.
        // Splitting the apply in two would read the frame a second time for nothing — measured at
        // 4.10 Mpx, that second read was ~1.2 ms of the frame.
        if bandsActive {
            params.a.x = textureAmount
            // Full deflection is 0.8 × the residual, not 1.0: at 1.0 the additive boost shifts the
            // frame's mean by ~1.1 % (measured on the fixture's dark/bright step), which is a
            // brightness change on a control that promises none. 0.8 keeps the +100 high-pass gain at
            // ~+67 % (the acceptance asks for +30 %) and the mean inside 1 %.
            params.a.y = clarityAmount * 0.8
            try detailFXBands(cb: cb, from: current, into: out, params: &params, qW: qW, qH: qH,
                              textureRadius: textureRadius, clarityRadius: clarityRadius)
            current = out
        }

        // No amount was non-zero: the pipeline would not have encoded this stage at all, but a caller
        // that asked for it anyway gets a copy rather than an uninitialised texture.
        if current === src {
            guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
            blit.copy(from: src, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: out, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
    }

    /// The two guided bands: one pack, one box pair + one coefficient map per **active** band, one
    /// apply.
    ///
    /// Statistics are `rgba32Float` (a half-float `mean II` cannot resolve the 1e-4 variance a texture
    /// has — the gate would be quantisation noise); the coefficient maps are `rgba16Float` because they
    /// are the textures the apply pass **samples linearly**, and Metal does not filter 32-bit formats.
    ///
    /// ε is per band (`p.d.x`), and so is the radius (`p.b.w`); the gradient gate (`p.e`) is shared,
    /// because "a step edge" is the same test at both scales.
    private func detailFXBands(cb: MTLCommandBuffer, from source: MTLTexture, into destination: MTLTexture,
                               params: inout DetailFXParamsU, qW: Int, qH: Int,
                               textureRadius: Int32, clarityRadius: Int32) throws {
        let base = try scratch("detailfx-stats", width: qW, height: qH, format: .rgba32Float)
        let tmp = try scratch("detailfx-stats-tmp", width: qW, height: qH, format: .rgba32Float)

        let pack = try kernels.pipeline(file: "s3_8_detail_fx", function: "s3_8_guide_pack")
        let e0 = try encoder(cb, pack, in: source, out: base)
        e0.setBytes(&params, length: MemoryLayout<DetailFXParamsU>.stride, index: 0)
        dispatch(e0, pack, ImageSize(width: qW, height: qH))
        e0.endEncoding()

        // band 0 = 纹理 (small radius, ε = 4e-3), band 1 = 清晰度 (mid radius, ε = 1e-2).
        var coeffTex: MTLTexture?
        var coeffCla: MTLTexture?
        for band in [0, 1] {
            let active = band == 0 ? params.a.x != 0 : params.a.y != 0
            if !active { continue }
            let stats = try scratch("detailfx-stats-\(band)", width: qW, height: qH,
                                    format: .rgba32Float)
            params.b.w = band == 0 ? textureRadius : clarityRadius
            params.d.x = band == 0 ? 0.004 : 0.01
            try detailFXBox(cb: cb, from: base, tmp: tmp, to: stats, params: &params, qW: qW, qH: qH,
                            horizontal: "s3_8_guide_box_h", vertical: "s3_8_guide_box_v")

            let coeff = try scratch("detailfx-coeff-\(band)", width: qW, height: qH,
                                    format: .rgba16Float)
            let cp = try kernels.pipeline(file: "s3_8_detail_fx", function: "s3_8_guide_coeff")
            let e1 = try encoder(cb, cp, in: stats, out: coeff)
            e1.setBytes(&params, length: MemoryLayout<DetailFXParamsU>.stride, index: 0)
            dispatch(e1, cp, ImageSize(width: qW, height: qH))
            e1.endEncoding()
            if band == 0 { coeffTex = coeff } else { coeffCla = coeff }
        }

        let apply = try kernels.pipeline(file: "s3_8_detail_fx", function: "s3_8_guide_apply")
        let fallback = coeffTex ?? coeffCla
        guard let enc = cb.makeComputeCommandEncoder(), let first = fallback else {
            throw RenderError.commandBufferFailed
        }
        enc.setComputePipelineState(apply)
        enc.setTexture(source, index: 0)
        enc.setTexture(coeffTex ?? first, index: 1)
        enc.setTexture(coeffCla ?? first, index: 2)
        enc.setTexture(destination, index: 3)
        enc.setBytes(&params, length: MemoryLayout<DetailFXParamsU>.stride, index: 0)
        dispatch(enc, apply, ImageSize(width: Int(params.b.x), height: Int(params.b.y)))
        enc.endEncoding()
    }

    /// The separable box mean of the statistics: `from → tmp → to`.
    private func detailFXBox(cb: MTLCommandBuffer, from: MTLTexture, tmp: MTLTexture, to: MTLTexture,
                             params: inout DetailFXParamsU, qW: Int, qH: Int,
                             horizontal: String, vertical: String) throws {
        let h = try kernels.pipeline(file: "s3_8_detail_fx", function: horizontal)
        guard let e0 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e0.setComputePipelineState(h)
        e0.setTexture(from, index: 0)
        e0.setTexture(tmp, index: 1)
        e0.setBytes(&params, length: MemoryLayout<DetailFXParamsU>.stride, index: 0)
        dispatchSegments(e0, qW: qW, qH: qH)
        e0.endEncoding()

        let v = try kernels.pipeline(file: "s3_8_detail_fx", function: vertical)
        guard let e1 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e1.setComputePipelineState(v)
        e1.setTexture(tmp, index: 0)
        e1.setTexture(to, index: 1)
        e1.setBytes(&params, length: MemoryLayout<DetailFXParamsU>.stride, index: 0)
        dispatchSegments(e1, qW: qW, qH: qH)
        e1.endEncoding()
    }

    /// One thread per 32-texel segment, 32 threads per group — the `s1_7_mask_neighbourhood` dispatch,
    /// which is what lets a running sum/min walk a segment instead of a pixel.
    private func dispatchSegments(_ enc: MTLComputeCommandEncoder, qW: Int, qH: Int) {
        enc.dispatchThreadgroups(MTLSize(width: max(1, (qW + 31) / 32), height: max(1, qH), depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
    }

    // MARK: - S1.9 去雾 (117)
    //
    // Three passes over a `1/q` dark channel, q = 4:
    //
    //   · `s1_9_dehaze_dark`     — block minimum, one texel per q × q block (rgba16Float, r used);
    //   · `s1_9_dehaze_airlight` — one threadgroup scans the block texture for the largest block
    //                              minimum and writes a 1 × 1 texture (He's brightest-dark-channel
    //                              estimate, cheaply and deterministically);
    //   · `s1_9_dehaze_apply`    — full resolution: samples the block texture bilinearly, builds
    //                              `t = max(1 − ω·D, t0)`, applies `J = (I − A(1 − t))/t`, and never
    //                              clamps the top (the HDR tail is the point of 117).
    //
    // The airlight never comes back to the CPU on the shipped path; `probesDehazeAirlight` adds a
    // 4-byte blit for the acceptance's measurement.
    private func encodeDehaze(cb: MTLCommandBuffer, into out: MTLTexture,
                              from src: MTLTexture, edit: EditModel, plan: Plan,
                              options: RenderOptions) throws {
        let w = plan.canvas.width, h = plan.canvas.height
        let q = 4
        let qW = max(1, (w + q - 1) / q), qH = max(1, (h + q - 1) / q)

        var params = DehazeParamsU(
            a: SIMD4(Float(edit.effects.dehaze) / 100, 0.95, 0.1, 0.02),
            b: SIMD4(plan.origin.x, plan.origin.y,
                     Float(plan.content.width), Float(plan.content.height)),
            c: SIMD4(Int32(w), Int32(h), Int32(q), Int32(qW)),
            d: SIMD4(Int32(qH), 0, 0, 0))

        let dark = try scratch("dehaze-dark", width: qW, height: qH, format: .rgba16Float)
        let airlight = try scratch("dehaze-airlight", width: 1, height: 1, format: .rgba16Float)

        let pack = try kernels.pipeline(file: "s1_9_dehaze", function: "s1_9_dehaze_dark")
        let e0 = try encoder(cb, pack, in: src, out: dark)
        e0.setBytes(&params, length: MemoryLayout<DehazeParamsU>.stride, index: 0)
        dispatch(e0, pack, ImageSize(width: qW, height: qH))
        e0.endEncoding()

        let aPipe = try kernels.pipeline(file: "s1_9_dehaze", function: "s1_9_dehaze_airlight")
        guard let e1 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e1.setComputePipelineState(aPipe)
        e1.setTexture(dark, index: 0)
        e1.setTexture(airlight, index: 1)
        e1.setBytes(&params, length: MemoryLayout<DehazeParamsU>.stride, index: 0)
        e1.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        e1.endEncoding()

        let apply = try kernels.pipeline(file: "s1_9_dehaze", function: "s1_9_dehaze_apply")
        guard let e2 = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e2.setComputePipelineState(apply)
        e2.setTexture(src, index: 0)
        e2.setTexture(dark, index: 1)
        e2.setTexture(airlight, index: 2)
        e2.setTexture(out, index: 3)
        e2.setBytes(&params, length: MemoryLayout<DehazeParamsU>.stride, index: 0)
        dispatch(e2, apply, plan.canvas)
        e2.endEncoding()

        if options.probesDehazeAirlight {
            // rgba16Float: four 16-bit channels. Read the red channel back as a half float, not the
            // whole texel as a Float (that was the bug the first version of this probe had).
            let texelBytes = MemoryLayout<UInt16>.stride * 4
            guard let probe = device.makeBuffer(length: texelBytes, options: .storageModeShared),
                  let blit = cb.makeBlitCommandEncoder() else {
                throw RenderError.commandBufferFailed
            }
            blit.copy(from: airlight, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: 1, height: 1, depth: 1),
                      to: probe, destinationOffset: 0,
                      destinationBytesPerRow: texelBytes,
                      destinationBytesPerImage: texelBytes)
            blit.endEncoding()
            dehazeAirlightProbe = probe
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
        Float(CropGeometry(geometry: edit.geometry, source: sourceSize).cosine)
    }

    private func sintheta(_ edit: EditModel) -> Float {
        Float(CropGeometry(geometry: edit.geometry, source: sourceSize).sine)
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
    private func maskTable(for edit: EditModel, plan: Plan,
                           semantics: SemanticResolution) throws -> MaskTable? {
        let active = edit.activeMasks
        guard !active.isEmpty else { return nil }
        let content = plan.frameInCanvas
        let mapping = canvasMapping(edit, plan)

        let selection = edit.maskSelectionMaterial
        let apply = edit.maskApplyMaterial
        // The content size is part of the key because the two radii (feather, guided) are pixel
        // lengths derived from it: the same document at thumbnail and at export must produce
        // different descriptors from the same selection key. 005e adds the semantic material for the
        // same reason: which slice a semantic component points at is not in the document.
        // 081 adds the canvas and its two origins: each mask's raster box is a *canvas* rectangle, so
        // a 1:1 window that pans keeps the selection fixed while moving the box that holds it.
        let cacheKey = selection + "##" + apply + "##" + content.keyString
            + "##" + semantics.keyMaterial
            + "##" + plan.canvas.keyString
            + "##" + "\(plan.origin.x),\(plan.origin.y),\(plan.frameOrigin.x),\(plan.frameOrigin.y)"
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
            // 081: the slice's raster box. `rasterRect` answers the whole canvas whenever the
            // coverage is *not* provably 0 outside the shape (inverted masks, content predicates).
            let raster = MaskBounds.rasterRect(for: m, mapping: mapping)
            let needsPicture = m.components.contains { c in
                switch c.shape {
                case .colorRange, .luminanceRange: return true
                default: return false
                }
            }
            masks.append(MaskDescU(meta: SIMD4(first, Int32(m.components.count), m.invert ? 1 : 0,
                                               needsPicture ? 1 : 0),
                                   misc: SIMD4(Float(min(max(m.opacity, 0), 1)), featherPx,
                                               Float(min(max(m.refine, 0), 1)), guidedPx),
                                   rect: SIMD4(Int32(raster.x0), Int32(raster.y0),
                                               Int32(raster.x1), Int32(raster.y1))))
            adjust.append(adjustDesc(m.adjustments, enabled: m.isEnabled))
            colorAdjust.append(colorAdjustDesc(m.adjustments, enabled: m.isEnabled))
        }
        // Metal requires a bound buffer even when the count is zero; one neutral entry keeps the
        // binding valid without inventing a mask.
        if masks.isEmpty { masks.append(MaskDescU(meta: .zero, misc: .zero, rect: .zero)) }
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
        // 085 — the local lifts take the same gated EV travels as the global ones (中间调 pinned at 0:
        // a local adjustment has no midtone slider yet). Same windows + same travel + same gate is what
        // makes "the masked slider is the global slider" a measurement rather than a hope.
        let d = S2Regions.travelEV(shadows: a.shadows, midtones: 0, highlights: a.highlights)
        return LocalAdjustU(
            a: SIMD4(gain.r, gain.g, gain.b, Float(min(max(a.amount, 0), 100) / 100)),
            b: SIMD4(Float(a.contrast), Float(d.high), Float(d.shadow), Float(a.whites)),
            // `.y` is the contrast travel: the EV of bend at `|contrast| = 100`, derived from the
            // axis' own end points exactly as 0107's `S2Contrast.travel` does (8 EV of tone map over
            // display white 0 EV and the black end −8 EV ⇒ 1.0 EV). Passed, not baked into the kernel,
            // for the same reason S2 takes it from the CPU: an axis that moves must move both stages.
            c: SIMD4(Float(a.blacks), Float(Self.localContrastTravelEV), 0, active ? 1 : 0))
    }

    /// 079 §2.1.2 — `S2Contrast.travel`'s derivation (`8/(whiteEV − blackEV)`, feat/contrast-0107
    /// commit `06c5a6b`), repeated here only because that type does not exist on this branch yet. The
    /// masked contrast and S2's contrast have to be the *same* bend; when 0107 merges this becomes a
    /// reference to `S2Contrast.travel` and nothing else changes.
    static let localContrastTravelEV: Double = 8.0 / (0.0 - (-8.0))

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
            // e.y: the document's quarter turn, so the atlas un-turns its position exactly where S0
            // does (P0-10 / 080: one turn, two stages).
            e: SIMD4(Int32(count), Int32(edit.geometry.quarterTurns), 0, 0),
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
            // 081 — the window the two halves have to visit: the union of the slices' boxes, grown by
            // the widest radius, snapped outward to the *existing* segment lattice (the kernels derive
            // their segment from `gid`, so a lattice that moved would be a different running sum).
            var boxX0 = canvas.width, boxY0 = canvas.height, boxX1 = 0, boxY1 = 0
            var rMax = 0
            for (i, m) in table.masks.prefix(count).enumerated() {
                let r = radii[i]
                guard r > 0 else { continue }
                boxX0 = min(boxX0, Int(m.rect.x)); boxY0 = min(boxY0, Int(m.rect.y))
                boxX1 = max(boxX1, Int(m.rect.z)); boxY1 = max(boxY1, Int(m.rect.w))
                rMax = max(rMax, r)
            }
            // Nothing to blur (every mask has radius 0): the passes are already skipped above.
            if boxX1 <= boxX0 { boxX1 = boxX0 + 1; boxY1 = boxY0 + 1 }
            let hGroupX0 = max(0, (boxX0 - rMax) / segment)
            let hGroupX1 = min((canvas.width + segment - 1) / segment,
                               (boxX1 + rMax + segment - 1) / segment)
            let vSegY0 = max(0, boxY0 / segment)
            let vSegY1 = min((canvas.height + segment - 1) / segment,
                             (boxY1 + segment - 1) / segment)
            // Rows the horizontal half must produce: every row the vertical half will *walk*, which
            // starts one segment below the box (the vertical pass keeps its whole-segment loop and
            // only confines its stores).
            var hRow0 = max(0, vSegY0 * segment - rMax)
            let hRow1 = min(canvas.height, min(canvas.height, vSegY1 * segment) + rMax)
            if hRow0 >= hRow1 { hRow0 = max(0, hRow1 - 1) }
            let hGroups = MTLSize(width: max(1, hGroupX1 - hGroupX0),
                                  height: max(1, (hRow1 - hRow0 + 31) / 32), depth: count)
            let vGroups = MTLSize(width: max(1, (boxX1 - boxX0 + 31) / 32),
                                  height: max(1, vSegY1 - vSegY0), depth: count)
            var bp = MaskBlurParams(a: SIMD4(Int32(canvas.width), Int32(canvas.height),
                                             Int32(segment), Int32(count)),
                                    b: SIMD4(0, 0, 0, 0))
            let passes: [(String, MTLTexture, MTLTexture, MTLSize, MTLSize, SIMD4<Int32>)] = [
                ("s1_7_mask_blur_h", atlas, tmp, hGroups,
                 MTLSize(width: 1, height: 32, depth: 1),
                 SIMD4(Int32(hGroupX0), Int32(hRow0), 0, 0)),
                ("s1_7_mask_blur_v", tmp, atlas, vGroups,
                 MTLSize(width: 32, height: 1, depth: 1),
                 SIMD4(Int32(boxX0), Int32(vSegY0), 0, 0)),
            ]
            for (fn, source, destination, groups, threads, origin) in passes {
                let pipe = try kernels.pipeline(file: "s1_7_mask_neighbourhood", function: fn)
                guard let e = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
                e.setComputePipelineState(pipe)
                e.setTexture(source, index: 0)
                e.setTexture(destination, index: 1)
                // The window's origin, in the pass's own lattice units (segment index for the axis
                // that walks segments, pixel index for the other). The window is always a *subset*
                // of the lattice — when the box is the whole canvas it degenerates to the old
                // dispatch, with a zero origin.
                bp.b = origin
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
        // 081 — how much of a full-canvas dispatch this atlas actually evaluated. Summed over the
        // boxes the *kernel* was given (`table.masks`, not `report.bounds`): the number has to
        // describe the dispatch, or it is not a receipt for the saving it claims.
        report.atlasRasterPixels = table.masks.prefix(count).reduce(0) { acc, m in
            let w = max(0, Int(m.rect.z) - Int(m.rect.x))
            let h = max(0, Int(m.rect.w) - Int(m.rect.y))
            return acc + w * h
        }
        report.atlasCanvasPixels = canvas.pixelCount * max(count, 1)
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
        // Through the graph, not the pool: a frame the graph handed out may be the `showMask` slot, and
        // returning it straight to the pool is what handed the next frame the slot's texture (see
        // `TexturePool.own`).
        if let t = result.output { recycle(output: t) }
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

    /// The eight bands as S3.4 reads them (2026-10-28, P0-4): **the same table**, with the 黑白混合
    /// value in `.v.x` where S3.6 puts the hue. The centres and reaches are `HSLBands`' constants, so
    /// the two stages cannot act on two different wheels; nothing is cached, for the reason
    /// `hslBandBuffer` gives (eight floats per frame is cheaper than a cache keyed by a dragging slider).
    private func bwBandBuffer(for color: ColorGroup) throws -> MTLBuffer {
        var words: [HSLBandU] = []
        words.reserveCapacity(ColorGroup.bandCount)
        for (i, band) in color.bands.prefix(ColorGroup.bandCount).enumerated() {
            let centre = HSLBands.centresDegrees[min(i, HSLBands.centresDegrees.count - 1)]
            let extent = HSLBands.extents[min(i, HSLBands.extents.count - 1)]
            words.append(HSLBandU(v: SIMD4(Float(band.mix), 0, 0, centre),
                                  e: SIMD4(extent.left, extent.right, 0, 0)))
        }
        guard let b = device.makeBuffer(bytes: words,
                                        length: MemoryLayout<HSLBandU>.stride * words.count,
                                        options: .storageModeShared) else {
            throw RenderError.allocationFailed("B&W mix bands")
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
        case .rec2020: return .rec2020
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

    /// 097 — the per-plane DNG warp as a column-major uniform: columns 0/1/2 are the R/G/B
    /// `(kr0, kr1, kr2, kr3)`, column 3 is the normalized centre `(x, y, 0, 0)`. `nil` (or a profile
    /// that does not need our own warp) returns the identity, which the default entries never read.
    /// An RW2 profile fills all three columns with the same fitted inverse (Panasonic has no
    /// per-channel distortion data), so the same `s0_geometry_lens` entry point consumes it.
    static func lensMatrix(_ profile: LensProfile?) -> simd_float4x4 {
        guard let profile, profile.requiresOwnWarp, profile.planes.count >= 3 else {
            return identityMatrix
        }
        func column(_ plane: LensWarpPlane) -> SIMD4<Float> {
            SIMD4(Float(plane.kr0), Float(plane.kr1), Float(plane.kr2), Float(plane.kr3))
        }
        return simd_float4x4(columns: (column(profile.planes[0]),
                                       column(profile.planes[1]),
                                       column(profile.planes[2]),
                                       SIMD4(Float(profile.centerX), Float(profile.centerY), 0, 0)))
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
    /// The identities in `free`, so a texture cannot be in the idle list twice.
    ///
    /// A frame that hands its own canvas back can reach a second `recycle` of a texture that is
    /// already idle — `showMask`'s reuse hit recycles the display frame it just produced, and that
    /// frame may be the very texture the slot already gave back. Two entries for one texture means the
    /// next two `obtain`s hand the same bytes to two live stages, so the second one's output is the
    /// first one's input. Membership is the cheapest way to make that impossible.
    private var idle: Set<ObjectIdentifier> = []
    /// Textures the **graph** owns, which the pool must never hand out (P1e's `showMask` slot).
    ///
    /// `render` hands the overlay's canvas out as a frame while keeping it as the next static frame's
    /// pixels. Anything that puts those bytes back into circulation turns the next frame's "nothing
    /// moved, reuse it" hit into a picture with no overlay on it: the stage that took the texture from
    /// the pool writes the plain display frame into it, and the slot still points there. `render`'s
    /// comment says "`recycle(output:)` refuses to pool it", and that guard is real — but it only
    /// covers callers that go through `recycle(output:)`; `maskAtlasWithReport` recycled the frame
    /// straight into the pool and the golden frame came back without its overlay.
    ///
    /// The ownership lives here, beside `free`, because this is where the question is decided: `recycle`
    /// is the one door a texture can enter the pool through, so a texture the graph owns cannot be
    /// handed out no matter which call site returns it.
    private var owned: [ObjectIdentifier: MTLTexture] = [:]

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
            idle.remove(ObjectIdentifier(t))
            assert(owned[ObjectIdentifier(t)] == nil, "the pool handed out a texture the graph owns")
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

    /// Take a texture out of circulation: the graph keeps it, no `obtain` may hand it out, and no
    /// `recycle` puts it back — until `disown` says the graph is done with it.
    ///
    /// Idempotent, and it takes the texture out of the idle list first, so it cannot matter whether
    /// the caller owns the texture before or after the frame that produced it was returned.
    func own(_ texture: MTLTexture) {
        let id = ObjectIdentifier(texture)
        if idle.contains(id) {
            let key = "\(texture.width)x\(texture.height)"
            if let list = free[key], let i = list.firstIndex(where: { $0 === texture }) {
                var rest = list
                rest.remove(at: i)
                if rest.isEmpty { free[key] = nil } else { free[key] = rest }
                idleBytes -= texture.width * texture.height * 8
                if let f = freeOrder.lastIndex(of: key) { freeOrder.remove(at: f) }
            }
            idle.remove(id)
        }
        owned[id] = texture
    }

    /// Give an owned texture back to the pool's jurisdiction. Pooling it is then an ordinary
    /// `recycle`, which the graph does right after — the two are separate so that a graph-invalidating
    /// path can release the texture without asserting anything about when it is reusable.
    func disown(_ texture: MTLTexture) {
        owned.removeValue(forKey: ObjectIdentifier(texture))
    }

    func recycle(_ texture: MTLTexture) {
        let key = "\(texture.width)x\(texture.height)"
        let id = ObjectIdentifier(texture)
        // A texture the graph owns is not the pool's to hand out (P1e), and one that is already idle
        // must not enter the list twice — both would end with two live stages sharing one texture.
        guard owned[id] == nil, !idle.contains(id) else { return }
        let bytes = texture.width * texture.height * 8
        idleBytes += bytes
        idle.insert(id)
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
            idle.remove(ObjectIdentifier(dropped))
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
        idle.removeAll()
        idleBytes = 0
        return bytes
    }
}
