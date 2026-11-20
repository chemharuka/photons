import XCTest
import AppKit
import Metal
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 457 — 直方图缓存接入「切换照片」.
///
/// The cache itself was already there (428: 64 memory entries + `HistogramStore`). The defect this
/// file pins is the **key**: a switch starts with the new photo's 0.5 preview rung (or with no rung of
/// it at all), and the key was built from the frame's rung, so it named `…-s0.5` while every stored
/// entry was `…-s1.0`. The preview was measured into a second set of numbers, then the full rung moved
/// the key again and the picture was measured a second time — the cache was never read.
///
/// The assertions are the user-visible facts: switching to a measured photo costs **zero**
/// measurements and one publish (at the switch, before its first frame), a preview may only show
/// cached numbers and never writes `…-s0.5`, and the old rung-derived key is shown red through the
/// reverse-gate hook.
@MainActor
final class HistogramSwitchCache457Tests: XCTestCase {

    private static let viewport = ImageSize(width: 2560, height: 1600)
    private var windows: [NSWindow] = []
    private var roots: [URL] = []

    override func tearDown() {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
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

    /// Two distinct photo **identities** (their file names are the frame identity in this harness).
    /// Real siblings when the fixture directory has them; otherwise two copies of the one fixture.
    private func fixturePair() throws -> (URL, URL) {
        let first = try rawFixture()
        let dir = first.deletingLastPathComponent()
        let siblings = ((try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "dng" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }) ?? []
        if siblings.count >= 2 {
            return (siblings[0], siblings[1])
        }
        let root = makeRoot(prefix: "photons-457-pair")
        let a = root.appendingPathComponent("photo-a.dng")
        let b = root.appendingPathComponent("photo-b.dng")
        try FileManager.default.copyItem(at: first, to: a)
        try FileManager.default.copyItem(at: first, to: b)
        return (a, b)
    }

    private func makeRoot(prefix: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func makeController(storeRoot: URL? = nil) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = false
        controller.collectsHistogram = true
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

    // MARK: - driving the controller the way the switch harness does

    private func source(_ url: URL) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: url.lastPathComponent,
                                   viewport: Self.viewport, state: .fit)
    }

    /// The switch itself: `frameSource`'s `didSet` runs `notePhotoIdentity` → `cancelPendingFrames`,
    /// which is where 457 publishes a measured photo's numbers before its first frame.
    private func switchPhoto(_ loupe: LoupeController, to url: URL) {
        loupe.frameSource = source(url)
        pump(0.01)
    }

    /// One synchronous frame. `targetScale` is the canonical rung the loupe asked for: a preview frame
    /// renders at 0.5 while still naming the full-scale picture.
    private func render(_ loupe: LoupeController, url: URL, decodeScale: Float,
                        targetScale: Float? = nil) throws {
        _ = try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: decodeScale,
                                edit: .neutral, state: .fit, targetScale: targetScale)
    }

    @discardableResult
    private func measuredFrame(_ loupe: LoupeController, url: URL, decodeScale: Float,
                               targetScale: Float? = nil) throws -> Histogram {
        try render(loupe, url: url, decodeScale: decodeScale, targetScale: targetScale)
        return try XCTUnwrap(loupe.lastHistogram, "the frame published nothing")
    }

    /// Measure `url` in `loupe` and wait for the disk write, so a second controller can read it.
    @discardableResult
    private func measureAndPersist(_ loupe: LoupeController, url: URL) throws -> (Histogram, String) {
        switchPhoto(loupe, to: url)
        let histogram = try measuredFrame(loupe, url: url, decodeScale: 1.0)
        let key = try XCTUnwrap(loupe.lastHistogramKeyForTesting)
        let file = try XCTUnwrap(loupe.histogramDiskURL(for: key))
        XCTAssertTrue(waitFor { FileManager.default.fileExists(atPath: file.path) },
                      "the measurement was not written to disk: \(file.path)")
        return (histogram, key)
    }

    // MARK: - ① cold start, then switch to a measured photo = zero measurements

    func testSwitchToAMeasuredPhotoAfterAColdStartMeasuresNothing() throws {
        let (p, q) = try fixturePair()
        let storeRoot = makeRoot(prefix: "photons-457-store")

        // Controller A measures P at the full rung and writes the file.
        let a = makeController(storeRoot: storeRoot)
        let (histP, keyP) = try measureAndPersist(a, url: p)
        XCTAssertEqual(a.histogramMeasurementCount, 1, "opening P is one measurement")
        XCTAssertTrue(keyP.contains("-s1.0"), "the canonical key names the full rung: \(keyP)")
        XCTAssertFalse(keyP.contains("-s0.5"), "a full frame must not be filed under the preview rung")

        // Controller B is a cold start with the same cache root: Q is a photo it has never measured.
        let b = makeController(storeRoot: storeRoot)
        switchPhoto(b, to: q)
        _ = try measuredFrame(b, url: q, decodeScale: 1.0)
        let beforeSwitch = b.histogramMeasurementCount
        let publishesBefore = b.histogramPublishedCount

        // Switch to P: the numbers come from the cache **at the switch**.
        switchPhoto(b, to: p)
        XCTAssertEqual(b.histogramMeasurementCount, beforeSwitch,
                       "switching to a measured photo must measure nothing")
        XCTAssertEqual(b.histogramPublishedCount, publishesBefore + 1,
                       "the switch publishes the cached numbers")
        XCTAssertEqual(b.lastHistogramKeyForTesting, keyP,
                       "the publish belongs to P's canonical key")
        XCTAssertEqual(b.lastHistogram, histP, "and it is P's numbers, field for field")

        // The photo's first frame is the 0.5 preview; it may show the cache but not measure.
        try render(b, url: p, decodeScale: 0.5, targetScale: 1.0)
        XCTAssertEqual(b.histogramMeasurementCount, beforeSwitch,
                       "the preview frame must not measure P again")

        // The settled frame reads the same entry; nothing is re-measured.
        let again = try measuredFrame(b, url: p, decodeScale: 1.0)
        XCTAssertEqual(b.histogramMeasurementCount, beforeSwitch,
                       "the full frame is a cache hit, not a third measurement")
        XCTAssertEqual(again, histP, "bins, sampleCount, clippedHDR — the whole value is identical")
        XCTAssertEqual(again.binsDigest(), histP.binsDigest())
        XCTAssertEqual(again.sampleCount, histP.sampleCount)
        XCTAssertEqual(again.red.clippedHDR, histP.red.clippedHDR)

        print("457 ①: A measured P once; B's switch to P = "
              + "\(b.histogramMeasurementCount - beforeSwitch) measurements, "
              + "\(b.histogramPublishedCount - publishesBefore) publish · key \(keyP)")
    }

    // MARK: - ② reverse gate: the old frame-rung key measures and writes `…-s0.5`

    func testTheOldFrameRungFallbackMeasuresAndPollutesTheCache() throws {
        let url = try rawFixture()
        let loupe = makeController()
        switchPhoto(loupe, to: url)

        // The production behaviour answered with the canonical rung (full scale). The reverse gate
        // makes it answer with the preview rung, which is exactly the old `fallbackScale` behaviour.
        loupe.histogramCanonicalRungOverrideForTesting = 0.5
        defer { loupe.histogramCanonicalRungOverrideForTesting = nil }

        try render(loupe, url: url, decodeScale: 0.5, targetScale: 1.0)

        XCTAssertGreaterThanOrEqual(loupe.histogramMeasurementCount, 1,
                                    "the rung-derived key measured the preview — the red this gate must show")
        let key = try XCTUnwrap(loupe.lastHistogramKeyForTesting)
        XCTAssertTrue(key.contains("-s0.5"), "the old behaviour names the frame's rung: \(key)")
        XCTAssertTrue(loupe.histogramCacheKeysForTesting.contains { $0.contains("-s0.5") },
                      "and it stores the low-quality numbers under that key")
        print("457 ② reverse gate: 1 preview frame → "
              + "\(loupe.histogramMeasurementCount) measurement · key \(key)")
    }

    // MARK: - ③ a preview frame neither measures nor pollutes the cache

    func testAPreviewFrameDoesNotMeasureOrWriteAPreviewEntry() throws {
        let url = try rawFixture()
        let storeRoot = makeRoot(prefix: "photons-457-preview")
        let loupe = makeController(storeRoot: storeRoot)
        switchPhoto(loupe, to: url)

        // First frame: the 0.5 preview of a picture whose full rung is still on its way.
        try render(loupe, url: url, decodeScale: 0.5, targetScale: 1.0)
        XCTAssertEqual(loupe.histogramMeasurementCount, 0,
                       "a preview frame must not measure the picture")
        XCTAssertEqual(loupe.histogramCacheCount, 0,
                       "and must not write a cache entry for a picture it has not measured")
        XCTAssertFalse(loupe.histogramCacheKeysForTesting.contains { $0.contains("-s0.5") },
                       "no `…-s0.5` entry may exist")

        // The full rung lands: exactly one measurement, one `…-s1.0` entry.
        let histogram = try measuredFrame(loupe, url: url, decodeScale: 1.0)
        XCTAssertEqual(loupe.histogramMeasurementCount, 1,
                       "the settled frame is the one measurement")
        let keys = loupe.histogramCacheKeysForTesting
        XCTAssertFalse(keys.contains { $0.contains("-s0.5") },
                       "the preview never became a cache entry")
        XCTAssertEqual(keys.filter { $0.contains("-s1.0") }.count, 1,
                       "exactly one full-rung entry: \(keys)")
        XCTAssertGreaterThan(histogram.sampleCount, 0)
        print("457 ③: preview 0.5 measured 0, full 1.0 measured 1 · cache \(keys.count) entry")
    }

    // MARK: - ④ the switch publishes before the new photo's first frame

    func testTheSwitchPublishesTheMeasuredPhotoBeforeItsFirstFrame() throws {
        let (p, q) = try fixturePair()
        let storeRoot = makeRoot(prefix: "photons-457-publish")

        let a = makeController(storeRoot: storeRoot)
        let (histP, keyP) = try measureAndPersist(a, url: p)

        let b = makeController(storeRoot: storeRoot)
        switchPhoto(b, to: q)
        _ = try measuredFrame(b, url: q, decodeScale: 1.0)
        XCTAssertFalse(b.histogramCacheKeysForTesting.contains(keyP),
                       "P is on disk, not resident in B — the switch is a disk hit")

        let measurementsBefore = b.histogramMeasurementCount
        let publishesBefore = b.histogramPublishedCount
        let presentedBefore = b.currentPresentedPhotoForTesting
        XCTAssertNotEqual(presentedBefore, p.lastPathComponent,
                          "no frame of P has been presented yet")

        // No frame request of any kind between this switch and the assertions below.
        switchPhoto(b, to: p)
        XCTAssertEqual(b.histogramPublishedCount, publishesBefore + 1,
                       "P's numbers reached the card at the switch")
        XCTAssertEqual(b.histogramMeasurementCount, measurementsBefore,
                       "…without a measurement")
        XCTAssertEqual(b.lastHistogramKeyForTesting, keyP,
                       "the card is showing P's key")
        XCTAssertEqual(b.lastHistogram, histP,
                       "the card is showing P's numbers, not Q's")
        XCTAssertNotEqual(b.currentPresentedPhotoForTesting, p.lastPathComponent,
                          "and P's first frame still has not been presented")
        print("457 ④: switch to P published \(keyP) before its first frame")
    }
}
