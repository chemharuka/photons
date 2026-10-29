import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 2026-10-28 — **黑白** (S3.4) on a hosted panel: the switch, the eight 黑白混合 rows, what greying
/// looks like, what one gesture costs the history, and what the three panel widths do to the card.
///
/// The card is `InspectorView.blackAndWhiteCard`; every row is the panel's **one** `SliderRow` (040/046)
/// and every number is `color.bands[i].mix` — so what is pinned here is the *card*, not a second
/// implementation of a row. Five claims, one per section below:
///
///   1. **一张卡、九行**：一行开关 + 八根混合，位置在 Color 之后（`RenderStage.order` 的
///      `… .color, .bw …`），行表 `bwRows` 就是卡迭代的那张表 —— 第八个色带不会漏，也不会多出第九根。
///   2. **命中区**：开关和八根行都真的画出来了，都在卡里，开关在上面、八根在下面，互不重叠。
///   3. **三个宽度（卡内容 244 / 274 / 308 = 面板 300 / 330 / 364）**：不重叠、不出卡。
///   4. **一根滑杆/一个开关 = 一条历史**：每根标签双击 +1；输入 `50` ↵ = 50；`0.5` + Esc 不改。
///   5. **关掉置灰不归零**：八行 `.isEnabled == false`、八个值原样，重新打开值还在。
///   6. **反证**：八行若直接绑到 `EditModel`（写模型、不入历史），双击那一下 history **+0** ——
///      这正是第 4 条会红的原因。
@MainActor
final class BlackAndWhiteCardTests: XCTestCase {

    private static let panelHeight: CGFloat = 1100

    /// 300 / 330 / 364 — the panel widths `WorkspaceLayout` allows (`inspectorWidthMin` …
    /// `inspectorWidthMax`). Their **card content** widths are `w − 2·12 − 2·16` = **244 / 274 / 308**,
    /// which are the three numbers the acceptance names; `testAllNineRowsFitAtTheThreeWidths` asserts
    /// that identity rather than assuming it.
    private static let widths: [CGFloat] = [300, 330, 364]

    // MARK: - 1. 卡片清单、位置、行的表

    /// One card, **last in the 色彩 workspace** (below 色彩分级), with a required group reset — and its
    /// two blocks as data.
    func testTheCardIsTheLastColourCardWithOneSwitchAndEightMixRows() throws {
        let sections = InspectorView.sections(in: .colour)
        XCTAssertEqual(sections, [.hsl, .pointColor, .colorGrading, .blackAndWhite],
                       "色彩工作区：HSL → 色彩分级 → 黑白，实际 \(sections)")
        // The *pipeline* still runs S3.4 before S3.6/S3.8 — the panel's reading order is the user's,
        // the execution order is the renderer's.
        XCTAssertEqual(RenderStage.order.firstIndex(of: .bw),
                       RenderStage.order.firstIndex(of: .color).map { $0 + 1 },
                       "S3.4 runs directly after S3 in the pipeline")
        XCTAssertLessThan(try XCTUnwrap(RenderStage.order.firstIndex(of: .bw)),
                          try XCTUnwrap(RenderStage.order.firstIndex(of: .hsl)),
                          "黑白 precedes the HSL stage (a grey has no chroma left to shift)")
        XCTAssertEqual(InspectorView.Section.blackAndWhite.title, "黑白", "标题 = 卡名 = 撤销标签")
        XCTAssertTrue(InspectorView.scrollingSections.contains(.blackAndWhite), "它跟随滚动")

        // The rows, as the card iterates them: eight, Lightroom's order, ±100, integers, red = linear.
        XCTAssertEqual(InspectorView.bwRows.count, 8, "八个色相，一个不多一个不少")
        XCTAssertEqual(InspectorView.bwRows.map(\.title), ["红", "橙", "黄", "绿", "青", "蓝", "紫", "品红"])
        XCTAssertEqual(InspectorView.bwRows.map(\.index), Array(0...7))
        XCTAssertEqual(InspectorView.bwRows.map(\.title), HSLBands.bandNames,
                       "行名来自 core 那张表（时间线的「黑白混合[红]」也是它）")
        for row in InspectorView.bwRows {
            XCTAssertEqual(row.range, -100 ... 100, "\(row.title)：±100（±1 档线性光）")
            XCTAssertEqual(row.format, "%.0f", "\(row.title)：整数读数")
            XCTAssertEqual(row.shape, .linear, "\(row.title)：红 = 线性域（071 的配色规则）")
            XCTAssertEqual(row.shape.accent, SliderShape.linearAccent, "\(row.title)：强调色就是那一个红")
            XCTAssertTrue(row.editable, "047：每一行都能键入")
            XCTAssertEqual(row.decimals, 0, "编辑时也是整数")
            XCTAssertEqual(row.defaultValue, 0, "默认 0（`HSLBand()`，不是字面量）")
            XCTAssertEqual(row.quantum, 1, "文档的格子是 1 个单位：读数就是存进去的数")
        }
        // Nine rows on screen: the switch plus the eight.
        XCTAssertEqual(InspectorView.blackAndWhiteRowCount, 9)

        // The mix is a stop of *linear* light — that is why the rows are red and not blue.
        XCTAssertEqual(HSLBands.mixStopsPerFull, 1)
        XCTAssertNotEqual(SliderShape.linear.accent, SliderShape.knob.accent,
                          "红 != 系统强调色：这条断言让「顺手改成 .knob」变红")
    }

    // MARK: - 2. 画出来了：开关 + 八行，都在卡里

    /// The hosted card: one switch (drawn with the document's value), eight rows below it, all inside
    /// the card's own frame, none overlapping.
    func testTheHostedCardDrawsItsSwitchAndEightRowsInsideTheCard() throws {
        let panel = try host(width: 330, mix: [0, 0, 0, 0, 0, 0, 0, 0], on: false)
        defer { panel.window.contentView = nil }
        try waitFor(panel) { $0.probes.count == 10 }        // card + switch + 8 rows

        let card = try XCTUnwrap(panel.cardFrame, "没有卡片 frame")
        XCTAssertGreaterThan(card.width, 200)
        let switchRow = try XCTUnwrap(panel.switchFrame, "开关那一行没有画出来")
        // 「点黑白」的命中区：勾选框 + 文字都在 Toggle 里，整行就是一个点击目标。
        XCTAssertGreaterThan(switchRow.width, 40, "开关的命中区只有 \(switchRow.width) pt")
        XCTAssertGreaterThan(switchRow.height, 10, "开关的命中区只有 \(switchRow.height) pt 高")
        XCTAssertGreaterThanOrEqual(switchRow.minX, card.minX - 0.5, "开关出了卡片左边")
        XCTAssertLessThanOrEqual(switchRow.maxX, card.maxX + 0.5, "开关出了卡片右边")
        XCTAssertEqual(panel.switchIsOn, false, "开关画的是文档的值（这里是关）")

        let rows = try InspectorView.bwRows.map { row -> (String, CGRect) in
            let frame = try XCTUnwrap(panel.rowFrame(row.title), "「\(row.title)」没有画出来")
            return (row.title, frame)
        }
        XCTAssertEqual(rows.count, 8)
        for (title, frame) in rows {
            XCTAssertGreaterThan(frame.width, 60, "「\(title)」只剩 \(frame.width) pt")
            XCTAssertGreaterThanOrEqual(frame.minX, card.minX - 0.5, "「\(title)」出了卡片左边")
            XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 0.5, "「\(title)」出了卡片右边")
            XCTAssertGreaterThan(frame.height, 10, "「\(title)」没有被画出来")
            XCTAssertGreaterThan(frame.minY, switchRow.minY, "「\(title)」跑到开关上面去了")
        }
        // Order = the table's order, top to bottom, no overlap.
        let ordered = rows.sorted { $0.1.minY < $1.1.minY }.map(\.0)
        XCTAssertEqual(ordered, InspectorView.bwRows.map(\.title), "八行的上下顺序必须是表的顺序")
        let sorted = rows.map(\.1).sorted { $0.minY < $1.minY }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxY, b.minY + 0.5, "两根行压在一起了：\(a) / \(b)")
        }
        XCTAssertGreaterThanOrEqual(sorted.first?.minY ?? 0, card.minY - 0.5, "第一行出了卡片顶")
        XCTAssertLessThanOrEqual(sorted.last?.maxY ?? 0, card.maxY + 0.5, "最后一行出了卡片底")
        print("BW CARD · card \(card) · switch \(switchRow) · rows \(rows.map { "\($0.0)@\($0.1.minY)" })")
    }

    // MARK: - 3. 三个宽度：244 / 274 / 308

    /// The three content widths, measured on the AppKit tree: every row inside the card, in order, not
    /// overlapping, and wide enough for its label plus its number field.
    func testAllNineRowsFitAtTheThreeWidths() throws {
        var report: [String] = []
        for width in Self.widths {
            let panel = try host(width: width, mix: Array(repeating: 0, count: 8), on: true)
            defer { panel.window.contentView = nil }
            try waitFor(panel) { $0.probes.count == 10 }

            let card = try XCTUnwrap(panel.cardFrame, "\(Int(width)) pt：没有卡片 frame")
            // The acceptance's numbers are card *content* widths, and this is the identity behind them.
            let content = card.width - 2 * WorkspaceLayout.cardInsetH
            XCTAssertEqual(content, width - 2 * 12 - 2 * WorkspaceLayout.cardInsetH, accuracy: 1.5,
                           "\(Int(width)) pt：卡片内容宽 \(content) ≠ \(width - 56)")
            XCTAssertEqual(content, width - 56, accuracy: 1.5)

            let switchRow = try XCTUnwrap(panel.switchFrame, "\(Int(width)) pt：开关没画出来")
            XCTAssertGreaterThan(switchRow.width, 40, "\(Int(width)) pt：开关只剩 \(switchRow.width) pt")
            XCTAssertLessThanOrEqual(switchRow.maxX, card.maxX + 0.5, "\(Int(width)) pt：开关出了卡片")

            var frames: [(String, CGRect)] = [(BlackAndWhiteProbe.switchID, switchRow)]
            for row in InspectorView.bwRows {
                let frame = try XCTUnwrap(panel.rowFrame(row.title), "\(Int(width)) pt：「\(row.title)」没画出来")
                // label + a 3-digit readout at 10 pt monospaced + the row's own gap: 70 pt is what the
                // 效果 card's layout test reserves for the same head, and 品红 is shorter than 颗粒粗糙度.
                XCTAssertLessThan(titleWidth(row.title) + 70, frame.width,
                                  "\(Int(width)) pt：「\(row.title)」的标签+数字装不进 \(frame.width) pt")
                XCTAssertGreaterThanOrEqual(frame.minX, card.minX - 0.5, "\(Int(width)) pt：「\(row.title)」出左")
                XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 0.5, "\(Int(width)) pt：「\(row.title)」出右")
                XCTAssertGreaterThanOrEqual(frame.minY, card.minY - 0.5, "\(Int(width)) pt：「\(row.title)」出顶")
                XCTAssertLessThanOrEqual(frame.maxY, card.maxY + 0.5, "\(Int(width)) pt：「\(row.title)」出底")
                frames.append((row.title, frame))
            }

            let ordered = frames.sorted { $0.1.minY < $1.1.minY }
            for (a, b) in zip(ordered, ordered.dropFirst()) {
                XCTAssertLessThanOrEqual(a.1.maxY, b.1.minY + 0.5,
                                         "\(Int(width)) pt：「\(a.0)」压住了「\(b.0)」")
            }
            XCTAssertEqual(ordered.first?.0, BlackAndWhiteProbe.switchID, "开关是第一行")
            XCTAssertEqual(ordered.dropFirst().map(\.0), InspectorView.bwRows.map(\.title))

            let text = frames.map {
                String(format: "%@(%.1f×%.1f @%.1f,%.1f)", $0.0, $0.1.width, $0.1.height,
                       $0.1.minX, $0.1.minY)
            }.joined(separator: " ")
            report.append("\(Int(width)) pt · content \(String(format: "%.1f", content)) · \(text)")
            print("BW ROWS @\(Int(width)) · \(text)")
        }
        print("BW ROWS · " + report.joined(separator: " ‖ "))
    }

    private func titleWidth(_ title: String) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10,
                                                                        weight: .medium)]).width
    }

    // MARK: - 4. 一根滑杆 / 一个开关 = 一条历史

    /// **每根标签双击 history +1** — all eight, one after another, each on a document where its own
    /// band is the only non-zero mix. The reset is the card's own handler
    /// (`resets.blackAndWhiteField(i)`), which is what `onReset:` is wired to.
    func testEachRowsLabelAddsExactlyOneHistoryEntry() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { $0.color.blackAndWhite = true }
        XCTAssertTrue(session.commitEdit(label: "黑白"))

        for row in InspectorView.bwRows {
            session.applyEdit { model in
                model.color.bands[row.index].mix = Double(row.index + 1) * 10
            }
            XCTAssertTrue(session.commitEdit(label: row.title))
            let before = session.history.count

            XCTAssertTrue(resets.blackAndWhiteField(row.index), "「\(row.title)」双击必须写一次")
            XCTAssertEqual(session.edit.color.bands[row.index].mix, 0, "「\(row.title)」回 0")
            XCTAssertEqual(session.history.count, before + 1,
                           "「\(row.title)」双击必须恰好 +1（不是 0，也不是 2）")
            XCTAssertEqual(session.history.currentSnapshot?.label, row.title,
                           "撤销标签是这一行自己的名字")
        }
        XCTAssertEqual(session.edit.color.bands.map(\.mix), Array(repeating: 0, count: 8))
        print("BW ROWS · 8 标签双击 → 每条 +1 · history \(session.history.count)")
    }

    /// The switch: one click = one row. 开 → 关 does not fold into the previous edit.
    func testTheSwitchAddsOneHistoryEntryPerClick() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        let before = session.history.count

        XCTAssertTrue(resets.blackAndWhite(true), "开 = 一条")
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "黑白")
        XCTAssertTrue(resets.blackAndWhite(false))
        XCTAssertEqual(session.history.count, before + 2, "开 → 关 是两行")
        XCTAssertFalse(resets.blackAndWhite(false), "已经是关：不写空快照")
        XCTAssertEqual(session.history.count, before + 2)
        print("BW SWITCH · 开/关 = 2 条")
    }

    /// 数值输入：真的建一个 `NSTextField`，让 AppKit 的 field editor 问 delegate —— `50` + ↵ 提交 50
    /// （一条历史）；`0.5` + Esc 不改文档、不写历史。
    func testTypingFiftyCommitsAndEscapeLeavesTheValueAlone() throws {
        let session = CatalogSession()
        session.applyEdit { $0.color.blackAndWhite = true }
        XCTAssertTrue(session.commitEdit(label: "黑白"))
        let before = session.history.count
        let row = InspectorView.bwRows[0]

        // The card's own path, exactly as `SliderRow` wires it: binding write, then the gesture-end
        // commit. Built from the row's own numbers so the field a test drives is the field on screen.
        let fieldRow = NumberFieldRow(value: 0, range: row.range, format: row.format,
                                      decimals: row.decimals, rounding: row.rounding)
        XCTAssertEqual(fieldRow.editingText, "0", "聚焦时显示干净数字")

        try withField(fieldRow, onCommit: { typed in
            session.applyEdit { $0.color.bands[0].mix = typed }
            session.commitEdit(label: row.title)
        }) { harness in
            let editor = try focus(harness)
            XCTAssertEqual(editor.string, "0")
            editor.setSelectedRange(NSRange(location: 0, length: 0))
            editor.insertText("50", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "50", "第一次按键整段替换")

            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))

            XCTAssertEqual(session.edit.color.bands[0].mix, 50, "键入 50 ↵ = 50")
            XCTAssertEqual(session.history.count, before + 1, "一次输入 = 一条历史")
            XCTAssertEqual(harness.field.stringValue, "50", "读数换成新值")
        }

        // Esc on `0.5`: nothing written, not even a snapshot.
        let afterCommit = session.history.count
        try withField(NumberFieldRow(value: session.edit.color.bands[0].mix, range: row.range,
                                     format: row.format, decimals: row.decimals,
                                     rounding: row.rounding),
                      onCommit: { typed in
            session.applyEdit { $0.color.bands[0].mix = typed }
            session.commitEdit(label: row.title)
        }) { harness in
            let editor = try focus(harness)
            editor.insertText("0.5", replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, "0.5")

            editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))

            XCTAssertEqual(session.edit.color.bands[0].mix, 50, "Esc 不改（还是刚才敲进去的 50）")
            XCTAssertEqual(session.history.count, afterCommit, "Esc 不写历史")
            XCTAssertEqual(harness.field.stringValue, "50", "Esc 恢复读数")
        }
        print("BW TYPING · 50 ↵ → 50（+1 条）· 0.5 Esc → 不改（+0 条）")
    }

    // MARK: - 5. 关掉置灰、不归零

    /// The acceptance's own numbers: set eight mixes, switch 黑白 off, host the panel and read SwiftUI's
    /// resolved `isEnabled` back for each row — all eight `false`, all eight values unchanged — then
    /// switch it on again and get eight live rows and the same eight numbers.
    func testSwitchingOffGreysTheEightRowsWithoutZeroingThem() throws {
        let values: [Double] = [10, 20, 30, 40, 50, 60, 70, 80]
        let session = CatalogSession()
        session.applyEdit { model in
            model.color.blackAndWhite = true
            for i in 0..<ColorGroup.bandCount { model.color.bands[i].mix = values[i] }
        }
        XCTAssertTrue(session.commitEdit(label: "黑白混合"))

        // ① switch on: eight live rows.
        DetailRowEnabledLog.shared.reset()
        var panel = try host(session: session, width: 330)
        try waitFor(panel) { $0.probes.count == 10 }
        XCTAssertEqual(panel.switchIsOn, true, "开关画的是开")
        var log = DetailRowEnabledLog.shared.snapshot
        XCTAssertFalse(log.isEmpty, "row probe 没有记录（没有窗口会话？）")
        for row in InspectorView.bwRows {
            XCTAssertEqual(log[row.title], true, "开的时候「\(row.title)」必须是活的")
        }
        panel.window.contentView = nil
        DetailRowEnabledLog.shared.reset()

        // ② switch off — one snapshot, eight values untouched.
        let resets = PanelResets(session: session)
        let before = session.history.count
        XCTAssertTrue(resets.blackAndWhite(false))
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertEqual(session.edit.color.bands.map(\.mix), values, "关掉不归零")

        panel = try host(session: session, width: 330)
        try waitFor(panel) { $0.probes.count == 10 }
        XCTAssertEqual(panel.switchIsOn, false, "开关画的是关")
        log = DetailRowEnabledLog.shared.snapshot
        for row in InspectorView.bwRows {
            XCTAssertEqual(log[row.title], false, "关的时候「\(row.title)」必须是灰的（isEnabled == false）")
        }
        XCTAssertEqual(session.edit.color.bands.map(\.mix), values, "画灰之后八个值还是原样")
        panel.window.contentView = nil
        DetailRowEnabledLog.shared.reset()

        // ③ switch back on: live again, same eight numbers.
        XCTAssertTrue(resets.blackAndWhite(true))
        panel = try host(session: session, width: 330)
        try waitFor(panel) { $0.probes.count == 10 }
        log = DetailRowEnabledLog.shared.snapshot
        for row in InspectorView.bwRows {
            XCTAssertEqual(log[row.title], true, "重新打开后「\(row.title)」活了")
        }
        XCTAssertEqual(session.edit.color.bands.map(\.mix), values, "重新打开后八个值都回来了")
        panel.window.contentView = nil
        DetailRowEnabledLog.shared.reset()
        print("BW GREY · 八行 isEnabled 开=\(values.count) 活 / 关=\(values.count) 灰 · 值 \(values)")
    }

    // MARK: - 6. 反证

    /// **反证**: bind the eight rows **straight to `EditModel`** — write the document and never commit —
    /// and the double-click produces **+0** history entries, which is exactly what
    /// `testEachRowsLabelAddsExactlyOneHistoryEntry` measures as +1 on the shipped wiring.
    ///
    /// So the +1 above is a claim about the *route*, not about the arithmetic: the `binding` here is the
    /// shortcut this card must not have taken (a `Binding` whose `set` stops at the model, and a reset
    /// that goes back through the same binding). `/Sources/PhotonsUI/InspectorView.swift`'s own rows take
    /// the other path, and the source assertions below say so in the one place a `swift test` can see it.
    func testCounterProofDirectModelBindingNeverReachesTheHistory() throws {
        let session = CatalogSession()
        session.applyEdit { $0.color.blackAndWhite = true }
        XCTAssertTrue(session.commitEdit(label: "黑白"))
        let before = session.history.count

        // The wrong wiring: a live slider and a double-click reset, both bound straight to the model.
        let direct = Binding<Double>(
            get: { session.edit.color.bands[0].mix },
            set: { value in
                session.applyEdit { model in model.color.bands[0].mix = value }   // no commitEdit
            })

        direct.wrappedValue = 50
        XCTAssertEqual(session.edit.color.bands[0].mix, 50, "值进了文档 …")
        XCTAssertEqual(session.history.count, before, "… 但历史一条都没有")
        direct.wrappedValue = 0                                                  // 「双击复位」
        XCTAssertEqual(session.edit.color.bands[0].mix, 0)
        XCTAssertEqual(session.history.count, before, "反证：双击那一下 +0 —— 上一条测试在这里必红")

        // The shipped path, on the same session: one write + one commit = one entry.
        session.applyEdit { $0.color.bands[0].mix = 50 }
        XCTAssertTrue(session.commitEdit(label: "红"))
        XCTAssertEqual(session.history.count, before + 1, "出厂路径 +1")

        // And the card really takes that path: `sliderRow`'s editing-ended commit, `PanelResets` for the
        // name, no direct model write anywhere in the card.
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        let card = try Self.body(of: "private var blackAndWhiteCard",
                                 upTo: "/// The card's first row", in: Self.inspectorSource)
        XCTAssertTrue(card.contains("onReset: { resets.blackAndWhiteField(row.index) }"),
                      "标签双击必须进 PanelResets（一条快照）")
        XCTAssertTrue(card.contains("if !editing { session.commitEdit() }"),
                      "抬起/键入之后必须提交：不加这一行，八行就是反证里那条直绑的路")
        XCTAssertTrue(source.contains("set: { on in _ = resets.blackAndWhite(on) })"),
                      "开关也必须走 PanelResets（coalesce: false），不是直写模型")
        XCTAssertFalse(card.contains("session.edit.color.bands["),
                       "卡里不许直接写文档（写模型 = 不进历史）")
        XCTAssertEqual(Self.occurrences(of: "Slider(value: ", in: card), 0,
                       "卡里不许自己造滑杆")
        XCTAssertFalse(card.contains("step:"), "没有刻度线（046）")
    }

    // MARK: - host

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let cards: InspectorCardsProbe
        let probes: [BlackAndWhiteProbe]

        var cardFrame: CGRect? {
            guard let probe = probes.first(where: { $0.rowID == BlackAndWhiteProbe.cardID }) else { return nil }
            return probe.convert(probe.bounds, to: host)
        }

        var switchProbe: BlackAndWhiteProbe? {
            probes.first { $0.rowID == BlackAndWhiteProbe.switchID }
        }

        var switchFrame: CGRect? { switchProbe.map { $0.convert($0.bounds, to: host) } }

        var switchIsOn: Bool? { switchProbe?.isOn }

        func rowFrame(_ id: String) -> CGRect? {
            guard let probe = probes.first(where: { $0.rowID == id }) else { return nil }
            return probe.convert(probe.bounds, to: host)
        }
    }

    private func host(width: CGFloat,
                      mix: [Double],
                      on: Bool) throws -> Panel {
        let session = CatalogSession()
        session.applyEdit { model in
            model.color.blackAndWhite = on
            for (i, value) in mix.enumerated() where i < ColorGroup.bandCount {
                model.color.bands[i].mix = value
            }
        }
        session.commitEdit(label: "黑白")
        return try host(session: session, width: width)
    }

    private func host(session: CatalogSession, width: CGFloat) throws -> Panel {
        _ = NSApplication.shared
        let state = InspectorWorkspaceState(.colour)   // 2026-10-28: 黑白 lives in 色彩 now
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: width, height: Self.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let cards = try XCTUnwrap(Self.find(InspectorCardsProbe.self, in: host), "卡片探针不在树上")
        return Panel(host: host, window: window, cards: cards,
                     probes: Self.all(BlackAndWhiteProbe.self, in: host))
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

    // MARK: - the number-field harness (the `NumberFieldTypingTests` pattern)

    private struct FieldHarness {
        let window: NSWindow
        let field: NumberTextField
        let controller: NumberFieldController
    }

    /// Harness windows live until the process exits — the same reason `NumberFieldTypingTests` keeps
    /// them: XCTest's memory checker dereferences a window + the shared field editor that a test let go.
    private static var windows: [NSWindow] = []

    private func withField(_ row: NumberFieldRow,
                           onCommit: @escaping (Double) -> Void,
                           _ body: (FieldHarness) throws -> Void) rethrows {
        NSApplication.shared.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        Self.windows.append(window)
        window.makeKeyAndOrderFront(nil)

        let controller = NumberFieldController(row: row, fontSize: 10, onCommit: onCommit)
        let field = NumberTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 18))
        field.attach(controller)
        window.contentView?.addSubview(field)
        defer {
            window.makeFirstResponder(nil)      // hand the shared field editor back
            window.orderOut(nil)
        }
        try body(FieldHarness(window: window, field: field, controller: controller))
    }

    private func focus(_ h: FieldHarness) throws -> NSTextView {
        XCTAssertTrue(h.window.makeFirstResponder(h.field), "字段必须能成为第一响应者")
        let editor = try XCTUnwrap(h.field.currentEditor() as? NSTextView, "字段没有 field editor")
        XCTAssertTrue(h.controller.state.editing, "聚焦必须让 057 的规则就位")
        return editor
    }

    // MARK: - source helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static func body(of signature: String, upTo endMarker: String,
                             in url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: signature),
              let end = source.range(of: endMarker),
              start.lowerBound < end.lowerBound else {
            throw XCTSkip("no `\(signature)` … `\(endMarker)` section in \(url.lastPathComponent)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
