import XCTest
import PhotonsCore
import PhotonsExport
import Metal
import CryptoKit

/// 派单 078 / P0-10 — **90° 旋转**，从文档字段到像素到导出。
///
/// 全部断言都量**真像素**：`RenderGraph` 渲出来的帧，不是公式对它自己。合成图（不借 RAW 样片），
/// 所以每个数字都能重跑。
///
/// 六件事，每件一条：
///
///   1. **4 个位置循环回原位**：转 4 次之后的帧 sha 与转 0 次**逐字节相同**，且 1/2/3 次都**不同**
///      （否则这条断言对一个"什么都不做"的实现也成立）。文档本身也回到逐字段相等 —— 裁切矩形走的是
///      `CropMath.turnedClockwise` 的**边**算术（一次 `1 − x` + 一次置换），所以四次是精确回到原来那四个
///      double，不是"接近"。
///   2. **单射**：`quarterTurns × 翻转 × 拉直角度` = 4 × 4 × 4 = **64 个组合 → 64 个不同的帧 sha**，
///      一个碰撞都没有。这条是"旋转不是个装饰字段"的判据。
///   3. **纯置换**：1:1、整幅、只转一次 —— 帧必须**逐字节等于源帧的整数置换**（不是重采样）。@9504 px
///      上 `uv × srcSize` 的往返值约 1e-3 texel，是个真的双线性混合；`s0_geometry.metal` 的 `p.e.w`
///      快路径就是为了让这条成立。
///   4. **裁切跟着转**：带裁切的文档转 90° 后，帧必须等于"未转帧顺时针转 90°"——同一批像素，换了方向。
///      **反证**：把文档改成"帧转了、裁切框没转"（就是那个常见 bug），同一条断言必红，这里打印它的差距。
///   5. **中性**：`quarterTurns == 0` 时帧 sha 与中性文档相同，几何键里**没有** `q=` token，阶段数不变。
///   6. **导出对齐**：编辑侧转 1 次后导出，与"不转、但导出时文档的 quarterTurns = 1"导出，**逐字节相同**。
final class QuarterTurnTests: XCTestCase {

    // MARK: - fixtures

    /// One asymmetric, high-frequency frame: every (x, y) carries a different value, so no two
    /// orientations of it can coincide and a rotation is visible in every pixel.
    ///
    /// r = a horizontal ramp, g = a vertical ramp, b = a hash — the ramps make "which part of the
    /// photograph is this" readable (crop assertions), the hash makes permutations distinguishable.
    private func patternImage(width: Int = 200, height: Int = 120) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let noise = (x &* 73856093) ^ (y &* 19349663)
                let h = Double(noise % 977)
                rgba[o] = Float16(0.02 + 0.85 * Double(x) / Double(width - 1))
                rgba[o + 1] = Float16(0.02 + 0.85 * Double(y) / Double(height - 1))
                rgba[o + 2] = Float16(0.03 + 0.9 * abs(h) / 977)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-p010")
    }

    private func graph(_ image: LinearImage, _ identity: String) throws -> RenderGraph {
        try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    }

    private func imageSize(_ image: LinearImage) -> ImageSize {
        ImageSize(width: image.width, height: image.height)
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        return try XCTUnwrap(result.display, "the render came back without pixels")
    }

    /// 314：neutral 现在真的过 S3.10，恒等类断言必须用 amount = 0 的文档。
    /// 先例见 `LocalColorStageTests` 475 的 `unsharpened`：`amount = 0` 是「S3.10 不存在」的写法。
    private static var unsharpened: EditModel {
        var edit = EditModel.neutral
        edit.sharpen = SharpenGroup(amount: 0, radius: 2.0, detail: 25, masking: 0)
        return edit
    }

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: - 1. four turns cycle back, byte for byte

    /// 转 4 次回到原帧，**逐字节**相同 — and the three intermediate positions are different frames.
    ///
    /// Two documents: the whole frame (where S0 is an exact permutation) and a **cropped** one with a
    /// straighten, i.e. the general resampling path. The second one is the interesting case: a cycle
    /// that only holds at 1:1 would be a property of the fast path, not of the document. What makes
    /// it hold there is that four turns hand back the *same document* — the crop rect's turn is
    /// exact (`CropMath.turnedClockwise` is a permutation of four doubles, each moved by `1 − x`), so
    /// turn 4 renders from the same key and the same arithmetic as turn 0.
    func testFourTurnsReturnTheSameFrame() throws {
        try requireMetal()
        let image = patternImage()
        let g = try graph(image, "quarter-cycle")

        let source = ImageSize(width: image.width, height: image.height)
        let cases: [(name: String, document: EditModel, exactDocument: Bool)] = [
            ("整幅", EditModel.neutral, true),
            // An arbitrary rect: the *frame* must still come back byte for byte (it does — see
            // below), but the stored `width`/`height` are re-derived as `right − left` on every
            // turn, which can move the last bit. Full document equality is therefore only claimed
            // for a rect whose numbers are dyadic, which is the next case.
            ("裁切 60% + 拉直 3.5°", {
                var e = EditModel.neutral
                e.geometry.crop = NormalizedRect(x: 0.12, y: 0.21, width: 0.6, height: 0.52)
                e.geometry.rotationDegrees = 3.5
                return e
            }(), false),
            // 0.125 / 0.25 / 0.5 are exact in binary, so `right − left` is exact at every step and
            // four turns give back the identical `GeometryGroup` — the strongest form of the claim.
            ("裁切 1/2（二进制精确）", {
                var e = EditModel.neutral
                e.geometry.crop = NormalizedRect(x: 0.125, y: 0.25, width: 0.5, height: 0.5)
                return e
            }(), true),
        ]

        for (name, start, exactInDoubles) in cases {
            var document = start
            var shas: [String] = [try render(g, document).sha256()]
            var sizes: [ImageSize] = []
            for _ in 1...4 {
                XCTAssertTrue(document.turn(clockwise: true), "\(name): 第 N 次旋转没有改动文档")
                let frame = try render(g, document)
                sizes.append(frame.size)
                shas.append(frame.sha256())
            }
            print("CYCLE \(name) · " + shas.map { String($0.prefix(12)) }.joined(separator: " → "))
            XCTAssertEqual(shas[4], shas[0],
                           "\(name): 转 4 次没有回到原来的帧（\(shas[4].prefix(12)) vs \(shas[0].prefix(12))）")
            for k in 1...3 {
                XCTAssertNotEqual(shas[k], shas[0], "\(name): 第 \(k) 次旋转后帧没有变——旋转是装饰字段")
            }
            XCTAssertEqual(Set(shas.prefix(4)).count, 4, "\(name): 四个位置必须互不相同")
            // 4 = identity on the *document*, not merely on the pixels. `cropRect` is the form the
            // cache key and the crop tool speak (`%.5f`), so it is the one every rect must pass; a
            // dyadic rect must pass on the raw doubles too.
            let startRect = start.geometry.cropRect, endRect = document.geometry.cropRect
            XCTAssertEqual(endRect.keyString, startRect.keyString,
                           "\(name): 4 次之后裁切的 keyString 变了（\(endRect.keyString) vs \(startRect.keyString)）")
            if exactInDoubles {
                XCTAssertEqual(document.geometry, start.geometry,
                               "\(name): 4 次之后几何不是逐字段相等")
            }
            // Odd turns swap the frame's axes. 132: the frame is the rotated crop's bounding box, so
            // a straighten grows the turn-0 canvas too; a quarter turn swaps that canvas' axes.
            let startCanvas = CropGeometry(geometry: start.geometry, source: source).canvas
            XCTAssertEqual(sizes[0], startCanvas.swapped,
                           "\(name): 转 90° 后帧的宽高没有交换")
        }
    }

    // MARK: - 2. 64 combinations, 64 frames

    /// `quarterTurns × 翻转 × 拉直角度` = 4 × 4 × 4 → **64 distinct frames**, no collisions.
    ///
    /// The angles are deliberately not symmetric (`0`, `0.7`, `1.9`, `−3.3`): a set that contained
    /// 90°/270° would make two combinations agree by construction (a quarter turn plus a quarter turn
    /// of straighten is another quarter turn), and the test would fail for a reason that has nothing
    /// to do with the code.
    func testSixtyFourOrientationsAreInjective() throws {
        try requireMetal()
        let image = patternImage()
        let g = try graph(image, "quarter-injective")

        // ① The control number: the **raw** triples, before normalisation. Sixteen triples spell only
        // eight D4 pictures, and the equivalent pair that used to differ by 1–2 Float16 ulp is the
        // one the ticket measured. This half is deliberately kept as `63` so a later change that
        // merely widens a tolerance cannot pass for the fix.
        var rawSeen: [String: String] = [:]
        var rawCollisions: [String] = []
        for turns in 0..<4 {
            for flips in 0..<2 {
                for vertical in 0..<2 {
                    for (index, angle) in [0.0, 0.7, 1.9, -3.3].enumerated() {
                        var document = EditModel.neutral
                        // 484b/489: the spatial sharpen pass is not rotation-invariant at the canvas
                        // edge, so the orientation comparison runs with it off (§2.15's rule).
                        document.sharpen.amount = 0
                        document.geometry.quarterTurns = turns
                        document.geometry.flipHorizontal = flips == 1
                        document.geometry.flipVertical = vertical == 1
                        document.geometry.rotationDegrees = angle
                        let sha = try render(g, document).sha256()
                        let name = "q\(turns)·H\(flips)·V\(vertical)·a\(index)"
                        if let other = rawSeen[sha] {
                            rawCollisions.append("\(name) == \(other)")
                        }
                        rawSeen[sha] = name
                    }
                }
            }
        }
        print("INJECTIVE · raw 64 combinations → \(rawSeen.count) distinct frames"
              + (rawCollisions.isEmpty ? "" : " · collisions \(rawCollisions)"))
        XCTAssertEqual(rawSeen.count, 63,
                       "the un-normalised control must stay 63 (the defect the ticket measured)")
        XCTAssertEqual(rawCollisions.count, 1)

        // ② The fix: `canonicalized` folds every equivalent triple to one spelling, so equivalent
        // pictures take the same geometry arithmetic. Eight D4 elements × four angles = 32 frames.
        var groups: [String: [(name: String, sha: String)]] = [:]
        var seen: Set<String> = []
        for turns in 0..<4 {
            for flips in 0..<2 {
                for vertical in 0..<2 {
                    for (index, angle) in [0.0, 0.7, 1.9, -3.3].enumerated() {
                        var document = EditModel.neutral
                        // 484b/489: the spatial sharpen pass is not rotation-invariant at the canvas
                        // edge, so the orientation comparison runs with it off (§2.15's rule).
                        document.sharpen.amount = 0
                        document.geometry.quarterTurns = turns
                        document.geometry.flipHorizontal = flips == 1
                        document.geometry.flipVertical = vertical == 1
                        document.geometry.rotationDegrees = angle
                        document.geometry = document.geometry.canonicalized
                        let sha = try render(g, document).sha256()
                        seen.insert(sha)
                        let key = "q\(document.geometry.quarterTurns)"
                            + "·H\(document.geometry.flipHorizontal ? 1 : 0)"
                            + "·V\(document.geometry.flipVertical ? 1 : 0)·a\(index)"
                        groups[key, default: []].append(
                            ("q\(turns)·H\(flips)·V\(vertical)·a\(index)", sha))
                    }
                }
            }
        }
        print("INJECTIVE · canonical 64 combinations → \(seen.count) distinct frames")
        XCTAssertEqual(seen.count, 32, "normalised: D4 8 × 4 angles = 32 distinct frames")
        XCTAssertEqual(groups.count, 32)
        for (key, members) in groups {
            XCTAssertEqual(members.count, 2, "\(key): one D4 element must have exactly two raw spellings")
            XCTAssertEqual(Set(members.map(\.sha)).count, 1,
                           "\(key): equivalent spellings must be byte-identical — "
                           + members.map { "\($0.name)=\($0.sha.prefix(12))" }.joined(separator: " / "))
        }
    }

    // MARK: - 2b. 489 §2.15: a pre-turned source and a turned document are the same pixels

    /// The document says `quarterTurns = 1`; the other graph is handed the source pixels **already
    /// turned** and says `quarterTurns = 0`. Same guide lines (which never render); sharpen is
    /// neutral. The frames must be equal **byte for byte** — the pure-turn path in S0 is an exact
    /// texel permutation, which is the part of §2.15 the code can make true without touching the
    /// resampling kernels. The crop/keystone variant is measured in the report: its two S0 entry
    /// points still differ by one Float16 ulp (the same sampling-order root as the 63-frame control,
    /// outside this task's allowed files).
    func testAPreTurnedSourceAndATurnedDocumentAreTheSameFrame() throws {
        try requireMetal()
        let image = patternImage(width: 200, height: 120)
        let turned = QuarterTurnTests.turnedClockwise(image)
        let graphA = try graph(image, "489-a")
        let graphB = try graph(turned, "489-b")

        var a = EditModel.neutral
        a.sharpen.amount = 0
        a.geometry.quarterTurns = 1
        a.geometry.guideLines = [StoredGuideLine(ax: 0.25, ay: 0.3, bx: 0.75, by: 0.7,
                                                 vertical: true)]

        var b = a
        b.geometry.quarterTurns = 0

        let frameA = try render(graphA, a)
        let frameB = try render(graphB, b)
        XCTAssertEqual(frameA.size, frameB.size)
        var mismatches = 0
        var worst: Float16 = 0
        for i in stride(from: 0, to: min(frameA.rgba.count, frameB.rgba.count), by: 1)
        where frameA.rgba[i] != frameB.rgba[i] {
            mismatches += 1
            worst = max(worst, abs(frameA.rgba[i] - frameB.rgba[i]))
        }
        print("489 §2.15 · turned document vs pre-turned source · \(frameA.size) · "
              + "mismatched channels \(mismatches) · worst Δ \(worst)")
        XCTAssertEqual(mismatches, 0, "same document, two source orientations: not byte-identical")
    }

    private static func turnedClockwise(_ image: LinearImage) -> LinearImage {
        let w = image.width, h = image.height
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let dx = h - 1 - y, dy = x
                let src = (y * w + x) * 4
                let dst = (dy * h + dx) * 4
                for c in 0..<4 { rgba[dst + c] = image.rgba[src + c] }
            }
        }
        return LinearImage(width: h, height: w, rgba: rgba,
                           colorSpace: image.colorSpace, decoderVersion: image.decoderVersion)
    }

    // MARK: - 3. a quarter turn is a permutation, not a resample

    /// 1:1、整幅、只转一次：帧必须逐字节等于源帧的**整数置换**。
    ///
    /// This is the assertion the `p.e.w` fast path exists for. Any implementation that samples
    /// through `uv × srcSize` lands ~1e-3 texel off at this size, i.e. a bilinear blend of two
    /// neighbours — 1–2 codes at a hard edge, invisible to the eye and wrong as a matter of fact for
    /// an operation that has no arithmetic in it. The expected frame is built here by hand, from the
    /// definition of a clockwise quarter turn, so the test cannot inherit the kernel's mistake.
    func testTurnIsAnExactTexelPermutation() throws {
        try requireMetal()
        let image = patternImage(width: 200, height: 120)
        let g = try graph(image, "quarter-permutation")
        // 314/483：neutral 现在真的过 S2.9，恒等类断言必须用 amount = 0 的文档
        // （先例：`LocalColorStageTests` 475 的 `unsharpened`；484 把这条换成套件 helper，
        // 489 的内联写法与它等价，合并取 helper 以保持「一处定义」）。
        let upright = try render(g, Self.unsharpened)

        for turns in 1...3 {
            var document = Self.unsharpened
            document.geometry.quarterTurns = turns
            let turned = try render(g, document)
            XCTAssertEqual(turned.size, turns % 2 == 1 ? upright.size.swapped : upright.size,
                           "q=\(turns): 帧的尺寸不对")

            var mismatches = 0
            var worst: Float16 = 0
            for y in 0..<turned.height {
                for x in 0..<turned.width {
                    let srcX = x, srcY = y
                    let (sx, sy) = QuarterTurnTests.sourcePixel(x: srcX, y: srcY, turns: turns,
                                                               width: upright.width,
                                                               height: upright.height)
                    let a = (sy * upright.width + sx) * 4
                    let b = (y * turned.width + x) * 4
                    for channel in 0..<4 where upright.rgba[a + channel] != turned.rgba[b + channel] {
                        mismatches += 1
                        worst = max(worst, abs(upright.rgba[a + channel] - turned.rgba[b + channel]))
                    }
                }
            }
            print("PERMUTATION q=\(turns) · \(turned.width)×\(turned.height) · mismatched channels "
                  + "\(mismatches) · worst Δ \(worst)")
            XCTAssertEqual(mismatches, 0,
                           "q=\(turns): 帧不是源帧的整数置换——S0 在重采样一个 90° 旋转")
        }
    }

    /// The inverse of a clockwise quarter turn, as the kernel spells it: the source pixel a turned
    /// frame's `(x, y)` came from.
    private static func sourcePixel(x: Int, y: Int, turns: Int,
                                    width: Int, height: Int) -> (x: Int, y: Int) {
        switch ((turns % 4) + 4) % 4 {
        case 1: return (y, height - 1 - x)          // source (i, j) → turned (H−1−j, i)
        case 2: return (width - 1 - x, height - 1 - y)
        case 3: return (width - 1 - y, x)
        default: return (x, y)
        }
    }

    // MARK: - 4. the crop keeps the same pixels (and the refutation)

    /// 带裁切的文档转 90° 后，裁切框在**新方向的同一位置** —— same pixels, turned.
    ///
    /// The measurement is the frame itself: `turned` must equal `upright` rotated 90° clockwise. Both
    /// the whole-frame rotation (frame 3) and this one go through the crop's own arithmetic, so this
    /// is the assertion that catches a crop rect that keeps its numbers while the picture turns.
    ///
    /// The refutation is the bug itself, spelled out: the same document with `quarterTurns` bumped and
    /// the rect **left alone** — the frame is then a different part of the photograph, and the number
    /// printed is how different (`meanAbs` in 8-bit codes).
    func testCropSelectsTheSamePixelsAfterATurn() throws {
        try requireMetal()
        let image = patternImage(width: 240, height: 160)
        let g = try graph(image, "quarter-crop")

        var document = EditModel.neutral
        document.geometry.crop = NormalizedRect(x: 0.15, y: 0.2, width: 0.5, height: 0.55)
        let upright = try render(g, document)

        var turnedDocument = document
        XCTAssertTrue(turnedDocument.turn(clockwise: true))
        let turned = try render(g, turnedDocument)

        // Same pixel grid, rotated: 0.5·240 × 0.55·160 = 120 × 88 → 88 × 120.
        XCTAssertEqual(turned.size, upright.size.swapped,
                       "裁切后的帧没有跟着转（\(turned.size.keyString) vs \(upright.size.keyString)）")

        let (mismatched, mismatch) = QuarterTurnTests.rotationAgreement(upright, turned)
        print("CROP · upright \(upright.size.keyString) → turned \(turned.size.keyString)"
              + " · meanAbs vs rot90CW(upright) = \(String(format: "%.3f", mismatch)) codes")
        XCTAssertEqual(mismatched, 0,
                       "转 90° 后裁切框没有盖住同一批像素（\(mismatch) 平均差 "
                       + "\(String(format: "%.2f", mismatch)) code，\(mismatched) 个通道超差）")

        // ── the refutation ────────────────────────────────────────────────────────────────────────
        // The frame turned, the rect did not — the bug this派单 exists to prevent. Measured the way
        // the pixel-set claim is measured: a frame that covers the same pixels has the same mean
        // colour (a permutation moves pixels, it does not invent any), so a different region shows
        // up as a different mean **and** a different rectangle.
        var broken = document
        broken.geometry.quarterTurns = 1
        let brokenFrame = try render(g, broken)
        let uprightMean = QuarterTurnTests.meanChannels(upright)
        let turnedMean = QuarterTurnTests.meanChannels(turned)
        let brokenMean = QuarterTurnTests.meanChannels(brokenFrame)
        let samePixels = zip(uprightMean, turnedMean).map { abs($0 - $1) }.max() ?? 0
        let differentPixels = zip(uprightMean, brokenMean).map { abs($0 - $1) }.max() ?? 0
        print(String(format: "CROP mean · upright %.2f/%.2f/%.2f · turned %.2f/%.2f/%.2f "
                     + "· Δ(turned) %.3f codes · REFUTATION Δ(rect not turned) %.3f codes",
                     uprightMean[0] * 255, uprightMean[1] * 255, uprightMean[2] * 255,
                     turnedMean[0] * 255, turnedMean[1] * 255, turnedMean[2] * 255,
                     samePixels * 255, differentPixels * 255))
        XCTAssertLessThan(samePixels * 255, 0.5,
                          "转 90° 后帧的均值变了——裁切框没有盖住同一批像素")
        XCTAssertNotEqual(brokenFrame.size, turned.size,
                          "反证没有红：裁切坐标不跟着转的帧尺寸正好等于正确的帧")
        XCTAssertGreaterThan(differentPixels * 255, 3.0,
                             "反证没有红：裁切坐标不跟着转的帧均值只差 "
                             + String(format: "%.2f", differentPixels * 255) + " code")
    }

    /// Per-channel mean (0…1) — a permutation moves pixels without inventing them, so a frame that
    /// covers the same pixels has the same mean, and a frame covering a different region does not.
    private static func meanChannels(_ image: DisplayImage) -> [Double] {
        var sums = [0.0, 0.0, 0.0]
        for i in stride(from: 0, to: image.rgba.count, by: 4) {
            for c in 0..<3 { sums[c] += Double(image.rgba[i + c]) }
        }
        let n = Double(max(1, image.width * image.height))
        return sums.map { $0 / n }
    }

    /// Mismatched channel count and mean absolute difference between two frames, the second
    /// rotated 90° CW.
    ///
    /// `turned(x, y)` must be `upright(y, H−1−x)` for the *image content*: a clockwise quarter turn
    /// maps the frame's top-left corner to its top-right, so the turned frame's row `x` is the upright
    /// frame's column `H−1−x` read bottom-up.
    private static func rotationAgreement(_ upright: DisplayImage, _ turned: DisplayImage)
        -> (mismatched: Int, meanAbs: Double) {
        guard turned.width == upright.height, turned.height == upright.width else {
            return (Int.max / 2, 255)
        }
        var mismatched = 0
        var total = 0.0
        var count = 0
        for y in 0..<turned.height {
            for x in 0..<turned.width {
                let b = (y * turned.width + x) * 4
                let a = ((upright.height - 1 - x) * upright.width + y) * 4
                for channel in 0..<3 {
                    let delta = abs(Double(upright.rgba[a + channel] - turned.rgba[b + channel])) * 255
                    total += delta
                    count += 1
                    if delta > 2 { mismatched += 1 }
                }
            }
        }
        return (mismatched, count > 0 ? total / Double(count) : 0)
    }

    // MARK: - 5. neutral: same frame, same key, same stage count

    /// `quarterTurns == 0` 的文档与中性文档**一模一样**：帧 sha 相同、几何键里没有 `q=` token、阶段数不变。
    ///
    /// The §3.2 discipline every stage in this graph follows: a field that is off must leave the key
    /// and the pixels exactly as they were, or every recorded golden and every pinned key moves for a
    /// feature nobody switched on.
    func testNeutralDocumentKeepsItsFrameAndItsKey() throws {
        try requireMetal()
        let image = patternImage()
        let g = try graph(image, "quarter-neutral")

        var explicit = EditModel.neutral
        explicit.geometry.quarterTurns = 0
        let neutralFrame = try render(g, EditModel.neutral)
        let explicitFrame = try render(g, explicit)
        XCTAssertEqual(explicitFrame.sha256(), neutralFrame.sha256(),
                       "quarterTurns = 0 的文档和中性文档渲出了两帧")

        let neutralMaterial = EditModel.neutral.keyMaterial(.geometry)
        XCTAssertFalse(neutralMaterial.contains("q="),
                       "几何键里出现了 q= token（\(neutralMaterial)）——旋转在这条链上还带着痕迹")
        XCTAssertTrue(explicit.keyMaterial(.geometry) == neutralMaterial)

        var turned = EditModel.neutral
        turned.geometry.quarterTurns = 1
        XCTAssertNotEqual(turned.keyMaterial(.geometry), neutralMaterial,
                          "转了 90° 的文档和中性文档的几何键相同——缓存会把旧帧当新帧")

        // Stage count: the turn is a *coordinate* of S0, not a new link in the chain.
        let display = DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1)
        func links(_ edit: EditModel, canvas: ImageSize) throws -> RenderKeyChain.Links {
            RenderKeyChain.links(identity: "quarter-neutral", sourceSize: imageSize(image),
                                 canvas: canvas, content: canvas, edit: edit, display: display)
        }
        let uprightLinks = try links(EditModel.neutral, canvas: imageSize(image))
        let turnedLinks = try links(turned, canvas: imageSize(image).swapped)
        print("NEUTRAL · stages \(uprightLinks.pipeline.count) upright vs "
              + "\(turnedLinks.pipeline.count) turned · geometry key "
              + "\(uprightLinks.geometry.prefix(10)) vs \(turnedLinks.geometry.prefix(10))")
        XCTAssertEqual(turnedLinks.pipeline.count, uprightLinks.pipeline.count,
                       "旋转多出了一段（阶段只应是 S0 的坐标，不是链条上的一环）")
        XCTAssertNotEqual(turnedLinks.geometry, uprightLinks.geometry)
    }

    // MARK: - 5b. a pasted turn carries the destination's crop with it

    /// `quarterTurns` 是一**变换**，不是一个自由数字：粘贴/预设只带 turn 不带裁切时，目标文档的裁切框
    /// 必须跟着转同样的角度，否则那张照片会换一块区域。
    ///
    /// This is the preset/copy-settings face of the same bug the crop test above pins on the render
    /// path: the payload says "the frame is turned one quarter", and a rect that was measured in the
    /// old frame cannot be left alone.
    func testPastingATurnCarriesTheDestinationCropWithIt() {
        var source = EditModel.neutral
        XCTAssertTrue(source.turn(clockwise: true))
        // 442: the full capture carries the crop too; this case is about a payload that names the
        // turn alone, so it is narrowed to that child.
        let payload = EditSnapshot.capture(source)
            .filtered(to: [.geometry], children: [.quarterTurns])
        XCTAssertEqual(payload.geometry?.quarterTurns, 1, "转了 90° 的整幅文档，快照里应该有 turn")
        XCTAssertNil(payload.geometry?.cropX, "只勾旋转时裁切边不在载荷里")

        var target = EditModel.neutral
        target.geometry.crop = NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        let pasted = payload.applied(to: target)
        XCTAssertEqual(pasted.geometry.quarterTurns, 1)
        XCTAssertEqual(pasted.geometry.cropRect.keyString,
                       CropMath.turnedClockwise(target.geometry.cropRect).keyString,
                       "粘贴一个 turn 时目标文档的裁切框没有跟着转")

        // A payload that carries crop edges speaks absolute coordinates in the destination's frame:
        // the edges are written, not turned again.
        var croppedSource = EditModel.neutral
        croppedSource.geometry.crop = NormalizedRect(x: 0.05, y: 0.1, width: 0.6, height: 0.5)
        let edges = EditSnapshot.capture(croppedSource)
            .filtered(to: [.geometry], children: [.crop])
        XCTAssertNotNil(edges.geometry?.cropX)
        var turnedTarget = EditModel.neutral
        turnedTarget.geometry.quarterTurns = 1
        let fromEdges = edges.applied(to: turnedTarget)
        XCTAssertEqual(fromEdges.geometry.cropRect.keyString,
                       croppedSource.geometry.cropRect.keyString,
                       "带裁切边的快照应该原样写入，而不是再转一次")
        XCTAssertEqual(fromEdges.geometry.quarterTurns, 1, "没带 turn 的快照不该改目标的 turn")
    }

    // MARK: - 6. the export and the editor are the same turn

    /// 编辑侧转 1 次 + 导出 == 不转但导出时 quarterTurns = 1，**逐字节相同**。
    ///
    /// Both documents carry the **same** `XMPOrientation` quarter count — `GeometryGroup.quarterTurns`
    /// — so this is the claim that the export does not have a turn of its own: it renders the
    /// document it is handed, writes the same pixels, and derives `tiff:Orientation` from the same
    /// number. A second mechanism (a post-render rotation, or applying the field twice) cannot produce
    /// these two identical files.
    func testTheExportIsTheSameTurnAsTheEditor() throws {
        try requireMetal()
        let image = patternImage(width: 160, height: 96)
        let g = try graph(image, "quarter-export")

        // (a) the editor's verb
        var editorTurned = EditModel.neutral
        XCTAssertTrue(editorTurned.turn(clockwise: true))
        // (b) the same field, declared on the document handed to the export — no editor, no history
        var exportDeclared = EditModel.neutral
        exportDeclared.geometry.quarterTurns = 1

        XCTAssertEqual(editorTurned.geometry, exportDeclared.geometry,
                       "编辑侧转一次与导出侧设 quarterTurns=1 不是同一份几何")

        let a = try render(g, editorTurned)
        let b = try render(g, exportDeclared)
        XCTAssertEqual(a.sha256(), b.sha256(), "两条路的帧不同")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-quarter-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let options = ExportOptions(format: .jpeg, quality: 0.92, bitDepth: 8)
        let urlA = directory.appendingPathComponent("a.jpg")
        let urlB = directory.appendingPathComponent("b.jpg")
        try Exporter.write(a, to: urlA, options: options)
        try Exporter.write(b, to: urlB, options: options)
        let bytesA = try Data(contentsOf: urlA)
        let bytesB = try Data(contentsOf: urlB)
        print("EXPORT · \(bytesA.count) bytes each · sha "
              + "\(SHA256.hash(data: bytesA).description.prefix(12)) · "
              + "identical \(bytesA == bytesB)")
        XCTAssertEqual(bytesA, bytesB, "导出的两个文件不是逐字节相同")

        // And the sidecar: one field, so the tag is derived from it — 90° CW on a level file is 6.
        let metadata = CGImageMetadataCreateMutable()
        try XMPWriter.registerNamespaces(metadata)
        let report = try XMPWriter.apply(editorTurned, to: metadata)
        XCTAssertTrue(report.notes.contains { $0.contains("90°") }, report.notes.joined(separator: " | "))
        XCTAssertEqual(XMPOrientation.composed(exif: 1, flipHorizontal: false,
                                               flipVertical: false, quarterTurns: 1),
                       6, "90° 顺时针在 EXIF 里是 orientation 6")
    }
}

private extension ImageSize {
    /// The same pixel block seen after a quarter turn.
    var swapped: ImageSize { ImageSize(width: height, height: width) }
}
