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
    private let flipHButton = NSButton(title: "水平", target: nil, action: nil)
    private let flipVButton = NSButton(title: "垂直", target: nil, action: nil)
    private let gridButton = NSButton(title: "九宫格", target: nil, action: nil)
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

    /// 072 §D3 — **on = the system accent**, off = the button exactly as it was (both colour slots nil,
    /// i.e. AppKit's own appearance, value for value).
    private func applyToggleStyle(_ button: NSButton, on: Bool) {
        button.state = on ? .on : .off
        button.bezelColor = on ? .controlAccentColor : nil
        button.contentTintColor = on ? .white : nil
    }

    /// The style a toggle has right now, for the tests: (bezel, tint, state).
    func toggleStyle(_ which: String) -> (bezel: NSColor?, tint: NSColor?, on: Bool) {
        let button: NSButton
        switch which {
        case "h": button = flipHButton
        case "v": button = flipVButton
        default: button = gridButton
        }
        return (button.bezelColor, button.contentTintColor, button.state == .on)
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

    /// The 自定义比例 sheet. Kept out of the tests' way: the parse and the lock are
    /// `CropTool.ratio(from:)` + `setCustomRatio`, both driven directly there.
    private func promptForCustomRatio() {
        guard let controller else { return }
        let alert = NSAlert()
        alert.messageText = "自定义比例"
        alert.informativeText = "输入宽:高，例如 4:3 或 16:9。"
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: 24))
        field.stringValue = Self.lastCustomRatioText
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let ratio = CropTool.ratio(from: field.stringValue), controller.setCustomRatio(ratio) else {
            NSSound.beep()                    // refused: nothing written, the old ratio stays
            return
        }
        Self.lastCustomRatioText = field.stringValue
        sync()
        onChange?()
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
