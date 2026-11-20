import XCTest
import AppKit
import GRDB
import PhotonsCore
import PhotonsCatalog
import PhotonsLocalization
@testable import PhotonsUI

/// 435 — 顶栏「打开」右边的「导入」「导出」。
///
/// 要钉住的六件事：
/// - A① 结构与样式：两个控件都是 `ToolButton`，顺序打开 → 导入 → 导出，相邻间隙 10 pt、同高 28 pt；
/// - A② 与菜单同一条路：按钮的 action 就是 `EditorWindowController.importAction/exportAction`
///   这两个 selector，target 两边都是 nil；
/// - A③ 可用性同源：`WorkspaceRootView.canImport/canExport` 是唯一判据，按钮与 `validateMenuItem`
///   在每种状态下逐条相等；
/// - A④ 布局不压状态簇：最右控件决定 `controlsTrailingEdge`，簇永远在它右边 16 pt 之外；
/// - A⑤ 真点击：按钮真的把命令送到窗口控制器（导入面板恰好弹 1 次、导出 sheet 恰好 1 个）；
/// - A⑥ 样式一致：font / bezelStyle / isBordered / focusRingType / contentTintColor 与「打开」逐项相等。
@MainActor
final class TopBarImportExport435Tests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        // `MainMenu.build()` assigns `NSApp.windowsMenu`; a process needs an NSApplication first.
        _ = NSApplication.shared
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-topbar435-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        TestWindows.sweep()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - fixtures

    private func makeBar(width: CGFloat = 1600,
                         inspector: CGFloat = 330,
                         selection: Int = 4,
                         libraryName: String? = "topbar-demo") -> TopBarView {
        let bar = TopBarView()
        bar.frame = NSRect(x: 0, y: 0, width: width, height: WorkspaceLayout.topBarHeight)
        bar.statusColumnWidth = inspector
        bar.update(mode: .grid, assetCount: 45, selectionCount: selection,
                   libraryName: libraryName, filmstrip: false)
        bar.updateActions(canImport: true, canExport: true)
        bar.layoutSubtreeIfNeeded()
        return bar
    }

    /// One open library with `names.count` catalog rows. Files may not exist: nothing here decodes.
    private func makeLibrary(names: [String] = ["435-a.dng"]) throws -> (url: URL, ids: [String]) {
        let sample = tmp.appendingPathComponent("samples", isDirectory: true)
        try FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
        let url = tmp.appendingPathComponent("435-\(UUID().uuidString).photonslibrary", isDirectory: true)
        let catalog = try Catalog.create(at: url)
        let source = try catalog.ensureRoot(for: sample, mode: .reference)
        var ids: [String] = []
        for name in names {
            let asset = Asset(sourceRootId: source.id,
                              relPath: name,
                              filename: name,
                              ext: (name as NSString).pathExtension,
                              kind: AssetKind.detect((name as NSString).pathExtension) ?? .raw,
                              size: 4096,
                              mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 9520,
                              height: 6336,
                              captureTime: "2026-10-02T05:09:12Z",
                              captureLocalDate: "2026-10-02",
                              cameraModel: "LEICA SL3",
                              cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            ids.append(asset.id)
        }
        return (url, ids)
    }

    private func importItem() -> NSMenuItem {
        NSMenuItem(title: Loc.t("导入照片…"),
                   action: #selector(EditorWindowController.importAction(_:)),
                   keyEquivalent: "i")
    }

    private func exportItem() -> NSMenuItem {
        NSMenuItem(title: Loc.t("导出…"),
                   action: #selector(EditorWindowController.exportAction(_:)),
                   keyEquivalent: "e")
    }

    private func fileMenu() throws -> NSMenu {
        let menu = MainMenu.build()
        return try XCTUnwrap(menu.items.first { $0.submenu?.title == Loc.t("文件") }?.submenu)
    }

    private func pump(until condition: () -> Bool, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// A nil-target button's action goes down the responder chain from the key window's first
    /// responder. XCTest's host application cannot be activated (it was not launched by
    /// LaunchServices), so `performClick` has no key window to start from; start at *this* window's
    /// first responder instead — the chain below it (root → window → window controller) is the real
    /// one the app uses.
    @discardableResult
    private func press(_ button: NSButton, in window: NSWindow) -> Bool {
        guard let action = button.action else { return false }
        return window.firstResponder?.tryToPerform(action, with: button) ?? false
    }

    // MARK: - A① structure + style

    func testA1_buttonsAreToolButtonsLaidOutOpenImportExportWithTenPointGaps() {
        let bar = makeBar()
        let open = bar.openButtonView
        let imp = bar.importButtonView
        let exp = bar.exportButtonView

        XCTAssertTrue(type(of: imp) === ToolButton.self, "导入不是 ToolButton")
        XCTAssertTrue(type(of: exp) === ToolButton.self, "导出不是 ToolButton")

        XCTAssertLessThan(open.frame.maxX, imp.frame.minX, "顺序：打开 → 导入")
        XCTAssertLessThan(imp.frame.maxX, exp.frame.minX, "顺序：导入 → 导出")
        XCTAssertEqual(imp.frame.minX - open.frame.maxX, TopBarView.itemGap, accuracy: 0.5, "打开↔导入间距不是 5 pt")
        XCTAssertEqual(exp.frame.minX - imp.frame.maxX, TopBarView.itemGap, accuracy: 0.5, "导入↔导出间距不是 5 pt")

        for (name, button) in [("打开", open), ("导入", imp), ("导出", exp)] {
            XCTAssertEqual(button.frame.height, WorkspaceLayout.toolButtonHit,
                           "\(name) 的命中高不是 28")
            XCTAssertEqual(button.frame.midY, bar.bounds.midY, accuracy: 0.001,
                           "\(name) 不在顶栏中线")
        }

        for (name, button) in [("导入", imp), ("导出", exp)] {
            XCTAssertNotNil(button.image, "\(name) 没有图标")
            XCTAssertEqual(button.imagePosition, .imageLeading, "\(name) 图标不在文字左边")
            XCTAssertEqual(button.title, name, "\(name) 的顶栏标题必须固定")
        }
        XCTAssertEqual(imp.toolTip, Loc.t("导入照片…") + "（⇧⌘I）")
        XCTAssertEqual(exp.toolTip, Loc.t("导出…") + "（⇧⌘E）")
        print("A① open=\(NSStringFromRect(open.frame)) import=\(NSStringFromRect(imp.frame))"
              + " export=\(NSStringFromRect(exp.frame))"
              + " gaps=\(String(format: "%.2f", imp.frame.minX - open.frame.maxX))"
              + "/\(String(format: "%.2f", exp.frame.minX - imp.frame.maxX))")
    }

    // MARK: - A② same selectors / nil targets as the File menu

    func testA2_buttonActionsAreTheMenuItemsActionsAndAllTargetsAreNil() throws {
        let bar = makeBar()
        let file = try fileMenu()
        let importMenuItem = try XCTUnwrap(file.items.first { $0.title == Loc.t("导入照片…") })
        let exportMenuItem = try XCTUnwrap(file.items.first { $0.title == Loc.t("导出…") })

        XCTAssertEqual(bar.importButtonView.action, importMenuItem.action)
        XCTAssertEqual(bar.exportButtonView.action, exportMenuItem.action)
        XCTAssertEqual(bar.importButtonView.action, #selector(EditorWindowController.importAction(_:)))
        XCTAssertEqual(bar.exportButtonView.action, #selector(EditorWindowController.exportAction(_:)))

        XCTAssertNil(bar.importButtonView.target)
        XCTAssertNil(bar.exportButtonView.target)
        XCTAssertNil(importMenuItem.target)
        XCTAssertNil(exportMenuItem.target)
    }

    // MARK: - A③ availability comes from the same two properties

    func testA3_buttonEnablementEqualsValidateMenuItemInEveryState() throws {
        let controller = EditorWindowController(size: NSSize(width: 1600, height: 940))
        defer { controller.window?.orderOut(nil) }
        let root = controller.rootView!
        let bar = root.topBar
        let importMenuItem = importItem()
        let exportMenuItem = exportItem()

        func assertSame(_ state: String) {
            root.updateTopBar()
            XCTAssertEqual(bar.importButtonView.isEnabled, controller.validateMenuItem(importMenuItem),
                           "导入按钮与菜单不同源（\(state)）")
            XCTAssertEqual(bar.exportButtonView.isEnabled, controller.validateMenuItem(exportMenuItem),
                           "导出按钮与菜单不同源（\(state)）")
        }

        // 1. 无库：导入灰（无处可写），导出也灰（没有选区）。
        XCTAssertFalse(root.session.isOpen)
        assertSame("无库")
        XCTAssertFalse(root.canImport, "无库时 canImport 必须为 false")
        XCTAssertFalse(root.canExport, "无库时 canExport 必须为 false")
        XCTAssertFalse(bar.importButtonView.isEnabled)
        XCTAssertFalse(bar.exportButtonView.isEnabled)

        // 2. 开库、空选区：导入亮，导出灰。
        let library = try makeLibrary()
        try controller.openLibrary(at: library.url)
        // `CatalogSession.open` preselects the first row; empty the selection to test the "no export" state.
        root.session.setSelection([])
        assertSame("开库 + 空选区")
        XCTAssertTrue(root.canImport)
        XCTAssertFalse(root.canExport)
        XCTAssertTrue(bar.importButtonView.isEnabled)
        XCTAssertFalse(bar.exportButtonView.isEnabled)

        // 3. 有选区：导出亮。
        let id = try XCTUnwrap(library.ids.first)
        root.session.setSelection([id], anchor: id)
        assertSame("有选区")
        XCTAssertTrue(root.canImport)
        XCTAssertTrue(root.canExport)
        XCTAssertTrue(bar.importButtonView.isEnabled)
        XCTAssertTrue(bar.exportButtonView.isEnabled)

        // 4. isImporting：导入两边同时灰。`start` 在主线程同步把标志置 true，完成回调要等
        //    下一轮主队列，所以这里读到的是确定的「正在导入」。
        let source = tmp.appendingPathComponent("empty-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        root.importCoordinator.start(ImportRequest(sources: [source], includeSubfolders: false))
        XCTAssertTrue(root.isImporting, "start 之后 isImporting 应当是 true")
        assertSame("isImporting")
        XCTAssertFalse(root.canImport)
        XCTAssertFalse(bar.importButtonView.isEnabled)
        pump(until: { !root.isImporting })
        XCTAssertFalse(root.isImporting, "导入没有在超时内结束")
        assertSame("导入结束后")
        XCTAssertTrue(root.canImport)
    }

    // MARK: - A④ layout keeps the status cluster off the controls

    func testA4_controlsTrailingEdgeIsTheRightmostButtonAndTheClusterStaysClear() {
        let bar = makeBar()
        let sort = bar.sortButtonView
        let imp = bar.importButtonView
        let exp = bar.exportButtonView

        // 这一行最右的控件是排序按钮（§3 的固定顺序），所以预算线就是它的右边缘。
        XCTAssertEqual(bar.controlsTrailingEdge, sort.frame.maxX, accuracy: 0.001)
        XCTAssertLessThan(exp.frame.maxX, sort.frame.minX, "导出必须在排序按钮左边")

        // 两个新按钮把后面的控件整体右移了「导入宽 + 导出宽 + 两条 10 pt」。
        let before = bar.controlsTrailingEdge - (imp.frame.width + exp.frame.width + 20)
        XCTAssertEqual(bar.controlsTrailingEdge - before, imp.frame.width + exp.frame.width + 20,
                       accuracy: 0.5)
        XCTAssertGreaterThan(bar.controlsTrailingEdge, before, "加了两个按钮后预算线没有变大")

        XCTAssertGreaterThanOrEqual(bar.statusCluster.frame.minX,
                                    bar.controlsTrailingEdge
                                        + TopBarStatusCluster.Metrics.minimumGapFromControls - 0.001,
                                    "状态簇压到了控件")

        // 1200 pt（最小窗口）仍不重叠；预算被挤到 40 pt 以下时整块隐藏，而不是压到按钮上。
        let narrow = makeBar(width: 1200, inspector: 300)
        XCTAssertGreaterThanOrEqual(narrow.statusCluster.frame.minX,
                                    narrow.controlsTrailingEdge
                                        + TopBarStatusCluster.Metrics.minimumGapFromControls - 0.001,
                                    "1200 pt 下状态簇压到了控件")

        let squeezed = makeBar(width: 1200, inspector: 160,
                               libraryName: String(repeating: "很长的库名", count: 20))
        XCTAssertTrue(squeezed.statusCluster.isHidden,
                      "预算不够时状态簇必须整块隐藏")
        XCTAssertEqual(squeezed.statusCluster.frame.width, 0, accuracy: 0.001,
                       "隐藏的状态簇宽度必须是 0")
        XCTAssertGreaterThanOrEqual(squeezed.statusCluster.frame.minX,
                                    squeezed.controlsTrailingEdge
                                        + TopBarStatusCluster.Metrics.minimumGapFromControls - 0.001,
                                    "隐藏的簇也不许压到按钮上")
        print("A④ trailing=\(String(format: "%.2f", bar.controlsTrailingEdge))"
              + " beforeChange=\(String(format: "%.2f", before))"
              + " delta=\(String(format: "%.2f", bar.controlsTrailingEdge - before))"
              + " clusterMinX=\(String(format: "%.2f", bar.statusCluster.frame.minX))"
              + " narrowClusterMinX=\(String(format: "%.2f", narrow.statusCluster.frame.minX))"
              + " narrowTrailing=\(String(format: "%.2f", narrow.controlsTrailingEdge))"
              + " squeezed=(hidden \(squeezed.statusCluster.isHidden) w \(String(format: "%.2f", squeezed.statusCluster.frame.width)))")
    }

    // MARK: - A⑤ clicking really sends the command

    func testA5_importButtonPresentsThePanelExactlyOnce() throws {
        let controller = EditorWindowController(size: NSSize(width: 1600, height: 940))
        let window = try XCTUnwrap(controller.window)
        TestWindows.show(window, key: true)
        defer { window.orderOut(nil) }
        try controller.openLibrary(at: try makeLibrary().url)
        let root = controller.rootView!
        root.updateTopBar()
        root.topBar.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(root), "根视图必须能进响应链")
        root.importCoordinator.presentPanel = { _ in .cancel }

        let button = root.topBar.importButtonView
        XCTAssertTrue(button.isEnabled, "开库后导入按钮应可用")
        XCTAssertNil(button.target, "按钮必须走响应链，而不是自带 target")
        XCTAssertTrue(press(button, in: window), "响应链上没有处理者")

        XCTAssertEqual(root.importCoordinator.panelPresentationCount, 1,
                       "导入按钮没有把命令送到窗口控制器（或送了两份）")
        XCTAssertEqual(root.importCoordinator.runCount, 0, "取消面板不应启动导入")
        print("A⑤ import: panelPresentationCount=\(root.importCoordinator.panelPresentationCount)"
              + " runCount=\(root.importCoordinator.runCount)")
    }

    func testA5_exportButtonPresentsOneSheetOnly() throws {
        let controller = EditorWindowController(size: NSSize(width: 1600, height: 940))
        let window = try XCTUnwrap(controller.window)
        TestWindows.show(window, key: true)
        defer { window.orderOut(nil) }
        let library = try makeLibrary()
        try controller.openLibrary(at: library.url)
        let root = controller.rootView!
        let id = try XCTUnwrap(library.ids.first)
        root.session.setSelection([id], anchor: id)
        root.updateTopBar()
        root.topBar.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(root), "根视图必须能进响应链")

        let button = root.topBar.exportButtonView
        XCTAssertTrue(button.isEnabled, "有选区时导出按钮应可用")
        XCTAssertNil(button.target, "按钮必须走响应链，而不是自带 target")
        XCTAssertTrue(press(button, in: window), "响应链上没有处理者")

        let sheet = try XCTUnwrap(controller.exportSheet, "导出按钮没有打开 sheet")
        XCTAssertTrue(sheet.isPresented, "导出 sheet 没有挂到窗口上")
        XCTAssertEqual(window.sheets.count, 1, "同一时间只许有一个导出 sheet")

        // 再按一次：同一张 sheet，不叠第二张。
        XCTAssertTrue(press(button, in: window))
        XCTAssertTrue(controller.exportSheet === sheet, "第二次点击又造了一张导出 sheet")
        XCTAssertEqual(window.sheets.count, 1, "第二次点击叠出了第二张 sheet")

        print("A⑤ export: sheets=\(window.sheets.count) firstSheetKept=true")
        sheet.dismiss()
    }

    // MARK: - A⑥ the same style, item by item

    func testA6_newButtonsShareEveryStyleKnobWithTheOpenButton() {
        let bar = makeBar()
        let open = bar.openButtonView
        for (name, button) in [("导入", bar.importButtonView), ("导出", bar.exportButtonView)] {
            XCTAssertEqual(button.font, open.font, "\(name) 的字体与打开不同")
            XCTAssertEqual(button.bezelStyle, open.bezelStyle, "\(name) 的 bezelStyle 与打开不同")
            XCTAssertEqual(button.isBordered, open.isBordered, "\(name) 的 isBordered 与打开不同")
            XCTAssertEqual(button.focusRingType, open.focusRingType, "\(name) 的 focusRingType 与打开不同")
            XCTAssertEqual(button.contentTintColor, open.contentTintColor,
                           "\(name) 的 contentTintColor 与打开不同")
            XCTAssertEqual(button.imagePosition, open.imagePosition, "\(name) 的 imagePosition 与打开不同")
        }
    }

    /// 442 —— **五个按钮的标题逐点同高**（用户报「导入/导出偏低约 2 px、胶片条偏低约 1 px」）。
    ///
    /// 这一条是回归门：`NSButtonCell` 会把「图标 + 标题」当一条基线组居中，而 SF Symbols 的
    /// 对齐矩形随字形不同 —— 实测旧实现的 `cell.titleRect` y 是 8.00 / 8.50 / 8.25 / 9.00 / 9.50。
    /// 现在 `ToolButton` 自己按固定公式摆（`contentGeometry(in:)`），五个按钮必须逐点相等。
    func testAllFiveButtonsShareTheSameTitleBaseline() throws {
        let bar = makeBar()
        let buttons: [(String, ToolButton)] = [
            ("打开", bar.openButtonView),
            ("导入", bar.importButtonView),
            ("导出", bar.exportButtonView),
            ("胶片条", bar.filmstripButtonView),
            ("排序", bar.sortButtonView)
        ]
        for (name, b) in buttons {
            XCTAssertEqual(b.frame.height, WorkspaceLayout.toolButtonHit, accuracy: 0.01,
                           "\(name) 的命中高不是 28")
        }
        let reference = buttons[0].1.contentGeometry(in: buttons[0].1.bounds)
        for (name, b) in buttons.dropFirst() {
            let g = b.contentGeometry(in: b.bounds)
            XCTAssertEqual(g.title.minY, reference.title.minY, accuracy: 0.01,
                           "\(name) 的标题比打开低/高了 \(g.title.minY - reference.title.minY) pt")
            XCTAssertEqual(g.title.height, reference.title.height, accuracy: 0.01,
                           "\(name) 的标题行高与打开不同")
            if let icon = g.icon, let refIcon = reference.icon {
                XCTAssertEqual(icon.midY, refIcon.midY, accuracy: 0.01,
                               "\(name) 的图标竖直中心与打开不同")
            }
        }
        print("442 · 标题 minY = \(reference.title.minY) · 行高 \(reference.title.height) · 五个按钮逐点相等")
    }

    /// 442 —— 「网格 / 单图」是**一个**按钮：文字与图标写的是当前模式，点一下换到另一个，
    /// 且宽度固定为两者较宽者（切换时顶栏不抖）。与「排序」那颗同一个行为。
    func testModeButtonTogglesItsOwnLabelAndKeepsItsWidth() throws {
        let bar = makeBar()
        let button = bar.modeButtonView
        bar.update(mode: .grid, assetCount: 45, selectionCount: 4,
                   libraryName: "topbar-demo", filmstrip: false)
        bar.layoutSubtreeIfNeeded()
        let width = button.frame.width
        XCTAssertEqual(button.title, Loc.t("网格"), "网格模式下按钮应写「网格」")
        XCTAssertEqual(width, bar.modeButtonWidthForTesting, accuracy: 0.01, "宽度不是两者较宽者")

        bar.update(mode: .loupe, assetCount: 45, selectionCount: 4,
                   libraryName: "topbar-demo", filmstrip: false)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.title, Loc.t("单图"), "单图模式下按钮应写「单图」")
        XCTAssertEqual(button.frame.width, width, accuracy: 0.01, "切换模式后按钮宽度变了")
        XCTAssertNotNil(button.image)
    }

    /// 442 —— 排序按钮也是「一个按钮换文字」，宽度必须固定为两种顺序里较宽的那个，
    /// 否则每次切换顶栏都会抖（用户口径：「Olderst first 点击切换为 Newest first 目前也要统一宽度」）。
    func testSortButtonKeepsItsWidthAcrossBothOrders() throws {
        let bar = makeBar()
        bar.updateSortOrder(.newestFirst)
        bar.layoutSubtreeIfNeeded()
        let width = bar.sortButtonView.frame.width
        XCTAssertEqual(width, bar.sortButtonWidthForTesting, accuracy: 0.01,
                       "排序按钮宽度不是两种顺序里较宽的那个")

        bar.updateSortOrder(.oldestFirst)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.sortButtonView.frame.width, width, accuracy: 0.01,
                       "切换顺序后排序按钮宽度变了")
        XCTAssertEqual(bar.sortButtonView.title, PhotoSortOrder.oldestFirst.label)
    }

    /// 442 —— 「胶片条 / 侧栏」也是一个按钮：标题写当前形态，点一下换到另一个，宽度固定。
    func testBrowserButtonTogglesFilmstripAndSidebarKeepingWidth() throws {
        let bar = makeBar()
        let button = bar.browserButtonView
        bar.update(mode: .grid, assetCount: 45, selectionCount: 4,
                   libraryName: "topbar-demo", filmstrip: true)
        bar.layoutSubtreeIfNeeded()
        let width = button.frame.width
        XCTAssertEqual(button.title, Loc.t("胶片条"))
        bar.update(mode: .grid, assetCount: 45, selectionCount: 4,
                   libraryName: "topbar-demo", filmstrip: false)
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(button.title, Loc.t("侧栏"))
        XCTAssertEqual(button.frame.width, width, accuracy: 0.01, "切换后宽度变了")
        XCTAssertEqual(width, bar.browserButtonWidthForTesting, accuracy: 0.01)
    }

    /// 442 —— 排序切换后**刷新完成之前**的点击被丢弃（不排队）：连点 3 下只切 1 次。
    func testSortClicksDuringRefreshAreDropped() throws {
        let controller = EditorWindowController(size: NSSize(width: 1600, height: 940))
        defer { controller.window?.orderOut(nil) }
        let root = try XCTUnwrap(controller.rootView)
        let before = root.session.sortOrder
        let toggle = try XCTUnwrap(root.topBar.onToggleSort)
        toggle()
        XCTAssertTrue(root.isSortBusy, "第一次点击之后闸门应关着")
        let afterFirst = root.session.sortOrder
        XCTAssertNotEqual(afterFirst, before, "第一次点击应该切了顺序")
        toggle()
        toggle()
        XCTAssertEqual(root.session.sortOrder, afterFirst, "刷新期间的点击不许再切")
        XCTAssertEqual(root.sortClicksIgnored, 2, "被丢弃的点击应计数")
    }
}
