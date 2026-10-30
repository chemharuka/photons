import XCTest
import Metal
import CryptoKit
import simd
import PhotonsCore

/// 158 — **点颜色 (Point Color)**: multiple sampled swatches, each a Rec.709 full-range YUV box with
/// three adjustments, rendered by S3.6b immediately after S3.6.
///
/// The suite is organised around the acceptance:
///
///  1. **The model.** An old single-object `point` reads as one selected swatch; three swatches
///     round-trip in order; `active` does not enter the stage key.
///  2. **Disjoint boxes.** A red box + a blue box: moving A leaves blue and grey byte-identical.
///  3. **Stacking.** Both boxes move their own side and match the one-at-a-time frames within 1 code.
///  4. **Grey is exact.** The pale floor gives a grey weight 0, so it is written back bit for bit.
///  5. **The pale guard.** A sample below `chromaFloorYCbCr` is not sampled; a nearly-grey pixel has
///     weight 0 under any parameters.
///  6. **CPU = GPU.**
final class PointColorTests: XCTestCase {

    // MARK: - fixtures

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func picture(_ width: Int, _ height: Int, identity: String = "point-colour",
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
                           colorSpace: "extendedLinearSRGB",
                           decoderVersion: "synthetic-158")
    }

    private static let toWorking = ColorPrimaries.conversion(from: ColorPrimaries.decoded,
                                                             to: ColorPrimaries.working)
    private static let toSRGB = ColorPrimaries.conversion(from: ColorPrimaries.working, to: .sRGB)

    /// Three blocks, left red-orange / centre grey / right blue, in decoded **linear** sRGB. The two
    /// colours are built at a modest OKLCh chroma (0.08) so a +30° rotation stays inside the gamut and
    /// the hue assertion is about the operator, not about clipping.
    private static let red = displayLinear(L: 0.62, C: 0.08, hue: 30)
    private static let grey = SIMD3(0.18, 0.18, 0.18)
    private static let blue = displayLinear(L: 0.52, C: 0.08, hue: 260)

    private static func displayLinear(L: Double, C: Double, hue: Double) -> SIMD3<Double> {
        let working = OKLCh.toLinear(L: L, C: C, hue: hue)
        return ColorPrimaries.conversion(from: .working, to: .sRGB).applying(to: working)
    }

    private func threeBlocks() -> LinearImage {
        picture(90, 30) { x, _ in
            let c: SIMD3<Double>
            if x < 30 { c = Self.red } else if x < 60 { c = Self.grey } else { c = Self.blue }
            return (c.x, c.y, c.z)
        }
    }

    private func sample(_ rgb: SIMD3<Double>) -> PointColor {
        let yuv = PointColor.sampleYUV(fromDecodedLinear: RGBSample(r: rgb.x, g: rgb.y, b: rgb.z))
        return PointColor(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z)
    }

    private func display(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(),
                                    useCache: false, wantsPixels: true)
        return try XCTUnwrap(graph.render(edit, options: options).display)
    }

    private static func code(_ v: Float16) -> Int { Int((Double(v) * 255).rounded()) }

    private static func workingPixel(_ img: DisplayImage, x: Int, y: Int) -> SIMD3<Double> {
        let o = (y * img.width + x) * 4
        func decode(_ v: Float16) -> Double {
            let c = Double(v)
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let srgb = SIMD3(decode(img.rgba[o]), decode(img.rgba[o + 1]), decode(img.rgba[o + 2]))
        return fromSRGB.applying(to: srgb)
    }

    private static let fromSRGB = ColorPrimaries.conversion(from: .sRGB, to: ColorPrimaries.working)

    private static func oklch(_ img: DisplayImage, x: Int, y: Int) -> (L: Double, C: Double, h: Double) {
        let lch = OKLCh.fromLinear(workingPixel(img, x: x, y: y))
        return (lch.L, lch.C, lch.hue)
    }

    private static func signedHueDelta(_ a: Double, _ b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    private static func channelCodes(_ img: DisplayImage, x: Int, y: Int) -> [Int] {
        let o = (y * img.width + x) * 4
        return (0..<3).map { code(img.rgba[o + $0]) }
    }

    private func keyLink(_ set: PointColorSet) -> (link: String, material: String) {
        var edit = EditModel.neutral
        edit.color.point = set
        let dims = ImageSize(width: 90, height: 30)
        let links = RenderKeyChain.links(identity: "158-key", sourceSize: dims,
                                         canvas: dims, content: dims,
                                         edit: edit, display: DisplayOptions())
        return (links.pointColour ?? "", edit.keyMaterial(.pointColour))
    }

    // MARK: - M1 the old single-object document

    func testOldSingleObjectReadsAsOneSelectedSwatch() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let base = try encoder.encode(EditModel.neutral)
        var root = try XCTUnwrap(try JSONSerialization.jsonObject(with: base) as? [String: Any])
        var color = try XCTUnwrap(root["color"] as? [String: Any])
        color["point"] = ["sampleHue": 24.78, "sampleChroma": 0.08,
                          "range": 30, "feather": 30,
                          "hue": 0, "saturation": 0, "luminance": 0]
        root["color"] = color
        let old = try JSONSerialization.data(withJSONObject: root)

        let decoded = try JSONDecoder().decode(EditModel.self, from: old)
        let set = try XCTUnwrap(decoded.color.point)
        XCTAssertEqual(set.swatches.count, 1)
        XCTAssertEqual(set.active, 0)
        XCTAssertFalse(set.isActive, "a sample with no adjustment is not a stage")
        XCTAssertEqual(decoded.changedStages(from: .neutral), [.pointColour])

        // A sample-only old document has no pass, so its frame is the pre-140 frame byte for byte.
        let image = threeBlocks()
        let graph = try makeGraph(image, identity: "158-old")
        let neutral = try display(graph, EditModel.neutral)
        let rendered = try graph.render(decoded,
                                       options: RenderOptions(scale: 1, useCache: false,
                                                              wantsPixels: true))
        XCTAssertFalse(rendered.trace.executed.contains(.pointColour))
        XCTAssertEqual(try XCTUnwrap(rendered.display).sha256(), neutral.sha256())

        // Re-encoding writes the new shape; decoding it again is stable.
        let again = try JSONDecoder().decode(EditModel.self, from: encoder.encode(decoded))
        XCTAssertEqual(again.color.point, decoded.color.point)
        print("POINT M1 · old single object → \(set.swatches.count) swatch, active \(set.active ?? -1)")
    }

    // MARK: - M2 three-swatch round trip

    func testThreeSwatchesRoundTripInOrder() throws {
        let a = sample(Self.red)
        let b = sample(Self.blue)
        var c = sample(Self.grey)
        c.hue = -40
        let set = PointColorSet(swatches: [a, b, c], active: 2)
        var edit = EditModel.neutral
        edit.color.point = set

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(edit)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"swatches\""), "the new spelling writes an array")
        let back = try JSONDecoder().decode(EditModel.self, from: data)
        XCTAssertEqual(back.color.point, set)
        XCTAssertEqual(back.color.point?.swatches.count, 3)
        XCTAssertEqual(back.color.point?.active, 2)
        XCTAssertEqual(try encoder.encode(back), data)
        print("POINT M2 · 3 swatches round-trip, active \(set.active ?? -1)")
    }

    // MARK: - M3 the key chain

    func testActiveDoesNotEnterTheStageKeyButSwatchesDo() throws {
        var a = sample(Self.red)
        a.hue = 10
        var b = sample(Self.blue)
        b.hue = 20
        let base = PointColorSet(swatches: [a, b], active: 0)
        let selected1 = PointColorSet(swatches: [a, b], active: 1)
        let reference = keyLink(base)
        let switched = keyLink(selected1)
        XCTAssertFalse(reference.link.isEmpty)
        XCTAssertEqual(reference.link, switched.link, "active moves no pixel and must not miss the cache")
        XCTAssertEqual(reference.material, switched.material)

        var moved = base
        moved.swatches[1].hue = 25
        let changed = keyLink(moved)
        XCTAssertNotEqual(changed.link, reference.link)
        XCTAssertNotEqual(changed.material, reference.material)
        print("POINT M3 · active 0→1 keeps the key; swatch[1].hue moves it")
    }

    // MARK: - K1 disjoint boxes

    func testEachBoxOnlyMovesItsOwnBlock() throws {
        let image = threeBlocks()
        let graph = try makeGraph(image, identity: "158-disjoint")
        let neutral = try display(graph, EditModel.neutral)

        var a = sample(Self.red)
        a.hue = 100
        var b = sample(Self.blue)
        b.hue = 100

        let onlyA = PointColorSet(swatches: [a, b.withAdjustmentZero()], active: 0)
        var editA = EditModel.neutral
        editA.color.point = onlyA
        let outA = try display(graph, editA)

        // Red moved; blue and grey are bit-identical.
        XCTAssertNotEqual(Self.channelCodes(outA, x: 15, y: 15),
                          Self.channelCodes(neutral, x: 15, y: 15))
        for (x, name) in [(45, "grey"), (75, "blue")] {
            XCTAssertEqual(Self.channelCodes(outA, x: x, y: 15),
                           Self.channelCodes(neutral, x: x, y: 15),
                           "\(name) is outside A and must not move")
        }

        let onlyB = PointColorSet(swatches: [sample(Self.red).withAdjustmentZero(), b], active: 1)
        var editB = EditModel.neutral
        editB.color.point = onlyB
        let outB = try display(graph, editB)
        XCTAssertNotEqual(Self.channelCodes(outB, x: 75, y: 15),
                          Self.channelCodes(neutral, x: 75, y: 15))
        for (x, name) in [(15, "red"), (45, "grey")] {
            XCTAssertEqual(Self.channelCodes(outB, x: x, y: 15),
                           Self.channelCodes(neutral, x: x, y: 15),
                           "\(name) is outside B and must not move")
        }
        print("POINT K1 · A moves red only, B moves blue only, grey untouched in both")
    }

    // MARK: - K2 stacking

    func testBothBoxesStackAndMatchTheOneAtATimeFrames() throws {
        let image = threeBlocks()
        let graph = try makeGraph(image, identity: "158-stack")
        var a = sample(Self.red)
        a.hue = 100
        var b = sample(Self.blue)
        b.saturation = 60

        var both = EditModel.neutral
        both.color.point = PointColorSet(swatches: [a, b], active: 0)
        let stacked = try display(graph, both)

        var onlyA = EditModel.neutral
        onlyA.color.point = PointColorSet(swatches: [a, b.withAdjustmentZero()], active: 0)
        let outA = try display(graph, onlyA)

        var onlyB = EditModel.neutral
        onlyB.color.point = PointColorSet(swatches: [a.withAdjustmentZero(), b], active: 1)
        let outB = try display(graph, onlyB)

        for x in [15, 75] {
            let s = Self.channelCodes(stacked, x: x, y: 15)
            let expected = Self.channelCodes(x == 15 ? outA : outB, x: x, y: 15)
            for (u, v) in zip(s, expected) {
                XCTAssertLessThanOrEqual(abs(u - v), 1,
                                         "stacking must agree with the one-at-a-time frame")
            }
        }
        XCTAssertNotEqual(Self.channelCodes(stacked, x: 15, y: 15),
                          Self.channelCodes(try display(graph, EditModel.neutral), x: 15, y: 15))
        XCTAssertNotEqual(Self.channelCodes(stacked, x: 75, y: 15),
                          Self.channelCodes(try display(graph, EditModel.neutral), x: 75, y: 15))
        print("POINT K2 · both sides move; each block ≤1 code from its solo frame")
    }

    // MARK: - K3 grey is exact

    func testGreyPixelsAreBitIdenticalUnderEveryParameterSet() throws {
        let image = picture(32, 32) { x, _ in
            let v = 0.03 + Double(x) / 31 * 0.75
            return (v, v, v)
        }
        let graph = try makeGraph(image, identity: "158-grey")
        let neutral = try display(graph, EditModel.neutral)

        var wide = sample(Self.red)
        wide.range = 120
        wide.feather = 120
        wide.hue = 100
        wide.saturation = 100
        wide.luminance = 100
        var wideB = sample(Self.blue)
        wideB.range = 120
        wideB.feather = 120
        wideB.hue = -100
        wideB.saturation = -100
        wideB.luminance = -100

        for set in [PointColorSet(swatches: [wide], active: 0),
                    PointColorSet(swatches: [wide, wideB], active: 1)] {
            var edit = EditModel.neutral
            edit.color.point = set
            let out = try display(graph, edit)
            XCTAssertEqual(out.sha256(), neutral.sha256(),
                           "a neutral pixel has weight 0 and must stay bit-identical")
        }
        print("POINT K3 · grey ramp byte-identical for 1 and 2 wide swatches")
    }

    // MARK: - K4 the pale guard

    func testPaleSamplesAreRejectedAndPalePixelsHaveZeroWeight() throws {
        // 0.005 chroma around mid grey: below the 0.01 pixel floor.
        let pale = SIMD3(0.180, 0.180, 0.187)
        let yuv = PointColor.sampleYUV(fromDecodedLinear: RGBSample(r: pale.x, g: pale.y, b: pale.z))
        let rejected = PointColor(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z)
        XCTAssertLessThan(rejected.sampleChromaYCbCr, PointColor.chromaFloorYCbCr)
        XCTAssertFalse(rejected.isSampled, "the model refuses a too-pale sample")
        XCTAssertFalse(rejected.isActive, "…and it can never make a stage")

        // A coloured box that would otherwise cover the pale patch still gives it weight 0.
        var fence = sample(Self.blue)
        fence.range = 120
        fence.feather = 120
        fence.hue = 100
        XCTAssertEqual(fence.weight(yuv: yuv), 0)
        XCTAssertEqual(PointColorSet(swatches: [fence], active: 0).apply(
            PointColor.linearWorking(from: yuv)), PointColor.linearWorking(from: yuv))

        // And the whole pale patch is byte-identical in a real render.
        let image = picture(32, 32) { _, _ in (pale.x, pale.y, pale.z) }
        let graph = try makeGraph(image, identity: "158-pale")
        let neutral = try display(graph, EditModel.neutral)
        var edit = EditModel.neutral
        edit.color.point = PointColorSet(swatches: [fence], active: 0)
        XCTAssertEqual(try display(graph, edit).sha256(), neutral.sha256())
        print("POINT K4 · pale sample rejected; pale pixels weight 0 under a 120/120 box")
    }

    // MARK: - the eight-swatch cap and the model-level pale refusal

    func testSetRefusesAPaleSwatchAndTheNinth() throws {
        var set = PointColorSet()
        let good = sample(Self.red)
        for i in 0..<PointColorSet.maxSwatches {
            XCTAssertEqual(set.append(good), i)
        }
        XCTAssertEqual(set.swatches.count, 8)
        XCTAssertEqual(set.active, 7)
        XCTAssertNil(set.append(good), "the ninth swatch is refused")

        // The model-level half of K4: a pale swatch can never enter the list.
        var pale = PointColor()
        pale.sampleY = 0.5
        pale.sampleU = 0.505
        pale.sampleV = 0.5
        XCTAssertLessThan(pale.sampleChromaYCbCr, PointColor.chromaFloorYCbCr)
        var empty = PointColorSet()
        XCTAssertNil(empty.append(pale))
        XCTAssertTrue(empty.swatches.isEmpty)
        print("POINT CAP · 8 swatches max; pale append refused at the model boundary")
    }

    // MARK: - the adjustment itself

    func testAHueMoveOnTheSampledColourIsThirtyDegrees() throws {
        let image = threeBlocks()
        let graph = try makeGraph(image, identity: "158-hue")
        let neutral = try display(graph, EditModel.neutral)
        var swatch = sample(Self.red)
        swatch.hue = 100
        var edit = EditModel.neutral
        edit.color.point = PointColorSet(swatches: [swatch], active: 0)
        let moved = try display(graph, edit)

        let before = Self.oklch(neutral, x: 15, y: 15)
        let after = Self.oklch(moved, x: 15, y: 15)
        let delta = Self.signedHueDelta(before.h, after.h)
        print(String(format: "POINT HUE · %.2f° + 30° → %.2f° (Δ %.2f°)", before.h, after.h, delta))
        XCTAssertEqual(delta, 30, accuracy: 1.5, "hue +100 must deliver +30° at the box centre")
        XCTAssertEqual(after.L, before.L, accuracy: 0.02, "a hue rotation must not brighten it")
        XCTAssertEqual(after.C, before.C, accuracy: 0.02, "…nor change its chroma")
    }

    // MARK: - neutral is structural

    func testEmptyAndUnadjustedListsAddNoPass() throws {
        let image = threeBlocks()
        let graph = try makeGraph(image, identity: "158-neutral")
        let plain = try graph.render(EditModel.neutral,
                                     options: RenderOptions(scale: 1, useCache: false,
                                                            wantsPixels: true))
        let neutral = try XCTUnwrap(plain.display)

        var sampledOnly = EditModel.neutral
        sampledOnly.color.point = PointColorSet(swatches: [sample(Self.red)], active: 0)
        var empty = EditModel.neutral
        empty.color.point = PointColorSet(swatches: [], active: nil)

        for edit in [sampledOnly, empty, EditModel.neutral] {
            let result = try graph.render(edit, options: RenderOptions(scale: 1, useCache: false,
                                                                       wantsPixels: true))
            XCTAssertFalse(result.trace.executed.contains(.pointColour))
            XCTAssertEqual(try XCTUnwrap(result.display).sha256(), neutral.sha256())
            let dims = ImageSize(width: image.width, height: image.height)
            let links = RenderKeyChain.links(identity: "158-neutral", sourceSize: dims,
                                             canvas: dims, content: dims,
                                             edit: edit, display: DisplayOptions())
            XCTAssertNil(links.pointColour)
        }

        var active = EditModel.neutral
        var swatch = sample(Self.red)
        swatch.hue = 10
        active.color.point = PointColorSet(swatches: [swatch], active: 0)
        let result = try graph.render(active, options: RenderOptions(scale: 1, useCache: false,
                                                                     wantsPixels: true))
        XCTAssertTrue(result.trace.executed.contains(.pointColour))
        XCTAssertNotNil(result.keys.pointColour)
        print("POINT NEUTRAL · trace \(result.trace.csv)")
    }

    // MARK: - CPU reference vs kernel

    func testTheKernelIsTheCPUReference() throws {
        // A 180-column sweep of encoded sRGB colours at a fixed luminance, so every column has a
        // different YUV triple and the box weights vary continuously.
        let image = picture(180, 6) { x, _ in
            func decode(_ v: Double) -> Double {
                v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            let t = Double(x) / 179
            return (decode(0.05 + 0.9 * t), decode(0.7 - 0.5 * t), decode(0.2 + 0.3 * t))
        }
        let graph = try makeGraph(image, identity: "158-cpu")
        let source = RGBSample(r: Double(image.rgba[(3 * image.width + 60) * 4]),
                               g: Double(image.rgba[(3 * image.width + 60) * 4 + 1]),
                               b: Double(image.rgba[(3 * image.width + 60) * 4 + 2]))
        let yuv = PointColor.sampleYUV(fromDecodedLinear: source)
        var swatch = PointColor(sampleY: yuv.x, sampleU: yuv.y, sampleV: yuv.z)
        swatch.hue = 80
        swatch.saturation = 40
        swatch.luminance = 20
        let set = PointColorSet(swatches: [swatch], active: 0)
        var edit = EditModel.neutral
        edit.color.point = set
        let actual = try display(graph, edit)

        var worst = 0
        var total = 0
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let o = (y * image.width + x) * 4
                let src = SIMD3(Double(image.rgba[o]), Double(image.rgba[o + 1]),
                                Double(image.rgba[o + 2]))
                let working = Self.toWorking.applying(to: src)
                let out = set.apply(working)
                let srgb = Self.toSRGB.applying(to: out)
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
        print("POINT CPU↔GPU · max |Δcode| \(worst), mean "
              + String(format: "%.3f", Double(total) / Double(count)) + " over \(count) channels")
        XCTAssertLessThanOrEqual(worst, 2, "the kernel must be the CPU reference, not a lookalike")
    }
}

private extension PointColor {
    /// A copy with the three adjustment sliders at zero (still sampled, so the other swatch keeps its
    /// box). Used by the disjoint/stacking tests.
    func withAdjustmentZero() -> PointColor {
        var p = self
        p.hue = 0
        p.saturation = 0
        p.luminance = 0
        return p
    }
}
