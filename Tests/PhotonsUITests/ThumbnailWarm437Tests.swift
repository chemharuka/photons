import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 437 — **a newly-entered band of already-cached photos gets one warm pass.**
///
/// The user's ask (2026-11-19) is one sentence:
///
/// > 「能否加载新的带缓存的照片时就触发一次新的缓存预热？」
///
/// The mechanism is the 429 band, split by cost instead of forked into a second queue:
///
/// * the **core** band (`AssetGridController.coreSlackRows`, currently ±10 rows) accepts every
///   photo;
/// * the **warm** band (±12 rows) only accepts a photo whose 1920 px JPEG is already on disk
///   (`ThumbnailCache.peek` = one `fileExists`) or already in the memory LRU.
///
/// Both feed **one** `wanted` set, so 429's "outside the band ⇒ cancel" still holds — only the
/// meaning of "outside" moved out to ±12 rows (`pendingThumbnailIndexesOutsideWindow`).
@MainActor
final class ThumbnailWarm437Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []
    private var extraCacheDirs: [URL] = []
    private static let columns = 9
    private static let gridWidth: CGFloat = 1478  // GridLayout: exactly nine columns
    private static let gridHeight: CGFloat = 900

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-warm437-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.close() }
        windows.removeAll()
        for dir in extraCacheDirs { try? FileManager.default.removeItem(at: dir) }
        extraCacheDirs.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    private static func readableSamples() -> [URL] {
        let folder = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: NSString(string: "~/Desktop/test").expandingTildeInPath)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dng") }.sorted()
        return names.map { folder.appendingPathComponent($0) }.filter {
            guard FileManager.default.isReadableFile(atPath: $0.path),
                  let source = CGImageSourceCreateWithURL($0 as CFURL, nil) else { return false }
            return CGImageSourceGetCount(source) > 0
        }
    }

    /// 30 rows × 9 columns, like the task's layout. The RAW pool is reused cyclically; every row
    /// still has its own `contentHash`, so every row is its own cache key.
    private func makeSession(rows: Int, name: String = "") throws -> CatalogSession {
        let pool = Self.readableSamples()
        guard !pool.isEmpty else { throw XCTSkip("no readable DNGs; set PHOTONS_TEST_RAW") }
        let package = tmp.appendingPathComponent("w437\(name).photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: package)
        let source = tmp.appendingPathComponent("src\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)
        for index in 0..<(rows * Self.columns) {
            let link = source.appendingPathComponent("shot\(index).dng")
            try FileManager.default.createSymbolicLink(at: link,
                                                       withDestinationURL: pool[index % pool.count])
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, imported_at, missing)
                    VALUES (?, ?, ?, ?, 'dng', 'raw', 4096, 0, ?, 9520, 6336,
                            '2026-11-19T00:00:00Z', 0)
                    """, arguments: ["a\(index)", root.id, "shot\(index).dng",
                                     "shot\(index).dng", String(format: "%064x", index + 1)])
            }
        }
        let session = CatalogSession()
        try session.open(package)
        XCTAssertEqual(session.assets.count, rows * Self.columns)
        return session
    }

    /// A real JPEG in the HD family's cache file, at exactly the key the grid will peek.
    private func seedHD(_ session: CatalogSession, rows: Range<Int>) throws {
        let cache = try XCTUnwrap(session.thumbnailCache)
        let image = try makeJPEGSource()
        for index in (rows.lowerBound * Self.columns)..<(rows.upperBound * Self.columns) {
            guard index < session.assets.count else { continue }
            let key = ThumbnailProvider.hdJPEGKey(for: session.assets[index])
            try cache.store(image: image, for: key)
        }
    }

    private func makeJPEGSource() throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 72,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(calibratedRed: 0.4, green: 0.6, blue: 0.8, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 72))
        return try XCTUnwrap(context.makeImage())
    }

    // MARK: - harness

    @MainActor
    private final class Harness {
        let session: CatalogSession
        let grid: AssetGridController
        let window: NSWindow
        let provider: ThumbnailProvider

        init(session: CatalogSession, window: NSWindow, width: CGFloat, height: CGFloat) {
            self.session = session
            self.window = window
            grid = AssetGridController(session: session)
            _ = grid.view
            grid.view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            window.contentView?.addSubview(grid.view)
            window.contentView?.layoutSubtreeIfNeeded()
            provider = grid.thumbnailProviderForSmoke
                ?? ThumbnailProvider.shared(for: session.thumbnailCache!)
            settle(6)
        }

        func settle(_ turns: Int = 4) {
            for _ in 0..<turns { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            grid.view.layoutSubtreeIfNeeded()
        }

        func waitForBands(_ seconds: TimeInterval = 120) {
            let deadline = Date().addingTimeInterval(seconds)
            var idle = 0
            while Date() < deadline {
                settle(2)
                if grid.pendingThumbnailRequests == 0 && grid.thumbnailQueueDepth == 0 {
                    idle += 1
                    if idle >= 3 { return }
                } else {
                    idle = 0
                }
            }
            XCTFail("warm bands did not settle (pending \(grid.pendingThumbnailRequests))")
        }

        var rowPitch: CGFloat { grid.metrics.rowHeight }
        var columns: Int { grid.metrics.columns }

        func scrollRows(_ rows: CGFloat) {
            let viewport = grid.scrollView.contentView.bounds.height
            let content = grid.collectionView.collectionViewLayout?
                .collectionViewContentSize.height ?? 0
            let maxOffset = max(0, content - viewport)
            let y = min(max(0, rows * rowPitch), maxOffset)
            grid.scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            grid.scrollView.reflectScrolledClipView(grid.scrollView.contentView)
            grid.view.layoutSubtreeIfNeeded()
            grid.collectionView.layoutSubtreeIfNeeded()
        }

        func indices(_ rows: Range<Int>) -> Set<Int> {
            Set(rows.flatMap { row in (0..<columns).map { row * columns + $0 } })
        }

        func rows(of indexes: Set<Int>) -> Set<Int> {
            Set(indexes.map { $0 / max(1, columns) })
        }
    }

    private func makeHarness(_ session: CatalogSession,
                             wait: Bool = true) throws -> Harness {
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0,
                                                         width: Self.gridWidth,
                                                         height: Self.gridHeight),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0,
                                                  width: Self.gridWidth,
                                                  height: Self.gridHeight))
        windows.append(window)
        let h = Harness(session: session, window: window,
                        width: Self.gridWidth, height: Self.gridHeight)
        XCTAssertEqual(h.columns, Self.columns)
        if wait { h.waitForBands() }
        return h
    }

    // MARK: - A① A③ A⑥ A⑧ — two bands, one set, disk-only

    func testWarmBandOnlyTakesCachedRowsAndNeverRenders() throws {
        let session = try makeSession(rows: 30)
        // Seed rows 0–26: at row 10 the whole core band (0–25) is on disk, the cached warm margin
        // is row 26 and row 27 is deliberately cold inside the wide ring. That keeps A③'s
        // "generated == 0" about the warm ring and still proves a cold wide-ring row is not asked.
        try seedHD(session, rows: 0..<27)
        let h = try makeHarness(session)
        XCTAssertEqual(h.columns, 9)

        h.provider.resetStats()
        let before = h.provider.stats
        let warmBefore = h.grid.warmRequests

        h.scrollRows(10)
        h.grid.reconcileThumbnailsForTesting()
        let queued = h.grid.queuedThumbnailIndexes
        let core = h.grid.coreWantedIndexes()
        let wide = h.grid.wideWantedIndexes()
        let warmQueued = queued.subtracting(core)
        let warmRows = h.rows(of: warmQueued)

        print("437 A① queued \(queued.count) core \(core.count) wide \(wide.count) "
              + "warm \(warmQueued.count) warm rows \(warmRows.sorted())")

        XCTAssertFalse(warmQueued.isEmpty,
                       "cached rows past the ±\(AssetGridController.coreSlackRows) core must be asked for")
        XCTAssertTrue(warmQueued.isSubset(of: wide), "warm requests live inside ±12 rows")
        XCTAssertTrue(warmQueued.isSubset(of: h.indices(0..<27)),
                      "only rows with an HD JPEG on disk may be warmed")
        XCTAssertTrue(queued.intersection(h.indices(27..<30)).isEmpty,
                      "rows 27–29 have no cache file and must not be asked for")
        // A⑥ (re-defined): nothing queued beyond ±12 rows.
        XCTAssertEqual(h.grid.pendingThumbnailIndexesOutsideWindow, 0)
        XCTAssertEqual(h.grid.lastRebuildOutsideCount, 0)

        // A⑧: the peek cost of one pass, then of the next pass with the answer cache warm.
        let coldPeeks = h.grid.lastWarmPeekCount
        let coldMS = h.grid.lastWarmPeekMilliseconds
        h.grid.reconcileThumbnailsForTesting(force: true)
        let cachedPeeks = h.grid.lastWarmPeekCount
        let cachedMS = h.grid.lastWarmPeekMilliseconds
        print(String(format: "437 A⑧ peek cold %d × fileExists = %.2f ms; cached %d = %.2f ms",
                     coldPeeks, coldMS, cachedPeeks, cachedMS))
        XCTAssertLessThanOrEqual(coldPeeks, 2 * 12 * Self.columns + Self.columns,
                                 "±12 rows × 9 columns is the probe ceiling")
        XCTAssertLessThanOrEqual(cachedPeeks, coldPeeks)
        XCTAssertLessThan(cachedMS, 3.0, "a cached reconcile is under the 3 ms budget")

        // A③: everything that landed came from disk; no producer ran.
        h.waitForBands(60)
        let after = h.provider.stats
        let generated = after.generated - before.generated
        let decodes = after.decodes - before.decodes
        let diskHits = after.diskHits - before.diskHits
        print("437 A③ generated +\(generated) diskHits +\(diskHits) decodes +\(decodes) "
              + "warmRequests +\(h.grid.warmRequests - warmBefore)")
        XCTAssertEqual(generated, 0, "a pre-warmed photo must never trigger a render")
        XCTAssertGreaterThan(diskHits, 0, "the warm ring's product is disk hits")
        XCTAssertLessThanOrEqual(decodes, queued.count + core.count)
        XCTAssertEqual(h.grid.pendingThumbnailIndexesOutsideWindow, 0)
    }

    // MARK: - A② — empty disk cache degrades to today's band

    func testEmptyDiskCacheOnlyAsksForTheCoreBand() throws {
        let session = try makeSession(rows: 30, name: "-cold")
        let cache = try XCTUnwrap(session.thumbnailCache)
        // Pause before the grid exists: a paused service refuses anything that would render, so
        // the cache stays empty for the whole reading instead of filling underneath the test.
        let provider = ThumbnailProvider.shared(for: cache)
        provider.service.isPaused = true
        defer { provider.service.isPaused = false }

        let h = try makeHarness(session, wait: false)
        h.scrollRows(10)
        h.grid.reconcileThumbnailsForTesting()

        let queued = h.grid.queuedThumbnailIndexes
        let core = h.grid.coreWantedIndexes()
        let peeks = h.grid.lastWarmPeekCount
        let wanted = h.grid.wantedIndexes()
        print("437 A② empty cache: wanted \(wanted.count) core \(core.count) "
              + "queued \(queued.count) warm asks \(h.grid.lastReconcileWarmRequests) peeks \(peeks)")
        XCTAssertEqual(wanted, core,
                       "no disk cache ⇒ the band is exactly the ±\(AssetGridController.coreSlackRows)-row core")
        XCTAssertEqual(h.rows(of: h.grid.wideWantedIndexes()).count - h.rows(of: core).count, 2,
                       "469: the ±12 outer ring leaves exactly two warm-only rows beyond the core")
        // 449 — the *request* band is still core, but cancellation now stops at the outer ring
        // (±`warmSlackRows` = ±12 rows), so asks from the band before a small scroll may still be
        // in flight. That is intended (it is what keeps a continuous scroll from discarding bytes);
        // what must not grow is the set this pass asks for, which `wanted == core` above proves.
        XCTAssertTrue(queued.isSubset(of: h.grid.wideWantedIndexes()),
                      "an empty cache must not queue anything past the ±12-row ring")
        XCTAssertEqual(h.grid.warmRequests, 0)
        XCTAssertEqual(h.grid.lastReconcileWarmRequests, 0)
        XCTAssertGreaterThan(peeks, 0, "the filter still peeks and finds nothing")
    }

    // MARK: - 469 — the core band is visible ± coreSlackRows, not a literal

    /// Three visible rows, no disk cache: the requested set must be exactly the visible rows plus
    /// `AssetGridController.coreSlackRows` above and below. The expectation is derived from the
    /// constant and from `wideWantedIndexes()`, never from `10` or the old `4`; the ring relation
    /// (outer − core = two rows) is the reverse gate that catches the constant drifting back to 4.
    func testRequestedBandIsVisiblePlusCoreSlackRows() throws {
        let session = try makeSession(rows: 40, name: "-boundary")
        let cache = try XCTUnwrap(session.thumbnailCache)
        let provider = ThumbnailProvider.shared(for: cache)
        provider.service.isPaused = true
        defer { provider.service.isPaused = false }

        let width: CGFloat = 520
        let metrics = GridLayout.metrics(forWidth: width)
        let height = metrics.rowHeight * 2.5
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        windows.append(window)
        let h = Harness(session: session, window: window, width: width, height: height)
        XCTAssertEqual(h.columns, 3)

        h.scrollRows(10)
        // Land just past row 9's bottom edge (the grid's content inset puts row 10 at
        // `10 * rowPitch + inset`), so the fixture is exactly three visible rows.
        let scroll = h.grid.scrollView
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 10 * h.rowPitch + metrics.inset + 1))
        scroll.reflectScrolledClipView(scroll.contentView)
        h.grid.view.layoutSubtreeIfNeeded()
        h.grid.collectionView.layoutSubtreeIfNeeded()
        h.grid.reconcileThumbnailsForTesting()

        let visibleRows = h.rows(of: h.grid.visibleIndexes())
        let queued = h.grid.queuedThumbnailIndexes
        let queuedRows = h.rows(of: queued)
        let core = h.grid.coreWantedIndexes()
        let coreRows = h.rows(of: core)
        let wideRows = h.rows(of: h.grid.wideWantedIndexes())
        let slack = Int(AssetGridController.coreSlackRows)
        let visibleTop = try XCTUnwrap(visibleRows.min())
        let visibleBottom = try XCTUnwrap(visibleRows.max())
        let expectedRows = Set(max(0, visibleTop - slack)...(visibleBottom + slack))

        print("469 boundary: visible rows \(visibleRows.sorted()), queued rows "
              + "\(queuedRows.min() ?? -1)–\(queuedRows.max() ?? -1), core \(core.count), "
              + "slack \(slack), wide \(wideRows.count) rows")

        XCTAssertEqual(visibleRows.count, 3, "fixture: exactly three visible rows")
        XCTAssertEqual(queuedRows, expectedRows,
                       "the request band is visible ± coreSlackRows rows")
        XCTAssertEqual(queued, core, "no disk cache ⇒ the core band is the whole ask")
        XCTAssertEqual(wideRows.count - coreRows.count, 2,
                       "469: the ±12 outer ring leaves exactly two warm-only rows beyond the core")
        XCTAssertEqual(h.grid.warmRequests, 0)
    }

    // MARK: - A④ — one look per newly-entered index
    func testWarmAskFiresOnlyForNewlyEnteredIndexes() throws {
        let session = try makeSession(rows: 30, name: "-step")
        try seedHD(session, rows: 0..<30)
        let h = try makeHarness(session)

        var warm = h.grid.warmRequests
        h.scrollRows(1)
        h.grid.reconcileThumbnailsForTesting()
        let first = h.grid.warmRequests - warm
        print("437 A④ one row down: +\(first) warm (columns \(h.columns))")
        XCTAssertEqual(first, h.columns, "exactly the row that just entered the wide band")
        h.waitForBands(60)

        warm = h.grid.warmRequests
        h.scrollRows(0)
        h.grid.reconcileThumbnailsForTesting()
        let back = h.grid.warmRequests - warm
        print("437 A④ back to top: +\(back) warm")
        XCTAssertEqual(back, 0, "scrolling back adds no new rows")
        h.waitForBands(60)

        warm = h.grid.warmRequests
        h.scrollRows(1)
        h.grid.reconcileThumbnailsForTesting()
        let again = h.grid.warmRequests - warm
        print("437 A④ same row again: +\(again) warm")
        XCTAssertEqual(again, 0, "the row is still in the memory LRU — one ask per stay")
        XCTAssertTrue(h.grid.wantedIndexes().isSuperset(of: h.indices(12..<13)),
                      "the re-entered row is still inside the warm band")

        let queued = h.grid.queuedThumbnailIndexes
        XCTAssertEqual(queued.count, Set(queued).count)
        XCTAssertEqual(h.grid.pendingThumbnailIndexesOutsideWindow, 0)

        // 429's other half: a reconcile with an unchanged band does no work at all.
        h.grid.cancelScheduledThumbnailReconcileForTesting()
        let passes = h.grid.reconcilePasses
        h.grid.reconcileThumbnailsForTesting(force: false)
        print("437 A④ idle reconcile passes: \(h.grid.reconcilePasses - passes)")
        XCTAssertEqual(h.grid.reconcilePasses, passes, "wanted unchanged ⇒ no pass")
    }

    // MARK: - A⑤ — budget and priority order

    func testWarmBudgetAndVisibleFirstOrdering() throws {
        // The top block is warm before the jump; the far block (rows 40–59) is cached but has never
        // been seen, so the visible cells there must be asked for as **onScreen** while the cached
        // rows past the new core band are the warm work. Rows 28–39 are cold; rows 28–29 fall in
        // the wide ring but are not cached, so only the two warm-margin rows below the core (56–57)
        // are eligible. 469 — the warm ring is `warmSlackRows − coreSlackRows` = 2 rows wide, so
        // those two rows hold 2 × 9 = 18 eligible cells; that is below `warmBudgetPerPass` (32), so
        // the pass must issue exactly 18, not merely "more than zero".
        let session = try makeSession(rows: 60, name: "-budget")
        try seedHD(session, rows: 0..<19)
        try seedHD(session, rows: 40..<60)
        let h = try makeHarness(session)

        h.grid.resetRequestLogForTesting()
        h.scrollRows(40)
        h.grid.cancelScheduledThumbnailReconcileForTesting()
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        h.grid.reconcileThumbnailsForTesting()
        let issued = h.grid.lastReconcileWarmRequests
        let log = h.grid.requestLog
        let priorities = log.map(\.priority)
        let visibleRows = Set(h.grid.collectionView.indexPathsForVisibleItems().map { $0.item / h.columns })
        print("437 A⑤ jump to row 40: new warm \(issued), requests \(priorities.count), "
              + "onScreen \(priorities.filter { $0 == .onScreen }.count), "
              + "visible rows \(visibleRows.sorted())")

        XCTAssertLessThanOrEqual(issued, AssetGridController.warmBudgetPerPass,
                                 "one pass may issue at most warmBudget")
        let core = h.grid.coreWantedIndexes()
        let seeded = h.indices(0..<19).union(h.indices(40..<60))
        let eligible = h.grid.wideWantedIndexes().intersection(seeded).subtracting(core)
        let expected = min(AssetGridController.warmBudgetPerPass, eligible.count)
        print("437 A⑤ warm: issued \(issued) expected \(expected) "
              + "(ring cells \(eligible.count) of budget \(AssetGridController.warmBudgetPerPass), "
              + "core \(core.count), wide \(h.grid.wideWantedIndexes().count))")
        XCTAssertEqual(issued, expected,
                       "one pass issues min(warmBudgetPerPass, cached cells in the two warm-only rows)")
        XCTAssertFalse(priorities.isEmpty)
        XCTAssertEqual(priorities.first, .onScreen,
                       "the visible cells are asked for before the prefetch work")
        // onScreen (2) first, then prefetch (1): never a 2 after a 1.
        var sawPrefetch = false
        for priority in priorities {
            if priority == .prefetch { sawPrefetch = true }
            if sawPrefetch { XCTAssertNotEqual(priority, .onScreen) }
        }
        XCTAssertEqual(h.grid.pendingThumbnailIndexesOutsideWindow, 0)
    }

    // MARK: - A⑦ — the warm ring's memory cost

    func testWarmBandMemoryCost() throws {
        let session = try makeSession(rows: 30, name: "-memory")
        try seedHD(session, rows: 0..<30)
        let h = try makeHarness(session)

        let count = h.grid.wantedIndexes().count
        let pixels = h.grid.displayPixelSize
        // The provider's own `NSCache` cost formula (`remember`: w · h · 8, half-float RGBA).
        let bytes = max(1, pixels.width * pixels.height * 8) * count
        let mb = Double(bytes) / (1024 * 1024)
        print(String(format: "437 A⑦ warm band %d cells at %d×%d = %.1f MB "
                     + "(%.0f KB each), limit %d MB",
                     count, pixels.width, pixels.height, mb,
                     Double(bytes) / Double(count) / 1024,
                     ThumbnailProvider.memoryByteLimit / (1024 * 1024)))
        XCTAssertEqual(h.columns, 9)
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThanOrEqual(bytes, ThumbnailProvider.memoryByteLimit)
    }

    // MARK: - A⑨ — the real 630-photo library at 15 rows/s

    /// A real-library read: copy `~/Documents/photons-demo.photonslibrary` (630 photos, every HD
    /// JPEG already on disk) plus its cache, then scroll continuously at 0.25 row per frame
    /// (15 rows/s) for 200 steps (50 rows) and sample the visible cells every frame.
    func testRealLibraryContinuousScrollKeepsPlaceholdersAtZero() throws {
        let source = URL(fileURLWithPath: NSString(
            string: "~/Documents/photons-demo.photonslibrary").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("photons-demo library not present")
        }
        let sourceCache = LibraryLayout(packageURL: source).cacheDirectory
        guard FileManager.default.fileExists(atPath: sourceCache.path) else {
            throw XCTSkip("no thumbnail cache for the demo library")
        }

        let package = tmp.appendingPathComponent("demo.photonslibrary", isDirectory: true)
        try clone(source, to: package)
        let destCache = LibraryLayout(packageURL: package).cacheDirectory
        try? FileManager.default.removeItem(at: destCache)
        extraCacheDirs.append(destCache)
        try FileManager.default.createDirectory(at: destCache.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try clone(sourceCache, to: destCache)

        let session = CatalogSession()
        try session.open(package)
        let cache = try XCTUnwrap(session.thumbnailCache)
        // A⑨'s premise is "every photo already has its 1920 px JPEG"; the demo copy can be one
        // file short (its source cannot produce one either). Fill that hole with a real JPEG so the
        // run measures the band and not one photo's permanent placeholder.
        let filler = try makeJPEGSource()
        var filled = 0
        for asset in session.assets {
            let key = ThumbnailProvider.hdJPEGKey(for: asset)
            if !cache.peek(key) {
                try cache.store(image: filler, for: key)
                filled += 1
            }
        }
        let missing = session.assets.filter {
            !cache.peek(ThumbnailProvider.hdJPEGKey(for: $0))
        }.count
        var startRow: CGFloat = 0
        print("437 A⑨ preflight: \(session.assets.count) assets, filled \(filled), "
              + "still missing \(missing)")

        let h = try makeHarness(session)
        h.waitForBands(300)
        // Where the measured run starts, the band must already be warm; otherwise the first jump
        // itself would be the sample. Only the stepping loop below is under test.
        h.scrollRows(startRow)
        h.waitForBands(300)

        h.provider.resetStats()
        let before = h.provider.stats
        let pitch = h.rowPitch
        var placeholderFrames = 0
        var samples = 0
        var maxOutside = 0
        var maxQueue = 0
        var placeholderSamples: [String] = []

        for _ in 0..<200 {
            startRow += 0.25
            h.scrollRows(startRow)
            RunLoop.current.run(until: Date().addingTimeInterval(1.0 / 60.0))
            h.grid.reconcileThumbnailsForTesting(force: false)
            h.grid.view.layoutSubtreeIfNeeded()
            samples += 1
            if h.grid.visibleThumbnailCount < h.grid.visibleCellCount {
                placeholderFrames += 1
                if placeholderSamples.count < 8 {
                    let missingCells = h.grid.collectionView.indexPathsForVisibleItems()
                        .filter {
                            guard let cell = h.grid.collectionView.item(at: $0) as? AssetGridItem
                            else { return true }
                            return cell.cardView.thumbnail == nil
                        }
                        .map(\.item).sorted()
                    placeholderSamples.append("step\(samples) row\(String(format: "%.2f", startRow)) "
                        + "\(h.grid.visibleThumbnailCount)/\(h.grid.visibleCellCount) "
                        + "pending\(h.grid.pendingThumbnailRequests) missing\(missingCells)")
                }
            }
            maxOutside = max(maxOutside, h.grid.pendingThumbnailIndexesOutsideWindow)
            maxQueue = max(maxQueue, h.grid.thumbnailQueueDepth)
        }
        let after = h.provider.stats
        let service = h.provider.serviceStats
        print("437 A⑨ library \(session.assets.count) photos, \(h.columns) columns, "
              + "pitch \(Int(pitch)) pt, 200 steps × 0.25 row = \(Int(startRow)) rows")
        print("437 A⑨ placeholder frames \(placeholderFrames)/\(samples) \(placeholderSamples)"
              + " generated +\(after.generated - before.generated)"
              + " disk +\(after.diskHits - before.diskHits)"
              + " memory +\(after.memoryHits - before.memoryHits)"
              + " maxOutside \(maxOutside) maxQueue \(maxQueue)")
        print("437 A⑨ service activePeak \(service.activePeak)/\(service.maxConcurrency) "
              + "queuedPeak \(service.queuedPeak) warmRequests \(h.grid.warmRequests)")

        XCTAssertLessThanOrEqual(placeholderFrames, 1,
                                 "only the first frame may still show a placeholder")
        XCTAssertEqual(missing, 0, "the fixture is fully cached before the run")
        XCTAssertEqual(after.generated - before.generated, 0, "every warmed photo is a disk hit")
        XCTAssertEqual(maxOutside, 0, "nothing left the ±12-row wide band")
        XCTAssertLessThanOrEqual(maxQueue, 12 + 2 * h.columns,
                                 "the queue is bounded by the warm ring, not the library")
    }

    /// APFS clone when possible (`cp -cR`), a plain copy otherwise. Keeps A⑨ from spending its
    /// budget writing 242 MB of JPEGs.
    private func clone(_ from: URL, to: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-cR", from.path, to.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: to)
            try FileManager.default.copyItem(at: from, to: to)
        }
    }
}
