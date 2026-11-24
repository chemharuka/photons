import XCTest
import Foundation
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// 538 — the catalog's reads all go through read-only pool connections, and can run in parallel.
///
/// The single thing this suite exists to prove is the connection *shape*: with `DatabaseQueue` a
/// read waits behind any write holding the one connection; with `DatabasePool` it borrows a
/// read-only reader and finishes while the write is still asleep. The 300 ms write below is the
/// seam: the reads must not pay it.
///
/// Timing cases are skipped unless the machine is quiet (`load average < 8`), as the ticket
/// requires; a red test on a loaded machine would be a lie about the connection, not the code.
final class CatalogParallelReads538Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-538-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - fixtures

    private func packageURL(_ name: String = "L") -> URL {
        workDir.appendingPathComponent("\(name).\(LibraryLayout.packageExtension)")
    }

    private func newLibrary(_ name: String = "L") throws -> Catalog {
        try Catalog.create(at: packageURL(name))
    }

    /// A row with no file behind it, plus an immutable-ish edit stack. Its two reads (the asset's
    /// cursor/document and `asset_history`) are exactly what `editHistory` issues.
    @discardableResult
    private func insertAsset(_ catalog: Catalog, name: String, historyRows: Int = 20) throws -> String {
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)
        var document = EditModel.neutral
        document.light.exposure = 0.25
        let live = try Catalog.encode(document)
        let id = UUID().uuidString
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, develop_json, develop_version, history_end, imported_at)
                VALUES (?, ?, ?, ?, 'dng', 'raw', 1024, 0, ?, ?, 1, ?, '2026-11-23T00:00:00Z')
                """, arguments: [id, root.id, name, name, UUID().uuidString, live, historyRows])
            for seq in 1 ... max(1, historyRows) {
                var earlier = document
                earlier.light.contrast = Double(seq)
                let json = try Catalog.encode(earlier)
                try db.execute(sql: """
                    INSERT INTO asset_history(asset_id, seq, develop_json, label, created_at)
                    VALUES(?, ?, ?, ?, '2026-11-23T00:00:00Z')
                    """, arguments: [id, seq, json, seq == historyRows ? "" : "edit \(seq)"])
            }
        }
        return id
    }

    // MARK: - 1. the connection shape (this ticket's main criterion)

    /// A `DatabaseQueue` and the catalog's `DatabasePool` do the same two reads for four assets,
    /// while a write transaction holds the connection for 300 ms. The queue's four reads all wait
    /// for that transaction (sum ≈ 4 × 300 ms); the pool's four run inside it (sum ≈ 4 × read).
    ///
    /// `serial_total_ms` is the sum of the four queue read latencies — the number the ticket's
    /// `4 × (300 + read)` describes. If `Catalog.dbQueue` ever goes back to `DatabaseQueue`, the
    /// pool side turns into the queue side and `parallel_total_ms < serial_total_ms / 3` goes red.
    func testHistoryReadsRunConcurrentlyWhileAWriteHoldsTheConnection() throws {
        try requireQuietMachine()
        let catalog = try newLibrary()
        var serialIDs: [String] = []
        var parallelIDs: [String] = []
        for index in 0 ..< 4 { serialIDs.append(try insertAsset(catalog, name: "s\(index).dng")) }
        for index in 0 ..< 4 { parallelIDs.append(try insertAsset(catalog, name: "p\(index).dng")) }

        // Open one reader connection before the clock starts; opening it is not what is measured.
        _ = try catalog.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT 1") }

        let serialQueue = try DatabaseQueue(path: catalog.layout.databaseURL.path,
                                           configuration: Catalog.configuration())
        defer { try? serialQueue.close() }
        let serial = try Self.measureReads(reader: serialQueue, writer: serialQueue, ids: serialIDs)
        let parallel = try Self.measureReads(reader: catalog.dbQueue, writer: catalog.dbQueue, ids: parallelIDs)

        // The real API, not the helper: an `editHistory` issued while the writer sleeps must return
        // well before the writer lets go.
        let real = try measureRealEditHistory(catalog: catalog, id: parallelIDs[0])

        print(String(format: """
            538 concurrency: serial_total_ms %.2f (reads %@) · parallel_total_ms %.2f (reads %@) \
            · serial_wall_ms %.2f · parallel_wall_ms %.2f · real_editHistory_ms %.2f
            """,
            serial.total, Self.format(serial.latencies),
            parallel.total, Self.format(parallel.latencies),
            serial.wall, parallel.wall, real))

        XCTAssertGreaterThanOrEqual(serial.minimum, 250,
                                    "the queue baseline itself must have waited for the 300 ms write")
        XCTAssertLessThanOrEqual(parallel.maximum, 150,
                                 "pool reads must not queue behind the writer; got \(parallel.latencies)")
        XCTAssertLessThan(parallel.total, serial.total / 3,
                          "parallel_total_ms \(parallel.total) must be far below serial_total_ms \(serial.total)")
        XCTAssertLessThan(real, 150, "editHistory itself must not wait for the writer")
    }

    // MARK: - 2. the 530 numbers, re-measured on the real library

    /// Ten consecutive `editHistory` reads from a copy of a real library — the same ten largest
    /// frames the 530 suite measured — p50/p95 and the target the ticket sets. Skipped unless
    /// `PHOTONS_538_LIBRARY` names one.
    func testRealLibraryTenHistoryReadsReportP50P95() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_538_LIBRARY"],
              FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no real library; set PHOTONS_538_LIBRARY")
        }
        try requireQuietMachine()
        let copy = workDir.appendingPathComponent("Real.photonslibrary", isDirectory: true)
        try FileManager.default.copyItem(atPath: path, toPath: copy.path)
        let catalog = try Catalog.open(at: copy)
        defer { try? catalog.dbQueue.close() }

        // The same ten switches the 530 suite measured: the largest frames first, so the numbers
        // are a direct before/after rather than a different photo set.
        let ids = try catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT id FROM assets
                ORDER BY (COALESCE(width, 0) * COALESCE(height, 0)) DESC, id
                LIMIT 10
                """)
        }
        XCTAssertEqual(ids.count, 10, "the library must have at least ten edited photos")
        _ = try catalog.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT 1") }

        var samples: [Double] = []
        var totalRows = 0
        for id in ids {
            totalRows += try catalog.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_history WHERE asset_id = ?",
                                 arguments: [id]) ?? 0
            }
            let started = DispatchTime.now()
            _ = try catalog.editHistory(forAsset: id)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6)
        }
        let p50 = Self.percentile(samples, 0.5)
        let p95 = Self.percentile(samples, 0.95)
        print(String(format: "538 real library: 10 switches, %d history rows, editHistory p50 %.2f ms p95 %.2f ms",
                     totalRows, p50, p95))
        XCTAssertLessThanOrEqual(p95, 50, "ticket target is p95 ≤ 50 ms; got p50 \(p50), p95 \(p95)")
    }

    // MARK: - 3. reads do not slow writes

    /// 50 `saveDevelop` writes with no readers, then 50 with four reader threads reading the
    /// catalog throughout. The writer is still the one serial connection; if pool reads stole its
    /// lock (or forced it to checkpoint) the median would move.
    ///
    /// The write assets carry a deep 200-row stack, so a `saveDevelop` is a substantive write
    /// (~16 ms here) instead of sub-millisecond timer noise. The read asset is deliberately a
    /// cheap 1-row history: this case is about DB/connection interference, not about four cores
    /// of JSON decoding competing with the writer.
    func testWritesAreNotSlowedByConcurrentReads() throws {
        try requireQuietMachine()
        let catalog = try newLibrary("W")
        let baselineID = try insertAsset(catalog, name: "base.dng", historyRows: 200)
        let concurrentID = try insertAsset(catalog, name: "conc.dng", historyRows: 200)
        let readID = try insertAsset(catalog, name: "read.dng", historyRows: 1)
        _ = try catalog.editHistory(forAsset: readID)

        let baseline = try saveDevelopSamples(catalog: catalog, assetID: baselineID, count: 50)

        let stop = LockedBox(false)
        let readers = DispatchGroup()
        let pool = catalog.dbQueue
        for _ in 0 ..< 4 {
            readers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readers.leave() }
                while !stop.value {
                    _ = try? Self.historyRead(pool, readID)
                    // A UI history read is one per selection, not a busy loop. A short pause keeps
                    // four readers active throughout the 50 writes without pinning four cores.
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        }
        let withReads = try saveDevelopSamples(catalog: catalog, assetID: concurrentID, count: 50)
        stop.set(true)
        readers.wait()

        // Same library, same WAL growth, no readers: distinguishes "the writer got slower as the
        // file grew" from "the readers interfered".
        let afterID = try insertAsset(catalog, name: "after.dng", historyRows: 200)
        let baselineAfter = try saveDevelopSamples(catalog: catalog, assetID: afterID, count: 50)

        let baseP50 = Self.percentile(baseline, 0.5)
        let readsP50 = Self.percentile(withReads, 0.5)
        let afterP50 = Self.percentile(baselineAfter, 0.5)
        let reference = max(baseP50, afterP50)
        print(String(format: """
            538 writes: saveDevelop p50 no-readers %.3f ms · with 4 reader threads %.3f ms \
            (ratio %.2fx) · no-readers again %.3f ms (n=50)
            """, baseP50, readsP50, readsP50 / max(reference, 0.0001), afterP50))

        XCTAssertLessThanOrEqual(readsP50, reference * 1.2,
                                 "four concurrent readers must not move the writer's p50 by more than 20%")
    }

    // MARK: - 4. correctness: a committed write is visible to the very next read

    /// A pool swaps the read snapshot; that must not become "the previous commit". The write call
    /// returns after its transaction commits, so the next `read` has to see the row it just wrote.
    func testWriteIsVisibleToTheImmediateNextRead() throws {
        let catalog = try newLibrary("V")
        let id = try insertAsset(catalog, name: "visible.dng", historyRows: 1)

        var document = EditModel.neutral
        document.light.exposure = 1.25
        let saved = try catalog.appendDevelop(document, label: "538", forAsset: id)
        XCTAssertTrue(saved.changed)

        XCTAssertEqual(try catalog.develop(forAsset: id).light.exposure, 1.25,
                       "the next read sees the committed document")
        let state = try catalog.developState(forAsset: id)
        XCTAssertEqual(state.historyEnd, saved.historySeq)

        let history = try catalog.editHistory(forAsset: id)
        XCTAssertEqual(history.current?.light.exposure, 1.25,
                       "the next read sees the committed history row and cursor")
        XCTAssertEqual(try catalog.historyRows(forAsset: id).last?.edit.light.exposure, 1.25)

        // Same visibility through a second handle, which is what a reopen in another window does.
        let reopened = try Catalog.open(at: catalog.layout.packageURL)
        XCTAssertEqual(try reopened.develop(forAsset: id).light.exposure, 1.25)
    }

    // MARK: - 5. every connection (reader included) gets the WAL configuration

    /// `prepareDatabase` runs per connection. Readers are read-only, and they still report the WAL /
    /// NORMAL / foreign_keys / busy_timeout settings the queue had.
    func testReaderConnectionsAreReadOnlyAndKeepTheConfiguration() throws {
        let catalog = try newLibrary("C")
        _ = try insertAsset(catalog, name: "a.dng")

        let reader = try catalog.dbQueue.read { db in
            try Self.pragmas(db)
        }
        let writer = try catalog.dbQueue.write { db in
            try Self.pragmas(db)
        }

        print("538 pragmas: reader \(reader) · writer \(writer)")
        XCTAssertTrue(reader.readonly, "pool readers must be read-only")
        XCTAssertFalse(writer.readonly)
        for side in [reader, writer] {
            XCTAssertEqual(side.journalMode, "wal")
            XCTAssertEqual(side.synchronous, 1, "NORMAL")
            XCTAssertEqual(side.foreignKeys, 1)
            XCTAssertEqual(side.busyTimeout, 5000)
        }
    }

    // MARK: - measurement helpers

    private struct ReadRun {
        let latencies: [Double]
        let wall: Double
        var total: Double { latencies.reduce(0, +) }
        var minimum: Double { latencies.min() ?? 0 }
        var maximum: Double { latencies.max() ?? 0 }
    }

    /// Start a write that holds the connection for `holdMilliseconds`, then issue one read per id
    /// concurrently and time each. The reader/writer split is the whole experiment: pass the same
    /// `DatabaseQueue` for the baseline, the catalog's `DatabasePool` for the fix.
    private static func measureReads(reader: any DatabaseReader, writer: any DatabaseWriter,
                                     ids: [String], holdMilliseconds: Double = 300) throws -> ReadRun {
        let started = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let latencies = LockedBox<[Double]>([])

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                try writer.write { db in
                    // Touch a row so the transaction owns the write lock before the signal.
                    try db.execute(sql: "UPDATE settings SET value = value WHERE key = 'schema_version'")
                    started.signal()
                    Thread.sleep(forTimeInterval: holdMilliseconds / 1000)
                }
            } catch {
                started.signal()
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success,
                       "the write never started")

        let wallStart = DispatchTime.now()
        for id in ids {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let t0 = DispatchTime.now()
                _ = try? historyRead(reader, id)
                latencies.mutate {
                    $0.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
                }
            }
        }
        group.wait()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - wallStart.uptimeNanoseconds) / 1e6
        return ReadRun(latencies: latencies.value, wall: wall)
    }

    /// The two reads `editHistory(forAsset:)` performs, decoded the same way, against any reader.
    /// It deliberately does not touch the 537 snapshot cache so both sides of the A/B pay it.
    private static func historyRead(_ reader: any DatabaseReader, _ id: String) throws {
        let state = try reader.read { db -> (historyEnd: Int, json: String) in
            let row = try Row.fetchOne(db, sql: """
                SELECT develop_json, history_end FROM assets WHERE id = ?
                """, arguments: [id])
            return (row?["history_end"] ?? 0, row?["develop_json"] ?? "{}")
        }
        let decoder = JSONDecoder()
        _ = try? decoder.decode(EditModel.self, from: Data(state.json.utf8))
        let rows = try reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT seq, label, develop_json, created_at
                FROM asset_history WHERE asset_id = ? ORDER BY seq
                """, arguments: [id])
        }
        for row in rows {
            let json: String = row["develop_json"]
            _ = try? decoder.decode(EditModel.self, from: Data(json.utf8))
        }
    }

    /// `editHistory` on the real API, issued while a 300 ms write holds the writer.
    private func measureRealEditHistory(catalog: Catalog, id: String) throws -> Double {
        let started = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let pool = catalog.dbQueue
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            do {
                try pool.write { db in
                    try db.execute(sql: "UPDATE settings SET value = value WHERE key = 'schema_version'")
                    started.signal()
                    Thread.sleep(forTimeInterval: 0.3)
                }
            } catch {
                started.signal()
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        let t0 = DispatchTime.now()
        _ = try catalog.editHistory(forAsset: id)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
        group.wait()
        return elapsed
    }

    private func saveDevelopSamples(catalog: Catalog, assetID: String, count: Int) throws -> [Double] {
        var samples: [Double] = []
        samples.reserveCapacity(count)
        for index in 0 ..< count {
            var history = try catalog.editHistory(forAsset: assetID)
            guard var document = history.current else {
                XCTFail("no current document for \(assetID)")
                return samples
            }
            document.light.exposure = 0.1 + Double(index) * 0.01
            history.commit(document, label: "w\(index)", now: Date())
            let t0 = DispatchTime.now()
            _ = try catalog.saveDevelop(document, history: history, forAsset: assetID)
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6)
        }
        return samples
    }

    private struct PragmaSnapshot: CustomStringConvertible {
        let readonly: Bool
        let journalMode: String
        let synchronous: Int
        let foreignKeys: Int
        let busyTimeout: Int
        var description: String {
            "readonly=\(readonly) journal_mode=\(journalMode) synchronous=\(synchronous) "
                + "foreign_keys=\(foreignKeys) busy_timeout=\(busyTimeout)"
        }
    }

    private static func pragmas(_ db: Database) throws -> PragmaSnapshot {
        PragmaSnapshot(
            readonly: db.configuration.readonly,
            journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
            synchronous: try Int.fetchOne(db, sql: "PRAGMA synchronous") ?? -1,
            foreignKeys: try Int.fetchOne(db, sql: "PRAGMA foreign_keys") ?? -1,
            busyTimeout: try Int.fetchOne(db, sql: "PRAGMA busy_timeout") ?? -1)
    }

    // MARK: - load gate and small utilities

    /// The ticket records timing only on a quiet machine; a parallel build next door is not a
    /// result about this connection.
    private func requireQuietMachine() throws {
        let load = Self.loadAverage
        guard load < 8 else {
            throw XCTSkip(String(format: "load average %.2f ≥ 8; timing numbers not recorded", load))
        }
    }

    private static var loadAverage: Double {
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return loads[0]
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
        return sorted[index]
    }

    private static func format(_ values: [Double]) -> String {
        "[" + values.map { String(format: "%.2f", $0) }.joined(separator: ", ") + "]"
    }
}

/// A tiny mutable box for values shared with `DispatchQueue` closures under Swift 6's checks.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func set(_ value: Value) {
        lock.lock(); defer { lock.unlock() }
        storage = value
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}
