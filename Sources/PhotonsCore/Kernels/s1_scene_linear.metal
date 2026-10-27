#include <metal_stdlib>
using namespace metal;

// S1 — scene linear: black/white levels, the linear black offset, exposure gain, white-balance
// gains, highlight recovery.
//
// Order (派单 019, plus 071's offset between ① and ②):
//   ① black/white **levels**:  v = (v − blk) / max(wht − blk, 1e−3)   affine, sign-preserving
//   ①b linear black **offset** (071): v = v + blackOffset              additive, in linear units
//   ② exposure gain + WB gains: v *= gain · wb                       multiplicative
//   ③ highlight recovery:      the soft shoulder, unchanged
//
// **Why the levels come first.** The decoder hands us scene-linear samples that go below zero
// (measured on _1274394.dng: min −0.039, 33 M negative samples), and exposure is a *multiplicative*
// gain: −0.01 at +1.6 EV is −0.03. With the black point applied **after** the gain (which is where it
// used to live, in S2) the lift is an absolute `|blk|` against a value that grew with the gain, so
// raising exposure pushed detail that `blacks +` had lifted back under zero, and S2's final clamp
// deleted it: the more exposure, the blacker the shadows — detail lost, not darkened.
//
// Normalising before the gain means the gain acts on "brightness relative to the black point", so a
// pixel's side of the black point does not depend on exposure at all, and `blacks +` keeps what it
// lifted under any exposure (measured: 0 / +1 / +2 EV all stay positive, `BwLevelsTests`).
//
// The slider mapping is unchanged — `blk = −blacks/100·0.15`, `wht = 1 − whites/100·0.15` — and the
// remap is affine, so it is defined on negative input and needs no clamp of its own. Levels answer
// "where are 0 and 1"; the curve (S3) answers "how does the range bend between them".
//
// Exposure is *arithmetic on the decoded buffer*, never a re-decode: v9 costs 5 s at 60 MP while a
// slider needs ~10 ms. Exposure is a gain on the buffer, never a second development.
//
// **071 — the linear black offset.** `blackOffset` is an *additive* fine trim in scene-linear units
// (±0.01, 1/1000 granularity), and it sits between the levels and the gain on purpose:
//
//     v = (v − blk)/span;   v += blackOffset;   v *= gain
//
// The complaint it answers is "more exposure makes the shadows blacker", whose cause is negative
// samples (min −0.039 on `_1274394.dng`) being multiplied by the gain and then deleted by S2's
// `max(v, 0)`. With the trim *before* the gain the correction is scaled by the same gain the damage
// is scaled by: `+0.01` at +2 EV lifts `+0.04`, exactly proportional. After the gain it would be a
// constant `+0.01` — too little in a +3 EV push, too much at −2 EV.
//
// **Two entry points, on purpose.** The obvious spelling — one kernel with `if (boff != 0.0) v += boff`
// — does *not* keep the default path byte-identical: measured on the `edit-push` document (blk 0.018,
// wht 0.988, shoulder 0.35), merely having that branch inside the function moved 2980 of 12309
// scene-linear samples by an ULP, because the extra addend changes how the compiler reassociates the
// level division (with `blk = 0 / wht = 1`, a unit span, the same edit measures 0 differences — which
// is exactly how that bug hides from a synthetic test). So the body lives in one templated function
// and the **default** path is instantiated without the offset — `s1_body<false>` — where the addition
// is not in the code at all, rather than "in the code but skipped". The UI is an integer slider
// −10…+10 → `slider/1000`.
//
// Which entry point runs is decided on the CPU by the same condition as the key material: `RenderGraph`
// asks for `s1_scene_linear_trim` only when `light.blackOffset != 0`.
//
// Highlight recovery is a soft shoulder: values above knee 0.8 are compressed towards 1.0 with a
// shape controlled by `amount`. amount = 0 is exact identity; amount = 1 asymptotes at 1.0.
//
// **The matte is not a shadow here either** (派单 008 B, moved from S2 by 019). S1 dispatches the whole
// canvas and S0 writes 0 into everything outside the picture, so a lifted black point maps that 0 to
// `(0 − blk)/(wht − blk) > 0` and the letterbox would turn grey. 071's offset does exactly the same
// thing (`0 + blackOffset`), so it too lives after these guards. The two guards that used to protect
// the bars in S2 are therefore duplicated here, unchanged and in the same order: alpha 0 says "there
// is no photograph at this pixel" (S0's background), and the content rect is the canvas guard for a
// window whose rect covers the canvas. They are exact write-throughs, not epsilons, so a test can
// assert the bars are exactly 0 (`MatteIsNotPartOfThePictureTests`, `ToneMapTests`).

struct S1Params {
    float4 a;   // gain, wbR, wbG, wbB
    float4 b;   // recovery, identity, blacks, whites
    float4 c;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
    // 派单 030 — the absolute levels: blackLevel, whiteLevel, hasBlack, hasWhite.
    //
    // `blackLevel`/`whiteLevel` are the same two numbers the `blacks`/`whites` sliders produce, said
    // in scene-linear units instead of slider travel. That matters for white: the slider can reach
    // `wht = 1.15`, and a +1 EV highlight needs `wht = 2.0`. Only one spelling is ever in force —
    // the flags say which, and both are 0 for every document that never used a dropper, so the
    // slider arithmetic below runs unchanged (and bit-identically) for those.
    float4 d;
    // 派单 071 — the linear black offset in scene-linear units (x), 3 pad. Read only by the `kTrim`
    // instantiation; `s1_scene_linear` never looks at it.
    float4 e;
};

// One body, two instantiations. `kTrim` is a compile-time constant, so the `kTrim == false`
// instantiation contains no offset arithmetic at all (see the header note: the `if (boff != 0.0)`
// spelling moved real pixels of the push document).
template <bool kTrim>
static inline void s1_body(texture2d<float, access::read> src,
                           texture2d<float, access::write> dst,
                           constant S1Params &p,
                           uint2 gid) {
    float4 c = src.read(gid);
    if (p.b.y > 0.5) {
        dst.write(c, gid);
        return;
    }

    // Alpha 0 is the only thing that says "there is no photograph here", so it is checked before any
    // pixel maths — the same rule and the same order S2 has always had.
    if (c.a == 0.0) {
        dst.write(c, gid);
        return;
    }

    // Outside the content rect: the matte, written back unchanged (S0 leaves it at 0).
    float2 g = float2(gid);
    if (g.x < p.c.x || g.y < p.c.y || g.x >= p.c.x + p.c.z || g.y >= p.c.y + p.c.w) {
        dst.write(c, gid);
        return;
    }

    // ① Linear black/white levels. A positive `blacks` lowers the input black point (lifting the
    //    shadows), a positive `whites` pulls the white point in (brightening, clipping sooner) — the
    //    Lightroom direction, unchanged from 派单 008 A.
    //
    //    030: an absolute level, when the document has one, is the same number in scene-linear units
    //    and wins over its slider. The slider arithmetic stays *inside* this branch rather than being
    //    pre-computed on the CPU, so a document with no absolute levels computes `blk`/`wht` with the
    //    exact float32 operations it always did — that is what keeps 019's pixels identical.
    float blk = p.d.z > 0.5 ? p.d.x : (-p.b.z / 100.0 * 0.15);
    float wht = p.d.w > 0.5 ? p.d.y : (1.0 - p.b.w / 100.0 * 0.15);
    float3 v = (c.rgb - blk) / max(wht - blk, 1e-3);

    // ①b 071 — the additive linear trim, **before** the gain so it is scaled by the same gain the
    //    negative samples are (see the header). Compiled out of the default instantiation: a document
    //    with `blackOffset == 0` is never dispatched to this entry point at all.
    if (kTrim) {
        v += float3(p.e.x);
    }

    // ② The gain acts on the levelled value: (v − blk)·gain, sign preserved by construction. The WB
    //    gains are literally (1, 1, 1) since white balance became a decode setting (派单 006) — the old
    //    Planckian fit here would be a second correction on top of the decoder's.
    v *= p.a.x * p.a.yzw;

    // ③ The shoulder, untouched.
    float amount = clamp(p.b.x, 0.0, 1.0);
    if (amount > 0.0) {
        const float knee = 0.8;
        float3 below = min(v, float3(knee));
        float3 t = max(v - knee, 0.0) / (1.0 - knee);
        float3 shoulder = knee + (1.0 - knee) * ((1.0 - amount) * t + amount * (1.0 - exp(-t)));
        v = below + shoulder - knee;
    }

    dst.write(float4(v, c.a), gid);
}

// The default path: 019's arithmetic, byte for byte. `blackOffset == 0` is the only condition under
// which `RenderGraph` picks this one.
kernel void s1_scene_linear(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant S1Params &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    s1_body<false>(src, dst, p, gid);
}

// 071: the same body with the offset in it. Picked only when the document's trim is non-zero.
kernel void s1_scene_linear_trim(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant S1Params &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    s1_body<true>(src, dst, p, gid);
}
