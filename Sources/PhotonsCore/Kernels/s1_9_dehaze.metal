#include <metal_stdlib>
#include "primaries.metal"
#include "frame_turn.metal"
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
// **The veil's spatial support (2026-10-31).** `D` used to *be* `t`'s only input: a per-block minimum
// upsampled bilinearly. A block minimum jumps by an order of magnitude across a skyline, and bilinear
// interpolation only ramps it over one or two blocks, so `t` stepped at the edge and `J` over/under-shot
// there — the bright/dark rim the user reported. `D` is now a **guided-filter veil**: the same block
// minimum, regressed on the block's mean luma (`a·l + b`, the window's covariance over its variance,
// both from a separable box mean at block resolution) and smoothed twice. A block-min field is
// edge-aware by construction — a regression on a luma guide that is *itself* the same block mean — so
// the veil follows the skyline instead of stepping across it.
//
// `t` then takes **two** estimates and blends them with a knee:
//
//     veilR  = min(veil / A, min_c(I/A))                (the smoothed veil, bounded by this pixel)
//     tSmooth = max(1 − ω·veilR, t0)                    (the guided estimate)
//     tPixel  = clamp(1 − ω·min_c(I/A), t0, 1)          (the pixel's own dark channel — a lower bound)
//     t      = min(max(tSmooth, tPixel) + κ²·knee/4, 1)  where κ = max(knee − |tSmooth − tPixel|, 0)/knee
//
// `max` keeps the pixel's own dark channel from being *over*-recovered (which is what crushes a dark
// edge to black); the knee term is a small lift where the two estimates agree, so the blend cannot
// dim a foggy region that both estimates call foggy. `knee = 0.15`.
//
// The recovery takes no depth term at all: 120b's depth-assisted distribution (the p1/p99 window
// `s1_9_dehaze_limit` used to measure and the strength `t` used to read) was removed in 175 — the
// limit pass now writes `(A, 0, 0, 1)` and `t` is a fact about the picture alone.
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
//      (2026-10-31) The fade is now symmetric about `A`: the evidence for any correction is `|L − A|`,
//      and the recovery multiplies it by `1/t`, so a difference smaller than `A`'s own estimation
//      resolution (4 % of `A`, twice the guided filter's `σ`) is not evidence either way. Without
//      that second fade the sky — 3 % below `A` at `t ≈ 0.12` — lost 20 % of its light. See
//      `s1_9_dehaze_apply`.
//
// The negative amount is untouched, so `dehaze < 0` is byte-identical to 117.
//
// **Eleven passes (117's three, 135's bound, and the veil's seven):**
//
//   1. `s1_9_dehaze_dark`     — one texel per q × q block: `.r` = the block's `min_c min I_c`, `.g` =
//                               the block's mean luma. q = 4. `.r` is bit-identical to pre-2026-10-31
//                               (the minimum's accumulation order did not move).
//   2. `s1_9_dehaze_airlight` — **one threadgroup** scans the block texture for the largest block
//                               minimum (a cheap, deterministic stand-in for He's top 0.1 %), clamps
//                               it to `[1e-4, 8]` and writes a 1 × 1 texture. No CPU readback.
//   3. `s1_9_dehaze_limit`    — 135: the airlight's physical **upper** bound, `min(A_raw, κ·p99(L))`
//                               (`κ = 0.95`, `p99` clipped at white; the cap engages only when the
//                               estimate is materially above the bright end), in a second 1 × 1 texture.
//   4. `s1_9_dehaze_veil_stats` — block resolution: `(l, l·l, p, l·p)` for the guided filter.
//   5. `s1_9_dehaze_box` (h)  — the separable running-sum mean of those stats, horizontal.
//   6. `s1_9_dehaze_box` (v)  — …and vertical.
//   7. `s1_9_dehaze_veil_ab`  — `a = cov/(var + 4e-4·A²)`, `b = mean(p) − a·mean(l)` — the pair.
//   8. `s1_9_dehaze_box` (h)  — the same separable mean, on **(a, b)**: the guided filter's second
//                               smoothing, of the coefficients and not of the reconstruction.
//   9. `s1_9_dehaze_box` (v)  — …and vertical.
//  10. `s1_9_dehaze_veil`     — `veil = a·l + b`, clamped to `[0, 1]`.
//  11. `s1_9_dehaze_apply`    — samples the veil bilinearly, builds the knee-blended `t`, and applies
//                               the recovery. `max(out, 0)`, **no upper clamp** (HDR is the point).
//
// Passes 4–10 run at **block resolution** (`qW × qH`, 1/16 of the canvas's texels at q = 4), so the
// seven new passes cost less than one of the two full-resolution passes they sit between.
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
    // qH, box axis (0 = horizontal, 1 = vertical), box segment length, box radius in blocks
    int4 d;
    // 130: k (the `2A` fade-out edge), legacy per-channel recovery switch, 135: κ (A's cap in
    // units of p99(L)), 141: `g` (S1's exposure gain, the scale every estimate is taken on)
    float4 e;
    // sourceSize.xy, quarterTurns, pad
    int4 j;
    // the knee (the `tSmooth`/`tPixel` blend width), tests-only legacy block-min `t`, pad, pad
    float4 l;
};

/// Per `q × q` block: `min` over the block of `min` over channels, in **linear Rec2020**. `min` is
/// associative, so one block-level minimum is exactly the dark channel at the resolution `t` lives at
/// (the paper itself recommends estimating the transmission at low resolution).
///
/// 2026-10-31 — the same walk also accumulates the block's **mean luma** into `.g`, which is the
/// guided filter's guide. `.r` is untouched by this: the minimum's accumulation order is the same one
/// it has always been, so every existing `.r` assertion reads the same bits. `n` is `q²` even at the
/// canvas's edge, where the reads clamp (that is how the block minimum already treats a short block).
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
    // The guide: the block's mean luma, in the same normalized space as `.r` (`× inv`, which is what
    // makes the 141 identity hold: `g == 1` multiplies by exactly 1.0).
    float sumL = 0.0;
    for (int dy = 0; dy < q; ++dy) {
        int y = min(int(gid.y) * q + dy, h - 1);
        for (int dx = 0; dx < q; ++dx) {
            int x = min(int(gid.x) * q + dx, w - 1);
            float3 c = src.read(uint2(x, y)).rgb * inv;
            m = min(m, min(min(c.r, c.g), c.b));
            sumL += dot(c, kWorkingLumaWeights);
        }
    }
    dark.write(float4(m, sumL / float(q * q), 0.0, 1.0), gid);
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

// MARK: - 2026-10-31 — the guided-filter veil (block resolution)

/// The guided filter's regularization, as a fraction of the airlight: `ε = epsRel·A²`. It is one
/// number with two readers — the coefficient solve below, and the recovery's own resolution, which
/// uses `2·sqrt(epsRel)` (4 % of `A`) as the size of the difference it can trust (see `s1_9_dehaze_apply`).
constant float kDehazeAirEpsRel = 4e-4;

/// `(l, l·l, p, l·p)` per block: the guided filter's window statistics, where `l` is the guide (the
/// block's mean luma, from `s1_9_dehaze_dark`'s `.g`) and `p` is the thing being smoothed (the block
/// minimum, its `.r`). Everything downstream is a separable mean of these four numbers, which is why
/// this is a separate pass rather than a second output of the dark pass: the dark pass's texel keeps
/// exactly the two values it always had and this pass owns the pair products.
kernel void s1_9_dehaze_veil_stats(texture2d<float, access::read> dark [[texture(0)]],
                                   texture2d<float, access::write> stats [[texture(1)]],
                                   constant DehazeParams &p [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.c.w || int(gid.y) >= p.d.x) { return; }
    float4 d = dark.read(gid);
    float l = d.g, q = d.r;
    stats.write(float4(l, l * l, q, l * q), gid);
}

/// Separable running-sum box mean — `MPSImageBox`'s equivalent, hand-written (the main line carries no
/// third-party compute dependency and this chain lives at block resolution, where four passes cost
/// less than one full-resolution pass).
///
/// One thread per `segment` of one row (axis 0) or one column (axis 1); the thread seeds its window
/// with `2r + 1` clamped reads and then slides it, so a pass costs one read per texel after the seed —
/// the same trick `s1_7_box4_h/v` use. `gid` = (segment, line) for the horizontal axis and
/// (line, segment) for the vertical one, which is what lets one kernel serve both.
kernel void s1_9_dehaze_box(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant DehazeParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int qW = p.c.w, qH = p.d.x;
    bool horizontal = p.d.y == 0;
    int len = horizontal ? qW : qH;
    int lines = horizontal ? qH : qW;
    int segment = horizontal ? int(gid.x) : int(gid.y);
    int line = horizontal ? int(gid.y) : int(gid.x);
    if (line >= lines) { return; }
    int segLen = max(p.d.z, 1);
    int i0 = segment * segLen;
    if (i0 >= len) { return; }
    int i1 = min(i0 + segLen, len);
    int r = max(p.d.w, 0);

    // One coordinate walks, the other is fixed; both clamp at the edge (clamp_to_edge, as MPS's box
    // filter's default edge mode does).
    if (r == 0) {
        for (int i = i0; i < i1; ++i) {
            int k = clamp(i, 0, len - 1);
            uint2 t = horizontal ? uint2(uint(k), uint(line)) : uint2(uint(line), uint(k));
            dst.write(src.read(t), t);
        }
        return;
    }
    float inv = 1.0 / float(2 * r + 1);
    float4 acc = float4(0.0);
    for (int i = i0 - r; i <= i0 + r; ++i) {
        int k = clamp(i, 0, len - 1);
        uint2 t = horizontal ? uint2(uint(k), uint(line)) : uint2(uint(line), uint(k));
        acc += src.read(t);
    }
    for (int i = i0; i < i1; ++i) {
        int k = clamp(i, 0, len - 1);
        uint2 t = horizontal ? uint2(uint(k), uint(line)) : uint2(uint(line), uint(k));
        dst.write(acc * inv, t);
        int add = clamp(i + r + 1, 0, len - 1), sub = clamp(i - r, 0, len - 1);
        acc += src.read(horizontal ? uint2(uint(add), uint(line)) : uint2(uint(line), uint(add)))
             - src.read(horizontal ? uint2(uint(sub), uint(line)) : uint2(uint(line), uint(sub)));
    }
}

/// The guided filter's linear coefficients: `a = cov/(var + ε)`, `b = mean(p) − a·mean(l)`, from the
/// window means `s1_9_dehaze_box` produced.
///
/// `ε ∝ A²` is the research pack's regularization: the regression is compared against the veil's own
/// brightness, so a bright (strong) veil is smoothed harder than a faint one — otherwise the faint
/// veil's quantized block minima look like structure and the guide follows noise.
///
/// Written as a pair because the **second** box pair (`s1_9_dehaze_box` again, next) smooths the
/// coefficients, not the reconstruction — that is the guided filter proper (§2.3's "stats 的 box 两向
/// + ab 的 box 两向"), and it is what makes the veil edge-preserving rather than merely smooth.
kernel void s1_9_dehaze_veil_ab(texture2d<float, access::read> stats [[texture(0)]],
                                texture2d<float, access::read> limited [[texture(1)]],
                                texture2d<float, access::write> ab [[texture(2)]],
                                constant DehazeParams &p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.c.w || int(gid.y) >= p.d.x) { return; }
    float A = max(limited.read(uint2(0, 0)).r, 1e-4);
    float eps = kDehazeAirEpsRel * A * A;
    float4 s = stats.read(gid);
    float ml = s.x, mll = s.y, mp = s.z, mlp = s.w;
    float var = max(mll - ml * ml, 0.0);
    float cov = mlp - ml * mp;
    float a = cov / (var + eps);
    ab.write(float4(a, mp - a * ml, 0.0, 1.0), gid);
}

/// `veil = a·l + b`: the boxed coefficients applied to the block's own luma. This is the field the
/// apply pass samples — same texture shape and same bilinear upsample as the block minimum it
/// replaces, so nothing about the resampling changed, only what is in the texel.
kernel void s1_9_dehaze_veil(texture2d<float, access::read> ab [[texture(0)]],
                             texture2d<float, access::read> dark [[texture(1)]],
                             texture2d<float, access::write> out [[texture(2)]],
                             constant DehazeParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.c.w || int(gid.y) >= p.d.x) { return; }
    float2 c = ab.read(gid).xy;
    float l = dark.read(gid).g;
    out.write(float4(clamp(c.x * l + c.y, 0.0, 1.0), 0.0, 0.0, 1.0), gid);
}

/// The recovery: (2026-10-31) the knee-blended `t` from the guided veil and the pixel's own dark
/// channel, then (130) the He inversion on **luminance only** with the `w = 1 − smoothstep(A, kA, L)`
/// fog-amount fade and one common gain on all three channels; `out = mix(I, J, amount)`. Negative
/// amount adds the veil back (`hazy = 0.6·I + 0.4·A`), unchanged.
/// **135** reads the capped airlight from `limited` (texture 2). No upper clamp:
/// `J ≤ I/t0` is the physical bound, and S4's headroom decides how much of that tail is written.
/// **141** runs the whole recovery in the unexposed space `I/g` and multiplies the result back by
/// `g`, so the stage commutes with S1's exposure gain (`g == 1` is bit-identical to the pre-141 pass).
///
/// `veil` (texture 1) is the block-resolution guided veil, sampled bilinearly — the same texture shape
/// and the same sampler the block minimum used, so nothing about the upsample changed; only what is
/// in the texel did. `darkRaw` (texture 5) is the untouched block minimum, read only by the tests'
/// pre-change `t` (`p.l.y`).
kernel void s1_9_dehaze_apply(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::sample> veil [[texture(1)]],
                              texture2d<float, access::read> limited [[texture(2)]],
                              texture2d<float, access::write> dst [[texture(3)]],
                              texture2d<float, access::sample> darkRaw [[texture(5)]],
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
    // Tests only — the pre-2026-10-31 `t`, which read the block minimum straight off the bilinear.
    bool legacy = p.l.y > 0.5;
    float D = max(legacy ? darkRaw.sample(linearSampler, uv).r : veil.sample(linearSampler, uv).r, 0.0);
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
        float t;
        if (legacy) {
            // The pre-change expression verbatim, kept so a test can measure the halo this stage used
            // to leave at a skyline.
            t = max(1.0 - omega * D, t0);
        } else {
            // The pixel's own normalized dark channel: `min_c(I/A)`, i.e. how much of *this* pixel the
            // veil could account for. Below `A` it is fog; above, it is object.
            float mPixel = clamp(min(min(In.r, In.g), In.b) / A, 0.0, 1.0);
            // The guided veil, bounded by this pixel: a texture that claims more haze than the pixel
            // carries is not evidence about the pixel.
            float veilR = clamp(min(D / A, mPixel), 0.0, 1.0);
            float tSmooth = max(1.0 - omega * veilR, t0);
            float tPixel = clamp(1.0 - omega * mPixel, t0, 1.0);
            // The knee: where the two estimates agree (within `knee`) the pair is trusted and lifted by
            // up to `knee/4`; where they disagree the larger one wins, so a smoothed veil can never
            // over-recover a dark edge into black and a bright pixel can never be under-recovered.
            float knee = max(p.l.x, 1e-4);
            float closeness = max(knee - fabs(tSmooth - tPixel), 0.0) / knee;
            t = min(max(tSmooth, tPixel) + closeness * closeness * knee * 0.25, 1.0);
        }
        float3 clear;
        if (p.e.y > 0.5) {
            // Tests only: the pre-130 per-channel recovery, kept so the acceptance can show that the
            // hue rotation is the formula's and not the rest of the chain's.
            clear = (In - A * (1.0 - t)) / t;
        } else {
            // 130: recover luminance, scale all three channels by one gain (hue/chroma invariant),
            // and let the correction fade out where the veil cannot be a meaningful part of the
            // pixel: `w = 0` for `L ≥ k·A`, and `w = 0` again within the airlight's own resolution.
            //
            // The second fade is 2026-10-31's. It used to be only the upper one — full participation
            // at or below `A` — and at or below `A` the veil's *whole* evidence is `A − L`, which the
            // recovery then multiplies by `1/t`. At the sky `t ≈ 0.12`, so the 3 % by which the
            // airlight estimate sits above the sky (`L/A = 0.971` on `_1263309`) came out as a 20 %
            // darkening (`J/I = 0.797`). `A` is a measurement, not a constant: over this frame's sky
            // band it spreads 0.405…0.438, i.e. ±4 % of `A`, so a 3 % offset is inside the
            // estimator's own error bar. A correction whose evidence is smaller than the estimator's
            // resolution is not evidence, so participation fades in over `2σ … k·2σ` of `A`
            // (`σ = sqrt(kDehazeAirEpsRel)·A = 2 %·A`, the guided filter's own regularization — one
            // number, two readers). The fade is **symmetric**: a pixel a few percent *above* the
            // airlight is not lifted either, and everything further than `8 %·A` from `A` — the whole
            // mid-ground band is at 37 % — keeps exactly the correction it had.
            float L = dot(In, kWorkingLumaWeights);
            float recovered = (L - A * (1.0 - t)) / t;
            float k = max(p.e.x, 1.0);
            float w = 1.0 - smoothstep(A, k * A, L);
            // Tests only (`legacyDehazeUnboundedRecovery`): the pre-2026-10-31 upper fade alone, so the
            // counterproof can measure the darkening this test exists to prevent.
            if (p.l.w < 0.5) {
                float res = 2.0 * sqrt(kDehazeAirEpsRel) * A;    // 4 % of A — twice the σ
                w *= smoothstep(res, k * res, fabs(L - A));      // …full again at 8 %
            }
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
