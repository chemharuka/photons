import AppKit

// MARK: - 392 · 「HDR 合成」 的居中卡片
//
// 用户第三轮原话（2026-11-12，**最终口径**）：
//
//   「HDR 合成的中心提示卡继续做，但**不需要做曝光指示了**，需要三行：**HDR 合成、张数、时间**」
//
// 所以卡片就是这三行，没有别的：
//
//     HDR 合成        ← 标题，字体更大（15 pt semibold，见 `ProgressCardOverlay.titleFont`）
//     3 张            ← 参与这一次合成的张数
//     0:34            ← 已用时间，分:秒（分钟不补零、秒两位、**不转小时**）
//
// 前两版要求过的「曝光差距」行（ISO / 光圈 / 快门 → EV）与「左标签 + 值居中」的版式**已作废**，
// 一行都没有实现 —— `lines(frameCount:elapsed:)` 的返回值长度会被 ① 逐字比对，多一行就是红。
//
// 尺寸 / 8 pt 夹取 / 分:秒算术 / 绘制**全部**来自 `ProgressCardOverlay`（387 的那一份）：本文件
// 只贡献三个字符串。这是用户 「继续做」 的意思 —— 不是再抄一份会漂移的算术。
final class HDRMergeProgressOverlay: ProgressCardOverlay {

    /// 第 1 行的字面量。① 断言的是这个字符串本身，不是「第一行有点像标题」。
    static let title = "HDR 合成"

    /// 参与张数。`0` 只在「还没拿到张数」时出现（合成尚未开始的静止态根本不会画卡片），
    /// 所以这里不编造一个最小 1 张之类的数字。
    static func frameText(_ count: Int) -> String {
        "\(max(0, count)) 张"
    }

    /// 三行，顺序固定：标题 / 张数 / 时间。绘制与验收读同一个函数，顺序不可能漂。
    static func lines(frameCount: Int, elapsed: Double) -> [String] {
        [title, frameText(frameCount), elapsedText(elapsed)]
    }
}
