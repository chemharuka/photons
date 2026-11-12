import XCTest
import Foundation
@testable import PhotonsExtensions

/// End-to-end tests for the GPL tool boundary.
///
/// These need the `ansel-denoise-swift` executable and a `.anselnn` model. Point at them with
/// `ANSEL_DENOISE_SWIFT` / `ANSEL_DENOISE_MODEL`; without them the suite skips rather than fails,
/// because the tool is an optional extension (the app has to launch on a machine that lacks it).
final class AnselDenoiseClientTests: XCTestCase {

    static var toolURL: URL? {
        if let p = ProcessInfo.processInfo.environment["ANSEL_DENOISE_SWIFT"],
           FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        for c in ["/tmp/photons-ansel/release/ansel-denoise-swift",
                  "/opt/homebrew/bin/ansel-denoise-swift",
                  "/usr/local/bin/ansel-denoise-swift"]
        where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
    }

    static var modelURL: URL? {
        if let p = ProcessInfo.processInfo.environment["ANSEL_DENOISE_MODEL"],
           FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        let c = "/Users/luyao/workspace/ansel-probe/denoise-quarter-single-v1.anselnn"
        return FileManager.default.fileExists(atPath: c) ? URL(fileURLWithPath: c) : nil
    }

    func testProtocolVersionIsReported() throws {
        guard let tool = Self.toolURL else { throw XCTSkip("ansel-denoise-swift not present") }
        let client = AnselDenoiseClient(executableURL: tool)
        XCTAssertEqual(try client.protocolVersion(), 1)
    }

    func testMissingExecutableGivesATypedError() {
        let bogus = URL(fileURLWithPath: "/nonexistent/ansel-denoise-swift")
        let client = AnselDenoiseClient(executableURL: bogus)
        XCTAssertThrowsError(try client.protocolVersion()) { error in
            guard let f = error as? AnselDenoiseFailure else {
                return XCTFail("expected AnselDenoiseFailure, got \(error)")
            }
            XCTAssertEqual(f.code, "launch_failed")
        }
    }

    /// The whole point of the module: mosaic in, denoised mosaic out, same size, finite,
    /// and demonstrably smoother than the input.
    func testDenoiseActuallyReducesNoise() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)
        let service = AnselDenoiseService(client: client, modelURL: model)

        // Synthetic noisy constant gradient: noise on top of a smooth ramp, so the only
        // high-frequency content IS noise and its removal is measurable.
        let W = 192, H = 192
        var mosaic = [Float](repeating: 0, count: W * H)
        var seed: UInt64 = 99
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 33) / Float(1 << 31)          // [0,1)
        }
        // Box-Muller for gaussian noise.
        for y in 0..<H {
            for x in 0..<W {
                let base = Float(x) / Float(W) * 0.3 + 0.02
                let u1 = max(rnd(), 1e-7), u2 = rnd()
                let g = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
                mosaic[y * W + x] = base + 0.01 * g
            }
        }

        var opts = AnselDenoiseOptions()
        opts.tileSize = 64
        opts.overlap = 16
        opts.noiseA = [0.0004, 0.0003, 0.0004]
        opts.noiseB = [3e-6, 1e-6, 1e-6]

        let out = try service.denoise(mosaic: mosaic, width: W, height: H, options: opts)

        XCTAssertEqual(out.width, W)
        XCTAssertEqual(out.height, H)
        XCTAssertEqual(out.mosaic.count, W * H)
        XCTAssertTrue(out.mosaic.allSatisfy { $0.isFinite }, "output has non-finite values")
        XCTAssertFalse(out.padded, "192 is a multiple of the tile, so no padding was needed")
        XCTAssertGreaterThan(out.tiles, 1, "a 192² image at tile 64 must produce several tiles")

        // Noise metric: deviation from the known smooth ramp.
        func residualRMS(_ m: [Float]) -> Float {
            var sum: Float = 0
            for y in 0..<H {
                for x in 0..<W {
                    let truth = Float(x) / Float(W) * 0.3 + 0.02
                    let d = m[y * W + x] - truth
                    sum += d * d
                }
            }
            return (sum / Float(W * H)).squareRoot()
        }
        let before = residualRMS(mosaic)
        let after = residualRMS(out.mosaic)
        // A working denoiser must cut the residual substantially; the exact factor depends on the
        // synthesized noise vs. the model's priors, so assert a clear direction, not a number.
        XCTAssertLessThan(after, before * 0.8,
                          "denoising did not reduce the residual (before \(before), after \(after))")
    }

    /// A mosaic smaller than one tile must still work (the service pads internally).
    func testSmallMosaicIsHandledByPadding() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)
        let service = AnselDenoiseService(client: client, modelURL: model)

        let W = 40, H = 24
        var mosaic = [Float](repeating: 0, count: W * H)
        for i in 0..<mosaic.count { mosaic[i] = 0.05 + Float(i % 17) * 0.002 }

        var opts = AnselDenoiseOptions()
        opts.tileSize = 64          // larger than the image
        opts.overlap = 16
        opts.noiseA = [0.0004, 0.0003, 0.0004]
        opts.noiseB = [3e-6, 1e-6, 1e-6]

        let out = try service.denoise(mosaic: mosaic, width: W, height: H, options: opts)
        XCTAssertEqual(out.width, W)
        XCTAssertEqual(out.height, H)
        XCTAssertTrue(out.padded)
        XCTAssertTrue(out.mosaic.allSatisfy { $0.isFinite })
    }
}
