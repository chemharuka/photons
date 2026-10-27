#include <metal_stdlib>
using namespace metal;

// S3b — colour: eight HSL bands (Lightroom's red/orange/yellow/green/aqua/blue/purple/magenta),
// then vibrance, then global saturation.
//
// The HSL maths — `rgb_to_hsl` / `hsl_to_rgb` / the band weights / the two slider mappings — lives
// in `color_hsl.metal`, which **`s3_5_local_color` includes as well** (派单 056). A local mask's
// saturation +40 and the global saturation slider at +40 therefore run the same arithmetic, not two
// copies of it, which is what makes a full-canvas mask agree with the global control.
//
// Matte (派单 008 C): a *black* pixel survives this pass today because HSL keeps `l = 0` whatever
// the saturation does, so the matte happens to come out 0 — but that is an accident of the maths,
// not a rule, and the moment a hue band or a lift lands on a dark channel the bars tint. The
// content-rect guard is the rule, the same one S2 and S3a now carry.

#include "color_hsl.metal"

struct ColorParams {
    float4 a;   // vibrance, saturation, identity, pad
    float4 b;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

kernel void s3_color(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant ColorParams &p [[buffer(0)]],
                     constant float4 *bands [[buffer(1)]],
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

    float3 shift = hsl_band_shift(hsl.x * 360.0, hsl.y, bands);
    hsl = hsl_rotate_hue(hsl, shift.x);
    hsl = hsl_scale_saturation(hsl, shift.y);
    hsl.z = clamp(hsl.z * (1.0 + shift.z / 100.0), 0.0, 1.0);

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
