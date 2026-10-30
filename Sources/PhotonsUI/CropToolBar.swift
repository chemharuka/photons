import AppKit
import PhotonsCore

// MARK: - the crop bar (画布底部的工具条) — 082: **只读三段信息**
//
// 用户的第二次改口（2026-10-28，与 082 同单）：
//
//   > 裁切模式下方悬浮栏的调节功能全部移动到右侧面板，只保留比例，像素，角度的信息。
//   > 注意角度有两个，一个是实际角度，一个是滑块角度。实际角度等于滑块角度 + 90 旋转两个之和。
//
// 所以这一条悬浮栏现在**只有三段只读读数**：`[角度] [比值] [像素]`，其中
//
//   · `角度` = **实际角度** = 滑块角度 + 90 × quarterTurns（`CropToolController.angleText()`）；
//   · `比值` = 草稿的比例（`ratioText`）；
//   · `像素` = 草稿将要提交的像素尺寸（`pixelText`）。
//
// 比例下拉、⇄、拉直滑杆、水平/垂直/九宫格、应用/取消 **全部搬进右侧裁切卡**
// （`TransformPanel.swift` 的四个分区）。这里没有 `NSButton`、没有 `NSSlider`、没有可编辑控件：
// 验收就是「悬浮栏视图树里可交互控件数 = 0」，`interactiveControlCount` 是那句话的读回点。
//
// 072 §D1 的三列定宽格式**原样保留**：每个字段按自己的最坏字符串（+2 pt）量一次、永不改宽度，所以
// 无论草稿是什么，三个数字都不会左右滑动、整栏宽度是同一个数。
//
// 104 只修排版（不增删信息）：082 删掉控件后 pill 仍按 `max(320, …)` 定宽，右边空了一半。现在
// pill 的宽度 = 内容宽 + 左右各 12 pt，三段等间距（段与段之间 16 pt，其中 1 pt 是分隔线）、整体
// 居中在画布上；`infoWidths()` 的定宽规则一点没动。
//
// 这个视图仍然**不存状态**：`sync()` 把控制器（草稿 + 文档的 quarterTurns）推进来，别处没有任何
// 副本，所以一个 ⌘] 转 90° 之后栏里的角度会立刻变成 `+90.0°` 的读数。

final class CropToolBar: NSView {

    var controller: CropToolController? {
        didSet { sync() }
    }

    private let pill = NSVisualEffectView()
    private let angleField = CropInfoField(labelWithString: "0.0°")
    private let ratioField = CropInfoField(labelWithString: "")
    private let pixelField = CropInfoField(labelWithString: "")
    /// 104: one hairline between each pair of segments, centred in the 16 pt gap.
    private let separators = [NSView(), NSView()]

    /// 104: the pill's left/right padding, and the gap between two segments' edges.
    static let pillInset: CGFloat = 12
    static let segmentGap: CGFloat = 16
    static let separatorWidth: CGFloat = 1
    static let separatorHeight: CGFloat = 18

    /// How tall the pill is; the canvas asks for this when it lays the bar out.
    private static let barHeight: CGFloat = 34

    /// The label font of the three readout fields, and the one their widths are measured with.
    static let infoFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// `+2 pt` of headroom over the widest string of each field, as §D1 asks.
    static let infoHeadroom: CGFloat = 2

    /// The three fixed widths, measured **once** from the worst string each field can print.
    static func infoWidths(font: NSFont = CropToolBar.infoFont) -> (angle: CGFloat, ratio: CGFloat, pixels: CGFloat) {
        func width(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width) + infoHeadroom
        }
        return (width(CropToolController.WorstCase.angle),
                width(CropToolController.WorstCase.ratio),
                width(CropToolController.WorstCase.pixels))
    }

    /// The custom-ratio field remembers what was typed last time — a **UI preference**, never a
    /// document field (§C2: the ratio itself goes into the document as `AspectLock.custom`).
    static let customRatioDefaultsKey = "photons.crop.customRatio"
    /// The `W:H` the inline field starts from (104 replaced the centred panel with it).
    static var lastCustomRatioText: String {
        get { UserDefaults.standard.string(forKey: customRatioDefaultsKey) ?? "4:3" }
        set { UserDefaults.standard.set(newValue, forKey: customRatioDefaultsKey) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    override var isFlipped: Bool { true }

    // MARK: building

    private func build() {
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.layer?.masksToBounds = true
        addSubview(pill)

        // The three readout fields: fixed width, **centred** readouts, one font (§D1 + N6). Nothing else
        // is added — no button, no slider, no popup (082). Centring matters because the width is sized to
        // the worst string each field can print, so a short readout (`0°`) would otherwise hug the left
        // edge of its box and the three numbers would look unequally spaced.
        for field in [angleField, ratioField, pixelField] {
            field.font = Self.infoFont
            field.textColor = .secondaryLabelColor
            field.alignment = .center
            field.lineBreakMode = .byClipping
            // The width is applied in `placeSegments()`; this view lays itself out by frames, not Auto
            // Layout, so a cell's intrinsic padding cannot widen a 39 pt field to 43.
        }
        angleField.setAccessibilityIdentifier("cropBar.angle")
        ratioField.setAccessibilityIdentifier("cropBar.ratio")
        pixelField.setAccessibilityIdentifier("cropBar.pixels")

        for separator in separators {
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        }

        // 104: the three fields + two hairlines are placed by `layout(in:)`. A stack view added no
        // value here (three fixed widths) and its cell padding made the measured gap 12 pt instead
        // of the 16 pt the spec asks for; explicit frames are the same numbers on every run.
        for view in [angleField, separators[0], ratioField, separators[1], pixelField] as [NSView] {
            pill.addSubview(view)
        }
    }

    // MARK: layout

    /// Place the pill centred at the bottom of `canvasBounds`, clear of the zoom pill (bottom-right)
    /// and the status chip (bottom-left). The container is y-up, like `ZoomGlassSlider.layout(in:)`,
    /// so "bottom" is `minY`.
    func layout(in canvasBounds: NSRect) {
        // 104: the pill hugs its content (no `max(320, …)`), so there is no empty right half any more.
        let width = ceil(Self.contentWidth) + 2 * Self.pillInset
        let height = Self.barHeight
        let x = canvasBounds.midX - width / 2
        let y = canvasBounds.minY + 12
        frame = NSRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height)
        pill.frame = bounds
        placeSegments()
    }

    /// The three fields and the two hairlines, inside the pill: equal 16 pt gaps, the group centred.
    /// Each gap holds one 1 pt line at its midpoint, so the line costs no width of its own.
    private func placeSegments() {
        let widths = Self.infoWidths()
        let fieldHeight = max(angleField.intrinsicContentSize.height,
                              max(ratioField.intrinsicContentSize.height,
                                  pixelField.intrinsicContentSize.height))
        let fieldY = ((Self.barHeight - fieldHeight) / 2).rounded()
        let separatorY = ((Self.barHeight - Self.separatorHeight) / 2).rounded()
        var x = (bounds.width - Self.contentWidth) / 2

        angleField.frame = NSRect(x: x, y: fieldY, width: widths.angle, height: fieldHeight)
        x += widths.angle + (Self.segmentGap - Self.separatorWidth) / 2
        separators[0].frame = NSRect(x: x, y: separatorY,
                                     width: Self.separatorWidth, height: Self.separatorHeight)
        x += Self.separatorWidth + (Self.segmentGap - Self.separatorWidth) / 2
        ratioField.frame = NSRect(x: x, y: fieldY, width: widths.ratio, height: fieldHeight)
        x += widths.ratio + (Self.segmentGap - Self.separatorWidth) / 2
        separators[1].frame = NSRect(x: x, y: separatorY,
                                     width: Self.separatorWidth, height: Self.separatorHeight)
        x += Self.separatorWidth + (Self.segmentGap - Self.separatorWidth) / 2
        pixelField.frame = NSRect(x: x, y: fieldY, width: widths.pixels, height: fieldHeight)
    }

    /// Content width = the three fixed fields + the two 16 pt gaps (each gap contains its hairline).
    /// The pill is this plus `2 × pillInset`.
    static var contentWidth: CGFloat {
        let widths = infoWidths()
        return widths.angle + widths.ratio + widths.pixels + 2 * segmentGap
    }

    // MARK: the readout, as measured (D1's evidence lives here)

    /// The three fields in this view's coordinates — what §D1's "frame(x, width) 逐点相同" is about.
    var angleFrame: NSRect { angleField.frame }
    var ratioFrame: NSRect { ratioField.frame }
    var pixelFrame: NSRect { pixelField.frame }
    /// The pill's frame, in the bar's coordinates (104's reflow evidence).
    var pillFrame: NSRect { pill.frame }
    /// The two hairline separators, in the bar's coordinates.
    var separatorFrames: [NSRect] { separators.map { convert($0.bounds, from: $0) } }
    /// The three segments, in the bar's coordinates — what the 16 pt / centring checks measure.
    var segmentFrames: (angle: NSRect, ratio: NSRect, pixels: NSRect) {
        (convert(angleField.bounds, from: angleField),
         convert(ratioField.bounds, from: ratioField),
         convert(pixelField.bounds, from: pixelField))
    }
    /// The bar's own width, in points.
    var barWidth: CGFloat { frame.width }
    /// What the three fields currently print, in order.
    var readoutText: (angle: String, ratio: String, pixels: String) {
        (angleField.stringValue, ratioField.stringValue, pixelField.stringValue)
    }
    /// The 角度 field only (the actual-angle readout 082 is about).
    var angleControl: CropInfoField { angleField }

    /// **082's acceptance**: how many *interactive* controls live in this view's subtree — 0 by contract.
    ///
    /// A "control" is anything a hand can press, drag or type into: a button, a slider, a popup, a
    /// segmented control, a toggle, or a text field that is `isEditable`/`isSelectable`. The three
    /// readout fields are `NSTextField` labels, which are `NSControl`s but neither editable nor
    /// selectable, so they do not count — which is exactly the distinction 「只读信息」 vs 「控件」.
    var interactiveControlCount: Int { Self.interactiveControls(in: self).count }

    /// The controls themselves, so a failure can name them.
    static func interactiveControls(in root: NSView) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if let text = view as? NSTextField {
                if text.isEditable || text.isSelectable { found.append(text) }
            } else if view is NSButton || view is NSSlider || view is NSPopUpButton
                        || view is NSSegmentedControl {
                found.append(view)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
        return found
    }

    // MARK: sync

    /// Push the controller into the three fields. Called on every draft change, on every tick of a
    /// ⌘-rotation (the angle is the *actual* angle, so a quarter turn moves it), and on a mode change.
    func sync() {
        guard let controller else {
            angleField.stringValue = "—"
            ratioField.stringValue = "—"
            pixelField.stringValue = "—"
            return
        }
        angleField.stringValue = controller.angleText()      // 082: 实际角度, not the slider's number
        ratioField.stringValue = controller.ratioText()
        pixelField.stringValue = controller.pixelText()
    }

}

// MARK: - one readout field

/// A read-only `NSTextField` label that reports a double-click without taking focus or a selection.
///
/// 082 made the bar read-only, so the double-click-to-reset that lived here (§D2) moved into the
/// card's 角度 section. The hook stays: it is what makes a label able to *report* a gesture at all,
/// and a field that quietly took focus would steal the keystrokes the crop mode's shortcuts own.
final class CropInfoField: NSTextField {

    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else { return }
        onDoubleClick?()
    }
}
