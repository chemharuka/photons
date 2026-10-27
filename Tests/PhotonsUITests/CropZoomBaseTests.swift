import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 072 §A0 + §A1 — 缩放基底与确认裁切后的动画.
///
/// **A0** one invariant: the zoom base is the **whole source frame** (the upright frame S0 ingested,
/// before the crop). `fit` = whole frame fits the viewport, `1:1` = one source pixel per device pixel,
/// `2:1` = two — crop or no crop. The 「用裁切尺寸算」 value is computed next to it as the anti-proof.
///
/// **A1** confirming a crop returns the camera to the framing it had **before** the tool opened: same
/// rung, same pan, per-field equality, no auto-fit and no auto-centre — and the travel is an animation
/// (the loupe's stop-change bridge, forced on, because a crop change moves the picture's content as
/// well as its ratio), which is counted.
@MainActor
final class CropZoomBaseTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-zoom-base-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - A0

    /// 50 % crop of a 6000×4000 frame in a 2560×1600 viewport: three rungs, and the photo's rect on
    /// screen at each, against the value the crop-based formula would have produced.
    func testFitIsMeasuredOnTheWholeFrameWhateverTheCropIs() {
        let viewport = ImageSize(width: 2560, height: 1600)
        let source = (width: 6000.0, height: 4000.0)
        let half = CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)
        let f = LoupeFraming(viewport: viewport, sourceWidth: source.width, sourceHeight: source.height,
                             crop: half)
        XCTAssertEqual(f.cropWidthPixels, 3000, accuracy: 1e-9)
        XCTAssertEqual(f.cropHeightPixels, 2000, accuracy: 1e-9)

        // A0's rule, measured: 2560/6000 = 0.426667, 1600/4000 = 0.4 → 0.4 for *any* crop of this frame.
        XCTAssertEqual(f.fitZoom, 0.4, accuracy: 1e-12)
        // Anti-proof — the 「用裁切尺寸算」 value: min(2560/3000, 1600/2000) = 0.8, i.e. twice the scale.
        let wrong = min(Double(viewport.width) / f.cropWidthPixels,
                        Double(viewport.height) / f.cropHeightPixels)
        XCTAssertEqual(wrong, 0.8, accuracy: 1e-12)
        XCTAssertNotEqual(f.fitZoom, wrong, "§A0: the crop must not enter the zoom conversion")

        // The photo on screen, per rung: at fit it is the crop at `fitZoom`; at a numeric stop the
        // window is `viewport / zoom` **source** pixels drawn one device pixel per canvas pixel.
        let oneToOne = LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000)
        let twoToOne = LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2000)
        let fitContent = f.contentSize(of: .fit)
        let oneWindow = f.windowSize(of: oneToOne)
        let twoWindow = f.windowSize(of: twoToOne)
        print(String(format: "A0 · 50%% crop 6000×4000 in 2560×1600 · fit %.6f → %.0f×%.0f device px · "
                     + "1:1 window %.0f×%.0f src px (%.3f canvas px per src) · "
                     + "2:1 window %.0f×%.0f src px (%.3f)",
                     f.fitZoom, fitContent.width, fitContent.height,
                     oneWindow.width, oneWindow.height, f.mapping(of: oneToOne).canvasPerSource,
                     twoWindow.width, twoWindow.height, f.mapping(of: twoToOne).canvasPerSource))

        // fit: the crop covers half the viewport on each axis (the whole frame would fill it).
        XCTAssertEqual(fitContent.width, 2560 * 0.4 * 3000 / 2560, accuracy: 1e-9)
        XCTAssertEqual(fitContent.width, 1200, accuracy: 1e-9)
        XCTAssertEqual(fitContent.height, 800, accuracy: 1e-9)
        // 1:1: one source pixel per device pixel, whatever the crop is.
        XCTAssertEqual(oneWindow.width, 2560, accuracy: 1e-9)
        XCTAssertEqual(oneWindow.height, 1600, accuracy: 1e-9)
        XCTAssertEqual(f.mapping(of: oneToOne).canvasPerSource, 1, accuracy: 1e-12)
        // 2:1: half the source span for the same canvas.
        XCTAssertEqual(twoWindow.width, 1280, accuracy: 1e-9)
        XCTAssertEqual(f.mapping(of: twoToOne).canvasPerSource, 2, accuracy: 1e-12)
        // The ratio between two rungs is the rung ratio, not a crop-dependent number.
        XCTAssertEqual(oneWindow.width / twoWindow.width, 2, accuracy: 1e-12)

        // …and a *different* crop of the same frame keeps the same three ratios (the invariant).
        let thin = LoupeFraming(viewport: viewport, sourceWidth: source.width, sourceHeight: source.height,
                                crop: CropRect(left: 0.1, top: 0.4, right: 0.4, bottom: 0.6))
        XCTAssertEqual(thin.fitZoom, f.fitZoom, accuracy: 1e-12,
                       "§A0: fit does not depend on the crop rect")
    }

    /// The mapping the canvas actually draws with puts a source pixel on one device pixel at 1:1, for a
    /// cropped and an uncropped document alike.
    func testOneToOneIsOneSourcePixelPerDevicePixelWithACrop() {
        let viewport = ImageSize(width: 2560, height: 1600)
        for crop in [CropRect.full, CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)] {
            let f = LoupeFraming(viewport: viewport, sourceWidth: 6000, sourceHeight: 4000, crop: crop)
            let state = LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000)
            let map = f.mapping(of: state)
            let a = map.sourcePoint(viewX: 100, viewY: 100)
            let b = map.sourcePoint(viewX: 101, viewY: 100)
            XCTAssertEqual(b.x - a.x, 1, accuracy: 1e-9, "crop \(crop.keyString): 1 px = 1 source px")
            XCTAssertEqual(b.y - a.y, 0, accuracy: 1e-9)
            XCTAssertEqual(map.canvasPerSource, 1, accuracy: 1e-12)
        }
    }

    // MARK: - A1

    /// 确认裁切 → the camera lands **exactly** on the entry framing, and the change is animated.
    /// Three rungs: fit, 25 %, 1:1.
    func testConfirmingACropRestoresTheEntryFramingExactly() throws {
        for rung in ["fit", "25%", "1:1"] {
            let (session, _) = try CropUITestSupport.makeSession(in: workDir)
            let loupe = LoupeController(session: session)
            loupe.autoRenderEnabled = false
            loupe.collectsHistogram = false
            loupe.canvasView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

            // The framing the user had *before* ⌘R.
            switch rung {
            case "25%": loupe.zoom(to: 0.25, aroundView: CGPoint(x: 450, y: 300))
            case "1:1": loupe.zoom(to: 1, aroundView: CGPoint(x: 450, y: 300))
            default: loupe.zoomToFit()
            }
            let entry = loupe.viewState

            XCTAssertTrue(loupe.beginCropTool(), "\(rung): the tool opened")
            // Entering forces fit (the whole picture has to be visible to be cropped) — and the entry
            // camera is remembered, not lost.
            let inside = loupe.viewState
            XCTAssertEqual(inside.mode, .fit, "\(rung): 进入裁切 goes to fit")

            // A real edit, then 应用.
            loupe.cropTool.setAspect(.square)
            let animationsBefore = loupe.cropExitAnimations
            let decodesBefore = loupe.decodeRequests
            XCTAssertTrue(loupe.applyCropTool(), "\(rung): one apply, one snapshot")
            // A1's «无新增解码»: geometry is not a decode input (`DecodeInputs`), so leaving the tool
            // asks for a *render* and never for a development.
            XCTAssertEqual(loupe.decodeRequests, decodesBefore, "\(rung): the exit asked for no decode")

            let after = loupe.viewState
            let deltaZoom = abs(after.zoom - entry.zoom)
            let deltaX = abs(after.centerX - entry.centerX)
            let deltaY = abs(after.centerY - entry.centerY)
            print(String(format: "A1 · %@: entry %@ · leaving %@ · after %@ · Δzoom %.9f Δx %.9f Δy %.9f "
                         + "· animations +%d",
                         rung, entry.zoomLabel, inside.zoomLabel, after.zoomLabel,
                         deltaZoom, deltaX, deltaY, loupe.cropExitAnimations - animationsBefore))

            XCTAssertEqual(after, entry, "§A1: 终点逐值相等 (same mode, zoom, centre)")
            XCTAssertEqual(deltaZoom, 0)
            XCTAssertEqual(deltaX, 0)
            XCTAssertEqual(deltaY, 0)
            XCTAssertFalse(after.isActualSize && entry.isActualSize && after.zoom != entry.zoom,
                           "no auto-fit / auto-centre on the way out")
            if entry == inside {
                XCTAssertEqual(loupe.cropExitAnimations, animationsBefore,
                               "\(rung): entering and leaving are the same framing, so there is nothing to animate")
            } else {
                XCTAssertEqual(loupe.cropExitAnimations, animationsBefore + 1,
                               "§A1: the return is an animation, not a cut")
            }
            // The crop really was committed, so the camera restore is not hiding a no-op.
            XCTAssertFalse(session.edit.geometry.cropRect.isFull, "\(rung): the crop is in the document")
        }
    }

    /// 取消 does the same restore, and writes nothing.
    func testCancellingAlsoReturnsToTheEntryFraming() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        loupe.canvasView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        loupe.zoom(to: 2, aroundView: CGPoint(x: 450, y: 300))
        let entry = loupe.viewState
        let bytes = CropUITestSupport.documentBytes(session)

        XCTAssertTrue(loupe.beginCropTool())
        loupe.cropTool.setStraighten(6)
        loupe.cancelCropTool()
        print("A1 · cancel: entry \(entry.zoomLabel) → after \(loupe.viewState.zoomLabel), "
              + "Δ \(abs(loupe.viewState.zoom - entry.zoom))")
        XCTAssertEqual(loupe.viewState, entry)
        XCTAssertEqual(CropUITestSupport.documentBytes(session), bytes, "Esc writes nothing")
    }
}
