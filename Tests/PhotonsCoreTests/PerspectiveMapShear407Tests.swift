import XCTest
@testable import PhotonsCore

/// **407 — 切变 `k` 进出 `PerspectiveMap`，且 `k = 0` 逐位等于今天。**
///
/// These are the rendering-side guarantees the rest of the ticket stands on. 407 §2.2 asks the
/// document to grow one field and *no* `StageAlgorithmVersion.geometry` bump, and the only thing that
/// makes that honest is the first test here: a map with `shear == 0` must produce **the same nine
/// doubles** the pre-407 map produced, not "the same to 1e−15". Everything the desktop cache, the
/// goldens and the pinned key vectors hold is downstream of that one identity.
final class PerspectiveMapShear407Tests: XCTestCase {

    /// 407 §3 ⑦ — the reverse gate's own subject: `S(0)` is the identity, so the early return and the
    /// multiply must agree, and both must agree with the matrix this type produced before 407.
    ///
    /// The reference is the *pre-407 formula*, written out here rather than called: `M_h · M_v` with
    /// no third factor. Comparing against `PerspectiveMap`'s own code would pass even if both sides
    /// changed, which is exactly the mistake a bit-identity test must not make.
    func testAZeroShearMapIsBitIdenticalToToday() {
        let pairs: [(vertical: Double, horizontal: Double)] = [
            (0, 0), (120, -80), (-500, 0), (0, 500), (500, 400), (-475, -425),
            (0.5, -0.25), (69.0375, 69.0375),
        ]
        for (vertical, horizontal) in pairs {
            let shipped = PerspectiveMap(vertical: vertical, horizontal: horizontal, shear: 0)
                .forwardMatrix
            let pre407 = Self.pre407Matrix(vertical: vertical, horizontal: horizontal)
            for row in 0..<3 {
                for column in 0..<3 {
                    XCTAssertEqual(shipped[row][column], pre407[row][column],
                                   "v \(vertical) h \(horizontal) · [\(row)][\(column)] "
                                   + "已经不是 407 之前的那个 double")
                }
            }

            // …and the same through the pixel walk, which is what S0 and the fit actually call.
            let map = PerspectiveMap(vertical: vertical, horizontal: horizontal, shear: 0)
            let a = map.forward(x: 0.31, y: 0.72)
            let b = PerspectiveMap.apply(pre407, x: 0.31, y: 0.72)
            XCTAssertEqual(a.x, b.x, "v \(vertical) h \(horizontal) · forward(.x) 不是逐位相同")
            XCTAssertEqual(a.y, b.y, "v \(vertical) h \(horizontal) · forward(.y) 不是逐位相同")

            // The inverse rides `invert(forwardMatrix)`, so it moves with the same bits.
            let ia = map.inverse(x: 0.31, y: 0.72)
            let ib = PerspectiveMap.apply(PerspectiveMap.invert(pre407), x: 0.31, y: 0.72)
            XCTAssertEqual(ia.x, ib.x)
            XCTAssertEqual(ia.y, ib.y)
        }
        print("407 ⑦ shear = 0: \(pairs.count) 组 (v, h) 的 forwardMatrix / forward / inverse 全部逐位相同")
    }

    /// The pre-407 matrix, verbatim from `CropMath`'s doc comment (`M = M_h · M_v`), so the test above
    /// has something to be identical *to*.
    private static func pre407Matrix(vertical: Double, horizontal: Double) -> [[Double]] {
        let v = -vertical / PerspectiveMap.strengthUnit * PerspectiveMap.tangentPerUnit
        let h = -horizontal / PerspectiveMap.strengthUnit * PerspectiveMap.tangentPerUnit
        let m1: [[Double]] = [[1, -0.5 * v, 0.25 * v],
                              [0, 1 - 0.5 * v, 0.25 * v],
                              [0, -v, 1 + 0.5 * v]]
        let m2: [[Double]] = [[1 + 0.5 * h, 0, -0.25 * h],
                              [0.5 * h, 1, -0.25 * h],
                              [h, 0, 1 - 0.5 * h]]
        return PerspectiveMap.multiply(m2, m1)
    }

    /// A non-zero shear is a **horizontal** shear of the normalized frame: `y` is untouched and the
    /// offset is proportional to it. That is the whole geometric claim of 方案 A, and the one thing a
    /// direction-angle implementation would break.
    func testTheShearSlidesRowsSidewaysAndOnlySideways() {
        let k = 0.08
        let map = PerspectiveMap(vertical: 0, horizontal: 0, shear: k)
        for y in [0.0, 0.25, 0.5, 1.0] {
            let p = map.forward(x: 0.4, y: y)
            XCTAssertEqual(p.y, y, accuracy: 1e-15, "切变不许动 y（y = \(y)）")
            XCTAssertEqual(p.x, 0.4 + k * y, accuracy: 1e-15, "x 按 k·y 平移（y = \(y)）")
        }
        // The mid-line is a fixed row under a pure shear (`y = ½` slides ½·k, not 0) — but `k` is
        // applied *outside* the keystone, so this is the post-keystone row, i.e. the frame's own.
        print(String(format: "407 · k = %.3f: (0.4, 0.25) → (%.6f, %.6f)",
                     k, map.forward(x: 0.4, y: 0.25).x, map.forward(x: 0.4, y: 0.25).y))
    }

    /// `shear == 0` must be **the identity predicate's** business too: a document that has a keystone
    /// and no shear is not "identity", and one with only a shear definitely is not.
    func testTheIdentityPredicateCountsTheShear() {
        XCTAssertTrue(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0).isIdentity)
        XCTAssertFalse(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0.01).isIdentity)
        XCTAssertTrue(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0.01).hasWarp)
        XCTAssertTrue(PerspectiveMap(vertical: 30, horizontal: 0, shear: 0).hasWarp)
    }

    /// §2.1 — the travel is ±`shearLimit` (0.5), the clamp is finite-safe, and the number is *not*
    /// shared with the keystone's `limit` or its `coupledTravelBudget`.
    func testTheShearTravelIsClampedAndIndependent() {
        XCTAssertEqual(PerspectiveMap.shearLimit, 0.5)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0.9).shear, 0.5)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: -0.9).shear, -0.5)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0.5).shear, 0.5,
                       "端点是合法的，不许被钳掉")
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: .nan).shear, 0)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: .infinity).shear, 0)

        // The pair budget must not shrink because a shear is present: `S` never touches the third row.
        let keystone = PerspectiveMap(vertical: 500, horizontal: 500)
        let sheared = PerspectiveMap(vertical: 500, horizontal: 500, shear: 0.5)
        XCTAssertEqual(sheared.vertical, keystone.vertical, accuracy: 0)
        XCTAssertEqual(sheared.horizontal, keystone.horizontal, accuracy: 0)
        print(String(format: "407 · shearLimit %.1f · 500/500 的冲突预算不受 k 影响（v %.1f h %.1f）",
                     PerspectiveMap.shearLimit, sheared.vertical, sheared.horizontal))
    }

    /// A shear cannot create a pole: `S` is affine, so it leaves the homography's third row alone and
    /// the canvas arithmetic keeps a positive `w` for every value the clamp admits. The canvas is
    /// therefore never degenerate for a shear alone.
    func testAShearAloneNeverProducesADegenerateCanvas() {
        let frame = DSize(width: 1200, height: 800)
        for k in stride(from: -0.5, through: 0.5, by: 0.1) {
            let map = PerspectiveMap(vertical: 0, horizontal: 0, shear: k)
            let size = map.canvasSize(frame)
            XCTAssertFalse(map.isDegenerate(frame), "k = \(k) 不该让画布退化")
            XCTAssertGreaterThan(size.width, 0)
            XCTAssertGreaterThan(size.height, 0)
        }
    }
}
