#include <metal_stdlib>
using namespace metal;

// S1 — scene linear: black/white **end points**, the linear black offset, exposure gain, white-balance
// gains, highlight recovery.
//
// Order (派单 019's, with 073's end-point model where 019's affine level used to be):
//   ① absolute levels (派单 030, dropper only)  v = (v − blk)/max(wht − blk, 1e−3)
//   ①b linear black **offset** (071):          v = v + blackOffset          additive, linear units
//   ② exposure gain + WB gains:                v *= gain · wb              multiplicative
//   ③ blacks:  EV (first half of the travel), then EV + **level** (second half, 073C)
//   ④ whites:  EV (91 %) + level (9 %), soft shoulder   ±0.6 EV at display white, 0 below −2 EV
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
// `whites` is mostly EV with a small additive level term, because a scene-linear multiplier alone
// cannot make the white point *move* where the picture has almost no pixels.
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
// **Whites** (contract §4.2, unchanged constants): full weight at display white (0 EV), fading down to
// 0 at −2 EV (the shoulder on the dark side) and decaying as exp(−L/1 EV) above 0 (the shoulder on the
// HDR side: +1 EV 0.368, +4 EV 0.018). The additive level term rides the *same* weight, so both terms
// vanish together at −2 EV and the map is continuous at the 0 EV join where the two branches meet.
// Ratio at the end point: 91 % EV / 9 % level (measured, contract §4.2) — "whites moves the white
// point, it does not fog the picture".
//
// **The default path has no new arithmetic.** `blacks == 0 && whites == 0` selects the entry point
// without the knee code at all, exactly as 071 split off the trim: a branch inside the function
// (`if (blacks != 0.0)`) is *in the code* and the compiler is free to reorder around it — 071 measured
// that spelling moving 2980/12309 samples of the push document by an ULP. So the body is one templated
// function and the CPU picks an entry point:
//
//     kLevels  kKnee  kHybrid  kTrim   entry point                      dispatched when
//     false    false  false    false   s1_scene_linear                   no levels, no sliders, no trim
//     false    false  false    true    s1_scene_linear_trim              071's trim only
//     true     false  false    false   s1_scene_linear_levels            030 dropper, no trim
//     true     false  false    true    s1_scene_linear_levels_trim
//     false    true   false    false   s1_scene_linear_knee              sliders ≠ 0, |blacks| ≤ 50
//     false    true   false    true    s1_scene_linear_knee_trim
//     false    true   true     false   s1_scene_linear_hybrid            073C: |blacks| > 50
//     false    true   true     true    s1_scene_linear_hybrid_trim
//
// `kLevels` is 030's dropper, and it stays affine on purpose: the dropper's whole meaning is "make
// *this* sample black" (`blackLevel` → 0, `whiteLevel` → 1), which is a level and nothing else — the
// paint-by-number reading of an absolute sample. The two spellings never coexist: `LightGroup.levels`
// uses the absolute field when it is set and the sliders otherwise, and the UI clears one when the
// other is dragged, so a document is either on the level path or on the knee path. A hand-edited
// document that sets both gets the absolute level (the pre-073 precedence: the flag wins).
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
    // 派单 030 — the absolute levels: blackLevel, whiteLevel, hasBlack, hasWhite.
    // Read only by the `kLevels` instantiation; the knee entries never look at them.
    float4 d;
    // 派单 071 — the linear black offset in scene-linear units (x), 3 pad. Read only by the `kTrim`
    // instantiation.
    float4 e;
};

// The two ends of the blacks knee, in EV relative to display white, and the travel at the very bottom.
// -11.2 EV is far below anything the decoder produces as picture (the frames' p1 sits at −8…−15 EV);
// -4.2 EV (code 0.29) is below every measured p30, so the mid-tones are outside the window.
constant float B_EV = 3.0;
constant float B_LO_EV = -11.2;
constant float B_HI_EV = -4.2;

// 073C — the level half of the hybrid travel: the black point moves by up to ±B_LEV in scene-linear
// light over its own window (LEV_LO_EV … LEV_HI_EV), with a C¹ knee of LEV_KNEE at 0 on the crush side.
//
// `LEV_HI_EV = −4.4` and not `B_HI_EV = −4.2`: the level's window has to end below the *lowest p50 of
// the reference frames* (−4.36 EV, L1030408), or the level term itself would move a median and the
// "the level only works on the dark end" invariant would be a tolerance instead of a fact. The EV
// toe keeps its old −4.2 (073B, untouched); the level's top is 0.2 EV lower for that reason alone.
// B_LEV is pinned by the monotonicity constraint (§ header): B_LEV < 1.5/(d·ln2·2^(LEV_HI−d)) = 0.0056
// for the 2.5 EV window below. LEV_KNEE = 1e-3 is about one 8-bit code at the sRGB toe, i.e. the
// clip's corner is rounded over ~1.5 code — visible as a knee, invisible as a step.
constant float B_LEV = 0.005;
constant float LEV_LO_EV = -6.9;
constant float LEV_HI_EV = -4.4;
constant float LEV_KNEE = 1e-3;

// Whites (contract §4.2): ±0.6 EV, plus 0.06 of a linear level at full travel, over a 2 EV shoulder.
constant float W_EV = 0.6;
constant float W_LEV = 0.06;
constant float W_BAND = 2.0;
constant float W_TAU = 1.0;

// One body, seven instantiations. All four flags are compile-time constants, so an instantiation that
// is not for them contains none of their arithmetic — not "the arithmetic with a zero in it".
//
// 073C's `kHybrid` is the level half of the blacks travel. It is a separate flag rather than a
// runtime test on `m` for the same reason 071 split the trim off: the dispatch threshold
// (`|blacks| > 50`) is exactly where `m` is 0, so the two instantiations agree bit for bit at the
// boundary and the untouched one keeps 073B's source verbatim.
static inline float3 s1_toe(float3 x) {
    // C¹ rectifier: identity at or above +LEV_KNEE, exactly 0 at or below −LEV_KNEE, quadratic in
    // between (slope 0 → 1). The crush really does reach 0 — that is the "level" half — and the
    // corner is rounded instead of stepped.
    const float k = LEV_KNEE;
    float3 kx = clamp(x + k, 0.0, 2.0 * k);
    // `select(a, b, c)` is c ? b : a; a bool3 cannot be the condition of `?:` in Metal.
    return select(x, kx * kx / (4.0 * k), x < k);
}

template <bool kLevels, bool kKnee, bool kHybrid, bool kTrim>
static inline void s1_body(texture2d<float, access::read> src,
                           texture2d<float, access::write> dst,
                           constant S1Params &p,
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

    // ① 030 — the absolute level the dropper sampled, when the document has one. Affine and
    //    sign-preserving, byte for byte 019's remap: a dropper says "this sample is black", i.e. where
    //    0 is, and that is a level by definition. The slider path never reaches this code.
    if (kLevels) {
        float blk = p.d.x;
        float wht = p.d.y;
        v = (v - blk) / max(wht - blk, 1e-3);
    }

    // ①b 071 — the additive linear trim, **before** the gain so it is scaled by the same gain the
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
        float db = clamp(p.b.z, -100.0, 100.0) / 100.0;
        float dw = clamp(p.b.w, -100.0, 100.0) / 100.0;

        // One weight per pixel, from the pixel's luminance: applying a per-channel weight would move
        // each channel by a different EV and shift hue in the lifted toe.
        float luma = dot(v, float3(0.2126, 0.7152, 0.0722));
        float L = log2(max(luma, 1e-9));

        // blacks: 1 below B_LO, 0 above B_HI, smoothstep between (C¹ at both ends, so the toe and the
        // knee have no seam). `0 → 0`: pure multiplication never lifts black into grey.
        float wb = 1.0 - smoothstep(B_LO_EV, B_HI_EV, L);
        if (kHybrid) {
            // 073C — the second half of the travel. `mb` is exactly 0 for |blacks| ≤ 50, and the CPU
            // does not even pick this instantiation there, so the two paths agree at the join.
            float mb = smoothstep(0.5, 1.0, abs(db));
            v *= exp2(B_EV * db * (1.0 - 0.5 * mb) * wb);

            // The level: the black point moves by `off` linear units over its own 2.5 EV window
            // (−6.9 … −4.4 EV, the top deliberately under the EV toe's so no frame's median is inside
            // it). The window is a weight in L, not a clip, so it is continuous at both ends; `wl = 0`
            // makes `off` ±0 and the pixel bit-still.
            float wl = 1.0 - smoothstep(LEV_LO_EV, LEV_HI_EV, L);
            float off = B_LEV * db * mb * wl;
            float3 x = v + off;
            // A lift must not clip (invariant: t = +1 leaves no pixel at 0), so the toe is only taken
            // on the crush side. → the darkest pixels really reach 0 when the slider is pushed down.
            v = off < 0.0 ? s1_toe(x) : x;
        } else {
            // 073B, verbatim: the first half of the travel is this, bit for bit.
            v *= exp2(B_EV * db * wb);
        }

        // whites: full weight at display white, 0 at −2 EV, exp(−L/1 EV) above 0 (the HDR shoulder).
        // The level term is (Δw·|Δw|) — quadratic, so a small travel is nearly pure EV and only the
        // end of the travel actually moves the white point (contract §4.2). It rides `ww`, so it is
        // continuous at both ends of the window and does not touch the mid-tones.
        float ww = L <= 0.0 ? smoothstep(-W_BAND, 0.0, L) : exp(-L / W_TAU);
        v = v * exp2(W_EV * dw * ww) + float3(W_LEV * dw * abs(dw) * ww);
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

    dst.write(float4(v, c.a), gid);
}

// The default path: 019's arithmetic with an identity level, byte for byte. `RenderGraph` picks this
// one only when there is no dropper level, no slider travel and no trim.
kernel void s1_scene_linear(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant S1Params &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, false, false, false>(src, dst, p, gid);
}

// 071: the same body with the offset in it.
kernel void s1_scene_linear_trim(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant S1Params &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, false, false, true>(src, dst, p, gid);
}

// 030: the absolute level a dropper sampled. No knee: the two spellings never coexist.
kernel void s1_scene_linear_levels(texture2d<float, access::read> src [[texture(0)]],
                                   texture2d<float, access::write> dst [[texture(1)]],
                                   constant S1Params &p [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, false, false, false>(src, dst, p, gid);
}

kernel void s1_scene_linear_levels_trim(texture2d<float, access::read> src [[texture(0)]],
                                        texture2d<float, access::write> dst [[texture(1)]],
                                        constant S1Params &p [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    s1_body<true, false, false, true>(src, dst, p, gid);
}

// 073B: the black/white end points. Picked only when `blacks != 0 || whites != 0`.
kernel void s1_scene_linear_knee(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant S1Params &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, true, false, false>(src, dst, p, gid);
}

kernel void s1_scene_linear_knee_trim(texture2d<float, access::read> src [[texture(0)]],
                                      texture2d<float, access::write> dst [[texture(1)]],
                                      constant S1Params &p [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, true, false, true>(src, dst, p, gid);
}

// 073C: the second half of the blacks travel — the same EV toe plus the black-point level move.
// Picked only when `|blacks| > 50` (i.e. where `m` can be non-zero); below that the level term is
// exactly zero and `s1_scene_linear_knee` is the right instantiation, bit for bit.
kernel void s1_scene_linear_hybrid(texture2d<float, access::read> src [[texture(0)]],
                                   texture2d<float, access::write> dst [[texture(1)]],
                                   constant S1Params &p [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, true, true, false>(src, dst, p, gid);
}

kernel void s1_scene_linear_hybrid_trim(texture2d<float, access::read> src [[texture(0)]],
                                        texture2d<float, access::write> dst [[texture(1)]],
                                        constant S1Params &p [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]]) {
    s1_body<false, true, true, true>(src, dst, p, gid);
}
