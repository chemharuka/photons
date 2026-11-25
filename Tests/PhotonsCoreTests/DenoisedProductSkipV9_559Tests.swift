import XCTest
@testable import PhotonsCore

/// §559 — a source file whose **name** carries the denoise marker never chooses v9 automatically.
///
/// The marker is the shipped product naming (`<原名>-denoised.dng`, `-denoised-2.dng`), so no writer
/// changes are needed and today's products take effect immediately. The rule is applied **after** the
/// 555 policy table, which is why `.v9` documents and legacy `stored == "9"` documents fall back to
/// the classic family too — 「无论是自动还是 v9」.
///
/// These cases are pure: no RAW, no filter. The decode path passes the same `denoised:` flag from the
/// URL's last path component (see `RAWDecoder.decodeDetailed`), and `photonsctl info` prints it.
final class DenoisedProductSkipV9_559Tests: XCTestCase {

    private let all = ["9", "9.dng", "8", "8.dng"]

    // MARK: - 1. the file-name marker

    func testTheShippedProductNamesAreRecognised() {
        XCTAssertTrue(DecoderVersionPreference.isDenoisedProduct(name: "L1030946-denoised.dng"))
        XCTAssertTrue(DecoderVersionPreference.isDenoisedProduct(name: "X-DENOISED-2.dng"))
        XCTAssertTrue(DecoderVersionPreference.isDenoisedProduct(name: "-denoise-3.dng"))
        XCTAssertTrue(DecoderVersionPreference.isDenoisedProduct(name: "/tmp/a/L1030946-denoised.dng"),
                      "the marker is read from the last path component")
    }

    func testUnmarkedNamesAreNotDenoised() {
        XCTAssertFalse(DecoderVersionPreference.isDenoisedProduct(name: "L1030946.dng"))
        XCTAssertFalse(DecoderVersionPreference.isDenoisedProduct(name: ""))
        XCTAssertFalse(DecoderVersionPreference.isDenoisedProduct(name: "noise.dng"),
                       "`noise` is not the marker")
    }

    // MARK: - 2. the resolver skips v9

    func testAutoHighISOWithDenoisedMarkerStartsWithEight() {
        let got = DecoderVersionPreference.candidates(
            policy: .auto, preference: .auto, iso: 3200, stored: nil,
            denoised: true, in: all)
        XCTAssertEqual(got.first, "8")
        XCTAssertFalse(got.contains("9"), "no v9 spelling may survive: \(got)")
    }

    func testV9DocumentWithDenoisedMarkerFallsBackToEight() {
        let got = DecoderVersionPreference.candidates(
            policy: .v9, preference: .auto, iso: 3200, stored: nil,
            denoised: true, in: all)
        XCTAssertEqual(got.first, "8")
        XCTAssertFalse(got.contains("9"), "a .v9 document is pulled back too: \(got)")
    }

    func testLegacyStoredNineWithDenoisedMarkerFallsBackToEight() {
        let got = DecoderVersionPreference.candidates(
            policy: .auto, preference: .auto, iso: 3200, stored: "9",
            denoised: true, in: all)
        XCTAssertEqual(got.first, "8")
        XCTAssertFalse(got.contains("9"), "an old hand pick is pulled back too: \(got)")
    }

    /// The reverse gate: without the marker these three cases keep today's v9 answer.
    func testTheSameInputsWithoutTheMarkerStillChooseNine() {
        XCTAssertEqual(DecoderVersionPreference.candidates(
            policy: .auto, preference: .auto, iso: 3200, stored: nil,
            denoised: false, in: all).first, "9")
        XCTAssertEqual(DecoderVersionPreference.candidates(
            policy: .v9, preference: .auto, iso: 3200, stored: nil,
            denoised: false, in: all).first, "9")
        XCTAssertEqual(DecoderVersionPreference.candidates(
            policy: .auto, preference: .auto, iso: 3200, stored: "9",
            denoised: false, in: all).first, "9")
    }

    func testAFileWithOnlyV9AsksForNothingWhenDenoised() {
        let got = DecoderVersionPreference.candidates(
            policy: .v9, preference: .auto, iso: 3200, stored: nil,
            denoised: true, in: ["9", "9.dng"])
        XCTAssertTrue(got.isEmpty, "only v9 offered ⇒ follow Apple's default, not a hidden v9: \(got)")
    }

    func testResolutionLeavesOneAttributionNote() {
        let resolution = DecoderVersionPreference.resolve(
            policy: .v9, preference: .auto, iso: 3200, stored: nil,
            denoised: true, in: all) { $0 }
        XCTAssertEqual(resolution.selected, "8")
        XCTAssertTrue(resolution.notes.contains("文件名带 denoise：已降噪源跳过 v9（除非手动覆盖）"),
                      "实际 \(resolution.notes)")
    }
}
