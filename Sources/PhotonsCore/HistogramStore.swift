import Foundation
import CryptoKit

// MARK: - 428 · the histogram's disk cache
//
// Switching photos in the loupe (and in the grid) must not wait for the histogram to be measured
// again. Two independent reasons made it wait:
//
//   ① `LoupeController.cancelPendingFrames` threw the whole in-memory cache away on every photo
//      switch. Only the de-dupe key (`histogramFrameKey`) has to go — every cache entry is keyed by
//      the document + recipe (`Histogram.cacheKey`), so another photo's entry can never be read for
//      this one;
//   ② even after ① the memory cache held 8 entries, and nothing was ever written to or read from the
//      disk. Ten photos in a row evicted the first two.
//
// This file is the disk half: one file per *key*, so a photo's numbers survive the process (and the
// 8-entry memory window).
//
// **Why not a plain `Codable` `Histogram` plist.** Measured on this machine, decoding a
// `PropertyListDecoder` tree whose leaves are 8 × 256 `[Int]` takes **1.73 ms** (p50) / 1.90 ms
// (p95) per histogram — `NSNumber` per bin, then `Int` per bin — which is 17 ms of main-thread work
// for ten photos, i.e. more than a frame. The file I/O is not the cost (`Data(contentsOf:)` is
// 0.015 ms). So the bins are a flat `Int32` block read with one `loadUnaligned` per element
// (**0.0003 ms**), and only the ~200 bytes of metadata are a plist.
//
// **The file, byte for byte:**
//
//     [0 ..< 4)                 UInt32, little endian: `metaLength`
//     [4 ..< 4+metaLength)      binary plist, `Metadata` (below)
//     [4+metaLength ..< EOF)    2048 × Int32 (little endian), eight 256-bin segments in order:
//                               red.bins, red.hdrBins, green.bins, green.hdrBins,
//                               blue.bins, blue.hdrBins, luma.bins, luma.hdrBins
//
// Four channels, not three: 403 stopped *drawing* the luma outline, and `luma.clippedHigh` is still
// where the card's three clipping percentages come from (`UISmokeRunner` asserts on it), so its bins
// travel with the numbers.
//
// **Why the key is hashed instead of used as a path.** The memory key is
// `hist|v1|<rungIdentity>|<editDigest>|<bins>|ceil=…` — it contains `|` and the rung identity is
// itself `contentHash|assetID-wb=…`, so it is neither a legal file name nor stable as one. The file
// name is the SHA-256 of that exact string, sharded by its first two hex digits
// (`<sha[0..2]>/<sha>.bin`), and the string itself is **inside** the metadata: a read whose stored
// key is not the key asked for is a miss. That is the proof that the disk hit and the memory hit are
// the same entry, not two number sets.
//
// **Versioning.** `schemaVersion` 2, in its own directory (`histograms-v2`). The 629 orphaned
// `histograms-v1` files were written by a retired build (`HistogramCacheKey.content + "histogram-v1|…"`
// — a different key spelling, no bins/sample-scale/ceiling in it) and nothing in this tree could
// address them: those are not hits, they are a directory nobody reads. A schema change is a
// directory change, so no second decoder is ever needed here.
//
// **Failure is a miss.** A truncated file, a length that is not `4 + metaLength + 8192`, a different
// schema, a different key — every one of them returns `nil`. A cache must never throw at the UI.
//
// **Eviction.** None, by design: one file per (photo, document, recipe) is ~8.5 KB, so a 629-photo
// library is ~5.3 MB. Retention is a separate task; the `recipe` half of the key already makes a
// stale file unreachable (ceiling, headroom, bins and the rung's sample scale are all in it).
public struct HistogramStore: Sendable {

    /// Bumped when the bytes on disk change shape. No decoder for an older version exists on
    /// purpose: the `schemaVersion` mismatch plus the `histograms-v2` directory is the whole
    /// migration.
    public static let schemaVersion = 2

    /// The directory under the library's cache root (`~/Library/Caches/Photons/<libHash>/`).
    public static let directoryName = "histograms-v2"

    /// Bins per segment. The format is fixed at this; a measurement at another resolution is simply
    /// not persisted (`write` becomes a no-op, `load` a miss).
    public static let binsPerSegment = 256

    /// What the plist half of the file holds: everything about a `Histogram` that is not a bin.
    /// Small on purpose — measured 200–330 bytes, decoded in well under 0.1 ms.
    struct Metadata: Codable, Equatable {
        var schemaVersion: Int
        /// The memory key this file is the answer to. Read back and compared, so a file can never be
        /// served for a different recipe.
        var key: String
        var binCount: Int
        var sampleCount: Int
        var canvas: ImageSize
        var roi: ImageRect
        var sampleSize: ImageSize
        var primaries: OutputPrimaries
        var headroom: Double
        /// Four channels in `Histogram.Channel` order: red, green, blue, luma.
        var clipHigh: [Double]
        var clipCeiling: [Double]
        var clipLow: [Double]
    }

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    // MARK: paths

    /// `<root>/<sha[0..1]>/<sha>.bin` — the shard keeps a directory listing to a few hundred entries,
    /// which is what makes "open the file" cheap on a cold cache.
    public func url(for key: String) -> URL {
        let name = Self.fileName(for: key)
        return root
            .appendingPathComponent(String(name.prefix(2)), isDirectory: true)
            .appendingPathComponent(name + ".bin", isDirectory: false)
    }

    static func fileName(for key: String) -> String {
        Histogram.sha256Hex(Data(key.utf8))
    }

    // MARK: read

    /// The numbers `key` names, or `nil` for every failure (missing, short, wrong version, wrong key).
    ///
    /// Synchronous on purpose: the whole point is that a cache hit is *faster* than a measurement, and
    /// the measurement is 1.4 ms. A healthy read is a few tens of microseconds (the plist half is
    /// ~200 bytes; the bins are 8 KB copied into eight `[Int]`).
    public func load(key: String) -> Histogram? {
        guard let data = try? Data(contentsOf: url(for: key), options: [.mappedIfSafe]) else {
            return nil
        }
        return decode(data, expecting: key)
    }

    /// The bytes `write` would put on disk, or `nil` when the histogram cannot be represented (a bin
    /// count the format does not carry). Public so a test can truncate a real file instead of
    /// hand-building one.
    public func data(for histogram: Histogram, key: String) -> Data? {
        encode(histogram, key: key)
    }

    func encode(_ histogram: Histogram, key: String) -> Data? {
        let segments = Self.segments(of: histogram)
        guard let segments else { return nil }
        let meta = Metadata(schemaVersion: Self.schemaVersion,
                            key: key,
                            binCount: histogram.binCount,
                            sampleCount: histogram.sampleCount,
                            canvas: histogram.canvas,
                            roi: histogram.roi,
                            sampleSize: histogram.sampleSize,
                            primaries: histogram.primaries,
                            headroom: histogram.headroom,
                            clipHigh: histogram.channels.map(\.clippedHigh),
                            clipCeiling: histogram.channels.map(\.clippedCeiling),
                            clipLow: histogram.channels.map(\.clippedLow))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let metaData = try? encoder.encode(meta), !metaData.isEmpty,
              metaData.count <= Int(UInt32.max) else { return nil }
        var bins = [Int32]()
        bins.reserveCapacity(Self.binsPerSegment * segments.count)
        for segment in segments { bins.append(contentsOf: segment) }
        var out = Data(capacity: 4 + metaData.count + bins.count * 4)
        withUnsafeBytes(of: UInt32(metaData.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(metaData)
        for value in bins {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    func decode(_ data: Data, expecting key: String) -> Histogram? {
        // 4 channels × (256 SDR + 256 tail) bins × 4 B.
        let binBytes = Self.binsPerSegment * 4 * 2 * 4
        guard data.count > 4 + binBytes else { return nil }
        let metaLength = data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        guard metaLength > 0,
              data.count == 4 + Int(metaLength) + binBytes else { return nil }
        let metaData = data.subdata(in: 4..<(4 + Int(metaLength)))
        guard let meta = try? PropertyListDecoder().decode(Metadata.self, from: metaData),
              meta.schemaVersion == Self.schemaVersion,
              meta.key == key,
              meta.binCount > 0,
              meta.clipHigh.count == 4, meta.clipCeiling.count == 4, meta.clipLow.count == 4
        else { return nil }

        // One `loadUnaligned` per bin instead of `bindMemory(to: Int32.self)`: the plist's length is
        // not a multiple of 4, so the bin block starts at an arbitrary alignment, and reinterpreting
        // a misaligned pointer is undefined behaviour. 2048 unaligned loads are ~20 µs.
        let base = 4 + Int(metaLength)
        let bins = data.withUnsafeBytes { raw -> [Int32] in
            var values = [Int32](repeating: 0, count: Self.binsPerSegment * 2 * 4)
            for i in 0..<values.count {
                values[i] = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: base + i * 4,
                                                                 as: Int32.self))
            }
            return values
        }

        func channel(_ index: Int) -> HistogramChannel {
            let start = index * Self.binsPerSegment * 2
            let sdr = bins[start..<(start + Self.binsPerSegment)].map(Int.init)
            let tail = bins[(start + Self.binsPerSegment)..<(start + 2 * Self.binsPerSegment)]
                .map(Int.init)
            return HistogramChannel(bins: sdr, hdrBins: tail,
                                    clippedHigh: meta.clipHigh[index],
                                    clippedCeiling: meta.clipCeiling[index],
                                    clippedLow: meta.clipLow[index])
        }
        return Histogram(binCount: meta.binCount, sampleCount: meta.sampleCount,
                         canvas: meta.canvas, roi: meta.roi, sampleSize: meta.sampleSize,
                         primaries: meta.primaries, headroom: meta.headroom,
                         red: channel(0), green: channel(1),
                         blue: channel(2), luma: channel(3))
    }

    // MARK: write

    /// Put `histogram` on disk under `key`. Best effort: no directory, no space, a bin count this
    /// format does not carry — the caller keeps its in-memory numbers and the next read is a miss.
    ///
    /// `.atomic` because a half-written file is the one corruption this cache could produce itself,
    /// and `load` would treat it as a miss but the *next* write would have to overwrite it anyway.
    public func write(_ histogram: Histogram, for key: String) {
        guard let bytes = encode(histogram, key: key) else { return }
        let file = url(for: key)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
        } catch {
            // A cache that cannot write is a slower app, not a broken one.
        }
    }

    /// The eight bins segments in the file's fixed order, or `nil` when the histogram is not
    /// 256 bins in each of its two segments (a caller asked for a different resolution; the format is
    /// deliberately not variable-length).
    static func segments(of histogram: Histogram) -> [[Int32]]? {
        guard histogram.binCount == binsPerSegment else { return nil }
        var out: [[Int32]] = []
        out.reserveCapacity(8)
        for channel in histogram.channels {
            guard channel.bins.count == binsPerSegment,
                  channel.hdrBins.count == binsPerSegment else { return nil }
            out.append(channel.bins.map { Int32(clamping: $0) })
            out.append(channel.hdrBins.map { Int32(clamping: $0) })
        }
        return out
    }
}

extension Histogram {
    /// Lowercase hex SHA-256 — the spelling the content-addressed caches in this app already use.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
