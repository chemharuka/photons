import XCTest
import CoreImage
@testable import PhotonsCore

/// 164 §3.2 — **去摩尔纹** is a fifth `CIRAWFilter` amount on the 开发 card
/// (`moireReductionAmount`, 0…3; slider 0…30), decoded with the same rules as 031's four axes:
///
///   · `nil` = leave Apple's own amount alone (measured on `L1030433.dng`: **0.55 on v8**, 0.0 on
///     `8.dng`, unsupported on `9.dng`);
///   · a non-`nil` position is a decode input (the rung identity and `decodeKey` move);
///   · a pre-164 document re-encodes byte for byte, and a document that never touched the row keeps
///     the old `dt=…` key text;
///   · v9's `isMoireReductionSupported == false` vetoes the assignment, exactly like 色彩降噪 / 细节.
final class MoireReductionTests: XCTestCase {

    private var leica: DetailBaseline { .measured }

    // MARK: - 1. positions

    func testTheRowTravelsZeroToThirtyAndMapsTenPositionsToOneAmount() {
        XCTAssertEqual(DetailSettings.moireRange, 0 ... 30)
        XCTAssertEqual(DetailSettings.moirePositionPerAmount, 10)
        XCTAssertEqual(DetailSettings.moireMaxAmount, 3)

        // The filter's own default (measured 0.55) is position 17, and parking there stores nil.
        XCTAssertEqual(leica.moireDefaultPosition, 17)
        var s = DetailSettings.identity
        s.setMoirePosition(17, in: leica)
        XCTAssertNil(s.moire, "拖回本机默认位置 = 不赋值")
        s.setMoirePosition(30, in: leica)
        XCTAssertEqual(s.moire, 30)
        XCTAssertEqual(DetailSettings.moireDecodeAmount(slider: s.moire, baseline: leica.moire), 3)
        s.setMoirePosition(0, in: leica)
        XCTAssertEqual(s.moire, 0, "0 is a real amount (no moiré reduction), not the default")
        XCTAssertEqual(DetailSettings.moireDecodeAmount(slider: 0, baseline: leica.moire), 0)

        // A file whose baseline is 0 has its default position at 0; 0 is then "leave it alone".
        let dng = DetailBaseline(luminanceNR: 0, colorNR: 0.5, sharpness: 0.5, detail: 0, moire: 0)
        XCTAssertEqual(dng.moireDefaultPosition, 0)
        XCTAssertNil(DetailSettings.moireDecodeAmount(slider: 0, baseline: dng.moire))
        XCTAssertEqual(DetailSettings.moireDecodeAmount(slider: 20, baseline: dng.moire), 2)
    }

    // MARK: - 2. the decode key

    func testMoireIsADecodeInputAndTheDefaultDocumentAppendsNothing() {
        var edit = EditModel.neutral
        let baseKey = edit.decodeKey
        let baseComponent = edit.decodeInputs.detailComponent
        XCTAssertNil(baseComponent, "a document that never touched the card appends nothing")

        edit.detailSettings.moire = 30
        let setKey = edit.decodeKey
        XCTAssertNotEqual(setKey, baseKey, "设置去摩尔纹 = 新缓冲")
        XCTAssertEqual(edit.decodeInputs.detailComponent, "dt=nr·,c·,s·,d·,m30")

        // Back to nil → the very same key, so the old buffer is hit again.
        edit.detailSettings.moire = nil
        XCTAssertEqual(edit.decodeKey, baseKey)

        // Pre-164: a four-axis document keeps its exact `dt=…` text — no `,m·` suffix appears.
        edit.detailSettings.luminanceNR = 20
        XCTAssertEqual(edit.decodeInputs.detailComponent, "dt=nr20,c·,s·,d·")
    }

    func testTheDocumentRoundTripsMoireAndAnOldDocumentReencodesByteForByte() throws {
        var edit = EditModel.neutral
        edit.detailSettings.moire = 21
        let data = try JSONEncoder().encode(edit)
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.detailSettings.moire, 21, "往返不丢")

        // A document written before 164 has no `moire` key at all.
        let legacy = #"{"schemaVersion":12,"processVersion":2,"detailSettings":{"luminanceNR":20}}"#
        let old = try JSONDecoder().decode(EditModel.self, from: Data(legacy.utf8))
        XCTAssertNil(old.detailSettings.moire, "缺键 = Apple 自己的值，不是 NaN / 0")
        XCTAssertEqual(old.detailSettings.luminanceNR, 20)

        let encoded = try JSONEncoder().encode(old)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("\"luminanceNR\":20"))
        XCTAssertFalse(text.contains("moire"), "没碰过的字段不写键：旧文档逐字节不变")
    }

    // MARK: - 3. the seam (v9)

    func testV9ReportsMoireUnsupportedAndTheVetoLeavesItUnassigned() {
        XCTAssertTrue(DetailAxes.forDecoderVersion("8").moire)
        XCTAssertTrue(DetailAxes.forDecoderVersion("8.dng").moire)
        XCTAssertFalse(DetailAxes.forDecoderVersion("9.dng").moire,
                       "v9 的 isMoireReductionSupported 是 false（实测）")
        XCTAssertTrue(DetailAxes.v9.moire == false)
    }

    // MARK: - 4. the pixels (fixture-gated)

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    /// The filter accepts the amount and the picture moves — on v8 and on `8.dng`; v9 refuses the
    /// assignment (its flag is false) and the pixels do not change.
    func testMoireIsReadBackAndMovesPixelsOnTheVersionsThatSupportIt() throws {
        let url = try fixtureURL()
        let decoder = try RAWDecoder()
        let base = try decoder.decodeDetailed(url, options: DecodeOptions(scale: 0.15))

        var detail = DetailSettings()
        detail.moire = 30
        let moved = try decoder.decodeDetailed(url, options: DecodeOptions(scale: 0.15, detail: detail))
        XCTAssertEqual(moved.detailApplied.moire, 3, "30 → amount 3, read back exactly")
        XCTAssertGreaterThan(maxDelta(base.image, moved.image), 0.001,
                             "去摩尔纹 必须改变 v8 的像素")

        // v8.dng: the same assignment lands and moves pixels.
        let dngBase = try decoder.decodeDetailed(
            url, options: DecodeOptions(decoderVersion: "8.dng", scale: 0.15))
        let dngMoved = try decoder.decodeDetailed(
            url, options: DecodeOptions(decoderVersion: "8.dng", scale: 0.15, detail: detail))
        XCTAssertEqual(dngMoved.detailApplied.moire, 3)
        XCTAssertGreaterThan(maxDelta(dngBase.image, dngMoved.image), 0.001,
                             "去摩尔纹 在 8.dng 上也必须生效")

        // v9: unsupported → the value is never written, and the pixels are the v9 default frame.
        let v9Base = try decoder.decodeDetailed(
            url, options: DecodeOptions(decoderVersion: "9.dng", scale: 0.15))
        let v9Moved = try decoder.decodeDetailed(
            url, options: DecodeOptions(decoderVersion: "9.dng", scale: 0.15, detail: detail))
        XCTAssertNil(v9Moved.detailApplied.moire, "v9 不支持 → 我们不赋值")
        XCTAssertEqual(maxDelta(v9Base.image, v9Moved.image), 0, accuracy: 0)
    }

    private func maxDelta(_ a: LinearImage, _ b: LinearImage) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        var m: Float = 0
        for i in stride(from: 0, to: min(a.rgba.count, b.rgba.count), by: 4) {
            for c in 0..<3 {
                m = max(m, abs(Float(a.rgba[i + c]) - Float(b.rgba[i + c])))
            }
        }
        return Double(m)
    }
}
