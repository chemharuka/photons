import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 453 — 「自动调整」的三扇门：编辑菜单 (⌘U) / 网格右键 / 胶片条右键 / loupe 画布右键。
///
/// 右键只在**单张**时出现：批量自动是 454 的后台任务，这里不假装能同步跑一批。
@MainActor
final class AutoDevelopMenu453Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var windows: [NSWindow] = []
    private var catalog: Catalog!
    private var session: CatalogSession!
    private var root: SourceRoot!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-auto453-menu-\(UUID().uuidString)", isDirectory: true)
        src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixture

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    @discardableResult
    private func makeSession(dngCount: Int = 3) throws -> [Asset] {
        let url = workDir.appendingPathComponent("S453.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: url)
        root = try catalog.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        for i in 0..<dngCount {
            let name = String(format: "IMG_%04d.dng", i)
            let fileURL = src.appendingPathComponent(name)
            try Data([0x00]).write(to: fileURL)
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: "dng", kind: .raw, size: 1, mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 1024, height: 1024,
                              captureTime: String(format: "2026-05-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-05-01",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }
        let store = MemoryStore()
        let s = CatalogSession(filterStore: store, sortPreferenceStore: store,
                               remembersRecentLibrary: false)
        try s.open(url)
        s.setSortOrder(.newestFirst)
        session = s
        return assets
    }

    private struct Surfaces {
        let grid: AssetGridController
        let strip: FilmstripController
    }

    private func makeSurfaces() -> Surfaces {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200))
        window.contentView = content
        windows.append(window)

        let grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        content.addSubview(grid.view)

        let strip = FilmstripController(session: session)
        _ = strip.view
        strip.view.frame = NSRect(x: 0, y: 800, width: 1600, height: WorkspaceLayout.filmstripHeight)
        content.addSubview(strip.view)

        content.layoutSubtreeIfNeeded()
        pump(0.2)
        return Surfaces(grid: grid, strip: strip)
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func autoRow(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == AutoAdjustMenuBuilder.title }
    }

    /// 490 — the colour sibling travels on exactly the same menu.
    private func colorRow(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == AutoAdjustMenuBuilder.colorTitle }
    }

    // MARK: - ① 编辑 ▸ 自动调整 · ⌘U

    func testEditMenuCarriesOneCommandUAndTheResponderVerb() {
        _ = NSApplication.shared
        let menu = MainMenu.build()
        var entries: [(key: String, modifiers: UInt, title: String)] = []

        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if !item.keyEquivalent.isEmpty {
                    entries.append((item.keyEquivalent, item.keyEquivalentModifierMask.rawValue,
                                    "\(menu.title)/\(item.title)"))
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(menu)

        let ours = entries.filter { $0.key == "u"
            && $0.modifiers == NSEvent.ModifierFlags.command.rawValue }
        XCTAssertEqual(ours.count, 1, "exactly one item carries ⌘U: \(ours.map(\.title))")
        XCTAssertTrue(ours.first?.title.hasSuffix("/自动调整") == true,
                      "and it is 编辑 ▸ 自动调整: \(ours.map(\.title))")

        let edit = menu.items.first { $0.submenu?.title == "编辑" }?.submenu
        let item = edit?.items.first { $0.action == #selector(EditorWindowController.autoDevelopAction(_:)) }
        XCTAssertNotNil(item, "编辑 ▸ 自动调整 must carry the responder-chain action")
        XCTAssertEqual(item?.keyEquivalent, "u")
        XCTAssertEqual(item?.keyEquivalentModifierMask, [.command])

        // 清除旗标's bare U is still bare, so the two keys do not shadow each other.
        let bareU = entries.filter { $0.key == "u" && $0.modifiers == 0 }
        XCTAssertEqual(bareU.count, 1, "the bare U (清除旗标) must stay bare: \(bareU.map(\.title))")

        let window = EditorWindowController()
        XCTAssertTrue(window.responds(to: #selector(EditorWindowController.autoDevelopAction(_:))))
        let probe = NSMenuItem(title: "自动调整",
                               action: #selector(EditorWindowController.autoDevelopAction(_:)),
                               keyEquivalent: "u")
        XCTAssertFalse(window.validateMenuItem(probe), "no anchor ⇒ the row is grey")
    }

    // MARK: - ② 右键：网格 / 胶片条 单张有、多张没有

    func testGridAndFilmstripShowTheRowForOnePhotoAndHideItForMany() throws {
        let assets = try makeSession()
        let surfaces = makeSurfaces()
        let single = try XCTUnwrap(assets.first)

        session.setSelection([single.id], anchor: single.id)
        pump(0.1)
        let gridMenu = try XCTUnwrap(surfaces.grid.menuForRightClick(nil))
        let stripMenu = try XCTUnwrap(surfaces.strip.menuForRightClick(nil))
        XCTAssertNotNil(autoRow(in: gridMenu), "网格右键缺「自动调整」: \(gridMenu.items.map(\.title))")
        XCTAssertNotNil(autoRow(in: stripMenu), "胶片条右键缺「自动调整」: \(stripMenu.items.map(\.title))")
        // 490 — 自动颜色 is its own row, single photo only, on the very same menus.
        XCTAssertNotNil(colorRow(in: gridMenu), "网格右键缺「自动颜色」: \(gridMenu.items.map(\.title))")
        XCTAssertNotNil(colorRow(in: stripMenu), "胶片条右键缺「自动颜色」: \(stripMenu.items.map(\.title))")

        session.setSelection(Set(assets.map(\.id)), anchor: assets[0].id)
        pump(0.1)
        let gridMany = try XCTUnwrap(surfaces.grid.menuForRightClick(nil))
        let stripMany = try XCTUnwrap(surfaces.strip.menuForRightClick(nil))
        XCTAssertNil(autoRow(in: gridMany), "多选时网格不得出现批量自动: \(gridMany.items.map(\.title))")
        XCTAssertNil(autoRow(in: stripMany), "多选时胶片条不得出现批量自动: \(stripMany.items.map(\.title))")
        XCTAssertNil(colorRow(in: gridMany), "多选时网格不得出现批量自动颜色: \(gridMany.items.map(\.title))")
        XCTAssertNil(colorRow(in: stripMany), "多选时胶片条不得出现批量自动颜色: \(stripMany.items.map(\.title))")
    }

    // MARK: - ③ loupe 画布的 menu(for:)

    func testLoupeCanvasMenuCarriesTheRow() throws {
        let assets = try makeSession()
        let single = try XCTUnwrap(assets.first)
        session.setSelection([single.id], anchor: single.id)
        session.mode = .loupe

        let loupe = LoupeController(session: session)
        _ = loupe.view
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1,
            pressure: 1))
        let menu = try XCTUnwrap(loupe.canvasView.menu(for: event),
                                 "loupe 画布没有右键菜单")
        let row = try XCTUnwrap(autoRow(in: menu),
                                "loupe 画布缺「自动调整」: \(menu.items.map(\.title))")
        XCTAssertEqual(row.title, "自动调整")
        // 490 — and its colour sibling.
        let color = try XCTUnwrap(colorRow(in: menu),
                                  "loupe 画布缺「自动颜色」: \(menu.items.map(\.title))")
        XCTAssertEqual(color.title, "自动颜色")
    }
}
