import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 383 — 胶片条与侧栏（左照片列表）**行为完全一致**：
///
/// - **单击** = 只选中：不切编辑视角（`mode` 不变）、**不居中**；
/// - **双击 / Return** = 进编辑视角（`.loupe`），**此时居中一次**；
/// - **真正编辑落地**（`commitEdit` → 303 的 0.25 s 合并窗口）= 居中一次；拖动期间不居中。
///
/// 352 为「防双击误触」加的 `pendingCenter` 延迟机制整套退役（见 `BrowserClickGuard`）：
/// 单击不再居中 ⇒ 格子不会从指针下滑走 ⇒ 第二下必然还落在同一张上，不需要延迟也不需要吞点击。
///
/// 夹具与 332/352 的验收同构：100 张、100 pt 格子/行、800 pt 可视。
@MainActor
final class SingleClickNoCenter383Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-383-\(UUID().uuidString)", isDirectory: true)
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
        let url = tmp.appendingPathComponent("s383-\(UUID().uuidString).photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: url)
        let src = tmp.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        var ids: [String] = []
        for index in 0..<count {
            let name = String(format: "IMG_%04d.dng", index)
            let file = src.appendingPathComponent(name)
            // A placeholder byte: the row exists, the decode fails fast — this test is about clicks,
            // not pixels.
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

    private func makeWindow(_ size: CGSize = CGSize(width: 1400, height: 900)) -> NSWindow {
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

    private func timeUntil(_ limit: TimeInterval = 2.0, _ predicate: () -> Bool) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < limit {
            if predicate() { return Date().timeIntervalSince(start) }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return predicate() ? Date().timeIntervalSince(start) : nil
    }

    /// `print` from an XCTest process is not reliably interleaved into `swift test`'s log when it is
    /// piped, so every acceptance number goes to stderr *and* to a file the caller can read.
    private func note(_ line: String) {
        FileHandle.standardError.write(Data("ACCEPT383 \(line)\n".utf8))
        let path = ProcessInfo.processInfo.environment["PHOTONS_383_LOG"] ?? "/tmp/photons-383.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data("\(line)\n".utf8))
            handle.closeFile()
        } else {
            try? ("\(line)\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - the filmstrip at 100 pt items and an 800 pt viewport (332's numbers)

    private struct Strip {
        let controller: FilmstripController
        let scroll: NSScrollView
    }

    private static let stripHeight: CGFloat = 100 / WorkspaceLayout.filmstripAspect + 12 + 8 + 6
    private static let viewport: CGFloat = 800
    private static let pitch: CGFloat = 100

    private func makeStrip(_ session: CatalogSession) throws -> Strip {
        let window = makeWindow()
        let controller = FilmstripController(session: session)
        // The double-click / Return verb in the app is `WorkspaceRootView`'s wiring; here it is the
        // same call, so `mode` lands exactly where the shipping app puts it.
        controller.onActivate = { [weak session] id in session?.activate(id) }
        let scroll = try XCTUnwrap(controller.view as? NSScrollView)
        scroll.frame = NSRect(x: 0, y: 0, width: Self.viewport, height: Self.stripHeight)
        window.contentView?.addSubview(scroll)
        window.contentView?.layoutSubtreeIfNeeded()
        settle(4)

        let flow = try XCTUnwrap(controller.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
        flow.minimumLineSpacing = 0
        flow.minimumInteritemSpacing = 0
        flow.sectionInset = NSEdgeInsets()
        flow.invalidateLayout()
        controller.collectionView.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        settle(4)
        // The timing is what the acceptance measures, not the animation curve: jump, so nothing is in
        // flight while a test moves the viewport by hand.
        controller.reduceMotion = { true }
        return Strip(controller: controller, scroll: scroll)
    }

    private func stripOffset(_ strip: Strip) -> CGFloat { strip.scroll.contentView.bounds.origin.x }

    private func placeStrip(_ strip: Strip, at offset: CGFloat) {
        strip.controller.scrollActivity.beginOwnChange()
        strip.scroll.contentView.setBoundsOrigin(NSPoint(x: offset, y: 0))
        settle(2)
    }

    /// A point inside item `item` in **collection-view** coordinates, right now.
    private func stripPoint(_ strip: Strip, item: Int, dx: CGFloat = 0) throws -> NSPoint {
        let frame = try XCTUnwrap(strip.controller.collectionView
            .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame)
        return NSPoint(x: frame.midX + dx, y: frame.midY)
    }

    /// Put `item` in the middle of the strip so it is hit-testable, without claiming a centre.
    private func reveal(_ strip: Strip, item: Int) {
        let wanted = min(max(0, CGFloat(item) * Self.pitch + Self.pitch / 2 - Self.viewport / 2),
                         CGFloat(99) * Self.pitch + Self.pitch - Self.viewport)
        placeStrip(strip, at: wanted)
    }

    /// One click through the shipping seam (`onMouseDown` → `handleMouseDown`).
    @discardableResult
    private func click(_ strip: Strip, item: Int, now: Date = Date()) throws -> BrowserClickGuard.Decision {
        strip.controller.handleMouseDown(at: try stripPoint(strip, item: item), now: now)
    }

    // MARK: - the left pane fixture (332's numbers: 100 pt rows, 800 pt viewport)

    private struct Pane {
        let controller: BrowserPaneController
        let table: NSTableView
        let scroll: NSScrollView
    }

    private func makePane(_ session: CatalogSession) throws -> Pane {
        let window = makeWindow()
        let controller = BrowserPaneController(session: session)
        window.contentView?.addSubview(controller.view)
        var height: CGFloat = 900
        _ = controller.applyLayout(in: CGSize(width: 260, height: height))
        while controller.photoListHeight < 800 - 0.001, height < 4000 {
            height += 1
            _ = controller.applyLayout(in: CGSize(width: 260, height: height))
        }
        settle(4)
        let table = controller.photoListForTesting
        table.rowHeight = 100
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.reloadData()
        controller.view.layoutSubtreeIfNeeded()
        settle(4)
        controller.reduceMotion = { true }
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        return Pane(controller: controller, table: table, scroll: scroll)
    }

    private func placePane(_ pane: Pane, at offset: CGFloat) {
        pane.controller.scrollActivity.beginOwnChange()
        pane.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: offset))
        settle(2)
    }

    private func panePoint(_ pane: Pane, row: Int) throws -> NSPoint {
        let rect = pane.table.rect(ofRow: row)
        guard rect.height > 0 else { throw XCTSkip("row \(row) has no frame") }
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    private func revealPane(_ pane: Pane, row: Int) {
        let wanted = min(max(0, CGFloat(row) * 100 + 50 - 400), 100 * 100 - 800)
        placePane(pane, at: wanted)
    }

    @discardableResult
    private func click(_ pane: Pane, row: Int, now: Date = Date()) throws -> BrowserClickGuard.Decision {
        pane.controller.handleMouseDown(at: try panePoint(pane, row: row), now: now)
    }

    // MARK: - ① 胶片条单击只选中（三个位置：中段、两端）

    func testOne_aFilmstripClickOnlySelectsAndDoesNotOpenLoupe() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        XCTAssertEqual(session.mode, .grid, "precondition：起点是网格")

        var passed = 0
        var rows: [String] = []
        for item in [5, 50, 95] {
            reveal(strip, item: item)
            let decision = try click(strip, item: item)
            settle(2)
            XCTAssertEqual(decision, .forward, "第 \(item) 格：普通单击应 forward")
            XCTAssertEqual(session.selection, [library.ids[item]], "第 \(item) 格：单击后 selection 应只有它")
            XCTAssertEqual(session.anchorID, library.ids[item], "第 \(item) 格：anchor 应跟着走")
            XCTAssertEqual(session.mode, .grid, "第 \(item) 格：单击 **不** 进编辑视角（mode \(session.mode)）")
            if session.selection == [library.ids[item]],
               session.anchorID == library.ids[item],
               session.mode == .grid { passed += 1 }
            rows.append("\(item) → 选中 \((session.anchorID ?? "?").prefix(8)) mode=\(session.mode)")
        }
        XCTAssertEqual(passed, 3, "① 胶片条单击只选中：\(passed)/3")
        note("383 ① 胶片条单击只选中 \(passed)/3（3 个位置各一次）；\(rows.joined(separator: "；"))")
    }

    // MARK: - ② 侧栏单击同样只选中（同一断言体）

    func testTwo_aSidebarClickOnlySelectsAndDoesNotOpenLoupe() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let pane = try makePane(session)
        settle(4)
        XCTAssertEqual(session.mode, .grid, "precondition：起点是网格")

        revealPane(pane, row: 50)
        let decision = try click(pane, row: 50)
        settle(2)
        XCTAssertEqual(decision, .forward)
        XCTAssertEqual(session.selection, [library.ids[50]], "侧栏单击后 selection 应只有那一行")
        XCTAssertEqual(session.anchorID, library.ids[50])
        XCTAssertEqual(session.mode, .grid, "侧栏单击 **不** 进编辑视角（mode \(session.mode)）")
        note("383 ② 侧栏单击只选中：选中 \((session.anchorID ?? "?").prefix(8))，mode=\(session.mode)（1/1）")
    }

    // MARK: - ③ 单击不居中：两面各 3 次，centerScrollCount 增量 0

    func testThree_neitherSurfaceCentresWhenAClickOnlySelects() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)

        var stripDelta = 0
        for item in [5, 50, 95] {
            // 视口故意偏离「该格居中」300 pt：单击要是又被接上居中，这里必然 +1（反向门 ⑪ 的判据）。
            // 用 `reveal` 把格子摆到正中间会让居中变成 no-op，测不出任何东西。
            placeStrip(strip, at: max(0, CGFloat(item) * Self.pitch + Self.pitch / 2 - Self.viewport / 2 - 300))
            let before = strip.controller.centerScrollCount
            try click(strip, item: item)
            settle(3)                       // 让模型的「锚点变了」tick 也跑过
            stripDelta += strip.controller.centerScrollCount - before
            XCTAssertEqual(strip.controller.centerScrollCount, before,
                           "第 \(item) 格单击后不许滚（\(before) → \(strip.controller.centerScrollCount)）")
        }

        let pane = try makePane(session)
        var paneDelta = 0
        for row in [5, 50, 95] {
            placePane(pane, at: max(0, CGFloat(row) * 100 + 50 - 400 - 300))
            let before = pane.controller.centerScrollCount
            try click(pane, row: row)
            settle(3)
            paneDelta += pane.controller.centerScrollCount - before
            XCTAssertEqual(pane.controller.centerScrollCount, before,
                           "侧栏第 \(row) 行单击后不许滚（\(before) → \(pane.controller.centerScrollCount)）")
        }

        XCTAssertEqual(stripDelta, 0, "胶片条 3 次单击的 centerScrollCount 增量应为 0，实际 \(stripDelta)")
        XCTAssertEqual(paneDelta, 0, "侧栏 3 次单击的 centerScrollCount 增量应为 0，实际 \(paneDelta)")
        note("383 ③ 单击不居中：胶片条 3 次增量 \(stripDelta)（合计计数 \(strip.controller.centerScrollCount)），侧栏 3 次增量 \(paneDelta)（合计计数 \(pane.controller.centerScrollCount)）→ 6/6")
    }

    // MARK: - ④ 双击进编辑视角并居中一次（两面各一次）

    func testFour_aDoubleClickOpensLoupeAndCentresExactlyOnce() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)

        // 第 50 张可见但**不在**中间：这样「进编辑视角时居中一次」是真的滚一下，而不是 no-op。
        placeStrip(strip, at: 50 * Self.pitch + Self.pitch / 2 - Self.viewport / 2 - 300)
        let first = Date()
        XCTAssertEqual(try click(strip, item: 50, now: first), .forward)
        settle(2)
        XCTAssertEqual(strip.controller.centerScrollCount, 0, "第一下只选中，不居中")
        XCTAssertEqual(session.mode, .grid, "第一下不进编辑视角")
        XCTAssertEqual(try click(strip, item: 50, now: first.addingTimeInterval(0.1)), .doubleClick,
                       "同格第二下 = 双击")
        // AppKit 的双击手势跑的那个动词（`handleDoubleClick` → `activateItem`）。
        strip.controller.activateItem(at: try stripPoint(strip, item: 50))
        settle(2)
        XCTAssertEqual(session.mode, .loupe, "双击应进编辑视角")
        XCTAssertEqual(session.anchorID, library.ids[50])
        XCTAssertEqual(strip.controller.centerScrollCount, 1, "双击应居中一次（实际 \(strip.controller.centerScrollCount)）")
        pump(0.8)
        XCTAssertEqual(strip.controller.centerScrollCount, 1, "窗口过后不许再来第二次（延迟居中已退役）")

        // …and the left list, same rule.
        session.mode = .grid
        let pane = try makePane(session)
        placePane(pane, at: 50 * 100 + 50 - 400 - 300)
        let paneBefore = pane.controller.centerScrollCount
        let paneFirst = Date()
        XCTAssertEqual(try click(pane, row: 50, now: paneFirst), .forward)
        settle(2)
        XCTAssertEqual(pane.controller.centerScrollCount, paneBefore, "侧栏第一下只选中")
        XCTAssertEqual(try click(pane, row: 50, now: paneFirst.addingTimeInterval(0.1)), .doubleClick)
        XCTAssertTrue(pane.controller.openRowInLoupe(50, assetID: library.ids[50]),
                      "侧栏双击的动词应能打开这一行")
        settle(2)
        XCTAssertEqual(session.mode, .loupe)
        XCTAssertEqual(session.anchorID, library.ids[50])
        XCTAssertEqual(pane.controller.centerScrollCount, paneBefore + 1,
                       "侧栏双击应居中一次（\(paneBefore) → \(pane.controller.centerScrollCount)）")
        pump(0.8)
        XCTAssertEqual(pane.controller.centerScrollCount, paneBefore + 1, "只 +1")
        note("383 ④ 双击：胶片条 mode=\(session.mode) 居中 0 → 1（+1）；侧栏 居中 \(paneBefore) → \(pane.controller.centerScrollCount)（+1）；两面各 1 次 → 2/2")
    }

    // MARK: - ⑤ 编辑落地才居中（0.25 s 合并窗口：窗口内 0 次、窗口后 +1 且只 +1）

    func testFive_anEditCommitCentresOnceAfterTheMergeWindow() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let window = makeWindow(CGSize(width: 1600, height: 1000))
        let root = WorkspaceRootView(session: session)
        root.frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window.contentView?.addSubview(root)
        root.layoutSubtreeIfNeeded()
        settle(6)
        root.setBrowserMode(.filmstrip)
        root.layoutSubtreeIfNeeded()
        settle(6)
        let strip = try XCTUnwrap(root.filmstripController.view as? NSScrollView)
        let filmstrip = root.filmstripController
        let visible = strip.contentView.bounds.width
        XCTAssertGreaterThan(visible, 0, "胶片条应有可视宽度")

        // 单击 → 只选中（不居中），然后走双击的动词进编辑视角并居中。先把第 50 张摆到视口中间，
        // 否则 `indexPathForItem(at:)` 在指针落在视口外时解析不到格子。
        let frame = try XCTUnwrap(filmstrip.collectionView
            .layoutAttributesForItem(at: IndexPath(item: 50, section: 0))?.frame)
        let content = filmstrip.collectionView.collectionViewLayout?.collectionViewContentSize.width ?? 0
        let centred = CenteredScroll.target(itemMidpoint: frame.midX, contentLength: content,
                                            visibleLength: visible)
        filmstrip.scrollActivity.beginOwnChange()
        strip.contentView.setBoundsOrigin(NSPoint(x: centred, y: 0))
        settle(2)
        filmstrip.handleMouseDown(at: NSPoint(x: frame.midX, y: frame.midY))
        settle(3)
        XCTAssertEqual(session.mode, .grid, "precondition：单击只选中")
        filmstrip.activateItem(at: NSPoint(x: frame.midX, y: frame.midY))
        settle(3)
        XCTAssertEqual(session.mode, .loupe, "双击动词进了编辑视角")

        // 把视口挪走，并等 332 的「用户正在滚动」窗口过期 —— 编辑不该被当成跟用户抢。
        filmstrip.scrollActivity.beginOwnChange()
        strip.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        pump(0.2)

        let countBefore = filmstrip.centerScrollCount
        session.applyEdit { $0.light.exposure = 0.75 }
        let committedAt = Date()
        XCTAssertTrue(session.commitEdit(label: "曝光"), "这次编辑应当落地")

        pump(0.15)
        XCTAssertEqual(filmstrip.centerScrollCount, countBefore, "0.25 s 合并窗口内不许滚")
        let arrival = try XCTUnwrap(timeUntil(1.5) { filmstrip.centerScrollCount == countBefore + 1 },
                                    "0.25 s 合并窗口关掉后应当滚一次")
        let elapsed = Date().timeIntervalSince(committedAt)
        XCTAssertGreaterThan(elapsed, 0.24, "滚动必须等 0.25 s 合并窗口，实际 \(elapsed) s")
        XCTAssertLessThan(elapsed, 0.5 + CenteredScroll.duration,
                          "合并窗口不应拖长（一个 0.25 s 窗口，只滚一次），实际 \(elapsed) s")
        pump(0.8)
        XCTAssertEqual(filmstrip.centerScrollCount, countBefore + 1,
                       "一次编辑只滚一次（\(countBefore) → \(filmstrip.centerScrollCount)）")
        note("383 ⑤ 编辑落地：commit \(String(format: "%.3f", elapsed)) s 后滚 1 次（窗口内 0 次；计数 \(countBefore) → \(filmstrip.centerScrollCount)），到达耗时 \(String(format: "%.3f", arrival)) s；1/1")
    }

    // MARK: - ⑥ 拖动期间不居中：10 次 applyEdit（不 commit）增量 0

    func testSix_nothingCentresWhileAnEditIsBeingDragged() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let window = makeWindow(CGSize(width: 1600, height: 1000))
        let root = WorkspaceRootView(session: session)
        root.frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window.contentView?.addSubview(root)
        root.layoutSubtreeIfNeeded()
        settle(6)
        root.setBrowserMode(.filmstrip)
        root.layoutSubtreeIfNeeded()
        settle(6)
        let filmstrip = root.filmstripController
        let strip = try XCTUnwrap(filmstrip.view as? NSScrollView)
        XCTAssertGreaterThan(strip.contentView.bounds.width, 0)

        session.selectOnly(library.ids[50])
        session.mode = .loupe
        settle(3)
        filmstrip.scrollActivity.beginOwnChange()
        strip.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        pump(0.2)

        let before = filmstrip.centerScrollCount
        for tick in 1...10 {
            session.applyEdit { $0.light.exposure = Double(tick) * 0.05 }
            pump(0.02)                       // 一个拖动的节拍：窗口被每一拍重置
            XCTAssertEqual(filmstrip.centerScrollCount, before,
                           "第 \(tick) 拍（未 commit）不许滚（\(before) → \(filmstrip.centerScrollCount)）")
        }
        XCTAssertEqual(filmstrip.centerScrollCount, before,
                       "10 次 applyEdit 期间 centerScrollCount 增量应为 0，实际 \(filmstrip.centerScrollCount - before)")
        note("383 ⑥ 拖动期间不居中：10 次 applyEdit（不 commit）→ centerScrollCount \(before) → \(filmstrip.centerScrollCount)（增量 0）→ 10/10")
    }

    // MARK: - ⑦ 双击仍打开第一下命中的那张；窗口内点另一格两下都生效

    func testSeven_aDoubleClickOpensTheFirstPressPhotoAndNoPressIsSwallowed() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        reveal(strip, item: 50)
        let p50 = try stripPoint(strip, item: 50)

        // (a) 同一格两下 → 打开第一下那张。
        let t0 = Date()
        XCTAssertEqual(strip.controller.handleMouseDown(at: p50, now: t0), .forward)
        XCTAssertEqual(strip.controller.handleMouseDown(at: p50, now: t0.addingTimeInterval(0.12)), .doubleClick)
        XCTAssertEqual(strip.controller.clickGuard.openTargetID(fallback: "?"), library.ids[50],
                       "双击的目标是第一下命中的那张")
        strip.controller.activateItem(at: p50)
        settle(2)
        XCTAssertEqual(session.anchorID, library.ids[50], "双击打开的是第一下那张")
        XCTAssertEqual(session.mode, .loupe)

        // (b) 按下 N、再按 N+1：第二下**生效**（选中 N+1），而双击的动词仍然打开 N。
        session.mode = .grid
        let p51 = try stripPoint(strip, item: 51)
        let t1 = Date()                             // 新的一对（上一对已 resolved），窗口从这一下重新开始
        XCTAssertEqual(strip.controller.handleMouseDown(at: p50, now: t1), .forward,
                       "第一下 N")
        XCTAssertEqual(strip.controller.handleMouseDown(at: p51, now: t1.addingTimeInterval(0.10)), .forward,
                       "窗口内点另一格不再被吞（383 §2.3）")
        XCTAssertEqual(session.anchorID, library.ids[51], "第二下生效：选中 N+1")
        XCTAssertEqual(strip.controller.clickGuard.openTargetID(fallback: "?", now: t1.addingTimeInterval(0.11)),
                       library.ids[50], "而双击的目标仍是第一下那张 N")
        strip.controller.activateItem(at: p51)
        settle(2)
        XCTAssertEqual(session.mode, .loupe, "动词仍进编辑视角")
        XCTAssertEqual(session.anchorID, library.ids[50], "打开的是 N（第一下那张），不是 N+1")
        note("383 ⑦ (a) 同格双击 → 打开第一下 \((library.ids[50]).prefix(8))；(b) 按下 N 再按 N+1 → 第二下生效选中 N+1、双击目标仍是 N（打开 \((session.anchorID ?? "?").prefix(8))）→ 2/2；swallow 已不存在")
    }

    // MARK: - ⑧ Return 仍进编辑视角

    func testEight_returnStillEntersLoupe() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        reveal(strip, item: 10)
        try click(strip, item: 10)
        settle(2)
        XCTAssertEqual(session.mode, .grid)

        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        strip.controller.collectionView.keyDown(with: event)
        settle(2)
        XCTAssertEqual(session.mode, .loupe, "Return 应进编辑视角（实际 \(session.mode)）")
        XCTAssertEqual(session.anchorID, library.ids[10])
        note("383 ⑧ Return：mode=\(session.mode)（1/1）")
    }
}
