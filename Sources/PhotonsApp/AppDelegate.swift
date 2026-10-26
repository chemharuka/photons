import AppKit
import PhotonsCatalog
import PhotonsUI

/// Launch options. Deliberately hand-parsed (same reason as `photonsctl`: the acceptance harness
/// must keep working while the app is mid-refactor).
struct LaunchArguments {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ argv: [String]) {
        var i = 1
        let valueFlags: Set<String> = ["--library", "--ui-smoke", "--ui-bench", "--expect-rows",
                                       "--shots", "--seconds"]
        while i < argv.count {
            let a = argv[i]
            if valueFlags.contains(a), i + 1 < argv.count {
                values[a] = argv[i + 1]
                i += 2
            } else if a.hasPrefix("--") {
                flags.insert(a)
                i += 1
            } else {
                i += 1
            }
        }
    }

    func value(_ key: String) -> String? { values[key] }
    func has(_ key: String) -> Bool { flags.contains(key) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [EditorWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        let args = LaunchArguments(CommandLine.arguments)

        if let smoke = args.value("--ui-smoke") {
            runSmoke(args, library: smoke, bench: false)
            return
        }
        if let bench = args.value("--ui-bench") {
            runSmoke(args, library: bench, bench: true)
            return
        }

        let controller = newWindow()
        if let path = args.value("--library") {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                try controller.openLibrary(at: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if args.has("--thumb-probe") {
            let after = Double(args.value("--seconds") ?? "5") ?? 5
            DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                self.thumbnailProbe(controller)
                NSApp.terminate(nil)
            }
        } else if let seconds = args.value("--seconds").flatMap(Double.init) {
            // Used by `make app`'s launch check: prove the window comes up and stays up, then leave.
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                NSApp.terminate(nil)
            }
        }
    }

    private func newWindow() -> EditorWindowController {
        let controller = EditorWindowController()
        controllers.append(controller)
        return controller
    }

    /// `--thumb-probe`: print the facts that decide whether a cell draws pixels, then quit.
    ///
    /// This exists because the bug it was written for was *silent*: the photo list painted its
    /// placeholder colour and never asked for an image, while every counter in the thumbnail layer
    /// looked healthy (nobody was asking). One command, no screenshots, counts and key digests only:
    ///
    ///     .build/Photons.app/Contents/MacOS/Photons --library <pkg> --thumb-probe --seconds 8
    @MainActor
    private func thumbnailProbe(_ controller: EditorWindowController) {
        let session = controller.session
        let grid = controller.rootView.gridController
        let pane = controller.rootView.browserPane
        func out(_ s: String) { print("thumb-probe  \(s)"); fflush(stdout) }

        out("library            \(session.libraryURL?.path ?? "nil")")
        if let cache = session.thumbnailCache {
            out("cache root         \(cache.root.path) · \(cache.inventory().count) jpg")
        } else {
            out("cache              nil ← thumbnailCache is nil: provider() returns nil, nothing is requested")
        }
        let m = grid.metrics
        out(String(format: "grid cell          %.1f × %.1f pt @%.0fx → tier %@",
                   m.itemSize.width, m.itemSize.height,
                   controller.window?.backingScaleFactor ?? 0, grid.currentThumbnailTier.rawValue))
        out("grid cells         \(grid.visibleThumbnailCount)/\(grid.visibleCellCount) drawing a real image · pending \(grid.pendingThumbnailRequests) · \(grid.thumbnailStats.summary)")
        out("browser            mode \(controller.rootView.browserMode.rawValue) · \(pane.photoRowCount) rows → tier \(pane.currentThumbnailTier.rawValue)")
        out("list rows          \(pane.visibleThumbnailCount)/\(pane.visiblePhotoRowCount) drawing a real image · pending \(pane.pendingThumbnailRequests)")
        out("list stats         \(pane.thumbnailStats.summary)")
        if let gridProvider = grid.thumbnailProviderForSmoke, let listProvider = pane.thumbnailProviderForSmoke {
            out("shared provider    \(gridProvider === listProvider ? "yes — one service, one LRU" : "NO — two instances")")
        } else {
            out("shared provider    missing (grid \(grid.thumbnailProviderForSmoke == nil ? "nil" : "ok"), list \(pane.thumbnailProviderForSmoke == nil ? "nil" : "ok"))")
        }
        for (i, asset) in session.assets.prefix(3).enumerated() {
            let listKey = ThumbKey.preview(contentHash: asset.contentHash, tier: pane.currentThumbnailTier)
            let gridKey = ThumbKey.preview(contentHash: asset.contentHash, tier: grid.currentThumbnailTier)
            let onDisk = { (key: ThumbKey) in
                session.thumbnailCache.map { FileManager.default.fileExists(atPath: $0.url(for: key).path) } ?? false
            }
            out("asset[\(i)]          \(asset.filename) · list \(asset.ext)/\(listKey.tier.rawValue) …\(String(listKey.digest.prefix(8))) onDisk=\(onDisk(listKey)) · grid \(gridKey.tier.rawValue) onDisk=\(onDisk(gridKey)) · fileURL=\(session.fileURL(for: asset)?.lastPathComponent ?? "nil")")
        }
        out("grid reloads       \(grid.reloadCount) · assets \(session.assets.count) · mode \(session.mode.rawValue)")
    }

    private func runSmoke(_ args: LaunchArguments, library: String, bench: Bool) {
        let controller = newWindow()
        controller.showWindow(nil)
        controller.window?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        let url = URL(fileURLWithPath: (library as NSString).expandingTildeInPath)
        let shots = URL(fileURLWithPath: ((args.value("--shots") ?? "local/out") as NSString).expandingTildeInPath)
        let expected = args.value("--expect-rows").flatMap(Int.init)
        let runner = UISmokeRunner(windowController: controller,
                                   libraryURL: url,
                                   expectedRows: expected,
                                   screenshotDirectory: shots)
        let code = bench ? runner.bench(rows: expected) : runner.run()
        fflush(stdout)
        exit(code)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
