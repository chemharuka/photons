import XCTest
import Foundation
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 537 — 「切图后立刻提交」 must not block on the whole history read.
///
/// 530 moved the history read off the selection path, but a commit/undo right after a switch still
/// waited for it *without a limit* — and that read decodes every snapshot (393-row history: p50
/// 270 ms / p95 883 ms). This suite pins both halves of 537:
///
///   1. the read a write waits for is the newest **window** (`Catalog.editHistoryWindow`), not the
///      whole stack; the full stack is materialised when the history panel opens;
///   2. whatever goes wrong, the wait is capped at 1.2 s, and a timed-out write is **refused**
///      rather than committed onto the one-row floor (which would truncate `asset_history`).
///
/// Timing assertions are only enforced when the machine's load average is below 8 (the ticket's
/// rule); above that the numbers are printed for the report and the functional assertions still run.
@MainActor
final class EditHistoryFlushBound537Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-flush-537-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - ① the expensive read that a write no longer waits for

    /// The ticket's p95 ≤ 5 ms target, measured directly on the read a commit uses. This is the
    /// half of the fix that makes the 1.2 s cap a hang guard instead of the normal path.
    func testMinimalWindowReadStaysCheap() throws {
        let limit = CatalogSession.pendingEditHistoryWindow
        let catalog: Catalog
        let assetID: String
        let label: String
        if let path = ProcessInfo.processInfo.environment["PHOTONS_537_LIBRARY"],
           FileManager.default.fileExists(atPath: path) {
            let copy = workDir.appendingPathComponent("Real.photonslibrary", isDirectory: true)
            try FileManager.default.copyItem(atPath: path, toPath: copy.path)
            catalog = try Catalog.open(at: copy)
            let longest = try catalog.dbQueue.read { db in
                try String.fetchOne(db, sql: """
                    SELECT asset_id FROM asset_history GROUP BY asset_id
                    ORDER BY COUNT(*) DESC LIMIT 1
                    """)
            }
            assetID = try XCTUnwrap(longest)
            label = "real"
        } else {
            let fixture = try makeFixture(targetRows: 393)
            catalog = try Catalog.open(at: fixture.package)
            assetID = fixture.targetID
            label = "synthetic"
        }

        // Warm the SQLite page cache once, exactly as a second visit would find it.
        let coldStarted = CFAbsoluteTimeGetCurrent()
        _ = try? catalog.editHistoryWindow(forAsset: assetID, limit: limit)
        let cold = (CFAbsoluteTimeGetCurrent() - coldStarted) * 1000

        var samples: [Double] = []
        for _ in 0 ..< 50 {
            let started = CFAbsoluteTimeGetCurrent()
            _ = try catalog.editHistoryWindow(forAsset: assetID, limit: limit)
            samples.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }
        let p = percentiles(samples)
        print(String(format: "537 minimal window [%@, %d rows, cold %.2f ms]: p50 %.2f ms p95 %.2f ms p99 %.2f ms",
                     label, try totalRows(catalog, assetID), cold, p.p50, p.p95, p.p99))
        if timingEnforced {
            XCTAssertLessThanOrEqual(p.p95, 5.0, "the window read is the commit path; p95 must stay ≤ 5 ms")
            XCTAssertLessThanOrEqual(p.p99, 50.0, "p99 includes scheduling noise but must stay ≤ 50 ms")
        }
    }

    /// The old read (`editHistory(forAsset:)` before 537, which decoded every snapshot) on the same
    /// library. Opt-in so a normal test run does not pay for it; the report uses it for the
    /// before/after table. Uses the uncached door on purpose: this row is the *old* cost.
    func testFullStackReadBaselineIsTheOldCost() throws {
        guard ProcessInfo.processInfo.environment["PHOTONS_537_BASELINE"] == "1" else {
            throw XCTSkip("set PHOTONS_537_BASELINE=1 to measure the pre-537 full read")
        }
        let catalog: Catalog
        let assetID: String
        let label: String
        if let path = ProcessInfo.processInfo.environment["PHOTONS_537_LIBRARY"],
           FileManager.default.fileExists(atPath: path) {
            let copy = workDir.appendingPathComponent("Baseline.photonslibrary", isDirectory: true)
            try FileManager.default.copyItem(atPath: path, toPath: copy.path)
            catalog = try Catalog.open(at: copy)
            let longest = try catalog.dbQueue.read { db in
                try String.fetchOne(db, sql: """
                    SELECT asset_id FROM asset_history GROUP BY asset_id
                    ORDER BY COUNT(*) DESC LIMIT 1
                    """)
            }
            assetID = try XCTUnwrap(longest)
            label = "real"
        } else {
            let fixture = try makeFixture(targetRows: 393)
            catalog = try Catalog.open(at: fixture.package)
            assetID = fixture.targetID
            label = "synthetic"
        }
        _ = try? catalog.editHistoryUncached(forAsset: assetID)
        var samples: [Double] = []
        for _ in 0 ..< 30 {
            let started = CFAbsoluteTimeGetCurrent()
            _ = try catalog.editHistoryUncached(forAsset: assetID)
            samples.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        }
        let p = percentiles(samples)
        print(String(format: "537 baseline full read [%@, %d rows]: p50 %.2f ms p95 %.2f ms p99 %.2f ms",
                     label, try totalRows(catalog, assetID), p.p50, p.p95, p.p99))
    }

    // MARK: - ② the measured promise: 50 switch → commit cycles wait for the window only

    func testSwitchThenCommitWaitsOnlyForTheWindow() throws {
        let fixture = try makeFixture(targetRows: 393)
        let session = try open(fixture)
        // The open landed somewhere; make the first switch explicit.
        session.selectOnly(fixture.otherID)

        var waits: [Double] = []
        for index in 0 ..< 50 {
            session.selectOnly(fixture.otherID)
            session.selectOnly(fixture.targetID)
            session.applyEdit { $0.light.exposure += 0.001 }
            let started = CFAbsoluteTimeGetCurrent()
            let committed = session.commitEdit(label: "bench \(index)", coalesce: false)
            XCTAssertTrue(committed, "cycle \(index) committed")
            XCTAssertTrue(session.lastPersistError == nil || session.lastPersistError?.contains("历史仍在加载") == true)
            waits.append(session.lastPendingEditHistoryWaitMilliseconds)
            // Do not let the 50 cycles pile up behind a broken read.
            XCTAssertLessThan((CFAbsoluteTimeGetCurrent() - started) * 1000, 1_200,
                              "cycle \(index) blocked on the history read")
        }
        let p = percentiles(waits)
        print(String(format: "537 switch→commit [synthetic, 393 rows, load %.2f]: p50 %.2f ms p95 %.2f ms p99 %.2f ms · cap hits %d/%d",
                     loadAverage, p.p50, p.p95, p.p99,
                     session.pendingEditHistoryWaitTimeouts, session.pendingEditHistoryWaitCount))
        XCTAssertEqual(session.pendingEditHistoryWaitTimeouts, 0,
                       "the 1.2 s cap must never fire on the normal path")
        if timingEnforced {
            XCTAssertLessThanOrEqual(p.p95, 5.0, "the wait in front of a commit must be ≤ 5 ms p95")
            XCTAssertLessThanOrEqual(p.p99, 50.0, "p99 includes scheduling noise but must stay ≤ 50 ms")
        }
    }

    // MARK: - ③ the bound: a read slower than 1.2 s refuses the write, then succeeds

    func testBoundedWaitRefusesToWriteAndSucceedsAfterTheReadLands() throws {
        let fixture = try makeFixture(targetRows: 393)
        let session = try open(fixture)
        session.selectOnly(fixture.otherID)

        let reader = try Catalog.open(at: fixture.package)
        let rowsBefore = try totalRows(reader, fixture.targetID)
        let seqBefore = try maxSeq(reader, fixture.targetID)

        session.editHistoryLoadDelayForTesting = 3
        session.selectOnly(fixture.targetID)
        session.applyEdit { $0.light.exposure += 0.01 }
        let historyBefore = session.history.count
        let started = CFAbsoluteTimeGetCurrent()
        let committed = session.commitEdit(label: "too early", coalesce: false)
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertFalse(committed, "a timed-out flush must refuse the write")
        XCTAssertEqual(elapsed, 1.2, accuracy: 0.1, "commitEdit returns at the 1.2 s cap, not when the read lands")
        XCTAssertEqual(session.history.count, historyBefore, "no snapshot was appended to the floor")
        XCTAssertEqual(try totalRows(reader, fixture.targetID), rowsBefore, "no history row was written")
        XCTAssertEqual(try maxSeq(reader, fixture.targetID), seqBefore, "no seq was consumed")
        XCTAssertTrue(session.lastPersistError?.contains("历史仍在加载") == true,
                      "the refusal is visible on the existing error channel")
        XCTAssertEqual(session.pendingEditHistoryWaitTimeouts, 1)

        // The 3 s read lands; the next commit is a normal one and keeps every stored row.
        XCTAssertTrue(waitFor(6, { session.history.count > 1 }), "the delayed read never installed")
        session.editHistoryLoadDelayForTesting = 0
        XCTAssertFalse(session.historyWindowIsComplete, "393 rows are more than the newest window")
        session.applyEdit { $0.light.exposure += 0.01 }
        XCTAssertTrue(session.commitEdit(label: "after the load", coalesce: false))
        XCTAssertEqual(try totalRows(reader, fixture.targetID), rowsBefore + 1, "one row appended")
        XCTAssertEqual(try maxSeq(reader, fixture.targetID), seqBefore + 1)
        XCTAssertEqual(try minSeq(reader, fixture.targetID), 1, "the oldest row is still there")
    }

    // MARK: - ④ the positive judgement: an immediate commit does not truncate the stack

    func testImmediateCommitDoesNotTruncateA393RowStack() throws {
        let fixture = try makeFixture(targetRows: 393)
        let session = try open(fixture)
        session.selectOnly(fixture.otherID)
        session.selectOnly(fixture.targetID)
        session.applyEdit { $0.light.exposure += 0.02 }
        XCTAssertTrue(session.commitEdit(label: "no truncation", coalesce: false))

        let reader = try Catalog.open(at: fixture.package)
        let snapshots = try reader.historyRows(forAsset: fixture.targetID)
        XCTAssertGreaterThanOrEqual(snapshots.count, 394, "original 393 + the new row")
        XCTAssertEqual(snapshots.first?.seq, 1, "the original floor survived")
        XCTAssertEqual(Array(1 ... 393), Array(snapshots.map(\.seq).prefix(393)),
                       "the stored seqs are one unbroken run")
        XCTAssertEqual(snapshots.last?.seq, 394)
        let history = try reader.editHistory(forAsset: fixture.targetID)
        XCTAssertEqual(history.currentSeq, 394, "the cursor is on the newest row")
    }

    // MARK: - ⑤ the other half of §2.1: the panel, not the selection, pays for the full stack

    func testOpeningTheHistoryPanelMaterialisesTheFullStack() throws {
        let fixture = try makeFixture(targetRows: 393)
        let session = try open(fixture)
        session.selectOnly(fixture.otherID)
        session.selectOnly(fixture.targetID)
        XCTAssertTrue(waitFor(2, { (session.lastEditLoadTimeline?.historyEndedAt ?? 0) > 0 }))
        XCTAssertFalse(session.historyWindowIsComplete)
        XCTAssertEqual(session.history.count, CatalogSession.pendingEditHistoryWindow,
                       "the selection path decoded only the newest window")

        let rows = session.historyRows
        XCTAssertTrue(session.historyWindowIsComplete, "opening the panel reads the full stack")
        XCTAssertEqual(rows.count, EditHistory.defaultMaxDepth,
                       "the whole stack is materialised, then trimmed by the history's own depth")
        XCTAssertEqual(rows.last?.seq, 393)
    }

    // MARK: - fixture

    private struct Fixture {
        let package: URL
        let targetID: String
        let otherID: String
    }

    /// Two assets: the target carries `targetRows` stored snapshots (393 in the ticket), the other
    /// only two so switching away is cheap. The documents are panel-sized (~1.3 KB of JSON, close to
    /// the demo library's rows), not the two-field documents a synthetic benchmark could cheat with.
    private func makeFixture(targetRows: Int) throws -> Fixture {
        let package = workDir.appendingPathComponent("Flush.photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        func insertAsset(_ name: String, rows: Int) throws -> String {
            let id = UUID().uuidString
            try Data([0x00]).write(to: source.appendingPathComponent(name))
            let document = richDocument(seed: rows)
            let live = try Catalog.encode(document)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, develop_json, develop_version, history_end, missing)
                    VALUES (?, ?, ?, ?, 'dng', 'raw', 1, 0, ?, 6000, 4000,
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-23T00:00:00Z', ?, 1, ?, 0)
                    """, arguments: [id, root.id, name, name, UUID().uuidString, live, rows])
                for seq in 1 ... rows {
                    var earlier = document
                    earlier.light.exposure = document.light.exposure - Double(rows - seq) * 0.001
                    earlier.light.contrast = document.light.contrast - Double(rows - seq) * 0.01
                    let json = try Catalog.encode(earlier)
                    try db.execute(sql: """
                        INSERT INTO asset_history (asset_id, seq, develop_json, label, created_at)
                        VALUES (?, ?, ?, ?, '2026-11-23T00:00:00Z')
                        """, arguments: [id, seq, json, seq == rows ? "" : "edit \(seq)"])
                }
            }
            return id
        }

        let targetID = try insertAsset("target.dng", rows: targetRows)
        let otherID = try insertAsset("other.dng", rows: 2)
        return Fixture(package: package, targetID: targetID, otherID: otherID)
    }

    private func richDocument(seed: Int) -> EditModel {
        var d = EditModel.neutral
        d.light.exposure = 0.8 + Double(seed % 7) * 0.1
        d.light.contrast = 18
        d.light.highlights = -25
        d.light.shadows = 11
        d.light.temperature = 5600
        d.curve.white = [CurvePoint(0, 0), CurvePoint(1, 1.08), CurvePoint(2, 2)]
        d.color.vibrance = 20
        d.color.bands[2].hue = 12
        d.effects.vignetteAmount = -18
        d.effects.grain = 12
        d.sharpen.amount = 65
        d.geometry.crop = NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        d.geometry.rotationDegrees = 1.5
        return d
    }

    private func open(_ fixture: Fixture) throws -> CatalogSession {
        let session = CatalogSession(remembersRecentLibrary: false)
        try session.open(fixture.package)
        return session
    }

    // MARK: - readbacks / stats

    private var timingEnforced: Bool { loadAverage < 8 }

    private var loadAverage: Double {
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { return load[0] }
        return 0
    }

    private func percentiles(_ values: [Double]) -> (p50: Double, p95: Double, p99: Double) {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return (0, 0, 0) }
        func at(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
        }
        return (at(0.5), at(0.95), at(0.99))
    }

    private func totalRows(_ catalog: Catalog, _ id: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_history WHERE asset_id = ?",
                             arguments: [id]) ?? 0
        }
    }

    private func maxSeq(_ catalog: Catalog, _ id: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM asset_history WHERE asset_id = ?",
                             arguments: [id]) ?? 0
        }
    }

    private func minSeq(_ catalog: Catalog, _ id: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(MIN(seq), 0) FROM asset_history WHERE asset_id = ?",
                             arguments: [id]) ?? 0
        }
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }
}
