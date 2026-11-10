<p align="center"><img src="Resources/AppIcon-legacy-1024.png" width="120" alt="Photons 图标"></p>

<h1 align="center">Photons</h1>

<p align="center">macOS 原生 RAW 工作流：导入文件夹、挑片、非破坏性显影、导出。用 Swift 写的，MIT 许可。</p>

<p align="center">
  <a href="https://chemharuka.github.io/photons/"><strong>白皮书</strong></a> ·
  <a href="docs/architecture-decisions.md">架构决策</a> ·
  <a href="docs/STATUS.md">项目状态</a> ·
  <a href="#构建与运行">构建</a>
</p>

Photons 自己不带 RAW 解码器。去马赛克、镜头校正、机器学习降噪这些跟相机强相关的事，交给 **Apple**：`CIRAWFilter` 调用系统里的 `RawCamera`。这之上全是我们自己写的：SQLite 目录、Metal 渲染图、蒙版、色彩管理、XMP 和导出。

这条边界怎么划的、为什么**故意**不链 LibRaw、Exiv2、libheif 或 lensfun，都写在 [docs/architecture-decisions.md](docs/architecture-decisions.md)。那里每条结论都有真实文件的实测，或者对系统框架的阅读做依据。

## 已经能做什么

1.0 之前项目动得很快。下面每一条都被 `make verify` / `make ui-smoke` 实际跑过，没有一条停在「计划中」。

**素材库** 是一个 `.photonslibrary` 包（SQLite/WAL）。导入可以按复制，也可以按引用；文件按内容哈希去重，导入中途被 `kill -9` 杀掉再重来，会续传到同一批素材，不产生重复。库里还有文件夹树、15 个维度的筛选栏（星级、旗标、颜色标签、相机、镜头、ISO、焦距、快门、光圈、月/日、扩展名、序列号、闪光、GPS）、星级/选用/排除/颜色标签、右键「移出照片库 / 移出并删除」、缺失文件查找、下次启动恢复上次的库，以及内容寻址的缩略图和 1920 px HDR 预览缓存。

**显影** 是一份非破坏性文档，带五个检查器工作区：

| 工作区 | 卡片 |
|---|---|
| 调整 | 白平衡（mired 滑杆，2000–50000 K）· 黑电平 · Light（曝光/对比/高光/中间调/阴影/白色/黑色 · 最高亮度）· Color（自然饱和/饱和）· 曲线（HDR 域控制点）· 开发（机身降噪/色彩降噪/锐化/细节/去摩尔纹）· 校正（色差 R/B · 暗角）· 细节（纹理/清晰度 · 去噪/去彩噪 · 锐化）· 效果（去雾 · 颗粒） |
| 变换 | 裁切（比例、翻转、九宫格、不出像素）· 校正（拉直 ±45°、画线拉直、引导线、透视 ±400）· 变换（90°、镜像、旋转） |
| 色彩 | HSL 八色带 · 点颜色（OKLCh 平台 + 肩）· 色彩分级（阴影/中间调/高光 × 色相/饱和/亮度）· 校准（阴影色调 + R/G/B 色相/饱和）· 黑白（每色相混合） |
| 蒙版 | 蒙版（画笔 · 线性渐变 · 径向渐变 · 颜色范围 · 亮度范围 · 语义/Vision 主体；每张蒙版有强度/透明度/羽化/refine/反相/混合与 12 个局部滑杆：曝光/对比/高光/阴影/白色/黑色/色温/色调/色相/饱和/纹理/锐化）· 修复（修复/克隆 + 红眼，跑在 S0 之前的源像素上） |
| 历史记录 | 时间线，点击回到任意快照；最新一行的 × 是撤销 |

另外还有**前后对比**（`\` 看解码原图，`Y` 分屏，`⇧Y` 换分割轴）、**预设**（从卡片挪到了顶级菜单）、可以分组的**复制/粘贴设置**（含蒙版，按短边锚定）。直方图固定在各工作区上方。

**导出** 覆盖 JPEG / HEIC / TIFF（8 或 16 位）/ PNG / AVIF。长边缩放但不放大，尺寸可以按百分比给，也可以按长边给，PPI 会写进文件，8 位下做抖动；色彩空间可选 sRGB 或 Display P3；质量可调；文件名模板 `{seq}-{name}`。批量导出逐张给结果，一个坏文件不会拖垮其余。XMP 能内嵌，也能写成 sidecar。HDR 是**任何格式的默认**：JPEG/HEIC 走增益图，TIFF/PNG 落 PQ 16 位，HLG 按 BT.2100 的绝对亮度。

这些都走同一个 `RenderGraph` 批处理，所以屏幕上的图和导出的文件是同一套算术。同一份文档在两个进程里渲染两次，得到同样的字节，这条有测试守着。

## 环境要求

- macOS 14 或更新。最新的 `RawCamera` 解码版本要求最新的 macOS；本仓库在 macOS 27 / Xcode 27 / Swift 6 上构建和测量。
- 第三方依赖只有一个，由 SwiftPM 解析：[GRDB](https://github.com/groue/GRDB.swift) 7（MIT），用来接 SQLite。见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
- 仓库里没有 `.xcodeproj`。Metal kernel 当**资源**发布，启动时由 `Metal.framework` 编译。原因是 SwiftPM 没有可靠的 `.metal` 构建步骤。
- 测试素材得自己备一张 RAW，仓库不附带照片：`PHOTONS_TEST_RAW=…` 或 `make verify RAW=…`。

## 构建与运行

```sh
make app
open .build/Photons.app
```

`make app` 跑 release 构建、打包、ad-hoc 签名，产物落在 `.build/Photons.app`。

首次启动走 文件 ▸ 打开库… 新建一个 `.photonslibrary`，再用 ⇧⌘I 导入文件夹。缓存（解码后的线性缓冲、缩略图）按库分开，放在 `~/Library/Caches/Photons/<library-hash>/`。

## 验收门

```sh
make verify
```

一条命令做完：构建 + 单元测试 + L1/L2/L3 + 目录验收 + bench。

| 层级 | 证明什么 |
|---|---|
| 单元测试 | 2 950 个测试方法（Core 1 070 · Catalog 213 · Export 170 · UI 1 497，按 `swift test list`）：解码契约、渲染图、蒙版、目录、XMP、导出、界面布局 |
| **L1** 确定性 | 两个独立进程解码同一文件，得到同一摘要 |
| **L2** golden | 按 OS 版本记录的像素摘要，把「系统变了」和「我们改坏了」分开 |
| **L3** 图 | 中性（锐化归零）== 解码 + sRGB OETF；只改 S3 会跳过 S0/S1/S2；编辑敏感性；渲染 golden |
| 目录 | 针对真实库的 9 项验收（`Tests/catalog-acceptance.sh`）：去重、幂等重导入、`kill -9` 后续传、移动、离线不删行、schema 前向守卫、迁移前快照、查询耗时、真实 RAW 元数据 |
| bench | 视口尺寸下完整 S0→S4 落在 60 fps 的帧预算内 |

窗口级验收要单独跑，因为它需要一个真窗口：

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

`photonsctl` 跑同一套引擎，但不带窗口。每个动词只有这一个实现：

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

`photonsctl` 不带参数跑，会列出全部命令，包括验收门用的 `decode`、`golden`、`histogram`、`detail`、`fixtures`。

## 实现方式

整条流水线是一张图，二十个阶段（7 个无条件 + 13 个由谓词触发）。每个阶段边界都是一个缓存键：

```
S1.9  修复        修复 / 克隆 / 红眼，跑在源像素上、S0 之前            （条件）
S0    几何        方向、裁切、拉直、翻转、90°、透视、色差、文件自带镜头 warp
S1    场景线性    白平衡 3×3、黑电平偏移、曝光增益、黑白端点、高光恢复
S1.5  蒙版图集    每张启用的蒙版一条切片                              （条件）
S1.6  局部调整    蒙版内的曝光/色温/影调，在光里                      （条件）
S1.7  HDR 曲线    直方图轴上的四条曲线                                 （总是）
S1.9  去雾        暗通道先验，场景线性                                 （条件）
S3c   暗角        镜头暗角校正，跑在 S2 之前                            （总是）
S2    色调映射    高光 / 中间调 / 阴影 三段归一化高斯 + 画面天花板       （总是）
S2.5  对比        增益域全局幂律，显示域                                 （条件）
S3    色彩        自然饱和 / 饱和                                      （总是）
S3.4  黑白        单色 + 每色相混合                                    （条件）
S3.5  局部色      蒙版的色相/饱和，显示域                               （条件）
S3.6  HSL         八个色带，OKLCh                                      （条件）
S3.6b 点颜色      一个采样色附近的 OKLCh 平台 + 肩                      （条件）
S3.8  分级        阴影 / 中间调 / 高光，亮度窗口                         （条件）
S3.9  细节        纹理 / 清晰度 / 去噪                                  （条件）
S3.10 锐化        USM + 边缘蒙版（默认 50 / 2.0）                        （条件）
S3.7  颗粒                                                             （条件）
S4    显示        基色矩阵 + sRGB OETF + EDR headroom                  （总是）
```

有两条性质由测试钉住，不靠假设：

- **只碰 S3 的滑杆不会重跑 S1。** 缓存键按阶段算，不按文档算。`--trace-stages` 会打印哪些阶段真跑了、哪些来自缓存。
- **没碰过的控件逐字节不改变任何东西。** 条件阶段只在谓词成立时才存在。所以加一张没调整过的蒙版，或者来一份 24 个 HSL 值全为 0 的文档，渲染结果跟加这个功能之前逐像素相同。大多数 golden 就是为了守住这一条。

> 有一个例外：314 之后**锐化的静止值是 50**，S3.10 就对每个文档都存在，默认画像是「解码 + 一点 USM」。所以 `make verify` 的 L3「中性 == 解码 + OETF」只在**锐化归零**的文档上成立。另外十二个条件阶段照旧严格按谓词走。

每个参数作用在哪个域、为什么排在这个顺序、公式长什么样，见[白皮书](https://chemharuka.github.io/photons/)。

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

下面这些不是「还没做」，是已经决定不做，理由都有记录：

- **HDR 合成与超分辨率。** 两件都要在马赛克上做，可 `CIRAWFilter` 交出来的图已经去过马赛克。在这条管线上做没有诚实的办法。
- **DNG 导出。** ImageIO 能读 RAW、不能写 RAW；要输出 DNG，等于从零写一个 DNG 编码器。
- **自研去马赛克 / 降噪。** 这正好是 Apple 那套栈真正更强的地方。
- **打印、幻灯片、地图、视频。** 一个照片工作流不需要长成发布套件。
- **导入时在 RAW 旁边写 `.xmp` sidecar。** 元数据从文件内嵌的 XMP 读，目录才是真值。

## 文档

- **[渲染白皮书](https://chemharuka.github.io/photons/)** 讲显示架构、处理架构、参数算法；源码在 [docs/whitepaper/](docs/whitepaper/)，`make whitepaper` 重建。
- [docs/STATUS.md](docs/STATUS.md) 记录项目现在到哪一步，以及背后的测量。
- [docs/architecture-decisions.md](docs/architecture-decisions.md) 解释每个选择为什么这样定，以及什么条件下它会是错的。
- [docs/xmp-mapping.md](docs/xmp-mapping.md) 列出 `crs:*` / `photons:*` 的映射与往返。
- [docs/collaboration.md](docs/collaboration.md) 说这台机器怎么配置、工作怎么排队。
- [tools/wb-calibrate/](tools/wb-calibrate/) 合成 RAW 图卡：用固定刺激体检 RAW 解码器的中性点/颜色/取向。
- [docs/tasks/](docs/tasks/) 每个功能一份规格。

## 许可

MIT 许可，见 [LICENSE](LICENSE)。第三方声明：[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
