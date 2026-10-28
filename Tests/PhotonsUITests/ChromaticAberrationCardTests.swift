import XCTest
import AppKit
import SwiftUI
import Metal
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 2026-10-28 (078 B8) — **色差** on a hosted panel: the two rows 029 rendered but never showed, what a
/// double-click costs the history, what a typed number stores, and — the reason the task exists — what
/// the two numbers do to a **pixel**.
///
/// 029 put lateral CA in S0 (red/blue radial rescale) and shipped it with no UI at all: the model had
/// `optics.caRed/caBlue`, the kernel read them, the cache key carried `;car=`, the history knew the field
/// names — and no user could reach any of it. This file is about the missing half:
///
///   1. **两根行**: 色差 R / 色差 B, in the 细节 card of 调整, in slider units (−100…+100), `.linear`
///      (red `#FF375F`), typeable, with a double-click reset on each name — and the card's title takes
///      both back in **one** snapshot, like every other card.
///   2. **画出来了**: two rows inside the detail card, in table order, not overlapping, at the three
///      card content widths 244 / 274 / 308 pt (panel 300 / 330 / 364) — `LayoutContractTests` pins the
///      identity those three numbers come from.
///   3. **一次输入 = 一条历史**: a typed `5` stores `0.00025` (five slider units of 5 × 10⁻⁵) and costs
///      one history row; a double-click on each name costs one each.
///   4. **改参数真的改像素**: a synthetic frame with a ±2 px radial red/blue fringe — the rows at
///      +57 / −57 put both channel edges back on green's, and the measured α is the α the document
///      holds (`α = slider × 5e-5`), to 1e-4.
///   5. **中性 = 未接 UI 的那一帧**: both rows at 0 write a document `== EditModel.neutral`, and the
///      frame's sha is the sha pinned here (recorded on `c9aa22e`, before this UI existed).
///   6. **反证**: a row bound straight to `EditModel` (no `PanelResets`, no `commitEdit`) leaves the
///      history exactly where it was — so 「双击 history +1」 fails on that wiring, which is why the
///      card must go through the panel furniture.
@MainActor
final class ChromaticAberrationCardTests: XCTestCase {

    private static let panelHeight: CGFloat = 3000
    private static let widths: [CGFloat] = [300, 330, 364]

    // MARK: - 1. the two rows, as data

    func testTheTwoCaRowsLiveInTheCorrectionCardInSliderUnitsWithTheLinearAccent() throws {
        // 096: 校正 is in 调整, between 细节 and 效果 — the card the rows moved to.
        XCTAssertTrue(InspectorWorkspace.adjust.cards.contains(.correction))
        XCTAssertEqual(InspectorView.Section.detail.title, "细节")
        XCTAssertEqual(InspectorView.Section.correction.title, "校正")
        XCTAssertEqual(InspectorView.caRows.map(\.title), ["色差 R", "色差 B"])
        XCTAssertEqual(InspectorView.caRows.map(\.title), ["色差 R", "色差 B"],
                       "the undo label of each row is its own title")

        for row in InspectorView.caRows {
            XCTAssertEqual(row.range, OpticsGroup.sliderRange, "\(row.title)：滑杆的行程是 −100…+100")
            XCTAssertEqual(row.range, -100 ... 100)
            XCTAssertEqual(row.format, "%.0f", "\(row.title)：整数读数")
            XCTAssertEqual(row.shape, .linear, "\(row.title)：线性域 → 红 #FF375F（071 的第三类）")
            XCTAssertEqual(row.shape.accent, SliderShape.linearAccent, "\(row.title)：强调色就是那一个红")
            XCTAssertNotEqual(row.shape.accent, SliderShape.knob.accent, "渲染参数是蓝，色差不是")
            XCTAssertNotEqual(row.shape.accent, SliderShape.bar.accent, "解码参数是黄，色差不是")
            XCTAssertTrue(row.editable, "047：每一行都能键入")
            XCTAssertEqual(row.decimals, 0)
            XCTAssertEqual(row.defaultValue, 0, "默认 = 文档的 0（`OpticsGroup()`，不是字面量）")
        }

        // The document fields the rows own are the ones 029 already had — no second set of parameters.
        XCTAssertEqual(EditModel.neutral[keyPath: InspectorView.caRows[0].keyPath], 0)
        XCTAssertEqual(EditModel.neutral[keyPath: InspectorView.caRows[1].keyPath], 0)
        var probe = EditModel.neutral
        probe[keyPath: InspectorView.caRows[0].keyPath] = 0.001
        XCTAssertEqual(probe.optics.caRed, 0.001, "色差 R 写的是 `optics.caRed`")
        probe[keyPath: InspectorView.caRows[1].keyPath] = -0.001
        XCTAssertEqual(probe.optics.caBlue, -0.001, "色差 B 写的是 `optics.caBlue`")

        // 4 decoder rows then the 2 CA rows: the card grows by a divider and nothing else.
        XCTAssertEqual(InspectorView.detailContent.rows.count, 4)
        XCTAssertEqual(InspectorView.detailContent.rows.map(\.title), ["降噪", "色彩降噪", "细节", "锐化"])
        XCTAssertTrue(PanelResets.Group.allCases.contains(.detail))
        XCTAssertTrue(PanelResets.Group.allCases.contains(.correction))
        XCTAssertEqual(PanelResets.Group.correction.title, "校正")
        print("CA CARD · rows \(InspectorView.caRows.map { "\($0.title) \($0.range) \($0.shape.rawValue)" })")
    }

    /// The slider grid: one unit is still 5 × 10⁻⁵ of α, the ends are ±fullScale, but the grid itself
    /// is **0.1 of a unit** (084) so the thumb can sit on 2.5 while the row still prints an integer.
    /// Both directions land on the same tenth so a knob that wobbles cannot store a number the row
    /// cannot express.
    func testTheSliderGridIsFiveE5PerUnitAndRoundTripsOnTheTenthGrid() throws {
        XCTAssertEqual(OpticsGroup.fullScale, 0.005)
        XCTAssertEqual(OpticsGroup.sliderStep, 0.1)
        XCTAssertEqual(OpticsGroup.alphaPerSliderUnit, 0.00005, accuracy: 1e-18)
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 0), 0)
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 1), 0.00005, accuracy: 1e-18)
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 5), 0.00025, accuracy: 1e-18, "输入 5 → 0.00025")
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 2.5), 0.000125, accuracy: 1e-18,
                       "084：0.1 网格上的一半 → 2.5 × 5e-5")
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 100), OpticsGroup.fullScale,
                       "084：0.1 网格不能动满幅，逐位相等")
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: -100), -OpticsGroup.fullScale)
        // Out of travel and junk are clamped / dropped: a hand-edited document cannot ask for more.
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 400), 0.005)
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: -400), -0.005)
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: .nan), 0)
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: .infinity), 0)
        // …and it snaps to the row's own 0.1 grid: 2.54 is not a grid point, 2.5 is.
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 2.54), OpticsGroup.alpha(fromSlider: 2.5))
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 5.04), OpticsGroup.alpha(fromSlider: 5))
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 5.06), OpticsGroup.alpha(fromSlider: 5.1))
        // The inverse snaps too, including a hand-edited α that sits between two grid points.
        XCTAssertEqual(OpticsGroup.sliderPosition(forAlpha: 0.000125), 2.5)
        XCTAssertEqual(OpticsGroup.sliderPosition(forAlpha: 0.000126), 2.5, "2.52 步 → 吸到 2.5")
        XCTAssertEqual(OpticsGroup.sliderPosition(forAlpha: 0.00013), 2.6, "2.6 步 → 2.6（不在 0.1 网格外）")

        for unit in stride(from: -100.0, through: 100.0, by: 7) {
            let alpha = OpticsGroup.alpha(fromSlider: unit)
            XCTAssertEqual(OpticsGroup.sliderPosition(forAlpha: alpha), unit,
                           "\(Int(unit)) → α \(alpha) → \(OpticsGroup.sliderPosition(forAlpha: alpha))")
        }
        var group = OpticsGroup.identity
        group.caRed = 0.00125
        group.caBlue = -0.0004
        XCTAssertEqual(group.caRedSliderPosition, 25)
        XCTAssertEqual(group.caBlueSliderPosition, -8, "-0.0004 / 5e-5 = −8")
        XCTAssertFalse(group.slidersAtRest)
        XCTAssertTrue(OpticsGroup.identity.slidersAtRest)
        print("CA GRID · step \(OpticsGroup.sliderStep) unit = \(OpticsGroup.alphaPerSliderUnit) α"
              + " · 2.5 = \(OpticsGroup.alpha(fromSlider: 2.5)) · 100 = \(OpticsGroup.alpha(fromSlider: 100))")
    }

    /// **The link that was missing** — and the reason the two rows would have been dead on arrival.
    ///
    /// 029 gave CA a model field, a cache-key token (`;car=`) and a history field name, but never an
    /// entry in `EditHistory.dirtyGroups` — the list `applyEdit` short-circuits on
    /// (`isSemanticallyIdentical`). So a CA write was **silently dropped**: the document stayed at 0,
    /// `commitEdit` found nothing, the slider moved and nothing on screen or in the history changed.
    /// Nobody noticed for a month because the sliders had no UI; this is the assertion that makes the
    /// gap impossible to reintroduce.
    func testAChangeReachesTheDocumentS0AndTheHistory() throws {
        let before = EditModel.neutral
        var after = before
        after.optics.caRed = OpticsGroup.alpha(fromSlider: 5)
        XCTAssertFalse(EditHistory.isSemanticallyIdentical(before, after),
                       "改了 α 必须算「文档变了」，否则 applyEdit 会把它吞掉")
        XCTAssertEqual(EditHistory.dirtyGroups(from: before, to: after), [.geometry],
                       "CA 是 S0 的参数 → geometry 组")
        XCTAssertEqual(after.changedStages(from: before), [.geometry], "S0 及其下游全部失效")

        let session = CatalogSession()
        session.applyEdit { $0.optics.caRed = OpticsGroup.alpha(fromSlider: 5) }
        XCTAssertEqual(session.edit.optics.caRed, 0.00025, accuracy: 1e-15,
                       "写进文档（修好 `dirtyGroups` 之前这一条是红的）")
        XCTAssertTrue(session.commitEdit(label: "色差 R"))
        XCTAssertEqual(session.history.count, 1)

        // The cache key: a non-zero α appends its own token, so no stage below S0 can serve a buffer
        // sampled with another ratio. 084: the token is integer tenths (`;car=50` = position 5).
        let key = session.edit.keyMaterial(.geometry)
        XCTAssertNotEqual(key, EditModel.neutral.keyMaterial(.geometry))
        XCTAssertTrue(key.contains(";car=50"), "键里的位置是 5 个滑杆单位 = 50 个十分位：\(key)")
        // …and a step is 5× the dirty tolerance, so every position the row can express — 0.1
        // included (5e-6 > 1e-6) — moves the document (a row whose neighbour compares equal would
        // print two numbers and store one).
        var oneUnit = before
        oneUnit.optics.caRed = OpticsGroup.alpha(fromSlider: 1)
        XCTAssertEqual(EditHistory.dirtyGroups(from: before, to: oneUnit), [.geometry])
        XCTAssertNotEqual(oneUnit.keyMaterial(.geometry), before.keyMaterial(.geometry))
        var oneStep = before
        oneStep.optics.caRed = OpticsGroup.alpha(fromSlider: 0.1)
        XCTAssertEqual(EditHistory.dirtyGroups(from: before, to: oneStep), [.geometry],
                       "0.1 步（5e-6）仍然大于 1e-6 的脏阈值")
        XCTAssertNotEqual(oneStep.keyMaterial(.geometry), before.keyMaterial(.geometry))
        print("CA LINK · dirty \(EditHistory.dirtyGroups(from: before, to: after).map(\.rawValue))"
              + " · key \(key)")
    }

    // MARK: - 2. 复位：每根名字一次，卡片标题一次

    /// A double-click on **each** name: that field back to 0, **one** history row, `coalesce: false`, and
    /// the other channel untouched. A second double-click writes nothing (no empty snapshot).
    func testEachNameDoubleClickIsExactlyOneHistoryRow() throws {
        let session = try Catalogue.makeSession()
        let base = session.history.count
        let resets = PanelResets(session: session)

        // What a drag of each row does: write through the slider's own mapping, then one commit.
        session.applyEdit { $0.optics.caRed = OpticsGroup.alpha(fromSlider: 30) }
        session.commitEdit(label: "色差 R")
        session.applyEdit { $0.optics.caBlue = OpticsGroup.alpha(fromSlider: -40) }
        session.commitEdit(label: "色差 B")
        XCTAssertEqual(session.history.count, base + 2)
        XCTAssertEqual(session.history.snapshots.last?.label, "色差 B")

        let redBefore = session.edit.optics.caRed
        let blueBefore = session.edit.optics.caBlue
        XCTAssertEqual(redBefore, 0.0015, accuracy: 1e-15)
        XCTAssertEqual(blueBefore, -0.002, accuracy: 1e-15)

        // Double-click 色差 R.
        XCTAssertTrue(resets.field(InspectorView.caRows[0].keyPath, label: "色差 R"))
        XCTAssertEqual(session.edit.optics.caRed, 0)
        XCTAssertEqual(session.edit.optics.caBlue, blueBefore, "只清这一根")
        XCTAssertEqual(session.history.count, base + 3, "双击 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "色差 R")
        // Its change is the field 029 registered, in the stage 029 registered it under.
        let change = try XCTUnwrap(session.history.currentSnapshot?.changes.first)
        XCTAssertEqual(change.field.key, "optics.caRed")
        XCTAssertEqual(change.field.group, .geometry, "CA 是 S0 的参数（029），不是 S1/S3")
        XCTAssertEqual(change.field.displayName, "横向色差 R", "077 的参数名表已经认识这个字段")

        // A second double-click on the same name: already at its default, no snapshot.
        XCTAssertFalse(resets.field(InspectorView.caRows[0].keyPath, label: "色差 R"))
        XCTAssertEqual(session.history.count, base + 3, "不许造空快照")

        // Double-click 色差 B.
        XCTAssertTrue(resets.field(InspectorView.caRows[1].keyPath, label: "色差 B"))
        XCTAssertEqual(session.edit.optics, .identity)
        XCTAssertEqual(session.history.count, base + 4)
        XCTAssertEqual(session.history.currentSnapshot?.label, "色差 B")

        // ⌘Z brings the blue back, then the red reset is the next step.
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.optics.caBlue, blueBefore)
        XCTAssertEqual(session.edit.optics.caRed, 0)
        print("CA RESET · \(session.history.snapshots.map(\.label))")
    }

    /// The card's title: **both** rows back in one snapshot — the card is one thing on screen (the
    /// effects card's rule), and 029's two numbers are the only fields it owns here.
    func testTheCorrectionTitleResetsBothRowsInOneSnapshotAndTheDetailTitleLeavesOpticsAlone() throws {
        let session = try Catalogue.makeSession()
        let resets = PanelResets(session: session)
        session.applyEdit {
            $0.optics.caRed = OpticsGroup.alpha(fromSlider: 12)
            $0.optics.caBlue = OpticsGroup.alpha(fromSlider: -73)
        }
        XCTAssertTrue(session.commitEdit(label: "色差"))
        let base = session.history.count

        // 096: 细节 no longer owns 色差 — its title must not touch `optics` (the 078 B8 behaviour is gone).
        XCTAssertFalse(resets.group(.detail), "细节 卡的标题不再碰色差")
        XCTAssertEqual(session.edit.optics.caRed, OpticsGroup.alpha(fromSlider: 12))
        XCTAssertEqual(session.edit.optics.caBlue, OpticsGroup.alpha(fromSlider: -73))
        XCTAssertEqual(session.history.count, base, "…也不写历史")

        XCTAssertTrue(resets.group(.correction), "校正 卡的标题复位")
        XCTAssertTrue(session.edit.optics.isIdentity, "两根都回 0")
        XCTAssertTrue(session.edit.optics.slidersAtRest)
        XCTAssertEqual(session.history.count, base + 1, "整卡复位也是**一条**历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, InspectorView.Section.correction.title)

        // Nothing left to write: the guard covers optics too (a second double-click is not a snapshot).
        XCTAssertFalse(resets.group(.correction))
        XCTAssertEqual(session.history.count, base + 1)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.optics.caRed, OpticsGroup.alpha(fromSlider: 12), "⌘Z 把两根一起带回来")
        XCTAssertEqual(session.edit.optics.caBlue, OpticsGroup.alpha(fromSlider: -73))
        print("CA TITLE RESET · \(session.history.snapshots.map(\.label))")
    }

    // MARK: - 3. 键入：5 ↵ = 5

    /// The real wiring, on a real window: focus 色差 R's own `NSTextField`, type `5`, press ↵ — the
    /// document stores five slider units (`0.00025`), the readout stays `5`, and the history grows by one.
    ///
    /// A model-level `alpha(fromSlider: 5)` test would pass with the row bound to nothing; this one drives
    /// the field the panel drew (`NumberFieldTypingTests`' technique), which is the only way to say
    /// 「输入 5 ↵ = 5」.
    func testTypingFiveIntoTheRedRowStoresFiveUnitsAndKeepsTheReadoutAtFive() throws {
        let session = CatalogSession()
        let panel = try host(session: session, width: 330)
        defer { panel.window.makeFirstResponder(nil); panel.window.contentView = nil }
        _ = try waitFor(panel) { $0.probes.count == 4 }

        let field = try XCTUnwrap(panel.numberField("inspector.detail.色差 R"),
                                  "色差 R 的数值框不在树上")
        XCTAssertTrue(panel.window.makeFirstResponder(field), "数值框必须是能进的第一响应者")
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "没有 field editor")
        XCTAssertEqual(editor.string, "0", "滑杆在 0，读数就是 0")

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("5", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "5", "第一次按键整段替换（057）")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        pump()

        XCTAssertEqual(session.edit.optics.caRed, 0.00025, accuracy: 1e-15,
                       "输入 5 = 5 个滑杆单位 = 5 × 5e-5")
        XCTAssertEqual(OpticsGroup.sliderPosition(forAlpha: session.edit.optics.caRed), 5,
                       "读数还是 5：屏幕上的数和文档里的数是同一个")
        XCTAssertEqual(session.edit.optics.caBlue, 0, "另一根不动")
        XCTAssertEqual(session.history.count, 1, "一次输入 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "色差 R")
        XCTAssertEqual(field.stringValue, "5", "提交后读数就是 5")
        print("CA TYPING · 5 ↵ → optics.caRed \(session.edit.optics.caRed) · readout \(field.stringValue)"
                + " · history \(session.history.count)")
    }

    // MARK: - 4. 画出来了

    func testTheTwoRowsAreDrawnInsideTheCorrectionCardAndOutsideTheDetailCard() throws {
        let panel = try host(width: 330, filled: true)
        defer { panel.window.contentView = nil }
        try waitFor(panel) { $0.probes.count == 4 }

        let card = try XCTUnwrap(panel.cardFrame, "校正卡没有 frame")
        let detail = try XCTUnwrap(panel.detailCardFrame, "细节卡没有 frame")
        XCTAssertGreaterThan(card.width, 200)
        XCTAssertGreaterThanOrEqual(card.minY, detail.maxY - 0.5, "校正卡紧跟在细节卡下方")
        let rows = try InspectorView.caRows.map { row -> (String, CGRect) in
            let frame = try XCTUnwrap(panel.rowFrame(row.title), "「\(row.title)」没有画出来")
            return (row.title, frame)
        }
        for (title, frame) in rows {
            XCTAssertGreaterThan(frame.width, 60, "「\(title)」只剩 \(frame.width) pt")
            XCTAssertGreaterThan(frame.height, 10, "「\(title)」没有被画出来")
            XCTAssertGreaterThanOrEqual(frame.minX, card.minX - 0.5, "「\(title)」出了卡片左边")
            XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 0.5, "「\(title)」出了卡片右边")
            XCTAssertGreaterThanOrEqual(frame.minY, card.minY - 0.5, "「\(title)」在卡片上方")
            XCTAssertLessThanOrEqual(frame.maxY, card.maxY + 0.5, "「\(title)」在卡片下方")
            XCTAssertFalse(detail.contains(frame), "「\(title)」仍在细节卡里 \(detail)")
        }
        let ordered = rows.sorted { $0.1.minY < $1.1.minY }.map(\.0)
        XCTAssertEqual(ordered, InspectorView.caRows.map(\.title), "上下顺序是表的顺序")
        let sorted = rows.map(\.1).sorted { $0.minY < $1.minY }
        for (a, b) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(a.maxY, b.minY + 0.5, "两根行压在一起了：\(a) / \(b)")
        }
        print("CA CARD · card \(card) · rows \(rows.map { "\($0.0)@\(Int($0.1.minY))" })")
    }

    /// 244 / 274 / 308 pt of card content (panel 300 / 330 / 364): the widest text in the panel is
    /// 细节's own rows, so the two new labels must not be the ones that clip.
    func testTheTwoRowsFitAtTheThreeWidths() throws {
        for width in Self.widths {
            let panel = try host(width: width, filled: true)
            defer { panel.window.contentView = nil }
            try waitFor(panel) { $0.probes.count == 4 }
            let card = try XCTUnwrap(panel.cardFrame)
            XCTAssertEqual(card.width, width - 2 * 12, accuracy: 0.5,
                           "卡宽 = 面板 − 2·12，实测 \(card.width)")
            let contentWidth = width - 2 * 12 - 2 * WorkspaceLayout.cardInsetH
            var frames: [CGRect] = []
            for row in InspectorView.caRows {
                let frame = try XCTUnwrap(panel.rowFrame(row.title), "\(width) pt：\(row.title) 没画出来")
                XCTAssertEqual(frame.width, contentWidth, accuracy: 1.0,
                               "\(width) pt：行宽应是卡内容宽 \(contentWidth)")
                XCTAssertGreaterThan(frame.width, 60)
                XCTAssertLessThanOrEqual(frame.maxX, card.maxX + 0.5, "\(width) pt：出了卡片")
                frames.append(frame)
            }
            if frames.count == 2 {
                let top = frames.min { $0.minY < $1.minY }!
                let bottom = frames.max { $0.minY < $1.minY }!
                XCTAssertLessThanOrEqual(top.maxY, bottom.minY + 0.5, "\(width) pt：两根行重叠")
            }
            // The label itself: 「色差 R」 at 244 pt is ~40 pt of a 244 pt card — no truncation at any
            // width the resolver allows, and the two rows keep the card's own 12 pt inset.
            XCTAssertEqual(frames.map(\.width), [contentWidth, contentWidth], "\(width) pt")
            print("CA WIDTHS · panel \(Int(width)) → content \(Int(contentWidth)) · rows \(frames.map(\.width))")
        }
    }

    // MARK: - 5. 改参数真的改像素

    /// **The pixel proof.** A synthetic frame whose three channels are concentric discs with radii
    /// 702 / 700 / 698 — red's edge 2 px outside green's, blue's 2 px inside: exactly what lateral CA
    /// looks like on a real lens (a red fringe on one side of an edge, a blue one on the other).
    ///
    /// On the centre row that frame *is* a set of vertical steps at x = 98 (R) / 100 (G) / 102 (B), so
    /// each channel's edge can be read back to a ten-thousandth of a pixel: the display value is affine in
    /// x across the edge (the bilinear blend of a one-texel ramp), so the halfway crossing interpolates
    /// exactly, and `u(x_cross) = k` turns that position into the kernel's own α — measured, not assumed.
    ///
    /// What it proves, in the order the acceptance asks:
    ///
    ///   · **`0` is the frame the pre-UI build produced** — the sha is the one pinned below, recorded on
    ///     `c9aa22e` before either slider existed, and the document a 0-row writes is `== .neutral`;
    ///   · **±100 moves the edges** — α = ±0.005 on both channels, and the screen edge moves by
    ///     `r·(1 − 1/(1+α))` px (≈ 3.5 px at these radii);
    ///   · **the two rows correct a fringe** — 色差 R at +57 and 色差 B at −57 put both edges back on
    ///     green's (100.0), i.e. the ±2.0 px split becomes 0.00 px. That is `5e-5` × slider doing
    ///     arithmetic on pixels, through the panel's own numbers.
    func testTheNeutralFrameIsThePreUiFrameAndTheRowsMoveTheEdges() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let image = Fringe.image()
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "ca-card-fringe"))

        // ---- the pre-UI frame: α = 0 has one sha, and it is the recorded one -------------------
        let neutral = try render(graph, EditModel.neutral)
        XCTAssertEqual(neutral.sha256(), Fringe.neutralSHA256,
                       "中性帧不是未接 UI 前的那一帧（029 的 α = 0 必须逐字节是恒等拷贝）")

        // What the two rows write when they are at 0 is **the** neutral document, not merely a
        // document that renders the same: `alpha(fromSlider: 0)` is 0, so nothing is appended to the
        // geometry key either.
        var uiZero = EditModel.neutral
        uiZero.optics.caRed = OpticsGroup.alpha(fromSlider: 0)
        uiZero.optics.caBlue = OpticsGroup.alpha(fromSlider: 0)
        XCTAssertEqual(uiZero, EditModel.neutral, "两根行在 0 时文档必须逐字段等于中性文档")
        XCTAssertEqual(uiZero.keyMaterial(.geometry), EditModel.neutral.keyMaterial(.geometry),
                       "…缓存键也一样（`;car=` 只在非零时追加）")
        let uiZeroFrame = try render(graph, uiZero)
        XCTAssertEqual(uiZeroFrame.sha256(), neutral.sha256(), "0 → 中性帧，逐字节")

        // ---- the edges of the source, as built: R +2, G 0, B −2 --------------------------------
        let row = Fringe.h / 2
        let edges = try [(0, Fringe.rRed), (1, Fringe.rGreen), (2, Fringe.rBlue)].map { channel, radius in
            try Fringe.firstBright(neutral, channel: channel, y: row,
                                   from: Fringe.halfWidth - radius - 12)
        }
        XCTAssertEqual(edges, [Fringe.halfWidth - Fringe.rRed,
                               Fringe.halfWidth - Fringe.rGreen,
                               Fringe.halfWidth - Fringe.rBlue],
                       "合成图的左边缘：R 98 / G 100 / B 102")

        // ---- ±100: both channels, both directions ---------------------------------------------
        var measured: [String: Double] = [:]
        for position in [100.0, -100.0] {
            var edit = EditModel.neutral
            edit.optics.caRed = OpticsGroup.alpha(fromSlider: position)
            edit.optics.caBlue = OpticsGroup.alpha(fromSlider: position)
            let frame = try render(graph, edit)
            XCTAssertNotEqual(frame.sha256(), neutral.sha256(),
                              "色差 \(Int(position)) 没有改像素")
            for (name, channel, radius) in [("R", 0, Fringe.rRed), ("B", 2, Fringe.rBlue)] {
                let m = try Fringe.measure(frame, channel: channel,
                                           k: Fringe.halfWidth - radius, y: row)
                measured["\(name)@\(Int(position))"] = m.alpha
                XCTAssertEqual(m.alpha, OpticsGroup.alpha(fromSlider: position), accuracy: 1e-4,
                               "\(name) @ \(Int(position))：测出 α \(m.alpha)")
                XCTAssertEqual(m.alpha, OpticsGroup.alphaPerSliderUnit * position, accuracy: 1e-4,
                               "\(name)：α 就是读数 × 5e-5")
                // The edge on screen: the step's texel index `k` at α = 0, `x_cross` now. A positive
                // slider pulls the channel's edge **toward the axis** (the channel is sampled further
                // out), which on the left-hand edge means `x_cross` grows.
                let moved = m.x - Double(Fringe.halfWidth - radius)
                print(String(format: "CA PIXELS · slider %+.0f · %@ edge x %.3f (%.3f px from %d) "
                               + "· implied α %+.5f", position, name, m.x, moved,
                               Fringe.halfWidth - radius, m.alpha))
            }
        }
        XCTAssertGreaterThan(measured["R@100"] ?? 0, 0)
        XCTAssertLessThan(measured["B@-100"] ?? 0, 0, "反向的滑杆值必须反向移动")

        // ---- the correction: +57 / −57 put both edges back on green's ---------------------------
        var corrected = EditModel.neutral
        corrected.optics.caRed = OpticsGroup.alpha(fromSlider: 57)
        corrected.optics.caBlue = OpticsGroup.alpha(fromSlider: -57)
        let fixed = try render(graph, corrected)
        XCTAssertNotEqual(fixed.sha256(), neutral.sha256())

        // Green never moves (α_G = 0 by construction): its edge stays at 100.
        let greenEdge = Double(Fringe.halfWidth - Fringe.rGreen)
        for (name, channel, radius) in [("R", 0, Fringe.rRed), ("B", 2, Fringe.rBlue)] {
            let k = Fringe.halfWidth - radius
            let m = try Fringe.measure(fixed, channel: channel, k: k, y: row)
            print(String(format: "CA CORRECT · %@ slider %+.0f · implied α %+.5f · edge x %.3f "
                           + "(was %d, fringe %+.3f px → %+.3f px from green)",
                           name, OpticsGroup.sliderPosition(forAlpha: m.alpha), m.alpha, m.x, k,
                           Double(k) - greenEdge, m.x - greenEdge))
            XCTAssertEqual(m.x, greenEdge, accuracy: 0.05,
                           "\(name)：色边没有被收掉（边缘在 \(m.x)，绿在 \(greenEdge)）")
        }

        // And the fringe *was* there: ±2.0 px of source radius on each side, which is what the
        // uncorrected frame's edges (98 / 100 / 102) measure.
        XCTAssertEqual(edges[2] - edges[1], 2, "B 小 2 px")
        XCTAssertEqual(edges[1] - edges[0], 2, "R 大 2 px")
    }

    // MARK: - 6. 反证

    /// **反证**: the same two numbers, bound **straight to `EditModel`** — a write and a "double-click"
    /// that both go through `applyEdit` alone, which is exactly what a row wired to the model without
    /// `PanelResets` does. The picture changes; the history does not. So 「双击 history +1」 is red on
    /// that wiring, and green only through `PanelResets.field` (section 2 above).
    func testCounterProofARowBoundStraightToTheModelNeverMovesTheHistory() throws {
        let session = try Catalogue.makeSession()
        let base = session.history.count

        // The broken wiring: the binding writes, nothing commits.
        session.applyEdit { $0.optics.caRed = OpticsGroup.alpha(fromSlider: 40) }
        XCTAssertEqual(session.edit.optics.caRed, 0.002, "像素会变 —— 所以这个 bug 看起来像好的")
        XCTAssertEqual(session.history.count, base, "…但历史没动")

        // The "double-click" of that wiring: write the default through the same door.
        session.applyEdit { $0.optics.caRed = 0 }
        XCTAssertEqual(session.edit.optics.caRed, 0)
        XCTAssertEqual(session.history.count, base, "直接绑 EditModel 的双击 = 零条历史")
        XCTAssertNotEqual(session.history.count, base + 1, "反证：这一条就是验收里必红的那个断言")

        // The shipped wiring, for contrast: the panel's verb does mint the row.
        // The shipped wiring, for contrast: the panel's own verb mints the row the direct binding lost.
        XCTAssertTrue(PanelResets(session: session).group(.correction))
        XCTAssertEqual(session.history.count, base + 1, "面板的动词会写一条 —— 直接绑定不会")
        print("CA COUNTER-PROOF · direct binding: history \(base) · via PanelResets: "
              + "\(session.history.count)")
    }

    /// The card must go through the panel's furniture: `PanelResets` for each name, one `commitEdit` on
    /// release, the panel's only `sliderRow`, and no slider of its own. A card that wrote the model
    /// directly would pass the pixel test above and fail the double-click one.
    func testTheCardGoesThroughThePanelFurniture() throws {
        let card = try Self.body(of: "private var correctionCard: some View {",
                                 upTo: "/// 2026-10-28 (078 B8 / 096) — **色差**",
                                 in: Self.inspectorSource)
        XCTAssertTrue(card.contains("ForEach(Self.caRows"), "两行来自卡自己的表")
        XCTAssertTrue(card.contains("caSliderRow(row)"), "每一行都要画出来")
        XCTAssertTrue(card.contains("resetGroup(.correction)"), "标题双击 = 整组复位")

        let detail = try Self.body(of: "private var detailCard: some View {",
                                   upTo: "/// 2026-10-28 (096) — **校正**",
                                   in: Self.inspectorSource)
        XCTAssertFalse(detail.contains("ForEach(Self.caRows"), "细节卡里不许再画色差")
        XCTAssertFalse(detail.contains("caSliderRow(row)"), "细节卡里不许再有色差行")

        let rows = try Self.body(of: "private func caSliderRow(_ row: ToneRow) -> some View {",
                                 upTo: "/// 色差's slider position ↔ document α",
                                 in: Self.inspectorSource)
        XCTAssertTrue(rows.contains("resets.field(row.keyPath, label: row.title)"),
                      "每行的双击复位必须走 PanelResets")
        XCTAssertTrue(rows.contains("if !editing { session.commitEdit(label: row.title) }"),
                      "拖动结束必须提交一条，标签是行名")
        XCTAssertTrue(rows.contains("caBinding(row)"), "数值走滑杆单位 ↔ α 的那一处转换")
        XCTAssertEqual(Self.occurrences(of: "Slider(value: ", in: rows), 0, "卡里不许自己造滑杆")
        XCTAssertFalse(rows.contains("step:"), "没有刻度线（046）")
        XCTAssertTrue(rows.contains("sliderRow("), "行是面板唯一的那根行")

        let binding = try Self.body(of: "private func caBinding(_ row: ToneRow) -> Binding<Double> {",
                                    upTo: "    /// 「解码模型」", in: Self.inspectorSource)
        XCTAssertTrue(binding.contains("OpticsGroup.alpha(fromSlider: position)"),
                      "写进去的是 α，不是滑杆位置")
        XCTAssertTrue(binding.contains("OpticsGroup.sliderPosition(forAlpha:"),
                      "读出来的是滑杆位置（同一个映射的逆）")
        XCTAssertFalse(binding.contains("step:"))
    }

    // MARK: - host

    private enum Catalogue {
        /// A session with one CA number on each channel (so the card is not all zeros).
        @MainActor
        static func makeSession() throws -> CatalogSession {
            let session = CatalogSession()
            session.applyEdit {
                $0.optics.caRed = OpticsGroup.alpha(fromSlider: 10)
                $0.optics.caBlue = OpticsGroup.alpha(fromSlider: -20)
            }
            session.commitEdit(label: "色差")
            return session
        }
    }

    private struct Panel {
        let host: NSHostingView<InspectorView>
        let window: NSWindow
        let probes: [ChromaticAberrationProbe]

        var cardFrame: CGRect? {
            probes.first { $0.rowID == ChromaticAberrationProbe.cardID }
                .map { $0.convert($0.bounds, to: host) }
        }

        var detailCardFrame: CGRect? {
            probes.first { $0.rowID == ChromaticAberrationProbe.detailCardID }
                .map { $0.convert($0.bounds, to: host) }
        }

        func rowFrame(_ id: String) -> CGRect? {
            probes.first { $0.rowID == id }.map { $0.convert($0.bounds, to: host) }
        }

        func numberField(_ id: String) -> NumberTextField? {
            Self.all(NumberTextField.self, in: host)
                .first { $0.accessibilityIdentifier() == id }
        }

        static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            var found: [T] = []
            if let hit = view as? T { found.append(hit) }
            for sub in view.subviews { found += all(type, in: sub) }
            return found
        }
    }

    private func host(width: CGFloat, filled: Bool) throws -> Panel {
        let session = filled ? try Catalogue.makeSession() : CatalogSession()
        return try host(session: session, width: width)
    }

    private func host(session: CatalogSession, width: CGFloat) throws -> Panel {
        _ = NSApplication.shared
        // 调整 is the default workspace, and 细节 is its sixth card — the card this task added to.
        let host = NSHostingView(rootView: InspectorView(session: session))
        host.frame = NSRect(x: 0, y: 0, width: width, height: Self.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return Panel(host: host, window: window,
                     probes: Panel.all(ChromaticAberrationProbe.self, in: host))
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

    private func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    // MARK: - render helpers

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        return try XCTUnwrap(result.display)
    }

    /// The synthetic frame: three concentric discs, one per channel, radii 702 / 700 / 698.
    ///
    /// 1600 × 1600 so the optical axis the kernel uses (`srcSize · 0.5` = 800.0) is a texel boundary:
    /// every step then lands exactly on an integer screen coordinate, which is what makes the edge
    /// readable at all. Rows 799 and 800 are identical (the disc is symmetric about y = 800), so the
    /// half-texel vertical blend at the centre row cannot perturb the measurement.
    private enum Fringe {
        static let w = 1600
        static let h = 1600
        static let axis = 800.0
        static let halfWidth = 800
        static let base: Float = 0.30
        static let bright: Float = 0.70
        static let rRed = 702
        static let rGreen = 700
        static let rBlue = 698

        /// The α = 0 frame of this image, **measured on `c9aa22e`** — main, before 色差 had any UI — by a
        /// throwaway probe in a worktree of that commit that built this exact fixture (same 1600², same
        /// radii, same levels) and rendered `EditModel.neutral` through the same `RenderGraph`. This
        /// branch produces the identical digest, so 「两根滑杆在 0 = 未接 UI 前的那一帧，逐字节」 is a
        /// measurement of two commits, not an inference.
        static let neutralSHA256 = "20e92c47bd5c862d588edce11f1ddce172fb8547bc27c9de0473261eeca1ad29"

        static func image() -> LinearImage {
            var rgba = [Float16](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    let o = (y * w + x) * 4
                    let dx = Double(x) + 0.5 - axis
                    let dy = Double(y) + 0.5 - axis
                    let r2 = dx * dx + dy * dy
                    for (channel, radius) in [(0, rRed), (1, rGreen), (2, rBlue)] {
                        let r = Double(radius)
                        rgba[o + channel] = Float16(r2 <= r * r ? bright : base)
                    }
                    rgba[o + 3] = 1
                }
            }
            return LinearImage(width: w, height: h, rgba: rgba,
                               colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-ca")
        }

        /// sRGB decode of one display code, in `Double` (`RenderTests`/`ChromaticAberrationTests`' curve).
        static func linear(_ v: Float16) -> Double {
            let x = Double(Float(v))
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }

        /// The first display column at or after `from` whose linear value is past the halfway mark —
        /// the hard edge of a channel that never moved. At α = 0 the sample coordinate *is* the pixel
        /// centre, so this is an exact texel index and nothing is interpolated.
        static func firstBright(_ image: DisplayImage, channel: Int, y: Int, from: Int) throws -> Int {
            let mid = (Double(base) + Double(bright)) / 2
            for x in from..<(from + 32) where x >= 0 && x < image.width {
                if linear(image.rgba[(y * image.width + x) * 4 + channel]) > mid { return x }
            }
            throw XCTSkip("no edge within 32 px of \(from) for channel \(channel)")
        }

        /// Where one channel's step lands **on screen**, to a ten-thousandth of a pixel, and the α that
        /// position implies.
        ///
        /// The kernel samples `u = axis + (x − axis)(1 + α)`, and `sample_bilinear` blends texels
        /// `⌊u − 0.5⌋` and `+1`, so a step whose texel `k` is the first bright one reads `base` below
        /// `u = k` and `bright` above it, **linearly** in between (the blend is affine in `u`, the ramp is
        /// one texel wide). The display value is therefore affine in `x` across the edge, so interpolating
        /// the halfway crossing between the two pixels that bracket it recovers `x_cross` exactly, and
        /// `u(x_cross) = k` gives `α` back:
        ///
        ///     α = (k − axis)/(x_cross − axis) − 1
        ///
        /// This covers the hard case too (an α that lands the sample exactly on a texel boundary leaves
        /// no blended pixel: `base` and `bright` are adjacent and the crossing *is* the boundary).
        static func measure(_ image: DisplayImage, channel: Int, k: Int, y: Int)
            throws -> (alpha: Double, x: Double) {
            let mid = (Double(base) + Double(bright)) / 2
            var values: [(x: Double, v: Double)] = []
            for i in (k - 10)...(k + 10) where i >= 0 && i < image.width {
                values.append((Double(i) + 0.5, linear(image.rgba[(y * image.width + i) * 4 + channel])))
            }
            for (lo, hi) in zip(values, values.dropFirst()) {
                guard lo.v < mid, hi.v >= mid, hi.v > lo.v else { continue }
                let xCross = lo.x + (mid - lo.v) / (hi.v - lo.v) * (hi.x - lo.x)
                let alpha = (Double(k) - axis) / (xCross - axis) - 1
                return (alpha, xCross)
            }
            var dump = ""
            for (x, v) in values { dump += String(format: " %.1f:%.5f", x, v) }
            print("DIAG k=\(k) ch=\(channel)" + dump)
            throw XCTSkip("channel \(channel): no edge beside texel \(k)")
        }
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
