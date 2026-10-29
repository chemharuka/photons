import XCTest
import Metal
import CryptoKit
import PhotonsCore

/// 2026-10-28 — **黑白**: the monochrome conversion (S3.4) and 黑白混合, the per-hue share of the grey.
///
/// P0-4 of `docs/tasks/078-lr-gap-matrix.md`. The suite is organised by the four things that can be
/// wrong, in the order they can lie:
///
///  1. **The conversion.** A monochrome pass that computes its grey *per channel* returns three
///     different numbers — a tinted "black and white". So the channel equality is asserted as a
///     number (max |Δ| over every pixel of a colour wheel, with the sample count and the brightest
///     grey on record), not as "looks grey", and §④ shows the assertion goes red when the kernel is
///     made to commit that mistake.
///  2. **The mix.** The eight bands are S3.6's (same centres, same partition of unity), so a mix at its
///     own band's centre must deliver its full value, a mix on one band must not touch another band's
///     colour **at all** (0 pixels, maxΔ 0), and the slider must be monotone on the three primaries —
///     the property a user actually feels when dragging it.
///  3. **The structure.** A colour document must not encode the pass: no `s3.4` in the trace, no `bw`
///     link in the key chain, no `s3.4-bw=` segment in `RenderInputs.key`, and the frame
///     byte-identical to the pre-S3.4 build — including a document that still carries mix values from
///     a day it *was* black-and-white. §④ runs the pass anyway and shows the byte assertion break.
///  4. **The cost.** 4.10 Mpx, the incremental milliseconds of the pass.
///
/// The CPU reference (`HSLBands.mix`, `HSLBands.gray`) is the definition the kernel is written
/// against; §② compares them end to end so the two cannot drift without a red test.
final class BlackAndWhiteTests: XCTestCase {

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

    private func makeGraph(_ image: LinearImage, identity: String = "bw",
                           bwStageAlwaysRuns: Bool = false) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity),
                               bwStageAlwaysRuns: bwStageAlwaysRuns)
    }

    private func picture(_ width: Int, _ height: Int,
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
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-bw")
    }

    /// Three vertical blocks: pure red, pure green, pure blue — the actual sRGB primaries, 1/3 of the
    /// width each. Their OKLCh hues are 29.23°, 142.50° and 264.05° in the working space, i.e. red and
    /// green sit on their band's centre and blue sits 10.4° off the blue centre (towards aqua). That is
    /// the truth about the wheel, not a defect: a mix value's weight is measured where the *colours*
    /// are (076 §2), so the three blocks need not respond by the same amount — only monotonically.
    private func primaries(width: Int = 96, height: Int = 32) -> LinearImage {
        picture(width, height) { x, _ in
            let third = width / 3
            if x < third { return (1, 0, 0) }
            if x < 2 * third { return (0, 1, 0) }
            return (0, 0, 1)
        }
    }

    private static let toWorking = ColorPrimaries.conversion(from: ColorPrimaries.decoded,
                                                             to: ColorPrimaries.working)
    private static let toSRGB = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB)

    /// A picture whose every column sits at a known **OKLCh** hue at a fixed lightness/chroma: `360`
    /// columns, one degree each. Built by walking OKLCh and converting back — the band centres are
    /// OKLCh angles, so a fixture made with HSL angles would be a different wheel.
    private func hueWheel(height: Int = 48, L: Double = 0.62, C: Double = 0.11) -> LinearImage {
        picture(360, height) { x, _ in
            let working = OKLCh.toLinear(L: L, C: C, hue: Double(x))
            let srgb = Self.toSRGB.applying(to: working)
            return (srgb.x, srgb.y, srgb.z)
        }
    }

    /// A colour frame with a full tonal range: hue around the wheel × lightness down the frame.
    private func colourRamp(width: Int = 240, height: Int = 120) -> LinearImage {
        picture(width, height) { x, y in
            let hue = Double(x) / Double(width) * 360
            let L = 0.18 + 0.72 * (1 - Double(y) / Double(height - 1))
            let working = OKLCh.toLinear(L: L, C: 0.09, hue: hue)
            let srgb = Self.toSRGB.applying(to: working)
            return (srgb.x, srgb.y, srgb.z)
        }
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel,
                         headroom: Double = 1) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: headroom),
                                    useCache: false, wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    private static func code(_ v: Float16) -> Int { Int((Double(v) * 255).rounded()) }

    private func document(blackAndWhite: Bool = true) -> EditModel {
        var edit = EditModel.neutral
        edit.color.blackAndWhite = blackAndWhite
        return edit
    }

    private func document(mix band: Int, _ value: Double) -> EditModel {
        var edit = document()
        edit.color.bands[band].mix = value
        return edit
    }

    /// Mean code of one block of a three-block frame.
    private func blockMean(_ image: DisplayImage, _ block: Int) -> Double {
        let third = image.width / 3
        let x0 = block * third
        let x1 = block == 2 ? image.width : x0 + third
        var sum = 0.0
        var n = 0
        for y in 0..<image.height {
            for x in x0..<x1 {
                let o = (y * image.width + x) * 4
                sum += Double(image.rgba[o])          // a monochrome frame: any channel will do
                n += 1
            }
        }
        return sum / Double(max(n, 1))
    }

    /// The whole block's bytes, so "the other two blocks did not move" can be asserted as pixels.
    private func blockSHA(_ image: DisplayImage, _ block: Int) -> String {
        let third = image.width / 3
        let x0 = block * third
        let x1 = block == 2 ? image.width : x0 + third
        var hasher = SHA256()
        for y in 0..<image.height {
            for x in x0..<x1 {
                let o = (y * image.width + x) * 4
                for c in 0..<3 {
                    withUnsafeBytes(of: image.rgba[o + c]) { hasher.update(bufferPointer: $0) }
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - ① the conversion: one grey, three identical channels

    /// **The hard acceptance.** With 黑白 on, every pixel of a colour frame is monochrome: the maximum
    /// difference between any two channels, over every pixel of a full hue wheel and a full tonal ramp,
    /// must be below `1e-4`.
    ///
    /// The kernel writes **one scalar three times**, so the honest expectation is 0; the threshold is
    /// there because the readback is a `rgba16Float` texture (`DisplayImage.rgba`), where two float32
    /// inputs that differ in the last bit can land in neighbouring half-float buckets — a 1-ULP readback
    /// artefact, not a cast. §④ measures what a real cast looks like (≈ 0.1), three orders larger.
    func testTheThreeChannelsAreEqualAfterTheConversion() throws {
        let image = colourRamp()
        let graph = try makeGraph(image, identity: "bw-equal")
        let out = try display(graph, document())

        var worst = 0.0
        var brightest = 0.0
        for i in 0..<(out.width * out.height) {
            let r = Double(out.rgba[i * 4]), g = Double(out.rgba[i * 4 + 1])
            let b = Double(out.rgba[i * 4 + 2])
            worst = max(worst, max(abs(r - g), max(abs(g - b), abs(r - b))))
            brightest = max(brightest, r)
        }
        let samples = out.width * out.height
        print("BW EQUAL · \(samples) pixels, max |Δchannel| \(String(format: "%.2e", worst)),"
              + " brightest grey \(String(format: "%.3f", brightest)) (= code \(Self.code(Float16(brightest))))")
        XCTAssertLessThan(worst, 1e-4, "a monochrome frame cannot carry a cast")
        XCTAssertGreaterThan(brightest, 0.5, "the frame must actually reach the light end, or the test is empty")
    }

    /// The conversion is a **real** conversion: colour in, monochrome out, and the grey is the pixel's
    /// OKLab lightness, not the average of three channels (which would be a different — and wrong —
    /// definition: 079 结论 4).
    func testTheGreyIsThePixelsLightness() throws {
        let image = primaries()
        let graph = try makeGraph(image, identity: "bw-lightness")
        let out = try display(graph, document())
        let third = out.width / 3

        var lines: [String] = []
        for (block, name) in ["红", "绿", "蓝"].enumerated() {
            let x = block * third + third / 2
            let o = (out.height / 2 * out.width + x) * 4
            let got = Double(out.rgba[o])
            let L = OKLCh.fromLinear(
                Self.toWorking.applying(to: block == 0 ? SIMD3(1.0, 0, 0)
                                            : (block == 1 ? SIMD3(0, 1.0, 0) : SIMD3(0, 0, 1.0)))).L
            let expected = L * L * L                           // perceptual L back into linear light
            // The frame is display-encoded, so the comparison is made in the encoded domain.
            func encode(_ v: Double) -> Double {
                let c = min(max(v, 0), 1)
                return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            XCTAssertEqual(got, encode(expected), accuracy: 0.02,
                           "\(name): the grey must be the pixel's OKLab L, cubed")
            lines.append("\(name) L \(String(format: "%.3f", L)) → code \(Self.code(out.rgba[o]))")
        }
        print("BW LIGHTNESS · " + lines.joined(separator: " · "))
    }

    /// A neutral pixel has no hue, so no mix can move it: `gate = 0` ⇒ `mix = 0` ⇒ `exp2(0) = 1`, and
    /// every mix value renders the *same* bytes. (The conversion itself is nearly the identity on a
    /// grey — `L³` returns the pixel it came from up to a cube root and back — but "nearly" is not what
    /// is asserted here; this test is about the gate, which is exact.)
    func testANeutralFrameIsUntouchedByTheMix() throws {
        let image = picture(32, 32) { x, _ in
            let v = 0.05 + Double(x) / 32 * 0.55               // a neutral ramp, not a flat patch
            return (v, v, v)
        }
        let graph = try makeGraph(image, identity: "bw-neutral")
        let plain = try display(graph, document())             // 黑白 on, every mix at 0
        let colour = try display(graph, EditModel.neutral)

        // The conversion is near-identity on a neutral frame (L³ round trip): report how near.
        var worst = 0
        for i in 0..<(plain.width * plain.height) {
            for c in 0..<3 {
                worst = max(worst, abs(Self.code(plain.rgba[i * 4 + c])
                                       - Self.code(colour.rgba[i * 4 + c])))
            }
        }
        print("BW NEUTRAL · switch on: a grey ramp's max |Δcode| against the colour frame = \(worst)")
        XCTAssertLessThanOrEqual(worst, 1, "the conversion must return a grey pixel as itself")

        for value in [100.0, -100] {
            var edit = document()
            edit.color.bands = Array(repeating: HSLBand(mix: value), count: ColorGroup.bandCount)
            let out = try display(graph, edit)
            XCTAssertEqual(out.sha256(), plain.sha256(),
                           "a neutral pixel has no hue: a mix of \(value) must leave it bit-identical")
        }
        // The gate itself, which is what makes the above exact rather than approximate.
        XCTAssertEqual(HSLBands.chromaGate(for: 0), 0)
        print("BW NEUTRAL · switch on + every mix at ±100 leaves a grey ramp byte-identical")
    }

    /// The matte is not a colour: outside the content rect (and where S0 wrote alpha 0) the pixel is
    /// written back untouched — the guard S2/S3/S3.5/S3.6 carry.
    func testTheLetterboxStaysExactlyZero() throws {
        let image = picture(64, 32) { x, _ in (0.6, 0.2 + Double(x % 5) / 40, 0.1) }
        let graph = try makeGraph(image, identity: "bw-matte")
        let canvas = ImageSize(width: 64, height: 64)
        var edit = document()
        edit.color.bands = Array(repeating: HSLBand(mix: 100), count: ColorGroup.bandCount)
        let result = try graph.render(edit,
                                      options: RenderOptions(canvas: canvas, scale: 1,
                                                             useCache: false, wantsPixels: true))
        let pixels = try XCTUnwrap(result.display)
        var worst = 0.0
        for y in [0, 1, 15, 48, 62, 63] {
            for x in stride(from: 0, to: 64, by: 7) {
                for c in 0..<3 {
                    worst = max(worst, Double(pixels.rgba[(y * 64 + x) * 4 + c]))
                }
            }
        }
        print("BW MATTE · max matte value with every mix at +100: \(worst)")
        XCTAssertEqual(worst, 0, "the letterbox must not be converted into a grey bar")
    }

    /// Headroom survives: S3.4 is display-referred but not display-clamped, so a highlight above white
    /// keeps its range (S4 is the only clamp, as everywhere else).
    func testAnHDRHighlightKeepsItsHeadroom() throws {
        let image = picture(16, 8) { x, _ in x < 8 ? (2.4, 1.6, 0.9) : (0.45, 0.2, 0.12) }
        let graph = try makeGraph(image, identity: "bw-hdr")
        let out = try display(graph, document(mix: 0, 50), headroom: 4)
        let peak = (0..<(out.width * out.height)).map { Double(out.rgba[$0 * 4]) }.max() ?? 0
        print("BW HDR · peak after 红 +50 at headroom 4: \(peak)")
        XCTAssertGreaterThan(peak, 1.05, "the highlight was flattened — the headroom was lost")
    }

    // MARK: - ② the mix: one band's weight, and only that band's

    /// **The acceptance's mix numbers.** 红/绿/蓝 at −100, −50, 0, +50, +100 on the pure primaries: the
    /// code value of that block must rise strictly with the slider, and the *other* two blocks must not
    /// move by a single byte (a band's weight is exactly 0 at another band's centre).
    func testTheMixIsMonotoneOnEachPrimaryAndTouchesNothingElse() throws {
        let image = primaries()
        let graph = try makeGraph(image, identity: "bw-mix")
        // headroom 4 so the slider's whole travel stays measurable: +100 on a bright primary is above
        // white, and a frame that clipped at 1.0 could only be shown to be monotone up to the white point.
        let base = try display(graph, document(), headroom: 4)
        let blocks = [0, 3, 5]                              // the bands red/green/blue sit on
        var report: [String] = []
        for (block, band) in blocks.enumerated() {
            var codes: [Int] = []
            for value in [-100.0, -50, 0, 50, 100] {
                let out = try display(graph, document(mix: band, value), headroom: 4)
                codes.append(Self.code(Float16(blockMean(out, block))))
                // The two blocks that are not this band's colour must be untouched — bit-exact.
                for other in 0..<3 where other != block {
                    XCTAssertEqual(blockSHA(out, other), blockSHA(base, other),
                                   "band \(band) at \(value) moved block \(other),"
                                   + " which is a different colour")
                }
            }
            for i in 1..<codes.count {
                XCTAssertGreaterThan(codes[i], codes[i - 1],
                                     "band \(band): the mix must be monotone that way")
            }
            report.append("带\(band) \(codes.map(String.init).joined(separator: "→"))")
        }
        print("BW MIX (codes at −100/−50/0/+50/+100, 红/绿/蓝 blocks) · "
              + report.joined(separator: " · "))
    }

    /// A band at its own centre delivers its **full** value; a colour sitting on its neighbour's centre
    /// gets exactly nothing. This is `HSLBands.weight`'s partition of unity, measured on the mix.
    func testABandDeliversItsFullValueAtItsOwnCentreAndZeroAtItsNeighbour() {
        let centres = HSLBands.centresDegrees.map(Double.init)
        for band in 0..<8 {
            let only = (0..<8).map { HSLBand(mix: $0 == band ? 100 : 0) }
            let own = HSLBands.mix(hueDeg: centres[band], chroma: 0.12, bands: only)
            XCTAssertEqual(own, 100, accuracy: 1e-9,
                           "band \(band) must deliver its whole value at its own centre")
            XCTAssertEqual(HSLBands.weight(band, hueDeg: centres[(band + 1) % 8]), 0,
                           "band \(band) must reach no further than its neighbour's centre")
        }
        // And Σw = 1 on the mix too, so eight equal values are the same value everywhere.
        var worstRipple = 0.0
        var previous: Double? = nil
        for step in 0..<1440 {
            let m = HSLBands.mix(hueDeg: Double(step) * 0.25, chroma: 0.12,
                                 bands: (0..<8).map { _ in HSLBand(mix: 100) })
            if let p = previous { worstRipple = max(worstRipple, abs(m - p)) }
            previous = m
            XCTAssertEqual(m, 100, accuracy: 1e-9)
        }
        print("BW WEIGHTS · band at its centre = 100.00, at its neighbour = 0.00,"
              + " all-eight ripple \(String(format: "%.2e", worstRipple)) over 1440 hues")
    }

    /// **The kernel is the CPU reference.** A hue wheel with all eight mixes at +40: every pixel's
    /// grey against `HSLBands.gray`, in display codes.
    func testTheKernelAgreesWithTheCPUReference() throws {
        let image = hueWheel(height: 6, L: 0.52, C: 0.11)
        let graph = try makeGraph(image, identity: "bw-cpu")
        var edit = document()
        edit.color.bands = (0..<8).map { HSLBand(mix: Double(40 - $0 * 6)) }
        let actual = try display(graph, edit)

        var worst = 0
        var total = 0
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = (y * image.width + x) * 4
                let src = SIMD3(Double(image.rgba[o]), Double(image.rgba[o + 1]),
                                Double(image.rgba[o + 2]))
                let grey = HSLBands.gray(Self.toWorking.applying(to: src), bands: edit.color.bands)
                let srgb = Self.toSRGB.applying(to: SIMD3(grey, grey, grey))
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
        print("BW CPU↔GPU · max |Δcode| \(worst), mean "
              + String(format: "%.3f", Double(total) / Double(count))
              + " over \(count) channels (bands at +40 … −2)")
        XCTAssertLessThanOrEqual(worst, 2, "the kernel must be the CPU reference, not a lookalike")
    }

    // MARK: - ③ the structure: a colour document does not encode the pass

    /// **The hard acceptance for the structure.** A colour document — and one that still carries mix
    /// values from a day it was black-and-white — must render the pre-S3.4 graph: no `s3.4` in the
    /// trace, no `bw` link in the key chain, no `s3.4-bw=` segment in `RenderInputs.key`, and the same
    /// bytes as before the stage existed.
    func testAColourDocumentDoesNotVisitTheStage() throws {
        let image = colourRamp(width: 64, height: 32)
        let graph = try makeGraph(image, identity: "bw-neutral-doc")
        let plain = try display(graph, EditModel.neutral)

        // (a) the switch explicitly off, and (b) mixes left behind by a document that *was*
        // black-and-white: neither may encode S3.4, and both must be the pre-S3.4 frame.
        var withMix = EditModel.neutral
        withMix.color.bands = (0..<8).map { HSLBand(mix: Double($0 * 10 - 30)) }

        let dims = ImageSize(width: image.width, height: image.height)
        for edit in [document(blackAndWhite: false), withMix] {
            let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                       wantsPixels: true))
            let pixels = try XCTUnwrap(result.display)
            XCTAssertFalse(result.trace.executed.contains(.bw),
                           "no 黑白 switch: S3.4 must not be in the pipeline")
            XCTAssertNil(result.keys.bw, "no 黑白 switch: no bw link in the key chain")
            XCTAssertFalse(result.keys.shortTrace.contains("s3.4"))
            XCTAssertEqual(pixels.sha256(), plain.sha256(),
                           "a colour document must be byte-identical to the pre-S3.4 frame")

            let links = RenderKeyChain.links(identity: "bw-neutral-doc", sourceSize: dims,
                                             canvas: dims, content: dims, edit: edit,
                                             display: DisplayOptions())
            XCTAssertNil(links.bw)
            XCTAssertEqual(links.pipeline.filter { $0 == .bw }, [])
            XCTAssertEqual(links.pipeline, RenderStage.allCases,
                           "a colour document's chain is exactly the unconditional stages")
            // `RenderInputs.key` must not grow a segment — otherwise every cached thumbnail misses once
            // (the 076/派单-042 rule).
            XCTAssertFalse(RenderInputs(edit).key.contains("s3.4-bw"),
                           "the render key must not grow a segment for a stage that does not exist")
        }

        // (c) a document that is *both* banded (S3.6 runs) and mix-carrying: still no S3.4, and still
        // no key segment for it — the two stages are independent, which is the point of putting the
        // mix on the band rather than in the HSL triple.
        var banded = withMix
        banded.color.bands[2].hue = 12
        let bandedResult = try graph.render(banded, options: RenderOptions(scale: 1, useCache: false,
                                                                          wantsPixels: true))
        XCTAssertTrue(bandedResult.trace.executed.contains(.hsl), "the hue is S3.6's, so S3.6 runs")
        XCTAssertFalse(bandedResult.trace.executed.contains(.bw))
        XCTAssertNil(bandedResult.keys.bw)
        XCTAssertFalse(RenderInputs(banded).key.contains("s3.4-bw"))

        let trace = try graph.render(EditModel.neutral,
                                     options: RenderOptions(scale: 1, wantsPixels: true)).trace.csv
        print("BW NEUTRAL DOC · trace \(trace)")
    }

    /// The other half: a black-and-white document gets exactly **one** more link, seeded by S3's key,
    /// and exactly one more pass — between S3 and the vignette, in `RenderStage.order`'s order.
    func testTheSwitchAddsExactlyOneLinkAndOneStage() throws {
        let dims = ImageSize(width: 64, height: 64)
        func links(_ edit: EditModel) -> RenderKeyChain.Links {
            RenderKeyChain.links(identity: "bw-link", sourceSize: dims, canvas: dims, content: dims,
                                 edit: edit, display: DisplayOptions())
        }
        let plain = links(EditModel.neutral)
        let bw = links(document())
        let link = try XCTUnwrap(bw.bw)
        XCTAssertEqual(link, KeyBuilder(KeyBuilder.digest(of: plain.color))
            .add("bw").add(document().keyMaterial(.bw)).canonical,
                       "S3.4 is seeded by S3's key, not by the vignette's")
        XCTAssertEqual(Array(bw.pipeline.dropFirst(4).prefix(2)), [.toneMap, .color])
        XCTAssertEqual(Array(bw.pipeline.suffix(3)), [.color, .bw, .display])
        XCTAssertEqual(bw.pipeline.count, plain.pipeline.count + 1)
        XCTAssertNotEqual(bw.vignette, plain.vignette, "the vignette reads the grey, so its key must move")

        // A mix move changes S3.4's material and nothing else.
        let mixed = links(document(mix: 0, 40))
        XCTAssertNotEqual(mixed.bw, bw.bw)
        XCTAssertEqual(mixed.color, bw.color, "a mix is not S3's parameter")
        print("BW LINK · \(bw.pipeline.map(\.short).joined(separator: " "))")
    }

    /// A document that is black-and-white **and** has bands/masks/grain: the four conditional stages
    /// coexist, in pipeline order, and a grey written at S3.4 leaves S3.6 bit-exact (it has no chroma to
    /// act on). The one interaction between the two stages, pinned.
    func testTheGreyLeavesS3_6Inert() throws {
        let image = hueWheel(height: 8)
        let graph = try makeGraph(image, identity: "bw-and-hsl")
        var edit = document()
        for i in 0..<8 { edit.color.bands[i] = HSLBand(hue: 40, saturation: 60, luminance: -30) }
        let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                  wantsPixels: true))
        XCTAssertEqual(result.trace.executed.filter { $0 == .bw || $0 == .hsl }, [.bw, .hsl])
        let out = try XCTUnwrap(result.display)
        // S3.6 ran, and had nothing to do: the frame is still exactly monochrome.
        var worst = 0.0
        for i in 0..<(out.width * out.height) {
            worst = max(worst, abs(Double(out.rgba[i * 4]) - Double(out.rgba[i * 4 + 2])))
        }
        print("BW × HSL · trace \(result.trace.csv) · max |R−B| after both stages "
              + String(format: "%.2e", worst))
        XCTAssertLessThan(worst, 1e-4, "S3.6 must write a grey back unchanged")
    }

    // MARK: - ③b the document: schema 8, additive encoding, dirty sets

    /// The two new keys are **absent at their default**, so a schema-7 document re-encodes byte for
    /// byte (§3.2 discipline, the `blackOffset` rule) — and a document that carries them round-trips.
    func testTheNewKeysAreAbsentAtTheirDefault() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let neutral = String(decoding: try encoder.encode(ColorGroup.identity), as: UTF8.self)
        XCTAssertFalse(neutral.contains("blackAndWhite"), "false must not be written")
        XCTAssertFalse(neutral.contains("\"mix\""), "0 must not be written")

        var on = ColorGroup.identity
        on.blackAndWhite = true
        on.bands[3].mix = -40
        let json = try encoder.encode(on)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("blackAndWhite"))
        XCTAssertTrue(text.contains("\"mix\":-40"))
        let back = try JSONDecoder().decode(ColorGroup.self, from: json)
        XCTAssertEqual(back, on)

        // A schema-7 blob (no keys at all) reads back as the pre-S3.4 document.
        let legacy = """
        {"bands":[{"hue":0,"luminance":0,"saturation":0},{"hue":0,"luminance":0,"saturation":0},\
        {"hue":0,"luminance":0,"saturation":0},{"hue":0,"luminance":0,"saturation":0},\
        {"hue":0,"luminance":0,"saturation":0},{"hue":0,"luminance":0,"saturation":0},\
        {"hue":0,"luminance":0,"saturation":0},{"hue":0,"luminance":0,"saturation":0}],\
        "saturation":0,"vibrance":0}
        """
        let old = try JSONDecoder().decode(ColorGroup.self, from: Data(legacy.utf8))
        XCTAssertFalse(old.blackAndWhite)
        XCTAssertFalse(old.hasMix)
        XCTAssertEqual(old, ColorGroup.identity)
        XCTAssertEqual(String(decoding: try encoder.encode(old), as: UTF8.self), legacy)
        print("BW SCHEMA · schema-7 group re-encodes byte for byte; new keys absent at their default")
    }

    /// The dirty sets: the switch dirties S3.4, a mix dirties S3.4, and neither dirties S3 or S3.6.
    func testTheSwitchAndTheMixDirtyOnlyS3_4() {
        let plain = EditModel.neutral
        XCTAssertEqual(plain.changedStages(from: document(blackAndWhite: false)), [])
        XCTAssertEqual(document().changedStages(from: plain), [.bw])
        XCTAssertEqual(document(mix: 2, 55).changedStages(from: document()), [.bw])
        XCTAssertEqual(document(mix: 2, 55).changedStages(from: plain), [.bw])
        // …and the other three directions stay as they were.
        var hsl = plain
        hsl.color.bands[0].luminance = 20
        XCTAssertEqual(hsl.changedStages(from: plain), [.hsl])
        var colour = plain
        colour.color.vibrance = 10
        XCTAssertEqual(colour.changedStages(from: plain), [.color])

        // The history's group-level answer is the same question, and `RenderGroup.color` now owns the
        // stage — a switch that belonged to no group could not be undone as one step.
        XCTAssertEqual(EditHistory.dirtyGroups(from: plain, to: document()), [.color])
        XCTAssertTrue(RenderGroup.color.stages.contains(.bw))
        XCTAssertEqual(EditHistory.dirtyStages(for: [.color]).contains(.bw), true)

        // A history row for each, in the panel's own words.
        let rows = EditHistory.changedFields(between: plain, and: document(mix: 1, -25))
        let keys = rows.map(\.field.key)
        XCTAssertEqual(keys, ["color.bands[1].mix", "color.blackAndWhite"])
        print("BW HISTORY · " + rows.map(\.summary).joined(separator: " · "))
    }

    // MARK: - ④ the refutations

    /// **Refutation 1 — the channel equality is load-bearing.** With `bwIndependentChannels` the kernel
    /// commits the plausible mistake (a grey per channel), and the number the acceptance asserts on
    /// goes from 0 to something a cast is made of — so `testTheThreeChannelsAreEqualAfterTheConversion`
    /// is not a tautology about a kernel that only has one number to write.
    func testTheRefutationTintsTheGrey() throws {
        let image = colourRamp()
        let graph = try makeGraph(image, identity: "bw-refute-cast")
        let options = RenderOptions(scale: 1, useCache: false, wantsPixels: true,
                                    bwIndependentChannels: true)
        let tinted = try XCTUnwrap(graph.render(document(), options: options).display)
        var worst = 0.0
        for i in 0..<(tinted.width * tinted.height) {
            let r = Double(tinted.rgba[i * 4]), g = Double(tinted.rgba[i * 4 + 1])
            let b = Double(tinted.rgba[i * 4 + 2])
            worst = max(worst, max(abs(r - g), abs(g - b), abs(r - b)))
        }
        print("BW REFUTE 1 · per-channel grey: max |Δchannel| \(String(format: "%.3f", worst))"
              + " → the <1e-4 assertion would fail, as it must")
        XCTAssertGreaterThan(worst, 1e-3, "the refutation must break the assertion it refutes")
    }

    /// **Refutation 2 — "the frame is unchanged because the stage does not exist" is structural.**
    /// `bwStageAlwaysRuns` puts S3.4 into the pipeline of a colour document; the pass then runs, the
    /// frame stops being the pre-S3.4 frame, and the byte-identical assertion of §③ has to go red.
    func testTheRefutationRunsTheKernelWithTheSwitchOff() throws {
        let image = colourRamp(width: 64, height: 32)
        let plainGraph = try makeGraph(image, identity: "bw-refute-stage")
        let forcedGraph = try makeGraph(image, identity: "bw-refute-stage", bwStageAlwaysRuns: true)
        let edit = EditModel.neutral                       // the switch is **off**

        let plain = try display(plainGraph, edit)
        let forcedResult = try forcedGraph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                              wantsPixels: true))
        let forced = try XCTUnwrap(forcedResult.display)
        print("BW REFUTE 2 · forced run: trace \(forcedResult.trace.csv)"
              + " · sha \(forced.sha256().prefix(12))… vs \(plain.sha256().prefix(12))…")
        XCTAssertTrue(forcedResult.trace.executed.contains(.bw),
                      "the knob must actually put S3.4 in the pipeline")
        XCTAssertNotEqual(forced.sha256(), plain.sha256(),
                          "a colour document with the pass encoded must not be the colour frame —"
                          + " otherwise the byte-identical claim would be about arithmetic, not about"
                          + " the stage being absent")
    }

    // MARK: - ⑤ cost

    /// 4.10 Mpx, one frame, `useCache: false`: the whole pipeline with and without S3.4, and the
    /// difference is the pass. Printed rather than asserted against a budget (056's rule: record it, do
    /// not invent a threshold); guarded only against a pathological kernel.
    func testTheStageCostsWhatAPassCosts() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        let image = picture(2340, 1755) { x, y in
            (0.2 + Double((x * y) % 61) / 300, 0.3, 0.4)
        }
        XCTAssertEqual(image.width * image.height, 4_106_700)
        let graph = try makeGraph(image, identity: "bw-cost")
        var edit = document()
        edit.color.bands = (0..<8).map { HSLBand(mix: Double($0 * 8 - 28)) }

        _ = try graph.render(EditModel.neutral, options: RenderOptions(scale: 1, useCache: false))
        _ = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false))
        var without = Double.infinity
        var with = Double.infinity
        for _ in 0..<5 {
            for e in [EditModel.neutral, edit] {
                let r = try graph.render(e, options: RenderOptions(scale: 1, useCache: false))
                if e.hasBlackAndWhite { with = min(with, r.trace.gpuMilliseconds) }
                else { without = min(without, r.trace.gpuMilliseconds) }
            }
        }
        print("BW COST · 4.10 Mpx (2340×1755): whole frame " + String(format: "%.2f", without)
              + " ms → " + String(format: "%.2f", with) + " ms (+"
              + String(format: "%.2f", with - without) + " ms for S3.4, best of 5, interleaved)")
        XCTAssertLessThan(with - without, 40, "a B&W pass on 4.1 Mpx cannot cost tens of milliseconds")
    }
}
