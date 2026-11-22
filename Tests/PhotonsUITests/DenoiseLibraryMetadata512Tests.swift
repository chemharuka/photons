import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsCatalog
@testable import PhotonsUI

/// 512 — 「对 1 星照片降噪后，新的 dng 没有继承所有的 tag，还是 0 星」.
///
/// The ticket's acceptance table, measured end to end through the shipped entry points
/// (`session.denoiseSelection()` / `denoiseBatchSelection(engine:)`), a **real** library on disk and
/// real catalog reads. Everything about pixels is a stand-in (§390/§395 precedent: the "denoise" is a
/// byte copy), because every assertion here is about the **library metadata** the product row ends up
/// with — rating / flag / colour label / keyword links / capture time.
///
///   ① one source ★1 + pick + red + 2 keywords ⇒ the product's four library fields are equal **one by
///      one** (all five values printed: the four attributes + the count of keyword links);
///   ② a ★0 / no-flag / no-colour / no-keyword source mints **no** noise in the product, and
///      `metadataRevision` moves exactly **once** for one denoise;
///   ③ a ★1 filter finds the product (facet + query read) and the stack row (top = product) shows ★1;
///   ④ a batch of ★5 / ★3 / ★0 gives **three** products each carrying **its own** source's metadata;
///   ⑤ capture time: the product's equals the source's, with both raw values printed — and the value
///      the product was *imported* with, read from the file itself, proves whether the writer kept the
///      EXIF date or whether the copy is what makes them equal;
///   ⑥ an injected, guaranteed-failing metadata copy leaves the denoise **successful**:
///      `lastDenoiseError == nil`, `lastDenoiseMetadataInheritError != nil`, the report present, the
///      file on disk, the product stacked.
///
/// Plus the two "not this" rules the ticket spells out: re-stacking must not overwrite a rating the
/// user set afterwards (§4), and `copyLibraryMetadata` must not touch `develop_json` / history (§2.1).
@MainActor
final class DenoiseLibraryMetadata512Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var libraryURL: URL!
    private var catalog: Catalog!
    private var session: CatalogSession!
    private var root: SourceRoot!

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise-meta512-\(UUID().uuidString)", isDirectory: true)
        src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        libraryURL = workDir.appendingPathComponent("S512.\(LibraryLayout.packageExtension)",
                                                    isDirectory: true)
        catalog = try Catalog.create(at: libraryURL)
        root = try catalog.ensureRoot(for: src, mode: .reference)
    }

    override func tearDownWithError() throws {
        session = nil
        catalog = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters.removeValue(forKey: key) }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    /// One row + its file, exactly what `ImportService` would have written for a scanned photo —
    /// except the content hash (a UUID, like the 474 fixture), so a byte-copied product never looks
    /// like a duplicate of its own source.
    @discardableResult
    private func addAsset(_ name: String,
                          salt: String = "",
                          rating: Int = 0,
                          flag: String? = nil,
                          colorLabel: String? = nil,
                          keywords: [String] = [],
                          captureTime: String? = "2026-05-01T10:00:00Z",
                          captureLocalDate: String? = "2026-05-01",
                          captureTimeSource: String? = "exif") throws -> Asset {
        var data = try Data(contentsOf: Self.fixtureURL)
        data.append(contentsOf: Array(salt.utf8))
        try data.write(to: src.appendingPathComponent(name))
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                          kind: .raw, size: data.count, mtime: 0,
                          contentHash: UUID().uuidString, width: 1024, height: 1024,
                          captureTime: captureTime, captureLocalDate: captureLocalDate,
                          captureTimeSource: captureTimeSource,
                          rating: rating, flag: flag, colorLabel: colorLabel,
                          cameraMake: "LEICA", cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try AssetHistory(assetId: asset.id, seq: 1, developJson: asset.developJson,
                             label: "import", createdAt: ISO8601.now()).insert(db)
        }
        for keyword in keywords { try addKeyword(keyword, to: asset.id) }
        return asset
    }

    private func addKeyword(_ name: String, to assetID: String) throws {
        try catalog.dbQueue.write { db in
            let id: String
            if let existing = try String.fetchOne(db, sql: "SELECT id FROM keywords WHERE name = ?",
                                                  arguments: [name]) {
                id = existing
            } else {
                id = UUID().uuidString
                try db.execute(sql: "INSERT INTO keywords(id, name, parent_id) VALUES(?, ?, NULL)",
                               arguments: [id, name])
            }
            try db.execute(sql: "INSERT OR IGNORE INTO photo_keywords(asset_id, keyword_id) VALUES(?, ?)",
                           arguments: [assetID, id])
        }
    }

    private func openSession() throws {
        let store = MemoryStore()
        let s = CatalogSession(filterStore: store, sortPreferenceStore: store,
                               remembersRecentLibrary: false)
        try s.open(libraryURL)
        s.setSortOrder(.oldestFirst)
        try installFakeTool(on: s)
        session = s
    }

    /// The §390 stand-in: `capabilities` answers `image-dng`, the run copies the file through.
    @discardableResult
    private func installFakeTool(on session: CatalogSession) throws -> URL {
        let tool = workDir.appendingPathComponent("fake-ansel-denoise-swift")
        let script = """
        #!/bin/sh
        if [ "$1" = "capabilities" ]; then
          echo '{"tool":{"name":"ansel-denoise-swift","protocol":2},"gpu":"Fake GPU","features":["image","image-dng","gpu"]}'
          exit 0
        fi
        input="$3"
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--out" ]; then out="$2"; shift 2; continue; fi
          shift
        done
        if [ -z "$out" ] || [ ! -f "$input" ]; then exit 3; fi
        size=$(wc -c < "$input" | tr -d ' ')
        magic=$(head -c 4 "$input" | od -An -tx1 | tr -d ' \\n')
        if [ "$size" -lt 64 ] || [ "$magic" != "49492a00" ]; then
          echo "error: 解码 RAW 失败：文件只有 $size 字节，不是完整的 DNG" >&2
          exit 2
        fi
        cp "$input" "$out" || exit 4
        echo '{"width":1024,"height":1024,"cfa":"rggb","mosaicCfa":"rggb","pieces":1,"columns":1,"rows":1,"seams":0,"seconds":0.05,"readSeconds":0.0,"inferenceSeconds":0.05,"writeSeconds":0.0,"backend":"fake","outputBytes":1}'
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let model = workDir.appendingPathComponent(AnselDenoiseVariant.quarter.modelFileName)
        try Data(repeating: 0, count: 64).write(to: model)
        var location = AnselDenoiseLocation(executableURL: tool, modelURL: model)
        location.variant = .quarter
        session.denoiseLocation = location
        return tool
    }

    // MARK: - driving

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 120,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.01)
        }
        XCTFail("\(what)：\(timeout) s 内没有成立")
        return false
    }

    @discardableResult
    private func runDenoiseAndWait(timeout: TimeInterval = 120,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) throws -> String {
        let before = session.denoiseCompletionCount
        session.denoiseSelection()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.denoiseCompletionCount > before { break }
            pump(0.01)
        }
        XCTAssertGreaterThan(session.denoiseCompletionCount, before,
                             "降噪没在 \(timeout) s 内结束", file: file, line: line)
        let report = try XCTUnwrap(session.lastDenoiseReport,
                                   "降噪失败：\(session.lastDenoiseError ?? "nil")",
                                   file: file, line: line)
        return report.assetID
    }

    @discardableResult
    private func runBatchAndWait(_ ids: [String], timeout: TimeInterval = 240) throws -> [String] {
        session.setSelection(Set(ids), anchor: ids[0])
        let before = session.denoiseCompletionCount
        session.denoiseBatchSelection(engine: .ansel)
        waitUntil("批量降噪没有结束", timeout: timeout) {
            self.session.denoiseCompletionCount >= before + ids.count
        }
        return ids
    }

    // MARK: - reading

    private struct LibraryFields: Equatable, CustomStringConvertible {
        var rating: Int
        var flag: String?
        var colorLabel: String?
        var keywords: [String]
        var captureTime: String?
        var captureLocalDate: String?
        var captureTimeSource: String?

        var description: String {
            "★\(rating) flag=\(flag ?? "nil") color=\(colorLabel ?? "nil") "
                + "keywords=\(keywords) capture=\(captureTime ?? "nil")"
                + "/\(captureLocalDate ?? "nil")/\(captureTimeSource ?? "nil")"
        }
    }

    private func fields(_ id: String) throws -> LibraryFields {
        let row = try catalog.dbQueue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT rating, flag, color_label, capture_time, capture_local_date, capture_time_source
                FROM assets WHERE id = ?
                """, arguments: [id])
        }
        let r = try XCTUnwrap(row, "库里没有这一行：\(id)")
        return LibraryFields(rating: r["rating"], flag: r["flag"], colorLabel: r["color_label"],
                             keywords: try catalog.keywords(assetId: id),
                             captureTime: r["capture_time"], captureLocalDate: r["capture_local_date"],
                             captureTimeSource: r["capture_time_source"])
    }

    private func stack(of id: String) throws -> (id: String, topID: String, count: Int) {
        let stackID = try XCTUnwrap(try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT stack_id FROM assets WHERE id = ?", arguments: [id])
        }, "\(id) 不在任何堆叠里")
        return try catalog.dbQueue.read { db in
            let top = try XCTUnwrap(try String.fetchOne(
                db, sql: "SELECT id FROM assets WHERE stack_id = ? AND stack_rank = 0",
                arguments: [stackID]), "堆叠 \(stackID) 没有置顶")
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets WHERE stack_id = ?",
                                         arguments: [stackID]) ?? 0
            return (stackID, top, count)
        }
    }

    private func product(of sourceID: String) throws -> String {
        try stack(of: sourceID).topID
    }

    // MARK: - ① five values, one by one

    func testSingleProductInheritsRatingFlagColourAndKeywords() throws {
        let source = try addAsset("IMG_0001.dng", salt: "one", rating: 1, flag: "pick",
                                  colorLabel: "red", keywords: ["天空", "夜景"])
        try openSession()
        session.selectOnly(source.id)
        let productID = try runDenoiseAndWait()

        let a = try fields(source.id)
        let b = try fields(productID)
        print("① 原图     \(a)")
        print("① 降噪产物 \(b)")
        print("① summary  \(session.lastDenoiseMetadataInheritSummary ?? "nil")")

        XCTAssertNil(session.lastDenoiseError, "① 降噪不许失败")
        XCTAssertNil(session.lastDenoiseMetadataInheritError, "① 库属性继承不许失败")
        XCTAssertEqual(b.rating, a.rating, "① 星级")
        XCTAssertEqual(b.flag, a.flag, "① 旗标")
        XCTAssertEqual(b.colorLabel, a.colorLabel, "① 色标")
        XCTAssertEqual(b.keywords.sorted(), a.keywords.sorted(), "① 关键词：双向相等")
        XCTAssertEqual(b.rating, 1)
        XCTAssertEqual(b.flag, "pick")
        XCTAssertEqual(b.colorLabel, "red")
        XCTAssertEqual(b.keywords.count, 2)
        // The report line reads the same four values back out of the library.
        let summary = try XCTUnwrap(session.lastDenoiseMetadataInheritSummary)
        XCTAssertTrue(summary.contains("★1"), summary)
        XCTAssertTrue(summary.contains("pick"), summary)
        XCTAssertTrue(summary.contains("red"), summary)
        XCTAssertTrue(summary.contains("关键词 2 个"), summary)
        // §4 — the edit inheritance (395) still happens: exactly one history row of its own.
        let labels = try catalog.dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT label FROM asset_history WHERE asset_id = ? ORDER BY seq",
                                arguments: [productID])
        }
        XCTAssertEqual(labels, ["import", "模型降噪：继承编辑"], "① 编辑继承仍是 395 的那一条")
    }

    // MARK: - ② zero star mints no noise, one revision bump

    func testZeroStarSourceMintsNoNoiseAndBumpsMetadataRevisionOnce() throws {
        let source = try addAsset("IMG_0002.dng", salt: "two",
                                  captureTime: nil, captureLocalDate: nil, captureTimeSource: "none")
        try openSession()
        session.selectOnly(source.id)
        let before = session.metadataRevision
        let productID = try runDenoiseAndWait()

        let a = try fields(source.id)
        let b = try fields(productID)
        let after = session.metadataRevision
        print("② 原图 \(a) / 产物 \(b) / metadataRevision \(before) → \(after)")

        XCTAssertEqual(b.rating, 0, "② 0 星不许被铸成别的值")
        XCTAssertNil(b.flag, "② 无旗标不许铸出旗标")
        XCTAssertNil(b.colorLabel, "② 无色标不许铸出色标")
        XCTAssertEqual(b.keywords, [], "② 无关键词不许铸出关键词")
        XCTAssertEqual(a.rating, b.rating)
        XCTAssertNil(a.flag); XCTAssertNil(b.flag)
        XCTAssertNil(a.colorLabel); XCTAssertNil(b.colorLabel)
        XCTAssertEqual(a.keywords, b.keywords)
        // §2.2.3 — the stack step's single bump is the only one; metadata must not add a second.
        XCTAssertEqual(after - before, 1, "② 一次降噪只 bump 一次 metadataRevision")
    }

    // MARK: - ③ filter + stack badge

    func testRatingOneFilterFindsTheProductAndTheStackRowShowsOneStar() throws {
        let source = try addAsset("IMG_0003.dng", salt: "three", rating: 1, flag: "pick",
                                  colorLabel: "red", keywords: ["天空"])
        try openSession()
        session.selectOnly(source.id)
        let productID = try runDenoiseAndWait()

        let filter = AssetFilter(criteria: [FilterCriterion(dimension: .rating, value: "1")])
        let hits = try catalog.assets(filter).map(\.id)
        let facets = catalog.facetValues(.rating, filter: filter)
        let stack = try stack(of: productID)
        print("③ ★1 筛选命中=\(hits) facet(★1 之下)=\(facets) 堆叠=\(stack)")
        print("③ 置顶行 \(try fields(productID))")

        // The stack projection keeps exactly one row per stack — its 置顶, which is the product. So
        // "the source is in the result" is *wrong* by design: ③ asks the product to be visible.
        XCTAssertEqual(hits, [productID], "③ 按 ★1 筛选，结果里就是这一叠的置顶 = 产物")
        XCTAssertTrue(facets.contains("1"), "③ facet 里有 ★1")
        XCTAssertEqual(stack.topID, productID, "③ 堆叠置顶 = 产物")
        XCTAssertEqual(stack.count, 2, "③ 产物 + 原图")
        let topRow = try catalog.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT rating, stack_rank FROM assets WHERE id = ?",
                             arguments: [productID])
        }
        XCTAssertEqual(topRow?["rating"] as Int?, 1, "③ 堆叠行显示 ★1")
        XCTAssertEqual(topRow?["stack_rank"] as Int?, 0)
    }

    // MARK: - ④ batch: each item inherits from its own source

    func testBatchOfThreeEachProductInheritsItsOwnSource() throws {
        let five = try addAsset("IMG_0010.dng", salt: "b5", rating: 5, flag: "pick",
                                colorLabel: "green", keywords: ["甲", "乙"])
        let three = try addAsset("IMG_0011.dng", salt: "b3", rating: 3, flag: "reject",
                                 colorLabel: "blue", keywords: ["丙"])
        let zero = try addAsset("IMG_0012.dng", salt: "b0")
        try openSession()
        try runBatchAndWait([five.id, three.id, zero.id])

        let pairs: [(Asset, String)] = [(five, "★5"), (three, "★3"), (zero, "★0")]
        for (source, label) in pairs {
            let b = try fields(try product(of: source.id))
            print("④ \(label) 原图 → 产物 \(b)")
        }
        let a5 = try fields(five.id), b5 = try fields(try product(of: five.id))
        let a3 = try fields(three.id), b3 = try fields(try product(of: three.id))
        let a0 = try fields(zero.id), b0 = try fields(try product(of: zero.id))

        XCTAssertEqual(b5.rating, 5); XCTAssertEqual(b5.flag, "pick")
        XCTAssertEqual(b5.colorLabel, "green"); XCTAssertEqual(b5.keywords.sorted(), ["乙", "甲"].sorted())
        XCTAssertEqual(b3.rating, 3); XCTAssertEqual(b3.flag, "reject")
        XCTAssertEqual(b3.colorLabel, "blue"); XCTAssertEqual(b3.keywords, ["丙"])
        XCTAssertEqual(b0.rating, 0); XCTAssertNil(b0.flag); XCTAssertNil(b0.colorLabel)
        XCTAssertEqual(b0.keywords, [])
        XCTAssertEqual(b5.rating, a5.rating); XCTAssertEqual(b3.rating, a3.rating)
        XCTAssertEqual(b0.rating, a0.rating)
        XCTAssertNil(session.lastDenoiseError, "④ 批量整单成功")
        XCTAssertNil(session.lastDenoiseMetadataInheritError, "④ 每一项的库属性都搬成功了")
    }

    // MARK: - ⑤ capture time, both raw values

    func testCaptureTimeMatchesTheSourceAndMeasureWhatTheWriterKept() throws {
        let source = try addAsset("IMG_0020.dng", salt: "time", rating: 2,
                                  captureTime: "2026-05-01T10:00:00Z",
                                  captureLocalDate: "2026-05-01", captureTimeSource: "exif")
        try openSession()
        session.selectOnly(source.id)
        let productID = try runDenoiseAndWait()

        let a = try fields(source.id)
        let b = try fields(productID)
        let report = try XCTUnwrap(session.lastDenoiseReport)
        // What the file **itself** says: the value `ImportService` wrote into the product before the
        // copy (and the only thing a writer that drops dates would leave behind).
        let onDisk = try MetadataReader.read(report.output)
        print("⑤ 原图 capture_time=\(a.captureTime ?? "nil") / local=\(a.captureLocalDate ?? "nil") "
              + "/ source=\(a.captureTimeSource ?? "nil")")
        print("⑤ 产物 capture_time=\(b.captureTime ?? "nil") / local=\(b.captureLocalDate ?? "nil") "
              + "/ source=\(b.captureTimeSource ?? "nil")")
        print("⑤ 产物文件自己的 EXIF：capture_time=\(onDisk.captureTime ?? "nil") "
              + "/ local=\(onDisk.captureLocalDate ?? "nil") / source=\(onDisk.captureTimeSource)")

        XCTAssertEqual(b.captureTime, a.captureTime, "⑤ 拍摄时间必须与原图相同")
        XCTAssertEqual(b.captureLocalDate, a.captureLocalDate)
        XCTAssertEqual(b.captureTimeSource, a.captureTimeSource)
        XCTAssertEqual(a.captureTime, "2026-05-01T10:00:00Z")
    }

    // MARK: - ⑥ failure isolation

    func testFailingMetadataCopyLeavesTheDenoiseSuccessful() throws {
        let source = try addAsset("IMG_0030.dng", salt: "fail", rating: 1, flag: "pick",
                                  colorLabel: "red", keywords: ["天空", "夜景"])
        try openSession()
        // A guaranteed failure through the same seam the production call uses (§2.2.2): the
        // destination id does not exist.
        session.denoiseMetadataInheritBody = { _, _, _ in
            throw LibraryMetadataError.noSuchAsset("injected-by-512-test")
        }
        session.selectOnly(source.id)
        let productID = try runDenoiseAndWait()

        let report = try XCTUnwrap(session.lastDenoiseReport)
        let stack = try stack(of: productID)
        print("⑥ lastDenoiseError=\(session.lastDenoiseError ?? "nil") "
              + "lastDenoiseMetadataInheritError=\(session.lastDenoiseMetadataInheritError ?? "nil") "
              + "file=\(FileManager.default.fileExists(atPath: report.output.path)) stack=\(stack)")

        XCTAssertNil(session.lastDenoiseError, "⑥ 元数据失败不许写成整单失败")
        let metadataError = try XCTUnwrap(session.lastDenoiseMetadataInheritError,
                                          "⑥ 元数据的失败要单独记一行")
        XCTAssertTrue(metadataError.contains("injected-by-512-test"), metadataError)
        XCTAssertNil(session.lastDenoiseInheritError, "⑥ 编辑继承仍然是成功的（两条附注互不影响）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.output.path), "⑥ 文件在盘")
        XCTAssertEqual(stack.topID, productID, "⑥ 已堆叠")
        XCTAssertEqual(stack.count, 2)
        // And the product is what the import made it — no half-copied metadata.
        let b = try fields(productID)
        XCTAssertEqual(b.rating, 0)
        XCTAssertNil(b.flag)
        XCTAssertNil(b.colorLabel)
    }

    // MARK: - §4 — a re-stack never overwrites what the user set afterwards

    func testRestackingDoesNotOverwriteARatingTheUserSetOnTheProduct() throws {
        let source = try addAsset("IMG_0040.dng", salt: "restack", rating: 1,
                                  keywords: ["天空"])
        try openSession()
        session.selectOnly(source.id)
        let productID = try runDenoiseAndWait()

        try catalog.setRating(4, forAsset: productID)
        try catalog.setColorLabel("purple", forAsset: productID)
        try catalog.setFlag("reject", forAssets: [productID])
        try catalog.makeStack(resultAssetID: productID, participantIDs: [source.id])

        let b = try fields(productID)
        print("§4 重堆叠之后产物 \(b)")
        XCTAssertEqual(b.rating, 4, "§4 重堆叠不许覆写用户后来改的星级")
        XCTAssertEqual(b.colorLabel, "purple")
        XCTAssertEqual(b.flag, "reject")
        XCTAssertEqual(b.keywords, ["天空"], "§4 重堆叠不新增也不删关键词")
    }

    // MARK: - §2.1 — the catalog action on its own

    func testCopyLibraryMetadataIsOneTransactionAndLeavesTheEditAlone() throws {
        let source = try addAsset("IMG_0050.dng", salt: "api", rating: 3, flag: "pick",
                                  colorLabel: "yellow", keywords: ["甲", "乙"])
        let destination = try addAsset("IMG_0051.dng", salt: "api2")
        let developBefore = try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?",
                                arguments: [destination.id]) ?? ""
        }
        let historyBefore = try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_history WHERE asset_id = ?",
                             arguments: [destination.id]) ?? -1
        }

        let written = try catalog.copyLibraryMetadata(fromAsset: source.id, toAsset: destination.id)
        print("§2.1 copyLibraryMetadata 返回 \(written)")
        XCTAssertEqual(written, 5, "§2.1 3 项 + 2 个关键词 = 5")
        XCTAssertEqual(try fields(destination.id).rating, 3)
        XCTAssertEqual(try fields(destination.id).flag, "pick")
        XCTAssertEqual(try fields(destination.id).colorLabel, "yellow")
        XCTAssertEqual(try fields(destination.id).keywords.sorted(), ["乙", "甲"].sorted())
        // Idempotent: a second call inserts no keyword twice and still answers 3 + 0.
        XCTAssertEqual(try catalog.copyLibraryMetadata(fromAsset: source.id, toAsset: destination.id), 3)
        XCTAssertEqual(try fields(destination.id).keywords.count, 2)
        // Not an edit: develop_json and history are untouched.
        let developAfter = try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?",
                                arguments: [destination.id]) ?? ""
        }
        let historyAfter = try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM asset_history WHERE asset_id = ?",
                             arguments: [destination.id]) ?? -1
        }
        XCTAssertEqual(developAfter, developBefore, "§2.1 不写 develop_json")
        XCTAssertEqual(historyAfter, historyBefore, "§2.1 不写 asset_history")
        // Missing ids throw (§2.1), and they throw before writing anything.
        XCTAssertThrowsError(try catalog.copyLibraryMetadata(fromAsset: "nope", toAsset: destination.id))
        XCTAssertThrowsError(try catalog.copyLibraryMetadata(fromAsset: source.id, toAsset: "nope"))
        XCTAssertEqual(try fields(destination.id).rating, 3, "§2.1 抛错不改已有行")
    }

    /// ⑤b — the "补" path is real, not a no-op: an imported product whose date came from the file's
    /// mtime gets the source's EXIF date, and a source **without** a date leaves the product's alone.
    func testCaptureTimeIsSupplementedOnlyWhenTheSourceHasOne() throws {
        let source = try addAsset("IMG_0060.dng", salt: "fill", captureTime: "2026-05-01T10:00:00Z",
                                  captureLocalDate: "2026-05-01", captureTimeSource: "exif")
        let blank = try addAsset("IMG_0061.dng", salt: "fill2", captureTime: nil,
                                 captureLocalDate: nil, captureTimeSource: "none")
        let product = try addAsset("IMG_0062.dng", salt: "fill3",
                                   captureTime: "2026-05-02T09:00:00Z",
                                   captureLocalDate: "2026-05-02", captureTimeSource: "file")

        try catalog.copyLibraryMetadata(fromAsset: source.id, toAsset: product.id)
        XCTAssertEqual(try fields(product.id).captureTime, "2026-05-01T10:00:00Z")
        XCTAssertEqual(try fields(product.id).captureTimeSource, "exif")

        let untouched = try addAsset("IMG_0063.dng", salt: "fill4",
                                     captureTime: "2026-05-02T09:00:00Z",
                                     captureLocalDate: "2026-05-02", captureTimeSource: "file")
        try catalog.copyLibraryMetadata(fromAsset: blank.id, toAsset: untouched.id)
        print("⑤b 原图无日期时产物保持 \(try fields(untouched.id).captureTime ?? "nil")")
        XCTAssertEqual(try fields(untouched.id).captureTime, "2026-05-02T09:00:00Z",
                       "⑤b 原图没有拍摄时间时，不许把产物那三列改成 NULL")
    }
}
