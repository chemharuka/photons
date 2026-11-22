import XCTest
import Foundation
@testable import PhotonsExtensions

/// 495 — how long does the built-in NLM take on a **screen-canvas-sized** buffer?
///
/// 485 measured the full frame (60 MP ≈ 11–18 s on this machine). The real-time preview proposal is
/// "clean the canvas-sized buffer first, cache the full frame afterwards", so the number that decides
/// whether that is viable is the cost at 4.1 Mpx, not at 60 Mpx. This is a measurement, not a test of
/// the algorithm: it is skipped unless `PHOTONS_BENCH=1`.
///
/// Fixture: `~/Desktop/test/L1030433.dng` (Leica SL3), 9520×6336 = 60.3 MP. Note that §495's text
/// calls it 12.2 MP / 4284×2851 — that is not this file. Because an integer box downsample cannot hit
/// 2560×1600 exactly from 9520×6336, each tier downsamples first (2× for A, 4× for B, none for C) and
/// then takes a centre crop to the exact target. A box average and a crop mix no colours, so the CFA
/// phase is preserved, which is what "预览尺寸" must mean.
///
/// Two forms per tier, because a canvas has no usable Bayer phase:
///   * CFA — four planes, through `DenoiseNLMBackend.cleanDNG` (the 485 DNG path).
///   * RGB — three planes, through `DenoiseNLMBackend.cleanRGB` (the 485 non-DNG path).
/// The RGB buffer is the CFA planes replicated 2×2 and combined into R / G / B. Replication is exactly
/// what a canvas made by re-rendering the mosaic at half resolution *cannot* do (it has no phase), but
/// it keeps the pixel count honest: 4.1 Mpx of canvas is 1280×800 CFA cells and 2560×1600 RGB pixels.
///
/// Env:
///   `PHOTONS_BENCH=1`            required
///   `PHOTONS_495_RAW=<dng>`      optional fixture override
///   `PHOTONS_495_TIERS=A,B,C`    optional subset (for a quick smoke run)
///   `PHOTONS_495_RUNS=3`         optional; the deliverable uses 3 (median)
final class DenoisePreviewCost495Tests: XCTestCase {

    private struct Tier {
        let name: String
        /// Box-downsample factor applied to each CFA plane before the centre crop.
        let factor: Int
        /// Final canvas size in display pixels (what a slider would render).
        let width: Int
        let height: Int
    }

    private let tiers: [Tier] = [
        Tier(name: "A", factor: 2, width: 2560, height: 1600),
        Tier(name: "B", factor: 4, width: 1810, height: 1132),
        // C is the full frame; its exact size is filled in from the decoded mosaic below.
        Tier(name: "C", factor: 1, width: 0, height: 0),
    ]

    private struct Measurement {
        let wall: Double
        let reported: Double
        let a: Float
        let b: Float
        let tiles: Int
    }

    func testCanvasSizedCleaningCost() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["PHOTONS_BENCH"] == "1",
                          "measurement only; set PHOTONS_BENCH=1")
        let rawPath = env["PHOTONS_495_RAW"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Desktop/test/L1030433.dng")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: rawPath),
                          "fixture not found: \(rawPath)")
        let runs = max(1, Int(env["PHOTONS_495_RUNS"] ?? "3") ?? 3)
        let wanted = Set((env["PHOTONS_495_TIERS"] ?? "A,B,C")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() })

        let source = URL(fileURLWithPath: rawPath)
        let data = try Data(contentsOf: source, options: .alwaysMapped)
        let doc = try SourceDNG(data: data)
        let mosaic = try doc.readMosaic(data: data)
        let cfa = BuiltinDenoiseJob.cfaPattern(of: doc) ?? "rggb"
        let channel = BuiltinDenoiseJob.channelIndex(cfa: cfa)
        let blacks = BuiltinDenoiseJob.blackLevels(of: doc)
        let white = BuiltinDenoiseJob.whiteLevel(of: doc)
        let pw = mosaic.width / 2
        let ph = mosaic.height / 2
        let tuning = BuiltinDenoise.Tuning()
        print("495 fixture \(source.lastPathComponent) \(mosaic.width)×\(mosaic.height) "
              + "cfa=\(cfa) white=\(white) blacks=\(blacks) planes=\(pw)×\(ph)")
        print("495 tuning search=\(tuning.search)/\(tuning.search2)/\(tuning.searchC) "
              + "half=\(tuning.half)/\(tuning.half2) runs=\(runs)")
        print("495 note: spec says 4284×2851 / 12.2 MP; this file decodes to "
              + "\(mosaic.width)×\(mosaic.height) (\(String(format: "%.2f", Double(mosaic.width * mosaic.height) / 1_000_000)) MP)")

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cost495-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Header is tab-separated so the report table is a copy-paste, not a re-derivation.
        print("495 table\ttier\tform\tdisplay\tmpx\tsigma0\ta\tb\tradius\ttiles\tmedian_ms\tms_per_mpx\treported_s")

        for var tier in tiers {
            guard wanted.contains(tier.name) else { continue }
            if tier.name == "C" {
                tier = Tier(name: tier.name, factor: 1, width: mosaic.width, height: mosaic.height)
            }
            let planeW = tier.width / 2
            let planeH = tier.height / 2
            let downW = pw / tier.factor
            let downH = ph / tier.factor
            guard downW >= planeW, downH >= planeH else {
                XCTFail("tier \(tier.name): \(downW)×\(downH) is smaller than \(planeW)×\(planeH)")
                continue
            }
            let cropX = (downW - planeW) / 2
            let cropY = (downH - planeH) / 2

            let built = try planes(from: mosaic, width: mosaic.width, cfa: cfa,
                                   channel: channel, blacks: blacks, white: white,
                                   factor: tier.factor, cropX: cropX, cropY: cropY,
                                   planeW: planeW, planeH: planeH, raw: tier.name != "C")
            let mpx = Double(tier.width * tier.height) / 1_000_000

            // CFA — the 485 DNG path. A/B go through a temp DNG written from the cropped mosaic, so
            // `cleanDNG` is the same door the app uses; C reads the original file.
            let cfaInput: URL
            if tier.name == "C" {
                cfaInput = source
            } else {
                cfaInput = workDir.appendingPathComponent("tier-\(tier.name).dng")
                _ = try DNGRawWriter.write(samples: built.raw!, width: tier.width, height: tier.height,
                                           from: source, to: cfaInput)
            }
            let cfaRuns = try measure(runs: runs) {
                let started = Date()
                let clean = try DenoiseNLMBackend.cleanDNG(input: cfaInput)
                return Measurement(wall: Date().timeIntervalSince(started), reported: clean.seconds,
                                   a: clean.noiseA, b: clean.noiseB, tiles: clean.tiles)
            }
            printRow(tier: tier, form: "CFA", mpx: mpx, runs: cfaRuns, tuning: tuning)

            // RGB — the 485 non-DNG path. The canvas buffer has no CFA phase; this is the only form a
            // re-rendered preview can hand to the filter.
            let rgb = makeRGB(planes: built.planes, channel: channel, planeW: planeW, planeH: planeH)
            let rgbRuns = try measure(runs: runs) {
                let started = Date()
                let result = DenoiseNLMBackend.cleanRGB(rgb, width: tier.width, height: tier.height)
                return Measurement(wall: Date().timeIntervalSince(started), reported: result.seconds,
                                   a: result.noiseA, b: result.noiseB, tiles: result.tiles)
            }
            printRow(tier: tier, form: "RGB", mpx: mpx, runs: rgbRuns, tuning: tuning)

            XCTAssertGreaterThan(cfaRuns.first!.tiles, 0, "CFA \(tier.name) must run the filter")
            XCTAssertGreaterThan(rgbRuns.first!.tiles, 0, "RGB \(tier.name) must run the filter")
        }
    }

    // MARK: - fixture preparation (no interpolation, no colour mixing)

    private struct Built {
        let planes: [[Float]]
        /// Reconstructed mosaic for `DNGRawWriter`, nil when the tier reads the original file.
        let raw: [UInt16]?
    }

    /// Downsample every CFA plane by `factor` (box average of same-phase samples), then centre-crop.
    private func planes(from mosaic: (samples: [UInt16], width: Int, height: Int),
                        width: Int,
                        cfa: String,
                        channel: [Int],
                        blacks: [Double],
                        white: Int,
                        factor: Int,
                        cropX: Int,
                        cropY: Int,
                        planeW: Int,
                        planeH: Int,
                        raw wantRaw: Bool) throws -> Built {
        var planes = [[Float]](repeating: [Float](repeating: 0, count: planeW * planeH), count: 4)
        var raw = wantRaw ? [UInt16](repeating: 0, count: (2 * planeW) * (2 * planeH)) : []
        let divisor = Float(factor * factor)
        for c in 0..<4 {
            let dx = c % 2
            let dy = c / 2
            let black = Float(BuiltinDenoiseJob.blackLevel(for: c, channel: channel, levels: blacks))
            let span = Float(white) - black
            for y in 0..<planeH {
                let sy = (cropY + y) * factor
                for x in 0..<planeW {
                    let sx = (cropX + x) * factor
                    var sum = 0
                    for j in 0..<factor {
                        let row = (2 * (sy + j) + dy) * width
                        for i in 0..<factor {
                            sum += Int(mosaic.samples[row + 2 * (sx + i) + dx])
                        }
                    }
                    let averaged = Float(sum) / divisor
                    let normalised = span > 0 ? (averaged - black) / span : averaged
                    planes[c][y * planeW + x] = min(max(normalised, 0), 1)
                    if wantRaw {
                        raw[(2 * y + dy) * (2 * planeW) + (2 * x + dx)] =
                            UInt16(min(max(averaged.rounded(), 0), 65535))
                    }
                }
            }
        }
        return Built(planes: planes, raw: wantRaw ? raw : nil)
    }

    /// CFA planes → one RGB sample per display pixel. A CFA cell covers 2×2 display pixels, so each
    /// channel is replicated; this is a canvas, not a demosaic, and its job is to have the right size.
    private func makeRGB(planes: [[Float]], channel: [Int], planeW: Int, planeH: Int) -> [[Float]] {
        var sums = [[Float]](repeating: [Float](repeating: 0, count: planeW * planeH), count: 3)
        var counts = [Float](repeating: 0, count: 3)
        for c in 0..<4 {
            let ch = channel[c]
            counts[ch] += 1
            for i in 0..<(planeW * planeH) { sums[ch][i] += planes[c][i] }
        }
        for ch in 0..<3 where counts[ch] > 0 {
            let scale = 1 / counts[ch]
            for i in 0..<(planeW * planeH) { sums[ch][i] *= scale }
        }
        let w = 2 * planeW
        let h = 2 * planeH
        var rgb = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: 3)
        for y in 0..<h {
            let py = y / 2
            for x in 0..<w {
                let from = py * planeW + x / 2
                let to = y * w + x
                for ch in 0..<3 { rgb[ch][to] = sums[ch][from] }
            }
        }
        return rgb
    }

    // MARK: - measurement

    private func measure(runs: Int,
                         _ body: () throws -> Measurement) rethrows -> [Measurement] {
        var results: [Measurement] = []
        results.reserveCapacity(runs)
        for _ in 0..<runs { results.append(try body()) }
        return results
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private func printRow(tier: Tier, form: String, mpx: Double,
                          runs: [Measurement], tuning: BuiltinDenoise.Tuning) {
        let ms = median(runs.map { $0.wall * 1000 })
        let reported = median(runs.map { $0.reported })
        let perMpx = ms / max(mpx, 0.001)
        let a = runs.map { $0.a }.sorted()[runs.count / 2]
        let b = runs.map { $0.b }.sorted()[runs.count / 2]
        let sigma0 = Double(max(b, 0)).squareRoot()
        let tiles = runs.map { $0.tiles }.sorted()[runs.count / 2]
        let radius = "\(tuning.search)/\(tuning.search2)/\(tuning.searchC)"
        print(String(format: "495 table\t%@\t%@\t%d×%d\t%.2f\t%.4f\t%.4g\t%.4g\t%@\t%d\t%.1f\t%.1f\t%.3f",
                     tier.name, form, tier.width, tier.height, mpx, sigma0, a, b, radius, tiles,
                     ms, perMpx, reported))
        let each = runs.map { String(format: "%.1f", $0.wall * 1000) }.joined(separator: "/")
        print("495 runs\t\(tier.name)\t\(form)\t\(each) ms  (self-reported "
              + runs.map { String(format: "%.3f", $0.reported) }.joined(separator: "/") + " s)")
    }
}
