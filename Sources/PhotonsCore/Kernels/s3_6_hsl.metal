#include <metal_stdlib>
#include "oklch_bands.metal"
using namespace metal;
// S3.6 — **HSL: the eight colour bands, on OKLCh, in the display-referred domain.**
//
// 派单 076. Three decisions, each bought with a measurement in `docs/tasks/079-oss-comparison.md`:
//
//  1. **The space is OKLCh, not HSL-on-linear-RGB** (079 结论 4). HSL's `l` is `(max+min)/2` of
//     whatever numbers it is handed, so on linear light pure blue and pure yellow both read 0.5 while
//     their luminance differs by 6.9× — one 亮度 slider, two meanings. darktable's `colorzones` uses
//     Lab/LCh and its `colorbalancergb` Filmlight Ych; ART/Ansel are in Lab as well. None of them runs
//     HSL in linear light, and neither do we: `OKLCh.fromLinear` (host) and `oklab_raw` in
//     `oklch_bands.metal` are the graph's own `OKLabMetric.lmsFold`, the Rec.2020 fold 075 derived.
//
//  2. **The position is here**, i.e. after S2's tone map and after S3/S3.5, before the vignette —
//     the same display-referred domain 056 put the mask's hue/saturation in. A band's 亮度 lift on a
//     value the tone map has already shaped is what the user sees; on scene-linear light it is a
//     different operation (and one the tone map then bends).
//
//  3. **The band weights are a partition of unity** (079 结论 5). The old scheme renormalised only
//     when the eight tents summed past 1, so a single band at +100 delivered 100 at its centre and
//     25.93 at 90°/150° — a 4× ripple, and 0 at 75°/165°. Here each band owns each of its sides with
//     `1 − smoothstep(0, gap, d)`, the two sides of a gap are complementary (`S(t) + S(1−t) = 1`), so
//     `Σw = 1` at **every** hue, seam included. The division by `Σw` is therefore a guarantee rather
//     than a correction — and it stays unconditional, as 076 requires: a hand-written document with a
//     NaN band cannot produce a NaN pixel.
//
// Tiling/identity: pixel-in, pixel-out, and a source pixel is written back untouched when the document
// has no non-identity band (`p.a.w`), outside the content rect, where S0 wrote alpha 0 (the matte),
// when the pixel is neutral (`hsl_chroma_gate` — exactly 0 there, so grey is bit-exact),
// or when every weight is zero. `HSLTests` pins those four.
//
// The stage only exists for documents that need it (`RenderStage.pipeline(hasHSL:)`), so a document
// with all 24 band values at 0 renders the pre-076 graph byte for byte.

// The stage shares **no** maths with `color_hsl.metal` (S3's global vibrance/saturation and S3.5's
// mask hue/saturation), because those two are HSL in the display domain and this one is OKLCh. It
// does share the band *geometry* with S3.4 (黑白) — that is `oklch_bands.metal`, and it is shared on
// purpose: two stages that name the same eight colours must measure them the same way.

struct HSLParams {
    float4 a;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

kernel void s3_6_hsl(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant HSLParams &p [[buffer(0)]],
                     constant HSLBandDesc *bands [[buffer(1)]],
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

    float3 lab = oklab_raw(c.rgb);
    float L = lab.x;
    float2 ab = lab.yz;
    float chroma = length(ab);
    // The neutral gate: **exactly** 0 at or below `kChromaFloor` (a grey has no hue, and the fold's rows
    // only sum to 1 to 1e-10 — so a mathematically neutral pixel arrives with C ≈ 1e-8 and an arbitrary
    // angle), 1 from 0.02 up, and a `smoothstep` in between so a near-neutral gradient fades in instead
    // of stepping at a threshold (079 §2.6.3).
    float gate = hsl_chroma_gate(chroma);
    if (gate <= 0.0) {
        dst.write(c, gid);
        return;
    }
    float hue = atan2(ab.y, ab.x) * (180.0 / M_PI_F);
    if (hue < 0.0) { hue += 360.0; }

    float3 shift = float3(0.0);
    float wSum = 0.0;
    for (int i = 0; i < 8; ++i) {
        HSLBandDesc d = bands[i];
        float delta = hue - d.v.w;
        if (delta > 180.0) { delta -= 360.0; }
        if (delta < -180.0) { delta += 360.0; }
        // `e.x` reaches backwards (towards the previous centre), `e.y` forwards.
        float reach = delta >= 0.0 ? d.e.y : d.e.x;
        if (reach <= 0.0) { continue; }
        float w = hsl_band_weight(delta, reach);
        if (w <= 0.0) { continue; }
        shift += w * d.v.xyz;
        wSum += w;
    }
    // **Unconditional** normalisation (076 §3): Σw is 1 up to rounding, so this changes nothing a user
    // can see — and makes "a band at its own centre delivers its full value" a property of the maths
    // rather than of the geometry happening to be nice.
    if (wSum <= 0.0) {
        dst.write(c, gid);
        return;
    }
    shift /= wSum;
    shift *= gate;

    if (shift.x == 0.0 && shift.y == 0.0 && shift.z == 0.0) {
        dst.write(c, gid);                            // nothing to do: bit-exact pass-through
        return;
    }

    // The three sliders (076 §4): 0.3° per hue unit, a multiplicative chroma, and ±1 stop of OKLab
    // lightness per 100 units.
    float h2 = hue + shift.x * 0.3;
    float c2 = max(chroma * (1.0 + shift.y / 100.0), 0.0);
    float l2 = L * exp2(shift.z / 100.0);
    float3 out = oklch_to_linear(l2, c2, h2);
    // A hue rotation can leave the working gamut; a negative channel is not a colour. Nothing is
    // clamped at the top, so a display-referred highlight keeps its headroom (S4 is the only clamp).
    dst.write(float4(max(out, 0.0), c.a), gid);
}
