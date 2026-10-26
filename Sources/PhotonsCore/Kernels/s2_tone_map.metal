#include <metal_stdlib>
using namespace metal;

// S2 — tone map: parametric curve (Lightroom's Light panel), display-referred output in 0…1+.
//
// Order: blacks/whites remap → contrast around the scene-linear mid-grey pivot (0.18) → region
// lifts for shadows/highlights weighted by output luminance. This is a parameterisation of the
// classic "light panel" behaviour, not a film emulation: it is monotone in every slider and exact
// identity at all zeros, which is what M1 has to prove.
//
// Direction (派单 008 A): Lightroom's, i.e. **both sliders brighten towards +**. `blacks` lifts or
// crushes the *input black point*, `whites` expands or pulls in the *white point*, and both points
// move opposite to the slider that names them — hence the two minus signs. The old code had
// `blk = +blacks/100·0.15` and `wht = 1 + whites/100·0.15`, which darkened the picture from either
// slider (a positive `blk` subtracts light; a larger `wht` divides it away).
//
// Matte (派单 008 B): the canvas may be larger than the picture (letterbox) and everything outside
// the content rect is 0. A lifted black point maps 0 to `(0 − blk)/(wht − blk) > 0`, which is how
// "drag blacks" used to light up the viewport's background bars. Those pixels are written through
// untouched — an exact pixel identity, not an epsilon — so a test can assert the matte is 0.

struct S2Params {
    float4 a;   // blacks, whites, contrast, pivot
    float4 b;   // highlights, shadows, identity, pad
    float4 c;   // contentOrigin.xy, contentSize.xy (canvas pixels) — the letterbox guard
};

kernel void s2_tone_map(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant S2Params &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    float4 c = src.read(gid);
    if (p.b.z > 0.5) {
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

    // Outside the content rect: the matte, written back unchanged (S0 leaves it at 0).
    float2 g = float2(gid);
    if (g.x < p.c.x || g.y < p.c.y || g.x >= p.c.x + p.c.z || g.y >= p.c.y + p.c.w) {
        dst.write(c, gid);
        return;
    }

    float3 v = max(c.rgb, 0.0);

    // Input black/white points: a positive slider lowers the point it names, which is what makes
    // `+blacks` open the shadows and `+whites` brighten (and clip) the highlights.
    float blk = -p.a.x / 100.0 * 0.15;
    float wht = 1.0 - p.a.y / 100.0 * 0.15;
    v = max((v - blk) / max(wht - blk, 1e-3), 0.0);

    float pivot = max(p.a.w, 1e-3);
    float gamma = exp2(p.a.z / 100.0 * 2.0);
    v = pivot * pow(max(v, 1e-6) / pivot, gamma);

    float lum = dot(v, float3(0.2126, 0.7152, 0.0722));
    float wShadow = 1.0 - smoothstep(0.0, 0.5, lum);
    float wHighlight = smoothstep(0.5, 1.0, lum);
    // LR convention for both region sliders: a positive value lifts that region, a negative value
    // pulls it down. `highlights +` therefore *brightens* the highlight zone (less recovery) and
    // `highlights -` recovers it — the sign used to be flipped here, which made the panel read
    // backwards against Lightroom for the same gesture.
    float liftShadow = exp2(p.b.y / 100.0 * 0.8 * wShadow);
    float liftHighlight = exp2(p.b.x / 100.0 * 0.8 * wHighlight);
    v *= liftShadow * liftHighlight;

    dst.write(float4(max(v, 0.0), c.a), gid);
}
