import XCTest
import AppKit
import SwiftUI
@testable import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 335 — 导出面板「去掉独立读数列」的量尺与门。
///
/// 用户口径（2026-11-10）：
/// > 导出界面，"PPI"三个字母没有向右对齐，右侧"像素/英寸"放置在主列中。储存路径，"更改路径"
/// > 的点击框只显示"更改…"，改成"更改"，并且放置在主列中。不透明度和质量的滑块左对齐，然后
/// > 百分数右对齐。这样右侧就没有额外列了，主列的宽度对齐到右侧去。
///
/// 可判定形式（全部走真呈现路径 `ExportSheetController.present(in:)`）：
///
///   1. 标签右沿 130、主列 138…540、读数右沿 540 —— **只有这两条列线**，旧的 424 不再出现；
///   2. PPI：标签右沿 130；输入框 138、宽 46（不变）；单位「像素/英寸」紧跟其后、
///      与输入框同一 midY；
///   3. 「存到」行：按钮文案逐字节「更改」（无 `…`）、左沿 138、宽 = 文字宽 + 原按钮内边距；
///   4. 不透明度 / 质量：滑杆左沿 138、右沿 = 百分数左沿 − 8、百分数（`%`）右沿 540；
///   5. 行 pitch 仍 32、首屏 band ≤ 10。
@MainActor
final class ExportSheetLayout335Tests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        for window in windows {
            window.makeFirstResponder(nil)
            if let parent = window.sheetParent { parent.endSheet(window) } else { window.orderOut(nil) }
            window.contentView = nil
        }
        windows = []
        for title in [ExportSheetView.colourSection, ExportSheetView.hdrSection,
                      ExportSheetView.afterSection] {
            UserDefaults.standard.removeObject(forKey: "photons.export.section.\(title)")
        }
    }

    private func descendants(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        for sub in root.subviews {
            found.append(sub)
            found += descendants(of: sub)
        }
        return found
    }

    private func gridProbes(_ kind: ExportRowGridProbe.Kind, in root: NSView) -> [ExportRowGridProbe] {
        descendants(of: root).compactMap { $0 as? ExportRowGridProbe }.filter { $0.kind == kind }
    }

    private func sliderProbes(_ kind: ExportSliderRowProbe.Kind, rowID: String,
                              in root: NSView) -> ExportSliderRowProbe? {
        descendants(of: root).compactMap { $0 as? ExportSliderRowProbe }
            .first { $0.kind == kind && $0.rowID == rowID }
    }

    private func frame(of view: NSView, in root: NSView) -> NSRect {
        view.convert(view.bounds, to: root)
    }

    private func rect(_ kind: ExportRowGridProbe.Kind, _ rowID: String, in content: NSView) -> NSRect? {
        gridProbes(kind, in: content).first { $0.rowID == rowID }.map { frame(of: $0, in: content) }
    }

    private func sliderRect(_ kind: ExportSliderRowProbe.Kind, _ rowID: String,
                            in content: NSView) -> NSRect? {
        sliderProbes(kind, rowID: rowID, in: content).map { frame(of: $0, in: content) }
    }

    /// 真路径：与 文件 ▸ 导出… 同一个入口；三段靠 `UserDefaults` 的 section 键展开。
    private func presentSheet(sdr: Bool = false) throws -> (ExportSheetController, NSWindow, NSView) {
        NSApplication.shared.setActivationPolicy(.accessory)
        for title in [ExportSheetView.colourSection, ExportSheetView.hdrSection,
                      ExportSheetView.afterSection] {
            UserDefaults.standard.set(true, forKey: "photons.export.section.\(title)")
        }
        let parent = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                                      styleMask: [.titled, .closable, .resizable],
                                      backing: .buffered, defer: false)
        TestWindows.show(parent, key: true)
        windows.append(parent)

        let controller = ExportSheetController(session: CatalogSession(remembersRecentLibrary: false))
        controller.present(in: parent)
        let window = try XCTUnwrap(controller.sheetWindow, "present(in:) 没有开 sheet 窗口")
        windows.append(window)
        let content = try XCTUnwrap(window.contentView)

        // 最挤的一档：长边 2401（半尺寸增益图要裁到偶数边，说明最长）+ 写死 240 PPI。
        controller.model.selectSizingMode(.longEdge)
        controller.model.preset.longEdge = 2401
        controller.model.setPPI(240)
        controller.model.selectionNatives = [ImageSize(width: 4096, height: 2731)]
        controller.model.selectionContents = [ImageSize(width: 4096, height: 2731)]
        if sdr { controller.model.setHDR(false) }

        for _ in 0..<10 {
            window.layoutIfNeeded()
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        return (controller, window, content)
    }

    private func rows(in content: NSView) -> [ExportRowGridProbe] {
        gridProbes(.row, in: content).sorted { frame(of: $0, in: content).minY
                                            < frame(of: $1, in: content).minY }
    }

    private func f(_ value: CGFloat?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }

    private func sourceText() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/ExportSheet.swift"), encoding: .utf8)
    }

    // MARK: - 1. dump（改前 / 改后各跑一次）

    /// ① 每行一串 `(x, 宽, 右沿)`。
    func testDumpEveryRowBoxesAndTheThreeLines() throws {
        let (_, _, content) = try presentSheet()
        print("335 dump · 行 | 标签右沿 | 主列 x…右 | 读数块 x…右 | 值 x…右 | 单位 x…右"
              + " | 滑杆 x…右 | 数字框 x…右 | 按钮 x…右")
        for row in rows(in: content) {
            let id = row.rowID
            let label = rect(.label, id, in: content)
            let control = rect(.control, id, in: content)
            let readout = rect(.readout, id, in: content)
            let value = rect(.value, id, in: content)
            let unit = rect(.unit, id, in: content)
            let slider = sliderRect(.slider, id, in: content)
            let number = sliderRect(.number, id, in: content)
            let button = rect(.button, id, in: content)
            print("335 dump · \(id) | \(f(label?.maxX)) | \(f(control?.minX))…\(f(control?.maxX))"
                  + " | \(f(readout?.minX))…\(f(readout?.maxX))"
                  + " | \(f(value?.minX))…\(f(value?.maxX))"
                  + " | \(f(unit?.minX))…\(f(unit?.maxX))"
                  + " | \(f(slider?.minX))…\(f(slider?.maxX))"
                  + " | \(f(number?.minX))…\(f(number?.maxX))"
                  + " | \(f(button?.minX))…\(f(button?.maxX))")
        }
        let button = rect(.button, "export.location.directory.change", in: content)
        print("335 dump · 更改按钮 \(f(button?.minX))…\(f(button?.maxX))"
              + " 宽 \(f(button.map { $0.width })) 高 \(f(button.map { $0.height }))")
        let ppiNumber = sliderRect(.number, "export.ppi", in: content)
        let ppiUnit = sliderRect(.unit, "export.ppi", in: content)
        print("335 dump · PPI 输入 \(f(ppiNumber?.minX))…\(f(ppiNumber?.maxX))"
              + " 宽 \(f(ppiNumber.map { $0.width })) midY \(f(ppiNumber?.midY))"
              + " · 单位 \(f(ppiUnit?.minX))…\(f(ppiUnit?.maxX)) midY \(f(ppiUnit?.midY))")
        for id in ["export.quality", "export.watermark.opacity"] {
            let slider = sliderRect(.slider, id, in: content)
            let number = sliderRect(.number, id, in: content)
            let unit = sliderRect(.unit, id, in: content)
            print("335 dump · \(id) 滑杆 \(f(slider?.minX))…\(f(slider?.maxX))"
                  + " 宽 \(f(slider.map { $0.width })) · 值 \(f(number?.minX))…\(f(number?.maxX))"
                  + " · % \(f(unit?.minX))…\(f(unit?.maxX))")
        }
        for probe in descendants(of: content).compactMap({ $0 as? ExportSliderRowProbe })
        .filter({ $0.kind == .toggle }) {
            let box = frame(of: probe, in: content)
            let text = gridProbes(.labelInk, in: content).first { $0.rowID == probe.rowID }
                .map { frame(of: $0, in: content) }
            print("335 toggle · \(probe.rowID) 点击框 \(f(box.minX))…\(f(box.maxX))"
                  + " · 文字 \(f(text?.minX))…\(f(text?.maxX))")
        }
    }

    // MARK: - 2. 两条列线，424 消失

    func testTwoGridLinesAndNo424() throws {
        let (_, _, content) = try presentSheet()

        let labels = gridProbes(.label, in: content).map { frame(of: $0, in: content) }
        let controls = gridProbes(.control, in: content).map { frame(of: $0, in: content) }
        XCTAssertGreaterThanOrEqual(labels.count, 13)
        XCTAssertGreaterThanOrEqual(controls.count, 13)

        for rect in labels {
            XCTAssertEqual(rect.maxX, 130, accuracy: 0.5, "335 · 标签右沿")
            XCTAssertEqual(rect.maxX, ExportRowGrid.labelRight, accuracy: 0.5)
        }
        for rect in controls {
            XCTAssertEqual(rect.minX, 138, accuracy: 0.5, "335 · 主列起点")
            XCTAssertEqual(rect.minX, ExportRowGrid.controlLeft, accuracy: 0.5)
            XCTAssertEqual(rect.width, 402, accuracy: 0.5, "335 · 主列宽 = 540 − 138")
            XCTAssertEqual(rect.maxX, 540, accuracy: 0.5, "335 · 主列右沿")
            XCTAssertNotEqual(rect.maxX, 424, accuracy: 0.5, "335 · 旧的 424 中间线还在")
        }

        // 读数只在主列内部：右沿 540（PPI 除外 —— 它的单位在主列左端）。
        for probe in gridProbes(.readout, in: content) where probe.rowID != "export.ppi" {
            XCTAssertEqual(frame(of: probe, in: content).maxX, 540, accuracy: 0.5,
                           "335 · \(probe.rowID) 读数右沿")
        }

        // 结构探针的任何一条边都不许落在 424（那条线必须彻底消失）。
        var edges: [(String, CGFloat)] = []
        for kind in [ExportRowGridProbe.Kind.label, .control, .readout, .value, .unit, .button] {
            for probe in gridProbes(kind, in: content) {
                let rect = frame(of: probe, in: content)
                if rect.width > 0.5 { edges.append(("\(kind.rawValue).minX/\(probe.rowID)", rect.minX)) }
                edges.append(("\(kind.rawValue).maxX/\(probe.rowID)", rect.maxX))
            }
        }
        for (name, x) in edges {
            XCTAssertNotEqual(x, 424, accuracy: 0.5, "335 · \(name) 落在旧的 424 线上（x=\(x)）")
        }
        print(String(format: "335 lines · label right %.1f · main %.1f…%.1f · readout right %.1f",
                     labels[0].maxX, controls[0].minX, controls[0].maxX,
                     frame(of: gridProbes(.readout, in: content)
                        .first { $0.rowID != "export.ppi" }!, in: content).maxX))
    }

    // MARK: - 2b. 标签对齐的是墨迹，不是文本框（335 补充口径）

    /// 用户的补充口径：
    /// > 「PPI」看起来不齐，是因为 `I` 的墨迹右边不贴 advance box 右边 —— 把文本框右沿对到 130，
    /// > 视觉上 `I` 右边还有一条缝。
    ///
    /// 所以这条门量的是**墨迹右沿**：文本的 advance 宽减去该字形的右侧 bearing（从 CoreText 取，
    /// 不用常量）。文本框右沿允许超过 130 —— 超出的正是这段 bearing。
    func testLabelInkRightEdgesSitOn130() throws {
        let (_, _, content) = try presentSheet()
        let inks = gridProbes(.labelInk, in: content)
        // 三段全展开 + HDR：19 条标签（含 3 个勾选框标签）。SDR 多一行「色调映射」。
        XCTAssertGreaterThanOrEqual(inks.count, 18, "每个标签都要报自己的文本框")

        /// 独立量一遍 bearing：测试这一侧不调用产线的 `labelInkInset`（否则就是自证）。
        func inkInset(_ text: String) -> CGFloat {
            let font = NSFont.systemFont(ofSize: ExportRowGrid.Font.label, weight: .medium)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: [.font: font]))
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            return advance - CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).maxX
        }

        var frameRight: [String: CGFloat] = [:]
        var inkRight: [String: CGFloat] = [:]
        for probe in inks {
            let rect = frame(of: probe, in: content)
            let inset = inkInset(probe.text)
            XCTAssertEqual(ExportRowGrid.labelInkInset(for: probe.text), inset, accuracy: 0.01,
                           "335 · 产线的 bearing 与 CoreText 的实测不一致（\(probe.text)）")
            frameRight[probe.text] = rect.maxX
            inkRight[probe.text] = rect.maxX - inset
            print(String(format: "335 ink · %@ · 框右 %.1f · 墨迹右 %.1f · bearing %.2f · 偏移 %.2f",
                         probe.text, rect.maxX, rect.maxX - inset, inset,
                         ExportRowGrid.labelInkShift(for: probe.text,
                                                     checkbox: probe.rowID.hasPrefix("export."))))
        }
        for (text, value) in inkRight {
            XCTAssertEqual(value, 130, accuracy: 0.5, "335 · 「\(text)」的墨迹右沿 \(value)")
        }

        // 以窄字形结尾的标签：文本框**必须**超出 130，超出的量就是这个字形的 bearing。
        for text in ["PPI", "不写入"] where frameRight[text] != nil {
            XCTAssertGreaterThan(frameRight[text]!, 130.5,
                                 "335 · 「\(text)」的文本框要超出 130（墨迹补偿）")
        }
        // 汉字结尾的标签：bearing 很小（0.6…1.6 pt），不能被这一改搞得「过头」。
        for text in ["质量", "水印不透明度", "存到", "命名"] where frameRight[text] != nil {
            XCTAssertLessThan(frameRight[text]! - 130, 2.0,
                              "335 · 「\(text)」的文本框被推出去超过 2 pt（bearing 量错了）")
            XCTAssertEqual(inkRight[text]!, 130, accuracy: 0.5, "335 · 「\(text)」的墨迹右沿")
        }

        // PPI 的三条对比：修前（322 的勾选框：文本框 126）/ 只对 frame（130）/ 修后（130 + bearing）
        if let frame = frameRight["PPI"], let ink = inkRight["PPI"] {
            let inset = inkInset("PPI")
            print(String(format: "335 PPI ink · 修前 322：框右 126.0 墨迹右 %.1f（差 %.1f）"
                         + " · 只对 frame：框右 130.0 墨迹右 %.1f · 修后 335：框右 %.1f 墨迹右 %.1f",
                         126.0 - inset, 126.0 - (126.0 - inset), 130.0 - inset, frame, ink))
            XCTAssertGreaterThan(ink, 129.5, "335 · PPI 的墨迹必须到 130（不是只把 frame 对上去）")
        }
    }

    // MARK: - 3. PPI：标签右对齐、单位进主列

    func testPPILabelIsRightAlignedAndTheUnitSitsInTheMainColumn() throws {
        let (_, _, content) = try presentSheet()

        let label = try XCTUnwrap(rect(.label, "export.ppi", in: content), "PPI 行没有标签探针")
        XCTAssertEqual(label.maxX, 130, accuracy: 0.5, "「PPI」三个字母的右沿")

        let number = try XCTUnwrap(sliderRect(.number, "export.ppi", in: content), "PPI 输入框")
        let unit = try XCTUnwrap(sliderRect(.unit, "export.ppi", in: content), "PPI 单位")
        print(String(format: "335 ppi · 输入 %.1f…%.1f (宽 %.1f) · 单位 %.1f…%.1f · midY 差 %.1f",
                     number.minX, number.maxX, number.width, unit.minX, unit.maxX,
                     abs(number.midY - unit.midY)))

        XCTAssertEqual(number.minX, 138, accuracy: 0.5, "输入框在主列起点")
        XCTAssertEqual(number.width, 46, accuracy: 0.5, "输入框宽度不变（288 的 46）")
        // 335 §2.3 —— 单位紧跟输入框，同一行、左对齐、固定间距 8。
        XCTAssertEqual(unit.minX, number.maxX + 8, accuracy: 0.5, "单位紧跟输入框")
        XCTAssertEqual(unit.minY, number.minY, accuracy: 0.5, "单位与输入框同一行")
        XCTAssertEqual(unit.midY, number.midY, accuracy: 0.5, "单位与输入框同一 midY")
        // 单位右沿不再贴 540：它跟着输入框走，读数列不存在了。
        XCTAssertLessThan(unit.maxX, 300, "单位在主列左端，不在右侧读数位")
        XCTAssertEqual(unit.width, ("像素/英寸" as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: ExportRowGrid.Font.unit)
        ]).width, accuracy: 1.0, "单位按自然宽（不再挤在 58 宽的列里）")
    }

    // MARK: - 4. 「更改」按钮

    func testTheChangeButtonSaysChangeWithoutEllipsisAndStartsInTheMainColumn() throws {
        let (_, _, content) = try presentSheet()
        let button = try XCTUnwrap(rect(.button, "export.location.directory.change", in: content),
                                   "更改按钮没有探针")
        let path = try XCTUnwrap(rect(.accessory, "export.location.directory.path", in: content),
                                 "路径没有探针")

        print(String(format: "335 button · x %.1f…%.1f 宽 %.1f 高 %.1f · 路径 %.1f…%.1f",
                     button.minX, button.maxX, button.width, button.height, path.minX, path.maxX))

        XCTAssertEqual(button.minX, 138, accuracy: 0.5, "按钮左沿在主列起点")
        XCTAssertEqual(path.minX, button.maxX + ExportRowGrid.readoutGap, accuracy: 0.5,
                       "路径紧跟按钮")
        XCTAssertLessThanOrEqual(path.maxX, 540 + 0.5, "路径不许越过面板右 padding")

        // 文案逐字节：源里是 `Button("更改")`，且这一行没有省略号。
        let text = try sourceText()
        XCTAssertTrue(text.contains("Button(\"更改\")"), "按钮文案必须是「更改」")
        XCTAssertFalse(text.contains("Button(\"更改…\")"), "335 · 按钮文案不许再带省略号")

        // 宽度 = 文字宽 + 原按钮内边距（= 改前「更改…」51.0 减去多出来的那个省略号）。
        // 小尺寸控件（`.controlSize(.small)`）的文字是 11 pt；改前按钮实测 51.0。
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let newText = ("更改" as NSString).size(withAttributes: [.font: font]).width
        let oldText = ("更改…" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertEqual(button.width, 51 - (oldText - newText), accuracy: 1.0,
                       "按钮宽度 = 文字宽 + 原内边距（51 是改前「更改…」的实测宽）")
    }

    // MARK: - 5. 滑块左对齐、百分数贴右沿

    func testBothSliderRowsStartAtTheMainColumnAndEndAtThePercent() throws {
        let (_, _, content) = try presentSheet()

        for rowID in ["export.quality", "export.watermark.opacity"] {
            let slider = try XCTUnwrap(sliderRect(.slider, rowID, in: content), "\(rowID) 没有滑杆")
            let number = try XCTUnwrap(sliderRect(.number, rowID, in: content), "\(rowID) 没有数值框")
            let unit = try XCTUnwrap(sliderRect(.unit, rowID, in: content), "\(rowID) 没有 % 单位")
            print(String(format: "335 slider · %@ · 滑杆 %.1f…%.1f (宽 %.1f) · 值 %.1f…%.1f · %% %.1f…%.1f",
                         rowID, slider.minX, slider.maxX, slider.width,
                         number.minX, number.maxX, unit.minX, unit.maxX))

            XCTAssertEqual(slider.minX, 138, accuracy: 0.5, "\(rowID) 滑杆左对齐在主列起点")
            XCTAssertGreaterThanOrEqual(slider.width, ExportRowGrid.sliderWidth, "滑杆不窄于 140")
            XCTAssertEqual(slider.maxX, number.minX - 8, accuracy: 0.5,
                           "\(rowID) 滑杆右沿 = 百分数左沿 − 8")
            XCTAssertEqual(number.minX, 540 - 8 - unit.width - number.width, accuracy: 0.5,
                           "\(rowID) 值在百分数左边 8 pt")
            XCTAssertEqual(unit.maxX, 540, accuracy: 0.5, "\(rowID) 百分数右沿 540")
            XCTAssertEqual(number.midY, slider.midY, accuracy: 1.0, "\(rowID) 同一行")
        }
    }

    // MARK: - 6. pitch 与首屏 band

    func testPitchIsStill32AndTheFirstScreenStaysUnderTenBands() throws {
        let (_, _, content) = try presentSheet()
        struct Band { let id: String; let rect: NSRect; let isHeader: Bool }
        let bands: [Band] = (gridProbes(.row, in: content).map {
            Band(id: $0.rowID, rect: frame(of: $0, in: content), isHeader: false)
        } + gridProbes(.header, in: content).map {
            Band(id: $0.rowID, rect: frame(of: $0, in: content), isHeader: true)
        }).sorted { $0.rect.minY < $1.rect.minY }

        var pitches: [CGFloat] = []
        for index in 1..<bands.count {
            let previous = bands[index - 1]
            let current = bands[index]
            let gap = current.rect.minY - previous.rect.maxY
            XCTAssertEqual(gap, current.isHeader ? ExportRowGrid.sectionSpacing
                                                 : ExportRowGrid.rowSpacing,
                           accuracy: 0.5, "335 · \(previous.id) → \(current.id) 的缝")
            guard !previous.isHeader, !current.isHeader else { continue }
            if previous.rect.height <= ExportRowGrid.rowHeight + 0.5 {
                pitches.append(current.rect.minY - previous.rect.minY)
            }
        }
        for pitch in pitches {
            XCTAssertEqual(pitch, ExportRowGrid.rowPitch, accuracy: 0.5, "335 · 行 pitch 32")
        }
        XCTAssertGreaterThanOrEqual(pitches.count, 15)
        print("335 pitch · \(pitches.count) 组 32 的 pitch · \(bands.count) band")

        // 默认折叠：6 个常驻行 + 3 个折叠标题 = 9 band ≤ 10。
        for title in [ExportSheetView.colourSection, ExportSheetView.hdrSection,
                      ExportSheetView.afterSection] {
            UserDefaults.standard.removeObject(forKey: "photons.export.section.\(title)")
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        let parent = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                                      styleMask: [.titled, .closable, .resizable],
                                      backing: .buffered, defer: false)
        TestWindows.show(parent, key: true)
        windows.append(parent)
        let controller = ExportSheetController(session: CatalogSession(remembersRecentLibrary: false))
        controller.present(in: parent)
        let window = try XCTUnwrap(controller.sheetWindow)
        windows.append(window)
        let defaultContent = try XCTUnwrap(window.contentView)
        for _ in 0..<8 {
            window.layoutIfNeeded()
            defaultContent.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        let resident = gridProbes(.row, in: defaultContent)
        let headers = gridProbes(.header, in: defaultContent)
        print("335 first screen · \(resident.count) 常驻行 + \(headers.count) 折叠标题 "
              + "= \(resident.count + headers.count) band")
        XCTAssertEqual(resident.count, 6, "常驻行仍是 6")
        XCTAssertEqual(headers.count, 3)
        XCTAssertLessThanOrEqual(resident.count + headers.count, 10, "首屏 band ≤ 10")
    }
}
