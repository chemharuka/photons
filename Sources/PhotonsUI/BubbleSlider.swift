import SwiftUI
import AppKit

// MARK: - 055: 一个控件，只换拖动点形状

/// 解码参数（细节的四根、色温/色调）的滑杆。
///
/// **055 的重点是它不再是自绘控件。** 046 的 `BarSlider` 是一条 `Canvas` + `DragGesture`，为了键盘步进
/// 它调了 `.focusable()` —— macOS 于是在点击时画上系统焦点环（用户看到的那圈蓝框），而且它的焦点、
/// 无障碍、拖动手感都和渲染参数用的 `Slider`（底层 `NSSlider`）是两套。
///
/// 现在两种形状底层是**同一个控件**：`NSSlider`。这里只做两件事：
///
///  1. `focusRingType = .none`（控件与 cell 都设），点击不出蓝框，也不自绘任何焦点高亮；
///  2. 换一个 cell，把**拖动点**画成圆角长方形气泡（10 × 16 pt，圆角 5 pt = 胶囊），
///     **轨道、已选部分、拖动手感、键盘、无障碍全部是系统的** —— 这正是「看起来和其它滑杆一样」。
///
/// 行为与 `BarSlider` 一致的地方（调用点因此一行不改）：
///
///  · 拖动每一跳都写 `value`（调用方据此实时预览），一次拖动只调一次 `onEditingChanged(true)` 和一次
///    `onEditingChanged(false)` → 一次拖动 = 一条历史；
///  · 键盘单独一步（没有拖动会话）写值后立刻 `onEditingChanged(false)`，与 046 的 `step` 语义相同：
///    一步 = 一个快照。←/→ 本身由 `NSSlider` 处理，这里没有自己的按键逻辑；
///  · 行高固定 16 pt（`sizeThatFits`），与圆形滑杆同高，切换形状面板不跳版式；
///  · 两端可达：`NSSlider` 把值钳在 `minValue/maxValue` 里，`range` 就是那两个端点。
public struct BubbleSlider: NSViewRepresentable {

    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let onEditingChanged: (Bool) -> Void

    public init(value: Binding<Double>,
                range: ClosedRange<Double>,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self._value = value
        self.range = range
        self.onEditingChanged = onEditingChanged
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> BubbleSliderControl {
        let slider = BubbleSliderControl()
        slider.target = context.coordinator
        slider.action = #selector(Coordinator.valueChanged(_:))
        slider.onEditingChanged = { [weak coordinator = context.coordinator] began in
            coordinator?.parent.onEditingChanged(began)
        }
        slider.apply(range: range, value: value)
        return slider
    }

    public func updateNSView(_ slider: BubbleSliderControl, context: Context) {
        // The coordinator's copy of the parent is refreshed every update: `range` and the binding can
        // both change between drags (a new photo, a reset), and the action closure reads the live one.
        context.coordinator.parent = self
        slider.apply(range: range, value: value)
    }

    /// 16 pt，与圆形滑杆的行高一致 —— 不依赖调用点的 `.frame(height:)`，控件自己就报这个高度。
    public func sizeThatFits(_ proposal: ProposedViewSize,
                             nsView: BubbleSliderControl,
                             context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width,
               height: SliderValueMap.rowHeight)
    }

    public final class Coordinator: NSObject {

        var parent: BubbleSlider

        init(_ parent: BubbleSlider) { self.parent = parent }

        /// The slider's action: continuous, so it fires on every jump of a drag (the caller previews)
        /// and once per keyboard step.
        ///
        /// A change that happens **outside** a drag session is a discrete edit (←/→, an accessibility
        /// set): write it and commit it, exactly as 046's `step` did — one step, one history entry.
        /// Inside a drag, the commit belongs to the end of the drag, not to each jump.
        @objc func valueChanged(_ slider: BubbleSliderControl) {
            let newValue = SliderValueMap.clamp(slider.doubleValue, parent.range)
            if parent.value != newValue { parent.value = newValue }
            if !slider.isEditingSession { parent.onEditingChanged(false) }
        }
    }
}

// MARK: - the control

/// `NSSlider`（与 SwiftUI `Slider` 在 macOS 上同一个控件）只加「一次拖动 = 一次编辑」的记账。
///
/// 为什么需要记账：`NSSlider` 只有 target/action，没有「按下 / 抬起」回调。拖动的两端由两条路给出，
/// 都走 `beginEditing`/`endEditing` 这对带幂等守卫的方法，所以一次拖动**恰好**一对 true/false：
///
///  · `mouseDown` 在 `super`（同步跟踪循环）前后包一次 —— 这条路保证一定成对；
///  · cell 的 `startTracking`/`stopTracking` 各自报一次 —— 这条路让「拖动的开始/结束」在 cell 层
///    可被测试抓住，也让 `mouseDown` 之外的跟踪（例如此后被系统改走别的路径）仍然成对。
public final class BubbleSliderControl: NSSlider {

    var onEditingChanged: ((Bool) -> Void)?

    /// 只给测试看：一次拖动之后必须是 (1, 1)。
    private(set) var editingBeganCount = 0
    private(set) var editingEndedCount = 0

    private(set) var isEditingSession = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: SliderValueMap.rowHeight))
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        // 换 cell：只重写拖动点的绘制。换完必须把控件属性重新下发一遍 —— 新 cell 是未配置的
        // （`focusRingType` 尤其：控件上设的那次不会转发给它）。
        cell = BubbleSliderCell()
        sliderType = .linear
        isContinuous = true
        numberOfTickMarks = 0
        minValue = 0
        maxValue = 100
        controlSize = .mini
        // 055：点击不出蓝框。`NSControl.focusRingType` 不一定会转发给刚换上的 cell，所以两处都设，
        // 测试也两处都断言。（并且本类不覆写任何焦点高亮绘制。）
        focusRingType = .none
        cell?.focusRingType = .none
        // 键盘仍然要能改：不可聚焦就没有 ←/→。
        refusesFirstResponder = false
    }

    /// 值/行程同步。差值小于 1e-9 就不写 —— 拖动中 SwiftUI 回写同一个值时不制造多余的重绘，
    /// 也不会把用户正在拖的把手拽回去。
    func apply(range: ClosedRange<Double>, value: Double) {
        // 先把两端向外撑，再向内收 —— 一次拖动之外的两行可以有不同的行程（0…100 与 2000…10000 K），
        // 视图若被复用，任何中间状态都不许出现 min > max。
        let lower = range.lowerBound, upper = range.upperBound
        if lower < minValue { minValue = lower }
        if upper > maxValue { maxValue = upper }
        if lower > minValue { minValue = lower }
        if upper < maxValue { maxValue = upper }
        let clamped = SliderValueMap.clamp(value, range)
        if abs(doubleValue - clamped) > 1e-9 { doubleValue = clamped }
    }

    // MARK: one drag = one edit

    func beginEditing() {
        guard !isEditingSession else { return }
        isEditingSession = true
        editingBeganCount += 1
        onEditingChanged?(true)
    }

    func endEditing() {
        guard isEditingSession else { return }
        isEditingSession = false
        editingEndedCount += 1
        onEditingChanged?(false)
    }

    public override func mouseDown(with event: NSEvent) {
        beginEditing()
        super.mouseDown(with: event)   // synchronous: returns on mouse-up
        endEditing()
    }
}

// MARK: - the cell: only the knob's drawing

/// 一个 `NSSliderCell`，**只**覆写拖动点的绘制：圆角长方形气泡，10 × 16 pt、圆角 5 pt（= 两端半圆），
/// `controlAccentColor`。
///
/// 不碰 `drawBarInside(_:flipped:)`（轨道与已选部分是系统画的）、不碰刻度、不碰焦点环，
/// 也不调 `super.drawKnob` —— 所以系统那个圆球一个像素都不会留下（实测：绘制后的位图里，拖动点占
/// 10 × 16 pt 的整块强调色，其余位置没有系统的把手）。
final class BubbleSliderCell: NSSliderCell {

    /// 拖动点尺寸：宽 10 pt（比原来的 3 pt 细条宽，才像「气泡」）、高 16 pt（正好是行高）。
    static let knobSize = CGSize(width: 10, height: 16)
    /// 圆角 5 pt = 宽度的一半 → 左右两端是半圆，上下是 5 pt 的圆角，即胶囊/药丸形。
    static let knobCornerRadius: CGFloat = 5

    /// 给测试的证据：真的被画的矩形（不是「打算画」的常量）。
    private(set) var drawnKnobRect: NSRect?
    private(set) var drawCount = 0

    override func drawKnob(_ knobRect: NSRect) {
        let rect = bubbleRect(around: knobRect)
        drawnKnobRect = rect
        drawCount += 1
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect,
                     xRadius: Self.knobCornerRadius,
                     yRadius: Self.knobCornerRadius).fill()
    }

    /// 气泡的中心跟着系统给的 `knobRect` 的中心走（所以每一档的落点和系统滑杆逐像素一致），
    /// 只把尺寸换掉；再钳进控件边界，两端不会被裁掉半个圆角。
    func bubbleRect(around knobRect: NSRect) -> NSRect {
        let size = Self.knobSize
        let bounds = controlView?.bounds ?? knobRect
        var origin = NSPoint(x: (knobRect.midX - size.width / 2).rounded(),
                             y: (knobRect.midY - size.height / 2).rounded())
        origin.x = min(max(origin.x, bounds.minX), max(bounds.maxX - size.width, bounds.minX))
        origin.y = min(max(origin.y, bounds.minY), max(bounds.maxY - size.height, bounds.minY))
        return NSRect(origin: origin, size: size)
    }

    // MARK: tracking → one edit per drag

    override func startTracking(at startPoint: NSPoint, in controlView: NSView) -> Bool {
        let tracking = super.startTracking(at: startPoint, in: controlView)
        (controlView as? BubbleSliderControl)?.beginEditing()
        return tracking
    }

    override func stopTracking(last lastPoint: NSPoint, current stopPoint: NSPoint,
                               in controlView: NSView, mouseIsUp flag: Bool) {
        super.stopTracking(last: lastPoint, current: stopPoint, in: controlView, mouseIsUp: flag)
        (controlView as? BubbleSliderControl)?.endEditing()
    }
}
