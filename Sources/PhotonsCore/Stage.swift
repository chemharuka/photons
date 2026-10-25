import Foundation
import CryptoKit

// MARK: - stages

/// The stages of the editing graph, in execution order.
///
/// `RenderStage` is the unit of both the cache-key chain (D6) and group-level dirty tracking (D10).
/// Every stage boundary is a key: re-running S3 must not re-run S0/S1.
///
/// M4 adds two **conditional** stages between S1 and S2 (`s1.5-mask-atlas`, `s1.6-local`). They are
/// cases of this enum — so the trace, the dirty set and the key chain all speak the same language —
/// but they are deliberately *not* in `allCases`, because `allCases` means "the passes every
/// document renders". A document with no masks must produce exactly the M1 trace and the M1 keys
/// (docs/tasks/005-masks.md §3.2); see `pipeline`.
public enum RenderStage: String, CaseIterable, Sendable, Codable {
    case geometry = "s0-geometry"
    case sceneLinear = "s1-scene-linear"
    case maskAtlas = "s1.5-mask-atlas"
    case localApply = "s1.6-local"
    case toneMap = "s2-tone-map"
    case curve = "s3-curve"
    case color = "s3-color"
    case vignette = "s3-vignette"
    case display = "s4-display"

    /// The seven passes every document runs. Mask stages are excluded on purpose: `masks == []`
    /// must be byte-for-byte the M1 graph, including the set of stages a cold render reports.
    public static var allCases: [RenderStage] {
        [.geometry, .sceneLinear, .toneMap, .curve, .color, .vignette, .display]
    }

    /// Execution order including the conditional stages.
    public static var order: [RenderStage] {
        [.geometry, .sceneLinear, .maskAtlas, .localApply, .toneMap, .curve, .color, .vignette, .display]
    }

    /// The stages one render actually visits.
    public static func pipeline(hasMasks: Bool) -> [RenderStage] {
        hasMasks ? order : allCases
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
        case .toneMap: return "s2"
        case .curve: return "s3-curve"
        case .color: return "s3-color"
        case .vignette: return "s3-vignette"
        case .display: return "s4"
        }
    }

    /// Stages whose parameters live in the same UI group; used to explain a dirty set.
    public var group: String {
        switch self {
        case .geometry: return "geometry"
        case .sceneLinear, .toneMap: return "light"
        case .maskAtlas, .localApply: return "masks"
        case .curve: return "curve"
        case .color: return "color"
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
        public var vignette: String
        public var display: String

        public var hasMaskStages: Bool { maskAtlas != nil && localApply != nil }
    }

    public static func links(identity: String, sourceSize: ImageSize, canvas: ImageSize,
                             content: ImageSize, edit: EditModel,
                             display: DisplayOptions) -> Links {
        let geometry = KeyBuilder("photons-render-v1")
            .add(identity)
            .add(sourceSize)
            .add(canvas)
            .add(content)
            .add(edit.keyMaterial(.geometry))
            .canonical
        let sceneLinear = KeyBuilder(KeyBuilder.digest(of: geometry))
            .add(edit.keyMaterial(.sceneLinear))
            .canonical

        var maskAtlas: String?
        var localApply: String?
        var toneMap: String
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
            toneMap = KeyBuilder(KeyBuilder.digest(of: local)).add(edit.keyMaterial(.toneMap)).canonical
        } else {
            toneMap = KeyBuilder(KeyBuilder.digest(of: sceneLinear))
                .add(edit.keyMaterial(.toneMap))
                .canonical
        }

        let curve = KeyBuilder(KeyBuilder.digest(of: toneMap)).add(edit.keyMaterial(.curve)).canonical
        let color = KeyBuilder(KeyBuilder.digest(of: curve)).add(edit.keyMaterial(.color)).canonical
        let vignette = KeyBuilder(KeyBuilder.digest(of: color)).add(edit.keyMaterial(.vignette)).canonical
        var displayKey = KeyBuilder(KeyBuilder.digest(of: vignette))
            .add(display.keyString)
            .add(canvas)
        // 005e: `showMask` changes the last pass's pixels, so showing a different mask must move the
        // display key — and *only* then. Appending unconditionally would change every pinned M1 key
        // and every recorded golden for a field that is nil in all of them (§3.2 discipline).
        if let shown = edit.showMaskID { displayKey = displayKey.add("show=" + shown) }

        return Links(geometry: geometry, sceneLinear: sceneLinear,
                     maskAtlas: maskAtlas, localApply: localApply,
                     toneMap: toneMap, curve: curve, color: color,
                     vignette: vignette, display: displayKey.canonical)
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
                  vignette: KeyBuilder.digest(of: links.vignette),
                  display: KeyBuilder.digest(of: links.display))
    }
}

/// The key chain for one render: each stage's output key, computed before anything runs.
///
/// Seven links for a document without masks (exactly M1), nine when masks are active:
/// `geo → lin → maskAtlas → localApply → preNR → curve → color → vignette → display`. The two mask
/// keys are `nil` for the M1 chain — that is the explicit exception of §3.2, and `pipeline` is what
/// makes the stages disappear instead of merely being skipped.
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
    public var vignette: String
    public var display: String

    public init(inputIdentity: String, geometry: String, sceneLinear: String,
                maskAtlas: String? = nil, localApply: String? = nil,
                toneMap: String, curve: String, color: String, vignette: String, display: String) {
        self.inputIdentity = inputIdentity
        self.geometry = geometry
        self.sceneLinear = sceneLinear
        self.maskAtlas = maskAtlas
        self.localApply = localApply
        self.toneMap = toneMap
        self.curve = curve
        self.color = color
        self.vignette = vignette
        self.display = display
    }

    public var hasMaskStages: Bool { maskAtlas != nil && localApply != nil }

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
        case .vignette: return vignette
        case .display: return display
        }
    }

    /// The stages this key set describes: seven, or nine with masks.
    public var pipeline: [RenderStage] { RenderStage.pipeline(hasMasks: hasMaskStages) }

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
