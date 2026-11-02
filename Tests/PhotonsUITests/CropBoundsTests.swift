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
///
/// **2026-11-02 — the bound is the document canvas, not `[0,1]²`** (「旋转之后裁剪框能移动的范围应该是
/// 画布，不是原始图片」). The canvas is the smallest axis-aligned box holding every pixel of the whole
/// photograph after the turn; `legalRect(degrees:)` below re-derives it from the AABB formula (never
/// from `CropGeometry`). Upright it *is* `[0,1]²`, so the 0° cases keep their numbers verbatim; at 8°
/// on 3000 × 2000 it is `-0.041525…1.041525 × -0.099514…1.099514` and the frame may sit in the black
/// corners a straighten opens — but not one pixel beyond them.
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

    /// The legal area of a crop frame — the **document canvas**: the smallest axis-aligned box holding
    /// every pixel of the whole photograph once it is turned, in normalized crop coordinates.
    ///
    /// Derived here from the AABB formula (`e = |w·cos| + |h·sin|` by `|w·sin| + |h·cos|`, centred on the
    /// photograph) rather than read from `CropGeometry.documentCanvasCropRect`, so the test cannot prove
    /// the implementation with itself. `[0,1]²` at 0°/180°; at 8° on 3000 × 2000 it is
    /// `-0.041525…1.041525 × -0.099514…1.099514`.
    private func legalRect(degrees: Double) -> CropRect {
        let w = Double(max(Self.source.width, 1)), h = Double(max(Self.source.height, 1))
        let quarter = degrees / 90
        let extent: (width: Double, height: Double)
        if abs(quarter - quarter.rounded()) < 1e-9 {
            extent = Int(quarter.rounded()) % 2 != 0 ? (h, w) : (w, h)
        } else {
            let radians = degrees * .pi / 180
            let c = abs(cos(radians)), s = abs(sin(radians))
            extent = (w * c + h * s, w * s + h * c)
        }
        let left = (w - extent.width) / 2, top = (h - extent.height) / 2
        return CropRect(left: left / w, top: top / h,
                        right: (left + extent.width) / w, bottom: (top + extent.height) / h)
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

    /// Four directions, same start: the frame lands flush on the **document canvas** with no gap and no
    /// overshoot. At 0° the canvas *is* `[0,1]²` (2026-11-02: the AABB of an upright photograph), which
    /// 适应 projects to the picture rect, so the flush edges sit at `mapping.frameView(0,0)` /
    /// `(W,H)` — the 90 % fit's 45 / 30 pt margin is outside the document and not part of the law.
    func testDraggingToEachCornerPinsTheFrameToTheCanvas() throws {
        let (controller, _) = try makeController()
        let map = mapping(.fit)
        // The bound, from the formula: `[0,1]²` at θ = 0, bit for bit.
        let legal = legalRect(degrees: 0)
        XCTAssertEqual(legal.left, 0, accuracy: 0)
        XCTAssertEqual(legal.top, 0, accuracy: 0)
        XCTAssertEqual(legal.right, 1, accuracy: 0)
        XCTAssertEqual(legal.bottom, 1, accuracy: 0)
        let origin = map.frameView(frameX: 0, frameY: 0)
        let end = map.frameView(frameX: Double(Self.source.width),
                                frameY: Double(Self.source.height))
        let canvas = CGRect(x: min(origin.x, end.x), y: min(origin.y, end.y),
                            width: abs(end.x - origin.x), height: abs(end.y - origin.y))
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
    /// **document canvas** after the drag (2026-11-02 — the viewport no longer participates, and at 0°
    /// the canvas is `[0,1]²`).
    func testTheDraftRectItselfStaysInsideTheCanvas() throws {
        let (controller, _) = try makeController()
        let map = mapping(.fit)
        let legal = legalRect(degrees: 0)
        drag(controller, mapping: map,
             from: CropRect(left: 0.40, top: 0.40, right: 0.60, bottom: 0.60),
             to: CGVector(dx: -5000, dy: -5000))
        let c = controller.draft.crop
        print(String(format: "224 G3 · draft l %.6f t %.6f r %.6f b %.6f · 合法区 l %.6f t %.6f r %.6f b %.6f",
                     c.left, c.top, c.right, c.bottom,
                     legal.left, legal.top, legal.right, legal.bottom))
        XCTAssertGreaterThanOrEqual(c.left, legal.left - 1e-9)
        XCTAssertGreaterThanOrEqual(c.top, legal.top - 1e-9)
        XCTAssertLessThanOrEqual(c.right, legal.right + 1e-9)
        XCTAssertLessThanOrEqual(c.bottom, legal.bottom + 1e-9)
        // The drag went to the top-left: the rect lands flush on the document's own edges, not on
        // the 90 % fit's letterbox (`-1/18 … 1 + 1/18`, which 213 used as the canvas).
        XCTAssertEqual(c.left, legal.left, accuracy: 1e-9)
        XCTAssertEqual(c.top, legal.top, accuracy: 1e-9)
    }

    // MARK: - ② an angle: blank corners are legal, the canvas edge is not

    /// At 8° the frame may cover the turned-out corner — the photograph's black corner — but it may
    /// **not** leave the document canvas (2026-11-02; the canvas at 8° on 3000 × 2000 is
    /// `-0.041525…1.041525 × -0.099514…1.099514`). The old 188/190 reading measured the frame against
    /// the viewport's window and let it hang a quarter off; that is exactly what made the excursion grow
    /// with the zoom and, at 45°, unbounded. The numbers below are derived from `legalRect`, not
    /// hard-coded, so the same expression produced 224's `0…1` upright.
    func testAtEightDegreesTheFrameIsPulledInsideTheCanvas() throws {
        let (controller, _) = try makeController()
        // 0.2× on a 3000×2000 source in a 900×600 canvas: the viewport is a window of the document.
        let state = LoupeViewState(mode: .actual, zoom: 0.2, centerX: 1500, centerY: 1000)
        let map = mapping(state)
        let legal = legalRect(degrees: 8)

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
        print("224 G3 · 8° · draft "
              + String(format: "l %.4f t %.4f r %.4f b %.4f", controller.draft.crop.left,
                       controller.draft.crop.top, controller.draft.crop.right,
                       controller.draft.crop.bottom)
              + " · quad AABB \(NSStringFromRect(frame))"
              + String(format: " · centre (%.2f, %.2f)", frame.midX, frame.midY)
              + String(format: " · 合法区 l %.6f t %.6f r %.6f b %.6f",
                       legal.left, legal.top, legal.right, legal.bottom))

        let crop = controller.draft.crop
        // 2026-11-02 — the document canvas is the bound: all four edges inside it, and the far drag
        // lands flush on the edge it crossed (down-right ⇒ right and bottom).
        XCTAssertGreaterThanOrEqual(crop.left, legal.left - 1e-9, "the frame leaves the canvas on the left")
        XCTAssertGreaterThanOrEqual(crop.top, legal.top - 1e-9, "the frame leaves the canvas on the top")
        XCTAssertLessThanOrEqual(crop.right, legal.right + 1e-9, "the frame leaves the canvas on the right")
        XCTAssertLessThanOrEqual(crop.bottom, legal.bottom + 1e-9, "the frame leaves the canvas on the bottom")
        XCTAssertEqual(min(crop.left - legal.left, crop.top - legal.top,
                           legal.right - crop.right, legal.bottom - crop.bottom),
                       0, accuracy: 1e-9, "the far drag did not reach the canvas' edge")
        XCTAssertEqual(crop.right, legal.right, accuracy: 1e-9, "the drag went down-right: right edge")
        XCTAssertEqual(crop.bottom, legal.bottom, accuracy: 1e-9, "…and the bottom edge")
        // Never reshaped by the pull-back: the seed's 0.2 × 0.2 survives.
        XCTAssertEqual(crop.width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(crop.height, 0.2, accuracy: 1e-9)
        // …and the turned-out corner is allowed: the frame sits on the picture's blank pixels, which
        // is a red warning, not a clamp.
        XCTAssertTrue(controller.frameExceedsPicture(source: Self.source),
                      "the frame covers the blank corner, so the warning must say so")
    }
}
