import XCTest
import AppKit
import SwiftUI
@testable import PhotonsUI

/// 派单 073 —— 检查器的**工作区切换器**：直方图下面一排五个图标按钮，决定滚动区里显示哪些卡片。
///
/// 用户 2026-10-27 的原话是这张清单：
///
/// | # | 工作区 | 图标 | 卡片 |
/// |---|---|---|---|
/// | 1 | 调整（默认） | `slider.horizontal.3` | 白平衡 / 黑电平 / Light / Color / 细节 / 曲线 / 预设（Decode 卡已删除，解码模型移入细节卡） |
/// | 2 | 变换 | `crop.rotate` | 裁切（2026-10-27：比例 / 角度 / 翻转 / 九宫格 / 应用取消） |
/// | 3 | 色彩 | `paintpalette` | —（HSL 未实现） |
/// | 4 | 蒙版 | `circle.dashed` | 蒙版 |
/// | 5 | 历史记录 | `clock.arrow.circlepath` | —（未实现） |
///
/// 这份文件钉四件事，而且尽量钉在**渲染出来的东西**上，不钉在愿望上：
///
///   1. **一张表**：`InspectorWorkspace.cards` 是唯一的「工作区 → 卡片」映射；`InspectorView` 用
///      `Section.allCases` 过滤它，所以顺序永远是枚举的顺序，工作区只能决定「有没有」。每个工作区
///      渲染出来的卡片序列由 `InspectorCardsProbe`（滚动区的读回点）报出来。
///   2. **切换器在直方图下方、滚动区上方**，五个按钮等宽、20 pt 高、244 pt 面板下不挤压 —— 量的是
///      `InspectorWorkspaceProbe` 的真实 frame（每个 tab 一个），不是算出来的。
///   3. **空工作区就是空**：没有卡片、没有占位、不崩、直方图照旧钉在顶部。
///   4. **工作区是视图态**：切遍五个工作区，`edit` / `editRevision` / `history.count` / `history.cursor`
///      一个都不许动。
///
/// 颜色那一组用 `ImageRenderer` 离屏渲染**这个控件本身**再采像素（060 的老办法）：选中 = 系统强调色，
/// 其余 = 次要色；没有图形上下文时 `XCTSkip`，源码/结构断言在此之前已经跑完。
@MainActor
final class InspectorWorkspaceTests: XCTestCase {

    private static let inspectorWidth: CGFloat = 330
    private static let panelHeight: CGFloat = 800

    // MARK: - 1. 一张表：五个工作区、顺序、各自的卡片

    func testTheFiveWorkspacesAndTheCardsEachOneShows() {
        XCTAssertEqual(InspectorWorkspace.allCases.map(\.rawValue),
                       ["adjust", "transform", "colour", "masks", "history"],
                       "工作区的顺序就是按钮从左到右的顺序（用户给的顺序）")
        XCTAssertEqual(InspectorWorkspace.allCases.map(\.title),
                       ["调整", "变换", "色彩", "蒙版", "历史记录"])
        XCTAssertEqual(InspectorWorkspace.allCases.map(\.symbol),
                       ["slider.horizontal.3", "crop.rotate", "paintpalette",
                        "circle.dashed", "clock.arrow.circlepath"])

        // 默认打开的是「调整」——这是用户的第一条要求。
        XCTAssertEqual(InspectorWorkspaceState().selection, .adjust, "首次打开必须是调整")
        // 调整 = 既有面板的卡片：蒙版 / 裁切 / HSL 各有自己的工作区，历史记录也有（077）。
        XCTAssertEqual(InspectorView.sections(in: .adjust),
                       InspectorView.scrollingSections.filter {
                           $0 != .masks && $0 != .crop && $0 != .angle && $0 != .hsl && $0 != .history
                               && $0 != .pointColor
                               && $0 != .colorGrading && $0 != .blackAndWhite
                       },
                       "调整 = 既有面板的卡片，只把蒙版 / 裁切 / HSL / 点颜色 / 色彩分级 / 黑白 / 历史记录交给各自的工作区")

        let titles = Dictionary(uniqueKeysWithValues: InspectorWorkspace.allCases.map {
            ($0, InspectorView.cardTitles(in: $0))
        })
        // 2026-10-28: 效果 (暗角 + 颗粒) joined 调整. 黑白 (S3.4) moved **out** of 调整 into 色彩
        // (user: 「黑白移动到色彩栏，不放在调整中」). 081 (2026-10-28): 预设 left the panel entirely —
        // 「预设卡片删掉，系统顶部菜单栏出现预设」 — so 调整 ends at 效果.
        XCTAssertEqual(titles[.adjust],
                       ["白平衡", "黑电平", "Light", "Color", "曲线", "细节", "校正", "效果"])
        XCTAssertEqual(titles[.masks], ["蒙版"])
        // 变换 有卡片了（裁切），色彩 有卡片了（HSL + 2026-10-28 的色彩分级），历史记录有卡片了（077）。
        XCTAssertEqual(titles[.transform], ["裁切", "旋转"])
        XCTAssertEqual(titles[.colour], ["HSL", "点颜色", "色彩分级", "黑白"],
                       "色彩工作区：HSL → 色彩分级 → 黑白（用户：黑白放在色彩分级下方）")
        XCTAssertEqual(titles[.history], ["历史记录"])

        // 图标必须有名字可念（.help 与 accessibilityLabel 都用它），空工作区的 tooltip 说明「尚未实现」。
        for workspace in InspectorWorkspace.allCases {
            XCTAssertTrue(workspace.help.hasPrefix(workspace.title),
                          "\(workspace.rawValue) 的 help 必须以中文名开头：\(workspace.help)")
            if !workspace.hasCards {
                XCTAssertTrue(workspace.help.contains("尚未实现"),
                              "空工作区的 tooltip 要说清楚它为什么是空的：\(workspace.help)")
            }
        }
        let report = InspectorWorkspace.allCases
            .map { "\($0.title)\($0.symbol) → \(titles[$0]!)" }
            .joined(separator: " · ")
        print("WORKSPACES · \(report)")
    }

    // MARK: - 2. 没有卡片会掉出表外，直方图谁也不能拿走

    /// 表是**唯一**的：每张滚动卡都至少属于一个工作区（否则它永远看不见，而且没人会发现）；没有工作区
    /// 能认领 `.histogram`（它钉在切换器上方，是参考读数，不是「哪个工作区的内容」）；每个工作区拿到的
    /// 顺序都是 `Section.allCases` 的顺序（工作区不能重排）。
    func testTheTableCoversEveryCardAndNoWorkspaceClaimsTheHistogram() {
        let scrolling = InspectorView.scrollingSections
        let claimable = Set(scrolling)
        var claimed: Set<InspectorView.Section> = []
        for workspace in InspectorWorkspace.allCases {
            let cards = workspace.cards
            XCTAssertFalse(cards.contains(.histogram),
                           "\(workspace.rawValue) 不许认领直方图：它钉在切换器上方，五个工作区都在")
            XCTAssertTrue(Set(cards).isSubset(of: claimable),
                          "\(workspace.rawValue) 认领了不在滚动区里的卡：\(cards)")
            XCTAssertEqual(Set(cards).count, cards.count, "\(workspace.rawValue) 里有重复卡片")
            // 顺序永远来自枚举，不来自这张表写的顺序。
            let expected = scrolling.filter { Set(cards).contains($0) }
            XCTAssertEqual(InspectorView.sections(in: workspace), expected,
                           "\(workspace.rawValue) 的渲染顺序必须与 Section.allCases 一致")
            claimed.formUnion(cards)
        }
        XCTAssertEqual(claimed, claimable,
                       "有卡片不属于任何工作区（永远看不见）：\(claimable.subtracting(claimed))")

        // 卡片枚举：Decode 删除后 9 张；裁切（变换）、HSL（色彩）、历史记录（077）各加一张 → 12 张；
        // 2026-10-28 效果（暗角 + 颗粒）再一张 → 13 张，黑白（S3.4）→ 14 张，色彩分级（S3.8）→ 15 张；
        // 081 (2026-10-28) 删掉 预设 卡 → 14 张；087 加 角度 卡 → 15 张；096 加 校正 卡 → 16 张；
        // 140 加 点颜色 卡 → 17 张。
        // 直方图仍排第一 —— 这张测试钉的是过滤，不是重排。
        XCTAssertEqual(InspectorView.Section.allCases.count, 17)
        XCTAssertEqual(Array(InspectorView.sectionTitles.prefix(3)), ["直方图", "白平衡", "黑电平"])
        // 077：历史记录排在最后（蒙版仍是它前面最后一张参数卡）。
        XCTAssertEqual(InspectorView.sectionTitles.suffix(2), ["蒙版", "历史记录"])
    }

    // MARK: - 3. 切换器的位置：直方图下方、滚动区上方

    func testTheSwitcherSitsBetweenTheHistogramAndTheScrollArea() throws {
        let panel = try host(width: Self.inspectorWidth, height: Self.panelHeight)
        defer { panel.window.contentView = nil }

        XCTAssertEqual(panel.tabs.count, 5, "五个按钮，一个不多一个不少")
        XCTAssertEqual(panel.tabs.map(\.workspace), InspectorWorkspace.allCases.map(\.rawValue),
                       "按钮从左到右 = 枚举顺序（按 frame.minX 读）")
        XCTAssertEqual(panel.tabs.map(\.title), ["调整", "变换", "色彩", "蒙版", "历史记录"])

        // 直方图 → 切换器 → 滚动区，三条边都成立，而且切换器在两者之间（不在滚动区里）。
        XCTAssertLessThan(panel.histogramPlot.maxY, panel.tabsTop,
                          "切换器必须在直方图卡下方（plot 底 \(panel.histogramPlot.maxY) vs 按钮顶 \(panel.tabsTop)）")
        XCTAssertLessThanOrEqual(panel.tabsBottom, panel.scrollViewport.minY,
                                 "切换器必须在滚动区上方（按钮底 \(panel.tabsBottom) vs 视口顶 \(panel.scrollViewport.minY)）")
        XCTAssertLessThanOrEqual(panel.tabRowHeight, 24,
                                 "切换器行高 \(panel.tabRowHeight) pt —— 「高度尽量小」")
        // 直方图 plot 底 → 视口顶 = 10（卡片自己的 cardInsetV）+ 10（面板间距）+ 20（按钮）+ 10（面板间距）。
        XCTAssertEqual(panel.switcherFootprint, 20 + 3 * 10, accuracy: 0.51,
                       "切换器只花掉 20 pt 按钮 + 它上下各 10 pt 的面板间距："
                       + "\(panel.switcherFootprint) pt")
        // 直方图仍然只有一份，而且在滚动区外面。
        XCTAssertEqual(panel.histogramCards, 1)

        let frames = panel.tabs
            .map { NSString(format: "(%.1f, %.1f, %.1f×%.1f)",
                            $0.frame.minX, $0.frame.minY, $0.frame.width, $0.frame.height) as String }
            .joined(separator: " ")
        print(String(format: "SWITCHER frames · row h %.2f, buttons %@ · histogram plot maxY %.2f"
                     + " · tabs %.2f…%.2f · viewport y %.2f",
                     panel.tabRowHeight, frames,
                     panel.histogramPlot.maxY, panel.tabsTop, panel.tabsBottom,
                     panel.scrollViewport.minY))
    }

    /// **244 pt 面板**（比 `WorkspaceLayout.inspectorWidthMin` 的 300 还窄 56 pt）下五个图标不挤压、
    /// 不截断、不重叠：等宽、每个都装得下 11 pt 的字形、整行落在面板内缩 12 pt 的内容宽里。
    func testTheFiveTabsDoNotClipAtTheNarrowestPanel() throws {
        var lines: [String] = []
        for width in [244 as CGFloat, 300, 330, WorkspaceLayout.inspectorWidthMax] {
            let panel = try host(width: width, height: Self.panelHeight)
            defer { panel.window.contentView = nil }
            let content = width - 2 * 12

            XCTAssertEqual(panel.tabs.count, 5, "\(width) pt 下少了按钮")
            let widths = panel.tabs.map(\.frame.width)
            for w in widths {
                XCTAssertEqual(w, widths[0], accuracy: 0.51, "\(width) pt 下五个按钮必须等宽：\(widths)")
                XCTAssertGreaterThanOrEqual(w, 20, "\(width) pt 下一个按钮只剩 \(w) pt，装不下图标")
            }
            XCTAssertEqual(panel.tabs.first?.frame.minX ?? -1, 12, accuracy: 0.51,
                           "整行从面板内缩 12 pt 处开始")
            XCTAssertEqual(panel.tabs.last?.frame.maxX ?? -1, width - 12, accuracy: 0.51,
                           "整行在面板内缩 12 pt 处结束（不越界、不截断）")
            XCTAssertEqual(panel.tabs.map(\.frame.height), Array(repeating: 20, count: 5),
                           "五个按钮同高 20 pt")
            // 不重叠：每一个的 minX 都在前一个的 maxX 右边（允许 2 pt 间距）。
            for (a, b) in zip(panel.tabs, panel.tabs.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.frame.minX, a.frame.maxX,
                                            "\(width) pt 下按钮重叠：\(a.frame) / \(b.frame)")
            }
            XCTAssertLessThanOrEqual(panel.tabs.last!.frame.maxX - panel.tabs.first!.frame.minX, content,
                                     "整行 \(panel.tabs.last!.frame.maxX - panel.tabs.first!.frame.minX)"
                                     + " pt 超过内容宽 \(content) pt")
            lines.append("\(Int(width)) pt → \(widths.map { String(format: "%.1f", $0) }.joined(separator: "/"))")
        }
        print("SWITCHER widths · \(lines.joined(separator: " · "))")
    }

    /// SF Symbol 名必须**本机解析得出来**：`NSImage(systemSymbolName:)` 对不存在的名字回 `nil`，
    /// 那样按钮就是一片空白（用户点得到，看不见）。所以逐个问系统，再问视图自己报的那一份。
    func testEverySymbolResolvesOnThisMachine() throws {
        for workspace in InspectorWorkspace.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: workspace.symbol, accessibilityDescription: nil),
                            "SF Symbol 「\(workspace.symbol)」（\(workspace.title)）在本机解析不出来")
        }
        let panel = try host(width: Self.inspectorWidth, height: Self.panelHeight)
        defer { panel.window.contentView = nil }
        for tab in panel.tabs {
            XCTAssertTrue(tab.symbolResolves,
                          "\(tab.workspace) 的图标 \(tab.symbol) 在视图里解析成了 nil")
        }
        // 探针不许吃点击：它是整块 tab 大小，`hitTest` 必须回 nil。
        XCTAssertNil(panel.tabProbes.first?.hitTest(.zero), "tab 的读回探针不能挡住按钮的点击")
    }

    // MARK: - 4. 默认「调整」：渲染出来的卡片序列

    func testThePanelOpensInAdjustAndRendersItsCardsInOrder() throws {
        let panel = try host(width: Self.inspectorWidth, height: Self.panelHeight)
        defer { panel.window.contentView = nil }

        XCTAssertEqual(panel.cards.workspace, "adjust", "首次打开必须是调整")
        XCTAssertEqual(panel.cards.cardIDs, InspectorView.sections(in: .adjust).map(\.rawValue))
        // 2026-10-28 (user): 黑白 moved to the 色彩 workspace. 081: 预设 card deleted, so 调整 has
        // seven cards and the panel's last card is 效果.
        XCTAssertEqual(panel.cards.cardTitles,
                       ["白平衡", "黑电平", "Light", "Color", "曲线", "细节", "校正", "效果"])
        // 真的渲染出来了，不只是表里有：调整工作区里蒙版卡不在树上，白平衡的数值框在。
        XCTAssertTrue(panel.numberFields > 0, "调整工作区里应该有真的控件（数值框），实际 \(panel.numberFields)")
        XCTAssertEqual(panel.maskCards, 0, "调整工作区里不该有蒙版卡")
        print("CARDS adjust · \(panel.cards.cardTitles) · number fields \(panel.numberFields)")
    }

    // MARK: - 5. 切到「蒙版」：只剩蒙版卡，直方图还钉在顶部

    func testSwitchingToMasksLeavesOnlyTheMaskCardAndKeepsTheHistogramPinned() throws {
        let panel = try host(width: Self.inspectorWidth, height: Self.panelHeight)
        defer { panel.window.contentView = nil }
        let plotBefore = panel.histogramPlot
        let viewportBefore = panel.scrollViewport

        panel.state.select(.masks)
        try waitFor(panel, until: { $0.cards.cardIDs == ["masks"] })

        XCTAssertEqual(panel.cards.cardIDs, ["masks"], "蒙版工作区只放蒙版卡")
        XCTAssertEqual(panel.cards.cardTitles, ["蒙版"])
        XCTAssertEqual(panel.maskCards, 1, "蒙版卡是真的在树上（MaskPanelProbe）")
        XCTAssertEqual(panel.numberFields, 0, "调整工作区的滑杆行必须已经离开树")

        // 直方图没被藏起来，也没被移动 —— 它钉在切换器上方，五个工作区都在。
        XCTAssertEqual(panel.histogramCards, 1, "直方图不许被工作区藏起来")
        XCTAssertEqual(panel.histogramPlot.minY, plotBefore.minY, accuracy: 0.001)
        XCTAssertEqual(panel.histogramPlot.height, plotBefore.height, accuracy: 0.001)
        // 切换器也没动（它不属于任何工作区）。
        XCTAssertEqual(panel.scrollViewport.minY, viewportBefore.minY, accuracy: 0.001)
        XCTAssertLessThan(panel.histogramPlot.maxY, panel.tabsTop)
        print("CARDS masks · \(panel.cards.cardTitles) · histogram y \(panel.histogramPlot.minY)"
              + " (was \(plotBefore.minY)) · mask cards \(panel.maskCards)")
    }

    // MARK: - 6. 空工作区：没有卡片、没有占位、不崩、直方图还在

    func testEveryWorkspaceDrawsExactlyItsTableAndNeverHidesTheHistogram() throws {
        let panel = try host(width: Self.inspectorWidth, height: Self.panelHeight)
        defer { panel.window.contentView = nil }
        let plot = panel.histogramPlot

        // 077 之后**没有空工作区了**：五个都有卡。这条用例原先钉「空工作区不画占位、不抢直方图」，
        // 现在钉它更强的一面：屏幕上画出来的卡片**正好**是表里那几张（多一张就是占位，少一张就是丢卡）。
        for workspace in InspectorWorkspace.allCases {
            panel.state.select(workspace)
            try waitFor(panel, until: { $0.cards.workspace == workspace.rawValue })

            XCTAssertEqual(panel.cards.cardIDs, InspectorView.sections(in: workspace).map(\.rawValue),
                           "\(workspace.title) 画出来的卡必须**正好**是表里那几张（多＝占位，少＝丢卡）")
            XCTAssertEqual(panel.histogramCards, 1, "\(workspace.title)：直方图仍然在")
            XCTAssertEqual(panel.histogramPlot.minY, plot.minY, accuracy: 0.001)
            // 滚动内容的高度就是卡片本身的高度：没有占位大图，也没有「尚未实现」的文案块。
            XCTAssertGreaterThan(panel.cards.frame.height, 15, "\(workspace.title) 有卡就该有高度")
            XCTAssertNil(panel.tabs.first { $0.isSelected && $0.workspace != workspace.rawValue },
                         "\(workspace.title) 必须是唯一选中的那个")
            XCTAssertEqual(panel.tabs.filter(\.isSelected).map(\.workspace), [workspace.rawValue])
            print(String(format: "CARDS %@ · %@ · doc h %.2f · histogram still at y %.2f",
                         workspace.rawValue, "\(panel.cards.cardIDs)",
                         panel.cards.frame.height, panel.histogramPlot.minY))
        }
    }

    // MARK: - 7. 工作区是视图态：不写文档、不产生历史

    func testSwitchingWorkspacesTouchesNoDocumentAndNoHistory() throws {
        let session = CatalogSession()
        // 先让文档不是初始状态，这样「没被改」才有意义（也证明 revision 不是一直为 0）。
        session.applyEdit { $0.light.exposure = 0.75 }
        session.commitEdit(label: "曝光")

        let revision = session.editRevision
        let edit = session.edit
        let historyCount = session.history.count
        let historyCursor = session.history.cursor
        let seq = session.history.currentSnapshot?.seq
        XCTAssertGreaterThan(revision, 0)
        // An unloaded session seeds no「Original」snapshot, so the commit above is snapshot #1 and the
        // undo stack is non-trivial —「1 → 1」afterwards therefore means「没多一条」, not「一直是空的」.
        XCTAssertEqual(historyCount, 1)
        XCTAssertEqual(session.history.currentSnapshot?.label.isEmpty, false)

        let state = InspectorWorkspaceState()
        XCTAssertEqual(state.selection, .adjust)
        let panel = try host(width: Self.inspectorWidth, height: Self.panelHeight,
                             session: session, state: state)
        defer { panel.window.contentView = nil }

        var sequences: [String] = []
        for workspace in InspectorWorkspace.allCases + [.adjust] {
            state.select(workspace)
            _ = try waitFor(panel, until: { $0.cards.workspace == workspace.rawValue })
            sequences.append("\(workspace.title)\(panel.cards.cardTitles)")

            XCTAssertEqual(state.selection, workspace)
            XCTAssertEqual(session.editRevision, revision,
                           "切到 \(workspace.title) 让 editRevision 动了 → 说明它写了文档")
            XCTAssertEqual(session.edit, edit, "切到 \(workspace.title) 改了文档")
            XCTAssertEqual(session.history.count, historyCount,
                           "切到 \(workspace.title) 产生了历史：\(historyCount) → \(session.history.count)")
            XCTAssertEqual(session.history.cursor, historyCursor)
            XCTAssertEqual(session.history.currentSnapshot?.seq, seq)
        }
        // 工作区不在文档里：`EditModel` 是 Codable 的文档，切完序列化结果与切换前逐字节相同。
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(session.edit), try encoder.encode(edit))
        print("CARDS rendered per workspace · " + sequences.joined(separator: " · "))
        print("WORKSPACES inert · revision \(revision) → \(session.editRevision)"
              + " · history \(historyCount) → \(session.history.count)"
              + " · cursor \(historyCursor) → \(session.history.cursor)")
    }

    // MARK: - 8. 颜色：选中 = 系统强调色，未选中 = 次要色

    /// **为什么这条不直接渲染那五个图标**：`Image(systemName:)` 在一个没有 app bundle 的测试进程里
    /// 画出来的不是符号，而是系统的「禁止」占位图（实测：黄底 + 红圈斜杠的方片）——`NSImage` 能解析、
    /// `Image` 却画不出，所以采那排图标的像素只会采到占位色。于是这一条分两半：
    ///
    ///   · 结构那一半钉**接线**：按钮的 `foregroundStyle` 只能是 `Self.tint(workspace, selected:)`，
    ///     而那个函数只能是「选中 = `Color.accentColor`，其余 = `Color.secondary`」；
    ///   · 像素那一半渲染**同一个函数**的两个结果（不是测试里的复制品：改掉 `tint` 这两块颜色就变），
    ///     断言选中那块就是系统强调色（逐通道 ≤ 24，与 060 的容差一致），未选中那块是灰的
    ///     （三通道差 ≤ 2），两者必须看得出来不同。
    func testTheSelectedTabIsTheSystemAccentAndTheOthersAreSecondary() throws {
        let source = try String(contentsOf: Self.tabsSource, encoding: .utf8)
        XCTAssertTrue(source.contains(".foregroundStyle(Self.tint(workspace, selected: selection))"),
                      "颜色只能从 tint(_:selected:) 来 —— 切换器里唯一的配色决定")
        XCTAssertTrue(source.contains("workspace == selected ? Color.accentColor : Color.secondary"),
                      "选中 = 系统强调色（与 060/071 的「默认参数色」一致），未选中 = 次要色")
        XCTAssertTrue(source.contains(".fill(Color.accentColor.opacity(Self.selectionOpacity))"),
                      "选中态的底色也是强调色（同一次选择，同一种颜色）")
        XCTAssertTrue(source.contains(".help(workspace.help)"), "每个按钮都要有 .help")
        XCTAssertTrue(source.contains(".accessibilityLabel(workspace.title)"),
                      "每个按钮都要有中文 accessibilityLabel")

        guard let pixels = Self.renderTints(selected: .masks) else {
            throw XCTSkip("ImageRenderer 拿不到 CGImage（本机没有可用的离屏图形上下文）：像素那一半跳过")
        }
        let accent = Self.systemAccent
        let selected = try XCTUnwrap(Self.modal(pixels, columns: 0 ..< 40), "选中态那块没有不透明像素")
        let unselected = try XCTUnwrap(Self.modal(pixels, columns: 40 ..< 80), "未选中态那块没有不透明像素")

        guard accent.b >= accent.r else {
            throw XCTSkip("系统强调色不是蓝的（\(accent)）—— 跟随系统，非蓝主题下这条无法断言")
        }
        XCTAssertLessThanOrEqual(abs(selected.r - accent.r), 24, "选中态 R：\(selected) vs \(accent)")
        XCTAssertLessThanOrEqual(abs(selected.g - accent.g), 24, "选中态 G：\(selected) vs \(accent)")
        XCTAssertLessThanOrEqual(abs(selected.b - accent.b), 24, "选中态 B：\(selected) vs \(accent)")
        XCTAssertLessThanOrEqual(max(unselected.r, max(unselected.g, unselected.b))
                                 - min(unselected.r, min(unselected.g, unselected.b)), 2,
                                 "未选中态必须是灰的（次要色），实测 \(unselected)")
        // 灰，不是黑也不是白：次要色在面板底色上是一层中灰（实测 128,128,128）。
        XCTAssertTrue((60 ... 220).contains(unselected.r),
                      "未选中态的中灰不该这么暗/这么亮：\(unselected)")
        let distance = abs(selected.r - unselected.r) + abs(selected.g - unselected.g)
            + abs(selected.b - unselected.b)
        XCTAssertGreaterThanOrEqual(distance, 150, "选中与未选中必须一眼看得出不同（三通道差 \(distance)/765）")
        print("TAB colour · selected \(selected) vs system accent \(accent)"
              + " · unselected \(unselected) · distance \(distance)")
    }

    // MARK: - 9b. 切回来时滚动位置不保证保留（说明 + 实测）

    /// 用户只要求「滚到哪里」不必保留，所以这里钉的是**不崩、不越界**，并把实测值打出来：
    ///
    /// 切走时（蒙版工作区的内容更短）`NSScrollView` 会把偏移夹到新内容里；切回来时 SwiftUI 不会把旧的
    /// 偏移还回去 —— 面板停在夹过之后的位置。也就是说：**切回来不保证回到原来的滚动位置**，这是有意
    /// 的（工作区是视图态，恢复一个不属于它的滚动历史没有意义），但偏移永远是「当前文档里的合法值」。
    func testSwitchingAwayAndBackLeavesTheScrollOffsetLegalButNotRestored() throws {
        let panel = try host(width: Self.inspectorWidth, height: 420)
        defer { panel.window.contentView = nil }
        let scroll = try XCTUnwrap(Panel.views(of: "HostingScrollView", in: panel.host).first
                                   as? NSScrollView, "the hosting scroll view is not an NSScrollView")
        let maxOffset = max(0, scroll.documentView!.frame.height - scroll.contentView.bounds.height)
        XCTAssertGreaterThan(maxOffset, 200, "调整工作区在 420 pt 窗口里必须能滚 200 pt 以上")

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        scroll.reflectScrolledClipView(scroll.contentView)
        panel.host.layoutSubtreeIfNeeded()
        let scrolled = scroll.contentView.bounds.origin.y
        XCTAssertEqual(scrolled, 200, accuracy: 0.5)

        panel.state.select(.masks)
        _ = try waitFor(panel, until: { $0.cards.cardIDs == ["masks"] })
        let inMasks = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThanOrEqual(inMasks, 0, "切到蒙版后偏移越界（负）")
        XCTAssertLessThanOrEqual(inMasks, 200 + 0.5, "切到蒙版后偏移比原来还大")

        panel.state.select(.adjust)
        _ = try waitFor(panel, until: { $0.cards.cardIDs.count == 9 })
        let back = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThanOrEqual(back, 0, "切回调整后偏移越界（负）")
        XCTAssertLessThanOrEqual(back, maxOffset + 0.5, "切回调整后偏移超过了文档能滚的范围")
        print(String(format: "SCROLL · adjust offset 200 → masks %.1f → adjust %.1f (max %.1f);"
                     + " 不保证回到 200，只保证落在 [0, max]", inMasks, back, maxOffset))
    }

    // MARK: - 9. 源码：过滤 + 一张表，不逐卡写 if

    func testTheScrollAreaFiltersOneTableInsteadOfBranchingPerCard() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("ForEach(visibleSections)"),
                      "滚动区必须迭代过滤后的工作区卡片，不是 allCases")
        XCTAssertTrue(source.contains("private var visibleSections: [Section] { Self.sections(in: workspaces.selection) }"),
                      "过滤只有一处")
        XCTAssertTrue(source.contains("let included = Set(workspace.cards)"),
                      "工作区只决定成员：集合来自唯一的 cards 表")
        // 没有哪张卡自己在外面套一个「当前工作区是 …」的判断。
        XCTAssertEqual(Self.occurrences(of: "workspaces.selection ==", in: source), 0,
                       "不许在卡片外层写 if selection == …：过滤在 ForEach 一处")
        XCTAssertFalse(source.contains("case .transform: return"), "Section 里不许为工作区加卡片")

        let tabs = try String(contentsOf: Self.tabsSource, encoding: .utf8)
        XCTAssertTrue(tabs.contains("public var cards: [InspectorView.Section]"),
                      "唯一一张「工作区 → 卡片」表在 InspectorWorkspace.cards")
        XCTAssertTrue(tabs.contains("case .transform:\n            // 2026-10-27 — 裁切."),
                      "变换 认领裁切卡（2026-10-27：卡片从菜单/浮动栏搬进了工作区）")
        XCTAssertTrue(tabs.contains("return [.crop, .angle]"),
                      "变换工作区的第一张卡 = 裁切，087 起第二张 = 角度")
    }

    // MARK: - harness

    private struct Tab {
        var workspace: String
        var title: String
        var symbol: String
        var symbolResolves: Bool
        var isSelected: Bool
        var frame: CGRect
    }

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let state: InspectorWorkspaceState

        // Live reads, every one of them: the panel is switched *after* it is hosted, so anything
        // cached at `host()` time would describe 调整 forever (the first version of this harness did
        // exactly that and reported "mask cards 0" for a mask card that was on screen).

        var histogramCards: Int { Panel.views(of: "HistogramCardView", in: host).count }
        var histogramPlot: CGRect {
            Panel.views(of: "HistogramCardView", in: host).first
                .map { $0.convert($0.bounds, to: host) } ?? .null
        }
        var scrollViewport: CGRect {
            Panel.views(of: "HostingScrollView", in: host).first
                .map { $0.convert($0.bounds, to: host) } ?? .null
        }
        /// The number boxes the panel built — real `NSTextField`s, so 「调整工作区的滑杆行真的在树上」
        /// is a count and not a claim.
        var numberFields: Int { Panel.views(of: "NumberTextField", in: host).count }
        var maskCards: Int { Panel.views(of: "MaskPanelProbe", in: host).count }
        var cards: InspectorCardsProbe { Self.probe(host) }
        var tabProbes: [InspectorWorkspaceProbe] {
            Self.views(of: "InspectorWorkspaceProbe", in: host)
                .compactMap { $0 as? InspectorWorkspaceProbe }
                .sorted { $0.frame.minX < $1.frame.minX }
        }
        var tabs: [Tab] {
            tabProbes.map {
                Tab(workspace: $0.workspace, title: $0.title, symbol: $0.symbol,
                    symbolResolves: $0.symbolResolves, isSelected: $0.isSelected,
                    frame: $0.convert($0.bounds, to: host))
            }
        }
        var tabRowHeight: CGFloat {
            let frames = tabs.map(\.frame)
            guard let top = frames.map(\.minY).min(), let bottom = frames.map(\.maxY).max() else { return -1 }
            return bottom - top
        }
        var tabsTop: CGFloat { tabs.map(\.frame.minY).min() ?? -1 }
        var tabsBottom: CGFloat { tabs.map(\.frame.maxY).max() ?? -1 }
        /// 直方图 plot 底 → 滚动视口顶 = 切换器 + 面板自己的两段 10 pt 间距。
        var switcherFootprint: CGFloat { scrollViewport.minY - histogramPlot.maxY }

        private static func probe(_ host: NSView) -> InspectorCardsProbe {
            views(of: "InspectorCardsProbe", in: host).compactMap { $0 as? InspectorCardsProbe }.first
                ?? InspectorCardsProbe(frame: .zero)
        }

        static func views(of className: String, in root: NSView) -> [NSView] {
            var found: [NSView] = []
            if String(describing: type(of: root)) == className { found.append(root) }
            for sub in root.subviews { found += views(of: className, in: sub) }
            return found
        }
    }

    private func host(width: CGFloat, height: CGFloat,
                      session: CatalogSession? = nil,
                      state: InspectorWorkspaceState? = nil) throws -> Panel {
        _ = NSApplication.shared
        let session = session ?? CatalogSession()
        let state = state ?? InspectorWorkspaceState()
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        let panel = Panel(host: host, window: window, state: state)
        XCTAssertNotEqual(panel.histogramPlot, .null, "直方图不在树上")
        XCTAssertNotEqual(panel.scrollViewport, .null, "滚动视口不在树上")
        return panel
    }

    /// 等一个状态最多 2 s，用轮询而不是睡固定时长（CI 上布局可能比一帧慢）。
    @discardableResult
    private func waitFor(_ panel: Panel, until predicate: (Panel) -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            panel.host.layoutSubtreeIfNeeded()
            if predicate(panel) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        panel.host.layoutSubtreeIfNeeded()
        return predicate(panel)
    }

    // MARK: - pixel helpers (060's toolbox)

    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static var tabsSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorWorkspaceTabs.swift")
    }

    private static var systemAccent: RGB {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return RGB(r: Int((color.redComponent * 255).rounded()),
                   g: Int((color.greenComponent * 255).rounded()),
                   b: Int((color.blueComponent * 255).rounded()))
    }

    /// 离屏渲染**面板自己的配色函数**的两个结果：左 40 pt 是「选中的那个」，右 40 pt 是「没选中的那个」。
    ///
    /// 渲染的是 `InspectorWorkspaceTabs.tint(_:selected:)` 本身 —— 改掉它，这两块像素就跟着变；
    /// 测试里没有第二份颜色字面量。
    private static func renderTints(selected: InspectorWorkspace) -> Pixels? {
        let swatches = ZStack {
            // 次要色是**语义色**：它按着它所在的面解析（面板上是一层灰）。所以在面板底色上采，
            // 不然采到的是「次要色叠在黑底上」= 黑。
            Color(nsColor: .windowBackgroundColor)
            HStack(spacing: 0) {
                Rectangle()
                    .fill(InspectorWorkspaceTabs.tint(selected, selected: selected))
                    .frame(width: 40, height: 20)
                Rectangle()
                    .fill(InspectorWorkspaceTabs.tint(InspectorWorkspace.allCases.first { $0 != selected }!,
                                                      selected: selected))
                    .frame(width: 40, height: 20)
            }
        }
        let renderer = ImageRenderer(content: swatches)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { return nil }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let width = image.width, height = image.height
        guard width >= 80, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
    }

    /// 一段列里的主色（不透明像素的众数）—— 两块都是实心矩形，所以这个值就是那块的颜色。
    private static func modal(_ pixels: Pixels, columns: Range<Int>) -> RGB? {
        var histogram: [Int: Int] = [:]
        for y in 0 ..< pixels.height {
            for x in columns where x < pixels.width {
                let i = (y * pixels.width + x) * 4
                guard Int(pixels.bytes[i + 3]) > 200 else { continue }
                let r = Int(pixels.bytes[i]), g = Int(pixels.bytes[i + 1]), b = Int(pixels.bytes[i + 2])
                histogram[(r << 16) | (g << 8) | b, default: 0] += 1
            }
        }
        guard let best = histogram.max(by: { $0.value < $1.value }) else { return nil }
        let packed = best.key
        return RGB(r: (packed >> 16) & 0xFF, g: (packed >> 8) & 0xFF, b: packed & 0xFF)
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var rest = haystack[...]
        while let range = rest.range(of: needle) {
            count += 1
            rest = rest[range.upperBound...]
        }
        return count
    }
}
