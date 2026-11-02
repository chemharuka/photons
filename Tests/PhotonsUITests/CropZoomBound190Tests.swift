import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 190 — 「缩放后裁切框可以随便移动出画布」.
///
/// The law this file measures: **the frame's legal excursion is a document property.** Drag the
/// frame to its extreme under 适应 / 1:1 / 2× and the fraction of the frame still over the canvas
/// must be the *same number* — if the bound reads the viewport, zoom changes it, which is exactly
/// what 188 shipped (`clampRotatedQuadToView` used `mapping.viewport` as the canvas).
///
/// Everything here is measured in **document pixels** (the turned frame's own space): the quad is
/// `CropTool.layout`'s four corners before the view's similarity, and the canvas is the turned
/// source's AABB — the region the workspace calls 画布. Neither number knows about a viewport, a
/// zoom or a window, so a limit computed from them cannot move when the framing does.
///
/// **2026-11-02 — the canvas the clamp uses is the document canvas** (「旋转之后裁剪框能移动的范围应该
/// 是画布，不是原始图片」). `legalRect(degrees:)` below re-derives that box from the AABB formula (never
/// from `CropGeometry`), and every screen-space containment check now compares the drawn frame with the
/// **drawn legal rect** instead of 219's `mapping.canvasRect` (the picture at the current camera), which
/// is a different object: the legal rect is the same box at every zoom, `canvasRect` is not.
@MainActor
final class CropZoomBound190Tests: XCTestCase {

    private static let canvas = ImageSize(width: 1400, height: 1000)
    private static let source = ImageSize(width: 6000, height: 4500)
    private static let degrees = 5.4
    /// 20 % × 20 % of the source, centred — the 188 fixture's frame.
    private static let frame = CropRect(left: 0.40, top: 0.40, right: 0.60, bottom: 0.60)

    /// One framing: the viewport the canvas is drawn into plus the camera stop.
    private struct Framing {
        let name: String
        let viewport: ImageSize
        let state: LoupeViewState
    }

    private static let framings: [Framing] = [
        Framing(name: "fit", viewport: canvas, state: LoupeViewState(mode: .fit, zoom: 1,
                                                                    centerX: 0, centerY: 0)),
        Framing(name: "1:1", viewport: ImageSize(width: 800, height: 600),
                state: LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2250)),
        Framing(name: "2×", viewport: ImageSize(width: 400, height: 300),
                state: LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2250)),
    ]

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-crop-190-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - the document-space geometry (the test's own, not the implementation's)

    /// The legal area of a crop frame — the **document canvas**: the smallest axis-aligned box holding
    /// every pixel of the whole photograph after the turn, in normalized crop coordinates.
    ///
    /// Written out from the AABB formula here (`e = |w·cos| + |h·sin|` by `|w·sin| + |h·cos|`, centred on
    /// the photograph) rather than read from `CropGeometry.documentCanvasCropRect` / `rotatedExtent`, so
    /// the test derives the bound it measures against instead of proving the implementation with itself.
    /// `0…1` at 0°/180°, an axis swap at 90°/270°, wider than the photograph in between
    /// (5.4° on 6000 × 4500: `-0.033072…1.033072 × -0.060520…1.060520`).
    private static func legalRect(degrees: Double, source: ImageSize) -> CropRect {
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

    private func legalRect(degrees: Double) -> CropRect {
        Self.legalRect(degrees: degrees, source: Self.source)
    }

    /// The canvas in **document pixels**: the turned whole-source AABB, centred on the source's centre.
    /// 2026-11-02 — this is also the clamp's legal area (`legalRect`), so the coverage readout, the
    /// pull-back and the containment law all speak about one object.
    private static func canvasPixels(at degrees: Double) -> CGRect {
        let r = legalRect(degrees: degrees, source: source)
        let w = Double(source.width), h = Double(source.height)
        return CGRect(x: r.left * w, y: r.top * h, width: r.width * w, height: r.height * h)
    }

    private static var canvasPixels: CGRect { canvasPixels(at: degrees) }

    /// The frame's four corners in document pixels: the same quad `CropTool.layout` projects, with
    /// the view's similarity removed (`imagePoint`'s `R(−θ)` about the **source** centre).
    private func quad(_ rect: CropRect) -> [CGPoint] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let rotation = CropGeometry.RotationMatrix(degrees: Self.degrees)
        func image(_ u: Double, _ v: Double) -> CGPoint {
            let turned = rotation.invert(x: u * w - w / 2, y: v * h - h / 2)
            return CGPoint(x: w / 2 + turned.x, y: h / 2 + turned.y)
        }
        return [image(rect.left, rect.top), image(rect.right, rect.top),
                image(rect.right, rect.bottom), image(rect.left, rect.bottom)]
    }

    /// The turned quad's bounding box in document pixels — what the canvas containment law is stated
    /// on (196).
    private func box(_ rect: CropRect) -> CGRect {
        let corners = quad(rect)
        let xs = corners.map { $0.x }, ys = corners.map { $0.y }
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// The frame as the overlay draws it, in view pixels (`CropTool.layout` with the draft's
    /// rotation). 213/§5 states the containment law on this box and the viewport, not on the
    /// document-space quad above.
    private func screenBox(_ rect: CropRect, mapping: LoupeMapping, degrees: Double) -> CGRect {
        let layout = CropTool.layout(crop: rect, source: Self.source, mapping: mapping,
                                     pointScale: 1, showsGrid: false,
                                     quadRotationDegrees: degrees)
        return bounds(layout.corners)
    }

    private func bounds(_ corners: [CGPoint]) -> CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                      width: (xs.max() ?? 0) - (xs.min() ?? 0),
                      height: (ys.max() ?? 0) - (ys.min() ?? 0))
    }

    /// The **drawn** canvas: the legal rect pushed through the very projection the frame is drawn with
    /// (rotation included), so "the frame is inside the canvas" is compared in one space.
    ///
    /// 2026-11-02 — this replaced `mapping.canvasRect` as the containment source. That one is 219's
    /// picture-at-the-camera and grows/shrinks with the framing; the legal rect is the document's, the
    /// same box at every zoom, which is the whole point of 190.
    private func canvasBox(mapping: LoupeMapping, degrees: Double) -> CGRect {
        screenBox(legalRect(degrees: degrees), mapping: mapping, degrees: degrees)
    }

    /// Sutherland–Hodgman against the axis-aligned canvas, then the shoelace area.
    private func overlapFraction(_ rect: CropRect) -> Double {
        let clip = Self.canvasPixels
        var polygon = quad(rect)
        let edges: [(CGPoint, CGPoint)] = [
            (CGPoint(x: clip.minX, y: clip.minY), CGPoint(x: clip.maxX, y: clip.minY)),
            (CGPoint(x: clip.maxX, y: clip.minY), CGPoint(x: clip.maxX, y: clip.maxY)),
            (CGPoint(x: clip.maxX, y: clip.maxY), CGPoint(x: clip.minX, y: clip.maxY)),
            (CGPoint(x: clip.minX, y: clip.maxY), CGPoint(x: clip.minX, y: clip.minY)),
        ]
        for (a, b) in edges {
            guard !polygon.isEmpty else { return 0 }
            func inside(_ p: CGPoint) -> Bool {
                (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0
            }
            func cut(_ p: CGPoint, _ q: CGPoint) -> CGPoint {
                let dx = q.x - p.x, dy = q.y - p.y
                let ex = b.x - a.x, ey = b.y - a.y
                let den = dx * ey - dy * ex
                guard abs(den) > 1e-12 else { return q }
                let t = ((a.x - p.x) * ey - (a.y - p.y) * ex) / den
                return CGPoint(x: p.x + dx * t, y: p.y + dy * t)
            }
            var next: [CGPoint] = []
            for i in polygon.indices {
                let current = polygon[i]
                let previous = polygon[(i + polygon.count - 1) % polygon.count]
                let cIn = inside(current), pIn = inside(previous)
                if cIn {
                    if !pIn { next.append(cut(previous, current)) }
                    next.append(current)
                } else if pIn {
                    next.append(cut(previous, current))
                }
            }
            polygon = next
        }
        guard polygon.count >= 3 else { return 0 }
        var twice = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            twice += a.x * b.y - b.x * a.y
        }
        let area = abs(twice) / 2
        let own = rect.width * Double(Self.source.width) * rect.height * Double(Self.source.height)
        return own > 0 ? area / own : 0
    }

    // MARK: - the drag

    /// The exact inverse of `CropToolController.normalized` — where on screen the hand must be for
    /// the drag to mean this normalized point.
    private func viewPoint(normalized point: NormalizedPoint, mapping: LoupeMapping) -> CGPoint {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let rotation = CropGeometry.RotationMatrix(degrees: Self.degrees)
        let turned = rotation.invert(x: (point.x - 0.5) * w, y: (point.y - 0.5) * h)
        let p = mapping.frameView(frameX: w / 2 + turned.x, frameY: h / 2 + turned.y)
        return CGPoint(x: p.x, y: p.y)
    }

    private struct Limit {
        let crop: CropRect
        let overlap: Double
        let centreInViewport: Bool
        let steps: Int
        let screen: CGRect
        /// The legal area (`legalRect`) as it is drawn at this framing — the same projection the frame
        /// goes through, so "inside the canvas" is one space. 2026-11-02: this used to be
        /// `mapping.canvasRect(rotatedBy:)`, 219's picture-at-the-camera.
        let canvas: CGRect
    }

    /// Drag the frame's interior right-and-down, one tick at a time, until the model stops moving
    /// it. `Δ` is 0.004 of the source per tick, so the pull-back is exercised on every tick.
    private func limit(_ framing: Framing) throws -> Limit {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        controller.draft = CropToolController.Draft(crop: Self.frame, straighten: Self.degrees,
                                                    lock: .original)
        let f = LoupeFraming(viewport: framing.viewport,
                             sourceWidth: Double(Self.source.width),
                             sourceHeight: Double(Self.source.height),
                             crop: .full, straightenDegrees: Self.degrees)
        let mapping = f.mapping(of: framing.state)
        let grab = NormalizedPoint(Self.frame.centerX, Self.frame.centerY)
        let grabView = viewPoint(normalized: grab, mapping: mapping)
        XCTAssertTrue(controller.beginDrag(atViewPoint: grabView, mapping: mapping, source: Self.source))

        let step = 0.004
        var last = controller.draft.crop
        var stable = 0
        var steps = 0
        for i in 1...400 {
            steps = i
            let target = NormalizedPoint(grab.x + step * Double(i), grab.y + step * Double(i))
            controller.continueDrag(atViewPoint: viewPoint(normalized: target, mapping: mapping),
                                    mapping: mapping, source: Self.source)
            let now = controller.draft.crop
            let delta = max(abs(now.left - last.left), abs(now.top - last.top),
                            abs(now.right - last.right), abs(now.bottom - last.bottom))
            last = now
            stable = delta < 1e-9 ? stable + 1 : 0
            if stable >= 3 { break }
        }
        let crop = controller.draft.crop
        let centre = viewPoint(normalized: NormalizedPoint(crop.centerX, crop.centerY),
                               mapping: mapping)
        let inViewport = centre.x >= 0 && centre.x <= Double(framing.viewport.width)
            && centre.y >= 0 && centre.y <= Double(framing.viewport.height)
        return Limit(crop: crop, overlap: overlapFraction(crop),
                     centreInViewport: inViewport, steps: steps,
                     screen: screenBox(crop, mapping: mapping, degrees: Self.degrees),
                     canvas: canvasBox(mapping: mapping, degrees: Self.degrees))
    }

    // MARK: - the claim

    /// The core of 190: **three framings, one limit.**
    ///
    /// Red before the fix (188's rule is 「the quad's centre is in the viewport」): 适应 lets the
    /// centre reach the canvas' corner but 1:1 and 2× confine it to a window of the document, so the
    /// three limits are three different numbers. Green after: 25 % ± 1 % everywhere, and the three
    /// rects agree — the extreme is a property of the document, not of the zoom.
    ///
    /// `centre in viewport` is printed and **never asserted**: at 1:1 and 2× the viewport is a window
    /// of the canvas, so a frame that keeps its quarter over the canvas is normally outside it. The
    /// two clauses cannot both hold, and 190 chooses coverage (see `legal` in the controller). It is
    /// printed so the next reader can see the choice instead of re-deriving the old rule.
    func testAtZoomTheFrameCannotLeaveTheCanvas() throws {
        var measured: [(Framing, Limit)] = []
        for framing in Self.framings {
            let l = try limit(framing)
            measured.append((framing, l))
            print(String(format: "190 · %@ · steps %d · crop l %.6f t %.6f r %.6f b %.6f · "
                         + "overlap %.6f · centre in viewport %@",
                         framing.name, l.steps, l.crop.left, l.crop.top, l.crop.right, l.crop.bottom,
                         l.overlap, l.centreInViewport ? "yes" : "no"))
        }

        // 213/§5 — the law is **screen-space**: the drawn frame's four corners stay inside the drawn
        // canvas (0.5 px of slack), at every framing. 2026-11-02: the canvas is the document's legal
        // rect (`legalRect`, the turned photograph's AABB), not 219's picture-at-the-camera, and it is
        // the same box at 适应 / 1:1 / 2× — which is exactly why the three limits must agree.
        for (framing, l) in measured {
            XCTAssertGreaterThanOrEqual(l.screen.minX, l.canvas.minX - 0.5,
                                        "\(framing.name): the frame leaves the canvas on the left")
            XCTAssertGreaterThanOrEqual(l.screen.minY, l.canvas.minY - 0.5,
                                        "\(framing.name): the frame leaves the canvas on the top")
            XCTAssertLessThanOrEqual(l.screen.maxX, l.canvas.maxX + 0.5,
                                     "\(framing.name): the frame leaves the canvas on the right")
            XCTAssertLessThanOrEqual(l.screen.maxY, l.canvas.maxY + 0.5,
                                     "\(framing.name): the frame leaves the canvas on the bottom")
            XCTAssertLessThanOrEqual(l.overlap, 1.0 + 1e-9)
        }

        // …and the model value, in document coordinates: the same law without any projection, and with
        // the same tolerance, so a layout bug cannot hide a clamp bug.
        let legal = legalRect(degrees: Self.degrees)
        for (framing, l) in measured {
            XCTAssertGreaterThanOrEqual(l.crop.left, legal.left - 1e-12, "\(framing.name): left")
            XCTAssertGreaterThanOrEqual(l.crop.top, legal.top - 1e-12, "\(framing.name): top")
            XCTAssertLessThanOrEqual(l.crop.right, legal.right + 1e-12, "\(framing.name): right")
            XCTAssertLessThanOrEqual(l.crop.bottom, legal.bottom + 1e-12, "\(framing.name): bottom")
        }

        // The three limits are one number: the same document, the same angle, three framings. Compared
        // with 1e-9 rather than bit-for-bit — the three drags take different tick sizes, so the slide
        // that lands on the canvas' edge carries a different last-bit rounding in each.
        for (framing, l) in measured.dropFirst() {
            XCTAssertEqual(l.crop.left, measured[0].1.crop.left, accuracy: 1e-9,
                           "\(framing.name): the extreme must be the document's, not the zoom's (left)")
            XCTAssertEqual(l.crop.top, measured[0].1.crop.top, accuracy: 1e-9,
                           "\(framing.name): … (top)")
            XCTAssertEqual(l.crop.right, measured[0].1.crop.right, accuracy: 1e-9,
                           "\(framing.name): … (right)")
            XCTAssertEqual(l.crop.bottom, measured[0].1.crop.bottom, accuracy: 1e-9,
                           "\(framing.name): … (bottom)")
        }

        // The bound only ever *shrinks* a frame that is larger than the canvas. The 20 % fixture fits
        // the document canvas, so it must be moved at its own size at every framing — never shrunk.
        // 2026-11-02: the canvas is one box (the turned photograph's AABB), not 219's picture-at-the-
        // camera, so this clause now reads the same at 适应 / 1:1 / 2×.
        for (framing, l) in measured {
            let initial = screenBox(Self.frame, mapping: LoupeFraming(
                viewport: framing.viewport,
                sourceWidth: Double(Self.source.width),
                sourceHeight: Double(Self.source.height),
                crop: .full, straightenDegrees: Self.degrees).mapping(of: framing.state),
                                    degrees: Self.degrees)
            if initial.width <= l.canvas.width + 0.5 && initial.height <= l.canvas.height + 0.5 {
                XCTAssertEqual(l.crop.width, Self.frame.width, accuracy: 1e-9, framing.name)
                XCTAssertEqual(l.crop.height, Self.frame.height, accuracy: 1e-9, framing.name)
            } else {
                XCTAssertLessThanOrEqual(l.screen.width, l.canvas.width + 0.5, framing.name)
                XCTAssertLessThanOrEqual(l.screen.height, l.canvas.height + 0.5, framing.name)
            }
        }
    }

    /// One far drag (a single tick that jumps the frame far off the document) must land **on the
    /// document canvas' edge**, not somewhere in between: the clamp is a pull-back to the canvas
    /// (2026-11-02), so the rect ends flush with one of its edges and keeps its size. The drawn frame
    /// may sit inside the view's picture with a margin — that margin is not part of the law any more.
    ///
    /// At 5.4° on 6000 × 4500 the canvas is `-0.033072…1.033072 × -0.060520…1.060520`; the numbers are
    /// derived from `legalRect`, not hard-coded.
    func testASingleFarDragIsPinnedOnTheCanvasEdge() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        controller.draft = CropToolController.Draft(crop: Self.frame, straighten: Self.degrees,
                                                    lock: .original)
        let f = LoupeFraming(viewport: Self.canvas, sourceWidth: Double(Self.source.width),
                             sourceHeight: Double(Self.source.height), crop: .full,
                             straightenDegrees: Self.degrees)
        let mapping = f.mapping(of: LoupeViewState(mode: .fit, zoom: 1, centerX: 0, centerY: 0))
        let grab = NormalizedPoint(Self.frame.centerX, Self.frame.centerY)
        XCTAssertTrue(controller.beginDrag(atViewPoint: viewPoint(normalized: grab, mapping: mapping),
                                          mapping: mapping, source: Self.source))
        // One tick: the hand teleports a frame and a half to the bottom right.
        controller.continueDrag(atViewPoint: viewPoint(normalized: NormalizedPoint(1.9, 1.9),
                                                       mapping: mapping),
                                mapping: mapping, source: Self.source)
        let crop = controller.draft.crop
        let b = box(crop)
        let screen = screenBox(crop, mapping: mapping, degrees: Self.degrees)
        let legal = legalRect(degrees: Self.degrees)
        let canvasBox = canvasBox(mapping: mapping, degrees: Self.degrees)
        print(String(format: "190 · far drag · crop l %.6f t %.6f r %.6f b %.6f · overlap %.6f "
                     + "· screen %.3f,%.3f–%.3f,%.3f · doc box %.3f,%.3f–%.3f,%.3f "
                     + "· 合法区 l %.6f t %.6f r %.6f b %.6f",
                     crop.left, crop.top, crop.right, crop.bottom, overlapFraction(crop),
                     screen.minX, screen.minY, screen.maxX, screen.maxY,
                     b.minX, b.minY, b.maxX, b.maxY,
                     legal.left, legal.top, legal.right, legal.bottom))
        // 2026-11-02 — pinned on the **canvas'** edge: inside the legal rect on all four sides and
        // flush with one of them (the bottom-right corner of the document canvas at 5.4°). The frame
        // may cover the black corners a straighten opens; that is legal, not a leak.
        XCTAssertGreaterThanOrEqual(crop.left, legal.left - 1e-9)
        XCTAssertGreaterThanOrEqual(crop.top, legal.top - 1e-9)
        XCTAssertLessThanOrEqual(crop.right, legal.right + 1e-9)
        XCTAssertLessThanOrEqual(crop.bottom, legal.bottom + 1e-9)
        XCTAssertEqual(min(crop.left - legal.left, crop.top - legal.top,
                           legal.right - crop.right, legal.bottom - crop.bottom),
                       0, accuracy: 1e-9, "the far drag did not reach the canvas' edge")
        XCTAssertEqual(crop.right, legal.right, accuracy: 1e-9, "the far drag went down-right: right edge")
        XCTAssertEqual(crop.bottom, legal.bottom, accuracy: 1e-9, "…and the bottom edge")
        XCTAssertEqual(crop.width, Self.frame.width, accuracy: 1e-9, "never shrunk")
        XCTAssertEqual(crop.height, Self.frame.height, accuracy: 1e-9)
        // The drawn form of the same statement: the frame's quad inside the canvas' quad.
        XCTAssertGreaterThanOrEqual(screen.minX, canvasBox.minX - 0.5)
        XCTAssertGreaterThanOrEqual(screen.minY, canvasBox.minY - 0.5)
        XCTAssertLessThanOrEqual(screen.maxX, canvasBox.maxX + 0.5)
        XCTAssertLessThanOrEqual(screen.maxY, canvasBox.maxY + 0.5)
    }

    /// **Every** clamped result satisfies the law it was clamped by — including the two paths that
    /// are easy to leave illegal: a frame bigger than the canvas (where 25 % may be unreachable and
    /// the honest answer is the best position there is) and the opt-in photo-bound shrink
    /// (`clampsToRotatedFrame`, which must not be allowed to undo the 25 % floor).
    ///
    /// The inputs are the interesting corners of the space: smaller / equal / bigger than the canvas,
    /// hanging over one edge, over a corner, with and without an aspect lock, at 5.4° / 9° / 45°,
    /// with the photo-bound shrink on and off.
    ///
    /// 2026-11-02 — the last case used to be 90°. The dial's 拉直 is `CropTool.clampStraighten`d to
    /// ±45°, so a 90° draft is **not a reachable document**: the clamp would read the 45° canvas while
    /// the overlay drew the quad at 90°, i.e. the case would compare two different documents. It is now
    /// the same overhang at 45° (the reachable maximum), and the canvas it is measured against is the
    /// legal rect instead of 219's `mapping.canvasRect`.
    func testEveryClampedResultSatisfiesItsOwnLaw() throws {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        let f = LoupeFraming(viewport: Self.canvas, sourceWidth: Double(Self.source.width),
                             sourceHeight: Double(Self.source.height), crop: .full,
                             straightenDegrees: 0)
        let mapping = f.mapping(of: .fit)

        struct Case {
            let name: String
            let crop: CropRect
            let degrees: Double
            let lock: AspectLock
            let photoBound: Bool
        }
        let cases: [Case] = [
            Case(name: "小于画布 · 中央", crop: CropRect(left: 0.40, top: 0.40, right: 0.60,
                                                        bottom: 0.60),
                 degrees: 5.4, lock: .original, photoBound: false),
            Case(name: "小于画布 · 贴右下角外", crop: CropRect(left: 0.86, top: 0.90, right: 1.06,
                                                             bottom: 1.10),
                 degrees: 5.4, lock: .original, photoBound: false),
            Case(name: "等于画布 · 5.4°", crop: CropRect(left: 0, top: 0, right: 1, bottom: 1),
                 degrees: 5.4, lock: .original, photoBound: false),
            Case(name: "大于画布 · 45° · 1.5×", crop: CropRect(left: -0.25, top: -0.25,
                                                              right: 1.25, bottom: 1.25),
                 degrees: 45, lock: .original, photoBound: false),
            Case(name: "远大于画布 · 45° · 4×（25% 不可达）",
                 crop: CropRect(left: -1.5, top: -1.5, right: 2.5, bottom: 2.5),
                 degrees: 45, lock: .original, photoBound: false),
            Case(name: "小于画布 · 16:9 锁", crop: CropRect(left: 0.45, top: 0.30, right: 0.75,
                                                           bottom: 0.50),
                 degrees: 9, lock: .sixteenNine, photoBound: false),
            Case(name: "大于画布 · 45°（原 90°：拉直钳在 ±45°）", crop: CropRect(left: -0.2, top: -0.3,
                                                                          right: 1.2, bottom: 1.1),
                 degrees: 45, lock: .original, photoBound: false),
            Case(name: "小于画布 · 照片约束开", crop: CropRect(left: 0.55, top: 0.85, right: 0.75,
                                                              bottom: 1.05),
                 degrees: 5.4, lock: .original, photoBound: true),
            Case(name: "大于画布 · 照片约束开", crop: CropRect(left: -0.1, top: -0.1, right: 1.1,
                                                              bottom: 1.1),
                 degrees: 9, lock: .original, photoBound: true),
        ]

        for c in cases {
            controller.clampsToRotatedFrame = c.photoBound
            controller.draft = CropToolController.Draft(crop: c.crop, straighten: c.degrees,
                                                        lock: c.lock)
            let before = controller.draft.crop
            let moved = controller.clampToView(mapping: mapping, source: Self.source)
            let after = controller.draft.crop
            let coverage = controller.canvasCoverage(of: after, source: Self.source)
            // 诊断，不是判据：可达性在 190 里由「25% 在画布上 + 适应可看全帧」保证，见 `legal` 的注释。
            let reachable = controller.hasReachableGrip(after, source: Self.source)

            let extent = Self.canvasPixels(at: c.degrees)
            let frameArea = after.width * Double(Self.source.width)
                * after.height * Double(Self.source.height)
            // 画布面积 / 框面积 —— 只用来判断「25% 到底可达不可达」，不是 coverage 的上界。
            let best = min(1, extent.width * extent.height / max(frameArea, 1e-9))
            print(String(format: "190 · law · %@ · moved %@ · l %.6f t %.6f r %.6f b %.6f · "
                         + "coverage %.6f (画布/框 %.6f) · 可抓 %@",
                         c.name, moved ? "yes" : "no", after.left, after.top, after.right,
                         after.bottom, coverage, best, reachable ? "yes" : "no"))

            // 2026-11-02 — the law the clamp applies: the result sits inside the **document canvas**
            // (`legalRect`, the turned photograph's AABB), with zero slack beyond the clamp's own
            // rounding. This is the document-space statement; the screen-space one follows.
            let legal = legalRect(degrees: c.degrees)
            XCTAssertGreaterThanOrEqual(after.left, legal.left - 1e-9, "\(c.name): left of the canvas")
            XCTAssertGreaterThanOrEqual(after.top, legal.top - 1e-9, "\(c.name): above the canvas")
            XCTAssertLessThanOrEqual(after.right, legal.right + 1e-9, "\(c.name): right of the canvas")
            XCTAssertLessThanOrEqual(after.bottom, legal.bottom + 1e-9, "\(c.name): below the canvas")

            // 213/§5 — the law, re-measured on the result **in screen space**: the drawn quad's
            // four sides inside the **drawn canvas** (0.5 px of slack), with the frame shrunk only
            // when it is genuinely bigger than the canvas. 2026-11-02: the canvas is the legal rect
            // drawn through the same projection (`canvasBox`), not 219's picture-at-the-camera.
            // The overlay draws `effectiveCrop` (the opt-in photo bound is a view, not a draft
            // write), so the screen law is measured on that rect.
            let drawn = controller.effectiveCrop(source: Self.source)
            let screen = screenBox(drawn, mapping: mapping, degrees: c.degrees)
            let canvas = canvasBox(mapping: mapping, degrees: c.degrees)
            XCTAssertGreaterThanOrEqual(screen.minX, canvas.minX - 0.5,
                                        "\(c.name): hangs off the canvas' left — \(screen)")
            XCTAssertLessThanOrEqual(screen.maxX, canvas.maxX + 0.5,
                                     "\(c.name): hangs off the canvas' right — \(screen)")
            XCTAssertGreaterThanOrEqual(screen.minY, canvas.minY - 0.5,
                                        "\(c.name): hangs off the canvas' top — \(screen)")
            XCTAssertLessThanOrEqual(screen.maxY, canvas.maxY + 0.5,
                                     "\(c.name): hangs off the canvas' bottom — \(screen)")
            XCTAssertLessThanOrEqual(coverage, 1.0 + 1e-9)

            // A clamp only ever *moves* a frame that fits; one bigger than the canvas is shrunk. The
            // test is made in **frame space**, which is where the clamp makes it: comparing drawn AABBs
            // would let a rotated square "fit" a narrower rectangle (its AABB is the sum, not the max).
            let fits = before.width <= legal.width + 1e-12 && before.height <= legal.height + 1e-12
            if fits, c.lock.ratio == nil, !c.photoBound {
                XCTAssertEqual(after.width, before.width, accuracy: 1e-9, c.name)
                XCTAssertEqual(after.height, before.height, accuracy: 1e-9, c.name)
            } else {
                XCTAssertLessThanOrEqual(screen.width, canvas.width + 0.5,
                                         "\(c.name): not shrunk to the canvas")
                XCTAssertLessThanOrEqual(screen.height, canvas.height + 0.5,
                                         "\(c.name): not shrunk to the canvas")
            }
        }
        controller.clampsToRotatedFrame = false
    }

    // MARK: - θ = 0 is untouched

    /// The reverse gate for the upright path: `clampedToCanvas` is not part of 190, so its numbers
    /// are the 188 ones to the last digit. The string below is printed before and after the change
    /// and diffed — any drift is a regression, not a tolerance.
    ///
    /// 2026-11-02 — this is also the guard that the new rule **degenerates** upright: `legalRect(0)` is
    /// exactly `[0,1]²`, so nothing that 224 allowed became illegal at θ = 0 and no upright number may
    /// move. Asserted bit-for-bit, not with a tolerance.
    func testZeroDegreeClampIsUnchanged() throws {
        let upright = legalRect(degrees: 0)
        XCTAssertEqual(upright.left, 0, accuracy: 0)
        XCTAssertEqual(upright.top, 0, accuracy: 0)
        XCTAssertEqual(upright.right, 1, accuracy: 0)
        XCTAssertEqual(upright.bottom, 1, accuracy: 0)
        // …and 180°, the other right angle the AABB degenerates on (the 拉直 dial itself stops at ±45°,
        // so 90/180 arrive here as formula checks only, never as a reachable draft).
        let upsideDown = legalRect(degrees: 180)
        XCTAssertEqual(upsideDown.left, 0, accuracy: 0)
        XCTAssertEqual(upsideDown.top, 0, accuracy: 0)
        XCTAssertEqual(upsideDown.right, 1, accuracy: 0)
        XCTAssertEqual(upsideDown.bottom, 1, accuracy: 0)
        let (session, _) = try CropUITestSupport.makeSession(in: workDir,
                                                             width: Self.source.width,
                                                             height: Self.source.height)
        let controller = CropToolController(session: session)
        XCTAssertTrue(controller.begin())
        let f = LoupeFraming(viewport: Self.canvas, sourceWidth: Double(Self.source.width),
                             sourceHeight: Double(Self.source.height), crop: .full,
                             straightenDegrees: 0)
        let mapping = f.mapping(of: LoupeViewState(mode: .fit, zoom: 1, centerX: 0, centerY: 0))
        // A frame far off to the right, and one straddling the band: both go through
        // `clampedToCanvas`, which 190 does not touch.
        for (index, start) in [CropRect(left: 0.9, top: 0.1, right: 1.3, bottom: 0.5),
                               CropRect(left: -0.4, top: 0.7, right: 0.2, bottom: 1.2)].enumerated() {
            controller.draft = CropToolController.Draft(crop: start, straighten: 0, lock: .original)
            let moved = controller.clampToView(mapping: mapping, source: Self.source)
            let c = controller.draft.crop
            print(String(format: "190 · θ=0 · case %d · moved %@ · l %.12f t %.12f r %.12f b %.12f",
                         index, moved ? "yes" : "no", c.left, c.top, c.right, c.bottom))
            XCTAssertEqual(c.width, start.width, accuracy: 1e-12, "θ=0 only moves: no shrink")
            XCTAssertEqual(c.height, start.height, accuracy: 1e-12)
        }
    }
}
