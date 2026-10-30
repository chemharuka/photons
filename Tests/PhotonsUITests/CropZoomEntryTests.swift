import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 162 §2.2 / G2 — **进入裁剪后画面与 90 % 框同步缩放，退出后恢复原来的缩放**.
///
/// The 132 workspace fit lived only in `LoupeFraming`'s `fitScale`, which the overlay and the zoom
/// readout read — but the renderer's own projection (`LoupeController.makeFrame` → `shot`) was built
/// without it, so the frame was drawn at 90 % while the pixels stayed at the ordinary fit. This suite
/// measures the **rendered picture rect** (`FrameResult.photoRect`), not just the camera number.
@MainActor
final class CropZoomEntryTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-zoom-entry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func bounds(_ corners: [CGPoint]) -> CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The user's exact complaint: after entering, the frame sits at 90 % but the picture is still the
    /// ordinary fit. The two rects must be one rect.
    func testEnteringScalesTheRenderedPictureWithTheDraftFrame() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        // The denominator: the ordinary fit, measured with the tool off.
        loupe.zoomToFit()
        CropUITestSupport.pump(0.05)
        let ordinaryFit = try XCTUnwrap(loupe.framing()).fitZoom

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        CropUITestSupport.pump(0.05)
        let inside = try XCTUnwrap(loupe.framing())
        let cropFit = inside.zoom(of: loupe.viewState)
        XCTAssertEqual(cropFit / ordinaryFit, 0.90, accuracy: 0.01,
                       "进入裁切: the camera must be the 90 % workspace fit")

        // The frame the overlay draws, in points.
        let layout = try XCTUnwrap(loupe.cropToolLayout())
        let frame = bounds(layout.corners)
        let scale = loupe.backingScale
        let viewport = loupe.viewportPixels
        let canvas = CGRect(x: 0, y: 0,
                            width: Double(viewport.width) / scale,
                            height: Double(viewport.height) / scale)
        XCTAssertEqual(frame.midX, canvas.midX, accuracy: 1, "the frame is not centred in the canvas")
        XCTAssertEqual(frame.midY, canvas.midY, accuracy: 1)

        // 5 % margin on the constraining axis — the frame occupies 90 % of the viewport.
        let horizontal = (canvas.width - frame.width) / canvas.width
        let vertical = (canvas.height - frame.height) / canvas.height
        print(String(format: "162 G2 · ordinary fit %.6f · crop fit %.6f · frame %.1f×%.1f pt "
                     + "· margins %.4f / %.4f · canvas %.0f×%.0f",
                     ordinaryFit, cropFit, Double(frame.width), Double(frame.height),
                     Double(horizontal), Double(vertical), Double(canvas.width), Double(canvas.height)))
        XCTAssertTrue(abs(horizontal - 0.10) < 0.01 || abs(vertical - 0.10) < 0.01,
                      "the frame does not sit at 90 % of the viewport (margins \(horizontal), \(vertical))")

        // The **rendered** picture, from a real frame of the fixture, in the same points.
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
                                "UI tests must run with PHOTONS_TEST_RAW")
        let frameResult = try loupe.makeFrame(url: URL(fileURLWithPath: raw),
                                              viewport: viewport, decodeScale: 0.5,
                                              edit: session.edit, state: loupe.viewState)
        let picture = CGRect(x: Double(frameResult.photoRect.x) / scale,
                             y: Double(frameResult.photoRect.y) / scale,
                             width: Double(frameResult.photoRect.width) / scale,
                             height: Double(frameResult.photoRect.height) / scale)
        print(String(format: "162 G2 · frame edges %@ · picture edges %@ · Δ %.2f/%.2f/%.2f/%.2f pt",
                     NSStringFromRect(frame), NSStringFromRect(picture),
                     abs(frame.minX - picture.minX), abs(frame.minY - picture.minY),
                     abs(frame.maxX - picture.maxX), abs(frame.maxY - picture.maxY)))
        XCTAssertEqual(frame.minX, picture.minX, accuracy: 1, "left edge: frame != rendered picture")
        XCTAssertEqual(frame.minY, picture.minY, accuracy: 1, "top edge: frame != rendered picture")
        XCTAssertEqual(frame.maxX, picture.maxX, accuracy: 1, "right edge: frame != rendered picture")
        XCTAssertEqual(frame.maxY, picture.maxY, accuracy: 1, "bottom edge: frame != rendered picture")

        // Leaving restores the camera the user had before entering — bit for bit.
        let entry = loupe.viewState
        loupe.cancelCropTool()
        CropUITestSupport.pump(0.05)
        XCTAssertFalse(loupe.isCropToolActive)
        XCTAssertEqual(loupe.viewState, entry, "退出裁切: the entry camera was not restored")
    }

    /// Entering from an actual stop (not fit) also returns to that exact stop on exit.
    func testLeavingRestoresAnActualZoomStopExactly() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        loupe.zoom(to: 0.25, aroundView: CGPoint(x: 450, y: 300))
        CropUITestSupport.pump(0.05)
        let entry = loupe.viewState
        XCTAssertTrue(entry.isActualSize)

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        CropUITestSupport.pump(0.05)
        XCTAssertEqual(loupe.viewState.mode, .fit, "进入裁切 goes to the workspace fit")
        loupe.cancelCropTool()
        CropUITestSupport.pump(0.05)
        XCTAssertEqual(loupe.viewState, entry, "退出裁切: same mode, zoom and centre")
        XCTAssertEqual(loupe.effectiveZoom, 0.25, accuracy: 1e-12)
    }
}
