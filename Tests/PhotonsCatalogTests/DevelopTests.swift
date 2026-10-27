import XCTest
import Foundation
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// M2.5 / Q16: the develop document actually lands in the library.
///
/// Each test names the invariant it protects. The three that matter most:
/// a document survives a close/reopen, a damaged document is *never* lost (it is quarantined and the
/// asset reads neutral), and one save is one transaction (a failure halfway leaves nothing behind).
///
/// Filter with `--filter Develop`.
final class DevelopTests: XCTestCase {

    /// Millisecond ceilings are asserted only under `PHOTONS_BENCH=1` (project rule): `swift test`
    /// builds Debug, where a render/DB pass measures several times its Release number.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-develop-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    private func packageURL(_ name: String = "L") -> URL {
        workDir.appendingPathComponent("\(name).\(LibraryLayout.packageExtension)")
    }

    private func newLibrary(_ name: String = "L") throws -> Catalog {
        try Catalog.create(at: packageURL(name))
    }

    /// A document that differs from `.neutral` in one easily-checked place.
    private func edit(exposure: Double = 0, contrast: Double = 0) -> EditModel {
        var m = EditModel.neutral
        m.light.exposure = exposure
        m.light.contrast = contrast
        return m
    }

    /// Walk the whole document, not just one slider: the round-trip test is only worth something if
    /// every group survives encoding.
    private func richEdit() -> EditModel {
        var m = EditModel.neutral
        m.geometry.rotationDegrees = -3.25
        m.geometry.crop = NormalizedRect(x: 0.1, y: 0.05, width: 0.8, height: 0.7)
        m.light = LightGroup(exposure: 0.75, contrast: 12, highlights: -30, shadows: 18,
                             whites: 5, blacks: -8, temperature: 5400, tint: 7,
                             highlightRecovery: 0.25)
        m.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.5, v: 0.62), CurvePoint(u: 1, v: 1)]
        m.color.saturation = -12
        m.color.bands[3] = HSLBand(hue: 10, saturation: -20, luminance: 5)
        m.detail.sharpening = 40
        m.effects.vignetteAmount = -18
        return m
    }

    /// A row with no file behind it: these tests are about the document, not the pixels.
    @discardableResult
    private func insertAsset(_ catalog: Catalog, name: String = "a.dng",
                             developJson: String = "{}", withImportHistory: Bool = true) throws -> String {
        let rootDir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: rootDir, mode: .reference)
        let asset = Asset(sourceRootId: root.id,
                          relPath: name,
                          filename: (name as NSString).lastPathComponent,
                          ext: (name as NSString).pathExtension,
                          kind: .raw,
                          size: 1024,
                          mtime: 0,
                          contentHash: UUID().uuidString,
                          developJson: developJson)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            if withImportHistory {
                // Exactly what ImportService writes when a file lands.
                try AssetHistory(assetId: asset.id, seq: 1, developJson: developJson,
                                 label: "import", createdAt: ISO8601.now()).insert(db)
            }
        }
        return asset.id
    }

    private func storedBlob(_ catalog: Catalog, _ id: String) throws -> String {
        try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?", arguments: [id]) ?? ""
        }
    }

    private func storedVersion(_ catalog: Catalog, _ id: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT develop_version FROM assets WHERE id = ?", arguments: [id]) ?? -1
        }
    }

    private func rowCount(_ catalog: Catalog, _ id: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_history WHERE asset_id = ?",
                             arguments: [id]) ?? 0
        }
    }

    // MARK: - 1. round trip

    func testDevelopRoundTripSurvivesEveryGroup() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        let document = richEdit()

        _ = try catalog.appendDevelop(document, label: "Develop", forAsset: id)
        XCTAssertEqual(try catalog.develop(forAsset: id), document,
                       "every group must survive encode → store → decode")

        // And the same document through a *second* connection: nothing is only in memory.
        let reopened = try Catalog.open(at: packageURL())
        XCTAssertEqual(try reopened.develop(forAsset: id), document)
    }

    func testStoredBlobIsCanonicalAndByteStable() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        let document = richEdit()
        _ = try catalog.appendDevelop(document, forAsset: id)

        let blob = try storedBlob(catalog, id)
        XCTAssertEqual(blob, try Catalog.encode(document), "the blob is the canonical encoding")
        XCTAssertEqual(blob, try Catalog.encode(try catalog.develop(forAsset: id)),
                       "re-encoding what we read back must produce the same bytes — the thumbnail "
                       + "cache keys on this text")
        XCTAssertFalse(blob.contains("\n"), "no pretty printing: one row, one line")
        // sortedKeys: "color" must precede "curve" must precede "detail".
        let color = try XCTUnwrap(blob.range(of: "\"color\"")).lowerBound
        let curve = try XCTUnwrap(blob.range(of: "\"curve\"")).lowerBound
        let detail = try XCTUnwrap(blob.range(of: "\"detail\"")).lowerBound
        XCTAssertTrue(color < curve && curve < detail, "keys are sorted")
    }

    func testNeutralDefaultBlobStaysNeutral() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)   // develop_json = "{}", like a freshly imported row
        XCTAssertEqual(try catalog.develop(forAsset: id), .neutral)
        XCTAssertEqual(catalog.developDecodeFailures, 0, "{} is a valid document, not damage")
        XCTAssertEqual(try catalog.developQuarantineCount(), 0)
    }

    // MARK: - 2. history rows

    func testHistoryRowsMapOneToOneToSnapshots() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)          // seq 1 = "import"
        let a = edit(exposure: 0.5)
        let b = edit(exposure: 1.0)
        let c = edit(exposure: 1.0, contrast: 20)
        _ = try catalog.appendDevelop(a, label: "Exposure", forAsset: id)
        _ = try catalog.appendDevelop(b, label: "Exposure", forAsset: id)
        _ = try catalog.appendDevelop(c, label: "Contrast", forAsset: id)

        let rows = try catalog.historyRows(forAsset: id)
        XCTAssertEqual(rows.map(\.seq), [1, 2, 3, 4], "one row per state, seqs dense and monotone")
        XCTAssertEqual(rows.map(\.label), ["import", "Exposure", "Exposure", "Contrast"])
        XCTAssertEqual(rows.map(\.edit), [.neutral, a, b, c], "row N is snapshot N, edit and all")
        XCTAssertEqual(rows.count, try rowCount(catalog, id), "no phantom rows")
    }

    func testHistoryRebuildsWithItsCursor() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        let a = edit(exposure: 0.5)
        let b = edit(exposure: 1.5)
        _ = try catalog.appendDevelop(a, label: "Exposure", forAsset: id)
        let saved = try catalog.appendDevelop(b, label: "Exposure", forAsset: id)

        let history = try catalog.editHistory(forAsset: id)
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.currentSeq, saved.historySeq)
        XCTAssertEqual(history.current, b)
        XCTAssertTrue(history.canUndo, "reopening a document must not lose the undo stack")
        XCTAssertEqual(history.undoLabel, "Exposure")
    }

    // MARK: - 3. version bookkeeping

    func testDevelopVersionIncrementsOnEveryChangedSave() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        XCTAssertEqual(try storedVersion(catalog, id), 1, "v1 is the import default")

        var versions: [Int] = []
        for i in 1...4 {
            let saved = try catalog.appendDevelop(edit(exposure: Double(i) * 0.25), forAsset: id)
            versions.append(saved.developVersion)
            XCTAssertEqual(try storedVersion(catalog, id), saved.developVersion,
                           "the reported version is the stored version")
        }
        XCTAssertEqual(versions, [2, 3, 4, 5], "one bump per write, no gaps, no reuse")
    }

    func testIdenticalSaveDoesNotBumpVersionOrGrowHistory() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        let document = edit(exposure: 0.5)
        let first = try catalog.appendDevelop(document, forAsset: id)
        XCTAssertTrue(first.changed)

        let again = try catalog.appendDevelop(document, forAsset: id)
        XCTAssertFalse(again.changed, "same canonical bytes = nothing changed")
        XCTAssertEqual(again.developVersion, first.developVersion)
        XCTAssertEqual(again.historyRows, first.historyRows, "a no-op commit writes no row")
        XCTAssertEqual(try catalog.develop(forAsset: id), document)
    }

    func testEditTimeRecordsRealWritesOnly() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        XCTAssertNil(try catalog.developState(forAsset: id).editTime, "never written yet")

        let saved = try catalog.appendDevelop(edit(exposure: 0.5), forAsset: id)
        let stamp = try XCTUnwrap(saved.editTime)
        XCTAssertNotNil(ISO8601.date(from: stamp), "edit_time is ISO8601, same clock as imported_at")

        // A no-op save must not move the timestamp: "last edited" is a fact about the document.
        let again = try catalog.appendDevelop(edit(exposure: 0.5), forAsset: id)
        XCTAssertEqual(again.editTime, stamp)
    }

    // MARK: - 4. undo / truncation

    func testRedoBranchIsDroppedWhenACommitFollowsAnUndo() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        let a = edit(exposure: 0.5)
        let b = edit(exposure: 1.5)
        let c = edit(exposure: 2.5)
        _ = try catalog.appendDevelop(a, forAsset: id)
        _ = try catalog.appendDevelop(b, forAsset: id)

        // Undo back onto `a`, then commit `c`: darktable's `history_end` semantics — the future we
        // walked away from is not one we can return to.
        var history = try catalog.editHistory(forAsset: id)
        let target = try XCTUnwrap(history.snapshots.first { $0.edit == a }?.seq)
        XCTAssertNotNil(history.jump(to: target))
        XCTAssertTrue(history.commit(c, label: "Contrast") != nil)
        _ = try catalog.saveDevelop(c, history: history, forAsset: id)

        let rows = try catalog.historyRows(forAsset: id)
        XCTAssertEqual(rows.map(\.edit), [.neutral, a, c], "b is gone, not renumbered around")
        XCTAssertEqual(try catalog.develop(forAsset: id), c)
        let reopened = try catalog.editHistory(forAsset: id)
        XCTAssertFalse(reopened.canRedo, "the abandoned branch must not come back on reopen")
    }

    func testReopenKeepsTheCursorWhereItWasLeft() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        let a = edit(exposure: 0.5)
        let b = edit(exposure: 1.5)
        _ = try catalog.appendDevelop(a, forAsset: id)
        _ = try catalog.appendDevelop(b, forAsset: id)

        var history = try catalog.editHistory(forAsset: id)
        let seqA = try XCTUnwrap(history.snapshots.first { $0.edit == a }?.seq)
        XCTAssertNotNil(history.jump(to: seqA))
        // Saving while parked on `a` makes `a` the current document, with `b` still redoable.
        let saved = try catalog.saveDevelop(a, history: history, forAsset: id)
        XCTAssertEqual(saved.historySeq, seqA)

        let reopened = try Catalog.open(at: packageURL())
        let reread = try reopened.editHistory(forAsset: id)
        XCTAssertEqual(reread.currentSeq, seqA, "history_end survives the reopen")
        XCTAssertEqual(reread.current, a)
        XCTAssertTrue(reread.canRedo, "the state after the cursor is still reachable")
        XCTAssertEqual(try reopened.develop(forAsset: id), a)
    }

    func testSaveRejectsAnEditThatIsNotTheHistorysCurrentState() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        _ = try catalog.appendDevelop(edit(exposure: 0.5), forAsset: id)

        var history = try catalog.editHistory(forAsset: id)
        XCTAssertThrowsError(try catalog.saveDevelop(edit(exposure: 9), history: history, forAsset: id)) {
            guard case DevelopError.historyInconsistent = $0 else {
                return XCTFail("expected historyInconsistent, got \($0)")
            }
        }
        XCTAssertEqual(try catalog.develop(forAsset: id), edit(exposure: 0.5), "nothing was written")

        // Same document, committed properly: accepted.
        history.commit(edit(exposure: 9))
        XCTAssertNoThrow(try catalog.saveDevelop(edit(exposure: 9), history: history, forAsset: id))
    }

    // MARK: - 5. damaged blobs

    func testCorruptBlobIsQuarantinedAndReadsAsNeutral() throws {
        let catalog = try newLibrary()
        // A blob cut off mid-object: what a killed process leaves behind.
        let corrupt = "{\"schemaVersion\":2,\"light\":{\"exposure\":0.5"
        let id = try insertAsset(catalog, developJson: corrupt)

        XCTAssertEqual(try catalog.develop(forAsset: id), .neutral, "damage must not throw at a caller")
        XCTAssertEqual(catalog.developDecodeFailures, 1)
        XCTAssertTrue(try catalog.developState(forAsset: id).recovered)

        let parked = try catalog.quarantinedDevelop(forAsset: id)
        XCTAssertEqual(parked.count, 1)
        XCTAssertEqual(parked[0].developJson, corrupt, "the bytes are kept verbatim — never repaired")
        XCTAssertFalse(parked[0].reason.isEmpty)
        XCTAssertEqual(try storedBlob(catalog, id), corrupt, "quarantine copies, it does not overwrite")
    }

    func testQuarantineIsIdempotentButEveryReadStillCounts() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog, developJson: "not json at all")

        _ = try catalog.develop(forAsset: id)
        _ = try catalog.develop(forAsset: id)
        _ = try catalog.develop(forAsset: id)
        XCTAssertEqual(catalog.developDecodeFailures, 3, "every bad read is reported")
        XCTAssertEqual(try catalog.developQuarantineCount(), 1, "one blob is one piece of evidence")
    }

    func testUndecodableBlobsOfDifferentAssetsStayApart() throws {
        let catalog = try newLibrary()
        let a = try insertAsset(catalog, name: "a.dng", developJson: "[]")
        let b = try insertAsset(catalog, name: "b.dng", developJson: "null")
        _ = try catalog.develop(forAsset: a)
        _ = try catalog.develop(forAsset: b)

        XCTAssertEqual(try catalog.quarantinedDevelop(forAsset: a).map(\.developJson), ["[]"])
        XCTAssertEqual(try catalog.quarantinedDevelop(forAsset: b).map(\.developJson), ["null"])
        XCTAssertEqual(catalog.developDecodeFailures, 2)
    }

    func testMissingAssetReadsNeutralWithoutQuarantining() throws {
        let catalog = try newLibrary()
        XCTAssertEqual(try catalog.develop(forAsset: "no-such-asset"), .neutral)
        XCTAssertEqual(catalog.developDecodeFailures, 1)
        XCTAssertEqual(try catalog.developQuarantineCount(), 0, "there were no bytes to keep")
    }

    func testCorruptHistoryRowIsLeftOutAndQuarantined() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        let a = edit(exposure: 0.5)
        let b = edit(exposure: 1.5)
        _ = try catalog.appendDevelop(a, forAsset: id)
        _ = try catalog.appendDevelop(b, forAsset: id)
        // Rot a middle snapshot the way a torn write would: seq 2 is gone, seqs 1 and 3 are fine.
        try catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE asset_history SET develop_json = ? WHERE asset_id = ? AND seq = 2",
                           arguments: ["{\"light\":", id])
        }

        let rows = try catalog.historyRows(forAsset: id)
        XCTAssertEqual(rows.map(\.seq), [1, 3], "an unrestorable state is dropped, not faked as neutral")
        XCTAssertEqual(rows[0].edit, .neutral)
        XCTAssertEqual(rows[1].edit, b)
        XCTAssertEqual(try catalog.quarantinedDevelop(forAsset: id).count, 1)
        XCTAssertEqual(try catalog.develop(forAsset: id), b, "the current blob is unaffected")
    }

    // MARK: - 6. migration v2 → v3

    func testMigrationV2ToV3KeepsRowsHistoryAndDevelopJson() throws {
        // Fabricate a real v2 library: v1 + v2 DDL, user_version stamped the way Database.swift does,
        // and rows written before v3 existed.
        let pkg = packageURL()
        let layout = LibraryLayout(packageURL: pkg)
        try layout.ensureDirectories()
        let legacyBlob = "{\"schemaVersion\":1,\"light\":{\"exposure\":0.5}}"
        let rootID = UUID().uuidString
        let assetID = UUID().uuidString

        let queue = try DatabaseQueue(path: layout.databaseURL.path, configuration: Catalog.configuration())
        try Schema.migrate(queue, upTo: 2)
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 2") }
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source_roots(id, display_name, path_hint, management_mode, status, created_at)
                VALUES(?, 'src', ?, 'reference', 'online', ?)
                """, arguments: [rootID, workDir.appendingPathComponent("src").path, ISO8601.now()])
            try db.execute(sql: """
                INSERT INTO assets(id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                   content_hash, develop_json, develop_version, imported_at)
                VALUES(?, ?, 'legacy.dng', 'legacy.dng', 'dng', 'raw', 10, 0, ?, ?, 7, ?)
                """, arguments: [assetID, rootID, "hash-legacy", legacyBlob, ISO8601.now()])
            try db.execute(sql: """
                INSERT INTO asset_history(asset_id, seq, develop_json, label, created_at)
                VALUES(?, 1, ?, 'import', ?), (?, 2, ?, 'Exposure', ?)
                """, arguments: [assetID, legacyBlob, ISO8601.now(), assetID, legacyBlob, ISO8601.now()])
        }
        // Sanity: it is a v2 file (no edit_time, no quarantine table yet).
        let preColumns = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('assets')")
        }
        XCTAssertFalse(preColumns.contains("edit_time"))
        XCTAssertEqual(try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }, 2)
        try queue.close()

        // Open through the product path: snapshot first, then migrate.
        let migrated = try Catalog.open(at: pkg)
        // M5 bumped the schema to v4, so this open runs v3 *and* v4. Compare against the current
        // version rather than a literal so the next additive migration does not break this test.
        XCTAssertEqual(migrated.schemaVersionApplied, Schema.version, "v3 and everything after it ran")
        XCTAssertEqual(try migrated.integrityCheck(), "ok")

        // 1. The backup exists, is named for the version it came from, and still holds the old rows.
        let backups = try FileManager.default.contentsOfDirectory(atPath: layout.backupsURL.path)
        XCTAssertTrue(backups.contains("library.bak-v2.db"), "got \(backups)")
        let backup = try DatabaseQueue(path: layout.backupsURL.appendingPathComponent("library.bak-v2.db").path)
        XCTAssertEqual(try backup.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }, 2)
        XCTAssertEqual(try backup.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? 0 }, 1)
        XCTAssertEqual(try backup.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?", arguments: [assetID])
        }, legacyBlob, "the snapshot is the pre-migration file, byte for byte")
        try backup.close()

        // 2. Nothing was renumbered or rewritten: same rows, same blob, same history.
        XCTAssertEqual(try storedBlob(migrated, assetID), legacyBlob, "old develop_json is untouched")
        XCTAssertEqual(try storedVersion(migrated, assetID), 7, "the old version number is kept")
        XCTAssertEqual(try rowCount(migrated, assetID), 2)
        XCTAssertEqual(try migrated.develop(forAsset: assetID).light.exposure, 0.5,
                       "an M1 document still reads, through the forgiving decoder")
        XCTAssertNil(try migrated.developState(forAsset: assetID).editTime, "v3 starts empty")

        // 3. The new tables/columns are live and writable.
        let saved = try migrated.appendDevelop(edit(exposure: 0.9), label: "Exposure", forAsset: assetID)
        XCTAssertEqual(saved.developVersion, 8)
        XCTAssertEqual(saved.historyRows, 3, "the pre-migration rows are still the floor of the stack")
        let rows = try migrated.historyRows(forAsset: assetID)
        XCTAssertEqual(rows.map(\.seq), [1, 2, 3])
        XCTAssertEqual(rows[0].edit.light.exposure, 0.5)
        XCTAssertEqual(try migrated.developQuarantineCount(), 0)
    }

    /// The real upgrade path for an M2 library: it is a **v1** file, so one `open` runs v2 *and* v3.
    func testMigrationV1ToV3RunsBothStepsInOneOpen() throws {
        let pkg = packageURL("V1")
        let layout = LibraryLayout(packageURL: pkg)
        try layout.ensureDirectories()
        let rootID = UUID().uuidString
        let assetID = UUID().uuidString
        let blob = "{\"schemaVersion\":1,\"light\":{\"exposure\":-0.5}}"

        let queue = try DatabaseQueue(path: layout.databaseURL.path, configuration: Catalog.configuration())
        try Schema.migrate(queue, upTo: 1)
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 1") }
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source_roots(id, display_name, path_hint, management_mode, status, created_at)
                VALUES(?, 'src', ?, 'reference', 'online', ?)
                """, arguments: [rootID, workDir.appendingPathComponent("src").path, ISO8601.now()])
            try db.execute(sql: """
                INSERT INTO assets(id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                   content_hash, rating, develop_json, imported_at)
                VALUES(?, ?, 'v1.dng', 'v1.dng', 'dng', 'raw', 10, 0, 'h1', 4, ?, ?)
                """, arguments: [assetID, rootID, blob, ISO8601.now()])
            try db.execute(sql: """
                INSERT INTO asset_history(asset_id, seq, develop_json, label, created_at)
                VALUES(?, 1, ?, 'import', ?)
                """, arguments: [assetID, blob, ISO8601.now()])
        }
        try queue.close()

        let opened = try Catalog.open(at: pkg)
        XCTAssertEqual(opened.schemaVersionApplied, Schema.version, "v2 and every later step ran")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: layout.backupsURL.path)
            .contains("library.bak-v1.db"), "the snapshot names the file it came from")
        XCTAssertEqual(try storedBlob(opened, assetID), blob)
        XCTAssertEqual(try opened.asset(id: assetID)?.rating, 4, "the rest of the row is untouched")
        XCTAssertEqual(try opened.develop(forAsset: assetID).light.exposure, -0.5)
        XCTAssertEqual(try opened.historyRows(forAsset: assetID).count, 1)
        XCTAssertEqual(try opened.developState(forAsset: assetID).historyEnd, 0, "no cursor written yet")
        XCTAssertEqual(try opened.integrityCheck(), "ok")
    }

    // MARK: - 7. atomicity

    func testSaveIsAtomicWhenAHistoryInsertFails() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        let before = try catalog.appendDevelop(edit(exposure: 0.25), forAsset: id)
        XCTAssertEqual(before.historyRows, 2)

        // A failure *inside* the transaction, after the DELETE and (part of) the inserts.
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER boom BEFORE INSERT ON asset_history
                WHEN NEW.seq >= 3 BEGIN SELECT RAISE(ABORT, 'boom'); END;
                """)
        }

        var history = try catalog.editHistory(forAsset: id)
        history.commit(edit(exposure: 0.5), label: "Exposure")
        history.commit(edit(exposure: 0.75), label: "Exposure")   // seq 3 and 4: the 3 hits the trigger
        XCTAssertThrowsError(try catalog.saveDevelop(edit(exposure: 0.75), history: history, forAsset: id))

        XCTAssertEqual(try catalog.develop(forAsset: id), edit(exposure: 0.25), "no half-written document")
        XCTAssertEqual(try storedVersion(catalog, id), before.developVersion, "no version bump")
        XCTAssertEqual(try rowCount(catalog, id), 2, "no half-written history row")
        XCTAssertEqual(try catalog.developState(forAsset: id).historyEnd, before.historySeq,
                       "the cursor did not move either")

        // Drop the trigger: the same save now lands whole.
        try catalog.dbQueue.write { db in try db.execute(sql: "DROP TRIGGER boom") }
        let saved = try catalog.saveDevelop(edit(exposure: 0.75), history: history, forAsset: id)
        XCTAssertEqual(saved.historyRows, 4)
        XCTAssertEqual(try catalog.historyRows(forAsset: id).map(\.seq), [1, 2, 3, 4])
    }

    // MARK: - 8. concurrency / durability

    func testTwoSequentialConnectionsDoNotLoseRows() throws {
        // "Two processes, one after the other": each connection has its own view of the stack, and the
        // second must append to what the first persisted instead of overwriting it.
        var first: Catalog? = try newLibrary()
        let id = try insertAsset(first!, name: "seq.dng")
        _ = try first!.appendDevelop(edit(exposure: 0.1), forAsset: id)
        _ = try first!.appendDevelop(edit(exposure: 0.2), forAsset: id)
        first = nil

        let second = try Catalog.open(at: packageURL())
        XCTAssertEqual(try second.historyRows(forAsset: id).map(\.seq), [1, 2, 3], "the first process's rows")
        _ = try second.appendDevelop(edit(exposure: 0.3), forAsset: id)
        _ = try second.appendDevelop(edit(exposure: 0.4), forAsset: id)

        let third = try Catalog.open(at: packageURL())
        let rows = try third.historyRows(forAsset: id)
        XCTAssertEqual(rows.map(\.seq), [1, 2, 3, 4, 5], "no gaps, nothing overwritten")
        XCTAssertEqual(rows.map(\.edit.light.exposure), [0, 0.1, 0.2, 0.3, 0.4])
        XCTAssertEqual(try storedVersion(third, id), 5)
    }

    func testTwoOpenHandlesDoNotLoseEachOthersRows() throws {
        let pkg = packageURL()
        let a = try Catalog.create(at: pkg)
        let idA = try insertAsset(a, name: "a.dng")
        let idB = try insertAsset(a, name: "b.dng")
        let b = try Catalog.open(at: pkg)          // both handles live at once, WAL

        _ = try a.appendDevelop(edit(exposure: 0.5), forAsset: idA)
        _ = try b.appendDevelop(edit(exposure: -0.5), forAsset: idB)

        let reader = try Catalog.open(at: pkg)
        XCTAssertEqual(try reader.develop(forAsset: idA).light.exposure, 0.5)
        XCTAssertEqual(try reader.develop(forAsset: idB).light.exposure, -0.5)
        XCTAssertEqual(try rowCount(reader, idA), 2)
        XCTAssertEqual(try rowCount(reader, idB), 2)
    }

    // MARK: - 9. performance

    /// 1000 documents, one read each — the number the UI pays when a grid asks "what does this photo
    /// look like". Reported in the Q16 summary as p50/p95 per read.
    func testThousandAssetDevelopReadLatency() throws {
        let catalog = try newLibrary()
        let count = 1000
        let rootDir = workDir.appendingPathComponent("perf", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: rootDir, mode: .reference)
        let document = richEdit()
        let blob = try Catalog.encode(document)

        var ids: [String] = []
        try catalog.dbQueue.write { db in
            for i in 0..<count {
                let asset = Asset(sourceRootId: root.id, relPath: "p\(i).dng", filename: "p\(i).dng",
                                  ext: "dng", kind: .raw, size: 1024, mtime: 0,
                                  contentHash: "hash-\(i)", developJson: blob, developVersion: 3)
                try asset.insert(db)
                ids.append(asset.id)
            }
        }

        // Warm the page cache once, then measure.
        for id in ids { _ = try catalog.develop(forAsset: id) }

        var samples: [Double] = []
        samples.reserveCapacity(count)
        for id in ids {
            let t0 = CFAbsoluteTimeGetCurrent()
            _ = try catalog.develop(forAsset: id)
            samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        let p95 = samples[Int(Double(samples.count) * 0.95)]
        print(String(format: "develop read x%d: p50 %.3f ms  p95 %.3f ms  max %.3f ms",
                     count, p50, p95, samples.last ?? 0))

        XCTAssertEqual(catalog.developDecodeFailures, 0)
        if benchmarks { XCTAssertLessThan(p95, 5.0, "a per-asset document read must stay far below a frame") }
    }
}
