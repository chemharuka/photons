import CoreGraphics
import PhotonsCore

/// 原图（\）与前后对比（Y）的状态机：只回答「下一帧是什么」，不碰文档、历史、解码。
public final class LoupeCompareSession {
    public private(set) var showOriginal = false
    public private(set) var split: CompareSplit?
    public private(set) var isDragging = false
    public private(set) var modeChanges = 0
    public private(set) var splitDrags = 0

    /// 每次状态变化后调用一次；控制器在这里 `generation += 1` 并请求一帧。
    public var onChange: (() -> Void)?

    /// The split a drag remembers when 对比 is switched off and on again.
    private var lastSplit: CompareSplit?

    public init() {}

    /// What the next frame will be of. `showOriginal` wins over 对比 (see `LoupeFrameMode`).
    public var frameMode: LoupeFrameMode {
        if showOriginal { return .original }
        if let split { return .compare(split) }
        return .edited
    }

    @discardableResult
    public func toggleShowOriginal() -> Bool {
        setShowOriginal(!showOriginal)
        return showOriginal
    }

    @discardableResult
    public func setShowOriginal(_ on: Bool) -> Bool {
        guard on != showOriginal else { return showOriginal }
        showOriginal = on
        changed()
        return showOriginal
    }

    @discardableResult
    public func toggleCompare() -> Bool {
        setCompare(split == nil)
        return split != nil
    }

    @discardableResult
    public func setCompare(_ on: Bool) -> Bool {
        if on {
            guard split == nil else { return true }
            split = lastSplit ?? .half
        } else {
            guard let previous = split else { return false }
            lastSplit = previous
            split = nil
        }
        changed()
        return split != nil
    }

    /// ⇧Y — 左右 ↔ 上下. Keeps the fraction, because the user is asking about the *layout* of the
    /// line they already placed.
    public func toggleCompareAxis() {
        guard var split else { return }
        split.axis = split.axis == .vertical ? .horizontal : .vertical
        self.split = split
        lastSplit = split
        changed()
    }

    public func setCompareAxis(_ axis: CompareSplit.Axis) {
        guard var split, split.axis != axis else { return }
        split.axis = axis
        self.split = split
        lastSplit = split
        changed()
    }

    /// Move the line. Called by the drag (and by the menu's 50 % row): **no document, no history, no
    /// decode** — a new line is a new composite of two textures that already exist, so it costs one
    /// render of the pair and nothing else.
    public func setCompareFraction(_ fraction: Double) {
        guard var split else { return }
        let next = min(max(fraction.isFinite ? fraction : 0.5, 0), 1)
        guard abs(next - split.fraction) > 1e-6 else { return }
        split.fraction = next
        self.split = split
        lastSplit = split
        splitDrags += 1
        changed()
    }

    private func changed() {
        modeChanges += 1
        onChange?()
    }

    /// Where along the split axis a canvas point sits, 0…1.
    ///
    /// The controller's canvas is drawn in **device pixels** and hit-tested in points; `bounds` is
    /// that view's bounds in points, and the axis comes from the current split (`.vertical` when 对比
    /// is off, matching the controller's old answer).
    public func fraction(atViewPoint point: CGPoint, in bounds: CGRect,
                         fallbackAxis: CompareSplit.Axis = .vertical) -> Double {
        guard bounds.width > 1, bounds.height > 1 else { return 0.5 }
        let x = Double(point.x / bounds.width)
        let y = Double(point.y / bounds.height)
        let fraction = (split?.axis ?? fallbackAxis) == .vertical ? x : y
        return min(max(fraction, 0), 1)
    }

    /// Is this click on the line? `nil` (对比 off) is never a hit. `canvas` is the viewport in device
    /// pixels and `backingScale` is the window's, so the grab radius is 9 points in both.
    public func dividerHit(atViewPoint point: CGPoint, bounds: CGRect,
                           canvas: ImageSize, backingScale: Double) -> Bool {
        guard let split else { return false }
        let extent = split.axis == .vertical ? canvas.width : canvas.height
        guard extent > 0 else { return false }
        let line = Double(split.dividerPixel(canvas: canvas)) / Double(extent)
        // 9.0 is `LoupeController.compareGrabPoints` (points); the controller keeps the constant.
        let grab = 9.0 * backingScale / Double(extent)
        return abs(fraction(atViewPoint: point, in: bounds) - line) <= grab
    }

    /// A click on the line takes the drag. Returns `false` so the canvas's other gestures (pan, crop,
    /// paint) are untouched when the click was not on it.
    @discardableResult
    public func beginDrag(atViewPoint point: CGPoint, bounds: CGRect,
                          canvas: ImageSize, backingScale: Double) -> Bool {
        guard dividerHit(atViewPoint: point, bounds: bounds, canvas: canvas,
                         backingScale: backingScale) else { return false }
        isDragging = true
        return true
    }

    /// Move the line. Nothing is written: the document, the history and the decode ladder are not
    /// touched, and the frame that follows is a composite of two renders whose keys did not move.
    public func continueDrag(atViewPoint point: CGPoint, bounds: CGRect) {
        guard isDragging else { return }
        setCompareFraction(fraction(atViewPoint: point, in: bounds))
    }

    public func endDrag() {
        isDragging = false
    }
}
