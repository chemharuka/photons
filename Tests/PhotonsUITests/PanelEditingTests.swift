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
/// `SliderStyleTests` 记过同一堵墙）。所以**按键到字段的接线**（↵ / Esc / 失焦，`NSSound.beep()`）
/// 按源码钉（`testTheFieldWiresReturnEscapeAndBlur`），其余全部按值断言。
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
                       ["曝光", "对比", "高光", "阴影", "白色", "黑色"])
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
        // Four cards, fourteen rows, one entry point (047: 不许有的卡有、有的没有).
        let total = InspectorView.lightRows.count + InspectorView.colorRows.count
            + InspectorView.detailContent.rows.count + InspectorView.whiteBalanceRows.count
        XCTAssertEqual(total, 14)
        print("typeable rows: \(total) across 4 cards (Light 6 · Color 2 · 细节 4 · 白平衡 2)")
    }

    /// The row builder draws the field for `editable` rows and never opts a card out; the two entry
    /// points of 047 are the only places the behaviour lives.
    func testTheRowBuilderDrawsTheNumberFieldEverywhere() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)

        XCTAssertTrue(source.contains("SliderNumberField(value: value.wrappedValue"),
                      "sliderRow must draw the typeable number, not a Text")
        XCTAssertFalse(source.contains("editable: false"),
                       "no card may opt out of typing (047: 所有卡片统一)")
        XCTAssertEqual(Self.occurrences(of: "editable: row.editable", in: source), 3,
                       "Light / Color / 细节 all take the fact from their row table")

        // A typed value takes the drag's path: the binding write, then the gesture-end commit.
        XCTAssertTrue(source.contains("value.wrappedValue = typed"))
        XCTAssertTrue(source.contains("onEditingChanged(false)"))

        // The field itself: three exits, and the beep only on a rejected string.
        XCTAssertTrue(source.contains(".onSubmit { commit(); focused = false }"), "↵ 提交")
        XCTAssertTrue(source.contains(".onExitCommand { cancel() }"), "Esc 取消")
        XCTAssertTrue(source.contains("else if editing { commit() }"), "失焦提交")
        XCTAssertTrue(source.contains("NSSound.beep()"), "非法输入 beep 一次")
    }

    // MARK: - helpers

    private static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    private static var inspectorSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }
}
