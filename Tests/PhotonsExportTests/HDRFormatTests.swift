import XCTest
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import PhotonsCore
@testable import PhotonsExport

/// 111 — HDR output kinds, PNG, and the "original size / never upscale" sizing rules.
///
/// Every assertion reads the written file back. The fixtures are synthetic so the suite needs no RAW
/// file and no GPU: `DisplayImage.linear` is exactly the half-float buffer `s4_display_linear` would
/// have produced.
final class HDRFormatTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hdr-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - fixtures

    /// A smooth gradient. The display half is encoded 0…1; the linear companion peaks at 2.0 so it is
    /// genuinely extended-range, and its alpha matches the display half.
    private func image(width: Int = 32, height: Int = 24,
                       primaries: OutputPrimaries = .sRGB) -> DisplayImage {
        var display = [Float16](repeating: 1, count: width * height * 4)
        var linear = [Float16](repeating: 1, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let u = Float(x) / Float(max(1, width - 1))
                let v = Float(y) / Float(max(1, height - 1))
                let o = (y * width + x) * 4
                display[o] = Float16(u)
                display[o + 1] = Float16(0.25 + v * 0.75)
                display[o + 2] = Float16(0.10 + u * 0.5)
                display[o + 3] = 1
                linear[o] = Float16(0.02 + u * 1.98)
                linear[o + 1] = Float16(0.02 + v * 0.9)
                linear[o + 2] = Float16(0.02 + u * 0.4)
                linear[o + 3] = 1
            }
        }
        let base = DisplayImage(width: width, height: height, rgba: display,
                                primaries: primaries, bitDepth: 8)
        return base.withLinear(LinearPixels(width: width, height: height, rgba: linear,
                                            primaries: primaries))
    }

    private func url(_ name: String) -> URL { scratch.appendingPathComponent(name) }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ExportError.encodeFailed("ImageIO cannot open \(url.lastPathComponent)")
        }
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func depth(_ url: URL) throws -> Int? {
        (try properties(url)[kCGImagePropertyDepth] as? NSNumber)?.intValue
    }

    private func profile(_ url: URL) throws -> String {
        try XCTUnwrap(try properties(url)[kCGImagePropertyProfileName] as? String)
    }

    private func write(_ preset: ExportPreset, _ name: String,
                       metadata: ExportMetadataContext = ExportMetadataContext()) throws -> URL {
        let out = url(name)
        try Exporter.write(image(), to: out, options: preset.exportOptions, metadata: metadata)
        return out
    }

    // MARK: - 1. the combination table

    func testFormatHDRKindTable() {
        XCTAssertEqual(ExportFormat.jpeg.hdrKinds, [.none])
        XCTAssertEqual(ExportFormat.heic.hdrKinds, [.none, .gainMap, .hlg, .pq])
        XCTAssertEqual(ExportFormat.avif.hdrKinds, [.none, .gainMap, .hlg, .pq])
        XCTAssertEqual(ExportFormat.tiff.hdrKinds, [.none, .hlg, .pq])
        XCTAssertEqual(ExportFormat.png.hdrKinds, [.none, .hlg, .pq])
    }

    func testValidatedRejectsEveryIllegalCombination() {
        let illegal: [(ExportFormat, HDRKind)] = [
            (.jpeg, .gainMap), (.jpeg, .hlg), (.jpeg, .pq), (.tiff, .gainMap), (.png, .gainMap),
        ]
        for (format, kind) in illegal {
            XCTAssertThrowsError(try ExportPreset(format: format,
                                                  hdr: HDRExport(kind: kind)).validated(),
                                 "\(format.rawValue) + \(kind.rawValue) must be rejected") { error in
                guard case ExportPresetError.badHDRKind(let f, let k) = error else {
                    return XCTFail("expected badHDRKind, got \(error)")
                }
                XCTAssertEqual(f, format)
                XCTAssertEqual(k, kind)
            }
        }
        // Every legal cell validates. 163 — PQ/HLG cells carry the one depth their container allows,
        // because `validated()` now refuses the silent-clamp mistake rather than accepting it.
        for format in ExportFormat.allCases {
            for kind in format.hdrKinds {
                let depth = format.hdrTransferBitDepth(for: kind) ?? 8
                XCTAssertNoThrow(try ExportPreset(format: format, bitDepth: depth,
                                                  hdr: HDRExport(kind: kind)).validated(),
                                 "\(format.rawValue) + \(kind.rawValue) at \(depth)-bit must be accepted")
            }
        }
    }

    /// 163 §1.3 — the four container shapes at their one legal depth, and the same four stale at 8-bit.
    func testPQHLGRequireTheFormatsExactBitDepth() throws {
        let allowed: [(ExportFormat, HDRKind, Int)] = [
            (.heic, .pq, 10), (.avif, .hlg, 10), (.png, .pq, 16), (.tiff, .hlg, 16),
        ]
        for (format, kind, bits) in allowed {
            XCTAssertNoThrow(try ExportPreset(format: format, bitDepth: bits,
                                              hdr: HDRExport(kind: kind)).validated(),
                             "\(format.rawValue) \(kind.rawValue) at \(bits)-bit")
        }
        let rejected: [(ExportFormat, HDRKind, Int)] = [
            (.heic, .pq, 8), (.avif, .hlg, 8), (.png, .pq, 8), (.tiff, .hlg, 8),
        ]
        for (format, kind, bits) in rejected {
            XCTAssertThrowsError(try ExportPreset(format: format, bitDepth: bits,
                                                  hdr: HDRExport(kind: kind)).validated(),
                                 "\(format.rawValue) \(kind.rawValue) at \(bits)-bit must be rejected") {
                guard case ExportPresetError.hdrNeedsBitDepth(let f, let k, let got, let want) = $0 else {
                    return XCTFail("expected hdrNeedsBitDepth, got \($0)")
                }
                XCTAssertEqual(f, format)
                XCTAssertEqual(k, kind)
                XCTAssertEqual(got, bits)
                XCTAssertEqual(want, format == .png || format == .tiff ? 16 : 10)
            }
        }
        // The other wrong direction: a 16-bit HEIF PQ request is just as illegal as 8-bit PNG.
        XCTAssertThrowsError(try ExportPreset(format: .heic, bitDepth: 16,
                                              hdr: HDRExport(kind: .pq)).validated())
        // JPEG has neither curve, so it fails at the kind check before the depth check.
        for kind in [HDRKind.pq, .hlg] {
            XCTAssertThrowsError(try ExportPreset(format: .jpeg, bitDepth: 8,
                                                  hdr: HDRExport(kind: kind)).validated()) {
                guard case ExportPresetError.badHDRKind = $0 else {
                    return XCTFail("expected badHDRKind, got \($0)")
                }
            }
        }
        // The sheet's picker is derived from the same rule.
        XCTAssertEqual(ExportFormat.heic.bitDepths(for: .pq), [10])
        XCTAssertEqual(ExportFormat.png.bitDepths(for: .hlg), [16])
        XCTAssertEqual(ExportFormat.jpeg.bitDepths(for: .pq), [8])
    }

    // MARK: - 2. bit-depth enforcement

    func testForcedBitDepthPerKind() {
        for format in [ExportFormat.heic, .avif] {
            for kind in [HDRKind.hlg, .pq] {
                XCTAssertEqual(ExportPreset(format: format, bitDepth: 8,
                                            hdr: HDRExport(kind: kind)).effectiveBitDepth, 10)
                XCTAssertEqual(ExportPreset(format: format, bitDepth: 16,
                                            hdr: HDRExport(kind: kind)).effectiveBitDepth, 10)
            }
        }
        for format in [ExportFormat.tiff, .png] {
            for kind in [HDRKind.hlg, .pq] {
                XCTAssertEqual(ExportPreset(format: format, bitDepth: 8,
                                            hdr: HDRExport(kind: kind)).effectiveBitDepth, 16)
            }
        }
        // A gain map's depth is the SDR base's: 8 or 10, never 16.
        XCTAssertEqual(ExportPreset(format: .heic, bitDepth: 8,
                                    hdr: HDRExport(kind: .gainMap)).effectiveBitDepth, 8)
        XCTAssertEqual(ExportPreset(format: .heic, bitDepth: 10,
                                    hdr: HDRExport(kind: .gainMap)).effectiveBitDepth, 10)
        XCTAssertEqual(ExportPreset(format: .avif, bitDepth: 10,
                                    hdr: HDRExport(kind: .gainMap)).effectiveBitDepth, 10)
        XCTAssertEqual(ExportPreset(format: .heic, bitDepth: 16,
                                    hdr: HDRExport(kind: .gainMap)).effectiveBitDepth, 10)
        // SDR keeps the container's own limit.
        XCTAssertEqual(ExportPreset(format: .jpeg, bitDepth: 16).effectiveBitDepth, 8)
        XCTAssertEqual(ExportPreset(format: .heic, bitDepth: 16).effectiveBitDepth, 10)
        XCTAssertEqual(ExportPreset(format: .tiff, bitDepth: 16).effectiveBitDepth, 16)
        XCTAssertEqual(ExportPreset(format: .png, bitDepth: 16).effectiveBitDepth, 16)
    }

    // MARK: - 3. PQ / HLG really reach the file

    func testPQAndHLGAreWrittenAndReadBack() throws {
        let cases: [(ExportFormat, HDRKind, Int)] = [
            (.heic, .pq, 10), (.heic, .hlg, 10),
            (.avif, .pq, 10), (.avif, .hlg, 10),
            (.tiff, .pq, 16), (.tiff, .hlg, 16),
            (.png, .pq, 16), (.png, .hlg, 16),
        ]
        for (format, kind, bits) in cases {
            let preset = ExportPreset(format: format, quality: 1.0,
                                      hdr: HDRExport(kind: kind))
            let out = try write(preset, "\(kind.rawValue)-\(format.rawValue).\(format.fileExtension)")
            XCTAssertEqual(try depth(out), bits,
                           "\(format.rawValue) \(kind.rawValue) depth")
            let name = try profile(out)
            XCTAssertTrue(name.contains(kind == .pq ? "PQ" : "HLG"),
                          "\(format.rawValue) \(kind.rawValue) profile was '\(name)'")
            if format == .heic || format == .avif {
                XCTAssertTrue(name.contains("HDR Metadata"),
                              "\(format.rawValue) should carry the HDR metadata marker: '\(name)'")
            }
            if let image = CGImageSourceCreateImageAtIndex(
                try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil)), 0, nil) {
                XCTAssertEqual(image.bitsPerComponent, bits)
            }
        }
    }

    // MARK: - 4. gain map still means 4:2:0 / 8-bit

    @available(macOS 15.0, *)
    func testGainMapBaseKeepsItsDepthAndTheMapIs420EightBit() throws {
        let preset = ExportPreset(format: .heic, bitDepth: 10,
                                  colorSpace: .sRGB,
                                  hdr: HDRExport(kind: .gainMap, gainMap: .iso))
        let out = try write(preset, "gainmap.heic")
        XCTAssertEqual(try depth(out), 10)

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let aux = try XCTUnwrap(CGImageSourceCopyAuxiliaryDataInfoAtIndex(
            source, 0, kCGImageAuxiliaryDataTypeISOGainMap) as? [CFString: Any])
        let description = try XCTUnwrap(
            aux[kCGImageAuxiliaryDataInfoDataDescription] as? [CFString: Any])
        let pixelFormat = (description["PixelFormat" as CFString] as? NSNumber)?.intValue
        XCTAssertEqual(pixelFormat, Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        if let bits = (description["BitsPerComponent" as CFString] as? NSNumber)?.intValue {
            XCTAssertEqual(bits, 8)
        }
    }

    // MARK: - 5. backwards compatibility

    func testLegacyHDRJSONDecodesToGainMapAndReEncodes() throws {
        let legacy = Data("""
        {
          "format" : "heic",
          "quality" : 0.9,
          "bitDepth" : 8,
          "colorSpace" : "sRGB",
          "writeXMP" : false,
          "nameTemplate" : "{name}",
          "hdr" : {
            "enabled" : true,
            "gainMap" : "apple",
            "halfSize" : false,
            "headroom" : "auto"
          }
        }
        """.utf8)
        let preset = try JSONDecoder().decode(ExportPreset.self, from: legacy)
        XCTAssertEqual(preset.hdrKind, .gainMap)
        XCTAssertTrue(preset.hdr?.enabled ?? false)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try preset.data()) as? [String: Any])
        let hdr = try XCTUnwrap(object["hdr"] as? [String: Any])
        XCTAssertEqual(hdr["kind"] as? String, "gainMap")
        XCTAssertEqual(hdr["enabled"] as? Bool, true)
        XCTAssertEqual(hdr["gainMap"] as? String, "apple")
        XCTAssertEqual(hdr["headroom"] as? String, "auto")

        // `enabled: false` (and no kind) stays SDR.
        let off = Data(#"{"format":"heic","hdr":{"enabled":false}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ExportPreset.self, from: off).hdrKind, .none)
    }

    // MARK: - 6. PNG

    func testPNG8And16KeepTheirDepth() throws {
        for bits in [8, 16] {
            let out = try write(ExportPreset(format: .png, bitDepth: bits,
                                             colorSpace: .sRGB),
                                "sdr-\(bits).png",
                                metadata: ExportMetadataContext(level: .none))
            XCTAssertEqual(try depth(out), bits)
        }
    }

    func testPNGWithMetadataNoneCarriesNoEXIF() throws {
        let out = try write(ExportPreset(format: .png, bitDepth: 16, colorSpace: .sRGB),
                            "bare.png", metadata: ExportMetadataContext(level: .none))
        let props = try properties(out)
        XCTAssertNil(props[kCGImagePropertyExifDictionary])
    }

    // MARK: - 7. original size / no upscale

    func testLongEdgeNeverUpscalesByDefaultButCanWhenAllowed() throws {
        let pixels = image(width: 320, height: 240)
        let base = ExportPreset(format: .jpeg, longEdge: 640, colorSpace: .sRGB, noUpscale: true)
        XCTAssertEqual(base.renderScale(content: ImageSize(width: 320, height: 240)), 1)
        XCTAssertTrue(base.summary.contains("未放大"))

        let allowed = ExportPreset(format: .jpeg, longEdge: 640, colorSpace: .sRGB,
                                   noUpscale: false)
        XCTAssertEqual(allowed.renderScale(content: ImageSize(width: 320, height: 240)), 2)

        let capped = BatchExporter.run(items: [ExportItem(id: "a", name: "capped")],
                                       preset: base, outputDirectory: scratch,
                                       render: { _, _ in pixels })
        XCTAssertEqual(capped.written.first?.pixelSize, ImageSize(width: 320, height: 240),
                       capped.failures.compactMap(\.error).joined(separator: "; "))

        let grown = BatchExporter.run(items: [ExportItem(id: "b", name: "grown")],
                                      preset: allowed, outputDirectory: scratch,
                                      render: { _, _ in pixels })
        XCTAssertEqual(grown.written.first?.pixelSize, ImageSize(width: 640, height: 480),
                       grown.failures.compactMap(\.error).joined(separator: "; "))
    }

    func testPercentAboveHundredIsCappedOnlyWhenNoUpscaleIsOn() {
        let content = ImageSize(width: 200, height: 100)
        XCTAssertEqual(ExportPreset(sizingMode: .percent, percent: 150)
            .renderScale(content: content), 1)
        XCTAssertEqual(ExportPreset(sizingMode: .percent, noUpscale: false, percent: 150)
            .renderScale(content: content), 1.5)
    }

    // MARK: - 8. SDR did not move

    func testSDRPathIsByteIdenticalWithOrWithoutAnExplicitNoneKind() throws {
        let pixels = image()
        let plain = ExportPreset(format: .jpeg, bitDepth: 8).exportOptions
        var none = plain
        none.hdr = HDRExport(kind: HDRKind.none)
        XCTAssertEqual(try Exporter.data(pixels, options: plain),
                       try Exporter.data(pixels, options: none))
    }
}
