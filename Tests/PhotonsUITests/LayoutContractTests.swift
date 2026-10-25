import XCTest
import AppKit
import PhotonsUI

/// The layout contract of docs/tasks/004-ui-skeleton.md §2b, as a test.
///
/// "The grid has 5 columns here" is only a claim unless both sides come from a function: the views
/// call `GridLayout.metrics` / `WorkspaceLayout.resolve`, and `--ui-smoke` compares what the flow
/// layout actually did against these numbers.
final class LayoutContractTests: XCTestCase {

    // MARK: top bar and panels

    func testToolBarIsThirtySixPointsAndSharesTheTrafficLightLine() {
        let g = WorkspaceLayout.resolve(window: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(g.topBar.height, 36, accuracy: 0.001)
        XCTAssertEqual(g.topBar.midY, 30, accuracy: 0.001, "12 pt inset + 18 pt half-height")
        // Body starts right under the tool container: the canvas has no extra margin.
        XCTAssertEqual(g.canvas.minY, g.topBar.maxY, accuracy: 0.001)
        XCTAssertEqual(g.browser.minY, g.topBar.maxY, accuracy: 0.001)
    }

    func testToolBarFollowsAnExplicitTrafficLightCentre() {
        let g = WorkspaceLayout.resolve(window: CGSize(width: 1400, height: 900), trafficLightCentreY: 34)
        XCTAssertEqual(g.topBar.midY, 34, accuracy: 0.001)
        XCTAssertEqual(g.topBar.minY, 16, accuracy: 0.001)
    }

    func testPanelWidthsAreClampedToTheirContractRanges() {
        let narrow = WorkspaceLayout.resolve(window: CGSize(width: 1600, height: 1000),
                                             browserWidth: 10, inspectorWidth: 100)
        XCTAssertEqual(narrow.browser.width, WorkspaceLayout.browserWidthMin, accuracy: 0.001)
        XCTAssertEqual(narrow.inspector.width, WorkspaceLayout.inspectorWidthMin, accuracy: 0.001)

        let wide = WorkspaceLayout.resolve(window: CGSize(width: 2400, height: 1200),
                                          browserWidth: 900, inspectorWidth: 900)
        XCTAssertEqual(wide.browser.width, WorkspaceLayout.browserWidthMax, accuracy: 0.001)
        XCTAssertEqual(wide.inspector.width, WorkspaceLayout.inspectorWidthMax, accuracy: 0.001)

        let defaults = WorkspaceLayout.resolve(window: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(defaults.browser.width, 212, accuracy: 0.001)
        XCTAssertEqual(defaults.inspector.width, 330, accuracy: 0.001)
    }

    func testThreeWindowWidthsKeepTheSafeEditingArea() {
        for width in [1200.0, 1600.0, 2400.0] {
            let g = WorkspaceLayout.resolve(window: CGSize(width: width, height: 900))
            XCTAssertGreaterThanOrEqual(g.canvas.width, WorkspaceLayout.minimumSafeCanvas.width,
                                        "canvas collapsed at w=\(width)")
            XCTAssertGreaterThanOrEqual(g.canvas.width, 560)
            XCTAssertEqual(g.canvas.maxX + WorkspaceLayout.dividerThickness + g.inspector.width,
                           g.window.width, accuracy: 0.001)
        }
    }

    func testFilmstripTakes122PointsAndSpansCanvasWidth() throws {
        let list = WorkspaceLayout.resolve(window: CGSize(width: 1600, height: 900), mode: .list)
        XCTAssertNil(list.filmstrip)

        let strip = WorkspaceLayout.resolve(window: CGSize(width: 1600, height: 900), mode: .filmstrip)
        let filmstrip = try XCTUnwrap(strip.filmstrip)
        XCTAssertEqual(filmstrip.height, 122, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(strip.canvas.height, 420, "canvas lost its safe height to the strip")
        // The strip stops at the inspector; the inspector runs full height beside it.
        XCTAssertLessThanOrEqual(strip.filmstrip?.maxX ?? 0, strip.inspector.minX + 0.001)
        XCTAssertEqual(strip.inspector.height, strip.window.height - strip.topBar.maxY, accuracy: 0.001)
    }

    func testShrinkingPanelsProtectsTheCanvas() {
        // 1200 is the minimum window; with both panels at their maximum the canvas must still exist.
        let tight = WorkspaceLayout.resolve(window: CGSize(width: 1200, height: 780),
                                           browserWidth: 260, inspectorWidth: 364)
        XCTAssertGreaterThanOrEqual(tight.canvas.width, 560 - 0.001)
        XCTAssertEqual(tight.browser.width, 260, accuracy: 0.001)
        XCTAssertEqual(tight.inspector.width, 364, accuracy: 0.001)
        // Below the minimum the resolver holds the minimum instead of producing negative frames.
        let tiny = WorkspaceLayout.resolve(window: CGSize(width: 900, height: 600),
                                          browserWidth: 260, inspectorWidth: 364)
        XCTAssertGreaterThanOrEqual(tiny.canvas.width, 560 - 0.001)
        XCTAssertEqual(tiny.window.width, 1200, accuracy: 0.001)
        XCTAssertEqual(tiny.window.height, 780, accuracy: 0.001)
    }

    // MARK: grid

    func testGridColumnsFollowThePureFunctionAtThreeWidths() {
        // Widths a real canvas has at the three smoke window sizes (1600 − 212 − 330 − 2 dividers).
        let widths: [(CGFloat, Int)] = [(1056, 6), (1456, 8), (2256, 13)]
        for (width, columns) in widths {
            let m = GridLayout.metrics(forWidth: width)
            XCTAssertEqual(m.columns, columns, "columns at width \(width)")
            XCTAssertEqual(m.rowHeight, m.itemSize.height + m.spacing, accuracy: 0.001)
        }
    }

    func testGridNeverProducesAFractionalOrZeroColumn() {
        for width in stride(from: CGFloat(200), through: 4000, by: 37) {
            let m = GridLayout.metrics(forWidth: width)
            XCTAssertGreaterThanOrEqual(m.columns, 1)
            XCTAssertGreaterThan(m.itemSize.width, 0)
            XCTAssertGreaterThanOrEqual(m.itemSize.width, 0)
            // Item width never exceeds the usable width.
            XCTAssertLessThanOrEqual(m.itemSize.width * CGFloat(m.columns)
                                     + CGFloat(m.columns - 1) * m.spacing,
                                     max(width - 2 * m.inset, m.itemSize.width * CGFloat(m.columns)) + 1)
        }
    }

    func testGridIsMonotoneInWidth() {
        var previous = 0
        for width in stride(from: CGFloat(400), through: 3000, by: 50) {
            let columns = GridLayout.metrics(forWidth: width).columns
            XCTAssertGreaterThanOrEqual(columns, previous)
            previous = columns
        }
    }

    // MARK: placeholder swatch

    func testPlaceholderColourIsStableAndDistinct() {
        let a = PlaceholderSwatch.components(for: String(repeating: "ab", count: 32))
        let b = PlaceholderSwatch.components(for: String(repeating: "ab", count: 32))
        XCTAssertEqual(a.hue, b.hue)
        XCTAssertEqual(a.saturation, b.saturation)
        XCTAssertEqual(a.brightness, b.brightness)

        let c = PlaceholderSwatch.components(for: "ff00aa" + String(repeating: "12", count: 29))
        XCTAssertNotEqual(a.hue, c.hue, "different hashes must not produce the same swatch")

        for hue in [a.hue, c.hue] {
            XCTAssertTrue(hue >= 0 && hue <= 1)
        }
    }
}
