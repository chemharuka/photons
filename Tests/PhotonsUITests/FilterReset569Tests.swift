import XCTest
import AppKit
import PhotonsCatalog
@testable import PhotonsUI

/// 569 — 「全部不选」 must not flatten the bar into one slot.
///
/// The owner's chain was: default five slots → 「全部不选」 (`slots = []`) → tick 旗标 留用/已拒/未标记.
/// That stored a one-slot blob, so after a restart the bar came back with exactly one slot and no
/// obvious way to get the other four dimensions back (the ten unticked rows stay greyed while the bar
/// is full). The fix is a different meaning for the same click: clear the values and return to the
/// factory five slots, which is also the shape `FilterPersistence` already treats as "no archive".
@MainActor
final class Filter569ResetTests: XCTestCase {

    private var tmp: URL!
    private var store: CountingStore!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-569-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = CountingStore()
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    /// The defaults slice `FilterPersistence` writes through, held in memory so a test can see the
    /// blob and the removal itself instead of a real `cfprefsd` side effect.
    final class CountingStore: FilterPersistence.Store {
        var storage: [String: String] = [:]

        func storedFilterJSON(forKey key: String) -> String? { storage[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { storage[key] = json }
        func removeFilterJSON(forKey key: String) { storage[key] = nil }
    }

    private func makeLibrary(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name, isDirectory: true)
        _ = try Catalog.create(at: url)
        return url
    }

    private func key(_ url: URL) -> String {
        FilterPersistence.storageKey(libraryPath: url.path)
    }

    // MARK: 1 — the original chain, in the model

    func testClearingReturnsTheDefaultFiveSlotsNotAnEmptyBar() {
        let cleared = CatalogFilter.none.clearingSlots()

        XCTAssertEqual(cleared.slots.count, CatalogFilter.slotCapacity,
                       "「回到默认五槽」 must leave five slots, not []")
        XCTAssertEqual(cleared.slots.map(\.dimension), CatalogFilter.defaultDimensions)
        XCTAssertTrue(cleared.slots.allSatisfy(\.isEmpty), "the five slots are empty (「全部…」)")
    }

    // MARK: 4 — clearing really means "no filter"

    func testClearedFilterIsInactiveAndHasNoFacets() {
        let active = CatalogFilter(slots: CatalogFilter.defaultSlots.map {
            $0.dimension == .rating ? FilterSlot(dimension: .rating, values: ["5"])
                : $0.dimension == .flag ? FilterSlot(dimension: .flag, values: ["pick"])
                : $0
        })
        XCTAssertEqual(active.activeFacetCount, 2)
        XCTAssertTrue(active.isActive)

        let cleared = active.clearingSlots()
        XCTAssertEqual(cleared.activeFacetCount, 0)
        XCTAssertFalse(cleared.isActive)
        XCTAssertTrue(cleared.criteria.isEmpty)
    }

    // MARK: 2 — clearing forgets the archive, and the next open is the default bar

    func testClearingForgetsTheBlobAndReopensOnTheDefaultFive() throws {
        let library = try makeLibrary("forget.photonslibrary")
        let session = CatalogSession(filterStore: store)
        try session.open(library)

        session.applyFilter(CatalogFilter(slots: [
            FilterSlot(dimension: .rating, values: ["5"]),
        ]))
        session.flushPendingFilterSave()
        XCTAssertNotNil(store.storage[key(library)], "an active filter has an archive")

        session.applyFilter(session.filter.clearingSlots())
        session.flushPendingFilterSave()
        XCTAssertNil(store.storage[key(library)],
                     "回到默认 = 没有筛选 = 不留存档（与 FilterPersistence 的全空 ⇒ forget 一致）")

        let reopened = CatalogSession(filterStore: store)
        try reopened.open(library)
        XCTAssertEqual(reopened.filter, .none)
        XCTAssertEqual(reopened.filter.slots.map(\.dimension), CatalogFilter.defaultDimensions)
        XCTAssertTrue(reopened.filter.slots.allSatisfy(\.isEmpty))
    }

    // MARK: 3 — the old one-slot shape cannot come back through this click

    func testFlagValuesAfterClearingStillProduceFiveSlotsInTheBlobAndAfterRestore() throws {
        let library = try makeLibrary("flag.photonslibrary")
        let session = CatalogSession(filterStore: store)
        try session.open(library)

        // Start narrowed, then press the reset row.
        session.applyFilter(CatalogFilter(slots: [
            FilterSlot(dimension: .rating, values: ["5"]),
        ]))
        session.applyFilter(session.filter.clearingSlots())
        XCTAssertEqual(session.filter.slots.count, 5)

        // The owner's next step: flag 留用/已拒/未标记. Untick and re-tick 旗标 so it joins the bar
        // the way a click on a non-default dimension would (appended in click order).
        var next = session.filter
        next = next.togglingDimension(.flag)
        next = next.togglingDimension(.flag)
        session.applyFilter(next)
        let flag = try XCTUnwrap(session.filter.slots.firstIndex { $0.dimension == .flag })
        session.applyFilter(session.filter.settingValues(["pick", "reject", "none"], atSlot: flag))

        XCTAssertEqual(session.filter.slots.count, 5,
                       "ticking values must not collapse the bar to one slot")
        XCTAssertEqual(session.filter.slots.filter { !$0.isEmpty }.count, 1)
        XCTAssertEqual(session.filter.slots[flag].values, ["pick", "reject", "none"])

        session.flushPendingFilterSave()
        let json = try XCTUnwrap(store.storage[key(library)])
        let stored = try JSONDecoder().decode(FilterPersistence.StoredFilter.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(stored.slots.count, 5, "the blob keeps all five slots")
        XCTAssertEqual(stored.slots.first { $0.dimension == FilterDimension.flag.rawValue }?.values,
                       ["pick", "reject", "none"])

        let reopened = CatalogSession(filterStore: store)
        try reopened.open(library)
        XCTAssertEqual(reopened.filter.slots.count, 5)
        XCTAssertEqual(reopened.filter.slots.map(\.dimension).last, .flag)

        let bar = FilterBarView()
        bar.update(filter: reopened.filter, cameraKeys: [])
        XCTAssertEqual(bar.slotVisibleCount, 5, "after a restart the bar is still five slots")
    }

    // MARK: 5 — the row says what it will do

    func testTheResetRowNamesItsConsequence() throws {
        let bar = FilterBarView()
        bar.update(filter: .none, cameraKeys: [])
        bar.openDimensionPopover()

        let reset = try XCTUnwrap(bar.dimensionChecklistForLayoutTests.rows.last)
        XCTAssertEqual(reset.title, "回到默认五槽")
        XCTAssertEqual(reset.toolTip, "清掉所有筛选值，并把筛选条恢复成默认五个维度")
        XCTAssertTrue(reset.enabled, "the default bar can still be reset")
        XCTAssertEqual(bar.dimensionMenuRows.last?.title, "回到默认五槽")
    }
}
