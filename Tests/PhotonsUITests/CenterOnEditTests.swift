import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 332 — an edit puts the current photo back in the middle of the filmstrip / left photo list.
///
/// The user's sentence is one rule with two views behind it: when a photo is edited, the strip and
/// the side list must **move to centre it** (or to the end when it is one of the last ones), with an
/// animation rather than a jump. The numbers here are that rule measured:
///
/// - 100 photos, an 800 pt viewport, 100 pt items → photo 50 lands on `50·100 + 50 − 400 = 4650`,
///   photo 0 on `0`, photo 99 on `contentWidth − 800` (the clamp: no blank space, no bounce);
/// - the call starts an animation, not a jump: the offset in the same turn is still the old one,
///   `NSAnimationContext` got 0.22 s, and the final value is in place 0.22 s ± 0.05 s later;
/// - already centred → the scroll is not issued at all (counter stays put);
/// - 「减弱动态效果」 → the same turn is already the final value, no animation;
/// - a scroll the user is driving is not fought over: that trigger is dropped and the next one works;
/// - the left list (vertical, `NSTableView`) obeys the same five;
/// - one real edit commit reaches both viewports 0.25 s later through 303's window.
@MainActor
final class CenterOnEditTests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-center332-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture: 100 photos

    private struct Library {
        let url: URL
        let ids: [String]
    }

    private func makeLibrary(count: Int = 100) throws -> Library {
        _ = NSApplication.shared
        let url = tmp.appendingPathComponent("center-\(UUID().uuidString).photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: url)
        let src = tmp.appendingPathComponent("src-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)
        var ids: [String] = []
        for index in 0..<count {
            let name = String(format: "IMG_%04d.dng", index)
            let file = src.appendingPathComponent(name)
            // A placeholder byte: the row exists, the thumbnail decode fails fast — this test is
            // about scrolling, not pixels.
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

    /// Seconds until `predicate` holds, pumping the run loop in 5 ms steps; nil after `limit`.
    private func timeUntil(_ limit: TimeInterval = 1.0, _ predicate: () -> Bool) -> TimeInterval? {
        let start = Date()
        while Date().timeIntervalSince(start) < limit {
            if predicate() { return Date().timeIntervalSince(start) }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return predicate() ? Date().timeIntervalSince(start) : nil
    }

    // MARK: - the filmstrip, at exactly 100 pt items and an 800 pt viewport

    private struct Strip {
        let controller: FilmstripController
        let scroll: NSScrollView
        let window: NSWindow
    }

    /// 100 pt wide cells: the strip derives the cell width from its own height (3:2 image area +
    /// 12 pt caption + 8/6 pt insets), so the container is that height for a 100 pt cell — the
    /// geometry the task states, produced by the shipping layout code rather than by a constant.
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
        // The task's numbers: no gap, no inset, so item i's middle is `i·100 + 50`.
        flow.minimumLineSpacing = 0
        flow.minimumInteritemSpacing = 0
        flow.sectionInset = NSEdgeInsets()
        flow.invalidateLayout()
        controller.collectionView.layoutSubtreeIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        settle(4)
        return Strip(controller: controller, scroll: scroll, window: window)
    }

    private func stripOffset(_ strip: Strip) -> CGFloat { strip.scroll.contentView.bounds.origin.x }

    private func stripTarget(_ strip: Strip, index: Int) throws -> CGFloat {
        let frame = try XCTUnwrap(strip.controller.collectionView
            .layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame)
        let content = try XCTUnwrap(strip.controller.collectionView.collectionViewLayout?.collectionViewContentSize.width)
        return CenteredScroll.target(itemMidpoint: frame.midX,
                                     contentLength: content,
                                     visibleLength: strip.scroll.contentView.bounds.width)
    }

    /// Put the viewport somewhere far from any centre *without* it counting as the user's scroll.
    private func placeStrip(_ strip: Strip, at offset: CGFloat) {
        strip.controller.scrollActivity.beginOwnChange()
        strip.scroll.contentView.setBoundsOrigin(NSPoint(x: offset, y: 0))
        settle(2)
    }

    // MARK: - ① centred

    func testOne_filmstripCentresTheAnchorPhoto() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)

        let visible = strip.scroll.contentView.bounds.width
        let content = try XCTUnwrap(strip.controller.collectionView.collectionViewLayout?.collectionViewContentSize.width)
        let cell = try XCTUnwrap(strip.controller.collectionView
            .layoutAttributesForItem(at: IndexPath(item: 0, section: 0))?.frame.size)
        let pitch = try XCTUnwrap(strip.controller.collectionView
            .layoutAttributesForItem(at: IndexPath(item: 1, section: 0))?.frame.minX)
        print("332 ① 可视 \(visible) pt, 内容 \(content) pt, 条目 \(cell.width)×\(cell.height) pt, 间距 \(pitch - cell.width) pt")

        session.selectOnly(library.ids[50])
        let started = strip.controller.centerAnchor()
        XCTAssertTrue(started, "第 50 张：应当有可滚动的几何")
        pump(0.4)

        let expected: CGFloat = 50 * 100 + 50 - 400   // 4650
        XCTAssertEqual(stripOffset(strip), expected, accuracy: 0.5,
                       "第 50 张应居中：偏移 \(stripOffset(strip)) ≠ 理论 \(expected)")
        print("332 ① 第 50 张偏移 \(stripOffset(strip)) pt（理论 \(expected)，差 \(abs(stripOffset(strip) - expected))）")
    }

    // MARK: - ② the ends

    func testTwo_filmstripPinsTheFirstAndLastPhotoToTheEnds() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        let content = try XCTUnwrap(strip.controller.collectionView.collectionViewLayout?.collectionViewContentSize.width)
        let visible = strip.scroll.contentView.bounds.width

        session.selectOnly(library.ids[0])
        strip.controller.centerAnchor()
        pump(0.4)
        XCTAssertEqual(stripOffset(strip), 0, accuracy: 0.5, "第 0 张必须贴左边，偏移 \(stripOffset(strip))")
        let first = stripOffset(strip)

        session.selectOnly(library.ids[99])
        strip.controller.centerAnchor()
        pump(0.4)
        let last = stripOffset(strip)
        XCTAssertEqual(last, content - visible, accuracy: 0.5,
                       "第 99 张必须贴右边：偏移 \(last) ≠ \(content - visible)")
        XCTAssertGreaterThanOrEqual(last, 0)
        XCTAssertLessThanOrEqual(last + visible, content + 0.5, "不许滚出内容区（出现空白）")

        // The clamp itself, not only AppKit's constrained result: a clip view would refuse to show
        // blank space anyway, but the *rule* has to ask for 0 / `content − visible`, or the two ends
        // would look 350 pt "not centred" and every trigger would keep scrolling into the wall.
        XCTAssertEqual(CenteredScroll.target(itemMidpoint: 50, contentLength: content, visibleLength: visible),
                       0, accuracy: 0.001, "第 0 张的目标偏移必须是 0")
        XCTAssertEqual(CenteredScroll.target(itemMidpoint: content - 50, contentLength: content, visibleLength: visible),
                       content - visible, accuracy: 0.001, "末张的目标偏移必须是 content − visible")

        // …and the consequence the user sees: standing on an end, a trigger is a no-op.
        let atEnd = strip.controller.centerScrollCount
        strip.controller.centerAnchor()
        pump(0.1)
        XCTAssertEqual(strip.controller.centerScrollCount, atEnd,
                       "贴边已是最终位置，再触发不该滚（计数 \(atEnd) → \(strip.controller.centerScrollCount)）")
        print("332 ② 第 0 张 \(first) pt；第 99 张 \(last) pt（理论 \(content - visible)）；内容 \(content) 可视 \(visible)；贴边后再触发计数 \(atEnd) → \(strip.controller.centerScrollCount)")
    }

    // MARK: - ③ animation, not a jump

    func testThree_filmstripAnimatesInsteadOfJumping() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        placeStrip(strip, at: 0)
        let target = try stripTarget(strip, index: 50)

        session.selectOnly(library.ids[50])
        strip.controller.centerAnchor()

        // Same turn: an `animator()` scroll has not reached its value yet — a jump would be there
        // already, which is exactly what the user said must not happen.
        let sameTurn = stripOffset(strip)
        XCTAssertNotEqual(sameTurn, target, accuracy: 0.5,
                          "同一帧就已经是最终值 —— 这是瞬移，不是动画（\(sameTurn)）")
        XCTAssertEqual(strip.controller.lastCenterAnimationDuration, 0.22, accuracy: 0.001,
                       "NSAnimationContext 的时长应为 0.22 s，实际 \(strip.controller.lastCenterAnimationDuration)")

        let arrival = try XCTUnwrap(timeUntil { abs(self.stripOffset(strip) - target) <= 0.5 },
                                    "0.22 s 之后没到位：\(stripOffset(strip)) vs \(target)")
        XCTAssertEqual(arrival, 0.22, accuracy: 0.05, "到达用时 \(arrival) s，应在 0.22 ± 0.05 s")
        print("332 ③ 同帧 \(sameTurn) pt ≠ 最终 \(target) pt；\(arrival) s 到位；duration 记录 \(strip.controller.lastCenterAnimationDuration) s")
    }

    // MARK: - ④ already centred: no scroll at all

    func testFour_alreadyCentredFilmstripDoesNotScroll() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)

        session.selectOnly(library.ids[50])
        strip.controller.centerAnchor()
        pump(0.4)
        let offset = stripOffset(strip)
        let count = strip.controller.centerScrollCount

        // The same anchor, three more triggers (a metadata refresh, an edit that did not move it).
        for _ in 0..<3 { strip.controller.centerAnchor() }
        pump(0.1)

        XCTAssertEqual(strip.controller.centerScrollCount, count, "已居中还应不动 —— 计数从 \(count) 变成 \(strip.controller.centerScrollCount)")
        XCTAssertEqual(stripOffset(strip), offset, accuracy: 0.001)
        XCTAssertLessThanOrEqual(abs(offset - (try stripTarget(strip, index: 50))), 2)
        print("332 ④ 已居中：偏移 \(offset) pt 不变，计数 \(count) → \(strip.controller.centerScrollCount)")
    }

    // MARK: - ⑤ reduce motion

    func testFive_reduceMotionJumpsInTheSameTurn() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)
        placeStrip(strip, at: 0)

        strip.controller.reduceMotion = { true }
        session.selectOnly(library.ids[50])
        let count = strip.controller.centerScrollCount
        strip.controller.centerAnchor()

        let target: CGFloat = 50 * 100 + 50 - 400
        XCTAssertEqual(stripOffset(strip), target, accuracy: 0.5,
                       "减弱动态效果：同一帧就应到位，实际 \(stripOffset(strip))")
        XCTAssertEqual(strip.controller.centerScrollCount, count + 1)
        XCTAssertEqual(strip.controller.lastCenterAnimationDuration, 0, "跳过去就没有动画时长")
        print("332 ⑤ reduceMotion：同帧 \(stripOffset(strip)) pt（理论 \(target)），动画时长 \(strip.controller.lastCenterAnimationDuration)")
    }

    // MARK: - ⑥ the user wins this time

    func testSix_aUserScrollIsNotOverwrittenAndTheNextTriggerWorks() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)

        // A drag/momentum move: the clip view moves without us moving it, which is the signal the
        // two controllers record in their bounds observer.
        strip.scroll.contentView.setBoundsOrigin(NSPoint(x: 1500, y: 0))
        settle(1)
        session.selectOnly(library.ids[50])
        let count = strip.controller.centerScrollCount
        strip.controller.centerAnchor()
        pump(0.1)

        XCTAssertEqual(stripOffset(strip), 1500, accuracy: 0.5,
                       "用户正在滚动时不许抢：偏移被改成了 \(stripOffset(strip))")
        XCTAssertEqual(strip.controller.centerScrollCount, count, "这一次应当整个放弃（计数不变）")

        // The user lets go; the next trigger is honoured.
        pump(0.2)
        strip.controller.centerAnchor()
        let arrival = try XCTUnwrap(timeUntil { abs(self.stripOffset(strip) - 4650) <= 0.5 })
        XCTAssertEqual(stripOffset(strip), 4650, accuracy: 0.5, "松手后的下一次应正常居中")
        print("332 ⑥ 拖动中停在 1500 pt（计数 \(count) 不变）；松手后 \(arrival) s 到 \(stripOffset(strip)) pt")
    }

    // MARK: - ⑦ the left photo list (vertical)

    private struct Pane {
        let controller: BrowserPaneController
        let table: NSTableView
        let scroll: NSScrollView
    }

    /// The shipping layout, tuned to the task's numbers: 100 pt rows, an 800 pt viewport.
    private func makePane(_ session: CatalogSession) throws -> Pane {
        let window = makeWindow()
        let controller = BrowserPaneController(session: session)
        let view = controller.view
        window.contentView?.addSubview(view)
        // `applyLayout` is the same code the window drives; widen the panel until the photo list is
        // exactly 800 pt tall (the tree takes 45 % of the panel, the rest is list).
        var height: CGFloat = 900
        var applied = controller.applyLayout(in: CGSize(width: 260, height: height))
        while controller.photoListHeight < 800 - 0.001, height < 4000 {
            height += 1
            applied = controller.applyLayout(in: CGSize(width: 260, height: height))
        }
        _ = applied
        settle(4)

        let table = controller.photoListForTesting
        table.rowHeight = 100
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.reloadData()
        controller.view.layoutSubtreeIfNeeded()
        settle(4)

        let scroll = try XCTUnwrap(table.enclosingScrollView)
        return Pane(controller: controller, table: table, scroll: scroll)
    }

    private func paneOffset(_ pane: Pane) -> CGFloat { pane.scroll.contentView.bounds.origin.y }

    func testSeven_leftPaneObeysTheSameFive() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let pane = try makePane(session)
        settle(4)
        let visible = pane.scroll.contentView.bounds.height
        let content = pane.table.bounds.height
        let row0 = pane.table.rect(ofRow: 0)
        let row1 = pane.table.rect(ofRow: 1)
        let row50 = pane.table.rect(ofRow: 50)
        // The table's `.sourceList` style insets its first row by 10 pt, so the row pitch is the
        // task's 100 pt but the arithmetic starts at that inset — measured, not assumed.
        let inset = row0.midY - 50
        let expected = row50.midY - visible / 2
        print("332 ⑦ 侧栏 可视 \(visible) pt, 内容 \(content) pt, 行高 \(pane.table.rowHeight) pt, 行距 \(row1.minY - row0.minY) pt, 首行内缩 \(inset) pt")

        XCTAssertEqual(row1.minY - row0.minY, 100, accuracy: 0.001, "行距应为 100 pt")
        XCTAssertEqual(row50.midY, 50 * 100 + 50 + inset, accuracy: 0.001)

        // ① centred
        session.selectOnly(library.ids[50])
        XCTAssertTrue(pane.controller.centerAnchor())
        pump(0.4)
        XCTAssertEqual(paneOffset(pane), expected, accuracy: 0.5,
                       "侧栏第 50 行应居中：\(paneOffset(pane)) ≠ \(expected)")

        // ④ already centred → no scroll
        let count = pane.controller.centerScrollCount
        pane.controller.centerAnchor()
        XCTAssertEqual(pane.controller.centerScrollCount, count, "侧栏已居中仍应不动")
        let countAfterCentred = pane.controller.centerScrollCount

        // ② the ends
        session.selectOnly(library.ids[0])
        pane.controller.centerAnchor()
        pump(0.4)
        XCTAssertEqual(paneOffset(pane), 0, accuracy: 0.5, "侧栏第 0 行贴顶：\(paneOffset(pane))")
        session.selectOnly(library.ids[99])
        pane.controller.centerAnchor()
        pump(0.4)
        XCTAssertEqual(paneOffset(pane), content - visible, accuracy: 0.5,
                       "侧栏第 99 行贴底：\(paneOffset(pane)) ≠ \(content - visible)")
        XCTAssertLessThanOrEqual(paneOffset(pane) + visible, content + 0.5)

        // ③ animation, not a jump
        pane.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        pump(0.2)
        session.selectOnly(library.ids[50])
        pane.controller.centerAnchor()
        let sameTurn = paneOffset(pane)
        XCTAssertNotEqual(sameTurn, expected, accuracy: 0.5, "侧栏也是瞬移？同帧 \(sameTurn)")
        XCTAssertEqual(pane.controller.lastCenterAnimationDuration, 0.22, accuracy: 0.001)
        let arrival = try XCTUnwrap(timeUntil { abs(self.paneOffset(pane) - expected) <= 0.5 })
        XCTAssertEqual(arrival, 0.22, accuracy: 0.05, "侧栏到达用时 \(arrival) s")

        // ⑤ reduce motion
        pane.controller.reduceMotion = { true }
        pane.scroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        pump(0.2)
        session.selectOnly(library.ids[50])
        pane.controller.centerAnchor()
        XCTAssertEqual(paneOffset(pane), expected, accuracy: 0.5, "侧栏 reduceMotion 同帧到位：\(paneOffset(pane))")
        XCTAssertEqual(pane.controller.lastCenterAnimationDuration, 0)

        print("332 ⑦ 侧栏：居中 \(expected) 已居中计数 \(count)→\(countAfterCentred)，两端 0 / \(content - visible)，同帧 \(sameTurn) 到达 \(arrival) s，reduceMotion 同帧 \(paneOffset(pane))")
    }

    // MARK: - ⑧ one edit commit reaches both viewports after 303's window

    func testEight_anEditCommitCentresTheAnchorAfterTheWindow() throws {
        let library = try makeLibrary()
        let session = try makeSession(library)
        let window = makeWindow(CGSize(width: 1600, height: 1000))
        let root = WorkspaceRootView(session: session)
        root.frame = NSRect(x: 0, y: 0, width: 1600, height: 1000)
        window.contentView?.addSubview(root)
        root.layoutSubtreeIfNeeded()
        settle(6)

        // The strip is the bottom surface in filmstrip mode; the panel's photo list in list mode.
        // One at a time is how the workspace actually shows them.
        root.setBrowserMode(.filmstrip)
        root.layoutSubtreeIfNeeded()
        settle(6)
        let strip = try XCTUnwrap(root.filmstripController.view as? NSScrollView)

        session.selectOnly(library.ids[50])
        pump(0.4)
        let visible = strip.contentView.bounds.width
        XCTAssertGreaterThan(visible, 0, "胶片条应有可视宽度")

        // Leave the strip somewhere else by hand and let the "the user was scrolling" window expire,
        // so the edit is not mistaken for fighting the user.
        root.filmstripController.scrollActivity.beginOwnChange()
        strip.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        pump(0.2)

        let stripCount = root.filmstripController.centerScrollCount
        // One edit commit — the document changes and is persisted, exactly as a slider release does.
        session.applyEdit { $0.light.exposure = 0.75 }
        let committedAt = Date()
        XCTAssertTrue(session.commitEdit(label: "曝光"), "这次编辑应当落地")

        // Nothing before the window closes…
        pump(0.15)
        XCTAssertEqual(root.filmstripController.centerScrollCount, stripCount, "0.25 s 之前不许滚")
        // …and exactly one scroll after it.
        try XCTUnwrap(timeUntil(1.0) { root.filmstripController.centerScrollCount == stripCount + 1 },
                      "0.25 s 合并窗口关掉后应当滚动一次")
        let elapsed = Date().timeIntervalSince(committedAt)
        XCTAssertGreaterThan(elapsed, 0.24, "滚动必须等 0.25 s 的合并窗口，实际 \(elapsed) s")
        XCTAssertLessThan(elapsed, 0.5, "合并窗口不应拖长，实际 \(elapsed) s")
        XCTAssertEqual(root.filmstripController.centerScrollCount, stripCount + 1,
                       "一次编辑只滚一次（0.25 s 合并窗口），实际 \(stripCount) → \(root.filmstripController.centerScrollCount)")
        pump(0.4)

        let stripFrame = try XCTUnwrap(root.filmstripController.collectionView
            .layoutAttributesForItem(at: IndexPath(item: 50, section: 0))?.frame)
        let stripContent = try XCTUnwrap(root.filmstripController.collectionView
            .collectionViewLayout?.collectionViewContentSize.width)
        let stripTarget = CenteredScroll.target(itemMidpoint: stripFrame.midX,
                                                contentLength: stripContent,
                                                visibleLength: visible)
        XCTAssertEqual(strip.contentView.bounds.origin.x, stripTarget, accuracy: 0.5,
                       "编辑落地后胶片条应居中：\(strip.contentView.bounds.origin.x) ≠ \(stripTarget)")

        // The left list gets the same tick: switch to list mode, move it away, edit again.
        root.setBrowserMode(.list)
        root.layoutSubtreeIfNeeded()
        settle(6)
        let pane = root.browserPane
        let listScroll = try XCTUnwrap(pane.photoListForTesting.enclosingScrollView)
        session.selectOnly(library.ids[50])
        pump(0.4)
        pane.scrollActivity.beginOwnChange()
        listScroll.contentView.setBoundsOrigin(NSPoint(x: 0, y: 0))
        pump(0.2)
        let paneCount = pane.centerScrollCount

        session.applyEdit { $0.light.contrast = 12 }
        XCTAssertTrue(session.commitEdit(label: "对比度"))
        _ = try XCTUnwrap(timeUntil(1.0) { pane.centerScrollCount == paneCount + 1 },
                          "侧栏应当在同一 0.25 s 窗口后滚动一次")
        pump(0.4)

        let row = pane.photoListForTesting.rect(ofRow: 50)
        let paneTarget = CenteredScroll.target(itemMidpoint: row.midY,
                                              contentLength: pane.photoListForTesting.bounds.height,
                                              visibleLength: listScroll.contentView.bounds.height)
        XCTAssertEqual(listScroll.contentView.bounds.origin.y, paneTarget, accuracy: 0.5,
                       "编辑落地后侧栏应居中：\(listScroll.contentView.bounds.origin.y) ≠ \(paneTarget)")
        print("332 ⑧ 编辑提交 → \(String(format: "%.3f", elapsed)) s 后胶片条滚 1 次到 \(strip.contentView.bounds.origin.x) pt（目标 \(stripTarget)）；侧栏计数 \(paneCount) → \(pane.centerScrollCount)，偏移 \(listScroll.contentView.bounds.origin.y) pt（目标 \(paneTarget)）")
    }
}
