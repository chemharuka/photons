import Foundation
import CryptoKit

// MARK: - stages

/// The stages of the editing graph, in execution order.
///
/// `RenderStage` is the unit of both the cache-key chain (D6) and group-level dirty tracking (D10).
/// Every stage boundary is a key: re-running S3 must not re-run S0/S1.
///
/// M4 adds two **conditional** stages between S1 and S2 (`s1.5-mask-atlas`, `s1.6-local`), and 056
/// adds a third one between S3 and the vignette (`s3.5-local-color`). They are cases of this enum —
/// so the trace, the dirty set and the key chain all speak the same language — but they are
/// deliberately *not* in `allCases`, because `allCases` means "the passes every document renders".
/// A document with no masks must produce exactly the M1 trace and the M1 keys: with `masks` empty
/// the two mask-keyed links are dropped whole rather than made neutral, so the key bytes stay the
/// M1 ones; a document whose masks carry no hue or saturation drops the S3.5 link the same way.
/// See `pipeline`.
public enum RenderStage: String, CaseIterable, Sendable, Codable {
    case geometry = "s0-geometry"
    case sceneLinear = "s1-scene-linear"
    case maskAtlas = "s1.5-mask-atlas"
    case localApply = "s1.6-local"
    /// 2026-10-28 (078 P0-1 / B9) — **修复 / 克隆**: the spot list of the 修复画笔.
    ///
    /// Placed between S1.6 (the mask adjustments) and S1.7 (the curve), for three reasons that are
    /// spelled out where the arithmetic is (`Kernels/s1_9_heal.metal`): it is a repair of the picture
    /// and not a look (so it goes before the curve/tone map/colour), it needs the pixels S1.6 wrote
    /// (so it goes after the local stage, and its 「源点」 is the texture the user is looking at), and
    /// it has to work on the canvas grid S0 produced (so a disk is a disk at every scale and in every
    /// loupe window). **Conditional** like the mask stages: it exists only when the document carries a
    /// spot, so a document without one keeps its pre-S1.9 trace, key chain and pixels byte for byte.
    case heal = "s1.9-heal"
    /// 派单 030: **the** tone curve, in the HDR (scene-linear, log1p-shaped) domain.
    ///
    /// It used to be `s3-curve`, after the tone map, on 0…1 data S2 had already compressed — so the
    /// user could only bend what S2 had shaped, and a +4 EV highlight had already been treated as a
    /// "highlights region" before the curve saw it. `s3_curve` (the file, the kernel and the stage)
    /// is **deleted**; this is the one curve. `grep -rn "s3_curve" Sources` must find nothing but
    /// this sentence.
    case curve = "s1.7-hdr-curve"
    /// 098 — **contrast**, as a multiscale edge-aware decomposition of `Y` in the **scene-linear**
    /// domain. Sits after the curve (it reads the curve's output) and before S2 (which now only does
    /// its three region lifts).
    ///
    /// **Conditional** like the mask/effect stages: it exists only when `light.contrast != 0`, so a
    /// neutral document keeps its pre-098 trace, key chain and pixels byte for byte.
    case contrast = "s1.8-contrast"
    case toneMap = "s2-tone-map"
    case color = "s3-color"
    /// 2026-10-28 (P0-4) — **黑白**: the monochrome conversion, and the per-hue mix that decides how
    /// bright each colour lands in the grey.
    ///
    /// After S3 (the colour image is converted where the colour image exists) and before S3.5/S3.6,
    /// and **conditional** like them: it exists only when the document's 黑白 switch is on, so a
    /// colour document keeps its pre-S3.4 trace, key chain and pixels byte for byte. A grey written
    /// here has `C = 0`, so S3.6 downstream is inert by its own chroma gate.
    case bw = "s3.4-bw"
    /// 派单 056 — a mask's **hue and saturation**, in the display-referred domain: after S2 and after
    /// S3, before the vignette.
    ///
    /// They used to ride in S1.6, i.e. in scene-linear light before the curve and the tone map, while
    /// the *global* hue/saturation live in S3 — so the same "+40" was two different operations
    /// depending on whether it came from a slider or from a mask, and a full-canvas mask refused to
    /// equal the global control. It is a **conditional** stage like S1.5/S1.6: it exists only when a
    /// mask actually carries a hue or a saturation value, so a document without local colour keeps
    /// its trace, its key chain and its pixels byte for byte.
    case localColor = "s3.5-local-color"
    /// 派单 076 — **HSL**: the eight colour bands, in OKLCh, in the display-referred domain.
    ///
    /// After S3.5 (same domain: post-tone-map, pre-vignette) and **conditional** like it: the stage
    /// exists only when a band actually carries a value, so a document with all 24 band values at 0
    /// keeps its pre-076 trace, key chain and pixels byte for byte. The band maths used to ride in S3
    /// on linear light, which is the defect 079 结论 4 measured (HSL `l` = 0.5 for both pure blue and
    /// pure yellow, whose luminance differs by 6.9×); S3 keeps vibrance and saturation only.
    case hsl = "s3.6-hsl"
    /// 2026-10-28 (P0 色彩分级) — **三向色彩分级**: 阴影 / 中间调 / 高光, each 色相 + 饱和 + 亮度.
    ///
    /// Its own stage, not three more uniforms inside S3.6, for three reasons:
    ///
    ///  1. **A different partition.** S3.6 partitions by *hue* (eight bands, a partition of unity over
    ///     the OKLCh hue circle); S3.8 partitions by *luminance* (three windows on `log2 luma`, the
    ///     same ones S2's 阴影/高光 lift). Two partitions, two weight functions — one stage cannot be
    ///     both without a branch that makes each half pay for the other's neutral test.
    ///  2. **Independent links.** A band drag must miss S3.8 and a grade drag must miss S3.6 — the
    ///     exact split 076 made when the bands left S3 (`changedStages`, `keyMaterial`). Two stages is
    ///     that split done structurally instead of by a conditional inside one kernel.
    ///  3. **Independent neutral.** `hasGrade` (nine zeros) and `hasHSL` (24 zeros) are different
    ///     predicates; a document with bands but no grade must not encode a grade pass, and vice versa.
    ///
    /// Position — after S3.6 and before S3c (the vignette): it is a **display-referred** colour
    /// operation like S3.6 (the windows are measured on the values the tone map produced, which is
    /// what makes 「高光」 mean the same region as the 高光 slider), and it belongs on the finished
    /// colour image, before the two effect stages darken/grain it. S3.4/S3.5/S3.6 stay before it, so a
    /// grey from 黑白 carries `C = 0` and the grade's chroma maths is inert on it by construction.
    case grade = "s3.8-grade"
    /// 2026-10-28 (P0-6) — **纹理 / 清晰度 / 去雾**: the three detail numbers of the 效果 card.
    ///
    /// Sits after the grade and **before** the vignette: dehaze removes the veil from the picture and
    /// texture/clarity shape its detail, all of which the vignette then darkens at the edges — putting
    /// it after S3c would let the vignette's own falloff be read as "detail" by the guided filter.
    /// **Conditional** like S3.4/S3.5/S3.6/S3.7: it exists only when at least one of the three numbers
    /// is non-zero, so a document with all three at 0 keeps its pre-S3.9 trace, key chain and pixels
    /// byte for byte. Numbered after S3.8 (the grade) — merge order: grade took the 8.
    case detailFX = "s3.9-detail-fx"
    /// S3c — post-crop vignette, and the card's other half.
    case vignette = "s3-vignette"
    /// 2026-10-28 — **grain**, the Effects card's second stage.
    ///
    /// After the vignette (grain sits on the finished picture, which is where Lightroom adds it and
    /// the last place before S4 encodes) and **conditional** like S3.5/S3.6: it exists only when the
    /// document's grain amount is above zero, so a document with no grain keeps its pre-S3.7 trace,
    /// key chain and pixels byte for byte. That condition is the strongest form of 「中性零变化」 —
    /// the pass is not encoded at all, rather than encoded and multiplied by zero.
    case grain = "s3.7-grain"
    case display = "s4-display"

    /// The passes every document runs. Mask stages are excluded on purpose: `masks == []`
    /// must be byte-for-byte the M1 graph, including the set of stages a cold render reports.
    ///
    /// The curve is third among the unconditional passes (030): S1 → **curve** → S2. S2 must see
    /// what the curve produced, not the other way round, and `s2_tone_map`'s region weights are
    /// defined on display-referred values — which is what the curve hands it.
    public static var allCases: [RenderStage] {
        [.geometry, .sceneLinear, .curve, .toneMap, .color, .vignette, .display]
    }

    /// Execution order including the conditional stages.
    ///
    /// S3.4 (`bw`), S3.5 (`localColor`), S3.6 (`hsl`) and S3.7 (`grain`) are in this list because they
    /// *are* stages — index, trace and the key chain speak one language — but
    /// `pipeline(hasMasks:hasLocalColor:hasHSL:hasGrain:hasBW:)` is what decides whether a render
    /// visits them. A colour document never visits S3.4, a document whose masks carry neither hue nor
    /// saturation never visits S3.5, one whose bands are all 0 never visits S3.6, and one whose grain
    /// amount is 0 never visits S3.7.
    public static var order: [RenderStage] {
        [.geometry, .sceneLinear, .maskAtlas, .localApply, .heal, .curve, .contrast, .toneMap,
         .color, .bw, .localColor, .hsl, .grade, .detailFX, .vignette, .grain, .display]
    }

    /// The stages one render actually visits.
    ///
    /// Five conditional families, five predicates: the mask stages appear when *any* mask is enabled,
    /// S3.5 only when a mask actually carries a hue or a saturation value (派单 056 §验收 7 — the
    /// judgement is by value, not by "there is a mask"), S3.6 only when a band carries a value
    /// (派单 076), S3.7 only when the grain amount is above zero, and S3.4 only when the 黑白 switch is
    /// on (2026-10-28). With none of them, the answer is exactly the pre-056 list, which is what keeps
    /// every existing trace and key byte for byte.
    public static func pipeline(hasMasks: Bool, hasLocalColor: Bool = false,
                                hasHSL: Bool = false, hasGrain: Bool = false,
                                hasBW: Bool = false, hasGrade: Bool = false,
                                hasDetailFX: Bool = false, hasHeal: Bool = false,
                                hasContrast: Bool = false) -> [RenderStage] {
        guard hasMasks || hasHSL || hasGrain || hasBW || hasGrade || hasDetailFX || hasHeal
                || hasContrast else {
            return allCases
        }
        return order.filter { stage in
            switch stage {
            case .maskAtlas, .localApply: return hasMasks
            case .heal: return hasHeal
            case .bw: return hasBW
            case .localColor: return hasMasks && hasLocalColor
            case .hsl: return hasHSL
            case .grade: return hasGrade
            case .detailFX: return hasDetailFX
            case .grain: return hasGrain
            case .contrast: return hasContrast
            default: return true
            }
        }
    }

    public var isMaskStage: Bool { self == .maskAtlas || self == .localApply }

    public var index: Int { RenderStage.order.firstIndex(of: self)! }
    public var label: String { rawValue }

    /// Short alias used in trace lines (`--trace-stages`).
    public var short: String {
        switch self {
        case .geometry: return "s0"
        case .sceneLinear: return "s1"
        case .maskAtlas: return "s1.5"
        case .localApply: return "s1.6"
        case .heal: return "s1.9"
        case .curve: return "s1.7"
        case .contrast: return "s1.8"
        case .toneMap: return "s2"
        case .color: return "s3-color"
        case .bw: return "s3.4"
        case .localColor: return "s3.5"
        case .hsl: return "s3.6"
        case .grade: return "s3.8"
        case .detailFX: return "s3.9"
        case .vignette: return "s3-vignette"
        case .grain: return "s3.7"
        case .display: return "s4"
        }
    }

    /// Stages whose parameters live in the same UI group; used to explain a dirty set.
    public var group: String {
        switch self {
        case .geometry: return "geometry"
        case .sceneLinear, .contrast, .toneMap: return "light"
        case .maskAtlas, .localApply, .localColor: return "masks"
        case .heal: return "heal"
        case .curve: return "curve"
        case .color, .bw, .hsl, .grade: return "color"
        case .vignette, .grain, .detailFX: return "effects"
        case .display: return "output"
        }
    }
}

// MARK: - geometry of a render pass

public struct ImageSize: Sendable, Equatable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }

    public var pixelCount: Int { width * height }
    public var keyString: String { "\(width)x\(height)" }

    /// Largest size with the same aspect that fits inside `box`.
    public static func fit(_ size: ImageSize, in box: ImageSize) -> ImageSize {
        let s = min(Double(box.width) / Double(size.width), Double(box.height) / Double(size.height))
        return ImageSize(width: max(1, Int((Double(size.width) * s).rounded())),
                         height: max(1, Int((Double(size.height) * s).rounded())))
    }
}

/// A rectangle in **content pixels**: the pixel grid of the cropped frame at a render's `scale`,
/// origin top-left, half-open on the far edge.
///
/// Same value type as `PixelRect` — a rectangle is a rectangle — but the alias is the thing
/// `RenderOptions.outputWindow` is expressed in, which is a different coordinate system from a crop
/// in the document (`CropRect`, normalized source) and from a canvas (letterboxed output). Naming
/// it keeps "which pixels?" answerable at every call site.
public typealias ImageRect = PixelRect

extension PixelRect {
    /// Pull the rect inside `frame`: at least one pixel, and never reaching past the frame's edge.
    ///
    /// A window that would leave the frame is *moved and shrunk* rather than refused — the renderer
    /// owes the caller pixels that exist, and `fit`/1:1 framing already clamps the same way
    /// (`LoupeFraming.clampedCenter`).
    public func clamped(in frame: ImageSize) -> PixelRect {
        let w = min(max(width, 1), max(frame.width, 1))
        let h = min(max(height, 1), max(frame.height, 1))
        let cx = min(max(x, 0), max(frame.width, 1) - w)
        let cy = min(max(y, 0), max(frame.height, 1) - h)
        return PixelRect(x: cx, y: cy, width: w, height: h)
    }

    /// Canonical text for cache keys: `wxh+x+y`.
    public var windowKeyString: String { "\(width)x\(height)+\(x)+\(y)" }

    /// The part of this rect that is **inside** `frame`, with zero area when the two do not meet.
    ///
    /// Not `clamped(in:)`: that one moves a rect back inside, which is right for a window the renderer
    /// must fill and wrong for a rect that *describes where something was drawn* — half a picture
    /// hanging off the canvas is half a picture at its own offset, not a whole one at zero. Hence the
    /// empty result: `isEmpty` is how a caller says "nothing of that is here", and `clamped(in:)`'s
    /// forced one pixel would turn it into a claim that a pixel exists.
    public func intersected(in frame: ImageSize) -> PixelRect {
        let x0 = max(x, 0), y0 = max(y, 0)
        let x1 = min(maxX, max(frame.width, 0)), y1 = min(maxY, max(frame.height, 0))
        return PixelRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

// MARK: - output

public enum OutputPrimaries: String, Sendable, Codable, CaseIterable {
    case sRGB
    case displayP3

    public var displayName: String {
        switch self {
        case .sRGB: return "sRGB"
        case .displayP3: return "Display P3"
        }
    }
}

public struct DisplayOptions: Sendable, Equatable {
    public var primaries: OutputPrimaries
    public var bitDepth: Int      // 8 or 16, only affects encoding, not the render
    /// Upper bound of the display encode, in linear scene units.
    ///
    /// `1` is SDR and is **pixel-identical to the pre-EDR output** (`clamp(v, 0, 1)` became
    /// `min(v, headroom)`). Values above 1 only survive if the S4 clamp stops at `headroom`, which
    /// is why this is a contract now rather than in M3.5: opening EDR later must be one boolean and
    /// one number, not a change to S4, S2, the key chain and every golden
    /// (docs/architecture-decisions.md §11.8, item 3).
    public var headroom: Double
    /// **HDR export only.** Ask S4 for the linear picture instead of the display encoding: the
    /// primaries matrix still runs, but the sRGB OETF and the `min(v, headroom)` clamp do not.
    ///
    /// `false` is the shipped path and is byte-identical to the pre-HDR output (`keyString` keeps its
    /// exact old spelling, so every recorded golden and cache key is untouched). `true` is only set
    /// by `GainMapHEIC`'s caller, which needs extended-range linear pixels to compute a gain map; the
    /// readback is therefore a linear `DisplayImage` whose values may exceed 1.
    public var linearOutput: Bool

    public init(primaries: OutputPrimaries = .sRGB, bitDepth: Int = 8, headroom: Double = 1,
                linearOutput: Bool = false) {
        self.primaries = primaries
        self.bitDepth = bitDepth
        self.headroom = headroom
        self.linearOutput = linearOutput
    }

    public var keyString: String {
        // Headroom changes the pixels, so it must change the key; "%.3f" keeps 1.0 == "1.000"
        // across processes and avoids 1 vs 1.0000000001 style churn. The linear suffix is appended
        // **only** when the flag is on, so the default key text is byte-identical to before 100.
        let base = String(format: "%@;bits=%d;headroom=%.3f", primaries.rawValue, bitDepth, headroom)
        return linearOutput ? base + ";linear=true" : base
    }
}

// MARK: - cache keys

/// Accumulates canonically formatted fields and digests them.
///
/// Fixed precision, fixed order, no dictionary iteration: two processes that render the same
/// document must produce the same keys, otherwise the on-disk cache is a coin flip.
public struct KeyBuilder {
    private var parts: [String] = []

    public init() {}

    public init(_ seed: String) { parts = [seed] }

    @discardableResult
    public func add(_ s: String) -> KeyBuilder {
        var c = self
        c.parts.append(s)
        return c
    }

    @discardableResult
    public func add(_ v: Int) -> KeyBuilder {
        var c = self
        c.parts.append("\(v)")
        return c
    }

    @discardableResult
    public func add(_ v: Double) -> KeyBuilder {
        var c = self
        c.parts.append(String(format: "%.5f", v))
        return c
    }

    @discardableResult
    public func add(_ size: ImageSize) -> KeyBuilder {
        var c = self
        c.parts.append(size.keyString)
        return c
    }

    public var canonical: String { parts.joined(separator: "|") }

    public func digest() -> String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Digest of an already-built canonical string (the chain seeds each link with the previous
    /// link's digest, so this is the only operation the chain needs).
    public static func digest(of canonical: String) -> String {
        SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The key chain as a pure function of (input identity, sizes, document, display options).
///
/// Split out of `RenderGraph` for one reason: the "empty masks must not change the M1 keys"
/// invariant (§3.2) has to be testable **without a GPU and without a RAW file** — it is a claim
/// about text, not about pixels. `links` exposes the canonical text of every link so a test can
/// pin it verbatim; `keys` digests it exactly the way the graph does.
public enum RenderKeyChain {
    public struct Links: Sendable, Equatable {
        public var geometry: String
        public var sceneLinear: String
        /// `H(linKey | "masks" | selectionKey… | canvas)`; `nil` when no mask is enabled, in which
        /// case the two stages do not exist for this render at all.
        public var maskAtlas: String?
        /// `H(maskAtlasKey | "local" | applyKey…)`.
        public var localApply: String?
        /// `H(localApply-or-sceneLinear key | "heal" | healMaterial)`; `nil` when the document carries
        /// no spot, in which case S1.9 does not exist for this render at all (2026-10-28, 078 P0-1)
        /// and the curve is seeded exactly as before.
        public var heal: String?
        public var toneMap: String
        public var curve: String
        /// `H(curveKey | "contrast" | contrastMaterial)`; `nil` when `light.contrast == 0`, in which
        /// case S1.8 does not exist for this render at all (098) and S2 is seeded by the curve exactly
        /// as before.
        public var contrast: String?
        public var color: String
        /// `H(colorKey | "bw" | bwMaterial)`; `nil` when the document is not black-and-white, in which
        /// case S3.4 does not exist for this render at all (2026-10-28) and the next link is seeded by
        /// `color` exactly as before.
        public var bw: String?
        /// `H(colorKey | "localcolor" | localColorMaterial)`; `nil` when no enabled mask carries a
        /// hue or saturation value, in which case the stage does not exist for this render at all
        /// (派单 056) and the next link is seeded by `bw`/`color` exactly as before.
        public var localColor: String?
        /// `H(bw-or-localColor-or-color key | "hsl" | hslBandMaterial)`; `nil` when no band carries a
        /// value, in which case the stage does not exist for this render at all (派单 076) and
        /// `vignette` is seeded exactly as before.
        public var hsl: String?
        /// `H(hsl-or-localColor-or-bw-or-color key | "grade" | gradeMaterial)`; `nil` when the grade
        /// group is neutral, in which case S3.8 does not exist for this render at all (2026-10-28,
        /// P0 色彩分级) and `vignette` is seeded exactly as before.
        public var grade: String?
        /// `H(grade-or-hsl-or-localColor-or-bw-or-color key | "detailfx" | detailFXMaterial)`; `nil`
        /// when all three detail numbers are 0, in which case S3.9 does not exist for this render at all
        /// (2026-10-28, P0-6) and `vignette` is seeded exactly as before.
        public var detailFX: String?
        public var vignette: String
        /// `H(vignetteKey | "grain" | grainMaterial)`; `nil` when the grain amount is 0, in which case
        /// S3.7 does not exist for this render at all (2026-10-28) and `display` is seeded by
        /// `vignette` exactly as before.
        public var grain: String?
        public var display: String

        public var hasMaskStages: Bool { maskAtlas != nil && localApply != nil }
        public var hasHealStage: Bool { heal != nil }
        public var hasContrastStage: Bool { contrast != nil }
        public var hasBWStage: Bool { bw != nil }
        public var hasLocalColorStage: Bool { localColor != nil }
        public var hasHSLStage: Bool { hsl != nil }
        public var hasGradeStage: Bool { grade != nil }
        public var hasDetailFXStage: Bool { detailFX != nil }
        public var hasGrainStage: Bool { grain != nil }

        /// The stages this link set describes — the same answer `StageKeys.pipeline` gives, available
        /// without a GPU so a test can pin "the stage exists" and "the stage does not exist" as text.
        public var pipeline: [RenderStage] {
            RenderStage.pipeline(hasMasks: hasMaskStages, hasLocalColor: hasLocalColorStage,
                                 hasHSL: hasHSLStage, hasGrain: hasGrainStage,
                                 hasBW: hasBWStage, hasGrade: hasGradeStage,
                                 hasDetailFX: hasDetailFXStage, hasHeal: hasHealStage,
                                 hasContrast: hasContrastStage)
        }
    }

    /// `materialWithoutAlgorithmVersion: true` drops every stage's `;alg=N` token, i.e. rebuilds the
    /// pre-P1f chain byte for byte. **Never true in the app** — `CacheVersionTests` sets it to show
    /// that a chain without the version reproduces the old keys exactly, which is the stale-thumbnail
    /// bug 079 §2.7.1 is about.
    public static func links(identity: String, sourceSize: ImageSize, canvas: ImageSize,
                             content: ImageSize, edit: EditModel,
                             display: DisplayOptions,
                             outputWindow: ImageRect? = nil,
                             orientation: ImageOrientation = .up,
                             lens: String? = nil,
                             materialWithoutAlgorithmVersion: Bool = false) -> Links {
        func mat(_ stage: RenderStage) -> String {
            edit.keyMaterial(stage, algorithmVersion: !materialWithoutAlgorithmVersion)
        }
        var geometryKey = KeyBuilder("photons-render-v1")
            .add(identity)
            .add(sourceSize)
            .add(canvas)
            .add(content)
            .add(mat(.geometry))
        // Orientation is a **file** fact, not an edit (docs/architecture-decisions.md §11.2): it is
        // deliberately absent from `EditModel`, so the key has to carry it here — otherwise two
        // renders over differently-oriented decodes of the same bytes could share cached geometry.
        // Appended only when it is not `.up`, so every document that came before this field (and
        // every file whose tag says 1) keeps its key verbatim (§3.2 discipline).
        if orientation != .up {
            geometryKey = geometryKey.add("orient=" + orientation.keyString)
        }
        // The output window changes which pixels S0 samples for a given output pixel, so it belongs
        // in the geometry link — the same link, not a side channel: everything downstream of S0 has
        // different pixels and must therefore miss. `nil` (the whole frame, i.e. every pre-window
        // render: fit, thumbnails, export) appends nothing, so those keys stay byte-identical.
        if let window = outputWindow {
            geometryKey = geometryKey.add("win=" + window.windowKeyString)
        }
        // 097: only a file whose S0 warp we apply appends this, so every pre-097 document and every
        // Apple-corrected file keeps its geometry key byte for byte.
        if let lens {
            geometryKey = geometryKey.add(lens)
        }
        let geometry = geometryKey.canonical
        let sceneLinear = KeyBuilder(KeyBuilder.digest(of: geometry))
            .add(mat(.sceneLinear))
            .canonical

        var maskAtlas: String?
        var localApply: String?
        var toneMap: String
        var curve: String
        // 2026-10-28 (078 P0-1): **the S1.9 link**, and the reason it is computed here rather than in
        // the two branches below: S1.9 sits between S1.6 and S1.7, so the curve's seed is either the
        // local link, S1's own, or — when the document carries a spot — the heal link. With no spot
        // the link does not exist at all and the curve is seeded exactly as before, which is what
        // keeps every pre-S1.9 key byte for byte (§3.2 discipline, the sixth stage to use it).
        var heal: String?
        var curveSeed: String
        if edit.hasActiveMasks {
            // The explicit exception of §3.2: with masks the chain is nine links, and every link
            // below the atlas moves. Without masks the two lines below simply do not run and
            // `toneMap` is byte-identical to M1.
            let atlas = KeyBuilder(KeyBuilder.digest(of: sceneLinear))
                .add("masks")
                .add(edit.maskSelectionMaterial)
                .add(canvas)
                .canonical
            let local = KeyBuilder(KeyBuilder.digest(of: atlas))
                .add("local")
                .add(edit.maskApplyMaterial)
                .canonical
            maskAtlas = atlas
            localApply = local
            curveSeed = local
        } else {
            curveSeed = sceneLinear
        }
        // 2026-10-28 (078 P0-1): S1.9 exists **only** when the document carries a spot. When it does
        // not, the link is `nil` and the curve is seeded by the local link (or S1's) exactly as
        // before — so a document that has never used the 修复画笔 keeps its whole key chain byte for
        // byte.
        if edit.hasHeal {
            let link = KeyBuilder(KeyBuilder.digest(of: curveSeed))
                .add("heal")
                .add(mat(.heal))
                .canonical
            heal = link
            curveSeed = link
        }
        // 030: the curve reads whatever the stage above produced, and S2 reads the curve. A curve
        // drag therefore misses S1.7, S2, S3, S3c and S4 — and **hits** S0/S1/S1.5/S1.6/S1.9, which
        // is the whole reason the curve has its own stage instead of riding on S1's key (§3.2 of 030).
        curve = KeyBuilder(KeyBuilder.digest(of: curveSeed)).add(mat(.curve)).canonical
        // 098: S1.8 sits between the curve and S2 and exists only when contrast is non-zero. Neutral
        // leaves the link `nil`, so S2 is seeded by the curve and every existing chain stays intact.
        var contrast: String?
        var toneMapSeed = curve
        if edit.hasContrastStage {
            let link = KeyBuilder(KeyBuilder.digest(of: curve))
                .add("contrast")
                .add(mat(.contrast))
                .canonical
            contrast = link
            toneMapSeed = link
        }
        toneMap = KeyBuilder(KeyBuilder.digest(of: toneMapSeed)).add(mat(.toneMap)).canonical

        let color = KeyBuilder(KeyBuilder.digest(of: toneMap)).add(mat(.color)).canonical
        // 2026-10-28 (P0-4): S3.4 sits between S3 and S3.5 and exists **only** when the 黑白 switch is
        // on. When it is not, the link is `nil` and the next link is seeded by `color` — so every
        // colour document keeps its pre-S3.4 key chain byte for byte, which is exactly the §3.2
        // discipline the mask, local-colour, HSL and grain stages follow.
        var bw: String?
        var nextSeed = color
        if edit.hasBlackAndWhite {
            let link = KeyBuilder(KeyBuilder.digest(of: color))
                .add("bw")
                .add(mat(.bw))
                .canonical
            bw = link
            nextSeed = link
        }
        // 056: S3.5 sits between S3 and the vignette and exists **only** when a mask carries a hue or
        // a saturation value. When it does not, the link is `nil` and the vignette is seeded by
        // `color`/`bw` — so every document without local colour keeps its pre-056 key chain byte for
        // byte, which is exactly the §3.2 discipline the mask stages follow.
        var localColor: String?
        var vignetteSeed = nextSeed
        if edit.hasLocalColor {
            let local = KeyBuilder(KeyBuilder.digest(of: nextSeed))
                .add("localcolor")
                .add(mat(.localColor))
                .canonical
            localColor = local
            vignetteSeed = local
        }
        // 076: S3.6 sits between S3.5 and the vignette and exists **only** when a band carries a value.
        // When it does not, the link is `nil` and the vignette is seeded by `localColor`/`color` — so
        // every document without HSL keeps its pre-076 key chain byte for byte.
        var hsl: String?
        if edit.hasHSL {
            let link = KeyBuilder(KeyBuilder.digest(of: vignetteSeed))
                .add("hsl")
                .add(mat(.hsl))
                .canonical
            hsl = link
            vignetteSeed = link
        }
        // 2026-10-28 (P0 色彩分级): S3.8 sits between S3.6 and the vignette and exists **only** when one
        // of its nine numbers is non-zero. When the group is neutral the link is `nil` and the vignette
        // is seeded by `hsl`/`localColor`/`bw`/`color` — so every document without a grade keeps its
        // pre-S3.8 key chain byte for byte. This is the fifth stage to use the §3.2 discipline, and it
        // is what makes 「中性文档：键不长新段」 a structural fact rather than a promise.
        var grade: String?
        if edit.hasGrade {
            let link = KeyBuilder(KeyBuilder.digest(of: vignetteSeed))
                .add("grade")
                .add(mat(.grade))
                .canonical
            grade = link
            vignetteSeed = link
        }
        // 2026-10-28 (P0-6): S3.9 (纹理/清晰度/去雾) sits between the grade and the vignette and exists
        // **only** when one of the three numbers is non-zero. Neutral ⇒ the link is `nil` and the
        // vignette is seeded exactly as before, so a document without detail keeps its chain byte for
        // byte (the sixth stage to use the §3.2 discipline).
        var detailFX: String?
        if edit.hasDetailFX {
            let link = KeyBuilder(KeyBuilder.digest(of: vignetteSeed))
                .add("detailfx")
                .add(mat(.detailFX))
                .canonical
            detailFX = link
            vignetteSeed = link
        }
        let vignette = KeyBuilder(KeyBuilder.digest(of: vignetteSeed)).add(mat(.vignette)).canonical
        // 2026-10-28: S3.7 sits between the vignette and the display transform and exists **only** when
        // the grain amount is above zero. When it does not, the link is `nil` and the display key is
        // seeded by `vignette` exactly as before — so a document without grain keeps its pre-S3.7 key
        // chain byte for byte (the §3.2 discipline the mask, local-colour and HSL stages follow).
        var grain: String?
        var displaySeed = vignette
        if edit.hasGrain {
            let link = KeyBuilder(KeyBuilder.digest(of: vignette))
                .add("grain")
                .add(mat(.grain))
                .canonical
            grain = link
            displaySeed = link
        }
        var displayKey = KeyBuilder(KeyBuilder.digest(of: displaySeed))
            .add(display.keyString)
            .add(canvas)
        // 005e: `showMask` changes the last pass's pixels, so showing a different mask must move the
        // display key — and *only* then. Appending unconditionally would change every pinned M1 key
        // and every recorded golden for a field that is nil in all of them (§3.2 discipline).
        if let shown = edit.showMaskID { displayKey = displayKey.add("show=" + shown) }

        return Links(geometry: geometry, sceneLinear: sceneLinear,
                     maskAtlas: maskAtlas, localApply: localApply, heal: heal,
                     toneMap: toneMap, curve: curve, contrast: contrast, color: color, bw: bw,
                     localColor: localColor,
                     hsl: hsl, grade: grade, detailFX: detailFX, vignette: vignette, grain: grain,
                     display: displayKey.canonical)
    }

    public static func keys(_ links: Links, identity: String) -> StageKeys {
        StageKeys(inputIdentity: identity,
                  geometry: KeyBuilder.digest(of: links.geometry),
                  sceneLinear: KeyBuilder.digest(of: links.sceneLinear),
                  maskAtlas: links.maskAtlas.map(KeyBuilder.digest(of:)),
                  localApply: links.localApply.map(KeyBuilder.digest(of:)),
                  heal: links.heal.map(KeyBuilder.digest(of:)),
                  toneMap: KeyBuilder.digest(of: links.toneMap),
                  curve: KeyBuilder.digest(of: links.curve),
                  contrast: links.contrast.map(KeyBuilder.digest(of:)),
                  color: KeyBuilder.digest(of: links.color),
                  bw: links.bw.map(KeyBuilder.digest(of:)),
                  localColor: links.localColor.map(KeyBuilder.digest(of:)),
                  hsl: links.hsl.map(KeyBuilder.digest(of:)),
                  grade: links.grade.map(KeyBuilder.digest(of:)),
                  detailFX: links.detailFX.map(KeyBuilder.digest(of:)),
                  vignette: KeyBuilder.digest(of: links.vignette),
                  grain: links.grain.map(KeyBuilder.digest(of:)),
                  display: KeyBuilder.digest(of: links.display))
    }
}

/// The key chain for one render: each stage's output key, computed before anything runs.
///
/// Seven links for a document without masks (exactly M1), nine when masks are active, ten when a
/// mask also carries local colour, eleven when the document also has HSL bands (076), twelve with
/// grain, thirteen when it is black-and-white (2026-10-28):
/// `geo → lin → [maskAtlas → localApply →] curve → toneMap → color → [bw →] [localColor →] vignette
/// → [grain →] display`.
/// The two mask keys are `nil` for the M1 chain and `localColor` is `nil` without local colour —
/// that is the explicit exception of §3.2, and `pipeline` is what makes the stages disappear instead
/// of merely being skipped.
///
/// 派单 030 swapped `curve` and `toneMap`: the curve runs *before* the tone map now, so S2's key is
/// seeded by the curve's and the curve's by S1.6 (or S1). The **order of the fields in this struct**
/// is declaration order, not execution order — `RenderStage.order` is the authority.
public struct StageKeys: Sendable, Equatable {
    public var inputIdentity: String
    public var geometry: String
    public var sceneLinear: String
    /// `H(linKey | "masks" | selectionKey… | canvas)`; `nil` when no mask is enabled.
    public var maskAtlas: String?
    /// `H(maskAtlasKey | "local" | applyKey…)`; `nil` when no mask is enabled.
    public var localApply: String?
    /// `H(localApply-or-sceneLinear key | "heal" | healMaterial)`; `nil` when the document carries no
    /// spot (2026-10-28, 078 P0-1), in which case S1.9 does not exist for this render.
    public var heal: String?
    public var toneMap: String
    public var curve: String
    /// `H(curveKey | "contrast" | contrastMaterial)`; `nil` when `light.contrast == 0` (098), in which
    /// case S1.8 does not exist for this render and S2 is seeded by the curve.
    public var contrast: String?
    public var color: String
    /// `H(colorKey | "bw" | bwMaterial)`; `nil` when the document is not black-and-white
    /// (2026-10-28), in which case the stage does not exist for this render.
    public var bw: String?
    /// `H(colorKey | "localcolor" | localColorMaterial)`; `nil` when the document has no local
    /// hue/saturation (派单 056), in which case the stage does not exist for this render.
    public var localColor: String?
    /// `H(colorKey | "hsl" | hslBandMaterial)`; `nil` when no band carries a value (派单 076), in
    /// which case the stage does not exist for this render.
    public var hsl: String?
    /// `H(hsl-or-localColor-or-bw-or-color key | "grade" | gradeMaterial)`; `nil` when the grade group
    /// is neutral (2026-10-28, P0 色彩分级), in which case the stage does not exist for this render.
    public var grade: String?
    /// `H(grade-or-hsl-or-localColor-or-bw-or-color key | "detailfx" | detailFXMaterial)`; `nil` when
    /// all three detail numbers are 0 (2026-10-28, P0-6), in which case the stage does not exist.
    public var detailFX: String?
    public var vignette: String
    /// `H(vignetteKey | "grain" | grainMaterial)`; `nil` when the grain amount is 0 (2026-10-28), in
    /// which case the stage does not exist for this render.
    public var grain: String?
    public var display: String

    public init(inputIdentity: String, geometry: String, sceneLinear: String,
                maskAtlas: String? = nil, localApply: String? = nil, heal: String? = nil,
                toneMap: String, curve: String, contrast: String? = nil, color: String,
                bw: String? = nil, localColor: String? = nil,
                hsl: String? = nil,
                grade: String? = nil, detailFX: String? = nil,
                vignette: String, grain: String? = nil, display: String) {
        self.inputIdentity = inputIdentity
        self.geometry = geometry
        self.sceneLinear = sceneLinear
        self.maskAtlas = maskAtlas
        self.localApply = localApply
        self.heal = heal
        self.toneMap = toneMap
        self.curve = curve
        self.contrast = contrast
        self.color = color
        self.bw = bw
        self.localColor = localColor
        self.hsl = hsl
        self.grade = grade
        self.detailFX = detailFX
        self.vignette = vignette
        self.grain = grain
        self.display = display
    }

    public var hasMaskStages: Bool { maskAtlas != nil && localApply != nil }
    public var hasHealStage: Bool { heal != nil }
    public var hasContrastStage: Bool { contrast != nil }
    public var hasBWStage: Bool { bw != nil }
    public var hasLocalColorStage: Bool { localColor != nil }
    public var hasHSLStage: Bool { hsl != nil }
    public var hasGradeStage: Bool { grade != nil }
    public var hasDetailFXStage: Bool { detailFX != nil }
    public var hasGrainStage: Bool { grain != nil }

    /// Key for a stage. The mask stages answer `""` when they do not exist for this render, which is
    /// only reachable by asking for a stage the pipeline does not visit.
    public func key(for stage: RenderStage) -> String {
        switch stage {
        case .geometry: return geometry
        case .sceneLinear: return sceneLinear
        case .maskAtlas: return maskAtlas ?? ""
        case .localApply: return localApply ?? ""
        case .heal: return heal ?? ""
        case .toneMap: return toneMap
        case .curve: return curve
        case .contrast: return contrast ?? ""
        case .color: return color
        case .bw: return bw ?? ""
        case .localColor: return localColor ?? ""
        case .hsl: return hsl ?? ""
        case .grade: return grade ?? ""
        case .detailFX: return detailFX ?? ""
        case .vignette: return vignette
        case .grain: return grain ?? ""
        case .display: return display
        }
    }

    /// The stages this key set describes: seven, nine with masks, ten when a mask also carries local
    /// colour (派单 056), eleven when the document also has HSL bands (派单 076), twelve when it has a
    /// grade (2026-10-28), thirteen when it also has grain and fourteen when it is black-and-white.
    public var pipeline: [RenderStage] {
        RenderStage.pipeline(hasMasks: hasMaskStages, hasLocalColor: hasLocalColorStage,
                             hasHSL: hasHSLStage, hasGrain: hasGrainStage, hasBW: hasBWStage,
                             hasGrade: hasGradeStage, hasDetailFX: hasDetailFXStage,
                             hasHeal: hasHealStage, hasContrast: hasContrastStage)
    }

    public var shortTrace: String {
        pipeline.map { "\($0.short)=\(key(for: $0).prefix(8))" }.joined(separator: " ")
    }
}

// MARK: - trace

/// What actually ran, what came out of the stage cache, and how long the GPU took.
public struct RenderTrace: Sendable {
    public var executed: [RenderStage] = []
    public var skipped: [RenderStage] = []
    public var gpuMilliseconds: Double = 0
    public var cacheHits: Int = 0
    /// 029: S0 took the pure-CA fast path — the frame is the source pixel grid, so green was a texel
    /// copy and only red/blue were resampled. False for every document with α = 0 (that is the
    /// identity copy) and for a CA document that also crops/rotates/scales (the general path).
    public var s0PureCA = false

    public init() {}

    public mutating func record(_ stage: RenderStage, executed didRun: Bool) {
        if didRun {
            executed.append(stage)
        } else {
            skipped.append(stage)
            cacheHits += 1
        }
    }

    public var summary: String {
        let ex = executed.isEmpty ? "(none)" : executed.map(\.label).joined(separator: " ")
        let sk = skipped.isEmpty ? "(none)" : skipped.map(\.label).joined(separator: " ")
        return "stages     \(ex)\nskipped    \(sk)\ngpu        \(String(format: "%.2f", gpuMilliseconds)) ms"
    }

    /// Comma-free machine form for grepping in scripts (`--trace-stages --trace-format csv`).
    public var csv: String {
        executed.map(\.label).joined(separator: ",")
    }
}
