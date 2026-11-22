import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// §432 — 「模型降噪(AI denoise)要设置两个入口」。
///
/// 这个 suite 只验**新增的那一半**（两条入口与共用路径）；386 的既有契约仍由
/// `DenoiseMenu386Tests` 守着（它现在读的是 Ansel 那一行）。
///
/// 判据对应派单的编号：
///
///   A② 两个菜单项的可用性**独立**：缺 ansel 工具时 Nonlocal 仍可点，缺 NLMF 模型时 Ansel 仍可点；
///       「正在跑」是另一件事，两条都灰，但那句 notice 是它自己的；
///   A③ 两个入口走**同一条**产物/堆叠路径：产物名、同目录、`makeStack(产物, [原图])`、产物置顶、
///       选中产物 —— 这里用 Nonlocal 真跑一次（推理换成照抄输入的替身，命名/落盘是生产代码）；
///   A④ 两条 notice 文案**不共用**：一句点名工具，一句点名模型 + 完整期望路径。
@MainActor
final class DenoiseTwoEntries432Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise432-\(UUID().uuidString)", isDirectory: true)
        src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - fixture

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    private var catalog: Catalog!
    private var session: CatalogSession!
    private var root: SourceRoot!

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    @discardableResult
    private func makeSession(dngCount: Int = 1) throws -> [Asset] {
        let url = workDir.appendingPathComponent("S432.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: url)
        root = try catalog.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        for i in 0..<dngCount {
            let name = String(format: "IMG_%04d.dng", i)
            let fileURL = src.appendingPathComponent(name)
            try FileManager.default.copyItem(at: Self.fixtureURL, to: fileURL)
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
                .flatMap { $0 } ?? 1
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: "dng", kind: .raw, size: size, mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 1024, height: 1024,
                              captureTime: String(format: "2026-05-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-05-01",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }

        let store = MemoryStore()
        let s = CatalogSession(filterStore: store, sortPreferenceStore: store,
                               remembersRecentLibrary: false)
        try s.open(url)
        s.setSortOrder(.newestFirst)
        session = s
        return assets
    }

    /// Ansel 那条路的依赖就位：一个会说 `image-dng` 的假可执行文件 + 一个占位模型。
    @discardableResult
    private func installFakeAnsel(on session: CatalogSession) throws -> URL {
        let tool = workDir.appendingPathComponent("fake-ansel-denoise-swift")
        let script = """
        #!/bin/sh
        if [ "$1" = "capabilities" ]; then
          echo '{"tool":{"name":"ansel-denoise-swift","protocol":2},"gpu":"Fake GPU","features":["image","image-dng","gpu"]}'
          exit 0
        fi
        input="$3"
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--out" ]; then out="$2"; shift 2; continue; fi
          shift
        done
        if [ -z "$out" ] || [ ! -f "$input" ]; then exit 3; fi
        cp "$input" "$out" || exit 4
        echo '{"width":1024,"height":1024,"cfa":"rggb","mosaicCfa":"rggb","pieces":1,"columns":1,"rows":1,"seams":0,"seconds":0.05,"readSeconds":0.0,"inferenceSeconds":0.05,"writeSeconds":0.0,"backend":"fake","outputBytes":1}'
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let model = workDir.appendingPathComponent(AnselDenoiseVariant.quarter.modelFileName)
        try Data(repeating: 0, count: 64).write(to: model)

        var location = AnselDenoiseLocation(executableURL: tool, modelURL: model)
        location.variant = .quarter
        session.denoiseLocation = location
        return tool
    }

    /// NLMF 那条路的依赖就位：模型目录存在就够（`isAvailable` 是文件存在性检查）。
    private func installNLMFModel(on session: CatalogSession) throws -> URL {
        let model = workDir.appendingPathComponent("v_matmul_256.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        session.nlmfModelURL = model
        return model
    }

    private struct Surfaces {
        let grid: AssetGridController
        let strip: FilmstripController
        let pane: BrowserPaneController
    }

    private func makeSurfaces() -> Surfaces {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 1200))
        window.contentView = content
        windows.append(window)

        let grid = AssetGridController(session: session)
        _ = grid.view
        grid.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 800)
        content.addSubview(grid.view)

        let strip = FilmstripController(session: session)
        _ = strip.view
        strip.view.frame = NSRect(x: 0, y: 800, width: 1600, height: WorkspaceLayout.filmstripHeight)
        content.addSubview(strip.view)

        let pane = BrowserPaneController(session: session)
        _ = pane.view
        _ = pane.applyLayout(in: CGSize(width: WorkspaceLayout.browserWidthDefault, height: 744))
        content.addSubview(pane.view)

        content.layoutSubtreeIfNeeded()
        pump(0.2)
        return Surfaces(grid: grid, strip: strip, pane: pane)
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    private func menus(_ surfaces: Surfaces) throws -> [String: NSMenu] {
        var out: [String: NSMenu] = [:]
        out["grid"] = try XCTUnwrap(surfaces.grid.menuForRightClick(nil))
        out["filmstrip"] = try XCTUnwrap(surfaces.strip.menuForRightClick(nil))
        surfaces.pane.prepareContextMenu()
        out["browser"] = surfaces.pane.contextMenu.menu
        return out
    }

    private func rows(in menu: NSMenu) -> [NSMenuItem] {
        DenoiseEngine.allCases.compactMap { engine in
            menu.items.first { $0.title == DenoiseMenuBuilder.title(for: engine) }
        }
    }

    // MARK: - A④ 两个菜单项的文案

    /// 两项都在、标题不同、都点名自己的网络 —— 这是「两个入口」最直接的证据。
    func testBothEntriesAppearInAllThreeBrowsers() throws {
        _ = try makeSession()
        try installFakeAnsel(on: session)
        try installNLMFModel(on: session)
        let surfaces = makeSurfaces()
        let menus = try self.menus(surfaces)

        print("A④ 并列项：\(menus.mapValues { $0.items.map(\.title) })")
        for name in ["grid", "filmstrip", "browser"] {
            let menu = try XCTUnwrap(menus[name])
            let entries = rows(in: menu)
            XCTAssertEqual(entries.count, 2, "\(name)：必须两行（不是子菜单、不是一行）")
            XCTAssertEqual(entries.map(\.title), ["模型降噪（Ansel）…", "模型降噪（Nonlocal）…"],
                           "\(name)：两项的顺序与文案")
            for row in entries {
                XCTAssertTrue(row.isEnabled, "\(name)：两条依赖都在时可点（行=\(row.title)）")
            }
        }
    }

    /// A④ —— 缺依赖时两句 notice **必须不同**：一句说工具，一句说模型 + 完整期望路径。
    func testTheTwoNoticesAreDifferentSentences() throws {
        _ = try makeSession()
        try installFakeAnsel(on: session)
        try installNLMFModel(on: session)
        let surfaces = makeSurfaces()

        // 1) 缺 ansel 工具
        session.denoiseLocation.executableURL = workDir.appendingPathComponent("no-such-tool")
        var menus = try self.menus(surfaces)
        let anselTool = try XCTUnwrap(rows(in: try XCTUnwrap(menus["grid"]))
            .first { $0.title == DenoiseMenuBuilder.title(for: .ansel) })
        XCTAssertEqual(anselTool.toolTip, "未找到 ansel-denoise-swift")

        // 2) 缺 NLMF 模型
        let absent = workDir.appendingPathComponent("no-such-model.mlpackage")
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path), "前提：路径必须不存在")
        session.nlmfModelURL = absent
        menus = try self.menus(surfaces)
        let nlmfRow = try XCTUnwrap(rows(in: try XCTUnwrap(menus["grid"]))
            .first { $0.title == DenoiseMenuBuilder.title(for: .nonlocal) })
        let nlmfNotice = try XCTUnwrap(nlmfRow.toolTip)
        print("A④ ansel=\(anselTool.toolTip ?? "nil") · nlmf=\(nlmfNotice)")

        XCTAssertNotEqual(nlmfNotice, "未找到 ansel-denoise-swift", "两句不许共用")
        XCTAssertTrue(nlmfNotice.contains(absent.path), "必须带完整期望路径")
        XCTAssertEqual(nlmfNotice, "未找到 nonlocal 降噪模型：\(absent.path)")
    }

    /// A④（不显式注入时）—— NLMF 的 hint 是**三个候选全写出来**，与 ansel 那条同构，
    /// 这样「缺模型」指向的是随包位置而用户能一眼看出是打包问题。
    func testTheNLMFHintNamesTheBundledAndUserPaths() throws {
        _ = try makeSession()
        let hint = session.nlmfDenoiseModelPathHint

        print("A④ NLMF hint=\(hint)")
        XCTAssertTrue(hint.contains("Photons_PhotonsExtensions.bundle"),
                      "必须点名随包（target bundle）那条：\(hint)")
        XCTAssertTrue(hint.contains("v_matmul_256.mlpackage"), "必须点名模型文件：\(hint)")
        XCTAssertTrue(hint.contains("Application Support/Photons/models"),
                      "用户换变体那条也要写出来：\(hint)")
        XCTAssertTrue(hint.contains(NLMFDenoiseJob.environmentKey),
                      "环境变量那条要写出名字：\(hint)")
    }

    // MARK: - A② 两个入口的可用性独立

    func testAGreyAnselEntryLeavesTheNonlocalEntryLive() throws {
        _ = try makeSession()
        try installFakeAnsel(on: session)
        try installNLMFModel(on: session)
        let surfaces = makeSurfaces()
        session.selectOnly(try XCTUnwrap(session.assets.first).id)
        pump(0.1)
        // Ansel 的工具没了，但模型与 NLMF 都还在。
        session.denoiseLocation.executableURL = workDir.appendingPathComponent("no-such-tool")

        let menus = try self.menus(surfaces)
        for name in ["grid", "filmstrip", "browser"] {
            let entries = rows(in: try XCTUnwrap(menus[name]))
            let ansel = try XCTUnwrap(entries.first { $0.title == DenoiseMenuBuilder.title(for: .ansel) })
            let nlmf = try XCTUnwrap(entries.first { $0.title == DenoiseMenuBuilder.title(for: .nonlocal) })
            print("A② 缺工具 [\(name)]：ansel=\(ansel.isEnabled)/\(ansel.toolTip ?? "nil") "
                  + "nlmf=\(nlmf.isEnabled)/\(nlmf.toolTip ?? "nil")")
            XCTAssertFalse(ansel.isEnabled, "\(name)：Ansel 应该灰")
            XCTAssertEqual(ansel.toolTip, "未找到 ansel-denoise-swift")
            XCTAssertTrue(nlmf.isEnabled, "\(name)：Nonlocal 不依赖工具，必须仍可点")
        }
    }

    func testAGreyNonlocalEntryLeavesTheAnselEntryLive() throws {
        _ = try makeSession()
        try installFakeAnsel(on: session)
        try installNLMFModel(on: session)
        let surfaces = makeSurfaces()
        session.selectOnly(try XCTUnwrap(session.assets.first).id)
        pump(0.1)
        // NLMF 的模型没了，但 Ansel 的工具与模型都在。
        session.nlmfModelURL = workDir.appendingPathComponent("no-such-model.mlpackage")

        let menus = try self.menus(surfaces)
        for name in ["grid", "filmstrip", "browser"] {
            let entries = rows(in: try XCTUnwrap(menus[name]))
            let ansel = try XCTUnwrap(entries.first { $0.title == DenoiseMenuBuilder.title(for: .ansel) })
            let nlmf = try XCTUnwrap(entries.first { $0.title == DenoiseMenuBuilder.title(for: .nonlocal) })
            print("A② 缺模型 [\(name)]：ansel=\(ansel.isEnabled) nlmf=\(nlmf.isEnabled)/\(nlmf.toolTip ?? "nil")")
            XCTAssertTrue(ansel.isEnabled, "\(name)：Ansel 两条依赖都在，必须仍可点")
            XCTAssertFalse(nlmf.isEnabled, "\(name)：Nonlocal 缺模型，应该灰")
            XCTAssertTrue(nlmf.toolTip?.contains("no-such-model.mlpackage") ?? false,
                          "\(name)：灰掉的理由要点名模型路径")
        }
    }

    /// A② 的另一半 —— 「正在跑」不是「缺依赖」：跑着的时候这一行灰，但那句话是运行态的
    /// 一句（432 的原文是 `已有一次模型降噪在进行`，510 起是「正在降噪」），两条都不许改说
    /// 「缺模型 / 缺工具」。
    ///
    /// 510 — 那句 notice 的**口径**变了：它现在说的是「**这张照片自己**在跑」（「正在降噪」），
    /// 而不再是「全应用有活在跑」。本条的牙齿因此升级成两组：
    ///   · 正在跑的这张：仍然灰、仍然是**运行态**那句（不是缺依赖）；
    ///   · **别的照片**：行必须可点，点下去只是入队 —— `lastDenoiseError` 必须是 nil，
    ///     队列深度 +1。这就是「不再全局灰」的机器可验证形式。
    func testRunningIsItsOwnNoticeAndDoesNotBecomeADependencyNotice() throws {
        let assets = try makeSession(dngCount: 2)
        try installFakeAnsel(on: session)
        try installNLMFModel(on: session)
        let surfaces = makeSurfaces()
        let asset = try XCTUnwrap(assets.first)
        let other = try XCTUnwrap(assets.last)
        session.selectOnly(asset.id)
        pump(0.1)

        // 推理替身：照抄输入，然后在闸门上等 —— 后台队列被占住，主线程仍能读菜单。
        let started = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        session.nlmfDenoiseBody = { source, output, _ in
            try? FileManager.default.copyItem(at: source, to: output)
            started.signal()
            _ = gate.wait(timeout: .now() + 60)
            return NLMFDenoiseExecutor.Report(width: 1024, height: 1024, cfa: "rggb",
                                              tiles: 1, seconds: 0.01, byteCount: 1)
        }

        session.denoiseSelectionNlmf()
        XCTAssertEqual(started.wait(timeout: .now() + 30), .success, "推理没有开始")
        defer { gate.signal() }

        let menus = try self.menus(surfaces)
        for name in ["grid", "filmstrip", "browser"] {
            for row in rows(in: try XCTUnwrap(menus[name])) {
                print("A② 运行中 [\(name)] \(row.title)：enabled=\(row.isEnabled) tooltip=\(row.toolTip ?? "nil")")
                XCTAssertFalse(row.isEnabled, "\(name)：这张正在跑，行必须灰")
                // 510 — 「正在跑」的句子从 432 的全局口径（`已有一次模型降噪在进行`）细化成
                // 「这张照片自己在跑」（`正在降噪`）。本条的意图不变：**运行态不许被说成缺依赖**。
                XCTAssertEqual(row.toolTip, DenoiseNotices.runningThisPhoto,
                               "\(name)：运行态不许被说成缺依赖")
            }
        }

        // ---- 510 的另一半：别的照片**不该**被这个运行态挡住 ----
        let depthBefore = session.denoiseQueueDepth
        session.selectOnly(other.id)
        let otherMenus = try self.menus(surfaces)
        for name in ["grid", "filmstrip", "browser"] {
            for row in rows(in: try XCTUnwrap(otherMenus[name])) {
                print("510 别的照片 [\(name)] \(row.title)：enabled=\(row.isEnabled) tooltip=\(row.toolTip ?? "nil")")
                XCTAssertTrue(row.isEnabled, "\(name)：别的照片在跑不许把这一行灰掉")
            }
        }
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [other.id], "别的照片应当入队")
        XCTAssertNil(session.lastDenoiseError, "入队不是错误：lastDenoiseError 必须是 nil")
        XCTAssertEqual(session.denoiseQueueDepth, depthBefore + 1, "队列深度必须 +1")
        XCTAssertTrue(session.lastDenoiseQueueNotice?.contains("队列") ?? false,
                      "入队要说清「已加入降噪队列」")

        // 同一张再来一次 ⇒ 仍然是它自己的那句；已排队的那张 ⇒ 「已在队列中」。
        session.selectOnly(asset.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [])
        XCTAssertEqual(session.lastDenoiseError, DenoiseNotices.runningThisPhoto)
        session.selectOnly(other.id)
        XCTAssertEqual(session.denoiseSelection(engine: .nonlocal), [])
        XCTAssertEqual(session.lastDenoiseError, DenoiseNotices.alreadyQueued)
        XCTAssertEqual(session.denoiseQueueDepth, depthBefore + 1, "同一张永不会有第二个排队请求")

        // 收尾：两条都放行，别把 60 s 的等待留给拆除阶段。
        gate.signal(); gate.signal()
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, session.denoiseQueueDepth > 0 || session.isDenoiseRunning {
            pump(0.01)
        }
    }

    // MARK: - A③ 两个入口共用同一条产物/堆叠路径

    /// Nonlocal 真跑一次（推理换成照抄输入的替身）。断言与 386 的 Ansel 那条**逐条对应**：
    /// 产物名、同目录、`makeStack(产物, [原图])`、产物置顶、选中产物、off-main。
    func testTheNonlocalEntryLandsOnTheSameProductAndStackPath() throws {
        let assets = try makeSession(dngCount: 2)
        try installFakeAnsel(on: session)
        try installNLMFModel(on: session)
        let target = try XCTUnwrap(assets.first)
        let other = try XCTUnwrap(assets.last)
        // 原图本来在另一个堆叠里：Nonlocal 这条也必须把它抽离。
        try catalog.makeStack(assetIDs: [target.id, other.id])
        session.reload()
        session.setSelection([target.id], anchor: target.id)

        session.nlmfDenoiseBody = { source, output, _ in
            try FileManager.default.copyItem(at: source, to: output)
            return NLMFDenoiseExecutor.Report(width: 1024, height: 1024, cfa: "rggb",
                                              tiles: 1, seconds: 0.01, byteCount: 1)
        }

        let rowsBefore = try rowCount()
        let participants = session.denoiseSelectionNlmf()
        XCTAssertEqual(participants, [target.id], "参与的是选中的那一张")
        waitForDenoise(timeout: 120)

        let report = try XCTUnwrap(session.lastDenoiseReport,
                                   "A③ 失败：\(session.lastDenoiseError ?? "nil")")
        print("A③ output=\(report.output.path) topID==product? \(report.stackTopID == report.assetID) "
              + "count=\(report.stackCount) engine=\(String(describing: session.lastDenoiseEngine))")

        XCTAssertNil(session.lastDenoiseError)
        XCTAssertEqual(session.lastDenoiseEngine, .nonlocal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.output.path))
        XCTAssertEqual(report.output.lastPathComponent, "IMG_0000-denoised.dng",
                       "A③ 命名必须与 Ansel 一致")
        XCTAssertEqual(report.output.deletingLastPathComponent().standardizedFileURL,
                       src.standardizedFileURL, "A③ 产物与原图同目录")

        let stack = try XCTUnwrap(session.stacksByTopID[report.stackTopID])
        XCTAssertEqual(stack.topID, report.assetID, "A③ 产物是新堆叠的置顶")
        XCTAssertEqual(stack.count, 2, "A③ 产物 + 原图")
        XCTAssertTrue(stack.memberIDs.contains(target.id))
        XCTAssertNil(try stackRow(for: other.id).stack, "A③ 原图旧堆叠解散")
        XCTAssertEqual(session.selection, [report.assetID], "A③ 完成后选中的是产物")
        XCTAssertEqual(session.denoiseRanOffMain, true, "A③ 阻塞的那一半在后台队列")
        XCTAssertEqual(try rowCount(), rowsBefore + 1, "A③ 库里只多出产物这一行")
    }

    // MARK: - helpers

    private func rowCount() throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? -1
        }
    }

    private func stackRow(for id: String) throws -> (stack: String?, rank: Int) {
        try catalog.dbQueue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT stack_id, stack_rank FROM assets WHERE id = ?",
                                       arguments: [id])
            return (row?["stack_id"] as String?, row?["stack_rank"] as Int? ?? -1)
        }
    }

    private func waitForDenoise(timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.denoiseCompletionCount > 0 { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("降噪在 \(timeout) s 内没有回来")
    }
}
