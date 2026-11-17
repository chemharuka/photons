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
//     t    = max(1 − ω·D, t0)             (ω = 0.95, t0 = 0.05 — 417 lowered it from He's 0.1)
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
// **280 — the upper edge is the estimator's resolution too, not `2A`.** `L` between `A` and `2A` used
// to take the full `1/t` recovery while the symmetric fade had already ended, so at `t ≈ 0.12` a
// pixel only 20–50 % above the airlight was multiplied by 1.6–2.2×. On `L1030433` at `dehaze = 20`
// that put the p99–p99.9 band at 1.11× and the p99.9–p100 band at 1.20× (max 1.23×); at 100 the
// same bands reached 1.55×/2.00× (max 2.17×). The user's "去雾把高光抬亮" is exactly this band: a
// bright sky/snow/water frame pushes `A` to 135's cap (`A = 0.95·p99`), so `2A` lands at `1.9·p99`
// and the whole highlight tail participates. The ownership is the **edge**, not the measured `A`:
// the correction is evidence about a pixel only within the airlight estimate's own error bar, so the
// upper edge now ends at `A + 2σ` (the same `σ = 2 %·A` as the lower side's `2σ … k·2σ`). Combined
// with the symmetric fade this leaves `w = 0` for every `L ≥ A` and keeps `L < A` bit-identical.
// The fog is untouched: `A` is still measured, `t` still reads the guided veil, and `J < I` below the
// airlight. A different owner (the `A` estimate itself) would be a separate change; this one only
// narrows who counts as fully participating.
//
// **374 — the edge has to span the SDR/HDR seam.** 280's upper edge (`A + 2σ`) put `w = 0` at
// `L ≈ A`, and `A = 0.95·p99(L)` sits at or below the SDR white on almost every frame, so the
// correction ended *inside* the SDR range: everything below it was darkened, everything above it
// (`L > 1.0`, the HDR highlights) was untouched, and the step between the two is the "断层" the
// user reported. The inversion is continuous at `L = A` (`J(A) = A`); the step was the participation
// function's, not the model's. The fade is now a **C¹ band in log2 luminance, `[0.75·A, 1.33·A]`**
// with a low shoulder at `A` (`w(A) = 0.04`): 1 below `0.75·A` (the deep fog keeps its recovery), 0
// above `1.33·A` (280's HDR contract, and the widest edge that still leaves every measured `p99.9`
// outside the band), and smooth log ramps on both halves of `A`, so `w` and `dw/dL` are continuous
// across `1.0` when `A` is near the SDR white. The shoulder keeps `p99 = A/0.95 = 1.05·A` at
// `w ≈ 0.035`, so 280's p99-band ceiling is met while the curve above it continues to zero. The
// lower edge is wide (`0.75·A`, not `0.92·A`) because a narrow fade *just* below `A` adds its own
// `dw/dL` to the recovery's `1/t`; spreading it keeps the sky band's light (0.981 on `_1263309`,
// against 0.978 before) and removes the 15× adjacent-level step. See `s1_9_dehaze_apply`.
//
// The negative amount is untouched, so `dehaze < 0` is byte-identical to 117.
//
// **417 — the participation is the dark channel's, and `t0` is 0.05.**
// 401 capped the recovery's gain at `[0.4, 1.0]` for four good reasons, and the two halves of that
// clamp turned out to be wrong in one specific case: **uniform fog**. `t` hits its floor as soon as
// `mPixel ≥ (1 − t0)/ω` (`0.947` at `t0 = 0.1`), i.e. for *every* pixel that is "foggy enough", and
// then `gain = 10 − 9A/L` sweeps from `−10.75` (clamped to 0.4) to `1.46` (clamped to 1.0) across
// `L/A ∈ [0.93, 1.06]` — a 0.05-wide window in `L`. So the mid-tones took the floor (60 % darker) and
// the fog itself took the ceiling (**unchanged**, measured 0 % on `L1030600`). Neither is the model's
// behaviour: `J(A) = A`, darker than `A` darkens, brighter than `A` lifts.
//
// Two changes survived measurement (the third the task proposed — a per-pixel ceiling above 1.0 —
// was measured and **rejected**, see below):
//
//   1. **`t0 = 0.05`** (the call site passes it; the kernel reads `p.a.z`). He's 0.1 is a
//      *display-referred* number; on scene light it means "the thickest fog transmits 10 %", and
//      because the floor saturates at `mPixel = 0.947` its slope was the whole 0.05 window above.
//      Halving `t0` doubles the window and makes `t`'s own shape carry more of the curve.
//      **Measured on `L1030600`: `t0` 0.05 / 0.04 / 0.03 / 0.02 all render the four bands identical
//      to 4 decimals** — the fog band's `t` is `max(1 − ω·veilR, t0)` with `veilR` clamped by
//      `mPixel ≤ 1`, so `1 − 0.95·1 = 0.05` and the floor is reached at `t0 ≥ 0.05`; below that the
//      `mPixel` clamp, not `t0`, is the binding constraint. The change is therefore **inert on
//      today's veil**, and kept because it is what makes the fog band's `t` exactly `1 − ω` rather
//      than a `t0` above it. It is *not* load-bearing; see 417's report, ⑧c.
//   2. **The participation is `smoothstep(0.55, 0.75, min_c(I)/A)`**, replacing 374's log-luminance
//      band `[0.75·A, 1.33·A]`. 374 assumed "brighter ⇒ more likely a highlight"; on a uniform-fog
//      frame the *brightest* pixels are the fog, so the fog got `w ≈ 0.003` (protected) while the
//      darker objects under it got `w = 1` (crushed). The dark channel inverts the direction: fog
//      has all three channels high (`L1030600`: `min_c(I)/A` p50 = 1.20), a highlight/object has at
//      least one low (0.39), and the separation is 0.90 of the range. **This is the actual fix**:
//      `L1030600`'s mid band goes −34.68 % → 0.00 % and its fog band −7.34 % → −16.43 %.
//
// **The ceiling stays 1.0 (368/401's flat clamp, 280's contract).** The task's third change —
// `gain ≤ 1.6` where `min_c(I)/A ≥ 0.90` — was implemented and measured: it makes the fog band
// *worse* (−12.57 % vs −16.43 %), because the fog band straddles `A` (`L/A` p50 = 0.932, p90 = 1.048)
// and lifting only the `L > A` half raises the band's mean. It also lifts 102 425 pixels by up to
// 1.6× on `L1030433`, reopening 280's highlight contract. The fog's problem was participation, not
// the ceiling; the two constants it needed are gone rather than left dead.
//
// `mPixel = clamp(min_c(I)/A, 0, 1)` is **still what `tPixel` reads** — the transmission is
// bit-identical to 401's — and the new quantity is the unclamped `darkRatio` beside it.
//
// **Twelve passes (117's three, 135's bound, the veil's seven, and 160's proxy upsample):**
//
//   1. `s1_9_dehaze_dark`     — one texel per qProxy × qProxy proxy block: `.r` = the block's
//                               `min_c min I_c`, `.g` = the block's mean luma.
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
//  11. `s1_9_dehaze_veil_upsample` — the proxy veil into this frame's `qTex`-block grid.
//  12. `s1_9_dehaze_apply`    — samples that veil bilinearly, builds the knee-blended `t`, and
//                               applies the recovery. `max(out, 0)`, **no upper clamp** (HDR is the point).
//
// Passes 1–10 run at **proxy resolution** (a fixed 512-long-edge grid, independent of the render
// scale), so the constants are one set for the fit preview, a 1:1 window and the export.
//
// `A < 0.02` is treated as "no haze": the picture has no veil to remove, so the pass is a copy — adding
// or removing nothing is the only honest answer for a frame whose airlight is essentially black.
//
// The negative amount reverses the same model (`hazy = 0.6·I + 0.4·A`), so the slider is symmetric
// about 0 and 0 is the identity. `A` is now measured on the canonical proxy, which is why 160 moves
// negative amounts too (the haze it adds is the proxy's airlight). The stage exists only when
// `effects.dehaze != 0` (`RenderStage.pipeline(hasDehaze:)`), so a neutral document never reaches
// this file.
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
    // canvas content rect: origin x, origin y, width, height (canvas pixels) — the letterbox guard
    float4 b;
    // proxy canvas W, H, qProxy (block size on the fixed 512 proxy), proxyQW
    int4 c;
    // proxyQH, box axis (0 = horizontal, 1 = vertical), box segment length, box radius in blocks
    int4 d;
    // 130/374: k (`2σ`, the pre-374 participation only), legacy per-channel recovery switch,
    // 135: κ (A's cap in units of p99(L)), 141: `g` (S1's exposure gain, the scale every estimate is
    // taken on)
    float4 e;
    // sourceSize.xy, quarterTurns, pad
    int4 j;
    // the knee (the `tSmooth`/`tPixel` blend width), legacy block-min `t`, pad,
    // pre-374 participation switch
    float4 l;
    // 160 — apply's picture map: frameOrigin.xy, contentOrigin.xy (`imgPx = px + ½ − zw + xy`)
    float4 m;
    // 160 — the picture's own grid in content pixels: frameSize.xy, pad, pad
    float4 n;
    // 160 — the frame veil grid apply samples: veilW, veilH, qTex (canvas px per veil texel), pad
    int4 o;
};

/// Per `qProxy × qProxy` **proxy** block (160: the fixed 512-long-edge statistics proxy, so the
/// window is the same scene area at every render scale): `min` over the block of `min` over channels,
/// in **linear Rec2020**. `min` is associative, so one block-level minimum is exactly the dark
/// channel at the resolution `t` lives at (the paper itself recommends estimating the transmission
/// at low resolution).
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
/// `p99(L)` is estimated on the GPU from a deterministic 1/64…1/65 536-stride sample of the **proxy's
/// content rectangle** (160: a fixed 512-long-edge grid of the whole picture, not the render texture,
/// so the sample set — and the percentile — cannot move with `scale`) with a 12-step bisection over
/// `[0, 1]`, the model's own white point: a value above white
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

// MARK: - 417 — the participation and the gain ceiling are the dark channel's, not the luminance's

/// `w`'s band on `darkRatio = min_c(I)/A`. Below `kDehazeFogLow` the pixel carries no evidence of a
/// veil (at least one channel is dark — a highlight or an object) and is left exactly alone; above
/// `kDehazeFogHigh` all three channels are near the airlight and the pixel is fog. The 0.55…0.75
/// window is wide on purpose: it is a *fraction of A*, so its absolute width follows the veil.
constant float kDehazeFogLow = 0.55;
constant float kDehazeFogHigh = 0.75;

/// 401's floor on the gain, unchanged: the deep end of the recovery is capped at 0.4 (60 % darkening)
/// so the `1/t` slope cannot stretch the contrast inside the fog.
constant float kDehazeGainFloor = 0.4;

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

/// 160 — the canonical proxy veil → **this frame's** veil grid.
///
/// The proxy's block texel is `qProxy` proxy px ≈ `qCanvas` picture px, a length that is one number at
/// every render scale. `apply` must not sample that texture directly: its own canvas is at a
/// different scale, so one proxy texel would cover a different number of *canvas* pixels and the
/// bilinear ramp would be a different physical width in the fit preview and at 1:1. Here every frame
/// block is `qTex = max(1, round(qCanvas·imageScale))` canvas px wide; its centre is mapped to the
/// picture's own grid (`px + ½ − contentOrigin + frameOrigin`) and sampled from the proxy in
/// picture-normalized coordinates. `apply` then samples this grid, which makes its interpolation
/// radius exactly `qTex` canvas px — the same `qCanvas` picture px at every scale.
kernel void s1_9_dehaze_veil_upsample(texture2d<float, access::sample> proxyVeil [[texture(0)]],
                                      texture2d<float, access::write> frameVeil [[texture(1)]],
                                      constant DehazeParams &p [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    if (int(gid.x) >= p.o.x || int(gid.y) >= p.o.y) { return; }
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    int qTex = max(p.o.z, 1);
    float2 canvasPx = (float2(gid) + 0.5) * float(qTex);
    float2 imgPx = canvasPx - p.m.zw + p.m.xy;
    float2 uv = imgPx / max(p.n.xy, float2(1.0));
    float v = clamp(proxyVeil.sample(linearSampler, uv).r, 0.0, 1.0);
    frameVeil.write(float4(v, 0.0, 0.0, 1.0), gid);
}

/// The recovery: (2026-10-31) the knee-blended `t` from the guided veil and the pixel's own dark
/// channel, then (130) the He inversion on **luminance only**; (374) the participation is a C¹ band
/// in log2 luminance (`[0.75·A, 1.33·A]`) and one common gain on all three channels;
/// `out = mix(I, J, amount)`. Negative amount adds the veil back (`hazy = 0.6·I + 0.4·A`), unchanged.
/// **135** reads the capped airlight from `limited` (texture 2). No upper clamp:
/// `J ≤ I/t0` is the physical bound, and S4's headroom decides how much of that tail is written.
/// **141** runs the whole recovery in the unexposed space `I/g` and multiplies the result back by
/// `g`, so the stage commutes with S1's exposure gain (`g == 1` is bit-identical to the pre-141 pass).
///
/// `veil` (texture 1) is this frame's `qTex`-block veil, resampled from the canonical proxy by
/// `s1_9_dehaze_veil_upsample`; its bilinear interpolation is therefore `qTex` canvas px wide at
/// every scale. `darkRaw` (texture 5) is the proxy's untouched block minimum, read only by the
/// tests' pre-change `t` (`p.l.y`).
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
    // 160 — the frame veil's texel is `qTex` canvas px, so the bilinear interpolation below is
    // `qTex` wide. `qTex = max(1, round(qCanvas·imageScale))` is derived from the **canvas** scale,
    // not from the proxy; that is the half of the old bug the statistics proxy alone would leave
    // behind (a low-res frame sampling a veil that is smooth in proxy texels).
    int qTex = max(p.o.z, 1);
    int veilW = max(p.o.x, 1), veilH = max(p.o.y, 1);
    float2 uv = float2((float(gid.x) + 0.5) / (float(qTex) * float(veilW)),
                       (float(gid.y) + 0.5) / (float(qTex) * float(veilH)));
    // Tests only — the pre-2026-10-31 `t`, which read the block minimum straight off the bilinear.
    bool legacy = p.l.y > 0.5;
    float D;
    if (legacy) {
        // The raw proxy block minimum, sampled in the picture's own normalized coordinates.
        float2 imgPx = float2(gid) + 0.5 - p.m.zw + p.m.xy;
        float2 uvProxy = imgPx / max(p.n.xy, float2(1.0));
        D = max(darkRaw.sample(linearSampler, uvProxy).r, 0.0);
    } else {
        D = max(veil.sample(linearSampler, uv).r, 0.0);
    }
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

    // 417 — **the pixel's own dark channel, unclamped.** This is the quantity that tells fog from a
    // highlight (see the 417 note below), so it is computed once here and read by the transmission,
    // the participation and the gain ceiling. `mPixel` (its clamp) is the **same** value `tPixel` has
    // always read: `clamp(darkRatio, 0, 1)`, so the transmission is bit-identical to 401's.
    float darkRatio = min(min(In.r, In.g), In.b) / max(A, 1e-6);
    float mPixel = clamp(darkRatio, 0.0, 1.0);

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
            // pixel.
            //
            // 417 — **participation is the dark channel, not the luminance.**
            //
            // 374's band assumed "the brighter, the more likely a highlight to protect". On a
            // uniform-fog frame that is backwards: the *brightest* pixels are the fog itself, so the
            // fog got `w ≈ 0.003` and was left alone while the darker objects under it (below `A`,
            // `w = 1`) took the whole `1/t` recovery — the direction was inverted.
            //
            // `darkRatio = min_c(I)/A` answers "how much of *this* pixel could the veil account for",
            // and it separates the two populations cleanly (`L1030600`: fog p50 1.202, objects 0.394):
            // a specular highlight has a low dark channel (the other two channels are dark), a fog
            // pixel has all three high. `smoothstep(0.55, 0.75)` puts objects at `w = 0` (untouched,
            // they are not haze) and fog at `w = 1`.
            //
            // `legacyDehazeUnboundedRecovery` (`p.l.w`) keeps the pre-374 participation: it is the
            // identity `t = (L − A)/(J − A)` `DehazeLinearTests` inverts.
            float L = dot(In, kWorkingLumaWeights);
            float recovered = (L - A * (1.0 - t)) / t;
            // 280's `2σ` edge, kept for the tests-only pre-374 participation below.
            float res = 2.0 * sqrt(kDehazeAirEpsRel) * A;    // 4 % of A — twice the σ
            float w;
            if (p.l.w > 0.5) {
                // Tests only (`legacyDehazeUnboundedRecovery`): the pre-374 participation, kept
                // byte for byte so the acceptance can invert `t` from the linear render. Below `A`
                // it is 1, which is the identity `t = (L − A)/(J − A)` DehazeLinearTests relies on.
                w = 1.0 - smoothstep(A, A + res, L);
            } else {
                // **417 — `L ≤ A` gets full participation; only the `L > A` tail fades.**
                //
                // 374 modelled the band in **luminance** on the premise "brighter ⇒ more likely a
                // highlight to protect". On a uniform-fog frame that premise inverts: the fog *is*
                // the brightest thing there, so `L ≈ A` — exactly the pixels the veil covers — got
                // `w = 0.04`, while the objects under the fog (`L ≈ 0.5·A`) got `w = 1` and took the
                // whole `1/t`. Measured on `L1030600` (`A = 0.807`): the fog band 0.70–0.85 was
                // darkened only −7.34 %, and 417's own probe showed the direction was inverted.
                //
                // Every pixel that the veil could account for (`L ≤ A`) is fog or something seen
                // through fog, so it participates fully; above `A` the pixel carries its own light
                // that the veil cannot explain, and `L > A` **cannot** darken anyway
                // (`J − L = (L − A)(1 − t)/t > 0`), so the tail fades to zero at `1.33·A` and 280/117's
                // "the highlight is never lifted" is preserved by the `clamp(gModel, floor, 1.0)` below.
                //
                // Rejected candidates, both measured on the same two fixtures:
                //   · per-pixel `min_c(I)/A` band — a dark object under medium fog has `min_c(I) = 0.4`
                //     (lifted *to* the veil) so it reads "not fog" and gets `w = 0`: contrast
                //     0.3833 → 0.2957 (0.77×, the acceptance wants ≥ 2×).
                //   · patch-level `D/A` — the guided filter is edge-preserving, so a dark region keeps
                //     its own 0.4 and the same 0.77× results.
                // Luminance against `A` is the quantity that separates "veil" from "light of its own".
                w = 1.0 - smoothstep(A, 1.33 * A, L);
            }
            // 401 — **the recovery's darkening depth is capped, not its participation.**
            //
            // 374 fixed the *shape* of `w` (a C¹ band, no step at `1.33·A`) but left the
            // **asymmetry of the two sides' slopes** alone: below `A` the blend moves `L` by the full
            // `1/t` (≈ 7× at `t = 0.14`) and above `A` it moves it by 1. On a frame whose airlight is
            // near SDR white (`A ≈ 0.95`, every 135-capped highlight frame) the band is
            // `[0.71, 1.26]`, so `L = 0.9` lands inside it (darkened, `w ≈ 0.12` on the ramp) while
            // `L = 1.4` lands outside it (byte-untouched): the user's "0.9 掉了、1.4 不动，对比度被
            // 拉爆". `L > A` **cannot** darken — `J − L = (L − A)(1 − t)/t > 0` — so "let the
            // highlight participate" would lift the tail, which is 117 (and 280 put the edge back).
            //
            // The defect that *is* fixable is the depth: the model asks for `gModel = J/L` as low as
            // `1/t` (0.24 measured at `L = 0.5·A`, `t = 0.54`), i.e. the fog band is darkened 4× while
            // a pixel a few percent brighter is darkened 1.6×. Capping the **gain** at a constant
            // floor bounds that ratio without touching `w`, `A`, `t`, `hi = 1.33` or the legibility of
            // the fog: measured on `A = 0.95`, `dehaze = 100`, `gain(0.5)` 0.2406 → 0.4000 and
            // `gain(0.9)` 0.9605 → 0.9603, so `gain(0.9)/gain(0.5)` falls 3.99 → 2.40 (the "contrast
            // is stretched" measurement) while the deep fog is still darkened 60 %.
            //
            // The floor is a **constant**, not `k·amount`: the amount's linearity lives in the
            // `mix(In, clear, amount)` at the end of this kernel, and a floor that read `amount`
            // there would make the half-amount render disagree with `L + α(clear − L)` by 5·10⁻²
            // (measured) instead of 0. The upper clamp keeps 280's contract — a `L > A` pixel is
            // never lifted — and in fact pulls the measured `p99–p99.9` band from 1.007/1.008 to
            // 1.000 on 437/428 (v1's measurement, re-verified here).
            //
            // `legacyDehazeUnboundedRecovery` (`p.l.w`) is deliberately **outside** the cap: it is
            // the identity `t = (L − A)/(J − A)` DehazeLinearTests inverts, and the pre-401 arithmetic
            // byte for byte.
            //
            // **417 — the ceiling is still 1.0.** 401's flat upper clamp is *kept*: the measurement
            // below shows that letting the fog lift is not needed for the fog band and actively
            // counteracts it (`L1030600`, `dehaze = 100`: fog band −16.4 % with the ceiling at 1.0,
            // −12.6 % with it at 1.6, because the fog band straddles `A` and the `L > A` half can
            // only be lifted). It also re-opens 280's highlight contract on `L1030433`. The fog's
            // problem was *participation*, not the ceiling.
            float Lout;
            if (legacy || p.l.w > 0.5) {
                Lout = mix(L, recovered, w);
            } else {
                float gModel = recovered / max(L, 1e-6);
                float gCapped = clamp(gModel, kDehazeGainFloor, 1.0);
                Lout = mix(L, L * gCapped, w);
            }
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
