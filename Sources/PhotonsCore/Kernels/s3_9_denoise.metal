#include <metal_stdlib>
#include "oklch_bands.metal"
using namespace metal;

// S3.9 — 联合双边网格去噪 (171)
//
// The bilateral grid of Paris/Durand, after Halide's MIT `apps/bilateral_grid`: **splat** the
// full-resolution picture into a coarse 3-D grid (x, y, luma), blur it separably with a five-tap
// `[1,4,6,4,1]/16`, then **slice** the grid back at full resolution. The grid's third axis is the
// edge-stopping dimension: a pixel only averages with neighbours whose luma lands in the same bin,
// so a step edge does not bleed while flat noise does.
//
//   · `s3_9_nr_sigma` — one threadgroup estimates the frame's noise σ from the median absolute
//     deviation of the high-pass (`|L − mean3x3 L|`). The median is robust to the edges and texture
//     that make up most of a photograph, which is why it, and not the mean, sets the grid's z scale.
//   · `s3_9_nr_splat` — one threadgroup per grid cell. Every pixel adds its luma, its OKLab a/b
//     (offset by +0.5 so the accumulator can be unsigned) and a weight of 1 into the cell, using
//     **integer atomics** at a fixed 65535 scale: float atomics are order-dependent, the integer
//     sums are not, so the same frame always produces the same grid. The z five-tap is applied here,
//     in the same threadgroup, before the cell is written.
//   · `s3_9_nr_blur` — the x and y five-tap, one invocation per axis.
//
// The apply pass (`s3_8_detail_fx.metal`) reads the grid with a **manual** eight-corner trilinear
// interpolation: `texture3d` linear filtering is silently unavailable on some devices, where the
// sampler degrades to nearest without an error.

#define S3_9_Z 40                 // z 轴 bin 数
#define S3_9_Q 65535.0            // 定点标度

struct DenoiseParams {
    int4 canvas;   // x = w, y = h, z = cell(格边长, 8), w = zBins(40)
    int4 grid;     // x = gW, y = gH, z = axis(0=x 1=y), w = 0
    float4 n;      // x = amtL, y = amtC, z = unused, w = unused
};

// MARK: - noise estimate

/// Median absolute deviation of the 3×3 high-pass, sampled on a 64 × 64 lattice (4096 samples). The
/// histogram has 256 bins over `|D| ∈ [0, 0.25]`; the median is read by walking the cumulative count
/// to the half-sample point. `1.572 = 1.4826 / 0.943` turns the MAD into a Gaussian σ estimate: for
/// a normal distribution `MAD = 0.6745σ`, and the high-pass `L − mean3x3` removes 8/9 of the variance
/// (`σ_D = sqrt(8/9)·σ ≈ 0.943σ`).
kernel void s3_9_nr_sigma(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> out [[texture(1)]],
                          constant DenoiseParams &p [[buffer(0)]],
                          uint tid [[thread_position_in_threadgroup]]) {
    threadgroup atomic_uint hist[256];
    for (uint i = tid; i < 256; i += 256) {
        atomic_store_explicit(&hist[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int w = p.canvas.x, h = p.canvas.y;
    const float3 lw = float3(0.2126, 0.7152, 0.0722);
    const float binWidth = 0.25 / 256.0;

    for (uint s = tid; s < 4096; s += 256) {
        int i = int(s) & 63;
        int j = int(s) >> 6;
        int x = clamp(int(round((float(i) + 0.5) * float(w) / 64.0)), 0, w - 1);
        int y = clamp(int(round((float(j) + 0.5) * float(h) / 64.0)), 0, h - 1);

        float L = dot(src.read(uint2(x, y)).rgb, lw);
        float sum = 0.0;
        for (int dy = -1; dy <= 1; ++dy) {
            for (int dx = -1; dx <= 1; ++dx) {
                int sx = clamp(x + dx, 0, w - 1);
                int sy = clamp(y + dy, 0, h - 1);
                sum += dot(src.read(uint2(sx, sy)).rgb, lw);
            }
        }
        float D = fabs(L - sum / 9.0);
        uint bin = clamp(uint(D / binWidth), 0u, 255u);
        atomic_fetch_add_explicit(&hist[bin], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid == 0) {
        uint cum = 0;
        float median = 0.0;
        for (uint b = 0; b < 256; ++b) {
            uint count = atomic_load_explicit(&hist[b], memory_order_relaxed);
            if (cum + count >= 2048u) {
                median = (float(b) + float(2048u - cum) / float(max(count, 1u))) * binWidth;
                break;
            }
            cum += count;
        }
        out.write(float4(1.572 * median, 0.0, 0.0, 0.0), uint2(0, 0));
    }
}

// MARK: - splat

/// Read-side of the threadgroup accumulator. The writes use atomics for determinism; after the
/// barrier the values are final, so each read is one relaxed atomic load.
static inline float s3_9_acc_load(threadgroup atomic_uint *p) {
    return float(atomic_load_explicit(p, memory_order_relaxed));
}

/// Full resolution → grid. One threadgroup per (gx, gy) cell; the cell's `cell × cell` pixels are
/// scattered over the threadgroup, each picking its z bin from `round(L / r)`.
///
/// `r` is the same expression the slice pass uses, and it is the only coupling between the two: the
/// grid's z resolution is per-frame (a noisy frame gets a wider bin), but splat and slice must agree
/// bit for bit or the slice walks a different scale than the splat built.
kernel void s3_9_nr_splat(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::read> sig [[texture(1)]],
                          texture3d<float, access::write> grid [[texture(2)]],
                          constant DenoiseParams &p [[buffer(0)]],
                          uint3 gid [[threadgroup_position_in_grid]],
                          uint3 tid3 [[thread_position_in_threadgroup]],
                          uint3 tgSize3 [[threads_per_threadgroup]]) {
    int w = p.canvas.x, h = p.canvas.y, cell = max(p.canvas.z, 1);
    const float3 lw = float3(0.2126, 0.7152, 0.0722);
    uint tid = tid3.x + tid3.y * tgSize3.x + tid3.z * tgSize3.x * tgSize3.y;
    uint tgSize = tgSize3.x * tgSize3.y * tgSize3.z;

    float r = clamp((0.4 + 0.6 * p.n.x) * sig.read(uint2(0, 0)).x, 0.010, 0.050);

    // L / A / B / weight, 40 bins each.
    threadgroup atomic_uint acc[160];
    for (uint i = tid; i < 160; i += tgSize) {
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
        float L = dot(rgb, lw);
        float3 lab = oklab_raw(rgb);
        int z = clamp(int(round(L / r)), 0, S3_9_Z - 1);

        uint lv = uint(round(clamp(L, 0.0, 1.0) * S3_9_Q));
        uint av = uint(round(clamp(lab.y + 0.5, 0.0, 1.0) * S3_9_Q));
        uint bv = uint(round(clamp(lab.z + 0.5, 0.0, 1.0) * S3_9_Q));

        atomic_fetch_add_explicit(&acc[z], lv, memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[40 + z], av, memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[80 + z], bv, memory_order_relaxed);
        atomic_fetch_add_explicit(&acc[120 + z], 1u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // The z five-tap, in-cell: [1,4,6,4,1]/16 with the bin index clamped at both ends. The sums stay
    // **premultiplied** (Σ L, not the mean), so the slice can divide by Σ w on its own.
    //
    // 171 — the chroma channels get a **wider** z kernel than the luma ones: [1,2,3,4,3,2,1]/16, still
    // summing to 16. That is the ticket's `r_sigma_C = 1.5 · r_sigma` in the only form a *joint* grid
    // admits (one bin width per axis, so "chroma tolerates a 1.5× wider value window" becomes a 1.5×
    // wider kernel: ±3 bins instead of ±2). It costs six adds in the threadgroup, no memory, and it is
    // what lifts `DetailDenoiseTests`' D requirement (chroma σ ↓≥ 50 %) without loosening the luma's
    // edge stop — see REPORT.md for the before/after.
    const float zLuma[5] = { 1.0, 4.0, 6.0, 4.0, 1.0 };
    const float zChroma[7] = { 1.0, 2.0, 3.0, 4.0, 3.0, 2.0, 1.0 };

    if (tid < S3_9_Z) {
        int z = int(tid);
        float4 s = float4(0.0);
        float2 chroma = float2(0.0);
        float chromaW = 0.0;
        for (int k = -3; k <= 3; ++k) {
            int zc = clamp(z + k, 0, S3_9_Z - 1);
            float wc = zChroma[k + 3];
            chroma += wc * float2(s3_9_acc_load(&acc[40 + zc]), s3_9_acc_load(&acc[80 + zc]));
            chromaW += wc * s3_9_acc_load(&acc[120 + zc]);
            if (k >= -2 && k <= 2) {
                int zl = clamp(z + k, 0, S3_9_Z - 1);
                s += zLuma[k + 2] * float4(s3_9_acc_load(&acc[zl]), 0.0, 0.0,
                                           s3_9_acc_load(&acc[120 + zl]));
            }
        }
        s /= 16.0;
        chroma /= 16.0;
        chromaW /= 16.0;

        float sumW = s.w;                       // Σ count, un-scaled: it is a count, not a value
        float sumL = s.x / S3_9_Q;
        // The chroma numerator and denominator must come from the **same** window, but the grid only
        // carries one weight channel, and the x/y blur divides by that one. So the wide-window mean is
        // formed here and re-premultiplied by `sumW`: the spatial pass then averages
        // `aMean_wide · w` against `w`, which is exactly the weighted mean of the cells' wide means.
        float aMean = 0.0, bMean = 0.0;
        if (chromaW > 1e-6) {
            aMean = (chroma.x / S3_9_Q - 0.5 * chromaW) / chromaW;
            bMean = (chroma.y / S3_9_Q - 0.5 * chromaW) / chromaW;
        }
        grid.write(float4(sumL, aMean * sumW, bMean * sumW, sumW),
                   uint3(gid.x, gid.y, uint(z)));
    }
}

// MARK: - blur

/// One invocation per grid texel: the five-tap along `p.grid.z` (0 = x, 1 = y), edge-clamped. The z
/// axis was already smoothed at splat time, so it is not touched here.
///
/// 171 — this is the **fallback / probe** form (one axis per dispatch). The shipped path uses
/// `s3_9_nr_blur_xy` below, which does both axes in one pass; the two are the same arithmetic, which
/// is what `DenoiseKernelProbeTests` checks.
kernel void s3_9_nr_blur(texture3d<float, access::read> src [[texture(0)]],
                         texture3d<float, access::write> dst [[texture(1)]],
                         constant DenoiseParams &p [[buffer(0)]],
                         uint3 gid [[thread_position_in_grid]]) {
    int gW = p.grid.x, gH = p.grid.y;
    if (int(gid.x) >= gW || int(gid.y) >= gH || int(gid.z) >= S3_9_Z) { return; }

    const int off[5] = { -2, -1, 0, 1, 2 };
    const float wt[5] = { 1.0, 4.0, 6.0, 4.0, 1.0 };
    int axis = p.grid.z;

    float4 sum = float4(0.0);
    for (int k = 0; k < 5; ++k) {
        int3 c = int3(gid);
        if (axis == 0) { c.x = clamp(c.x + off[k], 0, gW - 1); }
        else           { c.y = clamp(c.y + off[k], 0, gH - 1); }
        sum += wt[k] * src.read(uint3(c));
    }
    dst.write(sum / 16.0, gid);
}

/// 171 — the **shipped** grid blur: x and y five-taps in a single dispatch, out of threadgroup
/// memory. Two separate passes read and wrote the whole 3-D grid twice (two 20 MB round trips at
/// 4.10 Mpx); this one loads a 16 × 16 tile plus a two-texel halo once and writes once, which is
/// where the denoise's marginal cost came from at the acceptance's +2 ms budget.
///
/// The arithmetic is identical to `s3_9_nr_blur` run along x then y: `[1,4,6,4,1]/16`, edge-clamped.
/// The z axis is not touched (the splat already did it).
#define S3_9_TILE 16
#define S3_9_LOAD (S3_9_TILE + 4)         // one tile plus a two-texel halo each way

kernel void s3_9_nr_blur_xy(texture3d<float, access::read> src [[texture(0)]],
                            texture3d<float, access::write> dst [[texture(1)]],
                            constant DenoiseParams &p [[buffer(0)]],
                            uint3 tg [[threadgroup_position_in_grid]],
                            uint3 lid [[thread_position_in_threadgroup]]) {
    int gW = p.grid.x, gH = p.grid.y;
    int z = int(tg.z);
    int x0 = int(tg.x) * S3_9_TILE - 2;    // the tile's top-left **input** texel
    int y0 = int(tg.y) * S3_9_TILE - 2;

    threadgroup float4 tile[S3_9_LOAD * S3_9_LOAD];       // 20 × 20 inputs
    threadgroup float4 rows[S3_9_LOAD * S3_9_TILE];       // 16 × 20 after the x pass

    const float wt[5] = { 1.0, 4.0, 6.0, 4.0, 1.0 };
    const uint lane = lid.y * S3_9_TILE + lid.x;
    const uint threads = S3_9_TILE * S3_9_TILE;

    for (uint i = lane; i < uint(S3_9_LOAD * S3_9_LOAD); i += threads) {
        int tx = int(i) % S3_9_LOAD, ty = int(i) / S3_9_LOAD;
        int sx = clamp(x0 + tx, 0, gW - 1);
        int sy = clamp(y0 + ty, 0, gH - 1);
        tile[i] = src.read(uint3(uint(sx), uint(sy), uint(z)));
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // x five-tap: `rows[ty][tx]`, ty spans the halo (so the y pass has its inputs).
    for (uint i = lane; i < uint(S3_9_LOAD * S3_9_TILE); i += threads) {
        int tx = int(i) % S3_9_TILE, ty = int(i) / S3_9_TILE;
        float4 s = float4(0.0);
        for (int k = 0; k < 5; ++k) {
            s += wt[k] * tile[ty * S3_9_LOAD + clamp(tx + 2 + k - 2, 0, S3_9_LOAD - 1)];
        }
        rows[i] = s / 16.0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    int ox = int(tg.x) * S3_9_TILE + int(lid.x);
    int oy = int(tg.y) * S3_9_TILE + int(lid.y);
    if (ox >= gW || oy >= gH) { return; }

    float4 s = float4(0.0);
    for (int k = 0; k < 5; ++k) {
        s += wt[k] * rows[clamp(int(lid.y) + k, 0, S3_9_LOAD - 1) * S3_9_TILE + int(lid.x)];
    }
    dst.write(s / 16.0, uint3(uint(ox), uint(oy), uint(z)));
}
