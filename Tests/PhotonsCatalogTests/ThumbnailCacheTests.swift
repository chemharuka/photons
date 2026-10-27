import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsCatalog

/// M3.5 cache contract: content-addressed keys, atomic writes, LRU, tier policy.
/// Every assertion here is one of the executable acceptance checks written for M3.5: content
/// addressing, atomic `rename`, LRU budget, tier policy, and no upscaling past the embedded preview.
final class ThumbnailCacheTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-thumb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: helpers

    /// A real JPEG: the cache must refuse anything that is not one.
    private func jpeg(_ size: Int = 16) throws -> Data {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let img = ctx.makeImage()!
        return try XCTUnwrap(ThumbnailJPEG.encode(img), "JPEG encoder returned nil")
    }

    private func write(_ key: ThumbKey, to cache: ThumbnailCache, mtime: Date? = nil) throws {
        try cache.store(try jpeg(), for: key)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: cache.url(for: key).path)
        }
    }

    private func hash(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    // MARK: ① key stability

    func testKeyIsStableForSameInput() throws {
        let a = ThumbKey.preview(contentHash: hash("a"), tier: .t256)
        let b = ThumbKey.preview(contentHash: hash("a"), tier: .t256)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.digest, b.digest, "the same inputs must hash to the same cache file")
        XCTAssertEqual(a.keyString, "thumb|v1|\(hash("a"))|t256|preview|-")
        XCTAssertEqual(a.digest.count, 64)
        XCTAssertTrue(a.digest.allSatisfy { $0.isHexDigit })
    }

    func testKeyChangesWithTierPipelineAndRecipe() throws {
        let base = ThumbKey(contentHash: hash("a"), tier: .t256, pipeline: .graph,
                            recipeDigest: ThumbRecipe.recipeDigest(developJSON: "{}"))
        let otherTier = ThumbKey(contentHash: hash("a"), tier: .t512, pipeline: .graph,
                                 recipeDigest: ThumbRecipe.recipeDigest(developJSON: "{}"))
        let otherRecipe = ThumbKey(contentHash: hash("a"), tier: .t256, pipeline: .graph,
                                   recipeDigest: ThumbRecipe.recipeDigest(developJSON: #"{"light":{"exposureEV":1}}"#))
        let otherHash = ThumbKey(contentHash: hash("b"), tier: .t256, pipeline: .graph,
                                 recipeDigest: base.recipeDigest)

        XCTAssertNotEqual(base.digest, otherTier.digest, "tier is part of the key")
        XCTAssertNotEqual(base.digest, otherRecipe.digest, "an edit must produce a new key")
        XCTAssertNotEqual(base.digest, otherHash.digest, "identity is the content hash, not the asset id")
        XCTAssertEqual(Set([base.digest, otherTier.digest, otherRecipe.digest, otherHash.digest]).count, 4)
    }

    /// §3: a placeholder must survive an edit — that is the whole "first frame always has something
    /// to draw" guarantee. The initialiser therefore *forces* `-` for `preview`, whatever is passed.
    func testPreviewKeyIgnoresRecipeDigest() throws {
        let forged = ThumbKey(contentHash: hash("a"), tier: .t256, pipeline: .preview,
                              recipeDigest: "an-edit-happened")
        XCTAssertEqual(forged.recipeDigest, ThumbRecipe.placeholderDigest)
        XCTAssertEqual(forged.digest, ThumbKey.preview(contentHash: hash("a"), tier: .t256).digest)
    }

    /// A→B→A must land on A's old file (§4, acceptance #5). Digests are idempotent where a
    /// monotonic `render_version` would not be.
    func testRecipeDigestIsIdempotentAcrossEdits() throws {
        let a = ThumbRecipe.recipeDigest(developJSON: #"{"light":{"exposureEV":0.5}}"#)
        let b = ThumbRecipe.recipeDigest(developJSON: #"{"light":{"exposureEV":1.0}}"#)
        let aAgain = ThumbRecipe.recipeDigest(developJSON: #"{"light":{"exposureEV":0.5}}"#)
        XCTAssertEqual(a, aAgain)
        XCTAssertNotEqual(a, b)
        // Key order and whitespace are the same document.
        let reformatted = ThumbRecipe.recipeDigest(developJSON: "{\n  \"light\" : { \"exposureEV\" : 0.5 }\n}")
        XCTAssertEqual(a, reformatted, "canonical JSON: formatting must not create a second cache entry")
    }

    /// §6.3 / §8 #8: the decode recipe is frozen and the key builder takes no version argument.
    func testDecoderRecipeIsFrozen() throws {
        XCTAssertEqual(ThumbRecipe.decoderRecipe, "v8/boost0/gamutOff")
        XCTAssertFalse(ThumbKey.preview(contentHash: hash("a"), tier: .t256).keyString.contains("9"))
        XCTAssertTrue(ThumbRecipe.graphVersion.isEmpty == false)
        // The recipe text is inside the key material even though the digest is opaque.
        XCTAssertFalse(ThumbRecipe.recipeDigest(developJSON: "{}").isEmpty)
    }

    // MARK: ② atomic writes

    func testStoreThenHit() throws {
        let cache = try ThumbnailCache(root: root)
        let key = ThumbKey.preview(contentHash: hash("a"), tier: .t256)
        let payload = try jpeg()

        XCTAssertNil(cache.data(for: key), "cold read must miss")
        XCTAssertEqual(cache.stats().missReasons["absent"], 1)

        try cache.store(payload, for: key)
        XCTAssertEqual(cache.data(for: key), payload)
        XCTAssertEqual(cache.stats().hits, 1)
        XCTAssertEqual(cache.stats().writes, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.url(for: key).path))
    }

    /// A writer that dies mid-file leaves `.tmp-…`, never the final name. The final name must also
    /// disappear between the write and the rename is *not* a state we ever expose: rename(2) is
    /// atomic, so "exists but truncated" can only come from disk damage — which the completeness
    /// check turns into a miss instead of a grey square.
    func testHalfWrittenFileNeverHits() throws {
        let cache = try ThumbnailCache(root: root)
        let key = ThumbKey.preview(contentHash: hash("a"), tier: .t256)
        let dest = cache.url(for: key)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Leftover temp from a crashed writer, sitting where the store would have put it.
        let tmp = dest.deletingLastPathComponent().appendingPathComponent(".\(key.digest).tmp-1-dead")
        try Data([0xFF, 0xD8, 0xFF]).write(to: tmp)

        XCTAssertNil(cache.data(for: key), "a .tmp file is not a cache entry")
        XCTAssertEqual(cache.stats().missReasons["absent"], 1)
        XCTAssertFalse(cache.exists(key))

        // A truncated file at the final path: unsendable, and reported as `corrupt`, not `absent`.
        try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: dest)
        XCTAssertNil(cache.data(for: key))
        XCTAssertEqual(cache.stats().missReasons["corrupt"], 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "a corrupt entry is removed, not retried forever")

        // Now a real one.
        try cache.store(try jpeg(), for: key)
        XCTAssertNotNil(cache.data(for: key))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
            .filter { $0.contains(".tmp-") }
        XCTAssertEqual(leftovers.count, 1, "only the one we planted; store must not leave its own temp behind")
    }

    func testStoreRejectsNonJPEG() throws {
        let cache = try ThumbnailCache(root: root)
        let key = ThumbKey.preview(contentHash: hash("a"), tier: .t256)
        XCTAssertThrowsError(try cache.store(Data("not a jpeg".utf8), for: key))
        XCTAssertFalse(cache.exists(key))
    }

    // MARK: layout

    /// `thumbs/<namespace>/xx/yy/<digest>.jpg` — the namespace (P1f) is what makes "which generation
    /// of the arithmetic wrote this file?" a directory instead of an unanswerable question about a
    /// sha256. A placeholder goes under `p`, a graph file under `g-<fingerprint>`, and neither can be
    /// confused for the other by path.
    func testPathLayoutIsShardedByName() throws {
        let cache = try ThumbnailCache(root: root)
        let key = ThumbKey.preview(contentHash: hash("a"), tier: .t512)
        let url = cache.url(for: key)
        XCTAssertEqual(url.lastPathComponent, "\(key.digest).jpg")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                       String(key.digest.dropFirst(2).prefix(2)))
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
                       String(key.digest.prefix(2)))
        // …and the namespace above the shards: `p` here, `g-<fingerprint>` for a graph key.
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().lastPathComponent, ThumbNamespace.preview)
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().deletingLastPathComponent()
                        .standardizedFileURL.path, root.standardizedFileURL.path)

        let graph = ThumbKey.graph(contentHash: hash("a"), tier: .t512, developJSON: "{}")
        XCTAssertEqual(graph.namespace, "g-" + StageAlgorithmVersion.fingerprint)
        XCTAssertTrue(cache.url(for: graph).path.contains("/g-\(StageAlgorithmVersion.fingerprint)/"))
        XCTAssertNotEqual(graph.namespace, key.namespace, "the two pipelines never share a directory")
    }

    // MARK: ③ LRU

    func testTrimEvictsOldestFirst() throws {
        let cache = try ThumbnailCache(root: root)
        // Four distinct keys, written oldest-last so the surviving order proves it uses mtime and
        // not write order.
        var distinct: [ThumbKey] = []
        for i in 0..<4 {
            distinct.append(.preview(contentHash: String(repeating: String(i), count: 64), tier: .t256))
        }

        let now = Date()
        for (i, key) in distinct.enumerated() {
            try write(key, to: cache, mtime: now.addingTimeInterval(-Double(4 - i) * 86_400))
        }
        let perFile = Int64(try jpeg().count)
        XCTAssertEqual(cache.totalBytes(), perFile * 4)

        // Room for two files plus a byte: two evictions.
        cache.policy = .init(budgetBytes: perFile * 2 + 1, protectWindow: 0, staleAfter: 30 * 86_400)
        let report = cache.trim(now: now)

        XCTAssertEqual(report.evicted, 2)
        XCTAssertLessThanOrEqual(cache.totalBytes(), perFile * 2 + 1)
        XCTAssertFalse(cache.exists(distinct[0]), "oldest (4 days) evicted first")
        XCTAssertFalse(cache.exists(distinct[1]), "then the 3-day-old")
        XCTAssertTrue(cache.exists(distinct[2]), "the 2-day-old survives")
        XCTAssertTrue(cache.exists(distinct[3]), "the freshest survives")
    }

    /// §3: files written in the last ten minutes are untouchable — do not evict the window the
    /// user is looking at.
    func testTrimProtectsRecentWrites() throws {
        let cache = try ThumbnailCache(root: root)
        let now = Date()
        for i in 0..<3 {
            let key = ThumbKey.preview(contentHash: String(repeating: String(i), count: 64), tier: .t256)
            try write(key, to: cache, mtime: now.addingTimeInterval(-60))
        }
        cache.policy = .init(budgetBytes: 10, protectWindow: 600, staleAfter: 30 * 86_400)
        let report = cache.trim(now: now)
        XCTAssertEqual(report.evicted, 0, "everything was written a minute ago")
    }

    /// §0: once the faithful rendering exists at a tier, the placeholder at that tier is deleted —
    /// "placeholder → refined" happens once, never back and forth.
    func testGraphWriteRemovesShadowedPreview() throws {
        let cache = try ThumbnailCache(root: root)
        let preview = ThumbKey.preview(contentHash: hash("a"), tier: .t512)
        let graph = ThumbKey.graph(contentHash: hash("a"), tier: .t512, developJSON: "{}")
        try write(preview, to: cache)
        XCTAssertTrue(cache.exists(preview))

        try write(graph, to: cache)
        XCTAssertFalse(cache.exists(preview), "the placeholder at the same tier is dead weight")
        XCTAssertTrue(cache.exists(graph))
        // A different tier's placeholder is untouched: the grid still needs it.
        let other = ThumbKey.preview(contentHash: hash("a"), tier: .t256)
        try write(other, to: cache)
        try write(ThumbKey.graph(contentHash: hash("a"), tier: .t512, developJSON: #"{"a":1}"#), to: cache)
        XCTAssertTrue(cache.exists(other))
    }

    /// Trim order ①: shadowed previews go before anything else, even when they are the newest file.
    func testTrimDropsShadowedPreviewsBeforeLRU() throws {
        let cache = try ThumbnailCache(root: root)
        let content = hash("a")
        let now = Date()
        let old = ThumbKey.preview(contentHash: hash("b"), tier: .t256)
        let shadowed = ThumbKey.preview(contentHash: content, tier: .t256)
        let graph = ThumbKey.graph(contentHash: content, tier: .t256, developJSON: "{}")

        try write(old, to: cache, mtime: now.addingTimeInterval(-3 * 86_400))
        // Sorted by mtime the shadowed preview is *newest*, so only rule ① can pick it.
        try write(shadowed, to: cache, mtime: now.addingTimeInterval(-60))
        try write(graph, to: cache, mtime: now.addingTimeInterval(-30))

        cache.policy = .init(budgetBytes: Int64(try jpeg().count) * 2, protectWindow: 0)
        // Re-plant: store(graph:) already deleted the shadow, so put it back to test rule ①.
        try Data(try jpeg()).write(to: cache.url(for: shadowed))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-60)],
                                              ofItemAtPath: cache.url(for: shadowed).path)

        let report = cache.trim(now: now, knownKeys: [shadowed, graph])
        XCTAssertEqual(report.shadowedPreviews, 1, "the preview with a graph sibling is evicted by rule ①")
        XCTAssertFalse(cache.exists(shadowed))
        XCTAssertTrue(cache.exists(graph), "the faithful rendering is what we keep")
    }

    func testTrimDropsStaleLargeTiers() throws {
        let cache = try ThumbnailCache(root: root)
        let content = hash("a")
        let now = Date()
        // t2048 is above the preview ceiling, so a graph key is the realistic owner of that tier.
        let staleGraph = ThumbKey.graph(contentHash: content, tier: .t2048, developJSON: "{}")
        let small = ThumbKey.graph(contentHash: content, tier: .t256, developJSON: "{}")

        try write(staleGraph, to: cache, mtime: now.addingTimeInterval(-40 * 86_400))
        try write(small, to: cache, mtime: now.addingTimeInterval(-40 * 86_400))

        cache.policy = .init(budgetBytes: Int64(try jpeg().count), protectWindow: 0, staleAfter: 30 * 86_400)
        let report = cache.trim(now: now, knownKeys: [staleGraph, small])
        XCTAssertEqual(report.staleLarge, 1, "t2048 untouched for 40 days goes first")
        XCTAssertFalse(cache.exists(staleGraph))
        XCTAssertTrue(cache.exists(small), "t256 is below the stale-large rule")
    }

    // MARK: tier policy (§1, §6.1)

    func testTierLadderSelection() throws {
        XCTAssertEqual(ThumbTier.forPixelEdge(1), .t256)
        XCTAssertEqual(ThumbTier.forPixelEdge(256), .t256)
        XCTAssertEqual(ThumbTier.forPixelEdge(257), .t512)
        XCTAssertEqual(ThumbTier.forPixelEdge(1024), .t1024)
        XCTAssertEqual(ThumbTier.forPixelEdge(1025), .t2048)
        XCTAssertEqual(ThumbTier.forPixelEdge(4096), .t4096)
        XCTAssertEqual(ThumbTier.forPixelEdge(99_999), .t4096, "clamped to the top of the ladder")
    }

    func testDevicePixelRatioSelection() throws {
        // Grid cell ≤ 200 pt at 1x/2x, filmstrip at 2x, 6K XDR full screen at 2x (3384 pt → 6768 px).
        XCTAssertEqual(ThumbTier.forPoints(200, backingScale: 1), .t256)
        XCTAssertEqual(ThumbTier.forPoints(200, backingScale: 2), .t512)
        XCTAssertEqual(ThumbTier.forPoints(300, backingScale: 2), .t1024)
        XCTAssertEqual(ThumbTier.forPoints(3384, backingScale: 2), .t4096, "6K XDR fit @2x lands on t4096")
        // ceil, not round: 200.5 pt @2x = 401 px, which must not fall into t256.
        XCTAssertEqual(ThumbTier.forPoints(200.5, backingScale: 2), .t512)
    }

    func testPreviewNeverUpscalesAndDNGIsCapped() throws {
        // Measured embedded preview sizes (§11.2).
        XCTAssertFalse(ThumbPolicy.previewAllowed(tier: .t2048, sourceLongEdge: 1616, ext: "ARW"),
                       "1616 → 2048 is upscaling: the grid must render instead")
        XCTAssertTrue(ThumbPolicy.previewAllowed(tier: .t1024, sourceLongEdge: 1616, ext: "ARW"))
        // RW2's 1920 px preview covers t1024 but not t2048 — the tier, not the camera, decides.
        XCTAssertTrue(ThumbPolicy.previewAllowed(tier: .t1024, sourceLongEdge: 1920, ext: "RW2"))
        XCTAssertFalse(ThumbPolicy.previewAllowed(tier: .t2048, sourceLongEdge: 1920, ext: "RW2"))
        XCTAssertTrue(ThumbPolicy.previewAllowed(tier: .t512, sourceLongEdge: 1920, ext: "RW2"))
        // §6.1: a DNG's embedded preview is Adobe's rendering — never our large first-screen image.
        XCTAssertTrue(ThumbPolicy.previewAllowed(tier: .t512, sourceLongEdge: 8192, ext: "DNG"))
        XCTAssertFalse(ThumbPolicy.previewAllowed(tier: .t1024, sourceLongEdge: 8192, ext: "dng"))
    }
}
