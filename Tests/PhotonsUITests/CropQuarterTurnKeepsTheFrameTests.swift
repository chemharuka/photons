import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 169 第 2 轮 — 「点击旋转后也会丢失裁剪框」 (用户 2026-10-30 18:24).
///
/// A 90° turn is a **document write** (`quarterTurns`), and the crop tool's rect is measured in the
/// turned frame. Whatever the command closes/reopens around that write, the frame the user was
/// looking at must still be there afterwards: visible, non-empty, on the canvas, and with the
/// aspect the new orientation calls for (the source's two numbers swap on every odd turn).
///
/// Both entry orders are pinned: the ordinary one (crop is up, then the user presses 旋转) and the
/// reported one (裁切 opens and the **first** thing the user does is press 旋转).
@MainActor
final class CropQuarterTurnKeepsTheFrameTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-quarter-turn-\(UUID().uuidString)",
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

    /// The source's aspect **for a given number of clockwise quarter turns**, written from the
    /// stored photo (`9520×6336`) instead of from `cropSourceSize`, so a tool that forgot the turn
    /// cannot make the expectation agree with its own mistake.
    private func expectedAspect(afterClockwiseTurns turns: Int) -> Double {
        let stored = CropUITestSupport.stored
        let w = Double(stored.width), h = Double(stored.height)
        return turns % 2 == 0 ? w / h : h / w
    }

    /// The one assertion set every turn has to satisfy. It reads the **view's** layout, not a
    /// recomputation, so a turn that forgot to re-project fails here.
    private func assertFrameSurvives(_ loupe: LoupeController, _ step: String,
                                     afterClockwiseTurns turns: Int) throws {
        XCTAssertTrue(loupe.isCropToolActive, "\(step): the 90° turn closed 裁切 mode")
        XCTAssertTrue(loupe.isCropOverlayOnScreenForTesting,
                      "\(step): the overlay is hidden or not on screen after the turn")

        let layout = try XCTUnwrap(loupe.cropOverlayLayoutForTesting,
                                   "\(step): the overlay is drawing nothing after the turn")
        XCTAssertEqual(layout.corners.count, 4, "\(step): the frame is not a quad")
        XCTAssertFalse(layout.isEmpty, "\(step): the frame is empty after the turn")

        let frame = bounds(layout.corners)
        let canvas = canvasRect(loupe)
        print(String(format: "169 quarter-turn · %@ · frame %@ · canvas %@ · source %dx%d",
                     step, NSStringFromRect(frame), NSStringFromRect(canvas),
                     loupe.cropSourceSize.width, loupe.cropSourceSize.height))

        XCTAssertGreaterThan(frame.width, 1, "\(step): the frame has no width")
        XCTAssertGreaterThan(frame.height, 1, "\(step): the frame has no height")
        XCTAssertGreaterThan(frame.width * frame.height, 0, "\(step): zero area")
        XCTAssertTrue(CropCanvasClamp.contains(frame, in: canvas, tolerance: 0.5),
                      "\(step): the frame left the canvas — \(frame) vs \(canvas)")

        // A clockwise quarter turn swaps the picture's two numbers: the frame must follow, not keep
        // the aspect it had before the press (and not collapse to the old orientation's bound).
        XCTAssertEqual(frame.width / frame.height, expectedAspect(afterClockwiseTurns: turns),
                       accuracy: 1e-6,
                       "\(step): the frame's aspect does not match the turned source")
    }

    /// The ordinary route: the frame is already up, then the user presses 旋转.
    func testTurningWithTheFrameUpKeepsItOnEveryQuarter() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        CropUITestSupport.pump(0.05)
        try assertFrameSurvives(loupe, "entry (0 presses)", afterClockwiseTurns: 0)

        for turn in 1...4 {
            XCTAssertTrue(loupe.rotateQuarter(clockwise: true),
                          "press \(turn): the 90° turn did not write the document")
            CropUITestSupport.pump(0.05)
            try assertFrameSurvives(loupe, "after press \(turn)",
                                    afterClockwiseTurns: turn)
        }
    }

    /// The reported scene: 裁切 opens and the **first** action is 旋转. No tick, no tab switch, no
    /// second entry — the very first command after the frame appears must not take it away.
    func testTurningImmediatelyAfterEnteringCropKeepsTheFrame() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session), "裁切 mode did not open")
        // Deliberately no settling pump here: the first action after entering is the turn.
        XCTAssertTrue(loupe.rotateQuarter(clockwise: true),
                      "the first action after entering 裁切 did not write the turn")
        CropUITestSupport.pump(0.05)
        try assertFrameSurvives(loupe, "first action = turn", afterClockwiseTurns: 1)

        for turn in 2...4 {
            XCTAssertTrue(loupe.rotateQuarter(clockwise: true),
                          "press \(turn): the 90° turn did not write the document")
            CropUITestSupport.pump(0.05)
            try assertFrameSurvives(loupe, "after press \(turn)",
                                    afterClockwiseTurns: turn)
        }
    }
}
