import XCTest
import Foundation
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// 派单 078 P0-7 in the catalog: a **section-narrowed** paste, and a paste onto several photos.
///
/// The session-level file (`PhotonsUITests/CopyPasteSettingsTests`) drives the menu path; this one
/// pins the storage contract underneath it:
///
///   · one paste = one `asset_history` row **per photo**, in that photo's own stack (not one batch
///     transaction, and not one row per group);
///   · the narrowing is applied before the merge, so the sections the user did not check are not
///     written even when the payload carries them;
///   · a paste that changes nothing writes nothing (no row, no version bump).
final class CopyPasteSectionsTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-paste-sections-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func newLibrary() throws -> Catalog {
        try Catalog.create(at: workDir.appendingPathComponent("L.\\(LibraryLayout.packageExtension)"))
    }

    private func source() -> EditModel {
        var a = EditModel.neutral
        a.light.temperature = 5500
        a.light.tint = 10
        a.light.exposure = 1.2
        a.light.contrast = 15
        a.color.vibrance = 20
        a.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        return a
    }

    private func target() -> EditModel {
        var b = EditModel.neutral
        b.light.temperature = 4800
        b.light.tint = 5
        b.light.exposure = -0.4
        b.color.saturation = 30
        b.masks = [Mask(id: "B-mask", name: "B", feather: 0.6)]
        return b
    }

    private func insertAsset(_ catalog: Catalog, name: String, edit: EditModel) throws -> String {
        let rootDir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: rootDir, mode: .reference)
        let blob = try Catalog.encode(edit)
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                          kind: .raw, size: 1, mtime: 0,
                          contentHash: UUID().uuidString, developJson: blob)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try AssetHistory(assetId: asset.id, seq: 1, developJson: blob,
                             label: "import", createdAt: ISO8601.now()).insert(db)
        }
        return asset.id
    }

    private func rows(_ catalog: Catalog, _ id: String) throws -> Int {
        try catalog.editHistory(forAsset: id).count
    }

    // MARK: - one row per photo

    func testPastingIntoThreeAssetsWritesOneRowEach() throws {
        let catalog = try newLibrary()
        let ids = [try insertAsset(catalog, name: "1.dng", edit: target()),
                   try insertAsset(catalog, name: "2.dng", edit: target()),
                   try insertAsset(catalog, name: "3.dng", edit: target())]
        let before = try ids.map { try rows(catalog, $0) }
        let payload = EditSnapshot.capture(source())

        let reports = try catalog.pasteSettings(payload, intoAssets: ids,
                                               sections: [.light, .curve], label: "粘贴设置")
        print("CATALOG paste → \(reports.count) photos: "
              + reports.map { "\($0.assetID.prefix(4)):[\($0.summary)] rows=\($0.historyRows ?? -1)" }
                  .joined(separator: " | "))
        XCTAssertEqual(reports.count, 3)
        XCTAssertTrue(reports.allSatisfy(\.changed))
        for (i, id) in ids.enumerated() {
            XCTAssertEqual(try rows(catalog, id), before[i] + 1, "one paste = one row, per photo")
            let stored = try catalog.develop(forAsset: id)
            XCTAssertEqual(stored.light.exposure, 1.2)
            XCTAssertEqual(stored.light.contrast, 15)
            // The narrowing kept the balance out even though the payload carries 5500 K.
            XCTAssertEqual(stored.light.temperature, 4800)
            XCTAssertEqual(stored.color.vibrance, 0)
            XCTAssertEqual(stored.geometry.crop, NormalizedRect.full)
            XCTAssertEqual(stored.masks.map(\.id), ["B-mask"])
        }
        // The payload's own answer about the pipeline: [.light, .curve] has no balance in it.
        XCTAssertFalse(reports[0].requiresDecode)
        XCTAssertTrue(try catalog.pasteSettings(payload, intoAsset: ids[0],
                                               sections: [.whiteBalance]).requiresDecode)
        XCTAssertEqual(try catalog.develop(forAsset: ids[0]).light.temperature, 5500)
    }

    // MARK: - no-op pastes write nothing

    func testAPasteThatChangesNothingWritesNoRow() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog, name: "noop.dng", edit: target())
        let before = try rows(catalog, id)

        // The payload is the target's own document: every leaf already holds these values.
        let selfPayload = EditSnapshot.capture(try catalog.develop(forAsset: id))
        let report = try catalog.pasteSettings(selfPayload, intoAsset: id,
                                               sections: Set(EditSnapshotSection.copyable))
        XCTAssertFalse(report.changed)
        XCTAssertTrue(report.fields.isEmpty)
        XCTAssertEqual(try rows(catalog, id), before, "a no-op paste must not grow the stack")

        // An empty narrowing is the same kind of nothing.
        let empty = try catalog.pasteSettings(EditSnapshot.capture(source()), intoAsset: id, sections: [])
        XCTAssertFalse(empty.changed)
        XCTAssertEqual(try rows(catalog, id), before)

        // 蒙版 asked for explicitly is dropped, so it is also nothing.
        let masksOnly = try catalog.pasteSettings(EditSnapshot.capture(source()), intoAsset: id,
                                                  sections: [.masks])
        XCTAssertFalse(masksOnly.changed)
        XCTAssertEqual(try rows(catalog, id), before)
    }

    // MARK: - history: one ⌘Z takes the whole paste back

    func testOneUndoRestoresEveryLeafThePasteMoved() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog, name: "undo.dng", edit: target())
        let original = try catalog.develop(forAsset: id)
        let payload = EditSnapshot.capture(source())

        _ = try catalog.pasteSettings(payload, intoAsset: id,
                                      sections: Set(EditSnapshotSection.copyable))
        var history = try catalog.editHistory(forAsset: id)
        XCTAssertEqual(history.count, 2, "import row + one paste row")
        XCTAssertEqual(history.current?.light.exposure, 1.2)

        let undone = try XCTUnwrap(history.undo())
        print("UNDO  after one ⌘Z: exposure=\(undone.light.exposure)"
              + " temperature=\(String(describing: undone.light.temperature))"
              + " vibrance=\(undone.color.vibrance)"
              + " crop=\(undone.geometry.crop.keyString)")
        XCTAssertEqual(undone.light.exposure, original.light.exposure)
        XCTAssertEqual(undone.light.temperature, 4800)
        XCTAssertEqual(undone.color.vibrance, 0)
        XCTAssertEqual(undone.geometry.crop, original.geometry.crop)
        XCTAssertEqual(undone.light.contrast, original.light.contrast)
        XCTAssertEqual(undone.masks.map(\.id), original.masks.map(\.id))
    }
}
