#include <metal_stdlib>
#include "primaries.metal"
#include "tone_shape.metal"
#include "oklch_bands.metal"
using namespace metal;
// S3.8 — **色彩分级**: 阴影 / 中间调 / 高光, each 色相 + 饱和 + 亮度 (2026-10-28, P0).
//
// Four decisions, each with its reason written where the arithmetic is:
//
//  1. **The regions are luminance windows, and they are S2's own.** `region_weights` below is not a
//     copy — it is the *function* the 阴影 and 高光 sliders call (`tone_shape.metal`, 074 R2), compiled
//     into this pass by the same `#include` mechanism S3/S3.5/S3.6 use. 「阴影」 therefore means one
//     thing in the whole panel: full weight at and below −5.9 EV, gone at −3.9 EV; highlights absent
//     below −3.2 EV, full above −1.2 EV. The third weight is `1 − shadow − highlight` — the two
//     windows do not overlap, so the three sum to exactly 1 and **this stage owns no window of its
//     own**. A second table of region boundaries would be a second answer to "where are the shadows",
//     which is the defect 079 §2.1.2 measured between S1 and S1.6.
//
//  2. **The space is OKLCh**, the graph's own fold (075), the same one S3.4/S3.6 run in: a hue
//     rotation has to happen in a space whose hue *is* a hue, and HSL-on-linear-RGB is exactly the
//     construction that gives pure blue and pure yellow the same `l` (079 结论 4). Sharing
//     `oklab_raw`/`oklch_to_linear`/`hsl_chroma_gate` also means a grey is handled the same way by all
//     three colour stages.
//
//  3. **The order is: hue + chroma at constant OKLab L → luma restored → lightness gain.**
//
//         w   = (w_sh, w_mid, w_hi)                       partition of unity (S2's windows)
//         dh  = (Σ w_i·hue_i)   · 0.3                     degrees
//         sc  = 1 + (Σ w_i·sat_i)/100                     chroma multiplier
//         dl  = (Σ w_i·light_i)/100                       stops
//
//         h' = h + dh·gate ;  C' = C·sc ;  v1 = OKLCh⁻¹(L, C', h')
//         v2 = v1 · clamp(Y(v)/Y(v1))                     ← luma held, hue untouched
//         out = v2 · exp2(dl)                             ← a pure gain: exactly ±1 stop
//
//     Why each step is where it is:
//       · a **uniform RGB gain cannot rotate an OKLCh hue** — the fold is linear in RGB and the cube
//         root turns a gain into a scalar on (l, m, s), so (L, a, b) all scale by g^(1/3) and
//         `atan2(b, a)` is invariant. That is why the luma restoration (a gain) and the lightness
//         slider (a gain) can sit after the rotation without disturbing it: 「单轮 sat=100 → 色相偏移
//         0°」 is a property of the maths, not a tolerance;
//       · `C·sc` changes Y (a more colourful pixel at the same OKLab L is a different luminance), so
//         the restore is what makes 饱和 luma-neutral — measured 0 codes, where the acceptance allows 1;
//       · 亮度 is a gain, so it multiplies Y by exactly `2^dl`: +100 is +1 EV of that region's light,
//         the unit 曝光 and 阴影 already speak. `dl == 0` skips it entirely, so "lightness at rest" is
//         not "a multiply by 1.0" but no multiply at all.
//
//  4. **Neutral is not merely a no-op; it is a branch.** If the effective parameters are the identity
//     the source pixel is written back **unchanged** (not re-encoded, not round-tripped through OKLCh).
//     That is what makes the three isolation claims exact: a pixel in the highlight zone of a
//     shadow-only document has `w = (0, 0, 1)` exactly, so `dh = 0`, `sc = 1`, `dl = 0`, and the
//     early-out returns the input bit for bit — 0 changed pixels, not "≤ 1 code". The whole stage is
//     also absent from the pipeline for a neutral *document* (`RenderStage.pipeline(hasGrade:)`), so
//     the stronger claim (no pass at all) is the first line of defence and this branch the second.
//
// Tiling/identity: pixel-in, pixel-out; the content rect and the alpha-0 matte are written back
// unchanged, exactly as S, S3.4, S3.5 and S3.6 do (派单 008 C's rule).
//
// `p.b.x` is the **refutation** ("weights global instead of windowed"): it is set only by
// `RenderOptions.gradeGlobalWeights`, never by the app, and `ColorGradingTests` turns it on to show the
// highlight-zone isolation going red. A key cannot see it (it is not in any material), which is the
// same contract `bwIndependentChannels` has.

struct GradeParams {
    float4 a;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    float4 b;   // x: globalWeights (refutation), yzw: 0
    float4 sh;  // shadows:    hue, saturation, lightness (slider units), 0
    float4 mid; // midtones:   hue, saturation, lightness (slider units), 0
    float4 hi;  // highlights: hue, saturation, lightness (slider units), 0
};

/// Degrees of OKLCh hue per slider unit — `ColorGrade.degreesPerUnit`, the HSL card's own number.
constant float GRADE_DEGREES_PER_UNIT = 0.3;

/// The three region weights of a pixel. **`region_weights` is S2's function**, included above; the
/// mid-tone weight is the remainder, which is the whole reason the three are a partition of unity.
static inline float3 grade_weights(float3 v, bool global) {
    if (global) { return float3(1.0 / 3.0); }
    float2 rw = region_weights(v);
    return float3(rw.x, max(1.0 - rw.x - rw.y, 0.0), rw.y);
}

kernel void s3_8_grade(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant GradeParams &p [[buffer(0)]],
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

    // The weights, then the **blended** parameters. Blending the slider values and converting once
    // (rather than converting three times and blending the results) is what makes a neutral wheel
    // deliver exactly zero in its own region: `Σ w_i·0 = 0`, not three products that cancel.
    bool global = p.b.x != 0.0;
    float3 w = grade_weights(c.rgb, global);
    float hueUnits = dot(w, float3(p.sh.x, p.mid.x, p.hi.x));
    float satUnits = dot(w, float3(p.sh.y, p.mid.y, p.hi.y));
    float lightUnits = dot(w, float3(p.sh.z, p.mid.z, p.hi.z));

    float dh = hueUnits * GRADE_DEGREES_PER_UNIT;     // degrees
    float sc = 1.0 + satUnits / 100.0;                // chroma multiplier
    float dl = lightUnits / 100.0;                    // stops

    // Rule 4: identity in, identity out — bit for bit, and before any conversion.
    if (dh == 0.0 && sc == 1.0 && dl == 0.0) {
        dst.write(c, gid);
        return;
    }

    float3 out = c.rgb;
    if (dh != 0.0 || sc != 1.0) {
        float3 lab = oklab_raw(out);
        float L = lab.x;
        float2 ab = lab.yz;
        float chroma = length(ab);
        // A grey has no hue to rotate and no chroma to scale: `0·k = 0`, so the move **is** the
        // identity — and a round trip through OKLab would still move its last bit (the fold's rows sum
        // to 1 only to 1e-10). Below the gate the pixel is written back unchanged, the same rule S3.6
        // follows; `dl` (the lightness gain) still applies below, because a grey can be lit.
        float gate = hsl_chroma_gate(chroma);
        if (gate > 0.0) {
            float hue = atan2(ab.y, ab.x) * (180.0 / M_PI_F);
            if (hue < 0.0) { hue += 360.0; }

            float h2 = hue + dh * gate;
            float c2 = max(chroma * sc, 0.0);
            float3 v1 = oklch_to_linear(L, c2, h2);

            // **The gamut is the gamut.** A chroma the working space cannot hold at this lightness and
            // hue comes back with a negative channel, and clipping that channel is not a cosmetic fix:
            // at a low chroma a single clipped channel rotates the hue by degrees
            // (`ColorGradingTests` measured 8.4° on a shadow patch) and drops the luma the restore had
            // just fixed. So the *move* is shortened instead — bisect the interpolation from the
            // input's own chroma to the requested one, and stop at the widest colour that fits. That is
            // why 「饱和不改色相」 holds at the edge of the gamut too, and why the saturation slider
            // stops growing instead of lying about the colour.
            //
            // Six steps: the parameter is a fraction of one chroma move, so 1/64 of it is below a
            // display code at any lightness (and the path is only taken by pixels that would otherwise
            // have been clipped).
            if (min(min(v1.x, v1.y), v1.z) < 0.0) {
                float lo = 0.0, hi = 1.0;
                for (int i = 0; i < 6; ++i) {
                    float t = 0.5 * (lo + hi);
                    float3 probe = oklch_to_linear(L, mix(chroma, c2, t), h2);
                    if (min(min(probe.x, probe.y), probe.z) < 0.0) { hi = t; } else { lo = t; }
                }
                v1 = oklch_to_linear(L, mix(chroma, c2, lo), h2);
            }
            out = max(v1, 0.0);

            // Luma restored by a **uniform gain** — the one operation that cannot move the hue we just
            // set (see the header). Both ends are floored: a black pixel has no ratio to restore.
            float yIn = dot(max(c.rgb, 0.0), kWorkingLumaWeights);
            float yOut = dot(out, kWorkingLumaWeights);
            if (yIn > 1e-6 && yOut > 1e-6) {
                out *= clamp(yIn / yOut, 0.125, 8.0);
            }
        }
    }
    if (dl != 0.0) {
        out *= exp2(dl);
    }

    // Nothing is clamped at the top: a display-referred highlight keeps its headroom (S4 is the only
    // clamp). A negative channel is not a colour — a hue rotation can leave the working gamut — so the
    // floor is the one S3.6 also takes.
    dst.write(float4(max(out, 0.0), c.a), gid);
}
