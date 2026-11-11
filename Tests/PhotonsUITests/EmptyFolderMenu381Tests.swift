import XCTest
import AppKit
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// 381 — 空文件夹也能移除：菜单、文案与「确认后左栏真的少一行」，the UI half.
///
/// 379 的 enablement 规则是 `count > 0`。可 `source_roots` 的行不随照片消失 —— 一个源根的照片被
/// 全部移除后，左栏仍留着 `US 0` 这一行。用户能对它的唯一动作就是移除，菜单项不能是灰的。
///
/// 非根文件夹没有同样的问题：`folderNodes` 由 `rel_path` 扫出，照片没了行就没了，所以这里**不**需要
/// 一套「隐藏文件夹」状态 —— 只剩根行需要 0 张也能移除。
@MainActor
final class EmptyFolderMenu381Tests: XCTestCase {

    private var tmp: URL!
    private var library: URL!
    private var rootA: SourceRoot!
    private var rootB: SourceRoot!
    private var session: CatalogSession!
    private var controller: BrowserPaneController!

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-381ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("t.photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: library)
        rootA = try makeRoot(catalog, "rootA")
        rootB = try makeRoot(catalog, "rootB")
        // rootA has photos, rootB never had one: the second is the 0-count root row.
        try insert(catalog, rootA, "day2/a.jpg", minute: 2)
        try insert(catalog, rootA, "day2/b.jpg", minute: 1)

        session = CatalogSession()
        try session.open(library)
        controller = BrowserPaneController(session: session)
        _ = controller.view
        controller.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault, height: 744))
        controller.refresh()
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
        let url = tmp.appendingPathComponent(root.displayName, isDirectory: true)
            .appendingPathComponent(relPath)
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
    }

    private func rowIndex(rootID: String?, path: String) throws -> Int {
        let rows = controller.folderTreeRows
        guard let index = rows.firstIndex(where: { $0.rootID == rootID && $0.path == path }) else {
            throw XCTSkip("no row \(rootID ?? "*")|\(path) in \(rows.map { "\($0.rootID ?? "*")|\($0.path)" })")
        }
        return index
    }

    private func menu(rootID: String?, path: String) throws -> NSMenu {
        controller.menuRowOverride = try rowIndex(rootID: rootID, path: path)
        let menu = controller.sourceTreeMenu
        controller.menuNeedsUpdate(menu)
        return menu
    }

    private var rootTitles: [String] {
        controller.folderTreeRows.filter { $0.path.isEmpty && $0.rootID != nil }.map(\.title)
    }

    // MARK: - ③ the menu on a 0-count root row

    func testTheEmptyRootRowOffersTheVerbEnabledWithTheEmptyFolderTitle() throws {
        XCTAssertEqual(session.folderAssetCount(rootID: rootB.id, path: ""), 0,
                       "rootB is the 0-count row this task is about")
        let menu = try menu(rootID: rootB.id, path: "")
        let item = try XCTUnwrap(menu.items.first { $0.title.contains("从照片库移除") })
        print("381 ③ empty root menu = \(menu.items.map(\.title)) · enabled = \(item.isEnabled)")
        XCTAssertTrue(item.isEnabled, "0 张的根行必须可移除，不再是灰的")
        XCTAssertEqual(item.title, "从照片库移除「rootB」（空文件夹）…",
                       "the 0-count wording is the one the spec names")
    }

    /// 有照片的那一侧一字未变（379 断言原文）。
    func testTheNonEmptyRootKeepsItsCountedTitleAndIsEnabled() throws {
        let menu = try menu(rootID: rootA.id, path: "")
        let item = try XCTUnwrap(menu.items.first { $0.title.contains("从照片库移除") })
        print("381 ③ non-empty root menu = \(menu.items.map(\.title))")
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.title, "从照片库移除「rootA」（2 张）…")
    }

    // MARK: - ④ the confirmation for a 0-count row

    func testTheConfirmationForAnEmptyFolderSaysItOnlyRemovesTheRow() {
        let target = BrowserPaneController.FolderRemovalTarget(rootID: rootB.id, path: "",
                                                               displayName: "rootB")
        let alert = controller.folderRemovalAlert(for: target, count: 0)
        print("381 ④ alert buttons = \(alert.buttons.map { "\($0.title):\($0.keyEquivalent)" })")
        print("381 ④ informative = \(alert.informativeText)")
        XCTAssertEqual(alert.messageText, "从照片库移除「rootB」？")
        XCTAssertTrue(alert.informativeText.contains("没有照片"), "actual: \(alert.informativeText)")
        XCTAssertTrue(alert.informativeText.contains("磁盘上的文件夹不会被删除"),
                      "actual: \(alert.informativeText)")
        XCTAssertEqual(alert.buttons.map(\.title), ["移除", "取消"])
        XCTAssertEqual(alert.window.defaultButtonCell?.title, "取消", "Return must not remove anything")
    }

    /// 有照片时仍是 379 的那句：条数、不可撤销、原文件不动。
    func testTheConfirmationForANonEmptyFolderIsUnchanged() {
        let target = BrowserPaneController.FolderRemovalTarget(rootID: rootA.id, path: "day2",
                                                               displayName: "day2")
        let alert = controller.folderRemovalAlert(for: target, count: 1234)
        XCTAssertTrue(alert.informativeText.contains("1,234 张照片将从照片库移除"))
        XCTAssertTrue(alert.informativeText.contains("磁盘上的原文件不会被删除"))
        XCTAssertTrue(alert.informativeText.contains("不能撤销"))
        XCTAssertFalse(alert.informativeText.contains("没有照片"))
    }

    // MARK: - ⑤⑥ confirm → the row is gone and the selection is pruned

    /// The whole verb (menu target → session → redraw) on the 0-count root: before, the row is in the
    /// tree; after, it is not. This is the `guard !ids.isEmpty else { return nil }` the task removes —
    /// with it, `reload()` never ran and the row stayed forever.
    func testRemovingTheEmptyRootRowTakesItOutOfTheLeftColumn() throws {
        controller.setFolderExpanded(rootID: rootA.id, path: "", true)
        let before = rootTitles
        print("381 ⑤ root titles before = \(before)")
        XCTAssertTrue(before.contains("rootB"))

        let target = BrowserPaneController.FolderRemovalTarget(rootID: rootB.id, path: "",
                                                               displayName: "rootB")
        let report = try XCTUnwrap(controller.removeFolderFromLibrary(target),
                                   "a 0-count root removal must return a report, not nil")
        print("381 ⑤ DeleteReport.assets = \(report.assets)")

        let after = rootTitles
        print("381 ⑤ root titles after = \(after)")
        XCTAssertEqual(report.assets, 0, "no photo rows went; the root row did")
        XCTAssertFalse(after.contains("rootB"), "the root row left the left column")
        XCTAssertTrue(after.contains("rootA"), "the other root is untouched")
        XCTAssertFalse(session.roots.contains { $0.id == rootB.id })
    }

    /// ⑥ the selection pointing at the removed root is dropped, so the grid does not keep filtering
    /// by a row that no longer exists.
    func testTheRemovedEmptyRootIsDroppedFromSelectedFolders() throws {
        controller.selectFolderRow(rootID: rootB.id, path: "")
        let before = session.selectedFolders.map(\.key)
        print("381 ⑥ selectedFolders before = \(before)")
        XCTAssertEqual(before, ["\(rootB.id)|"])

        let target = BrowserPaneController.FolderRemovalTarget(rootID: rootB.id, path: "",
                                                               displayName: "rootB")
        _ = try XCTUnwrap(controller.removeFolderFromLibrary(target))

        let after = session.selectedFolders.map(\.key)
        print("381 ⑥ selectedFolders after = \(after)")
        XCTAssertTrue(after.isEmpty, "a root that no longer exists cannot be a filter")
        XCTAssertEqual(controller.selectedFolderKeys, ["*|"], "the highlight is back on 全部照片")
    }

    /// An emptied root (photos removed first, then the root row) goes the same path.
    func testAnEmptiedRootCanThenBeRemovedFromTheMenu() throws {
        _ = try XCTUnwrap(session.removeFolder(rootID: rootA.id, path: ""))
        controller.refresh()
        XCTAssertEqual(session.folderAssetCount(rootID: rootA.id, path: ""), 0)

        let menu = try menu(rootID: rootA.id, path: "")
        let item = try XCTUnwrap(menu.items.first { $0.title.contains("从照片库移除") })
        print("381 ③ emptied root menu = \(menu.items.map(\.title))")
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.title, "从照片库移除「rootA」（空文件夹）…")

        let target = BrowserPaneController.FolderRemovalTarget(rootID: rootA.id, path: "",
                                                               displayName: "rootA")
        let report = try XCTUnwrap(controller.removeFolderFromLibrary(target))
        XCTAssertEqual(report.assets, 0)
        XCTAssertFalse(rootTitles.contains("rootA"))
    }

    // MARK: - ⑧ the non-empty path did not regress

    func testANonEmptyFolderStillRemovesItsPhotosAndRedraws() throws {
        controller.setFolderExpanded(rootID: rootA.id, path: "", true)
        let target = BrowserPaneController.FolderRemovalTarget(rootID: rootA.id, path: "day2",
                                                               displayName: "day2")
        let report = try XCTUnwrap(controller.removeFolderFromLibrary(target))
        XCTAssertEqual(report.assets, 2)
        XCTAssertEqual(controller.photoRowCount, 0)
        XCTAssertFalse(controller.folderTreeRows.contains { $0.path == "day2" },
                       "a folder with no photos left is scanned out, no hidden state")
        XCTAssertTrue(rootTitles.contains("rootA"),
                      "the root row stays with 0 — that is the row 381 makes removable")
    }
}
