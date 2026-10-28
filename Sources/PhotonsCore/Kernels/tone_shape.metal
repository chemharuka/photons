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
//   S2    s2_tone_map       `tone_contrast`, `region_weights`/`region_gain` contrast, shadows/highlights
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
// **085**: S2's global 阴影/中间调/高光 uses the three-window chain below (`region_weights3`). The
// local pass (`s1_6_local`) still reads the 074 two-window `region_weights`/`region_gain`; that is
// deliberately unsynchronised until the local pass is unified (a later task), so both bodies stay
// here and neither is removed.

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

// ── 085 — the three region windows (S2's global 阴影/中间调/高光) ────────────────────────────────
//
// Two complementary smoothstep chains, all on `L = log2(luma)` in EV relative to display white:
//
//     a = smoothstep(−5.4, −3.9, L)   shadow → mid
//     b = smoothstep(−2.4, −0.9, L)   mid → high
//     c = smoothstep(−1.2,  0.0, L)   high → white (closes the top)
//
//     shadow = 1 − a,  mid = a(1 − b),  high = b(1 − c)
//
// `a` reaches 1 before `b` starts, so there is no band where all three are 0 — the defect of the old
// −3.9…−3.2 EV gap, which is exactly where the reference frames' medians sat. Above display white
// `c = 1` makes `high = 0`, so the gain is exactly 1 and HDR samples pass through unchanged.
// The CPU owns the travel and its monotonicity gate (`S2Regions`); these functions take **EV**.
constant float REGION3_SHADOW_LO_EV = -5.4;
constant float REGION3_SHADOW_HI_EV = -3.9;
constant float REGION3_MID_LO_EV = -2.4;
constant float REGION3_MID_HI_EV = -0.9;
constant float REGION3_HIGH_LO_EV = -1.2;
constant float REGION3_HIGH_HI_EV = 0.0;

/// `(shadow, mid, high)` for one pixel, each 0…1.
static inline float3 region_weights3(float3 v) {
    float lum = max(dot(max(v, 0.0), kWorkingLumaWeights), 1e-9);
    float L = log2(lum);
    float a = smoothstep(REGION3_SHADOW_LO_EV, REGION3_SHADOW_HI_EV, L);
    float b = smoothstep(REGION3_MID_LO_EV, REGION3_MID_HI_EV, L);
    float c = smoothstep(REGION3_HIGH_LO_EV, REGION3_HIGH_HI_EV, L);
    return float3(1.0 - a, a * (1.0 - b), b * (1.0 - c));
}

/// The one gain of the three lifts: `exp2(shadow·Δs + mid·Δm + high·Δh)`, `dEV` already in EV.
static inline float region_gain3(float3 w, float3 dEV) {
    return exp2(dot(w, dEV));
}

// ── 073B / 073C — the end points: blacks and whites ──────────────────────────────────────────────
//
// The knee ends, in EV relative to display white, and the travel at the very bottom. −11.2 EV is far
// below anything the decoder produces as picture (the frames' p1 sits at −8…−15 EV); −4.2 EV (code
// 0.29) is below every measured p30, so the mid-tones are outside the window.
constant float B_EV = 3.0;
constant float B_LO_EV = -11.2;
constant float B_HI_EV = -4.2;

// 073C — the level half of the hybrid travel: the black point moves by up to ±B_LEV in scene-linear
// light over its own window (LEV_LO_EV … LEV_HI_EV), with a C¹ knee of LEV_KNEE at 0 on the crush side.
//
// `LEV_HI_EV = −4.4` and not `B_HI_EV = −4.2`: the level's window has to end below the *lowest p50 of
// the reference frames* (−4.36 EV, L1030408), or the level term itself would move a median and the
// "the level only works on the dark end" invariant would be a tolerance instead of a fact. B_LEV is
// pinned by the monotonicity constraint (B_LEV < 1.5/(d·ln2·2^(LEV_HI−d)) = 0.0056 for the 2.5 EV
// window below); 0.005 is sRGB code 15.6, i.e. where a print fade sits.
constant float B_LEV = 0.005;
constant float LEV_LO_EV = -6.9;
constant float LEV_HI_EV = -4.4;
constant float LEV_KNEE = 1e-3;

// Whites (contract §4.2): ±0.6 EV, plus 0.06 of a linear level at full travel, over a 2 EV shoulder.
constant float W_EV = 0.6;
constant float W_LEV = 0.06;
constant float W_BAND = 2.0;
constant float W_TAU = 1.0;

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
/// `kHybrid` is a compile-time flag (073C): S1's dispatch threshold `|blacks| > 50` is exactly the zero
/// of `m`, so the two instantiations agree bit for bit where they meet and the default entry contains
/// none of the level arithmetic — not "the arithmetic with a zero in it" (071's lesson: a runtime
/// branch is still in the code, and the compiler is free to reorder around it). The local pass has no
/// per-mask instantiation to spend, so it always calls `kHybrid = true`; `m` is exactly 0 for
/// `|blacks| ≤ 50`, which is what makes the mask agree with S1's 073B entry in that whole range.
///
///     t = blacks/100, a = |t|, m = smoothstep(0.5, 1, a)
///     EV:    v *= exp2(B_EV · t · (1 − ½m) · wb)          wb = the 7 EV toe
///     level: v  = toe(v + B_LEV · t · m · wl)             wl = the 2.5 EV window, toe only on the crush
///     whites: v = v·2^(W_EV·w·ww) + W_LEV·w·|w|·ww        ww = the shoulder (2 EV below, exp above)
template <bool kHybrid>
static inline float3 s1_end_points(float3 v, float blacks, float whites) {
    float db = clamp(blacks, -100.0, 100.0) / 100.0;
    float dw = clamp(whites, -100.0, 100.0) / 100.0;

    // One weight per pixel, from the pixel's luminance: applying a per-channel weight would move each
    // channel by a different EV and shift hue in the lifted toe.
    float luma = dot(v, kEndPointLumaWeights);
    float L = log2(max(luma, 1e-9));

    // blacks: 1 below B_LO, 0 above B_HI, smoothstep between (C¹ at both ends, so the toe and the knee
    // have no seam). `0 → 0`: pure multiplication never lifts black into grey.
    float wb = 1.0 - smoothstep(B_LO_EV, B_HI_EV, L);
    if (kHybrid) {
        // 073C — the second half of the travel. `mb` is exactly 0 for |blacks| ≤ 50.
        float mb = smoothstep(0.5, 1.0, abs(db));
        v *= exp2(B_EV * db * (1.0 - 0.5 * mb) * wb);

        // The level: the black point moves by `off` linear units over its own 2.5 EV window. The window
        // is a weight in L, not a clip, so it is continuous at both ends; `wl = 0` makes `off` ±0 and
        // the pixel bit-still.
        float wl = 1.0 - smoothstep(LEV_LO_EV, LEV_HI_EV, L);
        float off = B_LEV * db * mb * wl;
        float3 x = v + off;
        // A lift must not clip (invariant: t = +1 leaves no pixel at 0), so the toe is only taken on the
        // crush side — the darkest pixels really reach 0 when the slider is pushed down.
        v = off < 0.0 ? s1_toe(x) : x;
    } else {
        // 073B, verbatim: the first half of the travel is this, bit for bit.
        v *= exp2(B_EV * db * wb);
    }

    // whites: full weight at display white, 0 at −2 EV, exp(−L/1 EV) above 0 (the HDR shoulder). The
    // level term is (Δw·|Δw|) — quadratic, so a small travel is nearly pure EV and only the end of the
    // travel actually moves the white point (contract §4.2). It rides `ww`, so it is continuous at both
    // ends of the window and does not touch the mid-tones.
    float ww = L <= 0.0 ? smoothstep(-W_BAND, 0.0, L) : exp(-L / W_TAU);
    v = v * exp2(W_EV * dw * ww) + float3(W_LEV * dw * abs(dw) * ww);
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
