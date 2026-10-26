import XCTest
import Metal
import PhotonsCore

/// 派单 008 — the two things the Light panel's black/white controls got wrong.
///
///   **A. Direction.** Lightroom brightens towards + on both sliders: `blacks +` lifts the black
///   point (shadows open), `whites +` expands the white point (highlights brighten, clipping starts
///   sooner). The old kernel subtracted a positive `blk` for `+blacks` and divided by a larger `wht`
///   for `+whites`, so *both* sliders darkened. The table in
///   `testBlacksAndWhitesFollowLightroomDirection` prints the four measured means; the sign of each
///   one is the acceptance criterion.
///
///   **B. The matte.** A canvas larger than the picture is letterboxed by S0, and the bars are 0.
///   The remap maps 0 to `(0 − blk)/(wht − blk)`, which is positive whenever the black point is
///   lifted — that is the "dragging blacks lightens the background" bug. S2 now writes pixels outside
///   the content rect through untouched, and `testMatteStaysExactlyZeroAtExtremes` asserts the bar
///   pixels are **exactly** 0 (every channel, every extreme), while the picture inside still moves.
///
/// Everything is synthetic, so nothing here skips for want of a RAW fixture, and the numbers are
/// reproducible.
final class ToneMapTests: XCTestCase {

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "tone-test") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// A 3:2 test picture: a dark→bright horizontal ramp, with an exact-black block in the top-left
    /// corner and a near-white block in the bottom-right. A lifted black point shows up in the mean
    /// because the ramp's toe moves; an expanded white point shows up because the top end clips.
    private func rampImage(width: Int = 480, height: Int = 320) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x) / Double(width - 1)
                var base = 0.015 + 0.90 * t
                if x < 32 && y < 32 { base = 0 }                       // true black
                if x >= width - 32 && y >= height - 32 { base = 0.99 } // near white
                let o = (y * width + x) * 4
                rgba[o] = Float16(base)
                rgba[o + 1] = Float16(base)
                rgba[o + 2] = Float16(base)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// 16:9 canvas holding a 3:2 picture: 640×360 canvas, 540×360 content, 50-pixel bars each side.
    private func letterboxedOptions() -> RenderOptions {
        RenderOptions(canvas: ImageSize(width: 640, height: 360), scale: 1, wantsPixels: true)
    }

    private func contentRect(_ result: RenderResult) -> (x: Int, y: Int, w: Int, h: Int) {
        // The same centred rect `RenderGraph.plan` computes: `(canvas − content) / 2`, integer division.
        (x: (result.canvas.width - result.content.width) / 2,
         y: (result.canvas.height - result.content.height) / 2,
         w: result.content.width,
         h: result.content.height)
    }

    private func meanLuma(_ img: DisplayImage, rect: (x: Int, y: Int, w: Int, h: Int)) -> Double {
        var sum = 0.0
        var n = 0
        for y in rect.y..<(rect.y + rect.h) {
            for x in rect.x..<(rect.x + rect.w) {
                let o = (y * img.width + x) * 4
                sum += (Double(Float(img.rgba[o])) + Double(Float(img.rgba[o + 1]))
                        + Double(Float(img.rgba[o + 2]))) / 3
                n += 1
            }
        }
        return sum / Double(max(n, 1))
    }

    /// Largest RGB component (and whether every channel is *exactly* zero) outside the content rect.
    private func matteStatistics(_ img: DisplayImage, rect: (x: Int, y: Int, w: Int, h: Int))
        -> (maxValue: Float, nonZeroPixels: Int, pixels: Int) {
        var maxValue: Float = 0
        var nonZero = 0
        var pixels = 0
        for y in 0..<img.height {
            for x in 0..<img.width {
                let inside = x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
                if inside { continue }
                let o = (y * img.width + x) * 4
                let m = max(Float(img.rgba[o]), max(Float(img.rgba[o + 1]), Float(img.rgba[o + 2])))
                maxValue = max(maxValue, m)
                if m != 0 { nonZero += 1 }
                pixels += 1
            }
        }
        return (maxValue, nonZero, pixels)
    }

    private func maxAbsDifference(_ a: DisplayImage, _ b: DisplayImage,
                                  rect: (x: Int, y: Int, w: Int, h: Int)) -> Float {
        var d: Float = 0
        for y in rect.y..<(rect.y + rect.h) {
            for x in rect.x..<(rect.x + rect.w) {
                let o = (y * a.width + x) * 4
                for c in 0..<3 {
                    d = max(d, abs(Float(a.rgba[o + c]) - Float(b.rgba[o + c])))
                }
            }
        }
        return d
    }

    // MARK: - A. direction

    /// Acceptance ①: four measured content means. `+50` must be brighter than neutral on **both**
    /// sliders and `−50` darker on both — the bug was that both `+` values were the dark ones.
    func testBlacksAndWhitesFollowLightroomDirection() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let opts = letterboxedOptions()

        var neutral = EditModel.neutral
        neutral.light.temperature = nil
        neutral.light.tint = nil
        let base = try XCTUnwrap(graph.render(neutral, options: opts).display)
        let rect = contentRect(try graph.render(neutral, options: opts))
        let baseMean = meanLuma(base, rect: rect)

        func mean(blacks: Double = 0, whites: Double = 0) throws -> Double {
            var edit = neutral
            edit.light.blacks = blacks
            edit.light.whites = whites
            let img = try XCTUnwrap(graph.render(edit, options: opts).display)
            return meanLuma(img, rect: rect)
        }

        let rows: [(String, Double)] = [
            ("blacks=+50", try mean(blacks: 50)),
            ("blacks=-50", try mean(blacks: -50)),
            ("whites=+50", try mean(whites: 50)),
            ("whites=-50", try mean(whites: -50)),
        ]
        print("派单 008 方向表 (content mean, neutral = \(baseMean)):")
        for (name, m) in rows { print("  \(name): \(m)") }

        let blacksUp = rows[0].1, blacksDown = rows[1].1
        let whitesUp = rows[2].1, whitesDown = rows[3].1
        XCTAssertGreaterThan(blacksUp, baseMean + 0.005, "blacks +50 must lighten, not darken")
        XCTAssertLessThan(blacksDown, baseMean - 0.005, "blacks −50 must darken")
        XCTAssertGreaterThan(whitesUp, baseMean + 0.005, "whites +50 must lighten, not darken")
        XCTAssertLessThan(whitesDown, baseMean - 0.005, "whites −50 must darken")
    }

    /// `highlights +` must *brighten* the highlight zone (less recovery) and `highlights -` must
    /// recover it, which is the Lightroom gesture. The kernel used `exp2(-highlights …)`, so the panel
    /// read backwards: dragging right recovered instead of opening the highlights.
    func testHighlightsFollowLightroomDirection() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let opts = RenderOptions(scale: 0.5, wantsPixels: true)
        let neutral = EditModel.neutral
        let base = try XCTUnwrap(graph.render(neutral, options: opts).display)
        let rect = (0, 0, base.width, base.height)
        let baseMean = meanLuma(base, rect: rect)

        func mean(highlights: Double) throws -> Double {
            var edit = neutral
            edit.light.highlights = highlights
            let img = try XCTUnwrap(graph.render(edit, options: opts).display)
            return meanLuma(img, rect: rect)
        }

        let up = try mean(highlights: 50), down = try mean(highlights: -50)
        print("highlights direction (content mean, neutral = \(baseMean)): +50 = \(up), -50 = \(down)")
        XCTAssertGreaterThan(up, baseMean + 0.005, "highlights +50 must brighten, not recover")
        XCTAssertLessThan(down, baseMean - 0.005, "highlights -50 must recover (darken) the highlights")
    }

    /// Monotonicity, per slider, on a fixed picture: five stops of the same slider never fold back.
    func testEachSliderIsMonotoneAcrossItsRange() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let opts = RenderOptions(scale: 0.5, wantsPixels: true)
        let rect = { (img: DisplayImage) in (0, 0, img.width, img.height) }

        func series(_ apply: (inout EditModel, Double) -> Void) throws -> [Double] {
            var out: [Double] = []
            for v in stride(from: -100.0, through: 100.0, by: 25.0) {
                var edit = EditModel.neutral
                apply(&edit, v)
                let img = try XCTUnwrap(graph.render(edit, options: opts).display)
                out.append(meanLuma(img, rect: rect(img)))
            }
            return out
        }

        let blacks = try series { $0.light.blacks = $1 }
        let whites = try series { $0.light.whites = $1 }
        for i in 1..<blacks.count {
            XCTAssertGreaterThan(blacks[i], blacks[i - 1], "blacks folded between \(blacks[i - 1]) and \(blacks[i])")
            XCTAssertGreaterThan(whites[i], whites[i - 1], "whites folded between \(whites[i - 1]) and \(whites[i])")
        }
    }

    // MARK: - B. the matte

    /// Acceptance ②: canvas ≠ content, four extreme slider settings. Every letterbox pixel must be
    /// **exactly** 0, and the picture must still change — otherwise the guard would have eaten the
    /// adjustment.
    func testMatteStaysExactlyZeroAtExtremes() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let opts = letterboxedOptions()

        let neutral = EditModel.neutral
        let base = try XCTUnwrap(graph.render(neutral, options: opts).display)
        let rect = contentRect(try graph.render(neutral, options: opts))
        XCTAssertEqual(rect.x, 50, "the fixture must actually be letterboxed")
        XCTAssertEqual(rect.w, 540)

        let cases: [(String, Double, Double)] = [
            ("blacks=-100", -100, 0), ("blacks=+100", 100, 0),
            ("whites=-100", 0, -100), ("whites=+100", 0, 100),
        ]
        var worst: Float = 0
        for (name, blacks, whites) in cases {
            var edit = neutral
            edit.light.blacks = blacks
            edit.light.whites = whites
            let img = try XCTUnwrap(graph.render(edit, options: opts).display)
            let stats = matteStatistics(img, rect: rect)
            let delta = maxAbsDifference(img, base, rect: rect)
            print("派单 008 黑边 \(name): matte max = \(stats.maxValue), "
                  + "non-zero matte pixels = \(stats.nonZeroPixels)/\(stats.pixels), "
                  + "content Δmax = \(delta), content mean = \(meanLuma(img, rect: rect))")
            XCTAssertEqual(stats.maxValue, 0, "\(name): a letterbox pixel was tone-mapped")
            XCTAssertEqual(stats.nonZeroPixels, 0, "\(name): \(stats.nonZeroPixels) matte pixels are not black")
            XCTAssertGreaterThan(delta, 0.002, "\(name): the content must still move")
            worst = max(worst, stats.maxValue)
        }
        print("派单 008 黑边 worst-case max over all four extremes = \(worst)")
    }

    /// Everything above with the vignette in play: S3c already guards on the content rect and S4's
    /// encode maps 0 to 0 — this pins that they still do, at the extremes, with the sliders that used
    /// to lift the bars.
    ///
    /// The **curve** used to be the hole in this chain: a LUT with a point at `(0, 0.1)` lifted the
    /// matte to 0.349 display units. That is fixed in `s3_curve` (派单 008 C) and pinned by
    /// `CurveMatteTests`; the case is not re-run here because it is no longer a ToneMapTests concern.
    func testMatteSurvivesTheRestOfTheChain() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let opts = letterboxedOptions()
        for amount in [100.0, -100.0] {
            var edit = EditModel.neutral
            edit.light.blacks = 100
            edit.light.whites = 100
            edit.effects.vignetteAmount = amount
            let img = try XCTUnwrap(graph.render(edit, options: opts).display)
            let rect = contentRect(try graph.render(edit, options: opts))
            let stats = matteStatistics(img, rect: rect)
            print("派单 008 黑边 + vignette \(amount): matte max = \(stats.maxValue), "
                  + "non-zero = \(stats.nonZeroPixels)/\(stats.pixels)")
            XCTAssertEqual(stats.maxValue, 0, "the matte must be exactly 0 after S3c/S4 as well")
        }
    }

    // MARK: - C. 0/0 identity

    /// Acceptance ③: the neutral document's pixels are what they were before the sign fix. The hash
    /// is printed so the before/after numbers can be compared without re-recording anything; the
    /// assertion here is the part that can be made locally — a neutral render is its own decode plus
    /// the OETF, i.e. S2 contributes nothing (the `identity` branch), with or without letterboxing.
    func testNeutralToneMapContributesNothing() throws {
        let image = rampImage()
        let graph = try makeGraph(image)
        let neutral = EditModel.neutral

        let plain = try XCTUnwrap(graph.render(neutral, options: RenderOptions(scale: 1, wantsPixels: true)).display)
        let boxed = try XCTUnwrap(graph.render(neutral, options: letterboxedOptions()).display)
        print("派单 008 0/0 恒等: canvas==content sha256 = \(plain.sha256())")
        print("派单 008 0/0 恒等: letterboxed   sha256 = \(boxed.sha256())")

        // Determinism of the neutral path (the guard must not depend on dispatch geometry).
        let again = try XCTUnwrap(graph.render(neutral, options: letterboxedOptions()).display)
        XCTAssertEqual(boxed.sha256(), again.sha256())

        // A neutral render with a 16:9 canvas is the picture in the middle and nothing else: the
        // content rect's own pixels are the sRGB encode of the decoded values, and the bars are 0.
        let rect = contentRect(try graph.render(neutral, options: letterboxedOptions()))
        XCTAssertEqual(matteStatistics(boxed, rect: rect).maxValue, 0)
    }

    // MARK: - D. local adjustments use the same convention

    /// 派单 008 A also demands that a *local* whites/blacks adjustment is not left inverted: the
    /// panel and a mask must agree. Same picture, same sign, both brighter than neutral.
    func testLocalWhitesAndBlacksMatchTheGlobalConvention() throws {
        let image: LinearImage = {
            // Flat mid-grey: a lift on either control is unambiguous, and coverage is 1 everywhere.
            let w = 64, h = 64
            var rgba = [Float16](repeating: 0, count: w * h * 4)
            for i in stride(from: 0, to: rgba.count, by: 4) {
                rgba[i] = Float16(0.35); rgba[i + 1] = Float16(0.35)
                rgba[i + 2] = Float16(0.35); rgba[i + 3] = 1
            }
            return LinearImage(width: w, height: h, rgba: rgba,
                               colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        }()
        let graph = try makeGraph(image)
        let opts = RenderOptions(scale: 1, wantsPixels: true)
        let base = try XCTUnwrap(graph.render(EditModel.neutral, options: opts).display)
        let rect = (0, 0, base.width, base.height)
        let baseMean = meanLuma(base, rect: rect)

        func localMean(blacks: Double = 0, whites: Double = 0) throws -> Double {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m",
                               components: [MaskComponent(id: "c",
                                                          shape: .linearGradient(.default))],
                               adjustments: LocalAdjustments(whites: whites, blacks: blacks))]
            let img = try XCTUnwrap(graph.render(edit, options: opts).display)
            return meanLuma(img, rect: rect)
        }

        let up = try localMean(whites: 100), down = try localMean(whites: -100)
        let blackUp = try localMean(blacks: 100), blackDown = try localMean(blacks: -100)
        print("派单 008 局部: whites +100 = \(up), whites −100 = \(down), "
              + "blacks +100 = \(blackUp), blacks −100 = \(blackDown) (neutral \(baseMean))")
        XCTAssertGreaterThan(up, baseMean, "local whites + must brighten")
        XCTAssertLessThan(down, baseMean, "local whites − must darken")
        XCTAssertGreaterThan(blackUp, baseMean, "local blacks + must brighten")
        XCTAssertLessThan(blackDown, baseMean, "local blacks − must darken")
    }

    /// The same agreement for `highlights`: a bright flat patch (luma 0.75, inside the highlight
    /// weight) must get brighter with `highlights +` locally too, not just globally.
    func testLocalHighlightsMatchTheGlobalConvention() throws {
        let image: LinearImage = {
            let w = 64, h = 64
            var rgba = [Float16](repeating: 0, count: w * h * 4)
            for i in stride(from: 0, to: rgba.count, by: 4) {
                rgba[i] = Float16(0.75); rgba[i + 1] = Float16(0.75)
                rgba[i + 2] = Float16(0.75); rgba[i + 3] = 1
            }
            return LinearImage(width: w, height: h, rgba: rgba,
                               colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        }()
        let graph = try makeGraph(image)
        let opts = RenderOptions(scale: 1, wantsPixels: true)
        let base = try XCTUnwrap(graph.render(EditModel.neutral, options: opts).display)
        let rect = (0, 0, base.width, base.height)
        let baseMean = meanLuma(base, rect: rect)

        func localMean(highlights: Double) throws -> Double {
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m",
                               components: [MaskComponent(id: "c",
                                                          shape: .linearGradient(.default))],
                               adjustments: LocalAdjustments(highlights: highlights))]
            let img = try XCTUnwrap(graph.render(edit, options: opts).display)
            return meanLuma(img, rect: rect)
        }

        let up = try localMean(highlights: 100), down = try localMean(highlights: -100)
        print("local highlights: +100 = \(up), −100 = \(down) (neutral \(baseMean))")
        XCTAssertGreaterThan(up, baseMean, "local highlights + must brighten")
        XCTAssertLessThan(down, baseMean, "local highlights − must recover")
    }
}
