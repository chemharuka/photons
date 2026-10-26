#include <metal_stdlib>
using namespace metal;

// S3a — tone curve: composite RGB table first, then the per-channel tables (Lightroom order).
//
// The table is built on the CPU once per parameter change (CurveLUT, monotone cubic) and uploaded
// as a 4 × 1024 float buffer; the kernel only interpolates. Keeping curve *evaluation* off the GPU
// makes the parameter→pixels mapping testable in a unit test.
//
// Matte (派单 008 C): the same bug S2 had, one stage further down. A curve whose black end is
// dragged up — `CurvePoint(0, 0.1)`, the normal way to "lift the blacks" — maps the letterbox's 0
// to 0.1, i.e. 0.349 in display units after S4's sRGB encode, and the viewport's background bars
// turn grey. The LUT is not wrong: the user did ask for `f(0) = 0.1`, but only about the *picture*.
// So the content rect is a guard, and pixels outside it are written through untouched — an exact
// pixel identity, not an epsilon. Same convention as S2's `c` and S3c's `c`: canvas pixels,
// `origin = (canvas − content) / 2`.

struct CurveParams {
    float4 a;   // identity, tableSize, pad, pad
    float4 b;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

static inline float lut_sample(device const float *lut, int offset, int n, float x) {
    float t = clamp(x, 0.0, 1.0) * float(n - 1);
    int i0 = int(floor(t));
    int i1 = min(i0 + 1, n - 1);
    float f = t - float(i0);
    return mix(lut[offset + i0], lut[offset + i1], f);
}

kernel void s3_curve(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant CurveParams &p [[buffer(0)]],
                     device const float *lut [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.a.x > 0.5) {
        dst.write(c, gid);
        return;
    }

    // Outside the content rect: the matte, written back unchanged (S0 leaves it at 0).
    float2 g = float2(gid);
    if (g.x < p.b.x || g.y < p.b.y || g.x >= p.b.x + p.b.z || g.y >= p.b.y + p.b.w) {
        dst.write(c, gid);
        return;
    }

    int n = int(p.a.y);
    float3 v = clamp(c.rgb, 0.0, 1.0);
    v = float3(lut_sample(lut, 0, n, v.x),
               lut_sample(lut, 0, n, v.y),
               lut_sample(lut, 0, n, v.z));
    v = float3(lut_sample(lut, n, n, v.x),
               lut_sample(lut, 2 * n, n, v.y),
               lut_sample(lut, 3 * n, n, v.z));
    dst.write(float4(v, c.a), gid);
}
