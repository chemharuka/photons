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

    // **Keep the sign.** The decoder hands us scene-linear values that go *below* the black point
    // (measured on _1274394.dng: min −0.039, 33 M negative samples, 43 % of the frame under luma
    // 1e-6). Those pixels are not dead — inside that band the 32×32 block means vary with σ 5.7e-4
    // against 2.5e-5 expected from noise, i.e. 23× more structure than noise, which is exactly the
    // detail Lightroom can lift and we could not. Clamping here deleted it before any slider saw it.
    float3 v = c.rgb;

    // Input black/white points: a positive slider lowers the point it names, which is what makes
    // `+blacks` open the shadows and `+whites` brighten (and clip) the highlights. The remap is
    // affine, so it is defined on negative input and needs no clamp of its own.
    float blk = -p.a.x / 100.0 * 0.15;
    float wht = 1.0 - p.a.y / 100.0 * 0.15;
    v = (v - blk) / max(wht - blk, 1e-3);

    float pivot = max(p.a.w, 1e-3);
    float gamma = exp2(p.a.z / 100.0 * 2.0);
    // Sign-preserving power: `pow` is undefined for a negative base, and the curve has to stay
    // odd-symmetric around zero so a sub-black pixel keeps its sub-black sign through the contrast
    // step (at gamma == 1 this is the identity on both sides of zero). The 1e-6 floor is the
    // existing guard against `pow(near-zero, large gamma)` collapsing; it only bites below 1e-6.
    v = sign(v) * pivot * pow(max(abs(v) / pivot, 1e-6), gamma);

    // The **region weights** are computed from the non-negative part, exactly as before the sign was
    // preserved. A pixel with mixed signs (one channel sub-black) would otherwise read a slightly
    // different luminance and the shadows/highlights lift would land a code off on its *positive*
    // channels — measured as 260 of 3.05 M pixels moving by 1 in the push fixture, with no benefit.
    float lum = dot(max(v, 0.0), float3(0.2126, 0.7152, 0.0722));
    float wShadow = 1.0 - smoothstep(0.0, 0.5, lum);
    float wHighlight = smoothstep(0.5, 1.0, lum);
    // LR convention for both region sliders: a positive value lifts that region, a negative value
    // pulls it down. `highlights +` therefore *brightens* the highlight zone (less recovery) and
    // `highlights -` recovers it — the sign used to be flipped here, which made the panel read
    // backwards against Lightroom for the same gesture.
    float liftShadow = exp2(p.b.y / 100.0 * 0.8 * wShadow);
    float liftHighlight = exp2(p.b.x / 100.0 * 0.8 * wHighlight);
    v *= liftShadow * liftHighlight;

    // The clamp stays **here**, at the end of the tone map, and not one line earlier: a sub-black
    // value that an additive control (`blacks +` lowers the input black point) has pulled above zero
    // is real picture by now and must survive; whatever is still below zero is what the display would
    // clip anyway, and clamping it here is what keeps every ordinary edit byte-identical to before.
    // Measured: keeping the sign *through* the write instead moved 260 of 3.05 M pixels by one code in
    // the push fixture — a real but pointless change in the wrong place.
    dst.write(float4(max(v, 0.0), c.a), gid);
}
