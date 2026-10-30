import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import PhotonsCore
@testable import PhotonsExport

/// 163 §1.5 — HDR colour spaces are paired with their SDR base family, exactly the way toGainMapHDR
/// does it (`main.swift:78-100`). Every assertion writes a real file and reads the colour space back
/// through `CGImageSourceCopyPropertiesAtIndex` (plus `CIImage.colorSpace`, which is the only stable
/// identity for HEIC/AVIF: their `ProfileName` appends a per-file "HDR Metadata <hash>" suffix).
final class HDRColorSpaceTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hdr-colour-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A small extended-range picture: the linear half peaks at 2.0, so the gain-map path really runs.
    private func image(primaries: OutputPrimaries, width: Int = 32, height: Int = 24) -> DisplayImage {
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

    private func write(_ preset: ExportPreset, _ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        let pixels = image(primaries: preset.colorSpace)
        try Exporter.write(pixels, to: url, options: preset.exportOptions,
                           metadata: ExportMetadataContext(level: .none))
        return url
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func readBackSpace(_ url: URL) throws -> String {
        let ci = try XCTUnwrap(CIImage(contentsOf: url))
        return try XCTUnwrap(ci.colorSpace?.name as String?)
    }

    private struct Row {
        let base: OutputPrimaries
        /// `kCGImagePropertyProfileName` of the SDR base (gain-map file).
        let sdrProfile: String
        let sdrSpace: String
        let pqProfile: String
        let pqSpace: String
        let hlgProfile: String
        let hlgSpace: String
    }

    /// The table's three rows, with the exact strings this OS reads back (probe 2026-10-30).
    private let rows: [Row] = [
        Row(base: .sRGB,
            sdrProfile: "Rec. ITU-R BT.709-5", sdrSpace: "kCGColorSpaceITUR_709",
            pqProfile: "Rec. ITU-R BT.709-5; SMPTE ST 2084 PQ", pqSpace: "kCGColorSpaceITUR_709_PQ",
            hlgProfile: "Rec. ITU-R BT.709-5; ARIB STD-B67 HLG", hlgSpace: "kCGColorSpaceITUR_709_HLG"),
        Row(base: .displayP3,
            sdrProfile: "Display P3", sdrSpace: "kCGColorSpaceDisplayP3",
            pqProfile: "Display P3; SMPTE ST 2084 PQ", pqSpace: "kCGColorSpaceDisplayP3_PQ",
            hlgProfile: "Display P3; ARIB STD-B67 HLG", hlgSpace: "kCGColorSpaceDisplayP3_HLG"),
        Row(base: .rec2020,
            sdrProfile: "Rec. ITU-R BT.2020-1; sRGB Gamma", sdrSpace: "kCGColorSpaceITUR_2020_sRGBGamma",
            pqProfile: "Rec. ITU-R BT.2100 PQ", pqSpace: "kCGColorSpaceITUR_2100_PQ",
            hlgProfile: "Rec. ITU-R BT.2100 HLG", hlgSpace: "kCGColorSpaceITUR_2100_HLG"),
    ]

    /// 3 rows × {gainMap, pq, hlg} = the nine files the task asks for. Gain maps are HEIC (the only
    /// container the table's base spaces are read from), PQ is TIFF and HLG is PNG so the profile
    /// names are the exact, non-hashed ones.
    func testEveryFamilyWritesItsOwnHDRColorSpace() throws {
        for row in rows {
            // gainMap → HEIC, SDR base tagged with the row's SDR space.
            let gain = try write(ExportPreset(format: .heic, bitDepth: 8, colorSpace: row.base,
                                              hdr: HDRExport(kind: .gainMap, gainMap: .iso,
                                                             halfSize: true)),
                                 "gain-\(row.base.rawValue).heic")
            XCTAssertEqual(try properties(gain)[kCGImagePropertyProfileName] as? String,
                           row.sdrProfile, "\(row.base.rawValue) gain-map base profile")
            XCTAssertEqual(try readBackSpace(gain), row.sdrSpace)

            // PQ → TIFF 16.
            let pq = try write(ExportPreset(format: .tiff, bitDepth: 16, colorSpace: row.base,
                                            hdr: HDRExport(kind: .pq)),
                               "pq-\(row.base.rawValue).tif")
            XCTAssertEqual(try properties(pq)[kCGImagePropertyProfileName] as? String,
                           row.pqProfile, "\(row.base.rawValue) PQ profile")
            XCTAssertEqual(try readBackSpace(pq), row.pqSpace)
            XCTAssertEqual((try properties(pq)[kCGImagePropertyDepth] as? NSNumber)?.intValue, 16)

            // HLG → PNG 16.
            let hlg = try write(ExportPreset(format: .png, bitDepth: 16, colorSpace: row.base,
                                             hdr: HDRExport(kind: .hlg)),
                                "hlg-\(row.base.rawValue).png")
            XCTAssertEqual(try properties(hlg)[kCGImagePropertyProfileName] as? String,
                           row.hlgProfile, "\(row.base.rawValue) HLG profile")
            XCTAssertEqual(try readBackSpace(hlg), row.hlgSpace)
            XCTAssertEqual((try properties(hlg)[kCGImagePropertyDepth] as? NSNumber)?.intValue, 16)
        }
    }

    /// The mapping itself: same family in, same family out — never a silent Rec.2100 rewrite.
    func testTargetColorSpaceComesFromTheBaseFamily() throws {
        XCTAssertEqual(HDREncoding.sdrColorSpace(for: .sRGB)?.name as String?,
                       "kCGColorSpaceITUR_709")
        XCTAssertEqual(HDREncoding.sdrColorSpace(for: .displayP3)?.name as String?,
                       "kCGColorSpaceDisplayP3")
        XCTAssertEqual(HDREncoding.sdrColorSpace(for: .rec2020)?.name as String?,
                       "kCGColorSpaceITUR_2020_sRGBGamma")
        XCTAssertEqual(HDREncoding.targetColorSpace(for: .sRGB, kind: .pq)?.name as String?,
                       "kCGColorSpaceITUR_709_PQ")
        XCTAssertEqual(HDREncoding.targetColorSpace(for: .displayP3, kind: .pq)?.name as String?,
                       "kCGColorSpaceDisplayP3_PQ")
        XCTAssertEqual(HDREncoding.targetColorSpace(for: .rec2020, kind: .pq)?.name as String?,
                       "kCGColorSpaceITUR_2100_PQ")
        XCTAssertEqual(HDREncoding.targetColorSpace(for: .sRGB, kind: .hlg)?.name as String?,
                       "kCGColorSpaceITUR_709_HLG")
        XCTAssertEqual(HDREncoding.targetColorSpace(for: .displayP3, kind: .hlg)?.name as String?,
                       "kCGColorSpaceDisplayP3_HLG")
        XCTAssertEqual(HDREncoding.targetColorSpace(for: .rec2020, kind: .hlg)?.name as String?,
                       "kCGColorSpaceITUR_2100_HLG")
        XCTAssertNil(HDREncoding.targetColorSpace(for: .sRGB, kind: .gainMap))
    }

    /// Three cross-family presets must throw, not be rewritten into the base family.
    func testCrossFamilyPairsAreRejected() {
        let cases: [(base: OutputPrimaries, target: OutputPrimaries, kind: HDRKind, bits: Int)] = [
            (.displayP3, .rec2020, .pq, 10),
            (.sRGB, .rec2020, .hlg, 10),
            (.rec2020, .displayP3, .gainMap, 8),
        ]
        for c in cases {
            let preset = ExportPreset(format: .heic, bitDepth: c.bits, colorSpace: c.base,
                                      hdr: HDRExport(kind: c.kind, targetColorSpace: c.target))
            XCTAssertThrowsError(try preset.validated(),
                                 "\(c.base.rawValue) + \(c.target.rawValue) \(c.kind.rawValue)") {
                guard case ExportPresetError.hdrColorSpaceMismatch(let base, let target, let kind) = $0
                else { return XCTFail("expected hdrColorSpaceMismatch, got \($0)") }
                XCTAssertEqual(base, c.base)
                XCTAssertEqual(target, c.target)
                XCTAssertEqual(kind, c.kind)
            }
        }
        // An explicit target that agrees with the base is legal.
        let ok = ExportPreset(format: .heic, bitDepth: 10, colorSpace: .displayP3,
                              hdr: HDRExport(kind: .pq, targetColorSpace: .displayP3))
        XCTAssertNoThrow(try ok.validated())
    }
}
