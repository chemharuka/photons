#include <metal_stdlib>
using namespace metal;

// S1.9 — **修复 / 克隆** (078 P0-1 / B9): Lightroom's spot removal, in the smallest form that is
// still the real operation.
//
// ## Where it runs, and why
//
// S1.9 sits **after S1.6 (masks) and before S1.7 (the curve)** — see `RenderStage.order`. Three
// reasons, and each one would be enough:
//
//   1. **It has to see the pixels that are there.** S0 has already cropped, turned and straightened,
//      so the canvas grid *is* the picture the user is pointing at: a disk on this grid is a disk on
//      the photograph, at every scale, in every window. Running before S0 would put the spot in
//      source space and every sample would need S0's transform (and its inverse) — two spellings of
//      one geometry, which is the class of defect 080 spent a task removing from the mask atlas.
//   2. **It is a repair, not a look.** A blemish is in the picture; the curve, the tone map, the
//      colour stage and the effects are a look applied *to* the picture. Putting the repair after
//      the tone map would mean the source texture had already been through a spatially-varying
//      grade (a vignette darkens the corners), so copying it elsewhere would carry the wrong
//      light — and the boundary correction would be fitting a difference that is partly the tone
//      map's, not the picture's. Before S1.7 the data is scene-linear and *unbounded*, which is also
//      the domain where "add a plane" is physically what a light difference is.
//   3. **After S1.6, not before it.** S1.6 writes the mask adjustments into the frame. A spot that
//      sampled *under* a mask is a spot that samples a texture the user never saw; sampling what
//      S1.6 produced is the only choice that makes 「源点」 mean the visible pixels. (The reverse
//      argument — masks should apply to the healed picture — is true too, and it is *also*
//      satisfied: S1.6 runs first, so its adjustments are inside both the destination and the
//      source, and a mask that darkens this corner does not create a seam at a spot's rim.)
//
// ## The two modes
//
// `clone`  out = mix(dst, src(q + o), w)                       — a copy, verbatim.
//
// `heal`   out = mix(dst, src(q + o) + P(q), w)                — a copy **plus a plane**.
//
// 229 — `redeye` is mode 2 and it is **not a third repair**: it is `heal` with `w` gated by the
// destination pixel's display-encoded redness (`heal_redness`), plus a hue pull-to-neutral on a
// source that is itself red. Non-red pixels inside the disk get `w = 0`, which is what keeps the
// skin around a pupil byte-identical. The same redness definition lives in `RedEye.swift`.
//
// `P` is the boundary correction, and it is this build's version of Lightroom's Poisson step:
//
// ### What Poisson would do, and what this does instead
//
// The exact operation is "find the image whose Laplacian equals the source's inside Ω and whose
// values match the destination's on ∂Ω" — solving Δf = Δs on Ω with f|∂Ω = d|∂Ω. The membrane (the
// correction) is then the harmonic function with boundary values `d − s`:
//
//     Δm = 0 on Ω,   m|∂Ω = (d − s)|∂Ω,   f = s + m.
//
// On a disk, the exact solution of the Dirichlet problem is a **Poisson integral** (a full circle of
// boundary values, every one of them weighted by the Poisson kernel). Solving it needs a solve, and
// a solve needs iterations or a spectral basis — which is not what an L-sized task should put in a
// per-frame pass.
//
// This is the **first-order truncation** of that integral. Expand the boundary data in Fourier
// series on the rim, `d − s = a₀ + Σ (aₙ cos nθ + bₙ sin nθ)`, and the harmonic extension of each
// term inside the disk is `rⁿ` times the same angular function (the Poisson kernel's own Taylor
// series: `P(r, θ−φ) = 1 + 2Σ rⁿ cos n(θ−φ)`). So
//
//     m(r, θ) = a₀ + Σ rⁿ (aₙ cos nθ + bₙ sin nθ),
//
// and this pass keeps **n ≤ 1**:
//
//     m(u, v) = a₀ + a₁·u + b₁·v          (u, v) = (q − c)/R,  |(u,v)| ≤ 1
//
// which is exactly an affine **plane**: the boundary's mean (a₀) and its gradient (a₁, b₁). The
// dropped terms are the rim's second and higher harmonics, scaled by `rⁿ`:
//
//     |error| ≤ Σ_{n≥2} rⁿ √(aₙ² + bₙ²) ≤ r² · max|d − s| · (2/π)  (Cauchy–Schwarz on the series)
//
// i.e. **the correction is exact for a linear light difference and wrong by at most `r²` times the
// rim's curvature content.** On a gradient background that is the whole job; on a strongly curved
// falloff (a hot spot's edge) a visible residual ring of the second harmonic remains — stated, not
// hidden, and the number `HealTests` reports is measured, not assumed.
//
// ### Where the coefficients come from
//
// They are a **least-squares fit of `d − s` over the rim ring**, not a single mean. Sampling the ring
// at `N = 256` equally spaced angles makes the normal equations of the fit `[1, u, v]` collapse to a
// diagonal (`Σu = Σv = Σuv = 0`, `Σu² = Σv² = N/2`), so the fit has a closed form:
//
//     a₀ = (1/N) Σₖ (dₖ − sₖ)
//     a₁ = (2/N) Σₖ (dₖ − sₖ)·uₖ
//     b₁ = (2/N) Σₖ (dₖ − sₖ)·vₖ
//
// One reduce over 256 texels per spot per channel, done once per frame by `s1_9_heal_stats` into a
// 3×float4 record (`HealStatU`), and read by every pixel of the apply pass. **No atomics, no
// order-dependent accumulation**: the ring is walked in a fixed order by one thread, so two renders
// of the same document produce the same bytes (the determinism contract every stage here has).
//
// ## The blend
//
// `t = |q − c| / R`, and
//
//     w = opacity · (1 − smoothstep(1 − feather, 1, t))     0 ≤ t < 1;  else 0
//
// so `w = 1` for `t ≤ 1 − feather` (full coverage) and `w = 0` **at the rim** — the destination is
// untouched on ∂Ω by construction, which is what keeps the seam C⁰ even when the correction is
// imperfect. `feather = 0` is the hard edge: `w = 1` everywhere inside, `w = 0` outside, and then
// the rim's continuity is the correction's own doing — which is why `HealTests` measures the
// boundary jump with `feather = 0`: with a feather the measurement would be a tautology about the
// ramp instead of a claim about the arithmetic.
//
// `clone` with `feather = 0` copies the source **verbatim** (`w = 1` ⇒ `out = src`, no `mix`
// arithmetic at all — `mix` with a weight of exactly 1 is `x + (y − x)` and that is not always `y`
// in IEEE), which is the setting under which the byte-for-byte claim of the acceptance holds.
//
// ## Multiple spots
//
// The apply pass walks the spot list in document order and **always samples the input texture**, not
// its own output: spot *k+1*'s source is the picture as S1.6 left it, so adding a spot cannot change
// what an earlier spot sampled. Two spots that overlap compose (`v` accumulates), two that do not
// are independent, and the third spot's own disk is untouched by the first two — `HealTests`
// measures all three.
//
// ## Geometry
//
// Everything arrives in **canvas pixels** (`HealSpotU`, computed once on the CPU by
// `RenderGraph.healSpotU`: `center = origin − frameOrigin + c·frameSize`, `radius = r·min(frameSize)`,
// `offset = o·min(frameSize)`), so a window render and a whole-frame render put the disk in the same
// physical place. The letterbox outside the content rect is never touched: those pixels are copied.

struct HealSpotU {
    float4 a;   // centerCanvas.xy, radiusPx, feather (0…1 of the radius)
    float4 b;   // offsetCanvas.xy, opacity, mode (0 = heal, 1 = clone, 2 = redeye)
    // 229 — the red gate. `x` threshold, `y` softness, both in display-encoded redness. A heal /
    // clone spot leaves them zero; a no-detection redeye spot carries a threshold no pixel can pass.
    float4 c;
};

struct HealParamsU {
    float4 a;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    // spotCount, boundaryMatch (1 = fit the plane), dispatchOrigin.xy. 257 C2: the apply pass is
    // dispatched once per spot over its bbox, and the kernel starts from `thread_position_in_grid +
    // dispatchOrigin`; the pre-257 whole-canvas dispatch passes (0, 0), so its math is untouched.
    float4 b;
    // 257 C0: frequencySeparation (1/0), gaussian sigma (canvas px), lowpassOrigin.xy. Zero in the
    // pre-257 path, which is that path's uniform byte for byte.
    float4 c;
};

/// The fitted correction, one record per spot. `cN` = (a₀, a₁, b₁, 0) for channel N (R, G, B).
struct HealStatU {
    float4 c0;
    float4 c1;
    float4 c2;
};

constant int kRingSamples = 256;

constexpr sampler kHealSampler(coord::normalized, filter::linear, address::clamp_to_edge);

static inline float heal_smoothstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / max(e1 - e0, 1e-6), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

// 229 — the red gate's definition, byte for byte the one in `RedEye.redness(r:g:b:)`. Measuring in
// display encoding is what separates a red pupil from neutral skin: in scene linear a warm skin
// tone and a dim red eye can have the same `r − max(g,b)`.
static inline float heal_srgb(float x) {
    float c = max(x, 0.0);
    return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

static inline float heal_redness(float3 c) {
    return heal_srgb(c.r) - max(heal_srgb(c.g), heal_srgb(c.b));
}

// MARK: - pass 1: the boundary ring's mean and gradient, per spot

kernel void s1_9_heal_stats(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::sample> samp [[texture(1)]],
                            constant HealSpotU *spots [[buffer(0)]],
                            constant HealParamsU &p [[buffer(1)]],
                            device HealStatU *stats [[buffer(2)]],
                            uint sid [[thread_position_in_grid]]) {
    if (int(sid) >= int(p.b.x)) { return; }
    HealSpotU s = spots[sid];
    float2 c = s.a.xy;
    float r = max(s.a.z, 1e-3);
    float2 size = float2(src.get_width(), src.get_height());
    float2 offset = s.b.xy;

    float3 sum = float3(0.0);      // Σ d
    float3 sumU = float3(0.0);     // Σ d·u
    float3 sumV = float3(0.0);     // Σ d·v
    for (int k = 0; k < kRingSamples; ++k) {
        float th = 6.283185307179586 * (float(k) + 0.5) / float(kRingSamples);
        float2 u = float2(cos(th), sin(th));
        float2 q = c + r * u;
        // The destination sample is a **texel read** (the ring has no sub-texel meaning), the source
        // sample is a bilinear one (its position is `q + offset`, i.e. wherever the user put it).
        int2 iq = clamp(int2(round(q)), int2(0), int2(size) - 1);
        float3 d = src.read(uint2(iq)).rgb
                 - samp.sample(kHealSampler, (q + offset + 0.5) / size).rgb;
        sum += d;
        sumU += d * u.x;
        sumV += d * u.y;
    }
    // The closed-form least squares of `[1, u, v]` over a uniform ring (see the header).
    float3 a0 = sum * (1.0 / float(kRingSamples));
    float3 a1 = sumU * (2.0 / float(kRingSamples));
    float3 b1 = sumV * (2.0 / float(kRingSamples));
    // `boundaryMatch == 0` is the **refutation** hook: the plane is zeroed, i.e. `heal` behaves as a
    // plain copy. `HealTests.testTheRefutationMakesTheBoundaryJumpFail` turns it on and shows the
    // acceptance's 「跳变 ≤ 2 码」 assertion going red — the proof the ring measurement is
    // load-bearing rather than a claim about a feather that ramps to zero anyway.
    if (p.b.y < 0.5) { a0 = float3(0.0); a1 = float3(0.0); b1 = float3(0.0); }
    HealStatU out;
    out.c0 = float4(a0.r, a1.r, b1.r, 0.0);
    out.c1 = float4(a0.g, a1.g, b1.g, 0.0);
    out.c2 = float4(a0.b, a1.b, b1.b, 0.0);
    stats[sid] = out;
}

// MARK: - 257 C0: the horizontal half of the frequency-separation membrane
//
// Ported from LightCraft (MIT) — crates/pipeline/src/spots.rs, heal branch.
//
// `outside = (alpha < 0.02) ? 1 : 0`, and this pass writes the horizontal Gaussian of
// `(target − source)·outside` (rgb) and of `outside` (a) into `hbuf`. The apply pass finishes the
// vertical Gaussian and divides: `low = G(diff) / max(G(outside), 1e-4)`, `out = source + low`.
// Two separable passes, no iteration, no convergence test. `spots[0]` is the current spot (the
// Swift side passes a one-element array), so the same reduction order is used for every pixel.
kernel void s1_9_heal_lowpass(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::sample> samp [[texture(1)]],
                              texture2d<float, access::write> hbuf [[texture(2)]],
                              constant HealSpotU *spots [[buffer(0)]],
                              constant HealParamsU &p [[buffer(1)]],
                              uint2 gid0 [[thread_position_in_grid]]) {
    HealSpotU spot = spots[0];
    float r = max(spot.a.z, 1e-3);
    float sigma = max(p.c.y, 1.0);
    int radius = int(ceil(3.0 * sigma));
    float inv = 1.0 / (2.0 * sigma * sigma);
    float2 size = float2(src.get_width(), src.get_height());
    int2 origin = int2(round(p.c.zw));
    int2 c = origin + int2(gid0);

    float3 dsum = float3(0.0);
    float msum = 0.0;
    for (int k = -radius; k <= radius; ++k) {
        int2 q = clamp(int2(c.x + k, c.y), int2(0), int2(size) - 1);
        float2 qf = float2(q) + 0.5;
        float3 target = src.read(uint2(q)).rgb;
        float3 source = samp.sample(kHealSampler, (qf + spot.b.xy) / size).rgb;
        float t = length(qf - spot.a.xy) / r;
        float alpha = spot.b.z * (1.0 - heal_smoothstep(1.0 - spot.a.w, 1.0, t));
        float outside = alpha < 0.02 ? 1.0 : 0.0;
        float wgt = exp(-float(k * k) * inv);
        dsum += (target - source) * outside * wgt;
        msum += outside * wgt;
    }
    hbuf.write(float4(dsum, msum), gid0);
}

// MARK: - pass 2: every canvas pixel, every spot in order

kernel void s1_9_heal_apply(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            texture2d<float, access::sample> samp [[texture(2)]],
                            texture2d<float, access::read> low [[texture(3)]],
                            constant HealSpotU *spots [[buffer(0)]],
                            constant HealParamsU &p [[buffer(1)]],
                            constant HealStatU *stats [[buffer(2)]],
                            uint2 gid0 [[thread_position_in_grid]]) {
    // 257 C2 — the only change to this kernel's coordinates: a per-spot dispatch starts at the
    // spot's bbox corner. The whole-canvas dispatch passes (0, 0), so every line below is the
    // pre-257 line with the same `gid`.
    uint2 gid = gid0 + uint2(uint(round(p.b.z)), uint(round(p.b.w)));
    float4 v = src.read(gid);
    float2 size = float2(src.get_width(), src.get_height());
    float2 local = float2(gid) + 0.5 - p.a.xy;
    int count = int(p.b.x);
    // Letterbox: never healed, never measured. Copied, so the matte is byte-identical.
    if (count == 0 || local.x < 0.0 || local.y < 0.0
        || local.x > p.a.z || local.y > p.a.w) {
        dst.write(v, gid);
        return;
    }

    for (int s = 0; s < count; ++s) {
        HealSpotU spot = spots[s];
        float2 rel = float2(gid) + 0.5 - spot.a.xy;
        float r = max(spot.a.z, 1e-3);
        float t = length(rel) / r;
        if (t >= 1.0) { continue; }

        float w = spot.b.z * (1.0 - heal_smoothstep(1.0 - spot.a.w, 1.0, t));
        if (w <= 0.0) { continue; }

        // 229 — red-eye is a **gated heal**: the disk decides *how much* of the repair can reach a
        // pixel, and the pixel's own redness decides whether it is a repair at all. Non-red pixels
        // therefore keep their bytes, which is the negative acceptance (a click on skin is a no-op)
        // and the reason the acceptance can demand "outside the circle unchanged".
        bool redeye = spot.b.w > 1.5;
        if (redeye) {
            float soft = max(spot.c.y, 1e-4);
            float redAlpha = heal_smoothstep(spot.c.x - soft, spot.c.x + soft, heal_redness(v.rgb));
            w *= redAlpha;
            if (w <= 0.0) { continue; }
        }

        // The source texel, bilinearly sampled at `p + offset` (clamped at the frame's edge, which is
        // what a spot whose source runs off the picture means).
        // `q` is already a pixel centre (`gid + 0.5` plus the offset), so the normalized coordinate
        // is `q / size`; an integer offset lands exactly on a texel centre, which is what makes the
        // clone's copy byte-exact rather than merely close.
        float2 q = float2(gid) + 0.5 + spot.b.xy;
        float3 s4 = samp.sample(kHealSampler, q / size).rgb;

        if (spot.b.w < 0.5 || redeye) {
            bool frequency = (p.c.x > 0.5) && spot.b.w < 0.5;
            if (frequency) {
                // 257 C0 — frequency separation. `low` holds the **horizontal** half of
                // gaussian((target − source)·outside) and gaussian(outside) (rgb = the first, a =
                // the second), written by `s1_9_heal_lowpass`; this finishes the vertical half and
                // divides (normalized convolution = the membrane interpolation).
                //
                // Ported from LightCraft (MIT) — crates/pipeline/src/spots.rs, heal branch.
                // https://github.com/lightcraft/lightcraft — `low = gaussian(diff, σ) /
                // max(gaussian(outside, σ), 1e-4); out = source + low`, σ = max(r·0.6, 1).
                float sigma = max(p.c.y, 1.0);
                int radius = int(ceil(3.0 * sigma));
                int2 origin = int2(round(p.c.zw));
                int2 l = int2(gid) - origin;
                int lw = int(low.get_width()) - 1;
                int lh = int(low.get_height()) - 1;
                float3 dsum = float3(0.0);
                float msum = 0.0;
                float inv = 1.0 / (2.0 * sigma * sigma);
                for (int j = -radius; j <= radius; ++j) {
                    int yy = clamp(l.y + j, 0, lh);
                    float4 h = low.read(uint2(uint(clamp(l.x, 0, lw)), uint(yy)));
                    float wgt = exp(-float(j * j) * inv);
                    dsum += h.rgb * wgt;
                    msum += h.a * wgt;
                }
                s4 += dsum / max(msum, 1e-4);
            } else {
                // heal / redeye — add the plane. (u, v) is the offset **inside the disk**, in radii, so
                // the plane reproduces the rim's own mean and gradient where the blend hands over.
                float2 uv = rel / r;
                HealStatU st = stats[s];
                s4.r += st.c0.x + st.c0.y * uv.x + st.c0.z * uv.y;
                s4.g += st.c1.x + st.c1.y * uv.x + st.c1.z * uv.y;
                s4.b += st.c2.x + st.c2.y * uv.x + st.c2.z * uv.y;
            }
        }

        if (redeye) {
            // 红瞳像素的色相拉回中性（`r ← (g+b)/2`）。The automatic source normally avoids red, but
            // two pupils in one face can put the `2r…4r` band on the other one; this is the last
            // line of defence, and it only fires when the sampled result is itself red.
            if (heal_redness(s4) > spot.c.x) {
                s4.r = 0.5 * (s4.g + s4.b);
            }
        }

        if (w >= 1.0) {
            // A full-strength copy is **the source**, not `mix(dst, src, 1)` — that expression is
            // `dst + (src − dst)` and is not `src` to the last bit. This branch is what makes the
            // clone acceptance a byte-for-byte claim.
            v.rgb = s4;
        } else {
            v.rgb = mix(v.rgb, s4, w);
        }
    }
    dst.write(v, gid);
}
