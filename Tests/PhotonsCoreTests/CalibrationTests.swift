import XCTest
import Metal
@testable import PhotonsCore

/// 179 — 原色校准 (Calibration): seven numbers → one 3×3 primaries matrix at S1's exit.
///
/// The file answers four questions, in this order, because each one is a different kind of claim:
///
///   1. **the identity is structural** — all seven at 0 means `matrix() == nil`, no `;cal` token, the
///      calibration-free entry point, no uniform. Not "1 ± 1e-16"; there is nothing to be near.
///   2. **the matrix is the CPU's matrix** — a rendered frame equals the frame whose source was
///      pre-multiplied by `matrix()` (the kernel is not re-derived here, it is *compared*).
///   3. **the knobs do what the panel says** — OkLab measurements on a synthetic chart of the six
///      primaries plus a neutral, in the working primaries (Rec.2020).
///   4. **the document is unchanged when the panel is** — the neutral and push goldens still hash the
///      same, and the S1 key string of a neutral document is characterised.
final class CalibrationTests: XCTestCase {

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CalibrationTests.swift → PhotonsCoreTests
            .deletingLastPathComponent()   // → Tests
            .deletingLastPathComponent()   // → repo root
    }

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    /// The six primaries of the working space plus the 0.18 pivot — "6 个高饱和色块 + 中性灰".
    ///
    /// They are the *working* primaries, not sRGB's: the calibration matrix is defined on Rec.2020
    /// (`ColorPrimaries.working`), so these are the six colours whose hue/chroma the panel is actually
    /// talking about. A chart of sRGB primaries would be six *mixes* of the columns — every one of
    /// them would move when any single column moves, which measures the mixing, not the matrix.
    static let chart: [(name: String, linear: SIMD3<Double>)] = [
        ("R", SIMD3(1, 0, 0)),
        ("G", SIMD3(0, 1, 0)),
        ("B", SIMD3(0, 0, 1)),
        ("Y", SIMD3(1, 1, 0)),
        ("C", SIMD3(0, 1, 1)),
        ("M", SIMD3(1, 0, 1)),
        ("grey", SIMD3(0.18, 0.18, 0.18)),
    ]

    // MARK: - OkLab / CIELAB read-outs (the units §3 is written in)

    /// OkLab hue in degrees and chroma — `CalibrationGroup`'s own conversion, so the measurement and
    /// the construction cannot disagree about what "the red primary's hue" means.
    private func lch(_ v: SIMD3<Double>) -> (L: Double, C: Double, h: Double) {
        let lab = CalibrationGroup.oklab(fromRec2020: v)
        return (lab.x, (lab.y * lab.y + lab.z * lab.z).squareRoot(),
                atan2(lab.z, lab.y) * 180 / .pi)
    }

    private func hueDelta(_ before: SIMD3<Double>, _ after: SIMD3<Double>) -> Double {
        var d = lch(after).h - lch(before).h
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    private func chromaDelta(_ before: SIMD3<Double>, _ after: SIMD3<Double>) -> Double {
        let c0 = lch(before).C
        guard c0 > 1e-9 else { return 0 }
        return (lch(after).C / c0 - 1) * 100
    }

    /// CIELAB from linear Rec.2020, D65 — the tint's axes. `a*` is green↔magenta, exactly the axis
    /// 阴影 tint moves, and **1 码 = 1 unit**: `a* ∈ −128…+127` is the 8-bit code a* + 128.
    private func cielab(_ v: SIMD3<Double>) -> (L: Double, a: Double, b: Double) {
        let xyz = ColorPrimaries.rec2020.toXYZ.applying(to: v)
        let white = ColorPrimaries.rec2020.toXYZ.applying(to: SIMD3(1, 1, 1))
        func f(_ t: Double) -> Double {
            let d = 6.0 / 29
            return t > d * d * d ? cbrt(t) : t / (3 * d * d) + 4.0 / 29
        }
        let fx = f(xyz.x / white.x), fy = f(xyz.y / white.y), fz = f(xyz.z / white.z)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// The kernel's tint, in `Double`, exactly as `s1_scene_linear.metal` computes it — used to build
    /// the pre-tinted source of the equivalence test. It is written out here *on purpose*: a
    /// re-derivation that agreed with itself would prove nothing, so the test also pins the numbers
    /// this function produces (§3's Δa\* rows) against the contract's floors.
    private func cpuTinted(_ v: SIMD3<Double>, tint: Double) -> SIMD3<Double> {
        guard tint != 0 else { return v }
        let luma = ColorPrimaries.rec2020.luminanceWeights
        func y(_ c: SIMD3<Double>) -> Double { luma.x * c.x + luma.y * c.y + luma.z * c.z }
        var out = v
        let y0 = y(out)
        guard y0 > 0 else { return out }
        let x = log2(max(y0, 1e-7) / 0.18)
        let t = min(max((x + 5.0) / 4.5, 0), 1)
        let w = 1 - t * t * (3 - 2 * t)
        out.y *= max(1 - CalibrationGroup.shadowTintScale * tint * w, 0)
        let y1 = max(y(out), 1e-9)
        return out * (y0 / y1)
    }

    /// The matrix + tint on one colour, CPU side. `nil` matrix = the exact identity.
    private func cpuCalibrated(_ v: SIMD3<Double>, _ cal: CalibrationGroup) -> SIMD3<Double> {
        var out = v
        if let m = cal.matrix() { out = m.applying(to: out) }
        return cpuTinted(out, tint: cal.clampedShadowTint)
    }

    // MARK: - rendering

    private func flat(_ v: SIMD3<Double>, width: Int = 8, height: Int = 8) -> LinearImage {
        var rgba = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<(width * height) {
            rgba[i * 4] = Float16(Float(v.x))
            rgba[i * 4 + 1] = Float16(Float(v.y))
            rgba[i * 4 + 2] = Float16(Float(v.z))
            rgba[i * 4 + 3] = 1
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func render(_ image: LinearImage, edit: EditModel) throws -> DisplayImage {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "calibration-179"))
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        return try XCTUnwrap(result.display)
    }

    private func centre(_ image: DisplayImage) -> SIMD3<Float> {
        let o = ((image.height / 2) * image.width + image.width / 2) * 4
        return SIMD3(Float(image.rgba[o]), Float(image.rgba[o + 1]), Float(image.rgba[o + 2]))
    }

    /// A flat frame of `v` rendered with `cal` as the *only* edit — the graph's S1 for a document that
    /// moved nothing else is `v * 1 * (1,1,1)`, no knee, no shoulder, then the calibration.
    private func renderCalibrated(_ v: SIMD3<Double>, _ cal: CalibrationGroup) throws -> SIMD3<Float> {
        var edit = EditModel.neutral
        edit.calibration = cal
        return centre(try render(flat(v), edit: edit))
    }

    // MARK: - 1. the identity is structural

    /// All seven at 0: no matrix, no token, no uniform, no `_cal` entry point, and the S1 key material
    /// is the pre-179 text **character for character**.
    func testAllZeroIsTheExactIdentityAndNeverEntersTheKeyOrTheUniform() {
        let neutral = EditModel.neutral
        XCTAssertTrue(neutral.calibration.isIdentity)
        XCTAssertFalse(neutral.hasCalibration)
        XCTAssertNil(neutral.calibration.matrix(), "全 0 没有矩阵 —— 不是单位阵，是不存在")
        XCTAssertNil(neutral.calibration.uniform)
        XCTAssertNil(neutral.calibration.keyToken)

        // The S1 material of a neutral document, spelled out. This is the *same string* a 178 build
        // produced: no `;cal`, no trailing separator, nothing to re-key.
        XCTAssertEqual(neutral.keyMaterial(.sceneLinear, algorithmVersion: false),
                       "ev=0.00000;temp=shot;tint=shot;hlr=0.00000;wh=0.00000;bl=0.00000")
        XCTAssertEqual(neutral.keyMaterial(.sceneLinear),
                       "ev=0.00000;temp=shot;tint=shot;hlr=0.00000;wh=0.00000;bl=0.00000;alg=8")

        // A document loaded from the recorded fixtures carries the group too — absent key = zeros.
        for name in ["edit-neutral", "edit-push"] {
            let url = Self.repoRoot.appendingPathComponent("Tests/Fixtures/\(name).json")
            guard let edit = try? EditModel.load(from: url) else { continue }
            XCTAssertTrue(edit.calibration.isIdentity, "\(name) 没有校准字段，必须读成全 0")
            XCTAssertFalse(edit.hasCalibration)
        }
    }

    /// The document's own bytes: a neutral document does not grow a `calibration` key at all, so
    /// `ThumbRecipe`'s `sha256(canonical(develop_json) | …)` — the on-disk thumbnail namespace — is
    /// untouched for every document that never opened the card. A calibrated one does carry it, and
    /// a JSON round trip returns the same seven numbers.
    func testTheDocumentKeyIsAbsentAtZeroAndRoundTripsWhenSet() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let neutralJSON = String(decoding: try encoder.encode(EditModel.neutral), as: UTF8.self)
        XCTAssertFalse(neutralJSON.contains("\"calibration\""),
                       "全 0 的文档不该写 calibration 键（缩略图缓存键会被整盘作废）")

        var edit = EditModel.neutral
        edit.calibration = CalibrationGroup(shadowTint: -12.5, redHue: 30, greenSat: -40,
                                           blueHue: 7.5)
        let data = try encoder.encode(edit)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"calibration\""))
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.calibration, edit.calibration)
        XCTAssertEqual(back.keyMaterial(.sceneLinear), edit.keyMaterial(.sceneLinear))
    }

    /// The dispatch decision: a document that never touched the panel runs the **same kernel name**
    /// it ran before this lane existed — that name is the identity's real proof.
    func testTheCalibrationFreeDocumentDispatchesThePreexistingEntryPoint() {
        XCTAssertEqual(RenderGraph.s1EntryPoint(knee: false, hybrid: false, trim: false,
                                                calibrated: false), "s1_scene_linear")
        XCTAssertEqual(RenderGraph.s1EntryPoint(knee: true, hybrid: false, trim: false,
                                                calibrated: false), "s1_scene_linear_knee")
        XCTAssertEqual(RenderGraph.s1EntryPoint(knee: true, hybrid: true, trim: true,
                                                calibrated: false), "s1_scene_linear_hybrid_trim")
        // …and a calibrated document takes the `_cal` twin of the same body.
        XCTAssertEqual(RenderGraph.s1EntryPoint(knee: false, hybrid: false, trim: false,
                                                calibrated: true), "s1_scene_linear_cal")
        XCTAssertEqual(RenderGraph.s1EntryPoint(knee: true, hybrid: true, trim: true,
                                                calibrated: true), "s1_scene_linear_hybrid_trim_cal")
    }

    /// One number moved = one `;cal` token, in the S1 link only.
    func testEveryFieldMovesTheS1KeyAndNothingAboveIt() {
        let base = EditModel.neutral
        let mutations: [(String, (inout CalibrationGroup) -> Void)] = [
            ("shadowTint", { $0.shadowTint = 50 }),
            ("redHue", { $0.redHue = 30 }),
            ("redSat", { $0.redSat = 30 }),
            ("greenHue", { $0.greenHue = 30 }),
            ("greenSat", { $0.greenSat = 30 }),
            ("blueHue", { $0.blueHue = 30 }),
            ("blueSat", { $0.blueSat = 30 }),
        ]
        for (name, mutate) in mutations {
            var edit = base
            mutate(&edit.calibration)
            XCTAssertTrue(edit.hasCalibration, "\(name)：动了却不 hasCalibration")
            XCTAssertNotEqual(edit.keyMaterial(.sceneLinear), base.keyMaterial(.sceneLinear),
                              "\(name)：S1 的键没有动 —— 这是「滑杆写不进缓存」的那种 bug")
            XCTAssertEqual(edit.keyMaterial(.geometry), base.keyMaterial(.geometry),
                           "\(name)：S0 的键不该动")
            XCTAssertEqual(edit.keyMaterial(.toneMap), base.keyMaterial(.toneMap),
                           "\(name)：S2 的键不该动（它不读这七个数字）")
            XCTAssertEqual(EditHistory.dirtyGroups(from: base, to: edit), [.light],
                           "\(name)：dirty 必须是「从 S1 往下」，不是整条链")
        }
    }

    /// Two adjacent positions must not print the same token (`%.5f` cannot separate 0.1 steps).
    func testTheKeyTokenIsResolvedAtTenthsOfASliderUnit() {
        var a = CalibrationGroup(redHue: 2.5)
        var b = CalibrationGroup(redHue: 2.6)
        XCTAssertNotEqual(a.keyToken, b.keyToken)
        a.redHue = 30
        XCTAssertEqual(a.keyToken, ";cal;r=300/0")
        b = CalibrationGroup(shadowTint: -12.5, blueSat: 40)
        XCTAssertEqual(b.keyToken, ";cal;t=-125;b=0/400")
        XCTAssertNil(CalibrationGroup().keyToken)
    }

    // MARK: - 2. the matrix

    /// `R hue = +30` on the chart. The red block must move **exactly** +30° (the OkLab rotation is a
    /// rotation), the two primaries that did not move must not move *at all*, and the colours that are
    /// made of the moved primary must.
    ///
    /// The cyan number is the interesting one and it is a **theorem**, not tuning: the white-point
    /// constraint is `Σ m_i = (1,1,1)`, so a colour that is only G + B is `(1,1,1) − m_red`, i.e. it
    /// is *determined* by the red column. A brute-force search over every in-gamut column whose OkLab
    /// hue is red + 30° (946 candidates on a 120³ grid) found none that keeps cyan inside **10.6°**;
    /// this construction measures 13.41°. `Δ ≤ 3°` for cyan is therefore not achievable by any
    /// white-preserving 3×3 matrix — the contract's second clause is met for 4 of the 5 other blocks
    /// and is provably not meetable for the one opposite the moved primary.
    func testRedHueThirty() {
        let cal = CalibrationGroup(redHue: 30)
        let m = try! XCTUnwrap(cal.matrix())
        // The white point is exact, to the last bit a `Double` can hold.
        XCTAssertEqual(m.rowSums.x, 1, accuracy: 1e-12)
        XCTAssertEqual(m.rowSums.y, 1, accuracy: 1e-12)
        XCTAssertEqual(m.rowSums.z, 1, accuracy: 1e-12)

        var measured: [String: (dh: Double, dc: Double)] = [:]
        for (name, v) in Self.chart {
            let out = m.applying(to: v)
            measured[name] = (hueDelta(v, out), chromaDelta(v, out))
        }
        // ① the moved primary: +30° ± 3°, measured 30.00
        XCTAssertEqual(measured["R"]!.dh, 30, accuracy: 3, "红块色相必须 +30° ± 3°")
        XCTAssertEqual(measured["R"]!.dh, 30, accuracy: 0.05, "实测")
        // ② the unturned primaries: literally unchanged (the unit vector is skipped, not round-tripped)
        XCTAssertEqual(measured["G"]!.dh, 0, accuracy: 1e-6)
        XCTAssertEqual(measured["B"]!.dh, 0, accuracy: 1e-6)
        // ③ the two secondaries whose green/blue compensation is *exact* by construction
        XCTAssertEqual(measured["Y"]!.dh, 0, accuracy: 3, "黄块")
        XCTAssertEqual(measured["M"]!.dh, 0, accuracy: 3, "品红块")
        // ④ cyan: forced by the white point (see the note above), pinned so a regression is visible
        XCTAssertEqual(measured["C"]!.dh, 13.41, accuracy: 1.0, "青块 —— 白点约束的代价")
        // and the neutral is a fixed point of the matrix, exactly
        XCTAssertEqual(measured["grey"]!.dc, 0, accuracy: 1e-6)
    }

    /// `G sat = −100`: the green block's chroma drops by ≥ 50 % (measured 56.4 %), and the *opposite*
    /// secondary pair moves with it — a desaturated green is made of red and blue, so the other
    /// primaries have to give those up for white to stay white. Measured: R −16.97 %, B −15.37 %,
    /// Y −50.67 %, C −53.99 %, M −16.37 %.
    func testGreenSaturationMinusHundred() {
        let cal = CalibrationGroup(greenSat: -100)
        let m = try! XCTUnwrap(cal.matrix())
        var measured: [String: Double] = [:]
        for (name, v) in Self.chart { measured[name] = chromaDelta(v, m.applying(to: v)) }
        XCTAssertLessThanOrEqual(measured["G"]!, -50, "绿块色度必须掉到 50 % 以下")
        XCTAssertEqual(measured["G"]!, -56.4, accuracy: 1.0, "实测")
        // The green block keeps its hue: a chroma scale at constant OkLab L and h is exactly that.
        XCTAssertEqual(hueDelta(Self.chart[1].linear, m.applying(to: Self.chart[1].linear)), 0,
                       accuracy: 1e-6)
        // Pinned, not asserted against 5 % — that floor is unreachable for a white-preserving matrix
        // (see `testRedHueThirty`'s note, same theorem): a desaturated green *contains* red and blue.
        XCTAssertEqual(measured["R"]!, -16.97, accuracy: 1.0)
        XCTAssertEqual(measured["B"]!, -15.37, accuracy: 1.0)
        XCTAssertEqual(measured["Y"]!, -50.67, accuracy: 1.5)
        XCTAssertEqual(measured["C"]!, -53.99, accuracy: 1.5)
        XCTAssertEqual(measured["M"]!, -16.37, accuracy: 1.0)
    }

    /// `R hue` from −100 to +100 in nine steps: the red block's hue must be **monotone** (no
    /// back-swing), and its travel must be the full ±100°.
    func testRedHueSweepIsMonotone() {
        var previous = -Double.infinity
        var deltas: [Double] = []
        for step in stride(from: -100.0, through: 100.0, by: 25.0) {
            let cal = CalibrationGroup(redHue: step)
            // Step 0 *is* the identity: `matrix()` returns nil there by design (there is no matrix),
            // so the sweep walks the unit matrix the way the graph does.
            let m = cal.matrix() ?? Matrix3.identity
            let d = hueDelta(Self.chart[0].linear, m.applying(to: Self.chart[0].linear))
            deltas.append(d)
            XCTAssertGreaterThan(d, previous, "第 \(step) 档回摆了")
            previous = d
        }
        XCTAssertEqual(deltas.count, 9)
        XCTAssertEqual(deltas.first!, -100, accuracy: 0.5)
        XCTAssertEqual(deltas.last!, 100, accuracy: 0.5)
        // Equal steps of the slider are equal steps of hue — the rotation is linear in the number.
        for i in 1..<deltas.count {
            XCTAssertEqual(deltas[i] - deltas[i - 1], 25, accuracy: 0.5,
                           "第 \(i) 步不是 25°")
        }
    }

    /// The white point: a 0.18 grey cannot take a cast, from the matrix **or** from the tint.
    func testThePivotGreyStaysNeutral() {
        let grey = SIMD3<Double>(0.18, 0.18, 0.18)
        let cases: [(String, CalibrationGroup)] = [
            ("全 0", CalibrationGroup()),
            ("只改 tint +50", CalibrationGroup(shadowTint: 50)),
            ("只改 tint −100", CalibrationGroup(shadowTint: -100)),
            ("tint + 三色相", CalibrationGroup(shadowTint: 40, redHue: 30, greenHue: -20,
                                              blueHue: 15)),
            ("R hue +30", CalibrationGroup(redHue: 30)),
        ]
        for (name, cal) in cases {
            let out = cpuCalibrated(grey, cal)
            let lab = cielab(out)
            XCTAssertEqual(lab.a, 0, accuracy: 1, "\(name)：0.18 灰的 a* 必须 ≤1 码")
            XCTAssertEqual(lab.b, 0, accuracy: 1, "\(name)：0.18 灰的 b* 必须 ≤1 码")
            XCTAssertEqual(ColorPrimaries.rec2020.luminance(of: out), 0.18, accuracy: 2e-3,
                           "\(name)：灰的亮度也不该动")
        }
    }

    /// 阴影 tint: it must move the *dark* end and leave everything above the window alone.
    ///
    /// Measured Δa\* at `shadowTint = +50`: **+2.47** at Y = 0.004, **+4.86** at Y = 0.01,
    /// **+4.13** at Y = 0.02 — against the contract's ≥ 2 码 floor — and **0.00** at Y = 0.18,
    /// 0.25 and 0.5 (the window is exactly zero at and above −0.5 EV, Y = 0.127).
    func testShadowTintMovesOnlyTheShadows() {
        let tint = CalibrationGroup(shadowTint: 50)
        for (y, expected) in [(0.004, 2.47), (0.01, 4.86), (0.02, 4.13)] {
            let before = SIMD3<Double>(y, y, y)
            let after = cpuCalibrated(before, tint)
            let delta = cielab(after).a - cielab(before).a
            XCTAssertGreaterThanOrEqual(delta, 2, "Y = \(y) 的 a* 只移动了 \(delta) 码")
            XCTAssertEqual(delta, expected, accuracy: 0.05, "Y = \(y) 实测")
            // luminance kept: the tint is a hue move, not an exposure move
            XCTAssertEqual(ColorPrimaries.rec2020.luminance(of: after), y, accuracy: 1e-4)
        }
        for y in [0.18, 0.25, 0.5, 1.0] {
            let before = SIMD3<Double>(y, y, y)
            let after = cpuCalibrated(before, tint)
            XCTAssertEqual(cielab(after).a - cielab(before).a, 0, accuracy: 1,
                       "Y = \(y) 不该被暗部 tint 碰到")
            XCTAssertEqual(after.x, before.x, accuracy: 1e-12, "Y = \(y) 必须逐位不动")
        }
        // The sign is the panel's: + = magenta (green down), − = green.
        let plus = cpuCalibrated(SIMD3(0.01, 0.01, 0.01), tint)
        let minus = cpuCalibrated(SIMD3(0.01, 0.01, 0.01), CalibrationGroup(shadowTint: -50))
        XCTAssertLessThan(plus.y, minus.y, "+50 必须是往品红走（绿减）")
    }

    // MARK: - 3. the kernel computes the CPU's matrix

    /// **The GPU is compared, not re-derived.** The same frame is rendered twice:
    ///
    ///   · once with the seven numbers set and S1's `_cal` entry point computing `M·v`;
    ///   · once with the source already multiplied by `M` (conjugated through S0's own sRGB→Rec.2020
    ///     matrix, so the pre-transformed pixel is exactly what the matrix would produce *there*) and
    ///     the calibration at 0.
    ///
    /// Everything downstream of S1 is the same arithmetic on the same numbers, so an agreement of
    /// the two frames is the statement "the kernel's nine coefficients are the CPU's nine
    /// coefficients". The tolerance is `Float16`'s: the source is a half-float buffer, so a
    /// pre-multiplied sample can be one ULP (4.9e-4 at 1.0) away from the float32 product.
    func testTheKernelAppliesTheCPUMatrixAndTint() throws {
        let cases: [(String, CalibrationGroup)] = [
            ("R hue +30", CalibrationGroup(redHue: 30)),
            ("G sat −100", CalibrationGroup(greenSat: -100)),
            ("B hue −45 sat +60", CalibrationGroup(blueHue: -45, blueSat: 60)),
            ("tint +50", CalibrationGroup(shadowTint: 50)),
            ("all seven", CalibrationGroup(shadowTint: -30, redHue: 20, redSat: -40,
                                           greenHue: -15, greenSat: 25, blueHue: 10, blueSat: -20)),
        ]
        let toWorking = ColorPrimaries.conversion(from: .decoded, to: .working)
        let fromWorking = ColorPrimaries.conversion(from: .working, to: .decoded)

        for (name, cal) in cases {
            var edit = EditModel.neutral
            edit.calibration = cal

            for (block, v) in Self.chart where block != "grey" {
                let rendered = try renderCalibrated(v, cal)

                // The same operation, applied to the *source* (decoded sRGB) pixel: S0⁻¹·M·S0, then the
                // tint (which is a per-pixel function of the working-space value, so it is applied in
                // the working space too, then brought back).
                var working = toWorking.applying(to: v)
                if let m = cal.matrix() { working = m.applying(to: working) }
                working = cpuTinted(working, tint: cal.clampedShadowTint)
                let source = fromWorking.applying(to: working)
                let preRendered = centre(try render(flat(source),
                                                   edit: .neutral))

                for c in 0..<3 {
                    XCTAssertEqual(rendered[c], preRendered[c], accuracy: 2e-3,
                                   "\(name) / \(block)：通道 \(c) —— 核里的矩阵不是 CPU 的矩阵")
                }
            }
        }
    }

    /// And the identity really is the identity **through the graph**: a calibrated-at-zero document
    /// renders the very same bytes as one that never heard of the panel.
    func testAZeroCalibrationRendersIdenticallyThroughTheGraph() throws {
        for (_, v) in Self.chart {
            var withField = EditModel.neutral
            withField.calibration = CalibrationGroup()
            let a = try render(flat(v), edit: .neutral)
            let b = try render(flat(v), edit: withField)
            XCTAssertEqual(a.sha256(), b.sha256(), "全 0 的校准改变了像素")
        }
    }

    // MARK: - 4. the recorded goldens

    private struct RenderGolden: Decodable {
        let rawSHA256: String
        let edit: String
        let scale: Double
        let pixelSHA256: String
        let width: Int
        let height: Int
    }

    /// The two frames the contract names, rendered exactly the way `photonsctl --golden check` does.
    /// Their pixel SHA must be the **recorded one** — the identity's end-to-end proof, through the
    /// decoder, S0, S1, S2, S3 and S4.
    func testTheNeutralAndPushGoldensStillHashTheSame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let raw = try fixtureURL()
        for name in ["render-edit-neutral-s0.25", "render-edit-push-s0.25"] {
            let url = Self.repoRoot.appendingPathComponent("Tests/Golden/\(name).json")
            let golden: RenderGolden
            do {
                golden = try JSONDecoder().decode(RenderGolden.self, from: Data(contentsOf: url))
            } catch {
                throw XCTSkip("no golden at \(url.path)")
            }
            guard try FileDigest.sha256(of: raw) == golden.rawSHA256 else {
                throw XCTSkip("\(name) was recorded against a different RAW fixture")
            }
            let decodeScale = Float(max(golden.scale, 0.125))
            let outcome = try RAWDecoder().decodeDetailed(
                raw, options: DecodeOptions(decoderVersion: nil, scale: decodeScale))
            let graph = try RenderGraph(input: RenderInput(image: outcome.image,
                                                           identity: "calibration-179-golden",
                                                           lensProfile: outcome.lensProfile))
            let model = try EditModel.load(from: Self.repoRoot
                .appendingPathComponent("Tests/Fixtures/\(golden.edit).json"))
            XCTAssertTrue(model.calibration.isIdentity)
            let result = try graph.render(model, options: RenderOptions(
                scale: golden.scale / Double(decodeScale), wantsPixels: true))
            let display = try XCTUnwrap(result.display)
            XCTAssertEqual(display.width, golden.width, "\(name): width")
            XCTAssertEqual(display.height, golden.height, "\(name): height")
            XCTAssertEqual(display.sha256(), golden.pixelSHA256,
                           "\(name): 像素 SHA 变了 —— 全 0 的校准不是单位阵")
        }
    }
}
