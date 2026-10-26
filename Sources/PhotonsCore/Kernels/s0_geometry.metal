#include <metal_stdlib>
using namespace metal;

// S0 — geometry: crop, straighten, flips, then the output window.
//
// Output is the *canvas*: the content rect sits inside it (letterboxed when the requested canvas
// aspect differs, which is exactly what an on-screen viewport does), and everything outside the
// content rect is transparent. Export passes canvas == content, so no padding is produced.
//
// Two-phase, in the order the user thinks in (docs D5): the **whole frame** is cropped, rotated and
// flipped, and only then is the requested **window** taken out of it. `p.f.xy` is the frame's size and
// `p.f.zw` the window's origin, both in content pixels (`RenderOptions.outputWindow`). A window is
// therefore literally the whole-frame picture with a rectangle cut out of it — same projection, same
// texel phase — instead of a second crop that would rotate about a different centre. With no window
// (`p.f.zw == 0`, `p.f.xy == content`) the mapping collapses to the content-normalized one S0 has
// always used, so the neutral/identity path stays bit-exact.
//
// Sampling is bilinear with clamp-to-edge. Because the crop rect stays the output frame, over-
// rotating a crop pulls edge samples rather than growing the canvas — the honest M1 behaviour;
// "zoom to fill after straighten" needs the crop UI that is a non-goal for this task.
//
// The one exception is a **canvas-space window** (`p.e.y`): the loupe's camera is allowed to leave the
// photograph, and the part of the canvas that misses it must be background. There the sample is
// rejected before it is taken — `float4(0)`, not the edge texel smeared outward, which is what
// clamp-to-edge would give and what a photograph's edge does *not* look like. In-bounds windows never
// reach that branch, so every pre-existing pixel is bit-identical.
//
// Lateral CA (029) rides in the same pass: green is the reference and is sampled exactly as before,
// red and blue are sampled at a radius scaled by `1 + α` about the source centre (`p.g`, `p.e.z`).
// No second stage, no second texture — the three samples are of the same pixel, which is the whole
// reason this belongs here rather than after S1.
struct S0Params {
    float4 a;   // canvasSize.xy, contentOrigin.xy
    float4 b;   // contentSize.xy, srcSize.xy
    float4 c;   // crop rect (x, y, w, h) normalized
    float4 d;   // cos, sin, flipH, flipV
    float4 e;   // identity, backgroundOutside, pureCA, pad
    float4 f;   // frameSize.xy, frameOrigin.xy (content pixels of the whole frame)
    float4 g;   // caRed, caBlue, pad, pad  (029; dimensionless radial ratios, 0 = off)
};
// 7 × float4 = 112 bytes. `RenderGraph.swift`'s mirror must stay the same size — a mismatch reads
// the wrong uniform and **does not fail**, which is why `ChromaticAberrationTests` asserts 112 on
// both sides.

static inline float4 sample_bilinear(texture2d<float, access::read> src,
                                     float2 px,
                                     int2 srcSize) {
    float2 p = px - 0.5;
    float2 f = floor(p);
    float2 t = p - f;
    int2 i0 = int2(f);
    int2 i1 = i0 + 1;
    int2 lo = int2(0);
    int2 hi = srcSize - 1;
    float4 v00 = src.read(uint2(clamp(i0, lo, hi)));
    float4 v10 = src.read(uint2(clamp(int2(i1.x, i0.y), lo, hi)));
    float4 v01 = src.read(uint2(clamp(int2(i0.x, i1.y), lo, hi)));
    float4 v11 = src.read(uint2(clamp(i1, lo, hi)));
    return mix(mix(v00, v10, t.x), mix(v01, v11, t.x), t.y);
}

kernel void s0_geometry(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant S0Params &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int2 canvas = int2(p.a.xy);
    if (int(gid.x) >= canvas.x || int(gid.y) >= canvas.y) { return; }
    int2 srcSize = int2(p.b.zw);

    // Identity: crop is full, no rotation, no flip, canvas == source, whole frame. Copy texel-for-
    // texel so the neutral path stays bit-exact (the determinism and identity tests depend on it).
    if (p.e.x > 0.5) {
        dst.write(src.read(uint2(clamp(int2(gid), int2(0), srcSize - 1))), gid);
        return;
    }

    float2 local = float2(gid) + 0.5 - p.a.zw;
    float2 content = p.b.xy;
    if (local.x < 0.0 || local.y < 0.0 || local.x >= content.x || local.y >= content.y) {
        dst.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }

    // Content pixel → position inside the whole frame (flips and rotation happen in *frame* space, so
    // a window at the frame's edge mirrors the same way the whole frame does).
    float2 framePx = local + p.f.zw;
    // A canvas-space window may reach past the frame: that part is background, not the frame's edge
    // stretched outward. Off for every window that stays inside the frame, so the in-bounds path keeps
    // the clamp-to-edge behaviour documented at the top of this file.
    if (p.e.y > 0.5 && (framePx.x < 0.0 || framePx.y < 0.0
                        || framePx.x >= p.f.x || framePx.y >= p.f.y)) {
        dst.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }
    // ── lateral CA (029), pure-CA fast path ─────────────────────────────────────────────────────
    // Crop full, nothing rotated or flipped, no window, canvas == content == frame == source, and
    // α ≠ 0 — the common case ("just fix the corners"). Then `framePx` *is* the source pixel centre,
    // so hand it to the sampler directly instead of going through the uv round trip below, whose
    // `(i + 0.5)/n·n` can lose an ulp at 9504 px and would move green by ~1e-4 relative. Green is
    // read as a texel (**not** resampled), so this frame's green channel is byte-identical to the
    // identity copy above; only red and blue are resampled.
    if (p.e.z > 0.5) {
        float2 axis = float2(srcSize) * 0.5;
        float2 d = framePx - axis;
        float4 green = src.read(uint2(gid));
        float4 red = sample_bilinear(src, axis + d * (1.0 + p.g.x), srcSize);
        float4 blue = sample_bilinear(src, axis + d * (1.0 + p.g.y), srcSize);
        dst.write(float4(red.r, green.g, blue.b, green.a), gid);
        return;
    }

    float2 uv = framePx / max(p.f.xy, float2(1.0));
    if (p.d.z > 0.5) { uv.x = 1.0 - uv.x; }
    if (p.d.w > 0.5) { uv.y = 1.0 - uv.y; }

    float2 o = uv - 0.5;
    float cs = p.d.x;
    float sn = p.d.y;
    float2 r = float2(o.x * cs - o.y * sn, o.x * sn + o.y * cs) + 0.5;

    float2 px = (p.c.xy + r * p.c.zw) * float2(srcSize);

    // ── lateral CA (029): one pass, three samples ───────────────────────────────────────────────
    // Green is the reference and never moves. Red and blue are taken at
    // `axis + (px − axis)·(1 + α)`, where `axis` is the **source** centre: lateral CA is a property
    // of the lens's optical axis, so a crop or a rotation must not move the point that is aberration-
    // free. `α` itself is dimensionless (a fraction of the radius), which is what lets a 400 px
    // preview and a 9504 px export correct the same picture.
    //
    // This is path C — CA on top of a crop/rotation/flip/scale. It samples the *same* `px` the
    // pre-029 kernel sampled, so green is bit-identical to the CA-off frame and only red and blue
    // come from a scaled radius. With both α at zero it is exactly the old single sample: that branch
    // is cold for every document that has never touched the sliders.
    if (p.g.x == 0.0 && p.g.y == 0.0) {
        dst.write(sample_bilinear(src, px, srcSize), gid);
        return;
    }
    float4 green = sample_bilinear(src, px, srcSize);
    float2 axis = float2(srcSize) * 0.5;
    float2 d = px - axis;
    float4 red = sample_bilinear(src, axis + d * (1.0 + p.g.x), srcSize);
    float4 blue = sample_bilinear(src, axis + d * (1.0 + p.g.y), srcSize);
    dst.write(float4(red.r, green.g, blue.b, green.a), gid);
}
