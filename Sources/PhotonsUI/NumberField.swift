import AppKit
import SwiftUI

// MARK: - 派单 057: the number field, in the text layer

/// 派单 057 — 「第一次按键先清空」 happens **before the character lands**, not after.
///
/// 052 tried the same rule one layer up, in a SwiftUI `TextField`'s `Binding` setter: it cut
/// `1.485` + `5` down to `5` in `state.text` and expected SwiftUI to re-read the binding and repaint
/// the field. A focused `TextField` owns its own text storage; after the setter returns, nothing
/// rewrites the character the user just typed. `state.text` said `5`, the screen still said `1.485`,
/// and the next keystroke appended to `1.485` again — 「似乎没工作」. The pure-state tests were green
/// because they asked the rule, not the field.
///
/// The one hook that runs *before* the character is in the buffer is
/// `textView(_:shouldChangeTextIn:replacementString:)`, asked of the **field editor's delegate**.
/// For an `NSTextField` that delegate is the field itself (measured while building this: a separate
/// `NSTextFieldDelegate` is *not* asked), so the interception lives on `NumberTextField`, and
/// everything else — focus, the three exits of 047 — stays in a plain `NSTextFieldDelegate`,
/// `NumberFieldController`.
///
/// Deliberately **not** 「聚焦时全选」: editing begins on mouse-*down*, and the following mouse-up puts
/// the insertion point back where the user clicked, dropping the selection. That is a sometimes-works
/// bug, which is worse than a never-works one.

/// One row's number, as data: what the field reads while idle and while focused.
///
/// A value because the panel and `NumberFieldTypingTests` configure a field with it — the test cannot
/// hand the field a different resting/editing text than the panel does.
struct NumberFieldRow: Equatable {
    /// The number the row holds (the document's, or 白平衡's `draft ?? stored ?? shot`).
    var value: Double
    /// The row's travel; a submitted number is clamped into it (`SliderValueInput.resolve`).
    var range: ClosedRange<Double>
    /// The row's resting format (`%.2f EV`, `%.0f`, `%.0f K`, …).
    var format: String
    /// 052: decimals while editing (`2` for 曝光, `1` for a tone row, `0` = 047's clean number).
    var decimals: Int
    /// 052: how the resting readout rounds (`.asIs` keeps 曝光's `1.48`; `.outward` is whole numbers).
    var rounding: InspectorView.SliderRounding

    /// What the field reads when nobody is editing it (`1.48 EV`).
    var restingText: String { InspectorView.sliderText(format, value, rounding: rounding) }

    /// What it reads once focused (`1.48`): the number the user would type back.
    var editingText: String { SliderValueInput.editingText(value, decimals: decimals) }
}

/// 057: the field editor's delegate — focus, the buffer, and 047's three exits.
///
/// The rule that clears the buffer is *not* here (AppKit never asks this object before a character
/// lands); it is one line down in `NumberTextField.textView(_:shouldChangeTextInRanges:…)`, which
/// calls `shouldChange(_:range:replacement:)` below. Everything this class owns is the part of 047 /
/// 052 that did not move: `begin` arms the rule and swaps in the clean number, `↵` / `Esc` / losing
/// focus end the edit exactly as before, and a rejected string beeps, restores and writes nothing.
@MainActor
final class NumberFieldController: NSObject, NSTextFieldDelegate {

    /// 052's buffer (`text`, `pendingClear`) and its exit verdict (`submission(in:)`).
    private(set) var state = NumberFieldState()
    /// The row this field is showing — updated by SwiftUI, and optimistically by a commit so the
    /// readout already says what the model is about to hold (047's `state.end(sliderText(…))`).
    private(set) var row: NumberFieldRow
    /// The beep, injectable so 「非法输入 beep 一次」 is a test and not a code reading.
    var beep: () -> Void = { NSSound.beep() }
    /// Set by `NumberTextField.attach`; weak, the field owns nothing.
    weak var field: NumberTextField?

    private(set) var fontSize: CGFloat
    private var onCommit: (Double) -> Void

    init(row: NumberFieldRow,
         fontSize: CGFloat = 10,
         onCommit: @escaping (Double) -> Void) {
        self.row = row
        self.fontSize = fontSize
        self.onCommit = onCommit
        super.init()
    }

    /// SwiftUI re-rendered: adopt the row, but never overwrite a buffer the user is typing into.
    func update(row: NumberFieldRow, fontSize: CGFloat, onCommit: @escaping (Double) -> Void) {
        self.row = row
        self.fontSize = fontSize
        self.onCommit = onCommit
        field?.font = Self.font(size: fontSize)
        refreshDisplay()
    }

    // MARK: - 1. focus

    /// Focus gained: the resting readout becomes the clean number, and the next edit starts the
    /// buffer over. Idempotent — AppKit reports focus from two places (`becomeFirstResponder`, then
    /// `controlTextDidBeginEditing`, which is posted a run-loop turn later and is *not* reliable as
    /// the only signal: measured while building this).
    func focusGained() {
        guard !state.editing else { return }
        state.begin(row.editingText)
        // Only the field's own value is set here: while the shared field editor is still being handed
        // over, `currentEditor()` can be the *previous* field's editor, and writing into that would
        // corrupt a row nobody touched.
        field?.stringValue = row.editingText
        field?.textColor = .controlAccentColor
        if let buffer = editorString { state.record(buffer) }
    }

    /// AppKit's own "editing began" announcement, one tick behind focus. Kept because a field that
    /// begins editing without going through `becomeFirstResponder` must still arm the rule.
    func controlTextDidBeginEditing(_ notification: Notification) {
        focusGained()
    }

    // MARK: - 2. the keystroke, before it lands

    /// Called by `NumberTextField` from the field editor's pre-change callback — the only place a
    /// character can be stopped from landing inside the readout it is meant to replace.
    ///
    /// Returns `false` when this method already made the edit itself: the affected range has been
    /// rewritten to **the whole buffer**, so `1.48` + `5` is `5` and not `51.48`.
    func shouldChange(_ textView: NSTextView, range: NSRange, replacement: String?) -> Bool {
        // `nil` is an attribute-only change: no character lands, so nothing to replace and the rule
        // is not spent.
        guard let replacement else { return true }
        guard state.judgeFirstEdit(affectedRange: range, replacement: replacement) else { return true }

        let whole = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.textStorage?.replaceCharacters(in: whole, with: replacement)
        textView.setSelectedRange(NSRange(location: (replacement as NSString).length, length: 0))
        textView.didChangeText()
        state.record(textView.string)
        return false
    }

    /// Any other change (second keystroke, Backspace, a local edit, paste, undo) — the buffer this
    /// class judges on exit must be the one on screen.
    func controlTextDidChange(_ notification: Notification) {
        if let buffer = editorString { state.record(buffer) }
    }

    // MARK: - 3. the exits (`doCommandBy` and losing focus)

    /// `↵` commits, `Esc` cancels, everything else is the field editor's own business (047).
    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            state.record(textView.string)
            commit()
            leave()
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            state.record(textView.string)
            cancel()
            leave()
            return true

        default:
            return false
        }
    }

    /// Losing focus commits (047's third exit). A `↵`/`Esc` that already ended the edit is not
    /// committed twice: `commit()` is guarded by `state.editing`.
    /// The field stopped editing — and **why** decides the outcome (2026-10-28, user):
    ///
    ///   * `↵` (`reason == .return`) → **commit**: typing a number and pressing return is a write.
    ///   * losing focus by clicking anywhere else (`reason == .other`) → **cancel**: 「点击其他地方就
    ///     取消点击输入，并退回之前的值」. The buffer is dropped, the document is not touched, and the
    ///     readout goes back to the resting value — an accidental click in the canvas must not write a
    ///     half-typed number.
    ///
    /// `Esc` never reaches here (it ends editing through `cancel()`), so the three exits are: return →
    /// write, click-away → revert, Esc → revert.
    func controlTextDidEndEditing(_ notification: Notification) {
        // macOS spells this as the `NSTextMovement` key on the end-editing notification
        // (`NSTextMovementUserInfoKey`): 0x10 = return, 0x11 = tab, 0x12 = backtab, 0 = "other"
        // (a click somewhere else). There is no `.return` reason enum on this platform.
        let movement = (notification.userInfo?["NSTextMovement"] as? Int) ?? 0
        let keyboardConfirm = movement == 0x10 || movement == 0x11 || movement == 0x12
        if keyboardConfirm {
            commit()
        } else {
            // A field that was never being edited has nothing to revert, and `cancel()` would bump the
            // display for no reason.
            if state.editing { cancel() }
        }
        refreshDisplay()
    }

    // MARK: - the exits themselves

    /// `↵` / Tab: write it (which commits once), or beep and put the old number back. Losing focus by
    /// clicking elsewhere never reaches here — it cancels (see `controlTextDidEndEditing`).
    ///
    /// 052: an **empty** buffer is not junk — `↵` on a field the user emptied and then abandoned is
    /// a cancel: no write, no history, no beep (the old number is still there).
    func commit() {
        guard state.editing else { return }
        switch state.submission(in: row.range) {
        case .value(let typed):
            var next = row
            next.value = typed                       // the readout the model is about to hold
            row = next
            state.end(next.restingText)
            writeDisplay(next.restingText)
            onCommit(typed)
        case .cancelled:
            cancel()
        case .rejected:
            beep()
            state.end(row.restingText)
            writeDisplay(row.restingText)
        }
    }

    /// `Esc` (or an empty buffer + `↵`): nothing written, not even a beep — the user asked to leave.
    func cancel() {
        state.end(row.restingText)
        writeDisplay(row.restingText)
    }

    // MARK: - the field's text

    /// The buffer the field editor is holding, or the field's value when nobody is editing it.
    private var editorString: String? {
        guard let field else { return nil }
        if let textView = field.currentEditor() as? NSTextView { return textView.string }
        return field.stringValue
    }

    /// Put `text` on screen. Both the field editor and the field get it: while editing, the editor
    /// is the live storage and `NSTextField` copies it back out when the edit ends.
    private func writeDisplay(_ text: String) {
        guard let field else { return }
        if let textView = field.currentEditor() as? NSTextView {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        field.stringValue = text
        field.textColor = state.editing ? .controlAccentColor : .labelColor
    }

    /// The resting readout, for a field that is not being edited.
    private func refreshDisplay() {
        guard !state.editing, let field else { return }
        state.end(row.restingText)
        field.stringValue = row.restingText
        field.textColor = .labelColor
    }

    /// `↵` and `Esc` both leave the field (047: the number is a control, not a document editor).
    private func leave() {
        field?.window?.makeFirstResponder(nil)
    }

    static func font(size: CGFloat) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }
}

/// 057: the field, and the one method AppKit asks **before** a character lands.
///
/// The field editor's delegate is this field — AppKit installs the control itself as the delegate of
/// its field editor — so `NSTextView` asks *this* object for permission to change text, never the
/// `NSTextFieldDelegate` the panel handed it. That is why the rule has to live here: an outside
/// delegate, and the SwiftUI `Binding` of 052, are both told about the change too late.
final class NumberTextField: NSTextField {

    weak var controller: NumberFieldController?

    /// 057: focus is the start of the edit, and it arrives *here* first. `controlTextDidBeginEditing`
    /// is posted later (a run-loop turn) and cannot be the only place the rule is armed — a keystroke
    /// that lands in between would append to the readout, which is the bug this task is about.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { controller?.focusGained() }
        return became
    }

    /// The plural form **supersedes** the singular one and is the one `NSTextView` actually asks
    /// (`NSTextView.h`: the singular "will not be called if textView:shouldChangeTextInRanges: is
    /// implemented") — pinned, because implementing only the singular is silently dead.
    @objc func textView(_ textView: NSTextView, shouldChangeTextInRanges ranges: [NSValue],
                        replacementStrings: [String]?) -> Bool {
        let range = (ranges.first as? NSRange) ?? NSRange(location: 0, length: 0)
        return controller?.shouldChange(textView, range: range,
                                        replacement: replacementStrings?.first) ?? true
    }

    /// The singular form, for the paths AppKit still routes that way. Same rule, same one entry.
    @objc func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange,
                        replacementString: String?) -> Bool {
        controller?.shouldChange(textView, range: range, replacement: replacementString) ?? true
    }

    /// The one way a row's field is built.
    ///
    /// `NumberFieldView` and `NumberFieldTypingTests` both call this, so the field a test drives is
    /// configured exactly like the field on screen — a test cannot be greener than the app.
    func attach(_ controller: NumberFieldController, accessibilityID: String? = nil) {
        self.controller = controller
        controller.field = self
        delegate = controller

        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        isEditable = true
        isSelectable = true
        alignment = .right
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.usesSingleLineMode = true
        font = NumberFieldController.font(size: controller.fontSize)
        textColor = .labelColor
        stringValue = controller.row.restingText
        if let accessibilityID { setAccessibilityIdentifier(accessibilityID) }
    }
}

/// 057: the SwiftUI wrapper. It holds no text of its own — the `NSTextField` does, which is the
/// whole point: nothing above it can rewrite a character that already landed.
struct NumberFieldView: NSViewRepresentable {
    var row: NumberFieldRow
    var fontSize: CGFloat = 10
    var accessibilityID: String?
    let onCommit: (Double) -> Void

    func makeCoordinator() -> NumberFieldController {
        NumberFieldController(row: row, fontSize: fontSize, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NumberTextField {
        let field = NumberTextField()
        field.attach(context.coordinator, accessibilityID: accessibilityID)
        return field
    }

    func updateNSView(_ field: NumberTextField, context: Context) {
        context.coordinator.update(row: row, fontSize: fontSize, onCommit: onCommit)
        if field.controller !== context.coordinator { field.attach(context.coordinator, accessibilityID: accessibilityID) }
    }
}
