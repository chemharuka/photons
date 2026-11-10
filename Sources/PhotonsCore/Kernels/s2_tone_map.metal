#include <metal_stdlib>
#include "primaries.metal"
#include "tone_shape.metal"
using namespace metal;

// S2 — tone map: the three region lifts and the final clamp.
//
// 098 moved contrast out of this file: it is now S1.8/228 (`s1_8_contrast.metal`), a global
// gain-domain power curve in the display-referred domain, **after** this stage. What is left here
// is the three-band EV chain and the final clamp. It is exact identity at all zeros, which is what
// M1 has to prove.
//
// **306 replaced the complementary smoothstep windows with normalized overlapping Gaussians, and
// 306b put 高光 inside the same convex combination.**
//
//     c = (−6.8, −3.6, +0.2) EV,  σ = 1.9 EV
//     b_i = exp(−((L − c_i)/σ)²/2),  w_i = b_i / Σ_j b_j      (Σ w ≡ 1)
//
// The three weights overlap, so every slider drags the other two (the user's brief) instead of the
// disjoint ownership 085 had; the local slope on a seam no longer collapses (measured floors
// 0.717 / 0.765 / 0.774 versus 0.30). The convex combination cannot ring.
//
// **306b**: the band term is `dot(w, d)` with all three displacements. Above white the band tends to
// `d_high`; 299's `high_shoulder_ev` adds only the *difference* needed for `+4 EV → +1 EV`, with
// `k = 1 + c·h` (c solved on the CPU). At `L = 0` the high weight is 0.856, so 高光 now reaches the
// SDR near-white too — that is what 「其他的也类似」 asks for.
//
// Travel and its monotonicity gate are **CPU-side** (`S2Regions.travelEV`): 1.24 / 0.96 / 0.83 EV at
// full slider, with the exact `1 + Σ w_i′(L)·d_i` minimum checked on `L ∈ [−12, 0]`. Under the
// default travels the worst opposite-sign corner is 0.5287, so the gate never triggers. S2 receives
// `b.xyz` as the three EV displacements and `d.x` as the 高光 slope `k`.
//
// Direction (派单 008 A): Lightroom's, i.e. **all three region sliders brighten towards +**. The
// 074 two-window `region_weights` / `region_weights3` remain for `s1_6_local` (the mask path).
//
// Matte (派单 008 B): the canvas may be larger than the picture (letterbox) and everything outside the
// content rect is 0. A shadow/highlight lift treats 0 as a picture pixel, which is how "drag shadows"
// used to light up the viewport's background bars. Those pixels are written through untouched — an exact
// pixel identity, not an epsilon — so a test can assert the matte is 0.
//
// **Blacks/whites are not here** (派单 019). They are the two end points, a scene-linear quantity, so
// they live in S1 (`s1_scene_linear`, 073B). What is left here is the "normal colour grading" side of
// the same distinction.

struct S2Params {
    // 306b — dShadow, dMid, dHigh (EV), identity. `S2Regions.travelEV` has already multiplied all
    // three by the travel and applied the monotonicity gate.
    float4 b;
    // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    float4 c;
    // 306b — `.x` is the 高光 slope `k` (1 = identity), from `S2Regions.highSlope`; `.y` is 320's
    // **picture ceiling** (linear, `DisplayOptions.highlightCeiling`); `.zw` unused.
    // The struct grew from 32 to 48 bytes when 高光 entered the band term.
    float4 d;
};

kernel void s2_tone_map(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant S2Params &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    // 320 — the ceiling is applied on **both** branches. The copy branch is the identity document's
    // byte-for-byte path and stays one for every value at or below the ceiling; light above it is
    // what the display-referred tail guards used to clip at a hard 4.0 (`s3_10_sharpen.metal:402`),
    // and the picture's own top is where that is decided now. `.y` is the linear ceiling; `0` means
    // "caller predates 320" and keeps the historical 4.0 (a real ceiling is `2^0 = 1` at the lowest).
    float ceiling = p.d.y > 0.0 ? p.d.y : 4.0;
    if (p.b.w > 0.5) {
        dst.write(float4(min(c.rgb, ceiling), c.a), gid);
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

    // **Keep the sign.** The decoder hands us scene-linear values that go *below* the black point.
    // Those pixels are not dead — inside that band the 32×32 block means carry structure, which is
    // exactly the detail Lightroom can lift and we could not. Clamping here deleted it before any
    // slider saw it. (Since 019 the lift that reaches into that band is S1's black end point; this
    // stage must still not clamp it away before its own maths.)
    float3 v = c.rgb;

    // 306/306b: the normalized Gaussian bands (`tone_shape.metal#band_weights`), on `L = log2(luma)`
    // — EV relative to display white, the histogram's own HDR axis. `p.b.xyz` is the gated EV travel
    // from `S2Regions`; all three bands enter, so 高光 drags its neighbours too. Above white the band
    // tends to `d_high` and the shoulder below supplies only the remaining HDR-tail difference.
    float3 w = band_weights(v);
    float luma = max(dot(max(v, 0.0), kWorkingLumaWeights), 1e-9);
    float L = log2(luma);
    // 299/306b: the difference shoulder above white. `p.d.x` is `k = S2Regions.highSlope(...)`;
    // `L ≤ 0` still makes this term exactly 0, but the band term is not (w_high(0) = 0.856).
    v *= exp2(dot(w, p.b.xyz) + high_shoulder_ev(L, p.d.x));
    // LR convention (派单 008 A): `+` brightens the named zone, `−` pulls it down.

    // The clamp stays **here**, at the end of the tone map, and not one line earlier: a sub-black
    // value that a lift has pulled above zero is real picture by now and must survive; whatever is
    // still below zero is what the display would clip anyway.
    //
    // 320 adds the **upper** half of the same sentence: this is where the picture's ceiling lives
    // (`DisplayOptions.highlightCeiling`), so every document — with or without 锐化/纹理/颗粒 — stops at
    // the same brightness, and the histogram and the pointer's readout (both measured after this
    // pass) stop there too. The value is the user's, not a literal.
    dst.write(float4(min(max(v, 0.0), ceiling), c.a), gid);
}
