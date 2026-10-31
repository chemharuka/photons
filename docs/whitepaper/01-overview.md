# 1 总览：一条管线，三条不变量

## 1.1 分工边界：Apple 做解码，Photons 做其余

`CIRAWFilter` 交出来的是**已经去马赛克、已经做过机身降噪与镜头校正**的线性图。Photons 不碰马赛克，也因此放弃了两件必须在马赛克上做的事——HDR 合成与超分辨率（`README.md` 的「Not in scope」）。

这条边界带来三个直接后果，后面每一章都会用到：

1. **白平衡是 S1 的增益，不是解码参数（143 起）。** 解码器永远停在文件自己的 as-shot 平衡，`CIRAWFilter` 的温度/色调从不写入；文档里的 `temperature/tint` 由 `WhiteBalanceEstimate` 在本机算成三通道增益，S1 用 `v *= gain · wb` 一次乘完（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:3`、`Sources/PhotonsCore/RAWDecoder.swift:102`）。好处是拖白平衡不再重新解码，预览就是松手帧（`docs/STATUS.md`）。注：`Sources/PhotonsCore/EditModel.swift:1284` 的注释仍写着「喂给 `CIRAWFilter`」，那是 143 之前的说法，保留它是因为字段名还没改。
2. **解码是昂贵的、带缓存的。** 60 MP 全分辨率解码约 0.5 s（v8）/ 更久（v9），结果按 `DecodeCacheKey` 落到磁盘，第二次打开是读盘而不是解码（`Sources/PhotonsCore/LinearImageStore.swift:24`）。
3. **解码缓冲进缓存键。** 缓冲的身份是 `DecodeCacheKey.digest`（文件 SHA-256、解码器版本、曝光、缩放、色彩空间、白平衡、细节参数、解码配方、镜头剖面），不是像素哈希——对 60 MP 每帧做哈希比渲染本身还贵（`Sources/PhotonsCore/RenderGraph.swift:11`）。

> **α 注记。** `CIRAWFilter` 的 `decoderVersion` 会被机型白名单静默降级（请求 v9 得到 v8），所以解码后必须回读能力集再决定 UI 与键（`Sources/PhotonsCore/DecoderCapabilities.swift`）。

## 1.2 一条管线：20 个 stage

渲染图是**一条单向链**：每个 stage 读上一张纹理、写下一张，边界就是缓存键。执行顺序定义在 `Sources/PhotonsCore/Stage.swift:182`；下表按它排列，并给出每个 stage 的域与存在条件。

| 顺序 | stage | 做什么 | 域 | 何时存在 |
|---|---|---|---|---|
| **S0** | `s0-geometry` | 方向、裁切、拉直、翻转、90°、透视、横向色差、文件自带镜头 warp | 源像素 | 总是 |
| **S1** | `s1-scene-linear` | 白平衡增益、黑电平偏移、曝光增益、黑白端点、高光恢复 | 场景线性 | 总是 |
| **S1.5** | `s1.5-mask-atlas` | 把所有蒙版的覆盖率烘成一张图集 | 画布网格 | 有启用的蒙版 |
| **S1.6** | `s1.6-local` | 蒙版内的曝光、色温/色调、黑白端点、影调 | 场景线性 | 同上 |
| **S1.9** | `s1.9-heal` | 修复/克隆（泊松边界匹配） | 场景线性 | 有修复点 |
| **S1.7** | `s1.7-hdr-curve` | HDR 曲线（W/R/G/B 四张表） | 曲线轴（`u`） | 总是 |
| **S1.9-dz** | `s1.9-dehaze` | 去雾（暗通道先验） | 场景线性 | `dehaze ≠ 0` |
| **S3c** | `s3-vignette` | 镜头暗角校正 | 场景线性 | 总是 |
| **S2** | `s2-tone-map` | 高光、中间调、阴影三段窗口 | 显示参考 | 总是 |
| **S2.5** | `s1.8-contrast` | 对比（多尺度引导滤波残差） | 显示参考 | `contrast ≠ 0` 或蒙版带对比 |
| **S3** | `s3-color` | 自然饱和、饱和 | 显示参考 | 总是 |
| **S3.4** | `s3.4-bw` | 黑白 + 每色相混合 | 显示参考 | 黑白开关开 |
| **S3.5** | `s3.5-local-color` | 蒙版内的色相、饱和 | 显示参考 | 蒙版带色相/饱和 |
| **S3.6** | `s3.6-hsl` | 八色带 HSL（OKLCh） | 显示参考 | 24 个值任一非零 |
| **S3.6b** | `s3.6b-point-colour` | 点颜色（采样一个 OKLCh 颜色） | 显示参考 | 有采样且有调整 |
| **S3.8** | `s3.8-grade` | 三向色彩分级（阴影/中间调/高光） | 显示参考 | 九个值任一非零 |
| **S3.9** | `s3.9-detail-fx` | 纹理、清晰度、去噪、去彩噪 | 显示参考 | 任一非零 |
| **S3.10** | `s3.10-sharpen` | 锐化（USM + 边缘蒙版） | 显示参考 | `amount > 0` |
| **S3.7** | `s3.7-grain` | 颗粒 | 显示参考 | `grain > 0` |
| **S4** | `s4-display` | 基色矩阵、sRGB OETF、`min(v, headroom)` | 输出 | 总是 |

七个**无条件**阶段（S0、S1、S1.7、S3c、S2、S3、S4）构成基线；其余十三个由谓词决定是否进入链。谓词是「值」而不是「对象存在」：`EditModel.hasBands` 看 24 个 HSL 数里有没有非零，`hasDetailFX` 看四个数，`hasGrain` 看 `grain > 0`（`Sources/PhotonsCore/EditModel.swift:1933`、`:2293`、`:2287`）。

> **两处与 README 不一致，以代码为准。** ① 曲线在 **tone map 之前**（S1.7），不在之后（`Stage.swift:34`）；② 白点/黑点是 **S1 的端点**，不在 S2（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:40`，同一文件第 9 行还留着「098 moved contrast out of this file」的历史注记）。README 的对照表是 M1 版本。

## 1.3 三条不变量

这三条不是设计口号，是被测试钉住的属性；第四章每次讲算法都会回到它们。

**① 中性零变化（byte-for-byte）。**
没碰过的控件必须让像素逐字节等于没有这个功能时的像素，不是「视觉上一样」。做法是让条件 stage **根本不进链**：`masks == []` 的文档得到与 M1 完全相同的 trace、键链与像素；24 个 HSL 全零、颗粒为 0、锐化 amount 为 0 的文档同样（`Stage.swift:164`、`:176`）。这条契约的强度在于它让「优化」和「新功能」都不会悄悄改变老照片。

**② stage 级缓存键。**
每个边界是一个键：只改 S3 的参数不会重跑 S0/S1/S2。键是链式的——`H(上一环 | 本环材料)`——所以链尾相等就蕴含整条链相等；`--trace-stages` 会打印每一阶段是跑了还是命中（`RenderGraph.swift:1925`）。

**③ 屏幕与导出同一算术。**
同一份文档、同一个 `RenderGraph`：屏幕上渲染到画布（可能带黑边、带 EDR headroom），导出渲染到内容尺寸（`headroom = 1`）。两条路径的差别只有 `RenderOptions`，没有第二套着色器（`README.md`；`Sources/PhotonsCore/Stage.swift:373`）。

## 1.4 两条路径，一套算术

```
屏幕：decode → S0…S3.7 → S4 → present（画布，headroom = 屏的上限）
               ↘（同一批纹理）
导出：decode → S0…S3.7 → S4 → encode（内容尺寸，headroom = 1）→ JPEG/HEIC/TIFF/PNG/AVIF
```

- 屏幕的 `canvas` 是视口像素，照片在里面可能留黑边（letterbox）；导出的 `canvas` 为 `nil`，即内容本身的大小（`RenderGraph.swift:52`）。
- 屏幕的 S4 把上限交给 `DisplayOptions.headroom`；导出恒为 1。`headroom = 1` 与旧的 `clamp(v, 0, 1)` 逐字节相同（`Sources/PhotonsCore/Kernels/s4_display.metal:11`）。
- 「显示原图」（`\`）不是「参数清零后的渲染」，而是把管线缩短成 `S0(identity) → S4` 的另一次渲染；它不改键、不写文档、不重新解码（`RenderGraph.swift:148`、`:1972`）。

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

`--trace-stages` 是本文所有「某阶段没重跑」说法的现场证据：它打印的短名（`s1`、`s2.5`、`s3.6`……）与 `RenderStage.short` 一致（`Stage.swift:240`）。

---

下一章从屏幕开始：一张照片是怎么从一块线性缓冲变成画布上的像素的。
