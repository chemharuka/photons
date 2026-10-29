import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 2026-10-28 — the 效果 card on a hosted panel: where it sits, that its eight rows fit at
/// 300 / 330 / 364 pt, and that one parameter is one history entry that ⌘Z can take back.
///
/// The card itself is `InspectorView.effectsCard`; every row is the panel's **one** `SliderRow` (040/046),
/// and every number is the `effects` field it names — so what is pinned here is the *card*, not a second
/// implementation of a row:
///
///   1. **一张卡，两块**：暗角's four rows and 颗粒's four live in 效果, which sits after 曲线 and
///      before 预设 in 调整; the row table (`effectsRows`) is what the card iterates, so a row that is
///      not in the table cannot be drawn and a row in the table cannot be skipped.
///   2. **300 / 330 / 364 不截断**: measured off the AppKit tree (`EffectsRowProbe`), not arithmetic —
///      every row is inside the card, in order, not overlapping, and wide enough that the widest label
///      plus the number field still fit on one line.
///   3. **一根滑杆 = 一条历史**: the drag path (`applyEdit` on every tick, `commitEdit` on release) is
///      one entry, and ⌘Z puts the number back; the whole card is one entry too (title double-click).
///   4. **重置回模型里的默认，不是 0**: 颗粒大小 goes back to 25 and 粗糙度 to 50.
@MainActor
final class EffectsCardTests: XCTestCase {

    private static let panelHeight: CGFloat = 900
    /// 300 / 330 / 364 — the three widths the acceptance names (244 is the hard minimum, 364 the
    /// widest drag; `WorkspaceLayout.inspectorWidthMax` is 364).
    private static let widths: [CGFloat] = [300, 330, 364]

    // MARK: - 1. 卡片清单与位置

    func testTheEffectsCardIsTheLastCardOfTheAdjustWorkspace() throws {
        let titles = InspectorView.cardTitles(in: .adjust)
        XCTAssertTrue(titles.contains("效果"), "调整工作区必须有「效果」卡（\(titles)）")

        let sections = InspectorView.sections(in: .adjust)
        let curve = try XCTUnwrap(sections.firstIndex(of: .curve))
        let detail = try XCTUnwrap(sections.firstIndex(of: .detail))
        let correction = try XCTUnwrap(sections.firstIndex(of: .correction))
        let effects = try XCTUnwrap(sections.firstIndex(of: .effects))
        // 曲线 sits above 细节 (2026-10-28, user); 096 put 校正 between 细节 and 效果, so 效果 is the
        // card after 校正. 081's only change here is that 预设 is gone.
        XCTAssertEqual(detail, curve + 1, "曲线在细节之上")
        XCTAssertEqual(correction, detail + 1, "校正在细节之下")
        XCTAssertEqual(effects, correction + 1, "效果紧跟在校正之后")
        // 081 (2026-10-28): 预设 卡已删，所以 效果 就是调整工作区的最后一张卡。
        XCTAssertEqual(effects, sections.count - 1, "效果是调整工作区的最后一张卡（预设卡已删）")
        XCTAssertFalse(titles.contains("预设"), "预设 不再是卡片：它搬到了顶部菜单与复制对话框")

        // One card, three blocks: the four vignette rows, the Presence triple (S3.8), then the four
        // grain rows, in that order.
        XCTAssertEqual(InspectorView.effectsRows.map(\.title),
                       ["暗角", "暗角中点", "暗角羽化", "暗角圆度",
                        "纹理", "清晰度", "去雾",
                        "颗粒数量", "颗粒大小", "颗粒粗糙度", "种子"])
        XCTAssertEqual(InspectorView.vignetteRows.count, 4)
        XCTAssertEqual(InspectorView.detailFXRows.count, 3)
        XCTAssertEqual(InspectorView.grainRows.count, 4)

        // Every row's travel is the kernel's own (a slider the shader cannot honour lies):
        XCTAssertEqual(InspectorView.vignetteRows.map(\.range),
                       [-100 ... 100, 0 ... 100, 0 ... 100, -100 ... 100])
        XCTAssertEqual(InspectorView.detailFXRows.map(\.range),
                       [-100 ... 100, -100 ... 100, -100 ... 100])
        XCTAssertEqual(InspectorView.grainRows.map(\.range),
                       [0 ... 100, 0 ... 100, 0 ... 100, 0 ... 999])

        let panel = try host(width: 330)
        defer { panel.window.contentView = nil }
        try waitFor(panel) { $0.cards.cardIDs.contains("effects") }
        XCTAssertTrue(panel.cards.cardIDs.contains("effects"),
                      "渲染出来的卡片里没有 effects（\(panel.cards.cardIDs)）")
        // The probe's row count is the table's, so the card cannot draw a ninth row or drop one.
        XCTAssertEqual(panel.rowFrames.count, InspectorView.effectsRows.count,
                       "画出来的行数 \(panel.rowFrames.count) ≠ 表里的 \(InspectorView.effectsRows.count)")
        print("EFFECTS CARD · \(panel.cards.cardIDs)")
    }

    // MARK: - 2. 三宽不截断

    /// Every row inside the card, in order, not overlapping, and wide enough for its own label plus a
    /// number field. 「不截断」 on this panel is a **width** claim: all eight rows are label + number +
    /// slider, so the thing that would truncate is the label, and the widest of the eight is 颗粒粗糙度.
    func testAllRowsFitAtThreeHundredThreeThirtyAndThreeSixtyFour() throws {
        // The widest label, measured at the panel's own label font — this is the constraint the narrow
        // width has to survive. 70 pt is what the row gives its readout (a 3-digit number at 10 pt
        // monospaced plus the 4–6 pt gap the row's `headSpacing` asks for).
        let widest = InspectorView.effectsRows
            .map { ($0.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10,
                                                                                       weight: .medium)]).width }
            .max() ?? 0

        var report: [String] = []
        for width in Self.widths {
            let panel = try host(width: width)
            defer { panel.window.contentView = nil }
            try waitFor(panel) { $0.cards.cardIDs.contains("effects") }

            let card = try XCTUnwrap(panel.cardFrame, "\(Int(width)) pt：没有卡片 frame")
            XCTAssertGreaterThan(card.width, width - 24 - 2, "卡片比面板窄太多（\(card.width)）")
            let rows = InspectorView.effectsRows.compactMap { row in
                panel.rowFrame(row.title).map { (row.title, $0) }
            }
            XCTAssertEqual(rows.count, InspectorView.effectsRows.count,
                           "\(Int(width)) pt：只画出了 \(rows.map(\.0))")

            for (title, frame) in rows {
                XCTAssertGreaterThan(frame.width, 60, "\(Int(width)) pt：「\(title)」只剩 \(frame.width) pt")
                XCTAssertGreaterThanOrEqual(frame.minX, card.minX - 0.5,
                                            "\(Int(width)) pt：「\(title)」出了卡片左边")
                XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 0.5,
                                         "\(Int(width)) pt：「\(title)」出了卡片右边（\(frame.maxX) > \(card.maxX)）")
                XCTAssertLessThan(titleWidth(title) + 70, frame.width,
                                  "\(Int(width)) pt：「\(title)」的标签+数字装不进 \(frame.width) pt")
            }

            // No overlap, and the block is contiguous inside the card.
            let ordered = rows.sorted { $0.1.minY < $1.1.minY }
            for (a, b) in zip(ordered, ordered.dropFirst()) {
                XCTAssertLessThanOrEqual(a.1.maxY, b.1.minY + 0.5,
                                         "\(Int(width)) pt：「\(a.0)」压住了「\(b.0)」")
            }
            let first = try XCTUnwrap(ordered.first?.1)
            let last = try XCTUnwrap(ordered.last?.1)
            XCTAssertGreaterThanOrEqual(first.minY, card.minY - 0.5, "\(Int(width)) pt：第一行出了卡片顶")
            XCTAssertLessThanOrEqual(last.maxY, card.maxY + 0.5, "\(Int(width)) pt：最后一行出了卡片底")
            XCTAssertGreaterThan(widest, 0)

            let frames = rows.map {
                String(format: "%@(%.1f×%.1f @%.1f,%.1f)", $0.0, $0.1.width, $0.1.height,
                       $0.1.minX, $0.1.minY)
            }.joined(separator: " ")
            report.append("\(Int(width)) pt · card \(String(format: "%.1f×%.1f", card.width, card.height)) · \(frames)")
            print("EFFECTS ROWS @\(Int(width)) · \(frames)")
        }
        // Anchor to the real panel geometry: at the default width the card content is 330 − 2·12 − 2·16.
        print("EFFECTS ROWS · widest label \(String(format: "%.1f", widest)) pt · " + report.joined(separator: " ‖ "))
    }

    private func titleWidth(_ title: String) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10,
                                                                        weight: .medium)]).width
    }

    // MARK: - 3. 一根滑杆 = 一条历史

    /// The drag's own path, exactly as `SliderRow` calls it: write on every tick (`applyEdit`), commit
    /// once on release (`commitEdit`). Five ticks must be **one** entry, and ⌘Z must restore the number
    /// the drag started from.
    func testOneParameterOneHistoryEntryAndUndo() throws {
        let session = CatalogSession()
        session.loadEditForAnchor()
        let before = session.history.count
        let start = session.edit.effects.vignetteAmount
        XCTAssertEqual(start, 0)

        // A drag from 0 to −40 in five ticks.
        for value in [-8.0, -16, -24, -32, -40] {
            session.applyEdit { $0.effects.vignetteAmount = value }
        }
        XCTAssertTrue(session.commitEdit(label: "暗角"), "一次拖动提交一条")
        XCTAssertEqual(session.history.count, before + 1, "五个 tick 只能是一条历史")
        XCTAssertEqual(session.edit.effects.vignetteAmount, -40)
        XCTAssertEqual(session.history.currentSnapshot?.label, "暗角")

        XCTAssertTrue(session.undo(), "⌘Z 必须能撤回")
        XCTAssertEqual(session.edit.effects.vignetteAmount, start, "⌘Z 回到拖动前")
        print("HISTORY · 5 ticks → +1 条（\(session.history.count - before)）· undo → "
              + "\(session.edit.effects.vignetteAmount)")
    }

    // MARK: - 4. 整卡复位

    /// Double-click on 「效果」: all eight numbers back to the **model's** defaults in one entry —
    /// including the three whose default is not 0 (颗粒大小 25, 粗糙度 50). A literal 0 here would be
    /// a different picture (and would make 颗粒大小's row disagree with `EffectsGroup.identity`).
    func testTheCardResetPutsEveryNumberBackInOneEntry() throws {
        let session = CatalogSession()
        session.loadEditForAnchor()
        let resets = PanelResets(session: session)

        session.applyEdit {
            $0.effects.vignetteAmount = -50
            $0.effects.vignetteMidpoint = 30
            $0.effects.grain = 40
            $0.effects.grainSize = 80
            $0.effects.grainRoughness = 20
            $0.effects.grainSeed = 12
            $0.effects.texture = 55
            $0.effects.clarity = -60
            $0.effects.dehaze = 70
        }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let before = session.history.count

        XCTAssertTrue(resets.group(.effects), "整卡复位必须真的写了一次")
        XCTAssertEqual(session.edit.effects, EffectsGroup.identity)
        XCTAssertEqual(session.edit.effects.grainSize, 25, "颗粒大小回 25，不是 0")
        XCTAssertEqual(session.edit.effects.grainRoughness, 50, "粗糙度回 50，不是 0")
        XCTAssertEqual(session.edit.effects.vignetteMidpoint, 50, "暗角中点回 50")
        XCTAssertEqual(session.edit.effects.texture, 0, "纹理回 0")
        XCTAssertEqual(session.edit.effects.clarity, 0, "清晰度回 0")
        XCTAssertEqual(session.edit.effects.dehaze, 0, "去雾回 0")
        XCTAssertEqual(session.history.count, before + 1, "整卡 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "效果")

        // Still default → no snapshot at all (a double-click must not truncate redo).
        XCTAssertFalse(resets.group(.effects), "已经是默认就不许再写一条")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.effects.grain, 40, "⌘Z 一步把六个数全带回来")
        XCTAssertEqual(session.edit.effects.vignetteAmount, -50)
        print("RESET · 6 个数 → 1 条 · undo 全部回来 · 再点一次不再写历史")
    }

    /// Per-row reset: 颗粒粗糙度 back to 50 (not 0), one entry.
    /// 2026-10-29 — 用户实测：纹理 / 清晰度 / 去雾 拖一下就弹回 0，手填 10 也没有任何变化。
    ///
    /// 根因不在界面：`EditParameters.areEqual(EffectsGroup)` 漏了这三个字段，`applyEdit` 于是在
    /// `isSemanticallyIdentical` 上短路返回，文档根本没被写过 —— 和文件里 grain 那三行注释记的是
    /// 同一个坑。这条测试逐个字段写入 + 断言文档真的变了，且历史里真的多了一行。
    func testDetailFXRowsWriteTheDocument() throws {
        for (name, keyPath) in [("纹理", \EditModel.effects.texture),
                                ("清晰度", \EditModel.effects.clarity),
                                ("去雾", \EditModel.effects.dehaze)] {
            let session = CatalogSession()
            session.loadEditForAnchor()
            let before = session.history.count

            session.applyEdit { $0[keyPath: keyPath] = 10 }
            XCTAssertEqual(session.edit[keyPath: keyPath], 10,
                           "\(name) 写入必须落到文档上（applyEdit 不许短路）")
            XCTAssertTrue(session.commitEdit(label: name), "\(name) 必须产生一条历史")
            XCTAssertEqual(session.history.count, before + 1, "\(name) 应只多一行")

            // 负值同样要能写进去：三个滑杆的行程是 −100…100。
            session.applyEdit { $0[keyPath: keyPath] = -35 }
            XCTAssertEqual(session.edit[keyPath: keyPath], -35, "\(name) 的负向也必须落地")
        }
    }

    func testOneRowsResetUsesItsOwnDefault() throws {
        let session = CatalogSession()
        session.loadEditForAnchor()
        let resets = PanelResets(session: session)

        session.applyEdit { $0.effects.grainRoughness = 90 }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let before = session.history.count

        XCTAssertTrue(resets.field(\.effects.grainRoughness, label: "颗粒粗糙度"))
        XCTAssertEqual(session.edit.effects.grainRoughness, 50)
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertFalse(resets.field(\.effects.grainRoughness, label: "颗粒粗糙度"),
                       "已经在默认值上就不再写")
    }

    // MARK: - 5. 接线（源码，因为 `swift test` 没有无障碍树）

    /// The card gets its reset from `card(_:reset:)` — the same shell every other card uses — and its
    /// rows come from the table, so 「十一根滑杆」 cannot drift into a twelfth hand-written row.
    func testTheCardIsWiredThroughThePanelOneRowBuilder() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("card(Section.effects.title, reset: { resetGroup(.effects) })"),
                      "效果卡的标题必须挂整卡复位")
        XCTAssertTrue(source.contains("ForEach(Self.vignetteRows, id: \\.title)"),
                      "暗角四行来自表")
        XCTAssertTrue(source.contains("ForEach(Self.detailFXRows, id: \\.title)"),
                      "纹理/清晰度/去雾三行来自表")
        XCTAssertTrue(source.contains("ForEach(Self.grainRows, id: \\.title)"),
                      "颗粒四行来自表")
        XCTAssertTrue(source.contains("private func effectsSliderRow(_ row: ToneRow) -> some View"),
                      "行必须走面板唯一的 sliderRow（一个 row view）")
        XCTAssertFalse(source.contains("Slider(value: Binding(get: { session.edit.effects"),
                       "卡里不许自己造滑杆")
    }

    // MARK: - host

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let state: InspectorWorkspaceState
        let cards: InspectorCardsProbe
        let probes: [EffectsRowProbe]

        /// Every probe except the card's own — the eight rows, in draw order (the tree's order is the
        /// `VStack`'s, which is why the frames are sorted by y where an order matters).
        var rowFrames: [(String, CGRect)] {
            probes.filter { $0.rowID != EffectsRowProbe.cardID }
                .map { ($0.rowID, $0.convert($0.bounds, to: host)) }
        }

        func rowFrame(_ id: String) -> CGRect? {
            rowFrames.first { $0.0 == id }?.1
        }

        /// The card's own frame — probed by `effectsCard`'s background.
        var cardFrame: CGRect? {
            probes.first { $0.rowID == EffectsRowProbe.cardID }
                .map { $0.convert($0.bounds, to: host) }
        }
    }

    private func host(width: CGFloat) throws -> Panel {
        _ = NSApplication.shared
        let session = CatalogSession()
        let state = InspectorWorkspaceState(.adjust)
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: Self.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let cards = try XCTUnwrap(Self.find(InspectorCardsProbe.self, in: host), "卡片探针不在树上")
        return Panel(host: host, window: window, state: state, cards: cards,
                     probes: Self.all(EffectsRowProbe.self, in: host))
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

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var found: [T] = []
        if let hit = view as? T { found.append(hit) }
        for sub in view.subviews { found += all(type, in: sub) }
        return found
    }

    private static var inspectorSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }
}
