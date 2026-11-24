import PhotonsLocalization
import Foundation
import Observation
import PhotonsCatalog
import PhotonsCore
import PhotonsExport
// §384: the HDR verb. `PhotonsExtensions` owns `HDRMergeService`, which spawns the GPLv3
// `hdrmerge-swift` binary as a child process — nothing of it is linked into this app.
import PhotonsExtensions

/// 451 — the quit hook. `PhotonsApp` does not link `PhotonsExtensions` directly, so this is the
/// one-line door its `applicationWillTerminate` calls to terminate any running denoise/HDR child.
public enum ChildProcessTermination {
    public static func terminateAll() {
        ChildProcessRegistry.shared.terminateAll()
    }
}

// MARK: - §432 两条降噪路（产物/堆叠共用一条路径）

/// 463 — the words that belong to the "file is gone" state but are not the existing
/// 「原文件已移动」 badge (that one is owned by `MissingFilesUI`). Kept here because the session is
/// the only model type all three browsers and the loupe banner already share.
public enum MissingMarkText {
    /// The loupe banner's one-line verdict.
    public static let fileGone = Loc.t("文件不在原位置")
    /// A stack's representative when a **hidden member** is the missing one.
    public static let stackHasMissing = Loc.t("这一叠里有文件不在了")
    /// The banner's removal verb. It performs the same `removeAndDelete` the context menu does.
    public static let removeFromLibrary = Loc.t("从库中移除…")
}

/// 哪一条模型降噪。
///
/// 两条路的**唯一**架构差别是许可边界：`ansel` 的权重是 GPL-3.0，必须走子进程；
/// `nonlocal` 的代码与权重都是 MIT，所以是进程内的一次普通调用。产品行为（命名、落盘、
/// 入库、继承编辑、堆叠、选中）完全相同，因此两者共用 `CatalogSession.denoiseSelection(engine:)`。
public enum DenoiseEngine: String, Sendable, CaseIterable {
    case ansel
    case nonlocal

    /// 菜单项里那个括号里的词，也用于日志。刻意不翻译：它是产品的专名。
    public var displayName: String {
        switch self {
        case .ansel: return "Ansel"
        case .nonlocal: return "Nonlocal"
        }
    }
}

/// 两条 notice 的**共同部分**与**各自部分**。
///
/// 「缺 ansel 工具」与「缺 NLMF 模型」必须是两句不同的话：前者是子进程那条路的问题，
/// 后者是进程内那条路的问题，用户要改的东西不一样。共用一句会让「两条入口互相独立」
/// 在文案层就失真。
public enum DenoiseNotices {
    public static let noLibrary = Loc.t("未打开库")
    public static let singlePhotoOnly = Loc.t("模型降噪只处理单张照片")
    public static let alreadyRunning = Loc.t("已有一次模型降噪在进行")
    public static let batchNeedsTwo = Loc.t("批量降噪至少需要两张可处理的 DNG")

    /// 510 — 「这张照片自己」在忙的两句。与上面的 `alreadyRunning` 是**两件事**：那句说的是
    /// 「全局有活在跑」，这两句说的只是「这张」—— 别的照片在跑时它们不出现。
    public static let runningThisPhoto = Loc.t("正在降噪")
    public static let alreadyQueued = Loc.t("已在队列中")

    /// 510 — 入队成功的那句。「前面还有 N 个」数的是**还会先跑完的请求**（正在跑的算 1 个）。
    public static func queued(_ ahead: Int) -> String {
        Loc.t("已加入降噪队列（前面还有 {0} 个）", String(describing: (ahead)))
    }

    /// 510 — 批量里有一部分已经在跑/已排队，所以只对剩下的那些开单。
    public static func batchQueueSkipped(_ skipped: Int, kept: Int) -> String {
        Loc.t("将跳过 {0} 张已在队列中的照片，只对 {1} 张运行降噪。",
              String(describing: (skipped)), String(describing: (kept)))
    }

    /// 510 — `clearDenoiseQueue()` 之后面板/日志里那一句。
    public static func clearedQueue(_ count: Int) -> String {
        Loc.t("已清空降噪队列（{0} 个）", String(describing: (count)))
    }

    public static func onlyDNG(_ filename: String) -> String {
        Loc.t("只支持 DNG：{0}", String(describing: (filename)))
    }
    public static func batchSkipped(_ skipped: Int, kept: Int) -> String {
        Loc.t("已跳过 {0} 张不支持降噪的照片，只对 {1} 张运行降噪。",
              String(describing: (skipped)), String(describing: (kept)))
    }

    // Ansel（子进程，GPL 权重）—— 与 §386 时一模一样的三句，只是搬到这里按引擎分组。
    public static let anselToolMissing = AnselDenoiseNotices.toolMissing
    public static func anselModelMissing(_ expectedPath: String) -> String {
        AnselDenoiseNotices.modelMissing(expectedPath)
    }

    // Nonlocal（进程内，MIT 权重）—— **只需要模型**，而且期望位置与 Ansel 不同
    // （随包在 target bundle 的 `Resources/Models`），所以文案必须自己一句。
    public static func nlmfModelMissing(_ searchedPaths: String) -> String {
        Loc.t("未找到 nonlocal 降噪模型：{0}", String(describing: (searchedPaths)))
    }
}

/// 一次降噪的原始产物 —— 两个 job 的共同形状，之后的一切（命名/入库/堆叠）都只看它。
struct DenoiseOutcome: Sendable {
    let output: URL
    let width: Int
    let height: Int
    let cfa: String
    let tiles: Int
    let seconds: Double
    let byteCount: Int
}

/// 「调用哪一次 denoise」的那一层。存在的理由：让 `CatalogSession` 的产物/堆叠路径**只有一份**，
/// 同时给测试一个不跑 90 s Core ML 推理的注入点。
protocol DenoiseExecuting: Sendable {
    func denoise(source: URL, progress: @escaping @Sendable (String) -> Void) throws -> DenoiseOutcome
}

struct AnselDenoiseExecutor: DenoiseExecuting {
    let job: AnselDenoiseJob

    func denoise(source: URL, progress: @escaping @Sendable (String) -> Void) throws -> DenoiseOutcome {
        let outcome = try job.run(source: source, progress: progress)
        return DenoiseOutcome(output: outcome.output, width: outcome.width, height: outcome.height,
                              cfa: outcome.cfa, tiles: outcome.tiles, seconds: outcome.seconds,
                              byteCount: outcome.byteCount)
    }
}

/// 进程内那条路。产物命名与落盘规矩**复用 Ansel 的**（`AnselDenoiseJob.outputURL`：
/// `<原名>-denoised.dng` / 重名递增；先写临时名再改名，失败不留半个文件），
/// 因为用户契约是「两个入口产物一样」，不是「两条各自实现一遍」。
///
/// `body` 是那条唯一的接缝：默认就是真跑 Core ML（~90 s，因此测试不能走它），
/// 测试传一个「照抄输入、返回数字」的替身时，**命名、临时名、改名**仍然是这里这份生产代码。
struct NLMFDenoiseExecutor: DenoiseExecuting {

    /// 一次推理能给出的那六个数。与 `NLMFDenoiseReport` 同形，但不把库的类型带进 PhotonsUI。
    struct Report: Sendable {
        var width: Int
        var height: Int
        var cfa: String
        var tiles: Int
        var seconds: Double
        var byteCount: Int
    }

    typealias Body = @Sendable (URL, URL, @escaping @Sendable (String) -> Void) throws -> Report

    let job: NLMFDenoiseJob
    var body: Body?

    init(job: NLMFDenoiseJob, body: Body? = nil) {
        self.job = job
        self.body = body
    }

    func denoise(source: URL, progress: @escaping @Sendable (String) -> Void) throws -> DenoiseOutcome {
        let fm = FileManager.default
        let finalURL = AnselDenoiseJob.outputURL(for: source, fileManager: fm)
        let temp = finalURL.deletingLastPathComponent()
            .appendingPathComponent(".nlmf-\(UUID().uuidString).dng")
        defer { try? fm.removeItem(at: temp) }

        let report: Report
        if let body {
            report = try body(source, temp, progress)
        } else {
            let real = try job.denoise(input: source, output: temp, progress: progress)
            report = Report(width: real.width, height: real.height, cfa: real.cfa,
                            tiles: real.tiles, seconds: real.seconds,
                            byteCount: real.outputBytes)
        }
        do {
            try? fm.removeItem(at: finalURL)
            try fm.moveItem(at: temp, to: finalURL)
        } catch {
            throw AnselDenoiseJobError.move("\(error)")
        }
        return DenoiseOutcome(output: finalURL, width: report.width, height: report.height,
                              cfa: report.cfa, tiles: report.tiles, seconds: report.seconds,
                              byteCount: report.byteCount)
    }
}

/// 一次运行要用的那个 job，按引擎选。
struct DenoiseRunner: Sendable {
    var engine: DenoiseEngine
    var ansel: AnselDenoiseJob
    var nonlocal: NLMFDenoiseJob
    /// 只给测试：替换进程内那条路的**推理**，命名与临时名/改名仍是生产代码。
    var nonlocalBody: NLMFDenoiseExecutor.Body?
    /// 只给测试（512）：替换「继承库属性」那一步，默认走 `catalog.copyLibraryMetadata`。
    var metadataInheritBody: (@Sendable (Catalog, _ from: String, _ to: String) throws -> Int)?

    func execute(source: URL,
                 progress: @escaping @Sendable (String) -> Void) throws -> DenoiseOutcome {
        switch engine {
        case .ansel:
            return try AnselDenoiseExecutor(job: ansel).denoise(source: source, progress: progress)
        case .nonlocal:
            return try NLMFDenoiseExecutor(job: nonlocal, body: nonlocalBody)
                .denoise(source: source, progress: progress)
        }
    }
}

/// 477 — read-only counters for `--ui-smoke` and the tests. Counts, never file paths.
public struct DNGWriteStats: Equatable, Sendable {
    /// DNG `DNGXMP.writeDocument` calls that actually changed the file.
    public var xmpWrites = 0
    /// Of those, how many reused tag 700's existing slot (`appendedBytes == 0`).
    public var reusedSlots = 0
    public var appendedBytes = 0
    /// Non-DNG saves that wrote/updated `‹original›.xmp`.
    public var sidecarWrites = 0
    public var thumbnailWrites = 0
    public var failures = 0
    /// Non-DNG sources skipped by a thumbnail-only door.
    public var skipped = 0
    /// Rows filled from a DNG's XMP because the library had no document.
    public var backfills = 0
    /// 文件 ▸ 从 DNG 读取编辑 successes.
    public var readsFromDNG = 0
    /// 撤销 DNG 里的上次写入 successes.
    public var undos = 0

    public init() {}
}

/// 477 — the one thing a write did, before it is folded into `DNGWriteStats` on the main actor.
public struct DNGWriteResult: Equatable, Sendable {
    public var wroteXMP = false
    public var reusedSlot = false
    public var appendedBytes = 0
    public var wroteSidecar = false
    public var wroteThumbnail = false
    public var thumbnailInPlace = false
    public var thumbnailBytes = 0
    public var thumbnailSize: ImageSize?
    public var failed = false
    public var skipped = false
    public var error: String?

    public init() {}
}

/// 477 — 载入回填的审计行写进 `local/`（gitignored），不进 UI。注入目录是为了测试不碰仓库。
public struct DNGXPMAuditLog: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static var standard: DNGXPMAuditLog {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return DNGXPMAuditLog(directory: cwd.appendingPathComponent("local", isDirectory: true))
    }

    public func append(source: String, assetID: String, path: String) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let entry: [String: String] = [
            "source": source,
            "asset_id": assetID,
            "path": path,
            "at": ISO8601.now(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        let target = directory.appendingPathComponent("dng-xmp-audit.log")
        if let handle = try? FileHandle(forWritingTo: target) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: target)
        }
    }
}

/// The one and only source of truth for the workspace.
///
/// Research `ui-stack.md` F5: the projects that mixed AppKit + SwiftUI did **not** keep two state
/// managers — they kept one `@Observable` model, one 15-line observation bridge for the AppKit side,
/// and `@Bindable` for the SwiftUI leaf views. That is the rule here: every view (grid, filmstrip,
/// sources, loupe, inspector) reads and writes this object, and nothing keeps a copy.
///
/// The document is *persisted* (Q16): `develop(forAsset:)` on open, `saveDevelop(_:history:forAsset:)`
/// after every commit, so closing the app no longer throws an edit away. What is deliberately **not**
/// persisted and **not** in history is mask view state (`selectedMaskID`, the brush, `showMaskID`) —
/// see `MaskViewState`.
@MainActor
@Observable
public final class CatalogSession {

    public enum Mode: String, Sendable {
        case grid
        case loupe
    }

    /// 454 P2a — the one task store, owned by the model rather than a view.
    ///
    /// The producers (denoise / HDR now, export in P3) all live on `CatalogSession`, so a
    /// view-private store could never be written by them. The workspace only reads this instance;
    /// the HUDs still read their own `last…Progress` fields (P2b is the phase that changes them).
    public let backgroundTasks = BackgroundTaskStore()

    // MARK: library

    public private(set) var libraryURL: URL?
    public private(set) var roots: [SourceRoot] = []
    public private(set) var assets: [Asset] = []
    /// The stacks the visible rows represent, keyed by their 置顶 asset id (§378).
    ///
    /// `assets` is the **projection**: one row per stack (its 置顶), plus every photo that is in no
    /// stack. This dictionary is the other half of that fact — a row's full membership, which is
    /// what the 「⧉ N」 badge counts and what 设为置顶 lists. A photo in no stack leaves no entry,
    /// so `stacksByTopID[asset.id] == nil` is the whole test for "draw no indicator".
    ///
    /// Rebuilt in `reload()` from the same query pass, never patched in place: the projection and
    /// this table can then never disagree about which row is a top, and nobody has to remember to
    /// update two things after a stack write.
    public private(set) var stacksByTopID: [String: StackSummary] = [:]
    /// 463 — stack tops whose **hidden** members include a missing file. The grid/filmstrip/list only
    /// draw the top, so a member's own badge would never be seen; this is the second half of
    /// `isMarkedMissing(assetID:)`. Rebuilt with `stacksByTopID` in `reload()` and kept in step by
    /// the single-row re-stat path.
    public private(set) var stackTopIDsWithMissingMembers: Set<String> = []
    public private(set) var stats: CatalogStats?
    public private(set) var loadError: String?

    /// Content-addressed thumbnail files for this library (`~/Library/Caches/Photons/<hash>/thumbs`).
    /// Owned by the session so every view shares one instance (and one set of cache counters).
    public private(set) var thumbnailCache: ThumbnailCache?

    // MARK: selection

    /// Multi-selection by asset id (⌘/⇧ in the grid, mirrored by the filmstrip).
    public private(set) var selection: Set<String> = []
    /// The "active" photo: the one the loupe shows and the inspector edits.
    public private(set) var anchorID: String?
    /// The ⇧ range base: the photo a range starts from.
    ///
    /// Deliberately separate from `anchorID`: the anchor is the thick blue ring / the photo the
    /// loupe shows, and it must stay put for the whole ⇧ gesture, while the base is what the next
    /// ⇧ click measures from. The first ⇧ click establishes it; further ⇧ clicks/arrows keep it.
    public private(set) var selectionBase: String?
    /// The far end of the current ⇧ range (the cursor ⇧+arrows advance). Not part of the
    /// selection itself; any non-⇧ selection change resets it to the clicked photo.
    private var rangeFocus: String?

    /// Set by `deleteAssets` just before the rows go away: the photo the anchor should hand over to
    /// when it is the anchor that got deleted. `reload()` consumes it exactly once, so a later
    /// reload for an unrelated reason (filter, folder, relink) keeps its original "fall back to the
    /// first row" behaviour.
    private var pendingAnchorSuccessor: String?

    // MARK: document

    /// The live document for the anchor photo. **Read-only from outside**: a slider goes through
    /// `applyEdit`, which is what bumps `editRevision` — the one signal the render loop listens to.
    /// A second writer that assign to `edit` directly would move pixels without invalidating them.
    public private(set) var edit: EditModel = .neutral

    /// Monotonic counter of document changes. The loupe observes *this* instead of diffing
    /// `EditModel` (a struct comparison on every observation pass, for no extra information).
    public private(set) var editRevision = 0

    /// 303 — callbacks for "a document edit moved the pixels of this asset". The loupe already watches
    /// `editRevision`; the three browsers need the **asset id** so they can refresh the one visible
    /// thumbnail instead of invalidating the library. Keys are removal tokens; the closures are
    /// expected to capture their owner weakly (see `WorkspaceRootView`).
    @ObservationIgnored
    private var editObservers: [UUID: (String) -> Void] = [:]

    /// 303 — observe document edits. The returned token removes the observer again. Not called for
    /// `publishViewState` (the mask overlay is view state, not a pixel change).
    @discardableResult
    public func addEditObserver(_ observer: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        editObservers[token] = observer
        return token
    }

    /// Remove an observer registered by `addEditObserver`.
    public func removeEditObserver(_ token: UUID) {
        editObservers.removeValue(forKey: token)
    }

    private func notifyEditObservers(assetID: String?) {
        guard let assetID else { return }
        for observer in editObservers.values { observer(assetID) }
    }

    /// The asset a live document edit belongs to: the loaded photo, or the anchor when no document is
    /// loaded (tests and a session with no library). `nil` = nothing to refresh.
    private var editedAssetID: String? { loadedEditAssetID ?? anchorAsset?.id }

    /// When the last document change landed. Slider→frame latency is measured from here, so the
    /// reported number includes the 50 ms debounce window rather than hiding it.
    public private(set) var lastEditChangedAt: CFAbsoluteTime = 0

    // MARK: 530 — the document-load timeline
    //
    // The user's report is 「编辑数值有时要等照片加载完再加载」. Three candidates were named before
    // any change (main-thread DB read, selection deferred behind the decode, or the view not being
    // told). These fields are the measurement, in the same read-only style as `lastEditChangedAt`:
    // they are written by the selection/document path and read by the tests. Nothing branches on
    // them.

    /// One photo switch, from the selection write to the first frame that photo presented.
    public struct EditLoadTimeline: Sendable, Equatable {
        public var assetID: String
        /// The click/selection entry (before the selection fields are written).
        public var selectionAt: CFAbsoluteTime
        /// The two catalog reads, each bracketed; equal when a read was skipped.
        public var developBeganAt: CFAbsoluteTime
        public var developEndedAt: CFAbsoluteTime
        public var historyBeganAt: CFAbsoluteTime
        public var historyEndedAt: CFAbsoluteTime
        /// After `edit` / `loadedEditAssetID` / `history` are in place.
        public var assignedAt: CFAbsoluteTime
        /// The first frame the loupe published for this asset, `nil` until it lands.
        public var firstFrameAt: CFAbsoluteTime?

        public var selectionToAssignedMilliseconds: Double {
            (assignedAt - selectionAt) * 1000
        }
        public var developMilliseconds: Double {
            (developEndedAt - developBeganAt) * 1000
        }
        /// The background history read, or 0 while it is still running.
        public var historyMilliseconds: Double {
            guard historyEndedAt > 0 else { return 0 }
            return (historyEndedAt - historyBeganAt) * 1000
        }
        public var assignedToFirstFrameMilliseconds: Double? {
            firstFrameAt.map { ($0 - assignedAt) * 1000 }
        }
    }

    /// The last switch measured by `loadEditForAnchor`.
    public private(set) var lastEditLoadTimeline: EditLoadTimeline?
    /// Wall-clock cost of the last background history read (0 until it lands).
    public private(set) var lastEditHistoryLoadMilliseconds: Double = 0
    /// Number of switches measured — a cheap "the seam ran" fact for tests.
    public private(set) var editLoadCount = 0
    /// When the loupe last published a new photo's frame, and for which asset.
    public private(set) var lastFirstFrameAt: CFAbsoluteTime = 0
    public private(set) var lastFirstFrameAssetID: String?
    /// The selection-entry clock `loadEditForAnchor` measures from.
    private var selectionChangedAt: CFAbsoluteTime = 0

    private func markSelectionChanged() {
        selectionChangedAt = CFAbsoluteTimeGetCurrent()
    }

    /// When a switch's document is not assigned synchronously (the 530 fix moves the reads to a
    /// task), the old document must not stay readable under the new anchor. This test-only door
    /// re-opens the pre-530 order — assign only when the first frame lands — so the acceptance's
    /// reverse gate can prove the synchronous path is load-bearing. Production leaves it `false`.
    public var defersDocumentUntilFirstFrameForTesting = false

    /// Test-only delay in front of the background history read, so a fixture can make 「等照片加载」
    /// arbitrarily long without a decoder. Production is 0.
    public var editHistoryLoadDelayForTesting: TimeInterval = 0

    /// Test-only reproduction of the pre-530 order (both reads on the main actor). The benchmark
    /// turns it on to measure the baseline on the same machine; production is `false`.
    public var loadsEditHistorySynchronouslyForTesting = false

    /// 537 — how many newest rows the background history read decodes. A write needs the cursor
    /// row, the row one undo lands on, and the tip (a redo branch must survive an undo's save);
    /// a panel-sized working set on top of that means a quick run of ⌘Z after a switch does not
    /// have to fall back to the whole stack. 64 also keeps the decoded window inside the ticket's
    /// 5 ms p95 budget (the 393-row stack in the demo library is ~1.3 KB of JSON per row).
    /// The full stack is read lazily when the history panel opens or an operation targets an
    /// older row (`loadFullEditHistoryIfNeeded()`).
    public static let pendingEditHistoryWindow = 64

    /// 537 — the wait in front of a history write was unbounded; 530 measured the read at p95
    /// 883 ms, so a commit right after a switch could freeze the main thread for that long. This
    /// is a **hang guard**, not a performance target: the window read above normally returns in a
    /// few milliseconds, so this limit should not be reached in production. Tests may shorten it.
    public static let defaultPendingEditHistoryWaitLimit: TimeInterval = 1.2

    /// 537 — test-injectable copy of the limit above. One place defines the default.
    public var pendingEditHistoryWaitLimit = CatalogSession.defaultPendingEditHistoryWaitLimit

    /// 537 — readback for the benchmark: how long the last `flushPendingEditHistory()` blocked, and
    /// how many times the 1.2 s cap was actually hit (the ticket asks for 0 on the normal path).
    public private(set) var lastPendingEditHistoryWaitMilliseconds: Double = 0
    public private(set) var pendingEditHistoryWaitCount = 0
    public private(set) var pendingEditHistoryWaitTimeouts = 0

    /// 537 — false while `history` holds only the newest window (or is still the one-row floor).
    /// `historyRows` and the operations that can target an arbitrary row load the full stack first.
    public private(set) var historyWindowIsComplete = true

    /// True once a window (complete or not) has actually replaced the one-row floor. Kept apart
    /// from `historyWindowIsComplete` so a failed load's floor is never merged into a later full
    /// read as if it were stored history.
    private var historyWindowLoaded = false

    /// A switch whose document read has finished but whose history read is still on a background
    /// queue. Anything that *writes* history calls `flushPendingEditHistory()` first: the user's
    /// undo stack must be the stored one before a snapshot is appended, never a one-row baseline
    /// that would truncate the persisted stack.
    private final class EditHistoryLoadBox: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stored: EditHistoryWindow?

        func finish(_ window: EditHistoryWindow?) {
            lock.lock()
            stored = window
            lock.unlock()
            semaphore.signal()
        }

        var result: EditHistoryWindow? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private struct PendingEditHistoryLoad {
        let assetID: String
        let token: Int
        let box: EditHistoryLoadBox
    }

    private var pendingEditHistory: PendingEditHistoryLoad?
    private var editHistoryLoadToken = 0
    /// 537 — a background read that threw. With no stack and no window, a write must be refused
    /// rather than based on the one-row floor.
    private var editHistoryLoadFailed = false

    /// A deferred (reverse-gate) switch: everything is read, nothing is written until the frame.
    private struct DeferredEditLoad {
        let asset: Asset
        let model: EditModel
        let stack: EditHistory?
        let timeline: EditLoadTimeline
        let installsHistoryNow: Bool
    }
    private var pendingDeferredEditLoad: DeferredEditLoad?

    /// The undo stack (D10: snapshots plus a cursor, not a command log). Seeded with the state the
    /// document was opened in, so the floor of undo is "Original", never "neutral".
    public private(set) var history = EditHistory()

    /// The asset whose document is loaded in `edit` / `history`.
    public private(set) var loadedEditAssetID: String?

    /// What the last successful write to `develop_json` did (version, seq, row count). `nil` before
    /// the first save of this session — a UI that shows "saved" must read *this*, not assume.
    public private(set) var lastSaveResult: DevelopSaveResult?

    /// Why the last write failed, or nil. A failed save is never silent: the smoke asserts on it,
    /// and the inspector could surface it.
    public private(set) var lastPersistError: String?

    /// How many times `persist()` has actually written the catalog. Cheap proof that a commit
    /// reached the database instead of only the undo stack.
    public private(set) var persistCount = 0

    // MARK: DNG XMP / thumbnail (477)

    /// Read-only counters for `--ui-smoke` (`session.dngWriteStats`).
    public private(set) var dngWriteStats = DNGWriteStats()
    /// Last human-readable DNG failure (read-only file, no embedded preview, …). `nil` = last action
    /// succeeded or did not fail.
    public private(set) var lastDNGError: String?
    /// Injectable for tests; production writes to Application Support.
    public var dngJournal = DNGXMPJournal.standard
    /// Injectable for tests; production appends to `local/dng-xmp-audit.log` when that directory exists.
    public var dngAuditLog = DNGXPMAuditLog.standard
    /// Saved to disk by 文件 ▸ 保存 only (the library writes `develop_json` on every commit).
    public var dngWriteQueue = DispatchQueue(label: "photons.dng.write", qos: .utility)

    // MARK: catalog metadata (rating / flag / colour label)
    //
    // These are **library facts**, not document edits: they live in `assets.rating` /
    // `assets.flag` / `assets.color_label`, they never enter `EditModel`, `EditHistory` or
    // `develop_json`, and therefore ⌘Z never walks one back and `editRevision` never moves for
    // them. `metadataRevision` is the one signal the views watch to redraw badges, exactly like
    // `editRevision` is the one the loupe watches for pixels.

    /// Bumped on every metadata write. The grid/filmstrip observe *this* to refresh badges without
    /// a full `reload()` (row order and membership do not change unless a filter is on).
    public private(set) var metadataRevision = 0

    /// Number of metadata transactions issued this session — one per keystroke, however many
    /// photos are selected. The smoke asserts "5 selected → 1 transaction, 5 rows".
    public private(set) var metadataWriteCount = 0

    /// Rows the last metadata statement actually changed (`db.changesCount`).
    public private(set) var lastMetadataAffectedRows = 0

    /// What the grid is narrowed to. Survives a selection change by construction: only
    /// `applyFilter`/`clearFilter` write it, and `reload()` reads it.
    public private(set) var filter = CatalogFilter.none

    /// Distinct camera keys in the library, for the filter bar's popup. Refreshed when an
    /// unfiltered load runs, so narrowing the grid does not shrink the list of cameras to choose.
    public private(set) var allCameraKeys: [String] = []

    /// `camera_key` → `camera_model`, for the slot popup's labels (a key is `make|model`, lowercased;
    /// the model is what the user recognises). Refreshed with `allCameraKeys`.
    public private(set) var allCameraLabels: [String: String] = [:]

    /// The assets a metadata command applies to: the whole selection, or the anchor when the
    /// selection is empty (a filter can leave nothing selected while the anchor is still visible).
    public var metadataTargetIDs: [String] {
        let ids = selectedAssets.map(\.id)
        if !ids.isEmpty { return ids }
        if let anchorID, assets.contains(where: { $0.id == anchorID }) { return [anchorID] }
        return []
    }

    public var canUndo: Bool { history.canUndo }
    public var canRedo: Bool { history.canRedo }
    /// Label of the action ⌘Z would take back — what the menu item should read.
    public var undoLabel: String? { history.undoLabel }
    public var redoLabel: String? { history.redoLabel }

    // MARK: view state (mirrors, never duplicates, model state)

    public var mode: Mode = .grid {
        didSet { if mode == .loupe, anchorID == nil { anchorID = assets.first?.id } }
    }

    /// True while a continuous control (a slider) is being dragged.
    ///
    /// View state, exactly like `mode` and `selectedMaskID`: not in `EditModel`, not in history, not
    /// persisted. It exists so entering the loupe on the first real write of a grid drag can be
    /// asserted without a window: the mode changes under the gesture, the gesture does not end.
    public private(set) var isAdjusting = false

    /// Slider press/release, called by the panel's one row builder (`InspectorView.sliderRow`).
    func setAdjusting(_ adjusting: Bool) {
        guard adjusting != isAdjusting else { return }
        isAdjusting = adjusting
    }

    // MARK: view state — sort order
    //
    // The order the grid, the left browser and the filmstrip read `assets` in. It is **one value in
    // one place**: the three views never sort anything themselves, they index this array, so "the
    // three views agree" holds by construction rather than by three copies of a comparator. It is
    // view state: not in the document, not in `EditHistory`, not in `develop_json` — flipping it must
    // leave `editRevision`, `history` and the pixels exactly where they were.

    /// `.newestFirst` (default) / `.oldestFirst`, restored from `PhotoSortPreferences` at launch.
    public private(set) var sortOrder: PhotoSortOrder

    /// Where the choice is remembered (`AppPreferences.store`：app 里是 standard，测试里是隔离域).
    private let sortPreferenceStore: PhotoSortPreferences.Store

    /// Where 「上次打开哪个库」 is remembered. Injectable so a test owns its own domain.
    private let recentLibraryStore: RecentLibrary.Store

    /// Turned off by the smoke/bench harness (`UISmokeRunner`): its temporary library must not become
    /// the user's "last opened" library. Public because the runner sets it before `run()`.
    public var remembersRecentLibrary: Bool

    // MARK: view state — masks (Q22)
    //
    // None of this is in the document, in a cache key or in history. It is what the canvas and the
    // inspector are currently pointed at: which mask is selected, which tool a drag means, and how
    // wide the brush is. `EditModel.showMaskID` is the one piece that lives in the document *value*
    // (the renderer reads the document) but it too is view state — `MaskViewState` keeps it out of
    // snapshots and out of the stored blob.

    /// The mask the canvas paints into and the inspector edits.
    public private(set) var selectedMaskID: String?

    /// What a drag on the canvas means. `.off` = pan, which is the pre-mask behaviour.
    public var maskTool: MaskTool = .off

    /// Brush diameter in **short-edge units** (0.12 = 12 % of the short edge of the photo). Each
    /// stroke stores its own radius, so changing this never changes a stroke already painted.
    ///
    /// The three defaults are named constants because the panel's double-click reset puts a brush row
    /// back on them: a literal in the reset closure would be a second answer to 「画笔的默认是多少」.
    public static let defaultBrushSize: Double = 0.12
    /// 0…1. A hard brush (`1`) has a 1 px edge; `0` is a fully feathered stamp.
    public static let defaultBrushHardness: Double = 0.5
    /// 0…1 per-stroke alpha multiplier.
    public static let defaultBrushFlow: Double = 1.0

    public var brushSize: Double = CatalogSession.defaultBrushSize
    public var brushHardness: Double = CatalogSession.defaultBrushHardness
    public var brushFlow: Double = CatalogSession.defaultBrushFlow

    // MARK: view state — 修复画笔 (078 P0-1)
    //
    // View state, all four: arming the tool, which spot the panel points at, the radius the *next*
    // click will use and the mode it will use. Nothing here is in the document, in a cache key or in
    // a snapshot — the spots themselves are (`EditModel.healSpots`).

    /// The canvas click adds a spot instead of panning. Disarms the mask tools and vice versa: two
    /// canvas gestures that both claim the first click cannot both be armed.
    public var healTool: Bool = false

    /// The spot the panel's rows are about.
    public var selectedHealSpotID: String?

    /// Radius of the next spot, in short-edge units of the frame.
    public var healRadius: Double = HealSpot.defaultRadius

    /// Mode of the next spot.
    public var healMode: HealMode = .heal

    // MARK: view state — 229 红眼
    //
    // Same rule as the heal view state above: none of this is in the document, a snapshot or a
    // cache key. The spots themselves are.

    /// 修复 / 红眼 — what the next canvas click means.
    public var healToolMode: HealToolMode = .heal

    /// The red-eye search radius, in **view points** (the card's 0.5…8 pt slider). The controller
    /// converts it to short-edge units with the live projection, so it means the same distance on
    /// screen at fit and at 1:1.
    public var redEyeRadiusPoints: Double = RedEye.defaultRadiusPoints

    /// 0…1 — the spot's opacity, shown as 0…100 in the card.
    public var redEyeStrength: Double = 1.0

    /// What the last red-eye click measured (the card's one status line; `nil` = no pupil found).
    public private(set) var lastRedEyeDetection: RedEye.Detection?

    /// Vision's face/animal hints for one image. Injectable so a headless test can answer without
    /// running a model; production is `RedEyeVision`, on the click only.
    public var redEyeFaceHintProvider: ((LinearImage) -> [RedEyeFaceHint])? = { image in
        RedEyeVision.hints(in: image)
    }

    /// Internal door for `addRedEyeSpot`, so a view cannot pretend a detection happened.
    func setLastRedEyeDetection(_ detection: RedEye.Detection?) {
        lastRedEyeDetection = detection
    }

    /// 自动取源：**view state**，不进文档、不进快照、不进 cache key。默认开。
    public var autoHealSource: Bool = true

    /// 搜索读的那张图。由 loupe 在解码落地后装上（`decoded?.oriented()`）；测试里可以是 nil，
    /// 此时搜索返回 `.searchSkipped` 并退回 `(2r, 0)` —— 也就是 184 之前的行为。
    /// 已知限度：这是未裁切的正立图，裁切时环带量的是裁切前的内容（源仍合法，只是不最优）。
    public var healFrameProvider: (() -> LinearImage?)?

    /// 最近一次新点取源的结果（面板/测试读它；`nil` = 还没有新点）。
    public private(set) var lastHealSource: HealSourceResult?

    /// Internal door for `MaskCanvasController.addHealSpot` (same module): the setter stays private
    /// so a view cannot pretend a search happened.
    func setLastHealSource(_ result: HealSourceResult?) {
        lastHealSource = result
    }

    /// The **upright** pixel size of the photo on screen, as the renderer actually ingested it
    /// (`RenderGraph.sourceSize`, i.e. after EXIF orientation was applied — task 028).
    ///
    /// Mask parameters are normalised to this frame, and every short-edge distance (`brushSize`, a
    /// stroke's radius, a radial mask's rim) is a fraction of it. The catalog row's `width/height` are
    /// the *stored* dimensions, which are transposed for EXIF 5…8: a portrait frame then converts
    /// `left/right` rim offsets with the landscape ratio and the ellipse renders half again as wide as
    /// the hand drew it. Written once per presented photo by the loupe, keyed by asset id so a photo
    /// switch cannot inherit the previous picture's frame before its own decode lands.
    public internal(set) var ingestedSourceFrame: (assetID: String, size: ImageSize)? {
        didSet {
            // 530 — the loupe publishes exactly one frame per presented photo. A new photo's first
            // frame closes that switch's timeline, which is the second number the acceptance asks
            // for (「edit 已赋值 → 首帧」).
            guard let frame = ingestedSourceFrame,
                  oldValue?.assetID != frame.assetID else { return }
            let now = CFAbsoluteTimeGetCurrent()
            lastFirstFrameAt = now
            lastFirstFrameAssetID = frame.assetID
            if let pending = pendingDeferredEditLoad, pending.asset.id == frame.assetID {
                pendingDeferredEditLoad = nil
                applyEditLoad(pending)
            }
            if var timeline = lastEditLoadTimeline, timeline.assetID == frame.assetID,
               timeline.firstFrameAt == nil {
                timeline.firstFrameAt = now
                lastEditLoadTimeline = timeline
            }
        }
    }

    /// 290 — the EXIF orientation the import recorded for `assetID`, or `nil` when the row has no
    /// metadata (or no orientation). The first-frame stand-in runs **before** the first ingest
    /// publishes `ingestedSourceFrame`, so this is the one fact that turns the catalog row's stored
    /// dimensions into the upright aspect the thumbnail already shows.
    public func sourceOrientation(of assetID: String) -> ImageOrientation? {
        guard let catalog,
              let value = (try? catalog.metadata(assetId: assetID))?.orientation else { return nil }
        return ImageOrientation(exifOrDefault: value)
    }

    /// The crop tool's **live** draft geometry while the tool is open (派单 049).
    ///
    /// The draft is view state that lives in `CropToolController` and reaches the document only at
    /// 应用, so `edit` does not move while the box is being dragged — the information row would sit
    /// on the old numbers until the drag ended. This is the one bridge: written by the tool on every
    /// draft change (and cleared on 应用 / 取消 / 离开), read by the inspector, never written to the
    /// document, the history or the render key. `assetID` is carried because a published draft must
    /// not be applied to the next photo's row.
    public internal(set) var cropToolDraft: (assetID: String, geometry: GeometryGroup)?

    /// What the next drag on the canvas creates, when a shape gradient is waiting for one.
    ///
    /// View state like `maskTool`: selecting 线性/径向渐变 in the inspector's 新建 menu arms a drag,
    /// and the mask is created **when the drag ends** with the geometry the user drew. That ordering
    /// is what makes one gesture one snapshot instead of "new mask" + "move it".
    public var pendingMaskShape: MaskCreationKind?

    /// Drag on the canvas adjusts the selected linear/radial mask instead of panning.
    ///
    /// On by default because "I just drew an ellipse" is followed by "…a bit more to the left" far
    /// more often than by a pan, and only armed while a *shape* mask is selected — a brush mask, or
    /// no mask, leaves the camera alone.
    public var adjustShapeOnDrag: Bool = true

    /// The semantic sub-kind the next 语义 mask uses (the 新建 menu's submenu).
    public var pendingSemanticKind: SemanticKind = .subject

    /// The mask the frame is painting over, or nil.
    public var shownMaskID: String? { edit.showMaskID }

    /// The overlay is on for `selectedMaskID` — what the inspector's toggle reads.
    public var isShowingSelectedMask: Bool {
        guard let id = selectedMaskID else { return false }
        return edit.showMaskID == id
    }

    // MARK: decoder facts

    /// What the last decode actually used — v9 or a silent v8 downgrade (§11.1).
    public private(set) var capabilities: DecoderCapabilities?

    /// The photo `capabilities` describes. The decoder facts come from a frame, which can outlive
    /// the selection that asked for it (443); this is what keeps 540's per-photo write from
    /// attributing one picture's as-shot pair to the next one.
    private var capabilitiesAssetID: String?

    /// 540 — the **loaded photo's** as-shot white balance, available as soon as `edit` is assigned.
    ///
    /// It is the stored catalog row on a switch (`Catalog.storedAsShotWhiteBalance`), and the first
    /// frame's value on a first visit. `nil` means "no value yet" — the rows keep today's behaviour
    /// (as shot without a number) instead of borrowing the previous photo's pair.
    public private(set) var asShotWhiteBalance: WhiteBalance?

    /// 540 — how many times a stored pair disagreed with the first frame that landed. A mismatch is
    /// corrected immediately, but it is counted so a decoder/archive drift is visible rather than
    /// silently rewritten.
    public private(set) var asShotMismatchCount = 0

    /// 540 — successful as-shot catalog writes made by this session (a row that already matches is
    /// not rewritten, so the counter staying put is proof the first frame changed no facts).
    public private(set) var asShotStoreWriteCount = 0

    private var catalog: Catalog?

    /// 451 — test seam for the reload guard. When set, `reload()` reads the source roots through
    /// this instead of the catalog, so a throwing loader can prove a failed load keeps the last
    /// good tree. Production never sets it.
    var reloadRootsLoader: (() throws -> [SourceRoot])?

    /// 451 — what the last startup sweep did (nil before the first one finishes). Read by the
    /// report/tests; no UI depends on it.
    public private(set) var lastSweepReport: SweepReport?

    /// Where the filter bar's state is remembered (043). Injectable so a test runs against its own
    /// domain and can count writes; production gets `AppPreferences.store`（= `UserDefaults.standard`）。
    public let filterPersistence: FilterPersistence.Writer

    /// The library the filter is remembered *for* — the key of the archive the next write goes to.
    /// Set by `open`; nil until a library is open, which is why a filter applied with no library
    /// open is not written anywhere (there is no library to attach it to).
    private var filterPersistencePath: String?

    public init(filterStore: FilterPersistence.Store = AppPreferences.store,
                sortPreferenceStore: PhotoSortPreferences.Store = AppPreferences.store,
                recentLibraryStore: RecentLibrary.Store = AppPreferences.store,
                remembersRecentLibrary: Bool = true) {
        filterPersistence = FilterPersistence.Writer(store: filterStore)
        self.sortPreferenceStore = sortPreferenceStore
        self.recentLibraryStore = recentLibraryStore
        self.remembersRecentLibrary = remembersRecentLibrary
        // Restored before the first `open()`, so a session's very first query already lands in the
        // order the user chose last time — there is no "restore after the first paint" flicker.
        sortOrder = PhotoSortPreferences.recall(from: sortPreferenceStore)
    }

    // MARK: lifecycle

    public var isOpen: Bool { catalog != nil }

    public func open(_ url: URL) throws {
        let c = try Catalog.open(at: url)
        catalog = c
        libraryURL = url.standardizedFileURL
        // A missing cache directory is created by the initialiser; a failure here only means the
        // grid falls back to placeholders, which must not stop the library from opening.
        thumbnailCache = try? ThumbnailCache(layout: c.layout)
        // 485 — the edit-time denoise cache. Global (not per library) on purpose: the key starts
        // with the source content hash, so the same original cleans once across libraries.
        makeDenoiseCleaner()
        denoiseStats = DenoiseCleanerStats()
        loadedEditAssetID = nil
        // Anything still pending belongs to the library we are leaving (043): write it before the
        // path changes, so a fast 打开另一个库 → 回来 does not lose the last click.
        filterPersistence.flush()
        let path = Self.filterPersistencePath(for: url)
        filterPersistencePath = path
        // The previous library's filter must not be inherited: this is the *reset* half of "remember
        // per library". Assigned directly rather than through `applyFilter` because the restore right
        // below (or the `reload()` further down) is what runs the query — one query, not three.
        filter = .none
        // 上一个库的相册范围同理不能继承：相册 id 属于那个库，留在 `selectedAlbumID` 里只会让新库的
        // 第一次查询空着（`reload()` 也会把它当"已不存在的相册"丢掉，但没必要开一次空查询）。
        selectedAlbumID = nil
        albums = []
        // Before the first query, so the grid's very first paint already carries 「原文件已移动」:
        // the flag is a filesystem fact and this is the only moment it can be fresh. A failure here
        // only means the flags keep yesterday's values, which is why it does not throw.
        lastAvailability = try? c.refreshAvailability()
        // 043 — the bar's slots are view state remembered per library, restored **before the first
        // query** so the grid's very first paint is already narrowed. It goes through `applyFilter`,
        // the door a click uses: a restored filter must be indistinguishable from a clicked one —
        // which also means its `reload()` is the only query this open runs when an archive exists.
        if let restored = filterPersistence.recall(libraryPath: path), restored != filter {
            applyFilter(restored)
        } else {
            reload()
        }
        // The preset list and the Develop menu read this cache; fill it as soon as the library is
        // open instead of waiting for the panel's first `onAppear`.
        reloadPresets()
        // 477 — rows the library has no document for get one chance from the DNG's own XMP. Async:
        // opening a library must not wait on a folder of 60 MB originals.
        backfillEditsFromXMP()
        // 081 §3: the 复制设置 checklist is remembered **per library**, so it is read here and not
        // from `UserDefaults`. A library that never stored one answers 全部.
        copySelection = (try? c.copySelection()) ?? .all
        // 295 B: the next launch has no `--library`, so it has to know which library this was. Only
        // reached when `Catalog.open` succeeded — a failed open must not overwrite the last good one.
        if remembersRecentLibrary {
            RecentLibrary.remember(url, in: recentLibraryStore)
        }
        // 451 — 降噪/HDR 跑到一半被杀会留下隐藏临时文件与 `running` 的 import session。打开库时
        // 扫一次（库包 + 各来源根，深度 2）；异步、不抛错，绝不让清扫拖住打开。
        sweepInterruptedWork(c, library: libraryURL ?? url.standardizedFileURL, roots: roots)
    }

    /// 451 — startup self-healing. The file half is bounded (depth 2) and only matches the strict
    /// temp names; the DB half books orphan `running` sessions as `interrupted`. A failure only
    /// lands in `lastPersistError` — it must never keep the library from opening.
    private func sweepInterruptedWork(_ catalog: Catalog, library: URL, roots: [SourceRoot]) {
        let sourceRoots = roots.map { URL(fileURLWithPath: $0.pathHint) }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var report = InterruptedWorkSweep.sweep(libraryRoot: library, catalog: catalog)
            for root in sourceRoots {
                let extra = InterruptedWorkSweep.sweep(libraryRoot: root)
                report.filesRemoved += extra.filesRemoved
                report.bytes += extra.bytes
                if report.error == nil { report.error = extra.error }
            }
            Task { @MainActor in
                guard let self else { return }
                self.lastSweepReport = report
                if let error = report.error { self.lastPersistError = error }
            }
        }
    }

    /// Where this library's filter archive lives. The path is the library *directory*; the hash of it
    /// inside `FilterPersistence` is what makes a path with a user name or CJK safe as a defaults key.
    private static func filterPersistencePath(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    public func reload() {
        guard catalog != nil else { return }
        loadProjection()
        reconcileSelectionAfterReload()
    }

    /// The query half of `reload()`: roots, folder tree, albums and the visible projection
    /// (`assets` = stack tops only, plus `stacksByTopID`).
    ///
    /// Split out for 524: a denoise item finishes while the user is looking at the library, and the
    /// new stack must appear **without** `reload()`'s selection reconciliation moving the user's
    /// selection onto the product. `reloadKeepingSelection` below runs this half and then writes the
    /// captured selection back; every other caller still uses `reload()` and gets both halves.
    private func loadProjection() {
        guard let c = catalog else { return }
        do {
            let loadedRoots: [SourceRoot]
            if let loader = reloadRootsLoader {
                loadedRoots = try loader()
            } else {
                loadedRoots = try c.roots()
            }
            roots = loadedRoots
            // One scan for the whole tree, before the rows: the source list and the photo list are
            // then guaranteed to describe the same library state, and a selected folder that lost
            // its last photo (a delete, a relink) stops filtering instead of filtering to nothing.
            folderNodes = (try? c.folderIndex()) ?? [:]
            // 相册：左栏的「相册」段与它每一行的数字都读这一个列表（078 B10）。加载在查询**之前**，
            // 因为下面那次 `assets()` 就带着 `selectedAlbumID`；一个已经不存在的相册（另一个进程删的、
            // 或者本进程刚删的）必须在这里被丢掉，否则网格会永远空着而左栏没有那一行可点回来。
            albums = (try? c.albums()) ?? []
            if let open = selectedAlbumID, !albums.contains(where: { $0.id == open }) {
                selectedAlbumID = nil
            }
            // Drop selections that no longer exist — a delete, a relink or a removed root. A dead
            // *root* drops its row outright; a dead *subfolder* falls back to its root, which is
            // what the single-selection model did ("the folder I was in lost its last photo" must
            // narrow to the root, not to nothing). Multi-selection keeps the other rows.
            if !selectedFolders.isEmpty {
                var kept: [FolderSelection] = []
                for sel in selectedFolders {
                    guard let id = sel.rootId, roots.contains(where: { $0.id == id }) else { continue }
                    guard let path = sel.normalizedPath else { kept.append(sel); continue }
                    if (folderNodes[id] ?? []).contains(where: { $0.path == path }) {
                        kept.append(sel)
                    } else {
                        kept.append(FolderSelection(rootId: id, path: nil))
                    }
                }
                let normalized = Self.normalizedFolders(kept)
                if normalized != selectedFolders { selectedFolders = normalized }
            }
            // The grid is the library view: everything the catalog has, in the session's sort order.
            // M3 has no paging; 10k rows is the design point.
            // The filter bar's value is folded into the *same* query the source list uses, so the
            // visible rows, their order and the count in the top bar can never disagree.
            //
            // The order is applied **here and nowhere else** on the load path: the query itself
            // returns `capture_time DESC` (the catalog's index order), and `sortOrder.sorted` makes
            // the array the one truth every view reads. Picking `.oldestFirst` therefore needs no
            // second SQL dialect (`ORDER BY … ASC`) and no second query — one comparator defines
            // "newest" for the grid, the browser and the strip at once.
            let f = filter
            let albumScope = selectedAlbumID.map { [$0] } ?? []
            assets = sortOrder.sorted(try c.assets(f.assetFilter(limit: 200_000,
                                                                 folders: selectedFolders,
                                                                 albumIds: albumScope)))
            // §378 — the other half of the projection: which stacks the visible rows stand for.
            // One query for every stack id on screen (not one per row), and only stacks whose
            // **top** survived the filter get an entry — a stack only a hidden member would match
            // is not in `assets` and must not be in this table either.
            let projection = Self.stacksByTop(assets, catalog: c)
            stacksByTopID = projection.byTop
            stackTopIDsWithMissingMembers = projection.missingTopIDs
            stats = try c.stats()
            loadError = nil
            // The camera list is a property of the library, not of the current filter: derive it
            // only from an unfiltered load so narrowing never removes a choice from its own popup.
            if !f.isActive {
                allCameraKeys = Array(Set(assets.compactMap(\.cameraKey))).sorted()
                var labels: [String: String] = [:]
                for asset in assets {
                    guard let key = asset.cameraKey, let model = asset.cameraModel, !model.isEmpty else { continue }
                    if labels[key] == nil { labels[key] = model }
                }
                allCameraLabels = labels
            }
        } catch {
            // 451 — 一次失败的 reload **不能**清空文件夹树：`roots=[]` 会让左栏只剩「全部照片」，
            // 用户就「无法筛选文件夹」，而且要等到下一次成功 reload（例如降噪收尾那次）才回来。
            // 保留上一次成功的 roots / folderNodes / assets，只把错误记下来并打一行日志。
            loadError = error.localizedDescription
            lastPersistError = "\(error)"
            NSLog("photons: reload failed, keeping the last good tree: \(error)")
        }
    }

    /// The selection half of `reload()`: drop what the projection no longer shows, hand a dead
    /// anchor to its successor, and load the anchor's document.
    private func reconcileSelectionAfterReload() {
        // Drop selections that no longer exist (a reload can follow an import).
        let ids = Set(assets.map(\.id))
        selection.formIntersection(ids)
        // The range base and cursor follow the same rule: an id that is gone cannot anchor a ⇧.
        if let base = selectionBase, !ids.contains(base) { selectionBase = nil }
        if let focus = rangeFocus, !ids.contains(focus) { rangeFocus = nil }
        let successor = pendingAnchorSuccessor
        pendingAnchorSuccessor = nil
        if let a = anchorID, !ids.contains(a) {
            // A delete hands the anchor to the next photo the user saw, not to the first row. Any
            // other reload keeps `pendingAnchorSuccessor == nil` and falls back to the first row.
            anchorID = successor.flatMap { ids.contains($0) ? $0 : nil } ?? assets.first?.id
        }
        if anchorID == nil { anchorID = assets.first?.id }
        if selection.isEmpty, let first = anchorID { selection = [first] }
        // A fresh library (or a new root) can leave `edit` pointing at the previous document; load
        // the anchor's stored document now instead of waiting for the next selection change.
        if let a = anchorAsset, loadedEditAssetID != a.id { loadEditForAnchor() }
    }

    /// The four selection fields, captured across a reload that must not move them (524).
    private struct SelectionSnapshot {
        let selection: Set<String>
        let anchorID: String?
        let selectionBase: String?
        let rangeFocus: String?
    }

    /// 524 — a reload for the denoise finish paths: the new stack becomes visible, the user's
    /// selection does not move.
    ///
    /// `reload()` narrows the four selection fields to the **visible projection**. A denoise product
    /// is a stack top and the photo it was made from becomes a hidden member, so the ids the user
    /// had selected leave `assets` even though their rows are still in the library. Two things are
    /// therefore forbidden here: letting `reload()` throw that selection away, and selecting the
    /// product instead (529 — that is what pulled the foreground away and made later edits land in
    /// the denoised file). So the projection is queried first and the captured fields are written
    /// back.
    ///
    /// `topByID` handles the single-photo path: the one selected original is drawn as its stack's
    /// top, so the selection follows that top (visually the same cell) rather than jumping elsewhere.
    /// An id whose row is **really gone** (deleted / unlinked) keeps `reload()`'s own fallback; this
    /// never invents a selection.
    private func reloadKeepingSelection(topByID: [String: String] = [:]) {
        guard catalog != nil else { return }
        let snapshot = SelectionSnapshot(selection: selection, anchorID: anchorID,
                                         selectionBase: selectionBase, rangeFocus: rangeFocus)
        let started = Date().timeIntervalSinceReferenceDate
        loadProjection()
        lastDenoiseItemReloadSeconds = Date().timeIntervalSinceReferenceDate - started
        // The empty start is the documented exception: there is nothing to keep, and `reload()`'s
        // own fallback (the first visible row, which may be the new product) is allowed to land.
        guard !snapshot.selection.isEmpty else {
            reconcileSelectionAfterReload()
            return
        }
        guard let catalog else { return }
        func inLibrary(_ id: String) -> Bool { (try? catalog.asset(id: id)) != nil }
        guard snapshot.selection.allSatisfy(inLibrary) else {
            // A row really disappeared while the batch ran: answer exactly like every other reload.
            reconcileSelectionAfterReload()
            return
        }
        func followed(_ id: String?) -> String? {
            guard let id, inLibrary(id) else { return nil }
            return topByID[id] ?? id
        }
        selection = Set(snapshot.selection.compactMap(followed))
        if let anchor = snapshot.anchorID { anchorID = followed(anchor) }
        selectionBase = followed(snapshot.selectionBase)
        rangeFocus = followed(snapshot.rangeFocus)
        // Do not switch the open document. A restored anchor that the projection hides (the batch
        // case) must leave `edit` / `loadedEditAssetID` exactly where the user had them — loading the
        // fallback anchor here is what let a pending edit reach the product. Only the single path's
        // visible stack top needs its document loaded.
        if let a = anchorAsset, loadedEditAssetID != a.id { loadEditForAnchor() }
    }

    // MARK: import (文件 ▸ 导入照片…)

    /// An `ImportService` for this library, for a caller that runs it **off the main actor**
    /// (`ImportCoordinator`). Nil when no library is open — which is exactly the condition the menu
    /// item is validated against.
    ///
    /// The engine is handed out instead of being driven by the session: `ImportService.run` is
    /// synchronous and does its own writing through `catalog.dbQueue`, so the caller owns the
    /// background queue and only the *result* comes back to the main actor.
    public func makeImportService() -> ImportService? {
        guard let catalog else { return nil }
        return ImportService(catalog: catalog)
    }

    /// After an import: reload, then select the first of `ids` that survived the current filter.
    /// A photo the filter hides must not become the anchor — that would leave the grid showing no
    /// selection at all. With nothing added the current selection is kept as it is.
    public func selectImported(_ ids: [String]) {
        reload()
        guard let hit = ids.first(where: { id in assets.contains { $0.id == id } }) else { return }
        selectOnly(hit)
    }

    // MARK: photo stacks (§378) — 库属性，不是编辑
    //
    // A stack is目录元数据: it lives in `assets.stack_id` / `assets.stack_rank`, so nothing in this
    // section touches `edit`, `history`, `develop_json` or `editRevision` — ⌘Z never walks a stack
    // back. Every verb is one transaction and **one** `metadataRevision` bump (the same signal a
    // rating uses), then one `reload()`: the projection (`assets` = tops only) and
    // `stacksByTopID` are recomputed together, so a card can never lose its 「⧉ N」 while the row
    // it counts is still hidden, or the other way round.

    /// Why the last stack command did nothing, or nil. Reported, never swallowed (same contract as
    /// `lastMetadataAffectedRows` / `lastAvailabilityError`).
    public private(set) var lastStackError: String?

    /// Rows the last stack statement changed.
    public private(set) var lastStackAffectedRows = 0

    /// The stack a displayed row stands for, or nil. `stacksByTopID` is keyed by the top id, and
    /// only tops are ever in `assets`, so this is the one lookup a cell needs.
    public func stackSummary(forAssetID id: String) -> StackSummary? {
        stacksByTopID[id]
    }

    /// Members of the stack behind a displayed row, in display order (top included). Asked when the
    /// right-click submenu opens, not on every paint.
    public func stackMembers(topID: String) -> [Asset] {
        guard let summary = stacksByTopID[topID], let catalog else { return [] }
        return (try? catalog.stackMembers(stackID: summary.id)) ?? []
    }

    /// Members of the stack an asset **belongs to** — the same list whether the id is the top or a
    /// hidden member. Nil when the id is in no stack.
    public func stackMembers(ofAssetID id: String) -> [Asset]? {
        guard let catalog else { return nil }
        if let summary = stacksByTopID[id] {
            return (try? catalog.stackMembers(stackID: summary.id)) ?? []
        }
        guard let found = (try? catalog.stackID(ofAsset: id)) ?? nil else { return nil }
        return try? catalog.stackMembers(stackID: found)
    }

    /// 堆叠所选照片 (⌘G): the selection, **in display order**, becomes one new stack whose first
    /// member is 置顶.
    ///
    /// Fewer than two photos is a no-op with an error, not a stack of one: one photo is already a
    /// stack's worth of nothing, and a "stack" of one would hide its own badge rule (≥ 2).
    /// Cross-album and cross-filter selections are allowed on purpose — the members need not be
    /// visible together, and the path is not validated at all.
    @discardableResult
    public func stackSelection() -> StackSummary? {
        guard let catalog else {
            lastStackError = Loc.t("未打开库")
            return nil
        }
        let ids = selectedAssets.map(\.id)
        guard ids.count >= 2 else {
            lastStackError = Loc.t("堆叠至少需要选中两张照片")
            return nil
        }
        do {
            guard let summary = try catalog.makeStack(assetIDs: ids) else {
                lastStackError = Loc.t("选中的照片已经不在库里")
                return nil
            }
            lastStackError = nil
            lastStackAffectedRows = summary.count
            metadataWriteCount += 1
            lastMetadataAffectedRows = summary.count
            metadataRevision &+= 1
            reload()
            // The other members just left the projection: the selection follows to the 置顶 only.
            if assets.contains(where: { $0.id == summary.topID }) { selectOnly(summary.topID) }
            return summary
        } catch {
            lastStackError = "\(error.localizedDescription)"
            return nil
        }
    }

    /// 取消堆叠 (⇧⌘G): every stack the selection (or the anchor) touches dissolves — all of its
    /// members return to `stack_id = NULL, stack_rank = 0`.
    ///
    /// Returns the number of photos that came back. Zero with no stack in the selection is not an
    /// error condition worth an alert; `lastStackError` stays nil (the user sees nothing happen
    /// because nothing was stacked).
    @discardableResult
    public func ungroupSelection() -> Int {
        guard let catalog else {
            lastStackError = Loc.t("未打开库")
            return 0
        }
        let ids = metadataTargetIDs
        guard !ids.isEmpty else { return 0 }
        // The members that come back are what the user selected the *stack* for; select them again
        // after the reload so ⇧⌘G visibly restores the row group.
        var returning: [String] = []
        for id in ids {
            if let summary = stacksByTopID[id] { returning.append(contentsOf: summary.memberIDs) }
        }
        do {
            let affected = try catalog.ungroup(assetIDs: ids)
            guard affected > 0 else {
                lastStackError = nil
                return 0
            }
            lastStackError = nil
            lastStackAffectedRows = affected
            metadataWriteCount += 1
            lastMetadataAffectedRows = affected
            metadataRevision &+= 1
            reload()
            let visible = returning.filter { id in assets.contains { $0.id == id } }
            if !visible.isEmpty {
                setSelection(Set(visible), anchor: visible.first)
            }
            return affected
        } catch {
            lastStackError = "\(error.localizedDescription)"
            return 0
        }
    }

    /// 设为置顶: the chosen member becomes the stack's top, and the previous top takes its old rank
    /// (a swap, not a re-sort).
    ///
    /// The row in `assets` is **replaced** by the new top on the next projection, and the selection
    /// follows it — that is what "click the second member and the card becomes that photo" means.
    @discardableResult
    public func setStackTop(assetID: String) -> Bool {
        guard let catalog else {
            lastStackError = Loc.t("未打开库")
            return false
        }
        let stackID = stacksByTopID.values.first(where: { $0.memberIDs.contains(assetID) })?.id
            ?? (try? catalog.stackID(ofAsset: assetID)).flatMap { $0 }
        guard let stackID else {
            lastStackError = Loc.t("这张照片不在任何堆叠里")
            return false
        }
        do {
            let changed = try catalog.setStackTop(stackID: stackID, assetID: assetID)
            lastStackError = nil
            guard changed else { return false }        // already 置顶: no write, no revision
            lastStackAffectedRows = 3                 // chosen, old top, and the stack row they share
            metadataWriteCount += 1
            lastMetadataAffectedRows = 2
            metadataRevision &+= 1
            reload()
            if assets.contains(where: { $0.id == assetID }) { selectOnly(assetID) }
            return true
        } catch {
            lastStackError = "\(error.localizedDescription)"
            return false
        }
    }

    // MARK: HDR 合成 (§384) — 右键菜单一个动词，不弹窗口
    //
    // The user's contract: 「不用弹窗口，直接和堆叠一样，在右键菜单入口」 and 「参与合成的照片 = 用户
    // 自己确认的方式就是先选好，再点菜单项」. So there is no sheet, no frame picker and no second
    // dialog: the selection *is* the choice, and the whole job is one verb that reports into
    // `lastHDRMergeError` / `lastHDRMergeProgress` — the same "a failure is never silent" contract
    // `lastStackError` keeps.
    //
    // Threading cannot be relaxed: `inspect` ≈2.8 s/frame, `merge` ≈15 s per 60 MP frame, and
    // `ImportService.run` is synchronous with its own disk I/O. The whole body therefore runs on
    // `hdrMergeQueue` and only the *result* comes back to the main actor. `hdrMergeRanOffMain`
    // records what the worker actually saw, so a test can assert the hop instead of trusting this
    // comment (§3 ⑦).

    /// Why the last HDR merge did not happen, in the service's own Chinese prose
    /// (`HDRMergeService.Failure.description`) — or the tool's compatibility sentence, which is
    /// already specific (「尺寸不一致：…」). Nil after a success. Never a sheet: no windows.
    public private(set) var lastHDRMergeError: String?

    /// The last progress line (`解码 1/3…`), then a one-line summary after a success. One string the
    /// panel or the footer can read — there is no global HUD in this app and §384 says not to build
    /// one for this.
    public private(set) var lastHDRMergeProgress: String?

    /// Runs started / finished. A test waits for the second number instead of sleeping.
    public private(set) var hdrMergeRunCount = 0
    public private(set) var hdrMergeCompletionCount = 0

    /// What the worker thread saw when it entered the blocking body. `nil` before the first run;
    /// `false` would mean the merge ran on the main thread — the bug §3 ⑦ exists to catch.
    public private(set) var hdrMergeRanOffMain: Bool?

    /// True between the click and the result: a second click must not start a second 15 s job.
    public private(set) var isHDRMergeRunning = false

    /// 392 — **参与正在进行的这一次合成的 id 列表**（空 = 没有在跑）。
    ///
    /// 为什么留列表而不是一个数：卡片的显示条件是「当前单图视图显示的照片**属于这一批**」
    /// （2026-11-12 用户补充：「HDR 合成是多张参与，所以设计的那些图片都显示」），所以运行期间必须
    /// 拿得到这批 id。降噪能只用 `denoiseAssetID` 一张，是因为它只处理一张；HDR 是多张。
    /// `hdrMergeSelection()` 的 `participants` 在开始后不再保存，这里留一份。
    ///
    /// 只在 `hdrMergeSelection()` 成功启动处写一次、`finishHDRMerge` 清空，
    /// **不参与**合成的执行、堆叠或入库，也不改任何既有状态机。
    public private(set) var hdrMergeParticipantIDs: [String] = []

    /// 392 — 卡片第二行读的张数。与列表同源，所以显示条件与「N 张」不可能各说各话。
    public var hdrMergeFrameCount: Int { hdrMergeParticipantIDs.count }

    /// 392 — 只读派生量：`nil` 表示「现在没有合成在跑」，否则是这一次参与合成的 id。
    ///
    /// 不引入第二个「是否在跑」的事实：它只有一个来源 `isHDRMergeRunning`，这里只是把
    /// 「在跑吗」与「哪几张」捆成一个原子答案，免得 UI 两次读之间状态翻了。
    public var hdrMergingParticipantIDs: [String]? {
        isHDRMergeRunning ? hdrMergeParticipantIDs : nil
    }

    /// What the last successful merge produced — the numbers the tool reported, the asset that joined
    /// the library, and the stack it tops. Nil until a merge succeeds; the failure path leaves it nil
    /// and fills `lastHDRMergeError` instead.
    public struct HDRMergeReport: Sendable, Equatable {
        public let output: URL
        public let width: Int
        public let height: Int
        public let frameCount: Int
        public let whiteLevel: Int
        public let assetID: String
        public let stackTopID: String
        public let stackCount: Int
    }

    public private(set) var lastHDRMergeReport: HDRMergeReport?

    /// The service the menu validates against and the verb calls. Injectable so a test can point the
    /// client at a missing binary (⇒ 「未找到 hdrmerge-swift」) or at a pinned copy.
    public var hdrMergeService = HDRMergeService()

    /// Whether the merge tool is **actually there**.
    ///
    /// `HDRMergeService.isAvailable` only answers "a client was resolved" — a client can name a path
    /// that no longer exists (a bundle that lost its binary, a Homebrew upgrade mid-session), and
    /// `merge` is what would then fail with `tool_missing` 15 s later. The menu needs the same answer
    /// the merge would get, so the check is the executable itself.
    public var isHDRMergeAvailable: Bool {
        guard let client = hdrMergeService.client else { return false }
        return FileManager.default.isExecutableFile(atPath: client.executableURL.path)
    }

    /// The queue the blocking half runs on. Injectable so a test can observe the hop without racing
    /// the global pool.
    public var hdrMergeQueue = DispatchQueue(label: "photons.hdr.merge", qos: .userInitiated)

    /// 合成所选的照片: 结果 + 参与的原帧 = 一个新堆叠，**结果为置顶**，参与的原帧抽离旧堆叠。
    ///
    /// Returns the participating asset ids (empty when the verb refused to start), so a test can name
    /// the frames without re-reading the selection.
    @discardableResult
    public func hdrMergeSelection() -> [String] {
        hdrMergeRunCount += 1
        lastHDRMergeError = nil
        lastHDRMergeProgress = nil
        hdrMergeRanOffMain = nil

        guard let catalog else {
            lastHDRMergeError = Loc.t("未打开库")
            return []
        }
        guard !isHDRMergeRunning else {
            lastHDRMergeError = Loc.t("已有一次 HDR 合成在进行")
            return []
        }
        guard isHDRMergeAvailable else {
            lastHDRMergeError = HDRMergeService.Failure.toolMissing.description
            return []
        }
        // The two gates the menu greys on, re-checked here: a stale menu or a keyboard path must not
        // be able to start a job the tool would refuse 3 s later.
        let chosen = selectedAssets
        var frames: [URL] = []
        var participants: [String] = []
        for asset in chosen {
            guard HDRMergeService.mergeableExtensions.contains(asset.ext.lowercased()) else {
                lastHDRMergeError = HDRMergeService.Failure.notCFARaw(asset.filename).description
                return []
            }
            guard let url = fileURL(for: asset) else {
                lastHDRMergeError = HDRMergeService.Failure.unreadable(asset.filename).description
                return []
            }
            frames.append(url)
            participants.append(asset.id)
        }
        guard frames.count >= 2 else {
            lastHDRMergeError = HDRMergeService.Failure.notEnoughFrames(frames.count).description
            return []
        }
        guard let importService = makeImportService(),
              let rootID = chosen.first?.sourceRootId
        else {
            lastHDRMergeError = Loc.t("未打开库")
            return []
        }
        // 451 — same per-operation cleanup as denoise: only this operation's prefix, only the
        // directories the frames live in (a merge may span folders).
        for directory in Set(frames.map { $0.deletingLastPathComponent() }) {
            _ = InterruptedWorkSweep.removeLeftovers(in: directory, kinds: ["hdrmerge"])
        }

        let service = hdrMergeService
        let queue = hdrMergeQueue
        isHDRMergeRunning = true
        // 392 — 卡片的两行（张数 + 显示条件）都读这一份 id 列表；它与 `participants` 是同一组，
        // 只是活到运行结束。
        hdrMergeParticipantIDs = participants
        lastHDRMergeProgress = Loc.t("准备合成…")
        // 454 P2a — every gate above returns *before* a task exists: a refused start is a validation
        // error, not work in flight, and `lastHDRMergeError` already carries the notice. From here on
        // the task is the record of this run; the progress callback advances it and `finishHDRMerge`
        // closes it on **both** outcomes, so it can never be left `running`.
        let taskID = backgroundTasks.begin(BackgroundTask(kind: .hdrMerge,
                                                           title: Loc.t("HDR 合成"),
                                                           total: participants.count,
                                                           currentAssetID: participants.first))
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in
                self?.lastHDRMergeProgress = text
                if let completed = Self.decodedFrameCount(fromProgress: text) {
                    self?.backgroundTasks.advance(id: taskID, completed: completed)
                }
            }
        }
        queue.async { [weak self] in
            let run = Self.runHDRMerge(service: service, importService: importService,
                                       catalog: catalog, frames: frames,
                                       participantIDs: participants,
                                       rootID: rootID, progress: report)
            Task { @MainActor in self?.finishHDRMerge(run, taskID: taskID) }
        }
        return participants
    }

    /// What one HDR run produced. A plain `Sendable` box so the background half never touches the
    /// session (which is main-actor isolated).
    private struct HDRMergeRun: Sendable {
        var ranOffMain = false
        var failure: String?
        var output: URL?
        var assetID: String?
        var width = 0
        var height = 0
        var frameCount = 0
        var whiteLevel = 0
        var stackTopID: String?
        var stackCount = 0
    }

    /// The blocking half. **Runs off the main thread** (asserted by the caller via `ranOffMain`).
    ///
    /// Order is the contract: 预检 → merge → 加进库 → 抽离旧堆叠 + 组新堆叠. The merged file lands
    /// next to its sources (`HDRMergeService` default), so no extra directory is invented here.
    private nonisolated static func runHDRMerge(service: HDRMergeService,
                                               importService: ImportService,
                                               catalog: Catalog,
                                               frames: [URL],
                                               participantIDs: [String],
                                               rootID: String,
                                               progress: @escaping @Sendable (String) -> Void) -> HDRMergeRun {
        var run = HDRMergeRun()
        run.ranOffMain = !Thread.isMainThread
        do {
            progress(Loc.t("预检 {0} 帧…", String(describing: (frames.count))))
            if let issue = try service.compatibilityIssue(frames) {
                run.failure = issue
                return run
            }

            var importedID: String?
            var importFailure: String?
            let outcome = try service.merge(frames, progress: { progress($0) }, onOutput: { url in
                // `onOutput` is the module's own "add this to your library" hook — it knows nothing
                // about catalogs, which is why the import lives here and not in PhotonsExtensions.
                // `ImportService` dedupes by content hash, so a re-run cannot create two rows.
                do {
                    let summary = try importService.run(sources: [url],
                                                        options: ImportOptions(mode: .reference,
                                                                               rootID: rootID,
                                                                               recursive: false))
                    importedID = summary.addedAssetIDs.first
                    if importedID == nil {
                        importFailure = Loc.t("合成结果已经在库里（内容相同），没有新建照片")
                    }
                } catch {
                    importFailure = error.localizedDescription
                }
            })
            run.width = outcome.width
            run.height = outcome.height
            run.frameCount = outcome.frameCount
            run.whiteLevel = outcome.whiteLevel
            run.output = outcome.output
            if let importFailure {
                run.failure = importFailure
                return run
            }
            guard let importedID else {
                run.failure = Loc.t("合成结果未能加入照片库")
                return run
            }
            run.assetID = importedID

            progress(Loc.t("加入堆叠…"))
            let summary = try catalog.makeHDRStack(resultAssetID: importedID,
                                                  participantIDs: participantIDs)
            run.stackTopID = summary?.topID
            run.stackCount = summary?.count ?? 0
            return run
        } catch {
            run.failure = (error as? HDRMergeService.Failure)?.description
                ?? error.localizedDescription
            return run
        }
    }

    /// Back on the main actor: publish the outcome, bump the projection, select the result.
    private func finishHDRMerge(_ run: HDRMergeRun, taskID: UUID) {
        isHDRMergeRunning = false
        hdrMergeParticipantIDs = []                  // 392 — no run, no participants; the card goes away
        hdrMergeCompletionCount += 1
        hdrMergeRanOffMain = run.ranOffMain
        lastHDRMergeError = run.failure
        lastHDRMergeReport = nil
        let succeeded = run.failure == nil && run.assetID != nil
        // 454 P2a — the task closes on every way out of the run. `finish` also fills `completed` to
        // `total` on success, so a successful merge reads `N/N` without a separate last advance.
        backgroundTasks.finish(id: taskID,
                               state: succeeded ? .finished : .failed,
                               failureCount: succeeded ? 0 : 1)
        guard succeeded, let assetID = run.assetID else {
            lastHDRMergeProgress = nil
            return
        }
        // A stack write is catalog metadata, not an edit: the same signal a rating uses, and ⌘Z never
        // walks it back.
        metadataWriteCount += 1
        lastMetadataAffectedRows = run.stackCount
        metadataRevision &+= 1
        lastStackError = nil
        lastStackAffectedRows = run.stackCount
        reload()
        // The result is 置顶, so it is the row the projection shows; select it and the user sees the
        // finished photo where the bracketed frames used to be.
        if assets.contains(where: { $0.id == assetID }) { selectOnly(assetID) }
        if let output = run.output {
            lastHDRMergeReport = HDRMergeReport(output: output, width: run.width, height: run.height,
                                                frameCount: run.frameCount, whiteLevel: run.whiteLevel,
                                                assetID: assetID, stackTopID: run.stackTopID ?? "",
                                                stackCount: run.stackCount)
        }
        lastHDRMergeProgress = Loc.t("合成完成：{0}×{1}，{2} 帧", String(describing: (run.width)), String(describing: (run.height)), String(describing: (run.frameCount)))
    }

    /// 454 P2a — `解码 1/3…` → `1`. `HDRMergeService` turns the tool's structured event into that
    /// one sentence, so the background-task store has to read the count back out of the line the HUD
    /// already shows. A line that does not match leaves the count where it was; `finish` still lands
    /// on `total` for a successful merge.
    nonisolated static func decodedFrameCount(fromProgress text: String) -> Int? {
        let prefix = Loc.t("解码 ")
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        let parts = rest.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let index = Int(String(parts[0]).trimmingCharacters(in: .whitespaces)),
              let total = Int(parts[1].prefix(while: { $0.isNumber })),
              total > 0
        else { return nil }
        return min(max(0, index), total)
    }

    // MARK: 模型降噪 (§386) — 右键菜单两个动词，不弹窗口    //
    // 和 §384 的 HDR 合成同一套口径：入口在右键菜单、点下去不弹窗、选择本身就是「处理哪张」。
    // 不同的是**只处理单张**，而且产物是「原图的降噪版」，所以完成后原图不消失 ——
    // 它成为新堆叠的第二张，产物置顶。
    //
    // §432 — 两条路并存：`模型降噪（Ansel）…`（GPL 权重，子进程）与 `模型降噪（Nonlocal）…`
    // （MIT 权重，进程内）。两者共用下面这一条产物/堆叠路径，只有 `DenoiseEngine` 决定的
    // 「哪一次 denoise 调用」不同；依赖检查则按引擎各自判，所以缺 ansel 工具时 Nonlocal 仍可点。
    //
    // 线程：一张 60 MP 是 1426 个 tile（step 208），GPU 上也要几十秒；解码 / 归一化 /
    // 写 DNG 同样是几十秒级的同步工作。整个 body 因此在 `denoiseQueue` 上跑，主线程只收结果。
    // `denoiseRanOffMain` 记录 worker 实际看到的值，测试断言的是这个，不是注释。

    /// 为什么上一次模型降噪没做成，中文原因。成功时为 nil。永远不弹窗。
    public private(set) var lastDenoiseError: String?

    /// 进度一行（`降噪 9536×6344，tile 256…`），成功后是结果摘要。没有全局 HUD（§2.5）。
    public private(set) var lastDenoiseProgress: String?

    /// 起了几次 / 完成了几次。测试等第二个数字，不靠 sleep。
    public private(set) var denoiseRunCount = 0
    public private(set) var denoiseCompletionCount = 0

    /// 524 — 上一次「一项完成就刷新」那次 `loadProjection()` 的实测秒数。
    /// 派单要求把这个成本量出来：若单次超过 16 ms 才考虑增量刷新。只读接缝，行为不被它影响。
    public private(set) var lastDenoiseItemReloadSeconds: TimeInterval = 0

    /// worker 进入阻塞体时看到的值。`nil` = 还没跑过；`false` 意味着跑在主线程（§3 ⑥ 要抓的 bug）。
    public private(set) var denoiseRanOffMain: Bool?

    /// 点了到结果之间为 true：第二次点击不许再起一个几十秒的任务。
    public private(set) var isDenoiseRunning = false

    /// §387 — **哪一张**正在降噪，`nil` = 没有。
    ///
    /// 386 只在后台闭包里拿着 `participantID`，session 上没有任何判据能回答「现在降的是哪张」，
    /// 所以「切到别的照片就看不到提示框」这条根本无从实现。写入点只有两个，
    /// 与 `isDenoiseRunning` 同一行：`denoiseSelection()` 里置成参与的那张，`finishDenoise(_:)`
    /// 里（成功与失败都走这里）置回 `nil`。只读，派生自当前这一次运行。
    public private(set) var denoiseAssetID: String?

    // MARK: - 510 · 请求队列（不是第二个执行器）

    /// 510 — 一次**降噪请求**。它只是「要做的事」，不含任何执行状态：真正干活的一直是那条
    /// 串行 `photons.denoise` 队列（`isDenoiseRunning` / `denoiseAssetID` / `denoiseBatch`）。
    ///
    /// 之所以要这一层：原来的门是**全局** `isDenoiseRunning`，一次降噪在跑，整个应用的
    /// 「模型降噪」对任何照片都灰。用户要的是「跑着的时候还能继续加」。队列记住加的那些，
    /// 执行仍然是并发度 1 —— 下一个请求只在**上一个请求的主 actor 收尾**里被派发。
    public struct DenoiseRequest: Sendable, Equatable {
        /// 单张 1 个；批量 ≥2。**入队时**就已经是「真正会跑的那些」，被跳过的照片不在里面 ——
        /// 所以队列里的每一张都是「点了就会降噪的那张」。
        public var assetIDs: [String]
        public var engine: DenoiseEngine
        public var id: UUID
        /// 这个请求在 `BackgroundTasks` 里的那一行。入队时就建好（`.queued` + `queuedAhead`），
        /// 轮到它时**同一行**变成进度条 —— 一个请求从头到尾只有一个行号。
        public var taskID: UUID

        public init(assetIDs: [String], engine: DenoiseEngine,
                    id: UUID = UUID(), taskID: UUID = UUID()) {
            self.assetIDs = assetIDs
            self.engine = engine
            self.id = id
            self.taskID = taskID
        }

        public var isBatch: Bool { assetIDs.count >= 2 }
    }

    /// FIFO。去重按 `assetID`：入队前已经查过 `denoiseBusyAssetIDs`，所以同一张照片永远不会
    /// 有两个排队请求。
    private var pendingDenoiseRequests: [DenoiseRequest] = []

    /// 队列里还有几个在等。**不含**正在执行的那一个 —— 那是 `denoiseAssetID`。
    public var denoiseQueueDepth: Int { pendingDenoiseRequests.count }

    /// 只读的排队项，顺序就是执行顺序。面板与测试读它，写入口只有 `enqueueDenoiseRequest`。
    public var pendingDenoiseRequestsSnapshot: [DenoiseRequest] { pendingDenoiseRequests }

    /// 510 — 入队时的那句 notice（「已加入降噪队列（前面还有 N 个）」）。直接开跑时为 nil。
    public private(set) var lastDenoiseQueueNotice: String?

    /// 510 — 批量里有多少张因为「已经在跑 / 已在队列」被跳过。与 `lastDenoiseBatchSkippedCount`
    /// 分开：一个是「不支持降噪」，一个是「已经在队列里」，用户要改的东西不一样。
    public private(set) var lastDenoiseQueueSkippedCount = 0

    /// 上一次成功的数字。失败时留 nil 并填 `lastDenoiseError`。
    public struct DenoiseReport: Sendable, Equatable {
        public let output: URL
        public let source: URL
        public let width: Int
        public let height: Int
        public let whiteLevel: Double
        public let cfa: String
        public let tiles: Int
        public let seconds: Double
        public let byteCount: Int
        public let assetID: String
        public let stackTopID: String
        public let stackCount: Int
    }

    public private(set) var lastDenoiseReport: DenoiseReport?

    /// §432 — 上一次跑的是哪条路，供 tooltip / 日志读。`nil` = 没跑过。
    public private(set) var lastDenoiseEngine: DenoiseEngine?

    /// §395 — 继承编辑那一步自己的失败原因，中文一句。`nil` = 没跑过或成功了。
    ///
    /// **与 `lastDenoiseError` 刻意分开**：继承失败时降噪本身是成功的 —— 文件在磁盘、已在库里、
    /// 已堆叠 —— 所以那一条不许写成 `run.failure`（`finishDenoise` 会因此认为整单失败，把报告
    /// 清掉、把堆叠的元数据信号也一起跳过）。这里只留一句「产物没有继承到原图的编辑」的原因，
    /// 供 tooltip / 日志读。成功一次就清空，与 `lastDenoiseError` 同一个生命周期。
    public private(set) var lastDenoiseInheritError: String?

    /// 512 — 继承**库属性**那一步自己的失败原因，中文一句。`nil` = 没跑过或成功了。
    ///
    /// 与 `lastDenoiseInheritError` 同一个形状、同一个理由：产物的星级/旗标/色标/关键词是
    /// 「这张照片是什么」，它没搬成功时文件已经在磁盘、已经入库、已经堆叠 —— 降噪本身是成功的。
    /// 所以这一条也**绝不**写成 `run.failure`，否则 `finishDenoise` 会把整单判失败、连报告一起清掉。
    public private(set) var lastDenoiseMetadataInheritError: String?

    /// 512 — 一次成功降噪后，产物**实际**继承到的库属性一行，供测试与用户核对：
    /// `继承库属性：★1 / 旗标 pick / 色标 red / 关键词 2 个`。
    ///
    /// 它是从库里**读回来**的，不是回调里记的计数 —— 所以「代码以为写了」与「用户看到的值」
    /// 不可能是两个数。失败路径留 `nil`（那时没有任何东西可报告）。
    public private(set) var lastDenoiseMetadataInheritSummary: String?

    /// 工具与模型在哪儿。Injectable：测试把它指向一个不存在的可执行文件或模型路径，
    /// 就能复现「菜单灰掉的三种原因」，不需要真装东西。
    public var denoiseLocation = AnselDenoiseLocation()

    /// NLMF 那条路的模型。Injectable，与 `denoiseLocation` 同一个用途：测试塞一条不存在的路径。
    ///
    /// 两条路**只有许可边界不同**：Ansel 的权重是 GPL-3.0，必须子进程；NLMF 的代码与权重都是
    /// MIT，所以是进程内的一个普通方法。因此这里**没有可执行文件**要定位，只有模型。
    public var nlmfModelURL: URL?

    /// 非局部匹配滤波那条路的模型在哪：显式 → `$PHOTONS_NLMF_MODEL` → 随包 `Resources/Models`
    /// → `~/Library/Application Support/Photons/models`（用户换变体，与 ansel 共用同一个目录）。
    /// 与 `AnselDenoiseLocation` 的四级同一个形状，只是第一级是这里的注入点。
    public var nlmfSearchedModelURLs: [URL] {
        if let nlmfModelURL { return [nlmfModelURL] }
        let variant = NLMFDenoiseJob.Variant.t256
        var out: [URL] = []
        if let env = ProcessInfo.processInfo.environment[NLMFDenoiseJob.environmentKey], !env.isEmpty {
            out.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath))
        }
        if let bundled = NLMFDenoiseJob.expectedModelPath(variant: variant) {
            out.append(bundled)
        }
        out.append(AnselDenoiseLocation.userModelDirectory()
            .appendingPathComponent(variant.rawValue))
        return out
    }

    /// 第一个真实存在的模型；`nil` = 这个入口今天不可用（菜单灰）。
    public var nlmfResolvedModelURL: URL? {
        nlmfSearchedModelURLs.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 它**只需要模型**：进程内调用没有工具要定位，这正是 MIT 那条路的好处。
    public var isNLMFDenoiseModelAvailable: Bool { nlmfResolvedModelURL != nil }

    /// 缺 NLMF 模型时 tooltip 要写的**完整期望路径**：显式路径，否则三个候选按查找顺序全列出来，
    /// 环境变量那一条在没设时也写出来（用户需要知道有这个旋钮才能用它）。
    public var nlmfDenoiseModelPathHint: String {
        if let nlmfModelURL { return nlmfModelURL.path }
        var parts: [String] = []
        if let env = ProcessInfo.processInfo.environment[NLMFDenoiseJob.environmentKey], !env.isEmpty {
            parts.append(URL(fileURLWithPath: (env as NSString).expandingTildeInPath).path)
        } else {
            parts.append("$" + NLMFDenoiseJob.environmentKey)
        }
        let variant = NLMFDenoiseJob.Variant.t256
        if let bundled = NLMFDenoiseJob.expectedModelPath(variant: variant) {
            parts.append(bundled.path)
        }
        parts.append(AnselDenoiseLocation.userModelDirectory()
            .appendingPathComponent(variant.rawValue).path)
        return parts.joined(separator: " / ")
    }

    /// 真正跑的那个 job。模型路径显式传进去，这样解析顺序只有上面一份。
    public var nlmfDenoiseJob: NLMFDenoiseJob {
        NLMFDenoiseJob(modelURL: nlmfResolvedModelURL)
    }

    /// 工具**真的在**：`AnselDenoiseClient` 会把一条不存在的显式路径原样收下，
    /// 所以这里问的是那个文件本身（与 `isHDRMergeAvailable` 同一条规矩）。
    public var isDenoiseToolAvailable: Bool {
        guard let client = denoiseLocation.client() else { return false }
        return FileManager.default.isExecutableFile(atPath: client.executableURL.path)
    }

    /// 模型在四级解析顺序里找到了没有。
    public var isDenoiseModelAvailable: Bool {
        denoiseLocation.resolvedModel() != nil
    }

    /// 缺模型时 tooltip 要写的完整期望路径。
    public var denoiseModelPathHint: String { denoiseLocation.modelPathHint() }

    /// 阻塞的那一半跑在这个队列上。Injectable，测试因此能不抢全局池。
    public var denoiseQueue = DispatchQueue(label: "photons.denoise", qos: .userInitiated)

    /// §432 — 进程内那条路的**推理**替身，`nil` = 真跑 Core ML。测试用它验证「产物/命名/堆叠」
    /// 这一段而不用等 ~90 s 的推理；命名与临时名/改名仍然是生产的 `NLMFDenoiseExecutor`。
    /// internal：它是模块内的接缝，不进公开 API。
    var nlmfDenoiseBody: NLMFDenoiseExecutor.Body?

    /// 512 — 继承库属性那一步的替身，`nil` = 真调 `catalog.copyLibraryMetadata`。与
    /// `nlmfDenoiseBody` 同一个用途：测试要能**注入一次必然失败的复制**，否则
    /// 「元数据失败不许拖垮降噪」这条只能靠读代码证明。internal：模块内的接缝，不进公开 API。
    var denoiseMetadataInheritBody: (@Sendable (Catalog, _ from: String, _ to: String) throws -> Int)?

    // MARK: 485 — edit-time clean + cache

    /// The edit-time cleaner. Created on `open()`; `nil` only before a library is open (or when the
    /// cache directory cannot be created, which the interactive entry reports like any other failure).
    public private(set) var denoiseCleaner: DenoiseCleaner?

    /// Read-only counters for `--ui-smoke` and tests (`cacheHits / computes / computesFailed /
    /// bytesWritten`). Mirrored on the main actor because the smoke reads them synchronously.
    public private(set) var denoiseStats = DenoiseCleanerStats()

    /// Injectable cache directory. Production is
    /// `~/Library/Application Support/Photons/denoise-v1/`; tests point this at their own temp tree
    /// so the user's cache is never touched.
    public var denoiseCacheDirectory: URL?

    /// Test seam for the cleaner's pixel computation (the real one runs CPU NLM over a 60 MP file).
    var denoiseComputeOverride: DenoiseCleaner.Compute?

    /// 485 — the built-in cleaner's identity. It is independent of the *edit*: the reducer cleans
    /// source pixels, so exposure/crop/masks must not move this key.
    public static let denoiseCleanerID = "builtin-nlm"
    public static let denoiseCleanerVersion = "builtin-nlm-v1"

    /// The DNG path feeds the cleaned CFA planes through the cell adapter; non-DNG files decode to
    /// a linear buffer and use the NLM backend's RGB adapter. Both end in `DenoiseLinearAdapter`,
    /// so the cache only ever holds linear RGBA. 480's menu/engine is gone; this is its only caller.
    nonisolated static func nlmFallbackCompute() -> DenoiseCleaner.Compute {
        { source, progress in
            if source.url.pathExtension.lowercased() == "dng" {
                let clean = try DenoiseNLMBackend.cleanDNG(input: source.url, progress: progress)
                return DenoiseLinearAdapter.linearImage(cfaPlanes: clean.planes,
                                                        width: clean.width / 2,
                                                        height: clean.height / 2,
                                                        cfa: clean.cfa)
            }
            let image = try RAWDecoder().decode(source.url, options: DecodeOptions())
            let n = image.width * image.height
            var rgb = [[Float]](repeating: [Float](repeating: 0, count: n), count: 3)
            for i in 0..<n {
                let base = i * 4
                rgb[0][i] = Float(image.rgba[base])
                rgb[1][i] = Float(image.rgba[base + 1])
                rgb[2][i] = Float(image.rgba[base + 2])
            }
            let cleaned = DenoiseNLMBackend.cleanRGB(rgb, width: image.width,
                                                     height: image.height, progress: progress)
            return DenoiseLinearAdapter.linearImage(fourPlanes: cleaned.planes,
                                                    width: image.width, height: image.height)
        }
    }

    nonisolated static func defaultDenoiseCacheDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Photons/denoise-v1", isDirectory: true)
    }

    /// Build the cleaner once per open. The resolver is the session's only job: asset id → the
    /// catalogue's content hash / size (asked on the main actor, never from the actor's worker).
    private func makeDenoiseCleaner() {
        let directory = denoiseCacheDirectory ?? Self.defaultDenoiseCacheDirectory()
        let compute = denoiseComputeOverride ?? Self.nlmFallbackCompute()
        denoiseCleaner = try? DenoiseCleaner(
            directory: directory,
            cleanerID: Self.denoiseCleanerID,
            cleanerVersion: Self.denoiseCleanerVersion,
            params: "amount=100;tile=256;overlap=16;anscombe=1;domain=cfa-or-rgb",
            resolver: { [weak self] assetID in
                guard let self else {
                    throw DenoiseCleanerFailure.sourceUnavailable(DenoiseNotices.noLibrary)
                }
                return try await MainActor.run { try self.resolveDenoiseSource(assetID: assetID) }
            },
            compute: compute)
    }

    private func resolveDenoiseSource(assetID: String) throws -> DenoiseSource {
        guard let asset = assets.first(where: { $0.id == assetID }) else {
            throw DenoiseCleanerFailure.sourceUnavailable(Loc.t("照片不在库里"))
        }
        guard let url = fileURL(for: asset) else {
            throw DenoiseCleanerFailure.sourceUnavailable(DenoiseNotices.onlyDNG(asset.filename))
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DenoiseCleanerFailure.sourceUnavailable(MissingMarkText.fileGone)
        }
        return DenoiseSource(assetID: asset.id, url: url, contentSHA256: asset.contentHash,
                             width: max(asset.width ?? 0, 1), height: max(asset.height ?? 0, 1))
    }

    /// 485 — the service door `P2`/`P3` will call. A cache hit costs one read; concurrent requests
    /// for the same photo join the running compute; a failure leaves no cache file behind.
    @discardableResult
    public func cleanDenoiseIfNeeded(assetID: String,
                                     progress: (@Sendable (String) -> Void)? = nil)
        async -> Result<LinearImage, DenoiseCleanerFailure> {
        guard let cleaner = denoiseCleaner else {
            return .failure(.sourceUnavailable(Loc.t("降噪缓存不可用")))
        }
        let result = await cleaner.cleanIfNeeded(assetID: assetID, progress: progress)
        denoiseStats = await cleaner.statsSnapshot()
        return result
    }

    /// 485 — fill the cache for several photos **serially** (one clean alive at a time). 480's batch
    /// menu row is gone; this is the service entry a future multi-select action calls. Returns the
    /// photos that failed, so a caller can report them without re-querying the cleaner.
    @discardableResult
    public func precomputeDenoiseCache(assetIDs: [String],
                                       progress: (@Sendable (String) -> Void)? = nil)
        async -> [String: DenoiseCleanerFailure] {
        var failures: [String: DenoiseCleanerFailure] = [:]
        for assetID in assetIDs {
            if case .failure(let error) = await cleanDenoiseIfNeeded(assetID: assetID,
                                                                    progress: progress) {
                failures[assetID] = error
            }
        }
        return failures
    }

    /// 对选中的**那一张**跑 Ansel 模型降噪（子进程，GPL 权重）。
    @discardableResult
    public func denoiseSelection() -> [String] {
        denoiseSelection(engine: .ansel)
    }

    /// 对选中的**那一张**跑非局部匹配滤波降噪（进程内，MIT 权重）。
    @discardableResult
    public func denoiseSelectionNlmf() -> [String] {
        denoiseSelection(engine: .nonlocal)
    }

    /// 对选中的**那一张**跑模型降噪：产物落在原图同目录，然后原图 + 产物组成一个新堆叠、
    /// **产物置顶**、选中产物。
    ///
    /// 两个入口共用这一条路径（§432）：选择检查、命名、落盘、入库、继承编辑、堆叠、选中，
    /// 只有「哪一次 `denoise` 调用」不同。差别来自许可边界而不是产品行为 —— Ansel 的权重是
    /// GPL-3.0 必须子进程，NLMF 的代码与权重都是 MIT 所以是进程内方法。
    ///
    /// **依赖检查按引擎分开**：Ansel 要工具 + 模型，NLMF 只要模型。这正是「两个入口的可用性
    /// 互不影响」的实现点；而「正在跑」是另一件事，由下面的 `isDenoiseRunning` 单独拦。
    ///
    /// 返回参与的原图 id（拒绝启动时为空数组），测试因此不用再读一遍选择。
    @discardableResult
    public func denoiseSelection(engine: DenoiseEngine) -> [String] {
        denoiseRunCount += 1
        lastDenoiseError = nil
        lastDenoiseProgress = nil
        lastDenoiseQueueNotice = nil
        denoiseRanOffMain = nil

        guard catalog != nil else {
            lastDenoiseError = DenoiseNotices.noLibrary
            return []
        }
        switch engine {
        case .ansel:
            guard isDenoiseToolAvailable else {
                lastDenoiseError = DenoiseNotices.anselToolMissing
                return []
            }
            guard isDenoiseModelAvailable else {
                lastDenoiseError = DenoiseNotices.anselModelMissing(denoiseModelPathHint)
                return []
            }
        case .nonlocal:
            // 进程内调用：没有可执行文件要定位，模型在就够。
            guard isNLMFDenoiseModelAvailable else {
                lastDenoiseError = DenoiseNotices.nlmfModelMissing(nlmfDenoiseModelPathHint)
                return []
            }
        }
        // 菜单已经拦过这几条；这里是第二次，因为一个过期的菜单行或键盘路径不该让任务白跑。
        let chosen = selectedAssets
        guard chosen.count == 1 else {
            lastDenoiseError = DenoiseNotices.singlePhotoOnly
            return []
        }
        let asset = chosen[0]
        guard asset.ext.lowercased() == "dng" else {
            lastDenoiseError = DenoiseNotices.onlyDNG(asset.filename)
            return []
        }
        guard fileURL(for: asset) != nil else {
            lastDenoiseError = DenoiseNotices.onlyDNG(asset.filename)
            return []
        }
        guard makeImportService() != nil else {
            lastDenoiseError = DenoiseNotices.noLibrary
            return []
        }

        // 510 — 只有「**这张照片自己**」在跑或在队列里才拒绝。「别的照片在跑」不再是理由：
        // 那种情况走下面同一条入队路径，notice 会说前面还有几个。
        if denoiseAssetIsRunning(asset.id) {
            lastDenoiseError = DenoiseNotices.runningThisPhoto
            return []
        }
        if denoiseAssetIsQueued(asset.id) {
            lastDenoiseError = DenoiseNotices.alreadyQueued
            return []
        }
        return enqueueDenoiseRequest(assetIDs: [asset.id], engine: engine)
    }
    // MARK: - 510 · 队列 → 一个执行器

    /// 入队（或在空闲时直接开跑）。单张与批量、第一次与排队**都走这一条**：并发度 1 与
    /// 「一个请求一行」因此只有一处实现。
    @discardableResult
    private func enqueueDenoiseRequest(assetIDs: [String], engine: DenoiseEngine) -> [String] {
        let ahead = pendingDenoiseRequests.count + (isDenoiseRunning ? 1 : 0)
        let taskID = beginDenoiseTaskRow(assetIDs: assetIDs, engine: engine, ahead: ahead)
        let request = DenoiseRequest(assetIDs: assetIDs, engine: engine, taskID: taskID)
        pendingDenoiseRequests.append(request)
        // 排队项的取消 = 从队列里拿掉它自己。轮到它执行时，这一句会在 launch 里被丢掉。
        backgroundTasks.registerCancel(id: taskID) { [weak self] in
            self?.dropQueuedDenoiseRequest(request.id)
        }
        if ahead > 0 {
            lastDenoiseQueueNotice = DenoiseNotices.queued(ahead)
        }
        pumpDenoiseQueue()
        return assetIDs
    }

    /// 入队时就建好面板那一行：`total` 是这次请求的张数（单张 1），`title` 与串行执行时
    /// 用到的一模一样，所以「排队中 → 进度条」是同一条行状态在变，不是换了一行。
    private func beginDenoiseTaskRow(assetIDs: [String], engine: DenoiseEngine, ahead: Int) -> UUID {
        let first = assets.first { $0.id == assetIDs.first }
        let title = assetIDs.count >= 2
            ? Loc.t("降噪 {0} 张（{1}）", String(describing: (assetIDs.count)), engine.displayName)
            : Loc.t("降噪 · {0}", first?.filename ?? "")
        let thumbKey = first.map { ThumbnailProvider.hdJPEGKey(for: $0).keyString }
        return backgroundTasks.begin(BackgroundTask(kind: .denoise,
                                                    title: title,
                                                    total: max(1, assetIDs.count),
                                                    currentAssetID: assetIDs.first,
                                                    currentThumbKey: thumbKey,
                                                    state: .queued,
                                                    queuedAhead: ahead))
    }

    /// 队列推进一步。**只有**主 actor 上、且 `isDenoiseRunning == false` 时才会派发 —— 这就是
    /// 「并发度恒为 1」的实现点：下一个请求只从上一个请求的收尾里进来，`photons.denoise`
    /// 队列永远只有一个块在跑。
    private func pumpDenoiseQueue() {
        guard !isDenoiseRunning else {
            refreshDenoiseQueueRows()
            return
        }
        while !pendingDenoiseRequests.isEmpty {
            let request = pendingDenoiseRequests.removeFirst()
            if startDenoiseRequest(request) {
                refreshDenoiseQueueRows()
                return
            }
            // 这个请求开不了（照片已不在库里）：行已经按失败关掉，接着看下一个。
        }
        isDenoiseRunning = false
        denoiseAssetID = nil
    }

    /// 真的开始一个请求。返回 false = 它没能起来（行已关掉），调用方接着看队头。
    @discardableResult
    private func startDenoiseRequest(_ request: DenoiseRequest) -> Bool {
        guard let catalog, let importService = makeImportService() else {
            lastDenoiseError = DenoiseNotices.noLibrary
            backgroundTasks.forgetCancel(id: request.taskID)
            backgroundTasks.finish(id: request.taskID, state: .failed, failureCount: 1)
            return false
        }
        let items = makeDenoiseItems(for: request.assetIDs)
        guard !items.isEmpty else {
            lastDenoiseError = DenoiseNotices.onlyDNG(request.assetIDs.first ?? "")
            backgroundTasks.forgetCancel(id: request.taskID)
            backgroundTasks.finish(id: request.taskID, state: .failed, failureCount: 1)
            return false
        }
        // 排队期间那个「取消排队」的把手必须消失：从这一刻起这一行归生产者管。
        backgroundTasks.forgetCancel(id: request.taskID)
        if items.count >= 2 {
            launchDenoiseBatch(items: items, engine: request.engine, taskID: request.taskID,
                               catalog: catalog, importService: importService)
        } else {
            launchSingleDenoise(item: items[0], engine: request.engine, taskID: request.taskID,
                                catalog: catalog, importService: importService)
        }
        return true
    }

    /// 一次请求的每一项：库里的那张、文件 URL、根、方形缩略图键。**开跑时**才解析，所以排队
    /// 期间库里换了东西也不会拿着过期的 URL 去跑。
    private func makeDenoiseItems(for assetIDs: [String]) -> [DenoiseBatchItem] {
        assetIDs.compactMap { id in
            guard let asset = assets.first(where: { $0.id == id }),
                  let url = fileURL(for: asset) else { return nil }
            return DenoiseBatchItem(assetID: asset.id,
                                    source: url,
                                    rootID: asset.sourceRootId,
                                    thumbKey: ThumbnailProvider.hdJPEGKey(for: asset).keyString)
        }
    }

    /// 单张请求开跑：451 的残留清扫、454 的那一条任务行、`photons.denoise` 上的那一个块。
    /// 与 386 的版本逐句一致，只有两处不同：任务行**入队时就建好**（这里只把它从 `.queued`
    /// 推到 `.running`），以及收尾时队列要接着走。
    private func launchSingleDenoise(item: DenoiseBatchItem, engine: DenoiseEngine, taskID: UUID,
                                     catalog: Catalog, importService: ImportService) {
        // 451 — 上一次被杀留下的 `.denoise-*.dng` 先清掉，同一个目录里的残留不会越积越多。
        // 只碰这个操作自己的前缀：同目录里可能正有一次 HDR 在写 `.hdrmerge-*.dng`。
        _ = InterruptedWorkSweep.removeLeftovers(in: item.source.deletingLastPathComponent(),
                                                 kinds: ["denoise"])
        let job = DenoiseRunner(engine: engine,
                                ansel: AnselDenoiseJob(location: denoiseLocation),
                                nonlocal: nlmfDenoiseJob,
                                nonlocalBody: nlmfDenoiseBody,
                                metadataInheritBody: denoiseMetadataInheritBody)
        let queue = denoiseQueue
        let participantID = item.assetID
        isDenoiseRunning = true
        denoiseAssetID = participantID
        lastDenoiseEngine = engine
        lastDenoiseProgress = Loc.t("准备降噪…")
        // 454 P2a — the row already exists (built at enqueue time); this only moves it from
        // `.queued` to `.running` and pins the photo it is working on.
        backgroundTasks.advance(id: taskID, completed: 0,
                                currentAssetID: participantID, currentThumbKey: item.thumbKey)
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in
                self?.lastDenoiseProgress = text
                self?.backgroundTasks.advance(id: taskID, currentAssetID: participantID)
            }
        }
        queue.async { [weak self] in
            let run = Self.runDenoise(job: job, importService: importService, catalog: catalog,
                                      source: item.source, participantID: participantID,
                                      rootID: item.rootID, progress: report)
            Task { @MainActor in self?.finishDenoise(run, taskID: taskID) }
        }
    }

    /// 批量请求开跑：474 的那台状态机，一件不少。取消只置 `cancelled`（当前项跑完就停），
    /// **队列本身不受影响**。
    private func launchDenoiseBatch(items: [DenoiseBatchItem], engine: DenoiseEngine, taskID: UUID,
                                    catalog: Catalog, importService: ImportService) {
        for directory in Set(items.map { $0.source.deletingLastPathComponent() }) {
            _ = InterruptedWorkSweep.removeLeftovers(in: directory, kinds: ["denoise"])
        }
        let job = DenoiseRunner(engine: engine,
                                ansel: AnselDenoiseJob(location: denoiseLocation),
                                nonlocal: nlmfDenoiseJob,
                                nonlocalBody: nlmfDenoiseBody,
                                // 512 (main) — the batch's items each inherit their own library
                                // metadata; the body is the same one the single path passes, so a
                                // batch product and a single product cannot diverge.
                                metadataInheritBody: denoiseMetadataInheritBody)
        backgroundTasks.advance(id: taskID, completed: 0,
                                currentAssetID: items[0].assetID,
                                currentThumbKey: items[0].thumbKey)
        backgroundTasks.registerCancel(id: taskID) { [weak self] in
            // Only a flag: the item already running is allowed to finish (§3 P4). 510 — the
            // requests **queued behind it** still run, so this is not a queue cancel.
            self?.denoiseBatch?.cancelled = true
        }
        denoiseBatch = DenoiseBatchState(taskID: taskID, engine: engine, job: job,
                                         catalog: catalog, importService: importService,
                                         items: items)
        startNextDenoiseBatchItem()
    }

    /// 队里每一行的「前面还剩几个」。正在跑的那个算 1 个 —— 所以队头读数是 1，不是 0。
    /// 「口径修正（覆盖 510 §④）」— 面板行现在只写「排队中」，这个数字只在队列簿记里保持正确
    /// （`setQueuedAhead` / 510 的断言仍在读它），不再出现在界面上。
    private func refreshDenoiseQueueRows() {
        let running = isDenoiseRunning ? 1 : 0
        for (index, request) in pendingDenoiseRequests.enumerated() {
            backgroundTasks.setQueuedAhead(id: request.taskID, index + running)
        }
    }

    /// 面板上「取消」一个**排队项**：只把它从队列里拿掉，正在跑的那个不受影响。
    private func dropQueuedDenoiseRequest(_ requestID: UUID) {
        guard let index = pendingDenoiseRequests.firstIndex(where: { $0.id == requestID }) else { return }
        let request = pendingDenoiseRequests.remove(at: index)
        backgroundTasks.finish(id: request.taskID, state: .cancelled)
        refreshDenoiseQueueRows()
    }

    /// 510 — 「清空队列」：只清 pending，**不动正在跑的那一个**。返回清掉了几个。
    @discardableResult
    public func clearDenoiseQueue() -> Int {
        let cleared = pendingDenoiseRequests
        guard !cleared.isEmpty else { return 0 }
        pendingDenoiseRequests.removeAll()
        for request in cleared {
            backgroundTasks.forgetCancel(id: request.taskID)
            backgroundTasks.finish(id: request.taskID, state: .cancelled)
        }
        lastDenoiseQueueNotice = DenoiseNotices.clearedQueue(cleared.count)
        return cleared.count
    }

    // MARK: - 474 · 批量降噪（一条任务，串行）

    /// One catalogue item of a batch: everything `runDenoise` needs, captured on the main actor so
    /// the background half never reads session state. `thumbKey` is the same square HD key the
    /// sidebar uses (`ThumbKey.hdJPEG`), stored as a string because `BackgroundTask` is a value type.
    private struct DenoiseBatchItem: Sendable {
        let assetID: String
        let source: URL
        let rootID: String
        let thumbKey: String
    }

    /// 474 — the batch's bookkeeping. Main actor only; `nextIndex` is the item that will start next,
    /// `completed` is the number that has finished (success **or** failure).
    private struct DenoiseBatchState {
        let taskID: UUID
        let engine: DenoiseEngine
        let job: DenoiseRunner
        let catalog: Catalog
        let importService: ImportService
        let items: [DenoiseBatchItem]
        var nextIndex = 0
        var completed = 0
        var failures = 0
        var successes = 0
        var cancelled = false
    }

    private var denoiseBatch: DenoiseBatchState?

    /// 479 — **read-only** view of the queue, for the loupe's 「等待降噪」 card. It reads the existing
    /// bookkeeping only; the batch driver (`startNextDenoiseBatchItem` / cancel semantics) is untouched.
    ///
    /// A cancelled batch has no queue any more: the one item already running is allowed to finish, but
    /// nothing after it will start, so those photos must not keep showing 「等待降噪」.
    ///
    /// 510 — the pending **requests** are part of this set too: a photo waiting behind another
    /// request is 「等待降噪」 for exactly the same reason as a photo waiting behind another item of
    /// one batch. This is also the set the menu's 「已在队列中」 uses.
    public var denoiseQueuedAssetIDs: Set<String> {
        var waiting: Set<String> = []
        if let batch = denoiseBatch, !batch.cancelled,
           batch.nextIndex < batch.items.count {
            waiting.formUnion(batch.items[batch.nextIndex...].map(\.assetID))
        }
        for request in pendingDenoiseRequests {
            waiting.formUnion(request.assetIDs)
        }
        return waiting
    }

    /// 510 — 忙的照片：正在跑的那张 + 批量里还没轮到的 + 队列里的。菜单、批量跳过与入队去重
    /// **共用**这一个集合，别处不许各写一份。
    public var denoiseBusyAssetIDs: Set<String> {
        var busy = denoiseQueuedAssetIDs
        if let running = denoiseAssetID { busy.insert(running) }
        return busy
    }

    /// 510 — 「这张自己在跑」。
    public func denoiseAssetIsRunning(_ assetID: String) -> Bool { denoiseAssetID == assetID }

    /// 510 — 「这张已在队列里等」（不含正在跑的那张；`denoiseBusyAssetIDs` 是两者的并集）。
    public func denoiseAssetIsQueued(_ assetID: String) -> Bool {
        denoiseQueuedAssetIDs.contains(assetID)
    }

    /// 479 — `true` while a batch exists that may still start more items (i.e. not cancelled and not
    /// finished). The running item is `denoiseAssetID`, which 387 already exposes.
    public var denoiseBatchIsActive: Bool {
        guard let batch = denoiseBatch else { return false }
        return !batch.cancelled
    }

    /// 474 — how many selected photos the last batch had to skip (not DNG / no file URL).
    public private(set) var lastDenoiseBatchSkippedCount = 0
    /// 474 — one sentence for the caller to show before the batch starts. `nil` = nothing skipped.
    public private(set) var lastDenoiseBatchSkipNotice: String?

    /// Run **one** background task over the selected photos, one at a time. The single-photo path
    /// (`denoiseSelection`) is untouched: this is only reachable when the caller selected ≥ 2 photos.
    ///
    /// - `beforeStart` is called synchronously **before** the first item starts, and only when some
    ///   selected photos were skipped. The menu uses it for the one-line alert; tests use it as the
    ///   seam instead of walking an `NSAlert`.
    /// - Cancellation follows P3's one-shot handle: the current item is allowed to finish, then no
    ///   new item starts and the task closes as `.cancelled`.
    /// - A failed item counts towards `failureCount` and the next item still runs.
    @discardableResult
    public func denoiseBatchSelection(engine: DenoiseEngine,
                                      beforeStart: ((String) -> Void)? = nil) -> [String] {
        denoiseRunCount += 1
        lastDenoiseError = nil
        lastDenoiseBatchSkippedCount = 0
        lastDenoiseBatchSkipNotice = nil
        lastDenoiseQueueSkippedCount = 0
        lastDenoiseQueueNotice = nil
        lastDenoiseProgress = nil
        denoiseRanOffMain = nil

        guard catalog != nil else {
            lastDenoiseError = DenoiseNotices.noLibrary
            return []
        }
        switch engine {
        case .ansel:
            guard isDenoiseToolAvailable else {
                lastDenoiseError = DenoiseNotices.anselToolMissing
                return []
            }
            guard isDenoiseModelAvailable else {
                lastDenoiseError = DenoiseNotices.anselModelMissing(denoiseModelPathHint)
                return []
            }
        case .nonlocal:
            guard isNLMFDenoiseModelAvailable else {
                lastDenoiseError = DenoiseNotices.nlmfModelMissing(nlmfDenoiseModelPathHint)
                return []
            }
        }

        let chosen = selectedAssets
        guard chosen.count >= 2 else {
            lastDenoiseError = DenoiseNotices.batchNeedsTwo
            return []
        }
        // Per-photo availability is the single-photo rule (`dng` + a file URL), applied one photo at
        // a time. Skipped photos are counted here and named to the user before the first item starts.
        //
        // 510 — a photo that is **already running or already queued** is skipped too, and counted
        // separately (`lastDenoiseQueueSkippedCount`): the menu promises 「将跳过 N 张已在队列中的
        // 照片」, which is a different sentence from 「不支持降噪」.
        var assetIDs: [String] = []
        var skipped: [String] = []
        var queuedSkips: [String] = []
        for asset in chosen {
            guard asset.ext.lowercased() == "dng", fileURL(for: asset) != nil else {
                skipped.append(asset.filename)
                continue
            }
            if denoiseAssetIsRunning(asset.id) || denoiseAssetIsQueued(asset.id) {
                queuedSkips.append(asset.filename)
                continue
            }
            assetIDs.append(asset.id)
        }
        lastDenoiseBatchSkippedCount = skipped.count
        lastDenoiseQueueSkippedCount = queuedSkips.count
        guard assetIDs.count >= 2 else {
            // 一张都没剩下、而且原因是「都已经在队列里」时，说的必须是那句话，不是「至少两张」。
            lastDenoiseError = queuedSkips.isEmpty ? DenoiseNotices.batchNeedsTwo
                                                   : DenoiseNotices.alreadyQueued
            emitDenoiseBatchSkipNotice(skipped: skipped, queued: queuedSkips,
                                       kept: assetIDs.count, beforeStart: beforeStart)
            return []
        }
        emitDenoiseBatchSkipNotice(skipped: skipped, queued: queuedSkips,
                                   kept: assetIDs.count, beforeStart: beforeStart)

        return enqueueDenoiseRequest(assetIDs: assetIDs, engine: engine)
    }

    /// 474/510 — the one line the menu shows before a batch starts. Two reasons, two sentences,
    /// joined into one message so the user still only dismisses one alert.
    private func emitDenoiseBatchSkipNotice(skipped: [String], queued: [String], kept: Int,
                                            beforeStart: ((String) -> Void)?) {
        var parts: [String] = []
        if !skipped.isEmpty {
            parts.append(DenoiseNotices.batchSkipped(skipped.count, kept: kept))
        }
        if !queued.isEmpty {
            parts.append(DenoiseNotices.batchQueueSkipped(queued.count, kept: kept))
        }
        guard !parts.isEmpty else { return }
        let notice = parts.joined(separator: " ")
        lastDenoiseBatchSkipNotice = notice
        beforeStart?(notice)
    }

    /// Start the next item. The queue is the existing serial `photons.denoise`; the next item is
    /// only dispatched from the previous item's main-actor completion, so two executors can never
    /// be alive at once (that is the acceptance's 「并发度 = 1」).
    private func startNextDenoiseBatchItem() {
        guard var batch = denoiseBatch else { return }
        guard !batch.cancelled, batch.nextIndex < batch.items.count else {
            finishDenoiseBatch()
            return
        }
        let itemIndex = batch.nextIndex
        let item = batch.items[itemIndex]
        batch.nextIndex += 1
        denoiseBatch = batch

        isDenoiseRunning = true
        denoiseAssetID = item.assetID
        lastDenoiseEngine = batch.engine
        lastDenoiseProgress = Loc.t("准备降噪…")
        backgroundTasks.advance(id: batch.taskID,
                                currentAssetID: item.assetID,
                                currentThumbKey: item.thumbKey)

        let taskID = batch.taskID
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in
                guard let self, self.denoiseBatch?.taskID == taskID else { return }
                self.lastDenoiseProgress = text
                self.backgroundTasks.advance(id: taskID, currentAssetID: item.assetID)
            }
        }
        let job = batch.job
        let importService = batch.importService
        let catalog = batch.catalog
        denoiseQueue.async { [weak self] in
            let run = Self.runDenoise(job: job, importService: importService, catalog: catalog,
                                      source: item.source, participantID: item.assetID,
                                      rootID: item.rootID, progress: report)
            Task { @MainActor in
                self?.finishDenoiseBatchItem(run, itemIndex: itemIndex, taskID: taskID)
            }
        }
    }

    /// One item is done. Book-keeping is the single path's, minus stopping `isDenoiseRunning`.
    ///
    /// 524 — a successful item refreshes the library **now**, so its new stack is on screen while
    /// the rest of the batch keeps running (the user's ask: 「完成一张堆叠一张」). The refresh is
    /// `reloadKeepingSelection`, not `selectOnly` of the product: with 40 photos, putting each
    /// intermediate product in front would fight the user's own selection 40 times (529).
    private func finishDenoiseBatchItem(_ run: DenoiseRun, itemIndex: Int, taskID: UUID) {
        guard var batch = denoiseBatch, batch.taskID == taskID,
              itemIndex == batch.completed, itemIndex < batch.nextIndex else { return }
        let succeeded = run.failure == nil && run.assetID != nil

        batch.completed += 1
        if succeeded { batch.successes += 1 } else { batch.failures += 1 }
        denoiseBatch = batch

        denoiseCompletionCount += 1
        denoiseRanOffMain = run.ranOffMain
        lastDenoiseError = run.failure
        lastDenoiseInheritError = run.inheritFailure
        // 512 — 库属性那一步是同一种附注：单独一行，不影响 `lastDenoiseError` / 报告的有无。
        lastDenoiseMetadataInheritError = run.metadataInheritFailure
        lastDenoiseMetadataInheritSummary = run.failure == nil
            ? metadataInheritSummary(forAsset: run.assetID) : nil
        lastDenoiseReport = nil
        if succeeded, let assetID = run.assetID {
            metadataWriteCount += 1
            lastMetadataAffectedRows = run.stackCount
            metadataRevision &+= 1
            lastStackError = nil
            lastStackAffectedRows = run.stackCount
            if let output = run.output {
                lastDenoiseReport = DenoiseReport(output: output,
                                                  source: run.source ?? output,
                                                  width: run.width, height: run.height,
                                                  whiteLevel: run.whiteLevel, cfa: run.cfa,
                                                  tiles: run.tiles, seconds: run.seconds,
                                                  byteCount: run.byteCount,
                                                  assetID: assetID, stackTopID: run.stackTopID ?? "",
                                                  stackCount: run.stackCount)
            }
            lastDenoiseProgress = Loc.t("降噪完成：{0}×{1}，{2} 个 tile", String(describing: (run.width)), String(describing: (run.height)), String(describing: (run.tiles)))
        } else {
            lastDenoiseProgress = nil
        }
        backgroundTasks.advance(id: taskID, completed: batch.completed)

        // 524 — 每张完成就刷新一次投影：堆叠已在后台那一半建好，这里只让它立刻可见。
        // 选择/锚点/范围基点由这次刷新原样放回，绝不选产物（529）。
        if succeeded { reloadKeepingSelection() }

        if batch.cancelled {
            // The item that was running when 取消 arrived has just been consumed; no new item starts.
            finishDenoiseBatch()
        } else {
            startNextDenoiseBatchItem()
        }
    }

    private func finishDenoiseBatch() {
        guard let batch = denoiseBatch else { return }
        denoiseBatch = nil
        isDenoiseRunning = false
        denoiseAssetID = nil
        backgroundTasks.forgetCancel(id: batch.taskID)
        // 527 — the square stays on the last photo the batch worked on (成功或失败都算) instead of
        // disappearing when the row closes. A cancelled batch keeps the item that was running when
        // 取消 arrived: `startNextDenoiseBatchItem` already pinned it, and no later item starts.
        // Only a normal completion needs a final write, so the last item is pinned even if a
        // progress report never landed; when the last item has no key (theoretical edge), the
        // previous pinned photo stays.
        if !batch.cancelled,
           let last = batch.items.last(where: { !$0.thumbKey.isEmpty }) {
            backgroundTasks.advance(id: batch.taskID,
                                    currentAssetID: last.assetID,
                                    currentThumbKey: last.thumbKey)
        }
        if batch.cancelled {
            backgroundTasks.finish(id: batch.taskID, state: .cancelled,
                                   failureCount: batch.failures)
        } else {
            backgroundTasks.finish(id: batch.taskID,
                                   state: batch.successes > 0 ? .finished : .failed,
                                   failureCount: batch.failures)
        }
        // 524 — no closing reload and no `selectOnly(last)`: every successful item already refreshed
        // the projection when it finished, and the batch must not move the user's selection (529).
        // 510 — the batch's row is closed; whoever is waiting behind it starts now.
        pumpDenoiseQueue()
    }

    /// 一次降噪的产物。纯 `Sendable` 盒子，后台那一半永远不碰 session。
    private struct DenoiseRun: Sendable {
        var ranOffMain = false
        var failure: String?
        var output: URL?
        var source: URL?
        var assetID: String?
        var width = 0
        var height = 0
        var whiteLevel: Double = 0
        var cfa = ""
        var tiles = 0
        var seconds: Double = 0
        var byteCount = 0
        var stackTopID: String?
        var stackCount = 0
        /// §395 — 继承编辑那一步的失败原因。**不进 `failure`**：降噪成功了，产物不该被判失败。
        var inheritFailure: String?
        /// 512 — 继承库属性那一步的失败原因。与 `inheritFailure` 同一个理由：它只是附注。
        var metadataInheritFailure: String?
    }

    /// §395 / §396 — 那唯一一条「产物带着原图编辑」历史行的 label。
    ///
    /// 396 之后它同时**包住三项覆写**（首选解码器版本、两根降噪归零），因为整件事是一个 payload
    /// 一次 `appendDevelop`。改这个名字等于改两单的验收（395 的 ④ 与 396 的 ⑥ 都按字符串断言），
    /// 所以 396 沿用它而不是新起一条 —— 用户看到的是「产物的编辑 = 原图编辑 + 三项调整」一个步骤。
    nonisolated static let denoiseInheritLabel = Loc.t("模型降噪：继承编辑")

    /// §554 — 这个产物文件应该自动选哪个解码器拼写。
    ///
    /// 顺序是用户口径 `9 > 9.dng > 8 > 8.dng > 其他`，并且**赋值后回读**：Apple 对文件不认的
    /// 拼写是静默忽略的（`DecoderCapabilities` 头注释），所以「写进去」不等于「生效」。
    /// `DecoderVersionPreference` 是唯一的选择逻辑，395/396 的继承段只调用它，不再自己挑版本。
    ///
    /// 读不出来（不是 RAW、文件坏了、`CIRAWFilter` 为 nil）时 `selected == nil`，调用方因此
    /// 不覆写继承来的值；这个加分项也绝不会把降噪判失败。
    nonisolated static func preferredDecoderVersion(at url: URL) -> String? {
        let resolution = DecoderVersionPreference.resolve(for: url)
        // 「首选 X 被回读成 Y」/「全部改写」必须留下读数，否则线上只能看到最后写了什么。
        for note in resolution.notes {
            NSLog("photons: 解码器版本 %@（%@）", note, url.lastPathComponent)
        }
        return resolution.selected
    }

    /// 阻塞的那一半。**不在主线程**（由 `ranOffMain` 断言）。
    ///
    /// 顺序就是契约：降噪 → 加进库 → 抽离旧堆叠 + 组新堆叠。产物写在源目录，
    /// 所以走 `mode: .reference` + 原图的 `sourceRootId`（与 §384 一致）。
    ///
    /// §432 — `job` 是一个 `DenoiseRunner`，两个引擎在这里**完全同形**：它只回答「调用哪一次
    /// denoise」，返回同一个 `DenoiseOutcome`；下面每一行（命名已由 executor 决定、入库、
    /// 继承编辑、`makeStack(产物, [原图])`、选中产物）都是共用的。
    private nonisolated static func runDenoise(job: DenoiseRunner,
                                               importService: ImportService,
                                               catalog: Catalog,
                                               source: URL,
                                               participantID: String,
                                               rootID: String,
                                               progress: @escaping @Sendable (String) -> Void) -> DenoiseRun {
        var run = DenoiseRun()
        run.ranOffMain = !Thread.isMainThread
        do {
            let outcome = try job.execute(source: source, progress: progress)
            run.output = outcome.output
            run.source = source
            run.width = outcome.width
            run.height = outcome.height
            run.cfa = outcome.cfa
            run.tiles = outcome.tiles
            run.seconds = outcome.seconds
            run.byteCount = outcome.byteCount

            progress(Loc.t("加入照片库…"))
            // `ImportService` 按内容哈希去重，重跑不会造出第二行。
            let summary = try importService.run(sources: [outcome.output],
                                               options: ImportOptions(mode: .reference,
                                                                      rootID: rootID,
                                                                      recursive: false))
            guard let importedID = summary.addedAssetIDs.first else {
                run.failure = Loc.t("降噪结果已经在库里（内容相同），没有新建照片")
                return run
            }
            run.assetID = importedID

            // 512 — **库属性**（星级 / 旗标 / 色标 / 关键词 / 拍摄时间）与 §395 的编辑是两件事：
            // 「这张照片是什么」先搬，「怎么处理」后搬。`ImportService` 按内容哈希新建一行，
            // `assets` 的默认值就是 ★0 / 无旗标 / 无色标 / 零关键词 —— 1 星的原图降噪后变 0 星
            // 就是这一步缺了的后果。
            //
            // 与 §395 同一条失败纪律：**绝不**设 `run.failure`。降噪已经成功（文件在磁盘、已入库），
            // 元数据没搬成只是产物少了几项标签，不该让整单变红、把报告与堆叠一起丢掉。
            // `participantID` 是**这一项**原图的 id —— 批量的每一项都从它自己那一张继承。
            progress(Loc.t("继承库属性…"))
            do {
                if let body = job.metadataInheritBody {
                    try body(catalog, participantID, importedID)
                } else {
                    try catalog.copyLibraryMetadata(fromAsset: participantID, toAsset: importedID)
                }
            } catch {
                run.metadataInheritFailure = error.localizedDescription
            }

            // §395 — 产物继承原图的**全部**编辑。用现成的那一对：`copySettings` 取快照、
            // `pasteSettings` 合并写入（不经 `sections:` ⇒ 全量；它只写 payload 带的字段，且
            // 里面走 `appendDevelop`，所以整件事是**一个** undo 步骤；蒙版是追加不是替换）。
            //
            // §396 — **继承与覆写一次写完**，仍然只是一个 undo 步骤。§2.3 的推荐做法是「在
            // `inherited` 快照上改完再 `pasteSettings`」，但 `EditSnapshot` 不携带
            // `detailSettings`（它是 042 的四个解码轴，不在剪贴板里 —— 395 的
            // `testTheClipboardsBoundaryIsTheKnownGap` 把这条缺口钉住了），所以走不了
            // `pasteSettings`。这里用它的两步等价展开：`snapshot.applied(to:)` 就是
            // `pasteSettings` 内部的那一次合并（同一个方法、同样的 `destinationAspect = nil`），
            // 然后 `appendDevelop` 落一条历史行。因此行为与 395 逐字段相同，只多了下面三项。
            //
            // 失败**不许**拖垮降噪：这段只是「产物带着原图的编辑」的加分项，降噪本身已经成功
            // （文件在磁盘、已入库）。所以 catch 只记 `inheritFailure`，绝不设 `run.failure`
            // —— 后者会让 `finishDenoise` 判整单失败、清掉报告。`participantID` 就是原图的 id。
            progress(Loc.t("继承编辑…"))
            do {
                let inherited = try catalog.copySettings(fromAsset: participantID)
                let sourceDocument = try catalog.develop(forAsset: participantID)
                let current = try catalog.develop(forAsset: importedID)
                var payload = inherited.applied(to: current)

                // 528 — 引导线不进 `EditSnapshot`（那是「复制设置」的剪贴板契约，395 的
                // `testTheClipboardsBoundaryIsTheKnownGap` 钉着这条边界），但产物是同一个栈里
                // 的另一份文件、同一份文档：原图有的引导线必须原样跟过来。所以在这里单独补写
                // 一次，仍然和上面的继承共用**同一次** `appendDevelop`（一条历史、一个 undo 步骤）。
                payload.geometry.guideLines = sourceDocument.geometry.guideLines

                // 554 — 产物默认走首选解码器版本：`9` → `9.dng` → `8` → `8.dng` → 其他
                // （用户的取舍：新解码器下让模型降噪的结果不被二次处理）。选择逻辑只有
                // `DecoderVersionPreference` 一处，并且**赋值后回读**：文件不认的拼写会被
                // Apple 静默忽略，回读不一致就换下一个候选；全部改写时回答 nil，这里保留
                // 继承来的值（= 源图怎么解码，产物就怎么解码），绝不硬写、也不把降噪判失败。
                if let version = Self.preferredDecoderVersion(at: outcome.output) {
                    payload.decoderVersion = version
                }

                // 396 C — 降噪归零。v9 下 `colorNR` 是无效写（`DecoderCapabilities.swift:17`：
                // v9 让 chroma NR / detail / moiré 三根滑杆变 no-op），但产物**可能被切回 v8
                // 打开**（解码器是用户能选的），那时 `colorNR = 0` 仍然是「不要二次降噪」的正确
                // 表达 —— 所以两根都写，代价是 v9 下这一行不改变像素。
                payload.detailSettings.luminanceNR = 0
                payload.detailSettings.colorNR = 0

                try catalog.appendDevelop(payload, label: Self.denoiseInheritLabel,
                                          forAsset: importedID)

                // 528 — 用户口径：「xml 中要有引导线位置的记录」。`DNGRawWriter` 先把源文件的
                // tag 700（XMP）原样复制到产物里（`DNGRawWriter.write` 的 preserved 列表），
                // 所以顺序是：**先**抄源 XMP，**后**在这里把继承后的文档合并进去。
                // `DNGXMP.writeDocument` 只替换 `photons:document` 这一个属性，源文件里别的
                // `crs:*` 字节不动；没有引导线时**不写**，也不写空数组 —— 产物文件保持降噪器
                // 写出的样子（tag 700 逐字节不变，文件不因为这一步增长）。
                if !payload.geometry.guideLines.isEmpty {
                    let text = try Catalog.encode(payload)
                    let existing = (try? DNGXMP.documentString(at: outcome.output)) ?? nil
                    if existing != text {
                        try DNGXMP.writeDocument(text, to: outcome.output)
                    }
                }
            } catch {
                run.inheritFailure = error.localizedDescription
            }

            progress(Loc.t("组成堆叠…"))
            let summary2 = try catalog.makeStack(resultAssetID: importedID,
                                                 participantIDs: [participantID])
            run.stackTopID = summary2?.topID
            run.stackCount = summary2?.count ?? 0
            return run
        } catch {
            run.failure = Self.denoiseFailureMessage(error)
            return run
        }
    }

    /// 两条路的错误都翻成一句中文。进程内那条有两个来源：`NLMFDenoiseJobError`（我们自己抛的，
    /// 已经是中文）与库的 `NLMFDenoiseFailure`（`code: message`，落到 `localizedDescription`，
    /// 与 Ansel 的 `tool_failed` 之外的情形同一条兜底）。
    nonisolated static func denoiseFailureMessage(_ error: Error) -> String {
        if let ansel = error as? AnselDenoiseJobError { return ansel.description }
        if let nlmf = error as? NLMFDenoiseJobError { return nlmf.description }
        return error.localizedDescription
    }

    /// 512 — 产物**实际**继承到的库属性，一行读回库里（不是回调里记的计数）：星级、旗标、色标、
    /// 关键词个数。`finishDenoise` 的两条收尾路径都写它，日志与测试读同一个字符串。
    private func metadataInheritSummary(forAsset id: String?) -> String? {
        guard let id, let catalog, let asset = try? catalog.asset(id: id) else { return nil }
        let keywords = (try? catalog.keywords(assetId: id)) ?? []
        return Loc.t("继承库属性：★{0} / 旗标 {1} / 色标 {2} / 关键词 {3} 个",
                     String(describing: (asset.rating)),
                     asset.flag ?? Loc.t("无"),
                     asset.colorLabel ?? Loc.t("无"),
                     String(describing: (keywords.count)))
    }

    /// 回到主 actor：发布结果、推进投影、选中产物。
    private func finishDenoise(_ run: DenoiseRun, taskID: UUID) {
        isDenoiseRunning = false
        // §387 — one line beside the flag it belongs to: the success path, the failure path and the
        // "already in the library" path all land here, so the box cannot outlive the run.
        denoiseAssetID = nil
        denoiseCompletionCount += 1
        denoiseRanOffMain = run.ranOffMain
        lastDenoiseError = run.failure
        // §395 — 继承失败是**降噪成功**的附注：它单独一行，不影响 `lastDenoiseError` / 报告的有无。
        lastDenoiseInheritError = run.inheritFailure
        // 512 — 库属性那一步是同一种附注：单独一行，不影响 `lastDenoiseError` / 报告的有无。
        lastDenoiseMetadataInheritError = run.metadataInheritFailure
        lastDenoiseMetadataInheritSummary = run.failure == nil
            ? metadataInheritSummary(forAsset: run.assetID) : nil
        lastDenoiseReport = nil
        let succeeded = run.failure == nil && run.assetID != nil
        // 454 P2a — task closes on success and every failure return inside `runDenoise`. Success
        // fills `completed` to the single item's total here, which is why the progress callback only
        // refreshes `currentAssetID`.
        backgroundTasks.finish(id: taskID,
                               state: succeeded ? .finished : .failed,
                               failureCount: succeeded ? 0 : 1)
        guard succeeded, let assetID = run.assetID else {
            lastDenoiseProgress = nil
            // 510 — a failed request must not stall the queue behind it.
            pumpDenoiseQueue()
            return
        }
        // 堆叠是库元数据，不是编辑：和评分用同一个信号，⌘Z 不会走回去。
        metadataWriteCount += 1
        lastMetadataAffectedRows = run.stackCount
        metadataRevision &+= 1
        lastStackError = nil
        lastStackAffectedRows = run.stackCount
        // 524 — 原图变成堆叠成员、格子上画的是产物（顶点）。用户选中的 id 是**原图**，所以要让
        // 选择跟着它现在代表的那一格走：把这条堆叠的全部成员都映射到顶点。没有堆叠时
        // （`stackTopID` 为 nil）产物自己就是那一行。选择不空时由 helper 原样放回，空选择才走
        // reload 的兜底。不许跳到别的照片，也不许切模式 / 激活窗口。
        var topByID: [String: String] = [assetID: run.stackTopID ?? assetID]
        if let top = run.stackTopID, let catalog,
           let stackID = (try? catalog.stackID(ofAsset: top)) ?? nil,
           let members = try? catalog.stackMembers(stackID: stackID) {
            for member in members { topByID[member.id] = top }
        }
        reloadKeepingSelection(topByID: topByID)
        if let output = run.output {
            lastDenoiseReport = DenoiseReport(output: output,
                                              source: run.source ?? output,
                                              width: run.width, height: run.height,
                                              whiteLevel: run.whiteLevel, cfa: run.cfa,
                                              tiles: run.tiles, seconds: run.seconds,
                                              byteCount: run.byteCount,
                                              assetID: assetID, stackTopID: run.stackTopID ?? "",
                                              stackCount: run.stackCount)
        }
        lastDenoiseProgress = Loc.t("降噪完成：{0}×{1}，{2} 个 tile", String(describing: (run.width)), String(describing: (run.height)), String(describing: (run.tiles)))
        // 510 — this request is over; the head of the queue starts here (and only here).
        pumpDenoiseQueue()
    }

    /// The `stacksByTopID` half of the projection, computed from the rows the query just returned.
    ///
    /// Only stack ids present in `visible` are asked for, so a filter that hides every member of a
    /// stack costs nothing. A stack whose top is missing from the query (a soft-deleted top, a row
    /// whose rank was moved) contributes no entry at all: the dictionary is keyed by top, and the
    /// contract is 「no entry = draw no indicator」.
    static func stacksByTop(_ visible: [Asset], catalog: Catalog)
        -> (byTop: [String: StackSummary], missingTopIDs: Set<String>) {
        let stackIDs = Set(visible.compactMap(\.stackId))
        guard !stackIDs.isEmpty else { return ([:], []) }
        guard let members = try? catalog.stackMembers(stackIDs: Array(stackIDs)) else {
            return ([:], [])
        }
        let kinds = (try? catalog.stackKinds(stackIDs: Array(stackIDs))) ?? [:]
        var out: [String: StackSummary] = [:]
        var missingTopIDs: Set<String> = []
        for (id, rows) in members {
            guard let top = rows.first(where: { $0.stackRank == 0 }) else { continue }
            guard visible.contains(where: { $0.id == top.id }) else { continue }
            out[top.id] = StackSummary(id: id, memberIDs: rows.map(\.id), topID: top.id,
                                       kind: kinds[id] ?? .plain)
            // 463: a missing **member** is just as real as a missing top, but only the top is drawn.
            // The row then says 「这一叠里有文件不在了」 instead of showing nothing.
            if rows.contains(where: \.isMissing) { missingTopIDs.insert(top.id) }
        }
        return (out, missingTopIDs)
    }

    // MARK: sort order (view state: one value, three views)

    /// Switch the order the three browsers read the library in, and remember the choice.
    ///
    /// No query and no decode: the array is re-sorted **in place from what is already loaded**, so a
    /// toggle costs one `sorted` and one `reloadData` per view — the thumbnails come back out of the
    /// shared memory cache (`ThumbnailProvider.serveFromMemory`), which is why the pixel hash, the
    /// document and the undo stack all read the same afterwards. Bumping `sortOrder` is also the
    /// one signal the views observe (`ObservationBridge`), so the grid, the left browser and the
    /// filmstrip refresh from this one write.
    public func setSortOrder(_ order: PhotoSortOrder) {
        guard order != sortOrder else { return }
        sortOrder = order
        assets = order.sorted(assets)
        PhotoSortPreferences.remember(order, in: sortPreferenceStore)
    }

    /// What the sort button does: `新→旧 ⇄ 旧→新`.
    public func toggleSortOrder() { setSortOrder(sortOrder.toggled) }

    // MARK: selection

    /// The folder rows the source tree has highlighted (021 B), in the order the user added them.
    ///
    /// Empty means no folder constraint — the whole library — and that is also how 「全部照片」 is
    /// stored: it is the *absence* of a constraint, not a clause. The old model was one
    /// `selectedRootID` + one `selectedFolderPath`, which could only ever name a single root's single
    /// subtree; ⌘-multi-select needs a set, and a set that spans roots.
    ///
    /// Normalised on the way in (`normalizedFolders`): 「全部照片」 collapses the whole set, duplicate
    /// rows collapse to one, and paths are canonicalised — so `reload()` compares like with like and
    /// a ⌘-click that changes nothing does not re-run the query.
    public private(set) var selectedFolders: [FolderSelection] = []

    /// `nil` = all photos. Read-only convenience for the single-selection case (the tree's own
    /// probes and the 020-era tests read it); with a multi-selection it is `nil`, because there is
    /// no single root to name — `selectedFolders` is the truth.
    public var selectedRootID: String? {
        guard selectedFolders.count == 1 else { return nil }
        return selectedFolders[0].rootId
    }

    /// A folder inside `selectedRootID`, relative to it and `/`-separated; `""` = the whole root.
    /// Same single-selection caveat as `selectedRootID`, and `""` whenever the set is empty (the
    /// whole library) so the old "全部照片 sets the path to empty" assertion still means what it says.
    public var selectedFolderPath: String {
        guard selectedFolders.count == 1 else { return "" }
        return selectedFolders[0].normalizedPath ?? ""
    }

    /// Per-root folder trees, filled by `reload()` from one `folderIndex()` scan. The browser draws
    /// its rows and reads its counts from here — never from `stats.byRoot`, which keys on the
    /// display name and therefore cannot tell two folders of the same name apart.
    public private(set) var folderNodes: [String: [FolderNode]] = [:]

    /// 相册（078 B10）。`reload()` 从 `Catalog.albums()` 填，每行带成员数；左栏那一列的数字、
    /// 「这一行点开有几张」和命令行 `library albums` 是同一份数据，不是三份各自算的。
    public private(set) var albums: [AlbumSummary] = []

    /// 当前打开的相册，`nil` = 不在任何相册里。与 `selectedFolders` 互斥（见 `selectFolders`）：
    /// 左栏只有一个「范围」高亮，网格只有一个范围。
    public private(set) var selectedAlbumID: String?

    /// 相册集合或成员数每变一次 +1 —— 与 `metadataRevision` 同一套用法：视图观察这个数，不去 diff
    /// 整个数组。**不进文档、不进历史**：相册是库属性，`editRevision` 不会为它动。
    public private(set) var albumRevision = 0

    public func selectRoot(_ id: String?) {
        selectFolder(rootID: id, path: "")
    }

    /// One click in the folder tree: root + subtree prefix, one reload.
    public func selectFolder(rootID: String?, path: String) {        selectFolders([FolderSelection(rootId: rootID, path: path)])
    }

    /// The whole selection at once — what a ⌘-click, a ⇧-range or a "clicked the empty area" hands
    /// over. One reload per gesture, never one per row.
    public func selectFolders(_ folders: [FolderSelection]) {
        let normalized = Self.normalizedFolders(folders)
        // 相册与文件夹是同一个问题的两个入口（「现在在看什么范围」）。点任意文件夹行 —— 包括
        // 「全部照片」—— 就意味着离开相册，即使文件夹集合本来就是空的：那一下点击的语义是
        // 「回到全库」，不是「什么都不做」。所以 `selectedAlbumID` 也参与这个 guard。
        guard normalized != selectedFolders || selectedAlbumID != nil else { return }
        selectedFolders = normalized
        selectedAlbumID = nil
        reload()
    }

    /// Canonical form of a selection, so the tree, the query and the highlight all agree.
    ///
    /// * 「全部照片」 (`rootId == nil`) means the whole library → the selection collapses to empty; the
    ///   other rows are ignored rather than ORed with everything (021 §B, last row of the table).
    /// * duplicates collapse (`Hashable` on `(rootId, path)`, paths canonicalised) — two highlights on
    ///   one row are not two clauses.
    /// * `day2` + `day2/sub` is left **as is**: the union is `day2`'s subtree by arithmetic, the SQL
    ///   OR returns each row once, and both rows stay highlighted because the user selected both.
    public static func normalizedFolders(_ folders: [FolderSelection]) -> [FolderSelection] {
        if folders.contains(where: { $0.isAllPhotos }) { return [] }
        var seen = Set<FolderSelection>()
        var out: [FolderSelection] = []
        for folder in folders {
            guard let root = folder.rootId else { continue }
            let canonical = FolderSelection(rootId: root, path: folder.normalizedPath)
            if seen.insert(canonical).inserted { out.append(canonical) }
        }
        return out
    }

    /// The folders of one root. Always contains the `""` node (the root itself) when it holds a photo,
    /// which is where the root row's count comes from.
    public func folderNodes(forRoot id: String) -> [FolderNode] { folderNodes[id] ?? [] }

    /// Photos per root — read from the same tree the rows are drawn from, so a count can never
    /// disagree with what expanding the row reveals.
    public var photoCountByRoot: [String: Int] {
        var out: [String: Int] = [:]
        for (id, nodes) in folderNodes { out[id] = nodes.first { $0.path.isEmpty }?.total ?? 0 }
        return out
    }

    // MARK: albums (078 B10) — 库属性，不是文档属性
    //
    // 这一段里没有一个函数碰 `edit` / `history` / `develop_json`：相册成员是「谁和谁放在一起看」，
    // 不是「这张照片长什么样」。所以 ⌘Z 不会撤一次「加入相册」，`editRevision` 也不会动一下
    // （`AlbumCRUDTests.testAlbumWritesNeverTouchTheDocument` 把这条钉成断言）。

    /// 点左栏的相册行：一个范围，一次查询。
    ///
    /// 与文件夹互斥是**设计**而不是限制：左栏是「现在看什么」的唯一入口，两个高亮意味着两个
    /// 不同的范围同时生效，而网格只能画一个结果 —— 那种不一致正是 078 B10 要消掉的东西。
    /// 筛选条（026 的槽位）不受影响：范围是 AND 的一边，挑选是另一边。
    public func selectAlbum(_ id: String?) {
        guard id != selectedAlbumID else { return }
        selectedAlbumID = id
        if id != nil { selectedFolders = [] }
        reload()
    }

    @discardableResult
    public func createAlbum(named name: String) throws -> AlbumSummary {
        guard let catalog else { throw AlbumError.noLibrary }
        let album = try catalog.createAlbum(named: name)
        try refreshAlbums()
        return albums.first { $0.id == album.id }
            ?? AlbumSummary(id: album.id, parentId: album.parentId, name: album.name,
                            sort: album.sort, createdAt: album.createdAt, count: 0)
    }

    @discardableResult
    public func renameAlbum(id: String, to name: String) throws -> AlbumSummary {
        guard let catalog else { throw AlbumError.noLibrary }
        let album = try catalog.renameAlbum(id: id, to: name)
        try refreshAlbums()
        return albums.first { $0.id == album.id }
            ?? AlbumSummary(id: album.id, parentId: album.parentId, name: album.name,
                            sort: album.sort, createdAt: album.createdAt, count: 0)
    }

    /// 删相册 —— **只删相册与成员关系，照片留在库里**。若删的正是当前打开的那个相册，
    /// 网格回到全库（不是回到一个已经不存在的相册）。
    @discardableResult
    public func deleteAlbum(id: String) throws -> AlbumDeleteReport {
        guard let catalog else { throw AlbumError.noLibrary }
        let report = try catalog.deleteAlbum(id: id)
        if selectedAlbumID == id { selectedAlbumID = nil }
        try refreshAlbums()
        reload()
        return report
    }

    /// 把照片加入相册（一次事务）。返回真正新增的成员数。
    ///
    /// 加完 `reload()`：正在看这个相册时，新成员必须立刻出现在网格里；不在看的时候这次 reload
    /// 也只是把左栏的数字改对。**不写 develop、不进历史。**
    @discardableResult
    public func addPhotos(_ ids: [String], toAlbum albumId: String) throws -> Int {
        guard let catalog else { throw AlbumError.noLibrary }
        let added = try catalog.addAssets(ids, toAlbum: albumId)
        try refreshAlbums()
        if added > 0 { reload() } else { albumRevision += 1 }
        return added
    }

    @discardableResult
    public func removePhotos(_ ids: [String], fromAlbum albumId: String) throws -> Int {
        guard let catalog else { throw AlbumError.noLibrary }
        let removed = try catalog.removeAssets(ids, fromAlbum: albumId)
        try refreshAlbums()
        if removed > 0 { reload() } else { albumRevision += 1 }
        return removed
    }

    /// 把当前选中（或锚点）的照片加入 / 移出相册 —— 菜单动作的落点。
    @discardableResult
    public func addSelection(toAlbum albumId: String) throws -> Int {
        try addPhotos(metadataTargetIDs, toAlbum: albumId)
    }

    @discardableResult
    public func removeSelection(fromAlbum albumId: String) throws -> Int {
        try removePhotos(metadataTargetIDs, fromAlbum: albumId)
    }

    /// 这些照片各自在哪些相册里 —— 右键菜单的「移出相册」用它决定列出谁。
    public func albumMemberships(of ids: [String]) -> [String: [String]] {
        guard let catalog else { return [:] }
        return (try? catalog.albumMemberships(assetIDs: ids)) ?? [:]
    }

    public func albumAssetIDs(_ albumId: String) -> [String] {
        guard let catalog else { return [] }
        return (try? catalog.albumAssetIDs(albumId)) ?? []
    }

    private func refreshAlbums() throws {
        guard let catalog else { return }
        albums = try catalog.albums()
        albumRevision += 1
    }

    public var anchorIndex: Int? {
        guard let id = anchorID else { return nil }
        return assets.firstIndex { $0.id == id }
    }

    public var anchorAsset: Asset? {
        guard let i = anchorIndex else { return nil }
        return assets[i]
    }

    /// The selection in library order — menus, filmstrip scrolling and "open" all want this.
    public var selectedAssets: [Asset] {
        assets.filter { selection.contains($0.id) }
    }

    /// Which photo a document edit applies to, given the selection and the grid's current order.
    ///
    /// 「当前顺序」 is the order the grid and filmstrip are actually drawing (`assets`, already sorted
    /// by `sortOrder`), not the order the user clicked the photos in and not the anchor. The answer
    /// is the **first selected photo in that order**; an empty selection — or a selection whose ids
    /// have all disappeared from the library — has no target and therefore writes nothing.
    ///
    /// Pure on purpose: the edit path and its tests both read this one function, so "多选时改的是
    /// 当前顺序第一张" cannot drift into "改的是锚点" in one place and not the other.
    public static func editTarget(selection: [String], order: [String]) -> String? {
        guard !selection.isEmpty else { return nil }
        let selected = Set(selection)
        return order.first { selected.contains($0) }
    }

    /// `editTarget` asked against *this* session's live selection and order.
    public var currentEditTargetID: String? {
        Self.editTarget(selection: Array(selection), order: assets.map(\.id))
    }

    /// Instance spelling, for callers that already hold the session.
    public func editTarget(selection: [String], order: [String]) -> String? {
        Self.editTarget(selection: selection, order: order)
    }

    public func setSelection(_ ids: Set<String>, anchor: String? = nil) {
        markSelectionChanged()
        selection = ids
        if let anchor {
            anchorID = anchor
        } else if let current = anchorID, ids.contains(current) {
            // keep the anchor
        } else {
            anchorID = ids.isEmpty ? nil : assets.last(where: { ids.contains($0.id) })?.id
        }
        // A programmatic selection that dropped the base no longer has a range to extend.
        if let base = selectionBase, !ids.contains(base) { selectionBase = nil }
        if let focus = rangeFocus, !ids.contains(focus) { rangeFocus = nil }
        loadEditForAnchor()
    }

    /// A plain click / non-⇧ keyboard landing: this photo is the selection, the anchor **and** the
    /// range base, so the next ⇧ click starts here.
    public func selectOnly(_ id: String) {
        markSelectionChanged()
        selection = [id]
        anchorID = id
        selectionBase = id
        rangeFocus = id
        loadEditForAnchor()
    }

    /// Grid/filmstrip click with modifiers already resolved by the control.
    ///
    /// ⌘ adds/removes one photo. Adding makes it the anchor and the new range base (the next ⇧
    /// starts from what the user just picked); removing a non-anchor leaves both where they were,
    /// and removing the anchor hands the anchor back to the range base (or, with no base left, to
    /// the last remaining photo in display order).
    public func toggle(_ id: String) {
        markSelectionChanged()
        if selection.contains(id) {
            selection.remove(id)
            if selectionBase == id {
                selectionBase = anchorID.flatMap { selection.contains($0) ? $0 : nil }
            }
            if anchorID == id {
                if let base = selectionBase, selection.contains(base) {
                    anchorID = base
                } else {
                    // 2026-11-11 主线修：锚被 ⌘ 关掉时，范围基点跟着落到新锚上，而不是变 nil ——
                    // 否则用户紧接着按 ⇧ 会退化成「只选一张再重建基点」，白丢一次范围手势。
                    anchorID = selection.isEmpty
                        ? nil : assets.last(where: { selection.contains($0.id) })?.id
                    selectionBase = anchorID
                }
            }
            if rangeFocus == id { rangeFocus = anchorID }
        } else {
            selection.insert(id)
            anchorID = id
            selectionBase = id
            rangeFocus = id
        }
        loadEditForAnchor()
    }

    /// ⇧ click: select the **closed range in display order** (`assets`, not id order) between the
    /// range base and `id`, replacing the current selection. `adding` is ⇧⌘ (union instead of
    /// replace). The anchor and the base do not move — that is the whole point of the gesture.
    public func selectRange(to id: String, adding: Bool = false) {
        markSelectionChanged()
        guard let base = selectionBase else {
            // No base yet (first ⇧ after a programmatic selection): a plain selection is the only
            // honest answer, and it establishes the base.
            selectOnly(id)
            return
        }
        guard let baseIndex = assets.firstIndex(where: { $0.id == base }),
              let targetIndex = assets.firstIndex(where: { $0.id == id }) else {
            selectOnly(id)
            return
        }
        let lo = min(baseIndex, targetIndex)
        let hi = max(baseIndex, targetIndex)
        let range = Set(assets[lo ... hi].map(\.id))
        selection = adding ? selection.union(range) : range
        rangeFocus = id
        loadEditForAnchor()
    }

    /// Arrow/Home/End/Page navigation. Without ⇧ the landing photo becomes the anchor and the
    /// base; with ⇧ the **cursor** moves from the previous range end, the range is recomputed from
    /// the unchanged base, and the anchor stays put (thick ring stays on the original photo).
    @discardableResult
    public func moveAnchor(by delta: Int, extend: Bool = false) -> Bool {
        guard !assets.isEmpty else { return false }
        if extend {
            let base = selectionBase ?? anchorID ?? assets.first?.id
            guard let base, assets.contains(where: { $0.id == base }),
                  let cursorID = rangeFocus ?? anchorID,
                  let cursor = assets.firstIndex(where: { $0.id == cursorID }) else { return false }
            let target = min(max(0, cursor + delta), assets.count - 1)
            guard target != cursor else { return false }
            selectionBase = base
            rangeFocus = assets[target].id
            selectRange(to: assets[target].id)
            return true
        }
        let current = anchorIndex ?? 0
        let target = min(max(0, current + delta), assets.count - 1)
        guard target != current || anchorID == nil else { return false }
        selectOnly(assets[target].id)
        return true
    }

    /// Double-click / Return: open the photo in the loupe.
    public func activate(_ id: String) {
        selectOnly(id)
        mode = .loupe
    }

    public func showGrid() {
        mode = .grid
    }

    // MARK: rating / flag / colour label (catalog metadata, never an edit)

    /// 0–5 stars on the whole selection. One transaction for the selection, because the shortcut
    /// runs per keystroke and a 10k-row selection must not become 10k writes.
    @discardableResult
    public func setRatingForSelection(_ rating: Int) -> Bool {
        let value = max(0, min(5, rating))
        return writeMetadata({ catalog, ids in try catalog.setRating(value, forAssets: ids) },
                             apply: { $0.rating = value })
    }

    /// P / X / U. `nil` clears the flag.
    @discardableResult
    public func setFlagForSelection(_ flag: String?) -> Bool {
        let value = AssetFlag.normalized(flag)?.rawValue
        return writeMetadata({ catalog, ids in try catalog.setFlag(value, forAssets: ids) },
                             apply: { $0.flag = value })
    }

    /// ⌥1–⌥6. `nil` clears the label.
    @discardableResult
    public func setColorLabelForSelection(_ label: String?) -> Bool {
        let value = ColorLabel.normalized(label)?.rawValue
        return writeMetadata({ catalog, ids in try catalog.setColorLabel(value, forAssets: ids) },
                             apply: { $0.colorLabel = value })
    }

    /// The one path a metadata write takes.
    ///
    /// Nothing here commits history or calls `persist()`: `develop_json`, `asset_history` and
    /// `editRevision` are untouched by construction, which is what makes "a rating is not an edit"
    /// an invariant rather than a promise. With a filter on, membership can change (a photo rated 2
    /// leaves "≥3"), so the query is re-run instead of patching rows in place.
    @discardableResult
    private func writeMetadata(_ write: (Catalog, [String]) throws -> Int,
                               apply: (inout Asset) -> Void) -> Bool {
        guard let catalog else { return false }
        let ids = metadataTargetIDs
        guard !ids.isEmpty else { return false }
        do {
            let affected = try write(catalog, ids)
            metadataWriteCount += 1
            lastMetadataAffectedRows = affected
            metadataRevision &+= 1
            lastPersistError = nil
            if filter.isActive {
                reload()
            } else {
                let touched = Set(ids)
                var next = assets
                for i in next.indices where touched.contains(next[i].id) { apply(&next[i]) }
                assets = next
            }
            return true
        } catch {
            lastPersistError = "\(error)"
            return false
        }
    }

    // MARK: filter

    /// Narrow (or widen) the grid. Re-runs the catalog query; the selection is intersected with
    /// what is left, exactly like a source change. Never touches the document or history.
    ///
    /// This is also the **only** place the filter is remembered (043): the bar, a chip's ×, a
    /// shortcut and the restore in `open` all arrive here, so what is stored is always what the user
    /// sees — there is no restore-only path that could drift from the click path.
    public func applyFilter(_ next: CatalogFilter) {
        guard next != filter else { return }
        filter = next
        reload()
        rememberFilter()
    }

    public func clearFilter() {
        applyFilter(.none)
        // 「清除全部」 means "start from the defaults next time too": that library's archive goes,
        // and every other library keeps its own (043 §4). `.none` is deliberately *not* written as an
        // archive — the default bar is the absence of one.
        if let path = filterPersistencePath { filterPersistence.forget(libraryPath: path) }
    }

    /// Write a pending filter archive right now. The app calls this on termination; a test calls it
    /// instead of waiting out the 0.5 s throttle.
    public func flushPendingFilterSave() {
        filterPersistence.flush()
    }

    private func rememberFilter() {
        guard let path = filterPersistencePath else { return }
        // A bar with nothing ticked constrains nothing: its archive is *absence*, not a blob of empty
        // slots. Dropping it is what makes "I un-ticked everything" survive a restart — writing
        // nothing here would leave yesterday's narrower archive to be restored over the user's own
        // clearing, which is the one way this feature could contradict the screen.
        guard filter.slots.contains(where: { !$0.isEmpty }) else {
            filterPersistence.forget(libraryPath: path)
            return
        }
        filterPersistence.remember(filter, libraryPath: path)
    }

    /// Drop one facet from the active filter.
    ///
    /// 050: the bar no longer draws removable chips, so nothing in the UI calls this — the same removal
    /// now happens by unticking the value in the slot's own checklist. Kept because the filter value is
    /// still a value: a facet can be dropped from a preset, a CLI or a test without going through a
    /// button that no longer exists.
    public func clearFilter(_ facet: CatalogFilter.Facet) {
        applyFilter(filter.without(facet))
    }

    /// Drop **one value** from one slot — what a chip's × does (026 v2). The slot stays, because a
    /// slot is the dimension the user is looking at, not a condition.
    public func removeSlotValue(at slot: Int, value: String) {
        applyFilter(filter.removingValue(value, atSlot: slot))
    }

    /// The values a slot's popup offers for `dimension`, scoped to the rest of the filter.
    ///
    /// Asked per dimension while the bar rebuilds; the catalog answers from this library only, so a
    /// dimension with nothing in it yields `[]` and the popup says 「本库无此数据」 instead of inventing
    /// a ladder of ISO values.
    public func facetValues(_ dimension: FilterDimension) -> [String] {
        guard let c = catalog else { return [] }
        let albumScope = selectedAlbumID.map { [$0] } ?? []
        return c.facetValues(dimension, filter: filter.assetFilter(limit: 200_000,
                                                                  folders: selectedFolders,
                                                                  albumIds: albumScope))
    }

    // MARK: documents

    /// The one way a slider (or a test) moves the document.
    ///
    /// Bumps `editRevision` only when the value actually changed, so an idle drag calls the
    /// renderer zero times instead of once per mouse move.
    ///
    /// A real write while the **grid** is on screen is also the moment the workspace enters the
    /// loupe (派单 119): the target is `editTarget(selection:order:)`, not necessarily the anchor, so
    /// a multi-selection is adjusted on its first photo in the current order. Pressing a slider
    /// without changing a value is not an edit and does not switch; entering happens on the first
    /// tick that writes, and the following ticks of the same drag continue in the loupe.
    public func applyEdit(_ mutate: (inout EditModel) -> Void) {
        // Not `flushPendingEditHistory()`: a drag only writes `edit`, and the values must not wait
        // for a history read. The stack is pulled forward at the commit/undo doors below.
        if mode == .grid, catalog != nil {
            applyEditFromGrid(mutate)
            return
        }
        applyEditInPlace(mutate)
    }

    /// The grid half of `applyEdit`: choose the target, write that photo's document, and switch.
    ///
    /// The target's document is read from the catalog **before** the switch so the mutation is
    /// applied exactly once (a closure may append a mask or generate an id; calling it twice to
    /// "test the water" would be a different edit). Nothing is written when the selection is empty
    /// or the mutation is a no-op.
    private func applyEditFromGrid(_ mutate: (inout EditModel) -> Void) {
        guard let target = currentEditTargetID else { return }
        let base: EditModel
        if target == loadedEditAssetID {
            base = edit
        } else if let catalog, let stored = try? catalog.develop(forAsset: target) {
            base = MaskViewState.documentOnly(stored)
        } else {
            base = .neutral
        }
        var next = base
        mutate(&next)
        guard !EditHistory.isSemanticallyIdentical(base, next) else { return }

        // 多选时改的是「当前顺序第一张」：切进单图后选集收成这一张，锚点同步成它。文档加载发生
        // 在写入之前，所以 `edit` / `history` / `loadedEditAssetID` 从第一帧起就是同一张照片的。
        if selection != [target] || anchorID != target || loadedEditAssetID != target {
            selectOnly(target)
        }
        mode = .loupe
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        notifyEditObservers(assetID: target)
    }

    /// The old `applyEdit` body, also used by commands whose target is already the loaded anchor
    /// (paste settings, presets): those are not grid adjustments and must not be retargeted.
    private func applyEditInPlace(_ mutate: (inout EditModel) -> Void) {
        var next = edit
        mutate(&next)
        guard !EditHistory.isSemanticallyIdentical(edit, next) else { return }
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        notifyEditObservers(assetID: editedAssetID)
    }

    /// Publish a change that is **not** a document edit — today that is only `showMaskID`.
    ///
    /// `applyEdit` cannot carry it: it short-circuits on "semantically identical", which is exactly
    /// the property that keeps the overlay out of history. This door bumps the revision (so the
    /// loupe re-encodes the last pass) and touches nothing else — no snapshot, no `persist()`.
    func publishViewState(_ mutate: (inout EditModel) -> Void) {
        var next = edit
        mutate(&next)
        guard next.showMaskID != edit.showMaskID else { return }
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
    }

    /// Internal door for the mask extension in `MaskCanvasController.swift` (same module, and the
    /// selection is view state that only that file's API should move).
    func setSelectedMaskID(_ id: String?) {
        selectedMaskID = id
    }

    /// End of one edit action (a slider release, a toggle, a menu command): push a snapshot and
    /// write it to the catalog.
    ///
    /// `EditHistory.commit` is a no-op when nothing changed, so a click on a slider that did not
    /// move neither grows the stack nor truncates the redo branch (and then nothing is written).
    /// The snapshot is `MaskViewState.documentOnly(edit)`: the overlay is view state, so a snapshot
    /// that carried it would make ⌘Z look like it also toggled the mask display.
    /// - Parameter coalesce: `false` for a discrete command (077): 双击复位 / 换解码版本 / 预设 各自
    ///   是**一个动作**，不许折进它前面那次拖动里（详见 `EditHistory.commit`）。
    @discardableResult
    public func commitEdit(label: String = "", coalesce: Bool = true) -> Bool {
        guard flushPendingEditHistory() else { return false }
        let committed = history.commit(MaskViewState.documentOnly(edit), label: label,
                                       coalesce: coalesce) != nil
        if committed { persist() }
        return committed
    }

    /// ⌘Z. Restores a whole snapshot — never an inverse operation (§History).
    ///
    /// The snapshot is the *document*; the `showMask` overlay that was on screen is pasted back on
    /// top of it. Without that, undoing any edit would silently switch the mask display off (the
    /// snapshot was taken before the overlay was turned on, and `showMaskID` is not an edit), which
    /// is exactly the failure this paste-back prevents.
    @discardableResult
    public func undo() -> Bool {
        // 356 — ⌘Z is a command, not a gesture: a session a gesture left open would be closed *after*
        // the undo and commit `base → edit`, resurrecting the state ⌘Z had just stepped away from.
        // Closing first is a no-op when nothing is open, so the door is the same either way.
        endToolSession()
        guard flushPendingEditHistory() else { return false }
        // A minimal window may stop at the oldest row it decoded; an undo that reaches that floor
        // asks for the full stack once, then walks it.
        if !history.canUndo, !historyWindowIsComplete { _ = loadFullEditHistoryIfNeeded() }
        guard let model = history.undo() else { return false }
        restore(model)
        persist()
        return true
    }

    // MARK: history panel (077)

    /// Click a row: move the cursor there and show it. **Not** an edit.
    ///
    /// `EditHistory.jump(to:)` only moves the cursor (no snapshot, nothing truncated), so this is one
    /// render and one write of `history_end`; the redo branch survives, and the *next* edit is what
    /// truncates it — which is the user's 「如果继续操作了，恢复点后面的操作就没了」.
    @discardableResult
    public func jumpToHistory(seq: Int) -> Bool {
        guard flushPendingEditHistory() else { return false }
        if history.index(of: seq) == nil, !historyWindowIsComplete {
            _ = loadFullEditHistoryIfNeeded()
        }
        guard let index = history.index(of: seq), index != history.cursor else { return false }
        guard let model = history.jump(to: seq) else { return false }
        restore(model)
        persist()
        return true
    }

    /// Delete one row of the timeline — 「可直接删除某个操作，其他不动」.
    ///
    /// Only the newest row of its class can go (`EditHistory.deletable(at:)`); the rule lives in the
    /// model so the panel's button and the model cannot disagree. Deleting **creates no snapshot**:
    /// it removes one, and the document moves only when the row the cursor stood on is the one
    /// removed (then the previous row's state is shown, one render).
    @discardableResult
    public func deleteHistoryEntry(at index: Int) -> Bool {
        let seqBefore = history.currentSeq
        guard history.delete(at: index) else { return false }
        if history.currentSeq != seqBefore, let model = history.current { restore(model) }
        persist()
        return true
    }

    /// 263: 撤销 one 「最新」 row — append a normal 「撤销 xxx」 snapshot that puts that row's fields
    /// back to their previous values, then write it once.
    ///
    /// Unlike `deleteHistoryEntry`, this always moves the document (the reverted snapshot is the new
    /// tip), so `restore` is unconditional: the append itself is the "the current document changed"
    /// signal. Returns false when the row cannot be reverted.
    @discardableResult
    public func revertHistoryEntry(at index: Int) -> Bool {
        guard let snapshot = history.revert(at: index) else { return false }
        restore(snapshot.edit)
        persist()
        return true
    }

    /// Rows for the panel: seq, label, the field-level summary, the time, and the two flags.
    ///
    /// 537 — opening the timeline is the moment the whole stack is wanted, so it is the moment the
    /// full read happens (once; the flag flips to true). The selection path only decoded the newest
    /// window.
    public var historyRows: [HistoryRow] {
        if !historyWindowIsComplete { _ = loadFullEditHistoryIfNeeded() }
        return history.rows
    }

    /// Begin a tool session (077): from here to `endToolSession` the history records **nothing**, so
    /// a crop/rotate gesture is one row however many handle positions it went through.
    public func beginToolSession(_ tool: String, label: String? = nil) {
        guard flushPendingEditHistory() else { return }
        history.beginSession(tool, label: label)
    }

    /// 356 — **a slider drag is a gesture: these are its two ends.**
    ///
    /// Press: close anything a previous gesture left open (a leak must not swallow this gesture's
    /// row), then open this one's. Release: close it — one row, `base → edit` — or, when the slider
    /// was driven without a press at all (a test, a preset, a reset), commit the same one row.
    ///
    /// The pair exists so a panel never asks the history whether a session is open: the two calls are
    /// the same whatever it contains, which is what makes a slider's row — and therefore what ⌘Z
    /// gives back — independent of it.
    public func beginToolGesture(tool: String, label: String) {
        endToolSession()                        // no-op when nothing is open
        guard flushPendingEditHistory() else { return }
        history.beginSession(tool, label: label)
    }

    @discardableResult
    public func endToolGesture(label: String, coalesce: Bool = true) -> Bool {
        if endToolSession(label: label) { return true }
        return commitEdit(label: label, coalesce: coalesce)
    }

    /// Is a tool session open?
    ///
    /// 356 — **only a gesture may make this true**, and no geometry judgement may read it. The crop
    /// tool asks nothing of it any more: `CropToolController` opens one on mouse-down and closes it on
    /// mouse-up, and closes any leftover before a command writes. It survives as the one question a
    /// *test* can ask ("is a session still open?") and nothing in the geometry paths branches on it.
    public var isToolSessionActive: Bool { history.isSessionActive }

    /// 应用: close the session with exactly one snapshot (`base → edit`), or none if nothing moved.
    @discardableResult
    public func endToolSession(label: String? = nil) -> Bool {
        guard flushPendingEditHistory() else { return false }
        let committed = history.endSession(MaskViewState.documentOnly(edit), label: label) != nil
        if committed { persist() }
        return committed
    }

    /// 取消: close the session with zero snapshots.
    ///
    /// The document goes back to where the tool started — normally a no-op (a draft tool never writes
    /// the document), but a control that *does* write inside a session (裁切 bar's flips) must not
    /// survive a cancel with no history row to undo it. One render, no snapshot.
    public func cancelToolSession() {
        guard flushPendingEditHistory() else { return }
        let base = history.activeSession?.base
        history.cancelSession()
        guard let base, !EditHistory.isSemanticallyIdentical(edit, base) else { return }
        edit = MaskViewState.restoring(base, keeping: edit.showMaskID)
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        notifyEditObservers(assetID: editedAssetID)
    }

    /// 356 — **the one writer for a command that changes the transform geometry** (双击「垂直透视」,
    /// a section reset, the card's title). A command is not a gesture, so it closes whatever a gesture
    /// left open — that close records the crop-so-far, which 应用 would have written anyway — then
    /// writes the document and commits **one** row.
    ///
    /// The three steps are the same whether or not a session was open, which is the whole point: the
    /// old shape ended-and-reopened a session only if there was one, so the same double-click left one
    /// row or none depending on what the history happened to contain, and the next ⌘Z therefore put a
    /// different document back.
    @discardableResult
    public func commitGeometryCommand(label: String,
                                      _ mutate: (inout GeometryGroup) -> Bool) -> Bool {
        endToolSession()                       // no-op when no gesture is running
        var changed = false
        applyEdit { model in changed = mutate(&model.geometry) }
        guard changed else { return false }
        return commitEdit(label: label, coalesce: false)
    }

    /// ⇧⌘Z.
    @discardableResult
    public func redo() -> Bool {
        endToolSession()            // 356 — same rule as `undo()`: a command closes the gesture's session
        guard flushPendingEditHistory() else { return false }
        guard let model = history.redo() else { return false }
        restore(model)
        persist()
        return true
    }

    /// Show a snapshot on screen: its document, plus the overlay that is currently on (view state).
    private func restore(_ model: EditModel) {
        edit = MaskViewState.restoring(model, keeping: edit.showMaskID)
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        // 165: ⌘Z / ⇧⌘Z / a history-row jump replaces the whole snapshot — the same "the user is
        // looking at the result, there was no pointer entry" case as a paste. The open photo's
        // backdrop must follow at once instead of waiting for the pointer to leave and come back.
        if let id = loadedEditAssetID ?? anchorAsset?.id {
            invalidateBackdrops(for: [id])
        }
        notifyEditObservers(assetID: editedAssetID)
    }

    /// Write the stack's current document to the catalog. One transaction, `saveDevelop`'s.
    ///
    /// Saving `history.current` rather than `edit` is deliberate: they are the same document except
    /// for the overlay, and the history is by construction the thing `DevelopError.historyInconsistent`
    /// checks a save against. A no-op commit therefore cannot throw "the blob disagrees with the
    /// cursor" just because a double moved by less than `EditHistory.dirtyTolerance`.
    private func persist() {
        guard flushPendingEditHistory() else { return }
        guard let catalog, let id = loadedEditAssetID ?? anchorAsset?.id else { return }
        var stack = history
        if stack.isEmpty {
            // Nothing was ever written for this asset (or its rows were quarantined): seed the floor
            // with the live document so the edit about to land has something to undo back to.
            stack = EditHistory(baseline: MaskViewState.documentOnly(edit))
        }
        guard let document = stack.current else { return }
        do {
            let result = try catalog.saveDevelop(document, history: stack, forAsset: id)
            lastSaveResult = result
            lastPersistError = nil
            // 363 — the row goes first: `persistCount` is the signal that wakes all three browsers,
            // and a refresh that runs before the row is updated would derive the pre-edit key again.
            adoptCommittedDocument(document, save: result)
            persistCount += 1
            // 487 — a denoise stack is one document in two files: the same payload is written to the
            // sibling, through the one catalog door that checks kind, member count and idempotency.
            // A plain stack (HDR, manual merge) is untouched — `propagateDenoiseEdit` returns nil.
            do {
                if let linked = try catalog.propagateDenoiseEdit(document, fromAsset: id) {
                    adoptCommittedDocument(document, save: linked)
                    // 525 — the sibling's `develop_json` moved too, so its `ThumbKey` (which carries
                    // the edit fingerprint) is a new file. 487's contract is that both members hold
                    // the same document; without this the expanded stack kept drawing the original
                    // on its pre-edit key, because the only refresh signals named the edited photo
                    // (`persistCount` and `editedAssetID`). One more call on the channel the three
                    // browsers already observe — not a second notification system.
                    notifyEditObservers(assetID: linked.assetId)
                }
            } catch {
                lastPersistError = "\(error)"
            }
            // 477 — **no file write here.** The library is the real-time store; the DNG/XMP is written
            // only by the explicit 文件 ▸ 保存 (⌘S) / right-click 保存 command.
        } catch {
            // A failed write is reported, never swallowed: the document is still on screen and
            // still undoable, and the next commit retries.
            lastPersistError = "\(error)"
        }
    }

    /// 363 — **the store and the row must not disagree.** `develop_json` in memory is what the three
    /// browsers derive a thumbnail key from for every photo that is not the loaded one, and what
    /// `reload()`/`catalog.develop(forAsset:)` would serve. It used to be written only to the
    /// database: the `Asset` in `assets` kept the **pre-edit** document until something re-read the
    /// library, so the next refresh of that photo's cell rebuilt the *old* key — the reported
    /// 「修改了 A，再修改 B，A 的预览又回退了」. Writing the committed document back into the row
    /// makes the key a consequence of the save instead of of a reload nobody performed.
    ///
    /// The bytes are `Catalog.encode`, i.e. the same canonical JSON the store just wrote, so a later
    /// decode yields the identical model (and therefore the identical `ThumbKey`).
    private func adoptCommittedDocument(_ document: EditModel, save: DevelopSaveResult) {
        guard let index = assets.firstIndex(where: { $0.id == save.assetId }) else { return }
        guard let json = try? Catalog.encode(document) else { return }
        guard assets[index].developJson != json
                || assets[index].developVersion != save.developVersion else { return }
        assets[index].developJson = json
        assets[index].developVersion = save.developVersion
        assets[index].editTime = save.editTime
        assets[index].historyEnd = save.historySeq
    }

    /// `force` re-reads the stored document (after an external save or a develop-json change).
    /// Without it, re-selecting the same photo keeps the live edit *and its history* — a selection
    /// change must not silently throw away the undo stack.
    ///
    /// D9 still holds — `develop_json` is the truth — but the selection path reads the copy the
    /// library query already loaded into `assets` instead of a second database round trip: the
    /// document is O(document) and lands synchronously, so the inspector's numbers never wait for a
    /// frame. The stack (`Catalog.editHistory(forAsset:)`, which decodes every snapshot) moves to a
    /// background queue; a library with no rows yet gets the `EditHistory(baseline:)` floor until it
    /// lands. `force` keeps the old authoritative synchronous read for 「外部保存改了这个 blob」.
    public func loadEditForAnchor(force: Bool = false) {
        guard let a = anchorAsset else {
            pendingEditHistory = nil
            pendingDeferredEditLoad = nil
            editHistoryLoadFailed = false
            historyWindowIsComplete = true
            historyWindowLoaded = false
            edit = .neutral
            history = EditHistory(baseline: .neutral)
            loadedEditAssetID = nil
            capabilitiesAssetID = nil
            asShotWhiteBalance = nil
            selectedMaskID = nil
            pendingMaskShape = nil
            recordHistogram(nil)
            return
        }
        // 463 — the switch is the detection moment. One `stat` for the photo the user just looked
        // at, before the early return, so re-selecting the same row after the file came back clears
        // the flag too. Offline roots are skipped inside the catalog method.
        recheckAvailability(assetID: a.id)
        if !force, loadedEditAssetID == a.id { return }
        // A switch supersedes any history still in flight for the photo we just left: its result
        // names another asset, so it could only be dropped later anyway.
        pendingEditHistory = nil
        editHistoryLoadToken &+= 1
        editHistoryLoadFailed = false
        historyWindowLoaded = false
        let selectionAt = selectionChangedAt == 0 ? CFAbsoluteTimeGetCurrent() : selectionChangedAt
        var timeline = EditLoadTimeline(assetID: a.id, selectionAt: selectionAt,
                                        developBeganAt: 0, developEndedAt: 0,
                                        historyBeganAt: 0, historyEndedAt: 0,
                                        assignedAt: 0, firstFrameAt: nil)
        // 530 — measured on the demo library (659 photos, histories up to 393 rows):
        // `develop(forAsset:)` costs ~1 ms, while `editHistory(forAsset:)` costs 15–20 ms p50 and
        // ~80 ms p95 in a quiet run (up to ~875 ms when the open's other reads contend), because
        // that call decodes every snapshot. So the **history** read is what holds the main
        // thread, not the document. The document is therefore still assigned synchronously (it is
        // the in-memory `develop_json` the library query already carried), and only the history
        // moves to a background queue. `force` keeps the old authoritative synchronous read: it is
        // the explicit "an external save changed this blob" door, not the selection path.
        var model: EditModel
        var stack: EditHistory?
        let synchronous = force || loadsEditHistorySynchronouslyForTesting
        let installsHistoryNow = synchronous
        timeline.developBeganAt = CFAbsoluteTimeGetCurrent()
        if synchronous, let catalog {
            model = (try? catalog.develop(forAsset: a.id)) ?? .neutral
        } else if let data = a.developJson.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(EditModel.self, from: data) {
            model = decoded
        } else if let catalog {
            // A row without a usable blob (or a library opened without the projection): one
            // document-sized read, still O(document), never the history.
            model = (try? catalog.develop(forAsset: a.id)) ?? .neutral
        } else {
            model = .neutral
        }
        timeline.developEndedAt = CFAbsoluteTimeGetCurrent()
        if synchronous {
            timeline.historyBeganAt = timeline.developEndedAt
            stack = try? catalog?.editHistory(forAsset: a.id)
            timeline.historyEndedAt = CFAbsoluteTimeGetCurrent()
        }
        // The overlay is view state: a stored document that carries one is stale by definition.
        model = MaskViewState.documentOnly(model)
        let load = DeferredEditLoad(asset: a, model: model, stack: stack, timeline: timeline,
                                    installsHistoryNow: installsHistoryNow)
        if defersDocumentUntilFirstFrameForTesting {
            pendingDeferredEditLoad = load
            return
        }
        applyEditLoad(load)
    }

    /// Put one switch's document (and, when already read, its history) in place. Split out so the
    /// reverse-gate door can defer exactly this step until a frame lands.
    private func applyEditLoad(_ load: DeferredEditLoad) {
        var timeline = load.timeline
        edit = load.model
        // A synchronous read that threw must not be mistaken for "the stack is empty": the floor
        // would be saved over the stored one. It stays incomplete and writes are refused until a
        // later full read succeeds.
        let synchronousFailure = load.installsHistoryNow && load.stack == nil && catalog != nil
        historyWindowIsComplete = load.installsHistoryNow && !synchronousFailure
        historyWindowLoaded = load.installsHistoryNow && !synchronousFailure
        editHistoryLoadFailed = synchronousFailure
        if load.installsHistoryNow, let stack = load.stack, !stack.isEmpty {
            history = stack
        } else {
            // A usable floor immediately; the stored stack replaces it when the background read
            // lands (or `flushPendingEditHistory()` pulls it forward before a write).
            history = EditHistory(baseline: load.model)
        }
        loadedEditAssetID = load.asset.id
        // 540 — the as-shot pair is read with the document, not with the first frame. One indexed
        // settings row, synchronous, so the two white-balance rows are ready at the same moment as
        // every other slider (530). A miss stays `nil`: the first frame fills it in below.
        asShotWhiteBalance = catalog?.storedAsShotWhiteBalance(forAsset: load.asset.id)
        selectedMaskID = edit.masks.first?.id
        maskTool = .off
        // A document change retires the pending shape and the previous photo's histogram: both
        // describe the picture that is no longer on screen.
        pendingMaskShape = nil
        recordHistogram(nil)
        timeline.assignedAt = CFAbsoluteTimeGetCurrent()
        if !load.installsHistoryNow {
            timeline.historyBeganAt = timeline.assignedAt
            lastEditLoadTimeline = timeline
            scheduleHistoryLoad(assetID: load.asset.id)
        } else {
            lastEditLoadTimeline = timeline
        }
        editLoadCount += 1
    }

    private func scheduleHistoryLoad(assetID: String) {
        guard let catalog else { return }
        editHistoryLoadToken &+= 1
        let token = editHistoryLoadToken
        let box = EditHistoryLoadBox()
        pendingEditHistory = PendingEditHistoryLoad(assetID: assetID, token: token, box: box)
        historyWindowIsComplete = false
        historyWindowLoaded = false
        editHistoryLoadFailed = false
        let delay = editHistoryLoadDelayForTesting
        let limit = Self.pendingEditHistoryWindow
        DispatchQueue.global(qos: .userInitiated).async {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            let started = CFAbsoluteTimeGetCurrent()
            // 537 — the write-sized window, not the whole stack: the old `editHistory(forAsset:)`
            // decoded all 393 rows (~270 ms p50 / 883 ms p95) to hand a commit a stack it would only
            // append to. See `Catalog.editHistoryWindow`.
            let window = try? catalog.editHistoryWindow(forAsset: assetID, limit: limit)
            let milliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
            box.finish(window)
            Task { @MainActor [weak self] in
                self?.installPendingHistory(token: token, milliseconds: milliseconds)
            }
        }
    }

    private func installPendingHistory(token: Int, milliseconds: Double) {
        guard let pending = pendingEditHistory, pending.token == token else { return }
        pendingEditHistory = nil
        lastEditHistoryLoadMilliseconds = milliseconds
        guard loadedEditAssetID == pending.assetID else { return }
        if let window = pending.box.result {
            editHistoryLoadFailed = false
            historyWindowIsComplete = window.isComplete
            historyWindowLoaded = true
            clearEditHistoryLoadingError()
            if !window.history.isEmpty { history = window.history }
        } else {
            editHistoryLoadFailed = true
            historyWindowLoaded = false
            lastPersistError = Self.editHistoryLoadingMessage
        }
        if var timeline = lastEditLoadTimeline, timeline.assetID == pending.assetID {
            timeline.historyEndedAt = CFAbsoluteTimeGetCurrent()
            lastEditLoadTimeline = timeline
        }
    }

    /// The message a refused write reports. One string, so the UI/tests can assert on it.
    static let editHistoryLoadingMessage = "历史仍在加载，请稍后重试"

    /// Clear the loading notice once the read has actually landed, without touching a genuine save
    /// failure that happened in the meantime.
    private func clearEditHistoryLoadingError() {
        if lastPersistError == Self.editHistoryLoadingMessage { lastPersistError = nil }
    }

    /// A write that appends to / moves the undo stack must see the stored one first. Waiting here is
    /// cheap in practice (537 loads only the newest window; the full 393-row read used to cost
    /// 270 ms p50 / 883 ms p95) and it exists so a very fast 「选图→拖滑块」 cannot commit onto a
    /// one-row baseline and truncate `asset_history`.
    ///
    /// 537 — the wait is now **bounded** (`pendingEditHistoryWaitLimit`, 1.2 s). On a timeout the
    /// pending read is deliberately left in flight, the write is refused, and `lastPersistError`
    /// explains why. Proceeding with the one-row floor would silently truncate the stored stack,
    /// which is exactly the failure 530's flush was added to prevent.
    ///
    /// - Returns: `false` when the caller must **not** write. Call sites either ignore the readback
    ///   (a session only needs it eventually) or guard on it before touching `history`.
    @discardableResult
    private func flushPendingEditHistory() -> Bool {
        guard let pending = pendingEditHistory else {
            if !historyWindowIsComplete && editHistoryLoadFailed {
                lastPersistError = Self.editHistoryLoadingMessage
                return false
            }
            return true
        }
        pendingEditHistoryWaitCount += 1
        let started = CFAbsoluteTimeGetCurrent()
        let waited = pending.box.semaphore.wait(timeout: .now() + pendingEditHistoryWaitLimit)
        lastPendingEditHistoryWaitMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1000
        if waited == .timedOut {
            pendingEditHistoryWaitTimeouts += 1
            // Keep `pendingEditHistory`: the background read is still on its way and may still
            // install. A later commit/undo retries against it.
            lastPersistError = Self.editHistoryLoadingMessage
            return false
        }
        pendingEditHistory = nil
        guard loadedEditAssetID == pending.assetID else { return true }
        guard let window = pending.box.result else {
            editHistoryLoadFailed = true
            historyWindowLoaded = false
            lastPersistError = Self.editHistoryLoadingMessage
            return false
        }
        editHistoryLoadFailed = false
        historyWindowIsComplete = window.isComplete
        historyWindowLoaded = true
        clearEditHistoryLoadingError()
        if !window.history.isEmpty { history = window.history }
        if var timeline = lastEditLoadTimeline, timeline.assetID == pending.assetID {
            timeline.historyEndedAt = CFAbsoluteTimeGetCurrent()
            lastEditLoadTimeline = timeline
        }
        return true
    }

    /// 537 — materialise the whole stack when an operation can target a row outside the newest
    /// window: the history panel (it lists every row), a jump, a delete/revert, or a schema
    /// migration (it must rewrite every snapshot, not just the newest 64).
    ///
    /// Merges by seq, preferring in-memory rows: a commit whose write failed lives only in memory,
    /// and replacing the stack with the database copy would drop it. An open tool session owns its
    /// base/cursor inside `history`, so this is a no-op while one is active (the panel is not
    /// reachable mid-gesture; a later command flushes normally).
    @discardableResult
    private func loadFullEditHistoryIfNeeded() -> Bool {
        guard !historyWindowIsComplete else { return true }
        guard !history.isSessionActive else { return false }
        guard let catalog, let id = loadedEditAssetID else { return false }
        // Cancel any window still in flight: installing it after the full read would shrink the
        // stack again.
        let hadWindow = historyWindowLoaded
        pendingEditHistory = nil
        editHistoryLoadToken &+= 1
        guard let full = try? catalog.editHistory(forAsset: id) else {
            editHistoryLoadFailed = true
            lastPersistError = Self.editHistoryLoadingMessage
            return false
        }
        guard loadedEditAssetID == id else { return false }
        var bySeq: [Int: EditHistory.Snapshot] = [:]
        for snap in full.snapshots { bySeq[snap.seq] = snap }
        if hadWindow {
            // Rows read before the window was replaced are at least as fresh as the database's.
            for snap in history.snapshots { bySeq[snap.seq] = snap }
        }
        let merged = EditHistory(rows: bySeq.values.sorted { $0.seq < $1.seq },
                                 cursorSeq: hadWindow ? (history.currentSeq ?? full.currentSeq)
                                                      : full.currentSeq)
        history = merged
        historyWindowIsComplete = true
        historyWindowLoaded = true
        editHistoryLoadFailed = false
        clearEditHistoryLoadingError()
        return true
    }

    /// 249 — convert a legacy (`canvasV1`) heal document to S1 source coordinates once the **exact**
    /// decoded frame is known. This is a schema migration, not an edit: it mints no history row, and
    /// it rewrites the stored document (the marker is the point of the version bump). The whole
    /// history is migrated with the live document so ⌘Z cannot bring a canvasV1 spot back.
    ///
    /// Returns `true` when anything moved.
    @discardableResult
    public func migrateHealSpots(sourceSize: ImageSize) -> Bool {
        guard flushPendingEditHistory() else { return false }
        // A migration rewrites every snapshot, so the newest window is not enough.
        guard loadFullEditHistoryIfNeeded() else { return false }
        var next = edit
        guard next.migrateHealSpots(sourceSize: sourceSize) else { return false }
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        history.migrateHealSpots(sourceSize: sourceSize)
        notifyEditObservers(assetID: editedAssetID)
        persist()
        return true
    }

    /// 330 — convert a pre-330 crop (a rect of the **photograph**) to the equivalent rectangle of the
    /// **document canvas** once the exact frame is known. The sibling of `migrateHealSpots`: a schema
    /// migration, not an edit — no history row, and the stored document is rewritten (the marker is
    /// the point). A keystone-free document returns `false` and its bytes do not move.
    @discardableResult
    public func migrateCropToCanvasSpace(sourceSize: ImageSize) -> Bool {
        guard flushPendingEditHistory() else { return false }
        guard loadFullEditHistoryIfNeeded() else { return false }
        var next = edit
        guard next.migrateCropToCanvasSpace(sourceSize: sourceSize) else { return false }
        edit = next
        editRevision &+= 1
        lastEditChangedAt = CFAbsoluteTimeGetCurrent()
        history.migrateCropToCanvasSpace(sourceSize: sourceSize)
        notifyEditObservers(assetID: editedAssetID)
        persist()
        return true
    }

    public func recordCapabilities(_ c: DecoderCapabilities) {
        // Equality-guarded: every presented frame reports the same facts, and an unconditional write
        // would re-render the SwiftUI inspector once per slider frame for no information. The photo
        // id is part of the guard because the same facts may describe two different photos (a stack
        // of identical files): the as-shot row below is still per asset.
        guard capabilities != c || capabilitiesAssetID != loadedEditAssetID else { return }
        capabilities = c
        capabilitiesAssetID = loadedEditAssetID

        // 540 — persist the file's own pair on the first development and correct an old row. The
        // first frame is the truth; a stored value that disagrees is rewritten exactly once and
        // counted. A frame that reports no pair leaves a stored one alone (it cannot be a correction)
        // and a photo with neither stays at "no value".
        let frame = c.asShotWhiteBalance
        guard frame.temperature != nil || frame.tint != nil else { return }
        guard let id = loadedEditAssetID, let catalog else {
            asShotWhiteBalance = frame
            return
        }
        // 443/540 — attribute the pair only to a frame this session actually ingested for the
        // loaded photo. The frame itself carries no asset id, so `ingestedSourceFrame` is the one
        // published identity that can refuse a late frame of the photo we just left; without it a
        // stale pair could be written into the new photo's row.
        guard ingestedSourceFrame?.assetID == id else { return }
        if let stored = catalog.storedAsShotWhiteBalance(forAsset: id) {
            if stored != frame {
                asShotMismatchCount &+= 1
                if catalog.storeAsShotWhiteBalance(frame, forAsset: id) {
                    asShotStoreWriteCount &+= 1
                }
            }
        } else if catalog.storeAsShotWhiteBalance(frame, forAsset: id) {
            asShotStoreWriteCount &+= 1
        }
        asShotWhiteBalance = frame
    }

    // MARK: measured facts — the histogram and the clipping warning
    //
    // Neither of these is a document edit: `lastHistogram` is a *reading* of the frame the loupe
    // already rendered (handed over when that frame is presented, so there is never a second
    // render), and `highlightWarning` is a display preference. `editRevision`, `EditHistory` and
    // `develop_json` are untouched by both — which is exactly what `--ui-smoke` asserts when it
    // toggles the warning and compares the document hash.

    /// The last frame's histogram, or nil before the first frame. Read by the inspector card.
    public private(set) var lastHistogram: Histogram?

    /// Paint clipped pixels magenta on the canvas. A toggle, not an edit.
    public private(set) var highlightWarning = false

    /// Bumped whenever the warning is switched, so the loupe (an AppKit observer of this object)
    /// has something cheap to watch that is not `editRevision`.
    public private(set) var highlightWarningRevision = 0

    /// The loupe hands over what its frame measured. Equality-guarded: a frame that measured the
    /// same distribution must not re-render the inspector.
    public func recordHistogram(_ h: Histogram?) {
        guard h != lastHistogram else { return }
        lastHistogram = h
    }

    public func setHighlightWarning(_ on: Bool) {
        guard on != highlightWarning else { return }
        highlightWarning = on
        highlightWarningRevision &+= 1
    }

    public func toggleHighlightWarning() {
        setHighlightWarning(!highlightWarning)
    }

    // MARK: presets (M5)
    //
    // A preset is a named *subset* of the document (`Preset` in PhotonsCore) stored in
    // `presets.develop_json`. `Presets.swift` owns the storage rules; the session's job is to keep
    // the live `edit`/`history` and the database in step:
    //
    //   · applying merges through `Preset.apply(to:)` — only the preset's groups move, masks and
    //     `showMaskID` stay the target's own — then commits **once**, so ⌘Z takes the whole preset
    //     back in one press (the same granularity as paste settings);
    //   · that commit is an ordinary `EditHistory.commit`, so the pixels, the blob and the undo
    //     label travel the path a slider does: a preset is not a special kind of edit;
    //   · the list is cached here (`presetRecords`) and rebuilt after every write, because the
    //     inspector card, the menu and the CLI-facing name lookups all draw from it.

    public private(set) var presetRecords: [PresetRecord] = []
    /// Bumped on every refresh — the panel observes this, not the array.
    public private(set) var presetsRevision = 0
    public private(set) var lastPresetError: String?

    public var defaultPresetName: String? { presetRecords.first(where: { $0.isDefault })?.name }

    public func reloadPresets() {
        guard let catalog else {
            presetRecords = []
            presetsRevision &+= 1
            return
        }
        do {
            presetRecords = try catalog.presetRecords()
            lastPresetError = nil
        } catch {
            presetRecords = []
            lastPresetError = error.localizedDescription
        }
        presetsRevision &+= 1
    }

    /// Apply a preset to the anchor photo as **one** undo step.
    @discardableResult
    public func applyPreset(named name: String) -> Bool {
        guard let catalog, anchorAsset != nil else {
            lastPresetError = Loc.t("先打开库并选中一张照片")
            return false
        }
        do {
            let record = try catalog.requirePreset(named: name)
            let merged = record.preset.apply(to: edit)
            guard !EditHistory.isSemanticallyIdentical(edit, merged) else {
                // Nothing to change is not an error — `commitEdit` would be a no-op too, and a
                // preset that is already applied must not grow the undo stack.
                lastPresetError = nil
                return false
            }
            // 356 — a preset is a command: close a gesture's session first, or `commitEdit` answers
            // `nil` and the preset moves the document with no row (⌘Z then cannot take it back).
            endToolSession()
            applyEditInPlace { $0 = merged }
            let committed = commitEdit(label: Loc.t("预设 {0}", String(describing: (record.name))))
            lastPresetError = committed ? nil : Loc.t("预设没有落地")
            return committed
        } catch {
            lastPresetError = error.localizedDescription
            return false
        }
    }

    /// Capture the anchor's document (minus the overlay, minus masks) as a new preset.
    ///
    /// `groups` defaults to every group, which is what "从当前照片新建" means: the whole look. The
    /// fragment is projected onto those groups by `Preset.init(name:from:groups:)`, so the stored
    /// preset can only carry what it claims to.
    @discardableResult
    public func createPresetFromCurrent(named name: String,
                                        groups: Set<PresetGroup> = Set(PresetGroup.allCases),
                                        sections: Set<EditSnapshotSection>? = nil)
        -> PresetRecord? {
        guard let catalog else {
            lastPresetError = Loc.t("未打开库")
            return nil
        }
        guard anchorAsset != nil else {
            lastPresetError = Loc.t("未选择照片")
            return nil
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastPresetError = Loc.t("预设需要一个名字")
            return nil
        }
        do {
            // 081 §4: a preset saved from the copy sheet carries **the cards that were checked**, and
            // nothing else — the fragment is those cards' current values over a neutral document, so
            // a later apply moves those leaves and only those. `groups` is the old door (「从当前照片
            // 新建预设」, the whole look).
            let preset: Preset = if let sections, !sections.isEmpty {
                Preset(name: trimmed, fromSections: sections, of: MaskViewState.documentOnly(edit))
            } else {
                Preset(name: trimmed, from: MaskViewState.documentOnly(edit), groups: groups)
            }
            let record = try catalog.savePreset(preset)
            lastPresetError = nil
            reloadPresets()
            return record
        } catch {
            lastPresetError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    public func deletePreset(named name: String) -> Bool {
        guard let catalog else { return false }
        do {
            let removed = try catalog.deletePreset(named: name)
            lastPresetError = removed ? nil : Loc.t("没有名为“{0}”的预设", String(describing: (name)))
            reloadPresets()
            return removed
        } catch {
            lastPresetError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    public func setDefaultPreset(named name: String?) -> Bool {
        guard let catalog else { return false }
        do {
            _ = try catalog.setDefaultPreset(named: name)
            lastPresetError = nil
            reloadPresets()
            return true
        } catch {
            lastPresetError = error.localizedDescription
            return false
        }
    }

    // MARK: settings clipboard — 复制/粘贴设置 (078 P0-7)
    //
    // ⌘C/⌘V for *settings*, which is a different verb from copying the document:
    //
    //   · the payload is `EditSnapshot` — **all copyable leaves**, defaults included (442), narrowed
    //     by the checklist (`CopySettingsSelection`). A paste writes every leaf the user checked, so
    //     a source at its default resets the destination to that default; fields outside the
    //     checklist still survive untouched.
    //   · it lives in this object, **not** on `NSPasteboard`. Develop settings are not text: putting
    //     them on the system pasteboard would make ⌘V into an image editor a `photons.*` blob, and
    //     would let a copied screenshot be "pasted" as settings. The menu item is ⌘C/⌘V and the
    //     focus rule (a text field keeps the system clipboard) lives in the window controller.
    //   · a paste is **one history row per photo** (`commitEdit(coalesce: false)` / `appendDevelop`),
    //     so one ⌘Z takes the whole paste back — however many groups it carried.
    //   · only a white balance paste re-develops (`EditSnapshotSection.requiresDecode`); tone, curve,
    //     colour, crop and masks are GPU-stage changes and `detail` is stored-not-rendered.

    /// What ⌘C captured (already narrowed). `nil` before the first copy.
    public private(set) var copiedSettings: EditSnapshot?
    /// Which photo it came from — the menu/paste messages name it, and the anchor's own paste goes
    /// through the live document only when this is the photo on screen.
    public private(set) var copiedSettingsSourceID: String?

    /// The checklist ⌘C uses. Lives here so the dialog's last answer is what the next ⌘C copies
    /// (Lightroom's behaviour: the Copy Settings checklist is sticky).
    public var copySelection = CopySettingsSelection.all

    /// Bumped after every copy/paste, for the status line and the menu titles.
    public private(set) var settingsRevision = 0
    /// Why the last copy/paste did nothing, or nil.
    public private(set) var lastSettingsError: String?
    /// The reports of the last paste, one per target photo.
    public private(set) var lastPasteReports: [SettingsPasteReport] = []

    // MARK: backdrop invalidation (165)
    //
    // `editRevision` says "the document moved" and the loupe answers with a new sharp frame. That is
    // not enough for the low-resolution whole picture: an ordinary edit deliberately only *marks* the
    // backdrop stale (039), and only a photo switch or a pointer entry into the canvas rebuilds it.
    // ⌘V and ⌘Z are not ordinary edits — the user is already looking at their result, and neither
    // command involves a pointer entry. These two properties are the command-scoped signal the loupe
    // observes, so it can rebuild **the photo that changed** immediately without turning every slider
    // tick into a backdrop render.
    //
    // A paste onto other photos writes their `develop_json` directly (no editor, no frame); the ids
    // are still reported so the scope is explicit and a future photo-keyed cache has one place to be
    // cleared. The loupe holds only the open photo's texture, so those ids cost no request.
    /// Bumped by a command that moved a document outside the frame/pointer path (paste, history).
    public private(set) var backdropInvalidationRevision = 0
    /// The photos the last such command touched. The loupe acts only when the photo on screen is in it.
    public private(set) var backdropInvalidationAssetIDs: Set<String> = []

    private func invalidateBackdrops(for assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }
        backdropInvalidationAssetIDs = assetIDs
        backdropInvalidationRevision &+= 1
    }

    public var canCopySettings: Bool { anchorAsset != nil }

    /// 442: `isEmpty` now means **no copyable leaf at all** (an empty checklist, or 蒙版 on a photo
    /// with no masks) — not "the source happened to be at defaults", which is a copyable state now.
    public var canPasteSettings: Bool {
        guard let payload = copiedSettings, !payload.isEmpty else { return false }
        return !metadataTargetIDs.isEmpty
    }

    /// ⌘C — capture the anchor's **every copyable leaf**, defaults included (442), narrowed by
    /// `selection` (default: the sticky checklist).
    @discardableResult
    public func copySettingsFromAnchor(selection: CopySettingsSelection? = nil) -> EditSnapshot? {
        guard let asset = anchorAsset else {
            lastSettingsError = Loc.t("先选中一张照片")
            return nil
        }
        let choice = selection ?? copySelection
        let document = asset.id == loadedEditAssetID
            ? MaskViewState.documentOnly(edit)
            : (catalog.flatMap { try? $0.develop(forAsset: asset.id) } ?? .neutral)
        // P1-5: masks travel with the aspect ratio of the frame they were measured in, so the paste
        // side can re-anchor them. This is the one place that knows it (the document does not store
        // its own pixel size).
        let payload = EditSnapshot.capture(document, frameAspect: frameAspect(of: asset.id))
            .filtered(to: choice)
        copiedSettings = payload
        copiedSettingsSourceID = asset.id
        copySelection = choice
        // 081 §3: every 复制 writes the checklist once, into **this** library's `settings` row. Failure
        // is silent on purpose — a read-only library must still be able to copy settings, and the
        // selection then simply comes back as 全部 next time.
        if let catalog { try? catalog.storeCopySelection(choice) }
        // 442: defaults are copied now, so "empty" no longer means "the photo is neutral"; it means
        // the checklist selected no leaf the payload can carry. Describe that, not the old rule.
        lastSettingsError = payload.isEmpty
            ? (choice.isEmpty
                ? Loc.t("未选任何组：粘贴什么也不会发生")
                : Loc.t("所选组里没有可粘贴的设置"))
            : nil
        settingsRevision &+= 1
        return payload
    }

    /// ⌘V — paste into the selection (or the anchor when nothing is selected).
    ///
    /// `sections` narrows the payload further at paste time (the 「粘贴设置（选择…）」 row); `nil`
    /// keeps what ⌘C already narrowed. `ids` exists for the tests and for a future Sync command; the
    /// menu passes neither.
    @discardableResult
    public func pasteSettings(sections: Set<EditSnapshotSection>? = nil,
                              into ids: [String]? = nil) -> [SettingsPasteReport] {
        let narrowed = sections.flatMap { checked in copiedSettings.map { $0.filtered(to: checked) } }
        return pasteSettings(narrowed: narrowed, into: ids)
    }

    /// ⇧⌘V — narrow the payload by **the sheet's whole answer**, cards *and* parameter rows, so the
    /// paste writes exactly what the checkboxes said (081 §2/§3).
    @discardableResult
    public func pasteSettings(selection: CopySettingsSelection,
                              into ids: [String]? = nil) -> [SettingsPasteReport] {
        let narrowed = copiedSettings.map { $0.filtered(to: selection) }
        return pasteSettings(narrowed: narrowed, into: ids)
    }

    private func pasteSettings(narrowed: EditSnapshot?, into ids: [String]?) -> [SettingsPasteReport] {
        let targets = ids ?? metadataTargetIDs
        lastPasteReports = []
        guard let copied = copiedSettings else {
            lastSettingsError = Loc.t("剪贴板里没有设置：先按 ⌘C 复制")
            settingsRevision &+= 1
            return []
        }
        let payload = narrowed ?? copied
        guard !payload.isEmpty else {
            lastSettingsError = Loc.t("所选组里没有可粘贴的设置")
            settingsRevision &+= 1
            return []
        }
        guard !targets.isEmpty else {
            lastSettingsError = Loc.t("没有目标照片")
            settingsRevision &+= 1
            return []
        }

        var reports: [SettingsPasteReport] = []
        var failures: [String] = []
        // 165: the photos whose document this paste actually moved, for the backdrop signal below.
        var changedTargets: Set<String> = []
        for id in targets {
            if id == loadedEditAssetID {
                if let report = pasteIntoLiveDocument(payload) {
                    reports.append(report)
                    if report.changed { changedTargets.insert(id) }
                } else {
                    failures.append(Loc.t("当前照片在工具会话里：先应用或取消裁切/蒙版工具再粘贴"))
                }
                continue
            }
            guard let catalog else { continue }
            do {
                let report = try catalog.pasteSettings(payload, intoAsset: id,
                                                       sections: Set(EditSnapshotSection.copyable),
                                                       label: Loc.t("粘贴设置"),
                                                       destinationAspect: frameAspect(of: id))
                reports.append(report)
                if report.changed { changedTargets.insert(id) }
            } catch {
                failures.append("\(id.prefix(8))：\(error.localizedDescription)")
            }
        }
        lastPasteReports = reports
        lastSettingsError = failures.isEmpty
            ? (reports.contains(where: \.changed) ? nil : Loc.t("目标照片已经是这些值：没有改动"))
            : failures.joined(separator: "；")
        // 165: a paste is a command, not a slider tick. Rebuild the open photo's bottom image now;
        // the other targets are only named, never rendered (their backdrops are made when opened).
        invalidateBackdrops(for: changedTargets)
        settingsRevision &+= 1
        return reports
    }

    /// The anchor's paste goes through the **live** document, so the pixels, the stack and the blob
    /// travel the same path a slider does — and so the undo row is the session's own.
    ///
    /// `commitEdit(coalesce: false)`: a paste is a discrete command, never the continuation of the
    /// drag that happened to precede it (EditHistory's merge rule is asked not to apply).
    /// The mask overlay (`showMaskID`) is pasted back on top because it is view state, exactly as
    /// `undo()` does.
    ///
    /// The perspective a mask paste has to be re-anchored in: `W/H` of the photo's **upright**
    /// source frame (P1-5).
    ///
    /// Three sources, in the order they can be trusted:
    ///   1. the frame the renderer actually ingested for *this* photo (`ingestedSourceFrame`) — the
    ///      exact numbers every mask on screen was normalised against, including EXIF orientation;
    ///   2. the catalog row's `width`/`height` — the *stored* dimensions, which are transposed for
    ///      EXIF 5…8, so for those files this answers the reciprocal ratio. That is a degradation,
    ///      not a wrong point: a reciprocal pair still meets an unknown aspect on the other side, and
    ///      the paste falls back to copying fractions rather than inventing a factor;
    ///   3. nothing (`nil`) — a paste copies the normalised coordinates as-is, which is what a
    ///      same-aspect copy would do anyway.
    func frameAspect(of assetID: String) -> Double? {
        if assetID == loadedEditAssetID, let frame = ingestedSourceFrame, frame.assetID == assetID {
            return Self.aspect(of: frame.size)
        }
        guard let row = assets.first(where: { $0.id == assetID }) else { return nil }
        return Self.aspect(width: row.width, height: row.height)
    }

    static func aspect(of size: ImageSize) -> Double? {
        aspect(width: size.width, height: size.height)
    }

    static func aspect(width: Int?, height: Int?) -> Double? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }

    /// The live-document half of ⌘V. (See `frameAspect(of:)` for the `destinationAspect` term.)
    private func pasteIntoLiveDocument(_ payload: EditSnapshot) -> SettingsPasteReport? {
        // 356 — a paste is a command, not a gesture: close whatever a gesture left open (its row is
        // the crop-so-far, which 应用 would have written anyway) instead of **refusing** the paste.
        // The old `guard !…isSessionActive else { return nil }` made ⌘V do nothing at all
        // whenever the history happened to hold a session — the user's 「只要历史里有东西…」.
        // `endToolSession` is a no-op when nothing is open, so the door is the same either way.
        endToolSession()
        let current = MaskViewState.documentOnly(edit)
        let merged = payload.applied(to: current,
                                     destinationAspect: frameAspect(of: loadedEditAssetID ?? ""))
        let fields = EditHistory.changedFields(between: current, and: merged)
        guard !fields.isEmpty else {
            return SettingsPasteReport(assetID: loadedEditAssetID ?? "",
                                       changed: false, fields: [], sections: payload.sections,
                                       requiresDecode: payload.requiresDecode, historyRows: nil)
        }
        applyEditInPlace { $0 = MaskViewState.restoring(merged, keeping: $0.showMaskID) }
        let committed = commitEdit(label: Loc.t("粘贴设置"), coalesce: false)
        return SettingsPasteReport(assetID: loadedEditAssetID ?? "", changed: committed,
                                   fields: fields, sections: payload.sections,
                                   requiresDecode: payload.requiresDecode,
                                   historyRows: committed ? history.count : nil)
    }

    // MARK: missing originals (a reference root's file moved on disk)

    // The library stores references, so the Finder can move a photo out from under a row. Nothing
    // here deletes anything without the user saying so: `refreshAvailability()` re-derives the flag,
    // `relinkMissing` puts a row back on its file, and `deleteAssets` is the other answer.
    //
    // All three are *library* facts, not document edits: `editRevision`, `editHistory` and
    // `develop_json` are untouched by a relink (the document belongs to the photo, and the photo is
    // the same photo — that is what the content hash check proves).

    /// What the last availability pass found (`nil` before the library was opened).
    public private(set) var lastAvailability: AvailabilityReport?

    /// Why the last relink/delete failed, or nil. Reported, never swallowed.
    public private(set) var lastAvailabilityError: String?

    /// 463 — bumped whenever a missing flag moves (single-row re-stat, decode fallback, full refresh).
    /// The loupe banner observes it; the three browsers already watch `metadataRevision`, which moves
    /// with it.
    public private(set) var availabilityRevision = 0

    /// Test seam: make the per-switch stat lie. `nil` means the real filesystem. The decode-failure
    /// fallback deliberately bypasses this and forces the answer, which is how the test proves the
    /// fallback is a second path rather than the stat running twice.
    var availabilityFileExistsOverrideForTesting: ((URL) -> Bool)?

    /// Rows whose original file is not where the library says — what the badge and the menu read.
    public var missingAssets: [Asset] { assets.filter(\.isMissing) }

    /// 463 — the one seam the three browsers use to decide whether a displayed row carries a missing
    /// mark. A stack's row is marked when the top itself is gone **or** any hidden member is, because
    /// the hidden member has no cell of its own.
    public func isMarkedMissing(assetID id: String) -> Bool {
        if assets.first(where: { $0.id == id })?.isMissing == true { return true }
        return stackTopIDsWithMissingMembers.contains(id)
    }

    /// Whether a displayed stack row should say 「这一叠里有文件不在了」. The top's own missing flag is
    /// still drawn as 「原文件已移动」, so the two sentences never describe the same photo twice.
    public func stackHasMissingMember(forAssetID id: String) -> Bool {
        guard assets.first(where: { $0.id == id })?.isMissing != true else { return false }
        return stackTopIDsWithMissingMembers.contains(id)
    }

    /// Re-stat just `assetID`, then tell the views. Called when the anchor changes (entering the
    /// loupe, arrow keys, a click) — the moment the user is looking at a file is the moment the app
    /// should notice it is gone. Returns the flag, or `nil` when the row/root was not examined.
    ///
    /// No `reload()`: members, order, filter and the document do not move because one flag did, and a
    /// full query on every arrow key would be the wrong price for this fact.
    @discardableResult
    public func recheckAvailability(assetID id: String) -> Bool? {
        guard let catalog else { return nil }
        let check = availabilityFileExistsOverrideForTesting
            ?? { FileManager.default.fileExists(atPath: $0.path) }
        guard let isMissing = try? catalog.recheckAvailability(assetID: id, fileExists: check) else {
            return nil
        }
        applyAvailability(isMissing, assetID: id)
        return isMissing
    }

    /// 463 — the decode/development fallback. It is deliberately **not** gated on a fresh `stat`:
    /// the file can disappear between the switch and the decode, and the decoder saying "no file"
    /// is itself the evidence. Forcing the flag through the same one-row entry keeps the SQL and the
    /// offline-root rule in one place (the forced answer is only used for a URL the row itself
    /// resolves to).
    func markMissingAfterDecodeFailure(url: URL) {
        guard let catalog else { return }
        let target = url.standardizedFileURL.path
        guard let asset = assets.first(where: {
            fileURL(for: $0)?.standardizedFileURL.path == target
        }) else { return }
        guard let isMissing = try? catalog.recheckAvailability(assetID: asset.id,
                                                               fileExists: { _ in false }) else {
            return
        }
        applyAvailability(isMissing, assetID: asset.id)
    }

    /// Write one flag into the in-memory projection and keep the stack marker in step. The database
    /// is already written by `Catalog.recheckAvailability`; this is the signal half.
    private func applyAvailability(_ isMissing: Bool, assetID id: String) {
        var changed = false
        if let index = assets.firstIndex(where: { $0.id == id }),
           assets[index].missing != isMissing {
            assets[index].missing = isMissing
            changed = true
        }
        if refreshStackMissing(forAssetID: id) { changed = true }
        guard changed else { return }
        availabilityRevision &+= 1
        metadataRevision &+= 1
    }

    /// Re-read the stack this asset belongs to and move its top into/out of the marker set. One
    /// query, only on the rare event of a flag actually moving.
    @discardableResult
    private func refreshStackMissing(forAssetID id: String) -> Bool {
        guard let catalog,
              let stackID = (try? catalog.stackID(ofAsset: id)) ?? nil,
              let members = try? catalog.stackMembers(stackID: stackID),
              let top = members.first(where: { $0.stackRank == 0 }) else { return false }
        let had = stackTopIDsWithMissingMembers.contains(top.id)
        let has = members.contains(where: \.isMissing)
        if has {
            stackTopIDsWithMissingMembers.insert(top.id)
        } else {
            stackTopIDsWithMissingMembers.remove(top.id)
        }
        if let index = assets.firstIndex(where: { $0.id == top.id }),
           assets[index].missing != top.isMissing {
            assets[index].missing = top.isMissing
        }
        return had != has
    }

    /// The missing subset of the current selection, in library order. Both context-menu verbs act on
    /// exactly this list, so the count in the confirmation sheet is the count that gets deleted.
    public var missingSelectionIDs: [String] { selectedAssets.filter(\.isMissing).map(\.id) }

    /// Re-stat every row under an online root. Called on open and by the manual rescan action.
    @discardableResult
    public func refreshAvailability() -> AvailabilityReport? {
        guard let catalog else { return nil }
        let report = try? catalog.refreshAvailability()
        lastAvailability = report
        reload()
        availabilityRevision &+= 1
        return report
    }

    /// Remove entries **and their modification records**. The originals on disk are never touched.
    @discardableResult
    public func deleteAssets(_ ids: [String]) -> DeleteReport? {
        guard let catalog, !ids.isEmpty else { return nil }
        // Decide the successor from the order seen *before* the rows go away. The query afterwards
        // can only answer "what is first now", which is exactly the bug (back to the first photo).
        pendingAnchorSuccessor = SelectionAfterRemoval.successor(order: assets.map(\.id),
                                                                removing: Set(ids),
                                                                anchor: anchorID)
        do {
            let report = try catalog.deleteAssets(ids: ids, thumbnails: thumbnailCache)
            lastAvailabilityError = nil
            // `reload()` and not a local splice: membership, the selection, the anchor and the stats
            // all change at once, and the query is the only thing that knows the new truth.
            reload()
            return report
        } catch {
            pendingAnchorSuccessor = nil
            lastAvailabilityError = "\(error.localizedDescription)"
            return nil
        }
    }

    /// Remove one folder subtree from the library — 「从照片库移除此文件夹…」 (379).
    ///
    /// Same order as `deleteAssets`: the anchor's successor is decided from the order the user saw
    /// **before** the rows go, then the transaction, then `reload()`. The folder selection that
    /// pointed into the removed subtree is pruned in the same breath — `reload()` would otherwise
    /// narrow the grid to a prefix no row carries any more while the left column has no row to click
    /// back from. Nothing on disk is touched (see `Catalog.removeFolder`).
    @discardableResult
    public func removeFolder(rootID: String, path: String) -> DeleteReport? {
        guard let catalog else { return nil }
        let folder = AssetFilter.normalizedFolderPath(path)
        let ids = (try? catalog.assetIDs(rootID: rootID, folderPath: path)) ?? []
        // 381: an empty id list is not a reason to stop. A root whose last photo went still has a
        // 0-count row in the left column, and only `reload()` below takes it out of the tree — a
        // `return nil` here would leave the menu verb doing nothing at all. There is simply no
        // anchor successor to compute when nothing the user saw is going away.
        if !ids.isEmpty {
            pendingAnchorSuccessor = SelectionAfterRemoval.successor(order: assets.map(\.id),
                                                                    removing: Set(ids),
                                                                    anchor: anchorID)
        }
        do {
            let report = try catalog.removeFolder(rootID: rootID, path: path, thumbnails: thumbnailCache)
            lastAvailabilityError = nil
            // Drop the dead rows from the selection *before* the reload, so the query it runs is the
            // one the user will see. A selection that loses every row goes back to 全部照片 — which
            // is `selectedFolders == []`, the same state the 全部照片 row stores. Selections from
            // **other roots** are untouched: removing `rootA/day2` is not removing `rootB/x`.
            selectedFolders = Self.selectedFolders(selectedFolders, removing: rootID, folder: folder)
            reload()
            return report
        } catch {
            pendingAnchorSuccessor = nil
            lastAvailabilityError = "\(error.localizedDescription)"
            return nil
        }
    }

    /// Remove a whole source root from the library (root row → 「从照片库移除此文件夹…」).
    ///
    /// The photos go with it (FK cascade) and so does the root's row in the left column; the originals
    /// on disk stay. Selections naming that root are dropped — a root that no longer exists cannot be
    /// a filter.
    @discardableResult
    public func removeSourceRoot(id: String) -> DeleteReport? {
        guard let catalog else { return nil }
        // Every id under the root, not just the ones the current filter shows: the successor rule is
        // about the order the user saw, and the removal is about the whole root.
        let ids = (try? catalog.assetIDs(rootID: id, folderPath: "")) ?? []
        // 381: 0 张的根行照样要移（见 `removeFolder` 的同一理由）：`removeSourceRoot` 删的是
        // `source_roots` 那一行，没有照片可删不是错误。
        if !ids.isEmpty {
            pendingAnchorSuccessor = SelectionAfterRemoval.successor(order: assets.map(\.id),
                                                                    removing: Set(ids),
                                                                    anchor: anchorID)
        }
        do {
            let report = try catalog.removeSourceRoot(id: id, thumbnails: thumbnailCache)
            lastAvailabilityError = nil
            selectedFolders = Self.selectedFolders(selectedFolders, removing: id, folder: nil)
            reload()
            return report
        } catch {
            pendingAnchorSuccessor = nil
            lastAvailabilityError = "\(error.localizedDescription)"
            return nil
        }
    }

    /// Keep the selections that do not point into the removed subtree. `removedPath` is the removed
    /// folder's canonical path; `nil` means **every photo of that root went** (the root row, or a
    /// folder removal with an empty path), so every selection of that root is dead.
    ///
    /// A sub-selection of the removed folder (`day2/sub` when `day2` went) is inside the subtree just
    /// as much as the folder itself, so the test is prefix-based and segment-safe — `day2x` is not
    /// `day2`. Selections naming a **different root** are neither, and stay. A selection of the root
    /// itself survives a *subfolder* removal: the root still holds its other photos. Pure, so the
    /// rule can be asserted without a library.
    static func selectedFolders(_ folders: [FolderSelection], removing rootID: String,
                                folder removedPath: String?) -> [FolderSelection] {
        folders.filter { folder in
            guard folder.rootId == rootID else { return true }
            guard let removedPath else { return false }
            guard let path = folder.normalizedPath else { return true }
            return path != removedPath && !path.hasPrefix(removedPath + "/")
        }
    }

    /// The count the confirmation sheet prints: one `COUNT(*)` over the folder subtree (or the root),
    /// never a full id read — a ten-thousand-photo folder must open its dialog instantly.
    public func folderAssetCount(rootID: String, path: String) -> Int {
        (try? catalog?.folderAssetCount(rootID: rootID, folderPath: path)) ?? 0
    }

    /// What 「移出并删除…」 did, in the user's terms.
    public struct RemovalOutcome: Sendable, Equatable {
        /// What the row transaction removed (table counts — the same shape `DeleteReport` always had).
        public var removed: DeleteReport?
        /// Originals that really went to the Trash (a file already gone is not counted).
        public var filesTrashed: Int
        /// Rows that stayed in the library because their original could not be recycled.
        public var keptIDs: [String]
        /// One human-readable reason per kept row.
        public var failures: [String]

        public init(removed: DeleteReport? = nil, filesTrashed: Int = 0,
                    keptIDs: [String] = [], failures: [String] = []) {
            self.removed = removed
            self.filesTrashed = filesTrashed
            self.keptIDs = keptIDs
            self.failures = failures
        }
    }

    /// The real recycle: `FileManager`'s Trash, so ⌘Z-less deletion is still undoable in the Finder.
    nonisolated public static func trashItem(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Remove rows **and** recycle their originals. Per entry: recycle first, then delete the row, so
    /// a row is never gone while its file is still where the library said it was. A recycle failure
    /// keeps that row and does not stop the others.
    ///
    /// A file that is already absent on disk is just a row removal (nothing to recycle, not a failure).
    @discardableResult
    public func removeAssetsDeletingFiles(_ ids: [String],
                                          recycle: (URL) throws -> Void = CatalogSession.trashItem)
        -> RemovalOutcome {
        guard catalog != nil, !ids.isEmpty else { return RemovalOutcome() }
        var toDelete: [String] = []
        var filesTrashed = 0
        var keptIDs: [String] = []
        var failures: [String] = []
        for asset in assets where ids.contains(asset.id) {
            if let url = fileURL(for: asset), FileManager.default.fileExists(atPath: url.path) {
                do {
                    try recycle(url)
                    filesTrashed += 1
                } catch {
                    keptIDs.append(asset.id)
                    failures.append("\(asset.filename)：\(error.localizedDescription)")
                    continue
                }
            }
            toDelete.append(asset.id)
        }
        let report = deleteAssets(toDelete)
        if !toDelete.isEmpty, report == nil {
            failures.append(Loc.t("移出条目失败：{0}", String(describing: (lastAvailabilityError ?? Loc.t("未知错误")))))
        }
        return RemovalOutcome(removed: report, filesTrashed: filesTrashed,
                              keptIDs: keptIDs, failures: failures)
    }

    /// One 「查找丢失的文件…」 run: search `folder` by file name, then relink every hit whose content
    /// hash matches. Entries that are not found keep their flag — nothing is guessed.
    ///
    /// One search for the whole batch (`LostFileFinder.find` takes every target at once), because a
    /// recursive walk per photo would make a 40-photo relink 40 walks of the same folder.
    public func relinkMissing(_ ids: [String], in folder: URL) -> RelinkOutcome {
        guard let catalog else { return RelinkOutcome() }
        let chosen = assets.filter { ids.contains($0.id) && $0.isMissing }
        let targets = chosen.map {
            LostFileFinder.Target(assetID: $0.id, filename: $0.filename, contentHash: $0.contentHash)
        }
        var outcome = RelinkOutcome()
        guard !targets.isEmpty else { return outcome }

        let found = LostFileFinder.find(folder: folder, targets: targets)
        outcome.unmatched = found.unmatched
        outcome.rejected = found.rejected
        for match in found.matches {
            do {
                _ = try catalog.relink(assetID: match.assetID, to: match.url)
                outcome.relinked.append(match.assetID)
            } catch {
                outcome.failed.append(match.assetID)
                outcome.failures.append("\(match.filename)：\(error.localizedDescription)")
            }
        }
        lastAvailabilityError = outcome.failures.isEmpty ? nil : outcome.failures.joined(separator: "；")
        if !outcome.relinked.isEmpty { reload() }
        return outcome
    }

    // MARK: export items

    /// The photos an export acts on: the selection, in library order.
    public var exportableSelection: [Asset] { selectedAssets }

    /// One `ExportItem` per asset — the engine's input, built from the catalog.
    ///
    /// The document is the catalog's (`develop_json`), except for the photo whose document is live
    /// in `edit`: that one is *this* session's, which is what makes "edit, then export" export the
    /// edit that is on screen rather than the last committed one.
    public func exportItems(for assets: [Asset]) -> [ExportItem] {
        assets.map { asset in
            let document: EditModel
            if asset.id == loadedEditAssetID {
                document = MaskViewState.documentOnly(edit)
            } else if let catalog, let stored = try? catalog.develop(forAsset: asset.id) {
                document = MaskViewState.documentOnly(stored)
            } else {
                document = .neutral
            }
            return ExportItem(id: asset.id,
                              name: (asset.filename as NSString).deletingPathExtension,
                              captureDate: Self.captureDate(asset.captureTime),
                              rating: asset.rating,
                              edit: document,
                              sourceURL: fileURL(for: asset))
        }
    }

    /// `assets.capture_time` is ISO8601 UTC. `{date}` in a name template wants a `Date`.
    static func captureDate(_ iso: String?) -> Date? {
        guard let iso, !iso.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let date = f.date(from: iso) { return date }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: iso)
    }

    // MARK: - Saving edits (477)

    /// The photos a save/thumbnail command applies to: the selection, or the anchor when nothing is
    /// selected. Unlike the old automatic writer this includes **non-DNG** sources — 保存 writes a
    /// sidecar for those.
    public var dngTargetAssets: [Asset] {
        let ids = selection.isEmpty ? Set([anchorID].compactMap { $0 }) : selection
        return assets.filter { ids.contains($0.id) }
    }

    /// Only the DNGs in the target set. `更新缩略图` is unavailable without at least one.
    public var dngOnlyTargets: [Asset] {
        dngTargetAssets.filter { $0.ext.lowercased() == "dng" }
    }

    /// Does the current target have a DNG to act on? The thumbnail menu's grey rule.
    public var hasDNGTarget: Bool { !dngOnlyTargets.isEmpty }

    /// A one-sentence reason for a greyed 更新缩略图 row, or `nil` when it is usable.
    public var thumbnailUnavailableReason: String? {
        guard let first = dngTargetAssets.first else { return Loc.t("没有选中的照片") }
        if dngOnlyTargets.isEmpty {
            return Loc.t("{0} 不是 DNG，无法写内嵌缩略图", String(describing: (first.filename)))
        }
        return nil
    }

    /// 477 — the document a save should carry. The live document for the loaded photo (so ⌘S right
    /// after a slider writes what is on screen), the stored row for every other photo.
    private func documentForSave(assetID: String) -> EditModel? {
        if assetID == loadedEditAssetID { return MaskViewState.documentOnly(edit) }
        if let catalog, let stored = try? catalog.develop(forAsset: assetID) {
            return MaskViewState.documentOnly(stored)
        }
        guard let asset = assets.first(where: { $0.id == assetID }),
              let data = asset.developJson.data(using: .utf8),
              let model = try? JSONDecoder().decode(EditModel.self, from: data) else { return nil }
        return MaskViewState.documentOnly(model)
    }

    /// 文件 ▸ 保存 (⌘S) / 右键 ▸ 保存 — **只写 XMP，不碰缩略图**. DNG gets tag 700; every other
    /// source gets `‹original›.xmp` next to it. Asynchronous so a multi-selection of 60 MB originals
    /// does not block the UI; `saveEditsNow` is the synchronous door tests use.
    public func saveEditsToFiles() {
        let targets = dngTargetAssets
        guard !targets.isEmpty else {
            lastDNGError = Loc.t("没有可保存的照片")
            return
        }
        let queue = dngWriteQueue
        let journal = dngJournal
        for asset in targets {
            guard let document = documentForSave(assetID: asset.id),
                  let url = fileURL(for: asset) else {
                lastDNGError = Loc.t("照片文件不在原位置")
                continue
            }
            queue.async {
                let result = Self.performSave(asset: asset, url: url, document: document,
                                              journal: journal)
                Task { @MainActor [weak self] in self?.recordDNG(result) }
            }
        }
    }

    /// Synchronous save for tests and callers that already own the document.
    @discardableResult
    public func saveEditsNow(assetID: String) -> Bool {
        guard let asset = assets.first(where: { $0.id == assetID }) else {
            lastDNGError = Loc.t("找不到这张照片")
            return false
        }
        guard let url = fileURL(for: asset), let document = documentForSave(assetID: asset.id) else {
            lastDNGError = Loc.t("照片文件不在原位置")
            return false
        }
        let result = Self.performSave(asset: asset, url: url, document: document, journal: dngJournal)
        recordDNG(result)
        return !result.failed
    }

    /// 右键 ▸ 更新缩略图 (also 文件 ▸ 更新缩略图). Slow on purpose: decode + render + JPEG + IFD.
    /// Non-DNG is grey at the menu and skipped here with the same sentence.
    public func updateThumbnailsForSelection() {
        let targets = dngTargetAssets
        guard !targets.isEmpty else {
            lastDNGError = Loc.t("没有可更新缩略图的照片")
            return
        }
        let queue = dngWriteQueue
        let journal = dngJournal
        for asset in targets {
            guard asset.ext.lowercased() == "dng" else {
                dngWriteStats.skipped += 1
                lastDNGError = thumbnailUnavailableReason
                continue
            }
            guard let document = documentForSave(assetID: asset.id),
                  let url = fileURL(for: asset) else { continue }
            queue.async {
                let result = Self.performThumbnailWrite(url: url, document: document, journal: journal)
                Task { @MainActor [weak self] in self?.recordDNG(result) }
            }
        }
    }

    /// Synchronous thumbnail update for tests.
    @discardableResult
    public func updateThumbnailNow(assetID: String) -> Bool {
        guard let asset = assets.first(where: { $0.id == assetID }) else {
            lastDNGError = Loc.t("找不到这张照片")
            return false
        }
        guard asset.ext.lowercased() == "dng" else {
            dngWriteStats.skipped += 1
            lastDNGError = Loc.t("{0} 不是 DNG，无法写内嵌缩略图", String(describing: (asset.filename)))
            return false
        }
        guard let url = fileURL(for: asset), let document = documentForSave(assetID: asset.id) else {
            lastDNGError = Loc.t("照片文件不在原位置")
            return false
        }
        let result = Self.performThumbnailWrite(url: url, document: document, journal: dngJournal)
        recordDNG(result)
        return !result.failed
    }

    // MARK: - explicit read / undo doors (kept off the main menu)

    /// 从 DNG 读取编辑 — the explicit 「用 XMP 覆盖当前照片的 DB 行」 door. The window asks first.
    @discardableResult
    public func readEditFromDNG(for assetID: String) -> Bool {
        guard let asset = assets.first(where: { $0.id == assetID }),
              asset.ext.lowercased() == "dng",
              let url = fileURL(for: asset) else {
            lastDNGError = Loc.t("当前照片不是 DNG")
            return false
        }
        do {
            guard let text = try DNGXMP.documentString(at: url), !text.isEmpty else {
                lastDNGError = Loc.t("这张 DNG 里没有 photons:document")
                return false
            }
            let model = try JSONDecoder().decode(EditModel.self, from: Data(text.utf8))
            guard let catalog else { throw DNGXMP.Failure.writeFailed("没有打开的库") }
            let json = try Catalog.encode(model)
            let stamp = ISO8601.now()
            try catalog.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM asset_history WHERE asset_id = ?", arguments: [assetID])
                try db.execute(sql: """
                    UPDATE assets SET develop_json = ?, develop_version = develop_version + 1,
                                      edit_time = ?, history_end = 0
                    WHERE id = ?
                    """, arguments: [json, stamp, assetID])
            }
            if let index = assets.firstIndex(where: { $0.id == assetID }) {
                assets[index].developJson = json
                assets[index].developVersion += 1
                assets[index].editTime = stamp
                assets[index].historyEnd = 0
            }
            if loadedEditAssetID == assetID || anchorID == assetID {
                loadEditForAnchor(force: true)
            }
            dngWriteStats.readsFromDNG += 1
            lastDNGError = nil
            return true
        } catch {
            lastDNGError = Self.dngSentence(error)
            return false
        }
    }

    /// 撤销 DNG 里的上次写入 — restores the header `DNGXMP` journaled. Synchronous: 8 bytes.
    @discardableResult
    public func undoLastDNGWriteForSelection() -> Bool {
        var restored = 0
        for asset in dngOnlyTargets {
            guard let url = fileURL(for: asset) else { continue }
            do {
                try DNGXMP.undo(at: url, journal: dngJournal)
                restored += 1
            } catch {
                lastDNGError = Self.dngSentence(error)
            }
        }
        dngWriteStats.undos += restored
        return restored > 0
    }

    // MARK: - audit backfill

    /// 477 — rows whose `develop_json` is empty/`{}` or will not decode get one chance from the
    /// DNG's own XMP. The library stays the only truth: a row with a real document is never read
    /// from the file, and a row that changed while this scan ran is not overwritten.
    public func backfillEditsFromXMP(completion: ((Int) -> Void)? = nil) {
        guard let catalog else {
            completion?(0)
            return
        }
        let rows = (try? catalog.assets(AssetFilter(limit: 200_000))) ?? []
        var targets: [(id: String, url: URL, original: String)] = []
        for asset in rows where asset.ext.lowercased() == "dng" {
            guard !hasUsableDevelop(asset.developJson),
                  let url = try? catalog.fileURL(for: asset) else { continue }
            targets.append((asset.id, url, asset.developJson))
        }
        guard !targets.isEmpty else {
            completion?(0)
            return
        }
        let audit = dngAuditLog
        let queue = dngWriteQueue
        queue.async {
            var found: [(id: String, json: String, path: String, original: String)] = []
            for target in targets {
                guard let text = try? DNGXMP.documentString(at: target.url),
                      let model = try? JSONDecoder().decode(EditModel.self, from: Data(text.utf8)),
                      let json = try? Catalog.encode(model) else { continue }
                found.append((target.id, json, target.url.path, target.original))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let n = self.applyBackfill(found, catalog: catalog, audit: audit)
                completion?(n)
            }
        }
    }

    private func hasUsableDevelop(_ json: String) -> Bool {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "{}" else { return false }
        return (try? JSONDecoder().decode(EditModel.self, from: Data(trimmed.utf8))) != nil
    }

    private func applyBackfill(_ found: [(id: String, json: String, path: String, original: String)],
                               catalog: Catalog, audit: DNGXPMAuditLog) -> Int {
        var applied = 0
        let stamp = ISO8601.now()
        for entry in found {
            do {
                let changed = try catalog.dbQueue.write { db -> Int in
                    try db.execute(sql: """
                        UPDATE assets SET develop_json = ?, develop_version = develop_version + 1,
                                          edit_time = ?
                        WHERE id = ? AND develop_json = ?
                        """, arguments: [entry.json, stamp, entry.id, entry.original])
                    return db.changesCount
                }
                guard changed > 0 else { continue }
                if let index = assets.firstIndex(where: { $0.id == entry.id }),
                   assets[index].developJson == entry.original {
                    assets[index].developJson = entry.json
                    assets[index].developVersion += 1
                    assets[index].editTime = stamp
                }
                audit.append(source: "xmp", assetID: entry.id, path: entry.path)
                applied += 1
            } catch {
                lastDNGError = Self.dngSentence(error)
            }
        }
        dngWriteStats.backfills += applied
        return applied
    }

    // MARK: - the two writers (off main)

    /// Save = one tag write for DNG, one small file for anything else. Never decodes and never
    /// re-encodes a JPEG.
    nonisolated static func performSave(asset: Asset, url: URL, document: EditModel,
                                        journal: DNGXMPJournal) -> DNGWriteResult {
        var result = DNGWriteResult()
        do {
            let text = try Catalog.encode(document)
            if asset.ext.lowercased() == "dng" {
                let existing = (try? DNGXMP.documentString(at: url)) ?? nil
                if existing != text {
                    let outcome = try DNGXMP.writeDocument(text, to: url, journal: journal)
                    result.wroteXMP = true
                    result.reusedSlot = outcome.reusedSlot
                    result.appendedBytes = outcome.appendedBytes
                }
            } else {
                let outcome = try DNGXMP.writeSidecar(document: text, for: url)
                result.wroteSidecar = outcome.wrote
                result.appendedBytes = outcome.bytes
            }
        } catch {
            result.failed = true
            result.error = dngSentence(error)
        }
        return result
    }

    nonisolated static func performThumbnailWrite(url: URL, document: EditModel,
                                                   journal: DNGXMPJournal) -> DNGWriteResult {
        var result = DNGWriteResult()
        do {
            let (jpeg, size) = try makeDNGThumbnailJPEG(url: url, document: document)
            let old = (try? DNGThumbnail.embeddedPreviewJPEG(at: url)) ?? nil
            if old != jpeg {
                let outcome = try DNGThumbnail.write(jpeg, size: size, to: url, journal: journal)
                result.wroteThumbnail = true
                result.thumbnailInPlace = outcome.replacedInPlace
                result.thumbnailBytes = outcome.appendedBytes
                result.thumbnailSize = ImageSize(width: outcome.width, height: outcome.height)
            }
        } catch {
            result.failed = true
            result.error = dngSentence(error)
        }
        return result
    }

    /// 477 — render the cropped picture at the thumbnail's size. One decode at the scale the target
    /// needs, one graph frame, one JPEG. This is why 更新缩略图 is a separate command.
    nonisolated static func makeDNGThumbnailJPEG(url: URL,
                                                 document: EditModel) throws -> (Data, ImageSize) {
        // The full source size decides the crop's output pixels; a 0.25 proxy cannot answer it.
        let fullSource = DNGThumbnail.mainImagePixelSize(at: url)
            ?? ImageSize(width: 1, height: 1)
        let cropCanvas = CropGeometry(geometry: document.geometry, source: fullSource).canvas
        let target = DNGThumbnail.targetSize(forCrop: cropCanvas)
        let cropLong = max(cropCanvas.width, cropCanvas.height, 1)
        let decodeScale = Float(min(1.0, max(0.25, Double(max(target.width, target.height)) / Double(cropLong))))
        let inputs = document.decodeInputs
        let decoded = try RAWDecoder().decode(url, options: DecodeOptions(
            decoderVersion: inputs.decoderVersion,
            scale: decodeScale,
            whiteBalance: inputs.whiteBalance,
            detail: inputs.detail))
        let decodedSize = ImageSize(width: decoded.uprightSize.width, height: decoded.uprightSize.height)
        let proxyScale = Double(decodedSize.width) / Double(max(fullSource.width, 1))
        let scale = Double(target.width)
            / (Double(max(cropCanvas.width, 1)) * max(proxyScale, 0.01))
        let graph = try RenderGraph(input: RenderInput(image: decoded,
                                                       identity: "dng-thumb|\(url.path)|\(target.keyString)",
                                                       sourceURL: url,
                                                       whiteBalance: inputs.whiteBalance),
                                    textureRetention: .none)
        defer { graph.releaseAllTextures() }
        let frame = try graph.render(document, options: RenderOptions(
            canvas: nil,
            scale: max(0.01, scale),
            display: DisplayOptions(primaries: .sRGB, bitDepth: 8, headroom: 1),
            useCache: false,
            wantsPixels: true))
        guard let display = frame.display else {
            throw DNGThumbnail.Failure.encodeFailed("渲染没有返回像素")
        }
        let cg = try Exporter.cgImage(display, bitDepth: 8)
        guard let jpeg = DNGThumbnail.jpegData(from: cg, targetSize: target) else {
            throw DNGThumbnail.Failure.encodeFailed("\(target.width)×\(target.height)")
        }
        return (jpeg, target)
    }

    private func recordDNG(_ result: DNGWriteResult) {
        if result.skipped { dngWriteStats.skipped += 1 }
        if result.wroteXMP {
            dngWriteStats.xmpWrites += 1
            if result.reusedSlot { dngWriteStats.reusedSlots += 1 }
            dngWriteStats.appendedBytes += result.appendedBytes
        }
        if result.wroteSidecar { dngWriteStats.sidecarWrites += 1 }
        if result.wroteThumbnail { dngWriteStats.thumbnailWrites += 1 }
        if result.failed {
            dngWriteStats.failures += 1
            lastDNGError = result.error
        } else if result.wroteXMP || result.wroteSidecar || result.wroteThumbnail {
            lastDNGError = nil
        }
    }

    nonisolated static func dngSentence(_ error: Error) -> String {
        (error as? CustomStringConvertible)?.description ?? error.localizedDescription
    }

    // MARK: paths

    public func fileURL(for asset: Asset) -> URL? {
        try? catalog?.fileURL(for: asset)
    }

    public var currentPhotoURL: URL? {
        guard let a = anchorAsset else { return nil }
        return fileURL(for: a)
    }
}
