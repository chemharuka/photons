import XCTest
import Metal
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 315 — the canvas colour is one enum with a preference, and the photograph does not notice.
///
/// The user's report (「默认的0f遮罩太暗了，和00有些区分不开」) says the default stop was too close to
/// the `000000` the frame writes where the photograph does not reach. What is pinned here:
///
///   1. **One enum, one default.** `CanvasBackdrop.current` is `.dark` when nothing is stored, an
///      unknown stored raw value falls back to `.dark`, and `CanvasPresenter.CanvasMatte` reports the
///      same stop through its `var` facade.
///   2. **The stops are the numbers in the spec.** L\* strictly increasing, and the darkest one
///      separates from `000000` (contrast ≥ 1.25 — the old `0F` was 1.10).
///   3. **Switching moves the matte and nothing else.** After `set(.light)` / `set(.midGrey)` the
///      presented canvas' matte region is the new code, while every photograph pixel is byte-identical
///      to the `.dark` present of the same frame.
///   4. **Display-referred.** A frame rendered for headroom 1.0 and one for 8.0 present the same matte
///      code: the stop is not scaled by the EDR budget.
///   5. **No literal survives.** No non-comment `0x0F` / `15/255` in `Sources/`, and every surface
///      that stores the colour subscribes to `.canvasBackdropDidChange`.
@MainActor
final class CanvasBackdropTests: XCTestCase {

    // MARK: - 1. one enum, one default

    func testTheDefaultStopIsDarkAndAnUnknownStoredStopFallsBack() {
        withFreshPreference {
            XCTAssertEqual(CanvasBackdrop.allCases, [.dark, .midGrey, .light])
            XCTAssertEqual(CanvasBackdrop.current, .dark)
            XCTAssertEqual(CanvasBackdrop.current.eightBitValue, 0x20, "#20 is 32")
            XCTAssertEqual(CanvasPresenter.CanvasMatte.eightBitValue, 0x20,
                           "the facade must report the stop `current` reports")

            // A stored value this build does not know (a downgrade, a hand-edited preference) is not
            // left to make the canvas undefined: it falls back to the default.
            UserDefaults.standard.set("slate", forKey: CanvasBackdrop.defaultsKey)
            XCTAssertEqual(CanvasBackdrop.current, .dark, "an unknown stop must fall back to .dark")

            // …and a known one is honoured, which is what makes this a preference and not a constant.
            UserDefaults.standard.set(CanvasBackdrop.midGrey.rawValue,
                                      forKey: CanvasBackdrop.defaultsKey)
            XCTAssertEqual(CanvasBackdrop.current, .midGrey)
            print("backdrop: default .dark = #\(String(CanvasBackdrop.dark.eightBitValue, radix: 16)) "
                  + "= \(CanvasBackdrop.dark.eightBitValue)/255; unknown raw falls back to .dark")
        }
    }

    // MARK: - 2. lightness and contrast

    /// L\* from relative luminance (`Y = linear` for a neutral), and the WCAG contrast ratio against
    /// the frame's `000000`. Both are computed here rather than copied, so a stopped stop cannot hide
    /// behind a stale table.
    func testTheThreeStopsIncreaseInLightnessAndTheDarkestSeparatesFromBlack() {
        let lStars = CanvasBackdrop.allCases.map(lStar)
        for (a, b) in zip(lStars, lStars.dropFirst()) {
            XCTAssertGreaterThan(b, a, "L* must strictly increase: \(lStars)")
        }
        XCTAssertEqual(lStars[0], 12.3, accuracy: 0.3, "dark L* (#202020)")
        XCTAssertEqual(lStars[1], 53.6, accuracy: 0.3, "midGrey L* (#808080)")
        XCTAssertEqual(lStars[2], 91.7, accuracy: 0.6, "light L* (#E6E6E6)")

        let contrast = (CanvasBackdrop.dark.linear + 0.05) / 0.05
        XCTAssertGreaterThanOrEqual(contrast, 1.25,
                                    "the darkest stop is \(contrast):1 against 000000 — the old 0F was 1.10")
        XCTAssertEqual(contrast, 1.29, accuracy: 0.02, "dark contrast against 000000")
        print("stops: " + CanvasBackdrop.allCases.map {
            "\($0.rawValue) #\(String($0.eightBitValue, radix: 16)) "
            + "L*=\(String(format: "%.1f", lStar($0))) "
            + "Y=\(String(format: "%.4f", $0.linear))"
        }.joined(separator: " | ")
        + " contrast(dark,000000)=\(String(format: "%.2f", contrast))")
    }

    // MARK: - 3. switching moves the matte, not the photograph

    func testSetPostsAndMovesTheStoredColour() {
        withFreshPreference {
            var posts = 0
            let token = NotificationCenter.default.addObserver(
                forName: .canvasBackdropDidChange, object: nil, queue: nil) { _ in posts += 1 }
            defer { NotificationCenter.default.removeObserver(token) }

            var seen: [String] = []
            func code() -> Int {
                Int(((NSColor.canvasMatte.usingColorSpace(.sRGB)?.redComponent ?? -1) * 255).rounded())
            }

            CanvasBackdrop.set(.light)
            XCTAssertEqual(posts, 1, "`set` must announce the change once")
            XCTAssertEqual(CanvasBackdrop.current, .light)
            assertCanvasMatteColor(0xE6, "after set(.light)")
            seen.append("set(.light) → NSColor.canvasMatte = \(code())/255")

            CanvasBackdrop.set(.midGrey)
            XCTAssertEqual(posts, 2)
            assertCanvasMatteColor(0x80, "after set(.midGrey)")
            seen.append("set(.midGrey) → \(code())/255")

            CanvasBackdrop.set(.dark)
            assertCanvasMatteColor(0x20, "after set(.dark)")
            seen.append("set(.dark) → \(code())/255")
            print(seen.joined(separator: " · "))
        }
    }

    /// The acceptance's pixel half: **the same frame**, presented once per stop. The matte region's
    /// mean code follows the preference exactly; the photograph's bytes do not move by one.
    func testTheSameFrameKeepsItsPhotographWhenTheBackdropMoves() throws {
        try withFreshPreference {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
            let presenter = try CanvasPresenter(device: device)
            let canvas = ImageSize(width: 320, height: 240)
            let picture = ImageRect(x: 80, y: 60, width: 160, height: 120)
            let source = try letterboxed(device, canvas, picture: picture)

            var mattes: [CanvasBackdrop: (mean: Double, photo: [UInt8])] = [:]
            for stop in CanvasBackdrop.allCases {
                CanvasBackdrop.set(stop)
                let target = try makeTexture(device, canvas.width, canvas.height, .bgra8Unorm)
                let request = PresentRequest(picture: source, canvas: canvas,
                                             pictureQuad: picture, window: .whole)
                XCTAssertTrue(presenter.render(request, into: target, linearize: false),
                              presenter.lastFailure ?? "the present pass failed")
                var samples = 0
                var sum = 0.0
                // Every matte pixel, sampled on a grid — the band above and below the picture.
                for y in stride(from: 2, to: canvas.height, by: 8) {
                    for x in stride(from: 2, to: canvas.width, by: 8) {
                        guard y < picture.y || y >= picture.maxY
                                || x < picture.x || x >= picture.maxX else { continue }
                        sum += Double(Self.code(target, x, y))
                        samples += 1
                    }
                }
                mattes[stop] = (sum / Double(samples), Self.bytes(target, picture))
            }

            let dark = try XCTUnwrap(mattes[.dark])
            let mid = try XCTUnwrap(mattes[.midGrey])
            let light = try XCTUnwrap(mattes[.light])

            // ① the matte follows the stop, exactly and on average.
            XCTAssertEqual(dark.mean, 32, accuracy: 1, "dark matte mean")
            XCTAssertEqual(mid.mean, 128, accuracy: 1, "midGrey matte mean")
            XCTAssertEqual(light.mean, 230, accuracy: 1, "light matte mean")
            XCTAssertGreaterThan(light.mean, mid.mean)
            XCTAssertGreaterThan(mid.mean, dark.mean)

            // ② the photograph is byte-identical across the three presents — the same source texture,
            //    the same quad, only the clear colour changed.
            XCTAssertEqual(light.photo, dark.photo, "the light stop moved photograph pixels")
            XCTAssertEqual(mid.photo, dark.photo, "the midGrey stop moved photograph pixels")

            // ③ the frame's own interior is untouched at its source: S2/S4 still write 000000 where the
            //    picture does not reach (that is 315's "do not touch the inner black corner").
            XCTAssertEqual(Self.code(source, 0, 0), 0, "the frame texture's corner is no longer 000000")
            print("same frame: matte mean \(String(format: "%.1f", dark.mean)) → "
                  + "\(String(format: "%.1f", mid.mean)) → \(String(format: "%.1f", light.mean)); "
                  + "photograph pixels changed = 0")
        }
    }

    // MARK: - 4. display-referred: the EDR budget does not touch it

    func testTheMatteDoesNotFollowEDRHeadroom() throws {
        try withFreshPreference {
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
            let canvas = ImageSize(width: 400, height: 300)
            var codes: [Double] = []
            for headroom in [1.0, 8.0] {
                let graph = try RenderGraph(input: RenderInput(image: greyImage(width: 800, height: 300),
                                                               identity: "canvas-backdrop-headroom"))
                let options = RenderOptions(canvas: canvas, scale: 1, outputWindow: nil,
                                            display: DisplayOptions(primaries: .sRGB, bitDepth: 16,
                                                                    headroom: headroom),
                                            useCache: false, wantsPixels: false,
                                            collectHistogram: false, histogramBins: 256)
                let result = try graph.render(.neutral, options: options)
                let frame = try XCTUnwrap(result.output, "the render handed back no texture")
                defer { graph.recycle(output: frame) }

                let presenter = try CanvasPresenter(device: device)
                let presented = try makeTexture(device, canvas.width, canvas.height, .rgba16Float)
                XCTAssertTrue(presenter.renderForTest(frame, window: .whole, picture: result.drawnRect,
                                                      into: presented, linearize: true),
                              presenter.lastFailure ?? "the present pass failed")
                codes.append(Self.displayCode(Self.pixel(presented, 0, 0), linear: true))
            }
            XCTAssertEqual(codes[0], 32, accuracy: 1, "matte at headroom 1.0")
            XCTAssertEqual(codes[1], codes[0], "the matte moved with the EDR budget — it is display-referred")
            print("headroom 1.0 → matte \(codes[0]); headroom 8.0 → matte \(codes[1])")
        }
    }

    // MARK: - 5. no literal, every cached surface hears the change

    func testNoLiteralSurvivesAndEveryStoredColourObservesTheChange() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" || $0.pathExtension == "metal" } ?? []
        XCTAssertGreaterThan(files.count, 50, "the source sweep found almost nothing")

        var literalHits: [String] = []
        for file in files {
            let code = Self.stripped(try String(contentsOf: file, encoding: .utf8))
            for needle in ["0x0F", "15/255"] {
                if code.contains(needle) { literalHits.append("\(file.lastPathComponent): \(needle)") }
            }
        }
        XCTAssertEqual(literalHits, [], "a literal of the old matte survives in code: \(literalHits)")

        // The one enum is the only producer, and each surface that **stores** the colour subscribes.
        let core = try Self.text(root, "PhotonsCore/CanvasBackdrop.swift")
        XCTAssertTrue(core.contains("public static let defaultsKey = \"photons.canvasBackdrop\""))
        XCTAssertTrue(core.contains("public static var current: CanvasBackdrop"))
        XCTAssertEqual(core.components(separatedBy: "case dark").count - 1, 1)
        XCTAssertEqual(core.components(separatedBy: "0x0F").count - 1, 0)

        let canvasView = try Self.text(root, "PhotonsUI/Loupe/LoupeCanvasView.swift")
        XCTAssertTrue(canvasView.contains("applyCanvasBackdrop()"))
        XCTAssertTrue(canvasView.contains(".canvasBackdropDidChange"))
        let loupe = try Self.text(root, "PhotonsUI/LoupeController.swift")
        XCTAssertTrue(loupe.contains("observeCanvasBackdrop()"))
        XCTAssertTrue(loupe.contains("NSColor.canvasMatte.cgColor"))
        let grid = try Self.text(root, "PhotonsUI/AssetGridController.swift")
        XCTAssertTrue(grid.contains("canvasBackdropChanged"))
        XCTAssertTrue(grid.contains(".canvasBackdropDidChange"))
        let colours = try Self.text(root, "PhotonsUI/Loupe/LoupeColors.swift")
        XCTAssertTrue(colours.contains("static var canvasMatte: NSColor"),
                      "NSColor.canvasMatte must be computed, not a stored copy")
        print("one producer: CanvasBackdrop.current; cached-colour surfaces observing: "
              + "LoupeCanvasView, LoupeController, AssetGridController")
    }

    // MARK: - helpers

    /// Run `body` with no stored stop, then put the user's real preference back — the tests share the
    /// process' defaults with every other suite.
    private func withFreshPreference(_ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.object(forKey: CanvasBackdrop.defaultsKey)
        UserDefaults.standard.removeObject(forKey: CanvasBackdrop.defaultsKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: CanvasBackdrop.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: CanvasBackdrop.defaultsKey)
            }
            NotificationCenter.default.post(name: .canvasBackdropDidChange, object: nil)
        }
        try body()
    }

    private func assertCanvasMatteColor(_ code: UInt8, _ what: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let srgb = NSColor.canvasMatte.usingColorSpace(.sRGB)
        let want = CGFloat(code) / 255
        XCTAssertEqual(srgb?.redComponent ?? -1, want, accuracy: 1e-6, "\(what) r", file: file, line: line)
        XCTAssertEqual(srgb?.greenComponent ?? -1, want, accuracy: 1e-6, "\(what) g", file: file, line: line)
        XCTAssertEqual(srgb?.blueComponent ?? -1, want, accuracy: 1e-6, "\(what) b", file: file, line: line)
    }

    private func lStar(_ stop: CanvasBackdrop) -> Double {
        let y = stop.linear
        return y > 0.008856 ? 116 * pow(y, 1.0 / 3) - 16 : 903.3 * y
    }

    private static func text(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A source with `//` comments removed: "this literal is gone" means gone from the **code**.
    private static func stripped(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).components(separatedBy: "//").first ?? "" }
            .joined(separator: "\n")
    }

    private func makeTexture(_ device: MTLDevice, _ w: Int, _ h: Int,
                             _ format: MTLPixelFormat) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .renderTarget]
        d.storageMode = .managed
        return try XCTUnwrap(device.makeTexture(descriptor: d), "no texture")
    }

    /// A fit frame as S2/S4 write it: the picture inside `picture`, `float4(0)` everywhere else.
    private func letterboxed(_ device: MTLDevice, _ canvas: ImageSize,
                             picture: ImageRect) throws -> MTLTexture {
        try fill(device, canvas) { x, y in
            let inside = x >= picture.x && x < picture.maxX && y >= picture.y && y < picture.maxY
            guard inside else { return [0, 0, 0, 1] }
            let fx = Float(x - picture.x) / Float(max(picture.width - 1, 1))
            let fy = Float(y - picture.y) / Float(max(picture.height - 1, 1))
            return [0.1 + 0.8 * fx, 0.2 + 0.6 * fy, 0.4, 1]
        }
    }

    private func fill(_ device: MTLDevice, _ size: ImageSize,
                      _ value: (Int, Int) -> [Float]) throws -> MTLTexture {
        let t = try makeTexture(device, size.width, size.height, .rgba16Float)
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

    private func greyImage(width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = y < height / 2 ? 0.6 : 0.1
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v); rgba[o + 2] = Float16(v)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private static func bytesPerRow(_ t: MTLTexture) -> Int {
        t.width * 4 * (t.pixelFormat == .rgba16Float ? 2 : 1)
    }

    private static func bytes(_ t: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        let bpr = bytesPerRow(t) / t.width
        var raw = [UInt8](repeating: 0, count: bpr)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: bpr, from: MTLRegionMake2D(x, y, 1, 1),
                       mipmapLevel: 0)
        }
        return raw
    }

    /// The photograph's region, as stored bytes — the comparison that must not move by one ulp.
    private static func bytes(_ t: MTLTexture, _ rect: ImageRect) -> [UInt8] {
        let bpr = bytesPerRow(t) / t.width
        var raw = [UInt8](repeating: 0, count: bpr * rect.height)
        raw.withUnsafeMutableBytes { buf in
            t.getBytes(buf.baseAddress!, bytesPerRow: bpr,
                       from: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height),
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
        return [Float(raw[2]) / 255, Float(raw[1]) / 255, Float(raw[0]) / 255, Float(raw[3]) / 255]
    }

    private static func displayCode(_ pixel: [Float], linear: Bool) -> Double {
        let v = Double(pixel[0])
        let display = linear ? (v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055) : v
        return (display * 255).rounded()
    }

    private static func code(_ t: MTLTexture, _ x: Int, _ y: Int) -> Int {
        let code = Int(displayCode(pixel(t, x, y), linear: t.pixelFormat == .rgba16Float).rounded())
        return min(max(code, 0), 255)
    }
}
