import XCTest
import AppKit
import GRDB
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsCatalog
@testable import PhotonsUI

/// 081 — ⌘C 按**卡片**选择：the sheet's rows, the child switch, and the shipped path through it.
///
/// What is pinned here, one test per claim:
///
///   ① **⌘C 不复制、只弹框** (`testCommandCOpensTheSheetAndCopiesNothingUntilConfirmed`) — the action
///      asks first; a cancelled sheet leaves `copiedSettings` nil. The 反证 is the old behaviour: one
///      line that calls `copySettingsFromAnchor()` directly would make `copiedSettings` non-nil before
///      any click, and the first assertion fails.
///   ② **卡片粒度** (`testTheSheetHasTwelveCardRows…`) — 12 rows,标题 == 卡片名, and 勾 白平衡 + 黑电平 +
///      Light then pasting to B moves exactly `temperature/tint/blackOffset/exposure/contrast` while
///      `saturation` / HSL / 黑白 / 效果 are **byte-identical** (the structs compare equal). The 反证
///      lives in the same class: if `light` were one section (078's shape), checking 黑电平 alone would
///      move 曝光 too — `testOnlyBlackLevelMovesNothingElse` is that assertion.
///   ③ **子项开关** (`testTurningOnShowsChildrenDrawsEveryParameterAndNarrowsToOne`) — `showsChildren =
///      true` → 12 + Σchildren rows, and checking 曝光 alone pastes only 曝光 (对比 unchanged).
///   ⑥ **预设卡消失、菜单还在** (`testThePresetCardIsGoneAndTheMenuBarHasATopLevelPresetMenu`).
///   ⑦ **保存为预设** (`testSavingTwoCardsAsAPresetStoresThoseCardsAndAppliesOnlyThem`).
@MainActor
final class CopySheetCardTests: XCTestCase {

    private var workDir: URL!
    private var packageURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-copysheet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        packageURL = workDir.appendingPathComponent("CS.\(LibraryLayout.packageExtension)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    /// A: every card the acceptance names has a non-default value, so a *whole-document* copy would
    /// visibly move all of them.
    private func documentA() -> EditModel {
        var a = EditModel.neutral
        a.light.temperature = 5500
        a.light.tint = 10
        a.light.blackOffset = 0.004
        a.light.exposure = 1.2
        a.light.contrast = 15
        a.color.vibrance = 20
        a.color.saturation = 25
        a.color.bands[2] = HSLBand(hue: 12, saturation: -8, luminance: 4, mix: 0)
        a.color.bands[5] = HSLBand(hue: 0, saturation: 0, luminance: 0, mix: 30)
        a.color.blackAndWhite = false
        a.colorGrading.shadows = GradeWheel(hue: 10, saturation: 20, lightness: -5)
        a.curve.white = [CurvePoint(0, 0), CurvePoint(1, 1.2), CurvePoint(2, 2)]
        a.effects.vignetteAmount = -20
        a.effects.grain = 12
        a.effects.clarity = 8
        a.detail.sharpening = 40
        return a
    }

    /// B: its own values everywhere, none of them equal to A's by accident.
    private func documentB() -> EditModel {
        var b = EditModel.neutral
        b.light.temperature = 4800
        b.light.tint = 5
        b.light.blackOffset = -0.002
        b.light.exposure = -0.4
        b.light.contrast = 6
        b.color.saturation = 30
        b.color.bands[1] = HSLBand(hue: -9, luminance: -6, mix: 0)
        b.colorGrading.highlights = GradeWheel(hue: -4, saturation: 6, lightness: 2)
        b.curve.white = [CurvePoint(0, 0), CurvePoint(1, 0.85), CurvePoint(2, 2)]
        b.effects.vignetteAmount = 15
        b.effects.grain = 3
        b.detail.sharpening = 5
        return b
    }

    @discardableResult
    private func insertAsset(_ catalog: Catalog, name: String, edit: EditModel) throws -> String {
        let rootDir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: rootDir, mode: .reference)
        let blob = try Catalog.encode(edit)
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                          kind: .raw, size: 1024, mtime: 0,
                          contentHash: UUID().uuidString, developJson: blob)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try AssetHistory(assetId: asset.id, seq: 1, developJson: blob,
                             label: "import", createdAt: ISO8601.now()).insert(db)
        }
        return asset.id
    }

    /// A library with A (the look) and B/C (the targets), opened in a session anchored on A.
    private func makeSession() throws -> (CatalogSession, Catalog, [String]) {
        let setup = try Catalog.create(at: packageURL)
        let ids = [try insertAsset(setup, name: "A.dng", edit: documentA()),
                   try insertAsset(setup, name: "B.dng", edit: documentB()),
                   try insertAsset(setup, name: "C.dng", edit: documentB())]
        let reader = try Catalog.open(at: packageURL)
        let session = CatalogSession()
        try session.open(packageURL)
        session.selectOnly(ids[0])
        XCTAssertEqual(session.anchorID, ids[0])
        return (session, reader, ids)
    }

    private func changedKeys(_ before: EditModel, _ after: EditModel) -> Set<String> {
        Set(EditHistory.changedFields(between: before, and: after).map { change in
            change.field.key.hasPrefix("curve.") ? "curve.white" : change.field.key
        })
    }

    /// The sheet's answer for 「勾这三张卡」, driven through the real checkboxes.
    private func selection(clicking sections: [EditSnapshotSection]) -> CopySettingsSelection {
        let view = CopySettingsAccessoryView(selection: .none, purpose: .copy)
        for section in sections { view.click(section) }
        return view.selection
    }

    // MARK: - ① ⌘C opens the sheet, copies nothing by itself

    func testCommandCOpensTheSheetAndCopiesNothingUntilConfirmed() throws {
        let (session, _, ids) = try makeSession()
        let controller = EditorWindowController(size: NSSize(width: 900, height: 600))
        try controller.session.open(packageURL)
        controller.session.selectOnly(ids[0])
        let target = controller.session
        XCTAssertNil(target.copiedSettings, "nothing copied yet")

        var asked: [(CopySettingsAccessoryView.Purpose, CopySettingsSelection)] = []
        controller.presentCopySheet = { purpose, selection in
            asked.append((purpose, selection))
            return .confirm(selection)
        }
        controller.copySettingsAction(nil)
        print("081 ⌘C: asked=\(asked.count) purpose=\(String(describing: asked.first?.0))"
              + " copied=\(String(describing: target.copiedSettings?.fieldCount))")
        XCTAssertEqual(asked.count, 1, "⌘C opened the sheet")
        XCTAssertEqual(asked.first?.0, .copy)
        XCTAssertNotNil(target.copiedSettings, "and only the answer produced a payload")
        XCTAssertEqual(target.copiedSettings?.fieldCount, 19, "A's non-default leaves")

        // 反证: cancelled → nothing copied, still nil.
        var fresh = CatalogSession()
        try fresh.open(packageURL)
        fresh.selectOnly(ids[0])
        XCTAssertNil(fresh.copiedSettings)
        let quiet = EditorWindowController(size: NSSize(width: 900, height: 600))
        try quiet.session.open(packageURL)
        quiet.session.selectOnly(ids[0])
        quiet.presentCopySheet = { _, _ in nil }
        quiet.copySettingsAction(nil)
        XCTAssertNil(quiet.session.copiedSettings,
                     "反证: a ⌘C that copies before asking would leave a payload here")
        _ = session
    }

    // MARK: - ② 12 card rows, titles == the panel's card names

    func testTheSheetHasTwelveCardRowsInPanelOrderAndTheirTitlesAreTheCards() throws {
        let view = CopySettingsAccessoryView(selection: .all, purpose: .copy)
        view.layoutSubtreeIfNeeded()

        let cardRows = view.rows.filter(\.isCard)
        print("081 rows: \(cardRows.count) cards · titles \(cardRows.map(\.title))")
        XCTAssertEqual(cardRows.count, 12, "十二张卡：白平衡…蒙版")
        XCTAssertEqual(cardRows.map(\.title),
                       ["白平衡", "黑电平", "Light", "Color", "黑白", "HSL", "色彩分级",
                        "曲线", "细节", "效果", "裁切", "蒙版"])
        // The row order *is* the inspector's render order — not a second list (曲线 above 细节 since
        // 2026-10-28). 调整's cards are 白平衡…效果, 黑白/HSL/色彩分级 are 色彩's, and 裁切/蒙版 are the
        // other two workspaces' single cards.
        let adjust = InspectorView.cardTitles(in: .adjust)
        let cardTitles = cardRows.map(\.title)
        // 096: 校正 卡（色差 R/B）不进复制表 —— 它的字段仍在既有组里，和 变换 卡的处境一样；
        // 所以「对话框的行 = 检查器的卡」这条只对**进了复制表的卡**成立。
        XCTAssertEqual(cardTitles.filter { adjust.contains($0) && $0 != "校正" },
                       adjust.filter { $0 != "校正" },
                       "对话框里属于调整工作区的行序必须跟着检查器的卡序：\(cardTitles) vs \(adjust)")
        // 087: 角度 card's fields (转动 / 旋转 / 镜像) live in `EditSnapshotSection.crop`, so the
        // copy sheet has no separate 角度 row even though the inspector draws a second card.
        XCTAssertEqual(Set(cardRows.map(\.title)),
                       Set([adjust, InspectorView.cardTitles(in: .colour),
                            InspectorView.cardTitles(in: .transform),
                            InspectorView.cardTitles(in: .masks)].flatMap { $0 })
                           .subtracting(["变换", "校正"]))
        // 默认不画子项。
        XCTAssertEqual(view.rows.count, 12, "默认只有卡级行（081 §2）")
    }

    // MARK: - ② 卡片粒度: 白平衡 + 黑电平 + Light

    func testWhiteBalanceBlackLevelAndLightMoveExactlyThoseLeavesAndNothingElse() throws {
        let (session, catalog, ids) = try makeSession()
        let (a, b) = (ids[0], ids[1])
        session.selectOnly(a)
        let choice = selection(clicking: [.whiteBalance, .blackLevel, .light])
        XCTAssertEqual(choice.sections, [.whiteBalance, .blackLevel, .light])

        let payload = try XCTUnwrap(session.copySettingsFromAnchor(selection: choice))
        XCTAssertEqual(payload.sections, [.whiteBalance, .blackLevel, .light])
        XCTAssertEqual(payload.fieldCount, 5, "色温 + 色调 + 黑电平 + 曝光 + 对比")

        // ⑧ 复制不写历史、不改文档.
        XCTAssertEqual(try catalog.editHistory(forAsset: b).count, 1, "复制没有给 B 加历史")
        XCTAssertEqual(try Catalog.encode(session.edit), try Catalog.encode(documentA()),
                       "复制没有改文档")

        let before = try catalog.develop(forAsset: b)
        session.selectOnly(b)
        let reports = session.pasteSettings(selection: choice)
        let after = try catalog.develop(forAsset: b)
        let keys = changedKeys(before, after)
        print("081 白平衡+黑电平+Light → B: \(keys.sorted()) | \(reports.first?.summary ?? "-")")

        XCTAssertEqual(keys, ["light.temperature", "light.tint", "light.blackOffset",
                              "light.exposure", "light.contrast"])
        XCTAssertEqual(after.light.temperature, 5500)
        XCTAssertEqual(after.light.tint, 10)
        XCTAssertEqual(after.light.blackOffset, 0.004, accuracy: 1e-12)
        XCTAssertEqual(after.light.exposure, 1.2)
        XCTAssertEqual(after.light.contrast, 15)

        // 逐字节不变: the structs the three cards do **not** own compare equal to B's own.
        XCTAssertEqual(after.color, before.color, "Color / 黑白 / HSL 一个字节都没动")
        XCTAssertEqual(after.colorGrading, before.colorGrading, "色彩分级没动")
        XCTAssertEqual(after.effects, before.effects, "效果没动")
        XCTAssertEqual(after.curve, before.curve)
        XCTAssertEqual(after.geometry, before.geometry)
        XCTAssertEqual(after.detail, before.detail)
        XCTAssertEqual(after.masks, before.masks)
    }

    /// 反证 for ②: if `light` were still one section (078's shape), checking **only** 黑电平 would also
    /// paste 曝光/对比. This asserts the split is real — the offset moves, the tone does not.
    func testOnlyBlackLevelMovesNothingElse() throws {
        let (session, catalog, ids) = try makeSession()
        let (a, b) = (ids[0], ids[1])
        session.selectOnly(a)
        let choice = selection(clicking: [.blackLevel])
        XCTAssertEqual(choice.sections, [.blackLevel])

        let payload = try XCTUnwrap(session.copySettingsFromAnchor(selection: choice))
        XCTAssertEqual(payload.fieldCount, 1)
        XCTAssertNil(payload.light?.exposure, "曝光 is not in a 黑电平 copy")
        XCTAssertNil(payload.light?.temperature)

        let before = try catalog.develop(forAsset: b)
        session.selectOnly(b)
        _ = session.pasteSettings(selection: choice)
        let after = try catalog.develop(forAsset: b)
        mirrorLog("081 只勾黑电平 → B", changedKeys(before, after))
        XCTAssertEqual(changedKeys(before, after), ["light.blackOffset"],
                       "反证: 把 light 当一个 section 写死，这里会出现 light.exposure")
        XCTAssertEqual(after.light.exposure, before.light.exposure)
        XCTAssertEqual(after.light.contrast, before.light.contrast)
    }

    // MARK: - ③ 子项存在但不展示

    func testTurningOnShowsChildrenDrawsEveryParameterAndNarrowsToOne() throws {
        XCTAssertFalse(CopySettingsSheet.showsChildren, "默认不展示子项（一个常量，不是注释）")
        let childCount = EditSnapshotChild.allCases.count
        let rows = CopySettingsAccessoryView.rows(showsChildren: true)
        print("081 rows with children: \(rows.count) = 12 + \(childCount)")
        XCTAssertEqual(rows.count, 12 + childCount)
        XCTAssertEqual(rows.filter { !$0.isCard }.count, childCount)
        XCTAssertEqual(EditSnapshotSection.panelOrder.flatMap(\.children).count, childCount)

        let view = CopySettingsAccessoryView(selection: .none, purpose: .copy, showsChildren: true)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.rows.count, 12 + childCount, "打开开关后子项真的画出来了")
        XCTAssertEqual(view.childCheckboxes.count, childCount)
        XCTAssertEqual(view.childCheckboxes[.exposure]?.title, "曝光")

        // 只勾 曝光 → paste writes exposure and nothing else.
        view.click(.exposure)
        XCTAssertEqual(view.selection.sections, [.light])
        XCTAssertEqual(view.selection.children, [.exposure])
        XCTAssertTrue(view.selection.contains(.exposure))

        let (session, catalog, ids) = try makeSession()
        session.selectOnly(ids[0])
        _ = session.copySettingsFromAnchor(selection: view.selection)
        let before = try catalog.develop(forAsset: ids[1])
        session.selectOnly(ids[1])
        _ = session.pasteSettings(selection: view.selection)
        let after = try catalog.develop(forAsset: ids[1])
        mirrorLog("081 只勾子项「曝光」 → B", changedKeys(before, after))
        XCTAssertEqual(changedKeys(before, after), ["light.exposure"], "对比不许动")
        XCTAssertEqual(after.light.contrast, before.light.contrast)
        XCTAssertEqual(after.light.temperature, before.light.temperature)
    }

    // MARK: - ⑥ 预设卡消失，菜单栏出现顶级 预设

    func testThePresetCardIsGoneAndTheMenuBarHasATopLevelPresetMenu() throws {
        XCTAssertFalse(InspectorView.sectionTitles.contains("预设"),
                       "预设 卡已删：\(InspectorView.sectionTitles)")
        XCTAssertFalse(InspectorView.cardTitles(in: .adjust).contains("预设"))

        let menu = MainMenu.build()
        let previous = NSApp.mainMenu
        NSApp.mainMenu = menu
        defer { NSApp.mainMenu = previous }

        let titles = menu.items.compactMap(\.submenu).map(\.title)
        print("081 menu bar: \(titles)")
        XCTAssertTrue(titles.contains("预设"), "顶部菜单里按标题找得到 预设：\(titles)")
        XCTAssertFalse(titles.contains("显影"), "显影 只剩预设一项，已由顶级 预设 取代")

        let presetMenu = try XCTUnwrap(menu.items.compactMap(\.submenu)
            .first(where: { $0.title == "预设" }) as? PresetMenu,
            "顶级 预设 就是那个从库里重建的 PresetMenu")
        presetMenu.menuNeedsUpdate(presetMenu)
        let rowTitles = presetMenu.items.map(\.title)
        print("081 preset menu rows: \(rowTitles)")
        XCTAssertTrue(rowTitles.contains { $0.contains("新建") },
                      "菜单里有「新建」子项：\(rowTitles)")
        XCTAssertTrue(presetMenu.items.contains {
            $0.action == #selector(EditorWindowController.newPresetFromCurrentAction(_:))
        })
    }

    // MARK: - ⑦ 保存为预设（只含勾选的两张卡）

    func testSavingTwoCardsAsAPresetStoresThoseCardsAndAppliesOnlyThem() throws {
        let (session, catalog, ids) = try makeSession()
        session.selectOnly(ids[0])
        let before = try Catalog.encode(session.edit)
        let rowsBefore = try catalog.editHistory(forAsset: ids[0]).count

        let controller = EditorWindowController(size: NSSize(width: 900, height: 600))
        try controller.session.open(packageURL)
        controller.session.selectOnly(ids[0])
        let live = controller.session
        let choice = selection(clicking: [.curve, .effects])
        controller.presentCopySheet = { _, _ in .savePreset(choice) }
        controller.askPresetName = { _ in "T081" }

        controller.copySettingsAction(nil)

        let record = try XCTUnwrap(try catalog.presetRecord(named: "T081"),
                                   "库里多了一条 presetRecords")
        print("081 preset T081: sections=\(record.preset.sections.map { $0.map(\.rawValue).sorted() } ?? [])"
              + " groups=\(PresetGroup.ordered(record.groups).map(\.rawValue))")
        XCTAssertEqual(record.preset.sections, [.curve, .effects])
        // 菜单与面板读的是同一份缓存：保存完就刷新，不用重启。
        XCTAssertTrue(live.presetRecords.contains { $0.name == "T081" },
                      "保存后 session.presetRecords 里就有它（菜单下次打开就在）")

        // 只含那两张卡的字段: nothing outside curve/effects moved away from neutral.
        let storedKeys = changedKeys(.neutral, record.edit)
        XCTAssertFalse(storedKeys.isEmpty)
        XCTAssertTrue(storedKeys.allSatisfy { $0.hasPrefix("curve.") || $0.hasPrefix("effects.") },
                      "只含 2 个 section 的字段；实际 \(storedKeys.sorted())")
        XCTAssertEqual(record.edit.light, EditModel.neutral.light, "预设里没有 A 的曝光/白平衡")

        // 新文档应用 T081 → 只有那 2 项变.
        var fresh = EditModel.neutral
        fresh.light.exposure = 0.7
        fresh.light.temperature = 4300
        fresh.color.saturation = 12
        let applied = record.preset.apply(to: fresh)
        let appliedKeys = changedKeys(fresh, applied)
        print("081 apply T081 → new doc: \(appliedKeys.sorted())")
        XCTAssertTrue(appliedKeys.allSatisfy { $0.hasPrefix("curve.") || $0.hasPrefix("effects.") },
                      "只有那 2 项变；实际 \(appliedKeys.sorted())")
        XCTAssertEqual(applied.light.exposure, 0.7, "别的卡的数值一个都没动")
        XCTAssertEqual(applied.light.temperature, 4300)
        XCTAssertEqual(applied.color.saturation, 12)
        XCTAssertEqual(applied.effects.vignetteAmount, -20, "效果卡带的是 A 的当前数值")
        XCTAssertEqual(applied.effects.grain, 12)

        // ⑧ 复制与保存预设不写历史、不改文档.
        XCTAssertEqual(try Catalog.encode(live.edit), before, "保存预设没有改文档")
        XCTAssertEqual(try catalog.editHistory(forAsset: ids[0]).count, rowsBefore,
                       "保存预设不写历史")
        XCTAssertEqual(live.history.count, session.history.count,
                       "复制/保存预设都不进撤销栈")
    }

    /// 反证 for ⑦: 「保存为预设」 written as 「保存整份文档」 would carry every card A has — so the
    /// assertion 「只含那 2 个 section 的字段」 goes red. Measured, not asserted by comment.
    func testAWholeDocumentPresetWouldCarryEveryCard() throws {
        var a = documentA()
        a.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let whole = Preset(name: "Whole", from: a)
        let wholeKeys = changedKeys(.neutral, whole.edit)
        print("反证 whole-document preset: \(wholeKeys.count) keys of \(EditSnapshot.fullDocumentFieldCount)"
              + " sections=\(PresetGroup.ordered(whole.groups).map(\.rawValue))")
        XCTAssertTrue(wholeKeys.contains { $0.hasPrefix("light.exposure") },
                      "反证: 整份文档的预设带着 A 的曝光")
        XCTAssertTrue(wholeKeys.contains { $0.hasPrefix("color.") },
                      "反证: 以及 A 的 Color/HSL/黑白")
        XCTAssertTrue(wholeKeys.contains { $0.hasPrefix("effects.") })
        XCTAssertNil(whole.sections, "整份文档的预设没有卡片范围")

        // The sheet's two-card save, in contrast, carries only curve + effects.
        let two = Preset(name: "Two", fromSections: [.curve, .effects], of: a)
        let twoKeys = changedKeys(.neutral, two.edit)
        XCTAssertTrue(twoKeys.allSatisfy { $0.hasPrefix("curve.") || $0.hasPrefix("effects.") },
                      "反证的另一半：两卡预设只带那两张卡的字段；实际 \(twoKeys.sorted())")
        XCTAssertLessThan(twoKeys.count, wholeKeys.count)
    }

    // MARK: - helpers

    private func mirrorLog(_ label: String, _ keys: Set<String>) {
        print("\(label): \(keys.sorted())")
    }
}
