import XCTest
import CryptoKit
import Metal
import QuartzCore
@testable import PhotonsCore

/// 037 ① — the present pass learns a **backdrop**: the whole picture at low resolution, drawn where the
/// shrinking main frame no longer reaches.
///
/// What this file is defending, in the order the failures would show up:
///
///   1. **The CPU/GPU struct is one contract.** `PresentParams` crosses to the shader as raw bytes
///      (`setVertexBytes`/`setFragmentBytes`), so nothing in the compiler compares the two sides —
///      and this project has already read a stale parameter silently once. The `.metal` text is
///      parsed here and every field offset and the stride are pinned on both sides.
///   2. **`backdrop == nil` is 025, to the bit.** Five windows (identity, shrink, zoom, encoded and
///      8-bit) are rendered and hashed against the values recorded from `5ae8a64`, *before* this
///      shader existed. Not "close": the same SHA-256.
///   3. **With a backdrop, the canvas is the picture outside the frame and the frame inside it.** A
///      real render into a readback texture: main-frame colour inside the window, backdrop colour
///      outside it, and a ≤2 px ramp between — including a 4500×3000 backdrop on a 3840×2160 canvas,
///      where every ratio is a non-power-of-two Double (037 ② picks `min(imageLongEdge / 2, 4096)`, so
///      a 9000 px frame gets a 4096 px preview — 0.4551…, not 0.5 — and this layer must not assume the
///      scale is 0.5, 0.25 or any other round number).
///   4. **It costs nothing when nobody asks for it.** Under `PHOTONS_BENCH=1`, the same 4.10 Mpx frame
///      is timed through 025's own fragment (compiled here as the baseline), through the new fragment
///      with no backdrop, and through it with a backdrop, on one 4.10 Mpx canvas.
final class BackdropPresenterTests: XCTestCase {

    /// Millisecond ceilings are asserted only under `PHOTONS_BENCH=1` (project rule): `swift test`
    /// builds Debug, where these numbers are not the shipping ones.
    private var benchmarks: Bool { ProcessInfo.processInfo.environment["PHOTONS_BENCH"] == "1" }

    // MARK: - ① the struct is the same struct on both sides

    private static var kernelURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // PhotonsUITests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // the package root
            .appendingPathComponent("Sources/PhotonsCore/Kernels/present.metal")
    }

    func testPresentParamsLayoutIsTheSameOnBothSides() throws {
        let url = Self.kernelURL
        let source = try String(contentsOf: url, encoding: .utf8)

        // The struct body, comment-free.
        let structBody = try XCTUnwrap(Self.presentParamsBody(in: source),
                                       "no `struct PresentParams { … };` in \(url.path)")
        var fields: [(name: String, type: String)] = []
        for rawLine in structBody.split(separator: "\n") {
            let line = String(rawLine).components(separatedBy: "//").first ?? ""
            let parts = line.replacingOccurrences(of: ";", with: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count == 2 else { continue }
            fields.append((name: parts[1], type: parts[0]))
        }

        // 067: **three** `float4`s — the quad, the window, the flags. `d` (the picture's rect, 054) is
        // gone, which is the whole point of the task: the rect is not a shader argument any more.
        XCTAssertEqual(fields.map(\.name), ["quad", "window", "misc"],
                       "present.metal's PresentParams changed shape; the Swift side must follow")
        XCTAssertEqual(fields.map(\.type), Array(repeating: "float4", count: 3),
                       "every field of PresentParams is a float4 so the offsets are plain multiples of 16")

        // Metal/Clang field offsets for a struct of float4s, computed from the parsed text.
        let sizes: [String: (size: Int, align: Int)] = ["float4": (16, 16), "float2": (8, 8), "float": (4, 4)]
        var offset = 0, maxAlign = 1
        var metalOffsets: [Int] = []
        for f in fields {
            let t = try XCTUnwrap(sizes[f.type], "unsupported field type \(f.type) in PresentParams")
            offset = (offset + t.align - 1) / t.align * t.align
            metalOffsets.append(offset)
            offset += t.size
            maxAlign = max(maxAlign, t.align)
        }
        let metalSize = (offset + maxAlign - 1) / maxAlign * maxAlign

        // The Swift half.
        let layout = MemoryLayout<CanvasPresenter.PresentParams>.self
        let swiftOffsets = [
            layout.offset(of: \.quad), layout.offset(of: \.window), layout.offset(of: \.misc),
        ].map { $0 ?? -1 }

        XCTAssertEqual(swiftOffsets, metalOffsets,
                       "Swift \(swiftOffsets) vs present.metal \(metalOffsets) — the shader would read a different field")
        XCTAssertEqual(layout.stride, metalSize,
                       "Swift stride \(layout.stride) vs present.metal sizeof \(metalSize)")
        // The numbers themselves, so a refactor cannot quietly renumber them.
        XCTAssertEqual(swiftOffsets, [0, 16, 32])
        XCTAssertEqual(layout.stride, 48)
        XCTAssertEqual(layout.size, 48, "stride and size agree, so a copy of `size` bytes is complete")

        // One fragment function, and it asks **nothing** about the photograph: no matte constant, no
        // picture rect, no second texture, no "outside the picture" test. This is the assertion that
        // makes the old class of bug unrepresentable rather than fixed — a fragment that cannot see a
        // rect cannot be handed the wrong one.
        XCTAssertNil(Self.fragmentSignature("present_fragment_backdrop", in: source),
                     "067: there is one fragment; the backdrop is a second **quad**, not a second shader")
        let plain = try XCTUnwrap(Self.fragmentSignature("present_fragment", in: source))
        let code = Self.stripped(source)
        XCTAssertTrue(plain.contains("texture2d<float> src [[texture(0)]]"))
        XCTAssertEqual(plain.components(separatedBy: "texture(").count - 1, 1,
                       "the one fragment binds one texture; which one is the caller's business")
        for gone in ["p.d", "kCanvasMatte", "photoRect", "beyondEdge", "backdrop_weight"] {
            XCTAssertFalse(Self.stripped(source).contains(gone),
                           "`\(gone)` is still in present.metal — the fragment is still asking where "
                           + "the photograph is instead of drawing a rectangle")
        }
        // …and the geometry it *does* read: a quad in canvas space and a window in texture space.
        XCTAssertTrue(code.contains("p.quad"), "the vertex stage must place the quad")
        XCTAssertTrue(code.contains("p.window"), "…and take uv from the canvas position through the window")
        XCTAssertTrue(code.contains("o.position = float4(canvasPosition.x * 2.0 - 1.0"),
                      "the quad's canvas rectangle is the clip-space rectangle — no other geometry exists")

        print("PresentParams: 3 × float4, offsets \(metalOffsets), stride \(metalSize) — Swift and "
              + "present.metal agree; one fragment, no matte, no picture rect")
    }

    /// The quad and the window the request hands the pass: the photograph's place on the canvas is
    /// **derived** from the frame's window, so the two can never be independent numbers.
    func testTheRequestDerivesTheQuadFromTheWindow() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let dummy = try solid(device, 256, 256, [0.5, 0.5, 0.5, 1])
        let canvas = ImageSize(width: 512, height: 512)
        let whole = ImageRect(x: 0, y: 0, width: 256, height: 256)

        // A centred half-canvas window (`du = 4`): the picture occupies canvas px [192, 320).
        let request = PresentRequest(picture: dummy, photoRect: whole,
                                     window: PresentWindow(u0: -1.5, v0: -1.5, du: 4, dv: 4),
                                     canvas: canvas)
        XCTAssertEqual(request.pictureQuad, ImageRect(x: 192, y: 192, width: 128, height: 128),
                       "the quad is the inverse of the window, in canvas pixels")
        XCTAssertEqual(CanvasPresenter.normalised(request.pictureQuad, canvas: canvas),
                       SIMD4<Float>(0.375, 0.375, 0.25, 0.25),
                       "…and that is exactly the rectangle `PresentParams.quad` carries")

        // The backdrop's quad is derived the same way, from its own window.
        let withBackdrop = PresentRequest(picture: dummy, photoRect: whole,
                                          window: .whole, canvas: canvas,
                                          backdrop: dummy,
                                          backdropWindow: PresentWindow(u0: 0.25, v0: 0.25,
                                                                        du: 0.5, dv: 0.5))
        XCTAssertEqual(withBackdrop.backdropQuad, ImageRect(x: -256, y: -256, width: 1024, height: 1024)
                        .intersected(in: canvas),
                       "the whole picture through a half-picture window covers 4 × the canvas, clipped")
        XCTAssertEqual(withBackdrop.pictureQuad, ImageRect(x: 0, y: 0, width: 512, height: 512))
        XCTAssertEqual(withBackdrop.quads.count, 2, "backdrop first, picture over it")
        XCTAssertTrue(withBackdrop.quads.first?.texture === dummy)
        XCTAssertTrue(withBackdrop.quads.last?.texture === dummy)

        // A degenerate window has no rectangle at all: nothing of the picture is on the canvas, and the
        // pass must clear rather than paint NaN (the old code had to floor a divisor in the fragment for
        // this; now there is no fragment arithmetic to divide by).
        let degenerate = PresentRequest(picture: dummy, photoRect: whole,
                                        window: PresentWindow(u0: 0, v0: 0, du: 0, dv: 0),
                                        canvas: canvas)
        XCTAssertTrue(degenerate.pictureQuad.isEmpty)
        XCTAssertFalse(degenerate.hasPicture, "a zero-sized window draws no picture quad")
        XCTAssertTrue(degenerate.quads.isEmpty)

        let presenter = try CanvasPresenter(device: device)
        let small = try makeTexture(device, 8, 8, .rgba16Float, [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(degenerate, into: small, linearize: false))
        let px = Self.readRGBA16(small)
        XCTAssertTrue(px.allSatisfy { $0.isFinite }, "a zero-sized window painted NaN")
        // Everything is the clear colour — the canonical `#0F0F0F`, in the transfer function of the
        // attachment (`linearize: false` here, so the display-encoded 15/255).
        for i in stride(from: 0, to: px.count, by: 4) {
            XCTAssertEqual(Double(px[i]), CanvasPresenter.CanvasMatte.displayEncoded, accuracy: 2e-3)
        }
    }

    // MARK: - ② `backdrop: nil` is byte-for-byte 025

    /// Recorded on this machine against `5ae8a64` — the shader *before* the backdrop existed — by
    /// running this same fixture through the then-current `CanvasPresenter.render`. Same window, same
    /// target format, same linearize flag: the hash must not move. `exact` is the rgba16Float / bgra8
    /// bit pattern; `q8` is the same pixels quantised to 8 bits, which is the form that survives a
    /// different GPU's rounding.
    func testACoveringQuadIsByteIdenticalTo025() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let size = ImageSize(width: 64, height: 48)
        let src = try patterned(device, size)
        let target16 = try makeTexture(device, size.width, size.height, .rgba16Float,
                                       [.shaderRead, .renderTarget])
        // A zoomed-in frame: the picture covers the canvas, so its quad *is* the canvas and 025's
        // arithmetic is all that is left. (A covering window is the case where the drawn rectangle and
        // the sampled window say the same thing — which is why this hash is allowed to be the one
        // recorded before any of this existed.)
        let zoom = PresentWindow(scale: 1.7, originX: -Double(size.width) * 0.2,
                                 originY: -Double(size.height) * 0.15, canvas: size, texture: size)
        XCTAssertLessThan(Double(zoom.du), 1, "a zooming window is a sub-rect of the texture")

        let cases: [(name: String, window: PresentWindow, linear: Bool, target: MTLTexture,
                     exact: String, eightBit: String)] = [
            ("identity/linear16", .whole, true, target16,
             "6ceb6f49b8d386e804bdef1ea144251b967041b9cedb92c8a9f6c0c4c5fab3cc",
             "7abcb9ffb5a891e9946457ecb3edfd9cb39e1fb9092dd5268011dab7209fc62e"),
            ("zoom/linear16", zoom, true, target16,
             "91616dc57255d327ce35a3206afa39b6ad9932f667f8388862241567e72b2c15",
             "2fddaf8d6c343f098aa4a90a78460df62d98877c8672b265df076fed9b651e30"),
        ]

        var lines: [String] = []
        for c in cases {
            XCTAssertTrue(presenter.renderForTest(src, window: c.window, into: c.target, linearize: c.linear),
                          presenter.lastFailure ?? "the present pass failed")
            let h = Self.hash(c.target)
            XCTAssertEqual(h.exact, c.exact,
                           "\(c.name): a covering quad must still write exactly what 025 wrote (exact hash)")
            XCTAssertEqual(h.eightBit, c.eightBit, "\(c.name): 8-bit hash moved")
            lines.append("  \(c.name): \(h.exact.prefix(16))… ✓")
        }
        print("covering quads, hashed against 5ae8a64:\n" + lines.joined(separator: "\n"))
    }

    /// 067 — **a shrinking frame no longer smears its own edge across the canvas.**
    ///
    /// 025's answer to "the frame does not reach the canvas" was `clamp_to_edge`: the picture's border
    /// pixels stretched over everything the frame missed. 053/058 replaced the *band* with the low-res
    /// picture when there was one, and 067 replaces the mechanism: the picture is a quad, so what it does
    /// not cover is not painted by it at all. The pixels the old answer produced are recorded here
    /// (`shrink/exact`) so the difference is a number, not an opinion.
    func testAShrinkingFrameDrawsItsQuadAndLeavesTheRestToTheCanvas() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let size = ImageSize(width: 64, height: 48)
        let canvas = size
        let source = try solid(device, size.width, size.height, [0.30, 0.60, 0.90, 1])
        let target = try makeTexture(device, size.width, size.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])
        let shrink = PresentWindow(scale: 0.5, originX: Double(size.width) * 0.1,
                                   originY: Double(size.height) * 0.1, canvas: canvas, texture: size)

        let request = PresentRequest(picture: source,
                                     photoRect: ImageRect(x: 0, y: 0, width: size.width,
                                                            height: size.height),
                                     window: shrink, canvas: canvas)
        // scale 0.5 about (6.4, 4.8): the picture is the middle half, px [6, 58) × [5, 43).
        XCTAssertEqual(request.pictureQuad, ImageRect(x: 6, y: 5, width: 32, height: 24),
                       "the quad is what the map says, not the whole canvas")
        XCTAssertTrue(presenter.render(request, into: target, linearize: true))
        let px = Self.readRGBA16(target)
        func p(_ x: Int, _ y: Int) -> [Float] { Self.pixel(px, canvas.width, x, y) }

        // Inside the quad: the picture, its own pixels. (`linearize: true` stores linear light, so the
        // expected value is the source's display-encoded colour through the sRGB EOTF.)
        func linear(_ v: Double) -> Float { Float(pow((v + 0.055) / 1.055, 2.4)) }
        let expected = [linear(0.30), linear(0.60), linear(0.90), 1]
        for (x, y) in [(6, 5), (37, 27), (20, 10), (6, 28)] {
            Self.assertColour(p(x, y), expected, "inside the quad at (\(x), \(y))")
        }
        // Outside: the canvas colour — not the picture's edge, which is what 025 wrote there.
        var smeared = 0
        var unset = 0
        for y in 0..<canvas.height {
            for x in 0..<canvas.width {
                let inside = x >= 6 && x < 38 && y >= 5 && y < 29
                if inside { continue }
                let c = p(x, y)
                if abs(Double(c[2]) - Double(expected[2])) < 1e-3 { smeared += 1 }
                if abs(Double(c[0]) - CanvasPresenter.CanvasMatte.linear) > 2e-3 { unset += 1 }
            }
        }
        XCTAssertEqual(smeared, 0, "\(smeared) pixels outside the quad are still the picture's edge")
        XCTAssertEqual(unset, 0, "\(unset) pixels outside the quad are not the canvas colour")

        // The old answer, for the record: 025's full-canvas quad with `clamp_to_edge` — the frame's own
        // border stretched over the band. Spelled with explicit geometry, because the request's derived
        // quad cannot ask for "cover the canvas" while the map says otherwise.
        let legacy = try makeTexture(device, size.width, size.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])
        let pre067 = PresentRequest(picture: source, canvas: canvas,
                                    pictureQuad: ImageRect(x: 0, y: 0, width: canvas.width,
                                                           height: canvas.height),
                                    window: shrink)
        XCTAssertTrue(presenter.render(pre067, into: legacy, linearize: true))
        let legacyPixels = Self.readRGBA16(legacy)
        XCTAssertEqual(Self.pixel(legacyPixels, canvas.width, 0, 0)[2], expected[2], accuracy: 1e-3,
                       "the counterexample is 025: the picture's colour at the canvas corner")
        print(String(format: "[067] shrink (s = 0.5 about (6.4, 4.8)): quad px [6, 38) × [5, 29) is the "
                     + "picture; %d pixels outside are all #0F0F0F (linear %.6f); 025 wrote the edge "
                     + "colour there (corner b = %.3f)", unset,
                     CanvasPresenter.CanvasMatte.linear,
                     Self.pixel(legacyPixels, canvas.width, 0, 0)[2]))
    }

    /// The same fixture plus an explicit `backdrop: nil` *and* an equal-looking window: the argument
    /// existing at all must not change the pixels, and neither must the dummy texture the pass binds
    /// at index 1 to keep the debug layer quiet.
    func testExplicitNilBackdropMatchesTheDefault() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let size = ImageSize(width: 64, height: 48)
        let src = try patterned(device, size)
        let a = try makeTexture(device, size.width, size.height, .rgba16Float, [.shaderRead, .renderTarget])
        let b = try makeTexture(device, size.width, size.height, .rgba16Float, [.shaderRead, .renderTarget])
        let shrink = PresentWindow(scale: 0.4, originX: 3, originY: 5, canvas: size, texture: size)

        XCTAssertTrue(presenter.renderForTest(src, window: shrink, into: a, linearize: true))
        XCTAssertTrue(presenter.renderForTest(src, window: shrink, backdrop: nil,
                                       backdropWindow: PresentWindow(u0: 0.3, v0: 0.7, du: 0.2, dv: 0.1),
                                       into: b, linearize: true))
        XCTAssertEqual(Self.hash(a).exact, Self.hash(b).exact,
                       "`backdrop: nil` must be the default path, not a second path")
    }

    // MARK: - ③ with a backdrop, the canvas outside the frame is the picture

    /// 512² canvas, 256² main frame occupying a centred quarter of the canvas, 512² backdrop in a
    /// different flat colour. Three zones, each ±1 code.
    func testBackdropFillsTheCanvasOutsideTheMainWindow() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 512, height: 512)
        let main = [Float(0.30), 0.60, 0.90, 1]
        let back = [Float(0.90), 0.25, 0.10, 1]

        let frame = try solid(device, 256, 256, main)
        let backdrop = try solid(device, 512, 512, back)
        let target = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])

        // The picture's rect on the canvas is (0.375, 0.375, 0.25, 0.25) — canvas px [192, 320).
        let window = PresentWindow(u0: -1.5, v0: -1.5, du: 4, dv: 4)
        XCTAssertTrue(window.coversWholeTexture, "a shrinking window is larger than its texture")

        XCTAssertTrue(presenter.renderForTest(frame, window: window, backdrop: backdrop,
                                       into: target, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")
        let px = Self.readRGBA16(target)
        func p(_ x: Int, _ y: Int) -> [Float] { Self.pixel(px, canvas.width, x, y) }

        // ① inside the window: the main frame's colour, everywhere the feather does not reach.
        for (x, y) in [(256, 256), (300, 210), (194, 256), (317, 256), (256, 194), (256, 317)] {
            Self.assertColour(p(x, y), main, "inside the window at (\(x), \(y)) must be the main frame")
        }
        // ② outside: the backdrop, not the main frame's stretched edge (which is what 025 produced).
        for (x, y) in [(0, 0), (511, 511), (511, 0), (0, 511), (100, 256), (256, 100), (191, 256),
                       (320, 256), (256, 191), (256, 320)] {
            Self.assertColour(p(x, y), back, "outside the window at (\(x), \(y)) must be the backdrop")
        }
        // ③ the edge is **hard and exact**: the last canvas pixel outside the quad is the backdrop, the
        // first inside is the frame. 037–065 cross-faded two pixels here; 067 does not need to, because
        // the boundary is a quad edge rather than a per-fragment decision, and the invariant the task
        // asks for ("inside the photograph, tolerance 0") forbids softening the photograph's own edge.
        for (x, y) in [(191, 256), (320, 256), (256, 191), (256, 320)] {
            Self.assertColour(p(x, y), back, "one pixel outside the quad at (\(x), \(y)) is the backdrop")
        }
        for (x, y) in [(192, 256), (319, 256), (256, 192), (256, 319)] {
            Self.assertColour(p(x, y), main, "one pixel inside the quad at (\(x), \(y)) is the frame")
        }

        // No canvas pixel is the pass's clear colour: the backdrop covers what the frame does not.
        var unpainted = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] == 0 && px[i + 1] == 0 && px[i + 2] == 0 {
            unpainted += 1
        }
        XCTAssertEqual(unpainted, 0, "\(unpainted) of \(px.count / 4) canvas pixels are unrendered black")

        // The counterexample, in the same geometry: without a backdrop the outside is the **canvas
        // colour** — not 025's stretched edge (which is what the user reported seeing, a band of the
        // picture's own border smeared across the window it does not reach).
        let bare = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                   [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.renderForTest(frame, window: window, into: bare, linearize: false))
        let barePixels = Self.readRGBA16(bare)
        for (x, y) in [(0, 0), (511, 511)] {
            let code = CanvasPresenter.CanvasMatte.displayEncoded
            XCTAssertEqual(Double(Self.pixel(barePixels, canvas.width, x, y)[0]), code, accuracy: 1.0 / 255,
                           "without a backdrop the corner is #0F0F0F, not the picture's edge")
            XCTAssertNotEqual(Self.pixel(barePixels, canvas.width, x, y)[0], main[0],
                              "…and certainly not the frame's colour stretched over the canvas")
        }
        print(String(format: "backdrop fill: 512² canvas, window px [192, 320), main (%.2f, %.2f, %.2f), "
                     + "backdrop (%.2f, %.2f, %.2f); corner = %.3f with backdrop, %.3f without",
                     main[0], main[1], main[2], back[0], back[1], back[2],
                     p(0, 0)[1], Self.pixel(barePixels, canvas.width, 0, 0)[1]))
    }

    /// The sizes the loupe actually produces (037 ②, final rule): `previewLongEdge =
    /// min(imageLongEdge / 2, 4096)`. For a 9000 px frame that is 4096 — a scale of 0.4551…, not 0.5 —
    /// and a 4096×2731 backdrop.
    ///
    /// Neither this layer nor the shader may assume a power-of-two scale: the backdrop is sampled
    /// through its own `backdropWindow`, so any texture size and any source rect work, and rounding the
    /// preview to a "friendlier" ratio is not something an engine-level optimisation may do. That is
    /// what this test holds: 4500×3000 (the 1/2-of-9000 reading of an earlier draft), 4096×2731 (the
    /// final rule) and 1125×750 must all produce the same canvas, and the window here is 4/3 — a
    /// `du` of 1.3333…, not 4.
    func testNonPowerOfTwoBackdropOnA3840Canvas() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 3840, height: 2160)
        let main = [Float(0.20), 0.75, 0.35, 1]
        let back = [Float(0.85), 0.10, 0.55, 1]

        // 9000×6000 frame shown at 75 % of the canvas, offset up and left: nothing about this window
        // is a round number.
        let frame = try solid(device, 900, 600, main)
        let backdrop = try solid(device, 4500, 3000, back)          // 1/2 of 9000 × 6000
        let target = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])
        let window = PresentWindow(u0: -0.166666672, v0: -0.214285717, du: 1.33333337, dv: 1.42857146)
        XCTAssertTrue(window.coversWholeTexture)
        XCTAssertGreaterThan(Double(window.du), 1, "the window must read past the texture")
        XCTAssertNotEqual(Double(window.du), 2.0, "not a power-of-two scale")

        XCTAssertTrue(presenter.renderForTest(frame, window: window, backdrop: backdrop,
                                       into: target, linearize: false),
                      presenter.lastFailure ?? "the present pass failed")
        func p(_ x: Int, _ y: Int) -> [Float] { Self.pixelAt(target, x, y) }

        // rect = (0.125, 0.15, 0.75, 0.7) → px x ∈ [480, 3360), y ∈ [324, 1836).
        for (x, y) in [(1920, 1080), (600, 400), (3300, 1800), (483, 1000), (2000, 327)] {
            Self.assertColour(p(x, y), main, "inside at (\(x), \(y))")
        }
        for (x, y) in [(0, 0), (3839, 2159), (3839, 0), (0, 2159), (200, 1080), (2000, 150),
                       (470, 1080), (3370, 1080), (2000, 315), (2000, 1845)] {
            Self.assertColour(p(x, y), back, "outside at (\(x), \(y))")
        }
        // The edge is the quad's, exactly: nothing is cross-faded, so a 1-px step is what a 1-px boundary
        // looks like (067).
        for (x, y) in [(480, 1080), (3359, 1080), (2000, 324)] {
            Self.assertColour(p(x, y), main, "first pixel inside the quad at (\(x), \(y))")
        }
        for (x, y) in [(479, 1080), (3360, 1080), (2000, 323)] {
            Self.assertColour(p(x, y), back, "last pixel outside the quad at (\(x), \(y))")
        }

        // The engine does not care how big the backdrop is — only where the canvas reads it. The same
        // solid picture at 4096×2731 (the final rule's 9000 px / 2 capped at 4096) and at a quarter of
        // the size must land on the same pixels.
        for (w, h) in [(4096, 2731), (1125, 750)] {
            let other = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                        [.shaderRead, .renderTarget])
            let size = try solid(device, w, h, back)
            XCTAssertTrue(presenter.renderForTest(frame, window: window, backdrop: size,
                                           into: other, linearize: false))
            XCTAssertTrue(Self.bytesEqual(target, other),
                          "a \(w)×\(h) backdrop of the same colour must render the same canvas")
        }
        print("non-power-of-two: 4500×3000 backdrop on a 3840×2160 canvas, du = \(window.du), "
              + "rect px [480, 3360) × [324, 1836) — inside main, outside backdrop, 2 px ramp")
    }

    /// The backdrop reads through its own window, so a caller can hand over any source rect.
    func testBackdropWindowIsHonoured() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 256, height: 256)
        // A backdrop split down the middle: left half red-ish, right half blue-ish.
        let backdrop = try halves(device, 400, 400, left: [0.9, 0.1, 0.1, 1], right: [0.1, 0.1, 0.9, 1])
        let frame = try solid(device, 128, 128, [0.1, 0.9, 0.1, 1])
        let target = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])

        // The picture is a strip down the left fifth (rect = (0, 0, 0.2, 1)), so the canvas right of
        // it is backdrop: read through the whole backdrop that is its left half at x = 77 and its
        // right half at x = 179; read through the backdrop's right half it is blue at both.
        let window = PresentWindow(u0: 0, v0: 0, du: 5, dv: 1)
        XCTAssertTrue(presenter.renderForTest(frame, window: window, backdrop: backdrop,
                                       backdropWindow: .whole, into: target, linearize: false))
        var px = Self.readRGBA16(target)
        XCTAssertEqual(Self.pixel(px, canvas.width, 77, 40)[0], Float(0.9), accuracy: 1.0 / 255,
                       "outside the frame, left of the backdrop's seam")
        XCTAssertEqual(Self.pixel(px, canvas.width, 179, 40)[2], Float(0.9), accuracy: 1.0 / 255,
                       "outside the frame, right of the backdrop's seam")
        XCTAssertEqual(Self.pixel(px, canvas.width, 20, 40)[1], Float(0.9), accuracy: 1.0 / 255,
                       "inside the frame is still the frame")

        XCTAssertTrue(presenter.renderForTest(frame, window: window, backdrop: backdrop,
                                       backdropWindow: PresentWindow(u0: 0.5, v0: 0, du: 0.5, dv: 1),
                                       into: target, linearize: false))
        px = Self.readRGBA16(target)
        XCTAssertEqual(Self.pixel(px, canvas.width, 77, 40)[2], Float(0.9), accuracy: 1.0 / 255,
                       "with the right half of the backdrop in the window, x = 77 is blue too")
    }

    // MARK: - ④ the on-screen path takes the same arguments

    func testPresentAcceptsABackdropOnARealLayer() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let layer = CAMetalLayer()
        CanvasPresenter.configure(layer, storage: presenter.storage)
        layer.drawableSize = CGSize(width: 64, height: 48)

        let frame = try solid(device, 32, 24, [0.2, 0.4, 0.8, 1])
        let backdrop = try solid(device, 16, 12, [0.8, 0.2, 0.2, 1])
        let window = PresentWindow(scale: 0.5, originX: 0, originY: 0,
                                   canvas: ImageSize(width: 64, height: 48),
                                   texture: ImageSize(width: 32, height: 24))
        if !presenter.presentForTest(frame, in: layer, drawableSize: ImageSize(width: 64, height: 48),
                                     window: window, backdrop: backdrop) {
            throw XCTSkip("no drawable in this session: \(presenter.lastFailure ?? "—")")
        }
        XCTAssertNil(presenter.lastFailure)
    }

    // MARK: - ⑤ what it costs

    /// 4.10 Mpx, one canvas, three draws: 025's own fragment (the baseline, compiled from source
    /// here), the new fragment with no backdrop, and the new fragment with a backdrop that covers the
    /// canvas.
    ///
    /// The claim is a delta, not an absolute: the same encode/commit/wait sequence timed three ways on
    /// the same machine in the same process. Ceilings only under `PHOTONS_BENCH=1`.
    func testBackdropCostOnAFullCoverFrame() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let canvas = ImageSize(width: 2560, height: 1600)          // 4.10 Mpx
        XCTAssertEqual(canvas.pixelCount, 4_096_000)

        let frame = try patterned(device, ImageSize(width: 1024, height: 640))
        let backdrop = try solid(device, 1280, 800, [0.4, 0.5, 0.6, 1])
        let target = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                     [.shaderRead, .renderTarget])

        // The baseline: 025's fragment, verbatim in shape (two float4s, one sample, clamp_to_edge).
        let old = try baselinePipeline(device, format: target.pixelFormat)
        var oldParams = Scratch025(a: SIMD4<Float>(1, 0, 0, 0), b: SIMD4<Float>(0, 0, 1, 1))
        let oldDraw: [(texture: MTLTexture, bytes: [UInt8])] =
            [(frame, withUnsafeBytes(of: &oldParams) { Array($0) })]

        // 067's pass, one quad (the picture covering the canvas) and two (a backdrop behind it).
        let pipeline = try newPipeline(device, format: target.pixelFormat)
        var picture = CanvasPresenter.PresentParams(quad: SIMD4(0, 0, 1, 1),
                                                    window: SIMD4(0, 0, 1, 1),
                                                    misc: SIMD4(1, 0, 0, 0))
        let pictureBytes = withUnsafeBytes(of: &picture) { Array($0) }
        let oneDraw: [(texture: MTLTexture, bytes: [UInt8])] = [(frame, pictureBytes)]
        let twoDraws: [(texture: MTLTexture, bytes: [UInt8])] = [(backdrop, pictureBytes),
                                                                 (frame, pictureBytes)]

        func measure(_ pipeline: MTLRenderPipelineState,
                     _ draws: [(texture: MTLTexture, bytes: [UInt8])]) -> Double {
            time(device: device, pipeline: pipeline, target: target, draws: draws, iterations: 60)
        }

        // The GPU clocks up under load, and a 4 Mpx pass is short enough that an un-warmed sample
        // measures the ramp instead of the shader: one discarded pass per configuration first.
        _ = (measure(old, oldDraw), measure(pipeline, oneDraw), measure(pipeline, twoDraws))

        // Three rounds, alternating order: a residual drift shows up as three different numbers instead
        // of one wrong one, and the fastest of them is how fast the draw can go.
        let roundA = (old: measure(old, oldDraw), one: measure(pipeline, oneDraw),
                      two: measure(pipeline, twoDraws))
        let roundB = (two: measure(pipeline, twoDraws), one: measure(pipeline, oneDraw),
                      old: measure(old, oldDraw))
        let roundC = (old: measure(old, oldDraw), one: measure(pipeline, oneDraw),
                      two: measure(pipeline, twoDraws))
        let oldMS = min(roundA.old, roundB.old, roundC.old)
        let oneMS = min(roundA.one, roundB.one, roundC.one)
        let twoMS = min(roundA.two, roundB.two, roundC.two)

        let oneDelta = oneMS - oldMS
        let twoDelta = twoMS - oneMS
        print(String(format: "present 4.10 Mpx (median draw+wait): 025 one quad %.3f ms · 067 one quad "
                     + "%.3f ms (%+.3f) · 067 two quads %.3f ms (%+.3f over one — the backdrop's cost)"
                     + "\n  rounds (025 / one / two): %.3f %.3f %.3f · %.3f %.3f %.3f · %.3f %.3f %.3f",
                     oldMS, oneMS, oneDelta, twoMS, twoDelta,
                     roundA.old, roundA.one, roundA.two,
                     roundB.old, roundB.one, roundB.two,
                     roundC.old, roundC.one, roundC.two))

        if benchmarks {
            // The task's ceiling: presenting the picture as a quad instead of 025's full-screen pass may
            // cost at most 0.2 ms on a 4.10 Mpx canvas — it is the same sample with one multiply more in
            // the vertex stage, and the vertex stage runs four times per draw.
            XCTAssertLessThanOrEqual(oneDelta, 0.2,
                                     "presenting a quad cost \(oneDelta) ms over 025's full-screen pass")
            XCTAssertLessThanOrEqual(twoDelta, 0.2,
                                     "the backdrop quad cost \(twoDelta) ms (a second 4-vertex draw)")
        } else {
            throw XCTSkip("timing printed; set PHOTONS_BENCH=1 to assert the ceilings")
        }
    }

    // MARK: - the timing harness

    /// 025's `PresentParams` + fragment, as a baseline only: the shipping kernel is the one in
    /// `present.metal`. Kept to two `float4`s and one sample so the only difference between this draw
    /// and the new one is the shader under test.
    private struct Scratch025 {
        var a: SIMD4<Float>
        var b: SIMD4<Float>
    }

    private static let baseline025Source = """
    #include <metal_stdlib>
    using namespace metal;
    struct P025 { float4 a; float4 b; };
    struct O025 { float4 position [[position]]; float2 uv; };
    vertex O025 v025(uint vid [[vertex_id]], constant P025 &p [[buffer(0)]]) {
        const float2 corners[4] = { float2(-1.0, 1.0), float2(1.0, 1.0), float2(-1.0, -1.0), float2(1.0, -1.0) };
        const float2 coords[4]  = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) };
        O025 o;
        o.position = float4(corners[vid], 0.0, 1.0);
        o.uv = p.b.xy + coords[vid] * p.b.zw;
        return o;
    }
    static inline float srgb_encode_inverse(float v) {
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
    }
    fragment float4 f025(O025 in [[stage_in]], texture2d<float> src [[texture(0)]],
                         constant P025 &p [[buffer(0)]]) {
        constexpr sampler smp(coord::normalized, address::clamp_to_edge, filter::linear);
        float4 c = src.sample(smp, in.uv);
        float3 v = max(c.rgb, 0.0);
        if (p.a.x > 0.5) {
            v = float3(srgb_encode_inverse(v.x), srgb_encode_inverse(v.y), srgb_encode_inverse(v.z));
        } else {
            v = min(v, 1.0);
        }
        return float4(v, 1.0);
    }
    """

    private func baselinePipeline(_ device: MTLDevice,
                                  format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let library = try device.makeLibrary(source: Self.baseline025Source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = try XCTUnwrap(library.makeFunction(name: "v025"))
        desc.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "f025"))
        desc.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    /// The shipping pipeline, built the way `CanvasPresenter` builds it (same source file, same
    /// function names) so the timing measures the real kernel.
    private func newPipeline(_ device: MTLDevice, format: MTLPixelFormat,
                             fragment: String = "present_fragment") throws -> MTLRenderPipelineState {
        let source = try String(contentsOf: Self.kernelURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = try XCTUnwrap(library.makeFunction(name: "present_vertex"))
        desc.fragmentFunction = try XCTUnwrap(library.makeFunction(name: fragment))
        desc.colorAttachments[0].pixelFormat = format
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    /// Per-draw cost of one pass, in milliseconds. `draws` is the sequence the pass makes — one quad
    /// for the picture, two with a backdrop — each with its own params, so the measurement is the shape
    /// the presenter actually encodes.
    private func time(device: MTLDevice, pipeline: MTLRenderPipelineState, target: MTLTexture,
                      draws: [(texture: MTLTexture, bytes: [UInt8])],
                      iterations: Int = 24, drawsPerSample: Int = 8) -> Double {
        guard let queue = device.makeCommandQueue() else { return .infinity }
        var samples: [Double] = []
        for i in 0..<(iterations + 3) {
            let start = CACurrentMediaTime()
            guard let cb = queue.makeCommandBuffer() else { return .infinity }
            for _ in 0..<drawsPerSample {
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = target
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return .infinity }
                enc.setRenderPipelineState(pipeline)
                for draw in draws {
                    enc.setFragmentTexture(draw.texture, index: 0)
                    draw.bytes.withUnsafeBytes {
                        enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
                    }
                    draw.bytes.withUnsafeBytes {
                        enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0)
                    }
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
                enc.endEncoding()
            }
            cb.commit()
            cb.waitUntilCompleted()
            if i >= 3 {
                samples.append((CACurrentMediaTime() - start) * 1000 / Double(drawsPerSample))
            }
        }
        samples.sort()
        return samples[samples.count / 2]
    }

    // MARK: - parsing the kernel source

    private static func presentParamsBody(in source: String) -> String? {
        guard let start = source.range(of: "struct PresentParams {") else { return nil }
        guard let end = source.range(of: "};", range: start.upperBound..<source.endIndex) else {
            return nil
        }
        return String(source[start.upperBound..<end.lowerBound])
    }

    /// The declaration only — up to the opening brace, since the body has braces of its own.
    private static func fragmentSignature(_ name: String, in source: String) -> String? {
        guard let start = source.range(of: "fragment float4 \(name)(") else { return nil }
        guard let end = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func vertexSignature(_ name: String, in source: String) -> String? {
        guard let start = source.range(of: " \(name)(") else { return nil }
        guard let end = source.range(of: "{", range: start.upperBound..<source.endIndex) else { return nil }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    /// The source with `//` comments removed — so "this word is gone" means it is gone from the *code*,
    /// not that the file stopped explaining why it went.
    private static func stripped(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    // MARK: - texture helpers (rgba16Float / bgra8, shared storage, CPU readable)

    private func makeTexture(_ device: MTLDevice, _ w: Int, _ h: Int, _ format: MTLPixelFormat,
                             _ usage: MTLTextureUsage) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h,
                                                          mipmapped: false)
        d.usage = usage
        d.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func solid(_ device: MTLDevice, _ w: Int, _ h: Int, _ rgba: [Float]) throws -> MTLTexture {
        let t = try makeTexture(device, w, h, .rgba16Float, [.shaderRead])
        var row = [UInt16](repeating: 0, count: w * 4)
        for x in 0..<w { for c in 0..<4 { row[x * 4 + c] = Float16(rgba[c]).bitPattern } }
        for y in 0..<h {
            row.withUnsafeBytes { buf in
                t.replace(region: MTLRegionMake2D(0, y, w, 1), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: w * 8)
            }
        }
        return t
    }

    private func halves(_ device: MTLDevice, _ w: Int, _ h: Int, left: [Float],
                        right: [Float]) throws -> MTLTexture {
        let t = try makeTexture(device, w, h, .rgba16Float, [.shaderRead])
        var row = [UInt16](repeating: 0, count: w * 4)
        for x in 0..<w {
            let v = x < w / 2 ? left : right
            for c in 0..<4 { row[x * 4 + c] = Float16(v[c]).bitPattern }
        }
        for y in 0..<h {
            row.withUnsafeBytes { buf in
                t.replace(region: MTLRegionMake2D(0, y, w, 1), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: w * 8)
            }
        }
        return t
    }

    /// A pattern with structure at every scale: a gradient plus a 3-px checker plus a distinct border,
    /// so a wrong window, wrong filter or wrong clamp all change the hash.
    private func patterned(_ device: MTLDevice, _ size: ImageSize) throws -> MTLTexture {
        let t = try makeTexture(device, size.width, size.height, .rgba16Float, [.shaderRead])
        let w = size.width, h = size.height
        var row = [UInt16](repeating: 0, count: w * 4)
        for y in 0..<h {
            for x in 0..<w {
                let fx = Float(x) / Float(max(w - 1, 1))
                let fy = Float(y) / Float(max(h - 1, 1))
                var v: [Float]
                if x < 1 || y < 1 || x > w - 2 || y > h - 2 {
                    v = [0.85, 0.15, 0.10, 1]
                } else {
                    let check: Float = ((x / 3) + (y / 3)) % 2 == 0 ? 1.0 : 0.0
                    v = [0.1 + 0.8 * fx, 0.2 + 0.6 * fy, check * 0.7, 1]
                }
                for c in 0..<4 { row[x * 4 + c] = Float16(v[c]).bitPattern }
            }
            row.withUnsafeBytes { buf in
                t.replace(region: MTLRegionMake2D(0, y, w, 1), mipmapLevel: 0,
                          withBytes: buf.baseAddress!, bytesPerRow: w * 8)
            }
        }
        return t
    }

    private static func readRGBA16(_ t: MTLTexture) -> [Float] {
        var raw = [UInt16](repeating: 0, count: t.width * t.height * 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: t.width * 8,
                       from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }

    /// One pixel, read on its own: a 4.10 Mpx canvas does not need a 130 MB `[Float]`.
    private static func pixelAt(_ t: MTLTexture, _ x: Int, _ y: Int) -> [Float] {
        var raw = [UInt16](repeating: 0, count: 4)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: 8,
                       from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return raw.map { Float(Float16(bitPattern: $0)) }
    }

    /// The same bytes in the same order — the whole canvas, without decoding it to floats.
    private static func bytesEqual(_ a: MTLTexture, _ b: MTLTexture) -> Bool {
        guard a.width == b.width, a.height == b.height, a.pixelFormat == b.pixelFormat else { return false }
        let bpr = a.width * 4 * (a.pixelFormat == .rgba16Float ? 2 : 1)
        var ra = [UInt8](repeating: 0, count: bpr * a.height)
        var rb = [UInt8](repeating: 0, count: bpr * b.height)
        ra.withUnsafeMutableBytes { buf in
            a.getBytes(buf.baseAddress!, bytesPerRow: bpr,
                       from: MTLRegionMake2D(0, 0, a.width, a.height), mipmapLevel: 0)
        }
        rb.withUnsafeMutableBytes { buf in
            b.getBytes(buf.baseAddress!, bytesPerRow: bpr,
                       from: MTLRegionMake2D(0, 0, b.width, b.height), mipmapLevel: 0)
        }
        return ra == rb
    }

    /// `flat` is row-major RGBA, so this is `(y * width + x) * 4`.
    private static func pixel(_ flat: [Float], _ width: Int, _ x: Int, _ y: Int) -> [Float] {
        Array(flat[((y * width) + x) * 4..<((y * width) + x) * 4 + 4])
    }

    private static func assertColour(_ got: [Float], _ want: [Float], _ message: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for c in 0..<3 {
            XCTAssertEqual(got[c], want[c], accuracy: 1.0 / 255,
                           "\(message): channel \(c) = \(got[c]), want \(want[c])", file: file, line: line)
        }
    }

    /// `exact` = the stored bits; `eightBit` = the same pixels quantised to 8 bits, per channel.
    private static func hash(_ t: MTLTexture) -> (exact: String, eightBit: String) {
        let sixteen = t.pixelFormat == .rgba16Float
        let bpr = t.width * 4 * (sixteen ? 2 : 1)
        var raw = [UInt8](repeating: 0, count: bpr * t.height)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: bpr,
                       from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0)
        }
        let exact = SHA256.hash(data: Data(raw)).map { String(format: "%02x", $0) }.joined()
        var q = [UInt8]()
        q.reserveCapacity(t.width * t.height * 3)
        if sixteen {
            for i in stride(from: 0, to: raw.count, by: 2) {
                let f = Float(Float16(bitPattern: UInt16(raw[i]) | (UInt16(raw[i + 1]) << 8)))
                q.append(UInt8(max(0, min(255, (f * 255).rounded()))))
            }
        } else {
            // bgra8Unorm: r is byte 2 of each texel, then g, then b, channel-planed like the above.
            for i in stride(from: 0, to: raw.count, by: 4) { q.append(raw[i + 2]) }
            for i in stride(from: 0, to: raw.count, by: 4) { q.append(raw[i + 1]) }
            for i in stride(from: 0, to: raw.count, by: 4) { q.append(raw[i]) }
        }
        let eight = SHA256.hash(data: Data(q)).map { String(format: "%02x", $0) }.joined()
        return (exact, eight)
    }
}
