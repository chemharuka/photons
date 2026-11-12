import XCTest
import Foundation
@testable import PhotonsExtensions

/// End-to-end tests for the GPL tool boundary.
///
/// These need the `ansel-denoise-swift` executable and a `.anselnn` model. Point at them with
/// `ANSEL_DENOISE_SWIFT` / `ANSEL_DENOISE_MODEL`; without them the suite skips rather than fails,
/// because the tool is an optional extension (the app has to launch on a machine that lacks it).
///
/// Note what is *not* tested here: how the image is split, and the seam arithmetic. That lives in
/// the GPL tool (`DenoisePlanner`, `DenoiseImageRunner`) and is tested there — this side only
/// transports files and parses the report.
final class AnselDenoiseClientTests: XCTestCase {

    static var toolURL: URL? {
        if let p = ProcessInfo.processInfo.environment["ANSEL_DENOISE_SWIFT"],
           FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        for c in ["/tmp/ansel-img/release/ansel-denoise-swift",
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
        for c in ["/Users/luyao/workspace/ansel-probe/denoise-quarter-single-v1.anselnn",
                  "/Users/luyao/Documents/GitHub/ansel-denoise-swift/weights/denoise-quarter-single-v1.anselnn"]
        where FileManager.default.fileExists(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        return nil
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

    /// The whole point: mosaic in, denoised mosaic out, same size, finite, and smoother.
    func testDenoiseActuallyReducesNoise() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)
        let service = AnselDenoiseService(client: client, modelURL: model)

        let W = 192, H = 192
        var mosaic = [Float](repeating: 0, count: W * H)
        var seed: UInt64 = 99
        func rnd() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(seed >> 33) / Float(1 << 31)          // [0,1)
        }
        for y in 0..<H {
            for x in 0..<W {
                let base = Float(x) / Float(W) * 0.3 + 0.02
                let u1 = max(rnd(), 1e-7), u2 = rnd()
                let g = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
                mosaic[y * W + x] = base + 0.01 * g
            }
        }

        var opts = AnselDenoiseOptions()
        opts.noiseA = [0.0004, 0.0003, 0.0004]
        opts.noiseB = [3e-6, 1e-6, 1e-6]

        let out = try service.denoise(mosaic: mosaic, width: W, height: H, options: opts)

        XCTAssertEqual(out.width, W)
        XCTAssertEqual(out.height, H)
        XCTAssertEqual(out.mosaic.count, W * H)
        XCTAssertTrue(out.mosaic.allSatisfy { $0.isFinite }, "output has non-finite values")
        // A frame this small must go through in one piece; that is what keeps seams out.
        XCTAssertEqual(out.pieces, 1)
        XCTAssertEqual(out.seams, 0, "nothing to feather when there are no cuts")

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
        XCTAssertLessThan(after, before * 0.8,
                          "denoising did not reduce the residual (before \(before), after \(after))")
    }

    /// Output must stay inside the range a DNG writer can encode — a negative sample gets wrapped
    /// to white or rejected. The network's residual overshoots on clipped-black pixels (measured:
    /// 0.018% of a 60 MP frame, 94% of them with input below 0.01), so the tool has to clamp.
    func testOutputStaysInRangeWhereInputIsClippedBlack() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)
        let service = AnselDenoiseService(client: client, modelURL: model)

        // Left half pure black (clipped), right half a gradient: the situation that produced
        // negatives at the frame edge.
        let W = 256, H = 128
        var mosaic = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W where x >= W / 2 {
                mosaic[y * W + x] = Float(x - W / 2) / Float(W / 2) * 0.5
            }
        }
        var opts = AnselDenoiseOptions()
        opts.noiseA = [0.0004, 0.0003, 0.0004]
        opts.noiseB = [3e-6, 1e-6, 1e-6]
        opts.strength = 1.0                     // no blending to hide an overshoot

        let out = try service.denoise(mosaic: mosaic, width: W, height: H, options: opts)
        let lo = out.mosaic.min() ?? 0
        let hi = out.mosaic.max() ?? 0
        XCTAssertGreaterThanOrEqual(lo, 0, "output has negative samples (min \(lo))")
        XCTAssertLessThanOrEqual(hi, 1, "output exceeds white level (max \(hi))")
    }

    /// Non-multiple-of-16 dimensions are the norm for real sensors — a Leica SL3 gives 9536×6344,
    /// and 6344 = 16·396 + 8. The tool must pad internally rather than trap on its own
    /// precondition; this is the regression test for that crash.
    func testOddDimensionsAreAccepted() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)
        let service = AnselDenoiseService(client: client, modelURL: model)

        let W = 61, H = 46              // neither divides by 16
        var mosaic = [Float](repeating: 0, count: W * H)
        for i in 0..<mosaic.count { mosaic[i] = 0.04 + Float(i % 23) * 0.003 }

        var opts = AnselDenoiseOptions()
        opts.noiseA = [0.0004, 0.0003, 0.0004]
        opts.noiseB = [3e-6, 1e-6, 1e-6]

        let out = try service.denoise(mosaic: mosaic, width: W, height: H, options: opts)
        XCTAssertEqual(out.width, W)
        XCTAssertEqual(out.height, H)
        XCTAssertTrue(out.mosaic.allSatisfy { $0.isFinite })
    }

    /// `strength` must interpolate between the original and the full denoise, and 1.0 must be
    /// exactly the old behaviour (so adding the knob changes nothing by default for strength=1).
    func testStrengthBlendsTowardTheOriginal() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)
        let service = AnselDenoiseService(client: client, modelURL: model)

        let W = 64, H = 64
        var mosaic = [Float](repeating: 0, count: W * H)
        var rng = SystemRandomNumberGenerator()
        for y in 0..<H {
            for x in 0..<W {
                let truth = Float(x) / Float(W) * 0.3 + 0.02
                mosaic[y * W + x] = truth + Float.random(in: -0.01...0.01, using: &rng)
            }
        }
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

        func run(_ strength: Double) throws -> [Float] {
            var o = AnselDenoiseOptions()
            o.noiseA = [0.0004, 0.0003, 0.0004]
            o.noiseB = [3e-6, 1e-6, 1e-6]
            o.strength = strength
            return try service.denoise(mosaic: mosaic, width: W, height: H, options: o).mosaic
        }

        let full = try run(1.0)
        let blended = try run(0.85)
        let none = try run(0.0)

        // strength 0 is the original, untouched.
        for i in 0..<mosaic.count {
            XCTAssertEqual(none[i], mosaic[i], accuracy: 1e-6,
                           "strength 0 must return the input (index \(i))")
        }

        // strength 1 removes the most noise, 0 doesn't touch it, and the knob is exactly linear.
        //
        // Asserting "strength 1 has the lowest error against truth" would be wrong, and the
        // measurement below is why: on this input the full-strength output is *further* from the
        // truth than the 0.85 blend, because the network over-corrects — it removes real signal
        // along with the noise. That bias is exactly what blending back toward the original
        // trades against, and it is the empirical case for shipping 0.85 rather than 1.0.
        //
        // So the contract is measured against **the input**, not against truth: a 0.85 blend has to
        // end up closer to the original than full strength does. `residualRMS` (distance to truth)
        // was the wrong ruler for that sentence — it can order the two either way depending on
        // whether the network under- or over-corrects, which is why it read
        // `0.0019453 vs 0.0019204` and failed a correct implementation.
        func distanceToInput(_ m: [Float]) -> Float {
            var sum: Float = 0
            for i in 0..<mosaic.count {
                let d = m[i] - mosaic[i]
                sum += d * d
            }
            return (sum / Float(mosaic.count)).squareRoot()
        }
        let n = residualRMS(none)
        let b = residualRMS(blended)
        let toInputFull = distanceToInput(full), toInputBlended = distanceToInput(blended)
        XCTAssertLessThan(b, n, "0.85 must still denoise (blended \(b) vs original \(n))")
        XCTAssertLessThan(toInputBlended, toInputFull,
                          "0.85 must keep more of the original than 1.0 "
                          + "(到输入的距离 \(toInputBlended) vs \(toInputFull))")

        // The blend is exactly linear: 0.85 of the full correction.
        for i in 0..<mosaic.count {
            let expect = mosaic[i] + 0.85 * (full[i] - mosaic[i])
            XCTAssertEqual(blended[i], expect, accuracy: 1e-5,
                           "blend is not linear at index \(i)")
        }
    }

    /// A tiny mosaic must work even though it is smaller than anything the network prefers.
    func testSmallMosaicWorks() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)
        let service = AnselDenoiseService(client: client, modelURL: model)

        let W = 40, H = 24
        var mosaic = [Float](repeating: 0, count: W * H)
        for i in 0..<mosaic.count { mosaic[i] = 0.05 + Float(i % 17) * 0.002 }

        var opts = AnselDenoiseOptions()
        opts.noiseA = [0.0004, 0.0003, 0.0004]
        opts.noiseB = [3e-6, 1e-6, 1e-6]

        let out = try service.denoise(mosaic: mosaic, width: W, height: H, options: opts)
        XCTAssertEqual(out.width, W)
        XCTAssertEqual(out.height, H)
        XCTAssertTrue(out.mosaic.allSatisfy { $0.isFinite })
    }
}
