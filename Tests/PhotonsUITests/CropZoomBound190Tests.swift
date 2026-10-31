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

    /// The turned whole-source AABB in source pixels — the **canvas** in document space.
    private static var canvasPixels: CGRect {
        let e = LoupeFraming.rotatedExtent(width: Double(source.width), height: Double(source.height),
                                           degrees: degrees)
        return CGRect(x: (Double(source.width) - e.width) / 2,
                      y: (Double(source.height) - e.height) / 2,
                      width: e.width, height: e.height)
    }

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
                     centreInViewport: inViewport, steps: steps)
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

        // ① 196 — 「框不得移出画布」: the turned quad's bounding box is inside the canvas at **every**
        //   framing. 190 measured 25 % area overlap here; the user has reversed that.
        for (framing, l) in measured {
            let b = box(l.crop), c = Self.canvasPixels
            XCTAssertGreaterThanOrEqual(b.minX, c.minX - 0.5,
                                        "\(framing.name): the frame hangs off the canvas' left \(b) vs \(c)")
            XCTAssertLessThanOrEqual(b.maxX, c.maxX + 0.5,
                                     "\(framing.name): the frame hangs off the canvas' right \(b) vs \(c)")
            XCTAssertGreaterThanOrEqual(b.minY, c.minY - 0.5,
                                        "\(framing.name): the frame hangs off the canvas' top \(b) vs \(c)")
            XCTAssertLessThanOrEqual(b.maxY, c.maxY + 0.5,
                                     "\(framing.name): the frame hangs off the canvas' bottom \(b) vs \(c)")
            XCTAssertLessThanOrEqual(l.overlap, 1.0 + 1e-9)
        }

        // ② …and the limit is the **same document position** at every framing: the extreme does not
        //   depend on the zoom. This is the sentence the bug report is really about.
        let values = measured.map(\.1.overlap)
        for (framing, l) in measured {
            XCTAssertEqual(l.overlap, values[0], accuracy: 0.01,
                           "\(framing.name) limits at \(l.overlap), fit limits at \(values[0]) — "
                           + "the bound still reads the viewport")
        }
        for (framing, l) in measured.dropFirst() {
            XCTAssertEqual(l.crop.left, measured[0].1.crop.left, accuracy: 1e-6, framing.name)
            XCTAssertEqual(l.crop.top, measured[0].1.crop.top, accuracy: 1e-6, framing.name)
            XCTAssertEqual(l.crop.right, measured[0].1.crop.right, accuracy: 1e-6, framing.name)
            XCTAssertEqual(l.crop.bottom, measured[0].1.crop.bottom, accuracy: 1e-6, framing.name)
        }

        // ③ the frame keeps its size: the bound may only ever *move* it (188 deleted the shrink and
        //   it is not coming back).
        for (framing, l) in measured {
            XCTAssertEqual(l.crop.width, Self.frame.width, accuracy: 1e-9, framing.name)
            XCTAssertEqual(l.crop.height, Self.frame.height, accuracy: 1e-9, framing.name)
        }
    }

    /// One far drag (a single tick that jumps the frame far off the canvas) must land **on** the
    /// canvas' edge, not somewhere in between: the clamp is a pull-back to the boundary (196), so the
    /// turned box ends flush with an edge and the frame keeps its size.
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
        let b = box(crop), c = Self.canvasPixels
        print(String(format: "190 · far drag · crop l %.6f t %.6f r %.6f b %.6f · overlap %.6f "
                     + "· box %.3f,%.3f–%.3f,%.3f · canvas %.3f,%.3f–%.3f,%.3f",
                     crop.left, crop.top, crop.right, crop.bottom, overlapFraction(crop),
                     b.minX, b.minY, b.maxX, b.maxY, c.minX, c.minY, c.maxX, c.maxY))
        // 196 — pinned on the canvas' edge: inside on all four sides, flush with two of them.
        XCTAssertGreaterThanOrEqual(b.minX, c.minX - 0.5)
        XCTAssertLessThanOrEqual(b.maxX, c.maxX + 0.5)
        XCTAssertGreaterThanOrEqual(b.minY, c.minY - 0.5)
        XCTAssertLessThanOrEqual(b.maxY, c.maxY + 0.5)
        XCTAssertEqual(min(c.maxX - b.maxX, b.minX - c.minX, c.maxY - b.maxY, b.minY - c.minY),
                       0, accuracy: 0.5, "the far drag did not reach the canvas' edge")
        XCTAssertEqual(crop.width, Self.frame.width, accuracy: 1e-9, "never shrunk")
        XCTAssertEqual(crop.height, Self.frame.height, accuracy: 1e-9)
    }

    /// **Every** clamped result satisfies the law it was clamped by — including the two paths that
    /// are easy to leave illegal: a frame bigger than the canvas (where 25 % may be unreachable and
    /// the honest answer is the best position there is) and the opt-in photo-bound shrink
    /// (`clampsToRotatedFrame`, which must not be allowed to undo the 25 % floor).
    ///
    /// The inputs are the interesting corners of the space: smaller / equal / bigger than the canvas,
    /// hanging over one edge, over a corner, with and without an aspect lock, at 5.4° / 45° / 90°,
    /// with the photo-bound shrink on and off.
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
            Case(name: "大于画布 · 90°", crop: CropRect(left: -0.2, top: -0.3, right: 1.2,
                                                        bottom: 1.1),
                 degrees: 90, lock: .original, photoBound: false),
            Case(name: "小于画布 · 照片约束开", crop: CropRect(left: 0.55, top: 0.85, right: 0.75,
                                                              bottom: 1.05),
                 degrees: 5.4, lock: .original, photoBound: true),
            Case(name: "大于画布 · 照片约束开", crop: CropRect(left: -0.1, top: -0.1, right: 1.1,
                                                              bottom: 1.1),
                 degrees: 9, lock: .original, photoBound: true),
        ]

        // The biggest coverage any position can have: a frame bigger than the canvas tops out at
        // canvas/frame when it is centred on it, so 25 % is simply not reachable for a huge frame.
        let canvasPixels = LoupeFraming.rotatedExtent(width: Double(Self.source.width),
                                                      height: Double(Self.source.height),
                                                      degrees: 0)
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

            let extent = LoupeFraming.rotatedExtent(width: Double(Self.source.width),
                                                    height: Double(Self.source.height),
                                                    degrees: c.degrees)
            let frameArea = after.width * Double(Self.source.width)
                * after.height * Double(Self.source.height)
            // 画布面积 / 框面积 —— 只用来判断「25% 到底可达不可达」，不是 coverage 的上界。
            let best = min(1, extent.width * extent.height / max(frameArea, 1e-9))
            _ = canvasPixels
            print(String(format: "190 · law · %@ · moved %@ · l %.6f t %.6f r %.6f b %.6f · "
                         + "coverage %.6f (画布/框 %.6f) · 可抓 %@",
                         c.name, moved ? "yes" : "no", after.left, after.top, after.right,
                         after.bottom, coverage, best, reachable ? "yes" : "no"))

            // ① 196 — the law, re-measured on the result: the turned box is **inside the canvas** on
            //   all four sides, whenever the box could fit at all.
            let b = box(after), cnv = Self.canvasPixels
            // `clampsToRotatedFrame` is a **view** bound (132): it is `effectiveCrop`'s answer, never
            // the stored draft's, so the draft may stay outside the canvas in those two cases.
            let fits = b.width <= cnv.width + 0.5 && b.height <= cnv.height + 0.5
            if fits && !c.photoBound {
                XCTAssertGreaterThanOrEqual(b.minX, cnv.minX - 0.5,
                                            "\(c.name): hangs off the left — \(b) vs \(cnv)")
                XCTAssertLessThanOrEqual(b.maxX, cnv.maxX + 0.5,
                                         "\(c.name): hangs off the right — \(b) vs \(cnv)")
                XCTAssertGreaterThanOrEqual(b.minY, cnv.minY - 0.5,
                                            "\(c.name): hangs off the top — \(b) vs \(cnv)")
                XCTAssertLessThanOrEqual(b.maxY, cnv.maxY + 0.5,
                                         "\(c.name): hangs off the bottom — \(b) vs \(cnv)")
            } else if !c.photoBound {
                // 162's other half: a frame whose turned box cannot fit is shrunk to the canvas.
                XCTAssertLessThanOrEqual(b.width, cnv.width + 0.5, "\(c.name): not shrunk to the canvas")
                XCTAssertLessThanOrEqual(b.height, cnv.height + 0.5, "\(c.name): not shrunk to the canvas")
            }
            XCTAssertLessThanOrEqual(coverage, 1.0 + 1e-9)
            // ③ a clamp only ever moves a frame that fits (196 keeps 162's shrink for one that does
            //   not): the size is untouched unless the box had to be brought inside.
            let beforeBox = box(before)
            // …and the opt-in photo bound (`clampsToRotatedFrame`) is a shrink by design, so it is
            // excluded: this clause is about the *canvas* law, which only ever moves.
            if beforeBox.width <= Self.canvasPixels.width + 0.5,
               beforeBox.height <= Self.canvasPixels.height + 0.5,
               c.lock.ratio == nil, !c.photoBound {
                XCTAssertEqual(after.width, before.width, accuracy: 1e-9, c.name)
                XCTAssertEqual(after.height, before.height, accuracy: 1e-9, c.name)
            }
        }
        controller.clampsToRotatedFrame = false
    }

    // MARK: - θ = 0 is untouched

    /// The reverse gate for the upright path: `clampedToCanvas` is not part of 190, so its numbers
    /// are the 188 ones to the last digit. The string below is printed before and after the change
    /// and diffed — any drift is a regression, not a tolerance.
    func testZeroDegreeClampIsUnchanged() throws {
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
