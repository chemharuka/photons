import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 325 — **复制清单跟着调整栏走，而不是跟着另一张表走。**
///
/// The user's two sentences, as tests:
///
///   ① 「各调整的名称严格按照现在UI上的来」 — every copy item's label is read off the panel row it
///      copies (`EditSnapshotChild.title` → `CopyRowCoverage` → `ToneRow.title` / `BlockGroup.title`),
///      and this file compares them **row by row, byte for byte**, not card header by card header.
///      Nothing did before this ticket, which is how 「高光恢复」 stayed in the list a year after the
///      slider went, and why 白 / 黑 / 自然饱和度 / 饱和度 had drifted from 白色 / 黑色 / 自然饱和 / 饱和.
///
///   ② 「以后修改调整栏的布局时，不会漏掉调整复制界面」 — `testEveryPanelRowHasExactlyOneCopyItem…`
///      walks **every row of every spec card** and demands exactly one item, and the reverse: every
///      item must land on a row the panel draws. Add a slider to a card and this file is red until the
///      clipboard learns it. `testAFakeRowTurnsTheAuditRed` proves the audit can fail at all.
///
/// 校准 is the one spec card with no items (its seven numbers are one look — the card row copies all
/// seven), and the Light card's 「最高亮度」 is a **preference**, skipped by its identifier's namespace
/// rather than by a hand-written whitelist (§4).
@MainActor
final class CopySheetCoverageTests: XCTestCase {

    // MARK: - the audit itself

    /// One line of the table 325 §3 asks for: 面板行 / 复制项 / 缺失 / 多余.
    struct CardLine: CustomStringConvertible {
        let card: String
        let panelRows: Int
        let items: Int
        /// The card rows are the item: a card the clipboard copies whole (`校准`) has no parameter
        /// rows to narrow, so「每行一项」does not apply — the card row *is* the one item.
        let cardLevel: Bool
        let missing: [String]
        let extra: [String]

        var description: String {
            "\(card) · 面板行 \(panelRows) / 复制项 \(items) / 缺失 \(missing.count) / 多余 \(extra.count)"
                + (cardLevel ? " · 整卡复制（无子项）" : "")
        }
    }

    /// Walk the panel's own table (`specs` is injectable so the reverse gate can hand in a mutated
    /// one) and pair it with the copy list. Everything reported is derived — no name is compared
    /// against a list written here.
    private func audit(specs: [InspectorView.PanelCardSpec] = InspectorView.PanelCardSpec.all,
                       children: [EditSnapshotChild] = EditSnapshotChild.allCases) -> [CardLine] {
        var lines: [CardLine] = []
        for spec in specs {
            let rows = spec.rows
            var claims = Array(repeating: 0, count: rows.count)
            var items = 0
            var extra: [String] = []

            let section = EditSnapshotSection(rawValue: spec.section.rawValue)
            for child in children where child.section == section {
                guard let selector = CopyRowCoverage.selectors[child] else {
                    extra.append("\(child.rawValue)（spec 卡上却没有对照项）")
                    continue
                }
                guard let placement = CopyRowCoverage.placement(of: selector, in: specs),
                      placement.section == section else {
                    extra.append("\(child.rawValue)（对照项解析不到本卡的行）")
                    continue
                }
                items += 1
                for row in placement.rows {
                    if let index = rows.firstIndex(where: { $0.keyPath == row.keyPath }) {
                        claims[index] += 1
                    } else {
                        extra.append("\(child.rawValue)→\(row.title)（不在本卡）")
                    }
                }
            }

            // A card with rows and **no children at all** is copied whole by its own card row
            // (`校准`: seven numbers, one look). Every other card must account for every row.
            let cardLevel = !rows.isEmpty && items == 0
                && !children.contains { $0.section == section }
            var missing: [String] = []
            if !cardLevel {
                for (index, row) in rows.enumerated() {
                    if claims[index] == 0 { missing.append("\(row.title)（没有复制项）") }
                    if claims[index] > 1 { missing.append("\(row.title)（\(claims[index]) 个复制项）") }
                }
            }
            lines.append(CardLine(card: spec.section.title, panelRows: rows.count,
                                  items: items, cardLevel: cardLevel,
                                  missing: missing, extra: extra))
        }
        return lines
    }

    // MARK: - ① 覆盖: 每一行恰好一项，标题逐字节相同（正反两向）

    func testEveryPanelRowHasExactlyOneCopyItemAndItsNameIsThePanelRowsName() throws {
        let specs = InspectorView.PanelCardSpec.all
        let lines = audit()
        for line in lines { print("COVERAGE · \(line)") }
        XCTAssertEqual(lines.count, specs.count)

        for line in lines where !line.cardLevel {
            XCTAssertEqual(line.missing, [], "\(line.card)：面板行没有复制项或不止一个 —— \(line.missing)")
            XCTAssertEqual(line.extra, [], "\(line.card)：复制项在面板上找不到行 —— \(line.extra)")
        }

        // 校准: the card row *is* the item — seven numbers, one look, nothing to narrow.
        let calibration = try XCTUnwrap(lines.first { $0.card == EditSnapshotSection.calibration.title })
        XCTAssertTrue(calibration.cardLevel, "校准 是唯一整卡复制的 spec 卡")
        XCTAssertEqual(calibration.panelRows, 7, "校准 卡七行")
        XCTAssertEqual(calibration.items, 0, "校准 没有子项：整卡一行复制七个数")
        XCTAssertTrue(EditSnapshotSection.calibration.children.isEmpty,
                      "校准 的 children 必须为空，否则「卡行复制全部」的说法就不成立")

        // Totals: 34 spec rows; 校准's 7 are the card's, the other 27 are claimed exactly once.
        XCTAssertEqual(lines.map(\.panelRows).reduce(0, +), 34, "六张 spec 卡共 34 行")
        XCTAssertEqual(lines.map(\.items).reduce(0, +), 22, "22 个复制项")
        let selectors = CopyRowCoverage.selectors
        let singles = selectors.values.filter { !$0.isBlock }.count
        let groups = selectors.values.filter { $0.isBlock }
        XCTAssertEqual(singles, 20, "20 个单行项")
        XCTAssertEqual(groups.count, 2, "两个整块项：暗角 / 颗粒")
        let groupRows = groups.reduce(0) { total, selector in
            total + (CopyRowCoverage.placement(of: selector)?.rows.count ?? 0)
        }
        XCTAssertEqual(groupRows, 7, "暗角 3 + 颗粒 4")
        XCTAssertEqual(singles + groupRows, 27, "校准 之外 27 行，一项不落")

        // 标题逐字节相同 — a single-row item's label IS its row's label.
        var checked: [String] = []
        for (child, selector) in selectors.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let placement = CopyRowCoverage.placement(of: selector) else {
                XCTFail("\(child.rawValue) 在面板上找不到归属")
                continue
            }
            XCTAssertEqual(child.section, placement.section,
                           "\(child.rawValue) 的 section 必须就是它所在的卡")
            switch selector {
            case .row:
                XCTAssertEqual(child.title, placement.rows[0].title,
                               "\(child.rawValue) 的名字必须逐字节等于面板行名")
                checked.append("\(child.rawValue)=\(child.title)")
            case .block(let group):
                XCTAssertEqual(child.title, group.title, "整块项的名字来自 block 自己")
                XCTAssertEqual(placement.rows.count, placement.block.rows.count)
                checked.append("\(child.rawValue)=\(child.title)(\(placement.rows.count) 行)")
            }
        }
        print("TITLES · \(checked.count) items, every label byte-identical to the panel: "
              + checked.joined(separator: " · "))
    }

    // MARK: - ② 反向: 清单里没有面板画不出来的项

    func testTheCopyListHasNoItemThePanelDoesNotDraw() {
        let specSections = Set(InspectorView.PanelCardSpec.all.map(\.section))
        let specSnapshotSections = Set(specSections.compactMap { EditSnapshotSection(rawValue: $0.rawValue) })
        var orphans: [String] = []
        for child in EditSnapshotChild.allCases {
            if specSnapshotSections.contains(child.section) {
                // A child on a spec card must land on a row — this is where a stale child such as
                // 325's removed `.highlightRecovery` would show up.
                guard let selector = CopyRowCoverage.selectors[child] else {
                    orphans.append("\(child.rawValue)（spec 卡上却没有对照项）")
                    continue
                }
                if CopyRowCoverage.placement(of: selector) == nil {
                    orphans.append("\(child.rawValue)（对照项指向面板已不存在的行）")
                }
            } else if child.standaloneTitle == nil {
                // A card with its own body: the child needs its own string, nothing derives it.
                orphans.append("\(child.rawValue)（既不在 spec 卡上，也没有自己的名字）")
            }
        }
        XCTAssertEqual(orphans, [], "清单里有面板画不出来的项：\(orphans)")

        // 325 §2: 「高光恢复」 is gone from the list — the case, the row and the name.
        XCTAssertFalse(EditSnapshotChild.allCases.contains { $0.rawValue == "highlightRecovery" },
                       "`highlightRecovery` 这个 child 已经从清单移除")
        XCTAssertFalse(EditSnapshotChild.allCases.contains { $0.title == "高光恢复" })
        XCTAssertEqual(EditSnapshotChild.allCases.count, 48, "49 → 48：Light 卡上本来就没有那一行")
        print("ITEMS · \(EditSnapshotChild.allCases.count) children · "
              + "\(CopyRowCoverage.selectors.count) on spec cards · "
              + "\(EditSnapshotChild.allCases.count - CopyRowCoverage.selectors.count) on their own bodies")
    }

    /// The reverse **gate**: hand the audit a panel table with one extra row and it must go red, with
    /// that row's name in the report. (The ticket also asks for a source-level run — add the row to
    /// `lightRows`, run this file, read the failure; that transcript is in the ticket's report.)
    func testAFakeRowTurnsTheAuditRed() {
        XCTAssertEqual(audit().filter { !$0.cardLevel }.flatMap(\.missing), [], "反证前必须是绿的")

        // 测试行 names a *document field* the card does not draw (`light.highlightRecovery` is
        // exactly such a field since 320) — the shape of the bug this file exists for.
        let fake = InspectorView.ToneRow(title: "测试行", range: -100 ... 100, format: "%.0f",
                                         shape: .knob, keyPath: \EditModel.light.highlightRecovery)
        let mutated = InspectorView.PanelCardSpec.all.map { spec -> InspectorView.PanelCardSpec in
            guard spec.section == .light else { return spec }
            return InspectorView.PanelCardSpec(
                section: spec.section, group: spec.group,
                blocks: spec.blocks.map { block in
                    block.group == .tone
                        ? InspectorView.PanelCardSpec.Block(group: block.group, rows: block.rows + [fake])
                        : block
                })
        }
        let lines = audit(specs: mutated)
        let light = lines.first { $0.card == "Light" }!
        print("REVERSE GATE · \(light) · \(light.missing)")
        XCTAssertEqual(light.missing, ["测试行（没有复制项）"],
                       "面板多一行而复制清单没动 ⇒ 覆盖测试必须红")
        XCTAssertEqual(light.panelRows, 8)
        XCTAssertEqual(light.items, 7)
    }

    // MARK: - ③ 「最高亮度」 是偏好行：按命名空间跳过

    /// 「最高亮度」 is **not** a document parameter: it is the picture's ceiling (320), drawn as the
    /// Light card's last row by `toneCard(_:extraRow:)` — an extra *view*, with no `ToneRow`, no
    /// keyPath, and nothing for a paste to write. Its identifier says so:
    /// `inspector.display.highestLight` sits outside every card's `inspector.<card>.*` namespace
    /// (`display` is not a `EditSnapshotSection`), which is the rule this file uses to leave it out —
    /// there is no whitelist of titles anywhere.
    func testTheHighestBrightnessRowIsAPreferenceAndStaysOutOfTheCopyList() {
        let panel = host()
        defer { panel.window.contentView = nil }
        let ids = panel.numberFieldIDs

        // The Light card draws exactly its seven spec rows under `inspector.light.`…
        let specIDs = Set(InspectorView.PanelCardSpec.lightCard.rows.map { row in
            InspectorView.PanelCardSpec.lightCard.accessibilityID(for: row)
        })
        let inNamespace = ids.filter { $0.hasPrefix("inspector.light.") }
        XCTAssertEqual(inNamespace, specIDs,
                       "Light 卡命名空间里只许有 spec 的七行：\(inNamespace) vs \(specIDs)")

        // …and the eighth row is the preference, in a namespace that is not a card at all.
        let preference = ids.first { $0.contains("highestLight") } ?? ""
        XCTAssertEqual(preference, "inspector.display.highestLight",
                       "最高亮度 的 id 必须落在 inspector.display.*：\(ids.sorted())")
        let namespace = preference.split(separator: ".").dropLast().joined(separator: ".")
        XCTAssertEqual(namespace, "inspector.display")
        XCTAssertFalse(Set(EditSnapshotSection.allCases.map { "inspector.\($0.rawValue)" }).contains(namespace),
                       "`display` 不是任何一张卡的命名空间 ⇒ 它不是文档行，覆盖测试按这条规则跳过它")
        XCTAssertTrue(ids.contains(preference), "这一行确实画出来了（只是不进清单）")

        // …and the copy list really has nothing under that name, in either direction.
        XCTAssertFalse(EditSnapshotChild.allCases.contains { $0.title == "最高亮度" })
        XCTAssertFalse(InspectorView.PanelCardSpec.all.flatMap(\.rows).contains { $0.title == "最高亮度" },
                       "偏好行没有 ToneRow，所以任何名字都不会被派生出来")
        print("PREFERENCE · \(preference) · namespace \(namespace) ∉ card namespaces · not in the copy list")
    }

    // MARK: - ④ 高光恢复: 新复制不再带它，旧载荷照样粘过去

    func testHighlightRecoveryIsNotCapturedByANewCopyButAnOldPayloadStillPastesIt() throws {
        var source = EditModel.neutral
        source.light.exposure = 1.2
        source.light.highlightRecovery = 0.4

        // A new ⌘C: no child covers the field, so `filtered` never carries it.
        let payload = EditSnapshot.capture(source).filtered(to: CopySettingsSelection.all)
        XCTAssertEqual(payload.light?.exposure, 1.2)
        XCTAssertNil(payload.light?.highlightRecovery, "325：清单里没有它，新复制就不许带它")

        // 「粘贴不动它」: the destination keeps its own value.
        var target = EditModel.neutral
        target.light.highlightRecovery = 0.1
        let pasted = payload.applied(to: target)
        XCTAssertEqual(pasted.light.exposure, 1.2)
        XCTAssertEqual(pasted.light.highlightRecovery, 0.1, "粘贴不许清掉目标自己的 高光恢复")

        // 旧文件往返: a payload written before 325 still carries the key and still pastes it — the
        // field is a wire key, not a child, and dropping it would change what stored payloads mean.
        var legacy = EditSnapshot()
        legacy.light = LightPatch()
        legacy.light?.highlightRecovery = 0.35
        let decoded = try JSONDecoder().decode(EditSnapshot.self,
                                               from: try JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded.light?.highlightRecovery, 0.35, "旧载荷的 高光恢复 必须原样解码")
        XCTAssertEqual(decoded.applied(to: EditModel.neutral).light.highlightRecovery, 0.35,
                       "旧载荷带着它时，粘贴仍然照旧写它")
        print("HIGHLIGHT RECOVERY · child gone · new copy carries nil · old payload still pastes 0.35")
    }

    // MARK: - ⑤ 复制界面画的就是面板的字

    func testTheSheetDrawsThePanelNamesForTheSpecCards() {
        let view = CopySettingsAccessoryView(selection: .all, purpose: .copy)
        view.layoutSubtreeIfNeeded()

        let light = InspectorView.PanelCardSpec.lightCard.rows.map(\.title)
        XCTAssertEqual(light, ["曝光", "对比", "高光", "中间调", "阴影", "白色", "黑色"])
        let lightRows = view.rows.compactMap { row -> String? in
            if case .child(let child, let card) = row, card == .light { return child.title }
            return nil
        }
        XCTAssertEqual(lightRows, light, "复制清单里的 Light 行必须就是面板的七行，名字逐字节相同")

        // The names that had drifted (325's own example) are the panel's now, not the sheet's.
        XCTAssertEqual(view.childCheckboxes[.whites]?.title, "白色")
        XCTAssertEqual(view.childCheckboxes[.blacks]?.title, "黑色")
        XCTAssertEqual(view.childCheckboxes[.vibrance]?.title, "自然饱和")
        XCTAssertEqual(view.childCheckboxes[.saturation]?.title, "饱和")
        for stale in ["白", "黑", "自然饱和度", "高光恢复"] {
            XCTAssertFalse(view.childCheckboxes.values.contains { $0.title == stale },
                           "「\(stale)」不在任何一张卡上，复制界面不许出现")
        }

        // A whole-block item is named by its block, and its tooltip lists what it carries.
        XCTAssertEqual(view.childCheckboxes[.vignette]?.title, "暗角")
        XCTAssertEqual(view.childCheckboxes[.vignette]?.toolTip,
                       "只复制这一组：暗角 / 暗角中点 / 暗角羽化（校正 卡）")
        XCTAssertEqual(view.childCheckboxes[.grain]?.title, "颗粒")
        XCTAssertEqual(view.childCheckboxes[.grain]?.toolTip,
                       "只复制这一组：颗粒数量 / 颗粒大小 / 颗粒粗糙度 / 种子（效果 卡）")
        print("SHEET · Light \(lightRows) · 暗角 \(view.childCheckboxes[.vignette]?.title ?? "-")"
              + " · 颗粒 \(view.childCheckboxes[.grain]?.title ?? "-")")
    }

    // MARK: - helpers

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

    private func host(workspace: InspectorWorkspace = .adjust) -> Hosted {
        _ = NSApplication.shared
        let state = InspectorWorkspaceState(workspace)
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession(), workspaces: state))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 4200)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return Hosted(host: host, window: window)
    }
}

private extension CopyRowCoverage.Selector {
    var isBlock: Bool { if case .block = self { return true }; return false }
}
