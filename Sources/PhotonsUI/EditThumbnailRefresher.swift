import Foundation

/// 303 — coalesce document edits into one HD thumbnail refresh.
///
/// A slider tick bumps `editRevision` on every mouse move. Re-rendering the 1920-long-edge PQ HEIC
/// on each of those ticks would spend the whole drag re-encoding frames nobody sees, so the three
/// browsers ask for a refresh only after the last edit in a `delay`-long window. Consecutive calls
/// (a drag, a paste over several photos) therefore produce exactly one callback, for the **last**
/// asset touched.
///
/// Everything is injected: the scheduler makes the window testable without sleeping, and `refresh`
/// is the closure `WorkspaceRootView` wires to the grid, the browser list and the filmstrip.
@MainActor
public final class EditThumbnailRefresher {
    /// Schedules `action` after `delay` seconds. Production uses the main queue; tests fire it by hand.
    public typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void

    /// Mutable, non-isolated state: the scheduled closure must not touch the `@MainActor` class
    /// itself, or it would need a hop back to the main actor just to read two fields.
    private final class State {
        var pendingAssetID: String?
        var generation = 0
    }

    private let delay: TimeInterval
    private let scheduler: Scheduler
    private let refresh: (String) -> Void
    private let state = State()

    public init(delay: TimeInterval = 0.25,
                scheduler: @escaping Scheduler = { delay, action in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
                },
                refresh: @escaping (String) -> Void) {
        self.delay = delay
        self.scheduler = scheduler
        self.refresh = refresh
    }

    /// The asset whose refresh is waiting for the window to close, or `nil` when nothing is pending.
    public var pendingAssetID: String? { state.pendingAssetID }

    /// Note one more edit. Each call restarts the window; only the last asset of the window is
    /// refreshed, and the callback runs exactly once.
    public func noteEdit(assetID: String) {
        state.pendingAssetID = assetID
        state.generation &+= 1
        let generation = state.generation
        scheduler(delay) { [state, refresh] in
            // A later `noteEdit` already superseded this window, so this closure must do nothing.
            guard state.generation == generation, let assetID = state.pendingAssetID else { return }
            state.pendingAssetID = nil
            refresh(assetID)
        }
    }
}
