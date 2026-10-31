import XCTest
import Metal
import simd
import PhotonsCore

/// 2026-10-28 (P0 色彩分级) — **三向色彩分级**: 阴影 / 中间调 / 高光 × 色相 / 饱和 / 亮度, S3.8.
///
/// The suite is organised by what can be wrong, in the order it can lie:
///
///  1. **The windows.** 「阴影」 has to mean what the Light card's 阴影 means, so the weights are
///     `tone_shape.metal`'s own (parsed from the kernel text and compared, not asserted in a comment),
///     they sum to 1 everywhere, and the two outer windows do not overlap — which is what makes the
///     mid-tone weight `1 − shadow − highlight` a remainder rather than a third, disagreeing table.
///  2. **The claims, in numbers.** One wheel at 饱和 +100 shifts the hue by ≤ 2° and the luma by ≤ 1
///     code — measured per direction, printed per direction. Zero, in the event: the hue offset is a
///     rotation and the luma restoration is a uniform gain, neither of which can move the other.
///  3. **Isolation, byte for byte.** A shadow-only document leaves the highlight zone **0 changed
///     pixels** (Float16 bit patterns, all four channels), and the refutation — global weights — turns
///     that same measurement red. The two together are the proof the window is load-bearing.
///  4. **Neutral is structural.** A document with no grade does not visit the stage, has no link in the
///     chain, and renders the neutral frame's sha.
///  5. **The document.** Schema 9's additive rule: no key when neutral, absent key = zeros, a schema-8
///     blob re-encodes byte for byte, and the version is not stamped at decode.
///  6. **History.** One wheel, one row; two axes of the same wheel merge into the one row; another
///     wheel is another row; 双击复位 is a row of its own (`PanelResets` in the UI tests).
///  7. **Cost.** 4.10 Mpx, one frame, the pass's incremental milliseconds.
final class ColorGradingTests: XCTestCase {

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func kernelText(_ name: String) throws -> String {
        try String(contentsOf: Self.repoRoot
            .appendingPathComponent("Sources/PhotonsCore/Kernels/\(name).metal"), encoding: .utf8)
    }

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func picture(_ width: Int, _ height: Int, identity: String = "grade",
                         _ body: (Int, Int) -> (Double, Double, Double)) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = body(x, y)
                let o = (y * width + x) * 4
                rgba[o] = Float16(r); rgba[o + 1] = Float16(g)
                rgba[o + 2] = Float16(b); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-grade")
    }

    private static let toWorking = ColorPrimaries.conversion(from: ColorPrimaries.decoded,
                                                             to: ColorPrimaries.working)
    private static let toDecoded = ColorPrimaries.conversion(from: ColorPrimaries.working,
                                                             to: ColorPrimaries.decoded)
    private static let toSRGBLinear = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB)
    private static let fromSRGBLinear = ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)

    /// **A colour at a known luma and a known OKLCh hue.** For a grey, OKLab `L = Y^(1/3)` exactly (the
    /// fold's rows sum to 1), so choosing `L` from the luma puts the patch at the EV the region windows
    /// measure. The chroma is deliberately **modest** (0.02): the acceptance asks what the stage does to
    /// a hue and a luma, and a colour already near the **display** gamut's edge would be measured
    /// through S4's own clamp — a fact about the display, not about this stage. (Measured: 饱和 +100 on
    /// a 0.05-chroma shadow patch lands at C = 0.10, which Rec.2020 holds and sRGB does not, and the
    /// 4.36° of "hue shift" the earlier fixture reported was S4 clipping blue, with the luma unchanged
    /// to 6.7e-5.) The stage's own gamut behaviour — it shortens the chroma move instead of clipping —
    /// is what `testTheGamutEdgeShortensTheMoveInsteadOfRotatingTheHue` measures.
    static func patch(hue: Double = 40, chroma: Double = 0.02, lumaEv: Double) -> SIMD3<Double> {
        let L = pow(pow(2, lumaEv), 1.0 / 3.0)          // grey: L = Y^(1/3)
        let working = OKLCh.toLinear(L: L, C: chroma, hue: hue)
        return toDecoded.applying(to: working)
    }

    /// Three horizontal bands — shadow / mid-tone / highlight — each at the **centre** of its window, so
    /// its weight vector is exactly `(1, 0, 0)`, `(0, 1, 0)`, `(0, 0, 1)`:
    ///
    /// ```
    ///   −6.5 EV  ← 阴影 owns it outright (full weight at and below −5.9 EV)
    ///   −3.55 EV ← 中间调 owns it outright (the gap between −3.9 and −3.2)
    ///   −1.0 EV  ← 高光 owns it outright (full weight above −1.2 EV)
    /// ```
    ///
    /// 32 rows per band, so a band is `height/3` rows of one colour.
    private static let bandEvs: [Double] = [-6.5, -3.55, -1.0]

    private static func bands(width: Int = 24, bandHeight: Int = 32) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * bandHeight * 3 * 4)
        let height = bandHeight * 3
        for (b, ev) in bandEvs.enumerated() {
            let c = patch(lumaEv: ev)
            for y in (b * bandHeight)..<((b + 1) * bandHeight) {
                for x in 0..<width {
                    let o = (y * width + x) * 4
                    rgba[o] = Float16(c.x); rgba[o + 1] = Float16(c.y)
                    rgba[o + 2] = Float16(c.z); rgba[o + 3] = 1
                }
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-grade")
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel,
                         headroom: Double = 1,
                         globalWeights: Bool = false) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: headroom),
                                    useCache: false, wantsPixels: true,
                                    gradeGlobalWeights: globalWeights)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    private static func code(_ v: Float16) -> Int { Int((Double(v) * 255).rounded()) }

    /// The display pixel decoded back to **linear sRGB** and then to the working primaries — the space
    /// the stage computes in, so a hue read off it is comparable with the stage's own numbers.
    private static func workingPixel(_ img: DisplayImage, x: Int, y: Int) -> SIMD3<Double> {
        let o = (y * img.width + x) * 4
        func decode(_ v: Float16) -> Double {
            let c = Double(v)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let srgb = SIMD3(decode(img.rgba[o]), decode(img.rgba[o + 1]), decode(img.rgba[o + 2]))
        return fromSRGBLinear.applying(to: srgb)
    }

    private static func luma(_ img: DisplayImage, x: Int, y: Int) -> Double {
        dot(workingPixel(img, x: x, y: y), ColorGrade.lumaWeights)
    }

    private static func hue(_ img: DisplayImage, x: Int, y: Int) -> Double {
        OKLCh.fromLinear(workingPixel(img, x: x, y: y)).hue
    }

    /// Circular difference in degrees, `a − b`, in −180…180.
    private static func hueDelta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    /// A document with one wheel set.
    private func document(_ direction: Int, hue: Double = 0, saturation: Double = 0,
                          lightness: Double = 0) -> EditModel {
        var edit = EditModel.neutral
        let wheel = GradeWheel(hue: hue, saturation: saturation, lightness: lightness)
        switch direction {
        case 0: edit.colorGrading.shadows = wheel
        case 1: edit.colorGrading.midtones = wheel
        default: edit.colorGrading.highlights = wheel
        }
        return edit
    }

    private static let directionNames = ["阴影", "中间调", "高光"]

    // MARK: - ① the windows

    /// **The four constants are `tone_shape.metal`'s**, parsed out of the kernel text. A copy in Swift is
    /// unavoidable (Metal cannot import Swift); a copy that *drifts* is the bug 075 spent a batch killing
    /// on the luma weights, so the two are compared here rather than trusted.
    func testTheWindowsAreToneShapesOwnNumbers() throws {
        let text = try kernelText("tone_shape")
        func constant(_ name: String) throws -> Double {
            let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains("float \(name) =") },
                                     "tone_shape.metal has no \(name)")
            let value = try XCTUnwrap(line.split(separator: "=").last)
            return try XCTUnwrap(Double(value.replacingOccurrences(of: ";", with: "")
                .trimmingCharacters(in: .whitespaces)))
        }
        XCTAssertEqual(ColorGrade.shadowLowEV, try constant("SHADOW_LO_EV"), accuracy: 1e-12)
        XCTAssertEqual(ColorGrade.shadowHighEV, try constant("SHADOW_HI_EV"), accuracy: 1e-12)
        XCTAssertEqual(ColorGrade.highlightLowEV, try constant("HIGHLIGHT_LO_EV"), accuracy: 1e-12)
        XCTAssertEqual(ColorGrade.highlightHighEV, try constant("HIGHLIGHT_HI_EV"), accuracy: 1e-12)
        print("GRADE WINDOWS · shadow \(ColorGrade.shadowLowEV)…\(ColorGrade.shadowHighEV) EV"
              + " · highlight \(ColorGrade.highlightLowEV)…\(ColorGrade.highlightHighEV) EV"
              + " · toneshape's own")
    }

    /// **Partition of unity, at every EV.** The three weights sum to 1 over the whole axis — including
    /// below the shadow window and above the highlight one — and each is 0…1. This is what makes
    /// 「一个区域的滑杆到处是同一个意思」 true and lets the isolation claim be a bit-exact one.
    func testTheThreeWeightsSumToOneAtEveryEV() {
        var worst = 0.0
        var worstEv = 0.0
        for step in 0...2000 {
            let ev = -16 + Double(step) * 0.008          // −16 … 0 EV
            let w = ColorGrade.weights(luma: pow(2, ev))
            let sum = w.x + w.y + w.z
            if abs(sum - 1) > worst { worst = abs(sum - 1); worstEv = ev }
            XCTAssertGreaterThanOrEqual(w.x, 0)
            XCTAssertGreaterThanOrEqual(w.y, 0)
            XCTAssertGreaterThanOrEqual(w.z, 0)
        }
        print("GRADE WEIGHTS · max |Σw − 1| over 2001 EVs (−16…0): \(String(format: "%.2e", worst))"
              + " (worst at \(String(format: "%.3f", worstEv)) EV)")
        XCTAssertLessThan(worst, 1e-12, "a partition of unity is what makes the mid weight a remainder")
    }

    /// The three fixture bands really are each a pure region: `(1,0,0)`, `(0,1,0)`, `(0,0,1)` — exactly.
    /// If this fails, every isolation number below would be measuring a blend instead of a region.
    func testTheThreeBandsArePureRegions() {
        for (i, ev) in Self.bandEvs.enumerated() {
            let w = ColorGrade.weights(luma: pow(2, ev))
            print("GRADE REGION · \(Self.directionNames[i]) @ \(ev) EV → w = (\(w.x), \(w.y), \(w.z))")
            XCTAssertEqual(w[i], 1.0, "band \(i) must be owned outright by its own region")
            for j in 0..<3 where j != i {
                XCTAssertEqual(w[j], 0.0, accuracy: 0, "band \(i) must not leak into region \(j)")
            }
        }
    }

    /// A shadow-only document's effective parameters are the **identity** in the highlight zone — the
    /// arithmetic reason the pixels there cannot move, stated before any render happens.
    func testAShadowOnlyDocumentHasNoEffectInTheHighlightZone() {
        let group = document(0, hue: -80, saturation: 90, lightness: 60).colorGrading
        for (i, ev) in Self.bandEvs.enumerated() {
            let p = ColorGrade.effective(group, weights: ColorGrade.weights(luma: pow(2, ev)))
            if i == 0 {
                XCTAssertFalse(p.isIdentity, "the shadow wheel must reach its own region")
            } else {
                XCTAssertTrue(p.isIdentity, "\(Self.directionNames[i]): the shadow wheel must not reach here")
            }
        }
    }

    // MARK: - ② the claims, in numbers

    /// **饱和 +100 per wheel: hue shift ≤ 2°, luma change ≤ 1 code.**
    ///
    /// The two properties are structural, not lucky: `C · 2` at a fixed OKLab `L` and hue is still that
    /// hue, and the luma restoration is a **uniform gain**, which is a scalar on `(L, a, b)` and therefore
    /// cannot rotate the angle. The numbers are printed per direction because the acceptance asks for
    /// three rows of data, not one.
    func testSaturationPlusHundredShiftsNoHueAndNoLuma() throws {
        let image = Self.bands()
        let graph = try makeGraph(image, identity: "grade-sat")
        let neutral = try display(graph, EditModel.neutral)
        var lines: [String] = []
        for direction in 0..<3 {
            let moved = try display(graph, document(direction, saturation: 100))
            // A sample point in the middle of this direction's band.
            let x = 12, y = direction * 32 + 16
            let dh = abs(Self.hueDelta(Self.hue(moved, x: x, y: y), Self.hue(neutral, x: x, y: y)))
            let lumaIn = Self.luma(neutral, x: x, y: y)
            let lumaOut = Self.luma(moved, x: x, y: y)
            let lumaCodes = abs(Double(Self.code(Float16(min(max(lumaOut, 0), 1)))
                                       - Self.code(Float16(min(max(lumaIn, 0), 1)))))
            // How much the picture actually moved: a saturation move that does nothing would pass the
            // two assertions above for the wrong reason.
            var biggestChannelMove = 0
            for c in 0..<3 {
                let o = (y * moved.width + x) * 4 + c
                biggestChannelMove = max(biggestChannelMove,
                                         abs(Self.code(moved.rgba[o]) - Self.code(neutral.rgba[o])))
            }
            lines.append("\(Self.directionNames[direction]) @\(Self.bandEvs[direction])EV"
                         + " Δhue \(String(format: "%.4f", dh))°"
                         + " Δluma \(String(format: "%.2e", abs(lumaOut - lumaIn))) (\(lumaCodes) 码)"
                         + " maxΔchannel \(biggestChannelMove) 码")
            XCTAssertLessThanOrEqual(dh, 2, "\(Self.directionNames[direction]): 饱和不得旋转色相")
            XCTAssertLessThanOrEqual(abs(lumaOut - lumaIn), 1.0 / 255, "\(Self.directionNames[direction]): 饱和不得改变亮度")
            XCTAssertGreaterThan(biggestChannelMove, 3,
                                 "\(Self.directionNames[direction]): a +100 saturation must actually move the pixel")
        }
        print("GRADE SAT +100 · " + lines.joined(separator: " · "))
    }

    /// **The gamut edge shortens the move instead of rotating the hue.** A chroma the working space
    /// cannot hold at this lightness and hue — here `C = 0.20` at `L = 0.75` asked to double — comes back
    /// with a negative channel. Clipping it would rotate the hue by degrees and eat the luma; the stage
    /// instead stops at the widest colour that fits. Measured on the **CPU reference**, so what is
    /// measured is the stage and not the display encode (`S4` clamps negatives, which is its job).
    func testTheGamutEdgeShortensTheMoveInsteadOfRotatingTheHue() throws {
        // Find the edge first — the widest chroma this space holds at L = 0.75 / hue 40 — then stand one
        // step inside it. Hard-coding a chroma would be a guess about a gamut; this is a measurement.
        var edge = 0.02
        while edge < 0.5 {
            let v = OKLCh.toLinear(L: 0.75, C: edge, hue: 40)
            if min(min(v.x, v.y), v.z) < 0 { break }
            edge += 0.005
        }
        // 30 % inside the edge: comfortably a colour this space has, and unmistakably short of the ×2
        // the slider asks for.
        let inside = edge * 0.7
        XCTAssertGreaterThan(inside, 0.02, "the search must find a real edge")
        let working = OKLCh.toLinear(L: 0.75, C: inside, hue: 40)
        // The bright one is the 高光 wheel's region (a shadow-only document would — correctly — leave
        // this pixel alone; that is what the isolation tests measure from the other side).
        let group = document(2, saturation: 100).colorGrading
        let out = ColorGrade.apply(working, group: group)
        let before = OKLCh.fromLinear(working)
        let after = OKLCh.fromLinear(out)
        let lumaBefore = dot(working, ColorGrade.lumaWeights)
        let lumaAfter = dot(out, ColorGrade.lumaWeights)
        print("GRADE GAMUT · edge C ≈ \(String(format: "%.3f", edge)) at L 0.75/40°:"
              + " C \(String(format: "%.4f", before.C)) → \(String(format: "%.4f", after.C))"
              + " (asked ×2, stopped inside the gamut) · Δhue "
              + String(format: "%.4f", abs(Self.hueDelta(after.hue, before.hue))) + "°"
              + " · Δluma \(String(format: "%.2e", abs(lumaAfter - lumaBefore)))")
        XCTAssertGreaterThan(after.C, before.C * 1.02, "it must still move towards the request")
        XCTAssertLessThan(after.C, before.C * 2, "…and it cannot deliver a colour the space does not have")
        XCTAssertEqual(Self.hueDelta(after.hue, before.hue), 0, accuracy: 0.5,
                       "at the gamut edge the hue must still be the hue")
        XCTAssertEqual(abs(lumaAfter - lumaBefore) / lumaBefore, 0, accuracy: 5e-3,
                       "…and the luma must still be the luma")
    }

    /// 色相 +100 = +30° **exactly**, in every direction — the unit the HSL card already uses. Measured
    /// through the whole pipeline (S0's matrix, S3.8, S4's encode) so the number is what a user sees.
    func testTheHueWheelDeliversThirtyDegreesPerFullTravel() throws {
        let image = Self.bands()
        let graph = try makeGraph(image, identity: "grade-hue")
        let neutral = try display(graph, EditModel.neutral)
        var lines: [String] = []
        for direction in 0..<3 {
            let moved = try display(graph, document(direction, hue: 100))
            let x = 12, y = direction * 32 + 16
            let dh = Self.hueDelta(Self.hue(moved, x: x, y: y), Self.hue(neutral, x: x, y: y))
            lines.append("\(Self.directionNames[direction]) \(String(format: "%+.2f", dh))°")
            XCTAssertEqual(dh, 30, accuracy: 0.5, "±100 必须是 ±30°（HSL 卡同一把尺子）")
        }
        print("GRADE HUE +100 · " + lines.joined(separator: " · ") + " (target +30.00°)")
    }

    /// 亮度 +100 = **+1 stop** of that region's linear light, and −100 = −1 stop. A pure gain, so the
    /// ratio is the whole claim. Measured at `headroom: 4`: at +1 stop the highlight band lands exactly
    /// on display white, and S4's own clamp is not this stage's business.
    func testTheLightnessWheelDeliversOneStopPerFullTravel() throws {
        let image = Self.bands()
        let graph = try makeGraph(image, identity: "grade-light")
        let neutral = try display(graph, EditModel.neutral, headroom: 4)
        var lines: [String] = []
        for direction in 0..<3 {
            for units in [100.0, -100.0] {
                let moved = try display(graph, document(direction, lightness: units), headroom: 4)
                let x = 12, y = direction * 32 + 16
                let ratio = Self.luma(moved, x: x, y: y) / Self.luma(neutral, x: x, y: y)
                let stops = log2(ratio)
                lines.append("\(Self.directionNames[direction]) \(Int(units)) → \(String(format: "%+.3f", stops)) EV")
                XCTAssertEqual(stops, units / 100, accuracy: 0.01, "亮度 ±100 必须是 ±1 档")
            }
        }
        print("GRADE LIGHTNESS ±100 · " + lines.joined(separator: " · "))
    }

    // MARK: - ③ isolation, byte for byte

    /// **A shadow-only document leaves the highlight zone bit-identical**: every channel of every pixel
    /// in the −1.0 EV band, compared as Float16 bit patterns (not as codes, and not with a tolerance),
    /// while the shadow band itself moves.
    func testAShadowOnlyDocumentLeavesTheHighlightZoneUntouched() throws {
        let image = Self.bands()
        let graph = try makeGraph(image, identity: "grade-isolation")
        let neutral = try display(graph, EditModel.neutral)
        let moved = try display(graph, document(0, hue: -70, saturation: 80, lightness: 50))
        let (changed, total) = Self.changedPixels(neutral, moved, rows: 64..<96)
        let (shadowChanged, _) = Self.changedPixels(neutral, moved, rows: 0..<32)
        let (midChanged, midTotal) = Self.changedPixels(neutral, moved, rows: 32..<64)
        print("GRADE ISOLATION · shadow-only: highlight band \(changed)/\(total) changed,"
              + " mid band \(midChanged)/\(midTotal), shadow band \(shadowChanged) changed")
        XCTAssertEqual(changed, 0, "高光区必须逐字节不变（不是「≤1 码」）")
        XCTAssertGreaterThan(shadowChanged, 100, "阴影区必须真的动了，否则这条隔离是空的")
        // The mid band is *partly* the shadow window's business? No: −3.55 EV is above the shadow
        // window's top (−3.9), so a shadow-only document must leave it alone too — the same exactness,
        // one region closer.
        XCTAssertEqual(midChanged, 0, "中间调在阴影窗之外，也必须逐字节不变")
    }

    /// **Refutation.** With `gradeGlobalWeights` — the windows replaced by `(1/3, 1/3, 1/3)`, i.e. the
    /// mistake of forgetting the window — the *same* shadow-only document changes most of the highlight
    /// band. That is what makes the previous test's 0 a claim about the windows.
    func testTheRefutationMakesTheIsolationFail() throws {
        let image = Self.bands()
        let graph = try makeGraph(image, identity: "grade-refutation")
        let neutral = try display(graph, EditModel.neutral)
        let globalWeights = try display(graph, document(0, hue: -70, saturation: 80, lightness: 50),
                                        globalWeights: true)
        let (changed, total) = Self.changedPixels(neutral, globalWeights, rows: 64..<96)
        print("GRADE REFUTATION · global weights on a shadow-only document:"
              + " highlight band \(changed)/\(total) changed (the real weights give 0)")
        XCTAssertEqual(changed, total,
                       "没有亮度窗，阴影轮就会改到整个画面——这正是「高光区 0 变化」要证明的东西")
    }

    /// The same isolation for the other direction: a highlight-only document leaves the shadow band
    /// untouched. Two directions, two windows — one test each, so neither window can rot unmeasured.
    func testAHighlightOnlyDocumentLeavesTheShadowZoneUntouched() throws {
        let image = Self.bands()
        let graph = try makeGraph(image, identity: "grade-isolation-2")
        let neutral = try display(graph, EditModel.neutral)
        let moved = try display(graph, document(2, hue: 60, saturation: 70, lightness: -40))
        let (changed, total) = Self.changedPixels(neutral, moved, rows: 0..<32)
        let (highChanged, _) = Self.changedPixels(neutral, moved, rows: 64..<96)
        print("GRADE ISOLATION · highlight-only: shadow band \(changed)/\(total) changed,"
              + " highlight band \(highChanged) changed")
        XCTAssertEqual(changed, 0)
        XCTAssertGreaterThan(highChanged, 100)
    }

    /// **Grey stays grey.** Every wheel at 色相 +100 / 饱和 +100 on a neutral frame changes no byte:
    /// `C = 0` scaled is still 0, and the hue offset is gated by the chroma gate — the same reason S3.6
    /// leaves a grey alone. (亮度 would move it, and is not in this document.)
    func testAHueAndSaturationGradeCannotTouchAGrey() throws {
        let grey = picture(24, 24) { _, _ in (0.18, 0.18, 0.18) }
        let graph = try makeGraph(grey, identity: "grade-grey")
        let neutral = try display(graph, EditModel.neutral)
        for direction in 0..<3 {
            let moved = try display(graph, document(direction, hue: 100, saturation: 100))
            XCTAssertEqual(moved.sha256(), neutral.sha256(),
                           "\(Self.directionNames[direction]): 灰没有色相，色相/饱和必须逐字节不变")
        }
        print("GRADE GREY · 色相 +100 / 饱和 +100 on a 0.18 grey: byte-identical")
    }

    /// Every pixel's own weights must be *computed from its own luma* — the same patch under two
    /// exposures is two different regions. A stage that read one global luma would pass the isolation
    /// tests above (they use bands) but fail this one.
    func testTheWeightsFollowEachPixelsOwnLuma() throws {
        // A vertical ramp: 128 columns from −8 EV to +0.5 EV, one colour.
        let width = 128
        let image = picture(width, 8) { x, _ in
            let ev = -8 + Double(x) / Double(width - 1) * 8.5
            let c = Self.patch(lumaEv: ev)
            return (c.x, c.y, c.z)
        }
        let graph = try makeGraph(image, identity: "grade-ramp")
        let neutral = try display(graph, EditModel.neutral)
        let moved = try display(graph, document(0, saturation: 100))
        var leftMove = 0, rightMove = 0
        for x in 0..<width {
            let d = (0..<3).map { c in
                abs(Self.code(moved.rgba[x * 4 + c]) - Self.code(neutral.rgba[x * 4 + c]))
            }.max() ?? 0
            if x < 16 { leftMove = max(leftMove, d) }
            if x >= width - 16 { rightMove = max(rightMove, d) }
        }
        print("GRADE RAMP · shadow wheel +100: dark end maxΔ \(leftMove) 码, bright end maxΔ \(rightMove) 码")
        XCTAssertGreaterThan(leftMove, 3, "the dark end must move")
        XCTAssertEqual(rightMove, 0, "the bright end is outside the shadow window and must not move")
    }

    // MARK: - ④ neutral is structural

    /// **The acceptance.** A document with no grade never visits S3.8, its chain has no grade link, and
    /// the frame is the neutral frame's sha.
    func testANeutralGradeDoesNotVisitTheStage() throws {
        let image = Self.bands()
        let graph = try makeGraph(image, identity: "grade-neutral")
        let plain = try graph.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true))
        let pixels = try XCTUnwrap(plain.display)
        XCTAssertFalse(plain.trace.executed.contains(.grade), "中性文档不得访问 S3.8")
        let dims = ImageSize(width: image.width, height: image.height)
        let links = RenderKeyChain.links(identity: "grade-neutral", sourceSize: dims,
                                         canvas: dims, content: dims,
                                         edit: EditModel.neutral, display: DisplayOptions())
        XCTAssertNil(links.grade, "中性文档的键链不得长出新段")
        XCTAssertEqual(links.pipeline, RenderStage.allCases)
        print("GRADE NEUTRAL · trace \(plain.trace.csv) · sha \(pixels.sha256().prefix(12))…")
    }

    /// A document that *does* carry a grade gets one extra link, seeded by S3.6's (or S3.5/S3.4/S3's),
    /// and it sits between `.hsl` and `.vignette` — the position the stage claims.
    func testAGradeAddsExactlyOneLinkAndOneStage() throws {
        let dims = ImageSize(width: 64, height: 64)
        let graded = document(1, hue: 20, saturation: 40)
        let links = RenderKeyChain.links(identity: "grade-link", sourceSize: dims,
                                         canvas: dims, content: dims,
                                         edit: graded, display: DisplayOptions())
        let plain = RenderKeyChain.links(identity: "grade-link", sourceSize: dims,
                                         canvas: dims, content: dims,
                                         edit: EditModel.neutral, display: DisplayOptions())
        let link = try XCTUnwrap(links.grade)
        XCTAssertEqual(links.pipeline, RenderStage.pipeline(hasMasks: false, hasGrade: true))
        XCTAssertEqual(Array(links.pipeline.suffix(3)), [.color, .grade, .display])
        XCTAssertEqual(link, KeyBuilder(KeyBuilder.digest(of: plain.color))
            .add("grade").add(graded.keyMaterial(.grade)).canonical,
                       "S3.8 必须由 S3 的键种下（没有 HSL/黑白/局部色时）")
        XCTAssertNotEqual(links.vignette, plain.vignette, "暗角读分级的结果，键必须动")
        print("GRADE LINK · \(links.pipeline.map(\.short).joined(separator: " "))")
    }

    /// With **both** a band and a grade the order is S3.6 then S3.8, and the grade link is seeded by the
    /// HSL link — the one thing that could silently go wrong in a chain of six conditional stages.
    func testABandAndAGradeChainInOrder() throws {
        var edit = document(1, hue: 20)
        edit.color.bands[0] = HSLBand(hue: 30)
        let dims = ImageSize(width: 32, height: 32)
        let links = RenderKeyChain.links(identity: "grade-both", sourceSize: dims,
                                         canvas: dims, content: dims,
                                         edit: edit, display: DisplayOptions())
        XCTAssertEqual(Array(links.pipeline.suffix(4)), [.color, .hsl, .grade, .display])
        XCTAssertEqual(try XCTUnwrap(links.grade),
                       KeyBuilder(KeyBuilder.digest(of: try XCTUnwrap(links.hsl)))
                        .add("grade").add(edit.keyMaterial(.grade)).canonical)
        XCTAssertNil(links.localColor, "没有局部色，这一段不该存在")
        print("GRADE+BAND · \(links.pipeline.map(\.short).joined(separator: " "))")
    }

    /// A grade drag dirties `.grade` and nothing else; a band drag does not dirty `.grade`. This is the
    /// same split 076 made inside S3, and the reason the stage is separate rather than folded in.
    func testTheDirtySetsAreSeparate() {
        var graded = EditModel.neutral
        graded.colorGrading.shadows.hue = 20
        XCTAssertEqual(graded.changedStages(from: .neutral), [.grade])
        var banded = EditModel.neutral
        banded.color.bands[0].hue = 20
        XCTAssertEqual(banded.changedStages(from: .neutral), [.hsl])
        var both = graded
        both.color.bands[0].hue = 20
        XCTAssertEqual(both.changedStages(from: graded), [.hsl])
        print("GRADE DIRTY · shadows.hue → [.grade] · bands[0].hue → [.hsl]")
    }

    // MARK: - ⑤ the document (schema 9)

    /// **The additive rule, measured on bytes.** A schema-8 document (no `colorGrading` key) decodes,
    /// re-encodes byte for byte, and its version stays 8 — nothing migrates and nothing is stamped.
    func testASchema8DocumentReEncodesByteForByte() throws {
        var old = EditModel.neutral
        old.light.exposure = 0.5
        old.schemaVersion = 8
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let first = try encoder.encode(old)
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains("colorGrading"),
                       "中性分级不得写进文档（schema-8 的字节必须原样）")
        let reloaded = try JSONDecoder().decode(EditModel.self, from: first)
        XCTAssertEqual(reloaded.schemaVersion, 8, "没迁移就不盖章")
        XCTAssertFalse(reloaded.hasGrade)
        XCTAssertEqual(try encoder.encode(reloaded), first)
        print("GRADE SCHEMA · schema-8 blob → \(first.count) bytes → identical, version still 8")
    }

    /// A grade document writes the key, reads it back, and re-encodes byte-identically — and the
    /// version is 10 because this build wrote it (9 was the grade's own number; 10 is `healSpots`).
    func testTheGradeGroupRoundTripsByteForByte() throws {
        let graded = document(2, hue: -12.5, saturation: 33, lightness: 7.25)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(graded)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"colorGrading\""))
        XCTAssertTrue(text.contains("\"highlights\""))
        XCTAssertEqual(graded.schemaVersion, 13)
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back, graded)
        XCTAssertEqual(try encoder.encode(back), data)
        print("GRADE SCHEMA · nine numbers round-trip byte for byte, version 10")
    }

    // MARK: - ⑥ history

    /// **每轮一行，拖动合并.** Two axes of one wheel in a run are one row (the wheel *is* the gesture
    /// class); a different wheel is a second row; the row's text names the wheel and the axis.
    func testOneWheelIsOneRowAndItsAxesMerge() {
        var history = EditHistory(baseline: .neutral, label: "原始", now: Date(timeIntervalSince1970: 0))
        var first = EditModel.neutral
        first.colorGrading.shadows.hue = 25
        history.commit(first, label: "色彩分级 阴影")
        var second = first
        second.colorGrading.shadows.saturation = 40
        history.commit(second, label: "色彩分级 阴影")
        XCTAssertEqual(history.count, 2, "同一个轮的两根轴必须合并成一行：\(history.snapshots.map(\.label))")
        XCTAssertEqual(history.snapshots.last?.changes.count, 2, "合并后的行说两件事")

        var third = second
        third.colorGrading.highlights.lightness = -30
        history.commit(third, label: "色彩分级 高光")
        XCTAssertEqual(history.count, 3, "换一个轮就是新的一行")
        XCTAssertEqual(history.snapshots.last?.label, "色彩分级 高光")
        XCTAssertEqual(history.snapshots.last?.changes.first?.summary, "色彩分级[高光] 亮度 0 → -30")
        print("GRADE HISTORY · \(history.snapshots.map { "\($0.label)[\($0.changes.count)]" })")
    }

    /// The field-level names exist for all nine numbers (a key the table does not know would print
    /// itself, which is the fallback — but a card with nine unreadable rows is not a history).
    func testAllNineFieldsHaveNames() {
        for wheel in ["shadows", "midtones", "highlights"] {
            for axis in ["hue", "saturation", "lightness"] {
                let key = "colorGrading.\(wheel).\(axis)"
                XCTAssertNotEqual(EditHistory.parameterName(for: key), key, "\(key) 没有中文名")
            }
        }
        XCTAssertEqual(EditField(key: "colorGrading.shadows.hue", group: .colorGrading).gestureClass,
                       "colorGrading.shadows")
        XCTAssertEqual(EditField(key: "colorGrading.shadows.lightness", group: .colorGrading).gestureClass,
                       "colorGrading.shadows")
        XCTAssertNotEqual(EditField(key: "colorGrading.highlights.hue", group: .colorGrading).gestureClass,
                          "colorGrading.shadows")
    }

    // MARK: - ⑦ the kernel and the CPU reference

    /// The kernel **is** the CPU reference. The document is neutral outside the grade, so what is modelled
    /// here is S0's matrix, S3.8, S4's matrix and the sRGB encode — the same shape `HSLTests` uses.
    func testTheKernelAgreesWithTheCPUReference() throws {
        let image = Self.bands(width: 24, bandHeight: 8)
        let graph = try makeGraph(image, identity: "grade-cpu")
        var edit = EditModel.neutral
        edit.colorGrading.shadows = GradeWheel(hue: -35, saturation: 60, lightness: 20)
        edit.colorGrading.midtones = GradeWheel(hue: 15, saturation: -30, lightness: -10)
        edit.colorGrading.highlights = GradeWheel(hue: 70, saturation: 20, lightness: 5)
        let actual = try display(graph, edit)

        var worst = 0
        var total = 0
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = (y * image.width + x) * 4
                let src = SIMD3(Double(image.rgba[o]), Double(image.rgba[o + 1]),
                                Double(image.rgba[o + 2]))
                let working = Self.toWorking.applying(to: src)
                let out = ColorGrade.apply(working, group: edit.colorGrading)
                let srgb = Self.toSRGBLinear.applying(to: out)
                func encode(_ v: Double) -> Int {
                    let c = min(max(v, 0), 1)
                    let e = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
                    return Int((e * 255).rounded())
                }
                for c in 0..<3 {
                    let expected = encode(c == 0 ? srgb.x : (c == 1 ? srgb.y : srgb.z))
                    let got = Self.code(actual.rgba[o + c])
                    worst = max(worst, abs(expected - got))
                    total += abs(expected - got)
                    count += 1
                }
            }
        }
        print("GRADE CPU↔GPU · max |Δcode| \(worst), mean "
              + String(format: "%.3f", Double(total) / Double(count)) + " over \(count) channels")
        XCTAssertLessThanOrEqual(worst, 2, "内核必须就是这份 CPU 参考，不是「像」它")
    }

    /// Headroom survives: S3.8 is display-referred but not display-clamped (S4 is the only clamp), so a
    /// graded highlight above white keeps its range.
    func testAnHDRHighlightKeepsItsHeadroom() throws {
        let image = picture(16, 8) { x, _ in x < 8 ? (2.4, 1.6, 0.9) : (0.45, 0.2, 0.12) }
        let graph = try makeGraph(image, identity: "grade-hdr")
        let out = try display(graph, document(2, saturation: 40, lightness: 10), headroom: 4)
        let peak = (0..<(out.width * out.height)).map { Double(out.rgba[$0 * 4]) }.max() ?? 0
        print("GRADE HDR · peak after highlight sat +40 / 亮度 +10 at headroom 4: \(peak)")
        XCTAssertGreaterThan(peak, 1.05, "高光被压平了——headroom 丢了")
    }

    /// The letterbox is not a colour: outside the content rect the pixel is written back untouched.
    func testTheLetterboxStaysExactlyZero() throws {
        let image = picture(64, 32) { _, _ in (0.3, 0.25, 0.2) }
        let graph = try makeGraph(image, identity: "grade-matte")
        let canvas = ImageSize(width: 64, height: 64)
        let result = try graph.render(document(1, hue: 90, saturation: 100, lightness: 100),
                                      options: RenderOptions(canvas: canvas, scale: 1, wantsPixels: true))
        let pixels = try XCTUnwrap(result.display)
        var worst = 0.0
        for y in [0, 1, 15, 48, 62, 63] {
            for x in stride(from: 0, to: 64, by: 7) {
                for c in 0..<3 {
                    worst = max(worst, Double(pixels.rgba[(y * 64 + x) * 4 + c]))
                }
            }
        }
        print("GRADE MATTE · max matte value with the mid wheel at ±100: \(worst)")
        XCTAssertEqual(worst, 0, "letterbox 不能被分级染色")
    }

    // MARK: - ⑧ cost

    /// 4.10 Mpx, one frame, `useCache: false`: the whole pipeline with and without S3.8, and the
    /// difference is the pass. Printed rather than asserted against a budget (056's rule: record it, do
    /// not invent a threshold); guarded only against a pathological kernel.
    func testTheStageCostsWhatAPassCosts() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let image = picture(2340, 1755) { x, y in
            (0.2 + Double((x * y) % 61) / 300, 0.3, 0.4)
        }
        XCTAssertEqual(image.width * image.height, 4_106_700)
        let graph = try makeGraph(image, identity: "grade-cost")
        let edit = document(1, hue: 20, saturation: 40)

        _ = try graph.render(EditModel.neutral, options: RenderOptions(scale: 1, useCache: false))
        _ = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false))
        var without = Double.infinity
        var with = Double.infinity
        for _ in 0..<5 {
            for e in [EditModel.neutral, edit] {
                let r = try graph.render(e, options: RenderOptions(scale: 1, useCache: false))
                if e.hasGrade { with = min(with, r.trace.gpuMilliseconds) }
                else { without = min(without, r.trace.gpuMilliseconds) }
            }
        }
        print("GRADE COST · 4.10 Mpx (\(image.width)×\(image.height)): whole frame "
              + String(format: "%.2f", without) + " ms → " + String(format: "%.2f", with)
              + " ms (+" + String(format: "%.2f", with - without) + " ms for S3.8, best of 5, interleaved)")
        XCTAssertLessThan(with - without, 40, "4.1 Mpx 上一个分级 pass 不能是几十毫秒")
    }

    // MARK: - helpers

    /// Changed pixels (any of the four Float16 channels a different bit pattern) in a row range.
    private static func changedPixels(_ a: DisplayImage, _ b: DisplayImage,
                                      rows: Range<Int>) -> (changed: Int, total: Int) {
        precondition(a.width == b.width && a.height == b.height)
        var changed = 0
        var total = 0
        for y in rows {
            for x in 0..<a.width {
                let o = (y * a.width + x) * 4
                total += 1
                for c in 0..<4 where a.rgba[o + c].bitPattern != b.rgba[o + c].bitPattern {
                    changed += 1
                    break
                }
            }
        }
        return (changed, total)
    }
}
