import XCTest
import Foundation
import CoreGraphics
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// 379 — 「从照片库移除此文件夹」, the data half.
///
/// The verb is a **library** verb: the rows, their satellite rows and their thumbnails go, and every
/// original file stays exactly where it is. The fixture is the one the task names, so each assertion
/// is about a path the user can point at:
///
/// ```
/// rootA/day2/a.jpg        rootA/day2/b.jpg        rootA/day2/sub/c.jpg
/// rootA/night/d.jpg       rootB/x/r.jpg
/// ```
///
/// Rows are written directly (the import pipeline is not what this task changes) but the *files* are
/// real files in a temporary directory, because ④ is a claim about the filesystem and a test that
/// only checks rows could pass while the implementation deleted them.
final class FolderRemoval379Tests: XCTestCase {

    private var workDir: URL!
    private var library: URL!
    private var catalog: Catalog!
    private var rootA: SourceRoot!
    private var rootB: SourceRoot!
    /// The files on disk, by rel path under `rootA`/`rootB`.
    private var files: [String: URL] = [:]
    private var ids: [String: String] = [:]
    private var hashes: [String: String] = [:]

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-379-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        library = workDir.appendingPathComponent("L.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: library)
        rootA = try makeRoot("rootA")
        rootB = try makeRoot("rootB")
        try seed()
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixture

    private func makeRoot(_ name: String) throws -> SourceRoot {
        let dir = workDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try catalog.ensureRoot(for: dir, mode: .reference)
    }

    /// One row + one real file. `minute` orders capture time, so "the order the grid shows" is fixed.
    @discardableResult
    private func insert(_ root: SourceRoot, _ relPath: String, minute: Int) throws -> Asset {
        let url = workDir.appendingPathComponent(root.pathHint.split(separator: "/").last.map(String.init) ?? "root")
            .appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not really a photo, but a real file — \(relPath)".utf8).write(to: url)
        let hash = String(format: "%064x", abs(relPath.hashValue) &+ minute)
        let asset = Asset(sourceRootId: root.id,
                          relPath: relPath,
                          filename: (relPath as NSString).lastPathComponent,
                          ext: (relPath as NSString).pathExtension,
                          kind: .jpeg,
                          size: 40,
                          mtime: 0,
                          contentHash: hash,
                          captureTime: String(format: "2026-01-01T00:%02d:00Z", minute))
        try catalog.dbQueue.write { db in try asset.insert(db) }
        files[relPath] = url
        ids[relPath] = asset.id
        hashes[relPath] = hash
        return asset
    }

    private func seed() throws {
        try insert(rootA, "day2/a.jpg", minute: 5)
        try insert(rootA, "day2/b.jpg", minute: 4)
        try insert(rootA, "day2/sub/c.jpg", minute: 3)
        try insert(rootA, "night/d.jpg", minute: 2)
        try insert(rootB, "x/r.jpg", minute: 1)

        // Satellite rows on every photo, so ③ has something to be zero *about*.
        let keyword = Keyword(id: UUID().uuidString, name: "keep")
        let album = Album(name: "A")
        try catalog.dbQueue.write { db in
            try keyword.insert(db)
            try album.insert(db)
            for (relPath, id) in ids {
                try AssetMetadata(assetId: id, exifJson: "{\"rel\":\"\(relPath)\"}").insert(db)
                try db.execute(sql: """
                    INSERT INTO asset_history(asset_id, seq, develop_json, created_at) VALUES (?, 1, '{}', '2026-01-01')
                    """, arguments: [id])
                try db.execute(sql: "INSERT INTO photo_keywords(asset_id, keyword_id) VALUES (?, ?)",
                               arguments: [id, keyword.id])
                try db.execute(sql: "INSERT INTO album_assets(album_id, asset_id, position) VALUES (?, ?, 0)",
                               arguments: [album.id, id])
            }
        }
    }

    private var allPaths: [String] {
        ((try? catalog.assets(AssetFilter(limit: 10_000))) ?? []).map(\.relPath).sorted()
    }

    // MARK: - ① the read

    func testAssetIDsIsTheSubtreeInDisplayOrder() throws {
        let got = try catalog.assetIDs(rootID: rootA.id, folderPath: "day2")
        XCTAssertEqual(got.count, 3, "day2 + day2/sub, not night/d: \(got)")
        XCTAssertEqual(got, [ids["day2/a.jpg"], ids["day2/b.jpg"], ids["day2/sub/c.jpg"]].compactMap { $0 },
                       "capture_time DESC, id — the order the grid shows")
        XCTAssertFalse(got.contains(ids["night/d.jpg"] ?? ""), "a sibling folder is not a subtree")
        XCTAssertEqual(try catalog.folderAssetCount(rootID: rootA.id, folderPath: "day2"), 3,
                       "the COUNT(*) the menu title prints is the same set")
        print("379 ① assetIDs(day2) = \(got.count) · count = \(try catalog.folderAssetCount(rootID: rootA.id, folderPath: "day2"))")
    }

    /// The prefix test is segment-safe: `day2x` is not inside `day2` (the shape a `LIKE 'day2%'`
    /// would get wrong).
    func testThePrefixDoesNotSwallowASiblingWithTheSamePrefix() throws {
        try insert(rootA, "day2x/z.jpg", minute: 6)
        let got = try catalog.assetIDs(rootID: rootA.id, folderPath: "day2")
        XCTAssertEqual(got.count, 3, "day2x/z is a different folder: \(got)")
        XCTAssertFalse(got.contains(ids["day2x/z.jpg"] ?? ""))
    }

    // MARK: - ②③④⑥ the folder removal

    func testRemovingAFolderRemovesItsSubtreeOnly() throws {
        let before = try count("assets")
        let report = try catalog.removeFolder(rootID: rootA.id, path: "day2",
                                              thumbnails: nil)
        XCTAssertEqual(report.assets, 3, "the report is the count the sheet promised")
        XCTAssertEqual(report.assets, 3)
        XCTAssertEqual(report.history, 3, "one history row per photo went with it")
        XCTAssertEqual(report.metadata, 3)
        XCTAssertEqual(report.keywords, 3)
        XCTAssertEqual(report.albumEntries, 3)

        let after = try count("assets")
        print("379 ② assets before = \(before) · after = \(after) · removed = \(report.assets)")
        XCTAssertEqual(after, before - 3)

        XCTAssertTrue(allPaths.contains("night/d.jpg"), "rootA/night/d is untouched")
        XCTAssertTrue(allPaths.contains("x/r.jpg"), "rootB/x/r is untouched")
        XCTAssertFalse(allPaths.contains("day2/a.jpg"))
        XCTAssertFalse(allPaths.contains("day2/b.jpg"))
        XCTAssertFalse(allPaths.contains("day2/sub/c.jpg"))

        // ③ the four satellite tables hold nothing for the three deleted rows.
        let doomed = [ids["day2/a.jpg"], ids["day2/b.jpg"], ids["day2/sub/c.jpg"]].compactMap { $0 }
        for table in ["asset_history", "asset_metadata", "photo_keywords", "album_assets"] {
            let n = try catalog.rowCount(table, assetIDs: doomed)
            print("379 ③ \(table) rows for the deleted 3 = \(n)")
            XCTAssertEqual(n, 0, "\(table) still has rows for a deleted photo")
        }

        // ④ the originals are still on disk — not moved, not trashed.
        for relPath in ["day2/a.jpg", "day2/b.jpg", "day2/sub/c.jpg"] {
            let exists = FileManager.default.fileExists(atPath: try XCTUnwrap(files[relPath]).path)
            print("379 ④ \(relPath) exists = \(exists)")
            XCTAssertTrue(exists, "\(relPath) must survive a library removal")
        }

        // ⑥ a folder removal is not a root removal.
        let roots = try catalog.roots().map(\.id)
        print("379 ⑥ roots after folder removal = \(roots.count)")
        XCTAssertTrue(roots.contains(rootA.id))
        XCTAssertTrue(roots.contains(rootB.id))
    }

    // MARK: - ⑤ thumbnails

    func testRemovingAFolderCleansItsThumbnailFilesAfterTheCommit() throws {
        let cache = try ThumbnailCache(root: workDir.appendingPathComponent("thumbs", isDirectory: true))
        let doomed = ["day2/a.jpg", "day2/b.jpg", "day2/sub/c.jpg"].compactMap { hashes[$0] }
        let kept = try XCTUnwrap(hashes["night/d.jpg"])
        let jpeg = try makeJPEG()
        var doomedKeys: [ThumbKey] = []
        for hash in doomed {
            let key = ThumbKey.preview(contentHash: hash, tier: .t256)
            try cache.store(jpeg, for: key)
            doomedKeys.append(key)
        }
        try cache.store(jpeg, for: .preview(contentHash: kept, tier: .t256))

        let report = try catalog.removeFolder(rootID: rootA.id, path: "day2", thumbnails: cache)
        print("379 ⑤ DeleteReport.thumbnailFiles = \(report.thumbnailFiles)")
        XCTAssertGreaterThan(report.thumbnailFiles, 0, "the three photos' previews must be cleaned")
        for key in doomedKeys {
            XCTAssertFalse(cache.exists(key), "a deleted photo's thumbnail is still on disk: \(key.keyString)")
        }
        XCTAssertTrue(cache.exists(.preview(contentHash: kept, tier: .t256)),
                      "the kept photo's thumbnail must not be touched")
    }

    private func makeJPEG() throws -> Data {
        let side = 16
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return try XCTUnwrap(ThumbnailJPEG.encode(try XCTUnwrap(ctx.makeImage())))
    }

    // MARK: - ⑨ the root removal

    func testRemovingARootDeletesItsRowAndItsPhotosOnly() throws {
        let report = try catalog.removeSourceRoot(id: rootB.id, thumbnails: nil)
        print("379 ⑨ DeleteReport.assets = \(report.assets)")
        XCTAssertEqual(report.assets, 1, "the report must be the real number of rows, not 0")
        XCTAssertEqual(report.metadata, 1)

        let roots = try catalog.roots().map(\.id)
        XCTAssertFalse(roots.contains(rootB.id), "source_roots lost the removed root")
        XCTAssertTrue(roots.contains(rootA.id), "rootA is not affected")

        XCTAssertFalse(allPaths.contains("x/r.jpg"))
        XCTAssertEqual(allPaths, ["day2/a.jpg", "day2/b.jpg", "day2/sub/c.jpg", "night/d.jpg"],
                       "rootA keeps every photo it had")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(files["x/r.jpg"]).path),
                      "the removed root's original is still on disk")
    }

    /// A root removal on an already-emptied folder selection is not special — but it must still
    /// delete the root row when the root holds no photo at all.
    func testRemovingAnEmptyRootStillDeletesTheRow() throws {
        let empty = try makeRoot("rootC")
        let report = try catalog.removeSourceRoot(id: empty.id, thumbnails: nil)
        XCTAssertEqual(report.assets, 0)
        XCTAssertFalse(try catalog.roots().map(\.id).contains(empty.id))
    }

    // MARK: - helpers

    private func count(_ table: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }
}
