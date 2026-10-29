import XCTest
import PhotonsCore

/// 「旋转后裁切框要自动缩小」 — the constraint at the **model** layer, measured instead of eyeballed.
///
/// The rule is one function, `CropMath.clampedToRotatedFrame`: given the straighten angle and the rect
/// the user drew, it keeps the rect's **centre** and its **pixel aspect** and shrinks it until it is
/// fully inscribed in the sensor's turned quad. Two layers consume it — the overlay/readouts and 应用
/// (`CropToolController.effectiveCrop`, `CropRotatedFrameClampTests`).
///
/// Every number below is checked against a second, independent implementation:
///
///  · containment is decided by the **signed distance from each corner to the quad's four edges**
///    (`clearance`), not by the support-function inequality the clamp itself uses, so a shared sign
///    error could not pass both;
///  · "largest inscribed rect" is found by a **bisection on σ** (`numericMaxScale`), 80 halvings of
///    `[0, 1]`, so the closed form is compared against a search rather than against itself;
///  · the full-frame answers are *also* compared with `CropMath.inscribedExtent`, the closed form that
///    existed before this constraint (a crop of the whole frame keeps the source aspect, so the two
///    must agree exactly — a cross-check between two derivations).
///
/// Frame: **1200×800** (3:2), the size the report names. Angles: 9° / 15° / 45°, plus the 0…15° walk.
final class CropFrameInscribeTests: XCTestCase {

    private let source = ImageSize(width: 1200, height: 800)

    /// Pixel slack a corner may sit outside the quad. 1e-6 px is the report's tolerance; the arithmetic
    /// here lands three orders of magnitude inside it.
    private let tolerance = 1e-6

    // MARK: - an implementation of its own

    private struct P {
        var x: Double
        var y: Double
    }

    /// The sensor's turned quad, in **pixels** (the space the constraint is solved in).
    private func quadPixels(degrees: Double) -> [P] {
        let w = Double(source.width), h = Double(source.height)
        return CropMath.rotatedFrameCorners(in: source, degrees: degrees)
            .map { P(x: $0.x * w, y: $0.y * h) }
    }

    private func cornerPixels(_ c: CropRect) -> [P] {
        let w = Double(source.width), h = Double(source.height)
        return [P(x: c.left * w, y: c.top * h), P(x: c.right * w, y: c.top * h),
                P(x: c.right * w, y: c.bottom * h), P(x: c.left * w, y: c.bottom * h)]
    }

    /// Signed distance from `p` to the **boundary** of the convex quad: positive inside, negative
    /// outside, and 0 on an edge. The winding is read off the shoelace area, so no assumption about the
    /// corner order leaks in.
    private func clearance(_ p: P, quad: [P]) -> Double {
        var area = 0.0
        for i in 0..<quad.count {
            let a = quad[i], b = quad[(i + 1) % quad.count]
            area += a.x * b.y - b.x * a.y
        }
        let sign = area > 0 ? 1.0 : -1.0
        var best = Double.infinity
        for i in 0..<quad.count {
            let a = quad[i], b = quad[(i + 1) % quad.count]
            let ex = b.x - a.x, ey = b.y - a.y
            let length = (ex * ex + ey * ey).squareRoot()
            guard length > 0 else { continue }
            // Inward normal of a positively wound polygon.
            let nx = -ey / length * sign, ny = ex / length * sign
            best = min(best, nx * (p.x - a.x) + ny * (p.y - a.y))
        }
        return best
    }

    private struct Containment {
        var corners: [Double]
        var minClearance: Double
        var inside: Bool
    }

    private func containment(_ c: CropRect, degrees: Double,
                             slack: Double? = nil) -> Containment {
        let limit = slack ?? tolerance
        let quad = quadPixels(degrees: degrees)
        let distances = cornerPixels(c).map { clearance($0, quad: quad) }
        return Containment(corners: distances, minClearance: distances.min() ?? -.infinity,
                           inside: distances.allSatisfy { $0 >= -limit })
    }

    private func centred(_ c: CropRect, scaledBy s: Double) -> CropRect {
        let w = c.width * s, h = c.height * s
        return CropRect(left: c.centerX - w / 2, top: c.centerY - h / 2,
                        right: c.centerX + w / 2, bottom: c.centerY + h / 2)
    }

    /// The largest σ ∈ 0…1 by **bisection** — the answer the closed form has to reproduce.
    private func numericMaxScale(_ c: CropRect, degrees: Double,
                                 iterations: Int = 80) -> Double {
        if containment(centred(c, scaledBy: 1), degrees: degrees, slack: 1e-9).inside { return 1 }
        var lo = 0.0, hi = 1.0
        for _ in 0..<iterations {
            let mid = (lo + hi) / 2
            if containment(centred(c, scaledBy: mid), degrees: degrees, slack: 1e-9).inside {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }

    private func size(_ c: CropRect) -> (width: Double, height: Double) {
        (c.width * Double(source.width), c.height * Double(source.height))
    }

    private func ratio(_ c: CropRect) -> Double { size(c).width / size(c).height }

    private func report(_ label: String, _ c: CropRect, degrees: Double) {
        let px = size(c)
        let m = containment(c, degrees: degrees)
        let corners = m.corners.map { String(format: "%+.9f", $0) }.joined(separator: " ")
        print(String(format: "内接 %@ · %g° · %.6f×%.6f px · 比例 %.9f · 四角距边界 [%@] px · 最小 %+.3e",
                     label, degrees, px.width, px.height, ratio(c), corners, m.minClearance))
    }

    // MARK: - 1. 全图起步：9° / 15° / 45° 的框尺寸、四角距边界、与理论最大值对比赛

    /// 从「框=全图」出发，三个角度的答案：尺寸、四角到边界的有符号距离、以及和**数值搜索**出的最大
    /// 内接矩形的比较。全图裁切保留源比例，所以还要和 `inscribedExtent` 的闭式解逐位对上。
    func testFullFrameShrinksToTheLargestInscribedRectAtNineFifteenFortyFive() {
        // Closed-form expectations, printed to 9 decimals by the derivation above.
        let expected: [(degrees: Double, width: Double, height: Double)] = [
            (9, 981.723548720, 654.482365813),
            (15, 886.161877381, 590.774584921),
            (45, 678.822509939, 452.548339959),
        ]

        for e in expected {
            let clamped = CropMath.clampedToRotatedFrame(.full, in: source, degrees: e.degrees, keepsInsideRotatedFrame: true)
            report("全图", clamped, degrees: e.degrees)
            let px = size(clamped)

            // (a) the size the derivation gives
            XCTAssertEqual(px.width, e.width, accuracy: 1e-6, "\(e.degrees)°: width")
            XCTAssertEqual(px.height, e.height, accuracy: 1e-6, "\(e.degrees)°: height")

            // (b) the source ratio survives the shrink (the crop started as the whole frame)
            XCTAssertEqual(ratio(clamped), 1.5, accuracy: 1e-12, "\(e.degrees)°: aspect")

            // (c) the centre is the user's centre
            XCTAssertEqual(clamped.centerX, 0.5, accuracy: 1e-12, "\(e.degrees)°: centre x")
            XCTAssertEqual(clamped.centerY, 0.5, accuracy: 1e-12, "\(e.degrees)°: centre y")

            // (d) every corner is inside, and the answer is *tight* (one side touches the quad)
            let m = containment(clamped, degrees: e.degrees)
            XCTAssertTrue(m.inside, "\(e.degrees)°: a corner left the picture (min \(m.minClearance) px)")
            XCTAssertLessThanOrEqual(abs(m.minClearance), 1e-6,
                                     "\(e.degrees)°: not the largest inscribed rect — \(m.minClearance) px of room left")

            // (e) …and it equals what a bisection over σ finds, to the search's own resolution
            let numeric = numericMaxScale(.full, degrees: e.degrees)
            XCTAssertEqual(px.width, 1200 * numeric, accuracy: 1e-6,
                           "\(e.degrees)°: closed form vs numeric maximum")

            // (f) cross-check with the pre-existing closed form for a source-aspect rect
            let inscribed = CropMath.inscribedExtent(of: source, degrees: e.degrees)
            XCTAssertEqual(px.width, inscribed.width, accuracy: 1e-9,
                           "\(e.degrees)°: disagrees with inscribedExtent")
            XCTAssertEqual(px.height, inscribed.height, accuracy: 1e-9,
                           "\(e.degrees)°: disagrees with inscribedExtent")

            // (g) the picture really was the limit: the unclamped full frame is outside
            XCTAssertFalse(containment(.full, degrees: e.degrees).inside,
                           "\(e.degrees)°: the full frame should not fit — the test would be vacuous")
        }
    }

    /// 比例锁 16:9：从 16:9 的框（1200×675）出发，9° / 15° / 45° 三个角度**保持 16:9**，
    /// 而不是「保持宽度」。
    func testSixteenNineLockKeepsItsRatioAndFits() {
        let base = CropMath.fittedCrop(aspect: 16.0 / 9.0, in: .full, source: source)
        XCTAssertEqual(size(base).width, 1200, accuracy: 1e-9, "the 16:9 base should span the frame")
        XCTAssertEqual(size(base).height, 675, accuracy: 1e-9)

        let expected: [(degrees: Double, width: Double, height: Double)] = [
            (9, 1115.570576415, 627.508449233),
            (15, 997.316815859, 560.990708921),
            (45, 724.077343935, 407.293505963),
        ]
        for e in expected {
            let clamped = CropMath.clampedToRotatedFrame(base, in: source, degrees: e.degrees, keepsInsideRotatedFrame: true)
            report("16:9 锁", clamped, degrees: e.degrees)
            let px = size(clamped)

            XCTAssertEqual(px.width, e.width, accuracy: 1e-6, "16:9 at \(e.degrees)°: width")
            XCTAssertEqual(px.height, e.height, accuracy: 1e-6, "16:9 at \(e.degrees)°: height")
            XCTAssertEqual(ratio(clamped), 16.0 / 9.0, accuracy: 1e-12,
                           "16:9 at \(e.degrees)°: the lock must survive the shrink")
            // «保持比例» not «保持宽度»: the width *must* have moved.
            XCTAssertLessThan(px.width, size(base).width,
                              "16:9 at \(e.degrees)°: the width did not shrink at all")

            let m = containment(clamped, degrees: e.degrees)
            XCTAssertTrue(m.inside, "16:9 at \(e.degrees)°: a corner left the picture")
            XCTAssertLessThanOrEqual(abs(m.minClearance), 1e-6,
                                     "16:9 at \(e.degrees)°: not tight")

            let numeric = numericMaxScale(base, degrees: e.degrees)
            XCTAssertEqual(px.width, size(base).width * numeric, accuracy: 1e-6,
                           "16:9 at \(e.degrees)°: closed form vs numeric maximum")
        }
    }

    // MARK: - 2. 幂等

    /// `clamp(clamp(r)) == clamp(r)` — bit for bit, at every angle, for centred, off-centre, square and
    /// small rects. A second pass must not shave a ULP off each edge (that is how a frame creeps).
    func testTheConstraintIsIdempotent() {
        let rects: [(name: String, rect: CropRect)] = [
            ("全图", .full),
            ("居中半幅", CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)),
            ("偏心右上", CropRect(left: 0.55, top: 0.10, right: 0.95, bottom: 0.45)),
            ("方形", CropRect(left: 0.30, top: 0.20, right: 0.60, bottom: 0.60)),
            ("小框 32px", CropRect(left: 0.48, top: 0.48, right: 0.48 + 32.0 / 1200,
                                   bottom: 0.48 + 32.0 / 800)),
        ]
        for angle in [0.0, 1, 5, 9, 15, 30, 45, -9, -12.5] {
            for (name, rect) in rects {
                let once = CropMath.clampedToRotatedFrame(rect, in: source, degrees: angle, keepsInsideRotatedFrame: true)
                let twice = CropMath.clampedToRotatedFrame(once, in: source, degrees: angle, keepsInsideRotatedFrame: true)
                XCTAssertEqual(twice, once, "\(name) at \(angle)°: clamp is not idempotent")
            }
        }
    }

    // MARK: - 3. 单调

    /// θ 从 0→15°（步长 1°）边长**不增**，而且每一步都真的减小；45° 不比 15° 大。两组：全图与 16:9。
    func testTheSidesNeverGrowWithTheAngle() {
        let sixteenNine = CropMath.fittedCrop(aspect: 16.0 / 9.0, in: .full, source: source)
        for (name, base) in [("全图", CropRect.full), ("16:9", sixteenNine)] {
            var previous = size(CropMath.clampedToRotatedFrame(base, in: source, degrees: 0, keepsInsideRotatedFrame: true))
            var widths: [String] = []
            for degrees in stride(from: 1.0, through: 15.0, by: 1.0) {
                let px = size(CropMath.clampedToRotatedFrame(base, in: source, degrees: degrees, keepsInsideRotatedFrame: true))
                widths.append(String(format: "%g°:%.3f", degrees, px.width))
                XCTAssertLessThanOrEqual(px.width, previous.width,
                                         "\(name): width grew from \(previous.width) at \(degrees)°")
                XCTAssertLessThanOrEqual(px.height, previous.height,
                                         "\(name): height grew from \(previous.height) at \(degrees)°")
                // «自动缩小» needs a strict step, or a frozen frame would satisfy «不增».
                XCTAssertLessThan(px.width, previous.width - 1e-3,
                                  "\(name): the frame did not shrink between steps at \(degrees)°")
                XCTAssertLessThan(px.height, previous.height - 1e-3,
                                  "\(name): the frame did not shrink between steps at \(degrees)°")
                previous = px
            }
            let at45 = size(CropMath.clampedToRotatedFrame(base, in: source, degrees: 45, keepsInsideRotatedFrame: true))
            XCTAssertLessThanOrEqual(at45.width, previous.width, "\(name): 45° wider than 15°")
            print("单调 \(name) · " + widths.joined(separator: " ") +
                  String(format: " · 45°:%.3f", at45.width))
        }
    }

    // MARK: - 4. 回 0°

    /// 0° 时约束是恒等：存进去的矩形原样回来（逐位），所以把角度拖回 0 就把整幅画面还给了用户。
    func testZeroDegreesReturnsTheUnclampedRect() {
        let rects = [CropRect.full,
                     CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
                     CropRect(left: 0.0, top: 0.0, right: 0.4, bottom: 0.7),
                     CropRect(left: 0.6, top: 0.3, right: 1.0, bottom: 1.0)]
        for rect in rects {
            let back = CropMath.clampedToRotatedFrame(rect, in: source, degrees: 0, keepsInsideRotatedFrame: true)
            XCTAssertEqual(back, rect, "0° must be the identity")
            XCTAssertEqual(back.left, rect.left, accuracy: 0)
            XCTAssertEqual(back.right, rect.right, accuracy: 0)
        }
        // …and the *same* rect comes back after a round trip through a large angle.
        for degrees in [5.0, 9, 15, 45] {
            let shrunk = CropMath.clampedToRotatedFrame(.full, in: source, degrees: degrees, keepsInsideRotatedFrame: true)
            XCTAssertNotEqual(shrunk, .full, "\(degrees)°: nothing shrank")
            let back = CropMath.clampedToRotatedFrame(.full, in: source, degrees: 0, keepsInsideRotatedFrame: true)
            XCTAssertEqual(back, .full, "\(degrees)° → 0°: the frame did not come back")
        }
    }

    // MARK: - 5. 四角在内部（矩阵：偏心 / 小框 / 方框 × 正负角度）

    func testEveryCornerStaysInsideAndTheCentreIsKept() {
        let rects: [(name: String, rect: CropRect)] = [
            ("偏心右上", CropRect(left: 0.55, top: 0.10, right: 0.95, bottom: 0.45)),
            ("偏心左下", CropRect(left: 0.05, top: 0.55, right: 0.45, bottom: 0.95)),
            ("贴边半幅", CropRect(left: 0.5, top: 0.0, right: 1.0, bottom: 0.5)),
            ("方形", CropRect(left: 0.30, top: 0.20, right: 0.60, bottom: 0.60)),
        ]
        for angle in [5.0, 9, 12, 15, 30, 45, -9, -45] {
            for (name, rect) in rects {
                let clamped = CropMath.clampedToRotatedFrame(rect, in: source, degrees: angle, keepsInsideRotatedFrame: true)
                let m = containment(clamped, degrees: angle)
                XCTAssertTrue(m.inside, "\(name) at \(angle)°: corner outside by \(-m.minClearance) px")
                // 保中心: the shrink is about the rect's own centre.
                XCTAssertEqual(clamped.centerX, rect.centerX, accuracy: 1e-12,
                               "\(name) at \(angle)°: centre x moved")
                XCTAssertEqual(clamped.centerY, rect.centerY, accuracy: 1e-12,
                               "\(name) at \(angle)°: centre y moved")
                // 保比例: the pixel aspect is untouched by a uniform scale.
                XCTAssertEqual(ratio(clamped), ratio(rect), accuracy: 1e-12,
                               "\(name) at \(angle)°: aspect moved")
                // …and a rect that already fits is untouched, bit for bit (against `clamped()`, the
                // model's own normalization: `right = left + width` is one ULP off a literal
                // `bottom: 0.45` before the constraint ever runs).
                if CropMath.fitsInsideRotatedFrame(rect, in: source, degrees: angle) {
                    XCTAssertEqual(CropMath.clampedToRotatedFrame(rect, in: source, degrees: angle, keepsInsideRotatedFrame: true),
                                   rect.clamped(), "\(name) at \(angle)°: a legal rect was shrunk")
                }
            }
        }
    }

    /// A crop whose **centre** is outside the picture (32 px in the very corner at 15°) cannot be kept —
    /// no positive size fits there. It is re-centred on the frame, keeps its shape, and lands inside.
    func testACorneredCropIsBroughtBackInside() {
        let width = 32.0 / 1200, height = 32.0 / 800
        let cornered = CropRect(left: 0, top: 0, right: width, bottom: height)
        for angle in [9.0, 15, 45] {
            XCTAssertEqual(CropMath.rotatedFrameScale(cornered, in: source, degrees: angle), 0,
                           "\(angle)°: the corner really is outside — the fallback is what is tested")
            XCTAssertFalse(CropMath.fitsInsideRotatedFrame(cornered, in: source, degrees: angle))
            let rescued = CropMath.clampedToRotatedFrame(cornered, in: source, degrees: angle, keepsInsideRotatedFrame: true)
            let m = containment(rescued, degrees: angle)
            XCTAssertTrue(m.inside, "\(angle)°: the rescued frame is still outside")
            XCTAssertEqual(ratio(rescued), 1.0, accuracy: 1e-12, "\(angle)°: shape changed")
            XCTAssertEqual(rescued.centerX, 0.5, accuracy: 1e-12, "\(angle)°: not re-centred")
            XCTAssertEqual(rescued.centerY, 0.5, accuracy: 1e-12, "\(angle)°: not re-centred")
        }
    }

    // MARK: - 6. 反证：去掉约束，两条断言都必红

    /// The reverse proof. The *same* two criteria the tests above assert are evaluated on a frame that
    /// skipped the constraint (the identity clamp), and both have to fail:
    ///
    ///  · 「四角在内部」 — the full frame at 9° puts all four corners outside the picture;
    ///  · 「宽度不增」 — measured as the shrink the fit is worth (`inscribedExtent` vs the frame): with no
    ///    constraint the frame keeps its size, so the "side strictly shrinks" criterion is false. (A
    ///    frozen width is *non-increasing*, which is why the property under test is the strict step, not
    ///    the weak one — otherwise removing the constraint would still satisfy it.)
    func testWithoutTheConstraintBothCriteriaAreRed() {
        struct Criteria {
            var allCornersInside: Bool
            var widthStrictlyShrinks: Bool
        }
        func criteria(_ transform: (CropRect, Double) -> CropRect) -> Criteria {
            var inside = true, shrinks = true
            for degrees in [9.0, 15, 45] {
                let crop = transform(.full, degrees)
                inside = inside && containment(crop, degrees: degrees).inside
                shrinks = shrinks && size(crop).width < size(.full).width - 1e-3
            }
            return Criteria(allCornersInside: inside, widthStrictlyShrinks: shrinks)
        }

        let withConstraint = criteria { crop, degrees in
            CropMath.clampedToRotatedFrame(crop, in: source, degrees: degrees, keepsInsideRotatedFrame: true)
        }
        let withoutConstraint = criteria { crop, _ in crop }

        print("反证 · 有约束 四角在内 \(withConstraint.allCornersInside) 宽度缩小 \(withConstraint.widthStrictlyShrinks)")
        print("反证 · 无约束 四角在内 \(withoutConstraint.allCornersInside) 宽度缩小 \(withoutConstraint.widthStrictlyShrinks)")

        XCTAssertTrue(withConstraint.allCornersInside, "the shipped constraint keeps every corner in")
        XCTAssertTrue(withConstraint.widthStrictlyShrinks, "the shipped constraint shrinks the frame")
        XCTAssertFalse(withoutConstraint.allCornersInside,
                       "anti-proof: without the constraint a corner must leave the picture")
        XCTAssertFalse(withoutConstraint.widthStrictlyShrinks,
                       "anti-proof: without the constraint the width must not shrink")
        // The precise numbers, so the report can quote them: how far outside, and how much bigger.
        let full = containment(.full, degrees: 9)
        print(String(format: "反证 · 9° 全图四角距边界 [%@] px (负=在外)",
                     full.corners.map { String(format: "%+.3f", $0) }.joined(separator: " ")))
        XCTAssertLessThan(full.minClearance, -1, "9°: the full frame should miss the picture by >1 px")
    }
}
