import AppKit
import QuartzCore

/// 332 — one rule for keeping the anchor photo in the middle of a browser.
///
/// The filmstrip scrolls horizontally through an `NSCollectionViewFlowLayout`; the left photo list
/// scrolls vertically through an `NSTableView`'s rows. The geometry each has to read is different,
/// the sentence they obey is not:
///
///     offset = item.mid − visible/2, clamped to [0, content − visible]
///
/// The clamp is what makes the first and last photos sit flush against the ends instead of
/// scrolling blank space into view, and this file is the *only* place either controller works out a
/// scroll target — no second copy of the arithmetic, no second animation.
///
/// The animation is `animator().setBoundsOrigin`, i.e. the scroll view's own machinery: inertia,
/// scrollbars, elastic edges and zoom keep behaving exactly as they did. 0.22 s `.easeInEaseOut` is
/// long enough to read as motion and short enough that a slider release does not appear to lag.
@MainActor
public enum CenteredScroll {
    public enum Axis { case horizontal, vertical }

    /// The window a centred scroll takes, and the duration the tests measure against.
    public static let duration: TimeInterval = 0.22
    /// Within this many points the view is already where it would go — animating would be jitter.
    public static let tolerance: CGFloat = 2
    /// A bounds change this recent belongs to the user; see `Activity`.
    public static let userActivityWindow: TimeInterval = 0.12

    /// `itemMidpoint` clipped so the viewport never leaves `[0, content − visible]`.
    public static func target(itemMidpoint: CGFloat,
                              contentLength: CGFloat,
                              visibleLength: CGFloat) -> CGFloat {
        let last = max(0, contentLength - visibleLength)
        return min(max(itemMidpoint - visibleLength / 2, 0), last)
    }

    public static func offset(of clip: NSClipView, axis: Axis) -> CGFloat {
        axis == .horizontal ? clip.bounds.origin.x : clip.bounds.origin.y
    }

    /// The clip view's origin with one axis replaced — the other axis is left exactly as it was.
    public static func origin(of clip: NSClipView, offset: CGFloat, axis: Axis) -> NSPoint {
        var point = clip.bounds.origin
        switch axis {
        case .horizontal: point.x = offset
        case .vertical: point.y = offset
        }
        return point
    }

    /// Scrolls `scrollView` so `offset` is the viewport's leading edge.
    ///
    /// - Returns: `true` when this call actually started a scroll. Already-centred (≤ 2 pt) is
    ///   `false`, which is what 332's "0 次" counter counts.
    /// - Parameter recorder: receives the `NSAnimationContext` duration the animation was given, so
    ///   a test can assert "duration > 0 during the call" without reaching into AppKit.
    @discardableResult
    public static func scroll(_ scrollView: NSScrollView,
                              axis: Axis,
                              to offset: CGFloat,
                              activity: Activity?,
                              reduceMotion: Bool,
                              recorder: ((TimeInterval) -> Void)? = nil) -> Bool {
        let clip = scrollView.contentView
        guard abs(Self.offset(of: clip, axis: axis) - offset) > tolerance else { return false }
        let destination = Self.origin(of: clip, offset: offset, axis: axis)

        // The user's own scrolling is never overwritten, and a jump must not be mistaken for one.
        activity?.beginOwnChange()

        if reduceMotion {
            clip.setBoundsOrigin(destination)
            return true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            recorder?(context.duration)
            clip.animator().setBoundsOrigin(destination)
        }
        return true
    }

    // MARK: - telling the user's scrolling from ours

    /// Notes when a clip view moved **without** us moving it.
    ///
    /// The bounds-changed notification cannot tell a drag, a wheel burst and momentum scrolling from
    /// our own `animator()` call — all four are `NSView.boundsDidChangeNotification`. So the two
    /// controllers already observe that notification for thumbnails; this object rides the same
    /// observation and remembers "the user moved this 0.05 s ago", which is the only signal AppKit
    /// gives a scroll view for momentum (there is no public `isScrolling`). While we are the ones
    /// scrolling, changes are ignored, so an animation can never make the next trigger look user-driven.
    public final class Activity {
        private var lastUserChange: Date?
        /// Set while our own animation is in flight; the completion handler of that animation is
        /// not guaranteed to run when the window is not on screen, so this is a deadline, not a flag.
        private var ownChangeUntil: Date?

        public init() {}

        /// When the user last moved this scroll view, or `nil` if they never have.
        public var lastUserChangeAt: Date? { lastUserChange }

        /// Called from the bounds-changed observer, for every change — ours or the user's.
        public func noteChange(now: Date = Date()) {
            if let until = ownChangeUntil, now < until { return }
            lastUserChange = now
        }

        /// Arm the window during which a bounds change is ours.
        func beginOwnChange(now: Date = Date()) {
            ownChangeUntil = now.addingTimeInterval(CenteredScroll.duration + 0.08)
        }

        /// True while the user is dragging the scroller, live-resizing, or still coasting: this
        /// trigger is dropped rather than fought over.
        public func isUserScrolling(_ scrollView: NSScrollView, now: Date = Date()) -> Bool {
            if scrollView.contentView.inLiveResize { return true }
            for scroller in [scrollView.horizontalScroller, scrollView.verticalScroller] {
                if let scroller, scroller.hitPart != .noPart { return true }
            }
            if let last = lastUserChange,
               now.timeIntervalSince(last) < CenteredScroll.userActivityWindow { return true }
            return false
        }
    }
}
