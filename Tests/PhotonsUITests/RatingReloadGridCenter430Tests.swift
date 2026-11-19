import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 430 — 三个界面联动的数字。
///
/// The user's three sentences (2026-11-19) are the acceptance, and each has its own counter:
///
///   ① 「给照片添加星后，侧栏会刷新一次」 — a star must not rebuild the photo list. The number is
///      `BrowserPaneController.listReloadCount` (how many times `photosTable.reloadData()` ran):
///      unchanged across a rating, +1 across a structure change. The stars must still appear
///      (that is the "don't fix it by not fixing it" half).
///   ② 「从单图退回网格…缩略图需要重新加载（占位图一闪而过）」 — the visible cells must already be
///      drawing a real bitmap in the turn the grid is installed, and the shared provider's
///      `generated`/`diskHits` must not move while doing it (`memoryHits` may).
///   ③ 「单图退回网格后…这张图居中」 — the anchor's `midY` must land inside the viewport's `midY`
///      ± half a card, and a later metadata tick must not move the scroll offset.
@MainActor
final class RatingReloadGridCenter430Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-430-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
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

    /// `count` real JPEG files (fast to decode — this lane is about the view's redraw path, not the
    /// RAW pipeline) with distinct capture times, newest first.
    private func makeLibrary(count: Int = 40) throws -> (CatalogSession, URL) {
        _ = NSApplication.shared
        let url = workDir.appendingPathComponent("S430.\(LibraryLayout.packageExtension)", isDirectory: true)
        let setup = try Catalog.create(at: url)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try setup.ensureRoot(for: src, mode: .reference)

        for i in 0 ..< count {
            let name = String(format: "IMG_%04d.jpg", i)
            let file = src.appendingPathComponent(name)
            try solidJPEG(hue: Double(i) / Double(max(1, count))).write(to: file)
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "jpg",
                              kind: .jpeg, size: 1024, mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 1200, height: 800,
                              captureTime: String(format: "2026-01-01T10:%02d:00Z", i % 60),
                              captureLocalDate: "2026-01-01 10:00",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try setup.dbQueue.write { db in try asset.insert(db) }
        }

        let store = MemoryStore()
        let session = CatalogSession(filterStore: store, sortPreferenceStore: store,
                                     remembersRecentLibrary: false)
        try session.open(url)
        session.setSortOrder(.newestFirst)
        return (session, url)
    }

    private func solidJPEG(hue: Double) -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8,
                                bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(NSColor(hue: hue, saturation: 0.7, brightness: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        let image = context.makeImage()!
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg,
                                                              properties: [.compressionFactor: 0.9])!
    }

    private func makeWindow() -> NSWindow {
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950))
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1500, height: 950))
        windows.append(window)
        return window
    }

    private func pump(_ seconds: TimeInterval = 0.02) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private func settle(_ turns: Int = 8) {
        for _ in 0..<turns { pump(0.02) }
    }

    /// The three surfaces on one real window, laid out as the app lays them out.
    @MainActor
    private final class Surfaces {
        let root: WorkspaceRootView
        let grid: AssetGridController
        let pane: BrowserPaneController
        init(root: WorkspaceRootView) {
            self.root = root
            self.grid = root.gridController
            self.pane = root.browserPane
        }
    }

    private func makeSurfaces(_ session: CatalogSession) -> Surfaces {
        let window = makeWindow()
        let root = WorkspaceRootView(session: session)
        root.frame = NSRect(x: 0, y: 0, width: 1500, height: 950)
        window.contentView?.addSubview(root)
        TestWindows.show(window)
        root.layoutSubtreeIfNeeded()
        settle(6)
        root.setBrowserMode(.list)
        root.layoutSubtreeIfNeeded()
        settle(4)
        return Surfaces(root: root)
    }

    private func waitForThumbnails(_ surfaces: Surfaces, seconds: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            settle(2)
            let busy = surfaces.grid.pendingThumbnailRequests + surfaces.pane.pendingThumbnailRequests
            if busy == 0, surfaces.grid.visibleThumbnailCount > 0 { return }
        }
    }

    private func rowCell(_ pane: BrowserPaneController, id: String) -> PhotoRowCell? {
        let table = pane.photoListForTesting
        for row in 0..<table.numberOfRows {
            guard let cell = table.view(atColumn: 0, row: row,
                                        makeIfNecessary: false) as? PhotoRowCell,
                  cell.assetID == id else { continue }
            return cell
        }
        return nil
    }

    // MARK: - ① 加星不重载侧栏，但星确实亮了

    func testRatingDoesNotReloadTheListButDoesRepaintTheStars() throws {
        let (session, _) = try makeLibrary()
        let surfaces = makeSurfaces(session)
        waitForThumbnails(surfaces)

        let id = session.assets[0].id
        session.selectOnly(id)
        settle(4)

        let cellBefore = try XCTUnwrap(rowCell(surfaces.pane, id: id), "① 这一行应在屏上")
        XCTAssertEqual(cellBefore.lastDrawnBadges.filter { $0.hasPrefix("stars:") }.count, 0,
                       "① 前置：还没打星")

        let reloadBefore = surfaces.pane.listReloadCount
        XCTAssertTrue(session.setRatingForSelection(3))
        settle(6)

        let cellAfter = try XCTUnwrap(rowCell(surfaces.pane, id: id), "① 加星后这一行仍在屏上")
        XCTAssertEqual(surfaces.pane.listReloadCount, reloadBefore,
                       "① 加一颗星不许 reloadData（\(reloadBefore) → \(surfaces.pane.listReloadCount)）")
        XCTAssertTrue(cellAfter === cellBefore, "① 同一行对象，没有被回收重建")
        XCTAssertTrue(cellAfter.lastDrawnBadges.contains("stars:3"),
                      "① 星标必须真的更新到 ★3（实际 \(cellAfter.lastDrawnBadges)）")
        print("① reloadData \(reloadBefore) → \(surfaces.pane.listReloadCount) · badges "
              + "\(cellBefore.lastDrawnBadges) → \(cellAfter.lastDrawnBadges) · sameCell "
              + "\(cellAfter === cellBefore)")
    }

    /// A① 的反面：结构变化仍然整表重载。
    func testAStructureChangeStillReloadsTheList() throws {
        let (session, _) = try makeLibrary()
        let surfaces = makeSurfaces(session)
        waitForThumbnails(surfaces)

        let id = session.assets[0].id
        session.selectOnly(id)
        XCTAssertTrue(session.setRatingForSelection(5))
        settle(4)

        let before = surfaces.pane.listReloadCount
        let rowsBefore = session.assets.count
        session.applyFilter(CatalogFilter(ratingAtLeast: 5))
        settle(6)

        XCTAssertLessThan(session.assets.count, rowsBefore, "③ 前置：筛选确实改变了行集合")
        XCTAssertEqual(surfaces.pane.listReloadCount, before + 1,
                       "③ 换筛选必须 reloadData 一次（\(before) → \(surfaces.pane.listReloadCount)）")
        print("③ 结构变化 reloadData \(before) → \(surfaces.pane.listReloadCount)，行数 "
              + "\(rowsBefore) → \(session.assets.count)")
    }

    // MARK: - ② 切回网格：首帧就有图，且不新增请求

    func testReturningFromTheLoupeKeepsAToBAndDrawsFromMemory() throws {
        let (session, _) = try makeLibrary()
        let surfaces = makeSurfaces(session)
        waitForThumbnails(surfaces)

        let anchorID = session.assets[12].id
        session.selectOnly(anchorID)
        settle(4)
        XCTAssertGreaterThan(surfaces.grid.visibleThumbnailCount, 0, "② 前置：网格有真图")

        surfaces.root.showModule(for: .loupe)
        session.mode = .loupe
        settle(6)
        XCTAssertEqual(session.mode, .loupe)

        // Go back and read the cells **in the same turn** — nothing pumped between the install and
        // the read, so "not a placeholder" is a first-frame claim and not a settled-state one.
        let statsBefore = surfaces.grid.thumbnailStats
        session.mode = .grid
        surfaces.root.showModule(for: .grid)
        let drawnImmediately = surfaces.grid.visibleThumbnailCount
        let visibleImmediately = surfaces.grid.visibleCellCount
        let pendingImmediately = surfaces.grid.pendingThumbnailRequests
        let statsAfter = surfaces.grid.thumbnailStats
        settle(8)

        XCTAssertGreaterThan(visibleImmediately, 0, "② 回到网格应立刻有可见格子")
        XCTAssertEqual(drawnImmediately, visibleImmediately,
                       "② 首帧每一格都必须已经有真图（\(drawnImmediately)/\(visibleImmediately)）")
        XCTAssertEqual(pendingImmediately, 0, "② 首帧不许挂新请求")
        XCTAssertEqual(statsAfter.generated, statsBefore.generated,
                       "② 切模式不许重新生产（\(statsBefore.generated) → \(statsAfter.generated)）")
        XCTAssertEqual(statsAfter.diskHits, statsBefore.diskHits,
                       "② 切模式不许读盘（\(statsBefore.diskHits) → \(statsAfter.diskHits)）")
        XCTAssertGreaterThan(statsAfter.memoryHits, statsBefore.memoryHits,
                             "② 命中应来自内存层（\(statsBefore.memoryHits) → \(statsAfter.memoryHits)）")
        print("② 首帧有图 \(drawnImmediately)/\(visibleImmediately) · pending \(pendingImmediately) · "
              + "memory \(statsBefore.memoryHits) → \(statsAfter.memoryHits) · "
              + "disk \(statsBefore.diskHits) → \(statsAfter.diskHits) · "
              + "generated \(statsBefore.generated) → \(statsAfter.generated)")
    }

    // MARK: - ③ 居中，且只居中一次

    func testReturningFromTheLoupeCentresTheAnchorOnce() throws {
        let (session, _) = try makeLibrary()
        let surfaces = makeSurfaces(session)
        waitForThumbnails(surfaces)

        let grid = surfaces.grid
        let anchorIndex = 24
        let anchorID = session.assets[anchorIndex].id
        session.selectOnly(anchorID)
        settle(4)

        // Park the viewport at the top so the anchor is off-screen and there is room to centre.
        let scroll = try XCTUnwrap(grid.collectionView.enclosingScrollView)
        scroll.contentView.setBoundsOrigin(.zero)
        settle(4)

        surfaces.root.showModule(for: .loupe)
        settle(6)
        surfaces.root.showModule(for: .grid)
        settle(6)

        let visible = scroll.contentView.bounds
        let frame = try XCTUnwrap(
            grid.collectionView.layoutAttributesForItem(at: IndexPath(item: anchorIndex, section: 0))?.frame,
            "③ 锚点应有布局属性")
        let halfRow = max(1, grid.metrics.rowHeight) / 2
        let delta = abs(frame.midY - visible.midY)
        XCTAssertLessThanOrEqual(delta, halfRow,
                                 "③ 锚点 midY \(frame.midY) 应落在视口 midY \(visible.midY) ± 半格 \(halfRow) 内")

        // ③②: a later metadata tick must not move the offset the user is at.
        scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        settle(4)
        let before = scroll.contentView.bounds.origin
        XCTAssertTrue(session.setRatingForSelection(2))
        settle(6)
        let after = scroll.contentView.bounds.origin
        XCTAssertEqual(after.y, before.y, accuracy: 0.5,
                       "③② 元数据变化不许把网格滚回去（\(before) → \(after)）")

        print("③ anchor midY \(frame.midY) · viewport midY \(visible.midY) · Δ \(delta) · "
              + "halfRow \(halfRow) · ③② y \(before.y) → \(after.y)")
    }
}
