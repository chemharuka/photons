#include <metal_stdlib>
using namespace metal;

// S1.7 — **the** tone curve, in the HDR domain (派单 030; the axis re-shaped by 派单 062).
//
// There is exactly one curve in the pipeline and it lives here, between S1.6 (local masks) and
// S2 (tone map). It used to sit *after* S2, on 0…1 data S2 had already compressed: the user could
// only bend values S2 had shaped, the highlights region weighting had already had its say about
// anything above 1, and a +4 EV highlight could not share an axis with a −12 EV shadow. Both
// problems are the same problem, and the answer is the mounting point, not a better table. The old
// stage, its file and its kernel are deleted (`Stage.curve` carries the one-line migration note).
//
// ## The axis: the histogram's own axis (派单 062)
//
//   u(x) = 0.5 · sRGB(x)             0 < x ≤ 1     SDR half: display code 0–255, 50 % of u
//   u(x) = 0.5 + 0.125 · log2(x)     1 < x         HDR half: +0…+4 EV, 12.5 % of u per stop
//   x(u) = sRGB⁻¹(2u)                u ≤ 0.5
//   x(u) = 2^(8(u − 0.5))            u > 0.5
//
//   u(0) = 0   u(0.18) = 0.2307   u(1.0) = 0.5000   u(2) = 0.6250   u(4) = 0.7500   u(16) = 1.0000
//
// so `u = 0 ↔ x = 0`, `u(0.18) = 0.2307`, **`u(1.0) = 0.5000`** (SDR white is the middle of the
// card, which is the histogram's `sdrFraction`), `u(4) = 0.7500` (+2 EV), `u = 1 ↔ +4 EV` — the
// histogram's own four-stop tail (`Histogram.swift:189` `maxStops = 4`, `xHI = 16`), which is where
// 派单 044 put the right end. `0.5` and `0.125` are **not** this file's constants: they arrive in
// the uniform as `HDRCurveAxis.whiteU` / `.hdrPerStop`, so the CPU reference and the GPU shaper
// cannot drift apart.
//
// 044's axis was `log1p(x/x0)/K`, with SDR white at `u = 0.7500` — three quarters of the card on
// 0…1 and a quarter on the whole HDR tail, i.e. the opposite proportion of the histogram above it.
// 062 replaced the shaper, not the curve: the table still holds `v ∈ [0,1]` in `u`, and the four
// boundary rules below are 030's/044's own, unchanged.
//
// Why a piecewise shaper and not one log1p: the owner's rule is that the curve reads like the
// histogram it sits under — 0–255 on the left half, +0…+4 EV on the right half. The SDR half is
// therefore the *display* encoding (S4's OETF, which is also what the 256 SDR bins count), and the
// HDR half is `log2` light, one stop per `hdrPerStop` of `u`. Both branches are strictly increasing
// and they meet at `u = 0.5` with the same value and the same slope up to the transfer's own break,
// so the axis is C¹ enough for a curve and strictly monotone overall — including across the sRGB
// break (`x = 0.0031308`, `u = 0.0016`), where the linear and power branches agree by construction.
//
// ## The four boundary rules (one if each; none is optional)
//
//  1. **Identity → copy.** `p.a.x > 0.5` writes the source through: no shaper, no table, not one
//     byte moved. The table is either exactly identity (identity points) or the user's, so this
//     branch is the "curve is off" path and it is bit-exact by construction.
//  2. **The matte is not a shadow** (派单 008 C, unchanged, both guards): alpha 0 first (S0 marks
//     everything that is not photograph with 0), then the content rect for a window whose rect
//     covers the canvas. `(0, 0.3)` in u is 0.32 in linear — 0.60 in display units — so without
//     the guards the letterbox would be a grey band.
//  3. **`x ≤ 0` passes through, sign preserved** (派单 018). A negative has no display code and no
//     log; the decoder delivers sub-black detail (measured min −0.039). Those samples are S2's
//     business (its `max(v, 0)`), exactly as before; the curve may not delete them. A consequence
//     worth stating: an *exactly* zero input can never be lifted by the curve, because it takes
//     this branch — the matte's 0 and a true-black pixel's 0 both come out 0.
//  4. **`u > 1` continues at the last segment's slope, never clamped.** `slope` is derived from the
//     table's last two entries `(lut[N-1] − lut[N-2]) · (N-1)`, which is exactly 1 for the identity
//     table, so identity is identity above +4 EV too: the f32 round trip over 1e-6…64 (64 is
//     u = 1.25, i.e. past the end) stays within 1.5e-6 relative, and through the fp16 display
//     buffer 1000 comes back as 997.65 — the storage step (9.77e-4), not the slope. A user's roll-off
//     (slope < 1) keeps compressing; slope = 0 is a hard ceiling at 16 *the user drew*, not a
//     pipeline clamp. The slope is clamped to [0, 1] so it can neither invert nor manufacture gain.
//
// ## WRGB: W is a luma **gain**, R/G/B are separable per-channel tables
//
// The composite table multiplies the pixel by `exp2(log2(x(v)/x(u)))`, i.e. it is a pure exposure
// offset on the pixel's luma and therefore preserves hue and saturation. Since `x(v)/x(u)` is the
// ratio of the two lights the axis maps, the W curve means exactly what the panel draws: *this input
// light becomes that one* (062; see `HDRCurve.offsetStops` for why the old `(v−u)·16` form no longer
// applies on a display-encoded half).
//
// Applying the same LUT to all three channels instead ("composite") is a different operator: on
// `rgb = (0.02, 0.02, 2.0)` under an S curve the two differ by 137 8-bit codes. They are not
// interchangeable and `EditModel` must not let a document drift between them.
//
// Order W → R → G → B: whole-picture tone first, then the colour cast (Lightroom's order, and the
// order the display-referred curve used before it).
//
// The table holds `v ∈ [0,1]` (log-domain, not linear output): interpolation in `v` is
// interpolation in the axis' own coordinate — display code over the SDR half, log light over the
// HDR half — which keeps the identity table exactly `i/(N−1)`, the same predicate
// `tablesAreIdentity` has always used.

struct HDRCurveParams {
    float4 a;   // identity, tableSize, whiteU (0.5), hdrPerStop (0.125)
    // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard (派单 008 C).
    float4 b;
    // slopeW, slopeR, slopeG, slopeB — the last segment of each table (rule 4).
    float4 c;
    // luma weights (Rec709: 0.2126, 0.7152, 0.0722 — the same convention as s2_tone_map:81), then
    // the **identity mask**: bit 0 = W, 1 = R, 2 = G, 3 = B, set for every table that is the
    // identity. The bitrate of `u` per stop is `p.a.w`, not a constant here.
    float4 d;
};

static inline float hdr_lut(device const float *lut, int offset, int n, float u) {
    float t = clamp(u, 0.0, 1.0) * float(n - 1);
    int i0 = int(floor(t));
    int i1 = min(i0 + 1, n - 1);
    return mix(lut[offset + i0], lut[offset + i1], t - float(i0));
}

/// S4's OETF — display code / 255, the encoding the SDR half of the axis counts.
///
/// The knee is `0.0031306684425005367` and not the printed `0.0031308`: with 12.92 / 1.055 / 0.055
/// the two branches do **not** meet at the printed value (the power branch is 2.85e-8 below it), and
/// a 2.85e-8 step *down* in `u` is a fold — a curve on a folded axis can invert two neighbouring
/// tones. The knee below is the exact crossing of the same three constants, so `hdr_forward` is
/// strictly increasing. It is `HDRCurveAxis.srgbKnee`, copied here only because Metal has no way to
/// read a Swift constant; the header numbers above are parsed by the test, these two are not axis
/// positions and are the transfer function's own (the same pair `s4_display.metal:20` rounds).
constant float hdr_srgb_knee = 0.0031306684425005367f;
constant float hdr_srgb_knee_encoded = 0.04044823627710693f;

static inline float hdr_srgb_encode(float x) {
    return x <= hdr_srgb_knee ? 12.92f * x : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
}

static inline float hdr_srgb_decode(float v) {
    return v <= hdr_srgb_knee_encoded ? v / 12.92f : pow((v + 0.055f) / 1.055f, 2.4f);
}

/// `u(x)` for `x > 0` (rule 3 handles the rest): piecewise, SDR half = display code, HDR half =
/// `log2` light. `uWhite = 0.5`, `perStop = 0.125`. `x = 1` belongs to the HDR branch so
/// `hdr_forward(1.0f) == uWhite` exactly, which is what makes the white tick exact.
static inline float hdr_forward(float x, float uWhite, float perStop) {
    if (x < 1.0f) { return uWhite * hdr_srgb_encode(x); }
    return uWhite + perStop * log2(x);
}

/// `x(u)` — the inverse of `hdr_forward`, unbounded above on purpose (rule 4 needs it past +4 EV).
static inline float hdr_inverse(float u, float uWhite, float perStop) {
    if (u <= uWhite) { return hdr_srgb_decode(u / uWhite); }
    return exp2((u - uWhite) / perStop);
}

/// One channel through its table, with rules 3 and 4.
static inline float hdr_channel(float x, device const float *lut, int offset, int n,
                                float slope, float uWhite, float perStop) {
    if (x <= 0.0) { return x; }                       // rule 3: sub-black detail, sign preserved
    float u = hdr_forward(x, uWhite, perStop);
    float v = hdr_lut(lut, offset, n, u) + max(u - 1.0, 0.0) * clamp(slope, 0.0, 1.0);
    return hdr_inverse(v, uWhite, perStop);
}

kernel void s1_7_hdr_curve(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant HDRCurveParams &p [[buffer(0)]],
                           device const float *lut [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);

    // Rule 1: the curve is off. A byte copy, not a table lookup that happens to be the identity.
    if (p.a.x > 0.5) {
        dst.write(c, gid);
        return;
    }

    // Rule 2, first guard: alpha 0 is the only thing that says "there is no photograph here".
    if (c.a == 0.0) {
        dst.write(c, gid);
        return;
    }

    // Rule 2, second guard: outside the content rect (S0 leaves the matte at 0).
    float2 g = float2(gid);
    if (g.x < p.b.x || g.y < p.b.y || g.x >= p.b.x + p.b.z || g.y >= p.b.y + p.b.w) {
        dst.write(c, gid);
        return;
    }

    int n = int(p.a.y);
    float uWhite = p.a.z;
    float perStop = p.a.w;
    float3 v = c.rgb;
    // Rule 1b (062): an identity table costs nothing and moves nothing. Running it through the
    // shaper→table→shaper round trip would return the value within ~5e-7 — and on an fp16 boundary
    // that is one bit, which is what `HDRCurveTests` ⑩ ("a curve on R cannot move G by even one
    // bit") measures. Skipping is both exact and cheaper.
    uint identityMask = uint(p.d.w + 0.5);

    // W: one exposure offset for the whole pixel, so hue and saturation survive it.
    float y = dot(max(c.rgb, float3(0.0)), p.d.xyz);
    if (y > 0.0 && (identityMask & 1u) == 0u) {
        float uy = hdr_forward(y, uWhite, perStop);
        float vy = hdr_lut(lut, 0, n, uy) + max(uy - 1.0, 0.0) * clamp(p.c.x, 0.0, 1.0);
        // The offset is `log2(x(v)/x(u))` — the ratio of the two *light* values the axis maps, not
        // `(v − u)·16`. On 044's log1p axis the two agreed to 0.1 %; on this one the SDR half is
        // display-encoded, where a unit of `u` is 12–100 stops, so a single constant would make the
        // midtone gain up to 40 % too weak (062, `HDRCurve.offsetStops`).
        //
        // fp16 protection: dragging the white end from 0.5 to 1.0 is +9 stops (×512), and
        // 200 → 102400 is already inf in half float. Clamping the *offset* keeps the pixel.
        float dv = clamp(log2(hdr_inverse(vy, uWhite, perStop) /
                              max(hdr_inverse(uy, uWhite, perStop), 1e-30f)), -12.0, 12.0);
        v *= exp2(dv);
    }

    // R, G, B: separable, so a curve on R cannot move G or B by even one bit.
    if ((identityMask & 2u) == 0u) { v.r = hdr_channel(v.r, lut, n, n, p.c.y, uWhite, perStop); }
    if ((identityMask & 4u) == 0u) { v.g = hdr_channel(v.g, lut, 2 * n, n, p.c.z, uWhite, perStop); }
    if ((identityMask & 8u) == 0u) { v.b = hdr_channel(v.b, lut, 3 * n, n, p.c.w, uWhite, perStop); }

    dst.write(float4(v, c.a), gid);
}
