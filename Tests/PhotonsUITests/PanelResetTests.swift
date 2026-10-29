import XCTest
import AppKit
import SwiftUI
import PhotonsCatalog
import PhotonsCore
@testable import PhotonsUI

/// 派单 047 — 双击复位：参数名回该字段的默认，分区名回整组默认，**一条**历史。
///
/// What is pinned, and why each assertion is the one that matters:
///
///   1. **一条 = 一次 ⌘Z**。双击「Light」把七根滑杆 + 两个绝对电平写回默认，历史只 +1；⌘Z 一步全部
///      回来（逐字段断言）。写错成「每字段各提交一次」会得到 7 条 —— 下面 `testTheGroupResetIsOne
///      EntryWhileThePerFieldPathWouldBeSeven` 就是这个错误实现的常驻反证：它把两条路径都跑一遍，
///      一条是 1，另一条是 7。
///   2. **默认不是字面 0**。参考值是 `EditModel.neutral`（各组自己的默认构造）与 `DetailAxis` 的机身
///      基线 —— 细节是 `0/50/0/50`（Leica），白平衡是 `nil`（原照）。硬编码 0 会让这条红。
///   3. **白平衡 = 原照设定 = 重新解码**：`decodeInputs.key` 必须移动过去再回来（这正是「会重新
///      develop」的机器可读形式，与 `WhiteBalanceSectionTests` 用 `decodeCounts` 测的是同一件事）。
///   4. **已经默认就不写历史**：双击一下不该长出一条空快照，更不该截断 redo 分支。
///
/// 走的是 `PanelResets` —— 面板双击时调用的**同一个**实现（与 `WhiteBalanceCommands` 同一套路），
/// 所以这里绿的断言就是屏幕上那个动作的断言。视图层的接线（`card(title:reset:)`、
/// `ResetOnDoubleClick`）在 `testEveryParameterCardCanBeResetFromItsTitle` 里按源码钉住：`swift test`
/// 没有窗口会话，无障碍树是空的（同 `DetailSectionTests` 的已知限制）。
@MainActor
final class PanelResetTests: XCTestCase {

    // MARK: - 1. 双击参数名

    /// 曝光 +2.0 → 双击「曝光」→ 0.0，历史 +1；⌘Z 回到 +2.0。
    func testDoubleClickingAParameterNameResetsThatFieldAndUndoBringsItBack() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)

        // A drag that lands on +2.0: one snapshot, the row's own path.
        session.applyEdit { $0.light.exposure = 2 }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let before = session.history.count

        XCTAssertTrue(resets.field(\.light.exposure, label: "曝光"), "a changed field must reset")
        XCTAssertEqual(session.edit.light.exposure,
                       EditModel.neutral.light.exposure, accuracy: 1e-12,
                       "曝光's default comes from the model (0), not from a literal in the panel")
        XCTAssertEqual(session.history.count, before + 1, "双击参数名 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "曝光")

        XCTAssertTrue(session.undo(), "⌘Z must be able to take the reset back")
        XCTAssertEqual(session.edit.light.exposure, 2, "⌘Z 回到 +2.0")
        print("曝光 reset: 2 → \(EditModel.neutral.light.exposure) · history +1 · undo → "
              + "\(session.edit.light.exposure)")
    }

    /// 每根滑杆的默认都来自它自己的字段（不是同一个 0）：色彩降噪回 50，不是 0。
    func testEachParametersDefaultIsItsOwnFieldAndNotZero() {
        // Every tone/color row's default is the neutral document's value for that very key path.
        for row in InspectorView.lightRows + InspectorView.colorRows {
            XCTAssertEqual(row.defaultValue, EditModel.neutral[keyPath: row.keyPath])
        }
        // 细节: the body's baseline position, which is 50 for colour NR on a Leica (and 100 for
        // sharpness on an R5) — a 0 here would switch Apple's default off (031).
        let leica = DetailBaseline.measured
        XCTAssertEqual(DetailAxis.panelOrder.map { $0.defaultPosition(in: leica) }, [0, 50, 0, 50])
        XCTAssertNotEqual(DetailAxis.colorNR.defaultPosition(in: leica), 0,
                          "the panel must not treat 'default' as 'zero'")

        // 色温/色调: as shot = `nil`, because the default is the *file's* balance (006).
        XCTAssertNil(SessionDefaults.temperature)
        XCTAssertNil(SessionDefaults.tint)
        print("defaults · 曝光 \(InspectorView.lightRows[0].defaultValue) · 色彩降噪 "
              + "\(DetailAxis.colorNR.defaultPosition(in: leica)) · 色温 as shot (nil)")
    }

    /// 双击「色彩降噪」（细节卡的一根）→ 回机身默认位置，一条历史，可 ⌘Z。
    func testDoubleClickingADetailParameterGoesBackToTheBodyBaseline() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { $0.detailSettings.setPosition(20, .colorNR, in: .measured) }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let before = session.history.count

        XCTAssertTrue(resets.detail(.colorNR))
        XCTAssertNil(session.edit.detailSettings.colorNR, "`nil` = 停在该机身的默认位置")
        XCTAssertEqual(session.edit.detailSettings.position(.colorNR, in: .measured), 50,
                       "屏幕上是 50，不是 0")
        XCTAssertEqual(session.history.count, before + 1)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.detailSettings.colorNR, 20)
    }

    // MARK: - 2. 双击分区名

    /// Light 里七个滑杆 + 两个绝对电平各设非默认值 → 双击「Light」→ 全部回默认，历史**只 +1**。
    func testDoubleClickingLightPutsEveryFieldBackInOneSnapshot() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)

        session.applyEdit { model in
            model.light.exposure = 2
            model.light.contrast = 40
            model.light.highlights = -30
            model.light.midtones = 18
            model.light.shadows = 25
            model.light.whites = 15
            model.light.blacks = -10
            // 白平衡不在这张卡里：它有自己的卡和自己的双击，所以这里必须原样保留。
            model.light.temperature = 5200
            model.light.tint = 8
        }
        XCTAssertTrue(session.commitEdit(label: "一堆调整"))
        let before = session.history.count

        XCTAssertTrue(resets.group(.light), "a changed card must reset")

        // 逐字段：七个滑杆回自己字段的默认（schema 11 之后 Light 卡只有这七个）。
        let neutral = EditModel.neutral.light
        XCTAssertEqual(session.edit.light.exposure, neutral.exposure, accuracy: 1e-12)
        XCTAssertEqual(session.edit.light.contrast, neutral.contrast, accuracy: 1e-12)
        XCTAssertEqual(session.edit.light.highlights, neutral.highlights, accuracy: 1e-12)
        XCTAssertEqual(session.edit.light.midtones, neutral.midtones, accuracy: 1e-12)
        XCTAssertEqual(session.edit.light.shadows, neutral.shadows, accuracy: 1e-12)
        XCTAssertEqual(session.edit.light.whites, neutral.whites, accuracy: 1e-12)
        XCTAssertEqual(session.edit.light.blacks, neutral.blacks, accuracy: 1e-12)
        // 白平衡原样：Light 的复位不许偷偷把色温也清掉。
        XCTAssertEqual(session.edit.light.temperature, 5200,
                       "the Light card does not own the white balance — its reset must not touch it")
        XCTAssertEqual(session.edit.light.tint, 8)

        XCTAssertEqual(session.history.count, before + 1, "整组复位 = 一条历史，不是 N 条")
        XCTAssertEqual(session.history.currentSnapshot?.label, InspectorView.Section.light.title,
                       "the undo label is the card the user double-clicked")
        print("Light reset: history +\(session.history.count - before) · "
              + "\(session.edit.light.exposure)/\(session.edit.light.contrast)/"
              + "\(session.edit.light.highlights)/\(session.edit.light.midtones)/\(session.edit.light.shadows)/"
              + "\(session.edit.light.whites)/\(session.edit.light.blacks)")
    }

    /// 一步 ⌘Z 把整组逐字段带回来。
    func testOneUndoTakesTheWholeLightGroupBack() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            model.light.exposure = 1.5
            model.light.contrast = 22
            model.light.highlights = -11
            model.light.midtones = 17
            model.light.shadows = 33
            model.light.whites = 44
            model.light.blacks = -55
        }
        XCTAssertTrue(session.commitEdit(label: "一堆调整"))
        XCTAssertTrue(resets.group(.light))
        XCTAssertTrue(session.undo())

        let restored = session.edit.light
        XCTAssertEqual(restored.exposure, 1.5, "⌘Z 一步：六个字段逐个回来")
        XCTAssertEqual(restored.contrast, 22)
        XCTAssertEqual(restored.highlights, -11)
        XCTAssertEqual(restored.shadows, 33)
        XCTAssertEqual(restored.whites, 44)
        XCTAssertEqual(restored.blacks, -55)
    }

    /// **反证（常驻）**：把整组复位写成「每字段各提交一次」就是 N 条历史。
    ///
    /// 116 把三个暗角滑杆搬进「校正」卡，但双击校正只复位了 `optics`（色差）——用户 2026-10-29
    /// 的原话是「双击校正不能让暗角的任何滑块归位」。这条钉住卡片的**完整**范围：色差 + 三个暗角，
    /// 一次双击一条历史；而「效果」卡不再伸进暗角（那是另一张卡的滑杆）。
    func testDoubleClickOnCorrectionResetsOpticsAndVignetteInOneSnapshot() throws {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            model.optics.caRed = 12
            model.optics.caBlue = -8
            model.effects.vignetteAmount = -55
            model.effects.vignetteMidpoint = 70
        }
        XCTAssertTrue(session.commitEdit(label: "校正"))
        let before = session.history.count

        XCTAssertTrue(resets.group(.correction), "changed card must reset")
        XCTAssertEqual(session.history.count, before + 1, "one double-click = one ⌘Z")
        XCTAssertTrue(session.edit.optics.isIdentity)
        let neutral = EditModel.neutral.effects
        XCTAssertEqual(session.edit.effects.vignetteAmount, neutral.vignetteAmount, accuracy: 1e-12)
        XCTAssertEqual(session.edit.effects.vignetteMidpoint, neutral.vignetteMidpoint, accuracy: 1e-12)
        XCTAssertFalse(resets.group(.correction), "nothing left to reset → no empty snapshot")

        // 效果 卡不再碰暗角：只复位它自己那七行。
        session.applyEdit { model in
            model.effects.vignetteAmount = -40
            model.effects.grain = 35
        }
        XCTAssertTrue(session.commitEdit(label: "效果"))
        XCTAssertTrue(resets.group(.effects))
        XCTAssertEqual(session.edit.effects.vignetteAmount, -40, accuracy: 1e-12,
                       "暗角 belongs to 校正 now — 效果's double-click must leave it alone")
        XCTAssertEqual(session.edit.effects.grain, EditModel.neutral.effects.grain, accuracy: 1e-12)
    }

    /// 这里把两条路径都跑一遍：`group(.light)` 是 1，逐字段循环是 7。前者一旦被改成后者，第一条
    /// 断言立刻红 —— 这就是规格第 7 条要的反证，不需要改代码再手动跑一次。
    func testTheGroupResetIsOneEntryWhileThePerFieldPathWouldBeSeven() {
        func configured() -> CatalogSession {
            let session = CatalogSession()
            session.applyEdit { model in
                model.light.exposure = 2
                model.light.contrast = 40
                model.light.highlights = -30
                model.light.midtones = 18
                model.light.shadows = 25
                model.light.whites = 15
                model.light.blacks = -10
            }
            session.commitEdit(label: "一堆调整")
            return session
        }

        // (a) the shipped path: one entry
        let one = configured()
        let oneBefore = one.history.count
        PanelResets(session: one).group(.light)
        let oneDelta = one.history.count - oneBefore

        // (b) the failing shape: one applyEdit + one commitEdit per field
        let many = configured()
        let manyBefore = many.history.count
        for row in InspectorView.lightRows {
            many.applyEdit { $0[keyPath: row.keyPath] = EditModel.neutral[keyPath: row.keyPath] }
            many.commitEdit(label: row.title)
        }
        let manyDelta = many.history.count - manyBefore

        print("group reset · shipped \(oneDelta) snapshot(s) · per-field \(manyDelta) snapshot(s)")
        XCTAssertEqual(oneDelta, 1, "双击分区必须是**一条**历史")
        XCTAssertEqual(manyDelta, InspectorView.lightRows.count,
                       "the per-field route is what this test guards against: it is N, not 1")
        XCTAssertNotEqual(oneDelta, manyDelta, "一条和 N 条必须是可分辨的，否则这条断言没有意义")
    }

    /// 090: 双击「中间调」→ 回 0，一条历史；⌘Z 回到拖动值。字段复位走的是同一张 `ToneRow` 表。
    func testDoubleClickingMidtonesResetsOnlyThatRow() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            model.light.midtones = 40
            model.light.shadows = 25
        }
        XCTAssertTrue(session.commitEdit(label: "拖动"))
        let before = session.history.count

        XCTAssertTrue(resets.field(\.light.midtones, label: "中间调"))
        XCTAssertEqual(session.edit.light.midtones, 0, "中间调回 0")
        XCTAssertEqual(session.edit.light.shadows, 25, "只清这一根")
        XCTAssertEqual(session.history.count, before + 1, "双击参数名 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "中间调")

        XCTAssertFalse(resets.field(\.light.midtones, label: "中间调"), "已在默认值上，不许造空快照")
        XCTAssertEqual(session.history.count, before + 1)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.light.midtones, 40, "⌘Z 回到 40")
    }

    // MARK: - 3. 白平衡 = 原照设定

    /// 双击「白平衡」→ `temperature/tint` 回 `nil`，**一条**历史，且 `decodeInputs` 移动（= 重新 develop）。
    func testTheWhiteBalanceGroupResetIsAsShotAndMovesTheDecodeInputs() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        let asShotKey = session.edit.decodeInputs.key

        session.applyEdit { model in
            model.light.temperature = 5200
            model.light.tint = 8
        }
        XCTAssertTrue(session.commitEdit(label: "色温"))
        XCTAssertNotEqual(session.edit.decodeInputs.key, asShotKey,
                          "显式色温必然是另一份解码输入（= 一次新的 develop）")
        let before = session.history.count

        XCTAssertTrue(resets.group(.whiteBalance))
        XCTAssertNil(session.edit.light.temperature, "原照设定 = nil（不是 5200，也不是 6500）")
        XCTAssertNil(session.edit.light.tint)
        XCTAssertTrue(session.edit.light.whiteBalance.isAsShot)
        XCTAssertEqual(session.edit.decodeInputs.key, asShotKey,
                       "回到原照：解码输入回到 as shot 那一份，所以会重新 develop")
        XCTAssertEqual(session.history.count, before + 1, "整组复位 = 一条历史")
        XCTAssertEqual(session.history.currentSnapshot?.label, "原照设置")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.light.temperature, 5200)
        XCTAssertEqual(session.edit.light.tint, 8)
        print("白平衡 reset: 5200/+8 → as shot · decodeInputs \(session.edit.decodeInputs.key)")
    }

    /// 双击「色温」（单个参数）只把那一根轴回原照，色调原样。
    func testDoubleClickingTheTemperatureNameOnlyClearsThatAxis() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            model.light.temperature = 5200
            model.light.tint = 12
        }
        XCTAssertTrue(session.commitEdit(label: "色温"))
        let before = session.history.count

        XCTAssertTrue(resets.whiteBalanceField(isTemperature: true))
        XCTAssertNil(session.edit.light.temperature)
        XCTAssertEqual(session.edit.light.tint, 12, "the other axis keeps what it held")
        XCTAssertEqual(session.history.count, before + 1)

        XCTAssertTrue(resets.whiteBalanceField(isTemperature: false))
        XCTAssertNil(session.edit.light.tint)
        XCTAssertTrue(session.edit.light.whiteBalance.isAsShot)
    }

    // MARK: - 4. 细节 = 机身基线

    /// 双击「细节」→ 四条滑杆回**基线位置**（Leica `0/50/0/50`），不是全 0，一条历史。
    func testTheDetailGroupResetReturnsToTheBodyBaselineNotToZero() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        let asShotKey = session.edit.decodeInputs.key

        // All four dragged away from their default positions (20 / 80 / 30 / 70 on any body, since
        // neither 20 nor 80 is a baseline: Leica is 0/50/0/50, R5 sharpness 100; 042 细节's travel is
        // 0…30, so 30 is its right end — amount 3.0, still not the Leica's default position 0).
        session.applyEdit { model in
            model.detailSettings.setPosition(20, .luminanceNR, in: .measured)
            model.detailSettings.setPosition(80, .colorNR, in: .measured)
            model.detailSettings.setPosition(30, .detail, in: .measured)
            model.detailSettings.setPosition(70, .sharpness, in: .measured)
        }
        XCTAssertTrue(session.commitEdit(label: "降噪"))
        XCTAssertNotEqual(session.edit.decodeInputs.key, asShotKey,
                          "碰过细节就是另一份解码输入")
        let before = session.history.count

        XCTAssertTrue(resets.group(.detail))

        let leica = DetailBaseline.measured
        XCTAssertTrue(session.edit.detailSettings.isIdentity,
                      "全 nil = 四根都停在机身默认位置")
        XCTAssertEqual(DetailAxis.panelOrder.map { session.edit.detailSettings.position($0, in: leica) },
                       [0, 50, 0, 50],
                       "Leica 基线是 0/50/0/50 —— 不是全 0（0 会关掉 Apple 的色彩降噪）")
        XCTAssertNotEqual(DetailAxis.panelOrder.map { session.edit.detailSettings.position($0, in: leica) },
                          [0, 0, 0, 0],
                          "反证：整组复位写成全 0 会让这条红")
        XCTAssertEqual(session.edit.decodeInputs.key, asShotKey,
                       "回到基线 = 回到未碰过面板的那份解码输入（会重新 develop）")
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, InspectorView.Section.detail.title)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.detailSettings.position(.colorNR, in: leica), 80)
        print("细节 reset: 20/80/30/70 → \(DetailAxis.panelOrder.map { session.edit.detailSettings.position($0, in: .measured) })")
    }

    /// R5 的基线不同（锐化 100）：复位不是写死 50 的证据。
    func testTheDetailResetFollowsTheBodyNotAConstant() {
        let r5 = DetailBaseline(luminanceNR: 0, colorNR: 0.5, sharpness: 1, detail: 0)
        XCTAssertEqual(DetailAxis.panelOrder.map { DetailSettings.identity.position($0, in: r5) },
                       [0, 50, 0, 100],
                       "a reset that wrote 50 would be wrong on this body")
        XCTAssertNotEqual(DetailAxis.sharpness.defaultPosition(in: r5),
                          DetailAxis.sharpness.defaultPosition(in: .measured))
    }

    // MARK: - 5. Color

    func testTheColorGroupResetIsOneSnapshot() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            model.color.vibrance = -40
            model.color.saturation = 60
        }
        XCTAssertTrue(session.commitEdit(label: "饱和"))
        let before = session.history.count

        XCTAssertTrue(resets.group(.color))
        XCTAssertEqual(session.edit.color, ColorGroup.identity)
        XCTAssertEqual(session.edit.color.vibrance, EditModel.neutral.color.vibrance)
        XCTAssertEqual(session.edit.color.saturation, EditModel.neutral.color.saturation)
        XCTAssertEqual(session.history.count, before + 1)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.color.vibrance, -40)
        XCTAssertEqual(session.edit.color.saturation, 60)
    }

    // MARK: - 5b. HSL (076)

    /// Double-clicking the **HSL card's title** takes all 24 band numbers back to 0 in **one** snapshot,
    /// and ⌘Z restores every one of them.
    func testTheHSLCardResetsAllTwentyFourBandsInOneSnapshot() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            for i in 0..<ColorGroup.bandCount {
                model.color.bands[i] = HSLBand(hue: Double(i * 3 - 10), saturation: 20,
                                               luminance: Double(-i))
            }
            model.color.vibrance = 25          // another card's field: it must survive
        }
        XCTAssertTrue(session.commitEdit(label: "HSL"))
        let before = session.history.count

        XCTAssertTrue(resets.hsl())
        XCTAssertEqual(session.edit.color.bands, ColorGroup.identityBands)
        XCTAssertEqual(session.edit.color.vibrance, 25, "the HSL card does not own vibrance")
        XCTAssertEqual(session.history.count, before + 1, "one edit action, one snapshot")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.color.bands[7].luminance, -7)
        XCTAssertEqual(session.edit.color.bands[0].hue, -10)
    }

    /// Double-clicking **one row** of the HSL card takes that one field of that one band back to 0 —
    /// the band the panel is showing, not band 0, and not the other two axes.
    func testOneHSLRowResetsOnlyThatBandAndThatAxis() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { $0.color.bands[5] = HSLBand(hue: 30, saturation: -40, luminance: 12) }
        XCTAssertTrue(session.commitEdit(label: "HSL row"))

        XCTAssertTrue(resets.hslField(5, .saturation))
        XCTAssertEqual(session.edit.color.bands[5], HSLBand(hue: 30, saturation: 0, luminance: 12))
        XCTAssertEqual(session.edit.color.bands, ColorGroup.identityBands.enumerated().map { i, b in
            i == 5 ? HSLBand(hue: 30, saturation: 0, luminance: 12) : b
        })
        // Nothing left to do on that row → no snapshot.
        XCTAssertFalse(resets.hslField(5, .saturation))
        // A band and an axis that hold nothing, and an index that does not exist.
        XCTAssertFalse(resets.hslField(4, .hue))
        XCTAssertFalse(resets.hslField(99, .hue))
        print("HSL ROW RESET · band 5 = " + session.edit.color.bands[5].keyString
              + " · history \(session.history.count)")
    }

    /// The **card** reset is wired to the title, like the other parameter cards (047's contract).
    /// 125: the assertion is the verb's behaviour, not a source line.
    func testTheHSLCardCanBeResetFromItsTitle() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        XCTAssertFalse(resets.hsl(), "a fresh document has no bands to reset")

        session.applyEdit { $0.color.bands[2] = HSLBand(hue: 11, saturation: 22, luminance: 33) }
        XCTAssertTrue(session.commitEdit(label: "HSL"))
        session.applyEdit { $0.color.bands[5] = HSLBand(hue: -4, saturation: -5, luminance: -6) }

        XCTAssertTrue(resets.hsl(), "双击标题 = 整卡复位")
        XCTAssertEqual(session.edit.color.bands, ColorGroup.identityBands)
    }

    // MARK: - 5c. 黑白 (S3.4, 2026-10-28)

    /// The switch is **one** command: press it, one row; press it twice, two rows. It must not fold
    /// into the drag before it (`coalesce: false`), and it must not touch the eight mixes — that is
    /// what makes 「关掉置灰、不归零」 possible at all.
    func testTheSwitchIsOneSnapshotAndLeavesTheMixesAlone() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit {
            $0.color.bands[0].mix = 40
            $0.color.bands[3].mix = -20
        }
        XCTAssertTrue(session.commitEdit(label: "黑白混合"))
        let before = session.history.count

        XCTAssertTrue(resets.blackAndWhite(true), "开 = 一条")
        XCTAssertEqual(session.edit.color.blackAndWhite, true)
        XCTAssertEqual(session.edit.color.bands[0].mix, 40, "开关不动混合值")
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "黑白")
        XCTAssertFalse(resets.blackAndWhite(true), "已经是开：不许写空快照")

        XCTAssertTrue(resets.blackAndWhite(false), "关 = 一条，且不折进上一行")
        XCTAssertEqual(session.history.count, before + 2, "开 → 关 是两行，不是一行")
        XCTAssertEqual(session.edit.color.bands[0].mix, 40, "关掉之后值还在")
        XCTAssertEqual(session.edit.color.bands[3].mix, -20)

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.color.blackAndWhite, true, "⌘Z 只撤回开关这一下")
        print("BW SWITCH · 开/关 = 2 条 · 混合 40/−20 原封不动 · history \(session.history.count)")
    }

    /// Double-click on one 黑白混合 row's name: that band's mix back to 0, one snapshot, and the other
    /// seven bands + the switch + the three HSL axes are untouched.
    func testOneBlackAndWhiteRowResetsOnlyThatBand() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            model.color.blackAndWhite = true
            for i in 0..<ColorGroup.bandCount { model.color.bands[i].mix = Double((i + 1) * 10) }
            model.color.bands[2].hue = 25          // another card's field: it must survive
        }
        XCTAssertTrue(session.commitEdit(label: "黑白混合"))
        let before = session.history.count

        XCTAssertTrue(resets.blackAndWhiteField(4), "绿（band 4）双击复位 = 一条")
        XCTAssertEqual(session.edit.color.bands[4].mix, 0)
        XCTAssertEqual(session.history.count, before + 1)
        XCTAssertEqual(session.history.currentSnapshot?.label, "青", "撤销标签是行自己的名字")
        // Everything else is where it was.
        XCTAssertEqual(session.edit.color.bands.map(\.mix), [10, 20, 30, 40, 0, 60, 70, 80])
        XCTAssertEqual(session.edit.color.bands[2].hue, 25)
        XCTAssertEqual(session.edit.color.blackAndWhite, true)

        XCTAssertFalse(resets.blackAndWhiteField(4), "已经是 0：不写")
        XCTAssertFalse(resets.blackAndWhiteField(99), "没有这个色带：不写")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.color.bands[4].mix, 50, "⌘Z 把那个色带带回来")
        print("BW ROW RESET · band 4 → 0 · 其余 " + session.edit.color.bands.map(\.mix).description)
    }

    /// Double-click on 「黑白」: the card's own two things in **one** snapshot — the switch off and all
    /// eight mixes to 0 — while Color's and HSL's numbers stay (they are other cards' work).
    func testTheBlackAndWhiteCardResetsTheSwitchAndAllEightMixesInOneSnapshot() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        session.applyEdit { model in
            model.color.blackAndWhite = true
            for i in 0..<ColorGroup.bandCount { model.color.bands[i].mix = Double(i * 5 - 10) }
            model.color.vibrance = 30            // Color's
            model.color.bands[1].hue = 12        // HSL's, on the same band
        }
        XCTAssertTrue(session.commitEdit(label: "黑白"))
        let before = session.history.count

        XCTAssertTrue(resets.group(.blackAndWhite))
        XCTAssertEqual(session.edit.color.blackAndWhite, false, "复位 = 关")
        XCTAssertEqual(session.edit.color.bands.map(\.mix), Array(repeating: 0, count: 8), "八个混合归零")
        XCTAssertEqual(session.edit.color.vibrance, 30, "Color 的数字不归这张卡")
        XCTAssertEqual(session.edit.color.bands[1].hue, 12, "HSL 的色相不归这张卡")
        XCTAssertEqual(session.history.count, before + 1, "整卡 = 一条")

        XCTAssertFalse(resets.group(.blackAndWhite), "已经是默认就不许再写一条")

        XCTAssertTrue(session.undo())
        XCTAssertEqual(session.edit.color.blackAndWhite, true)
        XCTAssertEqual(session.edit.color.bands[7].mix, 25, "⌘Z 一步把开关和八个数全带回来")
        print("BW CARD RESET · 开关 + 8 混合 → 1 条 · vibrance/hue 不动")
    }

    // MARK: - 6. 没有变化就不写历史

    func testAResetOnAnAlreadyDefaultPanelWritesNothing() {
        let session = CatalogSession()
        let resets = PanelResets(session: session)
        XCTAssertEqual(session.history.count, 0, "a fresh session starts with no snapshots")

        XCTAssertFalse(resets.field(\.light.exposure, label: "曝光"))
        XCTAssertFalse(resets.group(.light))
        XCTAssertFalse(resets.group(.color))
        XCTAssertFalse(resets.group(.detail))
        XCTAssertFalse(resets.group(.whiteBalance))
        XCTAssertFalse(resets.detail(.colorNR))
        XCTAssertFalse(resets.whiteBalanceField(isTemperature: true))
        // 076: the HSL card and its three rows, on a document that has no bands.
        XCTAssertFalse(resets.hsl())
        XCTAssertFalse(resets.hslField(0, .hue))
        // 2026-10-28: 黑白 — the switch (already off), the eight rows (already 0), and the card.
        XCTAssertFalse(resets.blackAndWhite(false), "已经是关：不许写空快照")
        XCTAssertFalse(resets.blackAndWhiteField(0))
        XCTAssertFalse(resets.group(.blackAndWhite))
        XCTAssertEqual(session.history.count, 0, "空双击不该长出一条空快照")
    }

    // MARK: - 7. 每张参数卡都能从标题复位（规格即接线）

    /// 125: a card's reset is its spec — the title verb and the row table are the same value, so
    /// 「这张卡复位哪些字段」 cannot drift from 「这张卡画哪些行」.
    ///
    /// The old source-string assertions are gone: they pinned a particular `ForEach` line, not the
    /// behaviour, and they were exactly what made moving a row比改表更难.
    func testEveryToneCardHasOneSpecAndOneResetGroup() {
        let specs = InspectorView.PanelCardSpec.all
        XCTAssertEqual(specs.map(\.section), [.light, .color, .correction, .effects])
        XCTAssertEqual(specs.map(\.group.rawValue), ["light", "color", "correction", "effects"],
                       "one spec card per tone group, in panel order")
        XCTAssertEqual(Set(specs.map(\.group)).count, specs.count, "no group is claimed by two cards")

        for spec in specs {
            XCTAssertFalse(spec.rows.isEmpty, "\(spec.section) 的 spec 不能是空表")
            XCTAssertEqual(spec.rows.map(\.keyPath), spec.keyPaths)
            XCTAssertEqual(Set(spec.rows.map(\.title)).count, spec.rows.count,
                           "\(spec.section) 的 spec 不能重复声明同一行")
            XCTAssertEqual(PanelResets.Group.allCases.filter { $0 == spec.group }, [spec.group],
                           "the card's group must be in the public enum (undo label + title dispatch)")
            XCTAssertTrue(InspectorView.cardTitles(in: .adjust).contains(spec.section.title),
                          "\(spec.section.title) 必须真的在调整工作区里")
        }

        // The group list itself is still the eight cards 047 + 2026-10-28 built.
        XCTAssertEqual(PanelResets.Group.allCases.map(\.rawValue),
                       ["whiteBalance", "light", "color", "blackAndWhite", "detail", "correction",
                        "effects", "colorGrading"])
    }

    // MARK: - helpers

    /// The white-balance defaults, named so the assertion above reads as the rule: as shot is `nil`.
    private enum SessionDefaults {
        static let temperature = EditModel.neutral.light.temperature
        static let tint = EditModel.neutral.light.tint
    }
}
