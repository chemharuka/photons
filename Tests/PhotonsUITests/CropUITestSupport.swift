import XCTest
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// One packaged library with one `9520×6336` Leica row — the fixture every 072 suite builds on.
struct CropTestLibrary {
    let package: URL
    let catalog: Catalog
    let assetID: String
    let asset: Asset
}

/// Shared fixtures for the 072 (裁切/变换 第二阶段) suites.
///
/// Every one of them needs the same thing: a **real** library with one photo in it, because the paths
/// they measure are the real ones (`beginCropTool` refuses without an anchor, `maskSourceSize` is the
/// upright frame the renderer ingested, the inspector gate is on the real hosting view). No Metal, no
/// decode, no 66 MP file: the geometry below is all `CropMath` / `LoupeFraming` arithmetic.
enum CropUITestSupport {

    /// `9520×6336` — the Leica SL3 file the user pinned in 049/072 (`60.3 Mpx`, 3:2 upright).
    static let stored = ImageSize(width: 9520, height: 6336)

    /// One library package with one asset row. `width`/`height` are the *stored* dimensions; the
    /// upright frame the loupe measures with is `CatalogSession.maskSourceSize`.
    @MainActor
    static func makeLibrary(in workDir: URL, width: Int? = CropUITestSupport.stored.width,
                            height: Int? = CropUITestSupport.stored.height) throws -> CropTestLibrary {
        _ = NSApplication.shared
        let folder = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let package = folder.appendingPathComponent("Spec.\(LibraryLayout.packageExtension)")
        let catalog = try Catalog.create(at: package)
        let src = folder.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        let name = "L1030433.dng"
        try Data([0x00]).write(to: src.appendingPathComponent(name))

        let id = UUID().uuidString
        try catalog.dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO assets (id, source_root_id, rel_path, filename, ext, kind, size, mtime,
                                    content_hash, width, height, camera_make, camera_model, lens,
                                    imported_at, missing)
                VALUES ('\(id)', '\(root.id)', '\(name)', '\(name)', 'dng', 'raw', 1, 0,
                        '\(UUID().uuidString)',
                        \(width.map(String.init) ?? "NULL"), \(height.map(String.init) ?? "NULL"),
                        'Leica Camera AG', 'Leica SL3', 'Vario-Elmarit-SL 24-90',
                        '2026-10-27T00:00:00Z', 0)
                """)
        }
        return CropTestLibrary(package: package, catalog: catalog, assetID: id,
                               asset: try XCTUnwrap(try catalog.asset(id: id)))
    }

    /// A session on that library, opened on the photo, in 单图 mode, with the baseline snapshot.
    @MainActor
    static func makeSession(in workDir: URL, width: Int? = CropUITestSupport.stored.width,
                            height: Int? = CropUITestSupport.stored.height)
        throws -> (CatalogSession, Asset) {
        let library = try makeLibrary(in: workDir, width: width, height: height)
        let session = CatalogSession()
        try session.open(library.package)
        session.selectOnly(library.assetID)
        session.mode = .loupe
        session.loadEditForAnchor()          // the baseline snapshot a first apply needs
        return (session, library.asset)
    }

    /// A real editor window (its own session) opened on that library, with the photo anchored and the
    /// whole workspace **laid out** (the canvas needs a real size, or every projection is degenerate).
    @MainActor
    static func makeEditor(in workDir: URL) throws -> EditorWindowController {
        let library = try makeLibrary(in: workDir)
        let editor = EditorWindowController()
        try editor.openLibrary(at: library.package)
        editor.session.selectOnly(library.assetID)
        editor.session.mode = .loupe
        editor.rootView.loupeController.autoRenderEnabled = false
        editor.rootView.loupeController.collectsHistogram = false
        editor.window?.orderFront(nil)
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.rootView.needsLayout = true
        editor.rootView.layoutSubtreeIfNeeded()
        pump(0.05)
        editor.rootView.layoutSubtreeIfNeeded()
        return editor
    }

    /// The document's bytes — the honest way to say "nothing was written".
    @MainActor
    static func documentBytes(_ session: CatalogSession) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(session.edit)) ?? Data()
    }

    /// The same, as a hash string for a report line.
    @MainActor
    static func documentHash(_ session: CatalogSession) -> String {
        "\(documentBytes(session).hashValue)"
    }

    /// A real window with the real workspace root in it, laid out.
    @MainActor
    static func makeWorkspace(size: NSSize = NSSize(width: 1600, height: 1000))
        -> (window: NSWindow, root: WorkspaceRootView) {
        _ = NSApplication.shared
        let controller = EditorWindowController(size: size)
        let window = controller.window!
        window.orderFront(nil)
        window.setContentSize(size)
        window.contentView?.layoutSubtreeIfNeeded()
        pump(0.05)
        return (window, controller.rootView)
    }

    @MainActor
    static func pump(_ seconds: TimeInterval = 0.005) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// A mouse event in window coordinates, for the tests that drive AppKit's real dispatch.
    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow,
                      clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                           clickCount: clickCount, pressure: 1)!
    }
}
