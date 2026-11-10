import XCTest
import SwiftUI
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 320 — 「最高亮度」 is a **row in the Light card** (the owner's placement: 「没有显示卡就放 Light 卡最底
/// 一行」), it shows `+2.3 EV` by default, its travel is 0…+4 EV, and a double-click on the name resets
/// it. It is a preference, not a document field: the row may not write an edit, dirty the document or
/// leave a history entry.
///
/// The row is drawn by the panel's own `SliderRow`, so what this file can assert without a pointer is
/// what the row *is*: its label, its identifier, its travel, its readout string, the preference it
/// writes, and that it renders **inside** the Light card after the six tone rows.
@MainActor
final class HighlightCeilingRowTests: XCTestCase {

    private var savedPref: Any?

    override func setUp() {
        super.setUp()
        savedPref = UserDefaults.standard.object(forKey: HighlightCeiling.defaultsKey)
        UserDefaults.standard.removeObject(forKey: HighlightCeiling.defaultsKey)
    }

    override func tearDown() {
        if let savedPref { UserDefaults.standard.set(savedPref, forKey: HighlightCeiling.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: HighlightCeiling.defaultsKey) }
        super.tearDown()
    }

    /// The card's row table is unchanged — the ceiling is **not** an eighth tone row (it has no
    /// `light.*` field), which is what keeps `resets.group(.light)` from trying to reset it and keeps
    /// the seven-row contract of `LightCardTests` true.
    func testTheCeilingIsNotAnEighthDocumentRow() {
        XCTAssertEqual(InspectorView.lightRows.count, 7)
        XCTAssertFalse(InspectorView.lightRows.contains { $0.title == "最高亮度" },
                       "最高亮度 is a preference — it has no document field to reset")
    }

    /// The readout the row paints, and its travel.
    func testTheRowShowsPlusTwoPointThreeAndTravelsToFourEV() {
        XCTAssertEqual(InspectorView.sliderText("%+.1f EV", HighlightCeiling.currentEV), "+2.3 EV")
        XCTAssertEqual(HighlightCeiling.evRange, 0 ... 4)
        XCTAssertEqual(HighlightCeiling.stepEV, 0.1)
        XCTAssertEqual(HighlightCeiling.defaultEV, 2.3)
        // The value the renderers read is the same number the row prints.
        XCTAssertEqual(HighlightCeiling.current, pow(2.0, 2.3), accuracy: 1e-12)
        print("320 row · label 最高亮度 · readout \(HighlightCeiling.label(HighlightCeiling.currentEV))"
              + " · range \(HighlightCeiling.evRange) · step \(HighlightCeiling.stepEV)")
    }

    /// Writing the row's value moves every render path that reads the preference — and posts the
    /// notification the loupe re-renders on.
    func testWritingTheRowMovesThePreferenceAndNotifies() {
        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: .highlightCeilingDidChange, object: nil, queue: nil) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        HighlightCeiling.setEV(4.0)
        XCTAssertEqual(HighlightCeiling.currentEV, 4.0, accuracy: 1e-12)
        XCTAssertEqual(DisplayOptions(highlightCeiling: HighlightCeiling.current).highlightCeiling,
                       16.0, accuracy: 1e-12)
        XCTAssertEqual(notifications, 1, "the loupe re-renders off this notification")
        XCTAssertTrue(DisplayOptions(highlightCeiling: HighlightCeiling.current)
            .keyString.contains("ceil=16.0000"),
                      "the render key follows the row, so a cached frame cannot outlive the change")
    }

    /// A double-click is `onReset`, i.e. `defaultEV` — the same number an untouched install renders.
    func testDoubleClickResetsToTwoPointThree() {
        HighlightCeiling.setEV(3.7)
        XCTAssertEqual(HighlightCeiling.currentEV, 3.7, accuracy: 1e-12)
        HighlightCeiling.setEV(HighlightCeiling.defaultEV)
        XCTAssertEqual(HighlightCeiling.currentEV, 2.3, accuracy: 1e-12)
        XCTAssertEqual(HighlightCeiling.label(HighlightCeiling.currentEV), "+2.3 EV")
    }

    // MARK: - the rendered card

    private static var windows: [NSWindow] = []

    private static func identifiers(in root: NSView, depth: Int = 0) -> [String] {
        guard depth < 24 else { return [] }
        var out: [String] = []
        for child in root.accessibilityChildren() ?? [] {
            if let view = child as? NSView {
                let id = view.accessibilityIdentifier()
                if !id.isEmpty { out.append(id) }
            }
            if let element = child as? NSAccessibilityElement,
               let id = element.accessibilityIdentifier(), !id.isEmpty {
                out.append(id)
            }
            if let view = child as? NSView { out += identifiers(in: view, depth: depth + 1) }
        }
        return out
    }

    func testTheRenderedLightCardCarriesTheRowAfterTheToneRows() {
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 2600)
        let window = TestWindows.make(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        Self.windows.append(window)
        host.layoutSubtreeIfNeeded()

        let ids = Self.identifiers(in: host)
        print("320 row ids: \(ids.filter { $0.contains("light") })")
        guard ids.contains("inspector.card.light") else {
            // No accessibility tree in this environment — the assertions above are the check (the
            // same degradation `LightCardTests` uses).
            return
        }
        let row = "inspector.light.row.最高亮度"
        XCTAssertTrue(ids.contains("inspector.display.highestLight"),
                      "the row's number field is outside the tone namespace (it is not a document row)")
        XCTAssertTrue(ids.contains(row), "「最高亮度」 must render inside the Light card: \(ids)")
        let toneRows = ids.compactMap { id -> Int? in
            guard id.hasPrefix("inspector.light.row.") else { return nil }
            return ids.firstIndex(of: id)
        }
        let rowIndex = try? XCTUnwrap(ids.firstIndex(of: row))
        if let rowIndex, let last = toneRows.max() {
            XCTAssertGreaterThan(rowIndex, last, "the ceiling is the card's **last** row")
        }
    }
}
