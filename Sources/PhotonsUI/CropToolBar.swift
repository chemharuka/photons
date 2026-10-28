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
// 这个视图仍然**不存状态**：`sync()` 把控制器（草稿 + 文档的 quarterTurns）推进来，别处没有任何
// 副本，所以一个 ⌘] 转 90° 之后栏里的角度会立刻变成 `+90.0°` 的读数。

final class CropToolBar: NSView {

    var controller: CropToolController? {
        didSet { sync() }
    }

    private let pill = NSVisualEffectView()
    private let stack = NSStackView()
    private let angleField = CropInfoField(labelWithString: "0.0°")
    private let ratioField = CropInfoField(labelWithString: "")
    private let pixelField = CropInfoField(labelWithString: "")

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

    /// The custom-ratio dialog remembers what was typed last time — a **UI preference**, never a
    /// document field (§C2: the ratio itself goes into the document as `AspectLock.custom`).
    static let customRatioDefaultsKey = "photons.crop.customRatio"
    /// The `W:H` the 自定义… sheet starts from.
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

        // The three readout fields: fixed width, left-aligned, one font (§D1). Nothing else is added —
        // no button, no slider, no popup (082).
        let widths = Self.infoWidths()
        for (field, width) in [(angleField, widths.angle),
                               (ratioField, widths.ratio),
                               (pixelField, widths.pixels)] {
            field.font = Self.infoFont
            field.textColor = .secondaryLabelColor
            field.alignment = .left
            field.lineBreakMode = .byClipping
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        angleField.setAccessibilityIdentifier("cropBar.angle")
        ratioField.setAccessibilityIdentifier("cropBar.ratio")
        pixelField.setAccessibilityIdentifier("cropBar.pixels")

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        for view in [angleField, ratioField, pixelField] as [NSView] {
            stack.addArrangedSubview(view)
        }
        pill.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            stack.topAnchor.constraint(equalTo: pill.topAnchor),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])
    }

    // MARK: layout

    /// Place the pill centred at the bottom of `canvasBounds`, clear of the zoom pill (bottom-right)
    /// and the status chip (bottom-left). The container is y-up, like `ZoomGlassSlider.layout(in:)`,
    /// so "bottom" is `minY`.
    func layout(in canvasBounds: NSRect) {
        let size = stack.fittingSize
        let width = max(320, size.width)
        let height = Self.barHeight
        let x = canvasBounds.midX - width / 2
        let y = canvasBounds.minY + 12
        frame = NSRect(x: x.rounded(), y: y.rounded(), width: width.rounded(), height: height)
        pill.frame = bounds
    }

    // MARK: the readout, as measured (D1's evidence lives here)

    /// The three fields in this view's coordinates — what §D1's "frame(x, width) 逐点相同" is about.
    var angleFrame: NSRect { angleField.frame }
    var ratioFrame: NSRect { ratioField.frame }
    var pixelFrame: NSRect { pixelField.frame }
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

    // MARK: the 自定义比例 door (the card's, and the one the ⑨ test drives)
    //
    // 082 moved the ratio popup into the inspector card, but the centred `W:H` panel is one piece of
    // chrome with two doors: the card's `CropRatioPanels` and this pair, which `CropRatioPromptTests`
    // drives through the real `NSClick`-free commit path. Neither is a subview of the bar.

    /// The panel currently asking for `W:H`, if any — the handle ⑨'s test measures and cancels.
    private(set) var customRatioPrompt: CropRatioPrompt?

    /// Parse `W:H` and lock it — the one thing the 自定义比例 prompt's commit does.
    ///
    /// One function so the panel's commit, the test that drives it, and the parse cannot disagree;
    /// an invalid string is refused **before** anything is written (`CropTool.ratio(from:)`), so a
    /// typo leaves the current ratio alone.
    @discardableResult
    func commitCustomRatio(_ text: String) -> Bool {
        guard let controller, let ratio = CropTool.ratio(from: text),
              controller.setCustomRatio(ratio) else {
            NSSound.beep()                    // refused: nothing written, the old ratio stays
            return false
        }
        Self.lastCustomRatioText = text
        sync()
        return true
    }

    /// Present the 自定义比例 panel centred on `window` (⑨). Internal so the test can drive the same
    /// path the card's popup does, with the same initial value and the same commit closure.
    ///
    /// ⑨ — it is a **centred panel of the window**, not a sheet and not a modal alert: `NSAlert
    /// .runModal()` puts the box at the screen centre (the window may be anywhere, on any display),
    /// and a sheet is placed under the title bar, never at the window's centre.
    func presentCustomRatioPrompt(in window: NSWindow, initial: String,
                                  onCommit: @escaping (String) -> Void) {
        customRatioPrompt?.close()
        let prompt = CropRatioPrompt(initial: initial)
        prompt.onCommit = { [weak self] text in
            self?.customRatioPrompt = nil
            onCommit(text)
        }
        prompt.onCancel = { [weak self] in self?.customRatioPrompt = nil }
        customRatioPrompt = prompt
        prompt.present(centredOn: window)
    }
}

// MARK: - ⑨ the centred 自定义比例 panel

/// The `W:H` input as a **borderless panel centred on the app window**.
///
/// Why a panel and not a sheet: AppKit places a sheet under the window's title bar, so a sheet's
/// centre is never the window's centre, and the ask is "浮层中心 = 窗口中心 (±1 pt)". Why not
/// `NSAlert.runModal()`: an alert is centred on the **screen**, which is not the window once the
/// window has been moved or is on a second display — and it blocks the run loop, so the crop
/// interaction behind it cannot be asserted.
///
/// So: a child window (`parent.addChildWindow`) placed from `parent.frame` at open time. A child
/// window travels with its parent (the offset is preserved), which is the "挪到副屏再打开仍居中"
/// answer: the centre is recomputed from `parent.frame` every time it is presented.
///
/// Keys: focus lands in the field with the current text selected (typing replaces it), `↵` commits,
/// `Esc` cancels, and **a click outside does not commit** — the panel is not a sheet and only the two
/// buttons (or the two keys) finish it.
final class CropRatioPrompt: NSPanel {

    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let field = CropRatioField()
    private let okay = NSButton(title: "确定", target: nil, action: nil)
    private let cancel = NSButton(title: "取消", target: nil, action: nil)
    private let backdrop = NSVisualEffectView()

    /// The pill's style constants, reused (no new colours, no new sizes): the bar's own font and the
    /// HUD material its pill is made of.
    private static let font = NSFont.systemFont(ofSize: 11)
    private static let promptSize = NSSize(width: 264, height: 104)

    init(initial: String) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.promptSize),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false

        backdrop.material = .hudWindow
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        backdrop.frame = NSRect(origin: .zero, size: Self.promptSize)
        backdrop.autoresizingMask = [.width, .height]

        let title = NSTextField(labelWithString: "自定义比例")
        title.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        title.textColor = .labelColor
        title.frame = NSRect(x: 14, y: Self.promptSize.height - 30, width: 236, height: 16)

        let hint = NSTextField(labelWithString: "宽:高，例如 4:3 或 16:9")
        hint.font = Self.font
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 14, y: Self.promptSize.height - 48, width: 236, height: 15)

        field.font = Self.font
        field.stringValue = initial
        field.frame = NSRect(x: 14, y: Self.promptSize.height - 78, width: 236, height: 22)
        field.delegate = field
        field.target = self
        field.action = #selector(commit)

        okay.target = self
        okay.action = #selector(commit)
        okay.bezelStyle = .rounded
        okay.controlSize = .small
        okay.font = Self.font
        okay.keyEquivalent = "\r"
        okay.frame = NSRect(x: 152, y: 12, width: 98, height: 22)

        cancel.target = self
        cancel.action = #selector(cancelOut)
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.font = Self.font
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: 64, y: 12, width: 80, height: 22)

        let content = NSView(frame: NSRect(origin: .zero, size: Self.promptSize))
        content.addSubview(backdrop)
        for v in [title, hint, field, okay, cancel] as [NSView] { content.addSubview(v) }
        contentView = content

        field.onCommit = { [weak self] in self?.commit() }
        field.onCancel = { [weak self] in self?.cancelOut() }
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    /// Borderless panels are not key by default; this one has to be, or the field never sees a key.
    override var canBecomeKey: Bool { true }

    /// Place the panel at the **centre of `parent`** (screen coordinates, both rectangles) and show
    /// it as a child so it follows the window if the window is dragged while it is up.
    func present(centredOn parent: NSWindow) {
        let parentFrame = parent.frame
        setFrameOrigin(NSPoint(x: (parentFrame.midX - frame.width / 2).rounded(),
                               y: (parentFrame.midY - frame.height / 2).rounded()))
        parent.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
        field.selectText(nil)
    }

    /// The text the user has typed — the panel's own business, read by the ⑨ test.
    var text: String { field.stringValue }

    /// `↵`'s effect, for the ⑨ test: the real path is the 确定 button's key equivalent or the field
    /// editor's `doCommandBy` (`CropRatioField`), neither of which can be synthesised from a test
    /// without an event loop.
    func performCommitForTesting() { commit() }

    @objc private func commit() {
        let text = field.stringValue
        finish(committed: text)
    }

    @objc private func cancelOut() {
        finish(committed: nil)
    }

    /// `↵` while the field editor is first responder never reaches the button, so the field's
    /// `doCommandBy` calls back here (`CropRatioField`). `Esc` arrives the same way.
    private func finish(committed: String?) {
        parent?.removeChildWindow(self)
        orderOut(nil)
        if let committed { onCommit?(committed) } else { onCancel?() }
    }

    override func cancelOperation(_ sender: Any?) { cancelOut() }
}

/// The prompt's field editor hook: `↵` and `Esc` are **commands**, not characters — the only place
/// both are visible is `control(_:textView:doCommandBy:)`.
final class CropRatioField: NSTextField, NSTextFieldDelegate {

    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            onCommit?()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
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
