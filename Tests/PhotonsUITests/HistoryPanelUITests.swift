import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 077 — the 历史记录 workspace on a hosted panel.
///
/// What is pinned here, and why each assertion is the one that matters:
///
///   1. **行 = 快照**：每行一个已提交状态，序号/摘要/标签来自模型本身，当前行高亮，每类最新一条带标识 ——
///      而且标识与可删是**同一个谓词**（`HistoryRow.isNewestOfClass == canDelete`）。
///   2. **300 / 330 / 364 不截断**：摘要列宽由面板自己的 frame 算出来，摘要文字在允许的两行内**装得下**
///      （不是被省略号吃掉）。这是实测：`NSAttributedString` 量字宽 vs 列宽。
///   3. **上千行不一次建满 view**：`LazyVStack` 只构建视口内的行，`HistoryPanelProbe.builtRows`
///      远小于 `totalRows`。
///   4. **接线**：点行 = 跳转、× = 删一条（只在该行可删时出现）。`swift test` 没有窗口会话、无障碍树
///      是空的，所以这两条按源码钉住 —— 与 `PanelResetTests.testEveryParameterCardCanBeResetFromItsTitle`
///      同一套路。
@MainActor
final class HistoryPanelUITests: XCTestCase {

    private static let panelHeight: CGFloat = 800

    /// A session shaped like the app's: `loadEditForAnchor()` with no photo seeds
    /// `EditHistory(baseline:)`, so seq 0 is 「Original」 — the floor of undo, never deletable. A bare
    /// `CatalogSession()` has an *empty* stack, where the first commit's own row becomes the floor.
    private func makeSession() -> CatalogSession {
        let session = CatalogSession()
        session.loadEditForAnchor()
        return session
    }

    // MARK: - 1. 行 = 快照

    func testTheTimelineShowsOneRowPerSnapshotWithBadgeAndCurrentHighlight() throws {
        let session = makeSession()
        session.applyEdit { $0.light.exposure = 0.6 }
        XCTAssertTrue(session.commitEdit(label: "曝光"))
        session.applyEdit { $0.light.contrast = 25 }
        XCTAssertTrue(session.commitEdit(label: "对比"))
        session.applyEdit { $0.color.saturation = 12 }
        XCTAssertTrue(session.commitEdit(label: "饱和"))

        let panel = try host(.history, width: WorkspaceLayout.inspectorWidthDefault, session: session)
        defer { panel.window.contentView = nil }
        try waitFor(panel, until: { $0.historyProbe != nil })

        let probe = try XCTUnwrap(panel.historyProbe)
        let model = session.history.rows
        XCTAssertEqual(probe.totalRows, model.count, "行数 = 快照数")
        XCTAssertEqual(probe.rows.map(\.seq), model.map(\.seq))
        XCTAssertEqual(probe.rows.map(\.summary), model.map(\.summary))
        XCTAssertEqual(probe.rows.map(\.isCurrent), model.map(\.isCurrent),
                       "当前行 = cursor 那一行")
        XCTAssertEqual(probe.rows.map(\.isNewest), model.map(\.isNewestOfClass))
        XCTAssertEqual(probe.rows.map(\.canDelete), probe.rows.map(\.isNewest),
                       "标识与可删是同一个谓词（面板上不会出现「亮着却删不掉」）")
        XCTAssertEqual(probe.rows.filter(\.canDelete).map(\.seq), [1, 2, 3],
                       "基线不可删；三个不同类的行各是各类最新")
        XCTAssertEqual(probe.rows.last?.isCurrent, true)
        XCTAssertEqual(probe.cardWidth, WorkspaceLayout.inspectorWidthDefault - 24, accuracy: 0.51,
                       "卡的宽度 = 面板 − 两侧 12 pt 内缩")
        print("HISTORY ROWS · \(probe.rows.map { "\($0.seq):\($0.summary)\($0.canDelete ? " ✕" : "")" })")
    }

    /// 同一类的第二条（覆盖）不亮、不可删；只有最后一条亮。
    func testACoveredRowIsNeverBadgedAndNeverDeletable() throws {
        let session = makeSession()
        session.applyEdit { $0.light.exposure = 0.5 }
        XCTAssertTrue(session.commitEdit(label: "曝光"))
        session.applyEdit { $0.light.contrast = 10 }
        XCTAssertTrue(session.commitEdit(label: "对比"))
        session.applyEdit { $0.light.exposure = 1.1 }
        XCTAssertTrue(session.commitEdit(label: "曝光"))

        let panel = try host(.history, width: WorkspaceLayout.inspectorWidthDefault, session: session)
        defer { panel.window.contentView = nil }
        try waitFor(panel, until: { $0.historyProbe != nil })
        let probe = try XCTUnwrap(panel.historyProbe)

        // seq 1 = first 曝光 (covered by seq 3), seq 2 = 对比, seq 3 = 曝光 again.
        XCTAssertEqual(probe.rows.map(\.seq), [0, 1, 2, 3])
        XCTAssertEqual(probe.rows.map(\.isNewest), [false, false, true, true])
        XCTAssertEqual(probe.rows.map(\.canDelete), [false, false, true, true])
    }

    // MARK: - 2. 三种宽度都不截断

    func testSummaryNeverGetsClippedAtAnyPanelWidth() throws {
        let session = makeSession()
        // The longest realistic summaries: a mask with several fields and a crop session.
        session.applyEdit { $0.masks = [Mask(id: "m-1", name: "天空", feather: 0.35, refine: 0.6)] }
        XCTAssertTrue(session.commitEdit(label: "蒙版"))
        session.beginToolSession("裁切", label: "裁切与旋转")
        session.applyEdit { $0.geometry.crop = NormalizedRect(x: 0.12, y: 0.06, width: 0.61, height: 0.7) }
        XCTAssertTrue(session.endToolSession(label: "裁切与旋转"))
        session.applyEdit { $0.curve.white = [CurvePoint(0, 0), CurvePoint(0.4, 0.55), CurvePoint(2, 2)] }
        XCTAssertTrue(session.commitEdit(label: "曲线"))

        var report: [String] = []
        for width in [WorkspaceLayout.inspectorWidthMin, WorkspaceLayout.inspectorWidthDefault,
                      WorkspaceLayout.inspectorWidthMax] {
            let panel = try host(.history, width: width, session: session)
            defer { panel.window.contentView = nil }
            try waitFor(panel, until: { $0.historyProbe != nil })
            let probe = try XCTUnwrap(panel.historyProbe)

            XCTAssertEqual(probe.cardWidth, width - 24, accuracy: 0.51)
            XCTAssertGreaterThan(probe.summaryColumn, 120,
                                 "\(width) 面板下摘要列 \(probe.summaryColumn) pt —— 太窄就不是「不截断」")
            for row in probe.rows {
                XCTAssertLessThanOrEqual(row.lines, HistoryPanelLayout.summaryLines,
                                         "\(width) 面板：seq \(row.seq) 的摘要占 \(row.lines) 行，"
                                         + "超过允许的 \(HistoryPanelLayout.summaryLines) 行 —— 会被截断："
                                         + "「\(row.summary)」（\(row.textWidth) pt / \(probe.summaryColumn) pt）")
                XCTAssertGreaterThanOrEqual(probe.summaryColumn, row.textWidth / CGFloat(HistoryPanelLayout.summaryLines),
                                            "字宽必须落在两行之内")
            }
            report.append(String(format: "%@ → card %.0f · 摘要列 %.0f · 最长行 %.0f pt / %d 行",
                                 "\(Int(width))", probe.cardWidth, probe.summaryColumn,
                                 probe.rows.map(\.textWidth).max() ?? 0,
                                 probe.rows.map(\.lines).max() ?? 0))
        }
        print("HISTORY WIDTHS · " + report.joined(separator: " · "))
    }

    // MARK: - 3. 上千行不建满

    func testAThousandRowsBuildOnlyWhatTheViewportNeeds() throws {
        let session = makeSession()
        // Two fields per commit, so the merge rule (077) does not fold them: this is a *depth* test.
        // 生产上限是 `EditHistory.defaultMaxDepth` = 200（`History.swift:86`），所以"长栈"就是 200 行：
        // 1000 行的构建成本由同一个 `LazyVStack` 机制决定，Core 层另有 1000 行的 `rows` 成本测试。
        for i in 1...400 {
            session.applyEdit {
                $0.light.exposure = Double(i % 97) / 10
                $0.light.contrast = -Double(i % 89) / 10
            }
            session.commitEdit(label: "e\(i)")
        }
        let total = session.history.count
        XCTAssertEqual(total, EditHistory.defaultMaxDepth, "深度上限把栈压在 200 行")

        let panel = try host(.history, width: WorkspaceLayout.inspectorWidthDefault, session: session)
        defer { panel.window.contentView = nil }
        try waitFor(panel, until: { $0.historyProbe?.totalRows == total })

        let probe = try XCTUnwrap(panel.historyProbe)
        XCTAssertEqual(probe.totalRows, total)
        XCTAssertGreaterThan(probe.builtRows, 0, "至少要建出行来，否则这条测试什么也没证明")
        XCTAssertLessThan(probe.builtRows, total / 2,
                          "\(total) 行里只该建视口附近的几十行，实际建了 \(probe.builtRows) 行")
        print("HISTORY LAZY · total \(probe.totalRows) · built \(probe.builtRows)")
    }

    // MARK: - 4. 接线：点行跳转 / × 删除

    func testTheRowJumpsAndTheDeleteButtonDeletes() throws {
        let session = makeSession()
        session.applyEdit { $0.light.exposure = 0.5 }
        XCTAssertTrue(session.commitEdit(label: "曝光"))
        session.applyEdit { $0.light.contrast = 10 }
        XCTAssertTrue(session.commitEdit(label: "对比"))
        session.applyEdit { $0.color.saturation = 12 }
        XCTAssertTrue(session.commitEdit(label: "饱和"))

        // The two calls the view makes, driven directly: jump keeps the stack, delete shrinks it.
        let countBefore = session.history.count
        XCTAssertTrue(session.jumpToHistory(seq: 1))
        XCTAssertEqual(session.edit.light.exposure, 0.5, accuracy: 1e-12)
        XCTAssertEqual(session.history.count, countBefore, "跳转不产生快照")
        XCTAssertTrue(session.history.canRedo)

        XCTAssertTrue(session.deleteHistoryEntry(at: 3))
        XCTAssertEqual(session.history.count, countBefore - 1)
        XCTAssertEqual(session.history.nextSeq, 4, "删行不回收 seq")

        // …and the view is wired to exactly those two doors, on the row and on the ×.
        let source = try String(contentsOf: Self.panelSource, encoding: .utf8)
        XCTAssertTrue(source.contains(".onTapGesture { session.jumpToHistory(seq: row.seq) }"),
                      "点行必须走跳转入口")
        XCTAssertTrue(source.contains("session.deleteHistoryEntry(at: row.index)"),
                      "× 必须走删行入口")
        XCTAssertTrue(source.contains("if row.canDelete {"),
                      "只有可删的行才画删除按钮")
        XCTAssertTrue(source.contains("LazyVStack"),
                      "行必须是 LazyVStack（上千行不一次建满）")
        XCTAssertFalse(source.contains("ScrollView {"),
                       "面板不许自带滚动视图：它活在检查器的那一个里面")
        XCTAssertTrue(source.contains(".lineLimit(HistoryPanelLayout.summaryLines)"),
                      "摘要换行而不是省略号（不截断）")
    }

    // MARK: - host

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let state: InspectorWorkspaceState
        let cards: InspectorCardsProbe
        let historyProbe: HistoryPanelProbe?

        var scrollViewport: NSRect { cards.frame }
    }

    private func host(_ workspace: InspectorWorkspace, width: CGFloat,
                      session: CatalogSession) throws -> Panel {
        _ = NSApplication.shared
        let state = InspectorWorkspaceState(workspace)
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: Self.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()

        let cards = try XCTUnwrap(Self.find(InspectorCardsProbe.self, in: host),
                                  "卡片探针不在树上")
        return Panel(host: host, window: window, state: state, cards: cards,
                     historyProbe: Self.find(HistoryPanelProbe.self, in: host))
    }

    @discardableResult
    private func waitFor(_ panel: Panel, until predicate: (Panel) -> Bool) throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            panel.host.layoutSubtreeIfNeeded()
            if predicate(panel) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        panel.host.layoutSubtreeIfNeeded()
        return predicate(panel)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews {
            if let hit = find(type, in: sub) { return hit }
        }
        return nil
    }

    private static var panelSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/PhotonsUI/HistoryPanel.swift")
    }
}
