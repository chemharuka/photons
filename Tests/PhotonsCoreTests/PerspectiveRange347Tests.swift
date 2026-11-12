import XCTest
import PhotonsCore
import Metal

/// 347 — **透视滑杆的行程 ±100 → ±200，±100 以内一个像素都不许动**.
///
/// The trap is the strength's denominator: `CropMath` used to write
/// `-vertical / PerspectiveMap.limit * tangentPerUnit`, so widening `limit` would have *halved* the
/// strength at slider 100 and repainted every document in the library — a re-parametrisation, not a
/// wider travel. 347 fixes the unit at 100 (`PerspectiveMap.strengthUnit`) and lets `limit` (200)
/// govern the clamp and the slider's track only, so
///
///   * `|v| ≤ 100` is **bit for bit** what it was — the same SHAs, the same key text, the same
///     `canvasSize`, the same `warpedQuad()`;
///   * `|v| > 100` is a new, stronger stop (200 = 0.42 = exactly 2 × today's 0.21).
///
/// Every number below was **recorded on `main@1f005b1`** (pre-347) and is compared as the exact
/// `Double` (`%.17g`), not to 12 digits: a rescaled strength would still agree to 12.
final class PerspectiveRange347Tests: XCTestCase {

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    }

    /// A high-frequency, asymmetric frame: two different warps cannot coincide on it.
    private func patternImage(width: Int = 480, height: Int = 320) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let noise = (x &* 73856093) ^ (y &* 19349663)
                let h = Double(abs(noise % 977))
                rgba[o] = Float16(0.06 + 0.70 * Double(x) / Double(width - 1))
                rgba[o + 1] = Float16(0.06 + 0.70 * Double(y) / Double(height - 1))
                rgba[o + 2] = Float16(0.05 + 0.75 * h / 977)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-347")
    }

    private func document(vertical: Double, horizontal: Double) -> EditModel {
        var edit = EditModel.neutral
        edit.geometry.perspectiveVertical = vertical
        edit.geometry.perspectiveHorizontal = horizontal
        return edit
    }

    private func render(_ edit: EditModel) throws -> DisplayImage {
        let graph = try RenderGraph(input: RenderInput(image: patternImage(),
                                                       identity: "perspective-range-347"))
        let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        return try XCTUnwrap(result.display, "the render came back without pixels")
    }

    /// `%.17g` so the string is the `Double` itself, not a rounded print.
    private func numbers(_ map: PerspectiveMap) -> (canvas: String, quad: String) {
        let size = map.canvasSize()
        let canvas = String(format: "%.17g x %.17g", size.width, size.height)
        let quad = map.warpedQuad().map { String(format: "%.17g,%.17g", $0.x, $0.y) }
            .joined(separator: " ")
        return (canvas, quad)
    }

    // MARK: - ① the recorded baseline

    private struct Baseline {
        let sha: String
        let key: String
        let canvas: String
        let quad: String
    }

    /// The five frames: both axes, both signs, both ends of the old travel. Recorded pre-347.
    private static let baseline: [(name: String, v: Double, h: Double, row: Baseline)] = [
        ("v=+0 h=+0", 0, 0, Baseline(
            sha: "562fae6a0ac1b16a1e95a5b23ece15d6b6da54901cfb37907d3a2754b6f4336a",
            key: "pv=2;crop=0.00000,0.00000,1.00000,1.00000;rot=0.00000;flip=00;alg=5",
            canvas: "1 x 1",
            quad: "0,0 1,0 1,1 0,1")),
        ("v=+25 h=+0", 25, 0, Baseline(
            sha: "0627601648b91ffaaaeaf0101d8959b33d64dcdf773a2eb85357b95d054646c1",
            key: "pv=2;crop=0.00000,0.00000,1.00000,1.00000;rot=0.00000;flip=00;pvy=250;alg=5",
            canvas: "0.97442143727161989 x 1.0006895376345262",
            quad: "-0.013478818998716302,-0.013478818998716302 1.0134788189987163,-0.013478818998716302 "
                + "0.98721071863580989,0.98721071863580989 0.012789281364190011,0.98721071863580989")),
        ("v=-25 h=+0", -25, 0, Baseline(
            sha: "e818f3e04f63b39c2d51247b930053a8a71f19a6a24fcb8879a6eecd91b0eb86",
            key: "pv=2;crop=0.00000,0.00000,1.00000,1.00000;rot=0.00000;flip=00;pvy=-250;alg=5",
            canvas: "0.97442143727161989 x 1.0006895376345262",
            quad: "0.012789281364190011,0.012789281364190011 0.98721071863580989,0.012789281364190011 "
                + "1.0134788189987163,1.0134788189987163 -0.013478818998716301,1.0134788189987163")),
        ("v=+100 h=+0", 100, 0, Baseline(
            sha: "a638dd7701b8164a3055f9edcdeab30f0256ccfeda6a9bbcbfb2844273337c69",
            key: "pv=2;crop=0.00000,0.00000,1.00000,1.00000;rot=0.00000;flip=00;pvy=1000;alg=5",
            canvas: "0.90497737556561098 x 1.0111479056599006",
            quad: "-0.058659217877094966,-0.058659217877094966 1.058659217877095,-0.058659217877094966 "
                + "0.95248868778280549,0.95248868778280549 0.047511312217194568,0.95248868778280549")),
        ("v=+0 h=-100", 0, -100, Baseline(
            sha: "a5e65b0a5d7147816a5bdb40234b0467ff85379198565eb35735733b3de151f5",
            key: "pv=2;crop=0.00000,0.00000,1.00000,1.00000;rot=0.00000;flip=00;phx=-1000;alg=5",
            canvas: "1.0111479056599004 x 0.90497737556561086",
            quad: "-0.058659217877094966,-0.058659217877094966 0.95248868778280549,0.047511312217194568 "
                + "0.95248868778280549,0.95248868778280549 -0.058659217877094966,1.058659217877095")),
    ]

    func testTheOldTravelIsByteForByteTheOldRender() throws {
        try requireMetal()
        for c in Self.baseline {
            let edit = document(vertical: c.v, horizontal: c.h)
            let display = try render(edit)
            let numbers = numbers(PerspectiveMap(vertical: c.v, horizontal: c.h))
            print("347 ① \(c.name) · \(display.width)×\(display.height) · sha \(display.sha256())")
            print("347 ① \(c.name) · key \(edit.keyMaterial(.geometry)) · canvas \(numbers.canvas)")
            XCTAssertEqual(display.sha256(), c.row.sha,
                           "347 ① \(c.name): 渲染 SHA 必须与改前逐字节相同")
            XCTAssertEqual(edit.keyMaterial(.geometry), c.row.key,
                           "347 ① \(c.name): 键材料必须逐字符相同")
            XCTAssertEqual(numbers.canvas, c.row.canvas,
                           "347 ① \(c.name): canvasSize 必须逐值相同")
            XCTAssertEqual(numbers.quad, c.row.quad,
                           "347 ① \(c.name): warpedQuad() 必须逐值相同")
        }
    }

    // MARK: - ③ strength: unit 100, travel 200

    func testTheStrengthIsLinearAndTheOldValuesAreUnmoved() {
        let fifty = PerspectiveMap(vertical: 50, horizontal: 0).verticalStrength
        let hundred = PerspectiveMap(vertical: 100, horizontal: 0).verticalStrength
        let twoHundred = PerspectiveMap(vertical: 200, horizontal: 0).verticalStrength
        let horizontal = PerspectiveMap(vertical: 0, horizontal: 200).horizontalStrength
        print(String(format: "347 ③ strength(50) = %.17g · strength(100) = %.17g · strength(200) = %.17g"
                     + " · horizontal(200) = %.17g · 200/100 = %.17g",
                     fifty, hundred, twoHundred, horizontal, twoHundred / hundred))

        XCTAssertEqual(hundred, -0.21, accuracy: 1e-15, "347 ③ 滑杆 100 仍是今天的 −0.21")
        XCTAssertEqual(fifty, -0.105, accuracy: 1e-15, "347 ③ 滑杆 50 仍是 −0.105")
        XCTAssertEqual(twoHundred, -0.42, accuracy: 1e-15, "347 ③ 滑杆 200 = 0.42")
        XCTAssertEqual(twoHundred / hundred, 2, accuracy: 1e-12, "347 ③ 200 是 100 的整两倍")
        XCTAssertEqual(horizontal, twoHundred, accuracy: 1e-15, "347 ③ 两个轴同一把尺")
        XCTAssertEqual(PerspectiveMap.tangentPerUnit, 0.21, "347: tangentPerUnit 不动")
    }

    // MARK: - ②④ the new travel: renders, finite, convex, no singularity

    /// `w` on the quad's four corners, from the matrix' own third row — the number the homography
    /// divides by, not a re-derivation.
    private func cornerW(_ map: PerspectiveMap) -> [Double] {
        let m = map.forwardMatrix
        return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map {
            m[2][0] * $0.0 + m[2][1] * $0.1 + m[2][2]
        }
    }

    /// Cross products of consecutive edges: all the same sign (and non-zero) means convex.
    private func isConvex(_ quad: [(x: Double, y: Double)]) -> Bool {
        var signs: [Double] = []
        for i in quad.indices {
            let a = quad[i], b = quad[(i + 1) % quad.count], c = quad[(i + 2) % quad.count]
            signs.append((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x))
        }
        guard signs.allSatisfy({ $0.isFinite && abs($0) > 1e-12 }) else { return false }
        return signs.allSatisfy { $0 > 0 } || signs.allSatisfy { $0 < 0 }
    }

    func testTheNewTravelRendersFiniteAndConvex() throws {
        try requireMetal()
        let travel: [(vertical: Double, horizontal: Double)] = [
            (120, 0), (-120, 0), (150, 0), (-150, 0), (200, 0), (-200, 0),
            (300, 0), (-300, 0), (400, 0), (-400, 0),   // 353 — 行程到 ±400
            (500, 0), (-500, 0),                        // 353b — 行程到 ±500
        ]
        var smallestW = Double.infinity
        for t in travel {
            let map = PerspectiveMap(vertical: t.vertical, horizontal: t.horizontal)
            let quad = map.warpedQuad()
            let size = map.canvasSize()
            let display = try render(document(vertical: t.vertical, horizontal: t.horizontal))
            let ws = cornerW(map)
            print(String(format: "347 ② v %+5.0f · 画布 %.17g×%.17g · 渲染 %d×%d · sha %@"
                         + " · min w %.17g · 凸 %@ · 强度 %.17g",
                         t.vertical, size.width, size.height, display.width, display.height,
                         String(display.sha256().prefix(12)), ws.min() ?? .nan,
                         isConvex(quad) ? "是" : "否", map.verticalStrength))

            for corner in quad {
                XCTAssertTrue(corner.x.isFinite && corner.y.isFinite,
                              "347 ② v \(t.vertical): 四边形里出现了 NaN/inf")
            }
            XCTAssertTrue(size.width.isFinite && size.width > 0,
                          "347 ② v \(t.vertical): 画布宽必须有限且 > 0")
            XCTAssertTrue(size.height.isFinite && size.height > 0,
                          "347 ② v \(t.vertical): 画布高必须有限且 > 0")
            XCTAssertTrue(isConvex(quad), "347 ② v \(t.vertical): 四边形必须仍然凸（叉积同号）")
            XCTAssertTrue(ws.allSatisfy { $0.isFinite && $0 > 0 }, "347 ② v \(t.vertical): w 必须 > 0")
            XCTAssertGreaterThan(display.width, 0, "347 ② v \(t.vertical): 渲染出了空画布")
            XCTAssertGreaterThan(display.height, 0)
            smallestW = min(smallestW, ws.min() ?? .nan)
        }

        // ④ the margin at the loudest stop, on both axes, and the pair together.
        let vertical200 = cornerW(PerspectiveMap(vertical: 200, horizontal: 0))
        let horizontal200 = cornerW(PerspectiveMap(vertical: 0, horizontal: 200))
        let both = cornerW(PerspectiveMap(vertical: 200, horizontal: 200))
        print(String(format: "347 ④ min w: 垂直 200 = %.17g · 水平 200 = %.17g · 双 200 = %.17g"
                     + " · 六档全局最小 %.17g",
                     vertical200.min() ?? .nan, horizontal200.min() ?? .nan,
                     both.min() ?? .nan, smallestW))
        let vertical400 = cornerW(PerspectiveMap(vertical: 400, horizontal: 0))
        let horizontal400 = cornerW(PerspectiveMap(vertical: 0, horizontal: 400))
        let both400 = cornerW(PerspectiveMap(vertical: 400, horizontal: 400))
        print(String(format: "353 ④ min w: 垂直 400 = %.17g · 水平 400 = %.17g · 双 400 = %.17g",
                     vertical400.min() ?? .nan, horizontal400.min() ?? .nan, both400.min() ?? .nan))
        let vertical500 = cornerW(PerspectiveMap(vertical: 500, horizontal: 0))
        let horizontal500 = cornerW(PerspectiveMap(vertical: 0, horizontal: 500))
        let both500 = cornerW(PerspectiveMap(vertical: 500, horizontal: 500))
        print(String(format: "353b ④ min w: 垂直 500 = %.17g · 水平 500 = %.17g · 双 500 = %.17g",
                     vertical500.min() ?? .nan, horizontal500.min() ?? .nan, both500.min() ?? .nan))
        XCTAssertGreaterThanOrEqual(vertical200.min() ?? 0, 0.78, "347 ④ 垂直 200 的 w 余量")
        XCTAssertGreaterThanOrEqual(horizontal200.min() ?? 0, 0.78, "347 ④ 水平 200 的 w 余量")
        XCTAssertGreaterThan(both.min() ?? 0, 0, "347 ④ 双 200 仍无奇点")
        XCTAssertGreaterThanOrEqual(vertical400.min() ?? 0, 0.58, "353 ④ 垂直 400 的 w 余量（1 − 0.84/2）")
        XCTAssertGreaterThanOrEqual(horizontal400.min() ?? 0, 0.58, "353 ④ 水平 400 的 w 余量")
        XCTAssertGreaterThan(both400.min() ?? 0, 0, "353 ④ 双 400 仍无奇点")
        // 353b — the single-axis margin, with a **float** tolerance: `1 − 1.05/2` is not exact in
        // binary, so the measured 0.47499999999999987 must not be compared with `>=` against 0.475.
        XCTAssertEqual(vertical500.min() ?? 0, 0.475, accuracy: 1e-12, "353b ④ 垂直 500 的 w 余量（1 − 1.05/2）")
        XCTAssertEqual(horizontal500.min() ?? 0, 0.475, accuracy: 1e-12, "353b ④ 水平 500 的 w 余量")
        XCTAssertGreaterThanOrEqual(smallestW, 0.475 - 1e-12, "353b ④ 十二档里最小的 w")

        // 353b — **the coupled axis is the real bound, not `limit` alone.** `M = M_h · M_v` and the
        // corner `w` is `1 − (|s_v| + |s_h|)/2`, so two axes at 500 cancel: the raw matrix gives
        // `w = −0.05`, a pole. `init` therefore clamps the **pair** (one axis gives way), and the
        // number that matters is the budget (900, 用户定), which is below
        // `2 × limit = 1000` — each axis alone may use the whole track, the two together may not.
        print(String(format: "353b ④ 耦合预算 = %.2f（2×limit = %.0f）· w 下限 %.2f",
                     PerspectiveMap.coupledTravelBudget, 2 * PerspectiveMap.limit,
                     PerspectiveMap.coupledWFloor))
        let c500 = PerspectiveMap(vertical: 500, horizontal: 500)
        print(String(format: "353b ④ 请求双 500 → 实际 v %.4f / h %.4f · w_min %.17g",
                     c500.vertical, c500.horizontal,
                     PerspectiveMap.minimumW(vertical: c500.vertical, horizontal: c500.horizontal)))
        XCTAssertGreaterThan(PerspectiveMap.minimumW(vertical: c500.vertical, horizontal: c500.horizontal),
                             0, "353b ④ 双 500 必须被收缩到无奇点")
        XCTAssertEqual(abs(c500.vertical) + abs(c500.horizontal),
                       PerspectiveMap.coupledTravelBudget, accuracy: 1e-9,
                       "353b ④ 收缩后正好落在预算上")
        XCTAssertEqual(c500.vertical / c500.horizontal, 1.0, accuracy: 1e-12,
                       "353b ④ 等比收缩：两轴同幅时保持相等")

        // 单轴到顶时，另一轴还有多少余量（这是「一轴让位」的可感知后果）。
        let onlyV = PerspectiveMap(vertical: 500, horizontal: 0)
        XCTAssertEqual(onlyV.vertical, 500, accuracy: 1e-12, "353b ④ 单轴 500 不许被收缩")
        let v500h300 = PerspectiveMap(vertical: 500, horizontal: 300)
        print(String(format: "353b ④ 请求 v500/h300 → 实际 v %.4f / h %.4f",
                     v500h300.vertical, v500h300.horizontal))
        XCTAssertLessThanOrEqual(abs(v500h300.vertical) + abs(v500h300.horizontal),
                                 PerspectiveMap.coupledTravelBudget + 1e-9,
                                 "353b ④ 800 ≤ 900 ⇒ 不该收缩")
        XCTAssertEqual(v500h300.vertical, 500, accuracy: 1e-12, "353b ④ 800 在预算内，v 保持 500")

        // 预算 900 的确切边界：475 + 425 = 900 恰好落在预算上，不收缩；476 + 425 = 901 收缩。
        let atBudget = PerspectiveMap(vertical: 475, horizontal: 425)
        XCTAssertEqual(atBudget.vertical, 475, accuracy: 1e-12, "353b ④ 475+425=900 恰好不缩")
        XCTAssertEqual(atBudget.horizontal, 425, accuracy: 1e-12)
        let overBudget = PerspectiveMap(vertical: 476, horizontal: 425)
        print(String(format: "353b ④ 476+425=901（超 1）→ v %.6f / h %.6f · 和 %.6f",
                     overBudget.vertical, overBudget.horizontal,
                     abs(overBudget.vertical) + abs(overBudget.horizontal)))
        XCTAssertEqual(abs(overBudget.vertical) + abs(overBudget.horizontal), 900, accuracy: 1e-9,
                       "353b ④ 超出后正好缩回 900")

        // 既存文档逐字不动：±400 双轴的 800 远在预算内。
        let legacy = PerspectiveMap(vertical: 400, horizontal: 400)
        XCTAssertEqual(legacy.vertical, 400, accuracy: 1e-15, "353b ④ 既存 400 不许被收缩")
        XCTAssertEqual(legacy.horizontal, 400, accuracy: 1e-15)
        XCTAssertEqual(both400.min() ?? 0, 0.16, accuracy: 1e-12, "353b ④ 双 400 的 w 仍是 0.16")
    }

    // MARK: - the clamp lives on `limit`, the strength on 100

    func testTheLimitMovesAndTheUnitDoesNot() {
        print("347 · limit \(PerspectiveMap.limit) · strengthUnit \(PerspectiveMap.strengthUnit)")
        XCTAssertEqual(PerspectiveMap.limit, 500, "353b: limit = 500（单轴夹取与滑杆行程）")
        XCTAssertEqual(PerspectiveMap.strengthUnit, 100, "347: 强度分母写死 100")
        XCTAssertEqual(PerspectiveMap(vertical: 550, horizontal: 0).vertical, 500,
                       "353b: 单轴 550 夹到 500")
        XCTAssertEqual(PerspectiveMap(vertical: -550, horizontal: 0).vertical, -500)
        XCTAssertEqual(PerspectiveMap(vertical: 500, horizontal: 0).vertical, 500,
                       "353b: 单轴 500 本身不再被夹")
        XCTAssertEqual(PerspectiveMap(vertical: 450, horizontal: 0).vertical, 450,
                       "353b: 450 现在合法（353 时会被夹到 400）")
        XCTAssertEqual(PerspectiveMap(vertical: 400, horizontal: 0).vertical, 400,
                       "353: 400 仍合法")
        XCTAssertEqual(PerspectiveMap(vertical: 200, horizontal: 0).vertical, 200,
                       "353: 200 仍合法（347 的行程未被收回）")
        XCTAssertEqual(PerspectiveMap(vertical: .nan, horizontal: 0).vertical, 0, "347: 非数 → 0")

        // 353b — 单轴夹取在前、耦合收缩在后：550 + 550 先各自夹到 500，再等比缩到预算。
        let over = PerspectiveMap(vertical: 550, horizontal: 550)
        print(String(format: "353b · 550/550 → v %.4f / h %.4f（和 %.2f ≤ 预算 %.2f）",
                     over.vertical, over.horizontal,
                     abs(over.vertical) + abs(over.horizontal),
                     PerspectiveMap.coupledTravelBudget))
        XCTAssertLessThanOrEqual(abs(over.vertical), 500, "353b: 单轴不许超过 limit")
        XCTAssertLessThanOrEqual(abs(over.vertical) + abs(over.horizontal),
                                 PerspectiveMap.coupledTravelBudget + 1e-9, "353b: 和必须在预算内")
    }

    /// 353b — **the strength of an existing value must not move.** Widening the track only lengthens
    /// the slider; if the denominator had followed `limit`, every document in the library would have
    /// been repainted by a re-parametrisation. This pins the half 347 was about.
    func testWideningTheTrackDoesNotRepaint() {
        for v in [100.0, 200.0, 300.0, 400.0] {
            let s = PerspectiveMap(vertical: v, horizontal: 0).verticalStrength
            let expected = -v / 100 * 0.21
            XCTAssertEqual(s, expected, accuracy: 1e-15,
                           "353b: 滑杆 \(v) 的强度必须仍是 \(-v / 100 * 0.21)")
            print(String(format: "353b ⑤ v %+5.0f · s %.17g · 期望 %.17g", v, s, expected))
        }
        let at500 = PerspectiveMap(vertical: 500, horizontal: 0).verticalStrength
        print(String(format: "353b ⑤ v %+5.0f · s %.17g（新增的那一档）", 500.0, at500))
        XCTAssertEqual(at500, -1.05, accuracy: 1e-12, "353b: 500 的强度 = −1.05")
    }
}
