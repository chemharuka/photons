import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 169 §2 — 「第一次拖动旋转，会丢失裁切框」.
///
/// The draft is `.full` when 裁切 opens. The very first `setStraighten(+2.5)` used to leave the
/// overlay drawing nothing (or a zero-area frame), and only a later tick — or leaving and re-entering
/// the workspace — brought it back. The frame must survive **every** tick: visible, non-empty, and
/// still on the canvas, with the crop stored in the draft untouched by a draft-angle write.
@MainActor
final class CropFirstStraightenDragTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-first-straighten-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func canvasRect(_ loupe: LoupeController) -> CGRect {
        let viewport = loupe.viewportPixels
        let scale = loupe.backingScale
        return CGRect(x: 0, y: 0,
                      width: Double(viewport.width) / scale,
                      height: Double(viewport.height) / scale)
    }

    private func bounds(_ corners: [CGPoint]) -> CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The one assertion set every tick has to satisfy. It reads the **view's** layout, not a
    /// recomputation, so a refresh that never reached the overlay fails here.
    private func assertFrameSurvives(_ loupe: LoupeController, _ step: String) throws {
        XCTAssertTrue(loupe.isCropToolActive, "\(step): the crop mode was dropped")
        XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting,
                      "\(step): the overlay is hidden or not on screen")

        let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting,
                                   "\(step): the overlay is drawing nothing")
        XCTAssertEqual(layout.corners.count, 4, "\(step): the frame is not a quad")
        XCTAssertFalse(layout.isEmpty, "\(step): the frame is empty")
        let frame = bounds(layout.corners)
        let canvas = canvasRect(loupe)
        print(String(format: "169 first-straighten · %@ · frame %@ · canvas %@",
                     step, NSStringFromRect(frame), NSStringFromRect(canvas)))

        XCTAssertGreaterThan(frame.width, 1, "\(step): the frame has no width")
        XCTAssertGreaterThan(frame.height, 1, "\(step): the frame has no height")
        XCTAssertGreaterThan(frame.width * frame.height, 0, "\(step): zero area")
        XCTAssertTrue(CropCanvasClamp.contains(frame, in: canvas, tolerance: 0.5),
                      "\(step): the frame left the canvas — \(frame) vs \(canvas)")

        // The pixel ratio is what the user drew; a straighten may change where the frame sits on
        // screen, never which pixels it keeps (until 应用). The draft still holds `.full` throughout.
        XCTAssertEqual(loupe.cropTool.draft.crop, .full,
                       "\(step): a draft-angle tick rewrote the crop rect")
    }

    func testTheFirstStraightenTickKeepsTheFullFrameOnScreen() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        CropUITestSupport.pump(0.05)
        XCTAssertEqual(loupe.cropTool.draft.crop, .full,
                       "entering 裁切 must seed the draft from the untouched document")

        let initial = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        XCTAssertEqual(initial.corners.count, 4)

        // The reported gesture: the **first** tick of the angle slider, +2.5°.
        loupe.cropTool.setStraighten(2.5)
        CropUITestSupport.pump(0.01)
        try assertFrameSurvives(loupe, "first tick +2.5°")

        // Five more ticks of the same gesture, including the reset-to-zero and the far end.
        for (index, angle) in [5.0, 7.5, 10.0, -2.5, 0.0].enumerated() {
            loupe.cropTool.setStraighten(angle)
            CropUITestSupport.pump(0.01)
            try assertFrameSurvives(loupe, "tick \(index + 2) \(String(format: "%+.1f", angle))°")
        }
    }

    /// The same claim through the document commit that a mouse-up makes: one angle write per gesture
    /// must not take the frame away either.
    func testCommittingTheFirstStraightenKeepsTheFrame() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)

        loupe.cropTool.setStraighten(2.5)
        XCTAssertTrue(loupe.cropTool.commitStraighten(), "the first release must write its row")
        CropUITestSupport.pump(0.05)
        try assertFrameSurvives(loupe, "commit +2.5°")
    }
}
