import XCTest
@testable import PhotonsCore

/// 298 — **the frame → canvas mapping must not carry the decode rung.**
///
/// `FrameTransform`'s S3 canvas is built on the **full-resolution** source (261), while the buffer
/// the renderer decodes can be a lower rung (the loupe shows the 0.5 preview first). The crop frame's
/// rectangle in S5 — the photograph's own rect on the canvas, and the rect the 235 stand-in is
/// placed in — must describe the file, not the buffer. Before this test the two functions still
/// multiplied by `decodedSource / source`, so the same document measured half as wide and half as
/// tall on the 0.5 rung (the reported「切图瞬间占位只有左上四分之一」).
///
/// `LoupeFraming.contentRectInS5` returns exactly `frameRectInS5` (`LoupeZoom.swift`), so these
/// assertions are the rung-independence of the stand-in's rect at its source.
final class FrameTransformRungTests: XCTestCase {

    private static let source = ImageSize(width: 4000, height: 3000)
    private static let crop = CropRect(left: 0.1, top: 0.05, right: 0.85, bottom: 0.95)
    private static let viewport = ImageSize(width: 1600, height: 1200)

    private func transform(degrees: Double, decodeScale: Double) -> FrameTransform {
        FrameTransform(source: Self.source, crop: Self.crop,
                       straightenDegrees: degrees, quarterTurns: 0,
                       decodeScale: decodeScale, contentScale: 1,
                       viewport: Self.viewport, zoom: 1,
                       cameraOffset: .zero, cameraWindowSize: nil)
    }

    private func assertEqual(_ a: Double, _ b: Double, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: 0.5, "\(label) moved with the decode rung once", file: file, line: line)
    }

    private func assertEqualRects(_ a: CGRect, _ b: CGRect, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        assertEqual(a.minX, b.minX, "\(label).x", file: file, line: line)
        assertEqual(a.minY, b.minY, "\(label).y", file: file, line: line)
        assertEqual(a.width, b.width, "\(label).width", file: file, line: line)
        assertEqual(a.height, b.height, "\(label).height", file: file, line: line)
    }

    /// The photograph's rectangle on the canvas — the stand-in's rect — is the same on the 1.0 and
    /// the 0.5 rung, at a right angle and in the straightened case.
    func testTheContentRectDoesNotDependOnTheDecodeRung() {
        for degrees in [0.0, 3.0] {
            let full = transform(degrees: degrees, decodeScale: 1.0)
            let preview = transform(degrees: degrees, decodeScale: 0.5)

            assertEqualRects(full.frameRectInS5(), preview.frameRectInS5(),
                             "contentRectInS5 @ \(degrees)°")

            assertEqual(full.frameOriginInS5.x, preview.frameOriginInS5.x,
                        "frameOriginInS5.x @ \(degrees)°")
            assertEqual(full.frameOriginInS5.y, preview.frameOriginInS5.y,
                        "frameOriginInS5.y @ \(degrees)°")
            assertEqual(full.frameSizeInS5.x, preview.frameSizeInS5.x,
                        "frameSizeInS5.x @ \(degrees)°")
            assertEqual(full.frameSizeInS5.y, preview.frameSizeInS5.y,
                        "frameSizeInS5.y @ \(degrees)°")
        }
    }

    /// The crop tool's quad (the four corners, not just its bounding box) is rung-invariant too —
    /// the same residual factor reached the overlay through `frameQuadInS5`.
    func testTheCropQuadIsRungInvariant() {
        for degrees in [0.0, 3.0] {
            let full = transform(degrees: degrees, decodeScale: 1.0).frameQuadInS5()
            let preview = transform(degrees: degrees, decodeScale: 0.5).frameQuadInS5()
            XCTAssertEqual(full.count, preview.count)

            for (index, (a, b)) in zip(full, preview).enumerated() {
                assertEqual(a.x, b.x, "corner \(index).x @ \(degrees)°")
                assertEqual(a.y, b.y, "corner \(index).y @ \(degrees)°")
            }
        }
    }
}
