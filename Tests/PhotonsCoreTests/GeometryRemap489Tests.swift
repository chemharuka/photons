import XCTest
import PhotonsCore

/// 489 §2.12/§2.14 — the one pure remap every 左转/右转/镜像 entry point goes through.
///
/// The arithmetic is pinned field by field (four operations × every field), the D4 normalisation is
/// pinned by comparing the **point map** every equivalent triple represents, and the three round
/// trips the ticket names are asserted on `GeometryGroup: Equatable`.
final class GeometryRemap489Tests: XCTestCase {

    private func base() -> GeometryGroup {
        GeometryGroup(crop: NormalizedRect(x: 0.1, y: 0.2, width: 0.5, height: 0.3),
                      rotationDegrees: 3.5,
                      flipHorizontal: false, flipVertical: false,
                      aspectLock: .square,
                      quarterTurns: 1,
                      perspectiveVertical: 40,
                      perspectiveHorizontal: -30,
                      perspectiveShear: 0.2,
                      perspectiveAspect: 1.5,
                      cropSpace: .canvas,
                      guideLines: [StoredGuideLine(ax: 0.2, ay: 0.3, bx: 0.7, by: 0.8,
                                                   vertical: true)])
    }

    // MARK: - one operation, every field

    func testRotateClockwiseRemapsEveryField() {
        let g = base().remapped(for: .rotateCW)
        XCTAssertEqual(g.quarterTurns, 2)
        XCTAssertEqual(g.crop, NormalizedRect(x: 0.5, y: 0.1, width: 0.3, height: 0.5))
        XCTAssertEqual(g.flipHorizontal, false)
        XCTAssertEqual(g.flipVertical, false)
        XCTAssertEqual(g.rotationDegrees, 3.5, accuracy: 1e-15)
        XCTAssertEqual(g.aspectLock, .square, "a 1:1 lock survives a quarter turn")
        XCTAssertEqual(g.perspectiveVertical, 30, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveHorizontal, -40, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveShear, -0.2, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveAspect, 2.0 / 3.0, accuracy: 1e-15)
        XCTAssertEqual(g.cropSpace, .canvas)
        XCTAssertEqual(g.guideLines.first?.ax ?? -1, 0.7, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.ay ?? -1, 0.2, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.bx ?? -1, 0.2, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.by ?? -1, 0.7, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.vertical, true, "the axis is the user's intent, not a coordinate")
    }

    func testRotateCounterClockwiseRemapsEveryField() {
        let g = base().remapped(for: .rotateCCW)
        XCTAssertEqual(g.quarterTurns, 0)
        XCTAssertEqual(g.crop, NormalizedRect(x: 0.2, y: 0.4, width: 0.3, height: 0.5))
        XCTAssertEqual(g.perspectiveVertical, 30, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveHorizontal, -40, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveShear, -0.2, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveAspect, 2.0 / 3.0, accuracy: 1e-15)
        XCTAssertEqual(g.rotationDegrees, 3.5, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.ax ?? -1, 0.3, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.ay ?? -1, 0.8, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.bx ?? -1, 0.8, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.by ?? -1, 0.3, accuracy: 1e-15)
    }

    func testMirrorHorizontalRemapsEveryField() {
        let g = base().remapped(for: .mirrorH)
        XCTAssertEqual(g.crop, NormalizedRect(x: 0.4, y: 0.2, width: 0.5, height: 0.3))
        XCTAssertEqual(g.flipHorizontal, true)
        XCTAssertEqual(g.flipVertical, false)
        XCTAssertEqual(g.quarterTurns, 1)
        XCTAssertEqual(g.perspectiveVertical, 40, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveHorizontal, 30, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveShear, -0.2, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveAspect, 1.5, accuracy: 1e-15)
        XCTAssertEqual(g.rotationDegrees, 3.5, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.ax ?? -1, 0.8, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.bx ?? -1, 0.3, accuracy: 1e-15)
    }

    func testMirrorVerticalRemapsEveryFieldAndKeepsTheSwitchBit() {
        // The stored triple keeps the flag the user pressed; `canonicalized` is the D4-spelling
        // function (pinned separately, and used by the 64-orientation acceptance).
        let g = base().remapped(for: .mirrorV)
        XCTAssertEqual(g.crop, NormalizedRect(x: 0.1, y: 0.5, width: 0.5, height: 0.3))
        XCTAssertEqual(g.quarterTurns, 1)
        XCTAssertEqual(g.flipHorizontal, false)
        XCTAssertEqual(g.flipVertical, true)
        XCTAssertEqual(g.perspectiveVertical, -40, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveHorizontal, -30, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveShear, -0.2, accuracy: 1e-15)
        XCTAssertEqual(g.perspectiveAspect, 1.5, accuracy: 1e-15)
        XCTAssertEqual(g.rotationDegrees, 3.5, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.ay ?? -1, 0.7, accuracy: 1e-15)
        XCTAssertEqual(g.guideLines.first?.by ?? -1, 0.2, accuracy: 1e-15)
    }

    // MARK: - D4 normalisation

    private func pointMap(_ g: GeometryGroup, _ p: NormalizedPoint) -> NormalizedPoint {
        var q = p
        for _ in 0..<GeometryGroup.normalizedQuarterTurns(g.quarterTurns) {
            q = NormalizedPoint(1 - q.y, q.x)
        }
        if g.flipHorizontal { q = NormalizedPoint(1 - q.x, q.y) }
        if g.flipVertical { q = NormalizedPoint(q.x, 1 - q.y) }
        return q
    }

    func testEveryTripleAndItsCanonicalFormAreTheSamePicture() {
        for q in 0..<4 {
            for h in 0..<2 {
                for v in 0..<2 {
                    var g = GeometryGroup(crop: .full, quarterTurns: q)
                    g.flipHorizontal = h == 1
                    g.flipVertical = v == 1
                    let c = g.canonicalized
                    for (x, y) in [(0.0, 0.0), (1.0, 0.0), (0.3, 0.8)] {
                        let a = pointMap(g, NormalizedPoint(x, y))
                        let b = pointMap(c, NormalizedPoint(x, y))
                        XCTAssertEqual(a.x, b.x, accuracy: 1e-15, "q\(q)H\(h)V\(v)")
                        XCTAssertEqual(a.y, b.y, accuracy: 1e-15, "q\(q)H\(h)V\(v)")
                    }
                    XCTAssertFalse(c.flipHorizontal && c.flipVertical,
                                   "canonical form may not keep both flips")
                    XCTAssertFalse(c.flipVertical, "canonical form may not keep V alone")
                }
            }
        }
    }

    // MARK: - round trips (hard)

    func testFourClockwiseTurnsAreTheIdentityOnEveryField() {
        var g = GeometryGroup(crop: NormalizedRect(x: 0.125, y: 0.25, width: 0.5, height: 0.25),
                              rotationDegrees: -7.0,
                              flipHorizontal: false, flipVertical: false,
                              aspectLock: .original,
                              quarterTurns: 1,
                              perspectiveVertical: 40,
                              perspectiveHorizontal: -20,
                              perspectiveShear: 0.25,
                              perspectiveAspect: 2,
                              cropSpace: .source,
                              guideLines: [StoredGuideLine(ax: 0.125, ay: 0.25,
                                                           bx: 0.5, by: 0.75,
                                                           vertical: true)])
        let start = g
        for _ in 0..<4 { g = g.remapped(for: .rotateCW) }
        XCTAssertEqual(g, start)
    }

    func testTwoMirrorsAreTheIdentity() {
        let base = GeometryGroup(crop: NormalizedRect(x: 0.125, y: 0.25, width: 0.5, height: 0.25),
                                 rotationDegrees: 2.0,
                                 aspectLock: .original,
                                 quarterTurns: 0,
                                 perspectiveVertical: 30,
                                 perspectiveHorizontal: -20,
                                 perspectiveShear: 0.125,
                                 perspectiveAspect: 1.5,
                                 guideLines: [StoredGuideLine(ax: 0.125, ay: 0.25,
                                                              bx: 0.5, by: 0.75,
                                                              vertical: false)])
        for op in [GeometryGroup.QuarterTurnOperation.mirrorH, .mirrorV] {
            XCTAssertEqual(base.remapped(for: op).remapped(for: op), base, "\(op)")
        }
    }

    func testRotateThenMirrorThenMirrorThenRotateBackIsTheIdentity() {
        var start = base().canonicalized
        // Guide endpoints use a dyadic pair here: `1 − (1 − x)` is not exact for 0.3, and this
        // assertion is about the **D4 word**, not about the doubles of a stored line (the four-turn
        // test above covers the endpoint map).
        start.guideLines = []
        let g = start.remapped(for: .rotateCW)
            .remapped(for: .mirrorH)
            .remapped(for: .mirrorH)
            .remapped(for: .rotateCCW)
        XCTAssertEqual(g, start)
    }
}

// MARK: - 489 §2.16: masks already travel with the photograph

extension GeometryRemap489Tests {

    /// Mask shapes are stored in the **file's** frame (`Masks.swift`), while `MaskCanvasMapping`
    /// applies the document's `quarterTurns` and flips on the way to the canvas. So the answer to
    /// 「旋转/镜像后蒙版还贴在同一图像特征上吗」 is yes without rewriting a single mask coordinate —
    /// this test pins that by mapping the same source point under the four orientations and checking
    /// the result is exactly the same point turn applied to the canvas point.
    func testMasksStayOnTheSameFeatureThroughQuarterTurnAndMirrors() {
        let source = ImageSize(width: 200, height: 120)
        let origin = (x: 0.0, y: 0.0)
        let p = NormalizedPoint(0.25, 0.5)

        func normalized(_ geometry: GeometryGroup) -> (x: Double, y: Double) {
            let oriented = geometry.orientedSource(source)
            let map = MaskCanvasMapping(geometry: geometry, source: source,
                                        content: oriented, canvas: oriented, origin: origin)
            let q = map.canvasPoint(p)
            return ((q.x + 0.5) / Double(oriented.width),
                    (q.y + 0.5) / Double(oriented.height))
        }

        let upright = normalized(GeometryGroup(crop: .full))
        XCTAssertEqual(upright.x, 0.25, accuracy: 1e-12)
        XCTAssertEqual(upright.y, 0.5, accuracy: 1e-12)

        let cw = normalized(GeometryGroup(crop: .full, quarterTurns: 1))
        XCTAssertEqual(cw.x, 1 - upright.y, accuracy: 1e-12)
        XCTAssertEqual(cw.y, upright.x, accuracy: 1e-12)

        let ccw = normalized(GeometryGroup(crop: .full, quarterTurns: 3))
        XCTAssertEqual(ccw.x, upright.y, accuracy: 1e-12)
        XCTAssertEqual(ccw.y, 1 - upright.x, accuracy: 1e-12)

        var mirrorH = GeometryGroup(crop: .full)
        mirrorH.flipHorizontal = true
        let h = normalized(mirrorH)
        XCTAssertEqual(h.x, 1 - upright.x, accuracy: 1e-12)
        XCTAssertEqual(h.y, upright.y, accuracy: 1e-12)

        var mirrorV = GeometryGroup(crop: .full)
        mirrorV.flipVertical = true
        let v = normalized(mirrorV)
        XCTAssertEqual(v.x, upright.x, accuracy: 1e-12)
        XCTAssertEqual(v.y, 1 - upright.y, accuracy: 1e-12)
    }
}
