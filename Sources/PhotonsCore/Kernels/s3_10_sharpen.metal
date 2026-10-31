#include <metal_stdlib>
using namespace metal;

// S3.10 — **自研锐化** (185): 数量 / 半径 / 细节 / 蒙版, an unsharp mask in the display-referred
// domain, between S3.9 (纹理/清晰度) and S3c (the vignette).
//
// This is **not** the decoder-forwarded 机身基线 sharpening (`DetailGroup.sharpening`, which is a
// `CIRAWFilter` input read at decode time and cannot be previewed without a re-decode). This pass
// reads the tone-mapped, display-referred pixels S3.9 produced, so a slider drag is one render — and
// it is the document's own sharpening rather than an export-time pass.
//
// ## The arithmetic
//
// One USM, two scales, so that 「细节」 can mean what Lightroom means by it:
//
//     I        = luma(rgb)                       (Rec.709 weights, the S3.9 convention in this domain)
//     G_fine   = gaussian(I, σ/2)                σ = sharpRadius, in **content pixels**
//     G_wide   = gaussian(I, σ)
//     d_wide   = G_fine − G_wide                 the ≥ σ/2 px band (structure, no 1–2 px texture)
//     d_fine   = I − G_fine                      the < σ/2 px band (texture)
//     d        = d_wide + t·d_fine               t = sharpDetail / 100
//     m        = smoothstep(g0, g1, |∇G_wide|)   the edge mask
//     ω        = mix(1, m, masking / 100)        masking = 0 → ω = 1 (sharpen everything)
//     Δ        = clamp(A·ω·d, −allow, +allow)    A = sharpAmount / 100
//     out      = rgb + Δ
//
// `t = 0` is why 「detail = 0 只放大 ≥ 4 px 结构」 is a fact and not a hope: the 1–2 px band only ever
// arrives through `d_fine`, whose weight is exactly zero. `t = 1` recovers the plain USM
// (`d = I − G_wide`), so the control is a blend between "only structures" and "everything".
//
// **The limiter** (`allow`) is what makes the two halo bounds in the acceptance compatible with a
// Gaussian at σ = 3 px. A plain USM draws 40 codes of halo 3 px from a step edge at radius 3; this one
// may not leave the block's own level range, and may not exceed `8·A` codes:
//
//     allow = min(A · 8/255, A · (hi − lo))       lo/hi = the 4×4 block's range of I
//
// In a flat block `hi == lo`, so `allow == 0` and nothing moves there — the halo is clipped by the
// picture's own local range rather than by a constant. The same limiter is the noise guard: a *noisy*
// flat block has `hi − lo ≈ 4σ_noise`, which is far above `8·A/255`, so the 8-code knee is what
// applies and `masking = 0` still amplifies noise (the 反证 in §3 wants ≥ +20 %).
//
// ## Parameters
//
//   · `sharpAmount`  0…150 → A = amount/100 (0…1.5). **0 means the stage is not encoded at all**
//     (`RenderStage.pipeline(hasSharpen:)`), so a neutral document's frame, trace and key are the
//     pre-185 ones byte for byte.
//   · `sharpRadius`  0.5…3.0 → σ in **content pixels** of the render's own grid, which is what keeps a
//     0.5-scale fit preview and a 1:1 window sharpening the same picture detail (「按缩放归一」).
//   · `sharpDetail`  0…100 → t above.
//   · `sharpMasking` 0…100 → ω above.

/// The vertical blur's tile. `ROWS` is `H + 2·k` with `k ≤ 12`, i.e. 32 rows for the widest σ the
/// document range allows (3.0 px → k = 7, so 22 of the 32 are used; the rest is slack for the clamp).
#define S3_10_TILE_W 32
#define S3_10_TILE_H 8
#define S3_10_TILE_ROWS 32

struct SharpenParams {
    // amount (0…1.5) · radius σ (px) · detail (0…1) · masking (0…1)
    float4 a;
    // canvasW · canvasH · q (block) · useFine (0/1 — the fine plane was encoded)
    int4 b;
    // qW · qH · contentOriginX · contentOriginY
    int4 c;
    // contentW · contentH · 0 · 0
    int4 d;
    // luma weights (Rec.709) · mask knee g0
    float4 e;
    // mask knee g1 · allowance (codes) · 0 · 0
    float4 f;
};

static inline float s3_10_luma(float3 rgb, float3 w) {
    return dot(max(rgb, 0.0), w);
}

/// One Gaussian tap, `i` px from the centre. The σ floor keeps a 0.5 px radius from producing a
/// NaN/0-weight kernel (a σ below a quarter pixel would be the identity, which is the one thing a
/// sharpen slider must never be while it is above zero).
static inline float s3_10_tap(float i, float sigma) {
    float s = max(sigma, 0.05);
    return exp(-0.5 * i * i / (s * s));
}

/// A **codes** budget expressed in the linear display values this stage works on.
///
/// The sRGB OETF's slope is `0.4396·v^(−0.5833)`, so a constant linear allowance would be ~25 codes
/// in the shadows and ~2 in the highlights. Inverting that slope here is what makes 「过冲 ≤ 8 码」 a
/// statement about the picture rather than about one end of it — the same inversion
/// `s3_9_code_allowance` performs for a mask's local 锐化.
static inline float s3_10_code_allowance(float I, float codes) {
    float v = max(I, 0.0031308);                      // the OETF's linear segment: slope 12.92
    return (codes / 255.0) / (0.4396 * pow(v, -0.5833));
}

// MARK: - 1. block range (the limiter's window)

/// One texel per `q × q` block: `(lo, hi, 0, 1)` of the **luma**. `rgba16Float` because the apply pass
/// samples it bilinearly and Metal does not filter 32-bit formats.
///
/// This is S3.9's `s3_8_guide_pack` idea reused at full resolution: a block range is a *local level
/// window*, and a sharpen that may not leave it is a sharpen with no halo — the same argument
/// `S3_9_LOCAL_ALLOWANCE_CODES` makes for a mask's local 锐化, with the allowance scaled by the amount
/// here because this slider has 150 of them where that one has 100.
kernel void s3_10_sharpen_pack(texture2d<float, access::read> lum [[texture(0)]],
                               texture2d<float, access::write> bounds [[texture(1)]],
                               constant SharpenParams &p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    int qW = p.c.x, qH = p.c.y;
    if (int(gid.x) >= qW || int(gid.y) >= qH) { return; }
    // `lum` is the half-resolution plane, so a 2 × 2 read of it is the 4 × 4 block of the frame this
    // texel describes. Reading the plane instead of the frame is what makes this pass cheap: the
    // frame-wide version moved eleven million texels at stride four and cost 4 ms of a 5.5 ms stage.
    int hw = (p.b.x + 1) / 2, hh = (p.b.y + 1) / 2;
    int x = int(gid.x) * 2, y = int(gid.y) * 2;
    float4 a = lum.read(uint2(min(x, hw - 1), min(y, hh - 1)));
    float4 b = lum.read(uint2(min(x + 1, hw - 1), min(y, hh - 1)));
    float4 c = lum.read(uint2(min(x, hw - 1), min(y + 1, hh - 1)));
    float4 d = lum.read(uint2(min(x + 1, hw - 1), min(y + 1, hh - 1)));
    float lo = min(min(a.y, b.y), min(c.y, d.y));
    float hi = max(max(a.z, b.z), max(c.z, d.z));
    bounds.write(float4(lo, hi, 0.0, 1.0), gid);
}

// MARK: - 2. plane, separable Gaussian

/// The luma plane at **half resolution**: one texel per 2 × 2 block, the mean of its four luma
/// samples.
///
/// Half, because a USM's base layer is by definition the low band — nothing in `G_σ` with σ ≥ 0.25 px
/// survives a 2 × 2 average, and the apply pass samples this plane bilinearly, so the base it
/// reconstructs is the smooth field it always was. The two blur passes then move a quarter of the
/// bytes, which on this hardware is the whole cost (`blur_v` was 3 ms of the 4.10 Mpx frame at full
/// resolution, and the stage has to fit in 1.2 ms).
kernel void s3_10_sharpen_luma(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> lum [[texture(1)]],
                               constant SharpenParams &p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    int w = p.b.x, h = p.b.y;
    int hw = (w + 1) / 2, hh = (h + 1) / 2;
    if (int(gid.x) >= hw || int(gid.y) >= hh) { return; }
    int x = int(gid.x) * 2, y = int(gid.y) * 2;
    float a = s3_10_luma(src.read(uint2(x, y)).rgb, p.e.xyz);
    float b = s3_10_luma(src.read(uint2(min(x + 1, w - 1), y)).rgb, p.e.xyz);
    float c = s3_10_luma(src.read(uint2(x, min(y + 1, h - 1))).rgb, p.e.xyz);
    float d = s3_10_luma(src.read(uint2(min(x + 1, w - 1), min(y + 1, h - 1))).rgb, p.e.xyz);
    // `.r` is the mean every later pass reads; `.g`/`.b` are this 2 × 2 cell's own range, which is the
    // 4 × 4 block the limiter wants and the reason `s3_10_sharpen_pack` never touches the frame.
    lum.write(float4((a + b + c + d) * 0.25,
                     min(min(a, b), min(c, d)), max(max(a, b), max(c, d)), 1.0), gid);
}

/// Horizontal Gaussian at **both** scales in one dispatch: the two kernels share every tap, so reading
/// the plane twice would double the pass's only real cost. Weights are normalised by the actual tap sum
/// (edge-replicated taps are counted twice at the border), so a flat field blurs to itself exactly.
kernel void s3_10_sharpen_blur_h(texture2d<float, access::read> lum [[texture(0)]],
                                 texture2d<float, access::write> wideH [[texture(1)]],
                                 texture2d<float, access::write> fineH [[texture(2)]],
                                 constant SharpenParams &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    int w = (p.b.x + 1) / 2, h = (p.b.y + 1) / 2;
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    float sW = max(p.a.y, 0.05) * 0.5;
    float sF = max(sW * 0.5, 0.05);
    int kW = min(int(ceil(2.0 * sW)) + 1, 12);
    int kF = min(int(ceil(2.0 * sF)) + 1, kW);
    float accW = 0.0, accF = 0.0, sumW = 0.0, sumF = 0.0;
    for (int i = -kW; i <= kW; ++i) {
        float L = lum.read(uint2(clamp(int(gid.x) + i, 0, w - 1), uint(gid.y))).r;
        float wW = s3_10_tap(float(i), sW);
        accW += L * wW; sumW += wW;
        if (p.b.w != 0 && abs(i) <= kF) {
            float wF = s3_10_tap(float(i), sF);
            accF += L * wF; sumF += wF;
        }
    }
    int ox = int(gid.x), oy = int(gid.y);
    wideH.write(float4(accW / max(sumW, 1e-6), 0.0, 0.0, 1.0), uint2(ox, oy));
    fineH.write(float4(accF / max(sumF, 1e-6), 0.0, 0.0, 1.0), uint2(ox, oy));
}

/// The vertical half of the same two Gaussians, **tiled through threadgroup memory**.
///
/// A column walk is a cache miss per tap (the stride is a row), and at σ = 3 that is fifteen misses per
/// pixel and per plane — the pass measured ~9 ms at 4.10 Mpx that way. A 32 × 8 tile loads
/// `32 × (8 + 2k)` texels once and every output then reads shared memory: the frame is touched once
/// instead of fifteen times, which is the difference between 1.6 GB of traffic and 0.2 GB.
kernel void s3_10_sharpen_blur_v(texture2d<float, access::read> wideH [[texture(0)]],
                                 texture2d<float, access::read> fineH [[texture(1)]],
                                 texture2d<float, access::write> wide [[texture(2)]],
                                 texture2d<float, access::write> fine [[texture(3)]],
                                 constant SharpenParams &p [[buffer(0)]],
                                 uint2 tid [[thread_position_in_threadgroup]],
                                 uint2 tgid [[threadgroup_position_in_grid]],
                                 uint2 tg [[threads_per_threadgroup]]) {
    int w = (p.b.x + 1) / 2, h = (p.b.y + 1) / 2;
    float sW = max(p.a.y, 0.05) * 0.5;
    float sF = max(sW * 0.5, 0.05);
    int kW = min(int(ceil(2.0 * sW)) + 1, 12);
    int kF = min(int(ceil(2.0 * sF)) + 1, kW);

    threadgroup float tileW[S3_10_TILE_W][S3_10_TILE_ROWS];
    threadgroup float tileF[S3_10_TILE_W][S3_10_TILE_ROWS];

    int x0 = int(tgid.x) * S3_10_TILE_W;
    int y0 = int(tgid.y) * S3_10_TILE_H;
    int rows = S3_10_TILE_H + 2 * kW;
    int col = int(tid.x);
    int outX = x0 + col;

    if (outX < w && rows <= S3_10_TILE_ROWS) {
        for (int r = int(tid.y); r < rows; r += int(tg.y)) {
            int y = clamp(y0 - kW + r, 0, h - 1);
            tileW[col][r] = wideH.read(uint2(outX, y)).r;
            tileF[col][r] = fineH.read(uint2(outX, y)).r;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (outX >= w) { return; }

    int oy = y0 + int(tid.y);
    if (oy >= h || rows > S3_10_TILE_ROWS) { return; }

    float accW = 0.0, accF = 0.0, sumW = 0.0, sumF = 0.0;
    for (int i = -kW; i <= kW; ++i) {
        int r = int(tid.y) + kW + i;
        float wW = s3_10_tap(float(i), sW);
        accW += tileW[col][r] * wW; sumW += wW;
        if (p.b.w != 0 && abs(i) <= kF) {
            float wF = s3_10_tap(float(i), sF);
            accF += tileF[col][r] * wF; sumF += wF;
        }
    }
    wide.write(float4(accW / max(sumW, 1e-6), 0.0, 0.0, 1.0), uint2(outX, oy));
    fine.write(float4(accF / max(sumF, 1e-6), 0.0, 0.0, 1.0), uint2(outX, oy));
}

// MARK: - 3. apply

/// `out = rgb + Δ`, with Δ limited to the block's own level range (see the header). One full-resolution
/// read of the frame, two lookups of the blurred planes, one bilinear sample of the block range.
///
/// The mask is computed **here** rather than in a pass of its own: it is two extra reads of `wide` at the
/// pixel the thread is already on, where a separate pass would be a whole frame and another texture.
kernel void s3_10_sharpen_apply(texture2d<float, access::read> src [[texture(0)]],
                                texture2d<float, access::sample> wide [[texture(1)]],
                                texture2d<float, access::sample> fine [[texture(2)]],
                                texture2d<float, access::sample> bounds [[texture(3)]],
                                texture2d<float, access::write> dst [[texture(4)]],
                                constant SharpenParams &p [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    int w = p.b.x, h = p.b.y;
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    float4 px = src.read(gid);

    // The content rect: a sharpen is picture detail, so it stops at the picture's edge exactly where
    // S2/S3/S3.5/S3.9 stop. The letterbox is copied through untouched.
    bool inside = gid.x >= uint(p.c.z) && gid.y >= uint(p.c.w)
               && gid.x < uint(p.c.z + p.d.x) && gid.y < uint(p.c.w + p.d.y);
    float A = clamp(p.a.x, 0.0, 1.5);
    if (!inside || A <= 0.0) {
        dst.write(px, gid);
        return;
    }

    float3 rgb = max(px.rgb, 0.0);
    float I = s3_10_luma(rgb, p.e.xyz);

    int x = int(gid.x), y = int(gid.y);
    // The blurred planes are half resolution (see `s3_10_sharpen_luma`), so both the base and the
    // mask's gradient are **sampled** — bilinearly, which is exactly the reconstruction a base layer
    // wants and keeps the result independent of the downsample's phase.
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float u = (float(x) + 0.5) / float(p.b.x);
    float v = (float(y) + 0.5) / float(p.b.y);
    // One **half-res texel** (two frame pixels) each way: the plane is half resolution, and a gradient
    // measured across half a texel of a blurred step is four times smaller than the step — enough to
    // leave the mask half-closed on an edge it should be open on.
    float2 du = float2(2.0 / float(p.b.x), 0.0);
    float2 dv = float2(0.0, 2.0 / float(p.b.y));
    float2 uv0 = float2(u, v);
    float Gs = wide.sample(linearSampler, uv0).r;
    float Gf = fine.sample(linearSampler, uv0).r;

    float t = clamp(p.a.z, 0.0, 1.0);
    float d = (Gf - Gs) + t * (I - Gf);

    // The edge mask: the gradient of the **blurred** luma, so noise (which a Gaussian averages away)
    // cannot open it. A 0.44 step reads 0.44; 2 code noise reads ~0.008, under `g0`.
    // Forward differences from the centre sample already in hand: two fetches instead of four, and the
    // magnitude of a 1 px step on the blurred plane is the same either way (a step is monotone there).
    float gx = wide.sample(linearSampler, uv0 + du).r - Gs;
    float gy = wide.sample(linearSampler, uv0 + dv).r - Gs;
    float g = max(abs(gx), abs(gy));
    float m = smoothstep(max(p.e.w, 0.0), max(p.f.x, p.e.w + 1e-4), g);
    float omega = mix(1.0, m, clamp(p.a.w, 0.0, 1.0));

    float raw = A * omega * d;

    // The limiter, in two halves, blended by the mask:
    //
    //   · **at an edge** (`m → 1`) the boost may not exceed `8·A` codes — the halo budget the brief
    //     states, expressed through the OETF slope so "8 codes" means 8 codes in the highlights too;
    //   · **in texture** (`m → 0`) it may not exceed half the block's own range — there is no halo to
    //     bound there (the mask would have opened if there were), and a fixed code budget would make
    //     the radius slider inaudible on a checkerboard, which is exactly what §3's radius test
    //     measures.
    //
    // In a **constant** block `hi == lo`, so both halves are 0 and nothing moves: the 3 px-from-an-edge
    // bound of §3 is the range half's work, not a separate guard.
    int q = max(p.b.z, 1);
    float2 uv = float2((float(x) + 0.5) / (float(q) * float(p.c.x)),
                       (float(y) + 0.5) / (float(q) * float(p.c.y)));
    float4 bnd = bounds.sample(linearSampler, uv);
    float lo = min(bnd.x, I), hi = max(bnd.y, I);
    float edgeBudget = s3_10_code_allowance(I, p.f.y);
    float rangeBudget = 0.5 * max(hi - lo, 0.0);
    float allowance = A * mix(rangeBudget, edgeBudget, m);
    float delta = clamp(raw, -allowance, allowance);

    dst.write(float4(clamp(rgb + delta, 0.0, 4.0), px.a), gid);
}

// MARK: - 4. the ⌥ preview

/// The `masking` mask itself, 0…1, as grey — what ⌥ shows on the canvas.
///
/// It reads the same `wide` plane the apply pass masks with, so the preview **is** the mask the render
/// uses, not a second derivation of it. Called by `RenderGraph.sharpenMaskPreview` outside the key
/// chain: no key, no cache entry, no document field (§「Alt 预览」).
kernel void s3_10_sharpen_mask(texture2d<float, access::sample> wide [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant SharpenParams &p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
    int w = p.b.x, h = p.b.y;
    if (int(gid.x) >= w || int(gid.y) >= h) { return; }
    int x = int(gid.x), y = int(gid.y);
    constexpr sampler linearSampler(coord::normalized, filter::linear, address::clamp_to_edge);
    float2 uv0 = float2((float(x) + 0.5) / float(p.b.x), (float(y) + 0.5) / float(p.b.y));
    // One **half-res texel** (two frame pixels) each way: the plane is half resolution, and a gradient
    // measured across half a texel of a blurred step is four times smaller than the step — enough to
    // leave the mask half-closed on an edge it should be open on.
    float2 du = float2(2.0 / float(p.b.x), 0.0);
    float2 dv = float2(0.0, 2.0 / float(p.b.y));
    // Forward differences from the centre sample already in hand: two fetches instead of four, and the
    // magnitude of a 1 px step on the blurred plane is the same either way (a step is monotone there).
    float centre = wide.sample(linearSampler, uv0).r;
    float gx = wide.sample(linearSampler, uv0 + du).r - centre;
    float gy = wide.sample(linearSampler, uv0 + dv).r - centre;
    float g = max(abs(gx), abs(gy));
    float m = smoothstep(max(p.e.w, 0.0), max(p.f.x, p.e.w + 1e-4), g);
    dst.write(float4(m, m, m, 1.0), gid);
}
