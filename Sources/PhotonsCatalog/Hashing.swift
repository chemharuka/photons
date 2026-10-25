import Foundation
import CryptoKit

/// Identity and pre-screen hashing.
///
/// `contentHash` is the identity: full-file SHA-256, because digiKam's head+tail MD5 collides in
/// practice and its older "EXIF block MD5" was outright wrong (changing a rating changed identity).
/// `quickHash` never decides identity — it only lets a re-scan skip reading a file whose size,
/// mtime and both ends are unchanged.
public enum FileHasher {
    public static func sha256(of url: URL, chunkSize: Int = 4 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: chunkSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 over (size, mtime, first 1 MB, last 1 MB). Cheap pre-screen only.
    public static func quickHash(of url: URL, size: Int, mtime: Double) throws -> String {
        let window = 1 << 20
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        hasher.update(data: Data("q1|\(size)|\(mtime)|".utf8))
        let head = handle.readData(ofLength: min(window, size))
        hasher.update(data: head)
        if size > window {
            let tailStart = UInt64(max(0, size - window))
            try handle.seek(toOffset: tailStart)
            hasher.update(data: handle.readData(ofLength: window))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// 16-bit-ish stable hash for the fixtures generator (not used by the catalog).
public enum StableSeed {
    public static func value(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x1000_0000_01b3
        }
        return h
    }
}
