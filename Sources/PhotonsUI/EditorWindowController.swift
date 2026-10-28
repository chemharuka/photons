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
        // 标题栏本身必须是**透明**的：它盖在 contentView 之上，只要 AppKit 在那里画自己的底板，
        // 底下那块 `HeaderGlassView`（.headerView / .behindWindow）就会被压低一层——那正是
        // 「系统红绿灯看着像自画的」这半个问题的来源（另一半是顶栏曾经填的不透明底色）。
        // 三颗按钮仍然由 AppKit 提供：尺寸/位置/点击/失焦变灰都不是我们画的。
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

    // MARK: import (M6)

    /// 文件 ▸ 导入照片… (⇧⌘I). The work lives in `WorkspaceRootView`'s `ImportCoordinator`, which
    /// owns the progress line it drives; the window only forwards the command, so the menu and
    /// `--ui-smoke` take the same path.
    public func beginImport() { rootView.beginImport() }

    public var isImporting: Bool { rootView.isImporting }

    @objc public func importAction(_ sender: Any?) { beginImport() }

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

    /// 25% / 33.3% / 50% / 66.7% / 100% / 200% / 300% / 400% — the stop travels in the item's `tag`
    /// **as an index** into `LoupeController.menuZoomStops`.
    ///
    /// An index, not a percentage: `1.0/3.0` has no hundredths representation, so a `33` tag would
    /// land the action on 0.33 — a stop the menu never offered — and a `Double` tag on an `NSMenuItem`
    /// is a boxed `NSNumber` nobody wants to parse back. The array is the table of record.
    @objc public func zoomStopAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              LoupeController.menuZoomStops.indices.contains(item.tag) else { return }
        rootView.loupeController.zoom(to: LoupeController.menuZoomStops[item.tag])
    }

    /// 放大 (⌘=, and ⌘+ on a US keyboard lands here too). Disabled outside the loupe.
    @objc public func zoomInAction(_ sender: Any?) { rootView.loupeController.zoomIn() }

    /// 缩小 (⌘−): below 1:1 there is only fit, so this is the inverse of `zoomIn`'s first half.
    @objc public func zoomOutAction(_ sender: Any?) { rootView.loupeController.zoomOut() }

    @objc public func undoAction(_ sender: Any?) { undoEdit() }

    @objc public func redoAction(_ sender: Any?) { redoEdit() }

    // MARK: 复制/粘贴设置 (078 P0-7)
    //
    // Four verbs, one payload (`CatalogSession.copiedSettings`):
    //
    //   复制设置 (⌘C)                  capture the anchor's non-default leaves, narrowed by the
    //                                 sticky checklist
    //   选择要复制的设置… (⌥⌘C)         the checklist — 全选 / 全不选 / 预设组合 — then copy
    //   粘贴设置 (⌘V)                   paste those groups onto the selection (or the anchor)
    //   粘贴设置（选择组…） (⇧⌘V)        narrow the payload at paste time, then paste
    //
    // **The focus rule** is the interesting one. These items own ⌘C/⌘V, and the app also has text
    // fields (the number fields, the preset name field, an export path). If a text field is being
    // edited, ⌘C must copy *text*: `validateMenuItem` greys the four items (so AppKit's menu
    // validation is right) **and** each action re-sends the event down the responder chain
    // (`NSText.copy:` / `NSText.paste:`), so a key equivalent that AppKit routes to us anyway cannot
    // eat the shortcut. That is the belt-and-braces version of 「焦点在文本域时 ⌘C 不被劫持」.

    /// True while a text editor owns the keyboard (a field editor or any `NSTextView`).
    var isTextEditing: Bool {
        guard let responder = window?.firstResponder else { return false }
        if let text = responder as? NSTextView { return text.isEditable || text.isFieldEditor }
        return responder is NSTextField
    }

    /// Hand a ⌘C/⌘V the text editor asked for to that editor, and report whether it took it.
    ///
    /// Sent **to the first responder** rather than `to: nil`: a `nil` target resolves from the key
    /// window, and a window that is not key (a sheet is up, the app is in the background, a test
    /// process never activated) has no key window — the shortcut would then vanish silently instead
    /// of reaching the field the user is typing in.
    private func forwardTextCommand(_ selector: Selector, sender: Any?) -> Bool {
        guard let responder = window?.firstResponder, responder.responds(to: selector) else {
            return false
        }
        NSApp.sendAction(selector, to: responder, from: sender)
        return true
    }

    @objc public func copySettingsAction(_ sender: Any?) {
        if isTextEditing {
            _ = forwardTextCommand(#selector(NSText.copy(_:)), sender: sender)
            return
        }
        session.copySettingsFromAnchor()
    }

    @objc public func chooseCopySettingsAction(_ sender: Any?) {
        guard !isTextEditing, session.canCopySettings else { return }
        guard let selection = CopySettingsAccessoryView.run(selection: session.copySelection,
                                                            purpose: .copy) else { return }
        session.copySettingsFromAnchor(selection: selection)
    }

    @objc public func pasteSettingsAction(_ sender: Any?) {
        if isTextEditing {
            _ = forwardTextCommand(#selector(NSText.paste(_:)), sender: sender)
            return
        }
        session.pasteSettings()
    }

    @objc public func pasteSettingsWithChoicesAction(_ sender: Any?) {
        guard !isTextEditing, session.canPasteSettings else { return }
        guard let selection = CopySettingsAccessoryView.run(selection: session.copySelection,
                                                            purpose: .paste) else { return }
        session.pasteSettings(sections: selection.sections)
    }

    // MARK: 旋转/裁切 (task 035)
    //
    // The menu never touches the document: it asks the loupe's tool to enter, apply or cancel, and
    // the tool owns the draft, the one commit and the camera.
    //
    // 2026-10-27 — the 变换 submenu keeps **one** row now (⌘R): 应用 / 取消 / 两个翻转 live in the
    // inspector's 裁切 card. `applyCropAction` and `cancelCropAction` stay because they are the
    // responder-chain verbs the panel and `--ui-smoke` call by name (and `CropToolTests` pins that they
    // exist on the window); they are no longer menu rows.

    /// 变换 ▸ 裁切 (⌘R) **and** the 裁切 card's 直角尺 button: enter the tool, or apply and leave if it
    /// is already on.
    @objc public func toggleCropAction(_ sender: Any?) {
        rootView.loupeController.toggleCropTool()
    }

    /// 应用裁切 — one snapshot, one ⌘Z. The card's 应用 button and ↵ on the canvas.
    @objc public func applyCropAction(_ sender: Any?) {
        rootView.loupeController.applyCropTool()
    }

    /// 取消裁切: nothing is written. The card's 取消 button and Esc on the canvas.
    @objc public func cancelCropAction(_ sender: Any?) {
        rootView.loupeController.cancelCropTool()
    }

    // MARK: 变换 ▸ 顺时针/逆时针旋转 90° (P0-10)
    //
    // 072 §F cut the 变换 submenu down to the verbs that have no panel, and these two are the
    // exception that proves the rule: the card has the two buttons, and the **keyboard** has ⌘[ / ⌘]
    // because that is where a rotate lives in every photo app. Both doors call the same
    // `LoupeController.rotateQuarter`, which is the same document write either way.

    /// 变换 ▸ 顺时针旋转 90° (⌘]).
    @objc public func rotateClockwiseAction(_ sender: Any?) {
        rootView.loupeController.rotateQuarterClockwise()
    }

    /// 变换 ▸ 逆时针旋转 90° (⌘[).
    @objc public func rotateCounterClockwiseAction(_ sender: Any?) {
        rootView.loupeController.rotateQuarterCounterClockwise()
    }

    // MARK: 080 · 原图 / 前后对比
    //
    // Three verbs, no document. Each one asks the loupe to change what its next frame is *of*; the
    // loupe re-renders (or composites) and nothing is written to the edit, the history or the decode
    // ladder. The menu is the keyboard's home for them (`\`, Y, ⇧Y), and the ticks below are the
    // state the user cannot otherwise see.

    /// 显示 ▸ 显示原图 (`\`): the decode, or the document again.
    @objc public func toggleShowOriginalAction(_ sender: Any?) {
        rootView.loupeController.toggleShowOriginal()
    }

    /// 显示 ▸ 前后对比 (Y): split the canvas between the decode and the document.
    @objc public func toggleCompareAction(_ sender: Any?) {
        rootView.loupeController.toggleCompare()
    }

    /// 显示 ▸ 对比方向 (⇧Y): 左右 ↔ 上下.
    @objc public func toggleCompareAxisAction(_ sender: Any?) {
        rootView.loupeController.toggleCompareAxis()
    }

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
        case #selector(toggleCropAction(_:)):
            // Ticked while the frame is up, and enabled only where there is a photo to crop.
            item.state = rootView.loupeController.isCropToolActive ? .on : .off
            return session.mode == .loupe && session.anchorID != nil
        case #selector(rotateClockwiseAction(_:)), #selector(rotateCounterClockwiseAction(_:)):
            // Enabled only where there is a photo to turn — the same rule as 裁切. Not ticked: a
            // rotation is a command, not a mode, and the card's badge is where the angle is read.
            return session.mode == .loupe && session.anchorID != nil
        case #selector(applyCropAction(_:)), #selector(cancelCropAction(_:)):
            // 072 §D4 — grey unless the tool is on: with no frame up there is nothing to apply or
            // cancel. (2026-10-27: the two rows moved into the 裁切 card, whose buttons follow the same
            // rule; these two verbs stay on the responder chain for the panel and `--ui-smoke`.)
            return rootView.loupeController.isCropToolActive
        case #selector(redoAction(_:)):
            item.title = session.redoLabel.map { "重做 \($0)" } ?? "重做"
            return session.canRedo
        case #selector(toggleShowOriginalAction(_:)):
            // Ticked while the canvas is showing the decode; the title says which picture the click
            // would bring back, so an item that is on does not read like a command to turn it on.
            item.state = rootView.loupeController.showOriginal ? .on : .off
            item.title = rootView.loupeController.showOriginal ? "显示原图（已开启）" : "显示原图"
            return session.mode == .loupe && session.anchorID != nil
        case #selector(toggleCompareAction(_:)):
            item.state = rootView.loupeController.compareSplit == nil ? .off : .on
            if let split = rootView.loupeController.compareSplit {
                // The title carries the state the tick cannot: which way the line runs and where it is.
                item.title = "前后对比（\(split.axis.displayName) "
                    + "\(Int((split.fraction * 100).rounded())) %）"
            } else {
                item.title = "前后对比"
            }
            return session.mode == .loupe && session.anchorID != nil
        case #selector(toggleCompareAxisAction(_:)):
            // Grey until 对比 is on (there is no line to turn), then it names the axis a click would
            // switch *to*, which is what the title promises.
            let axis = rootView.loupeController.compareSplit?.axis ?? .vertical
            item.title = "对比方向：" + axis.displayName
            return rootView.loupeController.compareSplit != nil
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
        case #selector(copySettingsAction(_:)), #selector(chooseCopySettingsAction(_:)):
            // Grey while a text field owns the keyboard (⌘C is the text field's) and with no photo.
            guard !isTextEditing, session.canCopySettings else { return false }
            if item.action == #selector(copySettingsAction(_:)) {
                item.title = session.copiedSettings.map { "复制设置（\($0.fieldCount) 项）" } ?? "复制设置"
            }
            return true
        case #selector(pasteSettingsAction(_:)), #selector(pasteSettingsWithChoicesAction(_:)):
            guard !isTextEditing, session.canPasteSettings else { return false }
            if item.action == #selector(pasteSettingsAction(_:)) {
                // The count is the number of photos the paste will write, not the number selected:
                // a photo that already holds these values still gets a report but no row.
                let count = session.metadataTargetIDs.count
                item.title = count > 1 ? "粘贴设置到 \(count) 张" : "粘贴设置"
            }
            return true
        case #selector(zoomFitAction(_:)):
            // Ticked when the camera shows the whole frame — the state Z returns to.
            item.state = rootView.loupeController.viewState.isActualSize ? .off : .on
            return session.mode == .loupe && session.anchorID != nil
        case #selector(zoomStopAction(_:)):
            // Exactly on this stop, not "at least": 2:1 and 4:1 cannot both be ticked, and `fit`
            // (which is not a rung) ticks none of them.
            let current = rootView.loupeController.currentZoomStop
            // The tag is an **index** into the stop table, so this is the same double the camera was
            // set from — `1/3` compares as `1/3`, not as 0.33 or 0.333.
            let tagZoom = LoupeController.menuZoomStops.indices.contains(item.tag)
                ? LoupeController.menuZoomStops[item.tag] : .nan
            item.state = (current.map { abs($0 - tagZoom) < 1e-9 } ?? false) ? .on : .off
            return session.mode == .loupe && session.anchorID != nil
        case #selector(zoomInAction(_:)):
            return session.mode == .loupe && session.anchorID != nil
        case #selector(zoomOutAction(_:)):
            return session.mode == .loupe && session.anchorID != nil
                && rootView.loupeController.viewState.isActualSize
        case #selector(openLibraryAction(_:)):
            return true
        case #selector(importAction(_:)):
            // Nowhere to write without a library, and a second import while one runs would put two
            // walks on the same root at once. Grey in both cases instead of starting a panel whose
            // OK does nothing.
            return session.isOpen && !rootView.isImporting
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
