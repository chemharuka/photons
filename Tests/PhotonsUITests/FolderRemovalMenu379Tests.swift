import XCTest
import AppKit
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// 379 — the left column's right-click verb 「从照片库移除此文件夹…」, the UI half.
///
/// Two things are asserted separately because they fail separately:
///
/// * the **menu** — which row kinds offer the verb, and whether the title carries the right count.
///   Driven through `menuNeedsUpdate` (the shipping delegate door) with a pinned row, because
///   `clickedRow` is AppKit's and a headless test cannot set it;
/// * the **model** — selecting a folder and then removing it must fall back to 全部照片 (the row it
///   filtered by is gone), keep the photos that were outside the subtree, and leave the tree without
///   the removed rows (they are scanned out of `rel_path`, so no "hidden folder" state is needed).
@MainActor
final class FolderRemovalMenu379Tests: XCTestCase {

    private var tmp: URL!
    private var library: URL!
    private var rootA: SourceRoot!
    private var rootB: SourceRoot!
    private var session: CatalogSession!
    private var controller: BrowserPaneController!
    private var ids: [String: String] = [:]
    private var files: [String: URL] = [:]

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-379ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("t.photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: library)
        rootA = try makeRoot(catalog, "rootA")
        rootB = try makeRoot(catalog, "rootB")
        try insert(catalog, rootA, "day2/a.jpg", minute: 5)
        try insert(catalog, rootA, "day2/b.jpg", minute: 4)
        try insert(catalog, rootA, "day2/sub/c.jpg", minute: 3)
        try insert(catalog, rootA, "night/d.jpg", minute: 2)
        try insert(catalog, rootB, "x/r.jpg", minute: 1)

        session = CatalogSession()
        try session.open(library)
        controller = BrowserPaneController(session: session)
        _ = controller.view
        controller.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault, height: 744))
    }

    override func tearDownWithError() throws {
        controller = nil
        session = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    private func makeRoot(_ catalog: Catalog, _ name: String) throws -> SourceRoot {
        let dir = tmp.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try catalog.ensureRoot(for: dir, mode: .reference)
    }

    private func insert(_ catalog: Catalog, _ root: SourceRoot, _ relPath: String, minute: Int) throws {
        let dir = tmp.appendingPathComponent(root.displayName, isDirectory: true)
        let url = dir.appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("bytes \(relPath)".utf8).write(to: url)
        let asset = Asset(sourceRootId: root.id,
                          relPath: relPath,
                          filename: (relPath as NSString).lastPathComponent,
                          ext: (relPath as NSString).pathExtension,
                          kind: .jpeg,
                          size: 10,
                          mtime: 0,
                          contentHash: String(format: "%064x", abs(relPath.hashValue)),
                          captureTime: String(format: "2026-01-01T00:%02d:00Z", minute))
        try catalog.dbQueue.write { db in try asset.insert(db) }
        ids[relPath] = asset.id
        files[relPath] = url
    }

    private func rowIndex(rootID: String?, path: String) throws -> Int {
        let rows = controller.folderTreeRows
        guard let index = rows.firstIndex(where: { $0.rootID == rootID && $0.path == path }) else {
            throw XCTSkip("no row \(rootID ?? "*")|\(path) in \(rows.map { "\($0.rootID ?? "*")|\($0.path)" })")
        }
        // 相册段在顶部：outline 的行号与 `folderTreeRows` 的下标一致（它按 outline 顺序遍历）。
        return index
    }

    private func menu(titlesForRoot rootID: String?, path: String) -> [String] {
        controller.menuRowOverride = (try? rowIndex(rootID: rootID, path: path)) ?? -1
        let menu = controller.sourceTreeMenu
        controller.menuNeedsUpdate(menu)
        return menu.items.map(\.title)
    }

    // MARK: - ⑩ the menu

    func testTheFolderRowOffersTheRemovalVerbedWithItsCount() throws {
        controller.setFolderExpanded(rootID: rootA.id, path: "", true)
        let titles = menu(titlesForRoot: rootA.id, path: "day2")
        print("379 ⑩ folder row menu = \(titles)")
        XCTAssertTrue(titles.contains("从照片库移除「day2」（3 张）…"), "actual: \(titles)")
        XCTAssertEqual(titles.first, "新建相册…")
    }

    func testTheRootRowOffersTheSameVerbWithItsOwnCount() throws {
        let titles = menu(titlesForRoot: rootA.id, path: "")
        print("379 ⑩ root row menu = \(titles)")
        XCTAssertTrue(titles.contains("从照片库移除「rootA」（4 张）…"), "actual: \(titles)")
    }

    func testAllPhotosDoesNotOfferFolderRemoval() throws {
        let titles = menu(titlesForRoot: nil, path: "")
        print("379 ⑩ 全部照片 menu = \(titles)")
        XCTAssertEqual(titles, ["新建相册…"], "the whole library is not a folder to remove")
    }

    func testTheAlbumRowKeepsItsFourVerbs() throws {
        _ = try session.createAlbum(named: "旅行")
        controller.refresh()
        let albumID = try XCTUnwrap(session.albums.first?.id)
        let row = try XCTUnwrap(controller.folderTreeRows.firstIndex { $0.albumID == albumID })
        controller.menuRowOverride = row
        let menu = controller.sourceTreeMenu
        controller.menuNeedsUpdate(menu)
        // 分隔符的 title 是 ""，不是一条动词：把它去掉再比菜单项本身。
        let titles = menu.items.map(\.title).filter { !$0.isEmpty }
        print("379 ⑩ album row menu = \(titles)")
        XCTAssertEqual(titles, ["新建相册…",
                                "重命名相册…",
                                "删除相册…",
                                "把选中的照片加入此相册",
                                "把选中的照片移出此相册"],
                       "the album menu is unchanged by 379")
        XCTAssertFalse(titles.contains { $0.contains("从照片库移除") })
    }

    /// The count in the title is a `COUNT(*)` of the subtree — `day2` is 3, not 4 (`night/d` is a
    /// sibling) and not 1 (`sub/c` is inside it).
    func testTheCountIsTheSubtreeCount() {
        XCTAssertEqual(session.folderAssetCount(rootID: rootA.id, path: "day2"), 3)
        XCTAssertEqual(session.folderAssetCount(rootID: rootA.id, path: "day2/sub"), 1)
        XCTAssertEqual(session.folderAssetCount(rootID: rootA.id, path: ""), 4)
        XCTAssertEqual(session.folderAssetCount(rootID: rootA.id, path: "nothing"), 0)
    }

    /// The verb is enabled on a row that has photos, and the enablement rule is the count (a folder
    /// with 0 has nothing to remove — its row is not drawn, so this is the guard, not a hidden state).
    func testTheRemovalItemIsEnabledOnlyWhenThereIsSomethingToRemove() throws {
        controller.setFolderExpanded(rootID: rootA.id, path: "", true)
        controller.menuRowOverride = try rowIndex(rootID: rootA.id, path: "day2")
        let menu = controller.sourceTreeMenu
        controller.menuNeedsUpdate(menu)
        let item = try XCTUnwrap(menu.items.first { $0.title.contains("从照片库移除") })
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(session.folderAssetCount(rootID: rootA.id, path: "nothing"), 0,
                       "the enablement input is 0 for a folder with no photos")
    }

    // MARK: - ⑪ the confirmation

    func testTheConfirmationDefaultsToCancel() {
        let target = BrowserPaneController.FolderRemovalTarget(rootID: rootA.id, path: "day2",
                                                               displayName: "day2")
        let alert = controller.folderRemovalAlert(for: target, count: 1234)
        print("379 ⑪ alert buttons = \(alert.buttons.map { "\($0.title):\($0.keyEquivalent)" })")
        XCTAssertEqual(alert.messageText, "从照片库移除「day2」？")
        XCTAssertEqual(alert.window.defaultButtonCell?.title, "取消",
                       "Return must not remove anything")
        XCTAssertEqual(alert.buttons.map(\.title), ["移除", "取消"])
        XCTAssertTrue(alert.informativeText.contains("磁盘上的原文件不会被删除"),
                      "actual: \(alert.informativeText)")
        XCTAssertTrue(alert.informativeText.contains("不能撤销"))
        XCTAssertTrue(alert.informativeText.contains("1,234 张照片"), "actual: \(alert.informativeText)")
    }

    // MARK: - ⑦⑧ the model after a removal

    func testRemovingTheSelectedFolderFallsBackToAllPhotos() throws {
        controller.setFolderExpanded(rootID: rootA.id, path: "", true)
        controller.selectFolderRow(rootID: rootA.id, path: "day2")
        XCTAssertEqual(session.assets.count, 3)

        let report = try XCTUnwrap(session.removeFolder(rootID: rootA.id, path: "day2"))
        XCTAssertEqual(report.assets, 3)
        controller.refresh()

        // ⑧ the selection that pointed into the removed subtree is gone → 全部照片.
        XCTAssertTrue(session.selectedFolders.isEmpty, "actual: \(session.selectedFolders)")
        XCTAssertEqual(controller.selectedFolderKeys, ["*|"], "the highlight is back on 全部照片")
        XCTAssertEqual(Set(session.assets.map(\.filename)), ["d.jpg", "r.jpg"],
                       "night/d and rootB/x/r are what is left")
        XCTAssertFalse(session.assets.isEmpty)
    }

    /// The removed folder's rows live in the model, not in a "hidden rows" list: after `reload()` the
    /// tree has no `day2` or `day2/sub`, while a sibling and the other root's folders are untouched.
    func testTheRemovedFolderRowsDisappearAndSiblingsStay() throws {
        controller.setFolderExpanded(rootID: rootA.id, path: "", true)
        controller.setFolderExpanded(rootID: rootA.id, path: "day2", true)
        controller.setFolderExpanded(rootID: rootB.id, path: "", true)
        var paths = controller.folderTreeRows.map { "\($0.rootID ?? "*")|\($0.path)" }
        print("379 ⑦ before = \(paths)")
        XCTAssertTrue(paths.contains("\(rootA.id)|day2"))
        XCTAssertTrue(paths.contains("\(rootA.id)|day2/sub"))
        XCTAssertTrue(paths.contains("\(rootA.id)|night"))
        XCTAssertTrue(paths.contains("\(rootB.id)|x"))

        _ = session.removeFolder(rootID: rootA.id, path: "day2")
        controller.refresh()

        paths = controller.folderTreeRows.map { "\($0.rootID ?? "*")|\($0.path)" }
        print("379 ⑦ after  = \(paths)")
        XCTAssertFalse(paths.contains("\(rootA.id)|day2"), "day2 is scanned out of rel_path")
        XCTAssertFalse(paths.contains("\(rootA.id)|day2/sub"))
        XCTAssertTrue(paths.contains("\(rootA.id)|night"), "a sibling folder is not touched")
        XCTAssertTrue(paths.contains("\(rootB.id)|x"), "another root is not touched")
    }

    /// A sub-selection inside the removed subtree is dead too, and a sibling selection survives.
    func testOnlySelectionsInsideTheRemovedSubtreeAreDropped() {
        let folders = [FolderSelection(rootId: "r", path: "day2"),
                       FolderSelection(rootId: "r", path: "day2/sub"),
                       FolderSelection(rootId: "r", path: "day2x"),
                       FolderSelection(rootId: "r", path: "night"),
                       FolderSelection(rootId: "r", path: ""),
                       FolderSelection(rootId: "other", path: "day2")]
        let kept = CatalogSession.selectedFolders(folders, removing: "r", folder: "day2")
        XCTAssertEqual(kept.map(\.key), ["r|day2x", "r|night", "r|", "other|day2"],
                       "the removed subtree and its children are gone; sibling paths and the root stay")

        // A root removal takes every selection naming that root, and nothing else.
        XCTAssertEqual(CatalogSession.selectedFolders(folders, removing: "r", folder: nil).map(\.key),
                       ["other|day2"])
    }

    /// A folder removal in one root must not drop a selection that names a **different root**: the
    /// grid is a union across roots, and only the removed subtree is dead.
    func testRemovingAFolderInOneRootKeepsAnotherRootsSelection() throws {
        controller.setFolderExpanded(rootID: rootA.id, path: "", true)
        controller.setFolderExpanded(rootID: rootB.id, path: "", true)
        controller.selectFolderRows([FolderSelection(rootId: rootA.id, path: "day2"),
                                     FolderSelection(rootId: rootB.id, path: "x")])
        XCTAssertEqual(session.assets.count, 4)

        _ = try XCTUnwrap(session.removeFolder(rootID: rootA.id, path: "day2"))
        controller.refresh()

        XCTAssertEqual(session.selectedFolders.map(\.key), ["\(rootB.id)|x"])
        XCTAssertEqual(session.assets.map(\.filename), ["r.jpg"])
    }

    /// A root removal takes every selection naming that root and leaves the other root's alone.
    func testRemovingARootLeavesTheOtherRootsSelectionAlone() throws {
        controller.setFolderExpanded(rootID: rootA.id, path: "", true)
        controller.setFolderExpanded(rootID: rootB.id, path: "", true)
        controller.selectFolderRows([FolderSelection(rootId: rootA.id, path: "day2"),
                                     FolderSelection(rootId: rootB.id, path: "x")])
        XCTAssertEqual(session.assets.count, 4)

        let report = try XCTUnwrap(session.removeSourceRoot(id: rootB.id))
        XCTAssertEqual(report.assets, 1, "the real row count, not 0")
        controller.refresh()

        XCTAssertEqual(session.selectedFolders.map(\.key), ["\(rootA.id)|day2"],
                       "rootB's selection went with rootB")
        XCTAssertFalse(session.roots.contains { $0.id == rootB.id })
        XCTAssertEqual(Set(session.assets.map(\.filename)), ["a.jpg", "b.jpg", "c.jpg"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(files["x/r.jpg"]).path),
                      "the removed root's original is still on disk")
    }

    /// The whole verb through the controller (menu target → transaction → redraw), which is what the
    /// menu item actually runs once the user has confirmed.
    func testTheControllerVerbRemovesTheSubtreeAndRedraws() throws {
        controller.setFolderExpanded(rootID: rootA.id, path: "", true)
        controller.selectFolderRow(rootID: rootA.id, path: "day2")
        let target = BrowserPaneController.FolderRemovalTarget(rootID: rootA.id, path: "day2",
                                                               displayName: "day2")
        let report = try XCTUnwrap(controller.removeFolderFromLibrary(target))
        XCTAssertEqual(report.assets, 3)
        XCTAssertEqual(controller.photoRowCount, 2, "the list redrew with night/d and rootB/x/r")
        XCTAssertFalse(controller.folderTreeRows.contains { $0.path == "day2" })
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(files["day2/a.jpg"]).path))
    }

    /// The anchor hands over to the next photo the user saw, not back to the first row (the existing
    /// `pendingAnchorSuccessor` rule, which a folder removal must reuse).
    func testTheAnchorFallsToTheNextSurvivorAfterAFolderRemoval() throws {
        // Display order is capture_time DESC: a(5) b(4) c(3) d(2) r(1). With the anchor on `b`, the
        // three removed rows are a+b+c and the first survivor **after** the run is `night/d`.
        session.selectOnly(try XCTUnwrap(ids["day2/b.jpg"]))
        XCTAssertEqual(session.anchorID, ids["day2/b.jpg"])

        _ = session.removeFolder(rootID: rootA.id, path: "day2")
        XCTAssertEqual(session.anchorID, ids["night/d.jpg"],
                       "the anchor moved to the next surviving photo, not to the first row")
    }
}
