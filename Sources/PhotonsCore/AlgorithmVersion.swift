import Foundation

/// P1f (079 §2.7.1) — **the version of a stage's arithmetic**, per stage, inside the cache key.
///
/// Why this shape rather than one global `graphVersion`:
///
///   · `graphVersion` was a hand-maintained literal (`ThumbRecipe.graphVersion = "graph-v1"`) whose
///     whole contract was "bump me when a stage's maths changes" — the kind of invariant that fails
///     silently. It did. S2's contrast was replaced (`v = sign(v)·0.18·(|v|/0.18)^γ`, a shear with no
///     upper asymptote → the bounded log2-EV bend of `S2Contrast`), S1's blacks became 073C's hybrid
///     EV-then-level travel, S1.6's contrast started calling the same `tone_contrast` — and
///     `graph-v1` stayed put. Every thumbnail carrying a contrast value was then **stale but
///     servable**: the grid drew the old curve's pixels, and nothing anywhere said so.
///   · The render key chain is a **hash chain** (`RenderKeyChain.links`: each link is
///     `H(digest(previous) | own material)`), so a token placed in a stage's *own* material reaches
///     that stage and every key below it — and nothing above it. That is exactly the scoping the
///     maths has: a contrast change must miss S2, S3 … S4 and must **not** evict S0/S1 (33 MB of
///     linear pass) or the mask atlas. It is the same "the key names what the stage reads" discipline
///     `EditModel.keyMaterial` already follows for parameters.
///   · The file cache still needs one scalar — its key is
///     `sha256(canonical(develop_json) | decoderRecipe | graphVersion)`, a fact about a *document*,
///     not about a stage — so `ThumbRecipe.graphVersion` is now **derived** from these numbers
///     (`fingerprint`) instead of typed by hand. Bumping a stage can no longer forget the thumbnails,
///     and there is no second literal to keep in step.
///
/// ## The rule for a bump
///
/// Start at `1` when a stage is introduced. Bump a stage's number when the *pixels* its card produces
/// change for the **same parameters** — a replaced curve, a different endpoint, a reordered pass.
/// Do **not** bump for a parameter that merely moved into another stage's material (`keyMaterial`
/// already covers that), and do not bump for a spelling change that moves no pixel (that is
/// `EditModel.processVersion`'s job).
///
/// A bump is a one-way fact about the past: it invalidates the stage's in-memory entry and every
/// downstream key (correct — their input pixels changed) and, through `ThumbRecipe.graphVersion`,
/// every `graph` thumbnail on disk (also correct: a thumbnail contains every stage). It must never be
/// "fixed" by adding the version to the document, which would make an upgrade look like an edit
/// (079 §2.7.1).
public enum StageAlgorithmVersion {

    // One number per stage, in `RenderStage.order`. 2 = "the maths changed after graph-v1 was set".

    /// Unchanged since graph-v1 (crop/rotate/flip/lateral CA arithmetic).
    public static let geometry = 1
    /// **2** — 073C: `blacks`/`whites` are no longer an affine level alone; the blacks travel is an EV
    /// toe for its first half and an EV + black-point *level* move above |50| (`s1_scene_linear.metal`).
    public static let sceneLinear = 2
    /// **2** — 079 A4: a shape's `feather` is a **short-edge percentage spent outside the rim**
    /// (interior 1.0, quadratic falloff beyond), not a fraction of the shape spent inside it. Same
    /// parameters, different pixels — every document with `feather > 0` moves; `feather == 0` keeps the
    /// old expression verbatim and does not.
    public static let maskAtlas = 2
    /// **3** — 079 A3: a mask's `temperature`/`tint` are `WhiteBalanceSolver.gain` (linear light) in
    /// the global coordinate instead of `LightGroup.whiteBalanceGains` (display-encoded, 2.2× weak).
    public static let localApply = 3
    /// Unchanged (030's HDR curve).
    public static let curve = 1
    /// **2** — 0107: contrast became a displacement in log2 EV over a held core with a bounded shoulder
    /// and a toe shift (no upper asymptote, no 4× slope); 074 R2 moved the region lifts to EV windows.
    public static let toneMap = 2
    /// Unchanged (vibrance/saturation only, since 076).
    public static let color = 1
    /// Unchanged (S3.4's eight-band grey mix).
    public static let bw = 1
    /// Unchanged (S3.5's hue/saturation in the display-referred domain).
    public static let localColor = 1
    /// Unchanged (S3.6's OKLCh bands).
    public static let hsl = 1
    /// **1** — S3.8's first arithmetic (2026-10-28, P0 色彩分级): three luminance windows ×
    /// (hue offset, chroma scale, light gain). Start at 1 when a stage is introduced.
    public static let grade = 1

    /// **1** — S3.9's first arithmetic (2026-10-28, P0-6): 纹理 / 清晰度 / 去雾. Starts at 1.
    public static let detailFX = 1
    /// Unchanged.
    public static let vignette = 1
    /// Unchanged.
    public static let grain = 1
    /// Unchanged (the OETF/encode).
    public static let display = 1

    /// The version of one stage. Every case is answered explicitly: a new stage cannot be added
    /// without someone writing down which generation of its arithmetic this is.
    public static func version(of stage: RenderStage) -> Int {
        switch stage {
        case .geometry: return geometry
        case .sceneLinear: return sceneLinear
        case .maskAtlas: return maskAtlas
        case .localApply: return localApply
        case .curve: return curve
        case .toneMap: return toneMap
        case .color: return color
        case .bw: return bw
        case .localColor: return localColor
        case .hsl: return hsl
        case .grade: return grade
        case .detailFX: return detailFX
        case .vignette: return vignette
        case .grain: return grain
        case .display: return display
        }
    }

    /// What goes into a stage's key material: `;alg=2`, appended by `EditModel.keyMaterial`.
    ///
    /// Unconditional, including for `1`. The alternative — appending only above 1, the `asp`/`car`/
    /// `boff` discipline — would keep a document's key byte-identical until the day its stage is
    /// bumped, but it would also make "the key names its arithmetic generation" a property of *some*
    /// stages: a log line, a cache directory or a support report could not answer "which golden wrote
    /// this" for half the pipeline. The one-time re-recording of the key vectors is the cost, and it
    /// is paid once, here, with the reason written down (`MaskTests`, `WindowTests`).
    public static func token(_ stage: RenderStage) -> String {
        ";alg=\(version(of: stage))"
    }

    /// The canonical text of every version, in execution order — the input to `fingerprint`.
    public static var material: String {
        RenderStage.order.map { "\($0.rawValue)=\(version(of: $0))" }.joined(separator: ";")
    }

    /// 16 hex chars of `sha256(material)`: the one scalar the on-disk cache needs
    /// (`ThumbRecipe.graphVersion`, and the `g-…` namespace a `graph` thumbnail lives in).
    ///
    /// Derived, so there is no literal to forget. 16 chars, not 64, because it is also a directory
    /// name a human may read in `ls`.
    public static var fingerprint: String {
        String(KeyBuilder.digest(of: material).prefix(16))
    }

    /// The same fingerprint, spelled for a log line or a cache key:
    /// `graph-v2@<fingerprint>`. `v2` is the *scheme* (versioned-by-derivation) — a reader who sees
    /// `graph-v1` in an old cache directory knows the files predate this mechanism.
    public static var graphVersion: String { "graph-v2@\(fingerprint)" }
}
