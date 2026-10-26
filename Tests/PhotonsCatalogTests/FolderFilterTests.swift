import XCTest
import GRDB
@testable import PhotonsCatalog

/// The "全部照片 → 文件夹 → 子文件夹" tree: the subtree filter it applies and the counts it shows.
///
/// The four paths here are the whole argument. `day2/b.dng` and `day2/sub/c.dng` belong to `day2`;
/// `day2x/d.dng` does **not**, even though its name starts with the same five characters. A `LIKE
/// 'day2%'` filter (or any prefix comparison that is not segment-aware) swallows it, and the tree
/// then shows a folder's photo count that the photo list can never reproduce.
///
/// 021 B turns the one `folderPath` into a **set** of `FolderSelection`, so the tests below are the
/// six-row semantics table of the spec: nothing/全部照片 = the library, one root, a root's subtree,
/// parent + child (union, no duplicate rows), `day2` + `day2x` (component-aware), and two roots at
/// once. Every case is one `WHERE (…) OR (…)`, parameters bound — never a built string.
final class FolderFilterTests: XCTestCase {

    private var tmp: URL!
    private var library: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!
    private var otherRoot: SourceRoot!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("f.photonslibrary", isDirectory: true)
        catalog = try Catalog.create(at: library)
        let folder = tmp.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: folder, mode: .reference)
        let other = tmp.appendingPathComponent("other/shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        otherRoot = try catalog.ensureRoot(for: other, mode: .reference)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    @discardableResult
    private func insert(_ relPath: String, minute: Int = 0, root: SourceRoot? = nil) throws -> String {
        let target: SourceRoot = root ?? self.root
        let asset = Asset(sourceRootId: target.id,
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

    private func rows(_ filter: AssetFilter) throws -> [String] {
        try catalog.assets(filter).map(\.filename)
    }

    /// The library the tree is designed around: a root file, a folder, a nested folder, and a
    /// sibling whose name is a prefix of the folder's.
    private func seedFour() throws {
        try insert("a.dng", minute: 4)
        try insert("day2/b.dng", minute: 3)
        try insert("day2/sub/c.dng", minute: 2)
        try insert("day2x/d.dng", minute: 1)
    }

    private func day2(_ rootID: String? = nil, _ path: String? = "day2") -> FolderSelection {
        FolderSelection(rootId: rootID ?? root.id, path: path)
    }

    // MARK: the six ways a selection can read

    /// 1. Nothing selected — or 「全部照片」 — is the whole library, across every root.
    func testNoSelectionAndAllPhotosAreBothTheWholeLibrary() throws {
        try seedFour()
        try insert("night/e.dng", minute: 0, root: otherRoot)

        XCTAssertEqual(try names(AssetFilter()), ["a.dng", "b.dng", "c.dng", "d.dng", "e.dng"],
                       "an empty folder set adds no constraint")
        XCTAssertEqual(try names(AssetFilter(folders: [])).count, 5)
        XCTAssertEqual(try names(AssetFilter(folders: [FolderSelection(rootId: nil)])).count, 5,
                       "「全部照片」 is the library, not a root")
        XCTAssertEqual(try names(AssetFilter(folders: [FolderSelection(rootId: nil, path: "")])).count, 5,
                       "a stray empty path on 「全部照片」 is still the library")
    }

    /// 2. One root: `(rootId, nil)` is that root's every photo, whatever folder it sits in.
    func testOneRootSelectsThatRootOnly() throws {
        try seedFour()
        try insert("night/e.dng", minute: 0, root: otherRoot)

        let mine = try names(AssetFilter(folders: [FolderSelection(rootId: root.id)]))
        XCTAssertEqual(mine, ["a.dng", "b.dng", "c.dng", "d.dng"])
        XCTAssertEqual(try names(AssetFilter(folders: [FolderSelection(rootId: otherRoot.id)])), ["e.dng"],
                       "the second root is a separate clause, never a prefix of the first")
        XCTAssertEqual(try names(AssetFilter(folders: [FolderSelection(rootId: root.id, path: "")])),
                       ["a.dng", "b.dng", "c.dng", "d.dng"], "an empty path is the root itself")
    }

    /// 3. `day2` + `day2/sub` — the child is inside the parent, so the union is `day2`, and a photo
    /// that matches both clauses still comes back **once** (a `WHERE … OR …`, not a join).
    func testAParentAndItsChildUnionWithoutDuplicateRows() throws {
        try seedFour()
        let both = try rows(AssetFilter(folders: [day2(), day2(nil, "day2/sub")]))
        XCTAssertEqual(Set(both), ["b.dng", "c.dng"])
        XCTAssertEqual(both.count, 2, "c.dng matches both clauses and must not be listed twice: \(both)")
        XCTAssertEqual(try rows(AssetFilter(folders: [day2()])).count, 2,
                       "the parent alone already holds the child's photo")
    }

    /// 4. `day2` + `day2x` — a union, and `day2x` is **not** swallowed by `day2`.
    func testASiblingFolderNamedLikeAPrefixIsNotSwallowed() throws {
        try seedFour()
        XCTAssertEqual(try names(AssetFilter(folders: [day2(), day2(nil, "day2x")])),
                       ["b.dng", "c.dng", "d.dng"],
                       "the prefix compared against rel_path always ends in /")
        XCTAssertEqual(try names(AssetFilter(folders: [day2()])), ["b.dng", "c.dng"])
        XCTAssertEqual(try names(AssetFilter(folders: [day2(nil, "day2x")])), ["d.dng"])
    }

    /// 5. Two roots, one subfolder each: the union crosses roots (the old single `sourceRootId`
    /// could not even express this).
    func testSelectionsAcrossRootsAreAUnion() throws {
        try seedFour()
        try insert("day2/z.dng", minute: 0, root: otherRoot)
        try insert("day3/y.dng", minute: 0, root: otherRoot)

        XCTAssertEqual(try names(AssetFilter(folders: [day2(),
                                                       FolderSelection(rootId: otherRoot.id, path: "day2")])),
                       ["b.dng", "c.dng", "z.dng"],
                       "same path, two roots: each clause carries its own root")
        XCTAssertEqual(try names(AssetFilter(folders: [day2(),
                                                       FolderSelection(rootId: otherRoot.id)])),
                       ["b.dng", "c.dng", "z.dng", "y.dng"],
                       "a whole root and a subtree in another root")
    }

    /// 6. 「全部照片」 together with a folder: the whole library, the folder ignored (021 §B — the
    /// catalog's contract; the browser also normalises the combination away before it gets here).
    func testAllPhotosInTheSetWinsAndTheOthersAreIgnored() throws {
        try seedFour()
        XCTAssertEqual(try names(AssetFilter(folders: [FolderSelection(rootId: nil), day2()])),
                       ["a.dng", "b.dng", "c.dng", "d.dng"])
    }

    /// The query stays a query: `limit` still caps the *union*, and ordering is unchanged.
    func testLimitStillCapsTheUnion() throws {
        try seedFour()
        let filter = AssetFilter(limit: 2, folders: [day2(), day2(nil, "day2x")])
        XCTAssertEqual(try catalog.assets(filter).count, 2)
        XCTAssertEqual(try catalog.assets(AssetFilter(limit: 1, folders: [day2()])).first?.filename,
                       "b.dng", "newest first inside the union too")
    }

    // MARK: literal, segment-safe paths

    /// A folder name is data, not a pattern: `%` and `_` must match themselves, and they reach the
    /// query as bound parameters (`instr(rel_path, ?)`), never as SQL text.
    func testAFolderNameWithWildcardCharactersIsLiteral() throws {
        try insert("100%_raw/e.dng", minute: 2)
        try insert("100Xraw/f.dng", minute: 1)
        XCTAssertEqual(try names(AssetFilter(folders: [FolderSelection(rootId: root.id, path: "100%_raw")])),
                       ["e.dng"], "a LIKE-based prefix would match 100Xraw/f.dng as well")
        XCTAssertEqual(try names(AssetFilter(folders: [FolderSelection(rootId: root.id, path: "100%_raw"),
                                                       FolderSelection(rootId: root.id, path: "100Xraw")])),
                       ["e.dng", "f.dng"], "and two such names are still two clauses")
    }

    func testThePathNormaliserIsTheOneTheTreeHandsOut() throws {
        XCTAssertEqual(AssetFilter.normalizedFolderPath("/day2//sub/"), "day2/sub")
        XCTAssertNil(AssetFilter.normalizedFolderPath("///"), "slashes only is still the root")
        XCTAssertEqual(AssetFilter.normalizedFolderPath("day2"), "day2")
        // The selection's own canonical form: same key for the same row, whatever the slashes.
        XCTAssertEqual(FolderSelection(rootId: "r", path: "/day2/sub/").key,
                       FolderSelection(rootId: "r", path: "day2/sub").key)
        XCTAssertEqual(FolderSelection(rootId: nil).key, FolderSelection(rootId: nil, path: "").key)
    }

    /// The seeded library again, now asking for `day2/sub` alone: a leaf folder holds only its own
    /// file, and the rootless 「全部照片」 is not a wildcard for a missing root.
    func testALeafFolderAndAnUnknownRoot() throws {
        try seedFour()
        XCTAssertEqual(try names(AssetFilter(folders: [day2(nil, "day2/sub")])), ["c.dng"])
        XCTAssertEqual(try names(AssetFilter(folders: [FolderSelection(rootId: "no-such-root", path: "day2")])),
                       [], "an id that names no root matches nothing, it does not fall back to everything")
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
        XCTAssertEqual(try names(AssetFilter(folders: [day2(nil, "day2x")])), [],
                       "the deleted photo is gone from the filter too")
    }

    /// Two roots, one index, no cross-talk: a path that exists in both keeps its own per-root count.
    func testFolderIndexKeepsRootsApart() throws {
        try seedFour()
        try insert("day2/z.dng", minute: 0, root: otherRoot)

        let index = try catalog.folderIndex()
        XCTAssertEqual(index[root.id]?.first { $0.path == "day2" }?.total, 2)
        XCTAssertEqual(index[otherRoot.id]?.first { $0.path == "day2" }?.total, 1)
        XCTAssertEqual(try names(AssetFilter(folders: [FolderSelection(rootId: otherRoot.id, path: "day2")])),
                       ["z.dng"])
    }
}
