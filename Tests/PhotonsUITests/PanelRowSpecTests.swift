import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 125 — **一张表定义一行滑杆**: position, reset scope and block order in `PanelCardSpec`.
///
/// The three acceptance criteria, as tests:
///
///   1. **穷尽性** — every row a spec card renders maps to exactly one card (and every table row is in
///      a spec). A row that exists only in a body, or twice across cards, is red.
///   2. **复位范围 = 卡片范围** — seed every row of a card (and a sentinel in every other card), then
///      one title reset puts *only* that card back to `EditModel.neutral`, adds exactly one history
///      entry, and a second click writes nothing. The other cards' values are byte-for-byte unchanged.
///   3. **迁移演练** — move `vignetteRows` from 校正 to 效果 in the spec list only; both the reset scope
///      and the rendered position move with it, without editing the view or the reset switch.
@MainActor
final class PanelRowSpecTests: XCTestCase {

    private static let panelHeight: CGFloat = 4200

    // MARK: - 2. every row the panel draws must be a row the document notices

    /// 2026-10-31 (185): the sharpen rows shipped with a stage, a key token, history labels and
    /// snapshot leaves — but no `dirtyGroups` comparison, so `applyEdit` short-circuited and **every
    /// drag was silently dropped** (user: 「UI 写了，功能没连上」). 078 B8's 色差 was the same accident.
    ///
    /// This is the invariant that makes that whole class impossible: one step inside a row's own
    /// range has to dirty at least one group. A new slider that forgets the dirty table fails here.
    func testEveryRenderedRowDirtiesAtLeastOneGroup() {
        let rows = InspectorView.PanelCardSpec.all.flatMap(\.rows)
        XCTAssertGreaterThan(rows.count, 24, "行表比这更少说明守卫读到的不是真的表")
        var silent: [String] = []
        for row in rows {
            var after = EditModel.neutral
            let before = after[keyPath: row.keyPath]
            let span = row.range.upperBound - row.range.lowerBound
            let step = max(0.01, span / 100)
            let target = before + step <= row.range.upperBound ? before + step : before - step
            XCTAssertNotEqual(target, before, "\(row.title)：没有任何可移动的一步，守卫推不动它")
            after[keyPath: row.keyPath] = target
            if EditHistory.dirtyGroups(from: .neutral, to: after).isEmpty {
                silent.append(row.title)
            }
        }
        XCTAssertEqual(silent, [],
                       "这些滑杆改了文档却不产生任何脏组 ⇒ applyEdit 会静默丢掉写入：\(silent)")
    }

    // MARK: - 3. every rendered row belongs to exactly one spec

    func testEveryRenderedToneRowBelongsToExactlyOneCardSpec() throws {
        let specs = InspectorView.PanelCardSpec.all
        let rows = specs.flatMap { spec in spec.rows.map { (spec, $0) } }

        // The spec union is exactly the tone tables — no table row outside a spec, no row twice.
        // 185: 锐化四参是 S3.10 的行表（`sharpenRows`），挂在「细节」卡的第三个 block 上。
        let expected = InspectorView.lightRows + InspectorView.colorRows
            + InspectorView.correctionRows + InspectorView.detailFXRows
            + InspectorView.sharpenRows + InspectorView.effectsRows
        XCTAssertEqual(rows.map(\.1.keyPath), expected.map(\.keyPath),
                       "spec 的行必须就是五张卡的全部行表")
        let ids = rows.map { $0.0.accessibilityID(for: $0.1) }
        XCTAssertEqual(Set(ids).count, ids.count, "同一行被两张卡声明（或 id 重复）")
        XCTAssertEqual(Set(rows.map(\.1.keyPath)).count, rows.count,
                       "同一个 keyPath 出现在多个 spec 里")

        // …and the panel really draws exactly those identifiers. A row that exists only in a body
        // would show up here as an orphan id; a spec row that is not drawn would be missing.
        let panel = host()
        defer { panel.window.contentView = nil }
        let caIDs = Set(InspectorView.caRows.map { "inspector.detail.\($0.title)" })
        let scoped = panel.numberFieldIDs.filter { id in
            ["inspector.light.", "inspector.color.", "inspector.correction.",
             "inspector.detailFX.", "inspector.effects."]
                .contains { id.hasPrefix($0) } || caIDs.contains(id)
        }
        XCTAssertEqual(Set(scoped), Set(ids),
                       "渲染出的行与 spec 行不一致 · 多了 \(Set(scoped).subtracting(ids))"
                       + " · 少了 \(Set(ids).subtracting(scoped))")
        print("ROW SPEC · \(specs.map(\.section.rawValue)) · \(rows.count) rows · \(ids.count) ids")
    }

    // MARK: - 2. reset scope == card scope

    func testEachTitleResetRestoresExactlyThatCardsRowsAndNothingElse() {
        let neutral = EditModel.neutral
        for card in InspectorView.PanelCardSpec.all {
            let session = CatalogSession()
            let others = InspectorView.PanelCardSpec.all.filter { $0.section != card.section }

            session.applyEdit { model in
                for row in card.rows { model[keyPath: row.keyPath] = changedValue(row, by: 1) }
                for other in others {
                    for row in other.rows { model[keyPath: row.keyPath] = changedValue(row, by: 2) }
                }
            }
            XCTAssertTrue(session.commitEdit(label: "seed \(card.section.rawValue)"))
            let before = session.history.count
            let othersBefore = others.flatMap { other in
                other.rows.map { session.edit[keyPath: $0.keyPath] }
            }

            let resets = PanelResets(session: session)
            XCTAssertTrue(resets.group(card), "\(card.section.title)：改过的卡必须复位")

            for row in card.rows {
                XCTAssertEqual(session.edit[keyPath: row.keyPath], neutral[keyPath: row.keyPath],
                               "\(card.section.title)：\(row.title) 没有回到 `EditModel.neutral`")
            }
            let othersAfter = others.flatMap { other in
                other.rows.map { session.edit[keyPath: $0.keyPath] }
            }
            XCTAssertEqual(othersAfter, othersBefore,
                           "\(card.section.title) 的复位碰了别的卡")
            XCTAssertEqual(session.history.count, before + 1,
                           "\(card.section.title)：整卡复位必须是一条历史")
            XCTAssertEqual(session.history.currentSnapshot?.label, card.section.title)

            XCTAssertFalse(resets.group(card), "\(card.section.title)：已经在默认值，不许造空快照")
            XCTAssertEqual(session.history.count, before + 1)
            print("CARD RESET · \(card.section.title) · \(card.rows.count) rows → +1 snapshot")
        }
    }

    // MARK: - 3. migration drill: only the spec changes

    func testMovingVignetteRowsBetweenCardsMovesResetScopeAndRendering() throws {
        let shipped = InspectorView.PanelCardSpec.all
        let correction = try XCTUnwrap(shipped.first { $0.section == .correction })
        let effects = try XCTUnwrap(shipped.first { $0.section == .effects })
        let vignette = try XCTUnwrap(correction.blocks.first { $0.group == .vignette })

        // The whole migration: delete one block from 校正, append the same block to 效果. No view code,
        // no reset switch, no field name.
        let movedCorrection = InspectorView.PanelCardSpec(
            section: .correction, group: .correction,
            blocks: correction.blocks.filter { $0.group != .vignette })
        let movedEffects = InspectorView.PanelCardSpec(
            section: .effects, group: .effects,
            blocks: effects.blocks + [vignette])
        let moved = shipped.map { spec -> InspectorView.PanelCardSpec in
            switch spec.section {
            case .correction: return movedCorrection
            case .effects: return movedEffects
            default: return spec
            }
        }

        XCTAssertFalse(movedCorrection.rows.contains { $0.keyPath == \.effects.vignetteAmount },
                       "迁移后校正卡不应再包含暗角")
        XCTAssertTrue(movedEffects.rows.contains { $0.keyPath == \.effects.vignetteAmount },
                      "迁移后效果卡必须包含暗角")

        // (a) reset scope follows the spec.
        let session = CatalogSession()
        session.applyEdit {
            $0.effects.vignetteAmount = -55
            $0.effects.vignetteMidpoint = 70
            $0.effects.vignetteFeather = 30
        }
        XCTAssertTrue(session.commitEdit(label: "暗角"))
        XCTAssertTrue(PanelResets(session: session).group(movedEffects),
                      "暗角现在属于效果：双击效果必须把它们带回来")
        let neutral = EditModel.neutral
        for row in InspectorView.vignetteRows {
            XCTAssertEqual(session.edit[keyPath: row.keyPath], neutral[keyPath: row.keyPath],
                           "\(row.title) 没有跟着 spec 一起复位")
        }

        // 校正 no longer owns them: its title reset writes nothing (its CA rows are neutral).
        let caSession = CatalogSession()
        caSession.applyEdit { $0.effects.vignetteAmount = -55 }
        XCTAssertTrue(caSession.commitEdit(label: "暗角"))
        XCTAssertFalse(PanelResets(session: caSession).group(movedCorrection),
                       "校正卡已经不含暗角，复位不应再碰它")
        XCTAssertEqual(caSession.edit.effects.vignetteAmount, -55)

        // (b) rendering follows the same spec: the rows' identifiers and the effects frame probes
        // move to 效果, and 校正 stops drawing them.
        let before = host()
        defer { before.window.contentView = nil }
        XCTAssertTrue(before.numberFieldIDs.contains("inspector.correction.暗角"),
                      "迁移前暗角在校正卡里")

        let after = host(specs: moved)
        defer { after.window.contentView = nil }
        for row in InspectorView.vignetteRows {
            XCTAssertTrue(after.numberFieldIDs.contains("inspector.effects.\(row.title)"),
                          "\(row.title) 没有画到效果卡里")
            XCTAssertFalse(after.numberFieldIDs.contains("inspector.correction.\(row.title)"),
                           "\(row.title) 仍在校正卡里")
        }
        XCTAssertTrue(after.numberFieldIDs.contains("inspector.detail.色差 R"),
                      "色差仍在（没被迁移带走）")
        let effectProbes = Hosted.all(EffectsRowProbe.self, in: after.host).map(\.rowID)
        for row in InspectorView.vignetteRows {
            XCTAssertTrue(effectProbes.contains(row.title),
                          "\(row.title) 没有效果卡的 frame probe（渲染位置没跟着 spec）")
        }
        XCTAssertFalse(effectProbes.contains("色差 R"), "色差不属于效果卡")
        print("MIGRATION · 暗角 校正→效果 · reset/ids/probes all followed the spec")
    }

    // MARK: - helpers

    /// A value that is not the row's default and still inside its own travel where possible.
    private func changedValue(_ row: InspectorView.ToneRow,
                              by offset: Double) -> Double {
        let start = row.defaultValue
        let up = start + offset
        if row.range.contains(up), up != start { return up }
        let down = start - offset
        if row.range.contains(down), down != start { return down }
        return start + offset
    }

    private struct Hosted {
        let host: NSHostingView<InspectorView>
        let window: NSWindow

        var numberFieldIDs: Set<String> {
            Set(Self.all(NumberTextField.self, in: host)
                .compactMap { $0.accessibilityIdentifier() }
                .filter { !$0.isEmpty })
        }

        static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            var found: [T] = []
            if let hit = view as? T { found.append(hit) }
            for sub in view.subviews { found += all(type, in: sub) }
            return found
        }
    }

    private func host(session: CatalogSession? = nil,
                      specs: [InspectorView.PanelCardSpec] = InspectorView.PanelCardSpec.all) -> Hosted {
        _ = NSApplication.shared
        let session = session ?? CatalogSession()
        let state = InspectorWorkspaceState(.adjust)
        let host = NSHostingView(rootView: InspectorView(session: session, workspaces: state,
                                                         cardSpecs: specs))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: Self.panelHeight)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return Hosted(host: host, window: window)
    }
}
