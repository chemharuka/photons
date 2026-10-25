import AppKit
import CryptoKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import PhotonsCatalog
import PhotonsCore
import PhotonsExport

/// The main menu, built in code (no XIB), with nil targets so AppKit resolves each item through the
/// responder chain and validates it against `EditorWindowController.validateMenuItem`.
@MainActor
public enum MainMenu {
    public static func build(appName: String = "Photons") -> NSMenu {
        let main = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: "文件")
        fileItem.submenu = file
        file.addItem(withTitle: "打开库…", action: #selector(EditorWindowController.openLibraryAction(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        // ⌘⇧E, the shortcut every photo app puts on "export the selection". Grey with an empty
        // selection (`validateMenuItem`), so the menu cannot promise a batch that has no items.
        let exportItem = file.addItem(withTitle: "导出…",
                                      action: #selector(EditorWindowController.exportAction(_:)),
                                      keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]

        // Edit
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        // Nil targets: AppKit walks the responder chain to the window controller, which validates
        // both items against `CatalogSession.canUndo/canRedo` (grey with no history).
        edit.addItem(withTitle: "撤销", action: #selector(EditorWindowController.undoAction(_:)),
                     keyEquivalent: "z")
        let redoItem = edit.addItem(withTitle: "重做", action: #selector(EditorWindowController.redoAction(_:)),
                                    keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "全选照片", action: #selector(EditorWindowController.selectAllAction(_:)), keyEquivalent: "a")

        // Photo — rating / flag / colour label. Catalog metadata, not edits, so these live outside
        // the undo pair above. Bare digits and letters (no ⌘) because that is the convention every
        // photo app uses, and ⌘0–⌘5 would collide with the view menu.
        let photoItem = NSMenuItem()
        main.addItem(photoItem)
        let photo = NSMenu(title: "照片")
        photoItem.submenu = photo
        for stars in 0...5 {
            let item = photo.addItem(withTitle: stars == 0 ? "清除星级" : "\(stars) 星",
                                     action: #selector(EditorWindowController.ratingAction(_:)),
                                     keyEquivalent: "\(stars)")
            item.keyEquivalentModifierMask = []
            item.tag = stars
        }
        photo.addItem(.separator())
        let pick = photo.addItem(withTitle: "标记为选取 (P)",
                                 action: #selector(EditorWindowController.pickAction(_:)), keyEquivalent: "p")
        pick.keyEquivalentModifierMask = []
        pick.tag = 1
        let reject = photo.addItem(withTitle: "标记为拒绝 (X)",
                                   action: #selector(EditorWindowController.rejectAction(_:)), keyEquivalent: "x")
        reject.keyEquivalentModifierMask = []
        reject.tag = 2
        let unflag = photo.addItem(withTitle: "清除旗标 (U)",
                                   action: #selector(EditorWindowController.clearFlagAction(_:)), keyEquivalent: "u")
        unflag.keyEquivalentModifierMask = []
        photo.addItem(.separator())
        for (index, label) in ColorLabel.allCases.enumerated() {
            let item = photo.addItem(withTitle: "色标：\(label.displayName)",
                                     action: #selector(EditorWindowController.colorLabelAction(_:)),
                                     keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.option]
            item.tag = index
        }

        // Develop — presets. The list is the library's, so the menu is rebuilt every time it opens
        // (`PresetMenu.menuNeedsUpdate`): a preset created in the inspector card shows up here
        // without a relaunch, and a deleted one cannot be applied from a stale item.
        let developItem = NSMenuItem()
        main.addItem(developItem)
        let develop = NSMenu(title: "显影")
        developItem.submenu = develop
        let presetItem = NSMenuItem(title: "预设", action: nil, keyEquivalent: "")
        presetItem.submenu = PresetMenu(kind: .apply)
        develop.addItem(presetItem)

        // View
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: "显示")
        viewItem.submenu = view
        view.addItem(withTitle: "网格", action: #selector(EditorWindowController.showGridAction(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "单图", action: #selector(EditorWindowController.showLoupeAction(_:)), keyEquivalent: "2")
        view.addItem(.separator())
        let strip = view.addItem(withTitle: "胶片条（第二浏览器）",
                                 action: #selector(EditorWindowController.toggleFilmstripAction(_:)),
                                 keyEquivalent: "b")
        strip.keyEquivalentModifierMask = [.control, .command]
        let list = view.addItem(withTitle: "浏览列表",
                                action: #selector(EditorWindowController.showBrowserListAction(_:)),
                                keyEquivalent: "a")
        list.keyEquivalentModifierMask = [.control, .command]
        view.addItem(.separator())
        // 倍率. The four stops are the ladder `LoupeController.zoomStops` defines, ticked by
        // `validateMenuItem` when the camera is exactly on one; 适应窗口 and 放大/缩小 are the
        // keyboard path (⌘0, ⌘=, ⌘−) every photo app has.
        view.addItem(withTitle: "适应窗口",
                     action: #selector(EditorWindowController.zoomFitAction(_:)),
                     keyEquivalent: "0")
        for (index, stop) in LoupeController.zoomStops.enumerated() {
            let item = view.addItem(withTitle: stop == 1 ? "1:1" : "\(Int(stop)):1",
                                    action: #selector(EditorWindowController.zoomStopAction(_:)),
                                    keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = Int(stop)
        }
        view.addItem(.separator())
        view.addItem(withTitle: "放大",
                     action: #selector(EditorWindowController.zoomInAction(_:)),
                     keyEquivalent: "=")
        view.addItem(withTitle: "缩小",
                     action: #selector(EditorWindowController.zoomOutAction(_:)),
                     keyEquivalent: "-")

        // Window
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

/// Develop ▸ 预设 — rebuilt from the library each time it opens.
///
/// A menu that is a static list of names goes stale the moment the inspector card creates or
/// deletes one, and a "delete shape 3" style tag map is the classic way to delete the wrong preset.
/// So the items carry the **name** in `representedObject` and the list is re-read from the session
/// in `menuNeedsUpdate` — the same `presetRecords` cache the panel draws.
///
/// The session is found through the responder chain's owner (the window controller), not passed in:
/// the menu is built by `MainMenu.build()` at launch, before any library is open, and must still be
/// correct for the second library the user opens.
@MainActor
final class PresetMenu: NSMenu, NSMenuDelegate {

    enum Kind {
        /// The preset list itself, plus 新建/设为默认/删除.
        case apply
        case setDefault
        case delete
    }

    private let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(title: "")
        title = kind == .apply ? "预设" : (kind == .setDefault ? "设为默认" : "删除预设")
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("no nibs in this app") }

    // MARK: building

    func menuNeedsUpdate(_ menu: NSMenu) {
        let controller = Self.activeEditor()
        let records = controller?.session.presetRecords ?? []
        menu.removeAllItems()

        guard !records.isEmpty else {
            let empty = NSMenuItem(title: "（还没有预设）", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            if kind == .apply { addCreateItem(to: menu) }
            return
        }

        let defaultName = controller?.session.defaultPresetName
        for record in records {
            let item = NSMenuItem(title: record.name, action: action(), keyEquivalent: "")
            item.representedObject = record.name
            if kind == .apply { item.state = record.isDefault ? .on : .off }
            menu.addItem(item)
        }

        if kind == .apply {
            menu.addItem(.separator())
            addCreateItem(to: menu)
            menu.addItem(.separator())
            let defaults = NSMenuItem(title: "设为默认", action: nil, keyEquivalent: "")
            defaults.submenu = PresetMenu(kind: .setDefault)
            menu.addItem(defaults)
            let delete = NSMenuItem(title: "删除预设", action: nil, keyEquivalent: "")
            delete.submenu = PresetMenu(kind: .delete)
            menu.addItem(delete)
            if let defaultName {
                menu.addItem(.separator())
                let note = NSMenuItem(title: "默认：\(defaultName)", action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
        }
    }

    private func addCreateItem(to menu: NSMenu) {
        menu.addItem(withTitle: "从当前照片新建预设…",
                     action: #selector(EditorWindowController.newPresetFromCurrentAction(_:)),
                     keyEquivalent: "")
    }

    private func action() -> Selector {
        switch kind {
        case .apply: return #selector(EditorWindowController.applyPresetAction(_:))
        case .setDefault: return #selector(EditorWindowController.setDefaultPresetAction(_:))
        case .delete: return #selector(EditorWindowController.deletePresetAction(_:))
        }
    }

    private static func activeEditor() -> EditorWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? EditorWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? EditorWindowController {
            return controller
        }
        return NSApp.windows.compactMap { $0.windowController as? EditorWindowController }.first
    }
}

/// `--ui-smoke` and `--ui-bench`: the two acceptance harnesses that need a real window.
///
/// Both drive the shipped views (no test doubles): the grid item count comes from
/// `NSCollectionView.numberOfItems`, the columns come from the flow layout's own attributes, and the
/// loupe frame comes out of `RenderGraph`. The screenshots land in `local/out/` for a human to look
/// at — they are not pixel goldens (a UI that differs across OS point releases would make the suite
/// red for no reason).
@MainActor
public final class UISmokeRunner {

    public let windowController: EditorWindowController
    public let libraryURL: URL
    public let expectedRows: Int?
    public let screenshotDirectory: URL
    public var widths: [CGFloat] = [1200, 1600, 2400]

    private var lines: [String] = []
    private var failures: [String] = []

    public init(windowController: EditorWindowController, libraryURL: URL,
                expectedRows: Int?, screenshotDirectory: URL) {
        self.windowController = windowController
        self.libraryURL = libraryURL
        self.expectedRows = expectedRows
        self.screenshotDirectory = screenshotDirectory
    }

    // MARK: smoke

    public func run() -> Int32 {
        log("ui-smoke: \(libraryURL.lastPathComponent)")
        try? FileManager.default.createDirectory(at: screenshotDirectory, withIntermediateDirectories: true)

        do {
            try windowController.openLibrary(at: libraryURL)
        } catch {
            fail("could not open library: \(error.localizedDescription)")
            return finish()
        }

        guard let window = windowController.window else {
            fail("no window")
            return finish()
        }
        window.setContentSize(NSSize(width: 1600, height: 940))
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        pump(0.5)

        let session = windowController.session
        let root = windowController.rootView!
        let grid = root.gridController
        let gridView = grid.collectionView

        // 0. the window is actually on screen (a window that never appears would still lay out)
        check(String(format: "window visible %.0f×%.0f", window.frame.width, window.frame.height),
              window.isVisible && window.frame.width >= WorkspaceLayout.minimumWindowSize.width
              && window.frame.height >= WorkspaceLayout.minimumWindowSize.height)

        // 1. every catalog row reached the grid
        let rows = session.assets.count
        log("library rows            \(rows)")
        if let expectedRows, expectedRows != rows {
            fail("library rows \(rows) != expected \(expectedRows)")
        }
        check("grid item count \(gridView.numberOfItems(inSection: 0)) == library rows \(rows)",
              gridView.numberOfItems(inSection: 0) == rows)

        // 2. tool bar contract
        let toolbarCentre = root.geometry.topBar.midY
        let lightCentre = root.trafficLightCentreY()
        check(String(format: "top bar height %.0f == 36", root.geometry.topBar.height),
              abs(root.geometry.topBar.height - WorkspaceLayout.topBarHeight) < 0.01)
        if let lightCentre {
            // The system titlebar is 28 pt on this macOS, so the lights sit at 14 pt from the top and
            // the 36 pt container (starting at the window edge) centres at 18. We follow the lights
            // as far as the container allows instead of moving system buttons; 4 pt is the residual.
            check(String(format: "tool centre y %.1f ≈ traffic-light centre %.1f (±4 pt)", toolbarCentre, lightCentre),
                  abs(toolbarCentre - lightCentre) <= 4.0)
        }
        check(String(format: "browser %.0f pt in 196…260", root.geometry.browser.width),
              root.geometry.browser.width >= 196 && root.geometry.browser.width <= 260)
        check(String(format: "inspector %.0f pt in 300…364", root.geometry.inspector.width),
              root.geometry.inspector.width >= 300 && root.geometry.inspector.width <= 364)
        check(String(format: "canvas %.0f × %.0f ≥ 560 × 420",
                     root.geometry.canvas.width, root.geometry.canvas.height),
              root.geometry.canvas.width >= 560 && root.geometry.canvas.height >= 420)

        // 3. three window widths: columns and row height must equal the pure function
        for width in widths {
            window.setContentSize(NSSize(width: width, height: 940))
            pump(0.2)
            root.layoutSubtreeIfNeeded()
            gridView.layoutSubtreeIfNeeded()

            let metrics = GridLayout.metrics(forWidth: gridView.bounds.width)
            let applied = grid.appliedItemSize
            check(String(format: "w=%.0f columns=%d itemSize=%.1f×%.1f (pure: %d / %.1f×%.1f)",
                         width, metrics.columns, applied.width, applied.height,
                         metrics.columns, metrics.itemSize.width, metrics.itemSize.height),
                  abs(applied.width - metrics.itemSize.width) < 0.5
                  && abs(applied.height - metrics.itemSize.height) < 0.5)

            if let first = gridView.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)),
               let last = gridView.layoutAttributesForItem(at: IndexPath(item: metrics.columns - 1, section: 0)),
               let wrapped = gridView.layoutAttributesForItem(at: IndexPath(item: metrics.columns, section: 0)) {
                let sameRow = abs(first.frame.minY - last.frame.minY) < 0.5
                let nextRow = abs(wrapped.frame.minY - (first.frame.maxY + metrics.spacing)) < 0.5
                check(String(format: "w=%.0f row0 has %d items, row1 starts at +%.1f",
                             width, metrics.columns, wrapped.frame.minY - first.frame.minY),
                      sameRow && nextRow)
            } else {
                fail("w=\(Int(width)): flow layout produced no attributes")
            }
            capture(window: window, name: String(format: "ui-smoke-grid-%.0f.png", width))
        }

        // 3b. the grid streams real thumbnails, not placeholders
        window.setContentSize(NSSize(width: 1600, height: 940))
        pump(0.3)
        root.layoutSubtreeIfNeeded()
        gridView.layoutSubtreeIfNeeded()
        checkGridThumbnails(grid: grid, gridView: gridView, session: session,
                            loupe: root.loupeController, window: window)

        // 3c. rating / flag / colour label + the filter strip (catalog metadata, never an edit)
        checkRatingAndFilter(session: session, grid: grid, gridView: gridView,
                             controller: windowController, window: window)

        // 4. filmstrip is the second browser and shares the selection
        windowController.showBrowserAsFilmstrip()
        pump(0.3)
        let stripController = root.filmstripController
        let strip = stripController.collectionView
        check("filmstrip item count \(strip.numberOfItems(inSection: 0)) == library rows \(rows)",
              strip.numberOfItems(inSection: 0) == rows)
        check(String(format: "filmstrip container %.0f pt == 122", root.geometry.filmstrip?.height ?? 0),
              abs((root.geometry.filmstrip?.height ?? 0) - WorkspaceLayout.filmstripHeight) < 0.01)
        if let id = session.anchorID {
            check("filmstrip shares the grid selection",
                  (strip.selectionIndexPaths.first.map { session.assets[safe: $0.item]?.id }) == id
                  || session.selection.contains(id))
        }

        // 4b. real thumbnails in the strip, from the same service the grid used
        checkFilmstripThumbnails(controller: stripController, session: session, window: window)
        checkSharedThumbnailService(grid: grid, strip: stripController, session: session)
        // 4c. §6.1 — a DNG above t512 is downgraded, not upscaled
        checkDNGCeiling(session: session, grid: grid)

        capture(window: window, name: "ui-smoke-filmstrip.png")
        windowController.showBrowserAsList()
        pump(0.2)

        // 5. the loupe renders one real frame through RenderGraph
        let asset = session.assets.first(where: { $0.kind == .raw }) ?? session.assets.first
        if let asset, let url = session.fileURL(for: asset) {
            // Keep the automatic ladder quiet until the synchronous frame is measured: two 60 MP
            // decodes at once is a memory spike, not a test.
            root.loupeController.autoRenderEnabled = false
            session.activate(asset.id)
            pump(0.3)
            log("loupe asset             \(url.path)  readable=\(FileManager.default.isReadableFile(atPath: url.path))")
            if let probe = try? RAWDecoder().probe(url) {
                log("loupe probe             \(probe.nativeWidth)×\(probe.nativeHeight) offered \(probe.supportedVersions.joined(separator: ","))")
            } else {
                log("loupe probe             FAILED (CIRAWFilter could not open the file)")
            }
            if let small = try? RAWDecoder().decode(url, options: DecodeOptions(scale: 0.125)) {
                log("loupe decode check      \(small.width)×\(small.height) v\(small.decoderVersion)")
            } else {
                log("loupe decode check      FAILED")
            }
            let viewport = root.loupeController.viewportPixels
            log("loupe viewport          \(viewport.width)×\(viewport.height) px")
            do {
                let frame = try root.loupeController.makeFrame(asset: asset, url: url,
                                                               viewport: viewport, decodeScale: 0.5)
                check("loupe frame \(frame.texture.width)×\(frame.texture.height) matches the viewport",
                      frame.texture.width == viewport.width && frame.texture.height == viewport.height)
                check("loupe decode scale 0.5", frame.decodeScale == 0.5)
                log(String(format: "loupe first frame       decode %.0f ms + render %.1f ms (scale 0.5)",
                           frame.decodeMilliseconds, frame.renderMilliseconds))
                write(texture: frame.texture, name: "ui-smoke-loupe-frame.png")
                if let caps = frame.capabilities {
                    log("loupe decoder            \(caps.summary)")
                }
            } catch {
                fail("loupe render threw: \(error.localizedDescription)")
            }
            // The async path (what the running app does) must also land a frame.
            root.loupeController.autoRenderEnabled = true
            root.loupeController.scheduleRender()
            let deadline = Date().addingTimeInterval(45)
            while root.loupeController.lastFrame == nil && Date() < deadline { pump(0.1) }
            if let frame = root.loupeController.lastFrame {
                log(String(format: "loupe async frame        %.1f ms render, decode cache %@, decode scale %.2f",
                           frame.renderMilliseconds,
                           frame.usedCachedDecode ? "hit" : "miss", frame.decodeScale))
            } else {
                fail("loupe async render produced no frame in 45 s"
                     + (root.loupeController.lastPresentError.map { " (\($0))" } ?? ""))
            }
            capture(window: window, name: "ui-smoke-loupe-window.png")

            // 6. slider → new pixels; undo returns to the previous pixels; menu state follows
            checkInspectorDrivesLoupe(session: session, loupe: root.loupeController,
                                      controller: windowController, window: window)

            // 7. masks: paint on the canvas → undo → reopen → delete (Q22 + Q16 persistence)
            checkMaskEditing(session: session, loupe: root.loupeController,
                             controller: windowController, window: window,
                             asset: asset, url: url)

            // 9. the histogram card + the clipping warning (005f's UI half)
            checkHistogramCard(session: session, loupe: root.loupeController,
                               controller: windowController, window: window,
                               asset: asset, url: url)

            // 10. the six mask shapes, drawn and created through the inspector's own API
            checkMaskShapes(session: session, loupe: root.loupeController,
                            controller: windowController, window: window,
                            asset: asset, url: url)

            // 10b. the mask's own parameters: mask-level + the eleven local sliders, rename, order
            checkMaskParameters(session: session, loupe: root.loupeController,
                                controller: windowController, window: window,
                                asset: asset, url: url)

            // 11. 显示 ▸ 倍率: four stops, ticks, ⌘= / ⌘−, and no document movement
            checkZoomMenu(session: session, loupe: root.loupeController,
                          controller: windowController, window: window,
                          asset: asset, url: url)

            // 8. export sheet + develop presets (M5): real files, one broken source, one undo step
            checkExportAndPresets(session: session, loupe: root.loupeController,
                                  controller: windowController, window: window,
                                  asset: asset, url: url)
        } else {
            fail("no asset for the loupe")
        }

        return finish()
    }

    // MARK: - export sheet + develop presets (M5)

    /// The two M5 surfaces, asserted end to end rather than by inspection:
    ///
    ///   1. **the export sheet** (what 文件 ▸ 导出… opens) writes real files, at the preset's size,
    ///      with the preset's name template — counted on disk and measured by decoding each file;
    ///   2. **one broken photo does not take the batch with it** — its source is overwritten with
    ///      junk (a genuine decode failure, not an injected error), the other two still export, and
    ///      the sheet shows exactly one failure row with a reason;
    ///   3. **applying a preset is one undo step** — the pixel hash moves, the history grows by
    ///      exactly one snapshot *and* one `asset_history` row, and ⌘Z puts the hash back.
    ///
    /// The last check is the menu's promise: with nothing selected, 导出… validates to disabled.
    private func checkExportAndPresets(session: CatalogSession, loupe: LoupeController,
                                       controller: EditorWindowController, window: NSWindow,
                                       asset: Asset, url: URL) {
        let exportDir = screenshotDirectory.appendingPathComponent("ui-smoke-export")
        let brokenDir = screenshotDirectory.appendingPathComponent("ui-smoke-export-broken")
        try? FileManager.default.removeItem(at: exportDir)
        try? FileManager.default.removeItem(at: brokenDir)

        // Photos from the *old* end of the library: the grid's prefetch window never touched them,
        // so overwriting one cannot disturb a thumbnail assertion that ran earlier.
        let pool = session.assets.filter { $0.kind != .raw }
        guard pool.count >= 5 else {
            fail("只有 \(pool.count) 张 JPEG，导出的验收做不了")
            return
        }
        let tail = Array(pool.suffix(5))
        let good = Array(tail.prefix(3))
        let broken = tail[3]

        // MARK: helpers

        func files(in dir: URL) -> [URL] {
            let all = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return all.filter { $0.pathExtension.lowercased() == "jpg" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        func pixelSize(of file: URL) -> ImageSize? {
            guard let src = CGImageSourceCreateWithURL(file as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int,
                  let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return ImageSize(width: w, height: h)
        }
        /// What the file *must* contain: the crop's size scaled by the preset, via the same two
        /// functions `BatchExporter` uses (`ExportSizing`), so the assertion is a forecast, not a
        /// restatement of what was measured.
        func expectedSize(_ asset: Asset, _ preset: ExportPreset) -> ImageSize? {
            guard let w = asset.width, let h = asset.height, w > 0, h > 0,
                  let edit = session.exportItems(for: [asset]).first?.edit else { return nil }
            let native = ImageSize(width: w, height: h)
            let content = CropMath.outputSize(edit.geometry.renderCrop(source: native), in: native)
            return ExportSizing.outputSize(content: content,
                                           scale: preset.renderScale(content: content))
        }
        func waitForExport(_ sheet: ExportSheetController, _ timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while sheet.model.phase != .finished && Date() < deadline { pump(0.1) }
            return sheet.model.phase == .finished
        }
        func sizeText(_ sizes: [ImageSize?]) -> String {
            sizes.map { $0.map { "\($0.width)×\($0.height)" } ?? "?" }.joined(separator: ", ")
        }

        // MARK: 1. three photos → three files at the preset's size

        session.setSelection(Set(good.map(\.id)), anchor: good[0].id)
        controller.showExportSheet()
        pump(0.3)
        guard let sheet = controller.exportSheet else {
            fail("文件 ▸ 导出… 没有开出弹窗")
            return
        }
        check("导出弹窗以窗口 sheet 呈现，并显示“将导出 \(good.count) 张”（selectionCount \(sheet.model.selectionCount)，捕获 \(sheet.items.count) 个条目）",
              window.attachedSheet != nil && window.attachedSheet === sheet.sheetWindow
              && sheet.model.selectionCount == good.count && sheet.items.count == good.count)

        sheet.model.outputDirectory = exportDir
        sheet.model.preset = ExportPreset(name: "Smoke Web", format: .jpeg, longEdge: 512,
                                          quality: 0.85, colorSpace: .sRGB, writeXMP: false,
                                          nameTemplate: "{seq}-{name}")
        let runStarted = CFAbsoluteTimeGetCurrent()
        sheet.runExport()
        let finishedA = waitForExport(sheet, 180)
        let secondsA = CFAbsoluteTimeGetCurrent() - runStarted
        let filesA = files(in: exportDir)
        let sizesA = filesA.map { pixelSize(of: $0) }
        let expectedA = good.map { expectedSize($0, sheet.model.preset) }
        let expectedNames = good.enumerated().map { index, photo in
            String(format: "%04d-%@.jpg", index + 1,
                   (photo.filename as NSString).deletingPathExtension)
        }.sorted()
        let namesA = filesA.map(\.lastPathComponent)
        log(String(format: "export sheet            %d/%d 已写 · %d 个文件 · %.2f s · 尺寸 %@ · 预设 %@ · 报告 %.2f s (p50 %.2f / p95 %.2f)",
                   sheet.model.writtenCount, sheet.model.total, filesA.count, secondsA,
                   sizeText(sizesA), sheet.model.preset.summary,
                   sheet.model.report?.seconds ?? 0,
                   sheet.model.report?.p50 ?? 0, sheet.model.report?.p95 ?? 0))
        check("导出 3 张 → 磁盘多 3 个文件（\(filesA.count)），名字来自 {seq}-{name}（\(namesA.joined(separator: ", "))）",
              finishedA && filesA.count == 3 && namesA == expectedNames
              && sheet.model.writtenCount == 3 && sheet.model.failedCount == 0)
        check("每个文件的像素尺寸 == 预设（实测 \(sizeText(sizesA))，预测 \(sizeText(expectedA))；512 px 长边对 320 px 的源不放大）",
              !expectedA.isEmpty && sizesA.count == expectedA.count
              && zip(sizesA, expectedA).allSatisfy { measured, want in
                  guard let measured, let want else { return false }
                  return measured == want
              })
        check("逐张结果行也报了尺寸与耗时（\(sheet.model.rows.first?.detail ?? "—")），「在 Finder 中显示」拿到的正是这 3 个存在的文件",
              sheet.model.rows.count == 3
              && sheet.model.rows.allSatisfy { $0.detail.contains("×") && $0.detail.contains(" s") }
              && sheet.model.writtenURLs.count == 3
              && sheet.model.writtenURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // MARK: 1b. a real downscale — the 60 MP RAW at long edge 512 must be exactly 512 px

        if let sheetWindow = sheet.sheetWindow {
            // The sheet itself, for a human: three green rows with size + time.
            capture(window: sheetWindow, name: "ui-smoke-export-sheet.png")
        }

        let rawDir = screenshotDirectory.appendingPathComponent("ui-smoke-export-raw")
        try? FileManager.default.removeItem(at: rawDir)
        sheet.dismiss()
        pump(0.2)
        session.selectOnly(asset.id)
        controller.showExportSheet()
        pump(0.3)
        if let rawSheet = controller.exportSheet {
            rawSheet.model.outputDirectory = rawDir
            rawSheet.model.preset = ExportPreset(name: "Smoke 512", format: .jpeg, longEdge: 512,
                                                 quality: 0.9, colorSpace: .sRGB,
                                                 nameTemplate: "{name}")
            rawSheet.runExport()
            let finishedRaw = waitForExport(rawSheet, 300)
            let rawFiles = files(in: rawDir)
            let rawSize = rawFiles.first.flatMap { pixelSize(of: $0) }
            let wantRaw = expectedSize(asset, rawSheet.model.preset)
            log("export raw              \(rawFiles.first?.lastPathComponent ?? "—") \(rawSize.map { "\($0.width)×\($0.height)" } ?? "?") "
                + "预测 \(wantRaw.map { "\($0.width)×\($0.height)" } ?? "?") · \(String(format: "%.2f", rawSheet.model.report?.seconds ?? 0)) s · "
                + "p50 \(String(format: "%.2f", rawSheet.model.report?.p50 ?? 0)) s")
            check("60 MP RAW 按 512 px 长边导出 → \(rawSize.map { "\($0.width)×\($0.height)" } ?? "?")，与预设预测一致（真下采样，不是不放大）",
                  finishedRaw && rawFiles.count == 1 && rawSize == wantRaw
                  && (wantRaw.map { max($0.width, $0.height) } == 512))
            rawSheet.dismiss()
            pump(0.2)
        } else {
            fail("RAW 的导出弹窗没有开出来")
        }

        // MARK: 2. one deliberately broken source → the rest still export, the sheet says why

        if let brokenURL = session.fileURL(for: broken) {
            // Junk bytes under the original name: `CIRAWFilter` cannot open it, so this is the
            // decode-failure path `BatchExporter` is supposed to isolate, not a synthesised throw.
            try? Data(repeating: 0x5A, count: 4096).write(to: brokenURL)
        } else {
            fail("坏图没有文件路径")
        }
        sheet.dismiss()
        pump(0.2)
        session.setSelection(Set([good[0].id, good[1].id, broken.id]), anchor: good[0].id)
        controller.showExportSheet()
        pump(0.3)
        guard let brokenSheet = controller.exportSheet else {
            fail("第二个导出弹窗没有开出来")
            return
        }
        brokenSheet.model.outputDirectory = brokenDir
        brokenSheet.model.preset = ExportPreset(name: "Smoke Thumb", format: .jpeg, longEdge: 160,
                                                quality: 0.8, colorSpace: .sRGB,
                                                nameTemplate: "{name}")
        brokenSheet.runExport()
        let finishedB = waitForExport(brokenSheet, 180)
        let filesB = files(in: brokenDir)
        let sizesB = filesB.map { pixelSize(of: $0) }
        let failureRows = brokenSheet.model.rows.filter(\.isFailure)
        if let brokenWindow = brokenSheet.sheetWindow {
            // The isolation receipt: two green rows, one red with the decode error.
            capture(window: brokenWindow, name: "ui-smoke-export-failed.png")
        }
        log("export broken           \(filesB.count) 个文件 \(sizeText(sizesB)) · \(failureRows.count) 行失败 · "
            + (failureRows.first?.detail ?? "—"))
        check("1 张坏图 → 其余 2 张照旧导出（\(filesB.count) 个文件，尺寸 \(sizeText(sizesB))，长边 160）",
              finishedB && filesB.count == 2
              && sizesB.allSatisfy { $0 == ImageSize(width: 160, height: 120) }
              && brokenSheet.model.writtenCount == 2)
        check("弹窗逐张列结果：\(failureRows.count) 行失败且写明原因（“\(failureRows.first?.detail ?? "—")”），失败的是 \(failureRows.first?.name ?? "—")",
              brokenSheet.model.rows.count == 3 && failureRows.count == 1
              && brokenSheet.model.failedCount == 1
              && failureRows.first?.name == (broken.filename as NSString).deletingPathExtension
              && failureRows.first?.detail.hasPrefix("失败：") == true
              && (failureRows.first?.detail.count ?? 0) > 4)

        // MARK: 3. preset apply = one history step, and ⌘Z takes it back

        loupe.autoRenderEnabled = false
        session.selectOnly(asset.id)
        func pixelHash(_ model: EditModel) -> String? {
            (try? loupe.makeFrame(url: url, viewport: ImageSize(width: 640, height: 420),
                                  decodeScale: 0.5, edit: MaskViewState.documentOnly(model),
                                  state: .fit, hashPixels: true))?.displayHash
        }

        session.applyEdit { $0 = .neutral }
        session.commitEdit(label: "Reset")
        session.applyEdit { $0.light.exposure = 1.2 }
        session.applyEdit { $0.light.contrast = 30 }
        session.commitEdit(label: "Smoke look")
        let created = session.createPresetFromCurrent(named: "Smoke Punch", groups: [.light])
        check("“从当前照片新建预设”落库，面板/菜单读的是同一份缓存（\(session.presetRecords.map(\.name).joined(separator: "、"))）",
              created != nil && session.presetRecords.contains { $0.name == "Smoke Punch" }
              && session.presetRecords.contains { $0.name == "Smoke Punch" && $0.preset.groups == [.light] })

        // The Develop menu rebuilds from the same cache — the card and the menu cannot disagree.
        if let develop = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == "显影" }),
           let presetItem = develop.items.first(where: { $0.submenu is PresetMenu }),
           let presetMenu = presetItem.submenu as? PresetMenu {
            presetMenu.menuNeedsUpdate(presetMenu)
            let titles = presetMenu.items.map(\.title)
            let applied = presetMenu.items.first { $0.title == "Smoke Punch" }
            log("preset menu             \(titles.prefix(6).joined(separator: " · "))")
            check("显影 ▸ 预设 从库里重建，带出“Smoke Punch”并指向应用动作（\(titles.prefix(4).joined(separator: "、"))…）",
                  applied?.action == #selector(EditorWindowController.applyPresetAction(_:))
                  && (applied?.representedObject as? String) == "Smoke Punch"
                  && presetMenu.items.contains { $0.action == #selector(EditorWindowController.newPresetFromCurrentAction(_:)) })
        } else {
            fail("主菜单里没有 显影 ▸ 预设")
        }

        session.applyEdit { $0.light.exposure = 0 }
        session.applyEdit { $0.light.contrast = 0 }
        session.commitEdit(label: "Reset")
        let preApplyHash = pixelHash(session.edit)
        let preApplyDepth = session.history.count
        let preApplyRows = session.lastSaveResult?.historyRows ?? 0
        let applied = session.applyPreset(named: "Smoke Punch")
        let postApplyHash = pixelHash(session.edit)
        let postApplyRows = session.lastSaveResult?.historyRows ?? 0
        log("preset apply            exposure \(String(format: "%.2f", session.edit.light.exposure)) EV · hash "
            + "\(preApplyHash?.prefix(8) ?? "nil")… → \(postApplyHash?.prefix(8) ?? "nil")… · history "
            + "\(preApplyDepth)→\(session.history.count) · asset_history \(preApplyRows)→\(postApplyRows)")
        check("应用预设改像素（hash \(preApplyHash?.prefix(8) ?? "nil")… → \(postApplyHash?.prefix(8) ?? "nil")…），只产生一条开发历史（history +\(session.history.count - preApplyDepth)，asset_history +\(postApplyRows - preApplyRows) 行）",
              applied && preApplyHash != nil && postApplyHash != nil
              && postApplyHash != preApplyHash
              && session.history.count == preApplyDepth + 1
              && postApplyRows == preApplyRows + 1)

        _ = controller.undoEdit()
        let undoneHash = pixelHash(session.edit)
        log("preset undo             hash \(undoneHash?.prefix(16) ?? "nil")… · exposure "
            + "\(String(format: "%.2f", session.edit.light.exposure)) EV · history \(session.history.count)")
        check("⌘Z 撤销预设 → 像素回到应用前（\(undoneHash?.prefix(8) ?? "nil")… == \(preApplyHash?.prefix(8) ?? "nil")…），曝光回到 0",
              undoneHash != nil && undoneHash == preApplyHash && session.edit.light.exposure == 0)

        // MARK: 4. the menu item tells the truth about an empty selection

        brokenSheet.dismiss()
        session.setSelection([])
        if let exportItem = menuItem(#selector(EditorWindowController.exportAction(_:))) {
            let enabledWhenEmpty = controller.validateMenuItem(exportItem)
            session.selectOnly(asset.id)
            let enabledWithSelection = controller.validateMenuItem(exportItem)
            log("export menu             empty → validate=\(enabledWhenEmpty) · 选中 1 张 → validate=\(enabledWithSelection) · title=\(exportItem.title)")
            check("空选中时 文件 ▸ 导出… 置灰，选中后恢复可用",
                  enabledWhenEmpty == false && enabledWithSelection == true)
        } else {
            fail("文件菜单里没有 导出… 项")
        }

        loupe.autoRenderEnabled = true
    }

    // MARK: - grid thumbnails

    /// Prove the grid is drawing thumbnail *pixels* out of `ThumbnailCache`, and that revisiting a
    /// cell costs nothing: no new lookups, only memory hits.
    private func checkGridThumbnails(grid: AssetGridController,
                                     gridView: NSCollectionView,
                                     session: CatalogSession,
                                     loupe: LoupeController,
                                     window: NSWindow) {
        let deadline = Date().addingTimeInterval(40)
        while grid.visibleThumbnailCount < min(8, grid.visibleCellCount), Date() < deadline { pump(0.1) }

        var stats = grid.thumbnailStats
        log("grid thumbnails         \(grid.visibleThumbnailCount)/\(grid.visibleCellCount) visible cells · tier \(grid.currentThumbnailTier.rawValue) · \(stats.summary)")

        check("grid cells show thumbnail images, not placeholders (\(grid.visibleThumbnailCount)/\(grid.visibleCellCount) visible)",
              grid.visibleThumbnailCount > 0 && grid.visibleThumbnailCount >= min(8, grid.visibleCellCount))
        check("thumbnail lookups produced images (\(stats.lookups) lookups, \(stats.applied) applied)",
              stats.lookups >= grid.visibleThumbnailCount && stats.failures == 0)

        // The tier must be the one the layout function implies: cell edge × DPR, clamped to the
        // source. Recomputed here from the applied item size, not from the controller's own field.
        if let first = session.assets.first {
            let expected = ThumbnailProvider.tier(
                cellEdgePoints: max(grid.appliedItemSize.width, grid.appliedItemSize.height),
                backingScale: window.backingScaleFactor,
                sourceLongEdge: ThumbnailProvider.sourceLongEdge(of: first))
            log(String(format: "grid cell               %.0f pt @%.0fx → expected %@, applied %@",
                       max(grid.appliedItemSize.width, grid.appliedItemSize.height),
                       window.backingScaleFactor, expected.rawValue, grid.currentThumbnailTier.rawValue))
            check("grid asks for the tier the cell edge implies (\(grid.currentThumbnailTier.rawValue))",
                  grid.currentThumbnailTier == expected)
        }

        // Re-show every visible cell twice. The first pass may still have to produce the prefetch
        // row (those cells were requested, not yet delivered); the second pass must be pure memory.
        // That is the 006 §7 #1 shape: "scroll once, then scroll again → hitRatio 1.000".
        grid.refresh()
        pump(1.0)
        let warm = grid.thumbnailStats
        grid.refresh()
        pump(0.6)
        stats = grid.thumbnailStats
        let deltaMemory = stats.memoryHits - warm.memoryHits
        let deltaDisk = stats.diskHits - warm.diskHits
        let deltaGenerated = stats.generated - warm.generated
        let deltaLookups = deltaMemory + deltaDisk + deltaGenerated
        let warmHitRatio = deltaLookups == 0 ? 0 : Double(deltaMemory + deltaDisk) / Double(deltaLookups)
        log(String(format: "grid thumbnails (warm)  memory +%d · disk +%d · generated +%d → hit %.3f (session total %.3f, %d requests)",
                   deltaMemory, deltaDisk, deltaGenerated, warmHitRatio, stats.hitRatio, stats.requests))
        check("re-shown cells are memory hits (no new disk reads, no new generations)",
              deltaMemory >= grid.visibleThumbnailCount && deltaDisk == 0 && deltaGenerated == 0)
        check(String(format: "steady-state thumbnail hit rate %.3f == 1.000", warmHitRatio), warmHitRatio >= 0.999)

        // Prefetch is "visible + one row", and anything that scrolls out is cancelled rather than
        // left queued (§5). Two jumps in quick succession, so the first region's loads are still
        // outstanding when the second one lands — that is when cancellation has to happen.
        if let scroll = gridView.enclosingScrollView {
            let before = grid.thumbnailStats
            let height = gridView.collectionViewLayout?.collectionViewContentSize.height ?? 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height * 0.5)))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(0.15)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height * 0.75)))
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(1.4)
            gridView.layoutSubtreeIfNeeded()
            let after = grid.thumbnailStats
            // Terminal outcomes are applied ∪ cancelled ∪ failed; anything else is still queued or
            // running. `cancelled` can overlap `applied` by one runloop when a job finishes just as
            // its cell scrolls away, so this is an upper bound, not an identity.
            let outstanding = max(0, after.requests - after.applied - after.failures)
            let cancelledDelta = after.cancelled - before.cancelled
            log("grid scroll             +\(after.requests - before.requests) requests, +\(cancelledDelta) cancelled, \(outstanding) not-yet-applied, queue \(grid.thumbnailQueueDepth), grid holds \(grid.pendingThumbnailRequests)")
            check("scrolling to a new region issues new thumbnail work", after.requests > before.requests)
            // The contract that actually matters, and it does not depend on how fast the disk is:
            // after the scroll handler runs, the grid holds no work for cells it can no longer see,
            // and the worker queue is bounded by one window rather than by the library.
            check("the grid drops work for cells that scrolled away (0 outside the window, \(grid.pendingThumbnailIndexesOutsideWindow))",
                  grid.pendingThumbnailIndexesOutsideWindow == 0)
            check("the worker queue stays bounded (queue \(grid.thumbnailQueueDepth) ≤ 12, holds \(grid.pendingThumbnailRequests) ≤ 96)",
                  grid.thumbnailQueueDepth <= 12 && grid.pendingThumbnailRequests <= 96)
            // Reported, not asserted: with a warm cache every load can finish before its cell leaves
            // the window, in which case there is genuinely nothing to cancel. The invariant above is
            // what must hold either way.
            // Back to the top so the screenshots that follow show the first row.
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            pump(0.4)
        }

        // A slider move while the grid is on screen must not render anything: the loupe is not
        // visible, so the debounced renderer has to stay asleep (and the document must still change).
        let rendersBefore = loupe.editRenderCount
        session.applyEdit { $0.light.contrast = 6 }
        pump(0.35)
        check("a slider move with the loupe closed renders nothing (\(loupe.editRenderCount) renders)",
              loupe.editRenderCount == rendersBefore && session.edit.light.contrast == 6)
        session.applyEdit { $0.light.contrast = 0 }
    }

    // MARK: - rating / flag / colour label + filter bar

    /// The rating UI, asserted on the **database** and on what the cell actually painted.
    ///
    /// Seven things this pins:
    ///   1. a real key event ("3") through `AssetCollectionView.keyDown` writes `assets.rating`;
    ///   2. the cell draws the badge — `lastDrawnBadges` read back after a real `display()`, not
    ///      inferred from `asset.rating`;
    ///   3. five selected photos + one "P" is **one** transaction and five rows;
    ///   4. ⌥3 writes a colour label, and the badge shows it next to the stars;
    ///   5. "≥3 星" narrows the grid to exactly the rows the same query returns, with a chip;
    ///   6. clicking the chip clears that facet and the library comes back;
    ///   7. a rating is metadata, not an edit: history does not grow, `editRevision` does not move,
    ///      and ⌘Z is grey (and a no-op if forced) because of it.
    private func checkRatingAndFilter(session: CatalogSession, grid: AssetGridController,
                                      gridView: NSCollectionView, controller: EditorWindowController,
                                      window: NSWindow) {
        guard let reader = try? Catalog.open(at: libraryURL) else {
            fail("could not open the library a second time to read the metadata back")
            return
        }
        let rowsBefore = session.assets.count
        let historyBefore = session.history.count
        let revisionBefore = session.editRevision
        let canUndoBefore = session.canUndo
        guard let target = session.anchorAsset ?? session.assets.first else {
            fail("no anchor photo to rate")
            return
        }
        session.selectOnly(target.id)
        pump(0.2)

        // 3c.1 — "3" through the shipped key path (grid keyDown → RatingShortcuts → session).
        let writesBefore = session.metadataWriteCount
        let known = press("3", in: gridView, window: window)
        let storedAsset: Asset? = try? reader.asset(id: target.id)
        let storedRating = storedAsset?.rating ?? -1
        let modelRating = session.assets.first(where: { $0.id == target.id })?.rating ?? -1
        log("rating key             “3” recognised=\(known) → db \(storedRating), model \(modelRating), \(session.metadataWriteCount - writesBefore) transaction(s), \(session.lastMetadataAffectedRows) row(s)")
        check("按 “3” 写库：assets.rating 读回 \(storedRating) == 3，模型里也是 \(modelRating)",
              known && storedRating == 3 && modelRating == 3)

        // 3c.2 — the badge on the cell that is on screen (draw, then read what it painted).
        grid.showAnchor()
        pump(0.25)
        gridView.layoutSubtreeIfNeeded()
        let ratedCell = grid.visibleItem(forAssetID: target.id)
        ratedCell?.cardView.display()
        let ratedDrawn = ratedCell?.cardView.lastDrawnBadges ?? []
        let ratedSignature = ratedCell?.cardView.badgeSignature ?? "no cell"
        log("badge                  \(target.filename) → “\(ratedSignature)”, painted \(ratedDrawn)")
        check("角标画出：格子上 3 颗星（painted \(ratedDrawn)，签名 “\(ratedSignature)”）",
              ratedDrawn.contains("stars:3") && ratedSignature.contains("★3"))

        // 3c.3 — five photos, one "P", one transaction, five rows.
        let batch = Array(session.assets.prefix(5))
        session.setSelection(Set(batch.map(\.id)), anchor: batch.first?.id)
        pump(0.2)
        let writesBeforeFlag = session.metadataWriteCount
        _ = press("p", in: gridView, window: window)
        let batchRows: [Asset] = batch.compactMap { try? reader.asset(id: $0.id) }
        let picked = batchRows.filter { $0.flag == "pick" }.count
        let transactions = session.metadataWriteCount - writesBeforeFlag
        log("flag P                 \(batch.count) selected → \(picked) rows flag=pick, \(transactions) batch write, db.changesCount \(session.lastMetadataAffectedRows)")
        check("多选 \(batch.count) 张按 P：\(picked) 行 flag=pick，一次按键只写 \(transactions) 遍事务（db 变更 \(session.lastMetadataAffectedRows) 行）",
              picked == batch.count && transactions == 1
              && session.lastMetadataAffectedRows == batch.count)

        // 3c.4 — ⌥3 (yellow), same selection, and the badge is stars + colour together.
        _ = press("3", option: true, in: gridView, window: window)
        let labelled = batch.compactMap { (try? reader.asset(id: $0.id)) as Asset? }
            .filter { $0.colorLabel == "yellow" }.count
        let firstCell = batch.first.flatMap { grid.visibleItem(forAssetID: $0.id) }
        firstCell?.cardView.display()
        let comboDrawn = firstCell?.cardView.lastDrawnBadges ?? []
        // Not just "draw() was called": render the card and look for the label's own colour in the
        // corner where the dot is painted. A badge that is computed but invisible fails here.
        let dotPainted = firstCell.map { badgeDotPresent(in: $0.cardView, label: .yellow) } ?? false
        log("colour ⌥3              \(labelled)/\(batch.count) rows color_label=yellow, badge \(comboDrawn), dot painted=\(dotPainted)")
        check("⌥3 给 \(batch.count) 张写色标 yellow（\(labelled) 行），角标画星级 + 旗标 + 色标（\(comboDrawn)，色点像素 \(dotPainted)）",
              labelled == batch.count && comboDrawn.contains("color:yellow")
              && comboDrawn.contains("flag:pick") && dotPainted)

        // 3c.5 — "≥3 星": the grid narrows to the rows the same query returns, and says so in a chip.
        let queryRows = (try? reader.assets(AssetFilter(ratingAtLeast: 3, limit: 200_000)).count) ?? -1
        session.applyFilter(CatalogFilter(ratingAtLeast: 3))
        pump(0.4)
        gridView.layoutSubtreeIfNeeded()
        grid.filterBar.layoutSubtreeIfNeeded()
        let filteredRows = session.assets.count
        let filteredItems = gridView.numberOfItems(inSection: 0)
        let allQualify = session.assets.allSatisfy { $0.rating >= 3 }
        let chipCount = grid.filterBar.chipCount
        let chip = grid.filterBar.chipText(0) ?? "-"
        log("filter ≥3 star         query \(queryRows) rows, grid \(filteredRows) rows / \(filteredItems) items, chips \(chipCount) “\(chip)”")
        check("筛选“≥3 星”后网格只剩达标项（查询 \(queryRows) 行 = 网格 \(filteredRows) 行 = collectionView \(filteredItems) 项，且全部 rating≥3：\(allQualify)）",
              queryRows > 0 && filteredRows == queryRows && filteredItems == filteredRows
              && filteredRows < rowsBefore && allQualify)
        check("筛选条件显示成可清除的 chip（\(chipCount) 个，第一个 “\(chip)” 对应星级）",
              chipCount == 1 && grid.filterBar.chipFacet(0) == .rating && chip.contains("3"))

        // 3c.6 — another photo does not widen the filter (it lives in the session, not the selection).
        if let otherID = session.assets.last?.id {
            session.selectOnly(otherID)
            pump(0.2)
        }
        check("切换照片时筛选不变（仍 \(session.assets.count) 行，\(session.filter.summary)，anchor \(session.anchorID?.prefix(8) ?? "nil")…）",
              session.filter.ratingAtLeast == 3 && session.assets.count == filteredRows)

        // 3c.7 — clicking the chip clears that facet, exactly like a user would.
        var cleared = false
        if let rect = grid.filterBar.chipRect(0),
           let event = mouseDownEvent(in: grid.filterBar,
                                      at: NSPoint(x: rect.midX, y: rect.midY), window: window) {
            grid.filterBar.mouseDown(with: event)
            pump(0.4)
            cleared = session.filter == .none && session.assets.count == rowsBefore
        }
        log("filter chip click      cleared=\(cleared) → \(session.assets.count)/\(rowsBefore) rows, chips \(grid.filterBar.chipCount), grid items \(gridView.numberOfItems(inSection: 0))")
        check("点 chip 清筛选：库回到 \(rowsBefore) 行、chip 清空（\(grid.filterBar.chipCount) 个），collectionView \(gridView.numberOfItems(inSection: 0)) 项",
              cleared && grid.filterBar.chipCount == 0
              && gridView.numberOfItems(inSection: 0) == rowsBefore)

        // 3c.8 — metadata, not an edit: no snapshot, no revision bump, no undo entry.
        session.selectOnly(target.id)
        pump(0.15)
        let undoItem = menuItem(#selector(EditorWindowController.undoAction(_:)))
        let undoValidated = undoItem.map { controller.validateMenuItem($0) } ?? true
        let ratingBeforeUndo: Int = (try? reader.asset(id: target.id)).map { $0?.rating ?? -1 } ?? -1
        let undone = controller.undoEdit()
        let ratingAfterUndo: Int = (try? reader.asset(id: target.id)).map { $0?.rating ?? -1 } ?? -1
        log("rating vs history      history \(historyBefore)→\(session.history.count), editRevision +\(session.editRevision - revisionBefore), canUndo \(canUndoBefore)→\(session.canUndo), undo validates=\(undoValidated), ⌘Z applied=\(undone), rating \(ratingBeforeUndo)→\(ratingAfterUndo)")
        check("评级不产生开发历史（history 仍为 \(session.history.count)，editRevision 不动 +\(session.editRevision - revisionBefore)，canUndo 不变）",
              session.history.count == historyBefore && session.editRevision == revisionBefore
              && session.canUndo == canUndoBefore)
        check("⌘Z 不撤销评级（菜单 validate=\(undoValidated)、undo() 返回 \(undone)，库内 rating 仍 \(ratingAfterUndo)）",
              undone == false && ratingAfterUndo == 3 && !undoValidated)

        capture(window: window, name: "ui-smoke-filter.png")
    }

    /// Render the card and look for the colour-label dot's own colour in the corner it is painted in.
    ///
    /// `lastDrawnBadges` proves the badge code ran; this proves a pixel changed. The search is
    /// confined to the 22 × 20 pt box at the swatch's top-right where `AssetBadges.drawColorDot`
    /// paints, so a yellowish photo underneath cannot pass for the dot. The match is in HSB, not
    /// RGB: the card is rendered through the display's colour profile, so the dot's blue channel
    /// comes back lifted (0.40 for a 0.20 dot) while its hue and saturation stay put.
    private func badgeDotPresent(in card: AssetCardView, label: ColorLabel) -> Bool {
        let rect = card.bounds
        guard rect.width > 40, rect.height > 40,
              let rep = card.bitmapImageRepForCachingDisplay(in: rect) else { return false }
        card.cacheDisplay(in: rect, to: rep)
        let targetColor = label.color.usingColorSpace(.sRGB) ?? label.color
        var tHue: CGFloat = 0, tSat: CGFloat = 0, tBri: CGFloat = 0, tAlpha: CGFloat = 0
        targetColor.getHue(&tHue, saturation: &tSat, brightness: &tBri, alpha: &tAlpha)
        let sx = CGFloat(rep.pixelsWide) / max(1, rect.width)
        let sy = CGFloat(rep.pixelsHigh) / max(1, rect.height)
        // The card is flipped, so `minY` is the top edge and the dot sits at (maxX - 14, minY + 5).
        let box = NSRect(x: rect.maxX - 22, y: rect.minY + 1, width: 20, height: 18)
        guard box.maxX <= rect.width, box.maxY <= rect.height else { return false }
        for py in Int(box.minY * sy)..<Int(box.maxY * sy) {
            for px in Int(box.minX * sx)..<Int(box.maxX * sx) {
                guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
                var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
                c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
                let hueDelta = min(abs(hue - tHue), 1 - abs(hue - tHue))
                if hueDelta < 0.06, abs(sat - tSat) < 0.30, abs(bri - tBri) < 0.20 {
                    return true
                }
            }
        }
        return false
    }

    /// Post one key down into a view's own `keyDown` — the shipped path, not a call into the model.
    /// Returns whether the shared rating table recognises the event (the *effect* is asserted after).
    @discardableResult
    private func press(_ key: String, option: Bool = false, in view: NSView, window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: option ? [.option] : [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: key, charactersIgnoringModifiers: key,
                                           isARepeat: false, keyCode: 0) else { return false }
        view.keyDown(with: event)
        pump(0.2)
        return RatingShortcuts.command(for: event) != nil
    }

    private func mouseDownEvent(in view: NSView, at point: NSPoint, window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(with: .leftMouseDown, location: view.convert(point, to: nil),
                           modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)
    }

    // MARK: - filmstrip thumbnails

    /// The strip must draw the same kind of *pixels* the grid does — not the hash swatch — and it
    /// must ask for the tier its 74 × 50 pt cell implies at this DPR (006 §1).
    ///
    /// "Every visible cell" is asserted twice: once for the screenful the strip opens on, and once
    /// over a sweep of pages (the union of cells that were visible while scrolling), so a cell that
    /// only renders when it is the first one cannot pass. The sweep needs ≥ 36 distinct cells —
    /// more than any single screenful — which is why the number is a union, not a viewport count.
    private func checkFilmstripThumbnails(controller: FilmstripController,
                                          session: CatalogSession,
                                          window: NSWindow) {
        let strip = controller.collectionView
        let deadline = Date().addingTimeInterval(40)
        while controller.visibleThumbnailCount < controller.visibleCellCount, Date() < deadline { pump(0.1) }

        var stats = controller.thumbnailStats
        log("filmstrip thumbnails    \(controller.visibleThumbnailCount)/\(controller.visibleCellCount) visible cells · tier \(controller.currentThumbnailTier.rawValue) · \(stats.summary)")

        check("filmstrip cells show thumbnail images, not placeholders (\(controller.visibleThumbnailCount)/\(controller.visibleCellCount) visible)",
              controller.visibleCellCount > 0
              && controller.visibleThumbnailCount == controller.visibleCellCount)

        if let first = session.assets.first {
            let edge = max(WorkspaceLayout.filmstripCell.width, WorkspaceLayout.filmstripCell.height)
            let requested = ThumbnailProvider.tier(cellEdgePoints: edge,
                                                   backingScale: window.backingScaleFactor,
                                                   sourceLongEdge: ThumbnailProvider.sourceLongEdge(of: first))
            let expected = ThumbnailProvider.effectiveTier(requested: requested, ext: first.ext).tier
            log(String(format: "filmstrip cell          %.0f×%.0f pt @%.0fx → expected %@, applied %@",
                       WorkspaceLayout.filmstripCell.width, WorkspaceLayout.filmstripCell.height,
                       window.backingScaleFactor, expected.rawValue, controller.currentThumbnailTier.rawValue))
            check("filmstrip asks for the tier its cell implies (\(controller.currentThumbnailTier.rawValue))",
                  controller.currentThumbnailTier == expected)
        }

        // Sweep: pages of the same width, two pages apart so each page shows fresh cells.
        var seen = Set<Int>()
        var imaged = Set<Int>()
        let items = strip.numberOfItems(inSection: 0)
        let stride = max(1, controller.visibleCellCount) * 2
        var start = 0
        var pages = 0
        while pages < 6, start < items, seen.count < 36 {
            strip.scrollToItems(at: [IndexPath(item: start, section: 0)], scrollPosition: .left)
            pump(0.2)
            strip.layoutSubtreeIfNeeded()
            let pageDeadline = Date().addingTimeInterval(12)
            while controller.visibleThumbnailCount < controller.visibleCellCount, Date() < pageDeadline { pump(0.1) }
            for path in strip.indexPathsForVisibleItems() {
                seen.insert(path.item)
                if let cell = strip.item(at: path) as? FilmstripCell, cell.cardView.thumbnail != nil {
                    imaged.insert(path.item)
                }
            }
            pages += 1
            start += stride
        }
        let missing = seen.subtracting(imaged).sorted()
        log("filmstrip sweep         \(imaged.count)/\(seen.count) cells over \(pages) pages have images"
            + (missing.isEmpty ? "" : " · missing \(missing.prefix(8))"))
        check("every filmstrip cell the sweep showed has an image (\(imaged.count)/\(seen.count), ≥ 36)",
              !seen.isEmpty && seen.count >= 36 && missing.isEmpty && imaged.count == seen.count)

        // Nothing for cells that are no longer visible or in the one-cell slack band (§5).
        pump(0.3)
        check("the filmstrip drops work for cells that scrolled away (0 outside the window, \(controller.pendingThumbnailIndexesOutsideWindow))",
              controller.pendingThumbnailIndexesOutsideWindow == 0)

        // Back to the first cell so the screenshot shows the same place the grid does.
        strip.scrollToItems(at: [IndexPath(item: 0, section: 0)], scrollPosition: .left)
        pump(0.3)
        stats = controller.thumbnailStats
        log("filmstrip thumbnails    \(stats.summary) · queue \(controller.thumbnailProviderForSmoke?.queueDepth ?? 0)")
    }

    // MARK: - one service, one LRU

    /// The point of collapsing the two queues: the grid and the strip are *clients of the same
    /// `ThumbnailService`*, so a `contentHash` the grid already rendered is one disk/memory hit for
    /// the strip, never a second producer run (006 §4 单飞, §3 content addressing).
    private func checkSharedThumbnailService(grid: AssetGridController,
                                            strip: FilmstripController,
                                            session: CatalogSession) {
        guard let gridProvider = grid.thumbnailProviderForSmoke,
              let stripProvider = strip.thumbnailProviderForSmoke else {
            fail("no thumbnail provider to inspect")
            return
        }
        check("the grid and the filmstrip share one ThumbnailProvider (one service, one memory LRU)",
              gridProvider === stripProvider)

        let provider = gridProvider
        let stats = provider.stats
        let runsPerKey = provider.generationCounts
        let runsPerContent = provider.generationsPerContent
        let runs = runsPerKey.values.reduce(0, +)
        let maxPerKey = runsPerKey.values.max() ?? 0
        let service = provider.serviceStats
        log("thumbnail service       \(ThumbServiceReport(service).summaryLine)")
        log("thumbnail queue         \(ThumbServiceReport(service).queueLine)")
        log("thumbnail producer      \(runs) runs over \(runsPerKey.count) keys / \(runsPerContent.count) contentHashes · max \(maxPerKey)/key · dropped in flight \(service.cancelledInFlight) · \(stats.skipSummary)")

        // §5: a cancelled job's bytes are dropped, so the *next* request for that key is a genuine
        // miss. Every extra producer run is therefore explained by a discarded in-flight job —
        // "one key, one generated file" holds with that correction, and not shakily so.
        let extraRuns = runs - runsPerKey.count
        // A fully warm cache (the previous smoke run left every tier on disk) legitimately
        // generates nothing — `0 keys` is not a failure, it is the steady state. Assert the
        // invariant that still means something in that case: everything came from a cache.
        if runsPerKey.isEmpty {
            check("warm cache: nothing regenerated and the grid+filmstrip hit cache (\(stats.hitRatio.formatted(.number.precision(.fractionLength(3)))) hit ratio)",
                  stats.hitRatio >= 0.999)
        } else {
            check("no cache key was generated twice across grid + filmstrip (\(runsPerKey.count) keys, \(runs) producer runs, \(extraRuns) extra = \(service.cancelledInFlight) dropped in flight)",
                  extraRuns >= 0 && extraRuns <= service.cancelledInFlight)
        }

        // The literal single-flight case, driven through both views' code path: one cold asset,
        // asked for twice before either request can complete, at the tier both views agree on.
        // Two subscriptions, one job, one producer run — and `coalesced` says so.
        if let cold = coldAsset(session: session, provider: provider, tier: strip.currentThumbnailTier) {
            let appliedBefore = provider.stats.applied
            let coalescedBefore = provider.serviceStats.coalesced
            let runsBefore = provider.generationsPerContent[cold.asset.contentHash] ?? 0
            let fromGrid = provider.request(index: 0, asset: cold.asset, fileURL: cold.url,
                                            tier: strip.currentThumbnailTier) { _, _, _ in }
            let fromStrip = provider.request(index: 1, asset: cold.asset, fileURL: cold.url,
                                             tier: strip.currentThumbnailTier) { _, _, _ in }
            let deadline = Date().addingTimeInterval(20)
            while provider.stats.applied < appliedBefore + 2, Date() < deadline { pump(0.05) }
            let after = provider.serviceStats
            let runsAfter = provider.generationsPerContent[cold.asset.contentHash] ?? 0
            log("single flight           \(cold.asset.filename) @ \(cold.key.tier.rawValue) asked by grid + filmstrip → "
                + "\(runsAfter - runsBefore) generation(s), coalesced +\(after.coalesced - coalescedBefore), "
                + "\(provider.stats.applied - appliedBefore) delivery(ies)")
            check("grid + filmstrip asking for one contentHash/tier share one job (1 generation, \(runsAfter - runsBefore) run(s), coalesced +\(after.coalesced - coalescedBefore))",
                  fromGrid.key == fromStrip.key
                  && runsAfter - runsBefore == 1
                  && after.coalesced > coalescedBefore
                  && provider.stats.applied >= appliedBefore + 2)
        }

        // Re-asking from the *other* view must be a memory hit: no disk read, no producer run.
        if let first = session.assets.first, let url = session.fileURL(for: first) {
            let before = provider.stats
            _ = provider.request(index: -2, asset: first, fileURL: url,
                                 tier: strip.currentThumbnailTier) { _, _, _ in }
            pump(0.2)
            let after = provider.stats
            check("re-asking the filmstrip's key serves it from the shared memory LRU (memory \(before.memoryHits)→\(after.memoryHits), generated \(before.generated)→\(after.generated))",
                  after.memoryHits == before.memoryHits + 1 && after.generated == before.generated
                  && after.diskHits == before.diskHits)
        }
    }

    /// An asset neither view has touched yet: no generation recorded for its key, nothing on disk.
    /// Picked from deep inside the library so neither the grid's prefetch window nor the strip's
    /// sweep could have reached it.
    private func coldAsset(session: CatalogSession,
                           provider: ThumbnailProvider,
                           tier: ThumbTier) -> (asset: Asset, url: URL, key: ThumbKey)? {
        let generated = provider.generationCounts
        var index = 200
        while index < session.assets.count {
            if let asset = session.assets[safe: index] {
                let key = ThumbKey.preview(contentHash: asset.contentHash, tier: tier)
                if generated[key.digest] == nil, !provider.cache.peek(key),
                   let url = session.fileURL(for: asset) {
                    return (asset, url, key)
                }
            }
            index += 37
        }
        return nil
    }

    // MARK: - §6.1 DNG ceiling

    /// `ThumbPolicy.dngPreviewMaxTier` was dead code: nothing consulted it, so a DNG asked for
    /// `t1024` would have been served an Adobe-rendered embedded preview far above the tier that
    /// policy trusts (§6.1: "不允许用 Adobe 的观感充当我们的首屏大图"). Now the request path
    /// downgrades and *counts* the downgrade, and the file that would have been the lie is absent.
    private func checkDNGCeiling(session: CatalogSession, grid: AssetGridController) {
        guard let provider = grid.thumbnailProviderForSmoke else {
            fail("no thumbnail provider for the DNG ceiling probe")
            return
        }
        let asked = ThumbnailProvider.effectiveTier(requested: .t1024, ext: "dng")
        let atLimit = ThumbnailProvider.effectiveTier(requested: .t512, ext: "dng")
        let other = ThumbnailProvider.effectiveTier(requested: .t1024, ext: "arw")
        check("DNG preview ceiling is t512 (t1024 → \(asked.tier.rawValue) \(asked.skipReason ?? "-"), t512 → \(atLimit.tier.rawValue) \(atLimit.skipReason ?? "-"), arw t1024 → \(other.tier.rawValue))",
              asked.tier == .t512 && asked.skipReason == "dngCeiling"
              && atLimit.tier == .t512 && atLimit.skipReason == nil
              && other.tier == .t1024 && other.skipReason == nil)

        guard let dng = session.assets.first(where: { $0.ext.lowercased() == "dng" }) else {
            log("dng ceiling             no DNG in this library — the policy is asserted, the request path is not")
            return
        }
        let before = provider.stats.skipReasons["dngCeiling"] ?? 0
        let token = provider.request(index: -1, asset: dng,
                                     fileURL: session.fileURL(for: dng), tier: .t1024) { _, _, _ in }
        pump(0.3)
        let after = provider.stats.skipReasons["dngCeiling"] ?? 0
        let aboveLadder = ThumbKey.preview(contentHash: dng.contentHash, tier: .t1024)
        let onDisk = provider.cache.peek(aboveLadder)
        log("dng ceiling             \(dng.filename) asked t1024 → \(token.key.tier.rawValue) · skipReason=dngCeiling ×\(after) · t1024 on disk \(onDisk ? "YES" : "no")")
        check("a t1024 DNG request is downgraded to t512 and recorded as skipReason=dngCeiling (\(after) so far)",
              token.key.tier == .t512 && after == before + 1)
        check("no t1024 preview file was written for the DNG (\(dng.filename))", onDisk == false)
    }

    // MARK: - slider → frame → undo

    /// The measurement the milestone is actually about: does moving a slider change the *pixels*,
    /// and does ⌘Z put the previous pixels back?
    ///
    /// Three independent things are asserted:
    /// 1. the debounce/single-flight discipline (N ticks must not become N renders),
    /// 2. the frame hash moves with the document and comes back on undo — a real `RenderGraph`
    ///    output hash of the presented texture, not "a frame arrived",
    /// 3. the ⌘Z/⇧⌘Z menu items grey out when the history has nothing to undo.
    private func checkInspectorDrivesLoupe(session: CatalogSession,
                                           loupe: LoupeController,
                                           controller: EditorWindowController,
                                           window: NSWindow) {
        let undoItem = menuItem(#selector(EditorWindowController.undoAction(_:)))
        let redoItem = menuItem(#selector(EditorWindowController.redoAction(_:)))
        guard let undoItem, let redoItem else {
            fail("the Edit menu has no 撤销/重做 items")
            return
        }
        NSApp.mainMenu?.update()
        // A nil-target item is enabled iff AppKit resolves a responder that validates true; that
        // resolution needs a *key* window, and a harness launched from a shell cannot take key focus
        // (logged below). So the assertion is the pair that actually decides the grey-out: the window
        // controller implements the action (it is the chain's target) and its validation says no.
        window.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        pump(0.15)
        NSApp.mainMenu?.update()
        let undoTarget = NSApp.target(forAction: undoItem.action!, to: nil, from: undoItem)
        let undoValidated = controller.validateMenuItem(undoItem)
        log("undo menu               key=\(window.isKeyWindow) target=\(undoTarget.map { String(describing: type(of: $0)) } ?? "nil") validate=\(undoValidated) enabled=\(undoItem.isEnabled) title=\(undoItem.title)")
        check("the window controller is the undo responder and answers the item’s action",
              controller.responds(to: undoItem.action!))
        check("undo menu validates to disabled with an empty history", undoValidated == false)
        check("redo menu validates to disabled with an empty history",
              controller.validateMenuItem(redoItem) == false)

        // The loupe must have settled on the full-resolution decode before hashes are comparable.
        let settle = Date().addingTimeInterval(45)
        while (loupe.lastFrame?.decodeScale ?? 0) < 1.0 && Date() < settle { pump(0.1) }
        log(String(format: "loupe settled           decode scale %.2f, history depth %d",
                   loupe.lastFrame?.decodeScale ?? 0, session.history.count))

        // Baseline: re-render the untouched document through the same debounced path, so the hash
        // we compare against is a *presented* frame and not a side render.
        loupe.hashesFrames = true
        let baseCount = loupe.editRenderCount
        loupe.requestEditRender()
        _ = waitForFrame(loupe, after: baseCount, timeout: 30)
        guard let baselineHash = loupe.lastFrame?.displayHash else {
            fail("loupe produced no hashable baseline frame")
            loupe.hashesFrames = false
            return
        }
        log("loupe baseline hash     \(baselineHash.prefix(16))…")

        // A drag: ten ticks ~12 ms apart, then one commit on release (one history snapshot).
        let dragStart = loupe.editRenderCount
        for tick in 1...10 {
            session.applyEdit { $0.light.exposure = 0.1 * Double(tick) }
            pump(0.012)
        }
        session.commitEdit()
        _ = waitForFrame(loupe, after: dragStart, timeout: 30)
        let editedHash = loupe.lastFrame?.displayHash
        let renderCountAfterDrag = loupe.editRenderCount - dragStart
        log("loupe edited hash       \(editedHash?.prefix(16) ?? "nil")…  exposure \(String(format: "%.2f", session.edit.light.exposure)) EV")
        check("slider drag changed the loupe pixels (hash \(baselineHash.prefix(8))… → \(editedHash?.prefix(8) ?? "nil")…)",
              editedHash != nil && editedHash != baselineHash)
        check("10 ticks in one drag → \(renderCountAfterDrag) render(s), not 10 (50 ms debounce)",
              renderCountAfterDrag >= 1 && renderCountAfterDrag <= 4)
        check("one commit produced one history snapshot (depth \(session.history.count))",
              session.history.count == 2 && session.canUndo)

        NSApp.mainMenu?.update()
        check("undo menu enabled after a commit, titled “\(undoItem.title)”",
              controller.validateMenuItem(undoItem) && undoItem.isEnabled)

        // ⌘Z: the pixels must return to the pre-drag frame, not merely "a new frame".
        let beforeUndo = loupe.editRenderCount
        let undid = controller.undoEdit()
        _ = waitForFrame(loupe, after: beforeUndo, timeout: 30)
        let undoneHash = loupe.lastFrame?.displayHash
        log("loupe undo hash         \(undoneHash?.prefix(16) ?? "nil")…")
        check("⌘Z restored the document", undid && session.edit.light.exposure == 0)
        check("undo returned the loupe to the previous pixels (hash \(undoneHash?.prefix(8) ?? "nil")…)",
              undoneHash != nil && undoneHash == baselineHash)

        NSApp.mainMenu?.update()
        check("redo menu enabled after undo, titled “\(redoItem.title)”",
              controller.validateMenuItem(redoItem) && redoItem.isEnabled)

        // ⇧⌘Z: forward again, same pixels as the edited frame.
        let beforeRedo = loupe.editRenderCount
        let redid = controller.redoEdit()
        _ = waitForFrame(loupe, after: beforeRedo, timeout: 30)
        let redoneHash = loupe.lastFrame?.displayHash
        log("loupe redo hash         \(redoneHash?.prefix(16) ?? "nil")…")
        check("⇧⌘Z re-applied the edit and the loupe pixels match the edited frame",
              redid && redoneHash != nil && redoneHash == editedHash)

        // Single-flight under a burst: 20 ticks inside ~80 ms must not become 20 renders.
        loupe.hashesFrames = false
        let burstStart = loupe.editRenderCount
        for tick in 0..<20 {
            session.applyEdit { $0.light.contrast = Double(tick + 1) }
            pump(0.004)
        }
        session.commitEdit()
        _ = waitForFrame(loupe, after: burstStart, timeout: 30)
        let burstRenders = loupe.editRenderCount - burstStart
        check("20 ticks in a burst → \(burstRenders) render(s) (debounce + single-flight)",
              burstRenders >= 1 && burstRenders <= 4)

        // Four more short gestures so p50/p95 have more than one sample per gesture.
        for gesture in 0..<4 {
            let start = loupe.editRenderCount
            for tick in 1...5 {
                session.applyEdit { $0.light.shadows = Double(tick + gesture) }
                pump(0.010)
            }
            session.commitEdit()
            _ = waitForFrame(loupe, after: start, timeout: 20)
        }

        let p = loupe.editLatencyPercentiles()
        log(String(format: "slider→frame           p50 %.1f ms  p95 %.1f ms  (n=%d, debounce %.0f ms, single-flight, %d coalesced)",
                   p.p50, p.p95, p.count, loupe.debounceInterval * 1000, loupe.editRenderCoalesced))
        check(String(format: "slider→frame latency measured (p50 %.1f ms / p95 %.1f ms, n=%d)", p.p50, p.p95, p.count),
              p.count >= 5 && p.p50 > 0 && p.p95 < 1000)

        capture(window: window, name: "ui-smoke-loupe-edited.png")
    }

    /// Pump the runloop until `loupe.editRenderCount` has passed `count` and then stopped moving for
    /// ~150 ms (a coalesced follow-up render has landed).
    @discardableResult
    private func waitForFrame(_ loupe: LoupeController, after count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last = loupe.editRenderCount
        var stable = 0
        while Date() < deadline {
            pump(0.05)
            let now = loupe.editRenderCount
            if now != last {
                last = now
                stable = 0
            } else if now > count {
                stable += 1
                if stable >= 3 { return true }
            }
        }
        return loupe.editRenderCount > count
    }

    private func menuItem(_ action: Selector) -> NSMenuItem? {
        func find(in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.action == action { return item }
                if let sub = item.submenu, let hit = find(in: sub) { return hit }
            }
            return nil
        }
        return find(in: NSApp.mainMenu)
    }

    // MARK: - masks: paint → undo → reopen → delete (Q22, Q16)

    /// The mask UI, asserted on real `RenderGraph` pixels rather than on a screenshot.
    ///
    /// "Coverage" here is measured, not asserted from a formula: the frame is rendered twice — once
    /// with `showMaskID` set and once without — and the pixels that differ **are** the mask. The
    /// overlay reads the atlas slice S1.6 consumed (`s4_show_mask.metal`), so a nonzero coverage
    /// means the atlas has a selection, i.e. a real stroke reached the document.
    ///
    /// The four behaviours this pins:
    ///   1. one gesture = one stroke = one snapshot, sampled by distance (fewer points than events);
    ///   2. ⌘Z returns to the pre-stroke frame and keeps the overlay (the QUEUE 第 5 轮 #1 conflict);
    ///   3. toggling 显示蒙版 grows neither the history nor a database write (view state, not an edit);
    ///   4. close/reopen of the same library reproduces the masked frame's hash, and deleting the
    ///      mask returns to the frame without it.
    private func checkMaskEditing(session: CatalogSession, loupe: LoupeController,
                                  controller: EditorWindowController, window: NSWindow,
                                  asset: Asset, url: URL) {
        // 7.0 — the pure half of the showMask fix, with no window and no GPU in the way.
        let pureMask = Mask(id: "m-pure", name: "pure")
        var pureDoc = EditModel(masks: [pureMask])
        pureDoc.showMaskID = pureMask.id
        let stripped = MaskViewState.documentOnly(pureDoc)
        check("showMask 是视图态：快照剥掉它、恢复时贴回、只差叠加的两个文档仍是同一个文档",
              stripped.showMaskID == nil
              && MaskViewState.restoring(stripped, keeping: pureMask.id).showMaskID == pureMask.id
              && MaskViewState.overlayIsViewState(pureDoc, stripped)
              && !MaskViewState.overlayIsViewState(pureDoc, EditModel()))

        // 7.1 — one known document, one fixed frame size. `autoRenderEnabled` goes off so the
        // debounced path cannot race the synchronous frames below.
        loupe.autoRenderEnabled = false
        session.maskTool = .off
        session.applyEdit { $0 = .neutral }
        session.commitEdit(label: "Reset")
        let viewport = ImageSize(width: 720, height: 480)

        func frame(_ edit: EditModel) -> LoupeController.FrameResult? {
            do {
                return try loupe.makeFrame(url: url, viewport: viewport, decodeScale: 0.5,
                                           edit: edit, state: .fit, hashPixels: true)
            } catch {
                fail("mask frame render threw: \(error.localizedDescription)")
                return nil
            }
        }

        guard let base = frame(MaskViewState.documentOnly(session.edit)),
              let baseHash = base.displayHash else {
            fail("no baseline frame for the mask checks")
            loupe.autoRenderEnabled = true
            return
        }
        log("mask baseline           \(baseHash.prefix(16))…  \(viewport.width)×\(viewport.height) @ decode 0.5")

        // 7.2 — a new mask covers nothing. Its atlas slice is all zeros, so the overlay pass copies
        // the frame: coverage 0 and the same pixels, which is also the "empty mask is the identity"
        // rule the mask tests assert on the GPU side.
        guard let mask = session.addMask() else {
            fail("addMask returned nil")
            loupe.autoRenderEnabled = true
            return
        }
        session.setShowMask(mask.id)
        guard let emptyOverlay = frame(session.edit), let emptyHash = emptyOverlay.displayHash else {
            fail("no frame for the empty mask")
            loupe.autoRenderEnabled = true
            return
        }
        let emptyCoverage = coverage(emptyOverlay.texture, base.texture)
        log(String(format: "mask empty overlay      coverage %.4f, hash %@", emptyCoverage, String(emptyHash.prefix(16))))
        check(String(format: "空蒙版：覆盖面积 %.4f == 0，叠加一个像素都没改（hash 相同）", emptyCoverage),
              emptyCoverage == 0 && emptyHash == baseHash)

        // 7.3 — paint a stroke with real mouse events through the shipped handler chain:
        // LoupeCanvasView.mouseDown/Dragged/Up → LoupeController → MaskCanvasController → session.
        session.maskTool = .brush
        session.brushSize = 0.18
        session.brushHardness = 0.5
        session.brushFlow = 1.0
        let canvas = loupe.canvasView
        let bounds = canvas.bounds
        check("画笔已武装：光标区是十字、拖拽不再平移（canvas \(Int(bounds.width))×\(Int(bounds.height)) pt）",
              loupe.maskCanvas.isArmed && bounds.width > 100)
        let historyBeforeStroke = session.history.count
        let events = synthesizeStroke(in: canvas, window: window,
                                      from: CGPoint(x: bounds.width * 0.2, y: bounds.midY),
                                      to: CGPoint(x: bounds.width * 0.8, y: bounds.midY),
                                      steps: 40)
        let pointsOnStroke = loupe.maskCanvas.lastStrokePointCount
        let strokes = session.strokeCount(ofMask: mask.id)
        let painterEvents = loupe.maskCanvas.eventsReceived
        let gestures = loupe.maskCanvas.finishedStrokes
        log("mask stroke             \(events) events posted, \(painterEvents) received → \(pointsOnStroke) points (spacing sampling), \(strokes) stroke(s), \(gestures) gesture(s), history \(historyBeforeStroke) → \(session.history.count)")
        check("一次拖拽 = 一笔 = 一个快照（\(painterEvents) 事件按间距采成 \(pointsOnStroke) 点，history +\(session.history.count - historyBeforeStroke)）",
              events >= 40 && painterEvents >= 40 && pointsOnStroke >= 2 && pointsOnStroke < painterEvents
              && strokes == 1 && gestures == 1 && !loupe.maskCanvas.isPainting
              && session.history.count == historyBeforeStroke + 1)

        guard let painted = frame(session.edit), let paintedHash = painted.displayHash else {
            fail("no frame for the painted mask")
            loupe.autoRenderEnabled = true
            return
        }
        let paintedCoverage = coverage(painted.texture, base.texture)
        log(String(format: "mask painted overlay    coverage %.4f, hash %@", paintedCoverage, String(paintedHash.prefix(16))))
        check(String(format: "画一笔 → 蒙版覆盖面积 0.0000 → %.4f 且帧 hash 变化", paintedCoverage),
              paintedCoverage > 0.01 && paintedCoverage < 0.7 && paintedHash != emptyHash)

        // 7.4 — the overlay is not an edit: toggling it must not grow the stack (QUEUE #1).
        let historyBeforeToggle = session.history.count
        let undoableBeforeToggle = session.canUndo
        let revisionBeforeToggle = session.editRevision
        session.toggleShowSelectedMask()
        let hiddenHash = frame(session.edit)?.displayHash
        session.toggleShowSelectedMask()
        let shownAgain = frame(session.edit)?.displayHash
        log("mask toggle             history \(historyBeforeToggle) → \(session.history.count), revision +\(session.editRevision - revisionBeforeToggle), hidden hash \(hiddenHash?.prefix(8) ?? "nil")…")
        check("显示蒙版 开关不产生历史（history 仍为 \(session.history.count)，canUndo 不变）且叠加确实换了像素",
              session.history.count == historyBeforeToggle
              && session.canUndo == undoableBeforeToggle
              && hiddenHash != nil && hiddenHash != paintedHash && shownAgain == paintedHash)

        // 7.5 — ⌘Z: back to the pre-stroke pixels, overlay untouched.
        let undone = controller.undoEdit()
        guard let afterUndo = frame(session.edit) else {
            fail("no frame after undo")
            loupe.autoRenderEnabled = true
            return
        }
        let undoneCoverage = coverage(afterUndo.texture, base.texture)
        log(String(format: "mask undo               coverage %.4f, hash %@, showMask %@",
                   undoneCoverage, String((afterUndo.displayHash ?? "nil").prefix(16)),
                   session.edit.showMaskID ?? "nil"))
        check("⌘Z 回到画笔前的帧（hash \(emptyHash.prefix(8))…，覆盖回 0）",
              undone && afterUndo.displayHash == emptyHash && undoneCoverage == 0)
        check("⌘Z 之后显示蒙版仍在（showMaskID 是视图态，不被快照回滚）",
              session.edit.showMaskID == mask.id)

        // 7.6 — ⇧⌘Z paints it back.
        let redid = controller.redoEdit()
        let redoCoverage = frame(session.edit).map { coverage($0.texture, base.texture) } ?? -1
        check(String(format: "⇧⌘Z 把这一笔加回来（覆盖 %.4f）", redoCoverage),
              redid && redoCoverage > 0.01)

        // 7.7 — a mask that changes pixels is the only thing worth persisting: +1 EV inside it.
        session.updateMask(mask.id, label: "蒙版曝光") { $0.adjustments.exposure = 1.0 }
        guard let saved = frame(MaskViewState.documentOnly(session.edit)),
              let savedHash = saved.displayHash else {
            fail("no frame for the adjusted mask")
            loupe.autoRenderEnabled = true
            return
        }
        let save = session.lastSaveResult
        log("mask saved frame        hash \(savedHash.prefix(16))… (mask +1 EV, overlay off)")
        log("mask persist            error=\(session.lastPersistError ?? "none") version=\(save?.developVersion ?? -1) seq=\(save?.historySeq ?? -1) rows=\(save?.historyRows ?? -1) changed=\(save?.changed ?? false) writes=\(session.persistCount)")
        check("蒙版内的局部曝光改变了像素（这份文档值得写库）", savedHash != baseHash)
        check("commit 之后写库成功（develop_version \(save?.developVersion ?? -1)，asset_history \(save?.historyRows ?? -1) 行，无错误）",
              session.lastPersistError == nil && (save?.changed ?? false) && (save?.historyRows ?? 0) >= 2)

        // 7.8 — close and reopen: a brand-new session reads the same library.
        let reopened = CatalogSession()
        var reopenError: String?
        do {
            try reopened.open(libraryURL)
            reopened.selectOnly(asset.id)
        } catch {
            reopenError = error.localizedDescription
        }
        if let reopenError {
            fail("could not reopen the library: \(reopenError)")
        } else {
            let storedMask = reopened.edit.masks.first
            let reloadedHash = frame(MaskViewState.documentOnly(reopened.edit))?.displayHash
            log("mask reopen             masks=\(reopened.edit.masks.count) strokes=\(reopened.strokeCount(ofMask: mask.id)) overlay=\(reopened.edit.showMaskID ?? "nil") hash=\((reloadedHash ?? "nil").prefix(16))…")
            check("重开库（新 session 读同一个库）后同一张照片的像素 hash 与保存前一致",
                  reloadedHash != nil && reloadedHash == savedHash)
            check("重开库后蒙版结构与保存前一致（1 个蒙版、1 笔、曝光 +1 EV），且 showMask 没有落盘",
                  reopened.edit.masks.count == 1
                  && reopened.strokeCount(ofMask: mask.id) == 1
                  && storedMask?.components.first?.shape.kind == MaskShape.brushKind
                  && (storedMask?.adjustments.exposure ?? 0) == 1.0
                  && reopened.edit.showMaskID == nil)
        }

        // 7.9 — delete: the pixels go back to the frame without the mask.
        session.deleteMask(mask.id)
        let afterDelete = frame(MaskViewState.documentOnly(session.edit))
        log("mask delete             masks=\(session.edit.masks.count) hash=\((afterDelete?.displayHash ?? "nil").prefix(16))…")
        check("删除蒙版后像素回到无蒙版帧（hash \(baseHash.prefix(8))…）",
              session.edit.masks.isEmpty && afterDelete?.displayHash == baseHash)

        session.maskTool = .off
        loupe.autoRenderEnabled = true
    }

    // MARK: - mask helpers

    /// Post a real mouse gesture (down, N drags, up) into the canvas' own handlers.
    ///
    /// Synthesised events, not a call into the controller: the point is to exercise the shipped
    /// `mouseDown/Dragged/Up` → `LoupeController` → `MaskCanvasController` chain, including the
    /// "is a brush armed?" branch that decides paint-versus-pan.
    @discardableResult
    private func synthesizeStroke(in canvas: LoupeCanvasView, window: NSWindow,
                                  from start: CGPoint, to end: CGPoint, steps: Int) -> Int {
        func post(_ type: NSEvent.EventType, _ point: CGPoint, _ number: Int) {
            guard let event = NSEvent.mouseEvent(with: type,
                                                 location: canvas.convert(point, to: nil),
                                                 modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber,
                                                 context: nil,
                                                 eventNumber: number,
                                                 clickCount: 1,
                                                 pressure: 1) else { return }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        post(.leftMouseDown, start, 0)
        for step in 1...max(1, steps) {
            let t = CGFloat(step) / CGFloat(max(1, steps))
            post(.leftMouseDragged,
                 CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                 step)
        }
        post(.leftMouseUp, end, steps + 1)
        return steps + 2
    }

    /// Fraction of pixels that differ between two frames — the mask's coverage, measured.
    private func coverage(_ a: MTLTexture, _ b: MTLTexture,
                          threshold: Float = 1.0 / 512.0) -> Double {
        guard a.width == b.width, a.height == b.height, a.width > 0 else { return -1 }
        let pa = rgba16(a), pb = rgba16(b)
        let count = a.width * a.height
        var differing = 0
        for i in 0..<count {
            let base = i * 4
            for c in 0..<3 {
                let va = Float(Float16(bitPattern: pa[base + c]))
                let vb = Float(Float16(bitPattern: pb[base + c]))
                if abs(va - vb) > threshold { differing += 1; break }
            }
        }
        return Double(differing) / Double(count)
    }

    private func rgba16(_ texture: MTLTexture) -> [UInt16] {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * MemoryLayout<UInt16>.size,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return raw
    }

    // MARK: - 蒙版参数：从两帧的差里量出“软硬”

    /// What one frame says about a mask parameter, measured against the frame with no mask.
    ///
    ///   · `amplitude` — the strongest luma difference anywhere. A strength parameter (opacity,
    ///     amount, EV) moves this; a geometric one does not.
    ///   · `maxStep` — the sharpest **single-pixel** jump in the difference image. This is the edge
    ///     softness in one number: a hard rim changes by the whole amplitude between two neighbouring
    ///     pixels, a blur of radius r spreads the same change over ~2r pixels, so `maxStep` falls
    ///     roughly as 1/r. That is why it can decide "变软" without a screenshot.
    ///   · `changed` — fraction of the frame that differs at all: the mask's **area**. Invert and a
    ///     `subtract` component move this, and a feather barely does.
    ///   · `partial` — of the affected pixels, the share that is *only partly* affected (between 20 %
    ///     and 80 % of the amplitude). A hard edge is mostly all-or-nothing; a soft edge is mostly
    ///     partial. The two numbers together are the "edge band" test.
    ///   · `core` — the **50 % contour**: the fraction of the frame at least half the peak effect.
    ///     This is the area a symmetric blur does *not* move (it moves the 2 %-of-peak tail, which is
    ///     why `changed` grows by tens of percent and is the wrong number for "面积不变").
    ///   · `mean` — the frame's mean luma, for the exposure slider's direction.
    private struct FrameDelta {
        var amplitude: Double = 0
        var maxStep: Double = 0
        var changed: Double = 0
        var partial: Double = 0
        var core: Double = 0
        var mean: Double = 0

        var text: String {
            String(format: "Δ峰 %.4f · 单像素最大跳变 %.4f · 覆盖 %.4f · 半幅 %.4f · 部分覆盖 %.3f · 均值 %.4f",
                   amplitude, maxStep, changed, core, partial, mean)
        }
    }

    /// Rec.709 luma of every pixel, 0…1 (the display texture, i.e. what the user sees).
    private func lumaPlane(_ texture: MTLTexture) -> [Double] {
        let raw = rgba16(texture)
        var out = [Double](repeating: 0, count: texture.width * texture.height)
        for i in out.indices {
            let base = i * 4
            let r = Double(Float(Float16(bitPattern: raw[base])))
            let g = Double(Float(Float16(bitPattern: raw[base + 1])))
            let b = Double(Float(Float16(bitPattern: raw[base + 2])))
            out[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return out
    }

    /// The same plane from a `DisplayImage` (what a `RenderGraph.render(..., wantsPixels: true)`
    /// hands back — the synthetic probes' source of pixels).
    private func lumaPlane(_ image: DisplayImage) -> [Double] {
        var out = [Double](repeating: 0, count: image.width * image.height)
        for i in out.indices {
            let base = i * 4
            out[i] = 0.2126 * Double(image.rgba[base])
                + 0.7152 * Double(image.rgba[base + 1])
                + 0.0722 * Double(image.rgba[base + 2])
        }
        return out
    }

    private func frameDelta(_ texture: MTLTexture, against base: MTLTexture) -> FrameDelta {
        let w = base.width, h = base.height
        guard w > 0, h > 0, texture.width == w, texture.height == h else { return FrameDelta() }
        return frameDelta(lumaPlane(texture), lumaPlane(base), width: w, height: h)
    }

    private func frameDelta(_ image: DisplayImage, against base: DisplayImage) -> FrameDelta {
        guard image.width == base.width, image.height == base.height else { return FrameDelta() }
        return frameDelta(lumaPlane(image), lumaPlane(base),
                          width: base.width, height: base.height)
    }

    private func frameDelta(_ a: [Double], _ b: [Double], width w: Int, height h: Int) -> FrameDelta {
        guard w > 0, h > 0, a.count == w * h, b.count == w * h else { return FrameDelta() }
        var d = [Double](repeating: 0, count: w * h)
        var mean = 0.0
        for i in d.indices {
            d[i] = abs(a[i] - b[i])
            mean += a[i]
        }
        mean /= Double(max(1, d.count))

        var out = FrameDelta()
        out.mean = mean
        out.amplitude = d.max() ?? 0
        let any = max(out.amplitude * 0.02, 1.0 / 512.0)
        let low = out.amplitude * 0.20
        let high = out.amplitude * 0.80
        var changed = 0, partial = 0, core = 0
        let half = out.amplitude * 0.50
        for v in d {
            guard v > any else { continue }
            changed += 1
            if v > half { core += 1 }
            if v > low && v < high { partial += 1 }
        }
        out.changed = Double(changed) / Double(d.count)
        out.core = Double(core) / Double(d.count)
        out.partial = changed > 0 ? Double(partial) / Double(changed) : 0

        var step = 0.0
        for y in 0..<h {
            let row = y * w
            for x in 0..<(w - 1) { step = max(step, abs(d[row + x + 1] - d[row + x])) }
        }
        for x in 0..<w {
            for y in 0..<(h - 1) { step = max(step, abs(d[(y + 1) * w + x] - d[y * w + x])) }
        }
        out.maxStep = step
        return out
    }

    /// The mask panel's readback seam, in the live view tree (`MaskListPanel`'s 1 × 1 background).
    private func maskProbe(in view: NSView?) -> MaskPanelProbe? {
        guard let view else { return nil }
        if let probe = view as? MaskPanelProbe { return probe }
        for subview in view.subviews {
            if let found = maskProbe(in: subview) { return found }
        }
        return nil
    }

    // MARK: - 直方图卡片 + 高光警告（005f 的 UI）

    /// The histogram card, asserted on the **frame's own measurement** rather than on a re-count of
    /// its own numbers:
    ///
    ///   1. the card is a real view in the inspector's SwiftUI tree and it drew 4 series of 256 bins;
    ///   2. every channel's bins sum to the sample count (the measurement's own invariant);
    ///   3. the 削顶 percentage is **Core's** number — checked twice: the card's text against
    ///      `HistogramCardFormat`, and Core's ratio against an independent full-resolution recount of
    ///      the very pixels that frame presented (at 720 × 420 the sample grid *is* the frame, so the
    ///      two agree exactly and the check is not a downsample estimate);
    ///   4. clicking 削顶 toggles the canvas warning, and doing so moves **no** document: same
    ///      document hash, same history depth, same `editRevision`, same persistence count.
    private func checkHistogramCard(session: CatalogSession, loupe: LoupeController,
                                    controller: EditorWindowController, window: NSWindow,
                                    asset: Asset, url: URL) {
        loupe.autoRenderEnabled = false
        session.maskTool = .off
        session.applyEdit { $0 = .neutral }
        session.commitEdit(label: "Reset")

        guard let card = findHistogramCard(in: window.contentView) else {
            fail("检查器里没有直方图卡片（视图树里找不到 HistogramCardView）")
            loupe.autoRenderEnabled = true
            return
        }

        // A canvas whose long edge is under `Histogram.maxLongEdge`, i.e. the measurement's sample
        // grid is the frame itself. That is what makes check 3 an equality rather than a bound.
        let viewport = ImageSize(width: 720, height: 420)
        guard let frame = try? loupe.makeFrame(asset: asset, url: url, viewport: viewport,
                                               decodeScale: 0.5,
                                               edit: MaskViewState.documentOnly(session.edit),
                                               state: .fit, hashPixels: false),
              let histogram = frame.histogram else {
            fail("直方图：这一帧没有 measurement（collectHistogram 没生效）")
            loupe.autoRenderEnabled = true
            return
        }
        // The same hand-off `present` performs: the card's input is the frame's own measurement.
        loupe.recordMeasurements(frame)
        let cardDeadline = Date().addingTimeInterval(6)
        while card.histogram != histogram && Date() < cardDeadline { pump(0.1) }
        card.needsDisplay = true
        card.display()

        log("histogram frame         \(histogram.sampleCount) px sampled on \(histogram.sampleSize.width)×\(histogram.sampleSize.height) · canvas \(histogram.canvas.width)×\(histogram.canvas.height) · \(histogram.binCount) bins · publishes \(loupe.histogramPublishCount)")
        check("直方图卡片在检查器里，并画出 4 组 × \(histogram.binCount) bin（实测 series \(card.lastDrawnSeries) / bins \(card.lastDrawnBins)）",
              card.lastDrawnSeries == 4 && card.lastDrawnBins == histogram.binCount
              && card.histogram != nil)

        let totals = [histogram.red.total, histogram.green.total,
                      histogram.blue.total, histogram.luma.total]
        check("bin 和 == 采样像素数（R/G/B/L 四组 \(totals) 全 == sampleCount \(histogram.sampleCount)，卡片读的是同一份）",
              histogram.sampleCount > 0 && totals.allSatisfy { $0 == histogram.sampleCount }
              && card.histogram == histogram)

        // Independent recount: the ratio Core reports, recomputed from the presented pixels with the
        // same 0.999 threshold, and the luma with the same Rec.709 weights.
        let recounted = clipFractions(of: frame.texture)
        let coreValues = [histogram.red, histogram.green, histogram.blue, histogram.luma]
            .map(\.clippedHigh)
        let deltas = zip(recounted, coreValues).map { abs($0 - $1) }
        log("clipped recount         card “\(card.clipHighText)” · Core luma \(String(format: "%.5f", histogram.luma.clippedHigh)) · 逐通道 Core \(coreValues.map { String(format: "%.5f", $0) }) · 独立重数 \(recounted.map { String(format: "%.5f", $0) }) · 最大差 \(deltas.max() ?? -1)")
        check("削顶百分比与 Core 一致：Core 的 4 个 clippedHigh 与对同一帧像素独立重数的最大差 \(String(format: "%.2e", deltas.max() ?? -1))（< 1e-5，即 0.001 个百分点以内）",
              deltas.allSatisfy { $0 < 1e-5 })
        let expectedText = [Histogram.Channel.red, .green, .blue, .luma]
            .map { HistogramCardFormat.clipHigh(histogram, $0) }
        check("卡片上的削顶数字就是 Core 的值（\(card.clipHighTextByChannel.joined(separator: " / ")) == \(expectedText.joined(separator: " / "))，削底 \(card.clipLowText)）",
              card.clipHighTextByChannel == expectedText
              && card.clipHighText == HistogramCardFormat.clipHigh(histogram, .luma)
              && card.clipLowText == HistogramCardFormat.clipLow(histogram, .luma))

        // The warning: a real click on the number, then a frame that carries the clipped grid.
        let documentBefore = documentHash(session.edit)
        let historyBefore = session.history.count
        let revisionBefore = session.editRevision
        let persistsBefore = session.persistCount
        let warningBefore = session.highlightWarning
        let hit = card.clipHighHitRect
        var clicked = false
        if hit.width > 1, let event = mouseDownEvent(in: card, at: NSPoint(x: hit.midX, y: hit.midY),
                                                     window: window) {
            card.mouseDown(with: event)
            clicked = true
        }
        pump(0.2)
        let toggled = session.highlightWarning != warningBefore
        if let warnedFrame = try? loupe.makeFrame(asset: asset, url: url, viewport: viewport,
                                                  decodeScale: 0.5,
                                                  edit: MaskViewState.documentOnly(session.edit),
                                                  state: .fit) {
            loupe.recordMeasurements(warnedFrame)
        }
        pump(0.2)
        let grid = loupe.lastClipped
        log("highlight warning       click=\(clicked) \(warningBefore) → \(session.highlightWarning) · grid \(grid.map { "\($0.columns)×\($0.rows)" } ?? "nil") · clipped \(grid?.clippedFraction ?? -1) · cells \(grid?.clippedCellCount ?? -1)")
        check("点削顶数字切换高光警告（\(warningBefore) → \(session.highlightWarning)），叠色网格 \(grid.map { "\($0.columns)×\($0.rows)" } ?? "nil") 有 \(grid?.clippedCellCount ?? 0) 个格子被点亮",
              clicked && toggled && (grid.map { !$0.isEmpty } ?? false))

        let documentAfter = documentHash(session.edit)
        log("highlight doc hash      \(documentBefore.prefix(16))… → \(documentAfter.prefix(16))… · history \(session.history.count) · editRevision \(session.editRevision) · persist \(session.persistCount)")
        check("高光警告开关不改文档：hash 不变（\(documentBefore.prefix(8))…）、history 仍 \(historyBefore) 条、editRevision +\(session.editRevision - revisionBefore)、persistCount +\(session.persistCount - persistsBefore)",
              documentAfter == documentBefore && session.history.count == historyBefore
              && session.editRevision == revisionBefore
              && session.persistCount == persistsBefore)

        // The warning's threshold is the histogram's, proved on a frame that *is* clipped: a
        // synthetic white source must light every grid cell and report 100 % in both measurements.
        // (This photo has no clipped pixels, so its own grid is legitimately empty — that is the
        // honest half of the pair.)
        var whiteGrid: ClippedGrid?
        var whiteHistogram: Histogram?
        let whiteWidth = 128, whiteHeight = 96
        var whitePixels = [Float16](repeating: 0, count: whiteWidth * whiteHeight * 4)
        for i in stride(from: 0, to: whitePixels.count, by: 4) {
            whitePixels[i] = 8
            whitePixels[i + 1] = 8
            whitePixels[i + 2] = 8
            whitePixels[i + 3] = 1
        }
        let white = LinearImage(width: whiteWidth, height: whiteHeight, rgba: whitePixels,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let whiteCanvas = ImageSize(width: whiteWidth, height: whiteHeight)
        if let graph = try? RenderGraph(input: RenderInput(image: white, identity: "ui-smoke-white")),
           let rendered = try? graph.render(EditModel(), options: RenderOptions(
                canvas: whiteCanvas, wantsPixels: false,
                collectHistogram: true, histogramBins: 256)),
           let texture = rendered.output {
            whiteGrid = HighlightWarning.grid(of: texture)
            whiteHistogram = rendered.histogram
            graph.recycle(output: texture)
        }
        let whiteCells = whiteGrid?.clippedCellCount ?? -1
        let whiteGridFraction = whiteGrid?.clippedFraction ?? -1
        let whiteHistogramFraction = whiteHistogram?.luma.clippedHigh ?? -1
        log("clip threshold probe    cells \(whiteCells)/\(HighlightWarning.columns * HighlightWarning.rows) · grid \(String(format: "%.3f", whiteGridFraction)) · histogram luma \(String(format: "%.3f", whiteHistogramFraction))")
        check("高光警告与削顶百分比共用 0.999 阈值：纯白源（线性 8）整网格点亮 \(whiteCells)/\(HighlightWarning.columns * HighlightWarning.rows) 格，网格 \(String(format: "%.3f", whiteGridFraction)) == histogram.luma.clippedHigh \(String(format: "%.3f", whiteHistogramFraction))",
              whiteCells == HighlightWarning.columns * HighlightWarning.rows
              && whiteGridFraction > 0.99 && whiteHistogramFraction > 0.99)

        // Back off, so the frames the later checks render are the plain ones.
        if session.highlightWarning { card.toggleHighlightWarning() }
        pump(0.15)
        loupe.autoRenderEnabled = true
    }

    // MARK: - 蒙版形状（线性 / 径向 / 颜色 / 亮度 / 语义）

    /// The six shapes M4's document model has, exercised through the UI's own paths:
    ///
    ///   · **linear and radial are drawn**, not created with a default: the gesture goes through
    ///     `LoupeCanvasView.mouseDown/Dragged/Up` → `LoupeController` → `addShapeMask`, and ⌘Z takes
    ///     the whole gesture back (one snapshot, not "new mask" + "move it");
    ///   · a second drag on a selected gradient **adjusts** it (centre → rim), also one snapshot;
    ///   · colour range / luminance range / semantic are created from the inspector's 新建 menu API,
    ///     with their coverage measured the same way the brush's is — the frame with the mask's
    ///     overlay against the frame with none, so "nonzero area" means pixels, not parameters;
    ///   · a **pure-colour source** makes the colour-range mask select ~100 % of the picture, which
    ///     is the one case where the area is predictable without knowing the photo.
    private func checkMaskShapes(session: CatalogSession, loupe: LoupeController,
                                 controller: EditorWindowController, window: NSWindow,
                                 asset: Asset, url: URL) {
        loupe.autoRenderEnabled = false
        session.maskTool = .off
        session.setShowMask(nil)
        session.applyEdit { $0 = .neutral }
        session.commitEdit(label: "Reset")
        let viewport = ImageSize(width: 720, height: 420)

        func frame(_ edit: EditModel) -> LoupeController.FrameResult? {
            do {
                return try loupe.makeFrame(url: url, viewport: viewport, decodeScale: 0.5,
                                           edit: edit, state: .fit, hashPixels: true)
            } catch {
                fail("mask shape frame threw: \(error.localizedDescription)")
                return nil
            }
        }

        /// The document with no masks at all — the denominator every coverage is measured against.
        func withoutMasks(_ model: EditModel) -> EditModel {
            var document = MaskViewState.documentOnly(model)
            document.masks = []
            return document
        }

        guard let plain = frame(withoutMasks(session.edit)) else {
            fail("蒙版形状：没有基线帧")
            loupe.autoRenderEnabled = true
            return
        }

        /// Measured area of one mask: its `showMask` overlay against the no-mask frame. Reads the
        /// atlas slice S1.6 consumed, so a nonzero number means a real selection reached the GPU.
        ///
        /// The live document is rendered **unstripped**: `documentOnly` would take the overlay away
        /// (`showMaskID` is view state), and then the overlay would measure zero by construction.
        func coverageOf(_ maskID: String) -> Double {
            session.setShowMask(maskID)
            defer { session.setShowMask(nil) }
            guard let over = frame(session.edit) else { return -1 }
            return coverage(over.texture, plain.texture)
        }

        let canvas = loupe.canvasView
        let bounds = canvas.bounds

        // MARK: 10.1 linear: drawn on the canvas, one snapshot, ⌘Z removes it

        let depthBeforeLinear = session.history.count
        session.createMask(.linearGradient)
        let armed = loupe.isShapeDragArmed
        let emptyWhileArmed = session.edit.masks.isEmpty
        let events = synthesizeStroke(in: canvas, window: window,
                                      from: CGPoint(x: bounds.width * 0.28, y: bounds.height * 0.30),
                                      to: CGPoint(x: bounds.width * 0.74, y: bounds.height * 0.68),
                                      steps: 24)
        let linearMask = session.edit.masks.last
        var linearGeometry = "—"
        var linearForward = false
        if case .linearGradient(let g)? = linearMask?.components.first?.shape {
            linearGeometry = String(format: "%.2f,%.2f → %.2f,%.2f", g.start.x, g.start.y,
                                    g.end.x, g.end.y)
            linearForward = g.end.x > g.start.x && g.end.y > g.start.y
        }
        let linearCoverage = linearMask.map { coverageOf($0.id) } ?? -1
        log("mask linear             \(events) 事件 · kind=\(linearMask?.components.first?.shape.kind ?? "nil") · \(linearGeometry) · 覆盖 \(String(format: "%.4f", linearCoverage)) · history \(depthBeforeLinear)→\(session.history.count)")
        check("线性渐变：画布拖拽创建（armed=\(armed)，按下时还没有 mask=\(emptyWhileArmed)），一个蒙版一笔历史，\(linearGeometry)，覆盖面积 \(String(format: "%.4f", linearCoverage))",
              armed && emptyWhileArmed && loupe.shapeDragsCreated == 1
              && session.edit.masks.count == 1
              && linearMask?.components.first?.shape.kind == MaskShape.linearKind
              && linearForward && linearCoverage > 0.01
              && session.history.count == depthBeforeLinear + 1)

        let undidLinear = controller.undoEdit()
        pump(0.1)
        check("线性渐变拖拽创建后 ⌘Z 一次撤掉整个蒙版（mask 1 → \(session.edit.masks.count)，pending \(session.pendingMaskShape?.rawValue ?? "nil")）",
              undidLinear && session.edit.masks.isEmpty && session.pendingMaskShape == nil)

        // MARK: 10.2 radial: drawn as centre → rim

        session.createMask(.radialGradient)
        _ = synthesizeStroke(in: canvas, window: window,
                             from: CGPoint(x: bounds.midX, y: bounds.midY),
                             to: CGPoint(x: bounds.midX + bounds.width * 0.16,
                                         y: bounds.midY + bounds.height * 0.20),
                             steps: 20)
        let radialMask = session.edit.masks.last
        var radialBefore = 0.0
        if case .radialGradient(let g)? = radialMask?.components.first?.shape {
            radialBefore = max(g.radius.x, g.radius.y)
        }
        let radialCoverage = radialMask.map { coverageOf($0.id) } ?? -1
        log("mask radial             kind=\(radialMask?.components.first?.shape.kind ?? "nil") · r=\(String(format: "%.3f", radialBefore)) · 覆盖 \(String(format: "%.4f", radialCoverage))")
        check("径向渐变：中心→边缘拖拽创建，半径 \(String(format: "%.3f", radialBefore))（短边单位），覆盖面积 \(String(format: "%.4f", radialCoverage))",
              radialMask?.components.first?.shape.kind == MaskShape.radialKind
              && radialBefore > 0.05 && radialCoverage > 0.01
              && loupe.shapeDragsCreated == 2)

        // MARK: 10.3 radial adjustment: a second drag reshapes it, one snapshot, ⌘Z restores

        func radialRadius() -> Double {
            guard let shape = session.edit.masks.first?.components.first?.shape,
                  case .radialGradient(let g) = shape else { return 0 }
            return max(g.radius.x, g.radius.y)
        }

        let depthBeforeAdjust = session.history.count
        _ = synthesizeStroke(in: canvas, window: window,
                             from: CGPoint(x: bounds.midX, y: bounds.midY),
                             to: CGPoint(x: bounds.midX + bounds.width * 0.26,
                                         y: bounds.midY + bounds.height * 0.30),
                             steps: 20)
        let radialAfter = radialRadius()
        log("mask radial adjust      r \(String(format: "%.3f", radialBefore)) → \(String(format: "%.3f", radialAfter)) · history \(depthBeforeAdjust)→\(session.history.count)")
        check("径向渐变可在画布上拖动调整（半径 \(String(format: "%.3f", radialBefore)) → \(String(format: "%.3f", radialAfter))，一次拖拽一条历史 +\(session.history.count - depthBeforeAdjust)）",
              radialAfter > radialBefore + 0.02 && session.history.count == depthBeforeAdjust + 1
              && loupe.shapeDragsAdjusted == 1)

        _ = controller.undoEdit()
        pump(0.1)
        let radialRestored = radialRadius()
        check("调整后再 ⌘Z 回到拖动前的半径（\(String(format: "%.3f", radialRestored)) ≈ \(String(format: "%.3f", radialBefore))）",
              abs(radialRestored - radialBefore) < 0.01 && session.edit.masks.count == 1)

        // Clean the gradients away; the remaining shapes are created by the panel's menu API.
        for mask in session.edit.masks { session.deleteMask(mask.id) }

        // MARK: 10.4 colour range: sampled from the picture itself

        let depthBeforeColor = session.history.count
        let colorMask = session.addMask(kind: .colorRange)
        var colorCoverage = -1.0
        if let colorMask {
            // "从画面取色": the frame's mean display colour, encoded the way `ColorRangeShape.samples`
            // is stored (sRGB). A tolerance of 0.35 in the normalised OKLab metric then means "this
            // neighbourhood of colours", which is what a colour-range mask is.
            let sample = averageSample(of: plain.texture)
            session.setMaskComponentShape(colorMask.id, component: 0,
                                          shape: .colorRange(ColorRangeShape(samples: [sample],
                                                                             tolerance: 0.35,
                                                                             smoothness: 0.5)),
                                          commit: false, label: "")
            colorCoverage = coverageOf(colorMask.id)
            log("mask colour             kind=\(colorMask.components.first?.shape.kind ?? "nil") · 样本 \(sample.map { String(format: "%.3f", $0) }) · 覆盖 \(String(format: "%.4f", colorCoverage))")
        }
        check("颜色范围蒙版（样本取自画面均值）覆盖面积 \(String(format: "%.4f", colorCoverage))，新建即一条历史（+\(session.history.count - depthBeforeColor)）",
              colorMask != nil && colorMask?.components.first?.shape.kind == MaskShape.colorRangeKind
              && colorCoverage > 0.01 && colorCoverage <= 1.0
              && session.history.count == depthBeforeColor + 1)

        // MARK: 10.5 luminance range: the full span covers the picture

        let lumaMask = session.addMask(kind: .luminanceRange)
        let lumaCoverage = lumaMask.map { coverageOf($0.id) } ?? -1
        log("mask luminance          kind=\(lumaMask?.components.first?.shape.kind ?? "nil") · 0…1 · 覆盖 \(String(format: "%.4f", lumaCoverage))")
        check("亮度范围蒙版 0…1 覆盖面积 \(String(format: "%.4f", lumaCoverage))（几乎整幅，扣掉两端羽化）",
              lumaMask?.components.first?.shape.kind == MaskShape.luminanceRangeKind
              && lumaCoverage > 0.5)

        // MARK: 10.6 semantic: created with the route the capability table picks

        let semanticMask = session.addMask(kind: .semantic, semanticKind: .subject)
        var semanticKind = "-"
        var semanticProvider = "-"
        if case .semantic(let s)? = semanticMask?.components.first?.shape {
            semanticKind = s.kind.rawValue
            semanticProvider = s.provider.rawValue
        }
        let semanticCoverage = semanticMask.map { coverageOf($0.id) } ?? -1
        log("mask semantic           kind=\(semanticMask?.components.first?.shape.kind ?? "nil") · \(semanticKind)/\(semanticProvider) · 覆盖 \(String(format: "%.4f", semanticCoverage))（OS 模型决定，可能为 0）")
        check("语义蒙版按能力表选路线创建（subject → \(semanticProvider)），进文档与列表（掩码数 \(session.edit.masks.count)）",
              semanticMask?.components.first?.shape.kind == MaskShape.semanticKind
              && semanticKind == "subject" && semanticProvider == SemanticProvider.visionForeground.rawValue
              && session.edit.masks.contains { $0.id == semanticMask?.id })

        // MARK: 10.7 the brush still creates its own (regression: the menu did not replace it)

        let brushMask = session.addMask(kind: .brush)
        var brushIsEmpty = false
        if case .brush(let b)? = brushMask?.components.first?.shape { brushIsEmpty = b.strokes.isEmpty }
        check("画笔（原有形状）仍能从同一菜单新建：空笔刷组件、kind=brush、覆盖 0",
              brushMask?.components.first?.shape.kind == MaskShape.brushKind && brushIsEmpty
              && (brushMask.map { coverageOf($0.id) } ?? -1) == 0)

        // MARK: 10.8 a pure-colour source: the colour-range mask selects all of it

        let side = 192
        let linearColour = (r: 0.18, g: 0.42, b: 0.62)
        var solidPixels = [Float16]()
        solidPixels.reserveCapacity(side * side * 4)
        for _ in 0..<(side * side) {
            solidPixels.append(Float16(linearColour.r))
            solidPixels.append(Float16(linearColour.g))
            solidPixels.append(Float16(linearColour.b))
            solidPixels.append(1)
        }
        let solid = LinearImage(width: side, height: side, rgba: solidPixels,
                                colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let solidSample = [srgbEncoded(linearColour.r), srgbEncoded(linearColour.g),
                           srgbEncoded(linearColour.b)]
        let solidMask = Mask(id: "m-solid", name: "纯色",
                             components: [MaskComponent(id: "c-solid", shape:
                                .colorRange(ColorRangeShape(samples: [solidSample], tolerance: 0.30,
                                                            smoothness: 0.5)))])
        var solidDocument = EditModel(masks: [solidMask])
        solidDocument.showMaskID = solidMask.id
        let solidCanvas = ImageSize(width: side, height: side)
        var solidArea = -1.0
        if let graph = try? RenderGraph(input: RenderInput(image: solid, identity: "ui-smoke-solid")),
           let masked = try? graph.render(solidDocument,
                                          options: RenderOptions(canvas: solidCanvas, wantsPixels: true)),
           let maskedPixels = masked.display,
           let plainSolid = try? graph.render(EditModel(),
                                              options: RenderOptions(canvas: solidCanvas, wantsPixels: true)),
           let plainPixels = plainSolid.display {
            solidArea = differingFraction(maskedPixels, plainPixels)
            log("solid colour probe      \(side)×\(side) 单体色 · 样本 \(solidSample.map { String(format: "%.3f", $0) }) · 覆盖 \(String(format: "%.4f", solidArea)) · masks \(masked.showsMask)")
        }
        check("纯色源的颜色范围蒙版覆盖面积 ≈ 1（实测 \(String(format: "%.4f", solidArea))，源是单一线性色）",
              solidArea > 0.95)

        // Leave the document as clean as the checks found it.
        for mask in session.edit.masks { session.deleteMask(mask.id) }
        session.setShowMask(nil)
        session.maskTool = .off
        loupe.autoRenderEnabled = true
    }

    // MARK: - 蒙版参数面板（Q28：蒙版级 + 局部调整 + 改名/排序）

    /// The parameter half of the mask panel, asserted on **pixels** and on the numbers that reach
    /// `EditHistory` — never on a screenshot:
    ///
    ///   · `opacity` scales the effect (half the slider ⇒ a smaller Δ) and costs one snapshot;
    ///   · `invert` flips the **area**: the fraction of the frame that differs from the no-mask frame
    ///     is measured twice, and "outside" must be the bigger of the two;
    ///   · `feather` softens the rim — a **box blur**, so it is measured on a flat source where the
    ///     mask's own alpha is the only structure: the sharpest single-pixel jump drops and the share
    ///     of *partly* covered pixels rises, while the area does not move;
    ///   · `refine` is a **guided filter**, not a blur: on a structureless source it degrades to a
    ///     symmetric smoothing, so the edge softens while the **50 % contour** (the `core` area) stays
    ///     put — a blur's tail grows, its half-amplitude contour does not. On the photograph it
    ///     re-aims coverage at image structure, which is why its 2 %-of-peak area moves (+55 %); both
    ///     numbers are logged, the contour invariance is what is asserted;
    ///   · the local sliders are real: ±2 EV inside the mask raises and lowers the frame's mean, and
    ///     at 0 EV the frame is **bit-identical** to the frame with no mask at all (M1-6's identity
    ///     branch, which is what makes "a mask with no adjustments" free);
    ///   · the blend picker's `subtract` cuts a hole (one component only ignores its `op` by design);
    ///   · rename redraws nothing (pixel hash *and* both keys identical) yet commits one snapshot —
    ///     Core's `isSemanticallyIdentical` compares the masks by value, name included;
    ///   · ▲▼ reorders the document list (and `develop_json`) while the *key material* stays put,
    ///     because `EditModel.activeMasks` sorts by id by design (D6);
    ///   · a 10-tick drag is one snapshot and a handful of debounced frames.
    private func checkMaskParameters(session: CatalogSession, loupe: LoupeController,
                                     controller: EditorWindowController, window: NSWindow,
                                     asset: Asset, url: URL) {
        loupe.autoRenderEnabled = false
        session.maskTool = .off
        session.setShowMask(nil)
        session.applyEdit { $0 = .neutral }
        session.commitEdit(label: "Reset")
        for mask in session.edit.masks { session.deleteMask(mask.id) }

        let viewport = ImageSize(width: 720, height: 480)

        func frame(_ edit: EditModel) -> LoupeController.FrameResult? {
            do {
                return try loupe.makeFrame(url: url, viewport: viewport, decodeScale: 0.5,
                                           edit: edit, state: .fit, hashPixels: true)
            } catch {
                fail("mask parameter frame threw: \(error.localizedDescription)")
                return nil
            }
        }
        /// The live document, minus the overlay (view state), i.e. what the renderer is judged on.
        func document() -> EditModel { MaskViewState.documentOnly(session.edit) }
        func shot() -> LoupeController.FrameResult? { frame(document()) }

        var withoutMasks = document()
        withoutMasks.masks = []
        guard let base = frame(withoutMasks) else {
            fail("蒙版参数：没有基线帧")
            loupe.autoRenderEnabled = true
            return
        }

        // A radial mask over the middle with a **near-hard** rim (component feather 0.02) and +2 EV
        // inside it. The hard rim is the point: a shape whose own transition band already spans a
        // quarter of its radius would swallow the mask-level feather this section has to measure.
        guard let mask = session.addMask(kind: .radialGradient) else {
            fail("蒙版参数：addMask 返回 nil")
            loupe.autoRenderEnabled = true
            return
        }
        session.writeMask(mask.id, label: "蒙版初值", commit: true) { m in
            if !m.components.isEmpty { m.components[0].feather = 0.02 }
            m.adjustments.exposure = 2.0
        }
        func current() -> Mask? { session.edit.masks.first { $0.id == mask.id } }

        guard let fullFrame = shot(), let fullHash = fullFrame.displayHash else {
            fail("蒙版参数：全强度帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        let full = frameDelta(fullFrame.texture, against: base.texture)
        log("mask params full        \(full.text) · hash \(fullHash.prefix(16))…")

        // MARK: 12.1 opacity — a strength, and one snapshot

        let depthBeforeOpacity = session.history.count
        let wroteOpacity = session.setMaskLevel(mask.id, .opacity, 0.5, commit: true)
        guard let halfFrame = shot() else {
            fail("蒙版参数：半强度帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        let half = frameDelta(halfFrame.texture, against: base.texture)
        let opacityRatio = full.amplitude > 0 ? half.amplitude / full.amplitude : -1
        log(String(format: "mask opacity            100%% → 50%%: Δ峰 %.4f → %.4f (%.2f×) · 覆盖 %.4f → %.4f · history %d → %d",
                   full.amplitude, half.amplitude, opacityRatio, full.changed, half.changed,
                   depthBeforeOpacity, session.history.count))
        check(String(format: "不透明度 100 %% → 50 %%：像素变了（Δ峰 %.4f → %.4f，%.2f×，覆盖 %.4f 不变），history +%d 一次快照",
                     full.amplitude, half.amplitude, opacityRatio, half.changed,
                     session.history.count - depthBeforeOpacity),
              wroteOpacity && halfFrame.displayHash != fullHash
              && session.history.count == depthBeforeOpacity + 1
              && opacityRatio > 0.2 && opacityRatio < 0.85
              && abs(half.changed - full.changed) < 0.01)

        session.setMaskLevel(mask.id, .opacity, 1.0, commit: true)

        // MARK: 12.2 invert — the area flips

        let depthBeforeInvert = session.history.count
        session.setMaskInverted(mask.id, true)
        guard let invertedFrame = shot() else {
            fail("蒙版参数：反转帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        let inverted = frameDelta(invertedFrame.texture, against: base.texture)
        let areaSum = full.changed + inverted.changed
        log(String(format: "mask invert             关 %.4f · 开 %.4f · 和 %.4f（内容区）· history %d → %d",
                   full.changed, inverted.changed, areaSum, depthBeforeInvert, session.history.count))
        check(String(format: "反转改变覆盖面积：关 %.4f < 开 %.4f（%.1f×），两者互补（和 %.4f），history +%d",
                     full.changed, inverted.changed, full.changed > 0 ? inverted.changed / full.changed : 0,
                     areaSum, session.history.count - depthBeforeInvert),
              session.history.count == depthBeforeInvert + 1
              && full.changed < 0.45 && inverted.changed > 0.5
              && inverted.changed > full.changed * 2 && abs(areaSum - 1) < 0.15)
        session.setMaskInverted(mask.id, false)

        // MARK: 12.3 + 12.4 feather / refine — two neighbourhood operators, two different pieces of
        // evidence
        //
        // Feather is a **separable box blur** of the combined selection; refine is a **guided
        // filter** (it follows the picture's luma, which is why it must not be judged by "the edge
        // got blurrier on a photo"). Both are therefore measured on a source with **no structure at
        // all**: inside a +2 EV region the difference image varies with the pixel's own value, so on
        // a photograph the sharpest jump is a *content* edge (measured 0.4526 with feather 0 and
        // 0.4526 with feather 0.4 — the statistic was wrong, not the blur missing). On a flat source
        // what is left in the frame is the mask itself.
        //
        // The invariant both share: a smoothing operator widens the transition band but leaves the
        // **half-amplitude contour** where it was. That contour — `core`, not the 2 %-of-peak tail
        // `changed`, which grows by tens of percent for either operator — is what "does not move the
        // boundary" means here.

        let depthBeforeFeather = session.history.count
        session.setMaskLevel(mask.id, .feather, 0.4, commit: true)
        let historyAfterFeather = session.history.count
        guard let featheredFrame = shot(), let featheredHash = featheredFrame.displayHash else {
            fail("蒙版参数：羽化帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        let feathered = frameDelta(featheredFrame.texture, against: base.texture)
        session.setMaskLevel(mask.id, .feather, 0, commit: true)

        let depthBeforeRefine = session.history.count
        session.setMaskLevel(mask.id, .refine, 0.9, commit: true)
        let historyAfterRefine = session.history.count
        guard let refinedFrame = shot(), let refinedHash = refinedFrame.displayHash else {
            fail("蒙版参数：精修帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        let refined = frameDelta(refinedFrame.texture, against: base.texture)
        session.setMaskLevel(mask.id, .refine, 0, commit: true)

        // A flat 320² mid-grey source: the mask's own alpha is the only structure in the frame.
        let side = 320
        var flatPixels = [Float16]()
        flatPixels.reserveCapacity(side * side * 4)
        for _ in 0..<(side * side) {
            flatPixels.append(Float16(0.18))
            flatPixels.append(Float16(0.18))
            flatPixels.append(Float16(0.18))
            flatPixels.append(1)
        }
        let flatImage = LinearImage(width: side, height: side, rgba: flatPixels,
                                    colorSpace: "extendedLinearSRGB", decoderVersion: "synthetic")
        let flatCanvas = ImageSize(width: side, height: side)

        func flatMask(feather: Double, refine: Double) -> Mask {
            Mask(id: "m-flat", name: "flat", opacity: 1, invert: false,
                 feather: feather, refine: refine,
                 components: [MaskComponent(id: "c-flat", op: .add, invert: false, feather: 0.02,
                                            shape: .radialGradient(RadialGradientShape(
                                                center: NormalizedPoint(0.5, 0.5),
                                                radius: NormalizedPoint(0.30, 0.30), angle: 0)))],
                 adjustments: LocalAdjustments(exposure: 2.0))
        }

        var flatDeltas: [String: FrameDelta] = [:]
        if let graph = try? RenderGraph(input: RenderInput(image: flatImage,
                                                           identity: "ui-smoke-mask-params")),
           let plain = try? graph.render(EditModel(),
                                          options: RenderOptions(canvas: flatCanvas, wantsPixels: true)),
           let plainPixels = plain.display {
            for (name, feather, refine) in [("hard", 0.0, 0.0), ("feather", 0.4, 0.0),
                                             ("refine", 0.0, 0.9)] {
                let document = EditModel(masks: [flatMask(feather: feather, refine: refine)])
                guard let rendered = try? graph.render(document,
                                                       options: RenderOptions(canvas: flatCanvas,
                                                                              wantsPixels: true)),
                      let pixels = rendered.display else { continue }
                flatDeltas[name] = frameDelta(pixels, against: plainPixels)
            }
        } else {
            fail("蒙版参数：纯色合成源没有渲染出来（羽化/精修的软硬量不了）")
        }
        let flatHard = flatDeltas["hard"] ?? FrameDelta()
        let flatFeathered = flatDeltas["feather"] ?? FrameDelta()
        let flatRefined = flatDeltas["refine"] ?? FrameDelta()
        let flatReady = flatDeltas.count == 3 && flatHard.amplitude > 0
        log(String(format: "mask flat probe         %d×%d 纯色 · 硬边 跳变 %.4f / 半覆盖 %.3f / 半幅 %.4f / 覆盖 %.4f · 羽化 %.4f / %.3f / %.4f / %.4f · 精修 %.4f / %.3f / %.4f / %.4f",
                   side, side,
                   flatHard.maxStep, flatHard.partial, flatHard.core, flatHard.changed,
                   flatFeathered.maxStep, flatFeathered.partial, flatFeathered.core, flatFeathered.changed,
                   flatRefined.maxStep, flatRefined.partial, flatRefined.core, flatRefined.changed))

        let featherStepRatio = flatHard.maxStep > 0 ? flatFeathered.maxStep / flatHard.maxStep : -1
        let featherPartialRatio = flatHard.partial > 0 ? flatFeathered.partial / flatHard.partial : -1
        let featherCoreDrift = flatHard.core > 0
            ? abs(flatFeathered.core - flatHard.core) / flatHard.core : -1
        let featherPhotoCore = full.core > 0 ? (feathered.core - full.core) / full.core : 0
        log(String(format: "mask feather            0 → 0.40：无结构源 跳变 %.4f → %.4f (%.2f×) · 半覆盖 %.3f → %.3f (%.2f×) · 半幅面积 %.4f → %.4f (漂 %.2f %%) ‖ 照片 半幅 %+.2f %% · hash %@ → %@ · history %d → %d",
                   flatHard.maxStep, flatFeathered.maxStep, featherStepRatio,
                   flatHard.partial, flatFeathered.partial, featherPartialRatio,
                   flatHard.core, flatFeathered.core, featherCoreDrift * 100,
                   featherPhotoCore * 100,
                   String(fullHash.prefix(8)), String(featheredHash.prefix(8)),
                   depthBeforeFeather, historyAfterFeather))
        check(String(format: "羽化 0 → 0.40 边缘变软：无结构源上单像素最大跳变 %.4f → %.4f（%.2f×），半覆盖像素占比 %.3f → %.3f（%.2f×），50 %% 等值线面积 %.4f → %.4f（只漂 %.2f %%，模糊是对称的）；照片上换了像素，history +%d 一次快照",
                     flatHard.maxStep, flatFeathered.maxStep, featherStepRatio,
                     flatHard.partial, flatFeathered.partial, featherPartialRatio,
                     flatHard.core, flatFeathered.core, featherCoreDrift * 100,
                     historyAfterFeather - depthBeforeFeather),
              // The softening itself is the flat source's two numbers (a 3× drop in the sharpest
              // jump plus a 3× rise in the partly-covered share). The 50 % contour is a *sanity*
              // check, not the evidence: on a discrete grid a symmetric blur quantizes by 1–4 %.
              flatReady
              && historyAfterFeather == depthBeforeFeather + 1
              && featheredHash != fullHash
              && featherStepRatio > 0 && featherStepRatio < 0.35
              && featherPartialRatio > 3
              && featherCoreDrift > 0 && featherCoreDrift <= 0.05)

        let refineFlatStep = flatHard.maxStep > 0 ? flatRefined.maxStep / flatHard.maxStep : -1
        let refineCoreDrift = flatHard.core > 0
            ? abs(flatRefined.core - flatHard.core) / flatHard.core : -1
        log(String(format: "mask refine             0 → 0.90：无结构源 跳变 %.4f → %.4f (%.2f×) · 半覆盖 %.3f → %.3f · 半幅漂 %.2f %% ‖ 照片 覆盖 %.4f → %.4f · hash %@ → %@ · history %d → %d",
                   flatHard.maxStep, flatRefined.maxStep, refineFlatStep,
                   flatHard.partial, flatRefined.partial, refineCoreDrift * 100,
                   full.changed, refined.changed,
                   String(fullHash.prefix(8)), String(refinedHash.prefix(8)),
                   depthBeforeRefine, historyAfterRefine))
        check(String(format: "精修 0 → 0.90 平滑而不搬边界：无结构源上单像素最大跳变 %.4f → %.4f（%.2f×），半覆盖像素占比 %.3f → %.3f，50 %% 等值线面积 %.4f → %.4f（漂 %.2f %%，导向滤波在无结构处退化为对称平滑）；真实照片上同样换了像素（hash %@ → %@），history +%d",
                     flatHard.maxStep, flatRefined.maxStep, refineFlatStep,
                     flatHard.partial, flatRefined.partial,
                     flatHard.core, flatRefined.core, refineCoreDrift * 100,
                     String(fullHash.prefix(8)), String(refinedHash.prefix(8)),
                     historyAfterRefine - depthBeforeRefine),
              flatReady
              && historyAfterRefine == depthBeforeRefine + 1
              && refinedHash != fullHash
              && refineFlatStep > 0 && refineFlatStep < 0.75
              && refineCoreDrift < 0.05
              && abs(refined.changed - full.changed) > 0.01)

        // MARK: 12.5 the local sliders — ±2 EV, and bit-exact at 0

        let depthBeforeExposure = session.history.count
        session.setMaskAdjustment(mask.id, .exposure, 0, commit: true)
        guard let zeroFrame = shot() else {
            fail("蒙版参数：0 EV 帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        session.setMaskAdjustment(mask.id, .exposure, 2, commit: true)
        guard let plusFrame = shot() else {
            fail("蒙版参数：+2 EV 帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        session.setMaskAdjustment(mask.id, .exposure, -2, commit: true)
        guard let minusFrame = shot() else {
            fail("蒙版参数：−2 EV 帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        let zero = frameDelta(zeroFrame.texture, against: base.texture)
        let plus = frameDelta(plusFrame.texture, against: base.texture)
        let minus = frameDelta(minusFrame.texture, against: base.texture)
        log(String(format: "mask exposure           +2 EV 均值 %.4f · 0 EV %.4f · −2 EV %.4f（0 EV 与无蒙版帧 %@）",
                   plus.mean, zero.mean, minus.mean,
                   zeroFrame.displayHash == base.displayHash ? "位精确相等" : "不一致"))
        check(String(format: "曝光滑杆 ±2 EV 改变像素：均值 +2 %.4f > 0 %.4f > −2 %.4f（各差 %.4f / %.4f），三帧 hash 两两不同，history +%d",
                     plus.mean, zero.mean, minus.mean,
                     plus.mean - zero.mean, zero.mean - minus.mean,
                     session.history.count - depthBeforeExposure),
              plus.mean > zero.mean && zero.mean > minus.mean
              && (plus.mean - zero.mean) > 0.002 && (zero.mean - minus.mean) > 0.002
              && Set([plusFrame.displayHash, zeroFrame.displayHash,
                      minusFrame.displayHash].compactMap { $0 }).count == 3
              && session.history.count == depthBeforeExposure + 3)
        check("曝光回到 0 时这一帧与“完全没有蒙版”位精确相等（M1-6 恒等分支：无调整的蒙版不改变任何像素）",
              zeroFrame.displayHash == base.displayHash && zero.changed == 0)

        session.setMaskAdjustment(mask.id, .exposure, 2, commit: true)

        // MARK: 12.6 rename — no render, but one snapshot (and why)

        let depthBeforeRename = session.history.count
        let hashBeforeRename = shot()?.displayHash
        let keysBefore = current()
        let docBeforeRename = documentHash(session.edit)
        let renamed = session.renameMask(mask.id, to: "高光主体")
        let keysAfter = current()
        let hashAfterRename = shot()?.displayHash
        let docAfterRename = documentHash(session.edit)
        log("mask rename             \(renamed ? "“高光主体”" : "失败") · 像素 hash \(hashBeforeRename?.prefix(8) ?? "nil")… → \(hashAfterRename?.prefix(8) ?? "nil")… · key 变了吗 \(keysBefore?.selectionKey != keysAfter?.selectionKey || keysBefore?.applyKey != keysAfter?.applyKey) · 文档 hash 变了吗 \(docBeforeRename != docAfterRename) · history \(depthBeforeRename) → \(session.history.count)")
        check("改名“高光主体”：像素 hash 不变、selectionKey/applyKey 都不变（Core: name 不在任何键里），文档 hash 变（JSON 里有名字），history +1 —— 这一条历史不重渲任何像素，因为 isSemanticallyIdentical 按值比 masks、名字在内",
              renamed && keysAfter?.name == "高光主体"
              && hashAfterRename != nil && hashAfterRename == hashBeforeRename
              && keysBefore?.selectionKey == keysAfter?.selectionKey
              && keysBefore?.applyKey == keysAfter?.applyKey
              && docAfterRename != docBeforeRename
              && session.history.count == depthBeforeRename + 1)

        // MARK: 12.7 ▲▼ — the list order moves, the key material does not

        guard let second = session.addMask(kind: .radialGradient) else {
            fail("蒙版参数：第二个蒙版没有建出来")
            loupe.autoRenderEnabled = true
            return
        }
        let orderBefore = session.edit.masks.map(\.id)
        let materialBefore = session.edit.maskSelectionMaterial
        let docBeforeMove = documentHash(session.edit)
        let depthBeforeMove = session.history.count
        session.selectMask(second.id)
        pump(0.15)
        let moved = session.moveMask(second.id, by: -1)
        let orderAfter = session.edit.masks.map(\.id)
        let expectedOrder = [second.id] + orderBefore.filter { $0 != second.id }
        pump(0.2)
        let probeOrder = maskProbe(in: window.contentView)?.listOrder
        log("mask order              \(orderBefore.map { String($0.suffix(4)) }) → \(orderAfter.map { String($0.suffix(4)) }) · 键材质 \(materialBefore == session.edit.maskSelectionMaterial ? "不变（按 id 排序）" : "变了") · 面板 \(probeOrder ?? []) · history \(depthBeforeMove) → \(session.history.count)")
        check("上/下移改变顺序：文档数组重排为 \(orderAfter.map { String($0.suffix(4)) })、落盘 JSON 变了、面板列表跟着变、history +1；而键材质不变——Core 的组合顺序与键都按 id 字典序（D6），所以上下移是文档顺序，不是渲染顺序（这不是回归，是 005/M4 §3 的排序规则）",
              moved && orderAfter == expectedOrder
              && documentHash(session.edit) != docBeforeMove
              && session.edit.maskSelectionMaterial == materialBefore
              && session.history.count == depthBeforeMove + 1
              && probeOrder == session.edit.masks.map(\.name))

        // MARK: 12.8 the blend picker — subtract cuts a hole

        session.selectMask(mask.id)
        guard let beforeBlend = shot() else {
            fail("蒙版参数：混合前帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        let unionArea = frameDelta(beforeBlend.texture, against: base.texture).changed
        session.writeMask(mask.id, label: "加第二个组件", commit: true) { m in
            m.components.append(MaskComponent(id: "c-\(UUID().uuidString)", op: .add, invert: false,
                                              feather: 0.02,
                                              shape: .radialGradient(RadialGradientShape(
                                                  center: NormalizedPoint(0.5, 0.5),
                                                  radius: NormalizedPoint(0.12, 0.12),
                                                  angle: 0))))
        }
        guard let unionFrame = shot() else {
            fail("蒙版参数：并集帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        let twoAddComponents = frameDelta(unionFrame.texture, against: base.texture).changed
        let depthBeforeOp = session.history.count
        let wroteOp = session.setMaskCombineOp(mask.id, component: 1, .subtract)
        guard let subtractFrame = shot() else {
            fail("蒙版参数：减去帧渲染失败")
            loupe.autoRenderEnabled = true
            return
        }
        let subtracted = frameDelta(subtractFrame.texture, against: base.texture).changed
        log(String(format: "mask blend              单组件 %.4f · 两个 add（并集）%.4f · 第二个改 subtract %.4f（−%.4f）· history %d → %d",
                   unionArea, twoAddComponents, subtracted, twoAddComponents - subtracted,
                   depthBeforeOp, session.history.count))
        check(String(format: "混合模式生效：第二个组件 add 时并集覆盖 %.4f（与单组件 %.4f 一致），改 subtract 后中心被擦掉 → %.4f（−%.4f），history +%d",
                     twoAddComponents, unionArea, subtracted, twoAddComponents - subtracted,
                     session.history.count - depthBeforeOp),
              wroteOp && abs(twoAddComponents - unionArea) < 0.01
              && subtracted < twoAddComponents - 0.01
              && session.history.count == depthBeforeOp + 1)

        // MARK: 12.9 a drag: ten writes, one snapshot, a few frames

        loupe.autoRenderEnabled = true
        loupe.hashesFrames = false
        // The edit path only renders while the loupe is the shown module (`LoupeController`'s
        // debounce guard checks `session.mode == .loupe`); a previous section may have left us in
        // the grid, which would make "10 ticks → 0 renders" look like a debounce bug.
        session.mode = .loupe
        pump(0.05)
        let depthBeforeDrag = session.history.count
        let rendersBeforeDrag = loupe.editRenderCount
        let startsBeforeDrag = loupe.editRenderStarts
        for tick in 1...10 {
            // Exactly what a slider tick does: no commit, only `applyEdit` (see `sliderRow`).
            session.setMaskAdjustment(mask.id, .hue, Double(tick) * 2)
            pump(0.012)
        }
        session.commitEdit(label: "局部色相")
        _ = waitForFrame(loupe, after: rendersBeforeDrag, timeout: 30)
        let dragRenders = loupe.editRenderCount - rendersBeforeDrag
        let dragStarts = loupe.editRenderStarts - startsBeforeDrag
        log("mask drag               10 ticks → \(dragStarts) render start(s) / \(dragRenders) presented · history \(depthBeforeDrag) → \(session.history.count) · hue \(current()?.adjustments.hue ?? -1)°")
        // Assert the debounce, not the ladder: a presented frame also needs a resident rung, and
        // that is the decode ladder's business (a mask edit needs no decode at all).
        check("滑杆拖动中 10 次写入只产生 1 个快照（history +\(session.history.count - depthBeforeDrag)，松手才 commit）与 \(dragStarts) 次渲染启动（50 ms 防抖 + 单飞）",
              session.history.count == depthBeforeDrag + 1
              && dragStarts >= 1 && dragStarts <= 2
              && current()?.adjustments.hue == 20)

        // MARK: 12.10 the panel itself

        pump(0.2)
        let required = MaskLevelParameter.allCases.map(\.label) + ["反转", "混合"]
            + MaskAdjustmentParameter.allCases.map(\.label)
        guard let probe = maskProbe(in: window.contentView) else {
            fail("检查器里找不到蒙版参数面板的读回点（MaskPanelProbe）")
            for m in session.edit.masks { session.deleteMask(m.id) }
            loupe.autoRenderEnabled = true
            return
        }
        let missing = required.filter { !probe.rows.contains($0) }
        let rowText = current().map { MaskRowSummary.text($0) } ?? "—"
        log("mask panel rows         \(probe.rows.joined(separator: " / "))")
        log("mask panel list         \(probe.listOrder.joined(separator: " | ")) · 选中 \(probe.selectedName) · 行文字 \(rowText)")
        check("面板在活视图树里露出蒙版级 + 局部调整的全部 \(required.count) 个控件（缺：\(missing.isEmpty ? "无" : missing.joined(separator: "、"))），改名已同步到面板，列表行写着“\(rowText)”",
              missing.isEmpty && probe.rows.count == required.count
              && probe.selectedName == (current()?.name ?? "—")
              && probe.listOrder.contains(current()?.name ?? "—")
              && rowText.hasPrefix("径向渐变 · 局部 ")
              && rowText.hasSuffix(" 项"))

        // Leave the document as clean as the checks found it.
        for m in session.edit.masks { session.deleteMask(m.id) }
        session.setShowMask(nil)
        session.maskTool = .off
        loupe.autoRenderEnabled = true
    }

    // MARK: - 倍率菜单（显示 ▸ 适应窗口 / 1:1 … 8:1 / 放大 / 缩小）

    /// The zoom commands, asserted on what the renderer is actually asked for:
    ///
    ///   · all four stops exist in the 显示 menu and are ticked exactly one at a time;
    ///   · after a stop, the frame's `canvas` is the viewport and its `zoom` is the stop, and the
    ///     visible window is `viewport / zoom` source pixels (the crop clamped);
    ///   · ⌘= and ⌘− walk the ladder through the real menu key equivalents;
    ///   · none of it is an edit: the document hash, the history and `editRevision` do not move.
    private func checkZoomMenu(session: CatalogSession, loupe: LoupeController,
                               controller: EditorWindowController, window: NSWindow,
                               asset: Asset, url: URL) {
        loupe.autoRenderEnabled = false
        let viewport = loupe.viewportPixels
        let document = MaskViewState.documentOnly(session.edit)
        let hashBefore = documentHash(session.edit)
        let historyBefore = session.history.count
        let revisionBefore = session.editRevision

        let items = zoomMenuItems()
        let titles = items.map(\.title).joined(separator: " / ")
        check("显示菜单有四档倍率 + 适应窗口 + 放大/缩小（\(titles)）",
              items.count == 4 && items.map(\.tag) == [1, 2, 4, 8]
              && menuItem(#selector(EditorWindowController.zoomFitAction(_:))) != nil
              && menuItem(#selector(EditorWindowController.zoomInAction(_:))) != nil
              && menuItem(#selector(EditorWindowController.zoomOutAction(_:))) != nil)

        /// What the renderer would be asked for, at the camera's current state.
        func renderShape() -> (canvas: ImageSize, zoom: Double, window: ImageSize)? {
            guard let frame = try? loupe.makeFrame(asset: asset, url: url, viewport: viewport,
                                                   decodeScale: 0.5, edit: document,
                                                   state: loupe.viewState) else { return nil }
            return (frame.canvas, frame.zoom, frame.window)
        }

        var stopResults: [String] = []
        var stopsOK = true
        for item in items {
            controller.zoomStopAction(item)
            pump(0.05)
            let shape = renderShape()
            let ticked = items.filter { controller.validateMenuItem($0) && $0.state == .on }
            let label = loupe.zoomLabel
            let expectedWindow = expectedWindowSize(loupe: loupe, zoom: Double(item.tag))
            stopResults.append(String(format: "%d:1→canvas %@ zoom %.0f window %@ label %@ ticked %d",
                                      item.tag,
                                      shape.map { "\($0.canvas.width)×\($0.canvas.height)" } ?? "nil",
                                      shape?.zoom ?? -1,
                                      shape.map { "\($0.window.width)×\($0.window.height)" } ?? "nil",
                                      label, ticked.count))
            var stopOK = true
            if let shape {
                stopOK = shape.canvas == viewport
                    && abs(shape.zoom - Double(item.tag)) < 0.001
                    && abs(shape.window.width - Int(expectedWindow.width)) <= 1
                    && abs(shape.window.height - Int(expectedWindow.height)) <= 1
            } else {
                stopOK = false
            }
            stopOK = stopOK && ticked.count == 1 && ticked.first?.tag == item.tag
            stopOK = stopOK && label == (item.tag == 1 ? "1:1"
                                            : String(format: "%.1f:1", Double(item.tag)))
            stopsOK = stopsOK && stopOK
        }
        log("zoom stops              \(stopResults.joined(separator: " · "))")
        check("四档倍率切换后 canvas == 视口、渲染倍率 == 档位、可见窗口 == 视口/倍率，且状态条文字同步（\(stopResults.joined(separator: " · "))）",
              stopsOK)

        // ⌘0 → fit; ⌘= → 1:1; ⌘= → 2:1; ⌘− → 1:1; ⌘− → fit.
        //
        // The key equivalent is posted through the main menu, which is the shipped path. A harness
        // launched from a shell cannot hold key-window focus, so AppKit finds the item and then has
        // nowhere to send its nil-target action; when that happens the same action is delivered to
        // the window controller — the responder AppKit would have chosen — and the log says which
        // route ran. The *wiring* (item + key equivalent + action) is asserted either way.
        func shortcut(_ characters: String) -> (matched: Bool, moved: Bool, via: String) {
            let before = loupe.viewState.isActualSize ? "a:\(loupe.zoomLabel)" : "f"
            let matched = performMenuKey(characters, modifiers: [.command], window: window)
            pump(0.05)
            var after = loupe.viewState.isActualSize ? "a:\(loupe.zoomLabel)" : "f"
            var via = "menu"
            if after == before, let item = menuKeyItem(characters, modifiers: [.command]),
               let action = item.action, controller.responds(to: action) {
                _ = controller.perform(action, with: item)
                pump(0.05)
                after = loupe.viewState.isActualSize ? "a:\(loupe.zoomLabel)" : "f"
                via = "controller"
            }
            return (matched, after != before, via)
        }

        let fitKey = shortcut("0")
        let fitState = loupe.viewState.isActualSize
        let zoomInKey = shortcut("=")
        let afterIn = loupe.zoomLabel
        _ = shortcut("=")
        let afterSecondIn = loupe.zoomLabel
        let zoomOutKey = shortcut("-")
        let afterOut = loupe.zoomLabel
        _ = shortcut("-")
        let backToFit = loupe.viewState.isActualSize
        log("zoom keys               ⌘0 matched=\(fitKey.matched) via \(fitKey.via) → actual \(fitState) · ⌘= \(zoomInKey.matched)/\(zoomInKey.via) → \(afterIn) · ⌘= → \(afterSecondIn) · ⌘− \(zoomOutKey.matched)/\(zoomOutKey.via) → \(afterOut) · ⌘− → fit \(!backToFit)")
        check("⌘0/⌘=/⌘− 命中真实菜单快捷键（matched \(fitKey.matched)/\(zoomInKey.matched)/\(zoomOutKey.matched)）并走完倍率阶梯：适应窗口 → \(afterIn) → \(afterSecondIn) → \(afterOut) → 适应窗口（\(!backToFit)）",
              fitKey.matched && zoomInKey.matched && zoomOutKey.matched
              && !fitState && afterIn == "1:1" && afterSecondIn == "2.0:1"
              && afterOut == "1:1" && !backToFit)

        let hashAfter = documentHash(session.edit)
        log("zoom vs document        hash \(hashBefore.prefix(8))… → \(hashAfter.prefix(8))… · history \(session.history.count) · editRevision +\(session.editRevision - revisionBefore)")
        check("⌘= / ⌘− / 倍率菜单不改文档：hash 不变（\(hashBefore.prefix(8))…）、history 仍 \(historyBefore) 条、editRevision +\(session.editRevision - revisionBefore)",
              hashAfter == hashBefore && session.history.count == historyBefore
              && session.editRevision == revisionBefore)

        loupe.zoomToFit()
        loupe.autoRenderEnabled = true
    }

    // MARK: - helpers for the three sections above

    /// The inspector's histogram card, wherever SwiftUI put it.
    private func findHistogramCard(in view: NSView?) -> HistogramCardView? {
        guard let view else { return nil }
        if let card = view as? HistogramCardView { return card }
        for subview in view.subviews {
            if let found = findHistogramCard(in: subview) { return found }
        }
        return nil
    }

    /// The four 倍率 items of 显示, in ladder order.
    private func zoomMenuItems() -> [NSMenuItem] {
        guard let view = NSApp.mainMenu?.items.compactMap(\.submenu)
            .first(where: { $0.title == "显示" }) else { return [] }
        return view.items.filter { $0.action == #selector(EditorWindowController.zoomStopAction(_:)) }
    }

    /// What `viewport / zoom` is in source pixels, clamped to the crop — computed through
    /// `LoupeFraming`, i.e. the same projection the loupe hit-tests with, not from the frame result.
    private func expectedWindowSize(loupe: LoupeController, zoom: Double) -> (width: Double, height: Double) {
        guard let framing = loupe.framing() else { return (0, 0) }
        let state = LoupeViewState(mode: .actual, zoom: zoom,
                                   centerX: framing.cropOriginX + framing.cropWidthPixels / 2,
                                   centerY: framing.cropOriginY + framing.cropHeightPixels / 2)
        return framing.windowSize(of: state)
    }

    /// A canonical hash of the document: JSON with sorted keys, SHA-256. Two documents that render
    /// the same bytes encode the same way, so this is the "did anything move" question in one number.
    private func documentHash(_ model: EditModel) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(MaskViewState.documentOnly(model)) else {
            return "unencodable"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Post a key equivalent through the **main menu** — the shipped shortcut path.
    @discardableResult
    private func performMenuKey(_ characters: String, modifiers: NSEvent.ModifierFlags,
                                window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters,
                                           charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: 0) else { return false }
        return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
    }

    /// The menu item a key equivalent would fire, so the harness can deliver its action itself when
    /// AppKit has no key window to resolve the responder chain against.
    private func menuKeyItem(_ characters: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        func find(in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.keyEquivalent == characters,
                   item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
                    == modifiers.intersection(.deviceIndependentFlagsMask) {
                    return item
                }
                if let sub = item.submenu, let hit = find(in: sub) { return hit }
            }
            return nil
        }
        return find(in: NSApp.mainMenu)
    }

    /// Clipped fraction per channel (R, G, B, Rec.709 luma) counted from a presented texture.
    ///
    /// The independent half of "the card's percentage is Core's": Core measures a *downsampled*
    /// grid, this walks the frame itself, and at the smoke's canvas size the two describe the same
    /// pixels — which is what makes the assertion an equality.
    private func clipFractions(of texture: MTLTexture) -> [Double] {
        let width = texture.width, height = texture.height
        let raw = rgba16(texture)
        let threshold = Float(Histogram.clipHighThreshold)
        let weights = (Float(Histogram.lumaWeights.r), Float(Histogram.lumaWeights.g),
                       Float(Histogram.lumaWeights.b))
        var hits = [0, 0, 0, 0]
        for i in stride(from: 0, to: raw.count, by: 4) {
            let r = Float(Float16(bitPattern: raw[i]))
            let g = Float(Float16(bitPattern: raw[i + 1]))
            let b = Float(Float16(bitPattern: raw[i + 2]))
            let luma = weights.0 * r + weights.1 * g + weights.2 * b
            if r > threshold { hits[0] += 1 }
            if g > threshold { hits[1] += 1 }
            if b > threshold { hits[2] += 1 }
            if luma > threshold { hits[3] += 1 }
        }
        let total = Double(max(1, width * height))
        return hits.map { Double($0) / total }
    }

    /// The frame's average display colour, sRGB-encoded — a `ColorRangeShape` sample taken "from the
    /// picture" the way a user's eyedropper would.
    private func averageSample(of texture: MTLTexture) -> [Double] {
        let width = texture.width, height = texture.height
        let raw = rgba16(texture)
        let stepY = max(1, height / 64)
        let stepX = max(1, width / 64)
        var sum = (r: 0.0, g: 0.0, b: 0.0)
        var count = 0.0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = (y * width + x) * 4
                sum.r += Double(Float(Float16(bitPattern: raw[offset])))
                sum.g += Double(Float(Float16(bitPattern: raw[offset + 1])))
                sum.b += Double(Float(Float16(bitPattern: raw[offset + 2])))
                count += 1
                x += stepX
            }
            y += stepY
        }
        guard count > 0 else { return [0.5, 0.5, 0.5] }
        return [min(max(sum.r / count, 0), 1), min(max(sum.g / count, 0), 1),
                min(max(sum.b / count, 0), 1)]
    }

    /// Fraction of pixels that differ between two rendered display images — the pure-colour probe's
    /// "how much of the picture did the mask select".
    private func differingFraction(_ a: DisplayImage, _ b: DisplayImage, threshold: Float = 1.0 / 512) -> Double {
        guard a.width == b.width, a.height == b.height, a.width > 0 else { return -1 }
        var differing = 0
        let count = a.width * a.height
        for i in 0..<count {
            let base = i * 4
            for c in 0..<3 {
                if abs(Float(a.rgba[base + c]) - Float(b.rgba[base + c])) > threshold {
                    differing += 1
                    break
                }
            }
        }
        return Double(differing) / Double(count)
    }

    /// Linear light → sRGB-encoded 0…1, the storage space of `ColorRangeShape.samples`.
    private func srgbEncoded(_ linear: Double) -> Double {
        let v = min(max(linear, 0), 1)
        return v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055
    }

    // MARK: bench

    /// 10k-row placeholder scroll: main-thread p99, honestly labelled "placeholders, no decode".
    @discardableResult
    public func bench(rows expected: Int?) -> Int32 {
        do {
            try windowController.openLibrary(at: libraryURL)
        } catch {
            fail("could not open library: \(error.localizedDescription)")
            return finish()
        }
        guard let window = windowController.window else { return finish() }
        window.setContentSize(NSSize(width: 1600, height: 940))
        window.orderFrontRegardless()
        pump(0.6)

        let root = windowController.rootView!
        let gridView = root.gridController.collectionView
        let rows = windowController.session.assets.count
        log("grid scroll bench: \(rows) rows, thumbnails stream in from the cache (decode is off the main thread)")
        gridView.layoutSubtreeIfNeeded()
        guard let scroller = gridView.enclosingScrollView else {
            fail("grid has no scroll view")
            return finish()
        }
        let rowHeight = max(1, root.gridController.metrics.rowHeight)
        let maxY = max(0, CGFloat(rows) / CGFloat(max(1, root.gridController.metrics.columns)) * rowHeight
                       - scroller.contentView.bounds.height)
        var samples: [Double] = []
        let steps = 140
        for step in 0..<steps {
            let y = maxY * CGFloat(step) / CGFloat(max(1, steps - 1))
            let t0 = CFAbsoluteTimeGetCurrent()
            scroller.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroller.reflectScrolledClipView(scroller.contentView)
            gridView.layoutSubtreeIfNeeded()
            gridView.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        samples.sort()
        func pct(_ p: Double) -> Double { samples[min(samples.count - 1, Int(Double(samples.count - 1) * p))] }
        log(String(format: "scroll step p50 %.2f ms  p95 %.2f ms  p99 %.2f ms  max %.2f ms  (%d steps)",
                   pct(0.5), pct(0.95), pct(0.99), samples.last ?? 0, samples.count))

        // Loupe: first frame (decode included) vs second frame (graph cache hit).
        if let asset = windowController.session.assets.first(where: { $0.kind == .raw }),
           let url = windowController.session.fileURL(for: asset) {
            windowController.session.activate(asset.id)
            pump(0.2)
            let viewport = root.loupeController.viewportPixels
            let first = try? root.loupeController.makeFrame(asset: asset, url: url, viewport: viewport, decodeScale: 0.5)
            let second = try? root.loupeController.makeFrame(asset: asset, url: url, viewport: viewport, decodeScale: 0.5)
            if let first, let second {
                log(String(format: "loupe first frame  %.0f ms (decode %.0f ms, cache %@)",
                           first.decodeMilliseconds + first.renderMilliseconds, first.decodeMilliseconds,
                           first.usedCachedDecode ? "hit" : "miss"))
                log(String(format: "loupe second frame %.1f ms (decode %.0f ms, cache %@)",
                           second.renderMilliseconds,
                           second.usedCachedDecode ? 0 : second.decodeMilliseconds,
                           second.usedCachedDecode ? "hit" : "miss"))
            }
        }
        return finish()
    }

    // MARK: helpers

    private func log(_ s: String) { lines.append(s); print(s) }

    private func check(_ what: String, _ ok: Bool) {
        if ok {
            log("  PASS  " + what)
        } else {
            log("  FAIL  " + what)
            failures.append(what)
        }
    }

    private func fail(_ what: String) {
        log("  FAIL  " + what)
        failures.append(what)
    }

    private func finish() -> Int32 {
        if failures.isEmpty {
            log("SMOKE PASS (\(lines.filter { $0.contains("PASS") }.count) checks)")
            return 0
        }
        log("SMOKE FAIL (\(failures.count) failures)")
        for f in failures { print("  - \(f)") }
        return 1
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func capture(window: NSWindow, name: String) {
        guard let view = window.contentView else { return }
        let rect = view.bounds
        guard rect.width > 1, rect.height > 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return }
        view.cacheDisplay(in: rect, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = screenshotDirectory.appendingPathComponent(name)
        try? data.write(to: url)
        log("screenshot              \(url.path)")
    }

    /// Write an S4 texture as a PNG. Proves the loupe produced real pixels, which a window
    /// screenshot cannot (a `CAMetalLayer` is not part of `cacheDisplay`).
    private func write(texture: MTLTexture, name: String) {
        let w = texture.width, h = texture.height
        var raw = [UInt16](repeating: 0, count: w * h * 4)
        raw.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: w * 4 * 2,
                             from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: raw.count, by: 4) {
            for c in 0..<3 {
                let v = Float(Float16(bitPattern: raw[i + c]))
                rgba[i + c] = UInt8(max(0, min(255, v * 255)))
            }
            rgba[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        let url = screenshotDirectory.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        log("screenshot              \(url.path)")
    }
}