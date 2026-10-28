import XCTest
@testable import PhotonsCore
import CoreImage
import Metal
import CryptoKit

/// 097 — the engine side of the per-plane DNG warp (`s0_geometry_lens*`).
///
/// The four acceptance properties from the派单:
///   · three identity planes leave the frame byte-identical to no warp at all;
///   · three *different* planes really move R and B relative to G by the file's `kr0` (the 095
///     refutation: Apple reads only plane 1, so the same file moves nothing through Apple);
///   · the real SL3 file's distortion matches Apple's one-plane warp in the centre (corr ≥ 0.98);
///   · the real file's channel alignment is what its coefficients say, and is recorded, not assumed.
final class CAWarpTests: XCTestCase {

    // MARK: - fixtures

    private func fixtureURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func metalAvailable() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
    }

    /// A smooth non-repeating ramp with identical R/G/B content: the per-plane warp then shows up as
    /// a pure geometric channel shift, not as a colour difference in the fixture.
    private func rampImage(width: Int, height: Int) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let u = Double(x) / Double(max(width - 1, 1))
                let v = Double(y) / Double(max(height - 1, 1))
                let s = Float(0.05 + 0.65 * (0.55 * u + 0.45 * v)
                              + 0.15 * sin(13.0 * u + 7.0 * v))
                rgba[o] = Float16(s)
                rgba[o + 1] = Float16(s)
                rgba[o + 2] = Float16(s)
                rgba[o + 3] = 1
            }
        }
        return LinearImage(width: width, height: height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
    }

    private func render(_ image: LinearImage, identity: String,
                        profile: LensProfile?) throws -> DisplayImage {
        let graph = try RenderGraph(input: RenderInput(image: image, identity: identity,
                                                       lensProfile: profile))
        let result = try graph.render(EditModel.neutral,
                                      options: RenderOptions(scale: 1, useCache: false,
                                                             wantsPixels: true))
        return try XCTUnwrap(result.display)
    }

    // MARK: - 4. identity is byte-identical

    func testThreeIdentityPlanesLeaveTheFrameByteIdentical() throws {
        try metalAvailable()
        let image = rampImage(width: 1201, height: 901)
        let identityPlane = LensWarpPlane.identity
        let profile = LensProfile(planes: [identityPlane, identityPlane, identityPlane])
        let bare = try render(image, identity: "lens-identity-bare", profile: nil)
        let warped = try render(image, identity: "lens-identity-warp", profile: profile)
        XCTAssertEqual(warped.sha256(), bare.sha256(),
                       "three identity planes must be the same bytes as no warp")
        print("identity planes: sha=\(warped.sha256().prefix(16))… (same as no warp)")
    }

    // MARK: - 5. extreme per-plane data must move R and B

    /// The rewrite script the 095 probe used. The profile it writes is `kr0 = 0.90 / 1.00 / 1.10`.
    private func makeStrongFile(from source: URL) throws -> URL {
        let script = URL(fileURLWithPath: NSString(
            string: "~/workspace/scripts/dng-opcode-rewrite.py").expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw XCTSkip("no dng-opcode-rewrite.py")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("lens-strong-\(UUID().uuidString).dng")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", script.path, source.path, out.path, "0.90", "1.00", "1.10"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("dng-opcode-rewrite.py failed") }
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        return out
    }

    func testStrongFileMovesRedAndBlueByTenPercent() throws {
        try metalAvailable()
        let original = try fixtureURL()
        let strongURL = try makeStrongFile(from: original)
        let profile = try XCTUnwrap(LensProfile.read(from: strongURL))
        XCTAssertEqual(profile.planes.map(\.kr0), [0.90, 1.00, 1.10])
        XCTAssertTrue(profile.hasPerPlaneDifference)

        // Our path: Apple's correction is off in `decodeDetailed` (the profile differs), S0 applies
        // the three planes. The fixture is the same ramp, so the best R→G scale *is* the kr0 ratio.
        let image = rampImage(width: 1601, height: 1201)
        let ourStrong = try render(image, identity: "lens-strong", profile: profile)
        let red = bestScale(of: ourStrong, channel: 0)
        let blue = bestScale(of: ourStrong, channel: 2)
        print(String(format: "ours strong: R→G scale=%.4f  B→G scale=%.4f", red.scale, blue.scale))
        XCTAssertGreaterThanOrEqual(abs(red.scale - 1), 0.08)
        XCTAssertGreaterThanOrEqual(abs(blue.scale - 1), 0.08)
        XCTAssertEqual(red.scale, 0.90, accuracy: 0.02)
        XCTAssertEqual(blue.scale, 1.10, accuracy: 0.02)

        // Apple's path: the same file, `isLensCorrectionEnabled = true`, with a decoded raw then
        // measured. Plane 1 is applied to all three channels, so R→G stays where the raw file put it
        // — the 095 result, restated on the generated file.
        let appleOriginal = try appleDecode(original, scale: 0.25, lensCorrection: true)
        let appleStrong = try appleDecode(strongURL, scale: 0.25, lensCorrection: true)
        let appleBase = bestScale(appleOriginal.rgba, appleOriginal.width, appleOriginal.height,
                                  channel: 0).scale
        let appleChanged = bestScale(appleStrong.rgba, appleStrong.width, appleStrong.height,
                                     channel: 0).scale
        print(String(format: "apple strong: R→G %.4f (original %.4f, Δ=%.4f)",
                     appleChanged, appleBase, appleChanged - appleBase))
        XCTAssertLessThan(abs(appleChanged - appleBase), 0.02,
                          "Apple read plane 0 — it is not supposed to")
    }

    // MARK: - 5b. the polynomial is the spec's (even powers)

    /// The bug this pins: `kr0 + r·(kr1 + r·(kr2 + r·kr3))` — odd powers — agrees with the spec for
    /// every `kr0`-only fixture and is wrong on every real file (SL3 `kr1 ≈ −0.0076` moves the picture
    /// by 0.4 % of the radius; measured against Apple's warp: corr 0.930 vs 0.99958). Two pins, one
    /// for the CPU statement and one for the Metal copy.
    func testTheRadialPolynomialUsesEvenPowersAndTheMetalCopyAgrees() throws {
        // Spec values, computed by hand: f(r) = 1 − 0.2 r² for kr1 = −0.2.
        let plane = LensWarpPlane(kr0: 1, kr1: -0.2, kr2: 0, kr3: 0)
        XCTAssertEqual(plane.radialScale(at: 0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(plane.radialScale(at: 0.5), 1 - 0.2 * 0.25, accuracy: 1e-12)
        XCTAssertEqual(plane.radialScale(at: 1.0), 0.8, accuracy: 1e-12)
        XCTAssertEqual(plane.radialScale(at: 0.5), 0.95, accuracy: 1e-12,
                       "even powers: kr1·r² = −0.05; odd powers would give −0.10")

        // The Metal copy must be spelled the same way. `r * (kR.y + r * …)` is the wrong shape.
        let kernel = try String(contentsOfFile: Self.kernelSourcePath, encoding: .utf8)
        XCTAssertTrue(kernel.contains("float r2 = r * r;"), "kernel lost the shared r²")
        XCTAssertTrue(kernel.contains("kR.x + r2 * (kR.y + r2 * (kR.z + r2 * kR.w))"),
                      "Metal radial polynomial is not the spec's even-power form")
        XCTAssertFalse(kernel.contains("kR.x + r * (kR.y"),
                       "Metal still has the odd-power (wrong) polynomial")
    }

    private static let kernelSourcePath: String = {
        // `swift test` runs from the package root; go up from the test bundle if it ever does not.
        let direct = "Sources/PhotonsCore/Kernels/s0_geometry.metal"
        if FileManager.default.fileExists(atPath: direct) { return direct }
        return NSString(string: "~/Documents/GitHub/Photons/Sources/PhotonsCore/Kernels/s0_geometry.metal")
            .expandingTildeInPath
    }()

    // MARK: - 6. the real file

    func testRealFileMatchesAppleDistortionAndRecordsChannelAlignment() throws {
        try metalAvailable()
        let url = try fixtureURL()
        let profile = try XCTUnwrap(LensProfile.read(from: url))
        XCTAssertTrue(profile.hasPerPlaneDifference)

        let ours = try RAWDecoder().decodeDetailed(url, options: DecodeOptions(scale: 0.25))
        XCTAssertEqual(ours.lensProfile, profile)
        let ourImage = try render(ours.image, identity: "lens-real-ours", profile: profile)

        // Apple's own correction, from a filter that kept `isLensCorrectionEnabled` at its default.
        let appleImage = try appleDecode(url, scale: 0.25, lensCorrection: true)
        let appleRendered = try render(appleImage, identity: "lens-real-apple",
                                       profile: LensProfile(planes: [.identity]))

        let corr = greenCorrelation(ourImage, appleRendered, radiusFraction: 0.35)
        print(String(format: "real file: centre green corr(ours, apple)=%.5f", corr))
        XCTAssertGreaterThanOrEqual(corr, 0.98,
                                   "our per-plane warp must follow the same distortion as Apple's")

        let r = bestScale(of: ourImage, channel: 0, from: 0.995, to: 1.005, step: 0.00025)
        let b = bestScale(of: ourImage, channel: 2, from: 0.995, to: 1.005, step: 0.00025)
        print(String(format: "real file ours: R→G scale=%.6f  B→G scale=%.6f",
                     r.scale, b.scale))
        print(String(format: "real file apple: R→G scale=%.6f  B→G scale=%.6f",
                     bestScale(of: appleRendered, channel: 0, from: 0.995, to: 1.005,
                               step: 0.00025).scale,
                     bestScale(of: appleRendered, channel: 2, from: 0.995, to: 1.005,
                               step: 0.00025).scale))
        // The real coefficients differ by ~1e-4…2e-3, so the measured shift is small — but it is the
        // file's number, not zero, and it must not be wild.
        XCTAssertLessThan(abs(r.scale - 1), 0.02)
        XCTAssertLessThan(abs(b.scale - 1), 0.02)
    }

    // MARK: - Apple's decode, for the refutation

    private func appleDecode(_ url: URL, scale: Float, lensCorrection: Bool) throws -> LinearImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device") }
        guard let filter = CIRAWFilter(imageURL: url),
              let queue = device.makeCommandQueue() else {
            throw XCTSkip("CIRAWFilter unavailable")
        }
        filter.boostAmount = 0
        filter.isGamutMappingEnabled = false
        filter.scaleFactor = scale
        filter.isLensCorrectionEnabled = lensCorrection
        guard let output = filter.outputImage else { throw XCTSkip("no output image") }
        let extent = output.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0 else { throw XCTSkip("bad extent") }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc),
              let cb = queue.makeCommandBuffer() else { throw XCTSkip("texture failed") }
        let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let ctx = CIContext(mtlDevice: device, options: [.workingColorSpace: cs,
                                                         .outputColorSpace: cs,
                                                         .cacheIntermediates: false])
        ctx.render(output, to: texture, commandBuffer: cb,
                   bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: cs)
        cb.commit()
        cb.waitUntilCompleted()
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        rgba.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        RAWDecoder.flipRows(&rgba, width: w, height: h)
        return LinearImage(width: w, height: h, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "apple-\(scale)")
    }

    // MARK: - measurement

    private func corpus(width: Int, height: Int,
                        radiusFraction: Double) -> [(x: Double, y: Double)] {
        let cx = Double(width) / 2, cy = Double(height) / 2
        let radius = radiusFraction * Double(min(width, height)) / 2
        let step = max(1.0, radius / 90.0)
        var points: [(Double, Double)] = []
        var y = cy - radius
        while y <= cy + radius {
            var x = cx - radius
            while x <= cx + radius {
                if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= radius * radius {
                    points.append((x, y))
                }
                x += step
            }
            y += step
        }
        return points
    }

    private func value(_ pixels: [Float16], _ width: Int, _ height: Int,
                       _ x: Double, _ y: Double, _ channel: Int) -> Double {
        let px = x - 0.5, py = y - 0.5
        let x0 = Int(floor(px)), y0 = Int(floor(py))
        let fx = px - Double(x0), fy = py - Double(y0)
        func at(_ i: Int, _ j: Int) -> Double {
            let ci = min(max(i, 0), width - 1), cj = min(max(j, 0), height - 1)
            return Double(pixels[(cj * width + ci) * 4 + channel])
        }
        let a = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
        let b = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
        return a * (1 - fy) + b * fy
    }

    /// The radial scale `s` that best aligns `channel` with green: green is sampled at
    /// `centre + s·(p − centre)` and correlated with the channel at `p`. For our per-plane warp with
    /// `kr0`, the answer is `kr0` (green itself gives 1).
    private func bestScale(of image: DisplayImage, channel: Int,
                           from lower: Double = 0.84, to upper: Double = 1.16,
                           step: Double = 0.0025) -> (scale: Double, correlation: Double) {
        bestScale(image.rgba, image.width, image.height, channel: channel,
                  from: lower, to: upper, step: step)
    }

    private func bestScale(_ pixels: [Float16], _ width: Int, _ height: Int,
                           channel: Int, from lower: Double = 0.84, to upper: Double = 1.16,
                           step: Double = 0.0025) -> (scale: Double, correlation: Double) {
        let points = corpus(width: width, height: height, radiusFraction: 0.85)
        let cx = Double(width) / 2, cy = Double(height) / 2
        var best = (scale: 1.0, correlation: -2.0)
        var s = lower
        while s <= upper {
            var xs: [Double] = [], ys: [Double] = []
            xs.reserveCapacity(points.count)
            ys.reserveCapacity(points.count)
            for p in points {
                let gx = cx + s * (p.x - cx), gy = cy + s * (p.y - cy)
                xs.append(value(pixels, width, height, p.x, p.y, channel))
                ys.append(value(pixels, width, height, gx, gy, 1))
            }
            let c = pearson(xs, ys)
            if c > best.correlation { best = (s, c) }
            s += step
        }
        return best
    }

    private func pearson(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, a.count > 2 else { return -2 }
        let n = Double(a.count)
        let ma = a.reduce(0, +) / n, mb = b.reduce(0, +) / n
        var num = 0.0, da = 0.0, db = 0.0
        for i in a.indices {
            let x = a[i] - ma, y = b[i] - mb
            num += x * y; da += x * x; db += y * y
        }
        let den = (da * db).squareRoot()
        return den > 1e-20 ? num / den : -2
    }

    private func greenCorrelation(_ a: DisplayImage, _ b: DisplayImage,
                                  radiusFraction: Double) -> Double {
        guard a.width == b.width, a.height == b.height else { return 0 }
        let points = corpus(width: a.width, height: a.height, radiusFraction: radiusFraction)
        let xs = points.map { value(a.rgba, a.width, a.height, $0.x, $0.y, 1) }
        let ys = points.map { value(b.rgba, b.width, b.height, $0.x, $0.y, 1) }
        return pearson(xs, ys)
    }
}
