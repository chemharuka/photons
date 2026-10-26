import AppKit
import PhotonsCatalog

// MARK: - the remembered choice

/// What the import panel remembers between runs.
///
/// There is **one** checkbox in the panel — 包含子文件夹 — and this struct is the only place its
/// value is read from or written to `UserDefaults`. 目录不复制原文件 是产品决定 (库只保存索引、元数据与
/// 缩略图), not a preference, so it is not a checkbox and has no key: `options()` always asks the
/// engine for `.reference`.
///
/// The panel is shown on **every** import (用户要求: 每次导入都要确认这一步). The memory only decides
/// which state the box opens in, never whether the box appears.
public struct ImportPanelConfiguration: Equatable, Sendable {

    /// Written the moment the user confirms — and only then (`resolve(_:defaults:)`).
    public static let includeSubfoldersKey = "importIncludeSubfolders"

    /// First run: include subfolders, the same default as `ImportOptions.recursive`. The panel and
    /// an unattended `photonsctl library import` therefore start from the same answer.
    public static let includeSubfoldersDefault = true

    public var includeSubfolders: Bool

    public init(includeSubfolders: Bool = ImportPanelConfiguration.includeSubfoldersDefault) {
        self.includeSubfolders = includeSubfolders
    }

    // MARK: persistence

    /// Last answer, or `includeSubfoldersDefault` when the key was never written. `object(forKey:)`
    /// rather than `bool(forKey:)` on purpose: `bool` cannot tell "saved false" from "never saved",
    /// and the first run has to open ticked.
    public static func load(from defaults: UserDefaults) -> ImportPanelConfiguration {
        guard defaults.object(forKey: includeSubfoldersKey) != nil else {
            return ImportPanelConfiguration()
        }
        return ImportPanelConfiguration(includeSubfolders: defaults.bool(forKey: includeSubfoldersKey))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(includeSubfolders, forKey: Self.includeSubfoldersKey)
    }

    // MARK: what it means for the engine

    public func options() -> ImportOptions {
        ImportRequest.options(includeSubfolders: includeSubfolders)
    }

    /// Fold the panel's answer into (a) the import to run and (b) the choice to remember.
    ///
    /// Confirming writes the memory **only when the selection contains a folder** — 全选文件时递归开关
    /// 不起作用，把它记下来只会让下次打开面板时显示一个与上次无效操作有关的值。 Cancelling returns
    /// nil and touches nothing: a cancel is not an answer.
    public static func resolve(_ outcome: ImportPanelOutcome,
                               defaults: UserDefaults) -> ImportRequest? {
        switch outcome {
        case .cancelled:
            return nil
        case let .confirmed(sources, includeSubfolders):
            // An empty selection with .OK should not happen, but an import of nothing must never
            // reach the engine (it throws `importSourceMissing`).
            guard !sources.isEmpty else { return nil }
            let shape = ImportSelectionShape.classify(sources)
            if shape.remembersSubfolderChoice {
                ImportPanelConfiguration(includeSubfolders: includeSubfolders).save(to: defaults)
            }
            // With no folder in the selection the flag is not applicable; `true` is the engine's own
            // default and cannot hide an explicitly named file (single files are always imported).
            return ImportRequest(sources: sources,
                                 includeSubfolders: shape.hasFolders ? includeSubfolders : true)
        }
    }
}

/// What the panel's selection contains — the whole 包含子文件夹 judgement, as a value.
///
/// 判定表 (用户拍板, 照此写死):
///
/// | 选了什么        | 勾选框   | 导入什么                                   |
/// |-----------------|----------|--------------------------------------------|
/// | 只有文件        | 禁用     | 选中的文件                                 |
/// | 只有文件夹      | 启用     | 文件夹内（勾选递归 / 未勾选只看顶层）      |
/// | 文件 + 文件夹   | 启用     | 选中的文件照导 + 文件夹按勾选决定深度      |
///
/// The mixed row is the one that must not be simplified away: the box's scope is *only* the folder
/// part, and an explicitly named file is imported no matter what the box says.
public struct ImportSelectionShape: Equatable, Sendable {
    public var hasFiles: Bool
    public var hasFolders: Bool

    public init(hasFiles: Bool, hasFolders: Bool) {
        self.hasFiles = hasFiles
        self.hasFolders = hasFolders
    }

    /// Enabled whenever at least one folder is in the selection — including 混选.
    public var subfolderOptionEnabled: Bool { hasFolders }

    /// And only then is the choice remembered: with files only the box is inert, so writing it
    /// would poison the next run's default with a value the user never exercised.
    public var remembersSubfolderChoice: Bool { hasFolders }

    public static func classify(_ urls: [URL]) -> ImportSelectionShape {
        var files = false
        var folders = false
        for url in urls {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDir { folders = true } else { files = true }
            if files && folders { break }
        }
        return ImportSelectionShape(hasFiles: files, hasFolders: folders)
    }
}

/// What the panel was answered with, as a value — so the decision can be tested without a window.
public enum ImportPanelOutcome: Equatable, Sendable {
    case cancelled
    case confirmed(sources: [URL], includeSubfolders: Bool)
}

// MARK: - the request

/// One import, fully decided: which folders, and whether the walk goes into their subfolders.
///
/// **`mode` is always `.reference`.** 用户决定: 原文件不复制进库, 库只包含索引、元数据与缩略图。 The engine
/// keeps `ManagementMode.copy` because `photonsctl library import --mode copy` is a CLI freedom —
/// what is ruled out here is the GUI ever offering it.
public struct ImportRequest: Equatable, Sendable {
    public var sources: [URL]
    public var includeSubfolders: Bool

    public init(sources: [URL], includeSubfolders: Bool) {
        self.sources = sources
        self.includeSubfolders = includeSubfolders
    }

    /// The one builder for GUI import options. Both the panel configuration and the request go
    /// through it, so the "GUI = reference" rule cannot drift between the two.
    public static func options(includeSubfolders: Bool) -> ImportOptions {
        ImportOptions(mode: .reference, recursive: includeSubfolders)
    }

    public var options: ImportOptions {
        Self.options(includeSubfolders: includeSubfolders)
    }
}

// MARK: - the panel

/// 文件 ▸ 导入照片… 的选择面板: folders **or** individual photos (mixed, multi-select), with one
/// 包含子文件夹 box that only means something for the folders in the selection.
///
/// The box lives inside the panel (`accessoryView`) rather than in an alert after it: the user
/// answers "what to import" and "how deep" in one dialog, and Finder-style panels put exactly this
/// kind of per-operation switch at the bottom.
@MainActor
public enum ImportPanel {
    public static let prompt = "导入"
    public static let message = "选择要导入的照片或文件夹"
    public static let includeSubfoldersTitle = "包含子文件夹"

    /// One 20 pt checkbox with 5 pt of air above and below. The frame is required: an accessory
    /// view with a zero frame collapses and the box is invisible.
    public static let accessorySize = NSSize(width: 400, height: 30)

    /// Builds the panel and its checkbox. Construction only — nothing is shown, no run loop is
    /// entered, so a test can assert every knob.
    public static func make(_ configuration: ImportPanelConfiguration)
        -> (panel: NSOpenPanel, include: NSButton) {
        let panel = NSOpenPanel()
        // Both: a import is usually a folder, but "these four shots" is a real request too, and the
        // panel must not force the user to organise files before Import can be pressed.
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.resolvesAliases = true
        panel.message = message
        panel.prompt = prompt

        let include = NSButton(checkboxWithTitle: includeSubfoldersTitle, target: nil, action: nil)
        include.state = configuration.includeSubfolders ? .on : .off
        include.frame = NSRect(x: 12, y: 5, width: accessorySize.width - 24, height: 20)
        // Nothing is picked yet when the panel opens; `AccessoryStateWatcher` enables it as soon as
        // the selection contains a folder.
        include.isEnabled = false

        let accessory = NSView(frame: NSRect(origin: .zero, size: accessorySize))
        accessory.addSubview(include)
        // Must be set before `runModal()`: a panel copies (and dismisses) its accessory view on show.
        panel.accessoryView = accessory
        return (panel, include)
    }

    /// Grey the box while the selection has no folder in it, so it never looks like a switch that
    /// would do something. A 0.15 s timer is enough: this is a hint, not a data path.
    @MainActor
    final class AccessoryStateWatcher: NSObject {
        private let panel: NSOpenPanel
        private let include: NSButton
        private var timer: Timer?

        init(panel: NSOpenPanel, include: NSButton) {
            self.panel = panel
            self.include = include
        }

        func start() {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                // The timer fires on the main run loop (the panel is modal, so that is the only
                // loop running) — this asserts what the scheduler already guarantees.
                MainActor.assumeIsolated { self?.refresh() }
            }
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        /// The 判定表, applied to the live selection.
        func refresh() {
            let shape = ImportSelectionShape.classify(panel.urls)
            include.isEnabled = shape.subfolderOptionEnabled
            include.toolTip = shape.hasFolders ? nil : "只选了照片，子文件夹选项不适用"
        }
    }

    /// The real interaction: show, read the box, remember the choice (only on 导入).
    ///
    /// `present` is injectable so the interaction can be driven without a modal window; production
    /// passes nil and gets `runModal()`.
    public static func present(_ configuration: ImportPanelConfiguration,
                               defaults: UserDefaults,
                               present: ((NSOpenPanel) -> NSApplication.ModalResponse)? = nil)
        -> ImportRequest? {
        let (panel, include) = make(configuration)
        let watcher = AccessoryStateWatcher(panel: panel, include: include)
        watcher.start()
        let response = present?(panel) ?? panel.runModal()
        watcher.stop()

        guard response == .OK else {
            return ImportPanelConfiguration.resolve(.cancelled, defaults: defaults)
        }
        return ImportPanelConfiguration.resolve(
            .confirmed(sources: panel.urls, includeSubfolders: include.state == .on),
            defaults: defaults)
    }
}

// MARK: - progress

/// One progress tick: how many files of how many are done.
public struct ImportProgress: Equatable, Sendable {
    public var processed: Int
    public var total: Int

    public init(processed: Int, total: Int) {
        self.processed = processed
        self.total = total
    }

    /// 「导入中 12/48」. Before the walk knows its size (the enumeration hashes nothing, so this is
    /// only the first few milliseconds) it reads 「导入中…」 instead of a fake denominator.
    public var text: String {
        total > 0 ? "导入中 \(processed)/\(total)" : "导入中…"
    }
}

/// A cancellation flag that can be read from the import queue.
///
/// `ImportService.shouldCancel` is called on the background queue while the main actor sets it, so
/// it cannot be a bare `Bool`. The lock is the whole mechanism: one reader, one writer, no
/// ordering requirement beyond "the next file sees it".
public final class ImportCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}

// MARK: - progress line

/// The one line of import feedback: 进度 + 取消, at the bottom of the canvas.
///
/// No sheet, no alert: an import is a background job, and a modal would either block the window or
/// be dismissed before the user could read it. What the user can still do is cancel — until the
/// last file, which is why the button stays live for the whole run.
@MainActor
public final class ImportProgressBar: NSView {
    /// Fired by 取消. The coordinator stops between two files; nothing already imported is undone.
    public var onCancel: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var hideToken = 0

    /// What the line currently reads — the thing a test asserts instead of a screenshot.
    public var text: String { label.stringValue }
    public var isCancelEnabled: Bool { cancelButton.isEnabled }

    /// The button's own path, callable from a test (the button itself is private): `performClick`
    /// no-ops without a window, so the action is sent directly.
    public func sendCancel() { cancelButton.performClick(nil) }

    public init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.10).cgColor

        label.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail

        cancelButton.bezelStyle = .inline
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: 10.5)
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        addSubview(label)
        addSubview(cancelButton)
        isHidden = true
    }

    public required init?(coder: NSCoder) { fatalError("no nibs in this app") }

    public override var isFlipped: Bool { true }

    /// Show a line of text and stay up until `hide()` (or a newer `show(_:)`).
    public func show(_ text: String) {
        hideToken += 1
        label.stringValue = text
        cancelButton.isHidden = false
        cancelButton.isEnabled = true
        isHidden = false
        needsLayout = true
    }

    /// A finished run with failures: one word, no paragraph (`用户: 摘要文案暂时不需要`).
    public func showFailure(_ count: Int) {
        show("\(count) 个失败")
        cancelButton.isHidden = true
        cancelButton.isEnabled = false      // nothing left to cancel once the run is over
        scheduleHide(after: 4)
    }

    public func hide() {
        hideToken += 1
        label.stringValue = ""
        cancelButton.isEnabled = false
        isHidden = true
    }

    /// Auto-hide guarded by a token: a second import that starts within the window must not be
    /// hidden by the first one's timer.
    private func scheduleHide(after seconds: TimeInterval) {
        hideToken += 1
        let token = hideToken
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.isHidden = true
        }
    }

    public override func layout() {
        super.layout()
        let inset: CGFloat = 8
        let buttonWidth: CGFloat = cancelButton.isHidden ? 0 : 46
        label.frame = NSRect(x: inset, y: (bounds.height - 14) / 2,
                             width: max(0, bounds.width - inset * 2 - buttonWidth), height: 14)
        cancelButton.frame = NSRect(x: bounds.width - inset - buttonWidth + 4,
                                    y: (bounds.height - 16) / 2, width: buttonWidth - 4, height: 16)
    }

    @objc private func cancelTapped() { onCancel?() }
}
