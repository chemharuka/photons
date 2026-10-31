import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 132 §8/§10 4 — the first angle change keeps the frame on screen (never a 0.001 dot), and a frame
/// that covers pixels outside the photograph is drawn **red** — a colour, never an edit.
@MainActor
final class CropOverlayAlertTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-alert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func frameBounds(_ layout: CropToolLayout) -> NSRect {
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    func testTheFirstAngleChangeKeepsTheFrameAndTurnsItRedOutsideThePicture() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)

        let start = try XCTUnwrap(loupe.cropOverlayLayoutForTesting, "no frame at 0°")
        XCTAssertFalse(start.exceedsPicture, "0° full frame has no empty pixels → not red")
        XCTAssertEqual(loupe.cropTool.draft.crop, .full)

        let history = session.history.snapshots.count
        let revision = session.editRevision

        // The report: 「第一次修改旋转，会丢失裁切框」. The draft is untouched (full), the overlay is
        // still drawn, and its four corners are a real quad — not the 0.001 floor.
        loupe.cropTool.setStraighten(5)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.05)
        let atFive = try XCTUnwrap(loupe.cropOverlayLayoutForTesting, "5° made the frame disappear")
        let bounds = frameBounds(atFive)
        let canvas = NSRect(x: 0, y: 0,
                            width: Double(loupe.viewportPixels.width) / loupe.backingScale,
                            height: Double(loupe.viewportPixels.height) / loupe.backingScale)
        XCTAssertGreaterThan(bounds.width, canvas.width * 0.5, "the frame collapsed: \(bounds)")
        XCTAssertGreaterThan(bounds.height, canvas.height * 0.5, "the frame collapsed: \(bounds)")
        XCTAssertEqual(loupe.cropTool.draft.crop.width, 1, accuracy: 1e-9,
                       "an angle tick must not shrink the document rect")
        print(String(format: "132 §4 · 0° frame %.1f×%.1f → 5° frame %.1f×%.1f pt",
                     Double(frameBounds(start).width), Double(frameBounds(start).height),
                     Double(bounds.width), Double(bounds.height)))

        // Back to 0° is the full frame again.
        loupe.cropTool.setStraighten(0)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)
        let back = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        XCTAssertEqual(back.corners.count, 4)
        XCTAssertEqual(loupe.cropTool.draft.crop, .full)

        // At 45° the full frame covers the rotated-out pixels → red; a 0.6× centred frame does not.
        loupe.cropTool.setStraighten(45)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)
        let at45 = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        XCTAssertTrue(at45.exceedsPicture, "full frame at 45° must be red")
        // 3:2 at 45°: 0.6× is still outside the rotated sensor (its rotated support is
        // (0.6·(W+H)/2)·√2/2 > H/2), so the fixture's "fully inside" example is 0.5×. The rule is
        // the same and the core test pins the spec's square 0.6× case.
        loupe.cropTool.draft.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)
        let inside = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        XCTAssertFalse(inside.exceedsPicture, "0.5× centred at 45° is inside the picture → not red")

        // A colour is not an edit.
        XCTAssertEqual(session.history.snapshots.count, history, "the red frame wrote a history row")
        XCTAssertEqual(session.editRevision, revision, "the red frame bumped editRevision")
        print("132 §8 · red at 45° \(at45.exceedsPicture) · 0.5× \(inside.exceedsPicture) · "
              + "history +\(session.history.snapshots.count - history) · revision +\(session.editRevision - revision)")
    }

    /// 132 §3 3 / 162 §2.3 — a frame dragged past the right edge of the **photograph** is applied
    /// as-is: one commit, one history row, and the stored rect keeps its width and its right edge
    /// outside 1. It stays inside the **canvas** (162): the old 1.1 example was outside the 90 %
    /// workspace's letterbox too (its hard bound is 1.0556), which is precisely what the user's third
    /// report forbids. 1.04 is outside the camera pixels and inside the canvas.
    func testAFrameOutsideThePictureIsAppliedWithoutSnappingBack() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)

        let outside = CropRect(x: 0.5, y: 0.2, width: 0.54, height: 0.6)   // right = 1.04
        loupe.cropTool.draft.crop = outside
        loupe.refreshCropTool()
        XCTAssertEqual(loupe.cropTool.effectiveCrop().right, 1.04, accuracy: 1e-9,
                       "the model must not pull the frame back onto the photograph")
        let history = session.history.snapshots.count
        let revision = session.editRevision
        XCTAssertTrue(loupe.applyCropTool(), "应用 must commit the frame where it is")
        XCTAssertEqual(session.history.snapshots.count, history + 1, "one apply = one history row")
        XCTAssertEqual(session.editRevision, revision + 1)
        let stored = session.edit.geometry.cropRect
        XCTAssertEqual(stored.right, 1.04, accuracy: 1e-9, "the outside edge was clamped")
        XCTAssertEqual(stored.width, 0.54, accuracy: 1e-9, "the width moved")
        print("132 §3 · stored crop r \(stored.right) w \(stored.width) · history +\(session.history.snapshots.count - history)")
    }

    /// The old ⑨ behaviour that used to hide the frame is still reachable through the flag, and it is
    /// the *clamp*, not the overlay, that moves the rect.
    func testTheOptInInscribedRectStillWorks() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        loupe.cropTool.clampsToRotatedFrame = true
        loupe.cropTool.setStraighten(9)
        let drawn = loupe.cropTool.effectiveCrop(source: loupe.cropSourceSize)
        XCTAssertTrue(CropMath.fitsInsideRotatedFrame(drawn, in: loupe.cropSourceSize, degrees: 9))
        XCTAssertLessThan(drawn.width, 0.95, "the opt-in rule must still inscribe")
        XCTAssertEqual(loupe.cropTool.draft.crop, .full, "the intent is still not written")
    }

    /// 196 — **the portrait hole**: `quarterTurns = 1` + 5.4°, where the frame *is* outside the
    /// photograph's turned support and has to go red.
    ///
    /// The user's report was 「裁剪框在此时理应出界但没有变为红色」. The two candidate causes were
    /// (a) the predicate reading the slider's angle while the overlay draws the quarter turn too, and
    /// (b) the predicate being dead. This pins the answer: the drawing angle is
    /// `quarterTurns·90 + straighten` *in display space*, while `sourceSize` is already the
    /// **turned** source and the predicate turns only by the straighten — the same rotation *relative
    /// to the photograph*, so both are the same number and the flag must be true here. If a later
    /// change adds the quarter turn to the predicate it double-counts and this test goes red.
    func testAPortraitDocumentGoesRedWhereTheFrameCoversTheRotatedOutCorner() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session
        // 竖拍：同一张照片转 90°,再直线 5.4°。
        session.applyEdit { $0.geometry.quarterTurns = 1 }
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)
        loupe.cropTool.setStraighten(5.4)
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)

        let history = session.history.snapshots.count
        let revision = session.editRevision
        let source = loupe.cropSourceSize
        print("196 red · quarterTurns \(session.edit.geometry.quarterTurns) "
              + "· straighten \(loupe.cropTool.draft.straighten) "
              + "· source \(source.keyString) "
              + "· document rotation \(session.edit.geometry.rotationDegrees)")

        // ① a frame covering the turned-out corner (the full frame at 5.4°) → red.
        loupe.cropTool.draft.crop = .full
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)
        let full = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        XCTAssertTrue(full.exceedsPicture, "portrait + 5.4°: the full frame covers the 000000 corner")
        XCTAssertTrue(loupe.cropTool.frameExceedsPicture(source: source, degrees: 5.4))

        // ② a small centred frame inside the photograph → not red.
        let insideCrop = CropRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        loupe.cropTool.draft.crop = insideCrop
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)
        let inside = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        XCTAssertFalse(inside.exceedsPicture, "a 0.4× centred frame at 5.4° is inside → not red")

        // ③ the warning is a colour: no rect change, no history, no revision bump.
        XCTAssertEqual(loupe.cropTool.draft.crop, insideCrop, "the alert moved the rect")
        XCTAssertEqual(session.history.snapshots.count, history, "the red frame wrote a history row")
        XCTAssertEqual(session.editRevision, revision, "the red frame bumped editRevision")
        print("196 red · full \(full.exceedsPicture) · 0.4× \(inside.exceedsPicture) "
              + "· history +\(session.history.snapshots.count - history) "
              + "· revision +\(session.editRevision - revision)")
    }

}
