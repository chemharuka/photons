import XCTest
import AppKit
import CoreGraphics
import ImageIO
import PhotonsCatalog
@testable import PhotonsUI

/// 文件 ▸ 导入照片… (⇧⌘I).
///
/// What is pinned here, in the order the user meets it:
///   1. the menu item exists, is ⇧⌘I, and is greyed until a library is open;
///   2. the panel takes photos *and* folders, multi-select, with exactly one 包含子文件夹 box whose
///      state is the previous run's and whose enablement is the 判定表 (提醒: 混选启用, 全文件禁用);
///   3. 导入 writes the memory, 取消 does not, a files-only pick does not;
///   4. GUI options are `.reference, recursive: …` — never `.copy`;
///   5. the import runs off the main thread, reloads, selects the first new photo, and leaves no
///      original inside the library package.
///
/// The panel is never *shown*: `ImportPanel.make` builds it, `presentPanel` stands in for
/// `runModal()`, and the real import is driven through `ImportCoordinator.start` with temp folders.
@MainActor
final class ImportUITests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        // `MainMenu.build()` assigns `NSApp.windowsMenu`, so the process needs an NSApplication
        // before any menu assertion. Nothing is activated or shown.
        _ = NSApplication.shared
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-import-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: fixtures

    private func libraryURL(_ name: String = "T") -> URL {
        workDir.appendingPathComponent("\(name).\(LibraryLayout.packageExtension)")
    }

    /// A fresh, open library. `Catalog.open` refuses a path that is not a package, so the fixture
    /// creates it first — exactly what 打开库… does through `Catalog.open` on a real one.
    private func newSession(at url: URL) throws -> CatalogSession {
        _ = try Catalog.create(at: url)
        let session = CatalogSession()
        try session.open(url)
        return session
    }

    private func sourceDir(_ name: String = "src") throws -> URL {
        let dir = workDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// An isolated `UserDefaults` domain per test — a shared suite would let one test's write answer
    /// another test's question. The domain is removed when the test ends.
    private func freshDefaults() -> UserDefaults {
        let name = "photons-import-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
        }
        return defaults
    }

    /// A real JPEG (the importer's job is identical for RAW and JPEG — it reads EXIF/XMP and hashes
    /// bytes; only *decode* would differ, and import never decodes).
    @discardableResult
    private func makeJPEG(at url: URL, seed: Int) throws -> URL {
        let w = 24, h = 16
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            pixels[i * 4] = UInt8((i &* 7 &+ seed &* 13) & 0xFF)
            pixels[i * 4 + 1] = UInt8((i &* 3 &+ seed &* 29) & 0xFF)
            pixels[i * 4 + 2] = UInt8((i &+ seed) & 0xFF)
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
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifDateTimeOriginal as String: "2026:03:07 10:00:00",
        ]] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("cannot finalize JPEG") }
        return url
    }

    /// Run the main run loop until `condition` holds. The import hops main-actor work through
    /// `DispatchQueue.main.async`, and an `XCTestExpectation.wait` on the main thread would block
    /// exactly those hops.
    private func pump(until condition: () -> Bool, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private func runImport(_ coordinator: ImportCoordinator,
                           _ request: ImportRequest,
                           timeout: TimeInterval = 30) throws -> ImportSummary {
        var summary: ImportSummary?
        coordinator.start(request) { summary = $0 }
        pump(until: { summary != nil }, timeout: timeout)
        XCTAssertFalse(coordinator.isImporting, "the run must be over before the assertions")
        return try XCTUnwrap(summary, "the import never called back")
    }

    /// Photo files an import must never *leave behind* in the package (reference mode).
    private static let photoExtensions: Set<String> = [
        "dng", "cr3", "cr2", "arw", "nef", "raf", "orf", "rw2", "srw", "pef", "jpg", "jpeg", "tif", "tiff",
    ]

    private func originalsInsidePackage(_ url: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [String] = []
        for case let file as URL in walker {
            if Self.photoExtensions.contains(file.pathExtension.lowercased()) {
                found.append(file.path)
            }
        }
        return found
    }

    // MARK: - 1. menu

    func testFileMenuOffersImportPhotoAtShiftCommandI() throws {
        let menu = MainMenu.build()
        let file = try XCTUnwrap(menu.items.first { $0.submenu?.title == "文件" }?.submenu)
        let titles = file.items.map(\.title)

        let openIndex = try XCTUnwrap(titles.firstIndex(of: "打开库…"))
        let importIndex = try XCTUnwrap(titles.firstIndex(of: "导入照片…"))
        XCTAssertEqual(importIndex, openIndex + 1, "导入照片… sits directly under 打开库…")

        let item = file.items[importIndex]
        XCTAssertEqual(item.action, #selector(EditorWindowController.importAction(_:)))
        XCTAssertEqual(item.keyEquivalent, "i")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift], "⇧⌘I")
        XCTAssertNil(item.target, "nil target: the responder chain decides which window imports")
    }

    func testImportIsDisabledWithoutALibrary() throws {
        let controller = EditorWindowController()
        let item = NSMenuItem(title: "导入照片…",
                              action: #selector(EditorWindowController.importAction(_:)),
                              keyEquivalent: "i")
        XCTAssertFalse(controller.validateMenuItem(item), "no library ⇒ nowhere to write ⇒ grey")

        let library = libraryURL()
        _ = try Catalog.create(at: library)
        try controller.openLibrary(at: library)
        XCTAssertTrue(controller.validateMenuItem(item))
    }

    // MARK: - 2. panel

    func testPanelTakesFilesAndFoldersAndCarriesOneCheckbox() {
        let (panel, include) = ImportPanel.make(ImportPanelConfiguration(includeSubfolders: false))
        XCTAssertTrue(panel.canChooseFiles, "几张照片也是一次导入")
        XCTAssertTrue(panel.canChooseDirectories)
        XCTAssertTrue(panel.allowsMultipleSelection, "混选: 文件 + 文件夹")
        XCTAssertEqual(panel.prompt, "导入")
        XCTAssertEqual(panel.message, "选择要导入的照片或文件夹")

        let accessory = panel.accessoryView
        XCTAssertNotNil(accessory, "the box lives in the panel, not in an alert after it")
        XCTAssertEqual(accessory?.frame.height, ImportPanel.accessorySize.height)
        XCTAssertEqual(accessory?.subviews.count, 1, "exactly one checkbox, no explanatory copy")
        XCTAssertEqual(include.title, "包含子文件夹")
        XCTAssertEqual(include.state, .off, "the remembered value is applied at construction")
        XCTAssertFalse(include.isEnabled, "nothing is picked yet — the watcher enables it")

        let (_, ticked) = ImportPanel.make(ImportPanelConfiguration(includeSubfolders: true))
        XCTAssertEqual(ticked.state, .on)
    }

    /// The 判定表, all three rows. 混选 is enabled: the box's scope is only the folder part.
    func testSubfolderBoxEnablementFollowsTheSelectionShape() throws {
        let filesOnly = ImportSelectionShape(hasFiles: true, hasFolders: false)
        XCTAssertFalse(filesOnly.subfolderOptionEnabled)
        XCTAssertFalse(filesOnly.remembersSubfolderChoice)

        let foldersOnly = ImportSelectionShape(hasFiles: false, hasFolders: true)
        XCTAssertTrue(foldersOnly.subfolderOptionEnabled)
        XCTAssertTrue(foldersOnly.remembersSubfolderChoice)

        let mixed = ImportSelectionShape(hasFiles: true, hasFolders: true)
        XCTAssertTrue(mixed.subfolderOptionEnabled, "混选时勾选框必须启用，不能变灰")
        XCTAssertTrue(mixed.remembersSubfolderChoice)

        let folder = try sourceDir()
        let file = try makeJPEG(at: workDir.appendingPathComponent("solo.jpg"), seed: 1)
        XCTAssertEqual(ImportSelectionShape.classify([file]), filesOnly)
        XCTAssertEqual(ImportSelectionShape.classify([folder]), foldersOnly)
        XCTAssertEqual(ImportSelectionShape.classify([file, folder]), mixed)
    }

    // MARK: - 3. the remembered box

    func testFirstRunOpensWithSubfoldersTicked() {
        let defaults = freshDefaults()
        XCTAssertNil(defaults.object(forKey: ImportPanelConfiguration.includeSubfoldersKey))
        XCTAssertTrue(ImportPanelConfiguration.load(from: defaults).includeSubfolders)
    }

    func testTheBoxStartsFromWhateverTheLastRunAnswered() {
        let defaults = freshDefaults()
        ImportPanelConfiguration(includeSubfolders: false).save(to: defaults)
        XCTAssertFalse(ImportPanelConfiguration.load(from: defaults).includeSubfolders)

        ImportPanelConfiguration(includeSubfolders: true).save(to: defaults)
        XCTAssertTrue(ImportPanelConfiguration.load(from: defaults).includeSubfolders)
    }

    func testImportRemembersTheAnswerAndCancelDoesNot() throws {
        let defaults = freshDefaults()
        let folder = try sourceDir()
        defaults.set(true, forKey: ImportPanelConfiguration.includeSubfoldersKey)

        let request = ImportPanelConfiguration.resolve(
            .confirmed(sources: [folder], includeSubfolders: false), defaults: defaults)
        XCTAssertEqual(request?.includeSubfolders, false)
        XCTAssertFalse(defaults.bool(forKey: ImportPanelConfiguration.includeSubfoldersKey),
                       "导入 must write the box back immediately")

        defaults.set(true, forKey: ImportPanelConfiguration.includeSubfoldersKey)
        XCTAssertNil(ImportPanelConfiguration.resolve(.cancelled, defaults: defaults),
                     "取消 imports nothing")
        XCTAssertTrue(defaults.bool(forKey: ImportPanelConfiguration.includeSubfoldersKey),
                      "取消 must not rewrite the memory")
    }

    func testAFileOnlyPickDoesNotTouchTheMemory() throws {
        let defaults = freshDefaults()
        defaults.set(false, forKey: ImportPanelConfiguration.includeSubfoldersKey)
        let file = try makeJPEG(at: workDir.appendingPathComponent("single.jpg"), seed: 9)

        let request = ImportPanelConfiguration.resolve(
            .confirmed(sources: [file], includeSubfolders: true), defaults: defaults)
        XCTAssertNotNil(request, "a file-only pick is still an import")
        XCTAssertFalse(defaults.bool(forKey: ImportPanelConfiguration.includeSubfoldersKey),
                       "no folder in the pick ⇒ the box was inert ⇒ nothing to remember")
    }

    // MARK: - 4. options

    func testGuiImportIsAlwaysReferenceNeverCopy() {
        let on = ImportRequest(sources: [URL(fileURLWithPath: "/tmp/folder")], includeSubfolders: true)
        let off = ImportRequest(sources: [URL(fileURLWithPath: "/tmp/folder")], includeSubfolders: false)

        XCTAssertEqual(on.options.mode, .reference, "库不存原文件")
        XCTAssertEqual(off.options.mode, .reference, "GUI 永远不传入 copy")
        XCTAssertTrue(on.options.recursive)
        XCTAssertFalse(off.options.recursive)
    }

    // MARK: - 5. the run

    func testImportAddsThePhotosSelectsTheFirstAndCopiesNothing() throws {
        let library = libraryURL()
        let session = try newSession(at: library)
        XCTAssertTrue(session.assets.isEmpty)

        let dir = try sourceDir()
        try makeJPEG(at: dir.appendingPathComponent("a.jpg"), seed: 11)
        try makeJPEG(at: dir.appendingPathComponent("b.jpg"), seed: 12)

        let coordinator = ImportCoordinator(session: session, defaults: freshDefaults())
        let summary = try runImport(coordinator,
                                    ImportRequest(sources: [dir], includeSubfolders: true))

        XCTAssertEqual(summary.added, 2)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(session.assets.count, 2, "reload() ran")
        XCTAssertEqual(session.selection.count, 1)
        XCTAssertEqual(session.anchorID, summary.addedAssetIDs.first,
                       "the first new photo is the anchor")
        XCTAssertNil(coordinator.progress, "the progress line goes idle")

        // Reference mode: the originals stay where they are, and the package holds none of them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.jpg").path))
        XCTAssertEqual(originalsInsidePackage(library), [],
                       "库里只存索引/元数据/缩略图，不存原文件")
    }

    func testSecondImportAddsNothingAndKeepsTheSelection() throws {
        let library = libraryURL()
        let session = try newSession(at: library)
        let dir = try sourceDir()
        try makeJPEG(at: dir.appendingPathComponent("a.jpg"), seed: 21)
        try makeJPEG(at: dir.appendingPathComponent("b.jpg"), seed: 22)

        let coordinator = ImportCoordinator(session: session, defaults: freshDefaults())
        _ = try runImport(coordinator, ImportRequest(sources: [dir], includeSubfolders: true))
        let firstAnchor = session.anchorID
        XCTAssertNotNil(firstAnchor)

        let again = try runImport(coordinator, ImportRequest(sources: [dir], includeSubfolders: true))
        XCTAssertEqual(again.added, 0)
        XCTAssertGreaterThan(again.duplicate + again.unchanged, 0)
        XCTAssertEqual(session.assets.count, 2)
        XCTAssertEqual(session.anchorID, firstAnchor, "no new photo ⇒ the selection is untouched")
        XCTAssertEqual(originalsInsidePackage(library), [])
    }

    func testMixedSelectionImportsTheFileAndTheFoldersTopLevel() throws {
        let library = libraryURL()
        let session = try newSession(at: library)

        let dir = try sourceDir("A")
        try makeJPEG(at: dir.appendingPathComponent("top.jpg"), seed: 31)
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try makeJPEG(at: sub.appendingPathComponent("deep.jpg"), seed: 32)
        let named = try makeJPEG(at: workDir.appendingPathComponent("named.jpg"), seed: 33)

        let coordinator = ImportCoordinator(session: session, defaults: freshDefaults())
        let summary = try runImport(coordinator,
                                    ImportRequest(sources: [named, dir], includeSubfolders: false))
        XCTAssertEqual(summary.added, 2, "named.jpg + A/top.jpg; A/sub/deep.jpg stays out")
        XCTAssertEqual(Set(session.assets.map(\.filename)), Set(["named.jpg", "top.jpg"]))
    }

    /// 相册（078 B10）在导入路径上的两条契约：导入不改已有相册的成员，新照片不会自动进相册。
    ///
    /// 这条守着一种很自然的错误实现：把「导入」当成「顺便把新照片塞进当前打开的相册」。
    /// 相册是用户摆的，不是导入器决定的。
    func testAnImportLeavesAlbumsAloneAndDoesNotJoinThem() throws {
        let library = libraryURL()
        let session = try newSession(at: library)
        let dir = try sourceDir()
        try makeJPEG(at: dir.appendingPathComponent("a.jpg"), seed: 41)
        try makeJPEG(at: dir.appendingPathComponent("b.jpg"), seed: 42)

        let coordinator = ImportCoordinator(session: session, defaults: freshDefaults())
        _ = try runImport(coordinator, ImportRequest(sources: [dir], includeSubfolders: true))
        XCTAssertEqual(session.assets.count, 2)

        let album = try session.createAlbum(named: "旅行")
        let member = try XCTUnwrap(session.assets.first?.id)
        try session.addPhotos([member], toAlbum: album.id)
        XCTAssertEqual(session.albums.first?.count, 1)

        // 第二次导入：同一批文件（幂等）+ 新的一张。
        try makeJPEG(at: dir.appendingPathComponent("c.jpg"), seed: 43)
        let again = try runImport(coordinator, ImportRequest(sources: [dir], includeSubfolders: true))
        XCTAssertEqual(again.added, 1)

        XCTAssertEqual(session.stats?.total, 3, "导入真的进了库")
        XCTAssertEqual(session.albums.map(\.name), ["旅行"], "导入不动相册本身")
        XCTAssertEqual(session.albums.first?.count, 1, "新照片不会自动加入相册")
        let catalog = try Catalog.open(at: library)
        XCTAssertEqual(try catalog.albumAssetIDs(album.id), [member],
                       "库里的成员关系与导入前一字不差")
    }

    // MARK: - 6. the interaction

    func testEveryImportShowsThePanelAndCancelStartsNothing() throws {
        let session = try newSession(at: libraryURL())
        let defaults = freshDefaults()
        let coordinator = ImportCoordinator(session: session, defaults: defaults)

        var shown = 0
        coordinator.presentPanel = { _ in
            shown += 1
            return .cancel
        }
        coordinator.presentAndStart()
        coordinator.presentAndStart()

        XCTAssertEqual(shown, 2, "每次导入都要问，记忆只决定勾选框的初始状态")
        XCTAssertEqual(coordinator.panelPresentationCount, 2)
        XCTAssertEqual(coordinator.runCount, 0)
        XCTAssertNil(defaults.object(forKey: ImportPanelConfiguration.includeSubfoldersKey),
                     "取消 writes nothing")
    }

    func testCancelIsANoOpWhenNothingIsRunning() throws {
        let session = try newSession(at: libraryURL())
        let coordinator = ImportCoordinator(session: session, defaults: freshDefaults())
        coordinator.cancel()
        XCTAssertFalse(coordinator.isImporting)
        XCTAssertEqual(coordinator.runCount, 0)
    }

    // MARK: - 7. the progress line

    func testProgressLineShowsCountsAndCancels() {
        let bar = ImportProgressBar()
        XCTAssertTrue(bar.isHidden, "idle")

        bar.show(ImportProgress(processed: 12, total: 48).text)
        XCTAssertEqual(bar.text, "导入中 12/48")
        XCTAssertFalse(bar.isHidden)

        var cancels = 0
        bar.onCancel = { cancels += 1 }
        bar.sendCancel()
        XCTAssertEqual(cancels, 1, "取消 is one click away while the run is live")

        bar.showFailure(3)
        XCTAssertEqual(bar.text, "3 个失败")
        XCTAssertFalse(bar.isCancelEnabled, "nothing left to cancel once it is over")

        bar.hide()
        XCTAssertTrue(bar.isHidden)
        XCTAssertEqual(bar.text, "")
    }

    func testProgressTextBeforeTheWalkKnowsItsSize() {
        XCTAssertEqual(ImportProgress(processed: 0, total: 0).text, "导入中…")
    }
}
