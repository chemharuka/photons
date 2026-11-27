import Foundation
import Metal

/// 566-A — the scene-linear gated multi-scale Wiener (GMW) denoiser.
///
/// This is the replacement for S3.9's joint-bilateral luminance/chroma denoise. It runs on the
/// scene-linear buffer (working primaries, before the curve and the tone map) because the noise is
/// born there and every threshold in `docs/tasks/566-post-denoise-design.md` is a linear-domain
/// number. The stage is encoded at the graph's S1.5 position (inside the `.curve` link, right before
/// the 365 linear prototype).
///
/// Algorithm, in the design document's order:
///
///   1. clamp negatives, `y = 0.2126R + 0.7152G + 0.0722B` (Rec709), `K = R − G`, `M = B − G`,
///      one full-resolution plane texture that every later pass reads instead of recomputing the
///      three planes;
///   2. one global `σ` per plane from `median(|∂·|) / 0.6745 / √2`, with the median taken from a
///      log2 histogram built on the GPU (no full-frame readback);
///   3. three à trous levels (B3 spline, steps 1/2/4), **every level at full resolution**. Each
///      level's detail is Wiener-shrunk by `w = c² / (c² + (k·σ·2^(i/2))²)`; the luma weight is
///      protected by the flatness gate `g`, the chroma weight by the chroma's own edge term;
///   4. the flatness gate: `gn = smooth|∇y| / σ`, `g = clip((hi − gn)/(hi − lo))` with `lo/hi` at the
///      40 %/85 % quantiles of `gn`. The quantile search is a second GPU histogram — the map is
///      **scale-free**, so `g` does not depend on the σ estimate at all. This is the only quarter-
///      resolution statistics pass; it decides the gate and never reconstructs a pixel;
///   5. chroma: the **same** multi-scale Wiener, and only the fine bands (1–4 px). The coarse chroma
///      pass that used to be a guided filter guided by **luma** is gone: it forced every coloured
///      object to follow the luminance structure, which is exactly the "colour disappeared" defect
///      (measured: 27–50 % of the chroma at the resting 50/50, 81 % of pixels down more than 20 %).
///      No coarse stage means the 16–64 px chroma base is passed through unchanged — low-frequency
///      colour is preserved by construction, while the fine Wiener removes the grain. The chroma
///      threshold is `k_c = 1 + colorNR/100 · 1` (default 50 ⇒ 1.5σc), not the old 3.5σc that ate
///      real colour differences. K and M take **one** weight, computed from the vector detail
///      `c = sqrt(K² + M²)` with `σ_c = sqrt(σK² + σM²)`, so the two components are never shrunk by
///      different amounts (566-A §11);
///   6. recombine `G = y − 0.2126K − 0.0722M`, `R = G + K`, `B = G + M`, clamp negatives. (The
///      Rec709 weights are what make a chroma-only pass leave every pixel's luma unchanged; the
///      earlier `(K + M)/3` and a flat `(K + M)/4` both moved it because `y` is not their luma.)
///
/// Robustness: when no **enabled** axis has a σ at or above `1e-6` (an extremely dark frame, e.g.
/// L1030479) the finish pass copies the source back verbatim — no division, no NaN, no "collapse to
/// black". A disabled axis passes its plane through unchanged (Wiener weight 1). The decoder has
/// already applied the frame's black level; this pass never invents one.
///
/// The parameters are the two existing `effects` fields, with unchanged 0…100 travel:
///   · luma   → `k = 1 + lumaNR/100 · 2`  (default 50 ⇒ k = 2);
///   · chroma → `k_c = 1 + colorNR/100 · 1` (default 50 ⇒ k_c = 1.5).
/// Both at 0 means the stage does not exist for the document (the caller never encodes it), so
/// `--nr 0 --cnr 0` is the pre-566 frame byte for byte.
enum PostDenoise {

    /// 566-A — the operator generation. Any change that moves a pixel of the S1.5 result must bump
    /// this, because the graph's whole-frame result cache is keyed by it: a cached texture from a
    /// previous arithmetic must never answer a request written by this one.
    static let tuningVersion = 4

    /// ── parameters, mirrored byte for byte by the shader below ─────────────────────────────────
    private struct Params {
        var size: SIMD4<Int32>   // full w, h, quarter w, quarter h
        var cfg: SIMD4<Float>    // kY, kC, add-to-accumulator flag, level index
        var dim: SIMD4<Int32>    // sample stride, sample count, à-trous/box radius, spare
        var f: SIMD4<Float>      // luma enabled, chroma enabled, 0, 0
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
    /// `correction`, when supplied, receives `out − source` after the finish pass. The graph keeps
    /// that field for the **interactive** path: a slider drag whose S1.5 inputs are still expensive
    /// can re-apply the previous frame's correction to the new input (one cheap full-resolution add)
    /// instead of running the whole chain; the next settled render replaces it. `nil` on the export,
    /// CLI and test paths, where the correction is neither needed nor allocated.
    static func encode(cb: MTLCommandBuffer, source: MTLTexture, destination: MTLTexture,
                       lumaNR: Double, chromaNR: Double, correction: MTLTexture? = nil,
                       scratch: (String, Int, Int, MTLPixelFormat) throws -> MTLTexture) throws {
        let device = source.device
        let w = destination.width, h = destination.height
        if w <= 0 || h <= 0 { return }
        let qw = max(1, w / 4), qh = max(1, h / 4)
        // The MAD median needs ~1 M samples on any frame size; denser sampling only spends atomics.
        let stride = max(1, min(8, min(w, h) / 256))
        // Exact number of lattice points the shader's `x % stride == stride/2` test visits.
        let nx = stride == 1 ? w : max(0, (w - 1 - stride / 2) / stride + 1)
        let ny = stride == 1 ? h : max(0, (h - 1 - stride / 2) / stride + 1)
        let samples = max(1, nx * ny)

        let kY = Float(1 + min(max(lumaNR, 0), 100) / 100 * 2)
        let kC = Float(1 + min(max(chromaNR, 0), 100) / 100 * 1)
        let lumaOn: Float = lumaNR > 0 ? 1 : 0
        let chromaOn: Float = chromaNR > 0 ? 1 : 0

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
                       f: SIMD4(lumaOn, chromaOn, 0, 0))

        func run(_ name: String, _ configure: (MTLComputeCommandEncoder) -> Void,
                 width: Int, height: Int) throws {
            let pso = try pipeline(name, device: device)
            guard let e = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            e.setComputePipelineState(pso)
            configure(e)
            dispatch(e, pso, width: width, height: height)
            e.endEncoding()
        }

        // ── 1 · full-resolution planes + σ histograms ─────────────────────────────────────────
        let planes = try scratch("gmw-planes", w, h, .rgba16Float)
        try run("gmw_prepare", { e in
            e.setTexture(source, index: 0)
            e.setTexture(planes, index: 1)
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

        // ── 3 · flatness gate, quarter-resolution statistics only ──────────────────────────────
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

        // ── 4 · three-level à trous, every level at full resolution ────────────────────────────
        // The texture holds (y, K, M). The accumulator ping-pongs between two **distinct** textures;
        // no pass binds one texture as both input and output.
        //
        //   level 0: cur = planes, smooth = next,     accOut = destination
        //   level 1: cur = next,   smooth = planesB,  accIn = destination → accOut = accB
        //   level 2: cur = planesB, smooth = next,    accIn = accB → accOut = accC
        // The finish pass reads accC and writes destination, so the frame needs no copy-back blit.
        let next = try scratch("gmw-next", w, h, .rgba16Float)
        let planesB = try scratch("gmw-planes-b", w, h, .rgba16Float)
        let accB = try scratch("gmw-acc-b", w, h, .rgba16Float)
        let accC = try scratch("gmw-acc-c", w, h, .rgba16Float)
        let levels: [(cur: MTLTexture, smooth: MTLTexture, accIn: MTLTexture,
                      accOut: MTLTexture, step: Int32, add: Float)] = [
            (planes, next, planes, destination, 1, 0),
            (next, planesB, destination, accB, 2, 1),
            (planesB, next, accB, accC, 4, 1),
        ]
        for (index, level) in levels.enumerated() {
            p.dim.z = level.step
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
        // Coarse is now `next`; the final accumulator is `accC`.

        // ── 5 · recombine, and clamp ─────────────────────────────────────────────────────────
        // There is no coarse chroma stage. The guided filter used to blend a large-radius (r = 24)
        // regression guided by **luma** into `g·(1 − structure)`, which made every coloured object
        // follow the luminance structure and cut the resting document's chroma by 27–50 %. The
        // multi-scale Wiener above already removes the 1–4 px chroma grain; what it leaves is the
        // low-frequency colour, which is the picture and must not be touched.
        try run("gmw_finish", { e in
            e.setTexture(accC, index: 0)
            e.setTexture(next, index: 1)
            e.setTexture(source, index: 3)
            e.setTexture(destination, index: 9)
            e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            e.setBuffer(stats, offset: 0, index: 1)
        }, width: w, height: h)

        if let correction {
            try run("gmw_correction", { e in
                e.setTexture(destination, index: 0)
                e.setTexture(source, index: 1)
                e.setTexture(correction, index: 2)
                e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
            }, width: w, height: h)
        }
    }

    /// Re-apply a cached correction to a new input: `out = max(source + correction, 0)`. This is the
    /// drag path — one full-resolution pointwise pass, no à trous, no guided filter.
    static func applyCorrection(cb: MTLCommandBuffer, source: MTLTexture, correction: MTLTexture,
                                destination: MTLTexture) throws {
        let w = destination.width, h = destination.height
        if w <= 0 || h <= 0 { return }
        let device = source.device
        var p = Params(size: SIMD4(Int32(w), Int32(h), 0, 0),
                       cfg: SIMD4(0, 0, 0, 0), dim: SIMD4(1, 1, 1, 0), f: SIMD4(0, 0, 0, 0))
        let pso = try pipeline("gmw_apply_correction", device: device)
        guard let e = cb.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        e.setComputePipelineState(pso)
        e.setTexture(source, index: 0)
        e.setTexture(correction, index: 1)
        e.setTexture(destination, index: 2)
        e.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        dispatch(e, pso, width: w, height: h)
        e.endEncoding()
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
        int4 dim;    // sample stride, sample count, trous/box radius, spare
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
                            texture2d<float, access::write> planes [[texture(1)]],
                            device atomic_uint *hist [[buffer(1)]],
                            constant GMWParams &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int w = p.size.x, h = p.size.y, stride = p.dim.x;
        int x = int(gid.x), y = int(gid.y);
        if (x >= w || y >= h) return;
        float3 a = max(src.read(uint2(x, y)).rgb, 0.0f);
        float ya = (0.2126f * a.x + 0.7152f * a.y + 0.0722f * a.z);
        float ka = a.x - a.y;
        float ma = a.z - a.y;
        planes.write(float4(ya, ka, ma, 1.0f), uint2(x, y));

        // One deterministic lattice point per stride × stride cell feeds the MAD histograms.
        if ((x % stride) != stride / 2 || (y % stride) != stride / 2) return;
        int nx = min(x + 1, w - 1);
        float3 b = max(src.read(uint2(nx, y)).rgb, 0.0f);
        float yb = (0.2126f * b.x + 0.7152f * b.y + 0.0722f * b.z);
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
        bool lumaOn = p.f.x > 0.5f && sy >= 1e-6f;
        bool chromaOn = p.f.y > 0.5f && (sk >= 1e-6f || sm >= 1e-6f);
        st->s = float4(sy, sk, sm, (lumaOn || chromaOn) ? 1.0f : 0.0f);
    }

    // ── 3 · flatness gate (quarter-resolution statistics; never pixels) ─────────────────────
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
                sum += (0.2126f * a.x + 0.7152f * a.y + 0.0722f * a.z);
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
    // the gradient by its own rounding. The shader used to histogram the raw gradient, which is not
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

    // ── 4 · one à-trous level, separably in threadgroup memory, full resolution ──────────────
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
                float4 v = cur.read(uint2(gx, gy));
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

        float4 c = cur.read(uint2(gx, gy));
        float4 d = c - smooth;
        // The gate lives at quarter resolution but covers the same normalised extent.
        float4 gv = gate.sample(lin, float2((float(gx) + 0.5f) / float(w),
                                            (float(gy) + 0.5f) / float(h)));
        // The quarter-resolution gate cannot see a 4-px pattern (its 4×4 reduction averages it
        // away). The same tile in threadgroup memory is a full-resolution plane, so the local
        // gradient is free here: it is the `structure` term the design already names for chroma,
        // and using it for the luma protection too is what keeps fine texture from being read as
        // flat noise. `max` with the gate preserves the gate's own 0…1 semantics.
        int ci = int(tid.y) + 2 * s, cj = int(tid.x) + 2 * s;
        int il = (ci * rw + (cj - 1)) * 4;
        int ir = (ci * rw + (cj + 1)) * 4;
        int iu = ((ci - 1) * rw + cj) * 4;
        int id = ((ci + 1) * rw + cj) * 4;
        float dx = 0.5f * (smem[ir] - smem[il]);
        float dy = 0.5f * (smem[id] - smem[iu]);
        float structure = clamp(sqrt(dx * dx + dy * dy) / max(6.0f * st->s.x, 1e-6f),
                                0.0f, 1.0f);
        // Chroma is protected by **its own** edges, not by luma's: a coloured object can sit on a
        // strong luminance edge (gold, paint, coloured light) while its chroma is locally flat, and
        // letting the luma structure gate chroma was half of the "colour disappeared" defect. The
        // luma guide is at most a quarter of the weight (566-A §8.1).
        float dkx = 0.5f * (smem[ir + 1] - smem[il + 1]);
        float dky = 0.5f * (smem[id + 1] - smem[iu + 1]);
        float dmx = 0.5f * (smem[ir + 2] - smem[il + 2]);
        float dmy = 0.5f * (smem[id + 2] - smem[iu + 2]);
        float chromaSigma = max(0.5f * (st->s.y + st->s.z), 1e-6f);
        float structureC = clamp(sqrt(dkx * dkx + dky * dky + dmx * dmx + dmy * dmy)
                                 / (6.0f * chromaSigma), 0.0f, 1.0f);
        // `protectL = 1` is "this is noise, shrink it"; `0` is "this is structure, keep it". The
        // full-resolution structure term therefore *reduces* the gate, it does not replace it.
        float protectL = clamp(gv.x, 0.0f, 1.0f) * (1.0f - structure);
        // Chroma does **not** use luma's flatness gate. A wall behind a striped shadow is flat in
        // chroma even when it is busy in luma, and gating it there was the other half of the colour
        // defect: the chroma grain stayed. Its own edge term is the guard instead.
        float protectC = 1.0f - max(structureC, 0.25f * structure);
        float scale = exp2(float(p.cfg.w) * 0.5f);
        float ty = p.cfg.x * st->s.x * scale;
        // 566-A §11 — the chroma is one **vector**, not two independent scalars. `c = |detail|`
        // gets one Wiener weight and the same weight multiplies both K and M, so the two components
        // can no longer be shrunk by different amounts (the old separate `wk`/`wm` was the hue
        // rotation the ticket measured). σ_c = sqrt(σK² + σM²) is the vector's noise length; the
        // ticket's other allowed choice (`max`) was 1.4× tighter, shrank real fine colour and did
        // not improve the 965 hue, so the norm is what ships.
        float sigmaC = sqrt(st->s.y * st->s.y + st->s.z * st->s.z);
        float tc = p.cfg.y * sigmaC * scale;
        float cc = d.y * d.y + d.z * d.z;
        float wc = (p.f.y > 0.5f) ? cc / (cc + tc * tc + 1e-20f) : 1.0f;
        float wy = (p.f.x > 0.5f) ? (d.x * d.x) / (d.x * d.x + ty * ty + 1e-20f) : 1.0f;
        float multC = (1.0f - protectC) + protectC * wc;
        float4 contrib = float4(((1.0f - protectL) + protectL * wy) * d.x,
                                multC * d.y,
                                multC * d.z,
                                0.0f);
        float4 prev = (p.cfg.z > 0.5f) ? accIn.read(uint2(gx, gy)) : float4(0.0f);
        accOut.write(prev + contrib, uint2(gx, gy));
    }

    // ── 6 · recombine ────────────────────────────────────────────────────────────────────────
    kernel void gmw_finish(texture2d<float, access::read> acc [[texture(0)]],
                           texture2d<float, access::read> coarse [[texture(1)]],
                           texture2d<float, access::read> src [[texture(3)]],
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
        float4 a = acc.read(gid);
        float4 c = coarse.read(gid);
        float y2 = a.x + c.x;
        float k2 = a.y + c.y;
        float m2 = a.z + c.z;

        // Chroma is recombined from the *same* fine-band Wiener the luma uses and the untouched
        // coarse remainder. There is deliberately no large-radius luma-guided blend here: that
        // regression was what pulled real colour onto the luminance structure (566-A §8.1).
        float g = y2 - 0.2126f * k2 - 0.0722f * m2;
        float r = g + k2;
        float b = g + m2;
        out.write(float4(max(r, 0.0f), max(g, 0.0f), max(b, 0.0f), 1.0f), gid);
    }

    // ── 7 · the interactive drag path: keep the correction, re-apply it ─────────────────────
    kernel void gmw_correction(texture2d<float, access::read> out [[texture(0)]],
                               texture2d<float, access::read> src [[texture(1)]],
                               texture2d<float, access::write> corr [[texture(2)]],
                               constant GMWParams &p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
        corr.write(float4(out.read(gid).rgb - src.read(gid).rgb, 0.0f), gid);
    }

    kernel void gmw_apply_correction(texture2d<float, access::read> src [[texture(0)]],
                                     texture2d<float, access::read> corr [[texture(1)]],
                                     texture2d<float, access::write> out [[texture(2)]],
                                     constant GMWParams &p [[buffer(0)]],
                                     uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= p.size.x || int(gid.y) >= p.size.y) return;
        // No clamp here: `corr = out − src` already carries the settle pass's clamp, so
        // `src + corr` reconstructs that frame exactly. A second clamp would turn the dark-frame
        // no-op (correction 0, source may carry negatives) into a different picture on the drag path.
        out.write(float4(src.read(gid).rgb + corr.read(gid).rgb, 1.0f), gid);
    }
    """
}
