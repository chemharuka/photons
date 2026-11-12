import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsCatalog
@testable import PhotonsUI

/// §395 — 「新功能：模型降噪后，新产生的 dng 要复制先前的所有编辑内容」.
///
/// The ticket's acceptance table, measured end to end through the shipped entry point
/// (`session.denoiseSelection()`), a **real** library on disk and the real catalog reads:
///
///   ① the product's stored document carries the source's non-default edits (exposure + contrast
///      printed from both sides);
///   ② **every key** of the source's `developJson` exists in the product's with an equal value
///      (recursive containment — extra keys in the product are allowed, missing/unequal are not).
///      `masks` is the one documented exception and ③ measures it on its own terms;
///   ③ masks are **appended**, not substituted: one source mask ⇒ one product mask (same name,
///      feether, geometry; fresh id, because the id is the atlas-cache identity), and a second paste
///      leaves the product's first mask untouched;
///   ④ exactly **one** history row called 「模型降噪：继承编辑」, and one ⌘Z lands on
///      「降噪后但还没有继承编辑」 — the state the product was imported in;
///   ⑤ an inheritance failure does **not** sink the denoise: file on disk, row in the library, stack
///      formed, `lastDenoiseError == nil`, `lastDenoiseInheritError != nil`;
///   ⑥ the product is still editable afterwards through the normal `applyEdit`/`commitEdit` path,
///      and ⌘Z takes back the user's own tweak — not the inheritance.
///
/// The denoise itself is the same stand-in tool §386/§390 introduced (`capabilities` answers
/// `image-dng`, the "denoise" is a byte copy), because every assertion here is about the **library
/// document** the product row ends up with, not about pixels.
@MainActor
final class DenoiseInheritEdits395Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var catalog: Catalog!
    private var session: CatalogSession!
    private var root: SourceRoot!

    /// The label the production code writes. One string, asserted in three places, so a rename in
    /// `CatalogSession.runDenoise` cannot pass silently.
    private static let inheritLabel = "模型降噪：继承编辑"

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise-inherit395-\(UUID().uuidString)", isDirectory: true)
        src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
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

    /// The source document the ticket names, plus every *other* section the clipboard can carry —
    /// so ② is a real full-document comparison and not a two-field coincidence.
    ///
    /// Deliberately **no mask** here (③ has its own fixture) and deliberately nothing the clipboard
    /// does not carry at all (`detailSettings`, `healSpots`, `color.point`, `guideLines`) — the last
    /// test in this file measures that boundary instead of assuming it away.
    private func richDocument() -> EditModel {
        var d = EditModel.neutral
        d.light.exposure = 1.5
        d.light.contrast = 20
        d.light.highlights = -30
        d.light.shadows = 12
        d.light.whites = 5
        d.light.blacks = -7
        d.light.temperature = 5500
        d.light.tint = 10
        d.light.blackOffset = 0.002
        d.light.highlightRecovery = 15
        d.curve.white = [CurvePoint(0, 0), CurvePoint(1, 1.12), CurvePoint(2, 2)]
        d.curve.red = [CurvePoint(0, 0), CurvePoint(2, 2.05)]
        d.color.vibrance = 23
        d.color.saturation = -11
        d.color.bands[2].hue = 15
        d.color.bands[4].luminance = -9
        d.color.global.luminance = 5
        d.colorGrading.shadows = GradeWheel(hue: 10, saturation: 20, lightness: 5)
        d.calibration.redHue = 12
        d.calibration.blueSat = -8
        d.optics.caRed = 0.0012
        d.effects.vignetteAmount = -20
        d.effects.vignetteMidpoint = 40
        d.effects.grain = 15
        d.effects.texture = 10
        d.effects.clarity = 8
        d.effects.dehaze = 12
        d.effects.nonBayerLuminanceNR = 20
        d.effects.nonBayerColorNR = 10
        d.sharpen.amount = 70
        d.sharpen.radius = 1.2
        d.sharpen.detail = 30
        d.sharpen.masking = 15
        d.geometry.crop = NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        d.geometry.rotationDegrees = 2.0
        d.geometry.perspectiveVertical = 5
        return d
    }

    private func maskedDocument() -> EditModel {
        var d = EditModel.neutral
        d.light.exposure = 1.5
        d.color.saturation = 18
        d.masks = [Mask(id: "m-src-sky", name: "天空", feather: 0.18,
                        components: [MaskComponent(id: "c-src-sky", op: .add, feather: 0.18,
                                                   shape: .radialGradient(
                                                    RadialGradientShape(
                                                        center: NormalizedPoint(0.25, 0.75),
                                                        radius: NormalizedPoint(0.2, 0.2))))])]
        return d
    }

    /// One DNG row over the committed 1024² fixture, carrying `doc` as its stored document **and**
    /// as history seq 1 (`import`), exactly as `ImportService` writes a freshly imported photo.
    @discardableResult
    private func makeSession(doc: EditModel) throws -> Asset {
        let url = workDir.appendingPathComponent("S395.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: url)
        root = try catalog.ensureRoot(for: src, mode: .reference)
        let name = "IMG_0000.dng"
        try FileManager.default.copyItem(at: Self.fixtureURL, to: src.appendingPathComponent(name))
        let blob = try Catalog.encode(doc)
        let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng", kind: .raw,
                          size: 1, mtime: 0, contentHash: UUID().uuidString,
                          width: 1024, height: 1024,
                          captureTime: "2026-05-01T10:00:00Z", captureLocalDate: "2026-05-01",
                          cameraModel: "LEICA SL3", cameraKey: "leica|sl3",
                          developJson: blob)
        try catalog.dbQueue.write { db in
            try asset.insert(db)
            try AssetHistory(assetId: asset.id, seq: 1, developJson: blob,
                             label: "import", createdAt: ISO8601.now()).insert(db)
        }
        let store = MemoryStore()
        let s = CatalogSession(filterStore: store, sortPreferenceStore: store,
                               remembersRecentLibrary: false)
        try s.open(url)
        s.setSortOrder(.newestFirst)
        s.selectOnly(asset.id)
        session = s
        return asset
    }

    /// The §390 stand-in: `capabilities` answers `image-dng`, the run copies the file through.
    @discardableResult
    private func installFakeTool() throws -> URL {
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

    /// Run the denoise and return the product's id. Fails loudly with the session's own reason.
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

    private func stored(_ id: String) throws -> EditModel {
        try catalog.develop(forAsset: id)
    }

    private func row(_ id: String) throws -> (stack: String?, rank: Int, filename: String) {
        try catalog.dbQueue.read { db in
            let r = try Row.fetchOne(db, sql: "SELECT stack_id, stack_rank, filename FROM assets WHERE id = ?",
                                     arguments: [id])
            return (r?["stack_id"] as String?, r?["stack_rank"] as Int? ?? -1,
                    r?["filename"] as String? ?? "")
        }
    }

    private func assetCount() throws -> Int {
        try catalog.dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? -1 }
    }

    private func developJSON(_ id: String) throws -> String {
        try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?", arguments: [id]) ?? ""
        }
    }

    // MARK: - ② the recursive containment comparison

    /// Every key the source document holds, found in the product's with an equal value.
    ///
    /// Numbers are compared with a tolerance (both blobs went through JSON), strings exactly, arrays
    /// element-wise. `skip` names the paths measured elsewhere — `masks`, whose ids are *expected* to
    /// be re-minted by the paste (P1-5).
    private func containmentDiffs(source: Any, product: Any, path: String = "",
                                  skip: Set<String>) -> (diffs: [String], leaves: Int) {
        var diffs: [String] = []
        var leaves = 0
        func walk(_ s: Any, _ p: Any, _ here: String) {
            switch s {
            case let sd as [String: Any]:
                guard let pd = p as? [String: Any] else {
                    diffs.append("\(here): 源是对象，产物不是（\(type(of: p))）")
                    return
                }
                for (key, sv) in sd {
                    let child = here.isEmpty ? key : "\(here).\(key)"
                    if skip.contains(child) { continue }
                    guard let pv = pd[key] else {
                        diffs.append("\(child): 产物缺这个 key")
                        continue
                    }
                    walk(sv, pv, child)
                }
            case let sa as [Any]:
                guard let pa = p as? [Any] else {
                    diffs.append("\(here): 源是数组，产物不是")
                    return
                }
                guard sa.count == pa.count else {
                    diffs.append("\(here): 数组长度 \(sa.count) ≠ \(pa.count)")
                    return
                }
                for (i, sv) in sa.enumerated() { walk(sv, pa[i], "\(here)[\(i)]") }
            case let sn as NSNumber:
                leaves += 1
                guard let pn = p as? NSNumber, !(p is String) else {
                    diffs.append("\(here): 源是数 \(sn)，产物不是数（\(p)）")
                    return
                }
                let a = sn.doubleValue, b = pn.doubleValue
                if a != b && abs(a - b) > 1e-9 * max(1, abs(a)) {
                    diffs.append("\(here): \(a) ≠ \(b)")
                }
            case let ss as String:
                leaves += 1
                guard let ps = p as? String, ps == ss else {
                    diffs.append("\(here): \"\(ss)\" ≠ \"\(String(describing: p))\"")
                    return
                }
            default:
                leaves += 1
                if "\(s)" != "\(p)" { diffs.append("\(here): \(s) ≠ \(p)") }
            }
        }
        walk(source, product, path)
        return (diffs, leaves)
    }

    private func parsed(_ json: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
    }

    private func topLevelKeys(_ json: String) throws -> [String] {
        ((try parsed(json)) as? [String: Any]).map { $0.keys.sorted() } ?? []
    }

    // MARK: - ① 编辑真的过去了 / ② 全部字段

    func testTheProductCarriesEveryEditOfTheSource() throws {
        let source = try makeSession(doc: richDocument())
        try installFakeTool()
        let sourceBefore = try stored(source.id)
        XCTAssertEqual(sourceBefore.light.exposure, 1.5, accuracy: 1e-12, "前提：源图确实有非默认编辑")
        XCTAssertEqual(sourceBefore.light.contrast, 20, accuracy: 1e-12)

        let productID = try runDenoiseAndWait()
        let product = try stored(productID)

        // ── ① 两边数值 ───────────────────────────────────────────────────────────────────────────
        print("① 源图 exposure=\(sourceBefore.light.exposure) contrast=\(sourceBefore.light.contrast) "
              + "| 产物 exposure=\(product.light.exposure) contrast=\(product.light.contrast)")
        XCTAssertEqual(product.light.exposure, sourceBefore.light.exposure, accuracy: 1e-12,
                       "① 曝光必须继承（println 见上）")
        XCTAssertEqual(product.light.contrast, sourceBefore.light.contrast, accuracy: 1e-12,
                       "① 对比度必须继承")

        // ── ② developJson 逐 key ────────────────────────────────────────────────────────────────
        let sourceJSON = try developJSON(source.id)
        let productJSON = try developJSON(productID)
        let compared = containmentDiffs(source: try parsed(sourceJSON),
                                        product: try parsed(productJSON),
                                        skip: ["masks"])
        let diffs = compared.diffs, leaves = compared.leaves
        print("② 顶层 key 源=\(try topLevelKeys(sourceJSON))")
        print("② 顶层 key 产物=\(try topLevelKeys(productJSON))")
        print("② 递归比较了 \(leaves) 个叶子，差异 \(diffs.count) 条：\(diffs)")
        XCTAssertEqual(diffs, [], "② 源图的每个 key 都必须在产物里存在且相等（masks 由 ③ 单独测）")
        XCTAssertGreaterThan(leaves, 60, "② 这一份文档的叶子数必须够多，否则「全部字段」没被真正测到")

        // The product is its own row, in its own file, top of a new stack: the §386 contract is
        // untouched by this ticket.
        let (stack, rank, filename) = try row(productID)
        XCTAssertEqual(filename, "IMG_0000-denoised.dng")
        XCTAssertNotNil(stack)
        XCTAssertEqual(rank, 0, "产物仍是堆叠置顶")
        XCTAssertEqual(session.stacksByTopID[session.lastDenoiseReport?.stackTopID ?? ""]?.count, 2)
    }

    // MARK: - ③ 蒙版是追加，不是替换

    func testMasksAreAppendedNotSubstituted() throws {
        let source = try makeSession(doc: maskedDocument())
        try installFakeTool()
        let productID = try runDenoiseAndWait()

        let sourceDoc = try stored(source.id)
        let productDoc = try stored(productID)
        print("③ 源图蒙版=\(sourceDoc.masks.map { "\($0.id)/\($0.name)" }) "
              + "| 产物蒙版=\(productDoc.masks.map { "\($0.id)/\($0.name)" })")

        XCTAssertEqual(sourceDoc.masks.count, 1, "前提：源图有一个蒙版")
        XCTAssertEqual(productDoc.masks.count, 1, "③ 产物必须有一个蒙版（追加进来的那一个）")
        XCTAssertEqual(productDoc.masks.first?.name, "天空", "③ 蒙版本身过去了")
        XCTAssertEqual(try XCTUnwrap(productDoc.masks.first).feather, 0.18, accuracy: 1e-12)

        XCTAssertNotEqual(productDoc.masks.first?.id, "m-src-sky",
                          "③ id 重新铸造（蒙版 id 是 atlas 缓存的身份，两份不能撞）")
        if case .radialGradient(let g)? = productDoc.masks.first?.components.first?.shape {
            // 降噪不改尺寸，所以短边锚定是精确的恒等 —— 坐标逐位相同。
            print("③ 圆心 \(g.center.x),\(g.center.y) 半径 \(g.radius.x),\(g.radius.y)")
            XCTAssertEqual(g.center.x, 0.25, accuracy: 1e-12)
            XCTAssertEqual(g.center.y, 0.75, accuracy: 1e-12)
            XCTAssertEqual(g.radius.x, 0.2, accuracy: 1e-12)
        } else {
            XCTFail("③ 径向蒙版必须原样过来")
        }

        // ② still holds for everything the mask does not touch.
        let maskDiffs = containmentDiffs(source: try parsed(try developJSON(source.id)),
                                         product: try parsed(try developJSON(productID)),
                                         skip: ["masks"]).diffs
        XCTAssertEqual(maskDiffs, [], "② 除 masks 外的每个 key 仍然相等")

        // ── 「产物已有蒙版时不被抹掉」：再粘一次，第一个蒙版必须还在 ───────────────────────────
        let again = try catalog.copySettings(fromAsset: source.id)
        let report = try catalog.pasteSettings(again, intoAsset: productID, label: "第二次粘贴")
        let twice = try stored(productID)
        print("③ 再粘一次：changed=\(report.changed) 蒙版数 1 → \(twice.masks.count) "
              + "ids=\(twice.masks.map(\.id))")
        XCTAssertTrue(report.changed)
        XCTAssertEqual(twice.masks.count, 2, "③ 蒙版是**追加**：第二次粘贴多一个，不是替换成一个")
        XCTAssertEqual(twice.masks.first?.id, productDoc.masks.first?.id,
                       "③ 产物原有的那个蒙版 id 不许被动过")
        XCTAssertEqual(twice.masks.first?.name, "天空")
        XCTAssertEqual(Set(twice.masks.map(\.id)).count, 2, "③ id 各不相同")
    }

    // MARK: - ④ 是一个 undo 步骤

    func testTheInheritanceIsExactlyOneHistoryRow() throws {
        let source = try makeSession(doc: richDocument())
        try installFakeTool()
        let productID = try runDenoiseAndWait()

        let history = try catalog.editHistory(forAsset: productID)
        let labels = history.snapshots.map(\.label)
        let inheritRows = labels.filter { $0 == Self.inheritLabel }
        print("④ 产物历史 \(history.count) 条，labels=\(labels)，其中「\(Self.inheritLabel)」\(inheritRows.count) 条")

        XCTAssertEqual(history.count, 2, "④ import + 继承，就两条")
        XCTAssertEqual(inheritRows.count, 1, "④ 有且只有一条「\(Self.inheritLabel)」")
        XCTAssertEqual(labels.last, Self.inheritLabel, "④ 它在最上面（当前状态）")

        // The source's own timeline is untouched: inheriting is a write on the product only.
        let sourceHistory = try catalog.editHistory(forAsset: source.id)
        XCTAssertEqual(sourceHistory.count, 1, "④ 原图的历史不许多出任何一行")
        XCTAssertEqual(sourceHistory.snapshots.map(\.label), ["import"])

        // One ⌘Z lands on 「降噪后、还没继承编辑」 — the document the import wrote.
        var undoable = history
        let undone = try XCTUnwrap(undoable.undo(), "④ 必须能撤一步")
        print("④ 撤一步：exposure \(try stored(productID).light.exposure) → \(undone.light.exposure)")
        XCTAssertEqual(undone.light.exposure, 0, accuracy: 1e-12,
                       "④ 撤销一步回到导入时的中性文档（继承是**一步**，不是伪装成初始状态）")
        XCTAssertEqual(undone.light.contrast, 0, accuracy: 1e-12)
    }

    // MARK: - ⑤ 继承失败不拖垮降噪

    /// **How the failure is produced.** The ticket says 「构造一个坏 developJson」. Measured, that
    /// does *not* throw in this codebase: `Catalog.developState` swallows a blob that will not decode,
    /// quarantines it and answers `.neutral` (Develop.swift:174-213), so `copySettings` returns an
    /// empty payload and the paste is a documented no-op. The reachable failure is the **write** —
    /// so this test denies it at the storage layer with a trigger on the product's row, which is
    /// exactly the "the paste threw" branch `runDenoise` has to survive. (The bad-blob case is
    /// measured in its own test below, and it is a finding, not a green.)
    func testAnInheritanceFailureLeavesTheDenoiseSuccessful() throws {
        let source = try makeSession(doc: richDocument())
        try installFakeTool()
        // Any UPDATE of the denoised row's develop_json fails. INSERT (the import) is untouched, and
        // so is the stack write (stack_id is a different column).
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER deny_inherit BEFORE UPDATE OF develop_json ON assets
                WHEN NEW.filename LIKE '%-denoised%'
                BEGIN SELECT RAISE(ABORT, '拒绝继承（测试注入）'); END;
                """)
        }
        defer { try? catalog.dbQueue.write { db in try db.execute(sql: "DROP TRIGGER deny_inherit") } }

        let report = try XCTUnwrap({
            let before = session.denoiseCompletionCount
            session.denoiseSelection()
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                if session.denoiseCompletionCount > before { break }
                pump(0.01)
            }
            return session.lastDenoiseReport
        }(), "⑤ 降噪被判失败：\(session.lastDenoiseError ?? "nil")")

        let productID = report.assetID
        let fileOnDisk = FileManager.default.fileExists(atPath: report.output.path)
        let rowInLibrary = try catalog.asset(id: productID) != nil
        let (stack, rank, _) = try row(productID)
        let productDoc = try stored(productID)

        print("⑤ lastDenoiseError=\(String(describing: session.lastDenoiseError)) "
              + "| lastDenoiseInheritError=\(String(describing: session.lastDenoiseInheritError)) "
              + "| 文件在=\(fileOnDisk) 库里有=\(rowInLibrary) 堆叠=\(stack != nil ? "成(count 置顶 rank \(rank))" : "没成") "
              + "| 产物 exposure=\(productDoc.light.exposure)")

        // The four numbers the ticket asks for.
        XCTAssertNil(session.lastDenoiseError, "⑤ 继承失败不许写成整单失败")
        XCTAssertNotNil(session.lastDenoiseInheritError, "⑤ 但必须留一条自己原因")
        XCTAssertTrue(fileOnDisk, "⑤ 产物文件必须在")
        XCTAssertTrue(rowInLibrary, "⑤ 库里必须有这一行")

        // …and the rest of the §386 contract survived: stacked, product on top, report published.
        XCTAssertNotNil(stack, "⑤ 堆叠必须成了")
        XCTAssertEqual(rank, 0, "⑤ 产物仍是置顶")
        XCTAssertEqual(report.stackCount, 2)
        XCTAssertNotNil(session.lastDenoiseReport, "⑤ 报告不许被清")
        // Nothing was inherited (the write was refused), and nothing else moved either.
        XCTAssertEqual(productDoc.light.exposure, 0, accuracy: 1e-12, "⑤ 这一轮确实没继承到")
        XCTAssertEqual(try catalog.editHistory(forAsset: productID).count, 1,
                       "⑤ 拒绝的那一步不许留下半条历史")
    }

    /// The measured shape of 「坏 developJson」: it does **not** throw, it reads as `.neutral`, so the
    /// inheritance is a silent no-op — 「继承失败」 never fires and the product simply has no edits.
    ///
    /// This is a finding for the report: the ticket's §2.4 assumed a corrupt source blob would raise.
    /// It is asserted here so the behaviour is pinned rather than folklore, and so the day
    /// `developState` starts throwing this test goes red and ⑤'s injection can be replaced by the
    /// ticket's own.
    func testACorruptSourceBlobIsASilentNoOpRatherThanAFailure() throws {
        let source = try makeSession(doc: richDocument())
        try installFakeTool()
        // Damage the source's document the way a killed process would: bytes that are not a document.
        try catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE assets SET develop_json = ? WHERE id = ?",
                           arguments: ["{not json", source.id])
        }
        // …and does the read actually raise?
        var threw: Error?
        do { _ = try catalog.copySettings(fromAsset: source.id) } catch { threw = error }
        print("⑤b 坏 developJson：copySettings 抛出=\(threw.map { "\($0)" } ?? "没有（读成 .neutral）") "
              + "developDecodeFailures=\(catalog.developDecodeFailures)")

        let productID = try runDenoiseAndWait()
        let productDoc = try stored(productID)
        print("⑤b lastDenoiseError=\(String(describing: session.lastDenoiseError)) "
              + "lastDenoiseInheritError=\(String(describing: session.lastDenoiseInheritError)) "
              + "产物 exposure=\(productDoc.light.exposure) 历史=\(try catalog.editHistory(forAsset: productID).count) 条")

        XCTAssertNil(session.lastDenoiseError, "⑤b 降噪本身成功")
        XCTAssertNil(session.lastDenoiseInheritError,
                     "⑤b 当前实现下这不是「失败」：损坏的源被读成中性文档，粘过去是空操作")
        XCTAssertEqual(productDoc.light.exposure, 0, accuracy: 1e-12,
                       "⑤b 因此产物什么也没继承到 —— 报告里要写清这条边界")
    }

    // MARK: - ⑥ 产物可继续编辑

    func testTheProductIsStillEditableAndOneUndoTakesBackTheUsersOwnTweak() throws {
        let source = try makeSession(doc: richDocument())
        try installFakeTool()
        let productID = try runDenoiseAndWait()
        XCTAssertEqual(session.selection, [productID], "完成后选中的是产物")
        XCTAssertEqual(session.loadedEditAssetID, productID)

        let before = try stored(productID)
        session.applyEdit { $0.light.exposure = 2.25 }
        XCTAssertTrue(session.commitEdit(label: "微调", coalesce: false), "⑥ 继承之后仍能写")
        let after = try stored(productID)
        print("⑥ 产物 exposure \(before.light.exposure) → \(after.light.exposure) "
              + "（历史 \(try catalog.editHistory(forAsset: productID).snapshots.map(\.label))）")

        XCTAssertEqual(before.light.exposure, 1.5, accuracy: 1e-12, "继承来的值")
        XCTAssertEqual(after.light.exposure, 2.25, accuracy: 1e-12, "自己改的值落了盘")
        XCTAssertEqual(after.light.contrast, 20, accuracy: 1e-12, "其余继承来的字段不受影响")
        XCTAssertEqual(session.edit.light.exposure, 2.25, "内存里的文档也是这个值")

        let labels = try catalog.editHistory(forAsset: productID).snapshots.map(\.label)
        XCTAssertEqual(labels, ["import", Self.inheritLabel, "微调"],
                       "⑥ 三次写入三条，继承那条夹在中间")

        // ⌘Z takes back the user's own tweak — not the inheritance (§2.3).
        XCTAssertTrue(session.undo())
        let undone = try stored(productID)
        print("⑥ ⌘Z 之后 exposure=\(undone.light.exposure)（应回到继承来的 1.5）")
        XCTAssertEqual(undone.light.exposure, 1.5, accuracy: 1e-12,
                       "⑥ 第一步撤销撤的是他自己的改动")
    }

    // MARK: - 「全部编辑」的边界（测量，不是假设）

    /// What 「所有编辑」 actually covers, measured against a document that uses **every** card.
    ///
    /// `EditSnapshot` is the clipboard of 「复制设置」, and it deliberately carries the twelve cards'
    /// leaves — not `detailSettings` (042's four detail axes), not `healSpots` (修复画笔), not
    /// `color.point` (点颜色), not `geometry.guideLines`, and never `showMaskID`. §2.5 forbids
    /// changing that type for this ticket, so those edits do **not** reach the product. Pinning the
    /// gap here is the honest option: if the clipboard grows, this test goes red and ② can be
    /// extended instead of the report quietly ageing.
    func testTheClipboardsBoundaryIsTheKnownGap() throws {
        var doc = richDocument()
        doc.detailSettings.detail = 6
        doc.healSpots = [HealSpot()]
        doc.geometry.guideLines = [StoredGuideLine(ax: 0.2, ay: 0.1, bx: 0.2, by: 0.9, vertical: true)]


        let source = try makeSession(doc: doc)
        try installFakeTool()
        let productID = try runDenoiseAndWait()

        let sourceKeys = try topLevelKeys(try developJSON(source.id))
        let productKeys = try topLevelKeys(try developJSON(productID))
        let missing = sourceKeys.filter { !productKeys.contains($0) }
        print("边界：源图顶层 key=\(sourceKeys)")
        print("边界：产物顶层 key=\(productKeys)")
        print("边界：源图有、产物没有的 key=\(missing)")

        // The key-level question is not enough: `detailSettings` is *present* in the product (the
        // encoder always writes the group) with different numbers inside. The real reading is the
        // recursive one — every value that did not travel shows up as one diff line.
        let docDiffs = containmentDiffs(source: try parsed(try developJSON(source.id)),
                                        product: try parsed(try developJSON(productID)),
                                        skip: ["masks"]).diffs
        print("边界：逐值差异 \(docDiffs.count) 条 = \(docDiffs)")

        // The card-level leaves all travelled (that is what ② already proves for a mask-free doc).
        XCTAssertEqual(missing, ["healSpots"],
                       "边界：修复画笔根本不在 document 里（EditSnapshot 不带它）")
        XCTAssertTrue(docDiffs.contains { $0.hasPrefix("detailSettings.detail") },
                      "边界：042 的四个细节轴没有过去（EditSnapshot 不带 detailSettings）")
        XCTAssertTrue(docDiffs.contains { $0.hasPrefix("geometry.guideLines") },
                      "边界：354 的辅助线没有过去（EditSnapshot 不带 guideLines）")
        XCTAssertTrue(docDiffs.contains { $0.hasPrefix("healSpots") },
                      "边界：修复画笔没有过去（EditSnapshot 不带 healSpots）")
        XCTAssertEqual(docDiffs.count, 3,
                       "边界：除这三条之外**没有任何**别的差异 —— 全部实拍差异都在这里点名了：\(docDiffs)")
        XCTAssertEqual(try stored(productID).healSpots.count, 0, "修复画笔没有过去（已知缺口）")
        XCTAssertNil(try stored(productID).detailSettings.detail, "042 的四个细节轴没有过去（已知缺口）")
    }
}
