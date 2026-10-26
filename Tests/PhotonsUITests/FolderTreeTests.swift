import XCTest
import AppKit
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// The left browser's source list is a **folder tree**, not a flat list of roots.
///
/// Three things have to hold at once, and each of them was wrong before:
///
/// * the shape — 全部照片 → the source root → the folders `rel_path` implies, indented, collapsible,
///   with counts (`day2` holds 2, its child `sub` holds 1);
/// * the filter — clicking `day2` must show exactly that subtree in the photo list, and clicking
///   全部照片 must bring everything back;
/// * the height — the tree was `rows × 46`, capped at 200, so a one-root library got a ~52 pt strip
///   ("这个区域的窗口太窄，大概只有几十 px"). It is now at least 180 pt, at most 45 % of the panel,
///   and leaves the photo list its own 120 pt floor.
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
        XCTAssertEqual(WorkspaceLayout.browserTreeHeight(rowCount: 100, panelHeight: 900), 405,
                       accuracy: 0.001, "45 % of 900")
        XCTAssertEqual(WorkspaceLayout.browserTreeHeight(rowCount: 100, panelHeight: 1200), 540,
                       accuracy: 0.001, "45 % of 1200")
        // A short panel keeps the floor (the photo list gives way, the tree does not disappear).
        XCTAssertGreaterThanOrEqual(WorkspaceLayout.browserTreeHeight(rowCount: 100, panelHeight: 400),
                                    WorkspaceLayout.browserTreeMinHeight)
    }
}
