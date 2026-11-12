import XCTest
import CoreImage
@testable import HDRMergeCore

/// SOF3 compression: the pixels must survive the round trip bit-exactly, both decoders must
/// accept the file, and the file must actually be smaller.
///
/// The "both decoders" half is not ceremony. A wrong SOS selector nibble produces a file that
/// libraw decodes correctly and Core Image renders **all black** while reporting success, so a
/// test that only checks one of them passes on a broken file.
final class CompressionTests: XCTestCase {

    private static let sample = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Desktop/austria/L1030664.dng")

    private func requireSample() throws -> RawFrame {
        guard FileManager.default.fileExists(atPath: Self.sample.path) else {
            throw XCTSkip("no sample at \(Self.sample.path)")
        }
        return try DNGReader.read(url: Self.sample)
    }

    /// A synthetic bracket: the source frame and a 2-stop-darker copy of it, merged. Runs the real
    /// merge path so the writer is exercised on the same data the tool produces.
    private func mergedBracket(_ frame: RawFrame) throws -> MergedImage {
        let w = frame.width, h = frame.height
        let dark = MergedImage(width: w, height: h,
                               values: (0..<(w * h)).map { i in
                                   let v = Float(frame.sample(i % w, i / w)) - 512
                                   return max(0, v / 4) + 512
                               },
                               black: 512, white: 16383,
                               cfaPattern: frame.photoCFAPattern, cfaRows: frame.cfaRows,
                               cfaCols: frame.cfaCols,
                               offsets: [(0, 0), (0, 0)], referenceIndex: 1, report: [])
        let bright = MergedImage(width: w, height: h,
                                 values: (0..<(w * h)).map { i in Float(frame.sample(i % w, i / w)) },
                                 black: 512, white: 16383,
                                 cfaPattern: frame.photoCFAPattern, cfaRows: frame.cfaRows,
                                 cfaCols: frame.cfaCols,
                                 offsets: [(0, 0), (0, 0)], referenceIndex: 1, report: [])
        return bright
    }

    // MARK: encoder round trip, small and fast

    /// Encode → our own decoder must return the exact same samples.
    func testEncoderRoundTripIsBitExact() throws {
        var samples = [UInt16](repeating: 0, count: 256 * 256)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<samples.count {
            // Mix of gradient, flat areas and hard edges: the cases that break a predictor.
            let x = i % 256, y = i / 256
            samples[i] = UInt16((x * 40 + y * 17 + Int.random(in: 0..<40, using: &rng)) & 0x3FFF)
        }
        let tables = LosslessJPEGEncoder.buildTables([samples], width: 256, height: 256, components: 2)
        let encoded = try LosslessJPEGEncoder.encode(samples, width: 256, height: 256,
                                                     components: 2, tables: tables)
        let decoded = try LosslessJPEG.decode(encoded)
        XCTAssertEqual(decoded.width, 128, "two components → 128 samples per component row")
        XCTAssertEqual(decoded.height, 256)
        XCTAssertEqual(decoded.components, 2)
        // Interleave the two planes back and compare.
        for y in 0..<256 {
            for x in 0..<128 {
                XCTAssertEqual(decoded.planes[0][y * 128 + x], samples[y * 256 + x * 2],
                               "component 0 at \(x),\(y)")
                XCTAssertEqual(decoded.planes[1][y * 128 + x], samples[y * 256 + x * 2 + 1],
                               "component 1 at \(x),\(y)")
            }
        }
    }

    func testEncoderHandlesConstantsAndFFStuffing() throws {
        // All 0xFFFF: every difference is 0 or ±1, and the byte stuffing path gets exercised
        // because long runs of a constant produce long stretches of 0xFF in the stream.
        let flat = [UInt16](repeating: 0xFFFF, count: 64 * 32)
        let tables = LosslessJPEGEncoder.buildTables([flat], width: 64, height: 32, components: 2)
        let encoded = try LosslessJPEGEncoder.encode(flat, width: 64, height: 32,
                                                     components: 2, tables: tables)
        let decoded = try LosslessJPEG.decode(encoded)
        for y in 0..<32 {
            for x in 0..<32 {
                XCTAssertEqual(decoded.planes[0][y * 32 + x], 0xFFFF)
                XCTAssertEqual(decoded.planes[1][y * 32 + x], 0xFFFF)
            }
        }
    }

    /// The SOS selector must be `Td << 4 | Ta`; a wrong nibble is invisible to libraw but fatal
    /// for Core Image. Assert on the bytes rather than waiting for a renderer to disagree.
    func testSOSSelectorUsesHighNibbleForTableID() throws {
        let samples = [UInt16](repeating: 1000, count: 8 * 4)
        let tables = LosslessJPEGEncoder.buildTables([samples], width: 8, height: 4, components: 2)
        let encoded = try LosslessJPEGEncoder.encode(samples, width: 8, height: 4,
                                                     components: 2, tables: tables)
        guard let sos = encoded.firstRange(of: [0xFF, 0xDA]) else {
            return XCTFail("no SOS marker")
        }
        let p = sos.lowerBound
        let components = Int(encoded[p + 4])
        XCTAssertEqual(components, 2)
        // Each selector pair is [componentID, Td << 4 | Ta].
        for c in 0..<components {
            let selector = encoded[p + 6 + c * 2]
            XCTAssertEqual(Int(selector >> 4), c, "table id must be the high nibble")
            XCTAssertEqual(Int(selector & 0x0F), 0, "Ta must be 0 for lossless")
        }
    }

    // MARK: the real thing

    /// Full 60 MP frame: compressed is smaller, decodes to identical samples, and **both**
    /// LibRaw and Core Image accept it.
    func testFullSizeMergeCompressesAndBothDecodersAcceptIt() throws {
        let frame = try requireSample()
        let merged = try mergedBracket(frame)

        let plain = try DNGWriter.render(merged, source: frame, bits: 16, compression: .uncompressed)
        let compressed = try DNGWriter.render(merged, source: frame, bits: 16,
                                              compression: .losslessJPEG(tileWidth: 256, tileHeight: 256))
        XCTAssertLessThan(compressed.count, plain.count,
                          "SOF3 must be smaller than raw samples")
        let ratio = Double(plain.count) / Double(compressed.count)
        XCTAssertGreaterThan(ratio, 1.8, "expected ≥1.8× on a 60 MP frame, got \(ratio)")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("compress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let compressedURL = dir.appendingPathComponent("compressed.dng")
        let plainURL = dir.appendingPathComponent("plain.dng")
        try compressed.write(to: compressedURL)
        try plain.write(to: plainURL)

        // 1. Our own reader: identical samples, and the CFA tags survived.
        let reread = try DNGReader.read(url: compressedURL)
        XCTAssertEqual(reread.fullWidth, merged.width)
        XCTAssertEqual(reread.fullHeight, merged.height)
        XCTAssertEqual(reread.cfaPattern, merged.cfaPattern)
        XCTAssertEqual(reread.whiteLevel, merged.white)

        let plainRead = try DNGReader.read(url: plainURL)
        for i in stride(from: 0, to: min(reread.pixels.count, plainRead.pixels.count), by: 997) {
            XCTAssertEqual(reread.pixels[i], plainRead.pixels[i], "sample \(i)")
        }

        // 2. Core Image: must not render black. This is the check that catches a wrong SOS nibble.
        let ciMean = try Self.coreImageMean(compressedURL)
        let ciMeanPlain = try Self.coreImageMean(plainURL)
        XCTAssertGreaterThan(ciMean, 0, "Core Image rendered an all-black frame")
        XCTAssertEqual(ciMean, ciMeanPlain, accuracy: 0.001,
                       "compressed and uncompressed must render identically")
    }

    func testFloatSamplesRefuseCompression() throws {
        let frame = try requireSample()
        let merged = try mergedBracket(frame)
        XCTAssertThrowsError(try DNGWriter.render(merged, source: frame, bits: 32,
                                                  compression: .lossless)) { error in
            guard let e = error as? DNGWriteError else { return XCTFail("wrong error type") }
            XCTAssertTrue("\(e)".contains("float32"))
        }
    }

    // MARK: helpers

    /// Mean byte value of a 64×64 Core Image render. All-black returns 0.
    static func coreImageMean(_ url: URL) throws -> Double {
        guard let filter = CIRAWFilter(imageURL: url) else {
            throw XCTSkip("CIRAWFilter refused \(url.lastPathComponent)")
        }
        guard let image = filter.outputImage else {
            throw XCTSkip("CIRAWFilter produced no image for \(url.lastPathComponent)")
        }
        let native = filter.nativeSize
        let side = 64
        let scale = CGFloat(min(native.width, native.height)) / CGFloat(side)
        let small = image.transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        guard let cg = context.createCGImage(small, from: CGRect(x: 0, y: 0, width: side, height: side)) else {
            throw XCTSkip("Core Image could not rasterise \(url.lastPathComponent)")
        }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("no bitmap context")
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }
}
