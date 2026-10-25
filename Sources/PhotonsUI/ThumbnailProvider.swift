import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PhotonsCatalog
import PhotonsCore

/// One cell's outstanding thumbnail load. Cancelling it drops the job from the worker pool
/// (a *running* job is not interruptible — `CIRAWFilter`/ImageIO give us no cancellation — it just
/// does not reach the UI, which is the 006 §5 rule).
public final class ThumbnailRequest {
    public let index: Int
    public let key: ThumbKey
    public private(set) var isCancelled = false
    private weak var operation: Operation?
    private weak var provider: ThumbnailProvider?

    public init(index: Int, key: ThumbKey, operation: Operation?, provider: ThumbnailProvider? = nil) {
        self.index = index
        self.key = key
        self.operation = operation
        self.provider = provider
    }

    /// Cancellation is counted here, not in the operation body: `OperationQueue` never runs an
    /// operation that was cancelled while still queued, so a counter inside `main()` would silently
    /// under-report — and "N were cancelled, none are stuck in the queue" is the whole point.
    ///
    /// A job that already finished is *not* counted as cancelled: its `applied` increment landed
    /// before the cell scrolled away, and counting both would make `requests - applied - cancelled`
    /// drift negative. Both counters are "at least" numbers for that one-runloop overlap.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        if operation?.isFinished != true {
            provider?.note { $0.cancelled += 1 }
        }
        operation?.cancel()
    }
}

/// The grid's thumbnail source: one memory LRU in front of `ThumbnailCache`, one bounded worker
/// pool behind it.
///
/// Three layers, in the order a cell asks for them (docs/tasks/006-thumbnails.md §1, §3):
///
/// 1. **memory** — `NSCache` keyed by `ThumbKey.digest`, 512 images / 96 MB, cost = w·h·4. A cell
///    that scrolls back into view is answered synchronously, with no file I/O.
/// 2. **disk** — the content-addressed JPEG in `~/Library/Caches/Photons/<libHash>/thumbs/`,
///    read + decoded off the main thread.
/// 3. **generate** — the P path: a RAW's *embedded* preview through ImageIO (never a RAW decode,
///    006 §0) or, for a file that already **is** a JPEG, ImageIO's own downscaled read. The result
///    is normalised to 8-bit sRGB, written back to the cache with an atomic rename, and remembered.
///
/// Failures never throw and never clear a cell: the caller keeps drawing its placeholder. That is
/// the difference between "no thumbnail yet" and "a white hole in the grid".
public final class ThumbnailProvider: @unchecked Sendable {

    /// Where a delivered image came from. `cache` (memory or disk) is a *hit*; `generated` is not.
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

        public var cacheHits: Int { memoryHits + diskHits }
        public var lookups: Int { memoryHits + diskHits + generated }
        /// Share of lookups served without producing anything (the acceptance number in 006 §7 #1).
        public var hitRatio: Double { lookups == 0 ? 0 : Double(cacheHits) / Double(lookups) }

        public var summary: String {
            String(format: "requests %d · applied %d · memory %d · disk %d · generated %d · failed %d · cancelled %d · hit %.3f",
                   requests, applied, memoryHits, diskHits, generated, failures, cancelled, hitRatio)
        }
    }

    /// 006 §1 asks for a 32 MB window-sized LRU; the brief sets the floor at 512 images / 96 MB.
    /// Both are enforced: `NSCache` evicts on whichever limit trips first.
    public static let memoryCountLimit = 512
    public static let memoryByteLimit = 96 * 1024 * 1024
    /// 006 §4 "并发上限 3" — the same number LightCraft uses, and the one that keeps a loupe frame
    /// (priority ①) from being starved by grid work (priority ②).
    public static let defaultConcurrency = 3

    public let cache: ThumbnailCache?

    private let memory = NSCache<NSString, ImageBox>()
    private let workers: OperationQueue
    private let lock = NSLock()
    private var counters = Stats()
    private var decoder: RAWDecoder?
    private var decoderUnavailable = false

    public init(cache: ThumbnailCache?, maxConcurrent: Int = ThumbnailProvider.defaultConcurrency) {
        self.cache = cache
        memory.countLimit = ThumbnailProvider.memoryCountLimit
        memory.totalCostLimit = ThumbnailProvider.memoryByteLimit
        workers = OperationQueue()
        workers.name = "photons.thumbs"
        workers.qualityOfService = .userInitiated
        workers.maxConcurrentOperationCount = max(1, maxConcurrent)
    }

    // MARK: - tier selection (006 §1)

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
    public func request(index: Int,
                        asset: Asset,
                        fileURL: URL?,
                        tier: ThumbTier,
                        completion: @escaping @MainActor (Int, ThumbKey, CGImage?) -> Void) -> ThumbnailRequest {
        let key = ThumbKey.preview(contentHash: asset.contentHash, tier: tier)

        if let hit = memoryImage(for: key) {
            note { $0.requests += 1; $0.memoryHits += 1; $0.applied += 1 }
            DispatchQueue.main.async { completion(index, key, hit) }
            return ThumbnailRequest(index: index, key: key, operation: nil, provider: self)
        }

        note { $0.requests += 1 }
        let op = LoadOperation(provider: self, index: index, key: key, asset: asset,
                               fileURL: fileURL, tier: tier, completion: completion)
        let token = ThumbnailRequest(index: index, key: key, operation: op, provider: self)
        workers.addOperation(op)
        return token
    }

    /// Synchronous memory hit for a cell being configured — counted, so the acceptance harness can
    /// distinguish "served from the LRU" from "regenerated the same image".
    public func serveFromMemory(for key: ThumbKey) -> CGImage? {
        guard let hit = memoryImage(for: key) else { return nil }
        note { $0.requests += 1; $0.memoryHits += 1; $0.applied += 1 }
        return hit
    }

    /// Work that is queued or running. Exposed so `--ui-smoke` can assert the queue does not grow
    /// with the library (§5: "队列峰值 ≤ 预取窗口的 2 倍").
    public var queueDepth: Int { workers.operationCount }

    /// Everything the worker does for one key. Runs off the main thread.
    fileprivate func load(index: Int, key: ThumbKey, asset: Asset, fileURL: URL?,
                          tier: ThumbTier, operation: Operation) -> CGImage? {
        // 1. disk. `ThumbnailCache.data` validates JPEG completeness and counts the hit itself.
        if let cache, let data = cache.data(for: key), let image = ThumbnailCache.decode(data) {
            remember(image, for: key)
            note { $0.diskHits += 1 }
            return image
        }
        if operation.isCancelled { return nil }

        // 2. produce. A failure is a normal state (006 §2 "失败与超时") — the placeholder stays.
        guard let produced = generate(asset: asset, fileURL: fileURL, tier: tier) else {
            note { $0.failures += 1 }
            return nil
        }
        // 3. write back. The in-flight job finishes and stores even if the UI walked away
        //    (§5: "让它跑完并写盘（不浪费），但结果不推给 UI").
        if let cache { try? cache.store(image: produced, for: key) }
        remember(produced, for: key)
        note { $0.generated += 1 }
        return produced
    }

    private func generate(asset: Asset, fileURL: URL?, tier: ThumbTier) -> CGImage? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        let source: CGImage?
        if asset.kind == .raw {
            // Embedded preview only: `previewImage` never falls through to a RAW decode (§0).
            guard let decoder = rawDecoder() else { return nil }
            source = decoder.preview(fileURL, maxPixelSize: tier.longEdge, strategy: .thumbnail)?.image
        } else {
            // The file already is a rendered JPEG/HEIC: ImageIO's own downscale *is* the fast path,
            // and `CreateThumbnailFromImageIfAbsent` is what lets it use the DCT-scaled decoder.
            source = ThumbnailProvider.imageIOThumbnail(fileURL, maxPixelSize: tier.longEdge)
        }
        guard let source else { return nil }
        // One colour space for every thumbnail: 8-bit sRGB (§1). An AdobeRGB camera JPEG drawn
        // straight into the grid is a whole-grid colour shift.
        return ThumbnailProvider.sRGB8(source)
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

    public func resetStats() {
        lock.lock(); counters = Stats(); lock.unlock()
    }

    public func note(_ mutate: (inout Stats) -> Void) {
        lock.lock(); mutate(&counters); lock.unlock()
    }

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
}

// MARK: - worker

private final class LoadOperation: Operation {
    private let provider: ThumbnailProvider
    private let index: Int
    private let key: ThumbKey
    private let asset: Asset
    private let fileURL: URL?
    private let tier: ThumbTier
    private let completion: @MainActor (Int, ThumbKey, CGImage?) -> Void

    init(provider: ThumbnailProvider, index: Int, key: ThumbKey, asset: Asset, fileURL: URL?,
         tier: ThumbTier, completion: @escaping @MainActor (Int, ThumbKey, CGImage?) -> Void) {
        self.provider = provider
        self.index = index
        self.key = key
        self.asset = asset
        self.fileURL = fileURL
        self.tier = tier
        self.completion = completion
        super.init()
        qualityOfService = .userInitiated
    }

    override func main() {
        // A queued operation that was cancelled never reaches here (OperationQueue drops it); the
        // token counted it. Reaching here cancelled means it was cancelled while starting.
        if isCancelled { return }
        let image = provider.load(index: index, key: key, asset: asset, fileURL: fileURL,
                                  tier: tier, operation: self)
        if isCancelled {
            // The work is not wasted — it was stored — but the cell has moved on (§5).
            return
        }
        guard let image else {
            DispatchQueue.main.async { self.completion(self.index, self.key, nil) }
            return
        }
        provider.note { $0.applied += 1 }
        DispatchQueue.main.async { self.completion(self.index, self.key, image) }
    }
}
