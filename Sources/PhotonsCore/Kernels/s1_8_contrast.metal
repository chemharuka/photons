#include <metal_stdlib>
#include "primaries.metal"
using namespace metal;

// S2.5 — **contrast**, a multiscale edge-aware decomposition of `Y` in the **display-referred**
// domain (159; the file keeps its 098 name so recorded traces and this header stay findable).
// Runs **after S2 (tone map)** and **before S3 (colour)**, so `Y` is the tone-mapped linear display
// light (white = 1 = 0 EV) rather than scene light.
//
// 098 put the same decomposition in the scene-linear domain with a fixed pivot of −3.5 EV. 142
// measured that this makes `exposure × contrast` non-commutative (p50 gain 0.666 at E0 vs 2.695 at
// E+2, 74 % of pixels changing sign), because a gain anchored to an absolute level is not invariant
// under a change of the level. 159 moves the decomposition to display values and makes every term a
// **residual**: multiplying the picture by an exposure gain shifts `G` and `B_c` by the same amount,
// leaves `D1`, `B_m`, `D_f` and the gate unchanged, and therefore leaves the contrast gain unchanged.
//
//     Y   = max(dot(max(rgb, 0), kWorkingLumaWeights), 1e-6)
//     G   = log2(Y)                              // display EV, white = 0
//     B_c = GF(G,  r_c, ε_c)                     // coarse base
//     D1  = G − B_c
//     B_m = GF(D1, r_m, ε_m)                     // mid band
//     D_f = D1 − B_m                             // fine band (no filter)
//     G′  = G + gate·(k_m·B_m + k_f·D_f)         // k_m = W_m·t, k_f = W_f·t, t = contrast/100
//     rgb′= max(rgb, 0) · 2^(G′ − G)
//
// Only `Y` is filtered, and the ratio `2^(G′−G)` multiplies all three channels: `R/Y`, `G/Y`, `B/Y`
// are unchanged, so colour and saturation are preserved by construction.
//
// **The guided filter** is copied from `s3_8_detail_fx.metal` (same pack → box → coeff → apply
// shape, same gate), but in a different domain and with a different consumer. It is deliberately a
// separate file: the display-referred S3.9 bands must be free to change without moving this stage.
//
// **The gate** is the one addition that makes the decomposition halo-free: `base` is a window mean,
// so several texels either side of a strong edge still have a large residual while `a` has already
// fallen. `gate = 1 − smoothstep(g0, g1, |∇mean_D1|)` is 1 in texture and 0 at an edge. It multiplies
// only the two detail bands; there is no level term left to leave alone.
//
// **Why the constants differ from 098 (159 §1.2).** The display coordinate is ~1/4 as wide as the
// scene-linear one (a tone-mapped frame spans ~2.3 EV where the scene spans 4+), so the same numbers
// would make the local detail *weaker* in the new domain. `MC_W_M`/`MC_W_F` are 15×/7.5× 098's travel (the display log is ~4× narrower and the response is not linear in the weights), `MC_GATE_LO/HI` are soft (0.05/2.0, mostly open), and the eps values are chosen so the decomposition keeps a residual (0.8/0.32).
// `MC_PIVOT_EV` is 0 (display white) and is carried only so a log line names the coordinate; the
// kernel does not add a level back.
//
// There is **no upper clamp**: `exp2` and a multiply, like S2's region lifts, so an HDR sample can be
// expanded past display white and S4's headroom decides what is written.
//
// The numbers below are the `.metal` copy of `MultiscaleContrast` (Swift). A test parses this file
// and asserts the two copies are equal, the way `ContrastLogDomainTests` did for `CT_*`.

struct ContrastParams {
    // t (= contrast/100), pivot EV, coarse ε, mid ε
    float4 a;
    // k_m, k_f, pad, gate lower knee
    float4 b;
    // gate upper knee, pad, pad, pad
    float4 c;
    // Rec2020 luma weights, pad
    float4 luma;
    // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox/alpha guard
    float4 rect;
    // canvasW, canvasH, q (statistics block), coarse radius in the 1/q domain
    int4 d;
    // qW, qH, segment length, mid radius in the 1/q domain
    int4 e;
    // mode (0 = G statistics, 1 = D1 statistics), mask count (masked apply), direct-read flag
    // (187: the proxy canvas *is* the picture grid), pad
    int4 f;
    // 187 — the whole-picture coefficient map's mapping. `map = (uvScaleX, uvScaleY, spanX, spanY)`;
    // `mapOrigin = (frameOrigin.xy, contentOrigin.xy)`; `srcMax` maps a **picture** pixel to the
    // proxy canvas (`+ offset` then `× scale`), used only by the pack passes.
    float4 map;
    float4 mapOrigin;
    float4 srcMax;
};

/// 187 — one source texel of the *picture* grid. `p.f.z == 1` is the canonical case (the proxy
/// canvas **is** the picture grid): read, bit-exact, no resample. Otherwise the picture pixel maps
/// into the proxy canvas (`s0_geometry`'s own `gid + ½ − origin + frameOrigin` rule, inverted).
static inline float3 s1_8_fetch(texture2d<float, access::read> srcR,
                                texture2d<float, access::sample> srcS,
                                constant ContrastParams &p, int x, int y) {
    if (p.f.z == 1) { return srcR.read(uint2(uint(x), uint(y))).rgb; }
    float2 pos = float2(float(x), float(y)) * p.srcMax.xy + p.srcMax.zw;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    return srcS.sample(s, (pos + 0.5) / float2(float(p.d.x), float(p.d.y))).rgb;
}

/// The mask descriptor S1.6 also uses (`s1_6_local.metal#LocalAdjustDesc`), declared here because a
/// kernel cannot include another kernel. Byte-for-byte the same three `float4`s; `.b.x` is the
/// mask's contrast slider and `.a.w` its amount.
struct LocalAdjustDesc {
    float4 a;
    float4 b;
    float4 c;
};

// ── the Swift constants' `.metal` copy (`MultiscaleContrast`) ─────────────────────────────────
constant float MC_PIVOT_EV = 0.0;
constant float MC_EPS_C = 0.80;
constant float MC_EPS_M = 0.32;
constant float MC_W_C = 0.00;
constant float MC_W_M = 7.50;
constant float MC_W_F = 3.75;
constant float MC_GATE_LO = 0.05;
constant float MC_GATE_HI = 2.00;
constant float MC_FLOOR_Y = 0.00110;   // linear light of display code ~0.0128 (A5)
constant float MC_R_C_FRAC = 0.06;
constant float MC_R_M_FRAC = 0.02;
constant int MC_R_C_CAP = 96;
constant int MC_R_M_CAP = 24;
constant int MC_BLOCK = 4;
/// 187 — the negative slider's shrink cap (see `s2_5_band_weights`): `2^(MC_SHRINK·t)`.
constant float MC_SHRINK = 0.75;

static inline float s1_8_g_luma(float3 rgb) {
    return max(dot(max(rgb, 0.0), kWorkingLumaWeights), 1e-6);
}

// ── statistics: one texel per q × q block ───────────────────────────────────────────────────────

/// Mode 0: `(mean G, mean G², 0, 1)` from the full-resolution source.
///
/// Mode 1: the mid band's **input statistics**. `src` is the full-resolution source and `aux` the
/// coarse coefficient map; inside each `q × q` block it averages
/// `D1 = G − (a_c·G + b_c)` with the coefficients sampled at the pixel's own position, then writes
/// `(mean D1, mean D1², 0, 1)`. Computing the mean of `D1` from the *block* mean of `G` would always
/// give zero (the self-guided base interpolates that mean), so the residual has to be sampled per
/// pixel before it is averaged.
kernel void s1_8_g_contrast_pack(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> packed [[texture(1)]],
                                 texture2d<float, access::sample> aux [[texture(2)]],
                                 texture2d<float, access::write> residual [[texture(3)]],
                                 texture2d<float, access::sample> srcSample [[texture(4)]],
                                 constant ContrastParams &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    int qW = p.e.x, qH = p.e.y, q = max(p.d.z, 1);
    if (int(gid.x) >= qW || int(gid.y) >= qH) { return; }

    if (p.f.x == 0) {
        // 187 — the block loop walks the **picture** grid (`qW × qH`), which the proxy canvas may
        // exceed or fall short of. The direct-read path keeps the old canvas clamp (`p.d`); the
        // resampling path clamps to the picture grid and lets `clamp_to_edge` cover the margin.
        int wLimit = p.f.z == 1 ? p.d.x - 1 : q * qW - 1;
        int hLimit = p.f.z == 1 ? p.d.y - 1 : q * qH - 1;
        float sumG = 0.0, sumGG = 0.0;
        int n = 0;
        for (int dy = 0; dy < q; ++dy) {
            int y = min(int(gid.y) * q + dy, hLimit);
            for (int dx = 0; dx < q; ++dx) {
                int x = min(int(gid.x) * q + dx, wLimit);
                float G = log2(s1_8_g_luma(s1_8_fetch(src, srcSample, p, x, y))
                               / max(p.c.z, 1e-6));
                sumG += G; sumGG += G * G;
                n += 1;
            }
        }
        float inv = 1.0 / float(max(n, 1));
        packed.write(float4(sumG * inv, sumGG * inv, 0.0, 1.0), gid);
    } else {
        int wLimit = p.f.z == 1 ? p.d.x - 1 : q * qW - 1;
        int hLimit = p.f.z == 1 ? p.d.y - 1 : q * qH - 1;
        constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float sumD = 0.0, sumDD = 0.0;
        int n = 0;
        for (int dy = 0; dy < q; ++dy) {
            int y = min(int(gid.y) * q + dy, hLimit);
            for (int dx = 0; dx < q; ++dx) {
                int x = min(int(gid.x) * q + dx, wLimit);
                float G = log2(s1_8_g_luma(s1_8_fetch(src, srcSample, p, x, y))
                               / max(p.c.z, 1e-6));
                float2 uv = float2((float(x) + 0.5) / (float(q) * float(qW)),
                                   (float(y) + 0.5) / (float(q) * float(qH)));
                float4 c = aux.sample(linearSampler, uv);
                float d1 = G - (c.x * G + c.y);
                sumD += d1; sumDD += d1 * d1;
                n += 1;
            }
        }
        float inv = 1.0 / float(max(n, 1));
        residual.write(float4(sumD * inv, sumDD * inv, 0.0, 1.0), gid);
    }
}

/// Separable box mean of the two statistics channels. Running sum (two reads per output whatever
/// the radius), **edge-shrinking window**, one thread per segment of `p.e.z` texels — the same shape
/// as `s3_8_guide_box_h/v`.
///
/// **187 — the border divides by the true sample count, not by `2r+1`.** Through 185 the window was
/// edge-*replicated* (`clamp(i, 0, qW-1)`) and always divided by `2r+1`: the same edge texel was
/// counted up to `r+1` times, which deflates the window's **variance** exactly where the count is
/// inflated. The guided filter then reads `a = var/(var+ε) → 0` and `b → mean` on that band, the
/// residual there is ~0, and the gain collapses to 1.0 — the unchanged strip the user saw on all
/// four edges at `contrast = +100`. A shrinking window sees only texels that exist and divides by
/// how many it saw, so a border texel's variance is measured with the same arithmetic as an interior
/// one. The interior is bit-identical to before (same taps, same `1.0 / float(2*r+1)`), which is what
/// keeps the recorded interior measurements standing.
kernel void s1_8_g_contrast_box_h(texture2d<float, access::read> src [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  constant ContrastParams &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int qW = p.e.x, qH = p.e.y;
    int row = int(gid.y);
    if (row >= qH) { return; }
    int x0 = int(gid.x) * p.e.z;
    if (x0 >= qW) { return; }
    int x1 = min(x0 + p.e.z, qW);
    int r = max(p.e.w, 0);
    if (r == 0) {
        for (int x = x0; x < x1; ++x) { dst.write(src.read(uint2(x, row)), uint2(x, row)); }
        return;
    }
    int lo = max(x0 - r, 0), hi = min(x0 + r, qW - 1);
    float2 acc = float2(0.0);
    for (int i = lo; i <= hi; ++i) { acc += src.read(uint2(i, row)).xy; }
    for (int x = x0; x < x1; ++x) {
        int cl = max(x - r, 0), ch = min(x + r, qW - 1);
        float inv = 1.0 / float(ch - cl + 1);
        dst.write(float4(acc * inv, 0.0, 1.0), uint2(x, row));
        int nl = max(x + 1 - r, 0), nh = min(x + 1 + r, qW - 1);
        if (nh > ch) { acc += src.read(uint2(nh, row)).xy; }
        if (nl > cl) { acc -= src.read(uint2(cl, row)).xy; }
    }
}

kernel void s1_8_g_contrast_box_v(texture2d<float, access::read> src [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  constant ContrastParams &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int qW = p.e.x, qH = p.e.y;
    int col = int(gid.x);
    if (col >= qW) { return; }
    int y0 = int(gid.y) * p.e.z;
    if (y0 >= qH) { return; }
    int y1 = min(y0 + p.e.z, qH);
    int r = max(p.e.w, 0);
    if (r == 0) {
        for (int y = y0; y < y1; ++y) { dst.write(src.read(uint2(col, y)), uint2(col, y)); }
        return;
    }
    int lo = max(y0 - r, 0), hi = min(y0 + r, qH - 1);
    float2 acc = float2(0.0);
    for (int i = lo; i <= hi; ++i) { acc += src.read(uint2(col, i)).xy; }
    for (int y = y0; y < y1; ++y) {
        int cl = max(y - r, 0), ch = min(y + r, qH - 1);
        float inv = 1.0 / float(ch - cl + 1);
        dst.write(float4(acc * inv, 0.0, 1.0), uint2(col, y));
        int nl = max(y + 1 - r, 0), nh = min(y + 1 + r, qH - 1);
        if (nh > ch) { acc += src.read(uint2(col, nh)).xy; }
        if (nl > cl) { acc -= src.read(uint2(col, cl)).xy; }
    }
}

/// `stats = (mean I, mean I²)` → `coeff = (a, b, gate)`, with `p = I`: self-guided,
/// `a = var/(var + ε)`, `b = mean·(1 − a)`, and the gradient gate from the **window mean** (the same
/// body `s3_8_guide_coeff` uses). `p.f.x` picks the band's ε.
kernel void s1_8_g_contrast_coeff(texture2d<float, access::read> stats [[texture(0)]],
                                  texture2d<float, access::write> coeff [[texture(1)]],
                                  constant ContrastParams &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.e.x || y >= p.e.y) { return; }
    float2 s = stats.read(gid).xy;
    float mI = s.x, mII = s.y;
    float var = max(mII - mI * mI, 0.0);
    float eps = max(p.f.x == 0 ? p.a.z : p.a.w, 1e-9);
    float a = var / (var + eps);
    float b = mI * (1.0 - a);

    int xm = max(x - 1, 0), xp = min(x + 1, p.e.x - 1);
    int ym = max(y - 1, 0), yp = min(y + 1, p.e.y - 1);
    float gx = 0.5 * (stats.read(uint2(xp, y)).x - stats.read(uint2(xm, y)).x);
    float gy = 0.5 * (stats.read(uint2(x, yp)).x - stats.read(uint2(x, ym)).x);
    float g = max(abs(gx), abs(gy));
    float gate = 1.0 - smoothstep(p.b.w, max(p.c.x, p.b.w + 1e-4), g);

    coeff.write(float4(a, b, gate, 1.0), gid);
}

// ── the shared operator (159) ────────────────────────────────────────────────────────────────────
//
// One body for the global slider and for a mask's slider (079's 「同一滑杆蒙版内外同义」). The
// mask path differs only in *how many* contrast numbers are evaluated and in the coverage weight
// that mixes their gains: a full-canvas mask therefore runs this exact arithmetic once.
//
// `contrast` is the slider value (−100…100). The band weights are the constants above, so the
// mask's number rides the same travel as the global one. The ±3 EV bound is a shape cap, not a
// clamp on the picture: inside it the gain is the residual arithmetic exactly.
/// 187 — the two band weights for a slider value, in **residual units** (`d = wm·B_m + wf·D_f`).
///
/// The two signs are different laws, and this is the one place that says so:
///
///   · `t ≥ 0` — a *travel*: `W·t` EV of the band, so the residual grows to `1 + W·t`.
///   · `t < 0` — a *shrink*: the residual is multiplied by `2^(MC_SHRINK·t)` ∈ [0.59, 1), i.e. `k = 2^… − 1`,
///     and **no `W`**: the travel constants belong to amplification, not to removal. (Through 185
///     the same `t · MC_W` line ran on both sides, so at `t = −1` the mid band asked for
///     `−7.5·B_m` — a 7.5× *inverted* residual, which is the negative picture the user reported.)
///
/// `MultiscaleContrast.scaleGains` is the Swift copy of this function; the constants test pins the
/// two together.
static inline void s2_5_band_weights(float contrast, thread float &wm, thread float &wf) {
    float t = contrast / 100.0;
    if (t >= 0.0) {
        wm = t * MC_W_M;
        wf = t * MC_W_F;
    } else {
        // `MC_SHRINK` = 0.75: the residual is multiplied by `2^(0.75·t)` ∈ [0.59, 1). Halving it
        // (`2^t`) measures a −1.21-code drift of the picture's mean at `c = −100`; 0.75 lands at
        // −0.91, i.e. removing local contrast does not remove light (§2's ±1 code).
        float k = exp2(MC_SHRINK * t) - 1.0;
        wm = k;
        wf = k;
    }
}

static inline float s2_5_contrast_gain(float Bm, float Df, float gate, float contrast,
                                        float G, float logExposure) {
    float wm, wf;
    s2_5_band_weights(contrast, wm, wf);
    float d = clamp(gate * (wm * Bm + wf * Df), -3.0, 3.0);
    // The **white shoulder** (0107's `4u(1−u)` lesson): a positive gain fades to 0 at display
    // white, and is then capped at the light that still fits under it (`Y_output ≤ 0.98`). Nothing
    // below white can be pushed onto the ceiling. Darkening is not faded or capped — a highlight
    // that should come down must come down. The cap is read in the **unexposed** display log, the
    // same coordinate the decomposition uses, so a global exposure does not change which pixels
    // are near the shoulder (A3). At E = 0 this is the absolute white; at E > 0 the picture is
    // allowed into the extended range, which is what the export's tone map is for.
    if (d > 0.0) {
        d *= 1.0 - smoothstep(-1.0, 0.0, G);
        // The cap is only for pixels **below** white. A sample already above it is HDR picture:
        // expanding it is the 079 property S4's headroom exists for, and the export tone map is
        // what brings it back.
        if (G < log2(0.98)) { d = min(d, max(0.0, log2(0.98) - G)); }
    }
    return exp2(d);
}

/// A5's black floor, shared by both paths. A pixel that clears the floor is held at it; a pixel
/// already under it is never darkened further (it keeps its input value), so the fraction under the
/// display-code threshold cannot grow. The floor rides S1's exposure gain (`p.c.z`) so it scales
/// with the picture and the gain stays exposure-invariant.
static inline float3 s2_5_finish(float4 px, float ratio, float exposureGain, float3 lw) {
    float3 outRGB = max(px.rgb, 0.0) * ratio;
    float floorY = MC_FLOOR_Y * (exposureGain > 0.0 ? exposureGain : 1.0);
    float yIn = dot(max(px.rgb, 0.0), lw);
    float yOut = dot(outRGB, lw);
    if (yOut < floorY && yOut > 0.0) {
        float target = min(yIn, floorY);
        if (yOut < target) { outRGB *= target / yOut; }
    }
    return outRGB;
}

/// The bands of one pixel, rebuilt from the two upsampled coefficient maps.
static inline void s2_5_bands(float4 cC, float4 cM, float G,
                              thread float &Bm, thread float &Df, thread float &gate) {
    float Bc = cC.x * G + cC.y;
    float D1 = G - Bc;
    Bm = cM.x * D1 + cM.y;
    Df = D1 - Bm;
    gate = clamp(cM.z, 0.0, 1.0);
}

/// Full-resolution reconstruction, **global** path: both coefficient maps bilinearly upsampled,
/// the two residual bands rebuilt from `G`, and one gain applied to all three channels.
kernel void s1_8_g_contrast_apply(texture2d<float, access::read> src [[texture(0)]],
                                  texture2d<float, access::sample> coeffC [[texture(1)]],
                                  texture2d<float, access::sample> coeffM [[texture(2)]],
                                  texture2d<float, access::write> dst [[texture(3)]],
                                  constant ContrastParams &p [[buffer(0)]],
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

    // Display-referred (159): `Y` is tone-mapped light, white = 1 = 0 EV. The decomposition runs on
    // the **unexposed** display log (`Y / 2^E`), so S1's power-of-two exposure gives bit-identical
    // filter inputs and an identical residual gain (A1/A2).
    float Y = s1_8_g_luma(px.rgb);
    float G = log2(Y / max(p.c.z, 1e-6));

    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    int q = max(p.d.z, 1);
    // 187 — the picture-normalized position of this pixel, the same metric `s3_vignette` uses
    // (`uv = (px + ½ − contentOrigin + frameOrigin) / frameSize`), then into the coefficient map's
    // own q-grid. In the canonical case (`uvScale == 1`, offsets 0) this is the pre-187 expression
    // **bit for bit** — the identity path must not move a pixel.
    float2 imgPx = float2(gid) + 0.5 - p.mapOrigin.zw + p.mapOrigin.xy;
    float2 uv = imgPx * p.map.xy / p.map.zw;
    float4 cC = coeffC.sample(linearSampler, uv);
    float4 cM = coeffM.sample(linearSampler, uv);
    float Bm, Df, gate;
    s2_5_bands(cC, cM, G, Bm, Df, gate);

    float ratio = s2_5_contrast_gain(Bm, Df, gate, p.a.x, G, p.c.y);
    dst.write(float4(s2_5_finish(px, ratio, p.c.z, p.luma.xyz), px.a), gid);
}

/// Full-resolution reconstruction, **masked** path. Same bands, same `s2_5_contrast_gain`, and the
/// gains are mixed linearly by each mask's coverage × amount: a full-canvas mask with
/// `contrast = c` and no global contrast is bit-identical to the global slider at `c` (B1).
kernel void s1_8_g_contrast_apply_masked(texture2d<float, access::read> src [[texture(0)]],
                                         texture2d<float, access::sample> coeffC [[texture(1)]],
                                         texture2d<float, access::sample> coeffM [[texture(2)]],
                                         texture2d<float, access::write> dst [[texture(3)]],
                                         texture2d_array<float, access::read> atlas [[texture(5)]],
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

    float Y = s1_8_g_luma(px.rgb);
    // **The mask's own linear gain belongs in `G`.** S1.6 applies `v *= d.a.xyz` (the mask's exposure
    // EV × its white-balance gain) to the pixels under a mask, mixed in by coverage, so a masked
    // pixel's luminance carries that gain by the time this stage reads it. The coefficient maps were
    // built on the **whole-picture proxy**, which deliberately has no masks in it (187: masks do not
    // participate in the statistics), so the map's own `G` at this pixel is the *unmasked* one.
    // Dividing by `p.c.z` alone therefore read a `+0.5 EV` mask as a half-stop brighter picture and
    // answered with a different decomposition: a flat field at `c = +100` under a full-canvas
    // `+0.5 EV` mask landed on code 255 where the global `+0.5 EV` landed on 184, while `c = 0` (no
    // band) agreed on both sides — the mask gain was the only asymmetry.
    //
    // Rebuild the same luma gain S1.6 applied — `(1 − w) + w · dot(d.a.xyz, lw)` per mask, in mask
    // order, since S1.6 mixes in linear RGB and `Y` is linear in RGB — and put it under the `log2`
    // together with the global gain.
    //
    // **A gain of 1 must be skipped, not multiplied.** `lw` is the Rec2020 triple and its float32 sum
    // is `0.99999994`, not 1 (`0.2627f + 0.6780f + 0.0593f`, one ULP low), so `dot(float3(1), lw)` is
    // `1 − 2⁻²⁴` even for an identity mask. `mix(1, 1 − 2⁻²⁴, w)` is then ≠ 1 and five masks deepen it to
    // `0.9999997`: `log2` moves by −4.3e−7, the decomposition answers a slightly different picture and
    // a high-contrast document lands on a different code — the five-all-zero-masks document stopped
    // being byte-identical to the unmasked one (measured: `push` `1ccecf69…` vs golden `69f1abb3…`).
    // The identity vector is the "S1.6 multiplied by exactly 1" case, so the reconstruction is exactly
    // 1 and the multiply is dropped; that keeps the masked path bit-identical to `s1_8_g_contrast_apply`
    // when no mask changes anything.
    float maskGain = 1.0;
    for (uint i = 0; i < uint(max(p.f.y, 0)); ++i) {
        LocalAdjustDesc d = adjust[i];
        if (d.a.w <= 0.0) { continue; }             // amount 0: S1.6 skips it too
        if (all(d.a.xyz == float3(1.0))) { continue; } // gain exactly 1: nothing to fold in
        float a = atlas.read(gid, i).r;
        float wgt = clamp(a * d.a.w, 0.0, 1.0);
        if (wgt <= 0.0) { continue; }
        maskGain *= mix(1.0, dot(d.a.xyz, p.luma.xyz), wgt);
    }
    float G = log2(Y / max(p.c.z * maskGain, 1e-6));

    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    int q = max(p.d.z, 1);
    // 187 — the picture-normalized position of this pixel, the same metric `s3_vignette` uses
    // (`uv = (px + ½ − contentOrigin + frameOrigin) / frameSize`), then into the coefficient map's
    // own q-grid. In the canonical case (`uvScale == 1`, offsets 0) this is the pre-187 expression
    // **bit for bit** — the identity path must not move a pixel.
    float2 imgPx = float2(gid) + 0.5 - p.mapOrigin.zw + p.mapOrigin.xy;
    float2 uv = imgPx * p.map.xy / p.map.zw;
    float4 cC = coeffC.sample(linearSampler, uv);
    float4 cM = coeffM.sample(linearSampler, uv);
    float Bm, Df, gate;
    s2_5_bands(cC, cM, G, Bm, Df, gate);

    // Global contrast first (the document's own slider), then each mask's contrast multiplied in
    // with its coverage — 「先全局、后局部」, the same order every other masked control uses.
    float ratio = s2_5_contrast_gain(Bm, Df, gate, p.a.x, G, p.c.y);
    for (uint i = 0; i < uint(max(p.f.y, 0)); ++i) {
        LocalAdjustDesc d = adjust[i];
        if (d.b.x == 0.0 || d.a.w <= 0.0) { continue; }
        float a = atlas.read(gid, i).r;
        float wgt = clamp(a * d.a.w, 0.0, 1.0);
        if (wgt <= 0.0) { continue; }
        float gMask = s2_5_contrast_gain(Bm, Df, gate, d.b.x, G, p.c.y);
        // A full-coverage mask is the global slider, not a `mix` of it: at `wgt == 1` use the gain
        // itself, because `1 + (g − 1)` rounds and the extreme gains here would show that rounding.
        ratio *= (wgt >= 1.0 ? gMask : mix(1.0, gMask, wgt));
    }
    dst.write(float4(s2_5_finish(px, ratio, p.c.z, p.luma.xyz), px.a), gid);
}
