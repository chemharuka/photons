#include <metal_stdlib>
using namespace metal;
// S3.6 — **HSL: the eight colour bands, on OKLCh, in the display-referred domain.**
//
// 派单 076. Three decisions, each bought with a measurement in `docs/tasks/079-oss-comparison.md`:
//
//  1. **The space is OKLCh, not HSL-on-linear-RGB** (079 结论 4). HSL's `l` is `(max+min)/2` of
//     whatever numbers it is handed, so on linear light pure blue and pure yellow both read 0.5 while
//     their luminance differs by 6.9× — one 亮度 slider, two meanings. darktable's `colorzones` uses
//     Lab/LCh and its `colorbalancergb` Filmlight Ych; ART/Ansel are in Lab as well. None of them runs
//     HSL in linear light, and neither do we: `OKLCh.fromLinear` (host) and `oklab_raw` below are the
//     graph's own `OKLabMetric.lmsFold`, the Rec.2020 fold 075 derived.
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
// when the pixel is neutral (`oklch chroma` below the gate — exactly 0 there, so grey is bit-exact),
// or when every weight is zero. `HSLTests` pins those four.
//
// The stage only exists for documents that need it (`RenderStage.pipeline(hasHSL:)`), so a document
// with all 24 band values at 0 renders the pre-076 graph byte for byte.

// The stage is self-contained on purpose: it shares **no** maths with `color_hsl.metal` (S3's global
// vibrance/saturation and S3.5's mask hue/saturation), because those two are HSL in the display
// domain and this one is OKLCh. The units are the one thing they do share: a hue unit is 0.3°.

struct HSLParams {
    float4 a;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

/// One band, as the host uploads it: `v` = (hue, saturation, luminance) in slider units and `e` =
/// how far the band reaches towards its previous and next neighbour, in OKLCh degrees.
struct HSLBandDesc {
    float4 v;
    float4 e;
};

/// Ottosson's OKLab from **linear working primaries**, raw axes (no `chromaSpan` division — a chroma
/// here is the real OKLCh `C`, which the saturation slider multiplies).
///
/// 075 §2.2: the fold is `M1 · toXYZ(Rec.2020)` with its rows normalised to 1, the same nine literals
/// `s1_5_mask_atlas.metal` carries.
static inline float3 oklab_raw(float3 rgb) {
    float3 c = max(rgb, 0.0);
    float l = dot(c, float3(0.6167557877, 0.3601984026, 0.0230458097));
    float m = dot(c, float3(0.2651330603, 0.6358393719, 0.0990275679));
    float s = dot(c, float3(0.1001026312, 0.2039065206, 0.6959908482));
    float3 lms = pow(max(float3(l, m, s), 0.0), float3(1.0 / 3.0));
    return float3(dot(lms, float3(0.2104542553, 0.7936177850, -0.0040720468)),
                  dot(lms, float3(1.9779984951, -2.4285922050, 0.4505937099)),
                  dot(lms, float3(0.0259040371, 0.7827717662, -0.8086757660)));
}

/// OKLCh → linear working primaries: `M₂⁻¹`, cube, `fold⁻¹`. The same nine + nine literals as
/// `OKLCh.toLinear` on the host (`HSLTests` pins the round trip on both sides).
static inline float3 oklch_to_linear(float L, float C, float hueDeg) {
    float h = hueDeg * (M_PI_F / 180.0);
    float a = C * cos(h), b = C * sin(h);
    float l_ = 0.9999999985 * L + 0.3963377922 * a + 0.2158037581 * b;
    float m_ = 1.0000000089 * L - 0.1055613423 * a - 0.0638541748 * b;
    float s_ = 1.0000000547 * L - 0.0894841821 * a - 1.2914855379 * b;
    float l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_;
    return float3(2.1399067200 * l - 1.2463894955 * m + 0.1064827755 * s,
                  -0.8847358342 * l + 2.1632309414 * m - 0.2784951073 * s,
                  -0.0485737534 * l - 0.4545031404 * m + 1.5030768936 * s);
}

/// One band's weight at a signed hue offset from its centre. Reads 1 on the centre, falls to **exactly
/// 0** on each neighbour's centre (`d >= reach`), and rises nowhere — the two bands sharing a gap sum
/// to 1 by construction.
static inline float hsl_band_weight(float delta, float reach) {
    float d = fabs(delta);
    if (d >= reach) { return 0.0; }
    float t = d / reach;
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

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
    float gate = chroma <= 1e-6 ? 0.0 : smoothstep(1e-6, 0.02, chroma);
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
