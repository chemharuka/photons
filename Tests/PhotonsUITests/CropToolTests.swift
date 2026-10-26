import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// Task 035 — 旋转/裁切, the **interaction layer**: a frame you can drag, handles that resize it, a
/// straighten you can dial or drag, an aspect lock, two flips, a thirds grid, and ↵/Esc.
///
/// Five things are pinned here, each from the side a user would notice:
///
///   1. **The frame is the projection.** `CropTool.layout` is `LoupeMapping` applied to the draft
///      rect and nothing else, so at 25 %, 100 % and 400 % the same grip is in the same place and the
///      hit radius is the same number of **points**. Corners beat edges, an inside click pans the
///      picture, an outside click builds a new frame.
///   2. **What the drag means.** A corner moves two edges, an edge moves one, a locked drag keeps the
///      pixel ratio with the opposite corner pinned, a preset switch keeps the centre and the area,
///      and replaying the same points gives the same rect (no drift, no ratchet).
///   3. **Geometry round-trip.** The rect a drag produces, rendered through S0 at 1:1, is a picture
///      whose content size is that rect in pixels — so the box on screen is the picture that gets
///      committed, not a number that happens to look right.
///   4. **One apply = one ⌘Z, Esc = none.** Dragging never touches the document; 应用 writes it once
///      and commits once; Escape leaves `editRevision`, the history and the document bytes untouched.
///   5. **Mode isolation.** While the tool is on, `gestureOwner` answers `.cropTool` for every point
///      and every click count — no pan, no mask grip, no brush, no eyedropper — and the answer comes
///      back when it is off.
@MainActor
final class CropToolTests: XCTestCase {

    // MARK: - fixtures

    private let viewport = ImageSize(width: 800, height: 600)
    private let landscape = ImageSize(width: 1200, height: 800)

    private func framing(source: ImageSize, crop: CropRect = .full, straighten: Double = 0,
                         flipH: Bool = false, flipV: Bool = false,
                         viewport: ImageSize? = nil) -> LoupeFraming {
        LoupeFraming(viewport: viewport ?? self.viewport,
                     sourceWidth: Double(source.width),
                     sourceHeight: Double(source.height),
                     crop: crop,
                     straightenDegrees: straighten,
                     flipH: flipH,
                     flipV: flipV)
    }

    /// View point of a normalized source point, in the fit camera — the exact call the overlay makes.
    private func viewPoint(_ framing: LoupeFraming, _ u: Double, _ v: Double,
                           state: LoupeViewState = .fit) -> CGPoint {
        let p = framing.viewPoint(of: state,
                                  sourceX: u * framing.sourceWidth,
                                  sourceY: v * framing.sourceHeight,
                                  backingScale: 1)
        return CGPoint(x: p.x, y: p.y)
    }

    private func normalized(_ framing: LoupeFraming, _ point: CGPoint,
                            state: LoupeViewState = .fit) -> NormalizedPoint {
        let p = framing.sourcePoint(of: state, viewX: Double(point.x), viewY: Double(point.y),
                                    backingScale: 1)
        return NormalizedPoint(p.x / framing.sourceWidth, p.y / framing.sourceHeight)
    }

    private func layout(_ crop: CropRect, source: ImageSize,
                        framing f: LoupeFraming, grid: Bool = true) -> CropToolLayout {
        CropTool.layout(crop: crop, source: source, mapping: f.mapping(of: .fit), showsGrid: grid)
    }

    // MARK: - 1. the frame is the projection

    /// Eight grips on the frame, four thirds lines, and a hit test that names the grip it drew.
    func testTheFrameDrawsItsEightGripsAndHitsThem() {
        let crop = CropRect(x: 0.2, y: 0.15, width: 0.5, height: 0.6)
        let f = framing(source: landscape)
        let layout = layout(crop, source: landscape, framing: f)

        XCTAssertEqual(layout.grips.count, 8, "four corners and four edges")
        XCTAssertEqual(layout.corners.count, 4)
        XCTAssertEqual(layout.grid.count, 4, "rule of thirds: two vertical, two horizontal")

        // Every grip is where the mapping puts its own edge or corner — not a pixel off.
        let expected: [CropToolHandle: CGPoint] = [
            .topLeft: viewPoint(f, 0.2, 0.15),
            .topRight: viewPoint(f, 0.7, 0.15),
            .bottomRight: viewPoint(f, 0.7, 0.75),
            .bottomLeft: viewPoint(f, 0.2, 0.75),
            .top: viewPoint(f, 0.45, 0.15),
            .right: viewPoint(f, 0.7, 0.45),
            .bottom: viewPoint(f, 0.45, 0.75),
            .left: viewPoint(f, 0.2, 0.45),
        ]
        for grip in layout.grips {
            let want = expected[grip.kind]
            XCTAssertNotNil(want)
            XCTAssertEqual(grip.point.x, want!.x, accuracy: 0.001, "\(grip.kind.label) x")
            XCTAssertEqual(grip.point.y, want!.y, accuracy: 0.001, "\(grip.kind.label) y")
            XCTAssertEqual(CropTool.hit(grip.point, in: layout), grip.kind,
                           "the grip that was drawn at \(grip.kind.label) must take the click")
        }

        // Inside is inside, outside is outside, and neither is mistaken for a grip.
        XCTAssertEqual(CropTool.hit(viewPoint(f, 0.45, 0.45), in: layout), .inside)
        XCTAssertEqual(CropTool.hit(viewPoint(f, 0.05, 0.05), in: layout), .outside)
        // A point just inside the frame, far from every grip.
        XCTAssertEqual(CropTool.hit(viewPoint(f, 0.25, 0.5), in: layout), .inside)
    }

    /// The hit target is a constant number of **points**: the same 12 pt at 25 %, 100 % and 400 %.
    ///
    /// This is the criterion Brightroom's guide view is built around (a fixed inflation around each
    /// control point), and the failure it prevents is a corner that becomes impossible to grab at one
    /// zoom and swallows half the frame at another.
    func testTheHitRadiusIsTheSameOnScreenAtEveryZoom() {
        let crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        for zoom in [0.25, 1.0, 4.0] {
            let f = framing(source: landscape)
            let state = LoupeViewState(mode: .actual, zoom: zoom,
                                       centerX: Double(landscape.width) / 2,
                                       centerY: Double(landscape.height) / 2)
            let layout = CropTool.layout(crop: crop, source: landscape,
                                         mapping: f.mapping(of: state))
            let corner = layout.grips.first { $0.kind == .topLeft }!.point

            // 10 pt away is inside the 12 pt target, 14 pt is outside it, at every zoom.
            let near = CGPoint(x: corner.x + 10, y: corner.y)
            let far = CGPoint(x: corner.x + 14, y: corner.y)
            XCTAssertEqual(CropTool.hit(near, in: layout), .topLeft, "10 pt at \(zoom)× is a hit")
            XCTAssertNotEqual(CropTool.hit(far, in: layout), .topLeft,
                              "14 pt at \(zoom)× must not be a hit")
            print(String(format: "035 hit radius: zoom %.2f, corner (%.1f, %.1f), 10 pt → hit, 14 pt → miss",
                         zoom, corner.x, corner.y))
        }
    }

    /// A straightened frame is still a frame: the quad turns with the picture and the grips stay on
    /// its corners.
    ///
    /// The angle is **S0's**: it rotates in normalized (y-up) crop space, so a document angle θ
    /// appears on a y-down canvas as `−atan(tan θ · H / W)`. Two facts follow, and both are pinned
    /// here: the magnitude is not θ (12° in the document is 8.07° of screen rotation on a 3:2 frame),
    /// and a positive document angle reads **counter-clockwise** on the canvas — which is why the
    /// rotate gesture (`CropTool.straighten`) has to hand a clockwise drag a negative angle.
    func testAStraightenedFrameTurnsWithThePicture() {
        let crop = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let f = framing(source: landscape, straighten: 12)
        let layout = layout(crop, source: landscape, framing: f)
        let topLeft = layout.corners[0]
        let topRight = layout.corners[1]
        let angle = atan2(Double(topRight.y - topLeft.y), Double(topRight.x - topLeft.x)) * 180 / .pi
        let expected = -atan(tan(12 * Double.pi / 180)
                             * Double(landscape.height) / Double(landscape.width)) * 180 / .pi
        print(String(format: "035 straighten frame: 12° in the document is %.3f° on screen (want %.3f°)",
                     angle, expected))
        XCTAssertEqual(angle, expected, accuracy: 0.01, "the frame turns with the picture, S0's way")
        XCTAssertGreaterThan(abs(angle - 12), 1, "the kernel rotates in normalized space, not on screen")
        // And the quad is still hit-testable: its centre is inside it.
        XCTAssertTrue(CropTool.contains(layout.center, in: layout))
    }

    // MARK: - 2. what the drag means

    /// A corner moves its two edges, an edge moves one, and the opposite side never budges.
    func testCornersMoveTwoEdgesAndEdgesMoveOne() {
        let crop = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let source = landscape
        let f = framing(source: source)

        // Bottom-right corner dragged by (−0.1, −0.05): only right and bottom move.
        let cornerDrag = CropToolDrag(handle: .bottomRight, crop: crop,
                                      grab: normalized(f, viewPoint(f, 0.8, 0.8)))
        let cornerEnd = normalized(f, viewPoint(f, 0.7, 0.75))
        let corner = cornerDrag.crop(at: cornerEnd, source: source)
        XCTAssertEqual(corner.left, 0.2, accuracy: 1e-9)
        XCTAssertEqual(corner.top, 0.2, accuracy: 1e-9)
        XCTAssertEqual(corner.right, 0.7, accuracy: 1e-6)
        XCTAssertEqual(corner.bottom, 0.75, accuracy: 1e-6)

        // The right edge dragged by (−0.1, any y): only right moves.
        let edgeDrag = CropToolDrag(handle: .right, crop: crop,
                                    grab: normalized(f, viewPoint(f, 0.8, 0.5)))
        let edge = edgeDrag.crop(at: normalized(f, viewPoint(f, 0.7, 0.1)), source: source)
        XCTAssertEqual(edge.left, 0.2, accuracy: 1e-9)
        XCTAssertEqual(edge.top, 0.2, accuracy: 1e-9)
        XCTAssertEqual(edge.bottom, 0.8, accuracy: 1e-9)
        XCTAssertEqual(edge.right, 0.7, accuracy: 1e-6)
    }

    /// 框内拖动 = 平移画面: the kept region travels **against** the hand (the picture follows it), and
    /// it stops at the frame's edge instead of leaving the source.
    func testDraggingInsidePansThePictureAndClampsAtTheEdge() {
        let crop = CropRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let source = landscape
        let drag = CropToolDrag(handle: .inside, crop: crop,
                                grab: NormalizedPoint(0.5, 0.5))
        // Hand moves +0.1 in x: the kept window moves −0.1, so the picture appears to move +0.1.
        let moved = drag.crop(at: NormalizedPoint(0.6, 0.5), source: source)
        XCTAssertEqual(moved.left, 0.2, accuracy: 1e-9)
        XCTAssertEqual(moved.width, 0.4, accuracy: 1e-9, "a pan never resizes the frame")
        XCTAssertEqual(moved.top, 0.3, accuracy: 1e-9)

        // Dragged far past the left edge: it stops with the whole frame inside the source.
        let clamped = drag.crop(at: NormalizedPoint(2.0, 2.0), source: source)
        XCTAssertEqual(clamped.left, 0, accuracy: 1e-9)
        XCTAssertEqual(clamped.top, 0, accuracy: 1e-9)
        XCTAssertEqual(clamped.width, 0.4, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(clamped.right, 1 + 1e-9)
        XCTAssertLessThanOrEqual(clamped.bottom, 1 + 1e-9)
    }

    /// 框外拖动 = 新建框: the two coordinates are ordered, so every drag direction builds a frame.
    func testDraggingOutsideBuildsANewFrameInAnyDirection() {
        let source = landscape
        let f = framing(source: source)
        let base = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        // Grab outside the frame at (0.05, 0.1), drag to (0.55, 0.65).
        let drag = CropToolDrag(handle: .outside, crop: base,
                                grab: NormalizedPoint(0.05, 0.1))
        let built = drag.crop(at: NormalizedPoint(0.55, 0.65), source: source)
        XCTAssertEqual(built.left, 0.05, accuracy: 1e-9)
        XCTAssertEqual(built.top, 0.1, accuracy: 1e-9)
        XCTAssertEqual(built.right, 0.55, accuracy: 1e-6)
        XCTAssertEqual(built.bottom, 0.65, accuracy: 1e-6)
        _ = f

        // The same two points grabbed the other way round give the same frame.
        let reversed = CropToolDrag(handle: .outside, crop: base,
                                    grab: NormalizedPoint(0.55, 0.65))
            .crop(at: NormalizedPoint(0.05, 0.1), source: source)
        XCTAssertEqual(reversed.keyString, built.keyString)
    }

    /// 比例锁: a locked drag keeps the **pixel** ratio (not the normalized one) and pins the opposite
    /// corner, which is what stops a 1:1 frame creeping while the hand is on it.
    func testALockedDragKeepsThePixelRatioAndPinsTheOppositeCorner() {
        let source = ImageSize(width: 1200, height: 800)   // 3:2
        let base = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let drag = CropToolDrag(handle: .bottomRight, crop: base, grab: NormalizedPoint(0.8, 0.8))
        let rect = drag.crop(at: NormalizedPoint(0.9, 0.62), source: source, lock: .square)

        let pixels = CropMath.outputSize(rect, in: source)
        let ratio = Double(pixels.width) / Double(pixels.height)
        print(String(format: "035 locked drag: %dx%d px, ratio %.5f", pixels.width, pixels.height, ratio))
        XCTAssertEqual(ratio, 1.0, accuracy: 1e-3, "1:1 is 1:1 in pixels, not in normalized units")
        // The anchor corner (top-left, 0.2/0.2) is untouched.
        XCTAssertEqual(rect.left, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rect.top, 0.2, accuracy: 1e-9)
        // And it stays inside the frame.
        XCTAssertLessThanOrEqual(rect.right, 1 + 1e-9)
        XCTAssertLessThanOrEqual(rect.bottom, 1 + 1e-9)
    }

    /// 比例 presets: 原始 / 1:1 / 4:3 / 3:2 / 16:9 / 自由 — switching keeps the centre and the area.
    func testASwitchKeepsTheCentreAndTheArea() {
        let source = ImageSize(width: 1200, height: 800)
        let crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let area = crop.width * crop.height

        for preset in [CropAspectPreset.square, .fourThree, .sixteenNine] {
            let lock = preset.lock(source: source)
            let next = CropTool.matching(lock, crop: crop, source: source)
            // The ratio that renders is the ratio of the rect in *pixels*, before rounding.
            let rendered = (next.width * Double(source.width)) / (next.height * Double(source.height))
            let pixels = CropMath.outputSize(next, in: source)
            print(String(format: "035 preset %@: rect ratio %.5f (want %.5f), %dx%d px, area %.4f (was %.4f)",
                         preset.displayName, rendered, lock.ratio ?? 0,
                         pixels.width, pixels.height, next.width * next.height, area))
            XCTAssertEqual(rendered, try XCTUnwrap(lock.ratio), accuracy: 1e-9,
                           "\(preset.displayName) must render at its own ratio")
            // …and the whole-pixel crop the renderer allocates is that rect, within a pixel.
            XCTAssertLessThanOrEqual(abs(Double(pixels.width) - next.width * Double(source.width)), 1)
            XCTAssertLessThanOrEqual(abs(Double(pixels.height) - next.height * Double(source.height)), 1)
            XCTAssertEqual(next.centerX, crop.centerX, accuracy: 1e-9, "the centre is kept")
            XCTAssertEqual(next.centerY, crop.centerY, accuracy: 1e-9)
            XCTAssertEqual(next.width * next.height, area, accuracy: 1e-3,
                           "\(preset.displayName) keeps the area (it fits this frame)")
            XCTAssertGreaterThanOrEqual(next.left, -1e-9)
            XCTAssertLessThanOrEqual(next.right, 1 + 1e-9)
        }

        // 原始 is the sensor's own ratio; 自由 is the document's "no constraint" spelling.
        XCTAssertEqual(CropAspectPreset.original.lock(source: source), .threeTwo)
        XCTAssertEqual(CropAspectPreset.free.lock(source: source), .original)
        // A frame that is not a named ratio still round-trips through 原始.
        let odd = ImageSize(width: 1000, height: 700)
        let oddLock = CropAspectPreset.original.lock(source: odd)
        XCTAssertEqual(CropAspectPreset(lock: oddLock, source: odd), .original)
        XCTAssertEqual(CropAspectPreset(lock: .fourThree, source: odd), .fourThree)
    }

    /// A drag cannot drift (absolute, not incremental) and a clamped edge cannot ratchet.
    func testADragCannotDriftOrRatchet() {
        let source = landscape
        let base = CropRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
        let drag = CropToolDrag(handle: .bottomRight, crop: base, grab: NormalizedPoint(0.8, 0.8))

        // Every tick is computed from the mouse-down state, so a 40-tick walk over the same point
        // gives the same rect as one jump to it — the drag is a function of "where the hand is", not
        // of "how it got here".
        let target = NormalizedPoint(0.7, 0.65)
        var last = base
        for t in stride(from: 0.0, through: 1.0, by: 0.025) {
            let point = NormalizedPoint(0.8 + (target.x - 0.8) * t,
                                        0.8 + (target.y - 0.8) * t)
            last = drag.crop(at: point, source: source)
        }
        let jumped = drag.crop(at: target, source: source)
        XCTAssertEqual(last.keyString, jumped.keyString, "a walk and a jump agree")
        XCTAssertEqual(jumped.right, 0.7, accuracy: 1e-6)
        XCTAssertEqual(jumped.bottom, 0.65, accuracy: 1e-6)

        // Past the frame and back: the value returns exactly, no ratchet.
        _ = drag.crop(at: NormalizedPoint(3.0, 3.0), source: source)
        let back = drag.crop(at: NormalizedPoint(0.7, 0.7), source: source)
        let again = drag.crop(at: NormalizedPoint(0.7, 0.7), source: source)
        XCTAssertEqual(back.keyString, again.keyString)
        XCTAssertEqual(back.right, 0.7, accuracy: 1e-6)
    }

    /// 拉直: the picture follows the hand and stops at ±45°, the document's own limit.
    ///
    /// The sign is the one the canvas actually shows: a **clockwise** hand sweep turns the picture
    /// clockwise, which in the document's normalized (y-up) angle is a *negative* number — the same
    /// convention Lightroom's Angle slider uses, and the one the straighten test above pinned for
    /// the frame.
    func testStraightenFollowsTheHandAndClampsAtTheLimit() {
        let source = ImageSize(width: 1200, height: 800)
        let centre = NormalizedPoint(0.5, 0.5)

        // The hand sweeps a quarter turn clockwise (screen y is down, so atan2 grows clockwise).
        let quarter = CropTool.straighten(0, grab: NormalizedPoint(0.9, 0.5),
                                          to: NormalizedPoint(0.5, 0.9),
                                          centre: centre, source: source)
        XCTAssertEqual(quarter, -45, accuracy: 1e-6, "a clockwise sweep, clamped at −45")

        // Counter-clockwise.
        let ccw = CropTool.straighten(0, grab: NormalizedPoint(0.5, 0.9),
                                      to: NormalizedPoint(0.9, 0.5),
                                      centre: centre, source: source)
        XCTAssertEqual(ccw, 45, accuracy: 1e-6)

        // A small sweep: the picture must turn by the hand's **screen** angle, which is what the
        // document angle reproduces once S0's normalized-space rotation is accounted for.
        let r = 250.0                                  // pixels, both axes: a screen-space circle
        let centrePx = (x: 0.5 * Double(source.width), y: 0.5 * Double(source.height))
        func onCircle(_ degrees: Double) -> NormalizedPoint {
            let a = degrees * Double.pi / 180
            return NormalizedPoint((centrePx.x + r * cos(a)) / Double(source.width),
                                   (centrePx.y + r * sin(a)) / Double(source.height))
        }
        let ten = CropTool.straighten(0, grab: onCircle(-10), to: onCircle(0),
                                      centre: centre, source: source)
        // What that document angle puts on screen: the picture turns by −atan(tan θ · H / W).
        let onScreen = -atan(tan(ten * Double.pi / 180) * Double(source.height)
                             / Double(source.width)) * 180 / .pi
        print(String(format: "035 straighten: hand swept 10° clockwise → document %.2f° → %.2f° on screen; quarter turn %.1f°",
                     ten, onScreen, quarter))
        XCTAssertEqual(onScreen, 10, accuracy: 0.2, "the picture follows the hand on screen")
        XCTAssertLessThan(ten, 0, "and the document angle is negative, because it is a y-up angle")

        XCTAssertEqual(CropTool.clampStraighten(90), 45)
        XCTAssertEqual(CropTool.clampStraighten(-90), -45)
        XCTAssertEqual(CropTool.clampStraighten(.nan), 0)
    }

    // MARK: - 3. geometry round-trip through S0

    private func flat(_ size: ImageSize, value: Double = 0.35) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for i in 0..<(size.width * size.height) {
            let o = i * 4
            rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
            rgba[o + 2] = Float16(value); rgba[o + 3] = 1
        }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-035")
    }

    private func graph(_ image: LinearImage, _ identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// The box you drag is the picture that renders: the crop's pixel size is the content size, and
    /// the content's aspect is the box's, inside half a pixel.
    func testTheFrameYouDragIsThePictureThatRenders() throws {
        let source = ImageSize(width: 600, height: 400)
        let f = framing(source: source)
        let base = CropRect.full
        // Drag the bottom-right corner to (0.75, 0.6) — a free frame, no lock.
        let drag = CropToolDrag(handle: .bottomRight, crop: base, grab: normalized(f, viewPoint(f, 1, 1)))
        let crop = drag.crop(at: normalized(f, viewPoint(f, 0.75, 0.6)), source: source)
            .clamped()

        var model = EditModel.neutral
        model.geometry.crop = crop.normalizedRect
        let pixels = CropMath.pixelRect(crop, in: source)
        let rendered = try graph(flat(source), "crop-035")
            .render(model, options: RenderOptions(scale: 1, useCache: false, wantsPixels: false))
        let content = rendered.content

        print("035 round-trip: crop \(crop.keyString) → pixels \(pixels.keyString) → content \(content.keyString)")
        XCTAssertEqual(Double(content.width), Double(pixels.width), accuracy: 1,
                       "the content is the crop, in pixels")
        XCTAssertEqual(Double(content.height), Double(pixels.height), accuracy: 1)

        let measured = Double(content.width) / Double(content.height)
        let expected = Double(pixels.width) / Double(pixels.height)
        // ±0.5 px on both edges is ±0.5 px on the aspect, expressed in pixels.
        XCTAssertLessThanOrEqual(abs(measured - expected) * Double(content.height), 0.5,
                                "the content's aspect is the frame's, within half a pixel")

        // The same rect walked through the tool's own document write: press on the frame's corner,
        // drag it to (0.75, 0.6), release — the draft that comes out is the pure drag's rect.
        let session = CatalogSession()
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())
        XCTAssertTrue(tool.beginDrag(atViewPoint: viewPoint(f, 1, 1),
                                     mapping: f.mapping(of: .fit), source: source))
        tool.continueDrag(atViewPoint: viewPoint(f, 0.75, 0.6),
                          mapping: f.mapping(of: .fit), source: source)
        tool.endDrag()
        XCTAssertEqual(tool.lastHandle, .bottomRight, "the press landed on the bottom-right corner")
        XCTAssertEqual(tool.draft.crop.keyString, crop.keyString,
                       "the controller's drag and the pure drag agree")
    }

    /// 翻转 reaches the document and mirrors the picture inside the same frame.
    func testFlipMirrorsThePictureInTheDocument() throws {
        let source = ImageSize(width: 64, height: 32)
        // Left half dark, right half bright.
        var rgba = [Float16](repeating: 0, count: source.width * source.height * 4)
        for y in 0..<source.height {
            for x in 0..<source.width {
                let o = (y * source.width + x) * 4
                let v: Float16 = x < source.width / 2 ? 0.05 : 0.9
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        let image = LinearImage(width: source.width, height: source.height, rgba: rgba,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-035")
        let g = try graph(image, "crop-035-flip")

        let session = CatalogSession()
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())
        tool.toggleFlipHorizontal()
        XCTAssertTrue(tool.apply())
        XCTAssertTrue(session.edit.geometry.flipHorizontal, "the flip is in the document")

        let result = try g.render(session.edit, options: RenderOptions(scale: 1, useCache: false,
                                                                     wantsPixels: true))
        if let texture = result.output { g.recycle(output: texture) }
        let out = try XCTUnwrap(result.display, "a readback was asked for")
        let w = out.width, h = out.height
        func mean(xRange: Range<Int>) -> Double {
            var total = 0.0
            var n = 0
            for y in 0..<h {
                for x in xRange {
                    let o = (y * w + x) * 4
                    total += (Double(out.rgba[o]) + Double(out.rgba[o + 1]) + Double(out.rgba[o + 2])) / 3
                    n += 1
                }
            }
            return n > 0 ? total / Double(n) : 0
        }
        let left = mean(xRange: 0..<(w / 4))
        let right = mean(xRange: (3 * w / 4)..<w)
        print(String(format: "035 flip: left %.4f, right %.4f (unflipped is left-dark)", left, right))
        XCTAssertGreaterThan(left, right, "after a horizontal flip the bright half is on the left")
    }

    // MARK: - 4. history and the untouched document

    /// Dragging writes nothing; 应用 writes once and commits once; Esc writes nothing at all.
    func testOneApplyIsOneHistoryEntryAndEscapeWritesNothing() throws {
        let source = landscape
        let f = framing(source: source)
        let session = CatalogSession()
        // A real document is opened with a baseline snapshot (`loadEditForAnchor`), which is what
        // makes the first 应用 undoable; the same floor is what "⌘Z takes the whole crop back" needs.
        session.loadEditForAnchor()
        let tool = CropToolController(session: session)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(session.edit)
        let revisionBefore = session.editRevision
        let historyBefore = session.history.snapshots.count

        XCTAssertTrue(tool.begin())
        XCTAssertTrue(tool.beginDrag(atViewPoint: viewPoint(f, 1, 1),
                                     mapping: f.mapping(of: .fit), source: source))
        for step in stride(from: 0.99, through: 0.6, by: -0.05) {
            tool.continueDrag(atViewPoint: viewPoint(f, step, step * 0.9),
                              mapping: f.mapping(of: .fit), source: source)
        }
        tool.endDrag()

        XCTAssertEqual(session.editRevision, revisionBefore, "a drag never touches the document")
        XCTAssertEqual(session.history.snapshots.count, historyBefore, "and never the history")
        XCTAssertEqual(try encoder.encode(session.edit), before, "the document is byte-identical")

        // Esc: still nothing.
        tool.cancel()
        XCTAssertEqual(tool.cancelledCount, 1)
        XCTAssertEqual(session.editRevision, revisionBefore, "Esc leaves the revision alone")
        XCTAssertEqual(session.history.snapshots.count, historyBefore)
        XCTAssertEqual(try encoder.encode(session.edit), before, "Esc leaves the document untouched")

        // ↵: one entry, one revision, and the geometry is the draft.
        XCTAssertTrue(tool.begin())
        XCTAssertTrue(tool.beginDrag(atViewPoint: viewPoint(f, 1, 1),
                                     mapping: f.mapping(of: .fit), source: source))
        tool.continueDrag(atViewPoint: viewPoint(f, 0.7, 0.7),
                          mapping: f.mapping(of: .fit), source: source)
        tool.endDrag()
        let drafted = tool.draft.crop
        XCTAssertTrue(tool.apply())
        XCTAssertEqual(tool.appliedCount, 1)
        XCTAssertEqual(session.history.snapshots.count, historyBefore + 1, "one apply = one ⌘Z")
        XCTAssertNotEqual(try encoder.encode(session.edit), before, "and the document did change")
        XCTAssertEqual(session.edit.geometry.cropRect.keyString, drafted.clamped().keyString)
        print("035 history: drag+Esc → \(historyBefore) entries, apply → \(session.history.snapshots.count)")

        // ⌘Z takes the whole crop back in one step.
        XCTAssertTrue(session.undo())
        XCTAssertEqual(try encoder.encode(session.edit), before, "one undo is the whole crop")
    }

    /// An apply that changes nothing does not grow the history (and does not lie about it).
    func testAnEmptyApplyCommitsNothing() {
        let session = CatalogSession()
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())
        XCTAssertFalse(tool.apply(), "no change, no snapshot")
        XCTAssertEqual(tool.appliedCount, 0)
        XCTAssertEqual(session.history.snapshots.count, 0)
    }

    // MARK: - 5. mode isolation

    /// In 裁切 mode the canvas belongs to the frame: every point, every click count, and every other
    /// tool disarmed. Exiting gives the canvas back.
    func testCropModeOwnsEveryCanvasGesture() {
        let session = CatalogSession()
        let loupe = LoupeController(session: session)
        loupe.canvasView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        // Before: the canvas pans.
        XCTAssertEqual(loupe.gestureOwner(atViewPoint: CGPoint(x: 400, y: 300)), .pan,
                       "with no tool armed a press pans")

        // Enter the tool through it (the menu's path needs an anchor photo; the tool itself does not).
        XCTAssertTrue(loupe.cropTool.begin())
        XCTAssertTrue(loupe.isCropToolActive)

        var pans = 0, masks = 0, crops = 0, applies = 0
        var borrowed = 0
        for x in stride(from: 0.0, through: 800.0, by: 50.0) {
            for y in stride(from: 0.0, through: 600.0, by: 50.0) {
                for clicks in [1, 2] {
                    switch loupe.gestureOwner(atViewPoint: CGPoint(x: x, y: y), clickCount: clicks) {
                    case .cropTool: crops += 1
                    case .cropToolApply: applies += 1
                    case .pan: pans += 1
                    case .maskHandle, .maskCreate, .maskShape: masks += 1
                    default: borrowed += 1
                    }
                }
            }
        }
        print("035 isolation: \(crops) crop, \(applies) apply, \(pans) pan, \(masks) mask, \(borrowed) other")
        XCTAssertEqual(pans, 0, "no press pans while the frame is up")
        XCTAssertEqual(masks, 0, "no press reaches a mask gesture while the frame is up")
        XCTAssertEqual(borrowed, 0, "and no press reaches a brush, a dropper or a zoom")
        XCTAssertEqual(crops + applies, 17 * 13 * 2, "every press (17 × 13 points × 2 click counts) is the frame's")
        XCTAssertGreaterThan(crops, 0)

        // The frame's own points really are on the frame.
        XCTAssertNotNil(loupe.cropToolLayout(), "the layout is available headlessly")

        // The double-click rule, asserted where it is decided (a double-click inside the frame
        // applies; a corner, an edge, or the outside is a drag either way).
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 2, hit: .inside), .cropToolApply)
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 1, hit: .inside), .cropTool)
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 2, hit: .bottomRight), .cropTool)
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 2, hit: .outside), .cropTool)
        XCTAssertEqual(LoupeCanvasGesture.crop(clickCount: 2, hit: nil), .cropTool)

        // Exit: the canvas pans again and no crop gesture is claimed.
        loupe.cropTool.cancel()
        XCTAssertFalse(loupe.isCropToolActive)
        XCTAssertEqual(loupe.gestureOwner(atViewPoint: CGPoint(x: 400, y: 300)), .pan)
        var after = 0
        for x in stride(from: 0.0, through: 800.0, by: 100.0) {
            for y in stride(from: 0.0, through: 600.0, by: 100.0) {
                if case .cropTool = loupe.gestureOwner(atViewPoint: CGPoint(x: x, y: y)) { after += 1 }
            }
        }
        XCTAssertEqual(after, 0, "nothing claims a crop gesture once the tool is off")
    }

    /// The tool's readout and its preview are derived, never stored: `previewEdit` shows the whole
    /// frame with the draft's straighten and flips and leaves the document's crop alone.
    func testThePreviewIsTheWholeFrameAndTheDocumentIsNotTouched() {
        let session = CatalogSession()
        session.applyEdit { $0.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5) }
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin())

        let preview = tool.previewEdit(from: session.edit)
        XCTAssertTrue(preview.geometry.cropRect.isFull, "the canvas shows the uncropped picture")
        XCTAssertEqual(preview.geometry.aspectLock, .original)
        XCTAssertEqual(session.edit.geometry.cropRect.left, 0.1, accuracy: 1e-9,
                       "and the document still holds the user's crop")

        tool.setStraighten(7.5)
        tool.toggleFlipVertical()
        let rotated = tool.previewEdit(from: session.edit)
        XCTAssertEqual(rotated.geometry.straightenDegrees, 7.5)
        XCTAssertTrue(rotated.geometry.flipVertical)
        // The draft was seeded from the document, so the readout is about the user's own frame.
        XCTAssertEqual(tool.draft.crop.left, 0.1, accuracy: 1e-9, "begin() seeds from the document")
        XCTAssertFalse(tool.sizeReadout(source: ImageSize(width: 1000, height: 1000)).isEmpty)
        // 九宫格 is a toggle and stays out of the document entirely.
        XCTAssertTrue(tool.showsGrid)
        tool.toggleGrid()
        XCTAssertFalse(tool.showsGrid)
        XCTAssertEqual(session.edit.geometry.cropRect.left, 0.1, accuracy: 1e-9)
    }

    // MARK: - 6. the shortcuts

    /// 进入 ⌘R / 应用 ⌘⏎ / 取消 ⌘. — and none of them collides with an existing menu item.
    func testTheCropShortcutsDoNotCollideWithTheMenu() {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        var entries: [(key: String, modifiers: UInt, title: String)] = []

        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    entries.append((item.keyEquivalent, item.keyEquivalentModifierMask.rawValue,
                                    "\(menu.title)/\(item.title)"))
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)

        let ours: Set<String> = ["r", "\r", "."]
        let collisions = entries.filter { ours.contains($0.key) && $0.modifiers == 1 << 20 } // ⌘
            .map { "\($0.title)" }
        print("035 shortcuts: ⌘R / ⌘⏎ / ⌘. · menu items with those keys: \(collisions)")
        XCTAssertEqual(collisions.count, 3, "exactly our three items carry ⌘R, ⌘⏎ and ⌘.")

        // Nothing else in the menu uses a bare ⌘R, ⌘⏎ or ⌘. .
        let others = entries.filter { ours.contains($0.key) && !$0.title.contains("裁切") }
        XCTAssertTrue(others.isEmpty, "a shortcut the menu already had: \(others.map(\.title))")

        // The three actions exist on the responder chain's owner, so the items can fire.
        let window = EditorWindowController()
        XCTAssertTrue(window.responds(to: #selector(EditorWindowController.toggleCropAction(_:))))
        XCTAssertTrue(window.responds(to: #selector(EditorWindowController.applyCropAction(_:))))
        XCTAssertTrue(window.responds(to: #selector(EditorWindowController.cancelCropAction(_:))))
    }
}

// MARK: - portrait

/// Task 035 on a file the camera wrote vertically (EXIF 6/8, stored 240×160, upright 160×240).
///
/// The crop tool has one frame authority — `CatalogSession.maskSourceSize`, the upright frame the
/// renderer ingested — and one projection (`LoupeMapping`). This test drives the whole chain the way
/// a drag does (view point → `LoupeMapping.sourcePoint` → `CropToolDrag` → the document) and measures
/// the corner that comes back: **under 1.5 px**, which is the budget 028 set for the mask grips.
///
/// The second half shows what measuring with the catalogue's stored dimensions would do, so the test
/// fails loudly if anyone ever swaps the frame back.
@MainActor
final class CropToolPortraitProjectionTests: XCTestCase {

    private struct Shot {
        let name: String
        let upright: ImageSize
        let orientation: ImageOrientation
        var stored: ImageSize {
            let s = orientation.uprightSize(width: upright.width, height: upright.height)
            return ImageSize(width: s.width, height: s.height)
        }
    }

    private let viewport = ImageSize(width: 480, height: 320)

    private func shots() -> [Shot] {
        [
            Shot(name: "landscape / EXIF 1", upright: ImageSize(width: 160, height: 240), orientation: .up),
            Shot(name: "portrait / EXIF 6", upright: ImageSize(width: 160, height: 240), orientation: .right),
            Shot(name: "portrait / EXIF 8", upright: ImageSize(width: 160, height: 240), orientation: .left),
        ]
    }

    private func framing(_ frame: ImageSize) -> LoupeFraming {
        LoupeFraming(viewport: viewport, sourceWidth: Double(frame.width),
                     sourceHeight: Double(frame.height))
    }

    private func viewPoint(_ framing: LoupeFraming, _ u: Double, _ v: Double) -> CGPoint {
        let p = framing.viewPoint(of: .fit, sourceX: u * framing.sourceWidth,
                                  sourceY: v * framing.sourceHeight, backingScale: 1)
        return CGPoint(x: p.x, y: p.y)
    }

    private func normalized(_ framing: LoupeFraming, _ point: CGPoint) -> NormalizedPoint {
        let p = framing.sourcePoint(of: .fit, viewX: Double(point.x), viewY: Double(point.y),
                                    backingScale: 1)
        return NormalizedPoint(p.x / framing.sourceWidth, p.y / framing.sourceHeight)
    }

    /// Drag the bottom-right corner with the pointer: the corner lands under the hand, on every
    /// orientation, inside 1.5 px — and the frame that gets committed is the one that was drawn.
    func testTheCornerYouDragLandsUnderTheHandInPortraitToo() {
        for shot in shots() {
            let framing = self.framing(shot.upright)
            let mapping = framing.mapping(of: .fit)
            // A frame that already exists: the middle half of the picture.
            let start = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            let layout = CropTool.layout(crop: start, source: shot.upright, mapping: mapping)
            let corner = layout.grips.first { $0.kind == .bottomRight }!.point

            // Grab the corner where it is drawn and drag it 40 px right, 30 px down.
            let grab = corner
            let drop = CGPoint(x: corner.x + 40, y: corner.y + 30)
            let drag = CropToolDrag(handle: .bottomRight, crop: start,
                                    grab: normalized(framing, grab))
            let crop = drag.crop(at: normalized(framing, drop), source: shot.upright)

            // Where does that corner come back on screen?
            let after = CropTool.layout(crop: crop, source: shot.upright, mapping: mapping)
            let landed = after.grips.first { $0.kind == .bottomRight }!.point
            let dx = abs(Double(landed.x - drop.x)), dy = abs(Double(landed.y - drop.y))
            print(String(format: "035 portrait %@: grab (%.2f, %.2f) drop (%.2f, %.2f) → landed (%.2f, %.2f) Δ (%.2f, %.2f) · %dx%d upright",
                         shot.name, grab.x, grab.y, drop.x, drop.y, landed.x, landed.y, dx, dy,
                         shot.upright.width, shot.upright.height))

            XCTAssertLessThanOrEqual(dx, 1.5, "\(shot.name): the corner is off in x")
            XCTAssertLessThanOrEqual(dy, 1.5, "\(shot.name): the corner is off in y")

            // The committed pixels are the frame's own size.
            let pixels = CropMath.outputSize(crop, in: shot.upright)
            XCTAssertEqual(pixels.width, Int((crop.width * Double(shot.upright.width)).rounded()),
                           accuracy: 1, "\(shot.name): the crop is measured in the upright frame")
        }
    }

    /// What the **stored** dimensions cost on a portrait file: the frame is transposed, so a projection
    /// built from it puts the very same normalized corner a long way from where the picture puts it.
    /// The tool must not go back to that frame.
    func testTheStoredFrameWouldPutTheCornerSomewhereElse() {
        for shot in shots().filter({ $0.orientation.exchangesDimensions }) {
            let upright = shot.upright
            let crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

            // The right frame: the upright picture, as the renderer ingests it.
            let good = CropTool.layout(crop: crop, source: upright,
                                       mapping: framing(upright).mapping(of: .fit))
            // The wrong one: the catalogue's stored (transposed) dimensions.
            let bad = CropTool.layout(crop: crop, source: shot.stored,
                                      mapping: framing(shot.stored).mapping(of: .fit))

            let off = hypot(Double(bad.corners[2].x - good.corners[2].x),
                            Double(bad.corners[2].y - good.corners[2].y))
            print(String(format: "035 portrait %@: stored frame (%dx%d) puts the corner %.1f px off the picture",
                         shot.name, shot.stored.width, shot.stored.height, off))
            XCTAssertGreaterThan(off, 1.5,
                                 "\(shot.name): the stored frame must disagree by more than 1.5 px")
        }
    }
}
