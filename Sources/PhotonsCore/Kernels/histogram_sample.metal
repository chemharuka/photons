#include <metal_stdlib>
using namespace metal;

// The histogram's sample: read one texel per output texel, on a deterministic stride, straight out of
// the **display-encoded** frame S4 just wrote (027).
//
// Why a stride read rather than a box filter: this pass runs once per rendered frame, inside a slider
// drag, and its whole budget is "under 2 ms including the readback". A 4.1 Mpx frame reduced to a
// 141×256 grid by averaging would read every source texel (33 MB of traffic); reading one texel per
// output texel touches 36 k texels and no more. The price is sampling noise instead of averaging: the
// grid estimates the distribution from 36 k independent pixels rather than 36 k local means, which
// makes it *unbiased* — an average would pull each sample toward its neighbourhood's mean and quietly
// flatten the ends of the distribution, exactly where a histogram is read.
//
// The sample must cover the **whole picture**, never a centred patch: a histogram of the middle of the
// frame is systematically biased (a sky band and a foreground differ in brightness), and a biased
// measurement is worse than a slow one. `origin`/`size` name the picture's own rect inside the frame
// (letterbox bars excluded), and the first sample sits half a stride in, the last half a stride from
// the far edge: `(i + 0.5) · step`. That covers [0, size) uniformly with no gap and no overlap.
//
// Determinism: the step is computed on the CPU from integers (double, then narrowed once) and the
// source index is `floor(origin + (i + 0.5) · step)` — the same inputs give the same texel indices in
// every process, which is what makes "two calls, same bytes" a property of the arithmetic and not of
// the driver's scheduling.

struct HistSampleParams {
    float4 a;   // origin.xy, size.xy — the rect of the source texture to sample, in texels
    float4 b;   // step.xy, dstSize.xy — source texels per output texel, and the grid to fill
};

// S4's own OETF (the measurement's code axis, and the one the shipped path derives per sample).
static inline float srgb_encode_f(float v) {
    return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055;
}

static inline float srgb_decode_f(float v) {
    float a = fabs(v);
    float d = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4);
    return v < 0.0 ? -d : d;
}

// 070 — the same stride read, out of the **scene-linear** texture instead of the display frame.
//
// This is the measurement the card shows. The frame's own S4 output is *display-referred*: S4 applies
// `min(v, headroom)` (`s4_display.metal`), so on this machine (headroom 3.948× = +1.98 stop) every
// texel above +1.98 stop is gone by the time this pass could read it, and the plot could not tell a
// +2 EV highlight from a +5 EV one. Reading S4's *input* — the scene-linear RGB S3 wrote — keeps that
// information: a texel may be 16, 32 or 1000× white and it arrives here as such.
//
// No encode, no luma: the CPU's `Histogram.compute(LinearSample)` takes linear RGB and derives both
// the code axis (`srgbEncode`) and the luma series with Rec.709 weights applied to **linear** light,
// so the alpha channel is simply 1. The extra `pow`s the display-referred sample had to compute here
// (four per texel, in `histogram_sample`) do not exist on this path at all.
kernel void histogram_sample_linear(texture2d<float, access::read> src [[texture(0)]],
                                    texture2d<float, access::write> dst [[texture(1)]],
                                    constant HistSampleParams &p [[buffer(0)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    uint2 grid = uint2(p.b.z, p.b.w);
    if (gid.x >= grid.x || gid.y >= grid.y) { return; }
    float2 f = (float2(gid) + 0.5) * p.b.xy;
    uint2 texel = uint2(floor(f));
    uint2 last = uint2(p.a.zw) - 1u;
    texel = min(texel, last) + uint2(p.a.xy);
    float4 c = src.read(texel);
    dst.write(float4(c.rgb, 1.0), gid);
}

kernel void histogram_sample(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant HistSampleParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    uint2 grid = uint2(p.b.z, p.b.w);
    if (gid.x >= grid.x || gid.y >= grid.y) { return; }
    // Relative to the rect's origin, so the clamp below is "the last texel of the rect" and the
    // origin is added once, at the end.
    float2 f = (float2(gid) + 0.5) * p.b.xy;
    uint2 texel = uint2(floor(f));
    // Clamped rather than refused: a step that lands one texel past the edge (rounding at the far
    // edge) must sample the edge, not read outside the rect.
    uint2 last = uint2(p.a.zw) - 1u;
    texel = min(texel, last) + uint2(p.a.xy);
    float4 c = src.read(texel);
    // **Alpha is not alpha here.** S4 writes 1.0 into it, and the fourth channel is the only place
    // this sample can carry the luma the CPU would otherwise have to derive from three codes — which
    // is a *different* quantity (`srgbEncode(Σw·linear)` is not `Σw·srgbEncode(linear)`: the OETF is
    // concave, so a code-space mean sits below the encoded mean, by up to a couple of percent of code
    // around white). The shipped measurement weights **linear** light and encodes the sum, so the
    // frame's luma series is that same number, computed here where four `pow`s per sample texel cost
    // nothing (36 k threads) instead of ~1 ms on the CPU (36 k × 4 pows inside a frame budget).
    float luma = srgb_encode_f(0.2126 * srgb_decode_f(c.r)
                               + 0.7152 * srgb_decode_f(c.g)
                               + 0.0722 * srgb_decode_f(c.b));
    dst.write(float4(c.r, c.g, c.b, luma), gid);
}
