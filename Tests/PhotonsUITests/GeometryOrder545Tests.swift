import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI
@testable import PhotonsCore

/// **545 — 旋转/镜像后的透视与引导线.**
///
/// The user's two sentences are the two halves of this suite:
///
/// > 旋转/镜像后，透视的值似乎取错了，现在是做的取相反数，结果不对。
/// > 另外引导线没有跟着旋转。
///
/// §1 measures the **baseline**: what `perspectiveVertical = +A` does to the four corners on a
/// document with no turn and no mirror — the table every sign below is judged against (the ticket
/// forbids guessing it from the comments).
///
/// §2 is the four-operations × four-knobs corner table: for each row, the **pre-545** residual (the
/// `−v`/`−h` spelling 489 shipped) and the **post-545** one (the shipped `remapped`). The criterion is
/// the screen shape, not the numbers: a document turned by `op` must put every picture point where
/// the un-turned one put it **after the canvas is turned too** — `G' ∘ τ = τ ∘ G` (`τ` the quarter
/// turn, `G` the composed `photo-normalized → canvas-normalized` map S0 samples through).
///
/// The **reverse gate** for the sign fix is the table itself: revert the two lines in `remapped` and
/// every `post ≤ 1e-9` assertion goes red (the `pre` column is the measured size of that red).
///
/// §3 is the guide lines: all four entry points, and a reverse gate that leaves the in-memory drawing
/// copy behind (`CropToolController.guideLinesFollowRemap = false`).
@MainActor
final class GeometryOrder545Tests: XCTestCase {

    // MARK: - harness

    private let source = ImageSize(width: 3000, height: 2000)
    private let corners: [(Double, Double)] = [(0, 0), (1, 0), (1, 1), (0, 1)]

    /// Photo-normalized → canvas-normalized, exactly the map `RenderGraph` hands S0 (`sampling`'s
    /// inverse). `turned` picks the frame the document is measured in: a quarter turn swaps the
    /// source, which is the frame the crop and the keystone live in (`orientedSource`).
    private func forward(_ v: Double, _ h: Double, _ k: Double, _ a: Double,
                         crop: CropRect = .full, straighten: Double = 0,
                         turned: Bool = false) -> [[Double]] {
        let oriented = turned ? ImageSize(width: source.height, height: source.width) : source
        return CropMath.perspectiveCanvas(
            crop: crop, in: oriented, straightenDegrees: straighten,
            perspective: PerspectiveMap(vertical: v, horizontal: h, shear: k, aspect: a)).forward
    }

    private func forward(_ g: GeometryGroup, turned: Bool = false) -> [[Double]] {
        forward(g.perspectiveVertical, g.perspectiveHorizontal,
                g.perspectiveShear, g.perspectiveAspect,
                crop: g.cropRect, straighten: g.straightenDegrees, turned: turned)
    }

    private func turn(_ x: Double, _ y: Double) -> (Double, Double) { (1 - y, x) }
    private func unturn(_ x: Double, _ y: Double) -> (Double, Double) { (y, 1 - x) }
    private func flipH(_ x: Double, _ y: Double) -> (Double, Double) { (1 - x, y) }
    private func flipV(_ x: Double, _ y: Double) -> (Double, Double) { (x, 1 - y) }

    /// The **screen-shape** residual of one operation: for every picture corner `c`, the document the
    /// operation produced must draw it at the operation's image of where the original drew it —
    /// `G'(σc) = σ(G(c))`. `σ` is the op's own point map (`turn`/`unturn`/`flipH`/`flipV`).
    private func shapeResidual(_ new: [[Double]], _ old: [[Double]],
                               _ σ: (Double, Double) -> (Double, Double)) -> Double {
        var worst = 0.0
        for (x, y) in corners {
            let c = σ(x, y)
            let gn = PerspectiveMap.apply(new, x: c.0, y: c.1)
            let g = PerspectiveMap.apply(old, x: x, y: y)
            let go = σ(g.0, g.1)
            worst = max(worst, hypot(gn.0 - go.0, gn.1 - go.1))
        }
        return worst
    }

    private func rotatedCrop(_ r: CropRect, cw: Bool) -> CropRect {
        let (x, y, w, h) = (r.left, r.top, r.width, r.height)
        return cw ? CropRect(x: 1 - y - h, y: x, width: h, height: w)
                  : CropRect(x: y, y: 1 - x - w, width: h, height: w)
    }

    /// The pre-545 spelling, kept **only** so the table can print what the fix removed. It is not a
    /// second implementation of the shipped rule; nothing in the app calls it.
    private func preFix(_ g: GeometryGroup, _ op: GeometryGroup.QuarterTurnOperation) -> GeometryGroup {
        var n = g
        switch op {
        case .rotateCW, .rotateCCW:
            n.perspectiveVertical = -g.perspectiveHorizontal
            n.perspectiveHorizontal = -g.perspectiveVertical
            n.perspectiveShear = -g.perspectiveShear
            n.perspectiveAspect = 1 / g.perspectiveAspect
        case .mirrorH:
            n.perspectiveHorizontal = -g.perspectiveHorizontal
            n.perspectiveShear = -g.perspectiveShear
        case .mirrorV:
            n.perspectiveVertical = -g.perspectiveVertical
            n.perspectiveShear = -g.perspectiveShear
        }
        return n
    }

    private func crop(after g: GeometryGroup, _ op: GeometryGroup.QuarterTurnOperation) -> CropRect {
        let r = g.cropRect
        switch op {
        case .rotateCW:  return rotatedCrop(r, cw: true)
        case .rotateCCW: return rotatedCrop(r, cw: false)
        case .mirrorH:   return CropRect(x: 1 - r.left - r.width, y: r.top,
                                         width: r.width, height: r.height)
        case .mirrorV:   return CropRect(x: r.left, y: 1 - r.top - r.height,
                                         width: r.width, height: r.height)
        }
    }

    private func σ(_ op: GeometryGroup.QuarterTurnOperation)
        -> (Double, Double) -> (Double, Double) {
        switch op {
        case .rotateCW:  return turn
        case .rotateCCW: return unturn
        case .mirrorH:   return flipH
        case .mirrorV:   return flipV
        }
    }

    /// One row of §2: the residual of the pre-545 rule and of the shipped one.
    private func residual(perspective g: GeometryGroup,
                          op: GeometryGroup.QuarterTurnOperation) -> (before: Double, after: Double) {
        let old = forward(g)
        let σ = σ(op)
        let beforeG = preFix(g, op)
        let afterG = g.remapped(for: op)
        let before = shapeResidual(
            forward(beforeG.perspectiveVertical, beforeG.perspectiveHorizontal,
                    beforeG.perspectiveShear, beforeG.perspectiveAspect,
                    crop: crop(after: g, op), straighten: g.straightenDegrees,
                    turned: op.isRotation),
            old, σ)
        let after = shapeResidual(
            forward(afterG.perspectiveVertical, afterG.perspectiveHorizontal,
                    afterG.perspectiveShear, afterG.perspectiveAspect,
                    crop: crop(after: g, op), straighten: g.straightenDegrees,
                    turned: op.isRotation),
            old, σ)
        return (before, after)
    }

    private func base(_ v: Double = 0, _ h: Double = 0, _ k: Double = 0, _ a: Double = 1)
        -> GeometryGroup {
        GeometryGroup(crop: .full, quarterTurns: 0,
                      perspectiveVertical: v, perspectiveHorizontal: h,
                      perspectiveShear: k, perspectiveAspect: a)
    }

    // MARK: - §1 the baseline: what +vertical does with no turn, no mirror

    /// **The table every sign below is judged against**, measured through the real composed map and
    /// not read off a comment. `vertical = +60` magnifies the **top** edge by `1/w` (the raw map
    /// pushes it above `y = 0`, so the AABB normalisation puts it flush and pulls the **bottom** in):
    ///
    ///     corner   → canvas normalized          displacement
    ///     (0,0)    → ( 0.000000000, 0.000000000)   ( 0, 0)
    ///     (1,0)    → ( 1.000000000, 0.000000000)   ( 0, 0)
    ///     (1,1)    → ( 0.940733772, 1.000000000)   (−0.059266228, 0)
    ///     (0,1)    → ( 0.059266228, 1.000000000)   (+0.059266228, 0)
    ///
    /// i.e. **+vertical narrows the bottom** (and `+horizontal` narrows the left, symmetrically).
    /// So a quarter turn CW must carry a magnified **top** edge to a magnified **right** edge — which
    /// is `horizontal = +v`, not `−v`. That is the whole sign fix in one measured sentence.
    func testPositiveVerticalBaselineCorners() {
        let table: [(Double, [(Double, Double)])] = [
            (60, [(0, 0), (1, 0), (0.94073377234242717, 1), (0.05926622765757288, 1)]),
            (100, [(0, 0), (1, 0), (0.90497737556561075, 1), (0.09502262443438914, 1)]),
        ]
        for (value, expected) in table {
            let g = forward(value, 0, 0, 1)
            for (i, (x, y)) in corners.enumerated() {
                let p = PerspectiveMap.apply(g, x: x, y: y)
                XCTAssertEqual(p.0, expected[i].0, accuracy: 1e-9,
                               "vertical=+\(value) corner \(i).x")
                XCTAssertEqual(p.1, expected[i].1, accuracy: 1e-9,
                               "vertical=+\(value) corner \(i).y")
            }
            // The bottom edge is the narrow one at a positive slider, and its half-inset is the
            // number the table prints (0.0593 at +60, 0.0950 at +100).
            let bottom = expected[2].0 - expected[3].0
            XCTAssertEqual(bottom, 1 - 2 * abs(expected[3].0), accuracy: 1e-12)
            XCTAssertLessThan(bottom, 1, "vertical=+\(value) narrows the bottom")
        }
        // The sign is a real direction, not a label: `+v` narrows the bottom, `−v` the top (338's
        // mid-line reflection). This is what makes "CW needs `h' = +v`" a statement about the screen.
        func widths(_ v: Double) -> (top: Double, bottom: Double) {
            let g = forward(v, 0, 0, 1)
            let top = PerspectiveMap.apply(g, x: 1, y: 0).0 - PerspectiveMap.apply(g, x: 0, y: 0).0
            let bottom = PerspectiveMap.apply(g, x: 1, y: 1).0 - PerspectiveMap.apply(g, x: 0, y: 1).0
            return (top, bottom)
        }
        let plus = widths(60), minus = widths(-60)
        XCTAssertLessThan(plus.bottom, plus.top, "+vertical narrows the bottom")
        XCTAssertGreaterThan(minus.bottom, minus.top, "−vertical narrows the top")
        XCTAssertEqual(plus.top, minus.bottom, accuracy: 1e-12, "the pair is a reflection")
    }

    // MARK: - §2 the four operations × four knobs (pre/post)

    /// Each row is one knob, alone, so the number names that knob:
    /// `V` = `vertical 60`, `H` = `horizontal 60`, `shear` = `0.2`, `aspect` = a keystoned map with
    /// `aspect 1.4` (an aspect on its own is a canvas scale and does not move a normalized corner —
    /// the keystone is what makes it observable).
    func testCornerDisplacementTable() {
        let rows: [(String, GeometryGroup)] = [
            ("perspectiveV", base(60, 0, 0, 1)),
            ("perspectiveH", base(0, 60, 0, 1)),
            ("shear", base(0, 0, 0.2, 1)),
            ("aspect", base(0, 40, 0, 1.4)),
        ]
        let tolerance = 1e-9
        var table: [String: (before: Double, after: Double)] = [:]
        for (name, g) in rows {
            for op in GeometryGroup.QuarterTurnOperation.allCases {
                let r = residual(perspective: g, op: op)
                table["\(name) \(op.rawValue)"] = (r.before, r.after)
                let row = String(format: "545 · %-12@ %-9@ before %.6e after %.6e",
                                 name as NSString, op.rawValue as NSString, r.before, r.after)
                print(row)
            }
        }
        // The keystone (both knobs) and the aspect are **exact** under a quarter turn once the two
        // lines agree with `PerspectiveMap`'s own signs. The mirrors were already exact (489).
        for name in ["perspectiveV", "perspectiveH", "aspect"] {
            for op in GeometryGroup.QuarterTurnOperation.allCases {
                let r = table["\(name) \(op.rawValue)"]!
                XCTAssertLessThanOrEqual(r.after, tolerance,
                                         "\(name) \(op.rawValue): \(r.after)")
            }
        }
        // The rotating direction the old spelling got wrong: exactly one of the two rotations per
        // knob, and the table's `before` column is the size of the red a revert would show.
        XCTAssertGreaterThan(table["perspectiveV rotateCW"]!.before, 5e-2)
        XCTAssertLessThanOrEqual(table["perspectiveV rotateCCW"]!.before, tolerance)
        XCTAssertGreaterThan(table["perspectiveH rotateCCW"]!.before, 5e-2)
        XCTAssertLessThanOrEqual(table["perspectiveH rotateCW"]!.before, tolerance)
        // `shear` is **not** rotation-closed — see `testTheShearCannotBeTurnedInThisOrder`; the rule
        // is deliberately left alone (the fix would be the pipeline reorder 545 §3 evaluates), so the
        // row pins that it did not move rather than pretending it is zero.
        for op in [GeometryGroup.QuarterTurnOperation.rotateCW, .rotateCCW] {
            let r = table["shear \(op.rawValue)"]!
            XCTAssertEqual(r.after, r.before, accuracy: 1e-12, "shear \(op.rawValue) unchanged")
            XCTAssertGreaterThan(r.after, 1e-1, "shear \(op.rawValue) is not rotation-closed")
        }
        for op in [GeometryGroup.QuarterTurnOperation.mirrorH, .mirrorV] {
            XCTAssertLessThanOrEqual(table["shear \(op.rawValue)"]!.after, tolerance,
                                     "a mirror *does* carry the shear exactly")
        }
    }

    /// **The exact form of the sign fix**, independent of the corner table: one quarter turn CW is
    /// `v' = −h, h' = +v`; CCW is its inverse `v' = +h, h' = −v`. The two are each other's inverse,
    /// which is what makes four presses the identity (`GeometryRemap489Tests`).
    func testQuarterTurnSwapsTheTwoKnobsWithOneSign() {
        let g = base(40, -30, 0, 1)
        let cw = g.remapped(for: .rotateCW)
        XCTAssertEqual(cw.perspectiveVertical, 30, accuracy: 1e-15)
        XCTAssertEqual(cw.perspectiveHorizontal, 40, accuracy: 1e-15)
        let ccw = g.remapped(for: .rotateCCW)
        XCTAssertEqual(ccw.perspectiveVertical, -30, accuracy: 1e-15)
        XCTAssertEqual(ccw.perspectiveHorizontal, -40, accuracy: 1e-15)
        // Fixed point of the fix: the two rotations are inverses on these two fields.
        XCTAssertEqual(cw.remapped(for: .rotateCCW).perspectiveVertical, g.perspectiveVertical, accuracy: 1e-15)
        XCTAssertEqual(cw.remapped(for: .rotateCCW).perspectiveHorizontal, g.perspectiveHorizontal, accuracy: 1e-15)
        // A **pure** vertical keystone is the user's case: CW must put a magnified top on the right,
        // i.e. `horizontal = +v`. The old `−v` is the mirror image of that (measured in §2).
        XCTAssertEqual(base(60, 0, 0, 1).remapped(for: .rotateCW).perspectiveHorizontal, 60, accuracy: 1e-15)
        XCTAssertEqual(base(0, 60, 0, 1).remapped(for: .rotateCCW).perspectiveVertical, 60, accuracy: 1e-15)
    }

    /// Why the shear row is the one that stays: a horizontal shear `S(k): (x,y) ↦ (x + k·y, y)`
    /// conjugated by a quarter turn is a **vertical** shear — `τ S(k) τ⁻¹: (x,y) ↦ (x, y + k·(1−x))`
    /// — and `PerspectiveMap` has one horizontal shear knob and no vertical one (407 §2.5). So no
    /// choice of `perspectiveShear` can make the corners agree; the fix is the order change 545 §3
    /// lists, not a sign. This test measures the statement instead of trusting the prose: the best
    /// horizontal shear (`+k`, the row above) still misses by 1.67e−1, the negated one by 2.36e−1.
    func testTheShearCannotBeTurnedInThisOrder() {
        let g = base(0, 0, 0.2, 1)
        let old = forward(g)
        let kept = forward(0.2, 0, 0, 1)
        let negated = forward(-0.2, 0, 0, 1)
        let best = shapeResidual(kept, old, turn)
        let shipped = shapeResidual(negated, old, turn)
        print(String(format: "545 · shear under a quarter turn: +k %.6e, −k %.6e", best, shipped))
        XCTAssertGreaterThan(best, 1e-1, "no horizontal shear can be the conjugated vertical one")
        // And the same shear under a mirror *is* exact — the mirror is a reflection in the same
        // plane, so no axis is lost.
        XCTAssertLessThanOrEqual(shapeResidual(forward(0, 0, -0.2, 1), old, flipH), 1e-9)
    }

    /// A keystoned document keeps its crop on the **document canvas** (330), so the shipped map is
    /// `canvasCrop(document:crop:)`, not `perspectiveCanvas(crop:)`. The same sign has to hold there —
    /// otherwise the fix would only exist on a path no keystoned document takes.
    func testCanvasSpacedCropKeepsTheShape() {
        let crop = NormalizedRect(x: 0.1, y: 0.05, width: 0.6, height: 0.55)
        for (v, h) in [(60.0, 0.0), (0.0, 60.0), (40.0, -30.0)] {
            let g = GeometryGroup(crop: crop, aspectLock: .original, quarterTurns: 0,
                                  perspectiveVertical: v, perspectiveHorizontal: h,
                                  cropSpace: .canvas)
            for (op, σ) in [(GeometryGroup.QuarterTurnOperation.rotateCW, turn), (.rotateCCW, unturn)] {
                guard let old = CropGeometry(geometry: g, source: source).exportPerspectiveCanvas,
                      let new = CropGeometry(geometry: g.remapped(for: op),
                                             source: source).exportPerspectiveCanvas else {
                    XCTFail("a keystoned document has an export canvas")
                    continue
                }
                let r = shapeResidual(new.forward, old.forward, σ)
                print(String(format: "545 · canvas crop v=%.0f h=%.0f %@ residual %.6e",
                             v, h, op.rawValue, r))
                XCTAssertLessThanOrEqual(r, 1e-9, "\(op.rawValue) v=\(v) h=\(h)")
            }
        }
    }

    // MARK: - §3 引导线 follow every entry

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-545-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CropToolController.guideLinesFollowRemap = true
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private var documentWithLines: GeometryGroup {
        GeometryGroup(crop: .full,
                      aspectLock: .original,
                      quarterTurns: 0,
                      perspectiveVertical: 40, perspectiveHorizontal: -30,
                      perspectiveShear: 0.2, perspectiveAspect: 1.5,
                      cropSpace: .source,
                      guideLines: [
                        StoredGuideLine(ax: 0.2, ay: 0.25, bx: 0.75, by: 0.35, vertical: true),
                        StoredGuideLine(ax: 0.15, ay: 0.7, bx: 0.85, by: 0.62, vertical: false),
                      ])
    }

    private func makeTool() throws -> (CatalogSession, CropToolController) {
        let directory = workDir.appendingPathComponent("t-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (session, _) = try CropUITestSupport.makeSession(in: directory,
                                                             width: source.width,
                                                             height: source.height)
        let base = documentWithLines
        session.applyEdit { $0.geometry = base }
        _ = session.commitEdit(label: "545 setup", coalesce: false)
        let tool = CropToolController(session: session)
        XCTAssertTrue(tool.begin(), "545: 进裁切模式")
        XCTAssertTrue(tool.setGuideLinesArmed(true), "545: 打开引导线")
        XCTAssertEqual(tool.guideLines.count, 2, "545: 两条线在文档里")
        return (session, tool)
    }

    private func guardLineFields(_ lines: [StoredGuideLine]) -> [Double] {
        lines.flatMap { [$0.ax, $0.ay, $0.bx, $0.by] }
    }

    /// **The four entries.** One press of each operation, then the drawn set, the draft's copy and the
    /// document must all be the endpoints of "the same document turned/mirrored first, then measured":
    /// `base.remapped(for: op).guideLines` — the very map the picture went through.
    ///
    /// Before 545 the document and the draft moved and the **drawn** copy did not (it is only seeded by
    /// `reloadGuideLines`), so the frame turned under lines that stayed on the old pixels — the user's
    /// 「引导线没有跟着旋转」. `adoptRemappedGuideLines` is that copy.
    func testGuideLinesFollowAllFourEntries() throws {
        let expectedBase = documentWithLines
        for (op, door) in [
            (GeometryGroup.QuarterTurnOperation.rotateCW, "rotateQuarter(CW)"),
            (.rotateCCW, "rotateQuarter(CCW)"),
            (.mirrorH, "toggleFlipHorizontal"),
            (.mirrorV, "toggleFlipVertical"),
        ] {
            let (session, tool) = try makeTool()
            switch op {
            case .rotateCW:  XCTAssertTrue(tool.rotateQuarter(clockwise: true))
            case .rotateCCW: XCTAssertTrue(tool.rotateQuarter(clockwise: false))
            case .mirrorH:   XCTAssertTrue(tool.toggleFlipHorizontal())
            case .mirrorV:   XCTAssertTrue(tool.toggleFlipVertical())
            }
            let expected = expectedBase.remapped(for: op).guideLines
            XCTAssertEqual(expected.count, 2, door)
            let drawn = guardLineFields(tool.guideLines.map(CropToolController.stored))
            XCTAssertEqual(drawn.count, 8, "\(door): the drawn set")
            for (a, b) in zip(drawn, guardLineFields(expected)) {
                XCTAssertEqual(a, b, accuracy: 1e-12, "\(door): drawn endpoints follow the picture")
            }
            XCTAssertEqual(tool.draft.guideLines.map(\.ax), expected.map(\.ax), "\(door): draft")
            XCTAssertEqual(tool.draft.guideLines.map(\.ay), expected.map(\.ay), "\(door): draft")
            XCTAssertEqual(session.edit.geometry.guideLines.map(\.bx), expected.map(\.bx), "\(door): document")
            XCTAssertEqual(session.edit.geometry.guideLines.map(\.by), expected.map(\.by), "\(door): document")
            XCTAssertTrue(tool.guideLines.allSatisfy { $0.a.x.isFinite && $0.b.y.isFinite })
            tool.cancel()
        }
    }

    /// The **menu / card** door (`LoupeController.remapDraft` → `CropToolController.remapDraft`), not
    /// the crop bar's: the same copy, reached by the other caller.
    func testGuideLinesFollowTheMenuRemapDoor() throws {
        let (session, tool) = try makeTool()
        let before = session.edit.geometry
        // The card writes the document first, then remaps the draft — the app's order (LoupeController).
        session.applyEdit { $0.geometry = before.remapped(for: .rotateCW) }
        tool.remapDraft(for: .rotateCW, from: before)
        let expected = documentWithLines.remapped(for: .rotateCW).guideLines
        let drawn = guardLineFields(tool.guideLines.map(CropToolController.stored))
        for (a, b) in zip(drawn, guardLineFields(expected)) {
            XCTAssertEqual(a, b, accuracy: 1e-12, "menu door: drawn endpoints")
        }
        tool.cancel()
    }

    /// **545 reverse gate** — the pre-545 shape: the draft and the document move, the drawn copy does
    /// not. The assertion above is exactly what goes red.
    func testReverseGateWithoutAdoptingGuideLinesTheDrawnSetStays() throws {
        CropToolController.guideLinesFollowRemap = false
        let (session, tool) = try makeTool()
        let before = guardLineFields(tool.guideLines.map(CropToolController.stored))
        XCTAssertTrue(tool.rotateQuarter(clockwise: true))
        let after = guardLineFields(tool.guideLines.map(CropToolController.stored))
        XCTAssertEqual(after, before, "gate off: the drawing copy must stay where it was")
        let expected = guardLineFields(documentWithLines.remapped(for: .rotateCW).guideLines)
        XCTAssertNotEqual(after, expected, "gate off: it is *not* the turned endpoints")
        // The draft still moved — that is what makes the drawn copy the only wrong half.
        XCTAssertNotEqual(guardLineFields(tool.draft.guideLines), before)
        tool.cancel()
    }
}
