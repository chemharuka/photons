import AppKit
import SwiftUI
import PhotonsCatalog

// 「原文件已移动」 — the UI half.
//
// The library stores references, so a file the user moved in the Finder turns into a row whose path
// no longer resolves. This file is everything the window says and does about that:
//
//   · the words — one constant per sentence, shared by the grid badge, the filmstrip badge, the
//     photo list, the inspector row, the context menu and the confirmation sheet. A second copy of
//     「原文件已移动」 is how a feature starts contradicting itself;
//   · the badge — one drawing routine for all three browsers, so a 210 pt card and a 111 pt strip
//     cell cannot disagree about what the state looks like;
//   · the context menu — two verbs, enabled only when the selection contains something missing, and
//     modelled as a value (`State`) so the enablement rule is testable without a menu bar;
//   · the inspector row — an `NSView`-backed line, like `MarqueeText`, so "is it on screen" can be
//     answered by walking the view tree instead of by trusting the `if`.

// MARK: - the words

/// Every string this feature shows, in one place.
public enum MissingFileText {
    /// The badge on a card, a strip cell, a list row and the line in the inspector.
    public static let moved = "原文件已移动"

    public static let deleteMenuTitle = "从库中删除…"
    public static let findMenuTitle = "查找丢失的文件…"

    /// The sheet's title. A question, because it is one.
    public static let deleteConfirmTitle = "从库中删除？"
    public static let deleteConfirmButton = "从库中删除"
    public static let cancelButton = "取消"

    /// The sentence the user asked for, count included: the entry and its modification records go,
    /// the file does not.
    public static func deleteConfirmMessage(count: Int) -> String {
        "将从库中移除 \(count) 个条目及其修改记录，原文件不受影响。"
    }

    public static let findPanelTitle = "查找丢失的文件"
    public static let findPanelMessage = "选择一个文件夹，按其子文件夹中与条目同名的文件重新链接。"
    public static let findPanelButton = "搜索"

    /// What one 「查找丢失的文件…」 run found.
    public static func relinkSummary(relinked: Int, unmatched: Int, rejected: Int, failed: Int) -> String {
        var parts: [String] = []
        parts.append("已重新链接 \(relinked) 个")
        if unmatched > 0 { parts.append("未找到 \(unmatched) 个") }
        if rejected > 0 { parts.append("内容不一致 \(rejected) 个（已跳过）") }
        if failed > 0 { parts.append("写入失败 \(failed) 个") }
        return parts.joined(separator: " · ")
    }

    /// A single item's失败 line, for the alert that reports the run.
    public static let findNothingFound = "没有找到与条目内容一致的丢失文件；条目仍标记为「原文件已移动」。"
}

// MARK: - the badge

/// The 「原文件已移动」 overlay, drawn the same way everywhere.
///
/// A scrim plus a bottom pill rather than a corner triangle: the badge carries *words*, and words at
/// 9 pt on a busier photo need a background to stay readable. It is drawn on top of whatever the cell
/// already has (the placeholder block or a cached thumbnail), so a missing entry is never a white
/// hole and never loses its rating badge.
public enum MissingFileBadge {

    public static let text = MissingFileText.moved

    public static func attributes(compact: Bool) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: compact ? 8 : 9, weight: .semibold),
         .foregroundColor: NSColor.white]
    }

    /// Draw into `rect` (the thumbnail rect, already clipped by the caller).
    /// Returns the rect the pill occupied — the tests read it back through the cell instead.
    @discardableResult
    public static func draw(in rect: NSRect, compact: Bool = false) -> NSRect? {
        guard rect.width > 24, rect.height > 16 else { return nil }
        let attrs = attributes(compact: compact)
        let size = (text as NSString).size(withAttributes: attrs)

        // Dim what is behind the words — a moved file's thumbnail may be a stale cache entry, and
        // the point of the badge is that the pixels are no longer the picture on disk.
        NSColor.black.withAlphaComponent(compact ? 0.35 : 0.30).setFill()
        NSBezierPath(roundedRect: rect, xRadius: WorkspaceLayout.cardCornerRadius,
                     yRadius: WorkspaceLayout.cardCornerRadius).fill()

        let pillWidth = min(rect.width - 8, size.width + 12)
        let pillHeight = size.height + 4
        let pill = NSRect(x: rect.minX + (rect.width - pillWidth) / 2,
                          y: rect.maxY - pillHeight - 6,
                          width: pillWidth, height: pillHeight)
        NSColor.systemOrange.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
        (text as NSString).draw(in: pill.insetBy(dx: 6, dy: 2), withAttributes: attrs)
        return pill
    }
}

// MARK: - the context menu

/// The right-click menu for a browser (grid, filmstrip, photo list).
///
/// Two verbs, and both are enabled **only** when the selection contains a missing entry: deleting an
/// entry whose file is present is not this feature's business (and a right-click must never be one
/// click away from deleting a good photo), and searching for a file that is where it belongs is a
/// contradiction.
///
/// Enablement is a value (`State`), not a side effect of `NSMenuItem` validation, so the rule that
/// decides it can be asserted directly — the menu items are then *set* from it, which is the only
/// way AppKit can render it.
public final class AssetContextMenu: NSObject, NSMenuDelegate {

    public struct State: Equatable, Sendable {
        public var hasSelection: Bool
        public var missingCount: Int

        public init(hasSelection: Bool = false, missingCount: Int = 0) {
            self.hasSelection = hasSelection
            self.missingCount = missingCount
        }

        public var canDelete: Bool { hasSelection && missingCount > 0 }
        public var canFindLost: Bool { hasSelection && missingCount > 0 }
    }

    /// 右键菜单里「加入相册 ▸」的一个条目（078 B10）。
    ///
    /// `containsAll` 是「选中的每一张都已经在这个相册里」—— 用来画勾，也用来决定「移出相册 ▸」
    /// 列出哪些相册：没包含就移出它，那个菜单项什么都不做。
    public struct AlbumItem: Equatable, Sendable {
        public var id: String
        public var name: String
        public var containsAll: Bool

        public init(id: String, name: String, containsAll: Bool = false) {
            self.id = id
            self.name = name
            self.containsAll = containsAll
        }
    }

    public let menu = NSMenu()

    /// Selection as of the last `update(...)`; both actions apply to the **missing** entries only.
    public private(set) var state = State()
    public private(set) var targetIDs: [String] = []
    /// The whole selection as of the last `update(...)` —— 相册动作作用于它，不是只作用于缺失文件。
    public private(set) var selectedIDs: [String] = []

    /// Run after the user confirms. `Ask` is the sheet's answer, so the decision is made once, here.
    public var onDelete: (([String]) -> Void)?
    public var onFindLost: (([String]) -> Void)?
    /// 相册动作。两个都拿「整批选中 id + 相册 id」：一次点击一次写入，不是每张一次。
    public var onAddToAlbum: (([String], String) -> Void)?
    public var onRemoveFromAlbum: (([String], String) -> Void)?
    /// 相册清单 + 「选中的照片是否全在里面」，每次菜单打开前问一次。
    public var albumsProvider: (([String]) -> [AlbumItem])?
    /// Asked immediately before the menu opens, so the owner can fold the clicked item into the
    /// selection (a right-click on an unselected cell means *that* cell).
    public var willOpen: (() -> Void)?

    public private(set) var deleteItem: NSMenuItem!
    public private(set) var findItem: NSMenuItem!
    /// 「加入相册 ▸」与「移出相册 ▸」的父项（没有相册时禁用，不是隐藏：菜单位置稳定）。
    public private(set) var addToAlbumItem: NSMenuItem!
    public private(set) var removeFromAlbumItem: NSMenuItem!

    public override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self

        deleteItem = NSMenuItem(title: MissingFileText.deleteMenuTitle,
                                action: #selector(deletePressed), keyEquivalent: "")
        deleteItem.target = self
        deleteItem.isEnabled = false
        menu.addItem(deleteItem)

        findItem = NSMenuItem(title: MissingFileText.findMenuTitle,
                              action: #selector(findPressed), keyEquivalent: "")
        findItem.target = self
        findItem.isEnabled = false
        menu.addItem(findItem)

        menu.addItem(.separator())
        addToAlbumItem = NSMenuItem(title: "加入相册", action: nil, keyEquivalent: "")
        addToAlbumItem.submenu = NSMenu(title: "加入相册")
        addToAlbumItem.isEnabled = false
        menu.addItem(addToAlbumItem)

        removeFromAlbumItem = NSMenuItem(title: "移出相册", action: nil, keyEquivalent: "")
        removeFromAlbumItem.submenu = NSMenu(title: "移出相册")
        removeFromAlbumItem.isEnabled = false
        menu.addItem(removeFromAlbumItem)
    }

    /// Fold one refresh of the selection into the menu. `missingIDs` is the missing subset, in
    /// library order, so the sheet's count and the action's targets are the same list.
    @discardableResult
    public func update(selectedIDs ids: [String], missingIDs: [String]) -> State {
        let selected = Set(ids)
        let targets = missingIDs.filter { selected.contains($0) }
        state = AssetContextMenu.state(hasSelection: !selected.isEmpty, missingCount: targets.count)
        targetIDs = targets
        selectedIDs = ids
        deleteItem.isEnabled = state.canDelete
        findItem.isEnabled = state.canFindLost
        return state
    }

    /// The rule, on its own — this is what the test pins.
    public static func state(hasSelection: Bool, missingCount: Int) -> State {
        State(hasSelection: hasSelection, missingCount: max(0, missingCount))
    }

    /// 相册清单，纯函数：`albums` 是左栏那一份，`memberships` 是 `album_assets` 的一行行查出来的。
    /// 测试拿它验「两个相册都在菜单里、照片在哪个里面带勾」。
    public static func albumItems(albums: [AlbumSummary], memberships: [String: [String]],
                                  selectedIDs: [String]) -> [AlbumItem] {
        albums.map { album in
            let all = !selectedIDs.isEmpty && selectedIDs.allSatisfy { ids in
                memberships[ids]?.contains(album.id) == true
            }
            return AlbumItem(id: album.id, name: album.name, containsAll: all)
        }
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        willOpen?()
        guard menu === self.menu else { return }
        let albums = albumsProvider?(selectedIDs) ?? []
        addToAlbumItem.submenu?.removeAllItems()
        removeFromAlbumItem.submenu?.removeAllItems()
        for album in albums {
            let add = NSMenuItem(title: album.name, action: #selector(addPressed(_:)), keyEquivalent: "")
            add.target = self
            add.representedObject = album.id
            add.state = album.containsAll ? .on : .off
            add.isEnabled = !selectedIDs.isEmpty
            addToAlbumItem.submenu?.addItem(add)
        }
        for album in albums where album.containsAll {
            let remove = NSMenuItem(title: album.name, action: #selector(removePressed(_:)), keyEquivalent: "")
            remove.target = self
            remove.representedObject = album.id
            remove.isEnabled = !selectedIDs.isEmpty
            removeFromAlbumItem.submenu?.addItem(remove)
        }
        addToAlbumItem.isEnabled = !selectedIDs.isEmpty && !albums.isEmpty
        removeFromAlbumItem.isEnabled = !selectedIDs.isEmpty
            && !(removeFromAlbumItem.submenu?.items.isEmpty ?? true)
    }

    @objc private func deletePressed() {
        guard !targetIDs.isEmpty else { return }
        onDelete?(targetIDs)
    }

    @objc private func findPressed() {
        guard !targetIDs.isEmpty else { return }
        onFindLost?(targetIDs)
    }

    @objc private func addPressed(_ sender: NSMenuItem) {
        guard let albumID = sender.representedObject as? String, !selectedIDs.isEmpty else { return }
        onAddToAlbum?(selectedIDs, albumID)
    }

    @objc private func removePressed(_ sender: NSMenuItem) {
        guard let albumID = sender.representedObject as? String, !selectedIDs.isEmpty else { return }
        onRemoveFromAlbum?(selectedIDs, albumID)
    }
}

// MARK: - what one search run did

/// The answer to 「查找丢失的文件…」, in library terms — one search, many entries.
public struct RelinkOutcome: Sendable, Equatable {
    public var relinked: [String] = []
    public var unmatched: [String] = []
    public var rejected: [String] = []
    public var failed: [String] = []
    /// Human-readable reasons for `failed`, one per entry.
    public var failures: [String] = []

    public init() {}

    public var message: String {
        let summary = MissingFileText.relinkSummary(relinked: relinked.count,
                                                    unmatched: unmatched.count,
                                                    rejected: rejected.count,
                                                    failed: failed.count)
        guard !failures.isEmpty else {
            return relinked.isEmpty ? "\(MissingFileText.findNothingFound)\n\(summary)" : summary
        }
        return summary + "\n" + failures.joined(separator: "\n")
    }
}

// MARK: - panels and sheets (the two modal steps)

@MainActor
public enum MissingFilesPanels {

    /// 「将从库中移除 N 个条目及其修改记录，原文件不受影响。」
    public static func confirmDelete(count: Int, in window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = MissingFileText.deleteConfirmTitle
        alert.informativeText = MissingFileText.deleteConfirmMessage(count: count)
        alert.alertStyle = .warning
        alert.addButton(withTitle: MissingFileText.deleteConfirmButton)
        alert.addButton(withTitle: MissingFileText.cancelButton)
        _ = window   // modal on whichever window is key; the sheet API would outlive the call
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Folders only — the search is recursive *inside* the chosen folder, so picking a single RAW
    /// would answer a question nobody asked.
    public static func chooseSearchFolder(in window: NSWindow?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.prompt = MissingFileText.findPanelButton
        panel.message = MissingFileText.findPanelMessage
        panel.title = MissingFileText.findPanelTitle
        _ = window
        // One panel per run, however many entries are missing: `runModal` blocks until the user has
        // answered, which is exactly the "批量：只开一次面板、搜一次" shape the task asks for.
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// One line after a search run: what happened, in the user's words.
    public static func report(_ outcome: RelinkOutcome, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = MissingFileText.findPanelTitle
        alert.informativeText = outcome.message
        alert.alertStyle = outcome.relinked.isEmpty ? .warning : .informational
        alert.addButton(withTitle: "好")
        _ = alert.runModal()
        _ = window
    }
}

// MARK: - the two verbs (one implementation, three browsers)

/// What 「从库中删除…」 and 「查找丢失的文件…」 *do*, once for the grid, the filmstrip and the photo
/// list.
///
/// The views differ in how they find out which rows the click meant; everything after that — the
/// sheet, the transaction, the folder panel, the search, the report, the reload — is the same, and
/// three copies of it would be three chances to disagree about the confirmation text or to forget
/// the `reload()`.
@MainActor
public enum MissingFilesActions {

    /// Confirm, delete, reload. Returns what was removed, or nil when the user cancelled / it failed.
    @discardableResult
    public static func delete(_ ids: [String], session: CatalogSession, window: NSWindow?) -> DeleteReport? {
        guard !ids.isEmpty else { return nil }
        // The sheet's count and the deleted count are the same array, by construction.
        guard MissingFilesPanels.confirmDelete(count: ids.count, in: window) else { return nil }
        return session.deleteAssets(ids)
    }

    /// One folder panel, one recursive search, one relink per hash-verified hit, then one report.
    ///
    /// Returns nil when the user cancelled the panel — the caller must not show an alert for that.
    @discardableResult
    public static func findLost(_ ids: [String], session: CatalogSession, window: NSWindow?) -> RelinkOutcome? {
        guard !ids.isEmpty else { return nil }
        guard let folder = MissingFilesPanels.chooseSearchFolder(in: window) else { return nil }
        let outcome = session.relinkMissing(ids, in: folder)
        MissingFilesPanels.report(outcome, in: window)
        return outcome
    }
}

// MARK: - the list row's pill

/// A small orange pill carrying 「原文件已移动」, for the photo list's 34 pt thumbnail.
///
/// A view rather than a `draw`-into-the-cell override because AppKit draws a view *before* its
/// subviews: a pill painted in the cell's own `draw` would be covered by the thumbnail square the
/// moment the row has an image, which is exactly the row this badge matters on.
public final class MissingFilePillView: NSView {

    public var text: String? {
        didSet {
            isHidden = text == nil
            needsDisplay = true
        }
    }

    public init(text: String? = nil) {
        self.text = text
        super.init(frame: .zero)
        isHidden = text == nil
        setAccessibilityElement(text != nil)
        if let text { setAccessibilityLabel(text) }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        guard let text, !text.isEmpty else { return }
        let attrs = MissingFileBadge.attributes(compact: true)
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = NSRect(x: 0, y: max(0, bounds.height - size.height - 2),
                          width: min(bounds.width, size.width + 8), height: size.height + 2)
        NSColor.systemOrange.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 4, y: pill.minY + 1), withAttributes: attrs)
    }
}

// MARK: - the inspector row

/// The line under the file name in 「信息」, for a missing original.
///
/// A real `NSView` rather than a `Text`: the inspector is SwiftUI, but its *facts* are asserted by
/// walking the AppKit tree (that is how `MarqueeText` is tested), and a `Text` that never reaches a
/// window is indistinguishable from a `Text` that is not in the body at all.
public final class MissingFileNoticeView: NSView {

    public private(set) var text: String

    public init(text: String = MissingFileText.moved) {
        self.text = text
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        setAccessibilityValue(text)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public func update(text: String) {
        guard text != self.text else { return }
        self.text = text
        setAccessibilityLabel(text)
        needsDisplay = true
    }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 14) }

    public override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: NSColor.systemOrange,
        ]
        let height = (text as NSString).size(withAttributes: attrs).height
        (text as NSString).draw(at: NSPoint(x: 0, y: floor((bounds.height - height) / 2)), withAttributes: attrs)
    }

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    public override func accessibilityLabel() -> String? { text }
    public override func accessibilityValue() -> Any? { text }
}

/// SwiftUI wrapper: one line, the card's width, present only while the anchor is missing.
public struct MissingFileNotice: View {
    public var text: String

    public init(text: String = MissingFileText.moved) { self.text = text }

    public var body: some View {
        MissingFileNoticeRepresentable(text: text)
            .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14)
            .accessibilityLabel(text)
    }
}

private struct MissingFileNoticeRepresentable: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> MissingFileNoticeView { MissingFileNoticeView(text: text) }

    func updateNSView(_ view: MissingFileNoticeView, context: Context) { view.update(text: text) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MissingFileNoticeView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: 14)
    }
}

extension InspectorPhotoInfo {
    /// The extra 「信息」 row for a missing original — `nil` for every healthy photo, which is what
    /// keeps the row from becoming a permanent "—".
    public static func missingNotice(isMissing: Bool) -> String? {
        isMissing ? MissingFileText.moved : nil
    }
}
