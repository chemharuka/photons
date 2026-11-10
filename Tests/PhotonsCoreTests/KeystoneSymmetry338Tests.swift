import XCTest
import PhotonsCore
import Metal

/// 338 — **`+v` and `−v` must be mirror images, or they are two different knobs.**
///
/// The user's report was behavioural: dragging 透视 to `+100` and to `−100` does not look like the
/// same operation in two directions. It was not — `PerspectiveMap` used to be a *one-sided* projection
/// anchored on the corner `(0, 1)` (`w = 1 + v·s`, `s` = distance from the bottom edge), so `+100`
/// scaled the far edge by `1/1.21` and `−100` by `1/(1−0.21)`: **reciprocals, not mirrors**, and the
/// two canvases came out 608×406 and 480×265.
///
/// This file is the measurement and the acceptance:
///
///   1. **geometry** — `+s`'s warped quad reflected in the mid-line is `−s`'s quad, corner for corner,
///      to **1e−9 px** on a 2000 px frame. Eight settings: `±10, ±25, ±50, ±100` on each axis.
///   2. **matrix** — `P(−s)` *is* `A·P(+s)·A` element for element, to **1e−12**. Four corners
///      agreeing is necessary, not sufficient.
///   3. **pixels** — `A·W(−s) = W(+s)·A` on a real render, to **≤ 1 code**, and the two canvases are
///      the same size. See `testTheVerticalPixelsAreTheMirroredRender` for why the *operator*
///      identity is the pixel claim (flipping one render and comparing it with the other render *of
///      the same photograph* cannot hold for any keystone: `+v` and `−v` are the picture upright in
///      both, distorted opposite ways).
final class KeystoneSymmetry338Tests: XCTestCase {

    /// The slider notches the acceptance names, both signs.
    private let notches: [Double] = [10, 25, 50, 100]
    /// The frame the quad's normalized corners are read in — 2000 px is the acceptance's own grid.
    private let frame = 2000.0
    /// The acceptance's px tolerance (a normalized corner times 2000).
    private let tolerance = 1e-9
    /// The matrix's elementwise tolerance.
    private let matrixTolerance = 1e-12

    private enum Axis { case vertical, horizontal }

    private func requireMetal() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    }

    // MARK: - the reflection the acceptance is about

    /// A quad in the frame's own order (TL, TR, BR, BL), reflected in the mid-line of `axis`.
    /// Reflection reverses the corner order, so the comparison below re-indexes.
    private func reflect(_ quad: [(x: Double, y: Double)],
                         in axis: Axis) -> [(x: Double, y: Double)] {
        switch axis {
        case .vertical:   return quad.map { (x: $0.x, y: 1 - $0.y) }
        case .horizontal: return quad.map { (x: 1 - $0.x, y: $0.y) }
        }
    }

    /// The reflection `A·P·A` of a 3×3 about the mid-line of `axis`, written as the two matrices the
    /// map itself is multiplied by.
    private func reflect(_ m: [[Double]], in axis: Axis) -> [[Double]] {
        let a: [[Double]] = axis == .vertical
            ? [[1, 0, 0], [0, -1, 1], [0, 0, 1]]
            : [[-1, 0, 1], [0, 1, 0], [0, 0, 1]]
        return PerspectiveMap.multiply(PerspectiveMap.multiply(a, m), a)
    }

    private func deviation(_ a: [(x: Double, y: Double)], _ b: [(x: Double, y: Double)]) -> Double {
        var worst = 0.0
        for (p, q) in zip(a, b) {
            worst = max(worst, max(abs(p.x - q.x), abs(p.y - q.y)))
        }
        return worst * frame
    }

    private func describe(_ q: [(x: Double, y: Double)]) -> String {
        q.map { String(format: "(%.9f,%.9f)", $0.x, $0.y) }.joined(separator: " ")
    }

    // MARK: - 1 · geometry

    /// `−s`'s quad is `+s`'s quad reflected in the horizontal mid-line, corner for corner.
    func testTheVerticalKnobIsMirrorSymmetric() {
        for slider in notches {
            let plus = PerspectiveMap(vertical: slider, horizontal: 0).warpedQuad()
            let minus = PerspectiveMap(vertical: -slider, horizontal: 0).warpedQuad()
            // Reflection reverses TL/TR/BR/BL, so `+`'s corner i is `−`'s corner (3 − i).
            let mirrored = reflect(plus, in: .vertical)
            let reordered = [mirrored[3], mirrored[2], mirrored[1], mirrored[0]]
            let worst = deviation(reordered, minus)
            print("MIRROR v=\(Int(slider)) +  \(describe(plus))")
            print("MIRROR v=\(Int(slider)) −  \(describe(minus))")
            print(String(format: "MIRROR v=%+d · max|mirror(+v) − (−v)| = %.3e px",
                         Int(slider), worst))
            XCTAssertLessThanOrEqual(worst, tolerance,
                                     "v=\(slider): +v is not the mirror of −v")
        }
    }

    /// The same on the other axis, reflected in the vertical mid-line.
    func testTheHorizontalKnobIsMirrorSymmetric() {
        for slider in notches {
            let plus = PerspectiveMap(vertical: 0, horizontal: slider).warpedQuad()
            let minus = PerspectiveMap(vertical: 0, horizontal: -slider).warpedQuad()
            let mirrored = reflect(plus, in: .horizontal)
            let reordered = [mirrored[1], mirrored[0], mirrored[3], mirrored[2]]
            let worst = deviation(reordered, minus)
            print("MIRROR h=\(Int(slider)) +  \(describe(plus))")
            print("MIRROR h=\(Int(slider)) −  \(describe(minus))")
            print(String(format: "MIRROR h=%+d · max|mirror(+h) − (−h)| = %.3e px",
                         Int(slider), worst))
            XCTAssertLessThanOrEqual(worst, tolerance,
                                     "h=\(slider): +h is not the mirror of −h")
        }
    }

    // MARK: - 2 · the matrices

    /// `P(−s)` must *be* the reflected `P(+s)`, element for element. This is the assertion a one-sided
    /// projection cannot satisfy at any strength: the reflected matrix's third row differs in sign from
    /// the one-sided map's unless the anchor is the mid-line itself.
    func testTheMatrixIsTheMirrorConjugate() {
        for slider in notches {
            let verticalPlus = PerspectiveMap(vertical: slider, horizontal: 0).forwardMatrix
            let verticalMinus = PerspectiveMap(vertical: -slider, horizontal: 0).forwardMatrix
            let horizontalPlus = PerspectiveMap(vertical: 0, horizontal: slider).forwardMatrix
            let horizontalMinus = PerspectiveMap(vertical: 0, horizontal: -slider).forwardMatrix

            var worstV = 0.0, worstH = 0.0
            let rv = reflect(verticalPlus, in: .vertical)
            let rh = reflect(horizontalPlus, in: .horizontal)
            for r in 0..<3 {
                for c in 0..<3 {
                    worstV = max(worstV, abs(rv[r][c] - verticalMinus[r][c]))
                    worstH = max(worstH, abs(rh[r][c] - horizontalMinus[r][c]))
                }
            }
            print(String(format: "MATRIX v=±%d · max|A·P(+v)·A − P(−v)| = %.3e"
                         + " · h=±%d · %.3e", Int(slider), worstV, Int(slider), worstH))
            XCTAssertLessThanOrEqual(worstV, matrixTolerance,
                                     "v=\(slider): P(−v) is not the reflection of P(+v)")
            XCTAssertLessThanOrEqual(worstH, matrixTolerance,
                                     "h=\(slider): P(−h) is not the reflection of P(+h)")
        }
    }

    /// The mid-line is the fixed line of both knobs, and the slider's own zero is the identity exactly
    /// — the two facts the new anchor is built on, and the reason `keystone == 0` cannot move a byte.
    func testTheMidLineIsFixedAndZeroIsTheIdentity() {
        for slider in notches {
            let vertical = PerspectiveMap(vertical: slider, horizontal: 0)
            for x in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let p = vertical.forward(x: x, y: 0.5)
                XCTAssertEqual(p.x, x, accuracy: 1e-12, "v=\(slider): x=\(x) moved on the mid-line")
                XCTAssertEqual(p.y, 0.5, accuracy: 1e-12, "v=\(slider): mid-line y moved")
            }
            let horizontal = PerspectiveMap(vertical: 0, horizontal: slider)
            for y in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let p = horizontal.forward(x: 0.5, y: y)
                XCTAssertEqual(p.x, 0.5, accuracy: 1e-12, "h=\(slider): mid-line x moved")
                XCTAssertEqual(p.y, y, accuracy: 1e-12, "h=\(slider): y=\(y) moved on the mid-line")
            }
        }
        let identity = PerspectiveMap(vertical: 0, horizontal: 0)
        XCTAssertEqual(identity.forwardMatrix, [[1, 0, 0], [0, 1, 0], [0, 0, 1]],
                       "0/0 must be the identity matrix exactly — the key and the pixels depend on it")
    }

    // MARK: - 3 · pixels

    /// A **smooth** frame: a two-axis linear ramp, one channel per axis. The pixel claim below is about
    /// the *sampler*, and a high-frequency picture would differ by resampling alone — the two canvases'
    /// integer `ceil` puts their pixel grids `size − extent` apart (0.43 px at `±100`), and bilinear
    /// interpolation of noise across a half-pixel phase is tens of codes wide. `PerspectiveTests`'
    /// cross-grid comparisons use a smooth picture for the same reason.
    private func smoothImage(width: Int = 480, height: Int = 320) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let u = Double(x) / Double(width - 1), v = Double(y) / Double(height - 1)
                rgba[o] = Float16(0.05 + 0.70 * u)
                rgba[o + 1] = Float16(0.05 + 0.70 * v)
                rgba[o + 2] = Float16(0.10 + 0.30 * (0.5 * u + 0.5 * v))
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-338")
    }

    /// The same photograph, flipped in the mid-line of `axis` — the `A` of `A·W(−v) = W(+v)·A`.
    private func flipped(_ image: LinearImage, in axis: Axis) -> LinearImage {
        let w = image.width, h = image.height
        var rgba = image.rgba
        for y in 0..<h {
            for x in 0..<w {
                let (sx, sy) = axis == .vertical ? (x, h - 1 - y) : (w - 1 - x, y)
                let src = (sy * w + sx) * 4, dst = (y * w + x) * 4
                for c in 0..<4 { rgba[dst + c] = image.rgba[src + c] }
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: image.colorSpace,
                           decoderVersion: image.decoderVersion + "-mirror")
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        return try XCTUnwrap(result.display, "the render came back without pixels")
    }

    /// How deep inside the **picture** each pixel of a render is: Chebyshev distance to the nearest
    /// `000000` background pixel (BFS from the background). `000000` is the canvas' honest black
    /// outside the warped picture (§2.2 of 246), so this is the picture's own mask.
    private func pictureInset(_ f: DisplayImage) -> [[Int]] {
        let w = f.width, h = f.height
        var depth = [[Int]](repeating: [Int](repeating: Int.max, count: w), count: h)
        var queue: [(Int, Int)] = []
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                if f.rgba[o] == 0 && f.rgba[o + 1] == 0 && f.rgba[o + 2] == 0 {
                    depth[y][x] = 0
                    queue.append((x, y))
                }
            }
        }
        var i = 0
        while i < queue.count {
            let (x, y) = queue[i]
            i += 1
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                if nx < 0 || ny < 0 || nx >= w || ny >= h { continue }
                if depth[ny][nx] > depth[y][x] + 1 {
                    depth[ny][nx] = depth[y][x] + 1
                    queue.append((nx, ny))
                }
            }
        }
        return depth
    }

    private struct Delta {
        var max = 0
        var differing = 0
        var at = (x: 0, y: 0, channel: 0)
    }

    /// |Δ| in 8-bit codes between `a` (read through the flip of `axis`) and `b`, over the pixels that
    /// are at least `inset` px inside the picture in **both** renders.
    private func delta(_ a: DisplayImage, _ b: DisplayImage, axis: Axis,
                       depthA: [[Int]], depthB: [[Int]], inset: Int) -> Delta {
        var out = Delta()
        let w = min(a.width, b.width), h = min(a.height, b.height)
        for y in 0..<h {
            for x in 0..<w {
                let (ax, ay) = axis == .vertical ? (x, h - 1 - y) : (w - 1 - x, y)
                guard depthA[ay][ax] > inset, depthB[y][x] > inset else { continue }
                let oa = (ay * a.width + ax) * 4, ob = (y * b.width + x) * 4
                for c in 0..<3 {
                    let d = abs(Int((Double(a.rgba[oa + c]) * 255).rounded())
                                - Int((Double(b.rgba[ob + c]) * 255).rounded()))
                    if d > 0 { out.differing += 1 }
                    if d > out.max { out.max = d; out.at = (x, y, c) }
                }
            }
        }
        return out
    }

    /// **The pixel claim is `A·W(−v) = W(+v)·A`** — the `−v` render of the photograph, flipped, is the
    /// `+v` render of the *flipped* photograph — to within a code, on canvases that must first be the
    /// same size.
    ///
    /// Two things about the shape of this claim, both measured rather than assumed:
    ///
    /// * The naive form (flip the `−v` render and compare it with the `+v` render **of the same
    ///   photograph**) cannot hold for any keystone, whatever its parametrisation: `+100` and `−100` are
    ///   the photograph *upright* in both, distorted in opposite directions — the content is not
    ///   mirrored, the displacement is. What the user saw as 「不一致」 is the amount: pre-338 `+100`
    ///   grew the far edge by 26.6 % against a pinned near edge while `−100` shrank it by 17.4 %, and
    ///   the two canvases came out 608×406 and 480×265. Post-338 both canvases are the same size
    ///   (asserted) and the two warps are reflections of each other (asserted here).
    /// * The comparison is made **8 px inside the picture**, and the margin is the canvas' integer
    ///   `ceil`, not the map: `size − extent` is 0.43 px at `±100`, so the two pixel grids sit a
    ///   half-pixel apart and, on the one-pixel ring where the picture meets the `000000` background,
    ///   one render can mix in background the other does not (measured: 3 codes at a 3 px inset, 7 at
    ///   `±100`). Away from that ring the two samplers agree to a code — and the map itself is exact:
    ///   `testTheMatrixIsTheMirrorConjugate` is 1e−16 and the quad test 1e−13 px.
    func testTheVerticalPixelsAreTheMirroredRender() throws {
        try requireMetal()
        let image = smoothImage()
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "sym-338-v"))
        let flipGraph = try RenderGraph(input: RenderInput(image: flipped(image, in: .vertical),
                                                           identity: "sym-338-vm"))
        for slider in [50.0, 100.0] {
            var plus = EditModel.neutral
            plus.geometry.perspectiveVertical = slider
            var minus = EditModel.neutral
            minus.geometry.perspectiveVertical = -slider
            let a = try render(graph, plus)          // W(+v) on the photograph
            let b = try render(graph, minus)         // W(−v) on the photograph
            let c = try render(flipGraph, plus)      // W(+v) on the flipped photograph
            let depthB = pictureInset(b), depthC = pictureInset(c)
            let inside = delta(b, c, axis: .vertical, depthA: depthB, depthB: depthC, inset: 8)
            let whole = delta(b, c, axis: .vertical, depthA: depthB, depthB: depthC, inset: 0)
            print("PIXELS v=+\(Int(slider)) \(a.width)×\(a.height) · v=−\(Int(slider))"
                  + " \(b.width)×\(b.height) · flipped(+v) \(c.width)×\(c.height)"
                  + " · max|Δ| of A·W(−v) vs W(+v)·A = \(inside.max) code"
                  + " over the picture (8 px in), \(inside.differing) samples off by 1"
                  + " · whole canvas \(whole.max)")
            XCTAssertEqual(a.size, b.size,
                           "v=±\(slider): the two knobs must need the same canvas")
            XCTAssertLessThanOrEqual(inside.max, 1,
                                     "v=±\(slider): A·W(−v) is not W(+v)·A")
        }
    }

    /// The same for the horizontal knob, flipped left to right.
    func testTheHorizontalPixelsAreTheMirroredRender() throws {
        try requireMetal()
        let image = smoothImage()
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "sym-338-h"))
        let flipGraph = try RenderGraph(input: RenderInput(image: flipped(image, in: .horizontal),
                                                           identity: "sym-338-hm"))
        for slider in [50.0, 100.0] {
            var plus = EditModel.neutral
            plus.geometry.perspectiveHorizontal = slider
            var minus = EditModel.neutral
            minus.geometry.perspectiveHorizontal = -slider
            let a = try render(graph, plus)
            let b = try render(graph, minus)
            let c = try render(flipGraph, plus)
            let depthB = pictureInset(b), depthC = pictureInset(c)
            let inside = delta(b, c, axis: .horizontal, depthA: depthB, depthB: depthC, inset: 8)
            let whole = delta(b, c, axis: .horizontal, depthA: depthB, depthB: depthC, inset: 0)
            print("PIXELS h=+\(Int(slider)) \(a.width)×\(a.height) · h=−\(Int(slider))"
                  + " \(b.width)×\(b.height) · flipped(+h) \(c.width)×\(c.height)"
                  + " · max|Δ| of A·W(−h) vs W(+h)·A = \(inside.max) code"
                  + " over the picture (8 px in), \(inside.differing) samples off by 1"
                  + " · whole canvas \(whole.max)")
            XCTAssertEqual(a.size, b.size,
                           "h=±\(slider): the two knobs must need the same canvas")
            XCTAssertLessThanOrEqual(inside.max, 1,
                                     "h=±\(slider): A·W(−h) is not W(+h)·A")
        }
    }
}
