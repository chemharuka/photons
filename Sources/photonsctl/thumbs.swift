import Foundation
import CoreGraphics
import ImageIO
import PhotonsCore
import PhotonsExport
import PhotonsCatalog

// MARK: - M3.5 / 006c: thumbs
//
// `photonsctl thumbs <pkg> --out <dir> [--tier grid|filmstrip|full] [--limit N]
//                         [--strategy graph|preview|auto] [--visible N] [--concurrency N]
//                         [--report] [--cancel-prefetch] [--json]`
//
// Everything goes through `ThumbnailService` (Sources/PhotonsCatalog/ThumbnailService.swift):
// priority queue (visible cells `onScreen`, the rest `prefetch`), single flight per key,
// cancellable handles, a hard concurrency ceiling, and counters that the `--report` line prints.
//
// Two producers, one renderer (docs/architecture-decisions.md D12):
//   preview — ImageIO on the embedded camera JPEG (`RAWDecoder.preview`), placeholder only, §0
//   graph   — `RenderGraph.render(edit, options: scale)` at the requested tier, the baseline
// `--strategy auto` resolves per asset the way §0 says: an existing `graph` file wins, then the
// placeholder, and a policy veto (would upscale / tier above the preview ceiling) escalates to
// `graph` — the placeholder is never upscaled to pretend it is a full-size frame.
//
// Numbers printed are measured (cold = cache miss, hot = cache hit), not estimated.

enum ThumbsTierArg: String, CaseIterable {
    case grid, filmstrip, full
    // An explicit rung, so `禁止放大` (#6) can be exercised: ARW's 1616 px preview cannot serve
    // t2048, and `--strategy auto` must escalate that to the G path rather than upscale.
    case t256, t512, t1024, t2048, t4096

    var tier: ThumbTier {
        switch self {
        case .grid, .t256: return .t256
        case .filmstrip, .t512: return .t512
        case .full, .t1024: return .t1024
        case .t2048: return .t2048
        case .t4096: return .t4096
        }
    }
}

/// `--strategy` takes the pipeline (`graph`/`preview`/`auto`) and, for compatibility with the 006b
/// bench, the two preview-API spellings (`filter` = CIRAWFilter first, `thumbnail` = ImageIO first).
enum ThumbsStrategyArg: String, CaseIterable {
    case graph
    case preview
    case auto
    case filter
    case thumbnail

    /// Thumbnail may use the embedded preview at all?
    var usesPreview: Bool { self != .graph }
    /// May escalate to `RenderGraph` when the preview path cannot serve the tier?
    var usesGraph: Bool { self == .graph || self == .auto }

    var previewAPI: PreviewStrategy {
        switch self {
        case .filter: return .filter
        default: return .thumbnail   // measured 2.6× faster than the filter route (§0)
        }
    }

    var label: String {
        switch self {
        case .graph: return "graph (RenderGraph)"
        case .preview, .thumbnail: return "preview (ImageIO embedded)"
        case .filter: return "preview (CIRAWFilter embedded)"
        case .auto: return "auto (graph file → preview → graph)"
        }
    }
}

// MARK: - producers

enum ThumbProducerError: LocalizedError {
    case noDecoder
    case wrongPipeline(String)
    case noEmbeddedPreview(String)
    /// The one error `--strategy auto` routes on: the preview may not serve this tier.
    case needsGraph(String)
    case noRecipe(String)
    case renderReturnedNothing
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .noDecoder: return "no Metal/RAW decoder on this machine"
        case .wrongPipeline(let p): return "producer cannot serve a \(p) key"
        case .noEmbeddedPreview(let f): return "no embedded preview in \(f)"
        case .needsGraph(let why): return "needs graph: \(why)"
        case .noRecipe(let h): return "no develop recipe for \(h.prefix(8))"
        case .renderReturnedNothing: return "RenderGraph returned no pixels"
        case .encodeFailed: return "JPEG encode returned nil"
        }
    }

    /// `--strategy auto` escalates exactly these, nothing else.
    var escalatesToGraph: Bool { if case .needsGraph = self { return true }; return false }
}

/// P path: the camera's own JPEG, never upscaled, never above the pipeline ceiling (§0, §1).
final class PreviewThumbProducer: ThumbnailProducer {
    private let decoder: RAWDecoder?
    private let strategy: PreviewStrategy

    init(decoder: RAWDecoder?, strategy: PreviewStrategy) {
        self.decoder = decoder
        self.strategy = strategy
    }

    func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
        guard key.pipeline == .preview else { throw ThumbProducerError.wrongPipeline(key.pipeline.rawValue) }
        guard let decoder else { throw ThumbProducerError.noDecoder }
        guard let outcome = decoder.preview(source, maxPixelSize: key.tier.longEdge, strategy: strategy) else {
            throw ThumbProducerError.noEmbeddedPreview(source.lastPathComponent)
        }
        // §1 禁止放大 + §6.1 DNG ceiling. Refusing here (instead of writing a too-small file) is why
        // `--strategy auto` can retry the same tier on the G path and get a real 2048.
        guard ThumbPolicy.previewAllowed(tier: key.tier, sourceLongEdge: outcome.sourceLongEdge,
                                         ext: source.pathExtension) else {
            let limit = ThumbPolicy.previewTierLimit(ext: source.pathExtension)
            throw ThumbProducerError.needsGraph(
                outcome.sourceLongEdge < key.tier.longEdge
                    ? "would upscale \(outcome.sourceLongEdge)→\(key.tier.longEdge)"
                    : "tier above \(source.pathExtension.uppercased()) preview ceiling \(limit.rawValue)")
        }
        guard let jpeg = ThumbnailJPEG.encode(outcome.image) else { throw ThumbProducerError.encodeFailed }
        return ThumbPayload(data: jpeg, source: outcome.source.rawValue,
                            sourceLongEdge: outcome.sourceLongEdge)
    }
}

/// G path: decode → `RenderGraph.render` at `scale = tier / source long edge` → 8-bit sRGB JPEG.
/// Same function as loupe and export, only the scale changes (D12).
final class GraphThumbProducer: ThumbnailProducer {
    private let decoder: RAWDecoder
    private let editFor: (ThumbKey) -> EditModel?
    private let display: DisplayOptions
    private let lock = NSLock()
    private var probes: [String: (w: Int, h: Int)] = [:]

    init(decoder: RAWDecoder, editFor: @escaping (ThumbKey) -> EditModel?, display: DisplayOptions) {
        self.decoder = decoder
        self.editFor = editFor
        self.display = display
    }

    func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
        guard key.pipeline == .graph else { throw ThumbProducerError.wrongPipeline(key.pipeline.rawValue) }
        guard let edit = editFor(key) else { throw ThumbProducerError.noRecipe(key.contentHash) }

        let native = try probeNativeLongEdge(source)
        let target = Double(key.tier.longEdge) / Double(max(1, native))
        // Decode at the coarsest ladder step that still covers the target: decoding finer loses 0.5 s
        // and 480 MB, decoding coarser resamples twice (same rule as `photonsctl render`).
        let decodeScale = min(1.0, Double(decodeScaleLadder(target)))
        let image = try decoder.decode(source, options: DecodeOptions(scale: Float(decodeScale)))
        let renderScale = min(1.0, target / decodeScale)

        let graph = try RenderGraph(input: RenderInput(image: image, identity: key.digest))
        let options = RenderOptions(canvas: nil, scale: renderScale, display: display,
                                    useCache: true, wantsPixels: true)
        guard let pixels = try graph.render(edit, options: options).display else {
            throw ThumbProducerError.renderReturnedNothing
        }
        let cg = try Exporter.cgImage(pixels, bitDepth: 8)
        guard let jpeg = ThumbnailJPEG.encode(cg) else { throw ThumbProducerError.encodeFailed }
        return ThumbPayload(data: jpeg, source: "graph", sourceLongEdge: native)
    }

    private func probeNativeLongEdge(_ url: URL) throws -> Int {
        lock.lock()
        let cached = probes[url.path]
        lock.unlock()
        if let cached { return max(cached.w, cached.h) }
        let probe = try decoder.probe(url)
        lock.lock(); probes[url.path] = (probe.nativeWidth, probe.nativeHeight); lock.unlock()
        return max(probe.nativeWidth, probe.nativeHeight)
    }
}

/// Picks the producer by the key's `pipeline`, so one service — and one queue — serves both paths.
final class RoutingThumbProducer: ThumbnailProducer {
    private let preview: PreviewThumbProducer
    private let graph: GraphThumbProducer?

    init(preview: PreviewThumbProducer, graph: GraphThumbProducer?) {
        self.preview = preview
        self.graph = graph
    }

    func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
        switch key.pipeline {
        case .preview: return try preview.produce(key, source: source)
        case .graph:
            guard let graph else { throw ThumbProducerError.noDecoder }
            return try graph.produce(key, source: source)
        }
    }
}

// MARK: - report

struct ThumbSample: Codable {
    var file: String
    var contentHash: String
    var ext: String
    var pipeline: String
    var source: String            // embedded | fallback | graph | cache | skipped
    var note: String?
    var sourceEdge: Int           // long edge of what the pixels came from (0 = unknown)
    var outW: Int
    var outH: Int
    var coldMs: Double            // service wait on the cold round (0 when it was a hit)
    var producedMs: Double        // producer-only cost
    var hotMs: Double             // service wait on the hot round
    var bytes: Int
    var coldHit: Bool
    var hotHit: Bool
}

struct ThumbsReport: Codable {
    var library: String
    var tier: String
    var tierPixels: Int
    var strategy: String
    var assets: Int
    var visible: Int
    var concurrency: Int
    var generated: Int
    var skipped: Int
    var cancelled: Int
    var coldHitRatio: Double
    var hotHitRatio: Double
    var coldP50: Double
    var coldP95: Double
    var producedP50: Double
    var producedP95: Double
    var hotP50: Double
    var hotP95: Double
    var totalBytes: Int64
    var samples: [ThumbSample]
    var missedReasons: [String: Int]
    /// Service-layer counters for the cold round: queueing, coalescing, cancellation.
    var service: ThumbServiceReport
    var hotService: ThumbServiceReport
    /// P1f: the algorithm-version surface. `graphVersion` is the recipe the keys were built under,
    /// `rebuilt` the number of `graph` thumbnails this run regenerated *because* the cache directory
    /// was stamped with another generation (0 on a start that found it current — `service.rebuilt`
    /// carries the same number for scripts that only read the service block).
    var graphVersion: String
    var rebuilt: Int
    var sweep: String
}

// MARK: - args

/// `--concurrency N` / `--visible N` are values this subcommand reads itself: `main.swift`'s
/// `valueFlags` predates them, and the parse falls back to the leftover positional token when the
/// flag was recorded as a bare flag. (The first positional stays the library path.)
private func intArg(_ a: Args, _ flag: String, default fallback: Int) -> Int {
    if let v = a.value(flag).flatMap(Int.init) { return v }
    if a.has(flag), let v = a.positional.dropFirst().compactMap(Int.init).last { return v }
    return fallback
}

// MARK: - command

func cmdThumbs(_ a: Args) throws {
    guard a.positional.count >= 1 else {
        die("thumbs <pkg> --out <dir> [--tier grid|filmstrip|full] [--strategy graph|preview|auto]"
            + " [--limit N] [--visible N] [--concurrency N] [--report] [--json]")
    }
    guard let outPath = a.value("--out") else { die("thumbs needs --out <dir>") }
    let outDir = URL(fileURLWithPath: (outPath as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let tierArg = ThumbsTierArg(rawValue: a.value("--tier") ?? "grid") ?? .grid
    let tier = tierArg.tier
    let strategy = ThumbsStrategyArg(rawValue: a.value("--strategy") ?? "preview") ?? .preview
    let catalog = openLibrary(a, index: 0)

    let visibleCount = max(1, intArg(a, "--visible", default: 20))
    let concurrency = min(8, max(1, intArg(a, "--concurrency", default: 3)))
    let wantReport = a.has("--report")

    var filter = AssetFilter()
    filter.limit = a.value("--limit").flatMap(Int.init) ?? 200
    let assets = try catalog.assets(filter)
    guard !assets.isEmpty else { die("no assets matched") }

    let cache = try ThumbnailCache(layout: catalog.layout)
    let decoder = try? RAWDecoder()
    if decoder == nil { err("warning: no Metal device — thumbnails can only be served from cache") }

    // Every recipe the library knows, so a `graph` key can be rebuilt from its digest's source.
    var developByHash: [String: String] = [:]
    for asset in assets { developByHash[asset.contentHash] = asset.developJson }
    let editFor: (ThumbKey) -> EditModel? = { key in
        guard let json = developByHash[key.contentHash], let data = json.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(EditModel.self, from: data)) ?? .neutral
    }
    var sRGB = DisplayOptions()
    sRGB.primaries = .sRGB      // §1: thumbnails are 8-bit sRGB, never P3/EDR
    sRGB.bitDepth = 8

    let previewProducer = PreviewThumbProducer(decoder: decoder, strategy: strategy.previewAPI)
    let graphProducer = decoder.map {
        GraphThumbProducer(decoder: $0, editFor: editFor, display: sRGB)
    }
    let service = ThumbnailService(
        cache: cache,
        config: .init(maxConcurrency: concurrency),
        producer: RoutingThumbProducer(preview: previewProducer, graph: graphProducer))

    // MARK: keys

    /// §0 resolution order for `auto`: a `graph` file that already exists wins; otherwise start from
    /// the placeholder and escalate only if the policy refuses the tier.
    func keyFor(_ asset: Asset) -> ThumbKey {
        let graphKey = ThumbKey.graph(contentHash: asset.contentHash, tier: tier,
                                      developJSON: asset.developJson)
        switch strategy {
        case .graph: return graphKey
        case .preview, .filter, .thumbnail:
            return .preview(contentHash: asset.contentHash, tier: tier)
        case .auto:
            return cache.peek(graphKey) ? graphKey : .preview(contentHash: asset.contentHash, tier: tier)
        }
    }

    if a.has("--reset") {
        for asset in assets {
            try? FileManager.default.removeItem(at: cache.url(for: keyFor(asset)))
            try? FileManager.default.removeItem(
                at: cache.url(for: .preview(contentHash: asset.contentHash, tier: tier)))
            try? FileManager.default.removeItem(
                at: cache.url(for: .graph(contentHash: asset.contentHash, tier: tier,
                                          developJSON: asset.developJson)))
        }
    }

    // MARK: cold round through the service

    var specs: [(asset: Asset, spec: ThumbRequestSpec)] = []
    var missingFiles = 0
    for asset in assets {
        guard let url = try? catalog.fileURL(for: asset),
              FileManager.default.fileExists(atPath: url.path) else {
            missingFiles += 1
            continue
        }
        specs.append((asset, ThumbRequestSpec(key: keyFor(asset), source: url)))
    }

    func enqueue(_ items: [(asset: Asset, spec: ThumbRequestSpec)], prefix: String) -> [ThumbTicket] {
        guard !items.isEmpty else { return [] }
        let head = Array(items.prefix(visibleCount))         // §4 ①② the visible cells
        let tail = Array(items.dropFirst(visibleCount))      // §4 ③ one row off screen
        var tickets = service.request(head.map { $0.spec }, priority: .onScreen)
        let tailTickets = service.request(tail.map { $0.spec }, priority: .prefetch)
        if a.has("--cancel-prefetch") && prefix == "cold" {
            // Demonstrates the cancellation counters without needing a scroll: the off-screen row
            // is abandoned before it is picked up, so nothing is produced or written for it.
            cancel(tailTickets)
        }
        tickets.append(contentsOf: tailTickets)
        return tickets
    }

    let coldStart = CFAbsoluteTimeGetCurrent()
    var tickets = enqueue(specs, prefix: "cold")
    guard service.waitUntilIdle(timeout: 3600) else { die("thumbnail queue did not drain in an hour") }

    var sampleBySpec: [ThumbRequestSpec: ThumbSample] = [:]
    var resultByAsset: [String: ThumbResult] = [:]

    func absorb(_ items: [(asset: Asset, spec: ThumbRequestSpec)], _ localTickets: [ThumbTicket]) {
        for (i, item) in items.enumerated() {
            guard i < localTickets.count, let result = service.result(for: localTickets[i]) else { continue }
            resultByAsset[item.asset.contentHash] = result
        }
    }
    absorb(specs, tickets)

    // `auto`: the placeholder refused the tier → render it. `needsGraph` is the only escalation.
    var escalated: [(asset: Asset, spec: ThumbRequestSpec)] = []
    if strategy.usesGraph {
        for item in specs {
            let graphKey = ThumbKey.graph(contentHash: item.asset.contentHash, tier: tier,
                                          developJSON: item.asset.developJson)
            guard let result = resultByAsset[item.asset.contentHash], result.origin == .failed,
                  graphKey != item.spec.key,
                  (result.error ?? "").contains("needs graph") else { continue }
            escalated.append((item.asset, ThumbRequestSpec(key: graphKey, source: item.spec.source)))
        }
        if !escalated.isEmpty {
            tickets += enqueue(escalated, prefix: "escalate")
            _ = service.waitUntilIdle(timeout: 3600)
            absorb(escalated, Array(tickets.suffix(escalated.count)))
        }
    }

    // Wall clock of the whole cold round, escalation included: the escalation is part of what the
    // grid waited for, so hiding it would make the p50 look better than the user's experience.
    let coldWall = (CFAbsoluteTimeGetCurrent() - coldStart) * 1000
    let coldStats = service.stats()

    /// The key each asset finally resolved to (the escalated `graph` key when auto escalated, or the
    /// original one). The hot round must re-request *these*, or it would re-ask a key that is known
    /// to be unservable and report a miss no user would ever see.
    var resolvedSpec: [String: ThumbRequestSpec] = [:]
    for item in specs { resolvedSpec[item.asset.contentHash] = item.spec }
    for item in escalated { resolvedSpec[item.asset.contentHash] = item.spec }

    // MARK: samples

    var samples: [ThumbSample] = []
    var coldTimes: [Double] = [], producedTimes: [Double] = []
    var generated = 0, skipped = 0, cancelled = 0
    let specByHash = Dictionary(specs.map { ($0.asset.contentHash, $0) },
                                uniquingKeysWith: { first, _ in first })

    for asset in assets {
        guard let item = specByHash[asset.contentHash] else {
            samples.append(ThumbSample(file: asset.filename, contentHash: asset.contentHash, ext: asset.ext,
                                       pipeline: strategy == .graph ? "graph" : "preview",
                                       source: "skipped", note: "file missing", sourceEdge: 0,
                                       outW: 0, outH: 0, coldMs: 0, producedMs: 0, hotMs: 0,
                                       bytes: 0, coldHit: false, hotHit: false))
            skipped += 1
            continue
        }
        var s = ThumbSample(file: asset.filename, contentHash: asset.contentHash, ext: asset.ext,
                            pipeline: item.spec.key.pipeline.rawValue, source: "skipped", note: nil,
                            sourceEdge: 0, outW: 0, outH: 0, coldMs: 0, producedMs: 0, hotMs: 0,
                            bytes: 0, coldHit: false, hotHit: false)

        guard let result = resultByAsset[asset.contentHash] else {
            s.note = "no result"; skipped += 1; samples.append(s); continue
        }
        s.pipeline = result.pipeline.rawValue
        s.sourceEdge = result.sourceLongEdge
        switch result.origin {
        case .hit:
            s.coldHit = true; s.source = "cache"; s.coldMs = result.waitedMilliseconds
        case .generated:
            s.source = result.source ?? result.pipeline.rawValue
            s.coldMs = result.waitedMilliseconds
            s.producedMs = result.producedMilliseconds
            coldTimes.append(result.waitedMilliseconds)
            producedTimes.append(result.producedMilliseconds)
            generated += 1
        case .cancelled:
            s.source = "skipped"; s.note = "cancelled"; cancelled += 1
        case .failed:
            s.source = "skipped"; s.note = result.error; skipped += 1
        }

        let file = cache.url(for: result.key)
        if let size = jpegSize(file) { s.outW = size.w; s.outH = size.h }
        if let data = try? Data(contentsOf: file) {
            s.bytes = data.count
            // Written where a human can look at it; the cache is the real product.
            let outName = "\(asset.filename.replacingOccurrences(of: ".", with: "-"))-\(tier.rawValue)-"
                + "\(result.pipeline.rawValue).jpg"
            try? data.write(to: outDir.appendingPathComponent(outName), options: .atomic)
        }
        samples.append(s)
    }

    // MARK: hot round (same keys, now from disk)

    // Reset both layers so the hot numbers describe the hot round alone: service queueing and cache
    // misses must be attributable, or "hitRatio == 1.000" means nothing (§7 #1).
    let coldCacheStats = cache.stats()
    service.resetStats()
    cache.resetStats()
    let hotItems = specs.compactMap { item -> (asset: Asset, spec: ThumbRequestSpec)? in
        guard let spec = resolvedSpec[item.asset.contentHash] else { return nil }
        return (item.asset, spec)
    }
    let hotTickets = enqueue(hotItems, prefix: "hot")
    _ = service.waitUntilIdle(timeout: 3600)
    var hotTimes: [Double] = []
    for (i, item) in hotItems.enumerated() where i < hotTickets.count {
        guard let result = service.result(for: hotTickets[i]) else { continue }
        hotTimes.append(result.waitedMilliseconds)
        if let idx = samples.firstIndex(where: { $0.contentHash == item.asset.contentHash }) {
            samples[idx].hotMs = result.waitedMilliseconds
            samples[idx].hotHit = result.origin == .hit
        }
    }
    let hotStats = service.stats()
    let hotCacheStats = cache.stats()

    let coldHits = samples.filter { $0.coldHit }.count
    let hotHits = samples.filter { $0.hotHit }.count
    let counted = max(1, samples.count)
    let report = ThumbsReport(
        library: catalog.layout.packageURL.path,
        tier: tier.rawValue, tierPixels: tier.longEdge, strategy: strategy.rawValue,
        assets: assets.count, visible: visibleCount, concurrency: concurrency,
        generated: generated, skipped: skipped, cancelled: cancelled,
        coldHitRatio: Double(coldHits) / Double(counted),
        hotHitRatio: Double(hotHits) / Double(counted),
        coldP50: median(coldTimes), coldP95: percentile(coldTimes, 0.95),
        producedP50: median(producedTimes), producedP95: percentile(producedTimes, 0.95),
        hotP50: median(hotTimes), hotP95: percentile(hotTimes, 0.95),
        totalBytes: cache.totalBytes(),
        samples: samples,
        missedReasons: hotCacheStats.missReasons,
        service: ThumbServiceReport(coldStats),
        hotService: ThumbServiceReport(hotStats),
        graphVersion: ThumbRecipe.graphVersion,
        rebuilt: coldStats.rebuilt,
        sweep: cache.versionSweep.summary)

    if a.has("--json") {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        print(String(data: try enc.encode(report), encoding: .utf8) ?? "{}")
    } else {
        note("library    \(report.library)")
        note("tier       \(tier.rawValue) (\(tier.longEdge) px long edge)")
        note("strategy   \(strategy.label)")
        // P1f: which arithmetic wrote the files, and whether this run had to replace them.
        note("version    \(report.graphVersion)  \(report.sweep)")
        note("cache      \(cache.root.path)")
        note("assets     \(assets.count)  generated \(generated)  skipped \(skipped)"
             + "  cancelled \(cancelled)  missingFile \(missingFiles)"
             + "  visible \(min(visibleCount, specs.count))  workers \(concurrency)")
        note(String(format: "cold       p50 %.1f ms  p95 %.1f ms  hit %.3f  (wall %.1f ms, render p50 %.1f p95 %.1f)",
                    report.coldP50, report.coldP95, report.coldHitRatio, coldWall,
                    report.producedP50, report.producedP95))
        note(String(format: "hot        p50 %.1f ms  p95 %.1f ms  hit %.3f",
                    report.hotP50, report.hotP95, report.hotHitRatio))
        note(String(format: "cache size %.2f MB", Double(report.totalBytes) / 1e6))
        if wantReport {
            note("")
            note("— service layer (cold round) —")
            note(report.service.summaryLine)
            note(report.service.queueLine)
            if report.service.rejectedWhilePaused + report.service.droppedStaleGeneration
                + report.service.rejectedByDepth > 0 {
                note("rejected   paused \(report.service.rejectedWhilePaused)"
                     + "  staleGen \(report.service.droppedStaleGeneration)"
                     + "  depth \(report.service.rejectedByDepth)")
            }
            note("— service layer (hot round) —")
            note(report.hotService.summaryLine)
            note(report.hotService.queueLine)
        }
        if !report.missedReasons.isEmpty {
            let s = report.missedReasons.sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
            note("misses     \(s)")
        }
        note("")
        note("  file                              key            source     srcEdge  out px    cold    build     hot")
        for s in samples {
            let src = s.sourceEdge == 0 ? "-" : String(s.sourceEdge)
            let out = "\(s.outW)×\(s.outH)"
            let cold = s.coldHit ? "   hit" : String(format: "%6.1f", s.coldMs)
            let build = s.producedMs == 0 ? "     -" : String(format: "%6.1f", s.producedMs)
            let hot = s.hotHit ? String(format: "%6.1f", s.hotMs) : "  miss"
            note("  \(pad(s.file, 33)) \(pad(s.pipeline, 14)) \(pad(s.source, 10)) \(pad(src, 8))"
                 + " \(pad(out, 9)) \(cold) \(build) \(hot)" + (s.note.map { "  · \($0)" } ?? ""))
        }
    }

    // A corrupt entry is a hard failure (#1: only `absent` is an acceptable miss reason).
    if (hotCacheStats.missReasons["corrupt"] ?? 0) > 0 || (coldCacheStats.missReasons["corrupt"] ?? 0) > 0 {
        exit(1)
    }
}

// MARK: - helpers

private func jpegSize(_ url: URL) -> (w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}

private func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
}
