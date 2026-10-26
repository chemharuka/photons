import AppKit

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
    private let straightenSlider = NSSlider(value: 0, minValue: -CropTool.straightenLimit,
                                            maxValue: CropTool.straightenLimit,
                                            target: nil, action: nil)
    private let straightenLabel = NSTextField(labelWithString: "0.0°")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let flipHButton = NSButton(title: "水平", target: nil, action: nil)
    private let flipVButton = NSButton(title: "垂直", target: nil, action: nil)
    private let gridButton = NSButton(title: "九宫格", target: nil, action: nil)
    private let applyButton = NSButton(title: "应用", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)

    /// How tall the pill is; the canvas asks for this when it lays the bar out.
    private static let barHeight: CGFloat = 34

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
        ratioPopup.target = self
        ratioPopup.action = #selector(ratioChanged(_:))
        ratioPopup.controlSize = .small
        ratioPopup.font = .systemFont(ofSize: 11)

        straightenSlider.target = self
        straightenSlider.action = #selector(straightenChanged(_:))
        straightenSlider.isContinuous = true
        straightenSlider.controlSize = .small
        straightenSlider.translatesAutoresizingMaskIntoConstraints = false
        straightenSlider.widthAnchor.constraint(equalToConstant: 132).isActive = true

        straightenLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        straightenLabel.textColor = .secondaryLabelColor
        straightenLabel.alignment = .right
        straightenLabel.translatesAutoresizingMaskIntoConstraints = false
        straightenLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor

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
        for view in [ratioPopup, straightenSlider, straightenLabel, sizeLabel,
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

    /// Push the draft into the controls. Called on every draft change and on every tick of a
    /// ⌘-rotation, so the slider and the numbers never disagree with the frame on the canvas.
    func sync() {
        guard let controller else { return }
        let draft = controller.draft
        straightenSlider.doubleValue = draft.straighten
        straightenLabel.stringValue = String(format: "%+.1f°", draft.straighten)
        let preset = controller.aspectPreset()
        let index = CropAspectPreset.allCases.firstIndex(of: preset) ?? 0
        if ratioPopup.indexOfSelectedItem != index { ratioPopup.selectItem(at: index) }
        flipHButton.state = draft.flipHorizontal ? .on : .off
        flipVButton.state = draft.flipVertical ? .on : .off
        gridButton.state = controller.showsGrid ? .on : .off
        sizeLabel.stringValue = controller.sizeReadout()
    }

    // MARK: actions (all of them are the controller's)

    @objc private func ratioChanged(_ sender: NSPopUpButton) {
        let cases = CropAspectPreset.allCases
        guard cases.indices.contains(sender.indexOfSelectedItem) else { return }
        controller?.setAspect(cases[sender.indexOfSelectedItem])
        sync()
        onChange?()
    }

    @objc private func straightenChanged(_ sender: NSSlider) {
        controller?.setStraighten(sender.doubleValue)
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
