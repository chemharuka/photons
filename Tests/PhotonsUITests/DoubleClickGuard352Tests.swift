import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 352 — 双击胶片条/侧栏照片被「单击切图 + 332 自动回中」抢走：第二下落到**另一张**上。
///
/// 用户口径：单击就切图，然后自动把选中的照片挪回中间，于是第二下命中的是另一张。
///
/// 这里量的是 `BrowserClickGuard` 那一条规则在两处界面上的同一份实现：
///
/// - **按下时**记命中项（index + 资产 id），窗口取 `NSEvent.doubleClickInterval`（读，不写死）；
/// - 窗口内第二下命中**不同**格子 ⇒ 整次按下被吞（不改选中、不切图）；
/// - 同一格子的第二下 = 双击，照旧进编辑模式，且只居中一次；
/// - 选中后居中挂到 `pendingCenter`，延迟一个双击窗口；双击则立即执行一次（仍只居中）；
/// - 窗口内用户自己滚动了 ⇒ `pendingCenter` 丢弃，不把视图拽回去；
/// - 单击手感不变：切图立即，只有居中动画的**起点**被推到窗口之后。
@MainActor
final class DoubleClickGuard352Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-dbl352-\(UUID().uuidString)", isDirectory: true)
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
        // The centre timing is what ③ measures, not the animation curve: jump so nothing is in flight
        // while a test moves the viewport by hand. ③ switches it back on.
        controller.reduceMotion = { true }
        return Strip(controller: controller, scroll: scroll)
    }

    private func stripOffset(_ strip: Strip) -> CGFloat { strip.scroll.contentView.bounds.origin.x }

    private func placeStrip(_ strip: Strip, at offset: CGFloat) {
        strip.controller.scrollActivity.beginOwnChange()
        strip.scroll.contentView.setBoundsOrigin(NSPoint(x: offset, y: 0))
        settle(2)
    }

    /// A window-space point inside item `item` right now; `dx` moves it within the cell (a click
    /// near an edge is where a small drift crosses into the neighbour).
    private func stripWindowPoint(_ strip: Strip, item: Int, dx: CGFloat = 0) throws -> NSPoint {
        let frame = try XCTUnwrap(strip.controller.collectionView
            .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame)
        return strip.controller.collectionView.convert(NSPoint(x: frame.midX + dx, y: frame.midY), to: nil)
    }

    /// The same window point, resolved against the strip **as it is now** — what the second press of
    /// a double-click sees after the viewport moved.
    private func stripLocalPoint(_ strip: Strip, window point: NSPoint) -> NSPoint {
        strip.controller.collectionView.convert(point, from: nil)
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

    /// The offset 332's rule asks for, computed the way the controller computes it.
    private func stripTarget(_ strip: Strip, item: Int) throws -> CGFloat {
        let frame = try XCTUnwrap(strip.controller.collectionView
            .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame)
        let content = try XCTUnwrap(strip.controller.collectionView.collectionViewLayout?
            .collectionViewContentSize.width)
        let visible = strip.scroll.contentView.bounds.width
        let layout = try XCTUnwrap(strip.controller.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
        note("352 ① debug itemSize=\(layout.itemSize) inset=\(layout.sectionInset) lineSpacing=\(layout.minimumLineSpacing) content=\(content) visible=\(visible) frame=\(frame)")
        return CenteredScroll.target(itemMidpoint: frame.midX, contentLength: content, visibleLength: visible)
    }

    private func clearPending(_ guardObject: BrowserClickGuard) {
        guardObject.dropCenter()
    }

    // MARK: - ① 用户场景：两端（会被回中挪动）的格子，双击后仍是第一下那张

    func testOne_doubleClickOnAnEndCellKeepsTheFirstPressPhoto() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)

        // 条带的一端：第 5 张靠视口右边按下，332 的居中把它挪到中间（0 → 150 pt），指针底下换成
        // 第 7 张 —— 用户报的「第二次点击就跳到下一个照片上」。
        placeStrip(strip, at: 0)
        pump(0.35)   // 332's own tests do this too: our own change window must be over
        let near = try stripWindowPoint(strip, item: 5, dx: 40)
        let nearFirst = stripItem(strip, at: stripLocalPoint(strip, window: near))
        XCTAssertEqual(nearFirst, 5, "precondition：按下的点是第 5 格")

        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: near)), .forward)
        XCTAssertEqual(session.anchorID, library.ids[5], "第一下命中的是第 5 张")

        // 332 的居中落地（修复前它就在第一下之后立刻发生；修复后它挂在 pendingCenter 上，
        // 这一行是那条动画真正跑起来的样子）。它把指针底下的格子挪走了 —— 这就是根因。
        XCTAssertTrue(strip.controller.centerAnchor())
        settle(3)
        let nearTarget = try stripTarget(strip, item: 5)
        XCTAssertEqual(stripOffset(strip), nearTarget, accuracy: 0.5,
                       "居中落地后偏移应到 \(nearTarget)（实测 \(stripOffset(strip))）")
        let nearSecond = stripItem(strip, at: stripLocalPoint(strip, window: near))
        XCTAssertNotEqual(nearSecond, nearFirst,
                          "居中把指针底下的格子换掉了（\(String(describing: nearFirst)) → \(String(describing: nearSecond))）")
        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: near)), .swallow,
                       "窗口内命中另一格 ⇒ 整次按下被吞")
        XCTAssertEqual(session.anchorID, library.ids[5], "第二下不许把选中带跑")
        XCTAssertEqual(session.selection, [library.ids[5]])

        // 另一端（内容末端贴边那一侧），同一条规则。
        placeStrip(strip, at: 9200)
        pump(0.35)
        let far = try stripWindowPoint(strip, item: 95, dx: -40)
        let farFirst = stripItem(strip, at: stripLocalPoint(strip, window: far))
        XCTAssertEqual(farFirst, 95, "precondition：按下的点是第 95 格")
        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: far)), .forward)
        XCTAssertEqual(session.anchorID, library.ids[95])
        strip.controller.centerAnchor()
        settle(3)
        let farSecond = stripItem(strip, at: stripLocalPoint(strip, window: far))
        XCTAssertNotEqual(farSecond, farFirst, "另一端：居中同样把指针底下的格子换掉了")
        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: far)), .swallow)
        XCTAssertEqual(session.anchorID, library.ids[95])

        // …and the left photo list, same two presses, same answer.
        let pane = try makePane(session)
        placePane(pane, at: 0)
        pump(0.35)
        let rowPoint = try paneWindowPoint(pane, row: 5)
        let paneFirst = paneRow(pane, at: paneLocal(pane, window: rowPoint))
        XCTAssertEqual(paneFirst, 5, "precondition：按下的点是第 5 行")
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: rowPoint)), .forward)
        XCTAssertEqual(session.anchorID, library.ids[5])
        pane.controller.centerAnchor()
        settle(3)
        let paneSecond = paneRow(pane, at: paneLocal(pane, window: rowPoint))
        XCTAssertNotEqual(paneSecond, paneFirst, "侧栏居中把指针底下的行换掉了")
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: rowPoint)), .swallow,
                       "侧栏：窗口内命中另一行 ⇒ 吞掉")
        XCTAssertEqual(session.anchorID, library.ids[5], "侧栏：第二下不许改选中")
        note("352 ① 胶片条 index path \(nearFirst ?? -1) → \(nearSecond ?? -1)（另一端 \(farFirst ?? -1) → \(farSecond ?? -1)）；最终选中 \(session.anchorID ?? "?")（第一下 \(library.ids[5])）")
        note("352 ① 侧栏 行 \(paneFirst ?? -1) → \(paneSecond ?? -1)；选中 \(session.anchorID ?? "?")（第一下 \(library.ids[5])）")
        note("352 ① 计数 胶片条 forward \(strip.controller.clickGuard.forwardCount)/swallow \(strip.controller.clickGuard.swallowCount)；侧栏 forward \(pane.controller.clickGuard.forwardCount)/swallow \(pane.controller.clickGuard.swallowCount)")
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
        var rows: [String] = []

        for round in 1...20 {
            clearPending(strip.controller.clickGuard)
            // A random place in the strip, a random cell that is visible there, a random drift of the
            // viewport between the two presses (0 – 90 pt, either way) — the drift is the whole bug.
            let target = 1 + rng.next(98)
            let offset = min(max(0, target * 100 + 50 - 400 + (rng.next(600) - 300)), 9200)
            placeStrip(strip, at: CGFloat(offset))
            let point = try stripWindowPoint(strip, item: target)
            let firstHit = stripItem(strip, at: stripLocalPoint(strip, window: point)) ?? -1
            let press1 = strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: point))
            let drift = rng.next(180) - 90
            strip.controller.scrollActivity.beginOwnChange()
            strip.scroll.contentView.setBoundsOrigin(NSPoint(x: CGFloat(offset + drift), y: 0))
            settle(1)
            let secondHit = stripItem(strip, at: stripLocalPoint(strip, window: point)) ?? -1
            let press2 = strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: point))
            XCTAssertEqual(press1, .forward, "第 \(round) 轮第一下应当选中")
            if secondHit != firstHit {
                XCTAssertEqual(press2, .swallow, "第 \(round) 轮第二下命中不同格（\(firstHit) → \(secondHit)），应吞掉")
            }
            let final = session.anchorID ?? "?"
            let switched = final != library.ids[target]
            if switched { stripUnintended += 1 }
            rows.append("\(round). 目标 \(target) 第一下 \(firstHit) 第二下 \(secondHit) 漂移 \(drift) → 选中 \(final.prefix(8)) 切换 \(switched ? "是" : "否")")
            XCTAssertFalse(switched, "第 \(round) 轮：双击第 \(target) 张却选中了 \(final)")
            clearPending(strip.controller.clickGuard)   // no late centre may move the next round's strip
        }

        // The same 20, on the left photo list.
        let pane = try makePane(session)
        var paneUnintended = 0
        var paneRows: [String] = []
        for round in 1...20 {
            clearPending(pane.controller.clickGuard)
            let target = 1 + rng.next(98)
            let offset = min(max(0, target * 100 + 60 - 400 + (rng.next(400) - 200)), 9200)
            placePane(pane, at: CGFloat(offset))
            let point = try paneWindowPoint(pane, row: target)
            let firstHit = paneRow(pane, at: paneLocal(pane, window: point)) ?? -1
            XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: point)), .forward)
            let drift = rng.next(200) - 100
            pane.controller.scrollActivity.beginOwnChange()
            pane.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: CGFloat(offset + drift)))
            settle(1)
            let secondHit = paneRow(pane, at: paneLocal(pane, window: point)) ?? -1
            let decision = pane.controller.handleMouseDown(at: paneLocal(pane, window: point))
            if secondHit != firstHit {
                XCTAssertEqual(decision, .swallow, "侧栏第 \(round) 轮：命中不同行（\(firstHit) → \(secondHit)）应吞掉")
            }
            let final = session.anchorID ?? "?"
            let switched = final != library.ids[target]
            if switched { paneUnintended += 1 }
            paneRows.append("\(round). 目标 \(target) 第一下 \(firstHit) 第二下 \(secondHit) 漂移 \(drift) → 选中 \(final.prefix(8)) 切换 \(switched ? "是" : "否")")
            XCTAssertFalse(switched, "侧栏第 \(round) 轮：双击第 \(target) 张却选中了 \(final)")
            clearPending(pane.controller.clickGuard)
        }

        XCTAssertEqual(stripUnintended, 0, "胶片条 unintendedSwitch 应为 0，实际 \(stripUnintended)")
        XCTAssertEqual(paneUnintended, 0, "侧栏 unintendedSwitch 应为 0，实际 \(paneUnintended)")
        note("352 ② 双击窗口 \(interval) s")
        for row in rows { note("352 ② 胶片条 \(row)") }
        for row in paneRows { note("352 ② 侧栏 \(row)") }
        note("352 ② unintendedSwitch：胶片条 \(stripUnintended)/20，侧栏 \(paneUnintended)/20；swallow 计数 胶片条 \(strip.controller.clickGuard.swallowCount) 侧栏 \(pane.controller.clickGuard.swallowCount)")
    }

    // MARK: - ③ 单击不变：切图立即，居中动画起点 ≥ 双击窗口

    func testThree_singleClickSwitchesAtOnceAndCentresAfterTheWindow() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        strip.controller.reduceMotion = { false }      // 这一条量的是动画的起点，所以要真有动画
        let interval = NSEvent.doubleClickInterval
        placeStrip(strip, at: 0)
        let point = try stripWindowPoint(strip, item: 5)
        let before = strip.controller.centerScrollCount
        let pressedAt = Date()

        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: point)), .forward)
        let switchedAt = Date()
        XCTAssertEqual(session.anchorID, library.ids[5], "单击必须立即切图")
        let switchLatency = switchedAt.timeIntervalSince(pressedAt) * 1000
        XCTAssertLessThan(switchLatency, 50, "切图应在 1 个渲染周期内（实测 \(switchLatency) ms）")
        XCTAssertEqual(strip.controller.centerScrollCount, before, "点下去不许立刻居中")
        XCTAssertEqual(stripOffset(strip), 0, accuracy: 0.5, "点下去不许立刻挪动条带")

        let arrival = try XCTUnwrap(timeUntil { strip.controller.centerScrollCount == before + 1 },
                                    "窗口之后应当居中一次")
        let fireDelta = try XCTUnwrap(strip.controller.clickGuard.lastCenterFiredAt)
            .timeIntervalSince(pressedAt)
        XCTAssertGreaterThanOrEqual(arrival, interval - 0.01, "居中起点 \(arrival) s 早于双击窗口 \(interval) s")
        XCTAssertGreaterThanOrEqual(fireDelta, interval - 0.01, "居中时间戳差 \(fireDelta) s 早于窗口")
        XCTAssertEqual(strip.controller.clickGuard.centerScheduledCount, 1)
        XCTAssertEqual(strip.controller.centerScrollCount, before + 1)

        // The left list, same measurement.
        let pane = try makePane(session)
        pane.controller.reduceMotion = { true }
        placePane(pane, at: 0)
        let rowPoint = try paneWindowPoint(pane, row: 5)
        let paneBefore = pane.controller.centerScrollCount
        let panePressedAt = Date()
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: rowPoint)), .forward)
        let paneLatency = Date().timeIntervalSince(panePressedAt) * 1000
        XCTAssertEqual(session.anchorID, library.ids[5])
        XCTAssertEqual(pane.controller.centerScrollCount, paneBefore, "侧栏点下去不许立刻居中")
        let paneArrival = try XCTUnwrap(timeUntil { pane.controller.centerScrollCount == paneBefore + 1 })
        XCTAssertGreaterThanOrEqual(paneArrival, interval - 0.01, "侧栏居中 \(paneArrival) s 早于窗口")
        note("352 ③ 胶片条：切图 \(String(format: "%.1f", switchLatency)) ms；居中起点 \(String(format: "%.3f", fireDelta)) s ≥ 窗口 \(interval) s（计数 \(before) → \(strip.controller.centerScrollCount)，duration \(strip.controller.lastCenterAnimationDuration) s）")
        note("352 ③ 侧栏：切图 \(String(format: "%.1f", paneLatency)) ms；居中起点 \(String(format: "%.3f", paneArrival)) s ≥ 窗口 \(interval) s（计数 \(paneBefore) → \(pane.controller.centerScrollCount)）")
    }

    // MARK: - ④ 窗口外的两下都生效（窗口长度是读 `NSEvent.doubleClickInterval` 的）

    func testFour_twoPressesOutsideTheWindowBothTakeEffect() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        let interval = NSEvent.doubleClickInterval
        placeStrip(strip, at: 0)
        let p5 = try stripWindowPoint(strip, item: 5)
        let p2 = try stripWindowPoint(strip, item: 2)

        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: p2)), .forward)
        let first = session.anchorID
        pump(interval + 0.15)
        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: p5)), .forward,
                       "间隔 > 窗口的两下都该生效")
        XCTAssertEqual(first, library.ids[2])
        XCTAssertEqual(session.anchorID, library.ids[5], "第二下（窗口外）应选中第 5 张")
        XCTAssertEqual(strip.controller.clickGuard.swallowCount, 0, "窗口外不许吞")

        // …and the window really is `NSEvent.doubleClickInterval`, not a constant: shrink it to 50 ms
        // and two presses 150 ms apart on different cells both take effect.
        pump(interval + 0.1)      // the previous pair must expire before the shrunk window starts
        strip.controller.clickGuard.doubleClickInterval = { 0.05 }
        placeStrip(strip, at: 0)
        let s2 = try stripWindowPoint(strip, item: 2)
        let s5 = try stripWindowPoint(strip, item: 5)
        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: s2)), .forward)
        pump(0.15)
        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: s5)), .forward,
                       "窗口改成 50 ms 之后，150 ms 间隔的两下都生效（不是写死 250 ms）")
        XCTAssertEqual(session.anchorID, library.ids[5])
        XCTAssertEqual(strip.controller.clickGuard.swallowCount, 0)
        strip.controller.clickGuard.doubleClickInterval = { NSEvent.doubleClickInterval }
        note("352 ④ 窗口 \(interval) s：第 2 张 → 第 5 张 都生效；窗口改成 50 ms 后 150 ms 间隔同样都生效；swallow 0")
    }

    // MARK: - ⑤ 同一格双击：进编辑模式，且只居中一次

    func testFive_sameCellDoubleClickOpensThePhotoAndCentresOnce() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        placeStrip(strip, at: 0)
        let point = try stripWindowPoint(strip, item: 5)
        var opened: [String] = []
        strip.controller.onActivate = { opened.append($0) }

        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: point)), .forward)
        XCTAssertEqual(session.anchorID, library.ids[5])
        let count = strip.controller.centerScrollCount
        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: point)), .doubleClick)
        XCTAssertEqual(strip.controller.clickGuard.doubleClickCount, 1)
        XCTAssertEqual(strip.controller.centerScrollCount, count + 1, "双击当刻居中一次（flush）")
        XCTAssertEqual(strip.controller.clickGuard.centerFlushedCount, 1)

        // The verb AppKit's gesture recogniser runs — the double-click opened the *first* photo.
        strip.controller.activateItem(at: stripLocalPoint(strip, window: point))
        XCTAssertEqual(opened, [library.ids[5]])

        pump(0.8)
        XCTAssertEqual(strip.controller.centerScrollCount, count + 1, "只居中一次，窗口过后不再来第二次")
        XCTAssertEqual(strip.controller.clickGuard.centerFiredCount, 0, "flush 之后不应再有延迟的那一次")
        note("352 ⑤ 同格双击：选中 \((session.anchorID ?? "?").prefix(8))，居中 \(count) → \(strip.controller.centerScrollCount)，flush \(strip.controller.clickGuard.centerFlushedCount)，打开 \(opened.first?.prefix(8) ?? "-")")
    }

    // MARK: - ⑥ 延迟期间用户手动滚动：pendingCenter 丢弃，不拽回去

    func testSix_aUserScrollDuringTheWindowDropsThePendingCentre() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        placeStrip(strip, at: 300)
        pump(0.35)
        let point = try stripWindowPoint(strip, item: 5)
        let count = strip.controller.centerScrollCount

        XCTAssertEqual(strip.controller.handleMouseDown(at: stripLocalPoint(strip, window: point)), .forward)
        XCTAssertTrue(strip.controller.clickGuard.hasPendingCenter, "选中之后应挂着一次待居中")

        // A drag: the clip view moves without us moving it — `Activity` records it as the user's.
        strip.scroll.contentView.setBoundsOrigin(NSPoint(x: 900, y: 0))
        settle(2)
        XCTAssertFalse(strip.controller.clickGuard.hasPendingCenter, "用户一滚，待居中就该丢弃")
        XCTAssertEqual(strip.controller.clickGuard.centerDropCount, 1)
        let afterScroll = stripOffset(strip)
        pump(NSEvent.doubleClickInterval + 0.4)
        XCTAssertEqual(stripOffset(strip), afterScroll, accuracy: 0.5,
                       "丢弃之后不许把视图拽回中间（\(afterScroll) → \(stripOffset(strip))）")
        XCTAssertEqual(strip.controller.centerScrollCount, count, "这一次整个放弃")

        // The left list, same rule.
        let pane = try makePane(session)
        placePane(pane, at: 300)
        pump(0.35)
        let rowPoint = try paneWindowPoint(pane, row: 5)
        let paneCount = pane.controller.centerScrollCount
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: rowPoint)), .forward)
        XCTAssertTrue(pane.controller.clickGuard.hasPendingCenter)
        pane.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 900))
        settle(2)
        XCTAssertFalse(pane.controller.clickGuard.hasPendingCenter, "侧栏：用户一滚就丢弃")
        let paneAfter = pane.scroll.contentView.bounds.origin.y
        pump(0.6)
        XCTAssertEqual(pane.scroll.contentView.bounds.origin.y, paneAfter, accuracy: 0.5)
        XCTAssertEqual(pane.controller.centerScrollCount, paneCount)
        note("352 ⑥ 胶片条 \(afterScroll) pt 停住（丢弃 \(strip.controller.clickGuard.centerDropCount) 次，居中计数 \(count) 不变）；侧栏 \(paneAfter) pt 停住（丢弃 \(pane.controller.clickGuard.centerDropCount) 次）")
    }

    // MARK: - ⑦ 侧栏：同一组用例（①③⑤⑥）各跑一遍的计数

    func testSeven_theLeftPaneObeysTheSameRule() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let pane = try makePane(session)
        let interval = NSEvent.doubleClickInterval

        // ① 端上的行：居中会把它挪走（第 5 行 560 → 160 pt，指针底下换成第 7 行）⇒ 第二下吞掉
        placePane(pane, at: 0)
        pump(0.35)
        let last = try paneWindowPoint(pane, row: 5)
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: last)), .forward)
        XCTAssertEqual(session.anchorID, library.ids[5])
        pane.controller.centerAnchor()
        settle(2)
        let drifted = paneRow(pane, at: paneLocal(pane, window: last))
        note("352 ⑦ debug 居中后指针下的行 \(String(describing: drifted)) 偏移 \(pane.scroll.contentView.bounds.origin.y)")
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: last)), .swallow)
        XCTAssertEqual(session.anchorID, library.ids[5])
        let swallowCount = pane.controller.clickGuard.swallowCount

        // ⑤ 同一行两下 = 双击，只居中一次，且打开的是这一张
        clearPending(pane.controller.clickGuard)
        placePane(pane, at: 0)
        pump(0.35)
        let p5 = try paneWindowPoint(pane, row: 6)
        let count = pane.controller.centerScrollCount
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: p5)), .forward)
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: p5)), .doubleClick)
        XCTAssertEqual(pane.controller.centerScrollCount, count + 1)
        XCTAssertTrue(pane.controller.openRowInLoupe(6, assetID: session.anchorID))
        XCTAssertEqual(session.mode, .loupe)
        XCTAssertEqual(session.anchorID, library.ids[6])
        pump(0.8)
        XCTAssertEqual(pane.controller.centerScrollCount, count + 1, "同格双击只居中一次")

        // ③ 单击：立即切图，居中起点 ≥ 窗口
        session.mode = .grid
        clearPending(pane.controller.clickGuard)
        placePane(pane, at: 0)
        pump(0.35)
        let p7 = try paneWindowPoint(pane, row: 7)
        let before = pane.controller.centerScrollCount
        let pressedAt = Date()
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: p7)), .forward)
        let latency = Date().timeIntervalSince(pressedAt) * 1000
        XCTAssertEqual(session.anchorID, library.ids[7])
        XCTAssertEqual(pane.controller.centerScrollCount, before)
        let arrival = try XCTUnwrap(timeUntil { pane.controller.centerScrollCount == before + 1 })
        XCTAssertGreaterThanOrEqual(arrival, interval - 0.01)

        // ⑥ 窗口内用户滚动 ⇒ 丢弃
        clearPending(pane.controller.clickGuard)
        placePane(pane, at: 0)
        pump(0.35)
        let p3 = try paneWindowPoint(pane, row: 3)
        XCTAssertEqual(pane.controller.handleMouseDown(at: paneLocal(pane, window: p3)), .forward)
        XCTAssertTrue(pane.controller.clickGuard.hasPendingCenter)
        pane.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 1200))
        settle(2)
        XCTAssertFalse(pane.controller.clickGuard.hasPendingCenter)
        let parked = pane.scroll.contentView.bounds.origin.y
        pump(0.6)
        XCTAssertEqual(pane.scroll.contentView.bounds.origin.y, parked, accuracy: 0.5)

        note("352 ⑦ 侧栏：swallow \(swallowCount)，切图 \(String(format: "%.1f", latency)) ms，居中起点 \(String(format: "%.3f", arrival)) s ≥ 窗口 \(interval) s，丢弃 \(pane.controller.clickGuard.centerDropCount) 次，同格双击居中 \(count) → \(count + 1)")
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

    private func paneWindowPoint(_ pane: Pane, row: Int) throws -> NSPoint {
        let rect = pane.table.rect(ofRow: row)
        guard rect.height > 0 else { throw XCTSkip("row \(row) has no frame") }
        return pane.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }

    private func paneLocal(_ pane: Pane, window point: NSPoint) -> NSPoint {
        pane.table.convert(point, from: nil)
    }

    private func paneRow(_ pane: Pane, at point: NSPoint) -> Int? {
        let row = pane.table.row(at: point)
        return row >= 0 ? row : nil
    }
}
