import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 303 — after an edit, the HD thumbnail (`10-bit PQ HEIC`) must refresh for the photo that moved.
///
/// These tests pin the two halves of the fix:
///   · the refresher coalesces a drag into one callback, for the **last** asset;
///   · `CatalogSession` reports every document edit (including undo) with an asset id, and does
///     **not** report `showMask` (view state, not pixels);
///   · the key really changes with the document, so "refresh" means "new key → new HEIC".
@MainActor
final class ThumbnailRefreshTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-thumb-refresh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fake scheduler

    private final class FakeScheduler {
        private(set) var scheduled: [(delay: TimeInterval, action: () -> Void)] = []

        func callAsFunction(_ delay: TimeInterval, _ action: @escaping () -> Void) {
            scheduled.append((delay, action))
        }

        /// Fire every window in order. Superseded windows must be no-ops inside the refresher.
        func fireAll() {
            let actions = scheduled.map(\.action)
            scheduled.removeAll()
            actions.forEach { $0() }
        }
    }

    private func makeRefresher(_ scheduler: FakeScheduler) -> (EditThumbnailRefresher, () -> [String]) {
        var refreshed: [String] = []
        let refresher = EditThumbnailRefresher(delay: 0.25,
                                               scheduler: scheduler.callAsFunction) { id in
            refreshed.append(id)
        }
        return (refresher, { refreshed })
    }

    // MARK: - 1

    func testOneEditRefreshesOnceAfterTheWindow() {
        let scheduler = FakeScheduler()
        let (refresher, refreshed) = makeRefresher(scheduler)

        refresher.noteEdit(assetID: "A")
        XCTAssertEqual(scheduler.scheduled.count, 1, "one edit schedules one window")
        XCTAssertEqual(refreshed(), [], "nothing fires before the window closes")
        XCTAssertEqual(refresher.pendingAssetID, "A")

        scheduler.fireAll()
        XCTAssertEqual(refreshed(), ["A"], "the window fires exactly once, for that asset")
        XCTAssertNil(refresher.pendingAssetID)
    }

    // MARK: - 2

    func testADragRefreshesOnlyOnceWithTheLastAsset() {
        let scheduler = FakeScheduler()
        let (refresher, refreshed) = makeRefresher(scheduler)

        // A drag (or a multi-target paste) bumps the revision repeatedly inside 0.1 s.
        for id in ["A", "B", "C", "D", "E"] {
            refresher.noteEdit(assetID: id)
        }
        XCTAssertEqual(scheduler.scheduled.count, 5, "each tick re-arms the window")
        XCTAssertEqual(refreshed(), [], "no intermediate value is ever rendered")

        scheduler.fireAll()
        XCTAssertEqual(refreshed(), ["E"], "the whole drag produces one refresh, for the last asset")
        XCTAssertNil(refresher.pendingAssetID)
    }

    // MARK: - 3

    func testTheKeyChangesWhenTheDocumentChanges() {
        let neutral = ThumbKey.hd(contentHash: "abc", document: .neutral)
        var editedDocument = EditModel.neutral
        editedDocument.light.exposure = 1.25
        let edited = ThumbKey.hd(contentHash: "abc", document: editedDocument)

        XCTAssertEqual(neutral.spec, .hd)
        XCTAssertNotEqual(neutral.digest, edited.digest,
                          "refresh = new key = a new PQ HEIC, not the bitmap already in memory")
        XCTAssertNotEqual(neutral.keyString, edited.keyString)
        XCTAssertEqual(ThumbKey.hd(contentHash: "abc", document: editedDocument).digest, edited.digest,
                       "the key is a pure function of the document")
    }

    // MARK: - 4

    func testUndoAlsoRefreshes() throws {
        let (session, id) = try makeSession()
        var refreshed: [String] = []
        session.addEditObserver { refreshed.append($0) }

        session.applyEdit { $0.light.exposure = 1.0 }
        XCTAssertEqual(refreshed, [id], "a document edit names the photo it moved")
        XCTAssertTrue(session.commitEdit(label: "曝光"))

        refreshed.removeAll()
        XCTAssertTrue(session.undo())
        XCTAssertEqual(refreshed, [id], "⌘Z moves the document back through the same observer")
    }

    // MARK: - 5

    func testShowMaskDoesNotRefresh() {
        let session = CatalogSession()
        var refreshed: [String] = []
        session.addEditObserver { refreshed.append($0) }
        let revision = session.editRevision

        session.publishViewState { $0.showMaskID = "mask-1" }

        XCTAssertEqual(session.editRevision, revision + 1,
                       "showMask is still a revision bump for the loupe overlay")
        XCTAssertEqual(refreshed, [], "…but it is not a pixel edit: no thumbnail refresh")
    }

    // MARK: - fixture

    private func makeSession() throws -> (CatalogSession, String) {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("Thumb.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        let id = UUID().uuidString
        let name = "IMG_0001.dng"
        try Data([0x00]).write(to: src.appendingPathComponent(name))
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    imported_at, missing)
                VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                        '\(UUID().uuidString)',
                        6000, 4000, 'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                        '2026-11-09T00:00:00Z', 0)
                """)
        }

        let session = CatalogSession(remembersRecentLibrary: false)
        try session.open(package)
        session.selectOnly(id)
        return (session, id)
    }
}
