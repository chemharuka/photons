import XCTest
import AppKit
import Metal
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 491 — 探针：A → B → A → B → A，同画布、同缩放、同中心，每次停留至 settled。
///
/// 目的不是再写一个缓存，而是把「为什么没命中」量出来：每一步打印
/// `canvasCacheMissReasons` 的六个计数，以及这一步的键。数字写进 `local/REPORT.md`。
///
/// 诊断结论：表里一直有 A，`lookup` 却**根本没被调用** —— `lastCanvasCachePresentedKey` 在
/// 「A 命中过 → 去一张没缓存的 C → 回 A」时仍停在 A，`scheduleRender` 因此跳过了这次 lookup。
/// 六个 reason 全为 0，`hits` 不动。本文件的 `testABACAReturn…` 是这个缺口的反向门。
@MainActor
final class CanvasCacheHit491Tests: XCTestCase {

    private static let viewport = ImageSize(width: 640, height: 400)
    private var windows: [NSWindow] = []
    private var workDir: URL?

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        CanvasFrameCache.browsingCapacity = 10
        CanvasFrameCache.editingCapacity = 3
        CanvasFrameCache.invalidatesOnEdit = true
        CanvasFrameCache.protectsCurrentPhoto = true
        CanvasFrameCache.quantizesCanvasCamera = true
        CanvasFrameCache.canonicalizesCanvasEditDigest = true
        super.tearDown()
    }

    // MARK: - fixtures / harness

    private func rawFixtures() throws -> (URL, URL) {
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
        let second = siblings
            .filter { $0.standardizedFileURL != firstURL.standardizedFileURL }
            .filter { ["dng", "DNG", "raw", "RAW"].contains($0.pathExtension) }
            .filter { FileManager.default.isReadableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
        guard let second else { throw XCTSkip("two RAW fixtures are required") }
        return (firstURL, second)
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

    private func makeController() -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        TestWindows.show(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.autoRenderEnabled = true
        return controller
    }

    private func source(_ url: URL, _ identity: String,
                        state: LoupeViewState = .fit,
                        edit: EditModel = .neutral) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: identity, viewport: Self.viewport,
                                    state: state, edit: edit)
    }

    @discardableResult
    private func switchTo(_ controller: LoupeController, _ url: URL,
                          _ identity: String,
                          state: LoupeViewState = .fit,
                          edit: EditModel = .neutral) throws -> CanvasFrameCache.Key {
        controller.frameSource = source(url, identity, state: state, edit: edit)
        controller.scheduleRender()
        return try XCTUnwrap(controller.lastCanvasFrameCacheKey)
    }

    /// Wait until this photo's settled frame is stored and the scheduled render is done.
    @discardableResult
    private func settle(_ controller: LoupeController, _ url: URL,
                        _ identity: String,
                        state: LoupeViewState = .fit,
                        edit: EditModel = .neutral) throws -> CanvasFrameCache.Key {
        let key = try switchTo(controller, url, identity, state: state, edit: edit)
        XCTAssertTrue(waitFor { controller.canvasFrameCache.contains(key) },
                      "the settled frame of \(identity) never reached the canvas cache")
        // The store lands inside `present`; let any follow-up present/queue work drain so the next
        // step starts from a quiet table.
        pump(0.1)
        return key
    }

    private func reasonCounts(_ controller: LoupeController) -> String {
        let r = controller.canvasCacheMissReasons
        return "noEntry=\(r[.noEntryForPhoto]) display=\(r[.displayChanged])"
            + " document=\(r[.documentChanged]) camera=\(r[.cameraChanged])"
            + " canvas=\(r[.canvasChanged]) decodeScale=\(r[.decodeScaleChanged])"
    }

    private func note(_ line: String) {
        FileHandle.standardError.write(Data("CACHE491 \(line)\n".utf8))
    }

    private func describe(_ key: CanvasFrameCache.Key) -> String {
        "photo=\(key.photo) digest=\(key.editDigest) geom=\(key.geometry.isEmpty ? "-" : key.geometry)"
            + " camera=\(key.cameraState) viewport=\(key.viewport.width)x\(key.viewport.height)"
            + " mode=\(key.mode) fit=\(key.fitScale) role=\(key.canvasRole)"
            + " crop=\(key.cropIsActive) warn=\(key.highlightWarning)"
            + String(format: " hr=%.4f scale=%.4f", key.headroom, key.decodeScale)
    }

    private func edit(pointActive: Int?) -> EditModel {
        var edit = EditModel.neutral
        let swatch = PointColor(sampleHue: 30, sampleChroma: 0.08)
        edit.color.point = PointColorSet(swatches: [swatch, swatch], active: pointActive)
        return edit
    }

    // MARK: - ① the acceptance probe: A → B → A → B → A

    func testABABAPrintsEveryMissReason() throws {
        let (a, b) = try rawFixtures()
        let controller = makeController()
        let cache = controller.canvasFrameCache
        let plan: [(String, URL)] = [("A", a), ("B", b), ("A", a), ("B", b), ("A", a)]
        var steps: [(hits: Int, misses: Int, stores: Int, reasons: String)] = []

        for (step, entry) in plan.enumerated() {
            let before = (cache.hits, cache.misses, cache.stores)
            let key = try settle(controller, entry.1, "cache491-\(entry.0.lowercased())")
            let after = (cache.hits, cache.misses, cache.stores)
            note("step\(step) \(entry.0) hits \(before.0)->\(after.0) "
                 + "misses \(before.1)->\(after.1) stores \(before.2)->\(after.2) "
                 + "count=\(cache.count)/\(cache.capacity)")
            note("step\(step) key \(describe(key))")
            note("step\(step) reasons \(reasonCounts(controller))")
            steps.append((after.0, after.1, after.2, reasonCounts(controller)))
        }

        // 第三次（A 回来）必须命中，且这一次不新增任何 miss reason.
        XCTAssertEqual(steps[2].hits, steps[1].hits + 1, "A→B→A: the third visit must hit")
        XCTAssertEqual(steps[2].misses, steps[1].misses, "the third visit must not add a miss")
        XCTAssertEqual(steps[2].reasons, steps[1].reasons, "the third visit must not add a reason")
        // 五轮里每张只算一次：misses == 2（首见 A、首见 B），其余三轮全命中.
        let diagnostics = controller.canvasFrameCacheDiagnostics
        XCTAssertEqual(diagnostics.misses, 2, "five visits, two photos: only two computes")
        XCTAssertEqual(diagnostics.stores, 2, "each photo is copied into the cache once")
        XCTAssertEqual(diagnostics.hits, 3, "the other three visits are hits")
        let reasons = controller.canvasCacheMissReasons
        XCTAssertEqual(reasons[.noEntryForPhoto], 2, "only the two first visits may miss")
        XCTAssertEqual(reasons.total, 2, "no document/camera/canvas/decode-scale miss:")
        note("FINAL hits=\(diagnostics.hits) misses=\(diagnostics.misses)"
             + " stores=\(diagnostics.stores) evictions=\(diagnostics.evictions)"
             + " count=\(diagnostics.count)/\(diagnostics.capacity) \(reasonCounts(controller))")
    }

    // MARK: - ② the regression the diagnosis found: A → B → A → C → A

    /// The user's actual sequence: A was a hit, then a photo **not** in the table (C), then back to A.
    /// Before 491 the dispatch gate still held A's key and skipped the lookup, so the cache held the
    /// frame while the canvas waited for a fresh decode. `hits` must move on the last step.
    func testABACAReturnAfterAnUncachedPhotoStillHits() throws {
        let (a, b) = try rawFixtures()
        let controller = makeController()
        let cache = controller.canvasFrameCache
        let plan: [(String, URL)] = [("A", a), ("B", b), ("A", a), ("C", b), ("A", a)]
        var stepHits: [Int] = []
        var stepMisses: [Int] = []

        for (step, entry) in plan.enumerated() {
            let identity = "cache491-abaca-\(entry.0.lowercased())"
            _ = try settle(controller, entry.1, identity)
            stepHits.append(cache.hits)
            stepMisses.append(cache.misses)
            note("abaca step\(step) \(entry.0) hits=\(cache.hits) misses=\(cache.misses) "
                 + "count=\(cache.count)/\(cache.capacity) \(reasonCounts(controller))")
        }

        XCTAssertEqual(stepHits[2], stepHits[1] + 1, "the first return to A is a hit")
        XCTAssertEqual(stepHits[4], stepHits[3] + 1,
                       "the return to A after an uncached C must still hit — it is in the table")
        XCTAssertEqual(stepMisses[4], stepMisses[3], "the last return is not a miss")
        XCTAssertEqual(stepMisses.reduce(0, +) > 0, true)
        XCTAssertTrue(cache.contains(try XCTUnwrap(controller.lastCanvasFrameCacheKey)),
                      "A is in the table when the user comes back to it")
    }

    // MARK: - ③ the user's rule: a view that did not move hits; a view that moved may miss

    /// A different point-colour **selection** is a cursor, not a pixel: it must not split the key.
    func testADifferentPointColourSelectionDoesNotMiss() throws {
        let (a, b) = try rawFixtures()
        let controller = makeController()
        let cache = controller.canvasFrameCache

        _ = try settle(controller, a, "cache491-cursor-a", edit: edit(pointActive: 0))
        _ = try settle(controller, b, "cache491-cursor-b")
        let hitsBefore = cache.hits
        let documentBefore = controller.canvasCacheMissReasons[.documentChanged]

        _ = try settle(controller, a, "cache491-cursor-a", edit: edit(pointActive: 1))

        XCTAssertEqual(cache.hits, hitsBefore + 1,
                       "moving the point-colour cursor must not invalidate the canvas")
        XCTAssertEqual(controller.canvasCacheMissReasons[.documentChanged], documentBefore,
                       "selecting another swatch is not a document change")
    }

    /// A real zoom change is a camera move: it **may** miss, and the miss must be named `camera`.
    func testARealZoomChangeMissesAsCameraChanged() throws {
        let (a, _) = try rawFixtures()
        let controller = makeController()
        let photo = "cache491-camera-a"

        _ = try settle(controller, a, photo, state: .fit)
        let cameraBefore = controller.canvasCacheMissReasons[.cameraChanged]
        let hitsBefore = controller.canvasFrameCache.hits

        _ = try settle(controller, a, photo,
                       state: LoupeViewState(mode: .actual, zoom: 2, centerX: 100, centerY: 50))

        XCTAssertEqual(controller.canvasFrameCache.hits, hitsBefore,
                       "a zoom move must not be served from the old camera")
        XCTAssertEqual(controller.canvasCacheMissReasons[.cameraChanged], cameraBefore + 1,
                       "the miss must be attributed to the camera")
    }

    // MARK: - ④ unit: the key is stable for one document, one view

    func testSameDocumentTwiceBuildsTheSameDigestEvenWhenACursorMoves() {
        let first = edit(pointActive: 0)
        var second = edit(pointActive: 1)
        // A metadata field that no renderer reads: its change must not re-key the canvas either.
        second.forwardCompatVersion = 99

        XCTAssertEqual(CanvasFrameCache.pixelEditDigest(first),
                       CanvasFrameCache.pixelEditDigest(second),
                       "two constructions of one document must produce one digest")

        let factsA = LoupeFrameFacts(canvas: "pixel-491", edit: CanvasFrameCache.pixelCanonicalEdit(first),
                                     camera: .fit, viewport: Self.viewport, mode: .edited,
                                     fitScale: 1, canvasRole: .export, cropIsActive: false,
                                     highlightWarning: false, headroom: 1, decodeScale: 1,
                                     primaries: .displayP3, ceiling: HighlightCeiling.current,
                                     digestSuffix: "")
        let factsB = LoupeFrameFacts(canvas: "pixel-491", edit: CanvasFrameCache.pixelCanonicalEdit(second),
                                     camera: .fit, viewport: Self.viewport, mode: .edited,
                                     fitScale: 1, canvasRole: .export, cropIsActive: false,
                                     highlightWarning: false, headroom: 1, decodeScale: 1,
                                     primaries: .displayP3, ceiling: HighlightCeiling.current,
                                     digestSuffix: "")
        XCTAssertEqual(CanvasFrameCache.Key(facts: factsA), CanvasFrameCache.Key(facts: factsB))

        // Reverse gate — spelling the cursor again makes the two keys differ (this is the old bug).
        CanvasFrameCache.canonicalizesCanvasEditDigest = false
        XCTAssertNotEqual(CanvasFrameCache.pixelEditDigest(first),
                          CanvasFrameCache.pixelEditDigest(second),
                          "⑧: without the projection the cursor is back in the digest")
    }

    func testSameViewTwiceBuildsTheSameKey() {
        let stateA = LoupeViewState(mode: .actual, zoom: 1, centerX: 1000, centerY: 600)
        let stateB = LoupeViewState(mode: .actual, zoom: 1.0000000000000002,
                                    centerX: 1000.0000000000001, centerY: 600.0000000000001)
        func key(_ state: LoupeViewState) -> CanvasFrameCache.Key {
            CanvasFrameCache.Key(facts: LoupeFrameFacts(
                canvas: "view-491", edit: .neutral, camera: state, viewport: Self.viewport,
                mode: .edited, fitScale: 1, canvasRole: .export, cropIsActive: false,
                highlightWarning: false, headroom: 1, decodeScale: 1, primaries: .displayP3,
                ceiling: HighlightCeiling.current, digestSuffix: ""), quantizeCamera: true)
        }

        XCTAssertEqual(key(stateA), key(stateB),
                       "two readings of one view must spell one key")

        // Reverse gate — without the quantization the last-ulp difference is a second key.
        CanvasFrameCache.quantizesCanvasCamera = false
        XCTAssertNotEqual(key(stateA), key(stateB),
                          "⑧: without quantization the ulp difference splits the key")
    }

    // MARK: - ⑤ unit: 10 / 3 and the LRU victim

    private func makeEmptyCache() throws -> CanvasFrameCache {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("no Metal device") }
        return CanvasFrameCache()
    }

    private func dummyKey(photo: String, digest: String = "digest") -> CanvasFrameCache.Key {
        CanvasFrameCache.Key(photo: photo, decodeInputs: "d", editDigest: digest,
                             geometry: "", cameraState: "fit", viewport: Self.viewport,
                             mode: "edited", fitScale: 0.9, canvasRole: "export",
                             cropIsActive: false, highlightWarning: false, headroom: 1)
    }

    private func dummyFrame(size: ImageSize = ImageSize(width: 16, height: 16))
        throws -> LoupeController.FrameResult {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: size.width, height: size.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let rect = ImageRect(x: 0, y: 0, width: size.width, height: size.height)
        return LoupeController.FrameResult(
            texture: texture, canvas: size, content: size, photoRect: rect, presentRect: rect,
            outputWindow: nil, decodeScale: 1, decodeMilliseconds: 0, renderMilliseconds: 0,
            usedCachedDecode: true, capabilities: nil, primaries: .displayP3,
            editRevision: 0, edit: .neutral, displayHash: nil, zoom: 1, headroom: 1,
            window: size, clipped: nil, sceneLinearSample: nil, mode: .edited,
            trace: RenderTrace(), whiteBalanceGain: SIMD3<Double>(1, 1, 1),
            frameInCanvas: size, frameOrigin: SIMD2<Float>(0, 0), expandedCanvas: nil,
            neverUpscalesContent: false)
    }

    func testBrowsingKeepsTenThenThree() throws {
        let cache = try makeEmptyCache()
        var keys: [CanvasFrameCache.Key] = []
        for index in 0..<11 {
            let key = dummyKey(photo: "cap491-\(index)")
            keys.append(key)
            // Name the photo on screen, as the shipping path's `lookup` does before the store.
            _ = cache.lookup(key)
            cache.store(try dummyFrame(), key: key)
        }
        XCTAssertEqual(cache.capacity, 10, "browsing capacity is 10")
        XCTAssertEqual(cache.count, 10, "the eleventh photo evicts one")
        XCTAssertEqual(cache.evictions, 1)
        XCTAssertFalse(cache.contains(keys[0]), "the oldest entry is the victim")
        XCTAssertTrue(cache.contains(keys[10]), "the newest entry survives")
        XCTAssertTrue(cache.contains(keys[1]), "the second-oldest is not evicted yet")

        // The current photo is never the victim: `lookup` names it, then a store overflows.
        _ = cache.lookup(keys[1])
        cache.store(try dummyFrame(), key: dummyKey(photo: "cap491-12"))
        XCTAssertTrue(cache.contains(keys[1]), "the current photo survived the eviction")

        // Editing moves the table to three, for good.
        cache.noteEditLanded(photo: "cap491-12", digest: "digest")
        XCTAssertEqual(cache.regime, .editing)
        XCTAssertEqual(cache.capacity, 3)
        XCTAssertEqual(cache.count, 3)
        note("capacity 491: browsing=10 → editing=3, evictions=\(cache.evictions)")
    }

    /// Reverse gate — setting the browsing capacity to 1 must make the 10-slot test red.
    func testReverseGateBrowsingCapacityOne() throws {
        let cache = try makeEmptyCache()
        CanvasFrameCache.browsingCapacity = 1
        let first = dummyKey(photo: "cap491-gate-1")
        let second = dummyKey(photo: "cap491-gate-2")
        _ = cache.lookup(first)
        cache.store(try dummyFrame(), key: first)
        _ = cache.lookup(second)
        cache.store(try dummyFrame(), key: second)
        XCTAssertEqual(cache.capacity, 1)
        XCTAssertEqual(cache.count, 1, "⑧: capacity 1 keeps one")
        XCTAssertFalse(cache.contains(first))
        XCTAssertTrue(cache.contains(second))
    }

    // MARK: - ⑥ the same sequence through the shipping session path (no frameSource)

    private func makeSessionLoupe(_ files: [URL]) throws -> (LoupeController, CatalogSession, [Asset]) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-cache491-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workDir = root
        let package = root.appendingPathComponent("Cache491.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let sourceRoot = try catalog.ensureRoot(for: source, mode: .reference)
        var ids: [String] = []
        for (index, file) in files.enumerated() {
            let name = "cache491-\(index).dng"
            let destination = source.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            let size = try pixelSize(of: file)
            let bytes = (try FileManager.default.attributesOfItem(atPath: file.path)[.size]
                as? NSNumber)?.intValue ?? 1
            let id = UUID().uuidString
            ids.append(id)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(sourceRoot.id)', '\(name)', '\(name)', 'dng', 'raw',
                            \(bytes), 0, '\(UUID().uuidString)', \(size.width), \(size.height),
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-21T00:00:00Z', 0)
                    """)
            }
        }
        let assets = try ids.map { try XCTUnwrap(try catalog.asset(id: $0)) }
        let session = CatalogSession()
        try session.open(package)
        session.selectOnly(assets[0].id)
        session.mode = .loupe
        session.loadEditForAnchor()

        let controller = LoupeController(session: session)
        controller.autoRenderEnabled = false
        controller.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        windows.append(window)
        TestWindows.show(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        controller.autoRenderEnabled = true
        let deadline = Date().addingTimeInterval(3)
        while session.anchorAsset == nil, Date() < deadline { pump(0.01) }
        controller.scheduleRender()
        pump(0.1)
        return (controller, session, assets)
    }

    private func pixelSize(of url: URL) throws -> ImageSize {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return ImageSize(width: try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
                         height: try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int))
    }

    private func settleSession(_ controller: LoupeController, _ session: CatalogSession,
                               _ asset: Asset) throws -> CanvasFrameCache.Key {
        session.selectOnly(asset.id)
        session.loadEditForAnchor()
        controller.scheduleRender()
        XCTAssertTrue(waitFor(10) { controller.lastCanvasFrameCacheKey?.photo.contains(asset.id) == true },
                      "the switch never named a canvas-cache key")
        let key = try XCTUnwrap(controller.lastCanvasFrameCacheKey)
        XCTAssertTrue(waitFor { controller.canvasFrameCache.contains(key) },
                      "the settled frame never reached the canvas cache")
        pump(0.15)
        return key
    }

    func testSessionABABAPrintsEveryMissReason() throws {
        let (a, b) = try rawFixtures()
        let (controller, session, assets) = try makeSessionLoupe([a, b])
        let cache = controller.canvasFrameCache
        let plan = [0, 1, 0, 1, 0].map { assets[$0] }
        var stepHits: [Int] = []

        for (step, asset) in plan.enumerated() {
            let before = (cache.hits, cache.misses, cache.stores)
            let key = try settleSession(controller, session, asset)
            let after = (cache.hits, cache.misses, cache.stores)
            stepHits.append(after.0)
            note("session step\(step) \(asset.filename) hits \(before.0)->\(after.0) "
                 + "misses \(before.1)->\(after.1) stores \(before.2)->\(after.2) "
                 + "count=\(cache.count)/\(cache.capacity)")
            note("session step\(step) key \(describe(key))")
            note("session step\(step) reasons \(reasonCounts(controller))")
        }
        // The first switch also sees the one-time "another library" cleanup; from the third visit on
        // the shipping path must hit every return.
        XCTAssertEqual(stepHits[3], stepHits[2] + 1, "B imposed as an uncached photo still hits on return")
        XCTAssertEqual(stepHits[4], stepHits[3] + 1, "A hits again")
        let diagnostics = controller.canvasFrameCacheDiagnostics
        note("session FINAL hits=\(diagnostics.hits) misses=\(diagnostics.misses)"
             + " stores=\(diagnostics.stores) evictions=\(diagnostics.evictions)"
             + " count=\(diagnostics.count)/\(diagnostics.capacity) \(reasonCounts(controller))")
    }
}
