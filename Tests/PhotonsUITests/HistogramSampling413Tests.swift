import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 413 — a column of the histogram plot claims the **highest point of the polyline it covers**, not
/// the point at its centre.
///
/// The owner's report: 「直方图…存在采样不足问题，例如在亮度 2.00 有 500 个像素，值完全一样。调整 EV 后
/// 这 500 个像素形成的柱的高度会变」. The arithmetic: the code half of a 244 pt card is 122 pt = 244
/// device px at 2×, for 256 bins — **1.05 bins per pixel**. A one-bin spike is therefore about one
/// pixel wide, and a centre sample lands on its apex or on a slope depending on where the histogram
/// happens to sit. An EV change pans the data by less than a pixel and the same spike swings between
/// 51 % and 100 % of its height.
///
/// So the tests here do **not** read pixels: they call the pure column sampler
/// (`HistogramCardView.envelopeMax`) over the real polyline (`HistogramCardFormat.points`, untouched)
/// and measure the heights it produces for 20 sub-pixel phases of the same data. The numbers the
/// suite prints are the before/after table in `local/REPORT.md`; `centreTop` below is a verbatim copy
/// of the pre-413 centre sample, and exists only so both columns of that table can be produced by the
/// same run.
///
/// The reverse gates (§3.3) are run by editing `envelopeMax`'s body, not this file, so what they
/// falsify is the production sampler:
///   ⑧a centre point sample  → `testASingleBinSpike…` red (the 27.6 px swing comes back)
///   ⑧b interval average     → `testTheTallestBin…` red
///   ⑧c interval endpoints   → `testASingleBinSpike…` / `testTwoAdjacentBins…` red
@MainActor
final class HistogramSampling413Tests: XCTestCase {

    /// The inspector's real card width and the shipped plot height (`HistogramCardView`).
    private let cardWidth: CGFloat = 244
    private let plotHeight: CGFloat = 58
    private let scale: CGFloat = 2
    private let binCount = 256

    private var plot: NSRect { NSRect(x: 0, y: 0, width: cardWidth, height: plotHeight) }
    private var stripWidth: CGFloat { 1 / scale }

    private enum Sampler { case maxPool, centre }

    // MARK: - fixtures

    /// One channel with `count` samples in each of `bins` (and/or `hdrBins`) and nothing elsewhere.
    private func channel(code: [Int: Int] = [:], tail: [Int: Int] = [:]) -> HistogramChannel {
        HistogramChannel(bins: (0..<binCount).map { code[$0] ?? 0 },
                         hdrBins: (0..<Histogram.hdrBinCount).map { tail[$0] ?? 0 },
                         clippedHigh: 0, clippedCeiling: 0, clippedLow: 0)
    }

    private func histogram(_ channel: HistogramChannel) -> Histogram {
        Histogram(binCount: binCount, sampleCount: channel.total,
                  canvas: ImageSize(width: 720, height: 420),
                  roi: ImageRect(x: 0, y: 0, width: 720, height: 420),
                  sampleSize: ImageSize(width: 720, height: 420),
                  primaries: .sRGB, headroom: 1,
                  red: channel, green: channel, blue: channel, luma: channel)
    }

    /// The real polyline, panned by `phase` points — what an EV change does to the drawn data.
    ///
    /// The strip grid stays put (it belongs to the view), the **data** moves: exactly the sub-pixel
    /// translation the owner sees. `points` itself is not touched or re-implemented here.
    private func points(_ channel: HistogramChannel, phase: CGFloat = 0) -> [CGPoint] {
        let axis = HistogramAxis(plot: plot)
        let raw = HistogramCardFormat.points(channel, binCount: binCount, axis: axis,
                                             peak: HistogramCardFormat.scalePeak(channel))
        guard phase != 0 else { return raw }
        return raw.map { CGPoint(x: $0.x + phase, y: $0.y) }
    }

    /// The 244 device-px columns' heights in **device px**, for one polyline.
    private func columnHeights(_ points: [CGPoint], sampler: Sampler) -> [CGFloat] {
        let plot = self.plot
        let strip = stripWidth
        let columns = Int((cardWidth / strip).rounded(.up))
        var cursor = 0
        var heights: [CGFloat] = []
        heights.reserveCapacity(columns)
        for column in 0..<columns {
            let x = plot.minX + CGFloat(column) * strip
            let width = min(strip, plot.maxX - x)
            guard width > 0 else { break }
            let top: CGFloat
            switch sampler {
            case .maxPool:
                top = HistogramCardView.envelopeMax(points, from: x, to: x + width, cursor: &cursor)
            case .centre:
                top = Self.centreTop(points, atX: x + width / 2, cursor: &cursor)
            }
            heights.append((plot.maxY - top) * scale)
        }
        return heights
    }

    private func tallest(_ heights: [CGFloat]) -> CGFloat { heights.max() ?? .nan }

    private func heightsAtEveryPhase(_ channel: HistogramChannel, sampler: Sampler) -> [CGFloat] {
        // 20 phases, 0.00 … 0.95 pt — exact count by index, because a `stride(by: 0.05)` over
        // `Double` accumulates error and yields 19 (§3.1's "at least 20").
        (0..<20).map { step in
            tallest(columnHeights(points(channel, phase: CGFloat(step) * 0.05), sampler: sampler))
        }
    }

    private func printPhases(_ label: String, _ heights: [CGFloat]) {
        let array = heights.map { String(format: "%.1f", $0) }.joined(separator: ", ")
        let spread = (heights.max() ?? .nan) - (heights.min() ?? .nan)
        print("413 \(label)：20 相位列高 [\(array)] px，max-min = \(String(format: "%.2f", spread)) px")
    }

    /// A verbatim copy of the pre-413 sampler (`HistogramCard.envelopeTop`), for the before column of
    /// the report's table. Production never calls this.
    private static func centreTop(_ points: [CGPoint], atX x: CGFloat,
                                  cursor: inout Int) -> CGFloat {
        guard let first = points.first, let last = points.last else { return .nan }
        if x <= first.x { return first.y }
        if x >= last.x { return last.y }
        var i = min(max(cursor, 0), points.count - 2)
        while i > 0 && points[i].x > x { i -= 1 }
        while i < points.count - 2 && points[i + 1].x < x { i += 1 }
        cursor = i
        let a = points[i], b = points[i + 1]
        let dx = b.x - a.x
        guard dx > 0 else { return b.y }
        let t = min(max((x - a.x) / dx, 0), 1)
        return a.y + (b.y - a.y) * t
    }

    // MARK: - ① the core: a one-bin spike keeps its height at every sub-pixel phase

    /// Before 413 this reads 56.6 … 108.9 px (a 27.6 pt = 55 px swing on the owner's table): the
    /// sample point slides off the apex as the data moves by a fraction of a pixel. After it: the
    /// strip covering the apex always claims it, so the tallest column is the same at all 20 phases.
    func testASingleBinSpikeKeepsItsHeightAcrossEverySubPixelPhase() {
        let spike = channel(code: [200: 500])
        let after = heightsAtEveryPhase(spike, sampler: .maxPool)
        let before = heightsAtEveryPhase(spike, sampler: .centre)
        printPhases("改后 单 bin 尖峰", after)
        printPhases("改前 单 bin 尖峰", before)

        let full = plotHeight * scale
        let spreadAfter = (after.max() ?? .nan) - (after.min() ?? .nan)
        XCTAssertLessThanOrEqual(spreadAfter, 1.0,
                                 "改后 20 个相位的列高差必须 ≤ 1 device px，实测 \(spreadAfter) px：\(after)")
        XCTAssertEqual(after.max() ?? .nan, full, accuracy: 0.01,
                       "尖峰的 500 == 峰值，最该占满 plot（\(full) px），实测 \(after.max() ?? .nan)")

        // The counter-proof lives here too, so the claim "the old sampler wobbled" is measured rather
        // than asserted from memory — and so ⑧a (centre sampling put back into `envelopeMax`) cannot
        // pass this test by accident.
        let spreadBefore = (before.max() ?? .nan) - (before.min() ?? .nan)
        XCTAssertGreaterThan(spreadBefore, 20,
                             "改前应当抖动（约 27.6 pt = 55 px），实测 \(spreadBefore) px —— 若这里也通过，"
                             + "说明诊断错了，先停下回报")
    }

    // MARK: - ② two adjacent spikes are not swallowed by their neighbour

    func testTwoAdjacentBinsAreNotSwallowedByTheirNeighbour() {
        let two = channel(code: [200: 500, 201: 500])
        let heights = columnHeights(points(two), sampler: .maxPool)
        let full = plotHeight * scale
        let fullColumns = heights.filter { $0 >= full - 1 }.count
        let run = longestRun(heights) { $0 >= full - 1 }
        print("413 双相邻 bin：满高 \(fullColumns) 列（连续 \(run) 列），列高 "
              + "\(heights.enumerated().filter { $0.element >= full - 1 }.prefix(6).map { "列\($0.offset)" })")
        // Two bins at 2× are ~1.9 device px wide, so both of them must be visible: at least two
        // columns at full height, and they must be a *run*, not two spikes separated by a dip.
        XCTAssertGreaterThanOrEqual(fullColumns, 2,
                                    "两个相邻尖峰都得画出来，实测满高列 \(fullColumns)：\(heights)")
        XCTAssertGreaterThanOrEqual(run, 2, "满高应当连续成一段，实测最长 \(run) 列")
    }

    // MARK: - ③ a plain plateau is unchanged (max must not make everything taller)

    /// On a **flat top** the polyline is horizontal, so the highest point of a strip and its centre
    /// point are the same number. The comparison is therefore restricted to the strips that lie
    /// entirely inside the plateau's interior: at the plateau's two ends the polyline climbs and
    /// falls, and there max-pooling *must* take the higher of the two edges (that is the fix, not a
    /// side effect).
    func testAPlainPlateauIsUnchangedByMaxPooling() {
        // A plateau at 300 that is **not** the peak (one bin elsewhere is 600), so its height is a
        // real fraction of the plot and "max makes everything taller" would be visible.
        var bins = Dictionary(uniqueKeysWithValues: (100...139).map { ($0, 300) })
        bins[20] = 600
        let plateau = channel(code: bins)
        let points = points(plateau)
        let axis = HistogramAxis(plot: plot)
        let flatStart = axis.x(sdrBin: 101, of: binCount)
        let flatEnd = axis.x(sdrBin: 138, of: binCount)
        var cursorMax = 0
        var cursorCentre = 0
        let columns = Int((cardWidth / stripWidth).rounded(.up))
        var worst: CGFloat = 0
        var compared = 0
        var top = CGFloat.nan
        for column in 0..<columns {
            let x = plot.minX + CGFloat(column) * stripWidth
            let width = min(stripWidth, plot.maxX - x)
            guard width > 0 else { break }
            let pooled = HistogramCardView.envelopeMax(points, from: x, to: x + width,
                                                       cursor: &cursorMax)
            let sampled = Self.centreTop(points, atX: x + width / 2, cursor: &cursorCentre)
            guard x >= flatStart, x + width <= flatEnd else { continue }
            compared += 1
            top = pooled
            worst = max(worst, abs(pooled - sampled))
        }
        let expected = plot.maxY - plotHeight * CGFloat(300) / CGFloat(HistogramCardFormat
            .scalePeak(plateau))
        print("413 平台：平顶内 \(compared) 列，max 与点采样最大差 \(String(format: "%.9f", worst)) pt，"
              + "平顶高度 \(String(format: "%.2f", plot.maxY - top)) pt（应为 "
              + "\(String(format: "%.2f", plot.maxY - expected)) pt）")
        XCTAssertGreaterThan(compared, 20, "平顶内要比对足够多的列")
        XCTAssertLessThanOrEqual(worst, 1e-9,
                                 "平顶上 max 与点采样必须同值（不能因为 max 把所有东西抬高），最大差 \(worst) pt")
        XCTAssertEqual(top, expected, accuracy: 1e-9, "平顶的高度不能被 max 抬高或压低")
    }

    // MARK: - ④ the tallest bin sets the height, not the interval average

    /// One bin at 500 inside a window of five bins that are otherwise 0. The window is ~2.4 pt, i.e.
    /// 4.8 device px, so this is "the spike is one fifth of what the column covers": max says 500,
    /// average says 100, endpoints say 0.
    func testTheTallestBinSetsTheColumnsHeightNotTheAverage() {
        let spike = channel(code: [100: 500])
        let pts = points(spike)
        let axis = HistogramAxis(plot: plot)
        let binWidth = axis.sdrWidth / CGFloat(binCount)
        let from = axis.x(sdrBin: 98, of: binCount)
        let to = axis.x(sdrBin: 102, of: binCount)
        XCTAssertGreaterThan(to - from, binWidth * 3.5, "窗口要覆盖 5 个 bin 左右（\(to - from) pt）")

        var cursor = 0
        let top = HistogramCardView.envelopeMax(pts, from: from, to: to, cursor: &cursor)
        let height = plot.maxY - top
        let full = plotHeight
        print("413 500/5 bin 窗口：列高 \(String(format: "%.2f", height)) pt（500 = 满高 \(full) pt；"
              + "平均值 100 会给出 \(String(format: "%.2f", full * 100 / 500)) pt）")
        XCTAssertEqual(height, full, accuracy: 1e-9,
                       "列高必须是 500 对应的满高，而不是平均值 100 的高度")

        // …and the same window measured *by average* is far below it, which is the distinction this
        // test exists to make (⑧b).
        var sum: CGFloat = 0
        let samples = 32
        for i in 0..<samples {
            var c = 0
            let x = from + (to - from) * (CGFloat(i) + 0.5) / CGFloat(samples)
            sum += plot.maxY - Self.centreTop(pts, atX: x, cursor: &c)
        }
        let average = sum / CGFloat(samples)
        XCTAssertLessThan(average, full * 0.5, "平均值采样应当只有 1/5 的高度，实测 \(average) pt")
    }

    // MARK: - ⑤ the tail segment gets the same treatment

    func testTheTailSegmentGetsTheSameTreatment() {
        let spike = channel(tail: [128: 500])
        let after = heightsAtEveryPhase(spike, sampler: .maxPool)
        let before = heightsAtEveryPhase(spike, sampler: .centre)
        printPhases("改后 尾段单 bin 尖峰", after)
        printPhases("改前 尾段单 bin 尖峰", before)

        let spreadAfter = (after.max() ?? .nan) - (after.min() ?? .nan)
        let spreadBefore = (before.max() ?? .nan) - (before.min() ?? .nan)
        XCTAssertLessThanOrEqual(spreadAfter, 1.0,
                                 "尾段也要 ≤ 1 device px，实测 \(spreadAfter) px：\(after)")
        XCTAssertGreaterThan(spreadBefore, 20, "尾段改前同样应抖动，实测 \(spreadBefore) px")
        XCTAssertEqual(after.max() ?? .nan, plotHeight * scale, accuracy: 0.01)
    }

    // MARK: - the cost of the wider sample

    /// The 406c baseline was measured on an **800 × 186 px P3 surface** — a 400 pt card, which is the
    /// default inspector width; that is the number 3.8 ms belongs to. The 244 pt card is the shipped
    /// minimum and is printed too (its surface is 488 × 180 px, so its timings are not comparable to
    /// the baseline). The assertion is only a sanity cap: a wall clock in a test suite is a flaky
    /// thing to assert, and "collapsed into a full scan of the bins" would be an order of magnitude.
    func testTheWiderSampleDoesNotCostASecondPassOverTheBins() throws {
        let channel = channel(code: Dictionary(uniqueKeysWithValues: (60...200).map { ($0, 40 + $0 % 900) }))
        for width in [CGFloat(400), cardWidth] {
            let (median, minimum, pixels) = drawTime(histogram(channel), width: width)
            print("413 draw 耗时（\(Int(width)) pt / \(pixels) px P3，15 次）：中位 "
                  + "\(String(format: "%.2f", median)) ms，min \(String(format: "%.2f", minimum)) ms"
                  + (width == 400 ? "（406c 基线 3.8 ms）" : "（出厂最窄卡）"))
            XCTAssertLessThan(median, 25, "列采样退化成全表扫描时才会到这里：\(median) ms")
        }
    }

    /// Median and minimum of 15 `draw`s at `width`, plus the surface's pixel dimensions.
    private func drawTime(_ histogram: Histogram, width cardWidth: CGFloat)
        -> (median: Double, minimum: Double, pixels: String) {
        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: HistogramCardView.contentHeight)
        card.appearance = NSAppearance(named: .aqua)
        card.histogram = histogram

        let pixelWidth = Int(cardWidth * scale)
        let pixelHeight = Int(HistogramCardView.contentHeight * scale)
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                bytesPerRow: pixelWidth * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        let resolution = NSAppearance(named: .aqua)!

        var times: [Double] = []
        for _ in 0..<15 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let start = CFAbsoluteTimeGetCurrent()
            resolution.performAsCurrentDrawingAppearance { card.draw(card.bounds) }
            times.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            NSGraphicsContext.restoreGraphicsState()
        }
        let sorted = times.sorted()
        return (sorted[sorted.count / 2], sorted[0], "\(pixelWidth)×\(pixelHeight)")
    }

    // MARK: - §3.2 the pixel comparison images

    /// Renders the three comparison fixtures to `local/413/`. The *before* set is produced by running
    /// this same test with `envelopeMax`'s body replaced by the pre-413 centre sample (§3.3 ⑧a); the
    /// file names are tagged by `PHOTONS_413_TAG` so a before run cannot overwrite an after run.
    func testTheComparisonFixturesAreRenderedForTheReport() throws {
        let tag = ProcessInfo.processInfo.environment["PHOTONS_413_TAG"] ?? "after"
        var plateauBins = Dictionary(uniqueKeysWithValues: (100...139).map { ($0, 300) })
        plateauBins[20] = 600
        let cases: [(name: String, channel: HistogramChannel)] = [
            ("spike", channel(code: [200: 500])),
            ("plateau", channel(code: plateauBins)),
            ("two-bins", channel(code: [200: 500, 201: 500])),
        ]
        for item in cases {
            let image = render(histogram(item.channel))
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("local/413", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("\(item.name)-\(tag).png")
            let rep = NSBitmapImageRep(cgImage: image)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
            print("413 像素对比图：\(url.path)")
        }
    }

    /// The card's real `draw`, upright, on an 8-bit sRGB surface read back as a `CGImage`.
    private func render(_ histogram: Histogram) -> CGImage {
        let width = Int(cardWidth * scale)
        let height = Int(HistogramCardView.contentHeight * scale)
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // The card is `isFlipped`: y grows downwards from its top-left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)

        let card = HistogramCardView()
        card.frame = NSRect(x: 0, y: 0, width: cardWidth, height: HistogramCardView.contentHeight)
        let resolution = NSAppearance(named: .aqua)!
        card.appearance = resolution
        card.histogram = histogram
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        resolution.performAsCurrentDrawingAppearance { card.draw(card.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    // MARK: - helpers

    private func longestRun(_ values: [CGFloat], where predicate: (CGFloat) -> Bool) -> Int {
        var best = 0
        var current = 0
        for value in values {
            if predicate(value) { current += 1; best = max(best, current) } else { current = 0 }
        }
        return best
    }
}
