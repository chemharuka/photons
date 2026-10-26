import XCTest
import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import PhotonsCatalog
@testable import PhotonsUI

/// 「原文件已移动」 — the UI half.
///
/// Four claims, each with a number or a string instead of an adjective:
///   · the words appear where they must and nowhere else (grid card, filmstrip cell, inspector row);
///   · the context menu is enabled exactly when the selection contains a missing entry;
///   · the recursive name search resolves one match, several same-name candidates (by content hash),
///     a different capitalisation, and nothing at all;
///   · deleting from the library leaves `session.assets.count` equal to what `reload()` returns.
final class MissingFilesUITests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-missing-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    @discardableResult
    private func makeJPEG(at url: URL, seed: Int) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let w = 20, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i * 4] = UInt8((i &* 11 &+ seed &* 41) & 0xFF)
            pixels[i * 4 + 1] = UInt8((i &* 5 &+ seed &* 23) & 0xFF)
            pixels[i * 4 + 2] = UInt8((i &+ seed &* 7) & 0xFF)
            pixels[i * 4 + 3] = 255
        }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("cannot write JPEG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("cannot finalize JPEG") }
        return url
    }

    /// A real library with one photo whose file was moved away and one whose file is where it says.
    @MainActor
    private func makeSession() throws -> (session: CatalogSession, missing: Asset, present: Asset, package: URL) {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("UI.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        let goneURL = try makeJPEG(at: src.appendingPathComponent("moved.jpg"), seed: 101)
        let hereURL = try makeJPEG(at: src.appendingPathComponent("here.jpg"), seed: 202)
        _ = try ImportService(catalog: catalog).run(sources: [goneURL, hereURL], options: ImportOptions())

        let goneHash = try FileHasher.sha256(of: goneURL)
        let hereHash = try FileHasher.sha256(of: hereURL)
        let missing = try XCTUnwrap(try catalog.asset(contentHash: goneHash))
        let present = try XCTUnwrap(try catalog.asset(contentHash: hereHash))

        // The user moved the file in the Finder.
        try FileManager.default.removeItem(at: goneURL)
        _ = try catalog.refreshAvailability()

        let session = CatalogSession()
        try session.open(package)
        // Anchor the missing photo so the inspector and the menu talk about it.
        session.selectOnly(missing.id)
        return (session, try XCTUnwrap(try catalog.asset(id: missing.id)),
                try XCTUnwrap(try catalog.asset(id: present.id)), package)
    }

    // MARK: - 1. the badge / the row

    /// The grid card carries the words, as a string and as paint.
    func testGridCardExposesAndDrawsTheMovedLabel() throws {
        let missing = Self.asset(isMissing: true)
        let present = Self.asset(isMissing: false)

        let card = AssetCardView()
        card.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        card.asset = missing
        XCTAssertEqual(card.missingLabel, "原文件已移动")
        XCTAssertNil(card.lastDrawnMissingLabel, "nothing is painted before the first draw")

        Self.paint(card)
        XCTAssertEqual(card.lastDrawnMissingLabel, "原文件已移动", "the badge was painted, not just computed")
        XCTAssertTrue(card.lastDrawnBadges.contains("missing"))

        card.asset = present
        XCTAssertNil(card.missingLabel, "a healthy photo says nothing")
        Self.paint(card)
        XCTAssertNil(card.lastDrawnMissingLabel)
        XCTAssertFalse(card.lastDrawnBadges.contains("missing"))
        print("GRID badge: missing → \"\(MissingFileText.moved)\", present → none")
    }

    /// The filmstrip cell carries the same words (compact paint, same constant).
    func testFilmstripCellExposesAndDrawsTheMovedLabel() throws {
        let card = FilmstripCard()
        card.frame = NSRect(x: 0, y: 0, width: 111, height: 69)
        card.asset = Self.asset(isMissing: true)
        XCTAssertEqual(card.missingLabel, "原文件已移动")
        Self.paint(card)
        XCTAssertEqual(card.lastDrawnMissingLabel, "原文件已移动")

        card.asset = Self.asset(isMissing: false)
        XCTAssertNil(card.missingLabel)
        Self.paint(card)
        XCTAssertNil(card.lastDrawnMissingLabel)
    }

    /// The inspector shows one extra line, and only for a moved original.
    @MainActor
    func testInspectorShowsTheRowOnlyWhileTheAnchorIsMissing() throws {
        let (session, missing, present, _) = try makeSession()

        // Missing anchor → the row is in the view tree, with the shared text.
        session.selectOnly(missing.id)
        let missingRows = Self.noticeRows(in: try Self.host(session: session))
        XCTAssertEqual(missingRows.count, 1, "exactly one 「原文件已移动」 row")
        XCTAssertEqual(missingRows.first?.text, MissingFileText.moved)

        // Healthy anchor → no row at all (not an empty one).
        session.selectOnly(present.id)
        let presentRows = Self.noticeRows(in: try Self.host(session: session))
        XCTAssertEqual(presentRows.count, 0)
        print("INSPECTOR row: missing anchor → \(missingRows.count) row(s) \"\(missingRows.first?.text ?? "-")\","
              + " present anchor → \(presentRows.count)")
    }

    // MARK: - 2. the menu

    /// Enabled exactly when the selection contains something missing.
    func testMenuIsEnabledOnlyWhenTheSelectionHasSomethingMissing() {
        let menu = AssetContextMenu()

        var state = menu.update(selectedIDs: ["a"], missingIDs: ["a"])
        XCTAssertTrue(state.canDelete)
        XCTAssertTrue(state.canFindLost)
        XCTAssertTrue(menu.deleteItem.isEnabled)
        XCTAssertTrue(menu.findItem.isEnabled)
        XCTAssertEqual(menu.targetIDs, ["a"], "both verbs act on the missing subset")
        XCTAssertEqual(menu.deleteItem.title, MissingFileText.deleteMenuTitle)
        XCTAssertEqual(menu.findItem.title, MissingFileText.findMenuTitle)

        // A healthy selection: nothing to delete, nothing to search for.
        state = menu.update(selectedIDs: ["b", "c"], missingIDs: [])
        XCTAssertFalse(state.canDelete)
        XCTAssertFalse(state.canFindLost)
        XCTAssertFalse(menu.deleteItem.isEnabled)
        XCTAssertFalse(menu.findItem.isEnabled)

        // Nothing selected at all.
        state = menu.update(selectedIDs: [], missingIDs: [])
        XCTAssertFalse(state.canDelete)
        XCTAssertFalse(menu.findItem.isEnabled)

        // A mixed selection: the verbs act on the missing one only.
        state = menu.update(selectedIDs: ["b", "m1", "m2"], missingIDs: ["m1", "m2"])
        XCTAssertEqual(state.missingCount, 2)
        XCTAssertEqual(menu.targetIDs, ["m1", "m2"])
        XCTAssertTrue(menu.deleteItem.isEnabled)

        // And the rule on its own, independent of any menu object.
        XCTAssertTrue(AssetContextMenu.state(hasSelection: true, missingCount: 1).canDelete)
        XCTAssertFalse(AssetContextMenu.state(hasSelection: false, missingCount: 1).canDelete,
                       "a missing row that is not selected is not a target")
    }

    /// The confirmation text names both halves of the promise: the records go, the files do not.
    func testConfirmationTextCountsAndReassures() {
        let text = MissingFileText.deleteConfirmMessage(count: 3)
        XCTAssertTrue(text.contains("3"))
        XCTAssertTrue(text.contains("修改记录"))
        XCTAssertTrue(text.contains("原文件不受影响"))
    }

    // MARK: - 3. the search (pure)

    /// One file with the right name and the right bytes → one match.
    func testSearchFindsASingleSameNamedFile() throws {
        let folder = workDir.appendingPathComponent("search1", isDirectory: true)
        let original = try makeJPEG(at: folder.appendingPathComponent("a.jpg"), seed: 1)
        let nested = folder.appendingPathComponent("2026/Trip", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: nested.appendingPathComponent("a.jpg"))

        let hash = try FileHasher.sha256(of: nested.appendingPathComponent("a.jpg"))
        let outcome = LostFileFinder.find(folder: folder,
                                          targets: [.init(assetID: "a1", filename: "a.jpg", contentHash: hash)])
        XCTAssertEqual(outcome.matches.count, 1)
        XCTAssertEqual(outcome.matches.first?.assetID, "a1")
        XCTAssertEqual(outcome.matches.first?.url.lastPathComponent, "a.jpg")
        XCTAssertTrue(outcome.unmatched.isEmpty)
        XCTAssertTrue(outcome.rejected.isEmpty)
        XCTAssertEqual(outcome.scannedFiles, 1, "the recursive walk found the nested file")
    }

    /// Two files with the same name: only the one whose bytes match is the photo.
    func testSearchUsesTheContentHashToChooseBetweenSameNamedFiles() throws {
        let folder = workDir.appendingPathComponent("search2", isDirectory: true)
        let wanted = try makeJPEG(at: folder.appendingPathComponent("disk1/shot.jpg"), seed: 7)
        try makeJPEG(at: folder.appendingPathComponent("disk2/shot.jpg"), seed: 8)

        let hash = try FileHasher.sha256(of: wanted)
        let outcome = LostFileFinder.find(folder: folder,
                                          targets: [.init(assetID: "s1", filename: "shot.jpg", contentHash: hash)])
        XCTAssertEqual(outcome.matches.count, 1)
        XCTAssertEqual(outcome.matches.first?.url.resolvingSymlinksInPath().path,
                       wanted.resolvingSymlinksInPath().path,
                       "the matching bytes won, not the first listing")
        XCTAssertTrue(outcome.rejected.isEmpty)
    }

    /// A different capitalisation is still the same name (case-insensitive, as the Finder is).
    func testSearchIsCaseInsensitive() throws {
        let folder = workDir.appendingPathComponent("search3", isDirectory: true)
        let file = try makeJPEG(at: folder.appendingPathComponent("DSC_0042.JPG"), seed: 9)
        let hash = try FileHasher.sha256(of: file)
        let outcome = LostFileFinder.find(folder: folder,
                                          targets: [.init(assetID: "c1", filename: "dsc_0042.jpg", contentHash: hash)])
        XCTAssertEqual(outcome.matches.count, 1)
        XCTAssertEqual(outcome.matches.first?.filename, "DSC_0042.JPG")
    }

    /// Not there → not in the matches, and not silently "found".
    func testSearchReportsMissingTargetsAndRejectsWrongBytes() throws {
        let folder = workDir.appendingPathComponent("search4", isDirectory: true)
        let impostor = try makeJPEG(at: folder.appendingPathComponent("b.jpg"), seed: 11)
        let absentHash = String(repeating: "0", count: 64)
        let wrongHash = try FileHasher.sha256(of: impostor) + "x"

        let outcome = LostFileFinder.find(folder: folder, targets: [
            .init(assetID: "absent", filename: "nowhere.dng", contentHash: absentHash),
            .init(assetID: "wrong", filename: "B.JPG", contentHash: wrongHash),
        ])
        XCTAssertTrue(outcome.matches.isEmpty)
        XCTAssertEqual(outcome.unmatched, ["absent"], "no file with that name anywhere")
        XCTAssertEqual(outcome.rejected, ["wrong"], "the name matched but the bytes did not")
    }

    /// The pure resolver takes an index, so the four rules can be checked without a filesystem at all.
    func testResolverIsPureOverAnIndex() {
        let url = URL(fileURLWithPath: "/tmp/x/shot.jpg")
        let index = ["shot.jpg": [url]]
        let outcome = LostFileFinder.resolve(index: index,
                                            targets: [.init(assetID: "p", filename: "shot.jpg", contentHash: "abc")],
                                            hashing: { _ in "abc" })
        XCTAssertEqual(outcome.matches.first?.assetID, "p")
        XCTAssertEqual(outcome.scannedFiles, 1)
    }

    // MARK: - 4. delete → reload

    /// Deleting through the session lands in the same place a `reload()` reads from.
    @MainActor
    func testDeletingAMissingEntryMatchesWhatReloadReports() throws {
        let (session, missing, present, package) = try makeSession()
        XCTAssertEqual(session.assets.count, 2)
        XCTAssertEqual(session.missingAssets.map(\.id), [missing.id])

        let report = session.deleteAssets([missing.id])
        XCTAssertEqual(report?.assets, 1, "one row removed")
        XCTAssertEqual(session.assets.count, 1, "the grid lost exactly the deleted row")
        XCTAssertEqual(session.assets.first?.id, present.id)

        // The same question asked of a *fresh* handle: the count is the database's, not the array's.
        let reopened = try Catalog.open(at: package)
        XCTAssertEqual(try reopened.assets(AssetFilter()).count, 1)
        XCTAssertEqual(try reopened.asset(id: missing.id), nil)
        XCTAssertEqual(try reopened.rowCount("asset_history", assetIDs: [missing.id]), 0)

        // And the surviving row still resolves to a real file: deletion is a library operation, not
        // a file operation.
        XCTAssertTrue(FileManager.default.fileExists(atPath: try reopened.fileURL(for: present).path))
        print("DELETE→reload: session.assets 2 → \(session.assets.count),"
              + " catalog rows \(try reopened.assets(AssetFilter()).count), report \(report?.summary ?? "-")")
    }

    // MARK: - helpers

    private static func asset(isMissing: Bool) -> Asset {
        Asset(sourceRootId: "r1", relPath: "a.jpg", filename: "a.jpg", ext: "jpg", kind: .jpeg,
              size: 100, mtime: 0, contentHash: UUID().uuidString, missing: isMissing)
    }

    /// Draw a view into an offscreen bitmap — the same `draw(_:)` the window runs, without a window.
    private static func paint(_ view: NSView) {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                   pixelsWide: Int(max(1, view.bounds.width)),
                                   pixelsHigh: Int(max(1, view.bounds.height)),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    @MainActor
    private static func host(session: CatalogSession) throws -> NSView {
        let host = NSHostingView(rootView: InspectorView(session: session))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 800)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        return host
    }

    private static func noticeRows(in view: NSView) -> [MissingFileNoticeView] {
        var found: [MissingFileNoticeView] = []
        if let row = view as? MissingFileNoticeView { found.append(row) }
        for sub in view.subviews { found += noticeRows(in: sub) }
        return found
    }
}
