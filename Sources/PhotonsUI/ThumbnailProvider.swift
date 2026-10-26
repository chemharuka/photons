import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PhotonsCatalog
import PhotonsCore
import PhotonsExport

// MARK: - request token

/// One cell's outstanding thumbnail load.
///
/// Queueing, single-flight, priority and cancellation are *not* here any more: they belong to
/// `ThumbnailService` (single-flight per `(contentHash, tier)`, priority order, concurrency ceiling 3,
/// `generation`-based cancellation) and there is exactly one of those per
/// library. This token is the UI-facing half of a request — the item index a scroll handler can
/// match against the visible window, the cache key that was actually asked for (after the tier
/// policy), and the cancellation counter `--ui-smoke` reads.
public final class ThumbnailRequest {
    public let index: Int
    /// The key the request was served under — **after** `ThumbnailProvider.effectiveTier`, so a
    /// `t1024` request for a DNG shows up here as `t512` (006 §6.1).
    public let key: ThumbKey

    fileprivate let state: RequestState
    private let ticket: ThumbTicket?
    private weak var provider: ThumbnailProvider?

    init(index: Int, key: ThumbKey, ticket: ThumbTicket?, provider: ThumbnailProvider?,
         state: RequestState = RequestState()) {
        self.index = index
        self.key = key
        self.ticket = ticket
        self.provider = provider
        self.state = state
    }

    public var isCancelled: Bool { state.isCancelled }

    /// `true` once the request delivered (an image or a definitive nil). A finished request is not
    /// counted as cancelled: its `applied`/`failures` increment already landed, and counting both
    /// would make `requests − applied − failures` drift negative on the one-runloop overlap.
    public var isFinished: Bool { state.isFinished }

    /// Idempotent, safe from any thread. Cancelling unsubscribes this caller from the service job;
    /// when it was the last subscriber the job is dequeued (or, if the producer already started,
    /// its bytes are dropped — §5).
    public func cancel() {
        guard state.markCancelled() else { return }
        provider?.note { $0.cancelled += 1 }
        ticket?.cancel()
    }
}

/// Shared, lock-protected flags between a token and the completion closure the service calls.
final class RequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    /// `true` only the first time, and only if the request had not already delivered.
    func markCancelled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        cancelled = true
        return !finished
    }

    func markFinished() {
        lock.lock(); finished = true; lock.unlock()
    }
}

// MARK: - provider

/// The grid's and the filmstrip's thumbnail source: one memory LRU in front of one
/// `ThumbnailService`, which owns the queue, the single-flight map, cancellation and the
/// concurrency ceiling.
///
/// Layers, in the order a cell asks for them — memory, then the content-addressed file on disk, then a
/// freshly generated one:
///
/// 1. **memory** — `NSCache` keyed by `ThumbKey.digest`, 512 images / 96 MB, cost = w·h·4. A cell
///    that scrolls back into view is answered synchronously, with no file I/O and no queue hop.
/// 2. **service** — which is itself disk→generate: the content-addressed JPEG in
///    `~/Library/Caches/Photons/<libHash>/thumbs/`, or the P path producing a new one.
/// 3. **generate** — `produce(_:source:)` rides through ImageIO on a RAW's *embedded* preview
///    (never a RAW decode, §0) or ImageIO's own downscale for a file that already is a JPEG. The
///    service writes the bytes; the producer never touches the disk cache.
///
/// This type is therefore a **producer adapter**, not a scheduler: it has no `OperationQueue`
/// (the 006 §4 "两套队列" bug), and two views share one instance through `shared(for:)` so a grid
/// cell and a filmstrip cell asking for the same `contentHash` join one job and hit one LRU.
///
/// Failures never throw out of `request` and never clear a cell: the caller keeps drawing its
/// placeholder. That is the difference between "no thumbnail yet" and "a white hole in the grid".
public final class ThumbnailProvider: @unchecked Sendable {

    /// Where a delivered image came from. `memory`/`disk` are *hits*; `generated` is not.
    public enum Source: String, Sendable {
        case memory
        case disk
        case generated
    }

    public struct Stats: Sendable {
        public var requests = 0
        public var memoryHits = 0
        public var diskHits = 0
        public var generated = 0
        public var failures = 0
        public var cancelled = 0
        /// Images actually handed to a cell.
        public var applied = 0
        /// Policy downgrades by reason (`dngCeiling`), 006 §6.1. Printed, not estimated.
        public var skipReasons: [String: Int] = [:]

        public var cacheHits: Int { memoryHits + diskHits }
        public var lookups: Int { memoryHits + diskHits + generated }
        /// Share of lookups served without producing anything (the acceptance number in 006 §7 #1).
        public var hitRatio: Double { lookups == 0 ? 0 : Double(cacheHits) / Double(lookups) }

        public var skipSummary: String {
            guard !skipReasons.isEmpty else { return "skip -" }
            let parts = skipReasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            return "skip " + parts.joined(separator: " ")
        }

        public var summary: String {
            String(format: "requests %d · applied %d · memory %d · disk %d · generated %d · failed %d · cancelled %d · hit %.3f",
                   requests, applied, memoryHits, diskHits, generated, failures, cancelled, hitRatio)
        }
    }

    /// 006 §1 asks for a 32 MB window-sized LRU; the brief sets the floor at 512 images / 96 MB.
    /// Both are enforced: `NSCache` evicts on whichever limit trips first.
    public static let memoryCountLimit = 512
    public static let memoryByteLimit = 96 * 1024 * 1024
    /// 006 §4 "并发上限 3" — handed to the service, which is the only thing that schedules.
    public static let defaultConcurrency = 3

    public let cache: ThumbnailCache
    /// The one scheduler. Public so a probe can read `stats()`/`pendingCount`; no view should
    /// enqueue into it directly (they go through `request`, which also feeds the memory layer).
    public let service: ThumbnailService

    private let memory = NSCache<NSString, ImageBox>()
    /// `ThumbnailService` holds its producer strongly, so the adapter holds the provider weakly:
    /// that is what keeps provider ↔ service from being a retain cycle.
    private let adapter: ProducerAdapter
    private let lock = NSLock()
    private var counters = Stats()
    /// Producer runs per cache key. Exactly one for every key that exists: single-flight plus the
    /// disk cache, measured rather than assumed (006 §4 单飞).
    private var runsPerKey: [String: Int] = [:]
    /// Producer runs per contentHash — the grid + filmstrip "generated once" assertion.
    private var runsPerContent: [String: Int] = [:]
    private var decoder: RAWDecoder?
    private var decoderUnavailable = false

    public init(cache: ThumbnailCache, maxConcurrent: Int = ThumbnailProvider.defaultConcurrency) {
        let adapter = ProducerAdapter()
        self.cache = cache
        self.adapter = adapter
        self.service = ThumbnailService(cache: cache,
                                        config: .init(maxConcurrency: maxConcurrent),
                                        producer: adapter)
        memory.countLimit = ThumbnailProvider.memoryCountLimit
        memory.totalCostLimit = ThumbnailProvider.memoryByteLimit
        adapter.provider = self
    }

    // MARK: - one instance per cache

    private final class WeakProvider {
        weak var value: ThumbnailProvider?
        init(value: ThumbnailProvider?) { self.value = value }
    }

    private static let registryLock = NSLock()
    private static var registry: [WeakProvider] = []

    /// The process-wide provider for a library's cache. The grid and the filmstrip both ask for
    /// this, which is how they end up on one `ThumbnailService` and one memory LRU (a grid cell and
    /// a filmstrip cell for the same `contentHash`/tier must not become two jobs — 006 §4 单飞).
    ///
    /// Weak on purpose: closing a library drops the last reference and the provider (and its
    /// queue) goes away with it.
    public static func shared(for cache: ThumbnailCache,
                              maxConcurrent: Int = ThumbnailProvider.defaultConcurrency) -> ThumbnailProvider {
        registryLock.lock()
        defer { registryLock.unlock() }
        registry.removeAll { $0.value == nil }
        for box in registry {
            if let existing = box.value, existing.cache === cache { return existing }
        }
        let made = ThumbnailProvider(cache: cache, maxConcurrent: maxConcurrent)
        registry.append(WeakProvider(value: made))
        return made
    }

    // MARK: - tier selection (006 §1, §6.1)

    /// `px = ceil(cellEdgePt × backingScale)`, then the smallest tier covering it — but never a tier
    /// the source cannot fill. Asking a 320 px JPEG for `t512` would mean writing an upscaled file
    /// under a `t512` key, which is exactly the "looks detailed" lie §1 forbids; clamping the *tier*
    /// instead keeps the key honest and Core Graphics does the on-screen scaling.
    public static func tier(cellEdgePoints: CGFloat, backingScale: CGFloat, sourceLongEdge: Int?) -> ThumbTier {
        let requested = ThumbTier.forPoints(Double(max(1, cellEdgePoints)),
                                           backingScale: Double(max(1, backingScale)))
        guard let sourceLongEdge, sourceLongEdge > 0 else { return requested }
        // Largest tier whose long edge still fits inside the source (floor, not ceil).
        let cap = ThumbTier.allCases.last { $0.longEdge <= sourceLongEdge } ?? .t256
        return cap.rank < requested.rank ? cap : requested
    }

    public static func sourceLongEdge(of asset: Asset) -> Int? {
        guard let w = asset.width, let h = asset.height, w > 0, h > 0 else { return nil }
        return max(w, h)
    }

    /// The tier a request may actually use, and the reason when it was lowered.
    ///
    /// Only one rule lives here today, and it is §6.1: a DNG's embedded preview is Adobe's
    /// rendering, so it is **never** accepted above `ThumbPolicy.dngPreviewMaxTier` (t512) —
    /// "用 Adobe 的观感充当我们的首屏大图" is exactly what the tier above that would be. The
    /// downgrade is counted as `skipReason= dngCeiling` instead of silently returning a smaller
    /// image, so a report can prove the policy ran.
    public static func effectiveTier(requested: ThumbTier, ext: String) -> (tier: ThumbTier, skipReason: String?) {
        guard ext.lowercased() == "dng" else { return (requested, nil) }
        let limit = ThumbPolicy.dngPreviewMaxTier
        guard requested.rank > limit.rank else { return (requested, nil) }
        return (limit, "dngCeiling")
    }

    // MARK: - memory layer

    public func memoryImage(for key: ThumbKey) -> CGImage? {
        memory.object(forKey: key.digest as NSString)?.image
    }

    public func memoryImage(contentHash: String, tier: ThumbTier) -> CGImage? {
        memoryImage(for: .preview(contentHash: contentHash, tier: tier))
    }

    private func remember(_ image: CGImage, for key: ThumbKey) {
        let cost = max(1, image.width * image.height * 4)
        memory.setObject(ImageBox(image), forKey: key.digest as NSString, cost: cost)
    }

    // MARK: - loading

    /// Load a cell's thumbnail. `completion` always runs on the main actor and is skipped entirely
    /// for a cancelled request, so a stale image can never land in a recycled cell.
    ///
    /// `priority` is the service's scheduling input: `.onScreen` for the visible window and for the
    /// filmstrip's selected item, `.prefetch` for the one-row slack (§4 ①②③).
    @discardableResult
    public func request(index: Int,
                        asset: Asset,
                        fileURL: URL?,
                        tier: ThumbTier,
                        priority: ThumbPriority = .onScreen,
                        completion: @escaping @MainActor (Int, ThumbKey, CGImage?) -> Void) -> ThumbnailRequest {
        let plan = ThumbnailProvider.effectiveTier(requested: tier, ext: asset.ext)
        if let reason = plan.skipReason {
            note { $0.skipReasons[reason, default: 0] += 1 }
        }
        let key = ThumbKey.preview(contentHash: asset.contentHash, tier: plan.tier)

        // 1. memory. Synchronous, so a cell that scrolls back into view draws in the same frame.
        if let hit = memoryImage(for: key) {
            note { $0.requests += 1; $0.memoryHits += 1; $0.applied += 1 }
            let token = ThumbnailRequest(index: index, key: key, ticket: nil, provider: self)
            token.state.markFinished()
            DispatchQueue.main.async { completion(index, key, hit) }
            return token
        }

        note { $0.requests += 1 }
        guard let fileURL else {
            // Offline root / missing file: a definitive "no image", not a hang.
            note { $0.failures += 1 }
            let token = ThumbnailRequest(index: index, key: key, ticket: nil, provider: self)
            token.state.markFinished()
            DispatchQueue.main.async { completion(index, key, nil) }
            return token
        }

        // 2. the service: disk hit, or a producer run shared with whoever else asks for this key.
        let state = RequestState()
        let spec = ThumbRequestSpec(key: key, source: fileURL)
        let ticket = service.request(spec, priority: priority) { [weak self] result in
            self?.deliver(result, index: index, state: state, completion: completion)
        }
        return ThumbnailRequest(index: index, key: key, ticket: ticket, provider: self, state: state)
    }

    /// Synchronous memory hit for a cell being configured — counted, so the acceptance harness can
    /// distinguish "served from the LRU" from "regenerated the same image".
    public func serveFromMemory(for key: ThumbKey) -> CGImage? {
        guard let hit = memoryImage(for: key) else { return nil }
        note { $0.requests += 1; $0.memoryHits += 1; $0.applied += 1 }
        return hit
    }

    /// Work the service has queued *or* running. Exposed so `--ui-smoke` can assert the queue does
    /// not grow with the library (§5: "队列峰值 ≤ 预取窗口的 2 倍").
    public var queueDepth: Int { service.pendingCount + service.stats().active }

    /// Runs on a service worker. Books the delivery and hands the decoded image to the main thread.
    private func deliver(_ result: ThumbResult, index: Int, state: RequestState,
                         completion: @escaping @MainActor (Int, ThumbKey, CGImage?) -> Void) {
        state.markFinished()
        switch result.origin {
        case .hit: note { $0.diskHits += 1 }
        case .generated: note { $0.generated += 1 }
        case .failed: note { $0.failures += 1 }
        case .cancelled: note { $0.cancelled += 1 }
        }
        guard let data = result.data, let image = ThumbnailCache.decode(data) else {
            DispatchQueue.main.async { completion(index, result.key, nil) }
            return
        }
        remember(image, for: result.key)
        note { $0.applied += 1 }
        DispatchQueue.main.async { completion(index, result.key, image) }
    }

    // MARK: - producer

    /// The `ThumbnailProducer` the service calls. Several workers may call this at once.
    public func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
        let ext = source.pathExtension
        // Defensive second line of defence: the request path clamps first (`effectiveTier`), but a
        // producer must never write an over-ceiling file even if someone enqueues a raw key.
        guard key.tier.rank <= ThumbPolicy.previewTierLimit(ext: ext).rank else {
            throw ThumbProviderError.tierAboveCeiling(tier: key.tier,
                                                      limit: ThumbPolicy.previewTierLimit(ext: ext),
                                                      ext: ext)
        }
        guard key.pipeline == .preview else {
            throw ThumbProviderError.unsupportedPipeline(key.pipeline)
        }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ThumbProviderError.unreadable(source)
        }

        let kind = AssetKind.detect(ext) ?? .jpeg
        var provenance = "imageio"
        var sourceEdge = 0
        let embedded: CGImage?
        if kind == .raw {
            // The camera's own embedded JPEG is the default (§11.2, and the user decision: "显示导入
            // RAW 时的内嵌 jpg"): ImageIO first because it is 2.6× faster than building a
            // `CIRAWFilter`, then the filter for files ImageIO cannot thumbnail, and only then a
            // **real render** at a coarse decode scale for files that carry no preview at all —
            // such a file would otherwise sit in the grid as a coloured placeholder forever.
            guard let decoder = rawDecoder() else { throw ThumbProviderError.noRAWDecoder }
            if let outcome = decoder.preview(source, maxPixelSize: key.tier.longEdge, strategy: .thumbnail) {
                embedded = outcome.image
                provenance = "embedded"
                sourceEdge = outcome.sourceLongEdge
            } else if let outcome = decoder.preview(source, maxPixelSize: key.tier.longEdge, strategy: .filter) {
                embedded = outcome.image
                provenance = "filter"
                sourceEdge = outcome.sourceLongEdge
            } else {
                embedded = renderedThumbnail(decoder, url: source, longEdge: key.tier.longEdge,
                                             identity: key.digest)
                provenance = "graph"
            }
        } else {
            // The file already is a rendered JPEG/HEIC: ImageIO's own downscale *is* the fast path,
            // and `CreateThumbnailFromImageIfAbsent` is what lets it use the DCT-scaled decoder.
            embedded = ThumbnailProvider.imageIOThumbnail(source, maxPixelSize: key.tier.longEdge)
        }
        guard let embedded else {
            throw ThumbProviderError.noPreview(source, tier: key.tier)
        }
        // One colour space for every thumbnail: 8-bit sRGB (§1). An AdobeRGB camera JPEG drawn
        // straight into the grid is a whole-grid colour shift.
        guard let normalised = ThumbnailProvider.sRGB8(embedded) else {
            throw ThumbProviderError.encodeFailed(source)
        }
        guard let data = ThumbnailJPEG.encode(normalised) else {
            throw ThumbProviderError.encodeFailed(source)
        }
        lock.lock()
        runsPerKey[key.digest, default: 0] += 1
        runsPerContent[key.contentHash, default: 0] += 1
        lock.unlock()
        return ThumbPayload(data: data,
                            source: provenance,
                            sourceLongEdge: max(sourceEdge, max(normalised.width, normalised.height)))
    }

    /// Last resort for a RAW with no usable embedded preview: one coarse decode plus one frame of
    /// the real graph (D12 — never a second renderer), sized to the tier.
    ///
    /// Only files that carry no camera JPEG take this path, so the ~0.3 s it costs for a 60 MP file
    /// is paid once per such file, not per scroll.
    private func renderedThumbnail(_ decoder: RAWDecoder, url: URL, longEdge: Int,
                                   identity: String) -> CGImage? {
        guard let scaled = try? decoder.decode(url, options: DecodeOptions(scale: 0.25)),
              let graph = try? RenderGraph(input: RenderInput(image: scaled, identity: identity,
                                                              sourceURL: url)) else { return nil }
        let w = Double(scaled.width), h = Double(scaled.height)
        let s = min(1, Double(longEdge) / max(w, h, 1))
        let canvas = ImageSize(width: max(1, Int((w * s).rounded())),
                               height: max(1, Int((h * s).rounded())))
        let options = RenderOptions(canvas: canvas, scale: 1,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: 8),
                                    useCache: false, wantsPixels: true)
        guard let display = (try? graph.render(.neutral, options: options))?.display,
              let cg = try? Exporter.cgImage(display, bitDepth: 8) else { return nil }
        return cg
    }

    private func rawDecoder() -> RAWDecoder? {
        lock.lock()
        if let decoder { lock.unlock(); return decoder }
        if decoderUnavailable { lock.unlock(); return nil }
        lock.unlock()
        do {
            let made = try RAWDecoder()
            lock.lock(); decoder = made; lock.unlock()
            return made
        } catch {
            lock.lock(); decoderUnavailable = true; lock.unlock()
            return nil
        }
    }

    // MARK: - stats

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    /// Producer runs per cache key (digest → count). Every value should be 1: a key generated twice
    /// means single-flight or the disk cache leaked work.
    public var generationCounts: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return runsPerKey
    }

    /// Producer runs per `contentHash`. The grid + filmstrip assertion (one file, one job).
    public var generationsPerContent: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return runsPerContent
    }

    /// The service's own counters (requests, coalesced, hits, generated, cancelled, waits).
    public var serviceStats: ThumbnailService.Stats { service.stats() }

    public func resetStats() {
        lock.lock(); counters = Stats(); lock.unlock()
        service.resetStats()
    }

    public func note(_ mutate: (inout Stats) -> Void) {
        lock.lock(); mutate(&counters); lock.unlock()
    }

    // `runsPerKey`/`runsPerContent` live outside `Stats` (which is a value type copied into
    // `note` closures) but under the same lock, so the counters and the per-key map never disagree.

    // MARK: - helpers

    static func imageIOThumbnail(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0, let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    /// Redraw into an 8-bit sRGB bitmap. Overwhelmingly the cheap path — a 256–512 px draw.
    static func sRGB8(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private final class ImageBox: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    /// Keeps `ThumbnailService`'s strong `producer` from retaining the provider (and through it the
    /// service): the adapter is the service's producer, the provider is only weakly behind it.
    private final class ProducerAdapter: ThumbnailProducer {
        weak var provider: ThumbnailProvider?

        func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
            guard let provider else {
                throw ThumbServiceError.noProducer(key)
            }
            return try provider.produce(key, source: source)
        }
    }
}

// MARK: - errors

/// Producer-side failures. Every one of them is a *normal* state for a grid cell (006 §2 "失败与
/// 超时"): the service records `origin: failed`, the cell keeps its placeholder, and nothing retries
/// in a loop.
public enum ThumbProviderError: LocalizedError {
    case noPreview(URL, tier: ThumbTier)
    case unreadable(URL)
    case noRAWDecoder
    case tierAboveCeiling(tier: ThumbTier, limit: ThumbTier, ext: String)
    case unsupportedPipeline(ThumbPipeline)
    case encodeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .noPreview(let url, let tier):
            return "no embedded preview for \(url.lastPathComponent) at \(tier.rawValue)"
        case .unreadable(let url):
            return "cannot read \(url.lastPathComponent)"
        case .noRAWDecoder:
            return "CIRAWFilter is unavailable on this machine"
        case .tierAboveCeiling(let tier, let limit, let ext):
            return "\(ext) preview ceiling is \(limit.rawValue); refusing \(tier.rawValue)"
        case .unsupportedPipeline(let pipeline):
            return "no producer for pipeline \(pipeline.rawValue)"
        case .encodeFailed(let url):
            return "could not encode a thumbnail for \(url.lastPathComponent)"
        }
    }
}
