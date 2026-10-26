import XCTest
import AppKit
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// 026 v2 — the grid's filter strip as the owner described it:
///
/// * **one** small button opens a 15-item check menu; ticking a dimension appends a slot in click
///   order, at most five; unticking removes it and the rest close the gap; 「全部不选」 empties them so
///   the next clicks number 1…5 again; a 6th dimension while full does nothing **and is greyed**;
/// * each slot's value control multi-selects (`1★、2★、5★`), values inside a slot OR, slots AND;
/// * chips stay, and a chip's × drops one value while the slot stays with 「全部」;
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
        XCTAssertEqual(bar.chipCount, 0)
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
        XCTAssertEqual(bar.slotTitle(at: 0), "星级 1★、5★")
        XCTAssertEqual(bar.slotValues(at: 0), ["1", "5"])
        XCTAssertEqual(bar.chipCount, 2)

        // 1★ OR 5★ → the 5★ and the 1★ photos (not the 3★, the 2★ or the unrated one).
        XCTAssertEqual(Set(session.assets.map(\.filename)), ["a.dng", "d.dng"])

        tick(["1", "2", "5"], at: 0)
        XCTAssertEqual(bar.slotTitle(at: 0), "星级 1★、2★、5★", "the owner's own example")
        XCTAssertEqual(Set(session.assets.map(\.filename)), ["a.dng", "d.dng", "e.dng"])
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

    // MARK: switching dimensions, clearing, chips

    func testRemovingADimensionDiscardsItsValues() {
        tick(["1", "5"], at: 0)
        XCTAssertEqual(bar.chipCount, 2)
        choose(.rating)                       // untick 星级 → its slot (and values) go
        XCTAssertFalse(bar.slotDimensions.contains(.rating))
        XCTAssertEqual(bar.chipCount, 0)

        choose(.rating)                       // tick it again → a **fresh**, empty slot
        XCTAssertEqual(bar.slotValues(at: bar.slotDimensions.count - 1), [],
                       "旧值属于旧维度，必须清掉")
        XCTAssertEqual(bar.slotTitle(at: bar.slotDimensions.count - 1), "全部星级")
        XCTAssertEqual(session.assets.count, 5, "no stale condition is left in the query")
        XCTAssertTrue(session.filter.criteria.isEmpty)
    }

    func testChipClickDropsOneValueAndKeepsTheSlot() throws {
        tick(["1", "5"], at: 0)
        let five = try XCTUnwrap((0..<bar.chipCount).first { bar.chipText($0)?.contains("5★") == true })
        let fiveRect = try XCTUnwrap(bar.chipRect(five))
        bar.mouseDown(with: Self.click(bar, at: NSPoint(x: fiveRect.midX, y: fiveRect.midY)))
        settle()

        XCTAssertEqual(bar.slotValues(at: 0), ["1"], "only the clicked value is gone")
        XCTAssertEqual(bar.slotDimensions.first, .rating, "the slot stays")
        XCTAssertEqual(bar.slotTitle(at: 0), "星级 1★")
        XCTAssertEqual(bar.chipCount, 1)

        let onlyRect = try XCTUnwrap(bar.chipRect(0))
        bar.mouseDown(with: Self.click(bar, at: NSPoint(x: onlyRect.midX, y: onlyRect.midY)))
        settle()
        XCTAssertEqual(bar.slotValues(at: 0), [])
        XCTAssertEqual(bar.slotTitle(at: 0), "全部星级", "取完则该槽回到「全部」")
        XCTAssertEqual(bar.chipCount, 0)
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
        XCTAssertEqual(bar.chipCount, 0)
        XCTAssertEqual(bar.slotDimensions, CatalogFilter.defaultDimensions)
        XCTAssertEqual(session.assets.count, 5)
    }

    // MARK: geometry — 330 pt and 212 pt panels

    func testTheBarNeverDrawsOutsideItself() {
        tick(["1", "5"], at: 0)                     // two chips
        tick(["pick"], at: 1)                       // a third
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
            for chip in 0..<bar.chipCount {
                guard let rect = bar.chipRect(chip) else { continue }
                XCTAssertLessThanOrEqual(rect.maxX, bounds.width + 0.5,
                                         "chip \(chip) pushed out at \(width)")
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
                          "212 pt cannot hold five usable slots with chips reserved — whole slots drop")
        XCTAssertGreaterThanOrEqual(bar.slotVisibleCount, 1)
        for index in 0..<bar.slotVisibleCount {
            XCTAssertGreaterThanOrEqual(bar.slotPopupFrame(at: index)!.width,
                                        FilterBarView.popupMinWidth - 0.5)
        }
    }

    // MARK: helpers

    private static func click(_ view: NSView, at point: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil),
                           modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
