import XCTest
import Foundation
import GRDB
import PhotonsCore
@testable import PhotonsCatalog

/// 381 — 空文件夹也能移除, the data half.
///
/// 379 gated the removal on `count > 0`. That gate has a blind spot: a **root** row lives in
/// `source_roots`, not in `rel_path`, so it stays in the left column with a `0` after its last
/// photo goes. Removing that row is a row operation (`DELETE FROM source_roots`) and must work
/// with no photos at all.
///
/// ```
/// rootA/day2/a.jpg   rootA/day2/b.jpg   (both later removed)
/// rootB                                  (never had a photo)
/// ```
final class EmptyFolderRemoval381Tests: XCTestCase {

    private var workDir: URL!
    private var library: URL!
    private var catalog: Catalog!
    private var rootA: SourceRoot!
    private var rootB: SourceRoot!
    private var ids: [String] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-381-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        library = workDir.appendingPathComponent("L.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: library)
        rootA = try makeRoot("rootA")
        rootB = try makeRoot("rootB")
        try insert(rootA, "day2/a.jpg", minute: 2)
        try insert(rootA, "day2/b.jpg", minute: 1)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixture

    private func makeRoot(_ name: String) throws -> SourceRoot {
        let dir = workDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try catalog.ensureRoot(for: dir, mode: .reference)
    }

    private func insert(_ root: SourceRoot, _ relPath: String, minute: Int) throws {
        let url = workDir.appendingPathComponent(root.displayName, isDirectory: true)
            .appendingPathComponent(relPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("bytes \(relPath)".utf8).write(to: url)
        let asset = Asset(sourceRootId: root.id,
                          relPath: relPath,
                          filename: (relPath as NSString).lastPathComponent,
                          ext: (relPath as NSString).pathExtension,
                          kind: .jpeg,
                          size: 10,
                          mtime: 0,
                          contentHash: String(format: "%064x", abs(relPath.hashValue)),
                          captureTime: String(format: "2026-01-01T00:%02d:00Z", minute))
        try catalog.dbQueue.write { db in try asset.insert(db) }
        ids.append(asset.id)
    }

    // MARK: - ① a root whose last photo went is still a 0-count row

    func testRemovingTheLastPhotosLeavesTheRootRowAtZero() throws {
        XCTAssertEqual(try catalog.folderAssetCount(rootID: rootA.id, folderPath: ""), 2)

        // Remove the root's whole subtree (the root row's own path is ""): both photos go.
        let report = try catalog.removeFolder(rootID: rootA.id, path: "", thumbnails: nil)
        XCTAssertEqual(report.assets, 2, "the two rows under the root were removed")

        let roots = try catalog.roots().map(\.id)
        print("381 ① roots after emptying rootA = \(roots.count) · contains rootA = \(roots.contains(rootA.id))")
        XCTAssertTrue(roots.contains(rootA.id),
                      "source_roots is independent of the photo count — the row stays, showing 0")
        XCTAssertEqual(try catalog.folderAssetCount(rootID: rootA.id, folderPath: ""), 0,
                       "the row is now the empty folder the user right-clicks")
        XCTAssertTrue(roots.contains(rootB.id), "an unrelated root is not touched")
        XCTAssertEqual(try catalog.assets(AssetFilter(limit: 100)).count, 0,
                       "the photos themselves went with the folder")
    }

    /// A root that never had a photo is the same 0-count row — the menu's input, without a delete.
    func testAFreshlyCreatedRootCountsZeroButStillExists() throws {
        let count = try catalog.folderAssetCount(rootID: rootB.id, folderPath: "")
        print("381 ① rootB count = \(count)")
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try catalog.roots().map(\.id).contains(rootB.id))
    }

    // MARK: - ② removing a 0-count root row

    func testRemovingAnEmptyRootDeletesItsRowAndReportsZero() throws {
        // rootB holds no photo at all — the exact row the pre-381 gate left unreachable.
        let report = try catalog.removeSourceRoot(id: rootB.id, thumbnails: nil)
        print("381 ② DeleteReport.assets = \(report.assets) · roots = \(try catalog.roots().map(\.displayName))")
        XCTAssertEqual(report.assets, 0, "nothing to delete, but still a successful removal")
        XCTAssertEqual(report.history, 0)
        XCTAssertEqual(report.metadata, 0)
        XCTAssertEqual(report.keywords, 0)
        XCTAssertEqual(report.albumEntries, 0)

        let roots = try catalog.roots().map(\.id)
        XCTAssertFalse(roots.contains(rootB.id), "source_roots lost the empty root")
        XCTAssertTrue(roots.contains(rootA.id), "rootA is not affected")
        XCTAssertNil(try catalog.root(id: rootB.id), "the DELETE reached the table")
        XCTAssertEqual(try catalog.assets(AssetFilter(limit: 100)).count, 2,
                       "rootA's two photos are untouched")
        XCTAssertEqual(Set(try catalog.assets(AssetFilter(limit: 100)).map(\.id)), Set(ids))
    }

    /// The emptied root (rootA after ①) behaves the same: the row goes, 0 rows reported.
    func testRemovingAnEmptiedRootStillDeletesTheRow() throws {
        let removed = try catalog.removeFolder(rootID: rootA.id, path: "", thumbnails: nil)
        XCTAssertEqual(removed.assets, 2)

        let report = try catalog.removeSourceRoot(id: rootA.id, thumbnails: nil)
        print("381 ② emptied root DeleteReport.assets = \(report.assets)")
        XCTAssertEqual(report.assets, 0)
        XCTAssertFalse(try catalog.roots().map(\.id).contains(rootA.id))
    }
}
