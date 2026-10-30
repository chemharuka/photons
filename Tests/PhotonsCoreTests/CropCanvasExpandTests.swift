import XCTest
import PhotonsCore

/// 162 §2.1 / G1 — **画布只在真的旋转时扩**.
///
/// A quarter-turn angle (0 / 90 / 180 / 270, and the 90° multiples a quarter turn adds) leaves the
/// canvas exactly the size of the crop's pixel rect — no padding, no rounding-up border. Only a
/// genuinely non-right angle grows the canvas, and then to the **exact** bounding box of the rotated
/// crop: a single `ceil` on the half-pixel boundary, never `+1`.
///
/// The expected values are computed here from `cos`/`sin` and the crop's pixel edges, independently
/// of `CropMath.canvasSize`.
final class CropCanvasExpandTests: XCTestCase {

    private let source = ImageSize(width: 6000, height: 4000)

    private struct Case {
        var name: String
        var crop: CropRect
    }

    /// 100 %, 90 % (5 % inset on each side), 50 % (centre), and an off-centre custom rect.
    private let cases: [Case] = [
        Case(name: "100%", crop: .full),
        Case(name: "90%", crop: CropRect(left: 0.05, top: 0.05, right: 0.95, bottom: 0.95)),
        Case(name: "50%", crop: CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)),
        Case(name: "custom", crop: CropRect(left: 0.10, top: 0.20, right: 0.73, bottom: 0.60)),
    ]

    private func turned(_ source: ImageSize, turns: Int) -> ImageSize {
        turns % 2 == 0 ? source : ImageSize(width: source.height, height: source.width)
    }

    /// The crop's own pixel size — the only thing a quarter-turn canvas may be.
    private func cropPixels(_ crop: CropRect, in source: ImageSize) -> ImageSize {
        ImageSize(width: Int((Double(source.width) * crop.width).rounded()),
                  height: Int((Double(source.height) * crop.height).rounded()))
    }

    // MARK: - quarter turns: canvas == crop, exactly

    func testZeroAndQuarterTurnAnglesLeaveTheCanvasExactlyTheCropSize() {
        for k in cases {
            for angle in [0.0, 90.0, 180.0, 270.0] {
                let expected = cropPixels(k.crop, in: source)
                let canvas = CropMath.canvasSize(crop: k.crop, in: source,
                                                 straightenDegrees: angle, quarterTurns: 0)
                print("162 G1 · \(k.name) @ \(Int(angle))° · crop \(expected.keyString) "
                      + "→ canvas \(canvas.keyString)")
                XCTAssertEqual(canvas, expected,
                               "\(k.name) @ \(Int(angle))°: a right angle must not expand the canvas")
            }
        }
    }

    /// The user's exact example: 6000×4000, crop 90 % ⇒ canvas == the crop, **not** the source.
    func testNinetyPercentCropAtZeroIsTheCropNotTheSource() {
        let crop = CropRect(left: 0.05, top: 0.05, right: 0.95, bottom: 0.95)
        let canvas = CropMath.canvasSize(crop: crop, in: source, straightenDegrees: 0,
                                         quarterTurns: 0)
        print("162 G1 · 0° · source 6000×4000 · crop 90% → canvas \(canvas.keyString)")
        XCTAssertEqual(canvas, ImageSize(width: 5400, height: 3600))
        XCTAssertNotEqual(canvas, source, "0° must never grow the canvas back to the source")

        // …and the value `CropGeometry.canvas` exposes is the same four edges of the crop.
        var geometry = GeometryGroup.identity
        geometry.crop = crop.normalizedRect
        let carried = CropGeometry(geometry: geometry, source: source)
        XCTAssertEqual(carried.canvas, ImageSize(width: 5400, height: 3600))
        XCTAssertEqual(Double(carried.canvas.width), carried.crop.width * Double(source.width),
                       accuracy: 1e-9)
        XCTAssertEqual(Double(carried.canvas.height), carried.crop.height * Double(source.height),
                       accuracy: 1e-9)
    }

    /// A document-level quarter turn swaps the source before the crop is measured, and the canvas is
    /// still the crop's own size.
    func testDocumentQuarterTurnsKeepTheCanvasAtTheCropSize() {
        for turns in [0, 1, 2, 3] {
            for k in cases {
                let expected = cropPixels(k.crop, in: turned(source, turns: turns))
                let canvas = CropMath.canvasSize(crop: k.crop, in: source,
                                                 straightenDegrees: 0, quarterTurns: turns)
                XCTAssertEqual(canvas, expected,
                               "\(k.name) · quarterTurns \(turns): canvas must be the crop size")
            }
        }
    }

    // MARK: - everything else: the exact bounding box

    /// `ceil` once around the continuous extent, computed here without `CropMath`.
    private func expectedExtent(_ crop: CropRect, in source: ImageSize,
                                degrees: Double) -> ImageSize {
        let w = Double(source.width) * crop.width
        let h = Double(source.height) * crop.height
        let radians = degrees * Double.pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        // The continuous AABB must be contained; the integer canvas is the smallest one that is.
        // The `1e-9` is the half-pixel-boundary snap: 400.00000000000006 is 400, not 401.
        func ceil(_ v: Double) -> Int { max(1, Int((v - 1e-9).rounded(.up))) }
        return ImageSize(width: ceil(w * c + h * s), height: ceil(w * s + h * c))
    }

    func testNonRightAnglesUseTheExactRotatedBoundingBox() {
        for k in cases {
            for angle in [1.0, 8.0, 45.0] {
                let expected = expectedExtent(k.crop, in: source, degrees: angle)
                let canvas = CropMath.canvasSize(crop: k.crop, in: source,
                                                 straightenDegrees: angle, quarterTurns: 0)
                let radians = angle * Double.pi / 180
                let w = Double(source.width) * k.crop.width
                let h = Double(source.height) * k.crop.height
                let continuous = (w * abs(cos(radians)) + h * abs(sin(radians)),
                                  w * abs(sin(radians)) + h * abs(cos(radians)))
                print(String(format: "162 G1 · %@ @ %.0f° · continuous %.3f×%.3f → canvas %@ "
                             + "(expected %@)",
                             k.name, angle, continuous.0, continuous.1,
                             canvas.keyString, expected.keyString))
                XCTAssertEqual(canvas, expected,
                               "\(k.name) @ \(angle)°: canvas is not the exact rotated bounding box")
                // The integer canvas contains the continuous box…
                XCTAssertGreaterThanOrEqual(Double(canvas.width), continuous.0)
                XCTAssertGreaterThanOrEqual(Double(canvas.height), continuous.1)
                // …and it is the *smallest* integer box that does (no stacked +1).
                XCTAssertLessThan(Double(canvas.width), continuous.0 + 1)
                XCTAssertLessThan(Double(canvas.height), continuous.1 + 1)
            }
        }
    }
}
