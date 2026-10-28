import XCTest
import GRDB
@testable import PhotonsCatalog

/// 相册（078 B10）的库层契约。
///
/// 这些断言只看 `library.db`，不经过任何视图：相册的真相在 `albums` / `album_assets` 两张表里，
/// 左栏和网格只是它的两种画法。四条最要紧的：
///
/// * **建 / 改名 / 删** 都要能读回来（同一个 `Catalog` 句柄、以及重新 `open` 之后）；
/// * **删相册不删照片** —— 不是"实现上恰好没删"，而是断言 `assets` 行数与 `fileURL` 都还在；
/// * **一张照片可以属于两个相册** —— 主键是 `(album_id, asset_id)`，这是正常状态；
/// * **按相册过滤只返回成员** —— 网格「点相册」走的正是这条查询。
final class AlbumCRUDTests: XCTestCase {

    private var workDir: URL!
    private var library: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-albums-\\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        library = workDir.appendingPathComponent("A.photonslibrary", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: fixtures

    /// A library with `count` photos in one reference root. The files are actually written: "删相册
    /// 不删照片" is only meaningful if there is a file to survive.
    private func makeLibrary(_ count: Int) throws -> (Catalog, [Asset]) {
        let catalog = try Catalog.create(at: library)
        let shoot = workDir.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: shoot, mode: .reference)
        var assets: [Asset] = []
        for i in 0..<count {
            let rel = String(format: "IMG_%02d.jpg", i)
            try Data("photo \\(i)".utf8).write(to: shoot.appendingPathComponent(rel))
            let asset = Asset(sourceRootId: root.id, relPath: rel, filename: rel, ext: "jpg",
                              kind: .jpeg, size: 8, mtime: 0,
                              contentHash: String(format: "%064d", i),
                              captureTime: String(format: "2026-02-01T10:%02d:00Z", i))
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }
        return (catalog, assets)
    }

    private func photoCount(_ catalog: Catalog) throws -> Int {
        try catalog.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? 0 }
    }

    private func albumAssetRowCount(_ catalog: Catalog) throws -> Int {
        try catalog.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_assets") ?? 0 }
    }

    // MARK: 建 / 改名 / 删

    func testCreateRenameAndDeleteRoundTrip() throws {
        let (catalog, _) = try makeLibrary(3)

        let album = try catalog.createAlbum(named: "  旅行  ")
        XCTAssertEqual(album.name, "旅行", "名字去首尾空白，不是把空白当名字的一部分")
        XCTAssertEqual(try catalog.albums().map(\.name), ["旅行"])
        XCTAssertEqual(try catalog.albums().first?.count, 0, "新建的相册是空的")

        let renamed = try catalog.renameAlbum(id: album.id, to: "旅行 2026")
        XCTAssertEqual(renamed.id, album.id, "改名不改 id —— 成员关系不需要搬家")
        XCTAssertEqual(try catalog.albums().map(\.name), ["旅行 2026"])

        let report = try catalog.deleteAlbum(id: album.id)
        XCTAssertEqual(report.albums, 1)
        XCTAssertEqual(report.entries, 0)
        XCTAssertTrue(try catalog.albums().isEmpty)
        XCTAssertEqual(try photoCount(catalog), 3, "删相册不删照片")
    }

    func testEmptyAndDuplicateNamesAreRejected() throws {
        let (catalog, _) = try makeLibrary(1)
        _ = try catalog.createAlbum(named: "旅行")

        XCTAssertThrowsError(try catalog.createAlbum(named: "   ")) { error in
            XCTAssertEqual(error as? AlbumError, .emptyName)
        }
        XCTAssertThrowsError(try catalog.createAlbum(named: "旅行")) { error in
            XCTAssertEqual(error as? AlbumError, .duplicateName("旅行"))
        }
        // 大小写与空白不算区分：左栏里两行长得一样的相册是无法点击区分的。
        XCTAssertThrowsError(try catalog.createAlbum(named: " 旅行 ")) { error in
            XCTAssertEqual(error as? AlbumError, .duplicateName("旅行"))
        }
        XCTAssertEqual(try catalog.albums().count, 1)
    }

    func testRenamingToTheSameNameIsANoOpAndToAnotherAlbumsNameIsRefused() throws {
        let (catalog, _) = try makeLibrary(1)
        let a = try catalog.createAlbum(named: "A")
        let b = try catalog.createAlbum(named: "B")

        XCTAssertEqual(try catalog.renameAlbum(id: a.id, to: "A").name, "A")
        XCTAssertThrowsError(try catalog.renameAlbum(id: a.id, to: "B")) { error in
            XCTAssertEqual(error as? AlbumError, .duplicateName("B"))
        }
        XCTAssertEqual(try catalog.albums().map(\.name), ["A", "B"], "被拒绝的改名不改动任何一行")
        XCTAssertNotEqual(a.id, b.id)
    }

    // MARK: 加入 / 移出

    func testAddingThreePhotosGivesThreeMembersInClickOrder() throws {
        let (catalog, assets) = try makeLibrary(4)
        let album = try catalog.createAlbum(named: "旅行")
        let ids = assets.prefix(3).map(\.id)

        XCTAssertEqual(try catalog.addAssets(ids, toAlbum: album.id), 3)
        XCTAssertEqual(try catalog.albumAssetIDs(album.id), ids, "成员顺序 = 加入顺序（position）")
        XCTAssertEqual(try catalog.albums().first?.count, 3)

        // 重复加入是幂等的，且不改动已有 position。
        XCTAssertEqual(try catalog.addAssets([ids[1]], toAlbum: album.id), 0)
        XCTAssertEqual(try catalog.albumAssetIDs(album.id), ids)

        // 后来的照片排到末尾，不是插到中间。
        XCTAssertEqual(try catalog.addAssets([assets[3].id], toAlbum: album.id), 1)
        XCTAssertEqual(try catalog.albumAssetIDs(album.id), ids + [assets[3].id])
    }

    func testRemovingPhotosOnlyRemovesTheMembership() throws {
        let (catalog, assets) = try makeLibrary(4)
        let album = try catalog.createAlbum(named: "旅行")
        let ids = assets.map(\.id)
        _ = try catalog.addAssets(ids, toAlbum: album.id)

        XCTAssertEqual(try catalog.removeAssets([ids[1]], fromAlbum: album.id), 1)
        XCTAssertEqual(try catalog.albumAssetIDs(album.id), [ids[0], ids[2], ids[3]])
        XCTAssertEqual(try photoCount(catalog), 4, "移出相册不是删照片")
        XCTAssertEqual(try catalog.removeAssets([ids[1]], fromAlbum: album.id), 0, "移出不在里面的照片什么都不做")

        // 再移出一次同一个 id 是 0，照片仍然在。
        XCTAssertNotNil(try catalog.asset(id: ids[1]))
    }

    /// 同一张照片可以属于任意多个相册（P0-12 的验收原句）。两个相册各自的成员数必须独立。
    func testOnePhotoCanBelongToTwoAlbums() throws {
        let (catalog, assets) = try makeLibrary(4)
        let trip = try catalog.createAlbum(named: "旅行")
        let picks = try catalog.createAlbum(named: "精选")

        let ids = assets.map(\.id)
        _ = try catalog.addAssets([ids[0], ids[1], ids[2]], toAlbum: trip.id)
        _ = try catalog.addAssets([ids[0], ids[1]], toAlbum: picks.id)

        XCTAssertEqual(try catalog.albumAssetCount(trip.id), 3)
        XCTAssertEqual(try catalog.albumAssetCount(picks.id), 2)
        XCTAssertEqual(try albumAssetRowCount(catalog), 5, "5 条关系，4 张照片")

        let memberships = try catalog.albumMemberships(assetIDs: [ids[0], ids[2]])
        XCTAssertEqual(Set(memberships[ids[0]] ?? []), [trip.id, picks.id])
        XCTAssertEqual(memberships[ids[2]], [trip.id])

        // 删掉一个相册，另一个相册的成员一个不少。
        _ = try catalog.deleteAlbum(id: trip.id)
        XCTAssertEqual(try catalog.albumAssetCount(picks.id), 2)
        XCTAssertEqual(try photoCount(catalog), 4)
    }

    // MARK: 删相册不删照片（反证：把删除写成级联删照片，这条必红）

    func testDeletingAnAlbumKeepsEveryPhotoAndItsFile() throws {
        let (catalog, assets) = try makeLibrary(3)
        let album = try catalog.createAlbum(named: "旅行")
        let ids = assets.map(\.id)
        _ = try catalog.addAssets(ids, toAlbum: album.id)

        let photosBefore = try photoCount(catalog)
        let urlsBefore = try assets.map { try catalog.fileURL(for: $0).path }

        let report = try catalog.deleteAlbum(id: album.id)

        XCTAssertEqual(report.entries, 3, "3 条成员关系被清掉")
        XCTAssertEqual(report.albums, 1)
        XCTAssertEqual(try photoCount(catalog), photosBefore, "照片数必须不变")
        XCTAssertEqual(try catalog.stats().total, photosBefore)
        for (asset, url) in zip(assets, urlsBefore) {
            XCTAssertNotNil(try catalog.asset(id: asset.id), "\(asset.filename) 还在库里")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url), "\(asset.filename) 的原文件还在")
        }
        XCTAssertEqual(try albumAssetRowCount(catalog), 0, "成员关系随相册一起走")
    }

    func testDeletingAnAlbumCascadesToNestedAlbumsButNotToTheirPhotos() throws {
        let (catalog, assets) = try makeLibrary(3)
        let parent = try catalog.createAlbum(named: "旅行")
        let child = try catalog.createAlbum(named: "第一天", parentId: parent.id)
        _ = try catalog.addAssets([assets[0].id], toAlbum: parent.id)
        _ = try catalog.addAssets([assets[1].id, assets[2].id], toAlbum: child.id)

        let report = try catalog.deleteAlbum(id: parent.id)
        XCTAssertEqual(report.albums, 2, "子相册跟着父相册一起走（schema 有 parent_id）")
        XCTAssertEqual(report.entries, 3)
        XCTAssertTrue(try catalog.albums().isEmpty)
        XCTAssertEqual(try photoCount(catalog), 3)
    }

    // MARK: 过滤 / 持久化 / 软删

    func testAlbumFilterReturnsExactlyTheMembers() throws {
        let (catalog, assets) = try makeLibrary(5)
        let album = try catalog.createAlbum(named: "旅行")
        let members = [assets[4].id, assets[1].id, assets[3].id]     // 故意乱序加入
        _ = try catalog.addAssets(members, toAlbum: album.id)

        let filtered = try catalog.assets(AssetFilter(limit: 100, albumIds: [album.id]))
        XCTAssertEqual(Set(filtered.map(\.id)), Set(members))
        XCTAssertEqual(filtered.count, 3)
        // 顺序仍是 `capture_time DESC` —— 相册提供范围，不提供排序。
        XCTAssertEqual(filtered.map(\.id), [assets[4].id, assets[3].id, assets[1].id])

        // 两个相册 OR：并集，不重复。
        let other = try catalog.createAlbum(named: "精选")
        _ = try catalog.addAssets([assets[0].id, assets[1].id], toAlbum: other.id)
        let union = try catalog.assets(AssetFilter(limit: 100, albumIds: [album.id, other.id]))
        XCTAssertEqual(Set(union.map(\.id)), Set(members + [assets[0].id]))
        XCTAssertEqual(union.count, 4, "同一张在两个相册里也只出现一次")

        // 别的约束照旧 AND 上去。
        let narrowed = try catalog.assets(AssetFilter(ratingAtLeast: 1, limit: 100, albumIds: [album.id]))
        XCTAssertTrue(narrowed.isEmpty, "库里没有星级，相册 ∩ 星级 = 空")
    }

    func testAlbumsAndMembersSurviveReopeningTheLibrary() throws {
        var (catalog, assets) = try makeLibrary(3)
        let album = try catalog.createAlbum(named: "旅行")
        _ = try catalog.addAssets([assets[0].id, assets[2].id], toAlbum: album.id)

        // 关掉句柄，重新打开 —— 这就是「重启应用」在库这一层的等价物。
        catalog = try Catalog.open(at: library)

        let reopened = try XCTUnwrap(try catalog.albums().first)
        XCTAssertEqual(reopened.name, "旅行")
        XCTAssertEqual(reopened.id, album.id)
        XCTAssertEqual(reopened.count, 2)
        XCTAssertEqual(try catalog.albumAssetIDs(reopened.id), [assets[0].id, assets[2].id])
        XCTAssertEqual(try catalog.assets(AssetFilter(limit: 100, albumIds: [album.id])).count, 2)
    }

    /// 软删（`setDeleted(true)`）的照片还在 `album_assets` 里，但**不计数**：左栏的数字必须等于
    /// 点开相册后网格的行数，否则「相册里 3 张，点进去只有 2 张」就是一次谎报。
    func testSoftDeletedPhotosAreNotCountedAndNotReturned() throws {
        let (catalog, assets) = try makeLibrary(3)
        let album = try catalog.createAlbum(named: "旅行")
        _ = try catalog.addAssets(assets.map(\.id), toAlbum: album.id)
        try catalog.setDeleted(true, forAsset: assets[1].id)

        XCTAssertEqual(try catalog.albums().first?.count, 2)
        XCTAssertEqual(try catalog.albumAssetIDs(album.id), [assets[0].id, assets[2].id])
        XCTAssertEqual(try albumAssetRowCount(catalog), 3, "关系还在，只是那张照片不在图库里了")
    }

    /// 删**照片**时级联清掉它的成员关系（`Availability.deleteAssets` 已经这么做了），
    /// 但相册本身留着：删一张照片不该删掉它所在的那个相册。
    func testDeletingAPhotoClearsItsMembershipButKeepsTheAlbum() throws {
        let (catalog, assets) = try makeLibrary(3)
        let album = try catalog.createAlbum(named: "旅行")
        _ = try catalog.addAssets(assets.prefix(2).map(\.id), toAlbum: album.id)

        let report = try catalog.deleteAssets(ids: [assets[0].id])
        XCTAssertEqual(report.albumEntries, 1, "一张照片的关系被清掉")
        XCTAssertEqual(try catalog.albums().map(\.id), [album.id], "相册还在")
        XCTAssertEqual(try catalog.albumAssetCount(album.id), 1)
        XCTAssertEqual(try photoCount(catalog), 2)
    }

    func testAddAndRemoveOnAMissingAlbumAreErrors() throws {
        let (catalog, assets) = try makeLibrary(1)
        XCTAssertThrowsError(try catalog.addAssets([assets[0].id], toAlbum: "nope"))
        XCTAssertThrowsError(try catalog.removeAssets([assets[0].id], fromAlbum: "nope"))
        XCTAssertThrowsError(try catalog.deleteAlbum(id: "nope"))
        XCTAssertThrowsError(try catalog.renameAlbum(id: "nope", to: "x"))
        XCTAssertEqual(try photoCount(catalog), 1)
    }

    /// 一次加入是一个事务：未知 id 被跳过，已知的照进，不是整批失败。
    func testAddingAnUnknownIDIsSkippedNotFatal() throws {
        let (catalog, assets) = try makeLibrary(2)
        let album = try catalog.createAlbum(named: "旅行")
        let added = try catalog.addAssets([assets[0].id, "not-an-asset", assets[1].id], toAlbum: album.id)
        XCTAssertEqual(added, 2)
        XCTAssertEqual(try catalog.albumAssetIDs(album.id), [assets[0].id, assets[1].id])
    }
}
