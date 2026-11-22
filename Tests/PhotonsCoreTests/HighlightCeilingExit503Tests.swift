import XCTest
import Metal
import PhotonsLocalization
@testable import PhotonsCore

/// 503 — the ceiling is an **exit guarantee**, not a mid-chain clip.
///
/// 320 put `min(v, ceiling)` at the end of S2. Everything after it — 对比度, 饱和度, 黑白, 局部色彩,
/// HSL, 点颜色, 分级, 清晰度/细节, 颗粒 — can push a pixel back over the ceiling, so the picture's
/// brightest value was not the number the histogram and the pointer read as the top. 503 adds the same
/// clamp to **both S4 exits**, after the primaries matrix (the matrix mixes, so a clamp in front of it
/// can be pushed over by its own arithmetic) and before `min(v, headroom)` / the OETF.
///
/// ## The probe table (§1)
///
/// `testTheProbeTable` prints one row per stage boundary: the peak (max channel, linear) and how many
/// pixels are above the ceiling. Every row but the last two is read off the texture that stage wrote,
/// via `RenderOptions.stopBefore` — a stop is a *position*, so all nine boundaries are addressable
/// without a second renderer. The last two rows are the two real exits (screen `s4_display` and HDR
/// `s4_display_linear`), and those are the rows 503 moves.
///
/// "Above the ceiling" is `> ceiling × (1 + 1/2048)`: the same half-float slack
/// `Histogram.screenCeilingFloor` uses, because a value clamped to the ceiling is stored in a
/// half-float texture and can round to the ULP above it (4.9246 → 4.9258, ¹⁄₂ ULP = 0.0004
/// relative). Without the slack a *correct* clamp would report a handful of "over" pixels.
final class HighlightCeilingExit503Tests: XCTestCase {

    private let ceiling = HighlightCeiling.defaultLinear        // 4.924577653378805
    private let wide = HighlightCeiling.linear(ev: 4)           // 16
    /// The quantisation slack of the texture the samples come from (§ above).
    private let slack = 1.0 / 2048.0

    private var savedPref: Any?

    override func setUp() {
        super.setUp()
        savedPref = AppPreferences.store.object(forKey: HighlightCeiling.defaultsKey)
        AppPreferences.store.removeObject(forKey: HighlightCeiling.defaultsKey)
    }

    override func tearDown() {
        if let savedPref { AppPreferences.store.set(savedPref, forKey: HighlightCeiling.defaultsKey) }
        else { AppPreferences.store.removeObject(forKey: HighlightCeiling.defaultsKey) }
        super.tearDown()
    }

    // MARK: - fixtures

    private func graph(_ image: LinearImage, _ id: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: id))
    }

    /// Vertical blocks. Equal quarters, so a pixel count is a block. The last value is **above** the
    /// default ceiling on purpose: S2 clamps it there, and the stages after S2 then get to push it
    /// back up (that is the whole question this test file answers).
    private func blocks(values: [Float] = [0.02, 0.30, 1.4, 8.0],
                        width: Int = 256, height: Int = 64) -> LinearImage {
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

    /// §1's document: everything after S2 that can lift a highlight, all at once.
    private func pushDocument() -> EditModel {
        var e = EditModel.neutral
        e.light.contrast = 40
        e.color.saturation = 60
        e.effects.clarity = 60
        e.effects.grain = 40
        e.colorGrading.highlights = GradeWheel(hue: 0, saturation: 0, lightness: 40)
        return e
    }

    /// The same document **without** the two tail passes that carry their own ceiling guard
    /// (`s3_8_detail_fx`, `s3_7_grain` both clamp at `DisplayOptions.highlightCeiling`). Those two
    /// guards are why doc A ends at the ceiling and only the primaries matrix can push it over; here
    /// nothing clamps between 分级 and S4, so the overshoot the later stages create survives to the
    /// exit — the second, independent way the old picture was brighter than its own ceiling.
    private func unguardedPushDocument() -> EditModel {
        var e = EditModel.neutral
        e.light.contrast = 40
        e.color.saturation = 60
        e.colorGrading.highlights = GradeWheel(hue: 0, saturation: 0, lightness: 40)
        return e
    }

    /// The last block is a saturated red: the probe should show the push document's own overshoot
    /// *and* the matrix mixing on the same frame.
    private func pushFixture() -> LinearImage {
        let width = 256, height = 64
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                switch x * 4 / width {
                case 0: rgba[o] = 0.02; rgba[o + 1] = 0.02; rgba[o + 2] = 0.02
                case 1: rgba[o] = 0.30; rgba[o + 1] = 0.30; rgba[o + 2] = 0.30
                case 2: rgba[o] = 1.40; rgba[o + 1] = 1.10; rgba[o + 2] = 0.80
                default: rgba[o] = 8.0                                        // saturated red
                }
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    // MARK: - measuring

    private struct Measurement {
        let peak: Double          // max channel, linear
        let over: Int             // pixels with any channel above `ceiling × (1 + slack)`
        let pixels: Int
    }

    private func measure(_ img: DisplayImage, decode: Bool = false) -> Measurement {
        var peak = 0.0
        var over = 0
        let threshold = ceiling * (1 + slack)
        for o in stride(from: 0, to: img.rgba.count, by: 4) {
            var p = 0.0
            var hot = false
            for c in 0..<3 {
                let raw = Double(img.rgba[o + c])
                let v = decode ? Self.srgbToLinear(raw) : raw
                p = max(p, v)
                if v > threshold { hot = true }
            }
            peak = max(peak, p)
            if hot { over += 1 }
        }
        return Measurement(peak: peak, over: over, pixels: img.rgba.count / 4)
    }

    private static func srgbToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// The texture the stage **before** `stopBefore` wrote, in the working (linear Rec.2020) primaries:
    /// no matrix, no OETF, no headroom. `readback` is a half-float copy, so these are the stage's own
    /// numbers.
    private func boundary(_ g: RenderGraph, _ edit: EditModel, before stage: RenderStage) throws
        -> Measurement {
        let r = try g.render(edit, options: RenderOptions(
            scale: 1, display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16),
            useCache: false, wantsPixels: true, stopBefore: stage))
        return measure(try XCTUnwrap(r.display))
    }

    /// The **screen** exit: `s4_display`, decoded back to linear.
    private func screenExit(_ g: RenderGraph, _ edit: EditModel, ceiling c: Double) throws
        -> Measurement {
        let r = try g.render(edit, options: RenderOptions(
            scale: 1, display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16,
                                              highlightCeiling: c),
            useCache: false, wantsPixels: true))
        return measure(try XCTUnwrap(r.display), decode: true)
    }

    /// The **HDR export** exit: `s4_display_linear`.
    private func linearExit(_ g: RenderGraph, _ edit: EditModel, ceiling c: Double) throws
        -> Measurement {
        var d = DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16, highlightCeiling: c)
        d.linearOutput = true
        let r = try g.render(edit, options: RenderOptions(
            scale: 1, display: d, useCache: false, wantsPixels: true))
        return measure(try XCTUnwrap(r.display))
    }

    // MARK: - §1 the probe table

    /// One row per stage boundary, printed for two documents (§1's push document, and the same one
    /// without the two tail guards). Every row but the last two comes from `stopBefore`, i.e. the
    /// texture that stage wrote, in the working primaries: no matrix, no OETF, no headroom.
    private func probeRows(_ g: RenderGraph, _ edit: EditModel, tag: String) throws
        -> [(String, Measurement)] {
        let rows: [(String, Measurement)] = [
            ("\(tag) afterS1",          try boundary(g, edit, before: .sharpen)),
            ("\(tag) afterSharpen",     try boundary(g, edit, before: .maskAtlas)),
            ("\(tag) afterToneMap",     try boundary(g, edit, before: .contrast)),
            ("\(tag) afterContrast",    try boundary(g, edit, before: .color)),
            ("\(tag) afterColor",       try boundary(g, edit, before: .bw)),
            ("\(tag) afterGrade",       try boundary(g, edit, before: .detailFX)),
            ("\(tag) afterDetailFX",    try boundary(g, edit, before: .grain)),
            ("\(tag) afterGrain",       try boundary(g, edit, before: .display)),
            ("\(tag) afterDisplay/screen", try screenExit(g, edit, ceiling: ceiling)),
            ("\(tag) afterDisplay/HDR",    try linearExit(g, edit, ceiling: ceiling)),
        ]
        return rows
    }

    private func printTable(_ rows: [(String, Measurement)]) {
        for (name, m) in rows {
            let label = name.padding(toLength: 26, withPad: " ", startingAt: 0)
            print(String(format: "503 probe · %@ %8.4f  %6d/%-6d", label,
                         m.peak, m.over, m.pixels))
        }
    }

    /// Prints the table and asserts only that both documents are worth measuring: doc B must reach the
    /// exit above the ceiling, doc A must reach it **at** the ceiling (its overshoot is the matrix's).
    func testTheProbeTable() throws {
        let g = try graph(pushFixture(), "503-probe")
        print(String(format: "503 probe · ceiling %.4f (2^2.3 EV) · slack %.6f · "
                     + "over = any channel > ceiling×(1+slack)", ceiling, slack))
        print("503 probe · segment                        peak   over/pixels")

        let guarded = try probeRows(g, pushDocument(), tag: "A")
        printTable(guarded)
        let unguarded = try probeRows(g, unguardedPushDocument(), tag: "B")
        printTable(unguarded)

        // Doc B: nothing clamps between 分级 and S4, so the stages' overshoot is still there when S4
        // reads the texture — the exit clamp is the only thing that can stop it.
        XCTAssertGreaterThan(unguarded[7].1.peak, ceiling,
                             "§1 doc B: the stages after S2 push the picture over the ceiling and "
                             + "nothing clamps it back before S4")
        XCTAssertGreaterThan(unguarded[7].1.over, 0, "§1 doc B: …and some pixel is above it")

        // Doc A: the tail guards (S3.9 清晰度 / S3.7 颗粒) clamp at the ceiling, so the texture S4
        // reads is at the ceiling — and before 503 the matrix alone still lifted it over (measured:
        // 4.9219 in, 7.4644 out). Both exit rows are now at the ceiling.
        XCTAssertLessThanOrEqual(guarded[7].1.peak, ceiling * (1 + slack),
                                 "§1 doc A: S3.9/S3.7's guards leave the texture at the ceiling")
        XCTAssertLessThanOrEqual(guarded[9].1.peak, ceiling * (1 + slack),
                                 "§1 doc A: the exit stays at the ceiling (was 7.4644 before 503)")
        XCTAssertEqual(guarded[9].1.over, 0, "§1 doc A: nothing above it at the exit")
    }

    // MARK: - §1b the same table on the reference frame

    /// The synthetic blocks are the fixture that overshoots; the reference photograph answers the
    /// other question — does an ordinary RAW with the same document reach its ceiling at all?
    func testTheProbeTableOnTheReferenceFrame() throws {
        let path = NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no RAW fixture at \(path)")
        }
        let image = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                            options: DecodeOptions(decoderVersion: nil, scale: 0.0625))
        let g = try graph(image, "503-raw-probe")
        printTable(try probeRows(g, pushDocument(), tag: "RAW"))
        let exit = try screenExit(g, pushDocument(), ceiling: ceiling)
        XCTAssertEqual(exit.over, 0, "the reference frame's exit is at or below the ceiling too")

        // …and with +3 EV the same photograph *does* cross it, so the guarantee is load-bearing on a
        // real frame and not only on synthetic blocks.
        var exposed = pushDocument()
        exposed.light.exposure = 3
        let rows = try probeRows(g, exposed, tag: "RAW+3EV")
        printTable(rows)
        // After 分级 (row 5) is where it shows: 25154 of 235620 pixels over. Rows 6/7 are at the
        // ceiling again because S3.9/S3.7 carry the same guard — that is the "mid-chain clip" 503 is
        // about: only those two passes were enforcing it, and only where they happen to run.
        XCTAssertGreaterThan(rows[5].1.over, 0, "at +3 EV 分级 pushes the photograph over")
        XCTAssertLessThanOrEqual(rows[7].1.peak, ceiling * (1 + slack),
                                 "…and S3.9/S3.7's own guards bring it back to the ceiling")
        XCTAssertEqual(rows[9].1.over, 0, "…while the exit stops it at the ceiling for every document")
    }

    // MARK: - §2 both exits

    func testBothExitsStopAtTheCeiling() throws {
        let g = try graph(pushFixture(), "503-exits")
        let edit = unguardedPushDocument()

        // The precondition, measured: what S4 is handed is above the ceiling.
        let handed = try boundary(g, edit, before: .display)
        XCTAssertGreaterThan(handed.peak, ceiling,
                             "precondition: the texture S4 reads is over the ceiling")

        let screen = try screenExit(g, edit, ceiling: ceiling)
        let linear = try linearExit(g, edit, ceiling: ceiling)
        print(String(format: "503 exits · handed %.4f (%d over) · screen %.4f (%d over) · "
                     + "HDR %.4f (%d over)", handed.peak, handed.over,
                     screen.peak, screen.over, linear.peak, linear.over))

        // The screen exit stores a half float of the **encoded** value: the decode round trip is worth
        // ~1e-3 relative, and the clamp's own half-float quantisation is the 1/2048 above.
        XCTAssertLessThanOrEqual(screen.peak, ceiling * (1 + 0.001),
                                 "s4_display (屏幕) must stop at the picture's ceiling")
        XCTAssertEqual(screen.over, 0, "…with no pixel above it")
        XCTAssertLessThanOrEqual(linear.peak, ceiling * (1 + slack),
                                 "s4_display_linear (HDR 导出) must stop at the same ceiling")
        XCTAssertEqual(linear.over, 0, "…with no pixel above it")
    }

    // MARK: - §2b after the matrix, not before it

    /// Doc A hands S4 a texture that is entirely **at or below** the ceiling, and the exit still comes
    /// out at 7.46 (measured before this change): `Rec2020 → sRGB`'s R row is `(1.6605, −0.5876,
    /// −0.0728)`, and S2's per-channel clamp left this pixel's Rec2020 triple non-saturated, so the
    /// mix lifts R by 1.5×. A clamp in front of the matrix is a no-op on that texture; only one behind
    /// it keeps the promise. (The same argument 075 used for the *lower* clamp.)
    func testTheMatrixCannotMixPastTheCeiling() throws {
        let g = try graph(pushFixture(), "503-mixing")
        let handed = try boundary(g, pushDocument(), before: .display)
        let screen = try screenExit(g, pushDocument(), ceiling: ceiling)
        let linear = try linearExit(g, pushDocument(), ceiling: ceiling)
        print(String(format: "503 mixing · handed %.4f · screen %.4f · HDR %.4f · ceiling %.4f",
                     handed.peak, screen.peak, linear.peak, ceiling))
        XCTAssertLessThanOrEqual(handed.peak, ceiling * (1 + slack),
                                 "doc A's texture is already at the ceiling when S4 reads it")
        XCTAssertLessThanOrEqual(screen.peak, ceiling * (1 + 0.001),
                                 "the matrix's own mix must not escape the ceiling (screen)")
        XCTAssertLessThanOrEqual(linear.peak, ceiling * (1 + slack),
                                 "…nor from the HDR export")
    }

    // MARK: - §2c the zero sentinel

    /// `p.a.z == 0` is **"caller predates 503"**, not a ceiling of 0: without the `> 0` guard in the
    /// kernel, a sentinel render would come out black. A real ceiling is `2^0 = 1` at the lowest
    /// (`HighlightCeiling.evRange`), so the two can never be confused. Measured: the sentinel lets the
    /// exit through at the pre-503 value while `ceiling = 4.0` truncates it.
    ///
    /// (Both renders pass 0 / 4.0 as `DisplayOptions.highlightCeiling`, so S2 falls back to its own
    /// historical 4.0 in both — the only difference measured here is S4's.)
    func testTheZeroSentinelMeansNoTruncation() throws {
        let g = try graph(pushFixture(), "503-sentinel")
        let sentinel = try screenExit(g, unguardedPushDocument(), ceiling: 0)
        let atFour = try screenExit(g, unguardedPushDocument(), ceiling: 4.0)
        print(String(format: "503 sentinel · ceiling 0 → %.4f · ceiling 4.0 → %.4f",
                     sentinel.peak, atFour.peak))
        XCTAssertGreaterThan(sentinel.peak, 4.0 * 1.05,
                             "0 means \"caller predates 503\": no extra truncation at the exit")
        XCTAssertLessThanOrEqual(atFour.peak, 4.0 * (1 + 0.001),
                                 "…while a real ceiling (4.0) still truncates")
    }

    // MARK: - §3 at-or-below the ceiling is byte-identical

    /// §3.3 — a wider ceiling may not move a single byte of a picture that already fits under the
    /// narrower one. The reference frame at exposure 0 peaks near 0.78 (linear), far below 2^2.3.
    func testPixelsAtOrBelowTheCeilingAreByteIdentical() throws {
        let path = NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw XCTSkip("no RAW fixture at \(path)")
        }
        let image = try RAWDecoder().decode(URL(fileURLWithPath: path),
                                            options: DecodeOptions(decoderVersion: nil, scale: 0.0625))
        let g = try graph(image, "503-byte-identity")

        func digest(_ c: Double) throws -> (String, Measurement) {
            let r = try g.render(.neutral, options: RenderOptions(
                scale: 1, display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16,
                                                  highlightCeiling: c),
                useCache: false, wantsPixels: true))
            let img = try XCTUnwrap(r.display)
            return (img.sha256(), measure(img, decode: true))
        }

        let (narrow, narrowM) = try digest(ceiling)
        let (wideSHA, wideM) = try digest(wide)
        print("503 byte-identity · exp 0 peak \(String(format: "%.4f", narrowM.peak)) · "
              + "@2.3EV \(narrow) · @4.0EV \(wideSHA)")
        XCTAssertLessThan(narrowM.peak, ceiling, "the fixture must sit under the narrow ceiling")
        XCTAssertEqual(narrow, wideSHA,
                       "a pixel at or below the ceiling cannot be moved by raising it")
        XCTAssertEqual(narrowM.over, 0)
        XCTAssertEqual(wideM.over, 0)
    }

    // MARK: - §4 the plot and the readout agree

    /// §3.4 — on a neutral ramp pushed to the ceiling, the histogram's top non-zero bin and the
    /// pointer's readout are the same number (the histogram measures the pre-S4 texture; it is not a
    /// second clamp). Grey blocks, so the luma series the plot draws *is* the channel value.
    func testTheHistogramTopAndThePointerReadoutAgree() throws {
        let g = try graph(blocks(), "503-readout")
        var edit = EditModel.neutral
        edit.light.exposure = 5
        let r = try g.render(edit, options: RenderOptions(
            scale: 1,
            display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 16,
                                    highlightCeiling: ceiling),
            useCache: false, wantsPixels: false,
            collectHistogram: true, histogramSampleLongEdge: Histogram.frameSampleLongEdge))
        let h = try XCTUnwrap(r.histogram)

        var topEV = -1.0
        for i in stride(from: h.luma.hdrBins.count - 1, through: 0, by: -1) where h.luma.hdrBins[i] > 0 {
            topEV = (Double(i) + 0.5) / Double(Histogram.hdrBinsPerStop)
            break
        }
        var readoutPeak = 0.0
        if let s = r.histogramSample {
            for o in stride(from: 0, to: s.rgba.count, by: 4) {
                for c in 0..<3 { readoutPeak = max(readoutPeak, Double(s.rgba[o + c])) }
            }
        }
        let readoutEV = log2(max(readoutPeak, 1e-9))
        print(String(format: "503 readout · top bin %.3f EV · pointer %.3f EV · ceiling %.3f EV",
                     topEV, readoutEV, log2(ceiling)))
        XCTAssertEqual(topEV, log2(ceiling), accuracy: 1.0 / 64.0,
                       "the histogram's top is the ceiling, within one 1/64-stop bin")
        XCTAssertEqual(readoutEV, log2(ceiling), accuracy: 0.02,
                       "the pointer reads the same ceiling")
    }
}
