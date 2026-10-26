import XCTest
import AppKit
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// The left browser's source list is a **folder tree**, not a flat list of roots.
///
/// Four things have to hold at once, and each of them was wrong before:
///
/// * the shape — 全部照片 → the source root → the folders `rel_path` implies, indented, collapsible,
///   with counts (`day2` holds 2, its child `sub` holds 1);
/// * the filter — clicking `day2` must show exactly that subtree in the photo list, clicking
///   全部照片 must bring everything back, and (021 B) a ⌘-multi-selection must be the **union** of
///   the highlighted subtrees, across roots, without `day2` swallowing `day2x`;
/// * the height — the tree was `rows × 46`, capped at 200, so a one-root library got a ~52 pt strip
///   ("这个区域的窗口太窄，大概只有几十 px"); it is now at least 180 pt, at most 45 % of the panel,
///   and leaves the photo list its own 120 pt floor. Since 021 A its **rows** are 28 pt (the photo
///   rows below keep 46), which is what "文件夹高度太高了" was about;
/// * the state — a reload must keep the highlighted folders (by `(rootId, path)`, never by row
///   index) and must not reset the filter to 全部照片.
@MainActor
final class FolderTreeTests: XCTestCase {

    private var tmp: URL!
    private var library: URL!
    private var root: SourceRoot!
    private var session: CatalogSession!
    private var controller: BrowserPaneController!

    /// Panel height of the browser at the contract window size (780 − 36 top bar), and a couple of
    /// taller ones: the ceiling is a fraction of the panel, so the number is not a constant.
    private static let panelHeights: [CGFloat] = [744, 900, 1200]

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-treeui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("t.photonslibrary", isDirectory: true)

        let catalog = try Catalog.create(at: library)
        let shoot = tmp.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: shoot, mode: .reference)
        try insert(catalog, "a.dng", minute: 4)
        try insert(catalog, "day2/b.dng", minute: 3)
        try insert(catalog, "day2/sub/c.dng", minute: 2)
        try insert(catalog, "day2x/d.dng", minute: 1)
        // A folder on disk that holds no photo must not appear: the tree lists the library, not the
        // filesystem, and an empty row is a click that shows nothing.
        try FileManager.default.createDirectory(at: shoot.appendingPathComponent("empty"),
                                                withIntermediateDirectories: true)

        session = CatalogSession()
        try session.open(library)
        controller = BrowserPaneController(session: session)
        _ = controller.view                      // loadView + viewDidLoad → refresh()
        controller.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault,
                                          height: Self.panelHeights[0]))
    }

    override func tearDownWithError() throws {
        controller = nil
        session = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    private func insert(_ catalog: Catalog, _ relPath: String, minute: Int) throws {
        let asset = Asset(sourceRootId: root.id,
                          relPath: relPath,
                          filename: (relPath as NSString).lastPathComponent,
                          ext: (relPath as NSString).pathExtension,
                          kind: .raw,
                          size: 1024,
                          mtime: 0,
                          contentHash: UUID().uuidString,
                          captureTime: String(format: "2026-01-01T00:%02d:00Z", minute))
        try catalog.dbQueue.write { db in try asset.insert(db) }
    }

    private var tree: [BrowserPaneController.FolderTreeRow] { controller.folderTreeRows }

    // MARK: row metrics

    /// The folder name sits **inside** its row and centred in it, in a 28 pt row (021 A).
    ///
    /// `NSOutlineView.style = .sourceList` applies the system's compact row metrics; with the row
    /// height set *before* the style it came out ~24 pt while the cell still drew its title at y 13…31
    /// of a 46 pt row — so the name was pushed up and clipped by the row above it (owner: 「文件夹
    /// 名称被抬高了，字体被遮挡」). The style is applied first, `rowSizeStyle = .custom` pins the
    /// height, and the cell centres on the row's own height instead of a constant.
    func testTheFolderNameIsInsideAndCentredInItsRow() throws {
        controller.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault, height: 744))
        controller.view.layoutSubtreeIfNeeded()

        let outline = try XCTUnwrap(Self.findOutline(controller.view))
        XCTAssertEqual(outline.rowHeight, WorkspaceLayout.browserTreeRowHeight, accuracy: 0.01,
                       "a source-list style must not shrink the row")
        XCTAssertEqual(outline.rowHeight, 28, accuracy: 0.01, "021 A: 28 pt, measured")
        XCTAssertLessThan(outline.rowHeight, WorkspaceLayout.browserRowHeight,
                          "the folder tree is the column the owner asked to shrink")

        // The photo rows below are *not* part of that change: they carry a 34 pt thumbnail and two
        // lines of text, and they still measure 46 pt.
        let tables = Self.findTables(controller.view).filter { $0 !== outline }
        let photos = try XCTUnwrap(tables.first, "the photo list is a table next to the outline")
        XCTAssertEqual(photos.rowHeight, WorkspaceLayout.browserRowHeight, accuracy: 0.01)
        XCTAssertEqual(photos.rowHeight, 46, accuracy: 0.01, "the photo row keeps its 46 pt")

        var checked = 0
        for row in 0..<outline.numberOfRows {
            guard let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
                  let label = cell.subviews.compactMap({ $0 as? NSTextField })
                      .first(where: { !$0.stringValue.isEmpty && $0.font?.pointSize == 12 })
            else { continue }
            let height = cell.bounds.height
            XCTAssertEqual(height, WorkspaceLayout.browserTreeRowHeight, accuracy: 0.01,
                           "row \(row) cell height")
            XCTAssertGreaterThanOrEqual(label.frame.minY, -0.01,
                                        "\(label.stringValue) starts above its row (\(label.frame))")
            XCTAssertLessThanOrEqual(label.frame.maxY, height + 0.01,
                                     "\(label.stringValue) is clipped by its row (\(label.frame) in \(height) pt)")
            XCTAssertEqual(label.frame.midY, height / 2, accuracy: 1.0,
                           "\(label.stringValue) is not centred (midY \(label.frame.midY) of \(height))")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 2, "the tree drew at least 全部照片 + one folder")
    }

    private static func findOutline(_ view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for sub in view.subviews {
            if let found = findOutline(sub) { return found }
        }
        return nil
    }

    private static func findTables(_ view: NSView) -> [NSTableView] {
        var out = view is NSTableView ? [view as! NSTableView] : []
        for sub in view.subviews { out += findTables(sub) }
        return out
    }

    // MARK: shape

    /// Default state: 全部照片 is expanded, the root is the second level, its subfolders stay closed.
    func testTheTreeOpensAsAllPhotosAndOneRoot() {
        XCTAssertEqual(tree.map(\.title), ["全部照片", "shoot"], "levels: \(tree.map { ($0.title, $0.level) })")
        XCTAssertEqual(tree.map(\.level), [0, 1], "the root sits one level under 全部照片")
        XCTAssertEqual(tree.map(\.detail), ["4", "4"], "the library holds four, the root holds four")
        XCTAssertTrue(tree[0].isAllPhotos)
        XCTAssertNil(tree[0].rootID)
        XCTAssertEqual(tree[1].rootID, root.id)

        // Subfolders are collapsed by default — a library with 40 of them must not open as a wall.
        XCTAssertFalse(tree.contains { $0.path == "day2" }, "day2 is hidden until the root is opened")
        XCTAssertFalse(tree.contains { $0.title == "empty" }, "an empty folder is not a node")
    }

    /// Expand the root, then `day2`: the nesting is `全部照片 → shoot → day2 → day2/sub`.
    func testExpandingTheTreeShowsTheNestedFolders() {
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        XCTAssertEqual(tree.map(\.title), ["全部照片", "shoot", "day2", "day2x"])
        XCTAssertEqual(tree.map(\.level), [0, 1, 2, 2])
        XCTAssertEqual(tree.map(\.detail), ["4", "4", "2", "1"],
                       "day2 counts b + the nested c; day2x counts only d")

        controller.setFolderExpanded(rootID: root.id, path: "day2", true)
        XCTAssertEqual(tree.map(\.title), ["全部照片", "shoot", "day2", "sub", "day2x"])
        XCTAssertEqual(tree.map(\.level), [0, 1, 2, 3, 2], "sub is one level deeper than day2")
        XCTAssertEqual(tree.map(\.detail), ["4", "4", "2", "1", "1"])
        XCTAssertEqual(tree.first { $0.title == "sub" }?.path, "day2/sub")
        XCTAssertEqual(tree.first { $0.title == "sub" }?.rootID, root.id)

        // Collapsing again hides the subtree but keeps the row.
        controller.setFolderExpanded(rootID: root.id, path: "day2", false)
        XCTAssertEqual(tree.map(\.title), ["全部照片", "shoot", "day2", "day2x"])
    }

    // MARK: filter

    /// Clicking `day2` narrows the photo list to that subtree — `day2x/d.dng` stays out.
    func testSelectingAFolderFiltersThePhotoList() {
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        XCTAssertEqual(session.assets.count, 4, "the library starts unfiltered")

        controller.selectFolderRow(rootID: root.id, path: "day2")
        XCTAssertEqual(session.selectedRootID, root.id)
        XCTAssertEqual(session.selectedFolderPath, "day2")
        XCTAssertEqual(Set(session.assets.map(\.filename)), ["b.dng", "c.dng"])
        XCTAssertEqual(controller.photoRowCount, 2, "the list drew the same two rows")

        controller.selectFolderRow(rootID: root.id, path: "day2/sub")
        XCTAssertEqual(session.assets.map(\.filename), ["c.dng"])
        XCTAssertEqual(controller.photoRowCount, 1)

        controller.selectFolderRow(rootID: root.id, path: "")
        XCTAssertEqual(session.assets.count, 4, "the root itself is the whole folder again")
    }

    /// 全部照片 clears both halves of the filter: root *and* folder.
    func testSelectingAllPhotosRestoresEverything() {
        controller.selectFolderRow(rootID: root.id, path: "day2")
        XCTAssertEqual(session.assets.count, 2)

        controller.selectFolderRow(rootID: nil, path: "")
        XCTAssertNil(session.selectedRootID)
        XCTAssertEqual(session.selectedFolderPath, "")
        XCTAssertEqual(session.assets.count, 4)
        XCTAssertEqual(controller.photoRowCount, 4)
        XCTAssertEqual(controller.folderTreeRows.first?.title, "全部照片")
    }

    /// The selection survives a reload: rating a photo re-runs the query, and the folder the user
    /// navigated into must still be the one on screen (and highlighted).
    func testTheFolderSelectionSurvivesAReload() {
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        controller.selectFolderRow(rootID: root.id, path: "day2")
        let before = controller.folderTreeRows.map(\.title)

        session.reload()

        XCTAssertEqual(session.selectedFolderPath, "day2")
        XCTAssertEqual(session.assets.count, 2)
        XCTAssertEqual(controller.folderTreeRows.map(\.title), before,
                       "the tree keeps the folders the user had open")
    }

    // MARK: multi-select = filter (021 B)

    private func outlineView() throws -> NSOutlineView {
        try XCTUnwrap(Self.findOutline(controller.view))
    }

    private func rowIndex(_ title: String) throws -> Int {
        try XCTUnwrap(controller.folderTreeRows.firstIndex { $0.title == title },
                      "no row titled \(title) in \(controller.folderTreeRows.map(\.title))")
    }

    /// Let the observation bridge land: `session.selectFolders` re-runs the query synchronously, but
    /// the tree and the photo table are rebuilt on the next main-queue turn.
    private func settle(_ turns: Int = 3) {
        for _ in 0..<turns {
            let turned = expectation(description: "main-queue turn")
            DispatchQueue.main.async { turned.fulfill() }
            wait(for: [turned], timeout: 5)
        }
    }

    /// ⌘-clicking two folders filters to their **union**. This drives AppKit's own multi-selection
    /// (`selectRowIndexes` posts `outlineViewSelectionDidChange`, exactly what a ⌘-click does) — there
    /// is no key handling in the controller to test separately.
    func testCommandClickingTwoFoldersFiltersToTheirUnion() throws {
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        let outline = try outlineView()
        outline.selectRowIndexes(IndexSet([try rowIndex("day2"), try rowIndex("day2x")]),
                                 byExtendingSelection: false)

        XCTAssertEqual(Set(session.assets.map(\.filename)), ["b.dng", "c.dng", "d.dng"],
                       "day2 ∪ day2x — d.dng is not swallowed by the day2 prefix")
        XCTAssertEqual(session.selectedFolders.count, 2)
        XCTAssertEqual(controller.selectedFolderKeys.count, 2, "both rows stay highlighted")

        settle()
        XCTAssertEqual(controller.photoRowCount, 3, "the photo list drew the union")
    }

    /// `day2` + `day2/sub`: the child is inside the parent, so the list is `day2` once — and both
    /// rows the user selected stay highlighted.
    func testAParentAndItsChildUnionWithoutDuplicateRows() throws {
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        controller.setFolderExpanded(rootID: root.id, path: "day2", true)
        controller.selectFolderRows([FolderSelection(rootId: root.id, path: "day2"),
                                     FolderSelection(rootId: root.id, path: "day2/sub")])

        XCTAssertEqual(Set(session.assets.map(\.filename)), ["b.dng", "c.dng"])
        XCTAssertEqual(controller.photoRowCount, 2, "c.dng is not listed twice")
        XCTAssertEqual(controller.selectedFolderKeys.count, 2)
    }

    /// A selection that spans two roots is the union across them (the old single `folderPath` could
    /// not even name two roots).
    func testTheUnionSpansRoots() throws {
        let other = try addSecondRoot(["day2/z.dng", "day3/y.dng"])
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        controller.setFolderExpanded(rootID: other.id, path: "", true)
        controller.setFolderExpanded(rootID: other.id, path: "day2", true)

        controller.selectFolderRows([FolderSelection(rootId: root.id, path: "day2"),
                                     FolderSelection(rootId: other.id, path: "day2")])

        XCTAssertEqual(Set(session.assets.map(\.filename)), ["b.dng", "c.dng", "z.dng"])
        XCTAssertEqual(controller.photoRowCount, 3)
        XCTAssertEqual(Set(controller.selectedFolderKeys), ["\(root.id)|day2", "\(other.id)|day2"],
                       "one highlighted row per root — same path, different roots")
    }

    /// ⌘-clicking the last highlight off means 「全部照片」: the whole library, and the highlight moves
    /// back to that row (it is the model that says so, not AppKit's empty selection).
    func testClearingTheSelectionGoesBackToTheWholeLibrary() throws {
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        controller.selectFolderRows([FolderSelection(rootId: root.id, path: "day2")])
        XCTAssertEqual(session.assets.count, 2)

        controller.selectFolderRows([])
        XCTAssertEqual(session.assets.count, 4)
        XCTAssertTrue(session.selectedFolders.isEmpty)
        XCTAssertEqual(controller.selectedFolderKeys, ["*|"], "the highlight is back on 全部照片")
    }

    /// 「全部照片」 is the library, not a folder: it can only be a selection of one, and the model
    /// collapses a mixed set to "no constraint" (021 §B — the catalog's documented choice).
    func testAllPhotosCollapsesTheSelection() {
        XCTAssertEqual(CatalogSession.normalizedFolders([FolderSelection(rootId: nil)]), [])
        XCTAssertEqual(CatalogSession.normalizedFolders([FolderSelection(rootId: nil),
                                                         FolderSelection(rootId: "r", path: "day2")]), [])
        XCTAssertEqual(CatalogSession.normalizedFolders([FolderSelection(rootId: "r", path: "/day2/"),
                                                         FolderSelection(rootId: "r", path: "day2")]),
                       [FolderSelection(rootId: "r", path: "day2")],
                       "the same row selected twice is one clause, not two")
    }

    // MARK: a reload keeps the selection (by rootId + path, never by row index)

    /// A rating, an import, a metadata write — anything that calls `reload()` — must not move a
    /// multi-selection, and `reloadData()` must not auto-select row 0 and wipe the filter.
    func testTheMultiSelectionSurvivesAReload() throws {
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        controller.selectFolderRows([FolderSelection(rootId: root.id, path: "day2"),
                                     FolderSelection(rootId: root.id, path: "day2x")])
        let keysBefore = Set(controller.selectedFolderKeys)
        XCTAssertEqual(session.assets.count, 3)

        session.reload()
        controller.refresh()

        XCTAssertEqual(session.selectedFolders,
                       [FolderSelection(rootId: root.id, path: "day2"),
                        FolderSelection(rootId: root.id, path: "day2x")])
        XCTAssertEqual(session.assets.count, 3, "the filter survived, it was not reset to 全部照片")
        XCTAssertEqual(controller.photoRowCount, 3)
        XCTAssertEqual(Set(controller.selectedFolderKeys), keysBefore,
                       "the same two rows are still highlighted after the rebuild")
    }

    /// A selected folder that lost its last photo falls back to its root — the multi-selection case
    /// of the 020 rule "narrow to what still exists, never filter to nothing".
    func testASelectedFolderThatDisappearsFallsBackToItsRoot() throws {
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        controller.selectFolderRows([FolderSelection(rootId: root.id, path: "day2"),
                                     FolderSelection(rootId: root.id, path: "day2x")])

        let catalog = try Catalog.open(at: library)
        let ids = try catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM assets WHERE rel_path LIKE 'day2x/%'")
        }
        for id in ids { try catalog.setDeleted(true, forAsset: id) }

        session.reload()
        controller.refresh()

        XCTAssertEqual(session.selectedFolders, [FolderSelection(rootId: root.id, path: "day2"),
                                                 FolderSelection(rootId: root.id, path: nil)],
                       "day2x is gone, its root takes its place")
        XCTAssertEqual(Set(session.assets.map(\.filename)), ["a.dng", "b.dng", "c.dng"])
    }

    /// Register a second source root with the given photos and reload, the way an import would.
    @discardableResult
    private func addSecondRoot(_ relPaths: [String]) throws -> SourceRoot {
        let catalog = try Catalog.open(at: library)
        let dir = tmp.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let other = try catalog.ensureRoot(for: dir, mode: .reference)
        for relPath in relPaths {
            let asset = Asset(sourceRootId: other.id, relPath: relPath,
                              filename: (relPath as NSString).lastPathComponent,
                              ext: (relPath as NSString).pathExtension, kind: .raw,
                              size: 1, mtime: 0, contentHash: UUID().uuidString)
            try catalog.dbQueue.write { db in try asset.insert(db) }
        }
        session.reload()
        controller.refresh()
        return other
    }

    // MARK: height

    /// The tree is a navigation surface with a floor, not `rows × 46`: at the contract window size a
    /// two-row tree is 180 pt, and it never eats the photo list.
    func testTheTreeHasAFloorAndNeverEatsThePhotoList() {
        for height in Self.panelHeights {
            let frames = controller.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault,
                                                           height: height))
            XCTAssertGreaterThanOrEqual(frames.tree.height, WorkspaceLayout.browserTreeMinHeight,
                                        "tree at panel \(height)")
            XCTAssertLessThanOrEqual(frames.tree.height, height * WorkspaceLayout.browserTreeMaxFraction + 0.001,
                                     "tree at panel \(height) must stay under 45 % of the panel")
            XCTAssertGreaterThanOrEqual(frames.photos.height, WorkspaceLayout.browserPhotoListMinHeight,
                                        "photo list at panel \(height)")
            XCTAssertEqual(frames.tree.minY + frames.tree.height + WorkspaceLayout.browserPaneGap,
                           frames.photos.minY, accuracy: 0.001,
                           "the two panes must not overlap or leave a gap")
        }
    }

    /// A deep, fully expanded tree grows up to the ceiling — and stops there rather than pushing the
    /// photo list off the panel.
    func testAManyRowTreeGrowsToTheCeiling() {
        // 12 *folders* of one photo each, under `many` — a folder with 12 photos directly in it is
        // one row (it has no subfolders), so a row count needs nested directories, not more files.
        let extra = try? Catalog.open(at: library)
        if let extra {
            for i in 0..<12 {
                let asset = Asset(sourceRootId: root.id, relPath: "many/f\(i)/x.dng",
                                  filename: "x.dng", ext: "dng", kind: .raw,
                                  size: 1, mtime: 0, contentHash: UUID().uuidString)
                try? extra.dbQueue.write { db in try asset.insert(db) }
            }
        }
        session.reload()
        controller.refresh()
        controller.setFolderExpanded(rootID: root.id, path: "", true)
        controller.setFolderExpanded(rootID: root.id, path: "many", true)

        let panel: CGFloat = 744
        let frames = controller.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault,
                                                       height: panel))
        XCTAssertGreaterThan(controller.folderTreeRowCount, 10)
        XCTAssertLessThanOrEqual(frames.tree.height, panel * WorkspaceLayout.browserTreeMaxFraction + 0.001)
        XCTAssertGreaterThanOrEqual(frames.photos.height, WorkspaceLayout.browserPhotoListMinHeight)
        XCTAssertEqual(frames.tree.height,
                       WorkspaceLayout.browserTreeHeight(rowCount: controller.folderTreeRowCount,
                                                         panelHeight: panel),
                       accuracy: 0.001, "the pane uses the contract, it does not re-derive it")
    }

    /// The pure contract, stated on its own: floor, ceiling, and the photo list's floor.
    func testTheTreeHeightContract() {
        XCTAssertEqual(WorkspaceLayout.browserTreeHeight(rowCount: 2, panelHeight: 744), 180,
                       accuracy: 0.001, "two rows still get the 180 pt floor")
        XCTAssertEqual(WorkspaceLayout.browserTreeHeight(rowCount: 7, panelHeight: 744), 7 * 28 + 6,
                       accuracy: 0.001, "021 A: the content term is rows × 28 + 6, not rows × 46 + 6")
        XCTAssertEqual(WorkspaceLayout.browserTreeHeight(rowCount: 100, panelHeight: 900), 405,
                       accuracy: 0.001, "45 % of 900")
        XCTAssertEqual(WorkspaceLayout.browserTreeHeight(rowCount: 100, panelHeight: 1200), 540,
                       accuracy: 0.001, "45 % of 1200")
        // A short panel keeps the floor (the photo list gives way, the tree does not disappear).
        XCTAssertGreaterThanOrEqual(WorkspaceLayout.browserTreeHeight(rowCount: 100, panelHeight: 400),
                                    WorkspaceLayout.browserTreeMinHeight)
    }
}
