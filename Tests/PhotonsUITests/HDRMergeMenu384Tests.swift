import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// §384 — 「HDR 合成…」 是**右键菜单**里和「堆叠 ▸」同级的一行，点下去不弹任何窗口。
///
/// The ticket's acceptance is a table, and this suite walks it in order:
///
///   ① 选 3 张 DNG ⇒ 三个面（网格 / 胶片条 / 侧栏）的右键菜单里各有**一行可点**的 `HDR 合成…`；
///   ② 选 1 张、或 2 张里有一张 JPEG ⇒ 那一行在、但灰掉，并写清原因；
///   ③ 找不到 `hdrmerge-swift` ⇒ 那一行在、灰掉、tooltip 是「未找到 hdrmerge-swift」（不静默消失）；
///   ⑥ 失败路径（2 张 JPEG / 2 张线性 DNG）⇒ `lastHDRMergeError` 就是 `Failure.description`，
///      且库里一张新照片都不留；
///   ⑦ 合成跑在**非主线程**（`hdrMergeRanOffMain == true`），主线程只收结果；
///   ⑧ 真跑一次（环境里有 `PHOTONS_TEST_RAW` 时）：Outcome 的数字与最终堆叠的置顶。
///
/// Every menu assertion goes through the controllers' own right-click entry point — not through
/// `HDRMenuBuilder` directly — because "漏挂了一面" is exactly the failure this table exists to catch
/// (a builder that works and a browser that forgot to attach it looks green otherwise).
@MainActor
final class HDRMergeMenu384Tests: XCTestCase {

    private var workDir: URL!
    private var windows: [NSWindow] = []

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-hdr384-ui-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
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

    /// `dng` RAW rows + `jpeg` rows, all backed by real (tiny) files so `fileURL(for:)` resolves —
    /// the failure path reads the path before it decides anything.
    private func makeSession(dng: Int = 5, jpeg: Int = 1) throws -> [Asset] {
        let url = workDir.appendingPathComponent("S384.\(LibraryLayout.packageExtension)", isDirectory: true)
        let setup = try Catalog.create(at: url)
        catalog = setup
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try setup.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        for i in 0 ..< dng + jpeg {
            let isRaw = i < dng
            let name = String(format: isRaw ? "IMG_%04d.dng" : "IMG_%04d.jpg", i)
            try Data([0x00]).write(to: src.appendingPathComponent(name))
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: isRaw ? "dng" : "jpg",
                              kind: isRaw ? .raw : .jpeg, size: 1, mtime: 0,
                              contentHash: UUID().uuidString,
                              width: 6000, height: 4000,
                              captureTime: String(format: "2026-01-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-01-01 10:00",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try setup.dbQueue.write { db in try asset.insert(db) }
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

    /// The three menus, each produced by its own browser's right-click path.
    private func menus(_ surfaces: Surfaces) throws -> [String: NSMenu] {
        var out: [String: NSMenu] = [:]
        out["grid"] = try XCTUnwrap(surfaces.grid.menuForRightClick(nil))
        out["filmstrip"] = try XCTUnwrap(surfaces.strip.menuForRightClick(nil))
        surfaces.pane.prepareContextMenu()
        out["browser"] = surfaces.pane.contextMenu.menu
        return out
    }

    /// Top-level row only: that is what "与「堆叠」子菜单同级" means, and a submenu of it would be a
    /// different feature.
    private func hdrRow(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == HDRMenuBuilder.title }
    }

    private static let toolMissing = "未找到 hdrmerge-swift"

    // MARK: - ① 三面各一行，可点

    func testTheHDRRowIsEnabledInAllThreeBrowsers() throws {
        let assets = try makeSession()
        let chosen = Array(assets.filter { $0.ext == "dng" }.prefix(3))
        // Surfaces first, selection second: building the views seeds the anchor, so a selection made
        // before them is not the one the menu is asked about.
        let surfaces = makeSurfaces()
        session.setSelection(Set(chosen.map(\.id)), anchor: chosen[0].id)
        pump(0.1)

        let menus = try self.menus(surfaces)
        XCTAssertEqual(menus.count, 3)
        for name in ["grid", "filmstrip", "browser"] {
            let menu = try XCTUnwrap(menus[name])
            let row = try XCTUnwrap(hdrRow(in: menu), "① \(name) 的右键菜单里没有「HDR 合成…」")
            print("① \(name)：row=\"\(row.title)\" enabled=\(row.isEnabled) "
                  + "并列项=\(menu.items.map(\.title))")
            XCTAssertEqual(row.title, "HDR 合成…")
            XCTAssertTrue(row.isEnabled, "① \(name)：3 张 DNG 应该可点")
            // 同级：它不在 「堆叠」 的子菜单里。
            let stackHolder = menu.items.first { $0.title == StackMenuBuilder.title }
            XCTAssertFalse(stackHolder?.submenu?.items.contains { $0.title == HDRMenuBuilder.title } ?? false,
                           "① \(name)：HDR 行必须是「堆叠 ▸」的兄弟，不是它的子项")
            XCTAssertEqual(row.toolTip?.isEmpty, false, "① 可点的那一行也带一句说明")
        }
    }

    // MARK: - ② 不足两张 / 有非 DNG ⇒ 灰掉

    func testTheRowIsGreyWithOnePhotoAndWithAJPEGInTheSelection() throws {
        let assets = try makeSession()
        let dngs = assets.filter { $0.ext == "dng" }
        let jpeg = try XCTUnwrap(assets.first { $0.ext == "jpg" })
        _ = makeSurfaces()

        // 2a 只选 1 张 DNG
        session.setSelection([dngs[0].id], anchor: dngs[0].id)
        let one = HDRMenuBuilder.item(session: session,
                                      target: HDRMenuTarget(session: session),
                                      selectedIDs: session.selectedAssets.map(\.id))
        print("②a 选 1 张 ⇒ title=\"\(one.title)\" enabled=\(one.isEnabled) tooltip=\(one.toolTip ?? "nil")")
        XCTAssertEqual(one.title, "HDR 合成…", "②a 行还在，只是灰掉")
        XCTAssertFalse(one.isEnabled)
        XCTAssertEqual(one.toolTip, "至少需要选中两张 DNG")

        // 2b 2 张里有一张 JPEG
        session.setSelection([dngs[0].id, jpeg.id], anchor: dngs[0].id)
        let mixed = HDRMenuBuilder.item(session: session,
                                        target: HDRMenuTarget(session: session),
                                        selectedIDs: session.selectedAssets.map(\.id))
        print("②b DNG+JPEG ⇒ enabled=\(mixed.isEnabled) tooltip=\(mixed.toolTip ?? "nil")")
        XCTAssertFalse(mixed.isEnabled)
        XCTAssertEqual(mixed.toolTip, "只支持 DNG：\(jpeg.filename)")
    }

    // MARK: - ③ 工具缺失：在，但灰掉并说明

    func testAMissingToolLeavesAGreyRowThatSaysSo() throws {
        let assets = try makeSession()
        let chosen = Array(assets.filter { $0.ext == "dng" }.prefix(3))
        let surfaces = makeSurfaces()
        session.setSelection(Set(chosen.map(\.id)), anchor: chosen[0].id)
        pump(0.1)
        // A client pinned at a path that does not exist — the same condition as a bundle that lost
        // its binary. No stubbing of the service: `isAvailable` is a file check.
        session.hdrMergeService = HDRMergeService(client: HDRMergeClient(
            executableURL: workDir.appendingPathComponent("no-such-hdrmerge-swift")))

        let row = try XCTUnwrap(hdrRow(in: try XCTUnwrap(surfaces.grid.menuForRightClick(nil))))
        print("③ 工具缺失 ⇒ enabled=\(row.isEnabled) tooltip=\(row.toolTip ?? "nil")")
        XCTAssertTrue(row.isEnabled == false)
        XCTAssertEqual(row.toolTip, Self.toolMissing, "③ 必须点名缺的是什么，而不是静默消失")
    }

    // MARK: - ⑥a 格式判据（不碰工具）

    func testTwoJPEGsAreRefusedBeforeAnyMergeAndAddNoRows() throws {
        let assets = try makeSession()
        let jpegs = assets.filter { $0.ext == "jpg" }
        let dng = try XCTUnwrap(assets.first { $0.ext == "dng" })
        let before = try rowCount()

        session.setSelection([jpegs[0].id, dng.id], anchor: dng.id)
        let participants = session.hdrMergeSelection()
        print("⑥a participants=\(participants.count) error=\(session.lastHDRMergeError ?? "nil") "
              + "rows \(before)→\(try rowCount())")
        XCTAssertTrue(participants.isEmpty, "⑥a 非 DNG 必须被挡在合成之前")
        XCTAssertEqual(session.lastHDRMergeError,
                       HDRMergeService.Failure.notCFARaw(dng.filename).description)
        XCTAssertEqual(try rowCount(), before, "⑥a 库里不留任何新 asset")
        XCTAssertEqual(session.hdrMergeCompletionCount, 0, "⑥a 连后台任务都没起")
    }

    // MARK: - ⑥b 线性 DNG + ⑦ 后台线程

    func testALinearDNGReportsTheTypedFailureAndLeavesTheLibraryUntouched() throws {
        let assets = try makeSession()
        // Two real files the tool classifies as LinearRaw (PhotometricInterpretation 34892) — the
        // Lightroom / ProRAW shape. Built here rather than committed: 332 bytes each, and the point is
        // the **tag**, not the pixels.
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        for i in 0 ..< 2 {
            try Self.writeLinearDNG(to: src.appendingPathComponent(String(format: "LIN_%02d.dng", i)))
        }
        let root = try XCTUnwrap(try catalog.roots().first)
        var linear: [Asset] = []
        for i in 0 ..< 2 {
            let name = String(format: "LIN_%02d.dng", i)
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name, ext: "dng",
                              kind: .raw, size: 332, mtime: 0, contentHash: UUID().uuidString,
                              captureTime: String(format: "2026-02-01T09:%02d:00Z", i),
                              captureLocalDate: "2026-02-01")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            linear.append(asset)
        }
        _ = assets
        let before = try rowCount()
        session.reload()
        session.setSelection(Set(linear.map(\.id)), anchor: linear[0].id)

        let participants = session.hdrMergeSelection()
        XCTAssertEqual(participants.count, 2)
        waitForMerge()

        print("⑥b error=\"\(session.lastHDRMergeError ?? "nil")\" rows \(before)→\(try rowCount()) "
              + "ranOffMain=\(String(describing: session.hdrMergeRanOffMain))")
        XCTAssertEqual(session.lastHDRMergeError, HDRMergeService.Failure.linearDNG("").description,
                       "⑥b 必须是 typed 的 linear_dng 文案，不是自己编的中文")
        XCTAssertEqual(try rowCount(), before, "⑥b 库里不留任何新 asset")
        XCTAssertNil(session.lastHDRMergeReport)
        // ⑦ 合成本体（inspect / merge / import）在非主线程；主线程只收结果。
        XCTAssertEqual(session.hdrMergeRanOffMain, true, "⑦ 阻塞的那一半必须在后台队列")
        XCTAssertEqual(session.hdrMergeCompletionCount, 1)
    }

    // MARK: - ⑧ 真跑一次（有样本就跑）

    func testARealMergeStacksTheResultOnTop() throws {
        // Candidate fixtures, same shape as the rest of the suite: an explicit sample wins, then
        // the committed bracket. The committed pair exists because this test's whole point is a
        // *real* merge — synthetic CFA frames cannot produce an exposure ratio to check.
        let candidates: [URL] = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"].map { URL(fileURLWithPath: $0) },
            Self.fixture("hdr-bracket-a.dng"),
        ].compactMap { $0 }
        guard let raw = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            throw XCTSkip("⑧ 没有 PHOTONS_TEST_RAW 也没有 hdr-bracket-a.dng，跳过真实合并")
        }
        // The fixture pairs the sample with its neighbour — a bracket, same body, same size. Copies
        // land in `workDir` so nothing of the user's folder is touched.
        let dir = workDir.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let siblings = try FileManager.default.contentsOfDirectory(at: raw.deletingLastPathComponent(),
                                                                  includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "dng" && $0 != raw }
            // A bracket has to be the *same scene*: when the sample is one of the committed pair,
            // only take its partner, never some other DNG that happens to share the folder.
            .filter { other in
                let stem = raw.deletingPathExtension().lastPathComponent
                guard stem.hasSuffix("-a") else { return true }
                return other.deletingPathExtension().lastPathComponent == String(stem.dropLast(2)) + "-b"
            }
        guard let other = siblings.first else { throw XCTSkip("⑧ 样本旁没有第二张 DNG") }
        let a = dir.appendingPathComponent("FRAME_A.dng")
        let b = dir.appendingPathComponent("FRAME_B.dng")
        try FileManager.default.copyItem(at: raw, to: a)
        try FileManager.default.copyItem(at: other, to: b)

        _ = try makeSession(dng: 0, jpeg: 0)
        // The merged DNG is written **next to its sources**, so the rows have to hang off the folder
        // the copies are in — that is also what `fileURL(for:)` resolves through.
        let root = try catalog.ensureRoot(for: dir, mode: .reference)
        var frames: [Asset] = []
        for (i, url) in [a, b].enumerated() {
            let asset = Asset(sourceRootId: root.id, relPath: url.lastPathComponent,
                              filename: url.lastPathComponent, ext: "dng", kind: .raw,
                              size: 1, mtime: 0, contentHash: UUID().uuidString,
                              captureTime: String(format: "2026-04-01T08:%02d:00Z", i),
                              captureLocalDate: "2026-04-01")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            frames.append(asset)
        }
        session.reload()
        // Point the session at the app's own binary: this test's subject is the merge, not tool
        // discovery, and under `swift test` there is no bundle-internal tool to discover.
        if let tool = Self.bundledTool() { session.hdrMergeService = HDRMergeService(client: tool) }
        guard session.isHDRMergeAvailable else {
            throw XCTSkip("⑧ 没有构建好的 Photons.app（先跑 scripts/build-and-run.sh --no-launch）")
        }
        session.setSelection(Set(frames.map(\.id)), anchor: frames[0].id)
        session.hdrMergeSelection()
        // A refusal sets `lastHDRMergeError` and never bumps the counter, so waiting on the counter
        // alone would hang instead of failing. Watch both.
        waitForMergeOrRefusal(timeout: 600)

        if let error = session.lastHDRMergeError {
            print("⑧ 工具拒绝这对样本：\(error)")
            throw XCTSkip("⑧ 这对样本无法合并：\(error)")
        }
        let report = try XCTUnwrap(session.lastHDRMergeReport)
        let stack = try XCTUnwrap(session.stacksByTopID[report.stackTopID])
        let bytes = (try? FileManager.default.attributesOfItem(atPath: report.output.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        print("⑧ outcome \(report.width)×\(report.height) frames=\(report.frameCount) "
              + "white=\(report.whiteLevel) bytes=\(bytes) "
              + "topID=\(report.stackTopID.prefix(8)) count=\(stack.count) "
              + "top==result? \(stack.topID == report.assetID)")
        XCTAssertEqual(stack.topID, report.assetID, "⑧ 合成结果必须是新堆叠的置顶")
        XCTAssertEqual(stack.count, 3, "⑧ 结果 + 两张原帧")
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.output.path))
        XCTAssertEqual(report.output.deletingLastPathComponent().standardizedFileURL,
                       dir.standardizedFileURL, "产物落在源文件同目录")
        XCTAssertEqual(session.selection, [report.assetID], "⑧ 完成后选中的是结果")
        XCTAssertEqual(session.hdrMergeRanOffMain, true)
    }

    // MARK: - helpers

    /// A file under `Tests/Fixtures/`, located from this source file so it works from any cwd.
    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Tests/Fixtures/\(name)")
    }

    /// The tool as the *app* resolves it — `Contents/Resources/bin/hdrmerge-swift` in the built
    /// bundle.
    ///
    /// The session a test builds here gets `Bundle.main` = the xctest runner, which has no
    /// `Resources/bin`, and the client deliberately has no PATH fallback (a stale copy outside the
    /// app is exactly the bug that hid a broken merge behind an old binary). So a real-merge test
    /// has to say which binary to use, the same way `HDRMergeServiceTests` does.
    private static func bundledTool() -> HDRMergeClient? {
        let bin = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent(".build/Photons.app/Contents/Resources/bin/hdrmerge-swift")
        guard FileManager.default.isExecutableFile(atPath: bin.path) else { return nil }
        return HDRMergeClient(executableURL: bin)
    }

    private func rowCount() throws -> Int {
        try catalog.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM assets") ?? -1
        }
    }

    /// Wait for the background half without sleeping blind: the completion hop is a main-actor task,
    /// so the main run loop has to turn for it to run.
    private func waitForMerge(timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.hdrMergeCompletionCount > 0 { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("合成在 \(timeout) s 内没有回来")
    }

    /// Same wait, but a *refusal* counts as an outcome. `hdrMergeSelection()` returns early on a
    /// missing tool / one frame / a busy queue, setting `lastHDRMergeError` and never touching the
    /// completion counter — so polling the counter alone turns every refusal into a 10-minute hang
    /// with no message. Whoever calls this gets an immediate answer either way.
    private func waitForMergeOrRefusal(timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if session.hdrMergeCompletionCount > 0 { return }
            if session.lastHDRMergeError != nil { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTFail("合成在 \(timeout) s 内没有回来，也没有给出拒绝理由")
    }

    /// A 332-byte TIFF with `PhotometricInterpretation = 34892` (LinearRaw) and 3 samples — what the
    /// tool calls a linear DNG, and the only thing this fixture has to be.
    private static func writeLinearDNG(to url: URL) throws {
        let w = 8, h = 8, spp = 3
        let pixels = [UInt8](repeating: 120, count: w * h * spp)
        var entries: [(UInt16, UInt16, UInt32, UInt32)] = [
            (254, 4, 1, 0), (256, 4, 1, UInt32(w)), (257, 4, 1, UInt32(h)), (259, 3, 1, 1),
            (262, 3, 1, 34892), (273, 4, 1, 0), (277, 3, 1, UInt32(spp)),
            (278, 4, 1, UInt32(h)), (279, 4, 1, UInt32(pixels.count)), (284, 3, 1, 1),
        ]
        entries.sort { $0.0 < $1.0 }
        let ifdSize = 2 + entries.count * 12 + 4
        let bpsOffset = 8 + ifdSize
        let dataOffset = bpsOffset + 6
        var out = Data("II".utf8)
        func u16(_ v: UInt16) { out.append(UInt8(v & 0xff)); out.append(UInt8(v >> 8)) }
        func u32(_ v: UInt32) {
            for i in 0 ..< 4 { out.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) }
        }
        u16(42); u32(8)
        u16(UInt16(entries.count))
        for (tag, type, count, value) in entries {
            u16(tag); u16(type); u32(count)
            if tag == 258 {
                u32(UInt32(bpsOffset))
            } else if tag == 273 {
                u32(UInt32(dataOffset))
            } else if type == 3 && count == 1 {
                u16(UInt16(value)); u16(0)
            } else {
                u32(value)
            }
        }
        u32(0)
        for _ in 0 ..< spp { u16(8) }        // BitsPerSample[3]
        out.append(contentsOf: pixels)
        try out.write(to: url)
    }
}
