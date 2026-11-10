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
    /// 这块是**回归哨兵**：它是显示路径的整帧哈希，任何一次「不该改变默认路径」的改动都应该让它变红。
    ///
    /// 2026-11-10（342）：重新钉了一次。原因**不是** 342 改坏了它 —— 342 只用 `git worktree add --detach
    /// 91023d0^`（342 之前的干净树）跑过同一条用例，**同样是这 7 条红**，说明这组字面量在本单之前就已经
    /// 落后于显示路径（129 之后 tone map/EDR 尾变过）。重钉时逐值对照过：`91023d0^` 与 342 之后的
    /// 打印哈希**完全相同**（342 的压黑项只作用于 `blacks < 0` 的第二段，0…20 这段逐字节不变），
    /// 所以这次换的是「过期的钉值」，不是「新行为」。
    private static let pinnedDisplayHashes: [(blacks: Double, hash: String)] = [
        (0, "51c352e8710d7db0dbc09d5a5f3e255b4dd46e96d0d31d22f7c371b13c11c2b8"),
        (5, "0b080720f124c31056c78a4dc486cbc7e426fa3c864b7477c5046c4b336bab9e"),
        (10, "5ffaaf46b41dc2e5a687c8a36104810b326ce9a9d75d15c0ffb6533127b7b60c"),
        (15, "b90f1b795c2b0248181a44546d2e091fd4cff309d892c83051b9a52a95ba6b2b"),
        (19.9, "bfadd3500cb4ced89e976f0158cf6c36d570a4f37abcf7215e2b7121e8a29b7e"),
        (19.99, "127590fe35ca6c0632d03376b5b79a66038e7c7b4688783c01c26922aebc507f"),
        (20, "f064220baaaa511b6ff8a6c16ddcddb6ca0f5102e52c85ae25079a8bc792a4d8"),
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
