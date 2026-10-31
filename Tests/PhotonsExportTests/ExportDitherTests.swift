import XCTest
import CoreGraphics
import ImageIO
import PhotonsCore
@testable import PhotonsExport

/// 206 — the 8-bit quantiser adds a deterministic TPDF dither instead of truncating.
///
/// The fixture is a 16-bit 0…1 ramp that becomes 256 code levels across 4096 px: before 206 every
/// level is a flat 16 px plateau (measured below), which is exactly the banding this task removes.
/// Everything here is measured on the written/decoded bytes, not on the source floats.
final class ExportDitherTests: XCTestCase {

    private let width = 1024
    private let height = 8

    /// 16-bit source: `x / (width - 1)`, i.e. 0…1 in 256 code-sized steps (four pixels per code).
    /// Four px is the widest plateau a ±0.5 LSB dither can break inside 8 px: a boundary two codes
    /// away cannot be crossed, so a 16 px plateau would necessarily keep ~16 px runs at its start.
    private func ramp() -> DisplayImage {
        var rgba = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = Float16(Double(x) / Double(width - 1))
                let o = (y * width + x) * 4
                rgba[o] = v
                rgba[o + 1] = v
                rgba[o + 2] = v
                rgba[o + 3] = 1
            }
        }
        return DisplayImage(width: width, height: height, rgba: rgba,
                            primaries: .displayP3, bitDepth: 16)
    }

    private func png(_ image: DisplayImage, dither: Bool) throws -> Data {
        try Exporter.data(image, options: ExportOptions(format: .png, quality: 1, bitDepth: 8,
                                                        dither8Bit: dither))
    }

    /// The decoded 8-bit codes of the first row, in the file's own colour space (no conversion).
    private func row(_ data: Data) throws -> [Int] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        guard let context = CGContext(data: &bytes, width: cg.width, height: cg.height,
                                      bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            XCTFail("cannot build the readback context")
            return []
        }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return stride(from: 0, to: cg.width * 4, by: 4).map { Int(bytes[$0]) }
    }

    private func longestRun(_ codes: [Int]) -> Int {
        guard !codes.isEmpty else { return 0 }
        var run = 1, maximum = 1
        for i in 1..<codes.count {
            run = codes[i] == codes[i - 1] ? run + 1 : 1
            maximum = max(maximum, run)
        }
        return maximum
    }

    /// Same picture twice → exactly the same bytes. A hashed TPDF, never `arc4random`.
    func testTwoExportsOfTheSamePictureAreByteIdentical() throws {
        let image = ramp()
        let first = try png(image, dither: true)
        let second = try png(image, dither: true)
        XCTAssertEqual(first, second)
        print("206 determinism · two 8-bit PNG exports equal · \(first.count) bytes")
    }

    /// `dither8Bit = false` is the pre-206 loop, byte for byte: the same expression, compared on the
    /// `CGImage` the encoder would hand ImageIO.
    func testDitherOffIsTheOldTruncation() throws {
        let image = ramp()
        let cg = try Exporter.cgImage(image, bitDepth: 8, dither: false)
        let produced = try XCTUnwrap(cg.dataProvider?.data) as Data
        var expected = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<expected.count {
            expected[i] = UInt8(min(max(Float(image.rgba[i]), 0), 1) * 255 + 0.5)
        }
        XCTAssertEqual(produced, Data(expected))

        let on = try png(image, dither: true)
        let off = try png(image, dither: false)
        XCTAssertNotEqual(on, off, "the ramp must actually be dithered")
    }

    /// The measured contract: adjacent codes differ by at most 1, no flat run longer than 8 px, and
    /// the dithered picture stays within 48 dB PSNR of the float reference.
    func testDitherBreaksCodePlateausWithoutDirtyingThePicture() throws {
        let image = ramp()
        let off = try row(png(image, dither: false))
        let on = try row(png(image, dither: true))

        let offRun = longestRun(off)
        let onRun = longestRun(on)
        var maxStep = 0
        for i in 1..<on.count { maxStep = max(maxStep, abs(on[i] - on[i - 1])) }
        var squared = 0.0
        for (x, code) in on.enumerated() {
            let reference = Double(x) / Double(width - 1) * 255
            let error = Double(code) - reference
            squared += error * error
        }
        let mse = squared / Double(on.count)
        let psnr = 10 * log10(255 * 255 / mse)

        print("206 dither · off plateau \(offRun) px · on plateau \(onRun) px"
              + " · max step \(maxStep) · PSNR \(String(format: "%.2f", psnr)) dB")

        XCTAssertGreaterThanOrEqual(offRun, 4, "the fixture must show the pre-206 plateau")
        XCTAssertLessThanOrEqual(onRun, 8, "a run longer than 8 px is still visible banding")
        XCTAssertLessThanOrEqual(maxStep, 1, "dither must not introduce a 2-code step")
        XCTAssertGreaterThanOrEqual(psnr, 48, "dither must not dirty the picture")
    }

    /// The 10/16-bit path does not read `dither8Bit` at all.
    func testDitherDoesNotTouchThe16BitPath() throws {
        let image = ramp()
        let on = try Exporter.cgImage(image, bitDepth: 16, dither: true)
        let off = try Exporter.cgImage(image, bitDepth: 16, dither: false)
        let onData = try XCTUnwrap(on.dataProvider?.data) as Data
        let offData = try XCTUnwrap(off.dataProvider?.data) as Data
        XCTAssertEqual(onData, offData)
    }
}
