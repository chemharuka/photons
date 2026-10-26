#include <metal_stdlib>
using namespace metal;

// S1 — scene linear: black/white levels, exposure gain, white-balance gains, highlight recovery.
//
// Order (派单 019):
//   ① black/white **levels**:  v = (v − blk) / max(wht − blk, 1e−3)   affine, sign-preserving
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
// slider needs ~10 ms (docs/tasks/002-editing-graph.md).
//
// Highlight recovery is a soft shoulder: values above knee 0.8 are compressed towards 1.0 with a
// shape controlled by `amount`. amount = 0 is exact identity; amount = 1 asymptotes at 1.0.
//
// **The matte is not a shadow here either** (派单 008 B, moved from S2 by 019). S1 dispatches the whole
// canvas and S0 writes 0 into everything outside the picture, so a lifted black point maps that 0 to
// `(0 − blk)/(wht − blk) > 0` and the letterbox would turn grey. The two guards that used to protect
// the bars in S2 are therefore duplicated here, unchanged and in the same order: alpha 0 says "there
// is no photograph at this pixel" (S0's background), and the content rect is the canvas guard for a
// window whose rect covers the canvas. They are exact write-throughs, not epsilons, so a test can
// assert the bars are exactly 0 (`MatteIsNotPartOfThePictureTests`, `ToneMapTests`).

struct S1Params {
    float4 a;   // gain, wbR, wbG, wbB
    float4 b;   // recovery, identity, blacks, whites
    float4 c;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

kernel void s1_scene_linear(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant S1Params &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
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
    float blk = -p.b.z / 100.0 * 0.15;
    float wht = 1.0 - p.b.w / 100.0 * 0.15;
    float3 v = (c.rgb - blk) / max(wht - blk, 1e-3);

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
