#include <metal_stdlib>
using namespace metal;

// S4 — display: primaries matrix, then the sRGB transfer function. Nothing after this.
//
// The matrix is the graph's **working primaries → linear output primaries**, identity for a target
// that matches the working space. Since 075 the working space is linear **Rec.2020**, so this is
// `Rec2020 → sRGB` (or `Rec2020 → Display P3`), fed from `ColorPrimaries.conversion` by `RenderGraph`.
// Encoding is the sRGB piecewise OETF, which Display P3 also uses.
//
// The upper bound is `headroom`, not 1. With headroom = 1 this is exactly the old
// `clamp(v, 0.0, 1.0)` (pixel-identical, golden-checked); with headroom > 1 the >1 values produced
// by the D2′ decode recipe survive into the texture, which is what EDR consumes in M3.5
// (docs/architecture-decisions.md §11.8). The file-export path always passes headroom = 1.
//
// ── 075: the lower clamp is **after** the matrix, and that is a bug fix ─────────────────────────
// This kernel used to clamp `max(c.rgb, 0)` *before* the matrix and then write the matrix's output
// unclamped. That was harmless while the only matrix was `sRGB → Display P3`, whose nine
// coefficients are all ≥ −1e-9 (a white-preserving convex combination): a non-negative input cannot
// produce a negative output, so the missing clamp never bit.
//
// `Rec.2020 → sRGB` is not that matrix. Its smallest coefficient is **−0.5876411**, so a saturated
// Rec.2020 green `(0, 1, 0)` comes out as `R = −0.5876`. Unclamped, that negative goes straight
// through `srgb_encode`'s negative branch (`12.92·v`) into the texture as **−7.59**:
//
//   · the export path's `min(max(v,0),1)` rescues the *file*, but only after the value has already
//     been treated as a linear light by the clamp, i.e. in the wrong domain;
//   · the EDR path (`present.metal`) hands it to an `extendedLinearDisplayP3` drawable as **negative
//     light**;
//   · `histogram_sample` lands it on a negative code — the bin index is computed from a value the
//     axis does not have.
//
// So the clamp moves to where it is a statement about the *output* primaries' cube: after the
// matrix. `NewSaturatedColourTests.testS4ClampsAfterThePrimariesMatrix` renders a pure Rec.2020
// green and asserts every output channel is ≥ 0 — and that test is red if this line moves back
// above the matrix (measured: R = −7.5938).

struct DisplayParams {
    float4x4 m;   // working primaries → linear output primaries (column-major, from ColorPrimaries)
    float4 a;     // identityMatrix, headroom, pad, pad
};

static inline float srgb_encode(float v) {
    return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}

kernel void s4_display(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant DisplayParams &p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    float3 v = max(c.rgb, 0.0);
    if (p.a.x < 0.5) {
        v = (p.m * float4(v, 0.0)).xyz;
        // After the matrix, not before: `Rec2020 → sRGB` has a −0.5876 coefficient, so this is the
        // first line that can produce a negative — see the header.
        v = max(v, 0.0);
    }
    float headroom = max(p.a.y, 0.0);
    v = min(v, headroom);
    float3 enc = float3(srgb_encode(v.x), srgb_encode(v.y), srgb_encode(v.z));
    dst.write(float4(enc, 1.0), gid);
}
