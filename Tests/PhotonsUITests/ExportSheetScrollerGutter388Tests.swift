import XCTest
import AppKit
import SwiftUI
@testable import PhotonsCore
@testable import PhotonsExport
@testable import PhotonsUI

/// 388 — 导出面板右侧的滚动指示条不许压住内容。
///
/// 用户口径（2026-11-12）：
/// > 「导出界面右侧，界面拖动的指示条会与内容重叠，宽度加宽一些给指示条让出空间」
///
/// 修法（本单实际落地的形状）：面板 560 → 576，右侧多出 `scrollerGutter`(16) 的**留白**；
/// 内容右沿仍是 540（`contentRight` 改成字面量），所以读数与百分数一位都不移。
///
/// ⚠ 只把面板加宽是不够的 —— 实测过两次：
///
/// | 配置 | ScrollView 右沿 | 指示条 x | 内容右沿 | 净空 |
/// |---|---|---|---|---|
/// | 560 + 对称 padding | 540 | 523…540 | 540 | **0**（压在百分数上） |
/// | 576 + 右 padding 36 | 540 | 523…540 | 540 | **0**（指示条贴 ScrollView 右缘，不贴面板） |
/// | 576 + ScrollView 破出 + 内容缩进 | 552 | 555…572 | 540 | 15 |
///
/// 所以这里的核心断言读的是**真的 `NSScroller`**（SwiftUI 的 `ScrollView` 在 macOS 上就是
/// `NSScrollView`，overlay 指示条是它自己的 `NSScroller` 子视图），不是拿常量反推的几何。
/// 只靠 `contentRight + 15 < panelWidth` 这种断言在 560 宽下也成立 —— 那是假绿。
@MainActor
final class ExportSheetScrollerGutter388Tests: XCTestCase {

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

    // MARK: - 读取手段

    private func descendants(of root: NSView) -> [NSView] {
        var found: [NSView] = []
        for sub in root.subviews {
            found.append(sub)
            found += descendants(of: sub)
        }
        return found
    }

    private func frame(of view: NSView, in root: NSView) -> NSRect {
        view.convert(view.bounds, to: root)
    }

    private struct Presented {
        let controller: ExportSheetController
        let window: NSWindow
        let content: NSView
    }

    /// 真路径：与 文件 ▸ 导出… 同一个入口；三段全展开（`form` 才会长到要滚，才有指示条）。
    private func presentSheet() throws -> Presented {
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

        // 最挤的一档：长边 2401（半尺寸增益图要裁到偶数边）+ 写死 240 PPI。
        controller.model.selectSizingMode(.longEdge)
        controller.model.preset.longEdge = 2401
        controller.model.setPPI(240)
        controller.model.selectionNatives = [ImageSize(width: 4096, height: 2731)]
        controller.model.selectionContents = [ImageSize(width: 4096, height: 2731)]

        for _ in 0..<10 {
            window.layoutIfNeeded()
            content.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        window.layoutIfNeeded()
        content.layoutSubtreeIfNeeded()
        return Presented(controller: controller, window: window, content: content)
    }

    /// `form` 那个 `ScrollView` 背后的 `NSScrollView`：它是唯一一个和 form 探针相交的。
    private func formScrollView(in content: NSView) throws -> NSScrollView {
        let form = try XCTUnwrap(descendants(of: content).compactMap { $0 as? ExportLayoutProbe }
            .first { $0.kind == .form }, "form（ScrollView）探针不存在")
        let formRect = frame(of: form, in: content)
        let scrolls = descendants(of: content).compactMap { $0 as? NSScrollView }.filter { scroll in
            frame(of: scroll, in: content).intersects(formRect.insetBy(dx: 1, dy: 1))
        }
        return try XCTUnwrap(scrolls.first, "form 背后不是 NSScrollView")
    }

    /// overlay 指示条的矩形。`verticalScroller` 是 SwiftUI 建出来的那一个，它的 frame 就是
    /// 用户看到的指示条那一竖条 —— 不是我们拿常量算的。
    private func indicatorRect(in content: NSView) throws -> NSRect {
        let scroll = try formScrollView(in: content)
        let scroller = try XCTUnwrap(scroll.verticalScroller, "ScrollView 没有 verticalScroller")
        XCTAssertTrue(scroll.hasVerticalScroller, "这个用例需要真的能滚的表单（三段全展开）")
        XCTAssertFalse(scroller.isHidden, "指示条被藏了（388 要的是让空间，不是藏掉）")
        return frame(of: scroller, in: content)
    }

    private func readoutMaxX(_ rowID: String, in content: NSView) -> CGFloat? {
        descendants(of: content).compactMap { $0 as? ExportRowGridProbe }
            .first { $0.kind == .readout && $0.rowID == rowID }
            .map { frame(of: $0, in: content).maxX }
    }

    private func f(_ value: CGFloat?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "—"
    }

    // MARK: - ① 四个常量

    func testTheFourConstantsSayWhatTheFixClaims() {
        print(String(format: "388 ① · panelWidth %.1f · scrollerGutter %.1f · contentRight %.1f · contentWidth %.1f"
                     + " · trailingPadding %.1f · scrollerBleed %.1f · scrollerEdgeInset %.1f",
                     ExportRowGrid.panelWidth, ExportRowGrid.scrollerGutter,
                     ExportRowGrid.contentRight, ExportRowGrid.contentWidth,
                     ExportRowGrid.trailingPadding, ExportRowGrid.scrollerBleed,
                     ExportRowGrid.scrollerEdgeInset))

        XCTAssertEqual(ExportRowGrid.scrollerGutter, 16, "388 · 给指示条的留白")
        XCTAssertEqual(ExportRowGrid.panelWidth, 576, "388 · 560 的内容宽 + 16 的指示条留白")
        XCTAssertEqual(ExportRowGrid.contentRight, 540, "388 · 内容右沿不许跟着面板变宽")
        XCTAssertEqual(ExportRowGrid.contentWidth, 520, "388 · 内容宽仍是 520")

        // 三者的依赖关系：面板 = 内容宽 + 左 20 + 右 (20 + gutter)，且内容右沿 = 20 + 520。
        XCTAssertEqual(ExportRowGrid.panelWidth,
                       ExportRowGrid.contentWidth + ExportRowGrid.horizontalPadding
                       + ExportRowGrid.trailingPadding,
                       "388 · 面板宽 = 内容宽 + 左 padding + 右 padding(含 gutter)")
        XCTAssertEqual(ExportRowGrid.contentRight,
                       ExportRowGrid.horizontalPadding + ExportRowGrid.contentWidth, accuracy: 1e-9,
                       "388 · 540 = 左 padding 20 + 内容宽 520")
        XCTAssertEqual(ExportRowGrid.contentRight, 540, accuracy: 1e-9,
                       "388 · 内容右沿是字面量，不跟着 panelWidth 漂")
    }

    // MARK: - ② 既有锚点不动

    func testThe335AnchorsAreUntouched() throws {
        let sheet = try presentSheet()
        let labels = descendants(of: sheet.content).compactMap { $0 as? ExportRowGridProbe }
            .filter { $0.kind == .label }.map { frame(of: $0, in: sheet.content) }
        let controls = descendants(of: sheet.content).compactMap { $0 as? ExportRowGridProbe }
            .filter { $0.kind == .control }.map { frame(of: $0, in: sheet.content) }
        XCTAssertGreaterThanOrEqual(labels.count, 13)
        XCTAssertGreaterThanOrEqual(controls.count, 13)

        for rect in labels {
            XCTAssertEqual(rect.maxX, 130, accuracy: 0.5, "388 · 标签右沿仍是 130")
            XCTAssertEqual(rect.maxX, ExportRowGrid.labelRight, accuracy: 0.5)
        }
        for rect in controls {
            XCTAssertEqual(rect.minX, 138, accuracy: 0.5, "388 · 主列左沿仍是 138")
            XCTAssertEqual(rect.minX, ExportRowGrid.controlLeft, accuracy: 0.5)
            XCTAssertEqual(rect.maxX, 540, accuracy: 0.5, "388 · 主列右沿仍是 540")
        }
        print(String(format: "388 ② · labels %d 块 右沿 %.1f · controls %d 块 %.1f…%.1f",
                     labels.count, labels[0].maxX, controls.count,
                     controls[0].minX, controls[0].maxX))
    }

    // MARK: - ③ 指示条真的不压内容（读真 NSScroller）

    /// 这一条是本单的核心门，而且它**在错误的配置下必红**：
    ///
    /// - `scrollerGutter` 改回 0 → 面板 560、ScrollView 停在 540、指示条回到 523…540 → 净空 0 → 红；
    /// - 只加 padding 不破出 → ScrollView 仍停在 540 → 指示条 523…540 → 净空 0 → 红。
    func testTheIndicatorHasRealClearanceFromTheContentRightEdge() throws {
        let sheet = try presentSheet()
        let indicator = try indicatorRect(in: sheet.content)
        let contentRight = ExportRowGrid.contentRight
        let scroll = try formScrollView(in: sheet.content)
        let scrollRect = frame(of: scroll, in: sheet.content)

        let clearance = indicator.minX - contentRight
        print(String(format: "388 ③ · 指示条 %.1f…%.1f · 内容右沿 %.1f · 净空 %.1f"
                     + " · ScrollView 右沿 %.1f · 面板宽 %.1f",
                     indicator.minX, indicator.maxX, contentRight, clearance,
                     scrollRect.maxX, ExportRowGrid.panelWidth))
        print(String(format: "388 ③ · 判据 contentRight + 15 < panelWidth → %.1f + 15 = %.1f < %.1f",
                     contentRight, contentRight + 15, ExportRowGrid.panelWidth))

        // 指示条整条落在内容右沿之外，且净空够一条指示条的宽度（实测 17）。
        XCTAssertGreaterThanOrEqual(clearance, 15,
                                    "388 · 指示条左沿 \(indicator.minX) 离内容右沿 \(contentRight) 只有 \(clearance) pt")
        XCTAssertGreaterThan(indicator.minX, contentRight,
                             "388 · 指示条压在内容上（左沿 \(indicator.minX) ≤ 内容右沿 \(contentRight)）")
        // 指示条自己得在面板里（不然是被裁掉一半）。
        XCTAssertLessThanOrEqual(indicator.maxX, ExportRowGrid.panelWidth + 0.5,
                                 "388 · 指示条右沿 \(indicator.maxX) 出了面板 \(ExportRowGrid.panelWidth)")

        // 规格 §3.1 ③ 的那条几何判据也留着（它是必要条件，不是充分条件 —— 见类注释）。
        XCTAssertLessThan(contentRight + 15, ExportRowGrid.panelWidth,
                          "388 · 内容右沿 + 指示条宽 15 必须小于面板宽")
    }

    // MARK: - ④ 滑杆读数不被压

    func testEverySliderReadoutKeepsTheGutterToItsRight() throws {
        let sheet = try presentSheet()
        let indicator = try indicatorRect(in: sheet.content)

        for rowID in ["export.quality", "export.watermark.opacity", "export.size.longEdge"] {
            let maxX = try XCTUnwrap(readoutMaxX(rowID, in: sheet.content), "\(rowID) 没有读数探针")
            print(String(format: "388 ④ · %@ 读数 maxX %.1f · 指示条左沿 %.1f · 净空 %.1f"
                         + " · panelWidth − maxX %.1f",
                         rowID, maxX, indicator.minX, indicator.minX - maxX,
                         ExportRowGrid.panelWidth - maxX))

            XCTAssertLessThanOrEqual(maxX, 540 + 0.5, "335 · \(rowID) 读数右沿 540")
            XCTAssertGreaterThanOrEqual(ExportRowGrid.panelWidth - maxX, 15 + 1,
                                        "388 · \(rowID) 与面板右边之间不够一条指示条")
            // 真正要的那件事：读数右沿在指示条左边留出净空。
            XCTAssertGreaterThanOrEqual(indicator.minX - maxX, 15,
                                        "388 · 指示条仍压着 \(rowID) 的读数")
        }
    }

    // MARK: - ⑤ 窗口宽 = panelWidth

    func testTheSheetWindowWidthFollowsTheConstant() throws {
        let sheet = try presentSheet()
        let contentWidth = sheet.content.bounds.width
        print(String(format: "388 ⑤ · window.contentLayoutRect %.1f · content.bounds %.1f · panelWidth %.1f",
                     sheet.window.contentLayoutRect.width, contentWidth, ExportRowGrid.panelWidth))

        XCTAssertEqual(sheet.window.contentLayoutRect.width, ExportRowGrid.panelWidth, accuracy: 0.5,
                       "388 · 窗口宽必须跟着 panelWidth 常量走")
        XCTAssertEqual(contentWidth, ExportRowGrid.panelWidth, accuracy: 0.5)
        // 字面值 560 不再能通过（⑦ 的判别力就在这两条上）。
        XCTAssertNotEqual(ExportRowGrid.panelWidth, 560, "388 · 面板必须真的变宽了")
    }

    // MARK: - ⑥ 截图

    /// 三段全展开 → `form` 出现指示条 → 用 `screencapture -l <windowNumber>` 对**真窗口**截图，
    /// 存到 `local/export-scroller.png`。
    ///
    /// 为什么不是 `cacheDisplay`：`NSHostingView` 的内容由图层合成，`cacheDisplay` 只拿到底色
    /// （实测整张 35/23 灰，没有文字也没有指示条），截了等于没截。
    ///
    /// 判据（像素级，不看常量）：内容右沿（540 pt → px）以右、指示条竖条以左的那一段**必须是纯
    /// 面板底色**（没有文字的墨迹），而指示条竖条里**必须**有一条比底色亮的拇指。
    func testTheScreenshotShowsAGapBetweenTheTextAndTheIndicator() throws {
        let sheet = try presentSheet()
        let view = sheet.content

        // overlay 指示条静止时会淡出（macOS 的正常行为）；flash 一下才是用户拖动时看到的那一帧。
        // 先 flash 再截图 —— 顺序有讲究：⑨（把 .visible 改成 .hidden）必须在这里红，不能因为
        // 前面某个 unwrap 先炸掉就算红（那等于没验到"截图里有没有指示条"）。
        if let scroll = try? formScrollView(in: view) {
            scroll.flashScrollers()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))

        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("local", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("export-scroller.png")
        try? FileManager.default.removeItem(at: url)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-o", "-l", String(sheet.window.windowNumber), url.path]
        try task.run()
        task.waitUntilExit()
        XCTAssertEqual(task.terminationStatus, 0, "screencapture 失败")

        let data = try Data(contentsOf: url)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data), "截图读不回来")
        let width = image.pixelsWide
        let height = image.pixelsHigh
        print("388 ⑥ · 截图 \(url.path) · \(width)×\(height) px"
              + " · windowNumber \(sheet.window.windowNumber)")

        // screencapture -l 连窗口阴影一起截，所以先在中间那一行找面板的左右边界：
        // 面板是 material（亮度 > 30），阴影/桌面是暗的。
        func luma(_ x: Int, _ y: Int) -> Double {
            guard let colour = image.colorAt(x: x, y: y) else { return 0 }
            return 0.299 * colour.redComponent + 0.587 * colour.greenComponent
                + 0.114 * colour.blueComponent
        }
        let midY = height / 2
        var panelLeft = -1
        var panelRight = -1
        for x in 0..<(width - 1) where luma(x, midY) < 0.12 && luma(x + 1, midY) >= 0.12 {
            panelLeft = x + 1
            break
        }
        for x in stride(from: width - 1, to: 0, by: -1) where luma(x, midY) < 0.12 && luma(x - 1, midY) >= 0.12 {
            panelRight = x - 1
            break
        }
        XCTAssertGreaterThan(panelLeft, 0, "找不到面板左边界")
        XCTAssertGreaterThan(panelRight, panelLeft, "找不到面板右边界")
        let scale = Double(panelRight - panelLeft + 1) / Double(ExportRowGrid.panelWidth)
        print(String(format: "388 ⑥ · 面板 px %d…%d（宽 %d）· %.2f× · 内容右沿 %.1f pt = %.0f px",
                     panelLeft, panelRight, panelRight - panelLeft + 1, scale,
                     ExportRowGrid.contentRight, Double(panelLeft) + ExportRowGrid.contentRight * scale))

        let contentRightPx = panelLeft + Int(ExportRowGrid.contentRight * scale)

        // 检查带：内容右沿右侧到面板右缘之间的每一列，最高亮度 = 有没有墨迹/拇指。
        struct Column { let px: Int; let pt: Double; let peak: Double }
        var columns: [Column] = []
        for x in (contentRightPx + 2)..<panelRight {
            var peak = 0.0
            var y = 0
            while y < height {
                peak = max(peak, luma(x, y))
                y += 2
            }
            columns.append(Column(px: x, pt: Double(x - panelLeft) / scale, peak: peak))
        }
        // 面板底色 ≈ 0.17；拇指比底色亮得多：实测 124/255 ≈ 0.49。
        let background = columns.map(\.peak).min() ?? 0
        let thumb = columns.filter { $0.peak > background + 0.15 }
        print(String(format: "388 ⑥ · 面板底色峰值 %.3f · 右缘检查带 %d 列（pt %.1f…%.1f）",
                     background, columns.count,
                     columns.first?.pt ?? 0, columns.last?.pt ?? 0))
        if let first = thumb.first, let last = thumb.last {
            print(String(format: "388 ⑥ · 拇指列 pt %.1f…%.1f（%d 列）· 峰值 %.3f",
                         first.pt, last.pt, thumb.count, first.peak))
        } else {
            print("388 ⑥ · 检查带里没有比底色亮的列（指示条没画出来）")
        }

        // 指示条几何（读真 NSScroller）只是给打印用的对照；拿不到时（.hidden）就退化成"区间未知"，
        // 让下面那条像素断言负责变红。
        let indicator = try? indicatorRect(in: view)
        if let indicator {
            let inIndicator = thumb.filter { $0.pt >= indicator.minX - 1 && $0.pt <= indicator.maxX + 1 }
            print(String(format: "388 ⑥ · 指示条 %.1f…%.1f · 落在区间里的拇指列 %d",
                         indicator.minX, indicator.maxX, inIndicator.count))
        }

        // 判据 1：截图里必须看得见指示条（⑨ 在这里变红）。
        XCTAssertGreaterThan(thumb.count, 0,
                             "388 · 截图里没有指示条（被藏掉了？）——这正是 ⑨ 必须红的那条")

        // 判据 2：内容右沿到拇指左沿之间必须够宽，且那一段干净。
        if let thumbLeft = thumb.first?.pt {
            let gap = thumbLeft - ExportRowGrid.contentRight
            let dirty = columns.filter { $0.pt <= ExportRowGrid.contentRight && $0.peak > background + 0.15 }
            print(String(format: "388 ⑥ · 内容右沿 %.1f → 拇指左沿 %.1f · 间隙 %.1f pt · 间隙内亮点 %d 个",
                         ExportRowGrid.contentRight, thumbLeft, gap, dirty.count))
            XCTAssertGreaterThanOrEqual(gap, 15, "388 · 文字与指示条之间的间隙只有 \(gap) pt")
            XCTAssertEqual(dirty.count, 0, "388 · 间隙里还有别的东西")
        }
        XCTAssertGreaterThan(width, 0)
    }
}
