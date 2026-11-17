import XCTest
@testable import PhotonsCore

/// **408 — 宽高比 `a` 进出 `PerspectiveMap`，且 `a = 1` 逐位等于今天（408 之前 = 407 之后）。**
///
/// The ticket's rendering-side guarantees, in the order it asks for them:
///
///   ① `a == 1` is bit-for-bit the pre-408 map (the compatibility gate — it is what lets 408 ship
///     without a `StageAlgorithmVersion.geometry` bump, and `.geometry` sits in every document's
///     chain, so a bump would re-render the whole library's thumbnails).
///   ② `A(a)` is a horizontal scale about the frame's centre: the centre is fixed, `x = 0.25` and
///     `x = 0.75` go to `0` and `1` at `a = 2`, `y` never moves.
///   ③ the canvas follows: `width(a) = a · width(1)`, so the inscribed rectangle's width moves one
///     for one with the knob and never collapses to zero.
///   ④ **the physical meaning.** `aspect` is a *multiplicative* scale, so it leaves the far/near
///     width **ratio** exactly where it was — that ratio is the keystone's, not this knob's. What it
///     *does* correct is the canvas: `compensatingAspect` makes the inscribed rectangle square again
///     (i.e. keeps the source frame's proportions), in one step and by closed form. 408 §6.1 rewrote
///     §3's case 4 for exactly this reason: 「补偿后宽度比回到 1.0」 is unsatisfiable, so the test
///     would have been a lie either way it was written.
///   ⑤ the composition order: `M = A(a) · S(k) · M_h · M_v` — `A` outermost, per darktable's ten
///     steps — checked against a hand-written product, and against `S·A` being a *different*
///     matrix (so the assertion has teeth).
///   ⑥ nothing else moves: a neutral document's geometry material, its encoded bytes and the stage
///     version are all exactly what they were.
final class PerspectiveAspect408Tests: XCTestCase {

    // MARK: - ① the compatibility gate

    /// **The most important test in the ticket.** A map with `aspect == 1` must produce the same nine
    /// doubles the 4-parameter map produced, not "the same to 1e−15".
    ///
    /// The reference is written out here (`M_h · M_v`, then `S(k)`), not called through
    /// `PerspectiveMap`: comparing the type against itself would pass even if both sides changed,
    /// which is the mistake a bit-identity test must not make.
    func testAnAspectOfOneIsBitIdenticalToToday() {
        let cases: [(vertical: Double, horizontal: Double, shear: Double)] = [
            (0, 0, 0), (120, -80, 0), (-500, 0, 0), (0, 500, 0), (500, 400, 0),
            (100, 0, 0.08), (-37.5, 12.5, -0.3), (0, 0, 0.5),
        ]
        for c in cases {
            let withAspect = PerspectiveMap(vertical: c.vertical, horizontal: c.horizontal,
                                            shear: c.shear, aspect: 1)
            let withoutAspect = PerspectiveMap(vertical: c.vertical, horizontal: c.horizontal,
                                               shear: c.shear)
            let reference = Self.pre408Matrix(vertical: c.vertical, horizontal: c.horizontal,
                                              shear: c.shear)
            for row in 0..<3 {
                for column in 0..<3 {
                    XCTAssertEqual(withAspect.forwardMatrix[row][column],
                                   withoutAspect.forwardMatrix[row][column],
                                   "v \(c.vertical) h \(c.horizontal) k \(c.shear) · [\(row)][\(column)] "
                                   + "与 4 参数版本不是同一个 double")
                    XCTAssertEqual(withAspect.forwardMatrix[row][column],
                                   reference[row][column],
                                   "v \(c.vertical) h \(c.horizontal) k \(c.shear) · [\(row)][\(column)] "
                                   + "已经不是 407 的那个 double")
                }
            }
            // …and through the pixel walk, which is what S0 and the fit actually call: the centre,
            // two corners, and one arbitrary interior point.
            for (x, y) in [(0.5, 0.5), (0.0, 0.0), (1.0, 1.0), (0.31, 0.72)] {
                let a = withAspect.forward(x: x, y: y)
                let b = withoutAspect.forward(x: x, y: y)
                XCTAssertEqual(a.x, b.x, "v \(c.vertical) h \(c.horizontal) k \(c.shear) · forward(\(x), \(y)).x")
                XCTAssertEqual(a.y, b.y, "v \(c.vertical) h \(c.horizontal) k \(c.shear) · forward(\(x), \(y)).y")
                let ra = withAspect.inverse(x: x, y: y)
                let rb = withoutAspect.inverse(x: x, y: y)
                XCTAssertEqual(ra.x, rb.x)
                XCTAssertEqual(ra.y, rb.y)
            }
        }
        print("408 ① aspect = 1：\(cases.count) 组 (v, h, k) 的 forwardMatrix / forward / inverse 全部逐位相同")
    }

    /// The pre-408 matrix, written out from the type's own doc (`M = S(k) · M_h · M_v`, `S(0) = I`).
    private static func pre408Matrix(vertical: Double, horizontal: Double,
                                     shear: Double) -> [[Double]] {
        let v = -vertical / PerspectiveMap.strengthUnit * PerspectiveMap.tangentPerUnit
        let h = -horizontal / PerspectiveMap.strengthUnit * PerspectiveMap.tangentPerUnit
        let m1: [[Double]] = [[1, -0.5 * v, 0.25 * v],
                              [0, 1 - 0.5 * v, 0.25 * v],
                              [0, -v, 1 + 0.5 * v]]
        let m2: [[Double]] = [[1 + 0.5 * h, 0, -0.25 * h],
                              [0.5 * h, 1, -0.25 * h],
                              [h, 0, 1 - 0.5 * h]]
        let keystone = PerspectiveMap.multiply(m2, m1)
        guard shear != 0 else { return keystone }
        return PerspectiveMap.multiply([[1, shear, 0], [0, 1, 0], [0, 0, 1]], keystone)
    }

    // MARK: - ② what the knob does

    /// `A(a)` is the horizontal scale `x ↦ ½ + (x − ½)·a` about the centre, and nothing else.
    func testTheAspectScalesHorizontallyAboutTheCentre() {
        // v = h = k = 0: today's map is the identity, so the claim is purely about `A`.
        let double = PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 2)
        let centre = double.forward(x: 0.5, y: 0.5)
        XCTAssertEqual(centre.x, 0.5, accuracy: 1e-15, "中心不许动")
        XCTAssertEqual(centre.y, 0.5, accuracy: 1e-15)
        for (x, expected) in [(0.25, 0.0), (0.75, 1.0), (0.125, -0.25), (0.875, 1.25)] {
            let p = double.forward(x: x, y: 0.37)
            XCTAssertEqual(p.x, expected, accuracy: 1e-15, "a = 2：x \(x) → \(expected)")
            XCTAssertEqual(p.y, 0.37, accuracy: 1e-15, "a 只动 x")
        }
        // a < 1 压窄：the two edges come in by the same factor.
        let half = PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 0.5)
        XCTAssertEqual(half.forward(x: 0.0, y: 0.5).x, 0.25, accuracy: 1e-15)
        XCTAssertEqual(half.forward(x: 1.0, y: 0.5).x, 0.75, accuracy: 1e-15)

        // …and it composes with a keystone the way the chain says: the result is the *warped* point
        // scaled about ½, not the source point (the keystone runs first).
        let v = 100.0
        let map = PerspectiveMap(vertical: v, horizontal: 0, shear: 0, aspect: 1.6)
        let keystone = PerspectiveMap(vertical: v, horizontal: 0, shear: 0, aspect: 1)
        for (x, y) in [(0.1, 0.2), (0.9, 0.8), (0.5, 0.5)] {
            let warped = keystone.forward(x: x, y: y)
            let scaled = map.forward(x: x, y: y)
            XCTAssertEqual(scaled.x, 0.5 + 1.6 * (warped.x - 0.5), accuracy: 1e-12,
                           "A 必须在 keystone 之后：x = \(x)")
            XCTAssertEqual(scaled.y, warped.y, accuracy: 1e-12)
        }
        print(String(format: "408 ② a = 2：(0.25, 0.5) → (%.6f, %.6f) · (0.75, 0.5) → (%.6f, %.6f)",
                     double.forward(x: 0.25, y: 0.5).x, double.forward(x: 0.25, y: 0.5).y,
                     double.forward(x: 0.75, y: 0.5).x, double.forward(x: 0.75, y: 0.5).y))
    }

    // MARK: - ③ the canvas

    /// The canvas — the largest rectangle inscribed in the warped quad — follows `a` **linearly** in
    /// width, keeps its height, and never degenerates for any value the clamp admits.
    func testTheCanvasFollowsTheAspect() {
        let frame = DSize(width: 1200, height: 800)
        for (v, h) in [(0.0, 0.0), (100.0, 0.0), (100.0, -80.0), (-250.0, 120.0)] {
            let one = PerspectiveMap(vertical: v, horizontal: h).inscribedRect()
            for a in [0.5, 0.75, 1.25, 1.6, 2.0] {
                let map = PerspectiveMap(vertical: v, horizontal: h, shear: 0, aspect: a)
                let rect = map.inscribedRect()
                XCTAssertEqual(rect.width, a * one.width, accuracy: 1e-12,
                               "v \(v) h \(h)：画布宽必须随 a 线性（a = \(a)）")
                XCTAssertEqual(rect.height, one.height, accuracy: 1e-12,
                               "v \(v) h \(h)：A 不许动高度（a = \(a)）")
                XCTAssertGreaterThan(rect.width, 0, "v \(v) h \(h) a \(a)：宽度不为零")
                XCTAssertGreaterThan(rect.height, 0)
                let size = map.canvasSize(frame)
                XCTAssertGreaterThan(size.width, 0)
                XCTAssertGreaterThan(size.height, 0)
                XCTAssertFalse(map.isDegenerate(frame), "v \(v) h \(h) a \(a) 不该让画布退化")
            }
            // a > 1 更宽、a < 1 更窄，且两端关于 1 对称（同一档）。
            let wider = PerspectiveMap(vertical: v, horizontal: h, shear: 0, aspect: 2).canvasSize()
            let narrower = PerspectiveMap(vertical: v, horizontal: h, shear: 0, aspect: 0.5).canvasSize()
            XCTAssertGreaterThan(wider.width, narrower.width)
            XCTAssertEqual(wider.height, narrower.height, accuracy: 1e-12)
        }
        print(String(format: "408 ③ v=100：画布 a=1 %.6f×%.6f · a=2 %.6f×%.6f",
                     1.0, PerspectiveMap(vertical: 100, horizontal: 0).inscribedRect().height,
                     PerspectiveMap(vertical: 100, horizontal: 0, shear: 0, aspect: 2).inscribedRect().width,
                     PerspectiveMap(vertical: 100, horizontal: 0, shear: 0, aspect: 2).inscribedRect().height))
    }

    // MARK: - ④ the physical meaning (408 §6.1's rewrite of §3's case 4)

    /// **What `aspect` is and is not.**
    ///
    /// *Not* the far/near width ratio: a global horizontal scale multiplies both widths, so the ratio
    /// is invariant in `a` — 1.2346 at `v = 100`, exactly today's number, for every `a`.
    ///
    /// What it *is*: the knob that puts the canvas' proportions back. `compensatingAspect` (the 自动
    /// button's value) makes the inscribed rectangle **square**, i.e. the crop keeps the source
    /// frame's shape, and it does so in one step because the width is linear in `a`.
    func testTheKeystoneWidthRatioIsTheOneAspectCompensates() {
        let v = 100.0
        // The far/near ratio, measured on the warped quad's top and bottom edges.
        func widths(_ a: Double) -> (top: Double, bottom: Double) {
            let map = PerspectiveMap(vertical: v, horizontal: 0, shear: 0, aspect: a)
            let tl = map.forward(x: 0, y: 0), tr = map.forward(x: 1, y: 0)
            let bl = map.forward(x: 0, y: 1), br = map.forward(x: 1, y: 1)
            return (abs(tr.x - tl.x), abs(br.x - bl.x))
        }
        let shipped = widths(1)
        let ratio = shipped.top / shipped.bottom
        XCTAssertEqual(ratio, 1.234637, accuracy: 1e-6, "今天的远/近宽度比")
        for a in [0.5, 0.809955, 1.105, 1.234637, 1.8, 2.0] {
            let w = widths(a)
            XCTAssertEqual(w.top / w.bottom, ratio, accuracy: 1e-12,
                           "a = \(a)：宽度比对 a 恒定 —— aspect 不是这个比值")
            XCTAssertEqual(w.top, a * shipped.top, accuracy: 1e-12)
            XCTAssertEqual(w.bottom, a * shipped.bottom, accuracy: 1e-12)
        }

        // The 自动 value: the canvas becomes square, and the formula carries `a_now` (it answers the
        // same number from any starting point — one step, no iteration).
        let map = PerspectiveMap(vertical: v, horizontal: 0)
        let canvas = map.inscribedRect()
        let auto = try! XCTUnwrap(map.compensatingAspect)
        XCTAssertEqual(auto, canvas.height / canvas.width, accuracy: 1e-12)
        let corrected = PerspectiveMap(vertical: v, horizontal: 0, shear: 0, aspect: auto)
            .inscribedRect()
        XCTAssertEqual(corrected.width, corrected.height, accuracy: 1e-12,
                       "补偿后画布必须是正方形（宽 \(corrected.width) vs 高 \(corrected.height)）")
        // …and from any other starting point the same fixed point comes back.
        let started = PerspectiveMap(vertical: v, horizontal: 0, shear: 0, aspect: 1.37)
        let again = try! XCTUnwrap(started.compensatingAspect)
        let settled = PerspectiveMap(vertical: v, horizontal: 0, shear: 0, aspect: again).inscribedRect()
        XCTAssertEqual(settled.width, settled.height, accuracy: 1e-12)
        // Two axes at once: the closed form in `v`/`h` is wrong, `inscribedRect` is the answer.
        let pair = PerspectiveMap(vertical: 100, horizontal: -80)
        let pairAuto = try! XCTUnwrap(pair.compensatingAspect)
        let naive = 1 / (1 - (0.21 + 0.168) / 2)
        XCTAssertGreaterThan(abs(pairAuto - naive), 0.05,
                             "两轴并开时 1/(1−(|v|+|h|)/2) 与内接矩形差得远（\(pairAuto) vs \(naive)）")
        // A bare shear is not a keystone: 自动 has nothing to say (no canvas stretch to correct).
        XCTAssertNil(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0.2).compensatingAspect)

        print(String(format: "408 ④ v=100：宽度比 %.6f（a 无关）· 画布 a=1 %.6f×%.6f · a_auto %.6f → %.6f×%.6f",
                     ratio, canvas.width, canvas.height, auto, corrected.width, corrected.height))
        print(String(format: "408 ④ (100, −80)：a_auto %.6f（和式 1/(1−(|v|+|h|)/2) = %.6f，差 %.2f %%）",
                     pairAuto, naive, abs(pairAuto - naive) / pairAuto * 100))
    }

    // MARK: - ⑤ the order

    /// `M = A(a) · S(k) · M_h · M_v`, element for element against a hand-written product — and
    /// `S·A` is a different matrix, so the assertion is about the order and not just about "some
    /// product".
    func testTheShearAndAspectComposeInTheDocumentedOrder() {
        let cases: [(v: Double, h: Double, k: Double, a: Double)] = [
            (100, 0, 0.08, 1.2), (100, -80, -0.052, 1.105), (-250, 120, 0.3, 0.75),
            (500, 400, 0.5, 2.0), (0, 0, 0.1, 1.5),
        ]
        for c in cases {
            let map = PerspectiveMap(vertical: c.v, horizontal: c.h, shear: c.k, aspect: c.a)
            let v = -c.v / PerspectiveMap.strengthUnit * PerspectiveMap.tangentPerUnit
            let h = -c.h / PerspectiveMap.strengthUnit * PerspectiveMap.tangentPerUnit
            let mv: [[Double]] = [[1, -0.5 * v, 0.25 * v],
                                  [0, 1 - 0.5 * v, 0.25 * v],
                                  [0, -v, 1 + 0.5 * v]]
            let mh: [[Double]] = [[1 + 0.5 * h, 0, -0.25 * h],
                                  [0.5 * h, 1, -0.25 * h],
                                  [h, 0, 1 - 0.5 * h]]
            let s: [[Double]] = [[1, c.k, 0], [0, 1, 0], [0, 0, 1]]
            let a: [[Double]] = [[c.a, 0, 0.5 * (1 - c.a)], [0, 1, 0], [0, 0, 1]]
            let documented = PerspectiveMap.multiply(
                a, PerspectiveMap.multiply(s, PerspectiveMap.multiply(mh, mv)))
            for row in 0..<3 {
                for column in 0..<3 {
                    XCTAssertEqual(map.forwardMatrix[row][column], documented[row][column],
                                   accuracy: 1e-12,
                                   "v \(c.v) h \(c.h) k \(c.k) a \(c.a) · [\(row)][\(column)]")
                }
            }
            // The other order is a *different* matrix whenever both knobs are engaged — this is the
            // teeth: `A·S` carries `a·k` in (0,1), `S·A` carries `k`.
            if c.k != 0, c.a != 1 {
                // The order is visible in the two factors themselves: `A·S`'s (0,1) entry is `a·k`,
                // `S·A`'s is `k` — so the whole products differ wherever `a ≠ 1` and `k ≠ 0`.
                XCTAssertEqual(PerspectiveMap.multiply(a, s)[0][1], c.a * c.k, accuracy: 1e-15)
                XCTAssertEqual(PerspectiveMap.multiply(s, a)[0][1], c.k, accuracy: 1e-15)
                let swapped = PerspectiveMap.multiply(
                    s, PerspectiveMap.multiply(a, PerspectiveMap.multiply(mh, mv)))
                XCTAssertGreaterThan(abs(map.forwardMatrix[0][1] - swapped[0][1]), 1e-9,
                                     "A·S ≠ S·A（k \(c.k), a \(c.a)）—— 顺序必须选对")
            }
        }
        let sample = PerspectiveMap(vertical: 100, horizontal: 0, shear: 0.08, aspect: 1.2)
        print("408 ⑤ M(100, 0, k 0.08, a 1.2) = \(sample.forwardMatrix)")
    }

    // MARK: - ⑥ nothing else moves

    /// A neutral document keeps its geometry material, its bytes and the stage version; a document
    /// with `aspect == 1` is the same document it was; and the key token is `;asp2=`, distinct from
    /// the crop lock's `;asp=`.
    func testEveryOtherStageIsUntouched() {
        // The neutral document's material is exactly what it was (this is the string the pinned key
        // vectors and `render-edit-neutral`'s blob are built on).
        let neutral = EditModel.neutral
        XCTAssertEqual(neutral.geometry.perspectiveAspect, 1, "默认必须是 1.0")
        XCTAssertNil(neutral.geometry.perspective, "中性文档没有透视图，S0 走 pre-183 分支")
        let material = neutral.keyMaterial(.geometry)
        XCTAssertFalse(material.contains("asp2"), "aspect = 1 不许追加任何段：\(material)")
        XCTAssertEqual(String(material.dropLast(";alg=\(StageAlgorithmVersion.geometry)".count)),
                       "pv=\(neutral.processVersion);crop=0.00000,0.00000,1.00000,1.00000"
                       + ";rot=0.00000;flip=00",
                       "中性 geometry 物料必须逐字节不变")
        // The stage version is *not* bumped by 408 (it is 5 since 307; 407 did not bump it either).
        XCTAssertEqual(StageAlgorithmVersion.geometry, 5, "408 不许 bump geometry 版本")

        // A document that only moved 宽高比 still renders through the perspective map, and its key
        // grows exactly one token.
        var onlyAspect = neutral
        onlyAspect.geometry.perspectiveAspect = 1.105
        XCTAssertNotNil(onlyAspect.geometry.perspective)
        XCTAssertEqual(onlyAspect.geometry.perspective?.aspect, 1.105)
        XCTAssertTrue(onlyAspect.keyMaterial(.geometry).contains(";asp2=1105"),
                      "千分之一的 a：\(onlyAspect.keyMaterial(.geometry))")
        // The lock's `;asp=` is a different token — two meanings must not share one.
        var locked = neutral
        locked.geometry.aspectLock = .sixteenNine
        XCTAssertTrue(locked.keyMaterial(.geometry).contains(";asp="))
        XCTAssertFalse(locked.keyMaterial(.geometry).contains(";asp2="))
        var both = locked
        both.geometry.perspectiveAspect = 1.105
        XCTAssertTrue(both.keyMaterial(.geometry).contains(";asp="))
        XCTAssertTrue(both.keyMaterial(.geometry).contains(";asp2="))
        // Adjacent slider positions (0.01) must never print the same token.
        var tokens: Set<String> = []
        for step in 100...200 {
            var doc = neutral
            doc.geometry.perspectiveAspect = Double(step) / 100
            tokens.insert(doc.keyMaterial(.geometry))
        }
        XCTAssertEqual(tokens.count, 101, "每 1 % 一档，101 个位置必须 101 个键")

        // Bytes: a pre-408 document re-encodes byte for byte, and 1.0 is never written.
        let encoded = try! JSONEncoder().encode(neutral)
        XCTAssertFalse(String(data: encoded, encoding: .utf8)!.contains("perspectiveAspect"))
        var withAspect = neutral
        withAspect.geometry.perspectiveAspect = 1.2
        let encodedAspect = try! JSONEncoder().encode(withAspect)
        XCTAssertTrue(String(data: encodedAspect, encoding: .utf8)!.contains("perspectiveAspect"))
        // Round trip.
        let decoded = try! JSONDecoder().decode(EditModel.self, from: encodedAspect)
        XCTAssertEqual(decoded.geometry.perspectiveAspect, 1.2)
        // A pre-408 blob reads as 1.0 (= the identity, no pixels move).
        let old = try! JSONDecoder().decode(EditModel.self, from: encoded)
        XCTAssertEqual(old.geometry.perspectiveAspect, 1)

        // The geometry fingerprint (`344`/`366`) names it too, and stays empty when neutral.
        XCTAssertEqual(neutral.geometry.geometryFingerprint, "")
        XCTAssertTrue(withAspect.geometry.geometryFingerprint.contains(";asp2=1200"),
                      "低清整图指纹必须看见宽高比：\(withAspect.geometry.geometryFingerprint)")

        // `isIdentity` / `hasWarp` count the new number.
        XCTAssertTrue(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 1).isIdentity)
        XCTAssertFalse(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 1.01).isIdentity)
        XCTAssertTrue(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 1.01).hasWarp)
        print("408 ⑥ 中性物料 \(material) · 只有宽高比时 \(onlyAspect.keyMaterial(.geometry))")
    }

    /// The clamp: `a ∈ [0.5, 2.0]`, finite-safe, and a non-positive value reads as the identity
    /// (never as a Mirrored picture nobody asked for).
    func testTheAspectTravelIsClampedAndIndependent() {
        XCTAssertEqual(PerspectiveMap.aspectLimit, 2.0)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 3).aspect, 2.0)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 0.1).aspect, 0.5)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 0.5).aspect, 0.5,
                       "端点是合法的，不许被钳掉")
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 2).aspect, 2)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: .nan).aspect, 1)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: .infinity).aspect, 1)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: 0).aspect, 1)
        XCTAssertEqual(PerspectiveMap(vertical: 0, horizontal: 0, shear: 0, aspect: -1.4).aspect, 1)
        // The pair budget is unchanged: `A` never touches the homography's third row.
        let pair = PerspectiveMap(vertical: 500, horizontal: 500, shear: 0, aspect: 2)
        XCTAssertEqual(pair.vertical, PerspectiveMap(vertical: 500, horizontal: 500).vertical)
        XCTAssertEqual(pair.horizontal, PerspectiveMap(vertical: 500, horizontal: 500).horizontal)
        print("408 · aspectLimit \(PerspectiveMap.aspectLimit) · 端点合法 · 非正数读作 1")
    }
}
