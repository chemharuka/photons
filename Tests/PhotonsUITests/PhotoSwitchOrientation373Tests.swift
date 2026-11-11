import XCTest
import AppKit
import CoreGraphics
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 373 — 横拍 → 竖拍换图时，先出现「被放大成竖幅的横拍照片」再切换.
///
/// The claim under test is a **pairing**, not a picture: at no instant may the texture the layer
/// samples belong to the previous photo while the rectangle it is drawn into is the new photo's. The
/// probe reads `presentTrace` (texture identity + geometry from the same present) and, while no
/// present has happened yet, the stand-in (its photo, its pixel size and the rect it occupies).
@MainActor
final class PhotoSwitchOrientation373Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-switch-373-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
    }

    private enum Switch {
        case landscapeToPortrait
        case portraitToLandscape

        var name: String {
            self == .landscapeToPortrait ? "横→竖" : "竖→横"
        }
    }

    private struct Row {
        let milliseconds: Double
        let presentedPhoto: String?
        let placeholderPhoto: String?
        let placeholderVisible: Bool
        let placeholderAspect: Double?
        let placeholderPixelsAspect: Double?
        let presents: Int
        let lastTextureIsOld: Bool?
        let lastPresentedAspect: Double?
        let lastFrameAspect: Double?
        let documentAspect: Double?
        let covered: Bool
        let sampled: String
        var line: String {
            String(format: "%7.2f ms · presented %@ · ph %@ vis %@ rect %@ px %@ · doc %@"
                   + " · presents %d · tex %@ %@ · lastAspect %@ · frameAspect %@ · cover %@",
                   milliseconds,
                   presentedPhoto ?? "nil",
                   placeholderPhoto ?? "nil",
                   placeholderVisible ? "yes" : "no",
                   placeholderAspect.map { String(format: "%.3f", $0) } ?? "—",
                   placeholderPixelsAspect.map { String(format: "%.3f", $0) } ?? "—",
                   documentAspect.map { String(format: "%.3f", $0) } ?? "—",
                   presents,
                   sampled,
                   lastTextureIsOld.map { $0 ? "OLD" : "new" } ?? "—",
                   lastPresentedAspect.map { String(format: "%.3f", $0) } ?? "—",
                   lastFrameAspect.map { String(format: "%.3f", $0) } ?? "—",
                   covered ? "yes" : "no")
        }
    }

    private func sample(_ loupe: LoupeController, oldTexture: ObjectIdentifier,
                        presentsAtSwitch: Int, placeholderPhoto: String?,
                        startedAt: CFTimeInterval) -> Row {
        let ms = (CACurrentMediaTime() - startedAt) * 1000
        let since = Array(loupe.presentTrace.dropFirst(presentsAtSwitch))
        let last = since.last
        let doc = loupe.framing()
        let placeholder = loupe.firstFramePlaceholderVisible
            && loupe.currentPlaceholderPhotoForTesting == placeholderPhoto
        let rect = loupe.placeholderRectForTesting
        let sampling: String
        if let last {
            sampling = last.texture == oldTexture ? "oldPresent" : "newPresent"
        } else if placeholder {
            sampling = "placeholder"
        } else if loupe.isCanvasCoveredForTesting {
            sampling = "matte"
        } else {
            sampling = "nothing"
        }
        return Row(milliseconds: ms,
                   presentedPhoto: loupe.currentPresentedPhotoForTesting,
                   placeholderPhoto: loupe.currentPlaceholderPhotoForTesting,
                   placeholderVisible: placeholder,
                   placeholderAspect: rect.height > 0 ? Double(rect.width / rect.height) : nil,
                   placeholderPixelsAspect: loupe.firstFramePlaceholderPixels.map {
                       $0.height > 0 ? Double($0.width) / Double($0.height) : 0
                   },
                   presents: since.count,
                   lastTextureIsOld: last.map { $0.texture == oldTexture },
                   lastPresentedAspect: last.map { aspect($0.pictureQuad) },
                   lastFrameAspect: loupe.lastFrame.map {
                       $0.content.height > 0 ? Double($0.content.width) / Double($0.content.height) : 0
                   },
                   documentAspect: doc.map {
                       $0.sourceWidth > 0 ? Double($0.sourceWidth) / Double($0.sourceHeight) : 0
                   },
                   covered: loupe.isCanvasCoveredForTesting,
                   sampled: sampling)
    }

    private func aspect(_ rect: ImageRect) -> Double {
        rect.height > 0 ? Double(rect.width) / Double(rect.height) : 0
    }

    private func run(_ mode: Switch, rounds: Int) throws {
        let landscape = try fixture("L1030433.dng")
        let portrait = try fixture("L1030437.dng")
        let files = mode == .landscapeToPortrait ? [landscape, portrait] : [portrait, landscape]
        let (editor, assets) = try makeEditor(files: files)
        let loupe = editor.rootView.loupeController
        let session = editor.session
        let expected = try files.map { try uprightSize(of: $0) }
        let oldAspect = Double(expected[0].width) / Double(expected[0].height)
        let newAspect = Double(expected[1].width) / Double(expected[1].height)
        XCTAssertNotEqual(backIsPortrait(oldAspect), backIsPortrait(newAspect),
                          "\(mode.name) the fixtures have the same orientation")

        session.selectOnly(assets[0].id)
        pump(0.05)
        session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(90) { loupe.lastFrame != nil }, "\(mode.name) A never presented")
        XCTAssertTrue(waitFor(90) { loupe.currentPresentedPhotoForTesting != nil },
                      "\(mode.name) A never presented an identity")

        for round in 0..<rounds {
            if round > 0 {
                session.activate(assets[0].id)
                editor.rootView.showModule(for: .loupe)
                XCTAssertTrue(waitFor(90) {
                    loupe.currentPresentedPhotoForTesting != nil && loupe.lastFrame != nil
                }, "\(mode.name) A never came back in round \(round)")
                pump(0.05)
            }
            let oldTexture = try XCTUnwrap(loupe.currentCanvasTextureIDForTesting,
                                           "\(mode.name) A has no texture")
            let oldID = try XCTUnwrap(loupe.currentPresentedPhotoForTesting,
                                      "\(mode.name) A has no identity")
            let presentsAtSwitch = loupe.presentTrace.count
            let started = CACurrentMediaTime()
            session.activate(assets[1].id)
            editor.rootView.showModule(for: .loupe)
            // AppKit can lay the canvas out in the same turn as the selection, before the dispatched
            // observation re-arms the stand-in. Drive that ordering here too: the probe is about the
            // frames the eye sees, not about which callback won the race.
            loupe.view.needsLayout = true
            loupe.view.layoutSubtreeIfNeeded()
            let newID = try XCTUnwrap(loupe.currentRenderedPhotoForTesting,
                                      "\(mode.name) the switch did not move the identity")
            XCTAssertNotEqual(newID, oldID, "\(mode.name) identity did not move")

            var rows: [Row] = []
            func record() {
                guard rows.count < 2000 else { return }
                rows.append(sample(loupe, oldTexture: oldTexture,
                                   presentsAtSwitch: presentsAtSwitch,
                                   placeholderPhoto: newID, startedAt: started))
            }
            record()
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline, loupe.currentPresentedPhotoForTesting != newID {
                pump(0.002)
                record()
            }
            XCTAssertEqual(loupe.currentPresentedPhotoForTesting, newID,
                           "\(mode.name) B never presented: \(loupe.lastPresentError ?? "—")")
            record()
            for _ in 0..<8 {
                pump(0.002)
                record()
            }

            print("373 \(mode.name) round \(round): \(rows.count) samples · oldAspect "
                  + String(format: "%.3f", oldAspect) + " · newAspect "
                  + String(format: "%.3f", newAspect))
            for (index, row) in rows.enumerated() {
                let interesting = index < 6 || index >= rows.count - 4
                    || row.sampled == "oldPresent"
                    || (row.placeholderVisible && row.placeholderAspect.map {
                        abs($0 - newAspect) > 0.02
                    } == true)
                if interesting {
                    print("373 \(mode.name) r\(round) row \(index): \(row.line)")
                }
                // ① the texture and the rectangle always describe the same photo.
                if let isOld = row.lastTextureIsOld, let presented = row.lastPresentedAspect {
                    let want = isOld ? oldAspect : newAspect
                    XCTAssertEqual(presented, want, accuracy: 0.02,
                                   "\(mode.name) r\(round) row \(index): texture/geometry disagree: \(row.line)")
                }
                if row.placeholderVisible, let rectAspect = row.placeholderAspect {
                    XCTAssertEqual(rectAspect, newAspect, accuracy: 0.02,
                                   "\(mode.name) r\(round) row \(index): stand-in rect is not B's: \(row.line)")
                }
                if row.placeholderVisible, let pixels = row.placeholderPixelsAspect {
                    XCTAssertEqual(pixels, newAspect, accuracy: 0.02,
                                   "\(mode.name) r\(round) row \(index): stand-in bitmap is not B's: \(row.line)")
                }
                // ③ never a bare backdrop-coloured canvas.
                XCTAssertFalse(row.sampled == "nothing",
                               "\(mode.name) r\(round) row \(index): nothing covers the canvas: \(row.line)")
                // 先撤旧帧: after the switch no present may sample A's texture at all.
                XCTAssertFalse(row.sampled == "oldPresent",
                               "\(mode.name) r\(round) row \(index): A's texture is on the new canvas: \(row.line)")
            }
            // ② one handover: stand-in/matte → B's frame, no second cut.
            var handovers = 0
            var previous = rows.first?.sampled
            for row in rows.dropFirst() where row.sampled != previous {
                handovers += 1
                previous = row.sampled
            }
            print("373 \(mode.name) round \(round): handovers \(handovers) · first present "
                  + "\(rows.first(where: { $0.presents > 0 })?.milliseconds ?? -1) ms · "
                  + "settled \(rows.first(where: { $0.presentedPhoto == newID })?.milliseconds ?? -1) ms")
            XCTAssertLessThanOrEqual(handovers, 2,
                                     "\(mode.name) r\(round): the switch cut more than twice")
        }
    }

    private func backIsPortrait(_ aspect: Double) -> Bool { aspect < 1 }

    func testLandscapeToPortraitShowsNoOldTextureUnderTheNewAspect() throws {
        try run(.landscapeToPortrait, rounds: 3)
    }

    func testPortraitToLandscapeShowsNoOldTextureUnderTheNewAspect() throws {
        try run(.portraitToLandscape, rounds: 3)
    }

    /// The actual report: a **layout pass between the anchor change and the observation that re-arms
    /// the stand-in** re-placed the *previous* photo's landscape thumbnail through the *new* photo's
    /// upright aspect — the landscape blown up to a portrait rectangle. The observation is dispatched,
    /// not synchronous, so the next layout of the canvas really can run first. This drives exactly that
    /// ordering: A's stand-in is up (renders off), the anchor moves to B, and the canvas lays out before
    /// the run loop delivers the observation.
    func testLayoutBeforeTheSwitchObservationNeverPlacesAThroughB() throws {
        let landscape = try fixture("L1030433.dng")
        let portrait = try fixture("L1030437.dng")
        let (editor, assets) = try makeEditor(files: [landscape, portrait])
        let loupe = editor.rootView.loupeController
        let session = editor.session
        let sizes = try [landscape, portrait].map { try uprightSize(of: $0) }
        let oldAspect = Double(sizes[0].width) / Double(sizes[0].height)
        let newAspect = Double(sizes[1].width) / Double(sizes[1].height)

        // No renders: the stand-in is the only thing on the canvas, which is the state the report
        // is about (the user switched before the first photo's frame landed).
        loupe.autoRenderEnabled = false
        session.selectOnly(assets[0].id)
        pump(0.05)
        session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(5) { loupe.firstFramePlaceholderVisible },
                      "A's stand-in never installed")
        XCTAssertEqual(loupe.currentPlaceholderPhotoForTesting,
                       loupe.currentRenderedPhotoForTesting,
                       "the stand-in is not A's")
        let aPhoto = try XCTUnwrap(loupe.currentPlaceholderPhotoForTesting)
        let aRect = loupe.placeholderRectForTesting
        XCTAssertEqual(Double(aRect.width / aRect.height), oldAspect, accuracy: 0.02,
                       "A's stand-in was not the landscape rectangle")

        // The switch. The observation is queued; the canvas is laid out now, before it runs.
        session.activate(assets[1].id)
        loupe.view.needsLayout = true
        loupe.view.layoutSubtreeIfNeeded()
        let bPhoto = try XCTUnwrap(loupe.backdropPhotoKeyForTesting)
        XCTAssertNotEqual(bPhoto, aPhoto, "the switch did not move the identity")

        let rect = loupe.placeholderRectForTesting
        let pixels = try XCTUnwrap(loupe.firstFramePlaceholderPixels)
        print(String(format: "373 layout window · placeholder %@ · rect h/w %.4f · pixels %dx%d"
                     + " (h/w %.4f) · A h/w %.4f · A upright h/w %.4f",
                     loupe.currentPlaceholderPhotoForTesting ?? "nil",
                     rect.height / max(rect.width, 1e-9),
                     pixels.width, pixels.height,
                     Double(pixels.height) / Double(pixels.width),
                     1 / oldAspect, 1 / newAspect))
        // ① the bitmap on screen and the rectangle it fills are the same photo.
        if loupe.firstFramePlaceholderVisible {
            let pixelAspect = Double(pixels.width) / Double(pixels.height)
            let rectAspect = Double(rect.width / rect.height)
            XCTAssertEqual(pixelAspect, rectAspect, accuracy: 0.02,
                           "the stand-in bitmap and its rectangle are different photos")
            XCTAssertEqual(loupe.currentPlaceholderPhotoForTesting, bPhoto,
                           "the stand-in still belongs to the previous photo")
        }
    }

    /// 验收 ⑥ — the reverse gate: with `reclaimsStandInOnPhotoChange` off, the same layout window
    /// re-places A's landscape bitmap through B's portrait aspect, and the invariant goes red.
    func testReverseGateLayoutReplacesAPlaceholderWithBGeometry() throws {
        let landscape = try fixture("L1030433.dng")
        let portrait = try fixture("L1030437.dng")
        let (editor, assets) = try makeEditor(files: [landscape, portrait])
        let loupe = editor.rootView.loupeController
        let session = editor.session

        loupe.autoRenderEnabled = false
        let gate = LoupeController.reclaimsStandInOnPhotoChange
        LoupeController.reclaimsStandInOnPhotoChange = false
        defer { LoupeController.reclaimsStandInOnPhotoChange = gate }

        session.selectOnly(assets[0].id)
        pump(0.05)
        session.mode = .loupe
        editor.rootView.showModule(for: .loupe)
        XCTAssertTrue(waitFor(5) { loupe.firstFramePlaceholderVisible })

        session.activate(assets[1].id)
        loupe.view.needsLayout = true
        loupe.view.layoutSubtreeIfNeeded()

        let rect = loupe.placeholderRectForTesting
        let pixels = try XCTUnwrap(loupe.firstFramePlaceholderPixels)
        let pixelAspect = Double(pixels.width) / Double(pixels.height)
        let rectAspect = Double(rect.width / rect.height)
        print(String(format: "373 reverse · pixels %dx%d (w/h %.4f) · rect w/h %.4f",
                     pixels.width, pixels.height, pixelAspect, rectAspect))
        XCTAssertGreaterThan(abs(pixelAspect - rectAspect), 0.02,
                             "the reverse gate kept the stand-in honest — it is not a gate")
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

    private func makeEditor(files: [URL]) throws -> (EditorWindowController, [Asset]) {
        let library = try makeLibrary(files: files)
        _ = NSApplication.shared
        let editor = EditorWindowController(size: NSSize(width: 1200, height: 800))
        windows.append(try XCTUnwrap(editor.window))
        try editor.openLibrary(at: library.package)
        let cache = try XCTUnwrap(editor.session.thumbnailCache)
        for asset in editor.session.assets {
            let stored = ImageSize(width: asset.width ?? 3, height: asset.height ?? 2)
            let upright = editor.session.sourceOrientation(of: asset.id)
                .map { $0.uprightSize(width: stored.width, height: stored.height) }
            let size = upright.map { ImageSize(width: $0.0, height: $0.1) } ?? stored
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
        let package = workDir.appendingPathComponent("Switch373.\(LibraryLayout.packageExtension)")
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
            let orientation = try orientation(of: file)
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

    private func uprightSize(of url: URL) throws -> ImageSize {
        let stored = try pixelSize(of: url)
        let value = try orientation(of: url)
        let exchanges = (5...8).contains(value)
        return exchanges ? ImageSize(width: stored.height, height: stored.width) : stored
    }
}
