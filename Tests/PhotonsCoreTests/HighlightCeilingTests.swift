import XCTest
import Metal
@testable import PhotonsCore

/// 320 — **the picture's ceiling**: +2 EV (linear 4.0) was a hard literal in the display-referred
/// tail, and it is now `photons.highlightCeilingEV` (default **+2.3 EV**, `2^2.3 = 4.9246`).
///
/// ## Where the clamp was (the probe this file's numbers come from)
///
/// The user's report: after +5 EV the picture, the histogram and the pointer's readout all stopped at
/// +2 EV. The candidates the brief listed are all *not* 4.0 — `DisplayOptions.headroom` (1.0 on this
/// machine), `Histogram.maxStops = 4` / `HDRCurveAxis.xHI = 16` (+4 EV), `SDRToneMap.maxHeadroom = 6`
/// (export only), `s4_display.metal:60`'s `min(v, headroom)` (1.0 on the panel). Measured, per stage,
/// on a synthetic picture at `exposure = +5`:
///
/// | segment | measurement | value |
/// |---|---|---|
/// | S0 → S4 only (`.decoded`) | linear exit peak | **16.00 / 32.00** — the ingest is clean |
/// | S1 (scene linear, gain 32×) | 0.5 → 16.0 | 16.00 — no clamp |
/// | S1.7 (HDR curve, identity) | copy | 16.00 |
/// | S2 (tone map) | identity copy | 16.00 — **and this is where the ceiling applies now** |
/// | S3 (colour) | copy | 16.00 |
/// | S3.10 (sharpen, **resting amount 50**) | `clamp(rgb + delta, 0.0, 4.0)` | **4.00** ← the clamp |
/// | S4 (`min(v, headroom)`), headroom 16 | decode | 4.00 |
/// | histogram (pre-S4 sample) | top non-zero hdr bin | **128** = +2.01 EV |
/// | pointer readout (`LinearSample`) | peak | **4.0000** |
///
/// **The site**: `Sources/PhotonsCore/Kernels/s3_10_sharpen.metal:402`
/// (`dst.write(float4(clamp(rgb + delta, 0.0, 4.0), px.a), gid)`) — and the same literal in
/// `s3_8_detail_fx.metal:413` / `:432` and `s3_7_grain.metal:113`. 314 left 锐化's resting amount at
/// 50 (`SharpenGroup.init`), so the pass — and its 4.0 — has been running on every document: the
/// picture's top was a property of the sharpen kernel, not of the picture. Its siblings carried the
/// same number, which is why turning one effect off never freed the highlight.
///
/// ## What the fix is
///
/// `DisplayOptions.highlightCeiling` (linear, default `2^2.3`) is the picture's ceiling. S2 applies it
/// once at the end of the tone map (`s2_tone_map.metal`, **both** branches), so it does not depend on
/// which effects are on; the three tail guards above read it instead of their literal, so an effect
/// may not clip below it or push above it. The histogram samples the texture **after** S2, so the plot
/// and the pointer row follow by construction — they are not a second clamp.
final class HighlightCeilingTests: XCTestCase {

    private let defaultLinear = HighlightCeiling.defaultLinear       // 4.924577653378805
    private let fourEV = HighlightCeiling.linear(ev: 4)              // 16

    /// 323b — 本类会 `HighlightCeiling.setEV(…)`，那是**全局偏好**（`UserDefaults`）。之前没有
    /// 保存/恢复，同一个进程里排在后面的用例（`HistogramOverWhiteReadoutTests` 的「画面里超过屏幕
    /// 上限的通道」、以及任何渲染）会读到别的用例留下的上限值 —— 表现是「有时红有时绿」。
    private var savedPref: Any?

    override func setUp() {
        super.setUp()
        savedPref = UserDefaults.standard.object(forKey: HighlightCeiling.defaultsKey)
        UserDefaults.standard.removeObject(forKey: HighlightCeiling.defaultsKey)
    }

    override func tearDown() {
        if let savedPref { UserDefaults.standard.set(savedPref, forKey: HighlightCeiling.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: HighlightCeiling.defaultsKey) }
        super.tearDown()
    }

    // MARK: - fixtures

    private func graph(_ image: LinearImage, _ id: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: id))
    }

    /// Four vertical blocks: a grey, SDR white, and two "sky" values that are only bright once the
    /// exposure is applied. Equal quarters, so a bin count is a block.
    private func blocks(values: [Float] = [0.05, 0.25, 0.5, 1.0],
                        width: Int = 400, height: Int = 100) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let b = min(values.count - 1, x * values.count / width)
                let v = Float16(values[b])
                let o = (y * width + x) * 4
                rgba[o] = v; rgba[o + 1] = v; rgba[o + 2] = v; rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func peak(_ img: DisplayImage) -> Double {
        var p = 0.0
        for o in stride(from: 0, to: img.rgba.count, by: 4) {
            for c in 0..<3 { p = max(p, Double(img.rgba[o + c])) }
        }
        return p
    }

    private static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private func encodedPeakAsLinear(_ img: DisplayImage) -> Double {
        var p = 0.0
        for o in stride(from: 0, to: img.rgba.count, by: 4) {
            for c in 0..<3 { p = max(p, Self.srgbToLinear(Double(img.rgba[o + c]))) }
        }
        return p
    }

    /// The texture S3 hands S4 — what the histogram samples. `s4_display_linear` is the only way to
    /// read it, and it has no upper clamp of its own, so this *is* the picture's top.
    private func sceneLinearPeak(_ g: RenderGraph, _ edit: EditModel, ceiling: Double) throws -> Double {
        var display = DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16,
                                     highlightCeiling: ceiling)
        display.linearOutput = true
        let result = try g.render(edit, options: RenderOptions(
            scale: 1, display: display, useCache: false, wantsPixels: true))
        return peak(try XCTUnwrap(result.display))
    }

    private func histogram(_ g: RenderGraph, _ edit: EditModel, ceiling: Double)
        throws -> (histogram: Histogram, sample: LinearSample?) {
        let result = try g.render(edit, options: RenderOptions(
            scale: 1,
            display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16,
                                    highlightCeiling: ceiling),
            useCache: false, wantsPixels: false,
            collectHistogram: true, histogramSampleLongEdge: Histogram.frameSampleLongEdge))
        return (try XCTUnwrap(result.histogram), result.histogramSample)
    }

    private func topBin(_ h: Histogram) -> (bin: Int, ev: Double) {
        let bins = h.luma.hdrBins
        for i in stride(from: bins.count - 1, through: 0, by: -1) where bins[i] > 0 {
            return (i, (Double(i) + 0.5) / Double(Histogram.hdrBinsPerStop))
        }
        return (-1, -1)
    }

    private func samplePeak(_ s: LinearSample?) -> Double {
        guard let s else { return -1 }
        var p = 0.0
        for o in stride(from: 0, to: s.rgba.count, by: 4) {
            for c in 0..<3 { p = max(p, Double(s.rgba[o + c])) }
        }
        return p
    }

    private func exposed(_ ev: Double) -> EditModel {
        var edit = EditModel.neutral
        edit.light.exposure = ev
        return edit
    }

    // MARK: - ① the clamp, and ② +5 EV is no longer cut at +2

    /// The probe table, measured on the shipped path, plus the two acceptance numbers: at
    /// `exposure = +5` the default ceiling stops the picture at **4.925**, and raising the ceiling to
    /// +4 EV stops it at **16.0** — so the number is adjustable and not a different constant.
    func testTheProbeTableAndTheTwoAcceptancePeaks() throws {
        let g = try graph(blocks(), "320-probe")

        // The four segments that are observable from outside the graph. S1/S1.7/S2/S3 are not
        // separately addressable (they are one command buffer), which is why the table above was
        // measured by *disabling* what could be disabled: `.decoded` (S0→S4) proves the ingest, and
        // the identity-chain renders (neutral document) prove no stage before S3.10 moves a value.
        let decoded = try g.render(.neutral, options: RenderOptions(
            scale: 1,
            display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16,
                                    linearOutput: true, highlightCeiling: fourEV),
            useCache: false, wantsPixels: true, source: .decoded))
        let decodedPeak = peak(try XCTUnwrap(decoded.display))

        let neutralPeak = try sceneLinearPeak(g, .neutral, ceiling: fourEV)
        let defaultPeak = try sceneLinearPeak(g, exposed(5), ceiling: defaultLinear)
        let widePeak = try sceneLinearPeak(g, exposed(5), ceiling: fourEV)

        let (hAtDefault, sampleAtDefault) = try histogram(g, exposed(5), ceiling: defaultLinear)
        let (hAtFour, sampleAtFour) = try histogram(g, exposed(5), ceiling: fourEV)
        let topDefault = topBin(hAtDefault)
        let topFour = topBin(hAtFour)

        let readoutDefault = log2(max(samplePeak(sampleAtDefault), 1e-9))
        let readoutFour = log2(max(samplePeak(sampleAtFour), 1e-9))

        print(String(format: "320 probe · S0→S4 (decoded) peak %.2f · neutral S3 exit %.2f · "
                     + "exp+5 @2.3 EV peak %.4f (want %.4f) · @4.0 EV peak %.4f (want %.4f) · "
                     + "histogram top bin %d (%.2f EV) / %d (%.2f EV) · readout %+.2f / %+.2f EV",
                     decodedPeak, neutralPeak, defaultPeak, defaultLinear, widePeak, fourEV,
                     topDefault.bin, topDefault.ev, topFour.bin, topFour.ev,
                     readoutDefault, readoutFour))

        // ② the two peaks (acceptance 2)
        XCTAssertEqual(defaultPeak, defaultLinear, accuracy: defaultLinear * 0.02,
                       "exp+5 at the default ceiling must stop at 2^2.3 = 4.925, not 4.0")
        XCTAssertEqual(widePeak, fourEV, accuracy: fourEV * 0.02,
                       "ceiling 4.0 EV must let the picture reach 16.0 — the number is adjustable")

        // ③ the histogram's top non-zero bin follows (acceptance 3)
        XCTAssertEqual(topDefault.bin, 147, accuracy: 1,
                       "ceiling 2.3 EV → tail bin 147 (2.3 × 64)")
        XCTAssertEqual(topFour.bin, 255, accuracy: 0,
                       "ceiling +4 EV → the tail's last bin")
        XCTAssertLessThan(topDefault.bin, topFour.bin, "the top bin must move with the ceiling")

        // ④ the pointer's readout follows (acceptance 4)
        XCTAssertEqual(readoutDefault, 2.3, accuracy: 0.02,
                       "the readout prints +2.3 EV at the default ceiling")
        XCTAssertEqual(readoutFour, 4.0, accuracy: 0.02,
                       "…and +4.0 EV when the ceiling is +4 EV")
    }

    // MARK: - ③ the histogram is a measurement, not a second clamp

    /// The tail's **last** bin is what the old 4.0 produced: everything above +2 EV landed in one
    /// place (bin 128) and nothing reached the end. Under the default it is 147, and a picture that is
    /// deliberately brighter than the ceiling lands there — one bin, not a smear: the clamp is a hard
    /// top, which is what 「最高亮度」 means.
    func testTheHistogramTailStopsAtTheCeiling() throws {
        let g = try graph(blocks(values: [0.05, 0.5, 2.0, 8.0]), "320-histogram")
        // +5 EV on this picture puts three blocks at 1.6 / 16 / 64 — all above both ceilings.
        let (h, _) = try histogram(g, exposed(5), ceiling: defaultLinear)
        let top = topBin(h)
        let tailTotal = h.luma.hdrBins.reduce(0, +)
        let atTop = h.luma.hdrBins[top.bin]
        print("320 histogram · top hdr bin \(top.bin) (\(String(format: "%.2f", top.ev)) EV) · "
              + "\(atTop)/\(tailTotal) samples at the ceiling · bins 145…150 = "
              + "\(Array(h.luma.hdrBins[145...150]))")
        XCTAssertEqual(top.bin, 147, accuracy: 1)
        XCTAssertGreaterThan(atTop, tailTotal / 2, "the clamped blocks pile into the ceiling's bin")
    }

    // MARK: - ⑤ the default is the preference, not a literal

    func testTheDefaultRenderUsesThePreferenceNotTheOldFour() throws {
        // The graph's own default — no ceiling passed anywhere.
        XCTAssertEqual(DisplayOptions().highlightCeiling, defaultLinear, accuracy: 1e-12)
        XCTAssertEqual(HighlightCeiling.defaultEV, 2.3)

        let g = try graph(blocks(), "320-default")
        var display = DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16)
        display.linearOutput = true
        let result = try g.render(exposed(5), options: RenderOptions(
            scale: 1, display: display, useCache: false, wantsPixels: true))
        let p = peak(try XCTUnwrap(result.display))
        print(String(format: "320 default (no override) · exp+5 peak %.4f (old bug: 4.0)", p))
        XCTAssertEqual(p, defaultLinear, accuracy: defaultLinear * 0.02,
                       "an untouched setting must render 4.925 — 4.0 was the bug")
        XCTAssertGreaterThan(p, 4.0, "and it must be strictly above the old literal")
    }

    // MARK: - ⑥ no collateral damage on an ordinary photograph

    /// The ceiling only touches light above itself. On the reference frame at `exposure = 0` the
    /// peak is far below 4.925, so the default clamp and an effectively infinite ceiling must produce
    /// **the same bytes**.
    func testAnExposureZeroPhotoIsByteIdenticalUnderTheCeiling() throws {
        let path = NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no RAW fixture at \(path)")
        }
        let image = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                            options: DecodeOptions(decoderVersion: nil, scale: 0.0625))
        let g = try graph(image, "320-no-collateral")
        var display = DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16)
        display.linearOutput = true

        func digest(ceiling: Double) throws -> (String, Double) {
            var d = display
            d.highlightCeiling = ceiling
            let r = try g.render(.neutral, options: RenderOptions(
                scale: 1, display: d, useCache: false, wantsPixels: true))
            let img = try XCTUnwrap(r.display)
            return (img.sha256(), peak(img))
        }

        let (clamped, clampedPeak) = try digest(ceiling: defaultLinear)
        let (unclamped, unclampedPeak) = try digest(ceiling: 1e6)
        print("320 collateral · exp 0 peak \(String(format: "%.4f", clampedPeak)) · "
              + "clamped \(clamped.prefix(16))… · unclamped \(unclamped.prefix(16))…")
        XCTAssertLessThan(clampedPeak, defaultLinear, "an ordinary frame sits below the ceiling")
        XCTAssertEqual(clamped, unclamped, "the ceiling may not move a pixel at or below itself")
    }

    // MARK: - the preference itself

    func testThePreferenceRoundTripsClampsAndLabels() {
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: HighlightCeiling.defaultsKey)
        defer {
            if let before { defaults.set(before, forKey: HighlightCeiling.defaultsKey) }
            else { defaults.removeObject(forKey: HighlightCeiling.defaultsKey) }
        }

        XCTAssertEqual(HighlightCeiling.defaultEV, 2.3)
        XCTAssertEqual(HighlightCeiling.linear(ev: 2.3), 4.924577653378805, accuracy: 1e-9)
        XCTAssertEqual(HighlightCeiling.linear(ev: 4), 16, accuracy: 1e-12)
        XCTAssertEqual(HighlightCeiling.evRange, 0 ... 4)
        XCTAssertEqual(HighlightCeiling.stepEV, 0.1)

        HighlightCeiling.setEV(3.4)
        XCTAssertEqual(HighlightCeiling.currentEV, 3.4, accuracy: 1e-12)
        XCTAssertEqual(HighlightCeiling.current, 10.556, accuracy: 0.001)

        // Outside the travel, on the row's 0.1 grid.
        HighlightCeiling.setEV(9)
        XCTAssertEqual(HighlightCeiling.currentEV, 4.0, accuracy: 1e-12)
        HighlightCeiling.setEV(-3)
        XCTAssertEqual(HighlightCeiling.currentEV, 0.0, accuracy: 1e-12)
        HighlightCeiling.setEV(2.34)
        XCTAssertEqual(HighlightCeiling.currentEV, 2.3, accuracy: 1e-9)

        XCTAssertEqual(HighlightCeiling.label(2.3), "+2.3 EV")
        XCTAssertEqual(HighlightCeiling.label(4), "+4.0 EV")
        XCTAssertEqual(HighlightCeiling.label(0), "+0.0 EV")

        // 323: the key carries the ceiling **always**, in one spelling (`ceil=%.4f`, from
        // `DisplayOptions.ceilingKeyString`), so no key can omit which picture top produced it.
        XCTAssertEqual(DisplayOptions().keyString,
                       DisplayOptions(highlightCeiling: HighlightCeiling.defaultLinear).keyString)
        XCTAssertTrue(DisplayOptions().keyString.contains("ceil=4.9246"), DisplayOptions().keyString)
        XCTAssertFalse(DisplayOptions().keyString.contains("ceiling"), "one spelling: ceil=")
        XCTAssertTrue(DisplayOptions(highlightCeiling: 16).keyString.contains("ceil=16.0000"))
        XCTAssertNotEqual(DisplayOptions().keyString, DisplayOptions(highlightCeiling: 16).keyString)
        XCTAssertEqual(Histogram.cacheKey(rungIdentity: "r", editDigest: "d", bins: 256),
                       Histogram.cacheKey(rungIdentity: "r", editDigest: "d", bins: 256,
                                          ceiling: HighlightCeiling.defaultLinear))
        XCTAssertTrue(Histogram.cacheKey(rungIdentity: "r", editDigest: "d", bins: 256)
                        .hasSuffix("|ceil=4.9246"))
        XCTAssertTrue(Histogram.cacheKey(rungIdentity: "r", editDigest: "d", bins: 256,
                                         ceiling: 16).contains("ceil=16.0000"))
    }
}
