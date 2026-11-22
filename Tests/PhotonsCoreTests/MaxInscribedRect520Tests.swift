import XCTest
import PhotonsCore

/// **520 — 自动裁剪 after a perspective correction must reach the maximum-area rectangle.**
///
/// The new solver (`MaxInscribedRect`) is compared with three independent things:
///
///  * a **4000 × 4000 grid** lower bound over the same (legal-box-clipped) polygon;
///  * the hull's own area (an upper bound);
///  * the two answers the product shipped before — `AutoCropSolver.maximumRectangle` (489) and the
///    controller's private `bandRectangle` (505), rebuilt here exactly as they were.
///
/// The grid is only a **lower** bound; the exact solver must be at least it and no larger than the
/// hull. `new ≥ old-max` is asserted on every fixture, and strictly `>` on the fixtures that can
/// actually discriminate (see the note printed by the table).
///
/// `print` is buffered away by a redirected `swift test`; the table goes to stderr so the report can
/// quote it.
private func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

final class MaxInscribedRect520Tests: XCTestCase {

    private struct Fixture {
        let name: String
        let polygon: [NormalizedPoint]
        /// `true` when the old answer is provably smaller (not merely equal), so the 520 assertion
        /// `new > old-max` has teeth and the reverse gate can turn it red.
        let discriminating: Bool
    }

    // MARK: - the six fixtures

    private static let source = ImageSize(width: 480, height: 320)

    private func fixtures() -> [Fixture] {
        // (A) the synthetic axis-parallel trapezoid from the 505 probe; 489's solver returns `nil`.
        let a = [NormalizedPoint(0, 0), NormalizedPoint(1, 0),
                 NormalizedPoint(0.97, 1), NormalizedPoint(0.03, 1)]
        // (B) the 505 `+30 / 0°` keystone, taken from the canvas' own forward map.
        let b = canvasCorners(vertical: 30, horizontal: 0, shear: 0, straighten: 0)
        // (C) the two-axis + straighten fixture in the ticket.
        let c = canvasCorners(vertical: 30, horizontal: -20, shear: 0, straighten: 8)
        // (D) the same trapezoid turned 3° about the frame centre.
        let d = rotate(a, degrees: 3)
        // (E) a triangle: the band construction has no positive answer here at all.
        let e = [NormalizedPoint(0, 0), NormalizedPoint(1, 0), NormalizedPoint(0.5, 1)]
        // (F) a long thin hexagon with **horizontal** top and bottom edges. Its optimum is shorter
        // than the full y-range, which is exactly what 505's band cannot express: the band is pinned
        // to the vertex y's, so it must use the narrow top edge over the whole height.
        let f = [NormalizedPoint(0, 0), NormalizedPoint(1, 0),
                 NormalizedPoint(1, 0.35), NormalizedPoint(0.65, 0.8),
                 NormalizedPoint(0.35, 0.8), NormalizedPoint(0, 0.35)]
        // (G) **the real-world case the six above miss**: a 480×320 photograph turned 30° about its
        // centre. At this angle the optimum's sides are limited by vertices, so 489's edge
        // enumeration is far below it (and returns `nil` at 40–45°); this is what the UI test ⑧
        // measures through the renderer.
        let g = turnedPicture(degrees: 30)
        return [
            Fixture(name: "A 轴平行梯形", polygon: a, discriminating: false),
            Fixture(name: "B +30 / 0° keystone", polygon: b, discriminating: false),
            Fixture(name: "C +30 / −20 / 8°", polygon: c, discriminating: false),
            Fixture(name: "D 梯形转 3°", polygon: d, discriminating: false),
            Fixture(name: "E 三角形", polygon: e, discriminating: true),
            Fixture(name: "F 细长六边形", polygon: f, discriminating: true),
            Fixture(name: "G 纯拉直 30° (480×320)", polygon: g, discriminating: true),
        ]
    }

    // MARK: - the table / acceptance

    func testTheExactSolverReachesTheGridOptimumAndNeverLosesToTheOldAnswer() throws {
        for fixture in fixtures() {
            let raw = fixture.polygon
            let legal = clipToUnit(raw)
            let new = try XCTUnwrap(MaxInscribedRect.maximumRectangle(in: raw),
                                    "\(fixture.name): 精确解不应为 nil")
            let newArea = Double(new.width * new.height)
            let oldSolverArea = oldSolverArea(raw)
            let oldBandArea = oldBandArea(raw) ?? 0
            let oldMax = max(oldSolverArea, oldBandArea)
            let grid = gridArea(legal, steps: 4000)
            let hullArea = polygonArea(raw)

            let verdict = fixture.discriminating ? "520 严格胜出" : "新旧相等，该夹具不具判别力"
            note(String(format: "520 夹具 %@ · old-solver %.6f | old-band %.6f | old-max %.6f"
                         + " | new %.6f | new/old-max %.6f | hull %d 顶点 · grid %.6f · %@",
                         fixture.name, oldSolverArea, oldBandArea, oldMax, newArea,
                         oldMax > 0 ? newArea / oldMax : .infinity,
                         raw.count, grid, verdict))

            // 520 §3.1 — the grid is a lower bound, the hull an upper bound.
            XCTAssertGreaterThanOrEqual(newArea, grid - 1e-9,
                                        "\(fixture.name): 新解 \(newArea) 小于 4000×4000 网格 \(grid)")
            XCTAssertLessThanOrEqual(newArea, hullArea + 1e-9,
                                     "\(fixture.name): 新解 \(newArea) 大于多边形面积 \(hullArea)")

            // Every corner must be inside the polygon — the ticket's 不出像素 invariant.
            let corners = [NormalizedPoint(new.x, new.y),
                           NormalizedPoint(new.x + new.width, new.y),
                           NormalizedPoint(new.x + new.width, new.y + new.height),
                           NormalizedPoint(new.x, new.y + new.height)]
            for corner in corners {
                XCTAssertTrue(contains(raw, corner),
                              "\(fixture.name): 角 \(corner) 在多边形外")
            }

            // 520 §3.2 — never worse than the shipped answer.
            XCTAssertGreaterThanOrEqual(newArea, oldMax - 1e-9,
                                        "\(fixture.name): 新解 \(newArea) 小于旧答案 \(oldMax)")
            if fixture.discriminating {
                XCTAssertGreaterThan(newArea, oldMax + 1e-6,
                                     "\(fixture.name): 520 必须严格大于旧答案（旧 \(oldMax)）")
            }
        }
    }

    /// A direct check of the exact answer on the fixtures whose optimum is known in closed form, so
    /// the solver is not only compared with its own grid.
    func testClosedFormFixtures() throws {
        let trapezoid = [NormalizedPoint(0, 0), NormalizedPoint(1, 0),
                         NormalizedPoint(0.97, 1), NormalizedPoint(0.03, 1)]
        let a = try XCTUnwrap(MaxInscribedRect.maximumRectangle(in: trapezoid))
        XCTAssertEqual(Double(a.width * a.height), 0.94, accuracy: 1e-9,
                       "对称梯形的最优解是整段窄边 [0.03, 0.97] × 全高")

        let triangle = [NormalizedPoint(0, 0), NormalizedPoint(1, 0), NormalizedPoint(0.5, 1)]
        let e = try XCTUnwrap(MaxInscribedRect.maximumRectangle(in: triangle))
        XCTAssertEqual(Double(e.width * e.height), 0.25, accuracy: 1e-9,
                       "三角形内的最大轴对齐矩形 = 中位线宽 × 半高")
    }

    // MARK: - an independent lower bound (the ticket's 4000 × 4000 grid)

    /// Scan every grid x as a candidate left edge and every grid x as a candidate right edge, and use
    /// the *same* chord lemma to measure the tallest rectangle between them. This is deliberately a
    /// grid, not the solver's own edge/interior enumeration.
    private func gridArea(_ polygon: [NormalizedPoint], steps: Int) -> Double {
        guard let span = xSpan(polygon), span.hi - span.lo > 1e-12 else { return 0 }
        let count = steps + 1
        var lo = [Double](repeating: 0, count: count)
        var hi = [Double](repeating: 0, count: count)
        for i in 0..<count {
            let x = span.lo + (span.hi - span.lo) * Double(i) / Double(steps)
            let chord = verticalChord(polygon, at: x)
            lo[i] = chord.lo
            hi[i] = chord.hi
        }
        var best = 0.0
        for i in 0..<steps {
            let xa = span.lo + (span.hi - span.lo) * Double(i) / Double(steps)
            for j in (i + 1)...steps {
                let top = min(hi[i], hi[j])
                let bottom = max(lo[i], lo[j])
                let xb = span.lo + (span.hi - span.lo) * Double(j) / Double(steps)
                if top > bottom { best = max(best, (xb - xa) * (top - bottom)) }
            }
        }
        return best
    }

    // MARK: - the old answers, rebuilt exactly

    /// 489's solver on the same polygon (it clips to `[0,1]²` internally).
    private func oldSolverArea(_ polygon: [NormalizedPoint]) -> Double {
        AutoCropSolver.maximumRectangle(in: polygon).map { Double($0.width * $0.height) } ?? 0
    }

    /// `CropToolController.bandRectangle`, byte-for-byte in behaviour: top/bottom are pairs of hull
    /// vertex `y`s, left/right are the intersection of all chords in that band.
    private func oldBandArea(_ polygon: [NormalizedPoint]) -> Double? {
        guard polygon.count >= 3 else { return nil }
        let ys = Set(polygon.map(\.y)).sorted()
        guard ys.count >= 2 else { return nil }
        var best: Double?
        for i in ys.indices {
            for j in (i + 1)..<ys.count {
                let top = ys[i], bottom = ys[j]
                guard bottom - top > 1e-9 else { continue }
                var left = -Double.infinity
                var right = Double.infinity
                for y in ys[i...j] {
                    guard let chord = horizontalChord(polygon, at: y) else { left = .nan; break }
                    left = max(left, chord.left)
                    right = min(right, chord.right)
                }
                guard left.isFinite, right.isFinite, right - left > 1e-9 else { continue }
                let corners = [NormalizedPoint(left, top), NormalizedPoint(right, top),
                               NormalizedPoint(right, bottom), NormalizedPoint(left, bottom)]
                guard corners.allSatisfy({ contains(polygon, $0) }) else { continue }
                let area = (right - left) * (bottom - top)
                if area > (best ?? 0) { best = area }
            }
        }
        return best
    }

    // MARK: - fixture construction

    /// The four corners of the 505 canvas polygon, in canvas-normalized coordinates.
    private func canvasCorners(vertical: Double, horizontal: Double, shear: Double,
                               straighten: Double) -> [NormalizedPoint] {
        let perspective = PerspectiveMap(vertical: vertical, horizontal: horizontal,
                                         shear: shear, aspect: 1)
        let canvas = CropMath.documentCanvas(source: Self.source,
                                             straightenDegrees: straighten,
                                             perspective: perspective)
        return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { corner in
            let p = PerspectiveMap.apply(canvas.forward, x: corner.0, y: corner.1)
            return NormalizedPoint(p.x, p.y)
        }
    }

    /// A 480×320 frame turned about its centre, in source-normalized coordinates (the space a pure
    /// straighten solves in). Its corners leave `[0,1]²` above a few degrees, which is why the solver
    /// clips to the legal box.
    private func turnedPicture(degrees: Double) -> [NormalizedPoint] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let r = CropGeometry.RotationMatrix(degrees: degrees)
        return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { corner in
            let turned = r.apply(x: (corner.0 - 0.5) * w, y: (corner.1 - 0.5) * h)
            return NormalizedPoint(0.5 + turned.x / w, 0.5 + turned.y / h)
        }
    }

    private func rotate(_ polygon: [NormalizedPoint], degrees: Double) -> [NormalizedPoint] {
        let r = CropGeometry.RotationMatrix(degrees: degrees)
        return polygon.map { p in
            let q = r.apply(x: p.x - 0.5, y: p.y - 0.5)
            return NormalizedPoint(0.5 + q.x, 0.5 + q.y)
        }
    }

    // MARK: - small geometry helpers (independent of `MaxInscribedRect`'s own)

    private func clipToUnit(_ polygon: [NormalizedPoint]) -> [NormalizedPoint] {
        var out = polygon
        out = clip(out, coordinate: { $0.x }, bound: 0, keepAbove: true)
        out = clip(out, coordinate: { $0.x }, bound: 1, keepAbove: false)
        out = clip(out, coordinate: { $0.y }, bound: 0, keepAbove: true)
        out = clip(out, coordinate: { $0.y }, bound: 1, keepAbove: false)
        return out
    }

    private func clip(_ input: [NormalizedPoint],
                      coordinate: (NormalizedPoint) -> Double,
                      bound: Double, keepAbove: Bool) -> [NormalizedPoint] {
        guard !input.isEmpty else { return [] }
        func inside(_ p: NormalizedPoint) -> Bool {
            keepAbove ? coordinate(p) >= bound : coordinate(p) <= bound
        }
        var result: [NormalizedPoint] = []
        var previous = input[input.count - 1]
        var previousInside = inside(previous)
        for current in input {
            let currentInside = inside(current)
            if currentInside != previousInside {
                let va = coordinate(previous), vb = coordinate(current)
                let denominator = vb - va
                let t = abs(denominator) > 1e-15 ? (bound - va) / denominator : 0
                result.append(NormalizedPoint(previous.x + (current.x - previous.x) * t,
                                              previous.y + (current.y - previous.y) * t))
            }
            if currentInside { result.append(current) }
            previous = current
            previousInside = currentInside
        }
        return result
    }

    private func verticalChord(_ polygon: [NormalizedPoint], at x: Double)
        -> (lo: Double, hi: Double) {
        var ys: [Double] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if abs(b.x - a.x) < 1e-15 {
                if abs(x - a.x) < 1e-12 { ys.append(a.y); ys.append(b.y) }
                continue
            }
            let t = (x - a.x) / (b.x - a.x)
            if t >= -1e-9, t <= 1 + 1e-9 { ys.append(a.y + (b.y - a.y) * t) }
        }
        return (ys.min() ?? 0, ys.max() ?? 0)
    }

    private func horizontalChord(_ polygon: [NormalizedPoint], at y: Double)
        -> (left: Double, right: Double)? {
        var xs: [Double] = []
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if abs(b.y - a.y) < 1e-15 {
                if abs(y - a.y) < 1e-12 { xs.append(a.x); xs.append(b.x) }
                continue
            }
            let t = (y - a.y) / (b.y - a.y)
            if t >= -1e-12, t <= 1 + 1e-12 { xs.append(a.x + (b.x - a.x) * t) }
        }
        guard let lo = xs.min(), let hi = xs.max(), hi >= lo else { return nil }
        return (lo, hi)
    }

    private func contains(_ polygon: [NormalizedPoint], _ point: NormalizedPoint) -> Bool {
        var positive = false, negative = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            let scale = max(1e-12, hypot(b.x - a.x, b.y - a.y))
            if cross > 1e-7 * scale { positive = true }
            if cross < -1e-7 * scale { negative = true }
        }
        return !(positive && negative)
    }

    private func polygonArea(_ polygon: [NormalizedPoint]) -> Double {
        var sum = 0.0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    private func xSpan(_ polygon: [NormalizedPoint]) -> (lo: Double, hi: Double)? {
        guard let lo = polygon.map(\.x).min(), let hi = polygon.map(\.x).max() else { return nil }
        return (lo, hi)
    }
}
