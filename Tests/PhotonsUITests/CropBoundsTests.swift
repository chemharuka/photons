import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 162 §2.3 / G3 — **框不出画布，但可以出相机像素**.
///
/// `canvasBounds` is the hard edge: the crop frame (or, at a draft angle, the AABB of its turned
/// quad) may never cross the viewport edge. `sourcePixelBounds` (`0…1²`) is only a readout/prompt
/// concept now: the frame may cover the black band outside the sensor, because that band is still
/// inside the canvas.
///
/// **188** — for a **draft angle** that hard edge became a *reachability* criterion: the turned quad's
/// centre has to stay on the canvas, its edges may cross it (「旋转后裁切框可以出画布」). The upright
/// path (`clampedToCanvas`, θ = 0) is untouched and still contains the frame, which is why the two
/// corner tests below are unchanged.
@MainActor
final class CropBoundsTests: XCTestCase {

    private var workDir: URL!
    private static let viewport = ImageSize(width: 900, height: 600)
    private static let source = ImageSize(width: 3000, height: 2000)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-bounds-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeController() throws -> (CropToolController, CatalogSession) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        return (controller, session)
    }

    private func mapping(_ state: LoupeViewState) -> LoupeMapping {
        LoupeFraming(viewport: Self.viewport,
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full,
                     straightenDegrees: 0).mapping(of: state)
    }

    private func rect(_ layout: CropToolLayout) -> CGRect {
        let xs = layout.corners.map(\.x), ys = layout.corners.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func canvasRect() -> CGRect {
        CGRect(x: 0, y: 0, width: Double(Self.viewport.width), height: Double(Self.viewport.height))
    }

    /// A press in the middle of the frame, then one tick far away in `direction` — the shipped drag
    /// path, not `CropToolDrag` in isolation.
    private func drag(_ controller: CropToolController, mapping: LoupeMapping,
                      from crop: CropRect, to direction: CGVector) {
        controller.draft = CropToolController.Draft(crop: crop, straighten: controller.draft.straighten,
                                                    lock: .original)
        _ = controller.clampToView(mapping: mapping, source: Self.source)
        let centreFrame = mapping.frameView(frameX: crop.centerX * Double(Self.source.width),
                                            frameY: crop.centerY * Double(Self.source.height))
        let start = CGPoint(x: centreFrame.x, y: centreFrame.y)
        XCTAssertTrue(controller.beginDrag(atViewPoint: start, mapping: mapping,
                                          source: Self.source, pointScale: 1),
                      "the press inside the frame was not taken")
        controller.continueDrag(atViewPoint: CGPoint(x: start.x + direction.dx,
                                                     y: start.y + direction.dy),
                                mapping: mapping, source: Self.source, pointScale: 1)
        controller.endDrag()
    }

    // MARK: - ① corners, upright

    /// Four directions, same start: the frame lands flush on the canvas edge it was pushed toward,
    /// with no gap and no overshoot.
    func testDraggingToEachCornerPinsTheFrameToTheCanvas() throws {
        let (controller, _) = try makeController()
        let map = mapping(.fit)
        let canvas = canvasRect()
        let crop = CropRect(left: 0.40, top: 0.40, right: 0.60, bottom: 0.60)
        let tolerance = 0.5

        for (name, direction, edge) in [
            ("right/down", CGVector(dx: 5000, dy: 5000), "bottomRight"),
            ("left/up", CGVector(dx: -5000, dy: -5000), "topLeft"),
            ("right/up", CGVector(dx: 5000, dy: -5000), "topRight"),
            ("left/down", CGVector(dx: -5000, dy: 5000), "bottomLeft"),
        ] {
            drag(controller, mapping: map, from: crop, to: direction)
            let frame = rect(controller.layout(mapping: map, source: Self.source, pointScale: 1,
                                               quadRotationDegrees: 0))
            print("162 G3 · \(name) · frame \(NSStringFromRect(frame)) · canvas \(NSStringFromRect(canvas))")
            XCTAssertGreaterThanOrEqual(frame.minX, canvas.minX - tolerance)
            XCTAssertGreaterThanOrEqual(frame.minY, canvas.minY - tolerance)
            XCTAssertLessThanOrEqual(frame.maxX, canvas.maxX + tolerance)
            XCTAssertLessThanOrEqual(frame.maxY, canvas.maxY + tolerance)
            switch edge {
            case "bottomRight":
                XCTAssertLessThanOrEqual(abs(frame.maxX - canvas.maxX), tolerance, "right edge is not flush")
                XCTAssertLessThanOrEqual(abs(frame.maxY - canvas.maxY), tolerance, "bottom edge is not flush")
            case "topLeft":
                XCTAssertLessThanOrEqual(abs(frame.minX - canvas.minX), tolerance, "left edge is not flush")
                XCTAssertLessThanOrEqual(abs(frame.minY - canvas.minY), tolerance, "top edge is not flush")
            case "topRight":
                XCTAssertLessThanOrEqual(abs(frame.maxX - canvas.maxX), tolerance)
                XCTAssertLessThanOrEqual(abs(frame.minY - canvas.minY), tolerance)
            default:
                XCTAssertLessThanOrEqual(abs(frame.minX - canvas.minX), tolerance)
                XCTAssertLessThanOrEqual(abs(frame.maxY - canvas.maxY), tolerance)
            }
        }
    }

    /// The model value is what is clamped, not just the drawing: `draft.crop` itself is inside the
    /// canvas rect after the drag.
    func testTheDraftRectItselfStaysInsideTheCanvas() throws {
        let (controller, _) = try makeController()
        let map = mapping(.fit)
        drag(controller, mapping: map,
             from: CropRect(left: 0.40, top: 0.40, right: 0.60, bottom: 0.60),
             to: CGVector(dx: -5000, dy: -5000))
        let c = controller.draft.crop
        let bounds = controller.canvasBounds(mapping: map, source: Self.source)
        print(String(format: "162 G3 · draft l %.6f t %.6f r %.6f b %.6f · canvas bounds l %.6f t %.6f "
                     + "r %.6f b %.6f",
                     c.left, c.top, c.right, c.bottom,
                     bounds.left, bounds.top, bounds.right, bounds.bottom))
        XCTAssertGreaterThanOrEqual(c.left, bounds.left - 1e-9)
        XCTAssertGreaterThanOrEqual(c.top, bounds.top - 1e-9)
        XCTAssertLessThanOrEqual(c.right, bounds.right + 1e-9)
        XCTAssertLessThanOrEqual(c.bottom, bounds.bottom + 1e-9)
        // The source is the fit frame here, so the two coincide; the next test is the case where they
        // do not, and proves the frame may use the band between them.
        XCTAssertEqual(bounds, CropRect.full)
    }

    // MARK: - ② an angle: blank corners are legal, the canvas edge is not

    /// At 8° with the camera zoomed out the canvas is wider than the sensor (`-0.25…1.25`). The frame
    /// may sit in that band — pixels outside the camera are allowed — and, since 188, **it may leave
    /// the canvas too** (user's 「旋转后裁切框可以出画布」).
    ///
    /// 190 replaced *how far*: 188 kept the turned quad's centre on the canvas, a rule that read the
    /// viewport and therefore moved with the zoom. The bound is now a document one — at least a
    /// quarter of the frame's own area still covers the canvas — so this drag pins where 25 % is
    /// still on the canvas instead of where the centre sits on its edge. The frame keeps its size
    /// (no shrink) and stays grabbable (a corner is on the canvas).
    func testAtEightDegreesTheFrameMayLeaveTheCanvasAndStayReachable() throws {
        let (controller, _) = try makeController()
        // 0.2× on a 3000×2000 source in a 900×600 canvas: the window is 4500×3000 source pixels, i.e.
        // the canvas bounds are -0.25…1.25 on both axes.
        let state = LoupeViewState(mode: .actual, zoom: 0.2, centerX: 1500, centerY: 1000)
        let map = mapping(state)
        let bounds = controller.canvasBounds(mapping: map, source: Self.source)
        print(String(format: "162 G3 · 0.2× · canvas bounds l %.4f t %.4f r %.4f b %.4f",
                     bounds.left, bounds.top, bounds.right, bounds.bottom))
        XCTAssertEqual(bounds.left, -0.25, accuracy: 1e-9)
        XCTAssertEqual(bounds.top, -0.25, accuracy: 1e-9)
        XCTAssertEqual(bounds.right, 1.25, accuracy: 1e-9)
        XCTAssertEqual(bounds.bottom, 1.25, accuracy: 1e-9)

        controller.draft = CropToolController.Draft(
            crop: CropRect(left: 0.40, top: 0.40, right: 0.60, bottom: 0.60),
            straighten: 8, lock: .original)
        let centreFrame = map.frameView(frameX: 0.5 * Double(Self.source.width),
                                        frameY: 0.5 * Double(Self.source.height))
        let start = CGPoint(x: centreFrame.x, y: centreFrame.y)
        XCTAssertTrue(controller.beginDrag(atViewPoint: start, mapping: map,
                                          source: Self.source, pointScale: 1))
        controller.continueDrag(atViewPoint: CGPoint(x: start.x + 5000, y: start.y + 5000),
                                mapping: map, source: Self.source, pointScale: 1)
        controller.endDrag()

        let layout = controller.layout(mapping: map, source: Self.source, pointScale: 1)
        let frame = rect(layout)
        let canvas = canvasRect()
        print("162 G3 · 8° · draft "
              + String(format: "l %.4f t %.4f r %.4f b %.4f", controller.draft.crop.left,
                       controller.draft.crop.top, controller.draft.crop.right,
                       controller.draft.crop.bottom)
              + " · quad AABB \(NSStringFromRect(frame)) · canvas \(NSStringFromRect(canvas))"
              + String(format: " · centre (%.2f, %.2f)", frame.midX, frame.midY))

        let crop = controller.draft.crop
        // The drag is pulled back toward the canvas' centre, so it ends up hanging over whichever
        // edge the hand came from — here the bottom. Either way it is past the camera's pixels,
        // which is the 132 promise the pre-188 test pinned on the right edge.
        XCTAssertGreaterThan(crop.bottom, 1.0, "the frame must be allowed outside the camera pixels")

        // 190 — 「最多 3/4 出去」, measured where the clamp measures it: the **document**. The pair of
        // numbers below is the whole law — the frame left the camera pixels (above) and left the
        // canvas by exactly three quarters, no more, no less. Comparing against the *visible* canvas
        // rect would repeat 188's mistake: at 0.2× the viewport is a window of the document, so a
        // frame three quarters off the canvas is still comfortably inside the view.
        let coverage = controller.canvasCoverage(of: crop, source: Self.source)
        let quadDoc = layout.corners.map { map.framePoint(viewX: Double($0.x), viewY: Double($0.y)) }
        let maxY = quadDoc.map(\.y).max() ?? 0
        print(String(format: "190 · 8° · pinned at coverage %.6f · quad maxY %.1f px (canvas bottom "
                     + "%.1f) · frame %@", coverage, maxY,
                     (Double(Self.source.height) + LoupeFraming.rotatedExtent(
                        width: Double(Self.source.width), height: Double(Self.source.height),
                        degrees: 8).height) / 2, NSStringFromRect(frame)))
        XCTAssertEqual(coverage, 0.25, accuracy: 0.005,
                       "the drag is pinned on the 25 % floor, not wherever it likes")
        XCTAssertGreaterThan(maxY, Double(Self.source.height),
                             "the frame still hangs past the canvas — moved, never shrunk")
        // …and it is still findable: a grip answers at the drawn position.
        var hits = 0
        for corner in layout.corners where CropTool.hit(corner, in: layout) != .outside { hits += 1 }
        XCTAssertGreaterThanOrEqual(hits, 1, "no grip is reachable — the frame would be lost")
        XCTAssertTrue(controller.frameExceedsPicture(source: Self.source),
                      "the frame covers the blank corner, so the warning must say so")
    }
}
