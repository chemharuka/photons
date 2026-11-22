import XCTest
import AppKit
import GRDB
import ImageIO
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 502 — **the prefetch band is direction-aware**: it grows where the scroll is going.
///
/// The ask (2026-11-22):
///
/// > 「带宽改成方向感知（velocity-aware）：按滚动速度在运动方向上延长（比如 ±10 → ±10+2×行/秒，
/// >   上限 ±30）」
///
/// Two halves, and they are checked separately:
///
/// * **the pure half** (`ScrollVelocityBand`) — the arithmetic, the dead band, the smoothing and the
///   `Δt < 1 ms` guard, all with an injected clock so a "twenty rows per second" scroll is a number,
///   not a sleep;
/// * **the wiring** — the grid (`rows/s`), the sidebar (`rows/s`) and the filmstrip (`cells/s`) each
///   read their own `bounds` displacement, and the cancellation ring is always ≥ the forward band.
///
/// The property that must not regress is stated as a comparison, not a comment: at v = 0 every
/// surface's band is **the set the old arithmetic produces**, recomputed here from the live geometry
/// with the pre-502 formula (symmetric ±10 for the request band, ±12 / ±20 for the rings).
@MainActor
final class ScrollVelocityBand502Tests: XCTestCase {

    private var tmp: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        _ = NSApplication.shared
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-band502-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.close() }
        windows.removeAll()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - §3.1 the pure function

    func testRestingBandIsTenOnBothSides() {
        let rest = ScrollVelocityBand.slacks(rowsPerSecond: 0)
        XCTAssertEqual(rest.backward, 10)
        XCTAssertEqual(rest.forward, 10)
        XCTAssertEqual(ScrollVelocityBand.Sample.resting.isResting, true)
    }

    func testLeadingSideGrowsAtTwoUnitsPerSecond() {
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: 5).forward, 20)
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: 5).backward, 10)
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: 7).forward, 24)
        // floor, not round: 7.6 rows/s ⇒ 10 + floor(15.2) = 25.
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: 7.4).forward, 24)
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: 7.6).forward, 25)
        print("502 pure: v=5 → \(ScrollVelocityBand.slacks(rowsPerSecond: 5)), "
              + "v=7.6 → \(ScrollVelocityBand.slacks(rowsPerSecond: 7.6))")
    }

    func testCapIsThirty() {
        for speed in [10.0, 11.0, 30.0, 50.0, 1_000.0, 1e12] {
            let band = ScrollVelocityBand.slacks(rowsPerSecond: speed)
            XCTAssertEqual(band.forward, 30, "v=\(speed) must stop at the unit cap")
            XCTAssertEqual(band.backward, 10)
        }
        XCTAssertEqual(ScrollVelocityBand.cap, 30)
    }

    func testNegativeSpeedHasTheSameMagnitude() {
        // The *direction* comes from the sampler; `slacks` only answers "how far". A backward scroll
        // therefore gets the same extension, on the other side.
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: -5).forward, 20)
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: -10).forward, 30)
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: -50).forward, 30)
    }

    func testDriftBelowHalfAUnitPerSecondIsRest() {
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: 0.4).forward, 10)
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: -0.49).forward, 10)
        XCTAssertEqual(ScrollVelocityBand.slacks(rowsPerSecond: 0.5).forward, 11)
        print("502 pure: dead band 0.4 → \(ScrollVelocityBand.slacks(rowsPerSecond: 0.4).forward)")
    }

    func testSamplerSmoothsAcrossAStop() {
        var sampler = ScrollVelocityBand.Sampler()
        // 20 rows/s, sampled once per second. The first moving sample ramps (0.6 × 0 + 0.4 × 20),
        // the second is steady (0.6 × 20 + 0.4 × 20 = 20 → capped). Then the scroll stops: the first
        // stopped sample is still weighted 0.6 of the previous 20, the second reads a previous sample
        // of 0 and returns to the resting band.
        _ = sampler.sample(offset: 0, time: 0, unitPoints: 100, viewportSpan: 1_000)
        let ramping = sampler.sample(offset: 2_000, time: 1.0, unitPoints: 100, viewportSpan: 10_000)
        let steady = sampler.sample(offset: 4_000, time: 2.0, unitPoints: 100, viewportSpan: 10_000)
        let firstStop = sampler.sample(offset: 4_000, time: 3.0, unitPoints: 100, viewportSpan: 1_000)
        let secondStop = sampler.sample(offset: 4_000, time: 4.0, unitPoints: 100, viewportSpan: 1_000)
        print("502 pure: 20 rows/s → \(ramping.forward), \(steady.forward); stop → "
              + "\(firstStop.forward), → \(secondStop.forward)")
        XCTAssertEqual(steady.forward, 30, "20 rows/s is past the cap")
        XCTAssertGreaterThan(firstStop.forward, 10, "one stopped sample must not collapse the band")
        XCTAssertEqual(secondStop.forward, 10, "the second stopped sample is the resting band")
        XCTAssertEqual(secondStop.direction, .none)
    }

    func testSamplerJitterNeverCollapsesToRest() {
        // A trackpad that alternates 0 and 20 rows/s per sample is the case the smoothing exists for.
        // Without it the band would alternate 10 / 30; with it the minimum stays near the cap.
        var sampler = ScrollVelocityBand.Sampler()
        _ = sampler.sample(offset: 0, time: 0, unitPoints: 100, viewportSpan: 10_000)
        var forwards: [Int] = []
        var offset: CGFloat = 0
        for step in 1...20 {
            if step % 2 == 1 { offset += 2_000 }  // 20 rows/s for this sample…
            let sample = sampler.sample(offset: offset, time: Double(step),
                                        unitPoints: 100, viewportSpan: 10_000)
            forwards.append(sample.forward)
        }
        let unsmoothed = ScrollVelocityBand.slacks(rowsPerSecond: 0).forward
        print("502 pure: jitter forwards \(forwards) min \(forwards.min() ?? -1); "
              + "unsmoothed zero-sample would be \(unsmoothed)")
        XCTAssertGreaterThanOrEqual(forwards.min() ?? 0, 26,
                                    "smoothing must keep the band up through a jittery sample")
        XCTAssertEqual(unsmoothed, 10, "the reference the smoothing is protecting against")
    }

    func testSubMillisecondIntervalIsTreatedAsZeroSpeed() {
        var sampler = ScrollVelocityBand.Sampler()
        _ = sampler.sample(offset: 0, time: 10.0, unitPoints: 100, viewportSpan: 1_000)
        let tooClose = sampler.sample(offset: 900, time: 10.0005,
                                      unitPoints: 100, viewportSpan: 1_000)
        print("502 pure: Δt = 0.5 ms, 9 rows of displacement → forward \(tooClose.forward)")
        XCTAssertEqual(tooClose.forward, 10)
        XCTAssertEqual(tooClose.direction, .none)
    }

    func testDisplacementWiderThanTheViewportIsAJumpNotSpeed() {
        // `scroll(to:)` from a menu, "jump to photo", restoring a position: a viewport-plus jump in
        // one sample is not a velocity, and must not arm the widest band while nothing is moving.
        var sampler = ScrollVelocityBand.Sampler()
        _ = sampler.sample(offset: 0, time: 0, unitPoints: 100, viewportSpan: 700)
        let jump = sampler.sample(offset: 5_000, time: 0.05, unitPoints: 100, viewportSpan: 700)
        XCTAssertEqual(jump.forward, 10)
        XCTAssertEqual(jump.direction, .none)
    }

    func testCancellationRingAtRestIsTheShippedRing() {
        XCTAssertEqual(ScrollVelocityBand.cancellationRing(forward: 10, restingRing: 12), 12)
        XCTAssertEqual(ScrollVelocityBand.cancellationRing(forward: 10, restingRing: 20), 20)
        XCTAssertEqual(ScrollVelocityBand.cancellationRing(forward: 30, restingRing: 12), 40)
        XCTAssertEqual(ScrollVelocityBand.cancellationRing(forward: 30, restingRing: 20), 40)
    }

    // MARK: - §3.2 the grid: rows per second

    func testGridBandAtTwentyRowsPerSecond() throws {
        let session = try makeSession(rowCount: 60 * 6)
        let grid = try makeGrid(session)
        let columns = grid.metrics.columns
        let pitch = grid.metrics.rowHeight
        XCTAssertEqual(columns, 6)

        scrollGrid(grid, toRow: 20)
        grid.cancelScheduledThumbnailReconcileForTesting()
        // 2 rows of displacement in 100 ms = 20 rows/s, with a previous sample of 20 rows/s so the
        // smoothed speed is 20 (0.6 × 20 + 0.4 × 20) rather than a ramp.
        grid.primeVelocityForTesting(offsetDelta: 2 * pitch, seconds: 0.1,
                                     previousRowsPerSecond: 20)
        grid.reconcileThumbnailsForTesting()

        let visible = grid.visibleIndexes()
        let firstRow = try XCTUnwrap(visible.map { $0 / columns }.min())
        let lastRow = try XCTUnwrap(visible.map { $0 / columns }.max())
        let rows = Set(grid.coreWantedIndexes().map { $0 / columns })
        let below = (rows.max() ?? lastRow) - lastRow
        let above = firstRow - (rows.min() ?? firstRow)
        print("502 grid: visible rows \(firstRow)…\(lastRow) of \(grid.metrics.columns) cols; "
              + "band rows \(rows.min() ?? -1)…\(rows.max() ?? -1) = \(above) above / \(below) below")

        XCTAssertEqual(below, 30, "20 rows/s drives the leading side to the cap")
        XCTAssertEqual(above, 10, "the trailing side stays at the resting slack")
        XCTAssertTrue(rows.contains(lastRow + 30))
        XCTAssertFalse(rows.contains(lastRow + 33))
        XCTAssertTrue(rows.contains(firstRow - 10))
        XCTAssertFalse(rows.contains(firstRow - 13))
    }

    func testGridBandPointsBackwardWhenTheOffsetFalls() throws {
        let session = try makeSession(rowCount: 60 * 6)
        let grid = try makeGrid(session)
        let columns = grid.metrics.columns
        let pitch = grid.metrics.rowHeight

        scrollGrid(grid, toRow: 40)
        grid.cancelScheduledThumbnailReconcileForTesting()
        grid.primeVelocityForTesting(offsetDelta: -2 * pitch, seconds: 0.1,
                                     previousRowsPerSecond: 20)
        grid.reconcileThumbnailsForTesting()

        let visible = grid.visibleIndexes()
        let firstRow = try XCTUnwrap(visible.map { $0 / columns }.min())
        let lastRow = try XCTUnwrap(visible.map { $0 / columns }.max())
        let rows = Set(grid.coreWantedIndexes().map { $0 / columns })
        print("502 grid (up): visible \(firstRow)…\(lastRow), band \(rows.min() ?? -1)…"
              + "\(rows.max() ?? -1)")
        XCTAssertEqual(firstRow - (rows.min() ?? firstRow), 30, "scrolling up extends upward")
        XCTAssertEqual((rows.max() ?? lastRow) - lastRow, 10)
    }

    // MARK: - §3.2 the sidebar: rows per second

    func testSidebarBandAtTwentyRowsPerSecond() throws {
        let session = try makeSession(rowCount: 200)
        let pane = try makeSidebar(session)

        scrollSidebar(pane, toRow: 40)
        pane.cancelScheduledThumbnailReconcileForTesting()
        // 2 rows = 92 pt in 100 ms = 20 rows/s.
        pane.primeVelocityForTesting(offsetDelta: 2 * WorkspaceLayout.browserRowHeight,
                                     seconds: 0.1, previousRowsPerSecond: 20)
        pane.reconcileThumbnailsForTesting()

        let visible = pane.visibleRows()
        let first = try XCTUnwrap(visible.min())
        let last = try XCTUnwrap(visible.max())
        let wanted = pane.wantedRows()
        let ring = pane.outerWantedRows()
        print("502 sidebar: visible \(first)…\(last); wanted \(wanted.min() ?? -1)…"
              + "\(wanted.max() ?? -1); ring \(ring.min() ?? -1)…\(ring.max() ?? -1)")

        XCTAssertEqual(wanted, Set(max(0, first - 10)..<min(200, last + 1 + 30)),
                       "forward 30 rows, backward 10 rows, exactly")
        XCTAssertEqual(ring, Set(max(0, first - 20)..<min(200, last + 1 + 40)),
                       "the ring is max(2 × 10, forward + 10) = 40 ahead")
    }

    // MARK: - §3.2 the filmstrip: cells per second

    func testFilmstripBandAtTwentyCellsPerSecond() throws {
        let session = try makeSession(rowCount: 200)
        let strip = try makeFilmstrip(session)
        let unit = max(24, strip.appliedItemSize.width)

        scrollFilmstrip(strip, toOffset: 1_200)
        strip.cancelScheduledThumbnailReconcileForTesting()
        strip.primeVelocityForTesting(offsetDelta: 2 * unit, seconds: 0.1,
                                     previousCellsPerSecond: 20)
        strip.reconcileThumbnailsForTesting()

        let visible = strip.visibleIndexes()
        let first = try XCTUnwrap(visible.min())
        let last = try XCTUnwrap(visible.max())
        let wanted = strip.wantedIndexes()
        let rightSpan = (wanted.max() ?? last) - last
        let leftSpan = first - (wanted.min() ?? first)
        print("502 filmstrip: visible \(first)…\(last); wanted \(wanted.min() ?? -1)…"
              + "\(wanted.max() ?? -1) = \(leftSpan) left / \(rightSpan) right; ring 20/40")

        // Cell widths are unit + spacing, so a 30-*unit* extension is ~27 cells: the claim is stated
        // in concrete cells with the spacing taken into account, and the old ±10 lengths are the
        // discriminating floor (26 ≫ 10).
        XCTAssertTrue(wanted.contains(last + 26), "the forward reach is ~30 cells, not 10")
        XCTAssertFalse(wanted.contains(last + 41), "and it stops at the cap")
        XCTAssertTrue(wanted.contains(first - 10))
        XCTAssertFalse(wanted.contains(first - 13))
        XCTAssertGreaterThanOrEqual(rightSpan, 26)
        XCTAssertLessThanOrEqual(leftSpan, 11)
        XCTAssertTrue(wanted.isSubset(of: strip.outerWantedIndexes()),
                      "the ring is at least the forward band")
        XCTAssertGreaterThanOrEqual(strip.outerWantedIndexes().max()! - last, 34,
                                    "the ring is max(20, forward + 10) = 40 units ahead")
    }

    // MARK: - §3.3 at rest is the old band, as a set

    func testRestingGridBandIsTheOldArithmetic() throws {
        let session = try makeSession(rowCount: 60 * 6)
        let grid = try makeGrid(session)
        grid.reconcileThumbnailsForTesting()

        let bounds = grid.scrollView.contentView.bounds
        let pitch = max(24, grid.metrics.rowHeight)
        let oldCore = indexes(grid, in: bounds.insetBy(dx: 0, dy: -pitch * 10))
        let oldWide = indexes(grid, in: bounds.insetBy(dx: 0, dy: -pitch * 12))

        print("502 rest grid: core \(grid.coreWantedIndexes().count) = old \(oldCore.count); "
              + "ring \(grid.wideWantedIndexes().count) = old \(oldWide.count)")
        XCTAssertEqual(grid.coreWantedIndexes(), oldCore)
        XCTAssertEqual(grid.wideWantedIndexes(), oldWide)
    }

    func testRestingSidebarBandIsTheOldArithmetic() throws {
        let session = try makeSession(rowCount: 200)
        let pane = try makeSidebar(session)
        pane.reconcileThumbnailsForTesting()

        let visible = pane.visibleRows()
        let first = try XCTUnwrap(visible.min())
        let last = try XCTUnwrap(visible.max())
        let oldWanted = Set(max(0, first - 10)..<min(200, last + 11))
        let oldRing = Set(max(0, first - 20)..<min(200, last + 21))
        print("502 rest sidebar: wanted \(pane.wantedRows().count) = old \(oldWanted.count); "
              + "ring \(pane.outerWantedRows().count) = old \(oldRing.count)")
        XCTAssertEqual(pane.wantedRows(), oldWanted)
        XCTAssertEqual(pane.outerWantedRows(), oldRing)
    }

    func testRestingFilmstripBandIsTheOldArithmetic() throws {
        let session = try makeSession(rowCount: 200)
        let strip = try makeFilmstrip(session)
        strip.reconcileThumbnailsForTesting()

        let scroll = try XCTUnwrap(strip.view as? NSScrollView)
        let bounds = scroll.contentView.bounds
        let unit = max(24, strip.appliedItemSize.width)
        let oldWanted = stripIndexes(strip, in: bounds.insetBy(dx: -unit * 10, dy: 0))
        let oldRing = stripIndexes(strip, in: bounds.insetBy(dx: -unit * 20, dy: 0))
        print("502 rest filmstrip: wanted \(strip.wantedIndexes().count) = old \(oldWanted.count); "
              + "ring \(strip.outerWantedIndexes().count) = old \(oldRing.count)")
        XCTAssertEqual(strip.wantedIndexes(), oldWanted)
        XCTAssertEqual(strip.outerWantedIndexes(), oldRing)
    }

    // MARK: - §3.4 the ring is at least the forward band

    func testCancellationRingKeepsAThirtyRowForwardAsk() throws {
        let session = try makeSession(rowCount: 200)
        let pane = try makeSidebar(session)

        // Drive the band to its cap: 20 rows/s ⇒ forward 30, ring 40.
        let step = 2 * WorkspaceLayout.browserRowHeight
        scrollSidebar(pane, toRow: 40)
        pane.cancelScheduledThumbnailReconcileForTesting()
        pane.primeVelocityForTesting(offsetDelta: step, seconds: 0.1, previousRowsPerSecond: 20)
        pane.reconcileThumbnailsForTesting()

        let visible = pane.visibleRows()
        let first = try XCTUnwrap(visible.min())
        let last = try XCTUnwrap(visible.max())
        let wanted = pane.wantedRows()
        let ring = pane.outerWantedRows()
        let deepest = last + 30
        print("502 ring: visible \(first)…\(last); band \(wanted.min() ?? -1)…"
              + "\(wanted.max() ?? -1); ring \(ring.min() ?? -1)…\(ring.max() ?? -1)")

        // Group 1 — the band is inside the ring, so nothing this pass issued can be condemned by the
        // same pass (that is what a fixed 20-row ring does to rows 21…30).
        XCTAssertEqual(pane.deferredCoreRowsForTesting, [], "a 30-row band fits the default budget")
        XCTAssertTrue(wanted.isSubset(of: ring))
        XCTAssertTrue(ring.contains(last + 25))
        XCTAssertTrue(ring.contains(last + 35))
        XCTAssertEqual(ring.max(), last + 40)
        XCTAssertEqual(ring.min(), max(0, first - 20))

        // Group 2 — 25 rows of scrolling later the previous pass's deepest forward ask is still
        // inside the ring (nobody cancelled it on the way); 41 rows ahead of the visible edge is
        // outside, so that is where a request is condemned.
        pane.cancelScheduledThumbnailReconcileForTesting()
        scrollSidebar(pane, toRow: 65)
        pane.primeVelocityForTesting(offsetDelta: step, seconds: 0.1, previousRowsPerSecond: 20)
        pane.reconcileThumbnailsForTesting()
        let ringAfter = pane.outerWantedRows()
        print("502 ring: after 25 rows the previous deepest row \(deepest) is inside = "
              + "\(ringAfter.contains(deepest)); ring now \(ringAfter.min() ?? -1)…"
              + "\(ringAfter.max() ?? -1)")
        XCTAssertTrue(ringAfter.contains(deepest),
                      "25 rows later the ask is still inside the ring")
        XCTAssertFalse(ringAfter.contains(ringAfter.max()! + 1))
    }

    // MARK: - §3.5 the budget

    func testCoreBudgetDefersThenDrainsInTwoPasses() throws {
        let session = try makeSession(rowCount: 60 * 6)
        let grid = try makeGrid(session)
        let columns = grid.metrics.columns
        let pitch = grid.metrics.rowHeight

        // A 30-row forward band over a 10-row resting band is 20 rows × 6 columns = 120 extension
        // asks; a budget of 60 is exactly half, so two passes must finish it.
        grid.coreBudgetPerPass = 60
        scrollGrid(grid, toRow: 10)
        grid.cancelScheduledThumbnailReconcileForTesting()
        grid.primeVelocityForTesting(offsetDelta: 2 * pitch, seconds: 0.1,
                                     previousRowsPerSecond: 20)
        grid.reconcileThumbnailsForTesting()

        let core = grid.coreWantedIndexes()
        let extensionCells = core.subtracting(grid.restingWantedIndexes())
        let deferredAfterFirst = grid.deferredCoreIndexesForTesting
        print("502 budget: band \(core.count) cells, extension \(extensionCells.count); "
              + "pass 1 issued \(extensionCells.count - deferredAfterFirst.count) extension asks, "
              + "deferred \(deferredAfterFirst.count) (budget 60)")
        XCTAssertEqual(extensionCells.count, 20 * columns, "30 rows of band minus the 10 resting")
        XCTAssertEqual(deferredAfterFirst.count, extensionCells.count - 60,
                       "the first pass stops exactly at the budget")
        XCTAssertTrue(deferredAfterFirst.isSubset(of: extensionCells))
        XCTAssertTrue(extensionCells.subtracting(deferredAfterFirst)
                        .isSubset(of: grid.prefetchRequestedIndexes),
                      "everything not deferred was actually asked for")

        // The continuation lands mid-flick (two rows further on), not after a standstill: the
        // carried rows are still inside the ring, so they go first and are drained.
        scrollGrid(grid, toRow: 12)
        grid.cancelScheduledThumbnailReconcileForTesting()
        grid.primeVelocityForTesting(offsetDelta: 2 * pitch, seconds: 0.1,
                                     previousRowsPerSecond: 20)
        grid.reconcileThumbnailsForTesting()

        let deferredAfterSecond = grid.deferredCoreIndexesForTesting
        let missing = extensionCells.subtracting(grid.prefetchRequestedIndexes)
        print("502 budget: pass 2 deferred \(deferredAfterSecond.count) "
              + "(the rows that entered past the cap), carried rows drained = "
              + "\(deferredAfterSecond.isDisjoint(with: deferredAfterFirst)); "
              + "extension covered = \(missing.isEmpty)")
        XCTAssertTrue(deferredAfterSecond.isDisjoint(with: deferredAfterFirst),
                      "the rows pass 1 deferred were issued by pass 2, not deferred again")
        XCTAssertLessThanOrEqual(deferredAfterSecond.count, 3 * columns,
                                 "only the rows that entered past the cap remain")
        XCTAssertTrue(extensionCells.isSubset(of: grid.prefetchRequestedIndexes),
                      "two passes = the whole band — nothing was silently dropped")
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

    private func makeSession(rowCount: Int) throws -> CatalogSession {
        let pool = Self.readableSamples()
        guard !pool.isEmpty else { throw XCTSkip("no readable DNGs; set PHOTONS_TEST_RAW") }
        let package = tmp.appendingPathComponent("b502-\(rowCount).photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: package)
        let source = tmp.appendingPathComponent("src-\(rowCount)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)
        for index in 0..<rowCount {
            let link = source.appendingPathComponent("shot\(index).dng")
            try FileManager.default.createSymbolicLink(at: link,
                                                       withDestinationURL: pool[index % pool.count])
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, imported_at, missing)
                    VALUES (?, ?, ?, ?, 'dng', 'raw', 4096, 0, ?, 9520, 6336,
                            '2026-11-22T00:00:00Z', 0)
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

    private func settle(_ turns: Int = 4) {
        for _ in 0..<turns { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func makeGrid(_ session: CatalogSession) throws -> AssetGridController {
        let size = NSSize(width: 992, height: 700)  // GridLayout: exactly six columns
        let window = makeWindow(size)
        let grid = AssetGridController(session: session)
        _ = grid.view
        // Decodes are not what this suite measures; refuse them so the band reading is stable.
        grid.thumbnailProviderForSmoke?.service.isPaused = true
        grid.view.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(grid.view)
        window.contentView?.layoutSubtreeIfNeeded()
        settle(6)
        grid.view.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        XCTAssertEqual(grid.metrics.columns, 6)
        return grid
    }

    private func makeSidebar(_ session: CatalogSession) throws -> BrowserPaneController {
        let size = NSSize(width: 280, height: 780)
        let window = makeWindow(size)
        let pane = BrowserPaneController(session: session)
        _ = pane.view
        pane.thumbnailProviderForSmoke?.service.isPaused = true
        pane.view.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(pane.view)
        window.contentView?.layoutSubtreeIfNeeded()
        settle(6)
        pane.view.layoutSubtreeIfNeeded()
        return pane
    }

    private func makeFilmstrip(_ session: CatalogSession) throws -> FilmstripController {
        let size = NSSize(width: 520, height: WorkspaceLayout.filmstripHeight)
        let window = makeWindow(size)
        let strip = FilmstripController(session: session)
        _ = strip.view
        strip.thumbnailProviderForSmoke?.service.isPaused = true
        strip.view.frame = NSRect(origin: .zero, size: size)
        window.contentView?.addSubview(strip.view)
        window.contentView?.layoutSubtreeIfNeeded()
        settle(6)
        strip.view.layoutSubtreeIfNeeded()
        strip.collectionView.layoutSubtreeIfNeeded()
        return strip
    }

    private func scrollGrid(_ grid: AssetGridController, toRow row: Int) {
        let scroll = grid.scrollView
        let content = grid.collectionView.collectionViewLayout?.collectionViewContentSize.height ?? 0
        let maxOffset = max(0, content - scroll.contentView.bounds.height)
        let y = min(maxOffset, CGFloat(row) * grid.metrics.rowHeight)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        grid.collectionView.layoutSubtreeIfNeeded()
    }

    private func scrollSidebar(_ pane: BrowserPaneController, toRow row: Int) {
        let table = pane.photoListForTesting
        guard let scroll = table.enclosingScrollView else { return XCTFail("no scroll view") }
        let maxOffset = max(0, table.bounds.height - scroll.contentView.bounds.height)
        let y = min(maxOffset, CGFloat(row) * WorkspaceLayout.browserRowHeight)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func scrollFilmstrip(_ strip: FilmstripController, toOffset x: CGFloat) {
        guard let scroll = strip.view as? NSScrollView else { return XCTFail("no scroll view") }
        let content = strip.collectionView.collectionViewLayout?.collectionViewContentSize.width ?? 0
        let maxOffset = max(0, content - scroll.contentView.bounds.width)
        scroll.contentView.scroll(to: NSPoint(x: min(maxOffset, x), y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        strip.collectionView.layoutSubtreeIfNeeded()
    }

    private func indexes(_ grid: AssetGridController, in rect: CGRect) -> Set<Int> {
        let attributes = grid.collectionView.collectionViewLayout?
            .layoutAttributesForElements(in: rect) ?? []
        return Set(attributes.compactMap { $0.indexPath?.item })
    }

    private func stripIndexes(_ strip: FilmstripController, in rect: CGRect) -> Set<Int> {
        let attributes = strip.collectionView.collectionViewLayout?
            .layoutAttributesForElements(in: rect) ?? []
        return Set(attributes.compactMap { $0.indexPath?.item })
    }
}
