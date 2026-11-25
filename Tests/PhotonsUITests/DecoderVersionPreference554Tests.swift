import XCTest
import AppKit
import CoreImage
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsCatalog
@testable import PhotonsUI

/// §554 — 模型降噪产物的解码器版本：`9 > 9.dng > 8 > 8.dng > 其他可选的`。
///
/// Three layers are measured separately:
///
///   1. **the pure rule** — six synthetic lists from the ticket, plus the deterministic fallback;
///   2. **the read-back** — on a real fixture file, and with a synthetic filter that refuses bare
///      `9` (the measured behaviour 396 was written around), where the next candidate must win;
///   3. **the denoise product** — a real library, a real fixture and the shipped `denoiseSelection()`
///      path, asserting the stored document asks for exactly the preference's answer.
///
/// The reverse gate is explicit: if the order were reverted to 396's 「only 9.dng」, the `"9"` list and
/// the `"8"` list below must fail (old rule → `9.dng` / `nil`).
@MainActor
final class DecoderVersionPreference554Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
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
            .appendingPathComponent("photons-decver-554-\(UUID().uuidString)", isDirectory: true)
        src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - 1. the pure table

    func testTheOwnersOrderIsNineThenNineDNGThenEightThenEightDNG() {
        XCTAssertEqual(DecoderVersionPreference.preferred(in: ["9", "9.dng", "8", "8.dng"]), "9")
        XCTAssertEqual(DecoderVersionPreference.preferred(in: ["9.dng", "8", "8.dng"]), "9.dng")
        XCTAssertEqual(DecoderVersionPreference.preferred(in: ["8", "8.dng"]), "8",
                       "8 排在 8.dng 前面：同号时裸拼写优先")
        XCTAssertEqual(DecoderVersionPreference.preferred(in: ["8.dng", "7", "7.dng"]), "8.dng",
                       "8.dng 在 7 之前：主版本号降序先于拼写")
        XCTAssertEqual(DecoderVersionPreference.preferred(in: ["7", "7.dng", "6"]), "7",
                       "其余按主版本降序，同号裸拼写在前")
        XCTAssertNil(DecoderVersionPreference.preferred(in: []),
                     "空列表 = 跟随 Apple 默认，既有行为")
    }

    /// The deterministic fallback, stated as its own small table so 「其余可选项」 is not hand-waving.
    func testTheRemainingSpellingsAreOrderedAndStable() {
        XCTAssertEqual(DecoderVersionPreference.candidates(in: ["None", "10", "9.dng", "6.dng", "8"]),
                       ["9.dng", "8", "10", "6.dng"],
                       "显式四项优先；其后主版本降序；None 不是版本")
        XCTAssertEqual(DecoderVersionPreference.candidates(in: ["beta", "alpha"]),
                       ["alpha", "beta"], "非数字拼写最后，按字典序")
        XCTAssertEqual(DecoderVersionPreference.candidates(in: ["8", "8", "8.dng"]),
                       ["8", "8.dng"], "重复项只尝试一次")
    }

    /// 反向门 — the old 396 rule was 「只有 9.dng，否则 nil」. These two are exactly the groups that
    /// would go red if that rule came back: the first would answer `9.dng`, the second `nil`.
    func testTheOldOnlyNineDngRuleWouldFailThisTable() {
        XCTAssertNotEqual(DecoderVersionPreference.preferred(in: ["9", "9.dng", "8", "8.dng"]),
                          "9.dng", "旧规则会把裸 9 让给 9.dng")
        XCTAssertNotNil(DecoderVersionPreference.preferred(in: ["8", "8.dng"]),
                        "旧规则会回答 nil，新规则必须选 8")
        XCTAssertNil(DecoderVersionPreference.preferred(in: ["None"]),
                     "513 的哨兵不是候选；退回 nil = 跟随默认")
    }

    // MARK: - 2. read-back

    /// A filter that silently rewrites bare `9` to `8` (the behaviour 396 measured) must move the
    /// choice to `9.dng` **and** leave a reading behind.
    func testARejectedSpellingMovesToTheNextCandidate() {
        let resolution = DecoderVersionPreference.resolve(
            in: ["9", "9.dng", "8", "8.dng"]) { candidate in
                candidate == "9" ? "8" : candidate
            }

        XCTAssertEqual(resolution.selected, "9.dng", "首选被静默改写 ⇒ 换下一个候选")
        XCTAssertEqual(resolution.readBacks.map(\.candidate), ["9", "9.dng"],
                       "回读记录必须包含被拒绝的那一次")
        XCTAssertEqual(resolution.readBacks.first?.effective, "8")
        XCTAssertTrue(resolution.notes.contains("首选 9 被回读成 8"),
                      "读数必须说明「首选 X 被回读成 Y」；实际 \(resolution.notes)")
    }

    func testEveryCandidateRewrittenMeansFollowTheDefault() {
        let resolution = DecoderVersionPreference.resolve(in: ["9", "9.dng"]) { _ in "8" }
        XCTAssertNil(resolution.selected, "全部候选都被改写 ⇒ nil（跟随默认）")
        XCTAssertTrue(resolution.notes.contains("全部候选都被改写，跟随默认"),
                      "实际 \(resolution.notes)")
    }

    /// Real fixture, real `availableVersions`, real assignment and read-back — printed, then checked
    /// against the rule. Today's list contains bare `9` and accepts it; on a body that rewrites it,
    /// the resolution must have moved to the next candidate.
    func testTheRealFileSelectsTheFirstSpellingThatSurvivesReadBack() throws {
        let available = try RAWDecoder.availableVersions(for: Self.fixtureURL)
        let resolution = DecoderVersionPreference.resolve(for: Self.fixtureURL)
        print("554 真文件 supportedDecoderVersions = \(available)")
        print("554 纯规则选中 = \(String(describing: DecoderVersionPreference.preferred(in: available))) "
              + "· 回读后选中 = \(String(describing: resolution.selected))")
        print("554 回读记录 = \(resolution.readBacks.map { "\($0.candidate)→\($0.effective ?? "nil")" }) "
              + "· notes = \(resolution.notes)")

        XCTAssertEqual(resolution.selected, DecoderVersionPreference.preferred(in: available),
                       "本机不该发生改写；若发生，resolve 的记录必须解释")
        let selected = try XCTUnwrap(resolution.selected, "夹具必须至少有一个可用版本")

        let filter = try XCTUnwrap(CIRAWFilter(imageURL: Self.fixtureURL))
        filter.decoderVersion = CIRAWDecoderVersion(rawValue: selected)
        let effective = filter.decoderVersion.rawValue
        print("554 手工赋值 \(selected) → 回读 \(effective)")
        if effective != selected {
            let ordered = DecoderVersionPreference.candidates(in: available)
            let index = try XCTUnwrap(ordered.firstIndex(of: selected))
            XCTAssertLessThan(index + 1, ordered.count,
                              "被改写时必须还有下一个候选；否则 resolve 该回答 nil")
            XCTAssertEqual(resolution.selected, ordered[index + 1],
                           "被改写 ⇒ 选中的必须是下一个候选")
        } else {
            XCTAssertEqual(resolution.readBacks.last?.candidate, selected)
            XCTAssertEqual(resolution.readBacks.last?.effective, selected)
        }
    }

    // MARK: - 3. the denoise product

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters.removeValue(forKey: key) }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    private func makeSession(doc: EditModel) throws -> Asset {
        let stamp = UUID().uuidString
        src = workDir.appendingPathComponent("src-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let url = workDir.appendingPathComponent("S554-\(stamp).\(LibraryLayout.packageExtension)",
                                                 isDirectory: true)
        catalog = try Catalog.create(at: url)
        root = try catalog.ensureRoot(for: src, mode: .reference)
        let name = "IMG_0000.dng"
        try FileManager.default.copyItem(at: Self.fixtureURL,
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

    /// §390's stand-in: `capabilities` answers `image-dng`, the run copies the file through.
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

    func testTheProductStoresThePreferredDecoderVersion() throws {
        var source = EditModel.neutral
        source.light.exposure = 1.25
        source.decoderVersion = "8"
        source.detailSettings = DetailSettings(luminanceNR: 60, colorNR: 40)

        _ = try makeSession(doc: source)
        try installFakeTool()
        let productID = try runDenoiseAndWait()

        let available = try RAWDecoder.availableVersions(for: Self.fixtureURL)
        let product = try catalog.develop(forAsset: productID)
        let productURL = try catalog.fileURL(for: try XCTUnwrap(catalog.asset(id: productID)))

        print("554 端到端 夹具列表 = \(available) "
              + "· 产物 decoderVersion = \(String(describing: product.decoderVersion))")
        // 559 — the product's name carries `denoise`, so the marker pulls it back to the classic
        // family even though the fixture still offers bare `9`.
        XCTAssertEqual(product.decoderVersion, "8",
                       "559 之后降噪产物（文件名带 denoise）按经典解码")

        // 559 — §554's order itself is intact: the **same bytes** under a name without the marker
        // still prefer bare `9`. Without this, the assertion above would silently delete §554.
        let plain = workDir.appendingPathComponent("probe-plain.dng")
        try FileManager.default.copyItem(at: productURL, to: plain)
        let plainResolution = DecoderVersionPreference.resolve(for: plain)
        print("554 无标记拷贝的回读选中 = \(String(describing: plainResolution.selected))")
        XCTAssertEqual(plainResolution.selected, "9",
                       "559 只影响带 denoise 的文件名；无标记文件仍按 §554 选裸 9")

        XCTAssertEqual(product.light.exposure, 1.25, accuracy: 1e-12,
                       "395/396 的继承不能被 554 带坏")
        XCTAssertNil(session.lastDenoiseInheritError)
    }
}
