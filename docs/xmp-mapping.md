# XMP 映射：`EditModel` ↔ Lightroom `crs:`

> 依据：`Sources/PhotonsCore/EditModel.swift`（逐字段）、`docs/architecture-decisions.md` D7/D9/§11.5、
> `local/research/lightcraft-product.md` §3.9/§4.3（LR 控件量程与默认值）、
> `local/src/darktable/src/develop/lightroom.c`（GPLv3，**只读**，仅取键名与语义）、
> `local/src/redlamp/docs/...`（MPL，**只读**，仅取 crop/tone curve 的坐标定义）。
> 本文不含任何被参考实现的代码或表结构，只写语义。
> 目标：为"导出 XMP sidecar / 内嵌 XMP"和"一次性导入 LR 目录"立可实现契约。

## 0. 前提与记号

三条硬约束（D7/D9）：

1. **数据库是唯一真相**。`assets.develop_json` 里的 `EditModel` 是唯一输入；XMP 是派生物，写失败不阻断导出。
2. **XMP 只导出，默认不回读**。唯一的读者是显式的"导入 LR 目录/XMP"命令（一次性，落成新快照）。
3. **单一 `schemaVersion`**：XMP 不承担版本迁移，只带 `photons:schemaVersion` 供导入时告警。

等级记号：`≡` 直映射（同量纲同域，往返可精确）｜`≈` 数值域相同但曲线形状不同（往返数值准，渲染不等效）｜
`⚠` 部分可映射（有损或语义偏移，须在导出报告里标注）｜`✕` 不可映射。

两个全局规则，后文表格默认成立：

- **R1 恒等不写键**：等于 `EditModel` 默认值的字段一律不写 `crs:` 键（缺失 = LR 用它的默认值）。
  例外：`crs:Version` / `crs:ProcessVersion` / `crs:WhiteBalance` 必须写（声明兼容性）。
  副作用见 §3.5（Detail 面板两侧默认值不同）。
- **R2 我们自有命名空间**：`https://photons.app/ns/edit/1.0/`（前缀 `photons`）存精确值与 crs 装不下的东西：
  `photons:settings` = base64(zlib(EditModel JSON))、`photons:temperature`、`photons:highlightRecovery`、
  `photons:schemaVersion`、`photons:processVersion`。`crs:` 负责互通，`photons:` 负责无损往返。

## 1. 表 A：`EditModel` → `crs:`

### 1.1 顶层

| 字段 | `crs:` 键 | LR 量程 / 默认 | 转换 | 等级 |
|---|---|---|---|---|
| `schemaVersion` | —（仅 `photons:schemaVersion`） | 无对应概念 | 整数直写私有 ns；`crs:` 不写 | ✕ |
| `processVersion` | `crs:ProcessVersion` | 字符串 `"11.0"`/`"15.4"`，默认 `"15.4"` | 写固定常量 `"15.4"`（≥ Process 2012 才被 LR 采用 `*2012` 键）；**只声明，不参与回读** | ⚠ |
| — | `crs:Version` | 字符串，如 `"18.5.1"`（实测本机 DNG 内的值） | 写编译期常量（目标 ACR 版本），**不要**写 `RawCamera.bundle` 的 `9.51.0`——那是系统解码器版本，与 ACR 无关 | ⚠ |
| — | `crs:WhiteBalance` | `"As Shot"`/`"Custom"`/`"Auto"`/预设名 | 有 as-shot WB 元数据时写 `"Custom"`；否则写 `"As Shot"` | ≡ |

### 1.2 geometry（裁剪 + 拉直 + 翻转）

LR 的坐标定义（参考自 redlamp 的 crop 说明，仅取语义）：`CropLeft/Top/Right/Bottom` 是 **0…1 的分数**，
以**文件存储像素**为参照、原点左上、**在相机 orientation 之前**；`(Left,Top)` 是左上角、`(Right,Bottom)` 是右下角
（所以宽 = Right−Left，不是宽度字段）；裁剪矩形按 `CropAngle` **顺时针**转、绕自己的中心。

| 字段 | `crs:` 键 | LR 量程 / 默认 | 转换 | 等级 |
|---|---|---|---|---|
| `crop.x` | `crs:CropLeft` | 0…1 | 直写，`%.6f` | ≡ |
| `crop.y` | `crs:CropTop` | 0…1 | 直写，`%.6f` | ≡ |
| `crop.width` | `crs:CropRight` | 0…1 | `x + width`（**边界，不是宽度**；darktable 侧同样按 `right−left` 求宽，参考自 lightroom.c 仅取语义） | ≡ |
| `crop.height` | `crs:CropBottom` | 0…1 | `y + height` | ≡ |
| — | `crs:HasCrop` | 布尔，LR 写 `True`/`False` | `crop == .full` → 不写（R1）；否则写 `true` | ⚠ |
| `rotationDegrees` | `crs:CropAngle` | −45…45，默认 0 | **`−rotationDegrees`**。我们让**画面内容**顺时针转，LR 让**裁剪框**顺时针转，两者反向（darktable 亦取负；参考自 lightroom.c 仅取语义）。|≡|
| `flipHorizontal` | `tiff:Orientation` | 1…8 | 与 EXIF orientation 合成成一个 1…8 的值；**非单射**（8 个值里含相机自身方向，4 种翻转组合只能靠 EXIF 参与才可逆） | ⚠ |
| `flipVertical` | `tiff:Orientation` | 同上 | 同上（两者共同决定一个值） | ⚠ |
| — | `crs:CropConstrainToWarp` | 0/1 | 不写。我们的 `NormalizedRect.clamped()` 已保证不越界，"约束到图像"对我们恒真 | ✕ |

### 1.3 light

| 字段 | `crs:` 键 | LR 量程 / 默认 | 转换 | 等级 |
|---|---|---|---|---|
| `exposure` | `crs:Exposure2012` | −5…5 EV，默认 0 | 1:1（同为 EV）。**但我们的是 S1 场景线性增益 `2^EV`**（解码侧 `boostAmount=0`，§11.4），LR 的 EV 在其 2012 管线内、之后还有自己的曲线 → 同 EV 不同图 | ≈ |
| `contrast` | `crs:Contrast2012` | −100…100，默认 0 | 1:1。我们 S2 是解析式（绕 0.18 中灰，M1-8），LR 是它的对比曲线段 | ≈ |
| `highlights` | `crs:Highlights2012` | −100…100 | 1:1 | ≈ |
| `shadows` | `crs:Shadows2012` | −100…100 | 1:1 | ≈ |
| `whites` | `crs:Whites2012` | −100…100 | 1:1 | ≈ |
| `blacks` | `crs:Blacks2012` | −100…100 | 1:1 | ≈ |
| `temperature` | `crs:Temperature` | raw 2000…50000 K（滑块非线性）；默认 = as-shot | **坐标系相同**（派单 006 起）：我们是*绝对*开尔文，`nil` = as shot，显式值直接喂 `CIRAWFilter.neutralTemperature`；LR 也是绝对开尔文、锚在同一个 as-shot 中性（差别只在相机 profile 矩阵）。所以映射就是 `crs:Temperature = temperature ?? N`——旧规则 `N + (temperature − 6500)` 的 `− 6500` 只是用来抵消我们从前那个名义值，现已随模型一起消失。无 `N` 且 as shot → 不写 `crs:Temperature`；显式值则照写 `= temperature` | ≈ |
| `tint` | `crs:Tint` | −150…150，默认 as-shot（**正 = 洋红**，与我们一致） | 同温度：`crs:Tint = tint ?? tint_asShot`（解码器 tint 坐标里 as-shot 本身约 +20，不是 0）。无 `N` 且 as shot 时不写 | ≈ |
| `highlightRecovery` | — | 无对应键 | 我们是 0.8 以上的软肩（S1、线性域）；LR 的 `Highlights2012` 是 tone 段的局部压缩，语义不同。只写 `photons:highlightRecovery` | ✕ |

### 1.4 curve

LR 的 `ToneCurvePV2012` 是 `rdf:Seq` 里每项一个 `"x, y"` **字符串**，两轴都是 **0…255 整数**，x 必须严格递增
（参考自 redlamp 的 curve 说明与 lightroom.c 的取值方式，仅取语义）。LR 每条曲线点数上限约 16。

| 字段 | `crs:` 键 | 量程 / 默认 | 转换 | 等级 |
|---|---|---|---|---|
| `curve.rgb` | `crs:ToneCurvePV2012` + `crs:ToneCurveName2012="Custom"` | 0…255 整数点列 | `x255 = round(x*255)`，`y255 = round(y*255)`，格式 `"%d, %d"`；恒等（`[(0,0),(1,1)]`）→ 不写（R1） | ⚠ 量化 1/255 |
| `curve.red` | `crs:ToneCurvePV2012Red` | 同上 | 同上 | ⚠ |
| `curve.green` | `crs:ToneCurvePV2012Green` | 同上 | 同上 | ⚠ |
| `curve.blue` | `crs:ToneCurvePV2012Blue` | 同上 | 同上 | ⚠ |
| — | `crs:ParametricShadows/Darks/Lights/Highlights` + 三个 `Split` | −100…100；split 10…40/30…70/60…90 | **不写**：我们没有参数曲线（只有点曲线），也无法从点曲线唯一反解出参数曲线+split。导入时这组键无处落脚 | ✕ |

插值方式不同（我们单调三次，LR 是它自己的样条）：**同点列 ≠ 同像素**，只在控制点上严格一致。

### 1.5 color

| 字段 | `crs:` 键 | 量程 / 默认 | 转换 | 等级 |
|---|---|---|---|---|
| `vibrance` | `crs:Vibrance` | −100…100，默认 0 | 1:1 | ≈ |
| `saturation` | `crs:Saturation` | −100…100 | 1:1 | ≈ |
| `bands[i].hue` | `crs:HueAdjustment<Band>` | −100…100 | 1:1，滑块域一致（我们内部把它换算成 ±30°，LR 同量级）；带宽顺序 red/orange/yellow/green/aqua/blue/purple/magenta 与 `HSLBand` 顺序完全一致 | ≈ |
| `bands[i].saturation` | `crs:SaturationAdjustment<Band>` | −100…100 | 1:1 | ≈ |
| `bands[i].luminance` | `crs:LuminanceAdjustment<Band>` | −100…100 | 1:1 | ≈ |
| — | `crs:ConvertToGrayscale` / `GrayMixer<Band>` | 布尔 / −100…100 | 不写：`EditModel` 没有黑白转换与黑白混合 | ✕ |

### 1.5b colorGrading（2026-10-28，S3.8；**故意不写 `crs:`**）

| 字段 | `crs:` 键 | 量程 / 默认 | 转换 | 等级 |
|---|---|---|---|---|
| `shadows/midtones/highlights.hue` | `crs:ColorGrade{Shadow,Midtone,Highlight}Hue` | LR：0…360 **绝对角度**；我方：−100…100 **相对偏移**（±30°） | **不写**。我方是「在这个像素自己的色相上偏移」，LR 是「把这个区域的色相转到某个角度」——按绝对角度写出去，导入后同一张照片会换一个样子（而且我方的 0 = 不动，在 LR 里 0 = 红）。要映射必须先定一条「绝对 = 像素色相 + 偏移」的规则，而区域里每个像素的色相本来就不同，没有唯一解 | ✕ |
| `….saturation` / `….lightness` | `crs:ColorGrade{Shadow,Midtone,Highlight}Sat` / `…Lum` | −100…100，默认 0 | 可 1:1（将来可加）；本版不写，理由同上：一个组只写两个轴会导出半个分级 | ✕ |

`docs/xmp-mapping.md` 的立场一贯是「语义不同就不写，而不是写一个看起来像的值」（§3 的风险清单）。
色彩分级按这条纪律整组不写；`EditModel` 里那九个数只在本机的 `edit.json` 里，这一版没有第二个消费者。

### 1.6 detail（M1 不渲染，仅存储；将来喂 `CIRAWFilter`）

| 字段 | `crs:` 键 | 量程 / 默认 | 转换 | 等级 |
|---|---|---|---|---|
| `sharpening` | `crs:Sharpness` | 0…150，默认 0（**LR 对 raw 的实际默认是 40**） | 1:1 数值；见 §3.5 的默认值错位 | ⚠ |
| `sharpeningRadius` | `crs:SharpenRadius` | 0.5…3，默认 1.0 | 1:1 | ≡ |
| `noiseLuminance` | `crs:LuminanceSmoothing` | 0…100，默认 0 | 1:1；LR 还有 `LuminanceNoiseReductionDetail/Contrast`（默认 50/0），我们无 → 不写 | ⚠ |
| `noiseColor` | `crs:ColorNoiseReduction` | 0…100，默认 0（LR raw 默认 25） | 1:1；`ColorNoiseReductionDetail/Smoothness` 无对应 | ⚠ |
| `lensCorrections` | `crs:LensProfileEnable` + `crs:LensProfileSetup="LensProfile"` + `crs:LensProfileDistortionScale=100` + `crs:LensProfileVignettingScale=100` | 0/1 + 枚举 + 0…200 | 一个 bool 换四个键：**语义是"声明已做镜头校正"**，不是"复制同一变换"。LR 走 Profile 库查找（镜头不在库里则整组无效），我们走 `CIRAWFilter.lensCorrectionEnabled`（per-file 才可靠，§11.3） | ⚠ |
| — | `crs:SharpenDetail` / `SharpenEdgeMasking` | 0…100（默认 25 / 0） | 不写（无字段）；导入时丢弃 | ✕ |

### 1.7 effects

| 字段 | `crs:` 键 | 量程 / 默认 | 转换 | 等级 |
|---|---|---|---|---|
| `vignetteAmount` | `crs:PostCropVignetteAmount` | −100…100，默认 0（负 = 压暗四角，与我方一致） | 1:1 | ≡ |
| `vignetteMidpoint` | `crs:PostCropVignetteMidpoint` | 0…100，默认 50 | 1:1 | ≡ |
| `vignetteFeather` | `crs:PostCropVignetteFeather` | 0…100，默认 50 | 1:1 | ≡ |
| `vignetteRoundness` | `crs:PostCropVignetteRoundness` | −100…100，默认 0（−100 方形 → +100 圆形） | 1:1 | ≡ |
| `grain` | `crs:GrainAmount` | 0…100，默认 0 | 1:1。**2026-10-28 起 `GrainSize` / `GrainFrequency` 也有字段了**，见下面两行 | ≡ |
| `grainSize` | `crs:GrainSize` | 0…100，默认 25（LR 的默认也是 25） | 1:1；默认不写键（同 `BlackOffset` 的纪律） | ≡ |
| `grainRoughness` | `crs:GrainFrequency` | 0…100，默认 50（LR 的默认也是 50） | 1:1；**LR 的 “frequency” 就是粗糙度**，同一根滑杆的两个名字 | ≡ |
| — | `crs:PostCropVignetteStyle` / `PostCropVignetteHighlightContrast` | 1…3 / 0…100 | 不写（无字段）。我们的暗角不区分 Highlight/Color Priority | ✕ |
| — | `crs:Texture` / `Clarity2012` / `Dehaze` | −100…100 | 不写（无字段） | ✕ |

### 1.8 masks（M4 预留）

`Mask { id, kind, params: [String: Double] }` 装不下 LR 的 `MaskGroupBasedCorrections`：
后者是嵌套结构体数组（每个 mask 有自己的 16 个局部滑块，每个组件是 brush `Dabs`/径向 `ZeroX,ZeroY,FullX,FullY`/
线性 `Top…Right`、外加 `CorrectionRangeMask` 的颜色/亮度/深度采样）。

**结论：`crs:` 侧双向都不可映射**（M1 只写 `photons:masks` 的空数组占位，M4 再定）。理由：①几何装不进 `[String: Double]`；
②`kind` 的取值集（`brush|radial|linearGradient|sky|subject`）与 LR 的 `What`/`MaskSubType` 不是一一对应；
③我们一个 mask 一层参数，LR 一个 mask 一组局部滑块，粒度不同。**参考自 lightroom.c 与 redlamp 的 mask 说明，仅取语义。**

## 2. 不可映射字段清单（按叶子标量计，共 5 个）

| 字段 | 原因 |
|---|---|
| `schemaVersion` | LR 没有文档级参数版本概念；只在 `photons:` 私有 ns 里存，供导入告警 |
| `light.highlightRecovery` | 我们的语义（0.8 以上软肩、S1 线性域）在 `crs:` 里没有对应键；`Highlights2012` 是另一件事 |
| `masks[i].id` | 无对应（LR 有 `CorrectionSyncID`，但语义是跨副本同步标识，且我们不做同步） |
| `masks[i].kind` | 取值集与 LR 的 `What`/`MaskSubType` 不一一对应 |
| `masks[i].params` | `[String: Double]` 装不下 LR 的嵌套几何与采样结构 |

另记 7 个**部分可映射**（有损/语义偏移，导出报告须逐条标注）：
`processVersion`、`temperature`、`tint`、`flipHorizontal`、`flipVertical`、`detail.lensCorrections`。

## 3. 表 B：导入 LR XMP 时的风险清单

| # | 风险 | 具体形态 | 处理 |
|---|---|---|---|
| B1 | **缺失键 ≠ 我们的默认值** | `crs:Sharpness` 缺失时 LR 对 raw 的默认是 40，我们的是 0；`ColorNoiseReduction` 同理（LR 25 / 我们 0） | 导入按"**缺失 = EditModel 默认值**"，但在报告里逐字段列出"取默认"，让用户知道 Detail 面板会与 LR 不齐 |
| B2 | **未知键** | `Texture`/`Dehaze`/`PointColor*`/`HDR*`/`LensBlur*`/`MaskGroupBasedCorrections`/新版键 | 白名单读取；未知键不报错、不静默丢弃 → 键名+值进导入报告并入库 `import_notes`（便于以后补） |
| B3 | **量程越界** | `Temperature=50000`（我们 2000…12000）、`Exposure2012=±20`（手改 XMP）、HSL 超 ±100、`CropAngle=±60` | 一律 **clamp 并记录**，不静默；clamp 后再归一化（`NormalizedRect.clamped()`） |
| B4 | **`-999999` 哨兵** | LR 的"延迟调整"值（LightCraft 记录过） | 视为缺失，不 clamp（clamp 会得到巨大负值） |
| B5 | **色彩空间假设** | `crs:Temperature/Tint` 只有配合相机 profile 矩阵才有物理意义；别人的 XMP 来自 Adobe Standard 或自定义 profile | 只当"滑块位置"用，不当物理色温；`crs:CameraProfile` 读到什么都不试图复现，报告里注明"profile 未迁移" |
| B6 | **ProcessVersion 语义差异** | LR 的 PV 是 Adobe 算法代号（3003/2010/2012，字符串 `"11.0"`）；且 **PV < 2012 时 `*2012` 键不被采用**，老键 `Exposure`/`Contrast` 才生效 | 导入**丢弃** PV，文档标到我们当前 `processVersion`，原值进报告；同时若 PV<11 且存在老键（`Exposure`/`Contrast`/`Highlights`…），按老键读并把 PV 记进报告 |
| B7 | **参照系不一致** | LR 的 crop 相对**文件存储像素、相机 orientation 之前**；若我们的解码缓冲已应用 EXIF orientation，90°/270° 时 `x/y/w/h` 必须转置 | 导入时按"解码是否已应用 orientation"分支转置；必须有 4 个 orientation 的用例 |
| B8 | **`tiff:Orientation` 非单射** | 8 个值里含相机方向，翻转组合要靠 EXIF 参与才可逆 | 读 `tiff:Orientation` + 文件 EXIF orientation 一起反算两个 bool；算不出就取 false 并报告 |
| B9 | **多值/嵌套类型** | `dc:subject/title/creator` 读回是**嵌套 Tag 数组**；`ToneCurvePV2012` 必须是 `rdf:Seq` 的 `li` 字符串 | 见 §4.3；曲线按 `"x, y"` 解析，容忍空格/负数/多余项 |
| B10 | **数值格式** | `"."` 小数点，LR 写 6 位；locale 相关格式化会写 `0,5` | 解析走 `strtod` 语义（强制 POSIX locale），拒绝 `,` 小数 |
| B11 | **命名空间 URI 必须逐字符精确** | `http://ns.adobe.com/camera-raw-settings/1.0/`（末尾斜杠；写成 `1.0` 或 `.../1.0` 之外都静默不认） | 常量集中定义，单测断言序列化文本里的 `xmlns:crs` |
| B12 | **LR 与我们的"恒等"不同义** | 我们 `exposure=0` 是"不解码重来、直接透传"（M1-6 的真实分支）；LR 的 0 是它曲线上的中点 | 只在 0 点断言"同为中性"，其余点不承诺像素级一致（L3 统计兜底） |
| B13 | **一个 mask 组整体丢弃的风险** | 我们的 M1 不渲染 mask；若导入时把 `MaskGroupBasedCorrections` 静默丢掉，用户会以为丢失是 bug | 明确报告"局部调整未迁移（M4）"，并把原结构 base64 存进 `import_notes` |

## 4. 写入路径（ImageIO / `CGImageMetadata`）

### 4.1 命名空间注册

`crs` **不是** ImageIO 内置前缀（内置的有 `dc`/`xmp`/`xmpMM`/`tiff`/`exif`/`photoshop` 等）。
不注册就 `CGImageMetadataSetValueWithPath` 会直接返回 `false`：

```
CGImageMetadataRegisterNamespaceForPrefix(m, CFSTR("http://ns.adobe.com/camera-raw-settings/1.0/"), CFSTR("crs"), &err)
CGImageMetadataRegisterNamespaceForPrefix(m, CFSTR("https://photons.app/ns/edit/1.0/"),        CFSTR("photons"), &err)
```

### 4.2 两条写路径

| 路径 | API | 要点 |
|---|---|---|
| A 内嵌（导出 JPEG/HEIC/TIFF/PNG） | `CGImageSourceCopyMetadataAtIndex` → `CGImageMetadataCreateMutableCopy` → `SetValueWithPath` → `CGImageDestinationAddImageAndMetadata` | 四容器已实测可往返（§11.5）。**必须 mutable copy 源元数据**，绝不新建空 `CGImageMetadata`——否则 exif/iptc/别人写的 `crs:` 全丢 |
| B sidecar | `CGImageMetadataCreateXMPData`（把 metadata 序列化成 XMP 包）→ 加 `<?xpacket begin="\u{FEFF}" …?>` 头与 `<?xpacket end="w"?>` 尾 + 2–4 KB padding → 原子写（temp + fsync + rename） | ImageIO 没有"XMP-only 输出类型"，sidecar 不能靠 `CGImageDestination`；RAW 本身不可写（§1），所以 RAW 只能走 sidecar |

已有的 `.xmp` 存在时：读入现有 packet → `CGImageMetadataCreateFromXMPData` → mutable copy →
**只覆写我们拥有的键**，他人的 `crs:`、`xmpMM:History`、未知命名空间原样保留（合并原则参考自 LightCraft 的 sidecar 策略，仅取语义）。
读不了的先备份 `.xmp.bak-<time>`。

### 4.3 类型与两个已知坑

- **类型要显式**：数值用 `CFNumber` + `kCGImageMetadataTypeDefault`（ImageIO 落成 `xmp:Real`/整数）；
  有序点列用 `kCGImageMetadataTypeArrayOrdered`（→ `rdf:Seq`），关键词用 `kCGImageMetadataTypeArrayUnordered`（→ `rdf:Bag`）。
  曲线写成 `Seq` 的字符串项 `"%d, %d"`，**不能**写成空格分隔的单字符串。
- **坑 1：`dc:subject/title/creator` 读回是嵌套 Tag 数组**（§11.5 实测）。`CGImageMetadataCopyTagWithPath` 拿到的外层 tag，
  其 value 是 `CFArray<CGImageMetadataTagRef>`，必须逐项取子 tag 的 value，直接当 `CFString`/`CFArray<CFString>` 会拿到空或崩。
  **规避**：机器可读数据一律不放 `dc:*`（全部走 `photons:*` 的单字符串）；`dc:subject` 只由 catalog 侧写关键词，
  且我们**不回读**它，所以这条坑只影响"导入时读别人的 sidecar"——那里按嵌套数组解析。
- **坑 2：数字读回是字符串**。写进去的 `3.5` 读回是 `CFString("3.5")`，而 `3.500000` 读回是 `CFString("3.500000")`，
  也可能在某些容器里仍是 `CFNumber`。**规避**：读侧统一走一个 `xmpDouble(_:)`（`CFNumber` → `CFStringGetDoubleValue` 两条腿），
  禁止 `CFNumberGetValue` 直接强转；往返比对一律**比数值**（`abs(a−b) ≤ 1e-6`），绝比字符串。

### 4.4 "只导出不回读"在代码上的含义

1. `XMPWriter` 只是 `EditModel → CGImageMetadata` 的纯函数，**没有逆函数**；`XMPReader` 只存在于 `Import/LightroomImporter` 目标。
2. `PhotonsCore` 与渲染路径**不得依赖** `Import` 目标（用依赖图断言）：`CGImageSourceCopyMetadataAtIndex` 只允许出现在导入器。
3. 渲染入口只从 `assets.develop_json` 取 `EditModel`；不订阅 `.xmp` 的 FSEvents、不比 mtime（D7 的代价，UI 在"导出 XMP"处写明）。
4. 写失败不阻断导出：XMP 是可丢的派生物，失败只记日志与导出报告，DB 里已提交的 `EditModel` 不受影响。
5. 导入是显式一次性命令，结果落成新快照（D10 一步 undo），此后不再回看 XMP。

## 5. 往返验收清单（写 XMP → `CGImageMetadata` 读回 → 与 `EditModel` 比对）

前置：每条用例都在 **JPEG / HEIC / TIFF / PNG** 四容器各跑一次（§11.5 已验四容器往返可行），
数值比较统一 `|Δ| ≤ 1e-6`，`crs:` 用语义等价比较，`photons:` 用精确比较。

| # | 用例 | 必须断言 |
|---|---|---|
| X-01 | `EditModel.neutral` | 只出现 `crs:Version`/`ProcessVersion`/`WhiteBalance` + `photons:*`；**不存在** `crs:Exposure2012` 等（R1） |
| X-02 | 显式 0（`exposure=0.0`，非缺失） | 与 X-01 字节相同：0 与缺失不可区分，且都等价于恒等 |
| X-03 | 负值：`exposure=-5, tint=-150, vignetteAmount=-100`, 8 段 HSL 全 −100 | 读回逐字段相等，符号不被格式化吞掉 |
| X-04 | 极值：`exposure=+5, temperature=12000, tint=+150, sharpening=150`, 半径 0.5 与 3 | 读回相等；`CropRight/Bottom` 不因 clamp 而漂移 |
| X-05 | 曲线量化：16 点随机单调曲线 | 每点 `|Δx|,|Δy| ≤ 0.5/255`；点数 == 16；首尾点保留 |
| X-06 | 曲线退化：>16 点 / 重复 x / 非单调 x | 写前规范化（排序去重、抽稀到 16），不写出 LR 反解不了的 `Seq`，报告记录丢弃点 |
| X-07 | crop + 角度：`crop=(0.1,0.2,0.3,0.4)`, `rotation=+12.5` | `CropLeft=0.1, CropTop=0.2, CropRight=0.4, CropBottom=0.6, CropAngle=-12.5`；0° / +45 / −45 各一条 |
| X-08 | `crop == .full` | `HasCrop` 缺失（或 `False`），无任何 `Crop*` 键 |
| X-09 | 翻转 4 组合 × 4 个 EXIF orientation | 4 种组合映射到 4 个不同的 `tiff:Orientation`，且能反算回原 bool |
| X-10 | locale：`LC_NUMERIC=de_DE` 下重跑 X-04 | 仍写 `"."` 小数；读回一致 |
| X-11 | 数字三形态：`CFNumber(0.35)`、`CFString("0.35")`、`CFString("0.350000")` | `xmpDouble` 三者同值；不含 `,` 小数解析路径 |
| X-12 | `dc:subject` 三条关键词（Bag） | 读回逐条相等（防坑 1 的嵌套 Tag 数组）；`dc:description` 不被当字符串直接取 |
| X-13 | 未注册 `crs` 就 `SetValueWithPath` | 返回 `false`（回归保护）；注册后 XMP 文本含精确 `xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"` |
| X-14 | 未知键保真：目标容器已有 `crs:Texture`、`SplitToningShadowHue`、`xmpMM:History` | 写完后逐字节仍在，未被覆写/丢弃 |
| X-15 | `photons:settings` 载荷 > 64 KB（多段曲线 + 占位 masks） | 仍能写出与读回；超阈走 sidecar，不硬塞进内嵌 XMP |
| X-16 | 导入真 LR sidecar：`Temperature=5200`、`ProcessVersion="15.4"`、某局部调整含 `-999999` | 温度按 as-shot 锚点解释；PV 被丢弃并记录原值；哨兵视为缺失 |
| X-17 | 导入含 `MaskGroupBasedCorrections` 的文件 | `masks == []`，报告含"局部调整未迁移（M4）"，原结构进 `import_notes` |
| X-18 | 幂等：同一 `EditModel` 连写两次 | 两次输出字节相同（键序稳定），第二次 diff 为空 |

## 6. 永远只单向导出的字段

这些字段**只写出去，永不回读**，任何"从 XMP 恢复"的路径都必须忽略它们（缺失即用 `EditModel` 默认值）：

| 字段 | 只出不回的理由 |
|---|---|
| `schemaVersion` | 我们的结构版本对 LR 无意义；回读会把别人的 sidecar 误判成旧文档 |
| `processVersion` | 我们的算法版本 ≠ Adobe PV；回读等于把别人的渲染语义当自己的 |
| `light.highlightRecovery` | 无 `crs:` 键；`photons:highlightRecovery` 只是备份 |
| `masks.*`（M1–M3） | 结构不可映射（§1.8）；导入侧永远得到 `[]` |
| `detail.lensCorrections` | 只声明"已做校正"；LR 端的 Profile 状态不能反推我们的 bool |
| ~~`effects.grain` 的 size/frequency~~ | **已解决（2026-10-28）**：`grainSize` → `GrainSize`、`grainRoughness` → `GrainFrequency`，双向 1:1 |
| `xmp:Rating` / `xmp:Label` / `dc:subject` | 由 catalog（DB）写，不是 `EditModel`；真相在库，XMP 只是镜像（D7） |

**一句话**：`crs:` 是给人（Lightroom 用户）看的一份"尽力而为"的副本，`photons:settings` 是我们自己的无损备份，
两者都不是真相；真相永远是 `assets.develop_json`。
