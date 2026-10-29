#include <metal_stdlib>
using namespace metal;

// On-screen presentation of an S4 output texture — **geometry, not a fragment test** (067).
//
// Not part of the five-stage editing graph: S4 hands back a texture in display encoding
// (rgba16Float, sRGB OETF already applied), and this pass copies a part of it into a drawable.
//
// The one rule this file exists to keep:
//
//   **A fragment never asks "is this pixel the photograph?"** It draws whatever texel its quad
//   points at, and nothing else. Where the photograph *is* is a rectangle, and a rectangle is
//   geometry: the CPU turns it into a vertex quad, and the canvas around it is the render pass's
//   `MTLClearColor`. 054–065 answered that question per fragment from `photoRect`, which meant
//   every present call site had to be told the rect and be told it in the right coordinate space;
//   a call site that forgot drew the frame's `float4(0)` letterbox as **black**, and one that passed
//   the previous frame's rect kept a **fixed grey band** on screen while a zoom moved the picture.
//   Both are impossible here: the only thing that says where the picture is, is where its quad is
//   drawn, and a quad is either there or it is not.
//
// Two draws, one pipeline, one fragment:
//
//   · the **backdrop** quad (optional) — the whole picture at low resolution, sampling through its
//     picture-space window;
//   · the **picture** quad — the photograph, sampling the frame texture through the frame's window.
//
// They are drawn in that order into one encoder with no blending, so the picture simply covers the
// backdrop where the two overlap. The rest of the canvas keeps the pass's clear colour
// (`CanvasPresenter.CanvasMatte`, `#0F0F0F`).
//
// The drawable format decides the transfer function of the values it stores:
//
//   linearize = 1  → drawable is rgba16Float + extendedLinearDisplayP3, so the stored value must be
//                    linear light. Values above 1 are kept: that is the EDR headroom S4 preserved.
//   linearize = 0  → drawable is bgra8Unorm + sRGB (the fallback for a layer that refuses the
//                    16-bit format), so the value stays display-encoded and is clamped to 1.
//
// M3 keeps `wantsExtendedDynamicRangeContent = false`, so the 16-bit path is still SDR on screen;
// opening EDR in M3.5 flips that one boolean and sets DisplayOptions.headroom.

// The CPU half of this struct is `CanvasPresenter.PresentParams`. The two are one contract handed
// over as raw bytes with no compiler check between them, so every field is a `float4` at a fixed
// offset (0, 16, 32; stride 48) and `BackdropPresenterTests` pins both sides against it.
struct PresentParams {
    float4 quad;     // the rectangle this draw covers, **canvas-normalised**: xy = origin, zw = size.
                     // The picture's quad for the picture draw, the whole picture's for the backdrop.
    float4 window;   // the uv window the quad reads: xy = origin, zw = size, texture-normalised.
                     // `uv = window.xy + canvasPosition · window.zw` — the window is a function of the
                     // canvas position, not of the quad's local coordinates, because the texture is
                     // canvas-sized and the window is the map that places it there.
    float4 misc;     // x = linearize; yzw unused padding, so the struct stays three float4s (stride 48).
};

struct PresentOut {
    float4 position [[position]];
    float2 uv;   // which texel the bound texture this fragment reads
};

vertex PresentOut present_vertex(uint vid [[vertex_id]],
                                constant PresentParams &p [[buffer(0)]]) {
    // Triangle strip in the quad's own [0, 1]², y down (texture order). The same four corners for
    // every draw: what moves is the rectangle they are placed in, not the topology.
    const float2 corners[4] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) };
    float2 local = corners[vid];
    // Where on the canvas this corner is, normalised, y down.
    float2 canvasPosition = p.quad.xy + local * p.quad.zw;
    PresentOut o;
    // Clip space: x −1…1 left to right, y +1…−1 top to bottom (the pass draws y down).
    o.position = float4(canvasPosition.x * 2.0 - 1.0, 1.0 - canvasPosition.y * 2.0, 0.0, 1.0);
    // The window is expressed against the **canvas**, so the uv of a corner follows from where the
    // corner is, not from which corner it is. A quad that covers the whole canvas therefore reads
    // exactly the window, which is what makes the covering case bit-identical to 025.
    o.uv = p.window.xy + canvasPosition * p.window.zw;
    return o;
}

static inline float srgb_encode_inverse(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// What the drawable stores for a sampled value: linear light for the 16-bit layer, clamped display
// encoding for the bgra8 fallback. One function, one path — there is no second fragment any more.
static inline float3 present_transfer(float3 rgb, constant PresentParams &p) {
    float3 v = max(rgb, 0.0);
    if (p.misc.x > 0.5) {
        v = float3(srgb_encode_inverse(v.x), srgb_encode_inverse(v.y), srgb_encode_inverse(v.z));
    } else {
        v = min(v, 1.0);
    }
    return v;
}

/// One sample, transferred. This is the whole of the pass: no matte branch, no `photoRect`, no
/// edge epsilon, no feather, no "outside the picture" special case. The texture bound here is the
/// picture for the picture quad and the low-resolution whole picture for the backdrop quad.
///
/// `clamp_to_edge` is kept as a guard, not as a mechanism: the quad's uv range is inside `[0, 1]` by
/// construction (`CanvasPresenter.PresentRequest` derives the quad from this same window), so the
/// sampler never has to invent an edge — and if a future caller hands in a quad that does reach past
/// the texture, one clamped texel is a far better failure than an unpainted band.
fragment float4 present_fragment(PresentOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant PresentParams &p [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 rgb = max(src.sample(smp, in.uv).rgb, 0.0);
    // 143b: the white-balance preview is a real render (S1…S4), so this pass only transfers the
    // frame. There is no display-domain gain and no second branch to prove it absent.
    return float4(present_transfer(rgb, p), 1.0);
}
