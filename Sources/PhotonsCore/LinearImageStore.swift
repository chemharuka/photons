import Foundation
import CryptoKit

/// Version of the fixed decode recipe.
///
/// Bumped whenever the *decode settings* change, because an already-written linear buffer must not
/// be reused by a build that decodes differently. `v1` = the D2′ recipe of M3:
/// `boostAmount = 0` + `isGamutMappingEnabled = false` (docs/architecture-decisions.md §11.4).
/// `v2` = top-down rows: `CIContext.render(to: MTLTexture)` + `getBytes` reads back **bottom-up**,
/// so every buffer written by v1 was vertically mirrored (the bug behind the "`L1030433.dng` renders
/// 180°" report — it was never an orientation tag; every file was affected). v2 flips rows at
/// ingest, so v1 buffers on disk must never be reused.
public enum DecodeRecipe {
    public static let current = "v2-topdown-rows"
}

/// Identity of a decode result: everything that can change the pixels.
///
/// Mirrors the cache discipline taken from darktable (four hashes) and LightCraft
/// (geo / lin_key / pre_nr_key), reduced to the one key M0 needs.
public struct DecodeCacheKey: Sendable, Hashable {
    public let fileSHA256: String
    public let decoderVersion: String
    public let exposureEV: Float
    public let scale: Float
    public let draft: Bool
    public let colorSpace: String
    public let decodeRecipe: String

    public init(fileSHA256: String, decoderVersion: String, exposureEV: Float = 0,
                scale: Float = 1, draft: Bool = false, colorSpace: String = "extendedLinearSRGB",
                decodeRecipe: String = DecodeRecipe.current) {
        self.fileSHA256 = fileSHA256
        self.decoderVersion = decoderVersion
        self.exposureEV = exposureEV
        self.scale = scale
        self.draft = draft
        self.colorSpace = colorSpace
        self.decodeRecipe = decodeRecipe
    }

    public var digest: String {
        let s = [fileSHA256, decoderVersion, String(format: "%.4f", exposureEV),
                 String(format: "%.4f", scale), draft ? "draft" : "full", colorSpace,
                 decodeRecipe].joined(separator: "|")
        return SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// On-disk store for decoded linear buffers, so 60 MP RAWs are developed once
/// (0.5 s at v8, up to 5 s at v9) instead of on every launch.
public final class LinearImageStore {
    public struct Header: Codable, Sendable {
        public let width: Int
        public let height: Int
        public let colorSpace: String
        public let decoderVersion: String
        public let exposureEV: Float
        public let scale: Float
        public let draft: Bool
        public let sha256: String
        public let bytes: Int
    }

    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) throws {
        self.directory = directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func binURL(for key: DecodeCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digest).bin")
    }
    public func headerURL(for key: DecodeCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digest).json")
    }

    public func load(_ key: DecodeCacheKey) throws -> LinearImage? {
        let bin = binURL(for: key), hdr = headerURL(for: key)
        guard fm.fileExists(atPath: bin.path), fm.fileExists(atPath: hdr.path) else { return nil }
        let header = try JSONDecoder().decode(Header.self, from: Data(contentsOf: hdr))
        let data = try Data(contentsOf: bin)
        guard data.count == header.width * header.height * 4 * 2 else { return nil }
        var rgba = [Float16](repeating: 0, count: header.width * header.height * 4)
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt16.self)
            for i in 0..<rgba.count { rgba[i] = Float16(bitPattern: src[i]) }
        }
        return LinearImage(width: header.width, height: header.height, rgba: rgba,
                           colorSpace: header.colorSpace, decoderVersion: header.decoderVersion)
    }

    public func save(_ image: LinearImage, key: DecodeCacheKey) throws {
        var data = Data(count: image.byteCount)
        data.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: UInt16.self)
            for i in 0..<image.rgba.count { dst[i] = image.rgba[i].bitPattern }
        }
        let header = Header(width: image.width, height: image.height,
                            colorSpace: image.colorSpace, decoderVersion: image.decoderVersion,
                            exposureEV: key.exposureEV, scale: key.scale, draft: key.draft,
                            sha256: image.sha256(), bytes: image.byteCount)
        // write-then-rename so a crash never leaves a half buffer behind
        let tmp = binURL(for: key).appendingPathExtension("tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try? fm.removeItem(at: binURL(for: key))
        try fm.moveItem(at: tmp, to: binURL(for: key))
        try JSONEncoder().encode(header).write(to: headerURL(for: key), options: .atomic)
    }

    public func totalBytes() -> Int64 {
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return items.reduce(0) { acc, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return acc + Int64(size)
        }
    }

    /// Simple LRU-by-mtime eviction; the real policy lands with the library in M2.
    public func evict(keepingBytes limit: Int64) {
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        else { return }
        let sorted = items.compactMap { url -> (URL, Int64, Date)? in
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = sorted.reduce(Int64(0)) { $0 + $1.1 }
        for (url, size, _) in sorted where total > limit {
            try? fm.removeItem(at: url)
            total -= size
        }
    }
}

public enum FileDigest {
    /// Full-file SHA-256. digiKam hashes only head+tail 100 KB, which collides in practice.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 4 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
