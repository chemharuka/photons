#include <metal_stdlib>
using namespace metal;

// S3.5 — a mask's **hue and saturation**, in the display-referred domain: after the tone map (S2)
// and after the global colour pass (S3), before the vignette.
//
// Why here (派单 056): these two sliders used to run in S1.6, i.e. in **scene-linear** light before
// the curve and the tone map, while the *global* hue/saturation live in S3 on display-referred data.
// The same "+40 saturation" was therefore two different operations depending on whether it came from
// the global slider or from a mask: the local one multiplied linear RGB about its luma, which in the
// display domain is not a saturation change at all — shadows and highlights drifted in hue and the
// midtones landed somewhere else. A mask covering the whole frame also refused to equal the global
// slider, which is the kind of difference no user can explain and no test can bless.
//
// The maths is `color_hsl.metal` — the **same include S3 compiles**, so "local" and "global" are one
// implementation, not two that look alike. Local exposure and white balance stay in S1.6 (they *are*
// scene-linear gains, and S2 would otherwise have compressed what they need to recover).
//
// Tiling/identity: like S1.6 this pass only reads the pixel it writes, and it writes the source pixel
// back untouched when there is nothing to do (`p.a.x == 0`), when the mask's coverage is 0, or when
// the adjustment is disabled — so a mask with only exposure costs exactly nothing here.
//
// Matte: outside the content rect (and wherever S0 wrote alpha 0) the pixel is written back
// unchanged, the same guard S2 and S3 carry. A hue rotation applied to the letterbox would tint the
// bars, and `l = 0` is not a promise any more once the value is display-referred rather than black.

#include "color_hsl.metal"

struct LocalColorParams {
    int4 a;   // anyActive, maskCount, pad, pad
    float4 b; // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

struct LocalColorDesc {
    float4 a;   // hue (units, −100…100), saturation (units), amountScale (0…1), enabled
};

kernel void s3_5_local_color(texture2d<float, access::read> src [[texture(0)]],
                             texture2d_array<float, access::read> atlas [[texture(1)]],
                             texture2d<float, access::write> dst [[texture(2)]],
                             constant LocalColorParams &p [[buffer(0)]],
                             constant LocalColorDesc *adjust [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.a.x == 0) {
        dst.write(c, gid);
        return;
    }

    // Background the window invented (S0's alpha 0): there is no photograph here.
    if (c.a == 0.0) {
        dst.write(c, gid);
        return;
    }
    float2 g = float2(gid);
    if (g.x < p.b.x || g.y < p.b.y || g.x >= p.b.x + p.b.z || g.y >= p.b.y + p.b.w) {
        dst.write(c, gid);
        return;
    }

    float3 v = c.rgb;
    for (uint i = 0; i < uint(max(p.a.y, 0)); ++i) {
        LocalColorDesc d = adjust[i];
        if (d.a.w < 0.5) { continue; }                  // neutral or disabled: skip entirely
        float a = atlas.read(gid, i).r;                 // the coverage S1.5 wrote, exactly as S1.6 reads it
        // `coverage · amount`: the atlas carries the mask-level opacity and the combine/invert rule,
        // `d.a.z` carries the adjustment's amount (0…1). A zero weight returns before any maths, so
        // this pass is bit-identical to no mask at all when nothing covers the pixel.
        float w = clamp(a * d.a.z, 0.0, 1.0);
        if (w <= 0.0) { continue; }

        // The same HDR carry as S3: normalise by the peak when it is above white, do all the clamped
        // HSL maths on the normalised value, scale back by the same factor.
        float peak = max(v.r, max(v.g, v.b));
        float headroomScale = peak > 1.0 ? peak / 0.9 : 1.0;
        float3 hsl = rgb_to_hsl(max(v, 0.0) / headroomScale);
        if (d.a.x != 0.0) { hsl = hsl_rotate_hue(hsl, d.a.x); }
        if (d.a.y != 0.0) { hsl = hsl_scale_saturation(hsl, d.a.y); }
        float3 adjusted = hsl_to_rgb(hsl) * headroomScale;

        // `coverage · amount` is a lerp in **RGB**, the rule S1.6 has always used for a partial
        // mask: at w = 1 (a full-canvas mask at amount 100) the pixel is `adjusted` exactly, which is
        // what makes this pass agree with the global slider bit for bit.
        v = mix(v, adjusted, w);
    }
    dst.write(float4(v, c.a), gid);
}
