import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 425 — 解码模型选择框固定显示 v8：the 409 automatic choice never reached the panel.
///
/// The user's report (2026-11-18): 「高ISO文件应该默认9 9.dng，但现在界面的选择框还是8，然后实际解码器
/// 是v9.dng。也就是选择框固定在了8」. Three facts were true at once — the picker said `8`, the pixels
/// were v9, and the user's own rule says a high-ISO file should say `9` — because the 409 rule runs at
/// decode time and leaves the document `nil`, while `chosenDecoderSpelling` fell through to
/// `defaultDecoderSpelling` (`8` when offered) for every `nil` document.
///
/// The seam fixed here is `DecoderCapabilities.autoVersion` (the rule's answer for a document that asks
/// for nothing) and two pure decisions built on it:
///
///  1. **`InspectorView.chosenDecoderSpelling(stored:offered:auto:)`** — stored wins, then auto, then
///     `defaultDecoderSpelling`. So a high-ISO file shows `9.dng` and a low-ISO one still shows `8`.
///  2. **`PanelResets.decoderVersion(_:offered:auto:)`** — `nil` is written only for the spelling that
///     *is* the automatic one. Picking `8` on a `9.dng` file is an explicit `"8"`, not `nil`: with the
///     old "8 ⇒ nil" rule the decode path re-ran the 409 rule and put the user straight back on v9,
///     i.e. the picker could not be moved. `auto == nil` keeps the old mapping byte for byte.
@MainActor
final class DecoderAutoSelection425Tests: XCTestCase {

    static let sl3: [String] = ["6.dng", "7", "7.dng", "8", "8.dng", "9.dng"]

    // MARK: - B. which item the picker shows

    /// B① — a `nil` document on a file the rule upgrades shows **the automatic choice**, not `8`.
    func testThePickerShowsTheAutomaticChoiceForAnUntouchedDocument() {
        XCTAssertEqual(InspectorView.chosenDecoderSpelling(stored: nil, offered: Self.sl3,
                                                           auto: "9.dng"),
                       "9.dng",
                       "409 upgrades this file, so the picker must say so — the decode already does")
    }

    /// B② — no upgrade ⇒ `8`, exactly as before 425. `DecoderModelCardTests:54-55` pins the pure
    /// `defaultDecoderSpelling` this falls through to; both are asserted so a `defaultDecoderSpelling`
    /// change cannot hide behind this test.
    func testAnUntouchedDocumentWithoutAnUpgradeStillShowsEight() {
        XCTAssertEqual(InspectorView.chosenDecoderSpelling(stored: nil, offered: Self.sl3, auto: nil), "8")
        XCTAssertEqual(InspectorView.chosenDecoderSpelling(stored: nil, offered: [], auto: nil), "8",
                       "before the first frame there is no list and no auto: still 8")
        XCTAssertEqual(InspectorView.defaultDecoderSpelling(offered: Self.sl3), "8",
                       "the fallback itself is unchanged")
    }

    /// B③ — **an explicit document choice wins over the automatic one.** A user who picked `8` (or
    /// `8.dng`) on a high-ISO file keeps seeing what they picked; the rule must never override it.
    func testAnExplicitDocumentChoiceIsNeverOverriddenByTheAutomation() {
        XCTAssertEqual(InspectorView.chosenDecoderSpelling(stored: "8", offered: Self.sl3, auto: "9.dng"),
                       "8", "the user picked 8 on a v9 file — show 8")
        XCTAssertEqual(InspectorView.chosenDecoderSpelling(stored: "8.dng", offered: Self.sl3,
                                                           auto: "9.dng"),
                       "8.dng")
        XCTAssertEqual(InspectorView.chosenDecoderSpelling(stored: "9.dng", offered: Self.sl3, auto: nil),
                       "9.dng", "the other direction too: stored wins even when auto says nothing")
    }

    // MARK: - C. what a pick stores

    /// C① — picking the automatic spelling itself writes `nil` = "back to automatic".
    func testPickingTheAutomaticSpellingGoesBackToNil() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { $0.decoderVersion = "8" }
        XCTAssertTrue(session.commitEdit(label: "setup"))
        XCTAssertEqual(session.edit.decoderVersion, "8")

        XCTAssertTrue(resets.decoderVersion("9.dng", offered: Self.sl3, auto: "9.dng"))
        XCTAssertNil(session.edit.decoderVersion,
                     "9.dng is this file's automatic answer — the document asks for nothing")
        XCTAssertTrue(session.edit.decodeInputs.key.contains("ver=auto"), session.edit.decodeInputs.key)
        XCTAssertEqual(session.edit.decodeInputs.appending(to: "photo"), "photo",
                       "back to automatic is byte-identical to an untouched document")
    }

    /// C② — **the point of 425's second half.** On a file the rule upgrades, picking `8` must store an
    /// explicit `"8"`; storing `nil` would let the decode path re-apply the rule and force the user back
    /// to `9.dng` — 「拨不动」.
    func testPickingEightOnAnUpgradedFileIsAnExplicitChoiceNotNil() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        XCTAssertNil(session.edit.decoderVersion, "the document starts untouched")
        XCTAssertTrue(session.edit.decodeInputs.key.contains("ver=auto"))

        XCTAssertTrue(resets.decoderVersion("8", offered: Self.sl3, auto: "9.dng"))
        XCTAssertEqual(session.edit.decoderVersion, "8",
                       "auto is 9.dng here, so 8 is an explicit assignment — not nil")
        XCTAssertEqual(session.edit.decodeInputs.appending(to: "photo"), "photo|ver=8",
                       "the rung identity must carry ver=8, i.e. a different buffer from ver=auto")
        XCTAssertTrue(session.edit.decodeInputs.key.contains("ver=8"), session.edit.decodeInputs.key)

        // …and the picker keeps showing it (B③, read from the document this test just wrote).
        XCTAssertEqual(InspectorView.chosenDecoderSpelling(stored: session.edit.decoderVersion,
                                                           offered: Self.sl3, auto: "9.dng"),
                       "8")
    }

    /// C③ — on a file the rule does **not** upgrade, `8` is still `nil`. This is the pre-425 mapping
    /// and every existing document depends on it (`DecoderModelCardTests` asserts the same through the
    /// `auto:`-less call site).
    func testPickingEightOnANonUpgradedFileStillWritesNil() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { $0.decoderVersion = "9.dng" }
        XCTAssertTrue(session.commitEdit(label: "setup"))

        XCTAssertTrue(resets.decoderVersion("8", offered: Self.sl3, auto: nil))
        XCTAssertNil(session.edit.decoderVersion, "no auto on this file ⇒ 8 is the automatic answer")
        XCTAssertEqual(session.edit.decodeInputs.appending(to: "photo"), "photo")

        // The `auto:`-less call site (the existing tests, and any caller that has no capabilities yet)
        // behaves identically: `8` ⇒ `nil`, anything else verbatim.
        let second = CatalogSession()
        let resets2 = PanelResets(session: second)
        second.applyEdit { $0.decoderVersion = "9.dng" }
        XCTAssertTrue(second.commitEdit(label: "setup"))
        XCTAssertTrue(resets2.decoderVersion("8", offered: Self.sl3))
        XCTAssertNil(second.edit.decoderVersion)
        XCTAssertTrue(resets2.decoderVersion("8.dng", offered: Self.sl3))
        XCTAssertEqual(second.edit.decoderVersion, "8.dng",
                       "8.dng is a different decode and is stored verbatim")
    }

    /// 425's ④ in the brief: on a high-ISO file the note under the picker must not say 「已退回 v8」
    /// once the picker says `9.dng` — that would mean the panel and the pixels disagree.
    func testTheNoteAgreesWithThePickerOnAnUpgradedFile() {
        let caps = DecoderCapabilities(requestedVersion: "9.dng", effectiveVersion: "9.dng",
                                       defaultVersion: "8", supportedVersions: Self.sl3,
                                       autoVersion: "9.dng")
        let chosen = InspectorView.chosenDecoderSpelling(stored: nil, offered: caps.supportedVersions,
                                                         auto: caps.autoVersion)
        XCTAssertEqual(chosen, "9.dng")
        XCTAssertEqual(InspectorView.decoderModelNote(requested: nil, effective: caps.effectiveVersion),
                       "实际 v9.dng", "the note names what ran, and it is what the picker shows")
        XCTAssertFalse(InspectorView.decoderModelWasDowngraded(requested: nil,
                                                              effective: caps.effectiveVersion),
                       "nothing was downgraded on this file — the note must not be orange")
    }

    /// The card reads the field from `session.capabilities`, not from `requestedVersion`: a capability
    /// that carries `requestedVersion = nil` (the untouched document) still has the automatic answer.
    func testTheCardTakesTheAutoAnswerFromTheRecordedCapabilities() {
        let session = CatalogSession()
        session.recordCapabilities(DecoderCapabilities(requestedVersion: nil,
                                                       effectiveVersion: "9.dng",
                                                       defaultVersion: "8",
                                                       supportedVersions: Self.sl3,
                                                       autoVersion: "9.dng"))
        XCTAssertEqual(InspectorView.chosenDecoderSpelling(stored: session.edit.decoderVersion,
                                                           offered: session.capabilities?.supportedVersions ?? [],
                                                           auto: session.capabilities?.autoVersion),
                       "9.dng")
        XCTAssertNil(session.capabilities?.requestedVersion,
                     "the untouched document requested nothing — which is why requestedVersion was the"
                     + " wrong field for the picker")
    }
}
