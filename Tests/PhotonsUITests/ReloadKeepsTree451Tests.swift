import XCTest
import Foundation
import GRDB
import PhotonsCatalog
@testable import PhotonsUI

/// 451 — the direct guard for the user's symptom 「无法筛选文件夹」.
///
/// `reload()` used to answer *any* failure with `roots = []` / `assets = []`, which leaves the left
/// browser with only 「全部照片」 and no folder row to click — until the next successful reload (the
/// one a finished denoise runs), which is exactly the shape of "必须重新降噪完成".
///
/// The reverse gate is the point: change the `catch` back to `roots = []` and this test fails.
@MainActor
final class ReloadKeepsTree451Tests: XCTestCase {
    private var tmp: URL!
    private var library: URL!
    private var catalog: Catalog!
    private var root: SourceRoot!
    private var session: CatalogSession!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-451-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("L.\(LibraryLayout.packageExtension)", isDirectory: true)

        catalog = try Catalog.create(at: library)
        let shoot = tmp.appendingPathComponent("shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: shoot.appendingPathComponent("day2", isDirectory: true),
                                                withIntermediateDirectories: true)
        root = try catalog.ensureRoot(for: shoot, mode: .reference)
        try catalog.dbQueue.write { db in
            let asset = Asset(sourceRootId: root.id,
                              relPath: "day2/a.dng",
                              filename: "a.dng",
                              ext: "dng",
                              kind: .raw,
                              size: 1024,
                              mtime: 0,
                              contentHash: UUID().uuidString)
            try asset.insert(db)
        }

        session = CatalogSession(remembersRecentLibrary: false)
        try session.open(library)
    }

    override func tearDownWithError() throws {
        session = nil
        catalog = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    func testFailedReloadKeepsTheLastGoodTree() throws {
        XCTAssertFalse(session.roots.isEmpty, "precondition: the first load succeeded")
        XCTAssertFalse(session.folderNodes[root.id, default: []].isEmpty)
        XCTAssertEqual(session.assets.count, 1)

        session.reloadRootsLoader = {
            throw NSError(domain: "photons-451", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "database is locked"])
        }
        session.reload()

        XCTAssertFalse(session.roots.isEmpty, "a failed reload must not empty the folder tree")
        XCTAssertEqual(session.roots.map(\.id), [root.id])
        XCTAssertFalse(session.folderNodes[root.id, default: []].isEmpty,
                       "the folder rows must survive a failed reload")
        XCTAssertEqual(session.assets.count, 1, "the grid must not be emptied either")
        XCTAssertNotNil(session.lastPersistError)
        XCTAssertNotNil(session.loadError)
    }

    /// The guard is about the *last good* tree: a session that never loaded anything is still
    /// allowed to have no roots.
    func testFailedFirstReloadOnEmptySessionStaysEmpty() throws {
        let fresh = CatalogSession(remembersRecentLibrary: false)
        // No open() at all: `reload()` returns before touching the catalog, so the tree is empty
        // and there is no error to report.
        fresh.reload()
        XCTAssertTrue(fresh.roots.isEmpty)
        XCTAssertNil(fresh.lastPersistError)
    }
}
