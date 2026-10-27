#include <metal_stdlib>
using namespace metal;

// S3.7 — film grain (Lightroom's Effects panel, the other half of the card).
//
// Three controls, and the two the shape needs to be a *picture* property rather than a canvas
// property:
//
//   · `amount`     0…100 — the grain's standard deviation. **0 means no grain**, and the pass is not
//                  encoded at all for such a document (`RenderStage.pipeline(hasGrain:)`), so a
//                  neutral document never reaches this file.
//   · `size`       0…100 — the grain's cell, in **frame fractions** (not canvas pixels): 0 = one
//                  cell per frame-width/1500, 100 = one per frame-width/200. Normalizing to the
//                  frame is what makes a 1:1 window show the same grain as the whole frame and an
//                  export at 9504 px show the same grain as the preview — the rule S3c follows for
//                  its falloff, for the same reason (grain is a property of the photograph).
//   · `roughness`  0…100 — how much of the **finer** octave is mixed in. 0 = one smooth lattice,
//                  100 = an equal mix of the lattice and a lattice at half the cell, i.e. more
//                  high-frequency energy for the same amount.
//   · `seed`       0…999 — the hash's only free variable. The noise is a pure function of
//                  (frame position, seed), so the same document renders the same bytes every time
//                  (determinism is a contract here, not an accident: `EffectsTests` hashes two
//                  renders of the same seed and one of another).
//
// The grain is **monochrome** and added after the vignette, in the display-referred domain: the same
// place Lightroom adds it, and the last place before S4 encodes, so amount is in 0…1 units where
// 100 ≈ 14 codes of an 8-bit output.
//
// Geometry is byte for byte S3c's convention: `p.b.xy` is the frame's size in content pixels,
// `p.b.zw` the window's origin, `p.c.yz` the content rect's origin inside the canvas. Without a
// window the three numbers reduce to the content rect. Letterbox padding is never grained.

struct GrainParams {
    float4 a;   // amount, size, roughness, seed
    float4 b;   // frameSize.xy, frameOrigin.xy (content pixels of the whole frame)
    float4 c;   // identity, contentOrigin.x, contentOrigin.y, pad
};

// A 32-bit avalanche hash over (x, y, seed). Deterministic on every GPU the same way integer
// arithmetic is: no `fast::` math, no randomness, no `texture` position, no time.
//
// **Scalar, not a `uint3`.** The first version hashed `uint3(x, y, seed)` and every operator was
// component-wise, so the seed only ever reached `.z` and never came back into `.x` — two seeds gave
// the same picture (measured: seed 7 and seed 8 produced one sha, `EffectsTests`' determinism
// assertion went red). The three inputs have to be folded into one accumulator *here*, before the
// avalanche, or the mix has to cross components explicitly; this does the former.
static inline uint grain_hash(uint x, uint y, uint seed) {
    uint h = (x * 0x9E3779B1u) ^ (y * 0x85EBCA77u) ^ (seed * 0xC2B2AE3Du);
    h ^= h >> 15;
    h *= 0x2545F491u;
    h ^= h >> 13;
    h *= 0x9E3779B1u;
    h ^= h >> 16;
    return h;
}

/// A lattice point's noise in [0, 1), from the **top** 24 bits (one float mantissa's worth) so the
/// value is strictly below 1 and adjacent cells are not correlated in their low bits.
static inline float grain_lattice(int2 p, uint seed) {
    return float(grain_hash(uint(p.x), uint(p.y), seed) >> 8) * (1.0 / 16777216.0);
}

/// Smooth (smoothstep-interpolated) value noise at `q`, in lattice units.
static inline float grain_value(float2 q, uint seed) {
    float2 f = floor(q);
    float2 t = q - f;
    t = t * t * (3.0 - 2.0 * t);
    int2 i = int2(f);
    float v00 = grain_lattice(i, seed);
    float v10 = grain_lattice(i + int2(1, 0), seed);
    float v01 = grain_lattice(i + int2(0, 1), seed);
    float v11 = grain_lattice(i + int2(1, 1), seed);
    float a = mix(v00, v10, t.x);
    float b = mix(v01, v11, t.x);
    return mix(a, b, t.y);
}

kernel void s3_7_grain(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant GrainParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.c.x > 0.5) {
        dst.write(c, gid);
        return;
    }

    // Canvas pixel → position inside the whole frame, then the same guard S3c makes: the letterbox
    // is not part of the picture and must not be grained.
    float2 size = max(p.b.xy, float2(1.0));
    float2 uv = (float2(gid) + 0.5 - p.c.yz + p.b.zw) / size;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        dst.write(c, gid);
        return;
    }

    float amount = clamp(p.a.x / 100.0, 0.0, 1.0);
    float grainSize = clamp(p.a.y / 100.0, 0.0, 1.0);
    float roughness = clamp(p.a.z / 100.0, 0.0, 1.0);
    uint seed = uint(max(p.a.w, 0.0));

    // Cell sizes in frame fractions: 1/1500 (a texel of the fixture's own width) … 1/200 (a grain
    // clump), the finer octave at half that.
    float cell = mix(1.0 / 1500.0, 1.0 / 200.0, grainSize);
    float2 q = uv / cell;
    float coarse = grain_value(q, seed);
    float fine = grain_value(q * 2.0, seed ^ 0x9E3779B9u);
    float n = mix(coarse, fine, roughness) * 2.0 - 1.0;

    // 0.055 in 0…1 units is ~14 codes of an 8-bit output at amount 100 — the ceiling Lightroom's own
    // 100 sits at. Multiplied by `amount` so 0 is exactly 0 and the pass cannot invent noise.
    float sigma = amount * 0.055;
    float3 grained = clamp(c.rgb + n * sigma, 0.0, 4.0);
    dst.write(float4(grained, c.a), gid);
}
