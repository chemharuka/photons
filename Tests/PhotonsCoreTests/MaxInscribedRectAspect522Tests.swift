import XCTest
import PhotonsCore

/// **522 — 自动裁切 must honour the aspect lock.**
///
/// 520's solver finds the largest-area rectangle of *any* ratio. This suite pins the constrained
/// answer: for a pixel ratio `r` the solver must return the widest rectangle whose pixel ratio is
/// exactly `r`, i.e. `|w_px / h_px − r| ≤ 1e-9`, with all four corners inside the hull, and its area
/// must be
///
///  * no larger than the free optimum (the constraint cannot create area), and
///  * no smaller than an **independent** grid lower bound (4000 samples of the left edge, each with
///    its own bisection on the width — deliberately not the solver's candidate enumeration).
///
/// The free path is pinned separately: `aspect: nil` must be byte-for-byte the 520 answer.
private func note(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

final class MaxInscribedRectAspect522Tests: XCTestCase {

    private static let source = ImageSize(width: 480, height: 320)

    private struct Fixture {
        let name: String
        let polygon: [NormalizedPoint]
    }

    private let ratios: [(label: String, value: Double)] = [
        ("1:1", 1), ("3:2", 3.0 / 2.0), ("4:3", 4.0 / 3.0),
        ("16:9", 16.0 / 9.0), ("4:5", 4.0 / 5.0), ("2.5:1", 2.5),
    ]

    // MARK: - the six 520 fixtures (A, B, C, E, F, G)

    private func fixtures() -> [Fixture] {
        // (A) the synthetic axis-parallel trapezoid from the 505 probe.
        let a = [NormalizedPoint(0, 0), NormalizedPoint(1, 0),
                 NormalizedPoint(0.97, 1), NormalizedPoint(0.03, 1)]
        // (B) the 505 `+30 / 0°` keystone, taken from the canvas' own forward map.
        let b = canvasCorners(vertical: 30, horizontal: 0, shear: 0, straighten: 0)
        // (C) the two-axis + straighten fixture in the ticket.
        let c = canvasCorners(vertical: 30, horizontal: -20, shear: 0, straighten: 8)
        // (E) a triangle: the band construction has no positive answer here at all.
        let e = [NormalizedPoint(0, 0), NormalizedPoint(1, 0), NormalizedPoint(0.5, 1)]
        // (F) a long thin hexagon with **horizontal** top and bottom edges.
        let f = [NormalizedPoint(0, 0), NormalizedPoint(1, 0),
                 NormalizedPoint(1, 0.35), NormalizedPoint(0.65, 0.8),
                 NormalizedPoint(0.35, 0.8), NormalizedPoint(0, 0.35)]
        // (G) the real-world case: a 480×320 photograph turned 30° about its centre.
        let g = turnedPicture(degrees: 30)
        return [
            Fixture(name: "A 轴平行梯形", polygon: a),
            Fixture(name: "B +30 / 0° keystone", polygon: b),
            Fixture(name: "C +30 / −20 / 8°", polygon: c),
            Fixture(name: "E 三角形", polygon: e),
            Fixture(name: "F 细长六边形", polygon: f),
            Fixture(name: "G 纯拉直 30° (480×320)", polygon: g),
        ]
    }

    // MARK: - ① the 36 constrained answers

    func testConstrainedAnswersKeepTheRatioAndReachTheGridLowerBound() throws {
        let W = Double(Self.source.width), H = Double(Self.source.height)
        for fixture in fixtures() {
            let raw = fixture.polygon
            let free = try XCTUnwrap(MaxInscribedRect.maximumRectangle(in: raw),
                                     "\(fixture.name): 自由解不应为 nil")
            let freeArea = Double(free.width * free.height)
            let legal = clipToUnit(raw)

            for ratio in ratios {
                let rect = try XCTUnwrap(
                    MaxInscribedRect.maximumRectangle(in: raw, aspect: ratio.value,
                                                      pixelSize: Self.source),
                    "\(fixture.name) @ \(ratio.label): 受限解不应为 nil")
                let pixelRatio = Double(rect.width * W) / Double(rect.height * H)
                let area = Double(rect.width * rect.height)
                let grid = constrainedGridArea(legal,
                                               normalizedAspect: ratio.value * H / W, steps: 4000)

                note(String(format: "522 夹具 %@ · r %@ | 受限面积 %.9f | 自由面积 %.9f | 占比 %.9f"
                             + " | 像素比 %.15f | 网格 %.9f",
                             fixture.name, ratio.label, area, freeArea,
                             freeArea > 0 ? area / freeArea : 0, pixelRatio, grid))

                // 1) the lock is a promise, not an approximation.
                XCTAssertEqual(pixelRatio, ratio.value, accuracy: 1e-9,
                               "\(fixture.name) @ \(ratio.label): 像素比 \(pixelRatio) 不是 \(ratio.value)")
                // 2) every corner inside the picture.
                let corners = [NormalizedPoint(rect.x, rect.y),
                               NormalizedPoint(rect.x + rect.width, rect.y),
                               NormalizedPoint(rect.x + rect.width, rect.y + rect.height),
                               NormalizedPoint(rect.x, rect.y + rect.height)]
                for corner in corners {
                    XCTAssertTrue(inside(raw, corner),
                                  "\(fixture.name) @ \(ratio.label): 角 \(corner) 在多边形外")
                }
                // 3) the constraint cannot beat the free optimum, and the answer is at least the
                //    independent grid lower bound.
                XCTAssertLessThanOrEqual(area, freeArea + 1e-9,
                                         "\(fixture.name) @ \(ratio.label): 受限面积大于自由面积")
                XCTAssertGreaterThanOrEqual(area, grid - 1e-9,
                                            "\(fixture.name) @ \(ratio.label): 受限面积 \(area) 小于网格 \(grid)")
            }
        }
    }

    // MARK: - ② self-check: constraining at the free answer's own ratio changes nothing

    func testConstrainingAtTheFreeRatiosReproducesTheFreeArea() throws {
        let W = Double(Self.source.width), H = Double(Self.source.height)
        for fixture in fixtures() {
            let free = try XCTUnwrap(MaxInscribedRect.maximumRectangle(in: fixture.polygon))
            let freeArea = Double(free.width * free.height)
            let freePixelRatio = Double(free.width * W) / Double(free.height * H)
            let constrained = try XCTUnwrap(
                MaxInscribedRect.maximumRectangle(in: fixture.polygon, aspect: freePixelRatio,
                                                  pixelSize: Self.source),
                "\(fixture.name): 用自由解比例约束后不应为 nil")
            let area = Double(constrained.width * constrained.height)
            note(String(format: "522 自检 %@ · r0 %.12f | 受限 %.9f | 自由 %.9f",
                        fixture.name, freePixelRatio, area, freeArea))
            XCTAssertEqual(area, freeArea, accuracy: 1e-9,
                           "\(fixture.name): 用自由解自己的比例约束，面积必须不变")
        }

        // A square fixture at 1:1: the whole square is the answer.
        let square = [NormalizedPoint(0, 0), NormalizedPoint(1, 0),
                      NormalizedPoint(1, 1), NormalizedPoint(0, 1)]
        let answer = try XCTUnwrap(
            MaxInscribedRect.maximumRectangle(in: square, aspect: 1,
                                              pixelSize: ImageSize(width: 1000, height: 1000)))
        note(String(format: "522 自检 方形夹具 @ 1:1 · 面积 %.9f", Double(answer.width * answer.height)))
        XCTAssertEqual(Double(answer.width * answer.height), 1, accuracy: 1e-9)
        XCTAssertEqual(Double(answer.width / answer.height), 1, accuracy: 1e-9)
    }

    // MARK: - ③ the free path is the 520 path, byte for byte

    func testTheFreePathIsByteIdentical() throws {
        for fixture in fixtures() {
            let free = try XCTUnwrap(MaxInscribedRect.maximumRectangle(in: fixture.polygon))
            let delegated = try XCTUnwrap(
                MaxInscribedRect.maximumRectangle(in: fixture.polygon, aspect: nil,
                                                  pixelSize: Self.source))
            XCTAssertEqual(delegated, free, "\(fixture.name): aspect nil 必须逐位等于 520 自由解")
            note(String(format: "522 自由路径 %@ · L%.12f T%.12f W%.12f H%.12f",
                        fixture.name, free.x, free.y, free.width, free.height))
        }
    }

    // MARK: - independent grid lower bound (left edge 4000 samples, width by bisection)

    private func constrainedGridArea(_ polygon: [NormalizedPoint], normalizedAspect: Double,
                                     steps: Int) -> Double {
        guard normalizedAspect.isFinite, normalizedAspect > 0,
              let xmin = polygon.map(\.x).min(),
              let xmax = polygon.map(\.x).max(), xmax - xmin > 1e-12 else { return 0 }
        let span = xmax - xmin
        // The chord at a grid point is shared by every width tried there.
        var lows = [Double](repeating: 0, count: steps + 1)
        var highs = [Double](repeating: 0, count: steps + 1)
        for i in 0...steps {
            let x = xmin + span * Double(i) / Double(steps)
            let chord = verticalChord(polygon, at: x)
            lows[i] = chord.lo
            highs[i] = chord.hi
        }
        var best = 0.0
        for i in 0...steps {
            let left = xmin + span * Double(i) / Double(steps)
            var low = 0.0
            var high = xmax - left
            guard high > 1e-12 else { continue }
            for _ in 0..<60 {
                let mid = (low + high) / 2
                let right = verticalChord(polygon, at: left + mid)
                let height = min(highs[i], right.hi) - max(lows[i], right.lo)
                if height >= mid / normalizedAspect - 1e-12 { low = mid } else { high = mid }
            }
            if low > 0 { best = max(best, low * low / normalizedAspect) }
        }
        return best
    }

    // MARK: - fixture construction

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

    private func turnedPicture(degrees: Double) -> [NormalizedPoint] {
        let w = Double(Self.source.width), h = Double(Self.source.height)
        let rotation = CropGeometry.RotationMatrix(degrees: degrees)
        return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { corner in
            let turned = rotation.apply(x: (corner.0 - 0.5) * w, y: (corner.1 - 0.5) * h)
            return NormalizedPoint(0.5 + turned.x / w, 0.5 + turned.y / h)
        }
    }

    // MARK: - small geometry helpers, independent of the solver's

    private func inside(_ polygon: [NormalizedPoint], _ point: NormalizedPoint) -> Bool {
        var positive = false, negative = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            let scale = max(1e-12, hypot(b.x - a.x, b.y - a.y))
            if cross > 1e-9 * scale { positive = true }
            if cross < -1e-9 * scale { negative = true }
        }
        return !(positive && negative)
    }

    private func verticalChord(_ polygon: [NormalizedPoint], at x: Double) -> (lo: Double, hi: Double) {
        var lo = Double.infinity, hi = -Double.infinity
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if abs(b.x - a.x) < 1e-15 {
                if abs(x - a.x) <= 1e-12 {
                    lo = min(lo, a.y, b.y)
                    hi = max(hi, a.y, b.y)
                }
                continue
            }
            let t = (x - a.x) / (b.x - a.x)
            if t >= -1e-9, t <= 1 + 1e-9 {
                let y = a.y + (b.y - a.y) * t
                lo = min(lo, y)
                hi = max(hi, y)
            }
        }
        guard lo.isFinite, hi.isFinite else { return (0, 0) }
        return (lo, hi)
    }

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
}
