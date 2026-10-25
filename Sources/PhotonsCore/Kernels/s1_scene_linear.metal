#include <metal_stdlib>
using namespace metal;

// S1 — scene linear: exposure gain, white-balance gains, highlight recovery.
//
// Exposure is *arithmetic on the decoded buffer*, never a re-decode: v9 costs 5 s at 60 MP while a
// slider needs ~10 ms (docs/tasks/002-editing-graph.md).
//
// Highlight recovery is a soft shoulder: values above knee 0.8 are compressed towards 1.0 with a
// shape controlled by `amount`. amount = 0 is exact identity; amount = 1 asymptotes at 1.0.

struct S1Params {
    float4 a;   // gain, wbR, wbG, wbB
    float4 b;   // recovery, identity, pad, pad
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

    float3 v = c.rgb * p.a.x * p.a.yzw;

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
