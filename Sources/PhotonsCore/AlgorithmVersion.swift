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
    /// **3** — 127: `whites`' level is multiplicative and global (`1/(1−0.20·Δw·|Δw|)`), so the
    /// shadows scale with the white end; 073C's blacks travel and 073B's EV shoulder are unchanged.
    /// **2** — 073C: `blacks`/`whites` are no longer an affine level alone; the blacks travel is an EV
    /// toe for its first half and an EV + black-point *level* move above |50| (`s1_scene_linear.metal`).
    public static let sceneLinear = 3
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
    /// **1** — S1.8's first arithmetic (098): contrast as a multiscale guided-filter decomposition of
    /// `Y` in the scene-linear domain, with three fixed band weights and a fixed pivot. Starts at 1.
    public static let contrast = 1
    /// **5** — 124: 高光 covers the whole HDR range. The high→white closure moved from
    /// `smoothstep(−1.2, 0.0, L)` to `smoothstep(+4.0, +6.0, L)`, so a document with
    /// `highlights != 0` now moves every pixel above −0.9 EV, including values above display white
    /// that the old window passed through untouched. Same stored numbers, different pixels.
    ///
    /// **4** — 098: S2 no longer contains contrast (it moved to S1.8), so its pixels for the same
    /// stored numbers changed even though the region-lift arithmetic did not.
    ///
    /// **3** — 085: the two-window shadows/highlights lift became the three-window
    /// shadow/mid/high chain with a gated EV travel (`S2Regions`); the pixels of a document with a
    /// non-zero region slider change even though its stored numbers do not.
    ///
    /// **2** — 0107: contrast became a displacement in log2 EV over a held core with a bounded shoulder
    /// and a toe shift (no upper asymptote, no 4× slope); 074 R2 moved the region lifts to EV windows.
    public static let toneMap = 5
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
    /// **2** — 117: 去雾 left S3.9 for S1.9 (`s1_9_dehaze.metal`). The domain changed from
    /// display-referred codes with `A = 1` to scene-linear light with a measured airlight, so every
    /// document with `effects.dehaze != 0` changes pixels even though its stored number did not.
    /// **3** — 130: the recovery is hue-preserving (He's inversion on Rec.2020 luminance, one common
    /// gain on the three channels) and fades out above the veil's reach (`w = 1 − smoothstep(A, 2A, L)`),
    /// so a `dehaze > 0` document no longer rotates blue highlights toward blue. `dehaze < 0` is
    /// unchanged; `dehaze == 0` never reaches the stage.
    public static let dehaze = 3
    /// **1** — S1.9's first arithmetic (2026-10-28, 078 P0-1): clone = the source disk, heal = the
    /// source disk + the boundary plane (mean and first harmonic, the Poisson integral truncated at
    /// n = 1). Starts at 1; a different boundary model — a real solve, a harmonic basis, a
    /// content-aware source search — is what bumps this, because it changes the pixels of the same
    /// document without changing a stored number.
    public static let heal = 1
    /// **2** — 116: the vignette moved out of S3 into the end of the linear chain, so the same stored
    /// numbers now multiply **light** instead of tone-mapped codes. Every document with
    /// `vignetteAmount != 0` changes pixels; the arithmetic inside the kernel did not change.
    public static let vignette = 2
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
        case .heal: return heal
        case .curve: return curve
        case .contrast: return contrast
        case .toneMap: return toneMap
        case .color: return color
        case .bw: return bw
        case .localColor: return localColor
        case .hsl: return hsl
        case .grade: return grade
        case .detailFX: return detailFX
        case .dehaze: return dehaze
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
