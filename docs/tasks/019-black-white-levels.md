# 019 — 黑点/白点改成「线性黑电平 / 白电平」（S1 域）

状态：**已定方向（用户 2026-10-26 拍板）**，规格待实现。

## 1. 问题（用户实测描述）

> 曝光调节优先于黑点白点，RAW 解出来有负像素；如果曝光优先于黑点，就会曝光越大、暗部越黑。

代码事实（`main` @ `fc49488`）：

| 阶段 | 现在的运算 | 性质 |
|---|---|---|
| S1 `s1_scene_linear.metal` L27 | `v = rgb * gain * wb` | **乘性**，负数被同比放大（−0.01 → −0.03 @ +1.6 EV） |
| S2 `s2_tone_map.metal` L65–67 | `blk = -blacks/100*0.15`；`v = (v - blk)/max(wht-blk, 1e-3)` | **仿射**，偏移量 `blk` 是绝对值、与 `gain` 无关 |

两者叠加即：曝光 ↑ → 同一像素更负 → 而抬升量 `|blk|` 不变 → 原本被 `blacks +` 抬到 0 以上的
细节重新落回 0 以下，被 S2 末尾的 `max(v,0)` 夹掉 ⇒ **曝光越大暗部越黑**（细节不是变暗，是被删）。
实测起点（`_1274394.dng`，交接 §3）：min −0.039、33 M 负样本。

## 2. 定案

**黑点/白点是线性空间的电平（黑电平 / 白电平），归 S1；曲线 + 色阶是正常调色，归 S2/S3。
两者不冲突：电平是「0 点和 1 点在哪」，曲线是「0…1 之间怎么弯」。**

S1 内的顺序（新）：

```
v = (v − blk) / max(wht − blk, 1e−3)     // ① 线性电平归一化（仿射，保符号，不夹断）
v = v * gain * wb                        // ② 曝光增益（乘性）
v = highlightRecovery(v)                 // ③ 高光肩（原有，不动）
```

滑杆映射保持不变（`blk = -blacks/100*0.15`，`wht = 1 - whites/100*0.15`），所以手感数值不变。

为什么这样就对了：电平归一化在增益**之前**，于是增益作用在「相对黑点的亮度」上，
**同一像素在黑点之上/之下的归属不随曝光改变**；`blacks +` 抬起来的细节不会被曝光吃掉。
（等价写法是 `(v − B)·g`：先减去黑点再乘增益，符号天然保持。）

S2 里删掉 blacks/whites 的 remap，只保留：`contrast`（pivot 0.18，保符号幂，不动）、
`highlights`/`shadows` 区域加权抬升（不动）、末尾 `max(v,0)` 夹断（不动）。
S3 的 `s3_curve`（曲线）+ 未来的色阶面板不受影响 —— 那才是「正常调色」的位置。

## 3. 必须处理的三个细节（漏一个就会出回归）

1. **matte 会被 S1 抬亮**。S1 dispatch 的是整个 canvas，S0 把画布外的像素写成 0。
   以前是 S2 的 `blk` 把 0 映射成 `(0−blk)/(wht−blk) > 0`，用 `alpha == 0` + content-rect 两道守卫
   挡住（`MatteIsNotPartOfThePictureTests` 钉着）。电平搬到 S1 后，**这两道守卫必须一起搬到 S1**，
   否则 letterbox 立刻变灰。
2. **identity 快路径**。S1 现在 `identity = exposure == 0 && highlightRecovery <= 0`，
   要加上 `blacks == 0 && whites == 0`；S2 的 identity 要**去掉** blacks/whites。
3. **缓存键与组级脏标记**。`EditModel.changedStages`：blacks/whites 从 `.toneMap` 挪到
   `.sceneLinear`（因为线性缓冲本身变了）。`EditModel.keyMaterial(.sceneLinear)` 要加
   blacks/whites，`.toneMap` 要删掉。注意 `MaskTests` 里有钉住的 key 向量 —— 如果它因此变化，
   **说明变化来源是 key material 内容迁移，要在测试注释里写明；mask 相关的不变性判据一个字都不许改。**

## 4. 验收（子代理自己跑，`make verify` 由主线跑）

```bash
cd <自己的 worktree>
PHOTONS_TEST_RAW=/Users/luyao/Desktop/test/L1030433.dng \
  swift test --filter BwLevels      # 新增测试
PHOTONS_TEST_RAW=/Users/luyao/Desktop/test/L1030433.dng \
  swift test --filter ToneMap       # 现有方向/单调断言必须继续绿
PHOTONS_TEST_RAW=/Users/luyao/Desktop/test/L1030433.dng \
  swift test --filter Matte         # matte 不被抬亮
```

新增测试（`Tests/PhotonsCoreTests/BwLevelsTests.swift`，名字里含 `BwLevels`）至少要有：

| 判据 | 内容 |
|---|---|
| 曝光不再吃掉 blacks 抬起的细节 | 合成缓冲 `v = −0.01`，`blacks = +10`（blk = −0.015）：`exposure = 0 / +1 / +2` 三档输出**都 > 0 且随曝光不减** |
| 单调性（新判据，最关键） | 固定 `blacks ∈ {+50}`、`whites ∈ {0}`，曝光从 −2 到 +2 EV 扫描，**任一像素输出单调不减**（用真实 RAW 的一小块 + 合成负数块各跑一次） |
| 归属不变 | 取 `v < blk` 与 `v > blk` 两个样本，任意曝光下两者的「在上/在下」关系不变 |
| 恒等 | `blacks = whites = exposure = 0` → 像素逐字节不变（沿用现有 identity 口径） |
| 方向 | `blacks +100` 六级阶梯分开（沿用 008 的判据）；`whites ±` 方向不变 |

允许更新的既有测试：只有「因为 blacks/whites 从 S2 搬到 S1 而必然改变」的断言（比如「改 blacks 只脏
`.toneMap`」这类组级断言，改成 `.sceneLinear`），每处都要在注释里写明原因。
**不许**为了让测试变绿而放宽容差、改 golden 数值、或跳过用例。

## 5. 边界

- 只动：`Kernels/s1_scene_linear.metal`、`Kernels/s2_tone_map.metal`、`RenderGraph.swift`（S1/S2 参数体与 identity）、`EditModel.swift`（`changedStages` / `keyMaterial`）、新增与上述迁移直接相关的测试。
- 不动：S0/S3/S4、mask 阶段、缓存链结构、`RenderOptions`、任何 UI 文件。
- 不跑 `make verify`、不 `git commit`、不开新分支（在主线给的 worktree 里改，让主线验收）。
