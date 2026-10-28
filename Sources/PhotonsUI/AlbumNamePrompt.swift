import AppKit

/// 相册名的一次性输入框（新建 / 重命名）。
///
/// 只有**取名字**这一件事需要模态；建、改名、删、加入、移出的真正动作都在
/// `CatalogSession` / `Catalog` 上，那些函数不弹窗、可被测试直接调用。所以「UI 里怎么问」
/// 和「库怎么改」是两层，测试不需要合成一次对话框点击。
enum AlbumNamePrompt {
    /// Returns the typed name, or nil when the user cancelled.
    static func run(title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = value
        field.placeholderString = "相册名"
        alert.accessoryView = field
        // 打开即选中旧名字：改名时最常见的是整名替换。
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
