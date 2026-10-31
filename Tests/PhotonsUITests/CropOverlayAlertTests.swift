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

    /// 197 ② — 用户的顺序：**裁剪 → ↵应用 → 再进裁切 → 缩到 25 % → 把框拖去盖住旋转空角**。
    ///
    /// 196 证伪了「角度差一个 quarterTurns」这个假设（`geometry.rotationDegrees` 在竖拍下就是
    /// 0.0），可用户的「红色越界不变红」仍然成立 —— 因为 ① 让画布只剩裁切区：覆盖层是按**裁剪后的
    /// 照片**投影的，框在屏幕上盖住的「空角」在源坐标里根本不是照片外。① 修好之后，覆盖层的映射
    /// 与帧 job 是同一个文档，这条断言才第一次有意义。
    func testAFrameOverTheLetterboxIsRedAfterReenteringCropOnACroppedDocument() throws {
        let editor = try CropUITestSupport.makeEditor(in: workDir)
        defer { editor.window?.close() }
        let loupe = editor.rootView.loupeController
        let session = editor.session

        // 裁剪 + 拉直，一次应用。
        let applied = CropRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)
        loupe.cropTool.draft.crop = applied
        loupe.cropTool.setStraighten(5.4)
        loupe.refreshCropTool()
        XCTAssertTrue(loupe.applyCropTool(), "应用 did not commit 裁剪 + 拉直")
        CropUITestSupport.pump(0.05)
        XCTAssertEqual(session.edit.geometry.cropRect.width, applied.width, accuracy: 1e-9)

        // 再进裁切，缩到 25 %。
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        CropUITestSupport.pump(0.05)

        // 用户的取景：缩到 25 %。这个窗口里 25 % 的画布（10075 px × 0.25 = 2518）比视口（2044）还
        // 宽，旋转空角根本不在屏幕上，而 ⑦ 会把框 clamp 进可见画布 —— 那一档「盖住黑角」这件事不
        // 存在，框落在哪里取决于镜头中心（两次跑出来一个在照片内、一个出界），不能当判据。所以
        // 25 % 只打印，判据取「整块画布可见」的取景（`zoomToFit`，即用户眼睛看到四个空角的那一屏）。
        loupe.zoom(to: 0.25)
        CropUITestSupport.pump(0.05)
        let source = loupe.cropSourceSize
        let framing = try XCTUnwrap(loupe.framing())
        let viewport = loupe.viewportPixels
        let canvas = CropMath.canvasSize(crop: framing.crop, in: source,
                                         straightenDegrees: framing.straightenDegrees,
                                         quarterTurns: session.edit.geometry.quarterTurns,
                                         allowsOutsideSource: true)
        let canvasRect = ImageRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        func fits(_ zoom: Double) -> Bool {
            Double(canvas.width) * zoom <= Double(viewport.width) + 0.5
                && Double(canvas.height) * zoom <= Double(viewport.height) + 0.5
        }
        print("197 ② · 25 % · effectiveZoom \(loupe.effectiveZoom) · 画布整块可见 "
              + "\(fits(loupe.effectiveZoom)) (canvas×z "
              + "\(Int(Double(canvas.width) * loupe.effectiveZoom))×"
              + "\(Int(Double(canvas.height) * loupe.effectiveZoom)) vs viewport "
              + "\(viewport.keyString)) · source \(source.keyString) "
              + "· document crop \(session.edit.geometry.cropRect.keyString) "
              + "· framing crop \(framing.crop.keyString) · θ \(framing.straightenDegrees) "
              + "· canvas \(canvasRect.keyString)")
        if !fits(loupe.effectiveZoom) {
            loupe.zoomToFit()
            CropUITestSupport.pump(0.05)
        }
        let zoom = loupe.effectiveZoom
        XCTAssertTrue(fits(zoom), "the judging framing must have the whole canvas on screen")
        print("197 ② · 判据取景 · effectiveZoom \(zoom) · fitScale "
              + "\(loupe.currentCropWorkspaceFitScale) · 画布整块可见 \(fits(zoom))")

        // ① 框盖住旋转空角（整帧在 5.4° 下必然盖住）⇒ 红。
        loupe.cropTool.draft.crop = .full
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)
        let over = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let effectiveOver = loupe.cropTool.effectiveCrop(source: source)
        print("197 ② · 盖空角 · exceedsPicture \(over.exceedsPicture) "
              + "· model \(loupe.cropTool.frameExceedsPicture(source: source)) "
              + "· effectiveCrop \(effectiveOver.keyString) "
              + "· source \(source.keyString) · canvas \(canvasRect.keyString) "
              + "· overlay \(frameBounds(over)) "
              + "· overlay corners \(over.corners.map { "(\(Int($0.x)),\(Int($0.y)))" }.joined(separator: " "))")
        XCTAssertTrue(over.exceedsPicture,
                      "197 ②: the frame covers the rotated-out corner but the "
                      + "stroke is not red (model says "
                      + "\(loupe.cropTool.frameExceedsPicture(source: source)), "
                      + "effectiveCrop \(effectiveOver.keyString), "
                      + "source \(source.keyString), canvas \(canvasRect.keyString), "
                      + "layout \(over.sizeInPoints), viewport \(viewport.keyString), "
                      + "framing crop \(framing.crop.keyString))")

        // ② 完全在照片里 ⇒ 不红。
        let inside = CropRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        loupe.cropTool.draft.crop = inside
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.02)
        let within = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let effectiveWithin = loupe.cropTool.effectiveCrop(source: source)
        print("197 ② · 照片内 · exceedsPicture \(within.exceedsPicture) "
              + "· model \(loupe.cropTool.frameExceedsPicture(source: source)) "
              + "· effectiveCrop \(effectiveWithin.keyString) "
              + "· overlay \(frameBounds(within))")
        XCTAssertFalse(within.exceedsPicture,
                       "197 ②: a 0.4× frame inside the picture is being called out of "
                       + "bounds (effectiveCrop \(effectiveWithin.keyString), "
                       + "source \(source.keyString))")
        XCTAssertEqual(loupe.cropTool.draft.crop.left, inside.left, accuracy: 1e-9,
                       "the alert moved the rect")
        XCTAssertEqual(loupe.cropTool.draft.crop.width, inside.width, accuracy: 1e-9,
                       "the alert moved the rect")
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
