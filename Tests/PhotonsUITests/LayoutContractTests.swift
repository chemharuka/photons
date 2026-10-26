import XCTest
import AppKit
import PhotonsUI

/// The layout contract of the M3 shell (36 pt top bar, 212 pt sidebar, 122 pt filmstrip, 330 pt
/// inspector), as a test.
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

    func testFilmstripTakes83PointsAndSpansCanvasWidth() throws {
        let list = WorkspaceLayout.resolve(window: CGSize(width: 1600, height: 900), mode: .list)
        XCTAssertNil(list.filmstrip)

        let strip = WorkspaceLayout.resolve(window: CGSize(width: 1600, height: 900), mode: .filmstrip)
        let filmstrip = try XCTUnwrap(strip.filmstrip)
        XCTAssertEqual(filmstrip.height, 83, accuracy: 0.001, "8 inset + 69 cell + 6 inset = one row")
        XCTAssertEqual(filmstrip.height, WorkspaceLayout.filmstripHeight, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(strip.canvas.height, 420, "canvas lost its safe height to the strip")
        // The strip stops at the inspector; the inspector runs full height beside it.
        XCTAssertLessThanOrEqual(strip.filmstrip?.maxX ?? 0, strip.inspector.minX + 0.001)
        XCTAssertEqual(strip.inspector.height, strip.window.height - strip.topBar.maxY, accuracy: 0.001)
    }

    // MARK: filmstrip

    /// Old → new geometry, as arithmetic: the cell is ×1.5 and the container is exactly one cell
    /// plus its insets, because a `.horizontal` flow layout fills a **column** top-to-bottom — the
    /// old 122 pt strip (8 + 50 + 8 + 50 + 6 = 122) was exactly two 50 pt cells and one gap, which
    /// is why it rendered two rows while `scrollDirection` was already `.horizontal`.
    func testFilmstripCellIsHalfAgainAsTallAndOneFitsPerColumn() {
        XCTAssertEqual(WorkspaceLayout.filmstripCell.width, 111, accuracy: 0.001, "74 × 1.5")
        XCTAssertEqual(WorkspaceLayout.filmstripCell.height, 69, accuracy: 0.001, "57 image + 12 caption")
        XCTAssertEqual(WorkspaceLayout.filmstripCell.height - WorkspaceLayout.filmstripCaptionHeight,
                       57, accuracy: 0.001, "old image area 50 − 12 = 38, × 1.5")
        XCTAssertEqual(WorkspaceLayout.filmstripCaptionHeight, 12, accuracy: 0.001)

        let column = WorkspaceLayout.filmstripHeight
            - WorkspaceLayout.filmstripInsetTop - WorkspaceLayout.filmstripInsetBottom
        XCTAssertEqual(column, WorkspaceLayout.filmstripCell.height, accuracy: 0.001,
                       "83 − 8 − 6 = 69: the column holds the cell exactly")
        XCTAssertGreaterThan(2 * WorkspaceLayout.filmstripCell.height + WorkspaceLayout.filmstripSpacing,
                             column, "a second cell must not fit — that is what made two rows at 122")

        XCTAssertEqual(WorkspaceLayout.filmstripItemsPerColumn(containerHeight: 83), 1)
        XCTAssertEqual(WorkspaceLayout.filmstripItemHeight(for: 83), 69, accuracy: 0.001)
        // The old geometry, reproduced: a 50 pt cell in the 108 pt column of the 122 pt strip → 2 rows.
        XCTAssertEqual(WorkspaceLayout.filmstripItemsPerColumn(containerHeight: 122,
                                                               cellHeight: 50), 2)
        // The derivation is what keeps it single-row if the strip is ever made taller.
        XCTAssertEqual(WorkspaceLayout.filmstripItemHeight(for: 200), 186, accuracy: 0.001)
        XCTAssertEqual(WorkspaceLayout.filmstripItemsPerColumn(containerHeight: 200), 1)
    }

    /// Single-row evidence from the layout engine itself: 40 items through a real
    /// `NSCollectionViewFlowLayout` configured exactly as `FilmstripController` configures it.
    /// Every item must land on one `minY`, the applied size must be the contract cell, and the
    /// content must be wider than the viewport (so the strip still scrolls horizontally).
    ///
    /// The same fixture with the **old** numbers (122 pt strip, 50 pt cell, `.horizontal`) produces
    /// two baselines — that is the two-row bug, reproduced on demand instead of described.
    func testFilmstripFlowLayoutPutsEveryItemInOneRow() throws {
        let strip = try LayoutContractTests.layoutStrip(containerHeight: WorkspaceLayout.filmstripHeight,
                                                        itemSize: CGSize(width: WorkspaceLayout.filmstripCell.width,
                                                                         height: WorkspaceLayout.filmstripItemHeight(for: WorkspaceLayout.filmstripHeight)),
                                                        itemCount: 40)
        XCTAssertEqual(strip.collection.numberOfItems(inSection: 0), 40)
        XCTAssertEqual(strip.collection.enclosingScrollView?.hasVerticalScroller, false)

        let frames = strip.frames
        XCTAssertEqual(frames.count, 40, "every item laid out")
        let baselines = Set(frames.map { ($0.minY * 100).rounded() })
        XCTAssertEqual(baselines.count, 1, "one row: distinct item minY = 1, got \(baselines.sorted())")
        XCTAssertEqual(baselines.first ?? -1, (WorkspaceLayout.filmstripInsetTop * 100).rounded(),
                       accuracy: 0.001, "the row starts at the top section inset")

        let first = try XCTUnwrap(frames.first)
        XCTAssertEqual(first.width, WorkspaceLayout.filmstripCell.width, accuracy: 0.01)
        XCTAssertEqual(first.height, WorkspaceLayout.filmstripCell.height, accuracy: 0.01)
        let last = try XCTUnwrap(frames.last)
        XCTAssertEqual(last.minX, first.minX
                       + 39 * (WorkspaceLayout.filmstripCell.width + WorkspaceLayout.filmstripSpacing),
                       accuracy: 0.51, "items run horizontally, 8 pt apart")
        XCTAssertEqual(last.maxY, first.maxY, accuracy: 0.01, "same row")

        let content = strip.contentSize
        XCTAssertGreaterThan(content.width, strip.viewport.width, "content is wider than the strip")
        XCTAssertEqual(content.height, strip.viewport.height, accuracy: 0.01, "content is exactly one row tall")

        // Counter-example: identical setup, old constants. `.horizontal` alone never meant one row.
        let old = try LayoutContractTests.layoutStrip(containerHeight: 122,
                                                      itemSize: CGSize(width: 74, height: 50),
                                                      itemCount: 40)
        let oldBaselines = Set(old.frames.map { ($0.minY * 100).rounded() })
        XCTAssertEqual(oldBaselines.count, 2,
                       "122 pt (8+50+8+50+6) at .horizontal laid out two rows, got \(oldBaselines.sorted())")
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

/// The minimum data source a flow layout needs: N items of a given cell size, no thumbnails.
/// Used to ask the layout engine — not the constants — how many rows the strip actually produces.
private final class FilmstripFixtureDataSource: NSObject, NSCollectionViewDataSource {
    let count: Int
    let itemViewSize: CGSize
    let cellID = NSUserInterfaceItemIdentifier("FilmstripFixtureCell")

    init(count: Int, itemViewSize: CGSize) {
        self.count = count
        self.itemViewSize = itemViewSize
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: cellID, for: indexPath)
        if item.view == nil || item.view.frame.isEmpty {
            item.view = NSView(frame: NSRect(origin: .zero, size: itemViewSize))
        }
        return item
    }
}

private extension LayoutContractTests {
    struct StripFixture {
        let collection: NSCollectionView
        let viewport: CGSize
        let frames: [NSRect]
        let contentSize: CGSize
    }

    /// Build the strip's view hierarchy (`NSScrollView` → `NSCollectionView` → horizontal flow) at a
    /// given container height and item size, lay it out, and read back what the engine produced.
    static func layoutStrip(containerHeight: CGFloat, itemSize: CGSize,
                            itemCount: Int) throws -> StripFixture {
        let viewport = CGSize(width: 900, height: containerHeight)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        let collection = NSCollectionView(frame: NSRect(origin: .zero, size: viewport))
        let flow = NSCollectionViewFlowLayout()
        flow.scrollDirection = .horizontal
        flow.itemSize = itemSize
        flow.minimumInteritemSpacing = WorkspaceLayout.filmstripSpacing
        flow.minimumLineSpacing = WorkspaceLayout.filmstripSpacing
        flow.sectionInset = NSEdgeInsets(top: WorkspaceLayout.filmstripInsetTop,
                                         left: WorkspaceLayout.filmstripInsetH,
                                         bottom: WorkspaceLayout.filmstripInsetBottom,
                                         right: WorkspaceLayout.filmstripInsetH)
        let dataSource = FilmstripFixtureDataSource(count: itemCount, itemViewSize: itemSize)
        collection.collectionViewLayout = flow
        collection.dataSource = dataSource
        collection.register(NSCollectionViewItem.self, forItemWithIdentifier: dataSource.cellID)
        scroll.documentView = collection
        collection.reloadData()
        collection.layoutSubtreeIfNeeded()

        let frames = (0..<itemCount).compactMap {
            collection.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
        }
        return StripFixture(collection: collection, viewport: viewport, frames: frames,
                            contentSize: flow.collectionViewContentSize)
    }
}
