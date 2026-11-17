import XCTest
import AppKit
import PhotonsCatalog
@testable import PhotonsUI

/// 423 — 顶栏七个控件是**一族**。
///
/// 用户的投诉是两条：「网格单图相比其他文字更高」和「任务的样式与导入导出和打开不一样」。
/// 这张表把「一族」写成了可量化的四条：同一个字号（11 pt）、同一个字重（medium）、
/// 同一个命中高（28 pt）、同样没有系统边框（`isBordered == false` + `.regularSquare`），
/// 再加一条**渲染**证据：三段文字的实际排版高度与邻居的标题差 ≤ 1 pt。
///
/// 反证（派单 §D ⑧a/⑧b）用同一套判据：把 `modeControl.font` 去掉、把 `tasksButton` 改回
/// `.texturedRounded`，A①/A④ 与 A③ 必须红。
@MainActor
final class TopBarChrome423Tests: XCTestCase {

    private var bars: [TopBarView] = []

    override func tearDownWithError() throws {
        bars.removeAll()
    }

    private func makeBar(width: CGFloat = 1400) -> TopBarView {
        let bar = TopBarView()
        bar.frame = NSRect(x: 0, y: 0, width: width, height: WorkspaceLayout.topBarHeight)
        bar.statusColumnWidth = WorkspaceLayout.inspectorWidthDefault
        bar.update(mode: .grid, assetCount: 45, selectionCount: 4,
                   libraryName: "photons-demo", filmstrip: false)
        bar.layoutSubtreeIfNeeded()
        bars.append(bar)
        return bar
    }

    /// 七个控件，带人能读懂的名字（失败信息里就是这些名字）。
    private func controls(_ bar: TopBarView) -> [(name: String, view: NSView, font: NSFont?)] {
        let c = bar.chromeControlViews
        return [("打开", c.open, c.open.font),
                ("导入", c.importButton, c.importButton.font),
                ("导出", c.exportButton, c.exportButton.font),
                ("网格/单图", c.mode, c.mode.font),
                ("胶片条", c.strip, c.strip.font),
                ("排序", c.sort, c.sort.font),
                ("任务", c.tasks, c.tasks.font)]
    }

    private func weight(of font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return traits?[.weight] as? CGFloat ?? -1
    }

    // MARK: A① 字号 + 字重

    func testAllSevenControlsShareElevenMedium() {
        let bar = makeBar()
        let medium = weight(of: .systemFont(ofSize: 11, weight: .medium))
        var seen: [String] = []
        for control in controls(bar) {
            let font = control.font
            XCTAssertEqual(font?.pointSize, 11, "「\(control.name)」字号")
            XCTAssertEqual(font.map { weight(of: $0) } ?? -1, medium,
                           accuracy: 0.0001, "「\(control.name)」字重")
            seen.append("\(control.name)=\(font?.pointSize ?? -1)pt w=\(font.map { weight(of: $0) } ?? -1)")
        }
        print("A① 七个控件字体：" + seen.joined(separator: " · "))
    }

    // MARK: A② 命中高

    func testAllSevenControlsShareTwentyEightPointHitHeight() {
        let bar = makeBar()
        var seen: [String] = []
        for control in controls(bar) {
            XCTAssertEqual(control.view.frame.height, WorkspaceLayout.toolButtonHit,
                           "「\(control.name)」命中高")
            seen.append("\(control.name)=\(control.view.frame.height)")
        }
        XCTAssertEqual(WorkspaceLayout.toolButtonHit, 28, "toolButtonHit 本身就是 28")
        print("A② 七个控件命中高：" + seen.joined(separator: " · "))
    }

    // MARK: A③ 任务按钮不再有系统边框

    func testTasksButtonDroppedItsSystemBezel() {
        let bar = makeBar()
        let tasks = bar.chromeControlViews.tasks
        XCTAssertFalse(tasks.isBordered, "任务按钮必须是无边框自绘族")
        XCTAssertEqual(tasks.bezelStyle, .regularSquare, "与 ToolButton 同一个 bezelStyle")
        // 邻居是这条判据的参照物：两个都必须是同一族，不然「同款」只是形容词。
        let open = bar.chromeControlViews.open
        XCTAssertEqual(tasks.isBordered, open.isBordered)
        XCTAssertEqual(tasks.bezelStyle, open.bezelStyle)
        print("A③ tasks isBordered=\(tasks.isBordered) bezelStyle=\(tasks.bezelStyle.rawValue)"
              + " / open isBordered=\(open.isBordered) bezelStyle=\(open.bezelStyle.rawValue)")
    }

    // MARK: A④ 实际渲染字高

    func testRenderedTextHeightsMatchTheNeighbouringTitle() {
        let bar = makeBar()
        let mode = bar.chromeControlViews.mode
        let tasks = bar.chromeControlViews.tasks
        let reference = openTitleHeight(bar)

        // 每段文字用它**自己**控件的字体量（不是借邻居的字体），否则这条判据看不见字体漂移。
        let candidates: [(String, String, NSFont?)] = [
            ("网格", mode.label(forSegment: 0) ?? "", mode.font),
            ("单图", mode.label(forSegment: 1) ?? "", mode.font),
            ("任务", tasks.title, tasks.font),
        ]
        for (name, text, font) in candidates {
            let height = (text as NSString).size(withAttributes: [.font: font ?? .systemFont(ofSize: 11)]).height
            XCTAssertLessThanOrEqual(abs(height - reference), 1.0,
                                     "「\(name)」的渲染字高 \(height) 与打开按钮的标题 \(reference) 差超过 1 pt")
        }
        print("A④ 打开标题高=\(reference) · 网格=\(segmentHeight(mode, 0))"
              + " · 单图=\(segmentHeight(mode, 1)) · 任务=\(taskTitleHeight(tasks))")
    }

    private func openTitleHeight(_ bar: TopBarView) -> CGFloat {
        let open = bar.chromeControlViews.open
        return (open.title as NSString).size(withAttributes: [.font: open.font ?? .systemFont(ofSize: 11)]).height
    }
    private func segmentHeight(_ control: NSSegmentedControl, _ index: Int) -> CGFloat {
        let text = control.label(forSegment: index) ?? ""
        return (text as NSString).size(withAttributes: [.font: control.font ?? .systemFont(ofSize: 11)]).height
    }
    private func taskTitleHeight(_ button: NSButton) -> CGFloat {
        (button.title as NSString).size(withAttributes: [.font: button.font ?? .systemFont(ofSize: 11)]).height
    }

    // MARK: A⑤ 进度条仍在

    func testProgressBarSurvivesWithoutTheSystemBezel() {
        let bar = makeBar()
        let tasks = bar.chromeControlViews.tasks
        let progress = tasks.progressIndicator
        tasks.layoutSubtreeIfNeeded()
        XCTAssertEqual(progress.frame.height, 3, "那条 3 pt 进度条去掉边框后必须仍是 3 pt")
        XCTAssertLessThanOrEqual(progress.frame.maxY, tasks.bounds.height + 0.001,
                                 "进度条要落在按钮里")
        XCTAssertGreaterThan(progress.frame.width, 0, "进度条有宽度")
        // 显隐逻辑不变：没有活动任务时隐藏，有活动任务时显示。
        XCTAssertEqual(progress.isHidden, BackgroundTasks.shared.activeCount == 0,
                       "progress.isHidden 仍由 activeCount 决定")
        print("A⑤ progress height=\(progress.frame.height) width=\(progress.frame.width)"
              + " hidden=\(progress.isHidden) active=\(BackgroundTasks.shared.activeCount)")
    }

    /// A⑤ 的**渲染**版：3 pt 不是说 frame 就算数 —— 把进度条从隐藏切到 50 %，
    /// 按钮的两张 bitmap 必须在这 3 pt 带上产生差异像素。一个无边框按钮把进度条盖掉、
    /// 或者进度条被裁掉，这条就红。
    func testProgressBarPaintsPixelsWithoutTheSystemBezel() throws {
        let button = makeBar().chromeControlViews.tasks
        button.frame = NSRect(x: 0, y: 0, width: 86, height: WorkspaceLayout.toolButtonHit)
        let progress = button.progressIndicator

        progress.isHidden = true
        button.layoutSubtreeIfNeeded()
        let hidden = try XCTUnwrap(renderBitmap(button))

        progress.isHidden = false
        progress.isIndeterminate = false
        progress.doubleValue = 0.5
        button.layoutSubtreeIfNeeded()
        let shown = try XCTUnwrap(renderBitmap(button))

        var different = 0
        var maxDelta: CGFloat = 0
        for x in 0..<min(hidden.pixelsWide, shown.pixelsWide) {
            for y in 0..<min(hidden.pixelsHigh, shown.pixelsHigh) {
                let a = hidden.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                let b = shown.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                let dr: CGFloat = abs((a?.redComponent ?? 0) - (b?.redComponent ?? 0))
                let dg: CGFloat = abs((a?.greenComponent ?? 0) - (b?.greenComponent ?? 0))
                let db: CGFloat = abs((a?.blueComponent ?? 0) - (b?.blueComponent ?? 0))
                let delta: CGFloat = dr + dg + db
                maxDelta = max(maxDelta, delta)
                if delta > 0.02 { different += 1 }
            }
        }
        XCTAssertGreaterThan(different, 5,
                             "3 pt 进度条没有画出任何像素（差 \(different) px, max Δ \(maxDelta)）")
        print("A⑤ 渲染：\(shown.pixelsWide)×\(shown.pixelsHigh) 上差 \(different) px（max Δ \(maxDelta)）")
        progress.isHidden = true
    }

    private func renderBitmap(_ view: NSView) -> NSBitmapImageRep? {
        guard let appearance = NSAppearance(named: .darkAqua) else { return nil }
        var rep: NSBitmapImageRep?
        appearance.performAsCurrentDrawingAppearance {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            rep = bitmap
        }
        return rep
    }

    // MARK: 宽度：86 是下界，不是常数

    func testTasksButtonWidthNeverGoesBelowTheOldHardcodedEightySix() {
        let bar = makeBar()
        let tasks = bar.chromeControlViews.tasks
        let intrinsic = tasks.intrinsicContentSize.width
        XCTAssertEqual(tasks.frame.width, max(86, intrinsic), accuracy: 0.001,
                       "宽度 = max(86, intrinsic)")
        XCTAssertGreaterThanOrEqual(tasks.frame.width, 86, "不窄于原来的 86")
        XCTAssertEqual(bar.controlsTrailingEdge, tasks.frame.maxX, accuracy: 0.001,
                       "controlsTrailingEdge 仍是任务按钮的右边缘")
        print("A· 宽度 intrinsic=\(intrinsic) applied=\(tasks.frame.width) trailing=\(bar.controlsTrailingEdge)")
    }

    /// 状态簇不许因为这次改动左移：它仍然落在 `controlsTrailingEdge + 16` 右边。
    func testStatusClusterStaysRightOfTheControls() {
        for width in [CGFloat(1200), 1600] {
            let bar = makeBar(width: width)
            let cluster = bar.statusCluster
            XCTAssertGreaterThanOrEqual(cluster.frame.minX,
                                        bar.controlsTrailingEdge
                                            + TopBarStatusCluster.Metrics.minimumGapFromControls - 0.001,
                                        "状态簇在 \(width) pt 窗口下压到了控件上")
            XCTAssertEqual(cluster.frame.maxX,
                           width - TopBarStatusCluster.Metrics.trailingInset, accuracy: 0.001)
        }
    }
}
