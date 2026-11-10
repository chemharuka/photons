# 1 总览：一条管线，三条不变量

## 1.1 分工边界：Apple 做解码，Photons 做其余

`CIRAWFilter` 交出来的图已经去过马赛克，也做过机身降噪和镜头校正，是一张线性图。Photons 不碰马赛克，所以也放弃了两件必须在马赛克上做的事：HDR 合成与超分辨率（`README.md` 的「不做的事」）。

这条边界带出三个后果，后面每一章都会用到：

1. 白平衡分两段走。文档里的 `temperature/tint` 不是 `nil` 时，Photons 把它写回 `CIRAWFilter.neutralTemperature/neutralTint`，解码器据此重新出一张图。这个值决定的是「哪张缓冲」，跟渲染无关（`Sources/PhotonsCore/EditModel.swift:1521`、`Sources/PhotonsCore/RAWDecoder.swift:587`）。`nil` 表示 as shot，此时完全不碰 filter，因为把读到的 as-shot 值再赋回去不是恒等。拖动期间不重解码，S1 用一条自算的 3×3（Bradford、锚点相对）把画面搬过去，松手才落成解码参数。所以同一对 (K, tint) 在两种状态下走的路不同：预览是近似，落定后是真值。
2. 解码很贵，所以要缓存。一次全尺寸 RAW 解码是数百毫秒量级。359 实测：2380×1584 的 1/4 尺寸 387 ms，其中 CPU 去马赛克约 830 ms×线程数。结果按 `DecodeCacheKey` 落到磁盘，第二次打开是读盘，不再解码（`Sources/PhotonsCore/LinearImageStore.swift:24`）。
3. 解码缓冲参与缓存键。缓冲的身份是 `DecodeCacheKey.digest`，由文件 SHA-256、解码器版本、曝光、缩放、色彩空间、白平衡、细节参数、解码配方、镜头剖面算出来。这里不按像素算哈希：60 MP 每帧做一次哈希比渲染本身还贵（`Sources/PhotonsCore/RenderGraph.swift:11`）。白平衡在键里，因为它会写回解码器、改掉像素；as shot 时这个分量不出现，所以老缓冲照样命中。

> **α 注记。** `CIRAWFilter` 的 `decoderVersion` 会被机型白名单静默降级（请求 v9 得到 v8），所以解码后要回读能力集，再决定 UI 与键（`Sources/PhotonsCore/DecoderCapabilities.swift`）。

## 1.2 一条管线：20 个 stage

渲染图是一条单向链：每个 stage 读上一张纹理、写下一张，边界就是缓存键。执行顺序写在 `Sources/PhotonsCore/Stage.swift:183`，下表按它排列，每个 stage 的域和存在条件一并列出。

| 顺序 | stage | 做什么 | 域 | 何时存在 |
|---|---|---|---|---|
| **S1.9-heal** | `s1.9-heal` | 修复与克隆（泊松边界匹配、频率分离、红眼） | S1 源像素 | 有修复点 |
| **S0** | `s0-geometry` | 方向、裁切、拉直、翻转、90°、透视、横向色差、文件自带的镜头 warp | 源像素 | 总是 |
| **S1** | `s1-scene-linear` | 白平衡矩阵、黑电平偏移、曝光增益、黑白端点、高光恢复 | 场景线性 | 总是 |
| **S1.5** | `s1.5-mask-atlas` | 把所有蒙版的覆盖率烘成一张图集 | 画布网格 | 有启用的蒙版 |
| **S1.6** | `s1.6-local` | 蒙版内的曝光、色温/色调、黑白端点、影调 | 场景线性 | 同上 |
| **S1.7** | `s1.7-hdr-curve` | HDR 曲线（W/R/G/B 四张表） | 曲线轴（`u`） | 总是 |
| **S1.9-dehaze** | `s1.9-dehaze` | 去雾（暗通道先验） | 场景线性 | `dehaze ≠ 0` |
| **S3c** | `s3-vignette` | 镜头暗角校正 | 场景线性 | 总是 |
| **S2** | `s2-tone-map` | 高光、中间调、阴影三段归一化高斯 + 画面天花板 | 显示参考 | 总是 |
| **S2.5** | `s1.8-contrast` | 全局对比（增益域幂律） | 显示参考 | `contrast ≠ 0` 或蒙版带对比 |
| **S3** | `s3-color` | 自然饱和、饱和 | 显示参考 | 总是 |
| **S3.4** | `s3.4-bw` | 黑白 + 每色相混合 | 显示参考 | 黑白开关开 |
| **S3.5** | `s3.5-local-color` | 蒙版内的色相、饱和 | 显示参考 | 蒙版带色相/饱和 |
| **S3.6** | `s3.6-hsl` | 八色带 HSL（OKLCh） | 显示参考 | 24 个值任一非零 |
| **S3.6b** | `s3.6b-point-colour` | 点颜色（采样一个 OKLCh 颜色） | 显示参考 | 有采样且有调整 |
| **S3.8** | `s3.8-grade` | 三向色彩分级（阴影/中间调/高光） | 显示参考 | 九个值任一非零 |
| **S3.9** | `s3.9-detail-fx` | 纹理、清晰度、去噪、去彩噪 | 显示参考 | 任一非零 |
| **S3.10** | `s3.10-sharpen` | 锐化（USM + 边缘蒙版） | 显示参考 | `amount > 0`（默认 50 → 恒真） |
| **S3.7** | `s3.7-grain` | 颗粒 | 显示参考 | `grain > 0` |
| **S4** | `s4-display` | 基色矩阵、sRGB OETF、`min(v, headroom)` | 输出 | 总是 |

七个无条件阶段（S0、S1、S1.7、S3c、S2、S3、S4）搭出基线，其余十三个靠谓词决定进不进链。谓词看的是值，不是对象在不在：`EditModel.hasBands` 数 24 个 HSL 数里有没有非零，`hasDetailFX` 看四个数，`hasGrain` 看 `grain > 0`（`Sources/PhotonsCore/EditModel.swift:2163`、`:397`、`:382`）。

有两处名字和位置对不上，以 `order` 数组为准。① 修复的 raw value 是 `s1.9-heal`，但它跑在最前面、在 S0 之前，修的是 S1 的源像素，之后才轮到几何（`Sources/PhotonsCore/Stage.swift:24`）。② 对比的 raw value 是 `s1.8-contrast`，实际跑在 S2 之后（S2.5），旧名字留着是为了让历史 trace 还能读（`Sources/PhotonsCore/Stage.swift:55`）。

> 早期本文说 README 的对照表停留在 M1、曲线在 tone map 之后。现在两份文档已经对上：曲线在 tone map 之前（S1.7），白点和黑点是 S1 的端点，不在 S2（`Sources/PhotonsCore/Stage.swift:194`、`Sources/PhotonsCore/Kernels/s2_tone_map.metal:40`）。

## 1.3 三条不变量

这三条都被测试钉住了。第四章每讲一个算法，都会回到它们。

**① 中性零变化（byte-for-byte）。**
没碰过的控件，要让像素逐字节等于没有这个功能时的像素，视觉上像不算。做法是让条件 stage 根本不进链：`masks == []` 的文档得到与 M1 完全相同的 trace、键链与像素；24 个 HSL 全零、颗粒为 0 的文档也一样（`Sources/PhotonsCore/Stage.swift:165`、`:177`）。这条要求让「优化」和「新功能」都不会悄悄改掉老照片。

有一个例外：锐化的静止值是 50。314 之后默认文档带 `amount = 50, radius = 2.0`，于是 S3.10 对每个文档都成立，每个文档都要过一遍 USM。所以「中性 == 解码 + OETF」现在只对锐化归零的文档成立。默认文档是「解码 + 一点锐化」，这是用户明确要的默认外观，不是漏配（`Sources/PhotonsCore/EditModel.swift:2655`、`Tests/PhotonsCoreTests/BeforeAfterTests.swift:174`）。其余十二个条件阶段仍然严格按谓词走。

**② stage 级缓存键。**
每个边界是一个键：只改 S3 的参数，S0/S1/S2 不重跑。键是链式的，`H(上一环 | 本环材料)`，链尾相等就蕴含整条链相等。`--trace-stages` 会打印每个阶段是跑了还是命中（`Sources/PhotonsCore/RenderGraph.swift:2434`）。

**③ 屏幕与导出同一算术。**
同一份文档、同一个 `RenderGraph`。屏幕上渲染到画布（可能带黑边、带 EDR headroom），导出渲染到裁切框（`headroom = 1`，`CanvasRole.export`）。两条路径的差别只有 `RenderOptions`，着色器只有一套（`README.md`；`Sources/PhotonsCore/Stage.swift:377`）。

## 1.4 两条路径，一套算术

```
屏幕：decode → S1.9-heal → S0…S3.7 → S4 → present（画布 .document，headroom = 屏的上限）
               ↘（同一批纹理）
导出：decode → S1.9-heal → S0…S3.7 → S4 → encode（裁切框 .export，headroom = 1）→ JPEG/HEIC/TIFF/PNG/AVIF
```

- 屏幕的 `canvas` 是视口像素、角色 `.document`，照片在里面可能留黑边（letterbox）或黑角（透视）；导出的 `canvas` 是裁切框、角色 `.export`（`Sources/PhotonsCore/RenderGraph.swift:80`、`:304`）。
- 屏幕的 S4 把上限交给 `DisplayOptions.headroom`，导出恒为 1。`headroom = 1` 与旧的 `clamp(v, 0, 1)` 逐字节相同（`Sources/PhotonsCore/Kernels/s4_display.metal:11`）。两条路径共用 S2 出口的画面天花板（320），所以「最高亮度」这个偏好对屏幕和文件是同一个数。
- 「显示原图」（`\`）的做法是把管线缩短成 `S0(identity) → S4` 再渲染一次，没有把参数清零。它不改键、不写文档、不重新解码（`Sources/PhotonsCore/RenderGraph.swift:186`、`:2235`）。

## 1.5 代码地图

| 目录 | 职责 | 本文用到的部分 |
|---|---|---|
| `Sources/PhotonsCore/` | 解码、线性缓冲、RenderGraph、Metal kernel（不依赖 AppKit） | 第 2、3、4 章的全部 |
| `Sources/PhotonsCore/Kernels/` | 每个 stage 的 `.metal` 源文件，运行时由 `Metal.framework` 编译 | 公式的最终真值 |
| `Sources/PhotonsExport/` | 渲染 + 编码、批量导出、XMP | 第 1.4、2.5 节 |
| `Sources/PhotonsCatalog/` | SQLite 目录、导入、缩略图 | 不涉及 |
| `Sources/PhotonsUI/` | AppKit/SwiftUI 外壳、画布、检查器 | 只提参数名，不写界面 |
| `Sources/photonsctl/` | 无窗口的验收工具，也是每个动词的唯一实现 | 第 1.6 节 |

## 1.6 怎么自己看

```sh
# 一次渲染，打印每个阶段是跑了还是命中缓存
.build/release/photonsctl render photo.dng --edit Tests/Fixtures/edit-push.json \
    --out /tmp/out.jpg --scale 0.25 --trace-stages

# 解码事实：版本、能力、as-shot 白平衡、线性最大值
.build/release/photonsctl info photo.dng
```

本文所有「某阶段没重跑」的说法，现场证据都来自 `--trace-stages`。它打印的短名（`s1`、`s2.5`、`s3.6`……）与 `RenderStage.short` 一致（`Stage.swift:244`）。

---

下一章从屏幕开始：一张照片是怎么从一块线性缓冲变成画布上的像素的。
