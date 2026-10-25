# 005 — M4：局部蒙版（Local Masks）

> 定稿 2026-10-25。前置：M1 `RenderGraph`（5 段 / 6 环键链，`make verify` 绿）。
> 依据：`architecture-decisions.md` D5/D6/D9/D10/D11/D12 + §11.4；`tasks/002-editing-graph.md`；
> `local/research/SYNTHESIS.md`（D11）、`rawtherapee-art.md`（Mask 乘积 + `ipspot.cc:686`）、`rapidraw.md`（参数化蒙版 + 分辨率键）、
> `darktable.md`（`masks_history`/blend-if）、`lightcraft-product.md` §5.5（LR 蒙版 UI）、`apple-raw-stack.md`（语义 matte 实测）。本文只写设计与判据。

## 1. 范围

| # | 做 | 参数形状 |
|---|---|---|
| 1 | Brush | 折线胶囊链 + 距离场软笔刷，可 erase |
| 2 | Linear Gradient | 两条直线 + midpoint，解析求值 |
| 3 | Radial Gradient | 椭圆 + 旋转 + feather，解析求值 |
| 4 | Color Range | ≤8 采样色 + tolerance + smoothness（OKLab 距离） |
| 5 | Luminance Range | lo/hi + 双侧 feather（OKLab L） |
| 6 | 组合 | 每 Mask 多 component，op ∈ add/subtract/intersect，component 级 invert |
| 7 | 局部调整 | exposure/WB/contrast/highlights/shadows/whites/blacks/hue/saturation + Amount |
| 8 | 语义（**能力验证级**） | `systemMatte`（CIRAWFilter 6 个 matte）、`visionForeground` |

不做：**不训练、不分发任何分割模型**（拿不到就禁用并写明原因，不静默降级）；局部 texture/clarity/dehaze（需额外邻域算子与自己的阶段）、局部 sharpness/NR/moire/defringe（属解码侧 M1-10 或 RAW 域）、局部曲线（LR 也没有）、AI object/text、depth range；
XMP `crs:` 映射（§7）、蒙版 UI 交互细节、linked mask 的 UI（数据与闭包留位并单测，§3.4）。

## 2. 数据模型

`EditModel.masks` 已存在（M1 占位 `params: [String: Double]`）。M4 换成下列形状，**`schemaVersion` 1→2**；
老 `params` 直接丢弃（未发布，无迁移负担），decode 对缺字段/多字段宽容（沿用 `c.val(_:_:)` 显式默认值，D9）。

```swift
public struct Mask: Codable, Sendable, Equatable, Identifiable {
    public var id: String          // "m-<uuid>"，稳定，进缓存键
    public var name: String        // "Mask 1"，用户可改；**不参与任何键**
    public var isEnabled: Bool     // true
    public var opacity: Double     // 1.0；组合后的整体倍率
    public var invert: Bool        // false；组合后取 1-a
    public var feather: Double     // 0.0；短边归一（0…0.1），组合后的空间模糊
    public var refine: Double      // 0.0；0…1，guided filter 强度（0 = 关）
    public var components: [MaskComponent]    // 顺序即组合顺序；空 = 无选区
    public var adjustments: LocalAdjustments  // 只影响 apply，不影响选区（§3.2）
}
public struct MaskComponent: Codable, Sendable, Equatable {
    public var id: String
    public var op: CombineOp       // .add；第一个 component 的 op 被忽略
    public var invert: Bool        // false
    public var feather: Double     // 0.5；形状自身过渡宽度（短边归一）
    public var shape: MaskShape
}
public enum CombineOp: String, Codable, Sendable { case add, subtract, intersect }
```

`MaskShape` 是 tagged union（手写 `Codable`，`kind` 判别；未知 kind 走 `unsupported(kind:payload:)`，**保留字节 + `isEnabled=false`**，round-trip 不丢数据）：

| kind | 字段（括号为默认） |
|---|---|
| `brush` | `size`(0.06 短边) · `strokes: [Stroke]` |
| `linearGradient` | `start`([0.5,0]) · `end`([0.5,1]) · `midpoint`(0.5，0.02…0.98) |
| `radialGradient` | `center`([0.5,0.5]) · `radius`([0.25,0.25]，按 w/h 归一等比) · `angle`(0) |
| `colorRange` | `samples: [[Double]]`（sRGB 0…1，≤8） · `tolerance`(0.30) · `smoothness`(0.50) |
| `luminanceRange` | `low`(0) · `high`(1) · `lowFeather`(0.10) · `highFeather`(0.10) |
| `semantic` | `kind`(sky/foreground/person/skin/hair) · `provider`(systemMatte/visionForeground) · `softEdge`(0.20) · `rasterDigest`(String?) |
| `unsupported` | `kind: String` + `payload: JSONValue` |

```swift
public struct Stroke: Codable, Sendable, Equatable {
    public var points: [Float]    // flat [x0,y0,x1,y1,…]，归一化到**未裁剪原图**（§7 几何）
    public var pressure: [Float]  // 空 = 无压感；非空与 points 等长，只影响 radius
    public var radius: Double     // 短边比例，随 size 缩放
    public var feather: Double    // 0…1，硬芯 = 1-feather
    public var flow: Double       // 0…1，整笔 alpha 倍率
    public var erase: Bool        // false
}
public struct LocalAdjustments: Codable, Sendable, Equatable {
    public var amount: Double     // 0…100，默认 100（整体 lerp）
    public var exposure: Double   // −4…4 EV
    public var temperature: Double, tint: Double      // −100…100，复用 M1-7 的 Planckian 近似
    public var contrast: Double, highlights: Double, shadows: Double
    public var whites: Double, blacks: Double          // −100…100
    public var hue: Double, saturation: Double         // −100…100
}
```

**存参数不存像素**：没有字段保存位图。语义蒙版只存意图 + `rasterDigest`（生成结果的 SHA-256，用于发现"OS 换了模型"），位图进磁盘缓存不进 `develop_json`（RapidRAW 把 base64 PNG 塞 sidecar 是反例）。
坐标量化 1e-5（60MP ≈ 0.6 px），落盘前跑 Ramer–Douglas–Peucker（ε = 0.5 px 折算归一化）；
硬判据：3 笔 × 300 点的 fixture，`EditModel` JSON ≤ 256 KB（005a 单测）。

**键材质分两段**（整个设计的支点）：

```
selectionKey(mask) = kind|components[op,invert,feather,shape…]|invert|opacity|feather|refine|isEnabled
applyKey(mask)     = adjustments.*|isEnabled
```

按 `id` 字典序拼接（跨进程一致，D6），`name` 不在任何键里。

## 3. 渲染契约

### 3.1 决策：不是 S3 的子通道，而是"S1.5 双段"

| 候选 | 结论 | 理由 |
|---|---|---|
| A. S1.5 双段（atlas + apply 各一段） | **取这个** | 谓词域唯一，失败面最小 |
| B. S3 子通道（S1/S2/S3 各自采样蒙版） | 否 | 谓词要在 3 个 kernel 各写一遍 → 三份实现必然漂移；同一 Mask 在 S1 与 S3 因输入不同而选出不同像素（局部 −1EV 后"高光"不再高光），表现为"局部饱和度漏到选区外" |
| C. 只为 mask 生成一段、apply 散在 S1/S2/S3 | 否 | apply 散开就回到 B；且 S2/S3 kernel 与键都要改，golden 全红 |

```
decode → S0 geometry → S1 scene-linear → S1.5 mask-atlas → S1.6 local → S2 tone → S3 curve/color/vignette → S4 display
```

- **S1.5 `mask-atlas`**：输入 = S1 输出的线性画布；输出 = `texture2d_array`（每 Mask 一层，R8Unorm 或 R16F），
  内容 = `opacity · combine(components) · invert`，可选 guided refine。它同时是 `showMask` 叠加的数据源（一个实现两个出口）。
- **S1.6 `local`**：逐像素读 atlas 各层，施加该 Mask 的 `LocalAdjustments`；**点态**，只读本像素 → 可 tile 化（§3.4）。
  输出仍是线性无上界，交给 S2。

apply 必须在 S2 之前：局部 exposure/WB 是场景线性域的增益；放到 S2 之后就是对已被 tone curve 压过的数据做增益，高光被压平就回不来（§11.8 同类错误）。谓词必须在 S1 **之后**：predicate 要看到"全局曝光已生效的画面"，否则拖曝光时亮度范围蒙版的质心会漂。代价：**拖曝光会重建 atlas（+0.5–0.9 ms/帧，估算待测）**。
若实测超预算，唯一允许的开关是 `MaskPredicateDomain { .linearS1 (默认), .geometry }`（后者 atlas 只随 geoKey 变，范围蒙版不再跟随全局曝光）；两条路径各存一份 golden，不做静默切换。

### 3.2 键链：空蒙版必须逐字节等价

`RenderStage` 插入两例（`maskAtlas = "s1.5-mask-atlas"`、`localApply = "s1.6-local"`，位于 `sceneLinear` 与 `toneMap` 之间），`StageKeys` 加两字段，链条变 9 环：

```
geo → lin → maskAtlas → localApply → preNR → curve → color → vignette → display
maskAtlasKey = H(linKey | "masks" | selectionKey(所有 enabled，id 排序) | canvas)
localKey     = H(maskAtlasKey | "local" | applyKey(所有 enabled，id 排序))
```

**`masks` 为空时这两个环整段省略**（`preNR = H(linKey, toneMaterial)`，与 M1 完全一致）。这是"固定链"的显式例外，理由可证：005a 存一份 M1 键向量 fixture，断言空蒙版下 7 个旧键 hash 逐字节相同、非空时 9 环都变。
不省略就要重录全部 golden 与磁盘缓存，且从此无法证明"加蒙版没改到无蒙版路径"。

`changedStages(from:)` 差分：`components/invert/opacity/feather/refine/isEnabled` → `.maskAtlas`；
`adjustments` → `.localApply`；`name` → 空集；空→非空 → 两段都脏；geometry 变则 geoKey 变、链条自然全脏。

### 3.3 不变量

1. **谓词只读本段输入，永不读输出** → 无不动点迭代、无环、单帧一遍收敛。
2. `masks == []` ⇒ 不执行、不缓存、不分配纹理，trace 无这两段，digest 与 M1 相同。
3. `adjustments` 全 0 或 `amount == 0` ⇒ S1.6 走 `dst = src` 真实分支（M1-6 纪律），half 位精确等于"没有这个 Mask"。
4. 一个 Mask 的 atlas 层只依赖 selection、不依赖自己的 adjustments → 拖 Amount/exposure 不重建 atlas。
5. 局部算子必须点态；引入邻域算子必须登记 `TileDependency{pointwise, neighborhood(r)}`，否则 tile 化静默出错。

### 3.4 补丁级重算（tile + 依赖闭包）——最小可行算法

```
1. bounds(mask) = AABB(所有 component) ⊕ featherRadius ⊕ guidedRadius
   形状 AABB 先过 S0 矩阵（crop+rotate）再取外接矩形（旋转后保守，允许浪费）
2. dirtyRect(stage) = ∪ bounds(m ∈ dirty(stage))
3. tile = 128 px（scale<1）| 256 px（导出）；只对与 dirtyRect 相交的 tile 下发 dispatchThreads，
   目标纹理 loadAction = .load。三道保护：
     · 只对**同 key 的缓存纹理**做部分更新（key 变则整幅重算）
     · 点态算子无 halo；neighborhood(r) 的算子把 dirtyRect 外扩 r（guided refine 的 r = kernelDiameter/2）
     · 导出时 tile 边界按 8 px 对齐，避免 tensor 半像素抖动
4. 依赖闭包：MaskGraph 的边 = producer → consumer（未来 linkedMask / 复合引用 / spot 的源落在别人 target 内）。
   closure(D) = D ∪ descendants(D)，Kahn 拓扑序；成环在 **decode 时**报 mask.cycle 并禁用该 Mask，不在渲染时抛。
   M4 用户可达的 mask 之间没有边（闭包退化为单点），但图与闭包代码存在，用合成 A→B→C 链单测。
```

最强判据（005d）：`--incremental` 与 `--no-incremental` 两次渲染的缓冲 **SHA-256 相等**，不是"看起来一样"。

## 4. 五类蒙版的算法

统一约定：坐标归一化到**未裁剪原图**，距离一律除以 `min(W,H)` → 同一份参数在缩略图/fit/1:1/导出上是同一形状（这是"只存参数"成立的前提）。alpha ∈ [0,1]，float 计算。

**4.1 Brush（光栅路径）**——点到线段距离（IQ 的 2D segment SDF，公开公式自行实现）+ smoothstep：
`d = distToSegment(p,a,b)`，`alpha = 1 − smoothstep(r(1−f), r, d)`。累积：一笔 = 胶囊链，用**一个 render pass、逐段 quad、`MTLBlendOperation.max`** 盖到该层（max 即并集，关节不叠亮斑）；跨笔 paint 用 `add / src=one, dst=oneMinusSrcAlpha`（`a_s + a_d(1−a_s)`），erase 用 `add / src=zero, dst=oneMinusSrcAlpha`（`a_d(1−a_s)`）——两个 blend state，不需要回读。已知限制（写进 UI 提示）：flow 只做整笔倍率，不做同一笔内反复涂抹累积；压感只影响 radius。性能：一次 draw/笔，4.1 Mpx 每笔 ≤ 0.15 ms（估算，005b 实测后写回）。
参考（只读不可抄）：RapidRAW `mask_generation.rs`（AGPL-3.0）、ART `DrawnMask`（GPL-3.0）、darktable BRUSH（GPL-3.0）。

**4.2 Linear Gradient（解析）**——`t = dot(p−start, d)/dot(d,d)`；midpoint m 重映射 `t' = t^(log0.5/log m)`（m=0.5 时恒等）；`alpha = smoothstep(0,1,clamp(t',0,1))`，feather 把窗口收窄为 `[0.5−f/2, 0.5+f/2]`。
来源：GLSL/Perlin 的 `smoothstep`（Hermite 三次，公开数学）；LR 的"三条线"语义见 `lightcraft-product.md` §5.5（产品对照）。

**4.3 Radial Gradient（解析）**——`q = R(−angle)·(p−center)/radius`，`r=|q|`，`alpha = 1 − smoothstep(1−f, 1, r)`；
`feather` 用 component 级 f，`invert` 在组合后统一处理。中心可拖到画外（bounds 钳到画布内）。

**4.4 Color Range（解析 + 空间平滑）**——S1 线性 Rec2020 → sRGB 编码（1 矩阵 + 1 次 `pow`，与采样色同空间，不随 EDR headroom 跳变）→ **OKLab**（Ottosson 2020：2 矩阵 + 3 立方根）；`d = min_i |(L,a,b)−(L,a,b)_i|`（L 归一到 [0,1]，a/b 归一到 [−0.4,0.4]）；`alpha = 1 − smoothstep(tol, tol + smooth·(0.5−tol), d)`。
**两个 smoothness 别混**：①上面的值域软过渡；②LR 的 "Smoothness" 是**空间**平滑 —— 我们实现为 atlas 末尾的 guided filter，由 `refine` 控制；UI 文案必须写清哪个是哪个。来源：CIE 1976 ΔE、OKLab（参考实现 MIT）；
ART `deltaEMask`/LCh 曲线（GPL-3.0，只读）、darktable blend-if 逐通道 range（GPL-3.0，只读）。

**4.5 Luminance Range（解析）**——`L = OKLab L(clamp(linear,0,1))`；
`alpha = smoothstep(low−lowF, low+lowF, L) · (1 − smoothstep(high−highF, high+highF, L))`；`low>high` 校验时交换并记 warning。
Y>1 的 headroom 一律按 1 参与（"数字白"），否则高光取值随解码档位跳变。空间平滑同 4.4。

**4.6 Guided filter（羽化 / 边缘贴合）**——Apple 现成 `MPSImageGuidedFilter`（macOS 10.13.4+）。已核实的 SDK 语义（`MPSImageGuidedFilter.h`）：source 单通道（我们的 mask）、guidance 彩色 RGB（S1 输出）、`encodeRegression` 出 4 通道系数（a 在 RGB、b 在 alpha），`encodeReconstruction` 做 `a·RGB + b`，再乘 `reconstructScale` 加 `reconstructOffset`；
**系数可在低分辨率求、重建时自动上采样**。参数：

```
kernelDiameter = odd(clamp(2·round(max(W,H)/30)+1, 3, 65))    // 半径 = max(W,H)/30，与 ART 同量级
epsilon        = 0.01 · 10^(−2·refine)                        // refine=1 → 1e−3；refine=0 → 整段跳过
regression     : guide/source 下采样到 1/4 边长，preview 允许 MPSKernelOptionsAllowReducedPrecision
reconstruction : 全分辨率，一次 4 乘加
```

性能预期：4.1 Mpx 0.3–0.8 ms（估算，005b 实测写入）；60 MP 导出 8–15 ms（估算），故导出只在 `refine>0` 时做且 regression 严格 1/4。
数学来源：He/Sun/Tang *Guided Image Filtering*（ECCV 2010 / TPAMI 2013），快速版 arXiv:1505.00996 —— Apple 头文件里给的就是这篇。
参考（只读不可抄）：RapidRAW `guided.wgsl`（AGPL-3.0）、darktable `guided_filter.c`（GPL-3.0）、ART `masks.cc` 的调用点（GPL-3.0）。

## 5. 语义蒙版

**5.1 系统能力（实测）**——`CIRAWFilter.h:202–207` 有 6 个只读可空属性：`portraitEffectsMatte`、`semanticSegmentation{Skin,Hair,Glasses,Sky,Teeth}Matte`；**本机两个 DNG 实测全为 nil**（`apple-raw-stack.md` §2/§11），sky matte 只在 Apple 自家 HEIC 出现。故 `systemMatte` 只能"有就用"：能力探测在**打开文件时逐文件**做（不能按机型缓存，§11.3 同坑），结果只进内存（环境事实，不是用户意图）。拿不到 ⇒ 保留 `kind: semantic` + `isEnabled=false` + `unavailableReason`，UI 提示"此文件系统蒙版不可用，可用画笔或颜色范围替代"。

**5.2 Vision 路线**（可用性来自本机 SDK）：`VNGenerateForegroundInstanceMaskRequest`（macOS 14+）→ `foreground`；
`VNGeneratePersonSegmentationRequest`（macOS 12+，三档 qualityLevel）→ `person`；`VNGeneratePersonInstanceMaskRequest`（macOS 14+）→ 多人分层（M5）；**天空没有任何 request**，只走 5.1 或"颜色范围 + 位置"预设，不自研模型。
成本预算 ≤ 120 ms @1024 长边（005e 探针实测后写回真值），只在**创建蒙版时**跑一次、绝不在帧内；结果按 `(assetContentHash, decodeRecipe, provider, osBuild)` 落盘缓存，二次 < 5 ms。输出远小于全幅 → 双线性上采样 + guided refine（guide = S1 输出），`softEdge` 控强度，否则边缘是糊的。

**5.3 许可证与坐标**——Vision/CoreImage 是 OS 框架，不重分发权重，MIT 声明不受影响（与 M0 的 `CIRAWFilter` 同一逻辑）。
任何第三方模型（SAM / Depth-Anything / ViTMatte）**不在 M4**：各自权重许可会破坏"零依赖可上架"，redlamp 已证明那是一条要单独做许可门禁的路（`swift-redlamp.md` §5）。matte 在解码坐标系（S0 之前），映射与 bounds 走同一路径；
`rasterDigest` 在生成时写入，下次重算不同则提示"选区可能已变化"，不静默改图。

## 6. 分步计划（每步以 `make verify` 绿收尾）

| 步 | 目标 | 可执行验收 |
|---|---|---|
| **005a** 模型 | `Mask`/`MaskComponent`/`MaskShape`/`LocalAdjustments` 落成，`schemaVersion=2`，两段键材质，校验器 | ① 每 kind 一个 round-trip fixture 相等；② 未知 kind → disabled 且 re-encode **逐字节**相等；③ `photonsctl maskkey --edit f.json` 两进程 sha 相同；④ 3 笔×300 点 JSON ≤ 256 KB；⑤ **空蒙版下 7 个旧键与 M1 键向量 fixture 逐字节相同**；⑥ 校验单测：id 重复 / samples>8 / radius≤0 / cycle 各一条错误 |
| **005b** atlas | `.maskAtlas` 段 + `s1_5_mask_atlas.metal`（3 形状 + 组合 + invert + opacity + refine）+ `photonsctl maskdump` | ① 线性渐变 t=0/0.5/1 采样在 1/255 内等于解析值；② 径向 `alpha(c)=1`、`alpha(r)=0.5±1/255`、沿半径单调；③ 画笔：胶囊内 ≥0.99、2r 外 =0，覆盖率 = Σ(段长×2r)±5%；④ add/sub/intersect 两个 0.5 蒙版的真值表逐值相等，invert 精确 `1−a`；⑤ 空蒙版 trace 无该段且 neutral digest 等于 M1 golden；⑥ refine 前后 `meanAbs` 变化 >0 且边缘梯度上升（数值判据，不看图） |
| **005c** 局部应用 | `s1_6_local.metal` + 十一个滑杆 + Amount；两段进键链 | ① 全 0 / Amount=0 → 与无该 Mask 位精确相等；② 0.5 中灰 + 圆形蒙版 + 局部 +1EV → 蒙版内 ratio ∈[1.99,2.01]、蒙版外 max\|Δ\| ≤ 1/65536；③ 改 selection → 只跑 maskAtlas/localApply（trace 断言 s0/s1/s2/s3 全 skipped）；④ 只改 adjustments → 重跑 localApply 而 **atlas 命中**；⑤ 只改 name → 全命中不重算；⑥ 两进程 digest 相同；⑦ 3 Mask @4.10 Mpx p95 ≤ 16.7 ms |
| **005d** 补丁重算 | `RectSet` + bounds + tile dispatch（`.load`）+ `MaskGraph` 闭包 + `--trace-regions` | ① 增量 vs 全幅 **SHA-256 相等**（改一笔 / 改滑杆 / 跨 3 tile 三种）；② 合成 A→B→C：脏 A ⇒ 执行序 A,B,C；成环 ⇒ 校验错误且不渲染；③ `--trace-regions` 单笔刷脏面积 < 全幅 25% 且与 bounds 一致（±1 tile）；④ `--no-incremental` 仍逐字节相同 |
| **005e** 语义 + 出口 | systemMatte 探测、Vision foreground、磁盘 raster 缓存、`showMask` 叠加、导出路径 | ① `photonsctl semprobe RAW` 逐文件打印 6 个 matte 可用性并复现"全 nil"；② 不可用时是 `semantic/disabled` + 原因，JSON 合法不抛错；③ 语义 raster 二次调用 < 5 ms；④ 有主体的 fixture：只在蒙版内 +1EV，蒙版外变化 ≤ 3%；⑤ `showMask` 与 atlas 同源（buffer digest 相同）；⑥ 全量 `make verify` |

## 7. 风险

| 风险 | 处理 |
|---|---|
| **许可证** | ART/RawTherapee/darktable = GPL-3.0；RapidRAW = AGPL-3.0；redlamp = MPL-2.0；vkdt 内核 BSD-2 但含 GPL 借用文件。**一律只读**：只取数学/结构/参数语义，不复制源码、不做伪代码级逐行翻译、不搬 shader；可移植的只有 MIT/Apache/BSD 且带声明。M4 不引入一行第三方代码 |
| 内存/带宽 | atlas 每 Mask 一层：60 MP × R8 = 60 MB/层，预览 4.1 Mpx = 4 MB/层。硬上限 **12 个 Mask**（超出 UI 拒绝并说明）；导出 >8 层改 tile 化 atlas（每 4 tile 一组，LRU） |
| 蒙版 × 几何/裁剪 | 坐标存"未裁剪原图"，crop/rotate 只影响 S0 矩阵与 bounds 的 AABB；feather 短边归一 → 换缩放不改形状。测：裁剪后的 atlas 与"先裁剪再建同形状"的 atlas 在重叠区一致（005d 单测） |
| 历史栈粒度 | 一次编辑动作 = 一个快照（D10）。画笔**抬笔才提交**（mouse-up），拖动中只更新内存并走 005d 增量；滑杆同理（`EditEvent` 合并窗 120 ms）。否则 300 点的笔 = 300 个快照 |
| XMP 映射延后 | `crs:MaskGroupBasedCorrections` 是嵌套数组 + 子节点引用，且 `Correction*` 与我们字段非一一对应。M4 只保证字段名稳定 + 默认值显式，映射表与 round-trip 留到 M5，避免把半成品映射写进 codec |
| 语义蒙版随 OS 变 | `rasterDigest` 比对 + 提示；golden 里语义蒙版单列一组，不并入像素基线 |
| 空/中性路径退化 | 005a/005b/005c 各有"空或中性 ⇒ 与 M1 逐字节相同"的断言；任何一条红就是结构改错，不是调参问题 |

## 8. 参考（全部只读；许可证以仓库 `LICENSE` 为准）

| 来源 | 用到什么 | 许可证 |
|---|---|---|
| `local/research/rawtherapee-art.md` | Mask 乘积顺序、guided radius = max(W,H)/30、`ipspot.cc:686` 的补丁级重算 + 依赖闭包 | ART / RawTherapee **GPL-3.0**（报告为原创总结，源码只读） |
| `local/research/rapidraw.md` | 参数化蒙版 + 分辨率键缓存、`MPSImageGuidedFilter` 每图一次、32 层 = 768 MB 的内存教训 | RapidRAW **AGPL-3.0**（另含 Spektrafilm LUT / lensfun 数据 / 模型权重限制） |
| `local/research/darktable.md` | `masks_history` 独立表 + 版本号、blend-if 逐通道 range、每实例自带混合器 | darktable **GPL-3.0** |
| `local/research/ansel-vkdt.md` | 参数三处手工对齐的教训（→ 单一 `Codable` 源头） | vkdt 内核 **BSD-2**、借用文件 **GPL-3.0**；Ansel **GPL-3.0** |
| `local/research/lightcraft-product.md` §5.5 | LR 蒙版 UI 清单、8 类 MaskShape 字段对照、局部滑杆范围 | 研究文档（非源码） |
| `local/research/apple-raw-stack.md` §2/§11 | 6 个 semantic matte + portraitEffectsMatte 在本机 DNG 全 nil | 实测记录 |
| `local/research/swift-redlamp.md` §5 | MPL-2.0 文件级 copyleft 边界、模型许可门禁 | Redlamp **MPL-2.0**（两个 demosaic 文件 **CDDL-1.0**） |
| `local/research/licensing.md` | LibRaw LGPL-2.1/CDDL、Lensfun LGPL-3 + CC BY-SA、Exiv2 GPL —— 本项目仍不引入 | 核查报告 |
| Apple SDK | `MPSImageGuidedFilter.h`（source 单通道 / guidance RGB / 系数 RGBA、macOS 10.13.4+）、`CIRAWFilter.h:202-207`、Vision 3 个 mask request | Apple SDK 许可（不重分发权重） |
| 论文/公开数学 | He/Sun/Tang *Guided Image Filtering*；arXiv:1505.00996；Ottosson *OKLab*（参考实现 MIT）；CIE 1976 ΔE；IQ 2D segment SDF；`smoothstep`；Ramer–Douglas–Peucker 1972 | 公式与事实，不受版权保护 |
