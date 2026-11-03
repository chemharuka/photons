#include <metal_stdlib>
#include "oklch_bands.metal"
using namespace metal;

// S3.6b — **点颜色 (Point Color)**: up to eight sampled colours, each an **OKLCh platform + shoulder**
// (285), and three adjustments (140, reshaped by 158). Display-referred, pixel-in / pixel-out,
// directly after S3.6.
//
// ## The window (285)
//
//   w_i = wh(Δh_i) · wc(ΔC_i) · wl(ΔL_i) · [C_pixel ≥ 0.5 · chromaFloor]
//   w_axis = 1 − smoothstep(d_axis, d_axis + shoulder, |pixel_axis − sample_axis|)
//
// The hue axis is an **angle** (wrapped to [−180°, 180°)), chroma is relative to the sample, and the
// luma axis is OKLab L. At 范围 30 the platforms are ±10° hue (zero at 15°), 30 % of the sample's C
// (clamped 0.02…0.12) and ±0.08 L (zero at 0.12). 过渡 scales only the shoulder.
//
// The pale-colour guard is a hard floor: a pixel whose own OKLab C is below `0.5 · chromaFloor`
// (0.01) gets weight 0. A neutral pixel is therefore written back bit for bit, and a nearly-grey
// patch cannot be tinted by accident.
//
// ## Multiple swatches (285)
//
// Every weight is evaluated on the **stage input** (no swatch sees another's output), then all
// weights are divided by `max(1, Σw)`. Two full-weight boxes therefore split a pixel instead of
// doubling its move, and the array order no longer changes the result. The hue shoulder uploaded in
// `window.y` has already been capped on the host by the nearest sample's angular distance.
//
// The adjustment is multiplied by the normalised `w`, never gated by membership alone: at the
// shoulder the hue rotation, chroma scale and lightness lift all reach exactly zero together.

struct PointColorParams {
    float4 a;    // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    float4 b;    // swatch count, 0.5 · chromaFloor, pad, pad
};

struct PointColorSwatch {
    float4 sample;   // OKLab L, OKLab C, OKLCh hue° (sample), active
    float4 window;   // hue platform°, hue shoulder° (capped), chroma tolerance, L platform
    float4 adjust;   // hue, saturation, luminance, featherScale
};

/// `((a − b + 540) mod 360) − 180` — the one angular-distance spelling, mirrored by
/// `PointColor.angularDistance` on the host.
static inline float point_angular_distance(float a, float b) {
    return fmod(a - b + 540.0, 360.0) - 180.0;
}

static inline float point_box_weight(float delta, float d, float shoulder) {
    float x = fabs(delta);
    if (x <= d) { return 1.0; }
    if (shoulder <= 0.0 || x >= d + shoulder) { return 0.0; }
    float t = (x - d) / shoulder;
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

kernel void s3_6b_point_colour(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant PointColorParams &p [[buffer(0)]],
                               constant PointColorSwatch *swatches [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.a.z <= 0.0 || p.a.w <= 0.0) {              // no content (degenerate window)
        dst.write(c, gid);
        return;
    }
    if (c.a == 0.0) {                                 // S0's background: there is no photograph here
        dst.write(c, gid);
        return;
    }
    float2 g = float2(gid);
    if (g.x < p.a.x || g.y < p.a.y || g.x >= p.a.x + p.a.z || g.y >= p.a.y + p.a.w) {
        dst.write(c, gid);                            // the matte, written back unchanged
        return;
    }
    if (p.b.x <= 0.0) {
        dst.write(c, gid);
        return;
    }

    int count = int(min(p.b.x, 8.0));

    // The pixel's OKLCh is box-independent and is exactly what the adjustments need anyway, so there
    // is no YUV round trip between swatches (158 paid one matrix + three OETFs per swatch).
    float3 lab = oklab_raw(c.rgb);
    float L = lab.x;
    float C = length(lab.yz);
    float H = atan2(lab.z, lab.y) * (180.0 / M_PI_F);
    if (H < 0.0) { H += 360.0; }

    // The pale floor can short-circuit the whole loop.
    if (C < p.b.y) {
        dst.write(c, gid);
        return;
    }

    // Pass 1 — every weight on the **input** pixel.
    float weights[8];
    float sum = 0.0;
    for (int i = 0; i < count; ++i) {
        PointColorSwatch s = swatches[i];
        if (s.sample.w <= 0.0) {                      // a sample-only swatch has no adjustment
            weights[i] = 0.0;
            continue;
        }
        float wh = point_box_weight(point_angular_distance(H, s.sample.z),
                                    s.window.x, s.window.y);
        float wc = point_box_weight(C - s.sample.y,
                                    s.window.z, 0.5 * s.window.z * s.adjust.w);
        float wl = point_box_weight(L - s.sample.x,
                                    s.window.w, 0.5 * s.window.w * s.adjust.w);
        weights[i] = wh * wc * wl;
        sum += weights[i];
    }
    if (sum <= 0.0) {
        dst.write(c, gid);
        return;
    }

    // Pass 2 — partition of unity: two full-weight boxes split the pixel, not double it.
    float divisor = max(1.0, sum);
    for (int i = 0; i < count; ++i) {
        PointColorSwatch s = swatches[i];
        if (s.sample.w <= 0.0) { continue; }
        float w = weights[i] / divisor;
        if (w <= 0.0) { continue; }

        // The three sliders are the HSL card's units: 0.3° of hue per unit, a multiplicative chroma
        // and ±1 stop of perceptual lightness per 100. Every one is scaled by the box weight.
        H += w * s.adjust.x * 0.3;
        C = max(C * (1.0 + w * s.adjust.y / 100.0), 0.0);
        L *= exp2(w * s.adjust.z / 100.0);
    }

    // A hue rotation can leave the working gamut; a negative channel is not a colour. Nothing is
    // clamped at the top, so a display-referred highlight keeps its headroom (S4 is the only clamp).
    c.rgb = max(oklch_to_linear(L, C, H), 0.0);
    dst.write(c, gid);
}
