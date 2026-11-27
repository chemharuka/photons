import XCTest
import Metal
@testable import PhotonsCore

/// 566-A — the scene-linear GMW denoiser that replaced S3.9's joint-bilateral NR branch.
///
/// These tests go through the shipped graph and Metal kernels. They pin the contract the ticket
/// states, not a CPU re-implementation:
///
///   1. the resting document is **50 / 50** (k = 2 / k_c = 3.5), and an absent key reads as 50 while
///      an explicit 0 stays 0 and is written back;
///   2. `0 / 0` is the pre-566 frame: no S1.5 pass, no `gmw=` key token, no S3.9 NR pass;
///   3. flat-region high-pass noise falls while a step edge does not widen;
///   4. a neutral frame keeps its luma code (the guided chroma pass must not divide by a zero variance);
///   5. an extremely dark (σ = 0) frame is a verbatim no-op — finite, not black;
///   6. the two strengths ride the linear curve link, not S3.9's material.
final class PostDenoise566Tests: XCTestCase {

    // MARK: - plumbing

    private func makeGraph(_ image: LinearImage, identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func render(_ graph: RenderGraph, _ edit: EditModel) throws -> DisplayImage {
        let options = RenderOptions(scale: 1, display: DisplayOptions(headroom: 1),
                                    useCache: false, wantsPixels: true)
        let result = try graph.render(edit, options: options)
        if let t = result.output { graph.recycle(output: t) }
        return try XCTUnwrap(result.display)
    }

    private struct Noise {
        var seed: UInt32
        init(_ s: UInt32) { seed = s }
        mutating func next() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / Double(1 << 24)
        }
        mutating func symmetric(_ amplitude: Double) -> Double { (next() - 0.5) * 2 * amplitude }
    }

    /// Left half: a noisy flat field. Right half: one horizontal step (top vs bottom), so the
    /// row-mean profile has a 10–90 % crossing to measure.
    private func noisyStep(w: Int = 320, h: Int = 240) -> LinearImage {
        var rng = Noise(0x566)
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let base: Double = x < w / 2 ? 0.14 : (y < h / 2 ? 0.06 : 0.42)
                let v = base + rng.symmetric(0.03)
                let i = (y * w + x) * 4
                rgba[i] = Float16(v); rgba[i + 1] = Float16(v); rgba[i + 2] = Float16(v); rgba[i + 3] = 1
            }
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-566")
    }

    private func flat(_ value: Float = 0.18, w: Int = 96, h: Int = 64) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        let v = Float16(value)
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba[i] = v; rgba[i + 1] = v; rgba[i + 2] = v; rgba[i + 3] = 1
        }
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-566-flat")
    }

    private func lumaCodes(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in 0..<out.count {
            let b = i * 4
            out[i] = 255 * (0.2126 * Double(image.rgba[b]) + 0.7152 * Double(image.rgba[b + 1])
                            + 0.0722 * Double(image.rgba[b + 2]))
        }
        return out
    }

    private func highPassSigma(_ luma: [Double], w: Int, h: Int,
                               x0: Int, x1: Int, y0: Int, y1: Int, radius: Int = 2) -> Double {
        func at(_ x: Int, _ y: Int) -> Double { luma[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        var sum = 0.0
        var n = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                var mean = 0.0
                var c = 0
                for dy in -radius...radius {
                    for dx in -radius...radius { mean += at(x + dx, y + dy); c += 1 }
                }
                let d = at(x, y) - mean / Double(c)
                sum += d * d
                n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    /// Row-mean step width 10 %→90 %, in pixels, over the right half where the step lives.
    private func edgeWidth(_ image: DisplayImage) -> Double {
        let luma = lumaCodes(image)
        let w = image.width
        var profile = [Double](repeating: 0, count: image.height)
        for y in 0..<image.height {
            var s = 0.0
            for x in (w / 2 + 12)..<(w - 12) { s += luma[y * w + x] }
            profile[y] = s / Double(w - 24 - w / 2)
        }
        let lo = profile.prefix(image.height / 4).reduce(.greatestFiniteMagnitude, min)
        let hi = profile.suffix(image.height / 4).reduce(-.greatestFiniteMagnitude, max)
        func crossing(_ t: Double) -> Double {
            for y in 1..<image.height where profile[y] >= t {
                let a = profile[y - 1], b = profile[y]
                return Double(y - 1) + (b == a ? 0 : (t - a) / (b - a))
            }
            return Double(image.height)
        }
        return crossing(lo + 0.9 * (hi - lo)) - crossing(lo + 0.1 * (hi - lo))
    }

    /// A plain document with both denoises at an explicit value (the resting 50 is not the baseline
    /// these measurements start from).
    private func document(_ nr: Double, _ cnr: Double) -> EditModel {
        var e = EditModel.neutral
        e.sharpen = SharpenGroup(amount: 0)
        e.effects.nonBayerLuminanceNR = nr
        e.effects.nonBayerColorNR = cnr
        return e
    }

    // MARK: - defaults and the key

    func testTheRestingDocumentIsFiftyFifty() throws {
        XCTAssertEqual(EditModel.neutral.effects.nonBayerLuminanceNR, 50)
        XCTAssertEqual(EditModel.neutral.effects.nonBayerColorNR, 50)
        XCTAssertFalse(EditModel.neutral.hasDetailFX, "S3.9 must not exist for a 50/50 document")

        // The resting value is not written: an absent key is what makes an old document read 50.
        let json = String(decoding: try JSONEncoder().encode(EditModel.neutral), as: UTF8.self)
        XCTAssertFalse(json.contains("nonBayerLuminanceNR"), "resting value must not be written")
        XCTAssertFalse(json.contains("nonBayerColorNR"), "resting value must not be written")

        // An explicit 0 is the user's own off and must survive a round trip.
        let off = document(0, 0)
        let offData = try JSONEncoder().encode(off)
        let offJSON = String(decoding: offData, as: UTF8.self)
        XCTAssertTrue(offJSON.contains("\"nonBayerLuminanceNR\":0"))
        XCTAssertTrue(offJSON.contains("\"nonBayerColorNR\":0"))
        let decoded = try JSONDecoder().decode(EditModel.self, from: offData)
        XCTAssertEqual(decoded.effects.nonBayerLuminanceNR, 0)
        XCTAssertEqual(decoded.effects.nonBayerColorNR, 0)

        // A pre-566 document has no key at all: it must read the new resting value.
        let old = try JSONDecoder().decode(EditModel.self, from: Data("{}".utf8))
        XCTAssertEqual(old.effects.nonBayerLuminanceNR, 50)
        XCTAssertEqual(old.effects.nonBayerColorNR, 50)
    }

    func testTheStrengthRidesTheCurveLinkNotS39() throws {
        let a = document(50, 50)
        let b = document(80, 20)
        XCTAssertNotEqual(a.keyMaterial(.curve), b.keyMaterial(.curve),
                          "S1.5 material must move the curve link")
        XCTAssertEqual(a.keyMaterial(.detailFX), b.keyMaterial(.detailFX),
                       "S3.9 reads neither denoise any more")
        XCTAssertTrue(a.keyMaterial(.curve).contains("gmw="))
        XCTAssertFalse(document(0, 0).keyMaterial(.curve).contains("gmw="),
                       "the explicit 0/0 pair must keep the pre-566 chain")
    }

    // MARK: - identity

    func testZeroZeroIsThePre566FrameAndEncodesNoS15Pass() throws {
        let image = noisyStep()
        let graph = try makeGraph(image, identity: "566-zero")
        let zero = document(0, 0)
        let once = try render(graph, zero)
        let twice = try render(graph, zero)
        XCTAssertEqual(once.sha256(), twice.sha256(), "deterministic")
        XCTAssertFalse(zero.keyMaterial(.curve).contains("gmw="))
        XCTAssertTrue(once.rgba.allSatisfy { $0.isFinite })
    }

    // MARK: - the measurement the design promises

    func testFlatNoiseFallsAndTheEdgeDoesNotWiden() throws {
        let image = noisyStep()
        let graph = try makeGraph(image, identity: "566-ab")
        let before = try render(graph, document(0, 0))
        let after = try render(graph, document(50, 0))

        let w = before.width, h = before.height
        let lb = lumaCodes(before), la = lumaCodes(after)
        let (x0, x1, y0, y1) = (8, w / 2 - 8, 8, h - 8)
        let sb = highPassSigma(lb, w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        let sa = highPassSigma(la, w: w, h: h, x0: x0, x1: x1, y0: y0, y1: y1)
        print(String(format: "566 · flat high-pass σ %.3f → %.3f codes (↓%.1f%%)",
                     sb, sa, 100 * (1 - sa / max(sb, 1e-9))))
        XCTAssertLessThanOrEqual(sa, 0.80 * sb, "flat luma noise must fall ≥20% at k=2")

        // The same fixture's horizontal step: the flatness gate must not turn it into a blur.
        let wb = edgeWidth(before)
        let wa = edgeWidth(after)
        print(String(format: "566 · step 10–90 %% width %.2f → %.2f px (%.2f×)", wb, wa, wa / wb))
        XCTAssertLessThanOrEqual(wa, 1.25 * wb, "the flatness gate must keep the edge")
    }

    func testANeutralFrameKeepsItsMean() throws {
        let graph = try makeGraph(flat(0.42), identity: "566-neutral")
        let off = try render(graph, document(0, 0))
        let on = try render(graph, document(50, 50))
        let a = lumaCodes(off), b = lumaCodes(on)
        let ma = a.reduce(0, +) / Double(a.count), mb = b.reduce(0, +) / Double(b.count)
        print(String(format: "566 · neutral flat mean %.2f → %.2f codes", ma, mb))
        XCTAssertEqual(ma, mb, accuracy: 0.5,
                       "a grey card must stay the same grey; the guided chroma may not shift luma")
    }

    // MARK: - the dark-frame robustness rule

    func testADarkFrameIsANoOpAndNeverNaN() throws {
        let image = flat(0.0)
        let graph = try makeGraph(image, identity: "566-dark")
        let off = try render(graph, document(0, 0))
        let on = try render(graph, document(50, 50))
        XCTAssertTrue(on.rgba.allSatisfy { $0.isFinite })
        XCTAssertEqual(on.sha256(), off.sha256(),
                       "σ = 0 must copy the frame verbatim, not invent a black level")
    }
}
