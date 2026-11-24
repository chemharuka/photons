import XCTest
import AppKit
import PhotonsCore
import PhotonsCatalog
@testable import PhotonsUI

/// 534 — the histogram **lands in the catalog** and the **first whole-picture frame** publishes.
///
/// Two user-visible facts are pinned here:
///
///   ① a second open of an untouched photo shows its plot **before any new frame** — the bins came
///      out of `asset_histograms`, not out of a fresh measurement. A document that changed at the
///      pixels (exposure) is a **miss** (`documentChanged`) and is measured/written again;
///   ② while the full development is still running, the 0.5 preview frame that already covers the
///      whole picture publishes its own bins, and the full rung refreshes them when it lands. The
///      two plots are compared against the dispatch's tolerances: no bucket moves more than 2 % of
///      the picture's samples, and the 削顶 fraction moves by at most 0.1 percentage point.
///
/// The noise guards are unchanged: a 1:1/200 % window frame never measures its crop, and the
/// synchronous test/smoke path still only lets the canonical rung measure (the reverse gates below).
@MainActor
final class HistogramPersist534Tests: XCTestCase {

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

    /// The sample library around the fixture: three real photographs for the tolerance table
    /// (the dispatch's 人像 / 风景 / 高光比 rows — the fixture directory is the library's own set).
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

    private func makeRoot(prefix: String) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        return root
    }

    private func makeCatalog() throws -> (Catalog, CatalogHistogramStore) {
        let root = makeRoot(prefix: "photons-534-library")
        let package = root.appendingPathComponent("test.photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: package)
        return (catalog, CatalogHistogramStore(catalog: catalog))
    }

    // MARK: - the controller

    private func makeController(persistence: CatalogHistogramStore? = nil,
                                autoRender: Bool = false) -> LoupeController {
        let controller = LoupeController(session: CatalogSession())
        controller.autoRenderEnabled = autoRender
        controller.collectsHistogram = true
        if let persistence { controller.histogramPersistence = persistence }
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

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func source(_ url: URL, identity: String, edit: EditModel = .neutral,
                        state: LoupeViewState = .fit) -> LoupeController.FrameSource {
        LoupeController.FrameSource(url: url, identity: identity,
                                   viewport: Self.viewport, state: state, edit: edit)
    }

    /// The switch itself: `frameSource`'s `didSet` runs `notePhotoIdentity`, which is where 457/534
    /// publish an already-measured photo before its first frame.
    private func switchPhoto(_ loupe: LoupeController, to url: URL, identity: String,
                             edit: EditModel = .neutral) {
        loupe.frameSource = source(url, identity: identity, edit: edit)
        pump(0.01)
    }

    @discardableResult
    private func render(_ loupe: LoupeController, url: URL, decodeScale: Float,
                        targetScale: Float? = nil, edit: EditModel = .neutral,
                        state: LoupeViewState = .fit) throws -> LoupeController.FrameResult {
        try loupe.makeFrame(url: url, viewport: Self.viewport, decodeScale: decodeScale,
                            edit: edit, state: state, targetScale: targetScale)
    }

    @discardableResult
    private func measuredFrame(_ loupe: LoupeController, url: URL, decodeScale: Float,
                               targetScale: Float? = nil, edit: EditModel = .neutral,
                               state: LoupeViewState = .fit) throws -> Histogram {
        _ = try render(loupe, url: url, decodeScale: decodeScale, targetScale: targetScale,
                       edit: edit, state: state)
        return try XCTUnwrap(loupe.lastHistogram, "the frame published nothing")
    }

    private func brighter(_ stops: Double) -> EditModel {
        var edit = EditModel.neutral
        edit.light.exposure += stops
        return edit
    }

    private func recordKey(assetID: String, edit: EditModel, scale: Float) -> HistogramRecordKey {
        HistogramRecordKey(assetID: assetID,
                           pixelDigest: CanvasFrameCache.pixelEditDigest(edit),
                           scale: scale, ceiling: HighlightCeiling.current)
    }

    // MARK: - ① the second open publishes the catalog row, with no new frame

    func testASecondOpenPublishesTheCatalogEntryWithNoNewFrame() throws {
        let url = try rawFixture()
        let (catalog, store) = try makeCatalog()
        let identity = url.lastPathComponent
        let key = recordKey(assetID: identity, edit: .neutral, scale: 1.0)

        let a = makeController(persistence: store)
        switchPhoto(a, to: url, identity: identity)
        let first = try measuredFrame(a, url: url, decodeScale: 1.0)
        XCTAssertTrue(waitFor { store.load(key) != nil },
                      "the measurement was never written to asset_histograms")
        let stored = try XCTUnwrap(store.load(key))
        XCTAssertEqual(stored, first, "the catalog row must be the numbers the card showed")
        XCTAssertEqual(catalog.schemaVersionApplied, Schema.version,
                       "opening a library migrates it to the histogram schema")

        // A second controller is the next launch: empty memory, empty file cache, same catalog.
        let b = makeController(persistence: store)
        switchPhoto(b, to: url, identity: identity)
        XCTAssertEqual(b.histogramPublishedCount, 1,
                       "the switch must publish the catalog's numbers")
        XCTAssertEqual(b.histogramMeasurementCount, 0,
                       "…without measuring anything")
        XCTAssertNil(b.lastFrame, "no frame of this photo has been rendered or presented")
        XCTAssertEqual(b.lastHistogram, first, "the plot is byte-for-byte the first run's")
        XCTAssertEqual(b.lastHistogram?.red.bins, first.red.bins)
        XCTAssertEqual(b.lastHistogram?.luma.hdrBins, first.luma.hdrBins)
        print("534 ①: second open published \(key.assetID) from the catalog with no frame")
    }

    // MARK: - ② a changed pixel digest is a miss, then the new row is written

    func testChangedExposureMissesTheCatalogRowAndWritesTheNewOne() throws {
        let url = try rawFixture()
        let (_, store) = try makeCatalog()
        let identity = url.lastPathComponent
        let neutralKey = recordKey(assetID: identity, edit: .neutral, scale: 1.0)
        let edited = brighter(1)
        let editedKey = recordKey(assetID: identity, edit: edited, scale: 1.0)
        XCTAssertNotEqual(neutralKey.pixelDigest, editedKey.pixelDigest,
                          "exposure reaches the pixels, so the digest must move")

        let a = makeController(persistence: store)
        switchPhoto(a, to: url, identity: identity)
        _ = try measuredFrame(a, url: url, decodeScale: 1.0)
        XCTAssertTrue(waitFor { store.load(neutralKey) != nil })

        // The next launch opens the photo with the exposure changed.
        let b = makeController(persistence: store)
        switchPhoto(b, to: url, identity: identity, edit: edited)
        XCTAssertEqual(b.histogramMissReasons.documentChanged, 1,
                       "another digest must be named `documentChanged`, never served approximately")
        XCTAssertNil(b.lastHistogram, "the previous document's plot must not stand in")
        XCTAssertEqual(b.histogramPublishedCount, 0)

        // The new document measures and writes its own row; the old one is left alone.
        let measured = try measuredFrame(b, url: url, decodeScale: 1.0, edit: edited)
        XCTAssertTrue(waitFor { store.load(editedKey) != nil },
                      "the changed document was not written back")
        let rewritten = try XCTUnwrap(store.load(editedKey))
        XCTAssertEqual(rewritten, measured)
        XCTAssertNotEqual(rewritten.binsDigest(),
                          try XCTUnwrap(store.load(neutralKey)).binsDigest(),
                          "a brighter document is a different distribution")
        print("534 ②: exposed document missed with documentChanged and wrote \(editedKey.pixelDigest)")
    }

    // MARK: - ③ the 0.5 preview publishes, the full rung refreshes, within tolerance

    func testThePreviewPublishesBeforeTheFullRungAndStaysWithinTolerance() throws {
        let url = try rawFixture()
        let (_, store) = try makeCatalog()
        let loupe = makeController(persistence: store, autoRender: true)
        loupe.frameSource = source(url, identity: "early-photo")
        loupe.scheduleRender()

        XCTAssertTrue(waitFor(60) {
            loupe.lastPresentedScale == DecodeLadder.previewScale && loupe.lastHistogram != nil
        }, "the 0.5 preview never reached the canvas with a plot")
        let preview = try XCTUnwrap(loupe.lastHistogram)
        let previewTime = CFAbsoluteTimeGetCurrent()
        let publishedAfterPreview = loupe.histogramPublishedCount
        XCTAssertEqual(loupe.histogramMeasurementCount, 1,
                       "the first whole-picture frame is the one measurement so far")
        XCTAssertNil(loupe.lastHistogramError)

        XCTAssertTrue(waitFor(120) {
            loupe.lastPresentedScale == DecodeLadder.fullScale
                && loupe.histogramPublishedCount > publishedAfterPreview
        }, "the full rung never refreshed the plot")
        let fullTime = CFAbsoluteTimeGetCurrent()
        let full = try XCTUnwrap(loupe.lastHistogram)
        XCTAssertLessThan(previewTime, fullTime,
                          "the preview's publish must come before the full rung's")
        XCTAssertEqual(loupe.histogramMeasurementCount, 2,
                       "preview + full: two measurements of one picture")
        XCTAssertEqual(loupe.histogramPublishedCount, 2)

        let report = tolerance(full: full, preview: preview)
        print("534 ③ early: preview \(preview.sampleCount) px → full \(full.sampleCount) px · "
              + "maxRel \(String(format: "%.3f%%", report.maxRelative * 100)) · "
              + "maxFrac \(String(format: "%.4f pp", report.maxFractionDifference * 100)) · "
              + "clippedΔ \(String(format: "%.4f pp", report.clippedDifference * 100)) · "
              + "worst \(report.detail)")
        XCTAssertLessThanOrEqual(report.maxFractionDifference,
                                 LoupeController.histogramPreviewBinRelativeTolerance,
                                 "preview bins left the 2 % envelope")
        XCTAssertLessThanOrEqual(report.clippedDifference,
                                 LoupeController.histogramPreviewClippedAbsoluteTolerance,
                                 "preview 削顶 left the 0.1 pp envelope")

        let fullKey = recordKey(assetID: "early-photo", edit: .neutral, scale: 1.0)
        XCTAssertTrue(waitFor { store.load(fullKey) != nil },
                      "the full-rung refresh was not written back to the catalog")
    }

    // MARK: - ②.4 the tolerance table on three subjects

    /// The dispatch's empirical half: compare the 0.5-rung and 1.0-rung bins for three real pictures
    /// from the sample library. The thresholds are the production constants, so this is the proof
    /// that lets `histogramStep` publish the preview at all.
    func testPreviewToleranceOnThreeSubjects() throws {
        let urls = try siblingFixtures(3)
        let subjects = ["人像", "风景", "高光比"]
        for (index, url) in urls.enumerated() {
            let loupe = makeController()
            switchPhoto(loupe, to: url, identity: "tolerance-\(index)")
            let preview = try measuredFrame(loupe, url: url, decodeScale: 0.5, targetScale: 0.5)
            let full = try measuredFrame(loupe, url: url, decodeScale: 1.0, targetScale: 1.0)
            let report = tolerance(full: full, preview: preview)
            print(String(format: "534 ②.4 %@ %@: maxRel %.3f%% · maxFrac %.4f pp · clippedΔ %.4f pp · TV %.3f%% · worst %@",
                         subjects[index], url.lastPathComponent,
                         report.maxRelative * 100, report.maxFractionDifference * 100,
                         report.clippedDifference * 100, report.totalVariation * 100,
                         report.detail))
            XCTAssertLessThanOrEqual(report.maxFractionDifference,
                                     LoupeController.histogramPreviewBinRelativeTolerance,
                                     "\(subjects[index]) preview bins left the 2 % envelope")
            XCTAssertLessThanOrEqual(report.clippedDifference,
                                     LoupeController.histogramPreviewClippedAbsoluteTolerance,
                                     "\(subjects[index]) preview 削顶 left the 0.1 pp envelope")
        }
    }

    /// One comparison. Each bucket's count is compared **relative to the picture's total** (the same
    /// convention `HistogramTests` uses for the GPU reduction's error), and only buckets where the
    /// full measurement holds at least 0.5 % of the channel are considered — a bucket with three
    /// samples is a quantisation artefact, not a distribution. The 削顶 fraction is the live read
    /// (`clippedFraction`, 464) of the luma series at the measurement's own screen.
    private struct ToleranceReport {
        var maxRelative: Double
        var maxFractionDifference: Double
        var clippedDifference: Double
        var totalVariation: Double
        var detail: String
    }

    private func tolerance(full: Histogram, preview: Histogram) -> ToleranceReport {
        XCTAssertEqual(preview.binCount, full.binCount)
        var maxRelative = 0.0
        var maxFractionDifference = 0.0
        var totalVariation = 0.0
        var worst = ""
        for channel in Histogram.Channel.allCases {
            let reference = full[channel]
            let candidate = preview[channel]
            XCTAssertEqual(candidate.bins.count, reference.bins.count)
            XCTAssertEqual(candidate.hdrBins.count, reference.hdrBins.count)
            let referenceTotal = max(reference.total, 1)
            let floor = max(1, Int(Double(referenceTotal) * 0.005))
            var sumAbsolute = 0
            for (i, pair) in zip(reference.bins, candidate.bins).enumerated() {
                let (a, b) = pair
                sumAbsolute += abs(b - a)
                maxFractionDifference = max(maxFractionDifference,
                                           Double(abs(b - a)) / Double(referenceTotal))
                guard a >= floor else { continue }
                let relative = abs(Double(b - a)) / Double(a)
                if relative > maxRelative {
                    maxRelative = relative
                    worst = "\(channel.rawValue)[\(i)] \(a)→\(b) (total \(referenceTotal))"
                }
            }
            for (i, pair) in zip(reference.hdrBins, candidate.hdrBins).enumerated() {
                let (a, b) = pair
                sumAbsolute += abs(b - a)
                maxFractionDifference = max(maxFractionDifference,
                                           Double(abs(b - a)) / Double(referenceTotal))
                guard a >= floor else { continue }
                let relative = abs(Double(b - a)) / Double(a)
                if relative > maxRelative {
                    maxRelative = relative
                    worst = "\(channel.rawValue).hdr[\(i)] \(a)→\(b) (total \(referenceTotal))"
                }
            }
            totalVariation = max(totalVariation, Double(sumAbsolute) / Double(referenceTotal))
        }
        let headroom = max(full.headroom, 1)
        let clippedDifference = abs(full.luma.clippedFraction(atOrAbove: headroom)
            - preview.luma.clippedFraction(atOrAbove: headroom))
        return ToleranceReport(maxRelative: maxRelative,
                               maxFractionDifference: maxFractionDifference,
                               clippedDifference: clippedDifference,
                               totalVariation: totalVariation,
                               detail: worst)
    }

    // MARK: - ④ a 200 % window frame never measures its crop

    func testAZoomedWindowFrameDoesNotMeasure() throws {
        let url = try rawFixture()
        let loupe = makeController()
        switchPhoto(loupe, to: url, identity: "zoom-photo")
        _ = try measuredFrame(loupe, url: url, decodeScale: 1.0)

        let measurementsBefore = loupe.histogramMeasurementCount
        let skippedBefore = loupe.histogramSkippedFrames
        let zoomed = LoupeViewState(mode: .actual, zoom: 2, centerX: 3000, centerY: 2000)
        _ = try render(loupe, url: url, decodeScale: 1.0, targetScale: 1.0,
                       edit: brighter(1), state: zoomed)

        XCTAssertEqual(loupe.histogramMeasurementCount, measurementsBefore,
                       "a 200 % frame is a crop: it must not measure")
        XCTAssertEqual(loupe.histogramSkippedFrames, skippedBefore + 1,
                       "the frame publishes nothing and is counted as such")
        XCTAssertEqual(loupe.lastHistogramError, "window frame")
        print("534 ④: 200 % frame skipped, frame measurements \(measurementsBefore) unchanged")
    }

    // MARK: - ⑤ the two reverse gates

    /// ① Replace the pixel digest with a constant: the exposure change then **hits** the stale row.
    /// The acceptance's case ② would go red (it expects `documentChanged == 1` and no plot).
    func testReverseGateAConstantDigestServesAStaleCatalogEntry() throws {
        let url = try rawFixture()
        let (_, store) = try makeCatalog()
        let constant: (EditModel) -> String = { _ in "constant-digest" }
        let identity = url.lastPathComponent

        let a = makeController(persistence: store)
        a.histogramPixelDigestForTesting = constant
        switchPhoto(a, to: url, identity: identity)
        _ = try measuredFrame(a, url: url, decodeScale: 1.0)
        let key = HistogramRecordKey(assetID: identity, pixelDigest: "constant-digest",
                                     scale: 1.0, ceiling: HighlightCeiling.current)
        XCTAssertTrue(waitFor { store.load(key) != nil })

        let b = makeController(persistence: store)
        b.histogramPixelDigestForTesting = constant
        switchPhoto(b, to: url, identity: identity, edit: brighter(1))
        XCTAssertEqual(b.histogramMissReasons.documentChanged, 0,
                       "the constant digest cannot notice the exposure change")
        XCTAssertNotNil(b.lastHistogram, "…so the stale neutral row is served — case ②'s red")
        print("534 ⑤① reverse gate: constant digest served the neutral row for a brighter document")
    }

    /// ② Restore the old `atTarget` rule: the 0.5 preview may not publish, so acceptance ③'s early
    /// publish assertion goes red.
    func testReverseGateAtTargetDoesNotPublishThePreview() throws {
        let url = try rawFixture()
        let loupe = makeController(autoRender: true)
        loupe.histogramPublishesOnPreviewForTesting = false
        loupe.frameSource = source(url, identity: "at-target-photo")
        loupe.scheduleRender()

        XCTAssertTrue(waitFor(60) { loupe.lastPresentedScale == DecodeLadder.previewScale },
                      "the preview never reached the canvas")
        XCTAssertNil(loupe.lastHistogram,
                     "atTarget: the preview must publish nothing — case ③'s red")
        XCTAssertEqual(loupe.histogramMeasurementCount, 0)

        XCTAssertTrue(waitFor(120) { loupe.lastHistogram != nil },
                      "the full rung never published")
        XCTAssertEqual(loupe.histogramPublishedCount, 1,
                       "atTarget: the first publish is the full frame's")
        print("534 ⑤② reverse gate: atTarget skipped the preview and published once at full scale")
    }
}
