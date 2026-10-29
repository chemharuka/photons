import XCTest
import Foundation
import PhotonsCore

/// 133 — `photonsctl render --tone-map`. The flag and the golden bookkeeping live in the
/// executable target (not importable from a test), so the CLI half is exercised as a process and
/// the pixel half is the exact `displaySDR` call the CLI makes.
final class RenderCLIToneMapTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // RenderCLIToneMapTests.swift
        .deletingLastPathComponent()   // PhotonsExportTests
        .deletingLastPathComponent()   // Tests

    private static var binary: URL? {
        let url = repoRoot.appendingPathComponent(".build/debug/photonsctl")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func runCLI(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        guard let binary = Self.binary else {
            throw XCTSkip("photonsctl is not built at .build/debug/photonsctl")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, stdout, stderr)
    }

    /// The switch must never be silently ignored: a wrong spelling is a hard error, matching the
    /// harness's stance on `--wb`.
    func testUnknownToneMapIsRejected() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-133-\(UUID().uuidString).dng")
        XCTAssertTrue(FileManager.default.createFile(atPath: raw.path, contents: Data([0])))
        defer { try? FileManager.default.removeItem(at: raw) }
        let result = try runCLI(["render", raw.path, "--out", raw.path + ".png",
                                 "--tone-map", "reinhard"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("bad --tone-map"), result.stderr)
    }

    /// `-R` only exists inside a tone map; asking for it on the hard-clamp path is a mistake, not a
    /// no-op.
    func testHeadroomNeedsGlobal() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-133-\(UUID().uuidString).dng")
        XCTAssertTrue(FileManager.default.createFile(atPath: raw.path, contents: Data([0])))
        defer { try? FileManager.default.removeItem(at: raw) }
        let result = try runCLI(["render", raw.path, "--out", raw.path + ".png",
                                 "--tone-map-headroom", "2"])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("needs --tone-map global"), result.stderr)
    }

    func testUsageDocumentsTheSwitch() throws {
        let result = try runCLI([])
        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stdout.contains("--tone-map"), result.stdout)
        XCTAssertTrue(result.stdout.contains("--tone-map-headroom"), result.stdout)
    }

    /// The default (`nil`) stays the historical hard clamp; `.global` on a frame that is already
    /// SDR must produce the same bytes, so ordinary documents do not move.
    func testGlobalToneMapLeavesAnSDRFrameByteIdentical() {
        let w = 64, h = 4
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = Float16(0.8 * Float(i) / Float(w * h - 1))
            rgba[i * 4] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
            rgba[i * 4 + 3] = 1
        }
        let linear = LinearPixels(width: w, height: h, rgba: rgba, primaries: .sRGB)
        let hard = linear.displaySDR(bitDepth: 8)
        let global = linear.displaySDR(bitDepth: 8, toneMap: .global)
        XCTAssertEqual(hard.rgba.map { $0.bitPattern }, global.rgba.map { $0.bitPattern })
    }

    /// Both `CIToneMapHeadroom` inputs reach the pixels: two renders of the same input are stable,
    /// and changing `-R` changes the result instead of being dropped by the CLI.
    func testHeadroomIsPassedThroughAndDeterministic() throws {
        if #unavailable(macOS 15.0) {
            throw XCTSkip("CIToneMapHeadroom is macOS 15+")
        }
        let w = 256, h = 8
        var rgba = [Float16](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let v = Float16(4 * Float(i) / Float(w * h - 1))
            rgba[i * 4] = v
            rgba[i * 4 + 1] = v
            rgba[i * 4 + 2] = v
            rgba[i * 4 + 3] = 1
        }
        let linear = LinearPixels(width: w, height: h, rgba: rgba, primaries: .sRGB)
        let a = linear.displaySDR(bitDepth: 8, toneMap: SDRToneMap(maxHeadroom: 1.5))
        let b = linear.displaySDR(bitDepth: 8, toneMap: SDRToneMap(maxHeadroom: 1.5))
        let c = linear.displaySDR(bitDepth: 8, toneMap: .global)
        XCTAssertEqual(a.sha256(), b.sha256(), "same parameters must hash the same")
        XCTAssertNotEqual(a.sha256(), c.sha256(),
                          "headroom must reach CIToneMapHeadroom, not be ignored")
    }
}
