#include <metal_stdlib>
using namespace metal;

// S1.5 — mask atlas: one slice per enabled mask, R16F, at canvas resolution.
//
// This is the single predicate domain of the graph (docs/tasks/005-masks.md §3.1): a mask is
// evaluated once, in the frame the *editing* stage sees (after S1's global exposure and white
// balance), and every consumer — S1.6 here, `showMask` in 005e — reads the same numbers.
// Evaluating the predicate inside S1/S2/S3 instead would mean three copies of it and three
// different selections.
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
// Shape maths (all public mathematics; nothing here is copied from ART/RapidTherapee/darktable
// (GPL-3.0) or RapidRAW (AGPL-3.0), which §7 keeps read-only):
//   linear  t = dot(p − a, d) / dot(d, d), t' = t^(log ½ / log m)  (m = midpoint, ½ ⇒ identity)
//           alpha = smoothstep(½ − f/2, ½ + f/2, t')               (§4.2)
//   radial  q = R(−angle)·(p − centre) / radius, r = |q|
//           alpha = 1 − smoothstep(1 − f, 1, r)                    (§4.3)
//   brush   alpha = 1 − smoothstep(r(1−f), r, distToSegment(p, a, b))   (§4.1)
//           one stroke = a capsule chain, `max` inside the chain (a joint is a union, not a
//           double exposure); across strokes paint = `src + dst·(1−src)`, erase = `dst·(1−src)`.
//   colour  d = min_i ‖OKLab(p) − OKLab(sample_i)‖ in the metric space of OKLabMetric
//           alpha = 1 − smoothstep(tol, tol + smooth·(0.5 − tol), d)   (§4.4)
//   luma    L = OKLab L of clamp(p, 0, 1)
//           alpha = smoothstep(lo − loF, lo + loF, L) · (1 − smoothstep(hi − hiF, hi + hiF, L))
//                                                                   (§4.5)
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
    int4   e;   // maskCount, pad, pad, pad
};

struct MaskDesc {
    int4   meta;   // firstComponent, componentCount, invert, pad
    float4 misc;   // opacity, featherRadiusPx (005d), refine strength, guidedRadiusPx (005d)
};

// kind: 0 linear, 1 radial, 2 brush, 3 colour range, 4 luminance range, 5 semantic matte,
//       −1 not evaluated here.
struct MaskShapeDesc {
    int4   meta;   // kind, componentInvert, op, pad
    float4 p0;     // linear: start.xy, end.xy   |  radial: centre.xy, radius.xy
                   // brush: firstStroke, strokeCount |  colour: firstSample, count, tol, smooth
                   // luma: low, high, lowFeather, highFeather
                   // semantic: rasterSlice, pad, pad, pad
    float4 p1;     // linear: midpoint, feather   |  radial: cos, sin, feather
                   // semantic: softEdge, feather, pad, pad
};

/// Bilinear like the matte's own resolution: the model runs at ≤ 1024 long edge (§5.2) and this is
/// the upsample, so `filter::linear` is the cheapest correct answer and `clamp_to_edge` keeps a
/// matte that does not quite reach the frame border from darkening it.
constexpr sampler kSemanticSampler(coord::normalized, filter::linear, address::clamp_to_edge);

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
static inline float2 source_uv(float2 pixel, constant MaskAtlasParams &p) {
    float2 local = pixel + 0.5 - p.a.zw;
    float2 content = p.b.xy;
    if (local.x < 0.0 || local.y < 0.0 || local.x >= content.x || local.y >= content.y) {
        return float2(-1.0, -1.0);
    }
    float2 uv = local / content;
    if (p.d.z > 0.5) { uv.x = 1.0 - uv.x; }
    if (p.d.w > 0.5) { uv.y = 1.0 - uv.y; }

    float2 o = uv - 0.5;
    float cs = p.d.x;
    float sn = p.d.y;
    float2 r = float2(o.x * cs - o.y * sn, o.x * sn + o.y * cs) + 0.5;
    return p.c.xy + r * p.c.zw;
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

    // Feather narrows the transition window around t' = 0.5; 1 = the full ramp, 0 = a hard edge.
    float f = clamp(d.p1.y, 0.0, 1.0);
    float lo = 0.5 - 0.5 * f;
    float hi = max(0.5 + 0.5 * f, lo + 1e-5);
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

    float f = clamp(d.p1.z, 0.0, 0.999);
    return 1.0 - smoothstep(1.0 - f, 1.0, length(q));
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

/// Ottosson's OKLab from linear sRGB — the same formulas as `OKLabMetric` on the host (a test
/// compares the two implementations, so the two cannot drift silently).
static inline float3 oklab(float3 linearRGB) {
    float3 rgb = max(linearRGB, 0.0);
    float l = dot(rgb, float3(0.4122214708, 0.5363325363, 0.0514459929));
    float m = dot(rgb, float3(0.2119034982, 0.6806995451, 0.1073969566));
    float s = dot(rgb, float3(0.0883024619, 0.2817188376, 0.6299787005));
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

static inline float luminance_range_alpha(float3 linearRGB, MaskShapeDesc d) {
    // Headroom above 1 is "digital white" and participates as 1, otherwise a highlight's value
    // would jump with the decode tier (§4.5).
    float L = oklab(clamp(linearRGB, 0.0, 1.0)).x;
    float lo = d.p0.x, hi = d.p0.y;
    float loF = max(d.p0.z, 0.0), hiF = max(d.p0.w, 0.0);
    float inLow = smoothstep(lo - loF, max(lo + loF, lo - loF + 1e-5), L);
    float inHigh = 1.0 - smoothstep(hi - hiF, max(hi + hiF, hi - hiF + 1e-5), L);
    return clamp(inLow * inHigh, 0.0, 1.0);
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

kernel void s1_5_mask_atlas(texture2d<float, access::read> src [[texture(0)]],
                            texture2d_array<float, access::write> atlas [[texture(1)]],
                            texture2d_array<float, access::sample> mattes [[texture(2)]],
                            constant MaskAtlasParams &p [[buffer(0)]],
                            constant MaskDesc *masks [[buffer(1)]],
                            constant MaskShapeDesc *shapes [[buffer(2)]],
                            constant MaskStrokeDesc *strokes [[buffer(3)]],
                            constant float4 *points [[buffer(4)]],
                            constant float4 *colours [[buffer(5)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int2 canvas = int2(p.a.xy);
    if (int(gid.x) >= canvas.x || int(gid.y) >= canvas.y) { return; }

    uint count = uint(max(p.e.x, 0));
    float2 srcSize = max(p.b.zw, float2(1.0));
    float minSide = min(srcSize.x, srcSize.y);
    float2 uv = source_uv(float2(gid), p);
    bool outside = uv.x < 0.0;
    float2 ppx = outside ? float2(0.0) : uv * srcSize;
    // Predicates that read the picture (colour range, luminance range) see the S1 output: the
    // frame the editing stage will see, not the decoder's.
    float3 linearRGB = outside ? float3(0.0) : src.read(gid).rgb;

    for (uint s = 0; s < count; ++s) {
        MaskDesc m = masks[s];
        float a = 0.0;
        if (!outside) {
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
