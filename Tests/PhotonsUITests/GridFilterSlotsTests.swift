import XCTest
import AppKit
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// 026 v2 — the grid's filter strip as the owner described it (036 reshaped the picker):
///
/// * **one** small icon button (24 × 24 SF Symbol) opens a transient-popover checklist of 15
///   dimensions; ticking one appends a slot in click order, at most five, and **the popover stays
///   open** for the next tick (036: an `NSMenu` closed on every selection). Unticking removes a slot
///   and the rest close the gap; 「全部不选」 empties them so the next clicks number 1…5, without
///   closing; a 6th dimension while full does nothing **and is greyed**;
/// * each slot's value control multi-selects (`1★、2★、5★`) in the same kind of checklist, also
///   staying open; values inside a slot OR, slots AND;
/// * 050: the removable-condition pills that used to sit at the bar's right end are **gone** — the
///   only control right of the slots is 「清除全部」. A single value is now dropped inside its slot's
///   own checklist, which is why these tests drive `performSlotRow` / `setSlotValues` instead of
///   clicking a pill. `CatalogFilter.chips()` still exists (query vocabulary + the summary) and
///   `FilterChipModelTests` keeps pinning it.
/// * the bar never draws outside its own bounds, at a 330 pt **or** a 212 pt panel.
@MainActor
final class GridFilterSlotsTests: XCTestCase {

    private var tmp: URL!
    private var library: URL!
    private var session: CatalogSession!
    private var grid: AssetGridController!
    private var bar: FilterBarView { grid.filterBar }

    private static let width: CGFloat = 900
    private static let height: CGFloat = 600

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-026ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("ui.photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: library)
        let shoot = tmp.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: shoot, mode: .reference)
        try seed(catalog, root: root)

        session = CatalogSession()
        try session.open(library)
        grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.height)
        grid.view.layoutSubtreeIfNeeded()
    }

    override func tearDownWithError() throws {
        session = nil
        grid = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    private func seed(_ catalog: Catalog, root: SourceRoot) throws {
        struct Row { let name: String; let key: String; let rating: Int; let lens: String
                     let iso: Int; let focal: Double; let aperture: Double }
        let rows: [Row] = [
            Row(name: "a.dng", key: "leica|sl3", rating: 5, lens: "85mm", iso: 100, focal: 85, aperture: 1.2),
            Row(name: "b.cr3", key: "canon|eos r5", rating: 3, lens: "50mm", iso: 200, focal: 50, aperture: 2.8),
            Row(name: "c.jpg", key: "leica|sl3", rating: 0, lens: "85mm", iso: 400, focal: 85, aperture: 8.0),
            Row(name: "d.dng", key: "canon|eos r5", rating: 1, lens: "50mm", iso: 160, focal: 24, aperture: 5.6),
            Row(name: "e.dng", key: "panasonic|dc-s5", rating: 2, lens: "24-70mm", iso: 125, focal: 60, aperture: 4.0),
        ]
        for (index, row) in rows.enumerated() {
            let model = row.key.split(separator: "|").last.map(String.init) ?? row.key
            var asset = Asset(sourceRootId: root.id, relPath: row.name, filename: row.name,
                              ext: (row.name as NSString).pathExtension, kind: .raw, size: 1024, mtime: 0,
                              contentHash: UUID().uuidString,
                              captureTime: String(format: "2026-10-%02dT10:00:00Z", 10 - index),
                              captureLocalDate: String(format: "2026-10-%02d", 10 - index),
                              rating: row.rating,
                              cameraModel: model, cameraKey: row.key, lens: row.lens)
            asset.flag = index == 0 ? "pick" : nil
            try catalog.dbQueue.write { db in
                try asset.insert(db)
                try AssetMetadata(assetId: asset.id,
                                  exifJson: Self.exif(serial: index == 0 ? "5954607" : "111"),
                                  iso: row.iso, focalLength: row.focal, aperture: row.aperture,
                                  shutter: "1/250").insert(db)
            }
        }
    }

    private static func exif(serial: String) -> String {
        #"{"{Exif}":{"BodySerialNumber":"\#(serial)","Flash":16},"{GPS}":{"Latitude":30.0,"Longitude":120.0}}"#
    }

    private func layout(width: CGFloat) {
        grid.view.frame = NSRect(x: 0, y: 0, width: width, height: Self.height)
        grid.view.layoutSubtreeIfNeeded()
        bar.layoutSubtreeIfNeeded()
    }

    /// The bar writes through `CatalogSession`, and the session notifies its observers on the main
    /// queue (`ObservationBridge`), so a click's effect on the bar arrives one turn later — exactly
    /// as it does for a user. Pumping the run loop is what makes the test see the same end state.
    private func settle(_ turns: Int = 4) {
        for _ in 0..<turns { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        bar.layoutSubtreeIfNeeded()
    }

    private func choose(_ dimension: FilterDimension) {
        bar.chooseDimension(dimension)
        settle()
    }

    private func tick(_ values: [String], at slot: Int) {
        bar.setSlotValues(values, at: slot)
        settle()
    }
    private func clearDimensions() {
        bar.clearSlotDimensions()
        settle()
    }

    // MARK: the single dimension button

    func testBarStartsWithTheOwnersFiveDimensionsOneSlotEach() {
        XCTAssertEqual(bar.slotDimensions, CatalogFilter.defaultDimensions)
        XCTAssertEqual(bar.slotVisibleCount, 5)
        XCTAssertEqual(bar.slotTitle(at: 0), "全部星级")
        XCTAssertEqual(bar.slotTitle(at: 1), "全部旗标")
        XCTAssertEqual(bar.slotTitle(at: 2), "全部相机")
        // 050: no pill row any more — the bar holds exactly the icon, five slot buttons and
        // 「清除全部」, and every one of them is a button (a drawn pill would be a bare NSView or, with
        // the old code, purely painted — which is precisely what must not come back).
        XCTAssertEqual(bar.subviews.count, 1 + CatalogFilter.slotCapacity + 1)
        XCTAssertTrue(bar.subviews.allSatisfy { $0 is NSButton })
        // The one small button — not one per slot.
        XCTAssertEqual(bar.dimensionButtonFrame.width, FilterBarView.dimensionButtonWidth, accuracy: 0.5)
    }

    func testMenuListsFifteenDimensionsNumberedAndGreysTheSixth() {
        let rows = bar.dimensionMenuRows
        XCTAssertEqual(rows.count, 16, "15 dimensions + 全部不选")
        // 星级 is the first *active* slot, so it carries slot number 1 — the list itself starts at 月.
        let rating = try! XCTUnwrap(rows.first { $0.title.contains("星级") })
        XCTAssertEqual(rating.title.hasPrefix("1  "), true, "活跃槽带序号：\(rating.title)")
        XCTAssertEqual(rating.checked, true)
        XCTAssertEqual(rating.enabled, true)
        XCTAssertEqual(rows.last?.title, "全部不选")
        // Five are ticked → a sixth dimension is offered but disabled (the chosen contract).
        let disabled = rows.filter { !$0.checked && !$0.enabled }
        XCTAssertEqual(disabled.count, 10, "the ten dimensions that cannot join a full bar are greyed")
        XCTAssertTrue(disabled.allSatisfy { !$0.title.hasPrefix("1  ") })
    }

    func testSixthDimensionIsIgnoredWhileFiveAreActive() {
        choose(.iso)
        XCTAssertEqual(bar.slotDimensions, CatalogFilter.defaultDimensions, "no sixth slot")
        XCTAssertEqual(bar.slotVisibleCount, 5)
    }

    func testUntickingADimensionRemovesItsSlotAndKeepsTheOrder() {
        choose(.camera)                      // untick 相机
        XCTAssertEqual(bar.slotDimensions, [.rating, .flag, .lens, .ext])
        XCTAssertEqual(bar.slotVisibleCount, 4)

        choose(.camera)                      // tick it again → appended at the end
        XCTAssertEqual(bar.slotDimensions, [.rating, .flag, .lens, .ext, .camera])
        XCTAssertEqual(bar.dimensionMenuRows.filter { $0.checked }.count, 5)
    }

    func testAllNoneClearsTheBarAndClicksRenumberFromOne() {
        clearDimensions()
        XCTAssertEqual(bar.slotDimensions, [])
        XCTAssertEqual(bar.slotVisibleCount, 0)
        XCTAssertFalse(bar.dimensionMenuRows.last!.enabled, "全部不选 is disabled with nothing selected")

        choose(.iso)
        choose(.focal)
        choose(.serial)
        XCTAssertEqual(bar.slotDimensions, [.iso, .focal, .serial])
        let rows = bar.dimensionMenuRows
        XCTAssertEqual(rows.first(where: { $0.title.contains("ISO") })?.title.hasPrefix("1"), true)
        XCTAssertEqual(rows.first(where: { $0.title.contains("焦距") })?.title.hasPrefix("2"), true)
        XCTAssertEqual(rows.first(where: { $0.title.contains("序列号") })?.title.hasPrefix("3"), true)
    }

    // MARK: multi-select values, OR inside a slot

    func testOneSlotCanHoldSeveralValuesShownJoinedByCommas() {
        tick(["1", "5"], at: 0)
        // 051: two or more values collapse to 「部分星级」 — the bar says *that* some are picked and
        // spends the recovered width on the other slots, not on enumerating this one.
        XCTAssertEqual(bar.slotTitle(at: 0), "部分星级")
        XCTAssertEqual(bar.slotValues(at: 0), ["1", "5"])

        // 1★ OR 5★ → the 5★ and the 1★ photos (not the 3★, the 2★ or the unrated one).
        XCTAssertEqual(Set(session.assets.map(\.filename)), ["a.dng", "d.dng"])

        tick(["1", "2", "5"], at: 0)
        XCTAssertEqual(bar.slotTitle(at: 0), "部分星级", "the owner's own example: three values are 部分")
        XCTAssertEqual(Set(session.assets.map(\.filename)), ["a.dng", "d.dng", "e.dng"])
    }

    /// 051: the three states of a slot title, and the accent row that says what it *does*.
    ///
    /// The rule is the owner's: 「选择后，菜单名称改成部分相机/部分ISO，除非只选择了一个，此时就用所选名称。
    /// 这个逻辑对布尔类型的选项不成立」.
    func testTheSlotTitleSaysPartInsteadOfListingValues() {
        XCTAssertEqual(bar.slotTitle(at: 0), "全部星级", "nothing ticked")
        XCTAssertEqual(bar.slotMenuTitles(at: 0).first, "全部星级",
                       "with nothing ticked the action row is still 「全部…」 (and disabled)")

        tick(["5"], at: 0)
        XCTAssertEqual(bar.slotTitle(at: 0), "星级 5★", "one value *is* the answer, so name it")

        tick(["5", "1"], at: 0)
        XCTAssertEqual(bar.slotTitle(at: 0), "部分星级")
        bar.openSlotPopover(at: 0)
        XCTAssertEqual(bar.slotMenuTitles(at: 0).first, "取消选择",
                       "the accent row is an action: it must not repeat the selection it would clear")
        bar.closeSlotPopover()

        // A ladder dimension whose values are long words, not stars.
        tick([], at: 0)
        XCTAssertEqual(bar.slotTitle(at: 0), "全部星级")
    }

    /// 布尔维度不适用「部分」：闪光灯/GPS 只有有/无，说「部分闪光灯」读起来像 bug。
    func testBooleanDimensionsKeepTheirWord() throws {
        // 五个默认槽位是满的，`choose` 加不进第六个维度 —— 先腾出位置再选闪光灯。
        clearDimensions()
        choose(.flash)
        let slot = try XCTUnwrap(bar.slotDimensions.firstIndex(of: .flash))
        XCTAssertEqual(bar.slotTitle(at: slot), "全部闪光灯")

        tick([FilterValue.yes], at: slot)
        XCTAssertEqual(bar.slotTitle(at: slot), "闪光灯 有", "a boolean tick is a complete answer")
        bar.openSlotPopover(at: slot)
        XCTAssertEqual(bar.slotMenuTitles(at: slot).first, "取消选择")
        bar.closeSlotPopover()

        tick([FilterValue.yes, FilterValue.no], at: slot)
        XCTAssertEqual(bar.slotValues(at: slot), [FilterValue.yes, FilterValue.no])
        XCTAssertEqual(bar.slotTitle(at: slot), "闪光灯 有、无",
                       "both is still spelled out, not 「部分闪光灯」")
    }

    func testSlotsAreAndedTogether() {
        tick(["1", "5"], at: 0)               // 星级 1★、5★ → a, d
        choose(.ext)                          // untick 后缀 to make room
        choose(.iso)                          // …and tick ISO
        XCTAssertEqual(bar.slotDimensions, [.rating, .flag, .camera, .lens, .iso])
        let isoSlot = try! XCTUnwrap(bar.slotDimensions.firstIndex(of: .iso))
        tick(["160"], at: isoSlot)
        XCTAssertEqual(session.assets.map(\.filename), ["d.dng"], "1★/5★ AND ISO 160")
    }

    func testRatingValuesAreTiersNotThresholds() {
        tick(["3"], at: 0)                    // exactly 3★, not ≥3★
        XCTAssertEqual(session.assets.map(\.filename), ["b.cr3"])
        tick(["4"], at: 0)                    // nobody is 4★
        XCTAssertEqual(session.assets.count, 0, "an empty grid, not a crash")
    }

    // MARK: switching dimensions, clearing

    func testRemovingADimensionDiscardsItsValues() {
        tick(["1", "5"], at: 0)
        XCTAssertEqual(bar.slotValues(at: 0), ["1", "5"])
        choose(.rating)                       // untick 星级 → its slot (and values) go
        XCTAssertFalse(bar.slotDimensions.contains(.rating))
        XCTAssertTrue(session.filter.criteria.isEmpty, "旧值不许留在查询里")

        choose(.rating)                       // tick it again → a **fresh**, empty slot
        XCTAssertEqual(bar.slotValues(at: bar.slotDimensions.count - 1), [],
                       "旧值属于旧维度，必须清掉")
        XCTAssertEqual(bar.slotTitle(at: bar.slotDimensions.count - 1), "全部星级")
        XCTAssertEqual(session.assets.count, 5, "no stale condition is left in the query")
        XCTAssertTrue(session.filter.criteria.isEmpty)
    }

    /// 050 — this was `testChipClickDropsOneValueAndKeepsTheSlot`. The pill's × no longer exists, so:
    /// a click in the band right of the last slot (where the 5★ pill used to be painted) must be
    /// **inert**, and dropping one value must go through the slot's own checklist.
    func testOnlyTheSlotChecklistDropsOneValue() throws {
        tick(["1", "5"], at: 0)
        layout(width: 900)
        let lastSlot = try XCTUnwrap(bar.slotPopupFrame(at: bar.slotVisibleCount - 1))

        let before = bar.slotValues(at: 0)
        // Where the pill row used to start — immediately right of the last slot.
        bar.mouseDown(with: Self.click(bar, at: NSPoint(x: lastSlot.maxX + 30, y: bar.bounds.midY)))
        settle()
        XCTAssertEqual(bar.slotValues(at: 0), before, "槽位右侧已经没有任何可点的条件了")
        XCTAssertEqual(bar.slotDimensions.first, .rating)

        bar.openSlotPopover(at: 0)
        let rows = bar.slotMenuTitles(at: 0)          // 「全部星级」, then the ladder
        let five = try XCTUnwrap(rows.firstIndex(of: "5★"), "\(rows)")
        bar.performSlotRow(at: five)
        settle()
        XCTAssertEqual(bar.slotValues(at: 0), ["1"], "only that value is gone")
        XCTAssertEqual(bar.slotDimensions.first, .rating, "the slot stays")
        XCTAssertEqual(bar.slotTitle(at: 0), "星级 1★")

        let one = try XCTUnwrap(bar.slotMenuTitles(at: 0).firstIndex(of: "1★"))
        bar.performSlotRow(at: one)
        settle()
        XCTAssertEqual(bar.slotValues(at: 0), [])
        XCTAssertEqual(bar.slotTitle(at: 0), "全部星级", "取完则该槽回到「全部」")
        XCTAssertEqual(session.assets.count, 5)
    }

    func testSlotMenuOffersTheLibrariesOwnValuesAndSaysSoWhenThereAreNone() {
        tick(["5"], at: 0)                    // 星级 5★
        choose(.ext)                          // make room …
        choose(.iso)                          // … then tick ISO
        let isoSlot = try! XCTUnwrap(bar.slotDimensions.firstIndex(of: .iso))
        // Scoped by the rest of the filter: only the 5★ photo's ISO is offered.
        XCTAssertEqual(bar.facetValuesForMenu(at: isoSlot), ["100"])
        XCTAssertEqual(bar.slotMenuTitles(at: isoSlot), ["全部ISO", "100"])

        tick([], at: 0)
        XCTAssertEqual(bar.facetValuesForMenu(at: isoSlot), ["100", "125", "160", "200", "400"],
                       "with no 星级 condition the whole library's ISOs are offered")

        // A dimension the library has nothing for: only 「全部」 + one disabled explanation, no ladder.
        let empty = try! Catalog.create(at: tmp.appendingPathComponent("bare.photonslibrary", isDirectory: true))
        let shoot = tmp.appendingPathComponent("bare", isDirectory: true)
        try! FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let bareRoot = try! empty.ensureRoot(for: shoot, mode: .reference)
        let bare = Asset(sourceRootId: bareRoot.id, relPath: "x.dng", filename: "x.dng", ext: "dng",
                         kind: .raw, size: 1, mtime: 0, contentHash: "x")
        try! empty.dbQueue.write { db in try bare.insert(db) }        // no metadata row at all

        let bareSession = CatalogSession()
        try! bareSession.open(tmp.appendingPathComponent("bare.photonslibrary", isDirectory: true))
        let bareGrid = AssetGridController(session: bareSession)
        _ = bareGrid.view
        bareGrid.filterBar.frame = NSRect(x: 0, y: 0, width: 900, height: FilterBarView.height)
        bareGrid.filterBar.layoutSubtreeIfNeeded()

        bareGrid.filterBar.clearSlotDimensions()
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        bareGrid.filterBar.chooseDimension(.focal)
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        bareGrid.filterBar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bareGrid.filterBar.facetValuesForMenu(at: 0), [])
        XCTAssertEqual(bareGrid.filterBar.slotMenuTitles(at: 0), ["全部焦距", "本库无此数据"])
        XCTAssertEqual(bareGrid.filterBar.slotTitle(at: 0), "全部焦距", "「全部」 is all it can offer")
    }

    func testClearAllResetsSlotsAndLegacyFacets() {
        tick(["1", "5"], at: 0)
        session.applyFilter(CatalogFilter(ratingAtLeast: 2, slots: bar.slotDimensions.map { FilterSlot(dimension: $0) }))
        XCTAssertTrue(session.filter.isActive)

        session.clearFilter()
        settle()
        XCTAssertFalse(session.filter.isActive)
        XCTAssertEqual(bar.slotDimensions, CatalogFilter.defaultDimensions)
        XCTAssertEqual(bar.slotValues(at: 0), [], "清空后没有残留值")
        XCTAssertTrue(session.filter.criteria.isEmpty)
        XCTAssertEqual(session.assets.count, 5)
    }

    // MARK: geometry — 330 pt and 212 pt panels

    func testTheBarNeverDrawsOutsideItself() {
        tick(["1", "5"], at: 0)                     // two values in 星级 …
        tick(["pick"], at: 1)                       // … and one in 旗标 (three conditions, no pills)
        for width in [330.0, 212.0, 900.0] as [CGFloat] {
            layout(width: width)
            let bounds = bar.bounds
            XCTAssertGreaterThanOrEqual(bar.dimensionButtonFrame.minX, 0)
            XCTAssertLessThanOrEqual(bar.dimensionButtonFrame.maxX, bounds.width, "button at \(width)")
            for index in 0..<CatalogFilter.slotCapacity {
                guard let frame = bar.slotPopupFrame(at: index) else { continue }
                XCTAssertGreaterThanOrEqual(frame.minX, 0, "slot \(index) at \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, bounds.width + 0.5, "slot \(index) overflows at \(width)")
                XCTAssertGreaterThanOrEqual(frame.width, FilterBarView.popupMinWidth - 0.5,
                                            "a popup narrower than 34 pt is not a control")
            }
            // 050: 「清除全部」 is the only thing right of the slots, and it is inside the bar too.
            XCTAssertLessThanOrEqual(bar.clearButtonFrame.maxX, bounds.width - 12 + 0.5,
                                     "「清除全部」 超出右边缘 at \(width)")
            XCTAssertGreaterThanOrEqual(bar.clearButtonFrame.minX, 0)
            // Nothing in the bar is a pill: every subview is one of the seven buttons.
            XCTAssertEqual(bar.subviews.count, 1 + CatalogFilter.slotCapacity + 1, "no pill views at \(width)")
            for subview in bar.subviews {
                XCTAssertLessThanOrEqual(subview.frame.maxX, bounds.width + 0.5,
                                         "\(subview) pushed out at \(width)")
            }
        }
    }

    func testAWideBarShowsAllFiveSlotsAndANarrowOneDropsWholesSlotsFirst() {
        layout(width: 900)
        XCTAssertEqual(bar.slotVisibleCount, 5)
        XCTAssertGreaterThanOrEqual(bar.slotPopupFrame(at: 0)!.width, FilterBarView.popupMaxWidth - 0.5,
                                    "a 900 pt bar gives the popup its full 120 pt")

        layout(width: 330)
        XCTAssertEqual(bar.slotVisibleCount, 5, "330 pt still fits five 34…120 pt popups")
        XCTAssertLessThanOrEqual(bar.slotPopupFrame(at: 4)!.maxX, bar.bounds.width)

        layout(width: 212)
        XCTAssertLessThan(bar.slotVisibleCount, 5,
                          "212 pt cannot hold five usable 34 pt popups — whole slots drop")
        XCTAssertGreaterThanOrEqual(bar.slotVisibleCount, 1)
        for index in 0..<bar.slotVisibleCount {
            XCTAssertGreaterThanOrEqual(bar.slotPopupFrame(at: index)!.width,
                                        FilterBarView.popupMinWidth - 0.5)
        }
    }

    // MARK: 036 — an icon button and a checklist popover that stays open

    /// Requirement 3: a fixed 24 × 24 box holding a real SF Symbol — the old button's 22 pt width for a
    /// word like 「筛选」 is what clipped it.
    func testTheDimensionButtonIsATwentyFourPointSymbol() {
        XCTAssertEqual(FilterBarView.dimensionButtonWidth, 24)
        XCTAssertEqual(bar.dimensionButtonFrame.width, 24, accuracy: 0.5)
        XCTAssertEqual(bar.dimensionButtonFrame.height, 24, accuracy: 0.5)
        let icon = try! XCTUnwrap(bar.dimensionButtonImage,
                                  "本机必须有 SF Symbol；没有时退化成同尺寸 ⋯，不许再裁字")
        // The owner's pick from the contact sheet, and the size it must render at.
        XCTAssertEqual(FilterBarView.dimensionSymbolCandidates.first, "line.horizontal.3.decrease.circle")
        XCTAssertNotNil(NSImage(systemSymbolName: "line.horizontal.3.decrease.circle",
                                accessibilityDescription: nil),
                        "首选符号必须在本机存在")
        XCTAssertEqual(icon.size.width, 16, accuracy: 1, "图标按 15–16 pt 显示")
        XCTAssertEqual(icon.size.height, 16, accuracy: 1)
        XCTAssertLessThanOrEqual(icon.size.width, 24, "图标不得超出 24 × 24 的框")
        XCTAssertTrue(icon.isTemplate, "模板图跟随 contentTintColor")
        XCTAssertEqual(bar.dimensionButtonTitle, "", "用图标时不再画文字（文字被裁的根因）")
        XCTAssertEqual(bar.dimensionButtonToolTip, "选择筛选维度")
        XCTAssertEqual(bar.dimensionButtonAccessibilityLabel, "选择筛选维度")
    }

    /// The fallback chain is a real chain: the ring-less glyph exists too, so only a system missing
    /// both would ever see `⋯`.
    func testTheSymbolFallbackChainResolves() {
        XCTAssertNotNil(NSImage(systemSymbolName: "line.horizontal.3.decrease.circle",
                                accessibilityDescription: nil))
        XCTAssertNotNil(NSImage(systemSymbolName: "line.horizontal.3.decrease",
                                accessibilityDescription: nil))
        XCTAssertNotNil(FilterBarView.dimensionSymbolImage())
    }

    /// Requirement 1: three ticks in a row → the popover is still open and the slots are 0 → 3 in click
    /// order. Every tick goes through the row button's production handler.
    func testTickingThreeDimensionsKeepsThePopoverOpenInClickOrder() throws {
        clearDimensions()
        XCTAssertEqual(bar.slotDimensions, [])

        bar.openDimensionPopover()
        XCTAssertTrue(bar.isDimensionPopoverOpen)

        for (expected, name) in [(1, "ISO"), (2, "焦距"), (3, "序列号")] {
            let rows = bar.dimensionMenuRows
            let index = try XCTUnwrap(rows.firstIndex { $0.title.contains(name) }, name)
            bar.performDimensionRow(at: index)
            settle()
            XCTAssertTrue(bar.isDimensionPopoverOpen, "点「\(name)」后 popover 不许关")
            XCTAssertEqual(bar.slotDimensions.count, expected, "槽位 \(expected) 个")
        }

        XCTAssertEqual(bar.slotDimensions, [.iso, .focal, .serial], "顺序 = 点击先后")
        XCTAssertEqual(bar.slotVisibleCount, 3)
        // The numbers the open checklist shows are the click order too.
        let titles = bar.dimensionMenuRows.map(\.title)
        XCTAssertTrue(titles.contains { $0.hasPrefix("1  ISO") })
        XCTAssertTrue(titles.contains { $0.hasPrefix("2  焦距") })
        XCTAssertTrue(titles.contains { $0.hasPrefix("3  序列号") })
    }

    /// Requirement 2: a click outside (the transient dismissal) closes the popover and keeps the slots.
    func testClickingOutsideClosesThePopoverAndKeepsTheSlots() throws {
        clearDimensions()
        bar.openDimensionPopover()
        let rows = bar.dimensionMenuRows
        bar.performDimensionRow(at: try XCTUnwrap(rows.firstIndex { $0.title.contains("焦距") }))
        settle()
        XCTAssertEqual(bar.slotDimensions, [.focal])

        bar.closeDimensionPopover()                       // what a click outside ends in
        XCTAssertFalse(bar.isDimensionPopoverOpen)
        XCTAssertEqual(bar.slotDimensions, [.focal], "槽位保留")
        XCTAssertEqual(bar.slotVisibleCount, 1)

        // Re-opening shows the current state, not a blank list.
        bar.openDimensionPopover()
        XCTAssertTrue(bar.isDimensionPopoverOpen)
        XCTAssertEqual(bar.dimensionMenuRows.filter { $0.checked }.count, 1)
    }

    /// Requirement 4: with five slots ticked the sixth dimension is greyed **and** inert, while a
    /// ticked row can still be unticked — all without the popover closing.
    func testAFullBarGreysTheSixthDimensionAndItsClickDoesNothing() throws {
        XCTAssertEqual(bar.slotDimensions, CatalogFilter.defaultDimensions)   // already full
        bar.openDimensionPopover()

        let rows = bar.dimensionMenuRows
        let iso = try XCTUnwrap(rows.firstIndex { $0.title.contains("ISO") })
        XCTAssertFalse(rows[iso].enabled, "满 5 时未选项置灰")
        XCTAssertFalse(rows[iso].checked)
        bar.performDimensionRow(at: iso)
        settle()
        XCTAssertEqual(bar.slotDimensions, CatalogFilter.defaultDimensions, "置灰行点击无效")
        XCTAssertEqual(bar.slotDimensions.count, 5)
        XCTAssertTrue(bar.isDimensionPopoverOpen)

        let rating = try XCTUnwrap(bar.dimensionMenuRows.firstIndex { $0.title.contains("星级") })
        XCTAssertTrue(bar.dimensionMenuRows[rating].enabled, "已选项仍可取消")
        bar.performDimensionRow(at: rating)
        settle()
        XCTAssertEqual(bar.slotDimensions, [.flag, .camera, .lens, .ext], "取消后其余左移")
        XCTAssertTrue(bar.isDimensionPopoverOpen)
    }

    /// Requirement 5: 「全部不选」 empties the slots and leaves the popover open for the next five ticks.
    func testClearAllEmptiesTheSlotsWithoutClosingThePopover() throws {
        bar.openDimensionPopover()
        let rows = bar.dimensionMenuRows
        XCTAssertEqual(rows.last?.title, "全部不选")
        XCTAssertTrue(try XCTUnwrap(rows.last).enabled)

        bar.performDimensionRow(at: rows.count - 1)
        settle()
        XCTAssertEqual(bar.slotDimensions, [])
        XCTAssertEqual(bar.slotVisibleCount, 0)
        XCTAssertTrue(bar.isDimensionPopoverOpen, "「全部不选」后 popover 仍开")
        XCTAssertFalse(try XCTUnwrap(bar.dimensionMenuRows.last).enabled, "没有可清的了")
        XCTAssertEqual(bar.dimensionMenuRows.filter { !$0.checked && $0.enabled }.count, 15,
                       "清空后 15 个维度全部可选")
    }

    /// C: the per-slot value list is the same checklist — multi-select, and it stays open too.
    func testTheSlotValueChecklistStaysOpenWhileValuesAreTicked() throws {
        layout(width: 900)
        bar.openSlotPopover(at: 0)
        XCTAssertTrue(bar.isSlotPopoverOpen(at: 0))

        let five = try XCTUnwrap(bar.slotChecklistRowModels(at: 0).firstIndex { $0.title == "5★" })
        bar.performSlotRow(at: five)
        settle()
        XCTAssertEqual(bar.slotValues(at: 0), ["5"])
        XCTAssertTrue(bar.isSlotPopoverOpen(at: 0), "点值不关")

        let rows = bar.slotChecklistRowModels(at: 0)
        let one = try XCTUnwrap(rows.firstIndex { $0.title == "1★" })
        XCTAssertTrue(rows[five].checked, "已选项打勾")
        bar.performSlotRow(at: one)
        settle()
        XCTAssertEqual(bar.slotValues(at: 0), ["5", "1"])
        XCTAssertEqual(bar.slotTitle(at: 0), "部分星级")
        XCTAssertTrue(bar.isSlotPopoverOpen(at: 0))

        bar.closeSlotPopover()
        XCTAssertNil(bar.openSlotPopoverIndex)
        XCTAssertEqual(bar.slotValues(at: 0), ["5", "1"], "关掉 popover 不动筛选")
    }

    // MARK: helpers

    private static func click(_ view: NSView, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil),
                           modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
