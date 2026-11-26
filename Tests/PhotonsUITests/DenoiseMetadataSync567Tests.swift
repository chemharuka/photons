import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 567 — 降噪堆叠的旗标 / 星级 / 色标也要同步给原图。
///
/// 487 §2.2 makes a denoise pair one document in two rows; 512 already copied the library fields at
/// creation. This suite is the **post-hoc** half: the three metadata verbs go through
/// `CatalogSession.writeMetadata`, which now also names the hidden sibling. Everything below is read
/// back from a real library on disk, never from the in-memory projection:
///
///   ① a flag on the product writes both rows (`lastMetadataAffectedRows == 2`);
///   ② clearing it clears both;
///   ③ ★ and colour label ride the same door;
///   ④ a **plain** stack stays single-row (the "only denoise pairs" gate);
///   ⑤ a three-member stack stays single-row (kind + live-member-count gate);
///   ⑥ the reverse direction: flagging the visible original reaches the product.
///
/// **Reverse gates:** make `denoiseSiblings` return `[]` and ① goes red; drop the `stack_kind`
/// check and ④ goes red.
@MainActor
final class DenoiseMetadataSync567Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var libraryURL: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-567-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        libraryURL = workDir.appendingPathComponent("S567.\(LibraryLayout.packageExtension)",
                                                    isDirectory: true)
        catalog = try Catalog.create(at: libraryURL)
        root = try catalog.ensureRoot(for: src, mode: .reference)
        _ = NSApplication.shared
    }

    override func tearDownWithError() throws {
        catalog = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixture

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    @discardableResult
    private func addAsset(_ name: String, minute: Int) throws -> Asset {
        try Data([0x00]).write(to: src.appendingPathComponent(name))
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                          kind: .raw, size: 1, mtime: 0,
                          contentHash: UUID().uuidString,
                          width: 6000, height: 4000,
                          captureTime: String(format: "2026-06-01T10:%02d:00Z", minute),
                          captureLocalDate: "2026-06-01",
                          cameraMake: "LEICA", cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
        try catalog.dbQueue.write { db in try asset.insert(db) }
        return asset
    }

    private func openSession() throws -> CatalogSession {
        let store = MemoryStore()
        let session = CatalogSession(filterStore: store, sortPreferenceStore: store,
                                     remembersRecentLibrary: false)
        try session.open(libraryURL)
        return session
    }

    private struct LibraryFields {
        var rating: Int
        var flag: String?
        var colorLabel: String?
    }

    private func fields(_ id: String) throws -> LibraryFields {
        let row = try catalog.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT rating, flag, color_label FROM assets WHERE id = ?",
                             arguments: [id])
        }
        let r = try XCTUnwrap(row, "库里没有这一行：\(id)")
        return LibraryFields(rating: r["rating"], flag: r["flag"], colorLabel: r["color_label"])
    }

    /// `L.dng` + `L-denoised.dng` — `makeStack` recognises the pair by filename. `top` decides which
    /// member is the visible row; the other is hidden exactly as it is in the three browsers.
    private func makeDenoisePair(top: @escaping (Asset, Asset) -> Asset) throws
        -> (original: Asset, product: Asset, top: Asset) {
        let original = try addAsset("L.dng", minute: 0)
        let product = try addAsset("L-denoised.dng", minute: 1)
        let chosen = top(original, product)
        let other = chosen.id == original.id ? product : original
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [chosen.id, other.id]))
        XCTAssertEqual(summary.kind, .denoise, "L + L-denoised ⇒ denoise")
        XCTAssertEqual(summary.topID, chosen.id)
        return (original, product, chosen)
    }

    // MARK: - ① 旗标：两行都写

    func testFlagOnTheDenoiseTopWritesBothRows() throws {
        let pair = try makeDenoisePair { _, product in product }
        let session = try openSession()
        XCTAssertEqual(session.metadataTargetIDs, [pair.product.id], "网格只画置顶")
        session.selectOnly(pair.product.id)

        XCTAssertTrue(session.setFlagForSelection("pick"))

        let a = try fields(pair.product.id)
        let b = try fields(pair.original.id)
        print("① product \(a) original \(b) affected \(session.lastMetadataAffectedRows)")
        XCTAssertEqual(a.flag, "pick")
        XCTAssertEqual(b.flag, "pick", "① 原图也拿到旗标")
        XCTAssertEqual(session.lastMetadataAffectedRows, 2, "① 一次事务写了两行")
    }

    // MARK: - ② 清旗标：两行都清

    func testClearingTheFlagClearsBothRows() throws {
        let pair = try makeDenoisePair { _, product in product }
        let session = try openSession()
        session.selectOnly(pair.product.id)
        XCTAssertTrue(session.setFlagForSelection("pick"))
        XCTAssertEqual(try fields(pair.original.id).flag, "pick", "② 前置：已同步")

        XCTAssertTrue(session.setFlagForSelection(nil))

        let a = try fields(pair.product.id)
        let b = try fields(pair.original.id)
        print("② product \(a) original \(b) affected \(session.lastMetadataAffectedRows)")
        XCTAssertNil(a.flag)
        XCTAssertNil(b.flag, "② 原图也清掉了")
        XCTAssertEqual(session.lastMetadataAffectedRows, 2)
    }

    // MARK: - ③ ★ / 色标：同一条门

    func testRatingAndColourLabelRideTheSameDoor() throws {
        let pair = try makeDenoisePair { _, product in product }
        let session = try openSession()
        session.selectOnly(pair.product.id)

        XCTAssertTrue(session.setRatingForSelection(3))
        var a = try fields(pair.product.id)
        var b = try fields(pair.original.id)
        print("③ rating product \(a) original \(b) affected \(session.lastMetadataAffectedRows)")
        XCTAssertEqual(a.rating, 3)
        XCTAssertEqual(b.rating, 3, "③ 原图也是 3★")
        XCTAssertEqual(session.lastMetadataAffectedRows, 2)

        XCTAssertTrue(session.setColorLabelForSelection("red"))
        a = try fields(pair.product.id)
        b = try fields(pair.original.id)
        print("③ colour product \(a) original \(b) affected \(session.lastMetadataAffectedRows)")
        XCTAssertEqual(a.colorLabel, "red")
        XCTAssertEqual(b.colorLabel, "red", "③ 原图也是 red")
        XCTAssertEqual(session.lastMetadataAffectedRows, 2)
    }

    // MARK: - ④ 普通堆叠：只写选中那一张

    func testAPlainStackStaysSingleRow() throws {
        let l = try addAsset("L.dng", minute: 0)
        let m = try addAsset("M.dng", minute: 1)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [m.id, l.id]))
        XCTAssertEqual(summary.kind, .plain, "[L, M] ⇒ plain")
        let session = try openSession()
        session.selectOnly(summary.topID)

        XCTAssertTrue(session.setFlagForSelection("pick"))

        let top = try fields(summary.topID)
        let sibling = try fields(summary.topID == l.id ? m.id : l.id)
        print("④ top \(top) sibling \(sibling) affected \(session.lastMetadataAffectedRows)")
        XCTAssertEqual(top.flag, "pick")
        XCTAssertNil(sibling.flag, "④ 普通堆叠的兄弟不许同步")
        XCTAssertEqual(session.lastMetadataAffectedRows, 1, "④ 只动了一行")
    }

    // MARK: - ⑤ 三成员堆叠：不联动

    func testAThreeMemberStackDoesNotSync() throws {
        let a = try addAsset("L.dng", minute: 0)
        let b = try addAsset("L-denoised.dng", minute: 1)
        let c = try addAsset("X.dng", minute: 2)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: [c.id, b.id, a.id]))
        XCTAssertEqual(summary.kind, .plain, "三成员按规则就是 plain")
        let session = try openSession()
        session.selectOnly(summary.topID)

        XCTAssertTrue(session.setFlagForSelection("pick"))
        XCTAssertEqual(try fields(summary.topID).flag, "pick")
        XCTAssertNil(try fields(a.id).flag, "⑤ a 不动")
        XCTAssertNil(try fields(b.id).flag, "⑤ b 不动")
        XCTAssertEqual(session.lastMetadataAffectedRows, 1)

        // The same three rows with the kind forced to denoise: the live-member-count gate is what
        // stops the write, so a 3-member "denoise" stack must still stay single-row.
        try catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET stack_kind = 'denoise' WHERE stack_id = ?",
                           arguments: [summary.id])
        }
        XCTAssertTrue(session.setFlagForSelection("reject"))
        XCTAssertEqual(try fields(summary.topID).flag, "reject")
        XCTAssertNil(try fields(a.id).flag, "⑤ kind=denoise 但三成员：a 仍不动")
        XCTAssertNil(try fields(b.id).flag, "⑤ kind=denoise 但三成员：b 仍不动")
        XCTAssertEqual(session.lastMetadataAffectedRows, 1, "⑤ denoiseSibling 只认 2 个活成员")
    }

    // MARK: - ⑥ 反方向：可见的原图 → 产物

    func testFlaggingTheVisibleOriginalSyncsToTheProduct() throws {
        let pair = try makeDenoisePair { original, _ in original }
        let session = try openSession()
        XCTAssertEqual(session.metadataTargetIDs, [pair.original.id], "原图这一行是置顶")
        session.selectOnly(pair.original.id)

        XCTAssertTrue(session.setFlagForSelection("pick"))

        let a = try fields(pair.original.id)
        let b = try fields(pair.product.id)
        print("⑥ original \(a) product \(b) affected \(session.lastMetadataAffectedRows)")
        XCTAssertEqual(a.flag, "pick")
        XCTAssertEqual(b.flag, "pick", "⑥ 产物也拿到旗标")
        XCTAssertEqual(session.lastMetadataAffectedRows, 2)
    }
}
