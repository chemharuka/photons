import XCTest
import GRDB
import PhotonsCatalog

/// §384 — 合成结果 + 参与的原帧 = 一个新堆叠，**结果为置顶**，参与的原帧**抽离**旧堆叠。
///
/// The data-layer half of the ticket, with no merge and no UI: a "merged" asset is just a row, and
/// what matters is the relationship the catalog ends up in. Three claims, in the order the user made
/// them:
///
/// * ④ `makeHDRStack(result:participants:)` puts the **result** at rank 0 and the participants under
///   it (`count == 4` for three frames) — one call, no `setStackTop` afterwards;
/// * ⑤ a participant that was in stack A leaves A, A is left self-consistent (re-numbered by display
///   order, one 置顶, no rank holes) and dissolves when only one photo remains;
/// * the rank re-numbering is what `repairStack` cannot do, so the fourth case pins it: a stack of
///   four losing ranks 0 and 2 keeps **two** members at ranks 0 and 1 — not ranks 1 and 3 with no top.
final class HDRStacking384Tests: XCTestCase {

    private var workDir: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hdr384-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        catalog = try Catalog.create(at: workDir.appendingPathComponent("H.photons",
                                                                        isDirectory: true))
        let shoot = workDir.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: shoot, mode: .reference)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixture

    /// Rows only — no files, because nothing in this suite opens one. Minute = index, so display
    /// order (`capture_time DESC`) is the reverse of insertion, which is what makes "in display
    /// order" a claim the test can fail on.
    @discardableResult
    private func seed(_ count: Int, prefix: String = "IMG", minuteBase: Int = 0) throws -> [Asset] {
        var out: [Asset] = []
        for i in 0 ..< count {
            let name = String(format: "\(prefix)_%02d.dng", i)
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                              kind: .raw, size: 16, mtime: 0,
                              contentHash: UUID().uuidString,
                              captureTime: String(format: "2026-03-01T10:%02d:00Z", minuteBase + i),
                              captureLocalDate: "2026-03-01")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            out.append(asset)
        }
        return out
    }

    /// A "merged" row that is not in any stack — display order puts it in the middle of the day, so
    /// the only way it can be 置顶 is the caller's array order (which is the point of ④).
    private func seedMerged() throws -> Asset {
        let name = "IMG_02-merged.dng"
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                          kind: .raw, size: 16, mtime: 0,
                          contentHash: UUID().uuidString,
                          captureTime: "2026-03-01T10:02:00Z",
                          captureLocalDate: "2026-03-01")
        try catalog.dbQueue.write { db in try asset.insert(db) }
        return asset
    }

    private func row(_ id: String) throws -> (stack: String?, rank: Int) {
        try catalog.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT stack_id, stack_rank FROM assets WHERE id = ?",
                                       arguments: [id])
            return (row?["stack_id"] as String?, row?["stack_rank"] as Int? ?? -1)
        }
    }

    private func stackIDs() throws -> [String] {
        try catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT stack_id FROM assets WHERE stack_id IS NOT NULL")
        }
    }

    private func liveCount(ofStack id: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM assets WHERE stack_id = ? AND deleted = 0
                """, arguments: [id]) ?? -1
        }
    }

    private func rankZeroCount(ofStack id: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM assets WHERE stack_id = ? AND stack_rank = 0
                """, arguments: [id]) ?? -1
        }
    }

    // MARK: - ④ 结果置顶

    func testTheMergedResultBecomesTheTopOfTheNewStackOfFour() throws {
        let frames = try seed(3)
        let merged = try seedMerged()

        let stack = try XCTUnwrap(try catalog.makeHDRStack(resultAssetID: merged.id,
                                                           participantIDs: frames.map(\.id)))
        print("④ topID=\(stack.topID.prefix(8)) count=\(stack.count) merged=\(merged.id.prefix(8))")
        XCTAssertEqual(stack.topID, merged.id, "④ 合成结果必须是置顶，不是某张原帧")
        XCTAssertEqual(stack.count, 4, "④ 结果 + 3 张原帧 = 4")
        XCTAssertEqual(try row(merged.id).rank, 0)
        XCTAssertEqual(try liveCount(ofStack: stack.id), 4)
        XCTAssertEqual(try rankZeroCount(ofStack: stack.id), 1, "一个堆叠只有一个置顶")
    }

    // MARK: - ⑤ 抽离原有堆叠（原堆叠还有第三张）

    func testParticipantsLeaveTheirOldStackWhichKeepsTheUnselectedMember() throws {
        let all = try seed(3)                       // IMG_00, IMG_01, IMG_02
        let old = try XCTUnwrap(try catalog.makeStack(assetIDs: all.map(\.id)))
        let participants = [all[0].id, all[1].id]   // 抽走两张，第三张不在选中里
        let bystander = all[2].id
        let merged = try seedMerged()

        let fresh = try XCTUnwrap(try catalog.makeHDRStack(resultAssetID: merged.id,
                                                           participantIDs: participants))
        let bystanderRow = try row(bystander)
        print("⑤a 新堆叠 top=\(fresh.topID.prefix(8)) count=\(fresh.count)；原堆叠 \(old.id.prefix(8)) "
              + "剩 stack_id=\(String(describing: bystanderRow.stack)) rank=\(bystanderRow.rank) "
              + "members=\(try liveCount(ofStack: old.id))")
        XCTAssertEqual(fresh.topID, merged.id)
        XCTAssertEqual(fresh.count, 3, "结果 + 抽走的两张")
        XCTAssertNotEqual(fresh.id, old.id, "是新堆叠，不是复用旧堆叠")
        // 只剩一张 ⇒ 自动解散（§1.4 的规则），而那张照片本身还在库里。
        XCTAssertNil(bystanderRow.stack, "⑤a 原堆叠只剩第 3 张 ⇒ stack_id 回到 NULL")
        XCTAssertEqual(try liveCount(ofStack: old.id), 0)
        XCTAssertEqual(try stackIDs().filter { $0 == old.id }.count, 0)
    }

    // MARK: - ⑤ 抽离原有堆叠（原堆叠恰好就是这两张）

    func testAStackOfOnlyTheTwoParticipantsDissolves() throws {
        let all = try seed(2)
        let old = try XCTUnwrap(try catalog.makeStack(assetIDs: all.map(\.id)))
        let merged = try seedMerged()

        let fresh = try XCTUnwrap(try catalog.makeHDRStack(resultAssetID: merged.id,
                                                           participantIDs: all.map(\.id)))
        print("⑤b 新堆叠 top=\(fresh.topID.prefix(8)) count=\(fresh.count)；旧堆叠 \(old.id.prefix(8)) "
              + "剩 members=\(try liveCount(ofStack: old.id))")
        XCTAssertEqual(fresh.count, 3)
        for asset in all {
            XCTAssertEqual(try row(asset.id).stack, fresh.id, "两张原帧应在新的合成堆叠里")
        }
        XCTAssertEqual(try liveCount(ofStack: old.id), 0, "旧堆叠自动解散")
        XCTAssertEqual(try stackIDs().filter { $0 == old.id }.count, 0)
    }

    // MARK: - ⑤ 剩下的成员要重排 rank（repairStack 做不到的那一条）

    func testTheRemainingMembersAreRenumberedWithoutHolesOrASecondTop() throws {
        let all = try seed(4)                       // 显示顺序 = IMG_03, IMG_02, IMG_01, IMG_00
        let old = try XCTUnwrap(try catalog.makeStack(assetIDs: all.map(\.id)))
        // 抽走显示顺序里的第 1 张和第 3 张（rank 0 与 rank 2）——正是 §1.4 描述的坑。
        let display = try catalog.stackMembers(stackID: old.id)
        XCTAssertEqual(display.count, 4)
        let participants = [display[0].id, display[2].id]
        let stayers = [display[1].id, display[3].id]
        let merged = try seedMerged()

        _ = try catalog.makeHDRStack(resultAssetID: merged.id, participantIDs: participants)

        let ranks = try stayers.map { try row($0).rank }
        print("⑤c 旧堆叠剩 \(try liveCount(ofStack: old.id)) 张，ranks=\(ranks)，"
              + "rank0 数=\(try rankZeroCount(ofStack: old.id))")
        XCTAssertEqual(try liveCount(ofStack: old.id), 2, "两张没被选中，堆叠仍在")
        XCTAssertEqual(ranks.sorted(), [0, 1], "按显示顺序重排为 0,1（repairStack 只会留 1,3）")
        XCTAssertEqual(try rankZeroCount(ofStack: old.id), 1, "仍然只有一个置顶")
        XCTAssertEqual(try row(stayers[0]).stack, old.id)
    }

    // MARK: - 抽离本身：只动被点名的照片

    func testExtractingTouchesOnlyTheNamedRows() throws {
        let all = try seed(3)
        let old = try XCTUnwrap(try catalog.makeStack(assetIDs: all.map(\.id)))
        let moved = try catalog.extractFromStacks(assetIDs: [all[0].id])
        print("抽离 1 张 ⇒ moved=\(moved)，旧堆叠剩 \(try liveCount(ofStack: old.id))")
        XCTAssertEqual(moved, 1)
        XCTAssertEqual(try liveCount(ofStack: old.id), 2)
        XCTAssertNil(try row(all[0].id).stack)
    }

    // MARK: - 反向门 ⑩ 的对照组：把结果放最后就选错置顶

    /// Runs the same fixture with the array order reversed — this is what `makeStack` alone does when
    /// the caller forgets "result first", and it is why ④ can fail (§3 ⑩).
    func testTheWrongOrderMakesAFrameTheTop() throws {
        let frames = try seed(3)
        let merged = try seedMerged()
        let stack = try XCTUnwrap(try catalog.makeStack(assetIDs: frames.map(\.id) + [merged.id]))
        print("⑩ 反证：结果放最后 ⇒ topID=\(stack.topID.prefix(8))，是原帧？\(stack.topID != merged.id)")
        XCTAssertNotEqual(stack.topID, merged.id, "结果放最后时置顶必然是某张原帧——这正是 ④ 要抓的")
    }
}
