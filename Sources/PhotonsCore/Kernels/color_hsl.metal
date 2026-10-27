#include <metal_stdlib>
using namespace metal;

// **One HSL implementation, two stages** (派单 056).
//
// `s3_color` (global: hue bands, vibrance, saturation) and `s3_5_local_color` (local: a mask's hue
// and saturation) both `#include "color_hsl.metal"`. That is the point of this file: the local
// sliders and the global sliders must not merely look alike, they must **be** the same arithmetic —
// otherwise a full-canvas mask at saturation +40 and the global saturation slider at +40 produce two
// different pictures and no test can say which one is wrong.
//
// Units, once, for both callers: a hue/saturation slider value is in 0…100 **units**. One hue unit
// is 0.3° — the mapping Lightroom's per-band hue sliders use (a band slider at 100 moves its band by
// 30°), so "+30" means the same 9° whether it arrives through a band or through a mask.
//
// Nothing here is a kernel; this file is a source include. `KernelLibrary` expands the include from
// the same bundle directory as the kernel that asks for it (Metal's runtime compiler has no include
// search path, and `makeLibrary(URL:)` wants a prebuilt metallib).

/// RGB → HSL, all three channels in 0…1. `h` is a **fraction of a turn** (0…1, not degrees).
static inline float3 rgb_to_hsl(float3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float l = (mx + mn) * 0.5;
    float d = mx - mn;
    if (d < 1e-6) {
        return float3(0.0, 0.0, l);
    }
    float s = l > 0.5 ? d / max(2.0 - mx - mn, 1e-6) : d / max(mx + mn, 1e-6);
    float h;
    if (mx == c.r) {
        h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
    } else if (mx == c.g) {
        h = (c.b - c.r) / d + 2.0;
    } else {
        h = (c.r - c.g) / d + 4.0;
    }
    return float3(h / 6.0, s, l);
}

static inline float hue_channel(float p, float q, float t) {
    if (t < 0.0) { t += 1.0; }
    if (t > 1.0) { t -= 1.0; }
    if (t < 1.0 / 6.0) { return p + (q - p) * 6.0 * t; }
    if (t < 0.5) { return q; }
    if (t < 2.0 / 3.0) { return p + (q - p) * (2.0 / 3.0 - t) * 6.0; }
    return p;
}

static inline float3 hsl_to_rgb(float3 hsl) {
    float h = fract(hsl.x);
    float s = clamp(hsl.y, 0.0, 1.0);
    float l = clamp(hsl.z, 0.0, 1.0);
    if (s < 1e-6) {
        return float3(l);
    }
    float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
    float p = 2.0 * l - q;
    return float3(hue_channel(p, q, h + 1.0 / 3.0),
                  hue_channel(p, q, h),
                  hue_channel(p, q, h - 1.0 / 3.0));
}

/// Slider units → turns. 100 units = 30° (0.0833 of a turn), the global band sliders' scale.
static inline float hsl_hue_turns(float units) {
    return units / 100.0 * (30.0 / 360.0);
}

/// Rotate the hue by `units` slider units (0 is exactly the identity: `fract(h + 0)` = `h` for
/// every `h` `rgb_to_hsl` can produce, since it returns `h / 6` with `h < 6`).
static inline float3 hsl_rotate_hue(float3 hsl, float units) {
    hsl.x = fract(hsl.x + hsl_hue_turns(units));
    return hsl;
}

/// Saturation is **multiplicative**, not additive: `s · (1 + units/100)`, clamped to 0…1. `-100`
/// is grey, `+100` doubles the distance from grey — the same curve as the global slider.
static inline float3 hsl_scale_saturation(float3 hsl, float units) {
    hsl.y = clamp(hsl.y * (1.0 + units / 100.0), 0.0, 1.0);
    return hsl;
}

/// The eight overlapping hue-band weights, summed into one (hue, saturation, luminance) shift in
/// **slider units**.
///
/// Each band's weight is a smooth tent of ±45° around its centre, so moving one band cannot produce
/// a seam against its neighbour; overlapping weights are renormalised when they sum past 1, so a
/// pixel between two centres gets a blend rather than double the shift. `bands[i]` is
/// (hue, saturation, luminance, centreDegrees).
///
/// A grey pixel (`saturation ≤ 1e-4`) has no hue to speak of, so it gets no shift at all — the loop
/// is skipped rather than weighted to zero, because `hueDeg` of a neutral pixel is meaningless.
static inline float3 hsl_band_shift(float hueDeg, float saturation, constant float4 *bands) {
    float3 shift = float3(0.0);
    float weightSum = 0.0;
    if (saturation > 1e-4) {
        for (int i = 0; i < 8; ++i) {
            float centre = bands[i].w;
            float d = abs(hueDeg - centre);
            d = min(d, 360.0 - d);
            float w = 1.0 - smoothstep(0.0, 45.0, d);
            shift += w * bands[i].xyz;
            weightSum += w;
        }
        if (weightSum > 1.0) {
            shift /= weightSum;
        }
    }
    return shift;
}
