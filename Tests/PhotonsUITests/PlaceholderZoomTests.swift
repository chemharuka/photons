import XCTest
import AppKit
import CoreGraphics
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 283 — the first-frame stand-in must use the **photograph's** S5 rectangle, not the camera window.
///
/// Before this, `firstFramePlaceholderContentRect` took `contentPixels` (which is `viewport ÷ zoom ×
/// zoom`, i.e. always the viewport) and then clamped it to the canvas. Two consequences the user
/// reported:
///
///   · at 12.5 % / 400 % the stand-in was the **whole window** (the full thumbnail, or a full-bleed
///     stretch of it) and the real frame then jumped to the small picture or the magnified detail;
///   · a portrait under 适应 went through the `min(canvas, …)` / fallback path with the canvas' shape,
///     so it occupied the space of a landscape photo.
///
/// The acceptance is the eight-cell table: fit / 12.5 % / 100 % / 400 % × landscape / portrait. The
/// expected rectangle is rebuilt here from the projection's own public `viewPoint` exit (the crop's
/// four corners), so "placeholder == real frame content" is a comparison of two paths, not of a
/// function with itself. Non-fit cells are allowed — expected — to leave the canvas.
@MainActor
final class PlaceholderZoomTests: XCTestCase {

    private var workDir: URL!
    /// The controller holds its session weakly; keep the session alive for the whole test.
    private var keepAlive: [AnyObject] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-placeholder-zoom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        keepAlive.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - the eight cells

    func testPlaceholderRectMatchesThePhotoCornersInEightCells() throws {
        let zooms: [(name: String, value: Double?)] = [
            ("适应", nil), ("12.5%", 0.125), ("100%", 1.0), ("400%", 4.0),
        ]

        for portrait in [false, true] {
            let (loupe, session) = try makeLoupe()
            if portrait {
                session.applyEdit { $0.geometry.quarterTurns = 1 }
                CropUITestSupport.pump(0.02)
            }
            let framing = try XCTUnwrap(loupe.framing(), "no projection")
            let scale = max(1, loupe.backingScale)
            let canvas = loupe.canvasView.bounds.size
            let sourceAspect = (framing.crop.height * framing.sourceHeight)
                / max(framing.crop.width * framing.sourceWidth, 1e-9)

            for zoom in zooms {
                if let value = zoom.value { loupe.zoom(to: value) } else { loupe.zoomToFit() }
                let state = loupe.viewState
                let rect = loupe.placeholderContentRectForTesting(state: state)
                let expected = photoRect(framing, state: state, backingScale: scale)
                print(String(format: "283 %@ %@ · state %@ %.4g · rect %.2f,%.2f %.2f×%.2f"
                             + " · expected %.2f,%.2f %.2f×%.2f · canvas %.0f×%.0f",
                             portrait ? "portrait" : "landscape", zoom.name,
                             state.mode == .fit ? "fit" : "actual", state.zoom,
                             rect.minX, rect.minY, rect.width, rect.height,
                             expected.minX, expected.minY, expected.width, expected.height,
                             canvas.width, canvas.height))

                XCTAssertEqual(rect.minX, expected.minX, accuracy: 0.5,
                               "283 \(portrait ? "竖幅" : "横幅") \(zoom.name): left edge")
                XCTAssertEqual(rect.minY, expected.minY, accuracy: 0.5,
                               "283 \(portrait ? "竖幅" : "横幅") \(zoom.name): top edge")
                XCTAssertEqual(rect.width, expected.width, accuracy: 0.5,
                               "283 \(portrait ? "竖幅" : "横幅") \(zoom.name): width")
                XCTAssertEqual(rect.height, expected.height, accuracy: 0.5,
                               "283 \(portrait ? "竖幅" : "横幅") \(zoom.name): height")

                if expected.width >= canvas.width {
                    XCTAssertGreaterThanOrEqual(rect.width, canvas.width - 0.5,
                                                "283 \(zoom.name) was clamped to the canvas width")
                }
                if expected.height >= canvas.height {
                    XCTAssertGreaterThanOrEqual(rect.height, canvas.height - 0.5,
                                                "283 \(zoom.name) was clamped to the canvas height")
                }
                if portrait {
                    XCTAssertEqual(rect.height / max(rect.width, 1e-9), sourceAspect, accuracy: 0.02,
                                   "283 竖幅 \(zoom.name) collapsed to a landscape-shaped rect")
                }
            }
        }
    }

    // MARK: - the shipped install path

    /// The property the switch/cold-start tests read is the same rectangle the seam computes, and a
    /// non-fit cell really leaves the canvas instead of being clamped.
    func testNonFitStandInInstallsTheUnclampedPhotoRect() throws {
        let (loupe, session) = try makeLoupe()
        let asset = try XCTUnwrap(session.anchorAsset)
        try seedPreview(asset, cache: try XCTUnwrap(session.thumbnailCache))

        loupe.zoom(to: 4.0)
        XCTAssertEqual(loupe.viewState.zoom, 4.0, accuracy: 1e-9)
        loupe.scheduleRender()

        XCTAssertTrue(loupe.firstFramePlaceholderVisible,
                      "a warm 400 % switch did not install the stand-in synchronously")
        let installed = loupe.placeholderRectForTesting
        let expected = loupe.placeholderContentRectForTesting(state: loupe.viewState)
        let canvas = loupe.canvasView.bounds.size
        print(String(format: "283 install 400%% · installed %.2f,%.2f %.2f×%.2f"
                     + " · expected %.2f,%.2f %.2f×%.2f · canvas %.0f×%.0f",
                     installed.minX, installed.minY, installed.width, installed.height,
                     expected.minX, expected.minY, expected.width, expected.height,
                     canvas.width, canvas.height))

        XCTAssertEqual(installed.minX, expected.minX, accuracy: 0.5)
        XCTAssertEqual(installed.minY, expected.minY, accuracy: 0.5)
        XCTAssertEqual(installed.width, expected.width, accuracy: 0.5)
        XCTAssertEqual(installed.height, expected.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(installed.width, canvas.width,
                                    "400 % must not be clamped to the window")
        XCTAssertGreaterThanOrEqual(installed.height, canvas.height,
                                    "400 % must not be clamped to the window")
    }

    /// 适应 + 竖幅: the stand-in occupies the portrait's own rectangle, not a landscape's.
    func testFitPortraitStandInKeepsThePhotoAspect() throws {
        let (loupe, session) = try makeLoupe()
        session.applyEdit { $0.geometry.quarterTurns = 1 }
        CropUITestSupport.pump(0.02)
        let asset = try XCTUnwrap(session.anchorAsset)
        try seedPreview(asset, cache: try XCTUnwrap(session.thumbnailCache))

        loupe.zoomToFit()
        loupe.scheduleRender()
        XCTAssertTrue(loupe.firstFramePlaceholderVisible, "the fit stand-in did not install")

        let framing = try XCTUnwrap(loupe.framing())
        let rect = loupe.placeholderRectForTesting
        let photoAspect = (framing.crop.height * framing.sourceHeight)
            / max(framing.crop.width * framing.sourceWidth, 1e-9)
        print(String(format: "283 portrait fit · stand-in %.2f,%.2f %.2f×%.2f · aspect %.4f"
                     + " · photo aspect %.4f · canvas %.0f×%.0f",
                     rect.minX, rect.minY, rect.width, rect.height,
                     rect.height / max(rect.width, 1e-9), photoAspect,
                     loupe.canvasView.bounds.width, loupe.canvasView.bounds.height))

        XCTAssertEqual(rect.height / max(rect.width, 1e-9), photoAspect, accuracy: 0.02,
                       "283 竖幅 适应 still occupies a landscape-shaped rectangle")
    }

    /// 适应 + 竖幅 **without** a projection (the switch before any asset dimensions/decode): the
    /// thumbnail itself is the layout's S1, and a canvas resize must keep its aspect instead of
    /// falling back to the canvas' landscape shape.
    func testFitPortraitFallbackSurvivesACanvasResize() throws {
        let (loupe, session) = try makeLoupe(width: nil, height: nil, requiresFraming: false)
        XCTAssertNil(loupe.framing(), "this fixture must have no projection")
        let asset = try XCTUnwrap(session.anchorAsset)
        try seedPreview(asset, cache: try XCTUnwrap(session.thumbnailCache),
                        width: 640, height: 960)

        loupe.zoomToFit()
        loupe.scheduleRender()
        XCTAssertTrue(loupe.firstFramePlaceholderVisible, "the fallback stand-in did not install")
        let installed = loupe.placeholderRectForTesting
        XCTAssertEqual(installed.height / max(installed.width, 1e-9), 1.5, accuracy: 0.02,
                       "the portrait thumbnail did not keep its aspect")

        loupe.canvasView.frame = NSRect(x: 0, y: 0, width: 900, height: 300)
        loupe.viewDidLayout()
        let resized = loupe.placeholderRectForTesting
        print(String(format: "283 portrait fallback · installed %.2f×%.2f · after resize %.2f×%.2f"
                     + " · aspect %.4f",
                     installed.width, installed.height, resized.width, resized.height,
                     resized.height / max(resized.width, 1e-9)))
        XCTAssertEqual(resized.height / max(resized.width, 1e-9), 1.5, accuracy: 0.02,
                       "283 竖幅 fallback collapsed to the canvas shape after a resize")
    }

    // MARK: - fixtures

    private func makeLoupe(width: Int? = CropUITestSupport.stored.width,
                           height: Int? = CropUITestSupport.stored.height,
                           requiresFraming: Bool = true) throws -> (LoupeController, CatalogSession) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir, width: width, height: height)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        loupe.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        loupe.canvasView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        loupe.view.layoutSubtreeIfNeeded()
        CropUITestSupport.pump(0.02)

        let deadline = Date().addingTimeInterval(5)
        while loupe.framing() == nil, Date() < deadline { CropUITestSupport.pump(0.01) }
        if requiresFraming {
            XCTAssertNotNil(loupe.framing(), "no projection: mode=\(session.mode)")
        }
        keepAlive.append(session)
        return (loupe, session)
    }

    /// The crop's four corners through the projection's public exit, in canvas points. This is the
    /// photograph's rectangle the real frame is rendered into.
    private func photoRect(_ framing: LoupeFraming, state: LoupeViewState,
                           backingScale: Double) -> CGRect {
        let w = framing.sourceWidth, h = framing.sourceHeight
        let crop = framing.crop
        let corners = [(crop.left * w, crop.top * h), (crop.right * w, crop.top * h),
                       (crop.right * w, crop.bottom * h), (crop.left * w, crop.bottom * h)]
            .map { framing.viewPoint(of: state, sourceX: $0.0, sourceY: $0.1,
                                     backingScale: backingScale) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func seedPreview(_ asset: Asset, cache: ThumbnailCache,
                             width: Int = 640, height: Int = 427) throws {
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
