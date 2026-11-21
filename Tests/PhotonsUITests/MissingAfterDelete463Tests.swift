import XCTest
import AppKit
import ImageIO
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 463 — 「外部删掉照片文件后没有提示，只剩 1920 px 缩略图」.
///
/// Everything here uses a **real library package and real files**: an import in `.reference` mode, then
/// `FileManager.removeItem` stands in for the Finder. The samples are generated JPEGs in the test's
/// temporary directory — the user's `PHOTONS_TEST_RAW` is never touched (it may be passed to the suite
/// command, and the loupe suites use it for decode fixtures; this file does not need it).
///
/// The four claims match the ticket:
///  1. switching to a photo whose file was deleted **while the app is running** flags it within 5 s,
///     shows the banner, and does not leave the stale 1920 px stand-in on the canvas;
///  2. putting the file back clears the flag and takes the banner down, with no rescan;
///  3. the decode/development failure path flags it even when the stat is made to lie;
///  4. a stack's top is marked, and dissolving the stack does not unmark the missing photo.
@MainActor
final class MissingAfterDelete463Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-missing463-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        _ = NSApplication.shared
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixtures

    private struct Library {
        var package: URL
        var catalog: Catalog
        var session: CatalogSession
        var assets: [Asset]
    }

    @discardableResult
    private func makeJPEG(at url: URL, seed: Int) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let w = 20, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i * 4] = UInt8((i &* 11 &+ seed &* 41) & 0xFF)
            pixels[i * 4 + 1] = UInt8((i &* 5 &+ seed &* 23) & 0xFF)
            pixels[i * 4 + 2] = UInt8((i &+ seed &* 7) & 0xFF)
            pixels[i * 4 + 3] = 255
        }
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("cannot write JPEG")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("cannot finalize JPEG") }
        return url
    }

    private func makeLibrary(count: Int = 2) throws -> Library {
        let package = workDir.appendingPathComponent("UI.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        var urls: [URL] = []
        for i in 0..<count {
            urls.append(try makeJPEG(at: src.appendingPathComponent(String(format: "IMG_%02d.jpg", i)),
                                     seed: 100 + i * 37))
        }
        _ = try ImportService(catalog: catalog).run(sources: urls, options: ImportOptions(mode: .reference))
        let rows = try catalog.assets(AssetFilter())
        // The import keeps display order (`capture_time DESC, filename`); names are unique.
        let assets = rows.sorted { $0.filename < $1.filename }
        let session = CatalogSession()
        try session.open(package)
        return Library(package: package, catalog: catalog, session: session, assets: assets)
    }

    private func makeLoupe(_ session: CatalogSession, autoRender: Bool = false) -> LoupeController {
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = autoRender
        loupe.collectsHistogram = false
        let window = TestWindows.make(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600))
        window.contentView = loupe.view
        loupe.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        loupe.canvasView.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        loupe.view.layoutSubtreeIfNeeded()
        TestWindows.show(window)
        pump(0.05)
        loupe.view.layoutSubtreeIfNeeded()
        return loupe
    }

    private func pump(_ seconds: TimeInterval = 0.01) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @discardableResult
    private func waitFor(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump()
        }
        return condition()
    }

    private func fileURL(_ asset: Asset, in library: Library) throws -> URL {
        try library.catalog.fileURL(for: asset)
    }

    // MARK: - 1. switching to a deleted file

    func testSwitchingToAnExternallyDeletedFileFlagsItAndShowsTheBanner() throws {
        let library = try makeLibrary(count: 2)
        let a = library.assets[0]
        let b = library.assets[1]
        let bURL = try fileURL(b, in: library)

        let loupe = makeLoupe(library.session)
        library.session.activate(a.id)
        pump(0.1)
        XCTAssertFalse(library.session.isMarkedMissing(assetID: b.id), "both files exist at the start")
        XCTAssertTrue(loupe.missingBannerForTesting.isHidden)

        // The Finder deletes the file **after** the library was opened; nothing rescans it.
        try FileManager.default.removeItem(at: bURL)
        library.session.activate(b.id)
        pump(0.2)   // the banner updates on the observation bridge's next turn

        XCTAssertTrue(waitFor(5) { library.session.missingAssets.map(\.id).contains(b.id) },
                      "the switch must stat the one anchor row and notice the file is gone")
        XCTAssertEqual(library.session.missingSelectionIDs, [b.id])
        XCTAssertFalse(loupe.missingBannerForTesting.isHidden, "the banner is the visible answer")
        XCTAssertTrue(loupe.missingBannerForTesting.titleText.contains("文件不在原位置"))
        XCTAssertEqual(loupe.missingBannerForTesting.findButton.title, MissingFileText.findMenuTitle)
        XCTAssertEqual(loupe.missingBannerForTesting.removeButton.title, MissingMarkText.removeFromLibrary)
        // The stale 1920 px JPEG is exactly the thing the user mistook for a healthy photo.
        XCTAssertNotEqual(loupe.firstFrameContent, .displayThumbnail)
        XCTAssertFalse(loupe.firstFramePlaceholderVisible)
        print("463 ① switch: missing=\(library.session.missingAssets.map(\.filename)) "
              + "banner=\"\(loupe.missingBannerForTesting.titleText)\" "
              + "firstFrame=\(loupe.firstFrameContent.rawValue)")
    }

    // MARK: - 2. restore without a rescan

    func testRestoringTheFileClearsTheFlagAndTheBannerOnTheNextSwitch() throws {
        let library = try makeLibrary(count: 2)
        let a = library.assets[0]
        let b = library.assets[1]
        let bURL = try fileURL(b, in: library)
        let bytes = try Data(contentsOf: bURL)
        let loupe = makeLoupe(library.session)

        try FileManager.default.removeItem(at: bURL)
        library.session.activate(b.id)
        pump(0.2)
        XCTAssertTrue(waitFor(5) { library.session.missingAssets.map(\.id).contains(b.id) })
        XCTAssertFalse(loupe.missingBannerForTesting.isHidden)

        // The user puts the file back (same bytes, same path) — no rescan is asked for.
        try bytes.write(to: bURL)
        library.session.activate(a.id)
        pump(0.05)
        library.session.activate(b.id)
        pump(0.2)

        XCTAssertTrue(waitFor(5) { !library.session.missingAssets.map(\.id).contains(b.id) },
                      "the next switch re-stats and clears the flag")
        XCTAssertFalse(library.session.isMarkedMissing(assetID: b.id))
        XCTAssertTrue(loupe.missingBannerForTesting.isHidden, "the banner goes away with the fact")
        print("463 ② restore: missing=\(library.session.missingAssets.count) "
              + "bannerHidden=\(loupe.missingBannerForTesting.isHidden)")
    }

    // MARK: - 3. the decode-failure fallback

    func testDecodeFailureFlagsMissingEvenWhenTheStatLies() throws {
        let library = try makeLibrary(count: 1)
        let asset = library.assets[0]
        let url = try fileURL(asset, in: library)
        let loupe = makeLoupe(library.session, autoRender: true)

        // Make the per-switch stat lie: "the file exists" while it really does not. Only the decode
        // failure can find out now.
        library.session.availabilityFileExistsOverrideForTesting = { _ in true }
        try FileManager.default.removeItem(at: url)
        library.session.selectOnly(asset.id)
        library.session.mode = .loupe
        XCTAssertFalse(library.session.isMarkedMissing(assetID: asset.id),
                       "the injected stat says present, so the stat path alone cannot flag it")

        XCTAssertTrue(waitFor(8) { library.session.missingAssets.map(\.id).contains(asset.id) },
                      "the development failed on a missing file; that must land in the same flag "
                      + "(last error: \(loupe.lastPresentError ?? "—"))")
        pump(0.2)   // the banner follows on the next observation turn
        XCTAssertFalse(loupe.missingBannerForTesting.isHidden)
        print("463 ③ fallback: decodeError=\(loupe.lastPresentError ?? "—") "
              + "missing=\(library.session.missingAssets.count) "
              + "banner=\"\(loupe.missingBannerForTesting.titleText)\"")
    }

    // MARK: - 4. stacks

    func testDeletingAStacksTopKeepsTheMarkAfterUngrouping() throws {
        let library = try makeLibrary(count: 3)
        let first = library.assets[0]
        let second = library.assets[1]
        let summary = try XCTUnwrap(try library.catalog.makeStack(assetIDs: [first.id, second.id]))
        library.session.reload()
        XCTAssertEqual(library.session.stacksByTopID[summary.topID]?.count, 2)

        let topURL = try fileURL(try XCTUnwrap(library.catalog.asset(id: summary.topID)), in: library)
        try FileManager.default.removeItem(at: topURL)
        library.session.selectOnly(summary.topID)

        XCTAssertTrue(waitFor(5) { library.session.missingAssets.map(\.id).contains(summary.topID) })
        XCTAssertTrue(library.session.isMarkedMissing(assetID: summary.topID))

        // The mark is on the displayed top card (the hidden member has no card of its own).
        let top = try XCTUnwrap(library.session.assets.first { $0.id == summary.topID })
        let card = AssetCardView()
        card.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        card.asset = top
        card.stackCount = 2
        XCTAssertEqual(card.missingLabel, MissingFileText.moved)

        // Dissolving the stack does not unmark the photo: the file is still gone.
        XCTAssertGreaterThan(library.session.ungroupSelection(), 0)
        pump(0.05)
        XCTAssertTrue(library.session.assets.contains { $0.id == summary.topID })
        XCTAssertTrue(library.session.missingAssets.map(\.id).contains(summary.topID))
        XCTAssertTrue(library.session.isMarkedMissing(assetID: summary.topID))
        print("463 ④ stack: top=\(String(summary.topID.prefix(8))) "
              + "missingAfterUngroup=\(library.session.missingAssets.map(\.filename))")
    }

    func testAMissingHiddenMemberMarksTheStackTop() throws {
        let library = try makeLibrary(count: 3)
        let first = library.assets[0]
        let second = library.assets[1]
        let summary = try XCTUnwrap(try library.catalog.makeStack(assetIDs: [first.id, second.id]))
        let hidden = try XCTUnwrap(summary.memberIDs.first { $0 != summary.topID })
        let hiddenURL = try fileURL(try XCTUnwrap(library.catalog.asset(id: hidden)), in: library)
        try FileManager.default.removeItem(at: hiddenURL)

        // The full pass (open/rescan) is the path that can see a hidden member's file.
        _ = library.session.refreshAvailability()
        XCTAssertTrue(library.session.isMarkedMissing(assetID: summary.topID))
        XCTAssertTrue(library.session.stackHasMissingMember(forAssetID: summary.topID))

        let top = try XCTUnwrap(library.session.assets.first { $0.id == summary.topID })
        XCTAssertFalse(top.isMissing, "the top's own file is healthy")
        let card = AssetCardView()
        card.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        card.asset = top
        card.stackCount = 2
        card.stackHasMissingMember = library.session.stackHasMissingMember(forAssetID: summary.topID)
        XCTAssertEqual(card.missingLabel, MissingMarkText.stackHasMissing)
        print("463 ④ hidden: top marked=\(library.session.isMarkedMissing(assetID: summary.topID)) "
              + "label=\"\(card.missingLabel ?? "-")\"")
    }

    // MARK: - 5. offline roots keep their meaning

    func testAnOfflineRootIsStillNotMarkedMissing() throws {
        let library = try makeLibrary(count: 1)
        let asset = library.assets[0]
        let root = try XCTUnwrap(try library.catalog.root(id: asset.sourceRootId))
        try library.catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE source_roots SET path_hint = ? WHERE id = ?",
                           arguments: [workDir.appendingPathComponent("unplugged").path, root.id])
        }

        let report = library.session.refreshAvailability()
        XCTAssertEqual(report?.offlineRoots, 1)
        XCTAssertEqual(report?.checked, 0, "an unplugged drive is not examined")
        XCTAssertTrue(library.session.missingAssets.isEmpty)
        XCTAssertFalse(library.session.isMarkedMissing(assetID: asset.id))

        // The per-switch path keeps the same rule: a skipped root returns "not examined", not missing.
        XCTAssertNil(library.session.recheckAvailability(assetID: asset.id))
        XCTAssertFalse(library.session.isMarkedMissing(assetID: asset.id))
        print("463 ⑤ offline: roots=\(report?.offlineRoots ?? -1) checked=\(report?.checked ?? -1) "
              + "missing=\(library.session.missingAssets.count)")
    }
}
