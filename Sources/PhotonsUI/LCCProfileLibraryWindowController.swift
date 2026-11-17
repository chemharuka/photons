import AppKit
import SwiftUI
import PhotonsLocalization

/// One independent manager shared by Settings, LCC correction and panorama stitching.
@MainActor
final class LCCProfileLibraryWindowController: NSWindowController {
    static let shared = LCCProfileLibraryWindowController()
    let model: LCCProfileLibraryModel

    init(model: LCCProfileLibraryModel = .shared) {
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("bba6488b8640")
        window.minSize = NSSize(width: 760, height: 580)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: LCCProfileLibraryView(model: model))
        host.sizingOptions = []
        window.contentView = host
        super.init(window: window)
        window.center()
        window.setFrameAutosaveName("PhotonsLCCProfileLibrary")
    }
    required init?(coder: NSCoder) { fatalError("no nib") }

    func open(select id: UUID? = nil) {
        model.refresh(select: id)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
