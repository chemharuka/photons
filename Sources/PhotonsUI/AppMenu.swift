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
        // ⇧⌘I — the shortcut every photo app puts on "import". Grey until a library is open
        // (`validateMenuItem`): the panel would otherwise accept folders and have nowhere to write.
        let importItem = file.addItem(withTitle: "导入照片…",
                                      action: #selector(EditorWindowController.importAction(_:)),
                                      keyEquivalent: "i")
        importItem.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        // ⌘⇧E, the shortcut every photo app puts on "export the selection". Grey with an empty
        // selection (`validateMenuItem`), so the menu cannot promise a batch that has no items.
        let exportItem = file.addItem(withTitle: "导出…",
                                      action: #selector(EditorWindowController.exportAction(_:)),
                                      keyEquivalent: "e")
        exportItem.keyEquivalentModifierMask = [.command, .shift]

        // Edit
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        editItem.submenu = edit
        // Nil targets: AppKit walks the responder chain to the window controller, which validates
        // both items against `CatalogSession.canUndo/canRedo` (grey with no history).
        edit.addItem(withTitle: "撤销", action: #selector(EditorWindowController.undoAction(_:)),
                     keyEquivalent: "z")
        let redoItem = edit.addItem(withTitle: "重做", action: #selector(EditorWindowController.redoAction(_:)),
                                    keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "全选照片", action: #selector(EditorWindowController.selectAllAction(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // 复制/粘贴设置 — 078 P0-7. One row per verb the ticket names, and each keeps the system
        // clipboard when a text field owns the keyboard: `validateMenuItem` greys them, and the action
        // itself hands ⌘C/⌘V back to `NSText` (see `EditorWindowController.copySettingsAction`), so a
        // photo app never eats the shortcut of the text field the user is typing in.
        edit.addItem(withTitle: "复制设置",
                     action: #selector(EditorWindowController.copySettingsAction(_:)),
                     keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴设置",
                     action: #selector(EditorWindowController.pasteSettingsAction(_:)),
                     keyEquivalent: "v")
        let pasteChoices = edit.addItem(withTitle: "粘贴设置（选择组…）",
                                        action: #selector(EditorWindowController.pasteSettingsWithChoicesAction(_:)),
                                        keyEquivalent: "v")
        pasteChoices.keyEquivalentModifierMask = [.command, .shift]
        let chooseCopy = edit.addItem(withTitle: "选择要复制的设置…",
                                      action: #selector(EditorWindowController.chooseCopySettingsAction(_:)),
                                      keyEquivalent: "c")
        chooseCopy.keyEquivalentModifierMask = [.command, .option]

        // Photo — rating / flag / colour label. Catalog metadata, not edits, so these live outside
        // the undo pair above. Bare digits and letters (no ⌘) because that is the convention every
        // photo app uses, and ⌘0–⌘5 would collide with the view menu.
        let photoItem = NSMenuItem()
        main.addItem(photoItem)
        let photo = NSMenu(title: "照片")
        photoItem.submenu = photo
        for stars in 0...5 {
            let item = photo.addItem(withTitle: stars == 0 ? "清除星级" : "\(stars) 星",
                                     action: #selector(EditorWindowController.ratingAction(_:)),
                                     keyEquivalent: "\(stars)")
            item.keyEquivalentModifierMask = []
            item.tag = stars
        }
        photo.addItem(.separator())
        let pick = photo.addItem(withTitle: "标记为选取 (P)",
                                 action: #selector(EditorWindowController.pickAction(_:)), keyEquivalent: "p")
        pick.keyEquivalentModifierMask = []
        pick.tag = 1
        let reject = photo.addItem(withTitle: "标记为拒绝 (X)",
                                   action: #selector(EditorWindowController.rejectAction(_:)), keyEquivalent: "x")
        reject.keyEquivalentModifierMask = []
        reject.tag = 2
        let unflag = photo.addItem(withTitle: "清除旗标 (U)",
                                   action: #selector(EditorWindowController.clearFlagAction(_:)), keyEquivalent: "u")
        unflag.keyEquivalentModifierMask = []
        photo.addItem(.separator())
        for (index, label) in ColorLabel.allCases.enumerated() {
            let item = photo.addItem(withTitle: "色标：\(label.displayName)",
                                     action: #selector(EditorWindowController.colorLabelAction(_:)),
                                     keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.option]
            item.tag = index
        }
        // ⌥0 — clear the label. Same path as the six values (`setColorLabelForSelection(nil)`), so a
        // multi-selection clears as one metadata write and no history entry appears: a colour label is
        // a library fact, not an edit.
        photo.addItem(.separator())
        let noLabel = photo.addItem(withTitle: "色标：无",
                                    action: #selector(EditorWindowController.clearColorLabelAction(_:)),
                                    keyEquivalent: "0")
        noLabel.keyEquivalentModifierMask = [.option]

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
        let transform = NSMenu(title: "变换")
        transformItem.submenu = transform
        // The R every photo app puts on its crop tool, and the key Phos uses
        // (`local/src/swift-raw/Zenodeng_Phos/Sources/Phos/PremiumUI.swift:74`). Ticked while the
        // frame is up (`validateMenuItem`), grey where there is no photo to crop.
        transform.addItem(withTitle: "裁切",
                          action: #selector(EditorWindowController.toggleCropAction(_:)),
                          keyEquivalent: "r")
        // 2026-10-28 (P0-10): the 90° rotation. The card's two buttons are the mouse's door; these
        // two rows are the keyboard's (⌘[ / ⌘], the pair every photo app ships). One verb behind each
        // — `LoupeController.rotateQuarter(clockwise:)` — so the menu cannot turn the picture by a
        // different rule from the buttons.
        transform.addItem(withTitle: "逆时针旋转 90°",
                          action: #selector(EditorWindowController.rotateCounterClockwiseAction(_:)),
                          keyEquivalent: "[")
        transform.addItem(withTitle: "顺时针旋转 90°",
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
        let presetItem = NSMenuItem(title: "预设", action: nil, keyEquivalent: "")
        presetItem.submenu = PresetMenu(kind: .apply)
        main.addItem(presetItem)

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
            view.addItem(withTitle: "适应窗口",
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
        let originalItem = view.addItem(withTitle: "显示原图",
                                        action: #selector(EditorWindowController.toggleShowOriginalAction(_:)),
                                        keyEquivalent: "\\")
        originalItem.keyEquivalentModifierMask = []
        let compareItem = view.addItem(withTitle: "前后对比",
                                       action: #selector(EditorWindowController.toggleCompareAction(_:)),
                                       keyEquivalent: "y")
        compareItem.keyEquivalentModifierMask = []
        // ⇧Y swaps the layout of the line the user already placed (左右 ↔ 上下). One row, not a
        // submenu: the submenu spelling taught two places for one verb, which is what the 变换 menu
        // was cut down for (072 §F).
        let compareAxisItem = view.addItem(withTitle: "对比方向：左右",
                                           action: #selector(EditorWindowController.toggleCompareAxisAction(_:)),
                                           keyEquivalent: "y")
        compareAxisItem.keyEquivalentModifierMask = [.shift]
        view.addItem(.separator())
        view.addItem(withTitle: "放大",
                     action: #selector(EditorWindowController.zoomInAction(_:)),
                     keyEquivalent: "=")
        view.addItem(withTitle: "缩小",
                     action: #selector(EditorWindowController.zoomOutAction(_:)),
                     keyEquivalent: "-")

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
        title = kind == .apply ? "预设" : (kind == .setDefault ? "设为默认" : "删除预设")
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("no nibs in this app") }

    // MARK: building

    func menuNeedsUpdate(_ menu: NSMenu) {
        let controller = Self.activeEditor()
        let records = controller?.session.presetRecords ?? []
        menu.removeAllItems()

        guard !records.isEmpty else {
            let empty = NSMenuItem(title: "（还没有预设）", action: nil, keyEquivalent: "")
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
            let defaults = NSMenuItem(title: "设为默认", action: nil, keyEquivalent: "")
            defaults.submenu = PresetMenu(kind: .setDefault)
            menu.addItem(defaults)
            let delete = NSMenuItem(title: "删除预设", action: nil, keyEquivalent: "")
            delete.submenu = PresetMenu(kind: .delete)
            menu.addItem(delete)
            if let defaultName {
                menu.addItem(.separator())
                let note = NSMenuItem(title: "默认：\(defaultName)", action: nil, keyEquivalent: "")
                note.isEnabled = false
                menu.addItem(note)
            }
        }
    }

    private func addCreateItem(to menu: NSMenu) {
        menu.addItem(withTitle: "从当前照片新建预设…",
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
