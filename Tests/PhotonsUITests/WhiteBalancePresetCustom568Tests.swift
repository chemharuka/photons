import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 568 — the preset menu's two states: an explicit 「自定义」 is selectable, and a value the user
/// edited stays 「自定义」 even when it sits on a preset's mired quantum.
///
/// The matching rules are not changed: `WhiteBalancePreset.matches` still defines "the same value" on
/// the slider's grid, and `WhiteBalancePresets.match` is still the derived answer. What these tests
/// pin is the view state *in front of* that answer — `WhiteBalancePresetMenuState` and the two
/// production entry points the menu and the sliders call (`applyPreset`, `commitWhiteBalanceValue`).
@MainActor
final class WhiteBalancePreset568Tests: XCTestCase {

    private let custom = WhiteBalanceCommands.customID

    private func setWhiteBalance(_ temperature: Double, _ tint: Double,
                                 on session: CatalogSession) {
        session.applyEdit {
            $0.light.temperature = temperature
            $0.light.tint = tint
        }
    }

    private func makeView(_ session: CatalogSession,
                          _ menu: WhiteBalancePresetMenuState) -> InspectorView {
        InspectorView(session: session, presetMenu: menu)
    }

    // MARK: - 1. the derived match is unchanged

    func testMatchStillUsesTheMiredQuantum() {
        let daylight = WhiteBalance(temperature: 5500, tint: 0)
        XCTAssertEqual(WhiteBalancePresets.match(daylight)?.id, WhiteBalancePresets.daylight.id)

        // 5600 K is three mireds away — nobody's constant, so the menu says 自定义.
        let between = WhiteBalance(temperature: 5600, tint: 0)
        XCTAssertNil(WhiteBalancePresets.match(between))
    }

    // MARK: - 2. 「自定义」 is selectable

    func testChoosingCustomKeepsTheDocumentAndRecordsTheState() {
        let session = CatalogSession()
        setWhiteBalance(5500, 0, on: session)
        let before = session.edit.light.whiteBalance
        let historyBefore = session.history.count

        let menu = WhiteBalancePresetMenuState()
        let view = makeView(session, menu)
        view.applyPreset(custom)

        XCTAssertEqual(menu.lastPresetID, custom, "选 自定义 must leave a selectable state")
        XCTAssertEqual(session.edit.light.whiteBalance, before,
                       "自定义 is a menu state, not a document write")
        XCTAssertEqual(session.history.count, historyBefore,
                       "no history entry for a menu state")
        XCTAssertEqual(view.whiteBalancePresetSelection, custom)
    }

    // MARK: - 3. state wins over the derived match

    func testExplicitCustomBeatsAPresetThatCarriesTheSameNanometers() {
        let session = CatalogSession()
        setWhiteBalance(5500, 0, on: session)
        let menu = WhiteBalancePresetMenuState(lastPresetID: custom)
        let view = makeView(session, menu)

        // The document still *matches* 日光; the user's state is what the menu shows.
        XCTAssertEqual(WhiteBalancePresets.match(session.edit.light.whiteBalance)?.id,
                       WhiteBalancePresets.daylight.id)
        XCTAssertEqual(view.whiteBalancePresetSelection, custom)
    }

    // MARK: - 4. a manual value is custom

    func testCommittingAHandEditedValueMarksCustom() {
        let session = CatalogSession()
        setWhiteBalance(5500, 0, on: session)
        let menu = WhiteBalancePresetMenuState(lastPresetID: WhiteBalancePresets.daylight.id)
        let view = makeView(session, menu)

        // The literal hand edit: 5500 → 5510.
        view.commitWhiteBalanceValue(5510, isTemperature: true)
        XCTAssertEqual(menu.lastPresetID, custom)
        XCTAssertEqual(view.whiteBalancePresetSelection, custom)
        XCTAssertNotEqual(session.edit.light.whiteBalance,
                          WhiteBalance(temperature: 5500, tint: 0),
                          "the edit itself must still reach the document")

        // And the case the old derivation got wrong: a hand-entered value that **still matches**
        // 日光 after the mired quantization (5500 K commits as 5495 K, one third of a mired away).
        // The menu must keep saying 自定义; the match alone would say 日光.
        menu.choose(WhiteBalancePresets.daylight.id)
        view.commitWhiteBalanceValue(5500, isTemperature: true)
        XCTAssertEqual(WhiteBalancePresets.match(session.edit.light.whiteBalance)?.id,
                       WhiteBalancePresets.daylight.id,
                       "this half is only meaningful while the pair still matches 日光")
        XCTAssertEqual(menu.lastPresetID, custom)
        XCTAssertEqual(view.whiteBalancePresetSelection, custom)
    }

    // MARK: - 5. as shot is a fact and beats custom

    func testAsShotBeatsTheCustomState() {
        let session = CatalogSession()   // document is as shot (`nil`), nothing decoded
        let menu = WhiteBalancePresetMenuState(lastPresetID: custom)
        let view = makeView(session, menu)

        XCTAssertEqual(view.whiteBalancePresetSelection, WhiteBalancePresets.asShot.id)
    }

    // MARK: - 6. picking a preset goes back to its name

    func testPickingDaylightWritesItAndSelectsIt() {
        let session = CatalogSession()
        let menu = WhiteBalancePresetMenuState(lastPresetID: custom)
        let view = makeView(session, menu)

        view.applyPreset(WhiteBalancePresets.daylight.id)

        let written = session.edit.light.whiteBalance
        XCTAssertTrue(WhiteBalancePresets.daylight.matches(written),
                      "the document must hold 日光's pair, got \(written.summary)")
        XCTAssertEqual(written.temperature,
                       WhiteBalancePresets.daylight.whiteBalance!.quantized().temperature)
        XCTAssertEqual(written.tint, 0)
        XCTAssertEqual(menu.lastPresetID, WhiteBalancePresets.daylight.id)
        XCTAssertEqual(view.whiteBalancePresetSelection, WhiteBalancePresets.daylight.id)
    }
}
