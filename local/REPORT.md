# 173 · 点颜色 — 亮度权重来自 primaries.metal，Y 先行粗筛

分支 `feat/point-color-multi-1030`，worktree `/Users/luyao/photons-wt/point-color-fix`。
只改了允许的四个位置：

| 文件 | 角色 |
|---|---|
| `Sources/PhotonsCore/Kernels/s3_6b_point_colour.metal` | 引入 `primaries.metal`、`point_yuv` 用 `kWorkingLumaWeights`、Y 一次算出后先全 swatch 粗筛 |
| `Sources/PhotonsCore/PointColor.swift` | 只动 YCbCr 一对 helper：`yuv(fromLinearWorking:)` / `linearWorking(from:)` 用同一组权重 |
| `Sources/PhotonsCore/AlgorithmVersion.swift` | `pointColour` 2 → 3，并加 `**3** — 173: …` 说明 |
| `local/REPORT.md` | 本文件 |

`Package.swift`、`Resources/`、其它 kernel、其它 stage、任何 golden 均未触碰。

---

## 1. 改动摘要

### ① 亮度权重改用 `primaries.metal`

**kernel（`s3_6b_point_colour.metal`）**

- 新增 `#include "primaries.metal"`（紧挨 `#include "oklch_bands.metal"`）；
- `point_yuv` 里的 `0.2126 * enc.x + 0.7152 * enc.y + 0.0722 * enc.z`
  → `dot(enc, kWorkingLumaWeights)`；
- 注释保留并写清：这个 Y 是在 **Rec.709 / sRGB 编码后**的三元组上量的，所以三个权重来自
  `primaries.metal`（working primaries），而不是本文件里的字面量；
- 整个文件现在没有非注释行含 `0.2126` / `0.2627` / `0.678`
  （`SaturatedColourTests.testNoKernelCarriesItsOwnLumaWeights` 的 27 个 kernel 全过）。

**host（`PointColor.swift`，仅 YCbCr helper）**

```swift
// yuv(fromLinearWorking:)
let w = ColorPrimaries.working.luminanceWeights
let y = w.x * r + w.y * g + w.z * b

// linearWorking(from:)
let w = ColorPrimaries.working.luminanceWeights
let g = (y - w.x * r - w.z * b) / w.y
```

正反变换用同一组 `w`，所以 `linearWorking(from: yuv(fromLinearWorking:))` 仍精确往返；
`PointColorTests.testTheKernelIsTheCPUReference` 保持 `max |Δcode| 1`
（本次运行打印 `POINT CPU↔GPU · max |Δcode| 1, mean 0.087 over 3240 channels`）。

**版本（`AlgorithmVersion.swift`）**

`StageAlgorithmVersion.pointColour` `2` → `3`，并在原 `**2** — 158: …` 之上加了
`**3** — 173: …` 段：同一个文档、同样的存储参数，Y/U/V 现在按 working primaries 的权重读，
`sampleY` 不再落在同一个像素上，窗口覆盖的邻域会变，所以像素必须变；同时说明 Y-first 粗筛
只是重排、不改像素。

### ② Y-first 早期退出（性能）

改前的每个像素（只要进了 stage）都会无条件跑完：

- 3 个矩阵行 + 3 次 sRGB OETF + Y；
- U/V 两次除法；
- 淡色地板 `length(float2(u−0.5, v−0.5))`；
- `oklab_raw`（2 个矩阵乘 + 3 次 `cbrt`）；
- `atan2` + 角度换算 + 负角回绕；

然后才进 swatch 循环，靠每个 box 的权重去否掉它。

改后：

1. Y 只算一次，算术与 `point_yuv` 的 Y **逐位相同**：三个线性行
   `dot(p.m0.xyz, rgb)` / `m1` / `m2`、三次 `point_srgb_encode`、再
   `dot(enc, kWorkingLumaWeights)`（没有把 Y 简写成 `point_srgb_encode(dot(p.m1.xyz, rgb))`）。
2. 用这个 Y 一次粗筛**全部** swatch：`fabs(y − s.sample.x) <= s.window.x + 0.5·s.window.x·s.window.w`，
   `<=` 故意取闭区间（只会多放进来、不会漏掉有权的像素）；`s.sample.w <= 0.0` 的 swatch 跳过。
   一个都没过 → `dst.write(c, gid); return;`。
3. 只有过了粗筛的像素才算 U/V（复用上面的 `enc`）、跑淡色地板（`< p.b.y` 则写回）、
   再做 `oklab_raw` / `atan2`，随后是**未改动**的逐 swatch 循环；循环里
   `yuvValid == false` 时仍然重算完整 `point_yuv`，和以前完全一样。

**因此每个“落在所有 box 之外”的像素省掉：**

- U/V：2 次除法、2 次加法；
- 淡色地板：2 次减法、2 次乘法、1 次加法、1 次 `sqrt`、1 次比较；
- `oklab_raw`：2 个 3×3 矩阵乘（18 次乘加）+ 3 次 `cbrt`；
- `atan2`、`× 180/π`、`H < 0` 分支；
- 以及为循环准备的 `L` / `C` / `H` 与 (在多数情况下) 一次 `point_yuv` 的完整转换。

**保留的开销**：3 个矩阵行、3 次 OETF、Y 的 `dot`、粗筛最多 8 次 `fabs`/比较。
（OETF 是 `pow`，占大头；这一步不能省，否则 Y 就不是原来的 Y。）

“落在某个 box 内”的像素走完整路径，算术与改前完全一致；这是纯粹的重排，
输出应与改前逐字节相同（除 ① 的权重差以外）。

---

## 2. ① 让哪些像素变了

窗口是在 YUV 上量的，而 Y/U/V 的定义换了权重（U/V 的 1.8556 / 1.5748 矩阵没动），
所以对**彩色**像素：

| 编码 sRGB 基色 | Y（旧 709 权重） | Y（working primaries） | ΔY |
|---|---|---|---|
| 红 (1,0,0) | 0.2126 | 0.2627 | **+0.0501**（+23.57 %） |
| 绿 (0,1,0) | 0.7152 | 0.6780 | **−0.0372**（−5.20 %） |
| 蓝 (0,0,1) | 0.0722 | 0.0593 | **−0.0129**（−17.87 %） |
| 中性灰 (t,t,t) | t | t | 0（三权重和仍是 1） |

U/V 跟着同一个 `y` 走：例如纯红 `V` 由 1.0000 → 0.9682（≈ −8/255），纯蓝 `U` 由 0.5000 →
1.0070；纯红 `U` 0.3854 → 0.3584。也就是彩色像素的 YUV 三元组整体挪动约 0.01–0.05
（≈ 3–12/255），饱和红最大。

具体到画面：

- **只可能变的是“被某个 swatch 的 luma 粗筛放进来、且逐轴权重非零”的彩色像素**：
  它们的 `wy`/`wu`/`wv` 都按新的 YUV 算，权重不同 → 三个滑块的作用量不同 → 输出不同。
- **所有 box 之外的像素逐字节不变**：Y-first 粗筛把它们直接写回（这也是 ② 的加速面）。
- **中性灰/近灰不变**：编码后 `r = g = b` 时三个权重和为 1，`Y` 保持到 1 ulp 内，且
  `U = V = 0.5` 精确成立，仍被淡色地板原样写回（`POINT K3 · grey ramp byte-identical` 仍绿）。
- **窗口相对照片移动**：文档里存的 `sampleY/sampleU/sampleV` 是旧权重下量的；换成
  working primaries 后，存下的 `sampleY` 不再对准原来采样的那个像素（纯红样本的 `V`
  差 ≈ 0.032），所以同一个 box 覆盖的邻域会变——这正是 bump 到 3 的原因。
- 这次运行里所有点颜色测试仍绿，包括 `POINT CPU↔GPU max |Δcode| 1`、
  `POINT HUE 30.09° + 30° → 60.08°`、`POINT K1/K2/K3`，说明 host 与 kernel 用同一组权重，
  采样点仍落在自己 box 的中心（host 参考）。

---

## 3. 验证（仅按指定命令）

```
swift build --build-tests        # Build complete! 0 errors
PHOTONS_TEST_RAW=$HOME/Desktop/test/L1030433.dng \
  swift test --filter 'SaturatedColour|PointColor|ColorGrading|HSL|PresetSnapshot|RenderTests'
```

| suite | 结果 |
|---|---|
| `PointColorTests` | **11 / 0** |
| `SaturatedColourTests` | **7 / 0** |
| `ColorGradingTests` | 25 / 0 |
| `ColorGradingCardTests` | 7 / 0 |
| `HSLTests` | 27 / 0 |
| `HSLPanelTests` | 6 / 0 |
| `PointColorPanelTests` | 12 / 0 |
| `PresetSnapshotTests` | 12 / 0 |
| `RenderTests` | 21 / 0 |
| `LoupeRenderTests` | 6 / 0 |
| `PanelResetTests` | 3 / 0 |
| `LocalColorStageTests` | 0 executed（filter 未选中用例） |

合计 **104 tests / 0 failures**，退出码 0。没有新的红。

关键行：`weights guard: 27 kernels checked, exempt: ["tone_shape.metal"]`、
`kernel weights 0.2627/0.6780/0.0593 == ColorPrimaries.working`。

未运行 `make verify|test|app|ui-smoke`，未跑 `WindowTests` / `LoupeQueueTests`，
没有 `pkill`，没有重录 golden，没有 push/merge。

---

## 4. 司机复核（独立重跑）

- `swift build --build-tests` → `Build complete!`，0 error。
- 独立重跑同一条 filter：`Executed 104 tests, with 0 failures`；
  逐套 `SaturatedColourTests 7/0`、`PointColorTests 11/0`、`HSLTests 27/0`、
  `ColorGradingTests 25/0`、`PresetSnapshotTests 12/0`、`RenderTests 21/0`。
  `SaturatedColourTests` 7 条里含 `testNoKernelCarriesItsOwnLumaWeights` 与
  `testTheKernelWeightsAreColorPrimaries`，即两条 gate 红都翻绿。
- 逐行复核 diff：`count` 的取值、`0.5·d·feather` 的肩宽表达式、`s.sample.w <= 0` 的跳过条件
  与 `point_box_weight`/循环内 `continue` 一一对应；粗筛闭区间只会多放进来，不会漏掉有权像素；
  通过粗筛的像素走的仍是原来的完整路径（含 `yuvValid == false` 时重算 `point_yuv`）。
  **早退没有改变任何像素**：粗筛与淡色地板都只是“写回 `c`”的过滤器，两者的先后互换不影响输出。
- **待主线判定**：`WindowTests.testPanFrameCostDoesNotRegress` 按要求没有跑（时序敏感、主线独占）。
  每像素省掉的项见第 1 节末尾；预期从 7.77 ms 回到 ≈4.7 ms 基线，需主线单独实测。
