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

    // MARK: export (M5)

    /// The live export sheet, when one is up. Held so the window owns its sheet's lifetime (and so
    /// `--ui-smoke` can assert on the same object the 导出… menu item created).
    public private(set) var exportSheet: ExportSheetController?

    /// File ▸ 导出… — disabled with an empty selection, because an export of nothing writes nothing.
    public func showExportSheet() {
        guard let window, !session.selection.isEmpty else { return }
        if let existing = exportSheet, existing.isPresented { return }
        let controller = ExportSheetController(session: session)
        exportSheet = controller
        controller.present(in: window)
    }

    @objc public func exportAction(_ sender: Any?) { showExportSheet() }

    // MARK: develop presets (M5)

    /// Develop ▸ 预设 ▸ <name>. The name travels in `representedObject` (a menu is rebuilt from the
    /// library, so a tag index would go stale the moment a preset is renamed).
    @objc public func applyPresetAction(_ sender: Any?) {
        guard let name = presetName(sender) else { return }
        session.applyPreset(named: name)
    }

    /// 从当前照片新建预设… — one name, then the capture. No group picker: "the whole look" is what
    /// the menu command means, and the panel is where a narrower save belongs.
    @objc public func newPresetFromCurrentAction(_ sender: Any?) {
        guard session.anchorAsset != nil else { return }
        let alert = NSAlert()
        alert.messageText = "新建预设"
        alert.informativeText = "当前照片的外观会保存为预设（不含蒙版）。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "预设名称"
        field.stringValue = "预设 \(session.presetRecords.count + 1)"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        session.createPresetFromCurrent(named: field.stringValue)
    }

    @objc public func deletePresetAction(_ sender: Any?) {
        guard let name = presetName(sender) else { return }
        session.deletePreset(named: name)
    }

    @objc public func setDefaultPresetAction(_ sender: Any?) {
        guard let name = presetName(sender) else { return }
        session.setDefaultPreset(named: name)
    }

    private func presetName(_ sender: Any?) -> String? {
        if let item = sender as? NSMenuItem, let name = item.representedObject as? String {
            return name
        }
        return session.presetRecords.first?.name
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

    // MARK: rating / flag / colour label commands
    //
    // These write `assets.rating` / `assets.flag` / `assets.color_label` and nothing else — no
    // snapshot, no `develop_json`, no `editRevision`. That is why the menu can offer them while ⌘Z
    // stays grey with an empty history: a rating is not something to undo.

    /// Tagged 0…5.
    @discardableResult
    public func applyRating(_ stars: Int) -> Bool {
        session.setRatingForSelection(stars)
    }

    /// Tagged like `AssetFlag`: 1 = pick, 2 = reject; 0 or anything else clears (U).
    @discardableResult
    public func applyFlag(tag: Int) -> Bool {
        session.setFlagForSelection(AssetFlag(rawValue: tag == 1 ? "pick" : "reject")?.rawValue)
    }

    @discardableResult
    public func clearFlag() -> Bool {
        session.setFlagForSelection(nil)
    }

    /// Tagged 0…5 into `ColorLabel.allCases`.
    @discardableResult
    public func applyColorLabel(tag: Int) -> Bool {
        guard ColorLabel.allCases.indices.contains(tag) else { return false }
        return session.setColorLabelForSelection(ColorLabel.allCases[tag].rawValue)
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

    // MARK: zoom (显示 ▸ 适应窗口 / 1:1 … 8:1 / 放大 / 缩小)

    /// 适应窗口 (⌘0). The same destination as Z from 1:1 and as Escape — one `LoupeViewState.change`.
    @objc public func zoomFitAction(_ sender: Any?) { rootView.loupeController.zoomToFit() }

    /// 50% / 100% / 200% / 300% / 400% — the stop travels in the item's `tag` **as a percentage**
    /// (`50` → 0.5), because a menu item is rebuilt from a static list, a tag is the one field AppKit
    /// keeps without a model object, and an `Int` cannot hold 0.5.
    @objc public func zoomStopAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, item.tag > 0 else { return }
        rootView.loupeController.zoom(to: Double(item.tag) / 100)
    }

    /// 放大 (⌘=, and ⌘+ on a US keyboard lands here too). Disabled outside the loupe.
    @objc public func zoomInAction(_ sender: Any?) { rootView.loupeController.zoomIn() }

    /// 缩小 (⌘−): below 1:1 there is only fit, so this is the inverse of `zoomIn`'s first half.
    @objc public func zoomOutAction(_ sender: Any?) { rootView.loupeController.zoomOut() }

    @objc public func undoAction(_ sender: Any?) { undoEdit() }

    @objc public func redoAction(_ sender: Any?) { redoEdit() }

    /// All six rating items share this action; the stars come from the item's tag.
    @objc public func ratingAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        applyRating(item.tag)
    }

    @objc public func pickAction(_ sender: Any?) { applyFlag(tag: 1) }

    @objc public func rejectAction(_ sender: Any?) { applyFlag(tag: 2) }

    @objc public func clearFlagAction(_ sender: Any?) { clearFlag() }

    /// Six colour items share this action; the label index comes from the tag.
    @objc public func colorLabelAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        applyColorLabel(tag: item.tag)
    }

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
        case #selector(zoomFitAction(_:)):
            // Ticked when the camera shows the whole frame — the state Z returns to.
            item.state = rootView.loupeController.viewState.isActualSize ? .off : .on
            return session.mode == .loupe && session.anchorID != nil
        case #selector(zoomStopAction(_:)):
            // Exactly on this stop, not "at least": 2:1 and 4:1 cannot both be ticked, and a pinch
            // between stops ticks none of them (the readout still says 1.7:1).
            let current = rootView.loupeController.currentZoomStop
            // The tag carries a **percentage** (`50`), the camera carries a zoom (`0.5`) — comparing
            // them raw is why no item was ever ticked after the tag moved to percent.
            let tagZoom = Double(item.tag) / 100
            item.state = (current.map { abs($0 - tagZoom) < 0.005 } ?? false) ? .on : .off
            return session.mode == .loupe && session.anchorID != nil
        case #selector(zoomInAction(_:)):
            return session.mode == .loupe && session.anchorID != nil
        case #selector(zoomOutAction(_:)):
            return session.mode == .loupe && session.anchorID != nil
                && rootView.loupeController.viewState.isActualSize
        case #selector(openLibraryAction(_:)):
            return true
        case #selector(ratingAction(_:)):
            // Ticked when the whole selection already holds that rating — a menu that shows 3 stars
            // while the selection is mixed would be lying about what the next click does.
            let ratings = Set(session.selectedAssets.map(\.rating))
            item.state = (ratings.count == 1 && ratings.first == item.tag) ? .on : .off
            return !session.metadataTargetIDs.isEmpty
        case #selector(pickAction(_:)), #selector(rejectAction(_:)):
            let want = item.action == #selector(pickAction(_:)) ? "pick" : "reject"
            let flags = Set(session.selectedAssets.map { $0.flag ?? "" })
            item.state = (flags.count == 1 && flags.first == want) ? .on : .off
            return !session.metadataTargetIDs.isEmpty
        case #selector(clearFlagAction(_:)):
            item.state = session.selectedAssets.allSatisfy { $0.flag == nil } ? .on : .off
            return !session.metadataTargetIDs.isEmpty
        case #selector(colorLabelAction(_:)):
            let want = ColorLabel.allCases.indices.contains(item.tag)
                ? ColorLabel.allCases[item.tag].rawValue : ""
            let labels = Set(session.selectedAssets.map { $0.colorLabel ?? "" })
            item.state = (labels.count == 1 && labels.first == want) ? .on : .off
            return !session.metadataTargetIDs.isEmpty
        case #selector(exportAction(_:)):
            // Nothing selected = nothing to export: grey, not a sheet that says "将导出 0 张".
            item.title = session.selection.count > 1
                ? "导出 \(session.selection.count) 张…"
                : "导出…"
            return !session.selection.isEmpty
        case #selector(applyPresetAction(_:)):
            // Tick the default, so the menu shows which look a new photo would get.
            if let name = item.representedObject as? String {
                item.state = session.defaultPresetName == name ? .on : .off
            }
            return session.anchorID != nil && session.presetRecords.contains {
                $0.name == (item.representedObject as? String)
            }
        case #selector(newPresetFromCurrentAction(_:)):
            return session.anchorID != nil
        case #selector(deletePresetAction(_:)), #selector(setDefaultPresetAction(_:)):
            return session.presetRecords.contains { $0.name == (item.representedObject as? String) }
        default:
            return true
        }
    }
}
