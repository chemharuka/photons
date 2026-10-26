import Foundation
import CryptoKit
import CoreGraphics
import ImageIO

// MARK: - tiers

/// The only sizes that may exist on disk. A tier is part of the cache key, so adding an
/// interpolated one (1.5×, 2.5×) buys one more file per recipe and one more way to go stale —
/// docs/tasks/006-thumbnails.md §1.
public enum ThumbTier: String, Sendable, CaseIterable, Codable {
    case t256, t512, t1024, t2048, t4096

    public var longEdge: Int {
        switch self {
        case .t256: return 256
        case .t512: return 512
        case .t1024: return 1024
        case .t2048: return 2048
        case .t4096: return 4096
        }
    }

    /// Position on the ladder; `tier < other` means "smaller".
    public var rank: Int {
        switch self {
        case .t256: return 0
        case .t512: return 1
        case .t1024: return 2
        case .t2048: return 3
        case .t4096: return 4
        }
    }

    /// Smallest tier whose long edge is at least `px`; clamped to the top of the ladder.
    public static func forPixelEdge(_ px: Int) -> ThumbTier {
        for tier in allCases where tier.longEdge >= px { return tier }
        return .t4096
    }

    /// `px = ceil(longEdgePt × backingScaleFactor)`, then the smallest covering tier (§1).
    public static func forPoints(_ points: Double, backingScale: Double) -> ThumbTier {
        let px = Int((points * backingScale).rounded(.up))
        return forPixelEdge(max(1, px))
    }
}

// MARK: - pipeline + recipe

/// Which producer made the file. `preview` = the camera's embedded JPEG (placeholder, §0);
/// `graph` = `RenderGraph` at this scale (the edit baseline).
public enum ThumbPipeline: String, Sendable, CaseIterable, Codable {
    case preview
    case graph
}

/// The constants that decide pixels, plus the digest that enters the cache key.
///
/// D1/D2′: the decode recipe is frozen. There is deliberately **no** decoder-version parameter
/// anywhere in this type or in `ThumbKey` — a thumbnail may never be produced by `9` or `9.dng`,
/// so "the same file renders differently after a decoder switch" cannot leak into the grid
/// (006 §6.3, §8 #8).
public enum ThumbRecipe {
    public static let decoderRecipe = "v8/boost0/gamutOff"
    /// Kernel semantics version. Bump when a stage's maths changes; it is part of every `graph` key.
    public static let graphVersion = "graph-v1"
    /// A placeholder must survive an edit, so it has no recipe at all (§3).
    public static let placeholderDigest = "-"

    /// `sha256(canonical(develop_json) | decoderRecipe | graphVersion)`.
    ///
    /// Canonical = key-sorted JSON, so two byte-different spellings of the same document (pretty
    /// printed, reordered, `-0.0` vs `0.0` handled by `EditModel`'s own encoding) yield one key.
    /// A non-JSON `develop_json` falls back to the raw string: never crash on a damaged row, just
    /// make the key maximally specific.
    public static func recipeDigest(developJSON: String) -> String {
        let canonical = canonicalJSON(developJSON) ?? developJSON
        return sha256Hex("\(canonical)|\(decoderRecipe)|\(graphVersion)")
    }

    static func canonicalJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(object),
              let canon = try? JSONSerialization.data(withJSONObject: object,
                                                      options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(data: canon, encoding: .utf8)
    }
}

/// Which pipeline is allowed to serve a given tier for a given file (§1 "禁止放大", §6.1 DNG).
public enum ThumbPolicy {
    /// §0 risk table: the P path is only trusted at or below this tier.
    public static let previewMaxTier: ThumbTier = .t1024
    /// §6.1: a DNG's embedded preview is Adobe's rendering, not ours — never the first-screen
    /// *large* image.
    public static let dngPreviewMaxTier: ThumbTier = .t512

    public static func previewTierLimit(ext: String) -> ThumbTier {
        ext.lowercased() == "dng" ? dngPreviewMaxTier : previewMaxTier
    }

    /// `true` when the embedded preview may stand in for this tier.
    ///
    /// Two independent vetoes: the file's own preview must be large enough (upscaling 1616 → 2048
    /// is the "looks detailed" lie of §1), and the tier must be inside the pipeline's ceiling.
    public static func previewAllowed(tier: ThumbTier, sourceLongEdge: Int, ext: String) -> Bool {
        guard tier.rank <= previewTierLimit(ext: ext).rank else { return false }
        return sourceLongEdge >= tier.longEdge
    }
}

// MARK: - key

/// Identity of one thumbnail file: content-addressed, never asset-addressed, so a moved or renamed
/// file (M2 `moved`) and a duplicate copy share one cached image (§3).
public struct ThumbKey: Hashable, Sendable {
    public let contentHash: String
    public let tier: ThumbTier
    public let pipeline: ThumbPipeline
    public let recipeDigest: String

    /// `preview` keys always carry `-`: a placeholder must not be invalidated by an edit, or the
    /// first frame after a commit would have nothing to draw.
    public init(contentHash: String, tier: ThumbTier, pipeline: ThumbPipeline, recipeDigest: String) {
        self.contentHash = contentHash
        self.tier = tier
        self.pipeline = pipeline
        self.recipeDigest = pipeline == .preview ? ThumbRecipe.placeholderDigest : recipeDigest
    }

    public static func preview(contentHash: String, tier: ThumbTier) -> ThumbKey {
        ThumbKey(contentHash: contentHash, tier: tier, pipeline: .preview,
                 recipeDigest: ThumbRecipe.placeholderDigest)
    }

    public static func graph(contentHash: String, tier: ThumbTier, developJSON: String) -> ThumbKey {
        ThumbKey(contentHash: contentHash, tier: tier, pipeline: .graph,
                 recipeDigest: ThumbRecipe.recipeDigest(developJSON: developJSON))
    }

    /// The exact string that gets hashed. Kept public and stable so `grep` on a cache directory
    /// explains itself and so the format can be asserted in a unit test.
    public var keyString: String {
        "thumb|v1|\(contentHash)|\(tier.rawValue)|\(pipeline.rawValue)|\(recipeDigest)"
    }

    /// 64 hex chars; also the file name (minus `.jpg`).
    public var digest: String { sha256Hex(keyString) }

    public var shard0: String { String(digest.prefix(2)) }
    public var shard1: String {
        let s = digest
        let start = s.index(s.startIndex, offsetBy: 2)
        let end = s.index(s.startIndex, offsetBy: 4)
        return String(s[start..<end])
    }

    /// Path inside a cache root: `thumbs/xx/yy/<digest>.jpg` (§3).
    public func relativePath(in root: URL) -> URL {
        root.appendingPathComponent(shard0, isDirectory: true)
            .appendingPathComponent(shard1, isDirectory: true)
            .appendingPathComponent("\(digest).jpg", isDirectory: false)
    }
}

// MARK: - digest helpers

func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

// MARK: - cache

public enum ThumbCacheError: LocalizedError {
    case notJPEG(URL)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notJPEG(let u): return "refusing to cache a non-JPEG payload at \(u.lastPathComponent)"
        case .writeFailed(let m): return "thumbnail cache write failed: \(m)"
        }
    }
}

/// Content-addressed thumbnail files under `~/Library/Caches/Photons/<libHash>/thumbs/`.
///
/// Files, not SQLite BLOBs (§3): a package must stay copyable, deleted BLOBs do not return space
/// without a `VACUUM`, and the filesystem already gives atomic `rename`, `mtime` LRU and
/// one-syscall `lstat` existence checks. Nothing here is a source of truth: losing the directory
/// costs one regeneration, so there is no `fsync` and no journal.
public final class ThumbnailCache {

    /// Eviction budget and the two grace windows. Exposed so tests can drive the policy without
    /// waiting ten minutes for reality.
    public struct TrimPolicy: Sendable {
        /// Default 2 GB, configurable 512 MB – 20 GB in `settings` (§3).
        public var budgetBytes: Int64
        /// Files written this recently are never evicted: do not pull the rug out from under the
        /// window the user is looking at.
        public var protectWindow: TimeInterval
        /// `t2048`/`t4096` untouched this long are evicted before the global LRU pass.
        public var staleAfter: TimeInterval

        public init(budgetBytes: Int64 = 2_000_000_000,
                    protectWindow: TimeInterval = 600,
                    staleAfter: TimeInterval = 30 * 86_400) {
            self.budgetBytes = budgetBytes
            self.protectWindow = protectWindow
            self.staleAfter = staleAfter
        }
    }

    public struct Stats: Sendable, Codable {
        public var hits = 0
        public var misses = 0
        public var writes = 0
        public var evicted = 0
        public var bytesWritten: Int64 = 0
        /// Misses by reason. `absent` is normal; anything else (`corrupt`) means a bug or a
        /// damaged disk and is a hard failure in acceptance run #1.
        public var missReasons: [String: Int] = [:]

        public var lookups: Int { hits + misses }
        public var hitRatio: Double { lookups == 0 ? 0 : Double(hits) / Double(lookups) }
    }

    public struct TrimReport: Sendable {
        public var totalBefore: Int64 = 0
        public var totalAfter: Int64 = 0
        public var evicted = 0
        public var freedBytes: Int64 = 0
        public var shadowedPreviews = 0
        public var staleLarge = 0
        public var lru = 0
        public var tempFiles = 0
    }

    public let root: URL
    public var policy: TrimPolicy
    private let fm = FileManager.default
    private let lock = NSLock()
    private var counters = Stats()
    /// At most one mtime touch per (key, process) — otherwise every grid read rewrites an inode
    /// (§3).
    private var touched: Set<String> = []

    public convenience init(layout: LibraryLayout, policy: TrimPolicy = TrimPolicy()) throws {
        try self.init(root: layout.cacheDirectory.appendingPathComponent("thumbs", isDirectory: true),
                      policy: policy)
    }

    public init(root: URL, policy: TrimPolicy = TrimPolicy()) throws {
        self.root = root.standardizedFileURL
        self.policy = policy
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    // MARK: paths

    public func url(for key: ThumbKey) -> URL { key.relativePath(in: root) }

    public func exists(_ key: ThumbKey) -> Bool {
        fm.fileExists(atPath: url(for: key).path)
    }

    // MARK: read

    /// The cached JPEG bytes, or `nil` on a miss (which is *counted*).
    ///
    /// A file that exists but is not a complete JPEG is treated as a miss and removed: a truncated
    /// file must never be handed to the decoder as if it were an image.
    public func data(for key: ThumbKey, now: Date = Date()) -> Data? {
        let path = url(for: key)
        guard let data = try? Data(contentsOf: path) else {
            record(miss: "absent")
            return nil
        }
        guard ThumbnailJPEGComplete(data) else {
            record(miss: "corrupt")
            try? fm.removeItem(at: path)
            return nil
        }
        record(hit: true)
        touchOnce(path.path, now: now)
        return data
    }

    /// Hot path: file read + JPEG decode. Both happen off the main thread in the app (§1).
    public func image(for key: ThumbKey, now: Date = Date()) -> CGImage? {
        guard let data = data(for: key, now: now) else { return nil }
        return Self.decode(data)
    }

    public static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    // MARK: write

    /// Write `.tmp` then `rename` — same volume, therefore atomic (§3).
    ///
    /// No `fsync`: derived data, regenerating is cheaper than an I/O barrier. A crash can lose the
    /// file, never a half file: the final name only ever appears after the bytes are all there.
    public func store(_ data: Data, for key: ThumbKey) throws {
        guard ThumbnailJPEGComplete(data) else {
            throw ThumbCacheError.notJPEG(url(for: key))
        }
        let dest = url(for: key)
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Unique temp name: two workers may race on the same key (single-flight is a service-layer
        // promise, not a cache-layer one); last writer wins and neither sees a torn file.
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent(".\(key.digest).tmp-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))")
        do {
            try data.write(to: tmp, options: [.withoutOverwriting])
        } catch {
            try? fm.removeItem(at: tmp)
            throw ThumbCacheError.writeFailed("\(error)")
        }
        // POSIX rename(2): atomic replace, no window where the name points at nothing.
        if rename(tmp.path, dest.path) != 0 {
            let code = errno
            try? fm.removeItem(at: tmp)
            throw ThumbCacheError.writeFailed("rename \(tmp.lastPathComponent) → \(dest.lastPathComponent) errno \(code)")
        }
        lock.lock()
        counters.writes += 1
        counters.bytesWritten += Int64(data.count)
        lock.unlock()

        // §0: once the faithful rendering exists at this tier, the placeholder is dead weight at
        // *this* tier. Deleting it keeps "placeholder → refined" a one-way transition.
        if key.pipeline == .graph {
            pruneShadowedPreview(for: key)
        }
    }

    public func store(image: CGImage, for key: ThumbKey, quality: Double = ThumbnailJPEG.quality) throws {
        guard let data = ThumbnailJPEG.encode(image, quality: quality) else {
            throw ThumbCacheError.writeFailed("JPEG encode returned nil")
        }
        try store(data, for: key)
    }

    private func pruneShadowedPreview(for key: ThumbKey) {
        let shadow = ThumbKey.preview(contentHash: key.contentHash, tier: key.tier)
        try? fm.removeItem(at: url(for: shadow))
    }

    // MARK: removal

    /// Drop every file this content hash owns, at every tier and pipeline. Returns how many files
    /// were actually removed.
    ///
    /// Deleting a library entry must not leave its pixels behind: the key is content-addressed, so
    /// nothing else will ever look at them again, and a re-import of the same bytes would then hit a
    /// thumbnail produced by an *edit* the user just deleted. `developJSONs` is the set of documents
    /// whose `graph` recipes may exist on disk (the row's own `develop_json`, plus `{}` for the
    /// neutral baseline); a recipe we are not told about can only be found by a full `trim()` pass.
    ///
    /// Not `fsync`ed and not journalled, like every other write here: the cache is derived data, so
    /// the worst case of a crash mid-removal is one stale file that `trim()` will evict.
    @discardableResult
    public func removeAll(contentHash: String, developJSONs: [String] = ["{}"]) -> Int {
        var removed = 0
        let recipes = developJSONs.isEmpty ? ["{}"] : Array(Set(developJSONs))
        for tier in ThumbTier.allCases {
            var keys = [ThumbKey.preview(contentHash: contentHash, tier: tier)]
            for json in recipes {
                keys.append(.graph(contentHash: contentHash, tier: tier, developJSON: json))
            }
            for key in keys {
                let path = url(for: key)
                guard fm.fileExists(atPath: path.path) else { continue }
                if (try? fm.removeItem(at: path)) != nil { removed += 1 }
            }
        }
        lock.lock()
        touched = touched.filter { !$0.contains(contentHash) }
        lock.unlock()
        return removed
    }

    // MARK: LRU

    /// Mark a hit as recently used. Once per key per process: hits are read-only in the common
    /// case, and an mtime write per grid scroll would cost more than the read it decorates.
    private func touchOnce(_ path: String, now: Date) {
        lock.lock()
        let first = touched.insert(path).inserted
        lock.unlock()
        guard first else { return }
        try? fm.setAttributes([.modificationDate: now], ofItemAtPath: path)
    }

    /// Existence check that does **not** count as a hit (used by prefetch / policy probes).
    public func peek(_ key: ThumbKey) -> Bool { fm.fileExists(atPath: url(for: key).path) }

    /// Everything currently on disk: (url, bytes, mtime).
    public func inventory() -> [(url: URL, bytes: Int64, modified: Date)] {
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [(url: URL, bytes: Int64, modified: Date)] = []
        for case let u as URL in en where u.pathExtension.lowercased() == "jpg" {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            out.append((url: u, bytes: Int64(v?.fileSize ?? 0),
                        modified: v?.contentModificationDate ?? .distantPast))
        }
        return out.sorted { $0.modified < $1.modified }
    }

    public func totalBytes() -> Int64 { inventory().reduce(0) { $0 + $1.bytes } }

    /// Evict until the directory fits the budget.
    ///
    /// Order (§3): ① previews that already have a `graph` counterpart at the same tier;
    /// ② `t2048`/`t4096` untouched for `staleAfter`; ③ everything else, oldest `mtime` first.
    /// Files inside `protectWindow` are never touched by any pass.
    ///
    /// `knownKeys` is how ① and ② are possible at all: a file name is the digest of
    /// `<contentHash>|<tier>|<pipeline>|<recipe>`, so neither tier nor pipeline can be recovered
    /// from the path — the owner of the catalog has to say which keys it believes exist. Two
    /// consequences worth stating: matching is by **file name digest**, never by path string (the
    /// same file answers to `/var/…` and `/private/var/…`); and a `graph` key needs the asset's
    /// real `develop_json`, because `{}` is only one of the recipes that may exist (A→B→A leaves
    /// two). Without `knownKeys` the cache still does a correct global LRU — it just cannot apply
    /// the two cheaper rules first.
    @discardableResult
    public func trim(now: Date = Date(), knownKeys: [ThumbKey] = []) -> TrimReport {
        var report = TrimReport()
        let items = inventory()
        report.totalBefore = items.reduce(0) { $0 + $1.bytes }

        var keyOf: [String: ThumbKey] = [:]
        for key in knownKeys { keyOf[key.digest] = key }
        let present = Set(items.map { $0.url.deletingPathExtension().lastPathComponent })
        // `hash|tier` pairs that already have a graph rendering on disk. A set, not a scan: this
        // sweep runs over 50k files and a nested loop would make it O(n²).
        var graphPresent: Set<String> = []
        for key in knownKeys where key.pipeline == .graph && present.contains(key.digest) {
            graphPresent.insert("\(key.contentHash)|\(key.tier.rawValue)")
        }

        guard report.totalBefore > policy.budgetBytes else {
            report.totalAfter = report.totalBefore
            cleanTempFiles(now: now, report: &report)
            return report
        }

        var remaining = report.totalBefore
        var removed: Set<String> = []

        /// One eviction attempt. Returns the bytes freed (0 = refused), and mutates no `report`
        /// state: passing `&report.field` into a closure that also captures `report` is an
        /// overlapping exclusive access, which traps at runtime.
        func evict(_ item: (url: URL, bytes: Int64, modified: Date)) -> Int64 {
            guard remaining > policy.budgetBytes else { return 0 }
            guard now.timeIntervalSince(item.modified) >= policy.protectWindow else { return 0 }
            guard !removed.contains(item.url.path) else { return 0 }
            guard (try? fm.removeItem(at: item.url)) != nil else { return 0 }
            removed.insert(item.url.path)
            remaining -= item.bytes
            return item.bytes
        }

        // ① a placeholder whose faithful rendering exists at the same tier. `store(graph:)` deletes
        // it immediately in the common case; this catches what older runs and cancelled writes left.
        for item in items {
            let digest = item.url.deletingPathExtension().lastPathComponent
            guard let key = keyOf[digest], key.pipeline == .preview else { continue }
            // Any recipe for that (content, tier) makes the placeholder redundant.
            if graphPresent.contains("\(key.contentHash)|\(key.tier.rawValue)") {
                let freed = evict(item)
                if freed > 0 { report.shadowedPreviews += 1; report.evicted += 1; report.freedBytes += freed }
            }
        }

        // ② big tiers gone stale.
        for item in items where remaining > policy.budgetBytes {
            let digest = item.url.deletingPathExtension().lastPathComponent
            guard let key = keyOf[digest], key.tier.rank >= ThumbTier.t2048.rank else { continue }
            guard now.timeIntervalSince(item.modified) > policy.staleAfter else { continue }
            let freed = evict(item)
            if freed > 0 { report.staleLarge += 1; report.evicted += 1; report.freedBytes += freed }
        }

        // ③ global LRU (items are already mtime-ascending).
        for item in items where remaining > policy.budgetBytes {
            let freed = evict(item)
            if freed > 0 { report.lru += 1; report.evicted += 1; report.freedBytes += freed }
        }

        cleanTempFiles(now: now, report: &report)
        report.totalAfter = remaining
        lock.lock(); counters.evicted += report.evicted; lock.unlock()
        return report
    }

    /// Crash leftovers: a `.tmp-…` older than an hour lost its writer.
    private func cleanTempFiles(now: Date, report: inout TrimReport) {
        var stack: [URL] = [root]
        while let dir = stack.popLast() {
            let children = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys:
                            [.isDirectoryKey, .contentModificationDateKey])) ?? []
            for child in children {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { stack.append(child); continue }
                guard child.lastPathComponent.contains(".tmp-") else { continue }
                let mtime = (try? child.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                if now.timeIntervalSince(mtime) > 3600, (try? fm.removeItem(at: child)) != nil {
                    report.tempFiles += 1
                }
            }
        }
    }

    // MARK: stats

    public func stats() -> Stats {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    public func resetStats() {
        lock.lock(); counters = Stats(); touched.removeAll(); lock.unlock()
    }

    private func record(hit: Bool) {
        lock.lock()
        if hit { counters.hits += 1 } else { counters.misses += 1 }
        lock.unlock()
    }

    private func record(miss reason: String) {
        lock.lock()
        counters.misses += 1
        counters.missReasons[reason, default: 0] += 1
        lock.unlock()
    }
}

/// 8-bit sRGB JPEG, quality 0.82 — the one encoding every thumbnail uses (006 §1).
///
/// Lives next to the cache because it *is* the on-disk format: if the encoder changes, every file
/// on disk becomes stale, so the two must be read together. No metadata is carried over — a
/// thumbnail must not smuggle EXIF/GPS (006 §9).
public enum ThumbnailJPEG {
    public static let quality: Double = 0.82

    public static func encode(_ image: CGImage, quality: Double = ThumbnailJPEG.quality) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            // Explicit sRGB tag: ImageIO would otherwise copy the source profile across.
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// JPEG completeness: SOI at the head and EOI at the tail. A truncated write fails this, which
    /// is exactly "a half-written file must not be served" (006 §3).
    public static func looksComplete(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let head = [UInt8](data.prefix(2))
        let tail = [UInt8](data.suffix(2))
        return head == [0xFF, 0xD8] && tail == [0xFF, 0xD9]
    }
}

private func ThumbnailJPEGComplete(_ data: Data) -> Bool { ThumbnailJPEG.looksComplete(data) }
