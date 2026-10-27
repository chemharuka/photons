#include <metal_stdlib>
#include "oklch_bands.metal"
using namespace metal;
// S3.4 — **黑白: the conversion to monochrome, and the mix that weighs each hue's share of the grey.**
//
// 2026-10-28 (P0-4 of `docs/tasks/078-lr-gap-matrix.md`). Lightroom's B&W mode is two controls that
// look like one: a switch that removes the colour, and eight sliders (红/橙/黄/绿/青/蓝/紫/品红) that
// decide **how bright each hue lands in the grey**. The second one is why a red apple can come out
// nearly black and a blue sky almost white in the same monochrome frame.
//
// Four decisions:
//
//  1. **The grey is the pixel's OKLab lightness, put back into linear light.** `L` is perceptual, so
//     the value a neutral pixel of that lightness holds is `L³` (which is what `OKLCh.toLinear(L: 0)`
//     returns, and why a grey written here is the *same* grey and not a lighter one). S3.6 already
//     commits the graph to OKLab lightness as *the* definition of "how light is this colour" (079
//     结论 4: HSL's `l` calls pure blue and pure yellow equal, 0.5 and 0.5, where their luminance
//     differs by 6.9×). One image, one lightness axis: the two stages cannot disagree about what
//     "lighter" means.
//
//  2. **The eight bands are S3.6's bands.** The centres, the reaches and the partition of unity come
//     from `oklch_bands.metal`, and the per-band number is `HSLBand.mix` on the *same* eight-band
//     table the HSL panel edits — no second band table, no second set of hue angles. Consequences,
//     all pinned by `BlackAndWhiteTests`: a mix value at its own band's centre has weight exactly 1,
//     a colour at another band's centre is untouched (weight exactly 0), and the eight bands
//     together are a partition of unity, so "+100 everywhere" is a uniform lift at every hue.
//
//  3. **The mix is `grey · 2^(m/100)`,** i.e. **±1 stop of linear light** at ±100 — the 曝光 slider's
//     unit, because a mix is a density decision ("how much light does this colour deposit in the
//     print"), and density is linear. It is *not* S3.6's 亮度, which is ±1 stop of perceptual
//     lightness and therefore 8× the light: two different jobs, and mixing them would make "+100 on
//     绿" a blown highlight out of a mid-tone leaf. Multiplicative either way, which is what keeps
//     black black (`0 · 2^k = 0`): a shadow cannot be lifted by a colour slider it does not contain.
//
//  4. **The mix is gated by chroma, exactly like S3.6.** A neutral pixel has no hue, so it has no
//     share to weigh: `gate = 0` below `kChromaFloor`, `hsl_chroma_gate` in between. That is what
//     makes "a grey frame is untouched by the mix" true bit for bit, and it is what keeps a
//     near-neutral gradient from stepping (the gate is `C¹`).
//
// The conversion itself is **not** conditional on the mix: a document with the switch on and all
// eight mix values at 0 renders monochrome at the pixel's own lightness (`exp2(0) = 1`). The *stage*
// is conditional — it exists only for documents whose switch is on (`RenderStage.pipeline(hasBW:)`),
// so a colour document never encodes this pass and its frame is the pre-S3.4 frame by construction,
// not by arithmetic.
//
// Position: after S3 (colour) and before S3.5/S3.6, i.e. the colour image is converted where the
// colour image exists. A grey written here has `C = 0`, so S3.6 downstream is inert by its own gate
// (it writes the pixel back unchanged) — the `BlackAndWhiteTests` pin that too, because it is the one
// interaction between the two stages.
//
// Tiling/identity: pixel-in, pixel-out; the matte (alpha 0 or outside the content rect) is written
// back untouched, the guard S2/S3/S3.5/S3.6 carry. Nothing is clamped at the top, so a display-
// referred highlight above white keeps its headroom (S4 is the only clamp).

struct BWParams {
    float4 a;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    // `.x` — **tests only**: write the grey per channel (three different numbers) instead of once and
    // replicated. It exists so `BlackAndWhiteTests` can show that "the three channels are equal" is a
    // load-bearing assertion: with this flag the plausible mistake is committed on purpose and the
    // max-channel-difference assertion has to go red. Never set by the app, never part of a key.
    // `.y` — stops of lightness per 100 units of mix (1.0 = ±1 stop, the shipped value). A parameter
    // rather than a literal so the host and the kernel cannot disagree about the scale.
    float4 b;
};

kernel void s3_4_bw(texture2d<float, access::read> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant BWParams &p [[buffer(0)]],
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
    float gate = hsl_chroma_gate(chroma);

    // The eight bands' weighted mix at this pixel's hue, in slider units (±100 at full weight after
    // the gate). **Exactly 0** for a neutral pixel (the gate) and for a hue every band disowns (a
    // document whose bands' reaches were hand-written broken) — in both cases `exp2(0) = 1` and the
    // pixel is `L`, the conversion's own grey.
    float mix = 0.0;
    if (gate > 0.0) {
        float hue = atan2(ab.y, ab.x) * (180.0 / M_PI_F);
        if (hue < 0.0) { hue += 360.0; }
        float acc = 0.0;
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
            acc += w * d.v.x;                        // `.x` is the band's 黑白混合 value
            wSum += w;
        }
        // **Unconditional** normalisation, the same rule as S3.6: Σw is 1 up to float rounding, so
        // this changes nothing a user can see, and it is what makes "+100 on the owning band delivers
        // its full value" a property of the maths rather than of the geometry.
        if (wSum > 0.0) { mix = (acc / wSum) * gate; }
    }
    float lift = exp2(mix / 100.0 * p.b.y);

    if (p.b.x != 0.0) {
        // **The refutation, and only that**: the plausible mistake of computing the grey once per
        // channel (`L` of (r,r,r), of (g,g,g), of (b,b,b)) instead of once per pixel. Three different
        // numbers, i.e. a tinted "monochrome" — which is exactly what the three-channel-equality
        // assertion in `BlackAndWhiteTests` is there to catch.
        float3 perChannel = float3(oklab_raw(float3(c.r, c.r, c.r)).x,
                                   oklab_raw(float3(c.g, c.g, c.g)).x,
                                   oklab_raw(float3(c.b, c.b, c.b)).x);
        perChannel = perChannel * perChannel * perChannel * lift;
        dst.write(float4(max(perChannel, 0.0), c.a), gid);
        return;
    }

    // **One scalar, written three times.** The three channels are not "allowed to agree to within a
    // tolerance": they are the same number, so a monochrome frame cannot pick up a cast from the
    // conversion.
    //
    // `L` is a *perceptual* lightness; the grey the frame needs is the linear-light value of that
    // lightness, i.e. `L³` — which is exactly what `OKLCh.toLinear(L: C: 0)` returns (the three rows of
    // `M₂⁻¹ · fold⁻¹` sum to 1), and what a neutral pixel of lightness `L` already holds. The cube is
    // done as three multiplies rather than through the matrix so the three channels are bit-identical
    // by construction rather than by the matrix's rounding.
    float l = L;
    float grey = max(l * l * l * lift, 0.0);
    dst.write(float4(grey, grey, grey, c.a), gid);
}
