import XCTest
import CoreGraphics
import PhotonsCore
import PhotonsUI

/// 259 — 适应 is the **crop's** turned quadrilateral, not the whole source.
///
/// The acceptance is stated as numbers: a 50 % central crop fills 90 % of the viewport (5 % of air on
/// every side when the crop's aspect matches it); a full frame keeps the pre-259 value bit for bit;
/// 1:1/2:1 stay source-pixel ratios; the crop workspace's entry zoom is the same number; a tiny crop
/// magnifies (capped at 4×) and the readout prints the real percentage.
final class FitToCrop259Tests: XCTestCase {

    // MARK: - 1. the 50 % crop fills 90 % of the viewport

    func testHalfCropFillsNinetyPercentOfTheViewport() {
        // 3000×2000 viewport matches the crop's 1.5 aspect, so "5 % on every side" is literal.
        let viewport = ImageSize(width: 3000, height: 2000)
        let crop = CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)
        let f = LoupeFraming(viewport: viewport, sourceWidth: 6000, sourceHeight: 4000, crop: crop)

        // crop AABB = 3000×2000; min(3000/3000, 2000/2000) × 0.90 = 0.90.
        XCTAssertEqual(f.fitZoom, 0.90, accuracy: 1e-12)

        let content = f.contentSize(of: .fit)
        XCTAssertEqual(content.width, 2700, accuracy: 1e-9)
        XCTAssertEqual(content.height, 1800, accuracy: 1e-9)

        let left = (Double(viewport.width) - content.width) / 2
        let right = left
        let top = (Double(viewport.height) - content.height) / 2
        let bottom = top
        XCTAssertEqual(left, 0.05 * 3000, accuracy: 1)
        XCTAssertEqual(right, 0.05 * 3000, accuracy: 1)
        XCTAssertEqual(top, 0.05 * 2000, accuracy: 1)
        XCTAssertEqual(bottom, 0.05 * 2000, accuracy: 1)

        // Reverse gate: the pre-259 whole-source base would be 0.45, not 0.90.
        let oldFit = min(Double(viewport.width) / 6000,
                         Double(viewport.height) / 4000) * LoupeFraming.fitMargin
        XCTAssertEqual(oldFit, 0.45, accuracy: 1e-12)
        XCTAssertNotEqual(f.fitZoom, oldFit, "reverting to rotatedSourceExtent must make this red")
    }

    // MARK: - 2. a full frame is the picture's own grid, so its 适应 never changes

    func testFullFrameFitIsTheOldValueExactly() {
        let viewport = ImageSize(width: 2560, height: 1600)
        // 301b — a full crop's canvas **is** the photograph's grid at every angle, so 适应 is the
        // θ = 0 value bit for bit. 259's expression needed the `> cropRefitDegrees` branch only to
        // shrink for the turned AABB; with the AABB gone there is nothing to re-fit, and this test
        // now pins that the angle enters a full frame's fit **nowhere**.
        let expected = min(1, min(Double(viewport.width) / 6000,
                                  Double(viewport.height) / 4000) * LoupeFraming.fitMargin)
        for degrees in [0.0, 9.0, 45.0] {
            let f = LoupeFraming(viewport: viewport, sourceWidth: 6000, sourceHeight: 4000,
                                 crop: .full, straightenDegrees: degrees)
            XCTAssertEqual(f.fitZoom, expected,
                           "\(degrees)°: a full crop's canvas is the source grid → the 0° fit")
            XCTAssertEqual(f.rotatedCropExtent.width, 6000, accuracy: 1e-9,
                           "\(degrees)°: the canvas is the crop frame, not its AABB")
        }

        // The M3 never-magnify rule survives for a small, never-cropped source.
        let small = LoupeFraming(viewport: viewport, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(small.fitZoom, 1, accuracy: 0, "a full frame smaller than the viewport stays 1:1")
    }

    // MARK: - 3. 1:1 and 2:1 are still source-pixel ratios

    func testOneToOneAndTwoToOneAreUnaffectedByTheCrop() {
        let viewport = ImageSize(width: 2560, height: 1600)
        let crops = [CropRect.full,
                     CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75)]
        for crop in crops {
            let f = LoupeFraming(viewport: viewport, sourceWidth: 6000, sourceHeight: 4000, crop: crop)
            let one = LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000)
            let two = LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2000)
            XCTAssertEqual(f.zoom(of: one), 1, accuracy: 1e-12, "crop \(crop.keyString): 1:1 unchanged")
            XCTAssertEqual(f.zoom(of: two), 2, accuracy: 1e-12, "crop \(crop.keyString): 2:1 unchanged")
            XCTAssertEqual(f.mapping(of: one).canvasPerSource, 1, accuracy: 1e-12)
            XCTAssertEqual(f.mapping(of: two).canvasPerSource, 2, accuracy: 1e-12)
        }
    }

    // MARK: - 4. the crop workspace enters at the same fit

    func testCropWorkspaceEntryIsTheOrdinaryFitNumber() {
        let viewport = ImageSize(width: 2560, height: 1600)
        let layout = CropWorkspaceLayout(
            source: ImageSize(width: 6000, height: 4000), quarterTurns: 0, straighten: 0,
            canvas: CGRect(x: 0, y: 0, width: Double(viewport.width), height: Double(viewport.height)))
        let crops = [CropRect.full,
                     CropRect(left: 0.25, top: 0.25, right: 0.75, bottom: 0.75),
                     CropRect(left: 0.45, top: 0.45, right: 0.55, bottom: 0.55)]

        for degrees in [0.0, 9.0, 45.0] {
            var angled = layout
            angled.straighten = degrees
            for crop in crops {
                let entry = angled.entry(crop: crop)
                let f = LoupeFraming(viewport: viewport, sourceWidth: 6000, sourceHeight: 4000,
                                     crop: crop, straightenDegrees: degrees)
                XCTAssertEqual(entry.entryZoom, f.fitZoom, accuracy: 1e-6,
                               "\(degrees)° · \(crop.keyString): entry must be the ordinary fit")
            }
        }
    }

    // MARK: - 5. a tiny crop magnifies, capped at 4×, and the readout says so

    func testSmallCropMagnifiesAndIsCappedAtFourTimes() {
        let crop = CropRect(left: 0.45, top: 0.45, right: 0.55, bottom: 0.55) // 600×400 source px

        // min(3200/600, 2400/400) × 0.90 = 4.8 → the 4× ceiling wins.
        let capped = LoupeFraming(viewport: ImageSize(width: 3200, height: 2400),
                                  sourceWidth: 6000, sourceHeight: 4000, crop: crop)
        XCTAssertEqual(capped.fitZoom, LoupeFraming.maximumFitZoom, accuracy: 1e-12)
        XCTAssertGreaterThan(capped.fitZoom, 1)
        XCTAssertEqual(capped.zoom(of: .fit), 4, accuracy: 1e-12, "fit is not clamped to 100 %")

        // A smaller viewport stays under the ceiling: min(1600/600, 1200/400) × 0.90 = 2.4.
        let magnified = LoupeFraming(viewport: ImageSize(width: 1600, height: 1200),
                                     sourceWidth: 6000, sourceHeight: 4000, crop: crop)
        XCTAssertEqual(magnified.fitZoom, 2.4, accuracy: 1e-12)
        let camera = LoupeCamera(viewport: LoupeViewport(framing: magnified),
                                 backingScale: 1, cropLimit: nil)
        XCTAssertEqual(camera.label, "适应 240%", "the readout prints the real, magnified ratio")
        XCTAssertNotEqual(camera.label, "适应 100%")
    }

    // MARK: - 6. 45° takes the crop's AABB only, never min(crop, whole source)

    func testFortyFiveDegreesUsesTheCropAABBOnly() {
        let viewport = ImageSize(width: 2000, height: 2000)
        let crop = CropRect(left: 0.4, top: 0.4, right: 0.6, bottom: 0.6) // 1200×800 source px
        let f = LoupeFraming(viewport: viewport, sourceWidth: 6000, sourceHeight: 4000,
                             crop: crop, straightenDegrees: 45)

        let cropExtent = f.rotatedCropExtent
        let cropFit = min(Double(viewport.width) / cropExtent.width,
                          Double(viewport.height) / cropExtent.height) * LoupeFraming.fitMargin
        let sourceExtent = f.rotatedSourceExtent
        let sourceFit = min(Double(viewport.width) / sourceExtent.width,
                            Double(viewport.height) / sourceExtent.height) * LoupeFraming.fitMargin

        XCTAssertEqual(f.fitZoom, cropFit, accuracy: 1e-12, "45° must take the crop's AABB")
        XCTAssertLessThan(sourceFit, cropFit, "the whole source's AABB is bigger at 45°")
        XCTAssertNotEqual(f.fitZoom, sourceFit,
                          "min(crop, whole source) would silently restore the old framing")
        XCTAssertNotEqual(f.fitZoom, min(cropFit, sourceFit))
    }
}
