import XCTest
import AppKit
import CoreGraphics
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 445 — the **end-to-end** half of 443: a real photo switch that lands on a 434 canvas-cache hit
/// must never register the previous photo's source size under the new photo.
///
/// `IngestedSourceOwner443Tests` only proves that the guard refuses a publication naming another
/// photo. This suite drives the shipped path — editor window, real loupe, real decode queue, real
/// canvas cache — and watches `session.ingestedSourceFrame` through the switch. It has to prove
/// three things, in this order:
///
///   1. the switch really is a cache hit (otherwise it is not testing that path at all);
///   2. `(B's asset id, A's size)` never appears while switching from A to B;
///   3. on `5b58872` (before 443) it goes red — the reverse gate that says the probe saw something.
///
/// The sampling window is `session.activate(B)` → B's real frame plus eight frames, sampled every
/// 2 ms. Only read-only accessors are used: `ingestedSourceFrame`, `canvasCachePresents`,
/// `canvasFrameCacheDiagnostics`, `presentedPhoto*ForTesting`, `presentationContentForTesting`.
@MainActor
final class CacheHitSourceOwner445Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-cachehit-445-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    private struct SourceSample {
        let assetID: String?
        let size: ImageSize?
        let presented: String?
        let content: String

        var line: String {
            let id = assetID ?? "nil"
            let s = size.map { "\($0.width)×\($0.height)" } ?? "nil"
            return "\(id) @ \(s) · presented \(presented ?? "nil") · \(content)"
        }
    }

    func testACacheHitSwitchNeverRegistersBWithAsSize() throws {
        let landscape = try fixture("L1030433.dng")
        let portrait = try fixture("L1030437.dng")
        let (editor, assets) = try makeEditor(files: [landscape, portrait])
        let loupe = editor.rootView.loupeController
        let session = editor.session
        let a = assets[0]
        let b = assets[1]
        let aIdentity = "\(a.contentHash)|\(a.id)"
        let bIdentity = "\(b.contentHash)|\(b.id)"
        let aSize = try displaySize(of: a)
        let bSize = try displaySize(of: b)
        XCTAssertNotEqual(aSize, bSize, "the two fixtures must have different display sizes")
        XCTAssertNotEqual(isPortrait(aSize), isPortrait(bSize),
                          "the fixtures must have different orientations (A landscape, B portrait)")
        XCTAssertTrue(isPortrait(bSize), "B must be the portrait photo")

        // ── open A: the first real frame lands (and its graph becomes `frameState`).
        session.selectOnly(a.id)
        pump(0.05)
        session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(60) { loupe.currentPresentedPhotoForTesting == aIdentity },
                      "A never presented: \(loupe.lastPresentError ?? "—")")
        let settledAfterA = loupe.settledFramePresents
        XCTAssertTrue(waitFor(60) { loupe.settledFramePresents > settledAfterA },
                      "A's real frame never reached the canvas cache")
        XCTAssertEqual(session.ingestedSourceFrame?.assetID, a.id)
        XCTAssertEqual(session.ingestedSourceFrame?.size, aSize)

        // ── warm B: a miss, a real development, and B's canvas goes into the 434 cache.
        let settledBeforeB = loupe.settledFramePresents
        session.activate(b.id)
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(60) { loupe.currentPresentedPhotoForTesting == bIdentity },
                      "B never presented on the warming visit: \(loupe.lastPresentError ?? "—")")
        XCTAssertTrue(waitFor(60) { loupe.settledFramePresents > settledBeforeB },
                      "B's real frame never reached the canvas cache")
        let bFrame = try XCTUnwrap(session.ingestedSourceFrame,
                                   "B's real frame never registered a source")
        XCTAssertEqual(bFrame.assetID, b.id, "the warming frame registered under another photo")
        XCTAssertEqual(bFrame.size, bSize, "B's real frame did not register B's display size")
        let bKey = try XCTUnwrap(loupe.lastCanvasFrameCacheKey,
                                 "the warming visit named no canvas-cache key")
        XCTAssertEqual(bKey.photo, bIdentity, "the cache key names another photo")
        XCTAssertTrue(loupe.canvasFrameCache.contains(bKey),
                      "B's canvas never reached the cache — the tested switch cannot hit")

        // ── go back to A and let A's **real** frame land: `frameState.graph` must be A's at the
        //    switch, otherwise the old publication would read B's size and the reverse gate would
        //    not reproduce the shipped defect.
        let settledBeforeReturn = loupe.settledFramePresents
        session.activate(a.id)
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(60) { loupe.currentPresentedPhotoForTesting == aIdentity },
                      "A never came back: \(loupe.lastPresentError ?? "—")")
        XCTAssertTrue(waitFor(60) { loupe.settledFramePresents > settledBeforeReturn },
                      "A's real frame never landed after the return")
        XCTAssertEqual(session.ingestedSourceFrame?.assetID, a.id)
        XCTAssertEqual(session.ingestedSourceFrame?.size, aSize)

        // ── the tested switch: A → B, which the 434 cache has warmed.
        let hitsBefore = loupe.canvasFrameCacheDiagnostics.hits
        let cachedPresentsBefore = loupe.canvasCachePresents
        var samples: [SourceSample] = []
        func record() {
            let frame = session.ingestedSourceFrame
            samples.append(SourceSample(assetID: frame?.assetID, size: frame?.size,
                                        presented: loupe.currentPresentedPhotoForTesting,
                                        content: loupe.presentationContentForTesting))
        }

        record()
        session.activate(b.id)
        editor.rootView.showModule(for: .loupe)
        record()

        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, loupe.currentPresentedPhotoForTesting != bIdentity {
            pump(0.002)
            record()
        }
        XCTAssertEqual(loupe.currentPresentedPhotoForTesting, bIdentity,
                       "B never presented on the tested switch: \(loupe.lastPresentError ?? "—")")
        for _ in 0..<8 {
            pump(0.002)
            record()
        }

        let hitsAfter = loupe.canvasFrameCacheDiagnostics.hits
        let cachedPresentsAfter = loupe.canvasCachePresents
        let hitDelta = hitsAfter - hitsBefore
        let presentDelta = cachedPresentsAfter - cachedPresentsBefore
        print("[445] tested switch: hits +\(hitDelta) (\(hitsBefore)→\(hitsAfter)) · "
              + "cachePresents +\(presentDelta) · samples \(samples.count) · "
              + "A \(aSize.width)×\(aSize.height) · B \(bSize.width)×\(bSize.height)")

        // ① this must have been a cache hit, or the switch is not the path under test.
        XCTAssertGreaterThan(hitDelta, 0, "the switch never hit the cache")
        XCTAssertGreaterThan(presentDelta, 0,
                             "the cache answered but its canvas never presented")

        // ② the symptom 443 fixed: (B's id, A's size) must not exist in any sample.
        var sampledB = 0
        var sawPresentedB = false
        for (index, sample) in samples.enumerated() {
            if sample.presented == bIdentity { sawPresentedB = true }
            guard sample.assetID == b.id, let size = sample.size else { continue }
            sampledB += 1
            if index < 5 || index >= samples.count - 4 || size != bSize {
                print("[445] sample \(index): \(sample.line)")
            }
            XCTAssertEqual(size, bSize,
                           "sample \(index): B was registered with another photo's size: \(sample.line)")
            XCTAssertNotEqual(size, aSize,
                              "sample \(index): B was registered with A's size: \(sample.line)")
        }

        // The window closed at the cache-hit present, before the real frame below. A sample that
        // already shows B on the layer means the probe reached the instant the old publication ran;
        // on 5b58872 that same instant left `(B, A's size)` in `ingestedSourceFrame`.
        XCTAssertTrue(sawPresentedB, "the window never reached the post-cache-present instant")
        XCTAssertTrue(waitFor(60) {
            session.ingestedSourceFrame?.assetID == b.id
                && session.ingestedSourceFrame?.size == bSize
        }, "B's real frame never registered B's size: \(String(describing: session.ingestedSourceFrame))")

        print("[445] samples naming B inside the window: \(sampledB); B's frame is "
              + "\(bSize.width)×\(bSize.height)")
    }

    // MARK: - fixtures

    private func fixture(_ name: String) throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/\(name)").expandingTildeInPath,
        ].compactMap { $0 }
        for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate) {
            if candidate.hasSuffix(name) { return URL(fileURLWithPath: candidate) }
        }
        throw XCTSkip("no RAW fixture \(name); set PHOTONS_TEST_RAW")
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 60, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func isPortrait(_ size: ImageSize) -> Bool { size.height > size.width }

    private func displaySize(of asset: Asset) throws -> ImageSize {
        ImageSize(width: try XCTUnwrap(asset.width, "the catalog row has no width"),
                  height: try XCTUnwrap(asset.height, "the catalog row has no height"))
    }

    private func makeEditor(files: [URL]) throws -> (EditorWindowController, [Asset]) {
        let library = try makeLibrary(files: files)
        _ = NSApplication.shared
        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        windows.append(try XCTUnwrap(editor.window))
        try editor.openLibrary(at: library.package)
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        for asset in editor.session.assets {
            // 436 — the catalog row is **display pixels** (import applies the EXIF turn), so the
            // seeded preview must not run `uprightSize` over it a second time (437).
            let size = ImageSize(width: asset.width ?? 3, height: asset.height ?? 2)
            try seedPreview(asset, upright: size, cache: cache)
        }
        TestWindows.show(editor.window)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.rootView.needsLayout = true
        editor.rootView.layoutSubtreeIfNeeded()
        pump(0.05)
        return (editor, editor.session.assets)
    }

    private func makeLibrary(files: [URL]) throws -> (package: URL, assets: [Asset]) {
        let package = workDir.appendingPathComponent("CacheHit445.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var ids: [String] = []
        for (index, file) in files.enumerated() {
            let name = "cachehit\(index).dng"
            let destination = source.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            let stored = try pixelSize(of: file)
            let orientation = try orientation(of: file)
            // 436 — the row import writes is display-oriented; this synthetic library has to say the
            // same thing or the 290 fallback legitimately reads a stored frame as the upright one.
            let size = (5...8).contains(orientation)
                ? ImageSize(width: stored.height, height: stored.width) : stored
            let id = UUID().uuidString
            ids.append(id)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                            '\(UUID().uuidString)',
                            \(size.width), \(size.height),
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-02T00:00:00Z', 0)
                    """)
                try db.execute(sql: """
                    INSERT INTO asset_metadata (asset_id, orientation) VALUES ('\(id)', \(orientation))
                    """)
            }
        }
        let assets = try ids.map { try XCTUnwrap(try catalog.asset(id: $0)) }
        return (package, assets)
    }

    /// A warm stand-in with the asset's own **upright** orientation: the cache's canvas placeholder is
    /// what the switch installs, so a portrait photo must be seeded with a portrait bitmap.
    private func seedPreview(_ asset: Asset, upright: ImageSize, cache: ThumbnailCache) throws {
        let (width, height) = upright.height > upright.width ? (427, 640) : (640, 427)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.72, green: 0.45, blue: 0.22, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
            .representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        let tier = ThumbnailProvider.effectiveTier(requested: .t1024, ext: asset.ext).tier
        try cache.store(data, for: .preview(contentHash: asset.contentHash, tier: tier))
    }

    private func pixelSize(of url: URL) throws -> ImageSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return ImageSize(width: width, height: height)
    }

    private func orientation(of url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return properties[kCGImagePropertyOrientation] as? Int ?? 1
    }
}
