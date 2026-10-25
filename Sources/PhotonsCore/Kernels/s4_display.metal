#include <metal_stdlib>
using namespace metal;

// S4 — display: primaries matrix, then the sRGB transfer function. Nothing after this.
//
// The matrix is linear sRGB → linear output primaries (identity for sRGB output). Encoding is the
// sRGB piecewise OETF, which Display P3 also uses. Values are clamped to [0, 1]: M1 is SDR output —
// EDR display is a separate, later concern that must not leak into the file.

struct DisplayParams {
    float4x4 m;   // linear sRGB → linear output primaries
    float4 a;     // identityMatrix, pad, pad, pad
};

static inline float srgb_encode(float v) {
    return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}

kernel void s4_display(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant DisplayParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    float3 v = max(c.rgb, 0.0);
    if (p.a.x < 0.5) {
        v = (p.m * float4(v, 0.0)).xyz;
    }
    v = clamp(v, 0.0, 1.0);
    float3 enc = float3(srgb_encode(v.x), srgb_encode(v.y), srgb_encode(v.z));
    dst.write(float4(enc, 1.0), gid);
}
