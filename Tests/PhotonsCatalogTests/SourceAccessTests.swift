import XCTest
import GRDB
@testable import PhotonsCatalog

final class SourceAccessTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testRootBookmarkFollowsRenamedFolderOnReopen() throws {
        let library = directory.appendingPathComponent("Test.photonslibrary")
        let photos = directory.appendingPathComponent("Photos")
        let moved = directory.appendingPathComponent("Renamed Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var catalog: Catalog? = try Catalog.create(at: library)
        let root = try catalog!.ensureRoot(for: photos, mode: .reference)
        XCTAssertNotNil(root.bookmark)
        catalog = nil
        try FileManager.default.moveItem(at: photos, to: moved)
        let reopened = try Catalog.open(at: library)
        let restored = try XCTUnwrap(reopened.root(id: root.id))
        XCTAssertEqual(URL(fileURLWithPath: restored.pathHint).resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
        XCTAssertEqual(try reopened.roots().count, 1)
    }

    func testFolderSelectionUpgradesLegacyRootWithoutReimport() throws {
        let catalog = try Catalog.create(at: directory.appendingPathComponent("Test.photonslibrary"))
        let photos = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: photos, mode: .reference)
        try catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE source_roots SET bookmark = NULL WHERE id = ?", arguments: [root.id])
        }
        try catalog.authorizeSourceFolder(photos)
        XCTAssertNotNil(try catalog.root(id: root.id)?.bookmark)
        XCTAssertEqual(try catalog.roots().map(\.id), [root.id])
    }

    func testOfflineFolderKeepsItsRootAndBookmark() throws {
        let library = directory.appendingPathComponent("Test.photonslibrary")
        let photos = directory.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        var catalog: Catalog? = try Catalog.create(at: library)
        let root = try catalog!.ensureRoot(for: photos, mode: .reference)
        catalog = nil
        try FileManager.default.removeItem(at: photos)
        let reopened = try Catalog.open(at: library)
        let restored = try XCTUnwrap(reopened.root(id: root.id))
        XCTAssertEqual(restored.bookmark, root.bookmark)
        XCTAssertEqual(try reopened.refreshRootStatus().first?.status, .offline)
    }
}
