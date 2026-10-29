#include <metal_stdlib>
using namespace metal;

// S3c — post-crop vignette (Lightroom's Effects panel).
//
// The contour is **always circular**: a lens is rotationally symmetric, so the light falloff it
// causes is too. There is no roundness control (134, user 2026-10-29) — darktable approximates the
// shape through the aspect ratio and RawTherapee has radius/strength/centre only. Radius is
// normalised by **half the diagonal**: `norm = 0.5·hypot(size.x, size.y)` and `dRad = |px| / norm`,
// so the image corner is *always* `1.0` whatever the aspect ratio. That is the same
// half-diagonal convention darktable uses for its vignetting knots and lensfun's pa model
// (`local/src/redlamp/docs/research/darktable/notes/E-lenses-and-geometry.md:110,227`).
//
// `midpoint` is where the falloff's 50 % point sits on that scale: 0 starts at the centre (the whole
// frame darkens), 100 puts it at the corner. This replaces the old short-edge-half-normalised scale
// (082/084), whose `inner ∈ 0.25…1.05` could never reach a 3:2 frame's corner at 1.803.
// `feather` sets how soft the transition is. Amount < 0 darkens the corners, > 0 lightens them.
// Distances are measured in **frame** space, never in window space: a vignette is a property of the
// photograph, so a 1:1 window must see exactly the falloff the whole frame has at the same physical
// place — and the letterbox padding must not be vignetted at all.
//
// `p.b.xy` is the frame's size, `p.b.zw` the window's origin, both in content pixels
// (`RenderOptions.outputWindow`); `p.c.yz` is the content rect's origin inside the canvas. Without a
// window the three numbers reduce to the content rect, which is what this pass used before windows
// existed.

struct VignetteParams {
    float4 a;   // amount, midpoint, feather, pad
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

    // One metric: **pixels over half the diagonal**. Corner = 1.0 at every aspect ratio; the old
    // metric divided by half the short edge (so a 3:2 corner was 1.803) and mixed in the square
    // max-norm, which is what made the contour an ellipse.
    float2 px = (uv - 0.5) * size;
    float norm = max(0.5 * length(size), 1.0);
    float dist = length(px) / norm;

    float midpoint = clamp(p.a.y / 100.0, 0.0, 1.0);
    float feather = clamp(p.a.z / 100.0, 0.02, 1.0);
    float inner = midpoint;   // 0 = centre, 1 = the corner
    // There must be room outside `inner` for a band of this width: at the corner there is none, so
    // the feather narrows with the remaining radius (a hard step at the very corner, rather than a
    // band that would start at 0.75 and darken the long-edge midpoint at midpoint 100).
    // The floor is 0.2 % of the corner radius: a zero-width step at exactly 1.0 would never touch a
    // pixel centre (the last pixel sits half a pixel inside the geometric corner), so the corner
    // would not visibly darken at all.
    float halfWidth = max(feather * 0.5 * (1.0 - inner), 0.002);
    float t = smoothstep(inner - halfWidth, inner + halfWidth, dist);

    float gain = clamp(1.0 + p.a.x / 100.0 * t, 0.0, 4.0);
    dst.write(float4(max(c.rgb * gain, 0.0), c.a), gid);
}
