#include <metal_stdlib>
using namespace metal;

// S3b — colour: vibrance, then global saturation.
//
// **The eight HSL bands are not here any more** (派单 076). They used to run `rgb_to_hsl` on this
// stage's linear input, which made one 亮度 slider mean two different things — pure blue and pure
// yellow both read HSL `l = 0.5` on linear light while their luminance differs by 6.9× (079 结论 4).
// They now live in S3.6 (`s3_6_hsl.metal`), on OKLCh, on the display-referred output of this stage.
// What stays here is exactly what S3.5's local colour shares: the same `color_hsl.metal` include, so
// a full-canvas mask at saturation +40 equals this slider at +40.
//
// The HSL maths — `rgb_to_hsl` / `hsl_to_rgb` / the two slider mappings — lives in
// `color_hsl.metal`, which **`s3_5_local_color` includes as well** (派单 056).
//
// Matte (派单 008 C): a *black* pixel survives this pass today because HSL keeps `l = 0` whatever
// the saturation does, so the matte happens to come out 0 — but that is an accident of the maths,
// not a rule, and the moment a lift lands on a dark channel the bars tint. The content-rect guard is
// the rule, the same one S2 and S3a now carry.

#include "color_hsl.metal"

struct ColorParams {
    float4 a;   // vibrance, saturation, identity(all-zero → this pass writes through), pad
    float4 b;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

kernel void s3_color(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant ColorParams &p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.a.z > 0.5) {
        dst.write(c, gid);
        return;
    }

    // **The matte is not a shadow.** S0 marks background (anything outside the picture, in a canvas-space
    // window) with alpha 0, and the guard below is a *canvas* guard: when the window is the canvas, the
    // content rect covers every pixel, so background pixels used to fall through and get lifted with the
    // shadows — a blacks/curve lift turned the letterbox grey. Alpha 0 is the only thing that says
    // "there is no photograph here", so it is checked before any pixel maths.
    if (c.a == 0.0) {
        dst.write(c, gid);
        return;
    }

    // Outside the content rect: the matte, written back unchanged.
    float2 g = float2(gid);
    if (g.x < p.b.x || g.y < p.b.y || g.x >= p.b.x + p.b.z || g.y >= p.b.y + p.b.w) {
        dst.write(c, gid);
        return;
    }

    // HDR headroom is carried around the HSL maths, not through it. `rgb_to_hsl` works on a
    // *normalised* colour (divide by the largest channel when it is above white), so a pixel at 4×
    // white keeps its 4× after the round trip: every clamp inside HSL is on the normalized values,
    // and the result is scaled back by the same factor. Before this, `clamp(c.rgb, 0, 1)` sat right
    // here, so touching vibrance or saturation flattened every highlight above white to 1.0 — the
    // picture lost its EDR range the moment a colour slider moved.
    // For an SDR pixel (max ≤ 1) the factor is exactly 1 and the maths below is bit-identical.
    // The scale targets a normalized peak of 0.9 rather than 1.0 on purpose: `rgb_to_hsl` on a value
    // whose max is exactly 1 always yields saturation **1** (s = (1−mn)/(1−mn)), which would make a
    // saturation boost a no-op on every HDR pixel. Normalizing to 0.9 keeps the chroma ratio intact,
    // so `saturation +` still has room to move.
    float peak = max(c.r, max(c.g, c.b));
    float headroomScale = peak > 1.0 ? peak / 0.9 : 1.0;
    float3 hsl = rgb_to_hsl(max(c.rgb, 0.0) / headroomScale);

    // Vibrance moves unsaturated pixels most: the gain scales with (1 - saturation), so skin tones
    // and already-saturated reds stay put while muted colour wakes up.
    float sat = hsl.y;
    if (abs(p.a.x) > 1e-6) {
        sat = clamp(sat + p.a.x / 100.0 * 0.5 * (1.0 - sat), 0.0, 1.0);
    }
    if (abs(p.a.y) > 1e-6) {
        sat = clamp(sat * (1.0 + p.a.y / 100.0), 0.0, 1.0);
    }
    hsl.y = sat;

    dst.write(float4(hsl_to_rgb(hsl) * headroomScale, c.a), gid);
}
