#include <metal_stdlib>
#include "primaries.metal"
#include "tone_shape.metal"
using namespace metal;

// S2 — tone map: the contrast bend (a bounded S in log2 EV, 0107), the two region lifts, final clamp.
//
// Order: **contrast as an EV displacement** → region lifts for shadows/highlights weighted by an
// **EV window** → the final clamp. It is monotone in every slider and exact identity at all zeros,
// which is what M1 has to prove.
//
// **0107 replaced the contrast curve.** It used to be a linear-light power around a 0.18 pivot
// (`v = sign(v)·0.18·(|v|/0.18)^(2^(contrast/100·2))`): one exponent over the whole range (a 4×
// slope at +100, i.e. a shear, not a bend) with no upper asymptote (`0.18·(v/0.18)^4 = 1` at
// v = 0.276, mid-grey + 0.62 EV). Measured on the four reference frames at +100: 12.5 / 3.1 / 1.5 /
// 12.9 % of the samples on code 255 and the median 86 → 30 codes; at −100 the median went *up*
// (86 → 109), because ¼ is a toe lift, not a flattening.
//
// The replacement is a **displacement in EV over a held core**, `v *= 2^Δ(L)`, `L = log2(luma)`:
//
//   · the core `[−5.0, −3.2]` EV is **held** (`Δ = 0`, slope 1) — that is where the four frames'
//     median sits (p50 ∈ [−4.07, −3.19] EV), so the median moves by **0 codes**. A point pivot
//     cannot do that: a bounded tanh S hinged at the middle of the range moves these medians by
//     +10.5 / +5.9 / −3.4 / +16.7 codes, measured — a static curve cannot put its fixed point on
//     four different medians. See `S2Contrast` for the full argument.
//   · the **toe** (`blackEV … blackEV+3`) is a *shift*, i.e. a gain: it cannot fold (slope ≥ 0.575
//     at full travel) and it keeps 0 at 0.
//   · the **shoulder** (`[−3.2, 0]`) is a *bump* that **lands on display white**: no sample at or
//     below white can be pushed past it (peak displacement 0.55 EV against 1.6 EV of headroom).
//     Measured at +100: 0.00–0.01 % on the ceiling, i.e. the neutral frame's own count.
//   · both terms are 0 for `L ≥ 0`, so **HDR samples above white pass through bit for bit** and 079
//     §4's "no upper clamp in S2" holds: the bound is the shape, not a `min()`.
//
// `travel` = `8/(whiteEV − blackEV)` = 1.0 EV replaces the old constant `2.0` — derived from the two
// end points of the axis (darktable's `contrast *= 8/(white_ev − black_ev)` normalisation), not
// chosen. The numbers live in `S2Contrast` (Swift) and in the `CT_*` block below; a test parses this
// file and asserts the two copies are equal.
//
// **079 §2.1.2 — the mask already runs this stage's replacement.** `s1_6_local` takes its contrast
// from `tone_shape.metal#tone_contrast` (0107's bounded log2 bend) and its region lifts from the same
// `region_weights`/`region_gain` this kernel calls, so "the same slider means the same thing inside and
// outside a mask" is a property of the code rather than a promise. The one slider whose *global* body
// is still the old linear-light power is contrast — 0107 is its own派单 — and when that lands here the
// power below is replaced by a call to the very function the masked path already uses.
//
// **Blacks/whites are not here** (派单 019). They are the two end points, a scene-linear quantity, so
// they live in S1 (`s1_scene_linear`, 073B). What is left here is *how the range bends between the end
// points* — contrast and the two region lifts — which is the "normal colour grading" side of the same
// distinction.
//
// **074 R2 — the region weights are EV windows, not linear-luma thresholds.** The shipped weights were
// `1 − smoothstep(0, 0.5, lum)` and `smoothstep(0.5, 1, lum)`, i.e. windows on *linear* luminance
// between code 0.5 (v = 0.214) and 1.0. Two measured facts made that wrong:
//
//   1. **The shadow window was centred on mid-grey.** At lum = 0.18 the old weight is 0.705, so
//      `shadows = +100` applied 70 % of its lift to the mid-tones: measured on the four reference
//      frames it moved the *median* by +19…+24 display codes while p90 moved +12…+26 — a global
//      brightness gain wearing the label "shadows" (074 §0, reproduced in `ToneMapTests`).
//   2. **The highlight window was above most of the picture.** It starts at lum 0.5 (code 0.735);
//      the frames' p99 sits at code 0.60…0.78, so `highlights ±100` moved them by 0…4 codes — a dead
//      control on real photographs — and at `highlights = −100` the window's own slope folded the map:
//      measured min d(log v′)/d(log v) = **−0.280** at code 0.895 (21 of 767 grid samples below 0.3),
//      i.e. a stretch of the highlights *inverted*.
//
// The fix is the coordinate, not a gain tweak: the weights are now smoothsteps on
// **L = log2(luma)** — EV relative to display white, the histogram card's own axis — with two 2 EV
// windows placed by the measured percentiles:
//
//     shadows    1 at/below −5.9 EV  →  0 at −3.9 EV
//     highlights 0 at/below −3.2 EV  →  1 at −1.2 EV and above
//
// Why those numbers (contract 073 §3 and `ToneMapTests`, measured on `L1030402/405/408/433`):
// p50 ∈ [−4.36, −3.28], p20 ∈ [−5.35, −4.77], p5 ∈ [−6.69, −6.22], p70 ∈ [−3.47, −2.53], p95 ∈
// [−2.48, −1.45], p99 ∈ [−1.68, −0.88]. The shadow boundary at −3.9 EV keeps **every** median at
// 0…2 codes while p5…p20 still move +7…+12; the highlight boundary at −3.2 EV does the mirror at the
// top (p95 moves −9…−35, the median 0). Both windows are 2 EV wide, which is the monotonicity budget:
// slope = 1 + 0.8·Δ·w′(L) with max|w′| = 1.5/2.0, so min slope is 1 − 1.2/2.0 = **0.400** at ±100
// (the old highlight window was 0.5 EV wide in luma and folded at −0.280).
//
// The two windows do not meet: between −3.9 and −3.2 EV neither slider acts, which is what keeps the
// mid-shadow-to-mid-tone band free of both. An EV window also has the property the owner asked for —
// the separation from the mid-tones does not depend on the exposure: adding +2 EV moves the *signal*
// through a window whose width is fixed in stops, whereas the old luma threshold changed which part of
// the picture counted as "shadow" as the linear values were multiplied.
//
// Direction (派单 008 A): Lightroom's, i.e. **both region sliders brighten towards +**. `highlights +`
// therefore *brightens* the highlight zone (less recovery) and `highlights −` recovers it.
//
// Matte (派单 008 B): the canvas may be larger than the picture (letterbox) and everything outside the
// content rect is 0. A shadow/highlight lift treats 0 as a picture pixel, which is how "drag shadows"
// used to light up the viewport's background bars. Those pixels are written through untouched — an exact
// pixel identity, not an epsilon — so a test can assert the matte is 0.

struct S2Params {
    // contrast, travel (EV of bend at |contrast| = 100, from `S2Contrast.travelEV`), pad, pad.
    // `.y` used to carry the pivot (0.18) for the linear-light power; that power is gone (0107) and
    // the slot now carries the number that replaced its constant `2.0` — see the header.
    float4 a;
    float4 b;   // highlights, shadows, identity, pad
    float4 c;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

// 074 R2 — the two windows live in `tone_shape.metal` now (079 §2.1.2): S1.6's masked lifts have to be
// the *same* windows, and a mask reading a second copy of `−5.9/−3.9/−3.2/−1.2` is a second meaning
// waiting to happen. `region_weights`/`region_gain` are the same two lines this kernel used to spell
// out; the extraction is bit-identical (same expressions, same order — `ToneMapTests` pins it).

// ── 0107 — the contrast bend's axis constants (the `.metal` copy of `S2Contrast`) ──────────────
//
// `CT_WHITE_EV` is display white, `CT_BLACK_EV` the tone map's floor. `CT_TOE_W_EV` is the width of
// the toe's transition (so the toe is at full travel from `CT_BLACK_EV + CT_TOE_W_EV` = −5.0 EV
// down), `CT_SH_LO_EV` the bottom of the shoulder's window (the shoulder's own top is `CT_WHITE_EV`,
// so the bump peaks at −1.6 EV). Between them — `[CT_BLACK_EV + CT_TOE_W_EV, CT_SH_LO_EV]`, i.e.
// −5.0 … −3.2 EV — both terms are 0: that is the **held core**, and it is what pins the median.
//
// `CT_TOE` / `CT_SH` are the two travels as a fraction of `p.a.y` (= 8/(white − black) = 1.0 EV).
// The toe is a *gain* on the far side of a smoothstep, so its steepest slope is `1.5·A/w` = 0.575;
// the shoulder is a `4u(1−u)` bump, whose steepest flank is `3.11·A/w` = 0.53 and whose code-space
// step is amplified by `2^(0.4167·Δ)`. Both fractions are set to the 2-code banding budget, and both
// are measured in `ContrastLogDomainTests` (max step 1.80 / 1.67 codes at ±100).
// Contrast itself lives in `tone_shape.metal#tone_contrast_ev` — the same body S1.6 (masks) calls,
// so a global "contrast +100" and a masked one are the same function, not two curves that agree.
// 0107 merged 2026-10-28; this file used to carry its own copy (`s2_contrast_ev`).

// One body, two entry points. `kContrast` is a compile-time flag, so the pass that runs with
// `contrast == 0` contains none of the log2/exp2 arithmetic — not "the arithmetic with a zero in it".
// That is 071's lesson (a branch inside the function is *in the code*, and the compiler is free to
// reorder around it: 071 measured that spelling moving 2980/12309 samples by an ULP) and it also keeps
// the slider-free pass free of two transcendental ops per pixel. `RenderGraph` dispatches on
// `edit.light.contrast == 0`.
//
// It is a *safety net*, not the identity proof: `tone_contrast_ev` returns exactly 0.0 at contrast 0, so
// `exp2(0)` is exactly 1 and the contrast path is bit-identical too (`ContrastLogDomainTests` pins
// both). The **old** power was not: `0.18·(|v|/0.18)^1` is `0.18·(|v|/0.18)` and a division followed by
// a multiplication is not the identity — measured 980 of 1685 samples off by 1 ULP on the arithmetic
// path (0 codes at 8 bits, but not "bit for bit"). The shipped pipeline never saw it, because the
// all-zero document takes the `identity` copy branch above; that is the fact this ticket recorded
// before changing anything.
template <bool kContrast>
static inline void s2_body(texture2d<float, access::read> src,
                           texture2d<float, access::write> dst,
                           constant S2Params &p, uint2 gid) {
    float4 c = src.read(gid);
    if (p.b.z > 0.5) {
        dst.write(c, gid);
        return;
    }

    // **The matte is not a shadow.** S0 marks background (anything outside the picture, in a canvas-space
    // window) with alpha 0, and the guard below is a *canvas* guard: when the window is the canvas, the
    // content rect covers every pixel, so background pixels used to fall through and get lifted with the
    // shadows — a shadows/curve lift turned the letterbox grey. Alpha 0 is the only thing that says
    // "there is no photograph here", so it is checked before any pixel maths.
    if (c.a == 0.0) {
        dst.write(c, gid);
        return;
    }

    // Outside the content rect: the matte, written back unchanged (S0 leaves it at 0).
    float2 g = float2(gid);
    if (g.x < p.c.x || g.y < p.c.y || g.x >= p.c.x + p.c.z || g.y >= p.c.y + p.c.w) {
        dst.write(c, gid);
        return;
    }

    // **Keep the sign.** The decoder hands us scene-linear values that go *below* the black point
    // (measured on _1274394.dng: min −0.039, 33 M negative samples, 43 % of the frame under luma
    // 1e-6). Those pixels are not dead — inside that band the 32×32 block means vary with σ 5.7e-4
    // against 2.5e-5 expected from noise, i.e. 23× more structure than noise, which is exactly the
    // detail Lightroom can lift and we could not. Clamping here deleted it before any slider saw it.
    // (Since 019 the lift that reaches into that band is S1's black end point; this stage must still
    // not clamp it away before its own maths.)
    float3 v = c.rgb;

    // ── contrast: a bounded S in log2 EV over a held core (0107) ───────────────────────────────
    //
    // This replaces the linear-light power (see the header for the measured "before"). It is a
    // *displacement in EV*, `v *= 2^Δ(L)`: contrast moves the shadow end and the highlight end in
    // opposite directions and leaves the band they cannot reach (the median's) alone.
    if (kContrast) {
        // Same non-negative luma as the region weights below: a mixed-sign pixel must not read a
        // slightly different luminance here than there.
        float lumaC = max(dot(max(v, 0.0), kWorkingLumaWeights), 1e-9);
        v *= exp2(tone_contrast_ev(log2(lumaC), p.a.x, p.a.y));
    }

    // The **region weights** are computed from the non-negative part, exactly as before the sign was
    // preserved. A pixel with mixed signs (one channel sub-black) would otherwise read a slightly
    // different luminance and the shadows/highlights lift would land a code off on its *positive*
    // channels — measured as 260 of 3.05 M pixels moving by 1 in the push fixture, with no benefit.
    //
    // The coordinate is L = log2(luma) — EV relative to display white, the histogram's own HDR axis —
    // so the windows are exposure-invariant in width and can be read off the card. A pixel at or below
    // zero lum reads a very negative L, which is the shadow end: exactly right for a sub-black sample
    // that a lift has already pulled above zero. Both weights come from the shared include, which is
    // the one place the numbers live (`tone_shape.metal`).
    float2 w = region_weights(v);
    // LR convention for both region sliders: a positive value lifts that region, a negative value
    // pulls it down. `highlights +` therefore *brightens* the highlight zone (less recovery) and
    // `highlights -` recovers it — the sign used to be flipped here, which made the panel read
    // backwards against Lightroom for the same gesture.
    v *= region_gain(w, p.b.y, p.b.x);

    // The clamp stays **here**, at the end of the tone map, and not one line earlier: a sub-black
    // value that a lift (S1's black end point, or these region lifts) has pulled above zero is real
    // picture by now and must survive; whatever is still below zero is what the display
    // would clip anyway, and clamping it here is what keeps every ordinary edit byte-identical to
    // before. Measured: keeping the sign *through* the write instead moved 260 of 3.05 M pixels by one
    // code in the push fixture — a real but pointless change in the wrong place.
    dst.write(float4(max(v, 0.0), c.a), gid);
}

// The two instantiated entry points (see the `kContrast` note above the body): the first is byte for
// byte the pass every document with `contrast == 0` has always run, the second is the only place the
// log2-domain bend exists.
kernel void s2_tone_map(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant S2Params &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    s2_body<false>(src, dst, p, gid);
}

kernel void s2_tone_map_contrast(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant S2Params &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    s2_body<true>(src, dst, p, gid);
}
