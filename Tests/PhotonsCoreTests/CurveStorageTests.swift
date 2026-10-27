import XCTest
@testable import PhotonsCore

/// 派单 069 — 曲线控制点的坐标与存储。
///
/// The coordinate is the card's own: **`0…1` is SDR** (`code = x·255`, `1` = display white) and
/// **`1…2` is HDR** (`EV = (x − 1)·4`, `2` = +4 EV). The engine's axis is `u = x / 2`, so no maths
/// downstream moves — `testTheNewCoordinateIsTwiceTheAxis` recomputes that for four points.
///
/// The claims:
///
///   1. `u = x/2` and the anchors agree with `HDRCurveAxis`.
///   2. Doubles out, doubles in: `format = {version:2, type:"double", max:2, domain:"hdr"}`, byte-stable.
///   3. `version: 1` (the transient integer grid) → `x_new = 2·cell/max`.
///   4. no `format` at all (old `0…1` axis coordinates) → `x_new = 2·v`.
///   5. out of range **throws** on the document/API path, and **clamps** on the interaction path.
///   6. a future `version` is refused (identity curve + warning) and the rest of the document loads.
@MainActor
final class CurveStorageTests: XCTestCase {

    // MARK: 1. the coordinate is twice the axis

    func testTheNewCoordinateIsTwiceTheAxis() {
        let axis = HDRCurveAxis.standard
        let anchors: [(x: Double, u: Double, note: String)] = [
            (0, 0, "zero light"),
            (0.5, 0.25, "SDR code 128"),
            (1, 0.5, "display white"),
            (1.5, 0.75, "+2 EV"),
            (2, 1.0, "+4 EV (right edge)"),
        ]
        for anchor in anchors {
            let p = CurvePoint(anchor.x, anchor.x)
            XCTAssertEqual(p.u, anchor.u, accuracy: 1e-15, "u = x/2（\(anchor.note)）")
            XCTAssertEqual(p.v, anchor.u, accuracy: 1e-15)
        }
        XCTAssertEqual(axis.whiteU, CurvePoint(1, 1).u, accuracy: 0, "x = 1 就是白点")
        XCTAssertEqual(axis.stops(at: CurvePoint(1.5, 1.5).u), 2, accuracy: 1e-12, "x = 1.5 就是 +2 EV")
        XCTAssertEqual(axis.stops(at: CurvePoint(2, 2).u), 4, accuracy: 1e-12, "x = 2 就是 +4 EV")
        for code in [0, 63, 127, 191, 255] {
            XCTAssertEqual(CurvePoint.from(code: code) * 255, Double(code), accuracy: 1e-12)
            XCTAssertEqual(CurvePoint.code(CurvePoint.from(code: code)), code)
        }
        // The EV half is a straight line: (x − 1)·4 — which is why 2.25 will be +5 EV.
        for step in 0...8 {
            let x = 1 + Double(step) * 0.125
            XCTAssertEqual((x - CurvePoint.sdrBoundary) * 4, Double(step) * 0.5, accuracy: 1e-12,
                           "EV = (x − 1)·4，x = \(x)")
        }
        print("coordinate · x/u " + anchors.map { "\($0.x)→\($0.u)" }.joined(separator: " · "))
    }

    // MARK: 2. doubles round trip

    func testCoordinatesRoundTripAsDoubles() throws {
        let points = [CurvePoint(0, 0), CurvePoint(0.21917808219178081, 0.17025440313111546),
                      CurvePoint(1.25, 1.5), CurvePoint(2, 2)]
        let first = try Self.encoder.encode(points)
        let decoded = try JSONDecoder().decode([CurvePoint].self, from: first)
        XCTAssertEqual(decoded, points, "double 往返不丢精度")
        XCTAssertEqual(try Self.encoder.encode(decoded), first, "写→读→写逐字节相等")
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertTrue(text.contains("0.219178"), "sidecar 里是 double")
        print("round trip · \(text.prefix(160))")
    }

    func testTheFormatBlockSaysVersionTwoAndDoubles() throws {
        var edit = EditModel.neutral
        edit.curve.white = [CurvePoint(0, 0), CurvePoint(0.44, 0.34), CurvePoint(2, 2)]
        let data = try Self.encoder.encode(edit)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let curve = try XCTUnwrap(root["curve"] as? [String: Any])
        let format = try XCTUnwrap(curve["format"] as? [String: Any])
        XCTAssertEqual(Set(format.keys), ["version", "type", "max", "domain"])
        XCTAssertEqual(format["version"] as? Int, 2)
        XCTAssertEqual(format["type"] as? String, "double")
        XCTAssertEqual((format["max"] as? NSNumber)?.doubleValue, 2)
        XCTAssertEqual(format["domain"] as? String, "hdr", "工作范围是 HDR 线性域")

        let model = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(model.curve, edit.curve)
        XCTAssertEqual(model.curve.decodeWarnings, [])
        XCTAssertEqual(try Self.encoder.encode(model), data, "整份文档写→读→写逐字节相等")
        print("format · \(format)")
    }

    // MARK: 3-4. the two older formats

    func testVersionOneCellsMapOntoTheNewCoordinate() throws {
        let json = """
        {"format":{"version":1,"type":"int","max":511,"domain":"hdr"},
         "white":[{"x":0,"y":0},{"x":112,"y":87},{"x":511,"y":511}]}
        """.data(using: .utf8)!
        let group = try JSONDecoder().decode(CurveGroup.self, from: json)
        XCTAssertEqual(group.white[1].x, 2.0 * 112 / 511, accuracy: 1e-15, "x_new = 2·112/511")
        XCTAssertEqual(group.white[1].y, 2.0 * 87 / 511, accuracy: 1e-15, "y_new = 2·87/511")
        XCTAssertEqual(group.white[2].x, 2, accuracy: 1e-15, "格 511 就是 x = 2")
        print("v1 cells · 112,87 → \(group.white[1].x), \(group.white[1].y)")
    }

    func testADocumentWithoutAFormatBlockIsOldAxisCoordinates() throws {
        let json = """
        {"schemaVersion":4,"processVersion":2,
         "curve":{"rgb":[{"x":0,"y":0},{"x":0.22,"y":0.17},{"x":1,"y":1}]}}
        """.data(using: .utf8)!
        let model = try JSONDecoder().decode(EditModel.self, from: json)
        XCTAssertEqual(model.curve.white[1].x, 0.44, accuracy: 1e-15, "x_new = 2·0.22")
        XCTAssertEqual(model.curve.white[1].y, 0.34, accuracy: 1e-15)
        XCTAssertEqual(model.curve, CurveGroup(white: [CurvePoint(0, 0), CurvePoint(0.44, 0.34),
                                                       CurvePoint(2, 2)]))
        // …and the identity of every old document survives: 0…1 becomes 0…2.
        let identity = """
        {"curve":{"white":[{"x":0,"y":0},{"x":1,"y":1}]}}
        """.data(using: .utf8)!
        let old = try JSONDecoder().decode(EditModel.self, from: identity)
        XCTAssertEqual(old.curve.white, CurvePoint.linear)
        XCTAssertEqual(CurveLUT.buildOne(old.curve.white), CurveLUT.identityTable(),
                       "旧恒等读进来必须仍是恒等表")

        let written = try Self.encoder.encode(model)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        let curve = try XCTUnwrap(root["curve"] as? [String: Any])
        let format = try XCTUnwrap(curve["format"] as? [String: Any], "写回必须补上 format")
        XCTAssertEqual(format["version"] as? Int, 2)
        XCTAssertNil(curve["rgb"], "030 之后写的是 white")
        print("legacy 0…1 · 0.22 → \(model.curve.white[1].x) · format \(format)")
    }

    // MARK: 5. range: documents throw, the pointer clamps

    func testOutOfRangeThrowsOnTheValidatingPath() {
        XCTAssertNoThrow(try CurvePoint(validating: 2, 2), "2.0 合法")
        XCTAssertNoThrow(try CurvePoint(validating: 1.9999, 0), "1.9999 合法")
        XCTAssertEqual((1.9999 - CurvePoint.sdrBoundary) * 4, 3.9996, accuracy: 1e-12,
                       "1.9999 → +3.9996 EV")

        XCTAssertThrowsError(try CurvePoint(validating: 2.0001, 0)) { error in
            XCTAssertEqual(error as? CurveCoordinateOutOfRange,
                           CurveCoordinateOutOfRange(value: 2.0001, axis: "x"))
        }
        XCTAssertThrowsError(try CurvePoint(validating: 2.25, 1)) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("2.25"), message)
            XCTAssertTrue(message.contains("+4"), "错误里要说明当前只支持到 +4 EV：\(message)")
            XCTAssertTrue(message.contains("version"), "并说明将来要升 version：\(message)")
        }
        XCTAssertThrowsError(try CurvePoint(validating: 1, 2.5))
        XCTAssertThrowsError(try CurvePoint(validating: -0.0001, 0))
        XCTAssertThrowsError(try CurvePoint(validating: .nan, 0))

        // A **document** carrying 2.5 fails to load with that error, rather than being clamped or the
        // curve being quietly dropped.
        let json = """
        {"curve":{"format":{"version":2,"type":"double","max":2,"domain":"hdr"},
                  "white":[{"x":0,"y":0},{"x":2.5,"y":1},{"x":2,"y":2}]}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(EditModel.self, from: json)) { error in
            XCTAssertEqual(error as? CurveCoordinateOutOfRange,
                           CurveCoordinateOutOfRange(value: 2.5, axis: "x"))
        }
        print("range · 2.0 ok · 2.0001 / 2.25 / −1e-4 / NaN throw · 文档 x=2.5 throw")
    }

    func testTheInteractionPathClampsInsteadOfThrowing() {
        XCTAssertEqual(CurvePoint(5, 5), CurvePoint(2, 2))
        XCTAssertEqual(CurvePoint(-1, 0.5), CurvePoint(0, 0.5))
        XCTAssertEqual(CurvePoint(.nan, .infinity), CurvePoint(0, 0), "非有限值落在 0")
        // A coordinate that came from the plot is in the box by construction, so the clamp can only
        // ever be a no-op or an edge — which is why it is allowed to exist here and not in the file path.
        XCTAssertEqual(CurvePoint(1.9999, 2).x, 1.9999, accuracy: 1e-15, "框内原样通过")
        print("clamp · CurvePoint(5,5) → (2,2) · 框内值原样保留")
    }

    // MARK: 5b. the axis is not a written-down 2

    /// `u = x / 2` is the map every consumer already has; after the map was written as "the SDR half
    /// fills `0…whiteU`, the HDR half fills `whiteU…1`" it must still be the *same bits* — that is what
    /// makes it safe to widen the card later without re-recording a single pixel.
    func testTheAxisMapIsStillXOverTwoToday() {
        var worstU = 0.0, worstRound = 0.0
        for i in 0...20000 {
            let x = CurvePoint.maximum * Double(i) / 20000
            let p = CurvePoint(x, x)
            worstU = max(worstU, abs(p.u - x / 2))
            worstRound = max(worstRound, abs(CurvePoint(u: p.u, v: p.v).x - x))
            XCTAssertEqual(p.v, p.u, "x == y 的点两个坐标必须一致")
        }
        XCTAssertEqual(worstU, 0, "u 与 x/2 逐位相等（20 001 个采样）")
        XCTAssertEqual(worstRound, 0, "x → u → x 逐位回到原点")
        // The split is written once, so the anchors of a *wider* card are the same expression:
        // 1 is still display white and `maximum` is still the right edge.
        XCTAssertEqual(CurvePoint.axisCoordinate(CurvePoint.sdrBoundary),
                       HDRCurveAxis.standard.whiteU, accuracy: 0, "x = 1 就是白点")
        XCTAssertEqual(CurvePoint.axisCoordinate(CurvePoint.maximum), 1, accuracy: 0, "x = max 就是右端")
        XCTAssertEqual(CurvePoint.cardCoordinate(1), CurvePoint.maximum, accuracy: 0)
        print("axis map · u − x/2 max |Δ| = \(worstU) · round trip max |Δ| = \(worstRound)")
    }

    /// A point as a **document** carries it. `CurvePoint`'s public inits are the interaction's (clamp)
    /// and the file's (throw), so an `x` beyond today's card — which is exactly what a future-version
    /// file or a synthetic fixture holds — can only be decoded. The keys are the synthesized ones.
    private func pointFromDocument(_ x: Double, _ y: Double) throws -> CurvePoint {
        let json = "{\"x\":\(x),\"y\":\(y)}".data(using: .utf8)!
        return try JSONDecoder().decode(CurvePoint.self, from: json)
    }

    // MARK: 7. near-coincident control points

    /// Two points a few nanometres apart are **one** point to the table, and the newer one wins. The
    /// window is `CurveLUT.dedupeWindow(axis:)` — a fraction of the card, not a constant.
    ///
    /// The counter-proof (`==` instead of the window) makes this case red: `0.4` and `0.4 + 10ε` are
    /// distinct `Double`s, so an equality test keeps both, and both is what the spike comes from.
    func testPointsInsideTheAxisWindowCollapseToTheNewest() throws {
        let axis = CurvePoint.maximum
        let epsilon = CurveLUT.coordinateEpsilon(axis: axis)
        let window = CurveLUT.dedupeWindow(axis: axis)
        XCTAssertEqual(epsilon, axis * 1e-9, "分辨率是量程的 1e-9")
        XCTAssertEqual(window, axis * 1e-6, "窗口是量程的 1e-6（pre-069 的 1e-6 换算到 0…2）")
        XCTAssertEqual(window / epsilon, 1000, accuracy: 1e-6)

        let older = CurvePoint(0.4, 0.45)
        let newer = CurvePoint(0.4 + 10 * epsilon, 0.9)
        XCTAssertNotEqual(older, newer, "两个点的坐标确实不同")

        let kept = CurveLUT.dedupe([older, newer], axis: axis)
        XCTAssertEqual(kept.count, 1, "相距 10ε 的两点是同一个点")
        XCTAssertEqual(kept.first, newer, "留下的是较新的那个")

        // The boundary is the window itself: half of it is one point, twice it is two.
        let halfWindow = CurvePoint(0.4 + window / 2, 0.9)
        let twoWindows = CurvePoint(0.4 + 2 * window, 0.9)
        XCTAssertEqual(CurveLUT.dedupe([older, halfWindow], axis: axis).count, 1, "半个窗口 → 一点")
        XCTAssertEqual(CurveLUT.dedupe([older, twoWindows], axis: axis).count, 2, "两个窗口 → 两点")

        // …and the collapse is **bit-exact**: a near-duplicate must be erased, not smoothed.
        let both = CurveLUT.buildOne([CurvePoint(0, 0), older, newer, CurvePoint(2, 2)])
        let one = CurveLUT.buildOne([CurvePoint(0, 0), newer, CurvePoint(2, 2)])
        XCTAssertEqual(both, one, "近重合点在表里必须被逐位擦掉")

        // A real gap (0.001 ≫ window) is two points, and the table must show it — without this the
        // equality above would be satisfied by a `buildOne` that ignores the second point anyway.
        let apart = CurvePoint(0.401, 0.9)
        XCTAssertEqual(CurveLUT.dedupe([older, apart], axis: axis).count, 2)
        XCTAssertNotEqual(CurveLUT.buildOne([CurvePoint(0, 0), older, apart, CurvePoint(2, 2)]),
                          CurveLUT.buildOne([CurvePoint(0, 0), apart, CurvePoint(2, 2)]),
                          "0.001 是真正的两点，表必须不同")

        // No spike: the surviving curve's steepest sample step is a small multiple of the mean step.
        let diffs = zip(one, one.dropFirst()).map { $1 - $0 }
        let meanStep = diffs.reduce(0, +) / Float(diffs.count)
        let ratio = diffs.max()! / meanStep
        XCTAssertTrue(diffs.allSatisfy { $0 >= 0 }, "单调不折")
        XCTAssertLessThan(ratio, 4, "最陡一步不超过平均步长的 4 倍")
        print("near-coincident · ε = \(epsilon) · 窗口 = \(window) · 10ε 距离 \(newer.x - older.x) → 1 点"
              + " · 0.5×窗口 → 1 点 · 2×窗口 → 2 点 · 0.001 → 2 点"
              + " · 最陡/平均步长比 \(ratio)")
    }

    /// The window is a **fraction of the axis**: a pair `3e-6` apart is one point on a `0…4` card and
    /// two points on today's `0…2` card, with no code change between them.
    func testTheWindowFollowsTheAxisAndAPointBeyondTwoStillBuildsATable() throws {
        let wide = 2 * CurvePoint.maximum      // the +8 EV card `maximum`'s comment anticipates
        XCTAssertEqual(CurveLUT.coordinateEpsilon(axis: wide), 2 * CurveLUT.coordinateEpsilon(),
                       "分辨率随量程线性缩放，不写死")
        XCTAssertEqual(CurveLUT.dedupeWindow(axis: wide), 2 * CurveLUT.dedupeWindow(),
                       "窗口同样随量程线性缩放")

        let p = try pointFromDocument(3.0, 1.0)                  // deep inside a 0…4 card
        let tenEps = try pointFromDocument(3.0 + 10 * CurveLUT.coordinateEpsilon(axis: wide), 1.5)
        XCTAssertEqual(CurveLUT.dedupe([p, tenEps], axis: wide).count, 1, "0…4 上相距 10ε → 一点")
        // 3e-6 sits *between* the two windows (2e-6 on 0…2, 4e-6 on 0…4): the same pair of points is
        // one point on the wider card and two on today's — the window really is the axis's.
        let between = try pointFromDocument(3.0 + 3e-6, 1.5)
        XCTAssertEqual(CurveLUT.dedupe([p, between], axis: wide).count, 1, "3e-6 ≤ 窗口(0…4)")
        XCTAssertEqual(CurveLUT.dedupe([p, between], axis: CurvePoint.maximum).count, 2,
                       "3e-6 > 窗口(0…2)：同一对是两点")
        XCTAssertEqual(CurveLUT.dedupe([p, try pointFromDocument(3.001, 1.5)], axis: wide).count, 2,
                       "0.001 ≫ 窗口 仍然是两点")

        // A knot past the card's right edge must be **used**, not clamped away: today `x = 3` maps to
        // `u = 1.5` (`x / 2`), i.e. past the last sample, so the table can only show the segment up to
        // `u = 1`. What it shows there has to be the spline's own rising value — below the last knot
        // (0.75) and above the previous one (0.5), not the identity's 1.0, not a flat tail.
        let s = try pointFromDocument(3.0, 1.5)
        XCTAssertEqual(s.u, 1.5, accuracy: 0, "x = 3 在今天的轴上是 u = 1.5，没有截到 1.0")
        let table = CurveLUT.buildOne([CurvePoint(0, 0), CurvePoint(1, 1), s])
        XCTAssertEqual(table.count, CurveLUT.size)
        XCTAssertFalse(CurveLUT.isIdentityTable(table), "不能退回恒等")
        XCTAssertTrue(zip(table, table.dropFirst()).allSatisfy { $1 >= $0 }, "单调不折")
        XCTAssertGreaterThan(table.last!, 0.5, "表尾仍在该段上（不是被压回上一个节点）")
        XCTAssertLessThan(table.last!, 0.75, "…且没有跳到最后一个节点的值")
        XCTAssertNotEqual(table.last!, 1, "没有被静默截断成恒等")
        // The steepness of the whole table, sample by sample: the steepest step over the mean step.
        let diffs = zip(table, table.dropFirst()).map { $1 - $0 }
        let meanStep = diffs.reduce(0, +) / Float(diffs.count)
        let ratio = diffs.max()! / meanStep
        XCTAssertLessThan(ratio, 4, "无尖刺：最陡一步 < 平均步长的 4 倍")
        print("beyond 2 · ε(4) = \(CurveLUT.coordinateEpsilon(axis: wide))"
              + " · 窗口(4) = \(CurveLUT.dedupeWindow(axis: wide))"
              + " · x = 3 → u = \(s.u) · 表尾 \(table.last!) · 最陡/平均 \(ratio)")
    }

    // MARK: 6. versions

    func testAFutureVersionIsRefusedButTheRestOfTheDocumentLoads() throws {
        let json = """
        {"schemaVersion":4,"processVersion":2,
         "light":{"exposure":0.75,"contrast":12},
         "curve":{"format":{"version":3,"type":"double","max":2.25,"domain":"hdr"},
                  "white":[{"x":0,"y":0},{"x":1.9,"y":1.2},{"x":2.25,"y":2.25}]}}
        """.data(using: .utf8)!
        let model = try JSONDecoder().decode(EditModel.self, from: json)
        XCTAssertEqual(model.curve, CurveGroup.identity, "不认识的版本不许猜")
        XCTAssertEqual(model.curve.decodeWarnings.count, 1)
        XCTAssertTrue(model.curve.decodeWarnings[0].contains("version 3"))
        XCTAssertEqual(model.light.exposure, 0.75, accuracy: 1e-12)
        XCTAssertEqual(model.light.contrast, 12, accuracy: 1e-12)
        print("future version · \(model.curve.decodeWarnings[0]) · exposure 仍为 \(model.light.exposure)")
    }

    func testATypeThatIsNotDoubleIsReadAsCoordinatesAndWarned() throws {
        let json = """
        {"format":{"version":2,"type":"int","max":2,"domain":"hdr"},
         "white":[{"x":0,"y":0},{"x":1.5,"y":1.5},{"x":2,"y":2}]}
        """.data(using: .utf8)!
        let group = try JSONDecoder().decode(CurveGroup.self, from: json)
        XCTAssertEqual(group.white[1], CurvePoint(1.5, 1.5), "版本 2 的数字就是坐标本身")
        XCTAssertEqual(group.decodeWarnings.count, 1)
        XCTAssertTrue(group.decodeWarnings[0].contains("int"))
        print("type int in v2 · \(group.decodeWarnings[0])")
    }

    /// The sidecar's own encoder settings, so "byte-identical" is a property of the file this app
    /// writes (`.prettyPrinted, .sortedKeys`), not of a test-only encoder.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
