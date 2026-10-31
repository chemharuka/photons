<p align="center"><img src="Resources/AppIcon-legacy-1024.png" width="120" alt="Photons 图标"></p>

<h1 align="center">Photons</h1>

<p align="center">macOS 原生 RAW 工作流：导入文件夹、挑片、非破坏性显影、导出。Swift 编写，MIT 许可。</p>

<p align="center">
  <a href="https://chemharuka.github.io/photons/"><strong>白皮书</strong></a> ·
  <a href="docs/architecture-decisions.md">架构决策</a> ·
  <a href="docs/STATUS.md">项目状态</a> ·
  <a href="#构建与运行">构建</a>
</p>

Photons 不自带 RAW 解码器。相机相关的那一半（去马赛克、镜头校正、机器学习降噪）是 **Apple 的**：`CIRAWFilter` 调用系统里的 `RawCamera`。它之上的一切是我们自己的：SQLite 目录、Metal 渲染图、蒙版、色彩管理、XMP 与导出。

这条分工边界的证据——以及为什么**故意**不链接 LibRaw、Exiv2、libheif 或 lensfun——写在 [docs/architecture-decisions.md](docs/architecture-decisions.md)。那里每一条结论都有真实文件的实测或对系统框架的阅读作为依据。

## 已经能做什么

项目在 1.0 之前，动得很快；下面每一条都不是「计划中」，而是被 `make verify` / `make ui-smoke` 实际跑过的。

**素材库** —— 一个 `.photonslibrary` 包（SQLite/WAL）。按复制或按引用导入；文件按内容哈希去重，导入中途被 `kill -9` 杀掉再重来会续传到同一批素材，不产生重复。文件夹树、15 个维度的筛选栏（星级、旗标、颜色标签、相机、镜头、ISO、焦距、快门、光圈、月/日、扩展名、序列号、闪光、GPS）、星级/选用/排除/颜色标签、缺失文件查找、内容寻址的缩略图缓存。

**显影** —— 一份非破坏性文档，五个检查器工作区：

| 工作区 | 卡片 |
|---|---|
| 调整 | 白平衡 · 黑电平 · 光线（曝光/对比/高光/阴影/白色/黑色）· 色彩（自然饱和/饱和）· 黑白（每色相混合）· 细节（降噪/色彩降噪/锐化/细节 + 色差 R/B）· 曲线（HDR 域控制点）· 效果（暗角 · 纹理/清晰度/去雾 · 颗粒）· 预设 |
| 变换 | 裁切（比例、拉直 ±45°、翻转）、90° 旋转 |
| 色彩 | HSL 八色带 · 三向色彩分级（阴影/中间调/高光 × 色相/饱和/亮度） |
| 蒙版 | 画笔 · 线性渐变 · 径向渐变 · 颜色范围 · 亮度范围 · 语义（Vision 主体）；每张蒙版有 opacity/羽化/refine/反相/混合与 10 个局部滑杆（曝光/温度/色调/对比/高光/阴影/白色/黑色/色相/饱和） |
| 历史记录 | 时间线，点击回到任意快照 |

另有**前后对比**（`\` 显示解码原图，`Y` 分屏，`⇧Y` 换分割轴）、**预设**、分组的**复制/粘贴设置**（含蒙版，按短边锚定），以及固定在各工作区上方的直方图。

**导出** —— JPEG / HEIC / TIFF（8 或 16 位）/ PNG / AVIF；长边缩放且不放大；sRGB 或 Display P3；质量；`{seq}-{name}` 文件名模板；批量导出逐张给出结果（一个坏文件不会拖垮其余）；XMP 可内嵌、也可写成 sidecar。

一切都在同一个 `RenderGraph` 里批处理，所以屏幕上的图和导出的文件是同一套算术。同一份文档在两个进程里渲染两次得到同样的字节——这是测试，不是愿望。

## 环境要求

- macOS 14 或更新（最新的 `RawCamera` 解码版本要求最新的 macOS；本仓库在 macOS 27 / Xcode 27 / Swift 6 上构建与测量）。
- 唯一的第三方依赖，由 SwiftPM 解析：[GRDB](https://github.com/groue/GRDB.swift) 7（MIT），用于 SQLite。见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 仓库里没有任何 `.xcodeproj`。Metal kernel 作为**资源**发布，启动时由 `Metal.framework` 编译——SwiftPM 没有可靠的 `.metal` 构建步骤。
- 自备一张 RAW 作为测试素材（仓库不附带照片）：`PHOTONS_TEST_RAW=…` 或 `make verify RAW=…`。

## 构建与运行

```sh
make app
open .build/Photons.app
```

`make app` 会做 release 构建、打包、ad-hoc 签名，产物在 `.build/Photons.app`。

首次启动：文件 ▸ 打开库… 新建一个 `.photonslibrary`，然后 ⇧⌘I 导入文件夹。缓存（解码后的线性缓冲、缩略图）按库分开，位于 `~/Library/Caches/Photons/<library-hash>/`。

## 验收门

```sh
make verify
```

一条命令：构建 + 单元测试 + L1/L2/L3 + 目录验收 + bench。

| 层级 | 证明什么 |
|---|---|
| 单元测试 | 1 652 个用例（Core 658 · Catalog 179 · Export 44 · UI 771）：解码契约、渲染图、蒙版、目录、XMP、导出、界面布局 |
| **L1** 确定性 | 两个独立进程解码同一文件，得到同一摘要 |
| **L2** golden | 按 OS 版本记录的像素摘要，把「系统变了」和「我们改坏了」分开 |
| **L3** 图 | 中性 == 解码 + sRGB OETF；只改 S3 会跳过 S0/S1/S2；编辑敏感性；渲染 golden |
| 目录 | 针对真实库的 12 项验收：去重、`kill -9` 后续传、移动、离线、迁移 |
| bench | 视口尺寸下完整 S0→S4 落在 60 fps 的帧预算内 |

窗口级验收单独跑，因为它需要真的窗口：

```sh
make ui-smoke    # 1000 张照片的库走一遍成品界面：网格、胶片条、缩略图、放大、撤销/重做、导出、预设、蒙版、星级、筛选
make ui-bench    # 1 万行占位网格的滚动 p99 + 放大帧耗时
```

## 命令

`make` 目标：

```
make app | ui-smoke | ui-bench     应用包与带窗口的验收
make verify                        所有不需要窗口的验收
make catalog | catalog-perf        目录验收（快）| 加 1 万行查询耗时
make info | cache | render | bench 针对自备 RAW 的一次性探针
make record                        重录 golden 基线（只在改动是预期的时候）
make whitepaper                    白皮书：docs/whitepaper/*.md → site/
```

`photonsctl` —— 同一套引擎，不带窗口，并且是每个动词的唯一实现：

```sh
.build/release/photonsctl info   path/to/file.dng
.build/release/photonsctl hash   path/to/file.dng --version 9.dng --ev 0.5
.build/release/photonsctl render path/to/file.dng --edit Tests/Fixtures/edit-push.json \
                                 --out /tmp/out.jpg --scale 0.25 --trace-stages
.build/release/photonsctl library create  ~/Pictures/New.photonslibrary
.build/release/photonsctl library import  ~/Pictures/New.photonslibrary ~/Pictures/2026-10 --mode reference
.build/release/photonsctl library assets  ~/Pictures/New.photonslibrary --rating 4 --json
.build/release/photonsctl preset  save    ~/Pictures/New.photonslibrary "Portrait" --asset 12 --groups light,curve
.build/release/photonsctl export  batch   ~/Pictures/New.photonslibrary --out /tmp/x --preset p.json --json
.build/release/photonsctl xmp     export  ~/Pictures/New.photonslibrary --out /tmp/x --embed
.build/release/photonsctl thumbs  ~/Pictures/New.photonslibrary --out /tmp/t --tier grid
```

不带参数运行 `photonsctl` 可以得到完整列表，包括验收门用到的 `decode`、`golden`、`histogram`、`detail`、`fixtures`。

## 实现方式

一条图、二十个阶段（7 个无条件 + 13 个由谓词触发），每个阶段边界都是一个缓存键：

```
S0    几何        方向、裁切、拉直、翻转、90°、透视、色差、文件自带镜头 warp
S1    场景线性    白平衡（解码参数）、黑电平偏移、曝光增益、黑白端点、高光恢复
S1.5  蒙版图集    每张启用的蒙版一条切片                          （条件）
S1.6  局部调整    蒙版内的曝光/色温/影调，在光里                    （条件）
S1.9  修复        修复/克隆，泊松边界匹配                          （条件）
S1.7  HDR 曲线    直方图轴上的四条曲线                             （总是）
S1.9  去雾        暗通道先验，场景线性                             （条件）
S3c   暗角        镜头暗角校正，跑在 S2 之前                        （总是）
S2    色调映射    高光 / 中间调 / 阴影 三段窗口                     （总是）
S2.5  对比        多尺度引导滤波残差，显示域                        （条件）
S3    色彩        自然饱和 / 饱和                                  （总是）
S3.4  黑白        单色 + 每色相混合                                （条件）
S3.5  局部色      蒙版的色相/饱和，显示域                           （条件）
S3.6  HSL         八个色带，OKLCh                                  （条件）
S3.6b 点颜色      一个采样色附近的窗口                              （条件）
S3.8  分级        阴影 / 中间调 / 高光，亮度窗口                     （条件）
S3.9  细节        纹理 / 清晰度 / 去噪                              （条件）
S3.10 锐化        USM + 边缘蒙版                                    （条件）
S3.7  颗粒                                                         （条件）
S4    显示        基色矩阵 + sRGB OETF + EDR headroom              （总是）
```

两条承重属性是被测试钉住的，不是假设：

- **只碰 S3 的滑杆不会重跑 S1。** 键按阶段算，不按文档算；`--trace-stages` 会打印哪些阶段真跑了、哪些来自缓存。
- **没碰过的控件逐字节不改变任何东西。** 条件阶段只在谓词成立时存在，所以加一张没有调整的蒙版、或一份 24 个 HSL 值全为 0 的文档，渲染结果与加入该功能之前逐像素相同。大多数 golden 的存在就是为了守住这一点。

细节（每个参数作用在哪个域、为什么在那个顺序、公式是什么）见[白皮书](https://chemharuka.github.io/photons/)。

## 目录结构

```
Sources/PhotonsCore/       解码、线性缓冲、RenderGraph、kernel（不依赖 AppKit）
Sources/PhotonsCatalog/    SQLite 目录、导入、缩略图、预设、元数据
Sources/PhotonsExport/     渲染 + 编码、批量导出、XMP
Sources/PhotonsUI/         AppKit/SwiftUI 外壳、检查器、画布、裁切、蒙版
Sources/PhotonsApp/        @main + AppDelegate + 菜单（很薄）
Sources/photonsctl/        零依赖的验收工具
Tests/                     四个测试目标、golden 基线、编辑 fixture
docs/                      决策、状态、XMP 映射、白皮书、任务规格
scripts/                   打包、ui-smoke、ui-bench、白皮书构建
local/                     不入库的会话工作区（笔记、探针、样本）
```

## 不做的事

不是「还没做」，而是已经决定不做，理由有记录：

- **HDR 合成与超分辨率。** 两者都需要马赛克，而 `CIRAWFilter` 只交出已经去马赛克的图。在这条管线上做这两件事没有诚实的办法。
- **DNG 导出。** ImageIO 能读 RAW、不能写 RAW；要输出 DNG 等于从零写一个 DNG 编码器。
- **自研去马赛克 / 降噪。** 这恰好是 Apple 那套栈真正更强的地方。
- **打印、幻灯片、地图、视频。** 一个照片工作流不需要变成发布套件。
- **导入时在 RAW 旁边写 `.xmp` sidecar。** 元数据从文件内嵌的 XMP 读；目录才是真值。

## 文档

- **[渲染白皮书](https://chemharuka.github.io/photons/)** —— 显示架构、处理架构、参数算法；源码在 [docs/whitepaper/](docs/whitepaper/)，`make whitepaper` 重建。
- [docs/STATUS.md](docs/STATUS.md) —— 项目现在到哪一步，以及背后的测量。
- [docs/architecture-decisions.md](docs/architecture-decisions.md) —— 每个选择为什么这样定，以及什么条件下它会是错的。
- [docs/xmp-mapping.md](docs/xmp-mapping.md) —— `crs:*` / `photons:*` 的映射与往返。
- [docs/collaboration.md](docs/collaboration.md) —— 这台机器怎么配置、工作怎么排队。
- [docs/tasks/](docs/tasks/) —— 每个功能一份规格。

## 许可

MIT —— 见 [LICENSE](LICENSE)。第三方声明：[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
