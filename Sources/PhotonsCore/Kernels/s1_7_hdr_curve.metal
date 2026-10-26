#include <metal_stdlib>
using namespace metal;

// S1.7 — **the** tone curve, in the HDR domain (派单 030).
//
// There is exactly one curve in the pipeline and it lives here, between S1.6 (local masks) and
// S2 (tone map). It used to sit *after* S2, on 0…1 data S2 had already compressed: the user could
// only bend values S2 had shaped, the highlights region weighting had already had its say about
// anything above 1, and a +6 EV highlight could not share an axis with a −12 EV shadow. Both
// problems are the same problem, and the answer is the mounting point, not a better table. The old
// stage, its file and its kernel are deleted (`Stage.curve` carries the one-line migration note).
//
// ## The axis: log1p of scene-linear light
//
//   u(x) = log1p(x / x0) / K        x0 = 2^-12 (−12 EV), K = ln(1 + 64/x0) = 12.4766531
//   x(u) = x0 · expm1(u · K)
//
// so `u = 0 ↔ x = 0`, `u(0.18) = 0.5293`, `u(1.0) = 0.6667` (SDR white is a third from the right
// edge), `u = 1 ↔ +6 EV`. `K` is a **natural** log of `1 + xHI/x0`; the 18.0000055 that
// `docs/tasks/030` quotes next to it is `K/ln 2`, i.e. the 18 stops the axis spans (+6 − (−12)),
// and every `u` position in that document's table is the ln one. See `HDRCurveAxis.K`.
//
// Why log1p and not a piecewise "log + linear toe" (Brightroom/OCIO): a toe needs a magic gain and
// a break point and is only C0 there. log1p is C∞, monotone, needs no constants beyond x0/K, and
// `u(0) = 0` is exact — which is what lets the black end bend all the way to zero output.
//
// ## The four boundary rules (one if each; none is optional)
//
//  1. **Identity → copy.** `p.a.x > 0.5` writes the source through: no shaper, no table, not one
//     byte moved. The table is either exactly identity (identity points) or the user's, so this
//     branch is the "curve is off" path and it is bit-exact by construction.
//  2. **The matte is not a shadow** (派单 008 C, unchanged, both guards): alpha 0 first (S0 marks
//     everything that is not photograph with 0), then the content rect for a window whose rect
//     covers the canvas. `(0, 0.3)` in u is 0.054 in linear — 0.26 in display units — so without
//     the guards the letterbox would be a grey band.
//  3. **`x ≤ 0` passes through, sign preserved** (派单 018). log of a negative is undefined, and
//     the decoder delivers sub-black detail (measured min −0.039). Those samples are S2's business
//     (its `max(v, 0)`), exactly as before; the curve may not delete them. A consequence worth
//     stating: a *exactly* zero input can never be lifted by the curve, because it takes this
//     branch — the matte's 0 and a true-black pixel's 0 both come out 0.
//  4. **`u > 1` continues at the last segment's slope, never clamped.** `slope` is derived from the
//     table's last two entries `(lut[N-1] − lut[N-2]) · (N-1)`, which is exactly 1 for the identity
//     table, so identity is identity above +6 EV too (measured 1000 → 999.9996). A user's roll-off
//     (slope < 1) keeps compressing; slope = 0 is a hard ceiling at 64 *the user drew*, not a
//     pipeline clamp. The slope is clamped to [0, 1] so it can neither invert nor manufacture gain.
//
// ## WRGB: W is a luma **gain**, R/G/B are separable per-channel tables
//
// The composite table multiplies the pixel by `exp2((f(u(y)) − u(y)) · K)`, i.e. it is a pure
// exposure offset on the pixel's luma and therefore preserves hue and saturation. Applying the
// same LUT to all three channels instead ("composite") is a different operator: on
// `rgb = (0.02, 0.02, 2.0)` under an S curve the two differ by 137 8-bit codes. They are not
// interchangeable and `EditModel` must not let a document drift between them.
//
// Order W → R → G → B: whole-picture tone first, then the colour cast (Lightroom's order, and the
// order the display-referred curve used before it).
//
// The table holds `v ∈ [0,1]` (log-domain, not linear output): interpolation in `v` is
// interpolation in log light, i.e. a geometric mean, which is far closer to a convex HDR segment
// than averaging linear values — and it keeps the identity table exactly `i/(N−1)`, the same
// predicate `tablesAreIdentity` has always used.

struct HDRCurveParams {
    float4 a;   // identity, tableSize, x0, K
    // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard (派单 008 C).
    float4 b;
    // slopeW, slopeR, slopeG, slopeB — the last segment of each table (rule 4).
    float4 c;
    // luma weights (Rec709: 0.2126, 0.7152, 0.0722 — the same convention as s2_tone_map:81),
    // then **stops per unit u** (`K/ln 2` = 18.0000055). A future colour basis change is one number
    // on the CPU side, not a kernel edit.
    float4 d;
};

static inline float hdr_lut(device const float *lut, int offset, int n, float u) {
    float t = clamp(u, 0.0, 1.0) * float(n - 1);
    int i0 = int(floor(t));
    int i1 = min(i0 + 1, n - 1);
    return mix(lut[offset + i0], lut[offset + i1], t - float(i0));
}

/// `u(x)` for `x > 0` (rule 3 handles the rest): `log1p(x/x0)/K`.
///
/// Metal has no `log1p`, and `log(1 + t)` loses the small values to cancellation: at `t = 1e-4` the
/// sum rounds to 1.0001 and the log quantises to ~6e-8 of `u`. The series below is used below 0.1
/// (where `log(1+t)` would be eating the argument's low bits) and the hardware log above it. Measured
/// against `Double`: the worst relative error of the whole forward→table→inverse round trip over
/// 1e-6…64 is **1.48e-6**, i.e. 5e-4 of an 8-bit code — smaller than the frame's own fp16 step.
static inline float hdr_forward(float x, float x0, float K) {
    float t = x / x0;
    float l = t < 0.1f
        ? t * (1.0f - t * (0.5f - t * (1.0f / 3.0f - t * (0.25f - t * (0.2f - t * (1.0f / 6.0f - t * (1.0f / 7.0f)))))))
        : log(1.0f + t);
    return l / K;
}

/// `x(u) = x0·expm1(u·K)` — the inverse of `hdr_forward`, unbounded above on purpose.
///
/// Same story as `hdr_forward`: no `expm1` in Metal, and `exp(a) - 1` cancels for small `a` (at
/// `a = 1e-3` it keeps only 5 decimal digits), so the series carries everything below 0.1.
static inline float hdr_inverse(float u, float x0, float K) {
    float a = u * K;
    float e = a < 0.1f
        ? a * (1.0f + a * (0.5f + a * (1.0f / 6.0f + a * (1.0f / 24.0f + a * (1.0f / 120.0f)))))
        : exp(a) - 1.0f;
    return x0 * e;
}

/// One channel through its table, with rules 3 and 4.
static inline float hdr_channel(float x, device const float *lut, int offset, int n,
                                float slope, float x0, float K) {
    if (x <= 0.0) { return x; }                       // rule 3: sub-black detail, sign preserved
    float u = hdr_forward(x, x0, K);
    float v = hdr_lut(lut, offset, n, u) + max(u - 1.0, 0.0) * clamp(slope, 0.0, 1.0);
    return hdr_inverse(v, x0, K);
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
    float x0 = p.a.z;
    float K = p.a.w;
    float3 v = c.rgb;

    // W: one exposure offset for the whole pixel, so hue and saturation survive it.
    float y = dot(max(c.rgb, float3(0.0)), p.d.xyz);
    if (y > 0.0) {
        float uy = hdr_forward(y, x0, K);
        float vy = hdr_lut(lut, 0, n, uy) + max(uy - 1.0, 0.0) * clamp(p.c.x, 0.0, 1.0);
        // The offset is in **u**, so it becomes stops by multiplying by stops-per-u (18.0000…),
        // not by K: K is the natural-log normaliser (12.4767), and using it here would make every
        // W-curve gain 0.69× too small in the exponent — measured as a 64→148 error on a ceiling
        // curve, which is exactly what `HDRCurveTests` ⑥ caught.
        //
        // fp16 protection: dragging the white end from 0.5 to 1.0 is +9 stops (×512), and
        // 200 → 102400 is already inf in half float. Clamping the *offset* keeps the pixel.
        float dv = clamp((vy - uy) * p.d.w, -12.0, 12.0);
        v *= exp2(dv);
    }

    // R, G, B: separable, so a curve on R cannot move G or B by even one bit.
    v.r = hdr_channel(v.r, lut, n, n, p.c.y, x0, K);
    v.g = hdr_channel(v.g, lut, 2 * n, n, p.c.z, x0, K);
    v.b = hdr_channel(v.b, lut, 3 * n, n, p.c.w, x0, K);

    dst.write(float4(v, c.a), gid);
}
