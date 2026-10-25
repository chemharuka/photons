#include <metal_stdlib>
using namespace metal;

// S1.6 — local adjustments, between S1 (scene linear) and S2 (tone map).
//
// Why here (§3.1): local exposure and white balance are *scene-linear* gains. Applied after S2 they
// would multiply data the tone curve had already compressed, and highlights pressed flat by the
// curve could not come back. The predicate is still evaluated upstream in S1.5 so it sees the
// globally exposed frame; this pass only reads, per pixel, the atlas coverage and the mask's own
// slider set.
//
// Pointwise by construction: every stage in this kernel reads exactly the pixel it writes, which is
// what keeps 005d's tile recomputation honest (no halo).
//
// Real identity branch (M1-6): if no mask has an active adjustment, or a given mask's adjustments
// are neutral (or `amount == 0`, or its coverage is 0), the source pixel is written unchanged.
// That is what makes "a mask with no adjustments" bit-exact against "no mask at all".

struct LocalParams {
    int4 a;   // anyActive, maskCount, pad, pad
};

struct LocalAdjustDesc {
    float4 a;   // gainR, gainG, gainB, amountScale (0…1, already includes adjustments.amount)
    float4 b;   // contrast, highlights, shadows, whites
    float4 c;   // blacks, hueDegrees, saturation, enabled
};

static inline float3 rotate_about_grey(float3 v, float degrees) {
    // Rodrigues rotation around the neutral axis (1,1,1)/√3: chroma rotates, luma is preserved.
    const float3 n = float3(0.5773502691896258);
    float ang = degrees * M_PI_F / 180.0;
    float cs = cos(ang);
    float sn = sin(ang);
    return v * cs + cross(n, v) * sn + n * dot(n, v) * (1.0 - cs);
}

static inline float3 local_adjust(float3 v, LocalAdjustDesc d) {
    // 1. Scene-linear gains: exposure and the Planckian white-balance approximation.
    v = max(v, 0.0) * d.a.xyz;

    // 2. Tone shaping, the same parameterisation S2 uses (blacks/whites remap → contrast around the
    //    0.18 scene pivot → shadow/highlight lifts), applied before the tone curve by design.
    float blk = d.c.x / 100.0 * 0.15;
    float wht = 1.0 + d.b.w / 100.0 * 0.15;             // whites
    v = max((v - blk) / max(wht - blk, 1e-3), 0.0);

    float gamma = exp2(d.b.x / 100.0 * 2.0);            // contrast
    v = 0.18 * pow(max(v, 1e-6) / 0.18, gamma);

    float lum = dot(v, float3(0.2126, 0.7152, 0.0722));
    float wShadow = 1.0 - smoothstep(0.0, 0.5, lum);
    float wHighlight = smoothstep(0.5, 1.0, lum);
    v *= exp2(d.b.z / 100.0 * 0.8 * wShadow);           // shadows
    v *= exp2(-d.b.y / 100.0 * 0.8 * wHighlight);       // highlights

    // 3. Hue and saturation.
    if (d.c.y != 0.0) { v = rotate_about_grey(v, d.c.y); }
    if (d.c.z != 0.0) {
        float grey = dot(v, float3(0.2126, 0.7152, 0.0722));
        v = mix(float3(grey), v, 1.0 + d.c.z / 100.0);
    }
    return max(v, 0.0);
}

kernel void s1_6_local(texture2d<float, access::read> src [[texture(0)]],
                       texture2d_array<float, access::read> atlas [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]],
                       constant LocalParams &p [[buffer(0)]],
                       constant LocalAdjustDesc *adjust [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.a.x == 0) {
        dst.write(c, gid);
        return;
    }

    float3 v = c.rgb;
    for (uint i = 0; i < uint(max(p.a.y, 0)); ++i) {
        LocalAdjustDesc d = adjust[i];
        if (d.c.w < 0.5) { continue; }                  // neutral adjustments: skip entirely
        float a = atlas.read(gid, i).r;
        if (a <= 0.0) { continue; }
        v = mix(v, local_adjust(v, d), clamp(a * d.a.w, 0.0, 1.0));
    }
    dst.write(float4(v, c.a), gid);
}
