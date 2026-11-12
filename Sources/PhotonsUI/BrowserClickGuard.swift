import AppKit
import Foundation

/// 383 — the click rule the filmstrip and the left photo list both obey.
///
/// 352 built this object for a bug that no longer exists: one click switched photo **and** 332 slid
/// the browser to centre it, so the cell under the pointer changed between the two halves of a
/// double-click, and the second click landed on the neighbour. 352 answered that with a deferred
/// centre (`pendingCenter`) plus swallowing a second press that hit another cell.
///
/// 383 removed the cause instead: **a click only selects — it neither centres nor changes the view
/// mode** (the filmstrip now behaves exactly like the left photo list). The browser therefore cannot
/// slide out from under the pointer, the second press always lands on the same photo, and the whole
/// deferral + swallow machinery is retired together with the bug.
///
/// What is left is one job: remember the cell a press sequence started on, so the verb a
/// double-click / Return runs opens the photo the **first** press hit (`openTargetID(fallback:)`).
/// The window is read from `NSEvent.doubleClickInterval` every time — never a hard-coded 250 ms — and
/// a second press on a *different* cell is an ordinary second click that takes effect (383 §2.3,
/// 用户已知并接受：快速点两张不同照片 ⇒ 两张都会生效).
@MainActor
public final class BrowserClickGuard {

    /// What a press means, decided before AppKit is allowed to select anything.
    public enum Decision: String, Equatable {
        /// A first press (or a press after the window closed, or the second press of a pair that hit
        /// another cell): let the normal click through.
        case forward
        /// Second press on the **same** cell: a double-click; its verb (loupe) runs as it always did.
        case doubleClick
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

    /// The cell the **current** press sequence started on — `hitItemAtMouseDown`, by identity. It is
    /// what `openTargetID(fallback:)` answers with, and a second press on another cell deliberately
    /// leaves it alone: the pair's target is the photo the user first pointed at.
    public private(set) var hitAtMouseDown: Hit?
    /// When that press happened.
    public private(set) var hitAtMouseDownTime: Date?
    /// The second press of a pair has been resolved; the next press starts a new pair.
    public private(set) var pairResolved = false
    /// The last decision, for a test that only wants to know what happened.
    public private(set) var lastDecision: Decision?
    public private(set) var forwardCount = 0
    public private(set) var doubleClickCount = 0

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
                    // The pair is a double-click. 383: nothing is parked, nothing is flushed — the
                    // gesture's own verb (`activateItem` / `openRowInLoupe`) opens and centres.
                    return .doubleClick
                }
                // A second press on **another** cell. 383 §2.3: nothing slid under the pointer, so
                // this is an ordinary click — it takes effect. The pair keeps its first-press target
                // so a gesture that follows still opens the photo the user started on.
                forwardCount += 1
                lastDecision = .forward
                return .forward
            }
        }

        // A first press, or the window had already closed: this cell becomes the pair's target.
        hitAtMouseDown = hit
        hitAtMouseDownTime = now
        pairResolved = false
        forwardCount += 1
        lastDecision = .forward
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
}
