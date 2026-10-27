import XCTest
import Metal
import simd
import CryptoKit
import PhotonsCore

/// 080 — 「显示原图」(`\`) and 前后对比, proved with pixels rather than with intent.
///
/// Four claims, and every one of them is a number:
///
///  ① **The decode is not a parameters-cleared render.** Both are rendered here and hashed: the two
///     hashes differ, and the largest per-channel difference (in 8-bit codes) says how much. The
///     parameters-cleared spelling still passes S0 with the document's *geometry*, so on a cropped,
///     straightened picture it shows a differently-framed photograph with neutral tone — which is
///     exactly what a `\` must not be.
///  ② **The decode is the decode.** The frame is compared against a reference computed on the CPU —
///     `OETF(M_working→out · M_decoded→working · v)` per pixel — and must agree to within one 8-bit
///     code. That is what makes it a decode rather than a filter that happens to be neutral.
///  ③ **The 分屏 line has one owner per pixel.** `CompareSplit.side(x:y:canvas:)` says which source
///     owns ten sample points; the composite's own bytes have to agree, and the two sources have to
///     differ at those points (otherwise "who owns it" is unanswerable).
///  ④ **Nothing leaks.** A composite of two identical frames is byte-identical to either input (the
///     pass converts nothing), and the same inputs composite to the same bytes twice.
///
/// The refutation lives in `testTheRefutationTurnsTheFirstAssertionRed`: with
/// `originalRendersAsParametersCleared` the shipped path *is* the naive one, and claim ① fails.
///
/// The fixture is synthetic on purpose: a decode would make ①'s difference depend on the photograph,
/// and this test needs the same bytes every run.
final class BeforeAfterTests: XCTestCase {

    private static let imageSize = ImageSize(width: 200, height: 150)
    /// A viewport wider than the picture's aspect on one axis, so the letterbox is exercised too.
    private static let viewport = ImageSize(width: 240, height: 180)

    // MARK: - fixtures

    /// A picture with structure in every direction: gradients plus a hard edge, and a few values
    /// above display white so S4's ceiling has something to clamp.
    private func decodedImage() -> LinearImage {
        let w = Self.imageSize.width, h = Self.imageSize.height
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        var seed: UInt32 = 0x5EED_0801
        func next() -> Float {
            seed = seed &* 1664525 &+ 1013904223
            return Float(seed >> 8) / Float(1 << 24)
        }
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                let gx = Float(x) / Float(w - 1), gy = Float(y) / Float(h - 1)
                let edge: Float = (x / 17) % 2 == 0 ? 1.0 : 0.35
                rgba[o] = Float16(min(2.4, (0.05 + 1.5 * gx) * edge + 0.02 * next()))
                rgba[o + 1] = Float16(min(2.4, (0.04 + 1.1 * gy) * edge + 0.02 * next()))
                rgba[o + 2] = Float16(min(2.4, (0.06 + 0.9 * (1 - gx * gy)) + 0.02 * next()))
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "sRGB", decoderVersion: "before-after-test")
    }

    private func makeGraph(_ image: LinearImage) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: "beforeafter-test"))
    }

    /// A document with **both** kinds of edit: tone/colour (which a parameters-cleared render can
    /// zero) and geometry (which it cannot).
    private func editedDocument() -> EditModel {
        var e = EditModel.neutral
        e.light.exposure = 1.2
        e.light.contrast = 35
        e.light.shadows = 30
        e.light.highlights = -25
        e.color.saturation = 45
        e.color.vibrance = 20
        e.curve.white = [CurvePoint(u: 0, v: 0.06), CurvePoint(u: 0.5, v: 0.58), CurvePoint(u: 1, v: 1)]
        e.geometry.crop = NormalizedRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7)
        e.geometry.rotationDegrees = 7
        e.geometry.flipHorizontal = true
        return e
    }

    private func options(source: RenderSource = .edited, naive: Bool = false,
                         canvas: ImageSize? = nil, scale: Double = 1) -> RenderOptions {
        RenderOptions(canvas: canvas, scale: scale,
                      display: DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1),
                      useCache: false, wantsPixels: true,
                      source: source, originalRendersAsParametersCleared: naive)
    }

    // MARK: - helpers

    private func render(_ graph: RenderGraph, _ edit: EditModel,
                        _ options: RenderOptions) throws -> DisplayImage {
        let result = try graph.render(edit, options: options)
        if let texture = result.output { graph.recycle(output: texture) }
        return try XCTUnwrap(result.display)
    }

    /// Per-channel difference between two display-encoded frames, in 8-bit codes.
    private func maxCodeDelta(_ a: DisplayImage, _ b: DisplayImage) -> (delta: Double, at: (x: Int, y: Int)) {
        precondition(a.width == b.width && a.height == b.height, "two different canvases")
        var worst: Float = 0
        var at = (x: 0, y: 0)
        for y in 0..<a.height {
            for x in 0..<a.width {
                let o = (y * a.width + x) * 4
                for c in 0..<3 {
                    let d = abs(Float(a.rgba[o + c]) - Float(b.rgba[o + c]))
                    if d > worst { worst = d; at = (x, y) }
                }
            }
        }
        return (Double(worst) * 255, at)
    }

    private func codes(_ image: DisplayImage, x: Int, y: Int) -> [Float] {
        let o = (y * image.width + x) * 4
        return (0..<3).map { Float(image.rgba[o + $0]) }
    }

    /// Read a texture the graph handed out (the composite) back as an RGBA half-float image.
    private func pixels(of texture: MTLTexture) -> DisplayImage {
        let w = texture.width, h = texture.height
        var raw = [Float16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return DisplayImage(width: w, height: h, rgba: raw, primaries: .sRGB, bitDepth: 16)
    }

    private func srgbEncode(_ v: Double) -> Double {
        v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1.0 / 2.4) - 0.055
    }

    // MARK: - ① the decode is not a parameters-cleared render

    func testTheDecodeIsNotAParametersClearedRender() throws {
        let image = decodedImage()
        let graph = try makeGraph(image)
        let doc = editedDocument()

        let original = try render(graph, doc, options(source: .decoded, canvas: Self.viewport))
        let cleared = try render(graph, doc.disregardingParameters, options(canvas: Self.viewport))

        let originalHash = original.sha256()
        let clearedHash = cleared.sha256()
        let delta = maxCodeDelta(original, cleared)
        print("""
        DECODE-VS-CLEARED original=\(originalHash.prefix(16))… cleared=\(clearedHash.prefix(16))… \
        maxΔ=\(String(format: "%.2f", delta.delta)) codes at \(delta.at)
        """)

        XCTAssertNotEqual(originalHash, clearedHash,
                          "`\\` must show the decode, not the document with its sliders zeroed")
        // Not a rounding difference: the two pictures are different photographs on the canvas
        // (the cleared one is cropped, straightened and flipped; the decode is the whole frame).
        XCTAssertGreaterThan(delta.delta, 8,
                             "the two spellings must differ by real tones, not by half-float rounding")

        // And the reason is the geometry, said as a number: the cleared render is the *cropped*
        // frame, the decode is the whole one.
        let clearedPicture = cleared.sha256()
        let neutralFullFrame = try render(graph, .neutral, options(canvas: Self.viewport))
        print("NEUTRAL-FULL frame=\(neutralFullFrame.sha256().prefix(16))… (compare: cleared \(clearedPicture.prefix(8))…)")
        // The decode of a document that never touched geometry *is* the neutral frame to within
        // half-float rounding — which is why the assertion above needs a geometry-bearing document
        // to be a real one, and why this test pins it rather than leaving it to chance.
        var plain = doc
        plain.geometry = .identity
        let originalOfPlain = try render(graph, plain, options(source: .decoded, canvas: Self.viewport))
        let neutralOfPlain = try render(graph, .neutral, options(canvas: Self.viewport))
        let plainDelta = maxCodeDelta(originalOfPlain, neutralOfPlain)
        print("geometry-free document: decode vs neutral maxΔ=\(String(format: "%.3f", plainDelta.delta)) codes")
        XCTAssertLessThanOrEqual(plainDelta.delta, 1,
                                 "with no geometry the decode and a neutral render are one picture")
    }

    // MARK: - ② the decode is `decode + OETF`, to within a code

    func testTheDecodeMatchesDecodePlusOETFWithinOneCode() throws {
        let image = decodedImage()
        let graph = try makeGraph(image)
        let doc = editedDocument()
        // canvas == the decode's own size and scale 1 → S0's identity path (a texel copy plus the
        // decoded→working matrix), so the comparison is per pixel and not a resampling question.
        let frame = try render(graph, doc, options(source: .decoded, canvas: Self.imageSize))

        let toWorking = ColorPrimaries.conversion(from: .decoded, to: .working)
        let toOutput = ColorPrimaries.conversion(from: .working, to: .sRGB)
        var worst = 0.0
        var at = (x: 0, y: 0)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let i = (y * image.width + x) * 4
                let source = SIMD3<Double>(Double(image.rgba[i]), Double(image.rgba[i + 1]),
                                           Double(image.rgba[i + 2]))
                var v = toOutput.applying(to: toWorking.applying(to: source))
                v = SIMD3(min(max(v.x, 0), 1), min(max(v.y, 0), 1), min(max(v.z, 0), 1))
                for c in 0..<3 {
                    let reference = srgbEncode(v[c])
                    let got = Double(codes(frame, x: x, y: y)[c])
                    let d = abs(got - reference) * 255
                    if d > worst { worst = d; at = (x, y) }
                }
            }
        }
        print("DECODE-VS-REFERENCE maxΔ=\(String(format: "%.3f", worst)) codes at \(at) "
              + "(\(image.width)×\(image.height) px, \(image.width * image.height * 3) channels)")
        XCTAssertLessThanOrEqual(worst, 1.0,
                                 "the decode frame must be decode + OETF to within one 8-bit code")
        XCTAssertEqual(frame.size, Self.imageSize)
    }

    // MARK: - ③ the 分屏 line: one owner per pixel

    func testTheDividerAssignsEverySampleToItsOwnSource() throws {
        let image = decodedImage()
        let graph = try makeGraph(image)
        let doc = editedDocument()
        let canvas = Self.viewport

        let edited = try render(graph, doc, options(canvas: canvas))
        let original = try render(graph, doc, options(source: .decoded, canvas: canvas))

        // Ten sample points, five each side, none of them on the painted line (columns 119/120 at
        // 50 % of 240). The list is fixed so the numbers in the report are reproducible.
        let vertical = CompareSplit(axis: .vertical, fraction: 0.5)
        let verticalPoints = [(8, 12), (30, 40), (60, 90), (95, 60), (118, 150),
                              (121, 20), (150, 75), (180, 140), (205, 45), (238, 175)]
        let compositeV = try graph.composite(original: try texture(graph, doc, canvas, .decoded),
                                             edited: try texture(graph, doc, canvas, .edited),
                                             split: vertical)
        let compositeVPixels = pixels(of: compositeV)
        graph.recycle(output: compositeV)

        print("SPLIT vertical 50 %: divider at column \(vertical.dividerPixel(canvas: canvas)) "
              + "(line \(CompareSplit.lineWidth) px)")
        for (i, point) in verticalPoints.enumerated() {
            let side = vertical.side(x: point.0, y: point.1, canvas: canvas)
            let composed = codes(compositeVPixels, x: point.0, y: point.1)
            let fromOriginal = codes(original, x: point.0, y: point.1)
            let fromEdited = codes(edited, x: point.0, y: point.1)
            print("  #\(i + 1) (\(point.0),\(point.1)) side=\(side.rawValue) "
                  + "composite=\(fmt(composed)) original=\(fmt(fromOriginal)) edited=\(fmt(fromEdited))")
            XCTAssertNotEqual(fromOriginal, fromEdited,
                              "#\(i + 1): the two sources must differ, or ownership is unanswerable")
            switch side {
            case .original:
                XCTAssertEqual(composed, fromOriginal, "#\(i + 1) must be the decode")
            case .edited:
                XCTAssertEqual(composed, fromEdited, "#\(i + 1) must be the edited frame")
            case .divider:
                XCTFail("#\(i + 1) was chosen away from the line")
            }
        }

        // The line itself is neither source: the two columns at 50 % of 240 are painted.
        let lineColumn = vertical.dividerPixel(canvas: canvas) - CompareSplit.lineWidth / 2
        XCTAssertEqual(vertical.side(x: lineColumn, y: 0, canvas: canvas), .divider)
        XCTAssertEqual(vertical.side(x: lineColumn + CompareSplit.lineWidth, y: 0, canvas: canvas), .edited)

        // Same question on the other axis: top is the decode, bottom is the edited frame.
        let horizontal = CompareSplit(axis: .horizontal, fraction: 0.5)
        let horizontalPoints = [(20, 8), (90, 30), (150, 55), (200, 80), (40, 88),
                                (70, 92), (110, 100), (160, 120), (210, 145), (230, 170)]
        let compositeH = try graph.composite(original: try texture(graph, doc, canvas, .decoded),
                                             edited: try texture(graph, doc, canvas, .edited),
                                             split: horizontal)
        let compositeHPixels = pixels(of: compositeH)
        graph.recycle(output: compositeH)
        print("SPLIT horizontal 50 %: divider at row \(horizontal.dividerPixel(canvas: canvas))")
        for (i, point) in horizontalPoints.enumerated() {
            let side = horizontal.side(x: point.0, y: point.1, canvas: canvas)
            let composed = codes(compositeHPixels, x: point.0, y: point.1)
            print("  #\(i + 1) (\(point.0),\(point.1)) side=\(side.rawValue) composite=\(fmt(composed))")
            switch side {
            case .original:
                XCTAssertEqual(composed, codes(original, x: point.0, y: point.1),
                               "#\(i + 1) must be the decode")
            case .edited:
                XCTAssertEqual(composed, codes(edited, x: point.0, y: point.1),
                               "#\(i + 1) must be the edited frame")
            case .divider:
                XCTFail("#\(i + 1) was chosen away from the line")
            }
        }
    }

    private func texture(_ graph: RenderGraph, _ edit: EditModel, _ canvas: ImageSize,
                         _ source: RenderSource) throws -> MTLTexture {
        let result = try graph.render(edit, options: RenderOptions(
            canvas: canvas, scale: 1,
            display: DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1),
            useCache: false, wantsPixels: false, source: source))
        return try XCTUnwrap(result.output)
    }

    private func fmt(_ v: [Float]) -> String {
        "(" + v.map { String(format: "%.4f", $0) }.joined(separator: ",") + ")"
    }

    // MARK: - ④ the composite converts nothing

    func testTheCompositeOfTwoIdenticalFramesIsByteIdenticalToEither() throws {
        let image = decodedImage()
        let graph = try makeGraph(image)
        let doc = editedDocument()
        let canvas = Self.viewport
        let edited = try texture(graph, doc, canvas, .edited)
        let editedAgain = try texture(graph, doc, canvas, .edited)
        XCTAssertEqual(LoupeComparable.hash(edited), LoupeComparable.hash(editedAgain),
                       "two renders of one document are one picture (or nothing below means anything)")

        let composed = try graph.composite(original: edited, edited: editedAgain,
                                           split: CompareSplit(axis: .vertical, fraction: 0.5))
        let composedPixels = pixels(of: composed)
        let reference = pixels(of: edited)
        // Every pixel outside the line, on both sides: the pass reads and writes, so the split of a
        // frame against itself is that frame.
        var mismatches = 0
        for y in 0..<canvas.height {
            for x in 0..<canvas.width where
                CompareSplit(axis: .vertical, fraction: 0.5).side(x: x, y: y, canvas: canvas) != .divider {
                if codes(composedPixels, x: x, y: y) != codes(reference, x: x, y: y) { mismatches += 1 }
            }
        }
        graph.recycle(output: composed)
        XCTAssertEqual(mismatches, 0, "the composite must not convert anything")
        XCTAssertEqual(composedPixels.sha256().count, 64)
    }

    func testTheCompositeIsDeterministic() throws {
        let image = decodedImage()
        let graph = try makeGraph(image)
        let doc = editedDocument()
        let canvas = Self.viewport
        let original = try texture(graph, doc, canvas, .decoded)
        let edited = try texture(graph, doc, canvas, .edited)
        let split = CompareSplit(axis: .vertical, fraction: 0.37)
        let a = try graph.composite(original: original, edited: edited, split: split)
        let aPixels = pixels(of: a)
        let b = try graph.composite(original: original, edited: edited, split: split)
        let bPixels = pixels(of: b)
        graph.recycle(output: a)
        graph.recycle(output: b)
        print("COMPOSITE deterministic sha=\(aPixels.sha256().prefix(16))… (fraction 0.37)")
        XCTAssertEqual(aPixels.sha256(), bPixels.sha256())
    }

    // MARK: - the refutation

    /// With `originalRendersAsParametersCleared` the shipped path **is** the naive one:
    /// `RenderSource.decoded` renders the parameters-cleared document through the whole pipeline.
    /// The first assertion — "the decode differs from the parameters-cleared render" — then has the
    /// same pixels on both sides and must be red. This test pins that it is.
    func testTheRefutationTurnsTheFirstAssertionRed() throws {
        let image = decodedImage()
        let graph = try makeGraph(image)
        let doc = editedDocument()

        let shipped = try render(graph, doc, options(source: .decoded, canvas: Self.viewport))
        let cleared = try render(graph, doc.disregardingParameters, options(canvas: Self.viewport))
        XCTAssertNotEqual(shipped.sha256(), cleared.sha256(), "the real path (sanity)")

        let naive = try render(graph, doc,
                               options(source: .decoded, naive: true, canvas: Self.viewport))
        let naiveDelta = maxCodeDelta(naive, cleared)
        print("REFUTATION naive sha=\(naive.sha256().prefix(16))… cleared sha=\(cleared.sha256().prefix(16))… "
              + "maxΔ=\(String(format: "%.3f", naiveDelta.delta)) codes")
        XCTAssertEqual(naive.sha256(), cleared.sha256(),
                       "the naive spelling renders the cleared document — that is the whole refutation")
        XCTAssertLessThanOrEqual(naiveDelta.delta, 0.0)
        // Which is precisely the assertion `testTheDecodeIsNotAParametersClearedRender` makes, and
        // with this flag on it fails.
        XCTAssertFalse(naive.sha256() != cleared.sha256(),
                       "assertion ① is load-bearing: the naive spelling makes it false")
    }

    // MARK: - the key discipline

    /// Entering and leaving 原图 cannot move a stage key: the decode path visits two stages of the
    /// same chain, and the document's own pipeline is decided by the document, not by the view.
    func testTheDecodePathVisitsOnlyGeometryAndDisplay() throws {
        let image = decodedImage()
        let graph = try makeGraph(image)
        let doc = editedDocument()
        let original = try graph.render(doc, options: options(source: .decoded, canvas: Self.viewport))
        if let texture = original.output { graph.recycle(output: texture) }
        print("DECODE PATH stages=\(original.trace.executed.map(\.label))")
        XCTAssertEqual(original.trace.executed, [.geometry, .display])
        XCTAssertEqual(original.showsMask, false)
        // The document's own pipeline still exists and is untouched.
        let edited = try graph.render(doc, options: RenderOptions(canvas: Self.viewport, scale: 1,
                                                                  useCache: false, wantsPixels: false))
        if let texture = edited.output { graph.recycle(output: texture) }
        XCTAssertEqual(edited.trace.executed, RenderStage.allCases)
    }
}

/// The loupe hashes textures with the same digest; the core tests need it without importing the UI.
private enum LoupeComparable {
    static func hash(_ texture: MTLTexture) -> String {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return raw.withUnsafeBytes { buf in
            SHA256.hash(data: Data(bytes: buf.baseAddress!, count: buf.count))
                .map { String(format: "%02x", $0) }.joined()
        }
    }
}
