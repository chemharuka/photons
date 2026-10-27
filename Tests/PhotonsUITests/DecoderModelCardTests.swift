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
///  2. **The document, not the view.** One switch = the version **and** the four defaults
///     (`detailSettings = .identity`, i.e. 四根都停在机身基线) in **one** history entry — 改版本必须
///     强制覆盖降噪/细节，而不是把不被支持的旧值留在文档里。The switch is a decode input, so both the
///     decode key *and* the rung identity move (`appending(to:)` carries `ver=`).
///  3. **The four rows follow `capabilities.detailAxes`** — Apple's per-instance `isSupported` flags,
///     read off the filter that made the pixels (`DetailAxes.supported(by:)`) and carried in
///     `DecoderCapabilities`. On this machine's `9.dng` exactly two are greyed (色彩降噪 + 细节) and the
///     other two stay live (降噪 + 锐化); the version-prefix table `DetailAxes.forDecoderVersion` is
///     only the pre-first-frame fallback. The read-back (`DetailRowEnabledLog`, SwiftUI's own
///     `isEnabled`) is what the test reads.
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

    /// **One pick = the version + the four defaults, in one snapshot.**
    ///
    /// The owner's rule (2026-10-27): 改解码版本时把降噪/细节四根滑杆**强制覆盖**到该版本的默认值，
    /// and the version change is the same undo step. Both halves are asserted, and so is the rung
    /// identity — the version is a decode input, so it must appear in `appending(to:)` and not only in
    /// `key` (that omission is why the canvas stood still until a slider moved).
    func testPickingAVersionWritesTheVersionAndTheFourDefaultsInOneEntry() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        let neutralKey = session.edit.decodeInputs.key
        XCTAssertTrue(neutralKey.contains("ver=auto"), "the default asks for nothing: \(neutralKey)")
        XCTAssertNil(session.edit.decoderVersion)
        XCTAssertEqual(session.edit.decodeInputs.appending(to: "photo"), "photo",
                       "the default document appends nothing to a rung identity")

        let amounts = DetailSettings(luminanceNR: 30, colorNR: 70, sharpness: 20, detail: 60)
        session.applyEdit { $0.detailSettings = amounts }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let before = session.history.count
        let amountsKey = session.edit.decodeInputs.key
        XCTAssertNotEqual(amountsKey, neutralKey, "the amounts alone move the key")
        XCTAssertEqual(session.edit.decodeInputs.appending(to: "photo"), "photo|dt=nr30,c70,s20,d60")

        XCTAssertTrue(resets.decoderVersion("9.dng", offered: Self.sl3))
        XCTAssertEqual(session.edit.decoderVersion, "9.dng")
        XCTAssertEqual(session.edit.detailSettings, .identity,
                       "换版本必须把四轴强制回该版本的默认值（.identity = 四根都停在机身基线）")
        XCTAssertEqual(session.history.count, before + 1, "one pick = one snapshot (版本 + 四轴)")
        XCTAssertEqual(session.history.currentSnapshot?.label, "解码模型")
        XCTAssertTrue(session.edit.decodeInputs.key.contains("ver=9.dng"),
                      session.edit.decodeInputs.key)
        XCTAssertEqual(session.edit.decodeInputs.appending(to: "photo"), "photo|ver=9.dng",
                       "the rung identity must carry the requested decoder version")

        // ⌘Z takes back **both** halves — one entry, not two.
        XCTAssertTrue(session.undo())
        XCTAssertNil(session.edit.decoderVersion, "undo restores the version …")
        XCTAssertEqual(session.edit.detailSettings, amounts, "… and the four amounts, in the same step")
        XCTAssertTrue(session.redo())
        XCTAssertEqual(session.edit.decoderVersion, "9.dng")
        XCTAssertTrue(session.edit.detailSettings.isIdentity)

        XCTAssertFalse(resets.decoderVersion("9.dng", offered: Self.sl3),
                       "the same value again writes nothing — no empty snapshot, no stealth reset")
        XCTAssertEqual(session.history.count, before + 1)

        // `8` is the file's default: stored as `nil`, i.e. the untouched decode and the bare identity.
        XCTAssertTrue(resets.decoderVersion("8", offered: Self.sl3))
        XCTAssertNil(session.edit.decoderVersion, "the default is nil, not an assignment")
        XCTAssertEqual(session.edit.decodeInputs.appending(to: "photo"), "photo")
        XCTAssertTrue(session.edit.detailSettings.isIdentity)

        // `8.dng` is a *different* decode and is stored verbatim.
        XCTAssertTrue(resets.decoderVersion("8.dng", offered: Self.sl3))
        XCTAssertEqual(session.edit.decoderVersion, "8.dng")
        XCTAssertEqual(session.edit.decodeInputs.appending(to: "photo"), "photo|ver=8.dng")

        XCTAssertTrue(session.undo())
        XCTAssertNil(session.edit.decoderVersion)
        print("MODEL neutral key: \(neutralKey) · rung identity of the default document: photo")
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
                       "the fallback table knows only v9's two dead axes")
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
        XCTAssertTrue(source.contains("Self.detailAxes(capabilities: caps"),
                      "the rows' axes must come from the decoded capabilities first")
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

    /// **The data source, end to end**: a real `9.dng` develop's `capabilities` — Apple's flags —
    /// reach the four hosted rows. The version string is the *same* in both branches, so this test
    /// fails if the card goes back to `DetailAxes.forDecoderVersion` (or if the flags are ignored
    /// anywhere on the way).
    func testTheHostedCardGreysFromTheDecodedCapabilitiesAndNotFromTheVersionString() throws {
        let url = try Self.fixtureURL()
        let offered = try RAWDecoder.availableVersions(for: url)
        try XCTSkipUnless(offered.contains("9.dng"), "this fixture offers no v9.dng: \(offered)")

        let caps = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(decoderVersion: "9.dng",
                                                                              scale: 0.125)).capabilities
        print("MODEL decoded v\(caps.effectiveVersion) · axes[\(caps.detailAxesProvenance.rawValue)]"
              + " \(caps.detailAxes.flagSummary)")

        // ① the pure function the card calls returns the capabilities value verbatim.
        XCTAssertEqual(InspectorView.detailAxes(capabilities: caps, requested: "9.dng", document: "9.dng"),
                       caps.detailAxes)
        XCTAssertFalse(caps.detailAxes.cnr, "Apple: isColorNoiseReductionSupported = false on 9.dng")
        XCTAssertFalse(caps.detailAxes.detail, "Apple: isDetailSupported = false on 9.dng")

        // ② the hosted card, read back through SwiftUI's own `isEnabled`.
        DetailRowEnabledLog.shared.reset()
        let session = CatalogSession()
        session.applyEdit { $0.decoderVersion = "9.dng" }
        session.recordCapabilities(caps)
        _ = Self.host(session: session)
        let log = DetailRowEnabledLog.shared.snapshot
        print("MODEL hosted rows for the decoded v9: \(log.sorted { $0.key < $1.key })")
        DetailRowEnabledLog.shared.reset()
        guard !log.isEmpty else {
            print("MODEL row probe: no window session — the in-view read-back is unavailable")
            return
        }
        XCTAssertEqual(log[DetailAxis.luminanceNR.title], true, "降噪 is live under v9 (flag true)")
        XCTAssertEqual(log[DetailAxis.colorNR.title], false, "色彩降噪 is greyed under v9 (flag false)")
        XCTAssertEqual(log[DetailAxis.detail.title], false, "细节 is greyed under v9 (flag false)")
        XCTAssertEqual(log[DetailAxis.sharpness.title], true, "锐化 is live under v9 (flag true)")
    }

    private static func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
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
        // 077（2026-10-27）：历史记录成为最后一张卡（蒙版仍是它前面的最后一张参数卡）。
        XCTAssertEqual(InspectorView.sectionTitles.suffix(2), ["蒙版", "历史记录"])
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
