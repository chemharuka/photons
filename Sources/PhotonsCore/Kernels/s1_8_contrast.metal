#include <metal_stdlib>
#include "primaries.metal"
using namespace metal;

// S1.8 — **contrast**, a multiscale edge-aware decomposition of `Y` in the scene-linear domain
// (098). Runs after the curve and before S2, so the tone map only does its three region lifts.
//
// The old contrast was a global bend in S2 over `L = log2(luma)` with a held core and hard-wired
// black/white end points. It was exactly zero for `L ≥ 0`, i.e. every HDR sample above display white
// passed through untouched — the defect 098 starts from. This stage has no end points at all: the
// only anchor is a fixed pivot `P = −3.5 EV` and three multiplicative gains, so the same arithmetic
// expands a mid-tone and an 8× highlight.
//
//     Y   = max(dot(max(rgb, 0), kWorkingLumaWeights), 1e-6)
//     G   = log2(Y)
//     B_c = GF(G,  r_c, ε_c)          // coarse base
//     D1  = G − B_c
//     B_m = GF(D1, r_m, ε_m)          // mid band
//     D_f = D1 − B_m                  // fine band (no filter)
//     G′  = P + k_c·(B_c − P) + gate·(k_m·B_m + k_f·D_f)
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
// only `B_m` and `D_f`; the coarse base `B_c` is left alone (it is the "whole-picture" tone axis,
// not a detail band).
//
// There is **no upper clamp**: `exp2` and a multiply, like S2's region lifts, so an HDR sample can be
// expanded past display white and S4's headroom decides what is written.
//
// The numbers below are the `.metal` copy of `MultiscaleContrast` (Swift). A test parses this file
// and asserts the two copies are equal, the way `ContrastLogDomainTests` did for `CT_*`.

struct ContrastParams {
    // t (= contrast/100), pivot EV, coarse ε, mid ε
    float4 a;
    // k_c, k_m, k_f, gate lower knee
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
    // mode (0 = G statistics, 1 = D1 statistics), pad, pad, pad
    int4 f;
};

// ── the Swift constants' `.metal` copy (`MultiscaleContrast`) ─────────────────────────────────
constant float MC_PIVOT_EV = -3.5;
constant float MC_EPS_C = 0.010;
constant float MC_EPS_M = 0.004;
constant float MC_W_C = 1.00;
constant float MC_W_M = 0.50;
constant float MC_W_F = 0.25;
constant float MC_GATE_LO = 0.015;
constant float MC_GATE_HI = 0.06;
constant float MC_R_C_FRAC = 0.06;
constant float MC_R_M_FRAC = 0.02;
constant int MC_R_C_CAP = 96;
constant int MC_R_M_CAP = 24;
constant int MC_BLOCK = 4;

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
                                 constant ContrastParams &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    int qW = p.e.x, qH = p.e.y, q = max(p.d.z, 1);
    if (int(gid.x) >= qW || int(gid.y) >= qH) { return; }

    if (p.f.x == 0) {
        int w = p.d.x, h = p.d.y;
        float sumG = 0.0, sumGG = 0.0;
        int n = 0;
        for (int dy = 0; dy < q; ++dy) {
            int y = min(int(gid.y) * q + dy, h - 1);
            for (int dx = 0; dx < q; ++dx) {
                int x = min(int(gid.x) * q + dx, w - 1);
                float G = log2(s1_8_g_luma(src.read(uint2(x, y)).rgb));
                sumG += G; sumGG += G * G;
                n += 1;
            }
        }
        float inv = 1.0 / float(max(n, 1));
        packed.write(float4(sumG * inv, sumGG * inv, 0.0, 1.0), gid);
    } else {
        int w = p.d.x, h = p.d.y;
        constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
        float sumD = 0.0, sumDD = 0.0;
        int n = 0;
        for (int dy = 0; dy < q; ++dy) {
            int y = min(int(gid.y) * q + dy, h - 1);
            for (int dx = 0; dx < q; ++dx) {
                int x = min(int(gid.x) * q + dx, w - 1);
                float G = log2(s1_8_g_luma(src.read(uint2(x, y)).rgb));
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
/// the radius), edge-replicated, one thread per segment of `p.e.z` texels — the same shape as
/// `s3_8_guide_box_h/v`.
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
    float inv = 1.0 / float(2 * r + 1);
    float2 acc = float2(0.0);
    for (int i = x0 - r; i <= x0 + r; ++i) {
        acc += src.read(uint2(clamp(i, 0, qW - 1), row)).xy;
    }
    for (int x = x0; x < x1; ++x) {
        dst.write(float4(acc * inv, 0.0, 1.0), uint2(x, row));
        acc += src.read(uint2(clamp(x + r + 1, 0, qW - 1), row)).xy
             - src.read(uint2(clamp(x - r, 0, qW - 1), row)).xy;
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
    float inv = 1.0 / float(2 * r + 1);
    float2 acc = float2(0.0);
    for (int i = y0 - r; i <= y0 + r; ++i) {
        acc += src.read(uint2(col, clamp(i, 0, qH - 1))).xy;
    }
    for (int y = y0; y < y1; ++y) {
        dst.write(float4(acc * inv, 0.0, 1.0), uint2(col, y));
        acc += src.read(uint2(col, clamp(y + r + 1, 0, qH - 1))).xy
             - src.read(uint2(col, clamp(y - r, 0, qH - 1))).xy;
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

/// Full-resolution reconstruction: both coefficient maps bilinearly upsampled, the three bands
/// rebuilt from `G`, and **one** gain applied to all three channels.
kernel void s1_8_g_contrast_apply(texture2d<float, access::read> src [[texture(0)]],
                                  texture2d<float, access::sample> coeffC [[texture(1)]],
                                  texture2d<float, access::sample> coeffM [[texture(2)]],
                                  texture2d<float, access::write> dst [[texture(3)]],
                                  constant ContrastParams &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    int w = p.d.x, h = p.d.y;
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    float4 px = src.read(gid);
    // Matte and alpha-0 pixels are written back unchanged: no photograph, no contrast.
    if (px.a == 0.0) { dst.write(px, gid); return; }
    float2 g = float2(gid);
    if (g.x < p.rect.x || g.y < p.rect.y
        || g.x >= p.rect.x + p.rect.z || g.y >= p.rect.y + p.rect.w) {
        dst.write(px, gid);
        return;
    }

    float Y = s1_8_g_luma(px.rgb);
    float G = log2(Y);

    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    int q = max(p.d.z, 1);
    float2 uv = float2((float(gid.x) + 0.5) / (float(q) * float(p.e.x)),
                       (float(gid.y) + 0.5) / (float(q) * float(p.e.y)));
    float4 cC = coeffC.sample(linearSampler, uv);
    float4 cM = coeffM.sample(linearSampler, uv);

    float Bc = cC.x * G + cC.y;
    float D1 = G - Bc;
    float Bm = cM.x * D1 + cM.y;
    float Df = D1 - Bm;

    float gate = clamp(cM.z, 0.0, 1.0);
    float Gp = p.a.y + p.b.x * (Bc - p.a.y)
             + gate * (p.b.y * Bm + p.b.z * Df);
    float ratio = exp2(Gp - G);

    float3 outRGB = max(px.rgb, 0.0) * ratio;
    dst.write(float4(outRGB, px.a), gid);
}
