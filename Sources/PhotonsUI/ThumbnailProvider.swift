import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import PhotonsCatalog
import PhotonsCore
import PhotonsExport
import QuartzCore

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
/// 1. **memory** — `NSCache` keyed by `ThumbKey.digest` + display pixels, 512 images / 256 MB,
///    cost = w·h·8 (a half-float RGBA bitmap). A cell that scrolls back into view is answered
///    synchronously, with no file I/O and no queue hop.
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
        /// 218 — image decodes performed inside `deliver`. A 200-cell grid where every cell is served
        /// from the memory LRU must leave this at 0; it is the measurement behind "全部命中时零解码".
        public var decodes = 0
        /// 223 — decodes that used ImageIO's **whole-image** door
        /// (`CGImageSourceCreateImageAtIndex`). The HD HEIC path must leave this at 0; only the
        /// legacy JPEG ladder may use it.
        public var imageIOWholeDecodes = 0
        /// 223 — decodes that used ImageIO's **thumbnail** door
        /// (`CGImageSourceCreateThumbnailAtIndex`). Also 0 for every HD cell: HEIC pixels come from
        /// Core Image → Metal, never from ImageIO.
        public var imageIOThumbnailDecodes = 0
        /// 223 — decodes that went through Core Image → `MTLTexture` (the HD HEIC path).
        public var gpuDecodes = 0
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
            String(format: "requests %d · applied %d · memory %d · disk %d · generated %d · failed %d · cancelled %d · decode %d · gpu %d · hit %.3f",
                   requests, applied, memoryHits, diskHits, generated, failures, cancelled, decodes,
                   gpuDecodes, hitRatio)
        }
    }

    /// 006 §1 asks for a 32 MB window-sized LRU; the brief sets the floor at 512 images / 96 MB.
    /// 223 raises the byte ceiling to 256 MB: a half-float display bitmap is 8 bytes per pixel, so
    /// 200 grid cells at 326×242 are ~126 MB — an acceptance that says "the second switch decodes
    /// nothing" cannot be met by a 96 MB cache that evicts a quarter of them.
    /// Both limits are enforced: `NSCache` evicts on whichever limit trips first.
    public static let memoryCountLimit = 512
    public static let memoryByteLimit = 256 * 1024 * 1024
    /// 006 §4 "并发上限 3" — handed to the service, which is the only thing that schedules.
    public static let defaultConcurrency = 3

    public let cache: ThumbnailCache
    /// The one scheduler. Public so a probe can read `stats()`/`pendingCount`; no view should
    /// enqueue into it directly (they go through `request`, which also feeds the memory layer).
    public let service: ThumbnailService

    private let memory = NSCache<NSString, ImageBox>()
    /// 218 — the last HD image delivered per content hash. A commit changes the key, so the new key
    /// is a miss by definition; this is what the cell draws while the rebuild runs ("先显示旧缩略图").
    /// Deliberately small: it is a placeholder cache, not a second thumbnail LRU.
    private let recent = NSCache<NSString, ImageBox>()
    /// The documents behind in-flight HD keys. `ThumbnailProducer` only receives a key and a source
    /// URL, so the edit itself has to ride here from `request` to `produce`. 223 — bounded: this is
    /// a hand-off, not a second store of the library.
    private var documentsByKey: [String: EditModel] = [:]
    private var documentOrder: [String] = []
    /// 223 — digest → the display size its bitmap was last stored at (the back-compat lookup).
    private var displaySizesByDigest: [String: ImageSize] = [:]
    private var displaySizeOrder: [String] = []
    /// Ceiling for the two bookkeeping maps above (`documentsByKey`, `displaySizesByDigest`).
    static let indexLimit = 4096
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
        recent.countLimit = 64
        recent.totalCostLimit = 32 * 1024 * 1024
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

    // MARK: - memory layer (223: keyed by content key **and** display pixels)

    /// The memory layer holds **display-sized** bitmaps only. Two cells of the same photo on the
    /// same screen share one entry; the grid, the filmstrip and the list do not, because their
    /// swatches are different sizes and resampling a 326 px grid bitmap down to 68 px would be both
    /// soft and a lie about which size was decoded.
    static func memoryKey(_ key: ThumbKey, display: ImageSize) -> NSString {
        "\(key.digest)|\(display.width)x\(display.height)" as NSString
    }

    static func recentKey(_ contentHash: String, display: ImageSize) -> NSString {
        "\(contentHash)|\(display.width)x\(display.height)" as NSString
    }

    public func memoryImage(for key: ThumbKey, display: ImageSize? = nil) -> CGImage? {
        if let display {
            return memory.object(forKey: ThumbnailProvider.memoryKey(key, display: display))?.image
        }
        // Back-compat for callers that only know the content key (the sort-order probe): remember
        // the last display size each digest was stored at and ask for that one.
        guard let last = lastDisplaySize(for: key.digest) else { return nil }
        return memory.object(forKey: ThumbnailProvider.memoryKey(key, display: last))?.image
    }

    public func memoryImage(contentHash: String, tier: ThumbTier) -> CGImage? {
        memoryImage(for: .preview(contentHash: contentHash, tier: tier))
    }

    /// 218 — the previous rendering of a photo, for the one frame between a commit's cache miss and
    /// the rebuilt file. Never counted as a cache hit: it is explicitly *not* the requested key.
    public func placeholderImage(contentHash: String, display: ImageSize? = nil) -> CGImage? {
        let pixels = display ?? ImageSize(width: 256, height: 256)
        return recent.object(forKey: ThumbnailProvider.recentKey(contentHash, display: pixels))?.image
    }

    private func remember(_ image: CGImage, for key: ThumbKey, display: ImageSize) {
        // A float RGBA bitmap is 8 bytes per pixel; the old cost (4) under-counted the EDR form.
        let cost = max(1, image.width * image.height * 8)
        memory.setObject(ImageBox(image),
                         forKey: ThumbnailProvider.memoryKey(key, display: display), cost: cost)
        lock.lock()
        rememberDisplaySize(display, for: key.digest)
        lock.unlock()
        if key.spec == .hd {
            recent.setObject(ImageBox(image),
                             forKey: ThumbnailProvider.recentKey(key.contentHash, display: display),
                             cost: cost)
        }
    }

    /// digest → the display size it was last remembered at. Tiny (one entry per asset), bounded by
    /// the same FIFO as `documentsByKey` so a 10k-photo library cannot grow it without limit.
    private func rememberDisplaySize(_ display: ImageSize, for digest: String) {
        if displaySizesByDigest[digest] == nil { displaySizeOrder.append(digest) }
        displaySizesByDigest[digest] = display
        while displaySizeOrder.count > ThumbnailProvider.indexLimit {
            displaySizesByDigest.removeValue(forKey: displaySizeOrder.removeFirst())
        }
    }

    private func lastDisplaySize(for digest: String) -> ImageSize? {
        lock.lock(); defer { lock.unlock() }
        return displaySizesByDigest[digest]
    }

    // MARK: - key selection (218)

    /// The document a thumbnail must be rendered from: the live document for the anchor photo, the
    /// persisted `develop_json` for every other row. A damaged blob reads as `.neutral`, exactly like
    /// `Catalog.develop(forAsset:)` (never crash the grid on one bad row).
    public static func document(from asset: Asset) -> EditModel {
        guard let data = asset.developJson.data(using: .utf8),
              let model = try? JSONDecoder().decode(EditModel.self, from: data) else { return .neutral }
        return model
    }

    /// The shared HD key. The grid, the browser list and the filmstrip all call this, which is the
    /// whole of "三处同源": same content hash + same document ⇒ same key ⇒ same cache file.
    public static func hdKey(for asset: Asset, document: EditModel? = nil) -> ThumbKey {
        .hd(contentHash: asset.contentHash,
            document: document ?? ThumbnailProvider.document(from: asset))
    }

    /// 223 — the pixel rectangle a cell actually shows, from its layout size in points and the
    /// window's backing scale. One helper: the grid, the filmstrip and the list must not each round
    /// differently, or the memory key would never be hit twice.
    public static func displayPixels(swatch: CGSize, backingScale: CGFloat) -> ImageSize {
        let scale = max(1, backingScale)
        return ImageSize(width: max(1, Int((max(1, swatch.width) * scale).rounded())),
                         height: max(1, Int((max(1, swatch.height) * scale).rounded())))
    }

    private func rememberDocument(_ document: EditModel, for digest: String) {
        lock.lock(); defer { lock.unlock() }
        if documentsByKey[digest] == nil { documentOrder.append(digest) }
        documentsByKey[digest] = document
        while documentOrder.count > ThumbnailProvider.indexLimit {
            documentsByKey.removeValue(forKey: documentOrder.removeFirst())
        }
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
                        document: EditModel? = nil,
                        tier: ThumbTier,
                        spec: ThumbSpec = .legacy,
                        display: ImageSize? = nil,
                        priority: ThumbPriority = .onScreen,
                        completion: @escaping @MainActor (Int, ThumbKey, CGImage?) -> Void) -> ThumbnailRequest {
        let pixels = display ?? ImageSize(width: 512, height: 512)
        let key: ThumbKey
        if spec == .hd {
            let doc = document ?? ThumbnailProvider.document(from: asset)
            key = ThumbKey.hd(contentHash: asset.contentHash, document: doc)
            rememberDocument(doc, for: key.digest)
        } else {
            let plan = ThumbnailProvider.effectiveTier(requested: tier, ext: asset.ext)
            if let reason = plan.skipReason {
                note { $0.skipReasons[reason, default: 0] += 1 }
            }
            key = ThumbKey.preview(contentHash: asset.contentHash, tier: plan.tier)
        }

        // 1. memory. Synchronous, so a cell that scrolls back into view draws in the same frame.
        // 223 — the key includes the display pixels: a grid bitmap is never handed to the list.
        if let hit = memoryImage(for: key, display: spec == .hd ? pixels : nil) {
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
            self?.deliver(result, index: index, state: state, display: pixels, completion: completion)
        }
        return ThumbnailRequest(index: index, key: key, ticket: ticket, provider: self, state: state)
    }

    /// Synchronous memory hit for a cell being configured — counted, so the acceptance harness can
    /// distinguish "served from the LRU" from "regenerated the same image".
    public func serveFromMemory(for key: ThumbKey, display: ImageSize? = nil) -> CGImage? {
        guard let hit = memoryImage(for: key, display: display) else { return nil }
        note { $0.requests += 1; $0.memoryHits += 1; $0.applied += 1 }
        return hit
    }

    /// Work the service has queued *or* running. Exposed so `--ui-smoke` can assert the queue does
    /// not grow with the library (§5: "队列峰值 ≤ 预取窗口的 2 倍").
    public var queueDepth: Int { service.pendingCount + service.stats().active }

    /// Runs on a service worker. Books the delivery and hands the decoded image to the main thread.
    private func deliver(_ result: ThumbResult, index: Int, state: RequestState, display: ImageSize,
                         completion: @escaping @MainActor (Int, ThumbKey, CGImage?) -> Void) {
        state.markFinished()
        switch result.origin {
        case .hit: note { $0.diskHits += 1 }
        case .generated: note { $0.generated += 1 }
        case .failed: note { $0.failures += 1 }
        case .cancelled: note { $0.cancelled += 1 }
        }
        guard let data = result.data else {
            DispatchQueue.main.async { completion(index, result.key, nil) }
            return
        }
        // 223 — the two decode doors are counted separately, so "the HEIC path used ImageIO" is a
        // number a test can refute rather than a claim in a comment.
        let image: CGImage?
        if result.key.spec == .hd {
            image = ThumbnailProvider.decodeHD(data, display: display)
            if image != nil { note { $0.gpuDecodes += 1 } }
        } else {
            image = ThumbnailCache.decode(data)
            if image != nil { note { $0.imageIOWholeDecodes += 1 } }
        }
        guard let image else {
            DispatchQueue.main.async { completion(index, result.key, nil) }
            return
        }
        note { $0.decodes += 1 }
        remember(image, for: result.key, display: display)
        note { $0.applied += 1 }
        DispatchQueue.main.async { completion(index, result.key, image) }
    }

    // MARK: - producer

    /// The `ThumbnailProducer` the service calls. Several workers may call this at once.
    public func produce(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
        if key.spec == .hd {
            return try produceHD(key, source: source)
        }
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
            if embedded != nil { note { $0.imageIOThumbnailDecodes += 1 } }
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

    // MARK: - HD thumbnail (218 → 223)

    /// Render one HD thumbnail: the **same** `RenderGraph` the loupe and the exporter use, at a
    /// scale whose long edge is at most 1920, then the existing PQ encoder
    /// (`HDREncoding.write`) with the four pinned parameters: Display P3 primaries, PQ curve,
    /// 10-bit HEIC, q0.75.
    ///
    /// One render, not two: unlike 218's gain-map base + auxiliary image, a PQ file *is* the
    /// extended-range picture, so the linear exit (`s4_display_linear` in P3) is the only frame
    /// needed. Reusing this door is what keeps "grid thumbnail == export preview" a fact instead of
    /// a claim — and it is why 223 does not add a second encoder.
    private func produceHD(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ThumbProviderError.unreadable(source)
        }
        guard let decoder = rawDecoder() else { throw ThumbProviderError.noRAWDecoder }
        let document: EditModel
        lock.lock(); document = documentsByKey[key.digest] ?? .neutral; lock.unlock()

        let longEdge = ThumbSpec.hd.longEdge
        // Decode no larger than needed for 1920 (a 60 MP RAW at 0.25 already covers it), and never
        // so small that the thumbnail has to upscale.
        let sourceEdge = ThumbnailProvider.sourceLongEdge(url: source) ?? longEdge
        let decodeScale = min(1, max(0.25, Double(longEdge) / Double(max(1, sourceEdge))))
        // The HD thumbnail is our own graph, so it must ask for the document's whole development:
        // version and detail are decode inputs too (the key's `editFingerprint` carries them, and
        // omitting them here would file a v8 picture under a v9 key).
        let inputs = document.decodeInputs
        let decoded = try decoder.decode(source, options: DecodeOptions(
            decoderVersion: inputs.decoderVersion,
            scale: Float(decodeScale),
            whiteBalance: inputs.whiteBalance,
            detail: inputs.detail))
        let w = decoded.width, h = decoded.height
        let scale = min(1, Double(longEdge) / Double(max(w, h, 1)))

        let graph = try RenderGraph(input: RenderInput(image: decoded,
                                                       identity: "thumb-hd|\(key.digest)",
                                                       sourceURL: source,
                                                       whiteBalance: inputs.whiteBalance),
                                    textureRetention: .none)
        defer { graph.releaseAllTextures() }

        // Display P3 primaries, linear exit: HDREncoding converts this to `displayP3_PQ` by the
        // system's own colour management (the same table `Export.swift` uses for `case .pq`).
        let linearOptions = RenderOptions(canvas: nil, scale: scale,
                                          display: DisplayOptions(primaries: .displayP3, bitDepth: 16,
                                                                  headroom: 1, linearOutput: true),
                                          useCache: false, wantsPixels: true)
        guard let linear = try? graph.render(document, options: linearOptions).display else {
            throw ThumbProviderError.encodeFailed(source)
        }
        let image = linear.withLinear(LinearPixels(linear))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "photons-hd-thumb-\(UUID().uuidString).heic")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let options = ExportOptions(format: .heic,
                                    quality: ThumbSpec.hd.quality,
                                    bitDepth: ThumbSpec.hd.bitDepth,
                                    hdr: HDRExport(enabled: true, kind: .pq))
        try HDREncoding.write(image, to: tmp, options: options)
        let data = try Data(contentsOf: tmp)

        lock.lock()
        runsPerKey[key.digest, default: 0] += 1
        runsPerContent[key.contentHash, default: 0] += 1
        lock.unlock()
        return ThumbPayload(data: data, source: "graph-pq",
                            sourceLongEdge: max(linear.width, linear.height))
    }

    /// Pixel size of the file's primary image without decoding it (ImageIO metadata only).
    static func sourceLongEdge(url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return max(w, h) > 0 ? max(w, h) : nil
    }

    /// Decode a cached payload for display.
    ///
    /// 223 — an HD payload is decoded **through Core Image → Metal at the cell's display pixels**,
    /// never through ImageIO and never at 1920 into memory: a 326 px grid cell must not pay for
    /// 2.4 M pixels. The result is a float image in extended linear Display P3; 227 keeps that
    /// bitmap (and its HDR values) in memory but composites it **SDR**, so `CALayer` tone maps it to
    /// SDR white instead of lifting reference white to the panel's maximum. The legacy JPEG ladder
    /// keeps ImageIO (it is the fast path there).
    static func decode(_ data: Data, for key: ThumbKey, display: ImageSize) -> CGImage? {
        guard key.spec == .hd else { return ThumbnailCache.decode(data) }
        return decodeHD(data, display: display)
    }

    /// 223 — the HD decode is the shared `ThumbnailHDRDecoder`: `CIImage` (display P3 PQ) → one
    /// pooled `MTLTexture` of exactly `display` → a half-float `CGImage` in extended linear P3.
    ///
    /// The 2026-11-01 measurement that decided this path: ImageIO's HEVC door is 79–100 ms for the
    /// same 1920 file **at any `maxPixelSize`** (the cost is the HEVC frame, not the pixel count),
    /// while `CIImage` → `CIContext.render(MTLTexture)` is ~3–7 ms. `ImageIO + maxPixelSize` was
    /// therefore a wrong hypothesis, not a tuning knob.
    static func decodeHD(_ data: Data, display: ImageSize) -> CGImage? {
        ThumbnailHDRDecoder.shared.decode(data, display: display)
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

// MARK: - Core Image → Metal decode (223)

/// The HD thumbnail decoder: one `CIContext`, one `MTLCommandQueue`, a pooled set of
/// display-sized `MTLTexture`s, for the whole process.
///
/// Why this shape (measured on this machine, 2026-11-01):
///
///   · `CGImageSourceCreateImageAtIndex` on a 1920 HEIC: **93 ms**; `CreateThumbnailAtIndex` at
///     `maxPixelSize: 326`: **79–100 ms** — the HEVC frame is the cost, not the requested size.
///   · `CIImage` → `CIContext.render(_:to: MTLTexture)`: **~3–7 ms** for the same file at 326 px.
///
/// So the code path is: lazy `CIImage` (which reads the 10-bit Display P3 PQ profile), aspect-fill
/// transform + centre crop in Core Image, render directly into a **display-sized** texture, then one
/// half-float read-back for `CALayer.contents`. The texture is returned to the pool, never allocated
/// per cell; the context is created once, not per thumbnail.
///
/// The read-back `CGImage` carries a **measured** content headroom (`max(R,G,B)`, floored at 1.0),
/// not ImageIO's default 4.926. 227 — the cell composites SDR, so the headroom no longer drives an
/// EDR layer; it remains the honest description of the bitmap (and the number an EDR path would use
/// if one ever returns). SDR white is `1.0` in this space, exactly like the old JPEG.
final class ThumbnailHDRDecoder: @unchecked Sendable {
    static let shared = ThumbnailHDRDecoder()

    /// Display P3 primaries with a linear transfer — the space the cells decode in. The cell
    /// composites SDR (227), but the bitmap keeps the extended-range values.
    let outputSpace: CGColorSpace?

    private let queue: MTLCommandQueue?
    private let context: CIContext
    private let pool: TexturePool?

    init() {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        outputSpace = space
        var options: [CIContextOption: Any] = [
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
        ]
        if let space {
            options[.workingColorSpace] = space
            options[.outputColorSpace] = space
        }
        if let device = MTLCreateSystemDefaultDevice(),
           let queue = device.makeCommandQueue() {
            self.queue = queue
            self.context = CIContext(mtlCommandQueue: queue, options: options)
            self.pool = TexturePool(device: device)
        } else {
            // No Metal: Core Image still decodes correctly, just through its CPU renderer. Keeping
            // this branch means a headless/VM machine shows thumbnails instead of empty cells.
            self.queue = nil
            self.context = CIContext(options: options)
            self.pool = nil
        }
    }

    /// 226 — the file's PQ profile has to be **explicit**.
    ///
    /// The cache is a 10-bit HEIC written from a `displayP3_PQ` bitmap. ImageIO hands that file
    /// back with `CGImage.colorSpace == nil` (the profile travels only in the ICC payload, and the
    /// 10-bit HEVC path drops it), so `CIImage(data:)` returned an image with **no transfer function**
    /// and Core Image copied the PQ signal straight into the linear working space: mid-grey came out
    /// at 0.69 instead of 0.117, i.e. 5.9× too bright, and highlights ran past 4.93.
    ///
    /// Tagging the source explicitly is still "hand it to the system": ColorSync performs the PQ
    /// EOTF + reference-white mapping. We only tell it what the bytes are.
    static func sourceImage(_ data: Data) -> CIImage? {
        if let tagged = CIImage(data: data,
                                options: [.colorSpace: CGColorSpace(name: CGColorSpace.displayP3_PQ)
                                          ?? CGColorSpace(name: CGColorSpace.sRGB)!]) {
            return tagged
        }
        return CIImage(data: data)
    }

    /// Decode `data` (a 10-bit Display P3 PQ HEIC) into exactly `display` pixels.
    ///
    /// Aspect-fill, centre-anchored — the same crop the cell's `contentsGravity` would apply, done
    /// once here so the bitmap the cache holds *is* the bitmap the user sees (no second resample).
    func decode(_ data: Data, display: ImageSize) -> CGImage? {
        guard display.width > 0, display.height > 0,
              let space = outputSpace,
              let image = Self.sourceImage(data) else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let width = CGFloat(display.width), height = CGFloat(display.height)
        let scale = max(width / extent.width, height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let e = scaled.extent
        let crop = CGRect(x: e.midX - width / 2, y: e.midY - height / 2,
                          width: width, height: height)

        if let pool,
           let texture = pool.acquire(width: display.width, height: display.height) {
            defer { pool.release(texture) }
            // CI writes through a compute shader, so the texture must allow `.shaderWrite` as well
            // as being a render target; without it the render silently leaves the texture empty.
            // The explicit buffer + `waitUntilCompleted` is what makes the read-back below observe
            // finished pixels — a nil buffer renders asynchronously and sometimes reads zeroes.
            guard let queue, let command = queue.makeCommandBuffer() else {
                return context.createCGImage(scaled, from: crop, format: .RGBAh, colorSpace: space)
            }
            context.render(scaled, to: texture, commandBuffer: command,
                           bounds: crop, colorSpace: space)
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed, command.error == nil else { return nil }
            return makeCGImage(from: texture, space: space)
        }

        // CPU fallback: `createCGImage` is the same colour conversion, just not texture-pooled.
        return context.createCGImage(scaled, from: crop, format: .RGBAh, colorSpace: space)
    }

    /// Half-float read-back → `CGImage` in extended linear P3 with a measured content headroom.
    private func makeCGImage(from texture: MTLTexture, space: CGColorSpace) -> CGImage? {
        let width = texture.width, height = texture.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 8
        var halves = [UInt16](repeating: 0, count: width * height * 4)
        halves.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        // The peak is both the acceptance number and the headroom the compositor may use: a cell
        // whose content reaches 1.3× white must say 1.3, or the SDR tone map will darken it anyway.
        var peak: Float = 0
        halves.withUnsafeBufferPointer { src in
            var i = 0
            while i < src.count {
                peak = max(peak, max(Float(Float16(bitPattern: src[i])),
                                     max(Float(Float16(bitPattern: src[i + 1])),
                                         Float(Float16(bitPattern: src[i + 2])))))
                i += 4
            }
        }
        let headroom = max(1, min(peak, 16))

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                      | CGBitmapInfo.floatComponents.rawValue
                                      | CGBitmapInfo.byteOrder16Little.rawValue)
        let data = halves.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        if #available(macOS 15.0, *) {
            // One allocation: `CGImageCreateCopyWithContentHeadroom` would copy the 630 KB buffer.
            return CGImage(headroom: headroom, width: width, height: height,
                           bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bytesPerRow,
                           space: space, bitmapInfo: bitmapInfo, provider: provider,
                           decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                       bytesPerRow: bytesPerRow, space: space, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    /// One texture per (width, height) per in-flight decode; a handful are kept for the next cell.
    private final class TexturePool: @unchecked Sendable {
        private let device: MTLDevice
        private let lock = NSLock()
        private var free: [String: [MTLTexture]] = [:]
        private let perSizeLimit = 4
        /// Resizing a window asks for a new width every few pixels; without a global ceiling the
        /// pool would keep four textures per width forever. Sixteen display-sized half-float
        /// textures is a few megabytes, and the next decode simply allocates instead of growing.
        private let totalLimit = 16
        private var total = 0

        init(device: MTLDevice) { self.device = device }

        func acquire(width: Int, height: Int) -> MTLTexture? {
            let key = "\(width)x\(height)"
            lock.lock()
            if var list = free[key], let texture = list.popLast() {
                free[key] = list
                total -= 1
                lock.unlock()
                return texture
            }
            lock.unlock()
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            descriptor.storageMode = .shared
            return device.makeTexture(descriptor: descriptor)
        }

        func release(_ texture: MTLTexture) {
            let key = "\(texture.width)x\(texture.height)"
            lock.lock()
            var list = free[key] ?? []
            if total < totalLimit && list.count < perSizeLimit {
                list.append(texture)
                free[key] = list
                total += 1
            }
            lock.unlock()
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
