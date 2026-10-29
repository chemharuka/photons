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
///   3. **位置**：Light 之后、Color 之前 —— 它是线性域的色调修整，紧挨着 Light 的七根滑杆，
///      但**不是**它们的第八根（`lightRows` 是七行，Lex 的复位语义因此不变）。
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

        // Light 现在是七行（085 的中间调），但黑电平仍不在这张表里。
        XCTAssertEqual(InspectorView.lightRows.count, 7, "黑电平不是 Light 的第八根滑杆")
        XCTAssertFalse(InspectorView.lightRows.map(\.title).contains("黑电平"))
        // 预钉的头部没动。
        XCTAssertEqual(Array(titles.prefix(3)), ["直方图", "白平衡", "黑电平"])
    }

    /// 行表本身：一行、整数行程、整数读数、可键入、线性域形状、绑 `light.blackOffset`。
    func testTheRowIsOneDecimalSliderOnTheLinearDomain() throws {
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
        // 滑杆的 getter 必须走 `LightGroup.blackOffsetSliderPosition(of:)`（0.1 格），
        // 否则拖动时值会被吸回整数——这条是用户实测「拖动还是只能整数」的回归点。
        var probe = LightGroup.identity
        probe.blackOffset = -0.0075
        XCTAssertEqual(LightGroup.blackOffsetSliderPosition(of: probe), -7.5, "getter 必须保留 0.1 格")
        XCTAssertNotEqual(LightGroup.blackOffsetSliderPosition(of: probe),
                          (probe.blackOffset * 1000).rounded(), "不能是整数取整那份")
        let panelSource = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(panelSource.contains("LightGroup.blackOffsetSliderPosition(of: session.edit.light)"),
                      "binding 的 getter 必须是 0.1 格那个函数")
        XCTAssertFalse(panelSource.contains("(session.edit[keyPath: row.keyPath] * 1000).rounded()"),
                       "旧整数 getter 不许回来")

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

    // MARK: - 4. 089 自动黑电平：取整方向、钳位、幂等、一条历史

    /// `−0.0014 → 0.002`（向上取整到 1/1000），不是 `0.001`；已经非负时自动值是 0；
    /// 超出 ±0.01 时写满量程。对求出来的偏移再把最小值抬一次，结果必须 ≥ 0。
    func testAutoOffsetRoundsUpToTheThousandthAndClampsToTheRange() throws {
        XCTAssertEqual(LoupeController.autoBlackOffset(for: -0.0014), 0.002,
                       "向上取整：0.0014 → 0.002，不是 0.001")
        XCTAssertEqual(LoupeController.autoBlackOffset(for: 0), 0)
        XCTAssertEqual(LoupeController.autoBlackOffset(for: 0.4), 0, "已经非负：自动值 = 0")
        XCTAssertEqual(LoupeController.autoBlackOffset(for: -0.05), 0.01, "−0.05 → 钳到 +0.01")
        XCTAssertEqual(LoupeController.autoBlackOffset(for: 0.05), 0, "0.05 不是负值，仍是 0")

        // 钳位不许静默：动作里有一行日志，说明它被写满了量程。
        let source = try String(contentsOf: Self.loupeSource, encoding: .utf8)
        XCTAssertTrue(source.contains("AUTO BLACK · min"), "越界时必须有日志，不许静默")

        for min: Float in [-0.0014, -0.0027, -0.01] {
            let offset = LoupeController.autoBlackOffset(for: min)
            XCTAssertGreaterThanOrEqual(Double(min) + offset, 0,
                                        "min \(min) + auto \(offset) 必须非负")
            XCTAssertLessThanOrEqual(offset, LightGroup.blackOffsetRange.upperBound)
            XCTAssertGreaterThanOrEqual(offset, LightGroup.blackOffsetRange.lowerBound)
        }
        // 超量程是「写满量程」而不是「假装非负」：−0.05 只能抬到 +0.01。
        let clamped = LoupeController.autoBlackOffset(for: -0.05)
        XCTAssertEqual(clamped, LightGroup.blackOffsetRange.upperBound)
    }

    /// 图标在数值框的正上方、右缘对齐、命中区 ≥ 18×18，自身没有底色/边框。
    func testAutoIconSitsAboveTheValueRightAlignedAndWithoutChrome() throws {
        let host = NSHostingView(rootView: InspectorView(session: CatalogSession()))
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 2400)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()

        let field = try XCTUnwrap(Self.firstView(in: host) {
            $0.accessibilityIdentifier() == "inspector.blackLevel.offset"
        }, "数值框没有渲染出来")
        let probe = try XCTUnwrap(Self.firstView(in: host) { $0 is BlackLevelAutoProbe }
                                      as? BlackLevelAutoProbe,
                                  "自动图标没有渲染出来")
        let value = field.convert(field.bounds, to: host)
        let icon = probe.convert(probe.bounds, to: host)
        print(String(format: "AUTO · icon (%.1f, %.1f, %.1f×%.1f) · value (%.1f, %.1f, %.1f×%.1f)",
                     icon.minX, icon.minY, icon.width, icon.height,
                     value.minX, value.minY, value.width, value.height))

        XCTAssertLessThan(icon.midY, value.midY, "图标必须在数值行的上方")
        XCTAssertEqual(icon.maxX, value.maxX, accuracy: 1, "图标右缘与数值框右缘对齐")
        XCTAssertGreaterThanOrEqual(icon.width, 18, "命中区 ≥ 18 pt 宽")
        XCTAssertGreaterThanOrEqual(icon.height, 18, "命中区 ≥ 18 pt 高")
        XCTAssertFalse(probe.hasBorder, "裸图标：没有底、没有边、没有胶囊")
    }

    /// 真 RAW：一次点击 = 一个偏移 + 一条「黑电平 · 自动」历史；再点一次是 no-op；⌘Z 回到原值；
    /// 其他字段逐位不变。
    func testAutoBlackOffsetWritesOneHistoryIsIdempotentAndUndoes() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        _ = try loupe.makeFrame(url: url, viewport: ImageSize(width: 800, height: 600),
                                decodeScale: 0.125, edit: session.edit)
        // A real session opens with a baseline snapshot; seed one so ⌘Z has somewhere to go back to.
        session.applyEdit { $0.light.exposure = 0.1 }
        XCTAssertTrue(session.commitEdit(label: "原照"))

        let before = session.edit
        let historyBefore = session.history.count
        let offset = try XCTUnwrap(loupe.autoBlackOffset(), "有解码缓冲时必须返回写入值")
        XCTAssertGreaterThan(offset, 0, "解码缓冲有负样本，自动值必须抬起来")
        XCTAssertLessThanOrEqual(offset, LightGroup.blackOffsetRange.upperBound)
        XCTAssertEqual((offset * 1000).rounded(), offset * 1000, accuracy: 1e-9,
                       "落在 1/1000 的格子上")
        var expected = before
        expected.light.blackOffset = offset
        XCTAssertEqual(session.edit, expected, "除了 blackOffset，其他字段全部不动")
        XCTAssertEqual(session.history.count, historyBefore + 1, "一次点击 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "黑电平 · 自动")

        XCTAssertNil(loupe.autoBlackOffset(), "第二次点击是 no-op")
        XCTAssertEqual(session.history.count, historyBefore + 1, "no-op 不加历史")
        XCTAssertEqual(session.edit.light.blackOffset, offset)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.light.blackOffset, before.light.blackOffset, "⌘Z 回到原值")
    }

    /// 094 — `autoBlackOffset()` 端到端量的是**工作空间**（Rec2020）里三通道全负的点。
    ///
    /// 合成缓冲里放两类点：一个三通道全负的暗点（x = 0）和一个出色域点（x = 5，sRGB 里只有 R
    /// 为负，最负 −0.018）。`autoBlackOffset()` 按 stride 5 采样，正好两个都看到。工作空间的最负值
    /// ≈ −0.0035 → 自动值 0.004（没有被钳）；旧口径 `minChannel` 会看到 −0.018 并钳到 +0.01，
    /// 所以这条用例同时钉住「换了空间」与「候选集排除了单通道为负的点」。
    func testAutoBlackOffsetMeasuresInWorkingSpaceEndToEnd() throws {
        let session = CatalogSession()
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view

        let image = LinearImage(width: 6, height: 1, rgba: [
            -0.005, -0.001, -0.001, 1,
            0.1, 0.1, 0.1, 1,
            0.1, 0.1, 0.1, 1,
            0.1, 0.1, 0.1, 1,
            0.1, 0.1, 0.1, 1,
            -0.018, 0.004, 0.003, 1,
        ], colorSpace: "linear", decoderVersion: "synthetic-094")
        loupe.decodedForTesting = image

        let working = image.darkestBelowBlack(sampleStride: 5)
        let decoded = image.minChannel(sampleStride: 5)
        print(String(format: "094 synthetic working min %.6f → auto %.4f · decoded min %.6f → old auto %.4f",
                     working, LoupeController.autoBlackOffset(for: working),
                     decoded, LoupeController.autoBlackOffset(for: decoded)))
        XCTAssertEqual(Double(working), -0.00351, accuracy: 1e-3,
                       "工作空间里只剩那个三通道全负的暗点")
        XCTAssertEqual(LoupeController.autoBlackOffset(for: decoded), 0.01,
                       "旧口径会被出色域点的 −0.018 顶到钳位上限")

        let offset = try XCTUnwrap(loupe.autoBlackOffset(), "有解码缓冲时必须返回写入值")
        XCTAssertEqual(offset, 0.004, accuracy: 1e-9, "工作空间口径：≈ −0.0035 向上取整 = 0.004")
        XCTAssertLessThan(offset, LightGroup.blackOffsetRange.upperBound, "没有被钳到 +0.01")
        XCTAssertEqual(session.edit.light.blackOffset, offset)
        XCTAssertEqual(session.history.count, 1, "一次点击 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "黑电平 · 自动")

        XCTAssertNil(loupe.autoBlackOffset(), "第二次点击是 no-op（幂等）")
        XCTAssertEqual(session.history.count, 1, "no-op 不加历史")
    }

    /// 没有解码缓冲（浏览器模式 / 还在加载）：返回 nil，不写文档、不加历史。
    func testAutoBlackOffsetReturnsNilWithoutADecodedBuffer() {
        let session = CatalogSession()
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        XCTAssertNil(loupe.autoBlackOffset())
        XCTAssertEqual(session.edit.light.blackOffset, 0)
        XCTAssertEqual(session.history.count, 0)

        session.mode = .grid
        XCTAssertNil(loupe.autoBlackOffset(), "浏览器模式同样 nil")
    }

    // MARK: - 5. 105 测量专用解码 + 守卫 + 回退

    /// 派单 105 的估计量守卫：−0.008 更负的点不足 50 个时用 p0.1，够多时仍用 min。
    func testTheEstimatorFallsBackToThePointOnePercentileWhenOnlyAFewOutliersAreLeft() {
        // 只有 14 颗单像素过冲：min −0.019，p0.1 −0.0042 → 用 p0.1，滑块不会顶到钳位。
        XCTAssertEqual(LoupeController.autoBlackRawValue(min: -0.019, p001: -0.0042,
                                                         extremeCount: 14), -0.0042)
        XCTAssertEqual(LoupeController.autoBlackOffset(for: LoupeController.autoBlackRawValue(
            min: -0.019, p001: -0.0042, extremeCount: 14)), 0.005)
        // 50 颗及以上是场景信号：仍用 min。
        XCTAssertEqual(LoupeController.autoBlackRawValue(min: -0.006, p001: -0.004,
                                                         extremeCount: 50), -0.006)
        // 没有候选：两者都是 0，自动值是 0。
        XCTAssertEqual(LoupeController.autoBlackRawValue(min: 0, p001: 0, extremeCount: 0), 0)
    }

    /// 派单 105 验收 3 —— L1030415 的自动黑电平不再顶到 ±0.01 钳位。
    ///
    /// 显示解码在 0.125 上（和 loupe 的首帧一致），测量解码在 0.5 上；写入值必须在 (0, 0.005]，
    /// 且按候选集覆盖率 ≥ 95%（候选集里加 offset 之后仍为负的不到 5%）。
    func testAutoBlackOffsetOnL1030415StopsHittingTheClamp() throws {
        let url = try fixture(named: "L1030415.dng", env: "PHOTONS_TEST_RAW_105")
        let session = CatalogSession()
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        _ = try loupe.makeFrame(url: url, viewport: ImageSize(width: 800, height: 600),
                                decodeScale: 0.125, edit: session.edit)

        let offset = try XCTUnwrap(loupe.autoBlackOffset(), "有解码缓冲时必须返回写入值")
        let measured = try RAWDecoder().decodeForMeasurement(url, scale: 0.5)
        let candidates = measured.blackCandidates(sampleStride: 5)
        let coverage = candidates.coverage(at: offset)
        print(String(format: "105 L1030415 auto %.4f · 候选 %d · 覆盖率 %.4f · min %.6f · p0.1 %.6f",
                     offset, candidates.count, coverage, candidates.min, candidates.p001))

        XCTAssertGreaterThan(offset, 0, "有候选集，自动值必须抬起来")
        XCTAssertLessThanOrEqual(offset, 0.005, "绝不能顶到 +0.01；滑块应 ≤ 5.0，实际 \(offset * 1000)")
        XCTAssertGreaterThanOrEqual(coverage, 0.95, "候选集覆盖率必须 ≥ 95%")
        XCTAssertEqual(session.edit.light.blackOffset, offset)
        XCTAssertEqual(session.history.count, 1, "一次点击 = 一条历史")
    }

    /// 派单 105 验收 6 —— 测量解码抛错时，`autoBlackOffset()` 退回显示缓冲、仍写入一个值，并打印
    /// 那行回退日志。
    func testAutoBlackOffsetFallsBackToTheDisplayBufferWhenTheMeasurementDecodeFails() throws {
        let url = try rawFixture()
        let session = CatalogSession()
        session.mode = .loupe
        let loupe = LoupeController(session: session)
        loupe.autoRenderEnabled = false
        _ = loupe.view
        _ = try loupe.makeFrame(url: url, viewport: ImageSize(width: 800, height: 600),
                                decodeScale: 0.125, edit: session.edit)
        loupe.measurementDecodeForTesting = { _, _ in throw DecodeError.renderFailed }

        let offset = try XCTUnwrap(loupe.autoBlackOffset(), "回退路径仍必须返回一个值")
        XCTAssertGreaterThan(offset, 0)
        XCTAssertEqual(session.edit.light.blackOffset, offset)
        XCTAssertEqual(session.history.count, 1)

        let source = try String(contentsOf: Self.loupeSource, encoding: .utf8)
        XCTAssertTrue(source.contains("AUTO BLACK · measurement decode failed, falling back"),
                      "回退必须留下那一行日志")
    }

    // MARK: - helpers

    private func rawFixture() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["PHOTONS_TEST_RAW"],
            NSString(string: "~/Desktop/test/L1030433.dng").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no RAW fixture; set PHOTONS_TEST_RAW")
    }

    private func fixture(named name: String, env: String) throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment[env],
            NSString(string: "~/Desktop/test/\(name)").expandingTildeInPath,
        ].compactMap { $0 }
        for c in candidates where FileManager.default.isReadableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        throw XCTSkip("no \(name) fixture; set \(env)")
    }

    private static func firstView(in root: NSView, where match: (NSView) -> Bool) -> NSView? {
        if match(root) { return root }
        for child in root.subviews {
            if let found = firstView(in: child, where: match) { return found }
        }
        return nil
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
    }

    private static var inspectorSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/InspectorView.swift")
    }

    private static var loupeSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/LoupeController.swift")
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
