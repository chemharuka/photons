import AppKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import PhotonsCatalog
import PhotonsCore

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
        } else {
            fail("no asset for the loupe")
        }

        return finish()
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
