import XCTest
import CoreGraphics
import PhotonsCore
@testable import PhotonsUI

/// 224 — **the crop frame's boundary is the document's canvas**, not the viewport and not the
/// straightened picture's AABB.
///
/// 213 measured the frame in the viewport (a full frame was squeezed to 22 % at 100 %); 219 moved the
/// bound to "the picture at the current camera", which grows with the angle (1485 × 1485 at 45° for a
/// 1400 × 1000 viewport), so the frame could be dragged out without an upper bound. The user's rule is
/// the simple one:
///
///   · **allowed** outside the photograph — the black corners a straighten cuts off (`frameExceedsPicture`);
///   · **not allowed** outside the **document canvas** — the smallest axis-aligned box holding every
///     pixel of the whole photograph once it is turned (its AABB), expressed in the crop rect's own
///     normalized coordinates;
///   · the screen, the zoom and the window size do not participate.
///
/// **2026-11-02 the user replaced 224's `[0,1]²` with that canvas** (「旋转之后裁剪框能移动的范围应该是
/// 画布，不是原始图片」). At 0°/180° the AABB is the photograph itself, so every upright number in this
/// file is byte-for-byte the one 224 pinned; at 8°/45° the canvas is wider than the photograph and the
/// legal rect is `-0.1187…1.1187 × -0.325…1.325` (6000 × 4500, 45°) instead of `0…1`. `[0,1]²` is only
/// the right-angle answer, not the rule.
///
/// Every expectation below is derived by `legalRect(degrees:source:)` — the AABB formula re-derived in
/// this file, never `CropGeometry.documentCanvasCropRect` — so a regression in either side shows up as a
/// disagreement instead of cancelling out.
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

    /// The legal area of a crop frame: the **document canvas** — the smallest axis-aligned box that
    /// holds every pixel of the whole photograph once it is turned by `degrees`.
    ///
    /// Derived here from the AABB formula (`e = |w·cos| + |h·sin|` by `|w·sin| + |h·cos|`, centred on the
    /// photograph) instead of calling `CropGeometry.documentCanvasCropRect`, so the assertion has an
    /// independent source. At 0°/180° it is exactly `0…1`; at a right angle the extent is an axis swap.
    private func legalRect(degrees: Double, source: ImageSize) -> CropRect {
        let w = Double(max(source.width, 1)), h = Double(max(source.height, 1))
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

    private func assertInsideDocument(_ crop: CropRect, degrees: Double, accuracy: Double = 1e-12,
                                      _ message: String = "") {
        let legal = legalRect(degrees: degrees, source: Self.source)
        XCTAssertGreaterThanOrEqual(crop.left, legal.left - accuracy, "\(message) left")
        XCTAssertGreaterThanOrEqual(crop.top, legal.top - accuracy, "\(message) top")
        XCTAssertLessThanOrEqual(crop.right, legal.right + accuracy, "\(message) right")
        XCTAssertLessThanOrEqual(crop.bottom, legal.bottom + accuracy, "\(message) bottom")
    }

    // MARK: - 224 §3.1 — the infinite excursion is gone

    /// The frame's centre is put **ten document widths** outside each edge, the shipped clamp runs,
    /// and the rect comes back inside the document canvas flush with the edge it crossed — an error of
    /// 1e-12, i.e. the slide's own rounding and nothing more (the upright case lands on exactly 0/1,
    /// because the numbers there are addition and subtraction of the same integers).
    /// (219's bound was the view AABB, so at 45° these four seeds travelled for ever.)
    ///
    /// 2026-11-02 — the flush edges moved from `0` / `1` to the canvas' own edges (6000 × 4500 at 45°:
    /// `-0.118718433538` / `1.118718433538` horizontally, `-0.324957911384` / `1.324957911384`
    /// vertically), recomputed here from the AABB formula rather than hard-coded.
    func testAFrameTenCanvasWidthsAwayIsPulledBackWithZeroError() throws {
        let controller = try makeController()
        let state = LoupeViewState(mode: .actual, zoom: 4, centerX: 3000, centerY: 2250)
        let map = mapping(state, degrees: 45)
        controller.draft.straighten = 45
        let legal = legalRect(degrees: 45, source: Self.source)

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
            assertInsideDocument(crop, degrees: 45, accuracy: 1e-12, "224 §1 \(name):")
            // Flush against the canvas' edge, not against the photograph's.
            switch edge {
            case "left": XCTAssertEqual(crop.left, legal.left, accuracy: 1e-12)
            case "right": XCTAssertEqual(crop.right, legal.right, accuracy: 1e-12)
            case "top": XCTAssertEqual(crop.top, legal.top, accuracy: 1e-12)
            default: XCTAssertEqual(crop.bottom, legal.bottom, accuracy: 1e-12)
            }
            // Moving, never reshaping: the seed's 0.2 × 0.2 span survives.
            XCTAssertEqual(crop.width, span, accuracy: 1e-12)
            XCTAssertEqual(crop.height, span, accuracy: 1e-12)
            reports.append(String(format: "%@ l %.12f t %.12f r %.12f b %.12f",
                                  name, crop.left, crop.top, crop.right, crop.bottom))
        }
        print("224 §1 · 十画布宽外 · " + reports.joined(separator: " ‖ "))
    }

    // MARK: - 246 — the pixel layer is the perspective quadrilateral

    /// A keystoned document's crop frame is painted red by the **photo quad** (not the turned
    /// rectangle) and its canvas is the new P → R → AABB size. The controller must thread the
    /// document's keystone into both, or the UI would show a green frame and the old canvas.
    func testPerspectiveDrivesTheRedFrameAndTheCanvas() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        session.applyEdit { $0.geometry.perspectiveVertical = 50 }
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        controller.draft = CropToolController.Draft(crop: .full, straighten: 0, lock: .original,
                                                     perspectiveVertical: 50)

        let expected = CropMath.canvasSize(crop: .full, in: Self.source,
                                           straightenDegrees: 0, quarterTurns: 0,
                                           allowsOutsideSource: true,
                                           perspective: PerspectiveMap(vertical: 50, horizontal: 0))
        print("246 UI · red \(controller.frameExceedsPicture(source: Self.source))"
              + " · canvas \(controller.effectiveCanvas.width)×\(controller.effectiveCanvas.height)"
              + " (expect \(expected.width)×\(expected.height))")
        XCTAssertTrue(controller.frameExceedsPicture(source: Self.source),
                      "the AABB's corners are outside the keystoned picture — red")
        XCTAssertEqual(controller.effectiveCanvas, expected,
                       "the workspace canvas must be the new AABB")
    }

    // MARK: - 224 §3.2 — the photograph's edge is a warning, not a clamp

    /// At 45°, the full frame `[0,1]²` is **legal** — it covers the turned-out black corners and sits
    /// well inside the document canvas (`-0.1187…1.1187 × -0.325…1.325`) — and the overlay is told to
    /// paint it red. The "改前" column is what the old `clampedToRotatedFrame` shrink produced on the
    /// same full frame.
    func testAtFortyFiveDegreesTheFullFrameIsAllowedAndWarns() throws {
        let controller = try makeController()
        let map = mapping(.fit, degrees: 45)
        controller.draft = CropToolController.Draft(crop: .full, straighten: 45, lock: .original)
        let legal = legalRect(degrees: 45, source: Self.source)

        let drawn = controller.effectiveCrop(source: Self.source)
        let oldShrink = CropMath.clampedToRotatedFrame(.full, in: Self.source, degrees: 45,
                                                       keepsInsideRotatedFrame: true)
        let w = Double(Self.source.width), h = Double(Self.source.height)
        print(String(format: "224 §2 · 45° 满幅框 · 改前 %.1f×%.1f px → 改后 %.1f×%.1f px · "
                     + "frameExceedsPicture %@ · 合法区 l %.6f t %.6f r %.6f b %.6f",
                     oldShrink.width * w, oldShrink.height * h,
                     drawn.width * w, drawn.height * h,
                     controller.frameExceedsPicture(source: Self.source) ? "true" : "false",
                     legal.left, legal.top, legal.right, legal.bottom))

        XCTAssertEqual(drawn, .full, "224 §2: 45° must not shrink the full frame back inside the picture")
        XCTAssertEqual(drawn.width, 1, accuracy: 0)
        XCTAssertEqual(drawn.height, 1, accuracy: 0)
        XCTAssertTrue(controller.frameExceedsPicture(source: Self.source),
                      "224 §2: the full frame at 45° covers the black corner — it must be red")
        // The photograph is, by construction, inside its own canvas: `[0,1]² ⊆ legal` at 45°, with the
        // black corners a straighten opens making up the difference.
        XCTAssertLessThanOrEqual(legal.left, 0 + 1e-12)
        XCTAssertLessThanOrEqual(legal.top, 0 + 1e-12)
        XCTAssertGreaterThanOrEqual(legal.right, 1 - 1e-12)
        XCTAssertGreaterThanOrEqual(legal.bottom, 1 - 1e-12)
        // Running the clamp on the legal full frame is an identity: the clamp is the document, not
        // the picture's turned quad.
        XCTAssertFalse(controller.clampToView(mapping: map, source: Self.source),
                       "224 §2: a full frame is already inside the document canvas")
        XCTAssertEqual(controller.draft.crop, .full)
    }

    // MARK: - 224 §3.3 — the viewport does not participate

    /// The same document and the same angle, clamped with an 800 × 600 and a 2560 × 1600 viewport:
    /// the two results are equal **value for value**. The seed that is already legal is included, so
    /// the identity path is covered as well as the pull-back.
    ///
    /// 2026-11-02 — the legality check is the document canvas (`-0.1187…1.1187 × -0.325…1.325` at 45°),
    /// not `[0,1]²`; the seeds and the equality are unchanged, and the second seed now stops on the
    /// canvas' right edge instead of the photograph's.
    func testTheClampIsIdenticalAtTwoViewports() throws {
        let controller = try makeController()
        let seeds: [CropRect] = [
            CropRect(left: 0.2, top: 0.1, right: 0.95, bottom: 0.7),
            CropRect(left: 1.2, top: 0.2, right: 1.7, bottom: 0.8),
            CropRect(left: -0.4, top: -0.3, right: 0.2, bottom: 0.1),
        ]
        let small = mapping(.fit, viewport: ImageSize(width: 800, height: 600), degrees: 45)
        let large = mapping(.fit, viewport: ImageSize(width: 2560, height: 1600), degrees: 45)
        let legal = legalRect(degrees: 45, source: Self.source)

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
            assertInsideDocument(a, degrees: 45, accuracy: 1e-12, "800×600:")
            assertInsideDocument(b, degrees: 45, accuracy: 1e-12, "2560×1600:")
            XCTAssertEqual(a.width, seed.width, accuracy: 1e-12, "never reshaped: width")
            XCTAssertEqual(a.height, seed.height, accuracy: 1e-12, "never reshaped: height")
            reports.append("800×600 " + a.keyString + " == 2560×1600 " + b.keyString)
        }
        print(String(format: "224 §3 · 与屏幕无关（合法区 l %.6f t %.6f r %.6f b %.6f）· ",
                     legal.left, legal.top, legal.right, legal.bottom)
              + reports.joined(separator: " ‖ "))
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
    /// is still inside the **document canvas**, flush with one of its edges. The camera is deliberately
    /// not centred, so the old view-AABB bound would have moved with it.
    ///
    /// 2026-11-02 — "flush" is measured against the canvas' edges (`-0.1187` left, `-0.325` top,
    /// `1.1187` right, `1.325` bottom on 6000 × 4500), not against `0` / `1`.
    func testFortyFiveDegreesAtFourHundredPercentAPanAndDragStayInTheDocument() throws {
        let controller = try makeController()
        let state = LoupeViewState(mode: .actual, zoom: 4, centerX: 1200, centerY: 800)
        let map = mapping(state, degrees: 45)
        let legal = legalRect(degrees: 45, source: Self.source)
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
                     + "· clampMoves %d · 合法区 l %.12f t %.12f r %.12f b %.12f",
                     after.left, after.top, after.right, after.bottom, controller.clampMoves,
                     legal.left, legal.top, legal.right, legal.bottom))
        assertInsideDocument(after, degrees: 45, accuracy: 1e-12, "224 §5:")
        XCTAssertEqual(min(after.left - legal.left, after.top - legal.top,
                           legal.right - after.right, legal.bottom - after.bottom),
                       0, accuracy: 1e-12, "the far drag must stop on the canvas' edge")
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

// MARK: - 224 补充契约：框不允许在**任何时刻**移出画布

/// The user's follow-up is a hard boundary, not a pull-back: every observable `draft.crop` is inside
/// the **document canvas**. These tests watch the drag **tick by tick** (not only its last value), and
/// then prove that a pinned edge stops dead when the hand keeps going.
///
/// 2026-11-02 — 「画布」 here means the AABB of the whole turned photograph, not `[0,1]²`
/// (「旋转之后裁剪框能移动的范围应该是画布，不是原始图片」). At 45° on 6000 × 4500 that is
/// `-0.1187…1.1187 × -0.325…1.325`; `[0,1]²` survives only as the 0°/180° case of the same formula.
@MainActor
final class CropClampDocument224TickTests: XCTestCase {

    private var workDir: URL!
    private static let source = ImageSize(width: 6000, height: 4500)
    private static let viewport = ImageSize(width: 1400, height: 1000)

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-224-tick-\(UUID().uuidString)", isDirectory: true)
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

    private func mapping(_ state: LoupeViewState, degrees: Double) -> LoupeMapping {
        LoupeFraming(viewport: Self.viewport,
                     sourceWidth: Double(Self.source.width),
                     sourceHeight: Double(Self.source.height),
                     crop: .full,
                     straightenDegrees: degrees).mapping(of: state)
    }

    private func viewPoint(normalized point: NormalizedPoint, mapping: LoupeMapping,
                           degrees: Double) -> CGPoint {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let rotation = CropGeometry.RotationMatrix(degrees: degrees)
        let turned = rotation.invert(x: (point.x - 0.5) * w, y: (point.y - 0.5) * h)
        let p = mapping.frameView(frameX: w / 2 + turned.x, frameY: h / 2 + turned.y)
        return CGPoint(x: p.x, y: p.y)
    }

    /// The document canvas — the smallest axis-aligned box holding every pixel of the whole photograph
    /// after the turn — re-derived here from the AABB formula rather than read from `CropGeometry`, so
    /// the assertion cannot be satisfied by the implementation agreeing with itself. At 0°/180° this is
    /// exactly `0…1`.
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

    private func isOutsideDocument(_ crop: CropRect, degrees: Double,
                                   tolerance: Double = 1e-12) -> Bool {
        let legal = legalRect(degrees: degrees)
        return crop.left < legal.left - tolerance || crop.top < legal.top - tolerance
            || crop.right > legal.right + tolerance || crop.bottom > legal.bottom + tolerance
    }

    /// 224 补充 §3 — drag the hand far outside (30 document widths) in 140 ticks and check **every**
    /// tick, not just the last. The reported number is 「越界 tick 数」 and must be 0.
    func testEveryDragTickIsInsideTheDocument() throws {
        let controller = try makeController()
        let degrees = 45.0
        let state = LoupeViewState(mode: .actual, zoom: 4, centerX: 1200, centerY: 800)
        let map = mapping(state, degrees: degrees)
        controller.draft = CropToolController.Draft(
            crop: CropRect(left: 0.35, top: 0.35, right: 0.55, bottom: 0.55),
            straighten: degrees, lock: .original)
        _ = controller.clampToView(mapping: map, source: Self.source)

        let start = controller.draft.crop
        let grab = NormalizedPoint(start.centerX, start.centerY)
        XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: grab, mapping: map,
                                                                  degrees: degrees),
                                          mapping: map, source: Self.source))

        let ticks = 140
        let reach = 30.0                       // document widths beyond the frame
        var outsideTicks = 0
        var firstOutside = ""
        for i in 1...ticks {
            let t = Double(i) / Double(ticks)
            let target = NormalizedPoint(grab.x + reach * t, grab.y + reach * t)
            controller.continueDrag(atViewPoint: viewPoint(normalized: target, mapping: map,
                                                           degrees: degrees),
                                    mapping: map, source: Self.source)
            let crop = controller.draft.crop
            if isOutsideDocument(crop, degrees: degrees) {
                outsideTicks += 1
                if firstOutside.isEmpty { firstOutside = "tick \(i): \(crop.keyString)" }
            }
        }
        controller.endDrag()

        print("224 补充 §3 · 45° 400% 平移 · \(ticks) ticks · 越界 tick 数 = \(outsideTicks)"
              + (firstOutside.isEmpty ? "" : " · 首个 \(firstOutside)"))
        XCTAssertEqual(outsideTicks, 0, "224 补充 §3: 越界 tick 数必须为 0 — \(firstOutside)")
        XCTAssertEqual(ticks, 140)
    }

    /// 224 补充 §5 — once the frame is pinned on the document's edge, further ticks in the same
    /// direction must not move it at all: the drawn quad's corner displacement is 0 pt and the rect is
    /// bit-for-bit constant (no jitter).
    func testPinnedFrameDoesNotMoveOnFurtherTicks() throws {
        let controller = try makeController()
        let degrees = 45.0
        let state = LoupeViewState(mode: .actual, zoom: 4, centerX: 1200, centerY: 800)
        let map = mapping(state, degrees: degrees)
        controller.draft = CropToolController.Draft(
            crop: CropRect(left: 0.35, top: 0.35, right: 0.55, bottom: 0.55),
            straighten: degrees, lock: .original)
        _ = controller.clampToView(mapping: map, source: Self.source)

        let start = controller.draft.crop
        let grab = NormalizedPoint(start.centerX, start.centerY)
        XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: grab, mapping: map,
                                                                  degrees: degrees),
                                          mapping: map, source: Self.source))
        let far = viewPoint(normalized: NormalizedPoint(grab.x + 30, grab.y + 30),
                            mapping: map, degrees: degrees)
        controller.continueDrag(atViewPoint: far, mapping: map, source: Self.source)
        let pinned = controller.draft.crop
        let pinnedCorners = controller.layout(mapping: map, source: Self.source, pointScale: 1).corners

        var displacement = 0.0
        var rectChanged = false
        for _ in 0..<24 {
            controller.continueDrag(atViewPoint: far, mapping: map, source: Self.source)
            let now = controller.draft.crop
            if isOutsideDocument(now, degrees: degrees) { XCTFail("224 补充 §5: a pinned tick left the document") }
            if now != pinned { rectChanged = true }
            let corners = controller.layout(mapping: map, source: Self.source, pointScale: 1).corners
            for (a, b) in zip(pinnedCorners, corners) {
                displacement = max(displacement, hypot(Double(a.x - b.x), Double(a.y - b.y)))
            }
        }
        controller.endDrag()

        print(String(format: "224 补充 §5 · 贴边后追加 24 ticks · 位移量 = %.12f pt · 框变化 %@",
                     displacement, rectChanged ? "yes" : "no"))
        XCTAssertFalse(rectChanged, "224 补充 §5: a pinned frame must not move at all")
        XCTAssertEqual(displacement, 0, accuracy: 0, "224 补充 §5: 位移量必须为 0 pt")
    }

    /// 224 补充 §1 — the other write paths (ratio presets, custom ratio, 拉直, zoom/pan) also leave
    /// `draft.crop` inside the **document canvas** immediately, with no follow-up clamp needed to
    /// observe it. Each write is checked against the canvas of the angle the draft then holds
    /// (2026-11-02: `0…1` upright, the turned AABB after 拉直), never against a hard-coded `[0,1]²`.
    func testRatioStraightenAndCameraWritesStayInsideTheDocument() throws {
        let controller = try makeController()
        controller.draft = CropToolController.Draft(
            crop: CropRect(left: 0.1, top: 0.1, right: 0.9, bottom: 0.9),
            straighten: 0, lock: .original)

        var writes = 0
        for preset in [CropAspectPreset.square, .fourThree, .threeTwo, .sixteenNine, .free] {
            controller.setAspect(preset, source: Self.source)
            writes += 1
            XCTAssertFalse(isOutsideDocument(controller.draft.crop, degrees: controller.draft.straighten),
                           "setAspect(\(preset)) left the document canvas")
        }
        controller.setCustomRatio(0.77, source: Self.source)
        writes += 1
        XCTAssertFalse(isOutsideDocument(controller.draft.crop, degrees: controller.draft.straighten),
                       "setCustomRatio left the document canvas")

        controller.setStraighten(45)
        writes += 1
        XCTAssertFalse(isOutsideDocument(controller.draft.crop, degrees: controller.draft.straighten),
                       "拉直 left the document canvas")

        for state in [LoupeViewState.fit,
                      LoupeViewState(mode: .actual, zoom: 4, centerX: 900, centerY: 700)] {
            _ = controller.clampToView(mapping: mapping(state, degrees: 45), source: Self.source)
            writes += 1
            XCTAssertFalse(isOutsideDocument(controller.draft.crop, degrees: controller.draft.straighten),
                           "camera write left the document canvas")
        }
        print("224 补充 §1 · 比例/拉直/相机写入 \(writes) 次 · 越界次数 = 0")
        XCTAssertGreaterThan(writes, 0)
    }
}
