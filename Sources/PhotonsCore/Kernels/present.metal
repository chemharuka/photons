#include <metal_stdlib>
using namespace metal;

// On-screen presentation of an S4 output texture.
//
// Not part of the five-stage editing graph: S4 hands back a texture in display encoding
// (rgba16Float, sRGB OETF already applied), and this pass copies it into a drawable. The two modes
// exist because the drawable format decides the transfer function of the values it stores:
//
//   linearize = 1  → drawable is rgba16Float + extendedLinearDisplayP3, so the stored value must be
//                    linear light. Values above 1 are kept: that is the EDR headroom S4 preserved.
//   linearize = 0  → drawable is bgra8Unorm + sRGB (the fallback for a layer that refuses the
//                    16-bit format), so the value stays display-encoded and is clamped to 1.
//
// M3 keeps `wantsExtendedDynamicRangeContent = false`, so the 16-bit path is still SDR on screen;
// opening EDR in M3.5 flips that one boolean and sets DisplayOptions.headroom.
//
// 037 adds the **backdrop**: a low-resolution copy of the whole picture, sampled outside the main
// frame's window while a shrink is in flight, so the canvas around a shrinking picture shows the
// picture's own low-res continuation instead of a band of stretched edge pixels (what 025's
// clamp_to_edge produced, and what the user reported seeing).
//
// The backdrop lives in a **second fragment function**, not in a branch inside `present_fragment`.
// A uniform branch still costs: the GPU cannot predicate a texture fetch, so it executes the fetch and
// selects afterwards — measured at +0.03 ms on a 4.10 Mpx canvas, for a case where the caller passed
// no backdrop at all. Two entry points, one chosen per draw by `CanvasPresenter`, keep the no-backdrop
// path at exactly 025's instructions.

// The CPU half of this struct is `CanvasPresenter.PresentParams`. The two are one contract handed
// over as raw bytes with no compiler check between them, so every field is a `float4` at a fixed
// offset (0, 16, 32, 48, 64; stride 80) and `BackdropPresenterTests` pins both sides against it.
struct PresentParams {
    float4 a;   // linearize, pad, pad, pad
    float4 b;   // the main frame's sampled window: xy = origin, zw = size, normalised texture coords
    float4 c;   // the backdrop's sampled window, same encoding; read only by the backdrop fragment
    float4 d;   // the main frame's rect **on the canvas**, normalised: xy = origin, zw = size
    float4 e;   // xy = the feather width per axis (canvas-normalised), z = has backdrop, w = pad
};

struct PresentOut {
    float4 position [[position]];
    float2 uv;   // which texel of the main frame this fragment reads
};

vertex PresentOut present_vertex(uint vid [[vertex_id]],
                                constant PresentParams &p [[buffer(0)]]) {
    // Full-screen triangle strip in clip space; y+ is up, texture v=0 is the top row.
    const float2 corners[4] = { float2(-1.0, 1.0), float2(1.0, 1.0), float2(-1.0, -1.0), float2(1.0, -1.0) };
    const float2 coords[4]  = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) };
    PresentOut o;
    o.position = float4(corners[vid], 0.0, 1.0);
    // The quad **always** covers the whole drawable; `b` decides which part of the texture it reads.
    // With no window `b` is (0, 0, 1, 1) and this is the identity the pre-window pass had. `b` is
    // deliberately *not* clamped to [0, 1]: on a shrink the window is larger than the texture, and the
    // sampler's clamp_to_edge is what fills the canvas with the picture's own edge pixels instead of
    // an unrendered band.
    o.uv = p.b.xy + coords[vid] * p.b.zw;
    return o;
}

static inline float srgb_encode_inverse(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// What the drawable stores for a sampled value: linear light for the 16-bit layer, clamped display
// encoding for the bgra8 fallback. Shared by both fragments so the two paths cannot drift.
static inline float3 present_transfer(float3 rgb, constant PresentParams &p) {
    float3 v = max(rgb, 0.0);
    if (p.a.x > 0.5) {
        v = float3(srgb_encode_inverse(v.x), srgb_encode_inverse(v.y), srgb_encode_inverse(v.z));
    } else {
        v = min(v, 1.0);
    }
    return v;
}

/// 025's presentation, unchanged: one sample, and `clamp_to_edge` extends the picture's own edge over
/// the rest of the canvas when the window is larger than the texture.
fragment float4 present_fragment(PresentOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant PresentParams &p [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 c = src.sample(smp, in.uv);
    return float4(present_transfer(c.rgb, p), 1.0);
}

// 0 at or outside the main rect's edge, 1 a feather-width inside it, a straight ramp in between —
// measured on the nearest edge, so a corner ramps on both axes. The ramp is *inside* the picture, so
// the picture's outer two pixels fade into the low-res whole instead of ending on a hard step.
static inline float backdrop_weight(float2 canvasUV, constant PresentParams &p) {
    float2 inside = min(canvasUV - p.d.xy, p.d.xy + p.d.zw - canvasUV);
    float2 f = max(p.e.xy, float2(1e-6));
    return saturate(min(inside.x / f.x, inside.y / f.y));
}

// The canvas colour outside the picture, display-encoded `#0F0F0F` (15/255) — the same value 054
// paints around a fitted picture. Declared by 058 ahead of that merge; `CanvasMatte` in
// `CanvasPresenter` is the CPU half and the two must agree (`CanvasMatteGreyTests` parses both once
// 054 lands). Running it through `present_transfer` is what makes it the right number for either
// drawable format: linear light for the 16-bit layer, the code itself for the 8-bit one.
constant float3 kCanvasMatteDisplay = float3(15.0 / 255.0);

// How far outside `[0, 1]` a backdrop UV may be and still count as inside, in picture-normalised
// units: 1/100 000 of the picture — 0.04 px on a 4096-px whole-picture texture. Wide enough that the
// last row/column of a picture that *does* fill the canvas is never mistaken for the outside (which
// would ring a fitted picture with one line of matte), far below a texel so no real "outside" survives.
constant float kPictureEdgeEpsilon = 1e-5;

/// The shrink path with a backdrop: the main frame where it reaches, the low-res whole picture where
/// it does not, cross-faded over the feather.
///
/// **058 — what is outside the picture is the matte, not the picture's edge.** 037–053 sampled the
/// backdrop through `saturate(backdropUV)`, so every fragment whose UV had left `[0, 1]` got the
/// nearest edge texel: one column of the photograph smeared across the whole band. That is only ever
/// right when the picture continues past its own edge, which it never does — outside the picture there
/// is canvas, and the canvas has a colour (`#0F0F0F`, 054's matte). So the fetch is kept (a GPU cannot
/// predicate a texture read) and its result is *discarded* where the UV is outside, which is a select
/// on the same two values, not a second sample: the cost of this fragment is unchanged.
///
/// The feather stays **inside** the picture, where its two pixels are: at a fragment outside the
/// picture `backdrop_weight` is 0, so the matte is what is drawn; one feather-width into the picture
/// the frame takes over. The photograph's own edge therefore still meets the frame over a ramp
/// instead of a step, and the band around it is the canvas colour.
fragment float4 present_fragment_backdrop(PresentOut in [[stage_in]],
                                          texture2d<float> src [[texture(0)]],
                                          texture2d<float> backdrop [[texture(1)]],
                                          constant PresentParams &p [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    // The canvas position is the inverse of the vertex stage's map, computed here rather than carried
    // in a third varying. A zero-sized window cannot produce a meaningful rect (`makeParams` clears the
    // has-backdrop flag for one), but this function is chosen by the *binding*, not by that flag, so the
    // divisor is floored rather than trusted: a NaN canvas would paint the whole drawable black.
    float2 size = select(float2(1.0), p.b.zw, abs(p.b.zw) > float2(1e-9));
    float2 canvasUV = (in.uv - p.b.xy) / size;
    // `p.c` is the whole picture's window (058 — the frame's window composed with where the frame
    // texture sits on the picture), so this UV is in the picture's own coordinates and `[0, 1]` is the
    // picture's edge.
    float2 backdropUV = p.c.xy + canvasUV * p.c.zw;
    float4 onPicture = backdrop.sample(smp, saturate(backdropUV));
    // Outside by more than the tolerance on either axis ⇒ there is no picture here.
    float2 outside = max(-backdropUV, backdropUV - 1.0);
    bool beyondEdge = max(outside.x, outside.y) > kPictureEdgeEpsilon;
    float4 far = beyondEdge ? float4(kCanvasMatteDisplay, 1.0) : onPicture;
    float4 near = src.sample(smp, in.uv);
    float4 c = mix(far, near, backdrop_weight(canvasUV, p));
    return float4(present_transfer(c.rgb, p), 1.0);
}
