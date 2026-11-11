#include <metal_stdlib>
#include "primaries.metal"
using namespace metal;

// S1.65 — **linear-domain (scene-referred) luminance denoise**, the 365 prototype.
//
// This is deliberately a prototype, not a replacement for S3.9: it runs on the S1/S1.6 buffer
// (working primaries, linear light, before the curve and the tone map), exists only when the hidden
// `EditModel.linearDenoiseLuma` switch is non-zero, and a document with the switch at 0 never
// encodes a single pass of this file. S3.9's chroma denoise, 314's sharpen default and the export
// path are untouched.
//
// The algorithm is the same bilateral grid as S3.9 (Paris/Durand, after Halide's MIT
// `apps/bilateral_grid`) with the two changes this ticket asks for:
//
//   · **the z axis is log2 luma**, not linear luma. Scene-linear values span six decades (1e-6 …
//     4.0); 40 linear bins would leave the whole shadow region in one or two of them. `log2` makes
//     each bin a **constant relative step** (0.5 EV over the [-16, 4] EV window this file uses), so
//     the five-tap on z is a range kernel on *relative* error — which is what a sensor's shot noise
//     actually is (`σ/I ∝ 1/√I`).
//   · **the range scale is physical**: `s1_65_noise_model` fits `σ² = a·I + b` on the frame itself
//     (a 64 × 64 lattice, 8 intensity bins, weighted least squares) and the slice clamps its log
//     correction by the fitted `σ(I)/I`. The model is also what the A/B report prints.
//
// The black level is **not** re-derived here. 071/089/094 decided that `light.blackOffset` is the
// one place a negative linear value is lifted, and CIRAWFilter has already subtracted the DNG's
// BlackLevel once (measuring that is 365 §1.5.3; subtracting it again turns shadows black). When a
// caller runs with `blackOffset = 0` this prototype's entry does `max(rgb, 0)` and counts the
// clamped pixels in the model texture's `.w`, which is the number the report quotes as evidence
// that the clamp was the 4 % all-negative population and not a rounding detail.

#define S1_65_Z 40                  // z-axis bins
#define S1_65_LOG_LO (-16.0)        // log2 floor: eps = 2^-16
#define S1_65_LOG_HI 4.0            // 16 stops above eps, 0.5 EV per bin
#define S1_65_LOG_SPAN (S1_65_LOG_HI - S1_65_LOG_LO)
#define S1_65_Q 3276.75             // 20 stops → 65535, i.e. 1/3276.75 EV per integer step
#define S1_65_TILE 16
#define S1_65_LOAD (S1_65_TILE + 4)

struct S1_65Params {
    int4 canvas;   // x = w, y = h, z = cell, w = zBins
    int4 grid;     // x = gW, y = gH, z = pass axis, w = 0
    float4 n;      // x = amount (0…1), y = eps, z = logLo, w = logHi
    float4 fit;    // x = a, y = b, z = fit residual, w = clamped pixel ratio
};

// MARK: - noise model: σ² = a·I + b

/// Fit `σ² = a·I + b` on a 64 × 64 lattice (4096 samples).
///
/// The high-pass `D = I − mean3x3` removes 8/9 of a white noise variance
/// (`σ_D = sqrt(8/9)σ`), so the per-bin variance is multiplied back by 9/8. Samples are bucketed by
/// **log2 intensity** (8 bins over −12…2 EV); the fit is a weighted least squares over the bins that
/// hold enough samples (≥ 24), and `.z` is the RMS residual of that fit in σ² units — the honest
/// number for "how well does the affine model describe this frame".
///
/// `.w` is the fraction of the lattice whose *any* channel was negative before the entry clamp.
/// With `blackOffset = 0` on a frame like L1030994 it is the ~4 % all-negative population 094
/// measured; with the automatic black level applied it is 0.
kernel void s1_65_noise_model(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> model [[texture(1)]],
                              constant S1_65Params &p [[buffer(0)]],
                              uint tid [[thread_position_in_threadgroup]]) {
    threadgroup atomic_uint cnt[8];
    threadgroup atomic_uint sumI[8];
    threadgroup atomic_uint sumD2[8];
    threadgroup atomic_uint clampedCount;
    for (uint i = tid; i < 8; i += 256) {
        atomic_store_explicit(&cnt[i], 0u, memory_order_relaxed);
        atomic_store_explicit(&sumI[i], 0u, memory_order_relaxed);
        atomic_store_explicit(&sumD2[i], 0u, memory_order_relaxed);
    }
    if (tid == 0) { atomic_store_explicit(&clampedCount, 0u, memory_order_relaxed); }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int w = p.canvas.x, h = p.canvas.y;
    constexpr float binLo = -12.0, binHi = 2.0;
    const float binW = (binHi - binLo) / 8.0;
    const float eps = p.n.y;

    for (uint s = tid; s < 4096; s += 256) {
        int i = int(s) & 63;
        int j = int(s) >> 6;
        int x = clamp(int(round((float(i) + 0.5) * float(w) / 64.0)), 0, w - 1);
        int y = clamp(int(round((float(j) + 0.5) * float(h) / 64.0)), 0, h - 1);
        float4 px = src.read(uint2(x, y));
        bool clamped = px.r < 0.0 || px.g < 0.0 || px.b < 0.0;
        float3 rgb = max(px.rgb, 0.0);
        float I = dot(rgb, kWorkingLumaWeights);

        float sum = 0.0;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                float3 c = max(src.read(uint2(clamp(x + dx, 0, w - 1),
                                               clamp(y + dy, 0, h - 1))).rgb, 0.0);
                sum += dot(c, kWorkingLumaWeights);
            }
        }
        float D = I - sum / 9.0;
        int bin = clamp(int((log2(max(I, eps)) - binLo) / binW), 0, 7);
        uint qI = uint(round(clamp(I, 0.0, 8.0) * 1e5));
        uint qD = uint(round(clamp(D * D, 0.0, 1.0) * 1e5));
        atomic_fetch_add_explicit(&cnt[bin], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&sumI[bin], qI, memory_order_relaxed);
        atomic_fetch_add_explicit(&sumD2[bin], qD, memory_order_relaxed);
        if (clamped) { atomic_fetch_add_explicit(&clampedCount, 1u, memory_order_relaxed); }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid != 0) { return; }
    float Sw = 0.0, Sx = 0.0, Sy = 0.0, Sxx = 0.0, Sxy = 0.0;
    for (int b = 0; b < 8; ++b) {
        uint c = atomic_load_explicit(&cnt[b], memory_order_relaxed);
        if (c < 24u) { continue; }
        float x = float(atomic_load_explicit(&sumI[b], memory_order_relaxed))
                / (float(c) * 1e5);
        float y = float(atomic_load_explicit(&sumD2[b], memory_order_relaxed))
                / (float(c) * 1e5) * (9.0 / 8.0);
        float wgt = float(c);
        Sw += wgt; Sx += wgt * x; Sy += wgt * y;
        Sxx += wgt * x * x; Sxy += wgt * x * y;
    }
    float den = Sw * Sxx - Sx * Sx;
    float a = den > 1e-14 ? (Sw * Sxy - Sx * Sy) / den : 0.0;
    float b = Sw > 0.0 ? (Sy - a * Sx) / Sw : 0.0;
    if (a < 0.0) { a = 0.0; b = Sw > 0.0 ? Sy / Sw : 0.0; }
    if (b < 1e-12) { b = 1e-12; }

    // RMS residual of the affine fit, in σ² units, weighted by the bin populations.
    float sse = 0.0, wsum = 0.0;
    for (int bb = 0; bb < 8; ++bb) {
        uint c = atomic_load_explicit(&cnt[bb], memory_order_relaxed);
        if (c < 24u) { continue; }
        float x = float(atomic_load_explicit(&sumI[bb], memory_order_relaxed))
                / (float(c) * 1e5);
        float y = float(atomic_load_explicit(&sumD2[bb], memory_order_relaxed))
                / (float(c) * 1e5) * (9.0 / 8.0);
        float e = y - (a * x + b);
        sse += float(c) * e * e;
        wsum += float(c);
    }
    float residual = wsum > 0.0 ? sqrt(sse / wsum) : 0.0;
    float clampedRatio = float(atomic_load_explicit(&clampedCount, memory_order_relaxed)) / 4096.0;
    model.write(float4(a, b, residual, clampedRatio), uint2(0, 0));
}

// MARK: - splat

static inline float s1_65_acc_load(threadgroup atomic_uint *p) {
    return float(atomic_load_explicit(p, memory_order_relaxed));
}

/// Full resolution → grid. Each (gx, gy) cell collects its `cell × cell` pixels by z bin, then
/// applies the five-tap range kernel on z **inside the same threadgroup** and writes the **mean**
/// log2 luma plus the cell's weight. Because z is already log2, the tap is on relative error: ±2
/// bins = ±1 EV around the cell's own brightness, regardless of how dark the cell is.
kernel void s1_65_splat(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::read> model [[texture(1)]],
                        texture3d<float, access::write> grid [[texture(2)]],
                        constant S1_65Params &p [[buffer(0)]],
                        uint3 gid [[threadgroup_position_in_grid]],
                        uint3 tid3 [[thread_position_in_threadgroup]],
                        uint3 tgSize3 [[threads_per_threadgroup]]) {
    int w = p.canvas.x, h = p.canvas.y, cell = max(p.canvas.z, 1);
    uint tid = tid3.x + tid3.y * tgSize3.x + tid3.z * tgSize3.x * tgSize3.y;
    uint tgSize = tgSize3.x * tgSize3.y * tgSize3.z;
    const float eps = p.n.y;

    // S1_65_Z sum-of-log entries followed by S1_65_Z counts.
    threadgroup atomic_uint acc[2 * S1_65_Z];
    for (uint i = tid; i < uint(2 * S1_65_Z); i += tgSize) {
        atomic_store_explicit(&acc[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int px0 = int(gid.x) * cell;
    int py0 = int(gid.y) * cell;
    for (uint k = tid; k < uint(cell * cell); k += tgSize) {
        int px = px0 + int(k) % cell;
        int py = py0 + int(k) / cell;
        if (px >= w || py >= h) { continue; }
        float3 rgb = max(src.read(uint2(px, py)).rgb, 0.0);
        float I = dot(rgb, kWorkingLumaWeights);
        float logL = clamp(log2(max(I, eps)), S1_65_LOG_LO, S1_65_LOG_HI);
        int z = clamp(int(round((logL - S1_65_LOG_LO) / S1_65_LOG_SPAN
                                * float(S1_65_Z - 1))), 0, S1_65_Z - 1);
        uint q = uint(round((logL - S1_65_LOG_LO) * S1_65_Q));
        atomic_fetch_add_explicit(&acc[z], q, memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[S1_65_Z + z], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const float wt[5] = { 1.0, 4.0, 6.0, 4.0, 1.0 };
    if (tid < S1_65_Z) {
        int z = int(tid);
        float sumL = 0.0, sumW = 0.0;
        for (int k = -2; k <= 2; ++k) {
            int zc = clamp(z + k, 0, S1_65_Z - 1);
            sumL += wt[k + 2] * s1_65_acc_load(&acc[zc]);
            sumW += wt[k + 2] * s1_65_acc_load(&acc[S1_65_Z + zc]);
        }
        float mean = sumW > 1e-6 ? (sumL / S1_65_Q / sumW) + S1_65_LOG_LO
                                 : (S1_65_LOG_LO + float(z) * S1_65_LOG_SPAN / float(S1_65_Z - 1));
        grid.write(float4(mean, 0.0, 0.0, sumW / 16.0),
                   uint3(gid.x, gid.y, uint(z)));
    }
}

// MARK: - blur

/// The x and y five-taps in one dispatch, out of threadgroup memory — the same tiled shape S3.9's
/// shipped `s3_9_nr_blur_xy` uses (16 × 16 outputs, a two-texel halo). The z axis was already
/// smoothed at splat time. Values are weighted means, so the pass carries `(Σ mean·w, Σ w)` and
/// divides once at the end; a cell with no pixels cannot drag a neighbour's mean down.
kernel void s1_65_blur_xy(texture3d<float, access::read> src [[texture(0)]],
                          texture3d<float, access::write> dst [[texture(1)]],
                          constant S1_65Params &p [[buffer(0)]],
                          uint3 tg [[threadgroup_position_in_grid]],
                          uint3 lid [[thread_position_in_threadgroup]]) {
    int gW = p.grid.x, gH = p.grid.y;
    int z = int(tg.z);
    int x0 = int(tg.x) * S1_65_TILE - 2;
    int y0 = int(tg.y) * S1_65_TILE - 2;

    threadgroup float2 tile[S1_65_LOAD * S1_65_LOAD];
    threadgroup float2 rows[S1_65_LOAD * S1_65_TILE];

    const float wt[5] = { 1.0, 4.0, 6.0, 4.0, 1.0 };
    const uint lane = lid.y * S1_65_TILE + lid.x;
    const uint threads = S1_65_TILE * S1_65_TILE;

    for (uint i = lane; i < uint(S1_65_LOAD * S1_65_LOAD); i += threads) {
        int tx = int(i) % S1_65_LOAD, ty = int(i) / S1_65_LOAD;
        int sx = clamp(x0 + tx, 0, gW - 1);
        int sy = clamp(y0 + ty, 0, gH - 1);
        float4 v = src.read(uint3(uint(sx), uint(sy), uint(z)));
        tile[i] = float2(v.x * v.w, v.w);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint i = lane; i < uint(S1_65_LOAD * S1_65_TILE); i += threads) {
        int tx = int(i) % S1_65_TILE, ty = int(i) / S1_65_TILE;
        float2 s = float2(0.0);
        for (int k = 0; k < 5; ++k) {
            s += wt[k] * tile[ty * S1_65_LOAD + clamp(tx + k, 0, S1_65_LOAD - 1)];
        }
        rows[i] = s / 16.0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int ox = int(tg.x) * S1_65_TILE + int(lid.x);
    int oy = int(tg.y) * S1_65_TILE + int(lid.y);
    if (ox >= gW || oy >= gH) { return; }

    float2 s = float2(0.0);
    for (int k = 0; k < 5; ++k) {
        s += wt[k] * rows[clamp(int(lid.y) + k, 0, S1_65_LOAD - 1) * S1_65_TILE
                         + int(lid.x)];
    }
    float mean = s.y > 1e-6 ? s.x / s.y : 0.0;
    dst.write(float4(mean, 0.0, 0.0, s.y / 16.0), uint3(uint(ox), uint(oy), uint(z)));
}

// MARK: - slice

/// Manual trilinear read — `texture3d` linear filtering is not available on every device, where the
/// sampler silently degrades to nearest (the same note S3.9's slice carries).
static inline float4 s1_65_grid_read(texture3d<float, access::read> g, float3 c, uint3 dim) {
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

/// Grid → full resolution. The grid's mean is a **log2 luma**, so the correction is one exponential
/// gain applied to all three channels: chroma ratios are exactly preserved and only luminance moves
/// (the ticket keeps chroma in S3.9). The gain is bounded by the fitted `σ(I)/I` — a flat shadow
/// pixel may move by its own noise amplitude, not by a cell in a brighter part of the picture.
kernel void s1_65_apply(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::read> model [[texture(1)]],
                        texture3d<float, access::read> grid [[texture(2)]],
                        texture2d<float, access::write> dst [[texture(3)]],
                        constant S1_65Params &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int w = p.canvas.x, h = p.canvas.y;
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }

    float4 px = src.read(gid);
    float3 rgb = max(px.rgb, 0.0);
    float I = dot(rgb, kWorkingLumaWeights);
    float logI = clamp(log2(max(I, p.n.y)), S1_65_LOG_LO, S1_65_LOG_HI);

    uint3 dim = uint3(grid.get_width(), grid.get_height(), grid.get_depth());
    float3 gc = float3((float(gid.x) + 0.5) / float(max(p.canvas.z, 1)) - 0.5,
                       (float(gid.y) + 0.5) / float(max(p.canvas.z, 1)) - 0.5,
                       clamp((logI - p.n.z) / (p.n.w - p.n.z) * float(S1_65_Z - 1),
                             0.0, float(S1_65_Z - 1)));
    float4 slice = s1_65_grid_read(grid, gc, dim);

    float amount = clamp(p.n.x, 0.0, 1.0);
    float logBar = slice.x;
    float4 fit = model.read(uint2(0, 0));
    float sigma2 = max(fit.x * I + fit.y, 0.0);
    float relative = clamp(sqrt(sigma2) / max(I, p.n.y), 0.02, 1.0);
    // 3σ of the fitted model is the most a pixel may move; the log-domain clamp keeps the gain
    // finite for a near-black pixel whose relative noise is large.
    float maxLog = log2(1.0 + clamp(3.0 * relative, 0.02, 1.5));
    // **Detail coring**: a difference between the pixel and the grid's mean that is far larger than
    // the fitted noise is structure, not noise. Keeping 70 % of it above 2σ…5σ is what stops a fine
    // dark texture from being averaged into its 8 px cell while a flat patch (|Δ| ≈ σ) still gets the
    // full amount. The bounds are in the same log2 units as everything else, so "2σ" is a relative
    // error, not a code value.
    float noiseLog = log2(1.0 + relative);
    float distance = fabs(logBar - logI);
    float keep = smoothstep(2.0 * noiseLog, 5.0 * noiseLog, distance);
    float effective = amount * (1.0 - 0.7 * keep);
    // Shadows get a gentler amount: display code 25 is ≈ 0.009 linear (log2 ≈ −6.8 EV), and the
    // ticket asks the dark-detail energy to keep ≥ 85 % of A. Scaling the amount down 30 % below
    // ~0.008 and letting it return by ~0.03 is what buys that 3–5 % of dark texture without moving
    // the flat-patch number, whose blocks sit above this window on all three files (printed by
    // `LinearDenoiseABTests`).
    float dark = 1.0 - smoothstep(-7.0, -5.0, logI);
    effective *= (1.0 - 0.30 * dark);
    float delta = clamp(effective * (logBar - logI), -maxLog, maxLog);
    if (slice.w < 1e-4) { delta = 0.0; }

    float gain = exp2(delta);
    float3 outRGB = rgb * gain;
    if (isnan(outRGB.x) || isnan(outRGB.y) || isnan(outRGB.z)
        || isinf(outRGB.x) || isinf(outRGB.y) || isinf(outRGB.z)) {
        outRGB = rgb;
    }
    dst.write(float4(max(outRGB, 0.0), px.a), gid);
}
