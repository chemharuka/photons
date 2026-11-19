import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 428 — 切换照片后不需要等直方图加载.
///
/// Two independent reasons made the loupe re-measure on every switch, and this file pins both:
///
///   ① `cancelPendingFrames` threw the whole in-memory cache away. Only the de-dupe key
///      (`histogramFrameKey`) has to go: every entry is keyed by the document + recipe, so another
///      photo's entry can never be read for this one. ② the memory window was 8 entries and nothing
///      was on disk. Both are gone (64 entries + `HistogramStore`); the store's own format and
///      failure modes are `HistogramStoreTests`' business, and this file proves the **wiring**:
///      a photo switch keeps the cache, a revisit publishes instead of measuring, and the ceiling
///      path still empties it.
///
/// A① is the closing criterion: A → B → A on *different photos* is three frames and two
/// measurements, and ten photos with a revisit is eleven frames and ten measurements.
@MainActor
final class HistogramCache428Tests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)
    private var windows: [NSWindow] = []
    private var scratch: URL?

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        scratch = nil
        super.tearDown()
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

    /// The sibling `.dng` files next to the first fixture — real, different photographs.
    private func siblingFixtures(_ count: Int) throws -> [URL] {
        let first = try rawFixture()
        let dir = first.deletingLastPathComponent()
        let all = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                               includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard all.count >= count else {
            throw XCTSkip("need \(count) DNG fixtures beside \(first.lastPathComponent)")
        }
        return Array(all.prefix(count))
    }

    /// A small RAW copied under `count` distinct file names: distinct **photo identities** (the frame
    /// key is the URL's last path component there), one cheap decode each. This is the window test
    /// (10 photos ≫ the old 8), not a claim about content.
    private func smallCopies(_ count: Int) throws -> [URL] {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/small-rggb.dng")
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw XCTSkip("missing Tests/Fixtures/small-rggb.dng")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-428-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scratch = root
        return try (0..<count).map { i in
            let url = root.appendingPathComponent("photo-\(i).dng")
            try FileManager.default.copyItem(at: source, to: url)
            return url
        }
    }

    private func makeController(storeRoot: URL? = nil) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = true
        // 428 — an injected root means the disk half is this test's own directory, not the user's
        // library cache (and it works with no library open at all).
        if let storeRoot {
            controller.histogramStore = HistogramStore(root: storeRoot)
        }
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                                      styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = controller.view
        controller.canvasView.frame = window.contentLayoutRect
        windows.append(window)
        controller.view.layoutSubtreeIfNeeded()
        pump(0.05)
        return controller
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func source(_ url: URL, identity: String) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: identity, viewport: Self.viewport, state: .fit)
    }

    /// One frame the way the tests drive it (synchronous, so the counters are the frame's own).
    @discardableResult
    private func frame(_ loupe: LoupeController, url: URL) throws -> Histogram {
        _ = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                edit: .neutral, state: .fit)
        return try XCTUnwrap(loupe.lastHistogram, "the frame published nothing")
    }

    /// 428 — the switch itself: `frameSource`'s `didSet` runs `notePhotoIdentity` →
    /// `cancelPendingFrames`, which is the one place the old code emptied the cache.
    private func switchPhoto(_ loupe: LoupeController, to url: URL, identity: String) {
        loupe.frameSource = source(url, identity: identity)
        pump(0.01)
    }

    // MARK: - A① / A② three different photos, two measurements

    /// The smallest cross-photo case: A, B, back to A. Two measurements for three frames — this is the
    /// task's A① in its literal form (and the one the old code failed, because the switch emptied the
    /// cache).
    func testTwoPhotosThenBackIsTwoMeasurements() throws {
        let urls = try siblingFixtures(2)
        let (a, b) = (urls[0], urls[1])
        let loupe = makeController()

        switchPhoto(loupe, to: a, identity: "photo-a")
        let histA = try frame(loupe, url: a)
        switchPhoto(loupe, to: b, identity: "photo-b")
        _ = try frame(loupe, url: b)
        switchPhoto(loupe, to: a, identity: "photo-a")
        _ = try frame(loupe, url: a)

        XCTAssertEqual(loupe.histogramRefreshCount, 2,
                       "A → B → A across two photos must be two measurements, not three")
        XCTAssertEqual(try XCTUnwrap(loupe.lastHistogram), histA, "and A's own numbers came back")
        print("428 A① (2): 3 frames → \(loupe.histogramRefreshCount) measurements")
    }

    /// A → B → A on **three different files**: the third frame publishes A's numbers out of the cache
    /// and measures nothing. This is `:8619`'s "A → B → A is two measurements" across photos, which is
    /// exactly what the old `histogramCache.removeAll()` on a switch made impossible.
    func testADifferentPhotoSwitchKeepsTheCacheAndRevisitingAIsFree() throws {
        let urls = try siblingFixtures(3)
        let a = urls[0], b = urls[1], c = urls[2]
        let loupe = makeController()

        switchPhoto(loupe, to: a, identity: "photo-a")
        let histA = try frame(loupe, url: a)
        let digestA = histA.binsDigest()
        XCTAssertEqual(loupe.histogramRefreshCount, 1, "the first photo is one measurement")
        let cacheAfterA = loupe.histogramCacheCount
        XCTAssertGreaterThan(cacheAfterA, 0)

        switchPhoto(loupe, to: b, identity: "photo-b")
        // A② — the switch must not empty the cache. (This is the assertion the old code failed.)
        XCTAssertEqual(loupe.histogramCacheCount, cacheAfterA,
                       "switching photos must not throw the measured numbers away")
        let histB = try frame(loupe, url: b)
        XCTAssertNotEqual(histB.binsDigest(), digestA, "B is a different photograph")
        XCTAssertEqual(loupe.histogramRefreshCount, 2, "B is a second measurement")
        XCTAssertEqual(loupe.histogramCacheCount, 2)

        switchPhoto(loupe, to: c, identity: "photo-c")
        XCTAssertEqual(loupe.histogramCacheCount, 2, "still not emptied on the second switch")
        _ = try frame(loupe, url: c)
        XCTAssertEqual(loupe.histogramRefreshCount, 3)

        // Back to A: the numbers are A's, and nothing was measured.
        switchPhoto(loupe, to: a, identity: "photo-a")
        let again = try frame(loupe, url: a)
        XCTAssertEqual(again.binsDigest(), digestA, "the card came back to A's numbers")
        XCTAssertEqual(again, histA, "…field for field, not just the shape of the plot")
        XCTAssertEqual(loupe.histogramRefreshCount, 3,
                       "A → B → C → A must be three measurements, not four")
        XCTAssertEqual(loupe.histogramPublishCount, 4, "…and four publishes: every frame reaches the card")

        print("428 A①: 3 photos → \(loupe.histogramRefreshCount) measurements, "
              + "\(loupe.histogramPublishCount) publishes, cache \(loupe.histogramCacheCount) entries")
    }

    /// Ten photos, then the first one again: eleven frames, ten measurements. The old window was 8
    /// entries, so this is where "8 is not enough" is asserted rather than assumed.
    func testTenPhotosThenTheFirstIsStillACacheHit() throws {
        let urls = try smallCopies(10)
        let loupe = makeController()

        for (i, url) in urls.enumerated() {
            switchPhoto(loupe, to: url, identity: "photo-\(i)")
            _ = try frame(loupe, url: url)
        }
        XCTAssertEqual(loupe.histogramRefreshCount, 10, "ten different photos, ten measurements")
        XCTAssertEqual(loupe.histogramCacheCount, 10,
                       "all ten are still cached — the old limit of 8 would have evicted the first two")

        let first = urls[0]
        let digestFirst = try XCTUnwrap(loupe.lastHistogram).binsDigest()
        switchPhoto(loupe, to: first, identity: "photo-0")
        _ = try frame(loupe, url: first)
        XCTAssertEqual(loupe.histogramRefreshCount, 10,
                       "photo 0 was re-measured after nine switches — the cache lost it")
        XCTAssertEqual(try XCTUnwrap(loupe.lastHistogram).binsDigest(), digestFirst)

        print("428 A① (10): \(loupe.histogramRefreshCount) measurements for 11 frames, "
              + "cache \(loupe.histogramCacheCount) entries")
    }

    // MARK: - A⑥ / wiring — a second controller reads the first one's file

    /// The disk half through the shipped path: controller 1 frames a photo and writes the file;
    /// controller 2 (a stand-in for the next launch: no memory, same test root) reads it back under the
    /// same key and gets the same numbers field for field.
    func testAFreshControllerReadsTheWrittenFile() throws {
        let url = try rawFixture()
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-428-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let first = makeController(storeRoot: storeRoot)
        switchPhoto(first, to: url, identity: "disk-photo")
        let measured = try frame(first, url: url)
        let key = try XCTUnwrap(first.lastHistogramKeyForTesting)
        let file = try XCTUnwrap(first.histogramDiskURL(for: key))

        // The write is asynchronous on purpose (a frame must not wait for the file).
        XCTAssertTrue(waitFor { FileManager.default.fileExists(atPath: file.path) },
                      "no file was written for \(key)")
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size ?? 0, 8192, "8 × 256 Int32 of bins and the metadata plist")

        let second = makeController(storeRoot: storeRoot)
        let loaded = try XCTUnwrap(second.cachedHistogram(for: key),
                                   "a second controller could not read the file the first one wrote")
        XCTAssertEqual(loaded, measured, "the disk round trip must be field-for-field equal")
        XCTAssertEqual(loaded.binsDigest(), measured.binsDigest())

        print("428 disk round trip: \(size ?? 0) B · \(key)")
    }

    /// A④ through the controller: another document is another key, and the cache answers `nil` for it.
    func testAnotherEditIsAMissInTheCache() throws {
        let url = try rawFixture()
        let loupe = makeController()
        switchPhoto(loupe, to: url, identity: "recipe-photo")
        _ = try frame(loupe, url: url)
        let neutralKey = try XCTUnwrap(loupe.lastHistogramKeyForTesting)

        var brighter = EditModel.neutral
        brighter.light.exposure += 1
        _ = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: 0.5,
                                edit: brighter, state: .fit)
        let brighterKey = try XCTUnwrap(loupe.lastHistogramKeyForTesting)

        XCTAssertNotEqual(neutralKey, brighterKey, "a different document must be a different key")
        XCTAssertNotNil(loupe.cachedHistogram(for: neutralKey))
        XCTAssertNil(loupe.cachedHistogram(for: brighterKey.replacingOccurrences(of: "256", with: "512")),
                     "a key nobody measured is a miss")
    }

    // MARK: - A⑦ the ceiling path still empties the cache

    /// `highlightCeilingDidChange` means every measurement's meaning moved (the ceiling is in the key
    /// *and* in the bins), so that path must keep emptying the cache. 428 changed the **photo switch**
    /// and nothing else.
    func testCeilingChangeStillEmptiesTheCache() throws {
        let url = try rawFixture()
        let loupe = makeController()
        switchPhoto(loupe, to: url, identity: "ceiling-photo")
        _ = try frame(loupe, url: url)
        XCTAssertGreaterThan(loupe.histogramCacheCount, 0)

        let before = HighlightCeiling.currentEV
        defer { HighlightCeiling.setEV(before) }
        HighlightCeiling.setEV(before == 2.3 ? 1.0 : before + 0.1)
        pump(0.05)

        XCTAssertEqual(loupe.histogramCacheCount, 0,
                       "a ceiling change must drop every measurement measured at the old ceiling")
    }
}
