import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 132 §9/§10 — the crop workspace's framing: **普通 fit × 0.90**, one zoom for ±6°, one whole-canvas
/// re-fit beyond it, and the ordinary fit back on exit.
@MainActor
final class CropWorkspaceFitTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-fit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    func testSmallAnglesKeepOneZoomAtNinetyPercentOfTheOrdinaryFit() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        // The ordinary fit is measured with the tool off — the denominator §10 11 names.
        loupe.zoomToFit()
        CropUITestSupport.pump(0.05)
        let ordinaryFit = try XCTUnwrap(loupe.framing()).fitZoom
        XCTAssertEqual(loupe.effectiveZoom, ordinaryFit, accuracy: 1e-9)

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        CropUITestSupport.pump(0.05)
        let cropFit = loupe.effectiveZoom
        XCTAssertEqual(cropFit / ordinaryFit, CropWorkspaceFitTests.ninetyPercent,
                       accuracy: 0.01, "裁切 fit must be ordinary fit × 0.90")

        var samples: [(Double, Double)] = []
        for angle in [-5.0, -3, 0, 3, 5] {
            loupe.cropTool.setStraighten(angle)
            loupe.refreshCropTool()
            CropUITestSupport.pump(0.01)
            samples.append((angle, loupe.effectiveZoom))
        }
        for (angle, zoom) in samples {
            XCTAssertEqual(zoom / ordinaryFit, CropWorkspaceFitTests.ninetyPercent, accuracy: 0.01,
                           "\(angle)° changed the zoom — the drag must not jump")
        }
        XCTAssertEqual(Set(samples.map { ($0.1 * 1e9).rounded() }).count, 1,
                       "the five samples are not one number: \(samples.map(\.1))")

        // Leaving the workspace restores the ordinary fit (the entry camera, un-scaled).
        loupe.cancelCropTool()
        CropUITestSupport.pump(0.05)
        XCTAssertFalse(loupe.isCropToolActive)
        XCTAssertEqual(loupe.effectiveZoom, ordinaryFit, accuracy: 1e-9,
                       "退出裁切 must return to the ordinary fit")
        print(String(format: "132 §10 · ordinary fit %.6f · crop fit %.6f · ratio %.4f · samples %@",
                     ordinaryFit, cropFit, cropFit / ordinaryFit,
                     samples.map { String(format: "%.6f", $0.1) }.joined(separator: ", ")))
    }

    func testFortyFiveRefitsTheWholeCanvasWithoutChangingTheCrop() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session
        loupe.zoomToFit()
        CropUITestSupport.pump(0.05)
        let ordinaryFit = try XCTUnwrap(loupe.framing()).fitZoom

        XCTAssertTrue(loupe.beginCropTool(), "裁切 mode did not open")
        CropUITestSupport.pump(0.05)
        let fullCrop = loupe.cropTool.draft.crop
        let cropFit = loupe.effectiveZoom

        loupe.cropTool.setStraighten(45)
        XCTAssertTrue(loupe.cropTool.commitStraighten(), "45° must be written")
        CropUITestSupport.pump(0.05)

        // The committed document is the source of truth; the projection is read from it (the
        // headless harness drops the tool when the commit bumps the revision, which does not change
        // the camera numbers).
        let document = session.edit.geometry
        XCTAssertEqual(document.straightenDegrees, 45, accuracy: 1e-9)
        let framing = try XCTUnwrap(loupe.framing(), "no projection after the commit")
        let refit = framing.zoom(of: loupe.viewState)
        let aabb = framing.rotatedCropExtent
        let aabbFit = min(Double(framing.viewport.width) / aabb.width,
                          Double(framing.viewport.height) / aabb.height)
        XCTAssertEqual(refit, aabbFit, accuracy: 1e-6,
                       "45° must fit exactly the rotated canvas, no more")
        XCTAssertLessThan(refit, cropFit * 0.95,
                          "45° must re-fit the whole canvas once (the AABB no longer fits at 90 %)")
        XCTAssertGreaterThan(refit, ordinaryFit * 0.7,
                             "a 3:2 frame at 45° is ~0.85 of the ordinary fit, not 0.707")
        print(String(format: "132 §10 · 45° · ordinary %.6f · crop@0 %.6f · refit %.6f (%.4f/fit)",
                     ordinaryFit, cropFit, refit, refit / ordinaryFit))

        // ③ the **document** crop did not change — only the view multiplier.
        let stored = document.cropRect
        XCTAssertEqual(stored.width, fullCrop.width, accuracy: 1e-9)
        XCTAssertEqual(stored.height, fullCrop.height, accuracy: 1e-9)
        XCTAssertTrue(stored.coversFrame, "the full crop must stay full")

        // ①② one scale for picture and frame, and the whole canvas on screen.
        let mapping = framing.mapping(of: loupe.viewState)
        let layout = CropTool.layout(crop: document.renderCrop(source: loupe.cropSourceSize),
                                               source: loupe.cropSourceSize,
                                               mapping: mapping,
                                               pointScale: loupe.backingScale,
                                               quadRotationDegrees: 0)
        let frame = CropWorkspaceFitTests.bounds(layout.corners)
        let viewport = loupe.viewportPixels
        let scale = loupe.backingScale
        let canvas = NSRect(x: 0, y: 0, width: Double(viewport.width) / scale,
                            height: Double(viewport.height) / scale)
        XCTAssertGreaterThanOrEqual(frame.minX, canvas.minX - 1)
        XCTAssertGreaterThanOrEqual(frame.minY, canvas.minY - 1)
        XCTAssertLessThanOrEqual(frame.maxX, canvas.maxX + 1)
        XCTAssertLessThanOrEqual(frame.maxY, canvas.maxY + 1)

        let expectedWidth = Double(loupe.cropSourceSize.width) * mapping.canvasPerSource / scale
        XCTAssertEqual(Double(frame.width), expectedWidth, accuracy: 1.0,
                       "the frame and the picture are not at the same multiplier")
        print(String(format: "132 §10 12 · frame-edge vs picture-edge error %.3f px · crop %.4f×%.4f "
                     + "→ %.4f×%.4f (document)",
                     abs(Double(frame.width) - expectedWidth),
                     fullCrop.width, fullCrop.height, stored.width, stored.height))
        print(String(format: "132 §10 · 45° frame %.1f×%.1f pt · expected %.1f · canvas %.1f×%.1f pt",
                     Double(frame.width), Double(frame.height), expectedWidth,
                     Double(canvas.width), Double(canvas.height)))
    }

    private static let ninetyPercent = 0.90

    private static func bounds(_ corners: [CGPoint]) -> NSRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
