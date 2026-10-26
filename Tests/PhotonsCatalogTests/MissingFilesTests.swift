import XCTest
import Foundation
import CoreGraphics
import ImageIO
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// 「原文件已移动」 — the data half: the flag, the relink, and the deletion that takes the
/// modification records with it.
///
/// Every test drives the real pipeline (import → move the file → rescan → relink/delete) rather than
/// writing flags by hand, because the thing worth proving is that a *file operation* the app never
/// sees ends up as a row the user can act on.
final class MissingFilesTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-missing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    private func newLibrary(_ name: String = "L") throws -> Catalog {
        try Catalog.create(at: workDir.appendingPathComponent("\(name).\(LibraryLayout.packageExtension)"))
    }

    private func sourceDir(_ name: String = "src") throws -> URL {
        let dir = workDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real JPEG, different bytes per `seed`, so two files can never share a content hash.
    @discardableResult
    private func makeJPEG(at url: URL, seed: Int) throws -> URL {
        let w = 24, h = 18
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i * 4] = UInt8((i &* 7 &+ seed &* 31) & 0xFF)
            pixels[i * 4 + 1] = UInt8((i &* 3 &+ seed &* 17) & 0xFF)
            pixels[i * 4 + 2] = UInt8((i &+ seed &* 5) & 0xFF)
            pixels[i * 4 + 3] = 255
        }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("cannot write JPEG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("cannot finalize JPEG") }
        return url
    }

    /// Import one file and hand back the row it produced.
    @discardableResult
    private func importOne(_ catalog: Catalog, name: String, seed: Int, in dir: URL? = nil) throws -> Asset {
        let folder = try dir ?? sourceDir()
        let url = try makeJPEG(at: folder.appendingPathComponent(name), seed: seed)
        _ = try ImportService(catalog: catalog).run(sources: [url], options: ImportOptions())
        let hash = try FileHasher.sha256(of: url)
        guard let asset = try catalog.asset(contentHash: hash) else {
            throw XCTSkip("import did not produce an asset for \(name)")
        }
        return asset
    }

    private func onDisk(_ catalog: Catalog, _ asset: Asset) throws -> URL {
        try catalog.fileURL(for: asset)
    }

    private func move(_ from: URL, to: URL) throws {
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: from, to: to)
    }

    // MARK: - 1. the flag

    /// Deleting one source file marks exactly that row, and nothing else.
    func testRefreshAvailabilityMarksOnlyTheMovedFile() throws {
        let catalog = try newLibrary()
        let a = try importOne(catalog, name: "a.jpg", seed: 1)
        let b = try importOne(catalog, name: "b.jpg", seed: 2)

        var report = try catalog.refreshAvailability()
        XCTAssertEqual(report.missing, 0, "nothing has moved yet")
        XCTAssertEqual(report.checked, 2)

        try FileManager.default.removeItem(at: try onDisk(catalog, a))

        report = try catalog.refreshAvailability()
        XCTAssertEqual(report.missing, 1)
        XCTAssertEqual(report.relinked, 0)
        XCTAssertEqual(try catalog.asset(id: a.id)?.isMissing, true, "the moved row is flagged")
        XCTAssertEqual(try catalog.asset(id: b.id)?.isMissing, false, "its neighbour is not")
        XCTAssertEqual(try catalog.rowCount("assets", assetIDs: [a.id], keyColumn: "id"), 1,
                       "the row is flagged, never deleted — the user has not answered yet")
        print("MISSING flag: checked \(report.checked) → missing \(report.missing)"
              + " (a=\(try catalog.asset(id: a.id)!.isMissing) b=\(try catalog.asset(id: b.id)!.isMissing))")
    }

    /// The file comes back → the flag clears and the pass reports it as a relink (same bytes, same
    /// row, no user action needed).
    func testRefreshClearsTheFlagAndCountsTheReturningFile() throws {
        let catalog = try newLibrary()
        let a = try importOne(catalog, name: "a.jpg", seed: 3)
        let url = try onDisk(catalog, a)
        let parked = workDir.appendingPathComponent("parked-a.jpg")
        try move(url, to: parked)
        XCTAssertEqual(try catalog.refreshAvailability().missing, 1)

        try move(parked, to: url)
        let report = try catalog.refreshAvailability()
        XCTAssertEqual(report.missing, 0)
        XCTAssertEqual(report.relinked, 1, "back where the row says it is")
        XCTAssertEqual(try catalog.asset(id: a.id)?.isMissing, false)
    }

    /// An unplugged root is skipped, not marked: "the drive is gone" is not "the file moved".
    func testOfflineRootIsNotMarkedMissing() throws {
        let catalog = try newLibrary()
        let a = try importOne(catalog, name: "a.jpg", seed: 4)
        let root = try XCTUnwrap(try catalog.root(id: a.sourceRootId))
        // Pretend the volume vanished: point the root at a directory that does not exist.
        try catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE source_roots SET path_hint = ? WHERE id = ?",
                           arguments: [workDir.appendingPathComponent("gone").path, root.id])
        }
        let report = try catalog.refreshAvailability()
        XCTAssertEqual(report.offlineRoots, 1)
        XCTAssertEqual(report.checked, 0, "no row under an offline root is examined")
        XCTAssertEqual(report.missing, 0)
        XCTAssertEqual(try catalog.asset(id: a.id)?.isMissing, false)
    }

    // MARK: - 2. relink

    func testRelinkPointsTheRowAtTheNewPathAndKeepsTheHash() throws {
        let catalog = try newLibrary()
        let a = try importOne(catalog, name: "a.jpg", seed: 5)
        let oldURL = try onDisk(catalog, a)
        let hashBefore = a.contentHash

        let moved = try sourceDir("moved").appendingPathComponent("renamed-a.jpg")
        try move(oldURL, to: moved)
        XCTAssertEqual(try catalog.refreshAvailability().missing, 1)

        let relinked = try catalog.relink(assetID: a.id, to: moved)
        XCTAssertEqual(relinked.isMissing, false)
        XCTAssertEqual(relinked.contentHash, hashBefore, "identity is the bytes, and the bytes did not change")
        XCTAssertEqual(relinked.relPath, "renamed-a.jpg", "the path followed the file")
        XCTAssertEqual(relinked.filename, "renamed-a.jpg")
        XCTAssertEqual(try catalog.fileURL(for: relinked).resolvingSymlinksInPath(),
                       moved.resolvingSymlinksInPath(),
                       "fileURL(for:) resolves to where the file actually is")
        XCTAssertEqual(relinked.size, a.size)
        XCTAssertEqual(try catalog.asset(id: a.id)?.isMissing, false, "the flag is persisted, not just returned")

        // And a rescan agrees: the row is no longer missing and nothing else came back.
        let report = try catalog.refreshAvailability()
        XCTAssertEqual(report.missing, 0)
        XCTAssertEqual(report.relinked, 0)
    }

    /// Same name, different bytes → refused, with the row left exactly as it was.
    func testRelinkRefusesAFileWhoseContentDiffers() throws {
        let catalog = try newLibrary()
        let a = try importOne(catalog, name: "a.jpg", seed: 6)
        let oldURL = try onDisk(catalog, a)
        try FileManager.default.removeItem(at: oldURL)
        XCTAssertEqual(try catalog.refreshAvailability().missing, 1)
        let before = try XCTUnwrap(try catalog.asset(id: a.id))

        // A different photo that happens to be called the same thing.
        let impostor = try sourceDir("impostor").appendingPathComponent("a.jpg")
        try makeJPEG(at: impostor, seed: 999)

        XCTAssertThrowsError(try catalog.relink(assetID: a.id, to: impostor)) { error in
            guard case AvailabilityError.contentMismatch(let id, let expected, let found) = error else {
                return XCTFail("expected contentMismatch, got \(error)")
            }
            XCTAssertEqual(id, a.id)
            XCTAssertEqual(expected, before.contentHash)
            XCTAssertNotEqual(found, expected, "a different photo has a different hash")
        }
        let after = try XCTUnwrap(try catalog.asset(id: a.id))
        XCTAssertTrue(after.isMissing, "a refused relink must not clear the flag")
        XCTAssertEqual(after.relPath, before.relPath, "and must not move the row")
        XCTAssertEqual(after.contentHash, before.contentHash)
        print("RELINK refused: expected \(before.contentHash.prefix(12))…, file hash differs"
              + " — row still missing, relPath unchanged (\(after.relPath))")
    }

    /// Relinking to a file outside every known root registers its folder instead of storing an
    /// absolute path in `rel_path` (the column is relative, and `fileURL(for:)` depends on that).
    func testRelinkOutsideKnownRootsRegistersTheNewFolder() throws {
        let catalog = try newLibrary()
        let a = try importOne(catalog, name: "a.jpg", seed: 7)
        try FileManager.default.removeItem(at: try onDisk(catalog, a))
        XCTAssertEqual(try catalog.refreshAvailability().missing, 1)

        let elsewhere = try sourceDir("elsewhere").appendingPathComponent("a.jpg")
        try makeJPEG(at: elsewhere, seed: 7)   // same seed = same bytes = same identity

        let relinked = try catalog.relink(assetID: a.id, to: elsewhere)
        XCTAssertFalse(relinked.relPath.hasPrefix("/"), "rel_path stays relative: \(relinked.relPath)")
        XCTAssertNotEqual(relinked.sourceRootId, a.sourceRootId, "a new root was registered")
        XCTAssertEqual(try catalog.fileURL(for: relinked).resolvingSymlinksInPath(),
                       elsewhere.resolvingSymlinksInPath())
        XCTAssertEqual(try catalog.roots().count, 2)
    }

    // MARK: - 3. deletion

    /// The whole point of `deleteAssets`: the entry **and** its modification records go, in one
    /// transaction, and the files on disk stay untouched.
    func testDeleteAssetsCascadesEveryModificationRecord() throws {
        let catalog = try newLibrary()
        let keep = try importOne(catalog, name: "keep.jpg", seed: 11)
        let doomed = try importOne(catalog, name: "doomed.jpg", seed: 12)

        // Real modification records, written by the real writer.
        var model = EditModel.neutral
        model.light.exposure = 1.25
        var history = EditHistory(baseline: .neutral)
        _ = history.commit(model, label: "曝光")
        let saved = try catalog.saveDevelop(history.current ?? model, history: history, forAsset: doomed.id)
        XCTAssertEqual(saved.historyRows, 2, "a floor and one edit")

        // The satellite rows the schema keeps beside an asset. The importer already wrote the
        // metadata row (EXIF), so this is an upsert, not an insert.
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO asset_metadata(asset_id, exif_json, iso) VALUES(?, '{}', 400)
                ON CONFLICT(asset_id) DO UPDATE SET iso = 400
                """, arguments: [doomed.id])
            try db.execute(sql: "INSERT INTO keywords(id, name) VALUES('k1', 'travel')")
            try db.execute(sql: "INSERT INTO photo_keywords(asset_id, keyword_id) VALUES(?, 'k1')",
                           arguments: [doomed.id])
            try db.execute(sql: "INSERT INTO albums(id, name, created_at) VALUES('al1', 'A', '2026-01-01T00:00:00Z')")
            try db.execute(sql: "INSERT INTO album_assets(album_id, asset_id) VALUES('al1', ?)",
                           arguments: [doomed.id])
            try db.execute(sql: """
                INSERT INTO develop_quarantine(asset_id, develop_json, develop_version, reason, quarantined_at)
                VALUES(?, '{}', 1, 'test', '2026-01-01T00:00:00Z')
                """, arguments: [doomed.id])
        }

        // A thumbnail on disk, so the cache half is proven too.
        let cache = try ThumbnailCache(root: workDir.appendingPathComponent("thumbs", isDirectory: true))
        let key = ThumbKey.preview(contentHash: doomed.contentHash, tier: .t256)
        try cache.store(Self.minimalJPEG(), for: key)
        XCTAssertTrue(cache.exists(key))
        let keepKey = ThumbKey.preview(contentHash: keep.contentHash, tier: .t256)
        try cache.store(Self.minimalJPEG(), for: keepKey)

        // Before: every table has rows for the doomed asset.
        let tables = ["assets", "asset_history", "asset_metadata", "photo_keywords", "album_assets",
                      "develop_quarantine"]
        let before = try tables.map {
            try catalog.rowCount($0, assetIDs: [doomed.id], keyColumn: $0 == "assets" ? "id" : "asset_id")
        }
        XCTAssertEqual(before, [1, 2, 1, 1, 1, 1], "fixture row counts, table by table")

        let originalURL = try onDisk(catalog, doomed)
        let report = try catalog.deleteAssets(ids: [doomed.id], thumbnails: cache)

        // The report is the assertion, table by table.
        XCTAssertEqual(report.assets, 1)
        XCTAssertEqual(report.history, 2, "asset_history rows for that asset")
        XCTAssertEqual(report.metadata, 1)
        XCTAssertEqual(report.keywords, 1, "photo_keywords rows")
        XCTAssertEqual(report.albumEntries, 1, "album_assets rows")
        XCTAssertEqual(report.quarantine, 1)
        XCTAssertEqual(report.thumbnailFiles, 1, "the preview thumbnail was removed")

        let after = try tables.map {
            try catalog.rowCount($0, assetIDs: [doomed.id], keyColumn: $0 == "assets" ? "id" : "asset_id")
        }
        XCTAssertEqual(after, [0, 0, 0, 0, 0, 0], "nothing that hangs off the entry survived")
        print("DELETE cascade for \(doomed.id): before \(before) → after \(after) "
              + "for \(tables) · report \(report.summary)")

        // The other photo and everything that belongs to it: untouched.
        XCTAssertEqual(try catalog.rowCount("assets", assetIDs: [keep.id], keyColumn: "id"), 1)
        XCTAssertNotNil(try catalog.asset(id: keep.id))
        XCTAssertTrue(cache.exists(keepKey), "another entry's thumbnail is not collateral")
        XCTAssertFalse(cache.exists(key))

        // The original file is *never* touched by a library deletion.
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path),
                      "deleting an entry must not delete the user's file")

        // The keyword and album rows themselves stay: they are library structure, not per-asset data.
        XCTAssertEqual(try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM keywords") ?? 0
        }, 1)
        XCTAssertEqual(try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") ?? 0
        }, 1)
    }

    /// A bulk deletion reports the sum, and an unknown id is a no-op rather than an error.
    func testDeleteAssetsIsAdditiveAndIgnoresUnknownIDs() throws {
        let catalog = try newLibrary()
        let a = try importOne(catalog, name: "a.jpg", seed: 21)
        let b = try importOne(catalog, name: "b.jpg", seed: 22)

        let unknown = try catalog.deleteAssets(ids: ["no-such-asset"])
        XCTAssertEqual(unknown.assets, 0)
        XCTAssertEqual(try catalog.assets(AssetFilter()).count, 2)

        let report = try catalog.deleteAssets(ids: [a.id, b.id])
        XCTAssertEqual(report.assets, 2)
        XCTAssertEqual(try catalog.assets(AssetFilter()).count, 0)
        XCTAssertTrue(try catalog.assets(AssetFilter()).isEmpty)
    }

    // MARK: - 4. migration

    /// A v4 library opens, gains the column, and reads every existing row as present.
    func testV4LibraryGainsTheColumnWithEverythingPresent() throws {
        let pkg = workDir.appendingPathComponent("Old.\(LibraryLayout.packageExtension)")
        let layout = LibraryLayout(packageURL: pkg)
        try layout.ensureDirectories()
        let queue = try DatabaseQueue(path: layout.databaseURL.path, configuration: Catalog.configuration())
        try Schema.migrate(queue, upTo: 4)
        XCTAssertEqual(try queue.read { db in try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0 }, 0,
                       "user_version is stamped by Catalog, not by the migrator")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source_roots(id, display_name, path_hint, management_mode, status, created_at)
                VALUES('r1', 'src', ?, 'reference', 'online', '2026-01-01T00:00:00Z')
                """, arguments: [workDir.appendingPathComponent("src").path])
            try db.execute(sql: """
                INSERT INTO assets(id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                   content_hash, develop_json, develop_version, render_version,
                                   imported_at, deleted)
                VALUES('a1', 'r1', 'old.jpg', 'old.jpg', 'jpg', 'jpeg', 10, 0, 'deadbeef',
                       '{}', 1, 1, '2026-01-01T00:00:00Z', 0)
                """)
        }
        try queue.close()

        let catalog = try Catalog.open(at: pkg)
        XCTAssertEqual(catalog.schemaVersionApplied, 5)
        let asset = try XCTUnwrap(try catalog.asset(id: "a1"))
        XCTAssertFalse(asset.isMissing, "an old row reads as present — pre-v5 behaviour")
        let columns = try catalog.dbQueue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(assets)").map { $0["name"] as String }
        }
        XCTAssertEqual(columns.filter { $0 == "missing" }.count, 1, "exactly one column, not two")
    }

    /// Replaying v5 on a database that already has the column is a no-op, not an error. (The
    /// `user_version` stamp can be lost — a restored backup, a hand-edited file — and a migration
    /// that explodes on a healthy library is worse than one that does nothing.)
    func testV5IsReplayable() throws {
        let catalog = try newLibrary()
        let path = catalog.layout.databaseURL.path
        let queue = try DatabaseQueue(path: path, configuration: Catalog.configuration())
        try queue.write { db in try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v5'") }
        XCTAssertNoThrow(try Schema.migrate(queue))
        let columns = try queue.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(assets)").map { $0["name"] as String }
        }
        XCTAssertEqual(columns.filter { $0 == "missing" }.count, 1)
        try queue.close()
    }

    // MARK: - helpers

    /// The smallest bytes that satisfy `ThumbnailCache.store` (SOI … EOI).
    private static func minimalJPEG() -> Data {
        let w = 8, h = 8
        var pixels = [UInt8](repeating: 128, count: w * h * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        return ThumbnailJPEG.encode(image) ?? Data()
    }
}
