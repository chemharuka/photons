import Foundation
import Observation

/// 454 P1 — the value type behind 顶栏「排序 | 后台」 and the future background-task panel.
///
/// P1 deliberately ships **no producer**: export still runs from its sheet, denoise/HDR keep their
/// session-owned serial queues, and neither of those paths knows this type exists. The only job here
/// is to let 「任务」 exist as data that can be written and drawn, so P2/P3 can connect the queues
/// without changing the model again.
public struct BackgroundTask: Identifiable, Equatable, Sendable {

    /// The four kinds the owner named. `panorama` is a placeholder: the feature has no producer yet.
    public enum Kind: String, CaseIterable, Equatable, Sendable {
        case denoise
        case hdrMerge
        case export
        case panorama
    }

    /// Terminal states are `finished` / `cancelled` / `failed`. A task is in flight while `queued`
    /// or `running`.
    public enum State: String, CaseIterable, Equatable, Sendable {
        case queued
        case running
        case finished
        case cancelled
        case failed

        public var isTerminal: Bool {
            switch self {
            case .finished, .cancelled, .failed: return true
            case .queued, .running: return false
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var total: Int
    public var completed: Int
    /// The photo currently being worked on, if the producer knows it.
    public var currentAssetID: String?
    /// A `ThumbKey`-shaped description of that photo's square thumbnail. P4 is the first phase that
    /// resolves it to real pixels; until then the panel draws a placeholder square.
    public var currentThumbKey: String?
    public var startedAt: Date
    public var state: State
    public var failureCount: Int

    public init(id: UUID = UUID(),
                kind: Kind,
                title: String,
                total: Int,
                completed: Int = 0,
                currentAssetID: String? = nil,
                currentThumbKey: String? = nil,
                startedAt: Date = Date(),
                state: State = .running,
                failureCount: Int = 0) {
        self.id = id
        self.kind = kind
        self.title = title
        self.total = total
        self.completed = completed
        self.currentAssetID = currentAssetID
        self.currentThumbKey = currentThumbKey
        self.startedAt = startedAt
        self.state = state
        self.failureCount = failureCount
    }
}

/// The one store P2/P3 will feed. P1 has no caller that mutates it, so the panel is always empty —
/// which is the phase's acceptance criterion, not an unfinished bit.
///
/// Ordering contract: `tasks` is append order (oldest first); an `advance`/`finish` by `id` updates
/// the existing element in place rather than appending a second one. **Display order** is
/// newest-first and has exactly one source of truth: `displayTasks`. The views (顶栏条 / 面板)
/// must read that property and never reverse `tasks` themselves again.
///
/// 488 — retention is now a display policy of five rows total, not twenty finished rows:
/// `finishedKeep = max(0, 5 − inFlight)`. In-flight tasks may exceed five; as soon as a terminal
/// row would make the retained total larger than five, the oldest terminal row is dropped
/// immediately (on `begin` and on `finish`). Six in-flight tasks therefore keep zero finished rows:
/// completing any one deletes it in the same turn.
@MainActor
@Observable
public final class BackgroundTaskStore {

    /// 488 — the owner's 2026-11-21 rule: at most five retained rows on screen **including** any
    /// in-flight tasks. This is a presentation policy, not a change to `BackgroundTask` itself.
    public static let retainedFinishedLimit = 5

    public private(set) var tasks: [BackgroundTask] = []

    /// Newest-first view for every surface that draws a list (顶栏 1–4 条 and the panel table).
    /// This is the **only** place the stored append order is flipped; reversing again in a view
    /// would silently turn the list back into oldest-first.
    public var displayTasks: [BackgroundTask] { Array(tasks.reversed()) }

    /// How many terminal rows may stay: `max(0, 5 − in-flight)`, capped by the same five.
    /// Six running tasks leave no room for finished rows (`max(0, 5 − 6) == 0`).
    public var finishedKeep: Int {
        let inFlight = tasks.lazy.filter { !$0.state.isTerminal }.count
        return max(0, Self.retainedFinishedLimit - inFlight)
    }

    /// 454 P3 — the cancel handle for a running task. It cannot live in `BackgroundTask`: the value
    /// type is `Sendable` and describes the row, while the action belongs to the producer's thread
    /// (the export `CancellationToken` lives on the main actor).
    private var cancelActions: [UUID: @MainActor () -> Void] = [:]

    /// Instance spelling of the same limit, so callers can ask the store without naming the type.
    public var retainedFinishedLimit: Int { Self.retainedFinishedLimit }

    /// `nonisolated` so a view can default-construct the store in its own initialiser
    /// (`TopBarView(store:)` keeps a zero-argument spelling for tests); the store only starts
    /// touching main-actor state when a caller uses it.
    public nonisolated init() {}

    /// Append a new task and return its id. The caller owns the id for the rest of the run.
    @discardableResult
    public func begin(_ task: BackgroundTask) -> UUID {
        tasks.append(task)
        pruneFinished()
        return task.id
    }

    /// Update one task in place. `nil` arguments leave the corresponding field untouched.
    ///
    /// `completed` is clamped to `0…total`; a queued task becomes `running` on its first progress
    /// report, so a producer never has to send two writes for one step.
    public func advance(id: UUID,
                        completed: Int? = nil,
                        currentAssetID: String? = nil,
                        currentThumbKey: String? = nil) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let total = max(0, tasks[index].total)
        if let completed {
            tasks[index].completed = min(max(0, completed), total)
        }
        if let currentAssetID {
            tasks[index].currentAssetID = currentAssetID
        }
        if let currentThumbKey {
            tasks[index].currentThumbKey = currentThumbKey
        }
        if tasks[index].state == .queued {
            tasks[index].state = .running
        }
    }

    /// 474 — drop the "currently running" photo without touching counts. A batch clears it at the
    /// end (the panel then has no square to draw); a single run keeps the existing P2a behaviour,
    /// where `currentAssetID` records the one photo it worked on.
    public func clearCurrent(id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].currentAssetID = nil
        tasks[index].currentThumbKey = nil
    }

    /// Close a task. `finished` means every item was accounted for, so its count reads `40/40`
    /// without the producer having to send one last `advance`; `cancelled`/`failed` keep the count
    /// they stopped at.
    public func finish(id: UUID, state: BackgroundTask.State = .finished, failureCount: Int = 0) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].state = state
        tasks[index].failureCount = max(0, failureCount)
        if state == .finished {
            tasks[index].completed = max(0, tasks[index].total)
        }
        pruneFinished()
    }

    /// Remember how to stop a running task. The handle is deliberately not part of the value type:
    /// the row knows an id, the producer knows its token.
    public func registerCancel(id: UUID, action: @escaping @MainActor () -> Void) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        cancelActions[id] = action
    }

    /// Run the registered cancel action **once**, then forget it. A second call is a no-op, so a
    /// double-click on the panel's 取消 cannot cancel the producer twice; a terminal task's stale
    /// handle is dropped without running.
    public func cancel(id: UUID) {
        guard let action = cancelActions.removeValue(forKey: id) else { return }
        if let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].state.isTerminal {
            return
        }
        action()
    }

    /// Drop a handle without running it — used when the producer reaches a terminal state on its own.
    public func forgetCancel(id: UUID) {
        cancelActions.removeValue(forKey: id)
    }

    /// Remove every terminal task (finished, cancelled, failed); in-flight tasks stay.
    public func clearFinished() {
        tasks.removeAll { $0.state.isTerminal }
        pruneCancelActions()
    }

    /// `8/40` — the spelling the header row uses. Pure: reads only the value it is given.
    public nonisolated static func countText(for task: BackgroundTask) -> String {
        "\(task.completed)/\(task.total)"
    }

    /// `0…1`. A zero-total finished task counts as complete; everything else with no total is 0.
    public nonisolated static func progressFraction(for task: BackgroundTask) -> Double {
        if task.total <= 0 {
            return task.state == .finished ? 1 : 0
        }
        let raw = Double(task.completed) / Double(task.total)
        return min(1, max(0, raw))
    }

    // Instance spellings keep the store the obvious place to ask, while the static bodies above are
    // the ones a pure-logic test can call without touching the main actor.
    public func countText(for task: BackgroundTask) -> String {
        Self.countText(for: task)
    }

    public func progressFraction(for task: BackgroundTask) -> Double {
        Self.progressFraction(for: task)
    }

    // MARK: retention

    private func pruneFinished() {
        let terminal = tasks.indices.filter { tasks[$0].state.isTerminal }
        // 488 — the total retained rows (in-flight + terminal) may not exceed five. In-flight is
        // counted first, so more than five running tasks legitimately keep no terminal rows.
        let excess = terminal.count - finishedKeep
        guard excess > 0 else { return }

        // Oldest `startedAt` first; equal dates fall back to insertion order so a burst of tasks
        // created in the same clock tick still evicts deterministically.
        let evict = terminal.sorted { lhs, rhs in
            let left = tasks[lhs]
            let right = tasks[rhs]
            if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
            return lhs < rhs
        }.prefix(excess)

        let doomed = Set(evict)
        tasks = tasks.enumerated().filter { !doomed.contains($0.offset) }.map(\.element)
        pruneCancelActions()
    }

    /// A handle is only meaningful while its row exists; eviction and `clearFinished` both drop the
    /// rows, so the dictionary must not keep the producer's closure alive.
    private func pruneCancelActions() {
        let live = Set(tasks.map(\.id))
        cancelActions = cancelActions.filter { live.contains($0.key) }
    }
}
