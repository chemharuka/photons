import XCTest
import GRDB
@testable import PhotonsCatalog

/// The "全部照片 → 文件夹 → 子文件夹" tree: the subtree filter it applies and the counts it shows.
///
/// The four paths here are the whole argument. `day2/b.dng` and `day2/sub/c.dng` belong to `day2`;
/// `day2x/d.dng` does **not**, even though its name starts with the same five characters. A `LIKE
/// 'day2%'` filter (or any prefix comparison that is not segment-aware) swallows it, and the tree
/// then shows a folder's photo count that the photo list can never reproduce.
final class FolderFilterTests: XCTestCase {

    private var tmp: URL!
    private var library: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("f.photonslibrary", isDirectory: true)
        catalog = try Catalog.create(at: library)
        let folder = tmp.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: folder, mode: .reference)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func insert(_ relPath: String, minute: Int = 0) throws -> String {
        let asset = Asset(sourceRootId: root.id,
                          relPath: relPath,
                          filename: (relPath as NSString).lastPathComponent,
                          ext: (relPath as NSString).pathExtension,
                          kind: .raw,
                          size: 1024,
                          mtime: 0,
                          contentHash: UUID().uuidString,
                          captureTime: String(format: "2026-01-01T00:%02d:00Z", minute))
        try catalog.dbQueue.write { db in try asset.insert(db) }
        return asset.id
    }

    private func names(_ filter: AssetFilter) throws -> Set<String> {
        Set(try catalog.assets(filter).map(\.filename))
    }

    /// The library the tree is designed around: a root file, a folder, a nested folder, and a
    /// sibling whose name is a prefix of the folder's.
    private func seedFour() throws {
        try insert("a.dng", minute: 4)
        try insert("day2/b.dng", minute: 3)
        try insert("day2/sub/c.dng", minute: 2)
        try insert("day2x/d.dng", minute: 1)
    }

    // MARK: filter

    /// `day2` means "this folder and everything under it" — and nothing that merely starts with it.
    func testASubtreeFilterIsSegmentAware() throws {
        try seedFour()
        let inDay2 = try names(AssetFilter(sourceRootId: root.id, folderPath: "day2"))
        XCTAssertEqual(inDay2, ["b.dng", "c.dng"],
                       "day2 must hold b and c and must not swallow day2x/d")
        XCTAssertEqual(try names(AssetFilter(sourceRootId: root.id, folderPath: "day2/sub")),
                       ["c.dng"], "a leaf folder holds only its own file")
        XCTAssertEqual(try names(AssetFilter(sourceRootId: root.id, folderPath: "day2x")),
                       ["d.dng"])
    }

    /// `""` (and `nil`, and a stray `/`) is the whole root — the "click the folder, not a subfolder"
    /// case, which must count the same as the root row does.
    func testAnEmptyFolderPathIsTheWholeRoot() throws {
        try seedFour()
        for path in [nil, "", "/", "//"] as [String?] {
            let all = try names(AssetFilter(sourceRootId: root.id, folderPath: path))
            XCTAssertEqual(all, ["a.dng", "b.dng", "c.dng", "d.dng"], "folderPath \(path ?? "nil")")
        }
        XCTAssertEqual(AssetFilter.normalizedFolderPath("/day2//sub/"), "day2/sub")
        XCTAssertNil(AssetFilter.normalizedFolderPath("///"), "slashes only is still the root")
        XCTAssertEqual(AssetFilter.normalizedFolderPath("day2"), "day2")
    }

    /// A folder name is data, not a pattern: `%` and `_` must match themselves.
    func testAFolderNameWithWildcardCharactersIsLiteral() throws {
        try insert("100%_raw/e.dng", minute: 2)
        try insert("100Xraw/f.dng", minute: 1)
        let hits = try names(AssetFilter(sourceRootId: root.id, folderPath: "100%_raw"))
        XCTAssertEqual(hits, ["e.dng"],
                       "a LIKE-based prefix would match 100Xraw/f.dng as well")
    }

    // MARK: aggregation

    /// The shape the tree draws: the root's own node, `day2`, `day2/sub`, `day2x` — no empty folders,
    /// and counts that agree with the filters above.
    func testTheFolderIndexIsWhatTheTreeDraws() throws {
        try seedFour()
        let nodes = try catalog.folders(rootId: root.id)
        XCTAssertEqual(nodes.map(\.path), ["", "day2", "day2/sub", "day2x"],
                       "parents before children, the root's own node first")

        let byPath = Dictionary(uniqueKeysWithValues: nodes.map { ($0.path, $0) })
        XCTAssertEqual(byPath[""]?.total, 4, "clicking the root shows all four")
        XCTAssertEqual(byPath[""]?.direct, 1, "a.dng sits directly in the root")
        XCTAssertEqual(byPath["day2"]?.total, 2, "b and the nested c")
        XCTAssertEqual(byPath["day2"]?.direct, 1, "only b sits directly in day2")
        XCTAssertEqual(byPath["day2/sub"]?.total, 1)
        XCTAssertEqual(byPath["day2/sub"]?.direct, 1)
        XCTAssertEqual(byPath["day2x"]?.total, 1)

        // The same numbers come out of the one-scan index the browser uses.
        let index = try catalog.folderIndex()
        XCTAssertEqual(index[root.id]?.map(\.path), nodes.map(\.path))
        XCTAssertEqual(index[root.id]?.first { $0.path == "day2" }?.total, 2)
    }

    /// Deleted rows are not folders: the tree counts exactly what the photo list can show.
    func testDeletedRowsDoNotGrowTheTree() throws {
        try seedFour()
        let id = try XCTUnwrap(try catalog.assets(AssetFilter()).first { $0.filename == "d.dng" }?.id)
        try catalog.setDeleted(true, forAsset: id)
        let nodes = try catalog.folders(rootId: root.id)
        XCTAssertEqual(nodes.map(\.path), ["", "day2", "day2/sub"])
        XCTAssertEqual(nodes.first?.total, 3)
    }

    /// Two roots, one index, no cross-talk: a path that exists in both keeps its own per-root count.
    func testFolderIndexKeepsRootsApart() throws {
        try seedFour()
        let other = tmp.appendingPathComponent("other/shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherRoot = try catalog.ensureRoot(for: other, mode: .reference)
        let asset = Asset(sourceRootId: otherRoot.id, relPath: "day2/z.dng", filename: "z.dng",
                          ext: "dng", kind: .raw, size: 1, mtime: 0, contentHash: UUID().uuidString)
        try catalog.dbQueue.write { db in try asset.insert(db) }

        let index = try catalog.folderIndex()
        XCTAssertEqual(index[root.id]?.first { $0.path == "day2" }?.total, 2)
        XCTAssertEqual(index[otherRoot.id]?.first { $0.path == "day2" }?.total, 1)
        XCTAssertEqual(try names(AssetFilter(sourceRootId: otherRoot.id, folderPath: "day2")),
                       ["z.dng"])
    }
}
