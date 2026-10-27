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
    float4 d;   // the picture's rect **on the canvas**, normalised: xy = origin, zw = size. Two
                // meanings, one per fragment: without a backdrop it is where the photograph is (054's
                // matte is everything outside it); with a backdrop it is the main window, the rect the
                // feather ramps inside of.
    float4 e;   // xy = the feather width per axis (canvas-normalised), z = has backdrop, w = pad
};

// MARK: - 054, the canvas matte

// The bands the user sees around a fitted picture are **not** a layer colour: S2/S4 write float4(0)
// for every pixel that is not the photograph, so that black is *inside the canvas texture*, and no
// layer background can ever show through it. The matte is therefore painted here, in the present
// pass, where `p.d` says where the picture is — and the texture keeps its zeros, which is what leaves
// the photograph's bytes and the histogram (measured on S4 over `pictureRect`) untouched.
//
// Display-encoded 15/255 = #0F0F0F: `present_transfer` turns it into linear light for the 16-bit
// drawable (an EDR-capable layer stores linear) and leaves it clamped for the 8-bit one, so both paths
// put the same #0F0F0F on the screen. Must equal `CanvasPresenter.CanvasMatte.eightBitValue`;
// `CanvasMatteGreyTests` parses this file and asserts the two agree.
constant float3 kCanvasMatteDisplay = float3(15.0 / 255.0);

// The rect test's tolerance, in canvas-normalised units: 1/100 000 of a canvas edge — 0.04 px on a 4K
// canvas, far below a pixel, so no photograph pixel can fall outside its own rect — and wide enough
// that a rect *meant* to cover the canvas cannot lose its last row or column to rounding.
constant float kCanvasMatteEpsilon = 1e-5;

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

/// 025's presentation, plus 054's matte: the picture where `p.d` says it is, `#0F0F0F` everywhere else
/// on the canvas.
///
/// The picture half is untouched — one sample, `clamp_to_edge`, the same `present_transfer` — so every
/// photograph pixel is byte-for-byte what 025 wrote. Only the fragments **outside** the picture's rect
/// take the new path, and they used to be the texture's own `float4(0)`.
///
/// `p.d == (0, 0, 1, 1)` means "the picture is the whole canvas" — the identity window, every shrink
/// with `clamp_to_edge`, and every caller that passes no picture rect — and then no fragment is
/// outside, which is exactly why the pinned 025 hashes still hold.
fragment float4 present_fragment(PresentOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant PresentParams &p [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 c = src.sample(smp, in.uv);
    // Where on the canvas this fragment is: the inverse of the vertex stage's `uv` map, with the same
    // floored divisor as `present_fragment_backdrop` (a zero-sized window cannot produce a NaN canvas).
    float2 size = select(float2(1.0), p.b.zw, abs(p.b.zw) > float2(1e-9));
    float2 canvasUV = (in.uv - p.b.xy) / size;
    // Distance to the picture's edge on each axis; negative on either means outside the picture.
    float2 slack = min(canvasUV - p.d.xy, p.d.xy + p.d.zw - canvasUV);
    if (min(slack.x, slack.y) < -kCanvasMatteEpsilon) {
        return float4(present_transfer(kCanvasMatteDisplay, p), 1.0);
    }
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

/// The shrink path with a backdrop: the main frame where it reaches, the low-res whole picture where
/// it does not, cross-faded over the feather.
///
/// 054's matte deliberately does **not** apply here: outside the main window this path must show the
/// picture's own low-resolution continuation (037/053), not the canvas colour. Choosing this fragment
/// is choosing the picture, so the two rules cannot fight.
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
    float2 backdropUV = p.c.xy + canvasUV * p.c.zw;
    float4 far = backdrop.sample(smp, saturate(backdropUV));
    float4 near = src.sample(smp, in.uv);
    float4 c = mix(far, near, backdrop_weight(canvasUV, p));
    return float4(present_transfer(c.rgb, p), 1.0);
}
