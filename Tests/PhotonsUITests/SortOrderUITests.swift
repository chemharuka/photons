import XCTest
import AppKit
import CryptoKit
import GRDB
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 拍摄时间排序（`新→旧 / 旧→新`）：**一个值，三个视图**。
///
/// The user's ask was one button beside the filmstrip that flips the order of the grid, the left
/// browser and the filmstrip at once, with the text naming the order currently in force. The tests
/// here are the numbers behind that sentence:
///
/// - the fixture is six **real** photos of this machine's `L10304xx` series whose EXIF capture times
///   are all different (13:09:12 … 13:10:45 local), plus one photo with no capture time at all;
/// - default order: the first item of all three views is the newest photo and the last is the
///   oldest — read off the **live cells** (`AssetGridItem.cardView.asset`, `FilmstripCell`…,
///   `PhotoRowCell.assetID`), not off `session.assets`, so a view that failed to react would be
///   visible here instead of hiding behind the model;
/// - one click: the order is reversed item for item, and the three arrays are equal to each other;
/// - the sort is view state: document hash, `editRevision`, `history.count`, `persistCount`, the
///   thumbnail pixels and the **decode counter** all read the same afterwards (re-ordering comes out
///   of the memory cache, it does not decode anything again);
/// - the button: text, tooltip, frame against its neighbour, font, icon box and the template
///   rendering that makes the glyph follow the appearance;
/// - two counterexamples, so the assertions above are shown to be able to fail: a strip that did
///   *not* follow the toggle, and a sort keyed on the filename instead of the capture time.
@MainActor
final class SortOrderUITests: XCTestCase {

    // MARK: - the sample set

    /// Six photos, one shoot, six distinct capture times. The UTC strings are the EXIF
    /// `DateTimeOriginal` values of the files on this machine (local 13:09:12 … 13:10:45, +08).
    /// Chronological order **is** filename order here, which is what makes the filename-keyed
    /// counterexample in `testCounterexampleTwo_sortingByFilenameGivesTheWrongFirstPhoto` a real
    /// mutation rather than a restatement.
    private static let shoot: [(name: String, utc: String)] = [
        ("L1030402.dng", "2026-10-02T05:09:12Z"),   // oldest
        ("L1030403.dng", "2026-10-02T05:09:24Z"),
        ("L1030404.dng", "2026-10-02T05:09:35Z"),
        ("L1030405.dng", "2026-10-02T05:09:49Z"),
        ("L1030407.dng", "2026-10-02T05:10:22Z"),
        ("L1030408.dng", "2026-10-02T05:10:45Z"),   // newest
    ]

    /// The seventh: a row whose EXIF had no date (an import that predates metadata reading, or a
    /// camera with a blank clock). It must land **last in both directions**.
    private static let undated = "L1030406.dng"

    private var tmp: URL!
    private var stores: [MemoryStore] = []
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-sortui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        _ = stores
        stores.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    /// The directory the sample files live in, or nil when this machine has none. `~/Desktop/test`
    /// is where the `L10304xx` fixtures sit; `PHOTONS_TEST_RAW` overrides it (one file, its folder).
    private static func sampleDirectory() -> URL? {
        if let raw = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"], !raw.isEmpty {
            return URL(fileURLWithPath: raw).deletingLastPathComponent()
        }
        let dir = URL(fileURLWithPath: NSString(string: "~/Desktop/test").expandingTildeInPath)
        for (name, _) in shoot where FileManager.default.isReadableFile(atPath: dir.appendingPathComponent(name).path) {
            return dir
        }
        return nil
    }

    private struct Library {
        let url: URL
        let catalog: Catalog
        let root: SourceRoot
        let idOf: [String: String]
        let rows: [(name: String, utc: String?)]
    }

    /// A one-root reference library over the real files (so thumbnails are real too), with one row
    /// per `rows` entry. Reference mode: the sample folder is only ever stat'ed/read.
    private func makeLibrary(_ rows: [(name: String, utc: String?)]) throws -> Library {
        let sample = Self.sampleDirectory() ?? tmp.appendingPathComponent("no-samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("sort-\(UUID().uuidString).photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: url)
        let root = try catalog.ensureRoot(for: sample, mode: .reference)
        var idOf: [String: String] = [:]
        for row in rows {
            let local = row.utc.map { String($0.prefix(10)) }
            let asset = Asset(sourceRootId: root.id,
                              relPath: row.name,
                              filename: row.name,
                              ext: (row.name as NSString).pathExtension,
                              kind: AssetKind.detect((row.name as NSString).pathExtension) ?? .raw,
                              size: 4096,
                              mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 9520,
                              height: 6336,
                              captureTime: row.utc,
                              captureLocalDate: local,
                              cameraModel: "LEICA SL3",
                              cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            idOf[row.name] = asset.id
        }
        return Library(url: url, catalog: catalog, root: root, idOf: idOf, rows: rows)
    }

    private func makeShootLibrary(includingUndated: Bool = false) throws -> Library {
        var rows: [(name: String, utc: String?)] = Self.shoot.map { (name: $0.name, utc: Optional($0.utc)) }
        if includingUndated { rows.append((Self.undated, nil)) }
        return try makeLibrary(rows)
    }

    // MARK: - the store (one global preference, isolated per test)

    /// Both preference protocols, in memory. A test never touches `UserDefaults.standard`, so no
    /// other test file inherits a sort order from this one.
    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        private(set) var sortWrites = 0

        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }

        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) {
            sortWrites += 1
            sort[key] = raw
        }
    }

    private func makeStore() -> MemoryStore {
        let store = MemoryStore()
        stores.append(store)
        return store
    }

    // MARK: - harness: one session, three views, all on screen at once

    @MainActor
    private final class Harness {
        let session: CatalogSession
        let grid: AssetGridController
        let strip: FilmstripController
        let browser: BrowserPaneController
        let window: NSWindow
        let filenameOf: [String: String]

        init(library: Library, store: MemoryStore, window: NSWindow) throws {
            session = CatalogSession(filterStore: store, sortPreferenceStore: store)
            try session.open(library.url)
            grid = AssetGridController(session: session)
            strip = FilmstripController(session: session)
            browser = BrowserPaneController(session: session)
            _ = grid.view
            _ = strip.view
            _ = browser.view
            self.window = window
            var reverse: [String: String] = [:]
            for (name, id) in library.idOf { reverse[id] = name }
            filenameOf = reverse

            let content = window.contentView ?? NSView(frame: window.contentView?.bounds ?? .zero)
            // Three surfaces in one window: the grid on top, the browser on the left, the strip
            // along the bottom. Their frames overlap on purpose — this is a layout host, not a
            // screenshot; each view lays its own cells out.
            grid.view.frame = NSRect(x: 240, y: 0, width: 1160, height: 780)
            strip.view.frame = NSRect(x: 0, y: 800, width: 1400, height: 83)
            browser.view.frame = NSRect(x: 0, y: 0, width: 240, height: 780)
            for v in [grid.view, browser.view, strip.view] { content.addSubview(v) }
            content.layoutSubtreeIfNeeded()
            settle(8)
        }

        /// The order the grid is drawing, top-left first.
        var gridOrder: [String] { grid.renderedAssetIDs }
        /// The order the filmstrip is drawing, left to right.
        var stripOrder: [String] { strip.renderedAssetIDs }
        /// The order the left list is drawing, row 0 first.
        var browserOrder: [String] { browser.renderedPhotoRowIDs }

        func names(_ ids: [String]) -> [String] { ids.map { filenameOf[$0] ?? $0 } }

        func settle(_ turns: Int = 4) {
            for _ in 0..<turns { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            grid.view.layoutSubtreeIfNeeded()
            browser.view.layoutSubtreeIfNeeded()
            strip.view.layoutSubtreeIfNeeded()
        }

        /// Wait until the shared thumbnail pipeline is idle (up to `seconds`).
        func waitForThumbnails(_ seconds: TimeInterval = 45) {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                settle(2)
                let busy = grid.pendingThumbnailRequests + strip.pendingThumbnailRequests
                    + browser.pendingThumbnailRequests
                if busy == 0, grid.thumbnailStats.generated > 0 { return }
            }
        }
    }

    private func makeHarness(_ library: Library, store: MemoryStore) throws -> Harness {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 884),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 884))
        windows.append(window)
        return try Harness(library: library, store: store, window: window)
    }

    // MARK: - expected orders

    /// Newest first, then the undated row last.
    private static func expectedNewestFirst(includingUndated: Bool) -> [String] {
        var names = shoot.map(\.name).reversed().map { $0 }      // L1030408 … L1030402
        if includingUndated { names.append(undated) }
        return names
    }

    private static func expectedOldestFirst(includingUndated: Bool) -> [String] {
        var names = shoot.map(\.name)                             // L1030402 … L1030408
        if includingUndated { names.append(undated) }             // still last — see the rule in the type
        return names
    }

    private func describe(_ harness: Harness, _ ids: [String]) -> String {
        harness.names(ids).enumerated()
            .map { "\($0.offset):\($0.element)" }
            .joined(separator: " ")
    }

    private func orderHash(_ ids: [String]) -> String {
        let digest = SHA256.hash(data: Data(ids.joined(separator: "|").utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    // MARK: - ① default: newest first, in all three views

    func testDefaultOrderIsNewestFirstInAllThreeViews() throws {
        let library = try makeShootLibrary()
        let harness = try makeHarness(library, store: makeStore())

        XCTAssertEqual(harness.session.sortOrder, .newestFirst, "默认是新日期在前")

        let expected = Self.expectedNewestFirst(includingUndated: false)
        for (view, order) in [("网格", harness.gridOrder),
                              ("左侧栏", harness.browserOrder),
                              ("胶片条", harness.stripOrder)] {
            XCTAssertEqual(harness.names(order), expected, "\(view) 默认顺序")
            XCTAssertEqual(order.first, library.idOf["L1030408.dng"], "\(view) 首项应是最新那张")
            XCTAssertEqual(order.last, library.idOf["L1030402.dng"], "\(view) 末项应是最旧那张")
        }
        print("默认 新→旧 ─ 网格: \(describe(harness, harness.gridOrder))")
        print("默认 新→旧 ─ 左侧栏: \(describe(harness, harness.browserOrder))")
        print("默认 新→旧 ─ 胶片条: \(describe(harness, harness.stripOrder))")
    }

    // MARK: - ② one click: reversed, and the three agree item for item

    func testOneClickReversesAllThreeViewsItemForItem() throws {
        let library = try makeShootLibrary()
        let harness = try makeHarness(library, store: makeStore())

        let beforeGrid = harness.gridOrder
        let beforeBrowser = harness.browserOrder
        let beforeStrip = harness.stripOrder

        harness.session.toggleSortOrder()
        harness.settle(8)

        XCTAssertEqual(harness.session.sortOrder, .oldestFirst)
        let expected = Self.expectedOldestFirst(includingUndated: false)

        for (view, order) in [("网格", harness.gridOrder),
                              ("左侧栏", harness.browserOrder),
                              ("胶片条", harness.stripOrder)] {
            XCTAssertEqual(harness.names(order), expected, "\(view) 点一次后应为旧→新")
        }
        // 完全反转：逐项等于点击前的倒序。
        XCTAssertEqual(harness.gridOrder, Array(beforeGrid.reversed()))
        XCTAssertEqual(harness.browserOrder, Array(beforeBrowser.reversed()))
        XCTAssertEqual(harness.stripOrder, Array(beforeStrip.reversed()))

        // 三视图逐项相等（不是三个「也都反转了」的巧合，是同一个数组）。
        XCTAssertEqual(harness.gridOrder, harness.browserOrder, "网格 ≠ 左侧栏")
        XCTAssertEqual(harness.gridOrder, harness.stripOrder, "网格 ≠ 胶片条")
        XCTAssertEqual(harness.gridOrder, harness.session.assets.map(\.id), "视图顺序 ≠ 会话顺序")
        XCTAssertEqual(Set([orderHash(harness.gridOrder),
                            orderHash(harness.browserOrder),
                            orderHash(harness.stripOrder)]).count, 1)

        print("点一次 旧→新 ─ 网格: \(describe(harness, harness.gridOrder))")
        print("点一次 旧→新 ─ 左侧栏: \(describe(harness, harness.browserOrder))")
        print("点一次 旧→新 ─ 胶片条: \(describe(harness, harness.stripOrder))")
        print("顺序 hash 网格/左bar/胶片条: \(orderHash(harness.gridOrder)) / "
              + "\(orderHash(harness.browserOrder)) / \(orderHash(harness.stripOrder)) "
              + "| before: \(orderHash(beforeGrid))")
    }

    // MARK: - ③ the undated photo

    func testUndatedPhotoSortsLastInBothOrders() throws {
        let library = try makeShootLibrary(includingUndated: true)
        let harness = try makeHarness(library, store: makeStore())
        let undatedID = library.idOf[Self.undated]

        for (order, view) in [("新→旧", harness.gridOrder)] {
            XCTAssertEqual(order.count, 7, "\(view) 应有 7 项")
            XCTAssertEqual(view.first, library.idOf["L1030408.dng"])
            XCTAssertEqual(Array(view.dropLast()).last, library.idOf["L1030402.dng"], "有拍摄时间的最旧一张排第 6")
            XCTAssertEqual(view.last, undatedID, "无拍摄时间的那张排在末尾")
        }
        let newestFirst = harness.names(harness.gridOrder)
        XCTAssertEqual(newestFirst, Self.expectedNewestFirst(includingUndated: true))

        harness.session.toggleSortOrder()
        harness.settle(8)

        XCTAssertEqual(harness.gridOrder.first, library.idOf["L1030402.dng"])
        XCTAssertEqual(harness.gridOrder.last, undatedID, "反转方向也不把它拽到最前")
        XCTAssertEqual(harness.names(harness.gridOrder), Self.expectedOldestFirst(includingUndated: true))
        // 网格、左侧栏、胶片条三处一致，第 7 项就是它。
        XCTAssertEqual(harness.browserOrder, harness.gridOrder)
        XCTAssertEqual(harness.stripOrder, harness.gridOrder)

        print("无拍摄时间那张：\(newestFirst.firstIndex(of: Self.undated).map { "新→旧 第 \($0 + 1) 项（共 7）" } ?? "缺失") / "
              + "旧→新 第 \((harness.names(harness.gridOrder).firstIndex(of: Self.undated) ?? -1) + 1) 项")
        print("旧→新 全序: \(describe(harness, harness.gridOrder))")
    }

    // MARK: - ④ view state, not document, not a decode

    func testSortIsViewStateNotDocumentAndDecodesNothingAgain() throws {
        guard Self.sampleDirectory() != nil else {
            throw XCTSkip("没有 L10304xx 样张（设 PHOTONS_TEST_RAW 或放到 ~/Desktop/test）")
        }
        // Two photos with real files: enough for a real decode, cheap enough for a unit test.
        let library = try makeLibrary(Self.shoot[4...5].map { (name: $0.name, utc: Optional($0.utc)) })  // 407, 408
        let harness = try makeHarness(library, store: makeStore())
        let session = harness.session
        harness.waitForThumbnails()

        let provider = try XCTUnwrap(harness.grid.thumbnailProviderForSmoke)
        let newest = try XCTUnwrap(library.idOf["L1030408.dng"].flatMap { id in
            session.assets.first { $0.id == id }
        })
        let tier = harness.grid.currentThumbnailTier
        let pixelsBefore = try XCTUnwrap(provider.memoryImage(contentHash: newest.contentHash, tier: tier),
                                         "缩略图没有进内存层，后面的「不重解码」无从谈起")
        let hashBefore = Self.pixelHash(pixelsBefore)

        let statsBefore = harness.grid.thumbnailStats
        let docBefore = Self.documentHash(session.edit)
        let historyBefore = session.history.count
        let revisionBefore = session.editRevision
        let persistBefore = session.persistCount
        let gridCountBefore = harness.gridOrder.count

        session.toggleSortOrder()
        harness.settle(10)

        let statsAfter = harness.grid.thumbnailStats
        let pixelsAfter = try XCTUnwrap(provider.memoryImage(contentHash: newest.contentHash, tier: tier))
        let hashAfter = Self.pixelHash(pixelsAfter)

        XCTAssertEqual(harness.gridOrder.count, gridCountBefore)
        XCTAssertEqual(harness.gridOrder, session.assets.map(\.id), "视图顺序 ≠ 会话顺序")

        // 文档 / 历史 / 直方图修订 / 落库次数：排序不该碰任何一项。
        XCTAssertEqual(Self.documentHash(session.edit), docBefore, "documentHash 变了")
        XCTAssertEqual(session.history.count, historyBefore, "history.count 变了")
        XCTAssertEqual(session.editRevision, revisionBefore, "editRevision 变了")
        XCTAssertEqual(session.persistCount, persistBefore, "persistCount 变了")

        // 像素：同一张的缩略图逐字节相同（memcmp 级，不是「看着一样」）。
        XCTAssertEqual(hashAfter, hashBefore, "帧像素 hash 变了")
        // 解码次数不增加；命中从内存层来。
        XCTAssertEqual(statsAfter.generated, statsBefore.generated, "排序触发了重新解码")
        XCTAssertGreaterThanOrEqual(statsAfter.memoryHits, statsBefore.memoryHits)
        XCTAssertEqual(statsAfter.failures, statsBefore.failures)

        print("排序前后 ─ documentHash \(docBefore.prefix(12)) → \(Self.documentHash(session.edit).prefix(12)) · "
              + "history \(historyBefore) → \(session.history.count) · editRevision \(revisionBefore) → \(session.editRevision) · "
              + "persist \(persistBefore) → \(session.persistCount)")
        print("像素 hash \(hashBefore.prefix(16)) → \(hashAfter.prefix(16))（同一对象: \(pixelsBefore === pixelsAfter)）· "
              + "解码 generated \(statsBefore.generated) → \(statsAfter.generated) · "
              + "memory \(statsBefore.memoryHits) → \(statsAfter.memoryHits) · "
              + "requests \(statsBefore.requests) → \(statsAfter.requests)")
    }

    // MARK: - ⑤ the button

    private func makeTopBar() -> TopBarView {
        let bar = TopBarView()
        bar.frame = NSRect(x: 0, y: 0, width: 1600, height: 36)
        bar.update(mode: .grid, assetCount: 6, selectionCount: 1, libraryName: "sort-demo", filmstrip: true)
        bar.updateSortOrder(.newestFirst)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    func testTheButtonShowsTheCurrentOrderAndMatchesItsNeighbour() {
        let bar = makeTopBar()
        let sort = bar.sortButtonView
        let neighbour = bar.filmstripButtonView

        XCTAssertEqual(sort.title, "新→旧", "默认按钮文字 = 当前排序")
        XCTAssertEqual(sort.toolTip, "按拍摄时间排序：新→旧")

        bar.updateSortOrder(.oldestFirst)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(sort.title, "旧→新")
        XCTAssertEqual(sort.toolTip, "按拍摄时间排序：旧→新")

        bar.updateSortOrder(.newestFirst)
        bar.layoutSubtreeIfNeeded()

        // 同一行、同高、10 pt 间距、同一基线。
        XCTAssertEqual(sort.frame.height, WorkspaceLayout.toolButtonHit)
        XCTAssertEqual(sort.frame.height, neighbour.frame.height, "与邻居不同高")
        XCTAssertEqual(sort.frame.midY, neighbour.frame.midY, accuracy: 0.001, "与邻居不在同一基线")
        XCTAssertEqual(sort.frame.minY, neighbour.frame.minY, accuracy: 0.001)
        XCTAssertEqual(sort.frame.minX - neighbour.frame.maxX, 10, accuracy: 0.001, "与邻居的间距不是 10 pt")
        XCTAssertLessThan(sort.frame.maxX, bar.statusCluster.frame.minX, "按钮压到了右上角状态文本")

        // 字体、颜色、边框、悬停态：同一个 `ToolButton`，逐项相同。
        XCTAssertEqual(sort.font?.fontName, neighbour.font?.fontName)
        XCTAssertEqual(sort.font?.pointSize, neighbour.font?.pointSize)
        XCTAssertEqual(sort.contentTintColor, neighbour.contentTintColor)
        XCTAssertEqual(sort.isBordered, neighbour.isBordered)
        XCTAssertEqual(sort.imagePosition, neighbour.imagePosition)
        XCTAssertEqual(sort.intrinsicContentSize.height, neighbour.intrinsicContentSize.height)

        // 宽 = 图标 + 间距 + 文本 + 左右内边距（`ToolButton.intrinsicContentSize` 的算式，
        // 用两个按钮的实测值验证）。
        let textWidth = ("新→旧" as NSString).size(withAttributes: [.font: sort.font!]).width
        let expectedWidth = WorkspaceLayout.toolButtonPaddingH * 2 + 14 + textWidth + 6
        XCTAssertEqual(sort.intrinsicContentSize.width, expectedWidth, accuracy: 0.51)

        print("排序按钮 frame \(rect(sort.frame)) · 邻居(胶片条) frame \(rect(neighbour.frame)) · "
              + "间距 \(String(format: "%.2f", sort.frame.minX - neighbour.frame.maxX)) pt")
        print("字体 \(sort.font?.fontName ?? "?") \(sort.font?.pointSize ?? 0) / 邻居 \(neighbour.font?.fontName ?? "?") "
              + "\(neighbour.font?.pointSize ?? 0) · 图标盒 \(sort.image?.size ?? .zero) / 邻居 \(neighbour.image?.size ?? .zero)")
        print("按钮宽 \(String(format: "%.2f", sort.frame.width)) = 内边距 \(WorkspaceLayout.toolButtonPaddingH)×2 + 图标 14 + 文本 "
              + "\(String(format: "%.2f", textWidth)) + 6 = \(String(format: "%.2f", expectedWidth)) · "
              + "tooltip「\(sort.toolTip ?? "")」")
    }

    func testTheIconIsTheStaticSortGlyphAndFollowsTheAppearance() throws {
        let bar = makeTopBar()
        let sort = bar.sortButtonView
        let neighbour = bar.filmstripButtonView

        let image = try XCTUnwrap(sort.image)
        XCTAssertTrue(image.isTemplate, "SF Symbol 必须是 template 才能跟随明暗外观")
        // 图标不随状态变：翻一次顺序，图像字节和尺寸都不动。
        let before = image.tiffRepresentation
        bar.updateSortOrder(.oldestFirst)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(sort.image?.tiffRepresentation, before, "图标随状态变了（应静态）")
        XCTAssertEqual(sort.image?.size, image.size)

        // 与邻居同尺寸（≤ 0.5 pt）。
        let neighbourImage = try XCTUnwrap(neighbour.image)
        XCTAssertEqual(image.size.width, neighbourImage.size.width, accuracy: 0.5, "图标宽与邻居不一致")
        XCTAssertEqual(image.size.height, neighbourImage.size.height, accuracy: 0.5, "图标高与邻居不一致")

        // 明/暗两种外观：同一个字形（alpha 掩码逐像素相同），颜色跟着 `labelColor` 翻转。
        let aqua = try XCTUnwrap(render(sort, appearance: .aqua))
        let dark = try XCTUnwrap(render(sort, appearance: .darkAqua))
        let lightStats = iconStats(aqua, iconWidth: 26)
        let darkStats = iconStats(dark, iconWidth: 26)

        XCTAssertEqual(lightStats.alphaMask, darkStats.alphaMask, "两种外观下的字形（覆盖像素）必须一致")
        XCTAssertGreaterThan(darkStats.meanLuma, lightStats.meanLuma,
                             "暗色外观下图标应更亮（模板被 labelColor 着色）")
        print("图标 \(image.size)（邻居 \(neighbourImage.size)）template=\(image.isTemplate) · "
              + "aqua 覆盖 \(lightStats.covered) px 亮度 \(String(format: "%.3f", lightStats.meanLuma)) · "
              + "darkAqua 覆盖 \(darkStats.covered) px 亮度 \(String(format: "%.3f", darkStats.meanLuma)) · "
              + "alpha hash \(lightStats.alphaMask) / \(darkStats.alphaMask)")
    }

    // MARK: - ⑥ counterexample ①: a strip that did not follow the toggle

    /// 「只改网格不改胶片条」的那种实现：网格换了序，胶片条还停在旧的。三视图逐项相等必须红。
    func testCounterexampleOne_aStripThatDidNotFollowMakesTheAgreementCheckRed() throws {
        let library = try makeShootLibrary()
        let harness = try makeHarness(library, store: makeStore())

        let stripBefore = harness.stripOrder
        harness.session.toggleSortOrder()
        harness.settle(8)

        let grid = harness.gridOrder
        let browser = harness.browserOrder
        let strip = harness.stripOrder

        // 正常接线：三处一致。
        XCTAssertEqual(agreement(grid: grid, browser: browser, strip: strip), .agrees,
                       "接线正常时三视图应逐项相等")
        // 反证：把胶片条换回排序前的顺序，检查必须在第 0 项就红。
        let stale = agreement(grid: grid, browser: browser, strip: stripBefore)
        guard case let .differs(view, index, lhs, rhs) = stale else {
            return XCTFail("胶片条停在旧顺序，一致性检查却通过了 —— 这个检查没有牙")
        }
        XCTAssertEqual(index, 0, "错位应从第 0 项开始")
        XCTAssertNotEqual(lhs, rhs)
        XCTAssertNotEqual(strip, stripBefore, "胶片条确实跟着换了序（否则上面的红线只是没接线的正常表现）")

        print("反证①：网格/左侧栏 = \(harness.names(grid).prefix(3))… · 旧胶片条 = \(harness.names(stripBefore).prefix(3))… "
              + "→ \(view) 第 \(index) 项 \(harness.filenameOf[lhs] ?? lhs) ≠ \(harness.filenameOf[rhs] ?? rhs)")
    }

    // MARK: - ⑦ counterexample ②: sorting by filename instead of capture time

    /// 若排序键是文件名而不是拍摄时间，`新→旧` 的首项会是 `C-oldest.dng`。必红。
    ///
    /// The fixture is deliberately anti-correlated (name ascending = time **descending**), which is
    /// the only shape in which "sort by the filename" and "sort by the capture time" disagree at
    /// index 0 — the real `L10304xx` names happen to run with the clock, so they cannot show this.
    func testCounterexampleTwo_sortingByFilenameGivesTheWrongFirstPhoto() {
        func photo(_ name: String, _ utc: String?) -> Asset {
            Asset(id: "id-\(name)", sourceRootId: "root", relPath: name, filename: name,
                  ext: "dng", kind: .raw, size: 1, mtime: 0, contentHash: name,
                  captureTime: utc, captureLocalDate: utc.map { String($0.prefix(10)) })
        }
        let assets = [photo("C-oldest.dng", "2024-01-01T00:00:00Z"),
                      photo("B-middle.dng", "2025-01-01T00:00:00Z"),
                      photo("A-newest.dng", "2026-10-02T05:10:45Z")]

        let byTime = PhotoSortOrder.newestFirst.sorted(assets).map(\.filename)
        let byName = assets.map(\.filename).sorted(by: >)     // 一个错的「新→旧」：按文件名倒序
        XCTAssertEqual(byTime, ["A-newest.dng", "B-middle.dng", "C-oldest.dng"])
        XCTAssertEqual(byTime.first, "A-newest.dng", "按拍摄时间，最新的是 A")
        XCTAssertEqual(byName.first, "C-oldest.dng", "按文件名，最前的是 C —— 错的")
        XCTAssertNotEqual(byTime, byName, "两种键的首项相同，这个反证不成立")
        XCTAssertEqual(PhotoSortOrder.oldestFirst.sorted(assets).map(\.filename),
                       ["C-oldest.dng", "B-middle.dng", "A-newest.dng"])

        // 无拍摄时间的那张：两个方向都排在末尾（连「文件名排第一」的 0-undated 也不例外）。
        let withUndated = assets + [photo("0-undated.dng", nil)]
        XCTAssertEqual(PhotoSortOrder.newestFirst.sorted(withUndated).map(\.filename).last, "0-undated.dng")
        XCTAssertEqual(PhotoSortOrder.oldestFirst.sorted(withUndated).map(\.filename).last, "0-undated.dng")

        print("反证②：按拍摄时间 → \(byTime)（首项 \(byTime[0])）· 按文件名倒序 → \(byName)（首项 \(byName[0])）")
        print("        无拍摄时间 → 新→旧 \(PhotoSortOrder.newestFirst.sorted(withUndated).map(\.filename)) · "
              + "旧→新 \(PhotoSortOrder.oldestFirst.sorted(withUndated).map(\.filename))")
    }

    // MARK: - ⑧ the choice survives a relaunch

    func testTheChoiceIsRememberedForTheNextLaunch() throws {
        let store = makeStore()
        let library = try makeShootLibrary()

        do {
            let first = try makeHarness(library, store: store)
            XCTAssertEqual(first.session.sortOrder, .newestFirst)
            first.session.toggleSortOrder()
            XCTAssertEqual(store.sort[PhotoSortPreferences.key], "oldestFirst")
            XCTAssertEqual(store.sortWrites, 1, "一次点击 = 一次写入")
            // 同一个值再设一次：不写。
            first.session.setSortOrder(.oldestFirst)
            XCTAssertEqual(store.sortWrites, 1)
        }

        let second = try makeHarness(library, store: store)
        XCTAssertEqual(second.session.sortOrder, .oldestFirst, "重启后应恢复上次的选择")
        XCTAssertEqual(second.names(second.gridOrder), Self.expectedOldestFirst(includingUndated: false),
                       "恢复的不只是按钮文字，第一次查询就是旧→新")
        print("持久化：store key \(PhotoSortPreferences.key) = \(store.sort[PhotoSortPreferences.key] ?? "nil") · "
              + "新会话首项 \(second.names(second.gridOrder).first ?? "?") · 写入次数 \(store.sortWrites)")
    }

    // MARK: - helpers

    /// 三视图逐项相等的判定，单独抽出来，好让反证能喂一个「没跟上的胶片条」进去。
    private enum Agreement: Equatable {
        case agrees
        case differs(view: String, index: Int, lhs: String, rhs: String)
    }

    private func agreement(grid: [String], browser: [String], strip: [String]) -> Agreement {
        for (view, other) in [("左侧栏", browser), ("胶片条", strip)] {
            if grid.count != other.count {
                return .differs(view: view, index: -1, lhs: "\(grid.count) 项", rhs: "\(other.count) 项")
            }
            for i in 0..<min(grid.count, other.count) where grid[i] != other[i] {
                return .differs(view: view, index: i, lhs: grid[i], rhs: other[i])
            }
        }
        return .agrees
    }

    private func rect(_ r: NSRect) -> String {
        String(format: "x %.2f y %.2f w %.2f h %.2f", r.minX, r.minY, r.width, r.height)
    }

    private static func documentHash(_ model: EditModel) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(MaskViewState.documentOnly(model)) else { return "unencodable" }
        return String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    private static func pixelHash(_ image: CGImage) -> String {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: max(1, w * h * 4))
        data.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let digest = SHA256.hash(data: Data(data))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// A real `draw` of the button into a bitmap under one appearance — no window needed, real
    /// symbol tinting (the button cell is what paints a template image).
    private func render(_ view: NSView, appearance: NSAppearance.Name) -> NSBitmapImageRep? {
        guard let resolution = NSAppearance(named: appearance) else { return nil }
        view.appearance = resolution
        view.layoutSubtreeIfNeeded()
        var rep: NSBitmapImageRep?
        resolution.performAsCurrentDrawingAppearance {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            rep = bitmap
        }
        return rep
    }

    /// The icon glyph as pixels: coverage (alpha) hash + mean luminance of the covered pixels, over
    /// the left `iconWidth` points of the button (icon + gap; the title starts to the right of it).
    private func iconStats(_ rep: NSBitmapImageRep,
                           iconWidth: CGFloat) -> (alphaMask: String, covered: Int, meanLuma: Double) {
        let pxWide = rep.pixelsWide, pxHigh = rep.pixelsHigh
        guard pxWide > 0, pxHigh > 0 else { return ("empty", 0, 0) }
        let scale = CGFloat(pxWide) / max(1, rep.size.width)
        let limit = min(pxWide, Int((iconWidth * scale).rounded()))
        var mask = ""
        var covered = 0
        var luma = 0.0
        for x in 0..<limit {
            for y in 0..<pxHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let a = color.alphaComponent
                if a > 0.12 {
                    covered += 1
                    mask.append("1")
                    luma += 0.2126 * color.redComponent + 0.7152 * color.greenComponent
                        + 0.0722 * color.blueComponent
                } else {
                    mask.append("0")
                }
            }
        }
        let digest = SHA256.hash(data: Data(mask.utf8))
        return (String(digest.map { String(format: "%02x", $0) }.joined().prefix(12)),
                covered,
                covered > 0 ? luma / Double(covered) : 0)
    }
}
