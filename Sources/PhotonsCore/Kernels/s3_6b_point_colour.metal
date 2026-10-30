#include <metal_stdlib>
#include "oklch_bands.metal"
#include "primaries.metal"
using namespace metal;

// S3.6b — **点颜色 (Point Color)**: up to eight sampled colours, each with a **Rec.709 full-range
// YCbCr neighbourhood box** and three adjustments (140, reshaped by 158). Display-referred, pixel-in /
// pixel-out, directly after S3.6.
//
// ## The window (158)
//
//   w = wy · wu · wv · [c_pixel ≥ 0.5 · chromaFloor]
//   w_axis = 1 − smoothstep(d_axis, d_axis + feather, |pixel_axis − sample_axis|)
//
// The three axes are multiplied with equal weight, not summed: the box is a region, not a score. The
// luminance radius is the tightest (`d1 = 0.06` ≈ ±15/255); U/V are wider (`d2 = d3 = 0.10` ≈ ±13/255)
// because human chroma acuity is lower. The shoulder is half the radius, so the box is C¹ and exactly
// zero at its edge.
//
// The pale-colour guard is a hard floor: a pixel whose own chroma `hypot(U−0.5, V−0.5)` is below
// `0.5 · chromaFloorYCbCr` (≈ 2.5/255) gets weight 0. A neutral pixel (U = V = 0.5) is therefore
// written back bit for bit, and a nearly-grey patch cannot be tinted by accident.
//
// ## Multiple swatches (158)
//
// Every swatch in the document renders, **in array order**, each evaluating its box on the *current*
// pixel (the previous swatch's output) and applying its own three adjustments. `active` in the
// document is a UI selection only and is not uploaded. The stage exists only for documents with at
// least one sampled-and-adjusted swatch (`RenderStage.pipeline(hasPointColor:)`), so a document that
// never used the card renders the pre-140 graph byte for byte.
//
// The adjustment is multiplied by `w`, never gated by membership alone: at the shoulder the hue
// rotation, chroma scale and lightness lift all reach exactly zero together, so a smooth gradient
// through the box boundary has no step.

struct PointColorParams {
    float4 a;    // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    float4 b;    // swatch count, 0.5 · chromaFloorYCbCr, pad, pad
    float4 m0;   // working → sRGB primaries, row 0
    float4 m1;   // row 1
    float4 m2;   // row 2
};

struct PointColorSwatch {
    float4 sample;   // sampleY, sampleU, sampleV, active
    float4 window;   // dY, dU, dV, feather
    float4 adjust;   // hue, saturation, luminance, pad
};

static inline float point_srgb_encode(float v) {
    return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}

/// Linear working primaries → Rec.709 full-range YCbCr (U/V centred on 0.5), the same arithmetic as
/// `PointColor.yuv(fromLinearWorking:)` on the host.
///
/// The luma is measured on the **Rec.709 / sRGB encoded** triple, so its three weights are the
/// working primaries' (`kWorkingLumaWeights`, from `primaries.metal`) — not a literal here.
static inline float3 point_yuv(float3 rgb, constant PointColorParams &p) {
    float3 lin = float3(dot(p.m0.xyz, rgb), dot(p.m1.xyz, rgb), dot(p.m2.xyz, rgb));
    float3 enc = float3(point_srgb_encode(lin.x),
                        point_srgb_encode(lin.y),
                        point_srgb_encode(lin.z));
    float y = dot(enc, kWorkingLumaWeights);
    return float3(y, (enc.z - y) / 1.8556 + 0.5, (enc.x - y) / 1.5748 + 0.5);
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

    // Y is the cheapest axis and the only one the boxes need first, so it is measured once, exactly
    // as `point_yuv` would (the three matrix rows, the three OETFs, then the same `dot`). The rest of
    // the conversion — U/V, the pale floor, OKLab and `atan2` — is deferred until a box has admitted
    // the pixel: the common case is a pixel outside every swatch's luma radius.
    float3 lin = float3(dot(p.m0.xyz, c.rgb), dot(p.m1.xyz, c.rgb), dot(p.m2.xyz, c.rgb));
    float3 enc = float3(point_srgb_encode(lin.x),
                        point_srgb_encode(lin.y),
                        point_srgb_encode(lin.z));
    float y = dot(enc, kWorkingLumaWeights);

    // A swatch can only carry weight when |Y − sampleY| ≤ radius + shoulder. The test is inclusive on
    // purpose: it may admit a pixel, never drop one the per-axis weights would keep.
    bool inAnyBox = false;
    for (int i = 0; i < count; ++i) {
        PointColorSwatch s = swatches[i];
        if (s.sample.w <= 0.0) { continue; }          // a sample-only swatch has no adjustment
        if (fabs(y - s.sample.x) <= s.window.x + 0.5 * s.window.x * s.window.w) {
            inAnyBox = true;
            break;
        }
    }
    if (!inAnyBox) {
        dst.write(c, gid);                            // outside every box, so nothing can change it
        return;
    }

    float u = (enc.z - y) / 1.8556 + 0.5;
    float v = (enc.x - y) / 1.5748 + 0.5;

    // The pixel's own chroma is box-independent; the pale floor can short-circuit the whole loop.
    if (length(float2(u - 0.5, v - 0.5)) < p.b.y) {
        dst.write(c, gid);
        return;
    }

    float3 current = float3(y, u, v);
    bool changed = false;
    bool yuvValid = true;
    // Keep the pixel in OKLCh between swatches. A swatch's three operations are an addition on h, a
    // scale on C and a scale on L, so re-folding linear RGB through `oklab_raw` for every overlapping
    // box would be redundant work (and is what made eight swatches measurably heavier).
    float3 lab = oklab_raw(c.rgb);
    float L = lab.x;
    float C = length(lab.yz);
    float H = atan2(lab.z, lab.y) * (180.0 / M_PI_F);
    if (H < 0.0) { H += 360.0; }

    for (int i = 0; i < count; ++i) {
        PointColorSwatch s = swatches[i];
        if (s.sample.w <= 0.0) { continue; }          // a sample-only swatch has no adjustment

        // Each swatch sees the previous one's output (显式堆叠, no renormalisation). The YUV of the
        // current pixel only changes when a previous swatch actually wrote something, so the
        // (matrix + 3×OETF) conversion is cached across non-matching boxes — the common case.
        if (!yuvValid) {
            float3 shifted = max(oklch_to_linear(L, C, H), 0.0);
            current = point_yuv(shifted, p);
            yuvValid = true;
        }
        float cpx = length(float2(current.y - 0.5, current.z - 0.5));
        if (cpx < p.b.y) { continue; }                // a previous swatch may have faded it

        float wy = point_box_weight(current.x - s.sample.x, s.window.x, 0.5 * s.window.x * s.window.w);
        float wu = point_box_weight(current.y - s.sample.y, s.window.y, 0.5 * s.window.y * s.window.w);
        float wv = point_box_weight(current.z - s.sample.z, s.window.z, 0.5 * s.window.z * s.window.w);
        float w = wy * wu * wv;
        if (w <= 0.0) { continue; }

        // The three sliders are the HSL card's units: 0.3° of hue per unit, a multiplicative chroma
        // and ±1 stop of perceptual lightness per 100. Every one is scaled by the box weight.
        H += w * s.adjust.x * 0.3;
        C = max(C * (1.0 + w * s.adjust.y / 100.0), 0.0);
        L *= exp2(w * s.adjust.z / 100.0);
        changed = true;
        yuvValid = false;
    }
    if (changed) {
        // A hue rotation can leave the working gamut; a negative channel is not a colour. Nothing is
        // clamped at the top, so a display-referred highlight keeps its headroom (S4 is the only clamp).
        c.rgb = max(oklch_to_linear(L, C, H), 0.0);
    }
    dst.write(c, gid);
}
