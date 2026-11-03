import XCTest
import simd
import PhotonsCore

/// 285 — **点颜色取样范围**: the OKLCh platform + shoulder, the relative chroma tolerance, the pale
/// gate in OKLab C, the wrap, and the overlap rules (input-domain weights, partition of unity,
/// sample-spacing shoulder cap).
///
/// These are model-level pins: every number here is the number the kernel consumes, because
/// `RenderGraph` uploads these same computed properties (`huePlateau`, `hueShoulder`,
/// `chromaTolerance`, `lumaPlateau`, `featherScale`) and `PointColorIsolationTests` proves the kernel
/// agrees with `PointColorSet.apply`.
final class PointColorRangeTests: XCTestCase {

    // MARK: - fixtures

    /// A swatch sampled from a working-primaries OKLCh colour (goes through the stored YUV, exactly
    /// like the dropper), so `sampleLightness/Chroma/Hue` are the real derived values.
    private func swatch(L: Double, C: Double, hue: Double,
                        range: Double = PointColor.defaultRange,
                        feather: Double = PointColor.defaultFeather) -> PointColor {
        let working = OKLCh.toLinear(L: L, C: C, hue: hue)
        let yuv = PointColor.yuv(fromLinearWorking: working)
        return PointColor(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z,
                          range: range, feather: feather)
    }

    private func weight(_ s: PointColor, dHue: Double = 0, dChroma: Double = 0,
                        dL: Double = 0) -> Double {
        s.weight(l: s.sampleLightness + dL,
                 c: s.sampleChroma + dChroma,
                 hue: s.sampleHue + dHue)
    }

    // MARK: - 1. hue platform / shoulder / zero

    func testHueIsFullThroughTenDegreesAndExactlyZeroAtFifteen() {
        let s = swatch(L: 0.72, C: 0.12, hue: 120)
        XCTAssertEqual(weight(s, dHue: 10), 1, accuracy: 1e-12)
        XCTAssertEqual(weight(s, dHue: 12.5), 0.5, accuracy: 0.02,
                       "12.5° is halfway through the 5° shoulder")
        XCTAssertEqual(weight(s, dHue: 15), 0, "15° is the user's minimum colour spacing")
        XCTAssertEqual(weight(s, dHue: -15), 0)
        XCTAssertEqual(weight(s, dHue: 175), 0)
        // Wrapped: −170° is the same 190° as +190°, i.e. 170° away.
        XCTAssertEqual(weight(s, dHue: 170), weight(s, dHue: -190), accuracy: 1e-12)
        print(String(format: "RANGE HUE · w(10°)=%.6f w(12.5°)=%.6f w(15°)=%.6f",
                     weight(s, dHue: 10), weight(s, dHue: 12.5), weight(s, dHue: 15)))
    }

    func testAngularDistanceWrapsAcrossZero() {
        XCTAssertEqual(PointColor.angularDistance(10, 350), 20, accuracy: 1e-12)
        XCTAssertEqual(PointColor.angularDistance(350, 10), -20, accuracy: 1e-12)
        XCTAssertEqual(abs(PointColor.angularDistance(0, 180)), 180, accuracy: 1e-12)
        XCTAssertEqual(PointColor.angularDistance(359, 1), -2, accuracy: 1e-12)
        XCTAssertEqual(PointColor.angularDistance(1, 359), 2, accuracy: 1e-12)
        XCTAssertEqual(PointColor.angularDistance(720 + 30, 30), 0, accuracy: 1e-12)
        print("RANGE WRAP · 350↔10 = -20°, 359↔1 = -2°, 30↔390 = 0°")
    }

    // MARK: - 2. shadow face vs another material

    func testAShadingFaceIsFullWeightAndAnotherMaterialIsZero() {
        let s = swatch(L: 0.72, C: 0.12, hue: 210)
        XCTAssertEqual(weight(s, dL: 0.06), 1, accuracy: 1e-12,
                       "±0.06 L is a shading face and must be fully selected")
        XCTAssertEqual(weight(s, dL: -0.06), 1, accuracy: 1e-12)
        XCTAssertEqual(weight(s, dL: 0.10), 0.5, accuracy: 0.03)
        XCTAssertEqual(weight(s, dL: 0.13), 0,
                       "beyond 0.12 L is a different material")
        print(String(format: "RANGE L · w(±0.06)=%.6f w(0.10)=%.6f w(0.13)=%.6f",
                     weight(s, dL: 0.06), weight(s, dL: 0.10), weight(s, dL: 0.13)))
    }

    // MARK: - 3. the pale sample

    func testAPaleC006SampleDoesNotReachFortyDegrees() {
        let s = swatch(L: 0.72, C: 0.06, hue: 60)
        XCTAssertEqual(weight(s, dHue: 40), 0,
                       "C=0.06 must not inherit the wide angle a YUV box gave it")
        XCTAssertEqual(weight(s, dHue: 10), 1, accuracy: 1e-12)
        print(String(format: "RANGE PALE · C_sample=%.4f tol=%.4f w(40°)=%.6f",
                     s.sampleChroma, s.chromaTolerance, weight(s, dHue: 40)))
    }

    // MARK: - 4. 范围 120

    func testRangeOneTwentyStopsAtSixtyDegrees() {
        let s = swatch(L: 0.72, C: 0.12, hue: 300, range: 120)
        XCTAssertEqual(s.huePlateau, 40, accuracy: 1e-12)
        XCTAssertEqual(s.hueShoulder, 20, accuracy: 1e-12)
        XCTAssertGreaterThan(weight(s, dHue: 55), 0)
        XCTAssertEqual(weight(s, dHue: 60), 0,
                       "range 120 is 40° platform + 20° shoulder, not the whole circle")
        XCTAssertEqual(weight(s, dHue: 90), 0)
        print(String(format: "RANGE 120 · platform %.1f° shoulder %.1f° w(55°)=%.3f w(60°)=%.6f",
                     s.huePlateau, s.hueShoulder,
                     weight(s, dHue: 55), weight(s, dHue: 60)))
    }

    // MARK: - 5. chroma is relative, not absolute

    func testChromaToleranceIsThirtyPercentOfTheSample() {
        let saturated = swatch(L: 0.72, C: 0.12, hue: 20)
        XCTAssertEqual(saturated.chromaTolerance, 0.036, accuracy: 1e-6)
        XCTAssertEqual(weight(saturated, dChroma: 0.036), 1, accuracy: 1e-12)
        XCTAssertEqual(weight(saturated, dChroma: 0.054), 0, accuracy: 1e-12)
        XCTAssertEqual(weight(saturated, dChroma: 0.06), 0)

        let pale = swatch(L: 0.72, C: 0.06, hue: 20)
        XCTAssertEqual(pale.chromaTolerance, 0.02, accuracy: 1e-6,
                       "the 0.02 floor keeps a pale sample selectable")
        XCTAssertEqual(weight(pale, dChroma: 0.02), 1, accuracy: 1e-12)
        XCTAssertEqual(weight(pale, dChroma: 0.03), 0, accuracy: 1e-12)
        print(String(format: "RANGE CHROMA · C=0.12 tol=%.4f; C=0.06 tol=%.4f",
                     saturated.chromaTolerance, pale.chromaTolerance))
    }

    // MARK: - 6. 过渡 only moves the shoulder

    func testFeatherScalesTheShoulderButNeverThePlatform() {
        let zero = swatch(L: 0.72, C: 0.12, hue: 0, feather: 0)
        XCTAssertEqual(weight(zero, dHue: 10), 1, accuracy: 1e-12)
        XCTAssertEqual(weight(zero, dHue: 10.001), 0, "feather 0 is a hard-edged platform")

        let wide = swatch(L: 0.72, C: 0.12, hue: 0, feather: 60)
        XCTAssertEqual(wide.hueShoulder, 10, accuracy: 1e-12)
        XCTAssertGreaterThan(weight(wide, dHue: 12), 0)
        XCTAssertEqual(weight(wide, dHue: 20), 0, accuracy: 1e-12)
        print(String(format: "RANGE FEATHER · 0 → w(10.001)=0; 60 → shoulder %.1f° w(12)=%.3f",
                     wide.hueShoulder, weight(wide, dHue: 12)))
    }

    // MARK: - 7. overlap: input domain + partition of unity

    func testOverlapSplitsTheMoveInsteadOfDoublingIt() {
        var a = swatch(L: 0.72, C: 0.12, hue: 0)
        var b = swatch(L: 0.72, C: 0.12, hue: 10)
        a.hue = 100                       // +30°
        b.hue = 100
        let set = PointColorSet(swatches: [a, b], active: 0)

        let inputHue = (a.sampleHue + b.sampleHue) / 2
        let input = OKLCh.toLinear(L: 0.72, C: 0.12, hue: inputHue)
        let both = set.apply(input)
        let single = PointColorSet(swatches: [a], active: 0).apply(input)

        let bothHue = OKLCh.fromLinear(both).hue
        let singleHue = OKLCh.fromLinear(single).hue
        XCTAssertEqual(bothHue, singleHue, accuracy: 0.05,
                       "Σw = 2 must divide by 2, not apply two full moves")
        let dE = PointColorDeltaE.deltaE00(encoded(both), encoded(single))
        XCTAssertLessThan(dE, 0.05, "the overlap move equals the single-frame move")
        print(String(format: "RANGE OVERLAP · Δh=%.2f° · both %.2f° vs single %.2f° · ΔE00 %.4f",
                     abs(PointColor.angularDistance(a.sampleHue, b.sampleHue)),
                     bothHue, singleHue, dE))
    }

    func testSwappingTheSwatchOrderDoesNotMoveThePixel() {
        var a = swatch(L: 0.62, C: 0.10, hue: 20)
        a.hue = 60; a.saturation = 40; a.luminance = 20
        var b = swatch(L: 0.62, C: 0.10, hue: 26)
        b.hue = -30; b.saturation = -20; b.luminance = -10

        let inputHue = (a.sampleHue + b.sampleHue) / 2
        let input = OKLCh.toLinear(L: 0.62, C: 0.10, hue: inputHue)
        let forward = PointColorSet(swatches: [a, b], active: 0).apply(input)
        let reverse = PointColorSet(swatches: [b, a], active: 0).apply(input)
        let dE = PointColorDeltaE.deltaE00(encoded(forward), encoded(reverse))
        XCTAssertLessThan(dE, 0.02, "input-domain weights make the array order irrelevant")
        print(String(format: "RANGE ORDER · ΔE00(forward, reverse) = %.6f", dE))
    }

    // MARK: - 8. shoulder cap is sample spacing

    func testTheHueShoulderIsCappedByTheNearestSample() {
        let a = swatch(L: 0.62, C: 0.10, hue: 10)
        let near = swatch(L: 0.62, C: 0.10, hue: 22)
        let far = swatch(L: 0.62, C: 0.10, hue: 80)
        let shoulders = PointColorSet.effectiveHueShoulders(for: [a, near, far])
        // d_min = 12°, platform = 10° ⇒ the shoulder may only be 2°, not 5°.
        XCTAssertEqual(shoulders[0], 2, accuracy: 1e-6)
        XCTAssertEqual(shoulders[1], 2, accuracy: 1e-6)
        XCTAssertEqual(shoulders[2], 5, accuracy: 1e-9,
                       "80° away keeps the card's full 5° shoulder")
        print(String(format: "RANGE CAP · shoulders %.2f/%.2f/%.2f°",
                     shoulders[0], shoulders[1], shoulders[2]))
    }

    func testAOneHundredTwentyDegreeRangeCannotReachTheNeighbour() {
        var a = swatch(L: 0.62, C: 0.10, hue: 0, range: 120)
        var b = swatch(L: 0.62, C: 0.10, hue: 60, range: 120)
        a.hue = 100
        b.hue = -100
        let set = PointColorSet(swatches: [a, b], active: 0)
        // The centre of A is 60° from B, B's zero point: B contributes exactly nothing there.
        let input = OKLCh.toLinear(L: 0.62, C: 0.10, hue: a.sampleHue)
        let out = set.apply(input)
        let onlyA = PointColorSet(swatches: [a], active: 0).apply(input)
        XCTAssertEqual(encoded(out), encoded(onlyA), "the neighbour is outside its 60° zero")
        print("RANGE 120 CAP · B's zero at 60° keeps A's centre to A alone")
    }

    // MARK: - 9. the key names the generation

    func testTheKeyStringCarriesThe285Prefix() {
        let s = swatch(L: 0.72, C: 0.12, hue: 30)
        XCTAssertTrue(s.keyString.hasPrefix("s3.6b/285/|"), s.keyString)
        XCTAssertTrue(s.keyString.contains("sampleY="))
        let set = PointColorSet(swatches: [s], active: 0)
        XCTAssertTrue(set.keyString.contains("s3.6b/285/|"))
        XCTAssertEqual(PointColorSet().keyString, "none")
        print("RANGE KEY · \(s.keyString)")
    }

    // MARK: - helpers

    /// Encode a linear working-primaries colour the way the display image stores it, so ΔE00 sees
    /// the same sRGB codes the user would.
    private func encoded(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let srgb = ColorPrimaries.conversion(from: .working, to: .sRGB).applying(to: rgb)
        func encode(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return SIMD3(encode(srgb.x), encode(srgb.y), encode(srgb.z))
    }
}
