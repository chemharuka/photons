import XCTest
import CoreGraphics
import ImageIO
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// 436 A②/A③/A④ — the row stores display pixels, old libraries are backfilled once, and the
/// backfill is replayable.
final class ImportUpright436Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-upright-436-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    /// A real JPEG of `width × height` stored pixels carrying `orientation` in its properties.
    private func makeJPEG(at url: URL, width: Int, height: Int, orientation: Int) throws {
        var pixels = [UInt8](repeating: 128, count: width * height * 4)
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("cannot write JPEG")
        }
        let properties: [String: Any] = [
            kCGImagePropertyOrientation as String: orientation,
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:11:19 10:00:00",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: "Nikon",
                kCGImagePropertyTIFFModel as String: "Z 8",
            ],
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("cannot finalize JPEG") }
    }

    private func newLibrary(_ name: String = "L") throws -> Catalog {
        try Catalog.create(at: workDir.appendingPathComponent("\(name).\(LibraryLayout.packageExtension)"))
    }

    // MARK: - A② import writes display pixels

    func testImportAppliesOrientationToTheStoredRow() throws {
        let catalog = try newLibrary()
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try makeJPEG(at: src.appendingPathComponent("quarter.jpg"), width: 64, height: 48, orientation: 8)
        try makeJPEG(at: src.appendingPathComponent("plain.jpg"), width: 64, height: 48, orientation: 1)

        let summary = try ImportService(catalog: catalog).run(sources: [src],
                                                              options: ImportOptions(mode: .reference))
        XCTAssertEqual(summary.added, 2)

        let assets = try catalog.assets(AssetFilter())
        let turned = try XCTUnwrap(assets.first { $0.filename == "quarter.jpg" })
        let plain = try XCTUnwrap(assets.first { $0.filename == "plain.jpg" })

        print("436 A② orientation 8 stored 64×48 → row \(String(describing: turned.width))×"
              + "\(String(describing: turned.height))")
        XCTAssertEqual(turned.width, 48, "display width is the stored height")
        XCTAssertEqual(turned.height, 64, "display height is the stored width")

        XCTAssertEqual(plain.width, 64, "orientation 1 keeps the stored width")
        XCTAssertEqual(plain.height, 48, "orientation 1 keeps the stored height")
    }

    // MARK: - A③ v7 migration

    private func makeV6Library() throws -> (URL, [(String, Int, Int, Int?)]) {
        let pkg = workDir.appendingPathComponent("Old.\(LibraryLayout.packageExtension)")
        let layout = LibraryLayout(packageURL: pkg)
        try layout.ensureDirectories()
        let queue = try DatabaseQueue(path: layout.databaseURL.path,
                                      configuration: Catalog.configuration())
        try Schema.migrate(queue, upTo: 6)
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 6") }

        // (id, width, height, orientation): a quarter-turned photo, a normal landscape photo, and a
        // stored pair that is already taller than wide while claiming orientation 8 (left alone).
        let rows: [(String, Int, Int, Int?)] = [
            ("turned", 9520, 6336, 8),
            ("plain", 6000, 4000, 1),
            ("already", 4000, 6000, 8),
        ]
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source_roots(id, display_name, path_hint, management_mode, status, created_at)
                VALUES('r1', 'src', ?, 'reference', 'online', '2026-01-01T00:00:00Z')
                """, arguments: [workDir.appendingPathComponent("src").path])
            for (id, w, h, orientation) in rows {
                try db.execute(sql: """
                    INSERT INTO assets(id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                       content_hash, width, height, develop_json, develop_version,
                                       render_version, imported_at, deleted)
                    VALUES(?, 'r1', ?, ?, 'jpg', 'jpeg', 10, 0, ?, ?, ?, '{}', 1, 1,
                           '2026-01-01T00:00:00Z', 0)
                    """, arguments: [id, "\(id).jpg", "\(id).jpg", "hash-\(id)", w, h])
                try db.execute(sql: """
                    INSERT INTO asset_metadata(asset_id, orientation) VALUES(?, ?)
                    """, arguments: [id, orientation])
            }
        }
        try queue.close()
        return (pkg, rows)
    }

    private func dimensions(_ catalog: Catalog) throws -> [String: (Int?, Int?)] {
        try catalog.dbQueue.read { db in
            var out: [String: (Int?, Int?)] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT id, width, height FROM assets") {
                out[row["id"]] = (row["width"], row["height"])
            }
            return out
        }
    }

    func testV7SwapsOnlyQuarterTurnedRowsAndReplaysAsANoOp() throws {
        let (pkg, _) = try makeV6Library()

        let migrated = try Catalog.open(at: pkg)
        XCTAssertEqual(migrated.schemaVersionApplied, Schema.version)
        XCTAssertEqual(try migrated.dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }, Schema.version)

        let after = try dimensions(migrated)
        print("436 A③ after v7: \(after)")
        XCTAssertEqual(after["turned"]?.0, 6336)
        XCTAssertEqual(after["turned"]?.1, 9520)
        XCTAssertEqual(after["plain"]?.0, 6000)
        XCTAssertEqual(after["plain"]?.1, 4000)
        XCTAssertEqual(after["already"]?.0, 4000, "already upright: deliberately untouched")
        XCTAssertEqual(after["already"]?.1, 6000)

        // Replay: pretend the `user_version` stamp was lost *and* GRDB's record vanished, exactly
        // the failure mode the migration's `width > height` guard exists for.
        try migrated.dbQueue.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7'")
            try db.execute(sql: "PRAGMA user_version = 6")
        }

        let replayed = try Catalog.open(at: pkg)
        let again = try dimensions(replayed)
        print("436 A③ after replay: \(again)")
        XCTAssertEqual(again["turned"]?.0, 6336, "a replay must not swap the numbers back")
        XCTAssertEqual(again["turned"]?.1, 9520)
        XCTAssertEqual(try replayed.dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }, Schema.version)
    }

    // MARK: - A④ a copy of the real demo library

    /// Opt-in: `PHOTONS_UPRIGHT_LIBRARY=/path/to/copy.photonslibrary swift test --filter …`.
    /// The test opens (and thereby migrates) the **copy**, never the original.
    func testRealDemoLibraryCopyBackfillsQuarterTurnedRows() throws {
        guard let path = ProcessInfo.processInfo.environment["PHOTONS_UPRIGHT_LIBRARY"] else {
            throw XCTSkip("set PHOTONS_UPRIGHT_LIBRARY to a copy of the demo library")
        }
        let pkg = URL(fileURLWithPath: path)
        // Read the *live* file before `Catalog.open` migrates it. (A `backups/` entry may be a
        // stale snapshot from an earlier session, so it is not a trustworthy "before".)
        let pre = try DatabaseQueue(path: pkg.appendingPathComponent("library.db").path,
                                    configuration: Catalog.configuration())
        let prePortrait = try pre.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM assets WHERE height > width") ?? 0
        }
        let expected = try pre.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM assets a JOIN asset_metadata m ON m.asset_id = a.id
                 WHERE a.width > a.height AND m.orientation BETWEEN 5 AND 8
                """) ?? 0
        }
        try pre.close()
        XCTAssertEqual(prePortrait, 0, "before v7 the demo library has no portrait rows")

        let catalog = try Catalog.open(at: pkg)
        let rows = try catalog.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.id, a.width, a.height, m.orientation
                  FROM assets a LEFT JOIN asset_metadata m ON m.asset_id = a.id
                 WHERE a.height > a.width
                """)
        }
        let all = try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? 0
        }
        print("436 A④ v\(catalog.schemaVersionApplied) assets \(all) portrait rows \(prePortrait) → "
              + "\(rows.count) (expected \(expected)): "
              + rows.map { "\($0["width"] ?? 0)×\($0["height"] ?? 0) ori \($0["orientation"] ?? 0)" }
                  .joined(separator: ", "))
        XCTAssertEqual(rows.count, expected, "every stored-landscape row with orientation 5…8 swapped")
        XCTAssertTrue(rows.allSatisfy { (($0["orientation"] as Int?) ?? 0) >= 5
                                        && (($0["orientation"] as Int?) ?? 0) <= 8 },
                      "only quarter-turned rows became portrait")
    }
}
