#include <metal_stdlib>
#include "oklch_bands.metal"
using namespace metal;

// S3.6b — **点颜色 (Point Color)**: one sampled OKLCh colour, a hue window around it, three
// adjustments (140). Display-referred, pixel-in / pixel-out, directly after S3.6.
//
// The weight is the same family as S3.6's band weight and S3.4/S3.6's neutral gate, not a second
// colour theory:
//
//   w = (1 − smoothstep(range, range + feather, |wrap(h − sampleHue)|)) · hsl_chroma_gate(C)
//
// `wrap` is the circular shortest angle, so 0°/360° is not a special case. The chroma gate is the
// **shared** `hsl_chroma_gate` helper (`oklch_bands.metal`), so a grey pixel gets exactly 0 and is
// written back bit for bit — the same invariant the eight bands hold. range and feather are clamped
// so `range + feather ≤ 180`: a wider window would select the opposite hue too, which is the whole
// wheel, not a range.
//
// The adjustment is **multiplied by w**, never gated by membership alone. That is what makes the
// window's shoulder C¹: at `range + feather` the hue rotation, chroma scale and lightness lift all
// reach exactly zero together, so a 1°-per-pixel hue sweep has no step at either edge.
//
// The stage only exists for documents that need it (`RenderStage.pipeline(hasPointColor:)`), so a
// document with no sample or all three sliders at 0 renders the pre-140 graph byte for byte. The
// `active` word is a belt-and-braces guard for a caller that encodes the pass by hand.

struct PointColorParams {
    float4 a;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    float4 b;   // sampleHue (deg), sampleChroma, range (deg), feather (deg)
    float4 c;   // hue, saturation, luminance (slider units), active
};

kernel void s3_6b_point_colour(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant PointColorParams &p [[buffer(0)]],
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
    if (p.c.w <= 0.0) {
        dst.write(c, gid);
        return;
    }

    float3 lab = oklab_raw(c.rgb);
    float L = lab.x;
    float2 ab = lab.yz;
    float chroma = length(ab);
    float gate = hsl_chroma_gate(chroma);
    if (gate <= 0.0) {                                // a grey has no hue: bit-exact write-back
        dst.write(c, gid);
        return;
    }

    float hue = atan2(ab.y, ab.x) * (180.0 / M_PI_F);
    if (hue < 0.0) { hue += 360.0; }

    // Circular shortest difference from the sampled hue.
    float delta = hue - p.b.x;
    delta = fmod(delta, 360.0);
    if (delta > 180.0) { delta -= 360.0; }
    if (delta < -180.0) { delta += 360.0; }
    float d = fabs(delta);

    float inner = clamp(p.b.z, 0.0, 180.0);
    float shoulder = clamp(p.b.w, 0.0, 180.0 - inner);
    float window = 0.0;
    if (d <= inner) {
        window = 1.0;
    } else if (shoulder > 0.0 && d < inner + shoulder) {
        float t = (d - inner) / shoulder;
        window = 1.0 - t * t * (3.0 - 2.0 * t);
    }
    float w = window * gate;
    if (w <= 0.0) {
        dst.write(c, gid);
        return;
    }

    // The three sliders are the HSL card's units: 0.3° of hue per unit, a multiplicative chroma and
    // ±1 stop of perceptual lightness per 100. Every one is scaled by the window weight.
    float h2 = hue + w * p.c.x * 0.3;
    float c2 = max(chroma * (1.0 + w * p.c.y / 100.0), 0.0);
    float l2 = L * exp2(w * p.c.z / 100.0);
    float3 out = oklch_to_linear(l2, c2, h2);
    // A hue rotation can leave the working gamut; a negative channel is not a colour. Nothing is
    // clamped at the top, so a display-referred highlight keeps its headroom (S4 is the only clamp).
    dst.write(float4(max(out, 0.0), c.a), gid);
}
