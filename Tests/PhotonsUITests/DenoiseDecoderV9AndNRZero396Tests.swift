import XCTest
import AppKit
import GRDB
import ImageIO
import UniformTypeIdentifiers
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsCatalog
@testable import PhotonsUI

/// §396 B/C —— 「生成的 DNG 默认解码器修改为 v9 dng，并且降噪强度为0」。
///
/// The ticket's acceptance table, measured end to end through the shipped entry point
/// (`session.denoiseSelection()`) against a **real** library on disk and the real catalog reads —
/// the same harness §395 established, so the two tickets are measured by the same ruler:
///
///   ② the product's `decoderVersion` in `develop_json` is exactly `"9.dng"` (raw value printed);
///   ③ the product's `detailSettings.luminanceNR` and `.colorNR` are **0** — and, because 042's
///      decoder reads a stored `0` back as `nil`, the reading is taken **twice**: once from the
///      document object and once from the raw JSON text, so 「写进去了」 is measured on the bytes
///      and 「读回来是什么」 is measured on the type;
///   ④ 395's inheritance is intact: the source's exposure/contrast/etc. are still in the product,
///      and the recursive containment comparison still passes;
///   ⑤ a file whose `supportedDecoderVersions` does **not** contain `"9.dng"` ⇒ `decoderVersion`
///      keeps its previous value (nil), no error, and nothing silently becomes a different version;
///   ⑥ exactly **one** new history row, and one ⌘Z lands on 「降噪后、无编辑」.
///
/// The denoise itself is §386/§390's stand-in tool (a byte copy): every assertion here is about the
/// **library document** the product row ends up with, not about pixels.
@MainActor
final class DenoiseDecoderV9AndNRZero396Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var catalog: Catalog!
    private var session: CatalogSession!
    private var root: SourceRoot!

    /// The label the production code writes (§395's, kept by §396 because the payload is one write).
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
            .appendingPathComponent("photons-denoise-v9-396-\(UUID().uuidString)", isDirectory: true)
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

    /// A source document that carries the things 396 must **not** clobber: exposure/contrast (395's
    /// ④), and the decoder + a non-zero `detailSettings` that 396 is supposed to **overwrite** — the
    /// source is deliberately v8 with NR 60/40 so the product's `9.dng` / `0` / `0` cannot be a
    /// coincidence of 「源图本来就是这样」.
    private func richDocument() -> EditModel {
        var d = EditModel.neutral
        d.light.exposure = 1.5
        d.light.contrast = 20
        d.light.highlights = -30
        d.light.shadows = 12
        d.light.temperature = 5500
        d.light.tint = 10
        d.color.vibrance = 23
        d.color.saturation = -11
        d.effects.vignetteAmount = -20
        d.effects.texture = 10
        d.sharpen.amount = 70
        d.geometry.crop = NormalizedRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        // The two things 396 overrides — set to values that are NOT what the product must end with.
        d.decoderVersion = "8"
        d.detailSettings = DetailSettings(luminanceNR: 60, colorNR: 40)
        return d
    }

    /// One DNG row over the committed 1024² fixture, carrying `doc` as its stored document **and**
    /// as history seq 1 (`import`), exactly as `ImportService` writes a freshly imported photo.
    @discardableResult
    private func makeSession(doc: EditModel, fixture: URL? = nil) throws -> Asset {
        // A fresh source folder per call: one test may build several libraries (⑤ runs two
        // witnesses), and they must not collide on `IMG_0000.dng`.
        let stamp = UUID().uuidString
        src = workDir.appendingPathComponent("src-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let url = workDir.appendingPathComponent("S396-\(stamp).\(LibraryLayout.packageExtension)",
                                                 isDirectory: true)
        catalog = try Catalog.create(at: url)
        root = try catalog.ensureRoot(for: src, mode: .reference)
        let name = "IMG_0000.dng"
        try FileManager.default.copyItem(at: fixture ?? Self.fixtureURL,
                                         to: src.appendingPathComponent(name))
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

    private func developJSON(_ id: String) throws -> String {
        try catalog.dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT develop_json FROM assets WHERE id = ?",
                                arguments: [id]) ?? ""
        }
    }

    /// The raw JSON leaf, straight out of the stored text — no `DetailSettings` decoder in between.
    ///
    /// This is the half of ③ that 042's type cannot answer: `DetailSettings.position(in:_:)` guards
    /// `v > 0`, so a stored `0` reads back as `nil` (measured:
    /// `{"colorNR":0,"luminanceNR":0}` → `luminanceNR=nil colorNR=nil`). The **bytes** therefore
    /// carry the 0 and the **type** reports 「默认位置」. Both readings are printed.
    private func rawLeaf(_ id: String, group: String, key: String) throws -> Any? {
        let obj = try JSONSerialization.jsonObject(with: Data(try developJSON(id).utf8))
        guard let root = obj as? [String: Any] else { return nil }
        guard !group.isEmpty else { return root[key] }
        guard let g = root[group] as? [String: Any] else { return nil }
        return g[key]
    }

    // MARK: - ② ③ ④ one product, three numbers

    func testTheProductAsksForV9AndZeroNoiseReduction() throws {
        let source = try makeSession(doc: richDocument())
        try installFakeTool()

        // The premise, printed from both sides: the source is v8 with NR 60/40, so anything the
        // product says is a 396 write and not an inheritance artifact.
        let sourceDoc = try stored(source.id)
        print("前提 源图 decoderVersion=\(String(describing: sourceDoc.decoderVersion)) "
              + "detailSettings=\(sourceDoc.detailSettings.summary)")

        let productID = try runDenoiseAndWait()
        let product = try stored(productID)

        // ── ② decoderVersion ──────────────────────────────────────────────────────────────────────
        print("② 产物 decoderVersion = \(String(describing: product.decoderVersion))")
        XCTAssertEqual(product.decoderVersion, "9.dng",
                       "② 产物必须是 9.dng（裸 \"9\" 会静默读回 8，见 EditModel 的实测注释）")
        XCTAssertNotEqual(product.decoderVersion, "9", "② 反向门：裸 9 不是这个文件的一项")

        let rawDecoder = try rawLeaf(productID, group: "", key: "decoderVersion")
        print("② develop_json 里的 decoderVersion 原文 = \(String(describing: rawDecoder))")
        XCTAssertEqual(rawDecoder as? String, "9.dng", "② 字节里也得是 9.dng")

        // ── ③ luminanceNR / colorNR ───────────────────────────────────────────────────────────────
        // Two readings, deliberately. The type drops a stored 0 (`v > 0` guard), so asserting only
        // on `product.detailSettings` would make the reverse gate ⑩ unfalsifiable — `nil` would look
        // identical whether 396 wrote 0 or wrote nothing at all.
        let rawLNR = try rawLeaf(productID, group: "detailSettings", key: "luminanceNR")
        let rawCNR = try rawLeaf(productID, group: "detailSettings", key: "colorNR")
        let lnr = (rawLNR as? NSNumber)?.doubleValue
        let cnr = (rawCNR as? NSNumber)?.doubleValue
        print("③ develop_json 原文 detailSettings.luminanceNR = \(String(describing: rawLNR)) "
              + "· colorNR = \(String(describing: rawCNR))")
        print("③ 类型读回 detailSettings.luminanceNR = \(String(describing: product.detailSettings.luminanceNR)) "
              + "· colorNR = \(String(describing: product.detailSettings.colorNR)) "
              + "（042 的 0 读回 nil，见 DetailSettings.position(in:_:) 的 v > 0 guard）")
        XCTAssertEqual(lnr, 0, "③ 字节里 luminanceNR 必须是 0；实际 \(String(describing: rawLNR))")
        XCTAssertEqual(cnr, 0, "③ 字节里 colorNR 必须是 0；实际 \(String(describing: rawCNR))")

        // And the type-level consequence, stated as what it is: both axes now ask for **nothing**
        // (`nil` = 「停在这个机身的默认位置」), which is the same *pixel* answer 0 would give on the
        // L1030433 baseline (luminance 0, colour 0.5 → position 50; 0 asks for nothing).
        print("③ 类型读回的 decodeValues = \(product.detailSettings.decodeValues(baseline: .measured).summary)")
        XCTAssertTrue(product.detailSettings.decodeValues(baseline: .measured).isEmpty,
                      "③ 两根轴都不再给解码器任何赋值（0 / nil 在像素上是同一个答案）")

        // ── ④ 395's inheritance is intact ─────────────────────────────────────────────────────────
        print("④ 源图 exposure=\(sourceDoc.light.exposure) contrast=\(sourceDoc.light.contrast) "
              + "| 产物 exposure=\(product.light.exposure) contrast=\(product.light.contrast)")
        XCTAssertEqual(product.light.exposure, 1.5, accuracy: 1e-12, "④ 曝光必须仍然继承（395 不许变红）")
        XCTAssertEqual(product.light.contrast, 20, accuracy: 1e-12, "④ 对比度必须仍然继承")
        XCTAssertEqual(product.light.tint, 10)
        XCTAssertEqual(product.color.vibrance, 23, accuracy: 1e-12)
        XCTAssertEqual(product.effects.vignetteAmount, -20, accuracy: 1e-12)
        XCTAssertEqual(product.sharpen.amount, 70, accuracy: 1e-12)
        XCTAssertEqual(product.geometry.crop.x, 0.05, accuracy: 1e-12, "④ 裁剪也仍然继承")
    }

    // MARK: - ⑤ 不支持 v9 的文件不许硬写

    /// ⑤ — a file whose `supportedDecoderVersions` has no `"9.dng"`.
    ///
    /// **What the branch is.** 396 decides on the **product** file (`outcome.output`), so the witness
    /// has to be a product the decoder will answer a version list for — and the answer must lack
    /// `"9.dng"`. The stand-in tool copies its input through, so the source's bytes decide.
    ///
    /// Two witnesses, both measured on this machine, and **both** have to hold:
    ///
    ///   · a real camera RAW that does not offer v9 — `/Users/luyao/Desktop/test/viltrox/0164541249.rw2`
    ///     (Panasonic DC-S1RM2) answers `["7","8"]`. Skipped when that file is absent, because it is a
    ///     sample on this machine and not part of the repo.
    ///   · a generated 8-bit RGB container named `.dng`, which answers `["None"]` while still
    ///     decoding — always available, so the branch is never untested on a machine without the RW2.
    ///
    /// The reason both are here: a corrupted RAW answers `["None"]` **and** `outputImage == nil`, i.e.
    /// 「读不了」 — that would make this test pass for the wrong reason (the code skips v9 because the
    /// decode failed, not because the file declined it). The RW2 is the honest case; the container is
    /// the always-runnable one. In both, the source document asks for `"8"` explicitly, so
    /// 「保持原值」 has a value to keep, a hard-written `"9.dng"` shows up as `"9.dng"`, and a silent
    /// rewrite shows up as anything else.
    func testAFileWithoutV9KeepsItsDecoderAndDoesNotFail() throws {
        var witnesses: [(String, URL)] = [("生成的 8-bit 容器", try makeFileWithoutV9())]
        let realRaw = URL(fileURLWithPath: "/Users/luyao/Desktop/test/viltrox/0164541249.rw2")
        if FileManager.default.fileExists(atPath: realRaw.path) {
            // Same bytes under a `.dng` name: `AnselDenoiseJob` requires the extension, and the
            // import row's `ext` must be `dng` for the menu path to accept it.
            let copy = workDir.appendingPathComponent("panasonic.dng")
            try FileManager.default.copyItem(at: realRaw, to: copy)
            witnesses.append(("真机 RW2（DC-S1RM2）", copy))
        } else {
            print("⑤ 没有 RW2 样本，只跑生成的容器那一路")
        }

        for (name, url) in witnesses {
            let offered = try RAWDecoder.availableVersions(for: url)
            print("⑤ [\(name)] supportedDecoderVersions = \(offered)")
            XCTAssertFalse(offered.contains("9.dng"),
                           "⑤ [\(name)] 前提：这个夹具必须真的不认 9.dng；实际 \(offered)")
            XCTAssertFalse(offered.isEmpty, "⑤ [\(name)] 前提：列表不能是空的（空 = 没问出答案）")

            let source = try makeSession(doc: richDocument(), fixture: url)
            try installFakeTool()
            let productID = try runDenoiseAndWait()
            let product = try stored(productID)

            print("⑤ [\(name)] lastDenoiseError = \(String(describing: session.lastDenoiseError)) "
                  + "| lastDenoiseInheritError = \(String(describing: session.lastDenoiseInheritError)) "
                  + "| 产物 decoderVersion = \(String(describing: product.decoderVersion))")
            XCTAssertNil(session.lastDenoiseError, "⑤ [\(name)] 不支持 v9 不许把降噪判失败")
            XCTAssertNil(session.lastDenoiseInheritError, "⑤ [\(name)] 也不许写成「继承失败」")
            XCTAssertEqual(product.decoderVersion, "8",
                           "⑤ [\(name)] 文件不认 9.dng ⇒ 保持原值（源图是 \"8\"）")
            XCTAssertNotEqual(product.decoderVersion, "9.dng", "⑤ [\(name)] 反向门：写进去才是 bug")
            // ④ still holds on this file — the override skipped, the inheritance did not.
            XCTAssertEqual(product.light.exposure, 1.5, accuracy: 1e-12, "⑤ [\(name)] 继承没被带坏")
            XCTAssertEqual(product.light.contrast, 20, accuracy: 1e-12)
            // ③ is unconditional: NR is zeroed whether or not the file takes v9.
            let rawLNR = try rawLeaf(productID, group: "detailSettings", key: "luminanceNR")
            let rawCNR = try rawLeaf(productID, group: "detailSettings", key: "colorNR")
            print("⑤ [\(name)] 同一产物上的降噪原文 = \(String(describing: rawLNR)) / \(String(describing: rawCNR))")
            XCTAssertEqual((rawLNR as? NSNumber)?.doubleValue, 0, "⑤ [\(name)] 降噪归零必须仍然写")
            XCTAssertEqual((rawCNR as? NSNumber)?.doubleValue, 0, "⑤ [\(name)] 色彩降噪同样必须写")
        }
    }

    /// A legal image container named `.dng` that this machine's RAW decoder opens while reporting a
    /// version list **without** `"9.dng"`.
    ///
    /// Written with ImageIO rather than by corrupting a RAW: a corrupted file answers `["None"]`
    /// *and* `outputImage == nil`, which would be 「读不了」 pretending to be 「不支持 v9」. This one
    /// decodes (it is an 8-bit RGB image) and the app's own probe reads it without throwing.
    private func makeFileWithoutV9() throws -> URL {
        let target = workDir.appendingPathComponent("no-v9.dng")
        let side = 64
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.45, green: 0.35, blue: 0.25, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let image = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            target as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw XCTSkip("⑤ 写不出夹具图片")
        }
        return target
    }

    // MARK: - ⑥ 一个 undo 步骤

    func testTheWholeOverrideIsOneHistoryRowAndOneUndoTakesItBack() throws {
        let source = try makeSession(doc: richDocument())
        try installFakeTool()
        let productID = try runDenoiseAndWait()

        let history = try catalog.editHistory(forAsset: productID)
        let labels = history.snapshots.map(\.label)
        print("⑥ 产物历史 \(history.count) 条，labels=\(labels)")
        print("⑥ 当前 decoderVersion=\(String(describing: try stored(productID).decoderVersion)) "
              + "luminanceNR 原文=\(String(describing: try rawLeaf(productID, group: "detailSettings", key: "luminanceNR")))")

        XCTAssertEqual(history.count, 2, "⑥ import + 一行「继承并覆写」，就两条")
        XCTAssertEqual(labels, ["import", Self.inheritLabel], "⑥ 有且只有一条新步骤，名字仍然是 395 的那条")
        XCTAssertEqual(labels.filter { $0 == Self.inheritLabel }.count, 1, "⑥ 不许拆成两条")

        // The source's own timeline is untouched.
        XCTAssertEqual(try catalog.editHistory(forAsset: source.id).count, 1, "⑥ 原图历史不许动")

        // One ⌘Z lands on 「降噪后、无编辑」: the document the import wrote.
        var undoable = history
        let undone = try XCTUnwrap(undoable.undo(), "⑥ 必须能撤一步")
        print("⑥ 撤一步：exposure \(try stored(productID).light.exposure) → \(undone.light.exposure)，"
              + "decoderVersion → \(String(describing: undone.decoderVersion))，"
              + "luminanceNR → \(String(describing: undone.detailSettings.luminanceNR))")
        XCTAssertEqual(undone.light.exposure, 0, accuracy: 1e-12,
                       "⑥ 撤销一步回到导入时的中性文档（继承与覆写是**一步**）")
        XCTAssertNil(undone.decoderVersion, "⑥ v9 也一起撤掉了")
        XCTAssertNil(undone.detailSettings.luminanceNR, "⑥ 降噪归零也一起撤掉了")
    }

    // MARK: - 框架自检：supportedDecoderVersions 是本机事实，不是常量

    /// Before trusting ② and ⑤, prove the **premise** they rest on: `supportedDecoderVersions` is a
    /// per-file answer from the decoder, not a constant this test could be reading off itself.
    ///
    /// Two facts, both measured here:
    ///
    ///   · the fixture offers `9.dng` **and not bare `9`** — which is exactly why `EditModel`'s
    ///     comment says a bare `9` silently reads back `8`, and why ② must assert the `.dng` spelling;
    ///   · a different container answers a **different** list that has neither — so ⑤'s branch is
    ///     reachable, and the empty-list case (`["None"]` + unreadable) is not the same thing.
    func testTheVersionListIsPerFileAndTheBareNineIsAbsent() throws {
        let fixture = try RAWDecoder.availableVersions(for: Self.fixtureURL)
        print("自检 夹具 supportedDecoderVersions = \(fixture)")
        XCTAssertTrue(fixture.contains("9.dng"), "自检 夹具必须认 9.dng，否则 ② 无从测起")
        XCTAssertFalse(fixture.contains("9"),
                       "自检 本机列表里没有裸 9 —— 这正是必须写 \"9.dng\" 的原因")

        let other = try makeFileWithoutV9()
        let otherVersions = try RAWDecoder.availableVersions(for: other)
        print("自检 另一个容器（8-bit RGB）= \(otherVersions)")
        XCTAssertNotEqual(otherVersions, fixture,
                          "自检 版本列表必须**按文件**变化，否则 ⑤ 的分支根本没有入口")
        XCTAssertFalse(otherVersions.contains("9.dng"), "自检 ⑤ 的夹具必须真的不认 9.dng")
    }
}
