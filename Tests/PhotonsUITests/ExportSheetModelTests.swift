import XCTest
import AppKit
import SwiftUI
import PhotonsCore
import PhotonsExport
@testable import PhotonsUI

/// 099 — the sheet's section order, the one-line summary, and the preset files behind the popup.
/// 106 — the HDR row's default/remembered state, the HDR export options, and the results layout.
@MainActor
final class ExportSheetModelTests: XCTestCase {

    private var scratch: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-sheet-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.contentView = nil }
        windows = []
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func model() -> ExportSheetModel {
        ExportSheetModel(presetStore: ExportPresetStore(directory: scratch))
    }

    // MARK: sections

    func testSectionOrderMatchesLightroom() {
        XCTAssertEqual(ExportSheetModel.sectionTitles,
                       ["位置", "文件命名", "文件设置", "图像尺寸", "输出锐化", "元数据", "导出"])
    }

    // MARK: summary

    func testBottomSummaryIsExact() {
        let sheet = model()
        sheet.selectionCount = 3

        sheet.preset = ExportSheetModel.defaultPreset
        sheet.preset.format = .jpeg
        sheet.preset.longEdge = 2400
        sheet.preset.bitDepth = 8
        sheet.preset.colorSpace = .sRGB
        sheet.preset.sizingMode = .longEdge
        sheet.preset.conflict = .rename
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 3 张 → JPEG · 8 位 · sRGB · 长边 2400 · 重命名")

        sheet.preset.format = .tiff
        sheet.preset.bitDepth = 16
        sheet.preset.colorSpace = .displayP3
        sheet.preset.sizingMode = .percent
        sheet.preset.percent = 60
        sheet.preset.conflict = .skip
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 3 张 → TIFF · 16 位 · Display P3 · 长边 60% · 跳过")

        sheet.preset.format = .png
        sheet.preset.bitDepth = 8
        sheet.preset.colorSpace = .sRGB
        sheet.preset.longEdge = 1234
        sheet.preset.sizingMode = .none
        sheet.preset.conflict = .overwrite
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 3 张 → PNG · 8 位 · sRGB · 原尺寸 · 覆盖")
    }

    // MARK: preset files

    func testSaveLoadAndDeleteAPreset() throws {
        let sheet = model()
        sheet.preset = ExportSheetModel.defaultPreset
        sheet.preset.longEdge = 2400
        sheet.preset.conflict = .skip

        XCTAssertTrue(sheet.savePreset(named: "网络 2048"))
        XCTAssertEqual(sheet.presetNames, ["网络 2048"])
        let file = scratch.appendingPathComponent("网络-2048.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        sheet.preset = ExportSheetModel.defaultPreset
        XCTAssertEqual(sheet.preset.longEdge, 2048)
        sheet.loadPreset(named: "网络 2048")
        XCTAssertEqual(sheet.preset.longEdge, 2400)
        XCTAssertEqual(sheet.preset.conflict, .skip)
        XCTAssertEqual(sheet.preset.name, "网络 2048")

        sheet.deletePreset(named: "网络 2048")
        XCTAssertTrue(sheet.presetNames.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSafePresetFilenameStripsPathCharacters() {
        XCTAssertEqual(ExportPresetStore.safeFilename("a/b:c d"), "a-b-c-d")
        XCTAssertEqual(ExportPresetStore.safeFilename("   "), "preset")
    }

    // MARK: - 106 HDR

    /// §A + §2: a fresh draft is HEIC with HDR on and ISO RGB gain maps, and the batch's own options
    /// carry the flag — that is the door `Exporter.write` checks before it calls `GainMapHEIC`.
    func testHDRIsOnByDefaultAndTheBatchTakesTheGainMapPath() {
        let sheet = model()
        XCTAssertEqual(sheet.preset.format, .heic, "HDR needs the HEIF container")
        XCTAssertEqual(sheet.preset.hdr?.enabled, true, "HDR defaults to on")
        // 默认值随系统：15+ 是 ISO（ImageIO 的 ISOGainMap），14 是 Apple（14.1 就有 HDRGainMap）。
        XCTAssertEqual(sheet.preset.hdr?.gainMap, HDRExport.defaultGainMap)
        XCTAssertEqual(sheet.preset.hdr?.halfSize, false)
        XCTAssertEqual(sheet.preset.hdr?.headroom, .auto)

        XCTAssertNotNil(sheet.preset.exportOptions.hdr)
        XCTAssertEqual(sheet.preset.exportOptions.hdr?.enabled, true)
        XCTAssertNoThrow(try sheet.preset.validated())
    }

    /// §A: the row is HEIC-only. Switching away records "off" in the preset (so `validated()` accepts
    /// it) but the user's real choice survives and comes back with HEIC — both directions.
    func testHDRIsHEICOnlyAndTheUsersChoiceSurvivesTheFormatRoundTrip() {
        let sheet = model()
        sheet.hdrGainMap = .apple
        sheet.hdrHalfSize = true
        XCTAssertTrue(sheet.hdrEnabled)

        // HEIC → JPEG: greyed/off, and a JPEG preset validates.
        sheet.selectFormat(.jpeg)
        XCTAssertEqual(sheet.preset.format, .jpeg)
        XCTAssertFalse(sheet.hdrEnabled)
        XCTAssertEqual(sheet.preset.hdr?.enabled, false)
        XCTAssertNil(sheet.preset.exportOptions.hdr, "off means the SDR encoder path")
        XCTAssertNoThrow(try sheet.preset.validated())

        // …and JPEG → HEIC restores both the switch and the menu choices.
        sheet.selectFormat(.heic)
        XCTAssertTrue(sheet.hdrEnabled)
        XCTAssertEqual(sheet.preset.hdr?.enabled, true)
        XCTAssertEqual(sheet.hdrGainMap, .apple)
        XCTAssertTrue(sheet.hdrHalfSize)
        XCTAssertEqual(sheet.preset.exportOptions.hdr?.gainMap, .apple)

        // The other order: the user turns HDR off, leaves HEIC, comes back — it stays off.
        sheet.setHDR(false)
        XCTAssertFalse(sheet.preset.hdr?.enabled ?? true)
        sheet.selectFormat(.jpeg)
        sheet.selectFormat(.heic)
        XCTAssertFalse(sheet.hdrEnabled, "a user who turned HDR off must not get it back for free")
        XCTAssertNil(sheet.preset.exportOptions.hdr)
        XCTAssertNoThrow(try sheet.preset.validated())

        // A second round trip must not resurrect the default either.
        sheet.selectFormat(.png)
        sheet.selectFormat(.heic)
        XCTAssertFalse(sheet.hdrEnabled)
    }

    /// §A + §3: the extra summary segment appears only while HDR is on and legal; off is 099 verbatim.
    func testSummaryShowsHDROnlyWhenTheToggleIsOn() {
        let sheet = model()
        sheet.selectionCount = 2
        sheet.preset = ExportSheetModel.defaultPreset

        // 钉死 iso 再断言文案，别让这条测试随 macOS 版本漂移。
        sheet.hdrGainMap = .iso
        XCTAssertTrue(sheet.summaryLine.contains("HDR ISO RGB"), sheet.summaryLine)
        sheet.hdrGainMap = .mono
        sheet.hdrHalfSize = true
        XCTAssertTrue(sheet.summaryLine.contains("HDR ISO mono 半尺寸"), sheet.summaryLine)

        sheet.setHDR(false)
        XCTAssertFalse(sheet.summaryLine.contains("HDR"))
        XCTAssertEqual(sheet.summaryLine,
                       "将导出 2 张 → HEIC · 8 位 · sRGB · 长边 2048 · 重命名")
    }

    // MARK: - 106 layout (measured on the real hosted sheet)

    /// §B: the scroll region is the flexible one — 760 pt gives it at least 35 % of the window, a
    /// taller window gives it the extra ~240 pt, and the form/footer keep their heights. The empty
    /// prompt is on the footer row, outside the results region, and empty results build no scroll view.
    /// The sheet is a fixed 620×900 now: the seven 文件设置-era sections must get their natural
    /// height (they used to be squeezed to 320 pt, which read as 「格式选择全都没了」), and the results
    /// region takes what is left with a floor of 120 pt.
    func testTheSevenSectionsGetTheirHeightAndResultsTakeTheRest() throws {
        let sheet = try host(height: 900)
        let resultsFrame = try frame(of: .results, in: sheet.host)
        let formFrame = try frame(of: .form, in: sheet.host)
        let footerFrame = try frame(of: .footer, in: sheet.host)
        let status = try frame(of: .status, in: sheet.host)
        let resultsProbe = try probe(of: .results, in: sheet.host)

        print(String(format: "layout · form %.1f · results %.1f · footer %.1f (footer maxY %.1f of %.1f)",
                     formFrame.height, resultsFrame.height, footerFrame.height,
                     footerFrame.maxY, sheet.host.bounds.maxY))

        // 1. the form is not squeezed: much more than the old 320 pt clamp.
        XCTAssertGreaterThanOrEqual(formFrame.height, 600,
                                    "文件设置 那一组又被压扁了：form 只有 \(formFrame.height) pt")
        // 2. results keeps a usable floor and does not overflow the sheet.
        XCTAssertGreaterThanOrEqual(resultsFrame.height, 140,
                                    "results 只有 \(resultsFrame.height) pt")
        XCTAssertLessThanOrEqual(resultsFrame.maxY, sheet.host.bounds.maxY)
        // 3. order: form → results → footer.
        XCTAssertGreaterThan(resultsFrame.minY, formFrame.maxY, "results 必须排在 form 下面")
        XCTAssertLessThan(resultsFrame.maxY, footerFrame.maxY)
        // 4. the empty prompt is on the footer's row and outside any scroll view.
        XCTAssertEqual(resultsProbe.rowCount, 0)
        XCTAssertEqual(status.midY, footerFrame.midY, accuracy: 2,
                       "空态文案必须和按钮同一行")
        let scrollsInResults = descendants(of: sheet.host)
            .compactMap { $0 as? NSScrollView }
            .filter { scroll in
                scroll.convert(scroll.bounds, to: sheet.host)
                    .intersects(resultsFrame.insetBy(dx: 1, dy: 1))
            }
        XCTAssertTrue(scrollsInResults.isEmpty,
                      "空态时 results 里不该有滚动视图")
        XCTAssertFalse(status.intersects(resultsFrame),
                       "「还没有导出…」 还在 results 里，没有挪到按钮那一行")
    }

    /// §A (the visible half): the row's menu is actually greyed out when the format cannot carry a
    /// gain map, and alive again on HEIC. (SwiftUI's checkbox has no `NSButton` leaf inside a `Form`
    /// — it draws into a `_NSGraphicsView` — so the row's `Menu`, which is a real control, carries the
    /// enabled-state assertion; the model test above pins the checkbox's own value.)
    func testTheHDRMenuIsGreyedOutForNonHEICFormats() throws {
        let sheet = model()
        let hosted = try host(height: 760, model: sheet)

        func rowRect() throws -> NSRect { try frame(of: .hdrRow, in: hosted.host) }
        func menu() throws -> NSButton {
            let row = try rowRect()
            let match = descendants(of: hosted.host).compactMap { $0 as? NSButton }
                .first { !$0.title.isEmpty
                    && $0.convert($0.bounds, to: hosted.host).intersects(row) }
            return try XCTUnwrap(match, "the gain-map menu is not in the HDR row")
        }

        let heicRow = try rowRect()
        XCTAssertGreaterThan(heicRow.height, 0, "the HDR row is in the sheet")
        XCTAssertTrue(try menu().isEnabled, "HEIC is the one format that supports HDR")
        XCTAssertEqual(try menu().title, "ISO RGB")

        sheet.selectFormat(.jpeg)
        pump(hosted.host)
        XCTAssertEqual(try rowRect().height, heicRow.height, accuracy: 0.5,
                       "the row stays put, it just greys out")
        XCTAssertFalse(try menu().isEnabled, "the row must be greyed before the user can hit 导出")

        sheet.selectFormat(.heic)
        pump(hosted.host)
        XCTAssertTrue(try menu().isEnabled, "the remembered choice came back with HEIC")
    }

    // MARK: - hosting helpers

    private struct Hosted {
        let host: NSHostingView<ExportSheetView>
        let window: NSWindow
    }

    private func host(height: CGFloat) throws -> Hosted {
        try host(height: height, model: model())
    }

    private func host(height: CGFloat, model sheet: ExportSheetModel) throws -> Hosted {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ExportSheetView(model: sheet))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        return Hosted(host: host, window: window)
    }

    private func pump(_ host: NSHostingView<ExportSheetView>) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
    }

    private func descendants(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        for sub in root.subviews {
            found.append(sub)
            found += descendants(of: sub)
        }
        return found
    }

    private func probe(of kind: ExportLayoutProbe.Kind,
                       in host: NSView) throws -> ExportLayoutProbe {
        let match = descendants(of: host)
            .compactMap { $0 as? ExportLayoutProbe }
            .first { $0.kind == kind }
        return try XCTUnwrap(match, "no \(kind.rawValue) probe in the hosted sheet")
    }

    private func frame(of kind: ExportLayoutProbe.Kind, in host: NSView) throws -> NSRect {
        let probe = try probe(of: kind, in: host)
        return probe.convert(probe.bounds, to: host)
    }
}
