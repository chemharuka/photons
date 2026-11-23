import XCTest
import AppKit
import CoreGraphics
import ImageIO
import QuartzCore
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 533 — 缩放/平移把窗口画布缓存打掉之后，切图**仍要有 1920 低清占位**，不能只剩背景色。
///
/// 用户口径：「缩放/移动后，10 张/3 张的缓存应该丢失。现在丢失后切换照片，直接连低清 1920p
/// 缩略图都不显示，展示背景色」。窗口缓存（`CanvasFrameCache`，10/3）按相机/视口入键，缩放/平移
/// 之后不可命中是设计；缺陷是**没命中的切图连 stand-in 都没有**。
///
/// 本套件用真库、真解码、真 present，库的磁盘形态就是用户机器上的形态（308 之后三个浏览器只写
/// `thumbs/hd` 的 1920 JPEG，不再写 legacy 预览）。四条断言：
///
///   1. 打开 A → 2× + 平移 → 切到 B（B 在该相机下一定没有窗口缓存）：stand-in 在 loupe 注意到
///      切图的那一拍就在屏上，长边 ≥ 1024；此后 200 ms 内画布不是纯背景色
///      （`presentationContentForTesting` 不是 `empty`）；
///   2. 同一条路径连做 10 次（10 张不同目标照片）：只有背景色的次数必须 0/10；
///   3. 反向门：把 `armFirstFramePlaceholder` 的幂等 guard 改回「忽略照片身份」⇒ ① 的读数必红；
///   4. 冷缓存（没有 HD、只有 1024 预览）的 1024 → 1920 升级链仍成立；
///   5. 命中窗口缓存时不装 stand-in（缓存帧上不叠低清图）。
@MainActor
final class CanvasStandInAfterCacheLoss533Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var cacheDirs: [URL] = []

    /// The window the ticket names: after the switch there must be a picture for this long.
    private let standInWindow: TimeInterval = 0.2

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-533-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for dir in cacheDirs { try? FileManager.default.removeItem(at: dir) }
        cacheDirs.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        LoupeController.armStandInIdempotentGuardIgnoresPhoto = false
        super.tearDown()
    }

    // MARK: - fixtures, library, cache shapes

    /// `count` distinct readable DNGs from the configured fixture's directory.
    private func rawFixtures(count: Int) throws -> [URL] {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"], !env.isEmpty {
            candidates.append(NSString(string: env).expandingTildeInPath)
        }
        candidates.append(NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath)
        guard let first = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0) })
        else { throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW") }
        let firstURL = URL(fileURLWithPath: first)
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: firstURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        let others = siblings
            .filter { $0.standardizedFileURL != firstURL.standardizedFileURL }
            .filter { ["dng", "DNG", "raw", "RAW"].contains($0.pathExtension) }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let urls = [firstURL] + others
        guard urls.count >= count else {
            throw XCTSkip("\(count) RAW fixtures are required, found \(urls.count)")
        }
        return Array(urls.prefix(count))
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 90, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private struct Library {
        let package: URL
        let assets: [Asset]
    }

    /// A real library whose rows point at real DNGs (the same shape the loupe suites use).
    private func makeLibrary(files: [URL]) throws -> Library {
        _ = NSApplication.shared
        let package = workDir.appendingPathComponent("Loss533.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var ids: [String] = []
        for (index, file) in files.enumerated() {
            let name = "loss533-\(index).dng"
            let destination = source.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            let size = try pixelSize(of: file)
            let byteSize = (try FileManager.default.attributesOfItem(atPath: file.path)[.size]
                as? NSNumber)?.intValue ?? 1
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
                            '2026-11-23T00:00:00Z', 0)
                    """)
            }
        }
        let assets = try ids.map { try XCTUnwrap(try catalog.asset(id: $0)) }
        return Library(package: package, assets: assets)
    }

    /// Open the library with the **loupe** already the visible module: the grid never gets a layout
    /// pass with the assets, so the only thumbnails on disk are the ones a test writes. That keeps
    /// the stand-in's read the thing under test instead of an accidental grid warm.
    private func makeEditor(files: [URL]) throws -> (EditorWindowController, Library) {
        let library = try makeLibrary(files: files)
        let cacheDirectory = LibraryLayout(packageURL: library.package).cacheDirectory
        try? FileManager.default.removeItem(at: cacheDirectory)
        cacheDirs.append(cacheDirectory)

        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        windows.append(editor.window!)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        TestWindows.show(editor.window)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        try editor.openLibrary(at: library.package)
        return (editor, library)
    }

    private func pixelSize(of url: URL) throws -> ImageSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        return ImageSize(width: width, height: height)
    }

    /// A document that is **not** the one the loupe opens the photo with. The photo's 1920 file then
    /// sits under a key the switch does not ask for — the real state after a document move (311's
    /// warm window) and the state a library is left in by any prior edit.
    private var otherDocument: EditModel {
        var edit = EditModel.neutral
        edit.light.exposure = 1
        return edit
    }

    /// One **real** 1920 HD JPEG payload from the shipping producer, reused under each photo's own
    /// key (the bytes are a 1920 picture, the key is what the test arranges). One render, not N, so a
    /// ten-switch test is not ten 60 MP developments.
    private func hdJPEGPayload(for asset: Asset, url: URL,
                               provider: ThumbnailProvider) throws -> Data {
        let key = ThumbnailProvider.hdJPEGKey(for: asset, document: .neutral)
        let payload = try provider.produce(key, source: url)
        XCTAssertFalse(payload.data.isEmpty)
        return payload.data
    }

    /// Write the photo's 1920 file under `document` — the only thumbnail a current library holds.
    private func seedHD(_ asset: Asset, document: EditModel, cache: ThumbnailCache, data: Data) throws {
        let key = ThumbnailProvider.hdJPEGKey(for: asset, document: document)
        try cache.store(data, for: key)
        XCTAssertTrue(cache.exists(key), "the test could not write \(asset.filename)'s 1920 file")
    }

    /// A 1024-long-edge legacy preview, the pre-308 cache shape (acceptance ④).
    private func seedPreview(_ asset: Asset, cache: ThumbnailCache, longEdge: Int = 1024) throws {
        let width = longEdge
        let height = max(1, Int((Double(longEdge) * 2.0 / 3.0).rounded()))
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

    // MARK: - driving the loupe

    /// The app's path: the filmstrip/grid calls `activate`; the observation bridge notices and calls
    /// `showModule` → `scheduleRender` → `armFirstFramePlaceholder`. No test-only door.
    private func open(_ editor: EditorWindowController, _ id: String) {
        editor.session.activate(id)
    }

    /// Wait for the loupe's own **switch instant** — `notePhotoIdentity` ran for this photo. This is
    /// the moment the stand-in is owed; everything the ticket measures happens from here.
    @discardableResult
    private func waitForNotice(_ loupe: LoupeController, _ photo: String,
                               timeout: TimeInterval = 10) -> Bool {
        waitFor(timeout) { loupe.currentRenderedPhotoForTesting == photo }
    }

    private func identity(_ asset: Asset) -> String { "\(asset.contentHash)|\(asset.id)" }

    @discardableResult
    private func waitForSettledFrame(_ loupe: LoupeController, _ photo: String,
                                     timeout: TimeInterval = 180) -> Bool {
        waitFor(timeout) {
            loupe.framePresentLog.contains {
                $0.photo == photo && !$0.fromCanvasCache
                    && $0.decodeScale >= DecodeLadder.fullScale - 1e-4
            }
        }
    }

    /// The user's gesture: 2× and one pan. Both change the camera, so the canvas cache key changes —
    /// the 10/3 window cannot answer for the photo being switched to.
    private func zoomAndPan(_ loupe: LoupeController) {
        loupe.zoom(to: 2)
        pump(0.05)
        loupe.panImage(byPoints: CGSize(width: -40, height: 24))
        pump(0.05)
    }

    /// A settled A at the zoomed/panned camera with nothing in flight: the state the user leaves the
    /// loupe in before picking the next photo.
    private func settleAfterGesture(_ loupe: LoupeController, _ photo: String) {
        XCTAssertTrue(waitForSettledFrame(loupe, photo), "the 2× panned frame never settled")
        XCTAssertTrue(waitFor(120) { !loupe.viewportRenderInFlight }, "the camera never quiesced")
        pump(0.3)
    }

    private struct Sample {
        var standInAt: Double?
        var standInPixels: ImageSize?
        var backgroundSamples = 0
        var endedEmpty = false
    }

    /// Sample the canvas for `duration` **after the loupe noticed `photo`**. `standInAt` is the first
    /// instant a ≥ 1024 stand-in *of this photo* was on screen; `backgroundSamples` counts instants
    /// whose presentation was `empty` with no stand-in (the user's 「展示背景色」).
    private func sampleCanvas(_ loupe: LoupeController, photo: String,
                              duration: TimeInterval) -> Sample {
        let start = CACurrentMediaTime()
        var sample = Sample()
        while true {
            let elapsed = CACurrentMediaTime() - start
            let showing = loupe.firstFramePlaceholderVisible
            let owned = loupe.currentPlaceholderPhotoForTesting == photo
            if let pixels = loupe.firstFramePlaceholderPixels, showing, owned,
               max(pixels.width, pixels.height) >= 1024, sample.standInAt == nil {
                sample.standInAt = elapsed
                sample.standInPixels = pixels
            }
            if loupe.presentationContentForTesting == "empty" && !showing {
                sample.backgroundSamples += 1
            }
            if elapsed >= duration {
                sample.endedEmpty = loupe.presentationContentForTesting == "empty" && !showing
                break
            }
            pump(0.001)
        }
        return sample
    }

    private func describe(_ loupe: LoupeController, photo: String, _ sample: Sample) -> String {
        let at = sample.standInAt.map { String(format: "%.1f ms", $0 * 1000) } ?? "never"
        let px = sample.standInPixels.map { "\($0.width)x\($0.height)" } ?? "nil"
        return "stand-in \(at) \(px) · background \(sample.backgroundSamples)"
            + " · content \(loupe.presentationContentForTesting)"
            + " · owner \(loupe.currentPlaceholderPhotoForTesting == photo)"
            + " · arm \(loupe.standinArmCalls) skip \(loupe.standinArmSkips)"
            + " reuse \(loupe.standinArmReuses) miss \(loupe.standinCacheMisses)"
            + " hd \(loupe.standinHDRecoveries) fallback \(loupe.standinFallbackRequests)"
            + " install \(loupe.standinInstalls) refusedPresented \(loupe.standinRefusedAfterPresented)"
    }

    // MARK: - ① the reported path

    func testSwitchAfterZoomAndPanShowsTheStandInWithin200ms() throws {
        let photos = try rawFixtures(count: 2)
        let (editor, library) = try makeEditor(files: photos)
        let loupe = editor.rootView.loupeController
        let a = library.assets[0], b = library.assets[1]
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        let provider = ThumbnailProvider.shared(for: cache)

        let payload = try hdJPEGPayload(for: a, url: photos[0], provider: provider)
        XCTAssertNil(provider.cachedCanvasPlaceholder(for: b, document: .neutral),
                     "the test is not exercising the miss: B already has the document's picture")

        open(editor, a.id)
        XCTAssertTrue(waitFor(90, { loupe.lastFrame != nil }), "A never presented")
        XCTAssertTrue(waitForSettledFrame(loupe, identity(a)), "A never settled")

        try seedHD(b, document: otherDocument, cache: cache, data: payload)
        zoomAndPan(loupe)
        settleAfterGesture(loupe, identity(a))

        let installsBefore = loupe.standinInstalls
        let switchAt = CACurrentMediaTime()
        open(editor, b.id)
        XCTAssertTrue(waitForNotice(loupe, identity(b)), "the loupe never noticed the switch")
        let noticeMs = (CACurrentMediaTime() - switchAt) * 1000
        let sample = sampleCanvas(loupe, photo: identity(b), duration: standInWindow)
        print(String(format: "533 ① notice %.1f ms · ", noticeMs) + describe(loupe, photo: identity(b),
                                                                              sample))

        // The stand-in is installed in the same turn the switch is noticed (fix ①②): no waiting for
        // an asynchronous request.
        let at = try XCTUnwrap(sample.standInAt, """
            切到 B 后没有 ≥1024 的 stand-in（content \(loupe.presentationContentForTesting)，\
            背景采样 \(sample.backgroundSamples)）
            """)
        XCTAssertLessThanOrEqual(at, standInWindow)
        XCTAssertEqual(sample.standInPixels?.width, 1920)
        XCTAssertGreaterThanOrEqual(loupe.standinInstalls - installsBefore, 1)
        XCTAssertEqual(loupe.standinHDRecoveries, 1,
                       "the 1920 file was found by content hash, not by the exact document key")
        XCTAssertEqual(sample.backgroundSamples, 0, "切图后画布出现过纯背景色")
        XCTAssertFalse(sample.endedEmpty)
        XCTAssertNotEqual(loupe.presentationContentForTesting, "empty")
    }

    // MARK: - ② ten switches, 0/10 background

    func testTenSwitchesAfterZoomAndPanNeverShowOnlyTheBackground() throws {
        let photos = try rawFixtures(count: 11)
        let (editor, library) = try makeEditor(files: photos)
        let loupe = editor.rootView.loupeController
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        let provider = ThumbnailProvider.shared(for: cache)
        let a = library.assets[0]
        let targets = Array(library.assets.dropFirst().prefix(10))
        let payload = try hdJPEGPayload(for: a, url: photos[0], provider: provider)
        for target in targets {
            try seedHD(target, document: otherDocument, cache: cache, data: payload)
        }

        open(editor, a.id)
        XCTAssertTrue(waitFor(90, { loupe.lastFrame != nil }), "A never presented")
        XCTAssertTrue(waitForSettledFrame(loupe, identity(a)), "A never settled")
        zoomAndPan(loupe)
        settleAfterGesture(loupe, identity(a))

        var onlyBackground = 0
        var backgroundSamples = 0
        var lines: [String] = []
        for (step, target) in targets.enumerated() {
            let photo = identity(target)
            let switchAt = CACurrentMediaTime()
            open(editor, target.id)
            XCTAssertTrue(waitForNotice(loupe, photo), "step \(step): the loupe never noticed")
            let noticeMs = (CACurrentMediaTime() - switchAt) * 1000
            let sample = sampleCanvas(loupe, photo: photo, duration: standInWindow)
            backgroundSamples += sample.backgroundSamples
            if sample.standInAt == nil { onlyBackground += 1 }
            lines.append("step \(step) \(target.filename): notice "
                         + String(format: "%.1f", noticeMs) + " ms · "
                         + (sample.standInAt.map { String(format: "%.1f ms", $0 * 1000) } ?? "never")
                         + " " + (sample.standInPixels.map { "\($0.width)x\($0.height)" } ?? "nil")
                         + (sample.endedEmpty ? " EMPTY" : ""))
        }
        print("533 ② · " + lines.joined(separator: " · "))
        print("533 ② · only-background \(onlyBackground)/10 · empty samples \(backgroundSamples)")

        XCTAssertEqual(onlyBackground, 0, "10 次切图里有 \(onlyBackground) 次只有背景色："
                       + lines.joined(separator: " · "))
        XCTAssertEqual(backgroundSamples, 0, "切图窗口里出现过纯背景色的采样")
    }

    // MARK: - ③ reverse gate: an identity-blind guard loses the picture

    func testReverseGateIdentityBlindArmGuardLosesTheStandIn() throws {
        let photos = try rawFixtures(count: 2)
        let (editor, library) = try makeEditor(files: photos)
        let loupe = editor.rootView.loupeController
        let a = library.assets[0], b = library.assets[1]
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        let provider = ThumbnailProvider.shared(for: cache)
        let payload = try hdJPEGPayload(for: a, url: photos[0], provider: provider)
        try seedHD(b, document: otherDocument, cache: cache, data: payload)

        open(editor, a.id)
        XCTAssertTrue(waitFor(90, { loupe.lastFrame != nil }), "A never presented")
        XCTAssertTrue(waitForSettledFrame(loupe, identity(a)), "A never settled")
        zoomAndPan(loupe)
        settleAfterGesture(loupe, identity(a))

        // The pre-fix guard: "a frame is on the canvas" without asking **whose**. A's settled frame
        // is still the one `presentation` names, so the switch is taken as idempotent and ①'s
        // stand-in never appears — ①'s assertion must go red for this reason.
        LoupeController.armStandInIdempotentGuardIgnoresPhoto = true
        let skipsBefore = loupe.standinArmSkips
        let installsBefore = loupe.standinInstalls
        open(editor, b.id)
        XCTAssertTrue(waitForNotice(loupe, identity(b)), "the loupe never noticed the switch")
        let sample = sampleCanvas(loupe, photo: identity(b), duration: standInWindow)
        print("533 ③ reverse gate · " + describe(loupe, photo: identity(b), sample))

        XCTAssertGreaterThan(loupe.standinArmSkips, skipsBefore,
                            "the reverse gate did not make the arm guard skip")
        XCTAssertEqual(loupe.standinInstalls, installsBefore,
                       "the identity-blind guard still installed a stand-in")
        XCTAssertNil(sample.standInAt, "the identity-blind guard still produced a stand-in")
        XCTAssertNil(loupe.currentPlaceholderPhotoForTesting)
    }

    // MARK: - ④ the cold 1024 → 1920 upgrade chain

    func testColdCacheUpgradesTheStandInFrom1024To1920() throws {
        let photos = try rawFixtures(count: 1)
        let (editor, library) = try makeEditor(files: photos)
        let loupe = editor.rootView.loupeController
        let a = library.assets[0]
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        try seedPreview(a, cache: cache)
        XCTAssertFalse(cache.exists(ThumbnailProvider.hdJPEGKey(for: a, document: .neutral)),
                       "the test is not cold: a 1920 file is already there")

        // The upgrade chain is the claim, so the real frame must not win the race for the canvas: a
        // presented frame takes the stand-in down by design (the ticket's 「有真帧就不需要 stand-in」).
        // Rendering is off for the wait; the stand-in's own arm and the 1920 warm are untouched.
        open(editor, a.id)
        loupe.autoRenderEnabled = false

        // The stand-in is on the canvas in the same turn (the 1024 preview)...
        XCTAssertTrue(waitFor(5, { loupe.firstFramePlaceholderVisible }), "no stand-in at all")
        let initial = try XCTUnwrap(loupe.firstFramePlaceholderPixels)
        XCTAssertEqual(initial.width, 1024, "the first stand-in is not the 1024 preview")

        // ...and the 344 chain still upgrades it to the 1920 file the warm writes.
        XCTAssertTrue(waitFor(120, {
            guard let size = loupe.firstFramePlaceholderPixels else { return false }
            return size.width == 1920
        }), "the stand-in never reached the 1920 rung (last "
             + "\(loupe.firstFramePlaceholderPixels.map { "\($0.width)x\($0.height)" } ?? "nil"))")
        loupe.autoRenderEnabled = true
        print("533 ④ · initial \(initial.width)x\(initial.height) → "
              + (loupe.firstFramePlaceholderPixels.map { "\($0.width)x\($0.height)" } ?? "nil"))
    }

    /// The genuinely empty cache (a library's first scan): nothing synchronous can be shown, so the
    /// requirement is the **fallback request** and then a picture — the stand-in or, if it gets there
    /// first, the real frame. Never a stall.
    func testTrulyEmptyCacheStillAsksForThePreview() throws {
        let photos = try rawFixtures(count: 1)
        let (editor, library) = try makeEditor(files: photos)
        let loupe = editor.rootView.loupeController
        let a = library.assets[0]
        let photo = identity(a)

        let fallbacksBefore = loupe.standinFallbackRequests
        let missesBefore = loupe.standinCacheMisses
        open(editor, a.id)
        XCTAssertTrue(waitFor(10, { loupe.standinFallbackRequests > fallbacksBefore }),
                      "the empty cache never asked for the embedded preview")
        XCTAssertGreaterThan(loupe.standinCacheMisses, missesBefore)
        XCTAssertTrue(waitFor(120) {
            let standIn = loupe.firstFramePlaceholderVisible
                && loupe.currentPlaceholderPhotoForTesting == photo
            let frame = loupe.currentPresentedPhotoForTesting == photo
            return standIn || frame
        }, "the empty-cache switch never put a picture on the canvas")
        print("533 ④ empty · fallbacks \(loupe.standinFallbackRequests - fallbacksBefore)"
              + " · pixels \(loupe.firstFramePlaceholderPixels.map { "\($0.width)x\($0.height)" } ?? "nil")"
              + " · presented \(loupe.currentPresentedPhotoForTesting == photo)")
    }

    // MARK: - ⑤ a cache hit installs no low-res picture

    func testCacheHitDoesNotPutAStandInOverTheCachedFrame() throws {
        let photos = try rawFixtures(count: 2)
        let (editor, library) = try makeEditor(files: photos)
        let loupe = editor.rootView.loupeController
        let a = library.assets[0], b = library.assets[1]
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        let provider = ThumbnailProvider.shared(for: cache)
        let payload = try hdJPEGPayload(for: a, url: photos[0], provider: provider)
        try seedHD(b, document: otherDocument, cache: cache, data: payload)

        open(editor, a.id)
        XCTAssertTrue(waitFor(90, { loupe.lastFrame != nil }), "A never presented")
        XCTAssertTrue(waitForSettledFrame(loupe, identity(a)), "A never settled")
        zoomAndPan(loupe)
        settleAfterGesture(loupe, identity(a))
        // The release after the gesture stores the settled canvas; wait for that store.
        loupe.scheduleRender()
        XCTAssertTrue(waitFor(90) {
            guard let key = loupe.lastCanvasFrameCacheKey else { return false }
            return loupe.canvasFrameCache.contains(key)
        }, "A's zoomed/panned canvas never reached the window cache")

        open(editor, b.id)
        XCTAssertTrue(waitForNotice(loupe, identity(b)), "the loupe never noticed B")
        XCTAssertTrue(waitFor(30, { loupe.currentPresentedPhotoForTesting == identity(b) }),
                      "B never presented")
        pump(0.2)

        let presentsBefore = loupe.canvasCachePresents
        open(editor, a.id)
        XCTAssertTrue(waitForNotice(loupe, identity(a)), "the loupe never noticed A")
        XCTAssertTrue(waitFor(10, { loupe.canvasCachePresents > presentsBefore }),
                      "the return to A was not a window-cache hit")
        XCTAssertFalse(loupe.firstFramePlaceholderVisible,
                       "a stand-in was installed over the cached frame")
        XCTAssertNotEqual(loupe.presentationContentForTesting, "empty")
        XCTAssertFalse(loupe.presentationContentForTesting.hasPrefix("placeholder("),
                       "a stand-in was installed over the cached frame")
        print("533 ⑤ · cache presents \(loupe.canvasCachePresents)"
              + " · content \(loupe.presentationContentForTesting)"
              + " · placeholder \(loupe.firstFramePlaceholderVisible)")
    }
}
