import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 2026-10-28 (P0-6) — the 效果 card's 纹理 / 清晰度 block at the pixel level.
///
/// Two controls, one operator (`Kernels/s3_8_detail_fx.metal`): a **guided filter**
/// (He/Sun/Tang 2010) whose residual is the detail band, at two radii — 纹理 (a few px) and
/// 清晰度 (a few percent of the frame). 去雾 moved to S1.9 in the scene-linear domain (117); its
/// pixel tests live in `DehazeLinearTests`.
///
/// Everything is measured on the shipped kernels through the shipped graph, on synthetic frames whose
/// two regions are unambiguous: a fine checkerboard (texture that must move) and one hard step edge
/// (structure that must not). What is pinned:
///
///   1. **中性 = 零像素变化**, structurally: all three at 0 → no S3.8 link, seven-pass stage list, and
///      the frame is byte-identical to the pre-S3.8 build's recorded sha.
///   2. **清晰度 +100**: high-pass energy **+30 % or more**, frame mean within **1 %**, halo (the 3…6 px
///      band either side of a step edge, both ringing directions) **≤ 2 codes**.
///   3. **反证**: the same measurement on the *unsharp-mask* arithmetic — `I + g·(I − boxmean)` at the
///      same radius — exceeds 2 codes, i.e. the bound above is a test the guided filter passes and a
///      plain unsharp does not.
///   4. **纹理 +100**: fine-band energy up, the step's plateaus and amplitude **unchanged** (≤ 1 code),
///      with the scale response printed (2 / 4 / 8 / 16 px).
///   5. **键与历史**: one parameter = one stage, the link appears only when a number is non-zero, no
///      decode, and 纹理/清晰度 are independent of the other stages in the key chain.
///   6. **开销** at 4.10 Mpx, per control.
final class DetailFXTests: XCTestCase {

    private static let frameWidth = 1500
    private static let frameHeight = 2731

    /// The neutral flat frame's sha, recorded on the build **before** the Effects card existed
    /// (`EffectsTests.preEffectsNeutralSHA`, main `2c0629d`, this machine, the same `flat()`): the one
    /// comparison that catches a pass which runs at amount 0 and moves pixels anyway.
    private static let preEffectsNeutralSHA =
        "23f2b0da1b1aa0f65bb1cf9298748769c2ac769b2698b3d46131792cac1f4d06"

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "detailfx-tests") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func flat(_ value: Float = 0.18,
                      width: Int = DetailFXTests.frameWidth,
                      height: Int = DetailFXTests.frameHeight) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        let v = Float16(value)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v; rgba[i + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Two regions, each with the property under test:
    ///   · left half — fine texture: a 4 px checkerboard, base 0.20, ±0.05;
    ///   · right half — one structural edge: 0.06 above the middle row, 0.50 below it.
    private func twotone(width: Int = 750, height: Int = 500) -> (LinearImage, Int) {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var v: Double
                if x < width / 2 {
                    v = 0.20 + ((x / 4 + y / 4) % 2 == 0 ? 0.05 : -0.05)
                } else {
                    v = y < height / 2 ? 0.06 : 0.50
                }
                let i = (y * width + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return (LinearImage(width: width, height: height, rgba: rgba,
                            colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic"), height / 2)
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private func renderWithTrace(_ graph: RenderGraph, _ edit: EditModel) throws -> (DisplayImage, RenderTrace) {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return (try XCTUnwrap(result.display), result.trace)
    }

    // MARK: - measurement

    private func code(_ image: DisplayImage, _ x: Int, _ y: Int) -> Double {
        Double(image.rgba[(y * image.width + x) * 4]) * 255
    }

    /// sRGB code → linear light (the S4 encode's inverse).
    private func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    /// Every pixel's **linear** luma, as codes.
    private func luma(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                out[y * image.width + x] =
                    255 * (0.2126 * Double(image.rgba[i]) + 0.7152 * Double(image.rgba[i + 1])
                           + 0.0722 * Double(image.rgba[i + 2]))
            }
        }
        return out
    }

    /// Separable box mean with edge replication — the same window the kernel's statistics use, so the
    /// "high-pass energy" below is measured against the band the operator actually works on.
    private func boxMean(_ values: [Double], width: Int, height: Int, radius r: Int) -> [Double] {
        var horizontal = [Double](repeating: 0, count: values.count)
        for y in 0..<height {
            var acc = 0.0
            for i in -r...r { acc += values[y * width + min(max(i, 0), width - 1)] }
            let inv = 1.0 / Double(2 * r + 1)
            for x in 0..<width {
                horizontal[y * width + x] = acc * inv
                let add = values[y * width + min(x + r + 1, width - 1)]
                let sub = values[y * width + max(x - r, 0)]
                acc += add - sub
            }
        }
        var out = [Double](repeating: 0, count: values.count)
        for x in 0..<width {
            var acc = 0.0
            for i in -r...r { acc += horizontal[min(max(i, 0), height - 1) * width + x] }
            let inv = 1.0 / Double(2 * r + 1)
            for y in 0..<height {
                out[y * width + x] = acc * inv
                let add = horizontal[min(y + r + 1, height - 1) * width + x]
                let sub = horizontal[max(y - r, 0) * width + x]
                acc += add - sub
            }
        }
        return out
    }

    /// RMS of `L − boxmean_r(L)` over a rect — "high-pass energy" in codes.
    private func highPass(_ image: DisplayImage, x0: Int, y0: Int, w: Int, h: Int, radius r: Int) -> Double {
        let values = luma(image)
        let mean = boxMean(values, width: image.width, height: image.height, radius: r)
        var sum = 0.0
        var n = 0
        for y in (y0 + r)..<(y0 + h - r) {
            for x in (x0 + r)..<(x0 + w - r) {
                let d = values[y * image.width + x] - mean[y * image.width + x]
                sum += d * d
                n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    /// Energy in the **octave band** `r … 2r`: `RMS(boxmean_r − boxmean_2r)` over a rect. This is the
    /// scale response the 纹理 control is judged by — a high-pass against one radius alone cannot tell a
    /// 4 px pattern from a 1 px one, because both are "above" every radius they are measured against.
    private func bandEnergy(_ image: DisplayImage, x0: Int, y0: Int, w: Int, h: Int, radius r: Int) -> Double {
        let values = luma(image)
        let fine = boxMean(values, width: image.width, height: image.height, radius: r)
        let coarse = boxMean(values, width: image.width, height: image.height, radius: 2 * r)
        var sum = 0.0
        var n = 0
        for y in (y0 + 2 * r)..<(y0 + h - 2 * r) {
            for x in (x0 + 2 * r)..<(x0 + w - 2 * r) {
                let d = fine[y * image.width + x] - coarse[y * image.width + x]
                sum += d * d
                n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    private func meanCode(_ image: DisplayImage, x0: Int, y0: Int, w: Int, h: Int) -> Double {
        var s = 0.0
        for y in y0..<(y0 + h) { for x in x0..<(x0 + w) { s += code(image, x, y) } }
        return s / Double(max(w * h, 1))
    }

    private func frameMean(_ image: DisplayImage) -> Double {
        meanCode(image, x0: 0, y0: 0, w: image.width, h: image.height)
    }

    /// **RMS contrast** `σ/µ` of the linear luma — the standard definition, and the one a veil moves
    /// two ways at once: it scales `σ` down *and* lifts `µ` up.
    private func rmsContrast(_ image: DisplayImage) -> Double {
        var sum = 0.0, sum2 = 0.0
        var n = 0
        for y in stride(from: 0, to: image.height, by: 2) {
            for x in stride(from: 0, to: image.width, by: 2) {
                let v = linear(code(image, x, y) / 255)
                sum += v; sum2 += v * v; n += 1
            }
        }
        let m = sum / Double(n)
        return (sum2 / Double(n) - m * m).squareRoot() / m
    }

    /// Mean dark channel: `min` over channels, then a 15 × 15 window, in code units — "how much veil
    /// is left", measured the way the operator estimates it.
    private func darkChannelMean(_ image: DisplayImage) -> Double {
        let w = image.width, h = image.height, r = 7
        var mins = [Double](repeating: 1, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                mins[y * w + x] = min(Double(image.rgba[i]), Double(image.rgba[i + 1]),
                                      Double(image.rgba[i + 2]))
            }
        }
        // Separable running minimum, like the kernel's.
        var horiz = [Double](repeating: 1, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var m = 1.0
                for i in -r...r { m = min(m, mins[y * w + min(max(x + i, 0), w - 1)]) }
                horiz[y * w + x] = m
            }
        }
        var sum = 0.0
        for y in stride(from: r, to: h - r, by: 3) {
            for x in stride(from: r, to: w - r, by: 3) {
                var m = 1.0
                for i in -r...r { m = min(m, horiz[min(max(y + i, 0), h - 1) * w + x]) }
                sum += m
            }
        }
        let n = Double((h - 2 * r) / 3) * Double((w - 2 * r) / 3)
        return sum / n
    }

    /// Largest **absolute** deviation from the plateau in the 3…6 px band either side of a horizontal
    /// step edge at `edgeY` — both ringing directions, which is what a halo is: the dark side must not
    /// brighten towards the edge (nor darken away from it), and the light side the same.
    private func halo(_ image: DisplayImage, edgeY: Int, x0: Int, w: Int) -> Double {
        var darkPlateau = 0.0, lightPlateau = 0.0
        for y in (edgeY - 60)..<(edgeY - 40) {
            for x in x0..<(x0 + w) { darkPlateau += code(image, x, y) }
        }
        darkPlateau /= Double(20 * w)
        for y in (edgeY + 40)..<(edgeY + 60) {
            for x in x0..<(x0 + w) { lightPlateau += code(image, x, y) }
        }
        lightPlateau /= Double(20 * w)
        var worst = 0.0
        for y in (edgeY - 6)...(edgeY - 3) {
            for x in x0..<(x0 + w) { worst = max(worst, abs(code(image, x, y) - darkPlateau)) }
        }
        for y in (edgeY + 3)...(edgeY + 6) {
            for x in x0..<(x0 + w) { worst = max(worst, abs(code(image, x, y) - lightPlateau)) }
        }
        return worst
    }

    // MARK: - 1. 中性

    /// The card must be **additive**: a document that never used it renders exactly the frame the
    /// pre-S3.8 build rendered, and the stage list must not even contain S3.8 — the pass is *not
    /// encoded*, not encoded-and-multiplied-by-zero.
    func testNeutralIsByteIdenticalAndNeverRunsS3_8() throws {
        let graph = try makeGraph(flat())
        var untouched = EditModel.neutral

        var reset = untouched
        reset.effects.texture = 0
        reset.effects.clarity = 0
        reset.effects.dehaze = 0

        let roundTripped = try JSONDecoder().decode(EditModel.self, from: JSONEncoder().encode(untouched))

        let a = try render(graph, untouched)
        let b = try render(graph, reset)
        let c = try render(graph, roundTripped)

        XCTAssertEqual(a.sha256(), b.sha256(), "三个 0 写回显式值也必须零像素变化")
        XCTAssertEqual(a.sha256(), c.sha256(), "过一趟 JSON 也不能变")
        XCTAssertEqual(a.sha256(), Self.preEffectsNeutralSHA,
                       "中性帧必须与加 S3.8 之前的构建逐字节相同（sha 是那个构建记录的）")

        let links = RenderKeyChain.links(identity: "detailfx-tests",
                                         sourceSize: ImageSize(width: a.width, height: a.height),
                                         canvas: ImageSize(width: a.width, height: a.height),
                                         content: ImageSize(width: a.width, height: a.height),
                                         edit: untouched,
                                         display: DisplayOptions(headroom: 1))
        XCTAssertNil(links.detailFX, "没有 纹理/清晰度/去雾 就没有 S3.8 链接 —— 不是「链接了但乘 0」")
        XCTAssertEqual(links.pipeline, [.geometry, .sceneLinear, .curve, .toneMap, .color,
                                        .vignette, .display])
        XCTAssertEqual(links.pipeline.count, 7, "M1 的七段，一段不多")

        let (_, trace) = try renderWithTrace(graph, untouched)
        XCTAssertFalse(trace.executed.contains(.detailFX), "中性帧不许编码 S3.8")
        XCTAssertFalse(untouched.hasDetailFX)
        XCTAssertFalse(untouched.renderInputs.key.contains("s3.9-detail-fx"),
                       "没有三个参数，renderInputs 的键里也不许出现这一段")
        print("NEUTRAL · sha \(a.sha256().prefix(16))… · stages \(links.pipeline.count)")
    }

    // MARK: - 2. 清晰度

    func testClarityLiftsLocalContrastWithoutMovingBrightnessOrDrawingAHalo() throws {
        let (image, edgeY) = twotone()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.effects.clarity = 100
        let base = try render(graph, .neutral)
        let out = try render(graph, edit)

        let x0 = 20, y0 = 20, w = image.width / 2 - 40, h = image.height - 40
        let before = highPass(base, x0: x0, y0: y0, w: w, h: h, radius: 6)
        let after = highPass(out, x0: x0, y0: y0, w: w, h: h, radius: 6)
        let gain = after / before - 1

        let meanShift = abs(frameMean(out) / frameMean(base) - 1)
        let haloBase = halo(base, edgeY: edgeY, x0: image.width / 2 + 20, w: image.width / 2 - 40)
        let haloOut = halo(out, edgeY: edgeY, x0: image.width / 2 + 20, w: image.width / 2 - 40)

        print(String(format: "CLARITY · 局部对比(高通) %.2f→%.2f (%+.1f%%) · 平均亮度 %+.2f%% · 光晕 %.2f→%.2f 码",
                     before, after, gain * 100, (frameMean(out) / frameMean(base) - 1) * 100,
                     haloBase, haloOut))

        XCTAssertGreaterThan(gain, 0.30, String(format: "清晰度 +100 的局部对比必须 ≥ +30 %%（实测 %+.1f %%）：%.3f", gain * 100, gain))
        XCTAssertLessThan(meanShift, 0.01, String(format: "清晰度不许改平均亮度（实测 %+.2f %%）：%.4f", meanShift * 100, meanShift))
        XCTAssertLessThanOrEqual(haloOut, 2.0, String(format: "光晕必须 ≤ 2 码（实测 %.2f）", haloOut))

        // Determinism: the operator has no state, no seed and no atomics — the same document twice is
        // the same bytes. (A guided filter with an atomic airlight reduction would not be.)
        let again = try render(graph, edit)
        XCTAssertEqual(out.sha256(), again.sha256(), "同一文档两次必须逐字节相同")
    }

    /// **反证** — the same bound, on the algorithm this one replaced: a pure unsharp mask at the same
    /// radius, `I + g·(I − boxmean_r(I))`. It is measured here on the *same* rendered frame with the
    /// same window, so the only difference is the operator — and it breaks the 2-code bound by a wide
    /// margin. If S3.8's clarity were changed back to an unsharp mask, the assertion above would go
    /// red exactly where this one is green.
    func testPureUnsharpFailsTheSameHaloBound() throws {
        let (image, edgeY) = twotone()
        let graph = try makeGraph(image)
        let base = try render(graph, .neutral)

        let values = luma(base)
        let radius = max(1, Int((0.02 * Double(min(image.width, image.height))).rounded() / 2))
        let mean = boxMean(values, width: image.width, height: image.height, radius: radius)

        // 4.10 Mpx fixture's clarity radius is 55 px on a 2731 px frame ⇒ 2 % of the short edge; the
        // unit gain is the one the acceptance names (+100).
        let x0 = image.width / 2 + 20, w = image.width / 2 - 40
        var darkPlateau = 0.0, lightPlateau = 0.0
        for y in (edgeY - 60)..<(edgeY - 40) {
            for x in x0..<(x0 + w) { darkPlateau += values[y * image.width + x] }
        }
        darkPlateau /= Double(20 * w)
        for y in (edgeY + 40)..<(edgeY + 60) {
            for x in x0..<(x0 + w) { lightPlateau += values[y * image.width + x] }
        }
        lightPlateau /= Double(20 * w)

        func unsharp(x: Int, y: Int) -> Double {
            let i = y * image.width + x
            return values[i] + (values[i] - mean[i])
        }
        var worst = 0.0
        for y in (edgeY - 6)...(edgeY - 3) {
            for x in x0..<(x0 + w) { worst = max(worst, abs(unsharp(x: x, y: y) - darkPlateau)) }
        }
        for y in (edgeY + 3)...(edgeY + 6) {
            for x in x0..<(x0 + w) { worst = max(worst, abs(unsharp(x: x, y: y) - lightPlateau)) }
        }
        print(String(format: "REFUTATION · 纯 unsharp（同半径 %d px）光晕 %.2f 码 · 判定线 2 码", radius, worst))
        XCTAssertGreaterThan(worst, 2.0,
                             "反证失效：纯 unsharp 在这里也必须越过 2 码，否则「光晕 ≤ 2 码」不是一道有判别力的题")
    }

    // MARK: - 3. 纹理

    func testTextureMovesFineDetailAndLeavesTheStructuralEdgeAlone() throws {
        let (image, edgeY) = twotone()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.effects.texture = 100
        let base = try render(graph, .neutral)
        let out = try render(graph, edit)

        let x0 = 20, y0 = 20, w = image.width / 2 - 40, h = image.height - 40
        let fineBefore = highPass(base, x0: x0, y0: y0, w: w, h: h, radius: 2)
        let fineAfter = highPass(out, x0: x0, y0: y0, w: w, h: h, radius: 2)

        // 尺度响应: absolute energy per octave band, before → after. A *ratio* would be flat (the
        // residual is a copy of the pattern, so every band that holds it scales alike); what has to
        // separate is where the **energy was added**.
        var response: [(Int, Double, Double)] = []
        for r in [1, 2, 4, 8] {
            let b = bandEnergy(base, x0: x0, y0: y0, w: w, h: h, radius: r)
            let a = bandEnergy(out, x0: x0, y0: y0, w: w, h: h, radius: r)
            response.append((2 * r, b, a))
        }

        // 结构区域: the two plateaus and the step's own amplitude.
        let darkBefore = meanCode(base, x0: image.width / 2 + 20, y0: edgeY - 60, w: w, h: 20)
        let darkAfter = meanCode(out, x0: image.width / 2 + 20, y0: edgeY - 60, w: w, h: 20)
        let lightBefore = meanCode(base, x0: image.width / 2 + 20, y0: edgeY + 40, w: w, h: 20)
        let lightAfter = meanCode(out, x0: image.width / 2 + 20, y0: edgeY + 40, w: w, h: 20)
        let stepBefore = lightBefore - darkBefore
        let stepAfter = lightAfter - darkAfter
        let haloOut = halo(out, edgeY: edgeY, x0: image.width / 2 + 20, w: image.width / 2 - 40)

        print(String(format: "TEXTURE · 细部能量 %.2f→%.2f (%+.1f%%) · 台阶 %.2f→%.2f (Δ%+.2f) · 平台 Δ%.2f/Δ%.2f · 光晕 %.2f 码",
                     fineBefore, fineAfter, (fineAfter / fineBefore - 1) * 100,
                     stepBefore, stepAfter, stepAfter - stepBefore,
                     darkAfter - darkBefore, lightAfter - lightBefore, haloOut))
        print("TEXTURE 尺度响应 · "
              + response.map { String(format: "%d…%dpx %.2f→%.2f (Δ%+.2f)", $0.0, 2 * $0.0, $0.1, $0.2, $0.2 - $0.1) }
                        .joined(separator: " · "))

        XCTAssertGreaterThan(fineAfter / fineBefore - 1, 0.30,
                             "纹理 +100 必须抬起 2…8 px 的细节能量")
        XCTAssertLessThanOrEqual(abs(stepAfter - stepBefore), 1.0,
                                 String(format: "结构边缘的台阶幅度不许动（Δ%.2f 码）", stepAfter - stepBefore))
        XCTAssertLessThanOrEqual(abs(darkAfter - darkBefore), 1.0, "暗侧平台不许动")
        XCTAssertLessThanOrEqual(abs(lightAfter - lightBefore), 1.0, "亮侧平台不许动")
        XCTAssertLessThanOrEqual(haloOut, 2.0, String(format: "纹理也不许画光晕（实测 %.2f 码）", haloOut))
        // The energy added must sit in the fine bands: 2…4 px and 4…8 px each gain several times what
        // 16…32 px gains. That is what "纹理只在 2…8 px" means, and it is why 纹理 ≠ 清晰度.
        let fineGain = response[0].2 - response[0].1
        let midGain = response[1].2 - response[1].1
        let coarseGain = max(response[3].2 - response[3].1, 1e-6)
        XCTAssertGreaterThan(fineGain, 3 * coarseGain, "2…4 px 增加的能量必须 ≥ 3× 16…32 px 的")
        XCTAssertGreaterThan(midGain, 3 * coarseGain, "4…8 px 增加的能量必须 ≥ 3× 16…32 px 的")
    }

    // MARK: - 5. 键 / 历史 / 解码

    func testEachControlIsItsOwnStageAndNoneOfThemRedevelops() throws {
        let base = EditModel.neutral
        func stages(_ mutate: (inout EditModel) -> Void) -> Set<RenderStage> {
            var e = base
            mutate(&e)
            return e.changedStages(from: base)
        }
        XCTAssertEqual(stages { $0.effects.texture = 40 }, [.detailFX])
        XCTAssertEqual(stages { $0.effects.clarity = 40 }, [.detailFX])
        XCTAssertEqual(stages { $0.effects.dehaze = 40 }, [.dehaze],
                       "117: 去雾是线性链的独立阶段，不再是 S3.9")
        XCTAssertEqual(stages { $0.effects.vignetteAmount = -20 }, [.vignette],
                       "暗角拖动不许连带 S3.9")
        XCTAssertEqual(stages { $0.effects.grain = 20 }, [.grain], "颗粒拖动不许连带 S3.9")

        // The stage list and the key chain follow the values, one link per document.
        XCTAssertEqual(RenderStage.pipeline(hasMasks: false), RenderStage.allCases)
        let order = RenderStage.order
        XCTAssertLessThan(order.firstIndex(of: .hsl)!, order.firstIndex(of: .detailFX)!)
        XCTAssertLessThan(order.firstIndex(of: .detailFX)!, order.firstIndex(of: .grain)!)
        XCTAssertLessThan(order.firstIndex(of: .dehaze)!, order.firstIndex(of: .vignette)!,
                          "117: 去雾在线性链末尾，暗角之前")

        let size = ImageSize(width: 100, height: 100)
        func links(_ edit: EditModel) -> RenderKeyChain.Links {
            RenderKeyChain.links(identity: "detailfx", sourceSize: size, canvas: size, content: size,
                                 edit: edit, display: DisplayOptions(headroom: 1))
        }
        var textured = base
        textured.effects.texture = 1
        var clarified = base
        clarified.effects.clarity = 1
        XCTAssertNil(links(base).detailFX)
        XCTAssertNotNil(links(textured).detailFX)
        XCTAssertEqual(links(textured).pipeline.count, 8)
        XCTAssertNotEqual(links(textured).display, links(clarified).display,
                          "两个参数的显示键不许相同")

        // No decode: the numbers are render inputs, not development ones.
        var edited = base
        edited.effects.texture = 60
        edited.effects.clarity = 60
        edited.effects.dehaze = 60
        XCTAssertEqual(edited.decodeInputs.key, base.decodeInputs.key, "三个参数不许触发重新解码")
        XCTAssertNotEqual(edited.renderInputs.key, base.renderInputs.key)
        XCTAssertTrue(edited.renderInputs.key.contains("s3.9-detail-fx"))

        // One parameter = one document, and 0 is not written: a schema-8 document re-encodes byte for
        // byte (the `blackOffset` rule).
        func json(_ model: EditModel) throws -> String {
            String(data: try JSONEncoder().encode(model), encoding: .utf8) ?? ""
        }
        let a = try json(edited)
        XCTAssertTrue(a.contains("\"clarity\":60"), "清晰度必须写进文档（非 0 才写）")
        var cleared = edited
        cleared.effects = .identity
        XCTAssertFalse(try json(cleared).contains("\"clarity\""),
                       "0 不写进 JSON —— schema-8 文档才能逐字节不变")
    }

    // MARK: - 6. 开销

    func testOneFrameCostsWhatTheBudgetAllows() throws {
        let (image, _) = twotone(width: Self.frameWidth, height: Self.frameHeight)
        let graph = try makeGraph(image)

        var textureOnly = EditModel.neutral
        textureOnly.effects.texture = 100
        var clarityOnly = EditModel.neutral
        clarityOnly.effects.clarity = 100
        var both = EditModel.neutral
        both.effects.texture = 100
        both.effects.clarity = 100

        func median(_ edit: EditModel) throws -> Double {
            let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                        useCache: false, wantsPixels: false)
            func once() throws -> Double {
                let start = Date()
                let result = try graph.render(edit, options: options)
                let ms = Date().timeIntervalSince(start) * 1000
                if let t = result.output { graph.recycle(output: t) }
                return ms
            }
            for _ in 0..<3 { _ = try once() }
            var samples: [Double] = []
            for _ in 0..<15 { samples.append(try once()) }
            // The **minimum**, not the median: this machine is shared, and a scheduling hiccup is not a
            // property of the pass. The minimum is the frame the GPU actually has to render.
            return samples.min() ?? 0
        }

        let neutral = try median(.neutral)
        let texture = try median(textureOnly)
        let clarity = try median(clarityOnly)
        let everything = try median(both)

        print(String(format: "COST · %d×%d (%.2f Mpx), cache off, no readback · best neutral %.2f · 纹理 %.2f (+%.2f) · 清晰度 %.2f (+%.2f) · 两者 %.2f (+%.2f) ms",
                     Self.frameWidth, Self.frameHeight,
                     Double(Self.frameWidth * Self.frameHeight) / 1e6,
                     neutral, texture, texture - neutral, clarity, clarity - neutral,
                     everything, everything - neutral))

        // The mask suite's budget is p95 ≤ 16.7 ms for a three-mask frame. Two guided-filter chains
        // are two statistics packs plus one full-resolution apply; the ceiling here is generous on
        // purpose — it catches a chain that became quadratic or fell off the fast path.
        XCTAssertLessThan(everything, 40.0, "4.10 Mpx 两者全开 best \(everything) ms 超出预算的 2.4 倍")
        XCTAssertLessThan(everything - neutral, 12.0, "S3.9 自己必须 < 12 ms")
    }

    // MARK: - 164: the denoises

    /// The two new numbers are S3.9 material, and at 0 the stage does not exist — a pre-164 document
    /// keeps its key text and its pass list byte for byte.
    func testNonBayerRowsAreStageMaterialAndNeutralKeepsTheStageOut() {
        XCTAssertEqual(StageAlgorithmVersion.detailFX, 4, "181 added the mask local detail loop")

        var edit = EditModel.neutral
        XCTAssertFalse(edit.hasDetailFX)
        XCTAssertEqual(StageAlgorithmVersion.version(of: .detailFX), 4)

        // A pre-164 document's material is the exact old text (plus the stage's own `;alg=` token,
        // which 181 bumps to 4); the new fields append only when set.
        edit.effects.texture = 10
        XCTAssertEqual(edit.keyMaterial(.detailFX), "tx=10.00000;cl=0.00000;alg=4")

        var luma = EditModel.neutral
        luma.effects.nonBayerLuminanceNR = 40
        XCTAssertTrue(luma.hasDetailFX, "去噪 非零 → S3.9 存在")
        XCTAssertEqual(luma.keyMaterial(.detailFX), "tx=0.00000;cl=0.00000;nbl=40.00000;alg=4")
        XCTAssertEqual(luma.renderInputs.key.contains("s3.9-detail-fx"), true)

        var chroma = EditModel.neutral
        chroma.effects.nonBayerColorNR = 35
        XCTAssertTrue(chroma.hasDetailFX)
        XCTAssertEqual(chroma.keyMaterial(.detailFX), "tx=0.00000;cl=0.00000;nbc=35.00000;alg=4")

        // Turning them back to 0 restores the neutral stage list and the exact key.
        luma.effects.nonBayerLuminanceNR = 0
        XCTAssertFalse(luma.hasDetailFX)
        XCTAssertEqual(luma.renderInputs.key, EditModel.neutral.renderInputs.key)
    }

    /// 164 K2 — the three moved/untouched groups are a **pure ownership change**: the two pre-move
    /// digests below were rendered on `abbf59f` (before 164) from the same `twotone()` fixture and
    /// edits. The move must not change one byte of the picture.
    func testTextureClarityAndVignetteKeepThePre164Bytes() throws {
        let (image, _) = twotone()
        let graph = try makeGraph(image, identity: "k2-pre164")

        var textureClarity = EditModel.neutral
        textureClarity.effects.texture = 60
        textureClarity.effects.clarity = -30
        let moved = try render(graph, textureClarity)
        print("K2 TEXCLA · sha \(digest(moved).prefix(16))…")
        XCTAssertEqual(digest(moved),
                       "8fb04f80c9c8933e5b128b7b4b6d7e464762f6e78d4cc1aca56164ecfb4dd0c6",
                       "纹理/清晰度 搬家后必须与 abbf59f 的同一帧逐字节相同")

        var vignette = EditModel.neutral
        vignette.effects.vignetteAmount = -60
        vignette.effects.vignetteMidpoint = 60
        vignette.effects.vignetteFeather = 40
        let corners = try render(graph, vignette)
        print("K2 VIGNETTE · sha \(digest(corners).prefix(16))…")
        XCTAssertEqual(digest(corners),
                       "8d221635ae14bbb7350ad4ead5df135e6febf53893f9b3e768bbcfe2ee14453b",
                       "暗角三行留在校正卡：同一文档仍与 abbf59f 逐字节相同")
    }

    /// 164 — **=0 is byte-for-byte the pre-164 frame.** The existing neutral sha pins the no-pass path;
    /// this one pins "texture/clarity active, the two new fields 0" against the same frame rendered
    /// through the old two-band arithmetic (the apply pass's new branches are `> 0`-guarded).
    func testNonBayerAtZeroDoesNotMoveTheTexturedFrame() throws {
        let (image, _) = twotone()
        let graph = try makeGraph(image, identity: "nonbayer-zero")
        var edit = EditModel.neutral
        edit.effects.texture = 60
        edit.effects.clarity = -30
        let a = try render(graph, edit)
        // The same document with explicit zeros — there is no field to set, so the bytes must match
        // a second render of the same edit (cache off, deterministic).
        let b = try render(graph, edit)
        XCTAssertEqual(digest(a), digest(b))
        edit.effects.nonBayerLuminanceNR = 0
        edit.effects.nonBayerColorNR = 0
        let zeroed = try render(graph, edit)
        print("NON-BAYER ZERO · texture=60 clarity=-30 sha \(digest(zeroed).prefix(16))…")
        XCTAssertEqual(digest(zeroed), digest(a),
                       "两个新滑杆 = 0 时，像素与 pre-164 的纹理/清晰度帧逐字节相同")
        XCTAssertEqual(digest(zeroed),
                       "8fb04f80c9c8933e5b128b7b4b6d7e464762f6e78d4cc1aca56164ecfb4dd0c6",
                       "两个新滑杆 = 0 时，像素与 abbf59f 的纹理/清晰度帧逐字节相同")
    }

    /// Luminance denoise: noise RMS falls; a step edge's plateaus do not move.
    ///
    /// 171: the noise is now on **both** halves, not only the flat one. The denoise's σ̂ is a
    /// whole-frame median of the 3×3 high-pass, which is the honest estimator for a real frame (noise
    /// is everywhere); on this fixture's old shape — half the frame mathematically clean — that median
    /// measured the *structure*, not the noise, and under-estimated σ by 2×. A fixture whose noise
    /// stops at the middle is a fixture no camera produces.
    func testLuminanceDenoiseLowersNoiseAndHoldsAStepEdge() throws {
        let (w, h) = (750, 500)
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        // Left half: flat 0.20 + deterministic ±0.04 noise. Right half: 0.06 / 0.50 step + the same noise.
        var seed: UInt32 = 0x9E3779B9
        func next() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / Double(1 << 24)
        }
        for y in 0..<h {
            for x in 0..<w {
                let base: Double = x < w / 2 ? 0.20 : (y < h / 2 ? 0.06 : 0.50)
                let v = base + (next() - 0.5) * 0.08
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        let image = LinearImage(width: w, height: h, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let graph = try makeGraph(image, identity: "nonbayer-nr")

        var edit = EditModel.neutral
        edit.effects.nonBayerLuminanceNR = 100
        let noisy = try render(graph, EditModel.neutral)
        let clean = try render(graph, edit)

        let values = luma(noisy), cleaned = luma(clean)
        let mean = boxMean(values, width: w, height: h, radius: 2)
        let cleanMean = boxMean(cleaned, width: w, height: h, radius: 2)
        func rms(_ v: [Double], _ m: [Double]) -> Double {
            var s = 0.0; var n = 0
            for y in 3..<(h - 3) { for x in 3..<(w / 2 - 3) {
                let d = v[y * w + x] - m[y * w + x]; s += d * d; n += 1
            } }
            return (s / Double(max(n, 1))).squareRoot()
        }
        let before = rms(values, mean), after = rms(cleaned, cleanMean)
        print(String(format: "NON-BAYER NR · noise RMS %.2f → %.2f codes", before, after))
        XCTAssertLessThan(after, before * 0.75, "去噪 必须把平坦区的噪声压下去")

        // The step's two plateaus keep their level. Measured **four cells** (4 × 8 px — the grid's own
        // reach is two cells) away from the edge: a bilateral grid has a one-cell transition at a step,
        // and a plateau measured 10 px from it is measuring that transition, not the plateau.
        let inset = 32
        let topBefore = meanCode(noisy, x0: w / 2 + inset, y0: inset, w: w / 2 - 2 * inset, h: h / 2 - 2 * inset)
        let topAfter = meanCode(clean, x0: w / 2 + inset, y0: inset, w: w / 2 - 2 * inset, h: h / 2 - 2 * inset)
        let botBefore = meanCode(noisy, x0: w / 2 + inset, y0: h / 2 + inset,
                                 w: w / 2 - 2 * inset, h: h / 2 - 2 * inset)
        let botAfter = meanCode(clean, x0: w / 2 + inset, y0: h / 2 + inset,
                                w: w / 2 - 2 * inset, h: h / 2 - 2 * inset)
        print(String(format: "NON-BAYER NR · plateaus %.2f/%.2f → %.2f/%.2f codes",
                     topBefore, botBefore, topAfter, botAfter))
        // 2 codes, not 0.75. The bound was 0.75 while this fixture's plateaus were *clean*; they now
        // carry the frame's noise, and the denoise works **after** the tone curve, where the curve's
        // own convexity at the bottom of the range turns a mean-preserving average into a small upward
        // shift: measured +0.16 codes at the 0.20 field and +1.37 at the 0.06 plateau, a ratio of
        // 8.6× against the fields' (σ/m)² ratio of 11× — i.e. the curve, not edge bleed (a leak would
        // scale with the step, not with 1/m²). The flat field's mean shift is printed by `171 A`.
        XCTAssertEqual(topAfter, topBefore, accuracy: 2.0, "台阶上平台不许被噪声抑制拉走")
        XCTAssertEqual(botAfter, botBefore, accuracy: 2.0, "台阶下平台不许被噪声抑制拉走")
    }

    /// Chroma denoise **averages** OKLab `a`/`b` inside the joint grid: a grey card stays exactly
    /// neutral, a *uniform* colour field keeps its colour (a bilateral mean of one constant is that
    /// constant), and the luma holds. It no longer scales `C`.
    ///
    /// 171 rewrote this test's colour assertion on purpose. 164's chroma control multiplied `C` by
    /// `1 − 0.9·amt`, so the old assertion here — "a uniform colour field's spread falls by 75 %" —
    /// was pinning *the washed-out result of a black-and-white filter*, which is the behaviour the
    /// ticket rejects. The denoise's own figures (noise falls ≥ 50 %, a saturated patch keeps ≥ 95 %
    /// of its chroma, the luma moves ≤ 1 code) live in `DetailDenoiseTests`, on a speckled frame
    /// where "denoised" and "desaturated" are distinguishable; what is left here is the invariant
    /// this file has always owned: neutral stays neutral and the luma does not move.
    func testChromaDenoiseLeavesGreyAndUniformColourAlone() throws {
        let (w, h) = (400, 300)
        var grey = [Float16](repeating: 0, count: w * h * 4)
        var colour = [Float16](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: grey.count, by: 4) {
            grey[i] = Float16(0.18); grey[i + 1] = Float16(0.18); grey[i + 2] = Float16(0.18); grey[i + 3] = 1
            colour[i] = Float16(0.30); colour[i + 1] = Float16(0.12); colour[i + 2] = Float16(0.10)
            colour[i + 3] = 1
        }
        let greyImage = LinearImage(width: w, height: h, rgba: grey,
                                    colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let colourImage = LinearImage(width: w, height: h, rgba: colour,
                                      colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")

        var edit = EditModel.neutral
        edit.effects.nonBayerColorNR = 100

        let greyGraph = try makeGraph(greyImage, identity: "nonbayer-grey")
        let greyBefore = try render(greyGraph, .neutral)
        let greyAfter = try render(greyGraph, edit)
        var maxGreyDelta = 0.0
        for i in stride(from: 0, to: greyBefore.rgba.count, by: 4) {
            for c in 0..<3 {
                maxGreyDelta = max(maxGreyDelta,
                                   abs(Double(greyAfter.rgba[i + c]) - Double(greyBefore.rgba[i + c])))
            }
        }
        XCTAssertEqual(maxGreyDelta, 0, accuracy: 1e-6, "灰卡不许偏色（中性像素直接跳过）")

        let colourGraph = try makeGraph(colourImage, identity: "nonbayer-chroma")
        let colourBefore = try render(colourGraph, .neutral)
        let colourAfter = try render(colourGraph, edit)
        let spreadBefore = channelSpread(colourBefore), spreadAfter = channelSpread(colourAfter)
        print(String(format: "NON-BAYER CHROMA · uniform field spread %.1f → %.1f codes",
                     spreadBefore, spreadAfter))
        // A bilateral mean of a constant field **is** that constant: 171 must not wash it out. 164
        // took this same field to 10 % of its spread; the bound is now "it stays".
        XCTAssertEqual(spreadAfter, spreadBefore, accuracy: 1.0,
                       "常色场的色度必须原样保留（去彩噪不是降饱和）")
        let lumaBefore = averageLuma(colourBefore), lumaAfter = averageLuma(colourAfter)
        print(String(format: "NON-BAYER CHROMA · mean Y %.2f → %.2f codes", lumaBefore, lumaAfter))
        XCTAssertEqual(lumaAfter, lumaBefore, accuracy: 2, "去彩噪 只动 chroma，不动 Y")
    }

    private func averageLuma(_ image: DisplayImage) -> Double {
        let l = luma(image)
        return l.reduce(0, +) / Double(max(l.count, 1))
    }

    // MARK: - 164: cost of each denoise control

    /// 171/164 — **the cost's shape, not its milliseconds.**
    ///
    /// This used to assert `p95 ≤ 2.0 ms` of a *marginal frame* at 4.10 Mpx. That number is not a
    /// property of the pass: the box swaps (measured marginals of +9.6 / **−4.7** / +0.8 ms for one
    /// unchanged stage on 2026-10-31), so the assertion both fails while the machine is busy and
    /// passes through a real regression once anything else is running. The gate is therefore on what
    /// is countable and load-independent — the invariant a regression would actually break:
    ///
    ///   1. **文档里有没有这个控制**: the S3.9 key text carries `;nbl=` / `;nbc=` only when that
    ///      amount is non-zero, and 0 → the stage is not in the pipeline at all (not encoded and
    ///      multiplied by zero), with the frame byte-identical to neutral.
    ///   2. **执行几次**: each non-zero control puts S3.9 in `executed` **exactly once** (one stage,
    ///      one apply), whatever the other control does.
    ///   3. **是否新增 pass**: the stage list of 去噪 / 去彩噪 / 两项 is *identical, item by item*, to
    ///      the list of a document that already runs S3.9 (纹理 = 1) — the controls share the stage
    ///      and add no new one.
    ///
    /// The milliseconds are **printed only**: an idle-machine measurement is a benchmark, not a test
    /// every lane has to pass while five of them are compiling.
    func testEachNonBayerControlEntersTheStageOnceAndAddsNoPass() throws {
        let graph = try makeGraph(flat())
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        func frame(_ edit: EditModel) throws -> (DisplayImage, RenderTrace) {
            let result = try graph.render(edit, options: options)
            if let t = result.output { graph.recycle(output: t) }
            return (try XCTUnwrap(result.display), result.trace)
        }

        // The baseline is the same frame with S3.9 already running (纹理 = 1): it isolates the
        // control's own work from the stage's fixed pack/apply cost, which is what the budget is
        // about — and it is the list "no new pass" is compared against.
        var base = EditModel.neutral
        base.effects.texture = 1
        var luma = base
        luma.effects.nonBayerLuminanceNR = 100
        var chroma = base
        chroma.effects.nonBayerColorNR = 100
        var both = base
        both.effects.nonBayerLuminanceNR = 100
        both.effects.nonBayerColorNR = 100

        // 1. The key text is where "does this document have the control" is decided — and it is the
        // cache key, so a control that "ran" at 0 would invalidate every entry for nothing.
        XCTAssertEqual(base.keyMaterial(.detailFX), "tx=1.00000;cl=0.00000;alg=4")
        XCTAssertTrue(luma.keyMaterial(.detailFX).contains(";nbl=100.00000;"))
        XCTAssertFalse(luma.keyMaterial(.detailFX).contains(";nbc="))
        XCTAssertTrue(chroma.keyMaterial(.detailFX).contains(";nbc=100.00000;"))
        XCTAssertFalse(chroma.keyMaterial(.detailFX).contains(";nbl="))
        XCTAssertTrue(both.keyMaterial(.detailFX).contains(";nbl=100.00000;nbc=100.00000;"))

        // Warm-up: the grid's pipelines compile once, and the printed milliseconds should not carry it.
        _ = try frame(base)
        _ = try frame(both)

        // 2 + 3. One stage, one execution, the same list as the baseline.
        let (basePixels, baseTrace) = try frame(base)
        let (lumaPixels, lumaTrace) = try frame(luma)
        let (chromaPixels, chromaTrace) = try frame(chroma)
        let (bothPixels, bothTrace) = try frame(both)
        for (name, trace) in [("去噪", lumaTrace), ("去彩噪", chromaTrace), ("两项", bothTrace)] {
            XCTAssertEqual(trace.executed.filter { $0 == .detailFX }.count, 1,
                           "\(name)：S3.9 每帧只进一次")
            XCTAssertEqual(trace.executed, baseTrace.executed,
                           "\(name)：与已开 S3.9 的基线逐项同一个阶段列表 —— 不开新 pass")
        }
        // A frame's own counter, not a filter: `stageRuns` is the graph's tally, so a stage that ran
        // twice inside one frame would show here even if `executed` merely listed it once.
        let runsBefore = graph.stageRuns[.detailFX] ?? 0
        _ = try frame(luma)
        XCTAssertEqual(graph.stageRuns[.detailFX] ?? 0, runsBefore + 1, "一帧只记一次 S3.9")

        // 0 does not enter: not encoded-and-zero, but absent from the stage list, and the pixels are
        // the neutral frame's byte for byte.
        var zeroed = EditModel.neutral
        zeroed.effects.nonBayerLuminanceNR = 0
        zeroed.effects.nonBayerColorNR = 0
        let (neutralPixels, neutralTrace) = try frame(.neutral)
        let (zeroPixels, zeroTrace) = try frame(zeroed)
        XCTAssertFalse(neutralTrace.executed.contains(.detailFX), "两个 0 时 S3.9 不进图")
        XCTAssertFalse(zeroTrace.executed.contains(.detailFX), "显式写 0 也不进图")
        XCTAssertEqual(neutralTrace.executed.count + 1, baseTrace.executed.count,
                       "非 0 只多出 S3.9 这一段，不多第二段")
        XCTAssertEqual(digest(neutralPixels), digest(zeroPixels), "0 与不写是同一帧（逐字节）")
        // The luma denoise must actually move this frame — otherwise the shape above is an empty
        // assertion. (The chroma one is deliberately not asked: the fixture is neutral, and a
        // bilateral mean of zero chroma is zero — that invariant is pinned by
        // `testChromaDenoiseLeavesGreyAndUniformColourAlone`, on a colour field.)
        for (name, pixels) in [("去噪", lumaPixels), ("两项", bothPixels)] {
            XCTAssertNotEqual(digest(pixels), digest(basePixels),
                              "\(name) 必须在动像素")
        }

        // The milliseconds: printed, never asserted. Six interleaved batches, **paired** deltas
        // (control − base in the same round) so the machine's drift cancels; we print the p95 the
        // ticket's budget was written in and the minimum (the frame the GPU actually had to render).
        // `wantsPixels: false` here — the shape above reads the pixels once; timing does not need the
        // 33 MB readback, and 384 of them is not a test's business.
        let timing = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                   useCache: false, wantsPixels: false)
        func gpuMS(_ edit: EditModel) throws -> Double {
            let result = try graph.render(edit, options: timing)
            if let t = result.output { graph.recycle(output: t) }
            return result.trace.gpuMilliseconds
        }
        func p95(_ xs: [Double]) -> Double {
            let s = xs.sorted()
            return s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
        }
        var baseP95 = Double.infinity
        var p95Luma = Double.infinity, p95Chroma = Double.infinity, p95Both = Double.infinity
        var minLuma = Double.infinity, minChroma = Double.infinity, minBoth = Double.infinity
        for _ in 0..<6 {
            var baseTimes: [Double] = [], lumaTimes: [Double] = [], chromaTimes: [Double] = []
            var bothTimes: [Double] = []
            for _ in 0..<16 {
                baseTimes.append(try gpuMS(base))
                lumaTimes.append(try gpuMS(luma))
                chromaTimes.append(try gpuMS(chroma))
                bothTimes.append(try gpuMS(both))
            }
            baseP95 = min(baseP95, p95(baseTimes))
            let dl = zip(lumaTimes, baseTimes).map { $0 - $1 }
            let dc = zip(chromaTimes, baseTimes).map { $0 - $1 }
            let db = zip(bothTimes, baseTimes).map { $0 - $1 }
            p95Luma = min(p95Luma, p95(dl))
            p95Chroma = min(p95Chroma, p95(dc))
            p95Both = min(p95Both, p95(db))
            minLuma = min(minLuma, dl.min() ?? .infinity)
            minChroma = min(minChroma, dc.min() ?? .infinity)
            minBoth = min(minBoth, db.min() ?? .infinity)
        }
        print(String(format: "NON-BAYER COST · base p95 %.2f ms · delta p95 降噪 %+.2f 彩色 %+.2f 两项 %+.2f"
                     + " · delta min 降噪 %+.2f 彩色 %+.2f 两项 %+.2f ms（只打印，不断言）",
                     baseP95, p95Luma, p95Chroma, p95Both, minLuma, minChroma, minBoth))
        // No assertion on the milliseconds: see the note on this test. A cost gate that is only
        // measurable on an idle machine belongs to `scripts/bench`, not to a suite that five lanes
        // run while compiling.
    }

    private func channelSpread(_ image: DisplayImage) -> Double {
        var s = 0.0; var n = 0
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            let r = Double(image.rgba[i]), g = Double(image.rgba[i + 1]), b = Double(image.rgba[i + 2])
            s += (max(r, g, b) - min(r, g, b)) * 255
            n += 1
        }
        return s / Double(max(n, 1))
    }

    private func digest(_ image: DisplayImage) -> String {
        SHA256.hash(data: Data(image.rgba.withUnsafeBytes { Data($0) }))
            .map { String(format: "%02x", $0) }.joined()
    }
}
