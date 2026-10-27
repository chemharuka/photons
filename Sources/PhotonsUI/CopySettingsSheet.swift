import AppKit
import PhotonsCore

/// 编辑 ▸ 选择要复制的设置… / 粘贴设置（选择组…） — the checklist.
///
/// One view, two purposes (`copy` / `paste`): the rows are the same rows Lightroom's Copy Settings
/// dialog has, and the answer is the same value type the session stores (`CopySettingsSelection`),
/// so the dialog cannot invent a combination the paste path does not understand.
///
/// The three answers the ticket asks for live on the **model** (`CopySettingsSelection`:
/// `selectAll()` / `selectNone()` / `select(.basic)`), and this view only drives them — `all` /
/// `none` buttons, a 预设组合 popup, and eight checkboxes. 蒙版 is drawn but disabled with the reason
/// in its tooltip: Lightroom's list has it, `EditSnapshot` cannot carry it (P1-5).
@MainActor
final class CopySettingsAccessoryView: NSView {

    enum Purpose {
        case copy
        case paste

        var title: String {
            switch self {
            case .copy: return "选择要复制的设置"
            case .paste: return "选择要粘贴的设置"
            }
        }

        var confirmTitle: String {
            switch self {
            case .copy: return "复制"
            case .paste: return "粘贴"
            }
        }
    }

    private(set) var selection: CopySettingsSelection
    let purpose: Purpose

    // Exposed for the tests: they drive the real controls, not a parallel model.
    private(set) var checkboxes: [EditSnapshotSection: NSButton] = [:]
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

    init(selection: CopySettingsSelection, purpose: Purpose) {
        self.selection = selection
        self.purpose = purpose
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 0))
        build()
        refreshControls()
    }

    required init?(coder: NSCoder) { fatalError("no nibs in this app") }

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
            root.widthAnchor.constraint(equalToConstant: 380),
        ])

        // 预设组合 + 全选 / 全不选 — the three answers, in one row so none of them is hidden behind a
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

        let tools = NSStackView(views: [presetPopUp, selectAllButton, selectNoneButton])
        tools.orientation = .horizontal
        tools.spacing = 6
        root.addArrangedSubview(tools)

        for section in EditSnapshotSection.panelOrder {
            let box = NSButton(checkboxWithTitle: section.title,
                               target: self, action: #selector(toggled(_:)))
            box.tag = EditSnapshotSection.panelOrder.firstIndex(of: section) ?? 0
            box.state = selection.contains(section) ? .on : .off
            box.isEnabled = section.isCopyable
            if let why = section.unavailableReason {
                box.toolTip = why
                box.title = "\(section.title)（暂不支持）"
            }
            checkboxes[section] = box
            root.addArrangedSubview(box)
        }

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)
    }

    // MARK: actions

    @objc private func toggled(_ sender: NSButton) {
        let sections = EditSnapshotSection.panelOrder
        guard sections.indices.contains(sender.tag) else { return }
        selection.set(sections[sender.tag], sender.state == .on)
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
        if let preset = selection.matchingPreset,
           let index = Self.popUpPresets.firstIndex(where: { $0 == preset }) {
            presetPopUp.selectItem(at: index)
        } else {
            presetPopUp.selectItem(at: 0)
        }
        statusLabel.stringValue = selection.summary
    }

    /// Programmatic equivalent of clicking every checkbox that names `section` — used by the tests to
    /// prove the disabled 蒙版 row cannot be checked in even by hand.
    func click(_ section: EditSnapshotSection) {
        guard let box = checkboxes[section] else { return }
        box.state = box.state == .on ? .off : .on
        toggled(box)
    }

    // MARK: presenting

    /// Run the sheet and return the answer, or nil when cancelled.
    static func run(selection: CopySettingsSelection, purpose: Purpose) -> CopySettingsSelection? {
        let accessory = CopySettingsAccessoryView(selection: selection, purpose: purpose)
        accessory.layoutSubtreeIfNeeded()
        let height = max(accessory.fittingSize.height, 240)
        accessory.frame = NSRect(x: 0, y: 0, width: 380, height: height)

        let alert = NSAlert()
        alert.messageText = purpose.title
        alert.informativeText = "只复制所选组里**非默认**的字段；目标照片没被点名的组一个字段都不会动。"
        alert.addButton(withTitle: purpose.confirmTitle)
        alert.addButton(withTitle: "取消")
        alert.accessoryView = accessory
        // The alert's own first responder would be its default button; the checklist wants the
        // keyboard so ⌘/space do not silently confirm an unexpected combination.
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return accessory.selection
    }
}
