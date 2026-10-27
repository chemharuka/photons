import XCTest
import Metal
import PhotonsCore

/// 048 — the histogram must measure the **photograph**, never the canvas around it.
///
/// The bug this file defends against is a *guess*: `LoupeController` used to compute the picture's
/// rect from `RenderResult.canvas`/`.content` (`(canvas − content) / 2`), which is only the picture's
/// rect when the picture is centred in the content rect. A 1:1 window over a picture smaller than the
/// viewport breaks the premise — the renderer draws the photograph at an offset and fills the rest of
/// the window with background (`s0_geometry.metal`) — so the guess measured the *window*, and bin 0
/// collected every background pixel. Measured on a 1600×1002 window over a 2400×800 picture: 37.0 %
/// of the sample in bin 0, none of it photograph.
///
/// What is pinned here, in the order the派单 asks for it:
///
///   1. **The rect is the drawing's**, not a derivation from two sizes: `RenderResult.photoRect`
///      equals the bounding box of the pixels S0 actually wrote — checked on a rendered frame, both
///      in a fit letterbox (bars 234 above / 235 below, i.e. asymmetric) and in a window that leaves
///      the frame (picture at (300, 200) of the canvas).
///   2. **Orientation is pinned by asymmetry**, and `ImageRect` is stated to be canvas pixels with
///      origin top-left / row 0 = the texture's first row — the space S0 writes `gid` in and
///      `histogram_sample.metal` reads `src.read` in. A vertically flipped rect cannot pass: the bars
///      are deliberately uneven and the picture's own black is in both halves.
///   3. **Bin 0 is exact**: letterbox black contributes nothing, the picture's own black contributes
///      every pixel. Per-bin equality against a histogram of the content region alone, and
///      `bin[0] == 4800` exactly — not 0, not the canvas's black count.
///   4. **The anti-proof**: the same claims, fed the whole canvas as if it were the picture, must
///      throw. If they ever stop throwing, the assertions above have lost their teeth.
///   5. **A degenerate rect measures nothing** instead of dividing by zero.
final class HistogramLetterboxTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "histogram-letterbox")
        throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// 2400×800, deliberately asymmetric: the top half is bright, the bottom half dark, the border is
    /// mid-grey (so the drawn bounds are findable to the pixel) and there is a pure-black block near
    /// the top-left only. A y-flip anywhere in the rect chain moves the bright half to the bottom and
    /// the black block to the bottom-left, which no centred, symmetric fixture could show.
    private func asymmetricImage(width: Int = 2400, height: Int = 800) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var v = y < height / 2 ? 0.62 : 0.08
                if x < 40 || x >= width - 40 || y < 40 || y >= height - 40 { v = 0.35 }
                if x >= 200 && x < 400 && y >= 60 && y < 220 { v = 0 }   // picture's own black
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v); rgba[o + 2] = Float16(v)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func render(_ graph: RenderGraph, canvas: ImageSize, window: ImageRect? = nil,
                        scale: Double = 1, collectHistogram: Bool = false)
        throws -> (result: RenderResult, texture: MTLTexture) {
        let options = RenderOptions(canvas: canvas, scale: scale, outputWindow: window,
                                   display: DisplayOptions(primaries: .sRGB, bitDepth: 16,
                                                           headroom: 1),
                                   useCache: false, wantsPixels: false,
                                   collectHistogram: collectHistogram, histogramBins: 256)
        let result = try graph.render(.neutral, options: options)
        return (result, try XCTUnwrap(result.output, "a pixels-free render hands back its texture"))
    }

    private func bytes(_ texture: MTLTexture) -> [Float16] {
        let w = texture.width, h = texture.height
        var raw = [Float16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return raw
    }

    /// The bounding box of the pixels that are not exactly `(0, 0, 0)` — where the photograph is.
    private func drawnBounds(_ texture: MTLTexture) -> ImageRect {
        let w = texture.width, h = texture.height
        let raw = bytes(texture)
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h {
            let row = y * w * 4
            for x in 0..<w {
                let o = row + x * 4
                guard raw[o] != 0 || raw[o + 1] != 0 || raw[o + 2] != 0 else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            return ImageRect(x: 0, y: 0, width: 0, height: 0)
        }
        return ImageRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - 1. the root cause: a window that leaves the picture

    /// The frame the user sees at 1:1 when the picture is smaller than the viewport: S0 writes the
    /// photograph at an offset and background around it. The old `(canvas − content) / 2` rect is the
    /// whole window here, so it counted that background; `photoRect` is the photograph.
    func testAWindowThatLeavesTheFrameMeasuresThePictureNotTheBackground() throws {
        let graph = try makeGraph(asymmetricImage())
        let canvas = ImageSize(width: 1600, height: 1002)
        // The window is bigger than the picture in both axes, at a non-zero offset: the photograph
        // lands at (300, 200) and every other pixel of the canvas is background.
        let window = ImageRect(x: -300, y: -200, width: 1600, height: 1002)
        let (result, texture) = try render(graph, canvas: canvas, window: window, collectHistogram: true)
        defer { graph.recycle(output: texture) }

        let drawn = drawnBounds(texture)
        XCTAssertEqual(result.drawnRect, drawn,
                       "photoRect must be the rect S0 actually drew the picture in, not a derivation")

        // The premise the old code assumed, stated so its failure is visible: the content rect is the
        // window (there is nothing to letterbox — canvas == window here), so the guess is the canvas.
        let guess = ImageRect(x: (result.canvas.width - result.content.width) / 2,
                              y: (result.canvas.height - result.content.height) / 2,
                              width: result.content.width, height: result.content.height)
        XCTAssertEqual(guess, ImageRect(x: 0, y: 0, width: 1600, height: 1002),
                       "the old rect is the whole window — the premise「content is centred」is what broke")
        XCTAssertNotEqual(result.drawnRect, guess, "and the picture is not that window")

        let backgroundSamples = guess.area - result.drawnRect.area
        let wrong = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral, content: guess)
        let right = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral,
                                                    content: result.drawnRect)
        print("048 window-leaves-frame: canvas \(canvas.keyString) → picture \(result.drawnRect) "
              + "drawn \(drawn); bin0 with the guess \(wrong.histogram.red.bins[0]) "
              + "(\(String(format: "%.1f", 100 * Double(wrong.histogram.red.bins[0]) / Double(max(wrong.histogram.red.total, 1)))) % of the sample) "
              + "vs with photoRect \(right.histogram.red.bins[0]) "
              + "(\(String(format: "%.1f", 100 * Double(right.histogram.red.bins[0]) / Double(max(right.histogram.red.total, 1)))) %)")

        XCTAssertGreaterThan(wrong.histogram.red.bins[0], right.histogram.red.bins[0] * 3,
                             "the guess counted the background into bin 0 — that is the reported bug")
        XCTAssertLessThan(Double(right.histogram.red.bins[0]) / Double(right.histogram.red.total),
                          0.05, "with the drawn rect, bin 0 is the picture's own blacks only")

        // The in-render measurement the same frame carries (`collectHistogram`) must agree with the
        // from-frame one about *where* the picture is: one layout, two measurements.
        let shipped = try XCTUnwrap(result.histogram)
        XCTAssertEqual(shipped.roi, result.drawnRect,
                       "the receipt the frame carries names the rect the frame was measured over")
    }

    // MARK: - 2. the fit letterbox, with uneven bars (orientation pinned)

    /// A fit frame of a 2400×800 picture in a 1600×1002 canvas: bars of 234 rows above and 235 below,
    /// i.e. **not** vertically symmetric. A rect whose `y` were measured from the bottom would sample
    /// one row of letterbox and lose one row of picture, and this fixture's top/bottom halves differ
    /// enough that its bins cannot hide it.
    func testTheFitLetterboxRectMatchesTheDrawingRowForRow() throws {
        let graph = try makeGraph(asymmetricImage())
        let canvas = ImageSize(width: 1600, height: 1002)
        let (result, texture) = try render(graph, canvas: canvas, collectHistogram: true)
        defer { graph.recycle(output: texture) }

        XCTAssertEqual(result.content.keyString, "1600x533",
                       "the picture is letterboxed into the canvas")
        let drawn = drawnBounds(texture)
        XCTAssertEqual(drawn, ImageRect(x: 0, y: 234, width: 1600, height: 533),
                       "234 rows above, 235 below — an asymmetric fixture on purpose")
        XCTAssertEqual(result.drawnRect, drawn)
        XCTAssertEqual(result.drawnRect.y + result.drawnRect.height, 767,
                       "the picture's last row is 766; row 767 is the bottom bar")
        XCTAssertLessThanOrEqual(result.drawnRect.maxX, result.canvas.width)
        XCTAssertLessThanOrEqual(result.drawnRect.maxY, result.canvas.height)

        let shipped = try XCTUnwrap(result.histogram)
        XCTAssertEqual(shipped.roi, result.drawnRect, "the fit frame's receipt is the same rect")

        // The top bar is picture-free: nothing but exactly 0 in it, all 234 rows of it.
        let raw = bytes(texture)
        var bottomRowsNonZero = 0
        for y in 767..<1002 {
            for x in 0..<1600 {
                let o = (y * 1600 + x) * 4
                if raw[o] != 0 || raw[o + 1] != 0 || raw[o + 2] != 0 { bottomRowsNonZero += 1 }
            }
        }
        XCTAssertEqual(bottomRowsNonZero, 0, "the bottom bar really is letterbox black")
    }

    // MARK: - 3. bin 0, to the pixel

    /// Describes the claim "the measurement is of the picture" so it can be checked — and, in
    /// `testCountingTheWholeCanvasIsRed`, so it can be shown to fail.
    private struct PictureClaim {
        var bins: [Histogram.Channel: [Int]]
        var bin0: Int
        var sampleCount: Int
        var area: Int
    }

    private enum ClaimError: Error, CustomStringConvertible {
        case bin(Histogram.Channel, Int, Int, Int)      // channel, bin, measured, expected
        case bin0(Histogram.Channel, Int, Int)
        case sampleCount(Int, Int)
        case area(Int, Int)

        var description: String {
            switch self {
            case .bin(let c, let i, let got, let want):
                return "\(c.rawValue) bin \(i): measured \(got), the picture alone has \(want)"
            case .bin0(let c, let got, let want):
                return "\(c.rawValue) bin 0: measured \(got), the picture's own black is \(want) px"
            case .sampleCount(let got, let want):
                return "sampleCount \(got), the picture's area is \(want)"
            case .area(let got, let want):
                return "measured area \(got) px, the picture is \(want) px"
            }
        }
    }

    /// Throws on the first deviation — the three things the派单 asks to be exactly true.
    private func check(_ measured: RenderGraph.FrameMeasurement, against claim: PictureClaim) throws {
        guard measured.histogram.sampleCount == claim.sampleCount else {
            throw ClaimError.sampleCount(measured.histogram.sampleCount, claim.sampleCount)
        }
        for channel in Histogram.Channel.allCases {
            guard let want = claim.bins[channel] else { throw ClaimError.area(0, 0) }
            let got = measured.histogram[channel].bins
            guard got.count == want.count else { throw ClaimError.area(got.count, want.count) }
            if got[0] != claim.bin0 { throw ClaimError.bin0(channel, got[0], claim.bin0) }
            for i in 0..<got.count where got[i] != want[i] {
                throw ClaimError.bin(channel, i, got[i], want[i])
            }
        }
    }

    /// The frame, built by hand so every pixel is known: canvas 1600×1002, picture at
    /// `(0, 234, 1600, 533)` — 234 rows of letterbox above, 235 below — and **4800** pure-black
    /// pixels inside the picture (4000 in the bright top half, 800 in the dark bottom half, so a
    /// vertical flip cannot keep the count but lose the placement).
    private func handBuiltFrame() -> (texture: MTLTexture, picture: ImageRect, blackCount: Int) {
        let canvasW = 1600, canvasH = 1002
        let picture = ImageRect(x: 0, y: 234, width: 1600, height: 533)
        var raw = [Float16](repeating: 0, count: canvasW * canvasH * 4)   // letterbox = 0, everywhere
        var black = 0
        for y in 0..<picture.height {
            for x in 0..<picture.width {
                var v: Float16 = y < 266 ? 0.71 : 0.31
                if y >= 300 && y < 340 { v = 0.52 }                      // a middle band, asymmetric
                if x >= 40 && x < 140 && y >= 20 && y < 60 { v = 0; black += 1 }       // 4000 above
                if x >= 900 && x < 940 && y >= 480 && y < 500 { v = 0; black += 1 }    // 800 below
                let o = ((picture.y + y) * canvasW + picture.x + x) * 4
                raw[o] = v; raw[o + 1] = v; raw[o + 2] = v; raw[o + 3] = 1
            }
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: canvasW, height: canvasH,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let texture = MTLCreateSystemDefaultDevice()!.makeTexture(descriptor: desc)!
        raw.withUnsafeBytes { buf in
            texture.replace(region: MTLRegionMake2D(0, 0, canvasW, canvasH), mipmapLevel: 0,
                            withBytes: buf.baseAddress!, bytesPerRow: canvasW * 8)
        }
        return (texture, picture, black)
    }

    /// The same pixels, but only the picture's own region, in the sample's own encoding: what
    /// 「只对内容区算」 means. Counted with the same binning code the measurement uses, so the
    /// comparison is about the *rect*, not about two ways of counting.
    private func pictureOnlyHistogram(_ texture: MTLTexture, picture: ImageRect, bins: Int)
        -> Histogram {
        let full = bytes(texture)
        let canvasW = texture.width
        var slice = [Float16](repeating: 0, count: picture.area * 4)
        for y in 0..<picture.height {
            for x in 0..<picture.width {
                let src = ((picture.y + y) * canvasW + picture.x + x) * 4
                let dst = (y * picture.width + x) * 4
                let r = full[src], g = full[src + 1], b = full[src + 2]
                slice[dst] = r; slice[dst + 1] = g; slice[dst + 2] = b
                // The sample's fourth channel is the luma the kernel computes, not alpha.
                slice[dst + 3] = Float16(Histogram.srgbEncode(
                    0.2126 * Histogram.srgbDecode(Float(r)) + 0.7152 * Histogram.srgbDecode(Float(g))
                        + 0.0722 * Histogram.srgbDecode(Float(b))))
            }
        }
        let image = DisplayImage(width: picture.width, height: picture.height, rgba: slice,
                                 primaries: .sRGB, bitDepth: 16)
        return Histogram.computeFrameSample(image, bins: bins,
                                            rect: ImageRect(x: 0, y: 0,
                                                            width: picture.width,
                                                            height: picture.height))
    }

    func testLetterboxBlackNeverReachesBinZeroAndThePicturesOwnBlackNeverLeaves() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try makeGraph(asymmetricImage(width: 2400, height: 800))
        let (texture, picture, blackCount) = handBuiltFrame()
        XCTAssertEqual(blackCount, 4800, "the fixture's own black, counted as it is written")

        // Stride 1: the grid is the picture, one sample per picture pixel, so bin counts are exact
        // rather than sampled. (`frameSampleSize` never upsamples, so this is the picture's size.)
        let measured = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral,
                                                       content: picture, sampleLongEdge: 1600)
        XCTAssertEqual(measured.cost.sampleSize.keyString, "1600x533",
                       "one sample per picture pixel — the count is exact, not an estimate")
        XCTAssertEqual(measured.rect, ImageRect(x: 0, y: 0, width: 1600, height: 533),
                       "the whole sample is picture: every sample texel is inside the rect")

        let truth = pictureOnlyHistogram(texture, picture: picture, bins: 256)
        var bins: [Histogram.Channel: [Int]] = [:]
        for channel in Histogram.Channel.allCases { bins[channel] = truth[channel].bins }
        let claim = PictureClaim(bins: bins, bin0: blackCount, sampleCount: picture.area,
                                 area: picture.area)
        // Throws (fails the test) on any bin that differs, on a bin 0 that is not exactly 4800, and
        // on a sample that is not exactly the picture's area.
        do {
            try check(measured, against: claim)
        } catch {
            XCTFail("the measurement must be the picture, but \(error)")
        }

        for channel in Histogram.Channel.allCases {
            XCTAssertEqual(measured.histogram[channel].bins[0], blackCount,
                           "\(channel.rawValue) bin 0 must be the picture's own 4800 black pixels — "
                           + "not 0 (they would have been dropped) and not "
                           + "\(blackCount + 1600 * 234 + 1600 * 235) (the canvas's black)")
            XCTAssertEqual(measured.histogram[channel].total, picture.area,
                           "\(channel.rawValue): the sample is the picture, not the canvas")
        }
        print("048 hand-built frame: canvas 1600x1002, picture 1600x533 at (0, 234) → "
              + "\(measured.cost.sampleSize.keyString) samples, bin0 = \(measured.histogram.red.bins[0]) "
              + "of \(measured.histogram.red.bins.reduce(0, +)) px (letterbox is "
              + "\(1600 * 234 + 1600 * 235) px and contributed none)")
    }

    // MARK: - 4. the anti-proof

    /// The same claims, fed the whole canvas: **must** throw. A test that only ever passes proves
    /// nothing about whether it would notice the bug.
    func testCountingTheWholeCanvasIsRed() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try makeGraph(asymmetricImage(width: 2400, height: 800))
        let (texture, picture, blackCount) = handBuiltFrame()
        let whole = ImageRect(x: 0, y: 0, width: texture.width, height: texture.height)
        XCTAssertNotEqual(whole, picture)

        let wrong = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral,
                                                     content: whole, sampleLongEdge: 1600)
        let truth = pictureOnlyHistogram(texture, picture: picture, bins: 256)
        var bins: [Histogram.Channel: [Int]] = [:]
        for channel in Histogram.Channel.allCases { bins[channel] = truth[channel].bins }
        let claim = PictureClaim(bins: bins, bin0: blackCount, sampleCount: picture.area,
                                 area: picture.area)

        XCTAssertThrowsError(try check(wrong, against: claim),
                             "the whole-canvas rect must be caught: that is what makes the "
                             + "green test evidence rather than decoration") { error in
            let text = "\(error)"
            XCTAssertTrue(text.contains("bin 0") || text.contains("sampleCount"),
                          "the first thing that breaks is bin 0 or the sample size — got: \(text)")
            print("048 anti-proof: counting the canvas fails with「\(text)」")
        }

        // And the size of the error, so the report has a number: the letterbox's own pixels.
        let letterbox = whole.area - picture.area
        XCTAssertEqual(wrong.histogram.red.bins[0], blackCount + letterbox,
                       "counting the canvas puts every one of the \(letterbox) letterbox pixels "
                       + "in bin 0 — exactly the「0 处多出一坨」the user reports")
        XCTAssertEqual(wrong.histogram.red.bins[0], 4800 + 750_400)

        // The bin-level teeth on their own: with the sample size allowed to be the canvas's (so the
        // first guard passes), bin 0 alone still fails. Weakening either guard alone must not be
        // enough to make this frame look measured.
        let canvasSized = PictureClaim(bins: bins, bin0: blackCount, sampleCount: whole.area,
                                       area: whole.area)
        XCTAssertThrowsError(try check(wrong, against: canvasSized),
                             "bin 0 alone must reject the canvas") { error in
            XCTAssertTrue("\(error)".contains("bin 0"), "got: \(error)")
        }
    }

    // MARK: - 5. degenerate rects

    /// A 0-wide or 0-tall rect, and a rect wholly outside the texture: no dispatch, no division by
    /// zero, no crash — an empty histogram that says so.
    func testADegenerateRectMeasuresNothingInsteadOfDividingByZero() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try makeGraph(asymmetricImage(width: 2400, height: 800))
        let (texture, picture, _) = handBuiltFrame()

        let degenerate: [ImageRect] = [
            ImageRect(x: 100, y: 300, width: 0, height: 0),
            ImageRect(x: 100, y: 300, width: 0, height: 400),
            ImageRect(x: 100, y: 300, width: 400, height: 0),
            ImageRect(x: -500, y: 0, width: 400, height: 400),      // wholly off the left edge
            ImageRect(x: 0, y: 5000, width: 400, height: 400),      // wholly below the texture
        ]
        for rect in degenerate {
            let measured = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral,
                                                            content: rect)
            XCTAssertTrue(measured.rect.isEmpty, "\(rect): nothing of that is in the texture")
            XCTAssertEqual(measured.histogram.sampleCount, 0, "\(rect): 0 samples, not a divide")
            for channel in Histogram.Channel.allCases {
                XCTAssertEqual(measured.histogram[channel].total, 0)
                XCTAssertEqual(measured.histogram[channel].bins.count, 256)
                XCTAssertEqual(measured.histogram[channel].clippedLow, 0, "no NaN ratios")
            }
            XCTAssertEqual(measured.cost.gpuMilliseconds, 0, "\(rect): no dispatch happened")
        }

        // A rect that hangs off the edge is *clipped*, not moved: the part that was not drawn is not
        // measured, and what was drawn keeps its own offset. (0, 200, 800, 400) of the canvas, i.e.
        // 256×128 samples — `clamped(in:)` would have slid it to (0, 200, 800, 400) only by luck and
        // to x = 0 with the full width otherwise, measuring background the picture never had.
        let hanging = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral,
                                                       content: ImageRect(x: -200, y: 200,
                                                                          width: 1000, height: 400))
        XCTAssertEqual(hanging.cost.sampleSize.keyString, "256x128",
                       "the rect is clipped to the canvas, so the grid is 800×400 at stride ~3")
        XCTAssertEqual(hanging.rect, ImageRect(x: 0, y: 0, width: 256, height: 128))
        _ = picture
    }
}
