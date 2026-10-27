import XCTest
import AppKit
import PhotonsUI

/// 顶栏右上角那一块状态文本的契约：三段同字号同字重同颜色、右对齐成一块、落在检查器列上方，
/// 并且计数从 1 位走到 3 位、已选从 0 走到 99 时，三个框和基线一个像素都不许动。
///
/// 数字全部来自真实的 `TopBarView.layout()`（不是手算的期望值）：这些断言就是"抽动"这个说法
/// 的可执行版本 —— 拿不到 frame 就没有证据。
@MainActor
final class TopBarStatusClusterTests: XCTestCase {

    private let assetCounts = [1, 9, 45, 999]
    private let selectionCounts = [0, 4, 12, 99]

    /// 一个铺满窗口的顶栏，状态文本按给定检查器列宽布局。
    private func makeBar(window: CGSize,
                         inspectorWidth: CGFloat,
                         assets: Int = 45,
                         selection: Int = 4,
                         libraryName: String? = "photons-demo") -> TopBarView {
        let bar = TopBarView()
        // 真实的顶栏是 36 pt 高的一条（宽度 = 窗口宽），不是整窗。
        bar.frame = NSRect(x: 0, y: 0, width: window.width, height: WorkspaceLayout.topBarHeight)
        bar.statusColumnWidth = inspectorWidth
        bar.update(mode: .grid, assetCount: assets, selectionCount: selection,
                   libraryName: libraryName, filmstrip: false)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// label 在顶栏坐标系里的框（label.frame 是簇内坐标，右边缘要跟窗口右边比）。
    private func frameInBar(_ label: NSTextField, _ bar: TopBarView) -> NSRect {
        label.convert(label.bounds, to: bar)
    }

    private func describe(_ label: NSTextField) -> String {
        "\(label.stringValue.debugDescription) frame \(NSStringFromRect(label.frame))"
            + " font \(label.font?.fontName ?? "nil") \(label.font?.pointSize ?? -1)"
    }

    // MARK: 1 · 三段是同一套字

    func testThreeSegmentsShareFontColourAndLineHeight() {
        let bar = makeBar(window: CGSize(width: 1600, height: 940), inspectorWidth: 330)
        let labels = [bar.statusCluster.countLabel,
                      bar.statusCluster.selectionLabel,
                      bar.statusCluster.identityLabel]

        for label in labels {
            XCTAssertEqual(label.font?.pointSize, 10, "字号 \(describe(label))")
            XCTAssertEqual(label.font?.fontName, TopBarStatusCluster.Metrics.font.fontName,
                           "字族 \(describe(label))")
            XCTAssertEqual(label.font.map { weight(of: $0) } ?? -1,
                           weight(of: TopBarStatusCluster.Metrics.font),
                           "字重 \(describe(label))")
            XCTAssertEqual(label.frame.height, TopBarStatusCluster.Metrics.lineHeight, "行高 \(describe(label))")
            XCTAssertEqual(label.frame.minY, labels[0].frame.minY, "同一条基线 \(describe(label))")
            XCTAssertEqual(label.alignment, .right, "右对齐 \(describe(label))")
            XCTAssertTrue(coloursMatch(label.textColor, TopBarStatusCluster.Metrics.textColor),
                          "颜色 \(label.textColor as Any) vs \(TopBarStatusCluster.Metrics.textColor)")
        }
        // 三者的颜色互相也相等（上面已经各自与本类常量比过，这里钉住"三者一致"这句人话）。
        XCTAssertTrue(coloursMatch(labels[0].textColor, labels[1].textColor))
        XCTAssertTrue(coloursMatch(labels[0].textColor, labels[2].textColor))
        XCTAssertEqual(Set(labels.map { $0.frame.midY }).count, 1, "同一水平中线")
        XCTAssertEqual(bar.statusCluster.frame.midY, bar.bounds.midY, accuracy: 0.001,
                       "整块居中在 36 pt 顶栏里 (y = 11)")
        XCTAssertTrue(bar.statusCluster.countLabel.frame.minX
                      < bar.statusCluster.selectionLabel.frame.minX,
                      "顺序：照片数 → 已选")
        XCTAssertTrue(bar.statusCluster.selectionLabel.frame.minX
                      < bar.statusCluster.identityLabel.frame.minX,
                      "顺序：已选 → 库名+build")
        print("cluster@330 \(describe(labels[0])) | \(describe(labels[1])) | \(describe(labels[2]))"
              + " cluster \(NSStringFromRect(bar.statusCluster.frame))")
    }

    // MARK: 2 · 右边缘与间距

    func testRightEdgesAreTheBarInsetAndTheGapsAreTheConstant() {
        for window in [CGSize(width: 1600, height: 940), CGSize(width: 1200, height: 780)] {
            for inspector in [CGFloat(330), 300, 274, 244] {
                let bar = makeBar(window: window, inspectorWidth: inspector)
                let count = frameInBar(bar.statusCluster.countLabel, bar)
                let selection = frameInBar(bar.statusCluster.selectionLabel, bar)
                let identity = frameInBar(bar.statusCluster.identityLabel, bar)
                let gap = TopBarStatusCluster.Metrics.gap
                let inset = TopBarStatusCluster.Metrics.trailingInset
                let context = "\(Int(window.width))×\(Int(window.height)) inspector \(inspector)"

                // 最右一段的右边缘 = 顶栏右边距 = 窗口右边 − 16。
                XCTAssertEqual(identity.maxX, bar.bounds.width - inset, accuracy: 0.001, context)
                XCTAssertEqual(bar.statusCluster.frame.maxX, bar.bounds.width - inset, accuracy: 0.001, context)
                // 已选 右边缘 = 库名 左边缘 − 间距；照片数 右边缘 = 已选 左边缘 − 间距。
                XCTAssertEqual(selection.maxX, identity.minX - gap, accuracy: 0.001, context)
                XCTAssertEqual(count.maxX, selection.minX - gap, accuracy: 0.001, context)
                print("edges \(context): count \(NSStringFromRect(count)) 已选 \(NSStringFromRect(selection))"
                      + " identity \(NSStringFromRect(identity))")
            }
        }
    }

    // MARK: 3 · 落在检查器列上方

    /// 检查器列矩形：右边缘是窗口右边，宽度就是列宽。`WorkspaceLayout` 在这一支里把列宽夹在
    /// 300…364（`inspectorWidthMin/Max`），所以 274 / 244 这两列在本树里到不了 —— 它们是**组件
    /// 契约**上的数字，直接灌给 `statusColumnWidth` 验证"列再窄也不许横到画布上"。
    func testClusterStaysOverTheInspectorColumn() {
        for window in [CGSize(width: 1600, height: 940), CGSize(width: 1200, height: 780)] {
            for inspector in [CGFloat(364), 330, 300, 274, 244] {
                let column = CGRect(x: window.width - inspector, y: 0, width: inspector, height: 36)
                let bar = makeBar(window: window, inspectorWidth: inspector)
                let cluster = bar.statusCluster.frame
                let context = "\(Int(window.width))×\(Int(window.height)) inspector \(inspector)"

                XCTAssertGreaterThanOrEqual(cluster.minX, column.minX - 0.001,
                                            "簇的左边缘越过了检查器列左边 ①\(context) cluster \(NSStringFromRect(cluster)) column \(NSStringFromRect(column))")
                XCTAssertLessThanOrEqual(cluster.maxX, column.maxX + 0.001, "簇的右边缘越过了列右边 ②\(context)")
                XCTAssertGreaterThanOrEqual(cluster.minX, bar.controlsTrailingEdge
                                            + TopBarStatusCluster.Metrics.minimumGapFromControls - 0.001,
                                            "簇压到了顶栏控件 ③\(context)")
                print("column \(context): cluster \(NSStringFromRect(cluster)) column \(NSStringFromRect(column))"
                      + " controlsEnd \(bar.controlsTrailingEdge)")
            }
        }
    }

    // MARK: 4 · 不抽动

    /// 照片数 1→3 位、已选 0→99，三个框逐字段相等：origin、size、字、颜色、基线。
    func testCountsNeverMoveAnEdgeOrTheBaseline() {
        for window in [CGSize(width: 1600, height: 940), CGSize(width: 1200, height: 780)] {
            for inspector in [CGFloat(330), 300, 244] {
                let reference = makeBar(window: window, inspectorWidth: inspector,
                                        assets: assetCounts[0], selection: selectionCounts[0])
                let baseFrames = [reference.statusCluster.countLabel.frame,
                                  reference.statusCluster.selectionLabel.frame,
                                  reference.statusCluster.identityLabel.frame]

                for assets in assetCounts {
                    for selection in selectionCounts {
                        let bar = makeBar(window: window, inspectorWidth: inspector,
                                          assets: assets, selection: selection)
                        let frames = [bar.statusCluster.countLabel.frame,
                                      bar.statusCluster.selectionLabel.frame,
                                      bar.statusCluster.identityLabel.frame]
                        let context = "\(Int(window.width)) inspector \(inspector) assets \(assets) selected \(selection)"
                        XCTAssertEqual(frames, baseFrames, "框抽动了 ④\(context)")
                        XCTAssertEqual(bar.statusCluster.frame, reference.statusCluster.frame,
                                       "整块抽动了 ⑤\(context)")
                        XCTAssertEqual(bar.statusCluster.countLabel.font?.pointSize,
                                       reference.statusCluster.countLabel.font?.pointSize)
                        print("jitter \(context): \(frames.map { NSStringFromRect($0) }.joined(separator: " "))")
                    }
                }
                // 只有框里的字形在变：文案确实跟着计数走了。
                let wide = makeBar(window: window, inspectorWidth: inspector, assets: 999, selection: 99)
                XCTAssertTrue(wide.statusCluster.countLabel.stringValue.contains("999"))
                XCTAssertTrue(wide.statusCluster.selectionLabel.stringValue.contains("99"))
            }
        }
    }

    // MARK: 5 · 长库名

    func testLongLibraryNameTruncatesAndKeepsTheVersionVisible() {
        let revision = BuildStamp.revision
        let names = ["photons-demo.photonslibrary",
                     "photons-demo.photonslibrary.backup-2026-10-27",
                     "一个名字特别特别特别特别特别特别特别特别特别长的中文库"]
        for inspector in [CGFloat(330), 300, 274, 244] {
            for name in names {
                let bar = makeBar(window: CGSize(width: 1600, height: 940),
                                  inspectorWidth: inspector, libraryName: name)
                let label = bar.statusCluster.identityLabel
                let identity = frameInBar(label, bar)
                let column = CGRect(x: 1600 - inspector, y: 0, width: inspector, height: 36)
                let text = label.stringValue
                let full = "\(name) \(revision)"
                let fullWidth = TopBarStatusCluster.Metrics.width(full)

                XCTAssertTrue(text.hasSuffix(" \(revision)"), "版本号必须完整可见 \(inspector): \(text)")
                XCTAssertEqual(label.toolTip, full, "tooltip 要给全名")
                XCTAssertLessThanOrEqual(text.count, full.count, "截断只许变短")
                XCTAssertGreaterThanOrEqual(bar.statusCluster.frame.minX, column.minX - 0.001,
                                            "长库名把簇顶到画布上去了 \(inspector) \(name)")
                if fullWidth > identity.width + 0.001 {
                    XCTAssertTrue(text.contains("…"), "库名要尾部省略 \(inspector): \(text)")
                    XCTAssertLessThanOrEqual(identity.width, column.width - 16 - 106.92 + 0.01)
                } else {
                    XCTAssertEqual(text, full, "放得下就不许截 \(inspector)")
                }
                print("truncation@\(inspector) \(String(format: "%.2f", fullWidth))→"
                      + "\(String(format: "%.2f", identity.width)): \"\(text)\"")
            }
        }
    }

    // MARK: 6 · 退化

    /// 簇比检查器列宽还宽（模拟一个极窄列）：允许向左伸出列，但必须停在顶栏控件右边 16 pt。
    func testSqueezeStopsAtTheControlsInsteadOfCoveringThem() {
        let bar = TopBarView()
        bar.frame = NSRect(x: 0, y: 0, width: 1600, height: 36)
        bar.statusColumnWidth = 4000     // 取消"留在列上方"这一约束，只剩控件这一条硬线
        bar.update(mode: .grid, assetCount: 45, selectionCount: 4,
                   libraryName: String(repeating: "很长的库名", count: 20), filmstrip: false)
        bar.layoutSubtreeIfNeeded()

        let limitX = bar.controlsTrailingEdge + TopBarStatusCluster.Metrics.minimumGapFromControls
        XCTAssertGreaterThanOrEqual(bar.statusCluster.frame.minX, limitX - 0.001,
                                    "簇压到控件上了: \(NSStringFromRect(bar.statusCluster.frame))")
        XCTAssertEqual(bar.statusCluster.frame.maxX, 1600 - 16, accuracy: 0.001)
        print("squeeze: cluster \(NSStringFromRect(bar.statusCluster.frame)) limitX \(limitX)"
              + " text \"\(bar.statusCluster.identityLabel.stringValue)\"")

        // 连"…+版本号"都放不下：整块隐藏，而不是剪碎或压住按钮。
        let tiny = TopBarView()
        tiny.frame = NSRect(x: 0, y: 0, width: 1600, height: 36)
        tiny.statusColumnWidth = 160
        tiny.update(mode: .grid, assetCount: 45, selectionCount: 4,
                    libraryName: "photons-demo", filmstrip: false)
        tiny.layoutSubtreeIfNeeded()
        XCTAssertTrue(tiny.statusCluster.isHidden || tiny.statusCluster.frame.width == 0,
                      "窄列要么隐藏要么为零宽: \(NSStringFromRect(tiny.statusCluster.frame))")
    }

    // MARK: 7 · 文案

    func testTextIsCountSelectionAndLibraryPlusBuild() {
        let bar = makeBar(window: CGSize(width: 1600, height: 940), inspectorWidth: 330,
                          assets: 45, selection: 4, libraryName: "photons-demo")
        let figure = TopBarStatusCluster.Metrics.figureSpace
        func plain(_ s: String) -> String { s.replacingOccurrences(of: figure, with: "") }

        XCTAssertEqual(plain(bar.statusCluster.countLabel.stringValue), "45 张")
        XCTAssertEqual(plain(bar.statusCluster.selectionLabel.stringValue), "已选 4")
        XCTAssertEqual(bar.statusCluster.identityLabel.stringValue,
                       "photons-demo \(BuildStamp.revision)")

        // 未打开库 + 未选：三段照样都在（行宽因此不跳），最右一段沿用旧语义。
        let empty = makeBar(window: CGSize(width: 1600, height: 940), inspectorWidth: 330,
                            assets: 0, selection: 0, libraryName: nil)
        XCTAssertEqual(plain(empty.statusCluster.countLabel.stringValue), "0 张")
        XCTAssertEqual(plain(empty.statusCluster.selectionLabel.stringValue), "已选 0")
        XCTAssertEqual(empty.statusCluster.identityLabel.stringValue, "未打开库 \(BuildStamp.revision)")
    }

    // MARK: 8 · 真窗口

    /// 真 `WorkspaceRootView` 里的那一条：检查器列宽由 `WorkspaceRootView.layout()` 交给顶栏，
    /// 状态块因此落在检查器列上方、右边缘贴窗口右边 16 pt。
    func testRealWorkspaceKeepsTheClusterOverTheInspectorColumn() {
        _ = NSApplication.shared
        for size in [NSSize(width: 1600, height: 940), WorkspaceLayout.minimumWindowSize] {
            let controller = EditorWindowController(size: size)
            guard let window = controller.window else { return XCTFail("窗口没建出来") }
            defer { window.orderOut(nil) }
            window.setContentSize(size)
            let root = controller.rootView!
            window.contentView?.layoutSubtreeIfNeeded()
            root.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            root.layoutSubtreeIfNeeded()
            root.topBar.layoutSubtreeIfNeeded()

            let bar = root.topBar
            let cluster = bar.convert(bar.statusCluster.frame, to: root)
            let inspector = root.geometry.inspector
            let context = "\(Int(root.bounds.width))×\(Int(root.bounds.height)) inspector \(inspector.width)"
            XCTAssertEqual(inspector.maxX, root.bounds.width, accuracy: 0.5)
            XCTAssertEqual(bar.statusColumnWidth, inspector.width, accuracy: 0.001, context)
            XCTAssertGreaterThanOrEqual(cluster.minX, inspector.minX - 0.001,
                                        "簇的左边缘越过了检查器列 \(context) cluster \(NSStringFromRect(cluster))")
            XCTAssertLessThanOrEqual(cluster.maxX, inspector.maxX + 0.001, context)
            XCTAssertEqual(cluster.maxX, root.bounds.width - TopBarStatusCluster.Metrics.trailingInset,
                           accuracy: 0.001, context)
            XCTAssertEqual(cluster.height, TopBarStatusCluster.Metrics.lineHeight, accuracy: 0.001)
            print("real \(context): cluster \(NSStringFromRect(cluster)) inspector \(NSStringFromRect(inspector))"
                  + " text \"\(bar.statusCluster.countLabel.stringValue)\""
                  + " \"\(bar.statusCluster.selectionLabel.stringValue)\""
                  + " \"\(bar.statusCluster.identityLabel.stringValue)\"")
        }
    }

    // MARK: helpers

    private func weight(of font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return traits?[.weight] as? CGFloat ?? -1
    }

    private func coloursMatch(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a, let b, let lhs = a.usingColorSpace(.sRGB), let rhs = b.usingColorSpace(.sRGB) else {
            return a == b
        }
        return abs(lhs.redComponent - rhs.redComponent) < 0.001
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.001
    }
}
