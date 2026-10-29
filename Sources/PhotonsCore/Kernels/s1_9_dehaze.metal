#include <metal_stdlib>
using namespace metal;

// S1.9 — **去雾**, the dark-channel prior (He/Sun/Tang 2010) in the **scene-linear** domain (117).
//
// It used to ride in S3.9 on display-referred codes with the airlight fixed at `A = 1`:
//
//     J = (I − 1) / t + 1
//
// That formula is only a haze model when the input is an encoding whose white point *is* the airlight.
// On scene light it is not: for `I > 1` it **adds** light (`(I − 1)/t > I − 1`), so every HDR highlight
// grew brighter as dehaze went up — the defect the user reported. The same expression with a measured
// `A` is the model the paper actually writes down:
//
//     I    = t·J + A·(1 − t)              (a veil of colour A, transmission t)
//     A    = max over the dark channel    (He's "brightest 0.1 %", approximated by the block-level max)
//     D(p) = min_c min_{Ω(p)} I_c         (dark channel, Ω = a q × q block here)
//     t    = max(1 − ω·D, t0)             (ω = 0.95, t0 = 0.1 — He's own numbers)
//     J    = (I − A·(1 − t)) / t
//
// **The physics.** `I > A` gives `J > I`, and that is correct: a sample under a veil is recovered by
// dividing by `t`, so the upper bound is `J ≤ I / t0` (10× at `t0 = 0.1`), and the amount it gains is
// exactly `A·(1 − t)/t`. A sample darker than the airlight (`I < A`) gives `J < I` (it is haze, not
// object). Neither direction is an unbounded brightening: the old `A = 1` in the display domain was
// the special case where the airlight happened to be the encoding's white.
//
// **Three passes, as the stage is specified:**
//
//   1. `s1_9_dehaze_dark`     — one texel per q × q block, the block's `min_c min I_c`. q = 4.
//   2. `s1_9_dehaze_airlight` — **one thread** scans the block texture for the largest block minimum
//                               (a cheap, deterministic stand-in for He's top 0.1 %), clamps it to
//                               `[1e-4, 8]` and writes a 1 × 1 texture. No CPU readback: `apply`
//                               samples it on the GPU.
//   3. `s1_9_dehaze_apply`    — samples the block texture bilinearly, builds `t`, and applies the
//                               recovery. `max(out, 0)`, **no upper clamp** (HDR is the point).
//
// `A < 0.02` is treated as "no haze": the picture has no veil to remove, so the pass is a copy — adding
// or removing nothing is the only honest answer for a frame whose airlight is essentially black.
//
// The negative amount reverses the same model (`hazy = 0.6·I + 0.4·A`), so the slider is symmetric
// about 0 and 0 is the identity. The stage exists only when `effects.dehaze != 0`
// (`RenderStage.pipeline(hasDehaze:)`), so a neutral document never reaches this file.

struct DehazeParams {
    // amount (−1…1), ω, t0, "no haze" threshold for A
    float4 a;
    // content rect: origin x, origin y, width, height (canvas pixels) — the letterbox guard
    float4 b;
    // canvasW, canvasH, q (block size), qW
    int4 c;
    // qH, pad, pad, pad
    int4 d;
};

/// Per `q × q` block: `min` over the block of `min` over channels, in **linear Rec2020**. `min` is
/// associative, so one block-level minimum is exactly the dark channel at the resolution `t` lives at
/// (the paper itself recommends estimating the transmission at low resolution).
kernel void s1_9_dehaze_dark(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dark [[texture(1)]],
                             constant DehazeParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    int qW = p.c.w, qH = p.d.x, q = max(p.c.z, 1);
    if (int(gid.x) >= qW || int(gid.y) >= qH) { return; }
    int w = p.c.x, h = p.c.y;

    float m = 1e9;
    for (int dy = 0; dy < q; ++dy) {
        int y = min(int(gid.y) * q + dy, h - 1);
        for (int dx = 0; dx < q; ++dx) {
            int x = min(int(gid.x) * q + dx, w - 1);
            float3 c = src.read(uint2(x, y)).rgb;
            m = min(m, min(min(c.r, c.g), c.b));
        }
    }
    dark.write(float4(m, 0.0, 0.0, 1.0), gid);
}

/// The airlight: the largest block minimum, clamped to `[1e-4, 8]`. **One threadgroup**, one
/// dispatch, no atomics: each lane scans a strided slice of the block texture and a tree reduction in
/// threadgroup memory leaves the maximum. (A literally single-thread scan is latency-bound — measured
/// at 32 ms of a 4.1 Mpx frame, and ~16× that at 60 Mpx — because every one of the 234 k…3.75 M reads
/// waits on its predecessor. The reduction has the same result, bit for bit, and costs a fraction of
/// one pass.) The result is a 1 × 1 texture the apply pass samples; nothing is read back to the CPU.
constant uint DEHAZE_AIRLIGHT_LANES = 256;

kernel void s1_9_dehaze_airlight(texture2d<float, access::read> dark [[texture(0)]],
                                 texture2d<float, access::write> airlight [[texture(1)]],
                                 constant DehazeParams &p [[buffer(0)]],
                                 uint tid [[thread_position_in_threadgroup]]) {
    threadgroup float shared[DEHAZE_AIRLIGHT_LANES];
    int qW = p.c.w, qH = p.d.x;
    int n = qW * qH;
    float A = 0.0;
    for (int i = int(tid); i < n; i += int(DEHAZE_AIRLIGHT_LANES)) {
        A = max(A, dark.read(uint2(uint(i % qW), uint(i / qW))).r);
    }
    shared[tid] = A;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = DEHAZE_AIRLIGHT_LANES / 2; s > 0; s >>= 1) {
        if (tid < s) { shared[tid] = max(shared[tid], shared[tid + s]); }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (tid == 0) {
        airlight.write(float4(clamp(shared[0], 1e-4, 8.0), 0.0, 0.0, 1.0), uint2(0, 0));
    }
}

/// The recovery: `t = max(1 − ω·D, t0)`, `J = (I − A(1 − t))/t`, `out = mix(I, J, amount)`.
/// Negative amount adds the veil back (`hazy = 0.6·I + 0.4·A`). No upper clamp: `J ≤ I/t0` is the
/// physical bound, and S4's headroom is what decides how much of that tail is written.
kernel void s1_9_dehaze_apply(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::sample> dark [[texture(1)]],
                              texture2d<float, access::read> airlight [[texture(2)]],
                              texture2d<float, access::write> dst [[texture(3)]],
                              constant DehazeParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    float3 I = c.rgb;

    // The letterbox is not part of the picture: copy it untouched.
    if (float(gid.x) < p.b.x || float(gid.y) < p.b.y
        || float(gid.x) >= p.b.x + p.b.z || float(gid.y) >= p.b.y + p.b.w) {
        dst.write(float4(max(I, 0.0), c.a), gid);
        return;
    }

    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    int q = max(p.c.z, 1);
    int qW = p.c.w, qH = p.d.x;
    float2 uv = float2((float(gid.x) + 0.5) / (float(q) * float(qW)),
                       (float(gid.y) + 0.5) / (float(q) * float(qH)));
    float D = max(dark.sample(linearSampler, uv).r, 0.0);
    float A = airlight.read(uint2(0, 0)).r;

    float amount = clamp(p.a.x, -1.0, 1.0);
    float omega = clamp(p.a.y, 0.0, 1.0);
    float t0 = clamp(p.a.z, 1e-3, 1.0);

    // No airlight, no haze: mix straight back to the original picture (the only honest answer for a
    // frame whose dark channel never rises above black).
    if (A < p.a.w) {
        dst.write(float4(max(I, 0.0), c.a), gid);
        return;
    }

    float3 outRGB;
    if (amount >= 0.0) {
        float t = max(1.0 - omega * D, t0);
        float3 clear = (I - A * (1.0 - t)) / t;
        outRGB = mix(I, clear, amount);
    } else {
        float3 hazy = I * 0.6 + 0.4 * A;
        outRGB = mix(I, hazy, -amount);
    }
    dst.write(float4(max(outRGB, 0.0), c.a), gid);
}
