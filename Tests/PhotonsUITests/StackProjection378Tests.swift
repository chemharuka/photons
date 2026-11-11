import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// §378 — 堆叠的**投影**与三个面。
///
/// The data-layer contract lives in `StackModel378Tests`; this suite is about the one decision that
/// makes "只显示置顶" true everywhere without touching any view: `CatalogSession.assets` **is** the
/// projection. Every claim below is read off the model the three browsers index, never off a private
/// filter one of them might have grown:
///
/// * a stack contributes one row — its 置顶 — and `stacksByTopID` carries the members;
/// * filter / sort / keyboard / range selection see only that row, so a non-top member can neither
///   satisfy a filter nor take part in a batch write;
/// * the grid card, the filmstrip cell and the sidebar row all paint 「⧉ N」 through **the same**
///   `AssetBadges.draw`, and a photo in no stack paints none of it.
@MainActor
final class StackProjection378Tests: XCTestCase {

    private var workDir: URL!
    private var package: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-stack-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        package = workDir.appendingPathComponent("P.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: package)
        let shoot = workDir.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: shoot, mode: .reference)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    private var window: NSWindow?

    /// Rows with **distinct** capture times (minute = index) and distinguishable names, inserted in
    /// ascending time so display order (`capture_time DESC`) is the reverse.
    @discardableResult
    private func seed(_ count: Int, rating: Int = 0, prefix: String = "IMG") throws -> [Asset] {
        var out: [Asset] = []
        for i in 0..<count {
            let name = String(format: "\(prefix)_%02d.dng", i)
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                              kind: .raw, size: 16, mtime: 0,
                              contentHash: UUID().uuidString,
                              captureTime: String(format: "2026-03-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-03-01",
                              rating: rating)
            try catalog.dbQueue.write { db in try asset.insert(db) }
            out.append(asset)
        }
        return out
    }

    private func openSession() throws -> CatalogSession {
        _ = NSApplication.shared
        let session = CatalogSession()
        try session.open(package)
        return session
    }

    private func sqlCount(_ sql: String, _ args: [any DatabaseValueConvertible] = []) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? -1
        }
    }

    /// Paint a view and its visible subviews offscreen — the same routine `MissingFilesUITests` uses,
    /// because a thumbnail card paints its badges on an overlay subview, not on itself.
    private static func paint(_ view: NSView) {
        view.layout()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(max(1, view.bounds.width)),
                                   pixelsHigh: Int(max(1, view.bounds.height)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        for subview in view.subviews where !subview.isHidden {
            subview.draw(subview.bounds)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - ⑦⑧ 投影：10 张，5 张堆叠 → 6 行

    func testTenPhotosWithOneStackOfFiveProjectToSixRows() throws {
        let assets = try seed(10)
        let stacked = Array(assets.prefix(5))
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: stacked.map(\.id)))
        let session = try openSession()

        XCTAssertEqual(session.assets.count, 6, "1 个代表 + 5 张独立")
        XCTAssertEqual(Set(session.assets.compactMap(\.stackId)).count, 1)
        let row = try XCTUnwrap(session.assets.first { $0.stackId != nil })
        XCTAssertEqual(row.id, summary.topID, "代表是置顶那张")
        XCTAssertEqual(session.stacksByTopID.count, 1)
        XCTAssertEqual(session.stacksByTopID[summary.topID]?.count, 5, "⑧ 成员数 5")
        XCTAssertEqual(session.stacksByTopID[summary.topID]?.memberIDs, summary.memberIDs)
        // 非堆叠照片不在字典里。
        for asset in session.assets where asset.stackId == nil {
            XCTAssertNil(session.stacksByTopID[asset.id])
        }
        print("⑦ assets \(session.assets.map(\.filename)) stacks \(session.stacksByTopID.keys.map { String($0.prefix(8)) })")
    }

    // MARK: - ⑨ 键盘导航跳过全部非置顶成员

    func testArrowNavigationWalksOnlyTheRepresentatives() throws {
        // Interleave: two singles, a stack of three, two singles — so "before" and "after" both exist.
        let assets = try seed(7)
        let ids = assets.map(\.id)                       // ascending time
        let stackIDs = [ids[2], ids[3], ids[4]]
        _ = try catalog.makeStack(assetIDs: stackIDs.reversed())   // display order: 4, 3, 2
        let session = try openSession()

        session.selectOnly(session.assets[0].id)
        var walked: [String] = [session.anchorID ?? ""]
        for _ in 0..<(session.assets.count - 1) {
            XCTAssertTrue(session.moveAnchor(by: 1))
            walked.append(session.anchorID ?? "")
        }
        // And back again.
        for _ in 0..<(session.assets.count - 1) {
            XCTAssertTrue(session.moveAnchor(by: -1))
            walked.append(session.anchorID ?? "")
        }

        XCTAssertEqual(session.selection, [session.assets[0].id])
        XCTAssertEqual(session.assets.count, 5, "7 张里 3 张一堆 → 5 行")
        let top = try XCTUnwrap(session.assets.first { $0.stackId != nil }?.id)
        XCTAssertTrue(walked.contains(top))
        for hidden in stackIDs where hidden != top {
            XCTAssertFalse(walked.contains(hidden), "非置顶成员不在导航里：\(hidden)")
        }
        print("⑨ walked \(walked.map { String($0.prefix(4)) })")
    }

    // MARK: - ⑩ ⇧ 范围选择跨过堆叠边界，范围里没有非置顶成员

    func testShiftRangeAcrossAStackNeverContainsAHiddenMember() throws {
        let assets = try seed(8)
        let ids = assets.map(\.id)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [ids[3], ids[4], ids[5]]))
        let session = try openSession()

        let first = session.assets[0].id
        let last = session.assets[session.assets.count - 1].id
        session.selectOnly(first)
        session.selectRange(to: last)

        XCTAssertEqual(session.selection.count, session.assets.count, "从第一行到最后一行的闭区间")
        for hidden in summary.memberIDs where hidden != summary.topID {
            XCTAssertFalse(session.selection.contains(hidden), "范围里没有非置顶成员")
        }
        XCTAssertTrue(session.selection.contains(summary.topID))
        print("⑩ selection \(session.selection.map { String($0.prefix(4)) })")
    }

    // MARK: - ⑪ 非置顶成员不参与任何筛选

    func testFilteringNeverSeesAHiddenMember() throws {
        let assets = try seed(10)
        let ids = assets.map(\.id)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [ids[6], ids[7], ids[8], ids[9]]))
        let hidden = summary.memberIDs.dropFirst().first!
        let session = try openSession()

        // A rating only the hidden member has must NOT surface the stack.
        try catalog.setRating(5, forAsset: hidden)
        session.applyFilter(CatalogFilter(ratingAtLeast: 5))
        let afterHidden = Set(session.assets.map(\.id))
        XCTAssertFalse(afterHidden.contains(summary.topID), "堆叠整个消失，成员不能替代置顶出现")
        XCTAssertNil(session.stacksByTopID[summary.topID], "stacksByTopID 里也没有它")

        // Same stack, now the 置顶 rated 5 → it appears.
        try catalog.setRating(5, forAsset: summary.topID)
        session.reload()
        let afterTop = Set(session.assets.map(\.id))
        XCTAssertTrue(afterTop.contains(summary.topID))
        XCTAssertEqual(session.stacksByTopID[summary.topID]?.count, 4)

        // 「搜索」 — this codebase has no search field; the invariant the task names is "a predicate
        // only a hidden member satisfies must not surface it", which a lens criterion exercises the
        // same way. Set a lens only on a hidden member and ask for that lens.
        try catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET lens = 'OnlyHidden 85mm' WHERE id = ?", arguments: [hidden])
        }
        session.applyFilter(CatalogFilter(slots: [FilterSlot(dimension: .lens, values: ["OnlyHidden 85mm"])]))
        XCTAssertEqual(session.assets.count, 0, "只存在于非置顶成员的取值 → 堆叠不出现")

        print("⑪ filter ★≥5 hidden-only: \(afterHidden.sorted().map { String($0.prefix(4)) }) "
              + "top-rated: \(afterTop.sorted().map { String($0.prefix(4)) })")
    }

    // MARK: - ⑪b 批量写入只写置顶那张

    func testRatingTheRepresentativeWritesOnlyTheTopRow() throws {
        let assets = try seed(5)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: assets.map(\.id)))
        let session = try openSession()
        XCTAssertEqual(session.metadataTargetIDs, [summary.topID], "选中集里只有代表")

        XCTAssertTrue(session.setRatingForSelection(3))

        let ratedInStack = try sqlCount(
            "SELECT COUNT(*) FROM assets WHERE stack_id = ? AND rating = 3", [summary.id])
        XCTAssertEqual(ratedInStack, 1, "堆叠 5 张里只有置顶被写")
        XCTAssertEqual(try sqlCount("SELECT COUNT(*) FROM assets WHERE stack_id = ? AND rating = 3 AND stack_rank = 0",
                                    [summary.id]), 1)
        XCTAssertEqual(session.assets.first { $0.id == summary.topID }?.rating, 3)
        print("⑪b rated-in-stack \(ratedInStack)")
    }

    // MARK: - ⑪c 排序按置顶那张的时间参与

    func testSortingUsesTheTopsCaptureTime() throws {
        let assets = try seed(5)                          // ascending time: 00 … 04
        let ids = assets.map(\.id)
        // The top is the OLDEST of the three (id 0), so the stack must sort where IMG_00 would.
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [ids[0], ids[3], ids[4]]))
        let session = try openSession()
        session.setSortOrder(.newestFirst)
        let newestFirst = session.assets.map(\.filename)
        session.setSortOrder(.oldestFirst)
        let oldestFirst = session.assets.map(\.filename)

        XCTAssertEqual(newestFirst, ["IMG_02.dng", "IMG_01.dng", "IMG_00.dng"])
        XCTAssertEqual(oldestFirst, ["IMG_00.dng", "IMG_01.dng", "IMG_02.dng"])
        XCTAssertEqual(session.assets.first { $0.stackId != nil }?.id, summary.topID)
        print("⑪c newest \(newestFirst) oldest \(oldestFirst)")
    }

    // MARK: - ⑫ 三个面都画同一个「⧉ N」

    func testTheThreeSurfacesDrawTheStackIndicatorThroughOneRoutine() throws {
        let assets = try seed(4)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [assets[1].id, assets[2].id, assets[3].id]))
        let top = try XCTUnwrap(try catalog.asset(id: summary.topID))
        let plain = try XCTUnwrap(try catalog.asset(id: assets[0].id))

        // ① grid card
        let card = AssetCardView()
        card.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        card.asset = top
        card.stackCount = summary.count
        Self.paint(card)
        XCTAssertTrue(card.lastDrawnBadges.contains("stack:3"), "网格卡片有 stack:3，实际 \(card.lastDrawnBadges)")
        XCTAssertEqual(card.badgeSignature, "⧉3")
        card.asset = plain
        card.stackCount = 0
        Self.paint(card)
        XCTAssertFalse(card.lastDrawnBadges.contains { $0.hasPrefix("stack:") }, "非堆叠照片没有指示")

        // ② filmstrip cell
        let strip = FilmstripCard()
        strip.frame = NSRect(x: 0, y: 0, width: 111, height: 69)
        strip.asset = top
        strip.stackCount = summary.count
        Self.paint(strip)
        XCTAssertTrue(strip.lastDrawnBadges.contains("stack:3"), "胶片条有 stack:3，实际 \(strip.lastDrawnBadges)")
        XCTAssertEqual(strip.badgeSignature, "⧉3")
        strip.asset = plain
        strip.stackCount = 0
        Self.paint(strip)
        XCTAssertFalse(strip.lastDrawnBadges.contains { $0.hasPrefix("stack:") })

        // ③ sidebar row
        let row = PhotoRowCell()
        row.frame = NSRect(x: 0, y: 0, width: 212, height: 46)
        row.configure(asset: top, isActive: false, stackCount: summary.count)
        Self.paint(row)
        XCTAssertEqual(row.lastDrawnBadges, ["stack:3"], "侧栏行有 stack:3，实际 \(row.lastDrawnBadges)")
        row.configure(asset: plain, isActive: false, stackCount: 0)
        Self.paint(row)
        XCTAssertTrue(row.lastDrawnBadges.isEmpty, "非堆叠照片没有指示")

        // The three surfaces agree on the signature the routine produces.
        XCTAssertEqual(AssetBadges(asset: top, stackCount: summary.count).drawn, ["stack:3"])
        print("⑫ grid \(card.lastDrawnBadges) strip \(strip.lastDrawnBadges) row \(row.lastDrawnBadges)")
    }

    // MARK: - ⑬ 点堆叠卡片打开的就是置顶

    func testActivatingAStackCardOpensTheTop() throws {
        let assets = try seed(4)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [assets[1].id, assets[2].id, assets[3].id]))
        let session = try openSession()

        let row = try XCTUnwrap(session.assets.first { $0.stackId != nil })
        XCTAssertEqual(row.id, summary.topID, "卡片显示的就是置顶")
        session.activate(row.id)

        XCTAssertEqual(session.mode, .loupe)
        XCTAssertEqual(session.anchorID, summary.topID)
        XCTAssertEqual(session.loadedEditAssetID, summary.topID)
        print("⑬ loupe asset \(session.anchorID?.prefix(8) ?? "-") top \(summary.topID.prefix(8))")
    }

    // MARK: - ⑭ 右键子菜单列出全部成员、当前置顶打勾、点第二张

    func testTheSetTopSubmenuListsEveryMemberAndSwapsTheRow() throws {
        let assets = try seed(4)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [assets[1].id, assets[2].id, assets[3].id]))
        let session = try openSession()
        let target = StackMenuTarget(session: session)

        let menu = try XCTUnwrap(StackMenuBuilder.menu(session: session, target: target,
                                                        selectedIDs: [summary.topID]))
        let holder = try XCTUnwrap(menu.items.first { $0.title == StackMenuBuilder.setTopTitle })
        let submenu = try XCTUnwrap(holder.submenu)
        let memberAssets = try catalog.stackMembers(stackID: summary.id)
        XCTAssertEqual(submenu.items.map(\.title), memberAssets.map(\.filename), "全部成员的文件名，按显示顺序")
        XCTAssertEqual(submenu.items.filter { $0.state == .on }.map(\.title), [session.assets.first { $0.id == summary.topID }?.filename].compactMap { $0 },
                       "当前置顶打勾")
        XCTAssertTrue(menu.items.contains { $0.title == StackMenuBuilder.ungroupTitle })

        let before = session.assets.map(\.id)
        let second = try XCTUnwrap(submenu.items.dropFirst().first)
        let secondID = try XCTUnwrap(second.representedObject as? String)
        target.setTopPressed(second)

        let after = session.assets.map(\.id)
        XCTAssertEqual(session.anchorID, secondID, "loupe/锚点换成它")
        XCTAssertTrue(after.contains(secondID), "assets 里那张被替换成它")
        XCTAssertFalse(after.contains(summary.topID), "原置顶离开可见列表")
        XCTAssertEqual(after.count, before.count, "行数不变")
        let newTop = try XCTUnwrap(try catalog.stackSummary(stackID: summary.id)?.topID)
        XCTAssertEqual(newTop, secondID)
        print("⑭ before \(before.map { String($0.prefix(4)) }) after \(after.map { String($0.prefix(4)) })")
    }

    // MARK: - ⑮ ⌘G / ⇧⌘G：网格 3 格 → 1 格 → 3 格

    func testMenuCommandsCollapseAndRestoreTheGrid() throws {
        let assets = try seed(3)
        let editor = EditorWindowController()
        _ = editor.window
        try editor.openLibrary(at: package)
        let session = editor.session
        XCTAssertEqual(session.assets.count, 3)

        session.setSelection(Set(assets.map(\.id)), anchor: assets[0].id)
        XCTAssertTrue(editor.stackSelection(), "⌘G")
        XCTAssertEqual(session.assets.count, 1, "网格从 3 格变 1 格")
        XCTAssertEqual(session.stacksByTopID.values.first?.count, 3)
        let historyBefore = session.history.snapshots.count
        let revisionBefore = session.editRevision

        XCTAssertTrue(editor.ungroupSelection(), "⇧⌘G")
        XCTAssertEqual(session.assets.count, 3, "回到 3 格")
        XCTAssertTrue(session.stacksByTopID.isEmpty)
        XCTAssertEqual(session.history.snapshots.count, historyBefore, "堆叠不是一次编辑")
        XCTAssertEqual(session.editRevision, revisionBefore)
        print("⑮ grid 3 → \(1) → \(session.assets.count), history \(session.history.snapshots.count)")
    }

    // MARK: - 菜单行与校验（⑯ 的 UI 半边）

    func testThePhotoMenuCarriesCommandGAndShiftCommandG() throws {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        let photo = try XCTUnwrap(menu.items.first { $0.submenu?.title == "照片" }?.submenu)
        let make = try XCTUnwrap(photo.items.first { $0.action == #selector(EditorWindowController.stackSelectionAction(_:)) })
        let unmake = try XCTUnwrap(photo.items.first { $0.action == #selector(EditorWindowController.ungroupSelectionAction(_:)) })
        XCTAssertEqual(make.keyEquivalent, "g")
        XCTAssertEqual(make.keyEquivalentModifierMask, [.command])
        XCTAssertEqual(unmake.keyEquivalent, "g")
        XCTAssertEqual(unmake.keyEquivalentModifierMask, [.command, .shift])

        let library = try seed(3)
        let editor = EditorWindowController()
        _ = editor.window
        try editor.openLibrary(at: package)
        XCTAssertFalse(editor.validateMenuItem(make), "一张选中：堆叠置灰")
        editor.session.setSelection(Set(library.map(\.id)))
        XCTAssertTrue(editor.validateMenuItem(make))
        XCTAssertFalse(editor.validateMenuItem(unmake), "没有堆叠：取消堆叠置灰")
        editor.stackSelection()
        XCTAssertTrue(editor.validateMenuItem(unmake))
    }
}
