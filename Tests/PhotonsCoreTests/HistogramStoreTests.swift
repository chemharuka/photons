import XCTest
import PhotonsCore

/// 428 — the histogram's **disk** cache: the file format, the round trip, and the failure modes.
///
/// The claim this file defends is the one the user made: 切换照片后不需要等直方图加载. In memory that is
/// "the cache is not emptied when the photo changes" (`HistogramCache428Tests`); across a relaunch —
/// or past the 64-entry window — it is "the numbers are on disk and a read costs tens of
/// microseconds, not a re-measurement".
///
/// The format is `[UInt32 metaLength][binary plist][2048 × Int32 little endian]`; why the bins are not
/// a plist (1.73 ms per decode) is written down in `HistogramStore`'s header, measured, so it is not
/// re-litigated here.
final class HistogramStoreTests: XCTestCase {

    private var root: URL!
    private var store: HistogramStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hist428-\(UUID().uuidString)", isDirectory: true)
        store = HistogramStore(root: root)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        root = nil
        store = nil
        super.tearDown()
    }

    // MARK: - fixtures

    /// A histogram with every field non-default: distinct bins per channel, a tail, three different
    /// clipping ratios, an ROI that is not the whole canvas, a headroom above 1. A round trip that
    /// compares equal therefore compared *every* field, not just "some bins came back".
    private func fixture(bins: Int = 256) -> Histogram {
        func channel(_ seed: Int, _ width: Int) -> HistogramChannel {
            HistogramChannel(bins: (0..<width).map { ($0 * (seed &+ 1)) % 97 + seed },
                             hdrBins: (0..<Histogram.hdrBinCount).map { ($0 &+ seed) % 13 },
                             clippedHDR: Double(seed) / 1000,
                             clippedScreen: Double(seed) / 2000,
                             clippedBlack: Double(seed) / 5000)
        }
        return Histogram(binCount: bins, sampleCount: 12_345,
                         canvas: ImageSize(width: 1500, height: 1000),
                         roi: ImageRect(x: 10, y: 20, width: 1480, height: 960),
                         sampleSize: ImageSize(width: 1024, height: 683),
                         primaries: .rec2020, headroom: 4.924577653378805,
                         red: channel(1, bins), green: channel(2, bins),
                         blue: channel(3, bins), luma: channel(4, bins))
    }

    // MARK: - A③ the round trip is field-for-field

    /// Write, then read through a **second** `HistogramStore` (a new process reading the same
    /// directory is this, plus a `Data(contentsOf:)`): the two `Histogram`s are `==`.
    func testRoundTripIsFieldForFieldEqual() throws {
        let key = Histogram.cacheKey(rungIdentity: "content|asset-s1.0", editDigest: "0123456789abcdef",
                                     bins: 256, ceiling: HighlightCeiling.defaultLinear)
        let value = fixture()
        store.write(value, for: key)

        let file = store.url(for: key)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let reopened = HistogramStore(root: root)
        let loaded = try XCTUnwrap(reopened.load(key: key),
                                   "a file this store just wrote must be readable by a new one")
        // `Histogram: Equatable` compares binCount, sampleCount, canvas, roi, sampleSize, primaries,
        // headroom and all four channels — bins, hdrBins and the three ratios each.
        XCTAssertEqual(loaded, value)
        XCTAssertEqual(loaded.binsDigest(), value.binsDigest())
        XCTAssertEqual(loaded.red.hdrBins, value.red.hdrBins)
        XCTAssertEqual(loaded.luma.clippedScreen, value.luma.clippedScreen)

        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        print("428 disk: \(size) B per histogram · key \(key)")
        XCTAssertLessThan(size, 12 * 1024, "the format is ~8.5 KB: 8 × 256 Int32 + ~250 B of plist")
    }

    /// The bins are eight segments in a fixed order (R/G/B **L**, SDR then tail). A round trip could
    /// still be "equal" if the segments were shuffled and shuffled back, so this reads the raw Int32
    /// block at the documented offsets and compares with the fields.
    func testBinsAreEightSegmentsInTheDocumentedOrder() throws {
        let value = fixture()
        let key = "layout"
        let data = try XCTUnwrap(store.data(for: value, key: key))
        let metaLength = data.withUnsafeBytes {
            Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)))
        }
        XCTAssertEqual(data.count, 4 + metaLength + 8 * 256 * 4,
                       "4 B length + plist + 2048 Int32")

        let base = 4 + metaLength
        func bin(_ index: Int) -> Int {
            data.withUnsafeBytes {
                Int(Int32(littleEndian: $0.loadUnaligned(fromByteOffset: base + index * 4,
                                                         as: Int32.self)))
            }
        }
        // Segment 0 red.bins, 1 red.hdrBins, 2 green.bins, 3 green.hdrBins, 4 blue.bins,
        // 5 blue.hdrBins, 6 luma.bins, 7 luma.hdrBins — 4 channels, luma included (403 stopped
        // drawing it, and `luma.clippedHDR` is still the source of the card's 过白 percentage).
        for (segment, channel) in value.channels.enumerated() {
            XCTAssertEqual(bin(segment * 512), channel.bins[0], "segment \(segment) bin 0")
            XCTAssertEqual(bin(segment * 512 + 255), channel.bins[255])
            XCTAssertEqual(bin(segment * 512 + 256), channel.hdrBins[0])
            XCTAssertEqual(bin(segment * 512 + 511), channel.hdrBins[255])
        }
    }

    // MARK: - A④ another recipe is another key, so it is another file

    /// The key is the identity of the numbers: a different ceiling, a different bin count or a
    /// different rung (i.e. a different sample scale) cannot read this file. Nothing is deleted and
    /// nothing has to be — the old key simply is not asked for again.
    func testAnotherRecipeIsAMiss() throws {
        let base = Histogram.cacheKey(rungIdentity: "content|asset-s1.0", editDigest: "abcd",
                                      bins: 256, ceiling: HighlightCeiling.defaultLinear)
        store.write(fixture(), for: base)
        XCTAssertNotNil(store.load(key: base))

        let otherCeiling = Histogram.cacheKey(rungIdentity: "content|asset-s1.0", editDigest: "abcd",
                                              bins: 256, ceiling: HighlightCeiling.linear(ev: 1.0))
        let otherBins = Histogram.cacheKey(rungIdentity: "content|asset-s1.0", editDigest: "abcd",
                                           bins: 512, ceiling: HighlightCeiling.defaultLinear)
        let otherScale = Histogram.cacheKey(rungIdentity: "content|asset-s0.5", editDigest: "abcd",
                                            bins: 256, ceiling: HighlightCeiling.defaultLinear)
        XCTAssertNotEqual(base, otherCeiling)
        XCTAssertNotEqual(base, otherBins)
        XCTAssertNotEqual(base, otherScale)
        for (name, key) in [("ceiling", otherCeiling), ("bins", otherBins), ("sampleScale", otherScale)] {
            XCTAssertNil(store.load(key: key), "a changed \(name) must not hit the old file")
        }
    }

    /// The file name is the SHA-256 of the memory key, so the key string has to be compared on read as
    /// well: a file whose stored key differs is a miss even when the name matches by chance.
    func testStoredKeyMustMatch() throws {
        let key = "asked-for"
        let bytes = try XCTUnwrap(store.data(for: fixture(), key: "something-else"))
        let file = store.url(for: key)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try bytes.write(to: file)
        XCTAssertNil(store.load(key: key))
    }

    // MARK: - A⑥ a damaged file is a miss, never a crash

    func testTruncatedAndCorruptFilesAreMisses() throws {
        let key = "damaged"
        let value = fixture()
        store.write(value, for: key)
        let file = store.url(for: key)
        let whole = try Data(contentsOf: file)
        XCTAssertNotNil(store.load(key: key))

        // Half a histogram: the plist is fine, the bins are not there.
        try whole.prefix(whole.count / 2).write(to: file)
        XCTAssertNil(store.load(key: key), "a half file must be a miss")

        // A whole file with four bytes too many: the length is not `4 + meta + 8192`.
        try (whole + Data([0, 0, 0, 0])).write(to: file)
        XCTAssertNil(store.load(key: key))

        // A length prefix that promises more than the file holds.
        try Data([0xff, 0xff, 0xff, 0x7f]) .write(to: file)
        XCTAssertNil(store.load(key: key))

        // Empty.
        try Data().write(to: file)
        XCTAssertNil(store.load(key: key))

        // No file at all.
        try FileManager.default.removeItem(at: file)
        XCTAssertNil(store.load(key: key))
    }

    /// A histogram the format cannot carry (another bin count) is not persisted at all — better a miss
    /// than a file that decodes into 256 bins' worth of somebody else's numbers.
    func testNonStandardBinCountIsNotPersisted() throws {
        let value = fixture(bins: 64)
        store.write(value, for: "bins64")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url(for: "bins64").path))
        XCTAssertNil(store.load(key: "bins64"))
    }

    /// What one in-memory `Histogram` costs, so 64 of them is a number and not a guess: eight `[Int]`
    /// arrays of 256 (four channels × SDR + tail) plus the 12 ratios and the labels.
    func testInMemorySizeOfOneHistogram() {
        let value = fixture()
        let bins = value.channels.reduce(0) { total, channel in
            total + (channel.bins.count + channel.hdrBins.count) * MemoryLayout<Int>.stride
        }
        print("428 memory: 1 histogram = \(bins) B of bins · 64 = \(bins * 64) B "
              + "(\(String(format: "%.2f", Double(bins * 64) / 1_048_576)) MB)")
        XCTAssertEqual(bins, 4 * 512 * MemoryLayout<Int>.stride)
    }

    // MARK: - A⑤ a read is cheaper than a frame

    /// Ten files, ten reads each: the median and the worst single read are printed and the median is
    /// asserted below the 5 ms the task allows on the main thread. (Measured with `Data(contentsOf:)` +
    /// 2048 unaligned Int32 loads; the plist is ~250 B.)
    func testAReadIsFastEnoughForMainThread() throws {
        var values: [(String, Histogram)] = []
        for i in 0..<10 {
            let key = Histogram.cacheKey(rungIdentity: "photo\(i)|asset-s1.0", editDigest: "d\(i)",
                                         bins: 256, ceiling: HighlightCeiling.defaultLinear)
            let value = fixture()
            store.write(value, for: key)
            values.append((key, value))
        }
        var times: [Double] = []
        for _ in 0..<10 {
            for (key, _) in values {
                let t0 = CFAbsoluteTimeGetCurrent()
                let loaded = store.load(key: key)
                times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                XCTAssertNotNil(loaded)
            }
        }
        let sorted = times.sorted()
        let median = sorted[sorted.count / 2]
        print(String(format: "428 disk read: %d reads · p50 %.4f ms · max %.4f ms",
                      times.count, median, sorted.last ?? 0))
        XCTAssertLessThan(median, 5.0, "a cache hit must fit in a main-thread turn")
    }
}
