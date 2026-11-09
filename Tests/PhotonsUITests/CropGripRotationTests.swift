import XCTest
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 312 — 「裁剪框在旋转时，四边中心的拖动指示条（白色粗线）不会跟着旋转」.
///
/// The bar on an edge grip is drawn `grip.point ± along·half`, and `along` used to be a constant:
/// `(1,0)` for top/bottom, `(0,1)` for left/right. The corner brackets already read their direction
/// off `layout.corners`, so a straightened (turned) quad drew brackets that turned with the frame and
/// bars that did not — the exact defect the user reported.
///
/// Five things are pinned here, all measured on the **real** `CropTool.layout` quad (no snapshot, no
/// screenshot, no hand-built corners):
///
///   1. **direction** — the bar's `along` is parallel to the side it moves, to ≤ 0.5°, at every
///      straighten angle the user can dial (0, 9, 15, −30, 45);
///   2. **length** — the bar is `edgeBarLength` long (± 0.5 pt) at every angle, so turning the frame
///      never resizes the target;
///   3. **midpoint** — the bar's midpoint is the side's midpoint (± 0.5 pt);
///   4. **0° is untouched** — at 0° `along` is still exactly `(1,0)` / `(0,1)`, so the upright path is
///      bit-for-bit the old arithmetic;
///   5. **reverse gate** — replay the assertion against the *old* constants: it goes red at 9 / 15 /
///      −30 / 45 and stays green at 0, which is what makes 1 a proof rather than a tautology.
@MainActor
final class CropGripRotationTests: XCTestCase {

    private static let source = ImageSize(width: 6000, height: 4000)
    private static let viewport = ImageSize(width: 900, height: 700)
    /// An inset frame, so no side is degenerate and every side has a direction.
    private static let crop = CropRect(left: 0.15, top: 0.12, right: 0.82, bottom: 0.88)

    private static let angles: [Double] = [0, 9, 15, -30, 45]

    /// The four edge grips and the corner pair that *is* that side, indexed in `CropTool.layout`'s
    /// corner order (top-left, top-right, bottom-right, bottom-left). 312 §2's table, written out here
    /// so the test derives the direction it expects instead of asking the view for its own answer.
    private static let edges: [(kind: CropToolHandle, from: Int, to: Int)] = [
        (.top, 0, 1),
        (.right, 1, 2),
        (.bottom, 3, 2),
        (.left, 0, 3),
    ]

    /// The real quad of a straightened draft: the document framing carries **no** angle (088 — the
    /// picture on screen is un-turned), and the frame's own space is turned by `quadRotationDegrees`.
    private func layout(_ degrees: Double) -> CropToolLayout {
        let framing = LoupeFraming(viewport: Self.viewport,
                                   sourceWidth: Double(Self.source.width),
                                   sourceHeight: Double(Self.source.height),
                                   crop: .full,
                                   straightenDegrees: 0)
        return CropTool.layout(crop: Self.crop, source: Self.source,
                               mapping: framing.mapping(of: .fit),
                               pointScale: 1, showsGrid: false,
                               quadRotationDegrees: degrees)
    }

    private func grip(_ kind: CropToolHandle, in layout: CropToolLayout) -> CropToolLayout.Grip {
        guard let found = layout.grips.first(where: { $0.kind == kind }) else {
            XCTFail("layout has no \(kind) grip")
            return CropToolLayout.Grip(kind: kind, point: .zero)
        }
        return found
    }

    /// The bar as the canvas strokes it — the view's own pure geometry, not a re-derivation here.
    private func bar(_ kind: CropToolHandle, in layout: CropToolLayout) -> CropToolOverlayView.EdgeBar {
        CropToolOverlayView.edgeBarGeometry(for: kind, in: layout)
    }

    /// Unsigned angle between two vectors, in degrees (0…180). Symmetric, so a bar that ended up
    /// pointing the wrong way along its side would read as 180° and never pass as 0°.
    private func angleDegrees(_ a: CGPoint, _ b: CGPoint) -> Double {
        let cross = abs(Double(a.x) * Double(b.y) - Double(a.y) * Double(b.x))
        let dot = Double(a.x) * Double(b.x) + Double(a.y) * Double(b.y)
        return atan2(cross, dot) * 180 / .pi
    }

    private func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-9 else { return .zero }
        return CGPoint(x: dx / length, y: dy / length)
    }

    /// The bar's two ends, exactly as `draw(grip:in:)` builds the path.
    private func barEnds(_ kind: CropToolHandle,
                         in layout: CropToolLayout) -> (a: CGPoint, b: CGPoint) {
        let geometry = bar(kind, in: layout)
        return (geometry.start, geometry.end)
    }

    // MARK: - 1. the bar is parallel to its own side, at every angle

    /// The whole defect in one number: `along` against the side's own corner-to-corner direction.
    /// ≤ 0.5° at 0 / 9 / 15 / −30 / 45, on all four sides — the table is printed so the report can
    /// quote it.
    func testEveryEdgeBarIsParallelToItsSideAtEveryStraightenAngle() {
        var worst = 0.0
        for degrees in Self.angles {
            let quad = layout(degrees)
            XCTAssertEqual(quad.corners.count, 4)
            var row: [String] = []
            for edge in Self.edges {
                let side = unit(quad.corners[edge.from], quad.corners[edge.to])
                XCTAssertGreaterThan((side.x * side.x + side.y * side.y).squareRoot(), 0.5,
                                     "\(edge.kind) side collapsed at \(degrees)°")
                let along = bar(edge.kind, in: quad).along
                let deviation = angleDegrees(along, side)
                worst = max(worst, deviation)
                row.append(String(format: "%@ %.4f°", edge.kind.rawValue, deviation))
                XCTAssertLessThanOrEqual(deviation, 0.5,
                                         "312: the \(edge.kind) bar is \(deviation)° off its side "
                                         + "at \(degrees)° (along \(along), side \(side))")
            }
            print("312 θ=\(degrees)° · " + row.joined(separator: " · "))
        }
        print(String(format: "312 · worst edge-bar deviation %.4f° over %d angles × 4 edges",
                     worst, Self.angles.count))
    }

    // MARK: - 2. the bar keeps its length

    /// 22 pt at every angle: the bar is a target, and a turned frame must not make it shorter or
    /// longer than the upright one. (± 0.5 pt, i.e. the same tolerance as every other length here.)
    func testTheEdgeBarLengthIsTheSameAtEveryAngle() {
        for degrees in Self.angles {
            let quad = layout(degrees)
            for edge in Self.edges {
                let ends = barEnds(edge.kind, in: quad)
                let length = hypot(ends.b.x - ends.a.x, ends.b.y - ends.a.y)
                print(String(format: "312 length θ=%.0f° %@ %.4f pt", degrees,
                             edge.kind.rawValue, Double(length)))
                XCTAssertEqual(Double(length), Double(CropToolOverlayView.edgeBarLength),
                               accuracy: 0.5,
                               "312: the \(edge.kind) bar is \(length) pt at \(degrees)°, "
                               + "expected \(CropToolOverlayView.edgeBarLength)")
            }
        }
    }

    // MARK: - 3. the bar is centred on its side

    /// The midpoint of the drawn bar is the midpoint of the two corners of that side — so the bar sits
    /// on the edge it drags, not beside it, whatever the angle.
    func testTheEdgeBarIsCentredOnItsSide() {
        for degrees in Self.angles {
            let quad = layout(degrees)
            for edge in Self.edges {
                let ends = barEnds(edge.kind, in: quad)
                let midpoint = CGPoint(x: (ends.a.x + ends.b.x) / 2, y: (ends.a.y + ends.b.y) / 2)
                let sideMid = CGPoint(x: (quad.corners[edge.from].x + quad.corners[edge.to].x) / 2,
                                      y: (quad.corners[edge.from].y + quad.corners[edge.to].y) / 2)
                XCTAssertEqual(Double(midpoint.x), Double(sideMid.x), accuracy: 0.5,
                               "312: \(edge.kind) bar midpoint x drifted at \(degrees)°")
                XCTAssertEqual(Double(midpoint.y), Double(sideMid.y), accuracy: 0.5,
                               "312: \(edge.kind) bar midpoint y drifted at \(degrees)°")
            }
        }
    }

    // MARK: - 4. 0° is the old arithmetic, value for value

    /// The upright path must not change by even a rounding step: at 0° the direction read off the
    /// corners *is* the old constant. Compared with `==`, not a tolerance — nothing here is a fit.
    func testTheUprightDirectionIsStillTheOldConstant() {
        let quad = layout(0)
        for edge in Self.edges {
            let along = bar(edge.kind, in: quad).along
            let constant: CGPoint = (edge.kind == .left || edge.kind == .right)
                ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
            print("312 upright \(edge.kind.rawValue) along \(along) == \(constant)")
            XCTAssertEqual(along, constant, "312: 0° no longer reproduces the old constant for \(edge.kind)")
        }
    }

    // MARK: - 5. reverse gate

    /// The same measure against the **old** direction — the constants this task removes. If the
    /// assertion in §1 were not measuring rotation, this would pass everywhere; it does not: it is
    /// above the 0.5° line at 9 / 15 / −30 / 45 and still green at 0. That is the gate.
    func testTheOldConstantDirectionIsCaughtAtEveryAngleButZero() {
        for degrees in Self.angles {
            let quad = layout(degrees)
            XCTAssertEqual(quad.corners.count, 4)
            for edge in Self.edges {
                let old: CGPoint = (edge.kind == .left || edge.kind == .right)
                    ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
                let side = unit(quad.corners[edge.from], quad.corners[edge.to])
                let deviation = angleDegrees(old, side)
                print(String(format: "312 gate θ=%.0f° %@ old-constant deviation %.4f°",
                             degrees, edge.kind.rawValue, deviation))
                if degrees == 0 {
                    XCTAssertLessThanOrEqual(deviation, 0.5,
                                             "312: the gate must stay green at 0° for \(edge.kind)")
                } else {
                    XCTAssertGreaterThan(deviation, 0.5,
                                         "312: the gate would not have caught \(edge.kind) at \(degrees)° "
                                         + "(deviation \(deviation)°) — §1 is not measuring rotation")
                }
            }
        }
    }
}
