import XCTest
import Foundation
import GRDB
@testable import PhotonsCatalog

/// §378 — 照片堆叠的库层契约。
///
/// Everything here is asserted against `library.db`, never against a view: a stack's whole truth is
/// "these rows share `stack_id`, and this one is `stack_rank = 0`", so the numbers below *are* the
/// feature. The four that matter most:
///
/// * **exactly one 置顶** — five members, one rank 0, enforced by the partial unique index;
/// * **设为置顶 is a swap, not a re-sort** — the old top takes the chosen member's old rank;
/// * **deleting the top promotes the next member in the same transaction** (the v6 trigger), and a
///   stack that shrinks to one member dissolves;
/// * **v6 replays** — running the migration again on a library that already has the columns is a
///   no-op rather than an "duplicate column" error.
final class StackModel378Tests: XCTestCase {

    private var workDir: URL!
    private var package: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-stacks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        package = workDir.appendingPathComponent("S.\(LibraryLayout.packageExtension)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    /// `count` photos in one reference root, capture times ascending with the index (so display
    /// order — `capture_time DESC` — is the reverse of the insert order).
    private func makeLibrary(_ count: Int) throws -> (Catalog, [Asset]) {
        let catalog = try Catalog.create(at: package)
        let shoot = workDir.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: shoot, mode: .reference)
        var assets: [Asset] = []
        for i in 0..<count {
            let rel = String(format: "IMG_%02d.dng", i)
            try Data("photo \(i)".utf8).write(to: shoot.appendingPathComponent(rel))
            let asset = Asset(sourceRootId: root.id, relPath: rel, filename: rel, ext: "dng",
                              kind: .raw, size: 8, mtime: 0,
                              contentHash: String(format: "%064d", i),
                              captureTime: String(format: "2026-02-01T10:%02d:00Z", i))
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }
        return (catalog, assets)
    }

    private func count(_ catalog: Catalog, _ sql: String, _ args: [any DatabaseValueConvertible] = []) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: StatementArguments(args)) ?? -1
        }
    }

    private func columnNames(_ catalog: Catalog) throws -> [String] {
        try catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('assets')")
        }
    }

    /// Display order for these fixtures: `capture_time DESC`, i.e. the **reverse** of insert order —
    /// the same order the grid/filmstrip/photo list show (`PhotoSortOrder`), and therefore the order
    /// every real caller passes to `makeStack`.
    private func displayOrder(_ assets: [Asset]) -> [String] {
        assets.map(\.id).reversed()
    }

    // MARK: - ① 五个成员，一个置顶

    func testFivePhotosBecomeOneStackWithExactlyOneTop() throws {
        let (catalog, assets) = try makeLibrary(5)
        let ids = displayOrder(assets)

        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: ids), "五张应该成为一个堆叠")

        XCTAssertEqual(try count(catalog, "SELECT COUNT(*) FROM assets WHERE stack_id IS NOT NULL"), 5)
        XCTAssertEqual(try count(catalog, "SELECT COUNT(DISTINCT stack_id) FROM assets WHERE stack_id IS NOT NULL"), 1)
        XCTAssertEqual(try count(catalog, "SELECT COUNT(*) FROM assets WHERE stack_id = ? AND stack_rank = 0",
                                 [summary.id]), 1,
                       "恰好一张置顶 —— 部分唯一索引没爆")
        XCTAssertEqual(summary.topID, ids[0], "传给 makeStack 的第一张是置顶")
        XCTAssertEqual(summary.memberIDs, ids, "成员顺序 = 调用方的显示顺序")
        XCTAssertEqual(summary.count, 5)
        // stack_id 是新 UUID，不是任何 asset id。
        XCTAssertFalse(ids.contains(summary.id), "stack_id 不跟着任何 asset id 走")
        print("① members \(try catalog.stackMembers(stackID: summary.id).map(\.filename)) top \(summary.topID.prefix(8))")
    }

    // MARK: - ② 换置顶是交换，不是重排

    func testSetStackTopSwapsTheTwoRanksAndKeepsTheOrder() throws {
        let (catalog, assets) = try makeLibrary(5)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: displayOrder(assets)))
        let membersBefore = try catalog.stackMembers(stackID: summary.id).map(\.id)
        let oldTop = try XCTUnwrap(membersBefore.first)
        let second = membersBefore[1]
        let ranksBefore = Dictionary(uniqueKeysWithValues: try catalog.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, stack_rank FROM assets WHERE stack_id = ?",
                             arguments: [summary.id]).map { ($0["id"] as String, $0["stack_rank"] as Int) }
        })

        XCTAssertTrue(try catalog.setStackTop(stackID: summary.id, assetID: second))

        let ranksAfter = Dictionary(uniqueKeysWithValues: try catalog.dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, stack_rank FROM assets WHERE stack_id = ?",
                             arguments: [summary.id]).map { ($0["id"] as String, $0["stack_rank"] as Int) }
        })
        XCTAssertEqual(try count(catalog, "SELECT COUNT(*) FROM assets WHERE stack_id = ? AND stack_rank = 0",
                                 [summary.id]), 1, "置顶仍恰好一张")
        XCTAssertEqual(ranksAfter[second], 0, "被点的那张成为置顶")
        XCTAssertEqual(ranksAfter[oldTop], ranksBefore[second],
                       "原置顶拿到新置顶的旧 rank（交换，不是重排）")
        XCTAssertEqual(try catalog.stackMembers(stackID: summary.id).map(\.id), membersBefore,
                       "members 的显示顺序不变")
        print("② ranks before \(ranksBefore) after \(ranksAfter)")
    }

    // MARK: - ③ 取消堆叠

    func testUngroupClearsEveryColumnAndTheIndexLosesTheStack() throws {
        let (catalog, assets) = try makeLibrary(5)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: displayOrder(assets)))

        XCTAssertEqual(try catalog.ungroup(stackIDs: [summary.id]), 5)

        XCTAssertEqual(try count(catalog, "SELECT COUNT(*) FROM assets WHERE stack_id = ?", [summary.id]), 0)
        XCTAssertEqual(try count(catalog, "SELECT COUNT(*) FROM assets WHERE stack_id IS NOT NULL"), 0)
        XCTAssertEqual(try count(catalog, "SELECT COUNT(*) FROM assets WHERE stack_rank <> 0"), 0)
        XCTAssertNil(try catalog.stackSummary(stackID: summary.id), "索引里不再有该 stack")
    }

    // MARK: - ④ 删掉置顶，同一事务里有人接班

    func testDeletingTheTopPromotesTheFirstRemainingMemberImmediately() throws {
        let (catalog, assets) = try makeLibrary(5)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: displayOrder(assets)))
        let members = try catalog.stackMembers(stackID: summary.id)
        let top = members[0]
        let expectedNext = members[1]

        let report = try catalog.deleteAssets(ids: [top.id])
        XCTAssertEqual(report.assets, 1)

        let after = try catalog.stackMembers(stackID: summary.id).map(\.id)
        XCTAssertEqual(after.count, 4)
        XCTAssertEqual(try count(catalog, "SELECT COUNT(*) FROM assets WHERE stack_id = ? AND stack_rank = 0",
                                 [summary.id]), 1)
        let newTop = try catalog.stackSummary(stackID: summary.id)?.topID
        XCTAssertEqual(newTop, expectedNext.id, "成员里显示顺序最前的一张升为置顶")
        XCTAssertEqual(after.first, expectedNext.id)
        print("④ deleted \(top.filename) → new top \(expectedNext.filename)")
    }

    // MARK: - ⑤ 只剩一张时不留残壳

    func testDeletingDownToOneMemberDissolvesTheStack() throws {
        let (catalog, assets) = try makeLibrary(3)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: displayOrder(assets)))

        // First delete: 3 → 2, the stack survives with a new 置顶.
        let firstTop = try XCTUnwrap(try catalog.stackMembers(stackID: summary.id).first)
        _ = try catalog.deleteAssets(ids: [firstTop.id])
        XCTAssertEqual(try count(catalog, "SELECT COUNT(*) FROM assets WHERE stack_id = ?", [summary.id]), 2)
        XCTAssertEqual(try count(catalog, "SELECT COUNT(*) FROM assets WHERE stack_id = ? AND stack_rank = 0",
                                 [summary.id]), 1)

        // Second delete: 2 → 1, and the survivor must come back out of the stack.
        let secondTop = try XCTUnwrap(try catalog.stackMembers(stackID: summary.id).first)
        _ = try catalog.deleteAssets(ids: [secondTop.id])
        let survivor = try XCTUnwrap(try catalog.asset(id: assets.first { $0.id != firstTop.id && $0.id != secondTop.id }!.id))
        XCTAssertNil(survivor.stackId, "单成员堆叠不留残壳")
        XCTAssertEqual(survivor.stackRank, 0)
        XCTAssertNil(try catalog.stackSummary(stackID: summary.id))
        print("⑤ 3 → 2 → 1: survivor \(survivor.filename) stackId \(survivor.stackId ?? "nil")")
    }

    /// The ⑤ rule on the live row: delete two of three and the last one carries `stack_id = NULL`.
    func testTheLastMemberOfAStackComesBackOutOfIt() throws {
        let (catalog, assets) = try makeLibrary(2)
        let summary = try XCTUnwrap(try catalog.makeStack(assetIDs: displayOrder(assets)))
        let members = try catalog.stackMembers(stackID: summary.id)
        let survivor = members[1]

        _ = try catalog.deleteAssets(ids: [members[0].id])

        let row = try XCTUnwrap(try catalog.asset(id: survivor.id))
        XCTAssertNil(row.stackId, "单成员堆叠不留残壳")
        XCTAssertEqual(row.stackRank, 0)
        XCTAssertNil(try catalog.stackSummary(stackID: summary.id))
        print("⑤ survivor \(row.filename) stackId \(row.stackId ?? "nil") rank \(row.stackRank)")
    }

    // MARK: - ⑥ migration 可重放

    func testV6MigrationReplaysWithoutErrorAndLeavesOneOfEachColumn() throws {
        let catalog = try Catalog.create(at: package)
        XCTAssertEqual(catalog.schemaVersionApplied, 6)
        XCTAssertEqual(try columnNames(catalog).filter { $0 == "stack_id" }.count, 1)
        XCTAssertEqual(try columnNames(catalog).filter { $0 == "stack_rank" }.count, 1)

        // Rewind the stamp the way a restored backup can, and forget GRDB's record so the step is
        // actually *re-run* (that is the guard this test exists for).
        try catalog.dbQueue.write { db in
            try db.execute(sql: "PRAGMA user_version = 5")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v6'")
        }
        XCTAssertNoThrow(try Schema.migrate(catalog.dbQueue))
        XCTAssertNoThrow(try Schema.migrate(catalog.dbQueue))

        let columns = try columnNames(catalog)
        XCTAssertEqual(columns.filter { $0 == "stack_id" }.count, 1, "列只有一个（重放不是重复 ALTER）")
        XCTAssertEqual(columns.filter { $0 == "stack_rank" }.count, 1)
        let indexes = try catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'assets'")
        }
        XCTAssertTrue(indexes.contains("idx_assets_stack_top"))
        XCTAssertTrue(indexes.contains("idx_assets_stack_members"))
        print("⑥ columns \(columns.filter { $0.hasPrefix("stack") }) indexes \(indexes.filter { $0.contains("stack") })")
    }

    /// The same reasoning for a real v5 file: `Catalog.open` snapshots it, runs v6, and the rows read
    /// back with `stack_id = NULL` / `stack_rank = 0` (which is what "not in a stack" means).
    func testOpeningAV5LibraryAddsTheColumnsWithNullStacks() throws {
        let layout = LibraryLayout(packageURL: package)
        try layout.ensureDirectories()
        let queue = try DatabaseQueue(path: layout.databaseURL.path, configuration: Catalog.configuration())
        try Schema.migrate(queue, upTo: 5)
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 5") }
        let rootID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source_roots(id, display_name, path_hint, management_mode, status, created_at)
                VALUES(?, 'src', ?, 'reference', 'online', ?)
                """, arguments: [rootID, workDir.appendingPathComponent("src").path, ISO8601.now()])
            try db.execute(sql: """
                INSERT INTO assets(id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                   content_hash, imported_at)
                VALUES(?, ?, 'v5.dng', 'v5.dng', 'dng', 'raw', 9, 0, 'h5', ?)
                """, arguments: [UUID().uuidString, rootID, ISO8601.now()])
        }
        try queue.close()

        let opened = try Catalog.open(at: package)
        XCTAssertEqual(opened.schemaVersionApplied, 6)
        let rows = try opened.assets(AssetFilter())
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].stackId, "老库的照片不属于任何堆叠")
        XCTAssertEqual(rows[0].stackRank, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: layout.backupsURL.path)
            .contains("library.bak-v5.db"), "迁移前先留快照，和其他版本一致")
    }
}
