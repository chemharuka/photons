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

        // 4. filmstrip is the second browser and shares the selection
        windowController.showBrowserAsFilmstrip()
        pump(0.3)
        let strip = root.filmstripController.collectionView
        check("filmstrip item count \(strip.numberOfItems(inSection: 0)) == library rows \(rows)",
              strip.numberOfItems(inSection: 0) == rows)
        check(String(format: "filmstrip container %.0f pt == 122", root.geometry.filmstrip?.height ?? 0),
              abs((root.geometry.filmstrip?.height ?? 0) - WorkspaceLayout.filmstripHeight) < 0.01)
        if let id = session.anchorID {
            check("filmstrip shares the grid selection",
                  (strip.selectionIndexPaths.first.map { session.assets[safe: $0.item]?.id }) == id
                  || session.selection.contains(id))
        }
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
        } else {
            fail("no asset for the loupe")
        }

        return finish()
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
        log("grid scroll bench: \(rows) rows, placeholders only (no decode, no thumbnails)")
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
