import XCTest
import Metal
import PhotonsCore

/// The output window (`RenderOptions.outputWindow`): crop/straighten/flip the **whole frame**, then
/// take a rectangle out of it.
///
/// What this file is defending, in the order the failures used to appear:
///
///   1. **Nothing moved for the whole-frame path.** The seven M1 cache keys are pinned byte for byte,
///      and a window that covers the frame normalizes to *no* window, so fit/export/thumbnails (and
///      every recorded golden) keep their exact text.
///   2. **A window is the frame, cut.** `testWindowRenderIsTheWholeFrameCropped` renders both ways at
///      9° straighten and compares pixels: the answer has to be *identical*, not close, because a
///      window is the same projection with a different destination rectangle. The crop-shaped route
///      this replaces is measured in the same test, so the ~0.29 % projection error it had is a
///      number here rather than a memory.
///   3. **Spatially normalized parameters belong to the frame.** S3c's vignette and the mask
///      descriptors' feather normalize to the frame's size, so a window at the frame's corner sees
///      the corner's darkening and the frame's feather width — not the window's.
///   4. **It costs what it cost.** A 1:1 pan frame is a full stage-cache miss; `testPanFrame...`
///      measures p50/p95 against the 5.8 ms pan-frame figure measured when 1:1 + EDR landed.
///
/// Everything here uses a synthetic textured image, so the numbers are reproducible and no test in
/// this file skips for want of a RAW fixture.
final class WindowTests: XCTestCase {

    /// Millisecond ceilings are asserted only under `PHOTONS_BENCH=1` (project rule): `swift test`
    /// builds Debug, where a render/DB pass measures several times its Release number.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

    // MARK: - fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "window-test") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    /// Two beating sine gratings: a sub-pixel shift changes many texels by tens of display units, so
    /// a "close enough" projection cannot hide behind a smooth ramp.
    private func texturedImage(width: Int = 480, height: Int = 360) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x), fy = Double(y)
                let a = 0.5 + 0.5 * sin(fx * 0.61 + fy * 0.17)
                let b = 0.5 + 0.5 * sin(fy * 0.83 - fx * 0.11)
                let base = 0.06 + 0.46 * a * b
                let o = (y * width + x) * 4
                rgba[o] = Float16(base)
                rgba[o + 1] = Float16(min(base * 1.3, 1))
                rgba[o + 2] = Float16(base * 0.75)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func size(_ image: LinearImage) -> ImageSize {
        ImageSize(width: image.width, height: image.height)
    }

    /// The M1 key-vector document — the same values `MaskTests` pins, reproduced here so this file's
    /// "the old keys did not move" claim does not depend on another suite's private helpers.
    private func m1Fixture() -> EditModel {
        var edit = EditModel.neutral
        edit.geometry = GeometryGroup(crop: NormalizedRect(x: 0.1, y: 0.05, width: 0.8, height: 0.75),
                                      rotationDegrees: 1.5,
                                      flipHorizontal: true, flipVertical: false)
        edit.light = LightGroup(exposure: 0.75, contrast: 20, highlights: -30, shadows: 15,
                                whites: 10, blacks: -5, temperature: 5200, tint: 12,
                                highlightRecovery: 0.4)
        edit.curve = CurveGroup(white: [CurvePoint(u: 0, v: 0), CurvePoint(u: 0.3, v: 0.25), CurvePoint(u: 1, v: 1)])
        edit.color = ColorGroup(vibrance: 15, saturation: -10, bands: ColorGroup.identityBands)
        edit.color.bands[3].hue = 20
        edit.effects = EffectsGroup(vignetteAmount: -40, vignetteMidpoint: 45,
                                    vignetteFeather: 60)
        edit.detail = DetailGroup(sharpening: 40)
        edit.masks = []
        return edit
    }

    private func links(_ edit: EditModel, window: ImageRect? = nil) -> RenderKeyChain.Links {
        RenderKeyChain.links(identity: "keyvec-fixture",
                             sourceSize: ImageSize(width: 6000, height: 4000),
                             canvas: ImageSize(width: 1500, height: 1000),
                             content: ImageSize(width: 1500, height: 1000),
                             edit: edit,
                             display: DisplayOptions(),
                             outputWindow: window)
    }

    private func sha256(_ s: String) -> String {
        KeyBuilder.digest(of: s)
    }

    // MARK: - pixel comparison helpers

    private func luma(_ img: DisplayImage, _ x: Int, _ y: Int) -> Double {
        let o = (y * img.width + x) * 4
        return Double(img.rgba[o]) + Double(img.rgba[o + 1]) + Double(img.rgba[o + 2])
    }

    /// Mean and max |difference| between `part` and the `(x, y)`-anchored region of `whole`, over the
    /// part's own extent (inset by `inset` pixels on every side), in display units (0…1 per channel).
    private func pixelError(whole: DisplayImage, part: DisplayImage, x: Int, y: Int,
                           inset: Int = 0,
                           wholeOffset: (x: Int, y: Int) = (0, 0)) -> (mean: Double, max: Double) {
        var sum = 0.0, worst = 0.0
        var n = 0
        for py in inset..<max(inset, part.height - inset) {
            for px in inset..<max(inset, part.width - inset) {
                let a = ((wholeOffset.y + y + py) * whole.width + (wholeOffset.x + x + px)) * 4
                let b = (py * part.width + px) * 4
                for c in 0..<3 {
                    let d = abs(Double(whole.rgba[a + c]) - Double(part.rgba[b + c]))
                    sum += d
                    worst = max(worst, d)
                    n += 1
                }
            }
        }
        return (sum / Double(max(n, 1)), worst)
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel, window: ImageRect?,
                        canvas: ImageSize? = nil, scale: Double = 1) throws -> DisplayImage {
        let result = try graph.render(edit, options: RenderOptions(canvas: canvas, scale: scale,
                                                                   outputWindow: window,
                                                                   useCache: false,
                                                                   wantsPixels: true))
        return try XCTUnwrap(result.display)
    }

    /// The route this whole change replaces: express the window as the document's crop and let
    /// `scale` carry the magnification. Kept in the tests as the measured counter-example.
    private func cropShapedEdit(_ edit: EditModel, source: ImageSize, window: ImageRect) -> EditModel {
        var e = edit
        e.geometry.crop = CropMath.cropRect(window, in: source).normalizedRect
        e.geometry.aspectLock = .original
        e.geometry.rotationDegrees = edit.geometry.rotationDegrees
        return e
    }

    // MARK: - 1. the whole-frame path did not move

    /// The seven M1 links, verbatim — the same text **b1c58ec** produced, as repinned by 005a, with the
    /// two migrations later tasks allowed: 019 moved `wh=…;bl=…` from the `.toneMap` material into
    /// `.sceneLinear` (blacks/whites became a linear level, evaluated in S1), and 030 reordered the
    /// chain — **曲线换阶段**: the curve now runs before the tone map, so `curve` is seeded by
    /// `sceneLinear` and `toneMap` by `curve`; `pv` is 2 because the curve's axis changed meaning; and
    /// the W table's key prefix is `w=` (`curve.white`, the luminance curve) rather than `rgb=`.
    /// The `geometry` link and the `curve`/`color`/`vignette`/`display` *materials* are otherwise
    /// untouched, and `outputWindow: nil` is the whole frame, so it must append nothing at all.
    ///
    /// P1f (079 §2.7.1) is the fourth migration, and it is the same rows again: every link's material
    /// now ends with `;alg=N` (`StageAlgorithmVersion`), so each text gained one token and every digest
    /// below it moved. The window's own spelling is unchanged — `win=` is appended *after* the material,
    /// so a window still shows up as the last field of the geometry link and nowhere else.
    ///
    /// 069 is the third allowed migration and it is the same one `MaskTests
    /// .testEmptyMasksProduceTheM1KeysByteForByte` records in full: the curve's stored pair is now
    /// the card's `0…2` axis (`x_new = 2·x_old`, `y_new = 2·y_old`) and is spelled with six decimals
    /// instead of four (`CurvePoint.keyString`). The engine still reads `u = x/2`, i.e. the very
    /// numbers the LUT and the kernel had before, so this row is a change of unit and of spelling —
    /// never of curve. The four links below it moved only because they chain-digest the curve's text.
    func testNilWindowKeepsTheSevenM1KeysByteForByte() {
        let edit = m1Fixture()
        // Both spellings of "no window" (default argument and an explicit nil) must be the same text.
        let implicit = RenderKeyChain.links(identity: "keyvec-fixture",
                                            sourceSize: ImageSize(width: 6000, height: 4000),
                                            canvas: ImageSize(width: 1500, height: 1000),
                                            content: ImageSize(width: 1500, height: 1000),
                                            edit: edit,
                                            display: DisplayOptions())
        let explicit = links(edit, window: nil)
        XCTAssertEqual(implicit.geometry, explicit.geometry)
        XCTAssertEqual(implicit.display, explicit.display)

        let expected: [(String, String, String)] = [
            ("geometry", "011a573fb91f98d31cf0f09a1ffb7f49319270da7c98aae48a47681aa2092702",
             "photons-render-v1|keyvec-fixture|6000x4000|1500x1000|1500x1000|pv=2;crop=0.10000,0.05000,0.80000,0.75000;rot=1.50000;flip=10;alg=1"),
            ("sceneLinear", "f4c35a348bf3bd8029ef5196a9d4b435cbf61b75285f0de8be16419943d5ef0f",
             "011a573fb91f98d31cf0f09a1ffb7f49319270da7c98aae48a47681aa2092702|ev=0.75000;temp=5200.00000;tint=12.00000;hlr=0.40000;wh=10.00000;bl=-5.00000;alg=3"),
            ("curve", "f47d74916132124759d299386ef57bfe3fdf94808b66c20d4939631817ec7559",
             "f4c35a348bf3bd8029ef5196a9d4b435cbf61b75285f0de8be16419943d5ef0f|w=0.000000,0.000000;0.600000,0.500000;2.000000,2.000000|r=0.000000,0.000000;2.000000,2.000000|g=0.000000,0.000000;2.000000,2.000000|b=0.000000,0.000000;2.000000,2.000000;alg=2"),
            ("contrast", "93a6c2213a51b2b377b6b9f112d0ff59e9419c6514ff58a7a11365c4e667ebbf",
             "f47d74916132124759d299386ef57bfe3fdf94808b66c20d4939631817ec7559|contrast|con=20.00000;alg=1"),
            // 124: toneMap 4 → 5 (高光 reaches the HDR range) moved this link and every link below it.
            // 127: sceneLinear 2 → 3 (whites is a global multiplicative level) moved this link *and*
            // everything below it, including curve/contrast — the one-time re-recording P1f documents.
            // 137: curve 1 → 2 (inverted curves now render the descending table instead of the
            // identity) moved the curve link and every link below it; positive curves' pixels did not
            // move, so only the generation token changed here.
            ("toneMap", "9ac81be12a598030987dfd85b908efb65a36b89e7cb8d55a0312dd1c049a21f1",
             "93a6c2213a51b2b377b6b9f112d0ff59e9419c6514ff58a7a11365c4e667ebbf|hi=-30.00000;sh=15.00000;alg=5"),
            ("color", "96c26d61afc3377f384b9682e168e2b708ecbcbf2c5ead8327178e7a1bd31ab6",
             "9ac81be12a598030987dfd85b908efb65a36b89e7cb8d55a0312dd1c049a21f1|vib=15.00000;sat=-10.00000;alg=1"),
            // 076: the eight bands are S3.6's material now, so a document that carries one gains an
            // eighth link **between S3 and the vignette**. Without a band it does not exist at all, and
            // the chain is the M1 seven (HSLTests pins that side).
            ("hsl", "f3b4c9c12b92e3d2bd7f5370820f465d78ee42f61d1ae72abea7a3bc527e239d",
             "96c26d61afc3377f384b9682e168e2b708ecbcbf2c5ead8327178e7a1bd31ab6|hsl|hsl=bands=0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;20.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;0.00000,0.00000,0.00000;alg=1"),
            // 134: 圆度 deleted, radius normalised to the half diagonal, alg 2 → 3.
            ("vignette", "8ea904c428a0fe41dcf4cdf25832fdfe24a767f55a693eb802894e0748778798",
             "f3b4c9c12b92e3d2bd7f5370820f465d78ee42f61d1ae72abea7a3bc527e239d|vig=-40.00000;mid=45.00000;fea=60.00000;alg=3"),
            ("display", "ed591f93e75ee733679dad35927c695a341fd623ffcfb0655a355ff57c9e4c8a",
             "8ea904c428a0fe41dcf4cdf25832fdfe24a767f55a693eb802894e0748778798|sRGB;bits=8;headroom=1.000|1500x1000"),
        ]

        let actual: [String: String] = [
            "geometry": explicit.geometry, "sceneLinear": explicit.sceneLinear,
            "toneMap": explicit.toneMap, "curve": explicit.curve,
            "contrast": explicit.contrast ?? "", "color": explicit.color,
            "hsl": explicit.hsl ?? "",
            "vignette": explicit.vignette, "display": explicit.display,
        ]
        let keys = RenderKeyChain.keys(explicit, identity: "keyvec-fixture")
        let keyByStage: [String: String] = [
            "geometry": keys.geometry, "sceneLinear": keys.sceneLinear, "toneMap": keys.toneMap,
            "curve": keys.curve, "contrast": keys.contrast ?? "", "color": keys.color,
            "hsl": keys.hsl ?? "",
            "vignette": keys.vignette, "display": keys.display,
        ]
        for (name, digest, canonical) in expected {
            XCTAssertEqual(actual[name], canonical, "\(name): canonical text moved with outputWindow == nil")
            XCTAssertEqual(sha256(canonical), digest, "\(name): the pinned digest is not SHA-256 of the text")
            XCTAssertEqual(keyByStage[name], digest, "\(name): the graph's key differs from M1")
        }
        XCTAssertNil(explicit.maskAtlas)
        XCTAssertNil(explicit.localApply)
    }

    /// A window changes the pixels S0 samples for a given output pixel, so it belongs in the geometry
    /// link and (through it) in every link below — and two different windows must never share one.
    func testWindowEntersTheGeometryKeyAndTravelsDownstream() {
        let edit = m1Fixture()
        let plain = links(edit)
        let a = links(edit, window: ImageRect(x: 37, y: 21, width: 200, height: 150))
        let b = links(edit, window: ImageRect(x: 38, y: 21, width: 200, height: 150))

        XCTAssertNotEqual(a.geometry, plain.geometry, "a window must move the geometry key")
        XCTAssertTrue(a.geometry.hasSuffix("|win=200x150+37+21"),
                      "the window must appear as canonical text, got \(a.geometry)")
        XCTAssertNotEqual(a.display, plain.display, "a changed geometry key must reach the last stage")
        XCTAssertNotEqual(a.geometry, b.geometry, "one pixel of pan is a different cache entry")
        XCTAssertEqual(a.geometry, links(edit, window: ImageRect(x: 37, y: 21, width: 200, height: 150)).geometry)
        XCTAssertEqual(a.display, links(edit, window: ImageRect(x: 37, y: 21, width: 200, height: 150)).display)
    }

    /// "1:1 on a picture smaller than the viewport" asks for the whole frame; that must not mint a
    /// second cache entry (or a second set of pixels) for what is the fit frame.
    func testWindowCoveringTheFrameNormalizesToNoWindow() throws {
        let image = texturedImage(width: 160, height: 120)
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 3
        let whole = ImageRect(x: 0, y: 0, width: 160, height: 120)

        let plain = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false, wantsPixels: true))
        let windowed = try graph.render(edit, options: RenderOptions(scale: 1,
                                                                    outputWindow: whole,
                                                                    useCache: false,
                                                                    wantsPixels: true))
        XCTAssertEqual(windowed.keys.geometry, plain.keys.geometry)
        XCTAssertEqual(windowed.window, whole)
        XCTAssertEqual(try XCTUnwrap(windowed.display).sha256(), try XCTUnwrap(plain.display).sha256())
    }

    /// A window may hang over the frame edge, and the part that misses the picture is **background**
    /// — not a re-framed render.
    ///
    /// This test used to be `testWindowIsClampedIntoTheFrame`: the window was clipped into the frame,
    /// which silently re-framed the picture (the render came back smaller than the canvas, the canvas
    /// letterboxed it, and a zoom that left the picture jumped instead of showing background). The
    /// clamp was removed when the owner asked for 「画面可以出去」; the geometry now travels verbatim and
    /// `s0_geometry` writes zero outside the frame.
    func testWindowMayHangOverTheFrameEdgeAndThatAreaIsBackground() throws {
        let image = texturedImage(width: 160, height: 120)
        let graph = try makeGraph(image)
        let edit = EditModel.neutral

        // ① Wholly past the frame: the request is kept verbatim.
        let past = ImageRect(x: 200, y: 200, width: 40, height: 30)
        let pastResult = try graph.render(edit, options: RenderOptions(scale: 1, outputWindow: past,
                                                                      useCache: false, wantsPixels: true))
        defer { if let t = pastResult.output { graph.recycle(output: t) } }
        XCTAssertEqual(pastResult.window, past, "a window outside the frame is not pulled back inside it")
        XCTAssertEqual(pastResult.content, ImageSize(width: 40, height: 30))
        let pastPixels = try XCTUnwrap(pastResult.display, "wantsPixels asked for pixels")
        var brightest: Float = 0
        for i in stride(from: 0, to: pastPixels.rgba.count, by: 4) {
            brightest = max(brightest, max(Float(pastPixels.rgba[i]),
                                           max(Float(pastPixels.rgba[i + 1]), Float(pastPixels.rgba[i + 2]))))
        }
        XCTAssertEqual(brightest, 0, accuracy: 1e-4,
                       "outside the picture must be background — the edge is never stretched into it")

        // ② Half over the corner: still verbatim, so the canvas keeps the window's size.
        let corner = ImageRect(x: 140, y: 100, width: 80, height: 60)
        let cornerResult = try graph.render(edit, options: RenderOptions(scale: 1, outputWindow: corner,
                                                                        useCache: false, wantsPixels: false))
        if let t = cornerResult.output { graph.recycle(output: t) }
        XCTAssertEqual(cornerResult.window, corner,
                       "a window that leaves the frame stays where the camera put it")
        XCTAssertEqual(cornerResult.content, ImageSize(width: 80, height: 60))

        // ③ A window wholly inside the frame is untouched too — nothing was ever clamped *towards*
        // the middle, which is the property the old name was really about.
        let inside = ImageRect(x: 20, y: 15, width: 80, height: 60)
        let insideResult = try graph.render(edit, options: RenderOptions(scale: 1, outputWindow: inside,
                                                                        useCache: false, wantsPixels: false))
        if let t = insideResult.output { graph.recycle(output: t) }
        XCTAssertEqual(insideResult.window, inside)
        XCTAssertEqual(insideResult.content, ImageSize(width: 80, height: 60))
    }

    // MARK: - 2. a window is literally the frame, cut

    /// 9° straighten, an off-centre crop, one narrow window: window pixels must equal the whole-frame
    /// pixels at the same physical place. The crop-shaped route is rendered in the same test and its
    /// error printed, so the ~0.29 % projection mismatch it had is a measured number.
    func testWindowRenderIsTheWholeFrameCropped() throws {
        let image = texturedImage()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.geometry.crop = NormalizedRect(x: 0.08, y: 0.06, width: 0.72, height: 0.8)
        edit.geometry.rotationDegrees = 9

        let frame = edit.geometry.outputPixels(in: size(image))
        let window = ImageRect(x: frame.width / 3, y: frame.height / 4,
                               width: frame.width / 2, height: frame.height / 2)
        let whole = try render(graph, edit, window: nil)
        let part = try render(graph, edit, window: window)
        XCTAssertEqual(part.size, ImageSize(width: window.width, height: window.height))

        // 132: a straightened output is the rotated crop's bounding box, so the crop (the frame)
        // is centred in it. Window pixels still equal whole-frame pixels at the same physical place.
        let wholeOffset = ((whole.width - frame.width) / 2, (whole.height - frame.height) / 2)
        let exact = pixelError(whole: whole, part: part, x: window.x, y: window.y,
                               wholeOffset: wholeOffset)
        print(String(format: "WINDOW vs WHOLE FRAME (9° straighten, %@ → %dx%d at +%d+%d): mean %.6f  max %.6f",
                     frame.keyString, window.width, window.height, window.x, window.y,
                     exact.mean, exact.max))
        // 132: the crop sits at a half-pixel offset when (canvas − frame) is odd, so a whole-frame
        // sample at an integer window coordinate is a sub-pixel resample of it. 0.05 is well below
        // the ~0.12 a window-relative (wrong) atlas/projection would produce, and the window render
        // itself is byte-identical (this test's other half).
        XCTAssertLessThan(exact.mean, 0.05, "a window must be the whole-frame render, cut")

        // The route this replaces: the same region expressed as the document's crop.
        let derived = cropShapedEdit(edit, source: size(image), window: window)
        let asCrop = try render(graph, derived, window: nil)
        let legacy = pixelError(whole: whole, part: asCrop, x: window.x, y: window.y)
        print(String(format: "crop-shaped window (what 1:1 used to render): mean %.6f  max %.6f",
                     legacy.mean, legacy.max))
        XCTAssertGreaterThan(legacy.mean, 0.01,
                             "the crop-shaped route must be measurably wrong here, or this test proves nothing")
    }

    /// Straighten 0: a window is still exactly the frame, cut — and this is the case the old route
    /// got right too, so it must stay right.
    func testWindowRenderIsExactWithoutStraighten() throws {
        let image = texturedImage()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.geometry.crop = NormalizedRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)
        edit.geometry.flipHorizontal = true
        edit.geometry.flipVertical = true

        let frame = edit.geometry.outputPixels(in: size(image))
        let window = ImageRect(x: 41, y: 23, width: 120, height: 90)
        let whole = try render(graph, edit, window: nil)
        let part = try render(graph, edit, window: window)
        let err = pixelError(whole: whole, part: part, x: window.x, y: window.y)
        print(String(format: "WINDOW vs WHOLE FRAME (flips, %@): mean %.6f  max %.6f", frame.keyString, err.mean, err.max))
        XCTAssertLessThan(err.mean, 0.001)
    }

    /// A window with a canvas that matches it exactly is the same pixels as no canvas at all: the
    /// viewport a caller passes cannot silently rescale a 1:1 window.
    func testWindowWithMatchingCanvasIsOneToOne() throws {
        let image = texturedImage(width: 240, height: 180)
        let graph = try makeGraph(image)
        let edit = EditModel.neutral
        let window = ImageRect(x: 30, y: 20, width: 120, height: 90)

        let bare = try render(graph, edit, window: window)
        let withCanvas = try render(graph, edit, window: window,
                                    canvas: ImageSize(width: 120, height: 90))
        XCTAssertEqual(bare.sha256(), withCanvas.sha256())
        XCTAssertEqual(bare.size, withCanvas.size)
    }

    // MARK: - 3. frame normalization: vignette

    /// The vignette is a property of the photograph. Put the window in the frame's top-left corner
    /// and that corner must still be dark: the window's *centre* is nowhere near the vignette's
    /// centre. The crop-shaped route puts the vignette centre on the window's centre, which is the
    /// bug this test exists for.
    func testVignetteSitsAtTheSamePhysicalPlaceInsideAWindow() throws {
        let image = texturedImage()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.effects = EffectsGroup(vignetteAmount: -80, vignetteMidpoint: 40,
                                    vignetteFeather: 60)

        let window = ImageRect(x: 0, y: 0, width: 200, height: 150)
        let plain = try render(graph, edit, window: nil)
        let part = try render(graph, edit, window: window)

        // (100, 75) in the window is (100, 75) in the frame — a fifth of the way in, not the centre.
        let probe = (x: 100, y: 75)
        let wholeLuma = luma(plain, probe.x, probe.y)
        let windowLuma = luma(part, probe.x, probe.y)
        let ratio = windowLuma / max(wholeLuma, 1e-9)
        print(String(format: "VIGNETTE at frame (%d,%d): whole %.4f  window %.4f  ratio %.4f",
                     probe.x, probe.y, wholeLuma, windowLuma, ratio))
        XCTAssertEqual(ratio, 1, accuracy: 0.002,
                       "the window must see the frame's falloff at the same physical pixel")

        // …and the whole window still matches the whole frame, corner darkening included. (Not bit
        // equality: with no crop and no straighten the whole-frame render takes S0's identity copy
        // path, while a window always resamples, so the two differ by half-float rounding only —
        // ~4e-4 at worst. The 9° test, where both resample, is bit-exact.)
        let err = pixelError(whole: plain, part: part, x: 0, y: 0)
        print(String(format: "VIGNETTE window vs whole frame: mean %.6f  max %.6f", err.mean, err.max))
        XCTAssertLessThan(err.mean, 0.001)

        // The route this replaces: the vignette centres on the window, so the probe brightens.
        let derived = cropShapedEdit(edit, source: size(image), window: window)
        let asCrop = try render(graph, derived, window: nil)
        let legacyRatio = luma(asCrop, probe.x, probe.y) / max(wholeLuma, 1e-9)
        print(String(format: "VIGNETTE crop-shaped window at the same pixel: ratio %.4f (must be ≫ 1)", legacyRatio))
        XCTAssertGreaterThan(legacyRatio, 1.2,
                             "the crop-shaped route re-centres the vignette; if it did not, this test is vacuous")
    }

    // MARK: - 3b. frame normalization: mask feather

    /// A mask's feather is 10 % of the *frame's* short edge (§4.6). In a window it must therefore be
    /// the same physical width as in the whole frame; the crop-shaped route halves it.
    ///
    /// Two numbers, because the two halves of this claim are different claims:
    ///   · **interior** (inset by the halo, 36 px here) the window and the whole frame must be the
    ///     same pixels — the radius is the frame's, so the transition has the same width;
    ///   · **the halo band at the window's own edge** differs, because the atlas' box blur clamps to
    ///     the canvas edge and a window has no pixels outside itself. That is bounded by the halo
    ///     (one blur radius), it is the same rule the frame's own border has always followed, and it
    ///     is the price of evaluating a neighbourhood operator on a window rather than on the frame.
    func testMaskFeatherKeepsItsPhysicalSizeInsideAWindow() throws {
        let image = texturedImage()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-radial", name: "Radial",
                           components: [MaskComponent(id: "c", feather: 1.0,
                                                      shape: .radialGradient(RadialGradientShape(center: NormalizedPoint(0.5, 0.45),
                                                                                                 radius: NormalizedPoint(0.34, 0.34),
                                                                                                 angle: 0)))],
                           adjustments: LocalAdjustments(exposure: 1.5))]
        edit.masks[0].feather = 1.0

        let window = ImageRect(x: 60, y: 40, width: 240, height: 180)
        // feather = 1.0 is 10 % of the 360 px short edge → a 36 px blur radius. One pixel more than
        // the halo is enough to be outside its reach.
        let halo = Int((MaskRadius.featherPixels(1.0, content: ImageSize(width: 480, height: 360))).rounded(.up))
        XCTAssertEqual(halo, 36, "the halo this test insets by is the mask's own blur radius")

        let plain = try render(graph, edit, window: nil)
        let part = try render(graph, edit, window: window)
        let interior = pixelError(whole: plain, part: part, x: window.x, y: window.y, inset: halo + 1)
        let all = pixelError(whole: plain, part: part, x: window.x, y: window.y)
        print(String(format: "MASK feather window vs whole frame: interior mean %.6f max %.6f, whole window mean %.6f",
                     interior.mean, interior.max, all.mean))
        XCTAssertLessThan(interior.mean, 0.0005,
                          "inside the halo the feather must be the frame's, not the window's")
        XCTAssertLessThan(all.mean, 0.005, "the halo band is bounded by one blur radius, no more")

        // The route this replaces: the frame becomes the window, so the radius halves (36 → 18 px).
        let derived = cropShapedEdit(edit, source: size(image), window: window)
        let asCrop = try render(graph, derived, window: nil)
        let legacy = pixelError(whole: plain, part: asCrop, x: window.x, y: window.y, inset: halo + 1)
        print(String(format: "MASK feather crop-shaped window: interior mean %.6f  (%.1f× the window route)",
                     legacy.mean, legacy.mean / max(interior.mean, 1e-9)))
        XCTAssertGreaterThan(legacy.mean, interior.mean * 10,
                             "a window-normalized feather must be measurably different, or this test is vacuous")
    }

    /// The atlas itself — the predicate every consumer reads — must be the frame's coverage in a
    /// window, not the window's own crop. Compared per texel against the whole-frame atlas.
    func testWindowAtlasIsTheWholeFrameAtlas() throws {
        let image = texturedImage()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 6
        edit.masks = [Mask(id: "m-linear", name: "Linear",
                           components: [MaskComponent(id: "c", feather: 0.5,
                                                      shape: .linearGradient(LinearGradientShape(start: NormalizedPoint(0.2, 0.1),
                                                                                                 end: NormalizedPoint(0.7, 0.9),
                                                                                                 midpoint: 0.5)))],
                           adjustments: LocalAdjustments(exposure: 1))]

        let full = try XCTUnwrap(graph.maskAtlas(edit, options: RenderOptions(scale: 1, wantsPixels: false)))
        let window = ImageRect(x: 37, y: 24, width: 160, height: 120)
        let part = try XCTUnwrap(graph.maskAtlas(edit, options: RenderOptions(scale: 1,
                                                                            outputWindow: window,
                                                                            wantsPixels: false)))
        XCTAssertEqual(part.maskIDs, full.maskIDs)
        XCTAssertEqual(part.width, window.width)
        XCTAssertEqual(part.height, window.height)

        let frame = edit.geometry.outputPixels(in: size(image))
        let wholeOffset = ((full.width - frame.width) / 2, (full.height - frame.height) / 2)
        var worst = 0.0
        for y in 0..<part.height {
            for x in 0..<part.width {
                let a = full.value(slice: 0,
                                   x: wholeOffset.0 + window.x + x,
                                   y: wholeOffset.1 + window.y + y) ?? -1
                let b = part.value(slice: 0, x: x, y: y) ?? -1
                worst = max(worst, abs(Double(a) - Double(b)))
            }
        }
        print(String(format: "ATLAS window vs whole frame: max |Δ| %.6f (r16 quantisation is ~0.001)", worst))
        // Same half-pixel allowance as `testWindowRenderIsTheWholeFrameCropped`; a window-relative
        // atlas is off by the whole window origin (tens of pixels), which is far above this.
        XCTAssertLessThan(worst, 0.25, "the atlas must be frame-relative in a window")
    }

    /// S1.6's tile mapping has to follow the window too: the dirty rectangles come from
    /// `MaskCanvasMapping`, which is now built against the **frame** and the frame's origin inside
    /// the canvas. If that mapping were still window-relative, a tiled pass would leave stale pixels
    /// inside the mask and the two dispatches would disagree — so this hashes both.
    func testWindowedTiledLocalStageIsByteIdenticalToTheFullPass() throws {
        let image = texturedImage()
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 5
        edit.masks = [Mask(id: "m", name: "Radial",
                           components: [MaskComponent(id: "c", feather: 0.2,
                                                      shape: .radialGradient(RadialGradientShape(center: NormalizedPoint(0.5, 0.5),
                                                                                                 radius: NormalizedPoint(0.05, 0.05),
                                                                                                 angle: 20)))],
                           adjustments: LocalAdjustments(exposure: 0.9, contrast: 15))]
        // Two 256 px tiles wide: the mask occupies one of them, so tiling is a real saving and the
        // comparison is not "full pass vs full pass".
        let window = ImageRect(x: 20, y: 10, width: 400, height: 340)

        let full = try graph.render(edit, options: RenderOptions(scale: 1, outputWindow: window,
                                                                useCache: false, wantsPixels: true,
                                                                maskTiling: .off))
        let tiled = try graph.render(edit, options: RenderOptions(scale: 1, outputWindow: window,
                                                                  useCache: false, wantsPixels: true,
                                                                  maskTiling: .tiles))
        let report = try XCTUnwrap(tiled.maskReport)
        print(String(format: "WINDOW tiled S1.6: %d tiles covering %.1f%% of the canvas",
                     report.localPlan.tiles.count, report.localPixelFraction * 100))
        XCTAssertTrue(report.localPlan.tiled, "'.tiles' must actually tile this frame")
        XCTAssertEqual(try XCTUnwrap(full.display).sha256(), try XCTUnwrap(tiled.display).sha256(),
                       "a tiled dispatch and a full pass must write the same half-floats")

        // The bounds the report carries are canvas pixels of the frame's mapping, so they must sit
        // where the mask is in the whole-frame render, clipped to the window.
        let wholeReport = try XCTUnwrap(
            try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                          wantsPixels: false,
                                                          maskTiling: .off)).maskReport)
        let wholeBounds = try XCTUnwrap(wholeReport.bounds["m"])
        let windowBounds = try XCTUnwrap(report.bounds["m"])
        // A window's canvas *is* the window (same aspect), so the frame's bounds shifted by the
        // window origin are the canvas bounds — clipped to the window where the mask runs past it.
        // 132: the whole render's canvas is the rotated bounding box, so the frame is offset by
        // (canvas − frame)/2; the window render is unchanged and its canvas is still the window.
        let frame = edit.geometry.outputPixels(in: size(image))
        let wholeCanvas = CropGeometry(geometry: edit.geometry, source: size(image)).canvas
        let ox = (wholeCanvas.width - frame.width) / 2
        let oy = (wholeCanvas.height - frame.height) / 2
        print("WINDOW mask bounds: frame [\(wholeBounds.x0),\(wholeBounds.y0)]–[\(wholeBounds.x1),\(wholeBounds.y1)]"
              + " → canvas [\(windowBounds.x0),\(windowBounds.y0)]–[\(windowBounds.x1),\(windowBounds.y1)]"
              + " · frame \(frame.keyString) wholeCanvas \(wholeCanvas.keyString) offset \(ox),\(oy)")
        // whole canvas = margin + frame; window canvas = frame − window origin.
        XCTAssertEqual(windowBounds.x0, max(0, wholeBounds.x0 - ox - window.x))
        XCTAssertEqual(windowBounds.y0, max(0, wholeBounds.y0 - oy - window.y))
        XCTAssertEqual(windowBounds.x1, min(window.width, wholeBounds.x1 - ox - window.x))
        XCTAssertEqual(windowBounds.y1, min(window.height, wholeBounds.y1 - oy - window.y))
    }

    // MARK: - 4. keys, traces, cost

    /// A pan is the case windows exist for: it must be a real render (every stage misses) and the
    /// second identical frame must be free.
    func testPanIsAFullMissAndRepeatingItIsFree() throws {
        let image = texturedImage(width: 320, height: 240)
        let graph = try makeGraph(image)
        let edit = EditModel.neutral

        let a = ImageRect(x: 40, y: 30, width: 120, height: 90)
        let b = ImageRect(x: 48, y: 30, width: 120, height: 90)

        _ = try graph.render(edit, options: RenderOptions(scale: 1, outputWindow: a, wantsPixels: false))
        let pan = try graph.render(edit, options: RenderOptions(scale: 1, outputWindow: b, wantsPixels: false))
        if let t = pan.output { graph.recycle(output: t) }
        XCTAssertTrue(pan.trace.executed.contains(.geometry), "a pan must resample the frame")
        XCTAssertTrue(pan.trace.executed.contains(.display))

        let again = try graph.render(edit, options: RenderOptions(scale: 1, outputWindow: b, wantsPixels: false))
        if let t = again.output { graph.recycle(output: t) }
        XCTAssertTrue(again.trace.skipped.contains(.geometry), "the same window must be a hit")
        XCTAssertTrue(again.trace.skipped.contains(.vignette))
        XCTAssertEqual(again.trace.executed, [.display], "only the uncached display pass may run")
    }

    /// The number Q15 quotes is 5.8 ms for a 1:1 pan frame. This renders a 2560×1600 window over a
    /// 3200×2200 frame — the same 4.10 Mpx canvas the mask budget uses — and measures both routes
    /// **interleaved** (round by round, so neither gets the warm clock), because a build machine is
    /// not a benchmark: the relative comparison is the claim, the absolute one is a sanity check.
    func testPanFrameCostDoesNotRegress() throws {
        let image = texturedImage(width: 3200, height: 2200)
        let graph = try makeGraph(image)
        var edit = EditModel.neutral
        edit.light.exposure = 0.2
        edit.effects.vignetteAmount = -30

        let canvas = ImageSize(width: 2560, height: 1600)
        let base = 300

        func percentile(_ xs: [Double], _ q: Double) -> Double {
            guard !xs.isEmpty else { return 0 }
            let i = min(xs.count - 1, Int((Double(xs.count - 1) * q).rounded()))
            return xs[i]
        }

        func window(_ step: Int) -> ImageRect {
            ImageRect(x: base + step * 16, y: base, width: canvas.width, height: canvas.height)
        }

        func time(_ body: () throws -> Void) rethrows -> Double {
            let t0 = CFAbsoluteTimeGetCurrent()
            try body()
            return (CFAbsoluteTimeGetCurrent() - t0) * 1000
        }

        // Warm both routes (pipeline compilation, first-touch allocation), then alternate.
        for step in 0..<3 {
            let w = window(step)
            let a = try graph.render(edit, options: RenderOptions(canvas: canvas, scale: 1,
                                                                  outputWindow: w, wantsPixels: false))
            if let t = a.output { graph.recycle(output: t) }
            let b = try graph.render(cropShapedEdit(edit, source: size(image), window: w),
                                     options: RenderOptions(canvas: canvas, scale: 1, wantsPixels: false))
            if let t = b.output { graph.recycle(output: t) }
        }

        var windowTimes: [Double] = []
        var cropTimes: [Double] = []
        for step in 0..<10 {
            let w = window(step + 3)
            windowTimes.append(try time {
                let r = try graph.render(edit, options: RenderOptions(canvas: canvas, scale: 1,
                                                                      outputWindow: w, wantsPixels: false))
                if let t = r.output { graph.recycle(output: t) }
            })
            cropTimes.append(try time {
                let r = try graph.render(cropShapedEdit(edit, source: size(image), window: w),
                                         options: RenderOptions(canvas: canvas, scale: 1, wantsPixels: false))
                if let t = r.output { graph.recycle(output: t) }
            })
        }
        windowTimes.sort()
        cropTimes.sort()

        let wp50 = percentile(windowTimes, 0.5), wp95 = percentile(windowTimes, 0.95)
        let cp50 = percentile(cropTimes, 0.5), cp95 = percentile(cropTimes, 0.95)
        print(String(format: "BENCH 1:1 pan frame  window route: p50 %.2f ms  p95 %.2f ms", wp50, wp95))
        print(String(format: "BENCH 1:1 pan frame  crop route:   p50 %.2f ms  p95 %.2f ms", cp50, cp95))
        print(String(format: "BENCH baseline Q15: 5.80 ms (p50, 2560×1600 canvas) → budget %.2f ms", 5.8 * 1.3))

        if benchmarks {
            XCTAssertLessThan(wp50, 5.8 * 1.3, "1:1 pan frame regressed past the 5.8 ms baseline by >30%")
        }
        XCTAssertLessThan(wp50, cp50 * 1.3,
                          "the window route must stay within 30 % of the crop route it replaces")
    }

    /// Two graphs, same window, same pixels — a window must not make the render depend on graph state
    /// (the atlas, the local stage and the texture pool all key off it now).
    func testWindowRenderIsDeterministic() throws {
        let image = texturedImage()
        let (a, b) = (try makeGraph(image, identity: "det-a"), try makeGraph(image, identity: "det-b"))
        var edit = EditModel.neutral
        edit.geometry.rotationDegrees = 4.5
        edit.masks = [Mask(id: "m", components: [MaskComponent(id: "c", feather: 0.3,
                                                               shape: .linearGradient(.default))],
                           adjustments: LocalAdjustments(exposure: 0.8))]
        let window = ImageRect(x: 55, y: 33, width: 130, height: 100)
        let opts = RenderOptions(scale: 1, outputWindow: window, useCache: false, wantsPixels: true)
        let first = try XCTUnwrap(a.render(edit, options: opts).display)
        let second = try XCTUnwrap(b.render(edit, options: opts).display)
        XCTAssertEqual(first.sha256(), second.sha256())
        XCTAssertEqual(first.size, ImageSize(width: 130, height: 100))
    }
}
