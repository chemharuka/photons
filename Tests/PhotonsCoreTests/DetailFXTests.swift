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
}
