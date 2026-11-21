import XCTest
@testable import PhotonsExtensions

/// §480 acceptance helper — runs the shipped NLMF engine once so the same highlight/texture metric
/// can be applied to it. Skipped unless `PHOTONS_480_NLMF=1`, because it is a GPU measurement, not a
/// unit test. It is deliberately in the test target: `NLMFDenoiseJob` already lives here.
final class NLMFDenoiseMeasurement480Tests: XCTestCase {

    func testRunNLMFForTheAcceptanceComparison() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PHOTONS_480_NLMF"] == "1", "acceptance-only GPU measurement")
        let inputPath = env["PHOTONS_TEST_RAW"] ?? ""
        let outputPath = env["PHOTONS_480_OUT"] ?? ""
        try XCTSkipIf(inputPath.isEmpty || outputPath.isEmpty,
                      "set PHOTONS_TEST_RAW and PHOTONS_480_OUT")
        let input = URL(fileURLWithPath: inputPath)
        let output = URL(fileURLWithPath: outputPath)
        let model = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsExtensions/Denoise/Models/v_matmul_256.mlpackage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.path), "模型不在 \(model.path)")
        let job = NLMFDenoiseJob(modelURL: model)
        let started = Date()
        let report = try job.denoise(input: input, output: output)
        print("480 NLMF \(input.lastPathComponent) \(report.width)×\(report.height) "
              + "tiles=\(report.tiles) seconds=\(String(format: "%.2f", Date().timeIntervalSince(started))) "
              + "bytes=\(report.outputBytes)")
    }
}
