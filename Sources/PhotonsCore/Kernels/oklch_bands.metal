#include <metal_stdlib>
using namespace metal;
// ── OKLCh + the eight bands, one definition for every stage that reads them ───────────────────────
//
// S3.6 (HSL, 派单 076) and S3.4 (黑白, 2026-10-28) are two operations on the *same* eight colour
// bands: one moves a band's hue/saturation/lightness, the other uses the band as a per-hue weight on
// the grey a colour converts to. The band geometry — eight centres, each band reaching to its
// neighbours, a partition of unity — is therefore defined **once, here**, and both kernels compile
// this text (the `#include` mechanism `KernelLibrary.expandingLocalIncludes` provides, the same one
// `color_hsl.metal` uses for S3/S3.5).
//
// The numbers below are the ones 076 measured and `HSLTests` pins against the CPU reference
// (`HSLBands`, `OKLCh`): if a centre, a weight or a matrix literal moves here, the kernel moves —
// which is the point.
//
// The only literal duplicated on purpose is the OKLab fold itself: it is also in
// `s1_5_mask_atlas.metal` because the mask atlas is a *different* pair of matrices (mask coverage
// works on the pixel's own primaries, not on the display-referred band space). `HSLTests` holds the
// two to the same numbers.

/// One band, as the host uploads it.
///
/// `v` = (hue, saturation, luminance) in slider units for S3.6, or (mix, 0, 0) for S3.4, with the
/// band's centre in `.w`. `e` = how far the band reaches towards its previous (`x`) and next (`y`)
/// neighbour, in OKLCh degrees.
struct HSLBandDesc {
    float4 v;
    float4 e;
};

/// Ottosson's OKLab from **linear working primaries**, raw axes (no `chromaSpan` division — a chroma
/// here is the real OKLCh `C`, which the saturation slider multiplies and the B&W mix gates on).
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
///
/// With `a = b = 0` the three rows sum to 1 and the result is a **neutral** `float3(L³)`, which is the
/// fact S3.4 stands on: a grey written to all three channels is a grey in the working space, not a
/// tint the display transform then has to undo.
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

/// The neutral gate both stages share: **exactly** 0 at or below `kChromaFloor`, 1 from 0.02 up, a
/// `smoothstep` in between.
///
/// It exists because "neutral" has to be exact: the fold's rows sum to 1 only to 1e-10, so a
/// mathematically grey pixel comes back with `C ≈ 1e-8` and an arbitrary hue — enough, without this
/// floor, to walk a grey through either stage and change its last bit (076 §3, 079 §2.6.3).
static inline float hsl_chroma_gate(float chroma) {
    return chroma <= 1e-6 ? 0.0 : smoothstep(1e-6, 0.02, chroma);
}

// The per-hue accumulation loop stays in each kernel: S3.6 sums three components per band in one
// pass, S3.4 sums one, and folding them into a helper with a component index would put a branch in
// the inner loop of a pass that runs at 4.10 Mpx per frame (measured: S3.6 is 1.6 ms there). What is
// shared is the *geometry* — the centres, the reaches and the weight function above — because that is
// the part two stages must not be allowed to disagree about.
