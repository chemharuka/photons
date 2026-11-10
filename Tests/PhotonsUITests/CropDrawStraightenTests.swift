import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 328 — 画线拉直: draw a line, the picture turns to the nearest axis.
///
/// The whole gesture is one pure function (`CropDrawStraighten.draw`) plus one write that already
/// exists (`CropToolController.commitStraighten`), so the acceptance can be stated without a screen:
///
///   · **self-consistency** — for every listed line angle, the value the gesture computes *lands the
///     line on the nearest axis*, measured through the renderer's own forward map
///     (`LoupeMapping.viewPoint(sourceX:sourceY:)`), to 1e−9°;
///   · **the mapping** — view → source includes zoom/pan, the rotation and the keystone's `P`, which
///     is what makes a line drawn on a warped picture mean the right angle;
///   · **the frame does not move** while a line is being drawn (§2 / 310);
///   · **a misfire is nothing** — 19 pt applies no angle and writes no row;
///   · **one gesture is one ⌘Z**;
///   · **横/竖** — a 7° line ends up level, an 83° line ends up plumb, in export pixels.
@MainActor
final class CropDrawStraightenTests: XCTestCase {

    private let viewport = ImageSize(width: 1200, height: 800)
    private let source = ImageSize(width: 1200, height: 800)

    // MARK: - fixtures

    private func framing(source: ImageSize? = nil,
                         crop: CropRect = .full,
                         straighten: Double = 0,
                         perspective: PerspectiveMap? = nil,
                         viewport: ImageSize? = nil) -> LoupeFraming {
        let source = source ?? self.source
        return LoupeFraming(viewport: viewport ?? self.viewport,
                            sourceWidth: Double(source.width),
                            sourceHeight: Double(source.height),
                            crop: crop,
                            straightenDegrees: straighten,
                            flipH: false,
                            flipV: false,
                            perspective: perspective)
    }

    /// Where a **source pixel** is drawn on the canvas — the renderer's forward walk.
    private func viewPoint(_ mapping: LoupeMapping, _ point: CGPoint) -> CGPoint {
        let p = mapping.viewPoint(sourceX: Double(point.x), sourceY: Double(point.y))
        return CGPoint(x: p.x, y: p.y)
    }

    /// The angle, in degrees, at which the rendered picture shows the source segment `a → b`: the
    /// number a screenshot of the canvas (or of the export) would measure. Rotation is a similarity
    /// in pixels (281), so this is the line's angle *as drawn*.
    private func drawnAngle(source: ImageSize? = nil,
                            straighten: Double,
                            perspective: PerspectiveMap? = nil,
                            from a: CGPoint,
                            to b: CGPoint,
                            state: LoupeViewState = .fit) -> Double {
        let map = framing(source: source, straighten: straighten,
                          perspective: perspective).mapping(of: state)
        let p = viewPoint(map, a), q = viewPoint(map, b)
        return CropDrawStraighten.degrees(dx: Double(q.x - p.x), dy: Double(q.y - p.y))
    }

    /// Distance from `degrees` to the horizontal / vertical **axis**, in degrees (0…90). Continuous
    /// through ±90°, unlike a folded difference, so the 1e−9 assertion is a real one.
    private func axisDistance(_ degrees: Double, _ axis: CropStraightenAxis) -> Double {
        let radians = degrees * .pi / 180
        let s = min(abs(sin(radians)), 1)
        let c = min(abs(cos(radians)), 1)
        return axis == .horizontal ? asin(s) * 180 / .pi : asin(c) * 180 / .pi
    }

    /// A source-space segment of `length` px through `centre`, at `degrees`.
    private func segment(at degrees: Double, length: Double = 600,
                         centre: CGPoint = CGPoint(x: 600, y: 400)) -> (CGPoint, CGPoint) {
        let radians = degrees * .pi / 180
        let half = length / 2
        return (CGPoint(x: Double(centre.x) - half * cos(radians),
                        y: Double(centre.y) - half * sin(radians)),
                CGPoint(x: Double(centre.x) + half * cos(radians),
                        y: Double(centre.y) + half * sin(radians)))
    }

    /// The gesture, as the canvas performs it: two source points → their view points → the draw.
    private func draw(_ a: CGPoint, _ b: CGPoint,
                      mapping: LoupeMapping,
                      nearestAxis: Bool = true) -> CropStraightenDraw? {
        CropDrawStraighten.draw(from: viewPoint(mapping, a), to: viewPoint(mapping, b),
                                mapping: mapping, nearestAxis: nearestAxis)
    }

    // MARK: - ① self-consistency (the core)

    /// 15 lines (the angles §4.1 lists: 0, ±2, ±5, ±30, ±44.9, 45.1, ±60, 89, −89, 90), each drawn on
    /// three different current angles: the value the gesture computes must put the line on its axis
    /// to 1e−9°, and the 横/竖 decision must be `|θ| ≤ 45°`.
    ///
    /// The measurement is the **drawn** angle — the renderer's forward projection at the new document
    /// angle — not a re-derivation of the formula, so a sign error cannot pass by being consistent
    /// with itself.
    func testEveryDrawnLineLandsOnTheNearestAxis() throws {
        let angles: [Double] = [0, 2, -2, 5, -5, 30, -30, 44.9, -44.9, 45.1, 60, -60, 89, -89, 90]
        var worst = 0.0
        var rows: [String] = []

        for current in [0.0, 9.0, -17.0] {
            let map = framing(straighten: current).mapping(of: .fit)
            for theta in angles {
                let (a, b) = segment(at: theta)
                let result = try XCTUnwrap(draw(a, b, mapping: map),
                                           "\(theta)°: the gesture produced nothing")
                let expected: CropStraightenAxis = abs(theta) <= 45 ? .horizontal : .vertical
                XCTAssertEqual(result.axis, expected, "\(theta)°: 贴轴判定")
                // A line has no direction: compare modulo 180 so a fold at ±90° cannot flake.
                let angleError = min(abs(result.sourceAngle - theta),
                                     abs(abs(result.sourceAngle - theta) - 180))
                XCTAssertLessThanOrEqual(angleError, 1e-9,
                                         "\(theta)°: the source-space angle is the line's own")

                // The correction never needs more than the limit: the fold is what keeps it legal.
                XCTAssertLessThanOrEqual(abs(result.raw), 45 + 1e-9,
                                         "\(theta)°: 校正量越界 \(result.raw)")
                XCTAssertFalse(result.wasClamped, "\(theta)°: 不该被夹")

                let after = drawnAngle(straighten: result.applied, from: a, to: b)
                let residual = axisDistance(after, result.axis)
                worst = max(worst, residual)
                rows.append(String(format: "%+6.1f° (now %+5.1f°) → %@ %+6.2f° · drawn %+8.4f° · off axis %.2e°",
                                   theta, current, result.axis == .horizontal ? "横" : "竖",
                                   result.applied, after, residual))
                XCTAssertLessThanOrEqual(residual, 1e-9,
                                         "\(theta)° at \(current)°: the line is \(residual)° off its axis")
            }
        }
        print("328 ① self-consistency — \(rows.count) lines, worst residual \(String(format: "%.3e", worst))°")
        for row in rows.prefix(15) { print("328 ① · \(row)") }
    }

    // MARK: - ② the mapping (zoom / pan / rotation / keystone)

    /// Four known source pixels, forward-projected onto the canvas and mapped back: ≤ 0.5 px in all
    /// three projections.
    ///
    /// (a) a 2× camera panned off-centre, (b) a document with `keystone = (+30, −15)`, (c) a 9°
    /// straighten. The keystone group also prints what the **wrong** map (the same framing without
    /// `P`) would answer, so 「映射里有 P」 is a measured difference and not a claim.
    func testViewToSourceMappingIsHalfAPixelExact() {
        let points = [CGPoint(x: 120, y: 80), CGPoint(x: 900, y: 300),
                      CGPoint(x: 300, y: 700), CGPoint(x: 1100, y: 750)]
        let keystone = PerspectiveMap(vertical: 30, horizontal: -15)
        let zoomed = LoupeViewState(mode: .actual, zoom: 2.0, centerX: 700, centerY: 520)

        struct Case { let name: String; let mapping: LoupeMapping; let state: LoupeViewState
                      let wrong: LoupeMapping? }
        let cases: [Case] = [
            Case(name: "zoom 2.0 + pan", mapping: framing().mapping(of: zoomed), state: zoomed,
                 wrong: nil),
            Case(name: "keystone (+30, −15)",
                 mapping: framing(perspective: keystone).mapping(of: .fit), state: .fit,
                 wrong: framing().mapping(of: .fit)),
            Case(name: "straighten 9°", mapping: framing(straighten: 9).mapping(of: .fit),
                 state: .fit, wrong: nil),
        ]

        for testCase in cases {
            var worst = 0.0
            var wrongWorst = 0.0
            for truth in points {
                let onScreen = viewPoint(testCase.mapping, truth)
                let back = CropDrawStraighten.sourcePoint(of: onScreen, mapping: testCase.mapping)
                let error = hypot(Double(back.x - truth.x), Double(back.y - truth.y))
                worst = max(worst, error)
                XCTAssertLessThanOrEqual(error, 0.5,
                                         "\(testCase.name): \(truth) came back as \(back) — \(error) px")
                if let wrong = testCase.wrong {
                    let naive = CropDrawStraighten.sourcePoint(of: onScreen, mapping: wrong)
                    wrongWorst = max(wrongWorst,
                                     hypot(Double(naive.x - truth.x), Double(naive.y - truth.y)))
                }
            }
            print(String(format: "328 ② mapping · %@: worst %.6f px%@", testCase.name, worst,
                         testCase.wrong == nil ? ""
                            : String(format: " · without P: %.2f px", wrongWorst)))
            if testCase.wrong != nil {
                XCTAssertGreaterThan(wrongWorst, 5,
                                     "\(testCase.name): the keystone must move the answer — a map "
                                     + "without P cannot pass this group")
            }
        }
    }

    // MARK: - ③ the limit

    /// The limit is `CropTool.straightenLimit`, the card reads `draft.straighten`, and a clamped
    /// value is reported as the number that took effect.
    ///
    /// A drawn line cannot *reach* the limit — §3.2's fold puts the correction at most 45° away — so
    /// the clamp is exercised through the same write door a gesture uses (`applyDrawnStraighten`),
    /// and the 60° case is asserted both ways: its honest answer (−30°, 竖) and the clamp itself.
    func testTheLimitClampsAndTheReadoutShowsTheAppliedValue() {
        let session = CatalogSession()
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())

        // The honest answer for a 60° line: 竖, +30° — nowhere near the limit.
        let map = framing().mapping(of: .fit)
        let (a, b) = segment(at: 60)
        let sixty = draw(a, b, mapping: map)
        XCTAssertEqual(sixty?.axis, .vertical)
        XCTAssertEqual(sixty?.raw ?? 0, 30, accuracy: 1e-9, "60° 线 → 竖 → +30°")
        XCTAssertEqual(sixty?.wasClamped, false)

        // The clamp itself, through the write.
        let applied = tool.applyDrawnStraighten(60)
        XCTAssertEqual(applied, CropTool.straightenLimit, accuracy: 1e-12, "raw 60 → 生效值 45")
        XCTAssertEqual(tool.draft.straighten, CropTool.straightenLimit, accuracy: 1e-12)
        XCTAssertEqual(session.edit.geometry.straightenDegrees, CropTool.straightenLimit,
                       accuracy: 1e-12, "文档与读数一致")
        XCTAssertEqual(tool.angleUIValue, 45, accuracy: 1e-12, "读数 45（实际生效值）")
        XCTAssertEqual(tool.sliderAngleText(), "+45.0°")
        XCTAssertEqual(CropTool.clampStraighten(-60), -45, accuracy: 1e-12)

        // And the pure form of the same two numbers.
        let clamped = CropDrawStraighten.draw(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 30, y: 0), mapping: map)
        XCTAssertEqual(clamped?.raw ?? .nan, 0, accuracy: 1e-12, "a level line asks for nothing")
        print(String(format: "328 ③ clamp: raw +60 → 生效 %.1f, 读数 %@, 文档 %.1f; 60° 线本身的正解 %+.1f°",
                     applied, tool.sliderAngleText(), session.edit.geometry.straightenDegrees,
                     sixty?.raw ?? 0))
    }

    // MARK: - ④ the frame does not move

    /// §2 — twenty drags during a stroke: the crop rect is identical to the bit, and the tool is not
    /// dragging a handle (`isDragging == false`, no `lastHandle`).
    func testDrawingALineNeverTouchesTheCropFrame() {
        let session = CatalogSession()
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())
        tool.draft.crop = CropRect(x: 0.1, y: 0.12, width: 0.6, height: 0.5)
        XCTAssertTrue(tool.setDrawStraightenArmed(true))

        let before = tool.draft.crop
        XCTAssertTrue(tool.beginDrawStraighten(atViewPoint: CGPoint(x: 200, y: 200)))
        XCTAssertFalse(tool.isDragging, "a stroke is not a frame drag")
        XCTAssertNil(tool.lastHandle, "a stroke takes no grip")

        var worstW = 0.0, worstH = 0.0
        for step in 1...20 {
            let t = Double(step) / 20
            tool.continueDrawStraighten(atViewPoint: CGPoint(x: 200 + 300 * t, y: 200 + 80 * t))
            let now = tool.draft.crop
            worstW = max(worstW, abs(now.width - before.width))
            worstH = max(worstH, abs(now.height - before.height))
            XCTAssertEqual(now, before, "tick \(step): the crop rect moved")
        }
        XCTAssertLessThanOrEqual(worstW, 1e-12)
        XCTAssertLessThanOrEqual(worstH, 1e-12)
        XCTAssertEqual(tool.straightenStroke?.b, CGPoint(x: 500, y: 280), "the line followed the hand")
        print(String(format: "328 ④ 20 ticks: Δw %.1e, Δh %.1e, frame %.4f×%.4f",
                     worstW, worstH, before.width, before.height))
    }

    // MARK: - ⑤ a misfire

    /// 19 pt is not a line: no angle, no history row, no prompt — only the counter.
    func testANineteenPointStrokeAppliesNothing() {
        let session = CatalogSession()
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())
        XCTAssertTrue(tool.setDrawStraightenArmed(true))
        let rows = session.history.snapshots.count
        let angle = tool.draft.straighten

        // Exactly 19 pt on screen, the last misfire the rule allows.
        XCTAssertTrue(tool.beginDrawStraighten(atViewPoint: CGPoint(x: 300, y: 300)))
        tool.continueDrawStraighten(atViewPoint: CGPoint(x: 319, y: 300))
        let result = tool.endDrawStraighten(mapping: framing().mapping(of: .fit))
        XCTAssertNil(result, "19 pt 不是一条线")
        XCTAssertEqual(tool.draft.straighten, angle, "角度不变")
        XCTAssertEqual(session.edit.geometry.straightenDegrees, 0, "文档不变")
        XCTAssertEqual(session.history.snapshots.count, rows, "无历史记录")
        XCTAssertEqual(tool.tooShortStraightenCount, 1)
        XCTAssertEqual(tool.drawnStraightenCount, 0)
        XCTAssertNil(tool.straightenStroke, "误触不留线")

        // 22.5 pt of tilted line is a line — the threshold is where it says it is.
        XCTAssertTrue(tool.beginDrawStraighten(atViewPoint: CGPoint(x: 300, y: 300)))
        tool.continueDrawStraighten(atViewPoint: CGPoint(x: 321, y: 308))
        XCTAssertNotNil(tool.endDrawStraighten(mapping: framing().mapping(of: .fit)))
        XCTAssertEqual(tool.drawnStraightenCount, 1)
        XCTAssertEqual(session.history.snapshots.count, rows + 1, "一次手势一条历史")
        print("328 ⑤ misfire: 19 pt → angle \(angle), rows \(rows); 21 pt → rows \(session.history.snapshots.count)")
    }

    // MARK: - ⑥ one gesture, one ⌘Z

    /// After a drawn line the document carries the new angle and the history grew by one; ⌘Z is the
    /// angle from before the line.
    func testOneStrokeIsOneUndo() throws {
        let session = CatalogSession()
        let tool = CropToolController(session: session)
        // A bare session has no baseline snapshot (`canUndo` needs two); one real edit gives the
        // history the "before" state the gesture is compared against.
        session.applyEdit { $0.light.exposure = 0.25 }
        _ = session.commitEdit(label: "曝光", coalesce: false)
        XCTAssertTrue(tool.begin())
        XCTAssertTrue(tool.setDrawStraightenArmed(true))
        XCTAssertEqual(session.edit.geometry.straightenDegrees, 0, "画线前 0°")
        let rows = session.history.snapshots.count

        let map = framing().mapping(of: .fit)
        let (a, b) = segment(at: 7)
        let va = viewPoint(map, a), vb = viewPoint(map, b)
        XCTAssertTrue(tool.beginDrawStraighten(atViewPoint: va))
        tool.continueDrawStraighten(atViewPoint: vb)
        let result = try XCTUnwrap(tool.endDrawStraighten(mapping: map))
        XCTAssertEqual(result.applied, -7, accuracy: 1e-9, "7° 线 → 摆平要 −7°")

        XCTAssertEqual(session.edit.geometry.straightenDegrees, -7, accuracy: 1e-9, "文档 −7°")
        XCTAssertEqual(session.history.snapshots.count, rows + 1, "一次手势 = 一条历史")
        XCTAssertEqual(tool.drawnStraightenCount, 1)

        XCTAssertTrue(session.undo(), "⌘Z 可用")
        XCTAssertEqual(session.edit.geometry.straightenDegrees, 0, accuracy: 1e-12,
                       "⌘Z 回到画线前的 0°")
        print(String(format: "328 ⑥ undo: 0° → %.1f° (rows %d) → ⌘Z → %.1f°",
                     -7.0, rows + 1, session.edit.geometry.straightenDegrees))
    }

    // MARK: - ⑦ 横 / 竖, in export pixels

    /// The line the user drew, measured in the **export canvas** at 1:1 — the grid the file's pixels
    /// come from (`FrameTransform`, the renderer's own S1 → S3 walk).
    ///
    /// (a) a 7° line ends level (|Δy| ≤ 1 px over the whole segment); (b) an 83° line ends plumb
    /// (|Δx| ≤ 1 px).
    func testASevenDegreeLineEndsLevelAndAnEightyThreeDegreeLineEndsPlumb() throws {
        func exported(_ a: CGPoint, _ b: CGPoint, at degrees: Double) -> (CGPoint, CGPoint) {
            let transform = FrameTransform(source: source, crop: .full,
                                           straightenDegrees: degrees, quarterTurns: 0,
                                           viewport: nil, zoom: 1)
            let p = transform.sourceToView(SIMD2<Double>(Double(a.x), Double(a.y)))
            let q = transform.sourceToView(SIMD2<Double>(Double(b.x), Double(b.y)))
            return (CGPoint(x: Double(p.x), y: Double(p.y)),
                    CGPoint(x: Double(q.x), y: Double(q.y)))
        }

        let map = framing().mapping(of: .fit)

        // (a) 7°, meant to be level.
        let (a1, b1) = segment(at: 7)
        let seven = try XCTUnwrap(draw(a1, b1, mapping: map))
        XCTAssertEqual(seven.axis, .horizontal)
        let (p1, q1) = exported(a1, b1, at: seven.applied)
        XCTAssertLessThanOrEqual(abs(Double(q1.y - p1.y)), 1,
                                 "7° 线应用后两端 y 差 \(abs(Double(q1.y - p1.y))) px")

        // (b) 83°, meant to be plumb.
        let (a2, b2) = segment(at: 83)
        let eightyThree = try XCTUnwrap(draw(a2, b2, mapping: map))
        XCTAssertEqual(eightyThree.axis, .vertical)
        let (p2, q2) = exported(a2, b2, at: eightyThree.applied)
        XCTAssertLessThanOrEqual(abs(Double(q2.x - p2.x)), 1,
                                 "83° 线应用后两端 x 差 \(abs(Double(q2.x - p2.x))) px")

        print(String(format: "328 ⑦ 横竖: 7° → %.2f° (Δy %.3f px) · 83° → %.2f° (Δx %.3f px)",
                     seven.applied, abs(Double(q1.y - p1.y)),
                     eightyThree.applied, abs(Double(q2.x - p2.x))))
    }

    // MARK: - ⑧ the line's flash

    /// 1.5 pt white over a 1 px shadow, held 0.3 s, then gone — the constants and the curve the
    /// overlay and the fade timer both read.
    func testTheLineIsHeldForPointThreeSecondsThenFades() {
        XCTAssertEqual(CropDrawStraighten.lineWidth, 1.5)
        XCTAssertEqual(CropDrawStraighten.shadowWidth, 1)
        XCTAssertEqual(CropDrawStraighten.holdSeconds, 0.3)
        XCTAssertEqual(CropToolOverlayView.straightenLineWidth, 1.5)
        XCTAssertEqual(CropToolOverlayView.straightenShadowWidth, 1)
        XCTAssertEqual(CropDrawStraighten.minimumLengthPoints, 20)

        XCTAssertEqual(CropDrawStraighten.alpha(elapsed: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(CropDrawStraighten.alpha(elapsed: 0.299), 1, accuracy: 1e-12)
        XCTAssertEqual(CropDrawStraighten.alpha(elapsed: 0.3), 1, accuracy: 1e-12)
        XCTAssertEqual(CropDrawStraighten.alpha(elapsed: 0.375), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CropDrawStraighten.alpha(elapsed: 0.45), 0, accuracy: 1e-12)
        XCTAssertEqual(CropDrawStraighten.alpha(elapsed: 5), 0, accuracy: 1e-12)
        print(String(format: "328 ⑧ flash: alpha(0.29)=%.2f alpha(0.375)=%.2f alpha(0.45)=%.2f",
                     CropDrawStraighten.alpha(elapsed: 0.29),
                     CropDrawStraighten.alpha(elapsed: 0.375),
                     CropDrawStraighten.alpha(elapsed: 0.45)))
    }

    /// The same claim through the controller: the line is up at full opacity right after the release
    /// and gone once the 0.3 s + fade has run out.
    func testTheLiveStrokeIsClearedByTheFade() {
        let session = CatalogSession()
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())
        XCTAssertTrue(tool.setDrawStraightenArmed(true))
        let map = framing().mapping(of: .fit)
        let (a, b) = segment(at: 4)
        XCTAssertTrue(tool.beginDrawStraighten(atViewPoint: viewPoint(map, a)))
        tool.continueDrawStraighten(atViewPoint: viewPoint(map, b))
        XCTAssertNotNil(tool.endDrawStraighten(mapping: map))
        XCTAssertNotNil(tool.straightenStroke, "松手后线仍在")
        XCTAssertEqual(tool.straightenStrokeAlpha, 1, accuracy: 1e-12)

        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        XCTAssertNil(tool.straightenStroke, "0.3 s 后淡出")
        XCTAssertEqual(tool.straightenStrokeAlpha, 1, accuracy: 1e-12, "清掉后回到不透明")
    }

    // MARK: - ⑨ reverse gate ①: the angle must be taken in source space

    /// With the keystone on, the same line has two angles: the one in the photograph (`P⁻¹` undone
    /// — §3.1's source space) and the one on the warped screen. **This gate applies both** and asks
    /// the question §3.1 makes the truth: *is the line level in the photograph?*
    ///
    ///   · the shipped path leaves it at 0° in the sensor grid (residual ≤ 1e−9°);
    ///   · the view-space reading asks for 1.698° more, so the photograph keeps that tilt — the gate
    ///     is red by more than a degree, which is why the mapping test's keystone group (`P` in the
    ///     walk, 40.88 px without it) is the one that pins this down.
    ///
    /// The number the *screen* still shows after the shipped path (1.69° at this corner) is the
    /// keystone's own angular distortion — the pipeline is `P → R`, so the correction levels the
    /// photograph **before** the keystone — and it is recorded in the report, not hidden here.
    func testTheAngleMustBeMeasuredInSourceSpaceNotOnScreen() throws {
        let keystone = PerspectiveMap(vertical: 30, horizontal: -15)
        let map = framing(perspective: keystone).mapping(of: .fit)
        // Off-centre, where the homography bends the picture most.
        let (a, b) = segment(at: 20, centre: CGPoint(x: 900, y: 250))

        let shipped = try XCTUnwrap(draw(a, b, mapping: map))
        let shippedResidual = axisDistance(shipped.sourceAngle + shipped.applied, shipped.axis)

        // The naive reading: the angle between the two **view** points, applied the same way.
        let va = viewPoint(map, a), vb = viewPoint(map, b)
        let screenAngle = CropDrawStraighten.fold(CropDrawStraighten.degrees(dx: Double(vb.x - va.x),
                                                                             dy: Double(vb.y - va.y)))
        let naiveAxis = CropDrawStraighten.axis(forFoldedAngle: screenAngle)
        let naiveRaw = CropDrawStraighten.correction(foldedAngle: screenAngle, axis: naiveAxis)
        let naiveApplied = CropTool.clampStraighten(naiveRaw)
        let naiveResidual = axisDistance(shipped.sourceAngle + naiveApplied, naiveAxis)

        // And what the screen shows in each case, for the record (§3.1 fixes which one is the goal).
        let shippedOnScreen = drawnAngle(straighten: shipped.applied, perspective: keystone,
                                         from: a, to: b)
        let naiveOnScreen = drawnAngle(straighten: naiveApplied, perspective: keystone,
                                      from: a, to: b)

        print(String(format: "328 ⑨① gate: source θ %+.3f° → %+.3f° (photograph off %.2e°, screen off %.2f°)",
                     shipped.sourceAngle, shipped.applied, shippedResidual,
                     axisDistance(shippedOnScreen, shipped.axis)))
        print(String(format: "328 ⑨① gate: view θ %+.3f° → %+.3f° (photograph off %.3f°, screen off %.3f°)",
                     screenAngle, naiveApplied, naiveResidual,
                     axisDistance(naiveOnScreen, naiveAxis)))
        XCTAssertLessThanOrEqual(shippedResidual, 1e-9,
                                 "the shipped path leaves the photograph level")
        XCTAssertGreaterThan(naiveResidual, 1.0,
                             "the view-space angle leaves the photograph tilted — the gate must be red")
        XCTAssertNotEqual(naiveApplied, shipped.applied, accuracy: 1e-6,
                          "the two spaces must give different numbers on a keystoned picture")
    }

    // MARK: - ⑨ reverse gate ②: the nearest axis

    /// Without the 贴轴 fold every line is taken as 横, so an 83° line asks for −83°, the clamp turns
    /// it −45° and the line ends up 38° off plumb — ⑦(b) red by hundreds of pixels.
    func testWithoutTheNearestAxisRuleAnEightyThreeDegreeLineGoesWrong() {
        let session = CatalogSession()
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())
        XCTAssertTrue(tool.setDrawStraightenArmed(true))
        tool.foldsToNearestAxis = false      // the gate

        let map = framing().mapping(of: .fit)
        let (a, b) = segment(at: 83)
        let va = viewPoint(map, a), vb = viewPoint(map, b)
        XCTAssertTrue(tool.beginDrawStraighten(atViewPoint: va))
        tool.continueDrawStraighten(atViewPoint: vb)
        let result = tool.endDrawStraighten(mapping: map)
        XCTAssertEqual(result?.axis, .horizontal, "without the fold everything is 横")
        XCTAssertEqual(result?.raw ?? 0, -83, accuracy: 1e-9)
        XCTAssertEqual(result?.wasClamped, true, "−83° 被夹到 −45°")

        let after = drawnAngle(straighten: result?.applied ?? 0, from: a, to: b)
        let offPlumb = axisDistance(after, .vertical)
        print(String(format: "328 ⑨② gate: 83° line → axis %@, raw %+.1f°, applied %+.1f°, drawn %.1f°, %.1f° off plumb",
                     result?.axis.rawValue ?? "—", result?.raw ?? 0, result?.applied ?? 0,
                     after, offPlumb))
        XCTAssertGreaterThan(offPlumb, 30, "the gate must be visibly wrong (the line stays at 38°)")
    }
}
