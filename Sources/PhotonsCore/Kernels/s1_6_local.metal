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
// Tiling (005d): `p.a.z/.w` carry the origin of the rectangle being dispatched, so the graph can send
// one thread group per dirty tile instead of the whole canvas. The kernel still addresses pixels in
// *canvas* coordinates, and outside the mask's bounds the coverage is exactly 0, so a tile pass and a
// full-frame pass write the same half-floats — which is the 005d acceptance criterion, checked by
// hashing both frames rather than by looking at them.
//
// Real identity branch (M1-6): if no mask has an active adjustment, or a given mask's adjustments
// are neutral (or `amount == 0`, or its coverage is 0), the source pixel is written unchanged.
// That is what makes "a mask with no adjustments" bit-exact against "no mask at all".
//
// 派单 056: this pass no longer carries **hue or saturation** — they are display-referred operations
// and run in S3.5, from the same `color_hsl.metal` include S3 uses. A mask whose only sliders are
// hue/saturation is therefore *inactive here* (its `enabled` flag is 0), which is what keeps it
// bit-exact against no mask rather than shipping it through neutral arithmetic.

struct LocalParams {
    int4 a;   // anyActive, maskCount, originX, originY (canvas pixels)
};

struct LocalAdjustDesc {
    float4 a;   // gainR, gainG, gainB, amountScale (0…1, already includes adjustments.amount)
    float4 b;   // contrast, highlights, shadows, whites
    float4 c;   // blacks, pad, pad, enabled
};

static inline float3 local_adjust(float3 v, LocalAdjustDesc d) {
    // 1. Scene-linear gains: exposure and the Planckian white-balance approximation.
    v = max(v, 0.0) * d.a.xyz;

    // 2. Tone shaping, the same parameterisation S2 uses (blacks/whites remap → contrast around the
    //    0.18 scene pivot → shadow/highlight lifts), applied before the tone curve by design — and
    //    with the same **signs**: 派单 008 A fixed S2 to Lightroom's direction (both sliders brighten
    //    towards +) and the panel must not be inverted for a local adjustment. `blk`/`wht` are input
    //    points, so they move opposite to the sliders.
    float blk = -d.c.x / 100.0 * 0.15;                  // blacks
    float wht = 1.0 - d.b.w / 100.0 * 0.15;             // whites
    v = max((v - blk) / max(wht - blk, 1e-3), 0.0);

    float gamma = exp2(d.b.x / 100.0 * 2.0);            // contrast
    v = 0.18 * pow(max(v, 1e-6) / 0.18, gamma);

    float lum = dot(v, float3(0.2126, 0.7152, 0.0722));
    float wShadow = 1.0 - smoothstep(0.0, 0.5, lum);
    float wHighlight = smoothstep(0.5, 1.0, lum);
    v *= exp2(d.b.z / 100.0 * 0.8 * wShadow);           // shadows (+ lifts)
    v *= exp2(d.b.y / 100.0 * 0.8 * wHighlight);        // highlights (+ lifts, LR convention)

    // 3. Hue and saturation: **not here** any more (派单 056). They are display-referred operations
    //    and run in S3.5, from the same include S3 uses; a rotation of linear RGB about its luma is
    //    not the same picture as a rotation in the display-referred domain, and only one of the two
    //    can agree with the global sliders.
    return max(v, 0.0);
}

kernel void s1_6_local(texture2d<float, access::read> src [[texture(0)]],
                       texture2d_array<float, access::read> atlas [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]],
                       constant LocalParams &p [[buffer(0)]],
                       constant LocalAdjustDesc *adjust [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    // Canvas coordinates: a tiled dispatch offsets the grid instead of moving the texture.
    uint2 px = uint2(gid.x + uint(p.a.z), gid.y + uint(p.a.w));
    if (px.x >= src.get_width() || px.y >= src.get_height()) { return; }

    float4 c = src.read(px);
    if (p.a.x == 0) {
        dst.write(c, px);
        return;
    }

    float3 v = c.rgb;
    for (uint i = 0; i < uint(max(p.a.y, 0)); ++i) {
        LocalAdjustDesc d = adjust[i];
        if (d.c.w < 0.5) { continue; }                  // neutral adjustments: skip entirely
        float a = atlas.read(px, i).r;                  // opacity · combine · invert, from S1.5
        // `acc · amount`: the atlas already carries the mask-level opacity, `d.a.w` carries the
        // adjustment's amount (0…1). Zero weight returns before `local_adjust`, so a mask with
        // amount 0 is bit-identical to no mask even if a slider would have produced a NaN (§3.3).
        float w = clamp(a * d.a.w, 0.0, 1.0);
        if (w <= 0.0) { continue; }
        v = mix(v, local_adjust(v, d), w);
    }
    dst.write(float4(v, c.a), px);
}
