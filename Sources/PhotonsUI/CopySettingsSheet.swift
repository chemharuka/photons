import AppKit
import PhotonsCore

/// 编辑 ▸ 复制设置… / 粘贴设置（选择…） — the card-level checklist of 081.
///
/// One view, two purposes (`copy` / `paste`): the rows are the **inspector's cards**, in the
/// inspector's order (`InspectorView` renders `Section.allCases`; `EditSnapshotSection.panelOrder`
/// mirrors it), and the answer is the value type the session stores (`CopySettingsSelection`), so the
/// dialog cannot invent a combination the paste path does not understand.
///
/// 156 (2026-10-30) reworked the presentation, not the answers:
///
///   · it is a **sheet on the editor window** (`beginSheet`), not `NSAlert.runModal()` — the old alert
///     centred on the *screen*, and this one belongs to the picture the user is looking at.
///   · the rows are laid out in **three columns, column-major**: the reading order is still the
///     inspector's order (first column top-to-bottom, then the second, then the third), so a user
///     scanning for a missing card follows the same sequence down a column.
///   · the material is the **sidebar's** (`NSVisualEffectView(.sidebar)` in a rounded, titlebar-less
///     `NSPanel`), not the system glass an `NSAlert` brings with it. The controls stay stock AppKit;
///     only the window chrome is ours.
///   · 校正 is a row now (156 §3): the panel has carried the card since 096, but the clipboard's
///     section list did not, so copy/paste silently could not move 色差 R / 色差 B.
///
/// What did not change: `showsChildren` (default `false`) still decides whether each card's
/// **parameters** are drawn under it, and the answer is still `CopySettingsSelection`, so checking a
/// card and checking one of its leaves mean the same thing they meant in 081.
enum CopySettingsSheet {

    /// Draw each card's parameter rows under it. **A constant, not a comment** (081 §2).
    static let showsChildren = false

    // MARK: 156 — the three-column grid

    static let columnCount = 3
    static let columnWidth: CGFloat = 200
    static let columnSpacing: CGFloat = 24
    static let rowHeight: CGFloat = 24
    static let contentInset: CGFloat = 16
    static let cornerRadius: CGFloat = 10

    /// 3 × 200 + 2 × 24 = 648; the panel is this plus the two 16 pt insets (≈ 680).
    /// 2026-10-30（用户）：三列选单不需要那么宽 —— 260 pt/列显得空，收到 200 pt。
    static var gridWidth: CGFloat {
        CGFloat(columnCount) * columnWidth + CGFloat(columnCount - 1) * columnSpacing
    }

    static func columnRows(for count: Int) -> Int {
        max(1, (count + columnCount - 1) / columnCount)
    }

    static func gridHeight(for count: Int) -> CGFloat {
        CGFloat(columnRows(for: count)) * rowHeight
    }
}

@MainActor
final class CopySettingsAccessoryView: NSView {

    enum Purpose: Equatable {
        case copy
        case paste

        var title: String {
            switch self {
            case .copy: return "选择要复制的设置"
            case .paste: return "选择要粘贴的设置"
            }
        }

        /// The primary button. 081 §1 spells the copy one out: **`复制（记住本次选择）`** — the promise
        /// that the checklist comes back next time.
        var confirmTitle: String {
            switch self {
            case .copy: return "复制（记住本次选择）"
            case .paste: return "粘贴"
            }
        }

        var informativeText: String {
            switch self {
            case .copy:
                // 2026-10-30（用户）：这行说明太长，改成一句结论。
                return "不包含默认值"
            case .paste:
                return "勾选要粘贴的卡片。目标照片里没被点名的卡片一个字段都不会动。"
            }
        }
    }

    /// What the user did with the sheet.
    enum Outcome {
        case confirm(CopySettingsSelection)
        case savePreset(CopySettingsSelection)
    }

    /// One drawn row — a card, or (with `showsChildren`) one of its parameters.
    enum Row: Equatable {
        case card(EditSnapshotSection)
        case child(EditSnapshotChild, card: EditSnapshotSection)

        var title: String {
            switch self {
            case .card(let section): return section.title
            case .child(let child, _): return child.title
            }
        }

        var isCard: Bool { if case .card = self { return true }; return false }
    }

    private(set) var selection: CopySettingsSelection
    let purpose: Purpose
    /// Whether the parameter rows are drawn — see `CopySettingsSheet.showsChildren`.
    let showsChildren: Bool

    // Exposed for the tests: they drive the real controls, not a parallel model.
    private(set) var rows: [Row] = []
    private(set) var checkboxes: [EditSnapshotSection: NSButton] = [:]
    private(set) var childCheckboxes: [EditSnapshotChild: NSButton] = [:]
    private(set) var presetPopUp: NSPopUpButton!
    private(set) var selectAllButton: NSButton!
    private(set) var selectNoneButton: NSButton!
    private(set) var statusLabel: NSTextField!
    private(set) var confirmButton: NSButton!
    private(set) var savePresetButton: NSButton?
    private(set) var cancelButton: NSButton!

    /// The three-column grid's row boxes, in `rows` order. `rowFrames` converts them into this view's
    /// coordinates, which is what `CopySheetLayoutTests` measures (column membership, reading order).
    private(set) var rowBoxes: [NSView] = []
    private let grid = CopySettingsRowGrid()

    /// Called by the panel: `.some(outcome)` for confirm/save, `nil` for cancel.
    var onFinish: ((Outcome?) -> Void)?

    /// `presetPopUp` index → preset. 自定义 is index 0 and is never selectable by the user directly.
    static let popUpPresets: [CopySettingsSelection.Preset?] =
        [nil] + CopySettingsSelection.Preset.allCases

    /// Where a preset sits in the popup (0 = 自定义). Used by the dialog's own `refreshControls` and by
    /// the tests, so neither has to re-derive the offset.
    static func popUpIndex(of preset: CopySettingsSelection.Preset) -> Int {
        popUpPresets.firstIndex(where: { $0 == preset }) ?? 0
    }

    /// The rows a sheet with this switch would draw — pure, so the count in a test is the count the
    /// layout uses (081 §2's 「行数 13 + 全部子项数」 is this function's output).
    static func rows(showsChildren: Bool) -> [Row] {
        var out: [Row] = []
        for section in EditSnapshotSection.panelOrder {
            out.append(.card(section))
            if showsChildren {
                out.append(contentsOf: section.children.map { .child($0, card: section) })
            }
        }
        return out
    }

    init(selection: CopySettingsSelection, purpose: Purpose,
         showsChildren: Bool = CopySettingsSheet.showsChildren) {
        self.selection = selection
        self.purpose = purpose
        self.showsChildren = showsChildren
        super.init(frame: NSRect(x: 0, y: 0, width: CopySettingsSheet.gridWidth, height: 0))
        build()
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    /// The frame of every row in this view's coordinates, in `rows` order.
    ///
    /// Call `layoutSubtreeIfNeeded()` first. Empty until the grid has laid out.
    var rowFrames: [NSRect] {
        rowBoxes.map { grid.convert($0.frame, to: self) }
    }

    // MARK: layout

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: CopySettingsSheet.gridWidth),
        ])

        // 156 §4: title and explanation stay, above the three columns, in system label colours.
        let title = NSTextField(labelWithString: purpose.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        root.addArrangedSubview(title)

        let info = NSTextField(wrappingLabelWithString: purpose.informativeText)
        info.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        info.textColor = .secondaryLabelColor
        info.preferredMaxLayoutWidth = CopySettingsSheet.gridWidth
        info.widthAnchor.constraint(equalToConstant: CopySettingsSheet.gridWidth).isActive = true
        root.addArrangedSubview(info)

        // The rows: cards and (optionally) their parameters, in the inspector's own order.
        rows = Self.rows(showsChildren: showsChildren)
        for (index, row) in rows.enumerated() {
            switch row {
            case .card(let section):
                let box = NSButton(checkboxWithTitle: section.title,
                                   target: self, action: #selector(toggledCard(_:)))
                box.tag = index
                box.state = selection.contains(section) ? .on : .off
                box.isEnabled = section.isCopyable
                if let help = section.help { box.toolTip = help }
                checkboxes[section] = box
                rowBoxes.append(contain(box, indent: 0))
            case .child(let child, _):
                let box = NSButton(checkboxWithTitle: child.title,
                                   target: self, action: #selector(toggledChild(_:)))
                box.tag = index
                box.state = selection.contains(child) ? .on : .off
                box.controlSize = .small
                box.toolTip = "\(child.title)：只复制这一个参数（\(child.section.title) 卡）"
                childCheckboxes[child] = box
                rowBoxes.append(contain(box, indent: 18))
            }
        }

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowViews = rowBoxes
        for row in rowBoxes { grid.addSubview(row) }
        grid.columnCount = CopySettingsSheet.columnCount
        grid.columnSpacing = CopySettingsSheet.columnSpacing
        grid.rowHeight = CopySettingsSheet.rowHeight
        root.addArrangedSubview(grid)
        NSLayoutConstraint.activate([
            grid.widthAnchor.constraint(equalToConstant: CopySettingsSheet.gridWidth),
            grid.heightAnchor.constraint(equalToConstant: CopySettingsSheet.gridHeight(for: rows.count)),
        ])

        root.addArrangedSubview(separator())
        // 2026-10-30（用户）：底部「将复制：xx · xx」整行删除 —— 勾选状态本身就是答案。
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.isHidden = true

        // 081 §1: 全选 / 全不选 / 组合预设 are the sheet's **footer**, under the rows — the checklist is
        // the subject, the shortcuts are not. The primary button (复制（记住本次选择）) and
        // 保存为预设… are the bottom right, where a sheet's buttons belong.
        let tools = NSStackView(views: [presetPopUpControl(), selectAllControl(),
                                       selectNoneControl()])
        tools.orientation = .horizontal
        tools.spacing = 6
        root.addArrangedSubview(tools)
        root.addArrangedSubview(buttonRow())
    }

    private func contain(_ box: NSButton, indent: CGFloat) -> NSView {
        let holder = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: indent),
            box.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
            box.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    private func presetPopUpControl() -> NSPopUpButton {
        presetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        presetPopUp.addItem(withTitle: "组合：自定义")
        for preset in CopySettingsSelection.Preset.allCases {
            presetPopUp.addItem(withTitle: "组合：\(preset.title)")
        }
        presetPopUp.target = self
        presetPopUp.action = #selector(presetChanged(_:))
        return presetPopUp
    }

    private func selectAllControl() -> NSButton {
        selectAllButton = NSButton(title: "全选", target: self, action: #selector(chooseAll(_:)))
        selectAllButton.bezelStyle = .rounded
        return selectAllButton
    }

    private func selectNoneControl() -> NSButton {
        selectNoneButton = NSButton(title: "全不选", target: self, action: #selector(chooseNone(_:)))
        selectNoneButton.bezelStyle = .rounded
        return selectNoneButton
    }

    private func buttonRow() -> NSStackView {
        confirmButton = NSButton(title: purpose.confirmTitle, target: self,
                                 action: #selector(confirmPressed(_:)))
        confirmButton.bezelStyle = .rounded
        confirmButton.keyEquivalent = "\r"

        cancelButton = NSButton(title: "取消", target: self, action: #selector(cancelPressed(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"

        var views: [NSView] = [NSView()]
        if purpose == .copy {
            let save = NSButton(title: "保存为预设…", target: self,
                                action: #selector(savePresetPressed(_:)))
            save.bezelStyle = .rounded
            savePresetButton = save
            views.append(save)
        }
        views.append(confirmButton)
        views.append(cancelButton)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        // The first view is the spacer: it takes the slack, so the buttons sit at the trailing edge.
        row.views[0].setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.widthAnchor.constraint(equalToConstant: CopySettingsSheet.gridWidth).isActive = true
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: CopySettingsSheet.gridWidth).isActive = true
        return box
    }

    // MARK: actions

    @objc private func toggledCard(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case .card(let section) = rows[sender.tag] else { return }
        selection.set(section, sender.state == .on)
        refreshControls()
    }

    @objc private func toggledChild(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case .child(let child, _) = rows[sender.tag] else { return }
        selection.set(child, sender.state == .on)
        refreshControls()
    }

    @objc private func chooseAll(_ sender: Any?) {
        selection.selectAll()
        refreshControls()
    }

    @objc private func chooseNone(_ sender: Any?) {
        selection.selectNone()
        refreshControls()
    }

    @objc private func presetChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.popUpPresets.indices.contains(index), let preset = Self.popUpPresets[index] else { return }
        selection.select(preset)
        refreshControls()
    }

    @objc private func confirmPressed(_ sender: Any?) {
        onFinish?(.confirm(selection))
    }

    @objc private func savePresetPressed(_ sender: Any?) {
        onFinish?(.savePreset(selection))
    }

    @objc private func cancelPressed(_ sender: Any?) {
        onFinish?(nil)
    }

    /// Push the model into the controls — after any change, so the popup reads 自定义 the moment a
    /// checkbox makes the set one no preset names (a popup that keeps saying 基本 while the boxes
    /// disagree is the classic two-sources-of-truth bug).
    func refreshControls() {
        for (section, box) in checkboxes {
            box.state = selection.contains(section) ? .on : .off
        }
        for (child, box) in childCheckboxes {
            box.state = selection.contains(child) ? .on : .off
        }
        if let preset = selection.matchingPreset,
           let index = Self.popUpPresets.firstIndex(where: { $0 == preset }) {
            presetPopUp.selectItem(at: index)
        } else {
            presetPopUp.selectItem(at: 0)
        }
        // statusLabel 不再参与布局（见构造里的注释），这里只更新值，供测试读取。
        statusLabel.stringValue = selection.summary
    }

    /// Programmatic equivalent of clicking a card's checkbox — used by the tests.
    func click(_ section: EditSnapshotSection) {
        guard let box = checkboxes[section] else { return }
        box.state = box.state == .on ? .off : .on
        toggledCard(box)
    }

    /// Programmatic equivalent of clicking a parameter's checkbox.
    func click(_ child: EditSnapshotChild) {
        guard let box = childCheckboxes[child] else { return }
        box.state = box.state == .on ? .off : .on
        toggledChild(box)
    }

    // MARK: presenting

    /// Run the sheet on **`window`** and return the answer, or nil when cancelled.
    ///
    /// The modal loop is ours (`NSApp.runModal(for:)`) so the function stays synchronous for the
    /// menu actions, while `beginSheet` makes the panel slide down **from the editor window** instead
    /// of appearing in the middle of the screen (156 §1).
    static func run(selection: CopySettingsSelection, purpose: Purpose,
                    showsChildren: Bool = CopySettingsSheet.showsChildren,
                    on window: NSWindow) -> Outcome? {
        let panel = CopySettingsPanel(selection: selection, purpose: purpose,
                                      showsChildren: showsChildren)
        window.beginSheet(panel)
        NSApp.runModal(for: panel)
        if panel.sheetParent != nil { window.endSheet(panel) }
        NSApp.stopModal()
        return panel.outcome
    }
}

// MARK: - the window (156 §1/§4)

/// The sheet itself: a titlebar-less panel whose content sits in the **sidebar's** material.
///
/// `NSAlert` was the old host, and its glass is decided by the system — there is no per-window switch
/// for it. Here the chrome is ours: an `NSVisualEffectView(material: .sidebar)` with a 10 pt corner
/// radius, exactly the material the browser pane uses (`BrowserPaneController`'s `matte`). Controls
/// inside are stock AppKit (`NSButton(.switch)` / `NSPopUpButton` / rounded buttons) so they keep the
/// system's own drawing and its light/dark colours.
@MainActor
final class CopySettingsPanel: NSPanel {

    let accessory: CopySettingsAccessoryView
    private(set) var outcome: CopySettingsAccessoryView.Outcome?

    /// A borderless window is not key by default; the sheet has to take the keyboard for the
    /// checkboxes, the popup and Return/Escape.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(selection: CopySettingsSelection, purpose: CopySettingsAccessoryView.Purpose,
         showsChildren: Bool = CopySettingsSheet.showsChildren) {
        let accessory = CopySettingsAccessoryView(selection: selection, purpose: purpose,
                                                  showsChildren: showsChildren)
        accessory.layoutSubtreeIfNeeded()
        let content = accessory.fittingSize
        let width = (content.width > 0 ? content.width : CopySettingsSheet.gridWidth)
            + 2 * CopySettingsSheet.contentInset
        let height = (content.height > 0 ? content.height : 320)
            + 2 * CopySettingsSheet.contentInset
        self.accessory = accessory
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)

        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: NSSize(width: width,
                                                                                  height: height)))
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        effect.wantsLayer = true
        effect.layer?.cornerRadius = CopySettingsSheet.cornerRadius
        effect.layer?.masksToBounds = true
        contentView = effect

        accessory.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(accessory)
        NSLayoutConstraint.activate([
            accessory.leadingAnchor.constraint(equalTo: effect.leadingAnchor,
                                               constant: CopySettingsSheet.contentInset),
            accessory.trailingAnchor.constraint(equalTo: effect.trailingAnchor,
                                                constant: -CopySettingsSheet.contentInset),
            accessory.topAnchor.constraint(equalTo: effect.topAnchor,
                                           constant: CopySettingsSheet.contentInset),
            accessory.bottomAnchor.constraint(equalTo: effect.bottomAnchor,
                                              constant: -CopySettingsSheet.contentInset),
        ])

        accessory.onFinish = { [weak self] outcome in
            self?.outcome = outcome
            NSApp.stopModal()
        }
        initialFirstResponder = accessory.confirmButton
    }
}

/// The three-column grid: rows go **down** the first column, then down the second, then the third.
///
/// A plain `NSView` with manual frames rather than nested stacks: the column-major mapping (`i →
/// (col: i / n, row: i % n)`) is one line here and is exactly what the layout test measures. `n` is
/// `ceil(count / 3)`, so a short last column leaves its bottom empty instead of stretching rows.
private final class CopySettingsRowGrid: NSView {

    var rowViews: [NSView] = []
    var columnCount = 3
    var columnSpacing: CGFloat = 24
    var rowHeight: CGFloat = 24

    override func layout() {
        super.layout()
        guard !rowViews.isEmpty else { return }
        let rowsPerColumn = max(1, (rowViews.count + columnCount - 1) / columnCount)
        let totalSpacing = CGFloat(columnCount - 1) * columnSpacing
        let columnWidth = max(0, (bounds.width - totalSpacing) / CGFloat(columnCount))
        for (index, row) in rowViews.enumerated() {
            let column = index / rowsPerColumn
            let line = index % rowsPerColumn
            let x = CGFloat(column) * (columnWidth + columnSpacing)
            // Non-flipped coordinates: the first row of a column is the **top** one, so minY
            // decreases down a column (what the reading-order test pins).
            let y = bounds.height - CGFloat(line + 1) * rowHeight
            row.frame = NSRect(x: x, y: y, width: columnWidth, height: rowHeight)
        }
    }
}
