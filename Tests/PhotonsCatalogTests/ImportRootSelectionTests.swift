import XCTest
import GRDB
@testable import PhotonsCatalog

/// Two folders on one disk are **two reference roots**.
///
/// The bug this pins down: `ensureRoot` matched an existing root by volume UUID, so the first root a
/// library had absorbed every later folder on the same disk. `rel_path` then could not be made
/// relative to that root, `relativePath` fell back to the bare filename, and the row pointed at a
/// file that was never there — the asset never got a thumbnail and never decoded, with no error
/// anywhere. Importing `~/Desktop/US` into a library that already held `~/Desktop/test` is exactly
/// that case.
final class ImportRootSelectionTests: XCTestCase {

    private var tmp: URL!
    private var library: URL!
    private var catalog: Catalog!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("photons-roots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        library = tmp.appendingPathComponent("t.photonslibrary", isDirectory: true)
        catalog = try Catalog.create(at: library)
    }

    override func tearDownWithError() throws {
        catalog = nil
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeDNG(_ url: URL, seed: UInt8) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 4096)
        for i in 0..<bytes.count { bytes[i] = UInt8((i &* 31 &+ Int(seed)) & 0xFF) }
        try Data(bytes).write(to: url)
    }

    /// The reported bug, in one test: folder B must not land in folder A's root.
    func testASecondFolderGetsItsOwnReferenceRoot() throws {
        let test = tmp.appendingPathComponent("Desktop/test", isDirectory: true)
        let us = tmp.appendingPathComponent("Desktop/US", isDirectory: true)
        try makeDNG(test.appendingPathComponent("L100.dng"), seed: 1)
        try makeDNG(us.appendingPathComponent("_1274394.dng"), seed: 2)

        let first = try ImportService(catalog: catalog).run(sources: [test], options: ImportOptions(mode: .reference))
        XCTAssertEqual(first.added, 1)
        let second = try ImportService(catalog: catalog).run(sources: [us], options: ImportOptions(mode: .reference))
        XCTAssertEqual(second.added, 1, "a second folder on the same disk is a second root, not a duplicate")

        let roots = try catalog.roots()
        XCTAssertEqual(roots.count, 2, "one root per folder: \(roots.map(\.pathHint))")
        let usRoot = try XCTUnwrap(roots.first { $0.pathHint == us.standardizedFileURL.path })

        let asset = try XCTUnwrap(try catalog.assets(AssetFilter()).first { $0.filename == "_1274394.dng" })
        XCTAssertEqual(asset.sourceRootId, usRoot.id)
        XCTAssertEqual(asset.relPath, "_1274394.dng")

        // The row must resolve to a file that exists — this is what "no thumbnail, no decode" was.
        let url = try catalog.fileURL(for: asset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "row resolves to \(url.path)")
        XCTAssertEqual(url.standardizedFileURL.path, us.appendingPathComponent("_1274394.dng").standardizedFileURL.path)
    }

    /// Sub-directories stay inside the folder that was chosen; the deepest containing root wins.
    func testAFileInASubfolderKeepsTheParentsRoot() throws {
        let folder = tmp.appendingPathComponent("shoot", isDirectory: true)
        try makeDNG(folder.appendingPathComponent("a.dng"), seed: 3)
        try makeDNG(folder.appendingPathComponent("day2/b.dng"), seed: 4)

        let summary = try ImportService(catalog: catalog).run(sources: [folder],
                                                             options: ImportOptions(mode: .reference))
        XCTAssertEqual(summary.added, 2)
        let roots = try catalog.roots()
        XCTAssertEqual(roots.count, 1, "the subfolder is not a root of its own")
        for asset in try catalog.assets(AssetFilter()) {
            let url = try catalog.fileURL(for: asset)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(asset.relPath) → \(url.path)")
        }
        let nested = try XCTUnwrap(try catalog.assets(AssetFilter()).first { $0.filename == "b.dng" })
        XCTAssertEqual(nested.relPath, "day2/b.dng")
    }

    /// Component-aware containment: `/a/bc` is not inside `/a/b`.
    func testContainmentIsComponentAware() {
        XCTAssertTrue(Catalog.path("/a/b", contains: "/a/b"))
        XCTAssertTrue(Catalog.path("/a/b", contains: "/a/b/c.dng"))
        XCTAssertFalse(Catalog.path("/a/b", contains: "/a/bc/d.dng"))
    }
}
