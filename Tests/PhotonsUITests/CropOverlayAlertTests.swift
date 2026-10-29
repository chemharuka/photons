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

    /// 132 §3 3 — a frame dragged 10 % past the right edge is **applied as-is**: one commit, one
    /// history row, and the stored rect keeps its width and its right edge outside 1.
    func testAFrameOutsideThePictureIsAppliedWithoutSnappingBack() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)

        let outside = CropRect(x: 0.5, y: 0.2, width: 0.6, height: 0.6)   // right = 1.1
        loupe.cropTool.draft.crop = outside
        loupe.refreshCropTool()
        XCTAssertEqual(loupe.cropTool.effectiveCrop().right, 1.1, accuracy: 1e-9,
                       "the model must not pull the frame back")
        let history = session.history.snapshots.count
        let revision = session.editRevision
        XCTAssertTrue(loupe.applyCropTool(), "应用 must commit the frame where it is")
        XCTAssertEqual(session.history.snapshots.count, history + 1, "one apply = one history row")
        XCTAssertEqual(session.editRevision, revision + 1)
        let stored = session.edit.geometry.cropRect
        XCTAssertEqual(stored.right, 1.1, accuracy: 1e-9, "the outside edge was clamped")
        XCTAssertEqual(stored.width, 0.6, accuracy: 1e-9, "the width moved")
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
}
