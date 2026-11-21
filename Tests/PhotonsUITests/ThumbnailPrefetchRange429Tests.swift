import XCTest
import AppKit
import GRDB
import ImageIO
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 429 — **the three prefetch bands are now wide enough that one scroll is a memory hit.**
///
/// The user's ask (2026-11-19) is three numbers:
///
/// > 「网格上下各 4 行，胶片条左右各 10 个」「侧栏也一样加入 10 个」
///
/// The mechanism already existed (`wanted` = visible + slack; anything that leaves it is cancelled)
/// — only the slack was one row / one cell / five rows. These tests measure the *shipping* views in
/// a real window (`TestWindows`), because the claim behind the ask — "scrolling no longer shows the
/// solid placeholder" — is about what a live cell draws, not about arithmetic:
///
/// * **A④** the band's size: grid = visible + `AssetGridController.coreSlackRows` rows, filmstrip =
///   visible + 10 cells, list = visible + 10 rows;
/// * **A①/A②/A③** a one-screen scroll on each surface is served from a cache: `memoryHits` grows,
///   `diskHits`/`generated` stay at 0;
/// * **A⑤** dragging to the bottom cancels what left the band: `pendingThumbnailRequests` is bounded
///   by the band, never by the library, and nothing outside the window is ever left queued;
/// * **A⑥** the three bands together fit the provider's 256 MB LRU (same `w · h · 8` cost the
///   provider charges `NSCache`), including the 12-column worst case in §0.3.
@MainActor
final class ThumbnailPrefetchRange429Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []
    /// Panel widths whose `GridLayout.metrics` resolve to exactly 6 / 9 / 12 columns.
    private static let columnWidths: [CGFloat] = [992, 1478, 1964]

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-prefetch429-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    /// All `L10304xx` samples on this machine that ImageIO can open (the folder also holds a few
    /// damaged/odd files, and a fixture that fails to decode would measure the failure path instead
    /// of the cache).
    private static func readableSamples() -> [URL] {
        let dir = URL(fileURLWithPath: NSString(string: "~/Desktop/test").expandingTildeInPath)
        let folder = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() } ?? dir
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dng") }.sorted()
        return names.map { folder.appendingPathComponent($0) }.filter { url in
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            return CGImageSourceGetCount(source) > 0
        }
    }

    /// A packaged library over `rowCount` symlinks to real RAWs, so thumbnails are genuinely
    /// produced and genuinely cached (a fabricated hash would only measure the failure path).
    ///
    /// The pool is reused cyclically when `rowCount` exceeds the number of samples on this machine:
    /// every row still has its own `contentHash`, so it is its own cache key, and the A⑤ drag test
    /// needs a library many screens tall while never letting a render run (the service is paused).
    private func makeSession(rowCount: Int) throws -> CatalogSession {
        let pool = Self.readableSamples()
        guard !pool.isEmpty else {
            throw XCTSkip("no readable DNGs; set PHOTONS_TEST_RAW")
        }
        let package = tmp.appendingPathComponent("p429-\(rowCount).photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: package)
        let source = tmp.appendingPathComponent("src-\(rowCount)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)
        for index in 0..<rowCount {
            let link = source.appendingPathComponent("shot\(index).dng")
            try FileManager.default.createSymbolicLink(
                at: link, withDestinationURL: pool[index % pool.count])
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, imported_at, missing)
                    VALUES (?, ?, ?, ?, 'dng', 'raw', 4096, 0, ?, 9520, 6336,
                            '2026-11-19T00:00:00Z', 0)
                    """, arguments: ["a\(index)", root.id, "shot\(index).dng", "shot\(index).dng",
                                     String(format: "%064x", index + 1)])
            }
        }
        let session = CatalogSession()
        try session.open(package)
        XCTAssertEqual(session.assets.count, rowCount)
        return session
    }

    // MARK: - harness

    @MainActor
    private final class Harness {
        let session: CatalogSession
        let grid: AssetGridController
        let strip: FilmstripController
        let pane: BrowserPaneController
        let window: NSWindow
        let provider: ThumbnailProvider

        init(session: CatalogSession, window: NSWindow) {
            self.session = session
            self.window = window
            grid = AssetGridController(session: session)
            strip = FilmstripController(session: session)
            pane = BrowserPaneController(session: session)
            _ = grid.view
            _ = strip.view
            _ = pane.view
            // One window, three surfaces. The grid is deliberately narrow (3 columns) so a screenful
            // is small and the band is the thing under test; they overlap — this is a layout host.
            grid.view.frame = NSRect(x: 300, y: 0, width: 520, height: 620)
            strip.view.frame = NSRect(x: 300, y: 640, width: 520,
                                      height: WorkspaceLayout.filmstripHeight)
            pane.view.frame = NSRect(x: 0, y: 0, width: 280, height: 780)
            let content = window.contentView ?? NSView(frame: .zero)
            for v in [grid.view, pane.view, strip.view] { content.addSubview(v) }
            content.layoutSubtreeIfNeeded()
            if let existing = grid.thumbnailProviderForSmoke {
                provider = existing
            } else if let cache = session.thumbnailCache {
                provider = ThumbnailProvider.shared(for: cache)
            } else {
                fatalError("the fixture library must have a thumbnail cache")
            }
            settle(6)
        }

        func settle(_ turns: Int = 4) {
            for _ in 0..<turns { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            grid.view.layoutSubtreeIfNeeded()
            strip.view.layoutSubtreeIfNeeded()
            pane.view.layoutSubtreeIfNeeded()
        }

        var busy: Int {
            grid.pendingThumbnailRequests + strip.pendingThumbnailRequests
                + pane.pendingThumbnailRequests
        }

        /// Wait until the shared pipeline has delivered everything in the three bands.
        func waitForBands(_ seconds: TimeInterval = 300) {
            let deadline = Date().addingTimeInterval(seconds)
            var idleTurns = 0
            while Date() < deadline {
                settle(2)
                if busy == 0 {
                    idleTurns += 1
                    if idleTurns >= 3 { return }
                } else {
                    idleTurns = 0
                }
            }
            XCTFail("thumbnail bands did not settle in \(Int(seconds)) s (pending \(busy))")
        }

        var gridScroll: NSScrollView { grid.scrollView }
        var stripScroll: NSScrollView { strip.view as! NSScrollView }
        var paneScroll: NSScrollView { pane.photoListForTesting.enclosingScrollView! }

        /// Row index → grid row, from the applied columns.
        func rows(_ indexes: Set<Int>) -> Set<Int> {
            let columns = max(1, grid.metrics.columns)
            return Set(indexes.map { $0 / columns })
        }
    }

    /// The library every test starts from: 40 rows is 14 grid screens, plenty for A④/A①/A⑥.
    private static let rowCount = 40
    /// A⑤'s library: tall enough that a full drag visits screens the band never covers, so a lost
    /// cancel would be visible as a growing queue.
    private static let dragRowCount = 400

    private func makeHarness(rowCount: Int = ThumbnailPrefetchRange429Tests.rowCount) throws -> Harness {
        let session = try makeSession(rowCount: rowCount)
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
        windows.append(window)
        let harness = Harness(session: session, window: window)
        harness.waitForBands()
        return harness
    }

    private func scroll(_ scrollView: NSScrollView, to point: NSPoint) {
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - A④ the three bands' sizes

    func testTheBandsAreCoreSlackRowsTenCellsAndTenRows() throws {
        let h = try makeHarness()
        let columns = max(1, h.grid.metrics.columns)
        let coreRows = Int(AssetGridController.coreSlackRows)

        // The strip is measured **in the middle**: at the left end of the library the left half of
        // the band is clipped by the model, which would read as 9 instead of 10.
        let cellStep = h.strip.appliedItemSize.width + WorkspaceLayout.filmstripSpacing
        scroll(h.stripScroll, to: NSPoint(x: cellStep * 15, y: 0))
        h.settle(6)

        let visibleGrid = Set(h.grid.collectionView.indexPathsForVisibleItems().map(\.item))
        let wantedGrid = h.grid.wantedIndexes()
        let visibleStrip = Set(h.strip.collectionView.indexPathsForVisibleItems().map(\.item))
        let wantedStrip = h.strip.wantedIndexes()
        let visibleRows = h.pane.visiblePhotoRowCount
        let wantedRows = h.pane.wantedRows()

        let visibleGridRows = h.rows(visibleGrid)
        let lastGridRow = max(0, (h.session.assets.count - 1) / columns)
        let firstVisibleRow = try XCTUnwrap(visibleGridRows.min())
        let lastVisibleRow = try XCTUnwrap(visibleGridRows.max())
        let expectedWantedRows = Set(firstVisibleRow...min(lastGridRow, lastVisibleRow + coreRows))
        let gridRowsBelow = (wantedGrid.max() ?? 0) / columns - (visibleGrid.max() ?? 0) / columns
        let stripLeft = (visibleStrip.min() ?? 0) - (wantedStrip.min() ?? 0)
        let stripRight = (wantedStrip.max() ?? 0) - (visibleStrip.max() ?? 0)
        print("429 A④ grid: visible \(visibleGrid.count) (\(h.rows(visibleGrid).count) rows, "
              + "\(columns) columns) wanted \(wantedGrid.count), \(gridRowsBelow) rows of slack below"
              + " visibleRows \(h.rows(visibleGrid).sorted()) "
              + "wantedRows \(h.rows(wantedGrid).sorted())")
        print("429 A④ strip (mid): visible \(visibleStrip.count) wanted \(wantedStrip.count) "
              + "left +\(stripLeft) right +\(stripRight)")
        print("429 A④ list: visible \(visibleRows) wanted \(wantedRows.count) "
              + "(+\(wantedRows.count - visibleRows))")

        // Grid: coreSlackRows of slack past the last visible row (the top is clipped at row 0
        // because the list starts at the top, which is where the band's lower edge meets the model).
        XCTAssertTrue((coreRows...(coreRows + 1)).contains(gridRowsBelow),
                      "429: the grid band is \(coreRows) rows past the screen, got \(gridRowsBelow)")
        XCTAssertEqual(h.rows(wantedGrid), expectedWantedRows,
                       "\(coreRows) rows of slack + the visible rows at \(columns) columns")
        XCTAssertLessThanOrEqual(wantedGrid.count,
                                 (visibleGridRows.count + coreRows + 1) * columns)

        // Filmstrip: ten cells of slack on **each** side, measured in the middle of the library (at
        // the left end the left half is clipped by index 0). The count reads 9–11 because the
        // expanded rect is `10 × itemSize.width` and a partially visible cell at either edge is
        // counted only once — so the distance is asserted too, which is the multiplier itself.
        let frames = h.strip.laidOutItemFrames
        let leftDistance = frames[visibleStrip.min()!].minX - frames[wantedStrip.min()!].minX
        let rightDistance = frames[wantedStrip.max()!].maxX - frames[visibleStrip.max()!].maxX
        print("429 A④ strip distance: left \(Int(leftDistance)) pt right \(Int(rightDistance)) pt "
              + "(cell step \(Int(cellStep)))")
        XCTAssertTrue((9...11).contains(stripLeft),
                      "429: ten cells of slack on the left, got \(stripLeft)")
        XCTAssertTrue((9...11).contains(stripRight),
                      "429: ten cells of slack on the right, got \(stripRight)")
        XCTAssertGreaterThanOrEqual(leftDistance, cellStep * 9,
                                    "left slack is ten cell widths, not one")
        XCTAssertGreaterThanOrEqual(rightDistance, cellStep * 9,
                                    "right slack is ten cell widths, not one")
        XCTAssertLessThanOrEqual(wantedStrip.count, visibleStrip.count + 22)

        // Browser list: `visible.location == 0` at the top, so the band is exactly visible + 10.
        XCTAssertEqual(wantedRows.count, visibleRows + 10,
                       "429: 侧栏 visible + 10 rows (clipped at row 0)")

        // Nothing outside a band is outstanding.
        XCTAssertEqual(h.grid.pendingThumbnailIndexesOutsideWindow, 0)
        XCTAssertEqual(h.strip.pendingThumbnailIndexesOutsideWindow, 0)
        XCTAssertEqual(h.pane.pendingThumbnailIndexesOutsideWindow, 0)
    }

    // MARK: - A① A② A③ a one-screen scroll is a memory hit

    func testScrollingOneScreenOnEachSurfaceHitsTheMemoryCache() throws {
        let h = try makeHarness()

        // ── grid: down by one viewport ─────────────────────────────────────────────────────────
        h.provider.resetStats()
        let gridBefore = h.grid.thumbnailStats
        let gridStep = h.gridScroll.contentView.bounds.height
        scroll(h.gridScroll, to: NSPoint(x: 0, y: gridStep))
        h.settle(8)
        let gridAfter = h.grid.thumbnailStats
        let gridVisible = h.grid.visibleCellCount
        print("429 A① grid +\(Int(gridStep)) pt: memory +\(gridAfter.memoryHits - gridBefore.memoryHits)"
              + " disk +\(gridAfter.diskHits - gridBefore.diskHits)"
              + " generated +\(gridAfter.generated - gridBefore.generated)"
              + " drawing \(h.grid.visibleThumbnailCount)/\(gridVisible)")
        XCTAssertGreaterThan(gridAfter.memoryHits, gridBefore.memoryHits,
                             "cells that just scrolled in must come from the LRU")
        XCTAssertEqual(gridAfter.diskHits - gridBefore.diskHits, 0, "no file I/O for a warmed band")
        XCTAssertEqual(gridAfter.generated - gridBefore.generated, 0, "no render for a warmed band")
        XCTAssertEqual(h.grid.visibleThumbnailCount, gridVisible,
                       "every visible grid cell draws a real bitmap (no solid placeholder)")
        XCTAssertEqual(h.grid.pendingThumbnailIndexesOutsideWindow, 0)

        // ── filmstrip: right by five cells (one screen of the 90 pt strip) ────────────────────
        h.provider.resetStats()
        let stripBefore = h.strip.thumbnailStats
        let cellStep = h.strip.appliedItemSize.width + WorkspaceLayout.filmstripSpacing
        scroll(h.stripScroll, to: NSPoint(x: cellStep * 5, y: 0))
        h.settle(8)
        let stripAfter = h.strip.thumbnailStats
        let stripVisible = h.strip.visibleCellCount
        print("429 A② strip +\(Int(cellStep * 5)) pt: memory +\(stripAfter.memoryHits - stripBefore.memoryHits)"
              + " disk +\(stripAfter.diskHits - stripBefore.diskHits)"
              + " generated +\(stripAfter.generated - stripBefore.generated)"
              + " drawing \(h.strip.visibleThumbnailCount)/\(stripVisible)")
        XCTAssertGreaterThan(stripAfter.memoryHits, stripBefore.memoryHits)
        XCTAssertEqual(stripAfter.diskHits - stripBefore.diskHits, 0, "no file I/O for a warmed band")
        XCTAssertEqual(stripAfter.generated - stripBefore.generated, 0)
        XCTAssertEqual(h.strip.visibleThumbnailCount, stripVisible,
                       "every visible strip cell draws a real bitmap")
        XCTAssertEqual(h.strip.pendingThumbnailIndexesOutsideWindow, 0)

        // ── sidebar: down by ten rows (exactly the new slack) ─────────────────────────────────
        h.provider.resetStats()
        let paneBefore = h.pane.thumbnailStats
        let rowStep = WorkspaceLayout.browserRowHeight
        scroll(h.paneScroll, to: NSPoint(x: 0, y: rowStep * 10))
        h.settle(8)
        let paneAfter = h.pane.thumbnailStats
        let paneVisible = h.pane.visiblePhotoRowCount
        print("429 A③ list +\(Int(rowStep * 10)) pt: memory +\(paneAfter.memoryHits - paneBefore.memoryHits)"
              + " disk +\(paneAfter.diskHits - paneBefore.diskHits)"
              + " generated +\(paneAfter.generated - paneBefore.generated)"
              + " drawing \(h.pane.visibleThumbnailCount)/\(paneVisible)")
        XCTAssertGreaterThan(paneAfter.memoryHits, paneBefore.memoryHits)
        XCTAssertEqual(paneAfter.diskHits - paneBefore.diskHits, 0, "no file I/O for a warmed band")
        XCTAssertEqual(paneAfter.generated - paneBefore.generated, 0)
        XCTAssertEqual(h.pane.visibleThumbnailCount, paneVisible,
                       "every visible list row draws a real bitmap")
        XCTAssertEqual(h.pane.pendingThumbnailIndexesOutsideWindow, 0)
    }

    // MARK: - A⑤ cancel keeps the queue bounded

    func testDraggingToTheBottomCancelsWorkOutsideTheBand() throws {
        let h = try makeHarness(rowCount: Self.dragRowCount)
        let content = h.grid.collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
        let viewport = h.gridScroll.contentView.bounds.height
        let maxOffset = max(0, content - viewport)
        let cancelledBefore = h.grid.thumbnailStats.cancelled

        var peakPending = 0
        var peakOutside = 0
        // Twelve jumps with only a frame between them. Each one asks for a fresh band that the
        // worker pool cannot possibly have produced yet, so the previous region's asks are still
        // outstanding when the next lands — exactly when "cancel what scrolled away" has to run.
        for step in 1...12 {
            scroll(h.gridScroll, to: NSPoint(x: 0, y: maxOffset * CGFloat(step) / 12))
            h.settle(4)
            peakPending = max(peakPending, h.grid.pendingThumbnailRequests)
            peakOutside = max(peakOutside, h.grid.pendingThumbnailIndexesOutsideWindow)
        }
        let band = h.grid.wantedIndexes()
        let columns = max(1, h.grid.metrics.columns)
        let cancelled = h.grid.thumbnailStats.cancelled - cancelledBefore
        print("429 A⑤ drag to bottom: band \(band.count) peak pending \(peakPending)"
              + " peak outside \(peakOutside) cancelled +\(cancelled)"
              + " library \(Self.dragRowCount)")

        XCTAssertEqual(peakOutside, 0,
                       "after each scroll handler runs, nothing outside the band is still queued")
        // 429 — **the gate that actually tests the cancellation.** `peakOutside` above can read 0 even
        // with the `where !wanted.contains(index)` loop deleted, because `thumbnailDidLoad` clears an
        // entry the moment its request lands: with four-frame settles the queue drains before the next
        // reading, so the measurement never sees the stale entries. `lastRebuildOutsideCount` is
        // written **at the end of the rebuild itself**, before any landing can interfere, so it is 0
        // iff the loop ran. Deleting the loop makes this assertion fail — verified as ⑧d.
        XCTAssertEqual(h.grid.lastRebuildOutsideCount, 0,
                       "the rebuild must leave nothing queued outside its own band")
        // 429 — the ceiling is the **widest** band seen during the drag, not the band at the end:
        // `band` is read after the last jump, and a drag through 400 photos passes through positions
        // whose band is wider than the bottom one's. The bound is derived from the geometry, not a
        // literal: the outer ring is ±`warmSlackRows` (12) ⇒ 2×12 = 24 rows either side; this
        // fixture's 620 pt viewport shows at most 4 rows ⇒ (2·12 + 4) rows × 3 columns = 84 cells.
        // Measured (469, ±10 core): peak 81 against that 84 ceiling, with `peakOutside == 0` and 312
        // cancellations — i.e. the invariant that matters ("nothing outside the band is queued")
        // holds; this one only bounds the *transient*. The real claim is "bounded by a band, not by
        // the library": 400 photos must never queue anywhere near 400.
        XCTAssertLessThanOrEqual(peakPending,
                                 (2 * Int(AssetGridController.warmSlackRows) + 4) * columns,
                                 "pending is bounded by a band, not by the library (\(Self.dragRowCount) rows)")
        XCTAssertGreaterThan(cancelled, 0,
                             "a drag over 400 photos must have cancelled the regions it left")

        // The band that survived the drag still fills in.
        h.waitForBands(180)
        print("429 A⑤ at the bottom: final pending \(h.grid.pendingThumbnailRequests)"
              + " drawing \(h.grid.visibleThumbnailCount)/\(h.grid.visibleCellCount)")
        XCTAssertEqual(h.grid.visibleThumbnailCount, h.grid.visibleCellCount,
                       "the band that survived the drag still fills in")
        XCTAssertEqual(h.grid.pendingThumbnailRequests, 0)
    }

    // MARK: - A⑥ memory cost

    func testTheThreeBandsFitTheMemoryBudget() throws {
        let h = try makeHarness()
        func bytes(_ image: ImageSize, _ count: Int) -> Int {
            // The provider's own cost formula (`remember`: w · h · 8, a half-float RGBA bitmap).
            max(1, image.width * image.height * 8) * count
        }
        func mb(_ value: Int) -> Double { Double(value) / (1024 * 1024) }

        let gridBand = bytes(h.grid.displayPixelSize, h.grid.wantedIndexes().count)
        let stripBand = bytes(h.strip.displayPixelSize, h.strip.wantedIndexes().count)
        let listBand = bytes(h.pane.displayPixelSize, h.pane.wantedRows().count)
        let live = gridBand + stripBand + listBand
        print(String(format: "429 A⑥ live: grid %.1f MB (%dx%d x %d) strip %.1f MB list %.1f MB total %.1f MB",
                     mb(gridBand), h.grid.displayPixelSize.width, h.grid.displayPixelSize.height,
                     h.grid.wantedIndexes().count, mb(stripBand), mb(listBand), mb(live)))
        XCTAssertLessThanOrEqual(live, ThumbnailProvider.memoryByteLimit,
                                 "the three live bands must fit the 256 MB LRU")

        // §0.3's worst case: a 12-column grid whose outer ring is ±`warmSlackRows` (the widest band
        // that may hold requests) + 20 strip + 20 list.
        let scale = h.window.backingScaleFactor
        let ringRows = Int(AssetGridController.warmSlackRows) * 2
        var widest = 0
        for width in Self.columnWidths {
            let metrics = GridLayout.metrics(forWidth: width)
            let display = ThumbnailProvider.displayPixels(
                swatch: CGSize(width: metrics.itemSize.width,
                               height: metrics.itemSize.height - GridLayout.labelHeight),
                backingScale: scale)
            let band = bytes(display, ringRows * metrics.columns)
            widest = max(widest, band)
            print(String(format: "429 A④ %d columns: cell %dx%d band %d cells = %.1f MB",
                         metrics.columns, display.width, display.height,
                         ringRows * metrics.columns, mb(band)))
        }
        let worst = widest
            + bytes(h.strip.displayPixelSize, 20)
            + bytes(h.pane.displayPixelSize, 20)
        print(String(format: "429 A⑥ worst (12-col grid + 20 + 20): %.1f MB of %d MB",
                     mb(worst), ThumbnailProvider.memoryByteLimit / (1024 * 1024)))
        XCTAssertLessThanOrEqual(Double(worst), Double(ThumbnailProvider.memoryByteLimit) * 1.2)
        XCTAssertEqual(GridLayout.metrics(forWidth: 992).columns, 6)
        XCTAssertEqual(GridLayout.metrics(forWidth: 1478).columns, 9)
        XCTAssertEqual(GridLayout.metrics(forWidth: 1964).columns, 12)
    }
}
