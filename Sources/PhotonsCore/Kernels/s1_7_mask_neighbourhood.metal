#include <metal_stdlib>
using namespace metal;

// S1.7 — the two **neighbourhood** operators of the atlas (docs/tasks/005-masks.md §3.4, §4.6).
//
// 005b/005c evaluated `opacity · combine(components) · invert` with a pointwise kernel. This file adds
// the two operators that reach past the pixel, in the order the atlas applies them:
//
//   1. mask-level `feather`  — a separable box blur of the combined selection, radius in canvas
//                              pixels (§2, `feather` 0…1 ⇒ 0…10 % of the short edge).
//   2. mask-level `refine`   — a guided filter (He/Sun/Tang 2010) steered by S1's linear luma:
//                              `a = cov/(var + ε)`, `b = mean_p − a·mean_I`, `out = a·I + b`,
//                              computed at 1/q resolution and upsampled at reconstruction, which is
//                              the fast variant of arXiv:1505.00996 and exactly what §4.6 specifies
//                              for the coefficient resolution.
//
// Both are affine-invariant under `opacity`/`invert` (`blur(1−a) = 1−blur(a)`, `blur(k·a) = k·blur(a)`),
// so the atlas may keep writing the *final* coverage in S1.5 and these passes can run afterwards
// without re-deriving the mask.
//
// ## Why not `MPSImageGuidedFilter`
//
// §4.6 names the system kernel, and it was measured on this machine (macOS 27.2, M1 Pro, 1500×2731):
//
//   · `MPSImageGuidedFilter(device:kernelDiameter:)` with the required diameter 65 costs **145.7 ms**
//     for the regression alone (36.2 ms at kd = 33, 3.2 ms at kd = 9; median of 12, GPU time) —
//     nine times the whole S0→S4 frame budget for a single mask, because the coefficients are solved
//     at full resolution.
//   · The documented escape hatch — encode the regression on a 1/4-resolution coefficient texture
//     and let `encodeReconstruction` upsample it — returns **≈ 0 everywhere** on this OS/GPU
//     (measured: centre 8.8e-5 against 0.82 at full resolution, `cb.error == nil`), for both
//     `.r16Float`/`.rgba16Float` and `.r32Float`/`.rgba32Float`.
//
// So the maths below is the same filter with the resolution split done by hand: 1/q regression,
// bilinear coefficient upsample, full-resolution reconstruction. Differences from MPS, documented
// rather than discovered: (a) the guide is a single luma channel, so `a`/`b` are scalars, whereas
// MPS solves a 3x3 system over RGB (a mask edge follows *brightness*, which is what LR's Smoothness
// follows); (b) the box means are running sums in float32 rather than MPS's internal form, so the
// last bits differ; (c) the result is mixed with the pre-refine coverage by `refine`, so the slider
// is a strength and not only an ε.
//
// ## Cost
//
// The blur is a **running sum**, not an O(r) convolution: one thread walks a segment of a row (or a
// column) and each output pixel costs two reads and one write whatever the radius is. A 273 px
// feather therefore costs the same as a 4 px one, which is what keeps `feather = 1` off the frame
// budget (O(r) would be 4.1 Mpx × 547 taps ≈ 9 ms per mask at radius 273).

struct MaskBlurParams {
    int4 a;   // canvasW, canvasH, segment length, sliceCount
};

// Mirror of the mask table in s1_5_mask_atlas.metal / RenderGraph.swift (`MaskDescU`).
struct MaskDesc {
    int4   meta;   // firstComponent, componentCount, invert, pad
    float4 misc;   // opacity, featherRadiusPx, refine strength, guidedRadiusPx
};

/// Horizontal box blur of one slice, edge-clamped (replicate), radius from the mask descriptor.
///
/// `gid` = (segment index, row, slice). Each thread sums `2r + 1` pixels once, then slides the window
/// across its segment. The clamp is what §3.4 asks for: a mask that covers the whole frame must stay
/// 1.0 at the border, and a feather must never read outside the canvas (zero padding would darken a
/// one-pixel frame and pull coverage toward 0 along every edge).
kernel void s1_7_mask_blur_h(texture2d_array<float, access::read> src [[texture(0)]],
                             texture2d_array<float, access::write> dst [[texture(1)]],
                             constant MaskBlurParams &p [[buffer(0)]],
                             constant MaskDesc *masks [[buffer(1)]],
                             uint3 gid [[thread_position_in_grid]]) {
    int w = p.a.x, h = p.a.y;
    int slice = int(gid.z);
    int row = int(gid.y);
    if (slice >= p.a.w || row >= h) { return; }
    int x0 = int(gid.x) * p.a.z;
    if (x0 >= w) { return; }
    int x1 = min(x0 + p.a.z, w);
    int r = int(clamp(masks[slice].misc.y, 0.0, 4096.0));

    if (r <= 0) {
        for (int x = x0; x < x1; ++x) {
            float v = src.read(uint2(x, row), slice).r;
            dst.write(float4(v, v, v, 1.0), uint2(x, row), slice);
        }
        return;
    }

    float inv = 1.0 / float(2 * r + 1);
    float acc = 0.0;
    for (int i = x0 - r; i <= x0 + r; ++i) {
        acc += src.read(uint2(clamp(i, 0, w - 1), row), slice).r;
    }
    for (int x = x0; x < x1; ++x) {
        float v = acc * inv;
        dst.write(float4(v, v, v, 1.0), uint2(x, row), slice);
        acc += src.read(uint2(clamp(x + r + 1, 0, w - 1), row), slice).r
             - src.read(uint2(clamp(x - r, 0, w - 1), row), slice).r;
    }
}

/// Vertical half of the same box blur. `gid` = (column, segment index, slice): adjacent threads walk
/// adjacent columns, so every step reads one contiguous row.
kernel void s1_7_mask_blur_v(texture2d_array<float, access::read> src [[texture(0)]],
                             texture2d_array<float, access::write> dst [[texture(1)]],
                             constant MaskBlurParams &p [[buffer(0)]],
                             constant MaskDesc *masks [[buffer(1)]],
                             uint3 gid [[thread_position_in_grid]]) {
    int w = p.a.x, h = p.a.y;
    int slice = int(gid.z);
    int col = int(gid.x);
    if (slice >= p.a.w || col >= w) { return; }
    int y0 = int(gid.y) * p.a.z;
    if (y0 >= h) { return; }
    int y1 = min(y0 + p.a.z, h);
    int r = int(clamp(masks[slice].misc.y, 0.0, 4096.0));

    if (r <= 0) {
        for (int y = y0; y < y1; ++y) {
            float v = src.read(uint2(col, y), slice).r;
            dst.write(float4(v, v, v, 1.0), uint2(col, y), slice);
        }
        return;
    }

    float inv = 1.0 / float(2 * r + 1);
    float acc = 0.0;
    for (int i = y0 - r; i <= y0 + r; ++i) {
        acc += src.read(uint2(col, clamp(i, 0, h - 1)), slice).r;
    }
    for (int y = y0; y < y1; ++y) {
        float v = acc * inv;
        dst.write(float4(v, v, v, 1.0), uint2(col, y), slice);
        acc += src.read(uint2(col, clamp(y + r + 1, 0, h - 1)), slice).r
             - src.read(uint2(col, clamp(y - r, 0, h - 1)), slice).r;
    }
}

// MARK: - guided refine (§4.6)

struct RefineParams {
    int4   a;   // canvasW, canvasH, q, guided radius in the 1/q domain
    float4 b;   // epsilon, lumaR, lumaG, lumaB
    float4 c;   // mix strength (0…1), pad, pad, pad
    int4   d;   // qW, qH, segment length, pad
};

/// Regression input: one texel per `q × q` block of (I, p, I², I·p), area-averaged.
/// `I` is the guidance (S1's linear luma), `p` the pre-refine coverage of this slice.
kernel void s1_7_refine_pack(texture2d<float, access::read> guide [[texture(0)]],
                             texture2d<float, access::read> mask [[texture(1)]],
                             texture2d<float, access::write> packed [[texture(2)]],
                             constant RefineParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int qW = p.d.x, qH = p.d.y, q = max(p.a.z, 1);
    if (int(gid.x) >= qW || int(gid.y) >= qH) { return; }
    int w = p.a.x, h = p.a.y;
    float3 lw = p.b.yzw;

    float sumI = 0.0, sumP = 0.0, sumII = 0.0, sumIP = 0.0;
    int n = 0;
    for (int dy = 0; dy < q; ++dy) {
        int y = min(int(gid.y) * q + dy, h - 1);
        for (int dx = 0; dx < q; ++dx) {
            int x = min(int(gid.x) * q + dx, w - 1);
            // Headroom above 1 is "digital white" here too, exactly as in the luminance range (§4.5),
            // so a highlight does not pull the regression's slope around as the decode tier changes.
            float I = clamp(dot(max(guide.read(uint2(x, y)).rgb, 0.0), lw), 0.0, 1.0);
            float m = mask.read(uint2(x, y)).r;
            sumI += I; sumP += m; sumII += I * I; sumIP += I * m;
            n += 1;
        }
    }
    float inv = 1.0 / float(max(n, 1));
    packed.write(float4(sumI * inv, sumP * inv, sumII * inv, sumIP * inv), gid);
}

/// Separable box mean of an `rgba` field — the window `w` of the guided filter. `gid` = (segment, row).
kernel void s1_7_box4_h(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant RefineParams &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int qW = p.d.x, qH = p.d.y;
    int row = int(gid.y);
    if (row >= qH) { return; }
    int x0 = int(gid.x) * p.d.z;
    if (x0 >= qW) { return; }
    int x1 = min(x0 + p.d.z, qW);
    int r = max(p.a.w, 0);
    if (r == 0) {
        for (int x = x0; x < x1; ++x) { dst.write(src.read(uint2(x, row)), uint2(x, row)); }
        return;
    }
    float inv = 1.0 / float(2 * r + 1);
    float4 acc = float4(0.0);
    for (int i = x0 - r; i <= x0 + r; ++i) {
        acc += src.read(uint2(clamp(i, 0, qW - 1), row));
    }
    for (int x = x0; x < x1; ++x) {
        dst.write(acc * inv, uint2(x, row));
        acc += src.read(uint2(clamp(x + r + 1, 0, qW - 1), row))
             - src.read(uint2(clamp(x - r, 0, qW - 1), row));
    }
}

/// Vertical half of the box mean. `gid` = (column, segment).
kernel void s1_7_box4_v(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant RefineParams &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int qW = p.d.x, qH = p.d.y;
    int col = int(gid.x);
    if (col >= qW) { return; }
    int y0 = int(gid.y) * p.d.z;
    if (y0 >= qH) { return; }
    int y1 = min(y0 + p.d.z, qH);
    int r = max(p.a.w, 0);
    if (r == 0) {
        for (int y = y0; y < y1; ++y) { dst.write(src.read(uint2(col, y)), uint2(col, y)); }
        return;
    }
    float inv = 1.0 / float(2 * r + 1);
    float4 acc = float4(0.0);
    for (int i = y0 - r; i <= y0 + r; ++i) {
        acc += src.read(uint2(col, clamp(i, 0, qH - 1)));
    }
    for (int y = y0; y < y1; ++y) {
        dst.write(acc * inv, uint2(col, y));
        acc += src.read(uint2(col, clamp(y + r + 1, 0, qH - 1)))
             - src.read(uint2(col, clamp(y - r, 0, qH - 1)));
    }
}

/// Linear coefficients from the window stats: `stats = (mean_I, mean_p, mean_II, mean_Ip)`.
/// `a = (mean_Ip − mean_I·mean_p) / (mean_II − mean_I² + ε)`, `b = mean_p − a·mean_I`.
kernel void s1_7_refine_coeff(texture2d<float, access::read> stats [[texture(0)]],
                              texture2d<float, access::write> coeff [[texture(1)]],
                              constant RefineParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.d.x || int(gid.y) >= p.d.y) { return; }
    float4 s = stats.read(gid);
    float mI = s.x, mp = s.y, mII = s.z, mIp = s.w;
    float var = max(mII - mI * mI, 0.0);
    float cov = mIp - mI * mp;
    float eps = max(p.b.x, 1e-9);
    float a = cov / (var + eps);
    float b = mp - a * mI;
    coeff.write(float4(a, b, 0.0, 1.0), gid);
}

/// Reconstruction at full resolution: `out = mix(p, a·I + b, refine)` with the coefficients sampled
/// bilinearly from the 1/q grid — the coefficient upsample §4.6 describes, performed here so it does
/// not depend on MPS's internal one.
kernel void s1_7_refine_apply(texture2d<float, access::read> guide [[texture(0)]],
                              texture2d<float, access::sample> coeff [[texture(1)]],
                              texture2d<float, access::read> mask [[texture(2)]],
                              texture2d<float, access::write> dst [[texture(3)]],
                              constant RefineParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    int w = p.a.x, h = p.a.y;
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    int q = max(p.a.z, 1);
    float2 uv = float2((float(gid.x) + 0.5) / (float(q) * float(p.d.x)),
                       (float(gid.y) + 0.5) / (float(q) * float(p.d.y)));
    float4 ab = coeff.sample(linearSampler, uv);

    float I = clamp(dot(max(guide.read(gid).rgb, 0.0), p.b.yzw), 0.0, 1.0);
    float guided = clamp(ab.x * I + ab.y, 0.0, 1.0);
    float before = clamp(mask.read(gid).r, 0.0, 1.0);
    // A strength mix rather than an epsilon-only knob: with `refine = 0` the pass does not exist at
    // all, and with `refine = 1` the guided result is used as-is.
    float v = mix(before, guided, clamp(p.c.x, 0.0, 1.0));
    v = clamp(v, 0.0, 1.0);
    dst.write(float4(v, v, v, 1.0), gid);
}
