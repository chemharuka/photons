import XCTest
import AppKit
import CoreGraphics
import ImageIO
import QuartzCore
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 235 — 冷启动 → 打开第一张 → 进编辑：首帧不能是空白。
///
/// The user's report is about the **process-cold** moment, not 065b's photo switch: on the first open
/// there is no frame graph yet, so the low-resolution whole picture 065b asks for cannot be made
/// until the first real frame lands. Between entering the loupe and that frame the canvas was the
/// matte alone.
///
/// The fix under test is the grid/filmstrip thumbnail standing in (aspect-fit) until the first
/// `present`. The tests assert the two halves the acceptance names:
///
///   1. a **cold** open has a non-blank first frame, and the content enum says what it was;
///   2. the reverse gate: with the arm disabled the same cold open is blank again.
///
/// A real RAW (the same fixture the loupe suites use) is referenced, and a thumbnail for the row is
/// written into the library's cache — that is the state a cold app start finds: no memory, warm disk.
/// 251 adds the other half: a brand-new library with **no** thumbnail on disk, where the stand-in has
/// to be generated from the embedded preview while the canvas is still the matte.
@MainActor
final class ColdStartLoupeTests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    /// Cache directories derived from this test's unique temporary library paths. They live outside
    /// the package (`~/Library/Caches/Photons/<hash>`), so `workDir` alone does not clean them up.
    private var cacheDirs: [URL] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-coldstart-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for dir in cacheDirs { try? FileManager.default.removeItem(at: dir) }
        cacheDirs.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - fixtures

    private func fixture(_ name: String) throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/\(name)").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            // `PHOTONS_TEST_RAW` names one file; only use it for the first slot.
            if c.hasSuffix(name) { return URL(fileURLWithPath: c) }
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

    // MARK: - the cold start

    func testColdOpenShowsACachedThumbnailBeforeTheFirstFrame() throws {
        let raw = try fixture("L1030433.dng")
        let (editor, assets) = try makeEditor(files: [raw])
        let loupe = editor.rootView.loupeController
        XCTAssertNil(loupe.lastFrame, "a cold controller has presented nothing")

        // Settle the selection while the grid is still the visible module, then enter the loupe — the
        // user's path (a double-click) publishes these two facts in the same order.
        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)

        // The arm is synchronous, so the stand-in must be up before any decode can finish.
        XCTAssertTrue(loupe.firstFramePlaceholderVisible,
                      "cold open: the canvas had no thumbnail before the first frame")
        let placeholderMs = loupe.firstFramePlaceholderMilliseconds
        XCTAssertGreaterThanOrEqual(placeholderMs, 0)

        // The real frame eventually replaces it; the content enum records what was there first.
        guard waitFor(90, { loupe.lastFrame != nil }) else {
            return XCTFail("no first frame (last error: \(loupe.lastPresentError ?? "—"))")
        }
        XCTAssertEqual(loupe.firstFrameContent, .displayThumbnail,
                       "the first presented frame replaced the thumbnail; until then it was blank")
        XCTAssertFalse(loupe.firstFramePlaceholderVisible, "the stand-in outlived the real frame")

        guard waitFor(90, { loupe.lowResFullFrame != nil }) else {
            return XCTFail("the open's low-resolution whole picture never arrived")
        }
        print(String(format: "235 cold open: stand-in %.1f ms · first real frame %.1f ms · low-res %.1f ms · first content %@",
                     placeholderMs,
                     loupe.lastPhotoSwitchFirstFrameMilliseconds,
                     loupe.lastPhotoSwitchBackdropMilliseconds,
                     loupe.firstFrameContent.rawValue))
    }

    /// 251 — the genuinely cold path: a brand-new library whose thumbnail cache has never been
    /// written. The tests above seed a preview JPEG, so `armFirstFramePlaceholder` finds its stand-in
    /// synchronously; here it must ask the thumbnail service for the RAW's embedded preview, and the
    /// canvas waits on the matte until that lands.
    ///
    /// What is pinned:
    ///   · the cache really is empty at the moment the loupe opens (otherwise this is 235 again);
    ///   · the wait is the **matte**, never stale pixels;
    ///   · the first real frame still replaces `displayThumbnail`, not `blank`;
    ///   · the matte window is measured and bounded (≤ 250 ms), not merely "something showed up".
    func testColdOpenWithAnEmptyCacheStandsInTheGeneratedPreview() throws {
        let raw = try fixture("L1030433.dng")
        let (editor, assets) = try makeEmptyCacheEditor(files: [raw])
        let loupe = editor.rootView.loupeController
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        let provider = ThumbnailProvider.shared(for: cache)
        XCTAssertNil(provider.cachedCanvasPlaceholder(for: assets[0], document: editor.session.edit),
                     "the test is not cold: the stand-in was already cached")

        // The grid has not been laid out with this asset (see `makeEmptyCacheEditor`), so entering the
        // loupe is the first thing that can ask for a thumbnail.
        editor.session.selectOnly(assets[0].id)
        let started = CACurrentMediaTime()
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)

        // With nothing on disk the stand-in cannot be synchronous: the only thing on the canvas is
        // the matte cover (never the previous photo, never a stale drawable).
        XCTAssertFalse(loupe.firstFramePlaceholderVisible,
                       "an empty cache installed a thumbnail synchronously")
        XCTAssertTrue(loupe.isCanvasCoveredForTesting,
                      "the empty-cache window was not the matte")
        XCTAssertNil(loupe.lastFrame, "the empty-cache window already had a real frame")

        XCTAssertTrue(waitFor(10, { loupe.firstFramePlaceholderVisible }),
                      "the generated embedded-preview stand-in never arrived")
        let matteMs = (CACurrentMediaTime() - started) * 1000
        let generationMs = loupe.firstFramePlaceholderMilliseconds

        // 251 round 2 (A) — the stand-in and the real frame must occupy **the same** 0.90 content
        // rectangle. Read the stand-in's rect while it is on screen (canvas points), then convert it
        // to device pixels exactly as `PhotoSwitchFlashTests` does.
        let scale = max(1, loupe.backingScale)
        let placeholderRect = loupe.placeholderRectForTesting
        let placeholderPixels = ImageSize(
            width: max(1, Int((placeholderRect.width * scale).rounded())),
            height: max(1, Int((placeholderRect.height * scale).rounded())))
        let canvasPoints = loupe.canvasView.bounds.size

        guard waitFor(90, { loupe.lastFrame != nil }) else {
            return XCTFail("no first frame (last error: \(loupe.lastPresentError ?? "—"))")
        }
        let frame = try XCTUnwrap(loupe.lastFrame)
        XCTAssertEqual(loupe.firstFrameContent, .displayThumbnail,
                       "the first real frame did not replace the generated stand-in")
        XCTAssertFalse(loupe.firstFramePlaceholderVisible, "the stand-in outlived the real frame")
        XCTAssertFalse(loupe.isCanvasCoveredForTesting, "the matte cover outlived the real frame")

        // Exact equality first: both rects come from the same `LoupeFraming.contentPixels`, and the
        // stand-in's points × backingScale recovers those pixels without a second rounding rule.
        XCTAssertEqual(placeholderPixels.width, frame.content.width,
                       "stand-in \(placeholderPixels.width) px vs real content \(frame.content.width) px"
                       + " (rect \(placeholderRect), scale \(scale))")
        XCTAssertEqual(placeholderPixels.height, frame.content.height,
                       "stand-in \(placeholderPixels.height) px vs real content \(frame.content.height) px"
                       + " (rect \(placeholderRect), scale \(scale))")
        XCTAssertLessThanOrEqual(abs(placeholderRect.midX - canvasPoints.width / 2), 1,
                                 "the stand-in is not centred: midX \(placeholderRect.midX)"
                                 + " vs canvas midX \(canvasPoints.width / 2)")
        XCTAssertLessThanOrEqual(abs(placeholderRect.midY - canvasPoints.height / 2), 1,
                                 "the stand-in is not centred: midY \(placeholderRect.midY)"
                                 + " vs canvas midY \(canvasPoints.height / 2)")

        // 251's budget: the empty-cache wait is allowed to exist, but it is a measured, bounded
        // state — not "whatever it takes". 250 ms leaves the measured 120–190 ms generation path
        // at least ~1.3× of headroom without turning the assertion into "it eventually shows".
        XCTAssertLessThanOrEqual(matteMs, 250,
                                 "empty-cache matte window \(matteMs) ms exceeds the 250 ms budget")
        XCTAssertLessThanOrEqual(generationMs, 250,
                                 "stand-in generation \(generationMs) ms exceeds the 250 ms budget")
        print(String(format: "251 empty cache: matte %.1f ms · stand-in generation %.1f ms"
                     + " · first real frame %.1f ms · first content %@"
                     + " · placeholder %dx%d px · real content %dx%d px"
                     + " · rect origin %.2f,%.2f · rect size %.2f×%.2f pt",
                     matteMs, generationMs,
                     loupe.lastPhotoSwitchFirstFrameMilliseconds,
                     loupe.firstFrameContent.rawValue,
                     placeholderPixels.width, placeholderPixels.height,
                     frame.content.width, frame.content.height,
                     placeholderRect.origin.x, placeholderRect.origin.y,
                     placeholderRect.width, placeholderRect.height))
    }

    /// 251 round 2 (B) — the empty-cache path's own reverse gate.
    ///
    /// 235's reverse gate disables the arm on a **seeded** library; here the cache is genuinely empty,
    /// so this pins the mechanism on the path that actually has to generate a stand-in. With the arm
    /// off the canvas must stay on the matte (never stale pixels, never a stand-in), and the first real
    /// frame must record `blank` — if the arm were wired in somewhere other than `armFirstFramePlaceholder`,
    /// the positive test could still pass while this one stays red.
    func testEmptyCacheWithoutTheStandInStaysOnTheMatte() throws {
        let raw = try fixture("L1030433.dng")
        let (editor, assets) = try makeEmptyCacheEditor(files: [raw])
        let loupe = editor.rootView.loupeController
        loupe.armsColdStartPlaceholder = false

        editor.session.selectOnly(assets[0].id)
        let started = CACurrentMediaTime()
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)

        // The matte is synchronous and is the only thing on the canvas: not the previous photo, not
        // a stand-in.
        XCTAssertTrue(loupe.isCanvasCoveredForTesting,
                      "without the arm the empty-cache window was not the matte")
        XCTAssertNil(loupe.lastFrame, "the empty-cache window already had a real frame")

        // The preview request is asynchronous, so sample the whole first second instead of trusting
        // one instant: a stand-in installed 50 ms later would still be a failure.
        let deadline = started + 1.0
        var placeholderSeen = false
        while CACurrentMediaTime() < deadline {
            if loupe.firstFramePlaceholderVisible { placeholderSeen = true; break }
            pump()
        }
        let matteWindowMs = (CACurrentMediaTime() - started) * 1000
        XCTAssertFalse(placeholderSeen,
                       "the stand-in appeared although `armsColdStartPlaceholder` was off")

        guard waitFor(90, { loupe.lastFrame != nil }) else {
            return XCTFail("no first frame (last error: \(loupe.lastPresentError ?? "—"))")
        }
        XCTAssertEqual(loupe.firstFrameContent, .blank,
                       "without the arm the empty-cache first frame had nothing to stand in")
        XCTAssertFalse(loupe.firstFramePlaceholderVisible, "the stand-in outlived the real frame")
        XCTAssertFalse(loupe.isCanvasCoveredForTesting, "the matte cover outlived the real frame")
        print(String(format: "251 reverse (empty cache): matte window %.1f ms"
                     + " · first real frame %.1f ms · first content %@",
                     matteWindowMs,
                     loupe.lastPhotoSwitchFirstFrameMilliseconds,
                     loupe.firstFrameContent.rawValue))
    }

    /// 反向门: the same cold open, with the arm switched off, is the pre-fix blank canvas.
    ///
    /// This is the assertion that goes red if the arm call is deleted: the positive test above cannot
    /// pass on a blank canvas, and this one pins the exact mechanism it depends on.
    func testWithoutTheColdStartArmTheCanvasIsBlank() throws {
        let raw = try fixture("L1030433.dng")
        let (editor, assets) = try makeEditor(files: [raw])
        let loupe = editor.rootView.loupeController
        loupe.armsColdStartPlaceholder = false

        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)

        XCTAssertFalse(loupe.firstFramePlaceholderVisible,
                       "the reverse gate did not disable the arm")

        guard waitFor(90, { loupe.lastFrame != nil }) else {
            return XCTFail("no first frame (last error: \(loupe.lastPresentError ?? "—"))")
        }
        XCTAssertEqual(loupe.firstFrameContent, .blank,
                       "without the arm the first frame had nothing to stand in")
    }

    /// The control the acceptance compares against: a **running** switch must arm the same stand-in
    /// immediately. 065b's low-resolution replacement is unchanged — this only says the first thing
    /// on screen is never the previous photo's blank/old pixels.
    func testRunningPhotoSwitchAlsoShowsTheNewThumbnailAtOnce() throws {
        let first = try fixture("L1030433.dng")
        let second = try fixture("L1030402.dng")
        let (editor, assets) = try makeEditor(files: [first, second])
        let loupe = editor.rootView.loupeController

        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(90, { loupe.lastFrame != nil }), "no first frame")
        XCTAssertTrue(waitFor(90, { loupe.lowResFullFrame != nil }), "no cold low-res picture")
        let cold = loupe.lastPhotoSwitchBackdropMilliseconds

        let frameBefore = loupe.lastPhotoSwitchFirstFrameMilliseconds
        editor.session.activate(assets[1].id)
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(loupe.firstFramePlaceholderVisible,
                      "a photo switch must put the new thumbnail up at once")

        XCTAssertTrue(waitFor(90, { loupe.lastPhotoSwitchFirstFrameMilliseconds != frameBefore }),
                      "the switched photo never presented")
        XCTAssertTrue(waitFor(90, {
            loupe.lastPhotoSwitchBackdropMilliseconds > 0
                && loupe.lastPhotoSwitchBackdropMilliseconds != cold
        }), "the switched photo's low-res picture never arrived")
        XCTAssertEqual(loupe.firstFrameContent, .displayThumbnail)
        // The acceptance's T2 rule: the cold open may not be more than 1.5× the running switch.
        let warm = loupe.lastPhotoSwitchBackdropMilliseconds
        let ratio = warm > 0 ? cold / warm : 0
        XCTAssertLessThanOrEqual(ratio, 1.5,
                                 "cold low-res \(cold) ms vs running switch \(warm) ms")
        print(String(format: "235 running switch: stand-in %.1f ms · first real frame %.1f ms · low-res %.1f ms · cold low-res %.1f ms · cold/warm %.2f",
                     loupe.firstFramePlaceholderMilliseconds,
                     loupe.lastPhotoSwitchFirstFrameMilliseconds,
                     warm, cold, ratio))
    }

    // MARK: - a library whose row points at a real file, with a warm thumbnail cache

    private struct ColdLibrary {
        let package: URL
        let assets: [Asset]
    }

    private func makeLibrary(files: [URL], physicalSize: Bool = false) throws -> ColdLibrary {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("Cold.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var ids: [String] = []
        for (index, file) in files.enumerated() {
            let name = "cold\(index).dng"
            let destination = source.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            let size = try pixelSize(of: file)
            // 251's empty-cache path is gated on `asset.size > 1024` (a one-byte synthetic row cannot
            // carry an embedded preview). The older fixtures deliberately use 1; the new test opts
            // into the real file size so the stand-in's generation path is the one under test.
            let byteSize = physicalSize
                ? ((try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 1)
                : 1
            let id = UUID().uuidString
            ids.append(id)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', \(byteSize), 0,
                            '\(UUID().uuidString)',
                            \(size.width), \(size.height),
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-02T00:00:00Z', 0)
                    """)
            }
        }
        let assets = try ids.map { try XCTUnwrap(try catalog.asset(id: $0)) }
        return ColdLibrary(package: package, assets: assets)
    }

    /// 251 — a library whose thumbnail cache is empty **and stays empty until the loupe opens**.
    ///
    /// `makeEditor` seeds the preview and then lays the grid out, which is the warm state. Here the
    /// loupe is entered and laid out **before** the library exists, so the grid never gets a layout
    /// pass with the asset in it (the one thing that would warm the cache). The library opens with
    /// the loupe already the visible module; the caller's `showModule(for: .loupe)` is then the actual
    /// open, with settled canvas geometry and no measurement-inflating layout work in the window.
    private func makeEmptyCacheEditor(files: [URL]) throws -> (EditorWindowController, [Asset]) {
        let library = try makeLibrary(files: files, physicalSize: true)
        // The cache directory is derived from the package path (`~/Library/Caches/Photons/<hash>`).
        // The package is under this test's UUID temp dir, so the derivation is already unique; the
        // removal makes "empty" a fact even if a previous process used the same path.
        let cacheDirectory = LibraryLayout(packageURL: library.package).cacheDirectory
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirs.append(cacheDirectory)

        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        let window = try XCTUnwrap(editor.window)
        windows.append(window)
        // No library yet: this only settles the loupe's canvas geometry (and cannot ask for a
        // thumbnail, because there is no anchor).
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        TestWindows.show(window)
        window.contentView?.layoutSubtreeIfNeeded()

        try editor.openLibrary(at: library.package)
        return (editor, library.assets)
    }

    private func makeEditor(files: [URL]) throws -> (EditorWindowController, [Asset]) {
        let library = try makeLibrary(files: files)
        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        windows.append(editor.window!)
        try editor.openLibrary(at: library.package)
        let cache = try XCTUnwrap(editor.session.thumbnailCache,
                                  "the library has no thumbnail cache")
        for asset in library.assets { try seedPreview(asset, cache: cache) }

        TestWindows.show(editor.window)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.rootView.needsLayout = true
        editor.rootView.layoutSubtreeIfNeeded()
        pump(0.05)
        return (editor, library.assets)
    }

    /// A small, aspect-correct JPEG, written under the legacy preview key the first-frame stand-in
    /// falls back to. The grid would have this for a library opened before; here it is seeded so the
    /// test measures the cold-code path rather than a RAW development.
    private func seedPreview(_ asset: Asset, cache: ThumbnailCache) throws {
        let width = 640, height = 427
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
}
