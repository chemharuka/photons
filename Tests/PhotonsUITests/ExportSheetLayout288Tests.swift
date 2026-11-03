import XCTest
import AppKit
import SwiftUI
@testable import PhotonsExport
@testable import PhotonsUI

/// 288 — 导出面板统一行栅格：每行同一套列、滑杆光条化、读数统一百分比。
///
/// These tests read the hosted layout back through `ExportRowGridProbe` (one transparent background
/// per column) — the same honest-anchor trick 217/243 used — plus `ExportControlFontProbe` for the
/// font audit. They also pin the source-level rules that have no AppKit leaf under `swift test`
/// (SwiftUI draws its own text and its `Slider` has no tick-mark API we can read).
@MainActor
final class ExportSheetLayout288Tests: XCTestCase {

    final class MemoryDraftStore: ExportDraftPersistence.Store {
        var values: [String: Data] = [:]
        func exportDraftData(forKey key: String) -> Data? { values[key] }
        func setExportDraftData(_ data: Data?, forKey key: String) {
            if let data { values[key] = data } else { values.removeValue(forKey: key) }
        }
    }

    private var scratch: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-export-288-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
        }
        windows = []
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func model() -> ExportSheetModel {
        ExportSheetModel(presetStore: ExportPresetStore(directory: scratch),
                         draftStore: MemoryDraftStore())
    }

    private struct Hosted {
        let host: NSHostingView<ExportSheetView>
        let window: NSWindow
    }

    private func host(model sheet: ExportSheetModel) throws -> Hosted {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: ExportSheetView(model: sheet))
        host.frame = NSRect(x: 0, y: 0, width: 620, height: 900)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        return Hosted(host: host, window: window)
    }

    private func descendants(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        for sub in root.subviews {
            found.append(sub)
            found += descendants(of: sub)
        }
        return found
    }

    private func gridProbes(in host: NSView) -> [ExportRowGridProbe] {
        descendants(of: host).compactMap { $0 as? ExportRowGridProbe }
    }

    private func gridProbe(_ kind: ExportRowGridProbe.Kind, _ rowID: String,
                           in host: NSView) throws -> ExportRowGridProbe {
        let match = gridProbes(in: host).first { $0.kind == kind && $0.rowID == rowID }
        return try XCTUnwrap(match, "no \(kind.rawValue) grid probe for \(rowID)")
    }

    private func frame(of view: NSView, in host: NSView) -> NSRect {
        view.convert(view.bounds, to: host)
    }

    /// The acceptance reads the label's **right** edge and the other columns' left edges.
    private func edge(of probe: ExportRowGridProbe, in host: NSView) -> CGFloat {
        let rect = frame(of: probe, in: host)
        return probe.kind == .label ? rect.maxX : rect.minX
    }

    private func numberField(_ axID: String, in host: NSView) throws -> NumberTextField {
        let fields = descendants(of: host).compactMap { $0 as? NumberTextField }
        return try XCTUnwrap(fields.first { $0.accessibilityIdentifier() == axID },
                             "no NumberTextField for \(axID)")
    }

    private func type(_ text: String, into field: NumberTextField, in hosted: Hosted) throws {
        XCTAssertTrue(hosted.window.makeFirstResponder(field), "字段必须能成为第一响应者")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "字段没有 field editor")
        editor.insertText(text, replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        hosted.host.layoutSubtreeIfNeeded()
    }

    private func sourceText() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/ExportSheet.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    // MARK: - §3.1 one grid

    /// Every row on the sheet — five numeric rows plus every picker/text row — reports the same five
    /// column x values. The numeric rows are checked in the three hosts that build them (default,
    /// 长边, 长边百分比), because 长边 and 百分比 are mutually exclusive.
    func testEveryRowSharesTheFiveColumnGrid() throws {
        let sheet = model()
        let defaultHosted = try host(model: sheet)
        let rows = gridProbes(in: defaultHosted.host).filter { $0.kind == .row }
        XCTAssertGreaterThanOrEqual(rows.count, 13, "面板至少要有 13 行走同一栅格")

        let kinds: [(ExportRowGridProbe.Kind, String)] = [
            (.label, "label-右缘"), (.control, "control-左缘"), (.value, "value-左缘"),
            (.unit, "unit-左缘"), (.accessory, "accessory-左缘")
        ]
        var baselines: [ExportRowGridProbe.Kind: CGFloat] = [:]
        for (kind, name) in kinds {
            let probes = gridProbes(in: defaultHosted.host).filter { $0.kind == kind }
            XCTAssertGreaterThanOrEqual(probes.count, rows.count,
                                        "\(name)：每行都要有占位探针")
            guard let first = probes.first else { XCTFail("\(name)：没有探针"); continue }
            let baseline = edge(of: first, in: defaultHosted.host)
            baselines[kind] = baseline
            for probe in probes {
                let x = edge(of: probe, in: defaultHosted.host)
                XCTAssertEqual(x, baseline, accuracy: 0.5,
                               "288 · \(probe.rowID) 的 \(name) x=\(x)，首行 \(baseline)")
            }
        }

        // Row height and within-section spacing.
        let frames = rows.map { frame(of: $0, in: defaultHosted.host) }
        for row in rows {
            XCTAssertEqual(frame(of: row, in: defaultHosted.host).height,
                           ExportRowGrid.rowHeight, accuracy: 0.5,
                           "288 · \(row.rowID) 行高")
        }
        let sorted = frames.sorted { $0.maxY > $1.maxY }
        var gaps: [CGFloat] = []
        for index in 1..<sorted.count {
            let gap = sorted[index - 1].minY - sorted[index].maxY
            if gap >= 0 && gap < 15 { gaps.append(gap) }
        }
        XCTAssertGreaterThanOrEqual(gaps.count, 12, "同 section 的相邻行至少要能量到 12 组")
        for gap in gaps {
            XCTAssertEqual(gap, ExportRowGrid.rowSpacing, accuracy: 0.5, "288 · 行距 \(gap)")
        }

        // 长边 / 长边百分比 rows live in their own hosts; their columns must match the same grid.
        sheet.preset.sizingMode = .longEdge
        let longHosted = try host(model: sheet)
        try assertGridColumns(in: longHosted.host, expected: baselines)
        let longRow = gridProbes(in: longHosted.host).filter {
            $0.kind == .row && $0.rowID == "export.size.longEdge"
        }
        XCTAssertEqual(longRow.count, 1, "长边行必须走同一栅格")

        sheet.preset.sizingMode = .percent
        let percentHosted = try host(model: sheet)
        try assertGridColumns(in: percentHosted.host, expected: baselines)
        let percentRow = gridProbes(in: percentHosted.host).filter {
            $0.kind == .row && $0.rowID == "export.size.percent"
        }
        XCTAssertEqual(percentRow.count, 1, "长边百分比行必须走同一栅格")

        printAuditTable(in: defaultHosted.host)
        printAuditTable(in: longHosted.host)
        printAuditTable(in: percentHosted.host)
    }

    private func assertGridColumns(in host: NSView,
                                   expected: [ExportRowGridProbe.Kind: CGFloat]) throws {
        let rows = gridProbes(in: host).filter { $0.kind == .row }
        XCTAssertGreaterThanOrEqual(rows.count, 13)
        for kind in [ExportRowGridProbe.Kind.label, .control, .value, .unit, .accessory] {
            guard let baseline = expected[kind] else { continue }
            for probe in gridProbes(in: host).filter({ $0.kind == kind }) {
                XCTAssertEqual(edge(of: probe, in: host), baseline, accuracy: 0.5,
                               "288 · \(probe.rowID) 的 \(kind.rawValue) 列越界")
            }
        }
    }

    private func printAuditTable(in host: NSView) {
        let rows = gridProbes(in: host).filter { $0.kind == .row }
            .sorted { frame(of: $0, in: host).maxY > frame(of: $1, in: host).maxY }
        for row in rows {
            let values = [ExportRowGridProbe.Kind.label, .control, .value, .unit, .accessory]
                .map { kind -> String in
                    guard let probe = gridProbes(in: host).first(where: {
                        $0.kind == kind && $0.rowID == row.rowID
                    }) else { return "-" }
                    return String(format: "%.1f", edge(of: probe, in: host))
                }
            print("288 grid · \(row.rowID) · label \(values[0]) · control \(values[1])"
                  + " · value \(values[2]) · unit \(values[3]) · accessory \(values[4])")
        }
    }

    // MARK: - §3.4 section header spacing

    func testSectionHeadersSitTwelvePointsBelowThePreviousSection() throws {
        let sheet = model()
        let hosted = try host(model: sheet)
        let rowRects = gridProbes(in: hosted.host).filter { $0.kind == .row }
            .map { frame(of: $0, in: hosted.host) }
        let headerRects = gridProbes(in: hosted.host).filter { $0.kind == .header }
            .map { frame(of: $0, in: hosted.host) }
            .sorted { $0.maxY > $1.maxY }
        XCTAssertGreaterThanOrEqual(headerRects.count, 7, "七个 section 头都要在")

        // The top-most header (位置, the first section) has no previous row; the six sections below
        // it are `header.minY - previousRow.maxY`.
        for header in headerRects.dropLast() {
            let gaps = rowRects.filter { $0.maxY <= header.minY }
                .map { header.minY - $0.maxY }
                .filter { $0 >= 0 }
            guard let closest = gaps.min() else {
                XCTFail("288 · 找不到 section 头上方的行"); continue
            }
            print(String(format: "288 header · y %.1f · gap %.1f", header.minY, closest))
            XCTAssertEqual(closest, ExportRowGrid.sectionHeaderTopSpacing, accuracy: 0.5,
                           "288 · section 头上间距 \(closest)")
        }
    }

    // MARK: - §3.2 no ticks

    func testSlidersAreContinuousAndShareTheSameTrack() throws {
        let sheet = model()
        let hosted = try host(model: sheet)
        let quality = try XCTUnwrap(descendants(of: hosted.host)
            .compactMap { $0 as? ExportSliderRowProbe }
            .first { $0.kind == .slider && $0.rowID == "export.quality" })
        let opacity = try XCTUnwrap(descendants(of: hosted.host)
            .compactMap { $0 as? ExportSliderRowProbe }
            .first { $0.kind == .slider && $0.rowID == "export.watermark.opacity" })
        let q = frame(of: quality, in: hosted.host)
        let o = frame(of: opacity, in: hosted.host)
        XCTAssertEqual(q.minX, o.minX, accuracy: 0.5, "两条轨道起点必须相同")
        XCTAssertEqual(q.width, o.width, accuracy: 0.5, "两条轨道终点必须相同")
        XCTAssertEqual(q.width, ExportRowGrid.sliderWidth, accuracy: 0.5)

        let text = try sourceText()
        XCTAssertEqual(ExportRowGrid.sliderTickMarks, 0, "质量 tick=0")
        XCTAssertEqual(ExportRowGrid.sliderTickMarks, 0, "不透明度 tick=0")
        XCTAssertFalse(text.contains(", step:"), "ExportSheet 里不许再给 Slider 传 step")
        XCTAssertFalse(text.contains("numberOfTickMarks"), "不手动画刻度")
        print(String(format: "288 ticks · quality 0 · opacity 0 · track x %.1f/%.1f width %.1f/%.1f",
                     q.minX, o.minX, q.width, o.width))
    }

    // MARK: - §3.3 percent readout

    func testQualityIsShownAsPercentAndWritesTheStoredFraction() throws {
        let sheet = model()
        let hosted = try host(model: sheet)

        let quality = try numberField("export.quality", in: hosted.host)
        XCTAssertEqual(quality.stringValue, "85", "默认 0.85 必须显示 85")
        XCTAssertTrue(descendants(of: hosted.host).compactMap { $0 as? ExportSliderRowProbe }
            .contains { $0.kind == .unit && $0.rowID == "export.quality" },
                      "质量现在带 % 单位")

        try type("75", into: quality, in: hosted)
        XCTAssertEqual(sheet.preset.quality, 0.75, accuracy: 1e-12)

        try type("5", into: quality, in: hosted)
        XCTAssertEqual(sheet.preset.quality, 0.10, accuracy: 1e-12, "5% 钳到 10%")

        try type("200", into: quality, in: hosted)
        XCTAssertEqual(sheet.preset.quality, 1.0, accuracy: 1e-12, "200% 钳到 100%")

        let opacity = try numberField("export.watermark.opacity", in: hosted.host)
        XCTAssertEqual(opacity.stringValue, "60", "默认不透明度显示 60%")
        try type("73", into: opacity, in: hosted)
        XCTAssertEqual(sheet.preset.watermarkOpacity, 75, accuracy: 1e-12,
                       "不透明度写入按 5% 量化：73 → 75")
    }

    // MARK: - §3.7 fonts

    func testEveryTextFieldAndPickerIsTenPoint() throws {
        let sheet = model()
        let hosted = try host(model: sheet)
        let probes = descendants(of: hosted.host).compactMap { $0 as? ExportControlFontProbe }
        XCTAssertGreaterThanOrEqual(probes.count, 14, "Text/Picker 的字体探针都要在")

        var byRow: [String: (ExportControlKind, CGFloat)] = [:]
        for probe in probes {
            XCTAssertEqual(probe.pointSize, ExportRowGrid.Font.control, accuracy: 1e-9,
                           "288 · \(probe.rowID) 的 \(probe.kind.rawValue) 字号")
            XCTAssertLessThanOrEqual(probe.pointSize, 10, "控件字号不得超过 10 pt")
            byRow[probe.rowID] = (probe.kind, probe.pointSize)
        }
        for (rowID, entry) in byRow.sorted(by: { $0.key < $1.key }) {
            print(String(format: "288 font · %@ · %@ %.0f pt", rowID, entry.0.rawValue, entry.1))
        }

        let numberFields = descendants(of: hosted.host).compactMap { $0 as? NumberTextField }
        XCTAssertGreaterThanOrEqual(numberFields.count, 3)
        for field in numberFields {
            XCTAssertEqual(field.font?.pointSize, 10,
                           "\(field.accessibilityIdentifier()) 必须 10 pt")
        }

        // Source scale: no literal above 10, and the title is the one 13 pt token.
        let text = try sourceText()
        let regex = try NSRegularExpression(pattern: "\\.font\\(\\.system\\(size: ([0-9.]+)")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let sizeRange = Range(match.range(at: 1), in: text),
                  let size = Double(text[sizeRange]) else { continue }
            XCTAssertLessThanOrEqual(size, 10, "288 · 源码里出现 \(size) pt 控件字号")
        }
        XCTAssertEqual(ExportRowGrid.Font.control, 10)
        XCTAssertEqual(ExportRowGrid.Font.label, 10)
        XCTAssertEqual(ExportRowGrid.Font.sectionHeader, 10)
        XCTAssertEqual(ExportRowGrid.Font.hint, 9)
        XCTAssertEqual(ExportRowGrid.Font.title, 13)
        XCTAssertTrue(text.contains("ExportRowGrid.Font.title"), "面板标题用唯一大字号常量")
    }

    // MARK: - §3.5 source guards

    func testNoQualityTextAndEveryAccessibilityIdentifierSurvives() throws {
        let text = try sourceText()
        XCTAssertEqual(text.components(separatedBy: "qualityText").count - 1, 0)
        let axIDs = [
            "export.quality", "export.watermark.opacity", "export.watermark.text",
            "export.watermark.position", "export.ppi", "export.ppi.enabled",
            "export.size.longEdge", "export.size.percent", "export.size.noUpscale",
            "export.size.megapixels"
        ]
        for axID in axIDs {
            XCTAssertTrue(text.contains("\"\(axID)\""), "\(axID) 必须仍在控件上")
        }
        print("288 AX · " + axIDs.joined(separator: ", "))
    }
}
