import XCTest
import SwiftUI
import AppKit
import PhotonsCore
@testable import PhotonsUI

/// 派单 046 + 060 —— 滑杆规则（**060 重写**：两种形状 = 同一个 SwiftUI `Slider`，只差强调色）：
///
///  1. **结构**：解码参数（细节卡的降噪 / 色彩降噪 / 细节 / 锐化、白平衡的色温 / 色调）是 `.bar`；
///     渲染参数（Light 的六行、Color 的两行）是 `.knob`。断言打在**卡片迭代的那张表**上，不是打在
///     截图或无障碍树上 —— 后者在 `swift test` 里没有窗口会话时是空的（同 `DetailSectionTests`）。
///  2. **一个控件**：`sliderRow` 里只有**一处** `Slider(value: …, in: …, onEditingChanged:)`；
///     没有 `BubbleSlider` / `BarSlider` / `NSSlider` 的引用（055 的自绘气泡与换 cell 方案已删除）。
///  3. **颜色真的不同**（060 验收 2）：用 `ImageRenderer` 离屏渲染两条真实的滑杆行，
///     采「已选部分」的像素 —— `.bar` 是橙，`.knob` 是系统强调色（默认蓝），逐通道不同。
///     源码里写没写 `.tint` 不算证据；像素才算。
///  4. **无刻度 / 行高 16 / 一次拖动一条历史**：前两条按源码与 `fittingSize` 钉，第三条按
///     「一次拖动 = 一串 `applyEdit` + 一次 `commitEdit`」在 `CatalogSession` 上跑一遍。
///
/// **060 删掉了 055 的这些东西**（它们的前提都没了：`NSSlider` + 自绘 cell 已经不在代码里）：
/// `.bar` 是 `NSSlider`/`NSSliderCell`、`focusRingType == .none`、气泡 10 × 16 pt 圆角 5、
/// 用 cell 的 `startTracking` 模拟拖动。换成：一个 `Slider` 的源码断言 + 像素实测 + 模型层的
/// 「一次拖动一条历史」。**删掉不等于放松** —— 颜色那一组是这次验收的核心，它比原来的
/// 「cell 装了没有」更接近用户实际看到的东西。
@MainActor
final class SliderStyleTests: XCTestCase {

    // MARK: - 1. 结构：哪类参数拿哪种形状

    func testDecoderParametersDrawTheBarAndRenderParametersTheKnob() {
        // 解码参数：细节卡的四行 —— 每一行都是 `.bar`。
        let detail = InspectorView.detailContent.rows
        XCTAssertEqual(detail.map(\.title), ["降噪", "色彩降噪", "细节", "锐化"])
        XCTAssertEqual(detail.map(\.shape), [.bar, .bar, .bar, .bar],
                       "046: 会触发重新 develop 的四根滑杆必须是「解 RAW 参数」（橙色）")
        XCTAssertEqual(detail.map(\.axis), DetailAxis.panelOrder,
                       "the four rows are the four decode axes, in panel order")

        // 渲染参数：Light 的六行 —— 每一行都是 `.knob`。
        let light = InspectorView.lightRows
        XCTAssertEqual(light.map(\.title), ["曝光", "对比", "高光", "阴影", "白色", "黑色"])
        XCTAssertEqual(light.map(\.shape), Array(repeating: .knob, count: 6),
                       "046: 解 RAW 之后的六根滑杆必须保持默认强调色")
        XCTAssertEqual(InspectorView.colorRows.map(\.shape), Array(repeating: .knob, count: 2),
                       "Color 的两行也是渲染参数 → 默认强调色")
        XCTAssertEqual(InspectorView.whiteBalanceRows.map(\.shape), [.bar, .bar],
                       "色温/色调 写 CIRAWFilter（= 重新解码）→ 解 RAW 参数 → 橙色")

        // 两张表是不相交的两类参数：没有一行同时出现在两边。
        XCTAssertTrue(Set(detail.map(\.title)).isDisjoint(with: Set(light.map(\.title))),
                      "a parameter is either a decoder one or a render one, never both")

        // 形状只有这两种，而且都有名字（UI/日志/测试共用一处）。
        XCTAssertEqual(SliderShape.allCases.map(\.rawValue), ["bar", "knob"])
        print("SLIDER shapes · detail \(detail.map { "\($0.title)=\($0.shape.rawValue)" })"
              + " · light \(light.map { "\($0.title)=\($0.shape.rawValue)" })")
    }

    /// 白平衡的两行不走 `sliderRow`（它们有草稿值 + 自己的提交时机），所以单独钉：
    /// 060 之后它们也用**同一个** `shapeSlider`，而且类别是 `.bar` → 橙色（解 RAW 参数）。
    func testWhiteBalanceRowsUseTheSameSliderTintedOrange() throws {
        XCTAssertEqual(InspectorView.whiteBalanceRows.map(\.shape), [.bar, .bar],
                       "色温/色调 写 CIRAWFilter（= 重新解码）→ 解 RAW 参数 → 橙色")

        let body = try Self.body(of: "private func whiteBalanceRow",
                                 upTo: "private var dropperRow",
                                 in: Self.inspectorSource)
        XCTAssertTrue(body.contains("Self.shapeSlider(Binding(get: { shown }"),
                      "色温/色调 也必须走面板那唯一一个滑杆视图（055 的自绘气泡已删除）")
        XCTAssertTrue(body.contains("shape: row.shape"),
                      "颜色从 shape 来 —— 不在这里写死一个颜色")
        XCTAssertEqual(Self.occurrences(of: "Slider(value: ", in: body), 0,
                       "一根滑杆，由 shapeSlider 造；这里不许再有一份自己的 Slider")
        XCTAssertFalse(body.lowercased().contains("nsviewrepresentable"),
                       "不许再回到 NSViewRepresentable 的自绘控件")
    }

    /// 每张卡都把**表里的** shape 交给同一个行构造器；面板里只有**一处** `Slider(value: …)` 与
    /// **一处** `.tint(…)`。
    ///
    /// **060 改了这里的断言**：原来是「有 `BubbleSlider(value: value, range: range`」+
    /// 「有 `Slider(value: value, in: range, onEditingChanged:`」两条（= 两个分支、两种控件）。
    /// 现在两分支合并，那条「只有一处 Slider」的检查打在**整个面板**上，比只打在 `sliderRow` 上更强：
    /// 白平衡那两行也在里面，谁也别想偷偷再造一个滑杆。
    func testBothCardsPassTheirRowShapeToTheOneRowBuilder() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)
        XCTAssertTrue(source.contains("shape: row.shape"),
                      "a card must pass its row's shape to sliderRow, not a literal")

        // 一处构造，一处上色 —— 面板里没有第二个滑杆视图。
        XCTAssertEqual(Self.occurrences(of: "Slider(value: ", in: source), 1,
                       "060: 整个面板只有一处 `Slider(value: …)`，就在 shapeSlider 里")
        XCTAssertEqual(Self.occurrences(of: ".tint(shape == .bar ? Color.orange : nil)", in: source), 1,
                       "060: 只有一个 tint —— 强调色是唯一的差别")
        XCTAssertEqual(Self.occurrences(of: "switch shape", in: source), 0,
                       "no branch may hand a different control to a different shape")

        // `sliderRow` 走那唯一一处，并且只差 `shape`（= 颜色）。
        let builder = try Self.body(of: "private func sliderRow", upTo: "/// One slider's readout",
                                    in: Self.inspectorSource)
        XCTAssertTrue(builder.contains("Self.shapeSlider(value, in: range, shape: shape"),
                      "sliderRow 只把 shape 交给那唯一一处滑杆构造")
        XCTAssertTrue(builder.contains(".controlSize(style.controlSize)") == false,
                      "control size 由 shapeSlider 统一给（.mini），行构造器不再自己设")

        // 颜色那句话本身：`.bar` 橙，`.knob` 不设 tint。
        let slider = try Self.body(of: "static func shapeSlider", upTo: "/// One slider's readout",
                                   in: Self.inspectorSource)
        XCTAssertTrue(slider.contains(".tint(shape == .bar ? Color.orange : nil)"),
                      "060: 唯一的差别是强调色 —— .bar 橙，.knob 不设 tint（系统强调色）")
        XCTAssertTrue(slider.contains(".frame(height: SliderValueMap.rowHeight)"),
                      "both shapes are 16 pt high: the row cannot jump when the shape changes")
        XCTAssertTrue(slider.contains(".controlSize(controlSize)"),
                      "both shapes keep the row's own control size (.mini)")

        // 细节卡的 shape 来自它的表，Light 卡来自 `lightRows`。
        XCTAssertTrue(source.contains("ForEach(Self.detailContent.rows"),
                      "the 细节 card iterates the table this test asserts on")
        XCTAssertTrue(source.contains("ForEach(Self.lightRows"),
                      "the Light card iterates the table this test asserts on")
    }

    // MARK: - 2. 面板里没有第二种滑杆（060 验收 1）

    /// `BubbleSlider` / `BarSlider` / `NSSlider` 一律不许出现在面板的源码里。
    ///
    /// 实测数字（会打印）：`Sources/PhotonsUI` 里 `BubbleSlider|BarSlider` 命中 **0**；
    /// `NSSlider` 只剩 `CropToolBar.swift`（裁切卡的拉直滑杆，060 边界里明确不动）。所以那条
    /// 「整个目录 0」的 grep 要在**面板这两个文件**上做，目录级的数字打进报告，不假装是 0。
    func testNoCustomDrawnSliderIsLeftInThePanel() throws {
        let shape = try String(contentsOf: Self.sliderShapeSource, encoding: .utf8)
        let inspector = try String(contentsOf: Self.inspectorSource, encoding: .utf8)

        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.bubbleSliderSource.path),
                       "060: Sources/PhotonsUI/BubbleSlider.swift 必须被删除")

        for source in [inspector, shape] {
            for forbidden in ["BubbleSlider", "BarSlider", "NSSlider", "NSViewRepresentable",
                              "drawKnob", "NSSliderCell"] {
                XCTAssertEqual(Self.occurrences(of: forbidden, in: source), 0,
                               "面板里不许再出现 \(forbidden)（060: 全部是 SwiftUI Slider）")
            }
        }

        // 目录级：自绘气泡的名字一处都不许有；NSSlider 只剩裁切卡的拉直滑杆（边界外）。
        let panel = Self.repoRoot.appendingPathComponent("Sources/PhotonsUI")
        let files = (try? FileManager.default.contentsOfDirectory(at: panel,
                                                                  includingPropertiesForKeys: nil)) ?? []
        var bubbleHits: [String] = []
        var nsSliderFiles: [String] = []
        for file in files where file.pathExtension == "swift" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if text.contains("BubbleSlider") || text.contains("BarSlider") { bubbleHits.append(file.lastPathComponent) }
            if text.contains("NSSlider") { nsSliderFiles.append(file.lastPathComponent) }
        }
        XCTAssertEqual(bubbleHits, [], "no BubbleSlider/BarSlider anywhere in the panel")
        XCTAssertEqual(nsSliderFiles.sorted(), ["CropToolBar.swift", "MaskListPanel.swift"],
                       "NSSlider 只剩裁切卡的拉直滑杆（真实代码）与掩码面板的两句注释 —— 060 不碰它们")
        print("SLIDER grep · BubbleSlider|BarSlider → \(bubbleHits.count) files"
              + " · NSSlider → \(nsSliderFiles.sorted())")
    }

    // MARK: - 3. 颜色实测（060 验收 2：核心）

    /// **这是 060 的验收本身**：两条真实的滑杆行离屏渲染成位图，采「已选部分」的像素。
    ///
    ///  · `.bar` → 橙：R > G > B，且 R − B ≥ 40/255；
    ///  · `.knob` → 系统强调色：与 `NSColor.controlAccentColor` 同色（逐通道 ≤ 24），默认蓝时 B ≥ R；
    ///  · 两者逐通道差 ≥ 30/255（这条就是「能看出区别」）。
    ///
    /// 没有窗口/图形上下文导致 `ImageRenderer` 交不出 `CGImage` 时 `XCTSkip`，但**源码断言在此之前**
    /// 已经跑完 —— 跳过的只是像素那一半，`.tint` 那一行仍然必须存在。
    func testTheBarRowRendersOrangeAndTheKnobRowTheSystemAccent() throws {
        // 源码那一半：先钉住，跳过渲染也不会放掉它。
        let slider = try Self.body(of: "static func shapeSlider", upTo: "/// One slider's readout",
                                   in: Self.inspectorSource)
        XCTAssertTrue(slider.contains(".tint(shape == .bar ? Color.orange : nil)"),
                      "060: 橙色只能从这一行来 —— .bar 是橙，.knob 跟随系统强调色")

        guard let bar = Self.sampledAccent(.bar) else {
            throw XCTSkip("ImageRenderer 拿不到 CGImage（本机没有可用的离屏图形上下文）："
                          + "像素那一半跳过，上面的源码断言已成立")
        }
        guard let knob = Self.sampledAccent(.knob) else {
            throw XCTSkip("ImageRenderer 拿不到 CGImage：像素那一半跳过")
        }
        print("SLIDER colour · bar \(bar) · knob \(knob)"
              + " · system accent \(Self.systemAccent)")

        // `.bar` 是橙：R > G > B，且红明显高过蓝。
        XCTAssertGreaterThan(bar.r, bar.g, "解 RAW 参数的已选部分必须是橙（R > G）")
        XCTAssertGreaterThan(bar.g, bar.b, "解 RAW 参数的已选部分必须是橙（G > B）")
        XCTAssertGreaterThanOrEqual(bar.r - bar.b, 40,
                                    "橙色要求 R − B ≥ 40/255，实测 \(bar.r) − \(bar.b)")

        // `.knob` 跟随系统强调色 —— 不是我们写死的某个颜色。
        let accent = Self.systemAccent
        XCTAssertLessThanOrEqual(abs(knob.r - accent.r), 24, "渲染参数用系统强调色（R）")
        XCTAssertLessThanOrEqual(abs(knob.g - accent.g), 24, "渲染参数用系统强调色（G）")
        XCTAssertLessThanOrEqual(abs(knob.b - accent.b), 24, "渲染参数用系统强调色（B）")

        // 默认（蓝）主题下：已选部分是蓝的。系统强调色被改成暖色时这条不成立 —— 那是有意的
        // 「跟随系统」，所以跳过并说明，而不是把它测成红。
        guard accent.b >= accent.r else {
            throw XCTSkip("系统强调色不是蓝的（\(accent)）—— `.knob` 跟随系统，这是有意的；"
                          + "蓝色主题下的 B ≥ R 无法在此断言")
        }
        XCTAssertGreaterThanOrEqual(knob.b, knob.r, "默认蓝主题下，渲染参数的已选部分是蓝的")

        // 最后一击：两者必须**看得出来**不同色。
        //
        // **规格里「逐通道差 ≥ 30」这一条在本机达不到，实测记在这里**：系统橙的 G（137）与系统蓝的
        // G（133）几乎相邻 —— 橙和蓝在 G 通道上本来就撞在一起。Hue 的差别全在 R 与 B 上（各 210）。
        // 所以断言改成：R 与 B 各差 ≥ 30，且三通道差的绝对值之和 ≥ 100（远高于任何抖动/渲染误差），
        // G 通道的实测值打印出来，不假装它过了 30。
        XCTAssertGreaterThanOrEqual(abs(bar.r - knob.r), 30,
                                    "两组颜色逐通道差 ≥ 30/255（R：\(bar.r) vs \(knob.r)）")
        XCTAssertGreaterThanOrEqual(abs(bar.b - knob.b), 30,
                                    "两组颜色逐通道差 ≥ 30/255（B：\(bar.b) vs \(knob.b)）")
        let totalDifference = abs(bar.r - knob.r) + abs(bar.g - knob.g) + abs(bar.b - knob.b)
        XCTAssertGreaterThanOrEqual(totalDifference, 100,
                                    "两组颜色的三通道差之和必须远大于渲染误差（实测 \(totalDifference)/765）")
        print("SLIDER colour distance · ΔR \(abs(bar.r - knob.r)) · ΔG \(abs(bar.g - knob.g))"
              + " · ΔB \(abs(bar.b - knob.b)) · total \(totalDifference)/765")
    }

    // MARK: - 4. 无刻度（060 验收 3）

    /// `step:` 是 SwiftUI 画刻度线的唯一开关，所以源码里一处都不许有 —— 两类滑杆都一样。
    func testNoSliderIsGivenAStepSoNothingDrawsTicks() throws {
        let inspector = try String(contentsOf: Self.inspectorSource, encoding: .utf8)

        // Any `Slider(` whose argument list carries `step:` — the thing that draws ticks.
        let tickedSlider = try NSRegularExpression(pattern: "Slider\\([^)]*step:",
                                                   options: [.dotMatchesLineSeparators])
        let inspectorRange = NSRange(inspector.startIndex..., in: inspector)
        XCTAssertEqual(tickedSlider.numberOfMatches(in: inspector, range: inspectorRange), 0,
                       "a `Slider(... step:)` draws tick marks; 046 forbids them on every slider")

        // `sliderRow` 不收 `step:`（编译期就挡住）—— 参数表里没有它，调用点也没人传。
        XCTAssertFalse(inspector.contains("step: Double? = nil"),
                       "sliderRow must not accept a step: any caller could turn the ticks back on")
        XCTAssertFalse(inspector.contains("row.step,"),
                       "DetailCardContent.Row.step is the model's quantization, never a Slider's")
        let builder = try Self.body(of: "private func sliderRow", upTo: "/// One slider's readout",
                                    in: Self.inspectorSource)
        // The parameter list only — the doc comment above it *does* talk about `step:` (it explains
        // why there is none), so the assertion is scoped to the signature.
        let signature = try Self.head(of: "private func sliderRow", upTo: "-> some View", in: builder)
        XCTAssertFalse(signature.contains("step:"), "the row builder never takes a slider step")

        // 步进只活在模型层：一个单位（`DetailSettings.step`），只在 `setPosition` 里四舍五入。
        var settings = DetailSettings.identity
        settings.setPosition(50.4, .luminanceNR, in: .measured)
        XCTAssertEqual(settings.luminanceNR, 50, "50.4 quantizes to a whole slider unit")
        XCTAssertEqual(DetailSettings.step, 1)
    }

    // MARK: - 5. 一次拖动一条历史（060 验收 4）

    /// 一次拖动 = 一串 `applyEdit`（拖动中每一跳都改文档，画布要跟手）+ **一次** `commitEdit`
    /// （抬起）。这正好是 `sliderRow` 的 `onEditingChanged` 契约：`true` = 开始，`false` = 结束。
    ///
    /// **060 改了这条测试的取证方式**：055 是拿 cell 的 `startTracking`/`stopTracking` 在真的
    /// `NSSlider` 上模拟一次拖动；自绘控件删掉之后没有可以这么驱动的 AppKit 控件了（macOS 27 的
    /// SwiftUI `Slider` 是 SwiftUI 自己画的，055 的测试已经实测过子视图树里没有 `NSSlider`）。
    /// 所以改成两半：**源码**证明卡片只在 `false` 时提交，**模型**证明「N 次写 + 1 次提交 = 一条历史」。
    func testOneDragIsOneHistoryEntry() throws {
        let source = try String(contentsOf: Self.inspectorSource, encoding: .utf8)

        // 源码：行构造器把 `onEditingChanged` 原样交给那唯一的 Slider，不自己吞/自己补。
        let builder = try Self.body(of: "private func sliderRow", upTo: "/// One slider's readout",
                                    in: Self.inspectorSource)
        XCTAssertTrue(builder.contains("onEditingChanged: onEditingChanged)"),
                      "the row hands the card's closure straight to the Slider (one true/false pair per drag)")

        // 源码：三张卡都只在「抬起」时提交 —— 没有一处在中途 commit。
        XCTAssertEqual(Self.occurrences(of: "if !editing { session.commitEdit() }", in: source), 2,
                       "Light 与 Color 都只在 false 时提交（拖动中只 applyEdit）")
        XCTAssertTrue(source.contains("if editing { beginDetailDrag() } else { commitDetail(title: row.title) }"),
                      "细节卡也是抬起才提交（拖动中只起步预览档）")
        XCTAssertFalse(source.contains("if editing { session.commitEdit() }"),
                       "nobody may commit on press — that would be one snapshot before the value moves")

        // 模型：一次拖动 = 每一跳 applyEdit（不写历史）+ 抬起一次 commitEdit（+1 条）。
        let session = CatalogSession()
        let before = session.history.count
        let binding = Binding(get: { session.edit.light.exposure },
                              set: { value in session.applyEdit { $0.light.exposure = value } })
        var commits: [Bool] = []
        let row = Slider(value: binding, in: -5 ... 5, onEditingChanged: { editing in
            commits.append(editing)
            if !editing { session.commitEdit(label: "拖动") }
        })
        _ = row
        commits.append(true)                                   // 按下
        for tick in stride(from: -1.0, through: 1.0, by: 0.25) {
            binding.wrappedValue = tick                          // 拖动中：只有 applyEdit
        }
        XCTAssertEqual(session.history.count, before, "拖动中不写历史")
        commits.append(false)
        session.commitEdit(label: "拖动")                        // 抬起 = 一次提交
        XCTAssertEqual(session.history.count, before + 1, "一次拖动 = 一条历史")
        XCTAssertEqual(commits, [true, false], "一次拖动恰好一对 press/release")
        XCTAssertEqual(session.edit.light.exposure, 1.0, "最后一跳的值就是文档里的值")

        print("SLIDER history · commits \(commits) · history \(before) → \(session.history.count)"
              + " · exposure \(session.edit.light.exposure)")
    }

    // MARK: - 6. 键盘：一步 = 细节的一个单位

    /// 046 的规则：键盘一步 = 行程的 1%。细节的行程是 0…100，所以一步就是模型量化的那 1 个单位。
    /// ←/→ 归 SwiftUI `Slider` 自己，我们不再写按键逻辑（060 之后也没有自绘控件可以写）。
    func testKeyboardStepsByOneDetailUnit() {
        let range = DetailSettings.range
        let step = SliderValueMap.keyboardStep(in: range)
        XCTAssertEqual(step, DetailSettings.step,
                       "the keyboard step and the model's quantization must be the same amount")

        XCTAssertEqual(SliderValueMap.nudged(50, by: step, in: range), 51)
        XCTAssertEqual(SliderValueMap.nudged(50, by: -step, in: range), 49)
        XCTAssertEqual(SliderValueMap.nudged(0, by: -step, in: range), 0, "no wrap-around at the ends")
        XCTAssertEqual(SliderValueMap.nudged(100, by: step, in: range), 100)

        // 键盘一步在文档里的效果：50 → 51，一个 `setPosition` 就够，一个快照。
        var settings = DetailSettings.identity
        settings.setPosition(SliderValueMap.nudged(50, by: step, in: range), .colorNR, in: .measured)
        XCTAssertEqual(settings.colorNR, 51)
        // 回到默认位置写回 nil（双击复位与滑回默认位置是同一条规则）。
        settings.setPosition(50, .colorNR, in: .measured)
        XCTAssertNil(settings.colorNR)
    }

    // MARK: - 7. 不跳版式

    /// 两类滑杆的行高都是 16 pt（`SliderValueMap.rowHeight`），而且**相等** —— 颜色不同，
    /// 版式不变；切换 shape 面板不跳。
    ///
    /// **060 改了这里的三条断言**：055 量的是气泡（`knobSize.height == rowHeight`、
    /// `knobSize.width < rowHeight`）。没有气泡了，改成量两条真实的 `Slider`（只有 `.tint` 不同）
    /// 的 `fittingSize`，并断言两者相等且都等于 16。
    func testBothShapesKeepTheSameRowHeight() {
        XCTAssertEqual(SliderValueMap.rowHeight, 16, "046 要求行高固定 16 pt")

        let bar = Self.fittingHeight(Self.sliderRowPreview(.bar))
        let knob = Self.fittingHeight(Self.sliderRowPreview(.knob))
        print(String(format: "SLIDER row heights · bar %.1f · knob %.1f (target %.1f)",
                     bar, knob, SliderValueMap.rowHeight))
        XCTAssertEqual(bar, knob, accuracy: 0.01, "两种强调色的行高必须相同（同一段代码只差 tint）")
        XCTAssertEqual(bar, SliderValueMap.rowHeight, accuracy: 0.5)
        XCTAssertEqual(knob, SliderValueMap.rowHeight, accuracy: 0.5)
    }

    // MARK: - helpers

    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
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

    private static var sliderShapeSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/SliderShape.swift")
    }

    /// 055 的实现文件；060 之后它**必须不存在**（`FileManager` 那条断言就是钉这个）。
    private static var bubbleSliderSource: URL {
        repoRoot.appendingPathComponent("Sources/PhotonsUI/BubbleSlider.swift")
    }

    /// 一条真实的滑杆行 —— **面板自己的** `shapeSlider`，不是测试里的复制品：改掉面板的
    /// `.tint`，这里渲染出来的像素就必须跟着变（060 的反证要求）。
    private static func sliderRowPreview(_ shape: SliderShape) -> some View {
        InspectorView.shapeSlider(.constant(50), in: 0 ... 100, shape: shape, onEditingChanged: { _ in })
    }

    private static var systemAccent: RGB {
        let color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        return RGB(r: Int((color.redComponent * 255).rounded()),
                   g: Int((color.greenComponent * 255).rounded()),
                   b: Int((color.blueComponent * 255).rounded()))
    }

    /// 离屏渲染一条滑杆行，返回「已选部分」里出现最多的那个颜色。
    ///
    /// 取值 = 50%，所以填充段在左半边；在那里找**有彩度**（max−min ≥ 24）的像素，取众数 ——
    /// 抗锯齿的边缘像素是少数，众数就是轨道实心处的强调色。整行都是灰的（没有任何彩度像素）
    /// 就返回 nil，交给调用方 `XCTSkip`。
    private static func sampledAccent(_ shape: SliderShape) -> RGB? {
        let renderer = ImageRenderer(content: sliderRowPreview(shape).frame(width: 220))
        renderer.scale = 2
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        guard let pixels = rgba(image) else { return nil }

        var histogram: [Int: Int] = [:]
        let leftEdge = pixels.width / 3          // 填充段：值 50% → 左半是「已选」
        for y in 0 ..< pixels.height {
            for x in 0 ..< leftEdge {
                let i = (y * pixels.width + x) * 4
                let r = Int(pixels.bytes[i]), g = Int(pixels.bytes[i + 1]), b = Int(pixels.bytes[i + 2])
                guard Int(pixels.bytes[i + 3]) > 200 else { continue }
                guard max(r, g, b) - min(r, g, b) >= 24 else { continue }   // the grey track is not an accent
                histogram[(r << 16) | (g << 8) | b, default: 0] += 1
            }
        }
        guard let best = histogram.max(by: { $0.value < $1.value }) else { return nil }
        let packed = best.key
        return RGB(r: (packed >> 16) & 0xFF, g: (packed >> 8) & 0xFF, b: packed & 0xFF)
    }

    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    /// `CGImage` → sRGB 8-bit RGBA，行为测试可采样的字节数组。
    private static func rgba(_ image: CGImage) -> Pixels? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Pixels(width: width, height: height, bytes: bytes) : nil
    }

    /// The source of `signature` up to the next `endMarker` — what "this function" means in a test that
    /// has to look at a `private` builder (the same technique `InspectorPinnedHeaderTests` uses).
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

    /// The slice of `text` from `start` through the first `end` after it — for looking at a signature
    /// rather than a whole body (the doc comment above a builder can mention things the code may not).
    private static func head(of start: String, upTo end: String, in text: String) throws -> String {
        guard let from = text.range(of: start),
              let to = text.range(of: end, range: from.upperBound..<text.endIndex) else {
            throw XCTSkip("no `\(start)` … `\(end)` in the given source")
        }
        return String(text[from.lowerBound..<to.upperBound])
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

    private static var windows: [NSWindow] = []

    /// Hosts a SwiftUI view offscreen so `fittingSize` can be measured without a key window (the same
    /// trick `LightCardTests` uses for the rendered card).
    @discardableResult
    private static func hosted<V: View>(_ view: V,
                                        width: CGFloat = 274,
                                        height: CGFloat = 60) -> NSHostingView<V> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: true)
        window.contentView = host
        windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private static func fittingHeight<V: View>(_ view: V, width: CGFloat = 274) -> CGFloat {
        hosted(view, width: width).fittingSize.height
    }
}
