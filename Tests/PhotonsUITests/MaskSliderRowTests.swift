import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 蒙版的滑杆 = 其它卡的滑杆：**标签双击复位**（进 `PanelResets`，一条历史）、**点数值可输入**
/// （`NumberFieldView` 的规则：↵ 提交 / Esc 取消 / 超范围钳制）、**样式取自 `SliderStyle`**
/// （`InspectorView.SliderRowStyle` + `SliderShape` + `SliderValueMap.rowHeight`）。
///
/// 每一条断言都钉在能真正跑起来的地方，而不是「读源码猜」：
///
///   1. **每一根都复位**（`testEveryMaskParameterRowGoesBackToItsDefaultInOneSnapshot`,
///      `testEveryShapeRowGoesBackToTheCoreDefaultInOneSnapshot`）：`MaskSliderRow.all` 与
///      `MaskShapeSliderRow.rows(for:)` 是卡片真正迭代的那两张表，所以「每一根」是循环；前后值、
///      `history.count` 的增量逐行打印。
///   2. **双击真的接在这一行上**（`testDoubleClickingTheRenderedLabelResetsThatParameterInOneSnapshot`）：
///      面板渲染出来之后，在「羽化」的标签上发两次真实的 `NSEvent`（第二次 `clickCount = 2`）——
///      文档回默认、历史 +1。卡片标题同理（`…TheCardTitle…`）。
///   3. **点数值真的是第一响应者**（`…TheNumberBecomesTheFirstResponder…`）：真的 `NSWindow` + 真的
///      `NSHostingView` + 真的 field editor，用的是面板自己渲染出来的那一个 `NumberTextField`。
///   4. **反证**（`testTheOldBareSliderRowCannotPassTheSameTwoAssertions`）：同一台机器、同一个窗口，
///      把行换回「裸 `Slider` + `Text`」的旧样子，同样两条探测（找数值框 / 真双击复位）就必然红。
@MainActor
final class MaskSliderRowTests: XCTestCase {

    // MARK: - 1. 每一根参数行：双击 → Core 默认，历史恰好 +1

    func testEveryMaskParameterRowGoesBackToItsDefaultInOneSnapshot() {
        // The two tables the card iterates: 不透明度/羽化/精修 + 强度/曝光/…/饱和.
        XCTAssertEqual(MaskSliderRow.all.map(\.title),
                       ["不透明度", "羽化", "精修",
                        "强度", "曝光", "对比", "高光", "阴影", "白色", "黑色",
                        "色温", "色调", "色相", "饱和"],
                       "the mask rows are the mask-level three plus the eleven local ones, in draw order")
        XCTAssertEqual(MaskSliderRow.all.count, 14)

        for row in MaskSliderRow.all {
            let session = CatalogSession()
            let mask = try! XCTUnwrap(session.addMask(kind: .linearGradient))   // creates + selects
            let resets = PanelResets(session: session)

            // Push it somewhere that is *not* the default (a drag's release: one snapshot).
            let away = valueAway(from: row.defaultValue, in: row.range)
            XCTAssertNotEqual(away, row.defaultValue)
            XCTAssertTrue(row.write(away, into: session, maskID: mask.id, commit: true),
                          "\(row.title): the drag path must write")
            let before = session.history.count
            let current = try! XCTUnwrap(session.edit.masks.first { $0.id == mask.id })
            XCTAssertEqual(row.display(current), away, accuracy: 1e-9,
                           "\(row.title): the document holds what the drag wrote")

            XCTAssertTrue(resets.mask(row, in: current),
                          "\(row.title): 双击标签必须复位（其它卡一样）")
            let after = try! XCTUnwrap(session.edit.masks.first { $0.id == mask.id })
            XCTAssertEqual(row.display(after), row.defaultValue, accuracy: 1e-9,
                           "\(row.title): 回到 Core 的默认，不是 0，也不是上一次的值")
            XCTAssertEqual(session.history.count, before + 1,
                           "\(row.title): 双击 = **一条**历史")
            XCTAssertEqual(session.history.currentSnapshot?.label, row.label,
                           "\(row.title): the undo label is this row's")

            // 已经默认就不写历史（一个手滑的双击不该截断 redo 分支）。
            let settled = session.history.count
            XCTAssertFalse(resets.mask(row, in: after), "\(row.title): nothing to do")
            XCTAssertEqual(session.history.count, settled)

            // ⌘Z 一步回到拖动后的值。
            XCTAssertTrue(session.undo())
            let undone = try! XCTUnwrap(session.edit.masks.first { $0.id == mask.id })
            XCTAssertEqual(row.display(undone), away, accuracy: 1e-9, "\(row.title): ⌘Z 一步回来")

            print("MASK reset · \(row.title): \(fmt(away)) → \(fmt(row.defaultValue))"
                  + " · history +1 · undo → \(fmt(row.display(undone)))")
        }
    }

    /// The mask-level defaults are Core's, not literals: 不透明度 100 %, 羽化/精修 0 — and 强度 100,
    /// not 0 (a reset that wrote 0 would switch the whole local adjustment off).
    func testTheMaskDefaultsComeFromCoreAndNotFromZero() {
        let rows = Dictionary(uniqueKeysWithValues: MaskSliderRow.all.map { ($0.title, $0) })
        XCTAssertEqual(rows["不透明度"]!.defaultValue, Mask.fallback.opacity * 100)
        XCTAssertEqual(rows["羽化"]!.defaultValue, Mask.fallback.feather)
        XCTAssertEqual(rows["精修"]!.defaultValue, Mask.fallback.refine)
        XCTAssertEqual(rows["强度"]!.defaultValue, LocalAdjustments.identity.amount)
        XCTAssertNotEqual(rows["强度"]!.defaultValue, 0,
                          "强度 0 = 蒙版不起作用：默认必须来自 LocalAdjustments.identity（100）")
        XCTAssertEqual(rows["强度"]!.defaultValue, 100)

        // 不透明度 shows a percentage and stores a fraction — the one conversion in the row.
        XCTAssertEqual(rows["不透明度"]!.document(35), 0.35, accuracy: 1e-12)
        XCTAssertEqual(rows["不透明度"]!.display(Mask.fallback), 100, accuracy: 1e-12)
        // …and a typed number outside the travel is clamped into it, never rejected (a slider's travel
        // is a fact about the control).
        XCTAssertEqual(rows["羽化"]!.document(5), 1, accuracy: 1e-12)
        XCTAssertEqual(rows["羽化"]!.document(-5), 0, accuracy: 1e-12)
        print("MASK defaults · 不透明度 \(rows["不透明度"]!.defaultValue) · 羽化 "
              + "\(rows["羽化"]!.defaultValue) · 精修 \(rows["精修"]!.defaultValue)"
              + " · 强度 \(rows["强度"]!.defaultValue)")
    }

    // MARK: - 2. 形状行：中点 / 半径 / 角度 / 容差 / 下限 / 上限 / 软边

    func testEveryShapeRowGoesBackToTheCoreDefaultInOneSnapshot() {
        // One mask per shape kind, so every row of every shape is walked exactly once.
        let shapes: [(String, MaskCreationKind)] = [
            ("线性渐变", .linearGradient), ("径向渐变", .radialGradient),
            ("颜色范围", .colorRange), ("亮度范围", .luminanceRange), ("语义", .semantic),
        ]
        var titles: [String] = []
        for (name, kind) in shapes {
            let session = CatalogSession()
            let mask = try! XCTUnwrap(session.addMask(kind: kind))
            let component = mask.components.count - 1
            let shape = mask.components[component].shape
            let rows = MaskShapeSliderRow.rows(for: shape)
            XCTAssertFalse(rows.isEmpty, "\(name): 这个形状必须有它自己的行")
            titles += rows.map(\.title)

            for row in rows {
                let resets = PanelResets(session: session)
                let away = valueAway(from: row.defaultValue, in: row.range)
                session.setMaskComponentShape(mask.id, component: component,
                                              shape: row.apply(shape, away),
                                              commit: true, label: row.label)
                let before = session.history.count
                let current = try! XCTUnwrap(session.edit.masks.first { $0.id == mask.id })
                XCTAssertEqual(row.read(current.components[component].shape), away, accuracy: 1e-9,
                               "\(name)/\(row.title): the drag path wrote the value")

                XCTAssertTrue(resets.maskShape(row, in: current, component: component),
                              "\(name)/\(row.title): 双击标签必须复位")
                let after = try! XCTUnwrap(session.edit.masks.first { $0.id == mask.id })
                XCTAssertEqual(row.read(after.components[component].shape), row.defaultValue,
                               accuracy: 1e-9,
                               "\(name)/\(row.title): 回到 Core 值类型的默认")
                XCTAssertEqual(session.history.count, before + 1,
                               "\(name)/\(row.title): 一条历史")
                XCTAssertEqual(session.history.currentSnapshot?.label, row.label)
                print("MASK shape reset · \(name)/\(row.title): \(fmt(away)) → "
                      + "\(fmt(row.defaultValue)) · history +1")
            }
        }
        XCTAssertEqual(Set(titles), ["中点", "半径", "角度", "容差", "下限", "上限", "软边"],
                       "每一根形状滑杆都在表里，一根不缺")
        print("MASK shape rows · \(titles)")
    }

    /// A brush's section has **no** shape rows (its numbers are the view-state rows 大小/硬度/流量),
    /// so the table cannot invent a 中点 for a brush.
    func testABrushHasNoShapeRows() {
        let brush = MaskShape.brush(BrushShape())
        XCTAssertEqual(MaskShapeSliderRow.rows(for: brush).count, 0)
        XCTAssertEqual(MaskShapeSliderRow.rows(for: .unsupported(kind: "future", payload: .null)).count, 0)
    }

    // MARK: - 3. 卡片标题：整张卡复位（一条历史）

    func testTheCardTitleResetPutsTheMasksParametersBackInOneSnapshot() {
        let session = CatalogSession()
        let mask = try! XCTUnwrap(session.addMask(kind: .linearGradient))
        let resets = PanelResets(session: session)

        session.writeMask(mask.id, label: "", commit: false) { m in
            m.opacity = 0.4
            m.feather = 0.3
            m.refine = 0.7
            m.invert = true
            m.adjustments.amount = 40
            m.adjustments.exposure = 1.5
            m.adjustments.saturation = -30
            // The drawn geometry: the card reset must leave this alone (see `maskCard`).
            if case .linearGradient(var g) = m.components[0].shape {
                g.midpoint = 0.3
                m.components[0].shape = .linearGradient(g)
            }
        }
        XCTAssertTrue(session.commitEdit(label: "一堆调整"))
        let before = session.history.count

        let current = try! XCTUnwrap(session.edit.masks.first { $0.id == mask.id })
        XCTAssertTrue(resets.maskCard(current.id), "双击「蒙版」必须整张卡复位")

        let after = try! XCTUnwrap(session.edit.masks.first { $0.id == mask.id })
        print("MASK card reset · 不透明度 \(current.opacity) → \(after.opacity)"
              + " · 羽化 \(current.feather) → \(after.feather)"
              + " · 精修 \(current.refine) → \(after.refine)"
              + " · 强度 \(current.adjustments.amount) → \(after.adjustments.amount)")
        XCTAssertEqual(after.opacity, Mask.fallback.opacity, accuracy: 1e-12)
        XCTAssertEqual(after.feather, Mask.fallback.feather, accuracy: 1e-12)
        XCTAssertEqual(after.refine, Mask.fallback.refine, accuracy: 1e-12)
        XCTAssertEqual(after.invert, Mask.fallback.invert)
        XCTAssertEqual(after.adjustments, LocalAdjustments.identity)
        XCTAssertEqual(session.history.count, before + 1, "整卡复位 = 一条历史，不是 14 条")
        XCTAssertEqual(session.history.currentSnapshot?.label, InspectorView.Section.masks.title)

        // The geometry the user drew is not a parameter: it survives the card reset.
        if case .linearGradient(let g) = after.components[0].shape {
            XCTAssertEqual(g.midpoint, 0.3, accuracy: 1e-12,
                           "中点 是画出来的几何，整卡复位不碰它（它有自己的行复位）")
        } else {
            XCTFail("the shape changed under a parameter reset")
        }

        // A card already at its defaults writes nothing (no empty snapshot, no truncated redo).
        let settled = session.history.count
        XCTAssertFalse(resets.maskCard(mask.id), "已经默认：不写")
        XCTAssertEqual(session.history.count, settled)

        XCTAssertTrue(session.undo())
        let undone = try! XCTUnwrap(session.edit.masks.first { $0.id == mask.id })
        XCTAssertEqual(undone.opacity, 0.4, accuracy: 1e-12)
        XCTAssertEqual(undone.adjustments.saturation, -30, accuracy: 1e-12)
    }

    // MARK: - 4. 点数值 → 第一响应者 → 输入

    /// The panel's **own** rendered row: a real window, a real `NSHostingView`, the real
    /// `MaskListPanel`. The number is a `NumberTextField`, it becomes the window's first responder,
    /// `0.35` + ↵ writes `0.35` in one snapshot, `5` clamps to the end of the travel, `Esc` writes
    /// nothing.
    func testTheNumberBecomesTheFirstResponderAndTypingWritesTheDocument() throws {
        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .linearGradient))
        session.setMaskLevel(mask.id, .feather, 0.2, commit: true)
        let historyBefore = session.history.count

        let (window, host) = Self.host(MaskListPanel(session: session),
                                       size: CGSize(width: 300, height: 1200))
        defer { window.makeFirstResponder(nil) }

        let fields = Self.subviews(of: host, ofType: NumberTextField.self)
        XCTAssertGreaterThanOrEqual(fields.count, 14,
                                    "两根滑杆一行一个数值框：蒙版卡至少 14 个（含形状行）")
        let field = try XCTUnwrap(fields.first { $0.accessibilityIdentifier() == "inspector.mask.羽化" },
                                  "羽化 的数值框必须在面板的视图树里")
        XCTAssertEqual(field.stringValue, "0.20", "idle: the row's own format")

        // A click into the number = it becomes the first responder.
        XCTAssertTrue(window.makeFirstResponder(field), "数值框必须能成为第一响应者")
        Self.pump()
        let responder = try XCTUnwrap(window.firstResponder)
        let isTheField = responder === field
            || (responder as? NSTextView)?.delegate === field
        XCTAssertTrue(isTheField, "点数值之后，键盘的落点必须是这个数值框 / 它的 field editor")
        print("MASK typing · firstResponder = \(String(describing: type(of: responder)))"
              + " · 数值框 \(String(describing: type(of: field))) frame \(field.frame)"
              + " · firstResponder === field: \(responder === field)")

        // 0.35 + ↵
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "no field editor")
        XCTAssertEqual(editor.string, "0.20", "聚焦后显示的是干净数字：行自己的精度（2 位），没有单位")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("0.35", replacementRange: editor.selectedRange())
        XCTAssertEqual(editor.string, "0.35", "第一次按键整段替换读数（057 的规则）")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        Self.pump()

        XCTAssertEqual(maskValue(session, mask.id).feather, 0.35, accuracy: 1e-12,
                       "↵ 提交 → 文档 0.35")
        XCTAssertEqual(session.history.count, historyBefore + 1, "一次输入 = 一条历史")
        XCTAssertEqual(field.stringValue, "0.35", "读数换成提交后的值")
        print("MASK typing · 「0.35」↵ → feather \(maskValue(session, mask.id).feather)"
              + " · history +\(session.history.count - historyBefore) · 读数 \(field.stringValue)")

        // 5 (outside 0…1) + ↵ → clamped to the end of the travel, still one entry.
        try enter("5", into: field, in: window)
        XCTAssertEqual(maskValue(session, mask.id).feather, 1, accuracy: 1e-12,
                       "超范围被钳到上限 1.0，不是 beep，也不是 5")
        XCTAssertEqual(session.history.count, historyBefore + 2)
        print("MASK typing · 「5」↵ → feather \(maskValue(session, mask.id).feather)（钳到上限）")

        // Esc → nothing written, the number goes back to the readout.
        try enter("0.1", into: field, in: window, cancel: true)
        XCTAssertEqual(maskValue(session, mask.id).feather, 1, accuracy: 1e-12, "Esc 不写文档")
        XCTAssertEqual(session.history.count, historyBefore + 2, "Esc 不写历史")
        XCTAssertEqual(field.stringValue, "1.00", "Esc 之后读数回到文档的值")
        print("MASK typing · 「0.1」Esc → feather \(maskValue(session, mask.id).feather) · history 不变")

        // 不透明度 is a percentage row: typing 35 must store 0.35, not 35.
        let opacity = try XCTUnwrap(fields.first { $0.accessibilityIdentifier() == "inspector.mask.不透明度" })
        try enter("35", into: opacity, in: window)
        XCTAssertEqual(maskValue(session, mask.id).opacity, 0.35, accuracy: 1e-12,
                       "百分比行：输入 35 = 文档 0.35")
        XCTAssertEqual(opacity.stringValue, "35%")
        print("MASK typing · 「35」↵ → opacity \(maskValue(session, mask.id).opacity)"
              + " · 读数 \(opacity.stringValue)")
    }

    // MARK: - 5. 样式：和 Light 卡那一行逐项相同

    /// The rendered number of a mask row vs the rendered number of **the Light card's own 曝光 row**:
    /// same font name, same point size, same field width, same measured text width. The reference is
    /// the real panel (the inspector hosted in its 调整 workspace), not a copy of a row.
    func testTheMaskNumberIsSetExactlyLikeTheLightCards() throws {
        // The mask panel, and the number that proves the two rows are the same object.
        let maskSession = CatalogSession()
        _ = try XCTUnwrap(maskSession.addMask(kind: .linearGradient))
        let (mWindow, mHost) = Self.host(MaskListPanel(session: maskSession),
                                         size: CGSize(width: 300, height: 1200))
        defer { mWindow.makeFirstResponder(nil) }
        let maskField = try XCTUnwrap(
            Self.subviews(of: mHost, ofType: NumberTextField.self)
                .first { $0.accessibilityIdentifier() == "inspector.mask.羽化" })

        // The inspector in the 调整 workspace: 曝光's resting readout is `0.00 EV` — the only one in
        // the panel, so the field identifies itself.
        let lightSession = CatalogSession()
        let workspaces = InspectorWorkspaceState()
        workspaces.select(.adjust)
        let (lWindow, lHost) = Self.host(InspectorView(session: lightSession, workspaces: workspaces),
                                         size: CGSize(width: 330, height: 2000))
        defer { lWindow.makeFirstResponder(nil) }
        let exposureField = try XCTUnwrap(
            Self.subviews(of: lHost, ofType: NumberTextField.self).first { $0.stringValue == "0.00 EV" },
            "曝光 那一行的数值框必须在 Light 卡的视图树里")

        func describe(_ field: NSTextField) -> (name: String, size: CGFloat, width: CGFloat,
                                                text: CGFloat, height: CGFloat) {
            let font = field.font ?? .systemFont(ofSize: 0)
            let width = ("0000" as NSString).size(withAttributes: [.font: font]).width
            return (font.fontName, font.pointSize, field.frame.width, width, field.frame.height)
        }
        let mask = describe(maskField)
        let light = describe(exposureField)
        print(String(format: "MASK style · 蒙版/羽化 %@ %.1fpt w%.1f text%.2f h%.1f"
                             + " · Light/曝光 %@ %.1fpt w%.1f text%.2f h%.1f",
                     mask.name, mask.size, mask.width, mask.text, mask.height,
                     light.name, light.size, light.width, light.text, light.height))

        XCTAssertEqual(mask.name, light.name, "同一个字体名")
        XCTAssertEqual(mask.size, light.size, "同一个字号")
        XCTAssertEqual(mask.width, light.width, "同一个字段宽")
        XCTAssertEqual(mask.text, light.text, accuracy: 1e-9, "同一个文本宽度（同字体同字号）")
        XCTAssertEqual(mask.height, light.height, "同一个字段高")

        // …and the same style table, not a mask-specific copy of it.
        let style = InspectorView.SliderRowStyle.standard
        XCTAssertEqual(style.readoutSize, mask.size, "数值字号来自 SliderRowStyle")
        XCTAssertEqual(style.labelSize, 10, "标签字号来自 SliderRowStyle")
        XCTAssertEqual(SliderValueMap.rowHeight, 16, "轨道高度来自 SliderValueMap")

        // The row view is shared, so the style can only come from one place.
        let row = try String(contentsOf: Self.sliderRowSource, encoding: .utf8)
        XCTAssertTrue(row.contains("style.labelSize"), "标签字号只能来自 SliderRowStyle")
        XCTAssertTrue(row.contains("InspectorView.shapeSlider(value, in: range, shape: shape"),
                      "轨道只能是面板那唯一一个 shapeSlider（同一处 tint / 高度 / controlSize）")
    }

    // MARK: - 6. 真双击：面板里那一个标签

    /// **这是「双击名称复原」的接线证据**（不是源码猜）：面板真的渲染出来之后，在「羽化」那一行的标签上
    /// 发两次真实的 `NSEvent`（第二次 `clickCount = 2`），文档回到默认值、`history.count` 恰好 +1。
    ///
    /// 为什么值得这么测：047 的那条源码断言（`ResetOnDoubleClick`）证明手势挂上去了，证明不了它接在
    /// **这一行**的复位上。这里点的是渲染出来的树，走的是 `SliderRow` 的标签 → `onReset` →
    /// `PanelResets.mask(_:in:)` → `writeMask(commit: true)` 这一整条。
    func testDoubleClickingTheRenderedLabelResetsThatParameterInOneSnapshot() throws {
        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .linearGradient))
        session.setMaskLevel(mask.id, .feather, 0.2, commit: true)
        let before = session.history.count

        let (window, host) = Self.host(MaskListPanel(session: session),
                                       size: CGSize(width: 300, height: 1200))
        defer { window.makeFirstResponder(nil) }

        let field = try XCTUnwrap(
            Self.subviews(of: host, ofType: NumberTextField.self)
                .first { $0.accessibilityIdentifier() == "inspector.mask.羽化" })
        let line = field.convert(field.bounds, to: nil)
        let point = Self.doubleClickScan(in: window, along: line.midY, upTo: line.minX - 6) {
            maskValue(session, mask.id).feather != 0.2
        }

        let hit = try XCTUnwrap(point, "标签上的一次真双击必须复位羽化（扫遍标签那一行都没有发生，"
                                       + "说明双击没接在这个参数上）")
        XCTAssertEqual(maskValue(session, mask.id).feather, 0, accuracy: 1e-12,
                       "双击「羽化」→ 回 Core 默认 0")
        XCTAssertEqual(session.history.count, before + 1, "双击 = **一条**历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "蒙版羽化")
        print("MASK double-click wiring · 羽化 0.2 → \(maskValue(session, mask.id).feather)"
              + " · history +\(session.history.count - before) · 点在 \(hit)")
    }

    /// **卡片标题的接线证据**：在渲染出来的「蒙版」两个字上双击，整张卡的参数面回到默认，`history` +1。
    func testDoubleClickingTheCardTitleInTheRenderedPanelResetsTheWholeMask() throws {
        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .linearGradient))
        session.writeMask(mask.id, label: "", commit: false) { m in
            m.opacity = 0.4
            m.feather = 0.3
            m.refine = 0.7
            m.adjustments.amount = 40
        }
        XCTAssertTrue(session.commitEdit(label: "一堆调整"))
        let before = session.history.count

        let (window, host) = Self.host(MaskListPanel(session: session),
                                       size: CGSize(width: 300, height: 1200))
        defer { window.makeFirstResponder(nil) }

        let opacityField = try XCTUnwrap(
            Self.subviews(of: host, ofType: NumberTextField.self)
                .first { $0.accessibilityIdentifier() == "inspector.mask.不透明度" })
        let line = opacityField.convert(opacityField.bounds, to: nil)

        // The title is the card's first element, above the list / tools / 蒙版级: sweep a band above
        // 不透明度's row at three x's inside the title's own text box (the left column — the buttons on
        // the right of the header must not be hit).
        var hit: NSPoint?
        var number = 5000
        loop: for y in stride(from: line.maxY + 20, through: line.maxY + 400, by: 10) {
            for x in [CGFloat(8), 20, 34] {
                Self.doubleClick(at: NSPoint(x: x, y: y), in: window, eventNumber: number,
                                 settle: 0.01)
                number += 4
                let now = maskValue(session, mask.id)
                if now.opacity == Mask.fallback.opacity, now.feather == Mask.fallback.feather {
                    hit = NSPoint(x: x, y: y)
                    break loop
                }
            }
        }

        let point = try XCTUnwrap(hit, "「蒙版」标题上的一次真双击必须整卡复位")
        let after = maskValue(session, mask.id)
        print("MASK title double-click · 不透明度 0.4 → \(after.opacity)"
              + " · 羽化 0.3 → \(after.feather)"
              + " · 精修 0.7 → \(after.refine)"
              + " · 强度 40 → \(after.adjustments.amount)"
              + " · history +\(session.history.count - before) · 点在 \(point)")
        XCTAssertEqual(after.opacity, Mask.fallback.opacity, accuracy: 1e-12)
        XCTAssertEqual(after.feather, Mask.fallback.feather, accuracy: 1e-12)
        XCTAssertEqual(after.refine, Mask.fallback.refine, accuracy: 1e-12)
        XCTAssertEqual(after.adjustments.amount, LocalAdjustments.identity.amount, accuracy: 1e-12)
        XCTAssertEqual(session.history.count, before + 1, "整卡复位 = 一条历史")
    }

    // MARK: - 7. 反证：换回裸 Slider，两条断言必红

    /// **反证（常驻，而且真的跑）**：旧的一行是「`Text` 标签 + `Text` 读数 + 裸 `Slider`」。同一台机器、
    /// 同一个窗口、**同一段探测代码**，对它跑上面那两条：
    ///
    ///   · **点数值**：子树里 **0 个** `NSTextField` —— 「`firstResponder` 是那个数值框」无从成立
    ///     （上面那条 `XCTUnwrap` 在这里必红）；
    ///   · **双击复位**：在标签那一带上真的发两次双击（同一段 `sendEvent`），`history.count` 增量为
    ///     **0** —— 「恰好 +1」在这里必红。
    func testTheOldBareSliderRowCannotPassTheSameTwoAssertions() throws {
        let session = CatalogSession()
        let mask = try XCTUnwrap(session.addMask(kind: .linearGradient))
        session.setMaskLevel(mask.id, .feather, 0.2, commit: true)
        let before = session.history.count

        let (window, host) = Self.host(LegacyMaskRow(value: 0.2, range: 0 ... 1, format: "%.2f",
                                                     onDragEnd: {}),
                                       size: CGSize(width: 260, height: 60))
        defer { window.makeFirstResponder(nil) }

        // (a) 点数值: there is nothing to click into.
        let fields = Self.subviews(of: host, ofType: NSTextField.self)
        XCTAssertEqual(fields.count, 0,
                       "裸 Slider 的那一行没有数值框 —— 「点数值 → firstResponder」这条断言在这里必红")
        XCTAssertNil(Self.subviews(of: host, ofType: NumberTextField.self).first)

        // (b) 双击复位: the label is a plain `Text`, so the same gesture does nothing. The whole row is
        // swept (both lines of it), not one guessed point.
        let sweptLabelLine = Self.doubleClickScan(in: window, along: 24, upTo: 120) {
            session.history.count != before
        }
        let sweptTrackLine = Self.doubleClickScan(in: window, along: 6, upTo: 120) {
            session.history.count != before
        }
        XCTAssertNil(sweptLabelLine, "裸 Slider 的标签没有双击手势")
        XCTAssertNil(sweptTrackLine)
        XCTAssertEqual(session.history.count, before, "没有复位发生：history 增量是 0")
        XCTAssertEqual(maskValue(session, mask.id).feather, 0.2, accuracy: 1e-12, "值还在拖动后的位置")

        // The new row, in the same window, passes both: one number field, and a reset that moves the
        // document and the history by exactly one.
        let (nWindow, nHost) = Self.host(MaskListPanel(session: session),
                                         size: CGSize(width: 300, height: 1200))
        defer { nWindow.makeFirstResponder(nil) }
        let newFields = Self.subviews(of: nHost, ofType: NumberTextField.self)
            .filter { $0.accessibilityIdentifier() == "inspector.mask.羽化" }
        XCTAssertEqual(newFields.count, 1, "新的一行有一个数值框")
        let row = try XCTUnwrap(MaskSliderRow.all.first { $0.title == "羽化" })
        let current = try XCTUnwrap(session.edit.masks.first { $0.id == mask.id })
        XCTAssertTrue(PanelResets(session: session).mask(row, in: current))
        XCTAssertEqual(session.history.count, before + 1, "新的一行：双击 = 一条历史")
        print("MASK negative control · 裸 Slider: \(fields.count) 数值框 / 复位 +0"
              + " · SliderRow: \(newFields.count) 数值框 / 复位 +1")
    }

    // MARK: - the mouse

    /// A real double-click, the way a mouse delivers one: two down/up pairs, the second carrying
    /// `clickCount = 2` (SwiftUI's `onTapGesture(count: 2)` reads exactly that).
    private static func doubleClick(at point: NSPoint, in window: NSWindow, eventNumber: Int,
                                    settle: TimeInterval = 0.03) {
        func send(_ type: NSEvent.EventType, clickCount: Int, number: Int, pressure: Float) {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: number, clickCount: clickCount,
                                                 pressure: pressure) else { return }
            window.sendEvent(event)
            pump(settle)
        }
        send(.leftMouseDown, clickCount: 1, number: eventNumber, pressure: 1)
        send(.leftMouseUp, clickCount: 1, number: eventNumber + 1, pressure: 0)
        send(.leftMouseDown, clickCount: 2, number: eventNumber + 2, pressure: 1)
        send(.leftMouseUp, clickCount: 2, number: eventNumber + 3, pressure: 0)
    }

    /// Sweep one line of a rendered row left-to-right and double-click at each step, stopping at the
    /// first point where `changed` becomes true. Returns the point that did it, or `nil`.
    ///
    /// A sweep and not one guessed coordinate: the label is a SwiftUI `Text` (no `NSView` of its own),
    /// so its frame is only knowable by trying — and 「扫遍整行都没有发生」 is the honest form of
    /// 「这个标签上没有双击」.
    @discardableResult
    private static func doubleClickScan(in window: NSWindow, along y: CGFloat, upTo x: CGFloat,
                                       eventBase: Int = 1000,
                                       until changed: () -> Bool) -> NSPoint? {
        var number = eventBase
        for x in stride(from: CGFloat(3), through: max(3, x), by: 6) {
            doubleClick(at: NSPoint(x: x, y: y), in: window, eventNumber: number)
            number += 4
            if changed() { return NSPoint(x: x, y: y) }
        }
        return nil
    }

    // MARK: - helpers

    /// A value inside `range` that is not `defaultValue` (37 % along the travel, nudged off the
    /// default if it lands on it).
    private func valueAway(from defaultValue: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        var candidate = range.lowerBound + span * 0.37
        if abs(candidate - defaultValue) < span * 0.01 { candidate = range.lowerBound + span * 0.63 }
        return candidate
    }

    private func maskValue(_ session: CatalogSession, _ id: String) -> Mask {
        session.edit.masks.first { $0.id == id } ?? .fallback
    }

    private func fmt(_ value: Double) -> String {
        String(format: "%.4g", value)
    }

    /// Focus a row's number and type into it: `cancel` = `Esc`, otherwise `↵`.
    private func enter(_ text: String, into field: NSTextField, in window: NSWindow,
                       cancel: Bool = false) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        Self.pump()
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "no field editor")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText(text, replacementRange: editor.selectedRange())
        editor.doCommand(by: cancel ? #selector(NSResponder.cancelOperation(_:))
                                   : #selector(NSResponder.insertNewline(_:)))
        Self.pump()
    }

    private static var windows: [NSWindow] = []

    /// A real (borderless) window hosting a SwiftUI view — the same harness `NumberFieldTypingTests`
    /// uses, because a `NumberTextField` only exists once SwiftUI has built its `NSViewRepresentable`.
    private static func host<V: View>(_ view: V, size: CGSize) -> (NSWindow, NSHostingView<V>) {
        NSApplication.shared.setActivationPolicy(.accessory)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        pump(0.15)
        return (window, host)
    }

    private static func subviews<T: NSView>(of root: NSView, ofType: T.Type) -> [T] {
        var found: [T] = []
        func walk(_ view: NSView) {
            if let typed = view as? T { found.append(typed) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private static func pump(_ seconds: TimeInterval = 0.05) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds))
    }

    private static var sliderRowSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/PhotonsUI/SliderRow.swift")
    }
}

// MARK: - the old row, kept only as the negative control

/// **The row as 蒙版 drew it before this task** — label + number as plain text, a bare `Slider`, no
/// reset hook, no typeable number. It exists so
/// `testTheOldBareSliderRowCannotPassTheSameTwoAssertions` can run the same two probes against it and
/// show them fail; it is never used by the panel.
private struct LegacyMaskRow: View {
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    let onDragEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text("羽化")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(String(format: format, value))
                    .font(.system(size: 10, design: .monospaced))
            }
            Slider(value: .constant(value), in: range) { editing in
                if !editing { onDragEnd() }
            }
            .controlSize(.mini)
        }
    }
}
