import AppKit

/// The app process: `NSApplication` + one `AppDelegate`, no storyboard, no XIB.
///
/// SwiftPM cannot produce a real `.app` by itself, so `scripts/bundle-app.sh` assembles the bundle
/// (Info.plist + ad-hoc signature) around this executable; `make app` is the single command.
@main
enum PhotonsMain {
    /// `NSApplication.delegate` is weak: this keeps the delegate alive for the whole process.
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        Self.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
