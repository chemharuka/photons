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

    /// **2** — 183: S0's map is no longer `crop ∘ rotate ∘ flip` alone; a document may carry a 3×3
    /// keystone (`geometry.perspectiveVertical/Horizontal`) that the same pass applies to the sample
    /// coordinate, and the canvas it allocates is the inscribed rectangle of the warped quad. A
    /// document at 0/0 renders **byte-identical** pixels (the kernel's warp block is skipped and the
    /// canvas is unchanged), but the stage's arithmetic now includes the warp, and the same stored
    /// numbers would have produced different pixels on a build that did not — so the generation moves.
    /// Unchanged since graph-v1 (crop/rotate/flip/lateral CA arithmetic, before the keystone).
    public static let geometry = 2
    /// **8** — 179: 原色校准 joined S1 (`CalibrationGroup`). The stage's exit now multiplies by a
    /// 3×3 primaries matrix and applies the shadows' green↔magenta tint, so a document whose seven
    /// calibration numbers are **not** all 0 renders pixels it could not render before. A document
    /// with all seven at 0 takes the calibration-free instantiation and is **bit-identical to 7**
    /// (and its key material does not even carry a `;cal` token) — the bump is the statement that the
    /// stage's arithmetic grew a term, not that every frame moved.
    /// **7** — 129: S1's instantiation switch for the blacks level now sits where the level term is
    /// zero (`|blacks| > 20`, `smoothstep(0.2, 1, |blacks|/100)`), not at 073C's original 50. The
    /// kernel arithmetic is unchanged; documents with **20 < |blacks| ≤ 50** now take the hybrid
    /// instantiation they should have taken since `a449462`, so their pixels move (S1 output: up to
    /// 0.17 code at blacks 30, 1.19 at 45, 1.70 at 49.9; true black +0.82 from the hybrid toe's
    /// floor). `|blacks| ≤ 20` and every other document are byte-identical to 6, and 50 → 50.01 no
    /// longer steps 3.13 codes.
    /// **6** — 147: `whites`' EV window is read on the unexposed light (`L − log2(exposureGain)`)
    /// instead of the exposed one, so the same `whites` number is the same scene operation at every
    /// exposure. A document with `whites != 0` and `exposure != 0` now renders different pixels;
    /// `exposure == 0` (g = 1) and `whites == 0` are bit-identical to 5.
    /// **5** — 143: white balance is S1's own scene-linear gain (`WhiteBalanceEstimate`) instead of a
    /// decoder input. A document with an explicit Kelvin/tint now applies a gain in this pass, so
    /// the same stored pair produces different pixels; an as-shot document (`nil`) is still the
    /// identity and keeps the pre-143 bytes. The golden images are re-recorded on main.
    /// **4** — 138: `whites`' EV weight is monotonically non-decreasing in `L` (`smoothstep(−2, +2, L)`,
    /// `W_EV` 1.2) instead of decaying above white. A document with `whites != 0` and any pixel near or
    /// above display white now renders different pixels for the same stored number; a document with
    /// `whites == 0` is untouched (the identity is still `exp2(0) · 1`).
    /// **3** — 127: `whites`' level is multiplicative and global (`1/(1−0.20·Δw·|Δw|)`), so the
    /// shadows scale with the white end; 073C's blacks travel and 073B's EV shoulder are unchanged.
    /// **2** — 073C: `blacks`/`whites` are no longer an affine level alone; the blacks travel is an EV
    /// toe for its first half and an EV + black-point *level* move above |50| (`s1_scene_linear.metal`).
    public static let sceneLinear = 8
    /// **3** — 147: a mask's `luminanceRange`/`colorRange` predicate reads the S1 sample divided by
    /// the global exposure gain, so the selection no longer drifts with the EV slider. A document
    /// with a picture-reading mask and `exposure != 0` now renders different pixels; `exposure == 0`
    /// (g = 1) is bit-identical to 2.
    /// **2** — 079 A4: a shape's `feather` is a **short-edge percentage spent outside the rim**
    /// (interior 1.0, quadratic falloff beyond), not a fraction of the shape spent inside it. Same
    /// parameters, different pixels — every document with `feather > 0` moves; `feather == 0` keeps the
    /// old expression verbatim and does not.
    ///
    /// **5** — 167: the luminance window is read on the **whole HDR axis**, `0…cbrt(16)` (+4 EV),
    /// instead of `OKLab L of clamp(linearRGB, 0, 1)`. A document with a `luminanceRange` mask now
    /// selects pixels above display white that the old predicate folded to `L = 1` (and, with the
    /// default `high = hdrMax`, stops discarding them), so the same stored numbers render different
    /// pixels; every other shape is byte-identical.
    ///
    /// **v1 documents are NOT migrated** (user, 2026-10-30 20:10): the decoder keeps the five stored
    /// numbers verbatim and only stamps `v = 2`, so an old document keeps `high = 1.0` and its SDR
    /// selection is bit-identical. The one visible difference is above display white: the old kernel
    /// folded those pixels to `L = 1` and gave them `alpha = 0.5` (an artefact of the clamp, not an
    /// intent), while the new axis reads their real `L` and `high = 1.0` closes the window there
    /// (`alpha = 0`). Users who want the highlights back drag the handle up. See
    /// `LuminanceRangeShape` for why `default` and the v1 decode fallback are separate constants.
    public static let maskAtlas = 5
    /// **4** — 159: contrast left S1.6 for S2.5 (after the tone map). A mask that carries a contrast
    /// value no longer runs the scene-linear `tone_contrast` here; the same stored number is applied
    /// by the display-domain residual operator, so the pixels inside such a mask change. A mask whose
    /// contrast is 0 is bit-identical to 3 (the arithmetic it used to run was the identity).
    /// **3** — 079 A3: a mask's `temperature`/`tint` are `WhiteBalanceSolver.gain` (linear light) in
    /// the global coordinate instead of `LightGroup.whiteBalanceGains` (display-encoded, 2.2× weak).
    public static let localApply = 4
    /// **2** — 137: a curve may descend as a whole (film-negative inversion). A document whose curve
    /// was already non-decreasing keeps its table byte for byte, but a document holding an inverted
    /// curve used to render the identity (buildOne's fold fallback) and now renders the inverted
    /// table, so the same stored points produce different pixels. The stage's generation moves;
    /// the positive-curve pixels do not.
    public static let curve = 2
    /// **2** — 159: contrast moved out of the scene-linear chain into S2.5 (after the tone map and
    /// before S3), where the multiscale gain is built from the decomposition's **residuals** on the
    /// display values. Same stored number, different pixels: the level anchor that made 142's
    /// `exposure × contrast` non-commutative is gone, and the retuned display-domain constants
    /// (`MC_W_M/W_F`, gate, ε) change the local response. `contrast == 0` never reaches the stage.
    /// **1** — S1.8's first arithmetic (098): contrast as a multiscale guided-filter decomposition of
    /// `Y` in the scene-linear domain, with three fixed band weights and a fixed pivot. Starts at 1.
    public static let contrast = 2
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
    /// **3** — 173: the luma is read with the working primaries' weights
    /// (`ColorPrimaries.working.luminanceWeights` / `kWorkingLumaWeights` in `primaries.metal`)
    /// instead of a hard-coded Rec.709 `0.2126/0.7152/0.0722`. The encoded triple is the same, so
    /// every pixel's `Y`, `U` and `V` move (Rec.2020 weights on sRGB codes are off by up to
    /// **+23.57 %** on saturated red), and a stored `sampleY` no longer lands on the same pixel: the
    /// same window can now admit a different neighbourhood. The Y-first box filter added here is a
    /// pure reordering and changes no pixel.
    /// **2** — 158: the window is a Rec.709 full-range **YUV box** (`d1 = 0.06`, `d2 = d3 = 0.10`,
    /// half-radius soft shoulder) with an explicit pale-colour floor, and a document may carry up to
    /// eight swatches applied in order. Same stored hue-window parameters now select different pixels,
    /// so the stage generation moves. A sample-only document is still no stage (bit-identical).
    /// **1** — S3.6b's first arithmetic (140, 点颜色): one sampled OKLCh hue window × the S3.6
    /// chroma gate, three adjustments scaled by the window weight.
    public static let pointColour = 3
    /// **1** — S3.8's first arithmetic (2026-10-28, P0 色彩分级): three luminance windows ×
    /// (hue offset, chroma scale, light gain). Start at 1 when a stage is introduced.
    public static let grade = 1

    /// **4** — 181: a mask can carry 局部纹理 / 局部锐化, applied in the same apply pass from the same
    /// guided band. A document whose masks carry neither is bit-identical to 3 (the loop does not
    /// exist: `maskCount == 0`), but the same stored mask numbers now produce pixels they could not
    /// produce before, so the generation moves.
    /// **3** — 171: the two denoises are no longer "a guided-base mean" and "a chroma scale". They
    /// are **one joint bilateral grid** (`s3_9_denoise.metal`: splat → 5-tap blur → trilinear
    /// slice), built from a measured noise estimate, and the chroma control averages OKLab `a`/`b`
    /// instead of multiplying `C`. Same stored numbers, different pixels — a 高饱和色块 keeps
    /// ~100 % of its chroma where 2 kept 10 % — so the generation moves. The 纹理/清晰度 bands are
    /// untouched (`tests` pin their pre-164 bytes); only the two denoise branches changed.
    ///
    /// **2** — 164: the 细节 card's two denoises (display-referred luminance guided-filter
    /// mix and OKLab chroma suppression) joined S3.9's apply pass. Both branches are skipped at 0, so
    /// a document with the two new fields untouched is byte-identical to 1; a document that sets one
    /// of them renders pixels it could not render before.
    ///
    /// **1** — S3.9's first arithmetic (2026-10-28, P0-6): 纹理 / 清晰度 / 去雾. Starts at 1.
    public static let detailFX = 4
    /// **2** — 117: 去雾 left S3.9 for S1.9 (`s1_9_dehaze.metal`). The domain changed from
    /// display-referred codes with `A = 1` to scene-linear light with a measured airlight, so every
    /// document with `effects.dehaze != 0` changes pixels even though its stored number did not.
    /// **3** — 130: the recovery is hue-preserving (He's inversion on Rec.2020 luminance, one common
    /// gain on the three channels) and fades out above the veil's reach (`w = 1 − smoothstep(A, 2A, L)`),
    /// so a `dehaze > 0` document no longer rotates blue highlights toward blue. `dehaze < 0` is
    /// unchanged; `dehaze == 0` never reaches the stage.
    /// **4** — 135: the airlight is capped at `κ·p99(L)` (`κ = 0.95`, the percentile clipped at
    /// white, the cap engaging only when `A` is materially above it). A +2 EV frame whose brightest
    /// block minimum sat above almost every pixel used to recover to negative light at
    /// `amount = 100` and wrote black; the same stored `dehaze` value now produces different
    /// (non-black) pixels, so the stage's generation moves.
    /// **5** — 141: `A`, `t` and the 135 percentile are estimated on the **unexposed** light
    /// (`I / 2^EV`, with the recovered light multiplied back), so dehaze commutes with the exposure
    /// slider. A document with both `exposure != 0` and `effects.dehaze != 0` now renders different
    /// pixels for the same stored numbers; `exposure == 0` (g = 1) is bit-identical to 4.
    ///
    /// **7** — 2026-10-31: `t`'s spatial support is no longer the block minimum's bilinear upsample
    /// but a **guided-filter veil** (`a·l + b` over the block's mean luma, ε = 4e-4·A², boxed twice)
    /// combined with a **per-pixel floor** — `t = max(tSmooth, tPixel)` plus a `knee = 0.15` lift
    /// where the two agree. A block minimum steps by an order of magnitude across a skyline and only
    /// ramps over one or two blocks, so `J` over-shot on the sky side and under-shot (to black) on the
    /// dark side of every high-contrast edge; on the reference frame the measured rim fell from the
    /// two-digit percentage to under 3 % of the step. **Every** document with `effects.dehaze > 0`
    /// renders different pixels for the same stored number; `dehaze < 0` (which never reads `t`) and
    /// `dehaze == 0` (no stage) are bit-identical to 6.
    ///
    /// **6** — 120b: the depth-assisted distribution (`effects.dehazeDepth`, `depthStrength`). The
    /// stage now reads the depth map and modulates `A`/`t` per pixel; `depthStrength == 0` (or no
    /// map) takes the pre-120b branch verbatim and is byte-identical, so the bump changes pixels only
    /// for documents that actually ask for the assist. **175 deleted the field and the p1/p99 window**
    /// — generations 7 and 8 never read them, so the number stays where 8 put it and no pixel moves.
    /// **8** — 2026-10-31: 130's fog participation became **symmetric about the airlight**. `w` used to
    /// be `1 − smoothstep(A, 2A, L)` — full participation at or below `A` — and below `A` the veil's
    /// whole evidence is `A − L`, which the recovery multiplies by `1/t`. At the sky `t ≈ 0.12`, so the
    /// 3 % by which the airlight estimate sits above the sky came out as a 20 % darkening. The
    /// correction now also fades out within the airlight's own resolution (`2σ … k·2σ` of `A`,
    /// `σ = 2 %·A` — the guided filter's ε, one number with two readers), i.e. where the evidence is
    /// smaller than the measurement's error bar. Every document with `effects.dehaze > 0` renders
    /// different pixels for the same stored number; `dehaze < 0` and `dehaze == 0` are bit-identical
    /// to 7.
    public static let dehaze = 8
    /// **1** — S1.9's first arithmetic (2026-10-28, 078 P0-1): clone = the source disk, heal = the
    /// source disk + the boundary plane (mean and first harmonic, the Poisson integral truncated at
    /// n = 1). Starts at 1; a different boundary model — a real solve, a harmonic basis, a
    /// content-aware source search — is what bumps this, because it changes the pixels of the same
    /// document without changing a stored number.
    public static let heal = 1
    /// **2** — 191: the radius, the mask knee and the block window are **image** pixels converted to
    /// the render's canvas (`σ_canvas = radius·S`, knee `0.01/S…0.04/S`, block `round(4·S)`) instead of
    /// being read as canvas pixels. Same stored numbers, different pixels on every render whose scale
    /// is not 1 — a 4 MP fit preview (`S ≈ 0.293`) is now the same physical sharpen as 1:1 instead of
    /// 3.45× stronger — and the **cache is the reason this moves**: a 185-era cached frame at a
    /// non-1:1 rung holds the old σ and would be served as if it were the new one. A 1:1 whole-picture
    /// render (S = 1) is value-identical to 1, so the golden images do not move.
    /// **1** — S3.10's first arithmetic (185, 自研锐化): an unsharp mask on the display-referred pixels
    /// with a two-scale split (细节 weights the < σ/2 px band), a gradient-of-the-blur edge mask
    /// (蒙版) and the block-range limiter that bounds the halo. Start at 1 when a stage is introduced;
    /// the bump rule is the one every comment above spells out (the same stored numbers must produce
    /// different pixels to move this number).
    public static let sharpen = 2
    /// **3** — 134: the radius is normalised to half the **diagonal** (the corner is 1.0 at every
    /// aspect ratio), the contour is always circular (the `roundness` field is gone), and `midpoint`
    /// now spans centre → corner (`inner = mid/100`, was `mix(0.25, 1.05, …)` measured in half the
    /// short edge). Every document with `vignetteAmount != 0` changes pixels.
    ///
    /// **2** — 116: the vignette moved out of S3 into the end of the linear chain, so the same stored
    /// numbers now multiply **light** instead of tone-mapped codes.
    public static let vignette = 3
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
        case .pointColour: return pointColour
        case .grade: return grade
        case .detailFX: return detailFX
        case .sharpen: return sharpen
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
