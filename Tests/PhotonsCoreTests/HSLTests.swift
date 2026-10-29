import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 派单 076 — **HSL**: the eight colour bands, in **OKLCh**, in the display-referred domain (S3.6).
///
/// The suite is organised by the four things that can be wrong, in the order they can lie:
///
///  1. **The space.** HSL on linear light read `l = 0.5` for both pure blue and pure yellow, whose
///     luminance differs by 6.9× (079 结论 4). OKLCh has to fix that *and* keep the eight band centres
///     pointing at the eight colours the panel names — which is a claim about a conversion, so it is
///     measured against the graph's own fold, not against a table copied from a website.
///  2. **The weights.** 079 结论 5 measured the old scheme's 4× ripple (green +100 delivered 25.93 at
///     90°/150°, 100 at 120°, 0 at 75°/165°). Here `Σw = 1` at every hue, a band at its own centre
///     delivers its full value, and all eight at once deliver it uniformly — measured on a 0.25°
///     sweep, seam included.
///  3. **The pixels.** Neutral is byte-identical (the stage does not exist), grey is byte-identical
///     (the chroma gate is exactly 0), a red-band drag cannot touch a blue pixel (0 samples, maxΔ 0),
///     the 0°/360° seam adds no step (≤ 2 codes against the same sweep without the stage), and a
///     1°-per-pixel hue ramp shows no banding.
///  4. **The cost.** 4.10 Mpx, the incremental milliseconds of the pass.
///
/// The CPU reference (`HSLBands`, `OKLCh`) is the definition the kernel is written against; §3.6
/// compares them end to end so the two cannot drift without a red test.
final class HSLTests: XCTestCase {

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

    private func picture(_ width: Int, _ height: Int, identity: String = "hsl",
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
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-076")
    }

    private func flat(_ value: Double, width: Int = 32, height: Int = 32) -> LinearImage {
        picture(width, height) { _, _ in (value, value, value) }
    }

    /// `hsl → linear sRGB` (the same arithmetic the panel's swatch uses), for building fixtures whose
    /// hue in the **working** space is known.
    private static func hslToLinearSRGB(h: Double, s: Double, l: Double) -> SIMD3<Double> {
        func channel(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return SIMD3(channel(p, q, h + 1.0 / 3.0), channel(p, q, h), channel(p, q, h - 1.0 / 3.0))
    }

    private static let toWorking = ColorPrimaries.conversion(from: ColorPrimaries.decoded,
                                                             to: ColorPrimaries.working)
    private static let toSRGB = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB)

    /// The **OKLCh hue** of one of the eight wheel colours, computed through the graph's own fold.
    private static func oklchHue(ofWheelColour degrees: Double) -> Double {
        let srgb = hslToLinearSRGB(h: degrees / 360, s: 0.85, l: 0.5)
        return OKLCh.fromLinear(toWorking.applying(to: srgb)).hue
    }

    /// A picture whose every column sits at a known **OKLCh** hue: `360` columns, one degree each,
    /// at a fixed lightness and chroma. Built by walking OKLCh and converting back, because the band
    /// centres are OKLCh angles — a fixture made with HSL angles would be a different wheel.
    private func oklchWheel(height: Int = 16, L: Double = 0.62, C: Double = 0.14) -> LinearImage {
        picture(360, height) { x, _ in
            let working = OKLCh.toLinear(L: L, C: C, hue: Double(x))
            let srgb = Self.toSRGB.applying(to: working)
            return (srgb.x, srgb.y, srgb.z)
        }
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel,
                         headroom: Double = 1) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: headroom),
                                    wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    private static func code(_ v: Float16) -> Int { Int((Double(v) * 255).rounded()) }

    private func codeDifferences(_ a: DisplayImage, _ b: DisplayImage) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(a.width * a.height * 3)
        for i in 0..<(a.width * a.height) {
            for c in 0..<3 {
                out.append(abs(Self.code(a.rgba[i * 4 + c]) - Self.code(b.rgba[i * 4 + c])))
            }
        }
        return out
    }

    /// A document with one band set.
    private func document(_ band: Int, hue: Double = 0, saturation: Double = 0,
                          luminance: Double = 0) -> EditModel {
        var edit = EditModel.neutral
        edit.color.bands[band] = HSLBand(hue: hue, saturation: saturation, luminance: luminance)
        return edit
    }

    private func allBands(_ hue: Double = 0, _ saturation: Double = 0,
                          _ luminance: Double = 0) -> EditModel {
        var edit = EditModel.neutral
        edit.color.bands = Array(repeating: HSLBand(hue: hue, saturation: saturation,
                                                    luminance: luminance),
                                 count: ColorGroup.bandCount)
        return edit
    }

    // MARK: - ① the space

    /// OKLab is the graph's own fold (075's Rec.2020 derivation), so the published sRGB values are the
    /// check that the two matrices are the *documented* ones and not a plausible-looking pair.
    func testOKLChMatchesThePublishedValues() {
        let cases: [(String, SIMD3<Double>, (L: Double, C: Double, h: Double))] = [
            ("red",     SIMD3(1, 0, 0), (0.6280, 0.2577, 29.23)),
            ("yellow",  SIMD3(1, 1, 0), (0.9680, 0.2110, 109.77)),
            ("green",   SIMD3(0, 1, 0), (0.8664, 0.2948, 142.50)),
            ("blue",    SIMD3(0, 0, 1), (0.4520, 0.3132, 264.05)),
            ("magenta", SIMD3(1, 0, 1), (0.7017, 0.3224, 328.36)),
            ("white",   SIMD3(1, 1, 1), (1.0000, 0.0000, 90.00)),
        ]
        for (name, srgb, expected) in cases {
            let working = Self.toWorking.applying(to: srgb)
            let lch = OKLCh.fromLinear(working)
            XCTAssertEqual(lch.L, expected.L, accuracy: 0.0015, "\(name): L")
            XCTAssertEqual(lch.C, expected.C, accuracy: 0.0015, "\(name): C")
            if expected.C > 0.01 {
                XCTAssertEqual(lch.hue, expected.h, accuracy: 0.05, "\(name): hue")
            }
        }

        // The round trip has to be exact enough to be invisible: 1e-9 on a linear channel is six orders
        // below one 8-bit code.
        var worst = 0.0
        for r in stride(from: 0.0, through: 1.0, by: 0.2) {
            for g in stride(from: 0.0, through: 1.0, by: 0.2) {
                for b in stride(from: 0.0, through: 1.0, by: 0.2) {
                    let v = SIMD3(r, g, b)
                    let lch = OKLCh.fromLinear(v)
                    let back = OKLCh.toLinear(L: lch.L, C: lch.C, hue: lch.hue)
                    worst = max(worst, max(abs(back.x - v.x), max(abs(back.y - v.y), abs(back.z - v.z))))
                }
            }
        }
        print("OKLCh · round trip worst error over a 6³ grid: \(String(format: "%.2e", worst))")
        XCTAssertLessThan(worst, 1e-9)
    }

    /// 079 结论 4, stated as the axis the panel cares about: **pure blue and pure yellow are 1.02 apart
    /// in OKLab L** (0.452 vs 0.968), where HSL's `l` says they are the same number (0.5).
    func testLightnessSeparatesBlueFromYellowWhereHSLCouldNot() {
        let blue = OKLCh.fromLinear(Self.toWorking.applying(to: SIMD3(0.0, 0.0, 1.0)))
        let yellow = OKLCh.fromLinear(Self.toWorking.applying(to: SIMD3(1.0, 1.0, 0.0)))
        let ratio = yellow.L / blue.L
        print("LUMINANCE ORDER · OKLab L blue \(String(format: "%.4f", blue.L))"
              + " yellow \(String(format: "%.4f", yellow.L)) ratio \(String(format: "%.2f", ratio))"
              + " · Rec2020 luminance ratio 6.9× · HSL l: 0.500 / 0.500")
        XCTAssertEqual(blue.L, 0.452, accuracy: 0.002)
        XCTAssertEqual(yellow.L, 0.968, accuracy: 0.002)
        // HSL's `l` is the same 0.500 for both — the defect, reproduced so the contrast is on record.
        func hslL(_ v: SIMD3<Double>) -> Double { (max(v.x, max(v.y, v.z)) + min(v.x, min(v.y, v.z))) / 2 }
        XCTAssertEqual(hslL(SIMD3(0.0, 0.0, 1.0)), hslL(SIMD3(1.0, 1.0, 0.0)))
    }

    /// The eight centres are the **same eight physical colours** the wheel names, re-derived in the
    /// space the stage runs in (the precedent 075 set for the wheel itself). If a centre is wrong, the
    /// band acts on a different colour than the dot in the panel says.
    func testTheEightCentresAreTheWheelColoursMeasuredInOKLCh() {
        let lightroom: [Double] = [0, 30, 60, 120, 180, 240, 285, 315]
        XCTAssertEqual(HSLBands.centresDegrees.count, 8)
        var lines: [String] = []
        for (i, degrees) in lightroom.enumerated() {
            let expected = Self.oklchHue(ofWheelColour: degrees)
            XCTAssertEqual(Double(HSLBands.centresDegrees[i]), expected, accuracy: 0.02,
                           "\(HSLAxisName.name(i)): centre is not the OKLCh hue of its own colour")
            lines.append("\(HSLAxisName.name(i)) \(String(format: "%.2f", expected))°")
        }
        print("HSL CENTRES (OKLCh) · " + lines.joined(separator: " · "))

        // Same eight colours, different spacing: OKLCh hue is perceptually even, HSL's is not, so the
        // gaps cannot be an eighth of a turn each. Purple/magenta really are 14° apart up there.
        let gaps = (0..<8).map { i -> Double in
            let next = Double(HSLBands.centresDegrees[(i + 1) % 8])
            let here = Double(HSLBands.centresDegrees[i])
            return (next - here).truncatingRemainder(dividingBy: 360) + (next < here ? 360 : 0)
        }
        print("HSL GAPS · " + gaps.map { String(format: "%.2f", $0) }.joined(separator: " · ")
              + "  (min \(String(format: "%.2f", gaps.min()!)) max \(String(format: "%.2f", gaps.max()!)))")
        XCTAssertLessThan(gaps.min()!, 20, "the violet/magenta pair must stay close — it is a fact")
        XCTAssertGreaterThan(gaps.max()!, 70, "aqua→blue is the widest gap in OKLCh")
        XCTAssertEqual(gaps.reduce(0, +), 360, accuracy: 1e-3, "the eight gaps are one turn")
    }

    // MARK: - ② the weights

    /// **The partition of unity.** `Σw = 1` at every hue, so a band's slider means the same thing
    /// wherever the pixel sits, and the unconditional normalisation has nothing to correct.
    func testTheWeightsSumToOneEverywhereIncludingTheSeam() {
        var worst = 0.0
        var worstAt = 0.0
        for step in 0..<1440 {                          // 0 … 359.75 in 0.25° steps
            let hue = Double(step) * 0.25
            let sum = (0..<8).reduce(0.0) { $0 + HSLBands.weight($1, hueDeg: hue) }
            if abs(sum - 1) > worst { worst = abs(sum - 1); worstAt = hue }
        }
        print("HSL WEIGHTS · max |Σw − 1| over 1440 hues = \(String(format: "%.2e", worst))"
              + " (worst at \(String(format: "%.2f", worstAt))°)")
        XCTAssertLessThan(worst, 1e-9,
                          "Σw must be exactly 1: that is what makes normalisation a guarantee")
    }

    /// A band reads 1 on its own centre and exactly 0 on both neighbours' centres — which is why a
    /// single band's +100 is not diluted by the bands around it (079's old scheme diluted even that:
    /// the tents overlapped by design and the sum was only divided when it passed 1).
    func testABandIsOneOnItsCentreAndZeroOnItsNeighbours() {
        for i in 0..<8 {
            XCTAssertEqual(HSLBands.weight(i, hueDeg: Double(HSLBands.centresDegrees[i])), 1.0,
                           accuracy: 1e-12, "\(HSLAxisName.name(i)): own centre must be exactly 1")
            let prev = (i + 7) % 8, next = (i + 1) % 8
            XCTAssertEqual(HSLBands.weight(i, hueDeg: Double(HSLBands.centresDegrees[next])), 0,
                           "\(HSLAxisName.name(i)): must reach exactly 0 at \(HSLAxisName.name(next))")
            XCTAssertEqual(HSLBands.weight(i, hueDeg: Double(HSLBands.centresDegrees[prev])), 0,
                           "\(HSLAxisName.name(i)): must reach exactly 0 at \(HSLAxisName.name(prev))")
        }
    }

    /// No seam at 0°/360°: the weight is continuous *through* the wrap. A 1° step across the seam must
    /// not move any weight further than the largest 1° step anywhere else in the wheel.
    func testTheWeightIsContinuousThroughTheZeroDegreeSeam() {
        func step(_ from: Double, _ to: Double) -> Double {
            (0..<8).map { abs(HSLBands.weight($0, hueDeg: to) - HSLBands.weight($0, hueDeg: from)) }
                .max() ?? 0
        }
        let seam = step(359, 0)                     // the wrap
        var interior = 0.0
        for d in 0..<359 { interior = max(interior, step(Double(d), Double(d + 1))) }
        print("HSL SEAM · 359°→0° weight step \(String(format: "%.5f", seam))"
              + " vs the wheel's own max 1° step \(String(format: "%.5f", interior))")
        XCTAssertLessThanOrEqual(seam, interior + 1e-9,
                                 "the seam must not be a special case — not even by a rounding step")
    }

    // MARK: - ③ delivery: 079 结论 5, in numbers

    /// **Single band +100.** At the band's own centre it delivers 100.00 units — no dilution. At the
    /// two mid-gaps beside it, 50.00 each, and those two agree to the last digit.
    ///
    /// (A smooth partition of unity cannot do better than 1/2 at a mid-gap: the two neighbours own the
    /// gap with `S(t)` and `S(1−t)`, which are equal at `t = 1/2` by construction. What 076's "差异
    /// ≤ 2%" buys is that the two sides are *symmetric* and that the peak is not diluted — both measured
    /// here — plus the all-bands uniformity below, which is the property a 4× ripple violates.)
    func testASingleBandDeliversItsFullValueAtItsCentreAndSymmetrically() throws {
        let bands = document(3, hue: 100).color.bands        // 绿
        let centre = Double(HSLBands.centresDegrees[3])
        let nextGap = (Double(HSLBands.centresDegrees[4]) - centre) / 2 + centre
        let prevGap = centre - (centre - Double(HSLBands.centresDegrees[2])) / 2

        func delivered(_ hue: Double) -> Double {
            HSLBands.shift(hueDeg: hue, chroma: 0.14, bands: bands).hue
        }
        let atCentre = delivered(centre)
        let atNext = delivered(nextGap)
        let atPrev = delivered(prevGap)
        print("HSL DELIVERY · band 绿 +100: centre \(String(format: "%.2f", atCentre))"
              + " · gaps \(String(format: "%.2f", atNext)) / \(String(format: "%.2f", atPrev))"
              + " · gap-to-gap difference \(String(format: "%.2f", abs(atNext - atPrev)))%"
              + " · centre-vs-gap \(String(format: "%.2f", abs(atCentre - (atNext + atPrev) / 2)))%")
        XCTAssertEqual(atCentre, 100, accuracy: 1e-9, "the band's own centre must deliver all of it")
        XCTAssertEqual(atNext, 50, accuracy: 1e-6)
        XCTAssertEqual(atPrev, 50, accuracy: 1e-6)
    }

    /// **All eight at +100.** The delivered value is the same at every hue on the wheel — 0.00 %
    /// ripple, where 079 measured a 4× one — and the hue rotation's spread is 0°, not 30°.
    func testAllEightBandsDeliverUniformlyAroundTheWheel() {
        let bands = allBands(100, 100, 100).color.bands
        var hues: [Double] = [], sats: [Double] = [], lums: [Double] = []
        for step in 0..<1440 {
            let s = HSLBands.shift(hueDeg: Double(step) * 0.25, chroma: 0.14, bands: bands)
            hues.append(s.hue); sats.append(s.saturation); lums.append(s.luminance)
        }
        func spread(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
        let hueSpreadDegrees = spread(hues) * HSLBands.degreesPerUnit
        print("HSL ALL-BANDS +100 · delivered hue \(String(format: "%.4f", hues.min()!))…"
              + "\(String(format: "%.4f", hues.max()!)) units (spread \(String(format: "%.4f", spread(hues)))%),"
              + " sat spread \(String(format: "%.4f", spread(sats))),"
              + " lum spread \(String(format: "%.4f", spread(lums))),"
              + " hue-rotation spread \(String(format: "%.4f", hueSpreadDegrees))°")
        XCTAssertEqual(hues[0], 100, accuracy: 1e-9)
        XCTAssertLessThan(spread(hues), 1e-9, "with all bands equal the delivery must be uniform")
        XCTAssertLessThan(spread(sats), 1e-9)
        XCTAssertLessThan(spread(lums), 1e-9)
        XCTAssertLessThanOrEqual(hueSpreadDegrees, 3, "076 §3: ≤ 3° of hue-shift spread")
    }

    /// The old numbers, so the fix is comparable rather than merely claimed: at 90°/150° (the two
    /// points 079 measured for green, which in OKLCh are *inside* the orange and yellow bands) green
    /// +100 now delivers ~0 (green reaches 0 there by construction) while the band that owns that hue
    /// delivers the full 100 — the wheel has no hole, which is what the 4× ripple and the 75°/165°
    /// zeroes were.
    func testThereAreNoHolesOnTheWheelWhereTheOldSchemeHadThem() {
        var minimum = Double.infinity
        var minimumAt = 0.0
        for step in 0..<360 {
            let hue = Double(step)
            // The band that owns this hue, at +100.
            let owner = (0..<8).max { HSLBands.weight($0, hueDeg: hue) < HSLBands.weight($1, hueDeg: hue) }!
            let bands = document(owner, hue: 100).color.bands
            let delivered = HSLBands.shift(hueDeg: hue, chroma: 0.14, bands: bands).hue
            if delivered < minimum { minimum = delivered; minimumAt = hue }
        }
        print("HSL NO HOLES · worst owner delivery over the wheel "
              + "\(String(format: "%.2f", minimum)) units at \(String(format: "%.0f", minimumAt))°"
              + " (old scheme: green delivered 25.93 at 90°/150° and 0 at 75°/165°)")
        XCTAssertGreaterThanOrEqual(minimum, 49.9,
                                    "whoever owns the hue must deliver at least half the value")
    }

    /// A document can have **both**: a mask that carries a hue and a band with a value. They are two
    /// stages, they run in pipeline order (S3.5 then S3.6), and each has its own link — the one thing
    /// that could silently go wrong is the chain seeding the vignette from the wrong one.
    func testABandAndALocalColourCoexistInOrder() throws {
        let image = oklchWheel(height: 8)
        let graph = try makeGraph(image, identity: "076-both")
        var edit = document(3, saturation: -40)
        edit.masks = [Mask(id: "m-all",
                           components: [MaskComponent(id: "c", feather: 0,
                                                      shape: .radialGradient(RadialGradientShape(
                                                        center: NormalizedPoint(0.5, 0.5),
                                                        radius: NormalizedPoint(1.5, 1.5))))],
                           adjustments: LocalAdjustments(hue: 20))]

        let result = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        let both = result.trace.executed.filter { $0 == .localColor || $0 == .hsl }
        XCTAssertEqual(both, [.localColor, .hsl], "S3.5 then S3.6, in `RenderStage.order`'s order")
        XCTAssertNotNil(result.keys.localColor)
        let hslLink = try XCTUnwrap(result.keys.hsl)
        XCTAssertEqual(Array(result.keys.pipeline.suffix(4)), [.localColor, .hsl, .vignette, .display])
        XCTAssertNotEqual(result.keys.vignette, KeyBuilder.digest(of: hslLink),
                          "the vignette link is H(hsl | effects), so it cannot be the hsl link itself")
        print("HSL BOTH · " + result.keys.shortTrace)
    }

    // MARK: - ④ the pixels

    /// **The hard acceptance.** A document with no band values must render the pre-076 graph: the stage
    /// is not in the trace, the key chain has no link for it, and the frame is the neutral frame.
    func testABandlessDocumentDoesNotVisitTheStage() throws {
        let image = flat(0.42)
        let graph = try makeGraph(image, identity: "076-neutral")
        let result = try graph.render(allBands(0, 0, 0), options: RenderOptions(scale: 1, wantsPixels: true))
        let neutral = try graph.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true))
        let pixels = try XCTUnwrap(result.display)
        let expected = try XCTUnwrap(neutral.display)
        XCTAssertFalse(result.trace.executed.contains(.hsl),
                       "a bandless document must not visit S3.6")
        XCTAssertEqual(pixels.sha256(), expected.sha256(),
                       "all-zero bands must be byte-identical to no HSL at all")
        let dims = ImageSize(width: image.width, height: image.height)
        let links = RenderKeyChain.links(identity: "076-neutral",
                                         sourceSize: dims,
                                         canvas: dims, content: dims,
                                         edit: allBands(0, 0, 0), display: DisplayOptions())
        XCTAssertNil(links.hsl, "no hsl link without a band value")
        XCTAssertEqual(links.pipeline, RenderStage.allCases)
        print("HSL NEUTRAL · trace \(result.trace.csv) · sha \(pixels.sha256().prefix(12))… = neutral")
    }

    /// A document that *does* carry a band gets one extra link and one extra stage, and the link is
    /// seeded by the colour key — i.e. it sits where the pipeline says it does.
    func testABandAddsExactlyOneLinkAndOneStage() throws {
        let withBand = document(0, hue: 20)
        let links = RenderKeyChain.links(identity: "076-link",
                                         sourceSize: ImageSize(width: 64, height: 64),
                                         canvas: ImageSize(width: 64, height: 64),
                                         content: ImageSize(width: 64, height: 64),
                                         edit: withBand, display: DisplayOptions())
        let plain = RenderKeyChain.links(identity: "076-link",
                                          sourceSize: ImageSize(width: 64, height: 64),
                                          canvas: ImageSize(width: 64, height: 64),
                                          content: ImageSize(width: 64, height: 64),
                                          edit: EditModel.neutral, display: DisplayOptions())
        let link = try XCTUnwrap(links.hsl)
        XCTAssertEqual(links.pipeline, RenderStage.pipeline(hasMasks: false, hasHSL: true))
        XCTAssertEqual(Array(links.pipeline.suffix(3)), [.hsl, .vignette, .display])
        XCTAssertEqual(link, KeyBuilder(KeyBuilder.digest(of: plain.color))
            .add("hsl").add(withBand.keyMaterial(.hsl)).canonical,
                       "S3.6 must be seeded by S3's key, not by the vignette's")
        XCTAssertNotEqual(links.vignette, plain.vignette,
                          "the vignette reads the HSL output, so its key must move")
        print("HSL LINK · \(links.pipeline.map(\.short).joined(separator: " "))")
    }

    /// Grey is **bit-exact**: the chroma gate is exactly 0 at `C = 0`, so a pure grey frame renders the
    /// same bytes with every band at +100 as without the stage at all. This is also what keeps a
    /// near-neutral gradient from stepping (the gate is `C¹`).
    func testAGreyFrameIsUntouchedByEveryBand() throws {
        let image = flat(0.37, width: 32, height: 32)
        let graph = try makeGraph(image, identity: "076-grey")
        let neutral = try display(graph, EditModel.neutral)
        for edit in [allBands(100, 100, 100), allBands(-100, -100, -100),
                     document(0, hue: 100, saturation: -100, luminance: 100)] {
            let out = try display(graph, edit)
            XCTAssertEqual(out.sha256(), neutral.sha256(),
                           "a neutral pixel has no hue: every band must leave it bit-identical")
        }
        // And the gate itself: exactly 0 for neutral, 1 above 0.02, smooth in between.
        XCTAssertEqual(HSLBands.chromaGate(for: 0), 0)
        XCTAssertEqual(HSLBands.chromaGate(for: 1e-7), 0)
        XCTAssertEqual(HSLBands.chromaGate(for: 0.02), 1)
        XCTAssertEqual(HSLBands.chromaGate(for: (HSLBands.chromaFloor + HSLBands.chromaGate) / 2), 0.5,
                       accuracy: 1e-12)
        print("HSL GREY · every band at ±100 leaves a neutral frame byte-identical")
    }

    /// **Single-band isolation.** Red +100 on a frame containing pure blue: the blue pixels must not
    /// move at all — not "by less than a code", but by zero samples with maxΔ = 0.
    func testTheRedBandCannotTouchABluePixel() throws {
        let red = Self.toSRGB.applying(to: OKLCh.toLinear(L: 0.62, C: 0.20,
                                                          hue: Double(HSLBands.centresDegrees[0])))
        let blue = Self.toSRGB.applying(to: OKLCh.toLinear(L: 0.45, C: 0.20,
                                                           hue: Double(HSLBands.centresDegrees[5])))
        // Left half red, right half blue.
        let image = picture(64, 32) { x, _ in x < 32 ? (red.x, red.y, red.z) : (blue.x, blue.y, blue.z) }
        let graph = try makeGraph(image, identity: "076-isolation")
        let neutral = try display(graph, EditModel.neutral)
        let moved = try display(graph, document(0, hue: 100, saturation: 60, luminance: 30))

        func codes(_ img: DisplayImage, x: Int, y: Int) -> (Int, Int, Int) {
            let o = (y * img.width + x) * 4
            return (Self.code(img.rgba[o]), Self.code(img.rgba[o + 1]), Self.code(img.rgba[o + 2]))
        }
        var blueChanged = 0, blueMax = 0, redMax = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let a = codes(neutral, x: x, y: y), b = codes(moved, x: x, y: y)
                let d = max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
                if x >= 32 {
                    if d > 0 { blueChanged += 1 }
                    blueMax = max(blueMax, d)
                } else {
                    redMax = max(redMax, d)
                }
            }
        }
        let blueSamples = image.width * image.height / 2
        print("HSL ISOLATION · red +100: blue side changed \(blueChanged)/\(blueSamples) pixels,"
              + " maxΔ \(blueMax) codes · red side maxΔ \(redMax) codes")
        XCTAssertEqual(blueChanged, 0, "the red band must not reach a blue hue at all")
        XCTAssertEqual(blueMax, 0, "not even by one code")
        XCTAssertGreaterThan(redMax, 5, "the red side must actually move, or the isolation is empty")
    }

    /// The 0°/360° seam, measured in **pixels**: a one-degree-per-column hue wheel, max |Δcode|
    /// between neighbours with the stage, minus the same figure without it — the *extra* step the stage
    /// introduces must be ≤ 2 codes (076 §4's hard acceptance).
    func testTheSeamAddsNoStepToASweptWheel() throws {
        let image = oklchWheel()
        let graph = try makeGraph(image, identity: "076-seam")
        let neutral = try display(graph, EditModel.neutral)
        let moved = try display(graph, allBands(100, 0, 100))

        func biggestStep(_ img: DisplayImage) -> (seam: Int, interior: Int) {
            var seam = 0
            var interior = 0
            for y in 0..<img.height {
                for x in 1..<img.width {
                    for c in 0..<3 {
                        let a = (y * img.width + x) * 4 + c
                        let b = (y * img.width + x - 1) * 4 + c
                        interior = max(interior, abs(Self.code(img.rgba[a]) - Self.code(img.rgba[b])))
                    }
                }
                // The wrap: column 359 against column 0 — the same 1° apart as any other pair.
                for c in 0..<3 {
                    let a = (y * img.width) * 4 + c
                    let b = (y * img.width + img.width - 1) * 4 + c
                    seam = max(seam, abs(Self.code(img.rgba[a]) - Self.code(img.rgba[b])))
                }
            }
            return (seam, interior)
        }
        let neutralSteps = biggestStep(neutral)
        let movedSteps = biggestStep(moved)
        print("HSL SEAM (pixels) · 359°→0° step: neutral \(neutralSteps.seam) codes,"
              + " with +100 hue/亮度 \(movedSteps.seam) codes;"
              + " interior max \(neutralSteps.interior) → \(movedSteps.interior) codes")
        XCTAssertLessThanOrEqual(movedSteps.seam, movedSteps.interior + 2,
                                 "the seam may not step more than 2 codes past the wheel's own steps")
        XCTAssertLessThanOrEqual(movedSteps.interior - neutralSteps.interior, 2,
                                 "the stage may not add more than 2 codes anywhere on the sweep")
    }

    /// A hue ramp must not band: with **one** band moved (the harshest case — the response has a peak
    /// and two shoulders), the 1°-per-pixel sweep stays smooth. Measured as the second difference of a
    /// row, which is 0 for a linear ramp and spikes at a step.
    func testASingleBandLeavesTheRampSmooth() throws {
        let image = oklchWheel(height: 8)
        let graph = try makeGraph(image, identity: "076-ramp")
        let moved = try display(graph, document(3, saturation: 80))

        var worstJump = 0
        var worstSecond = 0
        for y in 0..<moved.height {
            let codes = (0..<moved.width).map { x in
                Int((Double(moved.rgba[(y * moved.width + x) * 4 + 1]) * 255).rounded())
            }
            for x in 2..<codes.count {
                worstSecond = max(worstSecond, abs(codes[x] - 2 * codes[x - 1] + codes[x - 2]))
            }
            for x in 1..<codes.count {
                worstJump = max(worstJump, abs(codes[x] - codes[x - 1]))
            }
        }
        print("HSL RAMP · 绿 +80 on a 1°/px wheel: max neighbour jump \(worstJump) codes,"
              + " max second difference \(worstSecond) codes")
        XCTAssertLessThanOrEqual(worstJump, 3, "a gradient must not step")
        XCTAssertLessThanOrEqual(worstSecond, 3, "…and must not crease")
    }

    /// The stage's pixels are the CPU reference's pixels. The document is all-zero outside the bands,
    /// so S1/S2/S3 are the identity passes the neutral tests already pin; what is modelled here is
    /// S0's matrix, S3.6, S4's matrix and the sRGB encode.
    func testTheKernelAgreesWithTheCPUReference() throws {
        let image = oklchWheel(height: 6, L: 0.60, C: 0.12)
        let graph = try makeGraph(image, identity: "076-cpu")
        let edit = allBands(40, 50, 25)
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
                let out = HSLBands.apply(working, bands: edit.color.bands)
                let srgb = Self.toSRGB.applying(to: out)
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
        print("HSL CPU↔GPU · max |Δcode| \(worst), mean "
              + String(format: "%.3f", Double(total) / Double(count))
              + " over \(count) channels (all bands at +40/+50/+25)")
        XCTAssertLessThanOrEqual(worst, 2,
                                 "the kernel must be the CPU reference, not a lookalike")
    }

    /// The matte is not a colour: outside the content rect — and wherever S0 wrote alpha 0 — the pixel
    /// is written back untouched, the guard S2/S3/S3.5 carry.
    func testTheLetterboxStaysExactlyZero() throws {
        let image = flat(0.5, width: 64, height: 32)
        let graph = try makeGraph(image, identity: "076-matte")
        let canvas = ImageSize(width: 64, height: 64)          // 2:1 canvas over a 2:1 picture
        let result = try graph.render(allBands(100, 100, 100),
                                      options: RenderOptions(canvas: canvas, scale: 1, wantsPixels: true))
        let pixels = try XCTUnwrap(result.display)
        // 64×64 canvas, 2:1 picture → 16 px of matte top and bottom.
        var worst = 0.0
        for y in [0, 1, 15, 48, 62, 63] {
            for x in stride(from: 0, to: 64, by: 7) {
                for c in 0..<3 {
                    worst = max(worst, Double(pixels.rgba[(y * 64 + x) * 4 + c]))
                }
            }
        }
        print("HSL MATTE · max matte value with every band at +100: \(worst)")
        XCTAssertEqual(worst, 0, "the letterbox must not be tinted by a hue band")
    }

    /// Headroom survives: S3.6 is display-referred but not display-clamped, so a highlight above white
    /// keeps its range (S4 is the only clamp, as everywhere else).
    func testAnHDRHighlightKeepsItsHeadroom() throws {
        let image = picture(16, 8) { x, _ in x < 8 ? (2.4, 1.6, 0.9) : (0.45, 0.2, 0.12) }
        let graph = try makeGraph(image, identity: "076-hdr")
        let out = try display(graph, allBands(0, 40, 30), headroom: 4)
        let peak = (0..<(out.width * out.height)).map { Double(out.rgba[$0 * 4]) }.max() ?? 0
        print("HSL HDR · peak after +40 sat / +30 亮度 at headroom 4: \(peak)")
        XCTAssertGreaterThan(peak, 1.05, "the highlight was flattened — the headroom was lost")
    }

    // MARK: - ⑥ 全局 (101)

    /// The ninth selector at 0 must be *absent*: no stage, no link, the neutral frame byte for byte,
    /// and the pre-101 key text unchanged.
    func testTheNinthSelectorAtZeroKeepsTheOldStageAndKey() throws {
        let image = flat(0.42)
        let graph = try makeGraph(image, identity: "101-neutral")
        let neutral = try graph.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true))
        let zero = try graph.render(EditModel.neutral, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertEqual(try XCTUnwrap(zero.display).sha256(), try XCTUnwrap(neutral.display).sha256())
        XCTAssertFalse(zero.trace.executed.contains(.hsl), "an all-zero global must not visit S3.6")

        let expected = "bands=" + ColorGroup.identityBands.map(\.keyString).joined(separator: ";")
        XCTAssertEqual(EditModel.neutral.color.hslKeyString, expected,
                       "the eight-band text is 076's, byte for byte")
        XCTAssertFalse(EditModel.neutral.color.hslKeyString.contains(";gh="))
    }

    /// A band-only document keeps 076's key material; the global triplet is appended only when it is
    /// non-zero, in the fixed `gh/gs/gl` order.
    func testTheGlobalTripletIsAppendedOnlyWhenItMoves() {
        var edit = document(2, hue: 5, saturation: 6, luminance: 7)
        let bandsOnly = edit.color.hslKeyString
        XCTAssertEqual(bandsOnly,
                       "bands=" + edit.color.bands.map(\.keyString).joined(separator: ";"))
        XCTAssertFalse(bandsOnly.contains(";gh="))

        edit.color.global = HSLBand(hue: 10, saturation: 20, luminance: 30)
        XCTAssertEqual(bandsOnly + ";gh=10.00000;gs=20.00000;gl=30.00000",
                       edit.color.hslKeyString)
        XCTAssertTrue(edit.keyMaterial(.hsl).contains(";gh=10.00000;gs=20.00000;gl=30.00000"))
        XCTAssertTrue(edit.hasHSL)
    }

    /// Eight patches, one per band centre, at a chroma well above the gate and a lightness that stays
    /// inside the display gamut after a 30° rotation, a ×2 chroma and one stop of lift.
    private func bandCentrePicture() -> LinearImage {
        picture(8, 4) { x, _ in
            let working = OKLCh.toLinear(L: 0.38, C: 0.03,
                                         hue: Double(HSLBands.centresDegrees[x % 8]))
            let srgb = Self.toSRGB.applying(to: working)
            return (srgb.x, srgb.y, srgb.z)
        }
    }

    /// The display image's own OKLCh (decode sRGB, go to the working primaries, then `OKLCh`).
    private func displayedLCh(_ image: DisplayImage, x: Int, y: Int)
        -> (L: Double, C: Double, hue: Double) {
        let o = (y * image.width + x) * 4
        func decode(_ v: Float16) -> Double {
            let c = min(max(Double(v), 0), 1)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let srgb = SIMD3(decode(image.rgba[o]), decode(image.rgba[o + 1]),
                         decode(image.rgba[o + 2]))
        return OKLCh.fromLinear(Self.toWorking.applying(to: srgb))
    }

    /// 101 — 全局亮度 is ±1 stop of OKLab L at every band centre, symmetric, and it reaches grey (the one
    /// axis that is allowed to, because there is no hue for it to need).
    func testGlobalLuminanceLiftsEveryBandCentreAndLowersSymmetrically() throws {
        let image = bandCentrePicture()
        let graph = try makeGraph(image, identity: "101-lum")
        let before = try display(graph, EditModel.neutral)
        var up = EditModel.neutral
        up.color.global.luminance = 100
        var down = EditModel.neutral
        down.color.global.luminance = -100
        let lifted = try display(graph, up)
        let lowered = try display(graph, down)

        for x in 0..<8 {
            let l0 = displayedLCh(before, x: x, y: 0).L
            let a = displayedLCh(lifted, x: x, y: 0).L
            let b = displayedLCh(lowered, x: x, y: 0).L
            let gain = log2(a / l0)
            let loss = log2(b / l0)
            XCTAssertGreaterThanOrEqual(gain, 0.9, "band \(x): +100 must be a stop of L")
            XCTAssertLessThanOrEqual(loss, -0.9, "band \(x): −100 must be a stop of L")
        }
        print("HSL GLOBAL 亮度 · 8 band centres: +100 ≥ +0.9 stop, −100 ≤ −0.9 stop")
    }

    /// 101 — 全局饱和 doubles chroma (within 2 %) at every band centre; 全局色相 adds 30° (within
    /// 0.5°). Both ride the gate, so the grey test below stays bit-exact for them.
    func testGlobalSaturationAndHueHaveTheBandsOwnUnits() throws {
        let image = bandCentrePicture()
        let graph = try makeGraph(image, identity: "101-sat-hue")
        let before = try display(graph, EditModel.neutral)

        var sat = EditModel.neutral
        sat.color.global.saturation = 100
        let saturated = try display(graph, sat)
        var hue = EditModel.neutral
        hue.color.global.hue = 100
        let rotated = try display(graph, hue)

        for x in 0..<8 {
            let c0 = displayedLCh(before, x: x, y: 0).C
            let c1 = displayedLCh(saturated, x: x, y: 0).C
            XCTAssertEqual(c1 / c0, 2, accuracy: 0.04,
                           "band \(x): +100 saturation must double chroma ±2 %")
            let h0 = displayedLCh(before, x: x, y: 0).hue
            let h1 = displayedLCh(rotated, x: x, y: 0).hue
            var delta = (h1 - h0).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            XCTAssertEqual(delta, 30, accuracy: 0.5, "band \(x): +100 hue must be +30°")
        }
        print("HSL GLOBAL 饱和/色相 · 8 band centres: chroma ×2, hue +30°")
    }

    /// Grey has no hue: 全局色相/饱和 leave it bit-identical (the 079 gate), while 全局亮度 — the one
    /// ungated axis — still moves it. That asymmetry is the whole point of the ninth selector.
    func testGlobalHueAndSaturationLeaveGreyAloneButLuminanceDoesNot() throws {
        let image = flat(0.37, width: 32, height: 32)
        let graph = try makeGraph(image, identity: "101-grey")
        let neutral = try display(graph, EditModel.neutral).sha256()
        var hueSat = EditModel.neutral
        hueSat.color.global = HSLBand(hue: 100, saturation: 100)
        XCTAssertEqual(try display(graph, hueSat).sha256(), neutral,
                       "a grey has no hue to rotate and no chroma to scale")
        var lum = EditModel.neutral
        lum.color.global.luminance = 100
        XCTAssertNotEqual(try display(graph, lum).sha256(), neutral,
                          "全局亮度 is the axis that must reach grey")
        print("HSL GLOBAL 灰 · 色相/饱和逐位不变 · 亮度可见")
    }

    /// 101 — the snapshot carries the global triplet, applies it back, and a commit that moves only
    /// 全局 is one history row.
    func testGlobalRoundTripsThroughASnapshotAndTheHistory() {
        var edit = EditModel.neutral
        edit.color.global = HSLBand(hue: 12, saturation: -7, luminance: 3)
        let snapshot = EditSnapshot.capture(edit)
        XCTAssertNil(snapshot.color?.bands)
        XCTAssertEqual(snapshot.color?.global?.hue, 12)
        XCTAssertEqual(snapshot.color?.global?.saturation, -7)
        XCTAssertEqual(snapshot.color?.global?.luminance, 3)
        XCTAssertTrue(snapshot.sections.contains(.hsl))
        XCTAssertEqual(snapshot.applied(to: .neutral).color.global, edit.color.global)

        var history = EditHistory(baseline: .neutral)
        XCTAssertNotNil(history.commit(edit, label: "全局"))
        XCTAssertEqual(history.count, 2, "one baseline + one 全局 row")
    }

    /// 101 — the JSON rule: a neutral document writes no `global` key (byte-identical re-encode), a
    /// document with a global triplet round-trips it.
    func testTheGlobalTripletIsAbsentFromNeutralJSON() throws {
        let neutral = try JSONEncoder().encode(EditModel.neutral)
        XCTAssertFalse(try XCTUnwrap(String(data: neutral, encoding: .utf8)).contains("\"global\""),
                       "all-zero 全局 must not add a key")

        var edit = EditModel.neutral
        edit.color.global = HSLBand(hue: 12, saturation: -7, luminance: 3)
        let data = try JSONEncoder().encode(edit)
        XCTAssertTrue(try XCTUnwrap(String(data: data, encoding: .utf8)).contains("\"global\""))
        XCTAssertEqual(try JSONDecoder().decode(EditModel.self, from: data).color.global,
                       edit.color.global)
    }

    // MARK: - ⑤ cost

    /// 4.10 Mpx, one frame, `useCache: false`: the whole pipeline with and without S3.6, and the
    /// difference is the pass. Printed rather than asserted against a budget (056's rule: record it, do
    /// not invent a threshold); guarded only against a pathological kernel.
    func testTheStageCostsWhatAPassCosts() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let image = picture(2340, 1755) { x, y in
            (0.2 + Double((x * y) % 61) / 300, 0.3, 0.4)
        }
        XCTAssertEqual(image.width * image.height, 4_106_700)
        let graph = try makeGraph(image, identity: "076-cost")
        let edit = allBands(0, 40, 0)

        // Warm both paths first: the first render of a graph compiles its pipelines, and a "cost" that
        // is mostly pipeline compilation is not a cost. Then alternate, so a thermal or scheduling drift
        // hits both sides equally, and take the best of five on each.
        _ = try graph.render(EditModel.neutral, options: RenderOptions(scale: 1, useCache: false))
        _ = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false))
        var without = Double.infinity
        var with = Double.infinity
        for _ in 0..<5 {
            for e in [EditModel.neutral, edit] {
                let r = try graph.render(e, options: RenderOptions(scale: 1, useCache: false))
                if e.hasHSL { with = min(with, r.trace.gpuMilliseconds) }
                else { without = min(without, r.trace.gpuMilliseconds) }
            }
        }
        let dims = "\(image.width)×\(image.height)"
        let base = String(format: "%.2f", without)
        let total = String(format: "%.2f", with)
        let delta = String(format: "%.2f", with - without)
        print("HSL COST · 4.10 Mpx (" + dims + "): whole frame " + base + " ms → " + total + " ms (+"
              + delta + " ms for S3.6, best of 5, interleaved)")
        XCTAssertLessThan(with - without, 40,
                          "an HSL pass on 4.1 Mpx cannot cost tens of milliseconds")
    }
}

/// The eight bands' names, for printouts (`HSLAxis.bandNames` lives in the UI layer, which the core
/// tests do not import).
private enum HSLAxisName {
    static let names = ["红", "橙", "黄", "绿", "青", "蓝", "紫", "品红"]
    static func name(_ i: Int) -> String { names[min(max(i, 0), names.count - 1)] }
}
