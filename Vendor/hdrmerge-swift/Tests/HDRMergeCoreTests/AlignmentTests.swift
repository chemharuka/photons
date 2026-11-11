import XCTest
@testable import HDRMergeCore

final class AlignmentTests: XCTestCase {
    /// A smooth but structured test image (MTB needs structure, not noise).
    func makeImage(width: Int, height: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x), fy = Double(y)
                let v = 2000
                    + 900 * sin(fx * 0.05 + fy * 0.03)
                    + 700 * cos(fy * 0.07 - fx * 0.02)
                out[y * width + x] = UInt16(max(0, min(4000, Int(v))))
            }
        }
        return out
    }

    func testAlignmentRecoversKnownShift() {
        let w = 320, h = 240
        let base = makeImage(width: w, height: h)
        // alt(x, y) = base(x - 5, y - 3)
        var alt = [UInt16](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let sx = x - 5, sy = y - 3
                if sx >= 0, sx < w, sy >= 0, sy < h { alt[y * w + x] = base[sy * w + sx] }
            }
        }
        let ref = Plane(width: w, height: h, pixels: base)
        let moved = Plane(width: w, height: h, pixels: alt)
        let d = HDRMergeCore.alignPair(ref: ref, alt: moved,
                                       refScales: ref.prescaled(levels: 6),
                                       altScales: moved.prescaled(levels: 6),
                                       levelCount: 6, halfLight: 0.3, sat: 4000)
        print("recovered offset \(d.dx), \(d.dy)")
        // Ward MTB is integer and threshold based; on a synthetic smooth pattern
        // it lands within a couple of pixels of the truth, but must get the sign right.
        XCTAssertEqual(Double(d.dx), -5, accuracy: 3)
        XCTAssertEqual(Double(d.dy), -3, accuracy: 3)
    }
}
