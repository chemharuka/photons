import XCTest
import PhotonsCore

/// §555 Phase 1 — **the document policy, the 解码偏好 table, and the one resolver**.
///
/// This suite is deliberately pure: Phase 1 is the data model and the rule, so nothing here needs a
/// RAW, a window, or a render. Phase 2 will add the decode-path integration and Phase 3 the picker /
/// settings rows; both will keep these cases green because the rule they call is the same one.
///
/// The reverse gates are explicit:
///   · if `.v8` were allowed to fall through to v9, `testTheV8PolicyNeverFallsThroughToNine` goes red;
///   · if the cache key were spelled `auto` instead of the resolved spelling,
///     `testTheKeyNamesTheResolvedSpellingNotAuto` goes red.
final class DecoderPolicy555Tests: XCTestCase {

    private let all = ["9", "9.dng", "8", "8.dng"]
    private let noBareNine = ["9.dng", "8", "8.dng"]
    private let noNine = ["8", "8.dng", "7", "7.dng"]
    private let mixed = ["9", "8.dng", "7"]

    private func selected(_ policy: DecoderVersionPolicy,
                          _ preference: DecoderVersionPreference.Preference,
                          iso: Int?,
                          stored: String? = nil,
                          resolved: String? = nil,
                          in available: [String]) -> String? {
        DecoderVersionPreference.resolve(policy: policy, preference: preference, iso: iso,
                                         stored: stored, resolved: resolved,
                                         in: available) { $0 }.selected
    }

    // MARK: - 1. the table

    /// `{policy .auto} × {iso 400, 800, 3200} × {设置 自动 / 优先v9 / 优先v8} × {4 lists}`.
    func testTheAutomaticTable() {
        struct Row {
            let preference: DecoderVersionPreference.Preference
            let iso: Int
            let available: [String]
            let expected: String?
        }

        func rows(_ available: [String], iso: Int,
                  auto: String?, preferV9: String?, preferV8: String?) -> [Row] {
            [
                Row(preference: .auto, iso: iso, available: available, expected: auto),
                Row(preference: .preferV9, iso: iso, available: available, expected: preferV9),
                Row(preference: .preferV8, iso: iso, available: available, expected: preferV8),
            ]
        }

        let rows = [
            // All four spellings.
            rows(all, iso: 400, auto: "8", preferV9: "9", preferV8: "8"),
            rows(all, iso: 800, auto: "9", preferV9: "9", preferV8: "8"),
            rows(all, iso: 3200, auto: "9", preferV9: "9", preferV8: "8"),
            // No bare 9: the owner's order falls to 9.dng.
            rows(noBareNine, iso: 400, auto: "8", preferV9: "9.dng", preferV8: "8"),
            rows(noBareNine, iso: 800, auto: "9.dng", preferV9: "9.dng", preferV8: "8"),
            rows(noBareNine, iso: 3200, auto: "9.dng", preferV9: "9.dng", preferV8: "8"),
            // No v9 at all: 自动 must not invent one, even at ISO 3200.
            rows(noNine, iso: 400, auto: "8", preferV9: "8", preferV8: "8"),
            rows(noNine, iso: 800, auto: "8", preferV9: "8", preferV8: "8"),
            rows(noNine, iso: 3200, auto: "8", preferV9: "8", preferV8: "8"),
            // A gap in v8: 8 is missing, so 8.dng is the family's first offered spelling.
            rows(mixed, iso: 400, auto: "8.dng", preferV9: "9", preferV8: "8.dng"),
            rows(mixed, iso: 800, auto: "9", preferV9: "9", preferV8: "8.dng"),
            rows(mixed, iso: 3200, auto: "9", preferV9: "9", preferV8: "8.dng"),
        ].flatMap { $0 }

        for row in rows {
            let got = selected(.auto, row.preference, iso: row.iso, in: row.available)
            XCTAssertEqual(got, row.expected,
                           "自动 · \(row.preference.rawValue) · iso \(row.iso) · \(row.available)")
        }

        // The four anchors the ticket names, stated once so a reader can find them without reading
        // the table above.
        XCTAssertEqual(selected(.auto, .preferV8, iso: 3200, in: all), "8",
                       "优先 v8 + iso 3200 仍选 8")
        XCTAssertEqual(selected(.auto, .auto, iso: 800, in: all), "9", "自动 + iso 800 选 9")
        XCTAssertEqual(selected(.auto, .auto, iso: 400, in: all), "8", "自动 + iso 400 选 8")
        XCTAssertEqual(selected(.auto, .preferV9, iso: 400, in: all), "9", "优先 v9 + iso 400 选 9")
    }

    /// `{policy .v8 / .v9} × {3 ISO} × {3 settings} × {4 lists}` — a hand pick ignores the setting.
    func testTheHandPickedFamiliesIgnoreTheSetting() {
        let cases: [(DecoderVersionPolicy, [String], String?)] = [
            (.v8, all, "8"),
            (.v8, noBareNine, "8"),
            (.v8, noNine, "8"),
            (.v8, mixed, "8.dng"),
            (.v9, all, "9"),
            (.v9, noBareNine, "9.dng"),
            (.v9, noNine, nil),
            (.v9, mixed, "9"),
        ]
        for (policy, available, expected) in cases {
            for iso in [400, 800, 3200] {
                for preference in DecoderVersionPreference.Preference.allCases {
                    XCTAssertEqual(selected(policy, preference, iso: iso, in: available), expected,
                                   "\(policy.rawValue) · \(preference.rawValue) · iso \(iso)"
                                   + " · \(available)")
                }
            }
        }
    }

    /// A hand-picked spelling is pinned verbatim; a rejected one falls back **inside its family**.
    func testTheHandPickIsPinnedAndFallsBackWithinItsFamily() {
        XCTAssertEqual(selected(.v8, .preferV9, iso: 3200, stored: "8.dng", in: all), "8.dng")
        XCTAssertEqual(selected(.v9, .preferV8, iso: 400, stored: "9.dng", in: all), "9.dng")

        // A stored spelling from the other family is not a pin for this policy.
        XCTAssertEqual(selected(.v8, .preferV9, iso: 3200, stored: "9.dng", in: all), "8")
        XCTAssertEqual(selected(.v9, .preferV8, iso: 400, stored: "8.dng", in: all), "9")
    }

    /// Pre-555 documents: `decoderVersion` present, `resolvedDecoderVersion` absent ⇒ the old hand
    /// pick wins and the 设置 cannot move its pixels.
    func testALegacySpellingIsTreatedAsTheHandPickItWas() {
        XCTAssertEqual(selected(.auto, .preferV8, iso: 400, stored: "9.dng", resolved: nil,
                                in: all), "9.dng")
        XCTAssertEqual(selected(.auto, .preferV8, iso: 400, stored: "8.dng", resolved: nil,
                                in: all), "8.dng")

        // Once a resolved result exists, the same document follows the table (it is a new auto doc).
        XCTAssertEqual(selected(.auto, .preferV8, iso: 400, stored: "9.dng", resolved: "9.dng",
                                in: all), "8")
    }

    // MARK: - 2. threshold

    func testTheThresholdIsEightHundredAndIncludesTheBoundary() {
        XCTAssertEqual(DecoderVersionPreference.highISOThreshold, 800)
        XCTAssertTrue(DecoderVersionPreference.isHighISO(iso: 800))
        XCTAssertTrue(DecoderVersionPreference.isHighISO(iso: 3200))
        XCTAssertFalse(DecoderVersionPreference.isHighISO(iso: 400))
        XCTAssertFalse(DecoderVersionPreference.isHighISO(iso: nil),
                       "no ISO is not proof of a noisy file")
        // 409's format normalisation: ISO · crop² ≥ 800.
        XCTAssertTrue(DecoderVersionPreference.isHighISO(iso: 200, cropFactor: 2))
        XCTAssertFalse(DecoderVersionPreference.isHighISO(iso: 199, cropFactor: 2))
    }

    // MARK: - 3. reverse gates

    /// 反向门 — `.v8` must never answer a v9 spelling, including when every v8 candidate is rejected.
    func testTheV8PolicyNeverFallsThroughToNine() {
        for iso in [400, 800, 3200] {
            for preference in DecoderVersionPreference.Preference.allCases {
                let got = selected(.v8, preference, iso: iso, in: all)
                XCTAssertEqual(got, "8", "\(preference.rawValue) · iso \(iso)")
                XCTAssertFalse(got?.hasPrefix("9") ?? false, "v8 策略不得选 9")
            }
        }

        // A file that offers only v9 gets "ask for nothing", not a hidden upgrade.
        XCTAssertNil(selected(.v8, .auto, iso: 3200, in: ["9", "9.dng"]))

        // The read-back cannot escape the family either: every v8 candidate rewritten to 9 ⇒ nil.
        let resolution = DecoderVersionPreference.resolve(
            policy: .v8, preference: .preferV9, iso: 3200,
            stored: nil, in: ["9", "8", "8.dng"]) { candidate in
                candidate.hasPrefix("8") ? "9" : candidate
            }
        XCTAssertNil(resolution.selected, "v8 分支被改写时只能失败，不能落到 9")
    }

    /// The read-back still moves to the next spelling **of the same family**.
    func testARejectedSpellingMovesToTheNextOneInTheFamily() {
        let v9 = DecoderVersionPreference.resolve(
            policy: .v9, preference: .auto, iso: 400,
            stored: "9", in: ["9", "9.dng", "8"]) { candidate in
                candidate == "9" ? "8" : candidate
            }
        XCTAssertEqual(v9.selected, "9.dng")

        let v8 = DecoderVersionPreference.resolve(
            policy: .v8, preference: .auto, iso: 400,
            stored: "8", in: ["9", "8", "8.dng"]) { candidate in
                candidate == "8" ? "7" : candidate
            }
        XCTAssertEqual(v8.selected, "8.dng")
    }

    // MARK: - 4. document round-trip

    func testAnAutomaticDocumentRoundTripsPolicyAndResolvedSpelling() throws {
        var doc = EditModel.neutral
        doc.decoderVersionPolicy = .auto
        doc.resolvedDecoderVersion = "9.dng"

        let back = try JSONDecoder().decode(EditModel.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.decoderVersionPolicy, .auto)
        XCTAssertEqual(back.resolvedDecoderVersion, "9.dng")
        XCTAssertNil(back.decoderVersion, "自动 does not store a hand pick")
    }

    func testAHandPickedDocumentRoundTripsItsPolicyAndSpelling() throws {
        var doc = EditModel.neutral
        doc.decoderVersionPolicy = .v8
        doc.decoderVersion = "8.dng"
        doc.resolvedDecoderVersion = "8.dng"

        let back = try JSONDecoder().decode(EditModel.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.decoderVersionPolicy, .v8)
        XCTAssertEqual(back.decoderVersion, "8.dng")
        XCTAssertEqual(back.resolvedDecoderVersion, "8.dng")
    }

    /// A literal pre-555 document: no policy key, no resolved key, one stored spelling.
    func testAPrePolicyDocumentKeepsItsSpellingAndItsPixels() throws {
        let json = #"{"schemaVersion":13,"decoderVersion":"8.dng"}"#
        let old = try JSONDecoder().decode(EditModel.self, from: Data(json.utf8))

        XCTAssertEqual(old.decoderVersionPolicy, .auto, "absent policy decodes as 自动")
        XCTAssertEqual(old.decoderVersion, "8.dng", "the stored spelling is preserved verbatim")
        XCTAssertNil(old.resolvedDecoderVersion)

        // The development is named exactly as before this change …
        XCTAssertEqual(old.decodeInputs.key, DecodeInputs(decoderVersion: "8.dng").key)
        // … and the render half cannot see the decoder at all (the buffer already carries it).
        XCTAssertEqual(RenderInputs(old), RenderInputs(EditModel.neutral))
        XCTAssertEqual(RenderInputs(old).key, RenderInputs(EditModel.neutral).key)

        // Saving and re-opening does not lose the value either (it may write the two new keys; the
        // policy is still 自动 and the spelling is still the same).
        let back = try JSONDecoder().decode(EditModel.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(back.decoderVersionPolicy, .auto)
        XCTAssertEqual(back.decoderVersion, "8.dng")
        XCTAssertNil(back.resolvedDecoderVersion,
                     "a legacy document is still recognisable as a hand pick after a save")
    }

    func testANeutralDocumentDoesNotGrowTheNewKeys() throws {
        let text = String(decoding: try JSONEncoder().encode(EditModel.neutral), as: UTF8.self)
        XCTAssertFalse(text.contains("decoderVersionPolicy"), text)
        XCTAssertFalse(text.contains("resolvedDecoderVersion"), text)
    }

    // MARK: - 5. key stability / correctness

    /// Two documents that differ only in policy but resolve to the same spelling must produce the
    /// same decode key; different spellings must produce different keys.
    func testTheKeyNamesTheResolvedSpellingNotAuto() {
        let auto = EditModel.neutral
        var pinned = EditModel.neutral
        pinned.decoderVersionPolicy = .v9
        pinned.decoderVersion = "9.dng"

        let autoSelected = selected(auto.decoderVersionPolicy, .auto, iso: 3200,
                                    stored: auto.decoderVersion,
                                    resolved: auto.resolvedDecoderVersion, in: noBareNine)
        let pinnedSelected = selected(pinned.decoderVersionPolicy, .preferV8, iso: 400,
                                      stored: pinned.decoderVersion,
                                      resolved: pinned.resolvedDecoderVersion, in: noBareNine)
        XCTAssertEqual(autoSelected, "9.dng")
        XCTAssertEqual(pinnedSelected, "9.dng")

        let autoKey = DecodeInputs(decoderVersion: autoSelected).key
        let pinnedKey = DecodeInputs(decoderVersion: pinnedSelected).key
        XCTAssertEqual(autoKey, pinnedKey, "same resolved spelling ⇒ same buffer key")

        let eightKey = DecodeInputs(decoderVersion: "8").key
        XCTAssertNotEqual(autoKey, eightKey, "8 and 9.dng are different pictures")

        // 反向门 — the key must name the spelling, never the literal `auto`.
        XCTAssertTrue(autoKey.contains("ver=9.dng"), autoKey)
        XCTAssertFalse(autoKey.contains("ver=auto"), autoKey)
    }
}
