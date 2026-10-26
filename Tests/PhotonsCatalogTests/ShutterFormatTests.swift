import XCTest
@testable import PhotonsCatalog

/// The "huge integer ratio" report plus the owner's display rule:
///
///   · faster than 0.1 s → `1/n`, snapped to the standard ladder;
///   · 0.1 s and slower → **seconds** (`0.3s`, `4s`, `12s`) — never two decimals, never a decimal
///     above one second;
///   · except the fractions people still say out loud: `1/2 1/3 1/4 1/5 1/6 1/10` — and a seconds
///     value that *rounds* to 0.5 re-enters that spelling (`0.45 → 0.5 → 1/2`).
final class ShutterFormatTests: XCTestCase {

    // MARK: - ① the real library values that started this

    func testRealLibraryRationalsBecomeStandardShutters() {
        // Copied from ~/Documents/photons-demo.photonslibrary (Leica SL3 DNGs).
        XCTAssertEqual(ShutterFormat.standard(from: "55924/44739201"), "1/800")
        XCTAssertEqual(ShutterFormat.standard(from: "31667/39583751"), "1/1250")
        XCTAssertEqual(ShutterFormat.standard(from: "27962/44739201"), "1/1600")
    }

    func testAlreadyStandardFastStringsAreUnchanged() {
        for s in ["1/250", "1/60", "1/8000", "1/320"] {
            XCTAssertEqual(ShutterFormat.standard(from: s), s)
        }
    }

    /// The old EXIF path floored to `1/8006`; off-grid denominators snap in log space.
    func testOffGridDenominatorsSnapInLogSpace() {
        XCTAssertEqual(ShutterFormat.standard(seconds: 1.0 / 8006), "1/8000")
        XCTAssertEqual(ShutterFormat.standard(seconds: 1.0 / 750), "1/800")
        XCTAssertEqual(ShutterFormat.standard(seconds: 1.0 / 13), "1/13")
    }

    // MARK: - ② the fractions that keep their reciprocal spelling

    func testSpokenFractionsStayReciprocalEvenAboveATenth() {
        let cases: [(Double, String)] = [
            (1.0 / 3, "1/3"), (1.0 / 4, "1/4"),
            (1.0 / 5, "1/5"), (1.0 / 6, "1/6"), (1.0 / 10, "1/10"),
        ]
        for c in cases {
            XCTAssertEqual(ShutterFormat.standard(seconds: c.0), c.1, "1/\(c.0)")
        }
    }

    // MARK: - ③ seconds form

    func testSlowShuttersAreWrittenInSeconds() {
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.4), "0.4s")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.8), "0.8s")
        XCTAssertEqual(ShutterFormat.standard(seconds: 1.6), "2s", "above one second: no decimals")
        XCTAssertEqual(ShutterFormat.standard(seconds: 4.0), "4s")
        XCTAssertEqual(ShutterFormat.standard(seconds: 12.0), "12s")
        XCTAssertEqual(ShutterFormat.standard(from: "12"), "12s")
    }

    func testTheFractionBandCoversAnEighthAndATenth() {
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.125), "1/8")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.1), "1/10")
    }

    /// The banding: 0.1…0.35 s is a fraction, above that it is seconds (half a second included).
    func testTheBandBoundaries() {
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.34), "1/3", "still in the fraction band")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.35), "1/3", "the band's edge is inclusive")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.36), "0.4s", "past the edge: seconds, half up")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.45), "0.5s")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.5), "0.5s", "half a second is written 0.5s")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.55), "0.6s", "rounding is half up")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.62), "0.6s")
        XCTAssertEqual(ShutterFormat.standard(seconds: 3.5), "4s", "half up above a second too")
    }

    func testTheFractionBandSnapsWithinOneThirdToOneTenth() {
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.125), "1/8")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.1), "1/10")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.15), "1/6")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.2), "1/5")
        XCTAssertEqual(ShutterFormat.standard(seconds: 0.25), "1/4")
    }

    func testNeverTwoDecimals() {
        for t in [0.31, 0.37, 0.62, 0.87] {
            let s = ShutterFormat.standard(seconds: t) ?? ""
            guard let dot = s.firstIndex(of: ".") else { continue }   // a fraction has no decimals
            let decimals = s[s.index(after: dot)...].dropLast().count
            XCTAssertLessThanOrEqual(decimals, 1, "\(t) rendered as \(s)")
        }
    }

    // MARK: - ④ robustness

    func testUnitsAndWhitespaceAreTolerated() {
        XCTAssertEqual(ShutterFormat.standard(from: " 1/250 s "), "1/250")
        XCTAssertEqual(ShutterFormat.standard(from: "1/250s"), "1/250")
        XCTAssertEqual(ShutterFormat.standard(from: "0.004"), "1/250")
        XCTAssertEqual(ShutterFormat.standard(from: "0.3"), "1/3", "0.3 s is inside the fraction band")
        XCTAssertEqual(ShutterFormat.standard(from: "0.7"), "0.7s")
    }

    func testDegenerateInputDoesNotCrashOrInventAValue() {
        XCTAssertNil(ShutterFormat.seconds(from: "0/0"))
        XCTAssertNil(ShutterFormat.seconds(from: "abc"))
        XCTAssertNil(ShutterFormat.seconds(from: "-1/250"))
        XCTAssertNil(ShutterFormat.standard(seconds: 0))
        XCTAssertNil(ShutterFormat.standard(seconds: .nan))
        XCTAssertNil(ShutterFormat.standard(from: ""))
    }
}
