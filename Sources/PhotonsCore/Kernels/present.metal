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

struct PresentParams {
    float4 a;   // linearize, pad, pad, pad
    float4 b;   // the sampled window: xy = origin, zw = size, normalised texture coordinates
};

struct PresentOut {
    float4 position [[position]];
    float2 uv;
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

fragment float4 present_fragment(PresentOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant PresentParams &p [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 c = src.sample(smp, in.uv);
    float3 v = max(c.rgb, 0.0);
    if (p.a.x > 0.5) {
        v = float3(srgb_encode_inverse(v.x), srgb_encode_inverse(v.y), srgb_encode_inverse(v.z));
    } else {
        v = min(v, 1.0);
    }
    return float4(v, 1.0);
}
