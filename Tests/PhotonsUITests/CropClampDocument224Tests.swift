import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// 224 — **the crop frame's boundary is the document space**: `[0,1]²`, not the viewport and not the
/// straightened picture's AABB.
///
/// 213 measured the frame in the viewport (a full frame was squeezed to 22 % at 100 %); 219 moved the
/// bound to "the picture at the current camera", which grows with the angle (1485 × 1485 at 45° for a
/// 1400 × 1000 viewport), so the frame could be dragged out without an upper bound. The user's rule is
/// the simple one:
///
///   · **allowed** outside the photograph — the black corners a straighten cuts off (`frameExceedsPicture`);
///   · **not allowed** outside the document canvas — the frame rectangle `[0,1]²`;
///   · the screen, the zoom and the window size do not participate.
///
/// This file pins the six acceptance numbers of 224.
@MainActor
final class CropClampDocument224Tests: XCTestCase {

    private var workDir: URL!
    private static let source = ImageSize(width: 6000, height: 4500)
    private static let viewport = ImageSize(width: 1400, height: 1000)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-224-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func makeController() throws -> CropToolController {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        return controller
    }

    private func mapping(_ state: LoupeViewState,
                         viewport: ImageSize = viewport,
                         degrees: Double = 0) -> LoupeMapping {
        LoupeFraming(viewport: viewport,
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full,
                     straightenDegrees: degrees).mapping(of: state)
    }

    private func assertInsideDocument(_ crop: CropRect, accuracy: Double = 1e-12,
                                      _ message: String = "") {
        XCTAssertGreaterThanOrEqual(crop.left, 0 - accuracy, "\(message) left")
        XCTAssertGreaterThanOrEqual(crop.top, 0 - accuracy, "\(message) top")
        XCTAssertLessThanOrEqual(crop.right, 1 + accuracy, "\(message) right")
        XCTAssertLessThanOrEqual(crop.bottom, 1 + accuracy, "\(message) bottom")
    }

    // MARK: - 224 §3.1 — the infinite excursion is gone

    /// The frame's centre is put **ten document widths** outside each edge, the shipped clamp runs,
    /// and the rect comes back inside `[0,1]²` flush with the edge it crossed — zero error, not a
    /// tolerance. (219's bound was the view AABB, so at 45° these four seeds travelled for ever.)
    func testAFrameTenCanvasWidthsAwayIsPulledBackWithZeroError() throws {
        let controller = try makeController()
        let state = LoupeViewState(mode: .actual, zoom: 4, centerX: 3000, centerY: 2250)
        let map = mapping(state, degrees: 45)
        controller.draft.straighten = 45

        let span = 0.2
        let ten = 10.0
        let cases: [(String, (Double, Double), String)] = [
            ("左", (-ten, 0.5), "left"),
            ("右", (1 + ten, 0.5), "right"),
            ("上", (0.5, -ten), "top"),
            ("下", (0.5, 1 + ten), "bottom"),
        ]

        var reports: [String] = []
        for (name, centre, edge) in cases {
            controller.draft.crop = CropRect(left: centre.0 - span / 2, top: centre.1 - span / 2,
                                             right: centre.0 + span / 2, bottom: centre.1 + span / 2)
            XCTAssertTrue(controller.clampToView(mapping: map, source: Self.source),
                          "224 §1 \(name): the clamp must move a frame that is off the document")
            let crop = controller.draft.crop
            assertInsideDocument(crop, accuracy: 0, "224 §1 \(name):")
            switch edge {
            case "left": XCTAssertEqual(crop.left, 0, accuracy: 0)
            case "right": XCTAssertEqual(crop.right, 1, accuracy: 0)
            case "top": XCTAssertEqual(crop.top, 0, accuracy: 0)
            default: XCTAssertEqual(crop.bottom, 1, accuracy: 0)
            }
            // Moving, never reshaping: the seed's 0.2 × 0.2 span survives.
            XCTAssertEqual(crop.width, span, accuracy: 1e-12)
            XCTAssertEqual(crop.height, span, accuracy: 1e-12)
            reports.append(String(format: "%@ l %.12f t %.12f r %.12f b %.12f",
                                  name, crop.left, crop.top, crop.right, crop.bottom))
        }
        print("224 §1 · 十画布宽外 · " + reports.joined(separator: " ‖ "))
    }

    // MARK: - 224 §3.2 — the photograph's edge is a warning, not a clamp

    /// At 45°, the full frame `[0,1]²` is **legal** — it covers the turned-out black corners — and the
    /// overlay is told to paint it red. The "改前" column is what the old `clampedToRotatedFrame`
    /// shrink produced on the same full frame.
    func testAtFortyFiveDegreesTheFullFrameIsAllowedAndWarns() throws {
        let controller = try makeController()
        let map = mapping(.fit, degrees: 45)
        controller.draft = CropToolController.Draft(crop: .full, straighten: 45, lock: .original)

        let drawn = controller.effectiveCrop(source: Self.source)
        let oldShrink = CropMath.clampedToRotatedFrame(.full, in: Self.source, degrees: 45,
                                                       keepsInsideRotatedFrame: true)
        let w = Double(Self.source.width), h = Double(Self.source.height)
        print(String(format: "224 §2 · 45° 满幅框 · 改前 %.1f×%.1f px → 改后 %.1f×%.1f px · "
                     + "frameExceedsPicture %@",
                     oldShrink.width * w, oldShrink.height * h,
                     drawn.width * w, drawn.height * h,
                     controller.frameExceedsPicture(source: Self.source) ? "true" : "false"))

        XCTAssertEqual(drawn, .full, "224 §2: 45° must not shrink the full frame back inside the picture")
        XCTAssertEqual(drawn.width, 1, accuracy: 0)
        XCTAssertEqual(drawn.height, 1, accuracy: 0)
        XCTAssertTrue(controller.frameExceedsPicture(source: Self.source),
                      "224 §2: the full frame at 45° covers the black corner — it must be red")
        // Running the clamp on the legal full frame is an identity: the clamp is the document, not
        // the picture's turned quad.
        XCTAssertFalse(controller.clampToView(mapping: map, source: Self.source),
                       "224 §2: a full frame is already inside [0,1]²")
        XCTAssertEqual(controller.draft.crop, .full)
    }

    // MARK: - 224 §3.3 — the viewport does not participate

    /// The same document and the same angle, clamped with an 800 × 600 and a 2560 × 1600 viewport:
    /// the two results are equal **value for value**. The seed that is already legal is included, so
    /// the identity path is covered as well as the pull-back.
    func testTheClampIsIdenticalAtTwoViewports() throws {
        let controller = try makeController()
        let seeds: [CropRect] = [
            CropRect(left: 0.2, top: 0.1, right: 0.95, bottom: 0.7),
            CropRect(left: 1.2, top: 0.2, right: 1.7, bottom: 0.8),
            CropRect(left: -0.4, top: -0.3, right: 0.2, bottom: 0.1),
        ]
        let small = mapping(.fit, viewport: ImageSize(width: 800, height: 600), degrees: 45)
        let large = mapping(.fit, viewport: ImageSize(width: 2560, height: 1600), degrees: 45)

        var reports: [String] = []
        for seed in seeds {
            controller.draft = CropToolController.Draft(crop: seed, straighten: 45, lock: .original)
            _ = controller.clampToView(mapping: small, source: Self.source)
            let a = controller.draft.crop
            controller.draft = CropToolController.Draft(crop: seed, straighten: 45, lock: .original)
            _ = controller.clampToView(mapping: large, source: Self.source)
            let b = controller.draft.crop

            XCTAssertEqual(a.left, b.left, accuracy: 0, "small vs large viewport: left")
            XCTAssertEqual(a.top, b.top, accuracy: 0, "small vs large viewport: top")
            XCTAssertEqual(a.right, b.right, accuracy: 0, "small vs large viewport: right")
            XCTAssertEqual(a.bottom, b.bottom, accuracy: 0, "small vs large viewport: bottom")
            assertInsideDocument(a, accuracy: 1e-12, "800×600:")
            reports.append("800×600 " + a.keyString + " == 2560×1600 " + b.keyString)
        }
        print("224 §3 · 与屏幕无关 · " + reports.joined(separator: " ‖ "))
    }

    // MARK: - 224 §3.4 — no 219 regression: a full frame survives every zoom

    func testFullFrameSurvivesEveryFramingAtZeroDegrees() throws {
        let controller = try makeController()
        controller.draft.straighten = 0
        let framings: [(String, LoupeViewState)] = [
            ("fit", .fit),
            ("100%", LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2250)),
            ("200%", LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2250)),
            ("400%", LoupeViewState(mode: .actual, zoom: 4, centerX: 3000, centerY: 2250)),
        ]

        var ratios: [String] = []
        for (name, state) in framings {
            controller.draft.crop = .full
            _ = controller.clampToView(mapping: mapping(state), source: Self.source)
            XCTAssertEqual(controller.draft.crop, .full, "\(name): a full frame must stay full")
            ratios.append(String(format: "%@ %.1f%%", name, controller.draft.crop.width * 100))
        }
        print("224 §4 · 0° 满幅框 · " + ratios.joined(separator: " · "))
    }

    // MARK: - 224 §3.5 — 45° + 400 % + pan, then a real drag tick

    /// The shipped drag path at 45°, 400 % and an off-centre camera: after a far tick the stored rect
    /// is still inside `[0,1]²`. The camera is deliberately not centred, so the old view-AABB bound
    /// would have moved with it.
    func testFortyFiveDegreesAtFourHundredPercentAPanAndDragStayInTheDocument() throws {
        let controller = try makeController()
        let state = LoupeViewState(mode: .actual, zoom: 4, centerX: 1200, centerY: 800)
        let map = mapping(state, degrees: 45)
        controller.draft = CropToolController.Draft(
            crop: CropRect(left: 0.3, top: 0.3, right: 0.5, bottom: 0.5),
            straighten: 45, lock: .original)
        _ = controller.clampToView(mapping: map, source: Self.source)

        let crop = controller.draft.crop
        let grab = viewPoint(normalized: NormalizedPoint(crop.centerX, crop.centerY),
                             mapping: map, degrees: 45)
        XCTAssertTrue(controller.beginDrag(atViewPoint: grab, mapping: map, source: Self.source),
                      "the press inside the frame was not taken")
        let far = viewPoint(normalized: NormalizedPoint(9, 9), mapping: map, degrees: 45)
        controller.continueDrag(atViewPoint: far, mapping: map, source: Self.source)
        controller.endDrag()

        let after = controller.draft.crop
        print(String(format: "224 §5 · 45° 400%% 平移后拖动 · crop l %.12f t %.12f r %.12f b %.12f "
                     + "· clampMoves %d",
                     after.left, after.top, after.right, after.bottom, controller.clampMoves))
        assertInsideDocument(after, accuracy: 1e-12, "224 §5:")
        XCTAssertEqual(min(after.left, after.top, 1 - after.right, 1 - after.bottom), 0,
                       accuracy: 1e-12, "the far drag must stop on the document's edge")
        XCTAssertGreaterThan(controller.clampMoves, 0, "the drag must have gone through the clamp")
    }

    /// The exact inverse of `CropToolController.normalized` at the draft's angle.
    private func viewPoint(normalized point: NormalizedPoint, mapping: LoupeMapping,
                           degrees: Double) -> CGPoint {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let rotation = CropGeometry.RotationMatrix(degrees: degrees)
        let turned = rotation.invert(x: (point.x - 0.5) * w, y: (point.y - 0.5) * h)
        let p = mapping.frameView(frameX: w / 2 + turned.x, frameY: h / 2 + turned.y)
        return CGPoint(x: p.x, y: p.y)
    }
}
