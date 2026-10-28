import AppKit
import PhotonsCore

/// 编辑 ▸ 复制设置… / 粘贴设置（选择…） — the card-level checklist of 081.
///
/// One view, two purposes (`copy` / `paste`): the rows are the **inspector's cards**, in the
/// inspector's order (`InspectorView` renders `Section.allCases`; `EditSnapshotSection.panelOrder`
/// mirrors it), and the answer is the value type the session stores (`CopySettingsSelection`), so the
/// dialog cannot invent a combination the paste path does not understand.
///
/// What changed from 078, and why:
///
///   · ⌘C no longer copies — it opens this sheet (081 §1). 复制 is a decision about *what*, so it is
///     asked before it happens, not after.
///   · the rows are cards, not `RenderGroup`s: 白平衡 / 黑电平 / Light / Color / 黑白 / HSL / 色彩分级 /
///     细节 / 曲线 / 效果 / 裁切 / 蒙版 — the user's own words are 「按卡片选择」.
///   · `showsChildren` (default `false`) decides whether each card's **parameters** are drawn under
///     it. 081 §2 asks for them to exist but not be shown: 「只是不展示出来，不要写死」. So the rows
///     are built from `EditSnapshotChild` either way, and a test opens the switch to prove the child
///     rows draw *and* that checking one narrows the payload to that one leaf.
///   · the sheet can **save the selection as a preset** (081 §4): same rows, same answer, one button —
///     the naming dialog is the app's existing preset prompt.
///
/// The three answers the ticket asks for live on the **model** (`CopySettingsSelection`:
/// `selectAll()` / `selectNone()` / `select(.basic)`), and this view only drives them — `全选` /
/// `全不选` buttons, a 组合 popup, and the card checkboxes.
enum CopySettingsSheet {

    /// Draw each card's parameter rows under it. **A constant, not a comment** (081 §2): the default is
    /// 「不展示」, and the day the owner asks for them this one line is the whole change.
    ///
    /// The structure behind it is always there — `EditSnapshotSection.children` is typed and
    /// enumerable, and `EditSnapshot.filtered(to: selection)` honours the child set — so turning this
    /// on cannot half-work.
    static let showsChildren = false
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
                return "勾选要复制的卡片。只复制所选卡片里**非默认**的字段；目标照片没被点名的卡片一个字段都不会动。"
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

    /// `presetPopUp` index → preset. 自定义 is index 0 and is never selectable by the user directly.
    static let popUpPresets: [CopySettingsSelection.Preset?] =
        [nil] + CopySettingsSelection.Preset.allCases

    /// Where a preset sits in the popup (0 = 自定义). Used by the dialog's own `refreshControls` and by
    /// the tests, so neither has to re-derive the offset.
    static func popUpIndex(of preset: CopySettingsSelection.Preset) -> Int {
        popUpPresets.firstIndex(where: { $0 == preset }) ?? 0
    }

    /// The rows a sheet with this switch would draw — pure, so the count in a test is the count the
    /// layout uses (081 §2's 「行数 12 + 全部子项数」 is this function's output).
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
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 0))
        build()
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    // MARK: layout

    private func build() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 400),
        ])

        // 组合 + 全选 / 全不选 — the three answers, in one row so none of them is hidden behind a
        // popup the user has to discover.
        presetPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        presetPopUp.addItem(withTitle: "组合：自定义")
        for preset in CopySettingsSelection.Preset.allCases {
            presetPopUp.addItem(withTitle: "组合：\(preset.title)")
        }
        presetPopUp.target = self
        presetPopUp.action = #selector(presetChanged(_:))

        selectAllButton = NSButton(title: "全选", target: self, action: #selector(chooseAll(_:)))
        selectAllButton.bezelStyle = .rounded
        selectNoneButton = NSButton(title: "全不选", target: self, action: #selector(chooseNone(_:)))
        selectNoneButton.bezelStyle = .rounded

        // The rows. A card is a bold-ish checkbox with its tooltip; a parameter row is indented by a
        // spacer so the eye reads 「this belongs to the card above」.
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
                root.addArrangedSubview(box)
            case .child(let child, _):
                let box = NSButton(checkboxWithTitle: child.title,
                                   target: self, action: #selector(toggledChild(_:)))
                box.tag = index
                box.state = selection.contains(child) ? .on : .off
                box.controlSize = .small
                box.toolTip = "\(child.title)：只复制这一个参数（\(child.section.title) 卡）"
                childCheckboxes[child] = box
                let spacer = NSView(frame: NSRect(x: 0, y: 0, width: 18, height: 1))
                let line = NSStackView(views: [spacer, box])
                line.orientation = .horizontal
                line.spacing = 0
                root.addArrangedSubview(line)
            }
        }

        root.addArrangedSubview(separator())
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)

        // 081 §1: 全选 / 全不选 / 组合预设 are the sheet's **footer**, under the rows — the checklist is
        // the subject, the shortcuts are not. The primary button (复制（记住本次选择）) and
        // 保存为预设… are the alert's own, at the bottom right where a sheet's buttons belong.
        let tools = NSStackView(views: [presetPopUp, selectAllButton, selectNoneButton])
        tools.orientation = .horizontal
        tools.spacing = 6
        root.addArrangedSubview(tools)
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 400).isActive = true
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

    /// Run the sheet and return the answer, or nil when cancelled.
    static func run(selection: CopySettingsSelection, purpose: Purpose,
                    showsChildren: Bool = CopySettingsSheet.showsChildren) -> Outcome? {
        let accessory = CopySettingsAccessoryView(selection: selection, purpose: purpose,
                                                  showsChildren: showsChildren)
        accessory.layoutSubtreeIfNeeded()
        let height = max(accessory.fittingSize.height, 240)
        accessory.frame = NSRect(x: 0, y: 0, width: 400, height: height)

        let alert = NSAlert()
        alert.messageText = purpose.title
        alert.informativeText = purpose.informativeText
        alert.addButton(withTitle: purpose.confirmTitle)
        if purpose == .copy { alert.addButton(withTitle: "保存为预设…") }
        alert.addButton(withTitle: "取消")
        alert.accessoryView = accessory
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .confirm(accessory.selection)
        case .alertSecondButtonReturn where purpose == .copy:
            // 081 §4: 保存为预设… — the checked cards on the anchor, under the app's preset name prompt
            // (`EditorWindowController.askPresetName`), so both doors name a preset the same way.
            return .savePreset(accessory.selection)
        default:
            return nil
        }
    }
}
