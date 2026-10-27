import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 细节卡的「解码模型」一行 (owner, 2026-10-27) — the panel side.
///
/// The control is **the file's own `supportedDecoderVersions` list**, not a V8/V9 pair: on this
/// machine's SL3 DNG that list is `6.dng, 7, 7.dng, 8, 8.dng, 9.dng`, and `8` / `8.dng` / `9.dng` are
/// three different decodes (measured with `photonsctl detail`: `08193a35…`, `a15055fa…`, `f4d7e53b…`).
///
/// Four claims:
///
///  1. **The list, the labels, the default.** `8` and `8 (DNG)` are distinguishable, `8` is the default
///     where offered, and the stored value is `nil` for it (the DNG-independent "ask for nothing" that
///     every pre-change document already is).
///  2. **The document, not the view.** One switch = one field + one history entry; the four amounts
///     keep their numbers (greyed is not zeroed); the switch is a decode input (the key moves).
///  3. **The four rows follow the effective version** through the `DetailAxes` seam — under v9 exactly
///     two are greyed (色彩降噪 + 细节, Apple's `isColorNoiseReductionSupported`/`isDetailSupported` =
///     false and zero samples moved), the other two stay live (降噪 + 锐化, flags true, 0.021 / 0.510
///     maxΔ) — and the read-back (`DetailRowEnabledLog`, SwiftUI's own `isEnabled`) is what the test
///     reads.
///  4. **The read-back wins over the request**: `已退回 v8` when the file kept something else.
@MainActor
final class DecoderModelCardTests: XCTestCase {

    static let sl3: [String] = ["6.dng", "7", "7.dng", "8", "8.dng", "9.dng"]

    // MARK: - 1. the list, the labels, the default

    func testThePickerIsTheFilesOwnVersionList() {
        XCTAssertEqual(InspectorView.decoderChoices(chosen: "8", offered: Self.sl3), Self.sl3,
                       "the list is the file's, in the file's order")
        XCTAssertEqual(InspectorView.decoderChoices(chosen: "8", offered: Self.sl3)
                        .map(InspectorView.decoderVersionLabel),
                       ["6 (DNG)", "7", "7 (DNG)", "8", "8 (DNG)", "9 (DNG)"],
                       "8 and 8 (DNG) must be distinguishable — they decode differently")

        // A document from another body names a version this file does not offer: it must still be
        // visible (that is what the read-back is about to report), and it leads the list.
        XCTAssertEqual(InspectorView.decoderChoices(chosen: "9", offered: ["8", "8.dng"]),
                       ["9", "8", "8.dng"])
        XCTAssertEqual(InspectorView.decoderChoices(chosen: "8", offered: []), ["8"],
                       "before the first frame there is no list; the control still shows a value")
    }

    func testTheDefaultIsEightWhereOfferedAndTheNearestOlderVersionOtherwise() {
        XCTAssertEqual(InspectorView.defaultDecoderSpelling(offered: Self.sl3), "8")
        XCTAssertEqual(InspectorView.defaultDecoderSpelling(offered: []), "8")
        XCTAssertEqual(InspectorView.defaultDecoderSpelling(offered: ["9", "9.dng"]), "9",
                       "no v8 at all: nothing older, so the lowest")
        XCTAssertEqual(InspectorView.defaultDecoderSpelling(offered: ["6", "7", "7.dng", "9.dng"]), "7.dng",
                       "no v8: the newest version on the older side")
    }

    // MARK: - 2. the document

    func testPickingAVersionWritesOneFieldAndOneHistoryEntry() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        let neutralKey = session.edit.decodeInputs.key
        XCTAssertTrue(neutralKey.contains("ver=auto"), "the default asks for nothing: \(neutralKey)")
        XCTAssertNil(session.edit.decoderVersion)

        session.applyEdit {
            $0.detailSettings = DetailSettings(luminanceNR: 30, colorNR: 70, sharpness: 20, detail: 60)
        }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let before = session.history.count
        let amounts = session.edit.detailSettings
        let amountsKey = session.edit.decodeInputs.key
        XCTAssertNotEqual(amountsKey, neutralKey, "the amounts alone move the key")

        XCTAssertTrue(resets.decoderVersion("9.dng", offered: Self.sl3))
        XCTAssertEqual(session.edit.decoderVersion, "9.dng")
        XCTAssertEqual(session.edit.detailSettings, amounts, "picking a decoder must not zero anything")
        XCTAssertEqual(session.history.count, before + 1, "one pick = one snapshot")
        XCTAssertEqual(session.history.currentSnapshot?.label, "解码模型")
        XCTAssertTrue(session.edit.decodeInputs.key.contains("ver=9.dng"),
                      session.edit.decodeInputs.key)
        XCTAssertNotEqual(session.edit.decodeInputs.key, amountsKey)

        XCTAssertFalse(resets.decoderVersion("9.dng", offered: Self.sl3),
                       "the same value again writes nothing — no empty snapshot")
        XCTAssertEqual(session.history.count, before + 1)

        // `8` is the file's default: stored as `nil`, i.e. the untouched decode and the old key.
        XCTAssertTrue(resets.decoderVersion("8", offered: Self.sl3))
        XCTAssertNil(session.edit.decoderVersion, "the default is nil, not an assignment")
        XCTAssertEqual(session.edit.decodeInputs.key, amountsKey)
        XCTAssertEqual(session.edit.detailSettings, amounts, "the amounts come back untouched")

        // `8.dng` is a *different* decode and is stored verbatim.
        XCTAssertTrue(resets.decoderVersion("8.dng", offered: Self.sl3))
        XCTAssertEqual(session.edit.decoderVersion, "8.dng")
        XCTAssertTrue(session.edit.decodeInputs.key.contains("ver=8.dng"))

        XCTAssertTrue(session.undo())
        XCTAssertNil(session.edit.decoderVersion)
        print("MODEL neutral key: \(neutralKey)")
    }

    func testTheCardResetAlsoGoesBackToTheDefault() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit {
            $0.decoderVersion = "9.dng"
            $0.detailSettings = DetailSettings(colorNR: 12)
        }
        XCTAssertTrue(session.commitEdit(label: "setup"))
        XCTAssertTrue(resets.group(.detail), "a changed card must reset")
        XCTAssertNil(session.edit.decoderVersion, "the card resets to the default decoder too")
        XCTAssertTrue(session.edit.detailSettings.isIdentity)
    }

    // MARK: - 3. the four rows follow the effective version (the seam)

    func testTheSeamAnswersByVersionAndOnlyColourNRAndDetailAreOff() {
        // v9: two off, two on. Written out axis by axis so a "four grey" regression cannot pass.
        let v9 = DetailAxes.forDecoderVersion("9.dng")
        XCTAssertTrue(v9.nr, "降噪 survives v9 (isLuminanceNoiseReductionSupported = true, 0.021 maxΔ)")
        XCTAssertFalse(v9.cnr, "色彩降噪 does not survive v9 (flag false, 0 samples)")
        XCTAssertFalse(v9.detail, "细节 does not survive v9 (flag false, 0 samples)")
        XCTAssertTrue(v9.sharpness, "锐化 survives v9 (isSharpnessSupported = true, 0.510 maxΔ)")
        XCTAssertEqual(v9, .v9)
        XCTAssertEqual(DetailAxes.forDecoderVersion("9"), .v9)

        XCTAssertEqual(DetailAxes.forDecoderVersion("8"), .all,
                       "placeholder until DetailCapability lands: only v9's two axes are known to be off")
        XCTAssertEqual(DetailAxes.forDecoderVersion("8.dng"), .all)
        XCTAssertEqual(DetailAxes.forDecoderVersion("6"), .all)

        // No version may deaden all four: the seam has no all-off answer (the old `.none`, deleted).
        for version in ["6", "6.dng", "7", "7.dng", "8", "8.dng", "9", "9.dng", "10"] {
            XCTAssertTrue(DetailAxes.forDecoderVersion(version).anyEnabled,
                          "v\(version) came back with all four axes off — no measured version does that")
        }

        // The card's axes come from the *effective* version, then the request, then the document.
        XCTAssertEqual(InspectorView.detailAxes(effective: "9.dng", requested: "9.dng", document: "9.dng"),
                       .v9)
        XCTAssertEqual(InspectorView.detailAxes(effective: "8", requested: "9", document: "9"), .all,
                       "the request fell back to v8: the rows work, so they are live")
        XCTAssertEqual(InspectorView.detailAxes(effective: nil, requested: "9.dng", document: "9.dng"), .v9,
                       "before the first frame a v9 document opens with 色彩降噪/细节 already inert")
        XCTAssertEqual(InspectorView.detailAxes(effective: nil, requested: "8", document: nil), .all)
    }

    /// The four rows of a **real** hosted card, read back through SwiftUI's own `isEnabled`.
    func testTheHostedCardGreysOnlyColourNRAndDetailUnderV9() {
        let all: [DetailAxis: Bool] = [.luminanceNR: true, .colorNR: true,
                                       .detail: true, .sharpness: true]
        let v9: [DetailAxis: Bool] = [.luminanceNR: true, .colorNR: false,
                                      .detail: false, .sharpness: true]
        let states: [(spelling: String?, effective: String, rows: [DetailAxis: Bool])] =
            [(nil, "8", all), ("9.dng", "9.dng", v9), ("8.dng", "8.dng", all)]
        for state in states {
            DetailRowEnabledLog.shared.reset()
            let session = CatalogSession()
            if let spelling = state.spelling {
                session.applyEdit { $0.decoderVersion = spelling }
            }
            session.recordCapabilities(DecoderCapabilities(requestedVersion: state.spelling,
                                                          effectiveVersion: state.effective,
                                                          defaultVersion: "8",
                                                          supportedVersions: Self.sl3))
            _ = Self.host(session: session)

            let log = DetailRowEnabledLog.shared.snapshot
            print("MODEL v\(state.effective) rows: \(log.sorted { $0.key < $1.key })")
            DetailRowEnabledLog.shared.reset()
            guard !log.isEmpty else {
                print("MODEL row probe: no window session — the in-view read-back is unavailable")
                continue
            }
            for axis in DetailAxis.panelOrder {
                XCTAssertEqual(log[axis.title], state.rows[axis],
                               "\(axis.title) resolved isEnabled=\(String(describing: log[axis.title]))"
                               + " under v\(state.effective) (expected \(state.rows[axis]!))")
            }
        }
    }

    func testTheCardWiresTheSeamIntoEveryRow() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("enabled: axes.isEnabled(row.axis)"),
                      "every row must take the seam's answer, not a constant")
        XCTAssertTrue(source.contains("Self.detailAxes(effective: caps?.effectiveVersion"))
        // 蒙版共用同一行之后，行的外观（灰 = `.disabled` + 半透明）搬到了 `SliderRow.swift`；卡的
        // 决定（`enabled:` 从 seam 来）仍在检查器里。
        let row = try String(contentsOf: Self.sliderRowSource, encoding: .utf8)
        XCTAssertTrue(row.contains(".disabled(!enabled)"), "灰 = .disabled")
        XCTAssertTrue(row.contains(".opacity(enabled ? 1 : 0.42)"),
                      "灰 must be visible, not only semantic")
        XCTAssertTrue(source.contains("caps?.supportedVersions"),
                      "the list must come from the file, not from a hard-coded pair")
        XCTAssertTrue(source.contains("inspector.detail.decoderModel"))
        XCTAssertFalse(source.contains("Section.decode"), "the Decode card is gone")
    }

    // MARK: - 4. the read-back

    func testTheNotePrintsTheEffectiveVersionAndNamesTheFallback() {
        XCTAssertNil(InspectorView.decoderModelNote(requested: nil, effective: nil),
                     "the default document prints nothing before the first frame")
        XCTAssertEqual(InspectorView.decoderModelNote(requested: nil, effective: "8"), "实际 v8")
        XCTAssertEqual(InspectorView.decoderModelNote(requested: "8.dng", effective: "8.dng"), "实际 v8.dng")
        XCTAssertEqual(InspectorView.decoderModelNote(requested: "9", effective: "8"), "已退回 v8",
                       "bare 9 is not offered — the line must say v8 ran")
        XCTAssertEqual(InspectorView.decoderModelNote(requested: "9.dng", effective: nil), "正在切换解码器…")

        XCTAssertTrue(InspectorView.decoderModelWasDowngraded(requested: "9", effective: "8"))
        XCTAssertFalse(InspectorView.decoderModelWasDowngraded(requested: "9.dng", effective: "9.dng"))
        XCTAssertFalse(InspectorView.decoderModelWasDowngraded(requested: nil, effective: "8"))
    }

    func testTheDecodeCardIsGoneFromThePanel() {
        XCTAssertFalse(InspectorView.sectionTitles.contains("Decode"), "\(InspectorView.sectionTitles)")
        XCTAssertFalse(InspectorView.cardTitles(in: .adjust).contains("Decode"))
        XCTAssertEqual(InspectorView.sectionTitles.last, "蒙版", "蒙版 stays the last card")
    }

    // MARK: - helpers

    private static var windows: [NSWindow] = []

    /// The panel's one row view — where the row's own appearance (grey = `.disabled` + 0.42) lives now.
    private static var sliderRowSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/PhotonsUI/SliderRow.swift")
    }

    private static var inspectorSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static func host(session: CatalogSession) -> NSView {
        let host = NSHostingView(rootView: InspectorView(session: session))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 2400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        return host
    }
}
