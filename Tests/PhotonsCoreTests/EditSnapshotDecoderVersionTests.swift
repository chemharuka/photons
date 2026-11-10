import XCTest
import PhotonsCore

/// 319 — 解码器版本 in the clipboard.
///
/// The user's report was 「开发卡片的复制没有效果（例如复制解码器版本为 v9dng 无效）」, and the root
/// cause was not the sheet: `EditSnapshot` had **no** decoder field at all, so copying 开发 collected
/// five render-side leaves and left the one decoder fact behind. What is pinned here:
///
///   ① `capture` carries the model, and only when the document pins one (`nil` = 跟随 Apple);
///   ② the wire key is `decoderVersion` and a pre-319 blob (no key) still decodes — as "keep yours";
///   ③ `applied` writes it, and `requiresDecode` is **true** for exactly that leaf;
///   ④ a copy narrowed to 解码器版本 alone is not empty (it is one leaf of 开发), while 锐化 alone asks
///      for **no** development — the 4.9 s guard the ticket spells out;
///   ⑤ the two decoders really do produce different pixels on the fixture, which is what makes ③ mean
///      something: a version that "pastes" but renders the same bytes would be a green test over a
///      broken feature.
final class EditSnapshotDecoderVersionTests: XCTestCase {

    // MARK: - helpers

    /// A document that pins a decoder model and nothing else the tests do not name.
    private func document(version: String?) -> EditModel {
        var a = EditModel.neutral
        a.light.exposure = 0.8
        a.detail.sharpening = 30
        a.decoderVersion = version
        return a
    }

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

    // MARK: - ① capture

    func testCaptureCarriesTheDecoderModelOnlyWhenTheDocumentPinsOne() {
        let withVersion = EditSnapshot.capture(document(version: "9"))
        let without = EditSnapshot.capture(document(version: nil))
        print("319 capture: pinned=\(String(describing: withVersion.decoderVersion))"
              + " unpinned=\(String(describing: without.decoderVersion))"
              + " sections=\(withVersion.sections.map(\.rawValue).sorted())")

        XCTAssertEqual(withVersion.decoderVersion, "9")
        XCTAssertNil(without.decoderVersion, "nil is 跟随 Apple：不携带，也不覆盖目标")
        // 开发 卡 is the card that owns it, so a version-only payload still names 开发.
        XCTAssertTrue(withVersion.sections.contains(.detail))
        // The other five leaves of the card are untouched by this field.
        XCTAssertEqual(withVersion.detail?.sharpening, 30)
        XCTAssertEqual(withVersion.fieldCount, 2, "曝光 + 锐化；版本不计入 slider 算术")
        XCTAssertTrue(withVersion.carriesDecoderVersion)
        XCTAssertEqual(EditSnapshotChild.decoderVersion.standaloneTitle, "解码器版本",
                       "开发 卡没有行表，所以它的名字写在字段旁边（325：spec 卡的行名一律从 `ToneRow` 取）")
        XCTAssertEqual(EditSnapshotChild.decoderVersion.section, .detail)
        XCTAssertTrue(EditSnapshotChild.decoderVersion.requiresDecode)
        XCTAssertFalse(EditSnapshotChild.sharpening.requiresDecode)
    }

    // MARK: - ② wire shape

    func testTheWireKeyIsDecoderVersionAndAPre319PayloadStillDecodes() throws {
        let snapshot = EditSnapshot.capture(document(version: "9.dng"))
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        print("319 wire: \(json)")
        XCTAssertTrue(json.contains("\"decoderVersion\""), "键名就是文档里的名字：\(json)")
        XCTAssertTrue(json.contains("9.dng"), "Apple 的拼写原样过线，不做 Int 归一化")

        let back = try JSONDecoder().decode(EditSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(back.decoderVersion, "9.dng")

        // A payload written before 319 has no such key: it must mean 「keep the destination's decoder」,
        // not fail to decode.
        let old = #"{"schemaVersion":3,"light":{"exposure":1.0}}"#
        let legacy = try JSONDecoder().decode(EditSnapshot.self, from: Data(old.utf8))
        XCTAssertNil(legacy.decoderVersion)
        XCTAssertEqual(legacy.light?.exposure, 1.0)
    }

    // MARK: - ③ paste + requiresDecode

    func testPasteWritesTheVersionAndThatLeafRequiresADevelopment() {
        let source = EditSnapshot.capture(document(version: "9"))
        var target = EditModel.neutral
        target.light.exposure = -0.3

        let pasted = source.applied(to: target)
        print("319 paste: target version \(String(describing: target.decoderVersion))"
              + " → \(String(describing: pasted.decoderVersion))"
              + " requiresDecode=\(source.requiresDecode)")

        XCTAssertEqual(pasted.decoderVersion, "9")
        XCTAssertEqual(pasted.light.exposure, 0.8)
        XCTAssertTrue(source.requiresDecode, "版本变了就是新缓冲：必须重解")

        // The narrowed payload 只勾「解码器版本」 is the ticket's exact gesture, and it must still carry
        // 开发 + the version and nothing else.
        let onlyVersion = source.filtered(to: [.detail], children: [.decoderVersion])
        XCTAssertEqual(onlyVersion.decoderVersion, "9")
        XCTAssertNil(onlyVersion.detail, "只勾版本时锐化不跟着走")
        XCTAssertNil(onlyVersion.light)
        XCTAssertFalse(onlyVersion.isEmpty, "只带版本的载荷不是空载荷")
        XCTAssertEqual(onlyVersion.sections, [.detail])
        XCTAssertTrue(onlyVersion.requiresDecode)

        // 反证 ④: 只勾锐化 re-renders, never re-develops.
        let onlySharpen = source.filtered(to: [.detail], children: [.sharpening])
        XCTAssertNil(onlySharpen.decoderVersion)
        XCTAssertEqual(onlySharpen.detail?.sharpening, 30)
        XCTAssertFalse(onlySharpen.requiresDecode,
                       "只勾锐化不许重解：v9 冷启 60 MP 要 4.9 s")

        // And without the field there is nothing to require the development for — the pre-319 shape.
        var legacy = source
        legacy.decoderVersion = nil
        XCTAssertFalse(legacy.requiresDecode)
    }

    // MARK: - ⑤ the effect is real

    /// Same RAW, v8 vs v9: the pixels must differ. If they do not, 「复制解码器版本」 cannot have an
    /// effect at all, and this ticket is a no-op dressed as a feature — so a same-hash result is a
    /// **failure**, not a tolerance.
    func testTheTwoDecoderVersionsRenderDifferentPixels() throws {
        let url = try fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        let newer = ["9", "9.dng"].first { offered.contains($0) }
        guard let newer, offered.contains("8") else {
            throw XCTSkip("this file offers no v8/v9 pair: \(offered)")
        }
        print("319 decoder versions offered: \(offered); comparing 8 vs \(newer)")

        let decoder = try RAWDecoder()
        let scale: Float = 0.2
        let v8 = try decoder.decode(url, options: DecodeOptions(decoderVersion: "8", scale: scale))
        let v9 = try decoder.decode(url, options: DecodeOptions(decoderVersion: newer, scale: scale))
        let sha8 = v8.sha256()
        let sha9 = v9.sha256()
        print("319 pixels: v8 \(v8.width)×\(v8.height) read-back \(v8.decoderVersion) sha=\(sha8)")
        print("319 pixels: v\(newer) \(v9.width)×\(v9.height) read-back \(v9.decoderVersion) sha=\(sha9)")

        XCTAssertNotEqual(v8.decoderVersion, v9.decoderVersion,
                          "两个版本的读回值必须不同，否则请求根本没落到 CIRAWFilter 上")
        XCTAssertNotEqual(sha8, sha9,
                          "同一张 RAW 在 v8/\(newer) 下 pixelSHA256 相同 ⇒ v9 没有生效（按失败上报）")
    }
}
