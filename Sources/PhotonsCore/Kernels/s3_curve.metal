#include <metal_stdlib>
using namespace metal;

// S3a — tone curve: composite RGB table first, then the per-channel tables (Lightroom order).
//
// The table is built on the CPU once per parameter change (CurveLUT, monotone cubic) and uploaded
// as a 4 × 1024 float buffer; the kernel only interpolates. Keeping curve *evaluation* off the GPU
// makes the parameter→pixels mapping testable in a unit test.

struct CurveParams {
    float4 a;   // identity, tableSize, pad, pad
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
