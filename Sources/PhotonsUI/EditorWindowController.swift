import AppKit
import PhotonsCatalog

/// One editor window: titlebar contract, the workspace, and the commands the menu dispatches.
///
/// No `NSToolbar` (§2b item 1) and no storyboard/XIB anywhere: the window, its content and its
/// menus are built in code, which is what every surviving editor in the survey does.
public final class EditorWindowController: NSWindowController {

    public let session = CatalogSession()
    public private(set) var rootView: WorkspaceRootView!

    public init(size: NSSize = NSSize(width: 1440, height: 900)) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "Photons"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false      // only the title strip drags (Phos contract)
        window.minSize = WorkspaceLayout.minimumWindowSize
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)

        rootView = WorkspaceRootView(session: session)
        window.contentView = rootView
        window.setFrameAutosaveName("PhotonsEditorWindow")
        if window.frame.width < WorkspaceLayout.minimumWindowSize.width {
            window.setContentSize(size)
        }
        window.center()
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    // MARK: opening

    @discardableResult
    public func openLibrary(at url: URL) throws {
        try session.open(url)
        window?.title = "Photons — \(url.deletingPathExtension().lastPathComponent)"
        window?.representedURL = url
        rootView.needsLayout = true
    }

    public func openLibraryPanel() {
        rootView.openLibraryPanel()
    }

    // MARK: commands (used by the menu and by `--ui-smoke`)

    public func showGrid() {
        session.mode = .grid
        rootView.showModule(for: .grid)
        window?.makeFirstResponder(rootView.gridController.collectionView)
    }

    public func showLoupe() {
        guard let id = session.anchorID else { return }
        session.activate(id)
        rootView.showModule(for: .loupe)
        window?.makeFirstResponder(rootView.loupeController.canvasView)
    }

    public func toggleFilmstrip() {
        rootView.toggleFilmstrip()
    }

    public func showBrowserAsList() {
        rootView.setBrowserMode(.list)
    }

    public func showBrowserAsFilmstrip() {
        rootView.setBrowserMode(.filmstrip)
    }

    public func selectAllAssets() {
        session.setSelection(Set(session.assets.map(\.id)), anchor: session.anchorID ?? session.assets.first?.id)
    }

    // MARK: history commands

    /// ⌘Z. The loupe re-renders because `undo()` bumps `editRevision`, the same signal a slider
    /// produces — an undo is not special-cased anywhere in the render path.
    @discardableResult
    public func undoEdit() -> Bool {
        session.undo()
    }

    /// ⇧⌘Z.
    @discardableResult
    public func redoEdit() -> Bool {
        session.redo()
    }

    // MARK: menu actions (nil-target items: AppKit walks the responder chain and lands here,
    // because a window controller sits between its window and the application)

    @objc public func openLibraryAction(_ sender: Any?) { openLibraryPanel() }

    @objc public func showGridAction(_ sender: Any?) { showGrid() }

    @objc public func showLoupeAction(_ sender: Any?) { showLoupe() }

    @objc public func toggleFilmstripAction(_ sender: Any?) { toggleFilmstrip() }

    @objc public func showBrowserListAction(_ sender: Any?) { showBrowserAsList() }

    @objc public func showBrowserFilmstripAction(_ sender: Any?) { showBrowserAsFilmstrip() }

    @objc public func selectAllAction(_ sender: Any?) { selectAllAssets() }

    @objc public func undoAction(_ sender: Any?) { undoEdit() }

    @objc public func redoAction(_ sender: Any?) { redoEdit() }

    // MARK: menu validation

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undoAction(_:)):
            // Title carries the action being taken back ("撤销 Exposure"), and the item is grey
            // when there is nothing behind the cursor — a menu that lies about undo is a bug.
            item.title = session.undoLabel.map { "撤销 \($0)" } ?? "撤销"
            return session.canUndo
        case #selector(redoAction(_:)):
            item.title = session.redoLabel.map { "重做 \($0)" } ?? "重做"
            return session.canRedo
        case #selector(showGridAction(_:)):
            item.state = session.mode == .grid ? .on : .off
            return true
        case #selector(showLoupeAction(_:)):
            item.state = session.mode == .loupe ? .on : .off
            return session.anchorID != nil
        case #selector(toggleFilmstripAction(_:)):
            item.state = rootView.browserMode == .filmstrip ? .on : .off
            return true
        case #selector(showBrowserListAction(_:)):
            item.state = rootView.browserMode == .list ? .on : .off
            return true
        case #selector(selectAllAction(_:)):
            return !session.assets.isEmpty
        case #selector(openLibraryAction(_:)):
            return true
        default:
            return true
        }
    }
}
