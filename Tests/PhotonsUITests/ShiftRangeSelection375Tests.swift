import XCTest
import AppKit
import GRDB
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 375 — ⇧ 范围选择 / ⌘ 点选。
///
/// The user's rule, in three parts:
///
///   ① ⇧+click another photo selects every photo between the **original** photo and the new one;
///   ② a second ⇧+click still measures from the original photo — the thick blue ring (the anchor,
///      also the photo the loupe shows) never moves during the gesture;
///   ③ ⌘+click adds/removes one photo; adding one makes it the anchor and the new range base.
///
/// The fixture has ten photos whose **display order** is A…J and whose ids are deliberately the
/// reverse lexicographic order (`asset-10` … `asset-01`), so every range assertion distinguishes
/// "display order" from "id order".
@MainActor
final class ShiftRangeSelection375Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-range375-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixture

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    /// Ten rows A…J in display order. `ids` is in that same display order; the ids themselves sort
    /// the other way round on purpose.
    private func makeSession() throws -> (CatalogSession, [String]) {
        let url = workDir.appendingPathComponent("Range.\(LibraryLayout.packageExtension)", isDirectory: true)
        let setup = try Catalog.create(at: url)
        let rootDir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try setup.ensureRoot(for: rootDir, mode: .reference)

        var ids: [String] = []
        for index in 0 ..< 10 {
            let letter = String(UnicodeScalar(UInt8(65 + index)))
            let name = "\(letter).dng"
            let file = rootDir.appendingPathComponent(name)
            try Data([0x00]).write(to: file)
            let asset = Asset(id: String(format: "asset-%02d", 10 - index),
                              sourceRootId: root.id,
                              relPath: name,
                              filename: name,
                              ext: "dng",
                              kind: .raw,
                              size: 1,
                              mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 6000,
                              height: 4000,
                              captureTime: String(format: "2026-01-01T00:%02d:00Z", index),
                              cameraModel: "LEICA SL3",
                              cameraKey: "leica|sl3")
            try setup.dbQueue.write { db in try asset.insert(db) }
            ids.append(asset.id)
        }

        let store = MemoryStore()
        let session = CatalogSession(filterStore: store,
                                     sortPreferenceStore: store,
                                     remembersRecentLibrary: false)
        try session.open(url)
        session.setSortOrder(.oldestFirst)
        XCTAssertEqual(session.assets.map(\.id), ids, "fixture: display order A…J")
        XCTAssertEqual(ids.map { $0 }, ids.sorted(by: >),
                       "fixture: ids sort the opposite way from the display order")
        return (session, ids)
    }

    private func makeViews(session: CatalogSession) -> (AssetGridController, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200))
        windows.append(window)

        let grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: 1600, height: 1200)
        window.contentView?.addSubview(grid.view)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0 ..< 6 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        grid.view.layoutSubtreeIfNeeded()
        return (grid, window)
    }

    private func point(for id: String, in grid: AssetGridController, session: CatalogSession) throws -> NSPoint {
        let index = try XCTUnwrap(session.assets.firstIndex { $0.id == id })
        let frame = try XCTUnwrap(grid.collectionView
            .layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    // MARK: - ①–⑦, ⑨: the range measures from the base, never from the last landing

    func testShiftRangeUsesTheOriginalBaseAndNeverMovesTheAnchor() throws {
        let (session, id) = try makeSession()
        let (a, b, c, d, e, f, g, h) = (id[0], id[1], id[2], id[3], id[4], id[5], id[6], id[7])

        // ① single click B, then ⇧ E.
        session.selectOnly(b)
        session.selectRange(to: e)
        XCTAssertEqual(session.selection, [b, c, d, e], "① 单击 B、⇧ E ⇒ B…E")
        XCTAssertEqual(session.anchorID, b, "① 锚仍是 B")
        XCTAssertEqual(session.selectionBase, b, "① 范围基点是 B")

        // ② a second ⇧ click still measures from B (not from E).
        session.selectRange(to: h)
        XCTAssertEqual(session.selection, Set([b, c, d, e, f, g, h]), "② 从 B 起到 H，不是从 E 起")
        XCTAssertEqual(session.anchorID, b, "② 锚不动")
        XCTAssertEqual(session.selectionBase, b, "② 基点不动")

        // ③ backwards ⇧ click.
        session.selectRange(to: a)
        XCTAssertEqual(session.selection, [a, b], "③ 反向 ⇧ A ⇒ A…B")
        XCTAssertEqual(session.anchorID, b, "③ 锚仍然不动")

        // ④ ⌘ removes a photo that is not the anchor: the anchor and base stay.
        session.toggle(g)                       // on: G becomes anchor + base
        session.toggle(g)                       // off: the table's 「⌘点 G（关）」
        XCTAssertEqual(session.selection, [a, b], "④ ⌘ 关掉 G ⇒ 回到 A、B")
        XCTAssertEqual(session.anchorID, b, "④ 锚回到显示顺序里的 B")

        // ⑤ ⌘ adds D: the newly added photo becomes the anchor and the new base.
        session.toggle(d)
        XCTAssertEqual(session.selection, [a, b, d], "⑤ ⌘ 开 D")
        XCTAssertEqual(session.anchorID, d, "⑤ 加入的那张成为锚")
        XCTAssertEqual(session.selectionBase, d, "⑤ 加入的那张成为范围基点")

        // ⑥ ⇧ from the new base ⇒ D…F, anchor stays D.
        session.selectRange(to: f)
        XCTAssertEqual(session.selection, [d, e, f], "⑥ 从 D 起 ⇧ F ⇒ D…F")
        XCTAssertEqual(session.anchorID, d, "⑥ 锚仍是 D")

        // ⑦ plain click A resets the window, then ⇧ C.
        session.selectOnly(a)
        session.selectRange(to: c)
        XCTAssertEqual(session.selection, [a, b, c], "⑦ 单击 A、⇧ C ⇒ A…C")
        XCTAssertEqual(session.anchorID, a, "⑦ 锚是 A")
        XCTAssertEqual(session.selectionBase, a, "⑦ 基点是 A")
    }

    // MARK: - ⑧ ⇧+→ moves the cursor, not the anchor

    func testShiftArrowExtendsFromTheBaseWhileTheAnchorStays() throws {
        let (session, id) = try makeSession()
        let (a, b, c, d) = (id[0], id[1], id[2], id[3])

        session.selectOnly(a)
        XCTAssertTrue(session.moveAnchor(by: 1, extend: true))
        XCTAssertTrue(session.moveAnchor(by: 1, extend: true))
        XCTAssertEqual(session.selection, [a, b, c], "⑧ ⇧+→ 两次到 C：A…C")
        XCTAssertEqual(session.anchorID, a, "⑧ ⇧ 期间锚不动")
        XCTAssertEqual(session.selectionBase, a, "⑧ ⇧ 期间基点不动")

        // A third press advances the cursor one more step (and still leaves the anchor alone).
        XCTAssertTrue(session.moveAnchor(by: 1, extend: true))
        XCTAssertEqual(session.selection, [a, b, c, d], "⑧ 第三次 ⇧+→ 到 D")
        XCTAssertEqual(session.anchorID, a, "⑧ 第三次也不动锚")
        XCTAssertEqual(session.selectionBase, a, "⑧ 第三次也不动基点")

        // Backwards: one ⇧+← steps the cursor back to C.
        XCTAssertTrue(session.moveAnchor(by: -1, extend: true))
        XCTAssertEqual(session.selection, [a, b, c], "⑧ 反向一步回到 C")
        XCTAssertEqual(session.anchorID, a)
        XCTAssertEqual(session.selectionBase, a)
    }

    // MARK: - ⑨ display order, not id order

    func testRangeFollowsDisplayOrderWhenIDsSortTheOtherWay() throws {
        let (session, id) = try makeSession()
        // The fixture's ids are already the reverse of the display order; repeat ① on it.
        let (b, e) = (id[1], id[4])
        XCTAssertGreaterThan(b, e, "fixture: display-later photo has the smaller id")

        session.selectOnly(b)
        session.selectRange(to: e)
        XCTAssertEqual(session.selection, Set(id[1 ... 4]), "⑨ 仍按显示顺序取 B…E")
        XCTAssertEqual(session.anchorID, b)
        XCTAssertEqual(session.selectionBase, b)
    }

    // MARK: - ⑩ the UI writeback honours the session (thick ring only on the anchor)

    func testWritebackKeepsTheAnchorAndRangeFromTheModel() throws {
        let (session, id) = try makeSession()
        let (b, c, d, e) = (id[1], id[2], id[3], id[4])
        let (grid, _) = makeViews(session: session)
        grid.onActivate = { [weak session] id in session?.activate(id) }

        session.selectOnly(b)
        let shifted = grid.handleSelectionClick(at: try point(for: e, in: grid, session: session),
                                                modifiers: .shift)
        XCTAssertTrue(shifted, "⑩ ⇧ 点击由 session 解析，不交给 AppKit")
        XCTAssertEqual(session.selection, [b, c, d, e], "⑩ 范围 B…E")
        XCTAssertEqual(session.anchorID, b, "⑩ 锚仍是 B")
        XCTAssertEqual(session.selectionBase, b, "⑩ 基点仍是 B")

        // The view mirrors the model: four selected rows, the thick ring only on B.
        XCTAssertEqual(grid.collectionView.selectionIndexPaths.count, 4, "⑩ 四行都被选中")
        for photo in [b, c, d, e] {
            let item = try XCTUnwrap(grid.visibleItem(forAssetID: photo), "⑩ 单元格应在屏上")
            XCTAssertEqual(item.cardView.isActive, photo == b,
                           "⑩ 粗蓝框只在锚 B 上（\(photo.prefix(8))）")
        }

        // AppKit's own selection writeback is a trigger only: feeding the same range back must not
        // move the anchor/base, and must never invent an anchor from the first id in the set.
        let paths = Set(session.assets.enumerated()
            .filter { session.selection.contains($0.element.id) }
            .map { IndexPath(item: $0.offset, section: 0) })
        grid.collectionView.selectionIndexPaths = paths
        grid.collectionView(grid.collectionView, didSelectItemsAt: paths)
        XCTAssertEqual(session.selection, [b, c, d, e], "⑩ 回写不改变范围")
        XCTAssertEqual(session.anchorID, b, "⑩ 回写不挪锚")
        XCTAssertEqual(session.selectionBase, b, "⑩ 回写不挪基点")
        XCTAssertEqual(session.anchorAsset?.id, b, "⑩ 单图界面那张 == anchor")

        // A native selection that no longer contains the anchor still must not pick `ids.first`
        // (id order here is the reverse of display order): it falls back to the display-order last.
        let withoutAnchor = Set([c, d])
        grid.collectionView.selectionIndexPaths = Set(session.assets.enumerated()
            .filter { withoutAnchor.contains($0.element.id) }
            .map { IndexPath(item: $0.offset, section: 0) })
        grid.collectionView(grid.collectionView,
                            didSelectItemsAt: grid.collectionView.selectionIndexPaths)
        XCTAssertEqual(session.anchorID, d, "⑩ 锚缺失时按显示顺序回退，而不是 ids.first")
        XCTAssertEqual(session.anchorAsset?.id, d)
    }
}
