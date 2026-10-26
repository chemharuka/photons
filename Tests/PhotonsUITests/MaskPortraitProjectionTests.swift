import XCTest
import Metal
import PhotonsCore
@testable import PhotonsUI

/// Task 028, the UI half: **what the hand draws is what renders**, on a portrait file as well as on a
/// landscape one.
///
/// The mask UI has exactly one projection (`LoupeFraming`/`LoupeMapping`, the inverse of S0) and one
/// frame to measure normalised geometry against (`CatalogSession.maskSourceSize`, i.e.
/// `MaskSourceFrame.size`). This test drives the whole chain the way a drag does — view point →
/// `LoupeMapping.sourcePoint` → normalised point → `MaskDragGeometry` → the document — and then renders
/// that document through `RenderGraph` and measures the pixels. The ellipse's own radii are the
/// assertion: a rim dragged 60 px to the right and 40 px down must render a 60×40 px ellipse, in both
/// aspects.
///
/// The portrait fixture is stored the way the camera writes it (EXIF 6: stored 240×160, upright
/// 160×240). The catalog row of such a file reports the **stored** dimensions, and that number is what
/// the mask UI used to measure with — the second half of each case shows what that did.
@MainActor
final class MaskPortraitProjectionTests: XCTestCase {

    private struct Shot {
        let name: String
        /// What the user sees, and the frame the renderer ingests.
        let upright: ImageSize
        let orientation: ImageOrientation
        var stored: ImageSize {
            let s = orientation.uprightSize(width: upright.width, height: upright.height)
            return ImageSize(width: s.width, height: s.height)
        }
    }

    private let viewport = ImageSize(width: 480, height: 320)

    // MARK: - fixtures

    private func flat(_ size: ImageSize, value: Double = 0.35) -> LinearImage {
        var rgba = [Float16](repeating: 0, count: size.width * size.height * 4)
        for i in 0..<(size.width * size.height) {
            let o = i * 4
            rgba[o] = Float16(value); rgba[o + 1] = Float16(value)
            rgba[o + 2] = Float16(value); rgba[o + 3] = 1
        }
        return LinearImage(width: size.width, height: size.height, rgba: rgba,
                           colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic-028")
    }

    private func graph(_ image: LinearImage, _ identity: String) throws -> RenderGraph {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return try RenderGraph(input: RenderInput(image: image, identity: identity))
    }

    private func atlas(_ edit: EditModel, _ image: LinearImage) throws -> MaskAtlasDump {
        let g = try graph(image, "mask-028-ui")
        let dump = try g.maskAtlas(edit, options: RenderOptions(scale: 1))
        return try XCTUnwrap(dump, "an enabled mask must produce an atlas")
    }

    private func document(_ shape: MaskShape) -> EditModel {
        var edit = EditModel.neutral
        edit.masks = [Mask(id: "m-028", components: [MaskComponent(id: "c-028", feather: 0.5,
                                                                  shape: shape)])]
        return edit
    }

    // MARK: - measurements

    private func rowProfile(_ slice: [Float], width: Int, y: Int) -> [(x: Double, v: Double)] {
        (0..<width).map { (Double($0) + 0.5, Double(slice[y * width + $0])) }
    }

    private func columnProfile(_ slice: [Float], width: Int, height: Int,
                               x: Int) -> [(x: Double, v: Double)] {
        (0..<height).map { (Double($0) + 0.5, Double(slice[$0 * width + x])) }
    }

    /// First crossing of `level` scanning `samples` in the given direction.
    private func crossing(_ samples: [(x: Double, v: Double)], level: Double,
                          rising: Bool) -> Double? {
        let ordered = rising ? samples : samples.reversed()
        for i in 1..<ordered.count {
            let a = ordered[i - 1], b = ordered[i]
            if a.v < level, b.v >= level {
                let t = (level - a.v) / (b.v - a.v)
                return a.x + t * (b.x - a.x)
            }
        }
        return nil
    }

    /// `(centre, halfWidth)` of the α = 0.5 contour along a scan line — the radius where the coverage
    /// is half, which for `radial_alpha` with feather `f` is `1 − f/2` of the drawn radius.
    private func span(_ samples: [(x: Double, v: Double)], level: Double) -> (centre: Double, half: Double)? {
        guard let low = crossing(samples, level: level, rising: true),
              let high = crossing(samples, level: level, rising: false) else { return nil }
        return ((low + high) / 2, (high - low) / 2)
    }

    private func centroid(_ slice: [Float], width: Int, height: Int) -> (x: Double, y: Double) {
        var sx = 0.0, sy = 0.0, mass = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let a = Double(slice[y * width + x])
                guard a > 1e-4 else { continue }
                sx += a * (Double(x) + 0.5); sy += a * (Double(y) + 0.5); mass += a
            }
        }
        guard mass > 0 else { return (-1, -1) }
        return (sx / mass, sy / mass)
    }

    // MARK: - the drag

    /// A drag in **view points** → the normalised points the canvas would write into the document.
    private func normalizedDrag(in framing: LoupeFraming,
                                from startView: CGPoint, by delta: CGVector)
        -> (start: NormalizedPoint, end: NormalizedPoint, deltaPixels: (x: Double, y: Double)) {
        let state = LoupeViewState.fit
        let endView = CGPoint(x: startView.x + delta.dx, y: startView.y + delta.dy)
        func normalized(_ p: CGPoint) -> (x: Double, y: Double) {
            let s = framing.sourcePoint(of: state, viewX: Double(p.x), viewY: Double(p.y), backingScale: 1)
            return (s.x / framing.sourceWidth, s.y / framing.sourceHeight)
        }
        let a = normalized(startView), b = normalized(endView)
        return (NormalizedPoint(a.x, a.y), NormalizedPoint(b.x, b.y),
                ((b.x - a.x) * framing.sourceWidth, (b.y - a.y) * framing.sourceHeight))
    }

    private func viewPoint(in framing: LoupeFraming, sourceFraction: (x: Double, y: Double)) -> CGPoint {
        let state = LoupeViewState.fit
        let p = framing.viewPoint(of: state,
                                  sourceX: sourceFraction.x * framing.sourceWidth,
                                  sourceY: sourceFraction.y * framing.sourceHeight,
                                  backingScale: 1)
        return CGPoint(x: p.x, y: p.y)
    }

    // MARK: - tests

    /// The criterion: an ellipse dragged on the canvas renders at the radii the hand drew, in portrait
    /// and in landscape, and the fact that the catalog row is transposed is what used to break it.
    func testTheEllipseYouDragIsTheEllipseThatRenders() throws {
        let shots = [
            Shot(name: "landscape / EXIF 1", upright: ImageSize(width: 240, height: 160), orientation: .up),
            Shot(name: "portrait / EXIF 6", upright: ImageSize(width: 160, height: 240), orientation: .right),
            Shot(name: "portrait / EXIF 8", upright: ImageSize(width: 160, height: 240), orientation: .left),
        ]

        for shot in shots {
            let framing = LoupeFraming(viewport: viewport,
                                       decoded: shot.upright,
                                       decodeScale: 1,
                                       edit: .neutral)
            let startView = viewPoint(in: framing, sourceFraction: (0.5, 0.5))
            let drag = normalizedDrag(in: framing, from: startView, by: CGVector(dx: 60, dy: 40))

            // The upright frame — what the renderer ingested, and what the UI must measure with.
            let shape = MaskDragGeometry.radial(center: drag.start, to: drag.end,
                                                source: shot.upright)
            let dump = try atlas(document(.radialGradient(shape)), flat(shot.upright))
            XCTAssertEqual(dump.width, shot.upright.width, "\(shot.name): atlas is the upright width")
            XCTAssertEqual(dump.height, shot.upright.height, "\(shot.name): atlas is the upright height")

            let centreRow = Int(round(0.5 * Double(dump.height))) - 1
            let centreColumn = Int(round(0.5 * Double(dump.width))) - 1
            let horizontal = try XCTUnwrap(span(rowProfile(dump.slices[0], width: dump.width,
                                                           y: centreRow), level: 0.5),
                                           "\(shot.name): no horizontal 50 % contour")
            let vertical = try XCTUnwrap(span(columnProfile(dump.slices[0], width: dump.width,
                                                          height: dump.height, x: centreColumn),
                                              level: 0.5),
                                         "\(shot.name): no vertical 50 % contour")

            // `alpha = 1 − smoothstep(1−f, 1, r)` with f = 0.5 ⇒ half coverage at r = 0.75 of the radius.
            let expectedRX = 0.75 * abs(drag.deltaPixels.x)
            let expectedRY = 0.75 * abs(drag.deltaPixels.y)
            let expectedCentre = (x: drag.start.x * Double(dump.width),
                                 y: drag.start.y * Double(dump.height))

            print(String(format: "028 drag %@: centre (%.2f, %.2f) expected (%.2f, %.2f) · halfW %.2f (exp %.2f) · halfH %.2f (exp %.2f)",
                         shot.name, horizontal.centre, vertical.centre,
                         expectedCentre.x, expectedCentre.y,
                         horizontal.half, expectedRX, vertical.half, expectedRY))

            XCTAssertEqual(horizontal.half, expectedRX, accuracy: 1.5,
                           "\(shot.name): the ellipse's width is not the drag's width")
            XCTAssertEqual(vertical.half, expectedRY, accuracy: 1.5,
                           "\(shot.name): the ellipse's height is not the drag's height")
            XCTAssertEqual(horizontal.centre, expectedCentre.x, accuracy: 1.5,
                           "\(shot.name): the ellipse is not where the drag started (x)")
            XCTAssertEqual(vertical.centre, expectedCentre.y, accuracy: 1.5,
                           "\(shot.name): the ellipse is not where the drag started (y)")

            // What measuring with the *catalog* row (the stored dimensions) does — the bug this task
            // fixes. On a portrait file the two frames are transposed, so the rim's x-span is scaled by
            // the long/short ratio instead of 1.
            let storedFrame = shot.stored
            let storedShape = MaskDragGeometry.radial(center: drag.start, to: drag.end,
                                                      source: storedFrame)
            let storedDump = try atlas(document(.radialGradient(storedShape)), flat(shot.upright))
            let storedHorizontal = try XCTUnwrap(span(rowProfile(storedDump.slices[0],
                                                                 width: storedDump.width, y: centreRow),
                                                       level: 0.5))
            let storedError = abs(storedHorizontal.half - expectedRX)
            print(String(format: "028 drag %@: measured with the catalog (stored) frame → halfW %.2f, off by %.2f px",
                         shot.name, storedHorizontal.half, storedError))
            if shot.orientation.exchangesDimensions {
                XCTAssertGreaterThan(storedError, 5,
                    "\(shot.name): the stored dimensions are supposed to disagree with the upright frame by more than 5 px, got \(storedError)")
            } else {
                XCTAssertLessThan(storedError, 1.5,
                    "\(shot.name): with EXIF 1 the stored and upright frames are the same, got \(storedError)")
            }
        }
    }

    /// The other half of "落点": a brush point taken from a view point must paint on the pixel under the
    /// hand, in portrait and landscape, with the centroid inside the 1.5 px budget.
    func testBrushStrokeLandsUnderTheHand() throws {
        let shots = [
            Shot(name: "landscape / EXIF 1", upright: ImageSize(width: 240, height: 160), orientation: .up),
            Shot(name: "portrait / EXIF 6", upright: ImageSize(width: 160, height: 240), orientation: .right),
        ]

        for shot in shots {
            let framing = LoupeFraming(viewport: viewport, decoded: shot.upright,
                                       decodeScale: 1, edit: .neutral)
            let hand = viewPoint(in: framing, sourceFraction: (0.38, 0.62))
            let p = framing.sourcePoint(of: LoupeViewState.fit, viewX: Double(hand.x),
                                        viewY: Double(hand.y), backingScale: 1)
            let normalized = NormalizedPoint(p.x / framing.sourceWidth, p.y / framing.sourceHeight)

            let radius = 0.06                       // short-edge units
            let edit = document(.brush(BrushShape(size: radius * 2, strokes: [
                Stroke(points: [Float(normalized.x), Float(normalized.y)], radius: radius,
                       feather: 0, flow: 1, erase: false, closed: false)
            ])))
            let dump = try atlas(edit, flat(shot.upright))
            let measured = centroid(dump.slices[0], width: dump.width, height: dump.height)
            let expected = (x: normalized.x * Double(dump.width),
                           y: normalized.y * Double(dump.height))
            print(String(format: "028 brush %@: centroid (%.2f, %.2f) expected (%.2f, %.2f) Δ(%.2f, %.2f)",
                         shot.name, measured.x, measured.y, expected.x, expected.y,
                         abs(measured.x - expected.x), abs(measured.y - expected.y)))
            XCTAssertLessThanOrEqual(abs(measured.x - expected.x), 1.5,
                                     "\(shot.name): brush centroid is off in x")
            XCTAssertLessThanOrEqual(abs(measured.y - expected.y), 1.5,
                                     "\(shot.name): brush centroid is off in y")
        }
    }

    /// The session's one frame: the ingested (upright) size wins, and a frame recorded for a *different*
    /// photo is never used — a photo switch must not inherit the previous picture's aspect before its own
    /// decode lands.
    func testMaskSourceSizeUsesTheIngestedFrameOnlyForTheAnchor() {
        let session = CatalogSession()
        // No anchor: nothing to measure against, and no crash.
        XCTAssertEqual(session.maskSourceSize, ImageSize(width: 1, height: 1))

        session.ingestedSourceFrame = (assetID: "somebody-else", size: ImageSize(width: 6336, height: 9520))
        XCTAssertEqual(session.maskSourceSize, ImageSize(width: 1, height: 1),
                       "a frame recorded for another photo must not be used")
    }
}
