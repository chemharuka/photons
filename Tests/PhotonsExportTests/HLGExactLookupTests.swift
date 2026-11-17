import XCTest
import PhotonsCore
@testable import PhotonsExport

final class HLGExactLookupTests: XCTestCase {
    func testEveryHalfFloatCodeAndAlphaUsesTheExistingCurve() throws {
        // Exhaust the domain including subnormals, infinities and NaNs. Add a translucent row
        // to ensure its quantization remains after premultiplication, not before it.
        let count = 65_536
        var rgba = [Float16](repeating: 1, count: count * 2 * 4)
        for i in 0..<(count * 2) {
            let value = Float16(bitPattern: UInt16(i % count))
            rgba[i * 4] = value; rgba[i * 4 + 1] = value; rgba[i * 4 + 2] = value
            rgba[i * 4 + 3] = i < count ? 1 : 0.5
        }
        let linear = LinearPixels(width: count, height: 2, rgba: rgba, primaries: .rec2020)
        let image = DisplayImage(width: count, height: 2, rgba: rgba, primaries: .rec2020, bitDepth: 16)
            .withLinear(linear)
        let converted = try HDREncoding.cgImage(for: image, kind: .hlg)
        let data = try XCTUnwrap(converted.dataProvider?.data) as Data
        data.withUnsafeBytes { bytes in
            let codes = bytes.bindMemory(to: UInt16.self)
            for i in 0..<(count * 2) {
                let signal = HDREncoding.HLGCurve.signal(forLinear: Double(Float(rgba[i * 4])))
                let alpha = i < count ? 1.0 : 0.5
                let expected = UInt16(min(max((signal * alpha * 65535.0).rounded(), 0), 65535))
                XCTAssertEqual(codes[i * 4], expected, "pattern \(i % count), alpha \(alpha)")
                XCTAssertEqual(codes[i * 4 + 1], expected)
                XCTAssertEqual(codes[i * 4 + 2], expected)
            }
        }
    }
}
