import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 047 — 点数值，用键盘输入。
///
/// The contract has four parts, and each is asserted where it can actually be observed:
///
///   1. **只收数字**：`SliderValueInput.parse` —— 数字、可选负号、可选小数点；`abc` / 空 / `--3` /
///      `+3` / `1,5` / `nan` 全部 `nil`。这是**纯函数**，所以断言是真的执行，不是"读源码猜"。
///   2. **合法值 = 一条历史**：输入走的是拖动的同一条路（写 binding → gesture-end commit），这条在
///      模型层跑一遍：`applyEdit` + `commitEdit` 恰好 +1 条快照。
///   3. **非法值 = beep + 原值 + 不写历史**：`resolve` 返回 `.rejected`，`onCommit` 不被调用，于是
///      既没有 `applyEdit` 也没有 `commitEdit`。
///   4. **数值不被 format 截断**：`%.0f` 的行里输入 `0.5`，读回必须还是 `0.5`（旧实现用
///      `TextField(value:format: .number.precision(.fractionLength(0)))`，会把 0.5 变成 1）。
///
/// `swift test` 没有窗口会话：SwiftUI 不建 `NSTextField`，无障碍树也是空的（`DetailSectionTests` /
/// `SliderStyleTests` 记过同一堵墙）。所以这里断言的是**规则**与**面板怎么装配这个字段**；
/// 「按键 → 字段」的接线由 `NumberFieldTypingTests` 用真的 `NSWindow` + 真的 field editor 驱动
/// （057：那条才是 052 漏掉的东西）。
///
/// 派单 052 adds two contracts on top, and both are asserted where they can actually run:
///
///   5. **第一次按键先清空**（`NumberFieldState`）：点进 `1.5` 直接敲 `1` → 缓冲区 `1`（旧行为 `1.15`）；
///      先选过文本则不清、按键按选区替换；清空后 `↵` = 取消（不写历史、不 beep）。
///   6. **精度**：读数与文档不是同一个数 —— 曝光 `%.2f EV` + 0.01 网格；其它连续量整数、向外取整
///      （正 ceil / 负 floor），编辑态一位小数；本来整数的行（细节、白平衡 K）不变。
@MainActor
final class PanelEditingTests: XCTestCase {

    // MARK: - 1. 解析

    func testTheParserTakesNumbersAndRejectsEverythingElse() {
        // Numbers.
        XCTAssertEqual(SliderValueInput.parse("12"), 12)
        XCTAssertEqual(SliderValueInput.parse("-3"), -3)
        XCTAssertEqual(SliderValueInput.parse("0.5"), 0.5)
        XCTAssertEqual(SliderValueInput.parse("-0.25"), -0.25)
        XCTAssertEqual(SliderValueInput.parse(".5"), 0.5, "a leading point is still a number")
        XCTAssertEqual(SliderValueInput.parse("007"), 7)
        XCTAssertEqual(SliderValueInput.parse(" 12 "), 12, "surrounding whitespace is trimmed")
        XCTAssertEqual(SliderValueInput.parse("0"), 0)

        // Not numbers. `Double("…")` would say yes to several of these, which is why the parser exists.
        for junk in ["abc", "", "   ", "-", ".", "--3", "+3", "1,5", "1.2.3", "1e5", "nan", "inf",
                     "10 EV", "50%", "−3"] {
            XCTAssertNil(SliderValueInput.parse(junk), "\"\(junk)\" must not parse as a number")
        }
        print("input parser · accepts 12/-3/0.5/.5/007 · rejects abc/\"\"/--3/+3/1,5/1.2.3/1e5/nan")
    }

    func testAValueOutsideTheTravelIsClampedToIt() {
        // 曝光 is ±5 EV: typing 12 lands on the end of the slider, not on a beep.
        XCTAssertEqual(SliderValueInput.resolve("12", in: -5 ... 5), .value(5))
        XCTAssertEqual(SliderValueInput.resolve("-12", in: -5 ... 5), .value(-5))
        // 细节 is 0…100.
        XCTAssertEqual(SliderValueInput.resolve("-1", in: 0 ... 100), .value(0))
        XCTAssertEqual(SliderValueInput.resolve("140", in: 0 ... 100), .value(100))
        // 色温's travel is the decoder's, so 20000 K clamps to 12000.
        XCTAssertEqual(SliderValueInput.resolve("20000", in: WhiteBalance.temperatureRange),
                       .value(WhiteBalance.temperatureRange.upperBound))
    }

    // MARK: - 2. 编辑时显示的是"干净"的数字

    func testTheEditingTextIsTheCleanNumberAndRoundTrips() {
        XCTAssertEqual(SliderValueInput.editingText(2), "2", "no `+`, no `2.0`")
        XCTAssertEqual(SliderValueInput.editingText(-1.25), "-1.25")
        XCTAssertEqual(SliderValueInput.editingText(0.5), "0.5")
        XCTAssertEqual(SliderValueInput.editingText(5872), "5872", "no ` K`")
        XCTAssertEqual(SliderValueInput.editingText(0), "0")
        XCTAssertEqual(SliderValueInput.editingText(-0.0), "0", "no `-0`")

        // Round-trip: what the field shows while editing parses back to the same value, so a value the
        // user never touched is not silently changed by entering and leaving the field.
        for v in [0.0, 0.5, -0.5, 2.0, -3.25, 50.0, 5872.0, 1.75] {
            XCTAssertEqual(SliderValueInput.parse(SliderValueInput.editingText(v)) ?? .nan, v,
                           accuracy: 1e-9, "editingText/parse disagree at \(v)")
        }

        // Why editing text is not the row's `format`: `%.0f` truncates 0.5 to 0 — the exact bug 047
        // names ("输入 0.5 提交后读回仍是 0.5，不要被 format 截成 1").
        XCTAssertEqual(InspectorView.sliderText("%.0f", 0.5), "0",
                       "the resting readout rounds; the editing text must not")
        XCTAssertNotEqual(SliderValueInput.editingText(0.5), InspectorView.sliderText("%.0f", 0.5))

        // …and the resting readout still shows the row's own format (unit and all, `+` when the row's
        // format asks for one — 色调's does, 曝光's `%.2f EV` does not).
        XCTAssertEqual(InspectorView.sliderText("%.2f EV", 0.5), "0.50 EV")
        XCTAssertEqual(InspectorView.sliderText("%+.0f", 3), "+3")
        XCTAssertEqual(InspectorView.sliderText("%.0f K", 5872), "5872 K")
    }

    // MARK: - 3. 提交 = 一条历史；非法 = 不写历史

    /// Type `text` into a row the way `SliderNumberField.commit()` does: resolve, then (only on a value)
    /// write through the session and commit once. `onCommit` is what the row passes in.
    private func type(_ text: String,
                      into session: CatalogSession,
                      keyPath: WritableKeyPath<EditModel, Double>,
                      range: ClosedRange<Double>,
                      label: String) -> SliderValueInput.Outcome {
        let outcome = SliderValueInput.resolve(text, in: range)
        if case .value(let typed) = outcome {
            session.applyEdit { $0[keyPath: keyPath] = typed }
            session.commitEdit(label: label)
        }
        return outcome
    }

    func testATypedValueIsOneHistoryEntryAndReadsBackExactly() {
        let session = CatalogSession()
        let before = session.history.count

        // 对比 is a `%.0f` row, and 0.5 is the value the old numeric TextField used to round to 1.
        XCTAssertEqual(type("0.5", into: session, keyPath: \.light.contrast,
                            range: -100 ... 100, label: "对比"),
                       .value(0.5))
        XCTAssertEqual(session.edit.light.contrast, 0.5, accuracy: 1e-12,
                       "输入 0.5 读回还是 0.5 —— 不被 format 截成 1")
        XCTAssertEqual(session.history.count, before + 1, "一次输入 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "对比")

        // A second value is a second entry, and ⌘Z takes it back exactly (a typed value is not special).
        XCTAssertEqual(type("-2.5", into: session, keyPath: \.light.exposure,
                            range: -5 ... 5, label: "曝光"), .value(-2.5))
        XCTAssertEqual(session.edit.light.exposure, -2.5)
        XCTAssertEqual(session.history.count, before + 2)
        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.light.exposure, 0)
        print("typed input: 对比 0.5 → history +1 · 曝光 -2.5 → +2 · undo → "
              + "\(session.edit.light.exposure)")
    }

    func testARowAlreadyHoldingTheTypedValueWritesNoHistory() {
        let session = CatalogSession()
        let before = session.history.count
        XCTAssertEqual(type("0", into: session, keyPath: \.light.exposure,
                            range: -5 ... 5, label: "曝光"), .value(0))
        XCTAssertEqual(session.history.count, before,
                       "typing the value the row already holds must not grow the stack")
    }

    func testIllegalInputKeepsTheOldValueAndWritesNoHistory() {
        let session = CatalogSession()
        session.applyEdit { $0.light.exposure = 2 }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let before = session.history.count

        for junk in ["abc", "", "   ", "--3", "+3", "1,5", "nan"] {
            XCTAssertEqual(type(junk, into: session, keyPath: \.light.exposure,
                                range: -5 ... 5, label: "曝光"),
                           .rejected, "\"\(junk)\" must be rejected")
            XCTAssertEqual(session.edit.light.exposure, 2, "旧值必须还在（字段恢复原值）")
            XCTAssertEqual(session.history.count, before, "非法输入不写历史")
        }
        // The document is exactly what it was before the attempted input.
        XCTAssertEqual(session.history.currentSnapshot?.label, "拖动",
                       "no new snapshot was pushed, so the label is still the drag's")
        print("illegal input: \(["abc", "", "--3", "+3"].joined(separator: " / ")) → rejected, "
              + "value 2.0, history \(session.history.count) (unchanged)")
    }

    // MARK: - 4. 每张卡的每根滑杆都能输入

    func testEveryRowInEveryCardIsTypeable() {
        XCTAssertEqual(InspectorView.lightRows.map(\.title),
                       ["曝光", "对比", "高光", "中间调", "阴影", "白色", "黑色"])
        XCTAssertEqual(InspectorView.colorRows.map(\.title), ["自然饱和", "饱和"])
        XCTAssertEqual(InspectorView.detailContent.rows.map(\.title), ["降噪", "色彩降噪", "细节", "锐化"])
        XCTAssertEqual(InspectorView.whiteBalanceRows.map(\.title), ["色温", "色调"])

        for row in InspectorView.lightRows {
            XCTAssertTrue(row.editable, "Light 的「\(row.title)」必须能键盘输入")
        }
        for row in InspectorView.colorRows {
            XCTAssertTrue(row.editable, "Color 的「\(row.title)」必须能键盘输入")
        }
        for row in InspectorView.detailContent.rows {
            XCTAssertTrue(row.editable, "细节的「\(row.title)」必须能键盘输入")
        }
        for row in InspectorView.whiteBalanceRows {
            XCTAssertTrue(row.editable, "白平衡的「\(row.title)」必须能键盘输入")
        }
        // Four cards, fifteen rows, one entry point (047: 不许有的卡有、有的没有).
        let total = InspectorView.lightRows.count + InspectorView.colorRows.count
            + InspectorView.detailContent.rows.count + InspectorView.whiteBalanceRows.count
        XCTAssertEqual(total, 15)
        print("typeable rows: \(total) across 4 cards (Light 7 · Color 2 · 细节 4 · 白平衡 2)")
    }

    /// The row builder draws the field for `editable` rows and never opts a card out; the two entry
    /// points of 047 are the only places the behaviour lives.
    func testTheRowBuilderDrawsTheNumberFieldEverywhere() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        // 蒙版也要同一行之后，行视图搬到了 `SliderRow.swift`（`InspectorView.sliderRow` 只剩转交）：
        // 「数值框 / 输入走拖动那条路」这三条钉在**行视图自己**的文件上，其余仍钉在检查器上。
        let row = try String(contentsOf: Self.sliderRowSource, encoding: .utf8)

        XCTAssertTrue(row.contains("SliderNumberField(value: value.wrappedValue"),
                      "the one row view must draw the typeable number, not a Text")
        XCTAssertTrue(source.contains("SliderRow(title: title"),
                      "the inspector's cards must go through that one row view")
        XCTAssertFalse(source.contains("editable: false"),
                       "no card may opt out of typing (047: 所有卡片统一)")
        // 2026-10-28: 效果 (暗角 + 颗粒) is the fifth card whose rows come from its own table; 黑白
        // (the switch + eight 黑白混合 rows) makes six, 色彩分级's nine rows make seven, and the 细节
        // card's 色差 R/B rows (their own table) make eight.
        XCTAssertEqual(Self.occurrences(of: "editable: row.editable", in: source), 8,
                       "Light / 黑电平 / Color / 细节 / 效果 / 黑白 all take the fact from their row table")

        // A typed value takes the drag's path: the binding write, then the gesture-end commit.
        XCTAssertTrue(row.contains("value.wrappedValue = typed"))
        XCTAssertTrue(row.contains("onEditingChanged(false)"))

        // 057: the row still builds the same field (an `NSTextField` under SwiftUI now), and the three
        // exits + the beep live in one place — `NumberField.swift`, pinned there rather than here.
        XCTAssertTrue(source.contains("NumberFieldView(row: NumberFieldRow(value: value"),
                      "SliderNumberField 必须把行数据交给 AppKit 那一层")
        let fieldSource = try String(contentsOf: Self.numberFieldSource, encoding: .utf8)
        XCTAssertTrue(fieldSource.contains("#selector(NSResponder.insertNewline(_:))"), "↵ 提交")
        XCTAssertTrue(fieldSource.contains("#selector(NSResponder.cancelOperation(_:))"), "Esc 取消")
        XCTAssertTrue(fieldSource.contains("func controlTextDidEndEditing("), "失焦提交")
        XCTAssertTrue(fieldSource.contains("NSSound.beep()"), "非法输入 beep 一次")
        XCTAssertTrue(fieldSource.contains("func textView(_ textView: NSTextView, shouldChangeTextInRanges ranges: [NSValue]"),
                      "057: 规则挂在 field editor 真正会问的那一个回调上（复数形式）")
    }

    // MARK: - 5. 052：第一次按键先清空缓冲区

    /// 052 ①. 点进字段直接敲 `1`、`5` → 缓冲区是 `15`，不是 `1.55` / `2.515`。
    ///
    /// The machine is `NumberFieldState`: `begin` is focus, `typed(from:to:)` is the field's binding
    /// being written (SwiftUI hands back the changed string, never the key), `end` is any exit.
    func testTheFirstKeystrokeStartsTheBufferOver() {
        // 「点进去直接敲 1.5」：字段里本来躺着 `1.5`，光标落在中间，敲 `1`。
        var state = NumberFieldState()
        state.begin("1.5")
        XCTAssertTrue(state.pendingClear, "focus arms the rule")
        XCTAssertEqual(state.typed(from: "1.5", to: "11.5"), .clear(typed: "1"),
                       "第一次按键不能插进原来的 1.5 里（旧行为 → 1.15）")
        XCTAssertEqual(state.text, "1", "缓冲区只剩刚敲的那个字符")

        // A keystroke that changes nothing (typing `.` over the selected `.`) is not a keystroke: it
        // must not empty the buffer, and it must not spend the rule either.
        var noop = NumberFieldState()
        noop.begin("1.5")
        XCTAssertNil(noop.typed(from: "1.5", to: "1.5"))
        XCTAssertEqual(noop.text, "1.5")
        XCTAssertTrue(noop.pendingClear, "the rule is still armed after a no-op")
        XCTAssertNil(noop.typed(from: "1", to: "15"))

        // 此后照常输入：再敲 `5` → `15`，三个字符就是三个字符。
        XCTAssertNil(state.typed(from: "1", to: "15"), "第二次按键不再清空")
        XCTAssertEqual(state.text, "15")
        XCTAssertNil(state.typed(from: "15", to: "150"))
        XCTAssertEqual(state.text, "150", "连打三个字符得到三个字符")

        // 从 0 起手也一样：0 → 1 → 15 → 15.5，逐步累积。
        var fromZero = NumberFieldState()
        fromZero.begin("0")
        XCTAssertEqual(fromZero.typed(from: "0", to: "01"), .clear(typed: "1"))
        XCTAssertNil(fromZero.typed(from: "1", to: "15"))
        XCTAssertNil(fromZero.typed(from: "15", to: "15."))
        XCTAssertNil(fromZero.typed(from: "15.", to: "15.5"))
        XCTAssertEqual(fromZero.text, "15.5")

        // 粘贴一整段也算「第一次按键」：缓冲区就是粘贴的内容。
        var pasted = NumberFieldState()
        pasted.begin("5872")
        XCTAssertEqual(pasted.typed(from: "5872", to: "58724000"), .clear(typed: "4000"),
                       "在末尾粘贴 4000 → 缓冲区只有 4000（不是 58724000）")
        print("first keystroke: 1.5 + 「1」 → 1（旧：1.15）· 再「5」→ 15 · 三字符 → 150")
    }

    /// 052 ①·②: 用户先选过文本 → 不清空，按键按选区替换（那是「只想改一位」）。
    func testASelectedRangeIsNotClearedAndTheKeyReplacesIt() {
        var state = NumberFieldState()
        state.begin("1.5")
        // 选中 `5` 再敲 `9`：缓冲区保留 `1.`，`5` 被换掉 —— 不整段清空。
        XCTAssertEqual(state.typed(from: "1.5", to: "1.9"), .inPlace)
        XCTAssertEqual(state.text, "1.9", "选过文本就不清空，按键只替换选区")

        // 全选再敲一个数字：同样按选区替换（结果等于「清空后输入」，但走的是选区那条路）。
        var all = NumberFieldState()
        all.begin("1.5")
        XCTAssertEqual(all.typed(from: "1.5", to: "2"), .inPlace)
        XCTAssertEqual(all.text, "2")

        // 选区被删掉（无替换字符）时仍是「第一次按键」—— Backspace 就是清空。
        var deleted = NumberFieldState()
        deleted.begin("1.5")
        XCTAssertEqual(deleted.typed(from: "1.5", to: ""), .clear(typed: ""))
        XCTAssertEqual(deleted.text, "", "第一次按键是 Backspace → 空缓冲")
        print("selection: 1.5 选 `5` 敲 `9` → 1.9（不清空）· 全选敲 `2` → 2 · 首键 Backspace → 空")
    }

    /// 052 ①: 清空后直接 `↵`（缓冲区为空）= 取消 —— 值不变、`history.count` 不变、不 beep。
    func testAnEmptyBufferOnReturnCancelsAndWritesNoHistory() {
        let session = CatalogSession()
        session.applyEdit { $0.light.exposure = 1.5 }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let before = session.history.count

        var state = NumberFieldState()
        state.begin("1.50")
        XCTAssertEqual(state.typed(from: "1.50", to: "1.5"), .clear(typed: ""), "首键 Backspace 清空")
        XCTAssertEqual(state.text, "")
        XCTAssertEqual(state.submission(in: -5 ... 5), .cancelled,
                       "空缓冲不是非法输入：取消，不是 beep")

        // What `SliderNumberField.commit()` does with `.cancelled`: cancel(), no `onCommit`, so no
        // `applyEdit` and no `commitEdit`.
        XCTAssertEqual(session.edit.light.exposure, 1.5, "旧值原封不动")
        XCTAssertEqual(session.history.count, before, "空缓冲 ↵ 不写历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "拖动", "快照栈没有被推新条目")

        // …and the two other exit verdicts still say what 047 said they say.
        state.begin("abc")
        XCTAssertEqual(state.submission(in: -5 ... 5), .rejected)
        state.begin("1.48")
        XCTAssertEqual(state.submission(in: -5 ... 5), .value(1.48))
        print("empty buffer ↵: value 1.5, history \(before) (unchanged) · junk still rejected")
    }

    // MARK: - 6. 052：精度（显示 / 编辑态 / 存储）

    /// 052 ②: 编辑态才看得到小数。曝光两位，其它连续量最多一位，整数行不加 `.0`。
    func testTheEditingTextShowsDecimalsOnlyWhileEditing() {
        // 曝光：两位小数，但整数值仍是整数（`2`，不是 `2.00`）。
        XCTAssertEqual(SliderValueInput.editingText(1.4829, decimals: 2), "1.48")
        XCTAssertEqual(SliderValueInput.editingText(-0.4, decimals: 2), "-0.40")
        XCTAssertEqual(SliderValueInput.editingText(2, decimals: 2), "2")
        // 其它连续量：一位小数。
        XCTAssertEqual(SliderValueInput.editingText(1.4829, decimals: 1), "1.5")
        XCTAssertEqual(SliderValueInput.editingText(-0.4, decimals: 1), "-0.4")
        XCTAssertEqual(SliderValueInput.editingText(2, decimals: 1), "2", "整数行不要长出 .0")
        // 不进位的零不打印成 `-0` / `0.0`。
        XCTAssertEqual(SliderValueInput.editingText(-0.04, decimals: 1), "0")
        XCTAssertEqual(SliderValueInput.editingText(0, decimals: 2), "0")
        // decimals 0 = 047 的原样：`%.0f` 行里存着 0.5，编辑态必须还是 0.5（不许被格式截断）。
        XCTAssertEqual(SliderValueInput.editingText(0.5, decimals: 0), "0.5")
        print("editing text: 1.4829 → 1.48 (曝光) / 1.5 (其它) · 2 → 2 · 0.5 (decimals 0) → 0.5")
    }

    /// 052 ②: 面板读数 = 整数、向外取整（正 ceil / 负 floor），曝光是唯一的例外（两位小数）。
    func testTheReadoutIsAWholeNumberAndExposureKeepsTwoDecimals() {
        let exposure = InspectorView.lightRows[0]
        XCTAssertEqual(exposure.rounding, .asIs, "曝光是唯一的 .asIs 行")
        XCTAssertEqual(exposure.decimals, 2)
        XCTAssertEqual(exposure.quantum, 0.01, "曝光存在 0.01 的网格上")

        // 曝光：两位小数，整数化 / 向外取整都不许碰它。
        XCTAssertEqual(InspectorView.sliderText(exposure.format, 1.4829, rounding: exposure.rounding),
                       "1.48 EV")
        XCTAssertEqual(InspectorView.sliderText(exposure.format, -0.4, rounding: exposure.rounding),
                       "-0.40 EV")
        XCTAssertEqual(InspectorView.sliderText(exposure.format, 2, rounding: exposure.rounding),
                       "2.00 EV")

        // 其它连续量：整数 + 向外取整。
        let others = Array(InspectorView.lightRows.dropFirst()) + InspectorView.colorRows
        for row in others {
            XCTAssertEqual(row.rounding, .outward, "\(row.title) 用向外取整")
            XCTAssertEqual(row.decimals, 1, "\(row.title) 编辑态一位小数")
            XCTAssertEqual(row.quantum, 0, "\(row.title) 不额外量化")
            XCTAssertEqual(row.format, "%.0f")
        }
        let whole = InspectorView.lightRows[1].format          // "%.0f"
        XCTAssertEqual(InspectorView.sliderText(whole, 1.4829, rounding: .outward), "2", "正数向上取整")
        XCTAssertEqual(InspectorView.sliderText(whole, 1.06, rounding: .outward), "2")
        XCTAssertEqual(InspectorView.sliderText(whole, 0.4, rounding: .outward), "1")
        XCTAssertEqual(InspectorView.sliderText(whole, 2.0, rounding: .outward), "2")
        XCTAssertEqual(InspectorView.sliderText(whole, -0.4, rounding: .outward), "-1", "负数向下取整")
        XCTAssertEqual(InspectorView.sliderText(whole, -1.5, rounding: .outward), "-2")
        XCTAssertEqual(InspectorView.sliderText(whole, -2.0, rounding: .outward), "-2")
        XCTAssertEqual(InspectorView.sliderText(whole, 0.0, rounding: .outward), "0")
        XCTAssertEqual(InspectorView.sliderText(whole, -0.0, rounding: .outward), "0", "不显示 -0")
        XCTAssertEqual(InspectorView.sliderText(whole, 23.7413, rounding: .outward), "24")

        // 不误伤：细节四行仍是整数、白平衡仍是 `5872 K`（不是 `5872.0 K`），色调整数带符号。
        for row in InspectorView.detailContent.rows {
            XCTAssertEqual(row.format, "%.0f")
            XCTAssertEqual(InspectorView.sliderText(row.format, 50), "50")
            XCTAssertEqual(InspectorView.sliderText(row.format, 0), "0")
        }
        XCTAssertEqual(InspectorView.sliderText(InspectorView.whiteBalanceRows[0].format, 5872), "5872 K")
        XCTAssertEqual(InspectorView.sliderText(InspectorView.whiteBalanceRows[1].format, -3), "-3")
        XCTAssertEqual(InspectorView.sliderText(InspectorView.whiteBalanceRows[1].format, 3), "+3")
        print("readout: 曝光 1.4829 → 1.48 EV · 对比 1.4829 → 2 / -0.4 → -1 / 0 → 0 · "
              + "细节 50 → 50 · 白平衡 5872 → 5872 K")
    }

    /// 052 ②: 曝光全链路 —— 拖动值 `1.4829` → 显示 `1.48 EV` → 编辑态 `1.48` → 文档 `1.48`。
    func testExposureRunsTheWholeChainFromTheSliderToTheDocument() {
        let row = InspectorView.lightRows[0]

        // 1. 显示（拖动时面板上看到的）
        XCTAssertEqual(InspectorView.sliderText(row.format, 1.4829, rounding: row.rounding), "1.48 EV")
        // 2. 点进去：编辑态
        let editing = SliderValueInput.editingText(1.4829, decimals: row.decimals)
        XCTAssertEqual(editing, "1.48", "编辑态不许露出 1.4829")
        // 3. ↵ 提交：写进文档（量化到 0.01，一条历史）
        guard case .value(let typed) = SliderValueInput.resolve(editing, in: row.range) else {
            return XCTFail("「\(editing)」必须是一个数")
        }
        let session = CatalogSession()
        let before = session.history.count
        session.applyEdit { $0.light.exposure = InspectorView.quantized(typed, quantum: row.quantum) }
        session.commitEdit(label: row.title)
        XCTAssertEqual(session.edit.light.exposure, 1.48, accuracy: 1e-12)
        XCTAssertLessThan(abs(session.edit.light.exposure * 100
                              - (session.edit.light.exposure * 100).rounded()), 1e-9,
                          "exposure * 100 必须是整数")
        XCTAssertEqual(session.history.count, before + 1, "一次输入 = 一条历史")
        // 4. 回到显示
        XCTAssertEqual(InspectorView.sliderText(row.format, session.edit.light.exposure,
                                                rounding: row.rounding), "1.48 EV")

        // 拖动路径：任何落点都被量化到 0.01，文档里绝不出现 1.48293…
        for raw in [1.4829, -0.04, 0.123456, -2.71828, 4.999] {
            let stored = InspectorView.quantized(raw, quantum: row.quantum)
            XCTAssertLessThan(abs(stored * 100 - (stored * 100).rounded()), 1e-9,
                              "\(raw) → \(stored) 不在 0.01 的网格上")
        }
        XCTAssertEqual(InspectorView.quantized(-0.04, quantum: 0.01), -0.04, accuracy: 1e-12)
        print("exposure chain: 1.4829 → 显示 1.48 EV → 编辑 1.48 → 文档 "
              + "\(session.edit.light.exposure) (×100 = \(session.edit.light.exposure * 100))")
    }

    /// 052 ②: 反证 ——「向外取整」只作用于非曝光的连续量；套到曝光上，上一条测试立刻红。
    func testOutwardRoundingIsNotAppliedToExposure() {
        let exposure = InspectorView.lightRows[0]
        XCTAssertEqual(exposure.rounding, .asIs)
        XCTAssertEqual(InspectorView.sliderText(exposure.format, 1.4829, rounding: exposure.rounding),
                       "1.48 EV")
        // If 052's outward rule were applied to 曝光 as well, the readout would be 2.00 EV — the
        // integer display the user explicitly excepted this row from.
        XCTAssertEqual(InspectorView.sliderText(exposure.format, 1.4829, rounding: .outward),
                       "2.00 EV", "…套上 ceil 就是 2.00 EV")
        XCTAssertNotEqual(InspectorView.sliderText(exposure.format, 1.4829, rounding: exposure.rounding),
                          InspectorView.sliderText(exposure.format, 1.4829, rounding: .outward))
        XCTAssertEqual(InspectorView.lightRows.dropFirst().map(\.rounding),
                       Array(repeating: .outward, count: 6))
        XCTAssertEqual(InspectorView.colorRows.map(\.rounding), Array(repeating: .outward, count: 2))
        print("negative control: 曝光 1.4829 with .outward → 2.00 EV (wrong) · with .asIs → 1.48 EV")
    }

    /// 052/057: the field is built on the state machine — a rule that lives only in a test is dead code.
    ///
    /// After 057 the state machine is asked in two places, both pinned here: `judgeFirstEdit` from the
    /// field editor's pre-change callback (the live decision), and `submission(in:)` from the exits.
    func testTheNumberFieldIsBuiltOnTheBufferStateMachine() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("mutating func judgeFirstEdit(affectedRange: NSRange, replacement: String) -> Bool"),
                      "057: 判定就是「这个范围要改成整段吗」")
        XCTAssertTrue(source.contains("mutating func record(_ buffer: String)"),
                      "057: 缓冲区记的是字段 editor 真正持有的字符串")

        let fieldSource = try String(contentsOf: Self.numberFieldSource, encoding: .utf8)
        XCTAssertTrue(fieldSource.contains("private(set) var state = NumberFieldState()"),
                      "字段必须持有 NumberFieldState")
        XCTAssertTrue(fieldSource.contains("state.judgeFirstEdit(affectedRange: range, replacement: replacement)"),
                      "字符落地之前的那一个回调必须问规则")
        XCTAssertTrue(fieldSource.contains("state.begin(row.editingText)"),
                      "聚焦即进入待输入，并按行的 decimals 取编辑态文本")
        XCTAssertTrue(fieldSource.contains("switch state.submission(in: row.range)"),
                      "↵/失焦的三种结果由 state 给出（含空缓冲 = 取消）")
        XCTAssertTrue(fieldSource.contains("textView.textStorage?.replaceCharacters(in: whole, with: replacement)"),
                      "057: 范围改成整段后由我们自己落地，AppKit 不能再按原范围插一次")

        XCTAssertTrue(source.contains("binding(row.keyPath, quantum: row.quantum)"),
                      "Light/Color 的滑杆按行的 quantum 写入文档")
        XCTAssertTrue(source.contains("Self.quantized(newValue, quantum: quantum)"))
    }

    // MARK: - helpers

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The panel's one row view — every card, 蒙版 included, draws through it.
    private static var sliderRowSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/PhotonsUI/SliderRow.swift")
    }

    private static var inspectorSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    /// 057: the AppKit half of the field — where the keystroke is intercepted.
    private static var numberFieldSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/PhotonsUI/NumberField.swift")
    }
}
