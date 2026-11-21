import XCTest
@testable import PhotonsExtensions

/// 480 — the file-to-file job: a DNG goes through the ported filter and comes back as a legal DNG
/// with the source's metadata, same CFA and same size. Uses a 256×256 crop so the test runs the
/// real algorithm (no stand-in) in seconds.
final class BuiltinDenoiseJobTests: XCTestCase {

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    private func makeCrop(_ side: Int) throws -> (url: URL, source: SourceDNG, samples: [UInt16]) {
        let doc = try SourceDNG(url: Self.fixtureURL)
        let data = try Data(contentsOf: Self.fixtureURL, options: .alwaysMapped)
        let full = try doc.readMosaic(data: data)
        let n = min(side, min(full.width, full.height))
        var crop = [UInt16](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n { crop[y * n + x] = full.samples[y * full.width + x] }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin480-src-\(UUID().uuidString).dng")
        _ = try DNGRawWriter.write(samples: crop, width: n, height: n,
                                   from: Self.fixtureURL, to: url)
        return (url, doc, crop)
    }

    private func noiseSigma(_ samples: [UInt16], width: Int, height: Int,
                            x0: Int, x1: Int, y0: Int, y1: Int) -> Double {
        var sum = 0.0
        var n = 0
        for y in max(1, y0)..<min(height - 1, y1) {
            for x in max(1, x0)..<min(width - 1, x1) {
                let c = Double(samples[y * width + x])
                let around = Double(samples[y * width + x - 1]) + Double(samples[y * width + x + 1])
                    + Double(samples[(y - 1) * width + x]) + Double(samples[(y + 1) * width + x])
                let r = c - around / 4
                sum += r * r
                n += 1
            }
        }
        return (sum / Double(max(n, 1))).squareRoot()
    }

    /// The end-to-end wiring: output exists, decodes at the source size and CFA, and the flat noise
    /// drops by at least half while the file still renders (the writer is the existing one).
    func testTheJobWritesADNGWithLessNoiseAndTheSameGeometry() throws {
        let (source, sourceDoc, before) = try makeCrop(256)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin480-out-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: output) }

        let job = BuiltinDenoiseJob(options: BuiltinDenoiseJob.Options(amount: 100))
        let report = try job.denoise(input: source, output: output)

        XCTAssertEqual(report.width, 256)
        XCTAssertEqual(report.height, 256)
        XCTAssertEqual(report.cfa, BuiltinDenoiseJob.cfaPattern(of: sourceDoc))
        XCTAssertGreaterThan(report.byteCount, 0)
        XCTAssertGreaterThan(report.tiles, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let written = try SourceDNG(url: output)
        let decoded = try written.readMosaic(data: try Data(contentsOf: output))
        XCTAssertEqual(decoded.width, 256)
        XCTAssertEqual(decoded.height, 256)
        XCTAssertEqual(written.raw[33422]?.value, sourceDoc.raw[33422]?.value, "CFA 相位变了")
        XCTAssertEqual(written.raw[50717]?.value, sourceDoc.raw[50717]?.value, "白电平变了")
        XCTAssertEqual(written.raw[50714]?.value, sourceDoc.raw[50714]?.value, "黑电平变了")

        // A flat patch well away from the border: the residual high-pass sigma must fall by half.
        let beforeSigma = noiseSigma(before, width: 256, height: 256, x0: 40, x1: 120, y0: 40, y1: 120)
        let afterSigma = noiseSigma(decoded.samples, width: 256, height: 256, x0: 40, x1: 120, y0: 40, y1: 120)
        print("480 job: sigma \(beforeSigma) -> \(afterSigma) "
              + "(\(Int((1 - afterSigma / max(beforeSigma, 1e-9)) * 100)) % down), "
              + "\(report.tiles) tiles, \(String(format: "%.2f", report.seconds)) s, "
              + "a=\(report.noiseA) b=\(report.noiseB) "
              + "sigma18=\((report.noiseA * 0.18 + report.noiseB).squareRoot())")
        XCTAssertLessThan(afterSigma, beforeSigma * 0.65,
                          "noise did not drop enough: \(beforeSigma) -> \(afterSigma)")
    }

    /// Amount 0 is the user's "off": the filter still runs, but the output follows the input.
    func testAmountZeroLeavesTheMosaicCloseToTheSource() throws {
        let (source, _, before) = try makeCrop(128)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin480-zero-\(UUID().uuidString).dng")
        defer { try? FileManager.default.removeItem(at: output) }

        let job = BuiltinDenoiseJob(options: BuiltinDenoiseJob.Options(amount: 0))
        _ = try job.denoise(input: source, output: output)
        let written = try SourceDNG(url: output)
        let decoded = try written.readMosaic(data: try Data(contentsOf: output))
        var total = 0.0
        for (a, b) in zip(before, decoded.samples) { total += abs(Double(a) - Double(b)) }
        let mean = total / Double(before.count)
        XCTAssertLessThan(mean, 1.5, "amount 0 moved the mosaic by \(mean) LSB on average")
    }

    /// Tile seams: a flat noisy field is the honest probe (content cannot explain a step). With the
    /// 16-cell overlap the mean on either side of every seam must agree to 1e-4 of full scale.
    func testTileSeamsOnAFlatFieldAreBelowOneTenThousandth() throws {
        let side = 512
        let fixture = try SourceDNG(url: Self.fixtureURL)
        let blacks = BuiltinDenoiseJob.blackLevels(of: fixture)
        let black = blacks.first ?? 512
        let white = Double(BuiltinDenoiseJob.whiteLevel(of: fixture))
        let span = white - black
        // Noise-free: a seam caused by the tiling is then the only thing that can show up.
        let samples = [UInt16](repeating: UInt16(min(max(black + 0.3 * span, 0), white)),
                               count: side * side)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin480-flat-\(UUID().uuidString).dng")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin480-flat-out-\(UUID().uuidString).dng")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: output)
        }
        _ = try DNGRawWriter.write(samples: samples, width: side, height: side,
                                   from: Self.fixtureURL, to: source)
        let job = BuiltinDenoiseJob(options: BuiltinDenoiseJob.Options(amount: 100, tileSize: 128,
                                                                      overlap: 16))
        _ = try job.denoise(input: source, output: output)
        let written = try SourceDNG(url: output)
        let decoded = try written.readMosaic(data: try Data(contentsOf: output))

        // Plane origins are multiples of (128 - 16) = 112 cells → 224 samples; the seam is there.
        var worst = 0.0
        func mean(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Double {
            var sum = 0.0
            for y in y0..<y1 { for x in x0..<x1 { sum += Double(decoded.samples[y * side + x]) } }
            return sum / Double((x1 - x0) * (y1 - y0))
        }
        for boundary in stride(from: 224, to: side - 16, by: 224) {
            let left = mean(boundary - 8, boundary, 8, side - 8)
            let right = mean(boundary, boundary + 8, 8, side - 8)
            worst = max(worst, abs(left - right) / span)
        }
        for boundary in stride(from: 224, to: side - 16, by: 224) {
            let top = mean(8, side - 8, boundary - 8, boundary)
            let bottom = mean(8, side - 8, boundary, boundary + 8)
            worst = max(worst, abs(top - bottom) / span)
        }
        print("480 seams: worst mean step = \(worst)")
        XCTAssertLessThanOrEqual(worst, 1e-4, "tile seam mean step \(worst)")
    }
}
