import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// §386 — 「模型降噪…」 是**右键菜单**里和 「HDR 合成…」 并排的一行，点下去不弹任何窗口。
///
/// The ticket's acceptance table, walked in order:
///
///   ① 选 1 张 DNG ⇒ 三个面（网格 / 胶片条 / 侧栏）的右键菜单里各有**一行可点**的 `模型降噪…`；
///   ② 2 张 ⇒ 灰 + `模型降噪只处理单张照片`；1 张 JPEG ⇒ 灰 + `只支持 DNG：xxx`；
///      工具缺失 ⇒ 灰 + `未找到 ansel-denoise-swift`；模型缺失 ⇒ 灰 + tooltip 带**完整期望路径**；
///   ③ 跑一次（假 tool，恒等）⇒ 产物是原图的兄弟、`-denoised.dng`，新堆叠 topID = 产物、
///      count == 2，原图若本在别的堆叠里会被抽离，完成后选中的是产物；
///   ⑤ 失败（截断文件）⇒ `lastDenoiseError` 是中文原因、磁盘上没有产物、库里不多一行；
///   ⑥ 整条链路跑在**非主线程**（`denoiseRanOffMain == true`）。
///
/// Every menu assertion goes through the controllers' own right-click entry point — not through
/// `DenoiseMenuBuilder` directly — because "漏挂了一面" is exactly the failure this table catches.
@MainActor
final class DenoiseMenu386Tests: XCTestCase {

    private var workDir: URL!
    private var src: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-denoise386-ui-\(UUID().uuidString)", isDirectory: true)
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

    /// Real (tiny) backing files so `fileURL(for:)` resolves and the job has something to decode.
    /// `dngCount` copies of the committed 1024² fixture; `jpeg` rows are 1-byte placeholders.
    @discardableResult
    private func makeSession(dngCount: Int = 2, jpeg: Int = 1,
                             useFixtureContents: Bool = false) throws -> [Asset] {
        let url = workDir.appendingPathComponent("S386.\(LibraryLayout.packageExtension)", isDirectory: true)
        catalog = try Catalog.create(at: url)
        root = try catalog.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        let total = dngCount + jpeg
        for i in 0..<total {
            let isRaw = i < dngCount
            let name = String(format: isRaw ? "IMG_%04d.dng" : "IMG_%04d.jpg", i)
            let fileURL = src.appendingPathComponent(name)
            if isRaw && useFixtureContents {
                try FileManager.default.copyItem(at: Self.fixtureURL, to: fileURL)
            } else {
                try Data([0x00]).write(to: fileURL)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
                .flatMap { $0 } ?? 1
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: isRaw ? "dng" : "jpg",
                              kind: isRaw ? .raw : .jpeg, size: size, mtime: 0,
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

    /// Tool + model that "exist everywhere" from the menu's point of view: a stand-in executable and
    /// a placeholder `.anselnn`. The stand-in copies the tile file through, so the whole host-side
    /// chain runs in seconds and the assertions are about wiring, not about the network's quality.
    @discardableResult
    private func installFakeTool(on session: CatalogSession) throws -> URL {
        let tool = workDir.appendingPathComponent("fake-ansel-denoise-swift")
        let script = """
        #!/bin/sh
        input="$3"
        out=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--out" ]; then out="$2"; shift 2; continue; fi
          shift
        done
        if [ -z "$out" ] || [ ! -f "$input" ]; then exit 3; fi
        cp "$input" "$out" || exit 4
        echo '{"tiles":1,"tileSize":128,"ms":1.0,"backend":"fake","cfa":"rggb"}'
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

    private func denoiseRow(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == DenoiseMenuBuilder.title }
    }

    // MARK: - ① 三面各一行，可点

    func testTheDenoiseRowIsEnabledInAllThreeBrowsersForOneDNG() throws {
        let assets = try makeSession()
        try installFakeTool(on: session)
        let chosen = try XCTUnwrap(assets.first { $0.ext == "dng" })
        let surfaces = makeSurfaces()
        session.setSelection([chosen.id], anchor: chosen.id)
        pump(0.1)

        let menus = try self.menus(surfaces)
        XCTAssertEqual(menus.count, 3)
        for name in ["grid", "filmstrip", "browser"] {
            let menu = try XCTUnwrap(menus[name])
            let row = try XCTUnwrap(denoiseRow(in: menu), "① \(name) 的右键菜单里没有「模型降噪…」")
            print("① \(name)：row=\"\(row.title)\" enabled=\(row.isEnabled) "
                  + "tooltip=\(row.toolTip ?? "nil") 并列项=\(menu.items.map(\.title))")
            XCTAssertEqual(row.title, "模型降噪…")
            XCTAssertTrue(row.isEnabled, "① \(name)：1 张 DNG 应该可点")
            XCTAssertEqual(row.toolTip?.isEmpty, false, "① 可点的那一行也带一句说明")
            XCTAssertTrue(row.toolTip?.contains("IMG_0000-denoised.dng") ?? false,
                          "① 说明里点名将生成的文件")
        }
    }

    // MARK: - ② 灰掉的四种条件（三面各一次）

    func testTwoPhotosGreyTheRowInAllThreeBrowsers() throws {
        let assets = try makeSession()
        try installFakeTool(on: session)
        let dngs = assets.filter { $0.ext == "dng" }
        let surfaces = makeSurfaces()
        session.setSelection(Set(dngs.map(\.id)), anchor: dngs[0].id)
        pump(0.1)

        let menus = try self.menus(surfaces)
        for name in ["grid", "filmstrip", "browser"] {
            let row = try XCTUnwrap(denoiseRow(in: try XCTUnwrap(menus[name])))
            print("② 两张 DNG [\(name)]：enabled=\(row.isEnabled) tooltip=\(row.toolTip ?? "nil")")
            XCTAssertFalse(row.isEnabled)
            XCTAssertEqual(row.toolTip, "模型降噪只处理单张照片")
        }
    }

    func testAZeroSelectionGreyTheRow() throws {
        _ = try makeSession()
        try installFakeTool(on: session)
        let surfaces = makeSurfaces()
        session.setSelection([], anchor: nil)
        pump(0.1)
        let row = try XCTUnwrap(denoiseRow(in: try XCTUnwrap(surfaces.grid.menuForRightClick(nil))))
        print("② 零选择：enabled=\(row.isEnabled) tooltip=\(row.toolTip ?? "nil")")
        XCTAssertFalse(row.isEnabled)
        XCTAssertEqual(row.toolTip, "模型降噪只处理单张照片")
    }

    func testASingleJPEGGreyTheRowWithItsName() throws {
        let assets = try makeSession()
        try installFakeTool(on: session)
        let jpeg = try XCTUnwrap(assets.first { $0.ext == "jpg" })
        let surfaces = makeSurfaces()
        session.setSelection([jpeg.id], anchor: jpeg.id)
        pump(0.1)

        let menus = try self.menus(surfaces)
        for name in ["grid", "filmstrip", "browser"] {
            let row = try XCTUnwrap(denoiseRow(in: try XCTUnwrap(menus[name])))
            print("② JPEG [\(name)]：enabled=\(row.isEnabled) tooltip=\(row.toolTip ?? "nil")")
            XCTAssertFalse(row.isEnabled)
            XCTAssertEqual(row.toolTip, "只支持 DNG：\(jpeg.filename)")
        }
    }

    func testAMissingToolLeavesAGreyRowThatSaysSo() throws {
        let assets = try makeSession()
        try installFakeTool(on: session)
        let chosen = try XCTUnwrap(assets.first { $0.ext == "dng" })
        let surfaces = makeSurfaces()
        session.setSelection([chosen.id], anchor: chosen.id)
        pump(0.1)
        // A path that does not exist — the same condition as a bundle that lost its binary.
        session.denoiseLocation.executableURL = workDir.appendingPathComponent("no-such-tool")

        let menus = try self.menus(surfaces)
        for name in ["grid", "filmstrip", "browser"] {
            let row = try XCTUnwrap(denoiseRow(in: try XCTUnwrap(menus[name])))
            print("② 工具缺失 [\(name)]：enabled=\(row.isEnabled) tooltip=\(row.toolTip ?? "nil")")
            XCTAssertFalse(row.isEnabled)
            XCTAssertEqual(row.toolTip, "未找到 ansel-denoise-swift",
                           "② 必须点名缺的是什么，而不是静默消失")
        }
    }

    func testAMissingModelGreyTheRowAndNamesTheFullExpectedPath() throws {
        let assets = try makeSession()
        try installFakeTool(on: session)
        let chosen = try XCTUnwrap(assets.first { $0.ext == "dng" })
        let surfaces = makeSurfaces()
        session.setSelection([chosen.id], anchor: chosen.id)
        pump(0.1)

        let expected = AnselDenoiseLocation.expectedModelPath(variant: .quarter)
        session.denoiseLocation.modelURL = expected        // explicitly the user-directory path

        let menus = try self.menus(surfaces)
        for name in ["grid", "filmstrip", "browser"] {
            let row = try XCTUnwrap(denoiseRow(in: try XCTUnwrap(menus[name])))
            let tooltip = try XCTUnwrap(row.toolTip)
            print("② 模型缺失 [\(name)]：enabled=\(row.isEnabled) tooltip=\(tooltip)")
            XCTAssertFalse(row.isEnabled)
            XCTAssertTrue(tooltip.contains(expected.path), "② tooltip 必须带完整期望路径")
            XCTAssertEqual(tooltip, "未找到降噪模型：\(expected.path)")
        }
    }

    // MARK: - ③ 真跑一次（假 tool）：堆叠与置顶、抽离旧堆叠

    func testTheProductStacksOnTopOfTheOriginal() throws {
        let assets = try makeSession(dngCount: 2, jpeg: 0, useFixtureContents: true)
        try installFakeTool(on: session)
        let target = try XCTUnwrap(assets.first { $0.ext == "dng" })
        let other = try XCTUnwrap(assets.last { $0.ext == "dng" })
        // The original already sits in a stack with a third photo's worth of company (the "other"
        // row): after denoising it must be **out** of that stack (§3 ③).
        try catalog.makeStack(assetIDs: [target.id, other.id])
        session.reload()
        session.setSelection([target.id], anchor: target.id)

        let rowsBefore = try rowCount()
        let participants = session.denoiseSelection()
        XCTAssertEqual(participants, [target.id], "参与的是选中的那一张")
        waitForDenoise(timeout: 300)

        let report = try XCTUnwrap(session.lastDenoiseReport,
                                   "③ 失败：\(session.lastDenoiseError ?? "nil")")
        print("③ output=\(report.output.path) \(report.width)×\(report.height) "
              + "cfa=\(report.cfa) tiles=\(report.tiles) bytes=\(report.byteCount) "
              + "topID==product? \(report.stackTopID == report.assetID) count=\(report.stackCount)")

        XCTAssertNil(session.lastDenoiseError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.output.path))
        XCTAssertEqual(report.output.lastPathComponent, "IMG_0000-denoised.dng")
        XCTAssertEqual(report.output.deletingLastPathComponent().standardizedFileURL,
                       src.standardizedFileURL, "③ 产物落在原文件同目录")

        let stack = try XCTUnwrap(session.stacksByTopID[report.stackTopID])
        XCTAssertEqual(stack.topID, report.assetID, "③ 产物必须是新堆叠的置顶")
        XCTAssertEqual(stack.count, 2, "③ 产物 + 原图")
        XCTAssertTrue(stack.memberIDs.contains(target.id))

        // The original's old stack lost it; the leftover row dissolved to a single member.
        let oldStack = try stackRow(for: other.id)
        print("③ 原图旧堆叠的同伴 stack_id=\(String(describing: oldStack.stack)) "
              + "rank=\(oldStack.rank)")
        XCTAssertNil(oldStack.stack, "③ 只剩一张时旧堆叠必须解散")

        XCTAssertEqual(try rowCount(), rowsBefore + 1, "③ 库里只多出产物这一行")
        XCTAssertEqual(session.selection, [report.assetID], "③ 完成后选中的是产物")
        XCTAssertEqual(session.denoiseRanOffMain, true, "⑥ 阻塞的那一半必须在后台队列")
        XCTAssertEqual(session.denoiseCompletionCount, 1)
        XCTAssertEqual(session.lastDenoiseReport?.stackCount, 2)
    }

    // MARK: - ⑤ 失败不留垃圾

    func testAFailedRunLeavesNoFileAndNoRow() throws {
        let assets = try makeSession(dngCount: 1, jpeg: 0)
        try installFakeTool(on: session)
        let target = try XCTUnwrap(assets.first)
        // A 5-byte "DNG": the header alone, so decode fails after the tool/model gates pass.
        try Data([0x49, 0x49, 0x2a, 0x00, 0x08]).write(to: src.appendingPathComponent(target.filename))
        let rowsBefore = try rowCount()
        session.setSelection([target.id], anchor: target.id)

        session.denoiseSelection()
        waitForDenoise(timeout: 60)

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: src.path)
            .filter { $0.contains("-denoised") }
        print("⑤ error=\"\(session.lastDenoiseError ?? "nil")\" rows \(rowsBefore)→\(try rowCount()) "
              + "leftovers=\(leftovers) ranOffMain=\(String(describing: session.denoiseRanOffMain))")
        XCTAssertNotNil(session.lastDenoiseError)
        XCTAssertTrue(session.lastDenoiseError?.contains("解码 RAW 失败") ?? false,
                      "⑤ 必须是中文原因，实际：\(session.lastDenoiseError ?? "nil")")
        XCTAssertTrue(leftovers.isEmpty, "⑤ 磁盘上不许出现 \(leftovers)")
        XCTAssertEqual(try rowCount(), rowsBefore, "⑤ 库里不多一行")
        XCTAssertNil(session.lastDenoiseReport)
        XCTAssertEqual(session.denoiseRanOffMain, true, "⑥ 失败路径同样是 off-main")
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

    /// Wait for the background half without sleeping blind: the completion hop is a main-actor task,
    /// so the main run loop has to turn for it to run.
    private func waitForDenoise(timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.denoiseCompletionCount > 0 { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("降噪在 \(timeout) s 内没有回来")
    }
}
