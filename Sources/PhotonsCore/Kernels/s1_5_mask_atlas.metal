#include <metal_stdlib>
using namespace metal;

// The frame's turn, shared with `s0_geometry` (派单 080) — see `frame_turn.metal`.
#include "frame_turn.metal"

// S1.5 — mask atlas: one slice per enabled mask, R16F, at canvas resolution.
//
// This is the single predicate domain of the graph: a mask is evaluated once, in the frame the
// *editing* stage sees (after S1's global exposure and white balance), and every consumer — S1.6
// here, the `showMask` overlay — reads the same numbers.
// Evaluating the predicate inside S1/S2/S3 instead would mean three copies of it and three
// different selections.
//
// **147 — the selection is exposure-independent.** The picture predicates (colour range, luminance
// range) take their sample from S1, i.e. after the global exposure gain `g = 2^EV`; a naive read made
// the same `luminanceRange 0.55…1.0` select 17 % of the frame at E 0 and 55 % at E +2 (IoU 0.196).
// The sample is now divided by `g` (params `g.x`) before OKLab, so both predicates see the decoder's
// light. Nothing else in this file moved: the coordinate walk, the shapes, the feather and the
// combination order are untouched; `g == 1` is an exact division by one.
//
// Slice contents: `opacity · combine(components) · mask invert`, alpha in 0…1. Component invert is
// applied per component before combining; masks without components (or with shapes this build does
// not evaluate) are covered as 0 rather than guessed.
//
// Coordinates: the document stores shapes in *uncropped source* space, normalised to [0,1], so the
// kernel first walks S0's mapping backwards (canvas → content → crop → rotate → source) and then
// measures distances in source pixels divided by min(W, H). That division is what makes one set of
// parameters produce the same shape at thumbnail, fit, 1:1 and export scale.
//
// The turn in that walk is the same one S0 applies, in the same space — **frame pixels**, never
// `uv − ½` (派单 080, `frame_turn.metal`). Until 080 this file rotated normalised coordinates while
// S0 rotated pixels, which is `rotation ∘ anisotropic scale`: a 7° straighten on a 9504×6336 frame
// slid the mask 273 px off the pixels it selects. Kept as two instantiations for the same reason S0
// has two entry points: the `× frameSize` / `÷ frameSize` round trip is *not* the identity at θ = 0
// in floating point, so the angle-zero atlas would have moved by an ulp and every recorded digest
// with it. `<HAS_ROTATION>` false compiles the multiply and the divide out entirely.
//
// Shape maths (all public mathematics; nothing here is copied from ART/RapidTherapee/darktable
// (GPL-3.0) or RapidRAW (AGPL-3.0), which §7 keeps read-only):
//   linear  t = dot(p − a, d) / dot(d, d), t' = t^(log ½ / log m)  (m = midpoint, ½ ⇒ identity)
//           alpha = 1 outside the half-plane t' ≥ ½, squared falloff over `f·0.1·shortEdge` px
//                   before it: `clamp(1 − (d/w)²)²`                    (079 A4, was §4.2)
//   radial  q = R(−angle)·(p − centre) / radius, r = |q|
//           alpha = 1 for r ≤ 1; `clamp((r_out² − r²)/(r_out² − 1))²` for 1 < r < r_out,
//                   r_out = 1 + `f·0.1·shortEdge` / min(rx, ry)         (079 A4, was §4.3)
//   brush   alpha = 1 − smoothstep(r(1−f), r, distToSegment(p, a, b))   (§4.1)
//           one stroke = a capsule chain, `max` inside the chain (a joint is a union, not a
//           double exposure); across strokes paint = `src + dst·(1−src)`, erase = `dst·(1−src)`.
//   colour  d = min_i ‖OKLab(p) − OKLab(sample_i)‖ in the metric space of OKLabMetric
//           alpha = 1 − smoothstep(tol, tol + smooth·(0.5 − tol), d)   (§4.4)
//   luma    L = OKLab L of p (unclamped; 167 extends the axis to cbrt(16) = +4 EV)
//           alpha = smoothstep(lo − loF, lo + loF, L) · (1 − smoothstep(hi − hiF, hi + hiF, L))
//                                                                   (§4.5)
//   depth   d = depthTexture.sample(uv).r, 0 = farthest, 1 = nearest (120b; the texture is the
//               min-max normalised disparity, so no second normalisation lives here)
//           alpha = the SAME two-sided window as luma, applied to d. `near`/`far` are repaired into
//               lo/hi on the host by `DepthRangeShape.ordered`; `invert` flips this shape only, and
//               `hasDepth == 0` yields 0 rather than "everything selected".
//
// 079 A4 — **feather lives outside the shape.** Until A4 both gradients spent `feather` *inside*
// their shape (`1 − smoothstep(1−f, 1, r)`, `smoothstep(½−f/2, ½+f/2, t')`), so `feather = 0.5`
// meant "the fully covered region is half the radius". darktable's drawn masks do the opposite
// (`masks/ellipse.c:1502-1534`, comment: "ratio = 0.0 at the outer border, >= 1.0 within the
// ellipse"): the shape stays solid to its rim, the feather is a **quadratic** falloff outside it.
// This is that rule, with `feather` read as a percentage of the **short edge** — the same unit as
// the mask-level `featherPixels` — instead of a percentage of the shape. `feather = 0` keeps the
// pre-A4 expression verbatim (both branches are still in the two functions), because a document
// with no feather must not move a single byte.
//
// Since 005d the atlas is a two-part stage: this kernel writes the *pointwise* coverage
// (`opacity · combine · invert`), then `s1_7_mask_neighbourhood.metal` applies the two
// neighbourhood operators — mask-level `feather` (separable box blur, edge-clamped) and `refine`
// (guided filter steered by S1's luma). Both are declared as `TileDependency.neighborhood(r + g)`
// in `Masks.swift`, which is what makes the stage's dirty rectangle provably wide enough.
//
// Still not evaluated here: shapes this build cannot interpret (kind −1) contribute 0. Since 005e
// a `semantic` shape is evaluated from a raster the OS produced (`MaskSemantics.swift`): the graph
// uploads the resolved mattes as a `texture2d_array` and this kernel samples it bilinearly at the
// source `uv`, then applies `softEdge`. No raster ⇒ the component is kind −1 and covers 0 — the
// contract of §5.1 ("zero coverage with a recorded reason, never a guess").

struct MaskAtlasParams {
    float4 a;   // canvasSize.xy, contentOrigin.xy
    float4 b;   // contentSize.xy, sourceSize.xy
    float4 c;   // crop rect (x, y, w, h) normalised
    float4 d;   // cos, sin, flipH, flipV
    int4   e;   // maskCount, quarterTurns (P0-10), pad, pad
    float4 f;   // frameSize.xy, frameOrigin.xy (content pixels of the whole frame)
    // 147 — S1's exposure gain `g = 2^EV` (x), 3 pad. The two picture predicates (kind 3/4) read the
    // sample **divided by g**, so a mask selects the same scene tones at every exposure; the geometry
    // and the neighbourhood operators never touch this number. `g == 1` is an exact division by 1.
    float4 g;
    // 120b — `x` = 1 when a depth texture is bound. A depth mask with no map contributes **0**, not
    // "the whole frame": a missing measurement is not an empty selection.
    float4 h;
};

struct MaskDesc {
    // `meta.w` is 1 when any component of this mask reads the picture (kind 3/4), i.e. when the
    // kernel has to fetch S1's texel at all. It is a *slice* flag rather than a per-shape one
    // because the fetch is per pixel, not per shape.
    int4   meta;   // firstComponent, componentCount, invert, needsPicture
    float4 misc;   // opacity, featherRadiusPx (005d), refine strength, guidedRadiusPx (005d)
    // 081 — the canvas box (half-open `x0, y0, x1, y1`) this slice can be non-zero in: the mask's
    // own extent grown by `featherRadius + guidedRadius` and clamped to the canvas, or the whole
    // canvas when the extent cannot be bounded (inverted masks, colour/luminance/semantic
    // components — see `MaskBounds.rasterRect`). Every component is exactly 0 outside it, so the
    // coverage there *is* 0 and needs no evaluation. The slice is still **written** everywhere: the
    // atlas texture is reused across rebuilds, and a stale texel outside the new box would be a
    // previous frame's selection leaking into this one.
    int4   rect;
};

// kind: 0 linear, 1 radial, 2 brush, 3 colour range, 4 luminance range, 5 semantic matte,
//       6 depth range, −1 not evaluated here.
struct MaskShapeDesc {
    int4   meta;   // kind, componentInvert, op, pad
    float4 p0;     // linear: start.xy, end.xy   |  radial: centre.xy, radius.xy
                   // brush: firstStroke, strokeCount |  colour: firstSample, count, tol, smooth
                   // luma/depth: low, high, lowFeather, highFeather
                   // semantic: rasterSlice, pad, pad, pad
    float4 p1;     // linear: midpoint, feather   |  radial: cos, sin, feather
                   // depth: feather, shapeInvert, pad, pad
                   // semantic: softEdge, feather, pad, pad
};

/// Bilinear like the matte's own resolution: the model runs at ≤ 1024 long edge (§5.2) and this is
/// the upsample, so `filter::linear` is the cheapest correct answer and `clamp_to_edge` keeps a
/// matte that does not quite reach the frame border from darkening it.
constexpr sampler kSemanticSampler(coord::normalized, filter::linear, address::clamp_to_edge);

/// 120b — the depth map is a low-resolution measurement (the model runs at 518 × 392) sampled at the
/// **source** uv, exactly like the semantic matte: bilinear + clamp is the correct upsample and the
/// same coordinate every other shape is measured in.
constexpr sampler kDepthSampler(coord::normalized, filter::linear, address::clamp_to_edge);

struct MaskStrokeDesc {
    int4   meta;   // pointFirst, pointCount, closed, pad
    float4 misc;   // radius (short edge), feather, flow, erase
    float4 bmin;   // bbox min in normalised source (already grown by the radius)
    float4 bmax;   // bbox max
};

// OKLab `a`/`b` are normalised by their natural half-span so one tolerance number means the same
// thing on every axis (mirror of `OKLabMetric.chromaSpan`).
constant float kChromaInverseSpan = 1.0 / 0.4;

/// Inverse of `s0_geometry`: canvas pixel → normalised **uncropped source** position.
/// Returns x < 0 outside the content rect (letterbox padding), where every mask is 0.
///
/// Frame-relative, like S0 (`p.f.xy` = frame size, `p.f.zw` = window origin, in content pixels): a
/// mask's coefficients are properties of the photograph, so evaluating this against the visible
/// window instead of the frame would slide the selection by the window's pan — and would make a 1:1
/// render disagree with the fit render about where a gradient sits.
///
/// `<HAS_ROTATION>` is S0's split, for S0's reason: the rotating instantiation turns **pixels**
/// (`frame_turn_pixels`, the one shared definition), the other has no `× frameSize` / `÷ frameSize`
/// in it at all, so a document at `straighten == 0` maps `uv − ½` straight back and its atlas is
/// bit-identical to the one every recorded digest was taken from.
template <bool HAS_ROTATION>
static inline float2 source_uv(float2 pixel, constant MaskAtlasParams &p) {
    float2 local = pixel + 0.5 - p.a.zw;
    float2 content = p.b.xy;
    if (local.x < 0.0 || local.y < 0.0 || local.x >= content.x || local.y >= content.y) {
        return float2(-1.0, -1.0);
    }
    float2 framePx = local + p.f.zw;
    float2 uv = framePx / max(p.f.xy, float2(1.0));
    if (p.d.z > 0.5) { uv.x = 1.0 - uv.x; }
    if (p.d.w > 0.5) { uv.y = 1.0 - uv.y; }

    float cs = p.d.x;
    float sn = p.d.y;
    float2 r;
    if (HAS_ROTATION) {
        // The turn, in **frame pixels** — `R(θ)` applied to `uv − ½` is `rot ∘ aniso(frameSize)`, a
        // shear, and that is the 273 px the mask used to miss by. Same expression as S0's, from the
        // same header, so the picture and the selection cannot be turned by different maths.
        float2 o = (uv - 0.5) * max(p.f.xy, float2(1.0));
        float2 rotated = frame_turn_pixels(o, cs, sn);
        r = rotated / max(p.f.xy, float2(1.0)) + 0.5;
    } else {
        // No rotation is compiled into this instantiation. At θ = 0 `R(θ)·o` is `o` exactly, so this
        // is `o + ½` — the shape the recorded atlases contain, kept spelled as a turn so that the two
        // instantiations differ in exactly one thing (where the anisotropy sits) and nothing else.
        float2 o = uv - 0.5;
        r = float2(o.x * cs - o.y * sn, o.x * sn + o.y * cs) + 0.5;
    }
    // 2026-10-28 (P0-10): the document's 90° turn, in the same place and the same shape as S0's
    // (`s0_geometry.metal`): the crop rect `p.c` is measured in the **turned** frame, so the
    // position inside it is turned back before it names a source position. Runtime branch, not a
    // third instantiation: the coordinate permutation adds no arithmetic of its own, so `turns == 0`
    // is bit-identical to the atlas every recorded digest was taken from. `p.e.y` is the document's
    // `quarterTurns` — the same number, written by the same `RenderGraph.plan`.
    float2 cropped = p.c.xy + r * p.c.zw;
    int turns = p.e.y;
    if (turns != 0) { cropped = frame_unturn_uv(cropped, turns); }
    return cropped;
}

static inline float linear_alpha(float2 p, MaskShapeDesc d, float2 srcSize) {
    float2 a = d.p0.xy * srcSize;
    float2 b = d.p0.zw * srcSize;
    float2 dir = b - a;
    float t = clamp(dot(p - a, dir) / max(dot(dir, dir), 1e-12), 0.0, 1.0);

    // Midpoint remap. m = 0.5 is the identity, and the guard keeps a 0.5 that is only *nearly*
    // 0.5 from turning into a pow with a near-infinite exponent.
    float m = clamp(d.p1.x, 0.02, 0.98);
    float tp = t;
    if (abs(m - 0.5) > 1e-6 && t > 0.0) {
        tp = pow(t, log(0.5) / log(m));
    }

    float f = clamp(d.p1.y, 0.0, 1.0);
    // 079 A4's "short-edge percentage spent outside the rim" is the **radial** rule (darktable's
    // `masks/ellipse.c:1502-1534`); 079 A4 applied it to the open shapes too and that broke the linear
    // gradient — one-sided, a tenth as wide, and no longer through the midpoint. Restored here to the
    // pre-A4 (e3a011d^) contract: `f` is the fraction of the **whole span**, centred on `t' = ½`.
    float lo = 0.5 - 0.5 * f;
    float hi = max(0.5 + 0.5 * f, lo + 1e-5);
    if (f <= 0.0) {
        // f == 0 (or a zero-length gradient, which has no span to ramp over): the pre-079 arithmetic,
        // verbatim. Every document that carries `feather = 0` must stay **bit-identical** — the
        // recorded atlases and every digest taken from them were produced by this expression.
        return smoothstep(lo, hi, tp);
    }

    // Symmetric ramp: alpha = 0 at `lo`, 0.5 exactly at the half-way line `t' = ½`, 1 at `hi`.
    return smoothstep(lo, hi, tp);
}

static inline float radial_alpha(float2 p, MaskShapeDesc d, float2 srcSize, float minSide) {
    float2 centre = d.p0.xy * srcSize;
    // Radii are short-edge units, so rx == ry is a circle in *pixels*, not in normalised space.
    float2 rad = max(abs(d.p0.zw) * minSide, float2(1e-4));

    // q = R(−angle)·(p − centre) / radius (§4.3). Positive angle therefore turns the ellipse
    // clockwise on screen, because y points down in image space.
    float2 dv = p - centre;
    float cs = d.p1.x;
    float sn = d.p1.y;
    float2 q = float2(dv.x * cs + dv.y * sn, -dv.x * sn + dv.y * cs) / rad;
    float r = length(q);

    float f = clamp(d.p1.z, 0.0, 1.0);
    // 079 A4 — `1 − smoothstep(1 − f, 1, r)` ate the inside of the shape: at f = ½ the fully covered
    // region was half the radius. darktable's ellipse instead keeps `r ≤ 1` at exactly 1 and spends
    // the feather **outside** the rim (`ellipse.c:1502-1534`: `ratio = (r_out² − r²)/(r_out² − r_in²)`,
    // clipped, then squared), so a feather never shrinks the shape's own solid area.
    float featherPx = f * 0.1 * minSide;              // short-edge percentage, as in `linear_alpha`
    if (featherPx <= 0.0) {
        // f == 0: the pre-079 arithmetic, verbatim, for bit-identical documents (see `linear_alpha`).
        return 1.0 - smoothstep(1.0 - f, 1.0, r);
    }
    // The same radius in **ellipse-radius units**: the outer rim is `r_out = 1 + g`, i.e. the ellipse
    // scaled by `1 + g` about its centre. `min(rad)` (not the radius along the ray) keeps the offset
    // in pixels at the short axis exact and at least `featherPx` everywhere else.
    float g = featherPx / min(rad.x, rad.y);
    float rOut = 1.0 + g;
    float ratio = clamp((rOut * rOut - r * r) / (rOut * rOut - 1.0), 0.0, 1.0);
    return ratio * ratio;
}

/// §4.1 — distance from `p` to the segment `a…b`, turned into coverage by the same smoothstep the
/// gradients use. The radius is interpolated along the segment so pressure can taper a stroke.
static inline float segment_alpha(float2 p, float2 a, float2 b, float ra, float rb, float feather) {
    float2 ab = b - a;
    float len2 = dot(ab, ab);
    float t = len2 > 1e-12 ? clamp(dot(p - a, ab) / len2, 0.0, 1.0) : 0.0;
    float2 closest = a + ab * t;
    float r = mix(ra, rb, t);
    float core = r * (1.0 - feather);
    // Feather = 0 gives core == r and a 1e-6 ramp, i.e. a hard edge exactly at the radius.
    return 1.0 - smoothstep(core, max(r, core + 1e-6), length(p - closest));
}

/// One stroke: capsule chain with `max` accumulation, scaled by `flow`.
static inline float stroke_alpha(float2 ppx, float2 uv, MaskStrokeDesc s,
                                 constant float4 *points, float2 srcSize, float minSide) {
    // Cheap reject first: most pixels of a full-frame brush lie outside every stroke's box, and a
    // 300-point stroke is 299 distance evaluations per pixel without this.
    if (uv.x < s.bmin.x || uv.y < s.bmin.y || uv.x > s.bmax.x || uv.y > s.bmax.y) { return 0.0; }

    int n = s.meta.y;
    if (n <= 0) { return 0.0; }
    int first = s.meta.x;
    bool closed = s.meta.z != 0;
    float feather = clamp(s.misc.y, 0.0, 0.999);
    float baseR = max(s.misc.x, 0.0) * minSide;

    if (n == 1) {
        float4 q = points[first];
        float r = max(baseR * clamp(q.z, 0.02, 1.0), 0.5);
        return (1.0 - smoothstep(r * (1.0 - feather), max(r, r * (1.0 - feather) + 1e-6),
                                 length(ppx - q.xy * srcSize)))
               * clamp(s.misc.z, 0.0, 1.0);
    }

    int segments = closed ? n : n - 1;
    float acc = 0.0;
    for (int i = 0; i < segments; ++i) {
        float4 pa = points[first + i];
        float4 pb = points[first + ((i + 1) % n)];
        float ra = max(baseR * clamp(pa.z, 0.02, 1.0), 0.5);
        float rb = max(baseR * clamp(pb.z, 0.02, 1.0), 0.5);
        // `max` is a union: the joint between two segments must not double-expose (§4.1).
        acc = max(acc, segment_alpha(ppx, pa.xy * srcSize, pb.xy * srcSize, ra, rb, feather));
    }
    return acc * clamp(s.misc.z, 0.0, 1.0);
}

static inline float brush_alpha(float2 ppx, float2 uv, MaskShapeDesc d,
                                constant MaskStrokeDesc *strokes, constant float4 *points,
                                float2 srcSize, float minSide) {
    int first = int(d.p0.x);
    int count = int(d.p0.y);
    float acc = 0.0;
    for (int i = 0; i < count; ++i) {
        MaskStrokeDesc s = strokes[first + i];
        float v = stroke_alpha(ppx, uv, s, points, srcSize, minSide);
        if (s.misc.w > 0.5) {
            acc = acc * (1.0 - v);          // erase: dst·(1 − src)
        } else {
            acc = v + acc * (1.0 - v);      // paint: src + dst·(1 − src)
        }
    }
    return clamp(acc, 0.0, 1.0);
}

/// Ottosson's OKLab from **linear working primaries** — the same formulas as `OKLabMetric` on the
/// host (a test compares the two implementations, so the two cannot drift silently).
///
/// 075 §2.2: the fold is `M1 · toXYZ(Rec.2020)` with its rows normalised to 1 (white must fold to
/// `L = 1, a = b = 0`), not Ottosson's published *sRGB* matrix. The host derives it from
/// `ColorPrimaries.working`; the nine literals below are that product to 10 digits
/// (verified in `MaskTests`, whose fixed coverages are what a correct fold produces for known sRGB
/// colours — a stale fold moves them, which is exactly how this line was found).
static inline float3 oklab(float3 linearRGB) {
    float3 rgb = max(linearRGB, 0.0);
    float l = dot(rgb, float3(0.6167557877, 0.3601984026, 0.0230458097));
    float m = dot(rgb, float3(0.2651330603, 0.6358393719, 0.0990275679));
    float s = dot(rgb, float3(0.1001026312, 0.2039065206, 0.6959908482));
    // Metal's standard library has no `cbrt`; the exponent form is within a few ULP over [0, 1],
    // i.e. far below the 1/255 the masks are read at.
    float3 lms = pow(max(float3(l, m, s), 0.0), float3(1.0 / 3.0));
    float L = dot(lms, float3(0.2104542553, 0.7936177850, -0.0040720468));
    float A = dot(lms, float3(1.9779984951, -2.4285922050, 0.4505937099));
    float B = dot(lms, float3(0.0259040371, 0.7827717662, -0.8086757660));
    return float3(L, A * kChromaInverseSpan, B * kChromaInverseSpan);
}

static inline float colour_range_alpha(float3 linearRGB, MaskShapeDesc d,
                                       constant float4 *colours) {
    int first = int(d.p0.x);
    int count = int(d.p0.y);
    if (count <= 0) { return 0.0; }
    float3 lab = oklab(linearRGB);

    float best = 1e9;
    for (int i = 0; i < count; ++i) {
        best = min(best, length(lab - colours[first + i].xyz));
    }

    float tol = max(d.p0.z, 0.0);
    float smooth = clamp(d.p0.w, 0.0, 1.0);
    // §4.4: alpha = 1 − smoothstep(tol, tol + smooth·(0.5 − tol), d). The guard keeps the upper
    // edge above the lower one when tolerance is already past the half point.
    float upper = max(tol + smooth * max(0.5 - tol, 0.0), tol + 1e-4);
    return 1.0 - smoothstep(tol, upper, best);
}

/// The two-sided window, shared by the luminance (kind 4) and depth (kind 6) predicates. One
/// expression, so the two cannot grow different boundary rules: the host repairs an inverted pair
/// with `RangeOrdering`/`DepthRangeShape.ordered` before it reaches `p0`.
static inline float two_sided_window(float x, MaskShapeDesc d) {
    float lo = d.p0.x, hi = d.p0.y;
    float loF = max(d.p0.z, 0.0), hiF = max(d.p0.w, 0.0);
    float inLow = smoothstep(lo - loF, max(lo + loF, lo - loF + 1e-5), x);
    float inHigh = 1.0 - smoothstep(hi - hiF, max(hi + hiF, hi - hiF + 1e-5), x);
    return clamp(inLow * inHigh, 0.0, 1.0);
}

static inline float luminance_range_alpha(float3 linearRGB, MaskShapeDesc d) {
    // 167 — **the whole HDR axis**, `0…cbrt(16)` (host: `LuminanceRangeShape.hdrMax`). Until 167
    // this folded `clamp(linearRGB, 0, 1)`, so every pixel at or above display white arrived as
    // `L = 1.0` and `high` above 1 selected nothing: the window had no resolution in the HDR half.
    // The unclamped fold extends the same OKLab axis to +4 EV; negative light is clamped inside
    // `oklab` exactly as before, so the dark side is unchanged. Depth (kind 6) still calls
    // `two_sided_window` on its own normalised `0…1` sample — do not extend that one.
    float L = oklab(linearRGB).x;
    return two_sided_window(L, d);
}

/// 120b — the depth mask. `uv` is the same **source** coordinate the luma/colour predicates read
/// (the mapping from canvas pixel is `source_uv`, shared with every other shape), and the texture is
/// the normalised disparity (`0` far … `1` near). A missing texture is zero coverage, never "all".
static inline float depth_range_alpha(float2 uv, MaskShapeDesc d,
                                      texture2d<float, access::sample> depth, bool hasDepth) {
    if (!hasDepth) { return 0.0; }
    float z = clamp(depth.sample(kDepthSampler, uv).r, 0.0, 1.0);
    float a = two_sided_window(z, d);
    if (d.p1.y > 0.5) { a = 1.0 - a; }
    return a;
}

/// §5 — a raster the OS produced, sampled in **source** uv (the same coordinates every other shape
/// is measured in), then re-edged by `softEdge`: `smoothstep(½ − s/2, ½ + s/2, raw)`. Mirrors
/// `SemanticRaster.coverage` exactly, so the analytic reference in the tests is the same formula.
static inline float semantic_alpha(float2 uv, MaskShapeDesc d,
                                   texture2d_array<float, access::sample> mattes) {
    int slice = int(d.p0.x);
    if (slice < 0 || slice >= int(mattes.get_array_size())) { return 0.0; }
    float raw = clamp(mattes.sample(kSemanticSampler, uv, uint(slice)).r, 0.0, 1.0);
    float s = clamp(d.p1.x, 0.0, 1.0);
    float lo = 0.5 - 0.5 * s;
    float hi = max(0.5 + 0.5 * s, lo + 1e-5);
    return smoothstep(lo, hi, raw);
}

template <bool HAS_ROTATION>
static inline void atlas_body(texture2d<float, access::read> src,
                              texture2d_array<float, access::write> atlas,
                              texture2d_array<float, access::sample> mattes,
                              texture2d<float, access::sample> depth,
                              constant MaskAtlasParams &p,
                              constant MaskDesc *masks,
                              constant MaskShapeDesc *shapes,
                              constant MaskStrokeDesc *strokes,
                              constant float4 *points,
                              constant float4 *colours,
                              uint2 gid) {
    int2 canvas = int2(p.a.xy);
    if (int(gid.x) >= canvas.x || int(gid.y) >= canvas.y) { return; }

    uint count = uint(max(p.e.x, 0));
    float2 srcSize = max(p.b.zw, float2(1.0));
    float minSide = min(srcSize.x, srcSize.y);
    int2 px = int2(gid);
    // 081 — the geometry walk (S0's mapping backwards, one rotate, two divides) is only needed by a
    // pixel that lies inside *some* slice's box; everything else writes +0.0 without ever knowing
    // where in the source it would have been.
    bool anyInside = false;
    for (uint s = 0; s < count; ++s) {
        int4 r = masks[s].rect;
        if (px.x >= r.x && px.y >= r.y && px.x < r.z && px.y < r.w) { anyInside = true; break; }
    }
    float2 uv = float2(-1.0);
    bool outside = true;
    float2 ppx = float2(0.0);
    if (anyInside) {
        uv = source_uv<HAS_ROTATION>(float2(gid), p);
        outside = uv.x < 0.0;
        ppx = outside ? float2(0.0) : uv * srcSize;
    }

    for (uint s = 0; s < count; ++s) {
        MaskDesc m = masks[s];
        // 081 — evaluate only inside this mask's own box. Outside it every component is exactly 0
        // (the box is the shape's support grown by both neighbourhood radii), so the coverage the
        // old code computed there was `clamp(0 · opacity)` = +0.0, which is what gets written.
        bool inside = !outside
            && int(gid.x) >= m.rect.x && int(gid.y) >= m.rect.y
            && int(gid.x) <  m.rect.z && int(gid.y) <  m.rect.w;
        float a = 0.0;
        if (inside) {
            // Predicates that read the picture (colour range, luminance range) see the S1 output: the
            // frame the editing stage will see, not the decoder's. Only fetched when some component
            // of *this* mask looks at it; before 081 every pixel of every mask paid for an rgba16f
            // read that a geometry-only mask never used. **147** — the sample is divided by S1's
            // exposure gain before the predicate looks at it, so the selection is a fact about the
            // scene and not about the EV slider (the audit measured IoU 0.196 on one mask at E 0 vs
            // E +2). Dividing by 1.0 at E 0 is exact, so recorded atlases keep their bytes.
            float3 linearRGB = m.meta.w != 0
                ? src.read(gid).rgb / max(p.g.x, 1e-6)
                : float3(0.0);
            float acc = 0.0;
            for (int i = 0; i < m.meta.y; ++i) {
                MaskShapeDesc d = shapes[m.meta.x + i];
                float v = 0.0;
                switch (d.meta.x) {
                case 0: v = linear_alpha(ppx, d, srcSize); break;
                case 1: v = radial_alpha(ppx, d, srcSize, minSide); break;
                case 2: v = brush_alpha(ppx, uv, d, strokes, points, srcSize, minSide); break;
                case 3: v = colour_range_alpha(linearRGB, d, colours); break;
                case 4: v = luminance_range_alpha(linearRGB, d); break;
                case 5: v = semantic_alpha(uv, d, mattes); break;
                case 6: v = depth_range_alpha(uv, d, depth, p.h.x > 0.5); break;
                default: v = 0.0; break;   // unknown kind: no coverage, never a guess
                }
                if (d.meta.y != 0) { v = 1.0 - v; }

                if (i == 0) {
                    acc = v;                       // the first component's op is ignored
                } else if (d.meta.z == 1) {
                    acc = acc * (1.0 - v);         // subtract
                } else if (d.meta.z == 2) {
                    acc = acc * v;                 // intersect
                } else {
                    acc = max(acc, v);             // add: union, no double-exposure at joints
                }
            }
            if (m.meta.z != 0) { acc = 1.0 - acc; }
            a = clamp(acc * m.misc.x, 0.0, 1.0);
        }
        atlas.write(float4(a, a, a, 1.0), gid, s);
    }
}

// No rotation in the emitted code at all — the path every `straighten == 0` document takes, and the
// one every recorded atlas digest was taken from.
kernel void s1_5_mask_atlas(texture2d<float, access::read> src [[texture(0)]],
                            texture2d_array<float, access::write> atlas [[texture(1)]],
                            texture2d_array<float, access::sample> mattes [[texture(2)]],
                            texture2d<float, access::sample> depth [[texture(3)]],
                            constant MaskAtlasParams &p [[buffer(0)]],
                            constant MaskDesc *masks [[buffer(1)]],
                            constant MaskShapeDesc *shapes [[buffer(2)]],
                            constant MaskStrokeDesc *strokes [[buffer(3)]],
                            constant float4 *points [[buffer(4)]],
                            constant float4 *colours [[buffer(5)]],
                            uint2 gid [[thread_position_in_grid]]) {
    atlas_body<false>(src, atlas, mattes, depth, p, masks, shapes, strokes, points, colours, gid);
}

// The same body with the pixel-space turn compiled in. `RenderGraph` picks this one only when the
// document's straighten angle is non-zero — the same condition S0 uses for `s0_geometry_rot`, from
// the same field, so the picture and the selection are always turned together.
kernel void s1_5_mask_atlas_rot(texture2d<float, access::read> src [[texture(0)]],
                                texture2d_array<float, access::write> atlas [[texture(1)]],
                                texture2d_array<float, access::sample> mattes [[texture(2)]],
                                texture2d<float, access::sample> depth [[texture(3)]],
                                constant MaskAtlasParams &p [[buffer(0)]],
                                constant MaskDesc *masks [[buffer(1)]],
                                constant MaskShapeDesc *shapes [[buffer(2)]],
                                constant MaskStrokeDesc *strokes [[buffer(3)]],
                                constant float4 *points [[buffer(4)]],
                                constant float4 *colours [[buffer(5)]],
                                uint2 gid [[thread_position_in_grid]]) {
    atlas_body<true>(src, atlas, mattes, depth, p, masks, shapes, strokes, points, colours, gid);
}
