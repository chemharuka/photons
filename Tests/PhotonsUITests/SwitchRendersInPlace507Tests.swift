import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
import PhotonsLocalization
@testable import PhotonsUI

/// 507 — 切图之后三个面（网格 / 侧栏 / 胶片条）**直接渲染在应该在的位置**，不再「先切换再滚动」。
///
/// 同一把尺子量三个面，每个面三个读数点：
///
///  · `immediate` — 切换入口返回后的那一瞬，**连布局都不催**；
///  · `afterLayout` — 只让这一 turn 自己的布局跑完（不 spin runloop）；
///  · `expected` — 同一次切换完整 settle 之后它自己停下的位置（**实测**，不抄实现的算术）。
///
/// 另有 `layouts`（该面自己跑的 `layout()` 次数，正是创建可见 cell 的那一趟）与
/// `requests`（切换这一 turn 内 `ThumbnailProvider` 收到的请求及优先级）。
///
/// 反向门（§3.5）：网格换回 `scrollToItems`、侧栏换回 `scrollRowToVisible`、切图时清空可见集，
/// 各自必红。
@MainActor
final class SwitchRendersInPlace507Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []
    private var savedBrowserMode: Any?
    private static let photoCount = 500
    private static let anchorIndex = 400
    private static let startIndex = 5

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-507-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        savedBrowserMode = AppPreferences.store.object(forKey: "photons.browserMode")
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let value = savedBrowserMode {
            AppPreferences.store.set(value, forKey: "photons.browserMode")
        } else {
            AppPreferences.store.removeObject(forKey: "photons.browserMode")
        }
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    private struct Library {
        let url: URL
        let ids: [String]
    }

    private func makeLibrary(count: Int = SwitchRendersInPlace507Tests.photoCount) throws -> Library {
        let url = tmp.appendingPathComponent("s507-\(UUID().uuidString).photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: url)
        let src = tmp.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        var ids: [String] = []
        for index in 0..<count {
            let name = String(format: "IMG_%04d.dng", index)
            let file = src.appendingPathComponent(name)
            // 一个占位字节：行存在、解码立刻失败 —— 本条测的是位置与请求，不是像素。
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

    /// 一个 runloop turn：让 `DispatchQueue.main.async` 的观察桥落地。
    private func oneTurn() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }

    /// 每个验收数字都写 stderr（`print` 在 `swift test` 管道里不可靠）。
    private func note(_ line: String) {
        FileHandle.standardError.write(Data("ACCEPT507 \(line)\n".utf8))
    }

    // MARK: - the shipping workspace

    private func makeRoot(_ session: CatalogSession, mode: BrowserMode) throws -> WorkspaceRootView {
        let window = makeWindow()
        let root = WorkspaceRootView(session: session)
        // reduce-motion 装在第一趟布局之前：切换 reveal 也不许走动画。
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

    private func paneScroll(_ root: WorkspaceRootView) throws -> NSScrollView {
        try XCTUnwrap(root.browserPane.photoListForTesting.enclosingScrollView)
    }
    private func stripScroll(_ root: WorkspaceRootView) throws -> NSScrollView {
        try XCTUnwrap(root.filmstripController.view as? NSScrollView)
    }

    /// Put a viewport somewhere by hand without it counting as the user's scroll.
    private func place(_ scroll: NSScrollView, origin: NSPoint,
                       activity: CenteredScroll.Activity? = nil) {
        activity?.beginOwnChange()
        scroll.contentView.setBoundsOrigin(origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        settle(2)
    }

    // MARK: - one reading

    private struct Sample {
        var origin: CGPoint
        var visible: [Int]
        var layouts: Int
    }

    private struct Reading {
        var surface: String
        var immediate: Sample
        var afterLayout: Sample
        var expected: CGPoint
        var expectedBand: Set<Int>
        var requests: [(index: Int, priority: ThumbPriority)]
        var visibleCount: Int
        var turnsToCorrect: Int

        var originMiss: CGFloat {
            abs(afterLayout.origin.x - expected.x) + abs(afterLayout.origin.y - expected.y)
        }
        var immediateMiss: CGFloat {
            abs(immediate.origin.x - expected.x) + abs(immediate.origin.y - expected.y)
        }
    }

    private func fmt(_ p: CGPoint) -> String { String(format: "(%.1f, %.1f)", p.x, p.y) }

    private func describe(_ r: Reading) {
        note("\(r.surface)：切换返回时 origin \(fmt(r.immediate.origin))（差 "
             + String(format: "%.2f", r.immediateMiss) + " pt），本 turn 布局后 \(fmt(r.afterLayout.origin))"
             + "（差 \(String(format: "%.2f", r.originMiss)) pt，期望 \(fmt(r.expected))）；"
             + "可见 \(r.afterLayout.visible.count) 格（锚点在：\(r.afterLayout.visible.contains(Self.anchorIndex))）；"
             + "layout 立即 \(r.immediate.layouts) / 布局后 \(r.afterLayout.layouts) 次；"
             + "到可见集正确还等 \(r.turnsToCorrect) 个 runloop；"
             + "本 turn 请求 \(r.requests.count) 个（onScreen \(r.requests.filter { $0.priority == .onScreen }.count)，"
             + "可见格 \(r.visibleCount)）")
    }

    // MARK: - 网格

    private func gridVisible(_ root: WorkspaceRootView) -> [Int] {
        root.gridController.collectionView.indexPathsForVisibleItems().map(\.item).sorted()
    }

    private func gridBand(_ root: WorkspaceRootView, originY: CGFloat) -> Set<Int> {
        let m = root.gridController.metrics
        let visible = root.gridController.scrollView.contentView.bounds.height
        guard m.rowHeight > 0, visible > 0 else { return [] }
        let first = max(0, Int(floor((originY - m.inset) / m.rowHeight)) - 1)
        let last = Int(floor((originY + visible - m.inset) / m.rowHeight)) + 1
        return Set((first...max(first, last)).flatMap { row in (0..<m.columns).map { row * m.columns + $0 } })
    }

    /// 网格切换入口 = 单图 → 网格（`showModule(for: .grid)` → `applyPendingGridEntry`）。
    private func gridReading(_ root: WorkspaceRootView, library: Library,
                             replay expected: CGPoint?) -> Reading {
        let scroll = root.gridController.scrollView
        root.session.mode = .loupe
        root.showModule(for: .loupe)
        settle(2)
        place(scroll, origin: .zero)
        root.session.selectOnly(library.ids[Self.anchorIndex])
        settle(2)
        XCTAssertEqual(root.session.mode, .loupe, "precondition：网格已换出")

        let logBefore = root.gridController.requestLog.count
        let layoutsBefore = root.gridController.collectionView.layoutPassCount
        root.session.mode = .grid
        root.showModule(for: .grid)                        // ← 切图入口

        let immediate = Sample(origin: scroll.contentView.bounds.origin,
                               visible: gridVisible(root),
                               layouts: root.gridController.collectionView.layoutPassCount - layoutsBefore)

        if expected == nil {
            settle(10)
            let o = scroll.contentView.bounds.origin
            return Reading(surface: "网格", immediate: immediate,
                           afterLayout: Sample(origin: o, visible: gridVisible(root), layouts: 0),
                           expected: o, expectedBand: gridBand(root, originY: o.y),
                           requests: [], visibleCount: 0, turnsToCorrect: 0)
        }
        root.layoutSubtreeIfNeeded()
        let afterLayout = Sample(origin: scroll.contentView.bounds.origin,
                                 visible: gridVisible(root),
                                 layouts: root.gridController.collectionView.layoutPassCount - layoutsBefore)
        let requests = Array(root.gridController.requestLog[logBefore...])
        var turns = 0
        while !gridVisible(root).contains(Self.anchorIndex), turns < 40 {
            oneTurn()
            root.layoutSubtreeIfNeeded()
            turns += 1
        }
        return Reading(surface: "网格", immediate: immediate, afterLayout: afterLayout,
                       expected: expected!, expectedBand: gridBand(root, originY: expected!.y),
                       requests: requests, visibleCount: afterLayout.visible.count,
                       turnsToCorrect: turns)
    }

    // MARK: - 侧栏

    private func paneVisible(_ root: WorkspaceRootView) -> [Int] {
        let table = root.browserPane.photoListForTesting
        guard let clip = table.enclosingScrollView?.contentView.bounds else { return [] }
        let rect = table.rows(in: clip)
        guard rect.length > 0 else { return [] }
        return Array(rect.location..<(rect.location + rect.length))
    }

    private func paneBand(_ root: WorkspaceRootView, originY: CGFloat) -> Set<Int> {
        let table = root.browserPane.photoListForTesting
        let h = table.enclosingScrollView?.contentView.bounds.height ?? 0
        let rowH = max(1, table.rowHeight)
        guard h > 0 else { return [] }
        let first = max(0, Int(floor(originY / rowH)) - 1)
        let last = Int(floor((originY + h) / rowH)) + 1
        return Set(first...max(first, last))
    }

    private func paneReading(_ root: WorkspaceRootView, library: Library,
                             replay expected: CGPoint?) -> Reading {
        let scroll = try! paneScroll(root)
        // 从胶片条切回侧栏（同 mode 的 set 是 no-op，根本没有「切换」）。
        root.setBrowserMode(.filmstrip)
        root.layoutSubtreeIfNeeded()
        settle(3)
        place(scroll, origin: .zero, activity: root.browserPane.scrollActivity)
        root.session.selectOnly(library.ids[Self.anchorIndex])
        settle(2)

        let layoutsBefore = root.browserPane.photoListLayoutPassCountForTesting
        root.setBrowserMode(.list)                         // ← 切图入口
        let immediate = Sample(origin: scroll.contentView.bounds.origin,
                               visible: paneVisible(root),
                               layouts: root.browserPane.photoListLayoutPassCountForTesting - layoutsBefore)
        if expected == nil {
            settle(10)
            let o = scroll.contentView.bounds.origin
            return Reading(surface: "侧栏", immediate: immediate,
                           afterLayout: Sample(origin: o, visible: paneVisible(root), layouts: 0),
                           expected: o, expectedBand: paneBand(root, originY: o.y),
                           requests: [], visibleCount: 0, turnsToCorrect: 0)
        }
        root.layoutSubtreeIfNeeded()
        let afterLayout = Sample(origin: scroll.contentView.bounds.origin,
                                 visible: paneVisible(root),
                                 layouts: root.browserPane.photoListLayoutPassCountForTesting - layoutsBefore)
        var turns = 0
        while !paneVisible(root).contains(Self.anchorIndex), turns < 40 {
            oneTurn()
            root.layoutSubtreeIfNeeded()
            turns += 1
        }
        return Reading(surface: "侧栏", immediate: immediate, afterLayout: afterLayout,
                       expected: expected!, expectedBand: paneBand(root, originY: expected!.y),
                       requests: [], visibleCount: afterLayout.visible.count, turnsToCorrect: turns)
    }

    // MARK: - 胶片条

    private func stripVisible(_ root: WorkspaceRootView) -> [Int] {
        root.filmstripController.collectionView.indexPathsForVisibleItems().map(\.item).sorted()
    }

    private func stripBand(_ root: WorkspaceRootView, originX: CGFloat) -> Set<Int> {
        let viewport = (root.filmstripController.view as? NSScrollView)?.contentView.bounds ?? .zero
        guard viewport.width > 0 else { return [] }
        let flow = root.filmstripController.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout
        let pitch = (flow?.itemSize.width ?? 1) + (flow?.minimumInteritemSpacing ?? 0)
        guard pitch > 1 else { return [] }
        let inset = flow?.sectionInset.left ?? 0
        let first = max(0, Int(floor((originX - inset) / pitch)) - 1)
        let last = Int(floor((originX + viewport.width - inset) / pitch)) + 1
        return Set(first...max(first, last))
    }

    private func stripReading(_ root: WorkspaceRootView, library: Library,
                              replay expected: CGPoint?) -> Reading {
        let scroll = try! stripScroll(root)
        // 从侧栏切到胶片条。
        root.setBrowserMode(.list)
        root.layoutSubtreeIfNeeded()
        settle(3)
        place(scroll, origin: .zero, activity: root.filmstripController.scrollActivity)
        root.session.selectOnly(library.ids[Self.anchorIndex])
        settle(2)

        let layoutsBefore = root.filmstripController.collectionView.layoutPassCount
        root.setBrowserMode(.filmstrip)                    // ← 切图入口
        let immediate = Sample(origin: scroll.contentView.bounds.origin,
                               visible: stripVisible(root),
                               layouts: root.filmstripController.collectionView.layoutPassCount - layoutsBefore)
        if expected == nil {
            settle(10)
            let o = scroll.contentView.bounds.origin
            return Reading(surface: "胶片条", immediate: immediate,
                           afterLayout: Sample(origin: o, visible: stripVisible(root), layouts: 0),
                           expected: o, expectedBand: stripBand(root, originX: o.x),
                           requests: [], visibleCount: 0, turnsToCorrect: 0)
        }
        root.layoutSubtreeIfNeeded()
        let afterLayout = Sample(origin: scroll.contentView.bounds.origin,
                                 visible: stripVisible(root),
                                 layouts: root.filmstripController.collectionView.layoutPassCount - layoutsBefore)
        var turns = 0
        while !stripVisible(root).contains(Self.anchorIndex), turns < 40 {
            oneTurn()
            root.layoutSubtreeIfNeeded()
            turns += 1
        }
        return Reading(surface: "胶片条", immediate: immediate, afterLayout: afterLayout,
                       expected: expected!, expectedBand: stripBand(root, originX: expected!.x),
                       requests: [], visibleCount: afterLayout.visible.count, turnsToCorrect: turns)
    }

    // MARK: - tests

    /// ① 三个面：切图那一 turn 内视口就在锚点上、可见集落在期望带。
    func testOne_allThreeSurfacesPlaceTheViewportInTheSwitchTurn() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .list)

        let gridTruth = gridReading(root, library: library, replay: nil)
        let grid = gridReading(root, library: library, replay: gridTruth.expected)
        note("网格 ground truth \(fmt(gridTruth.expected))")
        describe(grid)

        let paneTruth = paneReading(root, library: library, replay: nil)
        let pane = paneReading(root, library: library, replay: paneTruth.expected)
        note("侧栏 ground truth \(fmt(paneTruth.expected))")
        describe(pane)

        let stripTruth = stripReading(root, library: library, replay: nil)
        let strip = stripReading(root, library: library, replay: stripTruth.expected)
        note("胶片条 ground truth \(fmt(stripTruth.expected))")
        describe(strip)

        for (name, truth) in [("网格", gridTruth), ("侧栏", paneTruth), ("胶片条", stripTruth)] {
            XCTAssertTrue(truth.afterLayout.visible.contains(Self.anchorIndex),
                          "precondition：\(name) settle 之后必须看得见第 \(Self.anchorIndex) 张，"
                          + "实际 \(truth.afterLayout.visible.prefix(8))…")
        }

        XCTAssertEqual(grid.originMiss, 0, accuracy: 0.5,
                       "切图那一 turn 内网格视口就该在锚点上：期望 \(fmt(grid.expected))，实际 \(fmt(grid.afterLayout.origin))")
        XCTAssertEqual(pane.originMiss, 0, accuracy: 0.5,
                       "切图那一 turn 内侧栏视口就该在锚点上：期望 \(fmt(pane.expected))，实际 \(fmt(pane.afterLayout.origin))")
        XCTAssertEqual(strip.originMiss, 0, accuracy: 0.5,
                       "切图那一 turn 内胶片条视口就该在锚点上：期望 \(fmt(strip.expected))，实际 \(fmt(strip.afterLayout.origin))")

        XCTAssertTrue(grid.afterLayout.visible.contains(Self.anchorIndex),
                      "同一 turn 内网格可见集必须含锚点：\(grid.afterLayout.visible.prefix(8))…")
        XCTAssertTrue(pane.afterLayout.visible.contains(Self.anchorIndex),
                      "同一 turn 内侧栏可见集必须含锚点：\(pane.afterLayout.visible.prefix(8))…")
        XCTAssertTrue(strip.afterLayout.visible.contains(Self.anchorIndex),
                      "同一 turn 内胶片条可见集必须含锚点：\(strip.afterLayout.visible.prefix(8))…")

        XCTAssertTrue(Set(grid.afterLayout.visible).isSubset(of: grid.expectedBand),
                      "网格可见集必须落在期望带内：多出 \(Set(grid.afterLayout.visible).subtracting(grid.expectedBand).sorted())")
        XCTAssertTrue(Set(pane.afterLayout.visible).isSubset(of: pane.expectedBand),
                      "侧栏可见集必须落在期望带内：多出 \(Set(pane.afterLayout.visible).subtracting(pane.expectedBand).sorted())")
        XCTAssertTrue(Set(strip.afterLayout.visible).isSubset(of: strip.expectedBand),
                      "胶片条可见集必须落在期望带内：多出 \(Set(strip.afterLayout.visible).subtracting(strip.expectedBand).sorted())")

        XCTAssertEqual(grid.turnsToCorrect, 0, "网格切图后同一 turn 内就正确")
        XCTAssertEqual(pane.turnsToCorrect, 0, "侧栏切图后同一 turn 内就正确")
        XCTAssertEqual(strip.turnsToCorrect, 0, "胶片条切图后同一 turn 内就正确")

        XCTAssertEqual(grid.afterLayout.layouts, 1,
                       "网格切图 turn 只许一趟布局（直出：位置先定，cell 就地出生）；"
                       + "实际 \(grid.afterLayout.layouts) 次（immediate \(grid.immediate.layouts)）")
        // 侧栏是 2 趟：切换那趟布局先把行数与面板几何给出来（表还没有行时无处可置），reveal 再
        // 把新一带的行就地布局出来。这不是「沿路创建」，第一趟没有任何行被材化到屏幕上。
        XCTAssertEqual(pane.afterLayout.layouts, 2,
                       "侧栏切图 turn 的布局次数 \(pane.afterLayout.layouts)（已说明：先给几何，再置 clip）")
        XCTAssertEqual(strip.afterLayout.layouts, 1,
                       "胶片条切图 turn 只许一趟布局；实际 \(strip.afterLayout.layouts) 次")
    }

    /// ④ 同一 turn 内可见格的缩略图请求必须全部发出，且都是 on-screen 优先级。
    func testTwo_everyVisibleCellAsksForItsThumbnailInTheSwitchTurn() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .list)

        let truth = gridReading(root, library: library, replay: nil)
        let grid = gridReading(root, library: library, replay: truth.expected)
        note("请求口径（网格）")
        describe(grid)

        let asked = Set(grid.requests.map(\.index))
        let visible = Set(grid.afterLayout.visible)
        XCTAssertEqual(grid.requests.count, grid.visibleCount,
                       "同一 turn 内请求数必须等于可见格数：请求 \(grid.requests.count)，可见 \(grid.visibleCount)")
        XCTAssertEqual(asked, visible,
                       "请求的索引必须正好是可见格：缺 \(visible.subtracting(asked).sorted())，"
                       + "多 \(asked.subtracting(visible).sorted())")
        XCTAssertEqual(grid.requests.filter { $0.priority == .onScreen }.count, grid.requests.count,
                       "切图这一 turn 的请求必须都是 on-screen 优先级")
    }

    /// ③ anchor 在可见区外（用户滚远了）⇒ 切图后锚点回到可见区，另外两面位置不变。
    func testThree_anAnchorOutsideTheViewportComesBackWithoutMovingTheOtherSurfaces() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let root = try makeRoot(session, mode: .list)

        root.session.selectOnly(library.ids[Self.anchorIndex])
        settle(2)
        let gridScrollView = root.gridController.scrollView
        let rowH = max(1, root.gridController.metrics.rowHeight)
        place(gridScrollView, origin: NSPoint(x: 0, y: 100 * rowH))
        root.session.mode = .loupe
        root.showModule(for: .loupe)
        settle(2)

        let paneScrollView = try paneScroll(root)
        let stripScrollView = try stripScroll(root)
        let paneBefore = paneScrollView.contentView.bounds.origin
        let stripBefore = stripScrollView.contentView.bounds.origin

        let logBefore = root.gridController.requestLog.count
        let layoutsBefore = root.gridController.collectionView.layoutPassCount
        root.session.mode = .grid
        root.showModule(for: .grid)                        // ← 切图入口
        root.layoutSubtreeIfNeeded()

        let origin = gridScrollView.contentView.bounds.origin
        let visible = gridVisible(root)
        let layouts = root.gridController.collectionView.layoutPassCount - layoutsBefore
        let requests = root.gridController.requestLog.count - logBefore
        let truth = gridReading(root, library: library, replay: nil)
        note("滚远后切图：origin \(fmt(origin))，期望 \(fmt(truth.expected))，"
             + "layout \(layouts) 次，请求 \(requests) 个，可见 \(visible.count) 格"
             + "（锚点在：\(visible.contains(Self.anchorIndex))）")

        XCTAssertEqual(abs(origin.x - truth.expected.x) + abs(origin.y - truth.expected.y), 0,
                       accuracy: 0.5,
                       "锚点在可见区外时，切图仍必须直出到锚点：期望 \(fmt(truth.expected))，实际 \(fmt(origin))")
        XCTAssertTrue(visible.contains(Self.anchorIndex), "滚远之后切图，锚点必须回到可见区：\(visible.prefix(8))…")
        XCTAssertEqual(paneScrollView.contentView.bounds.origin, paneBefore,
                       "网格切图不许移动侧栏")
        XCTAssertEqual(stripScrollView.contentView.bounds.origin, stripBefore,
                       "网格切图不许移动胶片条")
    }
}
