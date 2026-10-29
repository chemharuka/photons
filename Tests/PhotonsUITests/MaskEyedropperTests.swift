import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsUI

/// 139 — 亮度 / 颜色蒙版的吸管取值。
///
/// Every case runs the **shipped** conversion (`MaskEyedropper` → `OKLabMetric`) and the **shipped**
/// write (`CatalogSession.pickMask…`), then renders the real S1.5 atlas. The synthetic frames are
/// linear sRGB, the decoder's own space, so a wrong primaries/transfer assumption shows up as a
/// coverage that does not match the pixel it sampled.
@MainActor
final class MaskEyedropperTests: XCTestCase {

    // MARK: fixtures

    private func makeGraph(_ image: LinearImage, identity: String = "mask-eyedropper") throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func atlas(_ edit: EditModel, _ image: LinearImage) throws -> MaskAtlasDump {
        let graph = try makeGraph(image)
        return try XCTUnwrap(try graph.maskAtlas(edit),
                             "an enabled mask must produce an atlas")
    }

    /// Invert `OKLabMetric.fromLinear` on the neutral axis: the linear grey whose OKLab L is `target`.
    private func linearGrey(forL target: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<60 {
            let mid = (lo + hi) / 2
            let l = OKLabMetric.fromLinear(mid, mid, mid).L
            if l < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Horizontal ramp in the **sampler's own axis**: OKLab L 0.1 → 0.9, every channel equal.
    /// (A ramp in linear values would put the right-hand sample at L ≈ 0.96, inside the default
    /// upper feather — not the "0.1 / 0.9 luminance" the acceptance names.)
    private func luminanceRamp(width: Int = 128, height: Int = 32) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let target = 0.1 + 0.8 * Double(x) / Double(max(width - 1, 1))
                let v = Float(linearGrey(forL: target))
                let o = (y * width + x) * 4
                rgba[o] = Float16(v); rgba[o + 1] = Float16(v)
                rgba[o + 2] = Float16(v); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func twoTone(_ left: (Float, Float, Float), _ right: (Float, Float, Float),
                         width: Int = 96, height: Int = 32) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = x < width / 2 ? left : right
                let o = (y * width + x) * 4
                rgba[o] = Float16(c.0); rgba[o + 1] = Float16(c.1)
                rgba[o + 2] = Float16(c.2); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func colourRamp(width: Int = 96, height: Int = 8) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let t = Float(Double(x) / Double(max(width - 1, 1)))
                let o = (y * width + x) * 4
                rgba[o] = Float16(1 - t); rgba[o + 1] = 0; rgba[o + 2] = Float16(t); rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    /// Box sample from the decoded buffer at a column, the way the loupe's `samplePixel` reads it
    /// (radius 0: one pixel, so the expected value is exactly the ramp's value).
    private func sample(_ image: LinearImage, x: Int) -> RGBSample {
        image.averageRGB(x: x, y: image.height / 2, radius: 0)
    }

    private func maskShape(_ session: CatalogSession, _ maskID: String,
                           component: Int = 0) -> MaskShape {
        session.edit.masks.first { $0.id == maskID }!.components[component].shape
    }

    private func alpha(_ dump: MaskAtlasDump, _ maskID: String, x: Int, y: Int) -> Float {
        dump.slice(forMask: maskID)![y * dump.width + x]
    }

    // MARK: ① click centres the window on the sample

    func testLuminancePickerCentresTheWindowOnTheSample() throws {
        let image = luminanceRamp()
        let rightX = image.width - 1
        let leftX = 2
        let rightValue = MaskEyedropper.luminance(from: sample(image, x: rightX))
        let leftValue = MaskEyedropper.luminance(from: sample(image, x: leftX))
        XCTAssertGreaterThan(rightValue, leftValue)

        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .luminanceRange))
        XCTAssertTrue(session.pickMaskLuminance(mask.id, component: 0, at: rightValue))

        guard case .luminanceRange(let shape) = maskShape(session, mask.id) else {
            return XCTFail("the picker changed the shape kind")
        }
        XCTAssertLessThanOrEqual(shape.low, rightValue + 1e-12, "low must cover the sample")
        XCTAssertGreaterThanOrEqual(shape.high, rightValue - 1e-12, "high must cover the sample")
        // A full-range window (the default) opens 0.25 wide, centred on the sample.
        XCTAssertEqual(shape.low, 0.775, accuracy: 0.02)
        XCTAssertEqual(shape.high, 1.0, accuracy: 1e-9)

        let dump = try atlas(session.edit, image)
        let right = alpha(dump, mask.id, x: rightX, y: image.height / 2)
        let left = alpha(dump, mask.id, x: leftX, y: image.height / 2)
        XCTAssertGreaterThanOrEqual(right, 0.90, "the sampled side must be selected")
        XCTAssertLessThanOrEqual(left, 0.05, "the far side must not be selected")
        print("LUM PICK · v \(String(format: "%.4f", rightValue)) → "
              + "\(String(format: "%.4f", shape.low))…\(String(format: "%.4f", shape.high))"
              + " · alpha right \(right) left \(left)")
    }

    // MARK: ② ⌥ click moves only the nearer edge

    func testOptionClickMovesOnlyTheNearerEdge() throws {
        let image = luminanceRamp()
        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .luminanceRange))
        let rightValue = MaskEyedropper.luminance(from: sample(image, x: image.width - 2))
        XCTAssertTrue(session.pickMaskLuminance(mask.id, component: 0, at: rightValue))
        guard case .luminanceRange(let before) = maskShape(session, mask.id) else {
            return XCTFail("the picker changed the shape kind")
        }

        let leftValue = MaskEyedropper.luminance(from: sample(image, x: 2))
        XCTAssertTrue(session.pickMaskLuminance(mask.id, component: 0, at: leftValue,
                                                moveNearerEdge: true))
        guard case .luminanceRange(let after) = maskShape(session, mask.id) else {
            return XCTFail("the ⌥ picker changed the shape kind")
        }
        XCTAssertEqual(after.low, leftValue, accuracy: 1e-12, "the nearer (low) edge moved")
        XCTAssertEqual(after.high, before.high, "high is verbatim")
        XCTAssertEqual(after.lowFeather, before.lowFeather, "low feather is verbatim")
        XCTAssertEqual(after.highFeather, before.highFeather, "high feather is verbatim")
        print("LUM OPT · high \(before.high) unchanged · low "
              + "\(String(format: "%.4f", after.low))")
    }

    // MARK: ③ colour samples append, and the oldest is dropped past eight

    func testColourPickerAppendsAndCapsAtEight() throws {
        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .colorRange))
        var colours: [[Double]] = []
        for i in 0..<9 {
            let r = Double(i) / 10.0
            let g = Double(9 - i) / 10.0
            let b = Double((i * 3) % 10) / 10.0
            colours.append([r, g, b])
        }
        for colour in colours {
            XCTAssertTrue(session.pickMaskColour(mask.id, component: 0, sampleSRGB: colour))
        }
        guard case .colorRange(let shape) = maskShape(session, mask.id) else {
            return XCTFail("the picker changed the shape kind")
        }
        XCTAssertEqual(shape.samples.count, ColorRangeShape.maxSamples)
        XCTAssertEqual(shape.samples.first, colours[1], "the oldest sample was replaced")
        XCTAssertEqual(shape.samples.last, colours[8], "the newest sample is last")
        XCTAssertEqual(shape.tolerance, ColorRangeShape.default.tolerance,
                       "picking must not reset tolerance")
        print("COLOUR PICK · n \(shape.samples.count) · first \(shape.samples.first!)"
              + " · last \(shape.samples.last!)")
    }

    // MARK: ④ the sample is the pixel's sRGB code

    func testSampledColourIsThePixelColour() throws {
        let red: (Float, Float, Float) = (1, 0, 0)
        let grey: (Float, Float, Float) = (0.5, 0.5, 0.5)
        let image = twoTone(red, grey)
        let x = 8
        let y = image.height / 2
        let sampleRGB = sample(image, x: x)
        let stored = MaskEyedropper.colour(from: sampleRGB)

        // The pixel as a bitmap: 8-bit sRGB bytes straight from the same decode buffer. (`setColor`
        // on a `.calibratedRGB` rep colour-manages the value, so it is not the raw code.)
        var bytes = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for yy in 0..<image.height {
            for xx in 0..<image.width {
                let c = sample(image, x: xx)
                let o = (yy * image.width + xx) * 4
                bytes[o] = UInt8((HDRCurveAxis.srgbEncode(c.r) * 255).rounded())
                bytes[o + 1] = UInt8((HDRCurveAxis.srgbEncode(c.g) * 255).rounded())
                bytes[o + 2] = UInt8((HDRCurveAxis.srgbEncode(c.b) * 255).rounded())
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let cg = try XCTUnwrap(CGImage(width: image.width, height: image.height,
                                       bitsPerComponent: 8, bitsPerPixel: 32,
                                       bytesPerRow: image.width * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGBitmapInfo(
                                           rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                       provider: provider, decode: nil,
                                       shouldInterpolate: false, intent: .defaultIntent))
        let rep = NSBitmapImageRep(cgImage: cg)
        // `colorAt` reads the stored sRGB bytes as calibrated components — do **not** colour-convert
        // again (`usingColorSpace(.sRGB)` turns (1,0,0) into (1,0.149,0) on this machine).
        let c = try XCTUnwrap(rep.colorAt(x: x, y: y))
        let codes = [Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent)]
        for i in 0..<3 {
            XCTAssertEqual(stored[i], codes[i], accuracy: 2.0 / 255.0,
                           "channel \(i) must be the pixel's sRGB code within 2 codes")
        }

        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .colorRange))
        XCTAssertTrue(session.pickMaskColour(mask.id, component: 0, sampleSRGB: stored))
        let dump = try atlas(session.edit, image)
        let redAlpha = alpha(dump, mask.id, x: x, y: y)
        let greyAlpha = alpha(dump, mask.id, x: image.width - 8, y: y)
        XCTAssertGreaterThanOrEqual(redAlpha, 0.90, "the red block must be selected")
        XCTAssertLessThanOrEqual(greyAlpha, 0.05, "the grey background must not be selected")
        print("COLOUR PIXEL · stored \(stored) · rep \(codes) · alpha \(redAlpha)/\(greyAlpha)")
    }

    // MARK: ⑤ one pick = one history entry

    func testPickCreatesExactlyOneHistoryEntry() throws {
        let image = luminanceRamp()
        let value = MaskEyedropper.luminance(from: sample(image, x: image.width - 2))
        let colourValue = MaskEyedropper.colour(from: sample(image, x: image.width / 2))

        // `history.count` is the number of retained snapshots (the redo branch included); undo moves
        // the cursor rather than deleting it. One pick is one **cursor step**, and one undo returns
        // the value — the two facts ⌘Z actually depends on. A separate session per picker keeps the
        // second one from writing into an open redo branch, which would replace rather than append.
        let lumSession = CatalogSession()
        let lum = try XCTUnwrap(lumSession.addMask(kind: .luminanceRange))
        let before = lumSession.history.count
        let cursorBefore = lumSession.history.cursor
        XCTAssertTrue(lumSession.pickMaskLuminance(lum.id, component: 0, at: value))
        XCTAssertEqual(lumSession.history.count, before + 1, "one luminance pick = one snapshot")
        XCTAssertEqual(lumSession.history.cursor, cursorBefore + 1)
        XCTAssertTrue(lumSession.undo())
        XCTAssertEqual(lumSession.history.cursor, cursorBefore, "⌘Z steps back over that snapshot")
        guard case .luminanceRange(let restored) = maskShape(lumSession, lum.id) else {
            return XCTFail("undo changed the shape kind")
        }
        XCTAssertEqual(restored, LuminanceRangeShape.default, "the window returned to before")

        let colourSession = CatalogSession()
        let colour = try XCTUnwrap(colourSession.addMask(kind: .colorRange))
        let colourBefore = colourSession.history.count
        let colourCursor = colourSession.history.cursor
        XCTAssertTrue(colourSession.pickMaskColour(colour.id, component: 0, sampleSRGB: colourValue))
        XCTAssertEqual(colourSession.history.count, colourBefore + 1,
                       "one colour pick = one snapshot")
        XCTAssertEqual(colourSession.history.cursor, colourCursor + 1)
        XCTAssertTrue(colourSession.undo())
        XCTAssertEqual(colourSession.history.cursor, colourCursor)
        guard case .colorRange(let restoredColour) = maskShape(colourSession, colour.id) else {
            return XCTFail("undo changed the shape kind")
        }
        XCTAssertEqual(restoredColour.samples, [[0.5, 0.5, 0.5]],
                       "the sample list returned to the placeholder it opened with")
        print("HISTORY · luminance +1/−1 · colour +1/−1")
    }

    // MARK: ⑥ sampling does not change the presented frame

    func testPickDoesNotChangeThePresentedFrame() throws {
        let image = twoTone((1, 0, 0), (0.5, 0.5, 0.5))
        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .colorRange))
        let graph = try makeGraph(image, identity: "frame-sha")

        func frameHash(_ edit: EditModel) throws -> String {
            let result = try graph.render(edit, options: RenderOptions(wantsPixels: true))
            return try XCTUnwrap(result.display, "wantsPixels must produce DisplayImage").sha256()
        }
        let before = try frameHash(session.edit)
        let stored = MaskEyedropper.colour(from: sample(image, x: 8))
        XCTAssertTrue(session.pickMaskColour(mask.id, component: 0, sampleSRGB: stored))
        let after = try frameHash(session.edit)
        XCTAssertEqual(after, before, "a mask parameter change must not move a displayed pixel")
        print("FRAME SHA · \(before.prefix(12))… unchanged after pick")
    }

    // MARK: ⑦ the sampler and the kernel share one coordinate

    func testPickerAndKernelAgreeOnTheLuminanceCoordinate() throws {
        // 反证条件: if the picker decoded the buffer as display-referred (or used BT.709 luma instead
        // of OKLab L on working primaries), this narrow window would be centred on the wrong number
        // and the alpha at the sampled pixel would fall below 0.95.
        let image = luminanceRamp(width: 96, height: 16)
        let x = 60
        let y = image.height / 2
        let value = MaskEyedropper.luminance(from: sample(image, x: x))
        let shape = LuminanceRangeShape(low: value - 0.02, high: value + 0.02,
                                        lowFeather: 0, highFeather: 0)
        let dump = try atlas(doctor(.luminanceRange(shape)), image)
        let a = alpha(dump, "m-luminanceRange", x: x, y: y)
        XCTAssertGreaterThanOrEqual(a, 0.95,
                                    "the picker's value must be inside the kernel's own window")
        print("SPACE · v \(String(format: "%.5f", value)) · alpha \(a)")
    }

    // MARK: ⑫ tolerance widens the selection

    func testToleranceWidensTheSelection() throws {
        let image = colourRamp()
        func rendered(_ tolerance: Double) throws -> (MaskAtlasDump, String) {
            let shape = ColorRangeShape(samples: [[1, 0, 0]], tolerance: tolerance, smoothness: 0.5)
            let dump = try atlas(doctor(.colorRange(shape)), image)
            return (dump, shape.keyString)
        }
        let (narrow, narrowKey) = try rendered(0.30)
        let (wide, _) = try rendered(0.60)
        let narrowSlice = try XCTUnwrap(narrow.slice(forMask: "m-colorRange"))
        let wideSlice = try XCTUnwrap(wide.slice(forMask: "m-colorRange"))
        let narrowRatio = Double(narrowSlice.filter { $0 > 0.5 }.count) / Double(narrowSlice.count)
        let wideRatio = Double(wideSlice.filter { $0 > 0.5 }.count) / Double(wideSlice.count)
        XCTAssertGreaterThanOrEqual(wideRatio, narrowRatio + 0.05,
                                    "0.30 → 0.60 must cover at least 5 percentage points more")

        let (back, backKey) = try rendered(0.30)
        XCTAssertEqual(backKey, narrowKey, "the key is byte-identical when the value returns")
        XCTAssertEqual(try XCTUnwrap(back.slice(forMask: "m-colorRange")), narrowSlice,
                       "…and so are the rendered coverages")
        print(String(format: "TOLERANCE · 0.30 %.1f%% → 0.60 %.1f%% (+%.1f pp)",
                     narrowRatio * 100, wideRatio * 100, (wideRatio - narrowRatio) * 100))
    }

    // MARK: helpers

    private func doctor(_ shape: MaskShape) -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-\(shape.kind)", opacity: 1,
                           components: [MaskComponent(id: "c", feather: 0, shape: shape)],
                           adjustments: .identity)]
        return edit
    }
}
