import AppKit

/// 488 — the 1–4 thin progress lines between 顶栏「后台」 and the right-hand status cluster.
///
/// The owner's 2026-11-21 wording: a line is a 3 pt rounded bar (no knob), grey until it turns
/// blue as the task progresses. New tasks sit at the top, finished tasks stay, at most four lines
/// are drawn (the newest four), and the slot is reserved even when there is no task at all.
///
/// This view is display-only: it never mutates the store, it is the same width as the 后台 button,
/// and `hitTest` returns nil so it cannot steal clicks from the button or the status cluster.
public final class BackgroundTaskBars: NSView {

    public enum Metrics {
        /// 3 pt lines with a 1.5 pt radius, stacked 3 pt apart (owner: 「横线…和滑动条类似只不过没有滑块」).
        public static let barHeight: CGFloat = 3
        public static let cornerRadius: CGFloat = 1.5
        public static let spacing: CGFloat = 3
        /// 488 — 「顶栏的指示条最多展示4条」. The fifth/sixth task still exists in the store; only
        /// the newest four are drawn.
        public static let maximumVisibleBars = 4
        /// 481（用户 2026-11-21「进度条往右边再移动一点点，现在是贴着后台按钮的」）——
        /// 槽位左边缘从「后台」按钮右边缘再让出 **6 pt**，右边缘不动：进度线整体右移一点点、
        /// 长度跟着少一点点，状态簇的宽度预算（从条区右边缘算）不变。
        public static let gapFromButton: CGFloat = 6
        public static let fillColor: NSColor = .systemBlue
        /// `tertiaryLabelColor` at 0.35: dark mode's tertiary label is already a low-contrast grey,
        /// so 0.35 of it stays visible against the header glass without competing with the blue
        /// fill. Hard-coded (instead of `.tertiaryLabelColor`) so the exact track can be asserted.
        public static let trackColor: NSColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.35)
    }

    /// Newest-first, already filtered to rows this view may draw. Fed from `store.displayTasks`.
    private(set) public var visibleTasks: [BackgroundTask] = []
    private var barViews: [BackgroundTaskBarView] = []

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    /// Never take the mouse: the button and the status text on either side keep their hit areas.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `tasks` must be newest-first. Cancelled/failed rows are removed from the group entirely
    /// (the dispatch's §2.1 item 3), then the top four are kept.
    ///
    /// 510 — **queued** rows are not drawn here either: the header bar is 「正在执行的那条 + 已完成
    /// 未过期的」, a request that has not started yet belongs to the panel where its text can say
    /// 「排队中（前面还剩 N 个）」. A 3 pt line with no progress would just look like a stuck job.
    public func update(tasks newestFirst: [BackgroundTask]) {
        let shown = newestFirst
            .filter { $0.state != .cancelled && $0.state != .failed && $0.state != .queued }
            .prefix(Metrics.maximumVisibleBars)
        visibleTasks = Array(shown)

        while barViews.count < visibleTasks.count {
            let bar = BackgroundTaskBarView()
            addSubview(bar)
            barViews.append(bar)
        }
        for (index, task) in visibleTasks.enumerated() {
            barViews[index].isHidden = false
            barViews[index].configure(task: task)
        }
        for index in visibleTasks.count..<barViews.count {
            barViews[index].isHidden = true
        }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        guard !visibleTasks.isEmpty else { return }
        let count = CGFloat(visibleTasks.count)
        let groupHeight = count * Metrics.barHeight + max(0, count - 1) * Metrics.spacing
        let top = ((bounds.height - groupHeight) / 2).rounded()
        // The slot is exactly the 后台 button's width, so a single bar is that wide. The group is
        // centred horizontally with the same `x` for every line (acceptance ③ asks for equal midX).
        let x = ((bounds.width - barWidth) / 2).rounded()
        for (index, bar) in barViews.enumerated() where index < visibleTasks.count {
            let y = top + CGFloat(index) * (Metrics.barHeight + Metrics.spacing)
            bar.frame = NSRect(x: x, y: y, width: barWidth, height: Metrics.barHeight)
        }
    }

    private var barWidth: CGFloat { bounds.width }

    // MARK: - test/inspection surface

    public var barViewsForTesting: [BackgroundTaskBarView] { Array(barViews.prefix(visibleTasks.count)) }
    public var visibleTaskIDsForTesting: [UUID] { visibleTasks.map(\.id) }
    public var barFramesForTesting: [NSRect] { barViewsForTesting.map(\.frame) }

    /// Blue fraction of each visible line, in the same order as `visibleTasks` (0…1).
    public var blueFractionsForTesting: [Double] { barViewsForTesting.map(\.blueFraction) }
}

/// One 3 pt line. A grey rounded track plus a blue left segment whose width is the wet fraction.
/// Declared separately so a test can read each line's frame and fraction without parsing pixels.
public final class BackgroundTaskBarView: NSView {

    public private(set) var taskID: UUID?
    public private(set) var blueFraction: Double = 0

    public override var isFlipped: Bool { true }

    public init() {
        super.init(frame: .zero)
        wantsLayer = false
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    func configure(task: BackgroundTask) {
        taskID = task.id
        blueFraction = task.state == .queued ? 0 : BackgroundTaskStore.progressFraction(for: task)
        needsDisplay = true
    }

    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func draw(_ dirtyRect: NSRect) {
        let radius = BackgroundTaskBars.Metrics.cornerRadius
        BackgroundTaskBars.Metrics.trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        let blueWidth = bounds.width * CGFloat(min(1, max(0, blueFraction)))
        guard blueWidth > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: bounds.minX, y: bounds.minY,
                                  width: blueWidth, height: bounds.height)).addClip()
        BackgroundTaskBars.Metrics.fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
