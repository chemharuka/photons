import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsCatalog
@testable import PhotonsCore
@testable import PhotonsUI

/// **528 — 生成降噪文件时把引导线同步过去，文件的 XMP 里也要有引导线位置。**
///
/// 用户口径（2026-11-23，原话）:
/// > 在生成降噪文件时，引导线也要同步过去。也就是 xml 中要有引导线位置的记录
///
/// 引导线是文档的一部分（`EditModel.geometry.guideLines`），但不在 `EditSnapshot` 里 —— 那是
/// 「复制设置」的剪贴板契约，395 的边界用例钉着它。降噪产物走的是 `copySettings` + `applied(to:)`
/// 那条继承路，所以本单在**同一次** `appendDevelop` 上单独补写引导线，并且把继承后的文档合并进
/// 产物 DNG 的 `photons:document`（tag 700 里我们自己的那一个属性）。
///
/// 这一套量四件事：
///   ① 库内：产物的 `guideLines` 与原图逐字段相等（3 条、含顺序、1/1000 精度）；
///   ② 文件内：只用 `DNGXMP.documentString(at:)` 读产物 DNG 也能解出同样的引导线，且文件里
///      **复制过来的** `crs:*` 一个键都没变；
///   ③ 原图没有引导线：产物也没有，且我们不写空数组 —— 产物的 tag 700 与源文件逐字节相同
///      （没有多写一个字节）；
///   ④ 剪贴板边界不变：`copySettings(fromAsset:)` 的 `EditSnapshot` 仍然不带引导线。
///
/// 降噪本身用 §386/§390 的替身工具（capabilities 回答 image-dng，跑起来是把输入复制成输出），
/// 因为这里断言的是文档与 XMP，不是像素。
@MainActor
final class DenoiseGuideLines528Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var catalog: Catalog!
    private var session: CatalogSession!
    private var root: SourceRoot!

    /// 1/1000 归一化精度：整千分位，避免二进制小数的打印差异；三条线含横/竖与顺序。
    private static let guideLines: [StoredGuideLine] = [
        StoredGuideLine(ax: 0.125, ay: 0.250, bx: 0.375, by: 0.500, vertical: false),
        StoredGuideLine(ax: 0.625, ay: 0.750, bx: 0.875, by: 0.100, vertical: true),
        StoredGuideLine(ax: 0.200, ay: 0.300, bx: 0.200, by: 0.800, vertical: true),
    ]

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise-guides528-\(UUID().uuidString)", isDirectory: true)
        src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - harness

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters.removeValue(forKey: key) }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    @discardableResult
    private func makeSession(doc: EditModel) throws -> Asset {
        let url = workDir.appendingPathComponent("S528.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: url)
        root = try catalog.ensureRoot(for: src, mode: .reference)
        let name = "IMG_0528.dng"
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

    /// §390 的替身：`capabilities` 回答 `image-dng`，跑起来把输入复制成输出。
    private func installFakeTool() throws {
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
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func runDenoiseAndWait(timeout: TimeInterval = 120,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) throws -> CatalogSession.DenoiseReport {
        let before = session.denoiseCompletionCount
        session.denoiseSelection()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.denoiseCompletionCount > before { break }
            pump(0.01)
        }
        XCTAssertGreaterThan(session.denoiseCompletionCount, before,
                             "降噪没在 \(timeout) s 内结束", file: file, line: line)
        return try XCTUnwrap(session.lastDenoiseReport,
                             "降噪失败：\(session.lastDenoiseError ?? "nil")",
                             file: file, line: line)
    }

    // MARK: - tag 700 helpers

    /// The raw XMP packet in IFD0 tag 700, byte for byte (padding included).
    private func xmpPacket(at url: URL) throws -> Data? {
        let file = try TIFFFile(Data(contentsOf: url))
        guard let entry = file.entries(of: 700, in: file.ifd0) else { return nil }
        return try file.payload(entry)
    }

    /// Every `crs:Name="value"` in the packet. This is the foreign (Lightroom) half that must land
    /// on the product untouched.
    private func crsKeys(at url: URL) throws -> [String: String] {
        guard let packet = try xmpPacket(at: url),
              let text = String(data: packet, encoding: .utf8) else { return [:] }
        let regex = try NSRegularExpression(pattern: #"(crs:[A-Za-z0-9_]+)\s*=\s*"([^"]*)""#)
        var out: [String: String] = [:]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard match.numberOfRanges == 3,
                  let name = Range(match.range(at: 1), in: text),
                  let value = Range(match.range(at: 2), in: text) else { continue }
            out[String(text[name])] = String(text[value])
        }
        return out
    }

    // MARK: - ① 库内继承

    func testTheProductDocumentCarriesEveryGuideLineInOrder() throws {
        var doc = EditModel.neutral
        doc.light.exposure = 1.25
        doc.geometry.guideLines = Self.guideLines

        let source = try makeSession(doc: doc)
        try installFakeTool()
        let report = try runDenoiseAndWait()

        XCTAssertNil(session.lastDenoiseError)
        XCTAssertNil(session.lastDenoiseInheritError,
                     "528 ① 补写引导线/写 XMP 都不许把继承判失败")

        let sourceLines = try catalog.develop(forAsset: source.id).geometry.guideLines
        let productLines = try catalog.develop(forAsset: report.assetID).geometry.guideLines
        print("528 ① 源 \(sourceLines.count) 条 → 产物 \(productLines.count) 条：\(productLines)")
        XCTAssertEqual(sourceLines.count, 3, "528 ① 夹具确实有 3 条")
        XCTAssertEqual(productLines, sourceLines,
                       "528 ① 逐字段相等（端点、顺序、id 语义都在数组顺序里）")
        XCTAssertEqual(productLines.map(\.vertical), [false, true, true], "528 ① 顺序与横竖意图都在")
        XCTAssertEqual(try catalog.develop(forAsset: report.assetID).light.exposure, 1.25,
                       accuracy: 1e-12, "528 ① 其余继承不受影响")
    }

    // MARK: - ② 文件内记录

    func testTheProductFilesXMPCarriesTheSameGuideLinesAndKeepsCrsKeys() throws {
        var doc = EditModel.neutral
        doc.geometry.guideLines = Self.guideLines

        let source = try makeSession(doc: doc)
        try installFakeTool()
        let report = try runDenoiseAndWait()

        let sourceLines = try catalog.develop(forAsset: source.id).geometry.guideLines
        let storedDoc = try catalog.develop(forAsset: report.assetID)

        let text = try XCTUnwrap(DNGXMP.documentString(at: report.output),
                                 "528 ② 产物 DNG 的 tag 700 里必须读出 photons:document")
        let fileDoc = try JSONDecoder().decode(EditModel.self, from: Data(text.utf8))
        print("528 ② 文件 XMP 里 \(fileDoc.geometry.guideLines.count) 条引导线")
        XCTAssertEqual(fileDoc.geometry.guideLines, sourceLines, "528 ② 文件里的引导线与源文档相等")
        XCTAssertEqual(fileDoc, storedDoc,
                       "528 ② 文件里解出的就是库里那一份继承后的文档（同一份文档，不是第二份）")

        let sourceCrs = try crsKeys(at: try catalog.fileURL(for: source))
        let productCrs = try crsKeys(at: report.output)
        print("528 ② crs:* \(sourceCrs.count) 键：源=产物? \(sourceCrs == productCrs)")
        XCTAssertFalse(sourceCrs.isEmpty, "528 ② 夹具自带 Lightroom 的 crs:*，这条断言才有牙齿")
        XCTAssertEqual(productCrs, sourceCrs,
                       "528 ② 只替换 photons:document，复制过来的 crs:* 逐键不变")
    }

    // MARK: - ③ 没有引导线：不写空数组、不多一个字节

    func testASourceWithoutGuideLinesAddsNoXMPBytes() throws {
        let source = try makeSession(doc: .neutral)
        try installFakeTool()
        let report = try runDenoiseAndWait()

        XCTAssertEqual(try catalog.develop(forAsset: report.assetID).geometry.guideLines, [],
                       "528 ③ 库里是空的")
        XCTAssertNil(try DNGXMP.documentString(at: report.output),
                     "528 ③ 没有 photons:document —— 没写空数组，也没写别的")

        let sourcePacket = try xmpPacket(at: try catalog.fileURL(for: source))
        let productPacket = try xmpPacket(at: report.output)
        XCTAssertNotNil(sourcePacket, "528 ③ 夹具自带 tag 700")
        XCTAssertEqual(productPacket, sourcePacket,
                       "528 ③ tag 700 与源文件逐字节相同 ⇒ 这一步没有多写一个字节")
        XCTAssertEqual(productPacket?.count, sourcePacket?.count, "528 ③ XMP 字节数不增加")
    }

    // MARK: - ④ 剪贴板边界不变

    func testTheClipboardSnapshotStillDoesNotCarryGuideLines() throws {
        var doc = EditModel.neutral
        doc.geometry.guideLines = Self.guideLines
        let source = try makeSession(doc: doc)

        let snapshot = try catalog.copySettings(fromAsset: source.id)
        let json = try JSONEncoder().encode(snapshot)
        let text = String(decoding: json, as: UTF8.self)
        print("528 ④ EditSnapshot 的 JSON=\(text.prefix(120))…")

        XCTAssertEqual(try catalog.develop(forAsset: source.id).geometry.guideLines.count, 3,
                       "528 ④ 源文档确实有 3 条，下面那条断言才有意义")
        XCTAssertFalse(text.contains("guideLines"),
                       "528 ④ copySettings 的 EditSnapshot 仍然不带引导线（395 的剪贴板边界）")
        let geometry = try XCTUnwrap(snapshot.geometry)
        let labels = Mirror(reflecting: geometry).children.compactMap(\.label)
        XCTAssertFalse(labels.contains("guideLines"),
                       "528 ④ GeometryPatch 没有 guideLines 字段：\(labels)")
    }
}
