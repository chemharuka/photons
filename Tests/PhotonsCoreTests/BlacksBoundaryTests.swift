import XCTest
import Metal
@testable import PhotonsCore

/// 129 — S1's blacks level enters at `|blacks| = 20`, not at 073C's original 50.
///
/// `tone_shape.metal`'s hybrid instantiation blends the black-point level in with
/// `m = smoothstep(0.2, 1, |blacks|/100)` (`a449462`, 2026-10-29): the level term is exactly 0 at
/// `|blacks| = 20` and starts moving above it. The CPU used to keep dispatching 073B's knee
/// instantiation until `|blacks| = 50`, so the 20…50 range silently lost the level term and
/// `50 → 50.01` stepped the picture by 3.13 codes. `RenderGraph.sceneLinearUsesLevelEntry` is now
/// the single boundary decision; these tests pin it on both sides and pin the kernel's pixels.
///
/// **True black is the one sample the two instantiations do not share.** The hybrid branch routes
/// its lift through `s1_toe` unconditionally (also `a449462`), so at `off == 0` it maps `0` to
/// `LEV_KNEE/4 = 2.5e-4` where the knee branch multiplies and leaves `0`. That is a kernel-side
/// property, not the dispatch boundary, and 129 explicitly forbids touching `tone_shape.metal`;
/// the boundary comparisons below cover the 256 non-zero picture levels and the true-black step is
/// measured separately (0.82 code, against the old 3.13-code seam at 50).
final class BlacksBoundaryTests: XCTestCase {

    private static let levels: [Float] = (0...256).map { Float($0) / 256 }

    /// All values acceptance 1 names, plus 21 (named in its prose).
    private static let thresholdCases: [Float] = [
        19.9, 19.99, 20, 20.01, 20.1, 21, 30, 45, 49.9, 50, 50.01, 60,
    ]

    /// sRGB code of a scene-linear value, the same 8-bit yardstick `BwLevelsTests` uses.
    private static func code(_ v: Float) -> Double {
        let x = max(Double(v), 0)
        let e = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return e * 255
    }

    private static func maxCodeStep(_ a: [Float], _ b: [Float], from index: Int) -> Double {
        var worst = 0.0
        for i in index..<min(a.count, b.count) {
            worst = max(worst, abs(code(a[i]) - code(b[i])))
        }
        return worst
    }

    // MARK: - ① the two instantiations across the boundary

    func testTheTwoInstancesAgreeAcrossTheThreshold() throws {
        let harness = try MetalKernelHarness()
        let values = Self.levels
        var rendered: [Float: (hybrid: [Float], knee: [Float])] = [:]

        for blacks in Self.thresholdCases {
            let hybrid = try harness.run(values, blacks: blacks, whites: 0, entry: .hybrid)
            let knee = try harness.run(values, blacks: blacks, whites: 0, entry: .knee)
            rendered[blacks] = (hybrid, knee)

            // The CPU decision, not a copy of the number: <= 20 is 073B's pure-EV knee,
            // > 20 is 073C's hybrid (the level term is non-zero from 20.01 on).
            let usesLevels = RenderGraph.sceneLinearUsesLevelEntry(blacks: Double(blacks))
            XCTAssertEqual(usesLevels, Double(blacks) > RenderGraph.blacksLevelEntry,
                           "dispatch decision for blacks \(blacks) disagrees with the boundary")
            if blacks <= 20 {
                XCTAssertFalse(usesLevels, "blacks \(blacks) must stay on 073B's knee entry")
            } else {
                XCTAssertTrue(usesLevels, "blacks \(blacks) must run the level-bearing hybrid entry")
            }
        }

        // 20.01 and 21 are the first two values that must carry the level.
        XCTAssertTrue(RenderGraph.sceneLinearUsesLevelEntry(blacks: 20.01))
        XCTAssertTrue(RenderGraph.sceneLinearUsesLevelEntry(blacks: 21))
        // The boundary value itself is pinned: `m(20) == 0`, so `>` keeps 073B's bytes there.
        XCTAssertFalse(RenderGraph.sceneLinearUsesLevelEntry(blacks: 20))

        // Below (and at) 20 the level term is absent: the two instantiations write the same picture
        // on every level above true black. The first sample is the `s1_toe` exception documented on
        // the class, so it is recorded rather than asserted equal.
        for blacks in [Float(19.9), 19.99, 20] {
            let pair = try XCTUnwrap(rendered[blacks])
            for i in 1..<values.count {
                XCTAssertEqual(pair.hybrid[i].bitPattern, pair.knee[i].bitPattern,
                               "blacks \(blacks), level \(i) (v = \(values[i])): the level entered below 20")
            }
            XCTAssertEqual(pair.knee[0], 0, "the knee entry must keep true black at 0")
            let trueBlack = Self.code(pair.hybrid[0]) - Self.code(pair.knee[0])
            print(String(format: "129 true black at blacks %.2f: knee 0, hybrid %.6f code (toe floor)",
                         blacks, trueBlack))
            XCTAssertEqual(trueBlack, 0.82365, accuracy: 0.01,
                           "the hybrid toe floor moved; this is kernel-side, not 129's boundary")
        }

        // Above 20 the level really is in the hybrid instantiation: it differs from the knee one by
        // more than a rounding step somewhere on the ramp (30/45/49.9 are the named checks).
        for blacks in [Float(30), 45, 49.9] {
            let pair = try XCTUnwrap(rendered[blacks])
            let worst = Self.maxCodeStep(pair.hybrid, pair.knee, from: 1)
            XCTAssertGreaterThan(worst, 0.1,
                                 "blacks \(blacks): hybrid and knee are the same picture; the level is missing")
            print(String(format: "129 blacks %.2f: hybrid vs knee worst %.3f code", blacks, worst))
        }

        // Adjacent slider values must not step the *picture* by more than half an 8-bit code.
        // These are production's picks (the same decision the graph makes), compared sample by
        // sample over every non-zero level. Before 129 the 50 → 50.01 pair crossed a dispatch seam
        // and stepped 3.13 codes; 19.9 → 20.01 is the new boundary.
        func production(_ blacks: Float) -> [Float] {
            let pair = rendered[blacks]!
            return RenderGraph.sceneLinearUsesLevelEntry(blacks: Double(blacks)) ? pair.hybrid : pair.knee
        }

        for (below, above) in [(Float(19.9), Float(20.01)), (49.9, 50.01), (50, 50.01)] {
            let worst = Self.maxCodeStep(production(below), production(above), from: 1)
            print(String(format: "129 production %.2f → %.2f: worst step %.3f code", below, above, worst))
            XCTAssertLessThanOrEqual(worst, 0.5,
                                     "\(below) → \(above) stepped \(worst) codes across the boundary")
        }

        // The old seam is gone: 50 and 50.01 are now the same instantiation, so they cannot disagree
        // by the 3.13-code knee/hybrid step. (The boundary's own residual is the true-black toe.)
        let seam = Self.maxCodeStep(production(50), production(50.01), from: 0)
        print(String(format: "129 old 50 → 50.01 seam: %.6f code", seam))
        XCTAssertLessThan(seam, 0.1, "50 → 50.01 still crosses a dispatch seam")
    }

    // MARK: - ② the pure-EV path is untouched

    /// Fingerprints of the **whole display render** of a 257-level grey ramp, recorded from the code
    /// *before* 129 changed the dispatch boundary (`|blacks| > 50`). `blacks = 0` is 019's default
    /// entry and the rest are 073B's knee entry; none of them may move by even one byte.
    private static let pinnedDisplayHashes: [(blacks: Double, hash: String)] = [
        (0, "cc9a444295fc127c9b1bb09e0f48635947abfc121a90ad3a08978918542487de"),
        (5, "73586c9aca82b64c73aa2aaf90252ec1e641f64e7b0a87c318aac42b8f0fd0a3"),
        (10, "b51ad212ee5b12508f15fbbcbdd51db7193263a29f583aec4381d43557d959f9"),
        (15, "abcbd6d37f4daeec44a7f3225eee8435edd5840594d9bcbef38ddf3d45cb34ea"),
        (19.9, "1c8d687e65f5646885796885cb92876d5c3b318c87f1fea9bc650a57a3e8043b"),
        (19.99, "1e8e7c66a30794ece14330973748131b6b77a591445a3097ed4a2043a341d7ad"),
        (20, "9003b4902fcb3d131a59b8bba12b55fc86f80384bb0635f82e3c0d90e6f0a1d0"),
    ]

    func testTheDefaultPathIsUntouched() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: Self.grayscale(), identity: "blacks-boundary"))

        for (blacks, expected) in Self.pinnedDisplayHashes {
            XCTAssertFalse(RenderGraph.sceneLinearUsesLevelEntry(blacks: blacks),
                           "blacks \(blacks) is on the pure-EV side of the boundary")
            let hash = try Self.render(graph, blacks: blacks).sha256()
            XCTAssertEqual(hash, expected,
                           "blacks \(blacks) moved: the pure-EV entry must be byte-identical to pre-129")
            print(String(format: "129 default path blacks %.2f: %@", blacks, hash))
        }
    }

    // MARK: - fixtures

    private static func grayscale() -> LinearImage {
        let width = 257, height = 8
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(Float(x) / 256)
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private static func render(_ graph: RenderGraph, blacks: Double) throws -> DisplayImage {
        var edit = EditModel.neutral
        edit.light.blacks = blacks
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }
}
