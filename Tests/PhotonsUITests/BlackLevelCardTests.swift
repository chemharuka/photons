import XCTest
import SwiftUI
import AppKit
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 071 —— 「黑电平」卡的面板侧。
///
/// 卡片的形状是 047/048 那套既有契约的又一次使用，不是新发明：一行，标题 + 数值框 + 滑杆，
/// 名字双击 = 这个字段回默认，卡标题双击 = 整张卡一条快照。只有三件事是新的：
///
///   1. **类别**：`.linear` —— 面板里的第一个线性域参数，红 `#FF375F`（`SliderStyleTests` 量像素）。
///   2. **单位**：滑杆是整数 −10…+10，文档是 `n/1000` 的 Double。行显示整数，模型存小数，翻译只在
///      `LightGroup` 的两个映射函数里发生一次。
///   3. **位置**：Light 之后、Color 之前 —— 它是线性域的色调修整，紧挨着 Light 的六根滑杆，
///      但**不是**它们的第七根（`lightRows` 仍是六行，Lex 的复位语义因此不变）。
@MainActor
final class BlackLevelCardTests: XCTestCase {

    // MARK: - 1. 卡片存在、位置、名字

    func testTheCardSitsDirectlyUnderWhiteBalanceAndAboveLight() {
        let titles = InspectorView.sectionTitles
        guard let wb = titles.firstIndex(of: "白平衡") else {
            return XCTFail("no 白平衡 card in \(titles)")
        }
        // 用户 2026-10-27：「黑电平移动到白平衡下方」。
        XCTAssertEqual(titles[wb + 1], "黑电平", "黑电平必须紧跟 白平衡，实际 \(titles)")
        guard let black = titles.firstIndex(of: "黑电平"), let light = titles.firstIndex(of: "Light") else {
            return XCTFail("missing 黑电平/Light in \(titles)")
        }
        XCTAssertEqual(black + 1, light, "黑电平在白平衡与 Light 之间，实际 \(titles)")
        XCTAssertEqual(titles.filter { $0 == "黑电平" }.count, 1, "一张黑电平卡，不是两张")
        XCTAssertEqual(InspectorView.Section.blackLevel.title, "黑电平", "标题 = 卡名 = 撤销标签")
        XCTAssertTrue(InspectorView.scrollingSections.contains(.blackLevel), "它跟随滚动，不属于钉住区")

        // Light 仍是六行：071 没有往那张表里加第七行。
        XCTAssertEqual(InspectorView.lightRows.count, 6, "黑电平不是 Light 的第七根滑杆")
        XCTAssertFalse(InspectorView.lightRows.map(\.title).contains("黑电平"))
        // 预钉的头部没动。
        XCTAssertEqual(Array(titles.prefix(3)), ["直方图", "白平衡", "黑电平"])
    }

    /// 行表本身：一行、整数行程、整数读数、可键入、线性域形状、绑 `light.blackOffset`。
    func testTheRowIsOneDecimalSliderOnTheLinearDomain() {
        let rows = InspectorView.blackLevelRows
        XCTAssertEqual(rows.count, 1, "一行")
        let row = rows[0]
        XCTAssertEqual(row.title, "偏移", "行标题是这条偏移自己的名字（卡标题已经是「黑电平」）")
        XCTAssertEqual(row.range, -10 ... 10, "滑杆 −10…+10（0.1 步），0 在正中间")
        XCTAssertEqual(row.range.lowerBound, -row.range.upperBound, "两端对称，所以 0 落在中点")
        XCTAssertEqual(row.format, "%.1f", "读数带一位小数（−7.5），不是 −0.0075")
        XCTAssertEqual(row.shape, .linear, "线性域 → 红 #FF375F")
        XCTAssertTrue(row.editable, "047: 面板里每一行都能键入")
        XCTAssertEqual(row.defaultValue, 0, "默认 0（`EditModel.neutral`，不是字面量）")
        XCTAssertEqual(row.decimals, 1, "编辑时同样一位小数")

        // 读数文案：负号是 ASCII 的减号，负零不出现（面板的老规矩）。
        XCTAssertEqual(InspectorView.sliderText(row.format, -7, rounding: row.rounding), "-7.0")
        XCTAssertEqual(InspectorView.sliderText(row.format, -7.5, rounding: row.rounding), "-7.5")
        XCTAssertEqual(InspectorView.sliderText(row.format, 0, rounding: row.rounding), "0.0")
        XCTAssertEqual(InspectorView.sliderText(row.format, 10, rounding: row.rounding), "10.0")

        // 表里 `keyPath` 就是文档那一个字段：滑杆位置与它之间只有 `LightGroup` 的映射。
        var edit = EditModel.neutral
        edit[keyPath: row.keyPath] = LightGroup.blackOffset(fromSlider: -7.5)
        XCTAssertEqual(edit.light.blackOffset, -0.0075, "滑杆 −7.5 必须写进 −0.0075")
        XCTAssertEqual((edit[keyPath: row.keyPath] * 10000).rounded() / 10, -7.5, "读回来还是 −7.5")
        // 非整数位置落在 0.1 格上：这就是「不是只能取整数」。
        XCTAssertEqual(LightGroup.blackOffset(fromSlider: 3.34), 0.0033, "3.34 → 3.3 格 → 0.0033")
    }

    // MARK: - 2. 写文档：一次拖动 = 一条历史，一条快照里就是那个值

    /// 拖动（每一跳都写文档）只有抬起才进历史；写进去的是 `n/1000`，不是滑杆的连续位置。
    func testOneDragWritesOneHistoryEntryOnTheThousandthGrid() {
        let session = CatalogSession()
        let before = session.history.count

        // 与 `blackLevelBinding` 同一条路径：set 里过一次映射，get 里反算回滑杆位置。
        let binding = Binding<Double>(
            get: { (session.edit.light.blackOffset * 1000).rounded() },
            set: { position in
                let offset = LightGroup.blackOffset(fromSlider: position)
                session.applyEdit { $0.light.blackOffset = offset }
            })

        for tick in [-3.5, -1.2, 2.0001, 4.0] {          // 拖动中的每一跳都不是整数
            binding.wrappedValue = tick
            XCTAssertEqual(session.history.count, before, "拖动中不写历史")
        }
        XCTAssertEqual(binding.wrappedValue, 4, "抬起时滑杆停在整数格上")
        XCTAssertEqual(session.edit.light.blackOffset, 0.004, "文档里是 4/1000")

        session.commitEdit(label: InspectorView.Section.blackLevel.title)
        XCTAssertEqual(session.history.count, before + 1, "一次拖动 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "黑电平")

        // 回到 0 = 回到默认：键与像素都回到 pre-071 的样子（0 不写键）。
        binding.wrappedValue = 0
        XCTAssertEqual(session.edit.light.blackOffset, 0)
        XCTAssertFalse(session.edit.keyMaterial(.sceneLinear).contains("boff"))
    }

    /// 双击标题 / 双击名字：一条快照回到 0，而且「已经是 0」时什么都不写（047「无改动 = 无快照」）。
    func testDoubleClickResetsToOneSnapshotAndWritesNothingWhenAlreadyDefault() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)

        XCTAssertFalse(resets.field(\.light.blackOffset, label: "黑电平"), "已经是 0：不许写快照")
        XCTAssertEqual(session.history.count, 0)

        let row = InspectorView.blackLevelRows[0]
        session.applyEdit { $0.light.blackOffset = LightGroup.blackOffset(fromSlider: -7) }
        session.commitEdit(label: row.title)
        XCTAssertEqual(session.edit.light.blackOffset, -0.007)
        let afterDrag = session.history.count

        XCTAssertTrue(resets.field(row.keyPath, label: row.title), "名字双击 = 这个字段回默认")
        XCTAssertEqual(session.edit.light.blackOffset, 0)
        XCTAssertEqual(session.history.count, afterDrag + 1, "一条快照")

        // 卡标题双击（`card(_:reset:)` 接的也是 `field`）在非零时同样只写一条。
        session.applyEdit { $0.light.blackOffset = 0.01 }
        session.commitEdit(label: "黑电平")
        let beforeReset = session.history.count
        XCTAssertTrue(resets.field(\.light.blackOffset, label: InspectorView.Section.blackLevel.title))
        XCTAssertEqual(session.edit.light.blackOffset, 0)
        XCTAssertEqual(session.history.count, beforeReset + 1)
    }

    // MARK: - 3. 源码接线：这张卡不许自己另起一套

    func testTheCardIsWiredThroughTheOneRowBuilderAndTheModelMapping() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)

        // 卡片由 `sliderRow` + `blackLevelBinding` 组成，颜色/编辑/复位全部来自那一个 builder。
        XCTAssertTrue(source.contains("private var blackLevelCard: some View"),
                      "卡片本身必须存在，而且走面板那唯一一个行构造器")
        XCTAssertTrue(source.contains("sliderRow(row.title, blackLevelBinding(row), row.range, row.format"),
                      "行由 sliderRow 画：label、数值框、双击复位、onEditingChanged 一处提供")
        XCTAssertTrue(source.contains("shape: row.shape"), "颜色从行表来，不写死")
        XCTAssertTrue(source.contains("LightGroup.blackOffset(fromSlider: position)"),
                      "写文档必须过模型的映射，不许在视图里除以 1000")
        XCTAssertTrue(source.contains("resets.field(\\.light.blackOffset"),
                      "复位走 PanelResets.field（一条快照），不是自己写 applyEdit")
        XCTAssertTrue(source.contains("ForEach(Self.blackLevelRows"),
                      "卡片迭代的正是测试断言的那张表")

        // 它没有自己的 Slider / NSSlider / 刻度。
        let card = try Self.body(of: "private var blackLevelCard", upTo: "/// 071: the 黑电平 card's one row",
                                 in: Self.inspectorSource)
        XCTAssertEqual(Self.occurrences(of: "Slider(value: ", in: card), 0,
                       "卡片里不许有第二处 Slider —— 一根滑杆，由 shapeSlider 造")
        XCTAssertFalse(card.contains("step:"), "没有刻度线（046）")
        XCTAssertFalse(card.lowercased().contains("nsslider"), "不是 AppKit 控件")
    }

    // MARK: - helpers

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static func body(of signature: String, upTo endMarker: String,
                             in url: URL) throws -> String {
        let source = try String(contentsOf: url, encoding: .utf8)
        guard let start = source.range(of: signature),
              let end = source.range(of: endMarker),
              start.lowerBound < end.lowerBound else {
            throw XCTSkip("no `\(signature)` … `\(endMarker)` section in \(url.lastPathComponent)")
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var search = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: search) {
            count += 1
            search = found.upperBound..<haystack.endIndex
        }
        return count
    }
}
