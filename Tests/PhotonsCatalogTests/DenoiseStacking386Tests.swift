import XCTest
import GRDB
import PhotonsCatalog

/// §386 ③⑩ 的数据层判据 —— 降噪产物与原图组成堆叠、**产物置顶**，且原图先被抽出旧堆叠。
///
/// This is the same two-step ordering §384 pinned for HDR. §386 reuses it through the shared
/// `makeStack(resultAssetID:participantIDs:)`, so these tests double as the proof that the
/// generalisation did not fork the behaviour: `makeHDRStack` is now a forwarder and both entry
/// points must still leave the **product** at rank 0.
final class DenoiseStacking386Tests: XCTestCase {

    private var workDir: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise386-stack-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        catalog = try Catalog.create(at: workDir.appendingPathComponent("D.photons", isDirectory: true))
        let shoot = workDir.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: shoot, mode: .reference)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    @discardableResult
    private func seed(_ name: String, minute: Int) throws -> Asset {
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                          kind: .raw, size: 16, mtime: 0, contentHash: UUID().uuidString,
                          captureTime: String(format: "2026-06-01T10:%02d:00Z", minute),
                          captureLocalDate: "2026-06-01")
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

    /// ③ 产物置顶、count == 2 —— 即使产物在**显示顺序**里排在原图之后（minute 更大），
    /// 唯一的 rank 0 来源是调用方数组顺序。
    func testTheProductIsTheTopAndTheStackHasTwoMembers() throws {
        let original = try seed("IMG_0001.dng", minute: 1)
        let product = try seed("IMG_0001-denoised.dng", minute: 9)
        XCTAssertGreaterThan(product.captureTime ?? "", original.captureTime ?? "",
                            "前提：显示顺序里产物在后，所以它当置顶只能靠调用方顺序")

        let stack = try XCTUnwrap(try catalog.makeStack(resultAssetID: product.id,
                                                       participantIDs: [original.id]))
        print("③ topID=\(stack.topID) count=\(stack.count) members=\(stack.memberIDs)")
        XCTAssertEqual(stack.topID, product.id, "③ 产物必须是置顶")
        XCTAssertEqual(stack.count, 2, "③ 产物 + 原图")
        XCTAssertEqual(try row(product.id).rank, 0)
        XCTAssertEqual(try row(original.id).rank, 1)
        XCTAssertEqual(try row(product.id).stack, try row(original.id).stack, "③ 同一个 stack_id")
    }

    /// ③ 原图本来在别的堆叠里 ⇒ 被抽离，旧堆叠自洽（剩两张时重新编号，剩一张时解散）。
    func testTheOriginalIsPulledOutOfItsOldStack() throws {
        let a = try seed("IMG_0010.dng", minute: 10)
        let b = try seed("IMG_0011.dng", minute: 11)
        let c = try seed("IMG_0012.dng", minute: 12)
        try catalog.makeStack(assetIDs: [a.id, b.id, c.id])
        let product = try seed("IMG_0010-denoised.dng", minute: 20)

        let stack = try XCTUnwrap(try catalog.makeStack(resultAssetID: product.id,
                                                       participantIDs: [a.id]))
        XCTAssertEqual(stack.topID, product.id)
        XCTAssertEqual(stack.count, 2)

        print("③ 旧堆叠剩下：b rank=\(try row(b.id).rank) c rank=\(try row(c.id).rank) "
              + "stack==nil? \(try row(b.id).stack == nil)")
        XCTAssertEqual(try row(a.id).stack, stack.id, "③ 原图进了新堆叠")
        XCTAssertEqual(try row(product.id).stack, stack.id, "③ 产物也在同一个堆叠里")
        // Old stack keeps two live members, re-numbered from 0 with no hole.
        XCTAssertEqual(try row(c.id).rank, 0, "旧堆叠的置顶交给显示顺序最前的一张")
        XCTAssertEqual(try row(b.id).rank, 1)
        XCTAssertEqual(try row(b.id).stack, try row(c.id).stack)
    }

    /// The generalisation did not fork: the HDR entry point still produces the same shape.
    func testMakeHDRStackStillForwardsToTheSharedImplementation() throws {
        let original = try seed("IMG_0100.dng", minute: 30)
        let merged = try seed("IMG_0100-merged.dng", minute: 40)
        let stack = try XCTUnwrap(try catalog.makeHDRStack(resultAssetID: merged.id,
                                                          participantIDs: [original.id]))
        XCTAssertEqual(stack.topID, merged.id)
        XCTAssertEqual(stack.count, 2)
        XCTAssertEqual(try row(merged.id).rank, 0)
    }
}
