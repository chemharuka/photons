import XCTest
import CryptoKit
import PhotonsCore

/// 派单 137 — 曲线反相（右点低于左点）。
///
/// The engine used to accept only non-decreasing tables: mixed-direction input fell back to the
/// identity, and a globally descending list hit the same fold guard. A film negative needs the whole
/// curve to descend, so `CurveLUT.buildOne` now dispatches on the sign of every adjacent `Δv`:
/// non-decreasing keeps the historical bytes, non-increasing reflects `v`, mixed is refused by name.
final class CurveInvertTests: XCTestCase {

    private func sha(_ table: [Float]) -> String {
        var data = Data()
        for v in table {
            var bits = v.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// ① The positive path is byte-for-byte what it was before the change. These hashes were recorded
    /// from the pre-137 build; the non-decreasing branch is the old code, moved into a helper without
    /// arithmetic changes.
    func testNonDecreasingTablesAreByteIdenticalToThePreChangeBuild() {
        let expected: [(String, String, [CurvePoint])] = [
            ("identity", "660c27294c9ccb1de1d9d5a249e25e7c0bd5df98440712e78ddd90aa1754fe16",
             CurvePoint.linear),
            ("S mild", "a2dde2e87a6a25e97d03e42879f85e3349ac1282c620f1b8991bf84e7d0558cc",
             [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.25, v: 0.20),
              CurvePoint(u: 0.75, v: 0.80), CurvePoint(u: 1, v: 1)]),
            ("S hard", "832919511dd3aa509c754e3a05cc8f49935ac37d051ca1c119bb70bb03f3a815",
             [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.2, v: 0.03),
              CurvePoint(u: 0.4, v: 0.22), CurvePoint(u: 0.6, v: 0.78),
              CurvePoint(u: 0.8, v: 0.97), CurvePoint(u: 1, v: 1)]),
            ("roll-off", "e130a48c4c93e410ae44f46830d824e5e0d7e4bb7c2cc06bbb9171e827612a34",
             [CurvePoint(u: 0, v: 0), CurvePoint(u: 1, v: 0.86)]),
            ("black lifted", "a3c8095a2d0dfe9e14f394fd8f4bab187795febc669caba673c6be8c932b7c79",
             [CurvePoint(u: 0, v: 0.3), CurvePoint(u: 1, v: 1)]),
        ]
        for (name, want, points) in expected {
            let got = sha(CurveLUT.buildOne(points))
            XCTAssertEqual(got, want, "\(name) 的非递减表必须与改动前逐字节相同")
        }
        print("137 positive path · \(expected.count) tables byte-identical to pre-137")
    }

    /// ② A full-axis descending list is accepted and the table is strictly decreasing, not merely
    /// non-increasing. The axis is untouched: sample `i` is still `u = i/(N−1)`.
    func testInvertedCurveIsAcceptedAndItsTableIsStrictlyDecreasing() {
        let points = [CurvePoint(u: 0, v: 1), CurvePoint(u: 1, v: 0)]
        XCTAssertEqual(CurveLUT.direction(of: points), .decreasing)
        XCTAssertNil(CurveLUT.shapeError(of: points))

        let table = CurveLUT.buildOne(points)
        XCTAssertEqual(table.count, CurveLUT.size)
        XCTAssertTrue(zip(table, table.dropFirst()).allSatisfy { $1 < $0 },
                      "the table must descend at every one of its \(CurveLUT.size) samples")
        XCTAssertEqual(table.first ?? -1, 1, accuracy: 1e-6)
        XCTAssertEqual(table.last ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(CurveLUT.slope(of: table), -1, accuracy: 1e-3,
                       "a full descending line's tail slope is −1, and it must not be clamped to 0")
        XCTAssertEqual(HDRCurve.clampTailSlope(-1), -1, accuracy: 1e-12)

        // The same shape in the card's `0…2` coordinates.
        let card = [CurvePoint(0, 2), CurvePoint(2, 0)]
        XCTAssertTrue(zip(CurveLUT.buildOne(card), CurveLUT.buildOne(card).dropFirst())
                        .allSatisfy { $1 < $0 })

        // ③ The SDR inversion the user asked for: card (0,1) → (1,0) maps display code `e` to `1 − e`,
        // so an SDR-only descending segment is accepted too (it is constant above display white).
        let sdr = [CurvePoint(0, 1), CurvePoint(1, 0)]
        XCTAssertEqual(CurveLUT.direction(of: sdr), .decreasing)
        let sdrTable = CurveLUT.buildOne(sdr)
        XCTAssertTrue(zip(sdrTable, sdrTable.dropFirst()).allSatisfy { $1 <= $0 })
        let half = CurveLUT.size / 2
        XCTAssertTrue(zip(sdrTable[0...half], sdrTable[1...half]).allSatisfy { $1 < $0 },
                      "the drawn SDR segment descends strictly, sample by sample")
        XCTAssertEqual(sdrTable[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(sdrTable[CurveLUT.size / 2], 0, accuracy: 1e-6)
        XCTAssertEqual(sdrTable[CurveLUT.size - 1], 0, accuracy: 1e-6,
                       "above display white the user's descending segment holds black")
    }

    /// ④ Mixed direction is refused **by name**, and a hand-written document still renders the
    /// deterministic identity rather than a half-built table or a NaN.
    func testMixedDirectionIsRefusedByNameAndFallsBackToIdentity() {
        let mixed = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 1), CurvePoint(u: 1, v: 0)]
        XCTAssertEqual(CurveLUT.direction(of: mixed), .mixed)
        XCTAssertEqual(CurveLUT.shapeError(of: mixed), .mixedDirection)
        XCTAssertFalse(CurveShapeError.mixedDirection.hint.isEmpty)

        let table = CurveLUT.buildOne(mixed)
        XCTAssertEqual(table, CurveLUT.identityTable(), "a mixed hand-written list renders the identity")
        XCTAssertTrue(table.allSatisfy(\.isFinite))
    }

    /// ⑤ 600 random non-increasing curves (with equal neighbours and tiny gaps) must come out
    /// non-increasing at tolerance 0. Same LCG and spacing discipline as `HDRCurveTests`' positive
    /// random set, reflected.
    func testSixHundredRandomNonIncreasingCurvesNeverFold() {
        var seed: UInt64 = 0x5DEECE66D
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64(1) << 53)
        }

        var checked = 0
        for r in 0..<600 {
            var y = 0.6 + next() * 0.4
            var pts = [CurvePoint(u: 0, v: y)]
            var x = 0.02
            while x < 0.98 {
                if next() >= 0.15 { y = max(0, y - next() * 0.25) }
                pts.append(CurvePoint(u: x, v: y))
                x += 0.02 + next() * 0.08
            }
            pts.append(CurvePoint(u: 1, v: max(0, y - 0.01 - next() * 0.2)))
            XCTAssertEqual(CurveLUT.direction(of: pts), .decreasing, "random \(r) was not non-increasing")

            let table = CurveLUT.buildOne(pts)
            for i in 1..<table.count {
                XCTAssertLessThanOrEqual(table[i], table[i - 1],
                                         "random \(r) folded at sample \(i)")
                XCTAssertTrue(table[i].isFinite && table[i] >= 0 && table[i] <= 1)
            }
            checked += 1
        }
        print("137 · \(checked) random non-increasing curves × \(CurveLUT.size) samples: no folds")
    }

    /// ⑥ W is a luminance **gain**; an inverted W must not multiply the pixel by a negative number.
    /// Its table is the identity while R/G/B carry the inversion.
    func testInvertedWTakesTheIdentityTableAndRGBCarryTheInversion() {
        let inverted = [CurvePoint(0, 1), CurvePoint(1, 0)]
        var group = CurveGroup(white: inverted, red: inverted, green: inverted, blue: inverted)
        let tables = CurveLUT.build(group)
        let n = CurveLUT.size
        XCTAssertTrue(CurveLUT.isIdentityTable(tables[0..<n]), "an inverted W must be the identity")
        for t in 1..<4 {
            let slice = tables[t * n..<(t + 1) * n]
            XCTAssertFalse(CurveLUT.isIdentityTable(slice), "R/G/B must carry the inversion")
            XCTAssertTrue(zip(slice, slice.dropFirst()).allSatisfy { $1 <= $0 })
        }

        // …and the full-buffer path and the partial-rebuild path agree.
        XCTAssertEqual(CurveLUT.buildTable(inverted, index: 0), CurveLUT.identityTable())
        XCTAssertEqual(CurveLUT.buildTable(inverted, index: 1), CurveLUT.buildOne(inverted))
        group.white = [CurvePoint(0, 0), CurvePoint(1, 0.5), CurvePoint(2, 2)]
        XCTAssertFalse(CurveLUT.isIdentityTable(CurveLUT.build(group)[0..<n]),
                       "a positive W is not silently replaced by the identity")
    }

    /// ⑦ The `curve` stage key already names points in document order and both coordinates; the
    /// inversion case makes that load-bearing (same y set, different order = different table).
    func testCurveKeyIncludesOrderAndBothCoordinates() {
        let a = CurvePoint(0, 0)
        let b = CurvePoint(2, 2)
        XCTAssertNotEqual(CurveGroup(white: [a, b]).keyString,
                          CurveGroup(white: [b, a]).keyString,
                          "point order must move the key")
        XCTAssertNotEqual(CurveGroup(white: [a, b]).keyString,
                          CurveGroup(white: [a, CurvePoint(2, 1)]).keyString,
                          "y must move the key")
    }
}
