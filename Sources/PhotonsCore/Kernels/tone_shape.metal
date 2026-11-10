#include <metal_stdlib>
using namespace metal;

// **The tone controls' parameter → effect map, in one place** (派单 079 §2.1.2).
//
// Why this file exists: the same slider used to mean two different things depending on whether it was
// dragged globally or inside a mask. `s1_6_local` still carried 019's arithmetic — an affine ±0.15
// level, a linear-light power for contrast, and the linear-luma windows `1 − smoothstep(0, 0.5, lum)` /
// `smoothstep(0.5, 1, lum)` — while S1 had moved the end points to EV knees (073B/073C) and S2 had
// moved the region lifts to EV windows (074 R2). Measured consequence (079 §2.1.2): the same
// `shadows = +100` lifted **the whole picture** inside a mask (70 % of the lift landed on the
// mid-tones) and left it alone outside it. darktable cannot have that bug because a module runs one
// `process()` whether it is masked or not and the mask only decides alpha
// (`blend.c:833-859`) — so the fix is not "tune the local numbers", it is **one body per control**.
//
// Who reads what:
//
//   S1    s1_scene_linear   `s1_end_points<kHybrid>`                      blacks / whites
//   S2    s2_tone_map       `band_weights` + `high_shoulder_ev`            shadows / mid / high
//   S1.6  s1_6_local        all three, applied between S1 and S2          all four
//
// The order is the *global* order, and the local pass keeps it: gains (S1) → end points (S1) →
// contrast (S2) → region lifts (S2). Nothing here allocates, samples, or branches on a mask: these are
// pure functions of (pixel, slider values), which is what lets a masked and an unmasked frame agree
// pixel for pixel instead of "within a tolerance".
//
// This file is a **sibling of `primaries.metal`, not a client of it**: the including kernel must
// `#include "primaries.metal"` first (a kernel may not include the same header twice).
//
// **306b**: S2's global 阴影/中间调/高光 uses the normalized Gaussian `band_weights` below plus the
// difference shoulder `high_shoulder_ev`. The mask pass (`s1_6_local`) still reads 074's two-window
// `region_weights` / `region_gain` and 085's `region_weights3` / `region_gain3`; that is deliberately
// unsynchronised until the local pass is unified (a later task), so all bodies stay here.

// ── 074 R2 — the two region windows, in EV relative to display white ──────────────────────────────
//
// Shadows: full weight at and below −5.9 EV, smoothly to 0 at −3.9 EV. Highlights: 0 at and below
// −3.2 EV, full weight at −1.2 EV and above. Both 2 EV wide, placed from the measured percentiles of
// the four reference frames (p50 ∈ [−4.36, −3.28], p5 ∈ [−6.69, −6.22], p95 ∈ [−2.48, −1.45]) — the
// derivation, the monotonicity budget (min slope 0.400 at ±100) and the two failures of the old
// linear-luma windows are in `s2_tone_map.metal`'s header, which is where they were measured.
constant float SHADOW_LO_EV = -5.9;
constant float SHADOW_HI_EV = -3.9;
constant float HIGHLIGHT_LO_EV = -3.2;
constant float HIGHLIGHT_HI_EV = -1.2;

/// The two region weights of a pixel: `(shadow, highlight)`, each 0…1.
///
/// The coordinate is `L = log2(luma)` — EV relative to display white, the histogram card's own HDR
/// axis — so a window's *width* is fixed in stops and does not change what counts as "shadow" when the
/// exposure is multiplied. A pixel at or below zero reads a very negative L, which is the shadow end:
/// exactly right for a sub-black sample a lift has already pulled above zero.
static inline float2 region_weights(float3 v) {
    float lum = max(dot(max(v, 0.0), kWorkingLumaWeights), 1e-9);
    float L = log2(lum);
    return float2(1.0 - smoothstep(SHADOW_LO_EV, SHADOW_HI_EV, L),
                  smoothstep(HIGHLIGHT_LO_EV, HIGHLIGHT_HI_EV, L));
}

/// The multiplicative gain of the two region lifts, given the weights above.
///
/// LR convention (派单 008 A) for both: a positive value lifts that region, a negative value pulls it
/// down, so `highlights +` brightens the highlight zone (less recovery). ±0.8 EV at full travel.
static inline float region_gain(float2 w, float shadows, float highlights) {
    return exp2(shadows / 100.0 * 0.8 * w.x) * exp2(highlights / 100.0 * 0.8 * w.y);
}

// ── 306 — the normalized Gaussian bands (S2's global 阴影/中间调/高光) ─────────────────────────────
//
// The 085 smoothstep windows below were disjoint: a slider did not move its neighbours and the local
// slope on a seam fell to 0.30 (`mid = ±100`). **306** replaces S2's use of them with three
// overlapping, normalized Gaussians on the same `L = log2(luma)` axis:
//
//     c = (−6.8, −3.6, +0.2) EV,  σ = 1.9 EV
//     b_i = exp(−((L − c_i)/σ)² / 2)
//     w_i = b_i / Σ_j b_j          Σ_i w_i ≡ 1
//
// `weights` uses `L` directly: above white the two low weights decay to 0 and `w_high → 1`, so the
// band term approaches `d_high`. **306b** puts all three bands in the term (高光 drives its neighbours
// too); 299's shoulder supplies only the *difference* needed to keep `+4 EV → +1 EV`. The CPU mirror
// is `S2Regions.weights` / `bandEV`.
constant float BAND_SHADOW_EV = -6.8;
constant float BAND_MID_EV = -3.6;
constant float BAND_HIGH_EV = 0.2;
constant float BAND_SIGMA_EV = 1.9;

/// The three normalized Gaussian weights of a pixel, each 0…1 and summing to 1.
///
/// S2 uses all three: 306b feeds `d_high` through the band term as well, so the high slider drags
/// 阴影 and 中间调 exactly like the other two do. 299's `high_shoulder_ev` is added on top as the
/// remaining HDR-tail difference.
static inline float3 band_weights(float3 v) {
    float lum = max(dot(max(v, 0.0), kWorkingLumaWeights), 1e-9);
    float L = log2(lum);
    float bs = exp(-pow((L - BAND_SHADOW_EV) / BAND_SIGMA_EV, 2.0) * 0.5);
    float bm = exp(-pow((L - BAND_MID_EV) / BAND_SIGMA_EV, 2.0) * 0.5);
    float bh = exp(-pow((L - BAND_HIGH_EV) / BAND_SIGMA_EV, 2.0) * 0.5);
    float sum = bs + bm + bh;
    return float3(bs / sum, bm / sum, bh / sum);
}

// ── 085 — the three region windows (now the **mask path only**; S2 uses the 306 Gaussians) ────────
//
// Two complementary smoothstep chains, all on `L = log2(luma)` in EV relative to display white:
//
//     a = smoothstep(−5.4, −3.9, L)   shadow → mid
//     b = smoothstep(−2.4, −0.9, L)   mid → high
//     c = smoothstep(+4.0, +6.0, L)   high → white (closes the top, **outside** the HDR range)
//
//     shadow = 1 − a,  mid = a(1 − b),  high = b(1 − c)
//
// `a` reaches 1 before `b` starts, so there is no band where all three are 0 — the defect of the old
// −3.9…−3.2 EV gap, which is exactly where the reference frames' medians sat.
//
// **124 (2026-10-29) — 高光 covers the whole HDR range.** The closure used to be
// `smoothstep(−1.2, 0.0, L)`, so `high` was exactly 0 at and above display white and a pixel above
// 1.0 was untouched by 高光 (`c = 1` ⇒ gain 1). The owner measured that as 「高光对 +1 以上的像素
// 无效」 and asked for the slider to reach the whole HDR range. `c` now starts closing at +4 EV and
// is 1 at +6 EV, i.e. `c = 0` through the default 2.3 EV headroom and through 114's possible 4 EV
// preference block, so `high = b = 1` from −0.9 EV all the way up. 白色 keeps its own narrow band at
// the very top instead of eating the HDR range.
//
// The CPU owns the travel and its monotonicity gate (`S2Regions`); these functions take **EV**.
// **306b**: this shape is the **mask path only**. S2's global chain uses `band_weights` for all three
// bands and adds `high_shoulder_ev` (below) for the HDR-tail difference.
constant float REGION3_SHADOW_LO_EV = -5.4;
constant float REGION3_SHADOW_HI_EV = -3.9;
constant float REGION3_MID_LO_EV = -2.4;
constant float REGION3_MID_HI_EV = -0.9;
constant float REGION3_HIGH_LO_EV = 4.0;
constant float REGION3_HIGH_HI_EV = 6.0;

/// `(shadow, mid, high)` for one pixel, each 0…1. **Mask path only since 306** — S2's global chain
/// uses `band_weights` above.
///
/// The third component stays because `s1_6_local` (074's mask path) still reads
/// `region_gain3(region_weights3(v), …)` with the EV travel, and its two-window family is
/// intentionally unchanged. S2's global chain now uses all three of `band_weights`, so 高光 drives its
/// neighbours there; the mask's 高光 keeps 074's displacement semantics.
static inline float3 region_weights3(float3 v) {
    float lum = max(dot(max(v, 0.0), kWorkingLumaWeights), 1e-9);
    float L = log2(lum);
    float a = smoothstep(REGION3_SHADOW_LO_EV, REGION3_SHADOW_HI_EV, L);
    float b = smoothstep(REGION3_MID_LO_EV, REGION3_MID_HI_EV, L);
    float c = smoothstep(REGION3_HIGH_LO_EV, REGION3_HIGH_HI_EV, L);
    return float3(1.0 - a, a * (1.0 - b), b * (1.0 - c));
}

/// The one gain of the three lifts: `exp2(shadow·Δs + mid·Δm + high·Δh)`, `dEV` already in EV.
///
/// Still used **verbatim** by `s1_6_local` (the mask path). S2 uses only `.xy` of the weights and
/// adds `high_shoulder_ev` instead; see the 299 note on `region_weights3`.
static inline float region_gain3(float3 w, float3 dEV) {
    return exp2(dot(w, dEV));
}

// ── 299 / 306b — 高光: the band plus a C¹ difference shoulder above display white ───────────────
//
// The slider is a **slope**, not an EV displacement. `k` is `S2Regions.highSlope` (1 + c·h, c solved
// so the tail promise holds with the high band inside the convex combination), and the log2-domain
// output above white is
//
//     y = L + Σ w_i(L)·d_i + S(L)
//     S(L) = 0                                  L ≤ 0
//     S(L) = (k−1)(L − w(1 − e^{−L/w}))         L > 0,  w = 0.25 EV
//
// Above white the band tends to `d_high`; `S` supplies the remainder, so at h = −100 a +4 EV sample
// still lands at +1.00 EV and the +8 EV tail is +2.681 EV (recomputed with the new k). `L ≤ 0` and
// k = 1 make `S` exactly 0. The SDR side is no longer the identity at every 高光 position: `w_h(0)`
// is 0.856, so h = −100 moves L = 0 by −0.71 EV. That is the 306b semantic (高光 must also drive its
// neighbours); the pure-HDR behaviour is now only the part above white.
constant float HIGH_KNEE_W_EV = 0.25;

static inline float high_shoulder_ev(float L, float k) {
    if (L <= 0.0) { return 0.0; }
    return (k - 1.0) * (L - HIGH_KNEE_W_EV * (1.0 - exp(-L / HIGH_KNEE_W_EV)));
}

// ── 073B / 073C — the end points: blacks and whites ──────────────────────────────────────────────
//
// The knee ends, in EV relative to display white, and the travel at the very bottom. −11.2 EV is far
// below anything the decoder produces as picture (the frames' p1 sits at −8…−15 EV); −4.2 EV (code
// 0.29) is below every measured p30, so the mid-tones are outside the window.
constant float B_EV = 3.0;
constant float B_LO_EV = -12.0;
constant float B_HI_EV = -1.0;

// 073C — the level half of the hybrid travel: the black point moves by up to ±B_LEV in scene-linear
// light over its own window (LEV_LO_EV … LEV_HI_EV), with a C¹ knee of LEV_KNEE at 0 on the crush side.
//
// `LEV_HI_EV = −4.4` and not `B_HI_EV = −4.2`: the level's window has to end below the *lowest p50 of
// the reference frames* (−4.36 EV, L1030408), or the level term itself would move a median and the
// "the level only works on the dark end" invariant would be a tolerance instead of a fact. B_LEV is
// pinned by the monotonicity constraint (B_LEV < 1.5/(d·ln2·2^(LEV_HI−d)) = 0.0056 for the 2.5 EV
// window below); 0.005 is sRGB code 15.6, i.e. where a print fade sits.
constant float B_LEV = 0.006;
constant float LEV_LO_EV = -6.0;
constant float LEV_HI_EV = -1.0;
constant float LEV_KNEE = 1e-3;

// 342 — the **crush side's own level**, and why it is ~10× `B_LEV` rather than 2×.
//
// The brief (2026-11-10): 「黑色的色阶调节范围扩大，现在 −100 大概只能让亮度 32/255 的变成 0，扩大到
// −100 能让亮度 64/255 变为 0」. `B_LEV` at full travel moves the black point by 0.006 linear = sRGB
// **code 17.9**, and with its window (0.73 at code 64) it lands on **code 48.3** — measured, see
// `BlacksTravelTests`. Code 64 is 0.0513 linear, so a level term that reaches it cannot also be the
// one that reaches 0.006: a *single* coefficient can only be one black point. Doubling `B_LEV` to
// 0.012 puts the black point at code 25 — still 40 codes short.
//
// So the crush side gets a **second** level with its own window and its own amplitude. Two properties
// force the shape rather than taste:
//
//   · `m₅ = smoothstep(0.5, 1, |blacks|/100)` — **exactly 0 at |blacks| ≤ 50**, and its slope is 0
//     there, so the whole first half of the travel keeps 073C's bytes (including ±25 and ±50, which
//     already run this instantiation) and the slider has no seam at 50.
//   · the window is in **linear light**, not EV, because the crush is a black-point *move*: `off(v)`
//     must fall from ~0.05 at code 64 to 0 at code 103, and a log-domain smoothstep packs that fall
//     into the region where `v` is smallest, where `d(off)/dv > 1` would fold the transfer. In linear
//     light `|d(off)/dv| ≤ 1.5·B_LEV_CRUSH/(CRUSH_HI − CRUSH_LO) = 0.78 < 1` — monotone by
//     construction, which the 0…255 ramp in `BlacksTravelTests` checks code by code.
//
// B_LEV_CRUSH = 0.060 is linear **0.060** = sRGB code 69; with the window's own weight at code 64
// (0.82) the term lands 0.0493 there, and 0.0493 + `B_LEV`'s 0.0044 > 0.0513 — code 64 goes to 0 and
// code 65 stays above it. The window (0.020 … 0.135 = sRGB code 39 … 103) is what keeps 18 % grey
// **bit-identical**: `wl₂(0.18) == 0`, so the mid-tones move by nothing at all.
constant float B_LEV_CRUSH = 0.060;
constant float CRUSH_LO = 0.020;
constant float CRUSH_HI = 0.135;

// Whites: an EV move that rises monotonically through display white, plus a **multiplicative** level.
//
// 127: the level used to be additive and windowed (`+ W_LEV·Δw·|Δw|·ww`, W_LEV = 0.06), so at −2 EV
// and below it was exactly 0 and `whites +100` did not move p1/p5/p50 at all (measured: 7.5/26.2/89.9
// codes, unchanged). The owner's brief is a *level*: the whole range scales, shadows included. The
// additive form is what 019 was rejected for (it lifts `v = 0` into grey); a multiplier keeps `0 → 0`,
// so it can be global without fogging the blacks.
//
//     level = 1 / (1 − W_LEV · Δw · |Δw|)        Δw = whites/100 ∈ [−1, 1]
//     v *= level                                every luma, including the HDR tail
//
// W_LEV = 0.20 is the physical ceiling of this control, not a taste knob: the level can lift p1 by
// only 2…5 codes (at +100: ×1.25 in linear ≈ +2 codes at code 7.5, +4 at code 26). A shadow that has
// to be *visibly* brighter is `blacks` (its EV toe) or `exposure`; `whites` cannot be that and still
// leave a neutral black neutral.
//
// **138 — the EV weight rises with L instead of decaying above white.**
//
// 073B/127 used `ww = smoothstep(−2, 0, L)` below white and `exp(−L)` above it. Measured on
// L1030433 at +2 EV (−100, `--tone-map global`): p99.9 moved +0.0003 code (a super-white pixel did
// not come down at all) while p70–p85 moved −0.10…−0.13, and the 0.55–0.75 code bands kept only
// 0.51–0.62 of their local slope — 「90 % 被压到 70 %、高光不变」. The weight pointed at the wrong end:
// it was full at white and decayed through the HDR tail, so the shoulder took the −0.86 EV and the
// super-white pixels took almost nothing.
//
// The shape is one monotone window (`smoothstep(WW_LO_EV, WW_HI_EV, L)`): 0 at −2 EV and below, 1 at
// +2 EV and above. A pixel at display white receives `smoothstep(−2, 2, 0) · W_EV = 0.50 · 1.2 ≈
// 0.60 EV`, the same travel 073B pinned at the white point; the HDR tail receives the full 1.2 EV,
// i.e. **at least** the white point's move, which is what the owner asked for. `WW_HI_EV = +2` (not
// the brief's +1) is the measured choice: at +1 the same render put the 0.55–0.75 bands at 0.48/0.39
// of their slope, at +2 at 0.70/0.58, and p99.9 still fell 0.029 code (the brief's ≥0.020) — i.e. +2
// keeps more texture for the same super-white travel. Monotonicity: `slope = 1 + W_EV·Δw·ww′`, worst
// case `1 − 1.2 · 1.5/4 = 0.55` (the same argument as 073B's 7 EV toe), so the map cannot fold.
//
// No upper clamp is added: this is a positive multiplicative gain, so the EDR tail and the 4 EV
// histogram keep their values (079 §4). `0 → 0` is preserved by the level, not by clipping.
constant float W_EV = 1.2;
constant float W_LEV = 0.20;
constant float WW_LO_EV = -2.0;
constant float WW_HI_EV = 2.0;

// The luma the **end points** sample, and why it is written out here instead of read from
// `kWorkingLumaWeights`: 073B/073C measured and pinned their knee positions against these three
// numbers (BT.709), and S1 has not migrated yet (075 moved the colours but not this line). Using the
// working-primaries weights here would silently move every pinned `BwLevelsTests` number by the
// −13.4 %/saturated-red difference 075 documents. The local path has to agree with 073C, not with the
// primaries file, so both call this one function and both values move together when 075 gets here.
constant float3 kEndPointLumaWeights = float3(0.2126, 0.7152, 0.0722);

/// C¹ rectifier: identity at or above +LEV_KNEE, exactly 0 at or below −LEV_KNEE, quadratic in between
/// (slope 0 → 1). The crush really does reach 0 — that is the "level" half — and the corner is rounded
/// instead of stepped.
static inline float3 s1_toe(float3 x) {
    const float k = LEV_KNEE;
    float3 kx = clamp(x + k, 0.0, 2.0 * k);
    // `select(a, b, c)` is c ? b : a; a bool3 cannot be the condition of `?:` in Metal.
    return select(x, kx * kx / (4.0 * k), x < k);
}

/// Blacks and whites on one pixel, `v` scene-linear and already through the gain.
///
/// `kHybrid` is a compile-time flag (073C): the default entry contains none of the level arithmetic —
/// not "the arithmetic with a zero in it" (071's lesson: a runtime branch is still in the code, and the
/// compiler is free to reorder around it). The local pass has no per-mask instantiation to spend, so it
/// always calls `kHybrid = true`; **`m` is exactly 0 for `|k| ≤ 20`** (2026-10-29 moved the level's
/// entry there from 50), which is what makes the mask agree with S1's 073B entry in that range.
///
/// **346 does not change this file.** The slider is mapped into these units on the CPU
/// (`LightGroup.blacksKernelValue`: slider 0…30 → 0…50, 30…100 → 50…100), so `blacks` here is always
/// the kernel value: ±30 → ±50, ±100 → ±100, and S1 dispatches `kHybrid` from `|k| ≥ 50` — the curve
/// old ±50 rendered.
///
///     t = blacks/100, a = |t|, m = smoothstep(0.2, 1, a)          (2026-10-29: enters at 20, kernel units)
///     EV:    v *= exp2(B_EV · t · wb)                             wb = the 7 EV toe
///     level: v  = toe(v + B_LEV · t · m · wl)                     wl = the −6…−1 EV window
///     342:   v  = toe(v + B_LEV·t·m·wl − B_LEV_CRUSH·a·m₅·wl₂)    m₅ = smoothstep(0.5, 1, a),
///                                                                 wl₂ = 1 − smoothstep(0.02, 0.135, luma)
///            └ the crush side only (`t < 0`), and exactly 0 for `a ≤ 0.5`: `blacks = −100` moves the
///              black point to code 64 instead of the code 48 `B_LEV` alone reached. See `B_LEV_CRUSH`.
///     whites: v *= 2^(W_EV·w·ww) · 1/(1 − W_LEV·w·|w|)            ww = the EV shoulder, level global (127)
///
/// **147 — whites is read on the unexposed scale.** S1's exposure gain `g = 2^EV` is already in `v`
/// when this runs, so a naive `ww = smoothstep(WW_LO, WW_HI, L)` slid the whole white-point window up
/// by the exposure: the same `whites` number acted on different scene tones at E 0 and E +2 (the
/// audit measured p95 1.266 → 2.070). `L0 = L − log2 g` is the luma in the decoder's own light, so the
/// window is a fact about the scene and the stage commutes with exposure. The *shape* (138's
/// smoothstep, `W_EV`, the global level) is untouched, and `g == 1` makes `L0 == L` bit for bit.
///
/// `blacks` deliberately still reads `L`: 147 scopes the fix to 147's three defects, and the toe's
/// pinned numbers were measured on the exposed coordinate.
template <bool kHybrid>
static inline float3 s1_end_points(float3 v, float blacks, float whites,
                                   float exposureGain = 1.0) {
    float db = clamp(blacks, -100.0, 100.0) / 100.0;
    float dw = clamp(whites, -100.0, 100.0) / 100.0;

    // One weight per pixel, from the pixel's luminance: applying a per-channel weight would move each
    // channel by a different EV and shift hue in the lifted toe.
    float luma = dot(v, kEndPointLumaWeights);
    float L = log2(max(luma, 1e-9));
    // 147: the whites window is read on the decoder's light, not on the exposed light. `g == 1` is
    // exactly `L0 == L`, so a neutral document keeps every recorded byte.
    //
    // A non-positive `g` means "the uniform was never filled", not "the picture is 20 EV dark": the
    // naive `max(g, 1e-6)` would push `L0` up by 20 EV and open the whole whites window (measured:
    // BwLevelsTests' harness passed 0 and whites +100 became ×2.87 instead of ×1.25). Zero/negative
    // therefore falls back to the identity gain, so an unset uniform degrades to "no exposure".
    float g = exposureGain > 0.0 ? exposureGain : 1.0;
    float L0 = L - log2(g);
    // blacks: 1 below B_LO, 0 above B_HI, smoothstep between (C¹ at both ends, so the toe and the knee
    // have no seam). `0 → 0`: pure multiplication never lifts black into grey.
    float wb = 1.0 - smoothstep(B_LO_EV, B_HI_EV, L);
    if (kHybrid) {
        // 073C — the second half of the travel. `mb` is exactly 0 for |k| ≤ 20 (2026-10-29 moved it
        // there from 50; 346 only changes which slider positions arrive here — see the function doc).
        // 2026-10-29 — 电平从 |blacks| = 20 就进场（旧版要等到 50），而且不再从增益里扣一半去抵消它。
        //
        // 旧版在 −100 时两件事同时发生：电平窗口只到 −4.4 EV（30 % 码值在 −3.8 EV 之外，一点不动），
        // 增益又被砍成 1.5 EV。现在电平的窗口抬到 −1.0 EV、增益保留满 3 EV，于是 30 % 码值真的变暗
        // （−100：30 % → 24.8 %，20 % → 12.9 %）。
        float mb = smoothstep(0.2, 1.0, abs(db));
        // 342 — the crush side's own blend: **exactly 0 for |blacks| ≤ 50** (and with a zero slope
        // there), so the first half of the travel keeps 073C's bytes and the slider has no seam.
        float m5 = smoothstep(0.5, 1.0, abs(db));

        // The level: the black point moves by `off` linear units over its own window. The window is a
        // weight in L, not a clip, so it is continuous at both ends; `wl = 0` makes `off` ±0 and the
        // pixel bit-still.
        float wl = 1.0 - smoothstep(LEV_LO_EV, LEV_HI_EV, L);
        float off = B_LEV * db * mb * wl;
        // 342 — the second half's extra crush (see the constants above). It is `wl₂`'s **linear**
        // window, and the subtraction of an exact `+0` at `m5 == 0` is bit-identical to the old line.
        if (db < 0.0) {
            float wl2 = 1.0 - smoothstep(CRUSH_LO, CRUSH_HI, luma);
            off -= B_LEV_CRUSH * abs(db) * m5 * wl2;
        }
        float gain = exp2(B_EV * db * wb);

        // **The order depends on the sign, and that is what keeps the response monotone.**
        //
        //   · crush (off < 0): the level goes on first and the gain multiplies the leveled value — the
        //     owner's 「电平先算，然后算增益」. Both darken, so the minimum slope stays positive.
        //   · lift (off > 0): the gain goes on first and the level rides **outside** it. Adding ±0.006
        //     *inside* an 8× gain lifts the darkest texel eight times as far as the next one, which is
        //     exactly the inversion measured on the +100 staircase (band means 0.339 → 0.266, i.e. the
        //     darkest band came out brightest). Outside, it is a plain black-point move.
        float3 crushed = s1_toe(v + off) * gain;
        float3 lifted = s1_toe(v * gain + off);
        v = off < 0.0 ? crushed : lifted;
    } else {
        // 073B, verbatim: the first half of the travel is this, bit for bit.
        v *= exp2(B_EV * db * wb);
    }

    // whites: 138's monotone EV window (0 at −2 EV, full at +2 EV and above) plus 127's global
    // multiplicative level. The old shape (`exp(−L)` above white) decayed exactly where the owner
    // wanted the super-white pixels to follow the white point; see the constants' comment for the
    // measured table and the monotonicity bound. 147: the window reads `L0`, so exposure slides the
    // picture through a fixed window instead of sliding the window with the picture.
    float ww = smoothstep(WW_LO_EV, WW_HI_EV, L0);
    float level = 1.0 / (1.0 - W_LEV * dw * abs(dw));
    v = v * exp2(W_EV * dw * ww) * level;
    return v;
}

// ── contrast — the SEAM ─────────────────────────────────────────────────────────────────────────
//
// Contrast is the one control whose *global* body is still being replaced while this file is written
// (079 §2.1.1 is its own P0; branch `feat/contrast-0107`, commit `06c5a6b`, carries the replacement).
// So this function is a **seam with one body**, not a copy:
//
//   · today `s2_tone_map.metal` still folds contrast with the linear-light power
//     (`v = sign(v)·0.18·(|v|/0.18)^γ`, γ = 2^(contrast/100·2)) — a shear with no upper asymptote that
//     put 11–23 % of a frame on the ceiling at +100. Keeping that arithmetic inside a mask is what
//     079 §2.1.2 calls out: `local contrast = +100` clipped the masked highlights white.
//   · the body below is 0107's: a **displacement in EV**, `v *= 2^Δ`, `Δ` from `L = log2(luma)`, whose
//     shoulder bump lands exactly on display white and therefore cannot clip anything.
//
// When 0107 merges, S2 calls `tone_contrast(v, contrast, travel)` with the travel its CPU side already
// passes and **deletes its power**; nothing in this file changes. Until then the masked path runs the
// bounded body — the numbers in `LocalToneTests` pin it, so the two cannot silently drift apart.
//
// **Merged 2026-10-28:** 0107 landed on main as `ContrastCurve.swift` + `s2_contrast_ev`, and the two
// bodies are now **one**: the constants and the arithmetic below are 0107's (held band [−5.0, −3.2] EV,
// shoulder 0.55 / toe 0.85 of `travel`), and `s2_tone_map.metal` calls `tone_contrast_ev` instead of
// carrying a second copy. A mask's "contrast +100" is therefore not merely *shaped like* the global
// one — it is the same function, pinned by `ContrastLogDomainTests` (global) and `LocalToneTests`
// (masked, correlation 1.0000 against the global response).
constant float CT_WHITE_EV = 0.0;
constant float CT_BLACK_EV = -8.0;
constant float CT_TOE_W_EV = 3.0;
constant float CT_SH_LO_EV = -3.2;
constant float CT_TOE = 0.85;
constant float CT_SH = 0.55;

/// The bend of one pixel, in EV, from its luma's EV. `travel` is the CPU's `S2Contrast.travel`
/// (8 EV of tone map over the axis' own end points ⇒ 1.0 EV today) — an axis constant stays out of the
/// kernel, the same discipline `HDRCurve.axis` follows.
static inline float tone_contrast_ev(float L, float contrast, float travel) {
    // 4u(1−u): 0 at both ends of the window, exactly 1 in its middle, C¹ everywhere — so the shoulder
    // joins the held core and the white point with no step in value or in slope, and *lands on white*
    // (a pixel at white receives nothing, so nothing below white can be pushed past it).
    float up = smoothstep(CT_SH_LO_EV, CT_WHITE_EV, L);
    float shoulder = 4.0 * up * (1.0 - up);
    // The toe is a **shift** of the far end, not a bump: a gain cannot fold however dark the pixel is,
    // and it keeps 0 at 0 (no manufactured grey, no new dead black below the knee).
    float toe = 1.0 - smoothstep(CT_BLACK_EV, CT_BLACK_EV + CT_TOE_W_EV, L);
    return contrast / 100.0 * travel * (CT_SH * shoulder - CT_TOE * toe);
}

/// Contrast on one pixel. A pure gain, so `contrast = 0` is the identity exactly (Δ ≡ 0) and 0 stays 0.
static inline float3 tone_contrast(float3 v, float contrast, float travel) {
    float luma = max(dot(max(v, 0.0), kWorkingLumaWeights), 1e-9);
    return v * exp2(tone_contrast_ev(log2(luma), contrast, travel));
}
