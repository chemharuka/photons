import XCTest
import Metal
import PhotonsCore

/// 141 — **曝光与去雾必须可交换。** S1 applies the global exposure gain `g = 2^EV` before S1.9, so
/// the pre-141 stage measured `A`, `t` and 135's `p99` on the *already exposed* light: the same
/// dehaze amount acted one way at EV 0 (bright decile 0.884×, crushing) and the opposite way at
/// EV +2 (1.066×, lifting), and at EV +4 the airlight hit 135's ceiling so `D = 100` was
/// bit-identical to `D = 0`. The invariant this file pins:
///
///     render(E, D) == 2^E · render(0, D)      (scene-linear light, per pixel)
///
/// The stage now divides `g` out of every estimate and multiplies the recovery back by `g`
/// (`Kernels/s1_9_dehaze.metal`), so `E = 0` is the old arithmetic verbatim — the SHAs below were
/// recorded with the pre-141 build — and `E ≠ 0` is the same operation on the same numbers.
final class DehazeExposureTests: XCTestCase {

    // MARK: - frame builders

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func image(width: Int, height: Int,
                       _ value: (Int, Int) -> Double) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y)
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// The same synthetic landscape `DehazeLinearTests` uses: a bright veil-owning band, a textured
    /// mid band and a near-black band.
    private func landscape(width: Int = 750, height: Int = 500) -> LinearImage {
        image(width: width, height: height) { x, y in
            if y < height / 3 { return 1.0 - 0.10 * Double(y) / Double(height / 3) }
            if y < 2 * height / 3 { return 0.20 + ((x / 4 + y / 4) % 2 == 0 ? 0.05 : -0.05) }
            return 0.01 + 0.02 * Double(x) / Double(width)
        }
    }

    private func foggy(_ image: LinearImage, veil: Double = 0.4) -> LinearImage {
        var rgba = image.rgba
        for i in stride(from: 0, to: rgba.count, by: 4) {
            for c in 0..<3 { rgba[i + c] = Float16(Double(rgba[i + c]) * (1 - veil) + veil) }
        }
        return LinearImage(width: image.width, height: image.height, rgba: rgba,
                           colorSpace: image.colorSpace, decoderVersion: image.decoderVersion)
    }

    /// Five coloured bands whose luminance spans the 130 fade (`DehazeLinearTests.colouredBlocks`):
    /// the dehaze gain is not a constant, so this frame exercises the recovery, not just `t`.
    private func colouredBlocks(width: Int = 100, height: Int = 48) -> LinearImage {
        let bands: [(Double, Double, Double)] = [
            (0.30, 0.30, 0.30),
            (0.50, 0.25, 0.10),
            (0.30, 0.45, 0.05),
            (0.45, 0.30, 0.04),
            (0.30, 0.90, 0.10),
        ]
        let band = max(width / bands.count, 1)
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = bands[min(x / band, bands.count - 1)]
                let i = (y * width + x) * 4
                rgba[i] = Float16(c.0); rgba[i + 1] = Float16(c.1)
                rgba[i + 2] = Float16(c.2); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    // MARK: - the scene-linear frame

    /// S4's linear exit in the **working primaries** (Rec.2020), so S4's colour matrix is the exact
    /// identity: the frame is the scene light itself, before any tone map or OETF.
    private func linearRender(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let display = DisplayOptions(primaries: .rec2020, bitDepth: 16, headroom: 1,
                                     linearOutput: true)
        let result = try graph.render(edit, options: RenderOptions(
            scale: 1, display: display, useCache: false, wantsPixels: true))
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func edit(exposure: Double, dehaze: Double) -> EditModel {
        var e = EditModel.neutral
        e.light.exposure = exposure
        e.effects.dehaze = dehaze
        return e
    }

    private func decode(_ path: String) throws -> LinearImage {
        try RAWDecoder().decode(URL(fileURLWithPath: path),
                                options: DecodeOptions(scale: 0.25))
    }

    /// 141's own dark channel: `min` over RGB, one value per `q × q` block, on the light **divided
    /// by the exposure gain** — the coordinate the airlight is estimated in.
    private func darkChannelMean(_ image: DisplayImage, gain: Float, q: Int) -> Double {
        var sum = 0.0
        var blocks = 0
        for by in stride(from: 0, to: image.height, by: q) {
            for bx in stride(from: 0, to: image.width, by: q) {
                var m = Float.greatestFiniteMagnitude
                for y in by..<min(by + q, image.height) {
                    for x in bx..<min(bx + q, image.width) {
                        let i = (y * image.width + x) * 4
                        m = min(m, Float(image.rgba[i]) / gain,
                                Float(image.rgba[i + 1]) / gain,
                                Float(image.rgba[i + 2]) / gain)
                    }
                }
                sum += Double(m)
                blocks += 1
            }
        }
        return sum / Double(max(blocks, 1))
    }

    /// The `q × q` block minima of a frame — the dark texture's own content. Used by the commute
    /// test to know whether S1's half-precision input stayed in Float16's normal range across the
    /// whole estimation window.
    private func blockMinima(_ image: DisplayImage, q: Int) -> (values: [Float], qW: Int, qH: Int) {
        let qW = max(1, (image.width + q - 1) / q)
        let qH = max(1, (image.height + q - 1) / q)
        var out = [Float](repeating: .greatestFiniteMagnitude, count: qW * qH)
        for by in 0..<qH {
            for bx in 0..<qW {
                var m = Float.greatestFiniteMagnitude
                for y in (by * q)..<min(by * q + q, image.height) {
                    for x in (bx * q)..<min(bx * q + q, image.width) {
                        let i = (y * image.width + x) * 4
                        m = min(m, Float(image.rgba[i]), Float(image.rgba[i + 1]),
                                Float(image.rgba[i + 2]))
                    }
                }
                out[by * qW + bx] = m
            }
        }
        return (out, qW, qH)
    }

    // MARK: - 1. 交换性 (the reference frames)

    func testExposureAndDehazeCommuteOnReferenceFrames() throws {
        let frames = [
            ("L1030437", NSString(string: "~/Desktop/test/L1030437.dng").expandingTildeInPath),
            ("DJI_air3_2250_D", NSString(string: "~/Desktop/US/DJI_air3_2250_D.dng").expandingTildeInPath),
            ("L1030433", NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath),
        ]
        var available = 0
        for (name, path) in frames {
            guard FileManager.default.fileExists(atPath: path) else {
                print("COMMUTE · \(name) · skipped (missing)")
                continue
            }
            available += 1
            let decoded = try decode(path)
            let graph = try makeGraph(decoded, identity: "dehaze-exposure-\(name)")
            // The actual half-precision input S1 hands to S1.9 at `E = -2`: with no dehaze the stage
            // does not exist and every later stage is the identity, so this frame *is* S1's output.
            // It tells the test whether the 1/4 scale stayed in Float16's normal range.
            let minusTwoStageInput = try linearRender(graph, edit(exposure: -2, dehaze: 0))
            // The block minima of that input: if any block feeding the dark-channel bilinear sample
            // is subnormal, the 1/4 scale lost bits in the half texture and the estimate cannot be
            // bit-identical no matter what S1.9 does.
            let minusBlocks = blockMinima(minusTwoStageInput, q: 4)
            for d in [20.0, 60.0, 100.0] {
                let base = try linearRender(graph, edit(exposure: 0, dehaze: d))
                for ev in [-2.0, 1.0, 2.0] {
                    let exposed = try linearRender(graph, edit(exposure: ev, dehaze: d))
                    let g = Float(pow(2.0, ev))
                    // Float16 has a **constant** grid below 2^-14 (`leastNormalMagnitude`), so a
                    // power-of-two gain cannot land on the same grid there: S1's half-precision
                    // intermediate loses low bits when `g < 1`, and one dark block minimum is enough
                    // to move `D`/`t`. The 1-ULP law is checked wherever the estimation window stayed
                    // in the format's normal range; the subnormal floor — the local dark channel below
                    // 2.4e-4 scene linear, physically under two display codes — is held to half the
                    // smallest normal half (3.05e-5), far below the picture.
                    let normalFloor = Float(Float16.leastNormalMagnitude)
                    let subnormalTolerance = normalFloor / 2
                    var over = 0
                    var subnormalOver = 0
                    var subnormalWorst = 0.0
                    var worst = 0.0
                    var sample = ""
                    let w = base.width
                    let q = 4
                    let qW = minusBlocks.qW, qH = minusBlocks.qH
                    for i in stride(from: 0, to: base.rgba.count, by: 4) {
                        let px = (i / 4) % w, py = (i / 4) / w
                        // The bilinear footprint the apply pass samples: blocks at floor(u), floor(u)+1.
                        let u = (Float(px) + 0.5) / Float(q) - 0.5
                        let v = (Float(py) + 0.5) / Float(q) - 0.5
                        let x0 = max(0, min(qW - 1, Int(floor(u))))
                        let x1 = max(0, min(qW - 1, x0 + 1))
                        let y0 = max(0, min(qH - 1, Int(floor(v))))
                        let y1 = max(0, min(qH - 1, y0 + 1))
                        let windowMin = min(minusBlocks.values[y0 * qW + x0],
                                            minusBlocks.values[y0 * qW + x1],
                                            minusBlocks.values[y1 * qW + x0],
                                            minusBlocks.values[y1 * qW + x1])
                        let windowNormal = ev >= 0 || windowMin >= normalFloor
                        for c in 0..<3 {
                            let b = Float(base.rgba[i + c])
                            let expected = b * g
                            let expectedHalf = Float16(expected)
                            let tol = Float(expectedHalf.ulp)
                            let actual = Float(exposed.rgba[i + c])
                            let delta = abs(actual - expected)
                            let strict = windowNormal && b >= normalFloor && expected >= normalFloor
                            if strict {
                                if delta > tol {
                                    if over == 0 {
                                        sample = String(format: "base %.7g → 期望 %.7g · 实际 %.7g · 窗口最小 %.7g · 像素 %d 通道 %d · tol %.3g",
                                                        b, expected, actual, windowMin, i / 4, c, tol)
                                    }
                                    over += 1
                                }
                                if tol > 0 { worst = max(worst, Double(delta / tol)) }
                            } else if delta > subnormalTolerance {
                                subnormalOver += 1
                                subnormalWorst = max(subnormalWorst, Double(delta))
                            }
                        }
                    }
                    print(String(format: "COMMUTE · %@ · D=%.0f · E=%+.0f · max %.1f ULP · 超限 %d · 次正规 %d (max %.3g) · %@",
                                 name, d, ev, worst, over, subnormalOver, subnormalWorst, sample))
                    XCTAssertEqual(over, 0, "\(name) D=\(d) E=\(ev)：曝光与去雾必须可交换（1 ULP）")
                    XCTAssertEqual(subnormalOver, 0,
                                   "\(name) D=\(d) E=\(ev)：次正规估计窗的绝对差必须 ≤ leastNormal/2")
                }
            }
        }
        if available == 0 { throw XCTSkip("需要三张参考原片") }
    }

    // MARK: - 2. E = 0 逐字节不变

    /// SHA of the scene-linear frame at `exposure = 0`. The normalization is `I / g`, and `g = 1` at
    /// EV 0, so the stage must not move a single bit for a given arithmetic.
    ///
    /// 2026-10-31 — the six **positive** entries were re-recorded: `t` now comes from the guided veil,
    /// so `dehaze > 0` renders different pixels by design (that is why `AlgorithmVersion.dehaze` moved
    /// 6 → 7). The four **negative** entries are the pre-2026-10-31 bytes, unchanged to the digit: the
    /// haze-adding branch never read `t`, and this test's actual claim — that `g = 1` is an exact
    /// identity for the 141 normalization — is now checked against the current arithmetic.
    /// The same day, later: the six positive entries moved **again** when 130's fog participation
    /// became symmetric about the airlight (`w` now also fades within `A`'s own resolution). Again a
    /// fingerprint of the current arithmetic and not a golden: the four negative hashes still match
    /// to the digit, which is the evidence that the new fade reaches the recovery and nothing else.
    private static let e0SHA: [String: String] = [
        "foggy·-100": "0cfbcd45e29b430becf3580355f9ce6784f62d6f8c40e48a10de612b565ac847",
        "foggy·-60": "9606e7fae6a803fec18c83ff10c8fefd8a815602f407ff0a39833f887835f6ba",
        "foggy·20": "38b521e8371a542587d95e519ff0e1f40639c324d8038bd357a5c857d9c20d34",
        "foggy·60": "33ac7bca31851c59b253183bbf126112c5346269268cc057924e299a53b313ba",
        "foggy·100": "3119ea808727ce986d27e62994e7a6b3d1cfa2c70caa7fec5b05dfd9e833806d",
        "chroma·-100": "d214aa71558eeffbffaacbdcf11f3a0da44bb08fdd96b234796458c23d559272",
        "chroma·-60": "6015c989af2f6f905e0dd3db3068e770b0ef0de5a3fc78e8b2a302632da071c4",
        "chroma·20": "3a29821b67bca34a2773bebb569ef01579c8c3026bb8c35266bf008a01f51592",
        "chroma·60": "fdce68d4ce11440541831c6b132d39e9e49c8f3c88cefd4cf0ef6f9bca0a7877",
        "chroma·100": "fd7aed92dfcd15f81778ab05ae17c44a05011949c4742836b255ff1808382191",
    ]

    func testZeroExposureKeepsTheStageByteIdentical() throws {
        let frameSets: [(String, LinearImage)] = [
            ("foggy", foggy(landscape())),
            ("chroma", colouredBlocks()),
        ]
        for (name, image) in frameSets {
            let graph = try makeGraph(image, identity: "dehaze-exposure-e0-\(name)")
            for d in [-100.0, -60.0, 20.0, 60.0, 100.0] {
                let frame = try linearRender(graph, edit(exposure: 0, dehaze: d))
                let shaLo = frame.sha256()
                let key = String(format: "%@·%.0f", name, d)
                print("E0 · \(key) · \(shaLo)")
                XCTAssertEqual(shaLo, Self.e0SHA[key],
                               "141 不许动 E = 0 的去雾（g = 1 必须是逐字节恒等）")
            }
        }
    }

    // MARK: - 5. 不再变空操作

    func testDehazeDoesNotBecomeANoOpAtPlusFourEV() throws {
        let frames = [
            ("DJI_air3_2250_D", NSString(string: "~/Desktop/US/DJI_air3_2250_D.dng").expandingTildeInPath),
            ("L1030437", NSString(string: "~/Desktop/test/L1030437.dng").expandingTildeInPath),
        ]
        var available = 0
        for (name, path) in frames {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            available += 1
            let graph = try makeGraph(try decode(path), identity: "dehaze-exposure-plus4-\(name)")
            let four = try linearRender(graph, edit(exposure: 4, dehaze: 0))
            let fourD = try linearRender(graph, edit(exposure: 4, dehaze: 100))
            let gain = Float(pow(2.0, 4.0))
            let d4 = darkChannelMean(four, gain: gain, q: 4)
            let d4D = darkChannelMean(fourD, gain: gain, q: 4)
            let d15 = darkChannelMean(four, gain: gain, q: 15)
            let d15D = darkChannelMean(fourD, gain: gain, q: 15)
            print(String(format: "PLUS4 · %@ · 暗通道 q4 %.5f→%.5f (%+.1f%%) · q15 %.5f→%.5f (%+.1f%%) · differ %@",
                         name, d4, d4D, (d4D / d4 - 1) * 100,
                         d15, d15D, (d15D / d15 - 1) * 100,
                         four.sha256() == fourD.sha256() ? "NO" : "YES"))
            XCTAssertNotEqual(four.sha256(), fourD.sha256(),
                              "\(name)：E = +4 时 D = 100 与 D = 0 不许逐位相同（141 前的空操作）")
            if name == "L1030437" {
                // 135's veil effectiveness on the frame that actually carries white detail: a real
                // haze removal must still take the dark channel down materially. (DJI is the no-op
                // reproduction frame — its white has no detail, so it is not the fog measurement.)
                XCTAssertLessThanOrEqual(d4D / d4, 0.70,
                                         String(format: "L1030437：D = 100 的暗通道必须比 D = 0 低 ≥ 30%%（实测 %+.1f%%）",
                                                (d4D / d4 - 1) * 100))
                XCTAssertLessThanOrEqual(d15D / d15, 0.70,
                                         String(format: "L1030437：q15 暗通道也必须低 ≥ 30%%（实测 %+.1f%%）",
                                                (d15D / d15 - 1) * 100))
            }
        }
        if available == 0 { throw XCTSkip("需要 DJI_air3_2250_D / L1030437") }
    }
}
