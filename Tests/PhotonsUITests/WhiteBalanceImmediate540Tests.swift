import XCTest
import AppKit
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 派单 540 — 切图时色温/色调必须和其他滑块一起出现，不等首帧。
///
/// The two rows used to read `DecoderCapabilities.asShotWhiteBalance`, which only exists once a
/// frame has been developed. 530 made every other slider available in ~2 ms from the document read;
/// this suite pins the gap:
///
///   1. ten photos in a real catalog, switched one by one: after `selectOnly` returns (the document
///      is assigned) and before any frame is handed to the session, `session.asShotWhiteBalance`
///      is already the photo's own pair — bit-for-bit the value the first frame later reports —
///      and the switch took ≤ 5 ms;
///   2. the first frame leaves the two values untouched and does **not** write the row a second time;
///   3. no stored row + a non-RAW file leaves the rows at today's behaviour (no value), with no throw;
///   4. a deliberately wrong stored row is corrected by the first frame, counted once.
///
/// The fixture is the user's own RAW (`PHOTONS_TEST_RAW`), so the suite skips when it is absent.
@MainActor
final class WhiteBalanceImmediate540Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-wb540-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private struct Fixture {
        let session: CatalogSession
        let catalog: Catalog
        let assets: [Asset]
        let urls: [String: URL]
    }

    /// One real library. RAW fixtures are hard-linked (not copied) so ten rows cost no extra disk;
    /// the row identity, not the inode, is what the persistence key uses.
    private func makeLibrary(rawCount: Int, nonRaw: Bool = false) throws -> Fixture {
        let package = workDir.appendingPathComponent("WB540.\(LibraryLayout.packageExtension)",
                                                     isDirectory: true)
        let catalog = try Catalog.create(at: package)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        var urls: [String: URL] = [:]
        let raw = nonRaw ? nil : try fixtureURL()
        for i in 0..<rawCount {
            let name = String(format: "WB540_%02d.%@", i, nonRaw ? "jpg" : "dng")
            let url = src.appendingPathComponent(name)
            if let raw {
                try FileManager.default.linkItem(at: raw, to: url)
            } else {
                try Self.writeTinyJPEG(to: url)
            }
            let id = UUID().uuidString
            let asset = Asset(id: id, sourceRootId: root.id, relPath: name, filename: name,
                              ext: nonRaw ? "jpg" : "dng",
                              kind: nonRaw ? .jpeg : .raw,
                              size: 1, mtime: 0, contentHash: UUID().uuidString,
                              width: 1024, height: 1024,
                              captureTime: String(format: "2026-11-24T10:%02d:00Z", i),
                              captureLocalDate: "2026-11-24",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
            urls[id] = url
        }

        let session = CatalogSession()
        try session.open(package)
        return Fixture(session: session, catalog: catalog, assets: assets, urls: urls)
    }

    private static func writeTinyJPEG(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        let jpeg = try XCTUnwrap(rep.representation(using: .jpeg, properties: [:]))
        try jpeg.write(to: url)
    }

    /// The first frame's answer, without a window: a tiny development is enough to read the pair.
    private func develop(_ url: URL) throws -> DecoderCapabilities {
        try RAWDecoder().decodeDetailed(url, options: DecodeOptions(scale: 0.0625)).capabilities
    }

    /// Visit every photo once so the catalog has a row for each — the "second visit" state the
    /// user is in after a normal session. Returns the decoder's truth per asset.
    private func seed(_ fixture: Fixture) throws -> [String: WhiteBalance] {
        var truth: [String: WhiteBalance] = [:]
        for asset in fixture.assets {
            fixture.session.selectOnly(asset.id)
            let caps = try develop(try XCTUnwrap(fixture.urls[asset.id]))
            // The present path publishes the ingested photo before it hands the frame's facts over;
            // the session uses that identity to refuse a late frame of the previous photo.
            fixture.session.ingestedSourceFrame = (asset.id, ImageSize(width: 1024, height: 1024))
            fixture.session.recordCapabilities(caps)
            truth[asset.id] = caps.asShotWhiteBalance
        }
        return truth
    }

    // MARK: - 1. ten switches, value before the first frame, ≤ 5 ms

    func testTenSwitchesShowAsShotBeforeAnyFrameWithinFiveMilliseconds() throws {
        let fixture = try makeLibrary(rawCount: 10)
        let truth = try seed(fixture)
        XCTAssertEqual(truth.count, 10)
        XCTAssertFalse(fixture.assets.isEmpty)

        var worst = 0.0
        var slowest = ""
        for asset in fixture.assets {
            let started = CFAbsoluteTimeGetCurrent()
            fixture.session.selectOnly(asset.id)
            let milliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
            if milliseconds > worst {
                worst = milliseconds
                slowest = asset.filename
            }

            // The document is assigned and this is still before any frame: a frame would be
            // `recordCapabilities`, which is exactly what this test does not call here.
            XCTAssertEqual(fixture.session.loadedEditAssetID, asset.id)
            XCTAssertEqual(fixture.session.anchorAsset?.id, asset.id)
            XCTAssertEqual(fixture.session.asShotWhiteBalance, truth[asset.id],
                           "\(asset.filename): the rows must read this photo's as-shot pair before "
                           + "the first frame, not the previous photo's")
        }

        print("540 switch→as-shot: worst \(String(format: "%.2f", worst)) ms (\(slowest)) over "
              + "\(fixture.assets.count) photos")
        XCTAssertLessThanOrEqual(worst, 5,
                                 "the white-balance pair must arrive with the document, not after "
                                 + "a frame (worst \(worst) ms on \(slowest))")
    }

    // MARK: - 2. the first frame changes nothing and writes nothing

    func testFirstFrameKeepsTheValueAndDoesNotWriteTheRowAgain() throws {
        let fixture = try makeLibrary(rawCount: 2)
        let truth = try seed(fixture)
        let asset = fixture.assets[0]
        let caps = try develop(try XCTUnwrap(fixture.urls[asset.id]))

        fixture.session.selectOnly(asset.id)
        let before = try XCTUnwrap(fixture.session.asShotWhiteBalance)
        let writesBefore = fixture.session.asShotStoreWriteCount
        let mismatchesBefore = fixture.session.asShotMismatchCount
        XCTAssertEqual(before, truth[asset.id])

        // The first frame lands.
        fixture.session.ingestedSourceFrame = (asset.id, ImageSize(width: 1024, height: 1024))
        fixture.session.recordCapabilities(caps)

        let after = try XCTUnwrap(fixture.session.asShotWhiteBalance)
        XCTAssertEqual(after, before, "the first frame must not move either row")
        XCTAssertEqual(after, caps.asShotWhiteBalance)
        XCTAssertEqual(fixture.session.asShotStoreWriteCount, writesBefore,
                       "a row that already matches must not be written a second time")
        XCTAssertEqual(fixture.session.asShotMismatchCount, mismatchesBefore)
        print("540 first frame: rows unchanged · writes +"
              + "\(fixture.session.asShotStoreWriteCount - writesBefore) · mismatches +"
              + "\(fixture.session.asShotMismatchCount - mismatchesBefore)")
    }

    // MARK: - 3. no row + a non-RAW file: today's behaviour, no error

    func testNonRawWithoutARowLeavesTheRowsWithoutAValue() throws {
        let fixture = try makeLibrary(rawCount: 1, nonRaw: true)
        let asset = try XCTUnwrap(fixture.assets.first)

        fixture.session.selectOnly(asset.id)

        XCTAssertEqual(fixture.session.loadedEditAssetID, asset.id)
        XCTAssertNil(fixture.session.asShotWhiteBalance,
                     "a photo with no row and no decodable pair must say 无值, never a guess")
        XCTAssertNil(fixture.catalog.storedAsShotWhiteBalance(forAsset: asset.id))
        XCTAssertEqual(fixture.session.asShotStoreWriteCount, 0)
        XCTAssertEqual(fixture.session.asShotMismatchCount, 0)
    }

    // MARK: - 4. a wrong row is corrected by the first frame, once

    func testWrongStoredRowIsCorrectedAndCountedOnce() throws {
        let fixture = try makeLibrary(rawCount: 2)
        let asset = try XCTUnwrap(fixture.assets.last)
        let url = try XCTUnwrap(fixture.urls[asset.id])

        // Start on the other photo, then hand-write an old/wrong archive for the one we switch to.
        fixture.session.selectOnly(fixture.assets[0].id)
        let wrong = WhiteBalance(temperature: 4300, tint: -12)
        XCTAssertTrue(fixture.catalog.storeAsShotWhiteBalance(wrong, forAsset: asset.id))
        fixture.session.selectOnly(asset.id)
        XCTAssertEqual(fixture.session.asShotWhiteBalance, wrong,
                       "the stored row is what the rows show before a frame")

        let caps = try RAWDecoder().decodeDetailed(
            url, options: DecodeOptions(scale: 0.0625)).capabilities
        let truth = caps.asShotWhiteBalance
        let writesBefore = fixture.session.asShotStoreWriteCount
        let mismatchesBefore = fixture.session.asShotMismatchCount

        fixture.session.ingestedSourceFrame = (asset.id, ImageSize(width: 1024, height: 1024))
        fixture.session.recordCapabilities(caps)

        XCTAssertEqual(fixture.session.asShotWhiteBalance, truth,
                       "the first frame wins over an old archive")
        XCTAssertEqual(fixture.session.asShotMismatchCount, mismatchesBefore + 1)
        XCTAssertEqual(fixture.session.asShotStoreWriteCount, writesBefore + 1)
        XCTAssertEqual(fixture.catalog.storedAsShotWhiteBalance(forAsset: asset.id), truth,
                       "the correction must be written back, not only shown")
        print("540 mismatch: stored \(wrong.summary) → frame \(truth.summary) · mismatch count "
              + "\(fixture.session.asShotMismatchCount)")
    }
}
