#include <metal_stdlib>
using namespace metal;

// S3c — post-crop vignette (Lightroom's Effects panel).
//
// Shape blends between a square falloff and a radial one via `roundness`; `midpoint` moves where
// darkening starts; `feather` sets how soft the transition is. Amount < 0 darkens the corners,
// > 0 lightens them. Distances are measured in **frame** space, never in window space: a vignette is
// a property of the photograph, so a 1:1 window must see exactly the falloff the whole frame has at
// the same physical place — and the letterbox padding must not be vignetted at all.
//
// `p.b.xy` is the frame's size, `p.b.zw` the window's origin, both in content pixels
// (`RenderOptions.outputWindow`); `p.c.yz` is the content rect's origin inside the canvas. Without a
// window the three numbers reduce to the content rect, which is what this pass used before windows
// existed.

struct VignetteParams {
    float4 a;   // amount, midpoint, feather, roundness
    float4 b;   // frameSize.xy, frameOrigin.xy (content pixels of the whole frame)
    float4 c;   // identity, contentOrigin.x, contentOrigin.y, pad
};

kernel void s3_vignette(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant VignetteParams &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.c.x > 0.5) {
        dst.write(c, gid);
        return;
    }

    // Canvas pixel → position inside the whole frame, then the guard in `uv` — byte for byte the
    // test this pass has always made, so the whole-frame path keeps its recorded pixels.
    float2 size = max(p.b.xy, float2(1.0));
    float2 uv = (float2(gid) + 0.5 - p.c.yz + p.b.zw) / size;
    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        dst.write(c, gid);
        return;
    }

    float2 d = (uv - 0.5) * 2.0;
    float roundness = clamp(0.5 + p.a.w / 100.0 * 0.5, 0.0, 1.0);
    float dist = mix(max(abs(d.x), abs(d.y)), length(d), roundness);

    float midpoint = clamp(p.a.y / 100.0, 0.0, 1.0);
    float feather = clamp(p.a.z / 100.0, 0.02, 1.0);
    float inner = mix(0.25, 1.05, midpoint);
    float t = smoothstep(inner - feather * 0.5, inner + feather * 0.5, dist);

    float gain = clamp(1.0 + p.a.x / 100.0 * t, 0.0, 4.0);
    dst.write(float4(max(c.rgb * gain, 0.0), c.a), gid);
}
