import XCTest
import AppKit
import GRDB
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsCatalog
@testable import PhotonsUI

/// 165 — ⌘V / ⌘Z must leave the low-resolution whole picture on screen.
///
/// The bug was the gap between two rules that are each correct on their own:
///
///   · 039: an *edit* only marks the backdrop stale; the next pointer entry pays for the new one;
///   · 144: only the white-balance / detail settles (and a cancelled preview) explicitly ask for a
///     replacement.
///
/// A paste and an undo are commands, not slider ticks: the document moves with the pointer sitting
/// on the inspector, and nobody asks for the bottom image again. The assertions below are the three
/// acceptance paths from the spec:
///
///   ① paste into the open document → the cached digest is the new document's, within 200 ms,
///      with no pointer entry and no photo switch;
///   ② paste into three **unopened** photos → opening one makes exactly one backdrop; the other
///      two are never rendered;
///   ③ paste → undo → paste → undo, four times → the digest names the document after every step;
///   ④ the 144 preview marker still wins while a white-balance drag is live (paste during a drag is
///      the boundary case, and a preview backdrop must never be adopted as the settled document).
@MainActor
final class BackdropPasteTests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-backdrop-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func documentA() -> EditModel {
        var a = EditModel.neutral
        a.light.exposure = 1.2
        a.light.contrast = 15
        return a
    }

    private func documentB() -> EditModel {
        var b = EditModel.neutral
        b.light.exposure = -0.4
        b.light.contrast = 0
        return b
    }

    /// A real library whose photos all point at one hard link of the RAW fixture (one file on disk,
    /// a row per photo with its own identity). Everything else is the app's path: `Catalog.create`,
    /// `ensureRoot`, `CatalogSession.open`, `selectOnly`, the real `LoupeController`.
    ///
    /// Rows are inserted with SQL because the fixture must not be imported five times: `ImportService`
    /// dedupes by content hash, which is exactly right for the app and wrong for "five photos".
    private func makeLibrary(photoCount: Int) throws
        -> (session: CatalogSession, catalog: Catalog, ids: [String]) {
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let raw = try rawFixture()

        let package = workDir.appendingPathComponent("P.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        var ids: [String] = []
        for i in 0 ..< photoCount {
            // One file per row: `(source_root_id, rel_path)` is unique, and a link keeps the 63 MB
            // fixture on disk once while every row still resolves to a real, decodable photo.
            let name = "photo-\(i).dng"
            let dest = src.appendingPathComponent(name)
            do {
                try FileManager.default.createSymbolicLink(atPath: dest.path,
                                                           withDestinationPath: raw.path)
            } catch {
                // Symbolic link failed (some sandboxes): copy. The fixture is large, so a link wins.
                try FileManager.default.copyItem(at: raw, to: dest)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path),
                          "photo \(i)'s file is not there")

            let edit = i == 0 ? documentA() : documentB()
            let blob = try Catalog.encode(edit)
            let asset = Asset(sourceRootId: root.id,
                              relPath: name,
                              filename: name,
                              ext: "dng",
                              kind: .raw,
                              size: 1, mtime: 0,
                              contentHash: "fixture-\(i)-\(UUID().uuidString)",
                              width: 6000,
                              height: 4000,
                              developJson: blob)
            try catalog.dbQueue.write { db in
                try asset.insert(db)
                try AssetHistory(assetId: asset.id, seq: 1, developJson: blob,
                                 label: "import", createdAt: ISO8601.now()).insert(db)
            }
            ids.append(asset.id)
        }

        let session = CatalogSession()
        try session.open(package)
        XCTAssertEqual(Set(session.assets.map(\.id)), Set(ids), "the library's rows are the fixtures")
        return (session, catalog, ids)
    }

    private func makeLoupe(session: CatalogSession) -> LoupeController {
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        loupe.collectsHistogram = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = loupe.view
        loupe.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        window.orderFront(nil)
        loupe.view.layoutSubtreeIfNeeded()
        pump(0.05)
        return loupe
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = 30, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func settleBackdrop(_ loupe: LoupeController, timeout: TimeInterval = 60) -> Bool {
        waitFor(timeout) { loupe.backdrop.isIdle }
    }

    /// Open one asset on the real loupe path: anchor → mode → first frame (065b) → its backdrop.
    @discardableResult
    private func open(_ id: String, session: CatalogSession, loupe: LoupeController,
                      timeout: TimeInterval = 60) -> Bool {
        session.selectOnly(id)
        session.mode = .loupe
        loupe.autoRenderEnabled = true
        loupe.scheduleRender()
        guard waitFor(timeout, { loupe.lastFrame != nil }) else { return false }
        guard waitFor(timeout, { loupe.backdrop.texture != nil }) else { return false }
        guard settleBackdrop(loupe, timeout: timeout) else { return false }
        pump(0.05)
        return true
    }

    private func photoKey(_ asset: Asset) -> String { "\(asset.contentHash)|\(asset.id)" }

    // MARK: - ① paste into the open document

    func testPasteIntoTheOpenDocumentRebuildsTheBackdropImmediately() throws {
        let (session, _, ids) = try makeLibrary(photoCount: 2)
        let (source, target) = (ids[0], ids[1])
        let loupe = makeLoupe(session: session)

        XCTAssertTrue(open(source, session: session, loupe: loupe), "the source never opened")
        session.selectOnly(source)
        let payload = try XCTUnwrap(session.copySettingsFromAnchor())
        XCTAssertEqual(payload.fieldCount, 2)
        XCTAssertTrue(open(target, session: session, loupe: loupe), "the target never opened")
        XCTAssertEqual(session.edit.light.exposure, documentB().light.exposure)

        let generationsBefore = loupe.backdrop.generationCount
        let started = CACurrentMediaTime()
        let reports = session.pasteSettings()
        XCTAssertEqual(reports.count, 1)
        XCTAssertTrue(try XCTUnwrap(reports.first).changed, "the paste moved nothing")
        let pastedDigest = Histogram.editDigest(session.edit)

        XCTAssertTrue(waitFor(0.2) {
            loupe.backdrop.texture != nil && loupe.backdrop.key?.digest == pastedDigest
        }, "no bottom image for the pasted document within 200 ms")
        let elapsed = (CACurrentMediaTime() - started) * 1000
        print("[165] paste → backdrop digest \(pastedDigest.prefix(16))… in \(Int(elapsed)) ms")

        XCTAssertEqual(loupe.backdrop.key?.digest, pastedDigest,
                       "the cached key must name the pasted document")
        XCTAssertEqual(loupe.lowResFullFrame?.digest, pastedDigest)
        XCTAssertEqual(loupe.backdrop.generationCount, generationsBefore + 1,
                       "one command, one replacement — not a render per paste frame")
        XCTAssertFalse(pastedDigest.hasSuffix(LoupeController.backdropPreviewMarker))
    }

    // MARK: - ② paste into unopened photos, then open one

    func testPasteIntoUnopenedPhotosRendersOnlyTheOneThatIsOpened() throws {
        let (session, catalog, ids) = try makeLibrary(photoCount: 4)
        let source = ids[0]
        let targets = Array(ids[1...3])
        let loupe = makeLoupe(session: session)

        XCTAssertTrue(open(source, session: session, loupe: loupe))
        session.selectOnly(source)
        _ = try XCTUnwrap(session.copySettingsFromAnchor())
        let requestsBefore = loupe.backdrop.requests

        let reports = session.pasteSettings(into: targets)
        XCTAssertEqual(reports.count, 3)
        XCTAssertTrue(reports.allSatisfy(\.changed))
        // The source is still the live document; all three targets were written through the catalog.
        XCTAssertEqual(session.anchorID, source)
        for id in targets {
            XCTAssertEqual(try catalog.develop(forAsset: id).light.exposure, 1.2,
                           "\(id.prefix(4)) kept the pasted exposure in its row")
        }
        // None of them is on screen, so the command costs no backdrop render at all.
        pump(0.1)
        XCTAssertEqual(loupe.backdrop.requests, requestsBefore,
                       "an unopened target must not be rendered just because it was pasted onto")

        // Open the first target: exactly one generation, for this photo.
        let first = try XCTUnwrap(session.assets.first { $0.id == targets[0] })
        XCTAssertTrue(open(targets[0], session: session, loupe: loupe),
                      "the pasted target never opened")
        let expectedDigest = Histogram.editDigest(session.edit)
        XCTAssertEqual(session.edit.light.exposure, 1.2)
        XCTAssertEqual(loupe.backdrop.key?.photo, photoKey(first))
        XCTAssertEqual(loupe.backdrop.key?.digest, expectedDigest,
                       "the opened target's bottom image must name its own pasted document")
        XCTAssertEqual(loupe.backdrop.requests, requestsBefore + 1,
                       "opening one pasted photo is one request; the other two were not rendered")

        // The other two rows are pasted and unopened; their backdrops cost nothing.
        for id in targets.dropFirst() {
            XCTAssertEqual(try catalog.develop(forAsset: id).light.exposure, 1.2)
        }
        print("[165] 3 pasted, 1 opened → backdrop requests +\(loupe.backdrop.requests - requestsBefore)")
    }

    // MARK: - ③ paste → undo, four times

    func testPasteUndoCyclesAlwaysNameTheCurrentDocument() throws {
        let (session, _, ids) = try makeLibrary(photoCount: 2)
        let (source, target) = (ids[0], ids[1])
        let loupe = makeLoupe(session: session)

        XCTAssertTrue(open(source, session: session, loupe: loupe))
        session.selectOnly(source)
        _ = try XCTUnwrap(session.copySettingsFromAnchor())
        XCTAssertTrue(open(target, session: session, loupe: loupe))

        func assertBackdropNamesCurrentDocument(_ step: String) throws {
            let expected = Histogram.editDigest(session.edit)
            XCTAssertTrue(waitFor(0.2) {
                loupe.backdrop.texture != nil && loupe.backdrop.key?.digest == expected
            }, "\(step): no bottom image for the document on screen within 200 ms")
            XCTAssertEqual(try XCTUnwrap(loupe.backdrop.key).digest, expected,
                           "\(step): the cached digest must be the document's")
            XCTAssertEqual(loupe.lowResFullFrame?.digest, expected, "\(step)")
            XCTAssertFalse(expected.hasSuffix(LoupeController.backdropPreviewMarker), "\(step)")
        }

        // Four round trips: each paste is a command, each undo is a command.
        for i in 0 ..< 4 {
            let reports = session.pasteSettings()
            XCTAssertTrue(try XCTUnwrap(reports.first).changed, "cycle \(i): the paste moved nothing")
            XCTAssertEqual(session.edit.light.exposure, 1.2)
            try assertBackdropNamesCurrentDocument("cycle \(i) paste")

            XCTAssertTrue(session.undo(), "cycle \(i): nothing to undo")
            XCTAssertEqual(session.edit.light.exposure, documentB().light.exposure)
            try assertBackdropNamesCurrentDocument("cycle \(i) undo")
        }
        print("[165] 4 × (paste → undo) kept the backdrop on the current document")
    }

    // MARK: - ④ paste while a white-balance preview is being dragged

    func testPasteDuringAWhiteBalancePreviewNeverPresentsThePreviewAsTheDocument() throws {
        let (session, _, ids) = try makeLibrary(photoCount: 2)
        let (source, target) = (ids[0], ids[1])
        let loupe = makeLoupe(session: session)

        XCTAssertTrue(open(source, session: session, loupe: loupe))
        session.selectOnly(source)
        _ = try XCTUnwrap(session.copySettingsFromAnchor())
        XCTAssertTrue(open(target, session: session, loupe: loupe))

        // A live preview, then a paste in the middle of it (the command path the boundary is about).
        loupe.beginWhiteBalancePreview()
        loupe.updateWhiteBalancePreview(temperature: 4300, tint: 8)
        XCTAssertTrue(waitFor { loupe.whiteBalancePreviewRenderCount > 0
            && !loupe.isRenderingWhiteBalancePreview }, "no preview frame reached the canvas")

        let reports = session.pasteSettings()
        XCTAssertTrue(try XCTUnwrap(reports.first).changed)
        pump(0.15)

        // While the drag is live, the digest must still say "preview source": the paste may rebuild a
        // bottom image, but it can never be adopted as the settled document's.
        let settledDigest = Histogram.editDigest(session.edit)
        if let cached = loupe.lowResFullFrame {
            XCTAssertTrue(cached.digest.hasSuffix(LoupeController.backdropPreviewMarker),
                          "a preview backdrop claimed the settled digest \(settledDigest.prefix(12))…")
            XCTAssertNotEqual(cached.digest, settledDigest)
        }

        // Cancelling the preview is 144's path: the document's own bottom image comes back, without
        // the marker, and the document is exactly what the paste left.
        loupe.cancelWhiteBalancePreview()
        XCTAssertTrue(waitFor(30) {
            loupe.lowResFullFrame?.digest == settledDigest && !loupe.isWhiteBalancePreviewActive
        }, "the cancelled preview left the preview's backdrop in place")
        XCTAssertEqual(loupe.backdrop.key?.digest, settledDigest)
    }
}
