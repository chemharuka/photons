import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotonsCore
@testable import PhotonsExport

/// M5 acceptance: presets, naming, and the batch engine.
///
/// Everything here runs against synthetic pixels — no RAW fixture, no GPU, no catalog — because the
/// engine's contract is "given pixels and a preset, produce one file per item and one result per
/// item". The parts that need a renderer (long edge, sharpening) are exercised by handing the engine
/// pixels of a known size and reading the file back with ImageIO.
final class BatchExportTests: XCTestCase {

    private var scratch: URL!
    private var out: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-batch-tests-\(UUID().uuidString)", isDirectory: true)
        out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - helpers

    /// A horizontal gradient with a step in the middle: uniform areas are useless for a sharpening
    /// test, and an exact ramp is easy to reason about for a resample.
    /// The default preset asks for Display P3 (`ExportPreset.colorSpace`), and `BatchExporter`
    /// refuses to retag pixels that were rendered in another space, so the fixture is P3 too.
    private func image(width: Int = 320, height: Int = 240,
                       primaries: OutputPrimaries = .displayP3) -> DisplayImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(max(width - 1, 1))
                let v = Float(y) / Float(max(height - 1, 1))
                let o = (y * width + x) * 4
                rgba[o] = Float16(u)
                rgba[o + 1] = Float16(min(1, u * 0.5 + v * 0.5))
                rgba[o + 2] = Float16(v)
                rgba[o + 3] = 1
            }
        }
        return DisplayImage(width: width, height: height, rgba: rgba,
                            primaries: primaries, bitDepth: 8)
    }

    private func item(_ name: String, rating: Int = 0, date: Date? = nil,
                      edit: EditModel? = nil) -> ExportItem {
        ExportItem(id: "id-\(name)", name: name, captureDate: date, rating: rating, edit: edit)
    }

    private func readBack(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            XCTFail("ImageIO cannot read \(url.lastPathComponent)")
            throw ExportError.destinationFailed(url)
        }
        return img
    }

    private func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path))[.size] as? Int)
    }

    private let utc = TimeZone(secondsFromGMT: 0)!

    private func date(_ string: String) throws -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return try XCTUnwrap(f.date(from: string))
    }

    // MARK: - 1. naming

    func testNameTemplateExpandsEveryToken() throws {
        let when = try date("2026-03-04 05:06:07")
        let got = ExportNaming.baseName(template: "{date}_{name}_r{rating}_{seq}",
                                        item: item("L1030433", rating: 4, date: when),
                                        sequence: 7)
        XCTAssertEqual(got, "20260304_L1030433_r4_0007")
    }

    func testNameTemplateLeavesUnknownTokensAndSanitisesSeparators() {
        // A token we do not know is a typo the user must see; a slash is a path the batch must not
        // follow.
        let got = ExportNaming.baseName(template: "{camera}/{name} v2", item: item("A B"), sequence: 1)
        XCTAssertEqual(got, "{camera}-A_B_v2")
    }

    func testEmptyDateTokenCollapsesInsteadOfInventingATimestamp() {
        let got = ExportNaming.baseName(template: "{name}{date}", item: item("X"), sequence: 2)
        XCTAssertEqual(got, "X")
    }

    // MARK: - 2. no overwrite

    func testSecondRunDoesNotOverwriteTheFirst() throws {
        let preset = ExportPreset(format: .jpeg, longEdge: 64)
        let items = [item("a"), item("b")]
        let render: (ExportItem, ExportPreset) throws -> DisplayImage = { _, _ in self.image() }

        let first = BatchExporter.run(items: items, preset: preset, outputDirectory: out, render: render)
        XCTAssertEqual(first.written.count, 2)
        let firstNames = Set(first.written.compactMap { $0.fileURL?.lastPathComponent })
        XCTAssertEqual(firstNames, ["a.jpg", "b.jpg"])

        let second = BatchExporter.run(items: items, preset: preset, outputDirectory: out, render: render)
        XCTAssertEqual(second.written.count, 2)
        let secondNames = Set(second.written.compactMap { $0.fileURL?.lastPathComponent })
        XCTAssertEqual(secondNames, ["a-1.jpg", "b-1.jpg"])

        // Four distinct files on disk, and the first pair still holds the first run's bytes.
        let all = try FileManager.default.contentsOfDirectory(atPath: out.path)
            .filter { $0.hasSuffix(".jpg") }.sorted()
        XCTAssertEqual(all, ["a-1.jpg", "a.jpg", "b-1.jpg", "b.jpg"])
    }

    func testExistingFileOnDiskIsNeverReplaced() throws {
        let sentinel = Data("not an image".utf8)
        try sentinel.write(to: out.appendingPathComponent("a.jpg"))
        let report = BatchExporter.run(items: [item("a")],
                                       preset: ExportPreset(format: .jpeg, longEdge: 64),
                                       outputDirectory: out,
                                       render: { _, _ in self.image() })
        XCTAssertEqual(report.written.first?.fileURL?.lastPathComponent, "a-1.jpg")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("a.jpg")), sentinel)
    }

    // MARK: - 3. size and quality actually reach the file

    func testLongEdgeIsAppliedAndReadBackFromTheFile() throws {
        // The renderer ignores the hint on purpose: the engine must still honour the preset.
        let preset = ExportPreset(format: .jpeg, longEdge: 160)
        let report = BatchExporter.run(items: [item("big")], preset: preset,
                                       outputDirectory: out,
                                       render: { _, _ in self.image(width: 4000, height: 3000) })
        let url = try XCTUnwrap(report.written.first?.fileURL)
        let img = try readBack(url)
        XCTAssertEqual(img.width, 160)
        XCTAssertEqual(img.height, 120)
        XCTAssertEqual(report.written.first?.pixelSize, ImageSize(width: 160, height: 120))
        // The caller is told it paid for a second resample.
        XCTAssertTrue(report.written.first?.warnings.contains { $0.contains("resampled") } ?? false)
    }

    func testLongEdgeLargerThanThePictureDoesNotUpscale() throws {
        let report = BatchExporter.run(items: [item("small")],
                                       preset: ExportPreset(format: .jpeg, longEdge: 6000),
                                       outputDirectory: out,
                                       render: { _, _ in self.image(width: 320, height: 240) })
        let img = try readBack(try XCTUnwrap(report.written.first?.fileURL))
        XCTAssertEqual(img.width, 320)
        XCTAssertEqual(img.height, 240)
    }

    /// 168 §2 — 不扩大 clamps the request to the source and the outcome says so; turning the
    /// checkbox off is the explicit permission to enlarge. Scaled down so the test stays light.
    func testNoUpscaleClampsTheRequestAndRecordsWhy() throws {
        let report = BatchExporter.run(items: [item("small")],
                                       preset: ExportPreset(format: .jpeg, longEdge: 80,
                                                            noUpscale: true),
                                       outputDirectory: out,
                                       render: { _, _ in self.image(width: 60, height: 40) })
        let outcome = try XCTUnwrap(report.written.first)
        XCTAssertEqual(outcome.pixelSize, ImageSize(width: 60, height: 40))
        XCTAssertTrue(outcome.warnings.contains {
            $0.contains("长边 80 请求") && $0.contains("源 60")
                && $0.contains("按不扩大输出 60")
        }, outcome.warnings.joined(separator: " | "))
    }

    func testAllowingUpscaleHonoursTheRequestedLongEdge() throws {
        let report = BatchExporter.run(items: [item("small")],
                                       preset: ExportPreset(format: .jpeg, longEdge: 80,
                                                            noUpscale: false),
                                       outputDirectory: out,
                                       render: { _, _ in self.image(width: 60, height: 40) })
        let outcome = try XCTUnwrap(report.written.first)
        XCTAssertEqual(outcome.pixelSize, ImageSize(width: 80, height: 53))
    }

    /// 161 §3 — the exporter is the *correct* half of the old bug: `.none` ignores a stale
    /// `longEdge`. (The panel used to render at 2048 before the batch ever saw the pixels; that half
    /// is pinned in `ExportSheetSizingTests`.)
    func testOriginalSizeModeIgnoresAStaleLongEdge() throws {
        let preset = ExportPreset(name: "网络 2048", format: .png, longEdge: 2048,
                                  sizingMode: ExportSizingMode.none)
        let report = BatchExporter.run(items: [item("original")], preset: preset,
                                       outputDirectory: out,
                                       render: { _, _ in self.image(width: 320, height: 240) })
        let img = try readBack(try XCTUnwrap(report.written.first?.fileURL))
        XCTAssertEqual(img.width, 320, "原尺寸不能被残留的 2048 长边缩掉")
        XCTAssertEqual(img.height, 240)
        XCTAssertEqual(report.written.first?.pixelSize, ImageSize(width: 320, height: 240))
    }

    func testQualityChangesTheFileAndStaysLossy() throws {
        func run(_ q: Double) throws -> Int {
            let report = BatchExporter.run(items: [item("q")],
                                           preset: ExportPreset(format: .jpeg, quality: q),
                                           outputDirectory: out,
                                           render: { _, _ in self.image(width: 640, height: 480) })
            return try fileSize(try XCTUnwrap(report.written.first?.fileURL))
        }
        let low = try run(0.2), high = try run(0.98)
        XCTAssertLessThan(low, high, "quality 0.2 must produce a smaller JPEG than 0.98")
        XCTAssertGreaterThan(high, 1000)
    }

    // MARK: - 4. colour space → ICC

    func testDisplayP3AndSRGBWriteDifferentICCProfiles() throws {
        func profile(_ primaries: OutputPrimaries) throws -> String {
            let report = BatchExporter.run(items: [item("cs")],
                                           preset: ExportPreset(format: .jpeg, colorSpace: primaries),
                                           outputDirectory: out,
                                           render: { _, _ in self.image(primaries: primaries) })
            let img = try readBack(try XCTUnwrap(report.written.first?.fileURL))
            return try XCTUnwrap(img.colorSpace?.name as String?)
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        XCTAssertEqual(try profile(.sRGB), srgb.name as String?)
        XCTAssertEqual(try profile(.displayP3), p3.name as String?)
    }

    func testPresetColourSpaceMismatchFailsInsteadOfRetagging() throws {
        // sRGB pixels with a P3 preset would ship wrong colours: the item must fail, not be saved.
        let report = BatchExporter.run(items: [item("mismatch")],
                                       preset: ExportPreset(format: .jpeg, colorSpace: .displayP3),
                                       outputDirectory: out,
                                       // deliberately the *other* space: this test is the guard
                                       render: { _, _ in self.image(primaries: .sRGB) })
        XCTAssertTrue(report.written.isEmpty)
        XCTAssertTrue(report.failures.first?.error?.contains("Display P3") ?? false)
    }

    // MARK: - 5. failure isolation

    func testOneBrokenItemDoesNotStopTheBatch() throws {
        let items = [item("ok1"), item("broken"), item("ok2"), item("ok3")]
        let report = BatchExporter.run(items: items,
                                       preset: ExportPreset(format: .jpeg, longEdge: 64),
                                       outputDirectory: out,
                                       render: { item, _ in
            if item.name == "broken" { throw ExportError.encodeFailed("simulated decode failure") }
            return self.image(width: 64, height: 48)
        })
        XCTAssertEqual(report.outcomes.count, 4)
        XCTAssertEqual(report.written.map(\.sourceName), ["ok1", "ok2", "ok3"])
        XCTAssertEqual(report.failures.map(\.sourceName), ["broken"])
        XCTAssertTrue(report.failures[0].error?.contains("simulated") ?? false)
        XCTAssertNil(report.failures[0].fileURL)
        // The three survivors really are on disk.
        for name in ["ok1", "ok2", "ok3"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("\(name).jpg").path))
        }
    }

    func testOutcomesStayInRequestOrderEvenWhenTheBrokenOneIsLast() throws {
        let items = (1...5).map { item("i\($0)") } + [item("z-bad")]
        let report = BatchExporter.run(items: items,
                                       preset: ExportPreset(format: .jpeg, longEdge: 32),
                                       outputDirectory: out,
                                       render: { item, _ in
            if item.name == "z-bad" { throw ExportError.encodeFailed("nope") }
            return self.image(width: 32, height: 24)
        })
        XCTAssertEqual(report.outcomes.map(\.index), Array(0..<6))
        XCTAssertEqual(report.outcomes.last?.sourceName, "z-bad")
    }

    // MARK: - 6. concurrency

    func testConcurrencyNeverExceedsTwo() throws {
        let lock = NSLock()
        var inFlight = 0
        var peak = 0
        let items = (0..<8).map { item("c\($0)") }

        let started = CFAbsoluteTimeGetCurrent()
        let report = BatchExporter.run(items: items,
                                       preset: ExportPreset(format: .jpeg, longEdge: 32),
                                       outputDirectory: out,
                                       concurrency: 2,
                                       render: { _, _ in
            lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
            lock.lock(); inFlight -= 1; lock.unlock()
            return self.image(width: 32, height: 24)
        })
        let wall = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(report.written.count, 8)
        XCTAssertLessThanOrEqual(peak, 2, "the engine ran \(peak) renders at once")
        XCTAssertLessThanOrEqual(report.peakConcurrency, 2)
        XCTAssertEqual(report.peakConcurrency, peak)
        // 8 × 50 ms is 0.4 s serially; two at a time must be measurably faster than that.
        XCTAssertLessThan(wall, 0.4)
        XCTAssertGreaterThan(peak, 1, "nothing ran in parallel — the queue is serial")
    }

    func testSequenceTokenFollowsRequestOrderNotCompletionOrder() throws {
        // The first item is the slowest, so a "seq = finishing order" bug would put it last.
        let items = (1...4).map { item("s\($0)") }
        let report = BatchExporter.run(items: items,
                                       preset: ExportPreset(format: .jpeg, longEdge: 24,
                                                            nameTemplate: "{seq}_{name}"),
                                       outputDirectory: out,
                                       render: { item, _ in
            if item.name == "s1" { Thread.sleep(forTimeInterval: 0.08) }
            return self.image(width: 24, height: 18)
        })
        let names = Set(report.written.compactMap { $0.fileURL?.lastPathComponent })
        XCTAssertEqual(names, ["0001_s1.jpg", "0002_s2.jpg", "0003_s3.jpg", "0004_s4.jpg"])
    }

    // MARK: - 7. XMP

    func testXMPIsAbsentUnlessThePresetAsks() throws {
        var edit = EditModel.neutral
        edit.light.exposure = 0.75
        func run(_ writeXMP: Bool) throws -> URL {
            let report = BatchExporter.run(items: [item("x", edit: edit)],
                                           preset: ExportPreset(format: .jpeg, writeXMP: writeXMP),
                                           outputDirectory: out,
                                           render: { _, _ in self.image() })
            return try XCTUnwrap(report.written.first?.fileURL)
        }
        let without = try readMetadata(try run(false))
        XCTAssertNil(without.flatMap { XMPReadback.string($0, "photons:settings") })

        let url = try run(true)
        let with = try XCTUnwrap(readMetadata(url))
        XCTAssertNotNil(XMPReadback.string(with, "photons:settings"))
        XCTAssertEqual(XMPReadback.string(with, "crs:Version"), XMPNamespace.crsVersion)
        XCTAssertEqual(XMPReadback.double(with, "crs:Exposure2012") ?? 0, 0.75, accuracy: 1e-6)
        // And the document came back whole, not merely the crs: subset.
        let restored = XMPReadback.settings(with)
        XCTAssertEqual(restored?.light.exposure ?? 0, 0.75, accuracy: 1e-6)
    }

    private func readMetadata(_ url: URL) -> CGImageMetadata? {
        XMPReadback.metadata(of: url)
    }

    func testSixteenBitPNGKeepsItsDepthAndGetsASidecarInstead() throws {
        var edit = EditModel.neutral
        edit.color.saturation = 12
        let report = BatchExporter.run(items: [item("png16", edit: edit)],
                                       preset: ExportPreset(format: .png, bitDepth: 16,
                                                            writeXMP: true),
                                       outputDirectory: out,
                                       render: { _, _ in self.image(width: 96, height: 64) })
        let url = try XCTUnwrap(report.written.first?.fileURL)
        XCTAssertEqual(try readBack(url).bitsPerComponent, 16)
        // ImageIO's PNG embed path re-encodes through CGImage and would drop to 8 bits, so the
        // packet goes beside the file instead.
        let sidecar = url.deletingPathExtension().appendingPathExtension("xmp")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(report.written.first?.xmpURL, sidecar)
        let metadata = try XCTUnwrap(XMPReadback.metadata(fromXMP: sidecar))
        XCTAssertEqual(XMPReadback.double(metadata, "crs:Saturation") ?? 0, 12, accuracy: 1e-6)
        XCTAssertTrue(report.written.first?.warnings.contains { $0.contains("16-bit PNG") } ?? false)
    }

    // MARK: - 8. bit depth

    func testTIFF16BitIsReally16BitAndDiffersFrom8Bit() throws {
        func run(_ bits: Int) throws -> (CGImage, Int) {
            let report = BatchExporter.run(items: [item("bits")],
                                           preset: ExportPreset(format: .tiff, bitDepth: bits),
                                           outputDirectory: out,
                                           render: { _, _ in self.image(width: 256, height: 192) })
            let url = try XCTUnwrap(report.written.first?.fileURL)
            return (try readBack(url), try fileSize(url))
        }
        let (eight, size8) = try run(8)
        let (sixteen, size16) = try run(16)
        XCTAssertEqual(eight.bitsPerComponent, 8)
        XCTAssertEqual(sixteen.bitsPerComponent, 16)
        XCTAssertGreaterThan(size16, size8)
        // Same picture either way: the bit depth is a container property, not a crop.
        XCTAssertEqual(eight.width, sixteen.width)
        XCTAssertEqual(eight.height, sixteen.height)
        XCTAssertEqual(sixteen.width, 256)
    }

    func testJPEGPresetDowngrades16BitInsteadOfFailingEveryImage() throws {
        let preset = ExportPreset(format: .jpeg, bitDepth: 16)
        XCTAssertEqual(preset.effectiveBitDepth, 8)
        let report = BatchExporter.run(items: [item("j")], preset: preset, outputDirectory: out,
                                       render: { _, _ in self.image() })
        XCTAssertEqual(report.written.count, 1)
    }

    // MARK: - 9. sharpening (off by default)

    func testOutputSharpeningChangesPixelsAndKeepsTheSize() throws {
        let pixels = image(width: 200, height: 150)
        func run(_ sharpen: OutputSharpening?) throws -> URL {
            let report = BatchExporter.run(items: [item("sharp")],
                                           preset: ExportPreset(format: .png, sharpen: sharpen),
                                           outputDirectory: out,
                                           render: { _, _ in pixels })
            return try XCTUnwrap(report.written.first?.fileURL)
        }
        let plain = try run(nil)
        let plainAgain = try run(nil)
        let sharp = try run(OutputSharpening(amount: 1.0, radius: 1.0))

        // Two runs of the same input are byte-identical (PNG is lossless and the encoder is
        // deterministic), which is what makes the next assertion meaningful.
        XCTAssertEqual(try Data(contentsOf: plain), try Data(contentsOf: plainAgain))
        XCTAssertNotEqual(try Data(contentsOf: plain), try Data(contentsOf: sharp))

        let img = try readBack(sharp)
        XCTAssertEqual(img.width, 200)
        XCTAssertEqual(img.height, 150)
    }

    // MARK: - 10. a preset is a file

    func testPresetSurvivesJSONAndKeepsEveryField() throws {
        let preset = ExportPreset(name: "Web", format: .heic, longEdge: 2400, quality: 0.8,
                                  bitDepth: 8, colorSpace: .displayP3, writeXMP: true,
                                  sharpen: OutputSharpening(amount: 0.4, radius: 0.7),
                                  nameTemplate: "{date}/{name}")
        let url = scratch.appendingPathComponent("web.json")
        try preset.save(to: url)
        let back = try ExportPreset.load(from: url)
        XCTAssertEqual(back, preset)
        // Sorted keys, so a preset file diffs cleanly.
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"bitDepth\"")).lowerBound,
                          try XCTUnwrap(text.range(of: "\"format\"")).lowerBound)
    }

    func testPresetMissesKeysButRejectsATypoInTheFormat() throws {
        let minimal = scratch.appendingPathComponent("minimal.json")
        try Data(#"{"format":"jpg"}"#.utf8).write(to: minimal)
        let loaded = try ExportPreset.load(from: minimal)
        XCTAssertEqual(loaded.format, .jpeg)
        XCTAssertEqual(loaded.quality, 0.92, accuracy: 1e-9)
        XCTAssertFalse(loaded.writeXMP)
        XCTAssertNil(loaded.sharpen)

        let typo = scratch.appendingPathComponent("typo.json")
        try Data(#"{"format":"jpgg"}"#.utf8).write(to: typo)
        XCTAssertThrowsError(try ExportPreset.load(from: typo))
    }

    func testSizingNeverUpscalesAndRoundsLikeTheRenderer() {
        let content = ImageSize(width: 6000, height: 4000)
        XCTAssertEqual(ExportSizing.scale(content: content, longEdge: 1500), 0.25, accuracy: 1e-12)
        XCTAssertEqual(ExportSizing.scale(content: content, longEdge: 6000), 1, accuracy: 1e-12)
        XCTAssertEqual(ExportSizing.scale(content: content, longEdge: 9000), 1, accuracy: 1e-12)
        XCTAssertEqual(ExportSizing.scale(content: content, longEdge: nil), 1, accuracy: 1e-12)
        XCTAssertEqual(ExportSizing.outputSize(content: content, scale: 0.25),
                       ImageSize(width: 1500, height: 1000))
        // A portrait frame keys on the long edge too.
        XCTAssertEqual(ExportSizing.scale(content: ImageSize(width: 4000, height: 6000), longEdge: 3000),
                       0.5, accuracy: 1e-12)
    }

    // MARK: - 11. formats

    func testPNGAndAVIFPayloadsAreReadableWhenTheEncoderExists() throws {
        for format in [ExportFormat.png, .avif] {
            let report = BatchExporter.run(items: [item("f")],
                                           preset: ExportPreset(format: format),
                                           outputDirectory: out,
                                           render: { _, _ in self.image(width: 128, height: 96) })
            if let failure = report.failures.first {
                // Documented acceptable outcome: ImageIO on this OS has no encoder for the format.
                XCTAssertTrue(failure.error?.contains("destination") ?? false,
                              "\(format.rawValue): \(failure.error ?? "")")
                continue
            }
            let url = try XCTUnwrap(report.written.first?.fileURL)
            XCTAssertEqual(url.pathExtension, format.fileExtension)
            let img = try readBack(url)
            XCTAssertEqual(img.width, 128)
            XCTAssertEqual(img.height, 96)
        }
    }
}
