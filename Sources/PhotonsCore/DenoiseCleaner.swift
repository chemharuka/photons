import Foundation
import CryptoKit

// 485 — the real-time denoiser's cache and service layer.
//
// LightCraft's contract is not "produce another RAW": the edit-time denoiser cleans the *source*
// pixels once, keeps the result beside the library, and every Amount value is a mix of the plain
// and the cleaned buffer. This file owns exactly that half:
//
//   * identity — `sourceContentSHA256 | cleanerID | cleanerVersion | pixel size`;
//   * the on-disk `<digest>.lcdn` cache (magic / version / algo / params / dims + Float16 RGBA);
//   * the service semantics — one compute at a time, a second request for the same key joins the
//     first, a cache hit costs one read, and a failed compute writes nothing.
//
// The pixels themselves are supplied by a `compute` closure. `DenoiseCleaner` lives in
// `PhotonsCore`, which deliberately does not depend on `PhotonsExtensions` (the DNG reader and the
// built-in NLM port live there); `CatalogSession` injects the closure, so this type can be tested
// with a stand-in and still be the only implementation of the cache discipline.

/// What a clean result is addressed by.
///
/// Edits are **not** part of the key: denoise acts on the source pixels, so changing exposure, crop
/// or a mask must keep hitting the same buffer. Only a different file, cleaner or cleaner version
/// (or a file whose pixel size changed on re-import) moves the key.
public struct DenoiseCacheKey: Sendable, Hashable {
    public let sourceSHA256: String
    public let cleanerID: String
    public let cleanerVersion: String
    public let width: Int
    public let height: Int

    public init(sourceSHA256: String, cleanerID: String, cleanerVersion: String,
                width: Int, height: Int) {
        self.sourceSHA256 = sourceSHA256
        self.cleanerID = cleanerID
        self.cleanerVersion = cleanerVersion
        self.width = width
        self.height = height
    }

    /// The exact text the digest is taken over, exposed so a test can read the contract.
    public var keyText: String {
        "\(sourceSHA256)|\(cleanerID)|\(cleanerVersion)|\(width)x\(height)"
    }

    public var digest: String {
        SHA256.hash(data: Data(keyText.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The source a clean result belongs to. `contentSHA256` is the catalogue's full-file hash, so a
/// cache hit needs no re-read of a 60 MB original.
public struct DenoiseSource: Sendable, Equatable {
    public let assetID: String
    public let url: URL
    public let contentSHA256: String
    public let width: Int
    public let height: Int

    public init(assetID: String, url: URL, contentSHA256: String, width: Int, height: Int) {
        self.assetID = assetID
        self.url = url
        self.contentSHA256 = contentSHA256
        self.width = width
        self.height = height
    }
}

/// 485 — read-only counters for `--ui-smoke` and the tests.
public struct DenoiseCleanerStats: Equatable, Sendable {
    /// A request answered by the on-disk buffer.
    public var cacheHits = 0
    /// A clean that actually ran (a merged request does not add one).
    public var computes = 0
    public var computesFailed = 0
    public var bytesWritten = 0

    public init() {}
}

public enum DenoiseCleanerFailure: Error, CustomStringConvertible, Sendable {
    case sourceUnavailable(String)
    case computeFailed(String)
    case cacheFailed(String)

    public var description: String {
        switch self {
        case .sourceUnavailable(let message): return message
        case .computeFailed(let message): return message
        case .cacheFailed(let message): return message
        }
    }
}

// MARK: - on-disk cache

/// `<digest>.lcdn`, one file per (source, cleaner, version, size).
///
/// Layout, little-endian:
///
///     UInt32 magic              0x50484443 ("PHDC")
///     UInt16 formatVersion      1
///     UInt16 algoLen + bytes    cleaner ID
///     UInt16 paramsLen + bytes  human-readable tuning (amount=100;tile=256;…)
///     UInt32 width
///     UInt32 height
///     UInt16 colorLen + bytes   linear colour space
///     UInt8  orientation        `ImageOrientation.rawValue`
///     UInt64 payloadBytes       width·height·4·2
///     Float16 RGBA, row-major
///
/// The header is validated before a single pixel is trusted: a wrong magic, version, cleaner ID,
/// dimension or payload length is a corrupt file, not a picture. Callers treat that as a miss and
/// delete it, so the next request rebuilds.
public struct DenoiseCacheStore: Sendable {
    public static let magic: UInt32 = 0x5048_4443
    public static let formatVersion: UInt16 = 1

    public let directory: URL
    private let fm = FileManager.default

    public init(directory: URL) throws {
        self.directory = directory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func fileURL(for key: DenoiseCacheKey) -> URL {
        directory.appendingPathComponent("\(key.digest).lcdn")
    }

    public func load(_ key: DenoiseCacheKey) throws -> LinearImage? {
        let url = fileURL(for: key)
        guard fm.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        var reader = Reader(data: data)
        guard try reader.u32() == Self.magic else { throw DenoiseCleanerFailure.cacheFailed("bad magic") }
        guard try reader.u16() == Self.formatVersion else {
            throw DenoiseCleanerFailure.cacheFailed("unsupported cache version")
        }
        let algo = try reader.string()
        guard algo == key.cleanerID else {
            throw DenoiseCleanerFailure.cacheFailed("cache belongs to \(algo)")
        }
        _ = try reader.string() // params: recorded for diagnostics, not part of the key
        let width = Int(try reader.u32())
        let height = Int(try reader.u32())
        guard width > 0, height > 0 else { throw DenoiseCleanerFailure.cacheFailed("empty dims") }
        let colorSpace = try reader.string()
        let orientation = ImageOrientation(rawValue: Int(try reader.u8())) ?? .up
        let payloadBytes = Int(try reader.u64())
        let expected = width * height * 4 * MemoryLayout<Float16>.size
        guard payloadBytes == expected, data.count - reader.offset == expected else {
            throw DenoiseCleanerFailure.cacheFailed("payload length mismatch")
        }
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        data.withUnsafeBytes { raw in
            for i in 0..<rgba.count {
                let bits = raw.loadUnaligned(fromByteOffset: reader.offset + i * 2, as: UInt16.self)
                rgba[i] = Float16(bitPattern: UInt16(littleEndian: bits))
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: colorSpace.isEmpty ? "extendedLinearSRGB" : colorSpace,
                           decoderVersion: key.cleanerVersion, orientation: orientation)
    }

    /// Write-then-rename, so a crash leaves either the old file or the new one, never half of one.
    /// Returns the number of bytes written.
    @discardableResult
    public func save(_ image: LinearImage, key: DenoiseCacheKey, params: String) throws -> Int {
        guard image.width > 0, image.height > 0,
              image.rgba.count == image.width * image.height * 4 else {
            throw DenoiseCleanerFailure.cacheFailed("refusing to cache an empty buffer")
        }
        var header: [UInt8] = []
        Self.append(Self.magic, to: &header)
        Self.append(Self.formatVersion, to: &header)
        Self.appendString(key.cleanerID, to: &header)
        Self.appendString(params, to: &header)
        Self.append(UInt32(image.width), to: &header)
        Self.append(UInt32(image.height), to: &header)
        Self.appendString(image.colorSpace, to: &header)
        header.append(UInt8(clamping: image.orientation.rawValue))
        Self.append(UInt64(image.byteCount), to: &header)

        var payload = [UInt16](repeating: 0, count: image.rgba.count)
        for i in 0..<image.rgba.count { payload[i] = image.rgba[i].bitPattern.littleEndian }
        var out = Data(header)
        payload.withUnsafeBytes { out.append(contentsOf: $0) }

        let destination = fileURL(for: key)
        let tmp = directory.appendingPathComponent(".\(key.digest).\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: tmp) }
        try out.write(to: tmp, options: .atomic)
        _ = try? fm.removeItem(at: destination)
        try fm.moveItem(at: tmp, to: destination)
        return out.count
    }

    public func remove(_ key: DenoiseCacheKey) {
        try? fm.removeItem(at: fileURL(for: key))
    }

    public func totalBytes() -> Int64 {
        guard let items = try? fm.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return items.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: binary helpers

    private struct Reader {
        let data: Data
        var offset = 0

        mutating func u8() throws -> UInt8 {
            guard offset + 1 <= data.count else { throw DenoiseCleanerFailure.cacheFailed("truncated header") }
            defer { offset += 1 }
            return data[offset]
        }
        mutating func u16() throws -> UInt16 {
            guard offset + 2 <= data.count else { throw DenoiseCleanerFailure.cacheFailed("truncated header") }
            let v = UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
            offset += 2
            return v
        }
        mutating func u32() throws -> UInt32 {
            guard offset + 4 <= data.count else { throw DenoiseCleanerFailure.cacheFailed("truncated header") }
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(data[offset + i]) << (8 * UInt32(i)) }
            offset += 4
            return v
        }
        mutating func u64() throws -> UInt64 {
            guard offset + 8 <= data.count else { throw DenoiseCleanerFailure.cacheFailed("truncated header") }
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(data[offset + i]) << (8 * UInt64(i)) }
            offset += 8
            return v
        }
        mutating func string() throws -> String {
            let n = Int(try u16())
            guard offset + n <= data.count else { throw DenoiseCleanerFailure.cacheFailed("truncated header") }
            defer { offset += n }
            return String(decoding: data[offset..<(offset + n)], as: UTF8.self)
        }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }

    private static func appendString(_ value: String, to bytes: inout [UInt8]) {
        let utf8 = Array(value.utf8)
        append(UInt16(clamping: utf8.count), to: &bytes)
        bytes.append(contentsOf: utf8)
    }
}

// MARK: - service

/// The one owner of "clean this photo's source pixels, once".
///
/// `compute` is the only thing that knows where pixels come from (DNG mosaic + built-in NLM, or a
/// decoded linear buffer); this actor owns identity, caching and concurrency so both engines can
/// share one cache (P3 feeds the model engines through the same door).
public actor DenoiseCleaner {
    public typealias SourceResolver = @Sendable (String) async throws -> DenoiseSource
    public typealias Compute = @Sendable (DenoiseSource,
                                          @escaping @Sendable (String) -> Void) async throws -> LinearImage

    public nonisolated let cleanerID: String
    public nonisolated let cleanerVersion: String
    /// Recorded in the file header for diagnostics; it is deliberately **not** part of the key.
    public nonisolated let params: String

    private let store: DenoiseCacheStore
    private let resolver: SourceResolver
    private let compute: Compute
    private var stats = DenoiseCleanerStats()
    private var inflight: [String: Task<Outcome, Never>] = [:]
    private var lastCompute: Task<Void, Never>?

    private struct Outcome: Sendable {
        let result: Result<LinearImage, DenoiseCleanerFailure>
        let bytesWritten: Int
    }

    public init(directory: URL,
                cleanerID: String,
                cleanerVersion: String,
                params: String = "",
                resolver: @escaping SourceResolver,
                compute: @escaping Compute) throws {
        self.store = try DenoiseCacheStore(directory: directory)
        self.cleanerID = cleanerID
        self.cleanerVersion = cleanerVersion
        self.params = params
        self.resolver = resolver
        self.compute = compute
    }

    public nonisolated func key(for source: DenoiseSource) -> DenoiseCacheKey {
        DenoiseCacheKey(sourceSHA256: source.contentSHA256, cleanerID: cleanerID,
                        cleanerVersion: cleanerVersion, width: source.width, height: source.height)
    }

    public func statsSnapshot() -> DenoiseCleanerStats { stats }

    /// `cleanIfNeeded(assetID)` — resolve the asset through the injected resolver, then the normal
    /// path. The result is either the cached buffer or the freshly computed one.
    public func cleanIfNeeded(assetID: String,
                              progress: (@Sendable (String) -> Void)? = nil)
        async -> Result<LinearImage, DenoiseCleanerFailure> {
        let source: DenoiseSource
        do {
            source = try await resolver(assetID)
        } catch let failure as DenoiseCleanerFailure {
            return .failure(failure)
        } catch {
            return .failure(.sourceUnavailable(error.localizedDescription))
        }
        return await cleanIfNeeded(source: source, progress: progress)
    }

    /// The same service for a caller that already resolved the source.
    public func cleanIfNeeded(source: DenoiseSource,
                              progress: (@Sendable (String) -> Void)? = nil)
        async -> Result<LinearImage, DenoiseCleanerFailure> {
        let key = key(for: source)

        // 1. The buffer on disk is the answer; one read, no recompute.
        do {
            if let cached = try store.load(key) {
                stats.cacheHits += 1
                return .success(cached)
            }
        } catch {
            // A header we cannot trust is not a picture: drop it and rebuild below.
            store.remove(key)
        }

        // 2. A request that arrived while this key is computing joins that one, not a second run.
        if let running = inflight[key.digest] {
            return await running.value.result
        }

        stats.computes += 1
        let previous = lastCompute
        let store = self.store
        let compute = self.compute
        let params = self.params
        let task = Task.detached(priority: .utility) { () -> Outcome in
            // Concurrency limit 1: the previous clean finishes before this one starts.
            await previous?.value
            do {
                let image = try await compute(source, progress ?? { _ in })
                guard image.width > 0, image.height > 0,
                      image.rgba.count == image.width * image.height * 4 else {
                    return Outcome(result: .failure(.computeFailed("降噪结果为空")),
                                   bytesWritten: 0)
                }
                let bytes = try store.save(image, key: key, params: params)
                return Outcome(result: .success(image), bytesWritten: bytes)
            } catch let failure as DenoiseCleanerFailure {
                return Outcome(result: .failure(failure), bytesWritten: 0)
            } catch {
                return Outcome(result: .failure(.computeFailed(error.localizedDescription)),
                               bytesWritten: 0)
            }
        }
        inflight[key.digest] = task
        lastCompute = Task { _ = await task.value }

        let outcome = await task.value
        inflight[key.digest] = nil
        if case .failure = outcome.result { stats.computesFailed += 1 }
        stats.bytesWritten += outcome.bytesWritten
        return outcome.result
    }
}

// MARK: - plane adapters

/// 485 — the two shapes a cleaned result can arrive in, both turned into the pipeline's linear RGBA.
///
/// The DNG path gives four CFA planes (R/G1/G2/B). A 2×2 cell is exactly one R, two G and one B
/// sample, so its linear RGB is the cell's own average — no interpolation, no invented detail. The
/// buffer is therefore at CFA-cell resolution (`width/2 × height/2`); the source size stays in the
/// cache key, so the two can never be confused.
///
/// The RGB path gives LightCraft's four pseudo-planes (`Y/C1/C2/C3`, Hadamard-rotated and rescaled by
/// `BuiltinDenoise.fourPlanesFromRGB`). This is the inverse of that adapter: undo the noise gains,
/// undo the Hadamard, and recover `G = Y + C3`, `R = G + C1`, `B = G + C2`. The round-trip is pinned
/// by a test so the two constants cannot drift.
public enum DenoiseLinearAdapter {
    public static let colorSpace = "extendedLinearSRGB"
    public static let decoderVersion = "denoise"

    public static func linearImage(cfaPlanes planes: [[Float]],
                                   width: Int, height: Int, cfa: String) -> LinearImage {
        precondition(planes.count == 4, "four CFA planes required")
        let channel = cfa.map { letter -> Int in
            switch letter {
            case "r": return 0
            case "g": return 1
            default: return 2
            }
        }
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            var sums = (r: Float(0), g: Float(0), b: Float(0))
            var counts = (r: 0, g: 0, b: 0)
            for p in 0..<4 {
                let value = planes[p][i]
                switch channel[p] {
                case 0: sums.r += value; counts.r += 1
                case 1: sums.g += value; counts.g += 1
                default: sums.b += value; counts.b += 1
                }
            }
            let base = i * 4
            rgba[base] = Float16(counts.r > 0 ? sums.r / Float(counts.r) : 0)
            rgba[base + 1] = Float16(counts.g > 0 ? sums.g / Float(counts.g) : 0)
            rgba[base + 2] = Float16(counts.b > 0 ? sums.b / Float(counts.b) : 0)
            rgba[base + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: colorSpace, decoderVersion: decoderVersion)
    }

    /// Inverse of `BuiltinDenoise.fourPlanesFromRGB` (gains `0.75 / 0.625 / 0.625 / 2.75`).
    public static func linearImage(fourPlanes planes: [[Float]],
                                   width: Int, height: Int) -> LinearImage {
        precondition(planes.count == 4, "four planes required")
        let n = width * height
        let gains: [Float] = [0.75, 0.625, 0.625, 2.75]
        var scaled = planes
        for c in 0..<4 where scaled[c].count == n {
            let scale = gains[c].squareRoot()
            for i in 0..<n { scaled[c][i] *= scale }
        }
        let raw = hadamard(scaled)
        var rgba = [Float16](repeating: 0, count: n * 4)
        for i in 0..<n {
            let y = raw[0][i], c1 = raw[1][i], c2 = raw[2][i], c3 = raw[3][i]
            let g = y + c3
            let base = i * 4
            rgba[base] = Float16(g + c1)
            rgba[base + 1] = Float16(g)
            rgba[base + 2] = Float16(g + c2)
            rgba[base + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: colorSpace, decoderVersion: decoderVersion)
    }

    /// The same orthonormal 4×4 Hadamard as `BuiltinDenoise.hadamard` (it is its own inverse).
    static func hadamard(_ planes: [[Float]]) -> [[Float]] {
        let n = planes.first?.count ?? 0
        guard n > 0, planes.count >= 4 else {
            return [[Float]](repeating: [Float](repeating: 0, count: n), count: 4)
        }
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: 4)
        for c in 0..<4 {
            let p = planes[c]
            for i in 0..<n { out[c][i] = p[i] }
        }
        for i in 0..<n {
            let r = out[0][i], g1 = out[1][i], g2 = out[2][i], b = out[3][i]
            out[0][i] = (r + g1 + g2 + b) / 2
            out[1][i] = (r - g1 + g2 - b) / 2
            out[2][i] = (r + g1 - g2 - b) / 2
            out[3][i] = (r - g1 - g2 + b) / 2
        }
        return out
    }
}
