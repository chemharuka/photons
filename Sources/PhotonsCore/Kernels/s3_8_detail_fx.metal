#include <metal_stdlib>
using namespace metal;

// S3.8 — 纹理 / 清晰度 / 去雾 (2026-10-28, P0-6; 078 B4 / 079).
//
// The 效果 card's third block, in the place Lightroom puts the three controls (Presence, before the
// vignette): the veil comes off the picture, then its detail is shaped — and only then does S3c
// darken the corners, so the vignette's own falloff can never be mistaken for detail.
//
// Two operators, one arithmetic idea each:
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
//   · **去雾** — the dark channel prior (He/Sun/Tang 2010), simplified and written down:
//
//       D(x) = min_{c} min_{y∈Ω(x)} I_c(y)        (dark channel, Ω = the frame-relative window)
//       t(x) = 1 − ω·D(x)                          (transmission; ω = 0.95 keeps a trace of haze)
//       A    = 1                                   (airlight = the display white point — the one
//                                                   simplification: He estimates A from the top 0.1 %
//                                                   of the dark channel, which needs a histogram of
//                                                   the frame; a display-referred picture's haze is
//                                                   whitish, so A = 1 is the same model with the
//                                                   airlight fixed at the only value the encoding
//                                                   guarantees)
//       J(x) = (I(x) − A) / max(t(x), t0) + A      (t0 = 0.1, He's floor)
//
//     D is computed at `1/q` (block minimum, then a separable running minimum) and `t` is upsampled
//     bilinearly — the "transmission at low resolution" variant the paper itself recommends, at a
//     sixteenth of the pixels. A negative amount adds the veil back (`mix(I, 0.6·I + 0.4, −amt)`),
//     so the slider is symmetric about 0 and 0 is exactly the identity.
//
// Everything is in the **display-referred** domain (post S2/S3, pre S4), like S3c/S3.7. The stage
// exists only when at least one amount is non-zero (`RenderStage.pipeline(hasDetailFX:)`), so a
// neutral document never reaches this file: 中性 is "not encoded", not "encoded and multiplied by 0".

// MARK: - parameters

struct DetailFXParams {
    // texture, clarity, dehaze amounts (−1…1 each, i.e. the document's −100…100 after /100)
    float4 a;
    // luma weights (Rec.709), pad
    float4 luma;
    // texture: epsilon · clarity: epsilon · dehaze: ω · dehaze: t0
    float4 d;
    // gradient gate: g0, g1 (luma per 1/q texel), pad, pad
    float4 e;
    // canvasW, canvasH, q (statistics block), radius in the 1/q domain
    int4 b;
    // qW, qH, segment length, pad
    int4 c;
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
kernel void s3_8_guide_apply(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::sample> coeffTex [[texture(1)]],
                             texture2d<float, access::sample> coeffCla [[texture(2)]],
                             texture2d<float, access::write> dst [[texture(3)]],
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
    dst.write(float4(clamp(rgb + delta, 0.0, 4.0), px.a), gid);
}

// MARK: - dark channel prior: transmission at 1/q

/// Per `q × q` block, the **dark channel**: `min` over the block of `min` over channels. `min` is
/// associative, so the block minimum followed by a separable running minimum is exactly the window
/// minimum the paper's `Ω(x)` asks for (at `1/q` resolution, which is where the transmission lives).
kernel void s3_8_dark_pack(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> packed [[texture(1)]],
                           constant DetailFXParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
    int qW = p.c.x, qH = p.c.y, q = max(p.b.z, 1);
    if (int(gid.x) >= qW || int(gid.y) >= qH) { return; }
    int w = p.b.x, h = p.b.y;
    float m = 1.0;
    for (int dy = 0; dy < q; ++dy) {
        int y = min(int(gid.y) * q + dy, h - 1);
        for (int dx = 0; dx < q; ++dx) {
            int x = min(int(gid.x) * q + dx, w - 1);
            m = min(m, min(min(src.read(uint2(x, y)).r, src.read(uint2(x, y)).g),
                           src.read(uint2(x, y)).b));
        }
    }
    packed.write(float4(m, 0.0, 0.0, 1.0), gid);
}

/// Horizontal running **minimum** (van Herk-style two-pass would be faster; a plain O(r) sliding
/// window is enough at `1/q`, where the clarity radius of 55 px is 14 texels here and the whole pass
/// is a sixteenth of the frame).
kernel void s3_8_dark_min_h(texture2d<float, access::read> src [[texture(0)]],
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
    for (int x = x0; x < x1; ++x) {
        float m = 1.0;
        for (int i = x - r; i <= x + r; ++i) {
            m = min(m, src.read(uint2(clamp(i, 0, qW - 1), row)).r);
        }
        dst.write(float4(m, 0.0, 0.0, 1.0), uint2(x, row));
    }
}

kernel void s3_8_dark_min_v(texture2d<float, access::read> src [[texture(0)]],
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
    for (int y = y0; y < y1; ++y) {
        float m = 1.0;
        for (int i = y - r; i <= y + r; ++i) {
            m = min(m, src.read(uint2(col, clamp(i, 0, qH - 1))).r);
        }
        dst.write(float4(m, 0.0, 0.0, 1.0), uint2(col, y));
    }
}

/// `t = 1 − ω·D` at `1/q`, then `max(t, t0)` — the floor He's paper puts at 0.1, applied where the
/// transmission is built so the full-resolution pass is one sample and one divide.
///
/// `A = 1` is this implementation's one simplification and it is a property of the *domain*, not a
/// shortcut: the data here is display-referred, where the airlight of a haze layer is the white point
/// (a veil `I = t·J + (1−t)` takes its own colour to 1). He estimates `A` from the top 0.1 % of the
/// dark channel because his input is scene radiance with no known white; the cost of that estimate is
/// an atomic reduction and one more pass, and its failure mode is worse than the assumption: with
/// `A = max(D)` a large uniformly bright region reads as 100 % haze (its own dark channel *is* the
/// airlight) and the recovery drives it to black — measured on the suite's first fixture, linear RMS
/// 0.098 → 0.061, i.e. 0.62×, the opposite of the control's job. `A = 1` recovers 2.5× on the same
/// veil (σ/µ), and the dark channel's own requirement — that the picture reaches near-zero somewhere
/// in every window, the prior itself — is what a photograph satisfies.
kernel void s3_8_dark_trans(texture2d<float, access::read> dark [[texture(0)]],
                            texture2d<float, access::write> trans [[texture(1)]],
                            constant DetailFXParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.c.x || int(gid.y) >= p.c.y) { return; }
    float D = clamp(dark.read(gid).r, 0.0, 1.0);
    float omega = clamp(p.d.z, 0.0, 1.0);
    float t0 = clamp(p.d.w, 0.0, 1.0);
    float t = max(1.0 - omega * D, t0);
    trans.write(float4(t, 0.0, 0.0, 1.0), gid);
}

/// `J = (I − 1)/t + 1`, mixed by the amount: `out = I + amt·(J − I)`. A negative amount mixes the
/// other way — toward `0.6·I + 0.4`, a 0.4 veil — so −100 adds exactly the haze +100 was given.
kernel void s3_8_dehaze_apply(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::sample> trans [[texture(1)]],
                              texture2d<float, access::write> dst [[texture(2)]],
                              constant DetailFXParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int w = p.b.x, h = p.b.y;
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    int q = max(p.b.z, 1);
    float2 uv = float2((float(gid.x) + 0.5) / (float(q) * float(p.c.x)),
                       (float(gid.y) + 0.5) / (float(q) * float(p.c.y)));
    float t = max(trans.sample(linearSampler, uv).r, 1e-3);

    float4 c = src.read(gid);
    float3 rgb = max(c.rgb, 0.0);
    float amount = clamp(p.a.z, -1.0, 1.0);
    float3 outRGB;
    if (amount >= 0.0) {
        // `J = (I − 1)/t + 1` is the dark-channel-prior recovery with airlight A = 1, and it is only
        // meaningful for **display-referred** input. Above white the same expression *adds* light
        // (`I > 1 ⇒ (I−1)/t > I−1`), which made HDR highlights brighter as dehaze went up — a veil
        // removal must never brighten anything. So the model runs on `min(rgb, 1)` and the HDR tail
        // passes through untouched (`out == rgb` there, hence `out ≤ rgb` everywhere).
        float3 display = min(rgb, 1.0);
        float3 clear = (display - 1.0) / t + 1.0;
        clear = select(clear, rgb, rgb > 1.0);        // per-channel: keep >1 exactly as it was
        outRGB = mix(rgb, clear, amount);
    } else {
        float3 hazy = rgb * 0.6 + 0.4;
        outRGB = mix(rgb, hazy, -amount);
    }
    dst.write(float4(clamp(outRGB, 0.0, 4.0), c.a), gid);
}
