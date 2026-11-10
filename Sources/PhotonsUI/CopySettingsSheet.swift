import AppKit
import PhotonsCore

/// 编辑 ▸ 复制设置… / 粘贴设置（选择…） — the card-level checklist of 081, drawn like Lightroom's
/// **Copy Settings** since 319.
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
/// 319 (the user's own words: 「仿照 lightroom 去设计，即需要更加细分，而不是只按照卡片来」) makes the
/// **parameters the subject**, not an option:
///
///   · `showsChildren` is `true`. Every card is followed by its own parameter rows, indented 18 pt and
///     drawn at `.small` — Lightroom's own shape, where 「Light」 is a heading with 曝光/对比/高光…
///     under it.
///   · each card's checkbox is **three-state** (`allowsMixedState`): all of its parameters on = on,
///     none = off, some = mixed. Clicking a mixed card checks it whole (the same `set(_:)` the model
///     has always had), so the row can never claim a state the payload disagrees with.
///   · each card has a **disclosure triangle** that hides just its parameter rows, and the top of the
///     sheet has 展开全部 / 收起全部. Collapsing is *presentation only*: it changes `rows`, never
///     `selection` — hiding a row must not uncheck it.
///   · 全选 / 全不选 and the preset popup stay where they were (081 §1's footer).
enum CopySettingsSheet {

    /// Draw each card's parameter rows under it. **A constant, not a comment** (081 §2), and since 319
    /// it is `true`: the ticket's first sentence is that card-level-only is the bug.
    static let showsChildren = true

    /// 319 §2.3: the parameter rows are indented 18 pt under the card's own name, and drawn at
    /// `.small` — the two numbers the ticket names, in one place.
    static let childIndent: CGFloat = 18
    /// The disclosure triangle's width. The card's checkbox starts right of it, at 0 + this + 2.
    static let disclosureWidth: CGFloat = 13

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
                return "勾选要粘贴的卡片或单个参数。目标照片里没被点名的卡片一个字段都不会动。"
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

    /// The cards whose parameter rows are **hidden by the disclosure triangle**. Presentation only:
    /// `selection` is untouched, so a collapsed card still pastes everything it had checked.
    private(set) var collapsedCards: Set<EditSnapshotSection> = []

    // Exposed for the tests: they drive the real controls, not a parallel model.
    private(set) var rows: [Row] = []
    private(set) var checkboxes: [EditSnapshotSection: NSButton] = [:]
    private(set) var childCheckboxes: [EditSnapshotChild: NSButton] = [:]
    private(set) var disclosureButtons: [EditSnapshotSection: NSButton] = [:]
    private(set) var presetPopUp: NSPopUpButton!
    private(set) var selectAllButton: NSButton!
    private(set) var selectNoneButton: NSButton!
    private(set) var expandAllButton: NSButton!
    private(set) var collapseAllButton: NSButton!
    private(set) var statusLabel: NSTextField!
    private(set) var confirmButton: NSButton!
    private(set) var savePresetButton: NSButton?
    private(set) var cancelButton: NSButton!

    /// The three-column grid's row boxes, in `rows` order. `rowFrames` converts them into this view's
    /// coordinates, which is what `CopySheetLayoutTests` measures (column membership, reading order).
    private(set) var rowBoxes: [NSView] = []
    private let grid = CopySettingsRowGrid()
    private var gridHeightConstraint: NSLayoutConstraint!

    /// Rows torn down by a rebuild. Held until the next runloop turn so a **click** on a disclosure
    /// triangle cannot deallocate the button that is still dispatching its own action.
    private var retiredRows: [NSView] = []

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
    /// layout uses (081 §2's 「行数 15 + 全部子项数」 is this function's output). `collapsed` is the
    /// disclosure state: a collapsed card contributes its own row and none of its parameters.
    static func rows(showsChildren: Bool,
                     collapsed: Set<EditSnapshotSection> = []) -> [Row] {
        var out: [Row] = []
        for section in EditSnapshotSection.panelOrder {
            out.append(.card(section))
            guard showsChildren, !collapsed.contains(section) else { continue }
            out.append(contentsOf: section.children.map { .child($0, card: section) })
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

        // 319 §2.2: 展开全部 / 收起全部, above the checklist (they are about the list's shape, not about
        // what gets pasted — that is the footer's business).
        if showsChildren {
            let disclosureRow = NSStackView(views: [expandAllControl(), collapseAllControl()])
            disclosureRow.orientation = .horizontal
            disclosureRow.spacing = 6
            root.addArrangedSubview(disclosureRow)
        }

        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnCount = CopySettingsSheet.columnCount
        grid.columnSpacing = CopySettingsSheet.columnSpacing
        grid.rowHeight = CopySettingsSheet.rowHeight
        root.addArrangedSubview(grid)
        gridHeightConstraint = grid.heightAnchor.constraint(
            equalToConstant: CopySettingsSheet.gridHeight(for: 1))
        NSLayoutConstraint.activate([
            grid.widthAnchor.constraint(equalToConstant: CopySettingsSheet.gridWidth),
            gridHeightConstraint,
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

        rebuildRows()
    }

    /// Rebuild the grid from `rows(showsChildren:collapsed:)`.
    ///
    /// Called on construction and whenever the disclosure state changes. The controls are **not**
    /// reused across rebuilds: `rows` is the authority on what is drawn, and a checkbox holding a stale
    /// `tag` would act on the wrong row (`tag` is an index into `rows`).
    private func rebuildRows() {
        for view in rowBoxes { view.removeFromSuperview() }
        if !rowBoxes.isEmpty {
            retiredRows.append(contentsOf: rowBoxes)
            DispatchQueue.main.async { [weak self] in self?.retiredRows.removeAll() }
        }
        rowBoxes = []
        checkboxes = [:]
        childCheckboxes = [:]
        disclosureButtons = [:]

        rows = Self.rows(showsChildren: showsChildren, collapsed: collapsedCards)
        for (index, row) in rows.enumerated() {
            switch row {
            case .card(let section):
                rowBoxes.append(cardRow(section, index: index))
            case .child(let child, _):
                rowBoxes.append(childRow(child, index: index))
            }
        }

        grid.rowViews = rowBoxes
        for row in rowBoxes { grid.addSubview(row) }
        gridHeightConstraint?.constant = CopySettingsSheet.gridHeight(for: rows.count)
        grid.needsLayout = true
    }

    /// A card row: disclosure triangle, then the card's (three-state) checkbox.
    private func cardRow(_ section: EditSnapshotSection, index: Int) -> NSView {
        let box = NSButton(checkboxWithTitle: section.title,
                           target: self, action: #selector(toggledCard(_:)))
        box.tag = index
        box.allowsMixedState = true
        box.state = cardState(for: section)
        box.isEnabled = section.isCopyable
        if let help = section.help { box.toolTip = help }
        checkboxes[section] = box

        let holder = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(box)

        var constraints: [NSLayoutConstraint] = [
            box.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            box.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
        ]
        if showsChildren {
            let triangle = disclosureButton(for: section, index: index)
            holder.addSubview(triangle)
            disclosureButtons[section] = triangle
            constraints += [
                triangle.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                triangle.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                triangle.widthAnchor.constraint(equalToConstant: CopySettingsSheet.disclosureWidth),
                box.leadingAnchor.constraint(equalTo: triangle.trailingAnchor, constant: 2),
            ]
        } else {
            constraints.append(box.leadingAnchor.constraint(equalTo: holder.leadingAnchor))
        }
        NSLayoutConstraint.activate(constraints)
        return holder
    }

    private func disclosureButton(for section: EditSnapshotSection, index: Int) -> NSButton {
        let triangle = NSButton(title: "", target: self, action: #selector(toggledDisclosure(_:)))
        triangle.bezelStyle = .disclosure
        triangle.setButtonType(.onOff)
        triangle.title = ""
        triangle.tag = index
        triangle.translatesAutoresizingMaskIntoConstraints = false
        // On = expanded (triangle pointing down), off = collapsed. Not a checkbox: it is the list's
        // shape, and it never touches `selection`.
        triangle.state = collapsedCards.contains(section) ? .off : .on
        triangle.toolTip = collapsedCards.contains(section)
            ? "展开「\(section.title)」的参数"
            : "收起「\(section.title)」的参数"
        return triangle
    }

    /// A parameter row: indent 18, `.small` font (§2.3), tooltip saying exactly what one row copies.
    private func childRow(_ child: EditSnapshotChild, index: Int) -> NSView {
        let box = NSButton(checkboxWithTitle: child.title,
                           target: self, action: #selector(toggledChild(_:)))
        box.tag = index
        box.state = selection.contains(child) ? .on : .off
        box.controlSize = .small
        box.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        box.toolTip = "只复制这一个参数（\(child.section.title) 卡）"
        childCheckboxes[child] = box

        // The indent is measured from the card's **checkbox**, which itself starts right of the
        // disclosure triangle — so the parameter rows line up under the card's own words.
        let indent = showsChildren
            ? CopySettingsSheet.disclosureWidth + 2 + CopySettingsSheet.childIndent
            : CopySettingsSheet.childIndent
        return contain(box, indent: indent)
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

    private func expandAllControl() -> NSButton {
        expandAllButton = NSButton(title: "展开全部", target: self,
                                   action: #selector(expandAll(_:)))
        expandAllButton.bezelStyle = .rounded
        expandAllButton.controlSize = .small
        return expandAllButton
    }

    private func collapseAllControl() -> NSButton {
        collapseAllButton = NSButton(title: "收起全部", target: self,
                                     action: #selector(collapseAll(_:)))
        collapseAllButton.bezelStyle = .rounded
        collapseAllButton.controlSize = .small
        return collapseAllButton
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
        // The **model** decides, not the control's state. AppKit has already flipped the button (and a
        // mixed button flips to `.on`), and the tests drive the same action through `click(_:)`; reading
        // `cardState` keeps one rule for both: on → off, off/mixed → on. A mixed card clicked by the
        // user means 「这一张我全要」 — the alternative (mixed → off) would throw away parameters the user
        // checked one by one, which is the one thing a tri-state parent must not do.
        let wantOn = cardState(for: section) != .on
        selection.set(section, wantOn)
        refreshControls()
    }

    @objc private func toggledChild(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case .child(let child, _) = rows[sender.tag] else { return }
        // Same rule, for the same reason: the selection is the authority.
        selection.set(child, !selection.contains(child))
        refreshControls()
    }

    @objc private func toggledDisclosure(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), case .card(let section) = rows[sender.tag] else { return }
        setCollapsed(collapsedCards.contains(section) ? false : true, for: section)
    }

    @objc private func expandAll(_ sender: Any?) {
        collapsedCards.removeAll()
        rebuildRows()
        refreshControls()
    }

    @objc private func collapseAll(_ sender: Any?) {
        collapsedCards = Set(EditSnapshotSection.panelOrder)
        rebuildRows()
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

    /// Collapse / expand one card's parameter rows. Presentation only.
    func setCollapsed(_ collapsed: Bool, for section: EditSnapshotSection) {
        if collapsed { collapsedCards.insert(section) } else { collapsedCards.remove(section) }
        rebuildRows()
        refreshControls()
    }

    /// The state a card's checkbox should show: every parameter of the card on (`on`), none (`off`), or
    /// some (`mixed`). Cards with no parameter rows at all — 蒙版 — are plain on/off.
    func cardState(for section: EditSnapshotSection) -> NSButton.StateValue {
        let children = section.children
        guard !children.isEmpty else {
            return selection.sections.contains(section) ? .on : .off
        }
        let on = children.filter { selection.contains($0) }.count
        if on == 0 { return .off }
        return on == children.count ? .on : .mixed
    }

    /// Push the model into the controls — after any change, so the popup reads 自定义 the moment a
    /// checkbox makes the set one no preset names (a popup that keeps saying 基本 while the boxes
    /// disagree is the classic two-sources-of-truth bug).
    func refreshControls() {
        for (section, box) in checkboxes {
            box.state = cardState(for: section)
        }
        for (child, box) in childCheckboxes {
            box.state = selection.contains(child) ? .on : .off
        }
        for (section, triangle) in disclosureButtons {
            triangle.state = collapsedCards.contains(section) ? .off : .on
            triangle.toolTip = collapsedCards.contains(section)
                ? "展开「\(section.title)」的参数"
                : "收起「\(section.title)」的参数"
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

    /// Programmatic equivalent of clicking a card's checkbox — used by the tests. Follows the same
    /// rule the control does (the selection is the authority): on → off, off / mixed → on.
    func click(_ section: EditSnapshotSection) {
        guard let box = checkboxes[section] else { return }
        toggledCard(box)
    }

    /// Programmatic equivalent of clicking a parameter's checkbox.
    func click(_ child: EditSnapshotChild) {
        guard let box = childCheckboxes[child] else { return }
        toggledChild(box)
    }

    /// Programmatic equivalent of clicking a card's disclosure triangle.
    func clickDisclosure(_ section: EditSnapshotSection) {
        setCollapsed(!collapsedCards.contains(section), for: section)
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
final class CopySettingsRowGrid: NSView {

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
