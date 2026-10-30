# 167 · 亮度选择扩到 HDR 域 — lane `lum-hdr`

分支 `feat/lum-hdr-1030`，worktree `/Users/luyao/photons-wt/lum-hdr`。
三个 commit：① 引擎 + 迁移 ② 版本 bump + 键链/golden ③ UI 轴与域。

## 1. 改了什么

- `Sources/PhotonsCore/Kernels/s1_5_mask_atlas.metal`
  - `luminance_range_alpha` 去掉 `clamp(linearRGB, 0, 1)`，改为 `oklab(linearRGB).x`。
  - `two_sided_window` 本身没动；深度（kind 6）仍把 `0…1` 归一化距离送进同一个窗口。
  - 文件头的 luma 公式注释同步。
- `Sources/PhotonsCore/Masks.swift`
  - `LuminanceRangeShape.hdrMax = cbrt(16) = 2.5198420997897464`（+4 EV）。引擎与 UI 都读它。
  - `LuminanceRangeShape` 增加编码字段 `v`：新文档 = 2；无 `v` 的旧文档视为 v1。
  - v1 解码迁移：`high == 1.0 ⇒ hdrMax`；`high < 1.0`、`low`、两个 feather 原样。解码后 `v = 2`，
    重新编码即 v2，二次解码不再迁移。
  - `default.high`、`centring` / `movingNearerEdge` 的夹取区间改为 `0…hdrMax`。
  - `OKLabMetric.maskLuminance` 同步去掉通道上方 clamp，吸管可以采到 `L > 1`。
- `Sources/PhotonsCore/AlgorithmVersion.swift`
  - `maskAtlas: 4 → 5`，附 167 的原因。
- `Sources/PhotonsUI/MaskRangeBar.swift`
  - 轴改为 `0…hdrMax`；`value(atX:)`/`xPosition(forValue:)` 互为逆映射。
  - 把手、feather、整体平移全部按新域夹取；最小命中宽度 10 pt 规则不变。
  - 双击复位：`low → 0`，`high → hdrMax`。
  - 底部刻度：SDR `0/63/127/191/255` 在各自 OKLab L；HDR `+1…+4` 在
    `cbrt(2^stop)`。9 pt monospaced、secondary/tertiary 同曲线卡规矩。
  - 数字行仍两位小数，量纲 `0.00…2.52`，没有改 EV 文案。
- `Sources/PhotonsUI/MaskShapeControls.swift` / `MaskParameters.swift`
  - 新建亮度蒙版默认 `high = hdrMax`；`下限/上限` 两行的 range 与写入夹取改为 `0…hdrMax`。
    （派单说默认值在 `init`，但实际新建路径在这里显式写了 `high: 1.0`，不改会让每个新蒙版
    “只选到白点”，并且上限行会把 2.52 夹回 1.0。`MaskSliderRowTests` 的复位用例抓到了这一点。）

## 2. V1 · 扩域生效（逐片 alpha）

合成中性面片：线性 `1, 2, 4, 8, 16` = `0, +1, +2, +3, +4 EV`；组件 feather 与 mask-level
feather 都为 0。`MaskTests.testLuminanceRangeExtendsIntoTheHDRDomain` 输出：

```
HDR V1 · low 1.6 high 2.6 · 0=0.0000 · +1=0.0000 · +2=0.0000 · +3=1.0000 · +4=1.0000
HDR V1 · low 1.55 high 2.6 · 0=0.0000 · +1=0.0000 · +2=1.0000 · +3=1.0000 · +4=1.0000
```

**关于派单的 `+2`：** `+2 EV` 的 OKLab `L = cbrt(4) = 1.587401 < 1.6`，所以题面给的
`low = 1.6, feather = 0` 精确地**不选中** +2（不是取整误差）。为了验证“+2/+3/+4 三片被选中”
的意图，同一用例加了 `low = 1.55` 的窗口，结果如上：+2/+3/+4 = 1，+1/0 = 0。两行都保留在
测试和这里，避免把边界事实藏起来。

## 3. V2 / V3 · 旧文档迁移与逐字节比对

解码断言（`MaskTests.testLuminanceRangeV1DocumentsMigrateOnce`）：

- v1 `{low:0, high:1.0, lowFeather:.10, highFeather:.10}` → `high = 2.5198420997897464`，`v = 2`。
- v1 `{low:0.4, high:0.6, lowFeather:.05, highFeather:.07}` → 五个字段原样，`v = 2`。
- 再编码含 `"v":2`；再解码不变。v2 文档里字面量 `high = 1.0` 不再触发迁移。

逐字节（8-bit 量化 atlas，`MaskTests.testV1DocumentsRenderTheOldSDRSelectionByteForByte`）：

```
MIGRATE V2 old a292bc4a1d8d3caa7dd32d1858f7d642a27373526b84cde7df8634faad708d2a
             new a292bc4a1d8d3caa7dd32d1858f7d642a27373526b84cde7df8634faad708d2a
MIGRATE V3 old ccaab7261a27c4042a83b356970aef12eb6415b6b45df42bb1092ec34c30d27d
             new ccaab7261a27c4042a83b356970aef12eb6415b6b45df42bb1092ec34c30d27d
```

V2 用 flat 0.4（`L = 0.737`），V3 用 0…0.4 的 SDR ramp，都在旧窗口真正解析的 SDR 区内；旧参考
实现保留 `clamp(light, 0, 1)`，与新内核逐像素量化 digest 相等。

**必须记下的一个事实：** 旧 `high = 1.0` 并不是数学上的“白点及以上全选”。旧
`two_sided_window` 的上沿是 `1 − smoothstep(hi−hiF, hi+hiF, L)`，在 `hi = 1, hiF = 0.10`
时 `L ≥ 1` 的 alpha 是 0，`.9…1` 是渐隐。因此“v1 `high = 1.0` → `hdrMax`”对含高光的图
**不可能**和旧内核逐字节相同——那正是 167 要扩出去的 HDR 半边。上面的 V2 证明的是
“旧窗口已经解析的 SDR 区域不变”；`L > 0.9` 的差异是扩域本身（旧 0，新按 `hdrMax` 选择），
不是迁移改坏了旧值。派单里“1.0 就是白点及以上全选”的前提与实际 kernel 的 feather 上沿不符。

## 4. V4 · 深度不受影响

`DepthMaskTests` 5/5 通过（`0…1` 窗口、invert、feather 交换、无深度图零覆盖且画面逐字节等于
无蒙版、depth key 后缀不变）。`two_sided_window` 未改，深度没有接入 `hdrMax`。

## 5. V5 / V6 · 曝光无关性与交换性

`ExposureEquivarianceTests` 全绿：

```
MASK · luma 0.55…1.0 · E−2 vs E0 · IoU 1.0000 · mean|Δcov| 0.0000 · 面积 18.91% vs 18.91%
MASK · luma 0.55…1.0 · E+2 vs E0 · IoU 1.0000 · mean|Δcov| 0.0000 · 面积 18.91% vs 18.91%
COMMUTE · synthetic luma-mask E=-2/E=1/E=2 · max 0.0 ULP · 超限 0
```

（147 修前 IoU 0.196 的那条仍是同一个 mask 谓词；现在谓词读未曝光刻度 `L0`，HDR 扩域没有把
域建到曝光之后。）

`testZeroExposureIsByteIdenticalToThePre147Build` 的 atlas digest 因 167 变了：
引入提交 `b6166e4`（147），old → new
`37b8deb9a4e691b043429ec50673dcac3d63a14d39987f6e99fe5a8ad35b0eae` →
`2b0a593e14b510ca2580e50d4b0ad144d12b77b1d000c9ddbbf04b34134d9eee`。
E = 0 的 g 仍精确为 1；变的是 luma 谓词本身（高光不再折叠到 `L = 1`）。

## 6. V7 · UI

`MaskRangeBarTests` 7/7 通过，含新增三条：

- `0 / 127 / 255 / +2 / +4` 刻度在 `0 / 0.5965 / 1 / 1.5874 / 2.5198`，x = value / hdrMax。
- 拖过右端：`high == 2.5198420997897464`，不越界。
- 双击：`low → 0`、`high → hdrMax`；另一端和 feather 不动。

`MaskSliderRowTests` 10/10、`MaskEyedropperTests` 8/8、`MaskHandleTests` 15/15 通过。
`MaskEyedropperTests` 的两处旧期望更新为 HDR 域：full-range 吸管窗口 `0.775…1.025`
（旧 `0.775…1.0`，因为旧轴到 1 就夹住），`maskLuminance(4)` 现在为 `cbrt(4)`。

全量 `PhotonsUITests` 跑过一次 961 条：2 条失败，其中 `MaskSliderRowTests` 的复位已修复并在
上面定向重跑为绿；另一条 `CropZoomEntryTests` 要求 `PHOTONS_TEST_RAW` 环境变量，属环境缺失，
与本单无关。

## 7. V8 · 色彩

`SaturatedColourTests` 7/7、`WindowTests` 14/14 通过。`MaskTests` 的 brush/colour/gradient 固定
coverage 与 analytic 参考也全绿。

## 8. 版本、键链、golden

- `StageAlgorithmVersion.maskAtlas: 4 → 5`。
- `StageAlgorithmVersion.material` 指纹（19 环）：
  - old `35db0788e618e72b`
  - new `aaf8862386a2c685`
- `WindowTests` / `MaskTests` 的 M1 空蒙版键链**没有重算**：那 9 个 link 里根本没有
  `maskAtlas` / `localApply`（无蒙版时两个 stage 不存在），所以 maskAtlas bump 不会进入它们。
  全文件里也没有带蒙版的固定 key 向量；`CacheVersionTests` 新增 `maskAtlas == 5` 断言。
- 所有 golden 均未重录，old = new（测试实跑通过）：
  - `mask-gradient-s1.0.json`: atlas `4436531f…6ddcf`, display `22e9753a…1111a`
  - `mask-brush-colour-s1.0.json`: atlas `aa15da3b…7c268`, display `c376fd43…35ff2`
  - `mask-feather-refine-s1.0.json`: atlas `d0e77b09…2e327`, display `9c100935…af5603`
  - `mask-show-mask-s1.0.json`: atlas `3a9ec54e…0a3160`
  - `render-edit-neutral-s0.25.json`: `1e191e02…c1da6`
  - `render-edit-crop-rot-s0.25.json`: `a0059a02…96fa6b`
  - `render-edit-push-s0.25.json`: `4c5e3245…b755d`
  - `L1030433-v8-s1.0.json`: hash `38ac10e5…afa1a`（不是像素 golden）
  这些 golden 都不含 `luminanceRange`，167 不改它们的像素。

## 9. 测试命令与结果

- `swift build --build-tests`：通过。
- `.metal` 改后按规则 `rm -rf .build/out/Products/*/*.xctest` 再跑测试。
- `swift test --filter PhotonsCoreTests`：823 条，11 skip，**0 失败**。
- `swift test --filter PhotonsCatalogTests`：194 条，**0 失败**。
- UI 定向套件（RangeBar / Eyedropper / SliderRow / Handle）：**0 失败**。
- 没有使用 `XCTSkip` 代替重钉；只更新了 167 引入后已经陈旧的 E0 atlas digest，并在上面给出
  introducing commit 与 old→new。
