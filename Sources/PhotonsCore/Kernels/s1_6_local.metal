#include <metal_stdlib>
#include "primaries.metal"
#include "tone_shape.metal"
using namespace metal;

// S1.6 — local adjustments, between S1 (scene linear) and S2 (tone map).
//
// Why here (§3.1): local exposure and white balance are *scene-linear* gains. Applied after S2 they
// would multiply data the tone curve had already compressed, and highlights pressed flat by the
// curve could not come back. The predicate is still evaluated upstream in S1.5 so it sees the
// globally exposed frame; this pass only reads, per pixel, the atlas coverage and the mask's own
// slider set.
//
// **派单 079 §2.1.2 — the tone sliders are the global ones now.** Until this change the mask carried
// 019's arithmetic: an affine ±0.15 level for blacks/whites, a linear-light power for contrast, and
// the linear-luma windows `1 − smoothstep(0, 0.5, lum)` / `smoothstep(0.5, 1, lum)` for the two region
// lifts. Three of those four had already been replaced globally (073B/073C moved the end points to EV
// knees, 074 R2 moved the region lifts to EV windows, 0107 replaces the contrast power) — so the same
// `shadows = +100` lifted **the whole masked picture** (70 % of its weight landed on the mid-tones)
// while the global slider of the same name left the median alone. darktable cannot have that bug: a
// module runs one `process()` whether it is masked or not and the mask only decides alpha
// (`blend.c:833-859`).
//
// The fix is not new local numbers — it is that this pass now calls **the same functions** the global
// stages call, in the global order (`tone_shape.metal` is the one body per control):
//
//     S1               exposure · WB gain, then blacks/whites        (s1_end_points, 073B/073C)
//     S2               contrast, then shadows/highlights             (tone_contrast, region_*)
//     S1.6 (this file) the four tone sliders, same order, same bodies, blended by coverage
//
// What that buys, measured (`LocalToneTests`): a mask with `shadows = +100` no longer moves the
// masked picture's median (±1 code, p5 lifts +8…+12 codes); `contrast = +100` puts **0.00 %** of the
// masked samples on the display ceiling instead of 14.4 %; and a mask covering the whole frame with
// one slider at +100 is **bit-identical** to the global slider at +100.
//
// The clamp moved to the exit (item ④ of the派单): the old `max(v, 0)` at the top of this function
// deleted the decoder's sub-black samples before the black end point could reach into them, and the
// `max(v, 1e-6)` inside the power ate them a second time. `local_adjust` is now arithmetic only; the
// single `max(v, 0)` at the write is the same "the clamp stays at the end of the stage" rule S2
// follows.
//
// Pointwise by construction: every stage in this kernel reads exactly the pixel it writes, which is
// what keeps 005d's tile recomputation honest (no halo).
//
// Tiling (005d): `p.a.z/.w` carry the origin of the rectangle being dispatched, so the graph can send
// one thread group per dirty tile instead of the whole canvas. The kernel still addresses pixels in
// *canvas* coordinates, and outside the mask's bounds the coverage is exactly 0, so a tile pass and a
// full-frame pass write the same half-floats — which is the 005d acceptance criterion, checked by
// hashing both frames rather than by looking at them.
//
// Real identity branch (M1-6): if no mask has an active adjustment, or a given mask's adjustments
// are neutral (or `amount == 0`, or its coverage is 0), the source pixel is written unchanged.
// That is what makes "a mask with no adjustments" bit-exact against "no mask at all".
//
// 派单 056: this pass no longer carries **hue or saturation** — they are display-referred operations
// and run in S3.5, from the same `color_hsl.metal` include S3 uses. A mask whose only sliders are
// hue/saturation is therefore *inactive here* (its `enabled` flag is 0), which is what keeps it
// bit-exact against no mask rather than shipping it through neutral arithmetic.

struct LocalParams {
    int4 a;   // anyActive, maskCount, originX, originY (canvas pixels)
};

struct LocalAdjustDesc {
    float4 a;   // gainR, gainG, gainB, amountScale (0…1, already includes adjustments.amount)
    float4 b;   // contrast, highlights, shadows, whites
    // blacks, contrast travel (EV of bend at |contrast| = 100 — `S2Contrast.travel`'s derivation, the
    // axis' own end points), pad, enabled. The travel rides a uniform rather than a kernel constant
    // for the same reason S2 takes it from the CPU: the axis may move (an HDR white), and then both
    // stages follow instead of the mask silently changing meaning.
    float4 c;
};

static inline float3 local_adjust(float3 v, LocalAdjustDesc d) {
    // ① Scene-linear gains: exposure and the Planckian white-balance approximation. First, as in S1,
    //    and **without** a clamp: the decoder's sub-black samples are picture (S2's header measures
    //    0.039 below zero with 23× more structure than noise), and the old `max(v, 0)` here deleted
    //    them before any end point could reach into that band.
    v = v * d.a.xyz;

    // ② blacks/whites — S1's end points, the *same* function (073B/073C). `kHybrid = true` because a
    //    mask has no per-mask instantiation to spend; the level term's `m` is exactly 0 for
    //    `|blacks| ≤ 50`, so this agrees with S1's 073B entry bit for bit in that whole range. Signs
    //    are the global ones (派单 008 A): `blacks +` opens the shadows, `whites +` moves the white
    //    point up. The old affine ±0.15 level here is gone: it changed the *slope* of the whole masked
    //    picture, so `blacks +100` moved a 50 % grey by +25 codes instead of leaving it alone.
    v = s1_end_points<true>(v, d.c.x, d.b.w);

    // ③ contrast — S2's seam (`tone_shape.metal#tone_contrast`). A displacement in EV with a held band
    //    around the measured median and a shoulder that lands on display white, so it cannot clip:
    //    the masked highlights used to go white at `+100` (14.4 % of a frame on the ceiling).
    v = tone_contrast(v, d.b.x, d.c.y);

    // ④ shadows/highlights — S2's EV windows, both weights from the same `region_weights`. Two EV wide
    //    each, placed under the measured percentiles, so a mask's `shadows +100` lifts the p5 and
    //    leaves the median where it was — which is what the *global* slider of that name has done
    //    since 074 R2 and what "the same slider means the same thing" has to mean.
    v *= region_gain(region_weights(v), d.b.z, d.b.y);

    // ⑤ Nothing else. Hue and saturation are **not here** any more (派单 056): they are
    //    display-referred and run in S3.5 from the same include S3 uses; a rotation of linear RGB
    //    about its luma is not the same picture as a rotation in the display-referred domain, and only
    //    one of the two can agree with the global sliders.
    return v;
}

kernel void s1_6_local(texture2d<float, access::read> src [[texture(0)]],
                       texture2d_array<float, access::read> atlas [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]],
                       constant LocalParams &p [[buffer(0)]],
                       constant LocalAdjustDesc *adjust [[buffer(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    // Canvas coordinates: a tiled dispatch offsets the grid instead of moving the texture.
    uint2 px = uint2(gid.x + uint(p.a.z), gid.y + uint(p.a.w));
    if (px.x >= src.get_width() || px.y >= src.get_height()) { return; }

    float4 c = src.read(px);
    if (p.a.x == 0) {
        dst.write(c, px);
        return;
    }

    float3 v = c.rgb;
    for (uint i = 0; i < uint(max(p.a.y, 0)); ++i) {
        LocalAdjustDesc d = adjust[i];
        if (d.c.w < 0.5) { continue; }                  // neutral adjustments: skip entirely
        float a = atlas.read(px, i).r;                  // opacity · combine · invert, from S1.5
        // `acc · amount`: the atlas already carries the mask-level opacity, `d.a.w` carries the
        // adjustment's amount (0…1). Zero weight returns before `local_adjust`, so a mask with
        // amount 0 is bit-identical to no mask even if a slider would have produced a NaN (§3.3).
        float w = clamp(a * d.a.w, 0.0, 1.0);
        if (w <= 0.0) { continue; }
        v = mix(v, local_adjust(v, d), w);
    }
    // The one clamp, at the exit — S2's rule, and now this stage's too: a sub-black value that the
    // end points pulled above zero is real picture by now and has to survive; whatever is still below
    // zero is what the display would clip anyway.
    dst.write(float4(max(v, 0.0), c.a), px);
}
