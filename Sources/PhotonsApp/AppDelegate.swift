import AppKit
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

        if let seconds = args.value("--seconds").flatMap(Double.init) {
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
