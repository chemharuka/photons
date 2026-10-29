#include <metal_stdlib>
#include "primaries.metal"
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
// **130 — the recovery is on luminance, and only where there is fog to account for.** The
// per-channel `J_c = (I_c − A(1 − t))/t` subtracts the same constant from three different channels
// and then divides by the same `t`, so the *difference* between channels is multiplied by `1/t`.
// On a +2 EV blue sky that is a hue rotation: B − R grew 5.3× and saturation 5.1× at dehaze 20 while
// the picture also darkened. Two changes fix it:
//
//   1. **Hue-preserving recovery.** He's inversion is applied to the Rec.2020 luminance only, and the
//      three channels are scaled by one common `gain`: `out = I·gain`. One gain cannot change a
//      channel ratio, so hue and chroma are invariant and only brightness moves.
//   2. **Participation by fog amount.** A veil can only lift a pixel *towards* `A`; its whole
//      contribution is `A·(1 − t)`. For `L` far above `A` that contribution is negligible, so the
//      correction fades out with `w = 1 − smoothstep(A, k·A, L)`, `k = 2`: at `L ≥ 2A` the pixel is
//      left alone. This is an **amend of 117's "HDR participates"**, not a regression of it: 117
//      rejected the old `A = 1` in display codes that brightened every highlight without bound; `A`
//      is still measured, and the only thing 130 says is that a pixel brighter than twice the
//      airlight carries no evidence of fog. Do not "restore" the per-channel formula.
//
// The negative amount is untouched, so `dehaze < 0` is byte-identical to 117.
//
// **Four passes (117's three, plus 135's bound):**
//
//   1. `s1_9_dehaze_dark`     — one texel per q × q block, the block's `min_c min I_c`. q = 4.
//   2. `s1_9_dehaze_airlight` — **one threadgroup** scans the block texture for the largest block
//                               minimum (a cheap, deterministic stand-in for He's top 0.1 %), clamps
//                               it to `[1e-4, 8]` and writes a 1 × 1 texture. No CPU readback.
//   3. `s1_9_dehaze_limit`    — 135: the airlight's physical **upper** bound, `min(A_raw, κ·p99(L))`
//                               (`κ = 0.95`, `p99` clipped at white; the cap engages only when the
//                               estimate is materially above the bright end), in a second 1 × 1 texture.
//   4. `s1_9_dehaze_apply`    — samples the block texture bilinearly, builds `t`, and applies the
//                               recovery. `max(out, 0)`, **no upper clamp** (HDR is the point).
//
// `A < 0.02` is treated as "no haze": the picture has no veil to remove, so the pass is a copy — adding
// or removing nothing is the only honest answer for a frame whose airlight is essentially black.
//
// The negative amount reverses the same model (`hazy = 0.6·I + 0.4·A`), so the slider is symmetric
// about 0 and 0 is the identity. The stage exists only when `effects.dehaze != 0`
// (`RenderStage.pipeline(hasDehaze:)`), so a neutral document never reaches this file.
//
// **141 — the estimate is taken on the unexposed light.** S1 puts the global exposure gain `g = 2^EV`
// *upstream* of this stage, so a naive reading measures `A`, `t` and `p99` on `g·I₀` and the same
// dehaze amount acts differently at every exposure — measured on `L1030437`: the bright-decile gain
// flipped from 0.884× (crushing) at EV 0 to 1.066× (lifting) at EV +2, and the p99→p99.9 headroom
// collapsed from 0.065 to 0.030. Exposure and dehaze must commute:
//
//     render(E, D) = 2^E · render(0, D)
//
// so every measurement below is taken on `I = src / g` and the recovery is multiplied back by `g`:
// the four passes run on the same numbers for every exposure, and the stage becomes exactly
// scale-equivariant in the exposure gain (`g` is the S1 gain and nothing else — white balance is the
// light source, not the slider, and is deliberately *not* divided out). `g == 1` for a neutral
// document, so every estimate is bit-identical to the pre-141 pass; multiplication/division by 1.0 is
// exact, which is what keeps the `E = 0` frames byte-for-byte unchanged.
//
// The 135 airlight cap is estimated in that same normalized space (`p99(L/g)` and `A/g`) and the
// apply pass multiplies the capped value back by `g`: without this, a bright frame would push `A`
// through the `0.95·p99` ceiling and dehaze would become a no-op (measured: EV +4 with `D = 100` was
// bit-identical to `D = 0`).

struct DehazeParams {
    // amount (−1…1), ω, t0, "no haze" threshold for A
    float4 a;
    // content rect: origin x, origin y, width, height (canvas pixels) — the letterbox guard
    float4 b;
    // canvasW, canvasH, q (block size), qW
    int4 c;
    // qH, pad, pad, pad
    int4 d;
    // 130: k (the `2A` fade-out edge), legacy per-channel recovery switch, 135: κ (A's cap in
    // units of p99(L)), 141: `g` (S1's exposure gain, the scale every estimate is taken on)
    float4 e;
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
    // 141: divide S1's exposure gain out of every sample before the dark channel is measured, so this
    // block minimum is a fact about the scene light and not about the exposure slider.
    float inv = 1.0 / max(p.e.w, 1e-6);

    float m = 1e9;
    for (int dy = 0; dy < q; ++dy) {
        int y = min(int(gid.y) * q + dy, h - 1);
        for (int dx = 0; dx < q; ++dx) {
            int x = min(int(gid.x) * q + dx, w - 1);
            float3 c = src.read(uint2(x, y)).rgb * inv;
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

/// 135 — the airlight's **upper bound**: `A = A_raw` while `A_raw ≤ 1.02·p99(L)`, else `κ·p99(L)`.
///
/// The +2 EV DJI frame that exposed 135 has `A_raw = 2.283` while the picture's own 99th percentile
/// luminance is `2.035`: the brightest block minimum can sit above almost every pixel's brightness,
/// and then `A(1 − t) > L` for a large share of the frame, so `J = (L − A(1−t))/t` is negative and
/// the clamp writes black (46.8 % of the pixels at `amount = 100`, measured). A veil cannot be
/// brighter than the scene's own bright end; capping `A` there is a one-line physical bound and
/// leaves the dark-channel/airlight estimates themselves untouched.
///
/// `p99(L)` is estimated on the GPU from a deterministic 1/64…1/65 536-stride sample of the content
/// rectangle with a 12-step bisection over `[0, 1]`, the model's own white point: a value above white
/// is a highlight, not a veil, so the tail is clipped there before the percentile is taken (`p99` is
/// therefore `1` on any frame with ≥1 % of its pixels at or above white). The result is a 1 × 1
/// texture that the apply pass samples. One threadgroup, no atomics, no readback. `κ = 0.95`
/// (`p.e.z`), i.e. "the airlight may reach 95 % of the bright end". The 2 % deadband means an
/// estimate that merely grazes the percentile keeps its measured value: the synthetic veil's bright
/// band sits 0.1 % above its p99, and a blanket 5 % cut there costs the dark channel 16 points.
///
/// **141**: the percentile is taken on `L / g` (S1's exposure gain divided out), so the cap is a fact
/// about the scene and the same `A` survives every exposure. Both `A` (from the normalized dark
/// channel) and the ceiling are in that space; the apply pass multiplies the capped value back by `g`.
constant uint DEHAZE_LIMIT_LANES = 256;

kernel void s1_9_dehaze_limit(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::read> airlight [[texture(1)]],
                              texture2d<float, access::write> limited [[texture(2)]],
                              constant DehazeParams &p [[buffer(0)]],
                              uint tid [[thread_position_in_threadgroup]]) {
    threadgroup float scratch[DEHAZE_LIMIT_LANES];
    threadgroup float tailCount;

    int w = p.c.x, h = p.c.y;
    int x0 = clamp(int(round(p.b.x)), 0, max(w - 1, 0));
    int y0 = clamp(int(round(p.b.y)), 0, max(h - 1, 0));
    int cw = clamp(int(round(p.b.z)), 1, max(w - x0, 1));
    int ch = clamp(int(round(p.b.w)), 1, max(h - y0, 1));
    int n = cw * ch;

    // At most ~65 k samples: enough that the 1 % tail is measured from ~650 pixels, cheap enough
    // that the pass is invisible next to the two full-resolution passes around it.
    int stride = max(1, n / 65536);
    int samples = (n + stride - 1) / stride;
    // 141: the percentile is measured on the unexposed light (the dark channel already is); `g == 1`
    // makes this exact identity, so the pre-141 `E = 0` frame is untouched.
    float inv = 1.0 / max(p.e.w, 1e-6);

    float lo = 0.0, hi = 1.0;
    for (int it = 0; it < 12; ++it) {
        float mid = 0.5 * (lo + hi);
        int above = 0;
        for (int s = int(tid); s < samples; s += int(DEHAZE_LIMIT_LANES)) {
            int i = s * stride;
            int x = x0 + i % cw;
            int y = y0 + i / cw;
            float L = dot(src.read(uint2(x, y)).rgb, kWorkingLumaWeights) * inv;
            if (L >= mid) { above += 1; }
        }
        scratch[tid] = float(above);
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint step = DEHAZE_LIMIT_LANES / 2; step > 0; step >>= 1) {
            if (tid < step) { scratch[tid] += scratch[tid + step]; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) { tailCount = scratch[0]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (tailCount > 0.01 * float(samples)) { lo = mid; } else { hi = mid; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    float A = airlight.read(uint2(0, 0)).r;
    float kappa = clamp(p.e.z, 0.0, 1.0);
    float ceiling = (samples > 0) ? lo : A;
    // Cap only when the estimate is *materially* above the picture's bright end. `min` with a 2 %
    // margin: a block minimum that merely grazes the 99th percentile (the synthetic veil's bright
    // band sits 0.1 % above it) is inside the bright end and keeps its measured value; the +2 EV
    // sky (A = 2.28 against a white-clipped p99 of 1.0) is not. Applying the κ margin unconditionally
    // would darken every A by 2 %, which is measurable on the synthetic veil: its dark channel then
    // drops 42 % instead of the required 50 %.
    if (kappa > 0.0 && A > ceiling * 1.02) { A = kappa * ceiling; }
    limited.write(float4(clamp(A, 1e-4, 8.0), 0.0, 0.0, 1.0), uint2(0, 0));
}

/// The recovery: `t = max(1 − ω·D, t0)`, then (130) the He inversion on **luminance only** with the
/// `w = 1 − smoothstep(A, kA, L)` fog-amount fade, and one common gain on all three channels;
/// `out = mix(I, J, amount)`. Negative amount adds the veil back (`hazy = 0.6·I + 0.4·A`), unchanged.
/// **135** reads the capped airlight from `limited` (texture 2). No upper clamp:
/// `J ≤ I/t0` is the physical bound, and S4's headroom decides how much of that tail is written.
/// **141** runs the whole recovery in the unexposed space `I/g` and multiplies the result back by
/// `g`, so the stage commutes with S1's exposure gain (`g == 1` is bit-identical to the pre-141 pass).
kernel void s1_9_dehaze_apply(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::sample> dark [[texture(1)]],
                              texture2d<float, access::read> limited [[texture(2)]],
                              texture2d<float, access::write> dst [[texture(3)]],
                              constant DehazeParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    float3 I = c.rgb;
    // 141: the whole model lives in the unexposed light; `g` is the same gain S1 applied upstream.
    float g = max(p.e.w, 1e-6);
    float3 In = I / g;

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
    float A = limited.read(uint2(0, 0)).r;

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
        float3 clear;
        if (p.e.y > 0.5) {
            // Tests only: the pre-130 per-channel recovery, kept so the acceptance can show that the
            // hue rotation is the formula's and not the rest of the chain's.
            clear = (In - A * (1.0 - t)) / t;
        } else {
            // 130: recover luminance, scale all three channels by one gain (hue/chroma invariant),
            // and let the correction fade out where the veil cannot be a meaningful part of the
            // pixel: `w = 0` for `L ≥ k·A`.
            float L = dot(In, kWorkingLumaWeights);
            float recovered = (L - A * (1.0 - t)) / t;
            float k = max(p.e.x, 1.0);
            float w = 1.0 - smoothstep(A, k * A, L);
            float Lout = mix(L, recovered, w);
            float gain = max(Lout, 0.0) / max(L, 1e-6);
            clear = In * gain;
        }
        outRGB = mix(In, clear, amount);
    } else {
        float3 hazy = In * 0.6 + 0.4 * A;
        outRGB = mix(In, hazy, -amount);
    }
    // 141: back into the exposed light; `g == 1` leaves this multiplication exact.
    dst.write(float4(max(outRGB * g, 0.0), c.a), gid);
}
