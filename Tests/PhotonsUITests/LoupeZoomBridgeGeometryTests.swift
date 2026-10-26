import XCTest
import CoreGraphics
import PhotonsCore
import PhotonsUI

/// The bridge's geometry, checked as arithmetic before any pixels are involved.
///
/// The claim under test is one equation — `aN(p) = scale · aO(p) + offset` — where `aO` / `aN` are
/// the two cameras' own projections (`LoupeMapping`, device pixels, y down). If that holds for the
/// canvas as a whole then the old picture, carried by the layer transform, *is* the new picture at
/// that instant: every source pixel is where the new camera would put it, the anchored one included.
///
/// Two things this catches that a screenshot would not: a sign error in the y conversion (the layer's
/// coordinates run the other way up), and the case the old bridge got away with only because it was
/// never asked — `100 ↔ 200 %` where both content rects are the *same* size, so a pure content-rect
/// scale is 1.0 and does nothing at all, while the picture still has to grow 2×.
final class LoupeZoomBridgeGeometryTests: XCTestCase {

    /// 2560×1600 canvas, 6000×4000 source: `fitZoom` is 0.4, so none of the stops above it collide
    /// with the whole-frame rung and the window at 200 % is exactly the canvas.
    private let viewport = ImageSize(width: 2560, height: 1600)

    private func framing() -> LoupeFraming {
        LoupeFraming(viewport: viewport, sourceWidth: 6000, sourceHeight: 4000)
    }

    private func bridge(from old: LoupeViewState, to new: LoupeViewState,
                        startScale: Double = 1,
                        backingScale: Double = 1) -> LoupeZoomBridge {
        let f = framing()
        return LoupeZoomBridge(fromContent: f.contentPixels(of: old),
                               toContent: f.contentPixels(of: new),
                               fromMapping: f.mapping(of: old),
                               toMapping: f.mapping(of: new),
                               canvas: viewport,
                               startScale: startScale,
                               duration: LoupeZoomBridge.duration(from: startScale,
                                                                  to: f.mapping(of: new).canvasPerSource
                                                                      / f.mapping(of: old).canvasPerSource))
    }

    /// One source pixel through both cameras, and through the layer transform, in layer points.
    private func assertCarried(_ p: (x: Double, y: Double), _ b: LoupeZoomBridge,
                               backingScale k: Double = 1,
                               file: StaticString = #filePath, line: UInt = #line) {
        let old = b.fromMapping.viewPoint(sourceX: p.x, sourceY: p.y)
        let new = b.toMapping.viewPoint(sourceX: p.x, sourceY: p.y)
        let there = LoupeZoomBridge.apply(b.targetTransform(backingScale: k),
                                          to: b.layerPoint(canvasX: old.x, canvasY: old.y,
                                                           backingScale: k),
                                          anchor: b.layerAnchor(backingScale: k))
        let expect = b.layerPoint(canvasX: new.x, canvasY: new.y, backingScale: k)
        XCTAssertEqual(there.x, expect.x, accuracy: 0.5,
                       "x of source (\(p.x), \(p.y))", file: file, line: line)
        XCTAssertEqual(there.y, expect.y, accuracy: 0.5,
                       "y of source (\(p.x), \(p.y))", file: file, line: line)
    }

    func testEveryStopChangeIsOneSimilarityOfTheTwoProjections() {
        let f = framing()
        let anchor = CGPoint(x: 600, y: 400)          // a quarter in — not the canvas centre
        let at100 = f.zooming(.fit, to: 1, aroundView: anchor)
        let at200 = f.zooming(at100, to: 2, aroundView: anchor)
        let centre = (x: Double(viewport.width) / 2, y: Double(viewport.height) / 2)
        let cases: [(LoupeViewState, LoupeViewState, String, (x: Double, y: Double))] = [
            // Anchored commands: the fixed point of the similarity is the cursor, in canvas pixels.
            (.fit, at100, "fit → 100 %", (x: 600, y: 400)),
            (at100, at200, "100 → 200 %", (x: 600, y: 400)),
            // Centred states (the old `zoom(to:)` behaviour): the fixed point is the canvas centre.
            (LoupeViewState(mode: .actual, zoom: 3, centerX: 3000, centerY: 2000),
             LoupeViewState(mode: .actual, zoom: 4, centerX: 3000, centerY: 2000),
             "300 → 400 %", centre),
            (LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2000),
             LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000),
             "200 → 100 %", centre),
        ]
        for (old, new, label, fixedPoint) in cases {
            let b = bridge(from: old, to: new)
            XCTAssertTrue(b.isVisible, "\(label) must arm a bridge")
            // Four source pixels spread over the frame, plus the projections' own centre.
            for p in [(3000.0, 2000.0), (0.0, 0.0), (6000.0, 0.0), (0.0, 4000.0), (6000.0, 4000.0),
                      (1500.0, 900.0)] {
                assertCarried(p, b)
            }
            // The fixed point of `v ↦ scale·v + offset` is the pixel that does not move: the cursor
            // for an anchored command, the centre of the canvas for a centred one. This is the same
            // statement as "the anchor does not drift", in the space the layer transform works in.
            let o = b.offset
            let fixed = (x: o.x / (1 - b.scale), y: o.y / (1 - b.scale))
            XCTAssertEqual(fixed.x, fixedPoint.x, accuracy: 1.0, "\(label) fixed point x")
            XCTAssertEqual(fixed.y, fixedPoint.y, accuracy: 1.0, "\(label) fixed point y")
            print("\(label): scale=\(String(format: "%.4f", b.scale)) "
                  + "offset=(\(String(format: "%.1f", o.x)), \(String(format: "%.1f", o.y))) px "
                  + "fixed=(\(String(format: "%.1f", fixed.x)), \(String(format: "%.1f", fixed.y))) px "
                  + "duration=\(String(format: "%.0f", b.duration * 1000)) ms")
        }
    }

    /// The case that made the old bridge look sufficient and made `100 → 200 %` impossible to bridge
    /// with it: both content rects are the canvas, so the content-rect ratio is exactly 1.
    func testContentRectRatioCannotDescribeAStopChange() {
        let f = framing()
        let a = LoupeViewState(mode: .actual, zoom: 1, centerX: 3000, centerY: 2000)
        let b = LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2000)
        XCTAssertEqual(f.contentPixels(of: a), f.contentPixels(of: b),
                       "both stops fill the canvas — a content-rect ratio would be 1.0")
        let bridge = self.bridge(from: a, to: b)
        XCTAssertEqual(bridge.scale, 2, accuracy: 1e-9, "the picture still has to grow 2×")
        XCTAssertTrue(bridge.isVisible)
    }

    /// The layer transform is its own inverse at the read-out used for retargeting: what
    /// `armZoomBridge` reads off `presentation()` must be the same `(scale, offset)` it wrote.
    func testTheTransformRoundTripsThroughItsInverse() {
        let f = framing()
        let old = LoupeViewState(mode: .actual, zoom: 1, centerX: 2400, centerY: 1700)
        let new = LoupeViewState(mode: .actual, zoom: 1.6, centerX: 2600, centerY: 1500)
        let b = bridge(from: old, to: new)
        let m = b.targetTransform(backingScale: 2)
        let back = LoupeZoomBridge.offset(ofLayerTransform: m, canvas: viewport, backingScale: 2)
        let o = b.offset
        XCTAssertEqual(back.scale, b.scale, accuracy: 1e-9)
        XCTAssertEqual(back.x, o.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, o.y, accuracy: 1e-6)
    }

    /// A pan is not a stop change: same zoom, different centre — the projections differ by a
    /// translation, which is exactly what must **not** animate.
    func testAPanIsNotVisibleAsAScaleChange() {
        let f = framing()
        let old = LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2000)
        let new = LoupeViewState(mode: .actual, zoom: 2, centerX: 3100, centerY: 2050)
        let b = bridge(from: old, to: new)
        XCTAssertEqual(b.scale, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(abs(b.offset.x), 0.5, "a pan does move the picture…")
        // …and the loupe does not animate it (`movesScale` is false for it), which is why the
        // bridge's own `isVisible` is only ever consulted after that check.
        XCTAssertFalse(abs(f.zoom(of: new) / f.zoom(of: old) - 1) > 1e-6)
    }

    func testDurationScalesWithTheSpanInOctaves() {
        let cases: [(Double, Double, Double)] = [
            (1, 2, 0.180),        // one octave — 100 → 200 %, the tuned fit ↔ 100 % duration
            (2, 1, 0.180),        // and back
            (0.5, 1, 0.180),      // 50 → 100 %, the same octave
            (2, 3, 0.155),        // half an octave
            (3, 4, 0.145),
            (0.5, 4, 0.260),      // three octaves: at the ceiling
            (4, 3, 0.145),
        ]
        for (from, to, expected) in cases {
            XCTAssertEqual(LoupeZoomBridge.duration(from: from, to: to), expected, accuracy: 0.001,
                           "\(from) → \(to)")
        }
        XCTAssertEqual(LoupeZoomBridge.duration(from: 1, to: 1), 0.120, accuracy: 1e-9,
                       "a no-op span bottoms out at the 120 ms floor")
    }
}
