import XCTest
import AppKit
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// 050 — 「筛选栏有选择后，右侧就不要出现蓝色的单独关闭筛选条件的选项了，只保留清除全部四个字」
///
/// The removable-condition pills (`chipModels` / `chipRects`, an accent-tinted capsule + `×` per ticked
/// value, hit-tested in the bar's own `mouseDown`) are gone. What has to stay true instead:
///
/// 1. an active bar holds **only** the icon, N slot buttons and 「清除全部」 — no extra subview, and the
///    band the pills were painted in is plain background (no accent pixel at all);
/// 2. the button is hard right (`maxX == bounds.width - 12`), unbordered, 10.5 pt, grey — not blue;
/// 3. pressing it clears the slots, the filter, and hides itself;
/// 4. the width the pills used to eat went to the slot popups. Pre-050 measurements with the same bar
///    (5 slots, 3 conditions = 3 pills) are recorded next to each assertion.
@MainActor
final class FilterBarLayoutTests: XCTestCase {

    private var tmp: URL!
    private var library: URL!
    private var session: CatalogSession!
    private var grid: AssetGridController!
    private var bar: FilterBarView { grid.filterBar }

    private static let gridHeight: CGFloat = 600

    /// Pre-050 slot-popup widths, measured on this machine with the pill row still drawn
    /// (`TmpMeasureTests`, 5 slots + 3 pills — 星级 1★, 星级 5★, 旗标 留用):
    ///
    /// | bar width | slot width (before) | notes                                   |
    /// |-----------|---------------------|-----------------------------------------|
    /// | 1200      | 120.0 (the cap)     | 218 pt of pills sat right of the slots  |
    /// | 900       | 112.0               | the 35 % pill budget capped the popups  |
    /// | 700       | 72.0                | 2 of the 3 pills fit, 星级 5★ was dropped |
    private static let preChangeSlotWidth: [CGFloat: CGFloat] = [1200: 120.0, 900: 112.0, 700: 72.0]

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-050-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("bar.photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: library)
        let shoot = tmp.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: shoot, mode: .reference)
        for (index, rating) in [5, 3, 0].enumerated() {
            let name = "p\(index).dng"
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                              kind: .raw, size: 1, mtime: 0, contentHash: UUID().uuidString,
                              captureTime: "2026-10-0\(index + 1)T10:00:00Z",
                              captureLocalDate: "2026-10-0\(index + 1)",
                              rating: rating, cameraModel: "SL3", cameraKey: "leica|sl3", lens: "85mm")
            // p0 is 5★ *and* 留用: the one row that survives 星级 1★/5★ AND 旗标 留用.
            var row = asset
            row.flag = index == 0 ? "pick" : nil
            try catalog.dbQueue.write { db in try row.insert(db) }
        }

        session = CatalogSession()
        try session.open(library)
        grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: 1200, height: Self.gridHeight)
        grid.view.layoutSubtreeIfNeeded()
    }

    override func tearDownWithError() throws {
        session = nil
        grid = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: helpers

    private func layout(width: CGFloat) {
        grid.view.frame = NSRect(x: 0, y: 0, width: width, height: Self.gridHeight)
        grid.view.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
    }

    private func settle(_ turns: Int = 4) {
        for _ in 0..<turns { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        bar.layoutSubtreeIfNeeded()
    }

    /// 星级 1★、5★ + 旗标 留用 — the same three conditions the pre-050 numbers were taken with.
    private func activateThreeConditions() {
        bar.setSlotValues(["1", "5"], at: 0)
        settle()
        bar.setSlotValues(["pick"], at: 1)
        settle()
        XCTAssertEqual(session.filter.chips().count, 3, "模型层仍是三个条件（条上不再画）")
    }

    private func allSlotWidths() -> [CGFloat] {
        (0..<bar.slotVisibleCount).compactMap { bar.slotPopupFrame(at: $0)?.width }
    }

    // MARK: 1 — the bar's inventory

    /// Requirement 1: with a filter on, the bar is the icon + N slots + 「清除全部」, and nothing in it
    /// is a pill. The old pills were not subviews at all (they were painted by `draw` and hit-tested by
    /// rect), so the *pixel* check is the one that would have caught them; the subview count is the
    /// structural half.
    func testAnActiveBarDrawsOnlyTheIconSlotsAndClearAll() {
        activateThreeConditions()
        layout(width: 1200)

        XCTAssertEqual(bar.subviews.count, 1 + CatalogFilter.slotCapacity + 1,
                       "只有 图标 + 5 个槽位 + 「清除全部」")
        XCTAssertTrue(bar.subviews.allSatisfy { $0 is NSButton },
                      "条上每个控件都是按钮；画出来的胶囊不会是 NSButton")
        for subview in bar.subviews {
            XCTAssertNotEqual((subview as? NSButton)?.contentTintColor, .controlAccentColor,
                              "控件不许被染成 accent 蓝")
        }

        // The band the pills were painted in — right of the last slot, left of 「清除全部」 — is empty
        // background. Pre-050 this span held 3 accent capsules (fill 14 %, stroke 45 %).
        let lastSlot = bar.slotPopupFrame(at: bar.slotVisibleCount - 1)!
        let band = NSRect(x: lastSlot.maxX + 2, y: 0,
                          width: bar.clearButtonFrame.minX - lastSlot.maxX - 4,
                          height: bar.bounds.height)
        XCTAssertGreaterThan(band.width, 200, "1200 pt 条上胶囊原来占 218 pt 的那段空间还在")
        XCTAssertEqual(coloredPixelCount(in: bar, band: band), 0,
                       "槽位右侧不再有蓝色胶囊：那一段一个带色像素都不许有")
    }

    /// Any pixel with saturation above a hair is "coloured" — the pill's accent fill over the grey strip
    /// is ~0.4–0.9 saturation, while the strip, the bezels and the grey word are all under 0.1.
    private func coloredPixelCount(in view: NSView, band: NSRect, saturationFloor: CGFloat = 0.12) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return -1 }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / max(1, view.bounds.width)
        let x0 = max(0, Int((band.minX * scale).rounded(.down)))
        let x1 = min(rep.pixelsWide, Int((band.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((band.minY * scale).rounded(.down)))
        let y1 = min(rep.pixelsHigh, Int((band.maxY * scale).rounded(.up)))
        var count = 0
        for y in y0..<max(y0, y1) {
            for x in x0..<max(x0, x1) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                if saturation > saturationFloor { count += 1 }
            }
        }
        return count
    }

    // MARK: 2 — 「清除全部」 geometry and colour

    /// Requirement 2: hard right at every bar width, the owner's four words, no border, 10.5 pt, grey.
    func testClearAllSitsHardRightUnborderedAndGrey() {
        activateThreeConditions()

        for width in [1200.0, 700.0, 330.0] as [CGFloat] {
            layout(width: width)
            let frame = bar.clearButtonFrame
            XCTAssertFalse(bar.isClearButtonHidden, "有筛选时必须显示 at \(width)")
            XCTAssertEqual(frame.maxX, width - 12, accuracy: 0.5,
                           "「清除全部」贴右边缘 12 pt at \(width)")
            XCTAssertGreaterThanOrEqual(frame.minX, 0, "at \(width)")
            XCTAssertEqual(frame.width, FilterBarView.clearWidth(), accuracy: 0.5,
                           "宽度 = 文字实测 + 8 at \(width)")
            print("CLEARALL bar \(width): frame \(frame) maxX=\(frame.maxX) width=\(frame.width) title=\(bar.clearButtonTitle) textColor=\(String(describing: bar.clearButtonTextColor))")
            // Never overlapping the last slot.
            if let lastSlot = bar.slotPopupFrame(at: bar.slotVisibleCount - 1) {
                XCTAssertLessThanOrEqual(lastSlot.maxX, frame.minX + 0.5, "槽位与按钮不重叠 at \(width)")
            }
        }

        XCTAssertEqual(bar.clearButtonTitle, "清除全部", "就四个字，不追加图标或括号")
        XCTAssertFalse(bar.clearButtonIsBordered, "无边框")
        XCTAssertEqual(bar.clearButtonFont?.pointSize, 10.5, "10.5 pt")
        // Not blue — checked twice, because AppKit's default label colour for a plain button *is* the
        // accent: the tint and the attributed title both have to say grey.
        XCTAssertNotEqual(bar.clearButtonTintColor, .controlAccentColor, "contentTintColor 不是 accent")
        let textColor = bar.clearButtonTextColor
        XCTAssertNotNil(textColor, "标题必须自带颜色，否则 AppKit 会按 accent 画")
        XCTAssertNotEqual(textColor, .controlAccentColor, "标题不是 accent 蓝")
        XCTAssertEqual(textColor?.usingColorSpace(.sRGB),
                       NSColor.secondaryLabelColor.usingColorSpace(.sRGB), "secondaryLabelColor")
        XCTAssertEqual(bar.clearButtonAccessibilityLabel, "清除全部")

        // And it is really there to hit: hit-testing the frame's centre lands on the button.
        layout(width: 1200)
        let centre = NSPoint(x: bar.clearButtonFrame.midX, y: bar.clearButtonFrame.midY)
        if let parent = bar.superview, let hit = bar.hitTest(bar.convert(centre, to: parent)) {
            XCTAssertEqual((hit as? NSButton)?.title, "清除全部", "点在该点上的就是「清除全部」")
        }
    }

    /// With nothing ticked there is nothing to clear: the button is hidden and takes no space, and the
    /// slots get the whole strip.
    func testInactiveBarHidesClearAllAndGivesTheSlotsEveryPoint() {
        XCTAssertFalse(session.filter.isActive)
        layout(width: 700)
        XCTAssertTrue(bar.isClearButtonHidden, "无筛选时隐藏")
        XCTAssertEqual(bar.clearButtonFrame, .zero)

        // No reserve at all: 700 − 10 (leading) − 24 (icon) − 6 (gap) − 8 (trailing) = 652 for 5 slots.
        for width in allSlotWidths() {
            XCTAssertEqual(width, FilterBarView.popupMaxWidth, accuracy: 0.5,
                           "没有「清除全部」占位时 700 pt 就够五个满宽槽位")
        }
    }

    // MARK: 3 — pressing it

    /// Requirement 3: one press → slots empty, `filter == .none`, the library back, the button gone.
    ///
    /// `AssetGridController` wires the bar's `onClearAll` to `session.clearFilter()`, which calls
    /// `applyFilter(.none)` → one `reload()` (its `guard next != filter` is what keeps it to one). The
    /// test wraps that same closure to count the presses instead of replacing the behaviour.
    func testPressingClearAllClearsTheSlotsTheFilterAndHidesItself() {
        activateThreeConditions()
        layout(width: 1200)
        XCTAssertEqual(session.assets.count, 1, "只有 5★ 且 pick 的那张")

        var presses = 0
        let wiring = bar.onClearAll
        bar.onClearAll = { presses += 1; wiring?() }
        bar.performClearAllClick()                       // the button's own target/action
        settle()

        XCTAssertEqual(presses, 1, "一次点击 = 一次清空（也就是一次 reload）")
        XCTAssertEqual(session.filter, CatalogFilter.none)
        XCTAssertFalse(session.filter.isActive)
        XCTAssertEqual(bar.slotValues(at: 0), [], "槽位清空")
        XCTAssertEqual(bar.slotValues(at: 1), [])
        XCTAssertEqual(session.assets.count, 3, "库回到全部 3 行")
        XCTAssertTrue(bar.isClearButtonHidden, "清完之后按钮自己消失")
        XCTAssertEqual(bar.clearButtonFrame, .zero)
    }

    // MARK: 4 — the reclaimed width

    /// Requirement 4: the pills' band is now the slots'. At 700 pt a slot went 72 → 115.6 pt (+43.6);
    /// at 900 it went 112 → 120 (the 120 pt cap, reached 186 pt earlier than before). At 1200 the popups
    /// were **already** at the cap before 050, so the equality below is not a regression — the reclaimed
    /// 218 pt is the empty band `testAnActiveBarDrawsOnlyTheIconSlotsAndClearAll` scans.
    func testReclaimedPillWidthGoesToTheSlots() {
        activateThreeConditions()

        for width in [700.0, 900.0, 1200.0] as [CGFloat] {
            layout(width: width)
            let before = Self.preChangeSlotWidth[width]!
            let widths = allSlotWidths()
            XCTAssertEqual(widths.count, 5, "5 个槽位都在 at \(width)")
            for slotWidth in widths {
                XCTAssertGreaterThanOrEqual(slotWidth, before - 0.5,
                                            "槽位不许比改前窄 at \(width)：\(slotWidth) vs 改前 \(before)")
            }
            if width < 1200 {
                XCTAssertGreaterThan(widths[0], before, "at \(width) 回收到的宽度让槽位变宽：\(before) → \(widths[0])")
            } else {
                XCTAssertEqual(widths[0], FilterBarView.popupMaxWidth, accuracy: 0.5,
                               "1200 pt 改前就已顶到 120 pt 上限，改后仍是 120")
            }
            print("LAYOUT bar \(width): slot widths \(widths) (before \(before))")
        }
    }

    /// Requirement 4 (second half): a 700 pt bar keeps at least two usable slots.
    func testSevenHundredPointBarStillShowsAtLeastTwoSlots() {
        activateThreeConditions()
        layout(width: 700)
        XCTAssertEqual(bar.slotVisibleCount, 5, "700 pt 现在五个槽位全都在")
        XCTAssertGreaterThanOrEqual(bar.slotVisibleCount, 2, "硬底线：至少两个槽位")
        for index in 0..<bar.slotVisibleCount {
            let frame = bar.slotPopupFrame(at: index)!
            XCTAssertGreaterThanOrEqual(frame.width, FilterBarView.popupMinWidth - 0.5,
                                        "槽位 \(index) 不窄于 34 pt")
            XCTAssertLessThanOrEqual(frame.maxX, bar.clearButtonFrame.minX + 0.5,
                                     "槽位 \(index) 不许压到「清除全部」")
        }
    }
}

/// The model half of 050: `CatalogFilter.chips()` is **unchanged** — it is query vocabulary (the log's
/// summary, the smoke's “the condition still exists” line), and the bar simply stopped drawing it.
/// This class exists so `swift test --filter FilterChipModel` (the task's acceptance list) has the
/// model assertions it names; there was no such class in the repo before.
@MainActor
final class FilterChipModelTests: XCTestCase {

    func testChipsStillDescribeEveryCondition() {
        var filter = CatalogFilter.none
        filter = filter.settingValues(["1", "5"], atSlot: 0)         // 星级 1★、5★
        filter = filter.settingValues(["pick"], atSlot: 1)           // 旗标 留用
        filter.ratingAtLeast = 2                                     // a legacy facet chip

        let chips = filter.chips()
        XCTAssertEqual(chips.map(\.text), ["≥2 星", "星级 1★", "星级 5★", "旗标 留用"])
        XCTAssertEqual(chips.first?.origin, .facet(.rating))
        XCTAssertEqual(chips[1].origin, .slot(0))
        XCTAssertEqual(chips[1].value, "1")
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(filter.activeFacetCount, 4)
        XCTAssertEqual(filter.summary, "≥2 星 · 星级 1★ · 星级 5★ · 旗标 留用")
    }

    /// The two edits the old pills used to make (drop one value / drop one facet) are still model
    /// operations — the bar just reaches them from the slot checklist instead of a × on a capsule.
    func testTheOldPillEditsAreStillModelOperations() {
        var filter = CatalogFilter.none
        filter = filter.settingValues(["1", "5"], atSlot: 0)

        XCTAssertEqual(filter.removingValue("5", atSlot: 0).chips().map(\.text), ["星级 1★"],
                       "去掉一个值：槽位留着")
        XCTAssertEqual(filter.without(.rating).ratingAtLeast, nil)
        XCTAssertEqual(filter.chips().count, 2, "原值不受影响（值语义）")
    }

    func testAnEmptyFilterHasNoChips() {
        XCTAssertTrue(CatalogFilter.none.chips().isEmpty)
        XCTAssertEqual(CatalogFilter.none.summary, "全部照片")
        XCTAssertFalse(CatalogFilter.none.isActive)
    }
}
