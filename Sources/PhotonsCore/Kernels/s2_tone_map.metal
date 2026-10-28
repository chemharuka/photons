#include <metal_stdlib>
#include "primaries.metal"
#include "tone_shape.metal"
using namespace metal;

// S2 — tone map: the three region lifts and the final clamp.
//
// 098 moved contrast out of this file: it is now S1.8 (`s1_8_contrast.metal`), a multiscale
// edge-aware decomposition of `Y` in the scene-linear domain, **before** this stage. What is left here
// is the three-window EV chain (085) — 阴影 / 中间调 / 高光 — and the final clamp. It is exact identity
// at all zeros, which is what M1 has to prove.
//
// **085 replaced the two-window layout with three complementary windows.**
//
//     shadow  1 − a,  a = smoothstep(−5.0, −3.2, L)     (deep shadow → mid)
//     mid     a(1 − b), b = smoothstep(−2.6, −1.0, L)  (mid → high)
//     high    b(1 − c), c = smoothstep(−1.2, 0.0, L)   (high → display white, closing the top)
//
// Because `a` reaches 1 before `b` starts, the three weights sum to 1 over the whole shadow→high run:
// every luminance has a full-weight owner and there is no gap. Above white `c = 1` makes `high = 0`
// and the gain is exactly 1, so HDR samples pass through bit for bit (079 §4: S2 has no upper clamp).
//
// Travel and its monotonicity gate are **CPU-side** (`S2Regions.travelEV`): 0.90 / 0.70 / 0.60 EV at
// full slider, compressed by one common factor when opposite-sign combinations would push the
// derivative below 0.5. The kernel receives EV directly (`S2Params.b.xyz`) and only weights and
// exponentiates.
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
    // 085 — EV displacements, not slider positions: dShadow, dMid, dHighlight, identity.
    // `S2Regions.travelEV` has already multiplied by the travel and applied the monotonicity gate;
    // the kernel only weights and takes one `exp2`.
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

    // 085: three complementary windows (`tone_shape.metal#region_weights3`), all on
    // `L = log2(luma)` — EV relative to display white, the histogram's own HDR axis — so a window's
    // width is exposure-invariant. Every luminance has a full-weight owner, and above white the high
    // window closes, so HDR samples pass through with gain exactly 1. `p.b.xyz` is the gated EV travel
    // from `S2Regions`.
    float3 w = region_weights3(v);
    // LR convention (派单 008 A): `+` brightens the named zone, `−` pulls it down.
    v *= region_gain3(w, p.b.xyz);

    // The clamp stays **here**, at the end of the tone map, and not one line earlier: a sub-black
    // value that a lift has pulled above zero is real picture by now and must survive; whatever is
    // still below zero is what the display would clip anyway.
    dst.write(float4(max(v, 0.0), c.a), gid);
}
