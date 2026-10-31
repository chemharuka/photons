#include <metal_stdlib>
#include "primaries.metal"
#include "tone_shape.metal"
using namespace metal;

// S1 — scene linear: black/white **end points**, the linear black offset, exposure gain, white-balance
// gains, highlight recovery.
//
// Order (派单 019's, with 073's end-point model where 019's affine level used to be):
//   ① absolute levels (派单 030, dropper only)  v = (v − blk)/max(wht − blk, 1e−3)
//   ①b linear black **offset** (071):          v = v + blackOffset          additive, linear units
//   ② exposure gain + WB gains:                v *= gain · wb              multiplicative
//   ③ blacks:  EV (first half of the travel), then EV + **level** (second half, 073C)
//   ④ whites:  EV (138: 0 below −2 EV, rising monotonically to 1.2 EV at +2 EV and above display
//              white) × a multiplicative level (127: global, so the shadows scale too; `0 → 0`)
//   ⑤ highlight recovery: the soft shoulder, unchanged
//
// **073B — why the affine level left this path.** 019 made `blacks`/`whites` an affine remap
// `(v − blk)/max(wht − blk, 1e−3)`. That is family (a) — a *level*: it changes the slope of the whole
// picture, so `blacks = +100` moved every pixel (measured on L1030433: pure black 0 → code 0.397,
// 50 % grey +25 code, 100 % of pixels affected). The owner's brief is Lightroom's blacks/whites —
// family (c), an **end-point move with a soft knee**: the darkest pixels get exposure, the mid-tones
// are untouched, and the knee is monotone (no "the shadows are brighter than the mid-tones").
//
// So the sliders no longer touch the span. `blacks` is a **pure multiplicative EV** at the dark end
// (`0 → 0`: it never manufactures grey where there was none — that is `blackOffset`'s job, 071) and
// `whites` is mostly EV with a small **multiplicative** level term (127), because a scene-linear
// multiplier alone cannot make the white point *move* where the picture has almost no pixels.
//
// **127 — the level is multiplicative, and global.** 073B paired that EV term with a *small additive*
// level riding the same −2 EV window as the shoulder ("it does not fog the picture"). The owner then
// measured the consequence: `whites +100` on an exp+2 frame moved p95/p99.9 but left p1/p5/p50 at
// 7.5 / 26.2 / 89.9 codes — the shadows do not respond at all, because the window is 0 there. What the
// owner means by 「电平」 is a scale over the whole range. A multiplier does that without 019's fog
// (019's affine/additive level lifted pure black to code 0.397): `v·k` is still 0 at `v = 0`. The EV
// half is 073B's white-point move with 138's monotone window (see `tone_shape.metal`); this is a level
// *on top of* the white-point move, not a redefinition of it.
//
// **The knee is a window on L = log2(luma), not on the linear value and not on the display code.**
// Three coordinates were measured (contract 073 §4.9); for a ±3 EV travel the coded one loses: a
// weight that falls from 1 to 0 over a *code* span C has |dw/dL| ≥ 0.29·(C+0.055)/C at its steepest,
// so min d(log v′)/d(log v) bottoms out at 0.23 no matter how the ramp is shaped — at code 0.25 the
// knee would fold the shadows (measured 0.06 for the 1.5 EV draft). In log2 light the same audit is
// closed-form: slope = 1 + B_EV·Δ·w′(L), so a smoothstep over 7 EV gives
//   1 − 3.0·1.5/7.0 = **0.357** at Δ = +1,
// i.e. the local contrast of the lifted toe is compressed ≈2.8× and never folded. `L` is the
// histogram's own HDR coordinate (`u = 0.5 + 0.125·log2 v`), so the slider's reach can be read on the
// histogram card: full weight below −11.2 EV, zero at −4.2 EV (code 0.29), which is *below* every
// measured p30 of the four reference frames (p30 ∈ [−4.85, −4.22] EV) — hence p50 moves by exactly 0.
//
// **Why 3 EV and not the contract's 1.5.** The owner re-pinned the travel to ±3 EV on 2026-10-27
// ("blacks 行程 = ±3 EV"), and with that travel the knee has to be 7 EV wide to keep the slope above
// 0.3. The two are a pair (contract §4.7's counter-example): raising B_EV without widening the knee is
// how the first draft folded. The numbers are in `BwLevelsTests.testTheKneeIsMonotone…`.
//
// ── 073C: the hybrid travel (2026-10-27) ───────────────────────────────────────────────────────────
//
// The owner then asked for Lightroom's *black level* rather than only a dark-end exposure:
//
//   「blacks 的"最暗 5 %"，改成混合型，就是滑块开始为加减 EV，后面逐步变为修改电平」
//
// A pure multiplier cannot do the second half of that: `0 → 0` for every gain, so at full travel the
// black end can never be *moved* — pushed down it stays a very dark grey (today: `blacks = −100`
// leaves the darkest pixels at 1/8 of their value, never at 0), and pushed up it never floats the
// black point off the floor. So the travel is two mechanisms, blended:
//
//     t = blacks/100                       a = |t|
//     m = smoothstep(0.5, 1, a)            0 for the whole first half, 1 at the end
//     EV:    v *= exp2(B_EV · t · (1 − ½m) · wb)      — `wb` is the existing 7 EV toe
//     level: v  = toe(v + B_LEV · t · m · wl, LEV_KNEE),  wl = 1 − smoothstep(LEV_LO_EV, LEV_HI_EV, L)
//
// **A = B_EV is forced, not chosen.** The invariant "the first half of the travel is *bit-identical*
// to 073B" means `exp2(A·t·(1 − ½·0)·wb)` must be `exp2(B_EV·t·wb)` for every |t| ≤ 0.5, i.e. A = 3.
// There is no free parameter left there, and the budget it buys is: at a = 0.5 the p1 lift is exactly
// today's (measured +0.85…+1.5 EV on the four frames), and at a = 1 the EV half is 1.5 EV, the rest
// of the travel being the level move.
//
// **B_LEV = 0.005 is pinned by the monotonicity constraint, the same way B_EV was.** An additive level
// term riding a window in L puts a negative `B·w′(L)/(v·ln2)` into the slope, and at the bottom of the
// window `v` is small, so the constraint is
//     B_LEV · 1.5/(d · ln2 · 2^(B_HI_EV − d)) < 1      (d = the window's width in EV)
// i.e. B_LEV < 0.0126 · d · 2^−d. With d = 2.5 EV (LEV_LO_EV = −6.9) that is 0.0056; 0.005 leaves the
// measured minimum slope at 0.354 (a = 1, in the middle of the level's foot) instead of cutting it
// to 0. It is also the number that puts the black point where a raised black point belongs: linear
// 0.005 is sRGB code 15.6 — the deepest shadow of `blacks = +100` sits at the code a print fade
// sits at, which is the reading the owner asked for ("黑不再死").
//
// **Why the level gets its own window, and why it is in L.** Two hard invariants hold it down: the
// median must not move (so the window's top sits 0.2 EV *below* the EV toe's, under the lowest p50 of
// the four reference frames: "above −4.4 EV the level moves nothing", which is a fact and not a
// tolerance) and the map must not fold.
// The second one is what shapes the window: a *narrow* window keeps `w′` large where `v` is small and
// folds; the window is 2.5 EV wide for that reason. Everything below LEV_LO_EV carries the full
// offset, so a lift is a pure shift (slope 1) there and the crush is a pure shift down plus a clip.
//
// **The toe is the "soft knee" and the clip is the "level".** `s1_toe` is a C¹ rectifier: identity at
// or above +LEV_KNEE, exactly 0 at or below −LEV_KNEE, quadratic in between (slope 0 → 1, so no step
// and no fold). It is taken **only on the crush side**: a lift must not clip anything (invariant:
// `t = +1` leaves zero pixels at 0), so `off ≥ 0` writes `v + off` untouched. The crush side really
// does reach 0 — that is what "改电平" means — and the fraction of the frame that lands there is
// measured (`BwLevelsTests.testTheHybrid…`).
//
// **The CPU switch is invisible.** `kHybrid` is a template flag, so the level arithmetic exists only
// in the instantiations that can use it — no runtime `if`, which is 071's lesson. The dispatch
// threshold (`|blacks| > 50`) is exactly the zero of `m`, so both instantiations agree bit for bit
// where they meet: at |blacks| = 50 the level term is ±0 · B_LEV = 0 and the EV exponent is
// `3·t·1·wb`, today's expression, unchanged in the source of the `kKnee` instantiation.
//
// **Whites** (127): the EV half keeps contract §4.2's constants — full weight at display white (0 EV),
// fading down to 0 at −2 EV (the shoulder on the dark side) and decaying as exp(−L/1 EV) above 0 (the
// shoulder on the HDR side: +1 EV 0.368, +4 EV 0.018). The level is now multiplicative and has **no**
// window (`1/(1 − 0.20·Δw·|Δw|)`, ×1.25 at +100), so it scales every luma including the HDR tail; it
// is exactly 1 at `Δw = 0`, which is why a neutral document is byte-still. Its physical ceiling is
// small by construction (p1 moves ≈2 codes at +100) — a shadow that must be visibly brighter is
// `blacks`' EV toe or `exposure`, not this slider.
//
// **The default path has no new arithmetic.** `blacks == 0 && whites == 0` selects the entry point
// without the knee code at all, exactly as 071 split off the trim: a branch inside the function
// (`if (blacks != 0.0)`) is *in the code* and the compiler is free to reorder around it — 071 measured
// that spelling moving 2980/12309 samples of the push document by an ULP. So the body is one templated
// function and the CPU picks an entry point:
//
//     kKnee  kHybrid  kTrim   entry point                      dispatched when
//     false  false    false   s1_scene_linear                   no sliders, no trim
//     false  false    true    s1_scene_linear_trim              071's trim only
//     true   false    false   s1_scene_linear_knee              sliders ≠ 0, |blacks| ≤ 50
//     true   false    true    s1_scene_linear_knee_trim
//     true   true     false   s1_scene_linear_hybrid            073C: |blacks| > 50
//     true   true     true    s1_scene_linear_hybrid_trim
//
// **`kLevels` and 030's dropper are gone (schema 11).** `s1_scene_linear_levels(_trim)` was the affine
// remap `(v − blackLevel)/span` for a document that carried an absolute level from the 042 dropper.
// That control was deleted, the two document keys went with it, and the model now has exactly one
// black point (`light.blackOffset`, 071). A document written by an older build keeps its pixels to
// within that level's absence: `EditModel` drops the key and stamps the schema.
//
// **Highlight recovery** is a soft shoulder: values above knee 0.8 are compressed towards 1.0 with a
// shape controlled by `amount`. amount = 0 is exact identity; amount = 1 asymptotes at 1.0. It stays
// last: `whites` says *where* the white point is, recovery says *how* the shoulder is pressed.
//
// **The matte is not a shadow here either** (派单 008 B, moved from S2 by 019). S1 dispatches the whole
// canvas and S0 writes 0 into everything outside the picture, so a lifted black point maps that 0 to a
// positive value and the letterbox would turn grey. The knee model keeps 0 at 0 (multiplicative), but
// the level path (dropper) and 071's offset still move it, so both guards stay here, unchanged and in
// the same order: alpha 0 says "there is no photograph at this pixel" (S0's background), and the
// content rect is the canvas guard for a window whose rect covers the canvas. They are exact
// write-throughs, not epsilons, so a test can assert the bars are exactly 0
// (`MatteIsNotPartOfThePictureTests`, `ToneMapTests`).

struct S1Params {
    float4 a;   // gain, wbR, wbG, wbB
    float4 b;   // recovery, identity, blacks, whites
    float4 c;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    // 派单 071 — the linear black offset in scene-linear units (x). 147 — the S1 exposure gain (y),
    // handed to `s1_end_points` so whites' EV window is read on the unexposed light. 2 pad.
    float4 e;
};

// 179 — 原色校准 (CalibrationGroup): a 3×3 primaries matrix plus the shadows' tint, in its **own**
// buffer (index 1), bound only by the `_cal` entry points.
//
// Why a second buffer rather than five more fields in `S1Params`: the requirement is that a document
// with all seven numbers at 0 does not put the matrix in a uniform *at all*. `S1Params` is written for
// every document; this struct exists only when `CalibrationGroup.isIdentity` is false, and the
// kernels that do not declare it do not have it in their argument list.
//
// The rows are three `float4`s, `xyz` used, `w` unused — a **row-major** spelling, because a
// `float4x4` in Metal is column-major and one transposed matrix here is a wrong picture that no test
// with a grey patch would see.
struct CalParams {
    float4 r0;   // M row 0
    float4 r1;   // M row 1
    float4 r2;   // M row 2
    // x = shadow tint, −1…+1 (`CalibrationGroup.clampedShadowTint`). 3 pad.
    float4 t;
};

// The tint's axis, and the quantity it holds constant, is the **working primaries' own luma** — so it
// comes from `primaries.metal#kWorkingLumaWeights`, which this file already includes, and not from a
// fourth copy of the triple. (179 wrote `float3(0.2627, 0.6780, 0.0593)` here inline; the numbers are
// the same three constants, and the kernel's output is byte-identical either way —
// `SaturatedColourTests.testNoKernelCarriesItsOwnLumaWeights` is the rule that keeps it that way.)
// Deliberately **not** `tone_shape.metal`'s `kEndPointLumaWeights`: that one reads *encoded sRGB*
// numbers for the blacks/whites knee coordinate (073B §4.9), which is a different question in a
// different domain.

// `CalibrationGroup.shadowTintScale`: the green channel's change at full travel in the deepest shadows.
constant float kCalibrationShadowTintScale = 0.5;

// The tint's window, in log2 light relative to the 0.18 pivot: full weight at −5 EV (Y = 0.0056) and
// exactly 0 at −0.5 EV (Y = 0.127). Above that nothing moves — which is why a 0.18 grey cannot take a
// cast from this control, and why `Y > 0.2` is bit-still.
static inline float calibration_smoothstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// The two ends of the blacks knee (`B_EV/B_LO_EV/B_HI_EV`), 073C's level half
// (`B_LEV/LEV_LO_EV/LEV_HI_EV/LEV_KNEE`), the whites travel (`W_*`) and the C¹ toe used to live here.
// They live in `tone_shape.metal` now (079 §2.1.2): S1.6's masked end points have to be the *same*
// numbers, and a second copy of a constant is a second meaning waiting to happen. Nothing about this
// kernel's arithmetic changed when they moved.

// One body, seven instantiations. All four flags are compile-time constants, so an instantiation that
// is not for them contains none of their arithmetic — not "the arithmetic with a zero in it".
//
// 073C's `kHybrid` is the level half of the blacks travel. It is a separate flag rather than a
// runtime test on `m` for the same reason 071 split the trim off: the dispatch threshold
// (`|blacks| > 50`) is exactly where `m` is 0, so the two instantiations agree bit for bit at the
// boundary and the untouched one keeps 073B's source verbatim.

template <bool kKnee, bool kHybrid, bool kTrim, bool kCalib>
static inline void s1_body(texture2d<float, access::read> src,
                           texture2d<float, access::write> dst,
                           constant S1Params &p,
                           constant CalParams *cpPtr,
                           uint2 gid) {
    float4 c = src.read(gid);
    if (p.b.y > 0.5) {
        dst.write(c, gid);
        return;
    }

    // Alpha 0 is the only thing that says "there is no photograph here", so it is checked before any
    // pixel maths — the same rule and the same order S2 has always had.
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

    float3 v = c.rgb;

    // ① 071 — the additive linear trim, **before** the gain so it is scaled by the same gain the
    //    negative samples are (see 071's header: -0.01 at +1.6 EV is -0.03).
    if (kTrim) {
        v += float3(p.e.x);
    }

    // ② The gain. The WB gains are literally (1, 1, 1) since white balance became a decode setting
    //    (派单 006) — the old Planckian fit here would be a second correction on top of the decoder's.
    v *= p.a.x * p.a.yzw;

    // ③④ 073B — the end points. The **weight** is read off the encoded domain's log coordinate L (see
    //    the header for why L and not the code), the **gain and the level** are applied in scene-linear
    //    light. Both sliders are clamped to their travel in one place, so a hand-edited document cannot
    //    ask the kernel for 30 EV.
    if (kKnee) {
        // ③④ 073B/073C — the end points, from the include both this kernel and S1.6 call
        //    (`tone_shape.metal#s1_end_points`): the **weight** is read off the encoded domain's log
        //    coordinate L, the **gain and the level** are applied in scene-linear light. Both sliders
        //    are clamped to their travel inside that function, so a hand-edited document cannot ask the
        //    kernel for 30 EV, and a mask asking for the same numbers gets the same picture.
        v = s1_end_points<kHybrid>(v, p.b.z, p.b.w, p.e.y);
    }

    // ⑤ The shoulder, untouched, and always last.
    float amount = clamp(p.b.x, 0.0, 1.0);
    if (amount > 0.0) {
        const float knee = 0.8;
        float3 below = min(v, float3(knee));
        float3 t = max(v - knee, 0.0) / (1.0 - knee);
        float3 shoulder = knee + (1.0 - knee) * ((1.0 - amount) * t + amount * (1.0 - exp(-t)));
        v = below + shoulder - knee;
    }

    // ⑥ 179 — 原色校准, at this stage's **exit**: the 3×3 primaries matrix, then the shadows' tint.
    //
    // `kCalib` is a compile-time flag, so the calibration-free instantiations contain none of this
    // (071's lesson: "the arithmetic with a unit matrix in it" is still arithmetic the compiler may
    // schedule). The runtime `st != 0` inside is fine here — this code exists *only* in the `_cal`
    // instantiations, which a document with all seven numbers at 0 never reaches.
    //
    // No clamp after the matrix: every entry of M is ≥ 0 (the CPU gamut-maps each column into the
    // cube), so a non-negative input stays non-negative, and a *negative* input is S1's own
    // sub-black band (071's trim) which S2 is written to carry (`s2_tone_map` clamps at its end, not
    // at its start). Clamping here would quietly delete that band for calibrated documents only.
    if (kCalib) {
        constant CalParams &cp = *cpPtr;
        v = float3(dot(cp.r0.xyz, v), dot(cp.r1.xyz, v), dot(cp.r2.xyz, v));

        float st = cp.t.x;
        if (st != 0.0) {
            float y0 = dot(v, kWorkingLumaWeights);
            // A pixel at or below zero has no log coordinate; it also has no shadow *hue* to tint.
            if (y0 > 0.0) {
                float w = 1.0 - calibration_smoothstep(-5.0, -0.5, log2(max(y0, 1e-7) / 0.18));
                v.y *= max(1.0 - kCalibrationShadowTintScale * st * w, 0.0);
                // Luminance is **kept**: the tint moves the colour, not the exposure. The same
                // invariant LightCraft's `calibrate` holds (`c * y0 / y1`).
                float y1 = max(dot(v, kWorkingLumaWeights), 1e-9);
                v *= y0 / y1;
            }
        }
    }

    dst.write(float4(v, c.a), gid);
}

// The default path: 019's arithmetic with an identity level, byte for byte. `RenderGraph` picks this
// one only when there is no dropper level, no slider travel and no trim.
kernel void s1_scene_linear(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant S1Params &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, false, false, false>(src, dst, p, nullptr, gid);
}

// 071: the same body with the offset in it.
kernel void s1_scene_linear_trim(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant S1Params &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, false, true, false>(src, dst, p, nullptr, gid);
}

// 073B: the black/white end points. Picked only when `blacks != 0 || whites != 0`.
kernel void s1_scene_linear_knee(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant S1Params &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, false, false, false>(src, dst, p, nullptr, gid);
}

kernel void s1_scene_linear_knee_trim(texture2d<float, access::read> src [[texture(0)]],
                                      texture2d<float, access::write> dst [[texture(1)]],
                                      constant S1Params &p [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, false, true, false>(src, dst, p, nullptr, gid);
}

// 073C: the second half of the blacks travel — the same EV toe plus the black-point level move.
// Picked only when `|blacks| > 50` (i.e. where `m` can be non-zero); below that the level term is
// exactly zero and `s1_scene_linear_knee` is the right instantiation, bit for bit.
kernel void s1_scene_linear_hybrid(texture2d<float, access::read> src [[texture(0)]],
                                   texture2d<float, access::write> dst [[texture(1)]],
                                   constant S1Params &p [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, true, false, false>(src, dst, p, nullptr, gid);
}

kernel void s1_scene_linear_hybrid_trim(texture2d<float, access::read> src [[texture(0)]],
                                        texture2d<float, access::write> dst [[texture(1)]],
                                        constant S1Params &p [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, true, true, false>(src, dst, p, nullptr, gid);
}

// ── 179 — the six `_cal` twins ────────────────────────────────────────────────────────────────────
//
// One for each entry point above, differing only in `kCalib = true` and in declaring the calibration
// uniform at `buffer(1)`. They are separate *kernels*, not a runtime `if`, for the reason the file has
// six entry points already: the calibration-free documents must not carry the matrix's arithmetic in
// their compiled body, and a document with all seven numbers at 0 has no `CalParams` written for it
// at all (see `RenderGraph`'s S1 case).

kernel void s1_scene_linear_cal(texture2d<float, access::read> src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                constant S1Params &p [[buffer(0)]],
                                constant CalParams &cp [[buffer(1)]],
                                uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, false, false, true>(src, dst, p, &cp, gid);
}

kernel void s1_scene_linear_trim_cal(texture2d<float, access::read> src [[texture(0)]],
                                     texture2d<float, access::write> dst [[texture(1)]],
                                     constant S1Params &p [[buffer(0)]],
                                     constant CalParams &cp [[buffer(1)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, false, true, true>(src, dst, p, &cp, gid);
}

kernel void s1_scene_linear_knee_cal(texture2d<float, access::read> src [[texture(0)]],
                                     texture2d<float, access::write> dst [[texture(1)]],
                                     constant S1Params &p [[buffer(0)]],
                                     constant CalParams &cp [[buffer(1)]],
                                     uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, false, false, true>(src, dst, p, &cp, gid);
}

kernel void s1_scene_linear_knee_trim_cal(texture2d<float, access::read> src [[texture(0)]],
                                          texture2d<float, access::write> dst [[texture(1)]],
                                          constant S1Params &p [[buffer(0)]],
                                          constant CalParams &cp [[buffer(1)]],
                                          uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, false, true, true>(src, dst, p, &cp, gid);
}

kernel void s1_scene_linear_hybrid_cal(texture2d<float, access::read> src [[texture(0)]],
                                       texture2d<float, access::write> dst [[texture(1)]],
                                       constant S1Params &p [[buffer(0)]],
                                       constant CalParams &cp [[buffer(1)]],
                                       uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, true, false, true>(src, dst, p, &cp, gid);
}

kernel void s1_scene_linear_hybrid_trim_cal(texture2d<float, access::read> src [[texture(0)]],
                                            texture2d<float, access::write> dst [[texture(1)]],
                                            constant S1Params &p [[buffer(0)]],
                                            constant CalParams &cp [[buffer(1)]],
                                            uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, true, true, true>(src, dst, p, &cp, gid);
}
