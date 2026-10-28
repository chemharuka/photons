import XCTest
import Metal
@testable import PhotonsCore

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
    ///
    /// 074: the *statistic* had to change with the model. `blacks` is an end-point move now
    /// (073B): on this ramp only the bottom ~4 % of the picture is inside the 7 EV knee, so the whole
    /// image's mean is the wrong witness for "does the dark end lift". Blacks is measured on a dark
    /// band fixture instead; whites keeps the ramp, which is where its knee lives.
    func testBlacksAndWhitesFollowLightroomDirection() throws {
        let dark: [Float] = [0.002, 0.004, 0.008, 0.016, 0.05]
        let darkGraph = try makeGraph(bands(dark), identity: "tone-dark")
        let opts = RenderOptions(scale: 1, wantsPixels: true)

        func darkMean(blacks: Double) throws -> Double {
            var edit = EditModel.neutral
            edit.light.blacks = blacks
            let img = try XCTUnwrap(darkGraph.render(edit, options: opts).display)
            var sum = 0.0
            for i in stride(from: 0, to: img.rgba.count, by: 4) { sum += Double(img.rgba[i]) }
            return sum / Double(img.width * img.height)
        }
        let darkBase = try darkMean(blacks: 0)
        let blacksUp = try darkMean(blacks: 50), blacksDown = try darkMean(blacks: -50)

        let image = rampImage()
        let graph = try makeGraph(image)
        let boxed = letterboxedOptions()
        var neutral = EditModel.neutral
        neutral.light.temperature = nil
        neutral.light.tint = nil
        let base = try XCTUnwrap(graph.render(neutral, options: boxed).display)
        let rect = contentRect(try graph.render(neutral, options: boxed))
        let baseMean = meanLuma(base, rect: rect)

        func mean(whites: Double) throws -> Double {
            var edit = neutral
            edit.light.whites = whites
            let img = try XCTUnwrap(graph.render(edit, options: boxed).display)
            return meanLuma(img, rect: rect)
        }
        let whitesUp = try mean(whites: 50), whitesDown = try mean(whites: -50)

        print("派单 008 方向表 (neutral = \(baseMean), dark-band mean = \(darkBase)):")
        print("  blacks=+50 \(blacksUp) · blacks=-50 \(blacksDown) · whites=+50 \(whitesUp) · whites=-50 \(whitesDown)")

        XCTAssertGreaterThan(blacksUp, darkBase + 0.005, "blacks +50 must lighten the dark end")
        XCTAssertLessThan(blacksDown, darkBase - 0.005, "blacks −50 must darken the dark end")
        XCTAssertGreaterThan(whitesUp, baseMean + 0.005, "whites +50 must lighten, not darken")
        XCTAssertLessThan(whitesDown, baseMean - 0.005, "whites −50 must darken")
    }

    private func bands(_ values: [Float], bandsPerValue: Int = 32, height: Int = 32) -> LinearImage {
        let width = values.count * bandsPerValue
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(values[min(values.count - 1, x / bandsPerValue)])
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
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

        // 085: the three region lifts must leave the bars alone at both ends too.
        for (name, apply) in [("shadows", { (e: inout EditModel, v: Double) in e.light.shadows = v }),
                              ("midtones", { (e: inout EditModel, v: Double) in e.light.midtones = v }),
                              ("highlights", { (e: inout EditModel, v: Double) in e.light.highlights = v })] {
            for value in [100.0, -100.0] {
                var edit = neutral
                apply(&edit, value)
                let img = try XCTUnwrap(graph.render(edit, options: opts).display)
                let stats = matteStatistics(img, rect: rect)
                let delta = maxAbsDifference(img, base, rect: rect)
                print("085 黑边 \(name)=\(value): matte max = \(stats.maxValue), "
                      + "non-zero = \(stats.nonZeroPixels)/\(stats.pixels), content Δmax = \(delta)")
                XCTAssertEqual(stats.maxValue, 0, "\(name) \(value): a letterbox pixel was tone-mapped")
                XCTAssertEqual(stats.nonZeroPixels, 0, "\(name) \(value): matte is not black")
                XCTAssertGreaterThan(delta, 0.002, "\(name) \(value): the content must still move")
            }
        }
    }

    /// Everything above with the vignette in play: S3c already guards on the content rect and S4's
    /// encode maps 0 to 0 — this pins that they still do, at the extremes, with the sliders that used
    /// to lift the bars.
    ///
    /// The **curve** used to be the hole in this chain: a LUT with a lifted black end lightened the
    /// matte. That is fixed by the content guard in the curve's kernel (派单 008 C) — which since
    /// 派单 030 lives in `s1_7_hdr_curve.metal`, before this stage rather than after it — and pinned
    /// by `CurveMatteTests`; the case is not re-run here because it is no longer a ToneMapTests
    /// concern.
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

        // 085: the new 中间调 slider at 0 is part of the neutrality, not a second path.
        var withMid = neutral
        withMid.light.midtones = 0
        let midZero = try XCTUnwrap(graph.render(withMid, options: letterboxedOptions()).display)
        XCTAssertEqual(boxed.sha256(), midZero.sha256())

        // A neutral render with a 16:9 canvas is the picture in the middle and nothing else: the
        // content rect's own pixels are the sRGB encode of the decoded values, and the bars are 0.
        let rect = contentRect(try graph.render(neutral, options: letterboxedOptions()))
        XCTAssertEqual(matteStatistics(boxed, rect: rect).maxValue, 0)
    }

    // MARK: - D. local adjustments use the same convention

    /// **079 §2.1.2 — the mask's blacks/whites are 073B/073C's end points, not 019's affine level.**
    ///
    /// This test used to pin the opposite: a flat 0.35 mid-grey had to move for `blacks ±100`, which is
    /// what 019's `(v − blk)/max(wht − blk, 1e−3)` does — it changes the *slope of the whole picture*, so
    /// a 50 % grey moved +25 codes and every pixel with it. 073B replaced that globally (the knee is a
    /// window below −4.2 EV, so a mid-tone is outside it and does not move at all), and 079 §2.1.2 says
    /// the mask must follow the global convention rather than keep a second one.
    ///
    /// So the conventions are pinned where each one is visible:
    ///   · a 0.35 mid-grey is **untouched** by `blacks ±100` (outside the knee), and
    ///   · a 0.02 deep shadow **is** lifted/crushed by `blacks ±100`, which is the toe the slider names;
    ///   · a 0.98 near-white follows `whites ±100` (the white point is where that slider lives).
    ///
    /// `LocalToneTests` goes further and asserts the masked slider produces the *same pixels* as the
    /// global one, on real frames, for all four sliders at ±100.
    func testLocalBlacksAndWhitesAreTheGlobalEndPoints() throws {
        func flat(_ v: Float) -> LinearImage {
            let w = 64, h = 64
            var rgba = [Float16](repeating: 0, count: w * h * 4)
            for i in stride(from: 0, to: rgba.count, by: 4) {
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v)
                rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
            return LinearImage(width: w, height: h, rgba: rgba,
                               colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        }
        let opts = RenderOptions(scale: 1, wantsPixels: true)

        /// A crisp disc: coverage is exactly 1 at the centre, so the probe below is arithmetic and not
        /// a mix with the uncovered frame.
        func probe(_ image: LinearImage, blacks: Double = 0, whites: Double = 0) throws -> Float {
            let graph = try makeGraph(image, identity: "tone-local-\(blacks)-\(whites)")
            var edit = EditModel.neutral
            edit.masks = [Mask(id: "m",
                               components: [MaskComponent(id: "c", feather: 0,
                                                          shape: .radialGradient(RadialGradientShape(
                                                            center: NormalizedPoint(0.5, 0.5),
                                                            radius: NormalizedPoint(0.45, 0.45))))],
                               adjustments: LocalAdjustments(whites: whites, blacks: blacks))]
            let img = try XCTUnwrap(graph.render(edit, options: opts).display)
            let o = ((img.height / 2) * img.width + img.width / 2) * 4
            return (Float(img.rgba[o]) + Float(img.rgba[o + 1]) + Float(img.rgba[o + 2])) / 3
        }

        let mid = flat(0.35), toe = flat(0.02), bright = flat(0.98)
        let midBase = try probe(mid), toeBase = try probe(toe), brightBase = try probe(bright)
        let midUp = try probe(mid, blacks: 100), midDown = try probe(mid, blacks: -100)
        let toeUp = try probe(toe, blacks: 100), toeDown = try probe(toe, blacks: -100)
        let whiteUp = try probe(bright, whites: 100), whiteDown = try probe(bright, whites: -100)
        print("079 局部 blacks/whites: mid 0.35 → +\(midUp) −\(midDown) (neutral \(midBase)); "
              + "toe 0.02 → +\(toeUp) −\(toeDown) (neutral \(toeBase)); "
              + "white 0.98 → +\(whiteUp) −\(whiteDown) (neutral \(brightBase))")

        // 073B: the knee ends at −4.2 EV and 0.35 is −1.5 EV, so a mid-tone is outside it — exactly.
        XCTAssertEqual(midUp, midBase, accuracy: 1e-6, "blacks + must not move a mid-tone")
        XCTAssertEqual(midDown, midBase, accuracy: 1e-6, "blacks − must not move a mid-tone")
        // The toe is what the slider names: + opens it, − crushes it.
        XCTAssertGreaterThan(toeUp, toeBase, "local blacks + must open the toe")
        XCTAssertLessThan(toeDown, toeBase, "local blacks − must crush the toe")
        // Whites is the other end (派单 008 A's direction, unchanged by 073B).
        XCTAssertGreaterThan(whiteUp, brightBase, "local whites + must brighten")
        XCTAssertLessThan(whiteDown, brightBase, "local whites − must darken")
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

    // MARK: - E. 074 R2 — the region weights are EV windows, not linear-luma thresholds

    /// The four reference frames of the contract, decoded at 1/16 (`scale: 0.0625`) — big enough for
    /// percentiles, small enough for eight renders per frame inside a test.
    private static let frames = ["L1030402", "L1030405", "L1030408", "L1030433"]
    private static let percentileList = [1, 5, 20, 30, 50, 70, 90, 95, 99]

    private struct Measured {
        let name: String
        /// Display code 0…255 at p1…p99.
        let code: [Double]
        /// Scene-linear luma at the same percentiles, in EV relative to display white.
        let ev: [Double]
    }

    private func measure() throws -> [Measured] {
        var out: [Measured] = []
        for name in Self.frames {
            let path = NSString(string: "~/Desktop/test/\(name).dng").expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let img = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(decoderVersion: nil, scale: 0.0625))
            var lumas: [Double] = []
            lumas.reserveCapacity(img.width * img.height)
            for i in stride(from: 0, to: img.rgba.count, by: 4) {
                lumas.append(0.2126 * Double(img.rgba[i]) + 0.7152 * Double(img.rgba[i + 1])
                             + 0.0722 * Double(img.rgba[i + 2]))
            }
            let sorted = lumas.sorted()
            var ev: [Double] = []
            var code: [Double] = []
            for p in Self.percentileList {
                let v = sorted[min(sorted.count - 1, Int(Double(p) / 100 * Double(sorted.count - 1)))]
                ev.append(log2(max(v, 1e-12)))
                code.append(Self.code(v))
            }
            out.append(Measured(name: name, code: code, ev: ev))
        }
        if out.isEmpty { throw XCTSkip("no RAW fixtures for the 074 audit") }
        return out
    }

    static func code(_ v: Double) -> Double {
        let x = max(v, 0)
        return (x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055) * 255
    }

    /// The **pre-074** region weights, as a CPU mirror: `1 − smoothstep(0, 0.5, lum)` and
    /// `smoothstep(0.5, 1, lum)` on linear luminance, ±0.8 EV. It exists to reproduce the pinned
    /// "before" column below — the numbers the owner reported ("shadows +100 moves the median +24")
    /// — so the comparison in this file is between two *measured* maps and not between a map and a
    /// quotation.
    private func oldLift(_ v: Double, shadows: Double, highlights: Double) -> Double {
        func smoothstep(_ x: Double) -> Double {
            let t = min(max(x, 0), 1)
            return t * t * (3 - 2 * t)
        }
        let lum = max(v, 0)
        let ws = 1 - smoothstep(lum / 0.5)
        let wh = smoothstep((lum - 0.5) / 0.5)
        return v * pow(2, shadows / 100 * 0.8 * ws) * pow(2, highlights / 100 * 0.8 * wh)
    }

    /// Pinned pre-074 measurements (commit 592d3cc, same fixtures, same statistic):
    /// `shadows = +100` median and p90 in 8-bit codes.
    private static let pinnedOldShadowMedian = ["L1030402": 24.0, "L1030405": 22.0,
                                                "L1030408": 19.0, "L1030433": 24.0]
    private static let pinnedOldShadowP90 = ["L1030402": 15.0, "L1030405": 23.0,
                                             "L1030408": 24.0, "L1030433": 12.0]

    /// The mirror must still reproduce those numbers (within one code — it works on scene-linear luma,
    /// the pipeline on the whole chain), so "before" in this file is a measurement, not a memory.
    func testTheOldRegionWeightsStillReproduceTheReportedMedianShift() throws {
        for f in try measure() {
            let codeOld = f.ev.map { Self.code(oldLift(pow(2, $0), shadows: 100, highlights: 0)) }
            let median = codeOld[4] - f.code[4]
            let p90 = codeOld[6] - f.code[6]
            print(String(format: "074 before (mirror) %@: shadows +100 Δmedian %+.0f (pinned %+.0f), Δp90 %+.0f (pinned %+.0f)",
                         f.name as NSString, median, Self.pinnedOldShadowMedian[f.name] ?? .nan,
                         p90, Self.pinnedOldShadowP90[f.name] ?? .nan))
            XCTAssertEqual(median, Self.pinnedOldShadowMedian[f.name] ?? .nan, accuracy: 1.5,
                           "\(f.name): the pre-074 mirror no longer reproduces the reported shift")
            XCTAssertEqual(p90, Self.pinnedOldShadowP90[f.name] ?? .nan, accuracy: 1.5,
                           "\(f.name): the pre-074 mirror no longer reproduces the reported p90")
            // And the headline: the old shadows slider was a global gain — the median moved as much as
            // the shadows did.
            XCTAssertGreaterThan(median, 15, "\(f.name): the pinned 'before' median must be the big one")
        }
    }

    /// **085 — 分档：each of the three lifts moves its own band, in the LR direction.**
    ///
    /// The numbers are printed for all four reference frames; the assertions are the *relations* the
    /// design promises (a lift must reach its own band much harder than the other two), not a replay
    /// of one machine's percentile table. `+100` is used for every zone so the sign convention is
    /// visible in one place.
    func testEachZoneMovesItsOwnBand() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let frames = try measure()
        for f in frames {
            let path = NSString(string: "~/Desktop/test/\(f.name).dng").expandingTildeInPath
            let img = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                              options: DecodeOptions(decoderVersion: nil, scale: 0.0625))
            let graph = try RenderGraph(input: RenderInput(image: img, identity: f.name))
            let opts = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                     useCache: false, wantsPixels: true)
            func codes(shadows: Double = 0, midtones: Double = 0,
                       highlights: Double = 0) throws -> [Double] {
                var edit = EditModel.neutral
                edit.light.shadows = shadows
                edit.light.midtones = midtones
                edit.light.highlights = highlights
                let r = try graph.render(edit, options: opts)
                defer { if let t = r.output { graph.recycle(output: t) } }
                let d = try XCTUnwrap(r.display)
                return stride(from: 0, to: d.rgba.count, by: 4).map { Double(d.rgba[$0]) * 255 }
            }
            let base = try codes()
            let shadow = try codes(shadows: 100)
            let mid = try codes(midtones: 100)
            let high = try codes(highlights: 100)
            let shadowDown = try codes(shadows: -100)
            let midDown = try codes(midtones: -100)
            let highDown = try codes(highlights: -100)
            let q0 = Self.percentiles(base)
            let dS = zip(Self.percentiles(shadow), q0).map { $0 - $1 }
            let dM = zip(Self.percentiles(mid), q0).map { $0 - $1 }
            let dH = zip(Self.percentiles(high), q0).map { $0 - $1 }
            let dSn = zip(Self.percentiles(shadowDown), q0).map { $0 - $1 }
            let dMn = zip(Self.percentiles(midDown), q0).map { $0 - $1 }
            let dHn = zip(Self.percentiles(highDown), q0).map { $0 - $1 }
            func table(_ name: String, _ d: [Double]) {
                print("085 \(f.name) \(name): " + zip(Self.percentileList, d).map {
                    String(format: "p%d %+.0f", $0.0, $0.1) }.joined(separator: " "))
            }
            table("shadows +100", dS)
            table("midtones +100", dM)
            table("highlights +100", dH)

            // Shadow: the dark end (p5/p20) moves, the top of the picture (p90) does not.
            XCTAssertGreaterThanOrEqual(dS[1], 6, "\(f.name): shadows +100 must lift p5")
            XCTAssertGreaterThanOrEqual(dS[2], 6, "\(f.name): shadows +100 must lift p20")
            XCTAssertLessThanOrEqual(abs(dS[6]), 1, "\(f.name): shadows +100 moved p90")
            // Mid: p50 is inside the window the old layout left dead; p5 (deep shadow) is not.
            // The window runs to −1 EV, so p70…p90 respond too — that is the band the slider names,
            // and it is why the assertion is "p50 moves and p5 does not", not a code-space ranking.
            XCTAssertGreaterThanOrEqual(dM[4], 3, "\(f.name): midtones +100 must move p50")
            XCTAssertLessThanOrEqual(abs(dM[1]), 1, "\(f.name): midtones +100 moved p5")
            // High: the top tail (p99) moves, the median stays put. p95 is *not* the witness for every
            // frame: `L1030408`'s p95 sits at the bottom of the high window (b ≈ 0.02), so it barely
            // moves while its p99 (+14 codes) is the sample the slider is for.
            XCTAssertGreaterThanOrEqual(dH[8], 6, "\(f.name): highlights +100 must lift p99")
            XCTAssertLessThanOrEqual(abs(dH[4]), 1, "\(f.name): highlights +100 moved the median")
            // …and the mirror: `−` pulls the same band down (LR direction, 派单 008 A).
            XCTAssertLessThanOrEqual(dSn[1], -4, "\(f.name): shadows −100 must darken p5")
            XCTAssertLessThanOrEqual(dMn[4], -3, "\(f.name): midtones −100 must darken p50")
            XCTAssertLessThanOrEqual(dHn[8], -4, "\(f.name): highlights −100 must darken p99")
        }
    }

    private static func percentiles(_ values: [Double]) -> [Double] {
        let s = values.sorted()
        return percentileList.map { p in s[min(s.count - 1, Int(Double(p) / 100 * Double(s.count - 1)))] }
    }

    /// **085 — no dead band.** The red line of this task: at `L = −4.0, −3.6, −3.4 EV` (the old
    /// layout's −3.9…−3.2 EV gap) the three weights still sum to 1 and one of them owns the pixel.
    func testThereIsNoDeadBandBetweenTheZones() {
        for L in [-4.0, -3.6, -3.4] {
            let w = S2Regions.weights(L: L)
            let sum = w.shadow + w.mid + w.high
            print(String(format: "085 weights at L = %+.1f EV: shadow %.3f, mid %.3f, high %.3f (sum %.6f)",
                         L, w.shadow, w.mid, w.high, sum))
            XCTAssertGreaterThan(sum, 0.99, "L = \(L) EV is a dead band")
            XCTAssertGreaterThan(max(w.shadow, max(w.mid, w.high)), 0.5,
                                 "L = \(L) EV has no dominant zone")
        }
        // Full-weight ownership either side of the seam, and the chain sums to 1 through the whole
        // shadow→mid→high run (up to −1.2 EV, where the white closure starts).
        var L = -12.0
        while L <= -1.2 {
            let w = S2Regions.weights(L: L)
            XCTAssertEqual(w.shadow + w.mid + w.high, 1.0, accuracy: 1e-12,
                           "the three windows must partition the range at L = \(L)")
            L += 0.1
        }
    }

    /// **085 — model, key and dirty marker.** The new field decodes leniently (absent = 0), writes
    /// itself out, dirties `.toneMap`, and only enters the material when it has actually moved (the
    /// `asp`/`car`/`q` discipline: an untouched document's key is byte-identical to pre-085).
    func testMidtonesModelKeyAndDirtyMarker() throws {
        var edit = EditModel.neutral
        XCTAssertFalse(edit.keyMaterial(.toneMap).contains(";md="),
                       "an untouched 中间调 must not enter the tone-map material")
        edit.light.midtones = 12
        XCTAssertTrue(edit.keyMaterial(.toneMap).contains(";md=12.00000"))
        XCTAssertEqual(edit.changedStages(from: .neutral), [.toneMap])

        let partial = Data(#"{ "light": { "highlights": 3 } }"#.utf8)
        let decoded = try JSONDecoder().decode(EditModel.self, from: partial)
        XCTAssertEqual(decoded.light.midtones, 0, "a missing midtones key must read as 0")

        let encoded = try JSONEncoder().encode(EditModel.neutral)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let light = try XCTUnwrap(obj["light"] as? [String: Any])
        XCTAssertNotNil(light["midtones"], "085 writes the field, including its default")
    }

    /// Above display white the high window closes: all three weights are 0, so the gain is exactly 1
    /// and an HDR sample passes through bit for bit, for every slider combination.
    func testSamplesAboveWhitePassThrough() throws {
        let harness = try S2KernelHarness()
        let values: [Float] = [1.0, 1.5, 2.0, 4.0, 8.0]   // L = 0 … +3 EV
        let combos: [(Float, Float, Float)] = [(100, 0, 0), (-100, 0, 0),
                                               (0, 100, 0), (0, -100, 0),
                                               (0, 0, 100), (0, 0, -100),
                                               (100, -100, 100), (-100, 100, -100)]
        for (shadows, midtones, highlights) in combos {
            let out = try harness.run(values, highlights: highlights, midtones: midtones,
                                      shadows: shadows)
            for (i, v) in values.enumerated() {
                XCTAssertEqual(out[i].bitPattern, v.bitPattern,
                               "L = \(log2(Double(v))) EV moved with (\(shadows), \(midtones), \(highlights))")
            }
        }
        print("085 above white: bit-identical for all 8 extreme combinations")
    }

    /// **085 — the monotonicity gate.** 3×3×3 slider combinations × `L` from −12 to +2 EV in 0.02
    /// steps: the gain's log2 slope is never below `S2Regions.minSlope`. The gate is what makes this
    /// true (the next test removes it and shows the fold).
    func testTheRegionLiftsAreMonotoneForEveryCombination() {
        let stops: [Double] = [-100, 0, 100]
        var worst = Double.infinity
        var worstAt = (0.0, 0.0, 0.0, 0.0)
        for shadows in stops {
            for midtones in stops {
                for highlights in stops {
                    let d = S2Regions.travelEV(shadows: shadows, midtones: midtones,
                                               highlights: highlights)
                    var L = -12.0
                    while L <= 2.0 {
                        let h = 1e-5
                        let a = S2Regions.weights(L: L - h)
                        let b = S2Regions.weights(L: L + h)
                        let slope = 1 + ((b.shadow - a.shadow) * d.shadow
                                         + (b.mid - a.mid) * d.mid
                                         + (b.high - a.high) * d.high) / (2 * h)
                        if slope < worst {
                            worst = slope
                            worstAt = (L, shadows, midtones, highlights)
                        }
                        L += 0.02
                    }
                }
            }
        }
        print(String(format: "085 gated min slope %+.6f at L = %+.2f EV for (%.0f, %.0f, %.0f)",
                     worst, worstAt.0, worstAt.1, worstAt.2, worstAt.3))
        XCTAssertGreaterThanOrEqual(worst, S2Regions.minSlope - 1e-6,
                                    "the gated map folds at L = \(worstAt.0) EV")
    }

    /// **The refutation**: with the common compression switched off, `shadows = +100` and
    /// `midtones = −100` really do fold — so the green monotonicity test above is bought by the gate,
    /// not by the raw travel numbers.
    func testTheLimiterIsWhatKeepsTheExtremeCombinationMonotone() {
        let saved = S2Regions.limiterDisabled
        defer { S2Regions.limiterDisabled = saved }

        func worstSlope() -> Double {
            let d = S2Regions.travelEV(shadows: 100, midtones: -100, highlights: 0)
            var worst = Double.infinity
            var L = -12.0
            while L <= 2.0 {
                let h = 1e-5
                let a = S2Regions.weights(L: L - h)
                let b = S2Regions.weights(L: L + h)
                let slope = 1 + ((b.shadow - a.shadow) * d.shadow
                                 + (b.mid - a.mid) * d.mid
                                 + (b.high - a.high) * d.high) / (2 * h)
                worst = min(worst, slope)
                L += 0.02
            }
            return worst
        }

        S2Regions.limiterDisabled = true
        let unguarded = worstSlope()
        S2Regions.limiterDisabled = false
        let guarded = worstSlope()
        print(String(format: "085 limiter: unguarded min slope %+.3f, guarded %+.3f", unguarded, guarded))
        XCTAssertLessThan(unguarded, 0.2, "the raw +100/−100 travel must fold — otherwise nothing is gated")
        XCTAssertGreaterThanOrEqual(guarded, S2Regions.minSlope - 1e-6)
    }

    /// 074 R2 also has to hold up **with the other sliders in play**: contrast +22 (0.22 EV of bend
    /// since 0107) must not fold the shadow lift, and the combination must still be monotone. (The
    /// contrast curve itself was 074's R1 and moved to the log2 domain in 0107 —
    /// `ContrastLogDomainTests` — so this only asserts that the region lifts do not make it worse.)
    func testTheRegionLiftsSurviveContrast() throws {
        let harness = try S2KernelHarness()
        var grid: [Float] = []
        var v: Float = 1e-6
        while v <= 4 { grid.append(v); v *= 1.02 }
        for (label, contrast, shadows, highlights) in
            [("contrast +22 & shadows +100", 22.0 as Float, 100.0 as Float, 0.0 as Float),
             ("contrast +22 & highlights −100", 22, 0, -100)] {
            let out = try harness.run(grid, highlights: highlights, shadows: shadows, contrast: contrast)
            var worst = Double.infinity
            for i in 0..<(grid.count - 1) {
                let dy = log2(Double(max(out[i + 1], 1e-30))) - log2(Double(max(out[i], 1e-30)))
                let dx = log2(Double(grid[i + 1])) - log2(Double(grid[i]))
                worst = min(worst, dy / dx)
            }
            print(String(format: "074 combo %@: min slope %+.3f", label as NSString, worst))
            XCTAssertGreaterThan(worst, 0.30, "\(label) folds")
        }
    }
}

// MARK: - the S2 harness: the shipped tone-map kernel, compiled here

private struct S2KernelHarness {
    struct Params {
        var a: SIMD4<Float>   // contrast, travel, pad, pad
        var b: SIMD4<Float>   // dShadow, dMid, dHighlight, identity
        var c: SIMD4<Float>   // contentOrigin.xy, contentSize.xy
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    /// 0107: the entry point that contains the contrast bend. `s2_tone_map` has none of it (it is the
    /// pass every `contrast == 0` document runs), so a test that wants contrast has to ask for this one
    /// — the kernel picks the entry point, exactly as `RenderGraph` does.
    let contrastPipeline: MTLComputePipelineState

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsCore/Kernels/s2_tone_map.metal")
        // Through the same include expander the product uses: `s2_tone_map.metal` asks for
        // `primaries.metal` (the working-space luma weights, 075), and `makeLibrary(source:)` has no
        // include search path of its own.
        let source = try KernelLibrary.expandingLocalIncludes(of: url)
        let library = try device.makeLibrary(source: source, options: nil)
        let fn = try XCTUnwrap(library.makeFunction(name: "s2_tone_map"))
        let cfn = try XCTUnwrap(library.makeFunction(name: "s2_tone_map_contrast"))
        self.device = device
        self.pipeline = try device.makeComputePipelineState(function: fn)
        self.contrastPipeline = try device.makeComputePipelineState(function: cfn)
        guard let q = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        self.queue = q
        XCTAssertEqual(MemoryLayout<Params>.stride, 48, "S2Params' mirror must be as wide as Metal's")
    }

    func run(_ values: [Float], highlights: Float = 0, midtones: Float = 0,
             shadows: Float = 0, contrast: Float = 0) throws -> [Float] {
        let pso = contrast == 0 ? pipeline : contrastPipeline
        let travel = S2Regions.travelEV(shadows: Double(shadows), midtones: Double(midtones),
                                        highlights: Double(highlights))
        let w = values.count, h = 1
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: w,
                                                         height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared
        let src = try XCTUnwrap(device.makeTexture(descriptor: d))
        let dst = try XCTUnwrap(device.makeTexture(descriptor: d))
        var flat = [Float]()
        for v in values { flat += [v, v, v, 1] }
        flat.withUnsafeBytes { buf in
            src.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: buf.baseAddress!, bytesPerRow: w * 16)
        }
        var p = Params(a: SIMD4(contrast, Float(S2Contrast.travelEV), 0, 0),
                       b: SIMD4(Float(travel.shadow), Float(travel.mid), Float(travel.high), 0),
                       c: SIMD4(0, 0, Float(w), Float(h)))
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let enc = try XCTUnwrap(cb.makeComputeCommandEncoder())
        enc.setComputePipelineState(pso)
        enc.setTexture(src, index: 0)
        enc.setTexture(dst, index: 1)
        enc.setBytes(&p, length: MemoryLayout<Params>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: min(pso.maxTotalThreadsPerThreadgroup, 32),
                                                           height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        var out = [Float](repeating: 0, count: w * h * 4)
        out.withUnsafeMutableBytes { buf in
            dst.getBytes(buf.baseAddress!, bytesPerRow: w * 16,
                         from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return stride(from: 0, to: out.count, by: 4).map { out[$0] }
    }
}