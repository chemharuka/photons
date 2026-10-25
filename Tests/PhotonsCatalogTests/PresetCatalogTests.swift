import XCTest
import Foundation
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// M5 in the catalog: preset CRUD, the default preset, and the settings clipboard — all of it
/// landing in the same document/history machinery v3 built.
///
/// What each group of tests protects:
///
///  - **CRUD is by name**, case-insensitively, so "Punch" cannot exist twice.
///  - **Applying is one undo step**: a preset that covers three panels is one `asset_history` row,
///    not three, and the same is true of a paste.
///  - **Paste is partial**: the destination's masks, overlay and untouched groups survive.
///  - **v3 → v4 keeps everything**: presets are new, so no existing column moves; the old rows are
///    byte-identical and there is a pre-migration snapshot named for the version it came from.
///
/// Filter with `--filter Preset`.
final class PresetCatalogTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-preset-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    private func packageURL(_ name: String = "P") -> URL {
        workDir.appendingPathComponent("\(name).\(LibraryLayout.packageExtension)")
    }

    private func newLibrary(_ name: String = "P") throws -> Catalog {
        try Catalog.create(at: packageURL(name))
    }

    /// A document that differs from `.neutral` in a few easily counted places.
    private func edit(exposure: Double = 0, contrast: Double = 0, saturation: Double = 0) -> EditModel {
        var m = EditModel.neutral
        m.light.exposure = exposure
        m.light.contrast = contrast
        m.color.saturation = saturation
        return m
    }

    @discardableResult
    private func insertAsset(_ catalog: Catalog, name: String = "a.dng",
                             developJson: String = "{}") throws -> String {
        let rootDir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: rootDir, mode: .reference)
        let asset = Asset(sourceRootId: root.id,
                          relPath: name,
                          filename: (name as NSString).lastPathComponent,
                          ext: (name as NSString).pathExtension,
                          kind: .raw,
                          size: 1024, mtime: 0,
                          contentHash: UUID().uuidString,
                          developJson: developJson)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try AssetHistory(assetId: asset.id, seq: 1, developJson: developJson,
                             label: "import", createdAt: ISO8601.now()).insert(db)
        }
        return asset.id
    }

    private func historyRowCount(_ catalog: Catalog, _ id: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_history WHERE asset_id = ?",
                             arguments: [id]) ?? 0
        }
    }

    private func presetRowCount(_ catalog: Catalog) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM presets") ?? 0
        }
    }

    // MARK: - 1. CRUD

    func testPresetCRUDRoundTrip() throws {
        let catalog = try newLibrary()
        let document = edit(exposure: 0.5, contrast: 20)
        let saved = try catalog.savePreset(Preset(name: "Punch", from: document, groups: [.light]))

        XCTAssertEqual(try presetRowCount(catalog), 1)
        XCTAssertEqual(saved.name, "Punch")
        XCTAssertEqual(saved.groups, [.light])
        XCTAssertFalse(saved.isDefault)
        XCTAssertNotNil(ISO8601.date(from: saved.createdAt))
        XCTAssertEqual(saved.edit.light, document.light)

        // Listed.
        let all = try catalog.presetRecords()
        XCTAssertEqual(all.map(\.name), ["Punch"])
        XCTAssertEqual(all[0].id, saved.id)

        // Renamed: same row, new name, envelope name rewritten too.
        let renamed = try catalog.renamePreset(named: "Punch", to: "Punchy")
        XCTAssertEqual(renamed.id, saved.id, "a rename keeps the row")
        XCTAssertEqual(renamed.name, "Punchy")
        XCTAssertEqual(try presetRowCount(catalog), 1)
        XCTAssertNil(try catalog.presetRecord(named: "Punch"), "the old name is gone")
        XCTAssertEqual(try catalog.requirePreset(named: "Punchy").edit.light.contrast, 20)

        // Deleted.
        XCTAssertTrue(try catalog.deletePreset(named: "punchy"), "delete is case-insensitive too")
        XCTAssertEqual(try presetRowCount(catalog), 0)
        XCTAssertFalse(try catalog.deletePreset(named: "Punchy"))
    }

    func testSavePresetTwiceUpdatesTheSameRow() throws {
        let catalog = try newLibrary()
        let first = try catalog.savePreset(Preset(name: "Warm", from: edit(contrast: 10), groups: [.light]))
        let second = try catalog.savePreset(Preset(name: "warm", from: edit(contrast: 40), groups: [.light]))

        XCTAssertEqual(try presetRowCount(catalog), 1, "names are unique case-insensitively")
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.createdAt, first.createdAt, "created_at belongs to the row, not the save")
        XCTAssertEqual(second.edit.light.contrast, 40, "the values are the new ones")
        XCTAssertEqual(try catalog.presetRecords().count, 1)
    }

    func testRenameRefusesToCollideWithAnotherPreset() throws {
        let catalog = try newLibrary()
        try catalog.savePreset(Preset(name: "A", from: edit(contrast: 1), groups: [.light]))
        try catalog.savePreset(Preset(name: "B", from: edit(contrast: 2), groups: [.light]))

        XCTAssertThrowsError(try catalog.renamePreset(named: "A", to: "b")) { error in
            guard case PresetStoreError.duplicateName(let name) = error else {
                return XCTFail("expected duplicateName, got \(error)")
            }
            XCTAssertEqual(name, "b")
        }
        XCTAssertEqual(try catalog.presetRecords().map(\.name), ["A", "B"])
    }

    func testSavedPresetIsCanonicalAndReadableAfterReopen() throws {
        let catalog = try newLibrary()
        try catalog.savePreset(Preset(name: "Look", from: edit(exposure: 0.25), groups: [.light]))
        let blob = try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM presets WHERE name = 'Look'")
        }
        XCTAssertEqual(blob, try Catalog.encode(try catalog.requirePreset(named: "Look").preset),
                       "the row is the canonical encoding of the envelope")
        XCTAssertFalse((blob ?? "").contains("\n"), "one row, one line")

        let reopened = try Catalog.open(at: packageURL())
        let record = try reopened.requirePreset(named: "Look")
        XCTAssertEqual(record.edit.light.exposure, 0.25)
        XCTAssertEqual(record.groups, [.light])
    }

    func testWideningGroupsAfterCaptureDoesNotInventValues() throws {
        let catalog = try newLibrary()
        let document = edit(exposure: 0.5, contrast: 10, saturation: 20)

        // Captured as Light only, then widened by hand. The Color group was never captured, so it
        // must stay neutral — a save must not fabricate values the user never selected.
        var preset = Preset(name: "Widen", from: document, groups: [.light])
        preset.groups = [.light, .color]
        let record = try catalog.savePreset(preset)
        XCTAssertEqual(record.groups, [.light, .color])
        XCTAssertEqual(record.edit.color, .identity, "widening a subset cannot add values")
        XCTAssertEqual(record.edit.light, document.light)
        XCTAssertEqual(EditSnapshot.capture(record.edit).fieldCount, 2)

        // The returned record is exactly what the blob carries.
        let reloaded = try catalog.requirePreset(named: "Widen")
        XCTAssertEqual(record.edit, reloaded.edit)
        XCTAssertEqual(EditSnapshot.capture(reloaded.edit).fieldCount, 2)
    }

    // MARK: - 2. the default preset

    func testOnlyOnePresetCanBeDefault() throws {
        let catalog = try newLibrary()
        try catalog.savePreset(Preset(name: "A", from: edit(contrast: 1), groups: [.light]))
        let b = try catalog.savePreset(Preset(name: "B", from: edit(contrast: 2), groups: [.light]),
                                       makeDefault: true)
        XCTAssertTrue(b.isDefault)
        XCTAssertEqual(try catalog.defaultPresetRecord()?.name, "B")

        // Switching the default clears the previous one in the same transaction: the partial unique
        // index would otherwise reject this.
        try catalog.savePreset(Preset(name: "A", from: edit(contrast: 1), groups: [.light]),
                               makeDefault: true)
        XCTAssertEqual(try catalog.defaultPresetRecord()?.name, "A")
        let all = try catalog.presetRecords()
        XCTAssertEqual(all.filter(\.isDefault).map(\.name), ["A"], "exactly one default")
        XCTAssertEqual(all.first?.name, "A", "the default sorts first")

        // Clearing it leaves no default, and does not delete the preset.
        _ = try catalog.setDefaultPreset(named: nil)
        XCTAssertNil(try catalog.defaultPresetRecord())
        XCTAssertEqual(try presetRowCount(catalog), 2)

        // Deleting the default preset also removes the default.
        _ = try catalog.setDefaultPreset(named: "B")
        XCTAssertTrue(try catalog.deletePreset(named: "B"))
        XCTAssertNil(try catalog.defaultPresetRecord(), "no dangling default")
    }

    // MARK: - 3. applying is one undo step

    func testApplyPresetWritesOneHistoryRowAndKeepsOtherGroups() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        var target = edit(exposure: 0.1, saturation: -5)
        target.effects.vignetteAmount = -20
        target.masks = [Mask(id: "m-target", name: "Sky")]
        _ = try catalog.appendDevelop(target, label: "Develop", forAsset: id)
        let rowsBefore = try historyRowCount(catalog, id)

        var look = EditModel.neutral
        look.light.exposure = 1.25
        look.light.contrast = 30
        look.light.temperature = 5200
        look.geometry.rotationDegrees = 2.5
        look.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        try catalog.savePreset(Preset(name: "Bright", from: look, groups: [.light, .geometry]))

        let saved = try catalog.applyPreset(named: "Bright", toAsset: id)
        XCTAssertTrue(saved.changed)
        XCTAssertEqual(try historyRowCount(catalog, id), rowsBefore + 1,
                       "a preset covering two panels is still one undo step")

        let after = try catalog.develop(forAsset: id)
        XCTAssertEqual(after.light, look.light)
        XCTAssertEqual(after.geometry, look.geometry)
        XCTAssertEqual(after.color, target.color, "Color was not in the preset")
        XCTAssertEqual(after.effects, target.effects, "Effects was not in the preset")
        XCTAssertEqual(after.masks.map(\.id), ["m-target"], "the photo keeps its masks")

        // Applying the same preset again is a no-op: no version bump, no new row.
        let again = try catalog.applyPreset(named: "Bright", toAsset: id)
        XCTAssertFalse(again.changed)
        XCTAssertEqual(try historyRowCount(catalog, id), rowsBefore + 1)
    }

    // MARK: - 4. copy / paste settings

    func testCopySettingsIsSparse() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        _ = try catalog.appendDevelop(edit(exposure: 0.5, contrast: 15), forAsset: id)

        let snapshot = try catalog.copySettings(fromAsset: id)
        XCTAssertEqual(snapshot.fieldCount, 2, "two changed leaves, two stored fields")
        XCTAssertEqual(snapshot.light?.exposure, 0.5)
        XCTAssertEqual(snapshot.light?.contrast, 15)
        XCTAssertNil(snapshot.color)
        XCTAssertEqual(snapshot.groups, [.light])
        XCTAssertLessThan(snapshot.fieldCount, EditSnapshot.fullDocumentFieldCount / 10,
                          "two fields out of 57: the payload is sparse by construction")
    }

    func testPasteSettingsProducesExactlyOneHistoryRowAndSkipsMasks() throws {
        let catalog = try newLibrary()
        let source = try insertAsset(catalog, name: "source.dng")
        let target = try insertAsset(catalog, name: "target.dng")

        var sourceEdit = edit(exposure: 0.75, contrast: 25, saturation: 10)
        sourceEdit.masks = [Mask(id: "m-source", name: "Source mask")]
        sourceEdit.showMaskID = "m-source"
        _ = try catalog.appendDevelop(sourceEdit, label: "Develop", forAsset: source)

        var targetEdit = edit()
        targetEdit.effects.vignetteAmount = -30
        targetEdit.masks = [Mask(id: "m-target", name: "Target mask")]
        targetEdit.showMaskID = "m-target"
        _ = try catalog.appendDevelop(targetEdit, label: "Develop", forAsset: target)
        let rowsBefore = try historyRowCount(catalog, target)

        let snapshot = try catalog.copySettings(fromAsset: source)
        let saved = try catalog.pasteSettings(snapshot, intoAsset: target)

        XCTAssertTrue(saved.changed)
        XCTAssertEqual(try historyRowCount(catalog, target), rowsBefore + 1,
                       "a paste is one undo step, not one per field")
        XCTAssertEqual(saved.historySeq, saved.historyTipSeq, "the cursor is on the pasted state")

        let after = try catalog.develop(forAsset: target)
        XCTAssertEqual(after.light, sourceEdit.light, "the copied group landed")
        XCTAssertEqual(after.color, sourceEdit.color)
        XCTAssertEqual(after.effects, targetEdit.effects, "Effects was not copied")
        XCTAssertEqual(after.masks.map(\.id), ["m-target"], "masks are never pasted")
        XCTAssertEqual(after.showMaskID, "m-target", "the overlay selection is not pasted either")

        // Undo takes the whole paste back in one step.
        var history = try catalog.editHistory(forAsset: target)
        XCTAssertEqual(try XCTUnwrap(history.undo()), targetEdit,
                       "one undo returns the pre-paste document")
    }

    func testPasteEqualsAFullCopyOfTheSource() throws {
        let catalog = try newLibrary()
        let source = try insertAsset(catalog, name: "source.dng")
        let target = try insertAsset(catalog, name: "target.dng")

        var document = edit(exposure: -0.5, contrast: 8, saturation: 30)
        document.light.temperature = 7200
        document.detail.sharpening = 55
        document.curve.rgb = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        _ = try catalog.appendDevelop(document, label: "Develop", forAsset: source)

        let snapshot = try catalog.copySettings(fromAsset: source)
        _ = try catalog.pasteSettings(snapshot, intoAsset: target)

        XCTAssertEqual(try catalog.develop(forAsset: target), document,
                       "paste onto a neutral photo reproduces the source document")
    }

    func testPastingNothingChangesNothing() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog)
        _ = try catalog.appendDevelop(edit(exposure: 0.5), forAsset: id)
        let rowsBefore = try historyRowCount(catalog, id)

        let saved = try catalog.pasteSettings(EditSnapshot(), intoAsset: id)
        XCTAssertFalse(saved.changed)
        XCTAssertEqual(try historyRowCount(catalog, id), rowsBefore)
        XCTAssertEqual(try catalog.develop(forAsset: id), edit(exposure: 0.5))
    }

    // MARK: - 5. version guard

    func testPresetWithANewerSchemaVersionIsRefusedAndCounted() throws {
        let catalog = try newLibrary()
        try catalog.savePreset(Preset(name: "Current", from: edit(contrast: 5), groups: [.light]))
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO presets(id, name, develop_json, is_default, created_at, updated_at)
                VALUES(?, ?, ?, 0, ?, ?)
                """, arguments: ["future-id", "Future",
                                 #"{"schemaVersion":9,"name":"Future","groups":["light"]}"#,
                                 ISO8601.now(), ISO8601.now()])
        }

        // Listing skips it (one unreadable row must not empty the menu) and counts it.
        let listed = try catalog.presetRecords()
        XCTAssertEqual(listed.map(\.name), ["Current"])
        XCTAssertEqual(catalog.presetDecodeFailures, 1)

        // Asking for it by name throws instead of pretending it is not there.
        XCTAssertThrowsError(try catalog.presetRecord(named: "Future")) { error in
            guard case PresetError.unsupportedSchemaVersion(let found, _) = error else {
                return XCTFail("expected unsupportedSchemaVersion, got \(error)")
            }
            XCTAssertEqual(found, 9)
        }

        // Its bytes are untouched: a newer build can still read them.
        let blob = try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM presets WHERE name = 'Future'")
        }
        XCTAssertTrue(blob?.contains("\"schemaVersion\":9") ?? false)
    }

    // MARK: - 6. migration v3 → v4

    func testMigrationV3ToV4KeepsDataAndCreatesPresets() throws {
        let pkg = packageURL("V3")
        let layout = LibraryLayout(packageURL: pkg)
        try layout.ensureDirectories()
        let rootID = UUID().uuidString
        let assetID = UUID().uuidString
        let legacyBlob = #"{"schemaVersion":2,"light":{"exposure":0.5},"color":{"saturation":-7}}"#

        let queue = try DatabaseQueue(path: layout.databaseURL.path, configuration: Catalog.configuration())
        try Schema.migrate(queue, upTo: 3)
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 3") }
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source_roots(id, display_name, path_hint, management_mode, status, created_at)
                VALUES(?, 'src', ?, 'reference', 'online', ?)
                """, arguments: [rootID, workDir.appendingPathComponent("src").path, ISO8601.now()])
            try db.execute(sql: """
                INSERT INTO assets(id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                   content_hash, develop_json, develop_version, imported_at)
                VALUES(?, ?, 'legacy.dng', 'legacy.dng', 'dng', 'raw', 10, 0, 'hash-v3', ?, 7, ?)
                """, arguments: [assetID, rootID, legacyBlob, ISO8601.now()])
            try db.execute(sql: """
                INSERT INTO asset_history(asset_id, seq, develop_json, label, created_at)
                VALUES(?, 1, ?, 'import', ?), (?, 2, ?, 'Exposure', ?)
                """, arguments: [assetID, legacyBlob, ISO8601.now(),
                                 assetID, legacyBlob, ISO8601.now()])
        }
        // Sanity: it is a v3 file — no presets table yet.
        let preTables = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertFalse(preTables.contains("presets"))
        XCTAssertEqual(try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }, 3)
        try queue.close()

        // Product path: snapshot first, then migrate.
        let migrated = try Catalog.open(at: pkg)
        XCTAssertEqual(migrated.schemaVersionApplied, 4)
        XCTAssertEqual(try migrated.integrityCheck(), "ok")

        // 1. The pre-migration copy exists, named for the version it came from, with the old rows.
        let backups = try FileManager.default.contentsOfDirectory(atPath: layout.backupsURL.path)
        XCTAssertTrue(backups.contains("library.bak-v3.db"), "got \(backups)")
        let backup = try DatabaseQueue(path: layout.backupsURL.appendingPathComponent("library.bak-v3.db").path)
        XCTAssertEqual(try backup.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }, 3)
        XCTAssertEqual(try backup.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?", arguments: [assetID])
        }, legacyBlob)
        let backupTables = try backup.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        }
        XCTAssertFalse(backupTables.contains("presets"), "the snapshot is the file as it was")
        try backup.close()

        // 2. Nothing existing moved: same blob, same version, same history, same document.
        XCTAssertEqual(try migrated.developState(forAsset: assetID).developVersion, 7)
        XCTAssertEqual(try migrated.historyRows(forAsset: assetID).map(\.seq), [1, 2])
        XCTAssertEqual(try migrated.develop(forAsset: assetID).color.saturation, -7)

        // 3. The new table is live and writable, and the old document still edits normally.
        XCTAssertEqual(try presetRowCount(migrated), 0, "v4 starts with an empty preset list")
        var look = try migrated.develop(forAsset: assetID)
        look.color.saturation = 55
        look.light.exposure = 0.9
        let record = try migrated.savePreset(Preset(name: "From v3", from: look, groups: [.color]),
                                             makeDefault: true)
        XCTAssertEqual(record.groupNames, ["color"])
        XCTAssertTrue(record.isDefault)

        let saved = try migrated.applyPreset(named: "From v3", toAsset: assetID)
        XCTAssertTrue(saved.changed)
        XCTAssertEqual(saved.developVersion, 8, "one write after the migration, one bump")
        XCTAssertEqual(saved.historyRows, 3, "the pre-migration rows are still the floor of the stack")
        let after = try migrated.develop(forAsset: assetID)
        XCTAssertEqual(after.color.saturation, 55, "the preset's group landed")
        XCTAssertEqual(after.light.exposure, 0.5, "Light was not in the preset")
    }
}

private extension PresetRecord {
    var groupNames: [String] { PresetGroup.ordered(groups).map(\.rawValue) }
}
