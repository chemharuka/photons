import XCTest
import AppKit
import GRDB
import ImageIO
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 449 — **a continuous scroll must reconcile, not wait for the user to stop.**
///
/// The user's report (2026-11-20) is one sentence:
///
/// > 「在滚动时就要提前加载……但如果连续滚动，不会动态加载」
///
/// The old throttle was a pure 40 ms trailing debounce that every `boundsDidChange` cancelled. A
/// live scroll emits a change every 8–16 ms, so the reconcile never ran until the scroll stopped.
/// These tests drive the shipping views at a real 8 ms cadence (50 steps = 400 ms) and count:
///
/// * `reconcileRunCount` — the shared `ScrollReconcileGate` must run ≥ 3 times in 400 ms;
/// * `prefetchRequestCount` / `prefetchRequestedRows` — prefetch asks must actually be issued
///   during the scroll, for rows outside the visible set;
/// * a **pure trailing** reference driven by the same steps count must stay ≤ 1, so the same
///   assertion fails on the old implementation.
@MainActor
final class ScrollPrefetchContinuous449Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-scroll449-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixture

    private static func readableSamples() -> [URL] {
        let folder = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"]
            .map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
            ?? URL(fileURLWithPath: NSString(string: "~/Desktop/test").expandingTildeInPath)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dng") }.sorted()
        return names.map { folder.appendingPathComponent($0) }.filter { url in
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
            return CGImageSourceGetCount(source) > 0
        }
    }

    /// A packaged library over real RAWs, like the 429/437 acceptances: every row has its own
    /// `content_hash`, so every row is its own cache key and a request is genuinely issued.
    private func makeSession(rowCount: Int) throws -> CatalogSession {
        let pool = Self.readableSamples()
        guard !pool.isEmpty else {
            throw XCTSkip("no readable DNGs; set PHOTONS_TEST_RAW")
        }
        let package = tmp.appendingPathComponent("p449-\(rowCount).photonslibrary", isDirectory: true)
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
                            '2026-11-20T00:00:00Z', 0)
                    """, arguments: ["a\(index)", root.id, "shot\(index).dng", "shot\(index).dng",
                                     String(format: "%064x", index + 1)])
            }
        }
        let session = CatalogSession()
        try session.open(package)
        XCTAssertEqual(session.assets.count, rowCount)
        return session
    }

    private func makeWindow(_ size: NSSize) -> NSWindow {
        let window = TestWindows.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(origin: .zero, size: size))
        windows.append(window)
        return window
    }

    // MARK: - driving

    /// Scroll and then let the run loop run for exactly `interval`. The deadline loop matters: if
    /// `run(mode:before:)` returns early for lack of a source, the step would otherwise be much
    /// faster than 8 ms and the 120 ms cap would never be reached.
    private func step(_ interval: TimeInterval = 0.008, _ body: () -> Void) {
        body()
        let deadline = Date().addingTimeInterval(interval)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }

    private func scroll(_ scrollView: NSScrollView, to point: NSPoint) {
        scrollView.contentView.scroll(to: point)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func drive(_ steps: Int = 50, interval: TimeInterval = 0.008,
                       _ body: (Int) -> Void) {
        for index in 0..<steps {
            step(interval) { body(index) }
        }
        // Let the trailing work item (40 ms after the last note) run.
        RunLoop.current.run(until: Date().addingTimeInterval(0.06))
    }

    // MARK: - A① sidebar

    func testSidebarReconcilesAndPrefetchesDuringContinuousScroll() throws {
        let session = try makeSession(rowCount: 120)
        let window = makeWindow(NSSize(width: 280, height: 780))
        let pane = BrowserPaneController(session: session)
        _ = pane.view
        pane.view.frame = NSRect(x: 0, y: 0, width: 280, height: 780)
        window.contentView?.addSubview(pane.view)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        pane.view.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(pane.photoListForTesting.enclosingScrollView)
        let rowStep = WorkspaceLayout.browserRowHeight
        let maxOffset = max(0, pane.photoListForTesting.bounds.height
                               - scrollView.contentView.bounds.height)
        pane.resetScrollCountersForTesting()

        drive { index in
            let offset = min(maxOffset, CGFloat(index + 1) * rowStep * 0.8)
            scroll(scrollView, to: NSPoint(x: 0, y: offset))
        }

        let visible = pane.visibleRows()
        let wanted = pane.wantedRows()
        let prefetched = pane.prefetchRequestedRows
        print("449 A① list: gate runs \(pane.reconcileRunCount), prefetch asks "
              + "\(pane.prefetchRequestCount), prefetched rows \(prefetched.count), "
              + "visible \(visible.count), wanted \(wanted.count)")

        XCTAssertGreaterThanOrEqual(pane.reconcileRunCount, 3,
                                    "400 ms of continuous scrolling must reconcile ≥ 3 times")
        XCTAssertGreaterThanOrEqual(pane.prefetchRequestCount,
                                    BrowserPaneController.prefetchSlackRows,
                                    "the band beyond the viewport must actually be requested")
        XCTAssertGreaterThanOrEqual(prefetched.subtracting(visible).count,
                                    BrowserPaneController.prefetchSlackRows,
                                    "prefetch rows must lie outside the visible rows")
    }

    // MARK: - A② grid

    func testGridReconcilesAndPrefetchesDuringContinuousScroll() throws {
        let session = try makeSession(rowCount: 160)
        let window = makeWindow(NSSize(width: 520, height: 620))
        let grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: 520, height: 620)
        window.contentView?.addSubview(grid.view)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        grid.view.layoutSubtreeIfNeeded()

        let scrollView = grid.scrollView
        let content = grid.collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
        let maxOffset = max(0, content - scrollView.contentView.bounds.height)
        grid.resetScrollCountersForTesting()

        drive { index in
            let offset = min(maxOffset, CGFloat(index + 1) * 40)
            scroll(scrollView, to: NSPoint(x: 0, y: offset))
        }

        let visible = grid.visibleIndexes()
        let prefetched = grid.prefetchRequestedIndexes
        print("449 A② grid: gate runs \(grid.reconcileRunCount), prefetch asks "
              + "\(grid.prefetchRequestCount), prefetched items \(prefetched.count), "
              + "visible \(visible.count)")

        XCTAssertGreaterThanOrEqual(grid.reconcileRunCount, 3,
                                    "400 ms of continuous scrolling must reconcile ≥ 3 times")
        XCTAssertGreaterThanOrEqual(grid.prefetchRequestCount, 10,
                                    "the grid must request its off-screen band during the scroll")
        XCTAssertGreaterThanOrEqual(prefetched.subtracting(visible).count, 10,
                                    "prefetch items must lie outside the visible cells")
    }

    // MARK: - A③ filmstrip

    func testFilmstripReconcilesAndPrefetchesDuringContinuousScroll() throws {
        let session = try makeSession(rowCount: 120)
        let window = makeWindow(NSSize(width: 520, height: 160))
        let strip = FilmstripController(session: session)
        _ = strip.view
        strip.view.frame = NSRect(x: 0, y: 0, width: 520,
                                  height: WorkspaceLayout.filmstripHeight)
        window.contentView?.addSubview(strip.view)
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<6 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        strip.view.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(strip.view as? NSScrollView)
        let content = strip.collectionView.collectionViewLayout?
            .collectionViewContentSize.width ?? 0
        let maxOffset = max(0, content - scrollView.contentView.bounds.width)
        strip.resetScrollCountersForTesting()

        drive { index in
            let offset = min(maxOffset, CGFloat(index + 1) * 40)
            scroll(scrollView, to: NSPoint(x: offset, y: 0))
        }

        let visible = strip.visibleIndexes()
        let prefetched = strip.prefetchRequestedIndexes
        print("449 A③ strip: gate runs \(strip.reconcileRunCount), prefetch asks "
              + "\(strip.prefetchRequestCount), prefetched items \(prefetched.count), "
              + "visible \(visible.count)")

        XCTAssertGreaterThanOrEqual(strip.reconcileRunCount, 3,
                                    "400 ms of continuous scrolling must reconcile ≥ 3 times")
        XCTAssertGreaterThanOrEqual(strip.prefetchRequestCount, 10,
                                    "the filmstrip must request its off-screen band during the scroll")
        XCTAssertGreaterThanOrEqual(prefetched.subtracting(visible).count, 10,
                                    "prefetch items must lie outside the visible cells")
    }

    // MARK: - reverse control

    /// The old shape, kept in this file as the reference: cancel and reschedule 40 ms after every
    /// note. The same 8 ms steps leave it with at most one run (the one after the scroll stops).
    private final class PureTrailingReference {
        private var work: DispatchWorkItem?
        private(set) var runCount = 0

        func schedule() {
            work?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.runCount += 1 }
            work = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: item)
        }
    }

    func testPureTrailingReferenceCannotReconcileDuringTheSameScroll() {
        let reference = PureTrailingReference()
        drive { _ in reference.schedule() }
        print("449 reverse control: pure trailing runs \(reference.runCount) in the same 400 ms")
        XCTAssertLessThanOrEqual(reference.runCount, 1,
                                 "the old pure-trailing debounce must fail the ≥ 3 assertion")
    }
}
