import XCTest
import AppKit
import GRDB
import PhotonsCatalog
import PhotonsCore
import PhotonsExtensions
@testable import PhotonsUI

/// 454 P2a —— 降噪 / HDR 把进度写进 `BackgroundTaskStore`（**只写不读**）。
///
/// 本 suite 证明三件事：
///   1. 一次真实入口跑下来，store 里**只多一条**任务，kind/total 对，收尾 state 对；
///   2. 失败与提前拒绝都不会留下一条永远 `running` 的记录；
///   3. 两个 HUD 仍读原来的 `last…Progress`（P2b 才换绘制路径）。
///
/// 不跑 90 s 推理 / 真 HDR：降噪走 `nlmfDenoiseBody` 替身，HDR 走一个假的 `hdrmerge-swift`。
/// 两个都是既有接缝，本单没有为测试新增生产 API。
@MainActor
final class BackgroundTaskWiring454Tests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photons-tasks454-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - fixtures

    private final class MemoryStore: FilterPersistence.Store, PhotoSortPreferences.Store {
        var filters: [String: String] = [:]
        var sort: [String: String] = [:]
        func storedFilterJSON(forKey key: String) -> String? { filters[key] }
        func storeFilterJSON(_ json: String, forKey key: String) { filters[key] = json }
        func removeFilterJSON(forKey key: String) { filters[key] = nil }
        func sortOrderRaw(forKey key: String) -> String? { sort[key] }
        func storeSortOrderRaw(_ raw: String?, forKey key: String) { sort[key] = raw }
    }

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Tests/Fixtures/small-rggb.dng")
    }

    private struct Fixture {
        let session: CatalogSession
        let catalog: Catalog
        let src: URL
        let assets: [Asset]
    }

    @discardableResult
    private func makeSession(dngCount: Int = 1) throws -> Fixture {
        let libraryURL = workDir.appendingPathComponent("S454.\(LibraryLayout.packageExtension)",
                                                        isDirectory: true)
        let catalog = try Catalog.create(at: libraryURL)
        let src = workDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let root = try catalog.ensureRoot(for: src, mode: .reference)

        var assets: [Asset] = []
        for i in 0..<dngCount {
            let name = String(format: "IMG_%04d.dng", i)
            try FileManager.default.copyItem(at: Self.fixtureURL,
                                             to: src.appendingPathComponent(name))
            let asset = Asset(sourceRootId: root.id, relPath: name, filename: name,
                              ext: "dng", kind: .raw, size: 1, mtime: 0,
                              contentHash: UUID().uuidString, width: 1024, height: 1024,
                              captureTime: String(format: "2026-05-01T10:%02d:00Z", i),
                              captureLocalDate: "2026-05-01",
                              cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
            try catalog.dbQueue.write { db in try asset.insert(db) }
            assets.append(asset)
        }

        let store = MemoryStore()
        let session = CatalogSession(filterStore: store, sortPreferenceStore: store,
                                     remembersRecentLibrary: false)
        try session.open(libraryURL)
        session.setSortOrder(.newestFirst)
        return Fixture(session: session, catalog: catalog, src: src, assets: assets)
    }

    /// NLMF 那条路只需要模型路径存在；推理本身由 `nlmfDenoiseBody` 替身回答。
    private func installNLMFModel(on session: CatalogSession) throws {
        let model = workDir.appendingPathComponent("v_matmul_256.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        session.nlmfModelURL = model
    }

    /// 一个假的 `hdrmerge-swift`：`inspect` 说三帧同尺寸同 CFA，`merge` 把第一帧抄到 `-o` 并
    /// 按协议输出 JSON / progress。这样合成走的是生产 `HDRMergeService` + 入库 + 堆叠，只是
    /// 不花 15 s 真合并。
    private func installFakeHDRTool() throws -> URL {
        let tool = workDir.appendingPathComponent("fake-hdrmerge-swift")
        let script = """
        #!/bin/sh
        cmd="${1:-}"
        if [ "$cmd" = "inspect" ]; then
          shift 2
          printf '{"ok":true,"frames":['
          first=1
          for f in "$@"; do
            if [ $first -eq 0 ]; then printf ','; fi
            first=0
            printf '{"path":"%s","make":"LEICA","model":"SL3","width":1024,"height":1024,"cfaPattern":[0,1,1,2],"blackLevel":[0,0,0,0],"whiteLevel":16383,"exposureTime":0.001,"iso":100}' "$f"
          done
          printf ']}\\n'
          exit 0
        fi
        if [ "$cmd" = "merge" ]; then
          shift
          out=""
          first_input=""
          while [ $# -gt 0 ]; do
            case "$1" in
              --json|--progress|--compress) shift ;;
              -o) out="$2"; shift 2 ;;
              -b|--headroom|--feather|--white|--metadata-from) shift 2 ;;
              --) shift; if [ $# -gt 0 ]; then first_input="$1"; fi; break ;;
              *) shift ;;
            esac
          done
          if [ -z "$out" ] || [ -z "$first_input" ]; then exit 3; fi
          cp "$first_input" "$out" || exit 4
          echo '{"event":"progress","phase":"decode","index":1,"total":3,"file":"frame-1"}' >&2
          echo '{"event":"progress","phase":"decode","index":2,"total":3,"file":"frame-2"}' >&2
          echo '{"event":"progress","phase":"decode","index":3,"total":3,"file":"frame-3"}' >&2
          echo '{"event":"progress","phase":"merge","frames":3}' >&2
          echo '{"event":"progress","phase":"encode","bits":16}' >&2
          printf '{"ok":true,"output":"%s","width":1024,"height":1024,"frames":3,"bits":16,"headroom":4,"whiteLevel":65535,"blackLevel":0,"cfaPattern":[0,1,1,2],"metadataFrom":"%s"}\\n' "$out" "$first_input"
          exit 0
        fi
        exit 5
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }

    @discardableResult
    private func waitUntil(_ what: String, timeout: TimeInterval = 60,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            pump(0.01)
        }
        XCTFail("\(what)：\(timeout) s 内没有成立")
        return false
    }

    private func onlyTask(in session: CatalogSession) throws -> BackgroundTask {
        XCTAssertEqual(session.backgroundTasks.tasks.count, 1, "一次入口只能产生一条任务")
        return try XCTUnwrap(session.backgroundTasks.tasks.first)
    }

    // MARK: - 1 · 降噪成功产生一条任务

    func testDenoiseWritesOneFinishedTask() throws {
        let fixture = try makeSession(dngCount: 1)
        let session = fixture.session
        let asset = try XCTUnwrap(fixture.assets.first)
        try installNLMFModel(on: session)
        session.nlmfDenoiseBody = { source, output, _ in
            try FileManager.default.copyItem(at: source, to: output)
            return NLMFDenoiseExecutor.Report(width: 1024, height: 1024, cfa: "rggb",
                                              tiles: 1, seconds: 0.01, byteCount: 1)
        }
        session.selectOnly(asset.id)

        let participants = session.denoiseSelectionNlmf()
        XCTAssertEqual(participants, [asset.id])
        waitUntil("降噪没有结束") { session.denoiseCompletionCount > 0 }

        let task = try onlyTask(in: session)
        print("① 降噪任务 title=\(task.title) state=\(task.state.rawValue) "
              + "\(task.completed)/\(task.total) error=\(session.lastDenoiseError ?? "nil")")
        XCTAssertEqual(task.kind, .denoise)
        XCTAssertEqual(task.title, "降噪 · IMG_0000.dng")
        XCTAssertEqual(task.total, 1)
        XCTAssertEqual(task.state, .finished)
        XCTAssertEqual(task.completed, 1)
        XCTAssertEqual(task.failureCount, 0)
        XCTAssertNil(session.lastDenoiseError)
        // HUD 仍读这两个字段（P2a 只写 store，不换绘制路径）。
        XCTAssertFalse(session.lastDenoiseProgress?.isEmpty ?? true,
                       "既有进度字符串必须仍由同一条回调更新")
        XCTAssertEqual(session.denoiseAssetID, nil)
    }

    // MARK: - 2 · 失败也落 state，不留 running

    func testDenoiseFailureClosesTheTaskAsFailed() throws {
        struct FakeFailure: Error {}
        let fixture = try makeSession(dngCount: 1)
        let session = fixture.session
        let asset = try XCTUnwrap(fixture.assets.first)
        try installNLMFModel(on: session)
        session.nlmfDenoiseBody = { _, _, _ in throw FakeFailure() }
        session.selectOnly(asset.id)

        session.denoiseSelectionNlmf()
        waitUntil("失败路径没有结束") { session.denoiseCompletionCount > 0 }

        let task = try onlyTask(in: session)
        print("② 失败任务 state=\(task.state.rawValue) failureCount=\(task.failureCount) "
              + "error=\(session.lastDenoiseError ?? "nil")")
        XCTAssertEqual(task.kind, .denoise)
        XCTAssertEqual(task.total, 1)
        XCTAssertEqual(task.state, .failed)
        XCTAssertGreaterThanOrEqual(task.failureCount, 1)
        XCTAssertFalse(task.state == .running, "任务不许永远停在 running")
        XCTAssertFalse(session.isDenoiseRunning)
        XCTAssertNotNil(session.lastDenoiseError)
    }

    // MARK: - 3 · 每条提前 return 都不新建任务

    /// 口径：**拒绝启动不建任务**。那些 `guard … return []` 是参数/依赖校验失败，工作根本没开始，
    /// 一句 `lastDenoiseError` 已经是最贴切的载体；为一次没发生的降噪建一条 `.failed` 记录反而会
    /// 让面板里出现「点了但什么都没跑」的噪声。真正的失败（runner 抛错）才建任务并落 `.failed`
    /// —— 那由 ② 与 ④b 覆盖。
    func testRefusedStartsCreateNoTask() throws {
        // 1) 没有库
        let store = MemoryStore()
        let bare = CatalogSession(filterStore: store, sortPreferenceStore: store,
                                  remembersRecentLibrary: false)
        XCTAssertEqual(bare.denoiseSelectionNlmf(), [])
        XCTAssertEqual(bare.lastDenoiseError, DenoiseNotices.noLibrary)
        XCTAssertTrue(bare.backgroundTasks.tasks.isEmpty, "noLibrary 不许新建任务")

        // 2) 有库但没有选中照片
        let fixture = try makeSession(dngCount: 1)
        let session = fixture.session
        try installNLMFModel(on: session)
        // 保险：本 case 只验证拒绝启动，绝不让任何意外的真推理跑起来。
        struct NoRun: Error {}
        session.nlmfDenoiseBody = { _, _, _ in throw NoRun() }
        session.setSelection([], anchor: nil)
        XCTAssertEqual(session.denoiseSelectionNlmf(), [])
        XCTAssertEqual(session.lastDenoiseError, DenoiseNotices.singlePhotoOnly)
        XCTAssertTrue(session.backgroundTasks.tasks.isEmpty, "空选择不许新建任务")

        // 3) 选中的不是 DNG
        let root = try XCTUnwrap(fixture.catalog.roots().first)
        let jpeg = Asset(sourceRootId: root.id, relPath: "IMG_0001.jpg", filename: "IMG_0001.jpg",
                         ext: "jpg", kind: .jpeg, size: 1, mtime: 0,
                         contentHash: UUID().uuidString, width: 1024, height: 1024,
                         captureTime: "2026-05-01T10:05:00Z", captureLocalDate: "2026-05-01",
                         cameraModel: "LEICA SL3", cameraKey: "leica|sl3")
        try fixture.catalog.dbQueue.write { db in try jpeg.insert(db) }
        session.reload()
        session.setSelection([jpeg.id], anchor: jpeg.id)
        XCTAssertEqual(session.denoiseSelectionNlmf(), [])
        XCTAssertEqual(session.lastDenoiseError, DenoiseNotices.onlyDNG(jpeg.filename))
        XCTAssertTrue(session.backgroundTasks.tasks.isEmpty, "onlyDNG 不许新建任务")
    }

    // MARK: - 4a · HDR 成功：total = 参与者数

    func testHDRMergeWritesOneFinishedTask() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        let tool = try installFakeHDRTool()
        session.hdrMergeService = HDRMergeService(
            client: HDRMergeClient(executableURL: tool))
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)

        let participants = session.hdrMergeSelection()
        XCTAssertEqual(participants.count, 3)
        waitUntil("HDR 合成没有结束") { session.hdrMergeCompletionCount > 0 }

        let task = try onlyTask(in: session)
        print("④ HDR 任务 title=\(task.title) state=\(task.state.rawValue) "
              + "\(task.completed)/\(task.total) error=\(session.lastHDRMergeError ?? "nil")")
        XCTAssertEqual(task.kind, .hdrMerge)
        XCTAssertEqual(task.total, participants.count)
        XCTAssertEqual(task.state, .finished)
        XCTAssertEqual(task.completed, participants.count)
        XCTAssertEqual(task.failureCount, 0)
        XCTAssertNil(session.lastHDRMergeError)
        XCTAssertTrue(session.lastHDRMergeProgress?.contains("合成完成") ?? false,
                      "既有进度字符串必须仍由同一条回调更新")
        XCTAssertNil(session.hdrMergingParticipantIDs)
    }

    // MARK: - 4b · HDR 失败同样落 .failed

    func testHDRMergeFailureClosesTheTaskAsFailed() throws {
        let fixture = try makeSession(dngCount: 3)
        let session = fixture.session
        // `/bin/echo` 存在但输出不是 JSON：预检就失败，正是失败出口。
        session.hdrMergeService = HDRMergeService(
            client: HDRMergeClient(executableURL: URL(fileURLWithPath: "/bin/echo")))
        session.setSelection(Set(fixture.assets.map(\.id)), anchor: fixture.assets[0].id)

        let participants = session.hdrMergeSelection()
        XCTAssertEqual(participants.count, 3)
        waitUntil("HDR 失败路径没有结束") { session.hdrMergeCompletionCount > 0 }

        let task = try onlyTask(in: session)
        print("④b HDR 失败 state=\(task.state.rawValue) failureCount=\(task.failureCount) "
              + "error=\(session.lastHDRMergeError ?? "nil")")
        XCTAssertEqual(task.kind, .hdrMerge)
        XCTAssertEqual(task.total, 3)
        XCTAssertEqual(task.state, .failed)
        XCTAssertGreaterThanOrEqual(task.failureCount, 1)
        XCTAssertFalse(task.state == .running, "任务不许永远停在 running")
        XCTAssertFalse(session.isHDRMergeRunning)
        XCTAssertNotNil(session.lastHDRMergeError)
    }
}
