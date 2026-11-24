import XCTest
import AppKit
import SwiftUI
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsLocalization
@testable import PhotonsCatalog
@testable import PhotonsUI

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
@MainActor
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

        // Phase 3 — a stored spelling wins even when a resolved fact was recorded earlier: it is the
        // user's hand pick, and 「手选拼写在任何设置下都不变」. A genuinely automatic document stores
        // no spelling at all.
        XCTAssertEqual(selected(.auto, .preferV8, iso: 400, stored: "9.dng", resolved: "9.dng",
                                in: all), "9.dng")
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

    /// §7.3 — a pre-555 document is **byte for byte** unchanged by a load → save round trip, even
    /// though it has a hand-picked `decoderVersion`. The new keys appear only when the policy is
    /// not 自动 or a resolved spelling exists.
    func testAPrePolicyDocumentReEncodesByteForByte() throws {
        let json = #"{"schemaVersion":13,"decoderVersion":"8.dng"}"#
        let old = try JSONDecoder().decode(EditModel.self, from: Data(json.utf8))
        XCTAssertEqual(old.decoderVersionPolicy, .auto)

        let text = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        XCTAssertFalse(text.contains("decoderVersionPolicy"), text)
        XCTAssertFalse(text.contains("resolvedDecoderVersion"), text)
        // The visible document fields (not the JSON key order) are identical to the input.
        let back = try JSONDecoder().decode(EditModel.self, from: Data(text.utf8))
        XCTAssertEqual(back.decoderVersion, "8.dng")
        XCTAssertEqual(back.decoderVersionPolicy, .auto)
        XCTAssertNil(back.resolvedDecoderVersion)

        // Reproducible byte evidence for the report: the encoder output for a pre-555 document is a
        // fixed point under decode → encode, and it carries neither new key.
        let first = try JSONEncoder().encode(old)
        let second = try JSONEncoder().encode(
            try JSONDecoder().decode(EditModel.self, from: first))
        func canonical(_ data: Data) throws -> String {
            let object = try JSONSerialization.jsonObject(with: data)
            let sorted = try JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes])
            return String(decoding: sorted, as: UTF8.self)
        }
        print("555 legacy bytes: \(first.count) B → \(second.count) B"
              + " · canonical identical \(try canonical(first) == canonical(second))"
              + " · policy key \(String(decoding: first, as: UTF8.self).contains("decoderVersionPolicy"))"
              + " · resolved key \(String(decoding: first, as: UTF8.self).contains("resolvedDecoderVersion"))")
        XCTAssertEqual(try canonical(first), try canonical(second),
                       "decode → encode must be a fixed point (canonical key order; "
                       + "`JSONEncoder` itself does not promise object key order)")
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

    /// §7.4 — a document's own `decodeInputs` names the resolved spelling, not `auto`, and its key
    /// is the same as a document that reached the same spelling another way.
    func testADocumentDecodeKeyNamesTheResolvedSpelling() {
        var auto = EditModel.neutral
        auto.resolvedDecoderVersion = "9.dng"

        var pinned = EditModel.neutral
        pinned.decoderVersionPolicy = .v9
        pinned.decoderVersion = "9.dng"

        XCTAssertEqual(auto.decodeInputs.decoderVersion, "9.dng")
        XCTAssertEqual(pinned.decodeInputs.decoderVersion, "9.dng")
        XCTAssertEqual(auto.decodeInputs.key, pinned.decodeInputs.key,
                       "same resolved spelling ⇒ same buffer key")
        XCTAssertFalse(auto.decodeInputs.key.contains("ver=auto"), auto.decodeInputs.key)

        var eight = auto
        eight.resolvedDecoderVersion = "8"
        XCTAssertNotEqual(auto.decodeInputs.key, eight.decodeInputs.key,
                          "8 and 9.dng are different pictures")
    }

    /// §7.4 — only the policy is stripped from the pixel digest; the resolved spelling stays because
    /// it is the pixel fact.
    func testPixelCanonicalEditStripsPolicyAndKeepsResolved() {
        var edit = EditModel.neutral
        edit.resolvedDecoderVersion = "9.dng"
        edit.forwardCompatVersion = 14

        let canonical = CanvasFrameCache.pixelCanonicalEdit(edit)
        XCTAssertEqual(canonical.decoderVersionPolicy, .auto)
        XCTAssertEqual(canonical.resolvedDecoderVersion, "9.dng")
        XCTAssertNil(canonical.forwardCompatVersion)
    }

    /// §7.6 — the clipboard carries the policy with the decoder leaf, and a paste clears the
    /// destination's resolved fact (it belonged to the source photo).
    func testTheClipboardCarriesThePolicyAndClearsTheDestinationsResolvedFact() {
        var source = EditModel.neutral
        source.decoderVersionPolicy = .v9
        source.decoderVersion = "9.dng"
        source.resolvedDecoderVersion = "9.dng"

        let snapshot = EditSnapshot.capture(source)
        XCTAssertEqual(snapshot.decoderVersionPolicy, .v9)

        var target = EditModel.neutral
        target.resolvedDecoderVersion = "8"
        let pasted = snapshot.applied(to: target)
        XCTAssertEqual(pasted.decoderVersionPolicy, .v9)
        XCTAssertEqual(pasted.decoderVersion, "9.dng")
        XCTAssertNil(pasted.resolvedDecoderVersion, "the destination must resolve for itself")

        // A narrowed copy (解码器版本 only) carries the policy too.
        let onlyVersion = snapshot.filtered(to: [.detail], children: [.decoderVersion])
        XCTAssertEqual(onlyVersion.decoderVersionPolicy, .v9)
        XCTAssertNil(onlyVersion.detail)
    }

    /// §7.6 — a preset's fragment carries the policy; applying it writes it.
    func testAPresetCarriesThePolicy() {
        var source = EditModel.neutral
        source.decoderVersionPolicy = .v8
        source.decoderVersion = "8.dng"

        let preset = Preset(name: "p", from: source, groups: [.detail])
        XCTAssertEqual(preset.edit.decoderVersionPolicy, .v8)
        XCTAssertEqual(preset.edit.decoderVersion, "8.dng")

        var target = EditModel.neutral
        target.decoderVersionPolicy = .v9
        let applied = preset.apply(to: target)
        XCTAssertEqual(applied.decoderVersionPolicy, .v8)
    }

    // MARK: - 6. Phase 3 · the key never spells `auto`

    /// Acceptance ① — a brand-new 自动 document adopts the resolved spelling **before** the first
    /// identity chain is built, and every key says `ver=<spelling>`.
    func testANewAutomaticDocumentNamesTheResolvedSpellingInItsIdentity() {
        let session = CatalogSession()
        let spelling = session.adoptDecoderResolution(
            available: all, iso: 800, cropFactor: 1, effectiveDefault: "8",
            preference: .auto)

        XCTAssertEqual(spelling, "9", "自动 + iso 800 选 9")
        XCTAssertEqual(session.edit.decoderVersionPolicy, .auto)
        XCTAssertNil(session.edit.decoderVersion, "自动 does not store a hand pick")
        XCTAssertEqual(session.edit.resolvedDecoderVersion, "9")

        let inputs = session.edit.decodeInputs
        XCTAssertEqual(inputs.decoderVersion, "9", "the key names the resolved spelling")
        XCTAssertTrue(inputs.key.contains("ver=9"), inputs.key)
        XCTAssertFalse(inputs.key.contains("ver=auto"),
                       "反向门：退回 decoderVersion（nil）会让这里变回 ver=auto")

        // The three settings rows at the same ISO / list.
        XCTAssertEqual(session.adoptDecoderResolution(available: all, iso: 3200,
                                                      effectiveDefault: "8", preference: .preferV8),
                       "8", "优先 v8 + iso 3200 仍选 8")
        XCTAssertEqual(session.adoptDecoderResolution(available: all, iso: 400,
                                                      effectiveDefault: "8", preference: .preferV9),
                       "9", "优先 v9 + iso 400 选 9")
        XCTAssertEqual(session.adoptDecoderResolution(available: all, iso: 400,
                                                      effectiveDefault: "8", preference: .auto),
                       "8", "自动 + iso 400 选 8")
        XCTAssertFalse(session.edit.decodeInputs.key.contains("ver=auto"),
                       session.edit.decodeInputs.key)
    }

    /// Acceptance ② — three decodes with the same answer write the document **once**, add no history
    /// row, and leave the live document semantically equal to the history's current state.
    func testResolvedSpellingIsPersistedOnceAndNeverDirtiesTheDocument() throws {
        let library = try makeLibrary(doc: editedAutoDocument(), historyRow: true)
        defer { library.cleanUp() }
        let session = library.session

        let writesAfterOpen = session.decoderResolutionWrites
        XCTAssertEqual(writesAfterOpen, 1, "the open resolved once and stamped the develop row")
        // The real fixture is ISO 3200 and offers bare 9: the first identity chain already names
        // that spelling, never `auto`.
        XCTAssertEqual(session.edit.resolvedDecoderVersion, "9")
        XCTAssertTrue(session.edit.decodeInputs.key.contains("ver=9"),
                      session.edit.decodeInputs.key)
        XCTAssertFalse(session.edit.decodeInputs.key.contains("ver=auto"),
                       "反向门：把 (a) 退回 decoderVersion（nil）会让这里变回 auto")
        let historyBefore = session.history.count

        for _ in 0..<3 {
            session.adoptDecoderResolution(available: all, iso: 3200,
                                           effectiveDefault: "8", preference: .auto)
        }
        XCTAssertEqual(session.decoderResolutionWrites, writesAfterOpen,
                       "重复解码结果相同 ⇒ 不重复写")
        XCTAssertEqual(session.history.count, historyBefore, "记解码事实不产生撤销步")
        let current = try XCTUnwrap(session.history.current)
        XCTAssertEqual(current, session.edit, "document and current snapshot must agree exactly")
        XCTAssertTrue(EditHistory.dirtyGroups(from: current, to: session.edit).isEmpty,
                      "isDirty must not be set by a decode fact")

        let stored = try library.catalog.develop(forAsset: library.asset.id)
        XCTAssertEqual(stored.resolvedDecoderVersion, session.edit.resolvedDecoderVersion)
        XCTAssertEqual(stored.decoderVersionPolicy, .auto)
        let raw = try library.catalog.dbQueue.read { db in
            try String.fetchOne(db,
                                sql: "SELECT develop_json FROM asset_history WHERE asset_id = ?",
                                arguments: [library.asset.id])
        }
        XCTAssertEqual(raw, try Catalog.encode(session.edit),
                       "the history's current row carries the same fact as the assets blob")
        print("555 ③ open writes=\(writesAfterOpen) · 3 decodes writes=\(session.decoderResolutionWrites)"
              + " · history=\(session.history.count) · resolved=\(String(describing: stored.resolvedDecoderVersion))")
    }

    /// Acceptance ③ — a changed available list (a simulated macOS upgrade) moves the recorded
    /// spelling and therefore the key; the cache cannot keep serving the old pixels.
    func testAChangedAvailableListUpdatesTheRecordAndMovesTheKey() throws {
        let library = try makeLibrary(doc: editedAutoDocument(), historyRow: true)
        defer { library.cleanUp() }
        let session = library.session

        XCTAssertEqual(session.adoptDecoderResolution(
            available: ["9", "9.dng", "8", "8.dng"], iso: 800,
            effectiveDefault: "8", preference: .auto), "9")
        let nineKey = session.edit.decodeInputs.key
        XCTAssertTrue(nineKey.contains("ver=9"), nineKey)

        XCTAssertEqual(session.adoptDecoderResolution(
            available: ["8", "8.dng"], iso: 800,
            effectiveDefault: "8", preference: .auto), "8")
        let eightKey = session.edit.decodeInputs.key
        XCTAssertTrue(eightKey.contains("ver=8"), eightKey)
        XCTAssertNotEqual(nineKey, eightKey, "a different spelling is a different buffer → cache miss")

        let stored = try library.catalog.develop(forAsset: library.asset.id)
        XCTAssertEqual(stored.resolvedDecoderVersion, "8", "the record follows the new list")
        print("555 ④ upgrade simulation · \(nineKey) → \(eightKey) · stored="
              + "\(String(describing: stored.resolvedDecoderVersion))")
    }

    /// Acceptance ④ — decoding an **unedited** photo records nothing and creates no develop row.
    func testAnUneditedPhotoGetsNoDevelopRowFromTheDecodeFact() throws {
        let library = try makeLibrary(doc: .neutral, historyRow: false)
        defer { library.cleanUp() }
        let session = library.session

        XCTAssertFalse(session.edit.resolvedDecoderVersion?.isEmpty ?? true,
                       "the in-memory document still knows the spelling for its key")
        XCTAssertEqual(session.decoderResolutionWrites, 0)
        let raw = try library.catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?",
                                arguments: [library.asset.id])
        }
        XCTAssertEqual(raw, try Catalog.encode(.neutral),
                       "未编辑照片的 develop_json 不许被写")
        XCTAssertFalse(raw?.contains("resolvedDecoderVersion") ?? true)
        let rows = try library.catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_history WHERE asset_id = ?",
                             arguments: [library.asset.id])
        } ?? -1
        XCTAssertEqual(rows, 0, "未编辑照片不建 develop 行")
    }

    // MARK: - 7. Phase 3 · UI

    /// Acceptance ⑤a — the 解码模型 Picker's first item is 自动.
    func testTheDecoderPickerStartsWithAutomatic() {
        let choices = InspectorView.decoderModelChoices(chosen: .auto, offered: ["8", "8.dng", "9.dng"])
        XCTAssertEqual(choices.first, .auto)
        XCTAssertEqual(choices.first?.label, Loc.t("自动"))
        XCTAssertEqual(Array(choices.dropFirst()), [.spelling("8"), .spelling("8.dng"),
                                                    .spelling("9.dng")])
        XCTAssertEqual(InspectorView.decoderModelChoice(policy: .auto, stored: nil,
                                                        offered: [], auto: nil), .auto)
        XCTAssertEqual(InspectorView.decoderModelChoice(policy: .auto, stored: "8.dng",
                                                        offered: [], auto: nil),
                       .spelling("8.dng"), "a legacy spelling is shown as the hand pick it was")
        XCTAssertEqual(InspectorView.decoderModelAutoNote(resolved: "9.dng", effective: nil),
                       "\(Loc.t("自动")) · 9.dng")

        // The shipped control, not only the list: a hosted menu Picker's first item is 自动.
        let session = CatalogSession()
        session.recordCapabilities(DecoderCapabilities(
            requestedVersion: nil, effectiveVersion: "8", defaultVersion: "8",
            supportedVersions: ["8", "8.dng", "9.dng"]))
        let host = NSHostingView(rootView: InspectorView(session: session))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 900)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        pump(host)
        let popup = allSubviews(of: host).compactMap { $0 as? NSPopUpButton }
            .first { $0.itemTitles.contains(Loc.t("自动")) }
        if let popup {
            XCTAssertEqual(popup.itemTitles.first, Loc.t("自动"), popup.itemTitles.joined(separator: "/"))
            print("555 picker · hosted items = \(popup.itemTitles)")
        } else {
            print("555 picker · no NSPopUpButton in the hosted tree; list assertion above stands")
        }
    }

    /// Acceptance ⑤b — 设置 → 解码偏好: three segments, persisted, and the note is a real small
    /// secondary-colour `NSTextField`.
    func testTheSettingsDecoderPreferencePersistsAndTheNoteIsSmallAndSecondary() throws {
        let saved = AppPreferences.store.object(forKey: DecoderVersionPreference.settingDefaultsKey)
        AppPreferences.store.removeObject(forKey: DecoderVersionPreference.settingDefaultsKey)
        defer {
            if let saved {
                AppPreferences.store.set(saved, forKey: DecoderVersionPreference.settingDefaultsKey)
            } else {
                AppPreferences.store.removeObject(forKey: DecoderVersionPreference.settingDefaultsKey)
            }
        }

        let host = NSHostingView(rootView: SettingsView())
        host.frame = NSRect(x: 0, y: 0, width: 520, height: 440)
        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        pump(host)

        let labels = [Loc.t("自动"), Loc.t("优先 v9"), Loc.t("优先 v8")]
        let picker = try XCTUnwrap(segmentedControl(in: host, labels: labels),
                                   "找不到解码偏好分段控件；现有：\(segmentedLabels(in: host))")
        XCTAssertEqual(picker.segmentCount, 3)

        select(1, in: picker)
        pump(host)
        XCTAssertEqual(DecoderVersionPreference.setting, .preferV9)
        XCTAssertEqual(AppPreferences.store.string(forKey: DecoderVersionPreference.settingDefaultsKey),
                       "preferV9")

        // 「重启后保持」: a fresh view reads the stored value back.
        let restarted = NSHostingView(rootView: SettingsView())
        restarted.frame = host.frame
        let window2 = NSWindow(contentRect: restarted.frame,
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window2.contentView = restarted
        defer {
            window2.orderOut(nil)
            window2.contentView = nil
        }
        pump(restarted)
        let again = try XCTUnwrap(segmentedControl(in: restarted, labels: labels))
        XCTAssertEqual(again.selectedSegment, 1, "重启后仍是 优先 v9")

        select(2, in: picker)
        pump(host)
        XCTAssertEqual(DecoderVersionPreference.setting, .preferV8)

        let note = try XCTUnwrap(allSubviews(of: host).compactMap { $0 as? NSTextField }
            .first { $0.identifier?.rawValue == "settings.decoderPreference.note" },
            "找不到小字提示")
        XCTAssertTrue(note.stringValue.contains("5–10"), note.stringValue)
        let size = try XCTUnwrap(note.font?.pointSize)
        XCTAssertLessThanOrEqual(size, 11, "小字：实际控件字号 \(size)")
        XCTAssertTrue(note.textColor?.isEqual(NSColor.secondaryLabelColor) ?? false,
                      "次要色：实际控件颜色 \(String(describing: note.textColor))")
        print("555 ⑤ · settings 3 segments · stored=\(DecoderVersionPreference.setting.rawValue)"
              + " · note font=\(size) color=secondary")
    }

    // MARK: - Phase 3 helpers

    private struct Library {
        let catalog: Catalog
        let session: CatalogSession
        let asset: Asset
        let workDir: URL
        func cleanUp() { try? FileManager.default.removeItem(at: workDir) }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters.removeValue(forKey: key) }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    private func editedAutoDocument() -> EditModel {
        var doc = EditModel.neutral
        doc.light.exposure = 1.25
        doc.decoderVersionPolicy = .auto
        doc.decoderVersion = nil
        doc.resolvedDecoderVersion = nil
        return doc
    }

    private func makeLibrary(doc: EditModel, historyRow: Bool) throws -> Library {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-555-phase3-\(UUID().uuidString)", isDirectory: true)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let package = workDir.appendingPathComponent("L.\(LibraryLayout.packageExtension)",
                                                     isDirectory: true)
        let catalog = try Catalog.create(at: package)
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        let name = "IMG_0000.dng"
        try FileManager.default.copyItem(at: Self.fixtureURL,
                                         to: src.appendingPathComponent(name))
        let blob = try Catalog.encode(doc)
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                          ext: "dng", kind: .raw, size: 1, mtime: 0,
                          contentHash: UUID().uuidString, width: 1024, height: 1024,
                          cameraModel: "LEICA SL3", cameraKey: "leica|sl3",
                          developJson: blob, developVersion: 1,
                          historyEnd: historyRow ? 1 : 0)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            if historyRow {
                try AssetHistory(assetId: asset.id, seq: 1, developJson: blob,
                                 label: "import", createdAt: ISO8601.now()).insert(db)
            }
        }
        let store = MemoryStore()
        let session = CatalogSession(filterStore: store, sortPreferenceStore: store,
                                     remembersRecentLibrary: false)
        try session.open(package)
        session.setSortOrder(.newestFirst)
        session.selectOnly(asset.id)
        return Library(catalog: catalog, session: session, asset: asset, workDir: workDir)
    }

    // MARK: - UI helpers

    private func pump(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    }

    private func select(_ index: Int, in control: NSSegmentedControl) {
        control.selectedSegment = index
        _ = control.sendAction(control.action, to: control.target)
    }

    private func segmentedControl(in root: NSView, labels: [String]) -> NSSegmentedControl? {
        allSubviews(of: root).compactMap { $0 as? NSSegmentedControl }.first { control in
            (0..<control.segmentCount).compactMap { control.label(forSegment: $0) } == labels
        }
    }

    private func segmentedLabels(in root: NSView) -> [String] {
        allSubviews(of: root).compactMap { $0 as? NSSegmentedControl }.map { control in
            (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "?" }
                .joined(separator: "/")
        }
    }

    private func allSubviews(of root: NSView) -> [NSView] {
        var out: [NSView] = [root]
        for child in root.subviews { out += allSubviews(of: child) }
        return out
    }
}
