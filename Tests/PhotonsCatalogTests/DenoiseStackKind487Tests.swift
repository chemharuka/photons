import XCTest
import Foundation
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// 487 — 降噪是一种**特殊的堆叠**。
///
/// The data layer owns three facts and this suite pins each one:
///
///   · **kind** — `plain` / `denoise`, recognized from the two filenames by the one rule in
///     `StackKind.forMemberFilenames`;
///   · **linkage** — an edit propagated from either member writes the same payload to both, and
///     writing a document the sibling already has is a no-op (no history row);
///   · **restack alignment** — when a denoise pair is grouped again, the later `created_at` wins and
///     an exact tie prefers the product.
///
/// Everything is asserted against `library.db`, never against a view: the bytes and the rows *are*
/// the feature (the same evidence rule `StackModel378Tests` uses).
final class DenoiseStackKind487Tests: XCTestCase {

    private var workDir: URL!
    private var package: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-487-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        package = workDir.appendingPathComponent("D.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: package)
        let shoot = workDir.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: shoot, mode: .reference)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    @discardableResult
    private func seed(_ name: String, minute: Int = 0) throws -> Asset {
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                          kind: .raw, size: 16, mtime: 0, contentHash: UUID().uuidString,
                          captureTime: String(format: "2026-06-01T10:%02d:00Z", minute),
                          captureLocalDate: "2026-06-01")
        try catalog.dbQueue.write { db in try asset.insert(db) }
        return asset
    }

    private func rawKind(_ id: String) throws -> String? {
        try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT stack_kind FROM assets WHERE id = ?",
                                arguments: [id])
        }
    }

    private func historyCount(_ id: String) throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_history WHERE asset_id = ?",
                             arguments: [id]) ?? -1
        }
    }

    private func historyLabels(_ id: String) throws -> [String] {
        try catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: """
                SELECT COALESCE(label, '') FROM asset_history WHERE asset_id = ? ORDER BY seq
                """, arguments: [id])
        }
    }

    private func bytes(_ id: String) throws -> String {
        try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?",
                                arguments: [id]) ?? "<missing>"
        }
    }

    /// Write a document **with a chosen history time** — the acceptance needs two members whose
    /// `created_at` values can be ordered (and made equal), which `appendDevelop` cannot express
    /// because its empty-history baseline takes the wall clock.
    private func write(_ edit: EditModel, to id: String, at date: Date, label: String = "编辑") throws {
        let json = try Catalog.encode(edit)
        let stamp = ISO8601.string(from: date)
        try catalog.dbQueue.write { db in
            let last = try Int.fetchOne(db, sql: """
                SELECT MAX(seq) FROM asset_history WHERE asset_id = ?
                """, arguments: [id]) ?? -1
            try db.execute(sql: """
                INSERT INTO asset_history(asset_id, seq, develop_json, label, created_at)
                VALUES(?, ?, ?, ?, ?)
                """, arguments: [id, last + 1, json, label, stamp])
            try db.execute(sql: """
                UPDATE assets SET develop_json = ?, develop_version = develop_version + 1,
                                  edit_time = ?, history_end = ? WHERE id = ?
                """, arguments: [json, stamp, last + 1, id])
        }
    }

    private func edited(_ id: String, exposure: Double) throws -> EditModel {
        var doc = try catalog.develop(forAsset: id)
        doc.light.exposure = exposure
        return doc
    }

    // MARK: - A ① kind recognition

    func testKindRecognitionIsTheFilenameRule() throws {
        let original = try seed("L1030552.dng")
        let product = try seed("L1030552-denoised.dng")
        let pair = try XCTUnwrap(try catalog.makeStack(assetIDs: [original.id, product.id]))
        XCTAssertEqual(pair.kind, .denoise, "[L, L-denoised] ⇒ denoise")

        let a = try seed("A.dng", minute: 1)
        let b = try seed("B.dng", minute: 2)
        let plain = try XCTUnwrap(try catalog.makeStack(assetIDs: [a.id, b.id]))
        XCTAssertEqual(plain.kind, .plain, "[A, B] ⇒ plain")

        let h1 = try seed("HDR-1.dng", minute: 3)
        let h2 = try seed("HDR-2.dng", minute: 4)
        let h3 = try seed("HDR-3.dng", minute: 5)
        let hdr = try XCTUnwrap(try catalog.makeStack(assetIDs: [h1.id, h2.id, h3.id]))
        XCTAssertEqual(hdr.kind, .plain, "three members are never a denoise pair")

        let almost = try seed("M-denoised-2.dng", minute: 6)
        let other = try seed("M.dng", minute: 7)
        let notPair = try XCTUnwrap(try catalog.makeStack(assetIDs: [almost.id, other.id]))
        XCTAssertEqual(notPair.kind, .plain, "只认恰好 -denoised 一次")

        XCTAssertEqual(try catalog.stackKind(ofAsset: product.id), .denoise)
        XCTAssertEqual(try rawKind(product.id), "denoise")
        XCTAssertEqual(try rawKind(a.id), "plain")
        print("① pair \(pair.kind.rawValue) plain \(plain.kind.rawValue) hdr \(hdr.kind.rawValue) "
              + "almost \(notPair.kind.rawValue)")
    }

    // MARK: - A ② v7 → v8 migration

    func testV7LibraryMigratesToV8WithEveryStackPlain() throws {
        // A package of its own: `setUp` already made a v8 library at `package`, and GRDB refuses to
        // migrate a database *backwards* (`upTo: 7` on an already-v8 file).
        let v7Package = workDir.appendingPathComponent("V7.\(LibraryLayout.packageExtension)",
                                                       isDirectory: true)
        let layout = LibraryLayout(packageURL: v7Package)
        try layout.ensureDirectories()
        let queue = try DatabaseQueue(path: layout.databaseURL.path,
                                      configuration: Catalog.configuration())
        try Schema.migrate(queue, upTo: 7)
        try queue.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA user_version = 7") }

        let rootID = UUID().uuidString
        let stackID = UUID().uuidString
        let topID = UUID().uuidString
        let memberID = UUID().uuidString
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO source_roots(id, display_name, path_hint, management_mode, status, created_at)
                VALUES(?, 'src', ?, 'reference', 'online', ?)
                """, arguments: [rootID, workDir.appendingPathComponent("src").path, ISO8601.now()])
            for (id, name, rank) in [(topID, "OLD_0001.dng", 0), (memberID, "OLD_0002.dng", 1)] {
                try db.execute(sql: """
                    INSERT INTO assets(id, source_root_id, rel_path, filename, ext, kind, size,
                                       mtime, content_hash, imported_at, stack_id, stack_rank)
                    VALUES(?, ?, ?, ?, 'dng', 'raw', 9, 0, ?, ?, ?, ?)
                    """, arguments: [id, rootID, name, name, UUID().uuidString, ISO8601.now(),
                                     stackID, rank])
            }
        }
        try queue.close()

        let opened = try Catalog.open(at: v7Package)
        XCTAssertEqual(opened.schemaVersionApplied, Schema.version)
        let rows = try opened.dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, stack_id, stack_rank, stack_kind FROM assets ORDER BY stack_rank
                """)
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map { $0["id"] as String }, [topID, memberID], "成员与顺序不变")
        XCTAssertEqual(rows.map { $0["stack_id"] as String }, [stackID, stackID], "堆叠不变")
        XCTAssertEqual(rows.map { $0["stack_kind"] as String }, ["plain", "plain"],
                       "已有堆叠一律 plain（不猜历史数据）")
        let summary = try XCTUnwrap(try opened.stackSummary(stackID: stackID))
        XCTAssertEqual(summary.topID, topID)
        XCTAssertEqual(summary.kind, .plain)
        print("② v7 rows \(rows.count) kinds \(rows.map { $0["stack_kind"] as String })")
    }

    // MARK: - B ③④⑤⑥ linkage

    private func makeDenoisePair() throws -> (original: Asset, product: Asset, stack: StackSummary) {
        let original = try seed("L1030552.dng")
        let product = try seed("L1030552-denoised.dng", minute: 1)
        // A real original has been edited before the denoise run (that is what the product
        // inherits); give it one row so "history grows by exactly one" is about the linkage, not
        // about `appendDevelop` seeding a baseline.
        try write(try catalog.develop(forAsset: original.id), to: original.id,
                  at: Date(timeIntervalSince1970: 1_600_000_000))
        let stack = try XCTUnwrap(try catalog.makeStack(resultAssetID: product.id,
                                                        participantIDs: [original.id]))
        return (original, product, stack)
    }

    func testEditingTheProductWritesTheSameBytesToTheOriginal() throws {
        let pair = try makeDenoisePair()
        XCTAssertEqual(pair.stack.kind, .denoise)

        let beforeOriginal = try historyCount(pair.original.id)
        let doc = try edited(pair.product.id, exposure: 1.0)
        try catalog.appendDevelop(doc, label: "调整曝光", forAsset: pair.product.id)
        let linked = try catalog.propagateDenoiseEdit(doc, fromAsset: pair.product.id)

        XCTAssertNotNil(linked)
        XCTAssertEqual(try bytes(pair.original.id), try bytes(pair.product.id),
                       "③ 两边的 develop_json 逐字节相同")
        XCTAssertEqual(try historyCount(pair.original.id), beforeOriginal + 1, "③ 原图历史多 1 行")
        let linkLabels = try historyLabels(pair.original.id)
        XCTAssertTrue(linkLabels.contains { $0.contains("降噪联动") },
                      "③ label 含「降噪联动」：\(linkLabels)")
        let originalBytes = try bytes(pair.original.id)
        let originalLabels = try historyLabels(pair.original.id)
        print("③ bytes \(originalBytes) labels \(originalLabels)")
    }

    func testEditingTheOriginalWritesTheSameBytesToTheProduct() throws {
        let pair = try makeDenoisePair()
        let doc = try edited(pair.original.id, exposure: 2.5)
        try catalog.appendDevelop(doc, label: "调整曝光", forAsset: pair.original.id)
        XCTAssertNotNil(try catalog.propagateDenoiseEdit(doc, fromAsset: pair.original.id))

        XCTAssertEqual(try bytes(pair.product.id), try bytes(pair.original.id),
                       "④ 反方向同样逐字节相同")
        XCTAssertTrue(try historyLabels(pair.product.id).contains { $0.contains("降噪联动") })
        print("④ bytes \(try bytes(pair.product.id))")
    }

    func testWritingTheSameDocumentTwiceAddsOneRowOnly() throws {
        let pair = try makeDenoisePair()
        let doc = try edited(pair.product.id, exposure: 3.0)
        try catalog.appendDevelop(doc, label: "调整曝光", forAsset: pair.product.id)

        XCTAssertNotNil(try catalog.propagateDenoiseEdit(doc, fromAsset: pair.product.id))
        let afterFirst = try historyCount(pair.original.id)
        XCTAssertNil(try catalog.propagateDenoiseEdit(doc, fromAsset: pair.product.id),
                     "⑤ 第二次是 no-op")
        XCTAssertEqual(try historyCount(pair.original.id), afterFirst, "⑤ 第二次不加历史行")
        print("⑤ original history \(afterFirst) after second \(try historyCount(pair.original.id))")
    }

    func testPlainStackNeverPropagates() throws {
        let a = try seed("A.dng")
        let b = try seed("B.dng", minute: 1)
        let stack = try XCTUnwrap(try catalog.makeStack(assetIDs: [a.id, b.id]))
        XCTAssertEqual(stack.kind, .plain)
        let before = try bytes(b.id)

        let doc = try edited(a.id, exposure: 1.75)
        try catalog.appendDevelop(doc, label: "调整曝光", forAsset: a.id)
        XCTAssertNil(try catalog.propagateDenoiseEdit(doc, fromAsset: a.id),
                     "⑥ plain 堆叠没有联动")
        XCTAssertEqual(try bytes(b.id), before, "⑥ 另一张一字节不动")
        print("⑥ plain b bytes unchanged=\(try bytes(b.id) == before)")
    }

    // MARK: - D ⑩⑪⑫ ungroup / restack

    func testUngroupLeavesTwoPlainFilesAndNoKind() throws {
        let pair = try makeDenoisePair()
        _ = try catalog.ungroup(assetIDs: [pair.product.id])

        for asset in [pair.original, pair.product] {
            let row = try catalog.asset(id: asset.id)
            XCTAssertNil(row?.stackId, "⑩ 取消后是普通文件")
            XCTAssertNil(try catalog.stackKind(ofAsset: asset.id), "⑩ kind 记录不存在")
            XCTAssertEqual(try rawKind(asset.id), "plain", "⑩ 列重置为 plain")
        }
        XCTAssertNil(try catalog.denoiseSibling(ofAsset: pair.original.id))
        print("⑩ ungrouped both, stackKind=\(String(describing: try catalog.stackKind(ofAsset: pair.product.id)))")
    }

    func testRestackAlignsToTheLaterEdit() throws {
        let original = try seed("L1030552.dng")
        let product = try seed("L1030552-denoised.dng", minute: 1)
        let older = try edited(original.id, exposure: 0.5)
        let newer = try edited(product.id, exposure: 1.5)
        try write(older, to: original.id, at: Date(timeIntervalSince1970: 1_700_000_000))
        try write(newer, to: product.id, at: Date(timeIntervalSince1970: 1_700_000_100))

        let stack = try XCTUnwrap(try catalog.makeStack(assetIDs: [product.id, original.id]))
        XCTAssertEqual(stack.kind, .denoise, "⑪ 重堆识别为 denoise")
        XCTAssertEqual(try bytes(original.id), try bytes(product.id),
                       "⑪ 两边 == 晚编辑那份")
        XCTAssertEqual(try bytes(product.id), try Catalog.encode(newer))
        let alignLabels = try historyLabels(original.id)
        XCTAssertTrue(alignLabels.contains { $0.contains("重堆对齐") },
                      "⑪ label 说明取自哪张：\(alignLabels)")
        let alignedBytes = try bytes(original.id)
        let alignedLabels = try historyLabels(original.id)
        print("⑪ aligned bytes \(alignedBytes) labels \(alignedLabels)")
    }

    func testRestackTiePrefersTheProduct() throws {
        let original = try seed("L1030552.dng")
        let product = try seed("L1030552-denoised.dng", minute: 1)
        let fromOriginal = try edited(original.id, exposure: 0.25)
        let fromProduct = try edited(product.id, exposure: 3.25)
        let same = Date(timeIntervalSince1970: 1_700_000_500)
        try write(fromOriginal, to: original.id, at: same)
        try write(fromProduct, to: product.id, at: same)

        let stack = try XCTUnwrap(try catalog.makeStack(assetIDs: [original.id, product.id]))
        XCTAssertEqual(stack.kind, .denoise)
        XCTAssertEqual(try bytes(original.id), try bytes(product.id))
        XCTAssertEqual(try bytes(product.id), try Catalog.encode(fromProduct),
                       "⑫ 同一时刻以产物为准")
        print("⑫ tie winner product bytes \(try bytes(product.id))")
    }
}
