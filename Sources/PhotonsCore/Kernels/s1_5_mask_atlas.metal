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
// not evaluate yet) are covered as 0 rather than guessed.
//
// Coordinates: the document stores shapes in *uncropped source* space, normalised to [0,1], so the
// kernel first walks S0's mapping backwards (canvas → content → crop → rotate → source) and then
// measures distances in source pixels divided by min(W, H). That division is what makes one set of
// parameters produce the same shape at thumbnail, fit, 1:1 and export scale.
//
// Math of the two gradient shapes:
//   linear  t = dot(p − a, d) / dot(d, d), t' = t^(log ½ / log m)  (m = midpoint, ½ ⇒ identity)
//           alpha = smoothstep(½ − f/2, ½ + f/2, t')               (§4.2)
//   radial  q = R(−angle)·(p − centre) / radius, r = |q|
//           alpha = 1 − smoothstep(1 − f, 1, r)                    (§4.3)
// `smoothstep` is the Hermite cubic of GLSL/Metal, public mathematics; nothing here is copied from
// ART/RapidRAW/darktable (GPL-3.0 / AGPL-3.0, read-only per §7).
//
// Not implemented in this pass, deliberately and visibly (005b scope):
//   · Mask-level `feather` (a spatial blur of the combined selection) and `refine` (guided filter)
//     are neighbourhood operators; they need 005d's TileDependency declaration before they can be
//     added without silently breaking tile-based recomputation. Both are already in the atlas key.
//   · brush / colour-range / luminance-range / semantic shapes evaluate to 0 coverage.

struct MaskAtlasParams {
    float4 a;   // canvasSize.xy, contentOrigin.xy
    float4 b;   // contentSize.xy, sourceSize.xy
    float4 c;   // crop rect (x, y, w, h) normalised
    float4 d;   // cos, sin, flipH, flipV
    int4   e;   // maskCount, pad, pad, pad
};

struct MaskDesc {
    int4   meta;   // firstComponent, componentCount, invert, pad
    float4 misc;   // opacity, pad, pad, pad
};

struct MaskShapeDesc {
    int4   meta;   // kind (0 linear, 1 radial, −1 not evaluated by this pass), componentInvert, op, pad
    float4 p0;     // linear: start.xy, end.xy   |  radial: centre.xy, radius.xy
    float4 p1;     // linear: midpoint, feather   |  radial: cos, sin, feather
};

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

kernel void s1_5_mask_atlas(texture2d<float, access::read> src [[texture(0)]],
                            texture2d_array<float, access::write> atlas [[texture(1)]],
                            constant MaskAtlasParams &p [[buffer(0)]],
                            constant MaskDesc *masks [[buffer(1)]],
                            constant MaskShapeDesc *shapes [[buffer(2)]],
                            uint2 gid [[thread_position_in_grid]]) {
    int2 canvas = int2(p.a.xy);
    if (int(gid.x) >= canvas.x || int(gid.y) >= canvas.y) { return; }

    uint count = uint(max(p.e.x, 0));
    float2 srcSize = max(p.b.zw, float2(1.0));
    float minSide = min(srcSize.x, srcSize.y);
    float2 uv = source_uv(float2(gid), p);
    bool outside = uv.x < 0.0;
    float2 ppx = outside ? float2(0.0) : uv * srcSize;

    for (uint s = 0; s < count; ++s) {
        MaskDesc m = masks[s];
        float a = 0.0;
        if (!outside) {
            float acc = 0.0;
            for (int i = 0; i < m.meta.y; ++i) {
                MaskShapeDesc d = shapes[m.meta.x + i];
                float v = 0.0;
                if (d.meta.x == 0) {
                    v = linear_alpha(ppx, d, srcSize);
                } else if (d.meta.x == 1) {
                    v = radial_alpha(ppx, d, srcSize, minSide);
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
