import CoreGraphics
import XCTest
@testable import PhotonsCore
import PhotonsUI

final class LoupeViewportTests: XCTestCase {

    private func makeFraming() -> LoupeFraming {
        LoupeFraming(viewport: ImageSize(width: 1000, height: 800),
                     sourceWidth: 4000, sourceHeight: 3000, crop: .full)
    }

    private func makeViewport() -> LoupeViewport {
        LoupeViewport(framing: makeFraming())
    }

    func testFitZoomIsWholeFrameFit() {
        let viewport = makeViewport()
        XCTAssertEqual(viewport.zoom, 0.25, accuracy: 1e-12)
    }

    func testFitHasNoOutputWindow() {
        let viewport = makeViewport()
        XCTAssertNil(viewport.framing.outputWindow(of: viewport.state))
    }

    func testZoomAtCentreKeepsCentre() {
        let viewport = makeViewport().zoomed(aroundCanvas: CGPoint(x: 500, y: 400), by: 2)
        XCTAssertEqual(viewport.zoom, 0.5, accuracy: 1e-12)
        let centre = viewport.framing.windowCenter(of: viewport.state)
        XCTAssertEqual(centre.x, 2000, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 1500, accuracy: 1e-9)
    }

    func testZoomAtOffsetKeepsThePointUnderTheCursor() {
        let before = makeViewport()
        let point = CGPoint(x: 250, y: 200)
        let sourceBefore = before.sourcePoint(atCanvas: point)
        let after = before.zoomed(aroundCanvas: point, by: 2)
        let sourceAfter = after.sourcePoint(atCanvas: point)
        XCTAssertEqual(sourceAfter.x, sourceBefore.x, accuracy: 1e-9)
        XCTAssertEqual(sourceAfter.y, sourceBefore.y, accuracy: 1e-9)
    }

    func testPanMovesCentreByCanvasDeltaOverZoom() {
        let state = LoupeViewState(mode: .actual, zoom: 0.5, centerX: 2000, centerY: 1500)
        let viewport = LoupeViewport(framing: makeFraming(), state: state)
            .panned(byCanvas: CGSize(width: 100, height: 0))
        let centre = viewport.framing.windowCenter(of: viewport.state)
        XCTAssertEqual(centre.x, 2000 - 100 / 0.5, accuracy: 1e-9)
        XCTAssertEqual(centre.y, 1500, accuracy: 1e-9)
        XCTAssertEqual(viewport.state.mode, .actual)
        XCTAssertEqual(viewport.state.zoom, 0.5, accuracy: 1e-12)
    }

    func testPanIsIgnoredInFit() {
        let viewport = makeViewport()
        let panned = viewport.panned(byCanvas: CGSize(width: 100, height: -40))
        XCTAssertEqual(panned.state, viewport.state)
    }

    func testResizeRecomputesFit() {
        let resized = makeViewport().resized(to: ImageSize(width: 2000, height: 1600))
        XCTAssertEqual(resized.zoom, 0.5, accuracy: 1e-12)
    }

    func testResizeKeepsActualZoomAndCentre() {
        let state = LoupeViewState(mode: .actual, zoom: 0.5, centerX: 2000, centerY: 1500)
        let viewport = LoupeViewport(framing: makeFraming(), state: state)
            .resized(to: ImageSize(width: 1600, height: 1200))
        XCTAssertEqual(viewport.state.mode, .actual)
        XCTAssertEqual(viewport.state.zoom, 0.5, accuracy: 1e-12)
        XCTAssertEqual(viewport.state.centerX, 2000, accuracy: 1e-9)
        XCTAssertEqual(viewport.state.centerY, 1500, accuracy: 1e-9)
    }

    func testZoomClampsToTheLadderEnds() {
        let viewport = makeViewport()
        let zoomedIn = viewport.zoomed(aroundCanvas: CGPoint(x: 500, y: 400), by: 100)
        XCTAssertEqual(zoomedIn.zoom, 4, accuracy: 1e-12)
        let zoomedOut = viewport.zoomed(aroundCanvas: CGPoint(x: 500, y: 400), by: 0.001)
        XCTAssertEqual(zoomedOut.zoom, 0.125, accuracy: 1e-12)
    }

    func testCanvasPointRoundTrip() {
        let state = LoupeViewState(mode: .actual, zoom: 0.75, centerX: 1800, centerY: 1300)
        let viewport = LoupeViewport(framing: makeFraming(), state: state)
        let point = CGPoint(x: 321, y: 233)
        let source = viewport.sourcePoint(atCanvas: point)
        let centre = viewport.framing.windowCenter(of: viewport.state)
        let canvasCentre = CGPoint(x: 500, y: 400)
        let back = CGPoint(x: Double(canvasCentre.x) + (Double(source.x) - centre.x) * viewport.zoom,
                           y: Double(canvasCentre.y) + (Double(source.y) - centre.y) * viewport.zoom)
        XCTAssertEqual(back.x, point.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, point.y, accuracy: 1e-9)
    }
}
