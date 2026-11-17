import Foundation
import CryptoKit
import PhotonsCore

public struct HistogramCacheKey: Hashable, Codable, Sendable {
    public let content: String
    public let recipe: String
    public init(thumbnail: ThumbKey) {
        content = thumbnail.contentHash
        recipe = "histogram-v1|\(thumbnail.digest)"
    }
    var fileName: String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public extension Notification.Name {
    static let photonsHistogramCached = Notification.Name("photons.histogramCached")
}

/// Per-library, disposable disk cache. A file keeps only the latest edit of a content hash;
/// the bounded memory LRU can also serve recent undo states. No SQLite/catalog migration.
public final class HistogramCache: @unchecked Sendable {
    private struct Entry: Codable { let key: HistogramCacheKey; let snapshot: HistogramSnapshot }
    private final class Box: NSObject {
        let snapshot: HistogramSnapshot
        init(_ value: HistogramSnapshot) { snapshot = value }
    }
    public struct Stats: Sendable {
        public var diskHits = 0
        public var writes = 0
        public var computations = 0
        public var previewBackfills = 0
    }
    public let root: URL
    private let memory = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var counters = Stats()
    private var memoryGeneration: UInt64 = 0
    public var generation: UInt64 { PreviewCacheStorage.generation(in: root.deletingLastPathComponent()) }

    private func synchronizeMemory() {
        let current = generation
        lock.lock(); defer { lock.unlock() }
        if current != memoryGeneration { memory.removeAllObjects(); memoryGeneration = current }
    }
    public var stats: Stats { lock.lock(); defer { lock.unlock() }; return counters }

    public init(root: URL) {
        self.root = root
        memory.countLimit = 512
    }
    public func cached(_ key: HistogramCacheKey) -> HistogramSnapshot? {
        synchronizeMemory()
        return memory.object(forKey: key.recipe as NSString)?.snapshot
    }
    public func url(for key: HistogramCacheKey) -> URL {
        root.appendingPathComponent(String(key.fileName.prefix(2)), isDirectory: true)
            .appendingPathComponent(key.fileName + ".plist")
    }
    /// Worker queues only. A corrupt/outdated file is a miss, never a broken library.
    public func load(_ key: HistogramCacheKey) -> HistogramSnapshot? {
        let currentGeneration = generation
        return PreviewCacheStorage.publish(in: root.deletingLastPathComponent(), generation: currentGeneration) {
            if let value = cached(key) { return value }
            lock.lock(); defer { lock.unlock() }
            let path = url(for: key)
            guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 128 * 1024, let data = try? Data(contentsOf: path),
                  let entry = try? PropertyListDecoder().decode(Entry.self, from: data),
                  entry.key == key, entry.snapshot.isValid else { return nil }
            counters.diskHits += 1
            memory.setObject(Box(entry.snapshot), forKey: key.recipe as NSString)
            return entry.snapshot
        } ?? nil
    }
    public func store(_ value: HistogramSnapshot, for key: HistogramCacheKey, fromPreview: Bool = false,
                      generation: UInt64? = nil) {
        PreviewCacheStorage.publish(in: root.deletingLastPathComponent(), generation: generation) {
            synchronizeMemory()
            storeSnapshot(value, for: key, fromPreview: fromPreview)
        }
    }
    private func storeSnapshot(_ value: HistogramSnapshot, for key: HistogramCacheKey, fromPreview: Bool) {
        guard value.isValid else { return }
        lock.lock()
        if fromPreview, memory.object(forKey: key.recipe as NSString) != nil {
            lock.unlock(); return
        }
        memory.setObject(Box(value), forKey: key.recipe as NSString)
        counters.computations += 1
        if fromPreview { counters.previewBackfills += 1 }
        let path = url(for: key)
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            try encoder.encode(Entry(key: key, snapshot: value)).write(to: path, options: .atomic)
            counters.writes += 1
        } catch { /* Optional cache: lack of disk space must not fail a photo render. */ }
        lock.unlock()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .photonsHistogramCached, object: self,
                                            userInfo: ["key": key])
        }
    }
}
