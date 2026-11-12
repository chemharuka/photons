import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// **352 的延迟机制已被 383 取代** —— 这七条现在断言的是新规则，不是当年的旧规则。
///
/// 352 当时的问题：单击就切图，332 的居中随即把格子挪到指针下面，于是双击的第二下落到了邻格上。
/// 352 的答案是「把居中挂起一个双击窗口（`pendingCenter`）」+「窗口内第二下命中另一格就整次吞掉」。
///
/// 383 拆的是根因：**单击只选中 —— 不居中、也不切编辑视角**（胶片条与侧栏完全一致）。格子不动，第二下
/// 必然还落在同一张上，于是延迟居中与吞点击整套退役。本文件按 383 的口径重写：
///
/// | 352 原用例 | 383 处置 | 现在断言什么 |
/// |---|---|---|
/// | ① 双击端格打开第一下那张 | **保留** | 端格两下 → `.doubleClick`，动词打开第一下那张；没有居中，格子没挪 |
/// | ② 20 次随机双击不误切 | **保留** | `unintendedSwitch` 仍须 0（选中永远是按下过的那两张之一） |
/// | ③ 单击立即切图 + 居中延后 | **改写** | 单击只选中：不居中、不进编辑视角（延迟居中的前提消失） |
/// | ④ 窗口外两次点击都生效 | **保留** | 窗口仍读 `NSEvent.doubleClickInterval`，缩到 50 ms 也读得到 |
/// | ⑤ 同格双击进编辑且只居中一次 | **保留** | 动词进 `.loupe` 并居中一次；之后不再有「窗口那一次」 |
/// | ⑥ 延迟期间滚动丢 pendingCenter | **作废 → 改写** | 没有 pendingCenter 了：滚动之后编辑落地仍然只居中一次 |
/// | ⑦ 左栏同一规则 | **保留** | 侧栏单击只选中、双击进编辑并居中、窗口内点另一行两下都生效 |
@MainActor
final class DoubleClickGuard352Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-dbl383-\(UUID().uuidString)", isDirectory: true)
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
        let url = tmp.appendingPathComponent("dbl-\(UUID().uuidString).photonslibrary", isDirectory: true)
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

    // MARK: - the filmstrip at 100 pt items and an 800 pt viewport (332's numbers)

    private struct Strip {
        let controller: FilmstripController
        let scroll: NSScrollView
    }

    private static let stripHeight: CGFloat = 100 / WorkspaceLayout.filmstripAspect + 12 + 8 + 6
    private static let viewport: CGFloat = 800

    private func makeStrip(_ session: CatalogSession) throws -> Strip {
        let window = makeWindow()
        let controller = FilmstripController(session: session)
        // 与 `WorkspaceRootView` 同一条接线：双击 / Return 的动词在这里也是 `session.activate`。
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
        // Timing is what is measured, not the animation curve: jump so nothing is in flight while a
        // test moves the viewport by hand.
        controller.reduceMotion = { true }
        return Strip(controller: controller, scroll: scroll)
    }

    private func stripOffset(_ strip: Strip) -> CGFloat { strip.scroll.contentView.bounds.origin.x }

    private func placeStrip(_ strip: Strip, at offset: CGFloat) {
        strip.controller.scrollActivity.beginOwnChange()
        strip.scroll.contentView.setBoundsOrigin(NSPoint(x: offset, y: 0))
        settle(2)
    }

    /// A point inside item `item`, in collection-view coordinates; `dx` moves it within the cell.
    private func stripPoint(_ strip: Strip, item: Int, dx: CGFloat = 0) throws -> NSPoint {
        let frame = try XCTUnwrap(strip.controller.collectionView
            .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame)
        return NSPoint(x: frame.midX + dx, y: frame.midY)
    }

    private func stripItem(_ strip: Strip, at point: NSPoint) -> Int? {
        strip.controller.collectionView.indexPathForItem(at: point)?.item
    }

    /// `print` from an XCTest process is not reliably interleaved into `swift test`'s log when it is
    /// piped, so every acceptance number goes to stderr *and* to a file the caller can read.
    private func note(_ line: String) {
        FileHandle.standardError.write(Data("ACCEPT352 \(line)\n".utf8))
        let path = ProcessInfo.processInfo.environment["PHOTONS_352_LOG"] ?? "/tmp/photons-352.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data("\(line)\n".utf8))
            handle.closeFile()
        } else {
            try? ("\(line)\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - ① 用户场景：两端（会被回中挪动）的格子，双击后仍是第一下那张

    func testOne_doubleClickOnAnEndCellKeepsTheFirstPressPhoto() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)

        // 条带的一端：第 5 张靠视口右边按下。383 —— 这一下**不居中**，所以指针底下的格子没换，
        // 第二下自然还是第 5 张（352 当年正是这里被 332 的居中挪走了）。
        placeStrip(strip, at: 0)
        pump(0.35)   // 332's own window: our own change must be over
        let near = try stripPoint(strip, item: 5, dx: 40)
        XCTAssertEqual(stripItem(strip, at: near), 5, "precondition：按下的点是第 5 格")
        XCTAssertEqual(strip.controller.handleMouseDown(at: near), .forward)
        XCTAssertEqual(session.anchorID, library.ids[5], "第一下命中的是第 5 张")
        XCTAssertEqual(stripOffset(strip), 0, accuracy: 0.5,
                       "单击不居中：偏移仍是 0（实际 \(stripOffset(strip))）")
        XCTAssertEqual(stripItem(strip, at: near), 5, "格子没被挪走，第二下还落在这里")
        pump(0.35)
        XCTAssertEqual(strip.controller.handleMouseDown(at: near), .doubleClick, "同格第二下 = 双击")
        XCTAssertEqual(session.anchorID, library.ids[5], "双击不许把选中带跑")
        strip.controller.activateItem(at: near)
        settle(2)
        XCTAssertEqual(session.anchorID, library.ids[5], "打开的是第一下那张")
        XCTAssertEqual(session.mode, .loupe)

        // 另一端（内容末端贴边那一侧），同一条规则。
        session.mode = .grid
        placeStrip(strip, at: 9200)
        pump(0.35)
        let far = try stripPoint(strip, item: 95, dx: -40)
        XCTAssertEqual(stripItem(strip, at: far), 95, "precondition：按下的点是第 95 格")
        XCTAssertEqual(strip.controller.handleMouseDown(at: far), .forward)
        XCTAssertEqual(session.anchorID, library.ids[95])
        XCTAssertEqual(stripItem(strip, at: far), 95, "另一端：格子同样没被挪走")
        pump(0.35)
        XCTAssertEqual(strip.controller.handleMouseDown(at: far), .doubleClick)
        strip.controller.activateItem(at: far)
        settle(2)
        XCTAssertEqual(session.anchorID, library.ids[95])

        // …and the left photo list, same two presses, same answer.
        session.mode = .grid
        let pane = try makePane(session)
        placePane(pane, at: 0)
        pump(0.35)
        let rowPoint = try panePoint(pane, row: 5)
        XCTAssertEqual(paneRow(pane, at: rowPoint), 5, "precondition：按下的点是第 5 行")
        XCTAssertEqual(pane.controller.handleMouseDown(at: rowPoint), .forward)
        XCTAssertEqual(session.anchorID, library.ids[5])
        XCTAssertEqual(paneRow(pane, at: rowPoint), 5, "侧栏：行也没被挪走")
        pump(0.35)
        XCTAssertEqual(pane.controller.handleMouseDown(at: rowPoint), .doubleClick, "侧栏同格第二下 = 双击")
        XCTAssertTrue(pane.controller.openRowInLoupe(5, assetID: library.ids[5]))
        settle(2)
        XCTAssertEqual(session.anchorID, library.ids[5], "侧栏：第二下不许改选中")
        XCTAssertEqual(session.mode, .loupe)
        note("352 ① 胶片条 第 5 格 单击偏移 0 pt、第二下同格 → .doubleClick；另一端第 95 格同；侧栏第 5 行同。最终选中 \((session.anchorID ?? "?").prefix(8))")
        note("352 ① 计数 胶片条 forward \(strip.controller.clickGuard.forwardCount)/doubleClick \(strip.controller.clickGuard.doubleClickCount)；侧栏 forward \(pane.controller.clickGuard.forwardCount)/doubleClick \(pane.controller.clickGuard.doubleClickCount)")
    }

    // MARK: - ② 随机 20 次：条带不同位置双击，unintendedSwitch = 0

    /// Deterministic LCG — the 20 presses are reproducible, not "random enough".
    private struct LCG {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    func testTwo_twentyRandomDoubleClicksNeverSwitch() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        let interval = NSEvent.doubleClickInterval
        var rng = LCG(state: 352)
        var stripUnintended = 0
        var stripSameCell = 0
        var rows: [String] = []

        for round in 1...20 {
            // A random place in the strip, a random cell that is visible there, and a random drift of
            // the viewport between the two presses (0 – 90 pt, either way) — the drift 332's centre
            // used to produce all by itself.
            let target = 1 + rng.next(98)
            let offset = min(max(0, target * 100 + 50 - 400 + (rng.next(600) - 300)), 9200)
            placeStrip(strip, at: CGFloat(offset))
            let point = try stripPoint(strip, item: target)
            let firstHit = stripItem(strip, at: point) ?? -1
            let press1 = strip.controller.handleMouseDown(at: point)
            let drift = rng.next(180) - 90
            strip.controller.scrollActivity.beginOwnChange()
            strip.scroll.contentView.setBoundsOrigin(NSPoint(x: CGFloat(offset + drift), y: 0))
            settle(1)
            let secondHit = stripItem(strip, at: point) ?? -1
            let press2 = strip.controller.handleMouseDown(at: point)
            XCTAssertEqual(press1, .forward, "第 \(round) 轮第一下应当选中")
            if secondHit == firstHit {
                stripSameCell += 1
                XCTAssertEqual(press2, .doubleClick, "第 \(round) 轮同格第二下应是双击")
            } else {
                // 383 §2.3 — 另一格就是另一次单击：它生效（不再被吞）。
                XCTAssertEqual(press2, .forward, "第 \(round) 轮命中另一格（\(firstHit) → \(secondHit)）是普通单击")
            }
            // 「误切」= 选中落到两张按下过的格子之外。383 之后这条恒为 0：一次按下只改一次选中。
            let final = session.anchorID ?? "?"
            let pressed = Set([firstHit, secondHit].filter { $0 >= 0 }.map { library.ids[$0] })
            let switched = !pressed.contains(final)
            if switched { stripUnintended += 1 }
            rows.append("\(round). 目标 \(target) 第一下 \(firstHit) 第二下 \(secondHit) 漂移 \(drift) → 选中 \(final.prefix(8)) 误切 \(switched ? "是" : "否")")
            XCTAssertFalse(switched, "第 \(round) 轮：选中落到了没人按过的照片 \(final)")
        }

        // The same 20, on the left photo list.
        let pane = try makePane(session)
        var paneUnintended = 0
        var paneRows: [String] = []
        for round in 1...20 {
            let target = 1 + rng.next(98)
            let offset = min(max(0, target * 100 + 60 - 400 + (rng.next(400) - 200)), 9200)
            placePane(pane, at: CGFloat(offset))
            let point = try panePoint(pane, row: target)
            let firstHit = paneRow(pane, at: point) ?? -1
            XCTAssertEqual(pane.controller.handleMouseDown(at: point), .forward)
            let drift = rng.next(200) - 100
            pane.controller.scrollActivity.beginOwnChange()
            pane.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: CGFloat(offset + drift)))
            settle(1)
            let secondHit = paneRow(pane, at: point) ?? -1
            let decision = pane.controller.handleMouseDown(at: point)
            if secondHit == firstHit {
                XCTAssertEqual(decision, .doubleClick, "侧栏第 \(round) 轮同格第二下应是双击")
            } else {
                XCTAssertEqual(decision, .forward, "侧栏第 \(round) 轮：命中另一行是普通单击（不再吞）")
            }
            let final = session.anchorID ?? "?"
            let pressed = Set([firstHit, secondHit].filter { $0 >= 0 }.map { library.ids[$0] })
            let switched = !pressed.contains(final)
            if switched { paneUnintended += 1 }
            paneRows.append("\(round). 目标 \(target) 第一下 \(firstHit) 第二下 \(secondHit) 漂移 \(drift) → 选中 \(final.prefix(8)) 误切 \(switched ? "是" : "否")")
            XCTAssertFalse(switched, "侧栏第 \(round) 轮：选中落到了没人按过的照片 \(final)")
        }

        XCTAssertEqual(stripUnintended, 0, "胶片条 unintendedSwitch 应为 0，实际 \(stripUnintended)")
        XCTAssertEqual(paneUnintended, 0, "侧栏 unintendedSwitch 应为 0，实际 \(paneUnintended)")
        note("352 ② 双击窗口 \(interval) s")
        for row in rows { note("352 ② 胶片条 \(row)") }
        for row in paneRows { note("352 ② 侧栏 \(row)") }
        note("352 ② unintendedSwitch：胶片条 \(stripUnintended)/20，侧栏 \(paneUnintended)/20；胶片条 20 轮里同格双击 \(stripSameCell) 次；swallow 计数已随 383 退役")
    }

    // MARK: - ③ 改写：单击只选中（不居中、不进编辑视角）

    func testThree_aSingleClickOnlySelects() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        strip.controller.reduceMotion = { false }      // 真有动画也不会滚，更容易看见
        placeStrip(strip, at: 0)
        let point = try stripPoint(strip, item: 5)
        let before = strip.controller.centerScrollCount
        let pressedAt = Date()

        XCTAssertEqual(strip.controller.handleMouseDown(at: point), .forward)
        let switchedAt = Date()
        XCTAssertEqual(session.anchorID, library.ids[5], "单击必须立即选中")
        let switchLatency = switchedAt.timeIntervalSince(pressedAt) * 1000
        XCTAssertLessThan(switchLatency, 50, "选中应在 1 个渲染周期内（实测 \(switchLatency) ms）")
        XCTAssertEqual(session.mode, .grid, "单击不进编辑视角（mode \(session.mode)）")
        XCTAssertEqual(strip.controller.centerScrollCount, before, "单击不居中")
        XCTAssertEqual(stripOffset(strip), 0, accuracy: 0.5, "单击不挪动条带")
        // 352 的「窗口之后再来一次居中」也不存在了：窗口过了、甚至 0.8 s 之后仍是 0。
        pump(0.8)
        XCTAssertEqual(strip.controller.centerScrollCount, before,
                       "窗口过后也不许补一次居中（实际 \(before) → \(strip.controller.centerScrollCount)）")

        // The left list, same measurement.
        let pane = try makePane(session)
        pane.controller.reduceMotion = { true }
        placePane(pane, at: 0)
        let rowPoint = try panePoint(pane, row: 5)
        let paneBefore = pane.controller.centerScrollCount
        let panePressedAt = Date()
        XCTAssertEqual(pane.controller.handleMouseDown(at: rowPoint), .forward)
        let paneLatency = Date().timeIntervalSince(panePressedAt) * 1000
        XCTAssertEqual(session.anchorID, library.ids[5])
        XCTAssertEqual(session.mode, .grid)
        XCTAssertEqual(pane.controller.centerScrollCount, paneBefore, "侧栏单击不居中")
        pump(0.8)
        XCTAssertEqual(pane.controller.centerScrollCount, paneBefore)
        note("352 ③ 改写：胶片条单击 → 选中 \(String(format: "%.1f", switchLatency)) ms、mode=\(session.mode)、居中计数 \(before) → \(strip.controller.centerScrollCount)（0.8 s 后仍 \(strip.controller.centerScrollCount)）；侧栏 选中 \(String(format: "%.1f", paneLatency)) ms、居中 \(paneBefore) → \(pane.controller.centerScrollCount)")
    }

    // MARK: - ④ 窗口外的两下都生效（窗口长度是读 `NSEvent.doubleClickInterval` 的）

    func testFour_twoPressesOutsideTheWindowBothTakeEffect() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        let interval = NSEvent.doubleClickInterval
        placeStrip(strip, at: 0)
        let p5 = try stripPoint(strip, item: 5)
        let p2 = try stripPoint(strip, item: 2)

        XCTAssertEqual(strip.controller.handleMouseDown(at: p2), .forward)
        let first = session.anchorID
        pump(interval + 0.15)
        XCTAssertEqual(strip.controller.handleMouseDown(at: p5), .forward,
                       "间隔 > 窗口的两下都该生效")
        XCTAssertEqual(first, library.ids[2])
        XCTAssertEqual(session.anchorID, library.ids[5], "第二下（窗口外）应选中第 5 张")

        // …and the window really is `NSEvent.doubleClickInterval`, not a constant: shrink it to 50 ms
        // and two presses 150 ms apart on different cells are two independent clicks.
        pump(interval + 0.1)      // the previous pair must expire before the shrunk window starts
        strip.controller.clickGuard.doubleClickInterval = { 0.05 }
        placeStrip(strip, at: 0)
        let s2 = try stripPoint(strip, item: 2)
        let s5 = try stripPoint(strip, item: 5)
        XCTAssertEqual(strip.controller.handleMouseDown(at: s2), .forward)
        pump(0.15)
        XCTAssertEqual(strip.controller.handleMouseDown(at: s5), .forward,
                       "窗口改成 50 ms 之后，150 ms 间隔的两下都生效（不是写死 250 ms）")
        XCTAssertEqual(session.anchorID, library.ids[5])
        strip.controller.clickGuard.doubleClickInterval = { NSEvent.doubleClickInterval }
        note("352 ④ 窗口 \(interval) s：第 2 张 → 第 5 张 都生效；窗口改成 50 ms 后 150 ms 间隔同样都生效")
    }

    // MARK: - ⑤ 同一格双击：进编辑模式，且只居中一次

    func testFive_sameCellDoubleClickOpensThePhotoAndCentresOnce() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        placeStrip(strip, at: 0)
        let point = try stripPoint(strip, item: 5)
        var opened: [String] = []
        strip.controller.onActivate = { [weak session] id in
            opened.append(id)
            session?.activate(id)
        }

        XCTAssertEqual(strip.controller.handleMouseDown(at: point), .forward)
        XCTAssertEqual(session.anchorID, library.ids[5])
        let count = strip.controller.centerScrollCount
        XCTAssertEqual(count, 0, "第一下只选中，不居中")
        XCTAssertEqual(strip.controller.handleMouseDown(at: point), .doubleClick)
        XCTAssertEqual(strip.controller.clickGuard.doubleClickCount, 1)

        // The verb AppKit's gesture recogniser runs — open the *first* photo, then centre once.
        strip.controller.activateItem(at: point)
        settle(2)
        XCTAssertEqual(opened, [library.ids[5]])
        XCTAssertEqual(session.mode, .loupe)
        XCTAssertEqual(strip.controller.centerScrollCount, count + 1, "双击进编辑视角时居中一次")

        pump(0.8)
        XCTAssertEqual(strip.controller.centerScrollCount, count + 1,
                       "只居中一次：延迟的那一次已随 352 退役（实际 \(count) → \(strip.controller.centerScrollCount)）")
        note("352 ⑤ 同格双击：选中 \((session.anchorID ?? "?").prefix(8))，mode=\(session.mode)，居中 \(count) → \(strip.controller.centerScrollCount)，打开 \(opened.first?.prefix(8) ?? "-")")
    }

    // MARK: - ⑥ 作废后改写：滚动之后编辑落地仍然只居中一次（没有 pendingCenter 可丢）

    func testSix_anEditLandsAndCentresOnceAfterAUserScroll() throws {
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

        // 用户真的滚了一下（没有 `beginOwnChange`，所以 `Activity` 记成用户的）。
        let count = filmstrip.centerScrollCount
        strip.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        settle(3)
        XCTAssertEqual(filmstrip.centerScrollCount, count, "用户滚动不该被拽回去 —— 也不该补一次居中")
        let parked = strip.contentView.bounds.origin.x
        pump(0.6)
        XCTAssertEqual(strip.contentView.bounds.origin.x, parked, accuracy: 0.5,
                       "用户的滚动位置必须留着（\(parked) → \(strip.contentView.bounds.origin.x)）")

        // 332 的「用户正在滚动」窗口过期之后，编辑落地仍然居中一次。
        pump(0.3)
        session.applyEdit { $0.light.exposure = 0.4 }
        let committedAt = Date()
        XCTAssertTrue(session.commitEdit(label: "曝光"))
        pump(0.15)
        XCTAssertEqual(filmstrip.centerScrollCount, count, "0.25 s 合并窗口内不许滚")
        let arrival = try XCTUnwrap(timeUntil(1.5) { filmstrip.centerScrollCount == count + 1 },
                                    "滚动之后编辑落地仍应居中一次")
        let elapsed = Date().timeIntervalSince(committedAt)
        XCTAssertGreaterThanOrEqual(elapsed, 0.24, "必须等 0.25 s 合并窗口，实际 \(elapsed) s")
        pump(0.8)
        XCTAssertEqual(filmstrip.centerScrollCount, count + 1,
                       "只居中一次（\(count) → \(filmstrip.centerScrollCount)）")
        note("352 ⑥ 作废→改写：用户滚到 \(parked) pt 停住（居中计数 \(count) 不变）；编辑落地 \(String(format: "%.3f", elapsed)) s 后滚 1 次（\(count) → \(filmstrip.centerScrollCount)），到达耗时 \(String(format: "%.3f", arrival)) s")
    }

    // MARK: - ⑦ 侧栏：同一组用例（①③⑤）各跑一遍的计数

    func testSeven_theLeftPaneObeysTheSameRule() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let pane = try makePane(session)

        // ① 端上的行：单击不居中 ⇒ 行不动 ⇒ 第二下还是同一行。
        placePane(pane, at: 0)
        pump(0.35)
        let last = try panePoint(pane, row: 5)
        let before = pane.controller.centerScrollCount
        XCTAssertEqual(pane.controller.handleMouseDown(at: last), .forward)
        XCTAssertEqual(session.anchorID, library.ids[5])
        XCTAssertEqual(session.mode, .grid, "侧栏单击不进编辑视角")
        XCTAssertEqual(pane.controller.centerScrollCount, before, "侧栏单击不居中")
        XCTAssertEqual(paneRow(pane, at: last), 5, "行没被挪走")
        pump(0.35)
        XCTAssertEqual(pane.controller.handleMouseDown(at: last), .doubleClick)
        XCTAssertEqual(session.anchorID, library.ids[5])

        // ⑤ 同一行两下 = 双击，进编辑视角、只居中一次，且打开的是这一张
        session.mode = .grid
        placePane(pane, at: 0)
        pump(0.35)
        let p6 = try panePoint(pane, row: 6)
        let count = pane.controller.centerScrollCount
        XCTAssertEqual(pane.controller.handleMouseDown(at: p6), .forward)
        XCTAssertEqual(pane.controller.handleMouseDown(at: p6), .doubleClick)
        XCTAssertEqual(pane.controller.centerScrollCount, count, "两下按下本身不居中")
        XCTAssertTrue(pane.controller.openRowInLoupe(6, assetID: session.anchorID))
        XCTAssertEqual(session.mode, .loupe)
        XCTAssertEqual(session.anchorID, library.ids[6])
        XCTAssertEqual(pane.controller.centerScrollCount, count + 1, "双击进编辑视角时居中一次")
        pump(0.8)
        XCTAssertEqual(pane.controller.centerScrollCount, count + 1, "同格双击只居中一次")

        // ③ 单击：只选中，不居中、不进编辑
        session.mode = .grid
        placePane(pane, at: 0)
        pump(0.35)
        let p7 = try panePoint(pane, row: 7)
        let single = pane.controller.centerScrollCount
        let pressedAt = Date()
        XCTAssertEqual(pane.controller.handleMouseDown(at: p7), .forward)
        let latency = Date().timeIntervalSince(pressedAt) * 1000
        XCTAssertEqual(session.anchorID, library.ids[7])
        XCTAssertEqual(session.mode, .grid)
        XCTAssertEqual(pane.controller.centerScrollCount, single)
        pump(0.8)
        XCTAssertEqual(pane.controller.centerScrollCount, single, "窗口过后也不补一次居中")

        // 窗口内点另一行：两下都生效（383 §2.3）
        session.mode = .grid
        let t = Date().addingTimeInterval(2.0)
        let a = try panePoint(pane, row: 3)
        let b = try panePoint(pane, row: 4)
        XCTAssertEqual(pane.controller.handleMouseDown(at: a, now: t), .forward)
        XCTAssertEqual(pane.controller.handleMouseDown(at: b, now: t.addingTimeInterval(0.1)), .forward,
                       "侧栏：窗口内命中另一行不再被吞")
        XCTAssertEqual(session.anchorID, library.ids[4], "第二下生效")

        note("352 ⑦ 侧栏：单击 → 选中 \(String(format: "%.1f", latency)) ms、mode=\(session.mode)、居中 \(single) → \(pane.controller.centerScrollCount)；双击居中 \(count) → \(count + 1)；窗口内点另一行两下都生效（最终选中 \((session.anchorID ?? "?").prefix(8))）")
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

    /// A point inside row `row`, in **table** coordinates (what `handleMouseDown(at:)` takes).
    private func panePoint(_ pane: Pane, row: Int) throws -> NSPoint {
        let rect = pane.table.rect(ofRow: row)
        guard rect.height > 0 else { throw XCTSkip("row \(row) has no frame") }
        return NSPoint(x: rect.midX, y: rect.midY)
    }

    private func paneRow(_ pane: Pane, at point: NSPoint) -> Int? {
        let row = pane.table.row(at: point)
        return row >= 0 ? row : nil
    }
}
