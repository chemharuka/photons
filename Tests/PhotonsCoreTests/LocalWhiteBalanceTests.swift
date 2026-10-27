import XCTest
import Metal
import simd
@testable import PhotonsCore

/// 派单 079 A3 — **the mask's white balance is the global solver's white balance.**
///
/// The defect: `LocalAdjustments.gain` multiplied `LightGroup.whiteBalanceGains`, which divides the
/// 0…255 **display-encoded** black-body colour. A ratio of gamma-encoded channels under-states every
/// ratio — the same measurement `WhiteBalanceSolver`'s own header records (`0.86×` predicted where the
/// decoder delivered `0.63×`) — so one temperature meant two casts depending on whether a mask was
/// drawn: `+30` in a mask moved a grey's R/B by **0.121** where the global solver's `7400 K` moves it by
/// **0.296**, i.e. the mask's cast was **2.4×** too weak (−30: 2.1×). The gain vectors differ by 13.5 %
/// / 14.1 % in R/B; through the tone map the visible difference is 9.1 % / 9.2 %.
///
/// The fix is not a new local number: `LocalAdjustments.gain` now calls
/// `WhiteBalanceSolver.localGain`, which converts the mask's `6500 K + 30 K/unit` units and calls the
/// **same** `WhiteBalanceSolver.gain` the global path is predicted with. One body, one coordinate. This
/// file pins the four acceptance numbers:
///
///   ① the same temperature inside and outside a mask lands on the same R/B — **< 1 %** (0.000 % here,
///      because it is the same function), while the encoded body it replaced is 8.9–10.1 % off at
///      pixel level and 13.5 % at gain level, so the assertion is falsifiable rather than tautological;
///   ② WB all zero is **bit-identical** to no mask (the gain is exactly `(1, 1, 1)`, not `0.9999…`);
///   ③ `±100` does not blow up — the largest channel a mask can ask for is printed and bounded (1.925
///      on blue at 3500 K, 2.246 with the tint at +100 on top of it, and a 0.18 grey comes out at
///      0.4042 on its worst channel — nothing to clip, nothing to rescue);
///   ④ the pass costs **no measurable time** (paired median +0.024 ms over 9 interleaved rounds, spread
///      ±0.31): the kernel's arithmetic is unchanged (three floats per mask), and the 4.10 Mpx dispatch
///      is timed against the old gain vector.
///
/// One honest residual is measured separately (`testTheRemainingDifferenceIsThePrimariesNotTheSolver`):
/// S1.6's gain is diagonal in the **working** primaries while a decoder's is diagonal in the camera's,
/// so the two are not bit-identical operations even now — 3.4 % on a 0.18 grey at +30, against 10.8 %
/// for the body this change removed.
///
/// The counter-proof runs through the **shipped** kernel twice: once with the gain the app now builds,
/// once with the old encoded gain, on the same picture and the same dispatch shape.
final class LocalWhiteBalanceTests: XCTestCase {

    // MARK: - fixtures

    /// A flat grey field: every pixel identical, so a channel ratio read anywhere is a statement about
    /// the gain and not about the picture.
    private func greyImage(_ value: Float, width: Int = 64, height: Int = 64) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            let o = i * 4
            rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
            rgba[o + 2] = Float16(value); rgba[o + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// A crisp disc (`feather = 0`, radius 0.45 of the short edge): the coverage is exactly 1 inside,
    /// so a pixel read from the core is a statement about the arithmetic alone, and the corner is
    /// outside — where the pixel must not move at all.
    private func discMask(temperature: Double = 0, tint: Double = 0,
                          exposure: Double = 0) -> Mask {
        Mask(id: "m-wb",
             components: [MaskComponent(id: "c", feather: 0,
                                        shape: .radialGradient(RadialGradientShape(
                                            center: NormalizedPoint(0.5, 0.5),
                                            radius: NormalizedPoint(0.45, 0.45))))],
             adjustments: LocalAdjustments(amount: 100, exposure: exposure,
                                           temperature: temperature, tint: tint))
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        try XCTUnwrap(graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true)).display)
    }

    /// Offset of the centre pixel in `DisplayImage.rgba`.
    private func centre(_ img: DisplayImage) -> Int {
        ((img.height / 2) * img.width + img.width / 2) * 4
    }

    /// R/B of one pixel — the acceptance's own quantity. Both routes are read at the same coordinate
    /// of the same picture, so the tone map and the display encode cancel out of the comparison.
    private func redOverBlue(_ img: DisplayImage, _ offset: Int) -> Double {
        Double(img.rgba[offset + 2]) > 0 ? Double(img.rgba[offset]) / Double(img.rgba[offset + 2]) : .nan
    }

    /// The global route, expressed where the mask works: S1.6 applies its gain **after** S0's
    /// `sRGB → working` matrix, so the picture a global request would have produced is the source whose
    /// working-space pixels are already `g × v` — i.e. `M⁻¹ · diag(g) · M · source`. (Applying `g` in
    /// the decoded space instead — what a decoder really does — is *not* the same operation: a
    /// camera-space diagonal gain conjugated by the primaries matrix is not diagonal, and that residual
    /// is measured and printed by `testTheRemainingDifferenceIsThePrimariesNotTheSolver`.)
    private func pregained(_ image: LinearImage, by gain: (r: Double, g: Double, b: Double)) -> LinearImage {
        let toWorking = RenderGraph.primariesMatrix(from: ColorPrimaries.decoded,
                                                    to: ColorPrimaries.working)
        let toDecoded = RenderGraph.primariesMatrix(from: ColorPrimaries.working,
                                                    to: ColorPrimaries.decoded)
        let scale = SIMD3<Float>(Float(gain.r), Float(gain.g), Float(gain.b))
        var rgba = image.rgba
        for i in Swift.stride(from: 0, to: rgba.count, by: 4) {
            let v = SIMD4<Float>(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]), 1)
            let working = toWorking * v
            let gained = SIMD4<Float>(working.x * scale.x, working.y * scale.y,
                                      working.z * scale.z, 1)
            let back = toDecoded * gained
            rgba[i] = Float16(back.x)
            rgba[i + 1] = Float16(back.y)
            rgba[i + 2] = Float16(back.z)
        }
        return LinearImage(width: image.width, height: image.height, rgba: rgba,
                           colorSpace: image.colorSpace, decoderVersion: image.decoderVersion)
    }

    /// `g` applied in the **decoded** space (a decoder's own white balance), for the observation test.
    private func pregainedInCameraSpace(_ image: LinearImage,
                                       by gain: (r: Double, g: Double, b: Double)) -> LinearImage {
        var rgba = image.rgba
        for i in Swift.stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = Float16(Double(rgba[i]) * gain.r)
            rgba[i + 1] = Float16(Double(rgba[i + 1]) * gain.g)
            rgba[i + 2] = Float16(Double(rgba[i + 2]) * gain.b)
        }
        return LinearImage(width: image.width, height: image.height, rgba: rgba,
                           colorSpace: image.colorSpace, decoderVersion: image.decoderVersion)
    }

    /// The body `s1_6_local` shipped before 079 A3, i.e. the mask side of the defect, still reachable
    /// through `LightGroup.whiteBalanceGains`. Kept as a call so the counter-proof measures the code
    /// that was really there and not a re-typed impression of it.
    private func encodedGain(units: Double, tint: Double = 0) -> (r: Double, g: Double, b: Double) {
        let g = LightGroup(temperature: WhiteBalanceSolver.localKelvin(units),
                           tint: min(max(tint, -100), 100)).whiteBalanceGains
        return (Double(g.r), Double(g.g), Double(g.b))
    }

    /// The global side of the same request, in the solver's own coordinates.
    private func solverGain(units: Double, tint: Double = 0) -> (r: Double, g: Double, b: Double) {
        WhiteBalanceSolver.gain(temperature: WhiteBalanceSolver.localKelvin(units), tint: tint,
                                reference: WhiteBalanceSolver.localReference)
    }

    /// ④ 进键 — **no new field**, so the document's own key text does not move: `keyString` prints the
    /// same eleven tokens it always did, and a document that has never used a WB slider keeps the key
    /// it had. What *does* move is the **stage** version (`localApply` 2 → 3): the same parameters draw
    /// different pixels now, which is exactly what `StageAlgorithmVersion` exists to say, and it
    /// invalidates the mask stage (and the thumbnails that contain it) without touching the document.
    func testTheKeyTextIsUnchangedWhileTheStageVersionMoves() {
        let a = LocalAdjustments(amount: 100, exposure: 1, temperature: 30, tint: 12,
                                 contrast: 5, highlights: 6, shadows: 7,
                                 whites: 8, blacks: 9, hue: 10, saturation: 11)
        XCTAssertEqual(a.keyString,
                       "amt=100.00000;ev=1.00000;temp=30.00000;tint=12.00000"
                       + ";con=5.00000;hi=6.00000;sh=7.00000;wh=8.00000;bl=9.00000"
                       + ";hue=10.00000;sat=11.00000",
                       "the mask's document key must not gain a token for a derived gain")
        XCTAssertEqual(StageAlgorithmVersion.localApply, 3,
                       "S1.6's pixels changed for the same parameters")
        XCTAssertEqual(StageAlgorithmVersion.version(of: .localApply), 3)
        // And the gain is derived, not stored: decoding a document that carries only the WB pair
        // reproduces the same three numbers.
        let json = Data(#"{"amount":100,"temperature":30,"tint":12}"#.utf8)
        let decoded = try? JSONDecoder().decode(LocalAdjustments.self, from: json)
        XCTAssertEqual(decoded?.gain.r, LocalAdjustments(temperature: 30, tint: 12).gain.r)
        XCTAssertEqual(decoded?.gain.b, LocalAdjustments(temperature: 30, tint: 12).gain.b)
    }

    // MARK: - ① the same number is the same cast

    /// The mask's gain vector *is* the solver's: R/B of a gain triple is the R/B a grey pixel comes
    /// out with, so comparing them here is the acceptance's "same grey block" at its source.
    func testMaskedTemperatureIsTheGlobalSolverGain() {
        var worst = 0.0
        for units in [30.0, -30, 15, 60, -60, 100, -100] {
            let mask = LocalAdjustments(temperature: units).gain
            let global = solverGain(units: units)
            let maskRB = Double(mask.r) / Double(mask.b)
            let globalRB = global.r / global.b
            let difference = abs(maskRB / globalRB - 1)
            worst = max(worst, difference)
            print(String(format: "079 A3 温度 %+.0f (%.0f K): 蒙版 R/B %.6f, 全局 %.6f, 差 %.3f %%",
                         units, WhiteBalanceSolver.localKelvin(units), maskRB, globalRB,
                         difference * 100))
            XCTAssertLessThan(difference, 0.01,
                              "temperature \(units): the mask must apply the solver's gain")
        }
        XCTAssertLessThan(worst, 1e-6, "the two paths are one function — the difference is rounding only")
    }

    /// Tint is 1:1 in `WhiteBalance.tint` units (the document's own coordinate), not the encoded fit's
    /// `Δtint = 2·tint`. Asserted the same way: the mask's gain is `gain(tint:)`.
    func testMaskedTintIsTheGlobalSolverTint() {
        for tint in [25.0, -25, 100, -100] {
            let mask = LocalAdjustments(tint: tint).gain
            let global = solverGain(units: 0, tint: tint)
            XCTAssertEqual(Double(mask.r) / Double(mask.g), global.r / global.g, accuracy: 1e-6,
                           "tint \(tint): R/G")
            XCTAssertEqual(Double(mask.b) / Double(mask.g), global.b / global.g, accuracy: 1e-6,
                           "tint \(tint): B/G")
        }
        // And the encoded body it replaced is a *different number* for the same slider. Its encoded
        // gains (√ts on R,B; 1/ts on G) are the solver's at **twice** the units once squared into
        // linear light — so the old mask read `tint = +100` as a document tint of `+200`, which is
        // past the document's own ±150 range. That is the second meaning this change removes.
        let old = encodedGain(units: 0, tint: 100)
        let doubled = solverGain(units: 0, tint: 200)
        XCTAssertEqual(old.r * old.r, doubled.r, accuracy: 1e-6, "the encoded fit is the linear one at 2×")
        XCTAssertEqual(old.g * old.g, doubled.g, accuracy: 1e-6)
        XCTAssertEqual(old.b * old.b, doubled.b, accuracy: 1e-6)
        let document = solverGain(units: 0, tint: 100)
        let oldRedOverGreen = old.r / old.g
        let newRedOverGreen = document.r / document.g
        print(String(format: "079 A3 色调 +100: 旧编码 R/G %.4f, solver R/G %.4f, 差 %.2f %%",
                     oldRedOverGreen, newRedOverGreen,
                     abs(oldRedOverGreen / newRedOverGreen - 1) * 100))
        // The two are close (√ts ≈ 1 + ts/600 within 1 %), so this is a coordinate change, not a
        // visible jump: an existing document's tint keeps its strength and gains a definition.
        XCTAssertGreaterThan(abs(oldRedOverGreen / newRedOverGreen - 1), 0.01,
                             "the tint coordinate really did move (it is Δ=2t vs Δ=t)")
    }

    /// ① at pixel level, through the shipped graph: a mask at `+30 …` versus the picture whose
    /// working-space pixels already carry the solver's gain. Both go through the same tone map and the
    /// same display encode, and both are read at the same pixel — so the **only** thing left between
    /// them is the mask's own arithmetic, which is what S1.6 is.
    ///
    /// The counter-proof runs the identical measurement with the *encoded* gain (the pre-079 body) and
    /// requires it to miss the same 1 % bar: if it ever passes, this test has stopped measuring.
    func testMaskedWhiteBalanceMatchesTheGlobalRouteOnTheSameGrey() throws {
        for (units, value) in [(30.0, Float(0.18)), (-30.0, Float(0.18)),
                               (30.0, Float(0.05)), (-30.0, Float(0.45))] {
            let image = greyImage(value)
            let graph = try makeGraph(image, identity: "local-wb-parity")
            var edit = EditModel.neutral
            edit.masks = [discMask(temperature: units)]
            let masked = try render(graph, edit)
            let plain = try render(graph, EditModel.neutral)     // no mask at all

            func route(_ gain: (r: Double, g: Double, b: Double), _ label: String) throws -> Double {
                let g = try makeGraph(pregained(image, by: gain), identity: "local-wb-global")
                let img = try render(g, EditModel.neutral)
                let difference = abs(redOverBlue(masked, centre(masked))
                                     / redOverBlue(img, centre(img)) - 1)
                print(String(format: "079 A3 灰度 %.2f 温度 %+.0f: 蒙版 R/B %.5f, %@ R/B %.5f, 差 %.3f %%",
                             Double(value), units, redOverBlue(masked, centre(masked)), label,
                             redOverBlue(img, centre(img)), difference * 100))
                return difference
            }

            let shipped = try route(solverGain(units: units), "全局")
            XCTAssertLessThan(shipped, 0.01,
                              "temperature \(units) on a \(value) grey: the mask must be the global cast")

            // **反证** — the encoded body this change replaced, at the same 1 % bar.
            let encoded = try route(encodedGain(units: units), "旧编码体")
            XCTAssertGreaterThan(encoded, 0.01,
                                 "the encoded body must miss the 1 % bar — otherwise the test is vacuous")

            // Outside the disc nothing moves: a mask is not a global gain.
            XCTAssertEqual(plain.rgba[0], masked.rgba[0], "the corner must be untouched")
            XCTAssertEqual(plain.rgba[2], masked.rgba[2], "the corner must be untouched")
        }
    }

    /// What is **left** after the fix, measured rather than hidden: a decoder's white balance is a
    /// diagonal gain in the *camera's* primaries, and S1.6's is a diagonal gain in the **working**
    /// primaries (Rec.2020 since 075). A diagonal conjugated by a change of basis is not diagonal, so a
    /// masked gain cannot be *identical* to a decoded one on a non-neutral result — the residual is a
    /// property of doing the two operations in different bases, not of this solver.
    ///
    /// Measured at `+30` on a 0.18 grey it is a few percent; the encoded body's error is three times
    /// larger and in the same direction. Both are printed, so "we removed the 2.2×" cannot be confused
    /// with "the two are now the same operation down to the primaries".
    func testTheRemainingDifferenceIsThePrimariesNotTheSolver() throws {
        let image = greyImage(0.18)
        let graph = try makeGraph(image, identity: "local-wb-primaries")
        var edit = EditModel.neutral
        edit.masks = [discMask(temperature: 30)]
        let masked = try render(graph, edit)

        func cameraSpace(_ gain: (r: Double, g: Double, b: Double), _ label: String) throws -> Double {
            let g = try makeGraph(pregainedInCameraSpace(image, by: gain), identity: "local-wb-camera")
            let img = try render(g, EditModel.neutral)
            let difference = abs(redOverBlue(masked, centre(masked))
                                 / redOverBlue(img, centre(img)) - 1)
            print(String(format: "079 A3 相机空间 %@, 温度 +30, 灰 0.18: 蒙版 R/B %.5f, 全局 R/B %.5f, 差 %.3f %%",
                         label, redOverBlue(masked, centre(masked)),
                         redOverBlue(img, centre(img)), difference * 100))
            return difference
        }

        let shipped = try cameraSpace(solverGain(units: 30), "solver 增益")
        let encoded = try cameraSpace(encodedGain(units: 30), "旧编码增益")
        XCTAssertLessThan(shipped, 0.05, "the primaries conjugation must stay a small, documented residual")
        XCTAssertGreaterThan(encoded, shipped * 2,
                             "the removed 2.2× must still be the dominant term here")
    }

    // MARK: - ② all-zero white balance does not move a byte

    /// `0 / 0` is **exactly** `(1, 1, 1)` — the solver's reference is its own anchor, so `ref/ref` is
    /// one in floating point, not `0.9999998`. A neutral mask is therefore bit-identical to no mask,
    /// which is the M1-6 rule this pass has to keep.
    func testZeroWhiteBalanceIsExactIdentity() throws {
        let identity = LocalAdjustments(temperature: 0, tint: 0).gain
        XCTAssertEqual(identity.r, 1, "temp 0 must be exactly 1")
        XCTAssertEqual(identity.g, 1, "tint 0 must be exactly 1")
        XCTAssertEqual(identity.b, 1, "temp 0 must be exactly 1")

        // Exposure is the only other factor, and it must not perturb the WB half either.
        for ev in [0.0, 1.0, -1.5, 4.0, -4.0] {
            let g = LocalAdjustments(exposure: ev, temperature: 0, tint: 0).gain
            let scale = Float(pow(2.0, ev))
            XCTAssertEqual(g.r, scale, "ev \(ev): R")
            XCTAssertEqual(g.g, scale, "ev \(ev): G")
            XCTAssertEqual(g.b, scale, "ev \(ev): B")
        }

        // End to end: a mask whose WB sliders are 0 (and nothing else set) changes no byte.
        let image = greyImage(0.4)
        let graph = try makeGraph(image, identity: "local-wb-zero")
        let plain = try render(graph, EditModel.neutral)
        var edit = EditModel.neutral
        edit.masks = [discMask(temperature: 0, tint: 0)]
        XCTAssertEqual(try render(graph, edit).sha256(), plain.sha256(),
                       "a zeroed WB mask must be byte-identical to no mask")

        // …and a slider that is *really* zero inside a mask that does work perturbs nothing: +1 EV with
        // the WB pair at 0 is a pure doubling, so the mask introduces no cast at all (R = B = G/1).
        var working = EditModel.neutral
        working.masks = [discMask(temperature: 0, tint: 0, exposure: 1)]
        let doubled = try render(graph, working)
        let o = centre(doubled)
        XCTAssertEqual(Double(doubled.rgba[o]), Double(doubled.rgba[o + 2]), accuracy: 1e-6,
                       "a zeroed WB mask must not introduce a cast")
        XCTAssertEqual(Double(doubled.rgba[o + 1]), Double(doubled.rgba[o]), accuracy: 1e-6,
                       "a zeroed WB mask must leave all three channels on one gain")
        XCTAssertGreaterThan(Double(doubled.rgba[o]), Double(plain.rgba[centre(plain)]),
                             "the fixture must actually be lifting the pixel")
    }

    // MARK: - ③ ±100 does not blow up

    /// The extreme the sliders can ask for, at the gain level and through the shipped kernel: finite,
    /// positive, and bounded by what the model itself says (R/B at ±100 is `1.71× / 0.28×`, the same
    /// numbers a global `9500 K / 3500 K` request produces — no mask-only clamp, and nothing the
    /// display stage has to rescue).
    func testExtremeWhiteBalanceStaysFinite() throws {
        let harness = try LocalApplyHarness(fill: 0.18)
        var largest = 0.0
        var largestGain = 0.0
        for (units, tint) in [(100.0, 0.0), (-100.0, 0.0), (100.0, 100.0), (-100.0, -100.0),
                              (-100.0, 100.0), (100.0, -100.0)] {
            let g = LocalAdjustments(temperature: units, tint: tint).gain
            for value in [g.r, g.g, g.b] {
                XCTAssertTrue(value.isFinite && value > 0, "\(units)/\(tint): gain \(value)")
            }
            // Through the kernel: the pixel must be the gain times the source, not a clamped replica.
            let out = try harness.run(temperature: units, tint: tint)
            let maxChannel = max(Double(out[0]), max(Double(out[1]), Double(out[2])))
            let maxGain = max(Double(g.r), max(Double(g.g), Double(g.b)))
            largest = max(largest, maxChannel)
            largestGain = max(largestGain, maxGain)
            print(String(format: "079 A3 极端 温度 %+.0f 色调 %+.0f: 增益 (%.3f %.3f %.3f), 灰度 0.18 → "
                         + "R %.4f G %.4f B %.4f, 最大通道 %.4f（最大增益 %.4f）",
                         units, tint, Double(g.r), Double(g.g), Double(g.b),
                         Double(out[0]), Double(out[1]), Double(out[2]), maxChannel, maxGain))
            XCTAssertTrue(out.allSatisfy { $0.isFinite }, "\(units)/\(tint): non-finite pixel")
            XCTAssertEqual(Double(out[1]), 0.18 * Double(g.g), accuracy: 1e-5,
                           "G = v · gainG — the solver's normalizer, nothing else")
            XCTAssertEqual(Double(out[0]), 0.18 * Double(g.r), accuracy: 1e-5, "R = v · gainR")
            XCTAssertEqual(Double(out[2]), 0.18 * Double(g.b), accuracy: 1e-5, "B = v · gainB")
            XCTAssertEqual(Double(out[3]), 1, accuracy: 1e-6, "alpha must survive the pass")
        }
        // The model's own bound: 1.925 on blue at 3500 K (temp −100 alone), 2.246 once the tint's
        // √(1+t/600) rides on top of it (temp −100 with tint +100) — that is the largest number the
        // two sliders can ask for together, and it is the model's, not a mask-side clamp.
        XCTAssertLessThan(largestGain, 2.25, "a ±100 mask must not ask for more than 2.25× on any channel")
        XCTAssertLessThan(largest, 0.42, "and a 0.18 grey must come out as a 0.18 grey times that bound")
    }

    // MARK: - ④ cost

    /// The change is **three floats per mask** and no per-pixel arithmetic: the kernel's ① is still
    /// `v *= d.a.xyz`. So the 4.10 Mpx pass must be indistinguishable between the new gain vector and
    /// the old one, and building 32 masks' descriptors (where the solver now runs) must be a
    /// microsecond-scale, once-per-table cost.
    func testTheMaskedWhiteBalanceCostsLessThanPointTwoMilliseconds() throws {
        let harness = try LocalApplyHarness()
        let newGain = LocalAdjustments(temperature: 30, tint: 15).gain
        let old = LightGroup(temperature: WhiteBalanceSolver.localKelvin(30), tint: 15).whiteBalanceGains
        let times = try harness.time(oldGain: (old.r, old.g, old.b),
                                     newGain: (newGain.r, newGain.g, newGain.b))
        // Paired deltas, one per round: the statistic is their median, so a single round lost to a
        // parallel bundle cannot decide whether the pass got slower (it cannot: the kernel is the same
        // shader either way, and the descriptor is still three floats).
        let deltas = zip(times.new, times.old).map { $0 - $1 }.sorted()
        let median = deltas[deltas.count / 2]
        print(String(format: "079 A3 S1.6 pass at 4.10 Mpx, WB only: 旧编码增益 %.3f ms, solver 增益 %.3f ms, "
                     + "配对 Δ 中位数 %+.3f ms（9 轮 %.3f…%.3f）",
                     times.old.min() ?? 0, times.new.min() ?? 0, median,
                     deltas.first ?? 0, deltas.last ?? 0))
        XCTAssertLessThan(abs(median), 0.2,
                          "the WB gain is three floats either way — the pass cannot move")
        // And the pass itself is still in the class it was: ~0.9 ms for 4.10 Mpx of S1.6.
        XCTAssertLessThan(times.new.min() ?? .infinity, 1.5, "the S1.6 pass must stay in its own budget")

        // The CPU half: one `gain` per mask per table build (the table is cached by the mask key).
        var masks = [LocalAdjustments]()
        for i in 0..<32 {
            masks.append(LocalAdjustments(temperature: Double(i * 3 - 48), tint: Double(i % 7) * 8))
        }
        let start = CFAbsoluteTimeGetCurrent()
        var sink = 0.0
        for _ in 0..<20 { for m in masks { let g = m.gain; sink += Double(g.r + g.g + g.b) } }
        let perMask = (CFAbsoluteTimeGetCurrent() - start) * 1e6 / Double(20 * masks.count)
        print(String(format: "079 A3 蒙版 WB 的 CPU 代价: %.2f µs / 蒙版（表按蒙版键缓存，不是每帧每像素）", perMask))
        XCTAssertGreaterThan(sink, 0, "keep the loop alive")
        XCTAssertLessThan(perMask, 100, "a per-mask gain must be microseconds, not milliseconds")
    }
}

// MARK: - the shipped kernel, compiled here

/// Compiles the **real** `s1_6_local.metal` out of the repo and dispatches it over a 4.10 Mpx target
/// with a single coverage-1 mask, so the pixel numbers and the timing below are the shipped pass's.
///
/// `LocalParams`/`LocalAdjustDesc` are mirrored field for field (Metal and Swift share no
/// declaration) — the same mirror `LocalToneTests` keeps, and it would fail loudly there if the kernel
/// struct grew a field this one does not have.
private struct LocalApplyHarness {

    struct Params { var a: SIMD4<Int32> }

    struct Adjust {
        var a: SIMD4<Float>   // gainR, gainG, gainB, amountScale
        var b: SIMD4<Float>   // contrast, highlights, shadows, whites
        var c: SIMD4<Float>   // blacks, contrast travel, pad, enabled
    }

    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // PhotonsCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // package root

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLComputePipelineState
    let width = 2560, height = 1600    // 4.096 Mpx — the contract's frame
    let fill: Float

    init(fill: Float = 0.5) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw XCTSkip("no command queue") }
        self.queue = queue
        self.fill = fill

        let url = Self.repoRoot.appendingPathComponent("Sources/PhotonsCore/Kernels/s1_6_local.metal")
        let source = try KernelLibrary.expandingLocalIncludes(of: url)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let fn = library.makeFunction(name: "s1_6_local") else {
            throw XCTSkip("s1_6_local is not in the shipped source")
        }
        self.pipeline = try device.makeComputePipelineState(function: fn)
    }

    private func texture(_ format: MTLPixelFormat, array: Bool = false) -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = array ? .type2DArray : .type2D
        d.pixelFormat = format
        d.width = width; d.height = height
        d.arrayLength = 1
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .shared          // readback in `run`, and legal for a 4.10 Mpx fixture
        let texture = device.makeTexture(descriptor: d)!
        if array {
            // The atlas: one slice of alpha 1, so the mask's coverage is exactly 1 everywhere and the
            // pass's arithmetic is what the readback shows.
            var ones = [Float](repeating: 1, count: width * height)
            ones.withUnsafeMutableBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                slice: 0, withBytes: raw.baseAddress!,
                                bytesPerRow: width * 4, bytesPerImage: width * height * 4)
            }
        } else {
            var pixels = [Float](repeating: 0, count: width * height * 4)
            for i in 0..<(width * height) {
                pixels[i * 4] = fill; pixels[i * 4 + 1] = fill
                pixels[i * 4 + 2] = fill; pixels[i * 4 + 3] = 1
            }
            pixels.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: raw.baseAddress!, bytesPerRow: width * 16)
            }
        }
        return texture
    }

    /// The descriptor the app would build for one mask: `LocalAdjustU` with a WB-only slider set.
    private func makeBuffers(gain: (r: Float, g: Float, b: Float)) -> (MTLBuffer, MTLBuffer) {
        var params = Params(a: SIMD4(1, 1, 0, 0))
        var adjust = Adjust(a: SIMD4(gain.r, gain.g, gain.b, 1), b: .zero, c: SIMD4(0, 1, 0, 1))
        let p = device.makeBuffer(bytes: &params, length: MemoryLayout<Params>.stride,
                                  options: .storageModeShared)!
        let a = device.makeBuffer(bytes: &adjust, length: MemoryLayout<Adjust>.stride,
                                  options: .storageModeShared)!
        return (p, a)
    }

    private func encode(_ pipeline: MTLComputePipelineState,
                        _ src: MTLTexture, _ dst: MTLTexture, _ atlas: MTLTexture,
                        _ params: MTLBuffer, _ adjust: MTLBuffer, _ cb: MTLCommandBuffer) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(pipeline)
        enc.setTexture(src, index: 0)
        enc.setTexture(atlas, index: 1)
        enc.setTexture(dst, index: 2)
        enc.setBuffer(params, offset: 0, index: 0)
        enc.setBuffer(adjust, offset: 0, index: 1)
        let tw = pipeline.threadExecutionWidth
        let th = pipeline.maxTotalThreadsPerThreadgroup / tw
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
    }

    /// One dispatch, centre pixel read back in float32 (`rgba32Float` end to end, so the numbers are the
    /// arithmetic's and not a half-float's).
    func run(temperature: Double, tint: Double) throws -> [Float] {
        let src = texture(.rgba32Float)
        let dst = texture(.rgba32Float)
        let atlas = texture(.r32Float, array: true)
        let gain = LocalAdjustments(temperature: temperature, tint: tint).gain
        let (params, adjust) = makeBuffers(gain: gain)
        guard let cb = queue.makeCommandBuffer() else { throw XCTSkip("no command buffer") }
        encode(pipeline, src, dst, atlas, params, adjust, cb)
        cb.commit()
        cb.waitUntilCompleted()

        var out = [Float](repeating: 0, count: 4)
        let centre = MTLRegionMake2D(width / 2, height / 2, 1, 1)
        out.withUnsafeMutableBytes { raw in
            dst.getBytes(raw.baseAddress!, bytesPerRow: 16, from: centre, mipmapLevel: 0)
        }
        return out
    }

    /// Milliseconds per 4.10 Mpx pass for the old and the new gain vector, **interleaved**: nine rounds,
    /// the order alternating every round, twenty dispatches inside each command buffer. Interleaving is
    /// what makes the comparison a measurement instead of two separate samples of the machine's mood —
    /// the two descriptors differ by three floats, so the residual is noise — and nine rounds rather
    /// than one is what keeps a parallel test bundle hogging the GPU from deciding the answer: the
    /// *median* delta below is the statistic the assertion uses, and a single slow round cannot move it.
    func time(oldGain: (r: Float, g: Float, b: Float),
              newGain: (r: Float, g: Float, b: Float)) throws -> (old: [Double], new: [Double]) {
        let src = texture(.rgba32Float)
        let dst = texture(.rgba32Float)
        let atlas = texture(.r32Float, array: true)
        let oldBuffers = makeBuffers(gain: oldGain)
        let newBuffers = makeBuffers(gain: newGain)

        let iterations = 20
        var old: [Double] = []
        var new: [Double] = []

        func measure(_ buffers: (MTLBuffer, MTLBuffer)) throws -> Double {
            guard let cb = queue.makeCommandBuffer() else { throw XCTSkip("no command buffer") }
            for i in 0..<iterations {
                encode(pipeline, i % 2 == 0 ? src : dst, i % 2 == 0 ? dst : src, atlas,
                       buffers.0, buffers.1, cb)
            }
            let start = CFAbsoluteTimeGetCurrent()
            cb.commit()
            cb.waitUntilCompleted()
            return (CFAbsoluteTimeGetCurrent() - start) * 1000.0 / Double(iterations)
        }

        for round in 0..<9 {
            if round % 2 == 0 {
                old.append(try measure(oldBuffers))
                new.append(try measure(newBuffers))
            } else {
                new.append(try measure(newBuffers))
                old.append(try measure(oldBuffers))
            }
        }
        return (old, new)
    }
}
