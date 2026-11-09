import XCTest
import AppKit
import SwiftUI
@testable import PhotonsExport
@testable import PhotonsUI

/// 302 — 导出面板改版 A：**三列**栅格（标签 / 控件 / 读数）、pitch 32、12 pt 控件。
///
/// 288 的五列（96 / 8 / 240 / 46 / 52 / 64）是列表的度量，46 / 52 / 64 三列在商业产品里没有
/// 对应物 —— 那是「重心不稳」的来源。302 把它收回表单，但 288 的**列对齐思想**原样保留：
/// 同一列不许漂。这里的六条断言逐条按新栅格重写，一条没删。
///
/// 读回手段仍是 `ExportRowGridProbe`（每一列一块透明背景）+ `ExportControlFontProbe`（字号），
/// 外加源码层守卫（SwiftUI 的 `Slider` 在 hosted `swift test` 里没有刻度 API 可读）。
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

    /// 302 —— 三段都展开的那份 hosted 视图：栅格断言要看**全部**行，不是首屏那 10 个 band。
    private var allExpanded: ExportSectionCollapseStore {
        ExportSectionCollapseStore.memory([
            ExportSheetView.colourSection: true,
            ExportSheetView.hdrSection: true,
            ExportSheetView.afterSection: true
        ])
    }

    private struct Hosted {
        let host: NSHostingView<ExportSheetView>
        let window: NSWindow
    }

    private func host(model sheet: ExportSheetModel,
                      expanded: Bool = true) throws -> Hosted {
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = ExportSheetView(model: sheet,
                                   sectionStore: expanded ? allExpanded
                                                          : ExportSectionCollapseStore.memory())
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0,
                            width: ExportRowGrid.panelWidth, height: ExportRowGrid.contentMaxHeight)
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

    private func frame(of view: NSView, in host: NSView) -> NSRect {
        view.convert(view.bounds, to: host)
    }

    /// 验收读的是：标签的**右**沿、控件的左沿、读数整块的**右**沿。
    private func edge(of probe: ExportRowGridProbe, in host: NSView) -> CGFloat {
        let rect = frame(of: probe, in: host)
        switch probe.kind {
        case .label, .value, .readout, .summary, .buttons:
            return rect.maxX
        default:
            return rect.minX
        }
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

    // MARK: - §3.1 one grid（288 五列 → 302 三列）

    /// 每一行都报同一套三列 x：标签右沿 118、控件左沿 138、读数右沿 540（面板右 padding）。
    /// 长边 / 百分比 / 原尺寸三种尺寸模式各自单独建一次视图，数值框仍落在同一根 x 上。
    func testEveryRowSharesTheThreeColumnGrid() throws {
        let sheet = model()
        let hosted = try host(model: sheet)
        let rows = gridProbes(in: hosted.host).filter { $0.kind == .row }
        XCTAssertGreaterThanOrEqual(rows.count, 13, "三段展开后至少要有 13 行走同一栅格")

        let kinds: [(ExportRowGridProbe.Kind, String, CGFloat)] = [
            (.label, "标签右沿", ExportRowGrid.labelRight),
            (.control, "控件左沿", ExportRowGrid.controlLeft),
            (.readout, "读数右沿", ExportRowGrid.readoutRight)
        ]
        for (kind, name, expected) in kinds {
            let probes = gridProbes(in: hosted.host).filter { $0.kind == kind }
            XCTAssertGreaterThanOrEqual(probes.count, rows.count,
                                        "\(name)：每行都要有占位探针")
            for probe in probes {
                let x = edge(of: probe, in: hosted.host)
                XCTAssertEqual(x, expected, accuracy: 0.5,
                               "302 · \(probe.rowID) 的 \(name) x=\(x)，应为 \(expected)")
            }
        }

        // 行高 24、同节内行距 8（pitch 32）—— 节与节之间是 48（32 + 16），没有第三种。
        for row in rows {
            XCTAssertEqual(frame(of: row, in: hosted.host).height,
                           ExportRowGrid.rowHeight, accuracy: 0.5,
                           "302 · \(row.rowID) 行高")
        }
        // 行带之间的缝只有 8（pitch 32）；折叠段标题之前是 16。没有第三种。
        let sorted = rows.map { frame(of: $0, in: hosted.host) }.sorted { $0.minY < $1.minY }
        var pitches: [CGFloat] = []
        for index in 1..<sorted.count {
            let gap = sorted[index].minY - sorted[index - 1].maxY
            let pitch = sorted[index].minY - sorted[index - 1].minY
            // 8 = 同一节；48 = 中间隔着一个 24 高的折叠标题（16 + 24 + 8）。
            XCTAssertTrue(abs(gap - ExportRowGrid.rowSpacing) <= 0.5
                          || abs(gap - (ExportRowGrid.sectionSpacing + ExportRowGrid.headerHeight
                                        + ExportRowGrid.rowSpacing)) <= 0.5,
                          "302 · 出现第三种行缝 \(gap)（只许 8 / 48）")
            if abs(gap - ExportRowGrid.rowSpacing) <= 0.5 { pitches.append(pitch) }
        }
        XCTAssertGreaterThanOrEqual(pitches.count, 12, "同节内至少要能量到 12 组 pitch")
        for pitch in pitches {
            XCTAssertEqual(pitch, ExportRowGrid.rowPitch, accuracy: 0.5, "行 pitch")
        }

        // 长边 / 百分比 / 原尺寸：三种模式各自成视图，数值框仍落在同一根 x。
        sheet.preset.sizingMode = .longEdge
        let longHosted = try host(model: sheet)
        try assertThreeColumns(in: longHosted.host)
        XCTAssertEqual(gridProbes(in: longHosted.host)
            .filter { $0.kind == .row && $0.rowID == "export.size.longEdge" }.count, 1,
                       "长边行必须走同一栅格")

        sheet.preset.sizingMode = .percent
        let percentHosted = try host(model: sheet)
        try assertThreeColumns(in: percentHosted.host)
        XCTAssertEqual(gridProbes(in: percentHosted.host)
            .filter { $0.kind == .row && $0.rowID == "export.size.percent" }.count, 1,
                       "长边百分比行必须走同一栅格")

        sheet.preset.sizingMode = .none
        let noneHosted = try host(model: sheet)
        try assertThreeColumns(in: noneHosted.host)
        XCTAssertEqual(gridProbes(in: noneHosted.host)
            .filter { $0.kind == .row && $0.rowID == "export.size.original" }.count, 1,
                       "原尺寸行必须走同一栅格")

        printAuditTable(in: hosted.host)
    }

    private func assertThreeColumns(in host: NSView) throws {
        let rows = gridProbes(in: host).filter { $0.kind == .row }
        XCTAssertGreaterThanOrEqual(rows.count, 13)
        let expected: [ExportRowGridProbe.Kind: CGFloat] = [.label: ExportRowGrid.labelRight,
                                                            .control: ExportRowGrid.controlLeft,
                                                            .readout: ExportRowGrid.readoutRight]
        for (kind, anchor) in expected {
            for probe in gridProbes(in: host).filter({ $0.kind == kind }) {
                XCTAssertEqual(edge(of: probe, in: host), anchor, accuracy: 0.5,
                               "302 · \(probe.rowID) 的 \(kind.rawValue) 列越界")
            }
        }
    }

    private func printAuditTable(in host: NSView) {
        let rows = gridProbes(in: host).filter { $0.kind == .row }
            .sorted { frame(of: $0, in: host).maxY > frame(of: $1, in: host).maxY }
        for row in rows {
            let values = [ExportRowGridProbe.Kind.label, .control, .readout]
                .map { kind -> String in
                    guard let probe = gridProbes(in: host).first(where: {
                        $0.kind == kind && $0.rowID == row.rowID
                    }) else { return "-" }
                    return String(format: "%.1f", edge(of: probe, in: host))
                }
            print("302 grid · \(row.rowID) · label \(values[0]) · control \(values[1])"
                  + " · readout \(values[2])")
        }
    }

    // MARK: - §3.4 section spacing（12 → 16）

    func testSectionHeadersSitSixteenPointsBelowThePreviousSection() throws {
        let sheet = model()
        let hosted = try host(model: sheet)
        let rowRects = gridProbes(in: hosted.host).filter { $0.kind == .row }
            .map { frame(of: $0, in: hosted.host) }
        let headerRects = gridProbes(in: hosted.host).filter { $0.kind == .header }
            .map { frame(of: $0, in: hosted.host) }
            .sorted { $0.maxY > $1.maxY }
        XCTAssertGreaterThanOrEqual(headerRects.count, 3, "三个折叠段的标题都要在")

        // 首屏的 7 个常驻行之后才是第一个标题；每个标题的上间距都是 16。
        for header in headerRects {
            let gaps = rowRects.filter { $0.maxY <= header.minY }
                .map { header.minY - $0.maxY }
                .filter { $0 >= 0 }
            guard let closest = gaps.min() else {
                XCTFail("302 · 找不到 section 头上方的行"); continue
            }
            print(String(format: "302 header · y %.1f · gap %.1f", header.minY, closest))
            XCTAssertEqual(closest, ExportRowGrid.sectionSpacing, accuracy: 0.5,
                           "302 · section 头上间距 \(closest)")
        }
    }

    // MARK: - §3.2 no ticks（保留）

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
        // 302：滑杆贴控件块右沿（388），宽度仍是 140。
        XCTAssertEqual(q.width, ExportRowGrid.sliderWidth, accuracy: 0.5)
        XCTAssertEqual(q.maxX, ExportRowGrid.controlRight, accuracy: 0.5,
                       "滑杆右沿必须落在控件块右沿")

        let text = try sourceText()
        XCTAssertEqual(ExportRowGrid.sliderTickMarks, 0, "质量 tick=0")
        XCTAssertEqual(ExportRowGrid.sliderTickMarks, 0, "不透明度 tick=0")
        XCTAssertFalse(text.contains(", step:"), "ExportSheet 里不许再给 Slider 传 step")
        XCTAssertFalse(text.contains("numberOfTickMarks"), "不手动画刻度")
        print(String(format: "302 ticks · quality 0 · opacity 0 · track x %.1f/%.1f width %.1f/%.1f",
                     q.minX, o.minX, q.width, o.width))
    }

    // MARK: - §3.3 percent readout（保留）

    func testQualityIsShownAsPercentAndWritesTheStoredFraction() throws {
        let sheet = model()
        let hosted = try host(model: sheet, expanded: false)

        let quality = try numberField("export.quality", in: hosted.host)
        XCTAssertEqual(quality.stringValue, "85", "默认 0.85 必须显示 85")
        XCTAssertTrue(descendants(of: hosted.host).compactMap { $0 as? ExportSliderRowProbe }
            .contains { $0.kind == .unit && $0.rowID == "export.quality" },
                      "质量带 % 单位")

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

    // MARK: - §3.7 fonts（10 → 12）

    func testEveryTextFieldAndPickerIsTwelvePoint() throws {
        let sheet = model()
        let hosted = try host(model: sheet)
        let probes = descendants(of: hosted.host).compactMap { $0 as? ExportControlFontProbe }
        XCTAssertGreaterThanOrEqual(probes.count, 12, "Text/Picker 的字体探针都要在")

        var byRow: [String: (ExportControlKind, CGFloat)] = [:]
        for probe in probes {
            XCTAssertEqual(probe.pointSize, ExportRowGrid.Font.control, accuracy: 1e-9,
                           "302 · \(probe.rowID) 的 \(probe.kind.rawValue) 字号")
            XCTAssertLessThanOrEqual(probe.pointSize, 12, "控件字号不得超过 12 pt")
            byRow[probe.rowID] = (probe.kind, probe.pointSize)
        }
        for (rowID, entry) in byRow.sorted(by: { $0.key < $1.key }) {
            print(String(format: "302 font · %@ · %@ %.0f pt", rowID, entry.0.rawValue, entry.1))
        }

        let numberFields = descendants(of: hosted.host).compactMap { $0 as? NumberTextField }
        XCTAssertGreaterThanOrEqual(numberFields.count, 3)
        for field in numberFields {
            XCTAssertEqual(field.font?.pointSize, 12,
                           "\(field.accessibilityIdentifier()) 必须 12 pt")
        }

        // 源码字号表：正文 12、提示 11、节标题 12，面板标题 13 是唯一的大字号。
        let text = try sourceText()
        let regex = try NSRegularExpression(pattern: "\\.font\\(\\.system\\(size: ([0-9.]+)")
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let sizeRange = Range(match.range(at: 1), in: text),
                  let size = Double(text[sizeRange]) else { continue }
            XCTAssertLessThanOrEqual(size, 12, "302 · 源码里出现 \(size) pt 控件字号")
        }
        XCTAssertEqual(ExportRowGrid.Font.control, 12)
        XCTAssertEqual(ExportRowGrid.Font.label, 12)
        XCTAssertEqual(ExportRowGrid.Font.value, 12)
        XCTAssertEqual(ExportRowGrid.Font.unit, 12)
        XCTAssertEqual(ExportRowGrid.Font.sectionHeader, 12)
        XCTAssertEqual(ExportRowGrid.Font.hint, 11)
        XCTAssertEqual(ExportRowGrid.Font.title, 13)
        XCTAssertTrue(text.contains("ExportRowGrid.Font.title"), "面板标题用唯一大字号常量")
    }

    // MARK: - §3.5 source guards（保留，一个 a11y id 都不许少）

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
        print("302 AX · " + axIDs.joined(separator: ", "))
    }
}
