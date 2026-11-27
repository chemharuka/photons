import XCTest
import CoreGraphics
@testable import PhotonsCore

/// The decode ladder (§11.10): the loupe must be able to put a frame on screen **before** a 60 MP
/// development finishes, and the second visit to fit or 1:1 must never develop the file again.
///
/// What is asserted, and why it is asserted this way:
///
///   · **Counts, not timings.** "fit → 1:1 → fit → 1:1 develops the file once per rung" is a claim
///     about how many times ImageIO ran. A frame that takes 30 ms could still be decoding a 0.5
///     buffer nobody asked for, so the count comes from `RAWDecoder.decodeCounts()` and the test
///     walks the same `DecodeLadder.plan` the controller walks — never a hand-rolled sequence.
///   · **The first frame is a budget, the ready time is a report.** 60 ms is the ceiling for the
///     magnified preview (one render of the resident 0.5 rung); the full-resolution arrival is
///     printed next to the 941 ms Q15 baseline because it is a machine-speed fact, not a contract.
final class DecodeLadderTests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)

    /// Wall-clock ceilings are asserted only under `PHOTONS_BENCH=1` (project rule): `swift test`
    /// builds Debug, where the same render pass measures several times the Release number.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

    // MARK: - fixtures

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    /// One real development, wrapped in a rung — exactly what `LoupeController.makeFrame` does.
    private func develop(_ url: URL, scale: Float) throws -> DecodeRung {
        let decoder = try RAWDecoder()
        let t0 = CFAbsoluteTimeGetCurrent()
        let outcome = try decoder.decodeDetailed(url, options: DecodeOptions(decoderVersion: nil,
                                                                            exposureEV: 0,
                                                                            scale: scale))
        return DecodeRung(scale: scale, image: outcome.image, capabilities: outcome.capabilities,
                          milliseconds: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    /// A rung with no pixels worth looking at: the policy tests must not need ImageIO or Metal.
    private func syntheticRung(_ scale: Float) -> DecodeRung {
        let image = LinearImage(width: 2, height: 2, rgba: [Float16](repeating: 1, count: 16),
                                colorSpace: "extendedLinearSRGB", decoderVersion: "8")
        return DecodeRung(scale: scale, image: image,
                          capabilities: DecoderCapabilities(requestedVersion: nil,
                                                            effectiveVersion: "8",
                                                            defaultVersion: "8"),
                          milliseconds: 0)
    }

    // MARK: - 1. policy

    /// 571-A — a cold request is the full rung and nothing else: the canvas is either the 1920 px
    /// stand-in or the whole picture, never a half-resolution step in between.
    func testColdRequestPlansOnlyTheFullRung() {
        let ladder = DecodeLadder()
        let plan = ladder.plan(identity: "photo", target: DecodeLadder.fullScale)
        XCTAssertNil(plan.preview)
        XCTAssertEqual(plan.rungs, [DecodeLadder.fullScale])
    }

    /// Once the target is resident the plan is the same single rung: no preview, no decode, one render.
    func testResidentTargetPlansASingleRung() {
        let ladder = DecodeLadder()
        ladder.store(syntheticRung(DecodeLadder.previewScale), identity: "photo")
        XCTAssertEqual(ladder.plan(identity: "photo", target: DecodeLadder.fullScale).rungs,
                       [DecodeLadder.fullScale],
                       "571-A: a resident preview rung is not a canvas plan any more")

        ladder.store(syntheticRung(DecodeLadder.fullScale), identity: "photo")
        let plan = ladder.plan(identity: "photo", target: DecodeLadder.fullScale)
        XCTAssertNil(plan.preview)
        XCTAssertEqual(plan.rungs, [DecodeLadder.fullScale])
        XCTAssertNotNil(ladder.resident(identity: "photo", scale: DecodeLadder.fullScale))
    }

    /// A rung is never substituted for another one: a 0.5 buffer must not be handed back as the 1.0
    /// rung (a 2× blow-up of a blur is the one thing a loupe must not present as 1:1).
    func testALadderNeverHandsBackAnotherRungsPixels() {
        let ladder = DecodeLadder()
        ladder.store(syntheticRung(DecodeLadder.previewScale), identity: "photo")
        XCTAssertNotNil(ladder.resident(identity: "photo", scale: DecodeLadder.previewScale))
        XCTAssertNil(ladder.resident(identity: "photo", scale: DecodeLadder.fullScale))
        XCTAssertNil(ladder.resident(identity: "other photo", scale: DecodeLadder.previewScale),
                     "a different photo must never see another photo's buffer")
    }

    /// The memory rule that keeps the ladder from doubling the footprint: a bigger rung releases the
    /// smaller ones of the same photo, because a `RenderGraph` can render any zoom from the biggest
    /// buffer it has.
    func testTheFullRungReleasesThePreviewRung() {
        let ladder = DecodeLadder()
        ladder.store(syntheticRung(DecodeLadder.previewScale), identity: "photo")
        XCTAssertEqual(ladder.residentScales, [DecodeLadder.previewScale])
        ladder.store(syntheticRung(DecodeLadder.fullScale), identity: "photo")
        XCTAssertEqual(ladder.residentScales, [DecodeLadder.fullScale])
        XCTAssertEqual(ladder.released, 1)
        // …and the released rung is still reachable *as a plan*: it is re-derived from the full one
        // by the renderer, never re-decoded, because the plan asks for the full rung only.
        XCTAssertEqual(ladder.plan(identity: "photo", target: DecodeLadder.fullScale).rungs,
                       [DecodeLadder.fullScale])
    }

    /// A new photo drops everything: keeping the previous photo's rungs would be a leak the old
    /// single slot could not have.
    func testSwitchingPhotoForgetsThePreviousRungs() {
        let ladder = DecodeLadder()
        ladder.store(syntheticRung(DecodeLadder.previewScale), identity: "a")
        ladder.store(syntheticRung(DecodeLadder.fullScale), identity: "b")
        XCTAssertEqual(ladder.residentScales, [DecodeLadder.fullScale])
        XCTAssertNil(ladder.resident(identity: "a", scale: DecodeLadder.previewScale))
        XCTAssertNotNil(ladder.resident(identity: "b", scale: DecodeLadder.fullScale))
    }

    // MARK: - 2. the count ("only decoded once")

    /// The claim the whole change exists for: one photo, one development per rung, no matter how
    /// often the camera moves between fit and 1:1. 571-A — the only rung the canvas asks for is the
    /// full one, so a cold open develops exactly once.
    ///
    /// The sequence is the controller's own: `plan` + `rung` per rung. Nothing is hand-sequenced, so
    /// a change to the plan changes this test.
    func testFitAndOneToOneDevelopEachRungExactlyOnce() throws {
        let url = try fixtureURL()
        let identity = url.lastPathComponent
        let ladder = DecodeLadder()
        RAWDecoder.resetDecodeCounts()

        @discardableResult
        func request(_ label: String) throws -> [Float] {
            // Both fit and 1:1 ask for the full rung; they differ in what the *renderer* does with
            // it (a window or the whole frame), never in which pixels it develops.
            let plan = ladder.plan(identity: identity, target: DecodeLadder.fullScale)
            var presented: [Float] = []
            for scale in plan.rungs {
                let answer = try ladder.rung(identity: identity, scale: scale) {
                    try develop(url, scale: scale)
                }
                presented.append(answer.rung.scale)
                XCTAssertEqual(answer.rung.scale, scale, "a rung must answer for itself")
            }
            print("LADDER \(label): \(presented.map { String(format: "%.1f", $0) }.joined(separator: " → "))"
                  + "  decodes \(RAWDecoder.decodeCounts().sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))")
            return presented
        }

        // A cold open: the full rung only (571-A removed the 0.5 leg).
        XCTAssertEqual(try request("open"), [DecodeLadder.fullScale])
        XCTAssertEqual(RAWDecoder.decodeCounts(), [DecodeLadder.fullScale: 1])

        // Five round trips through fit ↔ 1:1 add nothing at all.
        for i in 0..<5 {
            XCTAssertEqual(try request("fit\(i)"), [DecodeLadder.fullScale])
            XCTAssertEqual(try request("1:1-\(i)"), [DecodeLadder.fullScale])
        }
        XCTAssertEqual(RAWDecoder.decodeCounts(), [DecodeLadder.fullScale: 1],
                       "switching fit ↔ 1:1 must never develop the file again")
        XCTAssertEqual(ladder.decodes, 1,
                       "the cold open developed once; every later frame is a hit")
        XCTAssertEqual(ladder.hits, 10)
    }

    // MARK: - 3. the first frame, and the pan it enables

    /// A 1:1 window frame, built the way the loupe builds it: the frame is the decoded buffer at
    /// `zoom / decodeScale` content pixels, and the window is one viewport of it.
    private func oneToOne(decoded: LinearImage, decodeScale: Double,
                          viewport: ImageSize) -> (window: ImageRect, scale: Double) {
        let scale = 1.0 / decodeScale          // zoom == 1 at 1:1
        let frameWidth = Int((Double(decoded.width) * scale).rounded())
        let frameHeight = Int((Double(decoded.height) * scale).rounded())
        let w = min(viewport.width, frameWidth), h = min(viewport.height, frameHeight)
        return (ImageRect(x: (frameWidth - w) / 2, y: (frameHeight - h) / 2, width: w, height: h),
                scale)
    }

    private func time(_ body: () throws -> Void) rethrows -> Double {
        let t0 = CFAbsoluteTimeGetCurrent()
        try body()
        return (CFAbsoluteTimeGetCurrent() - t0) * 1000
    }

    private func percentile(_ xs: [Double], _ q: Double) -> Double {
        guard !xs.isEmpty else { return 0 }
        let sorted = xs.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * q).rounded()))]
    }

    /// ① the first 1:1 frame built from the full rung, ② pan steady state — measured on the same
    /// 60 MP file. 571-A: there is no 0.5 rung to open on, so the first frame is a render of the
    /// already-developed full buffer (the user waits for the development, not for a soft frame).
    func testOneToOneRendersFromTheFullRungWithoutASecondDevelopment() throws {
        let url = try fixtureURL()
        let ladder = DecodeLadder()
        let identity = url.lastPathComponent
        RAWDecoder.resetDecodeCounts()

        // What the fit view develops: the whole picture, once.
        let fullAnswer = try ladder.rung(identity: identity, scale: DecodeLadder.fullScale) {
            try develop(url, scale: DecodeLadder.fullScale)
        }
        let full = fullAnswer.rung
        print(String(format: "LADDER full decode: %dx%d in %.0f ms",
                     full.image.width, full.image.height, full.milliseconds))
        let plan = ladder.plan(identity: identity, target: DecodeLadder.fullScale)
        XCTAssertNil(plan.preview, "571-A: no half-resolution leg")
        XCTAssertEqual(plan.rungs, [DecodeLadder.fullScale])

        // ① The first 1:1 frame: graph build + one window render, no ImageIO.
        let window = oneToOne(decoded: full.image, decodeScale: 1, viewport: Self.viewport)
        var firstRuns: [Double] = []
        for run in 0..<3 {
            let ms = try time {
                let graph = try RenderGraph(input: RenderInput(image: full.image,
                                                               identity: "ladder-full-\(run)",
                                                               sourceURL: url))
                let result = try graph.render(.neutral, options: RenderOptions(
                    canvas: Self.viewport, scale: window.scale,
                    outputWindow: window.window, wantsPixels: false))
                if let tex = result.output { graph.recycle(output: tex) }
            }
            firstRuns.append(ms)
        }
        let firstP50 = percentile(firstRuns, 0.5)
        print(String(format: "LADDER 1:1 first frame (full rung): %@ ms → p50 %.1f ms",
                     firstRuns.map { String(format: "%.1f", $0) }.joined(separator: "/"), firstP50))
        // Millisecond budget: asserted **only** under `PHOTONS_BENCH=1`, the project's rule for every
        // wall-clock ceiling. The number is printed on every run.
        if benchmarks {
            XCTAssertLessThan(firstP50, 60, "the first 1:1 frame must fit the 60 ms budget")
        }

        // ② Pan: 20 windows off the resident full rung, the steady state the ladder must not spoil.
        let graph = try RenderGraph(input: RenderInput(image: full.image,
                                                       identity: "ladder-full",
                                                       sourceURL: url))
        let base = oneToOne(decoded: full.image, decodeScale: 1, viewport: Self.viewport)
        var panTimes: [Double] = []
        for step in 0..<23 {
            let panWindow = ImageRect(x: base.window.x + step * 16, y: base.window.y + step * 9,
                                      width: base.window.width, height: base.window.height)
            panTimes.append(try time {
                let result = try graph.render(.neutral, options: RenderOptions(
                    canvas: Self.viewport, scale: base.scale,
                    outputWindow: panWindow, wantsPixels: false))
                if let tex = result.output { graph.recycle(output: tex) }
            })
        }
        let panP50 = percentile(Array(panTimes.dropFirst(3)), 0.5)
        print(String(format: "LADDER 1:1 full-resolution ready: %.0f ms decode", full.milliseconds))
        print(String(format: "LADDER 1:1 pan: p50 %.2f ms over 20 windows (budget 6, Q15 5.8)", panP50))
        if benchmarks {
            XCTAssertLessThan(panP50, 6.0, "panning a resident full rung must stay inside the 6 ms budget")
        }
        // "One development, not a decode storm" is a **count**, not a clock. 571-A: the cold open
        // developed exactly one rung, and every later visit is a hit.
        for _ in 0..<2 {
            let plan = ladder.plan(identity: identity, target: DecodeLadder.fullScale)
            for scale in plan.rungs {
                let answer = try ladder.rung(identity: identity, scale: scale) {
                    XCTFail("a resident rung must never be developed again")
                    return try develop(url, scale: scale)
                }
                XCTAssertTrue(answer.cached, "the second visit to a rung is a cache hit")
            }
        }
        XCTAssertGreaterThanOrEqual(ladder.hits, 2, "the second visit to 1:1 must be a hit")
        XCTAssertEqual(RAWDecoder.decodeCounts().values.reduce(0, +), 1,
                       "one development of the full rung and nothing else: \(RAWDecoder.decodeCounts())")
        XCTAssertEqual(RAWDecoder.decodeCounts(), [DecodeLadder.fullScale: 1])
    }

    // MARK: - 4. the row flip the whole buffer passes through

    /// `flipRows` was rewritten to copy rows instead of swapping samples one at a time (145 ms → 12 ms
    /// on a 60 MP frame). It has to be the *same* permutation — this is the guard that keeps the
    /// decode recipe at `v2` and every stored buffer's digest valid.
    func testRowFlipIsTheReferencePermutation() {
        for (width, height) in [(3, 4), (1, 1), (2, 7), (4, 2), (5, 1), (8, 8)] {
            let count = width * height * 4
            var actual = (0..<count).map { Float16(bitPattern: UInt16($0 % 8192)) }
            var expected = actual
            RAWDecoder.flipRows(&actual, width: width, height: height)
            let stride = width * 4
            var y = 0
            while y < height / 2 {          // the pre-optimisation formulation, verbatim
                let top = y * stride, bottom = (height - 1 - y) * stride
                for i in 0..<stride { expected.swapAt(top + i, bottom + i) }
                y += 1
            }
            XCTAssertEqual(actual.map { $0.bitPattern }, expected.map { $0.bitPattern },
                           "row flip changed for \(width)×\(height)")
        }
    }
}
