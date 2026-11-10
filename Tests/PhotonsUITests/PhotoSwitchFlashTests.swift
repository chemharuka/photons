import XCTest
import AppKit
import CoreGraphics
import QuartzCore
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 258 — 切换照片的首帧：**B 的**像素、**90 %** 的 content，而不是「A 的缓存 + 全屏 fit」。
///
/// Two defects, measured through the shipped paths:
///
///   1. **content**: a `CAMetalLayer` keeps its last drawable, so a switch left A's frame on screen
///      until B's first frame (or 235's thumbnail) arrived. The fix covers the layer at the instant
///      the identity moves and drops the old frame's ownership; `presentedPhoto` is nil from then on.
///   2. **geometry**: the 235 stand-in was a full-canvas `NSImageView` (100 %), then the real frame
///      landed at 213's 90 %. It now occupies the same `content` rect the real 适应 frame does.
///
/// The trace is sampled on every runloop tick from the switch until B's real frame, and the printed
/// table is the acceptance's per-frame evidence (identity, texture source, plan geometry).
@MainActor
final class PhotoSwitchFlashTests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-switch-flash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    // MARK: - the trace

    private enum TextureSource: String {
        case previousPhoto = "A-frame"
        case placeholder = "placeholder"
        case newFrame = "B-frame"
        case matte = "matte"
    }

    private struct Row {
        let milliseconds: Double
        let presentedPhoto: String?
        let placeholderPhoto: String?
        let source: TextureSource
        let canvas: ImageSize
        let content: ImageSize?
        let frameInCanvas: Bool
        let frameOrigin: SIMD2<Float>
        let expandedCanvas: ImageSize?
        let neverUpscalesContent: Bool

        var occupancy: Double? {
            guard let content else { return nil }
            return max(Double(content.width) / Double(canvas.width),
                       Double(content.height) / Double(canvas.height))
        }

        /// The acceptance's invariant for one frame: never the previous photo, and any content that
        /// is not the canvas is the 0.90 fit.
        func isAcceptable(oldTexture: ObjectIdentifier?, oldPhoto: String) -> Bool {
            guard source != .previousPhoto, presentedPhoto != oldPhoto else { return false }
            guard let occupancy else { return true }   // the matte is allowed while a cold cache fills
            return abs(occupancy - LoupeFraming.fitMargin) <= 0.005
        }

        var line: String {
            String(format: "%7.1f ms · presented %@ · placeholder %@ · %@ · canvas %dx%d"
                   + " · content %@ · inCanvas %@ · origin %.2f,%.2f · expanded %@"
                   + " · neverUpscales %@ · occupancy %@",
                   milliseconds,
                   presentedPhoto ?? "nil",
                   placeholderPhoto ?? "nil",
                   source.rawValue,
                   canvas.width, canvas.height,
                   content.map { "\($0.width)x\($0.height)" } ?? "nil",
                   frameInCanvas ? "true" : "false",
                   frameOrigin.x, frameOrigin.y,
                   expandedCanvas.map { "\($0.width)x\($0.height)" } ?? "nil",
                   neverUpscalesContent ? "true" : "false",
                   occupancy.map { String(format: "%.4f", $0) } ?? "nil")
        }
    }

    /// One observation of what the eye could be seeing right now.
    private func sample(_ loupe: LoupeController, oldTexture: ObjectIdentifier?,
                        oldPhoto: String, startedAt: CFTimeInterval,
                        placeholderPhoto: String?) -> Row {
        let canvas = loupe.viewportPixels
        let ms = (CACurrentMediaTime() - startedAt) * 1000
        if let frame = loupe.lastFrame, loupe.currentCanvasTextureIDForTesting != nil {
            let id = loupe.currentCanvasTextureIDForTesting
            return Row(milliseconds: ms,
                       presentedPhoto: loupe.currentPresentedPhotoForTesting,
                       placeholderPhoto: loupe.currentPlaceholderPhotoForTesting,
                       source: id == oldTexture ? .previousPhoto : .newFrame,
                       canvas: frame.canvas, content: frame.content,
                       frameInCanvas: frame.frameInCanvas == frame.canvas,
                       frameOrigin: frame.frameOrigin,
                       expandedCanvas: frame.expandedCanvas,
                       neverUpscalesContent: frame.neverUpscalesContent)
        }
        if loupe.firstFramePlaceholderVisible,
           loupe.currentPlaceholderPhotoForTesting == placeholderPhoto {
            let scale = max(1, loupe.backingScale)
            let rect = loupe.placeholderRectForTesting
            let content = ImageSize(width: max(1, Int((rect.width * scale).rounded())),
                                    height: max(1, Int((rect.height * scale).rounded())))
            return Row(milliseconds: ms,
                       presentedPhoto: loupe.currentPresentedPhotoForTesting,
                       placeholderPhoto: loupe.currentPlaceholderPhotoForTesting,
                       source: .placeholder,
                       canvas: canvas, content: content,
                       frameInCanvas: content == canvas,
                       frameOrigin: .zero,
                       expandedCanvas: nil,
                       neverUpscalesContent: true)
        }
        return Row(milliseconds: ms,
                   presentedPhoto: loupe.currentPresentedPhotoForTesting,
                   placeholderPhoto: loupe.currentPlaceholderPhotoForTesting,
                   source: .matte,
                   canvas: canvas, content: nil,
                   frameInCanvas: true, frameOrigin: .zero,
                   expandedCanvas: nil, neverUpscalesContent: true)
    }

    // MARK: - the switch

    func testSwitchShowsTheNewPhotoAtNinetyPercentFromTheFirstFrame() throws {
        let first = try fixture("L1030433.dng")
        let second = try fixture("L1030402.dng")
        let (editor, assets) = try makeEditor(files: [first, second], seeded: [true, true])
        let loupe = editor.rootView.loupeController
        let session = editor.session

        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(90) { loupe.lastFrame != nil }, "A never presented")
        let oldID = try XCTUnwrap(loupe.currentCanvasTextureIDForTesting, "A has no texture")
        let oldPhoto = try XCTUnwrap(loupe.currentPresentedPhotoForTesting, "A has no identity")

        // The acceptance's *warm* case: the grid has already decoded this photo's stand-in. The
        // provider's small cache is the same one the grid feeds, so the measured switch is the
        // dictionary hit the user gets after looking at the grid — not the first disk decode.
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        _ = ThumbnailProvider.shared(for: cache)
            .cachedCanvasPlaceholder(for: assets[1],
                                     document: ThumbnailProvider.document(from: assets[1]))

        let started = CACurrentMediaTime()
        session.activate(assets[1].id)
        editor.rootView.showModule(for: .loupe)
        let bPhoto = try XCTUnwrap(loupe.currentRenderedPhotoForTesting)
        XCTAssertNotEqual(bPhoto, oldPhoto, "the switch did not move the identity")

        // The hot-cache promise: the stand-in is up in this same turn, ≤ 5 ms.
        XCTAssertTrue(loupe.firstFramePlaceholderVisible,
                      "a warm switch must show B's thumbnail immediately")
        XCTAssertLessThanOrEqual(loupe.firstFramePlaceholderMilliseconds, 5,
                                 "the stand-in took \(loupe.firstFramePlaceholderMilliseconds) ms")
        XCTAssertEqual(loupe.currentPlaceholderPhotoForTesting, bPhoto,
                       "the stand-in belongs to another photo")
        XCTAssertNil(loupe.currentPresentedPhotoForTesting,
                     "presentedPhoto still names the previous photo")
        XCTAssertNil(loupe.lastFrame,
                     "the previous photo's frame is still the canvas' last frame")
        XCTAssertTrue(loupe.isCanvasCoveredForTesting,
                      "nothing covers the layer's previous drawable")

        var rows: [Row] = []
        func record() {
            rows.append(sample(loupe, oldTexture: oldID, oldPhoto: oldPhoto,
                               startedAt: started,
                               placeholderPhoto: bPhoto))
        }
        record()
        for _ in 0..<6 { pump(0.002); record() }

        XCTAssertTrue(waitFor(90) { loupe.currentPresentedPhotoForTesting == bPhoto },
                      "B never presented (last error: \(loupe.lastPresentError ?? "—"))")
        record()
        // At least six frames, and the last one is B's real frame.
        XCTAssertGreaterThanOrEqual(rows.count, 6)
        XCTAssertEqual(rows.last?.source, .newFrame)

        for (index, row) in rows.enumerated() {
            print("258 switch row \(index): \(row.line)")
            XCTAssertTrue(row.isAcceptable(oldTexture: oldID, oldPhoto: oldPhoto),
                          "row \(index) violates the switch invariant: \(row.line)")
            if let occupancy = row.occupancy {
                XCTAssertEqual(occupancy, LoupeFraming.fitMargin, accuracy: 0.005,
                               "row \(index) is not the 0.90 fit: \(row.line)")
            }
        }

        let final = try XCTUnwrap(loupe.lastFrame)
        let placeholderContent = rows.first(where: { $0.source == .placeholder })?.content
        let placeholder = try XCTUnwrap(placeholderContent, "no placeholder row was sampled")
        print(String(format: "258 final: placeholder %dx%d · real content %dx%d · canvas %dx%d "
                     + "· occupancy %.4f",
                     placeholder.width, placeholder.height,
                     final.content.width, final.content.height,
                     final.canvas.width, final.canvas.height,
                     max(Double(final.photoRect.width) / Double(final.canvas.width),
                         Double(final.photoRect.height) / Double(final.canvas.height))))
        XCTAssertLessThanOrEqual(abs(placeholder.width - final.content.width), 2,
                                 "the stand-in and the real frame disagree about width")
        XCTAssertLessThanOrEqual(abs(placeholder.height - final.content.height), 2,
                                 "the stand-in and the real frame disagree about height")
        XCTAssertTrue(final.neverUpscalesContent, "the fit frame did not keep its content rect")
        XCTAssertNil(final.expandedCanvas)
        XCTAssertEqual(final.frameOrigin.x, 0, accuracy: 0.5)
        XCTAssertEqual(final.frameOrigin.y, 0, accuracy: 0.5)
        XCTAssertFalse(loupe.isCanvasCoveredForTesting, "the cover outlived the real frame")
        XCTAssertFalse(loupe.firstFramePlaceholderVisible, "the stand-in outlived the real frame")
    }

    /// 298 — **the stand-in's rectangle is the presented frame's rectangle on every tick it is up.**
    ///
    /// The reported defect was no jump at all: while the viewer waited for the new frame, the stand-in
    /// was re-placed through a `FrameTransform` that still carried the decode rung, so on the 0.5
    /// preview rung it covered only the top-left quarter and the matte showed through the other
    /// three. This drives the shipped long-tail state — the viewed photo's resident buffer is its
    /// 0.5 preview rung, exactly what a return to a frame the ladder has not promoted yet sees —
    /// and compares the stand-in against `lastPresented.pictureQuad`, the real frame's own quad, on
    /// every sampled tick. The 2 pt tolerance is geometric, not a relaxation to an aspect ratio.
    func testTheStandInRectEqualsThePresentedQuadOnTheSwitchTick() throws {
        let first = try fixture("L1030433.dng")
        let second = try fixture("L1030402.dng")
        let (editor, assets) = try makeEditor(files: [first, second], seeded: [true, true])
        let loupe = editor.rootView.loupeController
        let session = editor.session

        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(90) { loupe.lastFrame != nil }, "A never presented")
        let presented = try XCTUnwrap(loupe.lastPresented,
                                      "A presented but recorded no quad")

        // Deterministically put A back on the 0.5 rung: a 60 MP full development takes hundreds of
        // milliseconds, so leaving and returning before it lands is the state a real re-entry
        // sees. The seam is the controller's own (it installs the buffer and its identity exactly
        // the way `makeFrame` leaves them), so the gate cannot pass just because the full rung
        // happened to win the race first.
        let stored = try pixelSize(of: first)
        let rung = ImageSize(width: max(1, stored.width / 2), height: max(1, stored.height / 2))
        let preview = LinearImage(width: rung.width, height: rung.height,
                                  rgba: [Float16](repeating: 0,
                                                  count: rung.width * rung.height * 4),
                                  colorSpace: "extendedLinearSRGB", decoderVersion: "test")
        loupe.installDecodedRungForTesting(preview, scale: 0.5)

        let scale = max(1, loupe.backingScale)
        let expected = CGRect(x: Double(presented.pictureQuad.x) / scale,
                              y: Double(presented.pictureQuad.y) / scale,
                              width: Double(presented.pictureQuad.width) / scale,
                              height: Double(presented.pictureQuad.height) / scale)

        // Leave and come straight back. B never gets a frame, so `decoded` is still A's 0.5 rung
        // when A is re-armed; that is what makes the stand-in's own rect the measurement.
        session.activate(assets[1].id)
        editor.rootView.showModule(for: .loupe)
        session.activate(assets[0].id)
        editor.rootView.showModule(for: .loupe)

        var sampled = 0
        for _ in 0..<8 {
            guard loupe.firstFramePlaceholderVisible && loupe.isCanvasCoveredForTesting else { break }
            let rect = loupe.placeholderRectForTesting
            print(String(format: "298 stand-in tick %d: rect %.1f,%.1f %.1fx%.1f"
                         + " · presented quad %.1f,%.1f %.1fx%.1f",
                         sampled, rect.minX, rect.minY, rect.width, rect.height,
                         expected.minX, expected.minY, expected.width, expected.height))
            XCTAssertLessThanOrEqual(abs(rect.minX - expected.minX), 2,
                                     "tick \(sampled): stand-in left edge is not the frame's")
            XCTAssertLessThanOrEqual(abs(rect.minY - expected.minY), 2,
                                     "tick \(sampled): stand-in top edge is not the frame's")
            XCTAssertLessThanOrEqual(abs(rect.width - expected.width), 2,
                                     "tick \(sampled): stand-in width is not the frame's")
            XCTAssertLessThanOrEqual(abs(rect.height - expected.height), 2,
                                     "tick \(sampled): stand-in height is not the frame's")
            sampled += 1
            pump(0.002)
        }
        XCTAssertGreaterThanOrEqual(sampled, 1,
                                    "no tick showed a covered stand-in — the fixture missed the 0.5 rung")
    }

    /// 反向门 ① — without the clear/cover step the very first sample is still A's texture.
    func testReverseGateWithoutClearingTheOldFrameShowsThePreviousPhoto() throws {
        let first = try fixture("L1030433.dng")
        let second = try fixture("L1030402.dng")
        let (editor, assets) = try makeEditor(files: [first, second], seeded: [true, true])
        let loupe = editor.rootView.loupeController

        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(90) { loupe.lastFrame != nil })
        let oldID = try XCTUnwrap(loupe.currentCanvasTextureIDForTesting)
        let oldPhoto = try XCTUnwrap(loupe.currentPresentedPhotoForTesting)

        loupe.clearsPresentedFrameOnPhotoSwitch = false
        loupe.armsColdStartPlaceholder = false
        let started = CACurrentMediaTime()
        editor.session.activate(assets[1].id)
        editor.rootView.showModule(for: .loupe)

        let row = sample(loupe, oldTexture: oldID, oldPhoto: oldPhoto, startedAt: started,
                         placeholderPhoto: loupe.currentRenderedPhotoForTesting)
        print("258 reverse ①: \(row.line)")
        XCTAssertEqual(loupe.currentPresentedPhotoForTesting, oldPhoto,
                       "the reverse gate did not leave the previous identity on the canvas")
        XCTAssertNotNil(loupe.lastFrame, "the reverse gate cleared the old frame")
        XCTAssertEqual(row.source, .previousPhoto)
        XCTAssertFalse(row.isAcceptable(oldTexture: oldID, oldPhoto: oldPhoto),
                       "the invariant passed on the pre-fix path — it is not a gate")
    }

    /// 反向门 ② — with `neverUpscalesContent` off for 适应 the same frame is the 100 % draw.
    func testReverseGateWithoutNeverUpscalesDrawsAtFullCanvas() throws {
        let raw = try fixture("L1030433.dng")
        let controller = LoupeController(session: CatalogSession())
        let viewport = ImageSize(width: 1200, height: 800)

        let kept = try controller.makeFrame(url: raw, viewport: viewport, decodeScale: 0.5,
                                            edit: .neutral, state: .fit)
        let keptOccupancy = occupancy(of: kept)
        XCTAssertEqual(keptOccupancy, LoupeFraming.fitMargin, accuracy: 0.005)
        XCTAssertTrue(kept.neverUpscalesContent)
        XCTAssertNotEqual(kept.content, kept.canvas)

        controller.neverUpscalesFitContent = false
        let full = try controller.makeFrame(url: raw, viewport: viewport, decodeScale: 0.5,
                                            edit: .neutral, state: .fit)
        let fullOccupancy = occupancy(of: full)
        print(String(format: "258 reverse ②: kept %.4f (content %dx%d) · full %.4f (content %dx%d)"
                     + " · canvas %dx%d",
                     keptOccupancy, kept.content.width, kept.content.height,
                     fullOccupancy, full.content.width, full.content.height,
                     full.canvas.width, full.canvas.height))
        XCTAssertEqual(fullOccupancy, 1.0, accuracy: 0.005,
                       "removing neverUpscalesContent must print 1.0000")
        XCTAssertFalse(full.neverUpscalesContent)
    }

    /// The cold-cache control: no thumbnail for B. It may wait on the matte, but the wait must never
    /// show A's pixels.
    func testColdCacheSwitchWaitsOnTheMatteAndNeverShowsTheOldPhoto() throws {
        let first = try fixture("L1030433.dng")
        let second = try fixture("L1030402.dng")
        let (editor, assets) = try makeEditor(files: [first, second], seeded: [true, false])
        let loupe = editor.rootView.loupeController

        editor.session.selectOnly(assets[0].id)
        pump(0.05)
        editor.session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(90) { loupe.lastFrame != nil })
        let oldID = try XCTUnwrap(loupe.currentCanvasTextureIDForTesting)
        let oldPhoto = try XCTUnwrap(loupe.currentPresentedPhotoForTesting)

        let started = CACurrentMediaTime()
        editor.session.activate(assets[1].id)
        editor.rootView.showModule(for: .loupe)
        let bPhoto = try XCTUnwrap(loupe.currentRenderedPhotoForTesting)
        var rows: [Row] = []
        func record() {
            rows.append(sample(loupe, oldTexture: oldID, oldPhoto: oldPhoto,
                               startedAt: started, placeholderPhoto: bPhoto))
        }
        record()
        XCTAssertTrue(loupe.isCanvasCoveredForTesting,
                      "a cold switch left the layer's old drawable uncovered")
        XCTAssertNil(loupe.lastFrame)
        XCTAssertNil(loupe.currentPresentedPhotoForTesting)

        let placeholderOrFrame = waitFor(90) {
            loupe.firstFramePlaceholderVisible
                || loupe.currentPresentedPhotoForTesting == bPhoto
        }
        XCTAssertTrue(placeholderOrFrame,
                      "B neither stood in nor presented (last error: \(loupe.lastPresentError ?? "—"))")
        for _ in 0..<6 {
            record()
            if loupe.currentPresentedPhotoForTesting == bPhoto { break }
            pump(0.005)
        }
        for (index, row) in rows.enumerated() {
            print("258 cold row \(index): \(row.line)")
            XCTAssertTrue(row.isAcceptable(oldTexture: oldID, oldPhoto: oldPhoto),
                          "cold row \(index) violates the switch invariant: \(row.line)")
        }
        XCTAssertTrue(waitFor(90) { loupe.currentPresentedPhotoForTesting == bPhoto },
                      "B never presented from a cold cache")
        XCTAssertFalse(loupe.isCanvasCoveredForTesting)
    }

    // MARK: - fixtures

    private func occupancy(of frame: LoupeController.FrameResult) -> Double {
        max(Double(frame.photoRect.width) / Double(frame.canvas.width),
            Double(frame.photoRect.height) / Double(frame.canvas.height))
    }

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

    private func makeEditor(files: [URL], seeded: [Bool]) throws
        -> (EditorWindowController, [Asset]) {
        let library = try makeLibrary(files: files)
        _ = NSApplication.shared
        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        windows.append(try XCTUnwrap(editor.window))
        try editor.openLibrary(at: library.package)
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        for (index, asset) in editor.session.assets.enumerated()
        where index < seeded.count && seeded[index] {
            try seedPreview(asset, cache: cache)
        }
        TestWindows.show(editor.window)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.rootView.needsLayout = true
        editor.rootView.layoutSubtreeIfNeeded()
        pump(0.05)
        return (editor, editor.session.assets)
    }

    private func makeLibrary(files: [URL]) throws -> (package: URL, assets: [Asset]) {
        let package = workDir.appendingPathComponent("Switch.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let source = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: source, mode: .reference)

        var ids: [String] = []
        for (index, file) in files.enumerated() {
            let name = "switch\(index).dng"
            let destination = source.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: file)
            let size = try pixelSize(of: file)
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
            }
        }
        let assets = try ids.map { try XCTUnwrap(try catalog.asset(id: $0)) }
        return (package, assets)
    }

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
