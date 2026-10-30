#include <metal_stdlib>
#include "oklch_bands.metal"
using namespace metal;

// S3.9 — 纹理 / 清晰度 (2026-10-28, P0-6; 078 B4 / 079); 164 adds the two **denoise** controls.
//
// The 效果 card's second block, in the place Lightroom puts the two Presence detail controls: the
// picture's detail is shaped here — and only then does S3c darken the corners, so the vignette's own
// falloff can never be mistaken for detail. 去雾 used to be the third operator of this stage; 117
// moved it to S1.9 (`s1_9_dehaze.metal`) in the scene-linear domain, where the airlight is a measured
// quantity instead of display white. This file is the guided filter only.
//
//   · **纹理 / 清晰度** — the **guided filter** of He/Sun/Tang (2010), steered by the picture's own
//     luma and used as the *base* layer: `base = a·I + b` with `a = var/(var+ε)`,
//     `b = mean_I·(1 − a)` (self-guidance, `p = I`), computed at `1/q` resolution and upsampled at
//     reconstruction — the same split `s1_7_mask_neighbourhood.metal`'s refine uses, for the same
//     reason (the regression at full resolution is nine times the frame budget).
//     The band is the **residual** `I − base`, boosted by the amount: `I' = I + amt·(I − base)`.
//
//     清晰度 is that residual at a mid radius (a few percent of the frame's short edge), 纹理 at a
//     small one (a few px). Three things make this *not* an unsharp mask, and the third is the one that
//     had to be added after measuring the first two:
//
//       1. where the window's variance is large — a **structural edge** — `a → 1`, so `base → I`, so
//          the residual shrinks. The statistics are solved on `q × q` block averages, so fine texture
//          averages out of the regression and only **structure** raises `a`: the gate follows scale as
//          well as amplitude, which is what lets 纹理 sit in the 2…8 px band and leave an edge alone.
//       2. `ε` is an amplitude threshold: a 0.05 texture (variance 2.5e-3) keeps ~60 % of its residual,
//          an edge's block (variance ~5e-2) keeps ~8 %.
//       3. **the gradient gate.** 1 + 2 are *not* enough: `base` is a window mean, so 3…6 px either
//          side of a strong edge `(I − base)` is still large while `a` has already fallen — the
//          classic guided-filter halo, merely reduced. So the coefficient pass also measures the
//          gradient of the **window mean** and writes `gate = 1 − smoothstep(g0, g1, |∇mean_I|)`:
//          a step moves `mean_I` by ~0.1 per 1/q texel, a texture pattern moves it not at all. The
//          gate is upsampled with the coefficients and multiplies the residual. Measured on the
//          suite's step edge: 0.00 codes of overshoot against 32.26 for the same-radius unsharp.
//
// Everything is in the **display-referred** domain (post S2/S3, pre S4), like S3c/S3.7. The stage
// exists only when at least one amount is non-zero (`RenderStage.pipeline(hasDetailFX:)`), so a
// neutral document never reaches this file: 中性 is "not encoded", not "encoded and multiplied by 0".
//
// 164 — **去噪 / 去彩噪**, the new 细节 card's two numbers:
//
//   · **luminance** reuses this file's own guided-filter residual at the smallest radius (the
//     texture band's statistics, one box pair), and mixes the luma **towards** the base layer:
//     `I' = I + amt·(base − I)`. At a flat patch `base` is the local mean, so noise is averaged; at a
//     structural edge `a → 1` so `base → I`, and the gradient gate holds the residual off. The
//     correction is applied equally to the three channels, so it moves luminance only.
//   · **chroma** converts to OKLab, scales `C` by `1 − 0.9·amt`, converts back, and restores the
//     **Rec.709 luminance** with one common gain. A grey card arrives at `C ≈ 1e-8` and is skipped
//     (`C <= 1e-6`), so it cannot gain a tint; a coloured pixel keeps its `Y` by construction.
//
// Both are inside the **same** full-resolution apply pass as 纹理/清晰度 (one extra coefficient map,
// no extra frame read), and both branches are skipped entirely at 0, which is what keeps the
// pre-164 frame byte for byte when the two new sliders are untouched.

// MARK: - parameters

struct DetailFXParams {
    // texture, clarity amounts (−1…1 each, i.e. the document's −100…100 after /100)
    float4 a;
    // luma weights (Rec.709), pad
    float4 luma;
    // texture: epsilon · clarity: epsilon · pad · pad
    float4 d;
    // gradient gate: g0, g1 (luma per 1/q texel), pad, pad
    float4 e;
    // canvasW, canvasH, q (statistics block), radius in the 1/q domain
    int4 b;
    // qW, qH, segment length, pad
    int4 c;
    // 164: denoise luma amount, denoise chroma amount (0…1), pad, pad
    float4 f;
};

static inline float s3_8_luma(float3 rgb, float3 w) {
    return dot(rgb, w);
}

// MARK: - guided filter: statistics at 1/q

/// One texel per `q × q` block: `(mean I, mean I², 0, 1)`. The block average is what keeps fine
/// texture out of the regression (see the header): at `q = 4` a 2 px pattern averages away, a step
/// edge does not.
kernel void s3_8_guide_pack(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> packed [[texture(1)]],
                            constant DetailFXParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int qW = p.c.x, qH = p.c.y, q = max(p.b.z, 1);
    if (int(gid.x) >= qW || int(gid.y) >= qH) { return; }
    int w = p.b.x, h = p.b.y;
    float3 lw = p.luma.xyz;

    float sumI = 0.0, sumII = 0.0;
    int n = 0;
    for (int dy = 0; dy < q; ++dy) {
        int y = min(int(gid.y) * q + dy, h - 1);
        for (int dx = 0; dx < q; ++dx) {
            int x = min(int(gid.x) * q + dx, w - 1);
            float I = s3_8_luma(max(src.read(uint2(x, y)).rgb, 0.0), lw);
            sumI += I; sumII += I * I;
            n += 1;
        }
    }
    float inv = 1.0 / float(max(n, 1));
    packed.write(float4(sumI * inv, sumII * inv, 0.0, 1.0), gid);
}

/// Separable box mean of the two statistics channels. Running sum (two reads per output whatever
/// the radius), edge-replicated, one thread per segment of `p.c.z` texels — the same shape as
/// `s1_7_box4_h/v`, so a 55 px clarity radius costs the same as a 4 px one.
kernel void s3_8_guide_box_h(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant DetailFXParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int qW = p.c.x, qH = p.c.y;
    int row = int(gid.y);
    if (row >= qH) { return; }
    int x0 = int(gid.x) * p.c.z;
    if (x0 >= qW) { return; }
    int x1 = min(x0 + p.c.z, qW);
    int r = max(p.b.w, 0);
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

kernel void s3_8_guide_box_v(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant DetailFXParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int qW = p.c.x, qH = p.c.y;
    int col = int(gid.x);
    if (col >= qW) { return; }
    int y0 = int(gid.y) * p.c.z;
    if (y0 >= qH) { return; }
    int y1 = min(y0 + p.c.z, qH);
    int r = max(p.b.w, 0);
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

/// `stats = (mean I, mean I²)` → `coeff = (a, b, gate)`, with `p = I`:
/// `a = (mean_II − mean_I²) / (mean_II − mean_I² + ε)`, `b = mean_I·(1 − a)`.
///
/// **The gate** is the third channel, and it is what actually keeps an edge still. The guided filter
/// alone is not enough: `base` is a window mean, so 3…6 px either side of a strong edge `(I − base)` is
/// still large while `a` has already fallen towards 0 — the classic halo, only reduced. So the
/// coefficient's own **gradient of the window mean** gates the residual: a step changes `mean_I` from
/// one 1/q texel to the next (0.44 of luma over 4 px), a texture pattern averages out of the block means
/// and changes nothing. `gate = 1 − smoothstep(g0, g1, |∇mean_I|)` is 1 in texture and 0 at an edge, and
/// it is bilinearly upsampled with the coefficients, so the transition is as smooth as they are.
kernel void s3_8_guide_coeff(texture2d<float, access::read> stats [[texture(0)]],
                             texture2d<float, access::write> coeff [[texture(1)]],
                             constant DetailFXParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int x = int(gid.x), y = int(gid.y);
    if (x >= p.c.x || y >= p.c.y) { return; }
    float2 s = stats.read(gid).xy;
    float mI = s.x, mII = s.y;
    float var = max(mII - mI * mI, 0.0);
    float eps = max(p.d.x, 1e-9);
    float a = var / (var + eps);
    float b = mI * (1.0 - a);

    // Central difference of the *window mean*, one 1/q texel each way (clamped at the border).
    int xm = max(x - 1, 0), xp = min(x + 1, p.c.x - 1);
    int ym = max(y - 1, 0), yp = min(y + 1, p.c.y - 1);
    float gx = 0.5 * (stats.read(uint2(xp, y)).x - stats.read(uint2(xm, y)).x);
    float gy = 0.5 * (stats.read(uint2(x, yp)).x - stats.read(uint2(x, ym)).x);
    float g = max(abs(gx), abs(gy));
    float gate = 1.0 - smoothstep(p.e.x, max(p.e.y, p.e.x + 1e-4), g);

    coeff.write(float4(a, b, gate, 1.0), gid);
}

/// Full-resolution reconstruction of **both bands in one pass**: `base = a·I + b` per band (the
/// coefficients bilinearly upsampled from the `1/q` grid), `detail = I − base`, and
///
///     out = rgb + amt_tex·gate_tex·(I − base_tex) + amt_cla·gate_cla·(I − base_cla)
///
/// One pass rather than two because the two bands share their source: the second full-resolution read
/// of the frame was ~1.2 ms of the 4.10 Mpx budget for nothing. An inactive band binds the other's
/// coefficient map with amount 0, so there is one kernel, not two, and no branch.
///
/// The residual is added to **all three channels equally**, so the boost moves luminance and leaves
/// the chroma ratios alone; clamping happens once, at the end.
///
/// 171: the denoise is a **joint bilateral grid** (see `s3_9_denoise.metal`), not a third guided
/// band. `nrGrid` (index 5) is the blurred grid, `nrSigma` (index 6) the frame's noise estimate.
/// The luma amount is `p.f.x`; the chroma amount `p.f.y`. Both branches are guarded by `> 0`, so an
/// untouched 细节 card executes exactly the pre-164 instruction stream.
#define S3_9_CELL 8

/// Manual trilinear read. `texture3d` linear filtering is not available everywhere — when it is not,
/// Metal silently falls back to nearest, which would turn the slice into a stair-stepped lookup — so
/// the eight corners are fetched and lerped by hand. `c` is in texel coordinates; corners clamp.
static inline float4 s3_9_grid_read(texture3d<float, access::read> g, float3 c, uint3 dim) {
    float3 f = floor(c);
    float3 t = c - f;
    int3 i0 = int3(f);
    int3 i1 = i0 + 1;
    int3 m = int3(dim) - 1;

    int3 a = clamp(i0, int3(0), m);
    int3 b = clamp(i1, int3(0), m);

    float4 c000 = g.read(uint3(a.x, a.y, a.z));
    float4 c100 = g.read(uint3(b.x, a.y, a.z));
    float4 c010 = g.read(uint3(a.x, b.y, a.z));
    float4 c110 = g.read(uint3(b.x, b.y, a.z));
    float4 c001 = g.read(uint3(a.x, a.y, b.z));
    float4 c101 = g.read(uint3(b.x, a.y, b.z));
    float4 c011 = g.read(uint3(a.x, b.y, b.z));
    float4 c111 = g.read(uint3(b.x, b.y, b.z));

    float4 c00 = mix(c000, c100, t.x);
    float4 c10 = mix(c010, c110, t.x);
    float4 c01 = mix(c001, c101, t.x);
    float4 c11 = mix(c011, c111, t.x);
    return mix(mix(c00, c10, t.y), mix(c01, c11, t.y), t.z);
}

kernel void s3_8_guide_apply(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::sample> coeffTex [[texture(1)]],
                             texture2d<float, access::sample> coeffCla [[texture(2)]],
                             texture2d<float, access::write> dst [[texture(3)]],
                             texture3d<float, access::read> nrGrid [[texture(5)]],
                             texture2d<float, access::read> nrSigma [[texture(6)]],
                             constant DetailFXParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int w = p.b.x, h = p.b.y;
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    int q = max(p.b.z, 1);
    float2 uv = float2((float(gid.x) + 0.5) / (float(q) * float(p.c.x)),
                       (float(gid.y) + 0.5) / (float(q) * float(p.c.y)));
    float4 t = coeffTex.sample(linearSampler, uv);
    float4 c = coeffCla.sample(linearSampler, uv);

    float4 px = src.read(gid);
    float3 rgb = max(px.rgb, 0.0);
    float I = s3_8_luma(rgb, p.luma.xyz);
    float baseTex = clamp(t.x * I + t.y, 0.0, 2.0);
    float baseCla = clamp(c.x * I + c.y, 0.0, 2.0);
    float amountTex = clamp(p.a.x, -1.0, 1.0);
    float amountCla = clamp(p.a.y, -1.0, 1.0);
    float delta = amountTex * clamp(t.z, 0.0, 1.0) * (I - baseTex)
                + amountCla * clamp(c.z, 0.0, 1.0) * (I - baseCla);

    // 171 — luminance denoise: slice the bilateral grid and add the difference from the pixel's own
    // luma to all three channels (luminance only, the chroma ratios stay put).
    float amountNR = clamp(p.f.x, 0.0, 1.0);
    if (amountNR > 0.0) {
        float r = clamp((0.4 + 0.6 * amountNR) * nrSigma.read(uint2(0, 0)).x, 0.010, 0.050);
        uint3 dim = uint3(nrGrid.get_width(), nrGrid.get_height(), nrGrid.get_depth());
        float3 c = float3((float(gid.x) + 0.5) / float(S3_9_CELL) - 0.5,
                          (float(gid.y) + 0.5) / float(S3_9_CELL) - 0.5,
                          clamp(I / r, 0.0, 39.0));
        float4 slice = s3_9_grid_read(nrGrid, c, dim);
        float wsum = max(slice.w, 1e-6);
        float Lbar = slice.x / wsum;
        delta += amountNR * (Lbar - I);
    }
    float3 outRGB = clamp(rgb + delta, 0.0, 4.0);

    // 171 — chroma denoise: run the same slice at the pixel's own luma and mix its a/b towards the
    // grid's mean. A neutral pixel has C ≈ 1e-8 and is skipped entirely, so a grey card cannot be
    // tinted by the fold's rounding. A common Rec.709 gain puts the luma back where it was.
    float amountCNR = clamp(p.f.y, 0.0, 1.0);
    if (amountCNR > 0.0) {
        float3 lab = oklab_raw(outRGB);
        float chroma = length(lab.yz);
        if (chroma > 1e-6) {
            float amtL = clamp(p.f.x, 0.0, 1.0);
            float r = clamp((0.4 + 0.6 * amtL) * nrSigma.read(uint2(0, 0)).x, 0.010, 0.050);
            float Ic = s3_8_luma(outRGB, p.luma.xyz);
            uint3 dim = uint3(nrGrid.get_width(), nrGrid.get_height(), nrGrid.get_depth());
            float3 c = float3((float(gid.x) + 0.5) / float(S3_9_CELL) - 0.5,
                              (float(gid.y) + 0.5) / float(S3_9_CELL) - 0.5,
                              clamp(Ic / r, 0.0, 39.0));
            float4 slice = s3_9_grid_read(nrGrid, c, dim);
            float wsum = max(slice.w, 1e-6);
            float abar = slice.y / wsum;
            float bbar = slice.z / wsum;
            float a2 = mix(lab.y, abar, amountCNR);
            float b2 = mix(lab.z, bbar, amountCNR);
            float C = length(float2(a2, b2));
            float hue = atan2(b2, a2) * (180.0 / M_PI_F);
            float3 reduced = oklch_to_linear(lab.x, C, hue);
            // Hold the **Rec.709 luminance**, not merely OKLab L: a common gain puts `Y` back where
            // it was, so the control moves chroma and leaves the luma untouched by construction.
            float y0 = s3_8_luma(outRGB, p.luma.xyz);
            float y1 = s3_8_luma(reduced, p.luma.xyz);
            if (y1 > 1e-6) { reduced *= max(y0, 0.0) / y1; }
            outRGB = clamp(reduced, 0.0, 4.0);
        }
    }
    dst.write(float4(outRGB, px.a), gid);
}

