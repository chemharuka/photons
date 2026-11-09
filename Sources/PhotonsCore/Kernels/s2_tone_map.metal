#include <metal_stdlib>
#include "primaries.metal"
#include "tone_shape.metal"
using namespace metal;

// S2 — tone map: the three region lifts and the final clamp.
//
// 098 moved contrast out of this file: it is now S1.8/228 (`s1_8_contrast.metal`), a global
// gain-domain power curve in the display-referred domain, **after** this stage. What is left here
// is the three-window EV chain (085) — 阴影 / 中间调 / 高光 — and the final clamp. It is exact identity
// at all zeros, which is what M1 has to prove.
//
// **085 replaced the two-window layout with three complementary windows.**
//
//     shadow  1 − a,  a = smoothstep(−5.4, −3.9, L)     (deep shadow → mid)
//     mid     a(1 − b), b = smoothstep(−2.4, −0.9, L)  (mid → high)
//     high    b(1 − c), c = smoothstep(+4.0, +6.0, L)  (high → white, closing above the HDR range)
//
// Because `a` reaches 1 before `b` starts, the three weights sum to 1 over the whole shadow→high run:
// every luminance has a full-weight owner and there is no gap. **299 replaces the 124 closure for
// the global 高光 slider**: the slider no longer multiplies the high weight by an EV displacement.
// It sets a slope `k` and the kernel applies `high_shoulder_ev` above display white (see
// `tone_shape.metal`). That is what makes 「+4 EV → +1 EV」 possible: a displacement would need 3 EV
// through the HDR tail, while a shoulder changes the asymptote without folding the map. `a` and `b`
// (阴影 / 中间调), their travels and the monotonicity gate are unchanged; the high weight in
// `region_weights3` is still used by the mask path (`s1_6_local`).
//
// Travel and its monotonicity gate are **CPU-side** (`S2Regions.travelEV`): 0.90 / 0.70 / 0.60 EV at
// full slider, compressed by one common factor when opposite-sign combinations would push the
// derivative below 0.400. S2 receives `b.xy` as EV and `b.z` as the 高光 **slope** `k`.
//
// Direction (派单 008 A): Lightroom's, i.e. **all three region sliders brighten towards +**.
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
    // 085/299 — dShadow (EV), dMid (EV), 高光 slope `k` (1 = identity), identity.
    // `S2Regions.travelEV` has already multiplied the first two by the travel and applied the
    // monotonicity gate; `k` comes from `S2Regions.highSlope`. Layout is unchanged (32-byte stride).
    float4 b;
    // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    float4 c;
};

kernel void s2_tone_map(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant S2Params &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.b.w > 0.5) {
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

    // **Keep the sign.** The decoder hands us scene-linear values that go *below* the black point.
    // Those pixels are not dead — inside that band the 32×32 block means carry structure, which is
    // exactly the detail Lightroom can lift and we could not. Clamping here deleted it before any
    // slider saw it. (Since 019 the lift that reaches into that band is S1's black end point; this
    // stage must still not clamp it away before its own maths.)
    float3 v = c.rgb;

    // 085: the shadow/mid windows (`tone_shape.metal#region_weights3`), on `L = log2(luma)` — EV
    // relative to display white, the histogram's own HDR axis — so a window's width is
    // exposure-invariant. `p.b.xy` is the gated EV travel from `S2Regions`.
    float3 w = region_weights3(v);
    float luma = max(dot(max(v, 0.0), kWorkingLumaWeights), 1e-9);
    float L = log2(luma);
    // 299: 高光 is the C¹ slope shoulder above white, not the third weight times a displacement.
    // `p.b.z` is `k = S2Regions.highSlope(...)`; `L ≤ 0` makes the shoulder exactly 0, so the SDR
    // image is untouched.
    v *= exp2(dot(w.xy, p.b.xy) + high_shoulder_ev(L, p.b.z));
    // LR convention (派单 008 A): `+` brightens the named zone, `−` pulls it down.

    // The clamp stays **here**, at the end of the tone map, and not one line earlier: a sub-black
    // value that a lift has pulled above zero is real picture by now and must survive; whatever is
    // still below zero is what the display would clip anyway.
    dst.write(float4(max(v, 0.0), c.a), gid);
}
