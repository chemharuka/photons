import PhotonsLocalization
import AppKit
import CryptoKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import PhotonsCatalog
import PhotonsCore
import PhotonsExport

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
        appMenu.addItem(withTitle: L10n.tr("8d1c78c9ff28" , String(describing: (appName))), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = appMenu.addItem(withTitle: L10n.tr("da9fc8ba9497"),
            action: #selector(SettingsWindowController.openSettings(_:)), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]
        settings.target = SettingsWindowController.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("5efd5bdc4894" , String(describing: (appName))), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: L10n.tr("d32bd5a0edfe"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.tr("cbec1c499c29" , String(describing: (appName))), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File
        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: L10n.tr("39932f24fe11"))
        fileItem.submenu = file
        file.addItem(withTitle: L10n.tr("f9af46c99fd4"), action: #selector(EditorWindowController.createLibraryAction(_:)), keyEquivalent: "n")
        file.addItem(withTitle: L10n.tr("e6fe0fd9bc6e"), action: #selector(EditorWindowController.openLibraryAction(_:)), keyEquivalent: "o")
        // ⇧⌘I — the shortcut every photo app puts on "import". Grey until a library is open
        // (`validateMenuItem`): the panel would otherwise accept folders and have nowhere to write.
        let importItem = file.addItem(withTitle: L10n.tr("006ed48cea9a"),
                                      action: #selector(EditorWindowController.importAction(_:)),
                                      keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: L10n.tr("dfc8a33f5fb3"), action: #selector(EditorWindowController.authorizePhotoFolderAction(_:)), keyEquivalent: "")
        file.addItem(.separator())
        // ⌘⇧E, the shortcut every photo app puts on "export the selection". Grey with an empty
        // selection (`validateMenuItem`), so the menu cannot promise a batch that has no items.
        let exportItem = file.addItem(withTitle: L10n.tr("643e7408e6a7"),
                                      action: #selector(EditorWindowController.exportAction(_:)),
                                      keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]

        // Edit
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L10n.tr("051836569928"))
        editItem.submenu = edit
        // Nil targets: AppKit walks the responder chain to the window controller, which validates
        // both items against `CatalogSession.canUndo/canRedo` (grey with no history).
        edit.addItem(withTitle: L10n.tr("926a50b98ece"), action: #selector(EditorWindowController.undoAction(_:)),
                     keyEquivalent: "z")
        let redoItem = edit.addItem(withTitle: L10n.tr("03717b6f1070"), action: #selector(EditorWindowController.redoAction(_:)),
                                    keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: L10n.tr("7e46f4042041"), action: #selector(EditorWindowController.selectAllAction(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // 复制/粘贴设置 — 078 P0-7. One row per verb the ticket names, and each keeps the system
        // clipboard when a text field owns the keyboard: `validateMenuItem` greys them, and the action
        // itself hands ⌘C/⌘V back to `NSText` (see `EditorWindowController.copySettingsAction`), so a
        // photo app never eats the shortcut of the text field the user is typing in.
        edit.addItem(withTitle: L10n.tr("1c7d60676292"),
                     action: #selector(EditorWindowController.copySettingsAction(_:)),
                     keyEquivalent: "c")
        edit.addItem(withTitle: L10n.tr("d24cf4a6b02b"),
                     action: #selector(EditorWindowController.pasteSettingsAction(_:)),
                     keyEquivalent: "v")
        let pasteChoices = edit.addItem(withTitle: L10n.tr("5942cecbe73c"),
                                        action: #selector(EditorWindowController.pasteSettingsWithChoicesAction(_:)),
                                        keyEquivalent: "v")
        pasteChoices.keyEquivalentModifierMask = [.command, .shift]
        let chooseCopy = edit.addItem(withTitle: L10n.tr("2cd3e10b3a16"),
                                      action: #selector(EditorWindowController.chooseCopySettingsAction(_:)),
                                      keyEquivalent: "c")
        chooseCopy.keyEquivalentModifierMask = [.command, .option]

        // Photo — rating / flag / colour label. Catalog metadata, not edits, so these live outside
        // the undo pair above. Bare digits and letters (no ⌘) because that is the convention every
        // photo app uses, and ⌘0–⌘5 would collide with the view menu.
        let photoItem = NSMenuItem()
        main.addItem(photoItem)
        let photo = NSMenu(title: L10n.tr("7b50017ae47e"))
        photoItem.submenu = photo
        for stars in 0...5 {
            let item = photo.addItem(withTitle: stars == 0 ? L10n.tr("3085c81211ed") : L10n.tr("63d4f7b1c358" , String(describing: (stars))),
                                     action: #selector(EditorWindowController.ratingAction(_:)),
                                     keyEquivalent: "\(stars)")
            item.keyEquivalentModifierMask = []
            item.tag = stars
        }
        photo.addItem(.separator())
        let pick = photo.addItem(withTitle: L10n.tr("96f39964acc7"),
                                 action: #selector(EditorWindowController.pickAction(_:)), keyEquivalent: "p")
        pick.keyEquivalentModifierMask = []
        pick.tag = 1
        let reject = photo.addItem(withTitle: L10n.tr("ce60f6e0a6d1"),
                                   action: #selector(EditorWindowController.rejectAction(_:)), keyEquivalent: "x")
        reject.keyEquivalentModifierMask = []
        reject.tag = 2
        let unflag = photo.addItem(withTitle: L10n.tr("200edafcacf5"),
                                   action: #selector(EditorWindowController.clearFlagAction(_:)), keyEquivalent: "u")
        unflag.keyEquivalentModifierMask = []
        photo.addItem(.separator())
        for (index, label) in ColorLabel.allCases.enumerated() {
            let item = photo.addItem(withTitle: L10n.tr("90bcec6e0d2b" , String(describing: (label.displayName))),
                                     action: #selector(EditorWindowController.colorLabelAction(_:)),
                                     keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.option]
            item.tag = index
        }
        // ⌥0 — clear the label. Same path as the six values (`setColorLabelForSelection(nil)`), so a
        // multi-selection clears as one metadata write and no history entry appears: a colour label is
        // a library fact, not an edit.
        photo.addItem(.separator())
        let noLabel = photo.addItem(withTitle: L10n.tr("1faccf658720"),
                                    action: #selector(EditorWindowController.clearColorLabelAction(_:)),
                                    keyEquivalent: "0")
        noLabel.keyEquivalentModifierMask = [.option]
        // §378 — 堆叠. ⌘G / ⇧⌘G are the pair every photo app puts on "group / ungroup"; they write
        // catalog metadata (`stack_id`/`stack_rank`), so ⌘Z never walks one back. Grey rules live in
        // `validateMenuItem`: 堆叠 needs ≥ 2 selected photos, 取消堆叠 needs a stack in the selection.
        photo.addItem(.separator())
        photo.addItem(withTitle: L10n.tr("93fa7e05b300"),
                      action: #selector(EditorWindowController.stackSelectionAction(_:)),
                      keyEquivalent: "g")
        let ungroup = photo.addItem(withTitle: L10n.tr("b5b27507401e"),
                                    action: #selector(EditorWindowController.ungroupSelectionAction(_:)),
                                    keyEquivalent: "g")
        ungroup.keyEquivalentModifierMask = [.command, .shift]

        // 变换 — **before 显影** (072 §F). Everything that moves the picture's geometry lives under
        // this title: it changes where the pixels come from, not what colour they are.
        //
        // 2026-10-27 — the panel took the verbs. The user's ask: 「将裁切下拉菜单中的相关功能，移动到右侧
        // 第二栏「变换」……第一个卡片是裁切；点按直角尺图标后进入裁切模式」. So the 应用裁切 / 取消裁切 /
        // 水平翻转 / 垂直翻转 rows are **deleted**, not duplicated: those four verbs (and 比例 / 角度 /
        // 九宫格) are the 裁切 card's rows now, and a menu that mirrors a panel teaches the user two
        // places to look for one control. What stays is the **shortcut carrier**: ⌘R must still enter
        // and leave 裁切 mode (「⌘R 必须仍能进/出裁切」), and it is the very verb the card's 直角尺
        // button calls (`LoupeController.toggleCropTool()`: enter, or apply-and-leave).
        //
        // ↵ (应用) and Esc (取消) on the canvas are untouched, so the keyboard lost nothing.
        //
        // 梯形校正 / 四边形校正 (**not built**): the contract is 072 §F — they belong to
        // `GeometryGroup` as a new group of corner offsets, they need their own renderer stage, and
        // until both exist there is no row here at all (a grey item teaches the user a command that
        // does nothing). The insertion point is the separator below.
        let transformItem = NSMenuItem()
        main.addItem(transformItem)
        let transform = NSMenu(title: L10n.tr("ca4842bc9e80"))
        transformItem.submenu = transform
        // The R every photo app puts on its crop tool, and the key Phos uses
        // (`local/src/swift-raw/Zenodeng_Phos/Sources/Phos/PremiumUI.swift:74`). Ticked while the
        // frame is up (`validateMenuItem`), grey where there is no photo to crop.
        transform.addItem(withTitle: L10n.tr("e9f8face2f69"),
                          action: #selector(EditorWindowController.toggleCropAction(_:)),
                          keyEquivalent: "r")
        // 2026-10-28 (P0-10): the 90° rotation. The card's two buttons are the mouse's door; these
        // two rows are the keyboard's (⌘[ / ⌘], the pair every photo app ships). One verb behind each
        // — `LoupeController.rotateQuarter(clockwise:)` — so the menu cannot turn the picture by a
        // different rule from the buttons.
        transform.addItem(withTitle: L10n.tr("d4b56c062003"),
                          action: #selector(EditorWindowController.rotateCounterClockwiseAction(_:)),
                          keyEquivalent: "[")
        transform.addItem(withTitle: L10n.tr("980edb5bf6fd"),
                          action: #selector(EditorWindowController.rotateClockwiseAction(_:)),
                          keyEquivalent: "]")
        // Reserved: 梯形校正 / 四边形校正 go here (see the comment above — no dead rows).

        // 预设 — a **top-level menu** as of 081 (§4: 「预设卡片删掉，系统顶部菜单栏出现预设」).
        //
        // It takes 显影's place rather than sitting inside it: 显影's only row *was* the preset list, so
        // moving the list out and leaving 显影 behind would leave a title that opens nothing. One verb,
        // one home — the same rule 072 §F used to cut the 变换 menu down.
        //
        // The list is the library's, so the menu is rebuilt every time it opens
        // (`PresetMenu.menuNeedsUpdate`): a preset created in the copy sheet shows up here without a
        // relaunch, and a deleted one cannot be applied from a stale item.
        let presetItem = NSMenuItem(title: L10n.tr("f1de1e2621de"), action: nil, keyEquivalent: "")
        presetItem.submenu = PresetMenu(kind: .apply)
        main.addItem(presetItem)

        let toolsItem = NSMenuItem()
        main.addItem(toolsItem)
        let tools = NSMenu(title: L10n.tr("5ca6730d4415"))
        toolsItem.submenu = tools
        let panorama = tools.addItem(withTitle: L10n.tr("8311512f9cab"), action: #selector(EditorWindowController.panoramaAction(_:)), keyEquivalent: "m")
        panorama.keyEquivalentModifierMask = [.control]
        let lcc = tools.addItem(withTitle: L10n.tr("486f04a981bd"), action: #selector(EditorWindowController.lccAction(_:)), keyEquivalent: "l")
        lcc.keyEquivalentModifierMask = [.control]
        tools.addItem(withTitle: L10n.tr("slices.title"), action: #selector(EditorWindowController.socialMediaSlicesAction(_:)), keyEquivalent: "")

        // View
        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let view = NSMenu(title: L10n.tr("4e1449e7d5e5"))
        viewItem.submenu = view
        view.addItem(withTitle: L10n.tr("e41ecc67ca28"), action: #selector(EditorWindowController.showGridAction(_:)), keyEquivalent: "1")
        view.addItem(withTitle: L10n.tr("e71b76b45a24"), action: #selector(EditorWindowController.showLoupeAction(_:)), keyEquivalent: "2")
        view.addItem(.separator())
        let strip = view.addItem(withTitle: L10n.tr("6efc41d2edbf"),
                                 action: #selector(EditorWindowController.toggleFilmstripAction(_:)),
                                 keyEquivalent: "b")
        strip.keyEquivalentModifierMask = [.control, .command]
        let list = view.addItem(withTitle: L10n.tr("61db6236bd40"),
                                action: #selector(EditorWindowController.showBrowserListAction(_:)),
                                keyEquivalent: "a")
        list.keyEquivalentModifierMask = [.control, .command]
        view.addItem(.separator())
        // 倍率. The stops are the eight numeric rungs (`LoupeController.menuZoomStops`) and the item's
        // **tag is the index** into that array: `1/3` and `2/3` have no hundredths form, so a percent
        // tag would have to round the third to 33 % — a different stop than the one the item names.
        // Ticked by `validateMenuItem` when the camera is exactly on one.
        //
        // 适应窗口 is **not** a rung of this ladder — it is a mode whose ratio depends on the window —
        // so it is its own row here (⌘0), and `LoupeController.zoomFitEntryPoint` is the one switch
        // that decides whether that row exists at all. TODO(用户待定): fit 的位置尚未决定。
        if LoupeController.zoomFitEntryPoint == .menuItem {
            view.addItem(withTitle: L10n.tr("f8d01c881e34"),
                         action: #selector(EditorWindowController.zoomFitAction(_:)),
                         keyEquivalent: "0")
        }
        for (index, stop) in LoupeController.menuZoomStops.enumerated() {
            let item = view.addItem(withTitle: LoupeViewState.percentLabel(of: stop),
                                    action: #selector(EditorWindowController.zoomStopAction(_:)),
                                    keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.command, .option]
            // Index, not percent: the action looks the value up in `menuZoomStops`, so 33.3 % stays
            // `1.0/3.0` instead of collapsing to 0.333.
            item.tag = index
        }
        view.addItem(.separator())
        // 080 — 原图 / 前后对比. `\` and Y are the two keys LR puts on this pair, both **bare** (no ⌘),
        // like the rating rows: they are viewing verbs the hand hits without leaving the picture.
        // The items carry no target, so AppKit resolves them through the responder chain to the window
        // controller, which ticks them against `LoupeController.frameMode` (`validateMenuItem`).
        let originalItem = view.addItem(withTitle: L10n.tr("c4507a67622d"),
                                        action: #selector(EditorWindowController.toggleShowOriginalAction(_:)),
                                        keyEquivalent: "\\")
        originalItem.keyEquivalentModifierMask = []
        let compareItem = view.addItem(withTitle: L10n.tr("a5163334460b"),
                                       action: #selector(EditorWindowController.toggleCompareAction(_:)),
                                       keyEquivalent: "y")
        compareItem.keyEquivalentModifierMask = []
        // ⇧Y swaps the layout of the line the user already placed (左右 ↔ 上下). One row, not a
        // submenu: the submenu spelling taught two places for one verb, which is what the 变换 menu
        // was cut down for (072 §F).
        let compareAxisItem = view.addItem(withTitle: L10n.tr("d3adfe26046b"),
                                           action: #selector(EditorWindowController.toggleCompareAxisAction(_:)),
                                           keyEquivalent: "y")
        compareAxisItem.keyEquivalentModifierMask = [.shift]
        view.addItem(.separator())
        view.addItem(withTitle: L10n.tr("80f8fbcfa011"),
                     action: #selector(EditorWindowController.zoomInAction(_:)),
                     keyEquivalent: "=")
        view.addItem(withTitle: L10n.tr("290f68030501"),
                     action: #selector(EditorWindowController.zoomOutAction(_:)),
                     keyEquivalent: "-")

        // Window
        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: L10n.tr("9efe01f647d6"))
        windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: L10n.tr("ac29e57a46f4"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L10n.tr("b762aec769a3"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        return main
    }
}

/// Develop ▸ 预设 — rebuilt from the library each time it opens.
///
/// A menu that is a static list of names goes stale the moment the inspector card creates or
/// deletes one, and a "delete shape 3" style tag map is the classic way to delete the wrong preset.
/// So the items carry the **name** in `representedObject` and the list is re-read from the session
/// in `menuNeedsUpdate` — the same `presetRecords` cache the panel draws.
///
/// The session is found through the responder chain's owner (the window controller), not passed in:
/// the menu is built by `MainMenu.build()` at launch, before any library is open, and must still be
/// correct for the second library the user opens.
@MainActor
final class PresetMenu: NSMenu, NSMenuDelegate {

    enum Kind {
        /// The preset list itself, plus 新建/设为默认/删除.
        case apply
        case setDefault
        case delete
    }

    private let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(title: "")
        title = kind == .apply ? L10n.tr("f1de1e2621de") : (kind == .setDefault ? L10n.tr("357211096f78") : L10n.tr("28786d906975"))
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("no nibs in this app") }

    // MARK: building

    func menuNeedsUpdate(_ menu: NSMenu) {
        let controller = Self.activeEditor()
        let records = controller?.session.presetRecords ?? []
        menu.removeAllItems()

        guard !records.isEmpty else {
            let empty = NSMenuItem(title: L10n.tr("a73ba3dfdb06"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            if kind == .apply { addCreateItem(to: menu) }
            return
        }

        let defaultName = controller?.session.defaultPresetName
        for record in records {
            let item = NSMenuItem(title: record.name, action: action(), keyEquivalent: "")
            item.representedObject = record.name
            if kind == .apply { item.state = record.isDefault ? .on : .off }
            menu.addItem(item)
        }

        if kind == .apply {
            menu.addItem(.separator())
            addCreateItem(to: menu)
            menu.addItem(.separator())
            let defaults = NSMenuItem(title: L10n.tr("357211096f78"), action: nil, keyEquivalent: "")
            defaults.submenu = PresetMenu(kind: .setDefault)
            menu.addItem(defaults)
            let delete = NSMenuItem(title: L10n.tr("28786d906975"), action: nil, keyEquivalent: "")
            delete.submenu = PresetMenu(kind: .delete)
            menu.addItem(delete)
            if let defaultName {
                menu.addItem(.separator())
                let note = NSMenuItem(title: L10n.tr("ad10bbb40992" , String(describing: (defaultName))), action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
        }
    }

    private func addCreateItem(to menu: NSMenu) {
        menu.addItem(withTitle: L10n.tr("5527eccff3b6"),
                     action: #selector(EditorWindowController.newPresetFromCurrentAction(_:)),
                     keyEquivalent: "")
    }

    private func action() -> Selector {
        switch kind {
        case .apply: return #selector(EditorWindowController.applyPresetAction(_:))
        case .setDefault: return #selector(EditorWindowController.setDefaultPresetAction(_:))
        case .delete: return #selector(EditorWindowController.deletePresetAction(_:))
        }
    }

    private static func activeEditor() -> EditorWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? EditorWindowController {
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? EditorWindowController {
            return controller
        }
        return NSApp.windows.compactMap { $0.windowController as? EditorWindowController }.first
    }
}
