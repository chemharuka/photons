import XCTest
@testable import PhotonsCore

/// P1d — the counting loop is **parallel now**, and this file is the proof that parallel did not change
/// a bin.
///
/// `local/perf/perf-baseline-2026-10-28.md` §6 measured the histogram grid as a 1.38–1.83 ms **wall**
/// item whose GPU half was free (+0.01…0.05 ms): a single-threaded sweep of 43 520 pixels doing four
/// `srgbEncode` calls each. The fix spreads the rows over the cores — and the whole risk of a fix like
/// that is a bin quietly moving because a chunk boundary, a merge, or a `Float16` rounding behaved
/// differently in one block than in the loop it replaced.
///
/// So the claim here is exactness, not speed:
///
///   ① **one thread and N threads agree, bin for bin**, over a sample that exercises every branch —
///      black, the 0.0031308 knee, mid grey, white, three stops above white, negative (a curve can
///      undershoot), `+∞` and NaN;
///   ② the merge is a sum of integers, so the *ratios* agree too (`clippedHigh`, `clippedCeiling`,
///      `clippedLow`) and so does `sampleCount` — the four series and the twelve scalars travel
///      together;
///   ③ a sample too small to pay for a dispatch stays on one thread (`countWorkers`), which is also
///      the arm ① compares against.
final class HistogramParallelTests: XCTestCase {

    /// 256×170 = 43 520 pixels: the shipped frame-sample grid at a 4.10 Mpx picture, i.e. the size the
    /// measurement actually counts, and comfortably over `countWorkers`' 16 384-pixel floor.
    private let width = 256
    private let height = 170

    /// A sample with something in every bin and every edge case the counters know about.
    private func sample() -> LinearSample {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        // The interesting values, cycled across the frame: black, just under/over the knee, mid grey,
        // white, 3 stops above white, a negative, -0, +∞ and NaN (a curve can produce any of these).
        let values: [Float16] = [0, 0.0031307, 0.0031309, 0.02, 0.18, 0.5, 0.999, 1.0, 1.5, 8.0,
                                 -0.02, -0.0, .infinity, .nan]
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let i = (x &* 7 &+ y &* 13) % values.count
                rgba[o] = values[i]
                rgba[o + 1] = values[(i &+ 1) % values.count]
                rgba[o + 2] = values[(i &+ 5) % values.count]
                // Alpha is not read by this entry point (a *frame* sample carries luma there).
                rgba[o + 3] = 1
            }
        }
        return LinearSample(width: width, height: height, rgba: rgba)
    }

    func testOneThreadAndManyThreadsAgree() throws {
        let sample = sample()

        // The reference: the loop the change replaced, one row block.
        let serial = Histogram.compute(sample, bins: 256, rect: nil, headroom: 1, workers: 1)
        XCTAssertEqual(serial.sampleCount, width * height, "the fixture must land every pixel in a bin")

        for workers in [2, 3, 5, 8, 16] {
            let parallel = Histogram.compute(sample, bins: 256, rect: nil, headroom: 1,
                                             workers: workers)
            XCTAssertEqual(parallel, serial, "\(workers) row blocks moved a bin")
            XCTAssertEqual(parallel.sampleCount, serial.sampleCount)
            XCTAssertEqual(parallel.red.bins, serial.red.bins)
            XCTAssertEqual(parallel.red.hdrBins, serial.red.hdrBins)
            XCTAssertEqual(parallel.luma.bins, serial.luma.bins)
            XCTAssertEqual(parallel.luma.hdrBins, serial.luma.hdrBins)
            XCTAssertEqual(parallel.red.clippedHigh, serial.red.clippedHigh, accuracy: 0)
            XCTAssertEqual(parallel.red.clippedCeiling, serial.red.clippedCeiling, accuracy: 0)
            XCTAssertEqual(parallel.red.clippedLow, serial.red.clippedLow, accuracy: 0)
        }
    }

    /// A row count that does not divide by the block count is the case a naive split drops pixels on
    /// (170 rows over 8 blocks is 22, 22, …, 20). Ask for widths that cannot tile and compare.
    func testRaggedRowCountsLoseNoPixel() {
        for workers in [3, 7, 9, 13] {
            let sample = sample()
            let serial = Histogram.compute(sample, bins: 256, rect: nil, headroom: 1, workers: 1)
            let split = Histogram.compute(sample, bins: 256, rect: nil, headroom: 1, workers: workers)
            XCTAssertEqual(split.sampleCount, serial.sampleCount,
                           "\(workers) blocks changed the pixel count")
            XCTAssertEqual(split, serial, "\(workers) blocks moved a bin")
        }
    }

    /// A sub-rect measurement is the other shape the sweep has to get right: the split must stay inside
    /// `rect`, not inside the frame.
    func testSubRectIsSplitInsideTheRect() {
        let sample = sample()
        let rect = ImageRect(x: 11, y: 7, width: 200, height: 121)
        let serial = Histogram.compute(sample, bins: 256, rect: rect, headroom: 1, workers: 1)
        let split = Histogram.compute(sample, bins: 256, rect: rect, headroom: 1, workers: 6)
        XCTAssertEqual(split.sampleCount, 200 * 121)
        XCTAssertEqual(split, serial)
    }

    /// ③ — the dispatch is not worth it for a thumbnail, and `countWorkers` says so.
    func testSmallSamplesStayOnOneThread() {
        XCTAssertEqual(Histogram.countWorkers(width: 64, height: 64), 1)
        XCTAssertEqual(Histogram.countWorkers(width: 256, height: 4), 1, "too few rows to split")
        XCTAssertGreaterThan(Histogram.countWorkers(width: 256, height: 170), 1)
    }

    /// The headroom argument is the third input that must not drift between arms: an SDR ceiling and a
    /// +2 stop ceiling are different `clippedCeiling` numbers over the same bins.
    func testHeadroomRatiosAgreeAcrossBlocks() {
        let sample = sample()
        for headroom in [1.0, 2.0, 4.0] {
            let serial = Histogram.compute(sample, bins: 256, rect: nil, headroom: headroom, workers: 1)
            let split = Histogram.compute(sample, bins: 256, rect: nil, headroom: headroom, workers: 5)
            XCTAssertEqual(split, serial, "headroom \(headroom) disagrees across blocks")
        }
    }
}
