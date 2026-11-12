import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 391 — 在**网格里双击**一张照片进单图时，胶片条与侧栏也要把那张照片滚到中间。
///
/// 用户口径只有一句：「网格双击照片进入单图界面，胶片条/侧栏需要触发照片居中功能。」
///
/// 缺口（`main@ad2ff07` 核实）：网格双击 → `AssetGridController.activateItem` → `onActivate` →
/// `WorkspaceRootView` 里只接了 `session.activate(id)`，而 `activate` 只写模型（`selectOnly` +
/// `mode = .loupe`），**没有任何滚动**。胶片条/侧栏能居中，是因为它们**自己的**双击路径先调了
/// `centreForLoupeEntry()`，和 `onActivate` 无关。
///
/// 修法：两个 `centreForLoupeEntry()` 变 `public`（方案 a），网格的 `onActivate` 在 `activate`
/// 之后补调两次。
///
/// 三条夹具事实（实测得出，不是猜的）：
///
/// 1. **网格的视图只在 `.grid` 模式下挂在 `canvasHost` 里**（`.loupe` 时被 `removeFromSuperview`），
///    所以 `indexPathForItem(at:)` 在单图里恒为 nil。取网格坐标前必须切回 `.grid`。
/// 2. `NSCollectionView.indexPathForItem(at:)` 只解析**当前可见**的那一片（实测：第 50 张的 frame 在
///    y=1208、视口只有 838 pt 时返回 nil），所以取点前先把网格滚到那一格。
/// 3. 网格的**普通**单击走 AppKit：`handleSelectionClick` 对无修饰键的按下返回 `false`（有意为之，
///    让 AppKit 接手），真正的写入发生在 `didSelectItemsAt` delegate 门。程序化
///    `selectItems(at:)` 不会调 delegate，所以单击用例把这两步都走一遍。
///
/// ⚠ 本文件**不读动画中途的 `bounds`**：`animator()` 在测试进程不落地（`CenterOnEditTests` 的 7 条
/// 恒红的根因），所以每个夹具都把 `reduceMotion` 设成 `true` —— 走 `setBoundsOrigin` 的同步分支，
/// 同一帧到位。断言的是终态偏移、`CenteredScroll.target` 的理论值与 `centerScrollCount`。
///
/// 夹具与 332/383 同构：100 张照片、真实 `CatalogSession`、真实 `WorkspaceRootView`（测的是
/// **出货版接线**，不是测试自己搭的一条回调）。
@MainActor
final class GridDoubleClickCentre391Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-391-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    private struct Library {
        let url: URL
        let ids: [String]
    }

    private func makeLibrary(count: Int = 100) throws -> Library {
        _ = NSApplication.shared
        let url = tmp.appendingPathComponent("s391-\(UUID().uuidString).photonslibrary", isDirectory: true)
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

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    /// `print` 在 `swift test` 管道里不可靠，所以每个验收数字都写 stderr（带 ACCEPT391 前缀）。
    private func note(_ line: String) {
        FileHandle.standardError.write(Data("ACCEPT391 \(line)\n".utf8))
    }

    // MARK: - the shipping workspace

    /// 真实的 `WorkspaceRootView`：网格的 `onActivate` 就是出货版接线。
    private func makeRoot(_ session: CatalogSession, mode: BrowserMode) throws -> WorkspaceRootView {
        let window = makeWindow()
        let root = WorkspaceRootView(session: session)
        root.frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window.contentView?.addSubview(root)
        root.layoutSubtreeIfNeeded()
        settle(6)
        root.setBrowserMode(mode)
        root.layoutSubtreeIfNeeded()
        settle(6)
        // 动画落地在测试进程不可靠（`animator()`）；reduce-motion 走同步分支，目标与终态不变。
        root.filmstripController.reduceMotion = { true }
        root.browserPane.reduceMotion = { true }
        return root
    }

    /// 让**两个面同时**有几何：出货配置里 `browserMode` 决定只显示其中一个（`.list` 藏胶片条、
    /// `.filmstrip` 藏照片列表）。这条只用来证明「网格那一次回调两面都调到了」。
    private func makeBothSurfacesLive(_ root: WorkspaceRootView) throws {
        root.browserPane.showsPhotoList = true
        root.browserPane.refresh()
        root.layoutSubtreeIfNeeded()
        root.browserPane.view.layoutSubtreeIfNeeded()
        settle(6)
    }

    private func stripScroll(_ root: WorkspaceRootView) throws -> NSScrollView {
        try XCTUnwrap(root.filmstripController.view as? NSScrollView)
    }

    private func paneScroll(_ root: WorkspaceRootView) throws -> NSScrollView {
        try XCTUnwrap(root.browserPane.photoListForTesting.enclosingScrollView)
    }

    private func stripOffset(_ scroll: NSScrollView) -> CGFloat { scroll.contentView.bounds.origin.x }
    private func paneOffset(_ scroll: NSScrollView) -> CGFloat { scroll.contentView.bounds.origin.y }

    private func stripTarget(_ root: WorkspaceRootView, scroll: NSScrollView, item: Int) throws -> CGFloat {
        let frame = try XCTUnwrap(root.filmstripController.collectionView
            .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame)
        let content = try XCTUnwrap(root.filmstripController.collectionView
            .collectionViewLayout?.collectionViewContentSize.width)
        return CenteredScroll.target(itemMidpoint: frame.midX,
                                     contentLength: content,
                                     visibleLength: scroll.contentView.bounds.width)
    }

    private func paneTarget(_ root: WorkspaceRootView, scroll: NSScrollView, row: Int) throws -> CGFloat {
        let table = root.browserPane.photoListForTesting
        let rect = table.rect(ofRow: row)
        guard rect.height > 0 else { throw XCTSkip("第 \(row) 行没有排出来") }
        return CenteredScroll.target(itemMidpoint: rect.midY,
                                     contentLength: table.bounds.height,
                                     visibleLength: scroll.contentView.bounds.height)
    }

    /// 把视口挪到一个**远离目标**的位置，并且不让这次移动被记成「用户正在滚」。
    private func place(_ scroll: NSScrollView, origin: NSPoint, activity: CenteredScroll.Activity) {
        activity.beginOwnChange()
        scroll.contentView.setBoundsOrigin(origin)
        settle(2)
    }

    /// 网格模式前置：网格的视图只在 `.grid` 时挂在 canvas 上（实测：单图里
    /// `indexPathForItem(at:)` 恒为 nil）。
    private func enterGrid(_ root: WorkspaceRootView) {
        if root.session.mode != .grid {
            root.session.mode = .grid
            root.layoutSubtreeIfNeeded()
            settle(4)
        }
    }

    // MARK: - the grid's click verbs

    /// 网格里第 `item` 个格子中心的**集合视图坐标**，并确认这个点真的会命中那一格
    /// （命中不了就等于什么都没测）。前置：`mode == .grid`。
    private func gridPoint(_ root: WorkspaceRootView, item: Int) throws -> NSPoint {
        XCTAssertEqual(root.session.mode, .grid,
                       "取网格坐标前必须在网格模式（单图模式下网格视图不在窗口里）")
        let path = IndexPath(item: item, section: 0)
        let grid = root.gridController
        let collection = grid.collectionView
        let frame = try XCTUnwrap(collection.layoutAttributesForItem(at: path)?.frame,
                                  "网格没有为第 \(item) 张排出格子")
        // 视口挪到那一格（`indexPathForItem(at:)` 只认可见范围）。
        let clip = grid.scrollView.contentView
        let wanted = CenteredScroll.target(itemMidpoint: frame.midY,
                                           contentLength: collection.bounds.height,
                                           visibleLength: clip.bounds.height)
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: wanted))
        root.layoutSubtreeIfNeeded()
        collection.layoutSubtreeIfNeeded()
        settle(2)
        let point = NSPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(collection.indexPathForItem(at: point), path,
                       "第 \(item) 张的格子中心应命中它自己（point \(point)，clip origin \(clip.bounds.origin)）")
        return point
    }

    /// AppKit 双击手势跑的那个动词（`handleDoubleClick` → `activateItem(at:)`），前面补上
    /// 「用户此刻在网格里」这一步。
    @discardableResult
    private func gridDoubleClick(_ root: WorkspaceRootView, item: Int) throws -> NSPoint {
        enterGrid(root)
        let point = try gridPoint(root, item: item)
        root.gridController.activateItem(at: point)
        settle(3)
        return point
    }

    /// 一次真实的网格单击：AppKit 先自己选中，再问 delegate（`didSelectItemsAt`）。
    @discardableResult
    private func gridSingleClick(_ root: WorkspaceRootView, item: Int) throws -> NSPoint {
        enterGrid(root)
        let point = try gridPoint(root, item: item)
        let path = IndexPath(item: item, section: 0)
        let collection = root.gridController.collectionView
        collection.selectionIndexPaths = [path]
        root.gridController.collectionView(collection, didSelectItemsAt: [path])
        settle(3)
        return point
    }

    // MARK: - ① 网格双击 ⇒ .loupe 且两面各 +1

    func testOne_gridDoubleClickCentresBothSurfaces() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .filmstrip)
        try makeBothSurfacesLive(root)
        let strip = try stripScroll(root)
        let pane = try paneScroll(root)
        XCTAssertGreaterThan(strip.contentView.bounds.width, 0, "胶片条应有可视宽度")
        XCTAssertGreaterThan(pane.contentView.bounds.height, 0, "侧栏照片列表应有可视高度")

        // 两个视口都远离目标，否则居中就是 no-op，测不出 +1。
        place(strip, origin: NSPoint(x: 0, y: 0), activity: root.filmstripController.scrollActivity)
        place(pane, origin: NSPoint(x: 0, y: 0), activity: root.browserPane.scrollActivity)
        let stripBefore = root.filmstripController.centerScrollCount
        let paneBefore = root.browserPane.centerScrollCount

        _ = try gridDoubleClick(root, item: 50)

        XCTAssertEqual(session.mode, .loupe, "网格双击应进单图（实际 \(session.mode)）")
        XCTAssertEqual(session.anchorID, library.ids[50], "单图显示双击的那张")
        XCTAssertEqual(root.filmstripController.centerScrollCount, stripBefore + 1,
                       "胶片条应居中一次（\(stripBefore) → \(root.filmstripController.centerScrollCount)）")
        XCTAssertEqual(root.browserPane.centerScrollCount, paneBefore + 1,
                       "侧栏应居中一次（\(paneBefore) → \(root.browserPane.centerScrollCount)）")
        let stripDelta = root.filmstripController.centerScrollCount - stripBefore
        let paneDelta = root.browserPane.centerScrollCount - paneBefore
        note("391 ① 网格双击 → mode=\(session.mode)；胶片条 count \(stripBefore) → \(root.filmstripController.centerScrollCount)（+\(stripDelta)）；侧栏 \(paneBefore) → \(root.browserPane.centerScrollCount)（+\(paneDelta)）→ 2/2")
    }

    // MARK: - ② 位置正确：偏移 == CenteredScroll.target，容差 0.5 pt

    func testTwo_theOffsetsLandOnTheCentredScrollTarget() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .filmstrip)
        try makeBothSurfacesLive(root)
        let strip = try stripScroll(root)
        let pane = try paneScroll(root)

        place(strip, origin: NSPoint(x: 0, y: 0), activity: root.filmstripController.scrollActivity)
        place(pane, origin: NSPoint(x: 0, y: 0), activity: root.browserPane.scrollActivity)
        let stripExpect = try stripTarget(root, scroll: strip, item: 50)
        let paneExpect = try paneTarget(root, scroll: pane, row: 50)
        let stripContent = try XCTUnwrap(root.filmstripController.collectionView
            .collectionViewLayout?.collectionViewContentSize.width)
        let paneContent = root.browserPane.photoListForTesting.bounds.height
        note("391 ② 几何：胶片条 可视 \(strip.contentView.bounds.width)、内容 \(stripContent)、目标 \(stripExpect)；侧栏 可视 \(pane.contentView.bounds.height)、内容 \(paneContent)、目标 \(paneExpect)")

        _ = try gridDoubleClick(root, item: 50)
        _ = library

        XCTAssertEqual(stripOffset(strip), stripExpect, accuracy: 0.5,
                       "胶片条偏移 \(stripOffset(strip)) ≠ 理论 \(stripExpect)")
        XCTAssertEqual(paneOffset(pane), paneExpect, accuracy: 0.5,
                       "侧栏偏移 \(paneOffset(pane)) ≠ 理论 \(paneExpect)")
        note("391 ② 网格双击第 50 张：胶片条 \(stripOffset(strip)) pt（理论 \(stripExpect)，差 \(abs(stripOffset(strip) - stripExpect))）；侧栏 \(paneOffset(pane)) pt（理论 \(paneExpect)，差 \(abs(paneOffset(pane) - paneExpect))）→ 2/2")
    }

    // MARK: - ③ 两端贴边：第一张 0，最后一张 content − visible

    func testThree_theEndsStayFlush() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .filmstrip)
        try makeBothSurfacesLive(root)
        let strip = try stripScroll(root)
        let pane = try paneScroll(root)
        let stripContent = try XCTUnwrap(root.filmstripController.collectionView
            .collectionViewLayout?.collectionViewContentSize.width)
        let stripVisible = strip.contentView.bounds.width
        let paneContent = root.browserPane.photoListForTesting.bounds.height
        let paneVisible = pane.contentView.bounds.height
        let last = library.ids.count - 1

        // 先把两个视口挪到中段，好让「第一张」是真的往回滚。
        place(strip, origin: NSPoint(x: stripContent / 2, y: 0), activity: root.filmstripController.scrollActivity)
        place(pane, origin: NSPoint(x: 0, y: paneContent / 2), activity: root.browserPane.scrollActivity)
        _ = try gridDoubleClick(root, item: 0)
        XCTAssertEqual(session.anchorID, library.ids[0])
        XCTAssertEqual(stripOffset(strip), 0, accuracy: 0.5, "第一张贴左：\(stripOffset(strip))")
        XCTAssertEqual(paneOffset(pane), 0, accuracy: 0.5, "第一行贴顶：\(paneOffset(pane))")
        let firstStrip = stripOffset(strip)
        let firstPane = paneOffset(pane)

        _ = try gridDoubleClick(root, item: last)
        XCTAssertEqual(session.anchorID, library.ids[last], "双击最后一格应打开最后一张")
        XCTAssertEqual(stripOffset(strip), stripContent - stripVisible, accuracy: 0.5,
                       "最后一张贴右：\(stripOffset(strip)) ≠ \(stripContent - stripVisible)")
        XCTAssertEqual(paneOffset(pane), paneContent - paneVisible, accuracy: 0.5,
                       "最后一行贴底：\(paneOffset(pane)) ≠ \(paneContent - paneVisible)")
        XCTAssertLessThanOrEqual(stripOffset(strip) + stripVisible, stripContent + 0.5, "胶片条不许滚出内容区")
        XCTAssertLessThanOrEqual(paneOffset(pane) + paneVisible, paneContent + 0.5, "侧栏不许滚出内容区")
        note("391 ③ 第 0 张：胶片条 \(firstStrip) pt / 侧栏 \(firstPane) pt（都应为 0）；第 \(last) 张：胶片条 \(stripOffset(strip)) pt（content−visible = \(stripContent - stripVisible)）、侧栏 \(paneOffset(pane)) pt（\(paneContent - paneVisible)）→ 6/6")
    }

    // MARK: - ④ 幂等：反复进单图 4 次只 +1

    func testFour_repeatingTheTriggerScrollsOnceOnly() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .filmstrip)
        try makeBothSurfacesLive(root)
        let strip = try stripScroll(root)
        let pane = try paneScroll(root)

        place(strip, origin: NSPoint(x: 0, y: 0), activity: root.filmstripController.scrollActivity)
        place(pane, origin: NSPoint(x: 0, y: 0), activity: root.browserPane.scrollActivity)
        let stripBefore = root.filmstripController.centerScrollCount
        let paneBefore = root.browserPane.centerScrollCount

        let point = try gridDoubleClick(root, item: 60)
        XCTAssertEqual(root.filmstripController.centerScrollCount, stripBefore + 1)
        XCTAssertEqual(root.browserPane.centerScrollCount, paneBefore + 1)
        let stripOnce = stripOffset(strip)
        let paneOnce = paneOffset(pane)

        // 用户回网格、再双击同一张 —— 三次（AppKit 每一下都是同一个动词）。
        for round in 1...3 {
            enterGrid(root)
            root.gridController.activateItem(at: point)   // 网格坐标不变，仍是那一格
            settle(3)
            XCTAssertEqual(session.mode, .loupe, "第 \(round) 次重复也应进单图")
            XCTAssertEqual(root.filmstripController.centerScrollCount, stripBefore + 1,
                           "第 \(round) 次重复：已居中还滚了（胶片条 \(stripBefore) → \(root.filmstripController.centerScrollCount)）")
            XCTAssertEqual(root.browserPane.centerScrollCount, paneBefore + 1,
                           "第 \(round) 次重复：已居中还滚了（侧栏 \(paneBefore) → \(root.browserPane.centerScrollCount)）")
            XCTAssertEqual(stripOffset(strip), stripOnce, accuracy: 0.001, "第 \(round) 次重复：胶片条偏移不许动")
            XCTAssertEqual(paneOffset(pane), paneOnce, accuracy: 0.001, "第 \(round) 次重复：侧栏偏移不许动")
        }
        note("391 ④ 同一张共进单图 4 次：胶片条 \(stripBefore) → \(root.filmstripController.centerScrollCount)（+1）、侧栏 \(paneBefore) → \(root.browserPane.centerScrollCount)（+1）；偏移始终 \(stripOnce) / \(paneOnce) → 8/8")
    }

    // MARK: - ⑤ 不回归单击：网格单击不居中、不进单图

    func testFive_aGridSingleClickCentresNothing() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .filmstrip)
        try makeBothSurfacesLive(root)
        let strip = try stripScroll(root)
        let pane = try paneScroll(root)

        var stripDelta = 0
        var paneDelta = 0
        for item in [10, 50, 90] {
            // 视口故意偏离 300 pt：单击要是又被接上居中，这里必然 +1。
            let stripItemTarget = try stripTarget(root, scroll: strip, item: item)
            place(strip, origin: NSPoint(x: max(0, stripItemTarget - 300), y: 0),
                  activity: root.filmstripController.scrollActivity)
            let paneItemTarget = try paneTarget(root, scroll: pane, row: item)
            place(pane, origin: NSPoint(x: 0, y: max(0, paneItemTarget - 300)),
                  activity: root.browserPane.scrollActivity)
            let stripBefore = root.filmstripController.centerScrollCount
            let paneBefore = root.browserPane.centerScrollCount
            _ = try gridSingleClick(root, item: item)
            XCTAssertEqual(session.selection, [library.ids[item]], "第 \(item) 张：单击后 selection 应只有它")
            XCTAssertEqual(session.anchorID, library.ids[item], "第 \(item) 张：anchor 应跟着走")
            XCTAssertEqual(session.mode, .grid, "第 \(item) 张：单击 **不** 进单图（实际 \(session.mode)）")
            stripDelta += root.filmstripController.centerScrollCount - stripBefore
            paneDelta += root.browserPane.centerScrollCount - paneBefore
        }
        XCTAssertEqual(stripDelta, 0, "胶片条 3 次单击的增量应为 0，实际 \(stripDelta)")
        XCTAssertEqual(paneDelta, 0, "侧栏 3 次单击的增量应为 0，实际 \(paneDelta)")
        note("391 ⑤ 网格单击 3 次：mode=\(session.mode)，胶片条增量 \(stripDelta)（合计 \(root.filmstripController.centerScrollCount)）、侧栏增量 \(paneDelta)（合计 \(root.browserPane.centerScrollCount)）→ 6/6")
    }

    // MARK: - ⑥ 胶片条 / 侧栏自己的双击仍然只 +1（不是 +2）

    func testSix_eachSurfacesOwnDoubleClickStillScrollsOnce() throws {
        let library = try makeLibrary()

        // (a) 胶片条自己的双击：`activateItem` → 它自己的 `centreForLoupeEntry()` + `onActivate`。
        //     先把第 70 张摆进视口并偏离目标 300 pt，让居中真的滚一下。
        do {
            let session = try makeSession(library)
            let root = try makeRoot(session, mode: .filmstrip)
            let strip = try stripScroll(root)
            let frames = root.filmstripController.laidOutItemFrames
            XCTAssertEqual(frames.count, library.ids.count, "胶片条为每张照片排了一个格子")
            let target = try stripTarget(root, scroll: strip, item: 70)
            place(strip, origin: NSPoint(x: max(0, target - 300), y: 0),
                  activity: root.filmstripController.scrollActivity)
            let point = NSPoint(x: frames[70].midX, y: frames[70].midY)
            XCTAssertEqual(root.filmstripController.collectionView.indexPathForItem(at: point),
                           IndexPath(item: 70, section: 0), "第 70 格应可命中（point \(point)）")
            let before = root.filmstripController.centerScrollCount
            let paneBefore = root.browserPane.centerScrollCount

            root.filmstripController.activateItem(at: point)
            settle(3)
            XCTAssertEqual(session.mode, .loupe)
            XCTAssertEqual(session.anchorID, library.ids[70])
            XCTAssertEqual(root.filmstripController.centerScrollCount, before + 1,
                           "胶片条自己双击只该滚一次（\(before) → \(root.filmstripController.centerScrollCount)）")
            pump(0.5)
            XCTAssertEqual(root.filmstripController.centerScrollCount, before + 1, "窗口过后不许再来第二次")
            XCTAssertEqual(root.browserPane.centerScrollCount, paneBefore,
                           "胶片条自己的双击不该动侧栏（\(paneBefore) → \(root.browserPane.centerScrollCount)）")
            note("391 ⑥a 胶片条自己双击第 70 张：胶片条 \(before) → \(root.filmstripController.centerScrollCount)（+1，不是 +2）；侧栏 \(paneBefore) → \(root.browserPane.centerScrollCount)（+0）")
        }

        // (b) 侧栏自己的双击（`photosTable.doubleAction` 接的就是 `openRowInLoupe`）。
        do {
            let session = try makeSession(library)
            let root = try makeRoot(session, mode: .list)
            let pane = try paneScroll(root)
            let target = try paneTarget(root, scroll: pane, row: 70)
            place(pane, origin: NSPoint(x: 0, y: max(0, target - 300)),
                  activity: root.browserPane.scrollActivity)
            let before = root.browserPane.centerScrollCount
            let stripBefore = root.filmstripController.centerScrollCount
            XCTAssertTrue(root.browserPane.openRowInLoupe(70, assetID: library.ids[70]),
                          "侧栏双击的动词应能打开这一行")
            settle(3)
            XCTAssertEqual(session.mode, .loupe)
            XCTAssertEqual(root.browserPane.centerScrollCount, before + 1,
                           "侧栏自己双击只该滚一次（\(before) → \(root.browserPane.centerScrollCount)）")
            pump(0.5)
            XCTAssertEqual(root.browserPane.centerScrollCount, before + 1, "窗口过后不许再来第二次")
            let stripDelta = root.filmstripController.centerScrollCount - stripBefore
            XCTAssertEqual(stripDelta, 0, "侧栏自己的双击不该动胶片条（实际 +\(stripDelta)）")
            note("391 ⑥b 侧栏自己双击第 70 行：侧栏 \(before) → \(root.browserPane.centerScrollCount)（+1，不是 +2）；胶片条 +\(stripDelta)（+0）")
        }
    }

    // MARK: - ⑦ 幂等的逐条实测：同一入口同帧调两次 → 只 +1

    /// 本单之后，同一次进单图可能被调两次（一面自己的路径 + 网格回调补的那次）。这条量的是
    /// **调一次 vs 同帧调两次** 的差别：必须是 0 —— 否则用户双击胶片条会看到条带抖一下。
    func testSeven_callingTheEntryTwiceInOneTurnScrollsOnce() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .filmstrip)
        let strip = try stripScroll(root)
        let filmstrip = root.filmstripController

        session.selectOnly(library.ids[50])
        settle(2)
        let target = try stripTarget(root, scroll: strip, item: 50)

        // 单次
        place(strip, origin: NSPoint(x: 0, y: 0), activity: filmstrip.scrollActivity)
        var count = filmstrip.centerScrollCount
        filmstrip.centreForLoupeEntry()
        settle(2)
        let onceDelta = filmstrip.centerScrollCount - count
        let onceOffset = stripOffset(strip)
        XCTAssertEqual(onceDelta, 1, "单次调用应滚一次（实际 +\(onceDelta)）")
        XCTAssertEqual(onceOffset, target, accuracy: 0.5)

        // 同一帧连调两次 —— 这正是「原来那条路径 + 新加的网格回调」的形状
        place(strip, origin: NSPoint(x: 0, y: 0), activity: filmstrip.scrollActivity)
        count = filmstrip.centerScrollCount
        filmstrip.centreForLoupeEntry()
        filmstrip.centreForLoupeEntry()
        settle(2)
        let twiceDelta = filmstrip.centerScrollCount - count
        let twiceOffset = stripOffset(strip)
        XCTAssertEqual(twiceDelta, 1, "连调两次也应只滚一次（实际 +\(twiceDelta)）")
        XCTAssertEqual(twiceOffset, target, accuracy: 0.5)

        // 第三次（用户再点一次同一张）→ 0
        count = filmstrip.centerScrollCount
        filmstrip.centreForLoupeEntry()
        XCTAssertEqual(filmstrip.centerScrollCount, count, "已居中再调一次必须 0")

        // 侧栏同样的量（需要照片列表有行：`.filmstrip` 模式下它没有行，这里把它打开）。
        let pane = try paneScroll(root)
        root.browserPane.showsPhotoList = true
        root.browserPane.refresh()
        root.browserPane.view.layoutSubtreeIfNeeded()
        settle(4)
        let paneTargetValue = try paneTarget(root, scroll: pane, row: 50)
        place(pane, origin: NSPoint(x: 0, y: 0), activity: root.browserPane.scrollActivity)
        var paneCount = root.browserPane.centerScrollCount
        root.browserPane.centreForLoupeEntry()
        root.browserPane.centreForLoupeEntry()
        settle(2)
        let paneDelta = root.browserPane.centerScrollCount - paneCount
        XCTAssertEqual(paneDelta, 1, "侧栏连调两次也应只滚一次（实际 +\(paneDelta)）")
        XCTAssertEqual(paneOffset(pane), paneTargetValue, accuracy: 0.5)
        paneCount = root.browserPane.centerScrollCount
        root.browserPane.centreForLoupeEntry()
        XCTAssertEqual(root.browserPane.centerScrollCount, paneCount, "侧栏已居中再调一次必须 0")

        note("391 ⑦ 胶片条：单次 +\(onceDelta)（偏移 \(onceOffset) pt，目标 \(target)）；同帧连调两次 +\(twiceDelta)（偏移 \(twiceOffset) pt）；第三次 +0 → 幂等成立。侧栏：连调两次 +\(paneDelta)（偏移 \(paneOffset(pane)) pt，目标 \(paneTargetValue)），第三次 +0")
    }

    // MARK: - ⑧ 出货配置：每种模式下网格双击都让**在屏上的那一面**居中

    func testEight_gridDoubleClickCentresTheSurfaceShownInEachMode() throws {
        let library = try makeLibrary()

        // 列表模式：屏上是侧栏的照片列表。
        let listSession = try makeSession(library)
        let listRoot = try makeRoot(listSession, mode: .list)
        let pane = try paneScroll(listRoot)
        XCTAssertGreaterThan(pane.contentView.bounds.height, 0)
        place(pane, origin: NSPoint(x: 0, y: 0), activity: listRoot.browserPane.scrollActivity)
        let paneBefore = listRoot.browserPane.centerScrollCount
        let stripBefore = listRoot.filmstripController.centerScrollCount
        _ = try gridDoubleClick(listRoot, item: 40)
        XCTAssertEqual(listSession.mode, .loupe)
        XCTAssertEqual(listSession.anchorID, library.ids[40])
        XCTAssertEqual(listRoot.browserPane.centerScrollCount, paneBefore + 1,
                       "列表模式下侧栏应滚一次（\(paneBefore) → \(listRoot.browserPane.centerScrollCount)）")
        let paneExpect = try paneTarget(listRoot, scroll: pane, row: 40)
        XCTAssertEqual(paneOffset(pane), paneExpect, accuracy: 0.5,
                       "列表模式侧栏偏移 \(paneOffset(pane)) ≠ 理论 \(paneExpect)")
        let hiddenStripDelta = listRoot.filmstripController.centerScrollCount - stripBefore
        XCTAssertLessThanOrEqual(hiddenStripDelta, 1, "藏起来的胶片条顶多滚一次（实际 +\(hiddenStripDelta)）")
        note("391 ⑧a 列表模式：侧栏 \(paneBefore) → \(listRoot.browserPane.centerScrollCount)（+1），偏移 \(paneOffset(pane)) pt（目标 \(paneExpect)）；藏着的胶片条 +\(hiddenStripDelta)")

        // 胶片条模式：屏上是胶片条，侧栏照片列表没有行（`showsPhotoList == false`）。
        let stripSession = try makeSession(library)
        let stripRoot = try makeRoot(stripSession, mode: .filmstrip)
        let strip = try stripScroll(stripRoot)
        XCTAssertGreaterThan(strip.contentView.bounds.width, 0)
        XCTAssertEqual(stripRoot.browserPane.photoListForTesting.numberOfRows, 0,
                       "胶片条模式下侧栏没有照片行（precondition）")
        place(strip, origin: NSPoint(x: 0, y: 0), activity: stripRoot.filmstripController.scrollActivity)
        let stripCountBefore = stripRoot.filmstripController.centerScrollCount
        let paneCountBefore = stripRoot.browserPane.centerScrollCount
        _ = try gridDoubleClick(stripRoot, item: 40)
        XCTAssertEqual(stripSession.mode, .loupe)
        XCTAssertEqual(stripSession.anchorID, library.ids[40])
        XCTAssertEqual(stripRoot.filmstripController.centerScrollCount, stripCountBefore + 1,
                       "胶片条模式下胶片条应滚一次（\(stripCountBefore) → \(stripRoot.filmstripController.centerScrollCount)）")
        XCTAssertEqual(stripRoot.browserPane.centerScrollCount, paneCountBefore,
                       "侧栏没有行时 `centerAnchor()` 返回 false（\(paneCountBefore) → \(stripRoot.browserPane.centerScrollCount)）")
        let expect = try stripTarget(stripRoot, scroll: strip, item: 40)
        XCTAssertEqual(stripOffset(strip), expect, accuracy: 0.5)
        note("391 ⑧b 胶片条模式：胶片条 \(stripCountBefore) → \(stripRoot.filmstripController.centerScrollCount)（+1），偏移 \(stripOffset(strip)) pt（目标 \(expect)）；侧栏 \(paneCountBefore) → \(stripRoot.browserPane.centerScrollCount)（无行，+0）")
    }
}
