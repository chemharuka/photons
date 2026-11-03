import XCTest
import AppKit
import CoreGraphics
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 290 — the first-frame stand-in must use the **upright** picture before the first ingest.
///
/// The catalog row's `width/height` are the **stored** (sensor) dimensions. For an EXIF orientation
/// of 5…8 the picture the user sees is those two swapped, and the thumbnail the stand-in draws is
/// already upright. Until `publishIngestedSource` publishes the real frame, the fallback projection
/// used to be built from the stored pair, so an EXIF portrait was laid out as a landscape: wider and
/// shorter than the frame that followed.
///
/// These tests pin the two fallback authorities and the hand-off:
///   1. a recorded orientation 6 swaps the stored dimensions (the reverse gate: the raw pair must red);
///   2. an unknown orientation uses the thumbnail's own (upright) aspect instead of the stored pair;
///   3. once the real upright size is ingested, the stand-in's rectangle does not move.
@MainActor
final class PlaceholderExifTests: XCTestCase {

    private var workDir: URL!
    /// The controller holds its session weakly; keep the session alive for the whole test.
    private var keepAlive: [AnyObject] = []

    /// The stored pair of the 072 fixture: a landscape sensor frame.
    private let stored = ImageSize(width: 9520, height: 6336)
    /// The same file after an EXIF orientation of 6: the picture is a portrait.
    private let upright = ImageSize(width: 6336, height: 9520)
    private var uprightAspect: Double { Double(upright.height) / Double(upright.width) }
    private var storedAspect: Double { Double(stored.height) / Double(stored.width) }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-placeholder-exif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        keepAlive.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - the acceptance

    /// Orientation known (EXIF 6), not ingested: the stand-in is the portrait the user sees, not the
    /// landscape the catalog row spells. The second assertion is 290's reverse gate — reverting the
    /// fallback to the raw stored pair turns this test red.
    func testExifPortraitUsesTheUprightAspectBeforeIngest() throws {
        let (loupe, session, _) = try makeLoupe(orientation: 6, thumbnail: (640, 960))
        XCTAssertNil(session.ingestedSourceFrame, "the test is not before ingest")

        loupe.zoomToFit()
        loupe.scheduleRender()
        XCTAssertTrue(loupe.firstFramePlaceholderVisible, "the stand-in did not install")

        let rect = loupe.placeholderRectForTesting
        let aspect = rect.height / max(rect.width, 1e-9)
        print(String(format: "290 EXIF 6 · stand-in %.2f×%.2f · h/w %.4f · upright %.4f"
                     + " · stored %.4f · canvas %.0f×%.0f",
                     rect.width, rect.height, aspect, uprightAspect, storedAspect,
                     loupe.canvasView.bounds.width, loupe.canvasView.bounds.height))

        XCTAssertEqual(aspect, uprightAspect, accuracy: 0.02,
                       "290 未 ingest 的 EXIF 竖幅仍按目录里的横值算")
        XCTAssertGreaterThan(abs(aspect - storedAspect), 0.02,
                             "290 reverse gate: the raw stored dimensions passed as upright")
    }

    /// The orientation half alone: even with no thumbnail size handed to the seam, a recorded EXIF 6
    /// swaps the catalog pair. (The test above could otherwise pass through the thumbnail authority.)
    func testRecordedOrientationAloneSwapsTheStoredDimensions() throws {
        let (loupe, session, _) = try makeLoupe(orientation: 6, thumbnail: (640, 960))
        XCTAssertNil(session.ingestedSourceFrame, "the test is not before ingest")

        let rect = loupe.placeholderContentRectForTesting(state: loupe.viewState, imageSize: nil)
        let aspect = rect.height / max(rect.width, 1e-9)
        print(String(format: "290 orientation only · rect %.2f×%.2f · h/w %.4f"
                     + " · upright %.4f · stored %.4f",
                     rect.width, rect.height, aspect, uprightAspect, storedAspect))

        XCTAssertEqual(aspect, uprightAspect, accuracy: 0.02,
                       "290 已记录的 EXIF 方向没有交换目录里的宽高")
        XCTAssertGreaterThan(abs(aspect - storedAspect), 0.02,
                             "290 reverse gate: the raw stored dimensions passed as upright")
    }

    /// Orientation unknown (no metadata row): the thumbnail is the upright authority. The stored pair
    /// is landscape, the thumbnail is portrait, so the fallback must swap — and keep the stored
    /// magnitude (100 % / 400 % use the file's pixel scale, not the preview's).
    func testUnknownOrientationUsesTheUprightThumbnailAspect() throws {
        let (loupe, session, _) = try makeLoupe(orientation: nil, thumbnail: (640, 960))
        XCTAssertNil(session.ingestedSourceFrame, "the test is not before ingest")

        loupe.zoom(to: 1.0)
        loupe.scheduleRender()
        XCTAssertTrue(loupe.firstFramePlaceholderVisible, "the stand-in did not install")

        let rect = loupe.placeholderRectForTesting
        let aspect = rect.height / max(rect.width, 1e-9)
        let scale = max(1, loupe.backingScale)
        print(String(format: "290 unknown orientation · stand-in %.2f×%.2f · h/w %.4f"
                     + " · upright %.4f · stored %.4f",
                     rect.width, rect.height, aspect, uprightAspect, storedAspect))

        XCTAssertEqual(aspect, uprightAspect, accuracy: 0.02,
                       "290 缩略图已摆正，未知方向时应以它的宽高比为准")
        XCTAssertEqual(rect.height, Double(upright.height) / scale, accuracy: 1,
                       "290 回退把缩略图的像素当成了 S1，100% 失去了文件尺度")
        XCTAssertGreaterThan(abs(aspect - storedAspect), 0.02,
                             "290 reverse gate: the raw stored dimensions passed as upright")
    }

    /// The hand-off: `publishIngestedSource` lands while the stand-in is still up, and the stand-in
    /// moves onto the real upright frame through the same resize path — without jumping.
    func testIngestKeepsThePlaceholderRect() throws {
        let (loupe, session, _) = try makeLoupe(orientation: 6, thumbnail: (640, 960))
        loupe.zoom(to: 1.0)
        loupe.scheduleRender()
        XCTAssertTrue(loupe.firstFramePlaceholderVisible, "the stand-in did not install")
        let before = loupe.placeholderRectForTesting

        loupe.publishIngestedSourceForTesting(rung: upright, decodeScale: 1)
        XCTAssertEqual(session.ingestedSourceFrame?.assetID, session.anchorAsset?.id)
        let after = loupe.placeholderRectForTesting
        print(String(format: "290 ingest · before %.2f,%.2f %.2f×%.2f"
                     + " · after %.2f,%.2f %.2f×%.2f",
                     before.minX, before.minY, before.width, before.height,
                     after.minX, after.minY, after.width, after.height))

        XCTAssertEqual(after.minX, before.minX, accuracy: 0.5, "290 ingest moved the stand-in left")
        XCTAssertEqual(after.minY, before.minY, accuracy: 0.5, "290 ingest moved the stand-in up")
        XCTAssertEqual(after.width, before.width, accuracy: 0.5, "290 ingest changed the stand-in width")
        XCTAssertEqual(after.height, before.height, accuracy: 0.5,
                       "290 ingest changed the stand-in height")
    }

    // MARK: - fixtures

    private func makeLoupe(orientation: Int?,
                           thumbnail: (width: Int, height: Int))
        throws -> (LoupeController, CatalogSession, Asset) {
        let library = try CropUITestSupport.makeLibrary(in: workDir,
                                                        width: stored.width,
                                                        height: stored.height)
        if let orientation {
            try library.catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO asset_metadata (asset_id, orientation) VALUES (?, ?)
                    """, arguments: [library.assetID, orientation])
            }
        }

        let session = CatalogSession()
        try session.open(library.package)
        session.selectOnly(library.assetID)
        session.mode = .loupe
        session.loadEditForAnchor()

        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        loupe.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        loupe.canvasView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.02)

        let deadline = Date().addingTimeInterval(5)
        while loupe.framing() == nil, Date() < deadline { CropUITestSupport.pump(0.01) }
        XCTAssertNotNil(loupe.framing(), "no projection: mode=\(session.mode)")

        let cache = try XCTUnwrap(session.thumbnailCache)
        try seedPreview(library.asset, cache: cache,
                        width: thumbnail.width, height: thumbnail.height)
        keepAlive.append(session)
        return (loupe, session, library.asset)
    }

    /// The same legacy preview key the stand-in reads first (`coldstart`'s fixture helper).
    private func seedPreview(_ asset: Asset, cache: ThumbnailCache,
                             width: Int, height: Int) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.72, green: 0.45, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        let tier = ThumbnailProvider.effectiveTier(requested: .t1024, ext: asset.ext).tier
        try cache.store(data, for: .preview(contentHash: asset.contentHash, tier: tier))
    }
}
