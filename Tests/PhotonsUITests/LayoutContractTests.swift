import XCTest
import AppKit
import PhotonsCore
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

    // MARK: the inspector's 黑白 card

    /// **The card, as a layout contract** (2026-10-28): where 黑白 sits in the panel, how many rows it
    /// draws (**9** = 1 switch + 8 mixes), and the card width that is `面板 − 2·12 − 2·16` at the three
    /// allowed panel widths — **244 / 274 / 308**.
    ///
    /// The three numbers the acceptance names are the card's *content* widths, and this is why: the
    /// inspector's `300 … 364` (`WorkspaceLayout.inspectorWidthMin … Max`) minus the column's 12 pt
    /// padding on each side and the card's own 16 pt inset. Pinning the identity here means a card that
    /// changed the panel's insets cannot quietly keep the old row geometry (the rendered proof is
    /// `BlackAndWhiteCardTests`, which measures the rows at exactly these three widths).
    func testTheBlackAndWhiteCardIsNineRowsInTheColourWorkspaceAtTheThreeContentWidths() throws {
        // 2026-10-28 (user): 黑白 moved out of 调整 into 色彩 — it is a colour partition (a luminance
        // switch), so it sits with HSL's hue bands and 色彩分级's luminance wheels.
        XCTAssertEqual(InspectorWorkspace.colour.cards, [.hsl, .colorGrading, .blackAndWhite])
        let sections = InspectorView.sections(in: .colour)
        XCTAssertEqual(sections.last, .blackAndWhite, "黑白是色彩工作区的最后一张卡：\(sections)")
        XCTAssertFalse(InspectorView.sections(in: .adjust).contains(.blackAndWhite),
                       "调整里不许再有黑白卡")
        XCTAssertEqual(InspectorView.Section.blackAndWhite.title, "黑白")

        // 1 switch + 8 mixes, derived from the card's own table.
        XCTAssertEqual(InspectorView.bwRows.count, ColorGroup.bandCount)
        XCTAssertEqual(InspectorView.blackAndWhiteRowCount, 9)
        XCTAssertEqual(InspectorView.bwRows.map(\.title),
                       ["红", "橙", "黄", "绿", "青", "蓝", "紫", "品红"])

        // The panel widths the resolver allows ↔ the card content widths the rows are measured at.
        XCTAssertEqual(WorkspaceLayout.inspectorWidthMin, 300)
        XCTAssertEqual(WorkspaceLayout.inspectorWidthMax, 364)
        XCTAssertEqual(WorkspaceLayout.cardInsetH, 16)
        let contentWidths = [WorkspaceLayout.inspectorWidthMin, 330, WorkspaceLayout.inspectorWidthMax]
            .map { $0 - 2 * 12 - 2 * WorkspaceLayout.cardInsetH }
        XCTAssertEqual(contentWidths, [244, 274, 308],
                       "面板 300/330/364 → 卡内容 244/274/308（行按这三个宽度量）")
        // The panel can never be narrower than the narrowest width this card was measured at.
        XCTAssertGreaterThanOrEqual(WorkspaceLayout.inspectorWidthMin, 300,
                                    "比实测更窄的面板会出现没有验证过的行宽")
    }

    // MARK: the inspector's Light card

    /// **The Light card's seven rows, in the user's order** (085/090): 曝光 → 对比 → 高光 → 中间调 →
    /// 阴影 → 白色 → 黑色. The card is content-derived (046/052), so adding 中间调 changes the row count,
    /// not a pinned height; the three content widths the rows are measured at are the same
    /// **244 / 274 / 308** pt identity every other card uses.
    func testTheLightCardIsSevenRowsWithMidtonesBetweenHighlightsAndShadows() throws {
        let rows = InspectorView.lightRows
        XCTAssertEqual(rows.map(\.title),
                       ["曝光", "对比", "高光", "中间调", "阴影", "白色", "黑色"],
                       "用户口径：高光 → 中间调 → 阴影；其余五行的顺序不动")
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows.map(\.shape), Array(repeating: .knob, count: 7),
                       "七根都是显示域渲染参数（.knob）")
        XCTAssertEqual(rows.map(\.keyPath),
                       [\.light.exposure, \.light.contrast, \.light.highlights,
                        \.light.midtones, \.light.shadows, \.light.whites, \.light.blacks],
                       "中间调直达 085 的 `light.midtones`，不需要新的接线")
        for row in rows.dropFirst() {
            XCTAssertEqual(row.range, -100 ... 100, "\(row.title) 与高光/阴影同为 ±100")
            XCTAssertEqual(row.format, "%.0f")
            XCTAssertEqual(row.decimals, 1)
        }

        let contentWidths = [WorkspaceLayout.inspectorWidthMin, 330, WorkspaceLayout.inspectorWidthMax]
            .map { $0 - 2 * 12 - 2 * WorkspaceLayout.cardInsetH }
        XCTAssertEqual(contentWidths, [244, 274, 308],
                       "面板 300/330/364 → 卡内容 244/274/308（Light 的七行也按这三个宽度画）")
    }

    // MARK: the inspector's 色彩分级 card

    /// **The card, as a layout contract** (2026-10-28, P0 色彩分级): where it sits (the 色彩 workspace,
    /// after HSL — the pipeline's own `.hsl, .grade` order), how many rows it draws (**9** = 3 wheels ×
    /// 3 axes), and the panel width identity every row is measured at.
    ///
    /// The rendered proof is `ColorGradingCardTests`, which hosts the panel and measures the nine rows at
    /// exactly 244 / 274 / 308 pt of card content.
    func testTheColorGradingCardIsNineRowsAfterHSLInTheColourWorkspace() throws {
        XCTAssertEqual(InspectorView.Section.colorGrading.title, "色彩分级")
        XCTAssertEqual(InspectorWorkspace.colour.cards, [.hsl, .colorGrading, .blackAndWhite],
                       "色彩工作区的三张卡：HSL / 色彩分级 / 黑白")
        let sections = InspectorView.sections(in: .colour)
        XCTAssertEqual(sections, [.hsl, .colorGrading, .blackAndWhite],
                       "渲染顺序来自 Section.allCases：\(sections)")

        // The pipeline says the same: S3.8 runs directly after S3.6 and before detailFX.
        let order = RenderStage.order
        let hsl = try XCTUnwrap(order.firstIndex(of: .hsl))
        let grade = try XCTUnwrap(order.firstIndex(of: .grade))
        let vignette = try XCTUnwrap(order.firstIndex(of: .vignette))
        let contrast = try XCTUnwrap(order.firstIndex(of: .contrast))
        let dehaze = try XCTUnwrap(order.firstIndex(of: .dehaze))
        // 116 把暗角搬进线性链末尾，117 把去雾插在它与对比度之间 —— 相邻关系因此不再成立。
        // What survives is the *position*: dehaze directly follows contrast, the vignette directly
        // follows dehaze (the linear tail), and both sit before the tone map and the grade.
        let detail = try XCTUnwrap(order.firstIndex(of: .detailFX))
        XCTAssertEqual(detail, grade + 1, "S3.9 紧跟 S3.8：\(order.map(\.short))")
        XCTAssertEqual(dehaze, contrast + 1, "117: 去雾紧跟对比度：\(order.map(\.short))")
        XCTAssertEqual(vignette, dehaze + 1, "117: 去雾在对比度与暗角之间：\(order.map(\.short))")
        XCTAssertLessThan(vignette, grade, "116: 暗角在线性链，色彩分级在显示链")
        XCTAssertLessThan(hsl, grade)

        // 3 wheels × 3 axes, derived from the card's own table.
        XCTAssertEqual(InspectorView.gradeRows.count, GradeRegion.allCases.count * GradeAxis.allCases.count)
        XCTAssertEqual(InspectorView.colorGradingRowCount, 9)
        XCTAssertEqual(InspectorView.gradeRows.map(\.region),
                       (0..<3).flatMap { [GradeRegion.allCases[$0], GradeRegion.allCases[$0],
                                          GradeRegion.allCases[$0]] })
        XCTAssertEqual(InspectorView.gradeRows.map(\.axis), Array(repeating: GradeAxis.allCases,
                                                                  count: 3).flatMap { $0 })
        XCTAssertEqual(InspectorView.gradeRows.first?.title, "色相")
        XCTAssertEqual(InspectorView.gradeRows.map(\.fieldKey).first, "colorGrading.shadows.hue")

        // The panel widths `WorkspaceLayout` allows ↔ the card content widths the rows are measured at.
        let contentWidths = [WorkspaceLayout.inspectorWidthMin, 330, WorkspaceLayout.inspectorWidthMax]
            .map { $0 - 2 * 12 - 2 * WorkspaceLayout.cardInsetH }
        XCTAssertEqual(contentWidths, [244, 274, 308])
    }

    // MARK: the inspector's 色差 rows

    /// **The two rows, as a layout contract** (2026-10-28, 078 B8 / 096): 色差 lives on its own 校正
    /// card, which sits directly between 细节 and 效果. The card adds **2** rows, owns the same two
    /// document fields, and every row is measured at — **244 / 274 / 308** pt of card content, i.e. the
    /// inspector's `300 … 364` minus the column's 12 pt padding and the card's own 16 pt inset.
    ///
    /// The rendered proof is `ChromaticAberrationCardTests`, which hosts the panel and measures the two
    /// rows at exactly these three widths.
    func testTheChromaticAberrationRowsAreTwoInTheCorrectionCardAtTheThreeContentWidths() throws {
        XCTAssertEqual(InspectorView.Section.detail.title, "细节")
        XCTAssertEqual(InspectorView.Section.correction.title, "校正")
        XCTAssertTrue(InspectorWorkspace.adjust.cards.contains(.correction), "色差 在「调整」的校正卡里")
        let sections = InspectorView.sections(in: .adjust)
        XCTAssertTrue(sections.contains(.correction), "调整 工作区里画校正卡：\(sections)")

        // 096: 细节 → 校正 → 效果, adjacent and in that order.
        let detail = try XCTUnwrap(sections.firstIndex(of: .detail))
        let correction = try XCTUnwrap(sections.firstIndex(of: .correction))
        let effects = try XCTUnwrap(sections.firstIndex(of: .effects))
        XCTAssertEqual(correction, detail + 1, "校正 紧跟在细节之后：\(sections)")
        XCTAssertEqual(effects, correction + 1, "效果 紧跟在校正之后：\(sections)")

        // 2 rows, in the card's own table, and nothing else grew.
        XCTAssertEqual(InspectorView.caRows.count, 2)
        XCTAssertEqual(InspectorView.caRows.map(\.title), ["色差 R", "色差 B"])
        XCTAssertEqual(InspectorView.detailContent.rows.count, 4, "四根解码行没变")
        for row in InspectorView.caRows {
            XCTAssertEqual(row.range, -100 ... 100, "\(row.title)：滑杆单位，整数")
            XCTAssertEqual(row.shape, .linear, "\(row.title)：线性域 → 红")
            XCTAssertEqual(row.format, "%.0f")
        }
        // 029's two fields, not a second set: one unit is `5e-5` of α and 100 is the full scale.
        XCTAssertEqual(OpticsGroup.sliderRange, -100 ... 100)
        XCTAssertEqual(OpticsGroup.alpha(fromSlider: 100), OpticsGroup.fullScale, accuracy: 1e-15)

        // The panel widths `WorkspaceLayout` allows ↔ the card content widths the rows are measured at.
        let contentWidths = [WorkspaceLayout.inspectorWidthMin, 330, WorkspaceLayout.inspectorWidthMax]
            .map { $0 - 2 * 12 - 2 * WorkspaceLayout.cardInsetH }
        XCTAssertEqual(contentWidths, [244, 274, 308])
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

    // MARK: 相册段（078 B10）

    /// 相册段不是第二个侧栏：它住在同一个 `NSOutlineView` 里，所以行高、行距、高度公式、
    /// 侧栏宽度都与文件夹行完全一致 —— 多加一个区段不新增一个布局契约。
    ///
    /// 这条是**故意**的：如果相册变成第二个滚动视图，就要再定一次最小高度、再算一次
    /// "树与照片列表怎么分那 45 %"，而那正是 021 A 花了一轮才修好的那类数字。
    func testTheAlbumsSectionSharesTheBrowserTreeGeometry() {
        // 一行一个相册、一行一个文件夹：同一个 28 pt 常数（photo row 仍是 46）。
        XCTAssertEqual(WorkspaceLayout.browserTreeRowHeight, 28, accuracy: 0.001)
        XCTAssertEqual(WorkspaceLayout.browserRowHeight, 46, accuracy: 0.001)

        // 5 行（相册标题 + 3 个相册 + 全部照片）走同一个公式：rows × 28 + 6。
        XCTAssertEqual(WorkspaceLayout.browserTreeHeight(rowCount: 5, panelHeight: 744), 5 * 28 + 6,
                       accuracy: 0.001, "rows × 28 + 6, album rows included")
        // 多一个相册 = 多一行 = 高 28 pt（在没到 45 % 上限之前）。
        XCTAssertEqual(WorkspaceLayout.browserTreeHeight(rowCount: 9, panelHeight: 744)
                       - WorkspaceLayout.browserTreeHeight(rowCount: 5, panelHeight: 744), 4 * 28,
                       accuracy: 0.001)

        // 侧栏宽度不因为多了相册段而变：212 pt 默认，仍夹在 196…260。
        let g = WorkspaceLayout.resolve(window: CGSize(width: 1600, height: 1000))
        XCTAssertEqual(g.browser.width, WorkspaceLayout.browserWidthDefault, accuracy: 0.001)
        XCTAssertEqual(g.browser.width, 212, accuracy: 0.001)
    }
}
