import XCTest
import AppKit
import SwiftUI
@testable import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 322 — 导出面板「文字被截成 …」的逐行量尺与门。
///
/// 走 321 的真呈现路径（`ExportSheetController.present(in:)`），把三段全展开，然后对**每一行**
/// 的每一块文字给出 `(文本, 分配宽, 需要宽, 是否截)`：
///
///   · **分配宽**是布局真给出去的那个 frame（`ExportRowGridProbe` / `ExportSliderRowProbe` 的
///     读数，不是常量推算）；
///   · **需要宽**是同一字号同一字重下 CoreText 量出来的行宽（标签 12 medium、正文 12、说明 11）；
///   · 两行行按「需要宽 > 2 × 分配宽」才算截。
///
/// 文字本身从下面这张表来（每个 axID 一行），并且 `testTheTableStillMatchesTheSource` 用源码
/// 守一道：表里的每段文字仍能在 `ExportSheet.swift` 里找到，防止表和界面各说各话。
@MainActor
final class ExportSheetTruncationTests: XCTestCase {

    // MARK: - 表

    private enum Role: String {
        case label = "标签"
        case toggle = "勾选"
        case control = "控件"
        case hint = "说明"
        case value = "读数"
        case unit = "单位"
    }

    private struct Cell {
        var row: String
        var role: Role
        var text: String
        var font: NSFont
        var lines: Int = 1
        /// 勾选框的盒子（16）+ 间距（4）：`需要宽` 要把它们算进去。
        var lead: CGFloat = 0
        /// 探针的 axID（勾选框用的是自己的 id）。
        var probeID: String?
        /// 这段文字是不是 `ExportSheet.swift` 里的字面量（算出来的就跳过源码守卫）。
        var literal: Bool = true

        init(_ row: String, _ role: Role, _ text: String,
             size: CGFloat = 12, weight: NSFont.Weight = .regular,
             mono: Bool = false, lines: Int = 1, lead: CGFloat = 0, probeID: String? = nil,
             literal: Bool = true) {
            self.row = row
            self.role = role
            self.text = text
            self.font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                             : NSFont.systemFont(ofSize: size, weight: weight)
            self.lines = lines
            self.lead = lead
            self.probeID = probeID
            self.literal = literal
        }
    }

    /// 「长边 + HDR 增益图半尺寸裁到偶数边」那一档的状态：这是最挤的一屏，说明文字最长。
    ///
    /// 算出来的那两段（像素量、裁偶数边说明）直接问 model 要 —— 它们是格式化结果，
    /// 测试里手抄一份就是「表和界面各说各话」。
    private func state(model: ExportSheetModel) -> [Cell] {
        let megapixels = model.predictedMegapixelText ?? "—"
        let halfSizeHint = model.halfSizeCropHint ?? "增益图小一半；SDR 基底不缩放"
        return [
            // 常驻
            Cell("export.format", .label, "格式", weight: .medium),
            Cell("export.format", .control, "HEIC"),
            Cell("export.hdr.toneMapping", .label, "色调映射", weight: .medium),
            Cell("export.hdr.toneMapping", .control, "全局 / 无（硬截断）"),
            Cell("export.quality", .label, "质量", weight: .medium),
            Cell("export.quality", .unit, "％".replacingOccurrences(of: "％", with: "%")),
            Cell("export.size.longEdge", .label, "尺寸", weight: .medium),
            Cell("export.size.longEdge", .control, "原尺寸 / 长边 / 百分比"),
            Cell("export.size.longEdge", .hint, megapixels, size: 11, mono: true,
                 probeID: "export.size.megapixels", literal: false),
            Cell("export.size.longEdge", .toggle, "不扩大", weight: .medium, lead: 20,
                 probeID: "export.size.noUpscale"),
            Cell("export.size.longEdge", .unit, "px"),
            Cell("export.ppi", .toggle, "PPI", weight: .medium, lead: 20, probeID: "export.ppi.enabled"),
            Cell("export.ppi", .value, "不写入", size: 11, literal: false),
            Cell("export.ppi", .unit, "像素/英寸"),
            Cell("export.location.directory", .label, "存到", weight: .medium),
            Cell("export.location.directory", .hint,
                 "/Users/luyao/Pictures/Photons 导出", size: 11, mono: true,
                 probeID: "export.location.directory.path", literal: false),
            Cell("export.naming.template", .label, "命名", weight: .medium),
            Cell("export.naming.template", .control, "{原名}_{序号}", mono: true),
            // 颜色与元数据
            Cell("export.colorSpace", .label, "色彩空间", weight: .medium),
            Cell("export.colorSpace", .control, "sRGB / P3 / Rec2020"),
            Cell("export.bitDepth", .label, "位深", weight: .medium),
            Cell("export.bitDepth", .control, "8 位 / 16 位"),
            Cell("export.metadata.level", .label, "元数据", weight: .medium),
            Cell("export.metadata.level", .control, "仅版权"),
            Cell("export.metadata.xmp", .toggle, "写入 XMP", weight: .medium, lead: 20,
                 probeID: "export.metadata.xmp"),
            Cell("export.metadata.xmp", .hint, "由上面的档位决定，不能再单独开关", size: 11, lines: 2),
            Cell("export.metadata.location", .toggle, "移除位置", weight: .medium, lead: 20,
                 probeID: "export.metadata.location"),
            Cell("export.metadata.location", .hint, "GPS 不写入导出（EXIF 与 XMP 两处）", size: 11, lines: 2),
            // HDR 与色调映射
            Cell("export.hdr.kind", .label, "HDR 类型", weight: .medium),
            Cell("export.hdr.kind", .control, "SDR / 增益图 / HLG / PQ"),
            Cell("export.hdr.gainMap", .label, "增益图", weight: .medium),
            Cell("export.hdr.gainMap", .control, "RGB / 黑白  ISO / Apple"),
            Cell("export.hdr.halfSize", .toggle, "半尺寸", weight: .medium, lead: 20,
                 probeID: "export.hdr.halfSize"),
            Cell("export.hdr.halfSize", .hint, halfSizeHint, size: 11, lines: 2, literal: false),
            // 输出后
            Cell("export.location.subfolder", .label, "子文件夹", weight: .medium),
            Cell("export.location.subfolder", .control, "{date}/{camera}", mono: true),
            Cell("export.location.conflict", .label, "重名文件", weight: .medium),
            Cell("export.location.conflict", .control, "重命名"),
            Cell("export.watermark.text", .label, "水印文字", weight: .medium),
            Cell("export.watermark.text", .control, "关"),
            Cell("export.watermark.position", .label, "水印位置", weight: .medium),
            Cell("export.watermark.position", .control, "右下"),
            Cell("export.watermark.opacity", .label, "水印不透明度", weight: .medium),
            Cell("export.watermark.opacity", .unit, "%")
        ]
    }

    // MARK: - 窗口

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

    private func toggleProbe(_ axID: String, in root: NSView) -> ExportSliderRowProbe? {
        descendants(of: root).compactMap { $0 as? ExportSliderRowProbe }
            .first { $0.kind == .toggle && $0.rowID == axID }
    }

    private func frame(of view: NSView, in root: NSView) -> NSRect {
        view.convert(view.bounds, to: root)
    }

    /// 真路径：和 文件 ▸ 导出… 一样，`ExportSheetController.present(in:)` 开它自己的 sheet。
    /// 三段展开靠的是控制器读的那一对象（`UserDefaults` 的 `photons.export.section.*`），
    /// 不是测试自己搭的视图。
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

        let session = CatalogSession(remembersRecentLibrary: false)
        let controller = ExportSheetController(session: session)
        controller.present(in: parent)
        let window = try XCTUnwrap(controller.sheetWindow, "present(in:) 没有开 sheet 窗口")
        windows.append(window)
        let content = try XCTUnwrap(window.contentView)

        // 最挤的一档：长边 2401（输出 2401×1601，奇数边 → 半尺寸增益图要裁到偶数边，
        // 说明最长）+ 不写 PPI（读数位是「不写入」）。三件事同时成立时这一屏最挤。
        controller.model.selectSizingMode(.longEdge)
        controller.model.preset.longEdge = 2401
        controller.model.setPPI(nil)
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

    // MARK: - 量

    private struct Measured {
        let row: String
        let role: Role
        let text: String
        let allocated: CGFloat
        let needed: CGFloat
        let lines: Int
        var truncated: Bool { needed > allocated * CGFloat(lines) + 0.5 }
    }

    private func allocatedWidth(for cell: Cell, in content: NSView) -> CGFloat? {
        let probeID = cell.probeID ?? cell.row
        switch cell.role {
        case .label:
            if let toggle = toggleProbe(probeID, in: content) { return toggle.bounds.width }
            return gridProbes(.label, in: content).first { $0.rowID == cell.row }?.bounds.width
        case .toggle:
            return toggleProbe(probeID, in: content)?.bounds.width
        case .control:
            return gridProbes(.control, in: content).first { $0.rowID == cell.row }?.bounds.width
        case .hint:
            // 次级读数（像素量 / 路径）有自己的探针；整行说明就是控件块本身。
            if let inline = gridProbes(.accessory, in: content).first(where: { $0.rowID == probeID }) {
                return inline.bounds.width
            }
            return gridProbes(.control, in: content).first { $0.rowID == cell.row }?.bounds.width
        case .value:
            return gridProbes(.value, in: content).first { $0.rowID == cell.row }?.bounds.width
        case .unit:
            return gridProbes(.unit, in: content).first { $0.rowID == cell.row }?.bounds.width
        }
    }

    private func measure(_ cells: [Cell], in content: NSView) -> [Measured] {
        cells.compactMap { cell in
            guard let allocated = allocatedWidth(for: cell, in: content) else { return nil }
            let needed = (cell.text as NSString).size(withAttributes: [.font: cell.font]).width + cell.lead
            return Measured(row: cell.row, role: cell.role, text: cell.text,
                            allocated: allocated, needed: needed, lines: cell.lines)
        }
    }

    private func report(_ measured: [Measured], tag: String) {
        print("322 dump · \(tag) · \(measured.count) 段文字")
        print("322 dump · 行 | 角色 | 文本 | 分配宽 | 需要宽 | 行数 | 是否截")
        var truncated = 0
        for m in measured.sorted(by: { ($0.row, $0.role.rawValue) < ($1.row, $1.role.rawValue) }) {
            if m.truncated { truncated += 1 }
            print(String(format: "322 dump · %@ | %@ | %@ | %.1f | %.1f | %d | %@",
                         m.row, m.role.rawValue, m.text, m.allocated, m.needed, m.lines,
                         m.truncated ? "截" : "—"))
        }
        print("322 dump · \(tag) 截断段数 N = \(truncated)")
    }

    /// `NSHostingView` 是 flipped：y 向下长。按阅读顺序（上 → 下）排就是 minY 升序。
    private func rows(in content: NSView) -> [(id: String, rect: NSRect)] {
        gridProbes(.row, in: content)
            .map { ($0.rowID, frame(of: $0, in: content)) }
            .sorted { $0.1.minY < $1.1.minY }
    }

    // MARK: - 1. 修前 / 修后的同一张表

    func testEveryRowTextFitsOnOneLine() throws {
        let (hdrController, _, content) = try presentSheet()
        let hdr = measure(state(model: hdrController.model), in: content)
        report(hdr, tag: "HDR 增益图 / 长边 / 三段全展开")

        let (sdrController, _, sdrContent) = try presentSheet(sdr: true)
        let sdr = measure(state(model: sdrController.model), in: sdrContent)
            .filter { $0.row == "export.hdr.toneMapping" }
        report(sdr, tag: "SDR 色调映射行")

        let all = hdr + sdr
        let truncated = all.filter(\.truncated)
        print("322 dump · 合计 \(all.count) 段 · 截断 \(truncated.count)："
              + truncated.map { "\($0.row)/\($0.role.rawValue)/\($0.text)" }.joined(separator: " · "))

        XCTAssertGreaterThan(all.count, 40, "表要有 40 段以上，否则量得不全")
        XCTAssertEqual(truncated.count, 0, "322 · 仍有 \(truncated.count) 段文字被截")
    }

    // MARK: - 2. 列栅格（335：两条线，424 消失）

    func testTheThreeGridLinesMatch335() throws {
        let (_, _, content) = try presentSheet()
        let sheet = content.bounds

        let labels = gridProbes(.label, in: content).map { frame(of: $0, in: content) }
        let controls = gridProbes(.control, in: content).map { frame(of: $0, in: content) }
        let readouts = gridProbes(.readout, in: content).map { frame(of: $0, in: content) }
        XCTAssertGreaterThanOrEqual(labels.count, 13)
        XCTAssertGreaterThanOrEqual(controls.count, 13)
        XCTAssertGreaterThanOrEqual(readouts.count, 4)

        print(String(format: "335 grid · label right %.1f · main left %.1f · main right %.1f "
                     + "· readout right %.1f · panel right %.1f",
                     labels[0].maxX, controls[0].minX, controls[0].maxX,
                     readouts[0].maxX, sheet.maxX))

        // 302 的实测值：标签右沿 130（20 + 110）、主列左沿 138（130 + 8）、右沿 540（560 − 20）。
        for rect in labels {
            XCTAssertEqual(rect.maxX, 130, accuracy: 0.5, "335 · 标签右沿")
            XCTAssertEqual(rect.maxX, ExportRowGrid.labelRight, accuracy: 0.5)
        }
        for rect in controls {
            XCTAssertEqual(rect.minX, 138, accuracy: 0.5, "335 · 主列左沿")
            XCTAssertEqual(rect.minX, ExportRowGrid.controlLeft, accuracy: 0.5)
            // 335 —— 主列现在长到面板右 padding：424 那条中间线不存在。
            XCTAssertEqual(rect.maxX, 540, accuracy: 0.5, "335 · 主列右沿")
            XCTAssertNotEqual(rect.maxX, 424, accuracy: 0.5, "335 · 旧的 424 线还在")
        }
        for rect in readouts where rect.maxX > 400 {
            XCTAssertEqual(rect.maxX, 540, accuracy: 0.5, "335 · 读数右沿")
            XCTAssertEqual(rect.maxX, sheet.maxX - ExportRowGrid.horizontalPadding, accuracy: 0.5)
        }
    }

    // MARK: - 3. 行高 / pitch（两行行单独报）

    func testPitchStays32AndTheTwoLineRowReportsItsHeight() throws {
        let (controller, _, content) = try presentSheet()
        struct Band { let id: String; let rect: NSRect; let isHeader: Bool }
        let bands: [Band] = (gridProbes(.row, in: content).map {
            Band(id: $0.rowID, rect: frame(of: $0, in: content), isHeader: false)
        } + gridProbes(.header, in: content).map {
            Band(id: $0.rowID, rect: frame(of: $0, in: content), isHeader: true)
        }).sorted { $0.rect.minY < $1.rect.minY }

        print("322 pitch · " + bands.map {
            String(format: "%@[y %.1f h %.1f]", $0.id, $0.rect.minY, $0.rect.height)
        }.joined(separator: " "))

        var pitch32 = 0
        var taller: [String: (CGFloat, CGFloat)] = [:]
        for index in 1..<bands.count {
            let previous = bands[index - 1]
            let current = bands[index]
            let gap = current.rect.minY - previous.rect.maxY
            // 302 的两条缝：行与行 8，节标题前 8 + 16。
            XCTAssertEqual(gap, current.isHeader ? ExportRowGrid.sectionSpacing
                                                 : ExportRowGrid.rowSpacing,
                           accuracy: 0.5, "322 · \(previous.id) → \(current.id) 的缝")
            if !previous.isHeader, previous.rect.height > ExportRowGrid.rowHeight + 0.5 {
                taller[previous.id] = (previous.rect.height,
                                       current.rect.minY - previous.rect.minY)
            }
            guard !previous.isHeader, !current.isHeader else { continue }
            let pitch = current.rect.minY - previous.rect.minY
            XCTAssertEqual(pitch, previous.rect.height + ExportRowGrid.rowSpacing, accuracy: 0.5,
                           "322 · \(previous.id) → \(current.id) 的 pitch")
            if previous.rect.height <= ExportRowGrid.rowHeight + 0.5 {
                XCTAssertEqual(pitch, ExportRowGrid.rowPitch, accuracy: 0.5, "322 · 32 的 pitch")
                pitch32 += 1
            }
        }
        print(String(format: "322 pitch · 32 的 pitch %d 组 · 两行行 %@", pitch32,
                     taller.sorted { $0.key < $1.key }
                        .map { String(format: "%@ h %.1f 到下一 band %.1f", $0.key, $0.value.0, $0.value.1) }
                        .joined(separator: ", ")))
        XCTAssertGreaterThanOrEqual(pitch32, 15)
        // 335 —— 主列 286 → 402，那条本来要两行的「半尺寸」说明（需要 377.9 pt）现在一行放得下，
        // 所以两行行**可以是 0 个**：pitch 于是整表都是 32。若还有两行行，它只能是那一行。
        XCTAssertLessThanOrEqual(taller.count, 1, "最多只有半尺寸说明那一行是两行")
        if let row = taller["export.hdr.halfSize"] {
            XCTAssertGreaterThan(row.0, ExportRowGrid.rowHeight + 2, "两行行要比 24 高")
            XCTAssertLessThanOrEqual(row.0, 2 * ExportRowGrid.rowHeight, "两行行不超过两行")
        } else {
            let hint = measure(state(model: controller.model), in: content)
                .first { $0.row == "export.hdr.halfSize" && $0.role == .hint }
            print(String(format: "335 pitch · 半尺寸说明一行放得下：需要 %.1f ≤ 主列 %.1f",
                         hint?.needed ?? -1, hint?.allocated ?? -1))
            XCTAssertNotNil(hint)
            XCTAssertGreaterThanOrEqual(hint?.allocated ?? 0, hint?.needed ?? .infinity,
                                        "没有两行行就必须是一行放得下（不是被截）")
        }
    }

    // MARK: - 4. 水印不透明度在水印段里 / 首屏 6 + 3

    func testTheWatermarkSectionCarriesTextPositionAndOpacity() throws {
        let (_, _, content) = try presentSheet()
        let after = ExportSheetView.afterSection
        let watermarkText = rows(in: content).first { $0.id == "export.watermark.text" }
        let position = rows(in: content).first { $0.id == "export.watermark.position" }
        let opacity = rows(in: content).first { $0.id == "export.watermark.opacity" }

        let text = try XCTUnwrap(watermarkText, "水印文字行")
        let pos = try XCTUnwrap(position, "水印位置行")
        let opa = try XCTUnwrap(opacity, "水印不透明度行")
        let order = [text, pos, opa]
        print("322 watermark · " + order.map {
            String(format: "%@ y %.1f", $0.id, $0.rect.minY)
        }.joined(separator: " → "))
        // 顺序：文字 → 位置 → 不透明度（flipped 坐标，y 向下长），三行是 32 的节奏。
        XCTAssertEqual(pos.rect.minY - text.rect.minY, ExportRowGrid.rowPitch, accuracy: 0.5,
                       "水印位置必须紧跟水印文字")
        XCTAssertEqual(opa.rect.minY - pos.rect.minY, ExportRowGrid.rowPitch, accuracy: 0.5,
                       "水印不透明度必须紧跟水印位置")

        // 不透明度行在「输出后」段里：它在段落标题下面（NSView 坐标，标题的 maxY 更大）。
        let header = try XCTUnwrap(gridProbes(.header, in: content).first { $0.rowID == after },
                                   "「\(after)」段标题")
        let headerRect = frame(of: header, in: content)
        XCTAssertGreaterThan(opa.rect.minY, headerRect.minY, "水印不透明度必须在「\(after)」标题下面")
    }

    func testTheFirstScreenShowsSixResidentRowsAndTenBandsAtMost() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        for title in [ExportSheetView.colourSection, ExportSheetView.hdrSection,
                      ExportSheetView.afterSection] {
            UserDefaults.standard.removeObject(forKey: "photons.export.section.\(title)")
        }
        let parent = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        TestWindows.show(parent, key: true)
        windows.append(parent)
        let controller = ExportSheetController(session: CatalogSession(remembersRecentLibrary: false))
        controller.present(in: parent)
        let window = try XCTUnwrap(controller.sheetWindow)
        windows.append(window)
        let content = try XCTUnwrap(window.contentView)
        for _ in 0..<8 {
            window.layoutIfNeeded()
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()

        let resident = gridProbes(.row, in: content).map(\.rowID)
        let headers = gridProbes(.header, in: content).map(\.rowID)
        print("322 first screen · \(resident.count) 常驻行 + \(headers.count) 折叠标题 "
              + "= \(resident.count + headers.count) band · " + resident.joined(separator: ","))

        XCTAssertEqual(resident.count, 6, "常驻行 = 6（水印不透明度已进水印段）")
        XCTAssertEqual(headers.count, 3)
        XCTAssertLessThanOrEqual(resident.count + headers.count, 10)
        XCTAssertFalse(resident.contains("export.watermark.opacity"), "不透明度不再是常驻行")
    }

    // MARK: - 5. 表 ↔ 源码

    func testTheTableStillMatchesTheSource() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/ExportSheet.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        var checked = 0
        for cell in state(model: ExportSheetModel()) where cell.literal {
            guard cell.role == .label || cell.role == .toggle || cell.role == .hint else { continue }
            // 分段/下拉的合并写法逐项拆开验。
            let parts = cell.text
                .components(separatedBy: " / ")
                .flatMap { $0.components(separatedBy: "  ") }
                .filter { $0.count > 1 }
            for part in parts {
                XCTAssertTrue(text.contains(part),
                              "322 · 表里的「\(part)」在 ExportSheet.swift 里找不到（表与界面脱节）")
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 20, "源码守卫要真的验到 20 段以上")

        // 表里说「说明允许两行」，源码里就得真有 lineLimit(2) —— 否则表比界面宽松。
        let twoLines = text.components(separatedBy: ".lineLimit(2)").count - 1
        XCTAssertGreaterThanOrEqual(twoLines, 3, "说明类文字必须允许两行（现在 \(twoLines) 处）")
    }
}