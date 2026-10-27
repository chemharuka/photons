import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// ③ (2026-10-27 用户要求加 12.5% 档) — the new rung, through **every** entry point.
///
/// The rules under test:
///
///   · the ladder is `fit … 12.5 % · 25 % · 33.3 % · 50 % · 66.7 % · 100 % · 200 % · 300 % · 400 %`,
///     ascending, with the eight older stops keeping their relative order;
///   · **⌘= / ⌘−** walk it: one ⌘− from 25 % stops at 12.5 % (not at fit), and the *next* ⌘− is fit;
///   · **the slider** can park the thumb on it: tick 0, chip `12.5%`, status readout `12.5%`;
///   · **裁切 mode** reaches it too, and the overlay follows (the same `syncCropOverlay` path ② fixed);
///   · **1:1 is untouched**: at 100 % the projection is still one source pixel per device pixel, and
///     12.5 % is exactly an eighth of it — the ladder gained a rung, not a new base.
@MainActor
final class ZoomTwelveHalfPercentTests: XCTestCase {

    private var workDir: URL!
    /// The controller holds its session **weakly**, so a test that only keeps the loupe alive would
    /// lose the projection (`framing()` → nil) the moment the tuple's second element went out of scope.
    private var keepAlive: [AnyObject] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-zoom-125-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// A loupe on a real library, laid out by hand (no window, no decode — this suite is about the
    /// camera and the chrome, and `CropZoomBaseTests` uses the same harness for the same reason).
    private func makeLoupe() throws -> (loupe: LoupeController, session: CatalogSession) {
        let (session, _) = try CropUITestSupport.makeSession(in: workDir)
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        loupe.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        loupe.canvasView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        loupe.view.layoutSubtreeIfNeeded()
        loupe.zoomSlider.layout(in: loupe.view.bounds)
        CropUITestSupport.pump(0.02)
        let deadline = Date().addingTimeInterval(2)
        while session.mode != .loupe || session.anchorAsset == nil, Date() < deadline {
            CropUITestSupport.pump(0.01)
        }
        // The projection is what every assertion below is about, so wait for it rather than assume the
        // anchor's publication turn has happened (the same reason `openCropTool` retries).
        let framingDeadline = Date().addingTimeInterval(5)
        while loupe.framing() == nil, Date() < framingDeadline {
            CropUITestSupport.pump(0.02)
        }
        XCTAssertNotNil(loupe.framing(),
                        "no projection: mode=\(session.mode) anchor=\(String(describing: session.anchorID)) "
                        + "viewport=\(loupe.viewportPixels) source=\(session.maskSourceSize)")
        keepAlive.append(session)
        return (loupe, session)
    }

    // MARK: - 1. the table, printed

    func testTheLadderIsNineStopsWithTwelveAndAHalfFirst() throws {
        let stops = LoupeViewState.zoomStops
        let labels = stops.map { LoupeViewState.percentLabel(of: $0) }
        print("③ 档位序列 · \(stops.map { String(format: "%.4g", $0) }.joined(separator: " · "))")
        print("③ 档位标签 · \(labels.joined(separator: " · "))")

        XCTAssertEqual(stops.first, 0.125, "12.5 % is the new first rung")
        XCTAssertEqual(labels.first, "12.5%")
        XCTAssertEqual(stops.count, 9)
        XCTAssertTrue(stops.contains(0.125))
        // The eight stops that were already there, in the same relative order.
        XCTAssertEqual(Array(stops.dropFirst()), [0.25, 1.0 / 3.0, 0.5, 2.0 / 3.0, 1, 2, 3, 4])
        XCTAssertEqual(stops, stops.sorted(), "still ascending")
        // `fit` is still not a rung.
        XCTAssertFalse(labels.contains("适应"))
        XCTAssertEqual(LoupeViewState.minimumZoom, 0.125, "the interactive floor moved with the ladder")
    }

    // MARK: - 2. ⌘= / ⌘−

    /// From fit, ⌘= lands on 100 % (unchanged), then walks up; ⌘− walks **all the way down through
    /// 12.5 %** and only then out to fit.
    func testCommandEqualsAndMinusWalkThroughTwelveAndAHalf() throws {
        let (loupe, session) = try makeLoupe()
        print("③ 起始 · mode \(session.mode) · 源 \(session.maskSourceSize.width)×\(session.maskSourceSize.height)"
              + " · viewport \(loupe.viewportPixels.width)×\(loupe.viewportPixels.height)"
              + " · fit \(String(format: "%.4f", loupe.framing()?.fitZoom ?? 0))")
        loupe.zoomToFit()
        XCTAssertEqual(loupe.viewState.mode, .fit)

        var ups: [String] = [loupe.zoomLabel]
        for _ in 0..<6 {
            loupe.zoomIn()
            ups.append(loupe.zoomLabel)
        }
        print("③ ⌘= 轨迹 · " + ups.joined(separator: " → "))
        XCTAssertEqual(ups, ["适应 19%", "100%", "200%", "300%", "400%", "400%", "400%"],
                       "⌘= from fit still lands on 100 %, then the ladder")

        // Back to 100 % and then down, one stop at a time — 12.5 % must be on the way.
        loupe.zoom(to: 1)
        var downs: [String] = [loupe.zoomLabel]
        var zooms: [Double] = [loupe.viewState.zoom]
        for _ in 0..<8 {
            loupe.zoomOut()
            downs.append(loupe.zoomLabel)
            zooms.append(loupe.viewState.isActualSize ? loupe.viewState.zoom : -1)
        }
        print("③ ⌘− 轨迹 · " + downs.joined(separator: " → "))
        print("③ ⌘− 倍率 · " + zooms.map { String(format: "%.4g", $0) }.joined(separator: " → "))
        XCTAssertEqual(downs, ["100%", "66.7%", "50%", "33.3%", "25%", "12.5%", "适应 19%", "适应 19%", "适应 19%"],
                       "⌘− stops on 12.5 % before it leaves the ladder for fit")
        XCTAssertEqual(zooms[5], 0.125, accuracy: 1e-12, "the 12.5 % stop is really reached")
        XCTAssertEqual(loupe.viewState.mode, .fit, "the step below 12.5 % is fit, as before")
    }

    // MARK: - 3. the slider

    /// The pill's thumb parks on tick 0 and the chip reads `12.5%`; the status readout says it too.
    func testTheSliderParksOnTwelveAndAHalfWithTheRightText() throws {
        let (loupe, _) = try makeLoupe()
        loupe.zoomToFit()
        loupe.zoomFromSlider(to: 0.125)

        let slider = loupe.zoomSlider
        print("③ slider at 12.5 % · label 「\(slider.labelText)」 · status 「\(loupe.statusText)」 · "
              + "thumb index \(String(describing: slider.thumbIndex)) · thumb centre "
              + String(format: "%.2f pt of x(forIndex:0) %.2f pt", slider.thumbCenterX,
                       slider.geometry.x(forIndex: 0))
              + " · accented ticks \(slider.accentedTickCount)")

        XCTAssertEqual(loupe.viewState.zoom, 0.125, accuracy: 1e-12)
        XCTAssertEqual(loupe.currentZoomStop, 0.125, "the camera is exactly on the new rung")
        XCTAssertEqual(slider.labelText, "12.5%", "the chip keeps one decimal — never 13%, never 0.125")
        XCTAssertTrue(loupe.statusText.hasSuffix("12.5%"), "status readout: \(loupe.statusText)")
        XCTAssertEqual(slider.thumbIndex, 0, "12.5 % is tick 0")
        XCTAssertEqual(slider.thumbCenterX, slider.geometry.x(forIndex: 0), accuracy: 1e-9,
                       "the thumb sits on the tick, not between ticks")
        XCTAssertEqual(slider.accentedTickCount, 1, "only the first tick is accented")
        XCTAssertEqual(slider.geometry.levels.first, 0.125, "the control's own table names it")

        // A pointer press on the first tick emits it (the pill is not a readout) — and the controller's
        // own wiring (which `testTheControllerWiresBothGestures` pins) still runs after ours.
        var emitted: [Double] = []
        let wiring = slider.onZoom
        slider.onZoom = { stop in
            emitted.append(stop)
            wiring?(stop)
        }
        loupe.zoomFromSlider(to: 1)
        slider.pointerDown(at: slider.point(forIndex: 0))
        slider.pointerUp()
        print("③ slider press on tick 0 emitted \(emitted)")
        XCTAssertEqual(emitted, [0.125])
        XCTAssertEqual(loupe.viewState.zoom, 0.125, accuracy: 1e-12)
        XCTAssertEqual(slider.labelText, "12.5%")
    }

    // MARK: - 4. 裁切 mode

    /// In 裁切 mode the new rung is reachable and the overlay is laid out on it — the same camera →
    /// overlay path ② fixed, so this is also the "12.5 % works with the frame up" evidence.
    func testTwelveAndAHalfWorksInCropModeAndTheOverlayFollows() throws {
        let (loupe, session) = try makeLoupe()
        XCTAssertTrue(CropUITestSupport.openCropTool(loupe, session))
        loupe.cropTool.draft = CropToolController.Draft(crop: CropRect(left: 0.35, top: 0.35,
                                                                      right: 0.65, bottom: 0.65))
        loupe.refreshCropTool()
        CropUITestSupport.pump(0.05)
        let atFit = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)

        loupe.zoomFromSlider(to: 0.125)
        CropUITestSupport.pump(0.05)
        let atRung = try XCTUnwrap(loupe.cropOverlayLayoutForTesting)
        let projected = try XCTUnwrap(loupe.cropToolLayout())

        let width = { (layout: CropToolLayout) -> CGFloat in
            hypot(layout.corners[1].x - layout.corners[0].x, layout.corners[1].y - layout.corners[0].y)
        }
        print(String(format: "③ 裁切 @12.5%% · frame width %.2f pt (fit %.2f pt) · ratio %.4f "
                     + "(expected %.4f) · overlay↔projection %.6f pt",
                     width(atRung), width(atFit), width(atRung) / width(atFit),
                     0.125 / (loupe.framing()?.fitZoom ?? 1),
                     zip(atRung.corners, projected.corners).map { hypot($0.x - $1.x, $0.y - $1.y) }.max() ?? 0))

        XCTAssertEqual(loupe.viewState.zoom, 0.125, accuracy: 1e-12)
        XCTAssertEqual(loupe.zoomSlider.labelText, "12.5%")
        XCTAssertEqual(width(atRung) / width(atFit),
                       0.125 / (loupe.framing()?.fitZoom ?? 1), accuracy: 0.02,
                       "the frame grew with the picture")
        for (drawn, want) in zip(atRung.corners, projected.corners) {
            XCTAssertEqual(drawn.x, want.x, accuracy: 1e-9, "the overlay is on the new rung's projection")
            XCTAssertEqual(drawn.y, want.y, accuracy: 1e-9)
        }
    }

    // MARK: - 5. 1:1 is untouched

    /// §A0's invariant, re-measured with the new rung in the table: 100 % is one source pixel per device
    /// pixel, and 12.5 % is exactly an eighth of that — the rung is a ratio against the same base.
    func testOneToOneSemanticsAreUnchanged() throws {
        let (loupe, _) = try makeLoupe()
        let framing = try XCTUnwrap(loupe.framing())
        let one = LoupeViewState(mode: .actual, zoom: 1, centerX: 0, centerY: 0)
        let eighth = LoupeViewState(mode: .actual, zoom: 0.125, centerX: 0, centerY: 0)

        let mapOne = framing.mapping(of: one)
        let mapEighth = framing.mapping(of: eighth)
        print(String(format: "③ 1:1 canvasPerSource %.6f · 12.5%% canvasPerSource %.6f · ratio %.6f",
                     mapOne.canvasPerSource, mapEighth.canvasPerSource,
                     mapOne.canvasPerSource / mapEighth.canvasPerSource))

        XCTAssertEqual(mapOne.canvasPerSource, 1, accuracy: 1e-12, "100 % is still 1 source px : 1 device px")
        XCTAssertEqual(mapOne.canvasPerSource / mapEighth.canvasPerSource, 8, accuracy: 1e-9,
                       "12.5 % is exactly one eighth of 1:1")
        // …and the source pixel / device pixel round trip still holds at 1:1.
        let a = mapOne.sourcePoint(viewX: 100, viewY: 100)
        let b = mapOne.sourcePoint(viewX: 101, viewY: 100)
        XCTAssertEqual(b.x - a.x, 1, accuracy: 1e-9)
        // The stop table did not touch the fit ratio either (it is the window's, not the ladder's).
        let vp = loupe.viewportPixels
        XCTAssertEqual(framing.fitZoom,
                       min(Double(vp.width) / framing.sourceWidth,
                           Double(vp.height) / framing.sourceHeight),
                       accuracy: 1e-12)
    }
}
