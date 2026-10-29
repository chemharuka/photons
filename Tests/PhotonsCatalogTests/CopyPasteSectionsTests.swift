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
        XCTAssertFalse(try catalog.pasteSettings(payload, intoAsset: ids[0],
                                                 sections: [.whiteBalance]).requiresDecode,
                       "since 143 a white balance is a render gain, not a development")
        XCTAssertEqual(try catalog.develop(forAsset: ids[0]).light.temperature, 5500)
    }

    // MARK: - no-op pastes write nothing

    func testAPasteThatChangesNothingWritesNoRow() throws {
        let catalog = try newLibrary()
        let id = try insertAsset(catalog, name: "noop.dng", edit: target())
        let before = try rows(catalog, id)

        // The payload is the target's own document: every leaf already holds these values. 蒙版 is
        // left out of the narrowing on purpose — a mask list is *additive* (pasting a document's own
        // masks onto itself adds copies, the way Lightroom does), so the no-op contract is about the
        // scalar leaves.
        let leafSections = Set(EditSnapshotSection.copyable).subtracting([.masks])
        let selfPayload = EditSnapshot.capture(try catalog.develop(forAsset: id))
        let report = try catalog.pasteSettings(selfPayload, intoAsset: id, sections: leafSections)
        XCTAssertFalse(report.changed)
        XCTAssertTrue(report.fields.isEmpty)
        XCTAssertEqual(try rows(catalog, id), before, "a no-op paste must not grow the stack")

        // An empty narrowing is the same kind of nothing.
        let empty = try catalog.pasteSettings(EditSnapshot.capture(source()), intoAsset: id, sections: [])
        XCTAssertFalse(empty.changed)
        XCTAssertEqual(try rows(catalog, id), before)

        // 蒙版 asked for explicitly: this source carries none, so there is nothing to write.
        let masksOnly = try catalog.pasteSettings(EditSnapshot.capture(source()), intoAsset: id,
                                                  sections: [.masks])
        XCTAssertFalse(masksOnly.changed)
        XCTAssertEqual(try rows(catalog, id), before)

        // And a mask list pasted onto the photo it came from is a real edit (a copy), not a no-op —
        // stated here so the difference is a measurement rather than a surprise.
        //
        // It is not id churn dressed up as a change: the document gains a second mask object.
        // `isSemanticallyIdentical` — the rule `commit` uses to drop a row — answers false because the
        // mask lists differ, and `maskApplyMaterial` (S1.6's input) differs because there are now two
        // `applyKey`s. Whether the *pixels* move depends on the mask: one carrying local adjustments
        // is applied twice by S1.6, while the fixture's mask here is `LocalAdjustments.identity`, so
        // the picture need not move — but a duplicated mask is still a thing the user can see in the
        // list and must be able to undo. Pasting your own mask list asking for a copy is what
        // Lightroom does too.
        let beforeSelf = try catalog.develop(forAsset: id)
        let selfMasks = try catalog.pasteSettings(selfPayload, intoAsset: id, sections: [.masks])
        XCTAssertTrue(selfMasks.changed, "masks are objects: pasting them adds them")
        let afterSelf = try catalog.develop(forAsset: id)
        XCTAssertEqual(afterSelf.masks.count, 2)
        XCTAssertEqual(try rows(catalog, id), before + 1)
        XCTAssertFalse(EditHistory.isSemanticallyIdentical(beforeSelf, afterSelf),
                       "the documents differ by a mask, so this is not a no-op row")
        XCTAssertTrue(EditHistory.dirtyGroups(from: beforeSelf, to: afterSelf).contains(.masks))
        XCTAssertNotEqual(afterSelf.maskApplyMaterial, beforeSelf.maskApplyMaterial,
                          "the local stage runs twice: the copied mask carries its own adjustments")
    }

    // MARK: - P1-5: 蒙版 as a section, in the catalog

    /// A masks-only paste: **three** masks afterwards (one of the destination's + two carried), all
    /// ids distinct, the destination's own mask untouched, every other field byte-identical — and
    /// exactly **one** history row, so one ⌘Z takes the whole thing back.
    func testAMasksOnlyPasteAppendsReidentifiedMasksAsOneHistoryRow() throws {
        let catalog = try newLibrary()
        var sourceDoc = source()
        sourceDoc.light.exposure = 1.2
        sourceDoc.masks = [
            Mask(id: "m-a1", name: "A 天空", feather: 0.2, components: [
                MaskComponent(id: "c-a1", shape: .radialGradient(
                    RadialGradientShape(center: NormalizedPoint(0.25, 0.75),
                                        radius: NormalizedPoint(0.2, 0.2)))),
            ]),
            Mask(id: "m-a2", name: "A 前景", feather: 0.1),
        ]
        let sourceID = try insertAsset(catalog, name: "src.dng", edit: sourceDoc)
        let targetID = try insertAsset(catalog, name: "dst.dng", edit: target())

        let payload = EditSnapshot.capture(try catalog.develop(forAsset: sourceID),
                                          frameAspect: 4.0 / 3.0)
        let before = try catalog.develop(forAsset: targetID)
        let rowsBefore = try rows(catalog, targetID)

        let report = try catalog.pasteSettings(payload, intoAsset: targetID, sections: [.masks],
                                               destinationAspect: 3.0 / 2.0)
        XCTAssertTrue(report.changed)
        XCTAssertEqual(report.sections, [.masks])
        XCTAssertFalse(report.requiresDecode, "a mask is a GPU-stage change, not a development")
        XCTAssertEqual(try rows(catalog, targetID), rowsBefore + 1, "one paste = one row")

        let after = try catalog.develop(forAsset: targetID)
        print("CATALOG masks-only: \(before.masks.map(\.id)) → \(after.masks.map(\.id))")
        XCTAssertEqual(after.masks.count, 3)
        XCTAssertEqual(Set(after.masks.map(\.id)).count, 3, "ids unique in the stored document")
        XCTAssertEqual(after.masks[0].id, "B-mask", "the destination's own mask keeps its id")
        XCTAssertEqual(after.masks[0].feather, 0.6)
        XCTAssertFalse(after.masks.map(\.id).contains("m-a1"))
        XCTAssertEqual(after.masks[1].name, "A 天空", "the name travels")
        XCTAssertEqual(after.masks[1].feather, 0.2)
        // 4:3 → 3:2: the carried circle re-anchored on the short edge (0.25 → 0.2778, y unchanged).
        guard case .radialGradient(let g)? = after.masks[1].components.first?.shape else {
            return XCTFail("still a radial gradient after the round trip through SQLite")
        }
        XCTAssertEqual(g.center.x, 0.5 + (0.25 - 0.5) * (8.0 / 9.0), accuracy: 1e-12)
        XCTAssertEqual(g.center.y, 0.75, accuracy: 0)
        XCTAssertEqual(g.radius.x, 0.2, "the radius is short-edge normalised: unchanged")

        // Everything that was not checked in is the bytes it was.
        XCTAssertEqual(after.light, before.light)
        XCTAssertEqual(after.color, before.color)
        XCTAssertEqual(after.curve, before.curve)
        XCTAssertEqual(after.geometry, before.geometry)
        XCTAssertEqual(Array(after.masks.map(\.id).prefix(1)), ["B-mask"])

        // One ⌘Z: back to one mask and the original document.
        var history = try catalog.editHistory(forAsset: targetID)
        XCTAssertEqual(history.count, 2, "import row + one paste row")
        let undone = try XCTUnwrap(history.undo())
        XCTAssertEqual(undone.masks.map(\.id), before.masks.map(\.id))
        XCTAssertEqual(undone.light, before.light)
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
