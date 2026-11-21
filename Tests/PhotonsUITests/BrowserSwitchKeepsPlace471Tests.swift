import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 471 — 侧栏 ↔ 胶片条互相切换时**保留所在位置**（用户 2026-11-21）。
///
/// 口径（§5，覆盖最初的「画布相机重居中」）：
///
/// - **网格**（`session.mode != .loupe`）：切换后新出现的那一面滚到**当前锚点**附近即可，
///   不要求居中（`scrollRowToVisible` / `scrollToItems(.nearest*)`）；
/// - **单图**（`.loupe`）：锚点那张在侧栏 / 胶片条里**居中**（既有的 `centreForLoupeEntry()`，
///   ≤ 2 pt 幂等）。
///
/// 两条都只由**模式切换**触发，不接选择变化 —— 383 的「单击只选中、不居中」仍是硬边界。
/// 相机、缩放、`recentreOnPicture()` 全都不在本次改动里。
///
/// 夹具与 332/383/391 同构：100 张照片、真实 `CatalogSession`、真实 `WorkspaceRootView`
/// （测的是出货版 `setBrowserMode` 接线，不是测试自己搭的一条回调）。
///
/// ⚠ `animator()` 在测试进程不落地（`CenterOnEditTests` 那 7 条既有红），所以 `reduceMotion`
/// 一律设 `true`：居中走 `setBoundsOrigin` 的同步分支，同一拍到位。
@MainActor
final class BrowserSwitchKeepsPlace471Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []
    private var savedBrowserMode: Any?

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-471-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // `setBrowserMode` persists the mode in the user's defaults; a test must not leave the app
        // opening in whichever mode it switched to.
        savedBrowserMode = UserDefaults.standard.object(forKey: "photons.browserMode")
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let value = savedBrowserMode {
            UserDefaults.standard.set(value, forKey: "photons.browserMode")
        } else {
            UserDefaults.standard.removeObject(forKey: "photons.browserMode")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    private struct Library {
        let url: URL
        let ids: [String]
    }

    private func makeLibrary(count: Int = 100) throws -> Library {
        _ = NSApplication.shared
        let url = tmp.appendingPathComponent("s471-\(UUID().uuidString).photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: url)
        let src = tmp.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        var ids: [String] = []
        for index in 0..<count {
            let name = String(format: "IMG_%04d.dng", index)
            let file = src.appendingPathComponent(name)
            // 一个占位字节：行存在，解码立刻失败 —— 本条测的是滚动，不是像素。
            try Data([0x00]).write(to: file)
            let asset = Asset(sourceRootId: root.id,
                              relPath: name,
                              filename: name,
                              ext: "dng",
                              kind: .raw,
                              size: 1,
                              mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 9520,
                              height: 6336,
                              cameraModel: "LEICA SL3",
                              cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            ids.append(asset.id)
        }
        return Library(url: url, ids: ids)
    }

    private func makeSession(_ library: Library) throws -> CatalogSession {
        let session = CatalogSession()
        try session.open(library.url)
        return session
    }

    private func makeWindow(_ size: CGSize = CGSize(width: 1600, height: 1000)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        windows.append(window)
        return window
    }

    // MARK: - time

    private func settle(_ turns: Int = 6) {
        for _ in 0..<turns { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// `print` 在 `swift test` 管道里不可靠，所以每个验收数字都写 stderr（带 ACCEPT471 前缀）。
    private func note(_ line: String) {
        FileHandle.standardError.write(Data("ACCEPT471 \(line)\n".utf8))
    }

    // MARK: - the shipping workspace

    /// 真实的 `WorkspaceRootView`：`setBrowserMode` 就是出货版入口。
    private func makeRoot(_ session: CatalogSession, mode: BrowserMode) throws -> WorkspaceRootView {
        let window = makeWindow()
        let root = WorkspaceRootView(session: session)
        // reduce-motion 在第一次布局之前装好：启动那一次 reveal 也不许走动画。
        root.filmstripController.reduceMotion = { true }
        root.browserPane.reduceMotion = { true }
        root.frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window.contentView?.addSubview(root)
        root.layoutSubtreeIfNeeded()
        settle(6)
        root.setBrowserMode(mode)
        root.layoutSubtreeIfNeeded()
        settle(6)
        return root
    }

    // MARK: - geometry

    private func stripScroll(_ root: WorkspaceRootView) throws -> NSScrollView {
        try XCTUnwrap(root.filmstripController.view as? NSScrollView)
    }

    private func paneScroll(_ root: WorkspaceRootView) throws -> NSScrollView {
        try XCTUnwrap(root.browserPane.photoListForTesting.enclosingScrollView)
    }

    private func paneRowRect(_ root: WorkspaceRootView, row: Int) -> NSRect {
        root.browserPane.photoListForTesting.rect(ofRow: row)
    }

    private func stripItemRect(_ root: WorkspaceRootView, item: Int) throws -> NSRect {
        try XCTUnwrap(root.filmstripController.collectionView
            .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame)
    }

    /// Put a viewport somewhere by hand, without letting the move be recorded as the user scrolling
    /// (which would make the centred entry stand down).
    private func place(_ scroll: NSScrollView, origin: NSPoint,
                       activity: CenteredScroll.Activity) {
        activity.beginOwnChange()
        scroll.contentView.setBoundsOrigin(origin)
        settle(2)
    }

    // MARK: - ① 网格：胶片条 → 侧栏，目标面落在锚点

    func testOne_gridFilmstripToListRevealsTheAnchor() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .filmstrip)
        let anchor = 20
        let id = library.ids[anchor]

        session.selectOnly(id)
        settle(3)
        XCTAssertEqual(session.anchorID, id)
        XCTAssertEqual(session.mode, .grid, "precondition：网格界面")

        // 源面（胶片条）就是用户此刻看的那一面：让它在锚点上。
        root.filmstripController.revealAnchor()
        root.filmstripController.view.layoutSubtreeIfNeeded()
        settle(3)
        let strip = try stripScroll(root)
        let stripItem = try stripItemRect(root, item: anchor)
        XCTAssertTrue(strip.documentVisibleRect.intersects(stripItem),
                      "precondition：源面（胶片条）应能看到第 \(anchor) 张")

        // 目标面（侧栏）停在开头 —— 正是切换后「从头开始」的那个旧状态。
        XCTAssertEqual(root.browserPane.photoListForTesting.numberOfRows, 0,
                       "precondition：胶片条模式下侧栏没有照片行")
        let pane = try paneScroll(root)

        root.setBrowserMode(.list)
        root.layoutSubtreeIfNeeded()
        settle(4)

        XCTAssertEqual(root.browserPane.photoListForTesting.numberOfRows, library.ids.count,
                       "侧栏应重新有全部照片行")
        let rowRect = paneRowRect(root, row: anchor)
        XCTAssertGreaterThan(rowRect.height, 0, "第 \(anchor) 行应有几何")
        let paneVisible = pane.documentVisibleRect
        let stripVisible = strip.documentVisibleRect
        XCTAssertTrue(paneVisible.intersects(rowRect),
                      "网格切换后侧栏应能看到锚点：visible \(paneVisible) vs row \(rowRect)")
        XCTAssertTrue(stripVisible.intersects(stripItem),
                      "源面（胶片条）仍应包含锚点：visible \(stripVisible) vs item \(stripItem)")
        note("471 ① 网格 胶片条→侧栏：第 \(anchor) 行可见（visible \(paneVisible)，row \(rowRect)）；胶片条仍可见该格（\(stripVisible) vs \(stripItem)）→ 4/4")
    }

    // MARK: - ② 网格：侧栏 → 胶片条，反向同形

    func testTwo_gridListToFilmstripRevealsTheAnchor() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .list)
        let anchor = 20
        let id = library.ids[anchor]

        session.selectOnly(id)
        settle(3)
        XCTAssertEqual(session.anchorID, id)
        XCTAssertEqual(session.mode, .grid, "precondition：网格界面")

        // 源面（侧栏）在锚点上。
        root.browserPane.revealAnchor()
        root.browserPane.view.layoutSubtreeIfNeeded()
        settle(3)
        let pane = try paneScroll(root)
        let rowRect = paneRowRect(root, row: anchor)
        XCTAssertTrue(pane.documentVisibleRect.intersects(rowRect),
                      "precondition：源面（侧栏）应能看到第 \(anchor) 行")

        // 目标面（胶片条）停在开头。
        let strip = try stripScroll(root)
        place(strip, origin: .zero, activity: root.filmstripController.scrollActivity)

        root.setBrowserMode(.filmstrip)
        root.layoutSubtreeIfNeeded()
        settle(4)

        let stripVisible = strip.documentVisibleRect
        let itemAfter = try stripItemRect(root, item: anchor)
        XCTAssertTrue(stripVisible.intersects(itemAfter),
                      "网格切换后胶片条应能看到锚点：visible \(stripVisible) vs item \(itemAfter)")
        // 胶片条模式下侧栏的照片列表是**隐藏且零行**的（AppKit 会把偏移夹回 0），所以这一面
        // 不作为「可见区间」参与断言；切回侧栏时由它自己的 reveal 重新落到锚点（①）。
        XCTAssertEqual(root.browserPane.photoListForTesting.numberOfRows, 0,
                       "胶片条模式下侧栏照片列表没有行（隐藏面，不参与可见性）")
        note("471 ② 网格 侧栏→胶片条：第 \(anchor) 格可见（visible \(stripVisible)，item \(itemAfter)）→ 3/3")
    }

    // MARK: - ③ 单图：胶片条 → 侧栏，锚点居中

    func testThree_loupeFilmstripToListCentresTheAnchor() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .filmstrip)
        let anchor = 20
        let id = library.ids[anchor]

        session.selectOnly(id)
        session.mode = .loupe
        root.layoutSubtreeIfNeeded()
        settle(4)
        XCTAssertEqual(session.mode, .loupe, "precondition：单图界面")

        let pane = try paneScroll(root)
        root.setBrowserMode(.list)
        root.layoutSubtreeIfNeeded()
        settle(4)

        let rowRect = paneRowRect(root, row: anchor)
        let visible = pane.documentVisibleRect
        XCTAssertEqual(rowRect.midY, visible.midY, accuracy: 2,
                       "单图切换后侧栏应把锚点居中：row mid \(rowRect.midY)，viewport mid \(visible.midY)")
        note("471 ③ 单图 胶片条→侧栏：第 \(anchor) 行中点 \(rowRect.midY)，视口中点 \(visible.midY)，差 \(abs(rowRect.midY - visible.midY)) pt → ≤2 pt")
    }

    // MARK: - ④ 单图：侧栏 → 胶片条，锚点居中

    func testFour_loupeListToFilmstripCentresTheAnchor() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .list)
        let anchor = 20
        let id = library.ids[anchor]

        session.selectOnly(id)
        session.mode = .loupe
        root.layoutSubtreeIfNeeded()
        settle(4)
        XCTAssertEqual(session.mode, .loupe, "precondition：单图界面")

        let strip = try stripScroll(root)
        place(strip, origin: .zero, activity: root.filmstripController.scrollActivity)

        root.setBrowserMode(.filmstrip)
        root.layoutSubtreeIfNeeded()
        settle(4)

        let itemRect = try stripItemRect(root, item: anchor)
        let visible = strip.documentVisibleRect
        XCTAssertEqual(itemRect.midX, visible.midX, accuracy: 2,
                       "单图切换后胶片条应把锚点居中：item mid \(itemRect.midX)，viewport mid \(visible.midX)")
        note("471 ④ 单图 侧栏→胶片条：第 \(anchor) 格中点 \(itemRect.midX)，视口中点 \(visible.midX)，差 \(abs(itemRect.midX - visible.midX)) pt → ≤2 pt")
    }

    // MARK: - ⑤ 幂等：再来回切一次，视口不再动

    func testFive_switchingBackAndForthAgainDoesNotMoveTheViewports() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .filmstrip)
        let anchor = 20

        session.selectOnly(library.ids[anchor])
        settle(3)
        root.filmstripController.revealAnchor()
        settle(2)

        root.setBrowserMode(.list)
        root.layoutSubtreeIfNeeded()
        settle(4)
        let pane = try paneScroll(root)
        let strip = try stripScroll(root)
        let paneOnce = pane.contentView.bounds.origin
        let stripOnce = strip.contentView.bounds.origin

        // 第二次、第三次切换：目标面已经含着锚点，reveal 必须是 no-op。
        for round in 1...2 {
            root.setBrowserMode(.filmstrip)
            root.layoutSubtreeIfNeeded()
            settle(4)
            XCTAssertEqual(strip.contentView.bounds.origin, stripOnce,
                           "第 \(round) 次回切：胶片条视口不许再动")
            root.setBrowserMode(.list)
            root.layoutSubtreeIfNeeded()
            settle(4)
            XCTAssertEqual(pane.contentView.bounds.origin, paneOnce,
                           "第 \(round) 次再切：侧栏视口不许再动")
        }
        note("471 ⑤ 网格来回切 2 轮：侧栏 \(paneOnce) / 胶片条 \(stripOnce) 始终不变 → 4/4")
    }

    // MARK: - ⑥ 幂等（单图）：居中是 ≤2 pt 的 no-op

    /// 胶片条在 `.list` 下虽然隐藏，但条目与偏移都还在（与侧栏照片列表不同：后者在
    /// `.filmstrip` 下 `numberOfRows == 0`）。所以「已居中再切回来」的 no-op 用它来量。
    func testSix_loupeSecondSwitchDoesNotScrollTheStripAgain() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .list)
        let anchor = 20

        session.selectOnly(library.ids[anchor])
        session.mode = .loupe
        settle(3)

        root.setBrowserMode(.filmstrip)
        root.layoutSubtreeIfNeeded()
        settle(4)
        let strip = try stripScroll(root)
        let itemRect = try stripItemRect(root, item: anchor)
        XCTAssertEqual(itemRect.midX, strip.documentVisibleRect.midX, accuracy: 2,
                       "第一次切入胶片条应把锚点居中")
        let stripOnce = strip.contentView.bounds.origin
        let stripCount = root.filmstripController.centerScrollCount

        // 去侧栏再回来：胶片条已经居中，第二次 `centreForLoupeEntry()` 必须是 no-op。
        root.setBrowserMode(.list)
        root.layoutSubtreeIfNeeded()
        settle(4)
        root.setBrowserMode(.filmstrip)
        root.layoutSubtreeIfNeeded()
        settle(4)

        XCTAssertEqual(strip.contentView.bounds.origin, stripOnce,
                       "单图已居中后再切回来：胶片条视口不许再动")
        XCTAssertEqual(root.filmstripController.centerScrollCount, stripCount,
                       "单图已居中后再切回来：不应再滚（\(stripCount) → \(root.filmstripController.centerScrollCount)）")
        note("471 ⑥ 单图 胶片条已居中后再切两轮：胶片条原点 \(stripOnce) 不变，centerScrollCount \(stripCount) 不变 → 2/2")
    }
}
