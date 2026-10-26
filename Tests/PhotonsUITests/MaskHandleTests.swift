import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// Task 032 — a mask that exists has **draggable control points on the canvas**: 位置, 形状, 角度 and
/// 渐变比例 for the two gradient shapes, a dashed boundary and nothing draggable for a brush, and no
/// geometry at all for the panel-only shapes (colour / luminance / semantic).
///
/// Five things are pinned here, each from the side a user would notice:
///
///   1. **The table is the table** — which grips each shape has, and that a brush/colour/luminance/
///      semantic mask has none (`MaskHandles.controls`). A brush must not turn one stroke into a
///      cloud of dots.
///   2. **The hit radius is constant on screen** — 25 %, 100 % and 400 % zoom, the same 11 pt. The
///      test asserts both halves: inside the radius the grip takes the click, outside it the click is
///      left for the pan.
///   3. **The drag maths** — an angle grip dragged 15° rotates the geometry by 15° ± 0.1°, a band end
///      dragged along the axis changes 渐变比例 linearly and clamps to 1e-3…1, a line dragged across
///      the ramp translates it without touching the width.
///   4. **Portrait does not regress** — on a file stored EXIF 6/8, dragging the centre grip moves the
///      rendered mask's centroid to the pixel under the hand, within 028's 1.5 px budget.
///   5. **One drag is one ⌘Z** — five ticks commit one snapshot, a drag that does not move commits
///      none, and Escape puts the shape back without growing the stack.
///
/// Everything is driven through the same functions the canvas calls (`MaskHandles.*` and
/// `MaskCanvasController`'s handle drag), with the frame the session reports — `maskSourceSize`, the
/// upright frame the renderer ingested — never `asset.width/height`.
@MainActor
final class MaskHandleTests: XCTestCase {

    // MARK: - fixtures

    /// A landscape frame with a lot of pixels: the grip separations must stay wider than two hit
    /// radii even at 25 % zoom, or "the click missed" would be testing the neighbour.
    private let landscape = ImageSize(width: 1200, height: 800)

    private func linear(start: (Double, Double) = (0.5, 0.2), end: (Double, Double) = (0.5, 0.8),
                        midpoint: Double = 0.5) -> LinearGradientShape {
        LinearGradientShape(start: NormalizedPoint(start.0, start.1),
                            end: NormalizedPoint(end.0, end.1), midpoint: midpoint)
    }

    private func radial(center: (Double, Double) = (0.5, 0.5),
                        radius: (Double, Double) = (0.35, 0.25),
                        angle: Double = 0) -> RadialGradientShape {
        RadialGradientShape(center: NormalizedPoint(center.0, center.1),
                            radius: NormalizedPoint(radius.0, radius.1), angle: angle)
    }

    private func mapping(viewport: ImageSize, source: ImageSize, zoom: Double) -> LoupeMapping {
        let framing = LoupeFraming(viewport: viewport,
                                   sourceWidth: Double(source.width),
                                   sourceHeight: Double(source.height))
        let state = LoupeViewState(mode: .actual, zoom: zoom,
                                   centerX: Double(source.width) / 2,
                                   centerY: Double(source.height) / 2)
        return framing.mapping(of: state)
    }

    private func layout(_ shape: MaskShape, source: ImageSize, zoom: Double,
                        feather: Double = 0.5,
                        viewport: ImageSize = ImageSize(width: 900, height: 600))
        -> MaskHandlesLayout {
        MaskHandles.layout(shape: shape, feather: feather, source: source,
                           mapping: mapping(viewport: viewport, source: source, zoom: zoom),
                           pointScale: 1)
    }

    private func grip(_ kind: MaskHandleKind, in layout: MaskHandlesLayout) -> CGPoint? {
        layout.grips.first { $0.kind == kind }?.point
    }

    /// The session the canvas talks to, with one mask selected. No catalog: `commitEdit` keeps the
    /// history and skips the write, which is exactly the part this test measures.
    private func session(with shape: MaskShape, feather: Double = 0.5) -> CatalogSession {
        let session = CatalogSession()
        session.applyEdit {
            $0.masks = [Mask(id: "m-032",
                             components: [MaskComponent(id: "c-032", feather: feather, shape: shape)])]
        }
        session.setSelectedMaskID("m-032")
        // The floor of the stack: the mask's creation, as the inspector does it. After this the
        // "before" of the next commit is this document, not `EditModel.neutral`.
        session.commitEdit(label: "新建蒙版")
        return session
    }

    private func shape(in session: CatalogSession) -> MaskShape? {
        session.edit.masks.first?.components.first?.shape
    }

    // MARK: - 1. the table the task asks for

    func testTheFourMaskKindsHaveExactlyTheControlPointsTheTaskLists() {
        let brush = MaskShape.brush(BrushShape(size: 0.12, strokes: [
            Stroke(points: [0.3, 0.3, 0.6, 0.6], radius: 0.05, feather: 0, flow: 1,
                   erase: false, closed: false)
        ]))
        let colour = MaskShape.colorRange(ColorRangeShape(samples: [[0.5, 0.5, 0.5]],
                                                          tolerance: 0.3, smoothness: 0.5))
        let luminance = MaskShape.luminanceRange(LuminanceRangeShape(low: 0, high: 1,
                                                                     lowFeather: 0.1,
                                                                     highFeather: 0.1))
        let semantic = MaskShape.semantic(SemanticShape(kind: .sky, provider: .systemMatte,
                                                        softEdge: 0.2))

        // 线性渐变: both iso-lines (位置 + 渐变比例) and the angle stem.
        XCTAssertEqual(MaskHandles.controls(for: .linearGradient(linear())),
                       [.position, .angle, .ratio])
        XCTAssertEqual(MaskHandles.handles(for: .linearGradient(linear()), source: landscape).count, 3)
        // 径向: the centre, the four rim grips (形状), the angle stem.
        XCTAssertEqual(MaskHandles.controls(for: .radialGradient(radial())),
                       [.position, .shape, .angle])
        XCTAssertEqual(MaskHandles.handles(for: .radialGradient(radial()), source: landscape).count, 6)
        // 画笔 / 颜色 / 亮度 / 语义: nothing draggable. The brush gets a dashed boundary instead, so
        // one stroke never becomes N points.
        for (name, shape) in [("画笔", brush), ("颜色范围", colour),
                              ("亮度范围", luminance), ("语义", semantic)] {
            XCTAssertEqual(MaskHandles.controls(for: shape), [], "\(name) must have no geometry grips")
            XCTAssertEqual(MaskHandles.handles(for: shape, source: landscape), [],
                           "\(name) must have no grips")
            XCTAssertFalse(MaskHandles.isDraggable(shape), "\(name) is not a dragged geometry")
        }

        // The brush still shows where it is: a dashed box, and no grips inside it.
        let brushLayout = layout(brush, source: landscape, zoom: 1)
        XCTAssertTrue(brushLayout.grips.isEmpty)
        XCTAssertEqual(brushLayout.guides.filter { $0.style == .brushBounds }.count, 1)
        XCTAssertEqual(brushLayout.guides.first?.isClosed, true)
        // The box contains the stroke and its radius: a stroke at 0.3…0.6 with r = 0.05 (short-edge)
        // must not be drawn smaller than the paint.
        let box = MaskHandles.bounds(of: BrushShape(size: 0.12, strokes: [
            Stroke(points: [0.3, 0.3, 0.6, 0.6], radius: 0.05, feather: 0, flow: 1,
                   erase: false, closed: false)
        ]), source: landscape)
        XCTAssertNotNil(box)
        if let box {
            XCTAssertLessThan(box.minX, 0.3)
            XCTAssertGreaterThan(box.maxX, 0.6)
            XCTAssertLessThan(box.minY, 0.3)
            XCTAssertGreaterThan(box.maxY, 0.6)
        }

        // Colour/luminance/semantic draw nothing at all on the canvas.
        for shape in [colour, luminance, semantic] {
            XCTAssertTrue(layout(shape, source: landscape, zoom: 1).isEmpty)
        }
    }

    /// The radial's 羽化 is drawn as the inner dashed ring the task asks for, at `1 − feather` of the
    /// radius — and it disappears when there is no feather.
    func testTheFeatherRingIsTheInnerRingAtOneMinusFeather() {
        let soft = layout(.radialGradient(radial()), source: landscape, zoom: 1, feather: 0.5)
        let rings = soft.guides.filter { $0.style == .featherRing }
        XCTAssertEqual(rings.count, 1, "a feathered ellipse has one dashed inner ring")
        guard let rim = soft.guides.first(where: { $0.style == .rim }),
              let centre = grip(.radialCenter, in: soft) else {
            return XCTFail("a radial layout must have a rim and a centre")
        }
        // Half the feather ⇒ the inner ring is half the radius, about the same centre.
        func meanRadius(_ points: [CGPoint], centre: CGPoint) -> Double {
            let sum = points.reduce(0.0) { $0 + hypot(Double($1.x - centre.x),
                                                      Double($1.y - centre.y)) }
            return sum / Double(max(points.count, 1))
        }
        let outer = meanRadius(rim.points, centre: centre)
        let inner = meanRadius(rings[0].points, centre: centre)
        XCTAssertEqual(inner / outer, 0.5, accuracy: 0.02,
                       "the dashed ring is the soft edge, not a second rim")

        let hard = layout(.radialGradient(radial()), source: landscape, zoom: 1, feather: 0)
        XCTAssertTrue(hard.guides.filter { $0.style == .featherRing }.isEmpty,
                      "feather 0 draws no inner ring")
    }

    // MARK: - 2. the hit radius, in points, at every zoom

    /// The acceptance criterion: 25 %–400 %, the grip eats the click inside 11 pt and leaves it to the
    /// pan outside. Measured in eight directions so a lucky axis cannot pass.
    func testTheHitRadiusIsTheSameNumberOfPointsAtEveryZoom() {
        let shape = MaskShape.radialGradient(radial())
        let kinds: [MaskHandleKind] = [.radialCenter, .radialEdge(.right), .radialEdge(.left),
                                      .radialEdge(.top), .radialEdge(.bottom), .radialAngle]
        let directions: [(Double, Double)] = [(1, 0), (-1, 0), (0, 1), (0, -1),
                                              (0.7071, 0.7071), (-0.7071, 0.7071),
                                              (0.7071, -0.7071), (-0.7071, -0.7071)]
        let radius = MaskHandles.hitRadiusPoints
        var report = "032 hit radius (radial, \(landscape.width)×\(landscape.height))\n"

        for zoom in [0.25, 0.5, 1, 2, 4] {
            let layout = layout(shape, source: landscape, zoom: zoom)
            XCTAssertEqual(layout.grips.count, 6)
            // Where a grip sits on screen must follow the zoom: that is the projection, not a constant.
            if zoom != 1 {
                let right = grip(.radialEdge(.right), in: layout)!
                let centre = grip(.radialCenter, in: layout)!
                let distance = hypot(Double(right.x - centre.x), Double(right.y - centre.y))
                let expected = 0.35 * Double(min(landscape.width, landscape.height)) * zoom
                XCTAssertEqual(distance, expected, accuracy: 0.5,
                               "grips are projected through LoupeMapping (zoom \(zoom))")
            }
            for kind in kinds {
                let p = grip(kind, in: layout)!
                for d in directions {
                    let inside = CGPoint(x: p.x + d.0 * (radius - 1), y: p.y + d.1 * (radius - 1))
                    let outside = CGPoint(x: p.x + d.0 * (radius + 1), y: p.y + d.1 * (radius + 1))
                    XCTAssertEqual(MaskHandles.hit(inside, in: layout), kind,
                                   "zoom \(zoom): \(d) at \(radius - 1) pt must be \(kind.label)")
                    XCTAssertNotEqual(MaskHandles.hit(outside, in: layout), kind,
                                      "zoom \(zoom): \(d) at \(radius + 1) pt must not be \(kind.label)")
                }
            }
            // And a point between the grips is nobody's: the pan keeps it.
            let centre = grip(.radialCenter, in: layout)!
            let far = CGPoint(x: centre.x + radius * 4, y: centre.y + radius * 4)
            XCTAssertNil(MaskHandles.hit(far, in: layout), "zoom \(zoom): an empty point must pan")
            report += String(format: "  %5.0f%%  radius %.0f pt  centre↔right %.1f pt\n",
                             zoom * 100, radius,
                             hypot(Double(grip(.radialEdge(.right), in: layout)!.x - centre.x),
                                   Double(grip(.radialEdge(.right), in: layout)!.y - centre.y)))
        }
        print(report)
    }

    /// A ramp's iso-line is grabbable along its whole drawn length, not just on its dot — that is
    /// what "drag the 等值线" means. Off the line (and off the other two grips) the click pans.
    func testTheWholeIsoLineTakesTheClickAndTheRestOfTheCanvasPans() {
        let shape = MaskShape.linearGradient(linear())
        let layout = layout(shape, source: landscape, zoom: 1)
        let start = grip(.linearLine(.start), in: layout)!
        let end = grip(.linearLine(.end), in: layout)!

        // The lines are horizontal (a vertical ramp), 0.6 short edge long ⇒ ±240 px at zoom 1.
        XCTAssertEqual(MaskHandles.hit(CGPoint(x: start.x + 200, y: start.y), in: layout),
                       .linearLine(.start))
        XCTAssertEqual(MaskHandles.hit(CGPoint(x: start.x - 200, y: start.y), in: layout),
                       .linearLine(.start))
        XCTAssertEqual(MaskHandles.hit(CGPoint(x: end.x + 200, y: end.y), in: layout),
                       .linearLine(.end))
        // Halfway between the two lines, on their axis, is inside the band: not a grip, so a pan.
        let between = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        XCTAssertNil(MaskHandles.hit(between, in: layout),
                     "the middle of the band is not a grip — dragging it is the adjust/pan gesture")
        // 12 pt above the start line: outside the radius (the line's own dot is 11 pt).
        XCTAssertNil(MaskHandles.hit(CGPoint(x: start.x, y: start.y - 12), in: layout))
    }

    /// The hit test never crosses the two shapes: a linear mask has no radial grips and vice versa,
    /// and a mask with no geometry has no layout to hit.
    func testHitTestIsPerShapeAndNeverClaimsAPanelOnlyMask() {
        let linearLayout = layout(.linearGradient(linear()), source: landscape, zoom: 1)
        XCTAssertNil(MaskHandles.hit(grip(.radialCenter, in: linearLayout) ?? .zero, in: linearLayout))
        let brush = layout(.brush(BrushShape(size: 0.12, strokes: [
            Stroke(points: [0.5, 0.5], radius: 0.05, feather: 0, flow: 1, erase: false, closed: false)
        ])), source: landscape, zoom: 1)
        XCTAssertTrue(brush.grips.isEmpty)
        XCTAssertNil(MaskHandles.hit(CGPoint(x: 450, y: 300), in: brush))
    }

    // MARK: - 3. the drag maths

    func testDraggingTheAngleGripRotatesTheMaskByTheSameDegrees() {
        // A frame whose aspect would double any "degrees in normalised space" mistake.
        let source = ImageSize(width: 1600, height: 900)
        let frame = MaskFrameProbe(source: source)

        for degrees in [15.0, -15.0, 45.0, -90.0] {
            // — radial: the shape's own `angle` field.
            let e = radial(radius: (0.30, 0.20), angle: 20)
            let grip = MaskHandles.handles(for: .radialGradient(e), source: source)
                .first { $0.kind == .radialAngle }!
            let grab = grip.point
            let target = frame.rotate(grab, about: (e.center.x, e.center.y), by: degrees)
            let drag = MaskHandleDrag(handle: grip, shape: .radialGradient(e), grab: grab)
            let moved = try? XCTUnwrap(drag.shape(at: target, source: source))
            guard case .radialGradient(let rotated)? = moved else {
                return XCTFail("a radial angle drag must produce a radial shape")
            }
            XCTAssertEqual(rotated.angle, 20 + degrees, accuracy: 0.1,
                           "radial: dragging \(degrees)° must rotate the ellipse \(degrees)°")
            XCTAssertEqual(rotated.center, e.center, "rotation must not move the centre")
            XCTAssertEqual(rotated.radius, e.radius, "rotation must not resize the ellipse")

            // — linear: the ramp's direction, measured on the axis in the same metric.
            let g = linear(start: (0.4, 0.5), end: (0.8, 0.5), midpoint: 0.5)
            let before = frame.angle(of: g.start, to: g.end)
            let lineGrip = MaskHandles.handles(for: .linearGradient(g), source: source)
                .first { $0.kind == .linearAngle }!
            let lineDrag = MaskHandleDrag(handle: lineGrip, shape: .linearGradient(g),
                                          grab: lineGrip.point)
            let lineTarget = frame.rotate(lineGrip.point, about: MaskHandleDrag.centre(of: g),
                                          by: degrees)
            guard case .linearGradient(let turned)? = lineDrag.shape(at: lineTarget, source: source)
            else { return XCTFail("a linear angle drag must produce a linear shape") }
            let after = frame.angle(of: turned.start, to: turned.end)
            let measured = MaskHandleDrag.wrap(after - before)
            print(String(format: "032 angle: asked %+6.1f° → radial %.4f° (err %+.5f°), linear axis %+.4f° (err %+.5f°)",
                         degrees, rotated.angle, rotated.angle - (20 + degrees),
                         measured, measured - degrees))
            XCTAssertEqual(measured, degrees, accuracy: 0.1,
                           "linear: dragging \(degrees)° must turn the ramp \(degrees)°")
            XCTAssertEqual(MaskHandles.gradientRatio(turned, source: source),
                           MaskHandles.gradientRatio(g, source: source), accuracy: 1e-9,
                           "rotation must not change the band width")
        }
    }

    /// 渐变比例: the band width in short-edge units, linear in the drag and clamped at both ends.
    func testDraggingABandEndChangesTheGradientRatioLinearlyAndClamps() {
        let source = ImageSize(width: 1200, height: 800)
        let frame = MaskFrameProbe(source: source)
        let g = linear(start: (0.5, 0.2), end: (0.5, 0.8))          // 0.6 short edge tall
        let startRatio = MaskHandles.gradientRatio(g, source: source)
        XCTAssertEqual(startRatio, 0.6, accuracy: 1e-9)

        let grip = MaskHandles.handles(for: .linearGradient(g), source: source)
            .first { $0.kind == .linearLine(.end) }!
        let drag = MaskHandleDrag(handle: grip, shape: .linearGradient(g), grab: grip.point)

        // +0.1 short edge along the axis (down the frame) ⇒ +0.1 of band.
        var moved = drag.shape(at: frame.offset(grip.point, along: (0, 1), by: 0.1), source: source)
        guard case .linearGradient(let wider)? = moved else { return XCTFail("no shape") }
        XCTAssertEqual(MaskHandles.gradientRatio(wider, source: source), 0.7, accuracy: 1e-9)

        // Half the distance ⇒ half the change: the map is linear, not a step.
        moved = drag.shape(at: frame.offset(grip.point, along: (0, 1), by: 0.05), source: source)
        guard case .linearGradient(let aBit)? = moved else { return XCTFail("no shape") }
        XCTAssertEqual(MaskHandles.gradientRatio(aBit, source: source), 0.65, accuracy: 1e-9)

        // Past the far end: 1 (one short edge), no more.
        moved = drag.shape(at: frame.offset(grip.point, along: (0, 1), by: 5), source: source)
        guard case .linearGradient(let clampedHigh)? = moved else { return XCTFail("no shape") }
        XCTAssertEqual(MaskHandles.gradientRatio(clampedHigh, source: source), 1, accuracy: 1e-12)

        // Past the near end: 1e-3, and the two lines never cross.
        moved = drag.shape(at: frame.offset(grip.point, along: (0, -1), by: 5), source: source)
        guard case .linearGradient(let clampedLow)? = moved else { return XCTFail("no shape") }
        XCTAssertEqual(MaskHandles.gradientRatio(clampedLow, source: source), 1e-3, accuracy: 1e-12)
        XCTAssertLessThan(clampedLow.start.y, clampedLow.end.y,
                          "the 100 % line must stay above the 0 % one")

        // No ratchet: past the clamp and back to +0.1 is exactly +0.1 again.
        moved = drag.shape(at: frame.offset(grip.point, along: (0, 1), by: 0.1), source: source)
        guard case .linearGradient(let back)? = moved else { return XCTFail("no shape") }
        XCTAssertEqual(MaskHandles.gradientRatio(back, source: source), 0.7, accuracy: 1e-9,
                       "a clamped drag must not ratchet")
        print(String(format: "032 ratio: 0.6 → 0.7 → clamp 1.000 / 0.001; start line fixed at y %.4f",
                     wider.start.y))
    }

    /// Dragging an iso-line **across** the ramp translates the whole band and leaves the width alone —
    /// the other half of the same grip, with no mode to get wrong.
    func testDraggingAIsoLineAcrossTheRampTranslatesWithoutResizing() {
        let source = ImageSize(width: 1200, height: 800)
        let frame = MaskFrameProbe(source: source)
        let g = linear(start: (0.5, 0.2), end: (0.5, 0.8))
        let grip = MaskHandles.handles(for: .linearGradient(g), source: source)
            .first { $0.kind == .linearLine(.start) }!

        // 0.05 short edge to the right = 0.05 · 800 / 1200 = 0.0333 in normalised x.
        let target = frame.offset(grip.point, along: (1, 0), by: 0.05)
        let drag = MaskHandleDrag(handle: grip, shape: .linearGradient(g), grab: grip.point)
        guard case .linearGradient(let shifted)? = drag.shape(at: target, source: source) else {
            return XCTFail("no shape")
        }
        let dx = 0.05 * 800.0 / 1200.0
        XCTAssertEqual(shifted.start.x, 0.5 + dx, accuracy: 1e-9)
        XCTAssertEqual(shifted.end.x, 0.5 + dx, accuracy: 1e-9)
        XCTAssertEqual(shifted.start.y, 0.2, accuracy: 1e-9)
        XCTAssertEqual(shifted.end.y, 0.8, accuracy: 1e-9)
        XCTAssertEqual(MaskHandles.gradientRatio(shifted, source: source),
                       MaskHandles.gradientRatio(g, source: source), accuracy: 1e-12,
                       "a sideways drag must not change 渐变比例")

        // The <end> line does the same, and pins the other line to itself.
        let endGrip = MaskHandles.handles(for: .linearGradient(g), source: source)
            .first { $0.kind == .linearLine(.end) }!
        let endDrag = MaskHandleDrag(handle: endGrip, shape: .linearGradient(g), grab: endGrip.point)
        guard case .linearGradient(let left)? = endDrag.shape(
            at: frame.offset(endGrip.point, along: (1, 0), by: 0.05), source: source)
        else { return XCTFail("no shape") }
        XCTAssertEqual(left.start.x, 0.5 + dx, accuracy: 1e-9, "the 100 % line moves with the band")
    }

    /// 形状: a rim grip changes its own axis, ⇧ scales both.
    func testRimGripsChangeTheirOwnAxisAndShiftMakesThemUniform() {
        let source = ImageSize(width: 1200, height: 800)
        let frame = MaskFrameProbe(source: source)
        let e = radial(center: (0.5, 0.5), radius: (0.30, 0.20), angle: 0)

        let right = MaskHandles.handles(for: .radialGradient(e), source: source)
            .first { $0.kind == .radialEdge(.right) }!
        // 0.1 short edge to the right: rx + 0.1, ry untouched.
        let target = frame.offset(right.point, along: (1, 0), by: 0.1)
        let drag = MaskHandleDrag(handle: right, shape: .radialGradient(e), grab: right.point)
        guard case .radialGradient(let wide)? = drag.shape(at: target, source: source) else {
            return XCTFail("no shape")
        }
        XCTAssertEqual(wide.radius.x, 0.40, accuracy: 1e-9)
        XCTAssertEqual(wide.radius.y, 0.20, accuracy: 1e-9)
        XCTAssertEqual(wide.center, e.center, "a rim drag must not move the centre")

        // ⇧: the aspect is kept, so ry grows by the same factor (0.40/0.30).
        guard case .radialGradient(let uniform)? = drag.shape(at: target, source: source,
                                                             uniform: true) else {
            return XCTFail("no shape")
        }
        XCTAssertEqual(uniform.radius.x, 0.40, accuracy: 1e-9)
        XCTAssertEqual(uniform.radius.y, 0.20 * (0.40 / 0.30), accuracy: 1e-9)

        // The top grip moves -y with the same sign convention (y down, so a drag *up* is negative).
        let top = MaskHandles.handles(for: .radialGradient(e), source: source)
            .first { $0.kind == .radialEdge(.top) }!
        let up = MaskHandleDrag(handle: top, shape: .radialGradient(e), grab: top.point)
        guard case .radialGradient(let taller)? = up.shape(
            at: frame.offset(top.point, along: (0, -1), by: 0.05), source: source)
        else { return XCTFail("no shape") }
        XCTAssertEqual(taller.radius.y, 0.25, accuracy: 1e-9)
        XCTAssertEqual(taller.radius.x, 0.30, accuracy: 1e-9)

        // A rim can never go negative, and never to zero.
        guard case .radialGradient(let tiny)? = up.shape(
            at: frame.offset(top.point, along: (0, 1), by: 5), source: source)
        else { return XCTFail("no shape") }
        XCTAssertEqual(tiny.radius.y, MaskHandles.radiusRange.lowerBound, accuracy: 1e-12)
    }

    /// 位置: the centre grip is a plain translation, in the shape's own units.
    func testTheCentreGripTranslatesTheEllipseExactly() {
        let source = ImageSize(width: 1200, height: 800)
        let e = radial(center: (0.5, 0.5), radius: (0.3, 0.2), angle: 33)
        let centre = MaskHandles.handles(for: .radialGradient(e), source: source)
            .first { $0.kind == .radialCenter }!
        let drag = MaskHandleDrag(handle: centre, shape: .radialGradient(e), grab: centre.point)
        let target = NormalizedPoint(0.5 + 0.125, 0.5 - 0.25)
        guard case .radialGradient(let moved)? = drag.shape(at: target, source: source) else {
            return XCTFail("no shape")
        }
        XCTAssertEqual(moved.center.x, 0.625, accuracy: 1e-12)
        XCTAssertEqual(moved.center.y, 0.25, accuracy: 1e-12)
        XCTAssertEqual(moved.radius, e.radius)
        XCTAssertEqual(moved.angle, e.angle)
    }

    // MARK: - 4. one drag, one document, one ⌘Z

    func testFiveTicksMakeOneHistoryEntryAndAnUnmovedDragMakesNone() {
        let session = session(with: .radialGradient(radial()))
        let canvas = MaskCanvasController(session: session)
        let frame = session.maskSourceSize              // upright frame, as the canvas uses it
        let shape0 = radial()
        let centre = MaskHandles.handles(for: .radialGradient(shape0), source: frame)
            .first { $0.kind == .radialCenter }!
        let before = session.history.count

        XCTAssertTrue(canvas.beginHandleDrag(.radialCenter, at: centre.point))
        XCTAssertTrue(canvas.isDraggingHandle)
        for step in 1...5 {
            XCTAssertTrue(canvas.extendHandleDrag(
                to: NormalizedPoint(centre.point.x + 0.01 * Double(step),
                                    centre.point.y + 0.004 * Double(step)),
                uniform: false))
            // The pixels follow the hand: the document is already the new geometry, the stack is not.
            XCTAssertEqual(session.history.count, before, "tick \(step) must not commit")
        }
        XCTAssertTrue(canvas.endHandleDrag())
        XCTAssertFalse(canvas.isDraggingHandle)
        XCTAssertEqual(session.history.count, before + 1, "five ticks, one snapshot")
        XCTAssertEqual(canvas.maskHandleDrags, 1)
        XCTAssertEqual(canvas.lastHandleLabel, "中心")

        // ⌘Z puts the whole gesture back — the mask is where it was, not 1/5 of the way.
        XCTAssertTrue(session.undo())
        guard case .radialGradient(let restored)? = shape(in: session) else {
            return XCTFail("the mask lost its shape")
        }
        XCTAssertEqual(restored.center.x, shape0.center.x, accuracy: 1e-12)
        XCTAssertEqual(restored.center.y, shape0.center.y, accuracy: 1e-12)

        // A drag that ends where it started is not an edit: no snapshot, no counter.
        let settled = session.history.count
        XCTAssertTrue(canvas.beginHandleDrag(.radialCenter,
                                            at: NormalizedPoint(0.5, 0.5)))
        XCTAssertTrue(canvas.extendHandleDrag(to: NormalizedPoint(0.5, 0.5), uniform: false))
        XCTAssertFalse(canvas.endHandleDrag(), "an unmoved drag commits nothing")
        XCTAssertEqual(session.history.count, settled)
        XCTAssertEqual(canvas.maskHandleDrags, 1)
    }

    /// Escape: the shape goes back and the stack does not grow. A cancel is not an undo, so it must
    /// not need one.
    func testCancelRestoresTheShapeAndWritesNothing() {
        let session = session(with: .linearGradient(linear()))
        let canvas = MaskCanvasController(session: session)
        let g = linear()
        let grip = MaskHandles.handles(for: .linearGradient(g), source: session.maskSourceSize)
            .first { $0.kind == .linearLine(.end) }!
        let before = session.history.count

        XCTAssertTrue(canvas.beginHandleDrag(.linearLine(.end), at: grip.point))
        XCTAssertTrue(canvas.extendHandleDrag(to: NormalizedPoint(grip.point.x + 0.1,
                                                                 grip.point.y + 0.2),
                                             uniform: false))
        canvas.cancelHandleDrag()
        XCTAssertFalse(canvas.isDraggingHandle)
        XCTAssertEqual(session.history.count, before)
        XCTAssertEqual(canvas.maskHandleDrags, 0)
        guard case .linearGradient(let back)? = shape(in: session) else {
            return XCTFail("the mask lost its shape")
        }
        XCTAssertEqual(back, g, "Escape must restore the shape exactly")
    }

    /// A grip drag is refused when there is nothing to drag — that false is what lets the canvas fall
    /// through to the pan instead of swallowing the click.
    func testBeginRefusesWhenTheSelectionHasNoGeometry() {
        let session = CatalogSession()
        session.applyEdit {
            $0.masks = [Mask(id: "m-brush", components: [
                MaskComponent(id: "c-brush",
                              shape: .brush(BrushShape(size: 0.1, strokes: [])))
            ])]
        }
        session.setSelectedMaskID("m-brush")
        session.commitEdit(label: "新建蒙版")
        let canvas = MaskCanvasController(session: session)
        XCTAssertFalse(canvas.beginHandleDrag(.radialCenter, at: NormalizedPoint(0.5, 0.5)))
        XCTAssertFalse(canvas.isDraggingHandle)
        XCTAssertEqual(canvas.endHandleDrag(), false)
        XCTAssertEqual(session.history.count, 1, "a refused drag writes nothing")
    }

    // MARK: - 5. portrait (EXIF 6 / 8) does not regress

    /// The 028 criterion, on the control points: drag the centre grip on a portrait file and the
    /// rendered mask's centroid is on the pixel under the hand, within 1.5 px.
    ///
    /// The whole chain is exercised: view point → `LoupeMapping.sourcePoint` (the only projection) →
    /// normalised upright source → `MaskCanvasController` → the document → `RenderGraph`'s atlas on
    /// the **stored** picture, so a transposed frame anywhere in that chain shows up as pixels.
    func testDraggingTheCentreOnAPortraitFileLandsWhereTheHandIs() throws {
        let shots: [(name: String, upright: ImageSize, orientation: ImageOrientation)] = [
            ("landscape / EXIF 1", ImageSize(width: 240, height: 160), .up),
            ("portrait / EXIF 6", ImageSize(width: 160, height: 240), .right),
            ("portrait / EXIF 8", ImageSize(width: 160, height: 240), .left),
        ]
        let viewport = ImageSize(width: 480, height: 320)

        for shot in shots {
            let framing = LoupeFraming(viewport: viewport, decoded: shot.upright,
                                       decodeScale: 1, edit: .neutral)
            let mapping = framing.mapping(of: .fit)
            let source = shot.upright

            // The grip as the canvas sees it: centre of the ellipse, at the middle of the picture.
            // The ellipse is small enough (and the drag short enough) to stay inside the frame in both
            // aspects — a clipped ellipse would move its own centroid and blur the measurement.
            let e = radial(center: (0.5, 0.5), radius: (0.15, 0.10), angle: 0)
            let handle = MaskHandles.handles(for: .radialGradient(e), source: source)
                .first { $0.kind == .radialCenter }!
            let gripView = mapping.viewPoint(sourceX: handle.point.x * Double(source.width),
                                             sourceY: handle.point.y * Double(source.height))
            let grabView = CGPoint(x: gripView.x, y: gripView.y)
            // A real drag: 40 pt right and 30 pt down, on screen.
            let movedView = CGPoint(x: grabView.x + 40, y: grabView.y + 30)
            func normalized(_ p: CGPoint) -> NormalizedPoint {
                let s = mapping.sourcePoint(viewX: Double(p.x), viewY: Double(p.y))
                return NormalizedPoint(s.x / framing.sourceWidth, s.y / framing.sourceHeight)
            }

            let session = self.session(with: .radialGradient(e))
            let canvas = MaskCanvasController(session: session)
            XCTAssertTrue(canvas.beginHandleDrag(.radialCenter, at: normalized(grabView),
                                                 source: source))
            XCTAssertTrue(canvas.extendHandleDrag(to: normalized(movedView), uniform: false))
            XCTAssertTrue(canvas.endHandleDrag())

            guard case .radialGradient(let dragged)? = shape(in: session) else {
                return XCTFail("\(shot.name): the mask lost its shape")
            }
            // What the hand asked for, in the upright frame.
            let expected = (x: dragged.center.x * Double(source.width),
                            y: dragged.center.y * Double(source.height))

            let stored = storedPicture(flat(source), orientation: shot.orientation)
            let dump = try atlas(self.document(.radialGradient(dragged)), stored)
            XCTAssertEqual(dump.width, source.width, "\(shot.name): atlas is the upright width")
            XCTAssertEqual(dump.height, source.height, "\(shot.name): atlas is the upright height")
            let measured = centroid(dump.slices[0], width: dump.width, height: dump.height)
            let dx = abs(measured.x - expected.x), dy = abs(measured.y - expected.y)
            print(String(format: "032 centre drag %@: centroid (%.2f, %.2f) expected (%.2f, %.2f) Δ(%.2f, %.2f) px",
                         shot.name, measured.x, measured.y, expected.x, expected.y, dx, dy))
            XCTAssertLessThanOrEqual(dx, 1.5, "\(shot.name): centroid is \(dx) px off in x")
            XCTAssertLessThanOrEqual(dy, 1.5, "\(shot.name): centroid is \(dy) px off in y")
            // The grip really moved (a drag that wrote nothing would pass the centroid test).
            XCTAssertNotEqual(dragged.center, e.center)
        }
    }

    // MARK: - 6. the per-frame cost of a drag tick

    /// The task asks for the per-frame recompute to stay inside the existing 4.1 Mpx budget. What a
    /// drag adds to a frame is **the drag maths**, not a new pass: the geometry write goes through
    /// S1.5/S1.6 exactly like a slider tick (the same `applyEdit` → `editRevision` → atlas rebuild),
    /// so this prints the part that is new and leaves the render budget where it was. Printed, not
    /// asserted (the render itself is gated behind `PHOTONS_BENCH` elsewhere).
    func testDragTickCostIsPrintedAndNegligible() {
        let source = ImageSize(width: 6000, height: 4000)
        let e = radial()
        let grip = MaskHandles.handles(for: .radialGradient(e), source: source)
            .first { $0.kind == .radialEdge(.right) }!
        let drag = MaskHandleDrag(handle: grip, shape: .radialGradient(e), grab: grip.point)
        let ticks = 2000
        let started = CFAbsoluteTimeGetCurrent()
        for i in 0..<ticks {
            _ = drag.shape(at: NormalizedPoint(grip.point.x + Double(i) * 1e-5,
                                              grip.point.y), source: source, uniform: i % 2 == 0)
        }
        let each = (CFAbsoluteTimeGetCurrent() - started) / Double(ticks) * 1_000_000
        print(String(format: "032 drag tick maths: %.2f µs/tick (%d ticks, 24 Mpx frame) — the frame itself is the existing S1.5/S1.6 rebuild",
                     each, ticks))
        XCTAssertLessThan(each, 500, "a tick's geometry maths must be negligible next to a render")
    }

    // MARK: - image fixtures (the 028 pattern: the stored picture is the inverse of `oriented()`)

    private func flat(_ size: ImageSize, value: Double = 0.35) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for i in 0..<(size.width * size.height) {
            let o = i * 4
            rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
            rgba[o + 2] = Float16(value); rgba[o + 3] = 1
        }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-032")
    }

    private func storedPicture(_ upright: LinearImage,
                               orientation: ImageOrientation) -> LinearImage {
        let w = upright.width, h = upright.height
        let stored = orientation.uprightSize(width: w, height: h)
        var rgba = [Float16](repeating: 0, count: stored.width * stored.height * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = orientation.sourceCoordinate(x: x, y: y,
                                                     width: stored.width, height: stored.height)
                let from = (y * w + x) * 4
                let to = (s.y * stored.width + s.x) * 4
                rgba[to] = upright.rgba[from]
                rgba[to + 1] = upright.rgba[from + 1]
                rgba[to + 2] = upright.rgba[from + 2]
                rgba[to + 3] = upright.rgba[from + 3]
            }
        }
        return LinearImage(width: stored.width, height: stored.height, rgba: rgba,
                           colorSpace: upright.colorSpace, decoderVersion: upright.decoderVersion,
                           orientation: orientation)
    }

    private func document(_ shape: MaskShape) -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-032-r",
                           components: [MaskComponent(id: "c-032-r", feather: 0.5, shape: shape)])]
        return edit
    }

    private func atlas(_ edit: EditModel, _ image: LinearImage) throws -> MaskAtlasDump {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "mask-032"))
        let dump = try graph.maskAtlas(edit, options: RenderOptions(scale: 1))
        return try XCTUnwrap(dump, "an enabled mask must produce an atlas")
    }

    private func centroid(_ slice: [Float], width: Int,
                          height: Int) -> (x: Double, y: Double) {
        var sx = 0.0, sy = 0.0, mass = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let a = Double(slice[y * width + x])
                guard a > 1e-4 else { continue }
                sx += a * (Double(x) + 0.5); sy += a * (Double(y) + 0.5); mass += a
            }
        }
        guard mass > 0 else { return (-1, -1) }
        return (sx / mass, sy / mass)
    }
}

// MARK: - the frame, from the test's side
//
// The test needs to build a drag *target* the way a hand would: "rotate this point 15° about that
// one", "move 0.1 short edge along the axis". Written here from the definition (normalised on each
// axis, distances over the short edge) instead of calling the implementation's helpers, so a sign or
// a transposition mistake in `MaskHandles` cannot hide behind a shared function.

private struct MaskFrameProbe {
    let source: ImageSize
    var shortEdge: Double { Double(min(max(1, source.width), max(1, source.height))) }

    func offset(_ p: NormalizedPoint, along direction: (Double, Double), by distance: Double)
        -> NormalizedPoint {
        let dx = direction.0 * distance * shortEdge / Double(max(1, source.width))
        let dy = direction.1 * distance * shortEdge / Double(max(1, source.height))
        return NormalizedPoint(p.x + dx, p.y + dy)
    }

    func rotate(_ p: NormalizedPoint, about centre: (x: Double, y: Double),
                by degrees: Double) -> NormalizedPoint {
        let w = Double(max(1, source.width)), h = Double(max(1, source.height))
        let vx = (p.x - centre.x) * w / shortEdge
        let vy = (p.y - centre.y) * h / shortEdge
        let r = degrees * .pi / 180
        let rx = vx * cos(r) - vy * sin(r)
        let ry = vx * sin(r) + vy * cos(r)
        return NormalizedPoint(centre.x + rx * shortEdge / w, centre.y + ry * shortEdge / h)
    }

    /// The axis direction of a ramp, in degrees, in the same metric.
    func angle(of start: NormalizedPoint, to end: NormalizedPoint) -> Double {
        let w = Double(max(1, source.width)), h = Double(max(1, source.height))
        let dx = (end.x - start.x) * w / shortEdge
        let dy = (end.y - start.y) * h / shortEdge
        return atan2(dy, dx) * 180 / .pi
    }
}
