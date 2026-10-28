import AppKit

// MARK: - geometry (pure, window-free)

/// The control's arithmetic: eight ticks **evenly spaced by index**, the index ↔ x mapping, and the
/// one continuous position the thumb is allowed — the *display* of the fit ratio.
///
/// The rule this type exists to enforce is that the ladder is *equal steps*, not a linear scale:
/// `25 → 400 %` over eight stops is seven equal gaps of track, so 25→33.3 is the same distance as
/// 300→400 even though the zoom ratios are wildly different. "每放大一级就是一格" is a statement
/// about the hand, not about the numbers.
///
/// The fit position is the **only** continuous x in here, and it is not a stop: it exists so the
/// thumb can say "the whole frame is currently at 31 %" without inventing a rung. Nothing can come
/// to rest on it — the first pointer event snaps to a tick (`ZoomGlassSlider.select(index:)`).
///
/// Everything here is a function of the track's width and nothing else — no window, no layer, no
/// camera — so the whole mapping is unit-testable without a screen (`ZoomGlassSliderTests`).
public struct ZoomGlassSliderGeometry: Equatable, Sendable {

    /// The control and its furniture, in points. One place, so the controller's placement and the
    /// drawing cannot disagree about how wide the thing is.
    public enum Metrics {
        /// `[适应] [————————]`, both pills on one 30 pt row.
        public static let totalWidth: CGFloat = 210
        public static let pillHeight: CGFloat = 30
        public static let cornerRadius: CGFloat = 15
        /// Distance from the canvas' right/bottom edge to the control.
        public static let edgeInset: CGFloat = 16
        /// The 适应 / percentage chip on the left.
        public static let chipWidth: CGFloat = 54
        /// The gap between the two pills.
        public static let gap: CGFloat = 8
        /// The track keeps 10 pt of air at each end, so the ticks never touch the pill's corner.
        public static let trackPadding: CGFloat = 10
        /// A tick is a 2 pt dot.
        public static let tickDiameter: CGFloat = 2
        /// The thumb is 14 pt across — so its own half-width (7 pt) is how far past the outermost
        /// tick the fit display may travel before the thumb would leave the pill.
        public static let thumbDiameter: CGFloat = 14

        /// The slider pill: everything that is not the chip and the gap.
        public static var sliderWidth: CGFloat { totalWidth - chipWidth - gap }
    }

    /// The number of rungs on the ladder — `LoupeViewState.zoomStops.count`, asserted in the tests.
    /// Derived, not written out: 2026-10-27 用户要求加 12.5% 档 turned eight rungs into nine, and a
    /// second literal here would have been a tick nobody drew.
    public static var tickCount: Int { LoupeViewState.zoomStops.count }

    /// The stop values, ascending. `0.125, 0.25, 1/3, 0.5, 2/3, 1, 2, 3, 4` — the thirds are the
    /// ladder's own exact doubles, never 0.333/0.667.
    public let levels: [Double]

    /// The track's width in points (the slider pill's width, not the whole control's).
    public let width: CGFloat

    public init(levels: [Double] = LoupeViewState.zoomStops,
                width: CGFloat = Metrics.sliderWidth) {
        self.levels = levels
        self.width = width
    }

    /// The distance between the first and last tick. A non-finite or tiny width can only collapse
    /// it to zero — never to a negative or a NaN, because both would put the ticks in an order the
    /// thumb could not follow.
    public var usableWidth: CGFloat {
        guard width.isFinite else { return 0 }
        return max(0, width - Metrics.trackPadding * 2)
    }

    /// The last valid index. `tickCount - 1`, clamped to whatever `levels` actually has, so a
    /// test-sized table cannot index out of bounds through this type.
    public var lastIndex: Int { max(0, min(Self.tickCount, levels.count) - 1) }

    /// `x(i) = padding + i · usable / lastIndex` — equal steps by **index**, so a rung added to the
    /// ladder narrows every gap without moving the two ends.
    public func x(forIndex index: Int) -> CGFloat {
        let i = min(max(index, 0), lastIndex)
        let usable = usableWidth
        guard usable > 0, lastIndex > 0 else { return Metrics.trackPadding }
        return Metrics.trackPadding + CGFloat(i) * usable / CGFloat(lastIndex)
    }

    /// The nearest tick to an x, clamped to the ends.
    ///
    /// **Tie-break: the lower index.** A pointer exactly halfway between two ticks is a question
    /// with two answers, and the left one is the answer the hand expects when it is sliding right
    /// (nothing moves until it has passed the midpoint). The half is compared with a `1e-9` band
    /// rather than with `==`: the midpoint of two ticks is not exactly representable in `CGFloat`,
    /// so `(x(2) + x(3)) / 2` can land one ulp above `.5` — and that ulp must not count as "past
    /// the middle".
    public func index(forX x: CGFloat) -> Int {
        guard x.isFinite, usableWidth > 0, lastIndex > 0 else { return 0 }
        let raw = (x - Metrics.trackPadding) / (usableWidth / CGFloat(lastIndex))
        guard raw.isFinite else { return 0 }
        let floorIndex = raw.rounded(.down)
        let fraction = raw - floorIndex
        let resolved = fraction <= 0.5 + 1e-9 ? floorIndex : floorIndex + 1
        return min(max(Int(resolved), 0), lastIndex)
    }

    /// The tick nearest a **numeric** zoom that is not exactly on the table (a pinch, a bridge
    /// ratio). Ties go to the lower index, the same rule as the x mapping.
    public func nearestIndex(forZoom zoom: Double) -> Int {
        let z = zoom.isFinite ? zoom : 1
        var best = 0
        var bestDelta = Double.infinity
        for (index, level) in levels.enumerated() where index <= lastIndex {
            let delta = abs(level - z)
            if delta < bestDelta {
                best = index
                bestDelta = delta
            }
        }
        return best
    }

    /// Every tick's x, left to right. Non-decreasing by construction, at any width.
    public var edges: [CGFloat] {
        (0...lastIndex).map { x(forIndex: $0) }
    }

    // MARK: the fit display (the only continuous position)

    /// Where the thumb's *centre* sits when it is pushed to the track's left end: half a thumb in
    /// from the edge, so the thumb's own left edge touches the track's left edge instead of
    /// hanging outside the pill. Deliberately **not** `x(forIndex: 0)` — "below 25 %" is not "on
    /// 25 %", and the user asked for the ends, not the first/last rung.
    public var thumbLeftLimit: CGFloat {
        let w = width.isFinite ? max(0, width) : 0
        return min(Metrics.thumbDiameter / 2, w / 2)
    }

    /// The same at the right end.
    public var thumbRightLimit: CGFloat {
        let w = width.isFinite ? max(0, width) : 0
        return max(thumbLeftLimit, w - Metrics.thumbDiameter / 2)
    }

    /// The thumb's x for a **fit** ratio: a continuous, log-interpolated position.
    ///
    /// Between two rungs the ladder's steps are multiplicative, so the honest position of a ratio
    /// between them is linear in `log`: with `z_i ≤ z ≤ z_{i+1}`,
    ///
    ///     index = i + log(z / z_i) / log(z_{i+1} / z_i)
    ///
    /// and the x is that fraction of the way from `x(i)` to `x(i+1)`. A linear-in-`z` placement
    /// would put 0.31 almost exactly on 25 % (0.31 is 6 points of 8.3 above 0.25 but 24 % of the
    /// way in log space) and the display would lie about where the picture is.
    ///
    /// Outside the ladder the thumb goes to the track's **ends**, not to the first/last rung: a
    /// 620 % window is past 400 %, and clamping it onto the 400 % dot would read as "you are at
    /// 400 %". Non-finite ratios read as 1:1.
    public func fitThumbCenter(forZoom zoom: Double) -> CGFloat {
        let z = zoom.isFinite ? zoom : 1
        guard levels.count > 1, lastIndex > 0 else { return thumbLeftLimit }
        guard let first = levels.first, let last = levels.last, first > 0, last > first else {
            return thumbLeftLimit
        }
        if z < first { return thumbLeftLimit }
        if z > last { return thumbRightLimit }
        if z == first { return clampedFit(x(forIndex: 0)) }
        if z == last { return clampedFit(x(forIndex: lastIndex)) }
        for index in 0..<lastIndex where levels[index] <= z && z <= levels[index + 1] {
            let a = levels[index]
            let b = levels[index + 1]
            guard a > 0, b > a else { return clampedFit(x(forIndex: index)) }
            let t = log(z / a) / log(b / a)
            guard t.isFinite else { return clampedFit(x(forIndex: index)) }
            let x = x(forIndex: index)
                + CGFloat(min(max(t, 0), 1)) * (x(forIndex: index + 1) - x(forIndex: index))
            return clampedFit(x)
        }
        return clampedFit(x(forIndex: 0))
    }

    /// Keep a fit position inside the track — the only thing a degenerate width could otherwise
    /// break (a 1 pt track has no room for 14 pt of thumb, and its ticks all collapse to one point).
    private func clampedFit(_ x: CGFloat) -> CGFloat {
        min(max(x, min(thumbLeftLimit, thumbRightLimit)), max(thumbLeftLimit, thumbRightLimit))
    }
}

// MARK: - the control

/// The canvas' zoom control: `[适应|12.5%] [ nine rungs ]` — two liquid-glass pills in the
/// **top-right** corner of the canvas (both modes, since 2026-10-27).
///
/// The left pill is a **state chip**: 适应 in fit, the percentage on a rung, and clicking it enters
/// fit (`zoomToFit()`). The right pill is the slider, and its thumb can only ever come to rest on
/// one of eight rungs.
///
/// The one apparent exception proves the rule: in fit the thumb is drawn at a **continuous**
/// position — the fit ratio, log-interpolated between two rungs (`fitThumbCenter(forZoom:)`), or at
/// the track's ends when the window is smaller than 25 % / bigger than 400 %. That position is a
/// *display*, not a stop: `pointerDown` / `pointerDragged` both go through `select(index:)`, which
/// snaps to a tick and emits, so the first event of any drag drops the camera onto 25–400 % — even
/// if the pointer has not moved a whole gap yet.
///
/// It never animates: `LoupeController.zoom(to:)` already bridges every stop change (180 ms), and a
/// second animation here would fight it. It also never streams: seven ticks mean at most seven
/// emissions for a full-width drag, and nothing at all while the pointer stays inside one gap.
public final class ZoomGlassSlider: NSView {

    /// Which backdrop actually got built. `glass` is the shipped path on macOS 26+; the visual
    /// effect fallback exists for older systems and is reported by the commit message.
    public enum Backdrop {
        case glass
        case visualEffect
    }

    /// Which corner of the canvas the pill is pinned to.
    ///
    /// **`topRight` is the placement in every mode** (2026-10-27 用户要求普通模式也放上方): the crop
    /// bar is centred at the bottom of the canvas, so the bottom-right corner is where two chrome
    /// rectangles overlap; putting the pill in the top-right in both modes removes that overlap
    /// without the bar's own layout contract (§D1's three fixed-width fields) moving a single point.
    ///
    /// `bottomRight` stays in the type because it is the corner the control *used* to occupy, and the
    /// regression tests still measure it to show the overlap the move removes. Nothing in the app
    /// selects it, and it is not the default any more.
    public enum Placement: Sendable, Equatable {
        case bottomRight
        case topRight

        /// The pin, expressed as AppKit's flexible margins (the *opposite* of the corner held).
        var autoresizingMask: NSView.AutoresizingMask {
            switch self {
            case .bottomRight: return [.minXMargin, .maxYMargin]
            case .topRight: return [.minXMargin, .minYMargin]
            }
        }
    }

    /// The corner this pill is pinned to. Setting it re-pins the view and asks for a layout pass;
    /// the geometry of the control itself (the track, the ticks, the thumb) is corner-independent.
    public var placement: Placement = .topRight {
        didSet {
            guard placement != oldValue else { return }
            autoresizingMask = placement.autoresizingMask
            needsLayout = true
        }
    }

    public let geometry: ZoomGlassSliderGeometry
    public let backdropKind: Backdrop

    /// The callback a stop change goes through. The controller wires it to `zoom(to:)`.
    public var onZoom: ((Double) -> Void)?
    /// The callback the chip goes through. The controller wires it to `zoomToFit()` — which is the
    /// only way *into* fit; the slider itself can never produce it.
    public var onFit: (() -> Void)?

    /// The stop the camera is exactly on, or `nil` for fit (the chip then reads 适应).
    ///
    /// `nil` is a state, not a position on the track: `currentZoomStop` is nil exactly when the
    /// camera is in fit, and the thumb is then drawn from the fit ratio instead of from an index.
    public private(set) var zoomStop: Double?
    /// The fit ratio, for the fit display only. Never a snap target.
    public private(set) var fitZoom: Double?
    /// The tick the thumb is on when the camera is on a rung.
    public private(set) var currentIndex = 0
    /// True while the camera is in `fit`: the chip reads 适应, no tick is accented, and the thumb
    /// shows the continuous fit position instead of a rung.
    public private(set) var showingFit = true

    private let chipBackdrop: NSView
    private let chipContent = NSView()
    private let chipLabel = ZoomGlassSliderLabel()
    private let sliderBackdrop: NSView
    private let sliderContent = NSView()
    private let track = ZoomGlassSliderTrack()
    /// True between `mouseDown` and `mouseUp` on the track: a drag is not a stream of clicks.
    private var isDragging = false

    // MARK: build

    public init(levels: [Double] = LoupeViewState.zoomStops,
                frame frameRect: NSRect = NSRect(x: 0, y: 0,
                                                 width: ZoomGlassSliderGeometry.Metrics.totalWidth,
                                                 height: ZoomGlassSliderGeometry.Metrics.pillHeight)) {
        geometry = ZoomGlassSliderGeometry(levels: levels)
        let chipBuilt = Self.makeBackdrop()
        let sliderBuilt = Self.makeBackdrop()
        chipBackdrop = chipBuilt.view
        sliderBackdrop = sliderBuilt.view
        backdropKind = chipBuilt.kind
        super.init(frame: frameRect)

        wantsLayer = true
        // Pinned to the top-right of whatever contains it: a resized window moves the canvas, not
        // this control. The mask comes from `placement`, so the two can never name different corners.
        autoresizingMask = placement.autoresizingMask

        track.geometry = geometry
        track.tickCount = geometry.lastIndex + 1
        chipContent.addSubview(chipLabel)
        sliderContent.addSubview(track)

        // The glass header guarantees only `contentView` is inside the glass, so the label and the
        // track are mounted there — never as siblings of the glass view.
        Self.mount(chipContent, in: chipBackdrop)
        Self.mount(sliderContent, in: sliderBackdrop)
        addSubview(chipBackdrop)
        addSubview(sliderBackdrop)

        update(zoomStop: nil, fitZoom: nil)
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    private static func mount(_ content: NSView, in backdrop: NSView) {
        if #available(macOS 26.0, *), let glass = backdrop as? NSGlassEffectView {
            glass.contentView = content
        } else {
            backdrop.addSubview(content)
        }
    }

    /// `NSGlassEffectView` where the SDK and the OS both have it (macOS 26+), otherwise an
    /// `NSVisualEffectView` HUD pill with a hand-drawn 1 pt hairline.
    ///
    /// Two separate pills rather than one `NSGlassEffectContainerView`: this SDK has no such class
    /// (checked in `AppKit.framework/Headers`), so they are matched in corner radius, height and
    /// material instead, which reads as one group without needing the container to merge them.
    private static func makeBackdrop() -> (view: NSView, kind: Backdrop) {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = ZoomGlassSliderGeometry.Metrics.cornerRadius
            glass.tintColor = nil
            // 27+ lets the glass answer the pointer itself (the specular lensing under the cursor).
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
            return (glass, .glass)
        }
        let fallback = NSVisualEffectView()
        fallback.material = .hudWindow
        fallback.blendingMode = .withinWindow
        fallback.state = .active
        fallback.wantsLayer = true
        fallback.layer?.cornerRadius = ZoomGlassSliderGeometry.Metrics.cornerRadius
        fallback.layer?.masksToBounds = true
        fallback.layer?.borderWidth = 1
        fallback.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        return (fallback, .visualEffect)
    }

    // MARK: placement

    /// Bottom-right of `bounds`, 16 pt in from each edge — or, what the app uses in **every** mode,
    /// the top-right corner (`placement`). Called by the controller on every layout pass; the
    /// autoresizing mask then carries the pin across window resizes without it.
    public func layout(in bounds: CGRect) {
        let size = CGSize(width: ZoomGlassSliderGeometry.Metrics.totalWidth,
                          height: ZoomGlassSliderGeometry.Metrics.pillHeight)
        let inset = ZoomGlassSliderGeometry.Metrics.edgeInset
        let origin: CGPoint
        switch placement {
        case .bottomRight:
            origin = CGPoint(x: bounds.maxX - inset - size.width, y: bounds.minY + inset)
        case .topRight:
            // y-up: the top edge is `maxY`, so the pill's origin is one pill-height below it.
            origin = CGPoint(x: bounds.maxX - inset - size.width, y: bounds.maxY - inset - size.height)
        }
        let next = CGRect(origin: origin, size: size)
        if frame != next { frame = next }
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let metrics = ZoomGlassSliderGeometry.Metrics.self
        let size = CGSize(width: metrics.chipWidth, height: bounds.height)
        chipBackdrop.frame = CGRect(origin: .zero, size: size)
        chipContent.frame = CGRect(origin: .zero, size: size)
        chipLabel.frame = CGRect(x: 8, y: ((bounds.height - 15) / 2).rounded(),
                                 width: metrics.chipWidth - 16, height: 15)
        let sliderSize = CGSize(width: metrics.sliderWidth, height: bounds.height)
        sliderBackdrop.frame = CGRect(origin: CGPoint(x: metrics.chipWidth + metrics.gap, y: 0),
                                      size: sliderSize)
        sliderContent.frame = CGRect(origin: .zero, size: sliderSize)
        track.frame = CGRect(origin: .zero, size: sliderSize)
    }

    // MARK: state in, state out

    /// Push the camera in: the stop (or `nil` for fit) and, for the fit display only, the fit ratio.
    ///
    /// Every external zoom change (⌘=, ⌘−, the wheel, a pinch, ⌘0) reaches this through
    /// `LoupeController.updateStatusChip()`, so the chip and the thumb cannot disagree with the
    /// canvas. `fitZoom` is used for exactly one thing — the continuous thumb position — and is
    /// never a snap target.
    public func update(zoomStop: Double?, fitZoom: Double?, zoom: Double? = nil) {
        self.zoomStop = zoomStop
        self.fitZoom = fitZoom
        // 082 (追加): the camera's **own** number wins when it is handed in. In a crop session the
        // ceiling is 「框恰好内接于画布」, which is usually not a rung (0.378 on a 4760-px crop in a
        // 1800-px canvas), and a readout that said 33.3 % while the camera sits at 37.8 % — or 适应,
        // because `currentZoomStop` is nil off the ladder — would be the one number on screen that
        // contradicts the picture.
        if let shown = zoom ?? zoomStop, shown.isFinite {
            showingFit = false
            let index = LoupeViewState.stopIndex(of: shown) ?? geometry.nearestIndex(forZoom: shown)
            currentIndex = min(max(index, 0), geometry.lastIndex)
            chipLabel.stringValue = LoupeViewState.percentLabel(of: shown)
            track.thumbX = geometry.x(forIndex: currentIndex)
        } else {
            showingFit = true
            chipLabel.stringValue = "适应"
            // The fit ratio is *displayed*, never parked: the first pointer event snaps away from
            // this position (`select(index:)`).
            track.thumbX = geometry.fitThumbCenter(forZoom: fitZoom ?? 1)
        }
        track.currentIndex = currentIndex
        track.showingFit = showingFit
        track.needsDisplay = true
    }

    /// What the chip says: `适应`, or the rung the camera is on (`25%`, `33.3%`, `200%`).
    public var labelText: String { chipLabel.stringValue }

    /// How many ticks are drawn in the accent colour (the current rung and everything left of it).
    /// Zero in fit — the fit position is not a rung, so nothing on the ladder is "behind" it.
    public var accentedTickCount: Int { track.tickTints.filter { $0 }.count }

    /// The rung the thumb is on — `nil` in fit, where the thumb shows a continuous ratio instead.
    public var thumbIndex: Int? { showingFit ? nil : currentIndex }

    /// The thumb's centre, **in the track's coordinates**. In fit this is the log-interpolated
    /// position of the fit ratio; on a rung it is exactly `geometry.x(forIndex: currentIndex)`.
    public var thumbCenterX: CGFloat { track.thumbX }

    /// The thumb's rect in the track's coordinates (14 pt across, vertically centred).
    public var thumbRect: CGRect {
        let d = ZoomGlassSliderGeometry.Metrics.thumbDiameter
        return CGRect(x: track.thumbX - d / 2, y: (track.bounds.height - d) / 2, width: d, height: d)
    }

    /// The track's frame, in this view's coordinates — the space the pointer helpers speak.
    public var trackFrame: CGRect { track.convert(track.bounds, to: self) }

    /// The chip's frame, in this view's coordinates.
    public var chipFrame: CGRect { chipBackdrop.convert(chipBackdrop.bounds, to: self) }

    /// The chip label's frame, in the chip's coordinates (client of `layout`).
    public var chipLabelFrame: CGRect { chipLabel.frame }

    /// The point (in this view) of a tick, for the controller, the smoke runner and the tests.
    public func point(forIndex index: Int) -> CGPoint {
        CGPoint(x: trackFrame.minX + geometry.x(forIndex: index), y: bounds.midY)
    }

    // MARK: the two gestures

    /// The chip: 适应 / the percentage, and the one way *into* fit. (⌘0 and the 显示 menu do the
    /// same thing; this is the pointer's copy of it.)
    public func activateChip() {
        onFit?()
    }

    /// A press on the track: pick the nearest tick and start a drag.
    ///
    /// From fit this is already the drop back onto the ladder — the press lands on a rung, and the
    /// camera goes there, whether or not a whole gap has been travelled.
    public func pointerDown(at point: CGPoint) {
        let band = trackFrame.insetBy(dx: -ZoomGlassSliderGeometry.Metrics.thumbDiameter / 2, dy: 0)
        guard band.contains(point) else { return }
        isDragging = true
        select(index: geometry.index(forX: point.x - trackFrame.minX))
    }

    /// A drag: still only ever a tick. `select(index:)` drops repeats, so a slow drag across one
    /// gap emits nothing at all.
    public func pointerDragged(at point: CGPoint) {
        guard isDragging else { return }
        select(index: geometry.index(forX: point.x - trackFrame.minX))
    }

    public func pointerUp() {
        isDragging = false
    }

    /// The **only** place a stop change leaves this view.
    ///
    /// Three guards, and between them they are the whole "never rests between rungs, never drops
    /// into fit" guarantee:
    ///
    /// 1. `index` is an integer tick index — `geometry.index(forX:)` returns one, and the thumb is
    ///    then placed at `geometry.x(forIndex: index)`. No continuous position is ever stored for a
    ///    drag, so the thumb cannot be caught mid-gap, not even for one frame.
    /// 2. The value emitted is `geometry.levels[next]` and nothing else: there is no expression in
    ///    this file that can send `nil` (fit) or a ratio between two rungs down `onZoom`.
    /// 3. The emit is gated on `index != currentIndex`, except for the fit → numeric entry, which is
    ///    a *mode* change and must be emitted even when the index happens to match. A 118 pt drag
    ///    therefore calls `onZoom` at most seven times, never once per event.
    private func select(index: Int) {
        let next = min(max(index, 0), geometry.lastIndex)
        let enteringFromFit = showingFit
        guard enteringFromFit || next != currentIndex else { return }
        currentIndex = next
        showingFit = false
        // The control's own camera record: from here on it is on a rung, not displaying fit.
        zoomStop = geometry.levels[next]
        chipLabel.stringValue = LoupeViewState.percentLabel(of: geometry.levels[next])
        track.currentIndex = next
        track.showingFit = false
        track.thumbX = geometry.x(forIndex: next)
        track.needsDisplay = true
        // Exactly one value, and it is a table value: `geometry.levels[next]`.
        onZoom?(geometry.levels[next])
    }

    // MARK: input routing

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if chipFrame.contains(point) {
            activateChip()
            return
        }
        pointerDown(at: point)
    }

    public override func mouseDragged(with event: NSEvent) {
        pointerDragged(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseUp(with event: NSEvent) {
        pointerUp()
    }

    /// A click on an inactive window's control should still work (and, on the glass path, light the
    /// lensing up) rather than be swallowed as an activation click.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Outside the control: **not here**. The canvas' pan/drag gestures must pass straight through
    /// the region around it, and this is the only thing that guarantees it.
    ///
    /// Inside it, the control answers as one view: the two pills, the label and the track are
    /// drawing, not targets, so a press can never land on (or be swallowed by) a subview — the two
    /// gestures are routed by `mouseDown` from `chipFrame` and `trackFrame`.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, frame.contains(point) else { return nil }
        return self
    }

    /// The wheel and the pinch are the loupe's gestures, not this control's: over it they must do
    /// exactly what they do over the matte. `wheelTarget` is the canvas, handed straight the event
    /// (`LoupeController` sets it at load) — the control never reads a scroll as a drag.
    public weak var wheelTarget: NSView?

    public override func scrollWheel(with event: NSEvent) {
        if let target = wheelTarget { target.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }

    public override func magnify(with event: NSEvent) {
        if let target = wheelTarget { target.magnify(with: event) } else { super.magnify(with: event) }
    }
}

// MARK: - furniture

/// The chip's text: 适应 / 25% / 33.3 %. A label, never a hit target.
private final class ZoomGlassSliderLabel: NSTextField {

    init() {
        super.init(frame: .zero)
        isBezeled = false
        isBordered = false
        drawsBackground = false
        isEditable = false
        isSelectable = false
        refusesFirstResponder = true
        font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        textColor = .secondaryLabelColor
        alignment = .center
        lineBreakMode = .byClipping
        stringValue = "适应"
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The track: eight ticks, one thumb, and nothing that moves on its own.
private final class ZoomGlassSliderTrack: NSView {

    var geometry = ZoomGlassSliderGeometry()
    var tickCount = ZoomGlassSliderGeometry.tickCount
    var currentIndex = 0
    var showingFit = true
    /// Where the thumb is drawn, in this view's coordinates. A rung (`x(forIndex:)`) whenever the
    /// camera is on one; the log-interpolated fit position when it is not.
    var thumbX: CGFloat = ZoomGlassSliderGeometry.Metrics.trackPadding

    /// One entry per tick: `true` = accent (the current rung and everything below it), `false` =
    /// tertiary. All `false` in fit — the fit position is not a rung.
    var tickTints: [Bool] {
        (0..<tickCount).map { !showingFit && $0 <= currentIndex }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let midY = bounds.midY

        // Ticks: 2 pt dots, accent up to the thumb, tertiary beyond it.
        for (index, accented) in tickTints.enumerated() {
            let x = geometry.x(forIndex: index)
            let d = ZoomGlassSliderGeometry.Metrics.tickDiameter
            let dot = CGRect(x: x - d / 2, y: midY - d / 2, width: d, height: d)
            (accented ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        // Thumb: 14 pt, white, hairline, a shadow just heavy enough to lift it off the glass.
        let size = ZoomGlassSliderGeometry.Metrics.thumbDiameter
        let rect = CGRect(x: thumbX - size / 2, y: midY - size / 2, width: size, height: size)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect).fill()

        NSGraphicsContext.saveGraphicsState()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        let outline = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}
