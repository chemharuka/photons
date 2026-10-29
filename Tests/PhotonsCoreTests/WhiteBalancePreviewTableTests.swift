import XCTest
@testable import PhotonsCore

/// The measured `(K, tint) → linear gain` table behind the white-balance drag preview (118).
///
/// What these hold: the lookup is **exact on its nodes**, linear between them, and `gain(from:to:)` is
/// a ratio of two nodes (so it does not care which pair the table was measured against). The camera
/// match is substring-based because `photonsctl info`'s camera line carries the body and the ISO.
final class WhiteBalancePreviewTableTests: XCTestCase {

    /// A 3 × 3 table with recognisable numbers: gain = (1 + 0.1·tempIndex, 1 − 0.1·tintIndex, 1).
    private func table() -> WhiteBalancePreviewTable {
        var gains: [[[Double]]] = []
        for t in 0..<3 {
            var row: [[Double]] = []
            for i in 0..<3 {
                row.append([1 + 0.1 * Double(t), 1 - 0.1 * Double(i), 1.0])
            }
            gains.append(row)
        }
        return WhiteBalancePreviewTable(camera: "LEICA SL3", decoderVersion: "8",
                                        asShot: .init(temperature: 5000, tint: 0),
                                        temperatures: [4000, 5000, 6000],
                                        tints: [-20, 0, 20],
                                        gains: gains)
    }

    func testNodesAreExact() throws {
        let t = table()
        let node = try XCTUnwrap(t.node(.init(temperature: 5000, tint: 0)))
        XCTAssertEqual(node.0, 1.1, accuracy: 1e-12)
        XCTAssertEqual(node.1, 0.9, accuracy: 1e-12)
        XCTAssertEqual(node.2, 1.0, accuracy: 1e-12)
    }

    func testBetweenNodesIsLinear() throws {
        let t = table()
        // Halfway in temperature, halfway in tint: the average of the four surrounding nodes.
        let mid = try XCTUnwrap(t.node(.init(temperature: 4500, tint: 10)))
        let a = try XCTUnwrap(t.node(.init(temperature: 4000, tint: 0)))
        let b = try XCTUnwrap(t.node(.init(temperature: 5000, tint: 0)))
        let c = try XCTUnwrap(t.node(.init(temperature: 4000, tint: 20)))
        let d = try XCTUnwrap(t.node(.init(temperature: 5000, tint: 20)))
        let expected = (a.0 + b.0 + c.0 + d.0) / 4
        XCTAssertEqual(mid.0, expected, accuracy: 1e-12)
        XCTAssertEqual(mid.1, (a.1 + b.1 + c.1 + d.1) / 4, accuracy: 1e-12)
    }

    func testOutOfRangeIsClampedNotExtrapolated() throws {
        let t = table()
        let cold = try XCTUnwrap(t.node(.init(temperature: 2000, tint: -100)))
        let atEdge = try XCTUnwrap(t.node(.init(temperature: 4000, tint: -20)))
        XCTAssertEqual(cold.0, atEdge.0, accuracy: 1e-12)
        XCTAssertEqual(cold.1, atEdge.1, accuracy: 1e-12)
    }

    func testGainIsTheRatioOfTwoNodes() throws {
        let t = table()
        let a = try XCTUnwrap(t.node(.init(temperature: 4000, tint: -20)))
        let b = try XCTUnwrap(t.node(.init(temperature: 6000, tint: 20)))
        let g = try XCTUnwrap(t.gain(from: .init(temperature: 4000, tint: -20),
                                     to: .init(temperature: 6000, tint: 20)))
        XCTAssertEqual(g.r, b.0 / a.0, accuracy: 1e-12)
        XCTAssertEqual(g.g, b.1 / a.1, accuracy: 1e-12)
        XCTAssertEqual(g.b, b.2 / a.2, accuracy: 1e-12)
    }

    func testGainRoundTripsToUnity() throws {
        let t = table()
        let p = WhiteBalancePreviewTable.Point(temperature: 4200, tint: -5)
        let q = WhiteBalancePreviewTable.Point(temperature: 5700, tint: 15)
        let there = try XCTUnwrap(t.gain(from: p, to: q))
        let back = try XCTUnwrap(t.gain(from: q, to: p))
        XCTAssertEqual(there.r * back.r, 1, accuracy: 1e-12)
        XCTAssertEqual(there.g * back.g, 1, accuracy: 1e-12)
        XCTAssertEqual(there.b * back.b, 1, accuracy: 1e-12)
    }

    func testCameraMatching() {
        let t = table()
        XCTAssertTrue(t.describes(camera: "LEICA SL3"))
        XCTAssertTrue(t.describes(camera: "leica sl3"))
        XCTAssertTrue(t.describes(camera: "LEICA CAMERA AG / LEICA SL3  ISO 100"))
        XCTAssertFalse(t.describes(camera: "SONY ILCE-7M4"))
        XCTAssertFalse(t.describes(camera: ""))
    }

    func testSaveAndLoadRoundTrip() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wbtable-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let t = table()
        try t.save(to: dir)
        let loaded = WhiteBalancePreviewTable.loadAll(from: dir)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, t)
    }

    func testMalformedTableReturnsNil() {
        let broken = WhiteBalancePreviewTable(camera: "x", decoderVersion: "8",
                                              asShot: .init(temperature: 5000, tint: 0),
                                              temperatures: [4000], tints: [-20, 0],
                                              gains: [[[1, 1, 1]]])
        XCTAssertNil(broken.node(.init(temperature: 4000, tint: 0)))
        XCTAssertNil(broken.gain(from: .init(temperature: 4000, tint: 0),
                                 to: .init(temperature: 4000, tint: 0)))
    }
}
