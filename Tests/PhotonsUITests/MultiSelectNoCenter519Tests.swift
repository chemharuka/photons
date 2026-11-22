import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 519 — 胶片条的 ⇧/⌘ 多选与单击同一口径：**只改选择，不居中**。
///
/// 用户 2026-11-22：「按住 command 后选择文件，胶片条会自动将最后选择的图片居中」。
/// 383 立下的规则是「选择手势不居中，居中的入口只剩显式动作」，但 `handleSelectionClick`
/// 这条 ⇧/⌘ 门漏了，末尾仍调 `centerAnchorIfChanged()` —— 每 ⌘ 点一次、每 ⇧ 拉一次范围都滚一次。
///
/// 判据是计数器 `centerScrollCount` 的**增量**，不是「看起来没跳」。
/// ④ 是反向确认：`centreForLoupeEntry()` 的增量必须仍是 1，证明计数本身是活的。
@MainActor
final class MultiSelectNoCenter519Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-519-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture (383's shape: real catalog, 100 pt items, 800 pt viewport)

    private struct Library {
        let url: URL
        let ids: [String]
    }

    private func makeLibrary(count: Int = 24) throws -> Library {
        _ = NSApplication.shared
        let url = tmp.appendingPathComponent("s519-\(UUID().uuidString).photonslibrary", isDirectory: true)
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

    private func settle(_ turns: Int = 6) {
        for _ in 0..<turns { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: - the strip

    private struct Strip {
        let controller: FilmstripController
        let scroll: NSScrollView
    }

    private static let stripHeight: CGFloat = 100 / WorkspaceLayout.filmstripAspect + 12 + 8 + 6
    private static let viewport: CGFloat = 800
    private static let pitch: CGFloat = 100
    private static let libraryCount = 24

    private func makeStrip(_ session: CatalogSession) throws -> Strip {
        let window = makeWindow()
        let controller = FilmstripController(session: session)
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
        // Timing is what the acceptance measures, not the animation curve: jump, so nothing is in
        // flight while the test moves the viewport by hand.
        controller.reduceMotion = { true }
        return Strip(controller: controller, scroll: scroll)
    }

    private func placeStrip(_ strip: Strip, at offset: CGFloat) {
        strip.controller.scrollActivity.beginOwnChange()
        strip.scroll.contentView.setBoundsOrigin(NSPoint(x: offset, y: 0))
        settle(2)
    }

    /// A point inside item `item` in **collection-view** coordinates, right now.
    private func stripPoint(_ strip: Strip, item: Int) throws -> NSPoint {
        let frame = try XCTUnwrap(strip.controller.collectionView
            .layoutAttributesForItem(at: IndexPath(item: item, section: 0))?.frame)
        return NSPoint(x: frame.midX, y: frame.midY)
    }

    private func note(_ line: String) {
        FileHandle.standardError.write(Data("ACCEPT519 \(line)\n".utf8))
        let path = ProcessInfo.processInfo.environment["PHOTONS_519_LOG"] ?? "/tmp/photons-519.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data("\(line)\n".utf8))
            handle.closeFile()
        } else {
            try? ("\(line)\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - the one test: ⇧/⌘ never centre, explicit entry still does

    func testMultiselectNeverCentres() throws {
        XCTAssertGreaterThanOrEqual(Self.libraryCount, 20, "夹具至少 20 张")
        let library = try makeLibrary(count: Self.libraryCount)
        let session = try makeSession(library)
        let strip = try makeStrip(session)
        settle(4)

        // 起点：普通单击选中第 6 张（只选中、不居中）。视口先放在 0，第 6 张可见。
        placeStrip(strip, at: 0)
        XCTAssertEqual(strip.controller.handleMouseDown(at: try stripPoint(strip, item: 6)), .forward)
        settle(3)
        XCTAssertEqual(session.selection, [library.ids[6]], "precondition：单击选中第 6 张")
        XCTAssertEqual(session.anchorID, library.ids[6])
        XCTAssertEqual(strip.controller.centerScrollCount, 0, "precondition：单击不居中")

        // ① 显式入口让锚点居中，记下计数（证明计数会动）。
        strip.controller.centreForLoupeEntry()
        settle(3)
        let afterEntry = strip.controller.centerScrollCount
        XCTAssertEqual(afterEntry, 1, "① centreForLoupeEntry 应居中一次（实际 \(afterEntry)）")

        // ② 三张 ⌘ 多选：增量必须为 0；selection 恰好 4 张，anchor 是最后点的那张。
        // 视口停在 250（第 6 张居中），第 7/8/9 张都在视口内。
        placeStrip(strip, at: 250)
        var commandDelta = 0
        var commandRows: [String] = []
        for item in [7, 8, 9] {
            let before = strip.controller.centerScrollCount
            let handled = strip.controller.handleSelectionClick(at: try stripPoint(strip, item: item),
                                                                modifiers: [.command])
            settle(3)
            XCTAssertTrue(handled, "第 \(item) 张：⌘ 点击应被这条门接住")
            let delta = strip.controller.centerScrollCount - before
            commandDelta += delta
            commandRows.append("⌘\(item) +\(delta)")
            XCTAssertEqual(delta, 0, "第 \(item) 张 ⌘ 多选不许滚（\(before) → \(strip.controller.centerScrollCount)）")
        }
        XCTAssertEqual(commandDelta, 0, "② 三次 ⌘ 多选的 centerScrollCount 增量应为 0，实际 \(commandDelta)")
        let multiselectCount = session.selection.count
        let anchorIsLastCommand = session.anchorID == library.ids[9]
        XCTAssertEqual(session.selection, Set([6, 7, 8, 9].map { library.ids[$0] }),
                       "② ⌘ 多选后 selection 应恰好是 4 张（实际 \(multiselectCount)）")
        XCTAssertEqual(session.anchorID, library.ids[9], "② 锚点应是最后点的那张")

        // ③-a ⇧ 范围（有基点）：锚点按定义不动，增量 0。视口挪回 250，第 4 张（范围端点）在固定几何下也可点。
        placeStrip(strip, at: 250)
        let beforeShift = strip.controller.centerScrollCount
        XCTAssertTrue(strip.controller.handleSelectionClick(at: try stripPoint(strip, item: 4),
                                                            modifiers: [.shift]),
                      "⇧ 点击应被这条门接住")
        settle(3)
        let shiftDelta = strip.controller.centerScrollCount - beforeShift
        XCTAssertEqual(shiftDelta, 0, "③ ⇧ 范围不许滚（\(beforeShift) → \(strip.controller.centerScrollCount)）")
        XCTAssertEqual(session.anchorID, library.ids[9], "⇧ 范围不动锚点")

        // ③-b ⇧ 首击（还没有基点）。`selectRange` 的既有回退是「当成普通选择」，于是**锚点真的会动** ——
        // 旧门靠「锚点变了」的判据在这里滚一次（反向门就靠这一条变红）；新门口径是「选择手势不居中」，
        // 无论锚点动不动都不滚。清空选择 = 应用里 ⌘ 点空白处的同一条模型写回（`setSelection([])`）。
        session.setSelection([])
        settle(3)
        placeStrip(strip, at: 250)
        let beforeFirstShift = strip.controller.centerScrollCount
        XCTAssertTrue(strip.controller.handleSelectionClick(at: try stripPoint(strip, item: 4),
                                                            modifiers: [.shift]),
                      "无基点时的 ⇧ 首击应被这条门接住")
        settle(3)
        let firstShiftDelta = strip.controller.centerScrollCount - beforeFirstShift
        XCTAssertEqual(firstShiftDelta, 0,
                       "③ ⇧ 首击（锚点会动）也不许滚（\(beforeFirstShift) → \(strip.controller.centerScrollCount)）")
        XCTAssertEqual(session.anchorID, library.ids[4], "⇧ 首击把锚点落在点上那张")

        // ③-c ⇧⌘ 首击（同样无基点）：增量 0。
        session.setSelection([])
        settle(3)
        placeStrip(strip, at: 250)
        let beforeShiftCommand = strip.controller.centerScrollCount
        XCTAssertTrue(strip.controller.handleSelectionClick(at: try stripPoint(strip, item: 7),
                                                            modifiers: [.shift, .command]),
                      "⇧⌘ 首击应被这条门接住")
        settle(3)
        let shiftCommandDelta = strip.controller.centerScrollCount - beforeShiftCommand
        XCTAssertEqual(shiftCommandDelta, 0,
                       "③ ⇧⌘ 首击也不许滚（\(beforeShiftCommand) → \(strip.controller.centerScrollCount)）")
        XCTAssertEqual(session.anchorID, library.ids[7], "⇧⌘ 首击把锚点落在点上那张")

        // ④ 反向确认：显式入口仍然滚，计数是活的（不是「谁都不滚」）。
        placeStrip(strip, at: 0)
        let beforeEntry = strip.controller.centerScrollCount
        strip.controller.centreForLoupeEntry()
        settle(3)
        let entryDelta = strip.controller.centerScrollCount - beforeEntry
        XCTAssertEqual(entryDelta, 1, "④ centreForLoupeEntry 的增量应为 1，实际 \(entryDelta)")

        note("519 ① 入口居中 +\(afterEntry)（计数 \(afterEntry)）；② ⌘×3 增量 \(commandDelta)（\(commandRows.joined(separator: "、"))) selection=\(multiselectCount) 张 anchor=最后点的是/否 \(anchorIsLastCommand)；③ ⇧范围 增量 \(shiftDelta)、⇧首击 增量 \(firstShiftDelta)、⇧⌘首击 增量 \(shiftCommandDelta)；④ 入口居中增量 \(entryDelta)（\(beforeEntry) → \(strip.controller.centerScrollCount)）")
    }
}
