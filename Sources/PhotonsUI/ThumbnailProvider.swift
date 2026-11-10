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
        /// 308 — decodes of the 1920 PQ JPEG, via ImageIO's thumbnail door with
        /// `kCGImageSourceThumbnailMaxPixelSize` = the cell's pixels. Counted apart from
        /// `imageIOThumbnailDecodes` (which is producer-side preview work) so "the grid decoded the
        /// JPEG at cell size" is a number, not a claim.
        public var hdJPEGDecodes = 0
        /// 284 — first-frame stand-in decodes, split by the bitmap they produced. The EDR counter is
        /// the shipped path; the SDR counter is the no-Metal fallback. `placeholderSRGBDecodes` is
        /// deliberately never incremented: the stand-in is a P3 picture, and a non-zero value would
        /// mean the old sRGB door came back.
        public var placeholderEDRDecodes = 0
        public var placeholderSDRDecodes = 0
        public var placeholderSRGBDecodes = 0
        /// Policy downgrades by reason (`dngCeiling`), 006 §6.1. Printed, not estimated.
        public var skipReasons: [String: Int] = [:]
        /// 311 — canvas warms: requests actually handed to the service, and the ones a digest in
        /// `warmedHDKeys` already covered (the "one file per document" counter pair).
        public var warmRequests = 0
        public var warmCoalesced = 0

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
    /// 006 §4 said 3. 308 measured what threads actually buy on this machine (24 distinct files,
    /// warm disk, decode downsampled to a 512 cell):
    ///
    ///   · **1920 PQ JPEG** — 331.8 ms wall at k=1 / 180.3 at 2 / 92.8 at 4 / 60.1 at 8 / 51.3 at
    ///     10: 5.52× at 8 threads, 6.47× at 10, close to linear. JPEG is software-decoded, so
    ///     threads convert directly into throughput;
    ///   · **1920 PQ HEIC** — 10.0 img/s at k=1 and 10.0 at k=4 (8.4 at k=12): HEVC's frame cost
    ///     serialises inside the process. Extra workers only make each image wait longer. That
    ///     measurement is why the old constant was 3, and it is no longer the file the grid reads.
    ///
    /// So the ceiling follows the machine and leaves one core for the main thread / compositing.
    /// A fixed 3/4/8 was right for one lane's sample size and wrong for every other machine.
    public static let defaultConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount - 1)

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
    /// 311 — the warm request in flight, by key. It is the whole dedupe: an ask for the digest that
    /// is already queued joins it, an ask for a document that moved on cancels it. Deliberately
    /// **not** a set of "already asked" digests: the cache keeps only the newest HD file per photo
    /// (308's retention), so undoing to an earlier document must be able to re-render it.
    private var warmInFlight: (digest: String, ticket: ThumbTicket)?
    /// 311 — the last warm's split: how long it sat in the queue, and how long the producer ran.
    /// Two numbers, because they answer different questions ("did the commit queue behind
    /// something?" vs "what does one HD render cost?").
    private var lastWarmWait: Double = 0
    private var lastWarmProduce: Double = 0
    /// 311 — the producer's own split: the graph render, and the JPEG encode. The whole point of
    /// retiring the HEIC is that the second number was the expensive half of a warm.
    private var lastHDRenderMilliseconds: Double = 0
    private var lastHDEncodeMilliseconds: Double = 0
    /// 351 — the five-way breakdown of a first screen: every HD render, every encode and every cell
    /// decode, as a distribution (bounded to the most recent 1024 samples each).
    ///
    /// The service owns `write` (`Stats.writeTimes`) and the queue (`waited − produced − write`), so
    /// these plus those two are the whole pipeline per cell. Kept as samples rather than as an
    /// average because the acceptance is stated in p50/p95/max — and `render` is itself split
    /// (`rawDecode` / `graphInit` / `graphRender`) so a report can say *which* half of "render" the
    /// time is in instead of guessing that the graph arithmetic is slow.
    public struct PhaseTimes: Sendable {
        /// The whole producer render leg (RAW decode + graph init + one frame).
        public var render: [Double] = []
        /// PQ JPEG encode.
        public var encode: [Double] = []
        /// The consumer's ImageIO downsample to the cell's pixels.
        public var decode: [Double] = []
        /// Inside `render`: the RAW decode at the thumbnail's scale.
        public var rawDecode: [Double] = []
        /// Inside `render`: `RenderGraph` construction.
        public var graphInit: [Double] = []
        /// Inside `render`: the one graph frame (S0 → S4 at 1920).
        public var graphRender: [Double] = []
    }

    private var phaseTimesStore = PhaseTimes()
    private static let phaseSampleLimit = 1024
    /// 351 — the source's long edge, remembered per key digest from the catalog's own row.
    ///
    /// `sourceLongEdge(url:)` opens the file with ImageIO and reads the primary image's properties:
    /// measured **147 ms** for one 60 MB DNG on this machine — per cell, because the producer only
    /// receives a key and a URL. The catalog has known `width`/`height` since import, so the request
    /// that *does* carry the `Asset` hands the number over and the producer stops re-scanning the RAW
    /// for a number it was already told.
    private var sourceEdges: [String: Int] = [:]
    private var sourceEdgeOrder: [String] = []
    /// How many times the producer had to open the file to learn its edge (351's reading).
    private var sourceProbeCount = 0
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
    /// 351 — the HD thumbnail producer's decoder pool (one command queue each) and its cursor.
    private var thumbnailDecoders: [RAWDecoder] = []
    private var decoderCursor: Int64 = 0
    /// 258 — decoded whole-picture stand-ins, keyed by the thumbnail key's digest. The grid's memory
    /// LRU holds display-sized **crops**, not the aspect-preserved picture the loupe's stand-in needs,
    /// so it cannot serve this path; without a small cache of its own every photo switch paid the
    /// disk read + JPEG decode again (measured 28 ms in debug for a 640×427 preview). Warm switches
    /// are now a dictionary lookup, which is the ≤ 5 ms the acceptance asks for.
    private var placeholderImages: [String: CGImage] = [:]
    private var placeholderOrder: [String] = []
    private static let placeholderLimit = 8

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
        if key.spec.isHDFamily {
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

    /// 308 — the key the three browsers share. Same document rules as `hdKey`; a different family.
    public static func hdJPEGKey(for asset: Asset, document: EditModel? = nil) -> ThumbKey {
        .hdJPEG(contentHash: asset.contentHash,
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

    /// Hand the producer the source's long edge so it does not re-open the RAW to measure it (351).
    private func rememberSourceEdge(_ edge: Int?, for digest: String) {
        guard let edge, edge > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        if sourceEdges[digest] == nil { sourceEdgeOrder.append(digest) }
        sourceEdges[digest] = edge
        while sourceEdgeOrder.count > ThumbnailProvider.indexLimit {
            sourceEdges.removeValue(forKey: sourceEdgeOrder.removeFirst())
        }
    }

    private func rememberedSourceEdge(_ digest: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return sourceEdges[digest]
    }

    /// 351 — times the producer had to open a file to learn its own dimensions. Should stay at 0 for
    /// every request that came through `request(asset:)`, which is all three browsers.
    public var sourceProbes: Int {
        lock.lock(); defer { lock.unlock() }
        return sourceProbeCount
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
        if spec.isHDFamily {
            let doc = document ?? ThumbnailProvider.document(from: asset)
            // 311 — one HD family. The 1920 PQ **JPEG** is the file every surface reads: the grid's
            // cells, the filmstrip and (now) the loupe's first-frame stand-in. A `.hd` request is
            // mapped onto it rather than producing the retired HEIC: two files per photo meant two
            // encodes per render, and the HEIC was the expensive one.
            key = ThumbKey.hdJPEG(contentHash: asset.contentHash, document: doc)
            rememberDocument(doc, for: key.digest)
            // 351 — the catalog already knows the pixel size; the producer must not re-open the RAW
            // to learn it (147 ms per cell).
            rememberSourceEdge(ThumbnailProvider.sourceLongEdge(of: asset), for: key.digest)
        } else {
            let plan = ThumbnailProvider.effectiveTier(requested: tier, ext: asset.ext)
            if let reason = plan.skipReason {
                note { $0.skipReasons[reason, default: 0] += 1 }
            }
            key = ThumbKey.preview(contentHash: asset.contentHash, tier: plan.tier)
        }

        // 1. memory. Synchronous, so a cell that scrolls back into view draws in the same frame.
        // 223 — the key includes the display pixels: a grid bitmap is never handed to the list.
        if let hit = memoryImage(for: key, display: spec.isHDFamily ? pixels : nil) {
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

    // MARK: - 235: the frame before the first frame

    /// The cached thumbnail for a photo, at its **own** aspect and already decoded to the display's
    /// colour space — the picture the loupe puts up while the real frame is still being developed.
    ///
    /// 311 — the file is the **1920 PQ JPEG** (`ThumbKey.hdJPEG`, 308's family promoted): one file
    /// per photo, written by the same render the cells use, so a commit's warm is one render and
    /// **one** encode instead of a HEIC plus a JPEG. The 8-bit PQ codes still decode through Core
    /// Image to a 16-bit extended-linear Display P3 bitmap (`decodeHDForPlaceholder`), so the
    /// stand-in carries the same light as the frame that replaces it (284).
    ///
    /// Without a Metal device the stand-in is 8-bit Display P3 (not sRGB: the file is P3, and a P3 →
    /// sRGB conversion would flatten exactly the saturated colours the user is comparing).
    ///
    /// Deliberately cache-only: generating one here would put a second decode in front of the frame
    /// the user is waiting for, which is the opposite of the fix. The legacy preview JPEG is the
    /// fallback for a library that still has one from an earlier build. `nil` means neither is on
    /// disk, and the caller then asks the service for a fresh preview asynchronously.
    ///
    /// The returned `CGImage` is never cropped: its aspect is the photo's, so the caller can fit it
    /// into the canvas without stretching.
    public func cachedCanvasPlaceholder(for asset: Asset, document: EditModel) -> CGImage? {
        let hd = ThumbnailProvider.hdJPEGKey(for: asset, document: document)
        if let cached = placeholderImage(for: hd.digest) { return cached }
        if cache.exists(hd), let data = cache.data(for: hd),
           let image = ThumbnailProvider.decodeHDForPlaceholder(data) {
            note {
                if image.bitsPerComponent == 16 {
                    $0.placeholderEDRDecodes += 1
                } else {
                    $0.placeholderSDRDecodes += 1
                }
            }
            rememberPlaceholder(image, for: hd.digest)
            return image
        }
        let tier = ThumbnailProvider.effectiveTier(requested: .t1024, ext: asset.ext).tier
        let preview = ThumbKey.preview(contentHash: asset.contentHash, tier: tier)
        if let cached = placeholderImage(for: preview.digest) { return cached }
        if cache.exists(preview), let data = cache.data(for: preview) {
            guard let decoded = ThumbnailCache.decode(data),
                  let image = ThumbnailProvider.displayP3Image(decoded) else { return nil }
            rememberPlaceholder(image, for: preview.digest)
            return image
        }
        return nil
    }

    // MARK: - 311: the canvas stand-in for the document that is open now

    /// Ask for the HD thumbnail of **this** document, so the loupe's cache-only stand-in has
    /// something to show the moment a transform commit lands.
    ///
    /// `cachedCanvasPlaceholder` above is deliberately cache-only, and every commit changes the
    /// document → changes the key → leaves the canvas with nothing to put up until the user edits
    /// *again* (which is what woke 303's `EditThumbnailRefresher`). In the loupe no browser cell is
    /// on screen to ask for the new key, so nobody rendered it. This is that missing door: one `hd`
    /// request at `.prefetch`, **summary-only** (`completion: nil` → no 1920 decode, no memory
    /// entry; the bytes on disk are the whole product), so it costs the main thread nothing.
    ///
    /// Idempotent and cancellable, both by key:
    ///   · a digest already in `warmedHDKeys` is never asked for twice — a crop commit wakes two
    ///     doors (the session's observer and `finishCropTool`), and an unchanged commit is a no-op;
    ///   · a **new** digest cancels the request it superseded, and the service drops those bytes
    ///     instead of writing them, so a slider drag that moves the document twenty times lands
    ///     one file, not twenty.
    ///
    /// Returns whether a request was handed to the service (a deduped call returns `false`) — the
    /// number the acceptance reads instead of guessing from timings.
    ///
    /// 326 — the request is marked `isBackgroundWarm`, because the commit that needs it happens
    /// *during* the interaction (a slider drag, a crop frame being moved) and the service refuses
    /// everything else while `isPaused`. A refusal here used to be final: in the loupe no cell ever
    /// asks for this key, so the 1920 preview stayed on the document before the edit. As a warm it is
    /// queued instead and starts when the drag ends.
    @discardableResult
    public func warmHDPreview(for asset: Asset, fileURL: URL?, document: EditModel) -> Bool {
        let key = ThumbnailProvider.hdJPEGKey(for: asset, document: document)
        // The file is the product. If it is already there (a re-render of a document the user came
        // back to) there is nothing to ask for; a stat is cheaper than a queue round trip.
        if cache.exists(key) {
            note { $0.warmCoalesced += 1 }
            return false
        }
        lock.lock()
        if let inFlight = warmInFlight, inFlight.digest == key.digest {
            counters.warmCoalesced += 1
            lock.unlock()
            return false
        }
        let superseded = warmInFlight
        warmInFlight = nil
        counters.warmRequests += 1
        lock.unlock()

        // The document moved on: the older rendering's bytes are obsolete, and a second file for a
        // superseded key is the "20 edits → 20 renders" failure this pairing exists to prevent.
        if let superseded, superseded.digest != key.digest { superseded.ticket.cancel() }
        guard let fileURL else { return true }
        // `produce` only receives a key and a source URL — the edit rides through this hand-off.
        // The callback is bookkeeping only: the bytes on disk are the whole product, so nothing is
        // decoded here and nothing enters the memory LRU.
        rememberDocument(document, for: key.digest)
        rememberSourceEdge(ThumbnailProvider.sourceLongEdge(of: asset), for: key.digest)
        let ticket = service.request(ThumbRequestSpec(key: key, source: fileURL,
                                                      isBackgroundWarm: true),
                                     priority: .prefetch) {
            [weak self] result in
            guard let self else { return }
            self.lock.lock()
            // `waitedMilliseconds` is enqueue→finish, i.e. it **contains** the producer. The two
            // numbers the report needs are: time spent behind other work, and the render itself.
            self.lastWarmWait = max(0, result.waitedMilliseconds - result.producedMilliseconds)
            self.lastWarmProduce = result.producedMilliseconds
            if self.warmInFlight?.digest == result.key.digest { self.warmInFlight = nil }
            self.lock.unlock()
        }
        lock.lock()
        warmInFlight = (key.digest, ticket)
        lock.unlock()
        return true
    }

    /// 311 — the last canvas warm's two halves, in milliseconds: time spent queued behind other
    /// work, and the producer's own render + encode. `nil` until one finishes. Read by the
    /// acceptance rather than timed with a stopwatch around the commit.
    public var lastWarmLatency: (queued: Double, rendering: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard lastWarmProduce > 0 else { return nil }
        return (lastWarmWait, lastWarmProduce)
    }

    /// 311 — the last HD producer's two halves: graph render, JPEG encode. Read by the acceptance
    /// to show where a warm's time goes; `(0, 0)` until one runs.
    public var lastHDProduction: (render: Double, encode: Double) {
        lock.lock(); defer { lock.unlock() }
        return (lastHDRenderMilliseconds, lastHDEncodeMilliseconds)
    }

    private func placeholderImage(for digest: String) -> CGImage? {
        lock.lock(); defer { lock.unlock() }
        return placeholderImages[digest]
    }

    /// 311 — test door: forget the decoded stand-in for one digest so the next
    /// `cachedCanvasPlaceholder` is the **disk** read of the file a warm wrote, which is the path a
    /// fresh loupe takes. Production never needs it (the L1 is an 8-entry cache, not state).
    func forgetPlaceholder(for digest: String) {
        lock.lock()
        placeholderImages.removeValue(forKey: digest)
        placeholderOrder.removeAll { $0 == digest }
        lock.unlock()
    }

    private func rememberPlaceholder(_ image: CGImage, for digest: String) {
        lock.lock(); defer { lock.unlock() }
        if placeholderImages[digest] == nil { placeholderOrder.append(digest) }
        placeholderImages[digest] = image
        while placeholderOrder.count > Self.placeholderLimit {
            placeholderImages.removeValue(forKey: placeholderOrder.removeFirst())
        }
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
        // 308 — three now: HEIC (Core Image → texture), 1920 PQ JPEG (ImageIO downsample), and the
        // legacy ladder (ImageIO whole image).
        let image: CGImage?
        let decodeStart = CACurrentMediaTime()
        if result.key.spec == .hd {
            image = ThumbnailProvider.decodeHD(data, display: display)
            if image != nil { note { $0.gpuDecodes += 1 } }
        } else if result.key.spec == .hdJPEG {
            image = ThumbnailProvider.decodeJPEG(data, display: display)
            if image != nil { note { $0.hdJPEGDecodes += 1 } }
        } else {
            image = ThumbnailCache.decode(data)
            if image != nil { note { $0.imageIOWholeDecodes += 1 } }
        }
        // 351 — the cell's decode is the fourth leg of the pipeline (`decode`), and the only one a
        // cell can feel directly: it runs on the worker after the file exists.
        let decodeMs = (CACurrentMediaTime() - decodeStart) * 1000
        lock.lock(); Self.append(decodeMs, to: &phaseTimesStore.decode); lock.unlock()
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
        if key.spec.isHDFamily {
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
    /// scale whose long edge is at most 1920, then **one** encoder.
    ///
    /// One render, not two: unlike 218's gain-map base + auxiliary image, a PQ file *is* the
    /// extended-range picture, so the linear exit (`s4_display_linear` in P3) is the only frame
    /// needed. Reusing this door is what keeps "grid thumbnail == export preview" a fact instead of
    /// a claim — and it is why 223 does not add a second encoder.
    ///
    /// 308 — the file is the 512-shaped **1920 PQ JPEG** the grid/list/filmstrip read.
    /// 311 — and it is the **only** file: the 1920 HEIC the loupe's stand-in used to read as a
    /// by-product is gone. Encoding it was the expensive half of a warm (HEVC frame cost, serialised
    /// inside the process) and no surface needs two files for one photo. The loupe reads this JPEG.
    private func produceHD(_ key: ThumbKey, source: URL) throws -> ThumbPayload {
        let document: EditModel
        lock.lock(); document = documentsByKey[key.digest] ?? .neutral; lock.unlock()
        let renderStart = CACurrentMediaTime()
        let rendered = try renderHD(key: key, source: source, document: document)
        let renderMs = (CACurrentMediaTime() - renderStart) * 1000

        let encodeStart = CACurrentMediaTime()
        guard let jpeg = ThumbnailPQJPEG.encode(linear: rendered.linear,
                                                longEdge: ThumbSpec.hdJPEG.longEdge,
                                                quality: ThumbSpec.hdJPEG.quality) else {
            throw ThumbProviderError.encodeFailed(source)
        }
        let encodeMs = (CACurrentMediaTime() - encodeStart) * 1000

        lock.lock()
        runsPerKey[key.digest, default: 0] += 1
        runsPerContent[key.contentHash, default: 0] += 1
        lastHDRenderMilliseconds = renderMs
        lastHDEncodeMilliseconds = encodeMs
        Self.append(renderMs, to: &phaseTimesStore.render)
        Self.append(encodeMs, to: &phaseTimesStore.encode)
        lock.unlock()
        return ThumbPayload(data: jpeg, source: "graph-pq-jpeg",
                            sourceLongEdge: rendered.longEdge)
    }

    /// The render half of `produceHD`: decode once, one graph frame at 1920, and hand back both the
    /// `DisplayImage` (what `HDREncoding` consumes) and its linear companion (what the 512 JPEG is
    /// downscaled from). Split out so the two encoders share exactly one render.
    struct HDRender {
        let image: DisplayImage
        let linear: LinearPixels
        let longEdge: Int
    }

    /// Internal, not private: the 308 acceptance harness compares the JPEG against the **exact**
    /// buffer it was encoded from (same render, same document), rather than re-rendering and hoping
    /// the two agree.
    func renderHD(key: ThumbKey, source: URL, document: EditModel) throws -> HDRender {
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ThumbProviderError.unreadable(source)
        }
        // 351 — a decoder per worker, not the loupe's single queue (see `thumbnailDecoder`).
        guard let decoder = thumbnailDecoder() else { throw ThumbProviderError.noRAWDecoder }

        let longEdge = ThumbSpec.hdJPEG.longEdge
        // Decode no larger than needed for 1920 (a 60 MP RAW at 0.25 already covers it), and never
        // so small that the thumbnail has to upscale. The 512 JPEG is a downscale of this frame.
        //
        // 351 — the edge comes from the request's `Asset` when it was given; only a caller that has
        // no catalog row (a CLI batch, a probe) pays the ImageIO scan, and that scan is 147 ms for a
        // 60 MB DNG — more than the graph render it is used to size.
        var sourceEdge = rememberedSourceEdge(key.digest)
        if sourceEdge == nil {
            sourceEdge = ThumbnailProvider.sourceLongEdge(url: source)
            lock.lock(); sourceProbeCount += 1; lock.unlock()
        }
        let edge = sourceEdge ?? longEdge
        let decodeScale = min(1, max(0.25, Double(longEdge) / Double(max(1, edge))))
        // The HD thumbnail is our own graph, so it must ask for the document's whole development:
        // version and detail are decode inputs too (the key's `editFingerprint` carries them, and
        // omitting them here would file a v8 picture under a v9 key).
        let inputs = document.decodeInputs
        let decodeStart = CACurrentMediaTime()
        let decoded = try decoder.decode(source, options: DecodeOptions(
            decoderVersion: inputs.decoderVersion,
            scale: Float(decodeScale),
            whiteBalance: inputs.whiteBalance,
            detail: inputs.detail))
        let rawDecodeMs = (CACurrentMediaTime() - decodeStart) * 1000
        let w = decoded.width, h = decoded.height
        let scale = min(1, Double(longEdge) / Double(max(w, h, 1)))

        let initStart = CACurrentMediaTime()
        let graph = try RenderGraph(input: RenderInput(image: decoded,
                                                       identity: "thumb-hd|\(key.digest)",
                                                       sourceURL: source,
                                                       whiteBalance: inputs.whiteBalance),
                                    textureRetention: .none)
        let graphInitMs = (CACurrentMediaTime() - initStart) * 1000
        defer { graph.releaseAllTextures() }

        // Display P3 primaries, linear exit: HDREncoding converts this to `displayP3_PQ` by the
        // system's own colour management (the same table `Export.swift` uses for `case .pq`).
        let linearOptions = RenderOptions(canvas: nil, scale: scale,
                                          display: DisplayOptions(primaries: .displayP3, bitDepth: 16,
                                                                  headroom: 1, linearOutput: true),
                                          useCache: false, wantsPixels: true)
        let frameStart = CACurrentMediaTime()
        let frame = try? graph.render(document, options: linearOptions).display
        let frameMs = (CACurrentMediaTime() - frameStart) * 1000
        lock.lock()
        Self.append(rawDecodeMs, to: &phaseTimesStore.rawDecode)
        Self.append(graphInitMs, to: &phaseTimesStore.graphInit)
        Self.append(frameMs, to: &phaseTimesStore.graphRender)
        lock.unlock()
        guard let linear = frame else {
            throw ThumbProviderError.encodeFailed(source)
        }
        return HDRender(image: linear.withLinear(LinearPixels(linear)),
                        linear: LinearPixels(linear),
                        longEdge: max(linear.width, linear.height))
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
        switch key.spec {
        case .hd: return decodeHD(data, display: display)
        case .hdJPEG: return decodeJPEG(data, display: display)
        case .legacy: return ThumbnailCache.decode(data)
        }
    }

    /// 308 — the 1920 PQ JPEG, decoded **by ImageIO straight to the cell's pixel size**.
    ///
    /// This is the whole reason the file stays at 1920: `kCGImageSourceThumbnailMaxPixelSize` makes
    /// the JPEG decoder do the downsample (DCT-domain where it can), averaging PQ codes before they
    /// reach the screen. Measured 14.7 ms to 512 against 183 ms for the 1920 HEIC, and a *lower*
    /// banding residual on screen (0.032 EV) than a file stored natively at 512 (0.047 EV) — the
    /// averaging is the point, not a shortcut. Decoding at full size and scaling by hand costs 2×
    /// the time and leaves the 0.0847 EV full-resolution residual (the reverse gate in the tests).
    ///
    /// The returned image is 8-bit and tagged `displayP3_PQ`; the cell's `ThumbnailMetalSurface`
    /// converts it to the extended-linear-P3 float texture it always draws (its 16-bit fast path is
    /// skipped, which is the migration `CIImage(cgImage:)` handles in one pass).
    static func decodeJPEG(_ data: Data, display: ImageSize) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let edge = max(1, max(display.width, display.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: edge,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return Self.taggedPQ(image)
    }

    /// 226's lesson, applied to a JPEG: a `CGImage` whose profile ImageIO dropped has **no transfer
    /// function**, and Core Image would copy the PQ signal into its linear working space (5.9× too
    /// bright). The file's ICC normally survives the JPEG decode; when it does not, re-tag the same
    /// bytes as `displayP3_PQ` rather than trusting an untagged image.
    static func taggedPQ(_ image: CGImage) -> CGImage? {
        if let space = image.colorSpace,
           (space.name as String?) == (CGColorSpace.displayP3_PQ as String) {
            return image
        }
        guard let pq = CGColorSpace(name: CGColorSpace.displayP3_PQ),
              let provider = image.dataProvider else { return image }
        return CGImage(width: image.width, height: image.height,
                       bitsPerComponent: image.bitsPerComponent,
                       bitsPerPixel: image.bitsPerPixel,
                       bytesPerRow: image.bytesPerRow, space: pq,
                       bitmapInfo: image.bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
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

    /// 284 — the HD file as a **whole-picture EDR** bitmap, for the loupe's first-frame stand-in.
    /// No aspect-fill here: the caller fits it, so cropping it would show the wrong composition.
    ///
    /// The preferred exit is `decodeWholePictureEDR`: half-float extended linear Display P3 with the
    /// file's measured headroom, the same colour path the grid/filmstrip cells use. Only a machine
    /// without a Metal device falls back to `decodeWholePictureSDR` (8-bit Display P3, still no sRGB
    /// narrowing) — there is no EDR surface to put a float bitmap on then.
    static func decodeHDForPlaceholder(_ data: Data) -> CGImage? {
        if ThumbnailMetalRenderer.shared.isAvailable {
            return ThumbnailHDRDecoder.shared.decodeWholePictureEDR(data)
        }
        return ThumbnailHDRDecoder.shared.decodeWholePictureSDR(data)
    }

    /// 284 — redraw any bitmap into 8-bit Display P3. The placeholder must never be sRGB: the HD
    /// cache is a P3 picture, and the legacy preview fallback is colour-managed into the same space
    /// so the stand-in and the cells agree about its saturation.
    static func displayP3Image(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.displayP3),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
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

    /// 351 — one decoder **per worker** for the HD thumbnail path.
    ///
    /// A `RAWDecoder` owns one `MTLCommandQueue` and one `CIContext`, and command buffers on one queue
    /// execute in order. Nine thumbnail workers sharing the loupe's decoder therefore did not run nine
    /// decodes at once: four concurrent decodes through one decoder measured **1212 ms** against
    /// 1718 ms sequential (1.42×), while the same four through four decoders measured **876 ms**
    /// (1.96×). The service's ceiling was never the problem — `activePeak` reaches 9 in the report —
    /// the decode leg was. The pool is sized by that same ceiling and created lazily, so a library that
    /// never generates an HD thumbnail pays nothing.
    ///
    /// `rawDecoder()` stays the single shared instance for the rare non-HD paths (a RAW with no
    /// embedded preview, the preview producer): those are one-off and must not allocate a pool.
    private func thumbnailDecoder() -> RAWDecoder? {
        let capacity = max(1, service.config.maxConcurrency)
        lock.lock()
        let index = Int(decoderCursor % Int64(capacity))
        decoderCursor &+= 1
        if index < thumbnailDecoders.count {
            let existing = thumbnailDecoders[index]
            lock.unlock()
            return existing
        }
        if decoderUnavailable { lock.unlock(); return nil }
        lock.unlock()
        guard let made = try? RAWDecoder() else {
            lock.lock(); decoderUnavailable = true; lock.unlock()
            return nil
        }
        lock.lock()
        thumbnailDecoders.append(made)
        lock.unlock()
        return made
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

    /// 351 — the phases the provider owns, as samples (ms). `write` is `serviceStats.writeTimes`
    /// and the queue is `waited − produced − write`.
    public var phaseTimes: PhaseTimes {
        lock.lock(); defer { lock.unlock() }
        return phaseTimesStore
    }

    /// Bounded append for a phase sample. The cap keeps a 10k-photo import from turning a diagnostic
    /// into an allocation that grows with the library.
    static func append(_ value: Double, to samples: inout [Double]) {
        samples.append(value)
        if samples.count > phaseSampleLimit {
            samples.removeFirst(samples.count - phaseSampleLimit)
        }
    }

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
    private let device: MTLDevice?

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
            self.device = device
            self.queue = queue
            self.context = CIContext(mtlCommandQueue: queue, options: options)
            self.pool = TexturePool(device: device)
        } else {
            // No Metal: Core Image still decodes correctly, just through its CPU renderer. Keeping
            // this branch means a headless/VM machine shows thumbnails instead of empty cells.
            self.device = nil
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

    /// 284 — the whole picture in the **same** colour path as `decode(_:display:)`: half-float
    /// extended linear Display P3 with the measured content headroom, but no aspect-fill crop.
    ///
    /// The stand-in has to match what the grid and filmstrip put on screen for the same PQ file, or
    /// the switch shows a brightness step (the reported 284 defect). A cell's bitmap is a crop of
    /// this one at display pixels; here the extent *is* the picture, so the caller can fit it into
    /// the 283 rectangle without losing the photograph's own aspect.
    func decodeWholePictureEDR(_ data: Data) -> CGImage? {
        guard let space = outputSpace, let image = Self.sourceImage(data) else { return nil }
        guard let (placed, bounds) = Self.wholePicture(image) else { return nil }
        let width = Int(bounds.width), height = Int(bounds.height)

        // A whole photograph is 1920 px on its long edge, far larger than any cell. Rendering it
        // through the cell pool would park up to four ~20 MB textures per photo aspect in the shared
        // pool, so this one-off read-back texture is deliberate: the stand-in is decoded once per
        // switch, never scrolled through.
        if let device, let queue,
           let texture = Self.makeReadbackTexture(device: device, width: width, height: height),
           let command = queue.makeCommandBuffer() {
            context.render(placed, to: texture, commandBuffer: command, bounds: bounds,
                           colorSpace: space)
            command.commit()
            command.waitUntilCompleted()
            guard command.status == .completed, command.error == nil else { return nil }
            return makeCGImage(from: texture, space: space)
        }
        return context.createCGImage(placed, from: bounds, format: .RGBAh, colorSpace: space)
    }

    private static func makeReadbackTexture(device: MTLDevice, width: Int,
                                            height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    /// 284 — the no-Metal fallback: whole picture, 8-bit **Display P3**. Still no sRGB narrowing;
    /// the file's own primaries are kept, only the extended range is gone.
    func decodeWholePictureSDR(_ data: Data) -> CGImage? {
        guard let image = Self.sourceImage(data),
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let (placed, bounds) = Self.wholePicture(image) else { return nil }
        return context.createCGImage(placed, from: bounds, format: .RGBA8, colorSpace: space)
    }

    /// The picture moved to the origin and its integral extent, so a texture render and a
    /// `createCGImage` agree about which pixels are the whole photograph.
    private static func wholePicture(_ image: CIImage) -> (CIImage, CGRect)? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return nil }
        let width = max(1, Int(extent.width.rounded())), height = max(1, Int(extent.height.rounded()))
        let placed = image.transformed(by: CGAffineTransform(translationX: -extent.minX,
                                                             y: -extent.minY))
        return (placed, CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// 235 — the legacy whole-picture sRGB door. Since 284 no placeholder path calls it: the stand-in
    /// is EDR when Metal is available and 8-bit Display P3 otherwise. Kept as the historical exit
    /// other callers may still name; the acceptance's "no sRGB in the placeholder path" is about the
    /// two doors above.
    func decodeWholePictureSRGB(_ data: Data) -> CGImage? {
        guard let image = Self.sourceImage(data),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }
        return context.createCGImage(image, from: extent, format: .RGBA8, colorSpace: srgb)
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

        // 241 — the one place the read-back changes coordinate systems.
        //
        // `CIContext.render(_:to:)` writes the image with row 0 at the **bottom** (Core Image's
        // origin is bottom-left; a Metal texture's row 0 is its first row). `getBytes` therefore
        // hands us bottom-row-first data, while `CGImage` and the `CAMetalLayer` upload below both
        // mean "row 0 = top". Reverse the rows once here. The CPU fallback above already returns
        // CGImage row order via `createCGImage`, so it needs nothing.
        //
        // 238 removed the row flip inside `HDREncoding` (PQ exports were upside down). Until then
        // that flip had been cancelling this one for HD thumbnails, which is why the grid only
        // turned upside down after 238.
        let rowBytes = width * 8
        if height > 1 {
            halves.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return }
                // One row of scratch, then three whole-row copies per pair. Swapping element by
                // element cost 18 ms under debug on a 326×242 buffer and pushed `decodeHD` past
                // its 8 ms budget; `memcpy` keeps this step well under 1 ms.
                let scratch = UnsafeMutableRawPointer.allocate(byteCount: rowBytes, alignment: 8)
                defer { scratch.deallocate() }
                for y in 0..<(height / 2) {
                    let a = base + y * rowBytes
                    let b = base + (height - 1 - y) * rowBytes
                    memcpy(scratch, a, rowBytes)
                    memcpy(a, b, rowBytes)
                    memcpy(b, scratch, rowBytes)
                }
            }
        }

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
