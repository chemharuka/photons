import XCTest
import CoreGraphics
import CoreImage
import ImageIO
import PhotonsCore
@testable import PhotonsExport

/// 238 — every export path must agree on **orientation**.
///
/// The fixture is deliberately asymmetric: four quadrants, four colours, written top-row first.
/// A vertical flip therefore turns it into a different picture instead of a symmetric one that
/// would pass by accident.
///
/// `SDR` is the reference. 233 measured SDR/HLG/gain-map upright and PQ upside down; this suite
/// pins all of them to the SDR row order and proves the detection is sensitive by re-writing the
/// old (flipped) PQ encode in a reverse-gate test.
final class ExportOrientationTests: XCTestCase {

    // MARK: - fixture

    /// An 8×8 four-quadrant picture (4×4 per colour). Each quadrant is sampled in its 2×2 centre
    /// so a lossy 4:2:0 container cannot mislead the classifier with edge/chroma bleed; the
    /// HEIC/AVIF rows of this suite exercise exactly that at quality 1.0.
    enum Quadrant: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    enum Colour: String {
        case red, green, blue, white, unknown
    }

    static let side = 8

    /// Display-encoded (SDR) and linear samples for the same quadrant picture.
    ///
    /// The linear corners are 4× SDR white, which keeps the gain-map path on its HDR branch
    /// (`peak > 1.05`) and inside HLG's 4.926× ceiling.
    private func fixture() -> DisplayImage {
        let w = Self.side, h = Self.side
        var display = [Float16](repeating: 1, count: w * h * 4)
        var linear = [Float16](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let top = y < h / 2
                let left = x < w / 2
                let sdr: (Float, Float, Float)
                switch (top, left) {
                case (true, true): sdr = (1, 0, 0)      // TL red
                case (true, false): sdr = (0, 1, 0)     // TR green
                case (false, true): sdr = (0, 0, 1)     // BL blue
                case (false, false): sdr = (1, 1, 1)    // BR white
                }
                let o = (y * w + x) * 4
                display[o] = Float16(sdr.0)
                display[o + 1] = Float16(sdr.1)
                display[o + 2] = Float16(sdr.2)
                display[o + 3] = 1
                linear[o] = Float16(sdr.0 * 4)
                linear[o + 1] = Float16(sdr.1 * 4)
                linear[o + 2] = Float16(sdr.2 * 4)
                linear[o + 3] = 1
            }
        }
        let base = DisplayImage(width: w, height: h, rgba: display, primaries: .sRGB, bitDepth: 8)
        return base.withLinear(LinearPixels(width: w, height: h, rgba: linear,
                                            primaries: .sRGB))
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-orientation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func url(_ dir: URL, _ name: String, _ format: ExportFormat) -> URL {
        dir.appendingPathComponent("\(name).\(format.fileExtension)")
    }

    // MARK: - export

    /// SDR through the pre-HDR path (`Exporter.write`, no `hdr`).
    private func writeSDR(_ image: DisplayImage, to url: URL) throws {
        try Exporter.write(image, to: url,
                           options: ExportOptions(format: .png, quality: 1.0, bitDepth: 16),
                           metadata: ExportMetadataContext(level: .none))
    }

    private func writeHDR(_ image: DisplayImage, format: ExportFormat, kind: HDRKind,
                          to url: URL) throws {
        let bitDepth: Int
        switch kind {
        case .hlg, .pq:
            bitDepth = try XCTUnwrap(format.hdrTransferBitDepth(for: kind))
        case .gainMap:
            // The gain map's depth is the SDR base's (10 for HEIC).
            bitDepth = format.supports10Bit ? 10 : 8
        case .none:
            bitDepth = 8
        }
        var preset = ExportPreset(format: format, quality: 1.0, bitDepth: bitDepth,
                                  colorSpace: .sRGB, hdrKind: kind)
        if kind == .gainMap {
            preset.hdr?.gainMap = .iso
            preset.hdr?.halfSize = true
        }
        preset = try preset.validated()
        XCTAssertEqual(preset.effectiveBitDepth, bitDepth)
        try Exporter.write(image, to: url, options: preset.exportOptions,
                           metadata: ExportMetadataContext(level: .none))
    }

    // MARK: - read back

    /// Premultiplied RGBA16, drawn in the file's **own** colour space (no colour management), so
    /// the sample is the code the container stored. Row 0 is the top row, the same order the
    /// fixture was written in.
    private struct Bitmap {
        let width: Int
        let height: Int
        let space: String
        let pixels: [UInt16]

        func mean(_ q: Quadrant) -> (Double, Double, Double) {
            let left = q == .topLeft || q == .bottomLeft
            let top = q == .topLeft || q == .topRight
            let halfW = width / 2, halfH = height / 2
            let x0 = (left ? 0 : halfW) + halfW / 4
            let x1 = (left ? halfW : width) - halfW / 4
            let y0 = (top ? 0 : halfH) + halfH / 4
            let y1 = (top ? halfH : height) - halfH / 4
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let o = (y * width + x) * 4
                    r += Double(pixels[o]) / 65535.0
                    g += Double(pixels[o + 1]) / 65535.0
                    b += Double(pixels[o + 2]) / 65535.0
                    n += 1
                }
            }
            return (r / n, g / n, b / n)
        }
    }

    private func read(_ url: URL) throws -> Bitmap {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let w = cg.width, h = cg.height
        let space = try XCTUnwrap(cg.colorSpace, "no colour space in \(url.lastPathComponent)")
        var buf = [UInt16](repeating: 0, count: w * h * 4)
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
        try buf.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(data: raw.baseAddress, width: w, height: h,
                                              bitsPerComponent: 16, bytesPerRow: w * 8,
                                              space: space, bitmapInfo: info))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return Bitmap(width: w, height: h,
                      space: cg.colorSpace?.name as String? ?? "?", pixels: buf)
    }

    private func colour(_ rgb: (Double, Double, Double)) -> Colour {
        let (r, g, b) = rgb
        let hi = max(r, g, b), lo = min(r, g, b)
        guard hi > 0.02 else { return .unknown }
        if hi - lo <= hi * 0.25 { return .white }
        if r >= g && r >= b { return .red }
        if g >= r && g >= b { return .green }
        if b >= r && b >= g { return .blue }
        return .unknown
    }

    private func labels(_ url: URL, _ name: String) throws -> [Quadrant: Colour] {
        let bitmap = try read(url)
        var out: [Quadrant: Colour] = [:]
        for q in Quadrant.allCases {
            let rgb = bitmap.mean(q)
            out[q] = colour(rgb)
            print(String(format: "238 · %@ %@ = %@ (r %.3f g %.3f b %.3f)",
                         name, String(describing: q), colour(rgb).rawValue,
                         rgb.0, rgb.1, rgb.2))
        }
        return out
    }

    private let upright: [Quadrant: Colour] = [
        .topLeft: .red, .topRight: .green, .bottomLeft: .blue, .bottomRight: .white,
    ]

    /// Compare every quadrant to the SDR baseline (which is itself pinned to the fixture).
    private func assertSameAsSDR(_ url: URL, _ name: String,
                                 baseline: [Quadrant: Colour],
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let got = try labels(url, name)
        for q in Quadrant.allCases {
            XCTAssertEqual(got[q], baseline[q],
                           "\(name) \(q): \(got[q]?.rawValue ?? "nil") vs SDR "
                           + "\(baseline[q]?.rawValue ?? "nil")",
                           file: file, line: line)
        }
    }

    // MARK: - 1. the baseline (also calibrates the reader)

    func testSDRBaselineIsTopRowFirst() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = url(dir, "sdr", .png)
        try writeSDR(fixture(), to: out)
        let got = try labels(out, "sdr-png16")
        for q in Quadrant.allCases {
            XCTAssertEqual(got[q], upright[q], "SDR PNG16 \(q)")
        }
    }

    // MARK: - 2. PQ in every container

    func testPQPartsAgreeWithSDR() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = fixture()
        let sdr = url(dir, "sdr-pq", .png)
        try writeSDR(image, to: sdr)
        let baseline = try labels(sdr, "sdr-pq-baseline")

        for format in [ExportFormat.png, .tiff, .heic, .avif] {
            let out = url(dir, "pq-\(format.rawValue)", format)
            try writeHDR(image, format: format, kind: .pq, to: out)
            try assertSameAsSDR(out, "pq-\(format.rawValue)", baseline: baseline)
        }
    }

    // MARK: - 3. HLG

    func testHLGPartsAgreeWithSDR() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = fixture()
        let sdr = url(dir, "sdr-hlg", .png)
        try writeSDR(image, to: sdr)
        let baseline = try labels(sdr, "sdr-hlg-baseline")

        for format in [ExportFormat.png, .tiff, .heic] {
            let out = url(dir, "hlg-\(format.rawValue)", format)
            try writeHDR(image, format: format, kind: .hlg, to: out)
            try assertSameAsSDR(out, "hlg-\(format.rawValue)", baseline: baseline)
        }
    }

    // MARK: - 4. gain map's primary image

    func testGainMapMainImageAgreesWithSDR() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = fixture()
        let sdr = url(dir, "sdr-gainmap", .png)
        try writeSDR(image, to: sdr)
        let baseline = try labels(sdr, "sdr-gainmap-baseline")

        let out = url(dir, "gainmap", .heic)
        try writeHDR(image, format: .heic, kind: .gainMap, to: out)
        let got = try labels(out, "gainmap-heic")
        for q in Quadrant.allCases {
            XCTAssertEqual(got[q], baseline[q], "gain map main image \(q)")
        }
    }

    // MARK: - 5. reverse gate: the old flipped PQ encode must be detected

    /// Re-creates the pre-238 PQ path (`HDREncoding`'s row flip in front of `CIImage(bitmapData:)`)
    /// locally. If the green assertions above would pass this file too, the suite is blind; the
    /// test proves it sees the flip.
    func testOldFlippedPQEncodeFailsTheOrientationGate() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = fixture()
        let sdr = url(dir, "sdr-gate", .png)
        try writeSDR(image, to: sdr)
        let baseline = try labels(sdr, "sdr-gate-baseline")

        let out = url(dir, "pq-flipped", .png)
        try writeFlippedPQ(image, to: out)
        let got = try labels(out, "pq-flipped")
        let expectedFlipped: [Quadrant: Colour] = [
            .topLeft: .blue, .topRight: .white, .bottomLeft: .red, .bottomRight: .green,
        ]
        XCTAssertEqual(got, expectedFlipped, "the reverse-gate file must be vertically mirrored")
        XCTAssertNotEqual(got, baseline, "the orientation gate must reject the old PQ encode")
    }

    /// The pre-238 PQ encode, kept only for the reverse gate.
    private func writeFlippedPQ(_ image: DisplayImage, to url: URL) throws {
        let linear = try XCTUnwrap(image.linear)
        let w = linear.width, h = linear.height
        var rows = [Float16](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let from = y * w * 4
            let to = (h - 1 - y) * w * 4
            for i in 0..<(w * 4) { rows[to + i] = linear.rgba[from + i] }
        }
        let source = try XCTUnwrap(HDREncoding.linearColorSpace(for: image.primaries))
        let target = try XCTUnwrap(HDREncoding.targetColorSpace(for: image.primaries, kind: .pq))
        let data = rows.withUnsafeBufferPointer { Data(buffer: $0) }
        let ci = CIImage(bitmapData: data, bytesPerRow: w * 8,
                         size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: source)
        let context = CIContext(options: [.workingColorSpace: source, .outputColorSpace: target])
        let cg = try XCTUnwrap(context.createCGImage(ci, from: ci.extent, format: .RGBA16,
                                                     colorSpace: target))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, ExportFormat.png.utType.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
