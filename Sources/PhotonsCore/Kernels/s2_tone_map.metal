#include <metal_stdlib>
using namespace metal;

// S2 — tone map: parametric curve (Lightroom's Light panel), display-referred output in 0…1+.
//
// Order: blacks/whites remap → contrast around the scene-linear mid-grey pivot (0.18) → region
// lifts for shadows/highlights weighted by output luminance. This is a parameterisation of the
// classic "light panel" behaviour, not a film emulation: it is monotone in every slider and exact
// identity at all zeros, which is what M1 has to prove.

struct S2Params {
    float4 a;   // blacks, whites, contrast, pivot
    float4 b;   // highlights, shadows, identity, pad
};

kernel void s2_tone_map(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant S2Params &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.b.z > 0.5) {
        dst.write(c, gid);
        return;
    }

    float3 v = max(c.rgb, 0.0);

    float blk = p.a.x / 100.0 * 0.15;
    float wht = 1.0 + p.a.y / 100.0 * 0.15;
    v = max((v - blk) / max(wht - blk, 1e-3), 0.0);

    float pivot = max(p.a.w, 1e-3);
    float gamma = exp2(p.a.z / 100.0 * 2.0);
    v = pivot * pow(max(v, 1e-6) / pivot, gamma);

    float lum = dot(v, float3(0.2126, 0.7152, 0.0722));
    float wShadow = 1.0 - smoothstep(0.0, 0.5, lum);
    float wHighlight = smoothstep(0.5, 1.0, lum);
    float liftShadow = exp2(p.b.y / 100.0 * 0.8 * wShadow);
    float liftHighlight = exp2(-p.b.x / 100.0 * 0.8 * wHighlight);
    v *= liftShadow * liftHighlight;

    dst.write(float4(max(v, 0.0), c.a), gid);
}
