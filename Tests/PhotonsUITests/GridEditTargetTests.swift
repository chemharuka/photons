import XCTest
import AppKit
import GRDB
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 派单 119: an edit made in the grid enters the loupe on the photo it actually writes.
///
/// The rules under test are the user's three sentences, in order:
///
///   ① 「网格里一改照片就进单图」 — the first tick that changes the document switches the mode, and
///      the following ticks of the same drag keep writing the same photo.
///   ② 「多选时改的是当前顺序下的第一张」 — `editTarget` is a pure function of selection × order, so
///      "the first one in the order I am looking at" cannot become "the anchor" by accident.
///   ③ 「双击哪一个进入哪一个」 — the grid's and the filmstrip's double-click both call
///      `CatalogSession.activate` with the hit photo, never with the anchor.
///
/// The fixture is a real (reference) library with five rows, so `session.assets` is the sorted order
/// every view reads; no RAW is decoded here — the mode switch is a state change, and the decode
/// counter is asserted to stay put.
@MainActor
final class GridEditTargetTests: XCTestCase {

    private var workDir: URL!
    private var packageURL: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-grid-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        packageURL = workDir.appendingPathComponent("Grid.\\(LibraryLayout.packageExtension)")
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        RAWDecoder.resetDecodeCounts()
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    /// Five rows with distinct capture times. The order itself is whatever the session's sort order
    /// produces — every assertion below reads `session.assets`, never a hard-coded index.
    private func makeSession(count: Int = 5) throws -> (CatalogSession, [String]) {
        let setup = try Catalog.create(at: packageURL)
        let rootDir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try setup.ensureRoot(for: rootDir, mode: .reference)
        var ids: [String] = []
        for i in 0 ..< count {
            let name = String(format: "IMG_%04d.dng", i)
            let asset = Asset(sourceRootId: root.id,
                              relPath: name,
                              filename: name,
                              ext: "dng",
                              kind: .raw,
                              size: 1024,
                              mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 6000,
                              height: 4000,
                              captureTime: String(format: "2026-10-2%dT05:09:%02dZ", i / 60, i % 60),
                              cameraModel: "LEICA SL3",
                              cameraKey: "leica|sl3")
            try setup.dbQueue.write { db in try asset.insert(db) }
            ids.append(asset.id)
        }
        let session = CatalogSession()
        try session.open(packageURL)
        XCTAssertEqual(Set(session.assets.map(\.id)), Set(ids))
        return (session, ids)
    }

    /// A grid + strip over the same session, laid out in a window so the frames exist.
    private func makeViews(session: CatalogSession) -> (AssetGridController, FilmstripController, NSWindow) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        windows.append(window)

        let grid = AssetGridController(session: session)
        let strip = FilmstripController(session: session)
        _ = grid.view
        _ = strip.view
        grid.view.frame = NSRect(x: 0, y: 80, width: 1400, height: 780)
        strip.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 83)
        window.contentView?.addSubview(grid.view)
        window.contentView?.addSubview(strip.view)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0 ..< 6 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        grid.view.layoutSubtreeIfNeeded()
        strip.view.layoutSubtreeIfNeeded()
        return (grid, strip, window)
    }

    // MARK: - ① editTarget is the order's first selected photo

    func testEditTargetSingleMultiEmptyAndDeletedIDs() {
        let order = ["a", "b", "c", "d"]

        XCTAssertEqual(CatalogSession.editTarget(selection: ["b"], order: order), "b",
                       "单选：就是那一张")
        XCTAssertEqual(CatalogSession.editTarget(selection: ["c", "a", "d"], order: order), "a",
                       "多选乱序：不是点击顺序，是 order 里最靠前的 a")
        XCTAssertNil(CatalogSession.editTarget(selection: [], order: order),
                     "空选集：没有目标")
        XCTAssertEqual(CatalogSession.editTarget(selection: ["gone", "b"], order: order), "b",
                       "选集含已删除 id：跳过它，取仍然存在的第一张")
        XCTAssertNil(CatalogSession.editTarget(selection: ["gone", "also-gone"], order: order),
                     "选集里的 id 全部已删除：没有目标")
        XCTAssertNil(CatalogSession.editTarget(selection: ["a"], order: []),
                     "没有顺序就没有第一张")
    }

    /// The same rule against the live session: the target is the first selected row of `assets`,
    /// not the anchor the user happened to click last.
    func testCurrentEditTargetUsesTheLiveOrderNotTheAnchor() throws {
        let (session, _) = try makeSession()
        let order = session.assets.map(\.id)
        XCTAssertGreaterThanOrEqual(order.count, 3)

        session.setSelection([order[2], order[0]], anchor: order[2])
        XCTAssertEqual(session.anchorID, order[2], "fixture: the anchor is the later row")
        XCTAssertEqual(session.currentEditTargetID, order[0],
                       "多选时的目标必须是当前顺序第一张，不是锚点")
    }

    // MARK: - ② a grid drag enters the loupe on the target

    func testDraggingInTheGridEntersTheLoupeOnTheEditTargetWithoutEndingTheDrag() throws {
        let (session, _) = try makeSession()
        let order = session.assets.map(\.id)
        let target = order[0]
        let anchor = order[2]
        session.setSelection([anchor, target], anchor: anchor)
        XCTAssertEqual(session.mode, .grid)

        let historyBefore = session.history.count
        let revisionBefore = session.editRevision

        // Slider down: the panel says "a drag is in progress", then the first tick writes.
        session.setAdjusting(true)
        session.applyEdit { $0.light.exposure = 0.75 }

        XCTAssertEqual(session.mode, .loupe, "第一次真正写入 = 进单图")
        XCTAssertEqual(session.anchorID, target, "anchor 同步改成被改的那张")
        XCTAssertEqual(session.selection, [target], "切进单图后选集收成唯一一张")
        XCTAssertEqual(session.loadedEditAssetID, target, "加载的文档就是被改的那张")
        XCTAssertEqual(session.edit.light.exposure, 0.75, "改动落在 editTarget 上")
        XCTAssertTrue(session.isAdjusting, "模式切换没有结束这次拖动")
        XCTAssertNotEqual(session.editRevision, revisionBefore)

        // The rest of the drag: same photo, no re-selection, no extra history until release.
        session.applyEdit { $0.light.exposure = 0.9 }
        XCTAssertEqual(session.edit.light.exposure, 0.9)
        XCTAssertEqual(session.history.count, historyBefore, "拖动中仍然不写历史")

        // Release: one commit = one row, and the row belongs to the target.
        session.setAdjusting(false)
        XCTAssertTrue(session.commitEdit(label: "曝光"))
        XCTAssertEqual(session.history.count, historyBefore + 1, "一次拖动 = 一条历史")
        XCTAssertFalse(session.isAdjusting)
    }

    func testGridEditWithNoSelectionWritesNothingAndStaysInTheGrid() throws {
        let (session, _) = try makeSession()
        session.setSelection([], anchor: nil)
        XCTAssertNil(session.anchorID)
        XCTAssertEqual(session.mode, .grid)

        let before = session.edit
        let historyBefore = session.history.count
        let revisionBefore = session.editRevision

        session.applyEdit { $0.light.exposure = 1.25 }

        XCTAssertEqual(session.mode, .grid, "没有选区就不切模式")
        XCTAssertEqual(session.edit, before, "没有选区就不写文档")
        XCTAssertEqual(session.editRevision, revisionBefore)
        XCTAssertEqual(session.history.count, historyBefore)
        XCTAssertNil(session.currentEditTargetID)
    }

    /// A no-op tick (the slider returns to the value that is already there) is not an edit and must
    /// not switch either.
    func testAnIdenticalWriteInTheGridDoesNotEnterTheLoupe() throws {
        let (session, _) = try makeSession()
        session.selectOnly(session.assets[0].id)
        let exposure = session.edit.light.exposure

        session.applyEdit { $0.light.exposure = exposure }
        XCTAssertEqual(session.mode, .grid, "没有语义变化就不切")
    }

    // MARK: - ③ double-click opens the hit photo

    func testDoubleClickingTheFifthFilmstripThumbnailOpensThatPhoto() throws {
        let (session, _) = try makeSession()
        let order = session.assets.map(\.id)
        XCTAssertGreaterThanOrEqual(order.count, 5)
        session.selectOnly(order[0])
        let (_, strip, _) = makeViews(session: session)
        strip.onActivate = { [weak session] id in session?.activate(id) }

        let frames = strip.laidOutItemFrames
        XCTAssertEqual(frames.count, order.count, "胶片条为每张照片排了一个格子")
        strip.activateItem(at: NSPoint(x: frames[4].midX, y: frames[4].midY))

        XCTAssertEqual(session.mode, .loupe)
        XCTAssertEqual(session.anchorID, order[4], "双击第五张 → 单图显示第五张")
        XCTAssertEqual(session.selection, [order[4]])
        XCTAssertNotEqual(session.anchorID, order[0], "与原来的 anchor 无关")
    }

    func testDoubleClickingAGridThumbnailOpensThatPhoto() throws {
        let (session, _) = try makeSession()
        let order = session.assets.map(\.id)
        session.selectOnly(order[0])
        let (grid, _, _) = makeViews(session: session)
        grid.onActivate = { [weak session] id in session?.activate(id) }

        let indexPath = IndexPath(item: order.count - 1, section: 0)
        guard let frame = grid.collectionView.layoutAttributesForItem(at: indexPath)?.frame else {
            return XCTFail("网格没有为最后一张排出格子")
        }
        grid.activateItem(at: NSPoint(x: frame.midX, y: frame.midY))

        XCTAssertEqual(session.mode, .loupe)
        XCTAssertEqual(session.anchorID, order[order.count - 1])
        XCTAssertEqual(session.selection, [order[order.count - 1]])
    }

    // MARK: - ⑤ switching modes is not a decode

    func testModeSwitchingDoesNotDecodeAgain() throws {
        let (session, _) = try makeSession()
        let id = session.assets[0].id
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view

        RAWDecoder.resetDecodeCounts()
        let before = RAWDecoder.decodeCounts().values.reduce(0, +)
        session.activate(id)
        session.showGrid()
        session.activate(id)
        let after = RAWDecoder.decodeCounts().values.reduce(0, +)
        XCTAssertEqual(after, before, "网格 → 单图 → 网格只切呈现，不重新解码")
    }
}
