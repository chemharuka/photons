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
    /// 派单 030: **the** tone curve, in the HDR (scene-linear, log1p-shaped) domain.
    ///
    /// It used to be `s3-curve`, after the tone map, on 0…1 data S2 had already compressed — so the
    /// user could only bend what S2 had shaped, and a +4 EV highlight had already been treated as a
    /// "highlights region" before the curve saw it. `s3_curve` (the file, the kernel and the stage)
    /// is **deleted**; this is the one curve. `grep -rn "s3_curve" Sources` must find nothing but
    /// this sentence.
    case curve = "s1.7-hdr-curve"
    case toneMap = "s2-tone-map"
    case color = "s3-color"
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
    case vignette = "s3-vignette"
    case display = "s4-display"

    /// The seven passes every document runs. Mask stages are excluded on purpose: `masks == []`
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
    /// S3.5 (`localColor`) and S3.6 (`hsl`) are in this list because they *are* stages — index, trace and
    /// the key chain speak one language — but `pipeline(hasMasks:hasLocalColor:hasHSL:)` is what decides
    /// whether a render visits them. A document whose masks carry neither hue nor saturation never
    /// visits S3.5, and one whose bands are all 0 never visits S3.6.
    public static var order: [RenderStage] {
        [.geometry, .sceneLinear, .maskAtlas, .localApply, .curve, .toneMap, .color, .localColor,
         .hsl, .vignette, .display]
    }

    /// The stages one render actually visits.
    ///
    /// Three conditional families, three predicates: the mask stages appear when *any* mask is enabled,
    /// S3.5 only when a mask actually carries a hue or a saturation value (派单 056 §验收 7 — the
    /// judgement is by value, not by "there is a mask"), and S3.6 only when a band carries a value
    /// (派单 076). With neither, the answer is exactly the pre-056 list, which is what keeps every
    /// existing trace and key byte for byte.
    public static func pipeline(hasMasks: Bool, hasLocalColor: Bool = false,
                                hasHSL: Bool = false) -> [RenderStage] {
        guard hasMasks || hasHSL else { return allCases }
        return order.filter { stage in
            switch stage {
            case .maskAtlas, .localApply: return hasMasks
            case .localColor: return hasMasks && hasLocalColor
            case .hsl: return hasHSL
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
        case .curve: return "s1.7"
        case .toneMap: return "s2"
        case .color: return "s3-color"
        case .localColor: return "s3.5"
        case .hsl: return "s3.6"
        case .vignette: return "s3-vignette"
        case .display: return "s4"
        }
    }

    /// Stages whose parameters live in the same UI group; used to explain a dirty set.
    public var group: String {
        switch self {
        case .geometry: return "geometry"
        case .sceneLinear, .toneMap: return "light"
        case .maskAtlas, .localApply, .localColor: return "masks"
        case .curve: return "curve"
        case .color, .hsl: return "color"
        case .vignette: return "effects"
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

    public init(primaries: OutputPrimaries = .sRGB, bitDepth: Int = 8, headroom: Double = 1) {
        self.primaries = primaries
        self.bitDepth = bitDepth
        self.headroom = headroom
    }

    public var keyString: String {
        // Headroom changes the pixels, so it must change the key; "%.3f" keeps 1.0 == "1.000"
        // across processes and avoids 1 vs 1.0000000001 style churn.
        String(format: "%@;bits=%d;headroom=%.3f", primaries.rawValue, bitDepth, headroom)
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
        public var toneMap: String
        public var curve: String
        public var color: String
        /// `H(colorKey | "localcolor" | localColorMaterial)`; `nil` when no enabled mask carries a
        /// hue or saturation value, in which case the stage does not exist for this render at all
        /// (派单 056) and `vignette` is seeded by `color` exactly as before.
        public var localColor: String?
        /// `H(color-or-localColor key | "hsl" | hslBandMaterial)`; `nil` when no band carries a value,
        /// in which case the stage does not exist for this render at all (派单 076) and `vignette` is
        /// seeded exactly as before.
        public var hsl: String?
        public var vignette: String
        public var display: String

        public var hasMaskStages: Bool { maskAtlas != nil && localApply != nil }
        public var hasLocalColorStage: Bool { localColor != nil }
        public var hasHSLStage: Bool { hsl != nil }

        /// The stages this link set describes — the same answer `StageKeys.pipeline` gives, available
        /// without a GPU so a test can pin "the stage exists" and "the stage does not exist" as text.
        public var pipeline: [RenderStage] {
            RenderStage.pipeline(hasMasks: hasMaskStages, hasLocalColor: hasLocalColorStage,
                                 hasHSL: hasHSLStage)
        }
    }

    public static func links(identity: String, sourceSize: ImageSize, canvas: ImageSize,
                             content: ImageSize, edit: EditModel,
                             display: DisplayOptions,
                             outputWindow: ImageRect? = nil,
                             orientation: ImageOrientation = .up) -> Links {
        var geometryKey = KeyBuilder("photons-render-v1")
            .add(identity)
            .add(sourceSize)
            .add(canvas)
            .add(content)
            .add(edit.keyMaterial(.geometry))
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
        let geometry = geometryKey.canonical
        let sceneLinear = KeyBuilder(KeyBuilder.digest(of: geometry))
            .add(edit.keyMaterial(.sceneLinear))
            .canonical

        var maskAtlas: String?
        var localApply: String?
        var toneMap: String
        var curve: String
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
            // 030: the curve reads whatever the mask stages produced, and S2 reads the curve. A
            // curve drag therefore misses S1.7, S2, S3, S3c and S4 — and **hits** S0/S1/S1.5/S1.6,
            // which is the whole reason the curve has its own stage instead of riding on S1's key
            // (§3.2 of 030).
            curve = KeyBuilder(KeyBuilder.digest(of: local)).add(edit.keyMaterial(.curve)).canonical
            toneMap = KeyBuilder(KeyBuilder.digest(of: curve)).add(edit.keyMaterial(.toneMap)).canonical
        } else {
            curve = KeyBuilder(KeyBuilder.digest(of: sceneLinear))
                .add(edit.keyMaterial(.curve)).canonical
            toneMap = KeyBuilder(KeyBuilder.digest(of: curve))
                .add(edit.keyMaterial(.toneMap))
                .canonical
        }

        let color = KeyBuilder(KeyBuilder.digest(of: toneMap)).add(edit.keyMaterial(.color)).canonical
        // 056: S3.5 sits between S3 and the vignette and exists **only** when a mask carries a hue or
        // a saturation value. When it does not, the link is `nil` and the vignette is seeded by
        // `color` — so every document without local colour keeps its pre-056 key chain byte for byte,
        // which is exactly the §3.2 discipline the mask stages follow.
        var localColor: String?
        var vignetteSeed = color
        if edit.hasLocalColor {
            let local = KeyBuilder(KeyBuilder.digest(of: color))
                .add("localcolor")
                .add(edit.keyMaterial(.localColor))
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
                .add(edit.keyMaterial(.hsl))
                .canonical
            hsl = link
            vignetteSeed = link
        }
        let vignette = KeyBuilder(KeyBuilder.digest(of: vignetteSeed)).add(edit.keyMaterial(.vignette)).canonical
        var displayKey = KeyBuilder(KeyBuilder.digest(of: vignette))
            .add(display.keyString)
            .add(canvas)
        // 005e: `showMask` changes the last pass's pixels, so showing a different mask must move the
        // display key — and *only* then. Appending unconditionally would change every pinned M1 key
        // and every recorded golden for a field that is nil in all of them (§3.2 discipline).
        if let shown = edit.showMaskID { displayKey = displayKey.add("show=" + shown) }

        return Links(geometry: geometry, sceneLinear: sceneLinear,
                     maskAtlas: maskAtlas, localApply: localApply,
                     toneMap: toneMap, curve: curve, color: color, localColor: localColor,
                     hsl: hsl, vignette: vignette, display: displayKey.canonical)
    }

    public static func keys(_ links: Links, identity: String) -> StageKeys {
        StageKeys(inputIdentity: identity,
                  geometry: KeyBuilder.digest(of: links.geometry),
                  sceneLinear: KeyBuilder.digest(of: links.sceneLinear),
                  maskAtlas: links.maskAtlas.map(KeyBuilder.digest(of:)),
                  localApply: links.localApply.map(KeyBuilder.digest(of:)),
                  toneMap: KeyBuilder.digest(of: links.toneMap),
                  curve: KeyBuilder.digest(of: links.curve),
                  color: KeyBuilder.digest(of: links.color),
                  localColor: links.localColor.map(KeyBuilder.digest(of:)),
                  hsl: links.hsl.map(KeyBuilder.digest(of:)),
                  vignette: KeyBuilder.digest(of: links.vignette),
                  display: KeyBuilder.digest(of: links.display))
    }
}

/// The key chain for one render: each stage's output key, computed before anything runs.
///
/// Seven links for a document without masks (exactly M1), nine when masks are active, ten when a
/// mask also carries local colour, eleven when the document also has HSL bands (076):
/// `geo → lin → [maskAtlas → localApply →] curve → toneMap → color → [localColor →] vignette → display`.
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
    public var toneMap: String
    public var curve: String
    public var color: String
    /// `H(colorKey | "localcolor" | localColorMaterial)`; `nil` when the document has no local
    /// hue/saturation (派单 056), in which case the stage does not exist for this render.
    public var localColor: String?
    /// `H(colorKey | "hsl" | hslBandMaterial)`; `nil` when no band carries a value (派单 076), in
    /// which case the stage does not exist for this render.
    public var hsl: String?
    public var vignette: String
    public var display: String

    public init(inputIdentity: String, geometry: String, sceneLinear: String,
                maskAtlas: String? = nil, localApply: String? = nil,
                toneMap: String, curve: String, color: String, localColor: String? = nil,
                hsl: String? = nil,
                vignette: String, display: String) {
        self.inputIdentity = inputIdentity
        self.geometry = geometry
        self.sceneLinear = sceneLinear
        self.maskAtlas = maskAtlas
        self.localApply = localApply
        self.toneMap = toneMap
        self.curve = curve
        self.color = color
        self.localColor = localColor
        self.hsl = hsl
        self.vignette = vignette
        self.display = display
    }

    public var hasMaskStages: Bool { maskAtlas != nil && localApply != nil }
    public var hasLocalColorStage: Bool { localColor != nil }
    public var hasHSLStage: Bool { hsl != nil }

    /// Key for a stage. The mask stages answer `""` when they do not exist for this render, which is
    /// only reachable by asking for a stage the pipeline does not visit.
    public func key(for stage: RenderStage) -> String {
        switch stage {
        case .geometry: return geometry
        case .sceneLinear: return sceneLinear
        case .maskAtlas: return maskAtlas ?? ""
        case .localApply: return localApply ?? ""
        case .toneMap: return toneMap
        case .curve: return curve
        case .color: return color
        case .localColor: return localColor ?? ""
        case .hsl: return hsl ?? ""
        case .vignette: return vignette
        case .display: return display
        }
    }

    /// The stages this key set describes: seven, nine with masks, ten when a mask also carries local
    /// colour (派单 056), and eleven when the document also has HSL bands (派单 076).
    public var pipeline: [RenderStage] {
        RenderStage.pipeline(hasMasks: hasMaskStages, hasLocalColor: hasLocalColorStage,
                             hasHSL: hasHSLStage)
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
