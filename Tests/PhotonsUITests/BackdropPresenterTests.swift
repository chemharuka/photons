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
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
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

        // The shader's half: five `float4`s, in this order, or the offsets below are wrong.
        XCTAssertEqual(fields.map(\.name), ["a", "b", "c", "d", "e"],
                       "present.metal's PresentParams changed shape; the Swift side must follow")
        XCTAssertEqual(fields.map(\.type), Array(repeating: "float4", count: 5),
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
            layout.offset(of: \.a), layout.offset(of: \.b), layout.offset(of: \.c),
            layout.offset(of: \.d), layout.offset(of: \.e),
        ].map { $0 ?? -1 }

        XCTAssertEqual(swiftOffsets, metalOffsets,
                       "Swift \(swiftOffsets) vs present.metal \(metalOffsets) — the shader would read a different field")
        XCTAssertEqual(layout.stride, metalSize,
                       "Swift stride \(layout.stride) vs present.metal sizeof \(metalSize)")
        // The numbers themselves, so a refactor cannot quietly renumber them.
        XCTAssertEqual(swiftOffsets, [0, 16, 32, 48, 64])
        XCTAssertEqual(layout.stride, 80)
        XCTAssertEqual(layout.size, 80, "stride and size agree, so a copy of `size` bytes is complete")

        // Two entry points: 025's fragment must not even declare the backdrop texture, or the
        // no-backdrop draw pays for a fetch it never uses.
        let plain = try XCTUnwrap(Self.fragmentSignature("present_fragment", in: source))
        XCTAssertTrue(plain.contains("texture2d<float> src [[texture(0)]]"))
        XCTAssertFalse(plain.contains("texture(1)"),
                       "present_fragment is 025's: no backdrop binding, no second fetch")
        let fill = try XCTUnwrap(Self.fragmentSignature("present_fragment_backdrop", in: source))
        XCTAssertTrue(fill.contains("texture2d<float> src [[texture(0)]]"))
        XCTAssertTrue(fill.contains("texture2d<float> backdrop [[texture(1)]]"),
                      "the backdrop must be texture(1): that is where both call sites bind it")
        XCTAssertEqual(CanvasPresenter.fragmentName(nil), "present_fragment")
        XCTAssertEqual(CanvasPresenter.fragmentName(try solid(device, 2, 2, [0, 0, 0, 1])),
                       "present_fragment_backdrop")

        print("PresentParams: 5 × float4, offsets \(metalOffsets), stride \(metalSize) — Swift and present.metal agree")
    }

    /// The `float4 c` / `float4 d` slots must actually carry what the fragment reads them for: the
    /// backdrop window, the main window's rect on the canvas, and the has-backdrop flag.
    func testMakeParamsEncodesTheBackdropGeometry() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let dummy = try solid(device, 8, 8, [0.5, 0.5, 0.5, 1])
        let canvas = ImageSize(width: 512, height: 512)

        // A centred 0.25 canvas window: the picture spans canvas px [192, 320).
        let window = PresentWindow(u0: -1.5, v0: -1.5, du: 4, dv: 4)
        let with = CanvasPresenter.makeParams(linearize: true, window: window,
                                              backdrop: dummy,
                                              backdropWindow: PresentWindow(u0: 0.1, v0: 0.2,
                                                                            du: 0.5, dv: 0.6),
                                              canvas: canvas)
        XCTAssertEqual(with.a.x, 1, "linearize flag")
        XCTAssertEqual(with.b.x, window.u0)
        XCTAssertEqual(with.b.w, window.du)
        XCTAssertEqual(with.c, SIMD4<Float>(0.1, 0.2, 0.5, 0.6), "the backdrop's own uv window")
        XCTAssertEqual(with.d.x, Float(0.375), accuracy: Float(1e-6), "rect origin = -u0/du")
        XCTAssertEqual(with.d.y, Float(0.375), accuracy: Float(1e-6))
        XCTAssertEqual(with.d.z, Float(0.25), accuracy: Float(1e-6), "rect size = 1/du")
        XCTAssertEqual(with.d.w, Float(0.25), accuracy: Float(1e-6))
        XCTAssertEqual(with.e.z, 1, "has-backdrop flag")
        XCTAssertEqual(with.e.x, Float(CanvasPresenter.backdropFeatherPixels / 512), accuracy: Float(1e-9))
        XCTAssertEqual(with.e.y, Float(CanvasPresenter.backdropFeatherPixels / 512), accuracy: Float(1e-9))

        // No backdrop: the flag is 0 and the geometry is neutral, whatever the window says.
        let without = CanvasPresenter.makeParams(linearize: false, window: window, backdrop: nil,
                                                 backdropWindow: .whole, canvas: canvas)
        XCTAssertEqual(without.e.z, 0, "no backdrop ⇒ the fragment takes 025's path")
        XCTAssertEqual(without.a.x, 0)
        XCTAssertEqual(without.d, SIMD4<Float>(0, 0, 1, 1))

        // A degenerate window cannot be feathered against; it must not divide by zero either — in the
        // params, or in the shader (which is chosen by the binding, not by the flag).
        let degenerate = CanvasPresenter.makeParams(linearize: true,
                                                    window: PresentWindow(u0: 0, v0: 0, du: 0, dv: 0),
                                                    backdrop: dummy, backdropWindow: .whole, canvas: canvas)
        XCTAssertEqual(degenerate.e.z, 0)
        XCTAssertTrue(degenerate.d.x.isFinite && degenerate.d.z.isFinite)

        let presenter = try CanvasPresenter(device: device)
        let small = try makeTexture(device, 8, 8, .rgba16Float, [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(dummy, window: PresentWindow(u0: 0, v0: 0, du: 0, dv: 0),
                                       backdrop: dummy, into: small, linearize: false))
        let px = Self.readRGBA16(small)
        XCTAssertTrue(px.allSatisfy { $0.isFinite }, "a zero-sized window painted NaN")
        Self.assertColour(Self.pixel(px, 8, 4, 4), [0.5, 0.5, 0.5, 1], "still the main frame")
    }

    // MARK: - ② `backdrop: nil` is byte-for-byte 025

    /// Recorded on this machine against `5ae8a64` — the shader *before* the backdrop existed — by
    /// running this same fixture through the then-current `CanvasPresenter.render`. Same window, same
    /// target format, same linearize flag: the hash must not move. `exact` is the rgba16Float / bgra8
    /// bit pattern; `q8` is the same pixels quantised to 8 bits, which is the form that survives a
    /// different GPU's rounding.
    func testNoBackdropOutputIsByteIdenticalTo025() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
        let presenter = try CanvasPresenter(device: device)
        let size = ImageSize(width: 64, height: 48)
        let src = try patterned(device, size)
        let target16 = try makeTexture(device, size.width, size.height, .rgba16Float,
                                       [.shaderRead, .renderTarget])
        let target8 = try makeTexture(device, size.width, size.height, .bgra8Unorm,
                                      [.shaderRead, .renderTarget])
        let shrink = PresentWindow(scale: 0.5, originX: Double(size.width) * 0.1,
                                   originY: Double(size.height) * 0.1, canvas: size, texture: size)
        let zoom = PresentWindow(scale: 1.7, originX: -Double(size.width) * 0.2,
                                 originY: -Double(size.height) * 0.15, canvas: size, texture: size)

        let cases: [(name: String, window: PresentWindow, linear: Bool, target: MTLTexture,
                     exact: String, eightBit: String)] = [
            ("identity/linear16", .whole, true, target16,
             "6ceb6f49b8d386e804bdef1ea144251b967041b9cedb92c8a9f6c0c4c5fab3cc",
             "7abcb9ffb5a891e9946457ecb3edfd9cb39e1fb9092dd5268011dab7209fc62e"),
            ("shrink/linear16", shrink, true, target16,
             "1243b1acbd4a72bdfdcccbcb7eaa2a75f8743a7f2addcaea43d3ee65146cdb64",
             "d635dc4e54cd853cc592b21e1cdd02c5ea700f4533a3946a79abe6fab05e488a"),
            ("shrink/encoded", shrink, false, target16,
             "ac372bdffa30436a0efbe9e68ce9f3a17806a78a9d53d9e136aa33c4e6ea8cd2",
             "6c990d3552c71cda070b5e5e90a6628c7b768435545713405e6128b511e83105"),
            ("zoom/linear16", zoom, true, target16,
             "91616dc57255d327ce35a3206afa39b6ad9932f667f8388862241567e72b2c15",
             "2fddaf8d6c343f098aa4a90a78460df62d98877c8672b265df076fed9b651e30"),
            ("shrink/srgb8", shrink, false, target8,
             "fda8d469f3202fbebeb4310622c15f7faf978492d0203f863f151e406b57d495",
             "d51a15d76b7ef6a7a3a95f510f28e536a245d7e316d5acdc7eca2fc236d11d10"),
        ]

        var lines: [String] = []
        for c in cases {
            XCTAssertTrue(presenter.render(src, window: c.window, into: c.target, linearize: c.linear),
                          presenter.lastFailure ?? "the present pass failed")
            let h = Self.hash(c.target)
            XCTAssertEqual(h.exact, c.exact,
                           "\(c.name): the no-backdrop path is no longer 025's output (exact hash)")
            XCTAssertEqual(h.eightBit, c.eightBit, "\(c.name): 8-bit hash moved")
            lines.append("  \(c.name): \(h.exact.prefix(16))… ✓")
        }
        print("no-backdrop output, hashed against 5ae8a64:\n" + lines.joined(separator: "\n"))
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

        XCTAssertTrue(presenter.render(src, window: shrink, into: a, linearize: true))
        XCTAssertTrue(presenter.render(src, window: shrink, backdrop: nil,
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

        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
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
        // ③ the two pixels inside each edge are a ramp between them, monotonically.
        for (inner, outer, axis, fixed) in [(192, 193, "x", 256), (319, 318, "x", 256),
                                            (192, 193, "y", 256)] {
            let a = axis == "x" ? p(inner, fixed) : p(fixed, inner)
            let b = axis == "x" ? p(outer, fixed) : p(fixed, outer)
            let lo = min(main[1], back[1]), hi = max(main[1], back[1])
            XCTAssertGreaterThan(a[1], lo + 2.0 / 255, "edge pixel (\(inner)) is not blended: \(a[1])")
            XCTAssertLessThan(a[1], hi - 2.0 / 255, "edge pixel (\(inner)) is not blended: \(a[1])")
            XCTAssertGreaterThan(b[1], lo + 2.0 / 255, "second edge pixel (\(outer)) is not blended: \(b[1])")
            XCTAssertLessThan(b[1], hi - 2.0 / 255)
            XCTAssertLessThan(abs(b[1] - hi), abs(a[1] - hi),
                              "the ramp must climb towards the main frame, not away from it")
        }

        // No canvas pixel is the pass's clear colour: the backdrop covers what the frame does not.
        var unpainted = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i] == 0 && px[i + 1] == 0 && px[i + 2] == 0 {
            unpainted += 1
        }
        XCTAssertEqual(unpainted, 0, "\(unpainted) of \(px.count / 4) canvas pixels are unrendered black")

        // The counterexample, in the same geometry: without a backdrop the outside is 025's stretched
        // edge — the main frame's colour — which is the band the user reported seeing.
        let bare = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                   [.shaderRead, .renderTarget])
        XCTAssertTrue(presenter.render(frame, window: window, into: bare, linearize: false))
        let barePixels = Self.readRGBA16(bare)
        for (x, y) in [(0, 0), (511, 511)] {
            XCTAssertEqual(Self.pixel(barePixels, canvas.width, x, y)[0], main[0], accuracy: 1.0 / 255,
                           "025's corner is the picture's own edge — the band this replaces")
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

        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
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
        for (x, y) in [(480, 1080), (481, 1080), (3359, 1080), (3358, 1080), (2000, 324), (2000, 325)] {
            let v = p(x, y)[1]
            XCTAssertGreaterThan(v, min(main[1], back[1]) + 2.0 / 255, "edge pixel (\(x), \(y)) not blended")
            XCTAssertLessThan(v, max(main[1], back[1]) - 2.0 / 255, "edge pixel (\(x), \(y)) not blended")
        }

        // The engine does not care how big the backdrop is — only where the canvas reads it. The same
        // solid picture at 4096×2731 (the final rule's 9000 px / 2 capped at 4096) and at a quarter of
        // the size must land on the same pixels.
        for (w, h) in [(4096, 2731), (1125, 750)] {
            let other = try makeTexture(device, canvas.width, canvas.height, .rgba16Float,
                                        [.shaderRead, .renderTarget])
            let size = try solid(device, w, h, back)
            XCTAssertTrue(presenter.render(frame, window: window, backdrop: size,
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
        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
                                       backdropWindow: .whole, into: target, linearize: false))
        var px = Self.readRGBA16(target)
        XCTAssertEqual(Self.pixel(px, canvas.width, 77, 40)[0], Float(0.9), accuracy: 1.0 / 255,
                       "outside the frame, left of the backdrop's seam")
        XCTAssertEqual(Self.pixel(px, canvas.width, 179, 40)[2], Float(0.9), accuracy: 1.0 / 255,
                       "outside the frame, right of the backdrop's seam")
        XCTAssertEqual(Self.pixel(px, canvas.width, 20, 40)[1], Float(0.9), accuracy: 1.0 / 255,
                       "inside the frame is still the frame")

        XCTAssertTrue(presenter.render(frame, window: window, backdrop: backdrop,
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
        if !presenter.present(frame, in: layer, drawableSize: ImageSize(width: 64, height: 48),
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

        // The new fragment, no backdrop: `e.z == 0` — the path every caller is on today.
        let pipeline = try newPipeline(device, format: target.pixelFormat)
        var nilParams = CanvasPresenter.makeParams(linearize: true, window: .whole, backdrop: nil,
                                                   backdropWindow: .whole, canvas: canvas)
        XCTAssertEqual(nilParams.e.z, 0)

        // The new fragment with a backdrop, frame covering the canvas (the "全覆盖" case).
        let bdPipeline = try newPipeline(device, format: target.pixelFormat,
                                         fragment: CanvasPresenter.fragmentName(backdrop))
        XCTAssertEqual(CanvasPresenter.fragmentName(backdrop), "present_fragment_backdrop")
        var bdParams = CanvasPresenter.makeParams(linearize: true, window: .whole, backdrop: backdrop,
                                                  backdropWindow: .whole, canvas: canvas)
        XCTAssertEqual(bdParams.e.z, 1)

        func measureOld() -> Double {
            time(device: device, pipeline: old, source: frame, backdrop: nil, target: target,
                 vertexBytes: withUnsafeBytes(of: &oldParams) { Array($0) }, iterations: 60)
        }
        func measureNil() -> Double {
            time(device: device, pipeline: pipeline, source: frame, backdrop: nil, target: target,
                 vertexBytes: withUnsafeBytes(of: &nilParams) { Array($0) }, iterations: 60)
        }
        func measureBackdrop() -> Double {
            time(device: device, pipeline: bdPipeline, source: frame, backdrop: backdrop, target: target,
                 vertexBytes: withUnsafeBytes(of: &bdParams) { Array($0) }, iterations: 60)
        }

        // The GPU clocks up under load, and a 4 Mpx pass is short enough that an un-warmed sample
        // measures the ramp instead of the shader: one discarded pass per configuration first.
        _ = (measureOld(), measureNil(), measureBackdrop())

        // Three rounds, alternating order: a residual drift shows up as three different numbers instead
        // of one wrong one, and the fastest of them is how fast the draw can go.
        let roundA = (old: measureOld(), nil_: measureNil(), backdrop: measureBackdrop())
        let roundB = (backdrop: measureBackdrop(), nil_: measureNil(), old: measureOld())
        let roundC = (old: measureOld(), nil_: measureNil(), backdrop: measureBackdrop())
        let oldMS = min(roundA.old, roundB.old, roundC.old)
        let nilMS = min(roundA.nil_, roundB.nil_, roundC.nil_)
        let bdMS = min(roundA.backdrop, roundB.backdrop, roundC.backdrop)

        let nilDelta = nilMS - oldMS
        let bdDelta = bdMS - nilMS
        print(String(format: "present 4.10 Mpx (median draw+wait, best of two rounds): "
                     + "025 %.3f ms · backdrop=nil %.3f ms (%+.3f) · backdrop full-cover %.3f ms "
                     + "(%+.3f over nil)\n  rounds (025 / nil / backdrop): %.3f %.3f %.3f · "
                     + "%.3f %.3f %.3f · %.3f %.3f %.3f",
                     oldMS, nilMS, nilDelta, bdMS, bdDelta,
                     roundA.old, roundA.nil_, roundA.backdrop,
                     roundB.old, roundB.nil_, roundB.backdrop,
                     roundC.old, roundC.nil_, roundC.backdrop))

        if benchmarks {
            // Same fragment *function* as the baseline, so this is an equality with the noise floor. A
            // single uniform branch around the backdrop fetch — the shape this started in — measured
            // +0.03 ms here, which is why the two paths are two entry points.
            XCTAssertLessThanOrEqual(nilDelta, 0.05,
                                     "the no-backdrop path must cost what 025 cost (was \(oldMS), now \(nilMS))")
            XCTAssertLessThanOrEqual(bdDelta, 0.30,
                                     "a backdrop may cost ≤0.3 ms on a full-cover frame (cost \(bdDelta))")
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

    /// Per-draw cost of one full-canvas present, in milliseconds.
    ///
    /// `drawsPerSample` draws share one command buffer and one wait: a single 4.10 Mpx draw is only a
    /// few hundred microseconds, so an unamortised `waitUntilCompleted` is most of what a one-draw
    /// sample would measure and the shader's own cost disappears into it.
    private func time(device: MTLDevice, pipeline: MTLRenderPipelineState, source: MTLTexture,
                      backdrop: MTLTexture?, target: MTLTexture, vertexBytes: [UInt8],
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
                enc.setFragmentTexture(source, index: 0)
                enc.setFragmentTexture(backdrop ?? source, index: 1)
                vertexBytes.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
                vertexBytes.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
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
