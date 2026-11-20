import Foundation
import QuartzCore

/// 449 — one coalescer shared by the sidebar, the grid and the filmstrip.
///
/// The old throttle was a **pure trailing** 40 ms debounce: every `boundsDidChange` cancelled the
/// previous work item. A live scroll changes the bounds every frame (16 ms at 60 Hz, 8 ms at
/// 120 Hz), which is always shorter than 40 ms, so the reconcile **never ran during the scroll** —
/// the new band was never computed, the old band was never cancelled and no prefetch was requested
/// until the user stopped. That is exactly the reported "continuous scrolling does not load".
///
/// The fix is the same gate on all three surfaces:
///
/// * **leading**: if at least `trailingDelay` (40 ms) has passed since the last run, run on the next
///   run-loop turn instead of waiting for the scroll to stop;
/// * **trailing**: otherwise coalesce for at most `trailingDelay` (40 ms), restarted by each new
///   `note()`;
/// * **max latency**: from the first `note()`, a pass that has not been served for `maxLatency`
///   (120 ms) is forced. A continuous 8 ms scroll therefore still reconciles roughly every 120 ms.
///
/// All calls are on the main thread; the gate owns only scheduling, never the band arithmetic.
@MainActor
final class ScrollReconcileGate {
    /// How long an otherwise-unserved change may be coalesced. 449 §2.1.
    static let trailingDelay: TimeInterval = 0.04
    /// Upper bound on how long a continuous scroll may go without a reconcile. 449 §2.1.
    static let maxLatency: TimeInterval = 0.12

    private let now: () -> TimeInterval
    private var pending: DispatchWorkItem?
    private var pendingWork: (() -> Void)?
    private var pendingIsLeading = false
    /// Guards against a cancelled-but-already-enqueued item firing after a newer arm.
    private var generation = 0
    private var firstNoteAt: TimeInterval?
    private var lastRunAt: TimeInterval = -.infinity

    /// How many times the gate actually ran its work. Internal, read by the 449 acceptance.
    private(set) var runCount = 0

    init(now: @escaping () -> TimeInterval = { CACurrentMediaTime() }) {
        self.now = now
    }

    /// Record that the visible range may have changed. The first note starts the 120 ms cap.
    func note() {
        let t = now()
        if firstNoteAt == nil { firstNoteAt = t }
        // A trailing pass is restarted by each new note; the 120 ms cap still bounds it.
        guard let work = pendingWork, pending != nil, !pendingIsLeading else { return }
        armTrailing(work, at: t)
    }

    /// Arrange for `work` to run with leading-edge + trailing coalescing and a 120 ms ceiling.
    func schedule(_ work: @escaping () -> Void) {
        pendingWork = work
        let t = now()
        if firstNoteAt == nil { firstNoteAt = t }
        if t - lastRunAt >= Self.trailingDelay {
            armLeading(work)
        } else {
            armTrailing(work, at: t)
        }
    }

    /// Drop any scheduled pass (used when a controller is reset or a test wants the queue quiet).
    func cancelPending() {
        generation += 1
        pending?.cancel()
        pending = nil
        pendingWork = nil
        pendingIsLeading = false
        firstNoteAt = nil
    }

    /// 449 acceptance hook.
    func resetRunCountForTesting() { runCount = 0 }

    private func armLeading(_ work: @escaping () -> Void) {
        pending?.cancel()
        generation += 1
        let gen = generation
        pendingIsLeading = true
        let item = DispatchWorkItem { [weak self] in self?.fire(work, generation: gen) }
        pending = item
        DispatchQueue.main.async(execute: item)
    }

    private func armTrailing(_ work: @escaping () -> Void, at t: TimeInterval) {
        pending?.cancel()
        generation += 1
        let gen = generation
        pendingIsLeading = false
        // `note()` and `schedule()` arrive as a pair on every bounds change, so the 400 ms scroll
        // in the acceptance restarts this deadline every 8 ms; only the cap below lets it run.
        let cap = (firstNoteAt ?? t) + Self.maxLatency
        let deadline = min(t + Self.trailingDelay, cap)
        let delay = max(0, deadline - t)
        let item = DispatchWorkItem { [weak self] in self?.fire(work, generation: gen) }
        pending = item
        if delay <= 0 {
            DispatchQueue.main.async(execute: item)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        }
    }

    private func fire(_ work: @escaping () -> Void, generation gen: Int) {
        guard gen == generation else { return }
        pending = nil
        pendingWork = nil
        pendingIsLeading = false
        firstNoteAt = nil
        lastRunAt = now()
        runCount += 1
        work()
    }
}
