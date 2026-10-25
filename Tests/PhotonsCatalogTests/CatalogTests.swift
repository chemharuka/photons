import XCTest
import CoreGraphics
import ImageIO
import GRDB
@testable import PhotonsCatalog

/// M2 unit tests: schema, dedupe, move/offline semantics, migrations, and the XMP mapping.
/// The end-to-end walk over 1000 files lives in `Tests/catalog-acceptance.sh` (`make catalog`).
final class CatalogTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func newLibrary(_ name: String = "T") throws -> Catalog {
        try Catalog.create(at: workDir.appendingPathComponent("\(name).\(LibraryLayout.packageExtension)"))
    }

    private func sourceDir() throws -> URL {
        let dir = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A real JPEG with EXIF and XMP — the same shapes the importer sees for RAW.
    @discardableResult
    private func makeJPEG(at url: URL, rating: Int, label: String, keywords: [String],
                          make: String = "Canon", model: String = "EOS R5",
                          date: String = "2026:03:07 10:00:00", seed: Int = 0) throws -> URL {
        let w = 32, h = 24
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i * 4] = UInt8((i &* 7 &+ seed &* 13) & 0xFF)
            pixels[i * 4 + 1] = UInt8((i &* 3 &+ seed &* 29) & 0xFF)
            pixels[i * 4 + 2] = UInt8((i &+ seed) & 0xFF)
            pixels[i * 4 + 3] = 255
        }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!

        let md = CGImageMetadataCreateMutable()
        _ = CGImageMetadataSetValueWithPath(md, nil, "xmp:Rating" as CFString, NSNumber(value: rating))
        _ = CGImageMetadataSetValueWithPath(md, nil, "xmp:Label" as CFString, label as CFString)
        if let tag = CGImageMetadataTagCreate("http://purl.org/dc/elements/1.1/" as CFString,
                                              "dc" as CFString, "subject" as CFString,
                                              .arrayUnordered, keywords as CFArray) {
            _ = CGImageMetadataSetTagWithPath(md, nil, "dc:subject" as CFString, tag)
        }
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: date,
                kCGImagePropertyExifOffsetTimeOriginal as String: "+08:00",
                kCGImagePropertyExifISOSpeedRatings as String: [400],
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFMake as String: make,
                kCGImagePropertyTIFFModel as String: model,
            ],
        ]
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("cannot write JPEG")
        }
        CGImageDestinationAddImageAndMetadata(dest, image, md, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("cannot finalize JPEG") }
        return url
    }

    // MARK: - schema / lifecycle

    func testCreateThenOpenKeepsSchemaVersion() throws {
        let pkg = workDir.appendingPathComponent("L.photonslibrary")
        let created = try Catalog.create(at: pkg)
        XCTAssertEqual(created.schemaVersionApplied, Schema.version)
        XCTAssertEqual(try created.integrityCheck(), "ok")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.layout.originalsURL.path))

        let reopened = try Catalog.open(at: pkg)
        XCTAssertEqual(reopened.schemaVersionApplied, Schema.version)
    }

    func testCreateRefusesExistingLibrary() throws {
        let pkg = workDir.appendingPathComponent("L.photonslibrary")
        _ = try Catalog.create(at: pkg)
        XCTAssertThrowsError(try Catalog.create(at: pkg))
    }

    func testOpenRefusesLibraryFromNewerVersion() throws {
        let pkg = workDir.appendingPathComponent("L.photonslibrary")
        let catalog = try Catalog.create(at: pkg)
        try catalog.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA user_version = 999")
        }
        XCTAssertThrowsError(try Catalog.open(at: pkg)) { error in
            guard case CatalogError.libraryFromNewerVersion(let found, let supported) = error else {
                return XCTFail("expected libraryFromNewerVersion, got \(error)")
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, Schema.version)
        }
    }

    func testPendingMigrationTakesSnapshotFirst() throws {
        let pkg = workDir.appendingPathComponent("L.photonslibrary")
        let catalog = try Catalog.create(at: pkg)
        try catalog.dbQueue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA user_version = 0")
        }
        _ = try Catalog.open(at: pkg)
        let backups = try FileManager.default.contentsOfDirectory(atPath: catalog.layout.backupsURL.path)
        XCTAssertTrue(backups.contains { $0.hasPrefix("library.bak-v0") }, "got \(backups)")
    }

    // MARK: - identity

    func testContentHashIsUnique() throws {
        let catalog = try newLibrary()
        let dir = try sourceDir()
        let a = try makeJPEG(at: dir.appendingPathComponent("a.jpg"), rating: 1, label: "Red", keywords: ["x"], seed: 1)
        _ = try ImportService(catalog: catalog).run(sources: [a], options: ImportOptions())
        let asset = try XCTUnwrap(try catalog.assets(AssetFilter()).first)

        let hash = try FileHasher.sha256(of: a)
        let duplicate = Asset(sourceRootId: asset.sourceRootId, relPath: "other.jpg", filename: "other.jpg",
                              ext: "jpg", kind: .jpeg, size: 1, mtime: 0, contentHash: hash)
        XCTAssertThrowsError(try catalog.dbQueue.write { db in try duplicate.insert(db) },
                            "content_hash must be unique — identity is the whole file")
    }

    func testQuickHashIsNotIdentity() throws {
        let dir = try sourceDir()
        let url = try makeJPEG(at: dir.appendingPathComponent("q.jpg"), rating: 0, label: "None", keywords: [], seed: 3)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber).intValue
        let quick = try FileHasher.quickHash(of: url, size: size, mtime: 0)
        let full = try FileHasher.sha256(of: url)
        XCTAssertNotEqual(quick, full)
        XCTAssertEqual(quick, try FileHasher.quickHash(of: url, size: size, mtime: 0), "quick hash is stable")
        XCTAssertNotEqual(quick, try FileHasher.quickHash(of: url, size: size, mtime: 1), "mtime participates")
    }

    func testCameraKeyNormalisesCaseAndWhitespace() {
        XCTAssertEqual(Asset.cameraKey(make: "LEICA CAMERA AG", model: "LEICA  SL3 "),
                       "leica camera ag|leica sl3")
        XCTAssertEqual(Asset.cameraKey(make: nil, model: " EOS R5"), "eos r5")
        XCTAssertNil(Asset.cameraKey(make: nil, model: nil))
        XCTAssertNil(Asset.cameraKey(make: "  ", model: ""))
    }

    // MARK: - metadata

    func testEmbeddedXMPIsMappedToColumns() throws {
        let dir = try sourceDir()
        let url = try makeJPEG(at: dir.appendingPathComponent("m.jpg"), rating: 4, label: "Green",
                               keywords: ["travel", "coast"], make: "Sony", model: "A7RV")
        let meta = try MetadataReader.read(url)
        XCTAssertEqual(meta.rating, 4)
        XCTAssertEqual(meta.colorLabel, "Green")
        XCTAssertEqual(meta.keywords.sorted(), ["coast", "travel"])
        XCTAssertEqual(meta.cameraKey, "sony|a7rv")
        XCTAssertEqual(meta.captureTimeSource, "exif")
        XCTAssertEqual(meta.captureLocalDate, "2026-03-07")
        XCTAssertEqual(meta.iso, 400)
        XCTAssertNotNil(meta.xmpBlob)
        XCTAssertTrue(meta.hadEmbeddedXMP)
        XCTAssertFalse(meta.exifJSON.isEmpty)
    }

    func testImportStoresKeywordsAndMetadata() throws {
        let catalog = try newLibrary()
        let dir = try sourceDir()
        let url = try makeJPEG(at: dir.appendingPathComponent("k.jpg"), rating: 5, label: "Blue",
                               keywords: ["alpha", "beta"])
        _ = try ImportService(catalog: catalog).run(sources: [url], options: ImportOptions())
        let asset = try XCTUnwrap(try catalog.assets(AssetFilter()).first)
        XCTAssertEqual(asset.rating, 5)
        XCTAssertEqual(asset.colorLabel, "Blue")
        XCTAssertEqual(try catalog.keywords(assetId: asset.id), ["alpha", "beta"])
        let md = try XCTUnwrap(try catalog.metadata(assetId: asset.id))
        XCTAssertEqual(md.iso, 400)
        XCTAssertNotNil(md.xmpBlob)
    }

    // MARK: - import semantics

    func testDuplicateContentIsSkippedAndReported() throws {
        let catalog = try newLibrary()
        let dir = try sourceDir()
        let a = try makeJPEG(at: dir.appendingPathComponent("a.jpg"), rating: 0, label: "None", keywords: [], seed: 11)
        let b = dir.appendingPathComponent("copy-of-a.jpg")
        try FileManager.default.copyItem(at: a, to: b)

        let summary = try ImportService(catalog: catalog).run(sources: [dir], options: ImportOptions())
        XCTAssertEqual(summary.added, 1)
        XCTAssertEqual(summary.duplicate, 1)
        XCTAssertEqual(try catalog.stats().total, 1)
    }

    func testSecondImportIsIdempotent() throws {
        let catalog = try newLibrary()
        let dir = try sourceDir()
        for i in 0..<5 {
            _ = try makeJPEG(at: dir.appendingPathComponent("p\(i).jpg"), rating: i, label: "None",
                             keywords: [], seed: 100 + i)
        }
        let service = ImportService(catalog: catalog)
        let first = try service.run(sources: [dir], options: ImportOptions())
        XCTAssertEqual(first.added, 5)
        let second = try service.run(sources: [dir], options: ImportOptions())
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.unchanged, 5)
        XCTAssertEqual(try catalog.stats().total, 5)
    }

    func testMovedFileKeepsItsRowAndHistory() throws {
        let catalog = try newLibrary()
        let dir = try sourceDir()
        let url = try makeJPEG(at: dir.appendingPathComponent("mover.jpg"), rating: 3, label: "Yellow",
                               keywords: ["keep"], seed: 21)
        let service = ImportService(catalog: catalog)
        _ = try service.run(sources: [dir], options: ImportOptions())
        let before = try XCTUnwrap(try catalog.assets(AssetFilter()).first)

        try catalog.setRating(4, forAsset: before.id)          // something worth not losing
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: sub.appendingPathComponent("mover.jpg"))

        let again = try service.run(sources: [dir], options: ImportOptions())
        XCTAssertEqual(again.moved, 1)
        let after = try XCTUnwrap(try catalog.asset(id: before.id))
        XCTAssertEqual(after.relPath, "sub/mover.jpg")
        XCTAssertEqual(after.rating, 4, "the row — and its edits — must survive the move")
        XCTAssertEqual(after.contentHash, before.contentHash)
    }

    func testCopyModeMaterialisesInsideThePackage() throws {
        let catalog = try newLibrary()
        let dir = try sourceDir()
        _ = try makeJPEG(at: dir.appendingPathComponent("c.jpg"), rating: 0, label: "None", keywords: [], seed: 31)
        let summary = try ImportService(catalog: catalog).run(
            sources: [dir], options: ImportOptions(mode: .copy, renameTemplate: "{YYYY}/{MM}/{orig}"))
        XCTAssertEqual(summary.added, 1)

        let asset = try XCTUnwrap(try catalog.assets(AssetFilter()).first)
        XCTAssertTrue(asset.relPath.hasPrefix("2026/03/"), asset.relPath)
        let url = try catalog.fileURL(for: asset)
        XCTAssertTrue(url.path.hasPrefix(catalog.layout.originalsURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try catalog.verify().isClean)
    }

    func testOfflineRootKeepsRowsAndVerifyStaysClean() throws {
        let catalog = try newLibrary()
        let dir = try sourceDir()
        _ = try makeJPEG(at: dir.appendingPathComponent("o.jpg"), rating: 0, label: "None", keywords: [], seed: 41)
        _ = try ImportService(catalog: catalog).run(sources: [dir], options: ImportOptions())
        XCTAssertEqual(try catalog.stats().total, 1)

        let away = dir.deletingLastPathComponent().appendingPathComponent("src-away")
        try FileManager.default.moveItem(at: dir, to: away)
        defer { try? FileManager.default.moveItem(at: away, to: dir) }

        let stats = try catalog.stats()
        XCTAssertEqual(stats.total, 1, "an offline root must never delete rows")
        XCTAssertEqual(stats.byRoot.first?.status, "offline")
        XCTAssertTrue(try catalog.verify().isClean, "offline files are not 'missing'")
    }

    func testFilenameChangeWithoutMoveStaysDuplicate() throws {
        let catalog = try newLibrary()
        let dir = try sourceDir()
        let url = try makeJPEG(at: dir.appendingPathComponent("twin.jpg"), rating: 0, label: "None",
                               keywords: [], seed: 51)
        let service = ImportService(catalog: catalog)
        _ = try service.run(sources: [dir], options: ImportOptions())
        let original = try XCTUnwrap(try catalog.assets(AssetFilter()).first)

        // A byte-identical copy under a different name, with the original still present: the row
        // must not move to the copy.
        try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("twin-copy.jpg"))
        let again = try service.run(sources: [dir], options: ImportOptions())
        XCTAssertEqual(again.duplicate, 1)
        XCTAssertEqual(again.moved, 0)
        XCTAssertEqual(try catalog.asset(id: original.id)?.relPath, original.relPath)
    }

    // MARK: - queries / soft delete

    func testFiltersAndSoftDelete() throws {
        let catalog = try newLibrary()
        let dir = try sourceDir()
        _ = try makeJPEG(at: dir.appendingPathComponent("1.jpg"), rating: 5, label: "Red", keywords: [], make: "Canon", model: "EOS R5", seed: 61)
        _ = try makeJPEG(at: dir.appendingPathComponent("2.jpg"), rating: 2, label: "None", keywords: [], make: "Nikon", model: "Z8", seed: 62)
        _ = try makeJPEG(at: dir.appendingPathComponent("3.jpg"), rating: 4, label: "None", keywords: [], make: "Canon", model: "EOS R5", seed: 63)
        _ = try ImportService(catalog: catalog).run(sources: [dir], options: ImportOptions())

        XCTAssertEqual(try catalog.assets(AssetFilter(ratingAtLeast: 4)).count, 2)
        XCTAssertEqual(try catalog.assets(AssetFilter(cameraKey: "canon|eos r5")).count, 2)
        XCTAssertEqual(try catalog.assets(AssetFilter(sinceLocalDate: "2026-03-01")).count, 3)

        let victim = try XCTUnwrap(try catalog.assets(AssetFilter()).first)
        try catalog.setDeleted(true, forAsset: victim.id)
        XCTAssertEqual(try catalog.assets(AssetFilter()).count, 2, "soft-deleted rows leave the default view")
        XCTAssertEqual(try catalog.assets(AssetFilter(includeDeleted: true)).count, 3)
        XCTAssertEqual(try catalog.stats().deleted, 1)
        XCTAssertNotNil(try catalog.asset(id: victim.id), "the row itself is kept")
    }
}
