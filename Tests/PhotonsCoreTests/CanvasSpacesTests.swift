import XCTest
import PhotonsCore

/// 2026-11-01 — the four spaces of a rotated crop, in one place.
///
/// Every assertion here is about *agreement*: the new `CropGeometry` API must reproduce the numbers
/// the renderer has always used (so no pixel moves), and the relations it claims between the four
/// rectangles must hold at every angle, including the right angles where they collapse.
final class CanvasSpacesTests: XCTestCase {

    private let sources = [ImageSize(width: 4000, height: 3000),
                           ImageSize(width: 701, height: 503),
                           ImageSize(width: 3000, height: 4000)]
    private let crops = [CropRect.full,
                         CropRect(left: 0.1, top: 0.2, right: 0.7, bottom: 0.6),
                         CropRect(left: 0.2, top: 0.1, right: 0.6, bottom: 0.7),
                         // 132 — a crop that deliberately reaches outside the photograph.
                         CropRect(left: -0.05, top: -0.05, right: 1.08, bottom: 1.03)]
    private let angles: [Double] = [0, 0.8, 7, 45, -12.5, -45, 30]

    private func geometry(_ crop: CropRect, degrees: Double, turns: Int = 0) -> GeometryGroup {
        var g = GeometryGroup.identity
        g.crop = crop.normalizedRect
        g.rotationDegrees = degrees
        g.quarterTurns = turns
        g.aspectLock = .original
        return g
    }

    // MARK: the canvas agrees with the renderer, bit for bit

    func testCanvasMatchesTheRendererForEveryCropAngleAndTurn() {
        for source in sources {
            for crop in crops {
                for degrees in angles {
                    for turns in [0, 1] {
                        let g = geometry(crop, degrees: degrees, turns: turns)
                        let cg = CropGeometry(geometry: g, source: source)
                        let legacy = CropMath.canvasSize(crop: cg.crop, in: source,
                                                         straightenDegrees: cg.rotationDegrees,
                                                         quarterTurns: turns,
                                                         allowsOutsideSource: true)
                        XCTAssertEqual(cg.canvas, legacy,
                                       "canvas drifted: \(source.keyString) \(crop.keyString) θ=\(degrees) q=\(turns)")
                        // The continuous extent and the integer canvas agree to within the one `ceil`.
                        let e = cg.frameExtent
                        XCTAssertEqual(Double(cg.canvas.width), e.width, accuracy: 1.0)
                        XCTAssertEqual(Double(cg.canvas.height), e.height, accuracy: 1.0)
                    }
                }
            }
        }
    }

    func testFrameSizeMatchesCropMath() {
        for source in sources {
            for crop in crops {
                let cg = CropGeometry(geometry: geometry(crop, degrees: 33), source: source)
                XCTAssertEqual(cg.frameSize,
                               CropMath.frameSize(cg.crop, in: cg.source,
                                                  allowsOutsideSource: true),
                               crop.keyString)
            }
        }
    }

    func testRightAnglesNeverGrowTheCanvas() {
        for source in sources {
            for crop in crops {
                // A right angle is a quarter turn, never a straighten (the document clamps the
                // straighten to ±45°, so `90` would arrive here as `45`).
                for turns in [0, 1, 2, 3] {
                    let cg = CropGeometry(geometry: geometry(crop, degrees: 0, turns: turns),
                                          source: source)
                    XCTAssertEqual(cg.canvas, cg.frameSize,
                                   "a right angle is an axis rename: q=\(turns) on \(crop.keyString)")
                    XCTAssertFalse(cg.hasAngle, "q=\(turns) must not count as an angle")
                    XCTAssertEqual(cg.photoCanvas, cg.source, "q=\(turns) must not grow the photo")
                }
                // …and the same through the straighten's own right angles: `canvasSize` returns the
                // frame's own pixel size, unchanged, at every multiple of 90°.
                for degrees in [90.0, 180, 270, -90, 360] {
                    let legacy = CropMath.canvasSize(crop: crop, in: source,
                                                     straightenDegrees: degrees, quarterTurns: 0,
                                                     allowsOutsideSource: true)
                    XCTAssertEqual(legacy,
                                   CropMath.frameSize(crop, in: source, allowsOutsideSource: true),
                                   "\(degrees)° must not grow the canvas")
                }
            }
        }
    }

    // MARK: the inset — the half pixel that used to be truncated

    func testTheInsetIsContinuousNotTruncated() {
        // A 1000 × 700 crop turned by 7° has a fractional extent; whatever the parity of
        // `canvas − frame`, the continuous inset must be exactly half the difference.
        let source = ImageSize(width: 4000, height: 3000)
        let cg = CropGeometry(geometry: geometry(CropRect.full, degrees: 7), source: source)
        let dx = Double(cg.canvas.width - cg.frameSize.width)
        let dy = Double(cg.canvas.height - cg.frameSize.height)
        XCTAssertEqual(cg.canvasInset.x, dx / 2, accuracy: 1e-12)
        XCTAssertEqual(cg.canvasInset.y, dy / 2, accuracy: 1e-12)
        // The historical integer spelling truncates; the type must not.
        let truncated = CropMath.canvasOrigin(crop: cg.crop, in: cg.source,
                                              straightenDegrees: 7, quarterTurns: 0)
        XCTAssertEqual(Double(truncated.x), dx / 2, accuracy: 0.5)
    }

    // MARK: frame ⇄ canvas

    func testFrameAndCanvasAreInverses() {
        for degrees in angles where degrees.truncatingRemainder(dividingBy: 90) != 0 {
            let cg = CropGeometry(geometry: geometry(CropRect.full, degrees: degrees),
                                  source: ImageSize(width: 4000, height: 3000))
            for p in [(0.0, 0.0), (123.0, 456.0), (Double(cg.frameSize.width), 0.0)] {
                let canvas = cg.canvasPoint(frameX: p.0, frameY: p.1)
                let back = cg.framePoint(canvasX: canvas.x, canvasY: canvas.y)
                XCTAssertEqual(back.x, p.0, accuracy: 1e-9, "θ=\(degrees)")
                XCTAssertEqual(back.y, p.1, accuracy: 1e-9, "θ=\(degrees)")
            }
        }
    }

    func testFrameCornersLandInsideTheCanvas() {
        for degrees in angles {
            let cg = CropGeometry(geometry: geometry(CropRect.full, degrees: degrees),
                                  source: ImageSize(width: 4000, height: 3000))
            for corner in cg.frameQuadInCanvas {
                XCTAssertGreaterThanOrEqual(corner.x, -0.5, "θ=\(degrees)")
                XCTAssertGreaterThanOrEqual(corner.y, -0.5, "θ=\(degrees)")
                XCTAssertLessThanOrEqual(corner.x, Double(cg.canvas.width) + 0.5, "θ=\(degrees)")
                XCTAssertLessThanOrEqual(corner.y, Double(cg.canvas.height) + 0.5, "θ=\(degrees)")
            }
        }
    }

    func testZeroAngleIsTheIdentityInEverySpace() {
        let source = ImageSize(width: 4000, height: 3000)
        let crop = CropRect(left: 0.1, top: 0.2, right: 0.7, bottom: 0.6)
        let cg = CropGeometry(geometry: geometry(crop, degrees: 0), source: source)
        XCTAssertEqual(cg.canvas, cg.frameSize)
        XCTAssertEqual(cg.framePoint(canvasX: 12, canvasY: 34).x, 12)
        XCTAssertEqual(cg.framePoint(canvasX: 12, canvasY: 34).y, 34)
        XCTAssertEqual(cg.documentCanvasCropRect, .full, "at 0° the canvas *is* the photograph")
        XCTAssertEqual(cg.photoCanvas, source)
    }

    /// 2026-11-02 — **a right angle covers exactly the photograph.** `rotatedExtent` answers the AABB
    /// of a turned rect, which at 90° is `h × w`; the canvas a crop is measured against is the region
    /// the turned photograph *covers*, and at a right angle that is the photograph's own rect. Without
    /// this guard a 90° document is told its own full-frame crop is illegal (measured: 6000×4500 gave
    /// `x ∈ [0.125, 0.875]`), which is the kind of contract bug a later caller would inherit.
    func testARightAngleIsThePhotographAndNotTheSwappedBox() {
        let source = ImageSize(width: 6000, height: 4500)
        for degrees in [0.0, 90, 180, 270, -90, 360] {
            XCTAssertEqual(CropGeometry.documentCanvasCropRect(in: source, degrees: degrees), .full,
                           "θ=\(degrees): a right angle covers the photograph, so its legal area is the frame")
        }
        // The document stores whatever a sidecar says, and the **read** path clamps the straighten to
        // ±45° (`GeometryGroup.straightenDegrees`), so a 90° document is not reachable in practice —
        // the guard above is a contract statement for the static function, not a live branch. Pin that
        // too, so the day the ±45° rule moves the guard is already the right answer.
        var right = GeometryGroup.identity
        right.rotationDegrees = 90
        XCTAssertEqual(right.rotationDegrees, 90, "文档照抄 XMP")
        XCTAssertEqual(right.straightenDegrees, 45, "读取时钳到 ±45°")
        let clamped = CropGeometry(geometry: right, source: source)
        XCTAssertEqual(clamped.rotationDegrees, 45)
        XCTAssertEqual(clamped.photoCanvas,
                       ImageSize(width: CropGeometry.canvasPixels(
                                    CropGeometry.rotatedExtent(of: source, degrees: 45).width),
                                 height: CropGeometry.canvasPixels(
                                    CropGeometry.rotatedExtent(of: source, degrees: 45).height)))
        let tilted = CropGeometry(geometry: geometry(.full, degrees: 45), source: source)
        XCTAssertLessThan(tilted.documentCanvasCropRect.left, 0, "45° sweeps wider than the photograph")
        XCTAssertLessThan(tilted.documentCanvasCropRect.top, 0)
        XCTAssertEqual(tilted.photoCanvas,
                       ImageSize(width: CropGeometry.canvasPixels(
                                    CropGeometry.rotatedExtent(of: source, degrees: 45).width),
                                 height: CropGeometry.canvasPixels(
                                    CropGeometry.rotatedExtent(of: source, degrees: 45).height)))
    }

    // MARK: the document canvas (space 4)

    func testDocumentCanvasGrowsWithTheAngleAndIgnoresTheCrop() {
        let source = ImageSize(width: 4000, height: 3000)
        let full = CropGeometry(geometry: geometry(.full, degrees: 45), source: source)
        let small = CropGeometry(geometry: geometry(CropRect(left: 0.3, top: 0.3, right: 0.6, bottom: 0.6),
                                                     degrees: 45), source: source)
        // A document fact: the crop cannot change it.
        XCTAssertEqual(full.photoCanvas, small.photoCanvas)
        XCTAssertEqual(full.documentCanvasRect, small.documentCanvasRect)
        // 4000 × 3000 at 45° ⇒ (4000+3000)/√2 ≈ 4949.7 on both axes.
        XCTAssertEqual(Double(full.photoCanvas.width), 4949.75, accuracy: 0.6)
        XCTAssertEqual(Double(full.photoCanvas.height), 4949.75, accuracy: 0.6)
        // The legal area is wider than the photograph by the sweep on each axis.
        XCTAssertLessThan(full.documentCanvasCropRect.left, 0)
        XCTAssertGreaterThan(full.documentCanvasCropRect.right, 1)
    }

    // MARK: the crop clamp

    func testCropMaySitInTheBlackCornersButNotLeaveTheCanvas() {
        let source = ImageSize(width: 4000, height: 3000)
        let cg = CropGeometry(geometry: geometry(.full, degrees: 45), source: source)
        let legal = cg.documentCanvasCropRect

        // A small frame parked in the black corner at the frame's top-left is legal.
        let corner = CropRect(left: legal.left + 0.01, top: legal.top + 0.01,
                              right: legal.left + 0.11, bottom: legal.top + 0.11)
        let kept = cg.clampedToDocumentCanvas(corner)
        XCTAssertEqual(kept.left, corner.left, accuracy: 1e-12)
        XCTAssertEqual(kept.top, corner.top, accuracy: 1e-12)

        // Dragged far outside: pulled back to the canvas edge, never further.
        let far = CropRect(left: -3, top: -2, right: -2.5, bottom: -1.5)
        let pulled = cg.clampedToDocumentCanvas(far)
        XCTAssertEqual(pulled.left, legal.left, accuracy: 1e-12)
        XCTAssertEqual(pulled.top, legal.top, accuracy: 1e-12)
        XCTAssertEqual(pulled.width, 0.5, accuracy: 1e-12, "the frame keeps its size")

        // And an oversized frame is shrunk to the canvas, about its centre.
        let huge = CropRect(left: -2, top: -2, right: 3, bottom: 3)
        let shrunk = cg.clampedToDocumentCanvas(huge)
        XCTAssertLessThanOrEqual(shrunk.width, legal.width + 1e-12)
        XCTAssertLessThanOrEqual(shrunk.height, legal.height + 1e-12)
    }

    func testCropClampAtZeroIsTheOldFrameRect() {
        let source = ImageSize(width: 4000, height: 3000)
        let cg = CropGeometry(geometry: geometry(.full, degrees: 0), source: source)
        let outside = CropRect(left: -0.2, top: 0.1, right: 0.4, bottom: 0.5)
        let clamped = cg.clampedToDocumentCanvas(outside)
        XCTAssertEqual(clamped.left, 0, accuracy: 1e-12)
        XCTAssertEqual(clamped.top, 0.1, accuracy: 1e-12)
        XCTAssertEqual(clamped.width, outside.width, accuracy: 1e-12)
    }

    // MARK: photo ⇄ canvas

    func testThePhotoIsPlacedByTheSameRotationAsTheFrame() {
        let source = ImageSize(width: 4000, height: 3000)
        let cg = CropGeometry(geometry: geometry(.full, degrees: 7), source: source)
        // At a full crop the photograph and the frame are the same rectangle.
        for (photo, frame) in zip(cg.photoQuadInCanvas, cg.frameQuadInCanvas) {
            XCTAssertEqual(photo.x, frame.x, accuracy: 1e-9)
            XCTAssertEqual(photo.y, frame.y, accuracy: 1e-9)
        }
    }
}
