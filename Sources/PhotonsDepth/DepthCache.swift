// PhotonsDepth — on-disk depth cache.
//
// One depth map is ~0.4 MB at the model's own 518×392, and a thumbnail's depth is what the depth
// mask / dehaze assist ask for again and again. The cache is deliberately narrow:
//
//   · key   = the *decode* key's digest + `DepthModel.revision`, so a different decode recipe or a
//             different weight revision can never hit an old map;
//   · files = `<digest>.bin` (Float16, row-major) + `<digest>.json` (the header), the same pair
//             `LinearImageStore` writes, and the same write-then-rename discipline;
//   · limit = only maps whose long edge is ≤ 4096 are stored. A full-size depth is computed on
//             demand and never persisted; that keeps a 60 MP picture from silently writing a
//             32 MB map per edit. Eviction is the same mtime LRU as `LinearImageStore`.
import CryptoKit
import Foundation
import PhotonsCore

/// Identity of a cached depth map: the decode result it was computed from, plus the weight revision.
public struct DepthCacheKey: Sendable, Hashable {
    public let decodeDigest: String
    public let modelRevision: String

    public init(decodeDigest: String, modelRevision: String = DepthModel.revision) {
        self.decodeDigest = decodeDigest
        self.modelRevision = modelRevision
    }

    public init(decodeKey: DecodeCacheKey, modelRevision: String = DepthModel.revision) {
        self.init(decodeDigest: decodeKey.digest, modelRevision: modelRevision)
    }

    /// The exact text the file digest is taken over. Exposed so the "both components are in the key"
    /// claim has a string a test can read.
    public var keyText: String { "\(decodeDigest)|\(modelRevision)" }

    public var digest: String {
        SHA256.hash(data: Data(keyText.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public final class DepthCache {
    /// Long edge above which a map is treated as full-size and not written. Thumbnails (the 4096
    /// cap is the same one the mask pipeline uses) are the only thing worth a disk round-trip.
    public static let thumbnailCeiling = 4096

    public struct Header: Codable, Sendable {
        public let width: Int
        public let height: Int
        public let decodeDigest: String
        public let modelRevision: String
        public let bytes: Int
    }

    public let directory: URL
    private let fm = FileManager.default

    /// `~/Library/Caches/Photons/<libraryHash>/depth` — the layout the app and `photonsctl` share.
    public static func defaultDirectory(libraryHash: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return base.appendingPathComponent("Photons")
            .appendingPathComponent(libraryHash)
            .appendingPathComponent("depth")
    }

    public init(directory: URL) throws {
        self.directory = directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func binURL(for key: DepthCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digest).bin")
    }

    public func headerURL(for key: DepthCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digest).json")
    }

    /// True when both halves of the pair exist. Cheap enough for a lookup before computing.
    public func contains(_ key: DepthCacheKey) -> Bool {
        fm.fileExists(atPath: binURL(for: key).path) && fm.fileExists(atPath: headerURL(for: key).path)
    }

    public func load(_ key: DepthCacheKey) throws -> DepthMap? {
        let bin = binURL(for: key), header = headerURL(for: key)
        guard fm.fileExists(atPath: bin.path), fm.fileExists(atPath: header.path) else { return nil }
        let record = try JSONDecoder().decode(Header.self, from: Data(contentsOf: header))
        // A header naming another revision is a stale file: treat it as a miss rather than serving it.
        guard record.modelRevision == key.modelRevision, record.decodeDigest == key.decodeDigest else {
            return nil
        }
        guard record.width > 0, record.height > 0,
              record.width * record.height <= Int.max / 2 else { return nil }
        let data = try Data(contentsOf: bin)
        guard data.count == record.width * record.height * MemoryLayout<Float16>.size else { return nil }
        var values = [Float16](repeating: 0, count: record.width * record.height)
        data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt16.self)
            for i in 0..<values.count { values[i] = Float16(bitPattern: source[i]) }
        }
        return DepthMap(width: record.width, height: record.height, values: values)
    }

    /// Writes the map unless its long edge is above `thumbnailCeiling`; returns whether it was
    /// written. A full-size map is a legitimate result — it just must not enter the cache.
    @discardableResult
    public func save(_ map: DepthMap, key: DepthCacheKey) throws -> Bool {
        guard max(map.width, map.height) <= Self.thumbnailCeiling else { return false }
        guard map.values.count == map.width * map.height else {
            throw DepthError.featureMismatch(
                "depth map \(map.width)×\(map.height) has \(map.values.count) samples")
        }
        var data = Data(count: map.values.count * MemoryLayout<Float16>.size)
        data.withUnsafeMutableBytes { raw in
            let destination = raw.bindMemory(to: UInt16.self)
            for i in 0..<map.values.count { destination[i] = map.values[i].bitPattern }
        }
        let record = Header(width: map.width, height: map.height,
                            decodeDigest: key.decodeDigest, modelRevision: key.modelRevision,
                            bytes: data.count)
        // write-then-rename so a crash never leaves a half map behind
        let tmp = binURL(for: key).appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? fm.removeItem(at: binURL(for: key))
        try fm.moveItem(at: tmp, to: binURL(for: key))
        try JSONEncoder().encode(record).write(to: headerURL(for: key), options: .atomic)
        return true
    }

    public func totalBytes() -> Int64 {
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return items.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Same mtime LRU as `LinearImageStore.evict(keepingBytes:)`.
    public func evict(keepingBytes limit: Int64) {
        guard let items = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        let sorted = items.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = sorted.reduce(Int64(0)) { $0 + $1.1 }
        for (url, size, _) in sorted where total > limit {
            try? fm.removeItem(at: url)
            total -= size
        }
    }
}
