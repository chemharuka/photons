import XCTest
import Foundation
@testable import PhotonsExtensions

/// End-to-end tests for the GPL tool boundary.
///
/// These need the `ansel-denoise-swift` executable and a `.anselnn` model. Point at them with
/// `ANSEL_DENOISE_SWIFT` / `ANSEL_DENOISE_MODEL`; without them the suite skips rather than fails,
/// because the tool is an optional extension (the app has to launch on a machine that lacks it).
///
/// §390 — two paths are covered here and they must stay distinguishable:
///
///   · **DNG in / DNG out** (`denoiseImage(model:input:output:)`) — the one the app uses. Nothing
///     about the pixels crosses the process boundary; the tool reads the file and writes a file.
///   · **the float32 mosaic path** (`denoiseImage(model:input:width:height:output:)`) — still
///     public, still tested, but no longer called by `AnselDenoiseJob`. `AnselDenoiseService`
///     (the host-side f32 driver) is gone, so these tests drive the client directly: the thing
///     under test is the argument list and the report, which is exactly what a wrapper added.
final class AnselDenoiseClientTests: XCTestCase {

    static var toolURL: URL? {
        if let p = ProcessInfo.processInfo.environment["ANSEL_DENOISE_SWIFT"],
           FileManager.default.isExecutableFile(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        for c in ["/tmp/ansel-img/release/ansel-denoise-swift",
                  "/Users/luyao/Documents/GitHub/ansel-denoise-swift/.build/release/ansel-denoise-swift",
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

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise-client390-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - protocol

    func testProtocolVersionIsReported() throws {
        guard let tool = Self.toolURL else { throw XCTSkip("ansel-denoise-swift not present") }
        let client = AnselDenoiseClient(executableURL: tool)
        let version = try client.protocolVersion()
        print("§390 protocol = \(version)")
        XCTAssertGreaterThanOrEqual(version, 1)
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

    /// The gate `AnselDenoiseJob` leans on: a tool that cannot do DNG-in/DNG-out must say so instead
    /// of being handed a float32 argument list it would misread.
    func testSupportsDNGIsReportedByTheShippedTool() throws {
        guard let tool = Self.toolURL else { throw XCTSkip("ansel-denoise-swift not present") }
        let client = AnselDenoiseClient(executableURL: tool)
        let supported = try client.supportsDNG()
        print("§390 supportsDNG = \(supported) (\(tool.path))")
        XCTAssertTrue(supported, "\(tool.path) 缺少 image-dng 能力，宿主已无处可退")
    }

    // MARK: - §390 ⑤ DNG in / DNG out

    /// ⑤ — the 1024² fixture through the real tool: same geometry, CFA from the file, backend GPU.
    func testDNGInDNGOutOnTheSmallFixture() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)
        let output = workDir.appendingPathComponent("small-out.dng")
        var options = AnselDenoiseOptions()
        options.noiseA = [0.0004, 0.0003, 0.0004]
        options.noiseB = [3e-6, 1e-6, 1e-6]

        let started = Date()
        let report = try client.denoiseImage(model: model, input: Self.fixtureURL,
                                             output: output, options: options)
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "§390 ⑤ 1024²：%.2f s 总 · 工具 %.3f s（读 %.4f · 推 %.4f · 写 %.4f）"
                     + " · %d×%d cfa=%@/%@ · %d piece %d×%d %d seam · %d bytes · backend=%@",
                     elapsed, report.seconds, report.readSeconds, report.inferenceSeconds,
                     report.writeSeconds, report.width, report.height, report.cfa, report.mosaicCfa,
                     report.pieces, report.columns, report.rows, report.seams,
                     report.outputBytes, report.backend))

        XCTAssertEqual(report.width, 1024)
        XCTAssertEqual(report.height, 1024)
        XCTAssertEqual(report.cfa.lowercased(), "rggb")
        XCTAssertEqual(report.mosaicCfa.lowercased(), "rggb")
        XCTAssertEqual(report.backend, "gpu", "⑦ --gpu 必须透传；cpu 意味着 60 MP 会跑 7 分钟")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        // The product must still be a CFA DNG this app can read, with the source's own levels.
        let productData = try Data(contentsOf: output, options: .alwaysMapped)
        let product = try SourceDNG(data: productData)
        let mosaic = try product.readMosaic(data: productData)
        XCTAssertEqual(mosaic.width, 1024)
        XCTAssertEqual(mosaic.height, 1024)
        XCTAssertEqual(product.ifd0[262]?.firstUInt32, 32803, "仍是 CFA 图")
        XCTAssertEqual(product.ifd0[259]?.firstUInt32, 7, "SOF3 压缩")

        let source = try SourceDNG(data: try Data(contentsOf: Self.fixtureURL, options: .alwaysMapped))
        XCTAssertEqual(product.ifd0[50717]?.firstUInt32, source.ifd0[50717]?.firstUInt32,
                       "白电平必须是原文件自己的")
        XCTAssertEqual(product.ifd0[33422]?.value, source.ifd0[33422]?.value,
                       "CFA 相位必须与原文件一致（差一位就是棋盘格）")
    }

    /// ④ with the **real** tool: a truncated DNG is refused by the tool, and the job leaves neither a
    /// `-denoised.dng` nor a `.denoise-*.dng` behind. This is the gate the temp-name-then-rename
    /// arrangement exists for.
    func testATruncatedDNGLeavesNoProductAndNoTempFile() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let dir = workDir.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let broken = dir.appendingPathComponent("BROKEN.dng")
        try Data([0x49, 0x49, 0x2a, 0x00, 0x08]).write(to: broken)

        let job = AnselDenoiseJob(location: AnselDenoiseLocation(executableURL: tool, modelURL: model))
        var message = ""
        XCTAssertThrowsError(try job.run(source: broken)) { error in
            message = (error as? AnselDenoiseJobError)?.description ?? "\(error)"
        }
        print("§390 ④ 真工具 + 截断 DNG ⇒ \(message)")
        XCTAssertTrue(message.contains("解码 RAW 失败"), "④ 要中文原因，实际：\(message)")

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0 != "BROKEN.dng" }
        print("§390 ④ 目录里剩下的：\(leftovers)")
        XCTAssertTrue(leftovers.isEmpty,
                      "④ 失败后不许留下产物或临时文件，实际 \(leftovers)")
    }

    // MARK: - float32 mosaic path (still public, no longer used by the job)

    /// The whole point of the f32 entry point: mosaic in, denoised mosaic out, same size, smoother.
    func testDenoiseActuallyReducesNoise() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)

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

        let out = try runFloat32(client: client, model: model, mosaic: mosaic, width: W, height: H,
                                 options: noiseOptions())

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
        print(String(format: "f32 路径：残差 RMS %.6f → %.6f（比值 %.3f）",
                     before, after, after / before))
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

        // Left half pure black (clipped), right half a gradient: the situation that produced
        // negatives at the frame edge.
        let W = 256, H = 128
        var mosaic = [Float](repeating: 0, count: W * H)
        for y in 0..<H {
            for x in 0..<W where x >= W / 2 {
                mosaic[y * W + x] = Float(x - W / 2) / Float(W / 2) * 0.5
            }
        }
        var opts = noiseOptions()
        opts.strength = 1.0                     // no blending to hide an overshoot

        let out = try runFloat32(client: client, model: model, mosaic: mosaic, width: W, height: H,
                                 options: opts)
        let lo = out.mosaic.min() ?? 0
        let hi = out.mosaic.max() ?? 0
        print("f32 路径 · 裁黑边缘：范围 [\(lo), \(hi)]")
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

        let W = 61, H = 46              // neither divides by 16
        var mosaic = [Float](repeating: 0, count: W * H)
        for i in 0..<mosaic.count { mosaic[i] = 0.04 + Float(i % 23) * 0.003 }

        let out = try runFloat32(client: client, model: model, mosaic: mosaic, width: W, height: H,
                                 options: noiseOptions())
        XCTAssertEqual(out.width, W)
        XCTAssertEqual(out.height, H)
        XCTAssertTrue(out.mosaic.allSatisfy { $0.isFinite })
    }

    /// `strength` must interpolate between the original and the full denoise, and 1.0 must be
    /// exactly the old behaviour (so adding the knob changes nothing by default for strength=1).
    ///
    /// §390 note: the blend itself now lives in the tool (`AnselDenoiseImage.swift`); what this
    /// test pins is that the **knob still reaches it** over the pipe, which is the only part this
    /// side owns. It is the one test here that cannot be written against the DNG path — a DNG
    /// carries quantized samples, so "the blend is exactly linear" is only measurable in float32.
    func testStrengthBlendsTowardTheOriginal() throws {
        guard let tool = Self.toolURL, let model = Self.modelURL else {
            throw XCTSkip("needs ansel-denoise-swift + a .anselnn model")
        }
        let client = AnselDenoiseClient(executableURL: tool)

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
            var o = noiseOptions()
            o.strength = strength
            return try runFloat32(client: client, model: model, mosaic: mosaic, width: W, height: H,
                                  options: o).mosaic
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
        print(String(format: "strength 语义：残差 0=%.6f 0.85=%.6f · 到输入 1.0=%.6f 0.85=%.6f",
                     n, b, toInputFull, toInputBlended))
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

        let W = 40, H = 24
        var mosaic = [Float](repeating: 0, count: W * H)
        for i in 0..<mosaic.count { mosaic[i] = 0.05 + Float(i % 17) * 0.002 }

        let out = try runFloat32(client: client, model: model, mosaic: mosaic, width: W, height: H,
                                 options: noiseOptions())
        XCTAssertEqual(out.width, W)
        XCTAssertEqual(out.height, H)
        XCTAssertTrue(out.mosaic.allSatisfy { $0.isFinite })
    }

    // MARK: - helpers

    private func noiseOptions() -> AnselDenoiseOptions {
        var o = AnselDenoiseOptions()
        o.noiseA = [0.0004, 0.0003, 0.0004]
        o.noiseB = [3e-6, 1e-6, 1e-6]
        return o
    }

    /// What `AnselDenoiseService` used to do: write the f32 buffer, call the client, read it back.
    /// Inlined here so the deleted wrapper's replacement is a test-local thing, not new production
    /// code.
    private func runFloat32(client: AnselDenoiseClient,
                            model: URL,
                            mosaic: [Float],
                            width: Int,
                            height: Int,
                            options: AnselDenoiseOptions) throws -> (mosaic: [Float],
                                                                     width: Int,
                                                                     height: Int,
                                                                     pieces: Int,
                                                                     seams: Int) {
        let dir = workDir.appendingPathComponent("f32-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("mosaic.f32")
        let output = dir.appendingPathComponent("denoised.f32")
        try mosaic.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: input)

        let report = try client.denoiseImage(model: model, input: input,
                                             width: width, height: height,
                                             output: output, options: options)
        let data = try Data(contentsOf: output, options: .mappedIfSafe)
        XCTAssertEqual(data.count, width * height * MemoryLayout<Float>.size,
                       "tool returned \(data.count) bytes for \(width)×\(height)")
        var result = [Float](repeating: 0, count: width * height)
        result.withUnsafeMutableBytes { data.copyToBytes(to: $0) }
        return (result, width, height, report.pieces, report.seams)
    }
}

private extension Data {
    func copyToBytes(to buffer: UnsafeMutableRawBufferPointer) {
        _ = buffer.copyBytes(from: self)
    }
}
