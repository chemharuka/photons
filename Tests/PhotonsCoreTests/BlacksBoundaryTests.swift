import XCTest
import Metal
@testable import PhotonsCore

/// 346 — S1's blacks travel switches mechanism at **slider ±30**, which is kernel `|k| = 50`.
///
/// `tone_shape.metal`'s hybrid instantiation blends the black-point level in with
/// `m = smoothstep(0.2, 1, |k|/100)`: the level term is exactly 0 at `|k| = 50` and starts moving
/// above it. 129 left this CPU switch at 50 in *slider* units by mistake (the level itself entered at
/// |k| = 20 — `a449462`), so `20…50` rendered with the level term switched off and `50 → 50.01`
/// stepped the picture by 3.13 codes.
///
/// 346 keeps the CPU switch at `|k| = 50` — that is the kernel's own zero, not a taste knob — and
/// moves the numbers that reach it: `LightGroup.blacksKernelValue` stretches slider 0…30 over kernel
/// 0…50 and slider 30…100 over kernel 50…100. So the switch sits at **slider ±30** — the owner's
/// 「0–30 是调整 EV，30–100 这一段是调整电平」 — and new `−30` is byte-for-byte old `−50`
/// (`BlacksTravelTests` pins that pair). 29.99 maps to 49.983 (knee), 30.01 to 50.017 (hybrid).
///
/// **True black is the one sample the two instantiations do not share.** The hybrid branch routes
/// its lift through `s1_toe` unconditionally (also `a449462`), so at `off == 0` it maps `0` to
/// `LEV_KNEE/4 = 2.5e-4` where the knee branch multiplies and leaves `0`. That is a kernel-side
/// property, not the dispatch boundary, and 129 explicitly forbids touching `tone_shape.metal`;
/// the boundary comparisons below cover the 256 non-zero picture levels and the true-black step is
/// measured separately (0.82 code, against the old 3.13-code seam at 50).
final class BlacksBoundaryTests: XCTestCase {

    private static let levels: [Float] = (0...256).map { Float($0) / 256 }

    /// **Kernel units.** 50 is the zero of `m`; 50.01 is the first kernel value that needs the level.
    private static let kernelCases: [Float] = [19.9, 20, 25, 49.9, 49.99, 50, 50.01, 50.1, 60]

    /// **Slider units**, around the new mechanism switch. 30 → kernel 50 exactly.
    private static let sliderCases: [Double] = [
        29.9, 29.99, 30, 30.01, 30.1, 31, 45, 60, 100,
        -29.9, -29.99, -30, -30.01, -30.1, -100,
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

    // MARK: - ① the boundary, in both coordinate systems

    func testTheSwitchIsSliderThirtyAndKernelFifty() {
        // (a) the mapping itself: the two ends of the stretch, and 0 as the identity.
        XCTAssertEqual(LightGroup.blacksKernelValue(0), 0)
        XCTAssertEqual(LightGroup.blacksKernelValue(30), 50, accuracy: 0)
        XCTAssertEqual(LightGroup.blacksKernelValue(-30), -50, accuracy: 0)
        XCTAssertEqual(LightGroup.blacksKernelValue(100), 100, accuracy: 0)
        XCTAssertEqual(LightGroup.blacksKernelValue(-100), -100, accuracy: 0)
        // 25 → 41.66667 is *old* 41.66667, not old 25: the first 30 slider units are the old 0…50.
        XCTAssertEqual(LightGroup.blacksKernelValue(25), 125.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(LightGroup.blacksKernelValue(-15), -25, accuracy: 0)

        // (b) the CPU decision, through the one mapping.
        print("346 boundary — slider → kernel → level?")
        for blacks in Self.sliderCases {
            let k = LightGroup.blacksKernelValue(blacks)
            let usesLevels = RenderGraph.sceneLinearUsesLevelEntry(blacks: blacks)
            print(String(format: "    bl %7.2f → k %+9.5f → %@", blacks, k,
                         usesLevels ? "hybrid" : "knee"))
            XCTAssertEqual(usesLevels, abs(k) >= RenderGraph.blacksLevelEntry,
                           "dispatch decision for blacks \(blacks) disagrees with the boundary")
            XCTAssertEqual(usesLevels, abs(blacks) >= 30,
                           "the mechanism switch must sit at slider ±30 (30 inclusive: old ±50's curve)")
        }
        // Acceptance ②: 29.99 → non-level, 30.01 → level, and 30 is the switch itself.
        XCTAssertFalse(RenderGraph.sceneLinearUsesLevelEntry(blacks: 29.99))
        XCTAssertTrue(RenderGraph.sceneLinearUsesLevelEntry(blacks: 30),
                      "30 maps to |k| = 50 exactly — old ±50's own curve, so it must carry the level")
        XCTAssertTrue(RenderGraph.sceneLinearUsesLevelEntry(blacks: 30.01))
        XCTAssertFalse(RenderGraph.sceneLinearUsesLevelEntry(blacks: -29.99))
        XCTAssertTrue(RenderGraph.sceneLinearUsesLevelEntry(blacks: -30.01))
        // The old entry (129's 20) would put the switch at slider 12: it is a *kernel* number now.
        XCTAssertEqual(RenderGraph.blacksLevelEntry, 50,
                       "the entry is a kernel number; keeping 20 here would put the switch at slider 12")
    }

    // MARK: - ② the two instantiations across the kernel boundary

    func testTheTwoInstancesAgreeAcrossTheThreshold() throws {
        let harness = try MetalKernelHarness()
        let values = Self.levels
        var rendered: [Float: (hybrid: [Float], knee: [Float])] = [:]

        for k in Self.kernelCases {
            rendered[k] = (try harness.run(values, blacks: k, whites: 0, entry: .hybrid),
                           try harness.run(values, blacks: k, whites: 0, entry: .knee))
        }

        // At and below 20 the level term is exactly 0 (`m = smoothstep(0.2, 1, |k|/100)`), so the two
        // instantiations write the same picture on every level above true black. The first sample is
        // the `s1_toe` exception documented on the class, so it is recorded rather than asserted equal.
        // Above 20 the kernel's blend is already non-zero — which is why production stops using the
        // knee only at 50 (346), where the *slider* says the mechanism changes.
        for k in [Float(19.9), 20] {
            let pair = try XCTUnwrap(rendered[k])
            for i in 1..<values.count {
                XCTAssertEqual(pair.hybrid[i].bitPattern, pair.knee[i].bitPattern,
                               "k \(k), level \(i) (v = \(values[i])): the level entered below its zero 20")
            }
            XCTAssertEqual(pair.knee[0], 0, "the knee entry must keep true black at 0")
            let trueBlack = Self.code(pair.hybrid[0]) - Self.code(pair.knee[0])
            print(String(format: "346 true black at k %.2f: knee 0, hybrid %.6f code (toe floor)",
                         k, trueBlack))
            XCTAssertEqual(trueBlack, 0.82365, accuracy: 0.01,
                           "the hybrid toe floor moved; this is kernel-side, not 346's boundary")
        }

        // Above 50 the level really is in the hybrid instantiation: it differs from the knee one by
        // more than a rounding step somewhere on the ramp.
        for k in [Float(49.9), 50, 50.01, 60] {
            let pair = try XCTUnwrap(rendered[k])
            let worst = Self.maxCodeStep(pair.hybrid, pair.knee, from: 1)
            XCTAssertGreaterThan(worst, 0.1,
                                 "k \(k): hybrid and knee are the same picture; the level is missing")
            print(String(format: "346 k %.2f: hybrid vs knee worst %.3f code", k, worst))
        }

        // Adjacent values through production's own picks (the same decision the graph makes), sample
        // by sample over every non-zero level. Inside one instantiation the travel is smooth; the one
        // step is 49.99 → 50, where the level joins at m(0.5) ≈ 0.32 — the documented price of
        // 「new −30 = old −50」 (see `blacksLevelEntry`). The slider reaches that pair at
        // 29.994 → 30.006.
        func production(_ k: Float) -> [Float] {
            let pair = rendered[k]!
            return abs(k) >= 50 ? pair.hybrid : pair.knee
        }
        let pairs: [(Float, Float, Double)] = [(49.9, 49.99, 0.5), (49.99, 50, 2.0),
                                               (50, 50.01, 0.5)]
        for (below, above, ceiling) in pairs {
            let worst = Self.maxCodeStep(production(below), production(above), from: 1)
            print(String(format: "346 production k %.2f → %.2f: worst step %.3f code (ceiling %.1f)",
                         below, above, worst, ceiling))
            XCTAssertLessThanOrEqual(worst, ceiling,
                                     "\(below) → \(above) stepped \(worst) codes across the boundary")
        }
    }

    // MARK: - ③ the pure-EV path is untouched

    /// Fingerprints of the **whole display render** of a 257-level grey ramp.
    ///
    /// `blacks = 0` is the one row 346 cannot move (`0 → 0`, and the key material is byte-identical),
    /// and it still carries 129's hash `51c352e8…` — this file's regression sentinel for the default
    /// entry. The non-zero rows were re-recorded **for 346**: the slider number now feeds a different
    /// kernel value (5 → 8.33, 20 → 33.33), so their pixels necessarily moved; the entry point
    /// (knee, `|k| ≤ 50`) and the kernel arithmetic did not.
    private static let pinnedDisplayHashes: [(blacks: Double, hash: String)] = [
        (0, "51c352e8710d7db0dbc09d5a5f3e255b4dd46e96d0d31d22f7c371b13c11c2b8"),
        (5, "da14507bc72ee235fc3ef3123c71ae4e8d29dd6cdc4eb00db44f99fa08c6cc94"),
        (10, "639e8607bf2e3f7be0a41c84da855a2d267a934b3d4eaccd961a0fc1a38e9a26"),
        (15, "773f11fae592b5c6b33e4db6377f5e345a88afca380907b23e8763e0ae734773"),
        (19.9, "38924948508abbfe8d1c5c60681e096b521e64173a0f0a34f642018bbe396365"),
        (19.99, "9aaaa42678a608546ffd0a2b73f079515ccf9ab24fadc63a48419d5b631f40ba"),
        (20, "413dcd3548b1a219c16a45dc2337738160b106518c49af6f01b36986fb690b0e"),
    ]

    func testTheDefaultPathIsUntouched() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: Self.grayscale(), identity: "blacks-boundary"))

        for (blacks, expected) in Self.pinnedDisplayHashes {
            XCTAssertFalse(RenderGraph.sceneLinearUsesLevelEntry(blacks: blacks),
                           "blacks \(blacks) is on the pure-EV side of the boundary")
            let hash = try Self.render(graph, blacks: blacks).sha256()
            XCTAssertEqual(hash, expected,
                           "blacks \(blacks) moved: the pure-EV entry must be byte-identical to 346")
            print(String(format: "346 default path blacks %.2f: %@", blacks, hash))
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
