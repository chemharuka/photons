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
//
// ── 503: the picture's ceiling is applied **here**, at both exits ────────────────────────────────
// 320 put `min(v, ceiling)` at the end of S2. Everything between S2 and this kernel — 对比度,
// 饱和度/自然饱和度, 黑白, 局部色彩, HSL, 点颜色, 分级, 清晰度/细节, 颗粒 — can put a pixel back over
// that ceiling, so 「最高亮度」 was a mid-chain clip rather than the top of the picture: measured on a
// push document, 对比度 +40 alone took the peak from 4.92 to **10.08**, 分级 高光 +40 to **13.73**, and
// even with the tail guards (S3.9/S3.7 clamp at the ceiling themselves) the `Rec.2020 → sRGB` matrix
// lifted a texture that was entirely ≤ 4.92 to **7.46** at the exit. The histogram and the pointer
// row read that number as the top, so the plot and the readout disagreed with the picture.
//
// So the clamp is here, and it is here **twice**: `s4_display` (what the screen shows) and
// `s4_display_linear` (what an HDR export writes) are two exits of one picture, and a preference that
// only holds on screen would export light the user set a limit on.
//
// Position — three constraints, all of them load-bearing:
//   · **after** the matrix, for the reason 075 gives above: the matrix mixes, so a clamp in front of
//     it can be pushed over by the matrix's own arithmetic (measured: 4.92 in, 7.46 out);
//   · **before** `min(v, headroom)` (the panel's ceiling, which must still win when it is lower) and
//     before `srgb_encode` (a clamp on an encoded code is a clamp on a different quantity);
//   · **`p.a.z == 0` means "no extra clamp"** — a caller that predates 503. A real ceiling is
//     `2^0 = 1` at the lowest (`HighlightCeiling.evRange` starts at 0 EV), so 0 is unambiguous.
//
// S2's own clamp stays where it is (503 does not remove it): it is the tone map's shoulder finish and
// it is what makes the identity branch's "≤ ceiling is byte-identical" claim true.

struct DisplayParams {
    float4x4 m;   // working primaries → linear output primaries (column-major, from ColorPrimaries)
    float4 a;     // identityMatrix, headroom, 503 ceiling (linear; 0 = caller predates 503), pad
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
    // 503 — the picture's ceiling, behind the matrix (a saturated value at the ceiling leaves the
    // matrix 1.5× brighter) and in front of the panel's own bound. `0` = caller predates 503.
    float ceiling = p.a.z;
    if (ceiling > 0.0) {
        v = min(v, ceiling);
    }
    float headroom = max(p.a.y, 0.0);
    v = min(v, headroom);
    float3 enc = float3(srgb_encode(v.x), srgb_encode(v.y), srgb_encode(v.z));
    dst.write(float4(enc, 1.0), gid);
}

// S4 — the **linear exit** (100, HDR export). Same primaries matrix as `s4_display`, then the
// picture's ceiling and **nothing else**: no OETF, no `min(v, headroom)`, so extended-range values
// survive into an `rgba16Float` texture.
//
// This exists because a gain map is a ratio between HDR and SDR *linear* light; deriving it from the
// display-encoded texture would (a) lose everything the headroom clamp removed and (b) invert a
// nonlinear transfer twice. It is the same code stream as the screen — one matrix, one read — so an
// export cannot disagree with what S4 would have shown.
//
// 503 — and the ceiling is part of "cannot disagree": `HighlightCeiling` is a **preference** (how much
// light the photograph may keep), not a document field, so it belongs to the picture rather than to
// the screen. Without this line an HDR export would hand the gain-map writer everything the display
// path had just refused to show. Same order as `s4_display`: matrix → ceiling.
kernel void s4_display_linear(texture2d<float, access::read> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant DisplayParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    float3 v = max(c.rgb, 0.0);
    if (p.a.x < 0.5) {
        v = (p.m * float4(v, 0.0)).xyz;
    }
    // The output primaries' cube still has a negative side (`Rec2020 → sRGB`'s −0.5876); a linear
    // export writes light, and negative light is not a value the file format can carry.
    v = max(v, 0.0);
    float ceiling = p.a.z;
    if (ceiling > 0.0) {
        v = min(v, ceiling);
    }
    dst.write(float4(v, 1.0), gid);
}
