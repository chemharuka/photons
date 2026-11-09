import XCTest
import PhotonsCore

/// 162 / 301 — **画布 = 裁切帧本身**.
///
/// 301 (方案 A) reversed 162's "a real angle grows the canvas" rule. The output is the rotated crop
/// frame, so every angle (right or not) leaves the canvas exactly the crop's pixel rect — no AABB,
/// no padding. The rotated AABB still exists as the crop's **legal region**
/// (`CropGeometry.rotatedExtent`), with a single `ceil` on the half-pixel boundary; it is no longer
/// the output texture. The expected values are computed from `cos`/`sin` and the crop's pixel edges,
/// independently of `CropMath.canvasSize`.
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

    // MARK: - everything else: the crop frame

    /// 301 (方案 A) — a non-right angle **does not grow the canvas any more**: the output is the
    /// rotated crop frame itself, so the canvas stays the crop's `W × H`. The rotated AABB still
    /// exists, but only as the frame's legal region (`CropGeometry.rotatedExtent`), not as the
    /// output texture. The user's 162 rule is therefore now "a right angle and every other angle
    /// both keep the crop frame"; the old AABB formula moved to the document-canvas side.
    func testNonRightAnglesKeepTheCropFrameAndTheAABBIsOnlyTheLegalRegion() {
        for k in cases {
            for angle in [1.0, 8.0, 45.0] {
                let expected = cropPixels(k.crop, in: source)
                let canvas = CropMath.canvasSize(crop: k.crop, in: source,
                                                 straightenDegrees: angle, quarterTurns: 0)
                let radians = angle * Double.pi / 180
                let w = Double(source.width) * k.crop.width
                let h = Double(source.height) * k.crop.height
                let continuous = (w * abs(cos(radians)) + h * abs(sin(radians)),
                                  w * abs(sin(radians)) + h * abs(cos(radians)))
                let legal = CropGeometry.rotatedExtent(width: w, height: h, degrees: angle)
                print(String(format: "301 · %@ @ %.0f° · canvas %@ · rotated AABB %.3f×%.3f",
                             k.name, angle, canvas.keyString, continuous.0, continuous.1))
                XCTAssertEqual(canvas, expected,
                               "\(k.name) @ \(angle)°: canvas must be the crop frame itself")
                // The AABB is the legal region: it contains the frame to within the one `ceil` and
                // agrees with the formula `|w·cos| + |h·sin|` independently of the canvas rule.
                XCTAssertEqual(legal.width, continuous.0, accuracy: 1e-9)
                XCTAssertEqual(legal.height, continuous.1, accuracy: 1e-9)
                XCTAssertGreaterThanOrEqual(legal.width + 1e-9, Double(canvas.width))
                XCTAssertGreaterThanOrEqual(legal.height + 1e-9, Double(canvas.height))
            }
        }
    }
}
