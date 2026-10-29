#include <metal_stdlib>
using namespace metal;

// The turn itself is shared with `s1_5_mask_atlas` — see `frame_turn.metal` for why one function and
// not two (派单 080: the atlas kept the normalised rotation one release after S0 dropped it, and the
// mask ended up 273 px off the picture it selected at 7° / 9504×6336).
#include "frame_turn.metal"

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
//
// ── 075: the **exit matrix** (decoded primaries → working primaries) ─────────────────────────────
// The decoder still writes linear **sRGB** (`RAWDecoder`'s `extendedLinearSRGB`, cache key and all),
// and every stage after this one is defined in the graph's working primaries — `ColorPrimaries.working`,
// Rec.2020 since 075. So the conversion is one 3×3 at this stage's exit, applied to every
// photograph-carrying write below. Background writes stay `float4(0)` (the matrix maps 0 to 0, and
// the matte is not a colour).
//
// Two properties the pixels depend on:
//   · **Neutral content is unchanged.** The matrix is a white-point-preserving convex combination
//     (row sums 1, all coefficients ≥ 0), so `r = g = b = v` comes out `(v, v, 0.9999994v)` in
//     float32 — 6e-7, against a Float16 step of 2.4e-4 at 0.18. Same half code, bit for bit.
//   · **The fast paths keep their meaning.** The identity copy and the pure-CA path are fast because
//     they avoid *resampling*; they are not "no arithmetic", and the matrix runs on both (as does the
//     general path). A tl;dr for the next reader: there is no branch here that skips the matrix.
//
// It arrives as a **uniform**, not as nine literals, so the numbers have exactly one source of truth
// (`ColorPrimaries.conversion`), and it is a *separate* buffer rather than a field of `S0Params`.
struct S0Params {
    float4 a;   // canvasSize.xy, contentOrigin.xy
    float4 b;   // contentSize.xy, srcSize.xy
    float4 c;   // crop rect (x, y, w, h) normalized
    float4 d;   // cos, sin, flipH, flipV
    float4 e;   // identity, backgroundOutside, pureCA, pureTurn  (pureTurn: P0-10's fast path)
    float4 f;   // frameSize.xy, frameOrigin.xy (content pixels of the whole frame)
    float4 g;   // caRed, caBlue, quarterTurns, outsideCrop  (029 / P0-10 / 132; 0 = off)
    // 097 — per-channel DNG WarpRectilinear. Columns 0/1/2 are the R/G/B radial coefficients
    // (kr0..kr3); column 3 is the normalized warp centre (x, y). Only `HAS_LENS_WARP` instances read
    // it, so the default entry points never see this field's arithmetic.
    float4x4 lens;
};
// 7 × float4 + float4x4 = 176 bytes. `RenderGraph.swift`'s mirror must stay the same size — a
// mismatch reads the wrong uniform and **does not fail**, which is why `ChromaticAberrationTests`
// asserts 176 on both sides.

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

// The 075 exit matrix, applied to a photograph texel. Alpha rides through untouched: it is the
// matte/coverage channel (`s2_tone_map` reads `c.a == 0` as "no photograph here"), not colour.
// `m` is column-major, as Metal and `simd_float4x4` both are; `RenderGraph` feeds it from
// `ColorPrimaries.conversion(from: .sRGB, to: .working)`, transposed once at the call site.
static inline float4 to_working_primaries(float4 c, constant float4x4 &m) {
    return float4((m * float4(c.rgb, 0.0)).xyz, c.a);
}

// Two entry points, like `s1_scene_linear` (071) and for the same reason — **byte identity on the
// path that does not rotate**. Rotating in pixels (the cropfix) means the mapping is
// `(uv − ½)·frameSize → R(θ) → ÷ frameSize + ½`, and at θ = 0 that round trip is *not* the identity
// in floating point: `(uv − ½)·w / w + ½` lands 1 ulp away from `uv` for most of the canvas, so
// every document that merely crops (`crop ≠ full`, no rotation) resampled one ulp off and every
// recorded pixel hash moved. A branch alone cannot fix that — the `× f` / `÷ f` pair has to be
// absent from the code the non-rotating path runs — so the body is one templated function and the
// two instantiations are dispatched by the CPU: `RenderGraph` asks for `s0_geometry_rot` only when
// `edit.geometry.straightenDegrees != 0` (the angle the cos/sin below come from), and the default
// entry never sees a multiply or a divide by the frame size at all — it maps `o = uv − ½` straight
// back to `o + ½`, the pre-cropfix machine-code shape (and *not* `r = uv`: see the branch below —
// the recorded pixels contain the double rounding that `uv` does not).
//
// ── the rotation, in **pixels** ──────────────────────────────────────────────────────────────────
// Rotating `uv − ½` is a rotation of *normalised* coordinates: the x offset is divided by the
// frame's width and the y offset by its height, so `R(θ)` is followed by the non-uniform scale
// `× frameSize` and the result is rotation ∘ anisotropic scale — a shear whose factor is the
// frame's W/H (so a 3:2 frame shears by 1.5, and a portrait one by 0.667 the other way). Turning
// the pixel offsets instead is the similarity every crop tool means: the two basis vectors stay
// orthogonal and equal (pure rotation + uniform scale), and a straightened picture is only
// turned, never tapered.
// `HAS_TURN` (P0-10) is the 90° document turn. It is a template parameter for the same reason
// `HAS_ROTATION` is: the un-turn is a coordinate permutation with *no* arithmetic of its own, and a
// branch that the compiler cannot fold would still be a branch per pixel in the hot loop. Four
// instantiations, dispatched by `RenderGraph` on `quarterTurns != 0` × `straightenDegrees != 0`.
template <bool HAS_ROTATION, bool HAS_TURN, bool HAS_LENS_WARP>
static inline void s0_body(texture2d<float, access::read> src,
                           texture2d<float, access::write> dst,
                           constant S0Params &p,
                           constant float4x4 &primaries,
                           uint2 gid) {
    int2 canvas = int2(p.a.xy);
    if (int(gid.x) >= canvas.x || int(gid.y) >= canvas.y) { return; }
    int2 srcSize = int2(p.b.zw);

    // Identity: crop is full, no rotation, no flip, canvas == source, whole frame. Copy texel-for-
    // texel so the neutral path stays bit-exact (the determinism and identity tests depend on it).
    // The exit matrix still runs — "identity" is about the *sampling*, not about the colour space —
    // and it is exactly why neutral content stays bit-exact: the matrix maps `(v,v,v)` to itself in
    // Float16 (see the header).
    if (p.e.x > 0.5) {
        dst.write(to_working_primaries(src.read(uint2(clamp(int2(gid), int2(0), srcSize - 1))),
                                       primaries), gid);
        return;
    }

    // ── the pure turn (P0-10): integer in, integer out ───────────────────────────────────────────
    // A document that is *only* turned — full crop, no straighten, no flips, no CA, canvas ==
    // content == the turned source, no window — is a **permutation of the source's texels**, and the
    // general path below would not give a permutation: `uv = framePx / frameSize` followed by
    // `× srcSize` is the same `× f / ÷ f` round trip 073 removed from the rotation (≈1e-3 of a texel
    // at 9504 px, i.e. a genuine blend of neighbours on an operation that has no arithmetic in it),
    // and four of those would not return the same bytes. So the source index is computed in `int`s.
    //
    // `p.e.w` is set by `RenderGraph.plan` for exactly that document (`s0PureTurn`) and by nothing
    // else, so every other frame keeps the general path bit for bit. The four cases are the inverse
    // of a clockwise quarter turn: source (i, j) appears in the turned frame at (H−1−j, i).
    if (HAS_TURN && p.e.w > 0.5) {
        int W = srcSize.x, H = srcSize.y;
        int2 s = int2(gid);
        int turns = int(p.g.z + 0.5);
        if (turns == 1)      { s = int2(gid.y, H - 1 - gid.x); }
        else if (turns == 2) { s = int2(W - 1 - gid.x, H - 1 - gid.y); }
        else if (turns == 3) { s = int2(W - 1 - gid.y, gid.x); }
        dst.write(to_working_primaries(src.read(uint2(clamp(s, int2(0), srcSize - 1))), primaries),
                  gid);
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
        dst.write(to_working_primaries(float4(red.r, green.g, blue.b, green.a), primaries), gid);
        return;
    }

    float2 uv = framePx / max(p.f.xy, float2(1.0));
    if (p.d.z > 0.5) { uv.x = 1.0 - uv.x; }
    if (p.d.w > 0.5) { uv.y = 1.0 - uv.y; }

    // ── the rotation, in **pixels** (see the header) ────────────────────────────────────────────
    // `HAS_ROTATION == false` is a compile-time constant, so the `× frameSize` / `÷ frameSize`
    // round trip is not in the emitted code at all and the mapping is the pre-cropfix one — bit-exact,
    // which is what every cropped-but-not-straightened document depends on. The rotation itself stays
    // a pure pixel-space turn: same body, one instantiation.
    float2 r;
    if (HAS_ROTATION) {
        float2 o = (uv - 0.5) * p.f.xy;
        float cs = p.d.x;
        float sn = p.d.y;
        float2 rotated = frame_turn_pixels(o, cs, sn);
        r = rotated / max(p.f.xy, float2(1.0)) + 0.5;
    } else {
        // NOT `r = uv`: the recorded pixels are not the ones `uv` produces, they are the ones
        // `(uv − ½) + ½` produces — two roundings, not zero. Subtracting ½ rounds for |uv| < ¼ and
        // adding it back does **not** recover the lost bits, so writing `r = uv` here moves every
        // cropped pixel by an ulp just as surely as `× f / ÷ f` did (measured: pillarbox identity
        // 0bd9fadc… instead of the recorded eab59159…). Spelling the `+ ½` as an `fma` keeps it a
        // separate rounding — the compiler's fast-math kernel will happily reassociate `o + ½` back
        // into `uv`, which is exactly the bug — while still keeping the *rotation* out of this
        // instantiation: no `× frameSize`, no `÷ frameSize`, no cos/sin.
        float2 o = uv - 0.5;
        r = fma(o, float2(1.0), float2(0.5));
    }

    // ── the 90° turn, between the straighten and the crop ────────────────────────────────────────
    // Order, and why: `r` above is a position in the **turned** picture (that is the frame the user
    // sees, so the flips and the straighten — applied to `r` — are the ones the user asked for), and
    // `p.c` is the crop measured **in that same turned frame** (schema 9: a crop is a rectangle of
    // the picture, so turning the picture turns the rectangle — `CropMath.turnedClockwise`). The file's
    // pixels are *not* turned, so the position inside the crop is turned back here, and only then
    // mapped through the crop rect into source pixels. Forgetting this step is the classic 90°
    // rotation bug: the box keeps its numbers, the picture turns, and the crop starts selecting a
    // different part of the photograph. `QuarterTurnTests.testCropSelectsTheSamePixelsAfterATurn`
    // pins it, and its second half renders exactly that broken document (the frame turned, the rect
    // not) to show the same assertion going red.
    float2 cropped = p.c.xy + r * p.c.zw;
    if (HAS_TURN) { cropped = frame_unturn_uv(cropped, int(p.g.z + 0.5)); }
    // 123 — rotated past the picture is **background**, not the edge smeared outward. The old
    // clamp-to-edge pulled the border colour into the corners; the honest answer for a pixel whose
    // source position is outside the photograph is transparent. This lives only in the rotating
    // instantiation, so `rotationDegrees == 0` keeps the recorded bytes (the non-rotating path never
    // runs this expression and keeps its clamp-to-edge behaviour for crop/scale).
    //
    // 132 — `p.g.w` is the "this crop deliberately extends past the photograph" flag (0 for every
    // document that predates the task). A crop can now be the output frame and larger than the
    // picture even at 0°, and those pixels must be the same deterministic black, not a smear of the
    // border: the flag adds the branch to the un-rotated instantiation without changing the value
    // the comparison produces for an in-range crop.
    if ((HAS_ROTATION || p.g.w > 0.5) && (cropped.x < 0.0 || cropped.x > 1.0
                                          || cropped.y < 0.0 || cropped.y > 1.0)) {
        dst.write(float4(0.0, 0.0, 0.0, 0.0), gid);
        return;
    }
    float2 px = cropped * float2(srcSize);

    // ── lens plane warp (097) ────────────────────────────────────────────────────────────────────
    // The file's own `OpcodeList3 / WarpRectilinear` planes, applied **per channel** in source pixel
    // space: for each channel c, `p_c = center + (px − center) · s_c(r)`, with
    // `r = |px − center| / halfDiagonal` and `s_c = kr0 + kr1·r + kr2·r² + kr3·r³`.
    //
    // `HAS_LENS_WARP` is a template parameter, so this block is absent from every default entry
    // point (the pre-097 byte-for-byte path). `RenderGraph` picks a `_lens` entry only when the
    // decode profile has three *different* planes, and it also turns off the identity/pure-CA/pure-
    // turn shortcuts for exactly that frame, because those would bypass this sampling.
    //
    // `kt0`/`kt1` (tangential) are not implemented: every file measured on this machine has both at
    // zero. TODO if a file with non-zero tangential terms ever appears.
    //
    // Order with 029: lens warp first, then the manual α scale (`p.g.xy`), so the sliders remain the
    // topmost fine adjustment. With α = 0 this is exactly the per-plane warp.
    if (HAS_LENS_WARP) {
        float2 lensCenter = float2(p.lens.columns[3].x, p.lens.columns[3].y) * float2(srcSize);
        float2 d = px - lensCenter;
        float r = length(d) / max(0.5 * length(float2(srcSize)), 1.0);
        float4 kR = p.lens.columns[0];
        float4 kG = p.lens.columns[1];
        float4 kB = p.lens.columns[2];
        // DNG 1.6 §"WarpRectilinear": `f = kr0 + kr1·r² + kr2·r⁴ + kr3·r⁶` — **even powers**.
        // (Writing it as `kr0 + r·(kr1 + r·(kr2 + r·kr3))` — odd powers — is the easy mistake: it
        // agrees with the spec whenever kr1..kr3 are 0, so a synthetic `kr0`-only test cannot catch it,
        // while on real files (kr1 ≈ −0.0076) it moves the whole picture by ~0.4 % of the radius.
        // Measured against Apple's own warp on L1030433: odd powers leave a 0.4 % radial offset
        // (corr 0.930); even powers match at 1.0000 (corr 0.9908, the remainder being Apple's
        // raw-domain warp vs our post-demosaic one).
        float r2 = r * r;
        float sR = kR.x + r2 * (kR.y + r2 * (kR.z + r2 * kR.w));
        float sG = kG.x + r2 * (kG.y + r2 * (kG.z + r2 * kG.w));
        float sB = kB.x + r2 * (kB.y + r2 * (kB.z + r2 * kB.w));
        float2 pR = lensCenter + d * sR;
        float2 pG = lensCenter + d * sG;
        float2 pB = lensCenter + d * sB;
        if (p.g.x != 0.0) {
            float2 caAxis = float2(srcSize) * 0.5;
            pR = caAxis + (pR - caAxis) * (1.0 + p.g.x);
        }
        if (p.g.y != 0.0) {
            float2 caAxis = float2(srcSize) * 0.5;
            pB = caAxis + (pB - caAxis) * (1.0 + p.g.y);
        }
        float4 red = sample_bilinear(src, pR, srcSize);
        float4 green = sample_bilinear(src, pG, srcSize);
        float4 blue = sample_bilinear(src, pB, srcSize);
        dst.write(to_working_primaries(float4(red.r, green.g, blue.b, green.a), primaries), gid);
        return;
    }

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
        dst.write(to_working_primaries(sample_bilinear(src, px, srcSize), primaries), gid);
        return;
    }
    float4 green = sample_bilinear(src, px, srcSize);
    float2 axis = float2(srcSize) * 0.5;
    float2 d = px - axis;
    float4 red = sample_bilinear(src, axis + d * (1.0 + p.g.x), srcSize);
    float4 blue = sample_bilinear(src, axis + d * (1.0 + p.g.y), srcSize);
    dst.write(to_working_primaries(float4(red.r, green.g, blue.b, green.a), primaries), gid);
}

// The default path — no rotation in the code at all, so the crop/scale/flip mapping is the one 029
// and 048 recorded. `RenderGraph` picks this one unless `straightenDegrees != 0`.
kernel void s0_geometry(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant S0Params &p [[buffer(0)]],
                        constant float4x4 &primaries [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    s0_body<false, false, false>(src, dst, p, primaries, gid);
}

// The same body with the pixel-space turn compiled in. Picked only for a straightened document.
kernel void s0_geometry_rot(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant S0Params &p [[buffer(0)]],
                            constant float4x4 &primaries [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    s0_body<true, false, false>(src, dst, p, primaries, gid);
}

// 2026-10-28 (P0-10): the two 90° entry points. `s0_geometry_turn` is the one a rotate press takes
// (no `× frameSize` / `÷ frameSize` in it, exactly like `s0_geometry`); `s0_geometry_turn_rot` is
// turn + straighten, which is a genuine resample and nothing more.
kernel void s0_geometry_turn(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant S0Params &p [[buffer(0)]],
                             constant float4x4 &primaries [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    s0_body<false, true, false>(src, dst, p, primaries, gid);
}

kernel void s0_geometry_turn_rot(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant S0Params &p [[buffer(0)]],
                                 constant float4x4 &primaries [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    s0_body<true, true, false>(src, dst, p, primaries, gid);
}

// ── 097: the per-plane lens-warp entry points ──────────────────────────────────────────────────
// `RenderGraph` picks these only when `LensProfile.hasPerPlaneDifference` and it has also cleared
// the S0 fast-path flags, so `s0_body` always reaches the general mapping above. The four
// combinations exist for the same reason the four default entries do: the straighten's `× f / ÷ f`
// round trip and the 90° turn's coordinate permutation must stay out of the instances that do not
// need them.
kernel void s0_geometry_lens(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant S0Params &p [[buffer(0)]],
                             constant float4x4 &primaries [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
    s0_body<false, false, true>(src, dst, p, primaries, gid);
}

kernel void s0_geometry_lens_rot(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant S0Params &p [[buffer(0)]],
                                 constant float4x4 &primaries [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    s0_body<true, false, true>(src, dst, p, primaries, gid);
}

kernel void s0_geometry_lens_turn(texture2d<float, access::read> src [[texture(0)]],
                                  texture2d<float, access::write> dst [[texture(1)]],
                                  constant S0Params &p [[buffer(0)]],
                                  constant float4x4 &primaries [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    s0_body<false, true, true>(src, dst, p, primaries, gid);
}

kernel void s0_geometry_lens_turn_rot(texture2d<float, access::read> src [[texture(0)]],
                                      texture2d<float, access::write> dst [[texture(1)]],
                                      constant S0Params &p [[buffer(0)]],
                                      constant float4x4 &primaries [[buffer(1)]],
                                      uint2 gid [[thread_position_in_grid]]) {
    s0_body<true, true, true>(src, dst, p, primaries, gid);
}
