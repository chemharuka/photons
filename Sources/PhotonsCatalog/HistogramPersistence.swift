import Foundation
import GRDB
import PhotonsCore

// MARK: - 534 · the histogram's catalog half
//
// A histogram is a measurement of **the picture** (see `Histogram`), and until 534 the only durable
// copy was `HistogramStore`'s file cache under `~/Library/Caches/Photons/<library>/histograms-v2`.
// That cache is keyed by `Histogram.cacheKey`, which contains the **rung identity** (a content hash
// plus the decode recipe) — enough for a warm process, but not a row a library can own, inspect or
// migrate. The user's report is 「V9 解码器的直方图首次加载特别慢」: the first measurement after a
// launch pays the v9 raw-domain denoiser every time even when the document has not moved.
//
// This table is the durable answer: one row per `(asset, pixel digest, measurement scale, ceiling)`.
//
//   · **asset_id** is the catalog asset. There is deliberately no foreign key: the histogram is a
//     cache of a rendering fact, not a relationship, and a test (or a future import preview) can name
//     a picture the catalog has no row for. Deleting an asset leaves an unreachable row; a later
//     `DELETE` sweep is a separate concern, and a stale row can never be read without an asset id.
//   · **pixel_digest** is `CanvasFrameCache.pixelCanonicalEdit`'s digest — the one 491 definition of
//     "which document fields reach a pixel". The histogram does not invent a second digest: a digest
//     change is a **miss**, never an approximate hit.
//   · **scale** is the rung the bins were measured from (0.5 or 1.0 today). It is part of the key
//     because 「先发近似」 means two rows may describe the same picture at two qualities.
//   · **ceiling** is the render ceiling in linear light (`HighlightCeiling.current`). The bins are
//     measured after S2's clamp, so a ceiling change is a different distribution even though the
//     pixel digest did not move (320). It is part of the measurement recipe, not of the pixel digest.
//
// **Schema.** v9 adds the table; an older library migrates to an **empty** table and therefore falls
// back to measuring (no data migration, which is exactly what the dispatch asks for). The stored
// blob carries its own `storageVersion`, so a future format change can reject old rows as misses.
//
// **Encoding.** A small binary plist of the non-bin fields plus the eight bin segments as a flat
// little-endian `Int32` block, the same shape `HistogramStore` writes. The reason is the same one
// written down there: plist leaves are `NSNumber`s and decoding 2048 of them is milliseconds, while
// one block of `Int32` is tens of microseconds. A read happens on a photo switch, on the main
// thread, before the first frame — the budget is smaller than a frame.

/// One catalog row's identity: what was measured, of which picture, at which quality.
public struct HistogramRecordKey: Sendable, Hashable {
    public var assetID: String
    public var pixelDigest: String
    public var scale: Float
    public var ceiling: Double

    public init(assetID: String, pixelDigest: String, scale: Float, ceiling: Double) {
        self.assetID = assetID
        self.pixelDigest = pixelDigest
        self.scale = scale
        self.ceiling = ceiling
    }
}

/// The catalog's histogram table as a value: it owns the open `Catalog` handle, nothing else.
///
/// `@unchecked Sendable` because `Catalog` is a database handle (GRDB's pools are thread-safe) and
/// this value only forwards reads/writes to it. A save is enqueued by the controller on its own disk
/// queue; a load happens on main before a decode starts.
public struct CatalogHistogramStore: @unchecked Sendable {

    /// Bumped when the blob's bytes change shape. A row with another version is a miss (the table is
    /// versioned, the `settings` / `PRAGMA user_version` story is `Schema`'s).
    public static let storageVersion = 1

    public let catalog: Catalog

    public init(catalog: Catalog) {
        self.catalog = catalog
    }

    // MARK: read

    /// The numbers exactly this `(asset, digest, scale, ceiling)` names, or `nil`.
    ///
    /// Every failure is a miss: no row, another blob version, a corrupt plist, a non-256-bin
    /// measurement. A cache must never throw at the UI.
    public func load(_ key: HistogramRecordKey) -> Histogram? {
        let row = try? catalog.dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT storage_version, bins FROM asset_histograms
                 WHERE asset_id = ? AND pixel_digest = ? AND scale = ? AND ceiling = ?
                """, arguments: [key.assetID, key.pixelDigest, Double(key.scale), key.ceiling])
        }
        guard let row else { return nil }
        let version: Int = row["storage_version"]
        let data: Data = row["bins"]
        guard version == Self.storageVersion else { return nil }
        return Self.decode(data)
    }

    /// The best row for a picture when the caller has a preferred scale (1.0 on a photo open).
    ///
    /// Exact scale wins; otherwise the largest measured scale is the closest to the picture the card
    /// wants. That is what lets a preview-only row still publish immediately after a relaunch, with
    /// the full frame refreshing it later.
    public func loadNearest(assetID: String, pixelDigest: String, ceiling: Double,
                            preferredScale: Float) -> (key: HistogramRecordKey, histogram: Histogram)? {
        let rows = (try? catalog.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT scale, storage_version, bins FROM asset_histograms
                 WHERE asset_id = ? AND pixel_digest = ? AND ceiling = ?
                 ORDER BY (ABS(scale - ?) < 0.000001) DESC, scale DESC
                """, arguments: [assetID, pixelDigest, ceiling, Double(preferredScale)])
        }) ?? []
        for row in rows {
            let version: Int = row["storage_version"]
            guard version == Self.storageVersion else { continue }
            let scale = Float(row["scale"] as Double)
            let data: Data = row["bins"]
            guard let histogram = Self.decode(data) else { continue }
            return (HistogramRecordKey(assetID: assetID, pixelDigest: pixelDigest,
                                       scale: scale, ceiling: ceiling), histogram)
        }
        return nil
    }

    /// Is there **any** row for this asset? Used only to name a miss: a digest with no rows at all is
    /// `noEntry`, while another digest for the same photo is `documentChanged`.
    public func hasAnyEntry(assetID: String) -> Bool {
        let count = (try? catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_histograms WHERE asset_id = ?",
                             arguments: [assetID])
        }) ?? 0
        return (count ?? 0) > 0
    }

    // MARK: write

    /// Store one measurement. Best effort: a closed library, a disk error or a histogram this format
    /// cannot carry leaves the in-memory numbers intact and the next read a miss.
    public func save(_ histogram: Histogram, key: HistogramRecordKey) {
        guard let data = Self.encode(histogram) else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        try? catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO asset_histograms
                    (asset_id, pixel_digest, scale, ceiling, storage_version, bins, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(asset_id, pixel_digest, scale, ceiling) DO UPDATE SET
                    storage_version = excluded.storage_version,
                    bins = excluded.bins,
                    updated_at = excluded.updated_at
                """, arguments: [key.assetID, key.pixelDigest, Double(key.scale), key.ceiling,
                                 Self.storageVersion, data, now])
        }
    }

    // MARK: the blob

    /// The non-bin half. A `Codable` tree of ~200 bytes; the bins are the flat block after it.
    private struct Metadata: Codable {
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

    static func encode(_ histogram: Histogram) -> Data? {
        // The format is fixed at eight 256-bin segments, like `HistogramStore`: a different bin
        // resolution is simply not persisted rather than a second variable-length decoder.
        guard histogram.binCount == 256,
              histogram.channels.allSatisfy({
                  $0.bins.count == 256 && $0.hdrBins.count == Histogram.hdrBinCount
              }) else { return nil }
        let meta = Metadata(binCount: histogram.binCount,
                            sampleCount: histogram.sampleCount,
                            canvas: histogram.canvas,
                            roi: histogram.roi,
                            sampleSize: histogram.sampleSize,
                            primaries: histogram.primaries,
                            headroom: histogram.headroom,
                            clipHigh: histogram.channels.map(\.clippedHDR),
                            clipCeiling: histogram.channels.map(\.clippedScreen),
                            clipLow: histogram.channels.map(\.clippedBlack))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let metaData = try? encoder.encode(meta), !metaData.isEmpty,
              metaData.count <= Int(UInt32.max) else { return nil }

        var bins = [Int32]()
        bins.reserveCapacity(8 * 256)
        for channel in histogram.channels {
            bins.append(contentsOf: channel.bins.map { Int32(clamping: $0) })
            bins.append(contentsOf: channel.hdrBins.map { Int32(clamping: $0) })
        }
        var out = Data(capacity: 4 + metaData.count + bins.count * 4)
        withUnsafeBytes(of: UInt32(metaData.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(metaData)
        for value in bins {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        return out
    }

    static func decode(_ data: Data) -> Histogram? {
        let binBytes = 256 * 4 * 2 * 4
        guard data.count > 4 + binBytes else { return nil }
        let metaLength = data.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
        }
        guard metaLength > 0, data.count == 4 + Int(metaLength) + binBytes else { return nil }
        let metaData = data.subdata(in: 4..<(4 + Int(metaLength)))
        guard let meta = try? PropertyListDecoder().decode(Metadata.self, from: metaData),
              meta.binCount > 0,
              meta.clipHigh.count == 4, meta.clipCeiling.count == 4, meta.clipLow.count == 4
        else { return nil }

        let base = 4 + Int(metaLength)
        let values = data.withUnsafeBytes { raw -> [Int32] in
            var out = [Int32](repeating: 0, count: 8 * 256)
            for i in 0..<out.count {
                out[i] = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: base + i * 4,
                                                               as: Int32.self))
            }
            return out
        }
        func channel(_ index: Int) -> HistogramChannel {
            let start = index * 256 * 2
            let sdr = values[start..<(start + 256)].map(Int.init)
            let tail = values[(start + 256)..<(start + 512)].map(Int.init)
            return HistogramChannel(bins: sdr, hdrBins: tail,
                                    clippedHDR: meta.clipHigh[index],
                                    clippedScreen: meta.clipCeiling[index],
                                    clippedBlack: meta.clipLow[index])
        }
        return Histogram(binCount: meta.binCount, sampleCount: meta.sampleCount,
                         canvas: meta.canvas, roi: meta.roi, sampleSize: meta.sampleSize,
                         primaries: meta.primaries, headroom: meta.headroom,
                         red: channel(0), green: channel(1), blue: channel(2), luma: channel(3))
    }
}
