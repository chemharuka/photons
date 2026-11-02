#include <metal_stdlib>
#include "primaries.metal"
using namespace metal;

// S2.5 — **global contrast in the gain domain** (228; the file keeps its 098 name so recorded traces
// and this header stay findable). Runs after S2 (tone map) and before S3 (colour), on the display
// linear light S2 wrote — white = 1 = 0 EV, and **unbounded above** for HDR.
//
// 159 put a multiscale, edge-aware decomposition here. The owner's report is that this is *local*
// contrast: it fights 清晰度/细节, and a smooth EV ramp passes through untouched (measured on the
// 30-step ramp at `contrast = ±100`: every `out/in` ratio is 0.9985…1.0004). 228 restores the global
// operator the old S2 had, in the gain domain:
//
//     Y    = max(dot(max(rgb, 0), kWorkingLumaWeights), 1e-9)
//     G    = log2(Y / exposureGain)              // unexposed display EV, white = 0
//     P    = log2(pivot)                         // linear mid-grey pivot (0.18)
//     γ    = 2^(contrast / 100 · travel)         // travel is the CPU's axis normalisation
//     G′   = P + γ·(G − P)
//     gain = 2^(G′ − G)
//     rgb′ = max(rgb, 0) · gain
//
// One scalar gain multiplies all three channels, so `R/Y`, `G/Y`, `B/Y` — hue and saturation — are
// preserved by construction. `contrast = 0` returns before any `log2`, so it is the exact identity
// (not "1 ± 1 code").
//
// **Why the unexposed luma.** The gain is built from `Y / exposureGain` and applied to the exposed
// pixel. With a neutral curve `Y(E) = 2^E·Y(0)`, so the gain field does not depend on the exposure
// slider and `render(E) = 2^E · render(0)` — exposure and contrast commute (174 §0's order contract,
// and 228 §2.2 ④). The division is the same one 159 used; only the body it feeds changed.
//
// **No upper clamp.** This is a power and a multiply. Nothing fades the gain at display white and
// nothing caps the output, so the HDR segment (1…4.926 linear, +2.303 EV) is expanded by the same
// arithmetic as the SDR segment. 159's white shoulder and A5 black floor are gone with the local
// operator; the display stage S4 still owns the headroom.
//
// **Masks.** A mask's contrast is the *same* curve scoped by its coverage: the global slider runs
// through this entry with `maskCount == 0`, and a full-canvas mask at `c` multiplies by exactly the
// same `gain` (079's 「同一滑杆蒙版内外同义」). There is no edge-aware decomposition left, so a mask
// can no longer mean a different kind of operation from the global slider.
//
// 228 removed `s1_8_g_contrast_pack`, `_box_h`, `_box_v` and `_coeff`; the only remaining
// `s1_8_g_contrast*` entry is the shared apply below (global = mask count 0, masks = per-mask gains).

struct ContrastParams {
    // contrast (−100…100), pivot (linear display light), exposure gain, travel EV
    float4 a;
    // Rec2020 luma weights, pad
    float4 luma;
    // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox/alpha guard
    float4 rect;
    // canvasW, canvasH, mask count, pad
    int4 d;
};

/// The mask descriptor S1.6 also uses (`s1_6_local.metal#LocalAdjustDesc`), declared here because a
/// kernel cannot include another kernel. Byte-for-byte the same three `float4`s; `.b.x` is the
/// mask's contrast slider, `.c.y` its travel, `.a.w` its amount.
struct LocalAdjustDesc {
    float4 a;
    float4 b;
    float4 c;
};

/// The global curve, one pixel: `gain = ((Y / exposure) / pivot)^(γ − 1)`.
///
/// `contrast == 0` returns `1.0` before the log, which is the bit-exact identity the neutral document
/// needs. There is no clamp in either direction: the power is defined on the whole positive axis.
///
/// **The pivot is quantised to the buffer's grid.** This stage reads a 16-bit-float texture, so the
/// flat a document calls "0.18" is stored as `half(0.18)` = 0.1800537109375 — 3.0e-4 above the
/// Double. Anchoring `P` on the Double leaves `G − P = +4.3e-4` at the pivot itself; the resulting
/// `gain` is 0.99985 at −100 (0.22 of a 16F code), and the implicit float→half store **truncates
/// toward zero**, so the flat lost a whole code on the negative side (1474/1475 = 0.9993220) while
/// every positive contrast kept its code. On the half grid the anchor is the number the stage can
/// actually read: `G == P` at the flat, `gain == 1` exactly, and both signs are byte-identical.
/// This is not a compensation for the measured ratio — it removes the offset that produced it.
static inline float s2_5_global_gain(float Y, float contrast, float pivot,
                                     float exposureGain, float travel) {
    if (contrast == 0.0) { return 1.0; }
    float G = log2(max(Y, 1e-9) / max(exposureGain, 1e-9));
    float P = log2(max(float(half(pivot)), 1e-6));
    float gamma = exp2(contrast / 100.0 * travel);
    return exp2((gamma - 1.0) * (G - P));
}

/// Full-resolution apply. **One entry for the global slider and for masks**: the global path binds a
/// dummy atlas with `maskCount == 0`, so the loops are empty and the arithmetic is literally the same
/// compiled body (079 B1's ≤1-code equality is a consequence, not a coincidence).
kernel void s1_8_g_contrast_apply_masked(texture2d<float, access::read> src [[texture(0)]],
                                         texture2d<float, access::write> dst [[texture(1)]],
                                         texture2d_array<float, access::read> atlas [[texture(2)]],
                                         constant ContrastParams &p [[buffer(0)]],
                                         constant LocalAdjustDesc *adjust [[buffer(1)]],
                                         uint2 gid [[thread_position_in_grid]]) {
    int w = p.d.x, h = p.d.y;
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    float4 px = src.read(gid);
    if (px.a == 0.0) { dst.write(px, gid); return; }
    float2 g = float2(gid);
    if (g.x < p.rect.x || g.y < p.rect.y
        || g.x >= p.rect.x + p.rect.z || g.y >= p.rect.y + p.rect.w) {
        dst.write(px, gid);
        return;
    }

    float Y = max(dot(max(px.rgb, 0.0), p.luma.xyz), 1e-9);

    // The mask's own linear gain belongs in the coordinate. S1.6 applies the mask's exposure × white
    // balance to the pixels under it, so `Y` already carries that gain; the contrast curve must see
    // the *unexposed* picture to stay the same operation inside and outside the mask (159's
    // `maskGain`, kept for the same reason). An identity gain is skipped rather than multiplied: the
    // Rec2020 weights sum to `0.99999994`, so `mix(1, dot(1, lw), w)` is not exactly 1 and would move
    // a high-contrast document by a code.
    float maskGain = 1.0;
    for (uint i = 0; i < uint(max(p.d.z, 0)); ++i) {
        LocalAdjustDesc d = adjust[i];
        if (d.a.w <= 0.0) { continue; }                 // amount 0: S1.6 skips it too
        if (all(d.a.xyz == float3(1.0))) { continue; }  // gain exactly 1: nothing to fold in
        float a = atlas.read(gid, i).r;
        float wgt = clamp(a * d.a.w, 0.0, 1.0);
        if (wgt <= 0.0) { continue; }
        maskGain *= mix(1.0, dot(d.a.xyz, p.luma.xyz), wgt);
    }
    float exposure = max(p.a.z * maskGain, 1e-9);

    // Global contrast first (the document's own slider), then each mask's contrast multiplied in with
    // its coverage — 「先全局、后局部」, the same order every other masked control uses.
    float ratio = s2_5_global_gain(Y, p.a.x, p.a.y, exposure, p.a.w);
    for (uint i = 0; i < uint(max(p.d.z, 0)); ++i) {
        LocalAdjustDesc d = adjust[i];
        if (d.b.x == 0.0 || d.a.w <= 0.0) { continue; }
        float a = atlas.read(gid, i).r;
        float wgt = clamp(a * d.a.w, 0.0, 1.0);
        if (wgt <= 0.0) { continue; }
        float travel = d.c.y > 0.0 ? d.c.y : p.a.w;
        float gMask = s2_5_global_gain(Y, d.b.x, p.a.y, exposure, travel);
        // A full-coverage mask is the global slider, not a `mix` of it: at `wgt == 1` use the gain
        // itself, because `1 + (g − 1)` rounds and the extreme gains here would show that rounding.
        ratio *= (wgt >= 1.0 ? gMask : mix(1.0, gMask, wgt));
    }
    dst.write(float4(max(px.rgb, 0.0) * ratio, px.a), gid);
}
