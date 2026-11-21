import XCTest
@testable import PhotonsExtensions

/// 485 — the extracted pure calculation. §480 tested the DNG writer end to end; this suite is the
/// other half: `clean` reads and returns planes without creating a file, and `cleanPlanes` is the
/// deterministic function the edit-time cache stores.
final class BuiltinDenoiseClean485Tests: XCTestCase {

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    private func makeCrop(_ side: Int) throws -> URL {
        let doc = try SourceDNG(url: Self.fixtureURL)
        let data = try Data(contentsOf: Self.fixtureURL, options: .alwaysMapped)
        let full = try doc.readMosaic(data: data)
        let n = min(side, min(full.width, full.height))
        var crop = [UInt16](repeating: 0, count: n * n)
        for y in 0..<n {
            for x in 0..<n { crop[y * n + x] = full.samples[y * full.width + x] }
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtin485-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("src.dng")
        _ = try DNGRawWriter.write(samples: crop, width: n, height: n,
                                   from: Self.fixtureURL, to: url)
        return url
    }

    private func highPassSigma(_ samples: [UInt16], width: Int, height: Int) -> Double {
        var sum = 0.0
        var n = 0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
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

    func testCleanReturnsPlanesAndWritesNothingNextToTheSource() throws {
        let source = try makeCrop(128)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let directory = source.deletingLastPathComponent()
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)

        let clean = try BuiltinDenoiseJob(options: BuiltinDenoiseJob.Options(amount: 100))
            .clean(input: source)

        XCTAssertEqual(clean.width, 128)
        XCTAssertEqual(clean.height, 128)
        XCTAssertEqual(clean.planes.count, 4)
        XCTAssertEqual(clean.planes[0].count, 64 * 64)
        XCTAssertEqual(clean.samples.count, 128 * 128)
        XCTAssertGreaterThan(clean.tiles, 0)
        let after = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(before, after, "clean 不允许写任何文件")
    }

    func testCleanPlanesIsDeterministicAndReducesNoise() throws {
        let side = 64
        let black: Float = 0.2
        var planes = [[Float]](repeating: [Float](repeating: 0, count: side * side), count: 4)
        var state: UInt64 = 0x9e37_79b9_7f4a_7c15
        func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24) - 0.5
        }
        for c in 0..<4 {
            for i in 0..<(side * side) {
                // A noisy flat field: the only structure NLM may remove is the noise.
                planes[c][i] = min(max(black + Float(c) * 0.05 + next() * 0.04, 0), 1)
            }
        }
        let options = BuiltinDenoiseJob.Options(amount: 100)
        let first = BuiltinDenoiseJob.cleanPlanes(planes: planes, width: side, height: side,
                                                  options: options)
        let second = BuiltinDenoiseJob.cleanPlanes(planes: planes, width: side, height: side,
                                                   options: options)
        XCTAssertEqual(first.planes, second.planes, "同一输入必须逐样本一致")
        XCTAssertEqual(first.tiles, second.tiles)

        func sigma(_ p: [Float]) -> Double {
            let n = side
            var sum = 0.0
            var count = 0
            for y in 1..<(n - 1) {
                for x in 1..<(n - 1) {
                    let r = p[y * n + x] - (p[y * n + x - 1] + p[y * n + x + 1]
                                            + p[(y - 1) * n + x] + p[(y + 1) * n + x]) / 4
                    sum += Double(r * r)
                    count += 1
                }
            }
            return (sum / Double(max(count, 1))).squareRoot()
        }
        let before = sigma(planes[0])
        let after = sigma(first.planes[0])
        print("485 cleanPlanes: sigma \(before) -> \(after), \(first.tiles) tiles")
        XCTAssertLessThan(after, before * 0.8, "NLM 应当压低平坦区的噪声")
    }
}
