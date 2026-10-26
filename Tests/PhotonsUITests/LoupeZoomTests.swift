import XCTest
import AppKit
import PhotonsCore
import PhotonsUI

/// The 1:1 interaction contract, as math.
///
/// Nothing here touches Metal: the whole point of `LoupeFraming` / `LoupeMapping` is that the
/// viewport↔source projection is a plain function, so "1:1 is off by half a pixel" and "panning by
/// 100 pt moved 100 px" are test assertions rather than things a screenshot has to catch.
final class LoupeZoomTests: XCTestCase {

    private let viewport = ImageSize(width: 2560, height: 1600)
    private let source = (width: 6000.0, height: 4000.0)

    private func framing(degrees: Double = 0, flipH: Bool = false, flipV: Bool = false,
                         crop: CropRect = .full) -> LoupeFraming {
        LoupeFraming(viewport: viewport,
                     sourceWidth: source.width,
                     sourceHeight: source.height,
                     crop: crop,
                     straightenDegrees: degrees,
                     flipH: flipH,
                     flipV: flipV)
    }

    private func actual(zoom: Double, x: Double = 3000, y: Double = 2000) -> LoupeViewState {
        LoupeViewState(mode: .actual, zoom: zoom, centerX: x, centerY: y)
    }

    // MARK: 1. round trip

    /// Screen point → image pixel → screen point. The pair of functions is one affine transform, so
    /// this is exact to floating-point noise; if S0's half-pixel convention and this one ever drift
    /// apart, 1:1 lands half a pixel off the crop it replaced and every pan re-render shimmers.
    func testViewAndSourcePointsRoundTrip() {
        let points = [(0.0, 0.0), (1.0, 1.0), (1280.0, 800.0), (2559.0, 3.0), (17.5, 1599.25)]
        for degrees in [0.0, 7.0, -12.5] {
            for (flipH, flipV) in [(false, false), (true, false), (false, true), (true, true)] {
                for zoom in [1.0, 2.5, 3.0] {
                    let f = framing(degrees: degrees, flipH: flipH, flipV: flipV)
                    let state = actual(zoom: zoom)
                    let map = f.mapping(of: state)
                    for (x, y) in points {
                        let s = map.sourcePoint(viewX: x, viewY: y)
                        let back = map.viewPoint(sourceX: s.x, sourceY: s.y)
                        XCTAssertEqual(back.x, x, accuracy: 1e-6,
                                       "x round trip failed at θ=\(degrees) flip=\(flipH),\(flipV) z=\(zoom)")
                        XCTAssertEqual(back.y, y, accuracy: 1e-6,
                                       "y round trip failed at θ=\(degrees) flip=\(flipH),\(flipV) z=\(zoom)")
                    }
                }
            }
        }
    }

    /// The same round trip through the *public* controller-facing helpers, in view points.
    func testRoundTripInViewPointsAtBackingScaleTwo() {
        let f = framing(degrees: 3)
        let state = actual(zoom: 4)
        for point in [CGPoint(x: 10, y: 20), CGPoint(x: 640, y: 400), CGPoint(x: 1279.5, y: 799.5)] {
            let s = f.sourcePoint(of: state, viewX: Double(point.x), viewY: Double(point.y),
                                  backingScale: 2)
            let back = f.viewPoint(of: state, sourceX: s.x, sourceY: s.y, backingScale: 2)
            XCTAssertEqual(back.x, Double(point.x), accuracy: 1e-6)
            XCTAssertEqual(back.y, Double(point.y), accuracy: 1e-6)
        }
    }

    // MARK: 2. window size == viewport / zoom

    /// 1:1 and 4:1 must ask the renderer for exactly the viewport, so the canvas is never resampled
    /// twice (once by S0, once by the presenter's fullscreen quad).
    func testWindowSizeIsTheViewportDividedByZoom() throws {
        let f = framing()
        for zoom in [1.0, 2.0, 3.0, 4.0] {
            let state = actual(zoom: zoom)
            let window = f.windowSize(of: state)
            let content = f.contentSize(of: state)
            XCTAssertEqual(content.width, Double(viewport.width), accuracy: 0.001,
                           "content width at \(zoom):1")
            XCTAssertEqual(content.height, Double(viewport.height), accuracy: 0.001,
                           "content height at \(zoom):1")
            XCTAssertEqual(window.width, Double(viewport.width) / zoom, accuracy: 0.001)
            XCTAssertEqual(window.height, Double(viewport.height) / zoom, accuracy: 0.001)
            // The window in source pixels, and the picture it produces at this zoom.
            XCTAssertEqual(f.windowPixels(of: state).width, viewport.width / Int(zoom),
                           "window source px at \(zoom):1")
            XCTAssertEqual(f.contentPixels(of: state), viewport, "content px at \(zoom):1")
        }
    }

    /// At 1:1 one source pixel is one *device* pixel: the window is the viewport in source pixels.
    func testOneToOneWindowIsOneSourcePixelPerDevicePixel() {
        let f = framing()
        let state = actual(zoom: 1)
        let map = f.mapping(of: state)
        let a = map.sourcePoint(viewX: 100, viewY: 100)
        let b = map.sourcePoint(viewX: 101, viewY: 100)
        XCTAssertEqual(b.x - a.x, 1, accuracy: 1e-9)
        XCTAssertEqual(b.y - a.y, 0, accuracy: 1e-9)
    }

    /// `RenderGraph` wants output-per-decoded-pixel: at 1:1 with a half-resolution decode the render
    /// scale is 2, not 1. Getting this wrong is a silent 2× zoom.
    func testRenderScaleDividesByTheDecodeScale() {
        let f = framing()
        XCTAssertEqual(f.renderScale(of: actual(zoom: 1), decodeScale: 1), 1, accuracy: 1e-12)
        XCTAssertEqual(f.renderScale(of: actual(zoom: 1), decodeScale: 0.5), 2, accuracy: 1e-12)
        XCTAssertEqual(f.renderScale(of: actual(zoom: 4), decodeScale: 1), 4, accuracy: 1e-12)
        // Fit at a half decode: 0.5 → 0.8 output per decoded pixel, which is M3's fit frame.
        XCTAssertEqual(f.fitZoom, 0.4, accuracy: 1e-12)
        XCTAssertEqual(f.renderScale(of: .fit, decodeScale: 0.5), 0.8, accuracy: 1e-12)
    }

    // MARK: 3. zoom clamp 25 % … 400 %

    func testZoomIsClampedToAQuarterThroughFour() {
        XCTAssertEqual(LoupeViewState(mode: .actual, zoom: 0.1).zoom, 0.25, accuracy: 1e-12)
        XCTAssertEqual(LoupeViewState(mode: .actual, zoom: 0).zoom, 0.25, accuracy: 1e-12)
        XCTAssertEqual(LoupeViewState(mode: .actual, zoom: -3).zoom, 0.25, accuracy: 1e-12)
        XCTAssertEqual(LoupeViewState(mode: .actual, zoom: 4).zoom, 4, accuracy: 1e-12)
        XCTAssertEqual(LoupeViewState(mode: .actual, zoom: 64).zoom, 4, accuracy: 1e-12)
        XCTAssertEqual(LoupeViewState(mode: .actual, zoom: .nan).zoom, 0.25, accuracy: 1e-12)
        XCTAssertEqual(LoupeViewState.clampZoom(12), 4, accuracy: 1e-12)
        XCTAssertEqual(LoupeViewState.clampZoom(1.0 / 3.0), 1.0 / 3.0, accuracy: 1e-12)

        // A pinch past the ceiling stops at 4 and keeps rendering 4.
        let f = framing()
        var state = actual(zoom: 1)
        for _ in 0..<12 { state = f.zooming(state, to: state.zoom * 2, aroundView: CGPoint(x: 100, y: 100)) }
        XCTAssertEqual(state.zoom, 4, accuracy: 1e-12)
        for _ in 0..<12 { state = f.zooming(state, to: state.zoom * 0.5, aroundView: CGPoint(x: 100, y: 100)) }
        XCTAssertEqual(state.zoom, 0.25, accuracy: 1e-12)
    }

    /// The eight stops, as percentages. 1:1 is 100 %; the thirds print one decimal and stay exact, and
    /// the fit mode only says "适应" here because a `LoupeViewState` has no window to measure (the
    /// controller prints "适应 31%").
    func testZoomLabels() {
        XCTAssertEqual(LoupeViewState.fit.zoomLabel, "适应")
        XCTAssertEqual(actual(zoom: 0.25).zoomLabel, "25%")
        XCTAssertEqual(actual(zoom: 1.0 / 3.0).zoomLabel, "33.3%")
        XCTAssertEqual(actual(zoom: 0.5).zoomLabel, "50%")
        XCTAssertEqual(actual(zoom: 2.0 / 3.0).zoomLabel, "66.7%")
        XCTAssertEqual(actual(zoom: 1).zoomLabel, "100%")
        XCTAssertEqual(actual(zoom: 2).zoomLabel, "200%")
        XCTAssertEqual(actual(zoom: 3).zoomLabel, "300%")
        XCTAssertEqual(actual(zoom: 4).zoomLabel, "400%")
    }

    // MARK: 4. fit is the old frame

    /// Fit must stay exactly what M3 rendered — an image smaller than the viewport is never blown up,
    /// the crop is never re-shaped, and the derived edit *is* the document.
    func testFitKeepsTheDocumentCropAndNeverMagnifies() {
        let edit = EditModel.neutral
        let f = LoupeFraming(viewport: viewport,
                             decoded: ImageSize(width: 3000, height: 2000),
                             decodeScale: 0.5,
                             edit: edit)
        XCTAssertLessThanOrEqual(f.fitZoom, 1)
        XCTAssertEqual(f.fitZoom, 0.4, accuracy: 1e-12)
        XCTAssertTrue(f.zoomedEdit(edit, for: .fit) == edit, "fit must hand the document through untouched")
        XCTAssertEqual(f.cropRect(of: .fit), f.crop)
        XCTAssertEqual(f.windowSize(of: .fit).width, f.cropWidthPixels, accuracy: 1e-9)

        // A small source (2× smaller than the viewport) fits at 1:1, never above it.
        let small = LoupeFraming(viewport: viewport, sourceWidth: 800, sourceHeight: 600)
        XCTAssertEqual(small.fitZoom, 1, accuracy: 1e-12)
    }

    func testSmallCropIsShownAtOneToOneInsideTheViewport() {
        // A 1000×800 crop in a 2560×1600 viewport: fit == 1:1, and a 4:1 window is still inside.
        let f = framing(crop: CropRect(left: 0.25, top: 0.25, right: 0.5, bottom: 0.45))
        XCTAssertEqual(f.cropWidthPixels, 1500, accuracy: 1e-9)
        XCTAssertEqual(f.cropHeightPixels, 800, accuracy: 1e-9)
        XCTAssertEqual(f.fitZoom, 1, accuracy: 1e-12)
        let window = f.windowSize(of: actual(zoom: 4, x: 2250, y: 1800))
        XCTAssertEqual(window.width, 640, accuracy: 1e-9)
        XCTAssertTrue(window.height <= f.cropHeightPixels + 1e-9)
    }

    // MARK: 5. the window is the whole frame's neighbourhood

    /// The rotation compensation, proved: the axis-aligned window rect, sampled through S0's
    /// rotation, must land on the *same source pixels* as the whole-frame render at the same
    /// offset. This is the claim that lets a 1:1 frame be a crop without S0 needing a new knob.
    ///
    /// The window's aspect has to equal the crop's here: S0 rotates in *normalized crop* space and
    /// then scales anisotropically, so a window with a different aspect is a slightly different
    /// projection (see `testStraightenAngleFollowsTheCropAspectNotTheWindow`).
    func testWindowMappingMatchesTheWholeFrameMapping() {
        // 3000×2000 has the crop's 1.5 aspect, so the window and the frame rotate identically.
        let aspectMatched = ImageSize(width: 3000, height: 2000)
        let f = LoupeFraming(viewport: aspectMatched, sourceWidth: source.width,
                             sourceHeight: source.height, straightenDegrees: 7)
        let zoom = 4.0
        let state = actual(zoom: zoom)
        let whole = wholeFrameMapping(f, zoom: zoom, degrees: 7, flipH: false, flipV: false)
        let centre = f.windowCenter(of: state)
        let framePoint = whole.viewPoint(sourceX: centre.x, sourceY: centre.y)
        let offset = (x: framePoint.x - Double(aspectMatched.width) / 2,
                      y: framePoint.y - Double(aspectMatched.height) / 2)
        let win = f.mapping(of: state)
        for gx in stride(from: 0.5, to: Double(aspectMatched.width), by: 317.0) {
            for gy in stride(from: 0.5, to: Double(aspectMatched.height), by: 211.0) {
                let a = win.sourcePoint(viewX: gx, viewY: gy)
                let b = whole.sourcePoint(viewX: gx + offset.x, viewY: gy + offset.y)
                XCTAssertEqual(a.x, b.x, accuracy: 1e-9, "dx at (\(gx),\(gy))")
                XCTAssertEqual(a.y, b.y, accuracy: 1e-9, "dy at (\(gx),\(gy))")
            }
        }
    }

    func testWindowMappingMatchesTheWholeFrameWhenFlipped() {
        let aspectMatched = ImageSize(width: 3000, height: 2000)
        let f = LoupeFraming(viewport: aspectMatched, sourceWidth: source.width,
                             sourceHeight: source.height, straightenDegrees: -9,
                             flipH: true, flipV: true)
        let zoom = 2.0
        let state = actual(zoom: zoom, x: 2400, y: 2100)
        let whole = wholeFrameMapping(f, zoom: zoom, degrees: -9, flipH: true, flipV: true)
        let centre = f.windowCenter(of: state)
        let framePoint = whole.viewPoint(sourceX: centre.x, sourceY: centre.y)
        let offset = (x: framePoint.x - Double(aspectMatched.width) / 2,
                      y: framePoint.y - Double(aspectMatched.height) / 2)
        let win = f.mapping(of: state)
        for gx in stride(from: 0.5, to: Double(aspectMatched.width), by: 401.0) {
            for gy in stride(from: 0.5, to: Double(aspectMatched.height), by: 193.0) {
                let a = win.sourcePoint(viewX: gx, viewY: gy)
                let b = whole.sourcePoint(viewX: gx + offset.x, viewY: gy + offset.y)
                XCTAssertEqual(a.x, b.x, accuracy: 1e-9)
                XCTAssertEqual(a.y, b.y, accuracy: 1e-9)
            }
        }
    }

    /// S0 rotates in normalized **frame** space (`r = R(θ)·(uv−0.5)`) and only then scales to pixels,
    /// so the effective pixel-space angle depends on the frame's aspect ratio. This test measures the
    /// same aspect sensitivity in `LoupeFraming.mapping`, i.e. in the *hit-testing* projection: a 1:1
    /// window is `viewport ÷ zoom` — the viewport's aspect, not the crop's — so the window-shaped
    /// mapping deviates from the whole-frame pitch by a fraction of a percent of the window when the
    /// frame is straightened.
    ///
    /// Since the renderer takes `RenderOptions.outputWindow` the *pixels* no longer have this
    /// deviation (S0 samples the frame and cuts the window out of it — `WindowTests` measures it at
    /// 0). What is pinned here is the remaining, purely geometric offset between the frame projection
    /// the renderer uses and the window projection this mapping still uses for pan/zoom anchoring;
    /// closing it is a `LoupeMapping` change (frame size + window origin instead of a crop-shaped
    /// window), deliberately not part of the output-window task.
    func testStraightenAngleFollowsTheCropAspectNotTheWindow() {
        let f = framing(degrees: 9)
        let zoom = 2.0
        let state = actual(zoom: zoom)
        let whole = wholeFrameMapping(f, zoom: zoom, degrees: 9, flipH: false, flipV: false)
        let centre = f.windowCenter(of: state)
        let framePoint = whole.viewPoint(sourceX: centre.x, sourceY: centre.y)
        let offset = (x: framePoint.x - Double(viewport.width) / 2,
                      y: framePoint.y - Double(viewport.height) / 2)
        let win = f.mapping(of: state)

        var worst = 0.0
        for gx in stride(from: 0.5, to: Double(viewport.width), by: 61.0) {
            for gy in stride(from: 0.5, to: Double(viewport.height), by: 61.0) {
                let a = win.sourcePoint(viewX: gx, viewY: gy)
                let b = whole.sourcePoint(viewX: gx + offset.x, viewY: gy + offset.y)
                worst = max(worst, hypot(a.x - b.x, a.y - b.y))
            }
        }
        // The window here is 2560×1600 (1.60) against a 6000×4000 crop (1.50).
        XCTAssertGreaterThan(worst, 0, "the aspect difference should be visible in the numbers")
        XCTAssertLessThan(worst / Double(viewport.width), 0.01,
                          "deviation must stay under 1 % of the window: \(worst) px")
        print(String(format: "straighten aspect note: 1:1 window vs whole-frame deviates %.2f px over %d px (%.2f%%)",
                     worst, viewport.width, worst / Double(viewport.width) * 100))

        // At θ = 0 there is nothing to rotate, so the two projections agree exactly.
        let flat = framing(degrees: 0)
        let flatWhole = wholeFrameMapping(flat, zoom: zoom, degrees: 0, flipH: false, flipV: false)
        let flatWin = flat.mapping(of: state)
        let p = flatWin.sourcePoint(viewX: 123.0, viewY: 456.0)
        let q = flatWhole.sourcePoint(viewX: 123.0 + offset.x, viewY: 456.0 + offset.y)
        XCTAssertEqual(p.x, q.x, accuracy: 1e-9)
        XCTAssertEqual(p.y, q.y, accuracy: 1e-9)
    }

    /// The whole crop rendered at `zoom` as one canvas: same math, no window.
    private func wholeFrameMapping(_ f: LoupeFraming, zoom: Double, degrees: Double,
                                  flipH: Bool, flipV: Bool) -> LoupeMapping {
        LoupeMapping(
            viewport: ImageSize(width: Int(source.width * zoom), height: Int(source.height * zoom)),
            contentWidth: source.width * zoom, contentHeight: source.height * zoom,
            cropLeft: f.cropOriginX, cropTop: f.cropOriginY,
            cropWidth: f.cropWidthPixels, cropHeight: f.cropHeightPixels,
            cosT: cos(degrees * .pi / 180), sinT: sin(degrees * .pi / 180),
            flipH: flipH, flipV: flipV)
    }

    // MARK: 6. pan

    func testPanMovesTheWindowByTheDraggedDistanceInSourcePixels() {
        let f = framing()
        let state = actual(zoom: 4)
        let moved = f.panning(state, byContent: (x: 100, y: -40))
        XCTAssertEqual(moved.centerX - state.centerX, 25, accuracy: 1e-9, "100 device px at 4:1 = 25 source px")
        XCTAssertEqual(moved.centerY - state.centerY, -10, accuracy: 1e-9)
        XCTAssertEqual(moved.zoom, state.zoom, accuracy: 1e-12, "panning never changes the zoom")
    }

    func testPanIsRotatedIntoSourceSpace() {
        let f = framing(degrees: 30)
        let state = actual(zoom: 2)
        let moved = f.panning(state, byContent: (x: 100, y: 0))
        let dx = moved.centerX - state.centerX
        let dy = moved.centerY - state.centerY
        XCTAssertEqual(hypot(dx, dy), 50, accuracy: 1e-9, "magnitude is still delta/zoom")
        XCTAssertEqual(dx, 50 * cos(30 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(dy, 50 * sin(30 * .pi / 180), accuracy: 1e-9)
    }

    /// The picture may leave the frame now, so a drag is no longer stopped with the window's far edge on
    /// the crop's: it is stopped by `LoupeFraming.minimumPictureCoverage` — the window's **centre**
    /// stays on the picture, i.e. at least half the canvas is still photograph. With ½ coverage that is
    /// exactly "the centre stops at the crop's edge", and it does not spring back.
    func testPanStopsAtTheCoverageLimitNotAtTheFrameEdge() {
        let f = framing()
        let state = actual(zoom: 2)
        let window = f.windowSize(of: state)
        XCTAssertEqual(window.width, 1280, accuracy: 1e-9)
        let far = f.panning(state, byContent: (x: 1e6, y: 1e6))
        XCTAssertEqual(far.centerX, f.cropOriginX + f.cropWidthPixels, accuracy: 1e-6,
                       "the centre reaches the crop's edge and stops there")
        XCTAssertEqual(far.centerY, f.cropOriginY + f.cropHeightPixels, accuracy: 1e-6)
        // Half of the window is hanging off the frame at the limit, and that is the point of the rule.
        XCTAssertEqual(far.centerX + window.width / 2 - f.cropWidthPixels, window.width / 2,
                       accuracy: 1e-6, "half a window of background, no more")
        let back = f.panning(far, byContent: (x: -1e6, y: -1e6))
        XCTAssertEqual(back.centerX, f.cropOriginX, accuracy: 1e-6)
        XCTAssertEqual(back.centerY, f.cropOriginY, accuracy: 1e-6)
        // Letting go does not move it: the limit is a stop, not a rubber band.
        XCTAssertEqual(f.panning(far, byContent: (x: 0, y: 0)).centerX, far.centerX, accuracy: 1e-9)
    }

    func testPanDoesNothingInFitMode() {
        let f = framing()
        XCTAssertEqual(f.panning(.fit, byContent: (x: 500, y: 500)), .fit)
    }

    // MARK: 7. pinch

    func testPinchKeepsThePointUnderTheCursorFixed() {
        let f = framing()
        for (from, to) in [(1.0, 4.0), (2.0, 4.0), (4.0, 2.0)] {
            let cursor = CGPoint(x: 300, y: 250)
            let before = actual(zoom: from)
            let after = f.zooming(before, to: to, aroundView: cursor)
            let p0 = f.mapping(of: before).sourcePoint(viewX: Double(cursor.x), viewY: Double(cursor.y))
            let p1 = f.mapping(of: after).sourcePoint(viewX: Double(cursor.x), viewY: Double(cursor.y))
            XCTAssertEqual(p1.x, p0.x, accuracy: 1e-6, "\(from)→\(to): x drifted")
            XCTAssertEqual(p1.y, p0.y, accuracy: 1e-6, "\(from)→\(to): y drifted")
            XCTAssertEqual(after.zoom, to, accuracy: 1e-12)
        }
    }

    func testPinchFromFitEntersOneToOneAboutTheCursor() {
        let f = framing()
        let cursor = CGPoint(x: 2000, y: 100)
        let next = f.zooming(.fit, to: 1.4, aroundView: cursor)
        XCTAssertTrue(next.isActualSize)
        XCTAssertEqual(next.zoom, 1.4, accuracy: 1e-12)
        let before = f.mapping(of: .fit).sourcePoint(viewX: 2000, viewY: 100)
        let after = f.mapping(of: next).sourcePoint(viewX: 2000, viewY: 100)
        // The same source pixel under the cursor — no "unless": the camera may leave the frame, so the
        // anchor is honoured outright.
        XCTAssertEqual(after.x, before.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
        XCTAssertEqual(f.windowCenter(of: next).x, next.centerX, accuracy: 1e-6,
                       "the window was never limited: the anchor is inside the picture")
    }

    // MARK: 8. the derived document

    func testZoomedEditCarriesTheWindowAndLeavesTheUserCropAlone() {
        let crop = CropRect(left: 0.1, top: 0.1, right: 0.8, bottom: 0.7)
        var edit = EditModel.neutral
        edit.geometry.crop = crop.normalizedRect
        edit.geometry.aspectLock = .threeTwo
        edit.geometry.rotationDegrees = 4
        let before = edit

        let f = LoupeFraming(viewport: viewport,
                             decoded: ImageSize(width: 6000, height: 4000),
                             decodeScale: 1, edit: before)
        let state = actual(zoom: 2)
        let derived = f.zoomedEdit(before, for: state)

        XCTAssertEqual(derived.geometry.crop, f.cropRect(of: state).normalizedRect)
        XCTAssertEqual(derived.geometry.aspectLock, .original, "the window is not the user's aspect lock")
        XCTAssertEqual(derived.geometry.rotationDegrees, 4, "straighten travels with the window")
        XCTAssertEqual(edit, before, "the derived document must not be written back")

        // The window is centred on the state's centre and is viewport ÷ zoom in source pixels.
        let window = CropRect(derived.geometry.crop)
        XCTAssertEqual(window.width * f.sourceWidth, Double(viewport.width) / 2, accuracy: 1e-6)
        XCTAssertEqual(window.centerX * f.sourceWidth, 3000, accuracy: 1e-6)
        XCTAssertEqual(window.centerY * f.sourceHeight, 2000, accuracy: 1e-6)
    }

    func testFitHandsTheDocumentThroughUntouched() {
        let edit = EditModel.neutral
        let f = framing()
        XCTAssertTrue(f.zoomedEdit(edit, for: .fit) == edit)
    }

    /// `outputWindow(of:)` is what the loupe renders with; `cropRect(of:)` is the mapping's own
    /// description of the same rectangle. Moving the window from the document into `RenderOptions`
    /// must not move the *region*: same origin, same size, in content pixels (`zoom` content pixels per
    /// source pixel, measured from the crop's corner).
    ///
    /// They agree **while the window is inside the crop**. Where it is not — the camera may leave the
    /// picture now (`LoupeFraming.minimumPictureCoverage`) — only the window is the truth: `cropRect`
    /// becomes the *document's* crop and a document stays inside the crop it describes. That case is
    /// asserted as such rather than averaged away, and the window's size is asserted to be the
    /// viewport at the stop, because that is what "the visible window is the canvas" means.
    func testOutputWindowAndTheDerivedCropNameTheSameRegionWhileItIsInsideTheCrop() {
        let crop = CropRect(left: 0.1, top: 0.08, right: 0.85, bottom: 0.72)
        var sawInside = 0, sawOutside = 0
        for degrees in [0.0, 7.0] {
            let f = framing(degrees: degrees, crop: crop)
            let frame = ImageSize(width: Int((f.cropWidthPixels * 1).rounded()),
                                  height: Int((f.cropHeightPixels * 1).rounded()))
            XCTAssertNil(f.outputWindow(of: .fit), "fit is the whole frame, so it names no window")
            for zoom in [1.0, 2.5, 4.0] {
                for centre in [(3000.0, 2000.0), (1200.0, 700.0), (5200.0, 3500.0)] {
                    let state = actual(zoom: zoom, x: centre.0, y: centre.1)
                    let rect = f.cropRect(of: state)
                    let window = f.outputWindow(of: state)
                    XCTAssertNotNil(window)
                    guard let window else { continue }
                    // `outputWindow` is in **content (device) pixels**, not source pixels: the window
                    // is `viewport / zoom` source pixels drawn at `zoom`, which is the viewport — the
                    // canvas is filled at every stop, and there is no second, hidden zoom.
                    XCTAssertEqual(Double(window.width), Double(viewport.width), accuracy: 1.0)
                    XCTAssertEqual(Double(window.height), Double(viewport.height), accuracy: 1.0)
                    let inside = window.x >= 0 && window.y >= 0
                        && window.x + window.width <= frame.width
                        && window.y + window.height <= frame.height
                    if inside {
                        sawInside += 1
                        // crop rect (source pixels) → content pixels, relative to the crop's origin.
                        XCTAssertEqual(Double(window.x), (rect.left * f.sourceWidth - f.cropOriginX) * zoom,
                                       accuracy: 1.0 * zoom,
                                       "θ=\(degrees) z=\(zoom): window origin x drifted")
                        XCTAssertEqual(Double(window.y), (rect.top * f.sourceHeight - f.cropOriginY) * zoom,
                                       accuracy: 1.0 * zoom,
                                       "θ=\(degrees) z=\(zoom): window origin y drifted")
                        XCTAssertEqual(Double(window.width), rect.width * f.sourceWidth * zoom,
                                       accuracy: 1.0 * zoom)
                    } else {
                        sawOutside += 1
                        // The derived *document* is still bounded by the frame (a crop rect is a
                        // normalized rect on the picture, and it may not leave it); the camera may.
                        XCTAssertGreaterThanOrEqual(rect.left, -1e-9)
                        XCTAssertGreaterThanOrEqual(rect.top, -1e-9)
                        XCTAssertLessThanOrEqual(rect.right, 1 + 1e-9)
                        XCTAssertLessThanOrEqual(rect.bottom, 1 + 1e-9)
                        XCTAssertTrue(window.x < 0 || window.y < 0
                                        || window.x + window.width > frame.width
                                        || window.y + window.height > frame.height,
                                      "an out-of-frame window must be reported as such")
                    }
                }
            }
        }
        XCTAssertGreaterThan(sawInside, 0, "some of these windows are inside the crop")
        XCTAssertGreaterThan(sawOutside, 0, "and some are not — that is the new freedom")
    }

    // MARK: 9. display headroom

    /// The brief's "maximum EDR − 1", made safe: AppKit reports a multiplier of SDR white, so the
    /// ceiling is 1 + extra. An SDR screen (or a missing one) floors to exactly 1 and nothing throws.
    func testHeadroomArithmeticAndDegradation() {
        XCTAssertEqual(DisplayHeadroom.headroom(fromMaximumEDR: 1.0), 1, accuracy: 1e-12)
        XCTAssertEqual(DisplayHeadroom.headroom(fromMaximumEDR: 0.5), 1, accuracy: 1e-12)
        XCTAssertEqual(DisplayHeadroom.headroom(fromMaximumEDR: 1.2), 1.2, accuracy: 1e-12)
        XCTAssertEqual(DisplayHeadroom.headroom(fromMaximumEDR: 16), 16, accuracy: 1e-12)
        XCTAssertEqual(DisplayHeadroom.headroom(fromMaximumEDR: 100), DisplayHeadroom.maximumHeadroom,
                       accuracy: 1e-12)
        XCTAssertEqual(DisplayHeadroom.headroom(fromMaximumEDR: .nan), 1, accuracy: 1e-12)
        XCTAssertEqual(DisplayHeadroom.headroom(fromMaximumEDR: .infinity), 1, accuracy: 1e-12)

        let sdr = DisplayHeadroom(headroom: 1, screenName: "27G7K-Ultra", maximumEDRComponent: 1,
                                  source: .sdr)
        XCTAssertFalse(sdr.isHDR)
        XCTAssertTrue(sdr.isDegraded)
        XCTAssertEqual(sdr.displayText, "SDR 显示器 · headroom 1.00×")

        let hdr = DisplayHeadroom(headroom: 1.2, screenName: "Built-in Retina Display",
                                  maximumEDRComponent: 1.2, source: .extendedRange)
        XCTAssertTrue(hdr.isHDR)
        XCTAssertEqual(hdr.displayText, "HDR 显示器 · headroom 1.20×")

        // A layer that refused the 16-bit drawable degrades to SDR instead of clipping in 8-bit.
        let refused = DisplayHeadroom(headroom: 1, screenName: "Built-in Retina Display",
                                      maximumEDRComponent: 16, source: .layerRefusedEDR)
        XCTAssertFalse(refused.isHDR)
        XCTAssertTrue(refused.displayText.contains("8-bit"))
    }

    @MainActor
    func testHeadroomOnThisMachineIsReadablePerScreenAndNeverThrows() {
        // No window, no screen → SDR, and the controller still works.
        let unknown = DisplayHeadroom.current(for: nil)
        XCTAssertEqual(unknown.headroom, 1, accuracy: 1e-12)
        XCTAssertEqual(unknown.source, .unknown)

        for screen in NSScreen.screens {
            let h = DisplayHeadroom.current(for: screen)
            XCTAssertGreaterThanOrEqual(h.headroom, 1)
            XCTAssertLessThanOrEqual(h.headroom, DisplayHeadroom.maximumHeadroom)
            // The reported value is a multiplier, so the ceiling is the value itself.
            XCTAssertEqual(h.headroom,
                           DisplayHeadroom.headroom(fromMaximumEDR: Double(screen.maximumExtendedDynamicRangeColorComponentValue)),
                           accuracy: 1e-12)
            print("screen headroom: \(screen.localizedName) max=\(screen.maximumExtendedDynamicRangeColorComponentValue) → \(h.detailText)")
        }

        // A 16-bit-refusing layer on an XDR screen must degrade, not claim HDR.
        if let xdr = NSScreen.screens.first(where: {
            $0.maximumExtendedDynamicRangeColorComponentValue > 1.0001
        }) {
            let degraded = DisplayHeadroom.current(for: xdr, layerAcceptsEDR: false)
            XCTAssertEqual(degraded.headroom, 1, accuracy: 1e-12)
            XCTAssertEqual(degraded.source, .layerRefusedEDR)
        }
    }

    @MainActor
    func testStatusTextSaysWhichDisplayAndWhereTheCameraIs() {
        let controller = LoupeController(session: CatalogSession())
        controller.setDisplayHeadroom(.init(headroom: 1.2, screenName: "Built-in Retina Display",
                                            maximumEDRComponent: 1.2, source: .extendedRange))
        XCTAssertTrue(controller.statusText.contains("HDR 显示器"), controller.statusText)
        XCTAssertTrue(controller.statusText.contains("1.20"), controller.statusText)
        XCTAssertTrue(controller.statusText.contains("适应"), controller.statusText)

        controller.setDisplayHeadroom(.init(headroom: 1, screenName: "27G7K-Ultra",
                                            maximumEDRComponent: 1, source: .sdr))
        XCTAssertTrue(controller.statusText.contains("SDR 显示器"), controller.statusText)
        XCTAssertTrue(controller.statusText.contains("headroom 1.00"), controller.statusText)
    }
}
