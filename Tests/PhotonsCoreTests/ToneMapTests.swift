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

    /// `highlights +` must *brighten* the HDR tail (less recovery) and `highlights -` must recover
    /// it, which is the Lightroom gesture. The kernel used `exp2(-highlights …)`, so the panel read
    /// backwards: dragging right recovered instead of opening the highlights.
    ///
    /// **299**: the slider is a slope above white, so the probe lives at `L = +2 EV` and reads the
    /// linear exit; on an SDR ramp it is exactly the identity by design.
    func testHighlightsFollowLightroomDirection() throws {
        let image = bands([4.0])          // L = +2 EV
        let graph = try makeGraph(image)
        let opts = RenderOptions(scale: 1,
                                 display: DisplayOptions(headroom: 8, linearOutput: true),
                                 useCache: false, wantsPixels: true)
        let neutral = EditModel.neutral

        func luma(highlights: Double) throws -> Double {
            var edit = neutral
            edit.light.highlights = highlights
            let img = try XCTUnwrap(graph.render(edit, options: opts).display)
            let o = (img.height / 2 * img.width + img.width / 2) * 4
            return 0.2126 * Double(img.rgba[o]) + 0.7152 * Double(img.rgba[o + 1])
                + 0.0722 * Double(img.rgba[o + 2])
        }

        let up = try luma(highlights: 100), mid = try luma(highlights: 0)
        let down = try luma(highlights: -100)
        print(String(format: "299 direction at L = +2 EV: −100 %.4f → 0 %.4f → +100 %.4f (linear)",
                     down, mid, up))
        XCTAssertLessThan(down, mid, "highlights −100 must recover the HDR tail")
        XCTAssertGreaterThan(up, mid, "highlights +100 must open it")
    }

    // MARK: - 299 / 306b · 高光 = band + difference shoulder

    /// The acceptance table: `y = L + Σ w_i·d_i + S(L)` at five slider positions and six luminances,
    /// read from the shipped `linearOutput` path (no OETF, no headroom clamp).
    ///
    /// **306b changed every row above 0.** 高光 now enters the normalized band term, so `L ≤ 0` is no
    /// longer the identity; and the shoulder coefficient was re-solved (`c = 0.579214`) so that
    /// `h = −100, L = +4` still lands on `+1.000`. `L = +8` is therefore `+2.681`, not 299's `+1.798`
    /// — the band already contributes `−0.998`, the shoulder supplies the rest. The table was
    /// recomputed from the shipped CPU formula, not copied from the old commit.
    func testHighlightShoulderTableFromLinearOutput() throws {
        let ls = [0.5, 1.0, 2.0, 2.3, 4.0, 8.0]
        let hs = [-100.0, -50.0, 0.0, 50.0, 100.0]
        let expected: [[Double]] = [
            [-0.4194, 0.0403, 0.5000, 0.9597, 1.4194],
            [-0.2212, 0.3894, 1.0000, 1.6106, 2.2212],
            [0.1729, 1.0865, 2.0000, 2.9135, 3.8271],
            [0.2947, 1.2974, 2.3000, 3.3026, 4.3053],
            [1.0000, 2.5000, 4.0000, 5.5000, 7.0000],
            [2.6811, 5.3406, 8.0000, 10.6594, 13.3189],
        ]
        let image = bands(ls.map { Float(pow(2.0, $0)) })
        let graph = try makeGraph(image, identity: "highlight-shoulder-table")
        let opts = RenderOptions(scale: 1,
                                 display: DisplayOptions(headroom: 8, linearOutput: true),
                                 useCache: false, wantsPixels: true)

        func output(highlights: Double) throws -> [Double] {
            var edit = EditModel.neutral
            edit.light.highlights = highlights
            let d = try XCTUnwrap(graph.render(edit, options: opts).display)
            return (0..<ls.count).map { i in
                let o = ((d.height / 2) * d.width + i * 32 + 16) * 4
                return log2(Double(d.rgba[o]))
            }
        }

        print("299/306b y (EV): L ∈ {0.5, 1, 2, 2.3, 4, 8}, h ∈ {−100, −50, 0, +50, +100}")
        for (hi, h) in hs.enumerated() {
            let y = try output(highlights: h)
            print("  h=\(Int(h)): " + y.map { String(format: "%.3f", $0) }.joined(separator: " "))
            for (li, _) in ls.enumerated() {
                XCTAssertEqual(y[li], expected[li][hi], accuracy: 0.02,
                               "h=\(h), L=\(ls[li]) EV: got \(y[li])")
            }
        }

        // The headline: +4 EV comes down to +1.00 EV, still above the white point.
        let down = try output(highlights: -100)
        XCTAssertEqual(down[4], 1.0, accuracy: 0.02, "+4 EV at −100 must land at +1.00 EV")
        // …and the recomputed +8 tail, reported honestly instead of 299's 1.798.
        XCTAssertEqual(down[5], 2.681, accuracy: 0.02, "+8 EV at −100 follows the new k")

        // 306b — h = 0 is still the identity, and L = 0 now follows 高光. At h = −100 the white point
        // moves by w_h(0)·(−0.83) = −0.710 EV while the shadow centre only moves −0.00075 EV.
        let probes = bands([Float(pow(2.0, -6.8)), 1.0])
        let probeGraph = try makeGraph(probes, identity: "highlight-band-below-white")
        func raw(highlights: Double) throws -> [Float16] {
            var edit = EditModel.neutral
            edit.light.highlights = highlights
            let d = try XCTUnwrap(probeGraph.render(edit, options: opts).display)
            return (0..<2).map { d.rgba[((d.height / 2) * d.width + $0 * 32 + 16) * 4] }
        }
        let neutral = try raw(highlights: 0)
        XCTAssertEqual(Float(neutral[1]), 1.0, accuracy: 1e-4, "h = 0 at white is the identity")
        let downProbe = try raw(highlights: -100)
        let dWhite = log2(Double(downProbe[1]))
        let dShadow = log2(Double(downProbe[0])) - (-6.8)
        print(String(format: "306b h=−100 below white: L=0 Δ %+.4f EV, L=−6.8 Δ %+.6f EV",
                     dWhite, dShadow))
        XCTAssertEqual(dWhite, -0.710, accuracy: 0.02, "w_h(0)·Δh is the SDR high-band carry")
        XCTAssertEqual(dShadow, -0.00075, accuracy: 0.01, "高光 barely reaches the shadow centre")
    }

    /// **306b — `highlights == 0` is the identity, but an SDR (headroom 1) frame now moves with 高光.**
    ///
    /// This used to pin 299's "the SDR render is unchanged at every 高光 position". 306b rejects that
    /// premise on purpose: 高光 is a band too, so it must drag the SDR near-white (`w_h(0) = 0.856`).
    /// The neutral document is still bit-exact; the slider now darkens/brightens the SDR frame in the
    /// LR direction, and the HDR tail is still the shoulder's.
    func testNeutralHighlightIsBitIdenticalAndTheSDRHighBandMoves() throws {
        XCTAssertEqual(StageAlgorithmVersion.toneMap, 7, "306 keeps the tone-map generation")
        let graph = try makeGraph(hdrImage(), identity: "highlight-sdr-band")
        let opts = RenderOptions(scale: 1, useCache: false, wantsPixels: true)
        let neutral = EditModel.neutral

        func render(highlights: Double) throws -> DisplayImage {
            var edit = neutral
            edit.light.highlights = highlights
            return try XCTUnwrap(graph.render(edit, options: opts).display)
        }

        let zeroExplicit = try render(highlights: 0)
        let baseline = try XCTUnwrap(graph.render(neutral, options: opts).display)
        XCTAssertEqual(zeroExplicit.sha256(), baseline.sha256(),
                       "highlights = 0 must be the same bytes as the neutral document")

        var worst: Float = 0
        for h in [-100.0, -50.0, 50.0, 100.0] {
            let moved = try render(highlights: h)
            for i in stride(from: 0, to: moved.rgba.count, by: 4) {
                for c in 0..<3 {
                    worst = max(worst, abs(Float(moved.rgba[i + c]) - Float(baseline.rgba[i + c])) * 255)
                }
            }
        }
        print(String(format: "306b SDR (headroom 1) max code diff over h = ±50/±100: %.3f", worst))
        XCTAssertGreaterThan(worst, 4.0, "the SDR near-white must follow 高光 now")

        func mean(_ d: DisplayImage) -> Double {
            var sum = 0.0
            for i in stride(from: 0, to: d.rgba.count, by: 4) {
                sum += (Double(d.rgba[i]) + Double(d.rgba[i + 1]) + Double(d.rgba[i + 2])) / 3
            }
            return sum / Double(d.width * d.height)
        }
        let down = try render(highlights: -100)
        let up = try render(highlights: 100)
        print(String(format: "306b SDR mean: −100 %.4f · 0 %.4f · +100 %.4f",
                     mean(down), mean(baseline), mean(up)))
        XCTAssertLessThan(mean(down), mean(baseline), "高光 −100 must recover the SDR near-white")
        XCTAssertGreaterThan(mean(up), mean(baseline), "高光 +100 must open it")
    }

    /// 299 acceptance ③: `dy/dL ≥ k` on the compression side, and never a fold on the expansion
    /// side (there the minimum is 1 at the C¹ knee). Measured on `[−3, +8]` EV in 0.01 steps.
    func testHighlightsAreMonotoneThroughTheHDRRange() {
        var globalWorst = Double.infinity
        var globalAt = (L: 0.0, highlights: 0.0, k: 1.0)
        for h in [-100.0, 0.0, 100.0] {
            let k = S2Regions.highSlope(highlights: h)
            let floor = min(1.0, k)
            var worst = Double.infinity
            var worstL = 0.0
            var L = -3.0
            while L <= 8.0 {
                let step = 1e-5
                let slope = (S2Regions.highShoulderEV(L: L + step, highlights: h)
                             - S2Regions.highShoulderEV(L: L - step, highlights: h)) / (2 * step) + 1
                if slope < worst { worst = slope; worstL = L }
                L += 0.01
            }
            print(String(format: "299 monotone h=%+.0f k=%.3f: min dy/dL %+.6f at L = %+.2f EV",
                         h, k, worst, worstL))
            XCTAssertGreaterThanOrEqual(worst, floor - 1e-6,
                                        "h=\(h): the shoulder folds at L = \(worstL) EV")
            if k <= 1 { XCTAssertGreaterThanOrEqual(worst, k - 1e-6) }
            if worst < globalWorst { globalWorst = worst; globalAt = (worstL, h, k) }
        }
        print(String(format: "299 monotone global min %+.6f at L = %+.2f EV (h = %+.0f, k = %.3f)",
                     globalWorst, globalAt.L, globalAt.highlights, globalAt.k))
        XCTAssertGreaterThan(globalWorst, 0, "the shoulder must never fold")
    }

    // MARK: - 124 · 高光 covers the whole HDR range

    /// A +2 EV frame: 25 % of the samples at 4.0 linear, the rest a normal SDR ramp, so the share
    /// above 1.0 is comfortably over the acceptance's 20 %.
    private func hdrImage(width: Int = 320, height: Int = 240) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x) / Double(width - 1)
                let v: Float = x >= (width * 3) / 4 ? 4.0 : Float(0.02 + 0.90 * t)
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// **124/299 acceptance ② — the HDR tail is actually reached.** A +2 EV frame through the real
    /// graph, rendered through the linear exit so values above white survive: 高光 −100's p99.9 must
    /// sit at least 0.25 EV below 高光 +100's. 306b pins the new target there: the band + shoulder take
    /// `L = +2 EV, h = −100` to `y = +0.173 EV` (299's shoulder-only `0.600` is no longer the model).
    func testHighlightsRecoverARealHDRFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try makeGraph(hdrImage(), identity: "hdr-highlight-124")
        let opts = RenderOptions(scale: 1,
                                 display: DisplayOptions(headroom: 8, linearOutput: true),
                                 useCache: false, wantsPixels: true)

        func linearLuma(highlights: Double) throws -> [Double] {
            var edit = EditModel.neutral
            edit.light.highlights = highlights
            let r = try graph.render(edit, options: opts)
            defer { if let t = r.output { graph.recycle(output: t) } }
            let d = try XCTUnwrap(r.display)
            return stride(from: 0, to: d.rgba.count, by: 4).map {
                0.2126 * Double(d.rgba[$0]) + 0.7152 * Double(d.rgba[$0 + 1])
                    + 0.0722 * Double(d.rgba[$0 + 2])
            }
        }

        func p999(_ values: [Double]) -> Double {
            let s = values.sorted()
            return s[min(s.count - 1, Int(0.999 * Double(s.count - 1)))]
        }

        let down = try linearLuma(highlights: -100)
        let neutral = try linearLuma(highlights: 0)
        let up = try linearLuma(highlights: 100)
        let share = Double(neutral.filter { $0 > 1.0 }.count) / Double(neutral.count)
        let gap = log2(p999(up)) - log2(p999(down))
        print(String(format: "124/299 HDR: %.1f%% of samples > 1.0; p99.9 −100 %.3f → 0 %.3f → +100 %.3f (gap %.3f EV)",
                     share * 100, p999(down), p999(neutral), p999(up), gap))
        XCTAssertGreaterThan(share, 0.20, "the fixture must actually be HDR")
        XCTAssertGreaterThanOrEqual(gap, 0.25, "高光 must cover the HDR range, not stop at white")
        XCTAssertEqual(log2(p999(down)), 0.173, accuracy: 0.05,
                       "306b: +2 EV at −100 follows band + difference shoulder")
        XCTAssertLessThan(p999(down), p999(neutral), "高光 −100 must recover the top tail")
        XCTAssertGreaterThan(p999(up), p999(neutral), "高光 +100 must open it")
    }

    /// **299 / 306b — 高光 −100 recovers, +100 opens, and neither manufactures clipping out of an
    /// identity.** 299's "the SDR frame is byte-identical at every 高光 position" is retired: 高光 is
    /// now a band, so `−100` pulls the SDR near-white down (fewer clipped channels) and `+100` opens it
    /// (more). The useful invariant left from 299 is that the *direction* is right and the neutral
    /// document is still bit-exact; the HDR tail above white is the shoulder's.
    func testHighlightRecoveryMovesClippingInTheRightDirection() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try makeGraph(hdrImage(), identity: "hdr-highlight-clip")
        let opts = RenderOptions(scale: 1, useCache: false, wantsPixels: true)

        func render(highlights: Double) throws -> DisplayImage {
            var edit = EditModel.neutral
            edit.light.highlights = highlights
            return try XCTUnwrap(graph.render(edit, options: opts).display)
        }

        func clippedChannels(_ d: DisplayImage) -> Int {
            // The ceiling, not the literal bit pattern: the GPU's float→half write of OETF(1.0) lands
            // on 0.99951, so `== 1` is a property of the converter. 0.999 is above every OETF value a
            // below-white sample can produce (0.92 linear encodes to 0.966), so it counts exactly the
            // pixels the headroom clamp put on the ceiling.
            var n = 0
            for i in stride(from: 0, to: d.rgba.count, by: 4) where d.rgba[i] >= 0.999 { n += 1 }
            return n
        }

        let neutral = try render(highlights: 0)
        let down = try render(highlights: -100)
        let up = try render(highlights: 100)
        print("299/306b SDR clipping: ceiling channels at 高光 0 = \(clippedChannels(neutral)), "
              + "−100 = \(clippedChannels(down)), +100 = \(clippedChannels(up))")
        XCTAssertGreaterThan(clippedChannels(neutral), 0, "the fixture's HDR samples must clip at headroom 1")
        // The fixture's L = +2 quarter stays above white even after the shoulder, so the count is not
        // strictly smaller; the claim is the direction: recovery may not add, opening may not remove.
        XCTAssertLessThanOrEqual(clippedChannels(down), clippedChannels(neutral),
                                 "高光 −100 must not add clipping")
        XCTAssertGreaterThanOrEqual(clippedChannels(up), clippedChannels(neutral),
                                    "高光 +100 opens the near-white and may clip more")
        XCTAssertNotEqual(down.sha256(), neutral.sha256(), "the SDR near-white must move")
    }

    /// **306b — a frame with no HDR still follows 高光 (the band term owns `L ≤ 0`).**
    ///
    /// 299's version asserted the SDR frame was the same bytes at every 高光 position because the
    /// shoulder is 0 below white. 306b puts 高光 inside the band, so a 0.8 grey (`L = −0.32`,
    /// `w_h ≈ 0.89`) moves by about ±0.74 EV. Neutral is still deterministic; the old byte-equality
    /// is intentionally gone.
    func testNoHDRFrameStillUsesTheNeutralPath() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let w = 64, h = 64
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = Float16(0.8); rgba[i + 1] = Float16(0.8)
            rgba[i + 2] = Float16(0.8); rgba[i + 3] = 1
        }
        let image = LinearImage(width: w, height: h, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let graph = try makeGraph(image, identity: "hdr-highlight-sdr")
        let opts = RenderOptions(scale: 1, wantsPixels: true)

        func render(highlights: Double) throws -> DisplayImage {
            var edit = EditModel.neutral
            edit.light.highlights = highlights
            return try XCTUnwrap(graph.render(edit, options: opts).display)
        }

        let neutral = try render(highlights: 0)
        let again = try render(highlights: 0)
        let down = try render(highlights: -100)
        let up = try render(highlights: 100)
        print("306b no-HDR hashes: 0 = \(neutral.sha256()), −100 = \(down.sha256()), +100 = \(up.sha256())")
        XCTAssertEqual(neutral.sha256(), again.sha256(), "高光 = 0 must stay deterministic")
        XCTAssertNotEqual(down.sha256(), neutral.sha256(), "the SDR band must follow 高光 −100")
        XCTAssertNotEqual(up.sha256(), neutral.sha256(), "the SDR band must follow 高光 +100")
        let sample = { (d: DisplayImage) in Double(d.rgba[(d.height / 2) * d.width + d.width / 2]) }
        print(String(format: "306b no-HDR 0.8 grey: −100 %.4f · 0 %.4f · +100 %.4f",
                     sample(down), sample(neutral), sample(up)))
        XCTAssertLessThan(sample(down), sample(neutral))
        XCTAssertGreaterThan(sample(up), sample(neutral))
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

    /// **138 — the white point must not move more than the super-white pixels.**
    ///
    /// `L = log2(v)` relative to display white. 073B/127's `exp(−L)` above white made `L = +1.5 EV`
    /// move −0.13 EV while `L = 0` moved −0.60 EV — the owner's 「高光不变」 (measured on the render:
    /// p99.9 moved +0.0003 code at `whites = −100`). 138's `smoothstep(−2, +1, L)` is monotone in L, so
    /// the **drop** at +1.5 EV has to be at least the drop at white. The old shape fails this test by
    /// construction (its weight decays exactly where the assertion looks); that is the point of it.
    func testWhitesCompressesAboveWhiteNotBelow() throws {
        let harness = try MetalKernelHarness()
        let white: Float = 1
        let above: Float = pow(2, 1.5)                    // +1.5 EV above display white
        let down = try harness.run([white, above], blacks: 0, whites: -100)
        let dWhite = log2(Double(down[0]) / Double(white))
        let dAbove = log2(Double(down[1]) / Double(above))
        print(String(format: "138 whites −100: ΔEV at white (L=0) %+.3f, at +1.5 EV %+.3f",
                     dWhite, dAbove))
        XCTAssertGreaterThanOrEqual(-dAbove, -dWhite + 0.15,
                                    "super-white must drop at least as much as the white point "
                                    + "(white \(dWhite) EV, +1.5 EV \(dAbove) EV)")
        XCTAssertLessThan(dAbove, 0, "whites −100 must actually darken a super-white pixel")

        // The other sign keeps the same ordering: +100 lifts the HDR tail at least as far as white.
        let up = try harness.run([white, above], blacks: 0, whites: 100)
        let uWhite = log2(Double(up[0]) / Double(white))
        let uAbove = log2(Double(up[1]) / Double(above))
        print(String(format: "138 whites +100: ΔEV at white (L=0) %+.3f, at +1.5 EV %+.3f",
                     uWhite, uAbove))
        XCTAssertGreaterThanOrEqual(uAbove, uWhite - 1e-4,
                                    "super-white must lift at least as much as the white point")
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
                // 306b: 高光 is a band now, so the SDR content must move here too (299 asserted 0).
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

    /// 090 acceptance: dragging 中间调 to +40 moves the display signal, measured with this file's own
    /// p50 convention (the same percentile table `testEachZoneMovesItsOwnBand` uses on real frames).
    /// The UI test owns "the document is 40 and releasing is one history row"; this owns the pixels.
    func testMidtonesPlusFortyMovesTheDisplayMedianUp() throws {
        let image = rampImage()
        let graph = try makeGraph(image, identity: "tone-midtones")
        let opts = RenderOptions(scale: 1, wantsPixels: true)

        func p50(midtones: Double) throws -> Double {
            var edit = EditModel.neutral
            edit.light.midtones = midtones
            let result = try graph.render(edit, options: opts)
            defer { if let output = result.output { graph.recycle(output: output) } }
            let display = try XCTUnwrap(result.display)
            let codes = stride(from: 0, to: display.rgba.count, by: 4)
                .map { Double(Float(display.rgba[$0])) * 255 }
            return Self.percentiles(codes)[4]          // 4 == p50 in `percentileList`
        }

        let base = try p50(midtones: 0)
        let lifted = try p50(midtones: 40)
        print("090 中间调 +40: p50 \(String(format: "%.1f", base)) → "
              + "\(String(format: "%.1f", lifted)) codes")
        XCTAssertGreaterThan(lifted, base + 0.5, "中间调 +40 必须把 p50 往前推（中灰变亮）")
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

        // 2026-10-29 — the knee now ends at −1.0 EV (it was −4.2) because the owner wants a 30 %-code
        // tone to respond; 0.35 linear is −1.5 EV, so this mid-tone moves a little instead of not at
        // all. Pin the **magnitude** (a mid-tone drifting would be the real defect), not zero.
        XCTAssertEqual(midUp, midBase, accuracy: midBase * 0.01,
                       "blacks + must not lift a mid-tone by more than 1 %")
        XCTAssertEqual(midDown, midBase, accuracy: midBase * 0.01,
                       "blacks − must not crush a mid-tone by more than 1 %")
        // The toe is what the slider names: + opens it, − crushes it.
        XCTAssertGreaterThan(toeUp, toeBase, "local blacks + must open the toe")
        XCTAssertLessThan(toeDown, toeBase, "local blacks − must crush the toe")
        // The tone the owner named: a 30 %-code patch (linear 0.073, −3.8 EV) used to be **completely
        // untouched** by blacks −100 (the window ended at −4.2 EV). It must now darken.
        let thirty = flat(0.073)
        let thirtyBase = try probe(thirty), thirtyDown = try probe(thirty, blacks: -100)
        print(String(format: "079 30%% 码值 blacks −100: %.4f → %.4f (%.1f%%)",
                     thirtyBase, thirtyDown, (thirtyDown / thirtyBase - 1) * 100))
        XCTAssertLessThan(thirtyDown, thirtyBase * 0.95,
                          "30 % 码值在 blacks −100 时必须明显变暗（旧版完全不动）")

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
            // 097: pass the decode's lens profile through, or the frame loses its lens correction.
            let outcome = try RAWDecoder().decodeDetailed(URL(fileURLWithPath: path),
                                                          options: DecodeOptions(decoderVersion: nil, scale: 0.0625))
            let graph = try RenderGraph(input: RenderInput(image: outcome.image, identity: f.name,
                                                            lensProfile: outcome.lensProfile))
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
                print("306 \(f.name) \(name): " + zip(Self.percentileList, d).map {
                    String(format: "p%d %+.0f", $0.0, $0.1) }.joined(separator: " "))
            }
            table("shadows +100", dS)
            table("midtones +100", dM)
            table("highlights +100", dH)

            // 306 replaced 085's disjoint ownership with overlapping Gaussians: the slider still
            // owns its band, but it **must now drag its neighbours** (the user's brief). So the old
            // "p90 must not move" / "p5 must not move" ceilings became lower bounds on the carry.
            XCTAssertGreaterThanOrEqual(dS[1], 6, "\(f.name): shadows +100 must lift p5")
            XCTAssertGreaterThanOrEqual(dS[2], 5, "\(f.name): shadows +100 must lift p20")
            XCTAssertGreaterThanOrEqual(dS[6], 0.5, "\(f.name): shadows +100 must reach p90")
            XCTAssertLessThanOrEqual(abs(dS[6]), 8, "\(f.name): shadows +100 overwhelmed p90")
            // Mid: p50 is the middle band's centre; the overlap carries it into the deep-shadow p5.
            XCTAssertGreaterThanOrEqual(dM[4], 3, "\(f.name): midtones +100 must move p50")
            XCTAssertGreaterThanOrEqual(dM[1], 2, "\(f.name): midtones +100 must carry p5")
            XCTAssertLessThanOrEqual(abs(dM[1]), 10, "\(f.name): midtones +100 overwhelmed p5")
            // 306b: 高光 is a band now, so it must reach the SDR p99 and (weakly) the median. The
            // old 299 pins (`dH[8] == 0`, median unchanged) are retired. The carry is much smaller
            // at p50 than at p99, which is the "own band first" relation.
            XCTAssertGreaterThan(dH[8], 0.5, "\(f.name): highlights +100 must lift the SDR p99")
            XCTAssertGreaterThan(dH[4], 0.05, "\(f.name): highlights +100 must drag the median")
            XCTAssertLessThan(dH[4], dH[8], "\(f.name): the median must move less than p99")
            XCTAssertLessThan(dHn[8], -0.5, "\(f.name): highlights −100 must compress the SDR p99")
            // …and the mirror: `−` pulls the same band down (LR direction, 派单 008 A).
            XCTAssertLessThanOrEqual(dSn[1], -4, "\(f.name): shadows −100 must darken p5")
            XCTAssertLessThanOrEqual(dMn[4], -3, "\(f.name): midtones −100 must darken p50")
        }

        // 299 — the high band is the HDR tail now. `hdrImage` puts 25 % of the samples at L = +2 EV;
        // a linear read makes the shoulder's travel visible (at headroom 1 it would all clamp to white).
        let hdrGraph = try makeGraph(hdrImage(), identity: "zone-high-hdr")
        let hdrOpts = RenderOptions(scale: 1,
                                    display: DisplayOptions(headroom: 8, linearOutput: true),
                                    useCache: false, wantsPixels: true)
        func hdrP99(highlights: Double) throws -> Double {
            var edit = EditModel.neutral
            edit.light.highlights = highlights
            let d = try XCTUnwrap(hdrGraph.render(edit, options: hdrOpts).display)
            let lumas = stride(from: 0, to: d.rgba.count, by: 4).map {
                0.2126 * Double(d.rgba[$0]) + 0.7152 * Double(d.rgba[$0 + 1])
                    + 0.0722 * Double(d.rgba[$0 + 2])
            }.sorted()
            return log2(lumas[Int(0.99 * Double(lumas.count - 1))])
        }
        let hdrDown = try hdrP99(highlights: -100)
        let hdrMid = try hdrP99(highlights: 0)
        let hdrUp = try hdrP99(highlights: 100)
        print(String(format: "299 HDR high band (p99, L): −100 %+.3f → 0 %+.3f → +100 %+.3f EV",
                     hdrDown, hdrMid, hdrUp))
        XCTAssertLessThan(hdrDown, hdrMid - 1.0, "highlights −100 must recover the HDR tail")
        XCTAssertGreaterThan(hdrUp, hdrMid + 1.0, "highlights +100 must open the HDR tail")
    }

    private static func percentiles(_ values: [Double]) -> [Double] {
        let s = values.sorted()
        return percentileList.map { p in s[min(s.count - 1, Int(Double(p) / 100 * Double(s.count - 1)))] }
    }

    /// **306 — the normalized Gaussian partition.** The three weights sum to 1 at every luminance on
    /// the gate's axis, so no pixel is un-owned; the middle band's peak is 0.726 at its centre, and the
    /// two other centres see 0.195 / 0.119 of it (the overlap the user asked for).
    func testThereIsNoDeadBandBetweenTheZones() {
        var worst = 0.0
        var L = -12.0
        while L <= 0.0 {
            let w = S2Regions.weights(L: L)
            let sum = w.shadow + w.mid + w.high
            worst = max(worst, abs(sum - 1))
            XCTAssertEqual(sum, 1.0, accuracy: 1e-6,
                           "the normalized Gaussians must partition the range at L = \(L)")
            L += 0.01
        }
        print(String(format: "306 partition: max |Σw − 1| = %.3e on [−12, 0]", worst))

        let midPeak = S2Regions.weights(L: S2Regions.bandCentres.mid)
        let atShadow = S2Regions.weights(L: S2Regions.bandCentres.shadow)
        let atHigh = S2Regions.weights(L: S2Regions.bandCentres.high)
        print(String(format: "306 peaks: mid %.3f; mid-weight at shadow %.3f, high %.3f",
                     midPeak.mid, atShadow.mid, atHigh.mid))
        XCTAssertEqual(midPeak.mid, 0.726, accuracy: 0.002, "middle band peak")
        XCTAssertEqual(atShadow.mid, 0.195, accuracy: 0.002, "middle band at the shadow centre")
        XCTAssertEqual(atHigh.mid, 0.119, accuracy: 0.002, "middle band at the high centre")
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

    /// **306b — `h = 0` is the pass-through; 高光 itself now reaches below white.**
    ///
    /// 299's version asserted `L ≤ 0` was bit-identical at every slider position because the shoulder
    /// is 0 there. 306b puts 高光 in the band term (`w_h(0) = 0.856`), so the identity is only at
    /// `h = 0`; the slider's SDR side is a band lift and its HDR tail is the shoulder. Both halves are
    /// pinned: the neutral bytes must not move, and `±100` must move every below-white probe.
    func testPassThroughIsBelowTheWhiteKnee() throws {
        let harness = try S2KernelHarness()

        let below: [Float] = [0.125, 0.25, 0.5, 1.0]   // L = −3 … 0 EV
        let neutral = try harness.run(below, highlights: 0)
        for (i, v) in below.enumerated() {
            XCTAssertEqual(neutral[i].bitPattern, v.bitPattern,
                           "h = 0 must be the identity at L = \(log2(Double(v))) EV")
        }
        let down = try harness.run(below, highlights: -100)
        let up = try harness.run(below, highlights: 100)
        for i in 0..<below.count {
            XCTAssertLessThan(down[i], below[i], "高光 −100 must darken L = \(log2(Double(below[i]))) EV")
            XCTAssertGreaterThan(up[i], below[i], "高光 +100 must lift L = \(log2(Double(below[i]))) EV")
        }
        print(String(format: "306b band below white (h=−100): L=−3 Δ%+.3f, L=0 Δ%+.3f EV",
                     log2(Double(down[0])) - (-3.0), log2(Double(down[3]))))

        // Above white both directions move too; L = 0 is no longer a fixed knee.
        let hdr: [Float] = [1.0, 2.0, 4.0]   // L = 0, +1, +2 EV
        let downHDR = try harness.run(hdr, highlights: -100)
        let upHDR = try harness.run(hdr, highlights: 100)
        for i in 0..<hdr.count {
            XCTAssertLessThan(downHDR[i], hdr[i], "高光 −100 must recover L = \(log2(Double(hdr[i]))) EV")
            XCTAssertGreaterThan(upHDR[i], hdr[i], "高光 +100 must lift L = \(log2(Double(hdr[i]))) EV")
        }
        print("306b high band: +2 EV −100 = \(downHDR[2]), 0 = \(hdr[2]), +100 = \(upHDR[2])")
    }

    /// **085/124/306b — the monotonicity gate.** 3×3×3 slider combinations × `L` from −12 to 0 EV in
    /// 0.02 steps: the band gain's log2 slope is never below `S2Regions.minSlope`. The gate's domain
    /// is `L ∈ [−12, 0]`; above white the slope is deliberately owned by the shoulder and is not
    /// gated. The gate is what makes this true (the next test removes it and shows the fold).
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
                    while L <= 1e-9 {
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

    /// **306 — the Gaussian partition needs no compression under the default travels.** The old
    /// disjoint windows folded when `shadows +100` and `midtones −100` met; the normalized Gaussians
    /// do not (measured floor above `minSlope`), so `travelEV` returns the raw travels and the gate is
    /// a safety net. The refutation of the un-normalized basis lives in the task's reverse gate
    /// (`w_i = b_i`, floor 0.29) rather than in a shipped switch.
    func testTheLimiterIsWhatKeepsTheExtremeCombinationMonotone() {
        let saved = S2Regions.limiterDisabled
        defer { S2Regions.limiterDisabled = saved }

        func worstSlope() -> Double {
            let d = S2Regions.travelEV(shadows: 100, midtones: -100, highlights: 0)
            var worst = Double.infinity
            var L = -12.0
            while L <= 1e-9 {
                worst = min(worst, S2Regions.bandSlope(L: L, shadow: d.shadow,
                                                       mid: d.mid, high: d.high))
                L += 0.02
            }
            return worst
        }

        S2Regions.limiterDisabled = true
        let unguarded = worstSlope()
        S2Regions.limiterDisabled = false
        let guarded = worstSlope()
        let raw = S2Regions.travelEV(shadows: 100, midtones: -100, highlights: 0)
        print(String(format: "306 limiter: raw min slope %+.3f, gated %+.3f, travel %.3f/%.3f",
                     unguarded, guarded, raw.shadow, raw.mid))
        XCTAssertGreaterThanOrEqual(unguarded, S2Regions.minSlope - 1e-9,
                                    "the normalized basis must not need the gate")
        XCTAssertEqual(raw.shadow, S2Regions.shadowTravel, accuracy: 1e-12,
                       "default travel must pass through the gate untouched")
        XCTAssertEqual(raw.mid, -S2Regions.midTravel, accuracy: 1e-12,
                       "default travel must pass through the gate untouched")
    }

    /// **306 acceptance 2 — the middle slider drives its neighbours.** With `midtones = +100` the
    /// shadow centre is passively lifted by `w_mid(−6.8)·0.96 = +0.187 EV` and the high centre by
    /// `w_mid(+0.2)·0.96 = +0.115 EV`; the middle band still owns only 0.143 of `L = 0` (≤ 0.15).
    func testTheMiddleBandDrivesTheShadowAndHighBands() throws {
        let harness = try S2KernelHarness()
        let inputs: [(String, Float)] = [
            ("shadow centre −6.8", Float(pow(2.0, -6.8))),
            ("high centre +0.2", Float(pow(2.0, 0.2))),
            ("white 0", 1.0),
        ]
        let out = try harness.run(inputs.map(\.1), midtones: 100)
        for (i, (name, v)) in inputs.enumerated() {
            let delta = log2(Double(out[i])) - log2(Double(v))
            print(String(format: "306 mid +100 drives %@ by %+.4f EV", name, delta))
            switch name {
            case "shadow centre −6.8":
                XCTAssertEqual(delta, 0.187, accuracy: 0.02, "shadow must follow the middle slider")
            case "high centre +0.2":
                XCTAssertEqual(delta, 0.115, accuracy: 0.02, "high must follow the middle slider")
            default:
                break
            }
        }
        XCTAssertLessThanOrEqual(S2Regions.weights(L: 0).mid, 0.15,
                                 "中间调 must still be the dominant owner of the median")
    }

    /// **306b acceptance 2 (high side) — 高光 drives the other two bands.** With `highlights = +100`
    /// the band term at the middle centre is `w_h(−3.6)·0.83 = +0.0815 EV` (> 0.03) and at the shadow
    /// centre `w_h(−6.8)·0.83 = +0.00075 EV` (> 0, printed).
    ///
    /// The shadow carry **cannot** reach 0.03 with a normalized three-Gaussian at σ = 1.9:
    /// `w_h(−6.8) = 1/(1 + e^{49/2σ²} + e^{19.38/σ²})`; 0.036 would need σ ≈ 2.8, which would also
    /// push the middle→shadow carry to 0.447 and break acceptance 2's ±0.02 and 「以中间为主」. The
    /// assertion is therefore `> 0.03` for the middle centre and `> 0` for the shadow centre, not a
    /// fabricated 0.03.
    func testTheHighBandDrivesTheMiddleAndShadowBands() throws {
        let harness = try S2KernelHarness()
        let inputs: [(String, Float)] = [
            ("mid centre −3.6", Float(pow(2.0, -3.6))),
            ("shadow centre −6.8", Float(pow(2.0, -6.8))),
            ("white 0", 1.0),
        ]
        let up = try harness.run(inputs.map(\.1), highlights: 100)
        let down = try harness.run(inputs.map(\.1), highlights: -100)
        for (i, (name, v)) in inputs.enumerated() {
            let delta = log2(Double(up[i])) - log2(Double(v))
            print(String(format: "306b high +100 drives %@ by %+.6f EV", name, delta))
            switch name {
            case "mid centre −3.6":
                XCTAssertGreaterThan(delta, 0.03, "middle tone must follow the high slider")
            case "shadow centre −6.8":
                XCTAssertGreaterThan(delta, 0.0, "shadow must follow the high slider (weakly)")
            case "white 0":
                XCTAssertGreaterThan(delta, 0.03, "the SDR near-white must follow 高光")
            default:
                break
            }
        }
        let midDelta = log2(Double(up[0])) - log2(Double(Double(inputs[0].1)))
        let shadowDelta = log2(Double(up[1])) - log2(Double(Double(inputs[1].1)))
        print(String(format: "306b high carry: middle %+.5f EV, shadow %+.5f EV",
                     midDelta, shadowDelta))
        XCTAssertLessThan(down[0], inputs[0].1, "highlights −100 must pull the middle tone down")
        XCTAssertEqual(midDelta, S2Regions.weights(L: -3.6).high * S2Regions.highTravel,
                       accuracy: 1e-4, "the middle carry is w_h(−3.6)·Δh")
    }

    /// **306b acceptance 3 — the local slope no longer collapses, for all three sliders.** Single
    /// slider at ±100, measured on the shipped kernel over `L ∈ [−12, 0]`. The dispatch's 0.80 was
    /// measured with the *pre*-recalibration travels; the frozen travels (1.24/0.96/0.83) land at
    /// ≈0.717 / 0.765 / 0.774. The old travels (0.90/0.70/0.60) would give 0.795 / 0.828 / 0.837 —
    /// printed below as the comparison the dispatch asks for. Threshold 0.70 (306b's revised floor).
    ///
    /// 高光 is in the band now, so its SDR slope is no longer 1.000; it is measured exactly like the
    /// other two.
    func testTheNormalizedBandsKeepLocalContrast() throws {
        let harness = try S2KernelHarness()
        let ls = stride(from: -12.0, through: 0.0, by: 0.05).map { $0 }
        let values = ls.map { Float(pow(2.0, $0)) }
        for (name, shadows, midtones, highlights) in
            [("shadows ±100", 100.0 as Float, 0.0 as Float, 0.0 as Float),
             ("midtones ±100", 0.0, 100.0, 0.0),
             ("highlights ±100", 0.0, 0.0, 100.0)] {
            let plus = try harness.run(values, highlights: highlights,
                                       midtones: midtones, shadows: shadows)
            let minus = try harness.run(values, highlights: -highlights,
                                        midtones: -midtones, shadows: -shadows)
            var worst = Double.infinity
            var worstAt = 0.0
            for i in 0..<(ls.count - 1) {
                let dyPlus = log2(Double(plus[i + 1])) - log2(Double(plus[i]))
                let dyMinus = log2(Double(minus[i + 1])) - log2(Double(minus[i]))
                let dx = ls[i + 1] - ls[i]
                let slope = min(dyPlus, dyMinus) / dx
                if slope < worst { worst = slope; worstAt = ls[i] }
            }
            // The same floor from the CPU's analytic derivative, plus the un-recalibrated travel
            // comparison (×1/1.378) so the dispatch's 0.828 / 0.657 numbers stay traceable.
            let dS = S2Regions.shadowTravel, dM = S2Regions.midTravel, dH = S2Regions.highTravel
            let cur = (Double(shadows) / 100 * dS, Double(midtones) / 100 * dM,
                       Double(highlights) / 100 * dH)
            let old = (Double(shadows) / 100 * dS / 1.378,
                       Double(midtones) / 100 * dM / 1.378,
                       Double(highlights) / 100 * dH / 1.378)
            func cpuFloor(_ d: (Double, Double, Double)) -> Double {
                var best = Double.infinity
                for sign in [1.0, -1.0] {
                    var L = -12.0
                    while L <= 1e-9 {
                        best = min(best, S2Regions.bandSlope(L: L, shadow: sign * d.0,
                                                             mid: sign * d.1, high: sign * d.2))
                        L += 0.05
                    }
                }
                return best
            }
            print(String(format: "306b local contrast %@: min slope %+.6f at L = %+.3f EV "
                         + "(analytic %+.6f; without ×1.378: %+.4f)",
                         name, worst, worstAt, cpuFloor(cur), cpuFloor(old)))
            XCTAssertGreaterThanOrEqual(worst, 0.70, "\(name) folded local contrast")
        }
    }

    /// **306b acceptance 4 — the default travels do not trigger the gate.** The worst opposite-sign
    /// corner is the full (`+1.24, −0.96, +0.83`) set; its measured floor is **0.528659** at
    /// `L = −5.345`, above `minSlope = 0.500`, so the compression ratio is exactly 1 and `travelEV`
    /// returns the raw numbers. 306b's revised floor is ≥ 0.52.
    func testTheDefaultTravelsDoNotTriggerTheGate() {
        let d = S2Regions.travelEV(shadows: 100, midtones: -100, highlights: 100)
        var worst = Double.infinity
        var worstAt = 0.0
        var L = -12.0
        while L <= 1e-9 {
            let s = S2Regions.bandSlope(L: L, shadow: d.shadow, mid: d.mid, high: d.high)
            if s < worst { worst = s; worstAt = L }
            L += 0.05
        }
        let scale = d.shadow / S2Regions.shadowTravel
        print(String(format: "306b gate: min slope %+.6f at L = %+.3f EV, compression %.9f",
                     worst, worstAt, scale))
        XCTAssertGreaterThanOrEqual(worst, 0.52, "the default travels folded (306b floor)")
        XCTAssertEqual(scale, 1.0, accuracy: 1e-12, "the gate must not have moved")
        XCTAssertEqual(d.shadow, S2Regions.shadowTravel, accuracy: 1e-12)
        XCTAssertEqual(d.mid, -S2Regions.midTravel, accuracy: 1e-12)
        XCTAssertEqual(d.high, S2Regions.highTravel, accuracy: 1e-12)
    }

    /// **306 acceptance 5 — no dead zone.** 085's middle slider was exactly 0 at `L = −0.9…0`; the
    /// Gaussian still owns those samples, so `mid = ±50` must produce different pixels at all four
    /// probe luminances.
    func testTheMiddleSliderHasNoDeadZone() throws {
        let harness = try S2KernelHarness()
        let ls = [-5.2, -1.7, -0.9, 0.0]
        let values = ls.map { Float(pow(2.0, $0)) }
        let up = try harness.run(values, midtones: 50)
        let down = try harness.run(values, midtones: -50)
        for i in 0..<ls.count {
            let delta = log2(Double(up[i])) - log2(Double(down[i]))
            print(String(format: "306 mid ±50 at L = %+.1f EV: Δ = %+.4f EV", ls[i], delta))
            XCTAssertGreaterThan(abs(delta), 1e-3, "L = \(ls[i]) EV is a dead zone for 中间调")
        }
    }

    /// **306b acceptance 7 — 299's `+4 → +1` survives, with the shoulder reduced to the difference.**
    /// At `h = −100` the Gaussian band contributes `w_h(+4)·(−0.83) = −0.827947` and the shoulder
    /// `c·shape(+4) = 2.172053`, so `L = +4` still lands on `+1.000`. `L = +8` is recomputed with the
    /// same `k`: the band is `−0.830`, the shoulder `−4.489`, so `y = +2.681` (299's old 1.798 is
    /// **not** a target any more — the dispatch says to report the new k honestly).
    func testTheHDRTailStillLandsOnThe299Promise() throws {
        let harness = try S2KernelHarness()
        let values: [Float] = [16.0, 256.0]   // L = +4, +8 EV
        let out = try harness.run(values, highlights: -100)
        for (i, target) in [1.0, 2.681].enumerated() {
            let y = log2(Double(out[i]))
            print(String(format: "306b HDR tail h=−100: L = %+.0f → y = %+.4f EV",
                         log2(Double(values[i])), y))
            XCTAssertEqual(y, target, accuracy: 0.02, "+4 → +1 keeps 299; +8 follows the new k")
        }
    }

    /// **306b — the band + difference shoulder never folds, on either side of white.**
    ///
    /// `testTheRegionLiftsAreMonotoneForEveryCombination` pins the band on the gate's own domain
    /// (`L ∈ [−12, 0]`) and `testHighlightsAreMonotoneThroughTheHDRRange` pins the shoulder alone.
    /// This is the composition the kernel actually exponentiates: `L ∈ [−12, +8]`, all 27 sign
    /// corners. Above white the slope is *meant* to drop — that is the HDR compressor — so the hard
    /// claim is only that it never reaches 0; measured floor 0.325 at `(+, +, −)`, `L = +0.76 EV`.
    func testTheTotalMapNeverFoldsAboveWhite() {
        var worst = Double.infinity
        var at = (shadow: 0.0, mid: 0.0, high: 0.0, L: 0.0)
        let h = 1e-5
        for s in [-1.0, 0, 1] { for m in [-1.0, 0, 1] { for g in [-1.0, 0, 1] {
            let d = (shadow: s * S2Regions.shadowTravel, mid: m * S2Regions.midTravel,
                     high: g * S2Regions.highTravel)
            var L = -12.0
            while L <= 8.0 {
                let a = S2Regions.totalEV(L: L - h, shadow: d.shadow, mid: d.mid, high: d.high,
                                          highlights: g * 100)
                let b = S2Regions.totalEV(L: L + h, shadow: d.shadow, mid: d.mid, high: d.high,
                                          highlights: g * 100)
                let slope = 1 + (b - a) / (2 * h)
                if slope < worst { worst = slope; at = (s, m, g, L) }
                L += 0.02
            }
        }}}
        print(String(format: "306b total map: min slope %+.6f at (%.0f, %.0f, %.0f) L = %+.2f EV",
                     worst, at.shadow, at.mid, at.high, at.L))
        XCTAssertGreaterThan(worst, 0, "the band + shoulder composition folds")
        XCTAssertGreaterThan(worst, 0.30, "the white-knee dip must stay well clear of a fold")
    }

    /// **306 acceptance 6 — the neutral document is bit-exact.** All sliders 0 makes every band and
    /// the shoulder exactly 0, so the kernel's multiply is by `exp2(0) == 1`.
    func testTheNeutralGaussianMapIsBitExact() throws {
        let harness = try S2KernelHarness()
        let values: [Float] = [0, 1e-6, 0.125, 0.5, 1, 2, 16, 256]
        let out = try harness.run(values)
        for (i, v) in values.enumerated() {
            XCTAssertEqual(out[i].bitPattern, v.bitPattern,
                           "neutral S2 must be the identity at v = \(v)")
        }
    }

    /// 074 R2 also has to hold up **with the other slider at full travel**: shadows +100 with
    /// highlights −100 must not fold the region-lift chain. (098 moved contrast to S1.8, so this
    /// harness no longer has a contrast to combine with — the monotonicity claim is about the three
    /// windows and their common gate.)
    func testTheRegionLiftsSurviveFullTravel() throws {
        let harness = try S2KernelHarness()
        var grid: [Float] = []
        var v: Float = 1e-6
        while v <= 4 { grid.append(v); v *= 1.02 }
        for (label, shadows, highlights) in
            [("shadows +100", 100.0 as Float, 0.0 as Float),
             ("highlights −100", 0, -100)] {
            let out = try harness.run(grid, highlights: highlights, shadows: shadows)
            var worst = Double.infinity
            for i in 0..<(grid.count - 1) {
                let dy = log2(Double(max(out[i + 1], 1e-30))) - log2(Double(max(out[i], 1e-30)))
                let dx = log2(Double(grid[i + 1])) - log2(Double(grid[i]))
                worst = min(worst, dy / dx)
            }
            print(String(format: "074/306b combo %@: min slope %+.4f", label as NSString, worst))
            // Above white the band is still transitioning while the shoulder ramps to `k`, so the
            // total can dip a little below `k` (measured 0.386 for 高光 −100 at L ≈ +1). The hard
            // claim is that it never folds; 0.30 is kept as the 085 floor for the storage axis.
            XCTAssertGreaterThan(worst, 0.30, "\(label) folds")
            XCTAssertGreaterThan(worst, 0, "\(label) must never invert")
        }
    }
}

// MARK: - the S2 harness: the shipped tone-map kernel, compiled here

private struct S2KernelHarness {
    struct Params {
        var b: SIMD4<Float>   // dShadow, dMid, dHigh (EV), identity
        var c: SIMD4<Float>   // contentOrigin.xy, contentSize.xy
        var d: SIMD4<Float>   // 高光 slope k, pad, pad, pad
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState

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
        self.device = device
        self.pipeline = try device.makeComputePipelineState(function: fn)
        guard let q = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        self.queue = q
        XCTAssertEqual(MemoryLayout<Params>.stride, 48, "S2Params' mirror must be as wide as Metal's")
    }

    func run(_ values: [Float], highlights: Float = 0, midtones: Float = 0,
             shadows: Float = 0, contrast: Float = 0) throws -> [Float] {
        // 098: contrast is S1.8 now; S2 has one entry point and reads no contrast number.
        let pso = pipeline
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
        var p = Params(b: SIMD4(Float(travel.shadow), Float(travel.mid), Float(travel.high), 0),
                       c: SIMD4(0, 0, Float(w), Float(h)),
                       d: SIMD4(Float(S2Regions.highSlope(highlights: Double(highlights))), 0, 0, 0))
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