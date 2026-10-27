import XCTest
import CryptoKit
import Metal
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 054 — the canvas **around** the picture is `#0F0F0F`, not black.
///
/// The user's report ("能否把背景的黑色设置为黑灰色？比如 0F0F0F 这种") is not about a layer colour: in
/// fit mode the bands around the photograph are **inside the canvas texture**, because S2/S4 write
/// `float4(0)` for every pixel that is not the photograph, and a `CAMetalLayer`'s `backgroundColor` is
/// behind that texture and never shows through it. So the colour is painted by the present pass, where
/// the picture's rect on the canvas (`PresentParams.d`, filled from `RenderResult.pictureRect`) says
/// where the photograph is, and the layer colour + `MTLClearColor` are set to the same value so the
/// canvas is grey from the very first frame instead of flashing black.
///
/// What is pinned here, in the order a mistake would show up:
///
///   1. **One constant, four places.** `CanvasPresenter.CanvasMatte` is the value; the shader's literal
///      is parsed out of `present.metal` and compared against it, and both layer backgrounds are
///      asserted to come from the same `NSColor`.
///   2. **The photograph is untouched.** A canvas-sized frame with the picture in the middle 50 %:
///      every pixel *inside* the picture's rect is byte-identical to the same render with no picture
///      rect (i.e. to pre-054 output), while the four corners are `(15, 15, 15)`.
///   3. **A frame that covers the canvas loses nothing.** The whole-frame `pixelSHA256` of the full-cover
///      fixture equals the hash recorded **before** this change, for both the 16-bit and the 8-bit path
///      — the anti-proof is the next test, which shows what the hash looks like when the matte *is*
///      painted over the photograph.
///   4. **The backdrop branch is still the picture.** With a backdrop the canvas outside the main
///      window is the backdrop's colour, not the matte, and the picture rect changes nothing there.
///   5. **The histogram cannot see it.** Measured on the S4 frame over `pictureRect`, the bins are
///      per-bin equal before and after the matte is drawn, and the frame's own corner is still exactly
///      `0` — the colour never enters the texture.
@MainActor
final class CanvasMatteGreyTests: XCTestCase {

    /// Recorded against `ded0dd1`, **before** the matte existed, by running the fixtures below through
    /// the then-current `CanvasPresenter.render`. `exact` is the stored bits, `q8` the same pixels
    /// quantised to 8 bits (the form that survives a different GPU's rounding).
    private enum Pre054 {
        static let fullCoverLinear16 = (exact: "717c7ac40c395861aa6d9e72c9449dad879fd20c288198ad85c7be4a1a9a9f2f",
                                        q8: "a3fe160c9206c10dac59cb718897ecebaba7e2d87984784fece27facc9243108")
        static let fullCoverSRGB8 = (exact: "c7a0d6c8cc8b3443a7cc41a09322bda59fd6f64460dad5ac6a98921fb04d62d6",
                                     q8: "7e929bc128876d32982f233373720fcd4109b89d06fcc3e11e5fec3f01e4af51")
    }

    // MARK: - 1. one constant, four places

    /// `#0F0F0F` is 15 of 255 in **display encoding**; the 16-bit layer stores linear light, so the two
    /// numbers must be the same colour through the sRGB transfer function, not the same literal.
    func testTheMatteIsHexZeroFZeroFZeroF() {
        XCTAssertEqual(CanvasPresenter.CanvasMatte.eightBitValue, 0x0F, "#0F is 15")
        XCTAssertEqual(CanvasPresenter.CanvasMatte.displayEncoded, 15.0 / 255, accuracy: 1e-12)
        // sRGB EOTF, the same branch `srgb_encode_inverse` in `present.metal` takes at 15/255 (above the
        // 0.04045 knee, so the pow branch — not a plain division).
        let expectedLinear = pow((15.0 / 255 + 0.055) / 1.055, 2.4)
        XCTAssertEqual(CanvasPresenter.CanvasMatte.linear, expectedLinear, accuracy: 1e-12)

        let encoded = CanvasPresenter.CanvasMatte.clearColor(linear: false)
        for (name, v) in [("r", encoded.red), ("g", encoded.green), ("b", encoded.blue)] {
            XCTAssertEqual(v, 15.0 / 255, accuracy: 1e-12, "encoded clear colour, \(name)")
        }
        XCTAssertEqual(encoded.alpha, 1)
        let linear = CanvasPresenter.CanvasMatte.clearColor(linear: true)
        for (name, v) in [("r", linear.red), ("g", linear.green), ("b", linear.blue)] {
            XCTAssertEqual(v, expectedLinear, accuracy: 1e-12, "linear clear colour, \(name)")
        }
        // The 8-bit quantisation of both numbers is 15: what a screen shows for `#0F0F0F`.
        XCTAssertEqual(Int((CanvasPresenter.CanvasMatte.displayEncoded * 255).rounded()), 15)
        print("canvas matte: #0F0F0F = 15/255 encoded, \(CanvasPresenter.CanvasMatte.linear) linear")
    }

    /// The shader carries its own literal (it cannot import Swift), so the two are compared here: the
    /// declaration in `present.metal` must be `float3(15.0 / 255.0)`.
    ///
    /// **058 supersedes the old second half of this test.** It used to require that the backdrop
    /// fragment never read the matte ("outside the window is the picture"). That is true only while the
    /// window is *inside* the picture: once a shrink pushes the picture's own edge onto the canvas,
    /// outside the window is not the picture at all, and `saturate()` was smearing one edge column
    /// across the band. So the backdrop branch now reads the matte for fragments whose UV left `[0,1]`
    /// and keeps the picture everywhere else — the assertion below pins *that* rule.
    func testTheShaderUsesTheSameValueAndOnlyWithoutABackdrop() throws {
        let source = try String(contentsOf: Self.kernelURL, encoding: .utf8)
        let eight = CanvasPresenter.CanvasMatte.eightBitValue
        let declaration = try XCTUnwrap(source.split(separator: "\n").first { $0.contains("kCanvasMatteDisplay") },
                                        "present.metal has no matte constant")
        XCTAssertTrue(declaration.contains("float3(\(eight).0 / 255.0)"),
                      "the shader's matte is not #0\(String(format: "%02X", eight)): \(declaration)")

        let plain = try XCTUnwrap(Self.fragmentSignature("present_fragment", in: source))
        XCTAssertTrue(plain.contains("kCanvasMatteDisplay"), "025's fragment does not paint the matte")
        XCTAssertTrue(plain.contains("p.d"), "the matte must be decided by the picture's rect")
        let backdrop = try XCTUnwrap(Self.fragmentSignature("present_fragment_backdrop", in: source))
        XCTAssertTrue(backdrop.contains("kCanvasMatteDisplay"),
                      "058: outside the **picture** the backdrop branch draws the canvas matte")
        XCTAssertTrue(backdrop.contains("beyondEdge") || backdrop.contains("kPictureEdgeEpsilon"),
                      "…and only where the picture's own UV left [0,1] — inside it is the picture")
        // The fetch itself is still clamped (`saturate`), because a GPU cannot skip a texture read —
        // what must be true is that the **result** is thrown away where the UV left the picture. That
        // select on `beyondEdge` is the whole fix; without it the clamp is what smeared the column.
        XCTAssertTrue(backdrop.contains("beyondEdge ? float4(kCanvasMatteDisplay"),
                      "the out-of-picture result must be replaced by the matte, not kept from the clamp")
    }

    /// The two layer backgrounds and the shader are one colour. `LoupeCanvasView` is built for real; the
    /// container layer is pinned where it is assigned (its controller needs a catalog session), so this
    /// test also fails if a literal creeps back in.
    func testBothLayerBackgroundsAreTheSameConstant() throws {
        let matte = NSColor.canvasMatte
        let srgb = try XCTUnwrap(matte.usingColorSpace(.sRGB), "no sRGB colour")
        for (name, v) in [("r", srgb.redComponent), ("g", srgb.greenComponent), ("b", srgb.blueComponent)] {
            XCTAssertEqual(v, CGFloat(15.0 / 255), accuracy: 1e-6, "NSColor.canvasMatte \(name)")
        }
        XCTAssertEqual(srgb.alphaComponent, 1)

        let canvas = LoupeCanvasView()
        let layerColor = try XCTUnwrap(canvas.metalLayer.backgroundColor, "the canvas layer has no colour")
        let readBack = try XCTUnwrap(NSColor(cgColor: layerColor)?.usingColorSpace(.sRGB))
        for (name, v) in [("r", readBack.redComponent), ("g", readBack.greenComponent),
                          ("b", readBack.blueComponent)] {
            XCTAssertEqual(v, CGFloat(15.0 / 255), accuracy: 1e-6, "metalLayer.backgroundColor \(name)")
        }

        // The container layer too, from the source: two assignments, both from the constant, and no
        // `NSColor.black` background left in the loupe.
        let text = try String(contentsOf: Self.loupeURL, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "NSColor.canvasMatte.cgColor").count - 1, 2,
                       "both the metal layer and the container layer take the matte from the constant")
        XCTAssertFalse(text.contains("backgroundColor = NSColor.black.cgColor"),
                       "a canvas background is still literal black")
        print("layers: metalLayer + container = NSColor.canvasMatte = (#0F0F0F)")
    }

    /// The matte is only correct if the *call site* hands the pass the picture's rect: a settled frame is
    /// canvas-sized, so `p.d` is `(0,0,1,1)` unless someone supplies the photograph's place inside it.
    /// The shader cannot guess that (the letterbox pixels are ordinary zeros), so the wiring is pinned
    /// here — text, because the only other witness is a drawable nobody can read back.
    func testTheSettledPresentHandsThePictureRectToThePass() throws {
        let text = try String(contentsOf: Self.loupeURL, encoding: .utf8)
        XCTAssertTrue(text.contains("let picture = frame.canvas == canvas ? frame.pictureRect : nil"),
                      "the settled frame's picture rect is not taken from RenderResult.pictureRect")
        XCTAssertEqual(text.components(separatedBy: "pictureRect: picture").count - 1, 2,
                       "both `window: .whole` presents (the settled frame and the bridge's stop) must "
                       + "carry the picture rect")
        XCTAssertTrue(text.contains("canvasPicture = picture.map { ($0, canvas) }"),
                      "the rect must be remembered for the bridge-cancel re-present")

        // And the on-screen pass accepts it (skipped, like 037's own real-layer test, when this session
        // hands out no drawable — a layer needs a visible window for one).
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let layer = CAMetalLayer()
        CanvasPresenter.configure(layer, storage: presenter.storage)
        let canvas = ImageSize(width: 64, height: 48)
        layer.drawableSize = CGSize(width: canvas.width, height: canvas.height)
        let frame = try letterboxed(device, canvas, picture: ImageRect(x: 16, y: 12, width: 32, height: 24))
        if !presenter.present(frame, in: layer, drawableSize: canvas, window: .whole,
                              pictureRect: ImageRect(x: 16, y: 12, width: 32, height: 24)) {
            throw XCTSkip("no drawable in this session: \(presenter.lastFailure ?? "—")")
        }
        XCTAssertNil(presenter.lastFailure)
    }

    // MARK: - 2. the letterbox is grey, the photograph is untouched

    /// A canvas-sized frame with the photograph in the middle 50 % — the fit mode the user reported.
    /// Four corners `(15, 15, 15)`; every pixel inside the picture's rect identical to the same render
    /// without a picture rect, which is byte-for-byte what this pass wrote before 054 existed.
    func testFitLetterboxCornersAreMatteGreyAndThePictureIsUntouched() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 640, height: 480)
        let picture = ImageRect(x: 160, y: 120, width: 320, height: 240)
        let src = try letterboxed(device, canvas, picture: picture)

        for linear in [true, false] {
            let format: MTLPixelFormat = linear ? .rgba16Float : .bgra8Unorm
            let matteTarget = try makeTexture(device, canvas.width, canvas.height, format,
                                              [.shaderRead, .renderTarget])
            let reference = try makeTexture(device, canvas.width, canvas.height, format,
                                            [.shaderRead, .renderTarget])
            XCTAssertTrue(presenter.render(src, window: .whole, pictureRect: picture,
                                           into: matteTarget, linearize: linear),
                          presenter.lastFailure ?? "the present pass failed")
            // No picture rect = the pre-054 pass, exactly.
            XCTAssertTrue(presenter.render(src, window: .whole, into: reference, linearize: linear),
                          presenter.lastFailure ?? "the present pass failed")

            // ①  the four corners.
            for (name, x, y) in [("top-left", 0, 0), ("top-right", canvas.width - 1, 0),
                                 ("bottom-left", 0, canvas.height - 1),
                                 ("bottom-right", canvas.width - 1, canvas.height - 1)] {
                let got = Self.displayCode(Self.pixel(matteTarget, x, y), linear: linear)
                XCTAssertEqual(got, 15, accuracy: 1, "\(name) is \(got) of 255, want 15 (#0F0F0F)")
            }
            // The letterbox is uniformly grey, not just at the corners: a row through the top band and a
            // column through the left band.
            for x in stride(from: 0, to: canvas.width, by: 37) {
                let got = Self.displayCode(Self.pixel(matteTarget, x, 3), linear: linear)
                XCTAssertEqual(got, 15, accuracy: 1, "letterbox row \(x),3 = \(got)")
            }
            for y in stride(from: 0, to: canvas.height, by: 41) {
                let got = Self.displayCode(Self.pixel(matteTarget, 7, y), linear: linear)
                XCTAssertEqual(got, 15, accuracy: 1, "letterbox column 7,\(y) = \(got)")
            }

            // ②  the photograph, byte for byte.
            var changed = 0
            var firstDifference: String?
            for y in picture.y..<picture.maxY {
                for x in picture.x..<picture.maxX {
                    let a = Self.bytes(matteTarget, x, y)
                    let b = Self.bytes(reference, x, y)
                    if a != b {
                        changed += 1
                        if firstDifference == nil {
                            firstDifference = "(\(x),\(y)): \(a) vs pre-054 \(b)"
                        }
                    }
                }
            }
            XCTAssertEqual(changed, 0,
                           "the matte moved \(changed) photograph pixels — \(firstDifference ?? "")")
            XCTAssertEqual(Self.hash(matteTarget, region: picture).exact,
                           Self.hash(reference, region: picture).exact,
                           "the picture region hashes differently after 054")
        }
    }

    // MARK: - 3. a frame that covers the canvas, and the anti-proof

    /// The photo fills the canvas: the picture's rect is the whole canvas, so the matte must never be
    /// reached and the frame must hash exactly as it did before 054 — on both output formats.
    func testAFrameThatCoversTheCanvasKeepsEveryByte() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 256, height: 192)
        let src = try pattern(device, canvas, size: canvas)
        let whole = ImageRect(x: 0, y: 0, width: canvas.width, height: canvas.height)

        let t16 = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                  [.shaderRead, .renderTarget])
        let t8 = try makeTexture(device, canvas.width, canvas.height, .bgra8Unorm,
                                 [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(src, window: .whole, pictureRect: whole, into: t16, linearize: true),
                      presenter.lastFailure ?? "the present pass failed")
        XCTAssertTrue(presenter.render(src, window: .whole, pictureRect: whole, into: t8, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")

        let h16 = Self.hash(t16), h8 = Self.hash(t8)
        XCTAssertEqual(h16.exact, Pre054.fullCoverLinear16.exact,
                       "a full-canvas frame no longer matches its pre-054 bytes (linear16)")
        XCTAssertEqual(h16.eightBit, Pre054.fullCoverLinear16.q8)
        XCTAssertEqual(h8.exact, Pre054.fullCoverSRGB8.exact,
                       "a full-canvas frame no longer matches its pre-054 bytes (srgb8)")
        XCTAssertEqual(h8.eightBit, Pre054.fullCoverSRGB8.q8)

        // And nothing on that frame is #0F0F0F-by-accident: the matte is nowhere on it.
        var matteColoured = 0
        for (x, y) in [(0, 0), (canvas.width - 1, 0), (0, canvas.height - 1),
                       (canvas.width / 2, canvas.height / 2), (13, 77)] {
            if abs(Self.displayCode(Self.pixel(t16, x, y), linear: true) - 15) <= 1 { matteColoured += 1 }
        }
        print("full-canvas frame: \(h16.exact.prefix(16))… unchanged; \(matteColoured) of 5 samples read 15")
    }

    /// **The anti-proof.** The same full-canvas frame, presented with a picture rect that covers none of
    /// it — i.e. what the shader would do if it painted the matte over the whole frame — must *not* hash
    /// to the pre-054 value. If this passes and the test above also passes, the hash guard has teeth.
    func testPaintingTheMatteOverTheWholeFrameIsRed() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 256, height: 192)
        let src = try pattern(device, canvas, size: canvas)
        let target = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])
        // A rect entirely off this canvas: every fragment is outside the picture.
        let nowhere = ImageRect(x: canvas.width * 4, y: canvas.height * 4, width: 8, height: 8)
        XCTAssertTrue(presenter.render(src, window: .whole, pictureRect: nowhere, into: target, linearize: true),
                      presenter.lastFailure ?? "the present pass failed")

        let h = Self.hash(target)
        XCTAssertNotEqual(h.exact, Pre054.fullCoverLinear16.exact,
                          "a frame painted entirely with the matte still hashes like the photograph — "
                          + "the full-canvas guard would not catch a matte over the whole frame")
        for (name, x, y) in [("top-left", 0, 0), ("centre", canvas.width / 2, canvas.height / 2),
                             ("bottom-right", canvas.width - 1, canvas.height - 1)] {
            let got = Self.displayCode(Self.pixel(target, x, y), linear: true)
            XCTAssertEqual(got, 15, accuracy: 1, "\(name) = \(got), want 15 when everything is matte")
        }
        print("anti-proof: matte over the whole frame hashes \(h.exact.prefix(16))… ≠ pre-054 "
              + "\(Pre054.fullCoverLinear16.exact.prefix(16))…")
    }

    // MARK: - 4. the backdrop branch is untouched

    /// 037/053: with a backdrop the canvas outside the main window is the photograph's own low-res
    /// continuation. Passing the picture rect must change nothing there, and the corner must be the
    /// backdrop's colour — not `#0F0F0F`.
    func testWithABackdropTheCanvasOutsideTheWindowIsStillThePicture() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 512, height: 512)
        let frame = try solid(device, 256, 256, [0.42, 0.66, 0.18, 1])
        let backdrop = try solid(device, 512, 512, [0.90, 0.20, 0.60, 1])
        // A centred half-canvas window: the main frame occupies the middle quarter of the canvas.
        let window = PresentWindow(u0: -0.5, v0: -0.5, du: 2, dv: 2)
        let picture = ImageRect(x: 128, y: 128, width: 256, height: 256)

        let withRect = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                       [.shaderRead, .renderTarget])
        let withoutRect = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                          [.shaderRead, .renderTarget])
        // Display-encoded storage (`linearize: false`) so the fixture's colours read back as written.
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       pictureRect: picture, into: withRect, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       into: withoutRect, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")

        XCTAssertEqual(Self.hash(withRect).exact, Self.hash(withoutRect).exact,
                       "the picture rect must not reach the backdrop branch")
        for (name, x, y) in [("top-left", 0, 0), ("top-right", canvas.width - 1, 0),
                             ("bottom-left", 0, canvas.height - 1)] {
            let got = Self.pixel(withRect, x, y)
            XCTAssertEqual(Double(got[0]), 0.90, accuracy: 1.0 / 255, "\(name) r")
            XCTAssertEqual(Double(got[1]), 0.20, accuracy: 1.0 / 255, "\(name) g")
            XCTAssertEqual(Double(got[2]), 0.60, accuracy: 1.0 / 255, "\(name) b")
        }
        let inside = Self.pixel(withRect, canvas.width / 2, canvas.height / 2)
        XCTAssertEqual(Double(inside[0]), 0.42, accuracy: 1.0 / 255, "the main frame is still the frame")
        print("backdrop: corners are the backdrop (0.90, 0.20, 0.60), centre is the frame; "
              + "picture rect changed no byte")
    }

    // MARK: - 5. the histogram cannot see it

    /// The histogram measures **S4's texture** over `pictureRect` (048/049), and the matte is painted
    /// later, in the present pass. A real render with a real letterbox: the frame's own corner is still
    /// exactly `0`, the bins are per-bin equal before and after the matte is drawn, and the presented
    /// canvas — where the same corner *is* grey — is what changed.
    func testTheMatteNeverEntersTheFrameTheHistogramMeasures() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let graph = try RenderGraph(input: RenderInput(image: asymmetricImage(),
                                                       identity: "canvas-matte-grey"))
        let canvas = ImageSize(width: 1200, height: 800)
        let options = RenderOptions(canvas: canvas, scale: 1, outputWindow: nil,
                                    display: DisplayOptions(primaries: .sRGB, bitDepth: 16, headroom: 1),
                                    useCache: false, wantsPixels: false,
                                    collectHistogram: false, histogramBins: 256)
        let result = try graph.render(.neutral, options: options)
        let texture = try XCTUnwrap(result.output, "the render handed back no texture")
        defer { graph.recycle(output: texture) }
        // 2400×800 fitted into 1200×800: bars above and below, the photograph in the middle.
        XCTAssertEqual(result.pictureRect, ImageRect(x: 0, y: 200, width: 1200, height: 400),
                       "the fixture's letterbox is not where this test assumes it is")

        let before = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral, bins: 256,
                                                     content: result.pictureRect)
        for channel in Histogram.Channel.allCases {
            XCTAssertGreaterThan(before.histogram[channel].bins.reduce(0, +), 0,
                                 "\(channel) measured nothing")
        }
        // The letterbox in the texture is exactly the present pass's problem, not the histogram's: the
        // frame's own corner is still S2/S4's `float4(0, 0, 0, ·)`.
        let frameCorner = Self.pixel(texture, 0, 0)
        XCTAssertEqual(frameCorner[0], 0, "the frame's corner r must still be S2/S4's zero")
        XCTAssertEqual(frameCorner[1], 0, "… g")
        XCTAssertEqual(frameCorner[2], 0, "… b")

        // Paint the matte on top of that frame, at the canvas size the frame was rendered for.
        let presenter = try CanvasPresenter(device: device)
        let presented = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                        [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(texture, window: .whole, pictureRect: result.pictureRect,
                                       into: presented, linearize: true),
                      presenter.lastFailure ?? "the present pass failed")
        let corner = Self.displayCode(Self.pixel(presented, 0, 0), linear: true)
        XCTAssertEqual(corner, 15, accuracy: 1, "the presented canvas corner is not #0F0F0F")

        let after = try graph.measureFrameHistogram(fromFrame: texture, edit: .neutral, bins: 256,
                                                    content: result.pictureRect)
        var checked = 0
        for channel in Histogram.Channel.allCases {
            XCTAssertEqual(after.histogram[channel].bins, before.histogram[channel].bins,
                           "\(channel): the matte moved the bins — it must not be in the texture")
            checked += before.histogram[channel].bins.count
        }
        XCTAssertGreaterThan(before.histogram.red.bins[0], 0,
                             "the fixture has no photograph black at all")
        print("histogram: \(checked) bins × 3 channels identical before/after the matte; "
              + "frame corner (0,0,0) — canvas corner \(corner)")
    }

    // MARK: - fixtures

    private static var kernelURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // PhotonsUITests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // the package root
            .appendingPathComponent("Sources/PhotonsCore/Kernels/present.metal")
    }

    private static var loupeURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/LoupeController.swift")
    }

    /// The text of one fragment function, brace-balanced — the same shape `BackdropPresenterTests` uses
    /// to assert what each entry point is allowed to read.
    private static func fragmentSignature(_ name: String, in source: String) -> String? {
        guard let start = source.range(of: "fragment float4 \(name)(") else { return nil }
        var depth = 0
        var seenBrace = false
        var index = start.lowerBound
        while index < source.endIndex {
            let c = source[index]
            if c == "{" { depth += 1; seenBrace = true }
            if c == "}" {
                depth -= 1
                if seenBrace && depth == 0 {
                    return String(source[start.lowerBound...index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func makeTexture(_ device: MTLDevice, _ w: Int, _ h: Int, _ format: MTLPixelFormat,
                             _ usage: MTLTextureUsage) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h,
                                                         mipmapped: false)
        d.usage = usage
        d.storageMode = .managed
        return try XCTUnwrap(device.makeTexture(descriptor: d), "no texture")
    }

    /// A 2400×800 picture: bright top half, dark bottom half, a mid-grey border, and a pure-black block
    /// near the top-left only — asymmetric, so a y-flip or a shifted rect cannot pass.
    private func asymmetricImage(width: Int = 2400, height: Int = 800) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var v = y < height / 2 ? 0.62 : 0.08
                if x < 40 || x >= width - 40 || y < 40 || y >= height - 40 { v = 0.35 }
                if x >= 200 && x < 400 && y >= 60 && y < 220 { v = 0 }
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v); rgba[o + 2] = Float16(v)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func solid(_ device: MTLDevice, _ w: Int, _ h: Int, _ rgba: [Float]) throws -> MTLTexture {
        try fill(device, ImageSize(width: w, height: h)) { _, _ in rgba }
    }

    /// A picture of the given size, tiled over the canvas, with structure at every scale so a wrong
    /// window, filter or clamp all move the hash.
    private func pattern(_ device: MTLDevice, _ canvas: ImageSize, size: ImageSize) throws -> MTLTexture {
        try fill(device, canvas) { x, y in
            let fx = Float(x % max(size.width, 1)) / Float(max(size.width - 1, 1))
            let fy = Float(y % max(size.height, 1)) / Float(max(size.height - 1, 1))
            let check: Float = ((x / 3) + (y / 3)) % 2 == 0 ? 1.0 : 0.0
            return [0.1 + 0.8 * fx, 0.2 + 0.6 * fy, check * 0.7, 1]
        }
    }

    /// Exactly what a fit frame looks like coming out of S2/S4: the picture inside `picture`, and
    /// `float4(0, 0, 0, 1)` for every pixel that is not the photograph.
    private func letterboxed(_ device: MTLDevice, _ canvas: ImageSize,
                             picture: ImageRect) throws -> MTLTexture {
        try fill(device, canvas) { x, y in
            let inside = x >= picture.x && x < picture.maxX && y >= picture.y && y < picture.maxY
            guard inside else { return [0, 0, 0, 1] }
            let fx = Float(x - picture.x) / Float(max(picture.width - 1, 1))
            let fy = Float(y - picture.y) / Float(max(picture.height - 1, 1))
            let check: Float = ((x / 3) + (y / 3)) % 2 == 0 ? 1.0 : 0.0
            return [0.1 + 0.8 * fx, 0.2 + 0.6 * fy, check * 0.7, 1]
        }
    }

    private func fill(_ device: MTLDevice, _ size: ImageSize,
                      _ value: (Int, Int) -> [Float]) throws -> MTLTexture {
        let t = try makeTexture(device, size.width, size.height, .rgba16Float, [.shaderRead])
        var row = [UInt16](repeating: 0, count: size.width * 4)
        for y in 0..<size.height {
            for x in 0..<size.width {
                let v = value(x, y)
                for c in 0..<4 { row[x * 4 + c] = Float16(v[c]).bitPattern }
            }
            row.withUnsafeBytes { buf in
                t.replace(region: MTLRegionMake2D(0, y, size.width, 1), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: size.width * 8)
            }
        }
        return t
    }

    private static func bytesPerRow(_ t: MTLTexture) -> Int {
        t.width * 4 * (t.pixelFormat == .rgba16Float ? 2 : 1)
    }

    /// One texel's stored bytes: the comparison that is not allowed to move by even one ulp.
    private static func bytes(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        let bpr = bytesPerRow(t) / t.width
        var raw = [UInt8](repeating: 0, count: bpr)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: bpr, from: MTLRegionMake2D(x, y, 1, 1),
                       mipmapLevel: 0)
        }
        return raw
    }

    /// Decoded to `[Float]` (16-bit) or `[UInt8]`-widened floats (8-bit), RGBA order.
    private static func pixel(_ t: MTLTexture, _ x: Int, _ y: Int) -> [Float] {
        let raw = bytes(t, x, y)
        if t.pixelFormat == .rgba16Float {
            return stride(from: 0, to: raw.count, by: 2).map {
                Float(Float16(bitPattern: UInt16(raw[$0]) | (UInt16(raw[$0 + 1]) << 8)))
            }
        }
        // bgra8Unorm: b, g, r, a — handed back as r, g, b, a.
        return [Float(raw[2]) / 255, Float(raw[1]) / 255, Float(raw[0]) / 255, Float(raw[3]) / 255]
    }

    /// The 8-bit code a display shows for a stored value, i.e. `#0F0F0F` reads as 15 on both paths.
    private static func displayCode(_ pixel: [Float], linear: Bool) -> Double {
        let v = Double(pixel[0])
        let display = linear ? (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055) : v
        return (display * 255).rounded()
    }

    /// `exact` = the stored bits; `q8` = the same pixels quantised to 8 bits, per channel.
    private static func hash(_ t: MTLTexture, region: ImageRect? = nil) -> (exact: String, eightBit: String) {
        let all = ImageRect(x: 0, y: 0, width: t.width, height: t.height)
        let rect = region ?? all
        let texel = bytesPerRow(t) / t.width
        let rowBytes = rect.width * texel
        var raw = [UInt8](repeating: 0, count: rowBytes * rect.height)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: rowBytes,
                       from: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height), mipmapLevel: 0)
        }
        let exact = SHA256.hash(data: Data(raw)).map { String(format: "%02x", $0) }.joined()
        var q = [UInt8]()
        q.reserveCapacity(rect.width * rect.height * 3)
        if t.pixelFormat == .rgba16Float {
            for i in stride(from: 0, to: raw.count, by: 2) {
                let f = Float(Float16(bitPattern: UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)))
                q.append(UInt8(max(0, min(255, (f * 255).rounded()))))
            }
        } else {
            for i in stride(from: 0, to: raw.count, by: 4) { q.append(raw[i + 2]) }
            for i in stride(from: 0, to: raw.count, by: 4) { q.append(raw[i + 1]) }
            for i in stride(from: 0, to: raw.count, by: 4) { q.append(raw[i]) }
        }
        let eight = SHA256.hash(data: Data(q)).map { String(format: "%02x", $0) }.joined()
        return (exact, eight)
    }
}
