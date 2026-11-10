import AppKit
import Foundation

/// 352 — the click rule the filmstrip and the left photo list both obey.
///
/// User's report: one click already switches photo, 332's centred scroll then slides the grid so the
/// cell sits *under the pointer*, and the second click of a double-click therefore lands on the
/// **next** photo. So a double-click becomes "jump one photo to the right".
///
/// Two halves, one object, because both browsers need both:
///
/// 1. **Press-time identity + swallow.** `mouseDown` records the hit (index + asset id) and when it
///    happened. A second press inside `NSEvent.doubleClickInterval` that hits a **different** cell is
///    swallowed whole (`.swallow`: no selection, no photo switch, no re-layout). The same cell twice
///    is a double-click (`.doubleClick`) and keeps its meaning (open in loupe). The window is read
///    from `NSEvent.doubleClickInterval` every time — never a hard-coded 250 ms.
/// 2. **Deferred centre.** A selection does not centre immediately any more: the centre is parked on
///    `pendingCenter` for one double-click window, so the strip cannot slide out from under the
///    second press. A double-click flushes it once (centre only, selection untouched); a manual
///    scroll by the user drops it (`dropCount`), because 332 already decided the user wins.
///
/// The controllers supply three things and share everything else: the hit-test (`hit(at:)`), the
/// verb that centres now (`onCenter`), and the verb that settles an anchor without moving anything
/// (`onCenterDropped`). No second copy of the state machine — see `FilmstripController` and
/// `BrowserPaneController`, whose `centerAnchorIfChanged` both ask `isCenterDeferred(_:)`.
@MainActor
public final class BrowserClickGuard {

    /// What a press means, decided before AppKit is allowed to select anything.
    public enum Decision: String, Equatable {
        /// A first press (or a press after the window closed): let the normal click through.
        case forward
        /// Second press on the **same** cell: a double-click; its verb runs as it always did.
        case doubleClick
        /// Second press inside the window on a **different** cell: eat the whole press.
        case swallow
    }

    /// The cell a press landed on, by index **and** identity — the index is what the test prints, the
    /// asset id is what the user actually chose (a re-sort between two presses moves the index).
    public struct Hit: Equatable {
        public var index: Int
        public var assetID: String

        public init(index: Int, assetID: String) {
            self.index = index
            self.assetID = assetID
        }
    }

    /// `NSEvent.doubleClickInterval` in the app (0.5 s by default, whatever 系统设置 says). A test
    /// replaces it to prove the window is read, not assumed; nothing here hard-codes a duration.
    public var doubleClickInterval: () -> TimeInterval = { NSEvent.doubleClickInterval }

    // MARK: press-time state (what the acceptance read-back quotes)

    /// The cell the **current** press sequence started on — `hitItemAtMouseDown`, by identity.
    public private(set) var hitAtMouseDown: Hit?
    /// When that press happened.
    public private(set) var hitAtMouseDownTime: Date?
    /// The second press of a pair has been resolved; the next press starts a new pair.
    public private(set) var pairResolved = false
    /// The last decision, for a test that only wants to know what happened.
    public private(set) var lastDecision: Decision?
    public private(set) var forwardCount = 0
    public private(set) var doubleClickCount = 0
    public private(set) var swallowCount = 0

    // MARK: deferred centre

    /// The centre that is waiting for the click window to close. `nil` when nothing is pending.
    public private(set) var pendingCenter: DispatchWorkItem?
    private var pendingCenterToken = UUID()
    /// Which anchor that pending centre is for — the id `isCenterDeferred(_:)` compares against.
    public private(set) var pendingCenterAnchorID: String?
    /// How long the parked centre was told to wait (== `doubleClickInterval()` at schedule time).
    public private(set) var pendingCenterDelay: TimeInterval = 0
    public private(set) var lastCenterScheduledAt: Date?
    /// When the parked centre actually ran — the acceptance ③ timestamp.
    public private(set) var lastCenterFiredAt: Date?
    public private(set) var centerScheduledCount = 0
    public private(set) var centerFiredCount = 0
    public private(set) var centerFlushedCount = 0
    public private(set) var centerDropCount = 0

    /// Centre now, for this anchor. Supplied by the controller (it owns the scroll view).
    public var onCenter: ((String) -> Void)?
    /// The parked centre was thrown away because the user scrolled — settle this anchor so a later
    /// model tick does not pull the view back.
    public var onCenterDropped: ((String) -> Void)?

    public init() {}

    // MARK: - the press

    /// Record the press and say what it means.
    ///
    /// - Parameter hit: the cell under the pointer **at press time**, or `nil` for empty space.
    public func mouseDown(hit: Hit?, now: Date = Date()) -> Decision {
        guard let hit else {
            clearPress()
            forwardCount += 1
            lastDecision = .forward
            return .forward
        }

        if !pairResolved, let first = hitAtMouseDown, let at = hitAtMouseDownTime {
            let elapsed = now.timeIntervalSince(at)
            if elapsed >= 0, elapsed <= doubleClickInterval() {
                pairResolved = true
                if first.index == hit.index, first.assetID == hit.assetID {
                    doubleClickCount += 1
                    lastDecision = .doubleClick
                    // 仍然只居中，不改选中: the pair is over, so the parked centre runs now instead
                    // of a window later. The double-click's own verb (loupe) is AppKit's.
                    flushCenter()
                    return .doubleClick
                }
                // The strip slid under the pointer between the two presses (332's centre, momentum,
                // a model re-sort). Eat this press rather than switching to the photo that drifted
                // into place.
                swallowCount += 1
                lastDecision = .swallow
                return .swallow
            }
        }

        // A first press, or the window had already closed: the photo switches now, the centre waits.
        hitAtMouseDown = hit
        hitAtMouseDownTime = now
        pairResolved = false
        forwardCount += 1
        lastDecision = .forward
        scheduleCenter(for: hit.assetID, now: now)
        return .forward
    }

    /// The photo a double-click means: the cell the **first** press hit, as long as that press is
    /// still the one being answered. `fallback` is what AppKit resolved on its own (`clickedRow`,
    /// the gesture's location) and is used for a keyboard-triggered double-click or after the window.
    public func openTargetID(fallback: String, now: Date = Date()) -> String {
        guard let hit = hitAtMouseDown, let at = hitAtMouseDownTime else { return fallback }
        let elapsed = now.timeIntervalSince(at)
        guard elapsed >= 0, elapsed <= doubleClickInterval() else { return fallback }
        return hit.assetID
    }

    private func clearPress() {
        hitAtMouseDown = nil
        hitAtMouseDownTime = nil
        pairResolved = false
    }

    // MARK: - the parked centre

    /// True while the centre for `anchorID` belongs to the parked one. Both controllers' anchor
    /// trigger asks this before scrolling, so a model tick inside the window cannot jump the queue.
    public func isCenterDeferred(_ anchorID: String?) -> Bool {
        guard let anchorID, let pending = pendingCenterAnchorID else { return false }
        return pending == anchorID
    }

    public var hasPendingCenter: Bool { pendingCenter != nil }

    /// Park this selection's centre for one double-click window.
    public func scheduleCenter(for anchorID: String, now: Date = Date()) {
        pendingCenter?.cancel()
        let delay = doubleClickInterval()
        pendingCenterDelay = delay
        pendingCenterAnchorID = anchorID
        lastCenterScheduledAt = now
        centerScheduledCount += 1
        let token = UUID()
        pendingCenterToken = token
        let work = DispatchWorkItem { [weak self] in self?.firePendingCenter(token: token) }
        pendingCenter = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Run the parked centre **now** — a double-click's worth of "settle this photo", still only a
    /// centre: the selection is not touched.
    public func flushCenter() {
        guard pendingCenter != nil else { return }
        pendingCenter?.cancel()
        pendingCenter = nil
        pendingCenterToken = UUID()
        centerFlushedCount += 1
        lastCenterFiredAt = Date()
        let id = pendingCenterAnchorID
        pendingCenterAnchorID = nil
        if let id { onCenter?(id) }
    }

    /// Drop the parked centre: the user scrolled, and 332 already ruled that the user wins.
    public func dropCenter() {
        guard pendingCenter != nil else { return }
        pendingCenter?.cancel()
        pendingCenter = nil
        pendingCenterToken = UUID()
        let id = pendingCenterAnchorID
        pendingCenterAnchorID = nil
        centerDropCount += 1
        if let id { onCenterDropped?(id) }
    }

    /// Called from the controllers' bounds-changed observer: the clip view moved, and `noteChange`
    /// already decided whether that was the user or our own animation (`Activity`).
    public func noteUserScroll(_ isUserChange: Bool) {
        guard isUserChange else { return }
        dropCenter()
    }

    private func firePendingCenter(token: UUID) {
        guard token == pendingCenterToken, pendingCenter != nil else { return }
        pendingCenter = nil
        let id = pendingCenterAnchorID
        pendingCenterAnchorID = nil
        centerFiredCount += 1
        lastCenterFiredAt = Date()
        if let id { onCenter?(id) }
    }
}
