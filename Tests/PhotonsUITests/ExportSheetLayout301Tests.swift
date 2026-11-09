import XCTest
import AppKit
import SwiftUI
@testable import PhotonsExport
@testable import PhotonsUI

/// 301 — 「美观」的可判定形式。
///
/// 用户在 302 里要的是「同种类型控件的位置相对一致、排列均匀、重心稳」。这三件事不靠肉眼，落在
/// 六条读数上：
///
///   1. 所有标签一条右沿（118）
///   2. 所有控件一条左沿（138）—— 顺带一条右沿（388）
///   3. 所有读数一条右沿（540 = 面板右 padding）
///   4. 行距只有两种：32（行与行）/ 48（节首行，32 + 16）—— 没有第三种
///   5. 默认折叠状态下首屏 ≤ 10 个 band（7 个常驻决定 + 3 个折叠标题）
///   6. 摘要行与按钮同一条水平带（中心差 ≤ 1），左右 padding 相等
///
/// 读回手段与 288 相同：`ExportRowGridProbe` 的透明背景 + hosted `NSHostingView`。
@MainActor
final class ExportSheetLayout301Tests: XCTestCase {

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
            .appendingPathComponent("photons-export-301-\(UUID().uuidString)", isDirectory: true)
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

    private func host(model sheet: ExportSheetModel, expanded: Bool) throws -> Hosted {
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

    private func gridProbes(_ kind: ExportRowGridProbe.Kind, in host: NSView) -> [ExportRowGridProbe] {
        descendants(of: host).compactMap { $0 as? ExportRowGridProbe }.filter { $0.kind == kind }
    }

    private func frame(of view: NSView, in host: NSView) -> NSRect {
        view.convert(view.bounds, to: host)
    }

    // MARK: - 1. 一条标签右沿

    func testAllLabelsShareOneRightEdge() throws {
        let hosted = try host(model: model(), expanded: true)
        let labels = gridProbes(.label, in: hosted.host)
        XCTAssertGreaterThanOrEqual(labels.count, 13, "三段展开后每行都要有标签列")

        for probe in labels {
            let rect = frame(of: probe, in: hosted.host)
            XCTAssertEqual(rect.maxX, ExportRowGrid.labelRight, accuracy: 0.5,
                           "301 · \(probe.rowID) 标签右沿 \(rect.maxX)")
            XCTAssertEqual(rect.width, ExportRowGrid.labelWidth, accuracy: 0.5,
                           "301 · \(probe.rowID) 标签列宽 \(rect.width)")
        }
        print(String(format: "301 labels · %d 行 · 右沿 %.1f（应 %.1f）",
                     labels.count, frame(of: labels[0], in: hosted.host).maxX,
                     ExportRowGrid.labelRight))
    }

    // MARK: - 2. 一条控件左沿（和一条右沿）

    func testAllControlsShareOneLeftEdge() throws {
        let hosted = try host(model: model(), expanded: true)
        let controls = gridProbes(.control, in: hosted.host)
        XCTAssertGreaterThanOrEqual(controls.count, 13, "三段展开后每行都要有控件列")

        for probe in controls {
            let rect = frame(of: probe, in: hosted.host)
            XCTAssertEqual(rect.minX, ExportRowGrid.controlLeft, accuracy: 0.5,
                           "301 · \(probe.rowID) 控件左沿 \(rect.minX)")
            XCTAssertEqual(rect.width, ExportRowGrid.controlWidth, accuracy: 0.5,
                           "301 · \(probe.rowID) 控件列宽 \(rect.width)")
            // 控件块自己也有右沿：下拉框、文本框、滑杆的右端都在 388。
            XCTAssertEqual(rect.maxX, ExportRowGrid.controlRight, accuracy: 0.5,
                           "301 · \(probe.rowID) 控件右沿 \(rect.maxX)")
        }
        print(String(format: "301 controls · %d 行 · 左沿 %.1f · 右沿 %.1f",
                     controls.count, frame(of: controls[0], in: hosted.host).minX,
                     frame(of: controls[0], in: hosted.host).maxX))
    }

    // MARK: - 3. 一条读数右沿（= 面板右 padding）

    func testAllReadoutsShareOneRightEdge() throws {
        let hosted = try host(model: model(), expanded: true)
        let sheet = frame(of: hosted.host, in: hosted.host)
        XCTAssertEqual(sheet.width, ExportRowGrid.panelWidth, accuracy: 0.5)

        let readouts = gridProbes(.readout, in: hosted.host)
        XCTAssertGreaterThanOrEqual(readouts.count, 13, "每行都要有读数块")

        for probe in readouts {
            let rect = frame(of: probe, in: hosted.host)
            XCTAssertEqual(rect.maxX, ExportRowGrid.readoutRight, accuracy: 0.5,
                           "301 · \(probe.rowID) 读数右沿 \(rect.maxX)")
            XCTAssertEqual(rect.maxX, sheet.maxX - ExportRowGrid.horizontalPadding, accuracy: 0.5,
                           "301 · \(probe.rowID) 读数右沿必须等于面板右 padding")
            XCTAssertEqual(rect.width, ExportRowGrid.readoutWidth, accuracy: 0.5,
                           "301 · \(probe.rowID) 读数块宽 \(rect.width)")
        }

        // 读数块里的数值框与单位也各是一条线（288 的列对齐思想，块内继续成立）。
        let values = gridProbes(.value, in: hosted.host).map { frame(of: $0, in: hosted.host) }
        XCTAssertGreaterThanOrEqual(values.count, 13)
        for rect in values {
            XCTAssertEqual(rect.minX, ExportRowGrid.readoutLeft, accuracy: 0.5)
        }
        print(String(format: "301 readouts · %d 行 · 右沿 %.1f · 面板右 padding %.1f",
                     readouts.count, frame(of: readouts[0], in: hosted.host).maxX,
                     sheet.maxX - ExportRowGrid.horizontalPadding))
    }

    // MARK: - 4. 行距只有一种，节首额外 16

    /// 行带之间只有 8 的缝（pitch 32）。唯一的例外是折叠段标题之前：8 + 16 = 24。
    /// 标题自己 24 高，标题到首行仍是 8 —— 所以「节首行」比常规行多出的正是 16。
    func testRowsAreEvenlySpaced() throws {
        let hosted = try host(model: model(), expanded: true)

        struct Band {
            let id: String
            let rect: NSRect
            let isHeader: Bool
        }
        let bands: [Band] = (gridProbes(.row, in: hosted.host).map {
            Band(id: $0.rowID, rect: frame(of: $0, in: hosted.host), isHeader: false)
        } + gridProbes(.header, in: hosted.host).map {
            Band(id: $0.rowID, rect: frame(of: $0, in: hosted.host), isHeader: true)
        }).sorted { $0.rect.minY < $1.rect.minY }

        XCTAssertGreaterThanOrEqual(bands.filter { !$0.isHeader }.count, 13)
        XCTAssertEqual(bands.filter { $0.isHeader }.count, 3, "三个折叠段标题")

        var gaps: [CGFloat] = []
        var gapsBeforeHeader: [CGFloat] = []
        for index in 1..<bands.count {
            let previous = bands[index - 1]
            let current = bands[index]
            let gap = current.rect.minY - previous.rect.maxY
            gaps.append(gap)
            if current.isHeader { gapsBeforeHeader.append(gap) }
            print(String(format: "301 gap · %@ → %@ · %.1f", previous.id, current.id, gap))
        }

        for gap in gaps {
            XCTAssertTrue(abs(gap - ExportRowGrid.rowSpacing) <= 0.5
                          || abs(gap - ExportRowGrid.sectionSpacing) <= 0.5,
                          "301 · 出现第三种间距 \(gap)（只许 8 或 16）")
        }
        XCTAssertEqual(gapsBeforeHeader.count, 3)
        for gap in gapsBeforeHeader {
            XCTAssertEqual(gap, ExportRowGrid.sectionSpacing, accuracy: 0.5,
                           "节标题前的间距必须是 16")
        }

        // 行 pitch 32、标题 24、标题到首行 8、节标题左沿 20。
        for band in bands {
            XCTAssertEqual(band.rect.height,
                           band.isHeader ? ExportRowGrid.headerHeight : ExportRowGrid.rowHeight,
                           accuracy: 0.5, "301 · \(band.id) 行高")
        }
        for band in bands where band.isHeader {
            XCTAssertEqual(band.rect.minX, ExportRowGrid.horizontalPadding, accuracy: 0.5,
                           "节标题左沿与标签列左沿对齐")
        }
        let pitches = zip(bands, bands.dropFirst()).compactMap { first, second -> CGFloat? in
            guard !first.isHeader, !second.isHeader else { return nil }
            return second.rect.minY - first.rect.minY
        }
        XCTAssertGreaterThanOrEqual(pitches.count, 12, "同节内行 pitch 至少要量到 12 组")
        for pitch in pitches {
            XCTAssertEqual(pitch, ExportRowGrid.rowPitch, accuracy: 0.5, "行 pitch")
        }
        print(String(format: "301 pitch · %d band · 行 pitch 32 有 %d 组 · 节首额外 16 有 %d 处",
                     bands.count, pitches.count, gapsBeforeHeader.count))
    }

    // MARK: - 5. 首屏 ≤ 10 个 band

    /// 默认折叠状态：7 个常驻决定 + 3 个折叠标题 = 10。任何一段默认展开都会把它推过 10 ——
    /// 反向门就是把 HDR 段改成默认展开，这一条必须红。
    func testTheFirstScreenShowsAtMostTenRows() throws {
        let hosted = try host(model: model(), expanded: false)
        let rows = gridProbes(.row, in: hosted.host)
        let headers = gridProbes(.header, in: hosted.host)
        let bands = rows.count + headers.count

        print("302 first screen · \(rows.count) 行 + \(headers.count) 个折叠标题 = \(bands) band")
        print("302 first screen rows · " + rows.map(\.rowID).joined(separator: ", "))

        XCTAssertEqual(rows.count, 7, "首屏是 7 个常驻决定")
        XCTAssertEqual(headers.count, 3, "三个折叠段都在首屏（收起）")
        XCTAssertLessThanOrEqual(bands, 10, "首屏 band 数 \(bands) 超过 10")

        // 首屏的每一行都在面板高度之内（默认折叠时面板恰好装得下这 10 个 band）。
        let sheet = frame(of: hosted.host, in: hosted.host)
        for probe in rows + headers {
            let rect = frame(of: probe, in: hosted.host)
            XCTAssertGreaterThanOrEqual(rect.minY, sheet.minY)
            XCTAssertLessThanOrEqual(rect.maxY, sheet.maxY,
                                     "302 · \(probe.rowID) 跑到面板外面了")
        }
    }

    // MARK: - 6. 页脚一条带

    func testTheFooterAndTheButtonsShareOneBand() throws {
        let hosted = try host(model: model(), expanded: false)
        let sheet = frame(of: hosted.host, in: hosted.host)
        let summary = try XCTUnwrap(gridProbes(.summary, in: hosted.host).first,
                                    "没有摘要行探针")
        let buttons = try XCTUnwrap(gridProbes(.buttons, in: hosted.host).first,
                                    "没有按钮带探针")
        let summaryRect = frame(of: summary, in: hosted.host)
        let buttonsRect = frame(of: buttons, in: hosted.host)

        print(String(format: "302 footer · summary midY %.1f h %.1f · buttons midY %.1f h %.1f",
                     summaryRect.midY, summaryRect.height,
                     buttonsRect.midY, buttonsRect.height))

        XCTAssertLessThanOrEqual(abs(summaryRect.midY - buttonsRect.midY), 1.0,
                                 "摘要行与按钮必须在同一条水平带（中心差 ≤ 1 pt）")
        XCTAssertEqual(summaryRect.height, ExportRowGrid.footerHeight, accuracy: 0.5)
        XCTAssertEqual(buttonsRect.height, ExportRowGrid.buttonHeight, accuracy: 0.5)

        // 重心：左右 padding 相等 —— 摘要左边 = 面板左边 + 20，按钮右边 = 面板右边 − 20。
        XCTAssertEqual(summaryRect.minX - sheet.minX, ExportRowGrid.horizontalPadding, accuracy: 0.5,
                       "摘要左侧 padding")
        XCTAssertEqual(sheet.maxX - buttonsRect.maxX, ExportRowGrid.horizontalPadding, accuracy: 0.5,
                       "按钮右侧 padding")
        XCTAssertEqual(summaryRect.minX - sheet.minX, sheet.maxX - buttonsRect.maxX, accuracy: 0.5,
                       "左右 padding 必须相等")
    }
}
