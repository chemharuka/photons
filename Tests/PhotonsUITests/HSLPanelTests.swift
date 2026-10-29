import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 076 — the **HSL card**, in the 色彩 workspace: eight band selectors, and the selected band's
/// three sliders, at the three panel widths the inspector is used at.
///
/// What this file holds, and why each half is needed:
///
///  * **Structure** — the colour workspace is the HSL card and nothing else, the eight selectors are
///    real views in Lightroom's order, and each is drawn in the colour it names (the swatch is computed
///    from the band's own OKLCh centre, so a band that moved would show a stale colour).
///  * **Layout at 244 / 330 / 364 pt** — measured off `NSView` frames, not arithmetic: 「八个选择器 +
///    三根滑杆在窄面板下不挤压」 is a claim about pixels, and `swift test` has no accessibility tree.
///  * **Document I/O** — picking a band writes *nothing* (it is view state), and typing into 色相 /
///    饱和 / 亮度 writes exactly one field of the selected band (through the field editor, the path 057
///    built), with the other seven bands untouched.
@MainActor
final class HSLPanelTests: XCTestCase {

    /// 244 is the narrowest the inspector is allowed to be (073), 330 the default, 364 the wide drag.
    private static let widths: [CGFloat] = [244, 330, 364]
    private static let panelHeight: CGFloat = 900

    // MARK: - structure

    func testTheColourWorkspaceIsTheHSLCardAndNothingElse() {
        // 2026-10-28: the workspace holds three cards — HSL, 色彩分级, then 黑白 (the user put it below
        // the grading card) — and HSL is still the one this suite is about.
        XCTAssertEqual(InspectorWorkspace.colour.cards, [.hsl, .pointColor, .colorGrading, .blackAndWhite])
        XCTAssertEqual(InspectorView.cardTitles(in: .colour), ["HSL", "点颜色", "色彩分级", "黑白"],
                       "the colour workspace: 黑白, then HSL, then 色彩分级")
        XCTAssertEqual(InspectorView.Section.hsl.title, "HSL")
        XCTAssertTrue(InspectorWorkspace.colour.hasCards)
        XCTAssertFalse(InspectorWorkspace.colour.help.contains("尚未实现"),
                       "the tooltip must stop claiming the workspace is empty")
        XCTAssertFalse(InspectorWorkspace.adjust.cards.contains(.colorGrading),
                       "色彩分级 lives in 色彩 with HSL, not under 调整")
        XCTAssertFalse(InspectorWorkspace.adjust.cards.contains(.hsl),
                       "the bands get their own workspace, not a seventh row under Color")
        XCTAssertEqual(HSLAxis.allCases.map(\.title), ["色相", "饱和", "亮度"])
        XCTAssertEqual(HSLAxis.range, -100...100)
    }

    func testTheNineSelectorsAreOnScreenInTheirOwnColours() throws {
        let panel = try host(width: 330, state: .init(.colour, hslBand: 4))
        defer { panel.close() }
        let probes = panel.bandProbes
        XCTAssertEqual(probes.count, 9, "eight bands + 全局, or the selector is not a selector")
        XCTAssertEqual(probes.map(\.title), HSLAxis.bandNames + [HSLAxis.globalName])
        XCTAssertEqual(probes.map(\.band), Array(0..<9))
        XCTAssertEqual(probes.filter(\.isSelected).map(\.band), [4],
                       "exactly the selected band is drawn as selected")

        func rgb(_ c: NSColor) -> (Double, Double, Double, Double) {
            let s = c.usingColorSpace(.sRGB) ?? c
            return (Double(s.redComponent), Double(s.greenComponent),
                    Double(s.blueComponent), Double(s.alphaComponent))
        }
        let red = rgb(probes[0].swatch), green = rgb(probes[3].swatch), blue = rgb(probes[5].swatch)
        print("HSL SWATCH · 红 \(red) · 绿 \(green) · 蓝 \(blue)")
        XCTAssertGreaterThan(red.0, red.1 + 0.15, "the red dot must read red")
        XCTAssertGreaterThan(red.0, red.2 + 0.15)
        XCTAssertGreaterThan(green.1, green.0 + 0.10, "the green dot must read green")
        XCTAssertGreaterThan(green.1, green.2 + 0.10)
        XCTAssertGreaterThan(blue.2, blue.0 + 0.10, "the blue dot must read blue")
        XCTAssertGreaterThan(blue.2, blue.1 + 0.10)

        // 101: the ninth cell's **background** is pure white — RGBA exactly (1, 1, 1, 1).
        let white = rgb(probes[8].backgroundColor)
        XCTAssertEqual(white.0, 1, accuracy: 1e-9, "全局 must be white")
        XCTAssertEqual(white.1, 1, accuracy: 1e-9)
        XCTAssertEqual(white.2, 1, accuracy: 1e-9)
        XCTAssertEqual(white.3, 1, accuracy: 1e-9)
        XCTAssertEqual(probes[8].title, "全局")
        XCTAssertEqual(probes[8].band, 8)
    }

    /// **The three widths.** Each of the eight cells keeps a real, non-degenerate frame, they sit on one
    /// row, and the three slider rows live inside the panel — so nothing is clipped and nothing is
    /// starved to a sliver.
    func testTheCardFitsAtEveryWidth() throws {
        for width in Self.widths {
            let panel = try host(width: width, state: .init(.colour))
            XCTAssertEqual(panel.cardIDs, ["hsl", "pointColor", "colorGrading", "blackAndWhite"],
                           "\(width) pt: the colour workspace shows HSL then 色彩分级")

            let probes = panel.bandProbes
            XCTAssertEqual(probes.count, 9, "\(width) pt: nine selectors")
            let frames = panel.bandFrames
            let widths = frames.map(\.width)
            let narrowest = widths.min() ?? 0
            XCTAssertGreaterThanOrEqual(narrowest, 12,
                                        "\(width) pt: a band cell collapsed to \(narrowest) pt")
            let tallest = frames.map(\.height).max() ?? 0
            XCTAssertEqual(tallest, HSLBandStrip.height, accuracy: 0.5,
                           "\(width) pt: the strip must keep its \(HSLBandStrip.height) pt height")
            let tops = Set(frames.map { ($0.maxY * 10).rounded() })
            XCTAssertEqual(tops.count, 1, "\(width) pt: the nine cells must sit on one row")
            for f in frames {
                XCTAssertGreaterThanOrEqual(f.minX, -0.5, "\(width) pt: a cell starts off-panel")
                XCTAssertLessThanOrEqual(f.maxX, width + 0.5, "\(width) pt: a cell runs past the panel")
            }

            let fields = panel.numberFields
            // 3 HSL rows + 9 色彩分级 rows + the 黑白 card's eight mixes (its switch is not a number):
            // since 2026-10-28 黑白 lives in this workspace, so every number here is typeable.
            XCTAssertEqual(fields.count, 3 + InspectorView.colorGradingRowCount
                                              + InspectorView.bwRows.count
                                              + PointColorAxis.allCases.count,
                           "\(width) pt: HSL 三行 + 点颜色五行 + 九行分级 + 八行黑白混合必须都能键入")
            for f in panel.numberFieldFrames {
                XCTAssertGreaterThanOrEqual(f.minX, -0.5, "\(width) pt: a row starts off-panel")
                XCTAssertLessThanOrEqual(f.maxX, width + 0.5, "\(width) pt: a row runs past the panel")
                XCTAssertGreaterThan(f.width, 6, "\(width) pt: a readout collapsed")
            }
            print("HSL LAYOUT · \(Int(width)) pt: cells "
                  + String(format: "%.1f–%.1f", narrowest, widths.max() ?? 0) + " pt wide,"
                  + " strip " + String(format: "%.1f", panel.stripWidth) + " pt,"
                  + " 3 fields, scroll content " + String(format: "%.0f", panel.cardHeight) + " pt tall")
            panel.close()
        }
    }

    // MARK: - document I/O

    /// Picking a band is **view state**: no document write, no snapshot, no revision move.
    func testSelectingABandWritesNothing() throws {
        let panel = try host(width: 330, state: .init(.colour))
        defer { panel.close() }
        let revision = panel.session.editRevision
        let snapshots = panel.session.history.count
        let before = panel.session.edit

        panel.state.selectBand(6)
        panel.pump()

        XCTAssertEqual(panel.state.hslBand, 6)
        XCTAssertEqual(panel.bandProbes.filter(\.isSelected).map(\.band), [6],
                       "the selector must follow the view state")
        XCTAssertEqual(panel.session.edit, before, "picking a band is not an edit")
        XCTAssertEqual(panel.session.editRevision, revision)
        XCTAssertEqual(panel.session.history.count, snapshots)
        panel.state.selectBand(99)
        XCTAssertEqual(panel.state.hslBand, 8, "out of range clamps to 全局 instead of crashing")
        panel.state.selectBand(-3)
        XCTAssertEqual(panel.state.hslBand, 0)
    }

    /// The three rows **read and write the selected band** — through the field editor, i.e. the same
    /// path a user's keystroke takes (057). Typing `40` into 色相 with band 2 selected must move
    /// `color.bands[2].hue` and leave every other band alone.
    func testTheThreeRowsReadAndWriteTheSelectedBand() throws {
        let panel = try host(width: 330, state: .init(.colour, hslBand: 2))
        defer { panel.close() }

        // The read side first: the document's own numbers are what the rows print. Three distinct
        // values, so the fields can be found by what they show rather than by hierarchy order.
        let seed = HSLBand(hue: -17, saturation: 23, luminance: -8)
        panel.session.applyEdit { $0.color.bands[2] = seed }
        panel.session.commitEdit(label: "seed")
        panel.pump()
        // The three HSL rows print the selected band's own values; the nine 色彩分级 rows print their
        // own zeros (they are a different card, and they must not be showing the band's numbers).
        XCTAssertEqual(Set(panel.numberFields.map(\.stringValue)), ["-17", "23", "-8", "30°", "0"],
                       "the rows must print the selected band's own values")

        try panel.type("40", intoFieldShowing: "-17")     // 色相
        XCTAssertEqual(panel.session.edit.color.bands[2].hue, 40)
        try panel.type("55", intoFieldShowing: "23")      // 饱和
        XCTAssertEqual(panel.session.edit.color.bands[2].saturation, 55)
        try panel.type("-30", intoFieldShowing: "-8")     // 亮度
        XCTAssertEqual(panel.session.edit.color.bands[2].luminance, -30)

        for i in 0..<ColorGroup.bandCount where i != 2 {
            XCTAssertEqual(panel.session.edit.color.bands[i], HSLBand(),
                           "band \(i) must not have moved")
        }
        XCTAssertEqual(panel.session.edit.color.bands[2],
                       HSLBand(hue: 40, saturation: 55, luminance: -30))
        print("HSL ROWS · band 2 = " + panel.session.edit.color.bands[2].keyString
              + " · other seven identity · history \(panel.session.history.count) snapshots")
    }

    /// 101 — selecting the ninth cell binds the same three rows to `color.global`, and a keystroke
    /// writes that triplet — not band 7 and not any of the eight bands.
    func testSelectingGlobalBindsTheThreeRowsToTheGlobalTriplet() throws {
        let panel = try host(width: 330, state: .init(.colour, hslBand: 8))
        defer { panel.close() }
        XCTAssertEqual(panel.bandProbes.filter(\.isSelected).map(\.band), [8])

        let seed = HSLBand(hue: -17, saturation: 23, luminance: -8)
        panel.session.applyEdit { $0.color.global = seed }
        panel.session.commitEdit(label: "seed")
        panel.pump()
        XCTAssertTrue(Set(panel.numberFields.map(\.stringValue)).isSuperset(of: ["-17", "23", "-8"]),
                      "the rows must print the global triplet")

        try panel.type("40", intoFieldShowing: "-17")     // 全局 色相
        XCTAssertEqual(panel.session.edit.color.global.hue, 40)
        try panel.type("55", intoFieldShowing: "23")      // 全局 饱和
        XCTAssertEqual(panel.session.edit.color.global.saturation, 55)
        try panel.type("-30", intoFieldShowing: "-8")     // 全局 亮度
        XCTAssertEqual(panel.session.edit.color.global.luminance, -30)
        for i in 0..<ColorGroup.bandCount {
            XCTAssertEqual(panel.session.edit.color.bands[i], HSLBand(),
                           "band \(i) must not have moved from a 全局 edit")
        }
        print("HSL GLOBAL ROWS · " + panel.session.edit.color.global.keyString)
    }

    // MARK: - harness
    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let session: CatalogSession
        let state: InspectorWorkspaceState

        func close() {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.orderOut(nil)
        }

        func pump(_ seconds: TimeInterval = 0.2) {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
            host.layoutSubtreeIfNeeded()
        }

        private var cardsProbe: InspectorCardsProbe? {
            views(of: "InspectorCardsProbe").compactMap { $0 as? InspectorCardsProbe }.first
        }
        var cardIDs: [String] { cardsProbe?.cardIDs ?? [] }
        var cardHeight: CGFloat { cardsProbe.map { $0.convert($0.bounds, to: host).height } ?? -1 }

        var bandProbes: [HSLBandProbe] {
            views(of: "HSLBandProbe").compactMap { $0 as? HSLBandProbe }
                .sorted { $0.frame.minX < $1.frame.minX }
        }
        var bandFrames: [CGRect] {
            bandProbes.map { $0.convert($0.bounds, to: host) }
        }
        var stripWidth: CGFloat {
            let f = bandFrames
            guard let lo = f.map(\.minX).min(), let hi = f.map(\.maxX).max() else { return -1 }
            return hi - lo
        }
        var numberFields: [NumberTextField] {
            views(of: "NumberTextField").compactMap { $0 as? NumberTextField }
        }
        var numberFieldFrames: [CGRect] {
            numberFields.map { $0.convert($0.bounds, to: host) }
        }

        /// Type into the row whose readout currently shows `value`, **through AppKit**: focus the real
        /// `NSTextField`, let the field editor take the keystroke, then press **↵** — the only exit that
        /// writes since 2026-10-28 (losing focus now cancels and restores the old value, per the user:
        /// 「点击其他地方就取消点击输入，并退回之前的值」).
        func type(_ text: String, intoFieldShowing value: String) throws {
            let field = try XCTUnwrap(numberFields.first { $0.stringValue == value },
                                      "no row showing \(value) — rows are \(numberFields.map(\.stringValue))")
            XCTAssertTrue(window.makeFirstResponder(field), "the field must take focus")
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "no field editor")
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText(text, replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))   // ↵ commits
            pump(0.2)
        }

        private func views(of className: String) -> [NSView] {
            var found: [NSView] = []
            func walk(_ v: NSView) {
                if String(describing: Swift.type(of: v)) == className { found.append(v) }
                for sub in v.subviews { walk(sub) }
            }
            walk(host)
            return found
        }
    }

    private func host(width: CGFloat, state: InspectorWorkspaceState) throws -> Panel {
        _ = NSApplication.shared
        let session = CatalogSession()
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: Self.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        host.layoutSubtreeIfNeeded()
        let panel = Panel(host: host, window: window, session: session, state: state)
        XCTAssertEqual(panel.cardIDs, ["hsl", "pointColor", "colorGrading", "blackAndWhite"], "the panel did not open on the HSL card")
        return panel
    }
}
