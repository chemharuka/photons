import XCTest
@testable import PhotonsCore

/// 195 — **the preview matrix's own contract**: identity where it must be, a real 3×3 where it must be,
/// a well-defined composition, and a safety valve that fires only on extrapolation.
///
/// The *accuracy* claim lives in `WhiteBalanceTwoStageGapTests` (codes) and
/// `WhiteBalanceModelProbeTests` (why). This file holds the properties that must not drift while the
/// main line decides what to do about the accuracy.
final class WhiteBalancePreviewMatrixTests: XCTestCase {

    private let asShot = WhiteBalance.asShot
    private let k6500 = WhiteBalance(temperature: 6500, tint: 0)
    private let k3200 = WhiteBalance(temperature: 3200, tint: 0)
    private let asShotPair = WhiteBalance(temperature: 5872, tint: 20)

    func testAsShotIsTheIdentityAndNeverNeedsAReference() {
        // Exact for the as-shot document (the runtime returns `.identity` outright), and to a ULP for
        // a ratio of two equal adaptations — `M(x)·M(x)⁻¹` is only exactly 1 to floating point's own
        // account, so the assertion is 1e-12 rather than `==`.
        XCTAssertEqual(WhiteBalanceEstimate.previewMatrix(from: asShot, to: asShot), .identity)
        XCTAssertEqual(WhiteBalanceEstimate.previewMatrix(from: asShotPair, to: asShot), .identity)
        let settled = WhiteBalanceEstimate.previewMatrix(from: k3200, to: k3200)
        XCTAssertLessThan(settled.maxAbsoluteDifference(from: .identity), 1e-12,
                          "a settled buffer must not be corrected twice")
    }

    /// The whole point of 195: the cross-channel terms are not decoration. A diagonal cannot express
    /// them, and they are exactly what 194 dropped.
    func testTheMatrixCarriesCrossTermsThatADiagonalCannot() {
        let m = WhiteBalanceEstimate.previewMatrix(from: asShot, to: k3200,
                                                   asShotPair: asShotPair)
        let offDiagonal = abs(m[0, 1]) + abs(m[0, 2]) + abs(m[1, 0])
            + abs(m[1, 2]) + abs(m[2, 0]) + abs(m[2, 1])
        print(String(format: "195 preview matrix @3200 K (as shot %@): off-diagonal mass %.4f"
                     + " · diag %.4f %.4f %.4f", asShotPair.summary, offDiagonal,
                     m[0, 0], m[1, 1], m[2, 2]))
        XCTAssertGreaterThan(offDiagonal, 0.05, "3200 K away from neutral must mix channels")
        XCTAssertGreaterThan(m[2, 2], m[0, 0], "a warm request must lift blue above red")
    }

    /// The as-shot **pair** is load-bearing: anchoring on the nominal 6500 K instead starts the ratio
    /// from a white the buffer never had (measured 5872 K/+20 on L1030433, 5552 K/+24 on the DJI).
    func testTheAnchorIsTheFilesAsShotPairNotNominal6500() {
        let anchored = WhiteBalanceEstimate.previewMatrix(from: asShot, to: k6500,
                                                          asShotPair: asShotPair)
        let nominal = WhiteBalanceEstimate.previewMatrix(from: asShot, to: k6500,
                                                         asShotPair: .asShot)
        XCTAssertLessThan(nominal.maxAbsoluteDifference(from: .identity), 1e-12,
                       "without a pair the model falls back to 6500 K, where 6500 K *is* the identity")
        XCTAssertNotEqual(anchored, .identity,
                          "with the real pair, a 6500 K request is a move — as the decoder measures")
    }

    /// `M(asShot→b) = M(a→b)·M(asShot→a)` — otherwise a drag from a settled rung would jump.
    func testTheCompositionOfTwoMovesIsTheDirectMove() {
        let a = WhiteBalance(temperature: 5000, tint: 10)
        let b = WhiteBalance(temperature: 7200, tint: -20)
        let direct = WhiteBalanceEstimate.previewMatrix(from: asShot, to: b, asShotPair: asShotPair)
        let chained = WhiteBalanceEstimate.previewMatrix(from: a, to: b)
            * WhiteBalanceEstimate.previewMatrix(from: asShot, to: a, asShotPair: asShotPair)
        for k in 0..<9 {
            XCTAssertEqual(chained.values[k], direct.values[k], accuracy: 1e-9, "entry \(k)")
        }
    }

    /// The valve: `|m| ≤ 3`. It must admit every pair §3 names and reject the cell the model
    /// extrapolates (2850 K/+60 asks for a 4.06× blue entry — measured 218 codes).
    func testTheValveAdmitsTheNamedPairsAndRejectsTheExtrapolation() {
        for pair in [k6500, k3200, WhiteBalance(temperature: 6500, tint: 30),
                     WhiteBalance(temperature: 6500, tint: -30)] {
            let m = WhiteBalanceEstimate.previewMatrix(from: asShot, to: pair, asShotPair: asShotPair)
            XCTAssertTrue(WhiteBalanceEstimate.isPlausiblePreviewMatrix(m),
                          "\(pair.summary) must pass the valve")
        }
        let extreme = WhiteBalanceEstimate.previewMatrix(
            from: asShot, to: WhiteBalance(temperature: 2850, tint: 60), asShotPair: asShotPair)
        let largest = extreme.values.map { abs($0) }.max() ?? 0
        print(String(format: "195 valve: 2850 K/+60 largest entry %.3f → %@", largest,
                     WhiteBalanceEstimate.isPlausiblePreviewMatrix(extreme)
                        ? "accepted" : "falls back to the diagonal"))
        XCTAssertFalse(WhiteBalanceEstimate.isPlausiblePreviewMatrix(extreme),
                       "a 4× entry is extrapolation, not correction")

        // The predicate is about magnitude, not sign or shape: a hand-made 3.0 passes, 3.01 does not.
        let ok = Matrix3(rows: [[0.5, 0.25, 0.25], [0.1, 1.0, -0.1], [0.2, 0.3, 2.9]])
        let bad = Matrix3(rows: [[0.5, 0.25, 0.25], [0.1, 1.0, -0.1], [0.2, 0.3, 3.01]])
        XCTAssertTrue(WhiteBalanceEstimate.isPlausiblePreviewMatrix(ok))
        XCTAssertFalse(WhiteBalanceEstimate.isPlausiblePreviewMatrix(bad))
        XCTAssertFalse(WhiteBalanceEstimate.isPlausiblePreviewMatrix(
            Matrix3(rows: [[.nan, 0, 0], [0, 1, 0], [0, 0, 1]])))
    }

    /// The reported gain is the matrix's diagonal, green-normalised — so "the number the frame
    /// reports" and "the matrix the kernel multiplied by" cannot drift apart.
    func testTheReportedGainIsTheMatricesDiagonal() {
        let quiet = WhiteBalance(temperature: 6500, tint: 0)
        let graph = try? RenderGraph(input: RenderInput(
            image: LinearImage(width: 1, height: 1, rgba: [1, 1, 1, 1],
                               colorSpace: "extendedLinearSRGB", decoderVersion: "8"),
            identity: "195-gain", asShotPair: asShotPair))
        guard let graph else { return XCTFail("no graph") }
        let g = graph.whiteBalanceGain(from: asShot, to: quiet)
        XCTAssertEqual(g.g, 1)
        XCTAssertTrue(g.r.isFinite && g.b.isFinite)
        // Green-normalised: exactly the diagonal of the matrix over m11.
        let m = graph.whiteBalanceMatrix(from: asShot, to: quiet)
        XCTAssertEqual(g.r, m[0, 0] / m[1, 1], accuracy: 1e-12)
        XCTAssertEqual(g.b, m[2, 2] / m[1, 1], accuracy: 1e-12)
        // The settled frame reports the identity — 194 §3's "one application, never two" still holds.
        XCTAssertEqual(graph.whiteBalanceGain(from: quiet, to: quiet).r, 1)
        XCTAssertEqual(graph.whiteBalanceGain(from: quiet, to: quiet).b, 1)
    }
}
