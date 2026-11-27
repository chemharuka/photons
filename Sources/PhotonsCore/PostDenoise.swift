import Foundation
import Metal

/// 566-A — the scene-linear GMW (guided multi-scale Wiener) denoiser.
///
/// This is the replacement for S3.9's joint-bilateral luminance/chroma denoise. It runs on the
/// scene-linear buffer (working primaries, before the curve and the tone map) because the noise is
/// born there and every threshold in `docs/tasks/566-post-denoise-design.md` is a linear-domain
/// number. The stage is encoded at the graph's S1.5 position (inside the `.curve` link, right before
/// the 365 linear prototype).
///
/// Algorithm, in the design document's order:
///
///   1. clamp negatives, `y = mean(R,G,B)`, `K = R − G`, `M = B − G`;
///   2. one global `σ` per plane from `median(|∂·|) / 0.6745 / √2`, with the median taken from a
///      log2 histogram built on the GPU (no full-frame readback);
///   3. three à-trous levels (B3 spline, steps 1/2/4). Each level's detail is Wiener-shrunk by
///      `w = c² / (c² + (k·σ·2^(i/2))²)`; the luma weight is protected by the flatness gate `g`,
///      the chroma weights by `g·(1 − structure)`;
///   4. the flatness gate: `gn = smooth|∇y| / σ`, `g = clip((hi − gn)/(hi − lo))` with `lo/hi` at the
///      40 %/85 % quantiles of `gn`. The quantile search is a second GPU histogram — the map is
///      **scale-free**, so `g` does not depend on the σ estimate at all;
///   5. chroma: the same multi-scale Wiener for the fine band, plus one large-radius guided filter
///      (`r = 24` in full-resolution pixels, guide `y`, `ε = (3σc)²`) for the 16–64 px blotches,
///      blended in by `g·(1 − structure)`;
///   6. recombine `G = y − (K + M)/3`, `R = G + K`, `B = G + M`, clamp negatives.
///
/// Robustness: when the luma σ is 0 or below `1e-6` (an extremely dark frame, e.g. L1030479) the
/// finish pass copies the source back verbatim — no division, no NaN, no "collapse to black". The
/// decoder has already applied the frame's black level; this pass never invents one.
///
/// The parameters are the two existing `effects` fields, with unchanged 0…100 travel:
///   · luma   → `k = 1 + lumaNR/100 · 2`  (default 50 ⇒ k = 2);
///   · chroma → `k_c = 1 + colorNR/100 · 5` (default 50 ⇒ k_c = 3.5).
/// Both at 0 means the stage does not exist for the document (the caller never encodes it), so
/// `--nr 0 --cnr 0` is the pre-566 frame byte for byte.
enum PostDenoise {

    /// ── parameters, mirrored byte for byte by the shader below ─────────────────────────────────
    private struct Params {
        var size: SIMD4<Int32>   // full w, h, quarter w, quarter h
        var cfg: SIMD4<Float>    // kY, kC, add-to-accumulator flag, level index
        var dim: SIMD4<Int32>    // sample stride, sample count, à-trous step, box mode
        var f: SIMD4<Float>      // spare (0)
    }

    private struct Stats {
        var s: SIMD4<Float>      // σY, σK, σM, active
        var g: SIMD4<Float>      // gate lo, gate hi, 0, 0
    }

    private static let histBins = 2048

    /// One compile per process, the same discipline `KernelLibrary` follows for the bundled files.
    private static let lock = NSLock()
    private static var libraries: [String: MTLLibrary] = [:]
    private static var pipelines: [String: MTLComputePipelineState] = [:]

    private static func pipeline(_ name: String, device: MTLDevice) throws -> MTLComputePipelineState {
        let key = "dev\(device.registryID)|\(name)"
        lock.lock()
        defer { lock.unlock() }
        if let p = pipelines[key] { return p }
        let libKey = "dev\(device.registryID)"
        let library: MTLLibrary
        if let l = libraries[libKey] {
            library = l
        } else {
            do {
                library = try device.makeLibrary(source: source, options: nil)
            } catch {
                throw RenderError.kernelCompileFailed("post_denoise", error.localizedDescription)
            }
            libraries[libKey] = library
        }
        guard let fn = library.makeFunction(name: name) else {
            throw RenderError.missingKernelFunction("post_denoise", name)
        }
        do {
            let p = try device.makeComputePipelineState(function: fn)
            pipelines[key] = p
            return p
        } catch {
            throw RenderError.pipelineFailed("post_denoise", error.localizedDescription)
        }
    }

    private static func dispatch(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState,
                                 width: Int, height: Int) {
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        let groups = MTLSize(width: max(1, (width + 15) / 16),
                             height: max(1, (height + 15) / 16), depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
    }

    /// Encode the whole S1.5 stage into `cb`. `scratch` is the graph's cached texture pool; the
    /// dependency is a closure so the graph keeps ownership of the allocation policy.
    static func encode(cb: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture,
                       lumaNR: Double, chromaNR: Double,
                       scratch: (String, Int, Int, MTLPixelFormat) throws -> MTLTexture) throws {
        let device = source.device
        let w = destination.width, h = destination.height
        if w <= 0 || h <= 0 { return }
        let qw = max(1, w / 4), qh = max(1, h / 4)
        let stride = max(1, min(4, min(w, h) / 512))
        // Exact number of lattice points the shader's `x % stride == stride/2` test visits.
        let nx = stride == 1 ? w : max(0, (w - 1 - stride / 2) / stride + 1)
        let ny = stride == 1 ? h : max(0, (h - 1 - stride / 2) / stride + 1)
        let samples = max(1, nx * ny)

        let kY = Float(1 + min(max(lumaNR, 0), 100) / 100 * 2)
        let kC = Float(1 + min(max(chromaNR, 0), 100) / 100 * 5)

        // ── buffers ────────────────────────────────────────────────────────────────────────────
        guard let hist = device.makeBuffer(length: histBins * 3 * MemoryLayout<UInt32>.stride,
                                           options: .storageModePrivate),
              let histG = device.makeBuffer(length: histBins * MemoryLayout<UInt32>.stride,
                                            options: .storageModePrivate),
              let stats = device.makeBuffer(length: MemoryLayout<Stats>.stride,
                                            options: .storageModePrivate) else {
            throw RenderError.allocationFailed("gmw-histograms")
        }
        guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
        blit.fill(buffer: hist, range: 0..<hist.length, value: 0)
        blit.fill(buffer: histG, range: 0..<histG.length, value: 0)
        blit.endEncoding()

        var p = Params(size: SIMD4(Int32(w), Int32(h), Int32(qw), Int32(qh)),
                       cfg: SIMD4(kY, kC, 0, 0),
                       dim: SIMD4(Int32(stride), Int32(samples), 1, 0),
                       f: SIMD4(0, 0, 0, 0))

        func run(_ name: String, _ configure: (MTLComputeCommandEncoder) -> Void,
                 width: Int, height: Int) throws {
            let pso = try pipeline(name, device: device)
            guard let e = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            e.setComputePipelineState(pso)
            configure(e)
            dispatch(e, pso, width: width, height: height)
            e.endEncoding()
        }

        // ── 1 · planes + σ histograms ──────────────────────────────────────────────────────────
        try run("gmw_prepare", { e in
            e.setTexture(source, index: 0)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            e.setBuffer(hist, offset: 0, index: 1)
        }, width: w, height: h)

        // ── 2 · σ from the MAD histograms ──────────────────────────────────────────────────────
        let sigma = try pipeline("gmw_sigma", device: device)
        guard let es = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        es.setComputePipelineState(sigma)
        es.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        es.setBuffer(hist, offset: 0, index: 1)
        es.setBuffer(stats, offset: 0, index: 2)
        es.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        es.endEncoding()

        // ── 3 · flatness gate at quarter resolution ───────────────────────────────────────────
        let yq = try scratch("gmw-yq", qw, qh, .r16Float)
        try run("gmw_downsample_y", { e in
            e.setTexture(source, index: 0)
            e.setTexture(yq, index: 1)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        }, width: qw, height: qh)

        let q1 = try scratch("gmw-q1", qw, qh, .r16Float)
        let yqb = try scratch("gmw-yqb", qw, qh, .r16Float)
        try run("gmw_gauss_h", { e in
            e.setTexture(yq, index: 0)
            e.setTexture(q1, index: 1)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        }, width: qw, height: qh)
        try run("gmw_gauss_v", { e in
            e.setTexture(q1, index: 0)
            e.setTexture(yqb, index: 1)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        }, width: qw, height: qh)

        try run("gmw_gradient", { e in
            e.setTexture(yqb, index: 0)
            e.setTexture(q1, index: 1)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        }, width: qw, height: qh)

        let q2 = try scratch("gmw-q2", qw, qh, .r16Float)
        let gn = try scratch("gmw-gn", qw, qh, .r16Float)
        try run("gmw_gauss_h", { e in
            e.setTexture(q1, index: 0)
            e.setTexture(q2, index: 1)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        }, width: qw, height: qh)
        try run("gmw_gauss_hist_v", { e in
            e.setTexture(q2, index: 0)
            e.setTexture(gn, index: 1)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            e.setBuffer(histG, offset: 0, index: 1)
            e.setBuffer(stats, offset: 0, index: 2)
        }, width: qw, height: qh)

        let gateReduce = try pipeline("gmw_gate_reduce", device: device)
        guard let eg = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        eg.setComputePipelineState(gateReduce)
        eg.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        eg.setBuffer(histG, offset: 0, index: 1)
        eg.setBuffer(stats, offset: 0, index: 2)
        eg.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        eg.endEncoding()

        let gate = try scratch("gmw-gate", qw, qh, .rg16Float)
        try run("gmw_gate_pack", { e in
            e.setTexture(gn, index: 0)
            e.setTexture(gate, index: 1)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            e.setBuffer(stats, offset: 0, index: 1)
        }, width: qw, height: qh)

        // ── 4 · three-level à trous, luma and both chroma planes in one chain ─────────────────
        // The texture holds (y, K, M). The accumulator ping-pongs between two **distinct** textures;
        // no pass binds one texture as both input and output, so a cached/aliased graph texture can
        // never turn a read-then-add into an undefined read_write.
        //
        //   level 0:            cur = planes,      smooth = next,    accOut = destination
        //   level 1: accIn = destination → accOut = accB
        //   level 2: accIn = accB → accOut = destination, coarse = next
        let next = try scratch("gmw-next", w, h, .rgba16Float)
        let planesB = try scratch("gmw-planes", w, h, .rgba16Float)
        let accB = try scratch("gmw-accB", w, h, .rgba16Float)
        let levels: [(cur: MTLTexture, smooth: MTLTexture, accIn: MTLTexture,
                      accOut: MTLTexture, step: Int32, add: Float, sourceMode: Int32)] = [
            (source, next, source, destination, 1, 0, 1),
            (next, planesB, destination, accB, 2, 1, 0),
            (planesB, next, accB, destination, 4, 1, 0),
        ]
        for (index, level) in levels.enumerated() {
            p.dim.z = level.step
            p.dim.w = level.sourceMode
            p.cfg.z = level.add
            p.cfg.w = Float(index)
            try run("gmw_atrous_level", { e in
                e.setTexture(level.cur, index: 0)
                e.setTexture(level.smooth, index: 1)
                e.setTexture(level.accIn, index: 2)
                e.setTexture(level.accOut, index: 3)
                e.setTexture(gate, index: 4)
                e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
                e.setBuffer(stats, offset: 0, index: 1)
            }, width: w, height: h)
        }
        // Coarse is now `next`; the accumulator is `destination`.

        // ── 5 · coarse chroma: guided filter (r = 24 full-res px ⇒ r = 6 at quarter res) ───────
        let kq = try scratch("gmw-kq", qw, qh, .r16Float)
        let mq = try scratch("gmw-mq", qw, qh, .r16Float)
        try run("gmw_downsample_km", { e in
            e.setTexture(destination, index: 0)
            e.setTexture(next, index: 1)
            e.setTexture(kq, index: 2)
            e.setTexture(mq, index: 3)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        }, width: qw, height: qh)

        // Statistics are 32-bit: `E[y²] − E[y]²` on a flat 0.42 field is a few 1e-5, below an
        // `r16Float` ulp (2.4e-4) — at half precision the variance is quantisation noise and the
        // guided regression divides by it. Every box pass below moves all four moments in one
        // rgba32 texture, so the guided filter costs four separable passes, not twenty.
        let radius: Int32 = 6
        let statsA = try scratch("gmw-stats-a", qw, qh, .rgba32Float)
        let statsB = try scratch("gmw-stats-b", qw, qh, .rgba32Float)
        let boxedA = try scratch("gmw-boxed-a", qw, qh, .rgba32Float)
        let boxedB = try scratch("gmw-boxed-b", qw, qh, .rgba32Float)
        let coeff = try scratch("gmw-guided-coeff", qw, qh, .rgba32Float)
        let coeffBox = try scratch("gmw-guided-coeff-box", qw, qh, .rgba32Float)
        let tmp = try scratch("gmw-box-tmp", qw, qh, .rgba32Float)

        for (name, target) in [("gmw_stats_a", statsA), ("gmw_stats_b", statsB)] {
            try run(name, { e in
                e.setTexture(yq, index: 0)
                e.setTexture(kq, index: 1)
                e.setTexture(mq, index: 2)
                e.setTexture(target, index: 3)
                e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            }, width: qw, height: qh)
        }
        p.dim.z = radius
        func box4(_ src: MTLTexture, into out: MTLTexture) throws {
            try run("gmw_box4_h", { e in
                e.setTexture(src, index: 0)
                e.setTexture(tmp, index: 1)
                e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            }, width: qw, height: qh)
            try run("gmw_box4_v", { e in
                e.setTexture(tmp, index: 0)
                e.setTexture(out, index: 1)
                e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            }, width: qw, height: qh)
        }
        try box4(statsA, into: boxedA)
        try box4(statsB, into: boxedB)
        try run("gmw_guided_ab4", { e in
            e.setTexture(boxedA, index: 0)
            e.setTexture(boxedB, index: 1)
            e.setTexture(coeff, index: 2)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            e.setBuffer(stats, offset: 0, index: 1)
        }, width: qw, height: qh)
        try box4(coeff, into: coeffBox)

        // Fold `a·y + b` here, at quarter resolution, so the full-resolution finish pass samples two
        // textures instead of five. Several bilinear taps per 60 Mpx pixel was a measurable cost.
        let kbig = try scratch("gmw-kbig", qw, qh, .r16Float)
        let mbig = try scratch("gmw-mbig", qw, qh, .r16Float)
        try run("gmw_guided_value", { e in
            e.setTexture(coeffBox, index: 0)
            e.setTexture(yq, index: 1)
            e.setTexture(kbig, index: 2)
            e.setTexture(mbig, index: 3)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        }, width: qw, height: qh)

        // ── 6 · recombine, blend the coarse chroma, clamp ─────────────────────────────────────
        // The finish pass reads the accumulator and the coarse level, so it writes `accB` (now free)
        // and one blit lands the frame in the graph's output texture. A read/write binding on the
        // shared destination is exactly the trap the level chain above avoids.
        try run("gmw_finish", { e in
            e.setTexture(destination, index: 0)
            e.setTexture(next, index: 1)
            e.setTexture(gate, index: 2)
            e.setTexture(source, index: 3)
            e.setTexture(kbig, index: 4)
            e.setTexture(mbig, index: 5)
            e.setTexture(accB, index: 9)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            e.setBuffer(stats, offset: 0, index: 1)
        }, width: w, height: h)

        guard let blit = cb.makeBlitCommandEncoder() else { throw RenderError.commandBufferFailed }
        blit.copy(from: accB, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: w, height: h, depth: 1),
                  to: destination, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
    }

    // MARK: - shader

    /// The shader lives inline: the 566-A whitelist does not add a `.metal` file, and the runtime
    /// compiler needs no prebuilt metallib (the same reason `KernelLibrary` compiles at runtime).
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct GMWParams {
        int4 size;   // w, h, qw, qh
        float4 cfg;  // kY, kC, add flag, level
        int4 dim;    // sample stride, sample count, trous step, box mode
        float4 f;
    };
    struct GMWStats {
        float4 s;    // sigmaY, sigmaK, sigmaM, active
        float4 g;    // gate lo, gate hi, -, -
    };

    #define GMW_BINS 2048
    #define GMW_LOG_LO (-24.0f)
    #define GMW_BINS_PER_OCT 64.0f

    inline int gmw_bin(float v) {
        float a = fabs(v);
        if (!(a > 0.0f)) return 0;
        int b = int((log2(a) - GMW_LOG_LO) * GMW_BINS_PER_OCT);
        return clamp(b, 0, GMW_BINS - 1);
    }

    inline float gmw_bin_value(int b) {
        if (b <= 0) return 0.0f;
        return exp2(GMW_LOG_LO + (float(b) + 0.5f) / GMW_BINS_PER_OCT);
    }

    inline float gmw_quantile(device atomic_uint *h, uint total, float q) {
        if (total == 0u) return 0.0f;
        uint target = uint(clamp(q, 0.0f, 1.0f) * float(total - 1u));
        uint cum = 0u;
        for (int b = 0; b < GMW_BINS; ++b) {
            uint c = atomic_load_explicit(&h[b], memory_order_relaxed);
            if (cum + c > target) {
                return gmw_bin_value(b);
            }
            cum += c;
        }
        return gmw_bin_value(GMW_BINS - 1);
    }

    // ── 1 · planes and the MAD histograms ─────────────────────────────────────────────────────
    kernel void gmw_prepare(texture2d<float, access::read> src [[texture(0)]],
                            device atomic_uint *hist [[buffer(1)]],
                            constant GMWParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.x, h = p.size.y, stride = p.dim.x;
        int x = int(gid.x), y = int(gid.y);
        if (x >= w || y >= h) return;
        float3 a = max(src.read(uint2(x, y)).rgb, 0.0f);
        float ya = (a.x + a.y + a.z) / 3.0f;
        float ka = a.x - a.y;
        float ma = a.z - a.y;

        // One deterministic lattice point per stride × stride cell feeds the MAD histograms.
        if ((x % stride) != stride / 2 || (y % stride) != stride / 2) return;
        int nx = min(x + 1, w - 1);
        float3 b = max(src.read(uint2(nx, y)).rgb, 0.0f);
        float yb = (b.x + b.y + b.z) / 3.0f;
        float kb = b.x - b.y;
        float mb = b.z - b.y;
        atomic_fetch_add_explicit(&hist[gmw_bin(ya - yb)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&hist[GMW_BINS + gmw_bin(ka - kb)], 1u, memory_order_relaxed);
        atomic_fetch_add_explicit(&hist[2 * GMW_BINS + gmw_bin(ma - mb)], 1u,
                                  memory_order_relaxed);
    }

    // ── 2 · one global sigma per plane ────────────────────────────────────────────────────────
    kernel void gmw_sigma(device atomic_uint *hist [[buffer(1)]],
                          device GMWStats *st [[buffer(2)]],
                          constant GMWParams &p [[buffer(0)]],
                          uint tid [[thread_position_in_threadgroup]]) {
        if (tid != 0u) return;
        uint total = uint(p.dim.y);
        const float norm = 1.0f / 0.6745f / 1.41421356237f;
        float sy = gmw_quantile(hist, total, 0.5f) * norm;
        float sk = gmw_quantile(hist + GMW_BINS, total, 0.5f) * norm;
        float sm = gmw_quantile(hist + 2 * GMW_BINS, total, 0.5f) * norm;
        st->s = float4(sy, sk, sm, sy >= 1e-6f ? 1.0f : 0.0f);
    }

    // ── 3 · flatness gate (quarter resolution) ───────────────────────────────────────────────
    inline float4 gmw_plane(texture2d<float, access::read> t, uint2 gid, int sourceMode) {
        if (sourceMode == 0) return t.read(gid);
        float3 a = max(t.read(gid).rgb, 0.0f);
        return float4((a.x + a.y + a.z) / 3.0f, a.x - a.y, a.z - a.y, 1.0f);
    }

    kernel void gmw_downsample_y(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant GMWParams &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.x, h = p.size.y;
        if (int(gid.x) >= p.size.z || int(gid.y) >= p.size.w) return;
        float sum = 0.0f;
        for (int dy = 0; dy < 4; ++dy) {
            for (int dx = 0; dx < 4; ++dx) {
                int x = min(int(gid.x) * 4 + dx, w - 1);
                int y = min(int(gid.y) * 4 + dy, h - 1);
                float3 a = max(src.read(uint2(x, y)).rgb, 0.0f);
                sum += (a.x + a.y + a.z) / 3.0f;
            }
        }
        dst.write(sum / 16.0f, gid);
    }

    constant float gmw_w[5] = { 1.0f / 16, 4.0f / 16, 6.0f / 16, 4.0f / 16, 1.0f / 16 };

    inline float gmw_gauss9(thread const float *v) {
        // sigma = 2.0 at the quarter-resolution grid (8 full-resolution pixels).
        const float w[9] = { 0.02763055f, 0.06628225f, 0.12383154f, 0.18017382f,
                             0.20416369f, 0.18017382f, 0.12383154f, 0.06628225f, 0.02763055f };
        float s = 0.0f;
        for (int i = 0; i < 9; ++i) s += w[i] * v[i];
        return s;
    }

    kernel void gmw_gauss_h(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant GMWParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.z, h = p.size.w;
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float v[9];
        for (int i = -4; i <= 4; ++i) {
            v[i + 4] = src.read(uint2(clamp(int(gid.x) + i, 0, w - 1), int(gid.y))).x;
        }
        dst.write(gmw_gauss9(v), gid);
    }

    kernel void gmw_gauss_v(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant GMWParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.z, h = p.size.w;
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float v[9];
        for (int i = -4; i <= 4; ++i) {
            v[i + 4] = src.read(uint2(int(gid.x), clamp(int(gid.y) + i, 0, h - 1))).x;
        }
        dst.write(gmw_gauss9(v), gid);
    }

    // `gn = smooth|∇y| / max(σ, floor)` — dimensionless, so the gate means the same thing on a
    // bright frame and a dark one. The absolute floor keeps a nearly noise-free input from dividing
    // the gradient by its own rounding (a low-noise fixture would otherwise make every pixel look
    // like an edge and close the gate). The shader used to histogram the raw gradient, which is not
    // scale-free; that is the one place it deviated from the design document.
    kernel void gmw_gauss_hist_v(texture2d<float, access::read> src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 device atomic_uint *histG [[buffer(1)]],
                                 constant GMWParams &p [[buffer(0)]],
                                 device const GMWStats *st [[buffer(2)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.z, h = p.size.w;
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float v[9];
        for (int i = -4; i <= 4; ++i) {
            v[i + 4] = src.read(uint2(int(gid.x), clamp(int(gid.y) + i, 0, h - 1))).x;
        }
        float g = gmw_gauss9(v);
        g /= max(st->s.x, 8e-4f);
        dst.write(g, gid);
        atomic_fetch_add_explicit(&histG[gmw_bin(g)], 1u, memory_order_relaxed);
    }

    kernel void gmw_gradient(texture2d<float, access::read> src [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant GMWParams &p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.z, h = p.size.w;
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        int x = int(gid.x), y = int(gid.y);
        float l = src.read(uint2(max(x - 1, 0), y)).x;
        float r = src.read(uint2(min(x + 1, w - 1), y)).x;
        float u = src.read(uint2(x, max(y - 1, 0))).x;
        float d = src.read(uint2(x, min(y + 1, h - 1))).x;
        float dx = 0.5f * (r - l), dy = 0.5f * (d - u);
        dst.write(sqrt(dx * dx + dy * dy), gid);
    }

    kernel void gmw_gate_reduce(device atomic_uint *histG [[buffer(1)]],
                                device GMWStats *st [[buffer(2)]],
                                constant GMWParams &p [[buffer(0)]],
                                uint tid [[thread_position_in_threadgroup]]) {
        if (tid != 0u) return;
        uint total = uint(p.size.z) * uint(p.size.w);
        st->g = float4(gmw_quantile(histG, total, 0.40f),
                       gmw_quantile(histG, total, 0.85f), 0.0f, 0.0f);
    }

    kernel void gmw_gate_pack(texture2d<float, access::read> gn [[texture(0)]],
                              texture2d<float, access::write> gate [[texture(1)]],
                              constant GMWParams &p [[buffer(0)]],
                              device const GMWStats *st [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= p.size.z || int(gid.y) >= p.size.w) return;
        float v = gn.read(gid).x;
        float lo = st->g.x, hi = st->g.y;
        float g = (st->s.w > 0.5f) ? clamp((hi - v) / max(hi - lo, 1e-6f), 0.0f, 1.0f) : 0.0f;
        // `v` is already `|∇y| / max(σ, floor)`, so `v / 6` is the prototype's dimensionless
        // `gmag / (6σ)` structure term.
        float structure = clamp(v / 6.0f, 0.0f, 1.0f);
        gate.write(float4(g, structure, 0.0f, 0.0f), gid);
    }

    // ── 4 · one à-trous level, separably in threadgroup memory ───────────────────────────────
    kernel void gmw_atrous_level(texture2d<float, access::read> cur [[texture(0)]],
                                 texture2d<float, access::write> smoothOut [[texture(1)]],
                                 texture2d<float, access::read> accIn [[texture(2)]],
                                 texture2d<float, access::write> accOut [[texture(3)]],
                                 texture2d<float, access::sample> gate [[texture(4)]],
                                 constant GMWParams &p [[buffer(0)]],
                                 device const GMWStats *st [[buffer(1)]],
                                 uint2 tid [[thread_position_in_threadgroup]],
                                 uint2 grp [[threadgroup_position_in_grid]]) {
        threadgroup float smem[32 * 32 * 4];
        threadgroup float hsm[32 * 16 * 4];
        constexpr sampler lin(filter::linear, address::clamp_to_edge);

        int w = p.size.x, h = p.size.y;
        int s = p.dim.z;
        int rw = 16 + 4 * s;
        int ox = int(grp.x) * 16, oy = int(grp.y) * 16;
        int sx = ox - 2 * s, sy = oy - 2 * s;

        for (int i = int(tid.y); i < rw; i += 16) {
            for (int j = int(tid.x); j < rw; j += 16) {
                int gx = clamp(sx + j, 0, w - 1);
                int gy = clamp(sy + i, 0, h - 1);
                float4 v = gmw_plane(cur, uint2(gx, gy), p.dim.w);
                int k = (i * rw + j) * 4;
                smem[k + 0] = v.x; smem[k + 1] = v.y; smem[k + 2] = v.z; smem[k + 3] = v.w;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (int i = int(tid.y); i < rw; i += 16) {
            for (int j = int(tid.x); j < 16; j += 16) {
                int c = j + 2 * s;
                float4 v = float4(0.0f);
                for (int t = 0; t < 5; ++t) {
                    int idx = (i * rw + (c + (t - 2) * s)) * 4;
                    v += gmw_w[t] * float4(smem[idx], smem[idx + 1], smem[idx + 2], smem[idx + 3]);
                }
                int o = (i * 16 + j) * 4;
                hsm[o + 0] = v.x; hsm[o + 1] = v.y; hsm[o + 2] = v.z; hsm[o + 3] = v.w;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        int gx = ox + int(tid.x), gy = oy + int(tid.y);
        if (gx >= w || gy >= h) return;
        int row = int(tid.y) + 2 * s;
        float4 smooth = float4(0.0f);
        for (int t = 0; t < 5; ++t) {
            int o = ((row + (t - 2) * s) * 16 + int(tid.x)) * 4;
            smooth += gmw_w[t] * float4(hsm[o], hsm[o + 1], hsm[o + 2], hsm[o + 3]);
        }
        smoothOut.write(smooth, uint2(gx, gy));

        float4 c = gmw_plane(cur, uint2(gx, gy), p.dim.w);
        float4 d = c - smooth;
        // The gate lives at quarter resolution but covers the same normalised extent.
        float4 gv = gate.sample(lin, float2((float(gx) + 0.5f) / float(w),
                                            (float(gy) + 0.5f) / float(h)));
        float protectL = clamp(gv.x, 0.0f, 1.0f);
        float protectC = protectL * (1.0f - clamp(gv.y, 0.0f, 1.0f));
        float scale = exp2(float(p.cfg.w) * 0.5f);
        float ty = p.cfg.x * st->s.x * scale;
        float tk = p.cfg.y * st->s.y * scale;
        float tm = p.cfg.y * st->s.z * scale;
        float wy = (d.x * d.x) / (d.x * d.x + ty * ty + 1e-20f);
        float wk = (d.y * d.y) / (d.y * d.y + tk * tk + 1e-20f);
        float wm = (d.z * d.z) / (d.z * d.z + tm * tm + 1e-20f);
        float4 contrib = float4(((1.0f - protectL) + protectL * wy) * d.x,
                                ((1.0f - protectC) + protectC * wk) * d.y,
                                ((1.0f - protectC) + protectC * wm) * d.z,
                                0.0f);
        float4 prev = (p.cfg.z > 0.5f) ? accIn.read(uint2(gx, gy)) : float4(0.0f);
        accOut.write(prev + contrib, uint2(gx, gy));
    }

    // ── 5 · coarse chroma ────────────────────────────────────────────────────────────────────
    kernel void gmw_downsample_km(texture2d<float, access::read> acc [[texture(0)]],
                                  texture2d<float, access::read> coarse [[texture(1)]],
                                  texture2d<float, access::write> kq [[texture(2)]],
                                  texture2d<float, access::write> mq [[texture(3)]],
                                  constant GMWParams &p [[buffer(0)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.x, h = p.size.y;
        if (int(gid.x) >= p.size.z || int(gid.y) >= p.size.w) return;
        float sk = 0.0f, sm = 0.0f;
        for (int dy = 0; dy < 4; ++dy) {
            for (int dx = 0; dx < 4; ++dx) {
                int x = min(int(gid.x) * 4 + dx, w - 1);
                int y = min(int(gid.y) * 4 + dy, h - 1);
                float4 a = acc.read(uint2(x, y));
                float4 c = coarse.read(uint2(x, y));
                sk += a.y + c.y;
                sm += a.z + c.z;
            }
        }
        kq.write(sk / 16.0f, gid);
        mq.write(sm / 16.0f, gid);
    }

    // The four guided-filter moments live in one rgba32 texture, so each box is one separable pair
    // over all four channels. `a` is the moment texture (I, I², K, M); `b` is (I², I·K, I·M, 0).
    kernel void gmw_stats_a(texture2d<float, access::read> yq [[texture(0)]],
                            texture2d<float, access::read> kq [[texture(1)]],
                            texture2d<float, access::read> mq [[texture(2)]],
                            texture2d<float, access::write> dst [[texture(3)]],
                            constant GMWParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= p.size.z || int(gid.y) >= p.size.w) return;
        float i = yq.read(gid).x, k = kq.read(gid).x, m = mq.read(gid).x;
        dst.write(float4(i, i * i, k, m), gid);
    }

    kernel void gmw_stats_b(texture2d<float, access::read> yq [[texture(0)]],
                            texture2d<float, access::read> kq [[texture(1)]],
                            texture2d<float, access::read> mq [[texture(2)]],
                            texture2d<float, access::write> dst [[texture(3)]],
                            constant GMWParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= p.size.z || int(gid.y) >= p.size.w) return;
        float i = yq.read(gid).x, k = kq.read(gid).x, m = mq.read(gid).x;
        dst.write(float4(i * i, i * k, i * m, 0.0f), gid);
    }

    kernel void gmw_box4_h(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant GMWParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.z, h = p.size.w, r = p.dim.z;
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float4 sum = float4(0.0f);
        for (int i = -r; i <= r; ++i) {
            sum += src.read(uint2(clamp(int(gid.x) + i, 0, w - 1), int(gid.y)));
        }
        dst.write(sum / float(2 * r + 1), gid);
    }

    kernel void gmw_box4_v(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant GMWParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.z, h = p.size.w, r = p.dim.z;
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float4 sum = float4(0.0f);
        for (int i = -r; i <= r; ++i) {
            sum += src.read(uint2(int(gid.x), clamp(int(gid.y) + i, 0, h - 1)));
        }
        dst.write(sum / float(2 * r + 1), gid);
    }

    kernel void gmw_guided_ab4(texture2d<float, access::read> meanA [[texture(0)]],
                               texture2d<float, access::read> meanB [[texture(1)]],
                               texture2d<float, access::write> dst [[texture(2)]],
                               constant GMWParams &p [[buffer(0)]],
                               device const GMWStats *st [[buffer(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= p.size.z || int(gid.y) >= p.size.w) return;
        float4 a = meanA.read(gid);
        float4 b = meanB.read(gid);
        float i = a.x, ii = a.y, k = a.z, m = a.w;
        float ik = b.y, im = b.z;
        float sc = 0.5f * (st->s.y + st->s.z);
        // A synthetic neutral frame has σK = σM = 0; eps = 0 makes the guided regression
        // ill-conditioned (and a grey card must stay grey). The floor is far below a real frame's
        // (3σc)² — ~3.6e-5 for the measured 2e-3 chroma noise.
        float eps = max((3.0f * sc) * (3.0f * sc), 1e-6f);
        float ak = (ik - i * k) / max(ii - i * i + eps, 1e-20f);
        float am = (im - i * m) / max(ii - i * i + eps, 1e-20f);
        dst.write(float4(ak, k - ak * i, am, m - am * i), gid);
    }

    // ── 6 · recombine and blend ──────────────────────────────────────────────────────────────
    kernel void gmw_guided_value(texture2d<float, access::read> coeff [[texture(0)]],
                                 texture2d<float, access::read> yq [[texture(1)]],
                                 texture2d<float, access::write> kbig [[texture(2)]],
                                 texture2d<float, access::write> mbig [[texture(3)]],
                                 constant GMWParams &p [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= p.size.z || int(gid.y) >= p.size.w) return;
        float4 c = coeff.read(gid);
        float yv = yq.read(gid).x;
        kbig.write(c.x * yv + c.y, gid);
        mbig.write(c.z * yv + c.w, gid);
    }

    kernel void gmw_finish(texture2d<float, access::read> acc [[texture(0)]],
                           texture2d<float, access::read> coarse [[texture(1)]],
                           texture2d<float, access::sample> gate [[texture(2)]],
                           texture2d<float, access::read> src [[texture(3)]],
                           texture2d<float, access::sample> kbig [[texture(4)]],
                           texture2d<float, access::sample> mbig [[texture(5)]],
                           texture2d<float, access::write> out [[texture(9)]],
                           constant GMWParams &p [[buffer(0)]],
                           device const GMWStats *st [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.x, h = p.size.y;
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        if (st->s.w < 0.5f) {
            out.write(src.read(gid), gid);
            return;
        }
        constexpr sampler lin(filter::linear, address::clamp_to_edge);
        float4 a = acc.read(gid);
        float4 c = coarse.read(gid);
        float y2 = a.x + c.x;
        float k2f = a.y + c.y;
        float m2f = a.z + c.z;

        float2 uv = float2((float(gid.x) + 0.5f) / float(w),
                           (float(gid.y) + 0.5f) / float(h));
        float4 gv = gate.sample(lin, uv);
        // A neutral / noise-free chroma plane cannot support a large-window regression; there is
        // nothing for the coarse pass to remove, so it is skipped rather than divided by rounding.
        float chromaSigma = 0.5f * (st->s.y + st->s.z);
        float weight = (chromaSigma > 1e-5f)
            ? clamp(gv.x, 0.0f, 1.0f) * (1.0f - clamp(gv.y, 0.0f, 1.0f)) : 0.0f;
        float kb = kbig.sample(lin, uv).x;
        float mb = mbig.sample(lin, uv).x;
        float k2 = mix(k2f, kb, weight);
        float m2 = mix(m2f, mb, weight);

        float g = y2 - (k2 + m2) / 3.0f;
        float r = g + k2;
        float b = g + m2;
        out.write(float4(max(r, 0.0f), max(g, 0.0f), max(b, 0.0f), 1.0f), gid);
    }
    """
}
