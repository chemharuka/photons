import XCTest
import AppKit
import CoreGraphics
import ImageIO
import QuartzCore
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 539 — 开库后把 v9 的 ML 程序表烘热。
///
/// The feature is one background development of the anchor photo, on the loupe's existing decode
/// queue, stored into the existing ladder and never rendered. The suite pins the four properties the
/// brief names as **counts** wherever a wall clock would be noise:
///
///   · reuse: the user's first frame joins/finds the warm — one development, `v9PrewarmReused +1`;
///   · concurrency: a switch to another photo makes the warm give way and `mlInFlightPeak` stays 1;
///   · the switch: `PHOTONS_WARM_V9=0` (or the property) makes no warm at all;
///   · failure: a missing/bad anchor is one count, and the library still opens.
///
/// The first-frame comparison is the only timing test. It only lands a verdict when the machine is
/// quiet (`load < 8`); on a busy box it prints the numbers and skips, because a compile next door
/// moves both sides by more than the 30 % the acceptance asks for.
@MainActor
final class V9Prewarm539Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []
    private var cacheDirs: [URL] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-warm539-\(UUID().uuidString)", isDirectory: true)
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
            if c.hasSuffix(name) { return URL(fileURLWithPath: c) }
        }
        throw XCTSkip("no RAW fixture \(name); set PHOTONS_TEST_RAW")
    }

    private struct WarmLibrary {
        let package: URL
        let assets: [Asset]
    }

    /// A library row pointing at a real RAW (a symlink, as the other UI suites do) or at a path that
    /// does not exist (`missing: true`, the failure path).
    private func makeLibrary(files: [URL], missing: Bool = false) throws -> WarmLibrary {
        _ = NSApplication.shared
        // Every measurement run gets its own package: `Catalog.create` refuses an existing one.
        let package = workDir.appendingPathComponent("Warm-\(UUID().uuidString).\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var ids: [String] = []
        for (index, file) in files.enumerated() {
            let name = "warm\(index).dng"
            let destination = source.appendingPathComponent(name)
            if !missing {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            }
            let size = try? pixelSize(of: file)
            let id = UUID().uuidString
            ids.append(id)
            try catalog.dbQueue.write { db in
                try db.execute(sql: """
                    INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                        content_hash, width, height, camera_make, camera_model, lens,
                                        imported_at, missing)
                    VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                            '\(UUID().uuidString)',
                            \(size?.width ?? 6000), \(size?.height ?? 4000),
                            'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                            '2026-11-24T00:00:00Z', 0)
                    """)
            }
        }
        let assets = try ids.map { try XCTUnwrap(try catalog.asset(id: $0)) }
        return WarmLibrary(package: package, assets: assets)
    }

    private func makeEditor(_ library: WarmLibrary,
                            prewarm: Bool,
                            delay: TimeInterval = 0) throws -> (EditorWindowController, [Asset]) {
        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        windows.append(try XCTUnwrap(editor.window))
        let loupe = editor.rootView.loupeController
        loupe.warmsV9OnLibraryOpen = prewarm
        loupe.v9PrewarmDelayForTesting = delay
        try editor.openLibrary(at: library.package)
        return (editor, library.assets)
    }

    private func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 120, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func enterLoupe(_ editor: EditorWindowController, asset: Asset) throws {
        editor.session.selectOnly(asset.id)
        pump(0.02)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
    }

    /// Make the document explicitly ask for v9, so this suite warms the decoder the brief is about
    /// instead of relying on the automatic rule's ISO threshold.
    private func askForV9(_ session: CatalogSession) {
        session.applyEdit { $0.decoderVersion = "9.dng" }
    }

    // MARK: - ② 只解一次

    func testWarmIsReusedAndThePhotoIsDevelopedOnce() throws {
        let raw = try fixture("L1030433.dng")
        let library = try makeLibrary(files: [raw])
        let (editor, assets) = try makeEditor(library, prewarm: false)
        let loupe = editor.rootView.loupeController
        askForV9(editor.session)

        RAWDecoder.resetDecodeCounts()
        loupe.warmsV9OnLibraryOpen = true
        loupe.prewarmV9ForAnchor()
        XCTAssertTrue(loupe.isV9Prewarming, "the background development was not started")
        XCTAssertTrue(waitFor(120, { loupe.v9PrewarmFinishedAt != nil }), "the warm never finished")
        XCTAssertEqual(loupe.v9PrewarmFailureCount, 0)
        XCTAssertEqual(RAWDecoder.decodeCounts()[DecodeLadder.fullScale], 1,
                       "the warm itself must be exactly one development: \(RAWDecoder.decodeCounts())")

        try enterLoupe(editor, asset: assets[0])
        XCTAssertTrue(waitFor(120, { loupe.lastFrame != nil }), "no first frame")
        XCTAssertEqual(loupe.v9PrewarmReused, 1,
                       "the first frame did not record a prewarm reuse")
        XCTAssertEqual(RAWDecoder.decodeCounts()[DecodeLadder.fullScale], 1,
                       "the user's first frame developed the same rung again: "
                       + "\(RAWDecoder.decodeCounts())")
        XCTAssertEqual(loupe.developedRungs[DecodeLadder.fullScale], 1,
                       "the ladder received a second full rung: \(loupe.developedRungs)")
        print("539 reuse: warm finished, first frame reused; decodes \(RAWDecoder.decodeCounts()),"
              + " ladder \(loupe.developedRungs), reused \(loupe.v9PrewarmReused)")
    }

    // MARK: - ③ 并发 = 1

    func testSwitchingPhotoMakesTheWarmGiveWayAndNeverRunsTwoMLDecodes() throws {
        let first = try fixture("L1030433.dng")
        guard let second = ["L1030402.dng", "L1030403.dng", "L1030404.dng"]
            .compactMap({ try? fixture($0) }).first else {
            throw XCTSkip("no second RAW fixture")
        }
        let library = try makeLibrary(files: [first, second])
        let (editor, assets) = try makeEditor(library, prewarm: false, delay: 1.5)
        let loupe = editor.rootView.loupeController
        askForV9(editor.session)

        NeuralStageSlot.resetPeak()
        loupe.warmsV9OnLibraryOpen = true
        loupe.prewarmV9ForAnchor()
        XCTAssertTrue(loupe.isV9Prewarming, "the warm was not in flight when the switch happened")

        // The user leaves the warmed photo and opens the other one while the warm is still held.
        editor.session.selectOnly(assets[1].id)
        askForV9(editor.session)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)

        XCTAssertTrue(waitFor(180, { loupe.lastFrame != nil }), "the switched photo never presented")
        XCTAssertGreaterThanOrEqual(loupe.v9PrewarmGaveWayCount, 1,
                                    "the warm was not cancelled by the photo switch")
        XCTAssertLessThanOrEqual(NeuralStageSlot.mlInFlightPeak, 1,
                                 "two neural-stage developments overlapped: peak "
                                 + "\(NeuralStageSlot.mlInFlightPeak)")
        print("539 concurrency: gave way \(loupe.v9PrewarmGaveWayCount),"
              + " mlInFlightPeak \(NeuralStageSlot.mlInFlightPeak),"
              + " decodes \(RAWDecoder.decodeCounts())")
    }

    // MARK: - ④ 开关

    func testEnvironmentSwitchOffMeansNoWarm() throws {
        XCTAssertTrue(V9PrewarmConfiguration.isEnabled(environment: [:]))
        XCTAssertFalse(V9PrewarmConfiguration.isEnabled(environment: ["PHOTONS_WARM_V9": "0"]))
        XCTAssertFalse(V9PrewarmConfiguration.isEnabled(environment: ["PHOTONS_WARM_V9": "0 "]))
        XCTAssertTrue(V9PrewarmConfiguration.isEnabled(environment: ["PHOTONS_WARM_V9": "1"]))

        let raw = try fixture("L1030433.dng")
        let library = try makeLibrary(files: [raw])
        RAWDecoder.resetDecodeCounts()
        let (editor, assets) = try makeEditor(library, prewarm: false)
        let loupe = editor.rootView.loupeController
        pump(0.25)

        XCTAssertNil(loupe.v9PrewarmStartedAt, "a warm was requested with the switch off")
        XCTAssertFalse(loupe.isV9Prewarming)
        XCTAssertEqual(loupe.v9PrewarmReused, 0)
        XCTAssertEqual(RAWDecoder.decodeCounts()[DecodeLadder.fullScale], nil,
                       "the open developed a full rung with prewarm off: \(RAWDecoder.decodeCounts())")
        XCTAssertTrue(editor.session.isOpen, "the library did not open")
        XCTAssertEqual(assets.count, 1)
    }

    // MARK: - ⑤ 失败路径

    func testMissingAnchorIsOneFailureAndTheLibraryStillOpens() throws {
        let raw = try fixture("L1030433.dng")
        let library = try makeLibrary(files: [raw], missing: true)
        let (editor, assets) = try makeEditor(library, prewarm: true)
        let loupe = editor.rootView.loupeController

        XCTAssertTrue(waitFor(60, { loupe.v9PrewarmFinishedAt != nil }),
                      "the failed warm never reported a finish")
        XCTAssertEqual(loupe.v9PrewarmFailureCount, 1,
                       "a failed warm must be exactly one count, no retry storm")
        XCTAssertFalse(loupe.isV9Prewarming)
        XCTAssertTrue(editor.session.isOpen, "a failed warm closed the library")
        XCTAssertEqual(assets.count, 1)
        XCTAssertNotNil(editor.session.anchorAsset, "the library lost its anchor after a failed warm")
        print("539 failure: \(loupe.v9PrewarmFailureCount) count, library open \(editor.session.isOpen)")
    }

    // MARK: - ① 冷启首帧变快（只在安静的机器上落判据）

    /// `click → first frame` with the warm already landed versus the same click without any warm.
    ///
    /// Each side is three samples on the same file and the same machine. The pair is measured
    /// **within one process**: after the first v9 decode the program table is warm, which is exactly
    /// why the brief says "new process" — this test therefore only asserts when the machine is quiet
    /// and prints both p50s every time. The warm-side click starts after the background development
    /// has finished, which is the state a user reaches by the time they have picked a photo; the
    /// immediate-click path is coalescing, not a shortcut, and is not what this number claims.
    func testColdStartFirstFrameIsFasterWithWarm() throws {
        let load = Self.loadAverage()
        guard load < 8 else {
            let uptime = ProcessInfo.processInfo.systemUptime
            throw XCTSkip("load \(String(format: "%.2f", load)) ≥ 8; uptime "
                          + "\(String(format: "%.0f", uptime)) s: timing not measured")
        }
        let raw = try fixture("L1030433.dng")

        var warmSamples: [Double] = []
        var coldSamples: [Double] = []
        for round in 0..<3 {
            // Alternate the order so a machine that slowly gets busier does not bias one side.
            if round.isMultiple(of: 2) {
                coldSamples.append(try measureClickToFirstFrame(raw: raw, prewarm: false))
                warmSamples.append(try measureClickToFirstFrame(raw: raw, prewarm: true))
            } else {
                warmSamples.append(try measureClickToFirstFrame(raw: raw, prewarm: true))
                coldSamples.append(try measureClickToFirstFrame(raw: raw, prewarm: false))
            }
        }
        let warm = Self.percentile(warmSamples, 0.5)
        let cold = Self.percentile(coldSamples, 0.5)
        print(String(format: "539 first frame p50: warm %.1f ms → cold %.1f ms (%.1f %% faster)"
                     + " · samples warm %@ cold %@ · load %.2f",
                     warm, cold, (cold - warm) / cold * 100,
                     warmSamples.map { String(format: "%.1f", $0) }.joined(separator: ","),
                     coldSamples.map { String(format: "%.1f", $0) }.joined(separator: ","),
                     load))

        XCTAssertGreaterThan(cold, 0)
        XCTAssertLessThanOrEqual(warm, cold * 0.7,
                                 "warm p50 \(warm) ms vs cold \(cold) ms: not 30 % faster")
    }

    private func measureClickToFirstFrame(raw: URL, prewarm: Bool) throws -> Double {
        let library = try makeLibrary(files: [raw])
        let (editor, assets) = try makeEditor(library, prewarm: false)
        let loupe = editor.rootView.loupeController
        askForV9(editor.session)
        if prewarm {
            loupe.warmsV9OnLibraryOpen = true
            loupe.prewarmV9ForAnchor()
            XCTAssertTrue(waitFor(180, { loupe.v9PrewarmFinishedAt != nil }),
                          "the warm never finished")
        }

        let start = CACurrentMediaTime()
        try enterLoupe(editor, asset: assets[0])
        XCTAssertTrue(waitFor(180, { loupe.lastFrame != nil }), "no first frame")
        let milliseconds = (CACurrentMediaTime() - start) * 1000
        // Release this round's full-rung buffer before the next one: six 60 MP ladders alive at
        // once would measure the machine's memory pressure rather than the first frame.
        if let window = editor.window {
            window.orderOut(nil)
            windows.removeAll { $0 === window }
        }
        return milliseconds
    }

    // MARK: - numbers

    /// The 1-minute load average, the same reading the brief names for timing gates.
    private static func loadAverage() -> Double {
        var info = [Double](repeating: 0, count: 3)
        let count = getloadavg(&info, 3)
        return count > 0 ? info[0] : .greatestFiniteMagnitude
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
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
