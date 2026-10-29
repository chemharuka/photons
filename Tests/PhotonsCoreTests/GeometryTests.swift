import XCTest
import PhotonsCore

/// 123 — `CropGeometry` is the single rotation/rect/canvas value the overlay and S0 share.
final class GeometryTests: XCTestCase {

    private let source = ImageSize(width: 4000, height: 3000)

    /// y-down pixels: +90° takes the right vector to *down* — clockwise on screen.
    func testPositiveRotationIsClockwiseOnScreen() {
        let rotation = CropGeometry.RotationMatrix(degrees: 90)
        let right = rotation.apply(x: 1, y: 0)
        XCTAssertEqual(right.x, 0, accuracy: 1e-12)
        XCTAssertEqual(right.y, 1, accuracy: 1e-12)

        let back = rotation.invert(x: right.x, y: right.y)
        XCTAssertEqual(back.x, 1, accuracy: 1e-12)
        XCTAssertEqual(back.y, 0, accuracy: 1e-12)
    }

    func testGeometryCarriesCropCanvasAndSource() {
        var geometry = GeometryGroup.identity
        geometry.cropRect = CropRect(left: 0.1, top: 0.2, right: 0.6, bottom: 0.7)
        geometry.rotationDegrees = -12.5
        let carried = CropGeometry(geometry: geometry, source: source)

        XCTAssertEqual(carried.rotationDegrees, -12.5, accuracy: 1e-12)
        XCTAssertEqual(carried.crop, geometry.renderCrop(source: source))
        XCTAssertEqual(carried.canvas, CropMath.outputSize(carried.crop, in: source))
        XCTAssertEqual(carried.source, source)
        XCTAssertEqual(carried.cosine, cos(-12.5 * .pi / 180), accuracy: 1e-12)
        XCTAssertEqual(carried.sine, sin(-12.5 * .pi / 180), accuracy: 1e-12)
    }

    /// A quarter turn swaps the canvas, and the crop stays a rectangle of the *turned* frame.
    func testQuarterTurnCarriesTheOrientedCanvas() {
        let geometry = GeometryGroup(crop: .full, rotationDegrees: 0,
                                     quarterTurns: 1)
        let carried = CropGeometry(geometry: geometry, source: source)
        XCTAssertEqual(carried.source, ImageSize(width: 3000, height: 4000))
        XCTAssertEqual(carried.canvas, ImageSize(width: 3000, height: 4000))
        XCTAssertEqual(carried.quarterTurns, 1)
    }

    func testNoRotationIsTheIdentityMatrix() {
        let carried = CropGeometry(geometry: .identity, source: source)
        XCTAssertTrue(carried.isIdentityRotation)
        XCTAssertEqual(carried.cosine, 1)
        XCTAssertEqual(carried.sine, 0)
        XCTAssertEqual(carried.canvas, source)
    }
}
