import XCTest
import Metal
import PhotonsCore

/// 372 — the histogram must not count the black matte a straighten/keystone opens into the canvas.
///
/// 307's document canvas is the AABB of the photograph's quad, so a turned (or keystoned) picture
/// leaves `000000` corners inside the sampled rect. The sample kernel used to read every texel of
/// that rect, so every corner pixel landed in bin 0 and the plot grew a false spike on the left —
/// a measurement error, not a picture one, and exactly what 307 recorded as a leftover.
///
/// 372 gives the two sample kernels the photograph's quad (four half-planes, canvas-normalised,
/// from `CropGeometry.photoQuad()`'s one owner). A sample outside it is excluded from every bin;
/// a sample inside it is still read exactly as before. A neutral document's quad contains the whole
/// canvas, so the coverage test is off and its bins are bit-for-bit the pre-372 ones.
final class HistogramMatte372Tests: XCTestCase {

    // MARK: - fixtures

    private let source = ImageSize(width: 1200, height: 800)

    /// A uniform 16-bit mid-grey photograph: every picture pixel is the same linear value, so any
    /// second nonzero bin (or a bin-0 spike) is a measurement error and nothing else.
    private func greyImage(_ value: Float16 = 0.18) -> LinearImage {
        let w = source.width, h = source.height
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i * 4] = value
            rgba[i * 4 + 1] = value
            rgba[i * 4 + 2] = value
            rgba[i * 4 + 3] = 1
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func makeGraph(_ image: LinearImage) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "histogram-matte-372"))
    }

    private func documentCanvas(_ edit: EditModel) -> ImageSize {
        CropGeometry(geometry: edit.geometry, source: source).canvas(.document)
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> RenderResult {
        let options = RenderOptions(
            canvas: documentCanvas(edit),
            canvasRole: .document,
            scale: 1,
            display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1),
            useCache: false,
            wantsPixels: false,
            collectHistogram: true,
            histogramBins: 256,
            histogramSampleLongEdge: Histogram.frameSampleLongEdge)
        return try graph.render(edit, options: options)
    }

    private func document(_ degrees: Double, _ vertical: Double = 0) -> EditModel {
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = degrees
        edit.geometry.perspectiveVertical = vertical
        return edit
    }

    private func nonZeroBins(_ channel: HistogramChannel) -> [(Int, Int)] {
        channel.bins.enumerated().compactMap { $0.element == 0 ? nil : ($0.offset, $0.element) }
    }

    /// A uniform photograph's plot is one small cluster around its own code; nothing may sit at
    /// either end. This is the "只有 V 附近一个尖峰" criterion in a form a test can fail on.
    private func assertOnePeak(_ histogram: Histogram, near peak: Int = 118, tolerance: Int = 8,
                               _ label: String) {
        for channel in Histogram.Channel.allCases {
            let series = histogram[channel]
            XCTAssertEqual(series.bins[0], 0,
                           "\(label) \(channel.rawValue) bin 0 must be 0 — the matte is not a "
                           + "sample, not a black one; got \(series.bins[0])")
            let outside = nonZeroBins(series).filter { abs($0.0 - peak) > tolerance }
            XCTAssertTrue(outside.isEmpty,
                          "\(label) \(channel.rawValue) has samples away from the peak: \(outside)")
            XCTAssertGreaterThan(series.total, 0, "\(label) \(channel.rawValue): nothing measured")
        }
    }

    /// The sample grid's texel centres that the photograph covers, counted on the CPU with the same
    /// Float arithmetic the kernel uses. Returns `(total, inside, outside)`.
    private func countSamples(_ result: RenderResult, canvas: ImageSize) throws
        -> (total: Int, inside: Int, outside: Int) {
        let grid = try XCTUnwrap(result.histogramSample, "no scene-linear sample grid")
        let quad = try XCTUnwrap(result.photoQuad, "no photograph quad")
        let picture = result.drawnRect
        let w = Float(max(canvas.width, 1)), h = Float(max(canvas.height, 1))

        var cx: Float = 0, cy: Float = 0
        let points = quad.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        for p in points { cx += p.x / w; cy += p.y / h }
        let centre = SIMD2<Float>(cx / 4, cy / 4)
        let planes: [SIMD4<Float>] = (0..<4).map { i in
            let a = SIMD2<Float>(points[i].x / w, points[i].y / h)
            let b = SIMD2<Float>(points[(i + 1) % 4].x / w, points[(i + 1) % 4].y / h)
            let ex = b.x - a.x, ey = b.y - a.y
            let len = (ex * ex + ey * ey).squareRoot()
            var n = SIMD2<Float>(ey / len, -ex / len)
            if n.x * (centre.x - a.x) + n.y * (centre.y - a.y) > 0 { n = -n }
            return SIMD4<Float>(n.x, n.y, n.x * a.x + n.y * a.y + 1e-6, 0)
        }
        func inside(_ p: SIMD2<Float>) -> Bool {
            planes.allSatisfy { p.x * $0.x + p.y * $0.y <= $0.z }
        }

        let stepX = Float(Double(picture.width) / Double(grid.width))
        let stepY = Float(Double(picture.height) / Double(grid.height))
        var insideCount = 0
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let fx = (Float(x) + 0.5) * stepX
                let fy = (Float(y) + 0.5) * stepY
                var tx = UInt32(floor(fx)), ty = UInt32(floor(fy))
                tx = min(tx, UInt32(picture.width - 1)) + UInt32(picture.x)
                ty = min(ty, UInt32(picture.height - 1)) + UInt32(picture.y)
                if inside(SIMD2<Float>((Float(tx) + 0.5) / w, (Float(ty) + 0.5) / h)) {
                    insideCount += 1
                }
            }
        }
        return (grid.width * grid.height, insideCount, grid.width * grid.height - insideCount)
    }

    private func matteSamples(_ sample: LinearSample) -> Int {
        var count = 0
        for i in stride(from: 0, to: sample.rgba.count, by: 4)
        where sample.rgba[i] == Float16(-65504) { count += 1 }
        return count
    }

    // MARK: - ① rotate 15°: the four corners must not enter bin 0

    func testRotatedPhotographHasNoMatteInBinZero() throws {
        let graph = try makeGraph(greyImage())
        let edit = document(15)
        let result = try render(graph, edit)
        defer { if let t = result.output { graph.recycle(output: t) } }
        let histogram = try XCTUnwrap(result.histogram)

        print("372 15°: canvas \(result.canvas.keyString), sample "
              + "\(try XCTUnwrap(result.histogramSample).size.keyString), "
              + "bin0 \(histogram.red.bins[0]) (was 18297), "
              + "sampleCount \(histogram.sampleCount)")
        assertOnePeak(histogram, "15°")

        // The same frame through the **display-referred** kernel (`histogram_sample`), with the
        // render's own quad: this is the second kernel 372 changes.
        let texture = try XCTUnwrap(result.output)
        let measured = try graph.measureFrameHistogram(
            fromFrame: texture, edit: edit, content: result.drawnRect,
            photoQuad: result.photoQuad)
        XCTAssertEqual(measured.histogram.red.bins[0], 0,
                       "the display kernel must exclude the matte too, got "
                       + "\(measured.histogram.red.bins[0])")

        // The anti-proof: without the quad the same bytes still put the corners in bin 0.
        let today = try graph.measureFrameHistogram(
            fromFrame: texture, edit: edit, content: result.drawnRect)
        XCTAssertGreaterThan(today.histogram.red.bins[0], 0,
                             "the pre-372 measurement must still see the corners — otherwise the "
                             + "green above is decoration")
        print("372 15° display kernel: with quad bin0 \(measured.histogram.red.bins[0]), "
              + "without quad bin0 \(today.histogram.red.bins[0])")
    }

    // MARK: - ② keystone, and keystone + rotate

    func testKeystonedPhotographHasNoMatteInBinZero() throws {
        let graph = try makeGraph(greyImage())
        for (label, edit) in [("v+60", document(0, 60)), ("9°+v+60", document(9, 60))] {
            let result = try render(graph, edit)
            defer { if let t = result.output { graph.recycle(output: t) } }
            let histogram = try XCTUnwrap(result.histogram)
            print("372 \(label): canvas \(result.canvas.keyString), bin0 "
                  + "\(histogram.red.bins[0]), sampleCount \(histogram.sampleCount)")
            assertOnePeak(histogram, label)

            let texture = try XCTUnwrap(result.output)
            let measured = try graph.measureFrameHistogram(
                fromFrame: texture, edit: edit, content: result.drawnRect,
                photoQuad: result.photoQuad)
            XCTAssertEqual(measured.histogram.red.bins[0], 0, "\(label): display kernel bin 0")
        }
    }

    // MARK: - ③ the neutral document: bit-for-bit unchanged

    /// The pre-372 numbers, captured before the change on this same fixture:
    /// canvas 1200×800, grid 256×171 = 43 776 samples, all of them in code bin 118, and
    /// `a76d1a9769e8b5fcaaca233ed69ee461acecc04f9346f913168e85e5dbbebff0` for every series.
    func testNeutralDocumentBinsAreBitForBitUnchanged() throws {
        let graph = try makeGraph(greyImage())
        let result = try render(graph, EditModel.neutral)
        defer { if let t = result.output { graph.recycle(output: t) } }
        let histogram = try XCTUnwrap(result.histogram)

        var expected = [Int](repeating: 0, count: 256)
        expected[118] = 43_776
        for channel in Histogram.Channel.allCases {
            let series = histogram[channel]
            XCTAssertEqual(series.bins, expected,
                           "\(channel.rawValue): the neutral plot moved; the coverage test must be "
                           + "off when the photograph's quad is the canvas")
            XCTAssertEqual(series.total, 43_776)
            XCTAssertEqual(series.sha256(),
                           "a76d1a9769e8b5fcaaca233ed69ee461acecc04f9346f913168e85e5dbbebff0",
                           "\(channel.rawValue): pre-372 digest")
        }
        XCTAssertEqual(histogram.sampleCount, 43_776)
        print("372 neutral: two arrays equal — expected bin118=43776, measured "
              + "\(nonZeroBins(histogram.red)); sha matches the pre-change digest")
    }

    // MARK: - ④ the count: only the quad's outside leaves; the inside keeps every sample

    func testOnlySamplesOutsideTheQuadAreExcluded() throws {
        let graph = try makeGraph(greyImage())
        let result = try render(graph, document(15))
        defer { if let t = result.output { graph.recycle(output: t) } }
        let histogram = try XCTUnwrap(result.histogram)
        let grid = try XCTUnwrap(result.histogramSample)
        let counted = try countSamples(result, canvas: result.canvas)
        let excluded = matteSamples(grid)

        print("372 sample count: grid \(counted.total) (pre-372 count), "
              + "photograph \(counted.inside) (CPU quad), measured \(histogram.sampleCount), "
              + "excluded \(excluded) (sentinels), outside \(counted.outside)")

        XCTAssertEqual(excluded, counted.outside, "every and only the quad's outside is a sentinel")
        XCTAssertEqual(histogram.sampleCount, counted.inside,
                       "the measured count must be the photograph-covered samples, error 0")
        XCTAssertEqual(histogram.sampleCount, counted.total - excluded)
        XCTAssertGreaterThan(excluded, 0, "θ = 15° must cut the corners, or nothing is tested")
        XCTAssertEqual(histogram.red.total, histogram.sampleCount,
                       "bin totals and the sample count are one number")
    }

    // MARK: - ⑤ the cost of the coverage test

    func testCoverageCostsAtMostPointThreeMilliseconds() throws {
        let graph = try makeGraph(greyImage())
        let edit = document(15)
        let result = try render(graph, edit)
        defer { if let t = result.output { graph.recycle(output: t) } }
        let texture = try XCTUnwrap(result.output)

        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        var withQuad: [Double] = [], without: [Double] = []
        for _ in 0..<7 {
            withQuad.append(try graph.measureFrameHistogram(
                fromFrame: texture, edit: edit, content: result.drawnRect,
                photoQuad: result.photoQuad).cost.gpuMilliseconds)
            without.append(try graph.measureFrameHistogram(
                fromFrame: texture, edit: edit, content: result.drawnRect).cost.gpuMilliseconds)
        }
        let delta = median(withQuad) - median(without)
        print(String(format: "372 cost: %.3f ms with the quad, %.3f ms without, Δ %.3f ms "
                     + "(budget +0.300)", median(withQuad), median(without), delta))
        XCTAssertLessThanOrEqual(delta, 0.3,
                                 "the four half-planes must stay inside the +0.3 ms budget")
    }

    // MARK: - ⑦ the reverse gate: force the coverage test true and ①② must go red

    func testTheReverseGateRestoresTheBinZeroSpike() throws {
        HistogramMatte372.ignoresPhotoQuad = true
        defer { HistogramMatte372.ignoresPhotoQuad = false }

        let graph = try makeGraph(greyImage())
        let expectations = [("15°", document(15), 18_297),
                            ("v+60", document(0, 60), 2_457),
                            ("9°+v+60", document(9, 60), 12_294)]
        for (label, edit, today) in expectations {
            let result = try render(graph, edit)
            defer { if let t = result.output { graph.recycle(output: t) } }
            let histogram = try XCTUnwrap(result.histogram)
            print("372 reverse gate \(label): bin0 \(histogram.red.bins[0]), today \(today)")
            XCTAssertEqual(histogram.red.bins[0], today,
                           "\(label): the gate must reproduce the pre-372 bin 0 exactly")
            XCTAssertGreaterThan(histogram.red.bins[0], 0,
                                 "\(label): the gate must bring the false spike back")
        }
    }
}
