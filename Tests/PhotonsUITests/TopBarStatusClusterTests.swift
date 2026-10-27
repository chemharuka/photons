import XCTest
import AppKit
import PhotonsUI

/// 顶栏右上角那一块状态文本的契约（2026-10-27 第二版）。四段一条线，从左到右：
///
///     `已选 4`  ·  `45 张`  ·  `photons-demo`  ·  `498331f`
///
/// 要钉住的六件事，每件都是可执行的数字：
///
/// 1. **顺序**：已选 → 张数 → 库名 → 版本号，版本号永远最右。
/// 2. **右对齐、右边缘固定**：整簇与版本号的右边缘都 = 窗口右边 − 16 pt。
/// 3. **不写死锚点**：段的位置是"从右往左按各自实际宽度 + 常量 gap"算出来的；计数从 1 位走到
///    3 位、已选从 0 走到 999，四段各自的**宽**与整簇的右边缘逐字相同。
/// 4. **库名有宽度上限**：`min(180, 可用宽度 − 已选 − 张 − 版本 − 3 × gap)`；只有库名会截
///    （中间省略，tooltip 全名），计数与版本号永不被截。
/// 5. **文本不被吞**：每段 `NSString.size(withAttributes:).width <= frame.width`，
///    版本号 frame 右边缘 == `bounds.width − 16`。
/// 6. **反证常驻**：旧顺序（`N 张` 在前）与写死框宽，用同一套判据必须红。
///
/// 数字全部来自真实的 `TopBarView.layout()`：拿不到 frame 就没有证据。
@MainActor
final class TopBarStatusClusterTests: XCTestCase {

    private let assetCounts = [1, 9, 45, 999]
    private let selectionCounts = [0, 4, 45]
    private let windows = [CGSize(width: 1600, height: 940), CGSize(width: 1200, height: 780)]
    private let inspectors: [CGFloat] = [300, 330, 364]

    /// 一个铺满窗口的顶栏，状态文本按给定检查器列宽布局。
    private func makeBar(window: CGSize,
                         inspectorWidth: CGFloat,
                         assets: Int = 45,
                         selection: Int = 4,
                         libraryName: String? = "photons-demo") -> TopBarView {
        let bar = TopBarView()
        bar.frame = NSRect(x: 0, y: 0, width: window.width, height: WorkspaceLayout.topBarHeight)
        bar.statusColumnWidth = inspectorWidth
        bar.update(mode: .grid, assetCount: assets, selectionCount: selection,
                   libraryName: libraryName, filmstrip: false)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// 四段，从左到右（顺序即断言）。
    private func segments(_ cluster: TopBarStatusCluster) -> [(name: String, label: NSTextField)] {
        [("已选", cluster.selectionLabel),
         ("张数", cluster.countLabel),
         ("库名", cluster.nameLabel),
         ("版本", cluster.revisionLabel)]
    }

    private func frameInBar(_ label: NSTextField, _ bar: TopBarView) -> NSRect {
        label.convert(label.bounds, to: bar)
    }

    private func describe(_ label: NSTextField) -> String {
        let advance = TopBarStatusCluster.Metrics.width(label.stringValue)
        return "\(label.stringValue.debugDescription)"
            + " frame=\(NSStringFromRect(label.frame))"
            + " textW=\(String(format: "%.4f", advance))"
            + " slack=\(String(format: "%.4f", label.frame.width - advance))"
    }

    private func textWidth(_ label: NSTextField) -> CGFloat {
        TopBarStatusCluster.Metrics.width(label.stringValue)
    }

    // MARK: 1 · 四段是同一套字 + 顺序

    func testFourSegmentsShareFontColourLineHeightAndOrder() {
        let bar = makeBar(window: windows[0], inspectorWidth: 330)
        let cluster = bar.statusCluster
        let labels = segments(cluster).map(\.label)

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
        XCTAssertEqual(Set(labels.map { $0.frame.midY }).count, 1, "同一水平中线")
        XCTAssertEqual(cluster.frame.midY, bar.bounds.midY, accuracy: 0.001, "整块居中在 36 pt 顶栏里")

        // 顺序：已选 → 张数 → 库名 → 版本号（版本号永远最右）。
        for (lhs, rhs) in zip(labels, labels.dropFirst()) {
            XCTAssertLessThan(lhs.frame.maxX, rhs.frame.minX,
                              "顺序错了：\(lhs.stringValue.debugDescription) 不在 \(rhs.stringValue.debugDescription) 左边")
        }
        XCTAssertEqual(cluster.revisionLabel.frame.maxX, cluster.bounds.width, accuracy: 0.001,
                       "版本号是最后一段，右边缘贴簇右边缘")
        print("segments@330 " + segments(cluster).map { describe($0.label) }.joined(separator: " | ")
              + " cluster=\(NSStringFromRect(cluster.frame))")
    }

    // MARK: 2 · 六组 frame 数字（1600×940 / 1200×780 × 300 / 330 / 364）

    func testSixLayoutsReportFramesNameLimitAndFixedRightEdge() {
        let gap = TopBarStatusCluster.Metrics.gap
        let inset = TopBarStatusCluster.Metrics.trailingInset
        let longName = String(repeating: "photons-library-backup-2026-10-27/", count: 2)   // 68 字符
        for window in windows {
            for inspector in inspectors {
                for (tag, name) in [("short", "photons-demo"), ("long", longName)] {
                    let bar = makeBar(window: window, inspectorWidth: inspector, libraryName: name)
                    let cluster = bar.statusCluster
                    let context = "\(Int(window.width))×\(Int(window.height)) inspector \(inspector) name \(tag)"
                    let parts = segments(cluster).map { (name: $0.name, label: $0.label,
                                                         frame: frameInBar($0.label, bar)) }

                    // 右边缘 = 窗口右边 − 16，簇与版本号都是。
                    XCTAssertEqual(cluster.frame.maxX, bar.bounds.width - inset, accuracy: 0.001, "簇右边缘 \(context)")
                    XCTAssertEqual(parts[3].frame.maxX, bar.bounds.width - inset, accuracy: 0.001,
                                   "版本号右边缘 \(context)")
                    // 段间距恒为 Metrics.gap：从右往左只有"自己的宽度 + gap"。
                    for i in stride(from: 3, through: 1, by: -1) {
                        XCTAssertEqual(parts[i].frame.minX - parts[i - 1].frame.maxX, gap, accuracy: 0.001,
                                       "gap \(parts[i - 1].name)→\(parts[i].name) \(context)")
                    }
                    // 每段文本都装得下（不被吞），没有一段被裁。
                    for part in parts {
                        XCTAssertLessThanOrEqual(textWidth(part.label), part.frame.width + 0.0001,
                                                 "\(part.name) 的文本比框宽 \(context) \(describe(part.label))")
                        XCTAssertGreaterThan(part.frame.width, 0, "\(part.name) 框宽为零 \(context)")
                    }
                    // 库名上限 vs 实际库名宽；四段总宽 ≤ 检查器列宽（300 组因此 ≤ 300）。
                    let nameLimit = cluster.nameWidthLimit(limit: cluster.widthLimit)
                    XCTAssertLessThanOrEqual(cluster.nameLabel.frame.width, nameLimit + 0.0001,
                                             "库名超了上限 \(context)")
                    XCTAssertLessThanOrEqual(cluster.frame.width, inspector + 0.0001,
                                             "四段总宽超过检查器列 \(context)")
                    XCTAssertGreaterThanOrEqual(cluster.frame.minX, bar.bounds.width - inspector - 0.001,
                                                "簇左边缘越过了检查器列 \(context)")
                    if tag == "short" {
                        XCTAssertEqual(cluster.nameLabel.frame.width, textWidth(cluster.nameLabel) + 1,
                                       accuracy: 1.001, "短库名不被截：框宽 = 文本宽 + slack \(context)")
                    } else {
                        XCTAssertTrue(cluster.nameLabel.stringValue.contains(TopBarStatusCluster.Metrics.ellipsis),
                                      "长库名要中间省略 \(context)")
                        XCTAssertGreaterThan(cluster.nameLabel.frame.width, nameLimit - 12,
                                             "长库名没吃满预算 \(context)")
                    }

                    let frames = parts.map { "\($0.name) x=\(String(format: "%.2f", $0.frame.minX))"
                        + " w=\(String(format: "%.2f", $0.frame.width))" }.joined(separator: " ")
                    print("six \(context): \(frames) | cluster x=\(String(format: "%.2f", cluster.frame.minX))"
                          + " w=\(String(format: "%.2f", cluster.frame.width))"
                          + " rightInset=\(String(format: "%.2f", bar.bounds.width - cluster.frame.maxX))"
                          + " nameLimit=\(String(format: "%.2f", nameLimit))"
                          + " nameActual=\(String(format: "%.2f", cluster.nameLabel.frame.width))"
                          + " nameTextW=\(String(format: "%.4f", textWidth(cluster.nameLabel)))")
                }
            }
        }
    }

    // MARK: 3 · 文本不被吞（修"最右字符被吞"的那条）

    /// 旧实现让末段 frame 宽**等于**文本 advance，右对齐的 `NSTextFieldCell` 把行宽按整点取整，
    /// 最后一个字形被 `.byClipping` 切掉（实测 `498331f`：框 43.3138 = 文本 43.3138 时墨迹停在
    /// 距框右边缘 8.63 device px 处，≈ 整个 'f'）。现在每段框宽 = `ceil(advance) + 1 pt`。
    func testEverySegmentFrameIsWiderThanItsTextAndTheVersionEdgeIsPinned() {
        let revision = BuildStamp.revision
        for window in windows {
            for inspector in inspectors {
                let bar = makeBar(window: window, inspectorWidth: inspector)
                let cluster = bar.statusCluster
                let context = "\(Int(window.width))×\(Int(window.height)) inspector \(inspector)"

                for part in segments(cluster) {
                    let advance = textWidth(part.label)
                    XCTAssertLessThanOrEqual(advance, part.label.frame.width + 0.0001,
                                             "\(part.name) 文本被吞 \(context) \(describe(part.label))")
                    XCTAssertGreaterThanOrEqual(part.label.frame.width - advance,
                                                TopBarStatusCluster.Metrics.textSlack - 0.0001,
                                                "\(part.name) 的余量不足一个 slack \(context)")
                }
                // 版本号：文本宽 ≤ frame 宽，且 frame 右边缘 == 窗口右边 − 16。
                let version = cluster.revisionLabel
                XCTAssertEqual(version.stringValue, revision)
                XCTAssertLessThanOrEqual(TopBarStatusCluster.Metrics.width(revision), version.frame.width)
                XCTAssertEqual(version.frame.maxX, cluster.bounds.width, accuracy: 0.001,
                               "版本号贴簇右边缘 \(context)")
                XCTAssertEqual(frameInBar(version, bar).maxX,
                               bar.bounds.width - TopBarStatusCluster.Metrics.trailingInset,
                               accuracy: 0.001, "版本号右边缘 \(context)")
                print("noClip \(context): version frame=\(NSStringFromRect(version.frame))"
                      + " textW=\(String(format: "%.4f", TopBarStatusCluster.Metrics.width(revision)))"
                      + " slack=\(String(format: "%.4f", version.frame.width - TopBarStatusCluster.Metrics.width(revision)))"
                      + " | selection "
                      + "\(String(format: "%.4f", textWidth(cluster.selectionLabel)))≤"
                      + "\(String(format: "%.4f", cluster.selectionLabel.frame.width))"
                      + " | count \(String(format: "%.4f", textWidth(cluster.countLabel)))≤"
                      + "\(String(format: "%.4f", cluster.countLabel.frame.width))"
                      + " | name \(String(format: "%.4f", textWidth(cluster.nameLabel)))≤"
                      + "\(String(format: "%.4f", cluster.nameLabel.frame.width))")
            }
        }
    }

    // MARK: 4 · 不抽动

    /// 计数 1/9/45/999 × 已选 0/4/45 × 三种列宽：四段各自的宽、整簇 frame、右边缘逐字相同。
    /// 段的位置可以因库名宽变化而整体左右移动（库名没变，所以这里也不动），但右边缘一寸不动。
    func testCountsNeverMoveTheRightEdgeOrAnySegmentWidth() {
        for window in windows {
            for inspector in inspectors {
                let reference = makeBar(window: window, inspectorWidth: inspector,
                                        assets: assetCounts[0], selection: selectionCounts[0])
                let baseWidths = segments(reference.statusCluster).map { $0.label.frame.width }
                let baseFrames = segments(reference.statusCluster).map { $0.label.frame }
                let baseRight = reference.statusCluster.frame.maxX

                for assets in assetCounts {
                    for selection in selectionCounts {
                        let bar = makeBar(window: window, inspectorWidth: inspector,
                                          assets: assets, selection: selection)
                        let labels = segments(bar.statusCluster).map(\.label)
                        let context = "\(Int(window.width)) inspector \(inspector)"
                            + " assets \(assets) selected \(selection)"

                        XCTAssertEqual(labels.map { $0.frame.width }, baseWidths,
                                       "段宽抽动了 ④\(context)")
                        XCTAssertEqual(labels.map { $0.frame }, baseFrames, "段位置抽动了 ④\(context)")
                        XCTAssertEqual(bar.statusCluster.frame.maxX, baseRight, accuracy: 0.001,
                                       "右边缘抽动了 ⑤\(context)")
                        XCTAssertEqual(bar.statusCluster.frame.maxX, bar.bounds.width - 16, accuracy: 0.001,
                                       "右边缘不贴窗口 ⑤\(context)")
                        XCTAssertEqual(bar.statusCluster.frame.width, reference.statusCluster.frame.width,
                                       accuracy: 0.001, "整块宽度抽动了 ⑤\(context)")
                    }
                }
                // 字形确实跟着计数走（只有字形在动，框不动）。
                for (assets, selection) in [(1, 0), (999, 45)] {
                    let bar = makeBar(window: window, inspectorWidth: inspector,
                                      assets: assets, selection: selection)
                    XCTAssertTrue(bar.statusCluster.countLabel.stringValue.contains("\(assets)"))
                    XCTAssertTrue(bar.statusCluster.selectionLabel.stringValue.contains("\(selection)"))
                }
                let before = makeBar(window: window, inspectorWidth: inspector, assets: 1, selection: 0)
                let after = makeBar(window: window, inspectorWidth: inspector, assets: 999, selection: 45)
                print("jitter \(Int(window.width))x inspector \(inspector) assets 1/selected 0 →"
                      + " assets 999/selected 45")
                print("   before " + segments(before.statusCluster).map { describe($0.label) }.joined(separator: " | "))
                print("   after  " + segments(after.statusCluster).map { describe($0.label) }.joined(separator: " | "))
                print("   cluster before \(NSStringFromRect(before.statusCluster.frame))"
                      + " after \(NSStringFromRect(after.statusCluster.frame))")
            }
        }
    }

    // MARK: 5 · 只有库名被截（中间省略），计数与版本号完整

    func testLongLibraryNameIsMiddleTruncatedAndEverythingElseStaysWhole() {
        let revision = BuildStamp.revision
        let longName = String(repeating: "photons-library-backup-2026-10-27/", count: 2)
        XCTAssertGreaterThan(longName.count, 40)
        for inspector in [CGFloat(330), 300] {
            let bar = makeBar(window: windows[0], inspectorWidth: inspector, libraryName: longName)
            let cluster = bar.statusCluster
            let name = cluster.nameLabel
            let context = "inspector \(inspector)"

            XCTAssertEqual(name.toolTip, longName, "tooltip 要给全名 \(context)")
            XCTAssertTrue(name.stringValue.contains(TopBarStatusCluster.Metrics.ellipsis),
                          "库名要中间省略 \(context): \(name.stringValue)")
            XCTAssertLessThan(name.stringValue.count, longName.count, "截断只许变短")
            XCTAssertFalse(name.stringValue.hasPrefix(longName),
                           "中间省略：不能只是尾巴被切掉 \(name.stringValue)")
            XCTAssertTrue(longName.hasSuffix(String(name.stringValue.split(separator: "…").last ?? "")),
                          "中间省略要保留尾巴 \(name.stringValue)")
            // 计数与版本号一个字符都不许少。
            XCTAssertEqual(cluster.selectionLabel.stringValue.replacingOccurrences(
                of: TopBarStatusCluster.Metrics.figureSpace, with: ""), "已选 4")
            XCTAssertEqual(cluster.countLabel.stringValue.replacingOccurrences(
                of: TopBarStatusCluster.Metrics.figureSpace, with: ""), "45 张")
            XCTAssertEqual(cluster.revisionLabel.stringValue, revision)
            // 三段都没被裁：文本宽 ≤ frame 宽。
            for part in [(cluster.selectionLabel, "已选"), (cluster.countLabel, "张数"), (cluster.revisionLabel, "版本")] {
                XCTAssertLessThanOrEqual(textWidth(part.0), part.0.frame.width + 0.0001,
                                         "\(part.1) 被裁了 \(context)")
            }
            // 库名恰好用满上限（被截时）。
            let limit = cluster.nameWidthLimit(limit: cluster.widthLimit)
            XCTAssertLessThanOrEqual(name.frame.width, limit + 0.0001, "库名超上限 \(context)")
            XCTAssertGreaterThan(name.frame.width, limit - 12, "库名没吃满预算 \(context)")
            XCTAssertLessThanOrEqual(textWidth(name), name.frame.width + 0.0001, "截断后的库名自己也被吞 \(context)")
            print("truncate \(context): nameLimit=\(String(format: "%.2f", limit))"
                  + " nameActual=\(String(format: "%.2f", name.frame.width))"
                  + " textW=\(String(format: "%.4f", textWidth(name)))"
                  + " text=\"\(name.stringValue)\""
                  + " | 已选=\"\(cluster.selectionLabel.stringValue)\""
                  + " 张=\"\(cluster.countLabel.stringValue)\""
                  + " 版本=\"\(cluster.revisionLabel.stringValue)\""
                  + " clusterW=\(String(format: "%.2f", cluster.frame.width))")
        }
    }

    /// 检查器 300 宽：四段总宽 ≤ 300，且没有任何一段被裁（逐段给文本宽 ≤ frame 宽）。
    func testInspector300FitsTheWholeClusterWithoutClippingAnything() {
        let bar = makeBar(window: windows[1], inspectorWidth: 300)
        let cluster = bar.statusCluster
        XCTAssertLessThanOrEqual(cluster.frame.width, 300 + 0.0001,
                                 "四段总宽超过 300: \(NSStringFromRect(cluster.frame))")
        for part in segments(cluster) {
            XCTAssertLessThanOrEqual(textWidth(part.label), part.label.frame.width + 0.0001,
                                     "\(part.name) 在 300 宽的检查器里被裁了 \(describe(part.label))")
        }
        print("inspector300: clusterW=\(String(format: "%.2f", cluster.frame.width))"
              + " parts=" + segments(cluster).map {
                  "\($0.name) \(String(format: "%.4f", textWidth($0.label)))≤\(String(format: "%.4f", $0.label.frame.width))"
              }.joined(separator: " "))
    }

    // MARK: 6 · 反证（旧顺序 / 写死框宽 → 同一套断言必红）

    func testTheOldOrderAndPinnedWidthsFailTheseAssertions() {
        let bar = makeBar(window: windows[0], inspectorWidth: 330)
        let cluster = bar.statusCluster
        func ordered(_ labels: [NSTextField]) -> Bool {
            zip(labels, labels.dropFirst()).allSatisfy { $0.frame.minX < $1.frame.minX }
        }
        let real = segments(cluster).map(\.label)
        XCTAssertTrue(ordered(real), "四段顺序：已选 → 张数 → 库名 → 版本")
        // 旧顺序：`N 张` 在前。用同一条判据，必须红。
        let oldOrder = [cluster.countLabel, cluster.selectionLabel, cluster.nameLabel, cluster.revisionLabel]
        XCTAssertFalse(ordered(oldOrder), "反证：把 `N 张` 放回最前面，顺序断言立刻红")

        // 写死框宽：旧实现在 3 位补宽之后把计数框宽当常量用。4 位计数比它宽，
        // 于是"文本宽 ≤ frame 宽"这条必然红 —— 这就是固定锚点的下场。
        let pinnedBox = TopBarStatusCluster.Metrics.frameWidth(for: "\(TopBarStatusCluster.Metrics.padded(999, digits: 3)) 张")
        let widerText = TopBarStatusCluster.Metrics.width("1000 张")
        XCTAssertGreaterThan(widerText, pinnedBox, "4 位计数应当比 3 位的写死框宽")
        let wide = makeBar(window: windows[0], inspectorWidth: 330, assets: 1000, selection: 45)
        let count = wide.statusCluster.countLabel
        XCTAssertTrue(count.stringValue.contains("1000"))
        XCTAssertGreaterThanOrEqual(count.frame.width, TopBarStatusCluster.Metrics.width(count.stringValue),
                                    "写死框宽会让这条红（4 位计数被吞）")
        XCTAssertGreaterThan(count.frame.width, pinnedBox, "框宽跟着文本走，不是常量")
        XCTAssertEqual(wide.statusCluster.frame.maxX, wide.bounds.width - 16, accuracy: 0.001,
                       "右边缘仍然固定")
        print("counterProof: pinnedBox(999 张)=\(String(format: "%.4f", pinnedBox))"
              + " < width(1000 张)=\(String(format: "%.4f", widerText))"
              + " ≤ count.frame.width=\(String(format: "%.4f", count.frame.width))")
    }

    // MARK: 7 · 文案

    func testTextIsSelectionCountLibraryAndRevision() {
        let bar = makeBar(window: windows[0], inspectorWidth: 330,
                          assets: 45, selection: 4, libraryName: "photons-demo")
        let figure = TopBarStatusCluster.Metrics.figureSpace
        func plain(_ s: String) -> String { s.replacingOccurrences(of: figure, with: "") }

        XCTAssertEqual(plain(bar.statusCluster.selectionLabel.stringValue), "已选 4")
        XCTAssertEqual(plain(bar.statusCluster.countLabel.stringValue), "45 张")
        XCTAssertEqual(bar.statusCluster.nameLabel.stringValue, "photons-demo")
        XCTAssertEqual(bar.statusCluster.revisionLabel.stringValue, BuildStamp.revision)
        XCTAssertEqual(bar.statusCluster.nameLabel.toolTip, "photons-demo")

        let empty = makeBar(window: windows[0], inspectorWidth: 330,
                            assets: 0, selection: 0, libraryName: nil)
        XCTAssertEqual(plain(empty.statusCluster.selectionLabel.stringValue), "已选 0")
        XCTAssertEqual(plain(empty.statusCluster.countLabel.stringValue), "0 张")
        XCTAssertEqual(empty.statusCluster.nameLabel.stringValue, "未打开库")
        XCTAssertEqual(empty.statusCluster.revisionLabel.stringValue, BuildStamp.revision)
    }

    // MARK: 8 · 落在检查器列上方

    func testClusterStaysOverTheInspectorColumn() {
        for window in windows {
            for inspector in [CGFloat(364), 330, 300, 274, 244] {
                let column = CGRect(x: window.width - inspector, y: 0, width: inspector, height: 36)
                let bar = makeBar(window: window, inspectorWidth: inspector)
                let cluster = bar.statusCluster.frame
                let context = "\(Int(window.width))×\(Int(window.height)) inspector \(inspector)"

                XCTAssertGreaterThanOrEqual(cluster.minX, column.minX - 0.001,
                                            "簇的左边缘越过了检查器列左边 ①\(context) cluster \(NSStringFromRect(cluster))")
                XCTAssertLessThanOrEqual(cluster.maxX, column.maxX + 0.001, "簇的右边缘越过了列右边 ②\(context)")
                XCTAssertGreaterThanOrEqual(cluster.minX, bar.controlsTrailingEdge
                                            + TopBarStatusCluster.Metrics.minimumGapFromControls - 0.001,
                                            "簇压到了顶栏控件 ③\(context)")
                print("column \(context): cluster \(NSStringFromRect(cluster)) column \(NSStringFromRect(column))")
            }
        }
    }

    // MARK: 9 · 退化

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
        // 被顶到 limit 时，只有库名收窄；计数与版本号完整。
        XCTAssertLessThanOrEqual(bar.statusCluster.nameLabel.frame.width,
                                 TopBarStatusCluster.Metrics.nameMaxWidth + 0.0001)
        XCTAssertLessThanOrEqual(textWidth(bar.statusCluster.revisionLabel),
                                 bar.statusCluster.revisionLabel.frame.width + 0.0001)
        print("squeeze: cluster \(NSStringFromRect(bar.statusCluster.frame)) limitX \(limitX)"
              + " name=\"\(bar.statusCluster.nameLabel.stringValue)\""
              + " nameW=\(String(format: "%.2f", bar.statusCluster.nameLabel.frame.width))")

        // 连 40 pt 库名都放不下：整块隐藏，而不是剪碎或压住按钮。
        let tiny = TopBarView()
        tiny.frame = NSRect(x: 0, y: 0, width: 1600, height: 36)
        tiny.statusColumnWidth = 160
        tiny.update(mode: .grid, assetCount: 45, selectionCount: 4,
                    libraryName: "photons-demo", filmstrip: false)
        tiny.layoutSubtreeIfNeeded()
        XCTAssertTrue(tiny.statusCluster.isHidden || tiny.statusCluster.frame.width == 0,
                      "窄列要么隐藏要么为零宽: \(NSStringFromRect(tiny.statusCluster.frame))")
    }

    // MARK: 10 · 真窗口

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
            // 版本号（簇内最右一段）的右边缘也必须贴窗口右边 −16。
            let version = bar.statusCluster.revisionLabel.convert(bar.statusCluster.revisionLabel.bounds, to: root)
            XCTAssertEqual(version.maxX, root.bounds.width - TopBarStatusCluster.Metrics.trailingInset,
                           accuracy: 0.001, "版本号右边缘 \(context)")
            print("real \(context): cluster \(NSStringFromRect(cluster)) inspector \(NSStringFromRect(inspector))"
                  + " text \"\(bar.statusCluster.selectionLabel.stringValue)\""
                  + " \"\(bar.statusCluster.countLabel.stringValue)\""
                  + " \"\(bar.statusCluster.nameLabel.stringValue)\""
                  + " \"\(bar.statusCluster.revisionLabel.stringValue)\"")
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
