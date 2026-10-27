import AppKit
import PhotonsCore

// MARK: - the crop bar (画布底部的工具条)
//
// Task 035 asks for a 拉直 slider, a 比例锁, the two flips and the 九宫格 toggle; every photo editor
// that got this right puts them in one strip at the bottom of the canvas while the tool is on, so
// the hand never leaves the picture (Phos's 裁剪 tool is a single toolbar button that swaps the
// canvas into crop mode, `local/src/swift-raw/Zenodeng_Phos/Sources/Phos/StudioUI.swift:82`).
//
// This view owns **no state**. Each control calls the controller; `sync()` pushes the controller's
// draft back into the controls (so the slider follows a ⌘-drag rotation, and the ratio popup follows
// a preset). Nothing here can invent a document change the controller did not make.
//
// 072 reshapes three things here:
//
//   · **D1 — the 信息栏 is three fixed-width fields** [角度] [比值] [像素]. The lock's name (`比例`) and
//     the `·` separators are gone (`draft.lock.displayName` was a fourth, variable-width thing), each
//     field is measured once against its own worst string (+2 pt) and never grows, so the whole bar's
//     width is the same number for every draft — the numbers no longer slide around as they change.
//   · **D2 — double-clicking 角度 returns it to 0.0°**, the same gesture as the inspector's
//     `ResetOnDoubleClick`. One assignment to the draft (no per-tick writes, no second snapshot when
//     the crop is applied).
//   · **D3 — 水平 / 垂直 / 九宫格 turn accent-blue when on** and keep their old appearance, value for
//     value, when off. 九宫格 stays view state; the two flips are the **document's** field (072 §F),
//     so the bar and 变换 ▸ 水平翻转 read the same bit.

final class CropToolBar: NSView {

    var controller: CropToolController? {
        didSet { sync() }
    }
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?
    /// The draft moved without an apply/cancel: the canvas has a new frame to draw (and, for a
    /// straighten, a new picture to render).
    var onChange: (() -> Void)?

    private let pill = NSVisualEffectView()
    private let stack = NSStackView()
    private let ratioPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let swapButton = NSButton(title: "⇄", target: nil, action: nil)
    private let straightenSlider = NSSlider(value: 0, minValue: -CropTool.straightenLimit,
                                            maxValue: CropTool.straightenLimit,
                                            target: nil, action: nil)
    private let angleField = CropInfoField(labelWithString: "0.0°")
    private let ratioField = CropInfoField(labelWithString: "")
    private let pixelField = CropInfoField(labelWithString: "")
    private let flipHButton = CropToggleButton(title: "水平", target: nil, action: nil)
    private let flipVButton = CropToggleButton(title: "垂直", target: nil, action: nil)
    private let gridButton = CropToggleButton(title: "九宫格", target: nil, action: nil)
    private let applyButton = NSButton(title: "应用", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

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

    /// The extra popup row that opens the 自定义… sheet (after the six presets and a separator).
    private static let customItemIndex = CropAspectPreset.allCases.count + 1

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

        for preset in CropAspectPreset.allCases {
            ratioPopup.addItem(withTitle: preset.displayName)
            ratioPopup.lastItem?.tag = CropAspectPreset.allCases.firstIndex(of: preset) ?? 0
        }
        ratioPopup.menu?.addItem(.separator())
        ratioPopup.addItem(withTitle: "自定义…")
        ratioPopup.lastItem?.tag = -1
        ratioPopup.target = self
        ratioPopup.action = #selector(ratioChanged(_:))
        ratioPopup.controlSize = .small
        ratioPopup.font = .systemFont(ofSize: 11)
        // A fixed width: the popup's own intrinsic width would change with a long custom title, and
        // then every field to its right would move (§D1's "三个起始 x 固定").
        ratioPopup.translatesAutoresizingMaskIntoConstraints = false
        ratioPopup.widthAnchor.constraint(equalToConstant: 82).isActive = true

        swapButton.target = self
        swapButton.action = #selector(swapTapped(_:))
        swapButton.bezelStyle = .inline
        swapButton.controlSize = .small
        swapButton.font = .systemFont(ofSize: 11)
        swapButton.toolTip = "交换长宽"
        swapButton.translatesAutoresizingMaskIntoConstraints = false
        swapButton.widthAnchor.constraint(equalToConstant: 24).isActive = true

        straightenSlider.target = self
        straightenSlider.action = #selector(straightenChanged(_:))
        straightenSlider.isContinuous = true
        straightenSlider.controlSize = .small
        straightenSlider.translatesAutoresizingMaskIntoConstraints = false
        straightenSlider.widthAnchor.constraint(equalToConstant: 132).isActive = true

        // The three readout fields: fixed width, left-aligned, one font (§D1).
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
        // 072 §D2 — double-click 角度 → 0.0°.
        angleField.onDoubleClick = { [weak self] in self?.resetStraighten() }

        for (button, action) in [(flipHButton, #selector(flipHorizontal(_:))),
                                 (flipVButton, #selector(flipVertical(_:))),
                                 (gridButton, #selector(toggleGrid(_:)))] {
            button.target = self
            button.action = action
            button.bezelStyle = .inline
            // ③ — a `.toggle`, because `state` is the whole interface here (the two flips are the
            // document's bits) and a *momentary* button does not keep it: AppKit normalises it back,
            // and the chip then never draws. What AppKit's own "selected" rendering paints for
            // `.inline` is a pale wash of the accent rather than the accent (measured (70,143,248)
            // against (0,122,255)), which is why `CropToggleButton` draws the accent **after**
            // `super.draw` — over that wash, not under it.
            button.setButtonType(.toggle)
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        gridButton.state = .on

        for (button, action) in [(applyButton, #selector(applyTapped(_:))),
                                 (cancelButton, #selector(cancelTapped(_:)))] {
            button.target = self
            button.action = action
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
        }

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        for view in [ratioPopup, swapButton, straightenSlider, angleField, ratioField, pixelField,
                     flipHButton, flipVButton, gridButton, applyButton, cancelButton] as [NSView] {
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
    /// The controls themselves, for the tests that drive them (`mouseDown`, `isEnabled`).
    var angleControl: CropInfoField { angleField }
    var applyControl: NSButton { applyButton }
    var cancelControl: NSButton { cancelButton }

    // MARK: sync

    /// Push the draft into the controls. Called on every draft change and on every tick of a
    /// ⌘-rotation, so the slider and the numbers never disagree with the frame on the canvas.
    func sync() {
        guard let controller else { return }
        let draft = controller.draft
        straightenSlider.doubleValue = draft.straighten
        angleField.stringValue = controller.angleText()
        ratioField.stringValue = controller.ratioText()
        pixelField.stringValue = controller.pixelText()
        syncRatioPopup()
        // 072 §D3/§F — the two flips are the **document's** bits, so they are read from it (a menu flip
        // moves these switches too). Each is refreshed on its own; neither can affect the other or the
        // grid, which is pure view state.
        applyToggleStyle(flipHButton, on: controller.flipHorizontal)
        applyToggleStyle(flipVButton, on: controller.flipVertical)
        applyToggleStyle(gridButton, on: controller.showsGrid)
        // 072 §D4 — with the tool off there is nothing to apply or cancel: both are grey (the menu's
        // two items are gated the same way in `EditorWindowController.validateMenuItem`).
        let active = controller.isActive
        applyButton.isEnabled = active
        cancelButton.isEnabled = active
    }

    private func syncRatioPopup() {
        guard let controller else { return }
        let preset = controller.aspectPreset()
        let index = CropAspectPreset.allCases.firstIndex(of: preset) ?? 0
        // A custom ratio that no preset names gets the dynamic row's own title, so the popup tells the
        // truth about the lock instead of claiming 自由 (§C2: "切换比例再切回不丢" — the name is what
        // makes the value findable again).
        if case .custom(let ratio) = controller.draft.lock, preset == .free {
            let text = "自定义 " + String(format: "%.4g", ratio) + ":1"
            if ratioPopup.item(at: Self.customItemIndex)?.tag != -2 {
                ratioPopup.insertItem(withTitle: text, at: Self.customItemIndex)
                ratioPopup.item(at: Self.customItemIndex)?.tag = -2
            } else {
                ratioPopup.item(at: Self.customItemIndex)?.title = text
            }
            if ratioPopup.indexOfSelectedItem != Self.customItemIndex {
                ratioPopup.selectItem(at: Self.customItemIndex)
            }
            return
        }
        if ratioPopup.item(at: Self.customItemIndex)?.tag == -2 {
            ratioPopup.removeItem(at: Self.customItemIndex)
        }
        if ratioPopup.indexOfSelectedItem != index { ratioPopup.selectItem(at: index) }
    }

    /// 072 §D3 — **on = the system accent, off = the button exactly as it was** (both colour slots nil,
    /// i.e. AppKit's own appearance, value for value).
    ///
    /// `bezelColor` alone does not paint anything here, and that is the whole of the 「看不出蓝」
    /// report: `NSButton` honours `bezelColor` only for the bezel styles that own a filled bezel
    /// (`.rounded`, `.regularSquare`, …). These three carry `.inline` so they sit inside the HUD pill
    /// like the popup and the ⇄ button next to them, and AppKit ignores the colour for that style —
    /// the slot could be read back while nothing on screen changed. So the accent is a **background
    /// layer of our own**, which is inside the button's frame, survives the `.inline` hairline and is
    /// pixel-measurable (`CropToggleAccentTests` samples the centre of the real bar, off vs on).
    /// `bezelColor` stays set as well: it is the slot the §D1/D3 assertions read, and on a future
    /// bezel style it would be the native answer.
    private func applyToggleStyle(_ button: NSButton, on: Bool) {
        button.state = on ? .on : .off
        button.bezelColor = on ? .controlAccentColor : nil
        button.contentTintColor = on ? .white : nil
        button.needsDisplay = true
    }

    /// The style a toggle has right now, for the tests: (bezel, tint, state).
    func toggleStyle(_ which: String) -> (bezel: NSColor?, tint: NSColor?, on: Bool) {
        let button = toggleButton(which)
        return (button.bezelColor, button.contentTintColor, button.state == .on)
    }

    /// The three switches by name ("h" / "v" / anything else = 九宫格) — one place, so the style
    /// accessor and the pixel test cannot disagree about which rect belongs to which control.
    func toggleButton(_ which: String) -> NSButton {
        switch which {
        case "h": return flipHButton
        case "v": return flipVButton
        default: return gridButton
        }
    }

    /// The toggle's rect in this bar's own (flipped) coordinates — ③ samples the bitmap inside it.
    ///
    /// The buttons are arranged subviews of the stack, which lives in the pill: `button.frame` is in
    /// the *stack's* space, not the bar's, so it has to be converted. (Sampling the raw frame reads
    /// the pill's background instead of the control — the mistake that made this test report
    /// (37, 37, 37) for every button.)
    func frame(ofToggle which: String) -> NSRect {
        let button = toggleButton(which)
        return convert(button.bounds, from: button)
    }

    // MARK: actions (all of them are the controller's)

    @objc private func ratioChanged(_ sender: NSPopUpButton) {
        guard let controller else { return }
        let cases = CropAspectPreset.allCases
        let index = sender.indexOfSelectedItem
        if sender.item(at: index)?.tag == -1 {
            // 自定义… : ask for W:H, then lock it. An invalid string is refused *before* anything is
            // written, so the current ratio survives a typo (§C2).
            sender.selectItem(at: max(0, cases.firstIndex(of: controller.aspectPreset()) ?? 0))
            promptForCustomRatio()
            return
        }
        guard cases.indices.contains(index) else { return }
        controller.setAspect(cases[index])
        sync()
        onChange?()
    }

    /// The 自定义比例 input. Kept out of the tests' way: the parse and the lock are
    /// `CropTool.ratio(from:)` + `setCustomRatio`, both driven directly there.
    ///
    /// ⑨ — it is a **centred panel of the window**, not a sheet and not a modal alert: `NSAlert
    /// .runModal()` puts the box at the screen centre (the window may be anywhere, on any display),
    /// and a sheet is placed under the title bar, never at the window's centre. A borderless
    /// `CropRatioPrompt` placed from `window.frame` is the only one of the three that satisfies
    /// "浮层中心 = 窗口中心 ±1 pt" for a window that has been moved or resized.
    private func promptForCustomRatio() {
        guard let controller else { return }
        guard let window = window else { NSSound.beep(); return }
        presentCustomRatioPrompt(in: window, initial: Self.lastCustomRatioText) { [weak self] text in
            self?.commitCustomRatio(text)
        }
    }

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
        onChange?()
        return true
    }

    /// The panel currently asking for `W:H`, if any — the handle ⑨'s test measures and cancels.
    private(set) var customRatioPrompt: CropRatioPrompt?

    /// Present the 自定义比例 panel centred on `window` (⑨). Internal so the test can drive the same
    /// path the popup does, with the same initial value and the same commit closure.
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

    @objc private func swapTapped(_ sender: NSButton) {
        guard let controller, controller.swapAspect() else { return }
        sync()
        onChange?()
    }

    @objc private func straightenChanged(_ sender: NSSlider) {
        controller?.setStraighten(sender.doubleValue)
        sync()
        onChange?()
    }

    /// 072 §D2 — one assignment to the draft, so there is exactly one value on the way to the one
    /// snapshot that 应用 writes (no per-tick writes, no second history entry).
    private func resetStraighten() {
        guard let controller, controller.draft.straighten != 0 else { return }
        controller.setStraighten(0)
        sync()
        onChange?()
    }

    @objc private func flipHorizontal(_ sender: NSButton) {
        controller?.toggleFlipHorizontal()
        sync()
        onChange?()
    }

    @objc private func flipVertical(_ sender: NSButton) {
        controller?.toggleFlipVertical()
        sync()
        onChange?()
    }

    @objc private func toggleGrid(_ sender: NSButton) {
        controller?.toggleGrid()
        sync()
        onChange?()
    }

    @objc private func applyTapped(_ sender: NSButton) { onApply?() }

    @objc private func cancelTapped(_ sender: NSButton) { onCancel?() }
}

// MARK: - ③ the accent-filled toggle

/// A toggle that **fills its own face** with the system accent while it is on.
///
/// Why a subclass instead of a colour slot: `NSButton` paints `bezelColor` only for the bezel styles
/// that own a filled bezel (`.rounded`, `.regularSquare`, …). These three are `.inline`, so they sit
/// in the HUD pill like the popup next to them — and for `.inline` the colour is **ignored**. That was
/// measured before this existed: with only `bezelColor` set, the centre row of 水平 stayed (37, 37, 37)
/// while the accent is (0, 122, 255) (see `CropToggleAccentTests`, which now samples the shipped
/// pixels and requires ≤24/255 on every channel).
///
/// Drawing the fill here — and using a *momentary* button type, so AppKit does not also paint its own
/// pale "selected" wash — is the whole fix: one rounded rect in the accent, then the cell's own title
/// (`contentTintColor = .white`) on top of it. Off draws exactly what it drew before.
final class CropToggleButton: NSButton {

    /// The bar is `isFlipped`, so the buttons are too: a fill in `bounds` needs no conversion either
    /// way, but the flag has to agree with the parent or the title would sit upside down.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Off: exactly the drawing that shipped before (`super` and nothing else).
        super.draw(dirtyRect)
        guard state == .on else { return }
        // On: the accent **over** the cell's own face. It has to be after `super.draw` — the `.inline`
        // bezel paints its own background inside `draw`, so a fill painted before it is covered
        // (measured: the centre row stayed (37, 37, 37) with the fill first).
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 5, yRadius: 5).fill()
        // …and the title again, because the fill just covered the one the cell drew.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.white,
        ]
        let text = attributedTitle.string.isEmpty ? title : attributedTitle.string
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
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
/// `ResetOnDoubleClick` (inspector) is a SwiftUI modifier; this is its AppKit twin for the bar, and it
/// carries the same contract: the *second* click of a double-click is the reset, once, and a single
/// click does nothing at all.
final class CropInfoField: NSTextField {

    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else { return }
        onDoubleClick?()
    }
}
