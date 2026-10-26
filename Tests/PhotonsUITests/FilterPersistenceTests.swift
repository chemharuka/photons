import XCTest
import AppKit
import CryptoKit
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// 043 — the filter bar remembers what was chosen, and it is remembered **per library**.
///
/// What is pinned here, one test per promise:
///
/// * a click's filter comes back, slot order and values included, and the restored filter runs the
///   *same query* a click runs (it goes through `CatalogSession.applyFilter`, not a side door);
/// * a fresh `UserDefaults` instance on the same domain (what a restart looks like) still sees it;
/// * two libraries keep their own archives and never inherit one another's;
/// * a damaged archive degrades — unknown dimension dropped, seven slots truncated to five, a
///   repeated dimension keeping its first slot — instead of breaking the open;
/// * 「清除全部」 forgets that library only;
/// * ten changes in a burst cost at most three writes (0.5 s throttle), and the last one still lands.
///
/// The store is injected: `CountingStore` counts writes and holds the JSON, which is also how the
/// shape of the blob is asserted. One test uses a real `UserDefaults` suite, because "does the
/// domain outlive the instance" is exactly what a fake cannot answer.
@MainActor
final class FilterPersistenceTests: XCTestCase {

    private var tmp: URL!
    private var store: CountingStore!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-043fp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = CountingStore()
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: fixtures

    /// The defaults slice, with the two things a test needs: the JSON it was handed, and a write
    /// count that ignores reads. `removeFilterJSON` is not counted as a write on purpose — the
    /// throttle question is about writes.
    final class CountingStore: FilterPersistence.Store {
        var storage: [String: String] = [:]
        private(set) var writes = 0
        private(set) var removals = 0

        func storedFilterJSON(forKey key: String) -> String? { storage[key] }

        func storeFilterJSON(_ json: String, forKey key: String) {
            writes += 1
            storage[key] = json
        }

        func removeFilterJSON(forKey key: String) {
            removals += 1
            storage[key] = nil
        }
    }

    /// Three photos: a.dng (1★, 留用, leica|sl3), b.cr3 (2★, canon|eos r5), c.jpg (5★, leica|sl3).
    /// Enough for 星级 1★/2★ + 旗标 留用 + 相机 to intersect down to one row, which is what proves a
    /// restored filter reached the query instead of only the bar.
    @discardableResult
    private func makeLibrary(_ name: String) throws -> URL {
        let url = tmp.appendingPathComponent(name, isDirectory: true)
        let catalog = try Catalog.create(at: url)
        let shoot = tmp.appendingPathComponent(name + "-shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: shoot, mode: .reference)

        struct Row { let file: String; let rating: Int; let cameraKey: String; let flag: String? }
        let rows = [
            Row(file: "a.dng", rating: 1, cameraKey: "leica|sl3", flag: "pick"),
            Row(file: "b.cr3", rating: 2, cameraKey: "canon|eos r5", flag: nil),
            Row(file: "c.jpg", rating: 5, cameraKey: "leica|sl3", flag: nil),
        ]
        for row in rows {
            var asset = Asset(sourceRootId: root.id, relPath: row.file, filename: row.file,
                              ext: (row.file as NSString).pathExtension, kind: .raw,
                              size: 1024, mtime: 0, contentHash: UUID().uuidString,
                              captureTime: "2026-10-10T10:00:00Z", captureLocalDate: "2026-10-10",
                              rating: row.rating,
                              cameraModel: row.cameraKey.split(separator: "|").last.map(String.init),
                              cameraKey: row.cameraKey)
            asset.flag = row.flag
            try catalog.dbQueue.write { db in try asset.insert(db) }
        }
        return url
    }

    /// The owner's own example: 3 slots, in a deliberate non-default order.
    private var threeSlotFilter: CatalogFilter {
        CatalogFilter(slots: [
            FilterSlot(dimension: .camera, values: ["leica|sl3"]),
            FilterSlot(dimension: .rating, values: ["1", "2"]),
            FilterSlot(dimension: .flag, values: ["pick"]),
        ])
    }

    private func key(_ url: URL) -> String {
        FilterPersistence.storageKey(libraryPath: url.path)
    }

    // MARK: ① round trip, order included

    func testARestoredFilterHasTheSameSlotsValuesAndOrder() throws {
        let library = try makeLibrary("roundtrip.photonslibrary")
        let session = CatalogSession(filterStore: store)
        try session.open(library)
        XCTAssertEqual(session.filter, .none, "a library with no archive opens on the default bar")

        session.applyFilter(threeSlotFilter)
        XCTAssertEqual(session.assets.map(\.filename), ["a.dng"], "星级 1★/2★ AND 留用 AND leica|sl3")
        session.flushPendingFilterSave()
        let writesAfterClick = store.writes
        XCTAssertEqual(writesAfterClick, 1, "the first change of a burst is written immediately")

        let reopened = CatalogSession(filterStore: store)
        try reopened.open(library)

        XCTAssertEqual(reopened.filter.slots.map(\.dimension), [.camera, .rating, .flag],
                       "槽位顺序 = 存档顺序 = 点击先后")
        XCTAssertEqual(reopened.filter.slots.map(\.values),
                       [["leica|sl3"], ["1", "2"], ["pick"]], "值逐一相等，多选保持原序")
        XCTAssertEqual(reopened.filter, threeSlotFilter, "整份筛选（含遗留单值位）都回来了")
        XCTAssertEqual(reopened.assets.map(\.filename), ["a.dng"],
                       "恢复走的是 applyFilter 那条查询，不是只把 bar 填上")
        XCTAssertEqual(store.writes, writesAfterClick,
                       "恢复不会把同一份存档再写一遍（去重，不产生回弹写）")
    }

    /// The key is a hash of the path, the blob is `version: 1` with the dimensions' `rawValue`s —
    /// both are contract, not implementation detail: they are what makes an archive safe in
    /// `CFPreferences` and readable next year.
    func testTheKeyIsAHashOfThePathAndTheBlobIsVersionOneJSON() throws {
        let library = try makeLibrary("shape.photonslibrary")
        let session = CatalogSession(filterStore: store)
        try session.open(library)
        session.applyFilter(CatalogFilter(slots: [FilterSlot(dimension: .rating, values: ["1", "2"])]))
        session.flushPendingFilterSave()

        // Key: `photons.filter.v1.` + 16 hex digits of SHA-256(normalised path) — never the path.
        let normalized = URL(fileURLWithPath: library.path).resolvingSymlinksInPath().standardizedFileURL.path
        let hex = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        let expected = "photons.filter.v1." + String(hex.prefix(16))
        XCTAssertEqual(key(library), expected)
        XCTAssertEqual(key(library).count, "photons.filter.v1.".count + 16)
        XCTAssertFalse(key(library).contains("/"), "键里不许出现路径分隔符")
        XCTAssertFalse(key(library).contains("photons-043fp-"), "键里不许出现库名（含用户名/中文时会被 CFPreferences 丢键）")

        // Shape: sorted keys, raw dimension names, values verbatim; empty values = 「全部」.
        let json = try XCTUnwrap(store.storage[expected])
        XCTAssertEqual(json, #"{"slots":[{"dimension":"rating","values":["1","2"]}],"version":1}"#)
        let decoded = try JSONDecoder().decode(FilterPersistence.StoredFilter.self,
                                               from: Data(json.utf8))
        XCTAssertEqual(decoded, FilterPersistence.StoredFilter(slots: [
            FilterPersistence.StoredSlot(dimension: "rating", values: ["1", "2"]),
        ]))

        // The same library spelled another way is the same key; a different library is not.
        XCTAssertEqual(FilterPersistence.storageKey(libraryPath: library.path + "/"), expected)
        let other = try makeLibrary("shape2.photonslibrary")
        XCTAssertNotEqual(key(other), expected)
    }

    // MARK: ② restart

    /// A restart is: same defaults domain, new `UserDefaults` instance, new session. The fake store
    /// cannot answer that, so this one runs on a real (throwaway) suite.
    func testAFreshDefaultsInstanceOnTheSameDomainStillHasTheFilter() throws {
        let suite = "photons-043-\(UUID().uuidString)"
        let first = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let library = try makeLibrary("restart.photonslibrary")

        let session = CatalogSession(filterStore: first)
        try session.open(library)
        session.applyFilter(threeSlotFilter)
        session.flushPendingFilterSave()
        first.synchronize()

        // 新实例 = 重启后的进程读同一个域（内存里的 session 与 defaults 缓存都不会跨进程）。
        let afterRestart = try XCTUnwrap(UserDefaults(suiteName: suite))
        afterRestart.synchronize()
        let restarted = CatalogSession(filterStore: afterRestart)
        try restarted.open(library)

        XCTAssertEqual(restarted.filter, threeSlotFilter, "重启后筛选还在")
        XCTAssertEqual(restarted.assets.map(\.filename), ["a.dng"])
    }

    // MARK: ③ per-library isolation

    func testTwoLibrariesKeepTheirOwnFilterAndNeverInheritOneAnothers() throws {
        let a = try makeLibrary("a.photonslibrary")
        let b = try makeLibrary("b.photonslibrary")
        let keyA = key(a), keyB = key(b)
        XCTAssertNotEqual(keyA, keyB)

        let session = CatalogSession(filterStore: store)
        try session.open(a)
        session.applyFilter(threeSlotFilter)
        session.flushPendingFilterSave()
        XCTAssertNotNil(store.storage[keyA])
        XCTAssertNil(store.storage[keyB], "A 的筛选不会写到 B 的槽里")

        // 切到 B：没有存档 → 默认条；A 的槽位不会被带过来。
        try session.open(b)
        XCTAssertEqual(session.filter, .none)
        XCTAssertEqual(session.filter.slots.map(\.dimension), CatalogFilter.defaultDimensions)
        XCTAssertEqual(session.filter.slots.map(\.values), Array(repeating: [], count: 5))
        XCTAssertEqual(session.assets.count, 3)

        // 在 B 上点一个筛选，只落在 B 的键上。
        session.applyFilter(CatalogFilter(slots: [FilterSlot(dimension: .ext, values: ["cr3"])]))
        session.flushPendingFilterSave()
        XCTAssertEqual(session.assets.map(\.filename), ["b.cr3"])

        let jsonA = store.storage[keyA]
        let jsonB = store.storage[keyB]
        XCTAssertNotNil(jsonA)
        XCTAssertNotNil(jsonB)
        XCTAssertNotEqual(jsonA, jsonB)

        // 切回 A：A 自己的还是 A 自己的。
        try session.open(a)
        XCTAssertEqual(session.filter, threeSlotFilter)
        XCTAssertEqual(session.assets.map(\.filename), ["a.dng"])

        // …and a whole new session opened on B sees B's filter, not A's.
        let freshB = CatalogSession(filterStore: store)
        try freshB.open(b)
        XCTAssertEqual(freshB.filter.slots.map(\.dimension), [.ext])
        XCTAssertEqual(freshB.filter.slots.map(\.values), [["cr3"]])
    }

    // MARK: ④ degradation

    /// Unknown dimension: that slot is dropped, the rest is restored — and the library still opens.
    func testAnUnknownDimensionIsDroppedAndTheRestIsRestored() throws {
        let library = try makeLibrary("degrade.photonslibrary")
        store.storage[key(library)] = #"{"version":1,"slots":[{"dimension":"rating","values":["1"]},{"dimension":"galaxy","values":["m31"]},{"dimension":"flag","values":["pick"]}]}"#

        let session = CatalogSession(filterStore: store)
        try session.open(library)
        XCTAssertEqual(session.filter.slots.map(\.dimension), [.rating, .flag], "坏维度丢那个槽，其余照常")
        XCTAssertEqual(session.filter.slots.map(\.values), [["1"], ["pick"]])
        XCTAssertEqual(session.assets.map(\.filename), ["a.dng"], "剩下的槽真的在查询里")
    }

    /// Seven slots → the first five, in stored order.
    func testSevenStoredSlotsAreTruncatedToTheFiveTheBarCanHold() throws {
        let dimensions: [FilterDimension] = [.rating, .flag, .camera, .lens, .ext, .iso, .focal]
        let stored = FilterPersistence.StoredFilter(slots: dimensions.map {
            FilterPersistence.StoredSlot(dimension: $0.rawValue, values: ["x"])
        })
        let restored = try XCTUnwrap(FilterPersistence.filter(from: stored))
        XCTAssertEqual(restored.slots.map(\.dimension), Array(dimensions.prefix(5)))
        XCTAssertEqual(restored.slots.count, CatalogFilter.slotCapacity)

        // …and end to end, through a library with that archive in it.
        let library = try makeLibrary("seven.photonslibrary")
        store.storage[key(library)] = FilterPersistence.encoded(stored)
        let session = CatalogSession(filterStore: store)
        try session.open(library)
        XCTAssertEqual(session.filter.slots.map(\.dimension), Array(dimensions.prefix(5)))
    }

    /// The same dimension twice → the first slot wins (one dimension, one slot).
    func testADuplicateDimensionKeepsTheFirstSlot() throws {
        let stored = FilterPersistence.StoredFilter(slots: [
            FilterPersistence.StoredSlot(dimension: "rating", values: ["5"]),
            FilterPersistence.StoredSlot(dimension: "flag", values: ["pick"]),
            FilterPersistence.StoredSlot(dimension: "rating", values: ["1"]),
        ])
        let restored = try XCTUnwrap(FilterPersistence.filter(from: stored))
        XCTAssertEqual(restored.slots.map(\.dimension), [.rating, .flag])
        XCTAssertEqual(restored.slots.map(\.values), [["5"], ["pick"]], "留首个，不合并、不后置")
    }

    /// Values are kept verbatim (no existence check) — a value this library no longer has keeps its
    /// slot, so the user sees it and can change it. And an empty value list is 「全部」, not absence.
    func testValuesAreNotValidatedButTheirSlotSurvives() throws {
        let library = try makeLibrary("verbatim.photonslibrary")
        let stored = FilterPersistence.StoredFilter(slots: [
            FilterPersistence.StoredSlot(dimension: "camera", values: ["nikon|gone tomorrow"]),
            FilterPersistence.StoredSlot(dimension: "iso", values: []),
        ])
        store.storage[key(library)] = FilterPersistence.encoded(stored)

        let session = CatalogSession(filterStore: store)
        try session.open(library)
        XCTAssertEqual(session.filter.slots.map(\.dimension), [.camera, .iso])
        XCTAssertEqual(session.filter.slots.map(\.values), [["nikon|gone tomorrow"], []])
        XCTAssertEqual(session.assets.count, 0, "不存在的值过滤出空集，这是正确的降级")

        // Nothing usable → the default bar, not a broken one.
        XCTAssertNil(FilterPersistence.filter(from: FilterPersistence.StoredFilter(slots: [])))
        XCTAssertNil(FilterPersistence.filter(from: FilterPersistence.StoredFilter(slots: [
            FilterPersistence.StoredSlot(dimension: "galaxy", values: ["m31"]),
        ])))
        XCTAssertNil(FilterPersistence.filter(from: nil), "没有存档 = 保持默认")
        // A future schema is ignored rather than guessed at.
        XCTAssertNil(FilterPersistence.filter(from: FilterPersistence.StoredFilter(
            version: FilterPersistence.currentVersion + 1,
            slots: [FilterPersistence.StoredSlot(dimension: "rating", values: ["5"])])))
        // Garbage in the domain is not a crash: unreadable JSON reads as "no archive".
        store.storage[key(library)] = "not json at all"
        XCTAssertNil(FilterPersistence.load(libraryPath: library.path, from: store))
        let salvaged = CatalogSession(filterStore: store)
        try salvaged.open(library)
        XCTAssertEqual(salvaged.filter, .none)
    }

    // MARK: ⑤ clear

    func testClearAllForgetsThisLibrarysArchiveAndLeavesTheOtherAlone() throws {
        let a = try makeLibrary("clear-a.photonslibrary")
        let b = try makeLibrary("clear-b.photonslibrary")
        let keyA = key(a), keyB = key(b)

        let session = CatalogSession(filterStore: store)
        try session.open(a)
        session.applyFilter(threeSlotFilter)
        session.flushPendingFilterSave()
        try session.open(b)
        session.applyFilter(CatalogFilter(slots: [FilterSlot(dimension: .ext, values: ["cr3"])]))
        session.flushPendingFilterSave()
        let jsonB = store.storage[keyB]
        XCTAssertNotNil(store.storage[keyA])
        XCTAssertNotNil(jsonB)

        // 「清除全部」 in A.
        try session.open(a)
        XCTAssertEqual(session.filter, threeSlotFilter)
        session.clearFilter()

        XCTAssertNil(store.storage[keyA], "该库的存档被清掉")
        XCTAssertEqual(store.storage[keyB], jsonB, "另一个库的存档一个字都不动")
        XCTAssertEqual(session.filter, .none)
        XCTAssertEqual(session.assets.count, 3, "清掉筛选，行数回到全库")

        // 再开库回到默认。
        let reopened = CatalogSession(filterStore: store)
        try reopened.open(a)
        XCTAssertEqual(reopened.filter, .none)
        XCTAssertEqual(reopened.filter.slots.map(\.dimension), CatalogFilter.defaultDimensions)

        // …and B is untouched by that too.
        let stillB = CatalogSession(filterStore: store)
        try stillB.open(b)
        XCTAssertEqual(stillB.filter.slots.map(\.dimension), [.ext])
        XCTAssertEqual(stillB.filter.slots.map(\.values), [["cr3"]])
    }

    /// Un-ticking every value is the *default bar* again, and that must be remembered too — otherwise
    /// yesterday's narrower archive comes back over the clearing the user just did (the one way this
    /// feature could contradict the screen).
    func testUnTickingEveryValueForgetsTheArchiveInsteadOfResurrectingIt() throws {
        let a = try makeLibrary("untick-a.photonslibrary")
        let b = try makeLibrary("untick-b.photonslibrary")
        let keyA = key(a), keyB = key(b)

        let session = CatalogSession(filterStore: store)
        try session.open(a)
        session.applyFilter(threeSlotFilter)
        session.flushPendingFilterSave()
        try session.open(b)
        session.applyFilter(CatalogFilter(slots: [FilterSlot(dimension: .ext, values: ["cr3"])]))
        session.flushPendingFilterSave()
        let jsonB = store.storage[keyB]
        try session.open(a)
        XCTAssertNotNil(store.storage[keyA])

        // 逐个点掉 chip 上的 × — 槽留着，值清空，直到回到默认条。
        var guardCount = 0
        while let chip = session.filter.chips().last, let value = chip.value, guardCount < 16 {
            guard case let .slot(index) = chip.origin else { break }
            session.removeSlotValue(at: index, value: value)
            guardCount += 1
        }
        XCTAssertTrue(session.filter.slots.allSatisfy(\.isEmpty), "槽留着、值清空：这才是用户看到的默认条")
        XCTAssertTrue(session.filter.criteria.isEmpty)
        XCTAssertEqual(session.assets.count, 3, "没有任何条件 = 全库")
        XCTAssertNil(store.storage[keyA], "回到默认就不要再留着更窄的存档")
        XCTAssertEqual(store.storage[keyB], jsonB, "清除只管这个库")

        let reopened = CatalogSession(filterStore: store)
        try reopened.open(a)
        XCTAssertEqual(reopened.filter, .none, "重开不会被旧存档打回原样")
        XCTAssertEqual(reopened.filter.slots.map(\.dimension), CatalogFilter.defaultDimensions)
    }

    // MARK: ⑥ throttle

    /// Ten changes in a burst (a value checklist drag) must not be ten `cfprefsd` round trips:
    /// one leading write, one trailing write, nothing lost.
    func testTenRapidChangesCostAtMostThreeWritesAndTheLastOneLands() throws {
        let library = try makeLibrary("throttle.photonslibrary")
        let session = CatalogSession(filterStore: store)
        try session.open(library)
        let baseline = store.writes

        for i in 0..<10 {
            session.applyFilter(CatalogFilter(slots: [
                FilterSlot(dimension: .rating, values: [String(i)]),
            ]))
        }
        let duringBurst = store.writes - baseline
        XCTAssertEqual(session.filter.slots.first?.values, ["9"])

        // The trailing write (0.5 s throttle) still has to land.
        RunLoop.current.run(until: Date().addingTimeInterval(0.75))
        let total = store.writes - baseline

        XCTAssertLessThanOrEqual(total, 3, "10 次变化只允许 ≤3 次写，实测 \(total)（leading \(duringBurst) + trailing \(total - duringBurst)）")
        XCTAssertGreaterThanOrEqual(duringBurst, 1, "第一次变化立刻落地，退出也不会全丢")
        XCTAssertLessThanOrEqual(duringBurst, total)

        let json = try XCTUnwrap(store.storage[key(library)])
        XCTAssertEqual(json, #"{"slots":[{"dimension":"rating","values":["9"]}],"version":1}"#,
                       "节流合并的是写，不是状态：最后那次变化必须落地")
    }

    /// Cmd-Q inside the 0.5 s window must not swallow the last tick: the trailing write is flushed
    /// on `willTerminate` instead of being lost with the process.
    func testQuittingInsideTheThrottleWindowStillWritesTheLastChange() throws {
        let library = try makeLibrary("quit.photonslibrary")
        let session = CatalogSession(filterStore: store)
        try session.open(library)

        session.applyFilter(CatalogFilter(slots: [FilterSlot(dimension: .rating, values: ["1"])]))
        session.applyFilter(CatalogFilter(slots: [FilterSlot(dimension: .rating, values: ["1", "2"])]))
        XCTAssertEqual(store.storage[key(library)],
                       #"{"slots":[{"dimension":"rating","values":["1"]}],"version":1}"#,
                       "第一次立刻落地，第二次还在 0.5 s 窗口里")

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(store.storage[key(library)],
                       #"{"slots":[{"dimension":"rating","values":["1","2"]}],"version":1}"#,
                       "退出时把窗口里的最后那次落盘")
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(store.writes, 2, "flush 之后那个 trailing 写已取消，不再多写一次")
    }

    /// A change spread out over more than the window writes on its own — the throttle must not
    /// swallow a lone click.
    func testASingleChangeIsWrittenImmediately() throws {
        let library = try makeLibrary("lone.photonslibrary")
        let session = CatalogSession(filterStore: store)
        try session.open(library)

        session.applyFilter(CatalogFilter(slots: [FilterSlot(dimension: .ext, values: ["dng"])]))
        XCTAssertEqual(store.writes, 1, "不等到 0.5 s 就有存档")
        XCTAssertNotNil(store.storage[key(library)])
        session.flushPendingFilterSave()
        XCTAssertEqual(store.writes, 1, "flush 不重复写同一份")
    }

    /// The archive outlives the session: a window closed inside the 0.5 s window still hands the next
    /// session its filter, because the first change of a burst is written on the leading edge.
    func testASecondSessionSeesTheFirstSessionsFilter() throws {
        let library = try makeLibrary("second.photonslibrary")
        let first = CatalogSession(filterStore: store)
        try first.open(library)
        first.applyFilter(threeSlotFilter)          // deliberately no flush
        let second = CatalogSession(filterStore: store)
        try second.open(library)
        XCTAssertEqual(second.filter, threeSlotFilter)
    }
}
