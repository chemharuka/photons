import XCTest
import AppKit
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 223 — the three cells decode at **their own display pixels**, not at 1920.
///
/// The numbers come from the live controllers (their layout constants, their window's backing
/// scale), so a layout change that makes a cell bigger moves the decode size with it instead of
/// leaving a hard-coded size behind.
@MainActor
final class ThumbnailDisplaySize223Tests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private func makeWindow() -> NSWindow {
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
        windows.append(window)
        return window
    }

    func testTheThreeViewsAskForTheirOwnDisplayPixels() throws {
        let window = makeWindow()
        let session = CatalogSession()
        let scale = window.backingScaleFactor
        XCTAssertGreaterThanOrEqual(scale, 1)

        // Grid: the card minus its caption, at the window's backing scale.
        let grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: 1400, height: 780)
        window.contentView?.addSubview(grid.view)

        // Filmstrip: 90 × 72 pt cell, image area 90 × 60 pt (3:2).
        let strip = FilmstripController(session: session)
        _ = strip.view
        strip.view.frame = NSRect(x: 0, y: 0, width: 1400, height: WorkspaceLayout.filmstripHeight)
        window.contentView?.addSubview(strip.view)

        // Browser list: the 34 pt square.
        let browser = BrowserPaneController(session: session)
        _ = browser.view
        browser.view.frame = NSRect(x: 0, y: 0, width: 212, height: 800)
        window.contentView?.addSubview(browser.view)

        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        grid.view.layoutSubtreeIfNeeded()
        strip.view.layoutSubtreeIfNeeded()

        let gridSize = grid.displayPixelSize
        let stripSize = strip.displayPixelSize
        let listSize = browser.displayPixelSize

        print("223 display pixels: grid \(gridSize.width)×\(gridSize.height) · "
              + "strip \(stripSize.width)×\(stripSize.height) · "
              + "list \(listSize.width)×\(listSize.height) · scale \(scale)")

        // Filmstrip and list are layout constants: 90×60 pt and 34×34 pt.
        XCTAssertEqual(stripSize, ThumbnailProvider.displayPixels(
            swatch: CGSize(width: WorkspaceLayout.filmstripCell.width,
                           height: WorkspaceLayout.filmstripCell.height
                               - WorkspaceLayout.filmstripCaptionHeight),
            backingScale: scale))
        XCTAssertEqual(listSize, ThumbnailProvider.displayPixels(
            swatch: CGSize(width: BrowserPaneController.thumbnailSide,
                           height: BrowserPaneController.thumbnailSide),
            backingScale: scale))

        // Grid: the live metrics (card minus caption), and inside the brief's ≤400×296 ceiling at 2×.
        XCTAssertEqual(gridSize, ThumbnailProvider.displayPixels(
            swatch: CGSize(width: grid.metrics.itemSize.width,
                           height: grid.metrics.itemSize.height - GridLayout.labelHeight),
            backingScale: scale))
        if scale == 2 {
            XCTAssertLessThanOrEqual(gridSize.width, 400, "grid ≤ 400 px at 2×")
            XCTAssertLessThanOrEqual(gridSize.height, 296, "grid ≤ 296 px at 2×")
            XCTAssertEqual(stripSize, ImageSize(width: 180, height: 120))
            XCTAssertEqual(listSize, ImageSize(width: 68, height: 68))
        }
    }

    /// The pure helper is what all three call; its rounding must be one implementation.
    func testDisplayPixelsAtTwoTimesAreTheThreeNumbersInTheBrief() {
        XCTAssertEqual(ThumbnailProvider.displayPixels(
            swatch: CGSize(width: 34, height: 34), backingScale: 2),
            ImageSize(width: 68, height: 68))
        XCTAssertEqual(ThumbnailProvider.displayPixels(
            swatch: CGSize(width: WorkspaceLayout.filmstripCell.width,
                           height: WorkspaceLayout.filmstripCell.height
                               - WorkspaceLayout.filmstripCaptionHeight),
            backingScale: 2),
            ImageSize(width: 180, height: 120))
        XCTAssertEqual(ThumbnailProvider.displayPixels(
            swatch: CGSize(width: 163, height: 121), backingScale: 2),
            ImageSize(width: 326, height: 242))
        // Never zero: a sub-point swatch is floored at 1 pt before the scale is applied.
        XCTAssertEqual(ThumbnailProvider.displayPixels(
            swatch: CGSize(width: 0.1, height: 0.1), backingScale: 2),
            ImageSize(width: 2, height: 2))
    }
}
