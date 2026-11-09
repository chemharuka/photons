import XCTest
import AppKit
import CoreGraphics
import ImageIO
import PhotonsCatalog
@testable import PhotonsUI

/// 295 A — 「移出照片库」 / 「移出并删除…」.
///
/// The claims are about **files**, not rows: the first verb must never touch the originals, the second
/// must recycle every original that is still on disk, and a failed recycle must keep that row instead
/// of leaving a "deleted" entry whose file the user still has. Every test injects its own `recycle`
/// closure — a test that called the real `trashItem` would empty into the user's Trash.
final class LibraryRemovalUITests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-library-removal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixture

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

    /// A real reference-mode library with two photos whose originals are on disk.
    @MainActor
    private func makeLibrary() throws -> (session: CatalogSession, files: [URL]) {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("Removal.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        let files = [try makeJPEG(at: src.appendingPathComponent("one.jpg"), seed: 301),
                     try makeJPEG(at: src.appendingPathComponent("two.jpg"), seed: 302)]
        _ = try ImportService(catalog: catalog).run(sources: files, options: ImportOptions())
        let session = CatalogSession()
        try session.open(package)
        XCTAssertEqual(session.assets.count, 2)
        return (session, files)
    }

    private func trashDirectory() throws -> URL {
        let dir = workDir.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func moveToTrash(_ url: URL, into trash: URL) throws {
        try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
    }

    // MARK: - 1. remove keeps the files

    @MainActor
    func testRemoveKeepsTheOriginalOnDisk() throws {
        let (session, files) = try makeLibrary()
        var recycleCalls = 0
        let recycle: (URL) throws -> Void = { _ in recycleCalls += 1 }
        _ = recycle

        let ids = session.assets.map(\.id)
        let report = MissingFilesActions.remove(ids, session: session, window: nil)

        XCTAssertEqual(report?.assets, 2, "both rows removed")
        XCTAssertEqual(session.assets.count, 0)
        for file in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "\(file.lastPathComponent) still there")
        }
        XCTAssertEqual(recycleCalls, 0, "「移出照片库」 never recycles")
    }

    // MARK: - 2. remove-and-delete recycles every original

    @MainActor
    func testRemoveAndDeleteTrashesEveryOriginal() throws {
        let (session, files) = try makeLibrary()
        let trash = try trashDirectory()
        var recycleCalls = 0

        let outcome = session.removeAssetsDeletingFiles(session.assets.map(\.id)) { url in
            recycleCalls += 1
            try self.moveToTrash(url, into: trash)
        }

        XCTAssertEqual(recycleCalls, 2)
        XCTAssertEqual(outcome.filesTrashed, 2)
        XCTAssertEqual(outcome.removed?.assets, 2)
        XCTAssertTrue(outcome.keptIDs.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertEqual(session.assets.count, 0)
        for file in files {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                           "\(file.lastPathComponent) left its place")
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: trash.appendingPathComponent(file.lastPathComponent).path),
                "\(file.lastPathComponent) is recoverable in the Trash")
        }
    }

    // MARK: - 3. the reverse gate: one boolean is the whole difference

    @MainActor
    func testCancellingTheConfirmationChangesNothing() throws {
        let (session, files) = try makeLibrary()
        let trash = try trashDirectory()
        var recycleCalls = 0
        let ids = session.assets.map(\.id)

        let cancelled = MissingFilesActions.removeAndDelete(
            ids, session: session, window: nil,
            confirm: { _, _ in false },
            recycle: { url in
                recycleCalls += 1
                try self.moveToTrash(url, into: trash)
            })
        XCTAssertNil(cancelled, "cancel means no work at all")
        XCTAssertEqual(session.assets.count, 2)
        XCTAssertEqual(recycleCalls, 0)
        for file in files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }

        let done = MissingFilesActions.removeAndDelete(
            ids, session: session, window: nil,
            confirm: { _, _ in true },
            recycle: { url in
                recycleCalls += 1
                try self.moveToTrash(url, into: trash)
            })
        XCTAssertEqual(done?.filesTrashed, 2)
        XCTAssertEqual(session.assets.count, 0)
        XCTAssertEqual(recycleCalls, 2)
        for file in files {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        print("REVERSE GATE: confirm false → rows 2, recycle 0; confirm true → rows 0, recycle 2")
    }

    // MARK: - 4. one failed recycle keeps that row

    @MainActor
    func testARecycleFailureKeepsThatRowAndReportsIt() throws {
        let (session, _) = try makeLibrary()
        let trash = try trashDirectory()
        let first = session.assets[0]
        let second = session.assets[1]
        let firstURL = try XCTUnwrap(session.fileURL(for: first))
        let secondURL = try XCTUnwrap(session.fileURL(for: second))

        let outcome = session.removeAssetsDeletingFiles([first.id, second.id]) { url in
            if url.standardizedFileURL == firstURL.standardizedFileURL {
                throw CocoaError(.fileWriteUnknown)
            }
            try self.moveToTrash(url, into: trash)
        }

        XCTAssertEqual(session.assets.count, 1, "the failed row stayed")
        XCTAssertEqual(session.assets.first?.id, first.id, "the row whose recycle failed is the survivor")
        XCTAssertEqual(outcome.keptIDs, [first.id])
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.filesTrashed, 1)
        XCTAssertEqual(outcome.removed?.assets, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path),
                      "the original whose recycle failed is untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    // MARK: - 5. an original already gone is only a row

    @MainActor
    func testMissingOriginalsAreRemovedWithoutCountingAsTrashed() throws {
        let (session, files) = try makeLibrary()
        let trash = try trashDirectory()
        // The user moved this one in the Finder before asking for 「移出并删除…」.
        try FileManager.default.removeItem(at: files[0])

        let outcome = session.removeAssetsDeletingFiles(session.assets.map(\.id)) { url in
            try self.moveToTrash(url, into: trash)
        }

        XCTAssertEqual(outcome.filesTrashed, 1, "only the file that was still on disk was recycled")
        XCTAssertEqual(session.assets.count, 0)
        XCTAssertTrue(outcome.keptIDs.isEmpty)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: trash.appendingPathComponent(files[1].lastPathComponent).path))
    }
}
