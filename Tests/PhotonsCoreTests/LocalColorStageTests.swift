import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 派单 056 — a mask's **hue and saturation** run in the display-referred domain (S3.5), from the
/// same `color_hsl.metal` include the global S3 colour stage compiles.
///
/// Four questions, in the order they can lie:
///
/// 1. **Is it one implementation?** The kernel text says so (`s3_color.metal` and
///    `s3_5_local_color.metal` both `#include "color_hsl.metal"`; `s1_6_local.metal` carries neither
///    hue nor saturation any more), and the pixels say so: a mask covering the whole canvas at
///    saturation +40 must equal the global saturation slider at +40, code for code.
/// 2. **Does a document without local colour notice anything?** No stage in the trace, no link in the
///    key chain, the same pixels. The key claim is textual and is asserted verbatim.
/// 3. **Is the domain right?** Local exposure must equal *global exposure* (the one control that is
///    known to be scene-linear and pre-S2), and local saturation must equal *global saturation*
///    (known to be post-S2). Those two equalities place the two local sliders on opposite sides of
///    the tone map without either test having to know S2's formula.
/// 4. **The rules S1.6 already had**: the letterbox stays exactly 0, the coverage is the atlas's own
///    (also in portrait), `amount`/opacity still lerp, and 0/0 does not create a stage.
final class LocalColorStageTests: XCTestCase {

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func kernelText(_ name: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent("Sources/PhotonsCore/Kernels/\(name).metal")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// `width × height`, per pixel `body(x, y)` → scene-linear RGB.
    private func picture(_ width: Int, _ height: Int, identity: String = "local-colour",
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
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-056")
    }

    /// A colour wheel: every hue once, three lightness bands, all of it below white so the HDR
    /// normalisation is exactly 1 and the comparison is about HSL, not about headroom.
    private func colourWheel(width: Int = 64, height: Int = 48) -> LinearImage {
        picture(width, height) { x, y in
            let h = Double(x) / Double(max(width - 1, 1))
            let l = 0.28 + 0.44 * Double(y) / Double(max(height - 1, 1))
            return Self.hslToRGB(h: h, s: 0.72, l: l)
        }
    }

    /// Pixels whose hue sits **exactly on a band centre**, several saturations and lightnesses. These
    /// are the pixels where the global eight-band hue slider has weight 1 (its tents sum to ≥ 1 and
    /// are renormalised), so "all eight bands at +30" is a uniform +9° there — which is what makes an
    /// exact comparison against the local hue possible.
    private func bandCentrePicture() -> LinearImage {
        let centres: [Double] = ColorGroup.bandCentresDegrees
        let shades: [(s: Double, l: Double)] = [(0.85, 0.30), (0.85, 0.50), (0.85, 0.70),
                                                (0.55, 0.40), (0.55, 0.60), (0.99, 0.35),
                                                (0.99, 0.62)]
        // Square, so the radius-1.5 radial below covers every pixel including the corners.
        let side = centres.count * shades.count
        return picture(side, side) { x, y in
            let band = centres[x % centres.count]
            let shade = shades[(x / centres.count) % shades.count]
            _ = y
            // Built **in the working primaries** (075 option A): the centres are Rec.2020 hue angles,
            // so a colour made with `hslToRGB` in sRGB would sit up to 0.3° off its own centre and the
            // band tent would weight it 0.99 instead of 1 — a fixture that cannot tell "the band is
            // right" from "the band is nearly right". Converting back through `fromWorking` keeps the
            // frame a plain linear-sRGB decode, which is what the graph's input is.
            let w = Self.hslToRGB(h: band / 360.0, s: shade.s, l: shade.l)
            let s = Self.fromWorking.applying(to: SIMD3(w.0, w.1, w.2))
            return (s.x, s.y, s.z)
        }
    }

    private func flat(_ value: Double, width: Int = 48, height: Int = 48) -> LinearImage {
        picture(width, height) { _, _ in (value, value, value) }
    }

    /// The predicate that makes S3.5 exist: a radial big enough to cover every pixel of a square
    /// frame (its radius is measured in short-edge units, and the frame's corners are 0.707 away).
    private func fullCanvasMask(id: String = "m-all",
                                _ adjustments: LocalAdjustments) -> Mask {
        Mask(id: id,
             components: [MaskComponent(id: "c", feather: 0,
                                        shape: .radialGradient(RadialGradientShape(
                                            center: NormalizedPoint(0.5, 0.5),
                                            radius: NormalizedPoint(1.5, 1.5))))],
             adjustments: adjustments)
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel,
                         canvas: ImageSize? = nil,
                         headroom: Double = 1) throws -> DisplayImage {
        let options = RenderOptions(canvas: canvas, scale: 1,
                                    display: DisplayOptions(headroom: headroom),
                                    wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    // MARK: - independent colour maths (double precision, no kernel involved)

    private static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        func channel(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6.0 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3.0 { return p + (q - p) * (2.0 / 3.0 - t) * 6 }
            return p
        }
        if s < 1e-9 { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        return (channel(p, q, h + 1.0 / 3.0), channel(p, q, h), channel(p, q, h - 1.0 / 3.0))
    }

    private static func rgbToHSL(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, l: Double) {
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        let l = (mx + mn) * 0.5
        let d = mx - mn
        if d < 1e-9 { return (0, 0, l) }
        let s = l > 0.5 ? d / max(2 - mx - mn, 1e-9) : d / max(mx + mn, 1e-9)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h / 6, s, l)
    }

    /// sRGB OETF / EOTF — S4 encodes, so measuring a hue or a difference has to decode first.
    private static func encode(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    private static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// The 8-bit code of a display channel (`DisplayImage` stores the encoded 0…1 float).
    private static func code(_ v: Float16) -> Int {
        Int((Double(v) * 255).rounded())
    }

    /// Per-pixel 8-bit differences over the RGB channels of two frames.
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

    /// Hue in degrees of a display pixel, after undoing S4's encode.
    /// A display pixel, back in the **working primaries** — the space the hue/saturation controls are
    /// defined in (075, option A). Measuring a hue shift on the display codes instead would compare a
    /// 9° rotation *in Rec.2020* against a rotated triple read in sRGB, and the basis change alone
    /// turns that into 11.1° — which is a property of the measurement, not of the control.
    private func workingPixel(_ img: DisplayImage, _ index: Int) -> (Double, Double, Double) {
        let v = SIMD3(Self.decode(Double(img.rgba[index * 4])),
                      Self.decode(Double(img.rgba[index * 4 + 1])),
                      Self.decode(Double(img.rgba[index * 4 + 2])))
        let w = Self.toWorking.applying(to: v)
        return (w.x, w.y, w.z)
    }

    /// sRGB ↔ working, once, from `ColorPrimaries` (never hand-written literals).
    private static let toWorking = ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)
    private static let fromWorking = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB)

    private func hueDegrees(_ img: DisplayImage, _ index: Int) -> Double {
        let (r, g, b) = workingPixel(img, index)
        return Self.rgbToHSL(r, g, b).h * 360
    }

    private func saturation(_ img: DisplayImage, _ index: Int) -> Double {
        let (r, g, b) = workingPixel(img, index)
        return Self.rgbToHSL(r, g, b).s
    }

    /// Signed difference of two hues, in −180…180 degrees (circular, so 359° → 7° is +8°).
    private static func hueDelta(_ from: Double, _ to: Double) -> Double {
        var d = to - from
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        return d
    }

    // MARK: - ① one implementation, by the text

    /// The shared maths is one file, and both kernels compile it. This is the only claim in this
    /// suite that is not about pixels, and it is the reason the pixels can be expected to agree: a
    /// second copy of `rgb_to_hsl` would drift the day someone touches one of them.
    ///
    /// 076 moved the eight **hue bands** out of this include and out of S3: they are S3.6's
    /// (`s3_6_hsl.metal`), on OKLCh. What remains shared here is exactly the pair S3 and S3.5 both
    /// need — one RGB↔HSL conversion and the two slider mappings — and the assertion follows the code:
    /// the band helper must be *gone* from the include and must not reappear in either kernel.
    func testBothColourStagesCompileTheSameHSLInclude() throws {
        let shared = try kernelText("color_hsl")
        for fn in ["rgb_to_hsl", "hue_channel", "hsl_to_rgb", "hsl_hue_turns",
                   "hsl_rotate_hue", "hsl_scale_saturation"] {
            XCTAssertTrue(shared.contains("static inline"), "the include must only define inline helpers")
            XCTAssertTrue(shared.contains(fn), "color_hsl.metal must define \(fn)")
        }
        XCTAssertFalse(shared.contains("hsl_band_shift"),
                       "the eight bands are S3.6's now (076): they are not HSL maths")

        for kernel in ["s3_color", "s3_5_local_color"] {
            let text = try kernelText(kernel)
            XCTAssertTrue(text.contains("#include \"color_hsl.metal\""),
                          "\(kernel).metal must compile the shared HSL include")
            XCTAssertFalse(text.contains("static inline float3 rgb_to_hsl"), "\(kernel).metal must not keep a copy")
            XCTAssertFalse(text.contains("hsl_band_shift"), "\(kernel).metal must not re-grow the band maths")
        }

        // S3.6 is self-contained on purpose: its maths is OKLCh, and OKLCh ≠ HSL.
        let hsl = try kernelText("s3_6_hsl")
        XCTAssertTrue(hsl.contains("kernel void s3_6_hsl"), "S3.6 must exist as its own kernel")
        XCTAssertFalse(hsl.contains("#include \"color_hsl.metal\""),
                       "S3.6 must not pretend to share HSL maths it does not use")
        XCTAssertTrue(hsl.contains("0.3"), "the hue unit (0.3° per unit) must be in the kernel")

        // S1.6 no longer consumes hue/saturation at all — the struct's third float4 is
        // `blacks, contrast travel, pad, enabled` (079 §2.1.2 took the second pad slot for the travel
        // the contrast bend needs; it is a number for the tone bodies, not a colour field).
        let local = try kernelText("s1_6_local")
        XCTAssertFalse(local.contains("hueDegrees"), "the hue field must be gone from the descriptor")
        XCTAssertFalse(local.contains("rotate_about_grey"), "the linear-domain rotation is gone")
        XCTAssertFalse(local.contains("float3(grey)"), "the mix-towards-grey saturation is gone")
        XCTAssertTrue(local.contains("blacks, contrast travel"),
                      "the S1.6 descriptor keeps its stride and drops the two colour fields")
        XCTAssertTrue(local.contains("tone_contrast") && local.contains("region_weights")
                      && local.contains("s1_end_points"),
                      "079: the tone sliders must come from the global include, not a local copy")
        XCTAssertFalse(local.contains("smoothstep(0.0, 0.5"), "the linear-luma window is gone")
        XCTAssertFalse(local.contains("pow(max(v, 1e-6)"), "the linear-light contrast power is gone")
    }

    // MARK: - ② the stage exists by value, and only then

    /// 派单 056 §验收 1 + 7: the predicate is *a mask with hue ≠ 0 or saturation ≠ 0*, never "there is
    /// a mask". A document with only local exposure must keep the pre-056 nine-stage pipeline, the
    /// pre-056 key chain and its pixels.
    func testStageAppearsOnlyWhenAMaskCarriesColour() throws {
        let image = rampImageForKeys()

        func links(_ edit: EditModel) -> RenderKeyChain.Links {
            RenderKeyChain.links(identity: "056", sourceSize: ImageSize(width: 640, height: 480),
                                 canvas: ImageSize(width: 320, height: 240),
                                 content: ImageSize(width: 320, height: 240),
                                 edit: edit, display: DisplayOptions())
        }

        var exposureOnly = EditModel.neutral
        exposureOnly.masks = [fullCanvasMask(LocalAdjustments(exposure: 0.5))]
        XCTAssertFalse(exposureOnly.hasLocalColor)
        XCTAssertEqual(links(exposureOnly).pipeline.count, 9)
        XCTAssertNil(links(exposureOnly).localColor, "no local colour: the link must not exist")
        // …and the chain is the pre-056 one: the vignette is seeded by `color`, not by a stage that
        // does not exist. `KeyBuilder` is the same digester the graph uses, so this is the literal
        // bytes a cached frame would be keyed on.
        XCTAssertEqual(links(exposureOnly).vignette,
                       KeyBuilder(KeyBuilder.digest(of: links(exposureOnly).color))
                           .add(exposureOnly.keyMaterial(.vignette)).canonical)
        // The mask keys themselves are untouched: no local colour never means "no mask stages".
        XCTAssertNotNil(links(exposureOnly).maskAtlas)
        XCTAssertNotNil(links(exposureOnly).localApply)

        var coloured = exposureOnly
        coloured.masks[0].adjustments.saturation = 40
        XCTAssertTrue(coloured.hasLocalColor)
        XCTAssertEqual(links(coloured).pipeline.count, 10)
        XCTAssertNotNil(links(coloured).localColor)
        XCTAssertEqual(coloured.keyMaterial(.color), exposureOnly.keyMaterial(.color),
                       "S3's own material must not move: the local pass is a stage of its own")
        XCTAssertNotEqual(links(coloured).vignette, links(exposureOnly).vignette,
                          "a new stage between S3 and the vignette must reach the vignette's key")
        XCTAssertEqual(links(coloured).pipeline.lastIndex(of: .localColor)!,
                       links(coloured).pipeline.firstIndex(of: .color)! + 1,
                       "S3.5 must sit immediately after S3")
        XCTAssertLessThan(links(coloured).pipeline.firstIndex(of: .vignette)!,
                          links(coloured).pipeline.firstIndex(of: .color)!,
                          "116: the vignette is the last linear pass, before S2/S3")

        // Identity is by value: 0/0 is not colour, a disabled mask is not colour, and neither is a
        // document with no masks at all.
        var zero = EditModel.neutral
        zero.masks = [fullCanvasMask(LocalAdjustments(exposure: 1))]
        XCTAssertFalse(zero.hasLocalColor)
        var disabled = coloured
        disabled.masks[0].isEnabled = false
        XCTAssertFalse(disabled.hasLocalColor)
        XCTAssertEqual(links(disabled).pipeline.count, 7, "a disabled mask is not a mask stage either")
        XCTAssertFalse(EditModel.neutral.hasLocalColor)

        // The trace agrees with the key set, which is what makes the two answers one answer.
        let graph = try makeGraph(image, identity: "056-trace")
        let plain = try graph.render(exposureOnly, options: RenderOptions(scale: 1, useCache: false))
        XCTAssertFalse(plain.trace.executed.contains(.localColor))
        XCTAssertFalse(plain.trace.skipped.contains(.localColor))
        XCTAssertNil(plain.keys.localColor)
        XCTAssertEqual(plain.trace.executed.count, 9)

        let withColour = try graph.render(coloured, options: RenderOptions(scale: 1, useCache: false))
        XCTAssertEqual(withColour.trace.executed.map(\.rawValue).joined(separator: " "),
                       "s0-geometry s1-scene-linear s1.5-mask-atlas s1.6-local s1.7-hdr-curve "
                       + "s3-vignette s2-tone-map s3-color s3.5-local-color s4-display")
        XCTAssertNotNil(withColour.keys.localColor)
        print("TRACE exposure only: \(plain.trace.csv)")
        print("TRACE with local colour: \(withColour.trace.csv)")
    }

    private func rampImageForKeys(width: Int = 96, height: Int = 65) -> LinearImage {
        picture(width, height) { x, _ in
            let v = 0.10 + 0.55 * Double(x) / Double(max(width - 1, 1))
            return (v, v * 0.95, v * 0.9)
        }
    }

    /// The stage's cache entry must be keyed by what it reads: the second frame is a hit (same
    /// pixels), and a hue move re-runs it (different pixels) while the atlas is still reused.
    func testLocalColourStageCachesAndInvalidatesCorrectly() throws {
        let image = colourWheel(width: 48, height: 32)
        let graph = try makeGraph(image, identity: "056-cache")

        var edit = EditModel.neutral
        edit.masks = [fullCanvasMask(LocalAdjustments(saturation: 40))]
        let first = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(first.trace.executed.contains(.localColor))

        let again = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(again.trace.skipped.contains(.localColor), "the same document must hit the cache")
        XCTAssertEqual(try XCTUnwrap(first.display).sha256(), try XCTUnwrap(again.display).sha256())

        edit.masks[0].adjustments.hue = 20
        let moved = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(moved.trace.executed.contains(.localColor), "a hue move must re-run S3.5")
        XCTAssertTrue(moved.trace.skipped.contains(.maskAtlas), "…without rebuilding the atlas")
        XCTAssertNotEqual(try XCTUnwrap(first.display).sha256(), try XCTUnwrap(moved.display).sha256())

        // A selection change must reach S3.5 too — the coverage it reads is the atlas's.
        edit.masks[0].components[0].shape = .radialGradient(RadialGradientShape(
            center: NormalizedPoint(0.4, 0.4), radius: NormalizedPoint(0.2, 0.2)))
        let reshaped = try graph.render(edit, options: RenderOptions(scale: 1, wantsPixels: true))
        XCTAssertTrue(reshaped.trace.executed.contains(.localColor))
        XCTAssertTrue(reshaped.trace.executed.contains(.maskAtlas))
        XCTAssertNotEqual(try XCTUnwrap(moved.display).sha256(),
                          try XCTUnwrap(reshaped.display).sha256(),
                          "the same sliders over a different coverage is a different picture")
    }

    /// Slice alignment: with two masks, `colorAdjust[i]` must be the descriptor of the mask whose
    /// coverage is `atlas` slice `i`. The two masks here sit in opposite halves of the frame and only
    /// the second one carries colour, so the coloured half must come out exactly as it does in a
    /// document that has only that mask. An off-by-one would paint the wrong half.
    func testTwoMasksKeepTheAtlasSliceAlignment() throws {
        let image = colourWheel(width: 64, height: 32)
        let graph = try makeGraph(image, identity: "056-slices")

        func disc(_ cx: Double, _ id: String, _ a: LocalAdjustments) -> Mask {
            Mask(id: id,
                 components: [MaskComponent(id: id + "-c", feather: 0,
                                            shape: .radialGradient(RadialGradientShape(
                                                center: NormalizedPoint(cx, 0.5),
                                                radius: NormalizedPoint(0.2, 0.2))))],
                 adjustments: a)
        }

        let exposure = disc(0.25, "m-a", LocalAdjustments(exposure: 1.5))
        let colour = disc(0.75, "m-b", LocalAdjustments(saturation: 70))

        var both = EditModel.neutral
        both.masks = [exposure, colour]
        var onlyColour = EditModel.neutral
        onlyColour.masks = [colour]

        let two = try display(graph, both)
        let one = try display(graph, onlyColour)
        XCTAssertTrue(try graph.render(both, options: RenderOptions(scale: 1, useCache: false))
            .trace.executed.contains(.localColor))

        // Inside the colour disc: identical between the two documents (the exposure disc is elsewhere).
        let cx = Int(0.75 * Double(image.width)), cy = image.height / 2
        let centre = (cy * image.width + cx) * 4
        for c in 0..<3 {
            XCTAssertLessThanOrEqual(
                abs(Self.code(two.rgba[centre + c]) - Self.code(one.rgba[centre + c])), 1,
                "channel \(c) at the colour disc's centre must not depend on the other mask")
        }
        // …and the exposure half really was lifted, so the two documents are not accidentally equal.
        let left = (cy * image.width + Int(0.25 * Double(image.width))) * 4
        let neutral = try display(graph, EditModel.neutral)
        XCTAssertGreaterThan(abs(Self.code(two.rgba[left]) - Self.code(neutral.rgba[left])), 5,
                             "the first mask's exposure must still land in its own half")
    }

    // MARK: - ③ the point of the whole dispatch: local == global

    /// **The acceptance criterion.** A mask covering every pixel at `saturation = +40` and the global
    /// `saturation = +40` must render the same picture — 8-bit differences ≤ 1, which here is 0.
    ///
    /// The feasibility premise is asserted rather than assumed: the atlas coverage really is 1
    /// everywhere (a radius-1.5 radial on a square frame).
    func testFullCanvasSaturationEqualsTheGlobalSaturationSlider() throws {
        let image = colourWheel()
        let graph = try makeGraph(image, identity: "056-sat")

        var global = EditModel.neutral
        global.color.saturation = 40

        var local = EditModel.neutral
        local.masks = [fullCanvasMask(LocalAdjustments(saturation: 40))]

        let coverage = try XCTUnwrap(graph.maskAtlas(local, options: RenderOptions(scale: 1)))
        let minimum = coverage.slices.flatMap { $0 }.min() ?? 0
        XCTAssertGreaterThanOrEqual(minimum, 0.999,
                                    "the fixture must cover the whole frame, or the comparison proves nothing")

        let a = try display(graph, global)
        let b = try display(graph, local)
        let diffs = codeDifferences(a, b)
        let maxDiff = diffs.max() ?? 0
        let differing = diffs.filter { $0 > 0 }.count
        print("SAT +40 · local mask vs global slider: max |Δcode| = \(maxDiff), "
              + "\(differing)/\(diffs.count) channels differ, mean "
              + String(format: "%.4f", Double(diffs.reduce(0, +)) / Double(diffs.count)))
        XCTAssertLessThanOrEqual(maxDiff, 1,
                                 "a full-canvas mask at +40 must equal the global +40 (measured max \(maxDiff) codes)")

        // The frame must actually have changed, or the equality is between two neutral pictures.
        let neutral = try display(graph, EditModel.neutral)
        XCTAssertGreaterThan(try XCTUnwrap(codeDifferences(neutral, b).max()), 20,
                             "the fixture must be colourful enough for +40 to be visible")
    }

    /// The same equality on HDR data, where S3 carries the headroom *around* the HSL maths (divide by
    /// the peak above white, scale back). The local stage has to do that too, or a highlight above
    /// white would be flattened the moment a mask touches saturation.
    func testFullCanvasSaturationEqualsGlobalOnHDRPixels() throws {
        // Half the frame at 2.4× white, half at a saturated mid-tone.
        let image = picture(48, 24) { x, _ in
            x < 24 ? (2.4, 1.6, 0.9) : (0.45, 0.2, 0.12)
        }
        let graph = try makeGraph(image, identity: "056-hdr")
        var global = EditModel.neutral
        global.color.saturation = 60
        var local = EditModel.neutral
        local.masks = [fullCanvasMask(LocalAdjustments(saturation: 60))]

        let a = try display(graph, global, headroom: 4)
        let b = try display(graph, local, headroom: 4)
        let diffs = codeDifferences(a, b)
        let maxDiff = diffs.max() ?? 0
        print("HDR sat +60 · local mask vs global slider: max |Δcode| = \(maxDiff) "
              + "(headroom 4, peak 2.4)")
        XCTAssertLessThanOrEqual(maxDiff, 1,
                                 "the headroom carry must be the same in both stages (measured \(maxDiff))")
        // Both must still be above SDR white, i.e. the HDR range survived.
        let peak = (0..<(b.width * b.height)).map { Double(b.rgba[$0 * 4]) }.max() ?? 0
        XCTAssertGreaterThan(peak, 1.05, "saturation flattened the highlight — the headroom was lost")
    }

    /// **Hue**: the same *unit*, in two different *spaces*.
    ///
    /// 056 could assert a pixel-identity here because the band slider and the mask slider ran the same
    /// HSL arithmetic. 076 moved the bands to OKLCh (079 结论 4: linear-light HSL made `l` mean two
    /// things), so the two controls now rotate in different spaces — a +30 on either is **9.00°**, and
    /// the resulting RGB cannot be identical because "rotate 9° at constant HSL `l`" and "rotate 9° at
    /// constant OKLab `L`" are different curves.
    ///
    /// So this test now holds what is still true and is still worth a sentinel: **the unit is shared**
    /// (0.3° per unit on both sides, measured in each stage's own space), and it reports the pixel
    /// difference that the domain split costs. Unifying the two spaces is 079 §2.6.1's item 5 — the
    /// same move for S3/S3.5's saturation, hue and vibrance — and is not part of 076.
    func testTheBandAndTheMaskShareTheHueUnitNotTheSpace() throws {
        let image = colourWheel(width: 48, height: 32)
        let graph = try makeGraph(image, identity: "076-hue-unit")

        var global = EditModel.neutral
        for i in global.color.bands.indices { global.color.bands[i].hue = 30 }

        var local = EditModel.neutral
        local.masks = [fullCanvasMask(LocalAdjustments(hue: 30))]

        let coverage = try XCTUnwrap(graph.maskAtlas(local, options: RenderOptions(scale: 1)))
        XCTAssertGreaterThanOrEqual(coverage.slices.flatMap { $0 }.min() ?? 0, 0.999,
                                    "the mask must cover the frame, or the comparison proves nothing")

        let neutral = try display(graph, EditModel.neutral)
        let a = try display(graph, global)      // S3.6 — OKLCh
        let b = try display(graph, local)       // S3.5 — HSL

        func unclipped(_ img: DisplayImage, _ i: Int) -> Bool {
            (0..<3).allSatisfy { Double(img.rgba[i * 4 + $0]) < 0.999 }
        }
        var localShift = 0.0, globalShift = 0.0, counted = 0
        for i in 0..<(image.width * image.height) where saturation(neutral, i) > 0.1
            && unclipped(b, i) && unclipped(a, i) {
            let h0 = hueDegrees(neutral, i)
            localShift += Self.hueDelta(h0, hueDegrees(b, i))               // HSL angle
            let w0 = workingPixel(neutral, i), w1 = workingPixel(a, i)
            let o0 = OKLCh.fromLinear(SIMD3(w0.0, w0.1, w0.2)).hue
            let o1 = OKLCh.fromLinear(SIMD3(w1.0, w1.1, w1.2)).hue
            globalShift += Self.hueDelta(o0, o1)                            // OKLCh angle
            counted += 1
        }
        XCTAssertGreaterThan(counted, 20, "the fixture must have coloured pixels")
        let localMean = localShift / Double(counted)
        let globalMean = globalShift / Double(counted)
        let diffs = codeDifferences(a, b)
        print(String(format: "HUE +30 · band (OKLCh) %+.3f°  mask (HSL) %+.3f°  |Δ| %.3f°  (n=%d)",
                     globalMean, localMean, abs(localMean - globalMean), counted)
              + " · pixels differ by up to \(diffs.max() ?? 0) codes"
              + " (\(diffs.filter { $0 > 0 }.count)/\(diffs.count) channels)")
        // The shared fact: one unit is 0.3°, so +30 is 9° on both controls.
        XCTAssertEqual(localMean, 9.0, accuracy: 0.5, "+30 units must be 9° for the mask")
        XCTAssertEqual(globalMean, 9.0, accuracy: 0.5, "+30 units must be 9° for the band")
        // The difference that remains is a *space* difference, and it is recorded rather than denied.
        XCTAssertGreaterThan(diffs.max() ?? 0, 1,
                             "the two controls are in different spaces since 076 — if this drops to "
                             + "≤1 code, someone unified them and this comment is stale")
    }

    // MARK: - ④ the domain, proved against the two global controls

    /// Local **exposure** must equal *global exposure* through a strongly non-linear tone map. The
    /// global exposure is scene-linear and pre-S2 by construction, so this equality is a domain
    /// proof: an exposure applied after S2 could not reproduce it once contrast bends the response.
    /// Local **saturation** must equal the global saturation (post-S2), which the test above pins.
    /// Together they place the mask's exposure at S1.6 and its colour at S3.5.
    func testLocalExposureLandsInTheSameDomainAsGlobalExposure() throws {
        // A coloured mid-tone: neutral grey would make the saturation half a no-op.
        let image = picture(40, 40) { _, _ in (0.34, 0.24, 0.19) }
        let graph = try makeGraph(image, identity: "056-exposure-domain")

        var global = EditModel.neutral
        global.light.exposure = 0.5
        global.light.contrast = 20           // a visibly non-linear S2: 0.48 is not linear in 0.34
        let globalFrame = try display(graph, global)

        var local = EditModel.neutral
        local.light.contrast = 20
        local.masks = [fullCanvasMask(LocalAdjustments(exposure: 0.5))]
        let localFrame = try display(graph, local)

        let centre = (image.height / 2 * image.width + image.width / 2) * 4
        let g = Self.code(globalFrame.rgba[centre])
        let l = Self.code(localFrame.rgba[centre])
        print("EXPOSURE +0.5 EV at contrast 20 · global \(g) vs local \(l) (8-bit red code)")
        XCTAssertGreaterThan(g, 30, "the probe pixel must be measurable, not clipped")
        XCTAssertLessThan(g, 250)
        XCTAssertLessThanOrEqual(abs(l - g), 1,
                                 "+0.5 EV inside a full-canvas mask must equal the global +0.5 EV through "
                                 + "S2 — if the local gain ran after the tone map these could not agree")

        // And a colour mask over the same frame keeps the exposure: both sliders on one mask, in
        // their two stages, is a composition rather than a replacement.
        var both = local
        both.masks[0].adjustments.saturation = 40
        let combined = try display(graph, both)
        XCTAssertNotEqual(Self.code(combined.rgba[centre]), l,
                          "the saturation half must still do something")
    }

    // MARK: - ⑤ the rules S1.6 already had

    /// The letterbox is not a picture: the content-rect guard (S2/S1.7/S3's rule) keeps every pixel
    /// outside it at exactly 0, hue rotation or not. Without the guard a warm mask would tint the bars.
    func testLetterboxStaysExactlyZero() throws {
        let image = colourWheel(width: 64, height: 40)
        let canvas = ImageSize(width: 64, height: 64)
        let graph = try makeGraph(image, identity: "056-matte")

        var local = EditModel.neutral
        local.masks = [fullCanvasMask(LocalAdjustments(hue: -80, saturation: 90))]

        let options = RenderOptions(canvas: canvas, scale: 1, wantsPixels: true)
        let result = try graph.render(local, options: options)
        XCTAssertTrue(result.trace.executed.contains(.localColor), "the guard must be tested on a frame that ran it")
        let frame = try XCTUnwrap(result.display)

        // 64×40 content in a 64×64 canvas: 12 background rows at the top, 12 at the bottom.
        XCTAssertEqual(frame.height, 64)
        var background = 0
        for y in [0, 1, 5, 11, 52, 60, 63] {
            for x in stride(from: 0, to: frame.width, by: 7) {
                let o = (y * frame.width + x) * 4
                XCTAssertEqual(frame.rgba[o], 0, "(\(x), \(y)) row \(y) is background: red must stay 0")
                XCTAssertEqual(frame.rgba[o + 1], 0, "(\(x), \(y)) row \(y) is background: green must stay 0")
                XCTAssertEqual(frame.rgba[o + 2], 0, "(\(x), \(y)) row \(y) is background: blue must stay 0")
                background += 1
            }
        }
        XCTAssertGreaterThan(background, 30)

        // The content did change, so "0 everywhere" is not the reason the guard passed.
        let plain = try display(graph, EditModel.neutral, canvas: canvas)
        XCTAssertGreaterThan(try XCTUnwrap(codeDifferences(plain, frame).max()), 10,
                             "the content rows must have moved under the mask")
    }

    /// Family 3 of the 056 acceptance: the coverage S3.5 reads is **the atlas's own**, in canvas
    /// coordinates, exactly what S1.6 reads — so a portrait frame's ellipse lands where it was drawn
    /// and nothing outside the selection is touched.
    func testCoverageIsTheAtlasOwnAndSurvivesPortraitOrientation() throws {
        // Upright portrait, coloured: a chroma operation has to have something to move.
        let upright = picture(48, 72) { x, y in
            Self.hslToRGB(h: 0.02 + 0.5 * Double(x) / 48, s: 0.62,
                          l: 0.30 + 0.40 * Double(y) / 72)
        }
        // Stored as EXIF 6 (rotate 90° CW to view): the inverse of `sourceCoordinate`.
        let stored = storedPicture(upright, orientation: .right)
        XCTAssertEqual(stored.orientation, .right)

        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-portrait",
                           components: [MaskComponent(id: "c", feather: 0,
                                                      shape: .radialGradient(RadialGradientShape(
                                                        center: NormalizedPoint(0.5, 0.25),
                                                        radius: NormalizedPoint(0.2, 0.2))))],
                           adjustments: LocalAdjustments(saturation: 60))]

        let graphUp = try makeGraph(upright, identity: "056-portrait-up")
        let graphStored = try makeGraph(stored, identity: "056-portrait-stored")
        let upAtlas = try XCTUnwrap(graphUp.maskAtlas(edit, options: RenderOptions(scale: 1)))
        let storedAtlas = try XCTUnwrap(graphStored.maskAtlas(edit, options: RenderOptions(scale: 1)))
        XCTAssertEqual(upAtlas.width, storedAtlas.width)
        XCTAssertEqual(upAtlas.height, storedAtlas.height)
        for i in upAtlas.slices[0].indices {
            XCTAssertEqual(Double(storedAtlas.slices[0][i]), Double(upAtlas.slices[0][i]),
                           accuracy: 1e-3, "the rotated decode must select the same pixels")
        }

        let plain = try display(graphStored, EditModel.neutral)
        let masked = try display(graphStored, edit)
        let trace = try graphStored.render(edit, options: RenderOptions(scale: 1, useCache: false)).trace
        XCTAssertTrue(trace.executed.contains(.localColor), "the stage must have run on the portrait frame")

        var changedX = 0, changedY = 0, changed = 0
        for y in 0..<masked.height {
            for x in 0..<masked.width {
                let i = y * masked.width + x
                let moved = (0..<3).contains { abs(Self.code(masked.rgba[i * 4 + $0]) - Self.code(plain.rgba[i * 4 + $0])) > 0 }
                let coverage = upAtlas.slices[0][i]
                if coverage == 0 {
                    XCTAssertFalse(moved, "(\(x), \(y)) is outside the selection — it must not move")
                }
                if coverage > 0.99 {
                    XCTAssertTrue(moved, "(\(x), \(y)) is fully covered — saturation must reach it")
                    changedX += x; changedY += y; changed += 1
                }
            }
        }
        XCTAssertGreaterThan(changed, 50)
        let cx = Double(changedX) / Double(changed), cy = Double(changedY) / Double(changed)
        print(String(format: "PORTRAIT coverage centroid (%.1f, %.1f) of %dx%d — mask centre was (24.0, 18.0)",
                     cx, cy, masked.width, masked.height))
        XCTAssertEqual(cx, 24.0, accuracy: 1.5, "the selection must land where it was drawn")
        XCTAssertEqual(cy, 18.0, accuracy: 1.5)
    }

    /// The inverse of `ImageOrientation.sourceCoordinate`, so the stored buffer is exactly what a
    /// camera wrote for that tag.
    private func storedPicture(_ upright: LinearImage, orientation: ImageOrientation) -> LinearImage {
        let w = upright.width, h = upright.height
        let stored = orientation.uprightSize(width: w, height: h)
        var rgba = [Float16](repeating: 0, count: stored.width * stored.height * 4)
        for y in 0..<h {
            for x in 0..<w {
                let s = orientation.sourceCoordinate(x: x, y: y,
                                                     width: stored.width, height: stored.height)
                let from = (y * w + x) * 4
                let to = (s.y * stored.width + s.x) * 4
                rgba[to] = upright.rgba[from]
                rgba[to + 1] = upright.rgba[from + 1]
                rgba[to + 2] = upright.rgba[from + 2]
                rgba[to + 3] = upright.rgba[from + 3]
            }
        }
        return LinearImage(width: stored.width, height: stored.height, rgba: rgba,
                           colorSpace: upright.colorSpace, decoderVersion: upright.decoderVersion,
                           orientation: orientation)
    }

    /// `amount` and mask `opacity` still lerp the way S1.6 lerps them — coverage · amount in RGB.
    /// Amount 0 is bit-identical to no mask at all, even with extreme sliders (§3.3).
    func testAmountAndOpacityStillWeightTheAdjustment() throws {
        let image = colourWheel(width: 40, height: 30)
        let graph = try makeGraph(image, identity: "056-amount")
        let plain = try display(graph, EditModel.neutral)

        for (label, adjustments, opacity) in [("amount 0", LocalAdjustments(amount: 0, hue: 80, saturation: 100), 1.0),
                                              ("opacity 0", LocalAdjustments(hue: 80, saturation: 100), 0.0)] {
            var edit = EditModel.neutral
            var mask = fullCanvasMask(adjustments)
            mask.opacity = opacity
            edit.masks = [mask]
            let frame = try display(graph, edit)
            XCTAssertEqual(frame.sha256(), plain.sha256(), "\(label) must be bit-exact against no mask")
        }

        // Full vs half amount: the half-way frame sits between neutral and full, channel by channel.
        var full = EditModel.neutral
        full.masks = [fullCanvasMask(LocalAdjustments(saturation: 80))]
        var half = EditModel.neutral
        half.masks = [fullCanvasMask(LocalAdjustments(amount: 50, saturation: 80))]
        let fullFrame = try display(graph, full)
        let halfFrame = try display(graph, half)
        let i = (image.height / 2 * image.width + image.width / 3) * 4
        let n = Double(plain.rgba[i]), f = Double(fullFrame.rgba[i]), h = Double(halfFrame.rgba[i])
        XCTAssertGreaterThan(abs(f - n), 0.02, "the fixture must move under +80 saturation")
        XCTAssertGreaterThan(abs(h - n), 0.005, "amount 50 must still do something")
        XCTAssertLessThan(abs(h - n), abs(f - n), "amount 50 must be a half measure")
    }

    // MARK: - ⑥ the local claim (zero colour = same pixels), and the cost

    /// ⑥ The **local** claim 056 makes: local colour at strength 0 changes nothing, and local colour at
    /// a real strength changes everything. Both halves are rendered from one tree, so no later task can
    /// expire them.
    ///
    /// What stood here until 2026-10-27 was a digest recorded from the tree *before* 056 (`79a0534e…`),
    /// with the claim "a document without local colour renders the same pixels as before 056". That
    /// claim expired — and not because of 056: 062 rebuilt the curve's axis onto the histogram's scale
    /// (`SDR 50 %` display codes, `HDR 50 %`, `W` gain in log2) and this probe's digest became
    /// `a7890962…`. The curve here is **not** the identity — `(0.4, 0.45)` on the engine axis — so an
    /// axis change *must* move these pixels, and 062 was allowed to move pixels. The two numbers are
    /// kept below as a note, never as an assertion: re-recording "whatever the tree does now" is the
    /// one assertion this test exists to refuse, and 056's real promise is narrower anyway.
    ///
    ///   | tree | digest |
    ///   |---|---|
    ///   | `4aca610` — 056 itself | `79a0534e7ffa6eaf…` |
    ///   | `699cd7f`, `4e17ee0` — present/backdrop/loupe, 曲线端点可移 | `79a0534e…` |
    ///   | `a6248ef`, `36138cf` — after 062 曲线轴对齐直方图 | `a7890962…` |
    ///
    /// The claim 056 actually makes, in three versions of the **same document** (contrast 20, the same
    /// white curve, global saturation 12, vignette −30) differing only in one full-canvas mask:
    ///
    ///   · **① explicit zero** — the mask spells `hue: 0, saturation: 0`;
    ///   · **② absent** — the file never wrote those two keys, so the decoder's default `0` stands;
    ///   · **③ real strength** — the same mask at `hue: +10, saturation: +40`.
    ///
    /// ① and ② must be the same pixels, bit for bit, and neither may put S3.5 in the trace or the key
    /// chain: "0/0 is not colour" (`LocalAdjustments.contributesLocalColor`) is the promise. ③ must
    /// differ — otherwise the equality is also what a renderer that ignored the mask entirely would
    /// produce — and ① must differ from the document with **no mask at all**, which proves the mask's
    /// scene-linear work is live while its zero colour is not.
    func testZeroStrengthLocalColourIsBitExactAndRealColourIsNot() throws {
        let image = colourWheel(width: 64, height: 48)
        let graph = try makeGraph(image, identity: "056-local-claim")

        var base = EditModel.neutral
        base.light.contrast = 20
        base.curve.white = [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.4, v: 0.45), CurvePoint(u: 1, v: 1)]
        base.color.saturation = 12
        base.effects.vignetteAmount = -30

        // ② "the file said nothing": the decoder fills a missing key with 0, which is why "spelled out
        // as 0" and "absent" are the same model value. Asserted, so ① and ② are known to differ only in
        // how the document writes the mask — a value type has no absent field.
        let absent = try JSONDecoder().decode(LocalAdjustments.self, from: Data(
            #"{"amount":100,"exposure":0.6,"contrast":10}"#.utf8))
        let explicitZero = LocalAdjustments(amount: 100, exposure: 0.6, contrast: 10,
                                            hue: 0, saturation: 0)
        XCTAssertEqual(absent, explicitZero, "缺失的 hue/saturation 解码成 0")
        XCTAssertFalse(explicitZero.contributesLocalColor, "0/0 不构成局部色彩")

        var spelledOut = base
        spelledOut.masks = [fullCanvasMask(explicitZero)]
        var silent = base
        silent.masks = [fullCanvasMask(absent)]
        var coloured = base
        coloured.masks = [fullCanvasMask(LocalAdjustments(amount: 100, exposure: 0.6, contrast: 10,
                                                          hue: 10, saturation: 40))]
        var noMask = base
        noMask.masks = []

        struct Shot { let digest: String; let stages: [RenderStage]; let hasLocalColourStage: Bool }
        func shot(_ edit: EditModel) throws -> Shot {
            let result = try graph.render(edit, options: RenderOptions(
                scale: 1, display: DisplayOptions(headroom: 1), useCache: false, wantsPixels: true))
            let frame = try XCTUnwrap(result.display)
            return Shot(digest: frame.sha256(),
                        stages: result.trace.executed,
                        hasLocalColourStage: result.keys.localColor != nil)
        }
        let one = try shot(spelledOut), two = try shot(silent)
        let three = try shot(coloured), none = try shot(noMask)

        XCTAssertEqual(one.digest, two.digest,
                       "① 显式 hue/saturation = 0 与 ② 文件没写它，必须是同一像素")
        XCTAssertNotEqual(one.digest, three.digest,
                          "③ hue +10 / saturation +40 必须动像素（反空洞：不然后面的相等什么也没证明）")
        XCTAssertNotEqual(one.digest, none.digest,
                          "蒙版的场景线性工作（曝光 +0.6 / 对比 +10）确实在场，零色彩不许把整个蒙版关掉")

        XCTAssertFalse(one.hasLocalColourStage, "① 不许在 key chain 里造出 localColor")
        XCTAssertFalse(two.hasLocalColourStage, "② 同上")
        XCTAssertTrue(three.hasLocalColourStage, "③ 才是 S3.5 该存在的理由")
        XCTAssertFalse(one.stages.contains(.localColor))
        XCTAssertFalse(two.stages.contains(.localColor))
        XCTAssertTrue(three.stages.contains(.localColor))
        XCTAssertTrue(one.stages.contains(.localApply), "① 的 S1.6 仍然跑")
        XCTAssertTrue(two.stages.contains(.localApply), "② 的 S1.6 仍然跑")

        print("LOCAL CLAIM · ① explicit-0 \(one.digest) · ② absent \(two.digest)"
              + " · ③ +10/+40 \(three.digest) · no mask \(none.digest)")
        print("LOCAL CLAIM stages · ① \(one.stages.map(\.rawValue).joined(separator: " "))")
    }

    /// 4.10 Mpx, cache off: what the extra stage costs. Printed on every run, asserted only under
    /// `PHOTONS_BENCH=1` (the project rule: a wall-clock number is a note, not a test, unless asked).
    func testLocalColourPassCostAtFourMegapixels() throws {
        let image = colourWheel(width: 2731, height: 1500)   // 4.0965 Mpx ≈ 4.10 Mpx
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let graph = try RenderGraph(input: RenderInput(image: image, identity: "bench-056"))

        func median(_ edit: EditModel, _ n: Int) throws -> Double {
            var times: [Double] = []
            for _ in 0..<n {
                let r = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                     wantsPixels: false))
                if let t = r.output { graph.recycle(output: t) }
                times.append(r.trace.gpuMilliseconds)
            }
            times.sort()
            return times[times.count / 2]
        }

        var exposureOnly = EditModel.neutral
        exposureOnly.masks = [fullCanvasMask(LocalAdjustments(exposure: 0.5))]
        var withColour = exposureOnly
        withColour.masks[0].adjustments.saturation = 40

        _ = try median(exposureOnly, 2)               // warm the pipelines
        // Interleaved, so a drifting machine moves both halves alike: the number reported is the
        // median of the paired differences, not the difference of two medians.
        var deltas: [Double] = []
        var without: [Double] = [], with: [Double] = []
        for _ in 0..<15 {
            let a = try graph.render(exposureOnly, options: RenderOptions(scale: 1, useCache: false,
                                                                        wantsPixels: false))
            if let t = a.output { graph.recycle(output: t) }
            let b = try graph.render(withColour, options: RenderOptions(scale: 1, useCache: false,
                                                                       wantsPixels: false))
            if let t = b.output { graph.recycle(output: t) }
            without.append(a.trace.gpuMilliseconds)
            with.append(b.trace.gpuMilliseconds)
            deltas.append(b.trace.gpuMilliseconds - a.trace.gpuMilliseconds)
        }
        without.sort(); with.sort(); deltas.sort()
        print(String(format: "BENCH 056 · 4.10 Mpx, cache off: 9 stages p50 %.2f ms, "
                     + "10 stages (S3.5 on) p50 %.2f ms, paired Δ (S3.5) p50 %+.2f ms "
                     + "(min %+.2f, max %+.2f, n=15)",
                     without[without.count / 2], with[with.count / 2], deltas[deltas.count / 2],
                     deltas.first ?? 0, deltas.last ?? 0))

        guard ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" else {
            throw XCTSkip("timing printed; set PHOTONS_BENCH=1 to assert the structural ceiling")
        }
        XCTAssertLessThan(with[with.count / 2], 100, "a structural regression, not jitter")
    }
}
