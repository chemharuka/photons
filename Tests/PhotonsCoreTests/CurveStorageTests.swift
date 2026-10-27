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
