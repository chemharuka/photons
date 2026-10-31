# 2 显示架构：画布、缓冲、渲染

这一章回答一个问题：**一块解码出来的线性缓冲，是怎么变成屏幕上那张图的？** 答案分四层：尺寸（画布与内容）、坐标（谁贴在谁上面）、缓冲（像素放在哪、放几份）、渲染（哪些 pass 跑、什么时候跳过）。最后两节讲显示编码与帧预算。

## 2.1 画布：三个尺寸，不是一个

一张照片在屏幕上涉及三个不同的像素网格，混用其中任意两个都会得到「图被拉扁」或「1:1 不 1:1」：

| 名字 | 定义 | 谁决定 |
|---|---|---|
| **源尺寸** | 解码缓冲的正立尺寸（EXIF 方向已应用） | 文件 + 解码器 |
| **内容尺寸** | 裁剪后的照片尺寸 × `RenderOptions.scale` | 文档的几何 + 本次渲染的缩放 |
| **画布尺寸** | 实际要画的像素面（视口 / drawable） | 窗口，或导出时的内容本身 |

屏幕上，内容通常小于画布：照片按适应比例居中，四周留黑边（letterbox）。黑边**不是**图层颜色，也不是着色器算出来的——S2 与 S4 在内容矩形之外直接写 `float4(0)`，present pass 的照片 quad 根本不覆盖那些像素，画布的 clear color（`#0F0F0F`）透出来（`Sources/PhotonsCore/CanvasPresenter.swift:307`、`Sources/PhotonsCore/Kernels/s2_tone_map.metal:44`）。这条设计有一个可测的后果：直方图只统计内容矩形，黑边永远不会被当成「暗部像素」。

**画布不总是裁剪矩形。** 拉直或透视之后，裁剪框在画面里变成一个转过的矩形，渲染的画布是它的**包围盒**：`CropMath.canvasSize(...)`（`Sources/PhotonsCore/EditModel.swift:1111`）。所以一张 9° 拉直的照片，画布比裁剪框大，照片在画布里居中；「输出尺寸」这个读数必须用 `canvasSize` 而不是裁剪框尺寸，否则读数会比屏幕上的图小一圈。

**1:1 不是裁剪。** 放大到 100 % 时，渲染的仍然是整幅画面，只是取其中一个窗口：`RenderOptions.outputWindow`，单位是**内容像素**，坐标系是整幅输出的网格（`Sources/PhotonsCore/RenderGraph.swift:58`）。用裁剪冒充 1:1 会有两个立刻可见的错：拉直角在裁剪空间里转，窗口的投影与整帧差约 0.29 %；暗角与蒙版羽化按窗口归一，1:1 时它们的物理尺寸会缩水（同文件 `:67`）。

> 画布尺寸是渲染的入参，不是结果的属性。`PresentRequest` 把画布尺寸和 quad 一起带着走，present 时若 drawable 与请求的画布不一致，这一帧在拿 drawable **之前**就被拒绝——拿一个不属于它的 drawable 会花掉一次 vsync，在拖动里就是「果冻」（`CanvasPresenter.swift:418`）。

## 2.2 坐标：谁贴在谁上面

一条渲染链上有四种矩形，换算关系只有一条仿射：

```
uv = (u0, v0) + (canvasX / canvasW, canvasY / canvasH) · (du, dv)
```

`PresentWindow` 就是这四个数 `(u0, v0, du, dv)`（`CanvasPresenter.swift:22`）。它描述的是「画布上的这一点，读纹理的哪里」，而不是「纹理有多大」——所以同一个窗口可以贴在一张比画布大的纹理上（缩小显示），也可以贴在一张更小的纹理上（放大显示）。

`FramePlacement` 补上另一半信息（`CanvasPresenter.swift:165`）：

- `region`：这张画布大小的帧纹理，覆盖了整幅照片的哪一块（1:1 窗口时是九分之一，适应时是全部）；
- `rect`：照片在这张纹理里的矩形（letterbox 之后，纹理里有一部分是 0）。

两个结构合起来，才能回答「这张纹理的某个像素，对应整幅照片的哪里」，背景纹理就是靠这个映射把画布上照片没盖住的部分填成照片自己的低分辨率延续，而不是灰块（`PresentWindow.onWholePicture`，同文件 `:71`）。

**present 只画两个 quad。** 先画整幅低分辨率背景，再画照片本身；画家顺序即合成，不开混合、不用深度缓冲，后画的覆盖先画的（`CanvasPresenter.swift:539`）。分成两个 draw 而不是一个带分支的着色器，是因为 GPU 不能谓词化纹理取样：分支里的取样照样要付带宽。

## 2.3 缓冲：像素放在哪、放几份

### 解码缓冲

`LinearImage` 是 `Float16` 的 RGBA，色彩空间标为 `extendedLinearSRGB`，行序自上而下（`Sources/PhotonsCore/LinearImage.swift:122`、`Sources/PhotonsCore/LinearImageStore.swift:9`）。方向不烘进缓冲：解码器交出的行可能还是文件声明的方向，`oriented()` 在进入 S0 之前做一次拷贝——旋转一次渲染，而不是重新解码一次（`LinearImage.swift:156`）。

### 解码阶梯

同一张照片会有两档缓冲（`Sources/PhotonsCore/RAWDecoder.swift:1038`）：

| rung | 用途 | 相对像素 | 60 MP 文件的内存 |
|---|---|---|---|
| `0.5` | 适应视图的第一帧 | 1/4 | 约 120 MB |
| `1.0` | 1:1 及更高倍率 | 1 | 约 482 MB |

规则只有两条：同 `(identity, scale)` 命中就复用；**高的一档落地时释放低的一档**（同文件 `:1026`）。后者让稳态内存回到「一张缓冲」而不是两张，也解释了为什么「适应 → 1:1 → 适应 → 1:1」只解码两次而不是四次。

### 磁盘缓存

解码结果的磁盘缓存键是 `DecodeCacheKey.digest`：文件 SHA-256、解码器版本、曝光、缩放、草稿标志、色彩空间、解码配方、细节参数、镜头剖面（`Sources/PhotonsCore/LinearImageStore.swift:24`）。白平衡字段仍留在键里，但自 143 起解码器不读它——像素与文档的白平衡无关，键里的那一项只是为了旧缓冲的命名兼容（`Sources/PhotonsCore/RAWDecoder.swift:102`）。配方号 `v3-lens` 不是装饰：`v1` 的缓冲曾经整体上下镜像，`v2` 修的就是它，所以老缓冲**必须**因为配方号变化而失效（同文件 `:9`）。键里没有像素哈希——对 60 MP 做哈希比解码还贵。

### 中间纹理与副产物

- 每个 stage 的输出是一张画布尺寸的 `rgba16Float` 纹理；缓存的粒度就是这张纹理（第 2.4 节）。
- 蒙版图集（S1.5）是一张画布尺寸的覆盖率纹理，一张蒙版一个通道/切片；局部调整的阶段读它，而不重新算形状（`Sources/PhotonsCore/Masks.swift`）。
- 少量 1×1 的「统计纹理」：去雾的 airlight `A` 就是一张 1×1 纹理，apply pass 在 GPU 上取样，不读回 CPU（`RenderGraph.swift:199`）。
- 直方图：默认在**缩略图尺度**（约 0.58 Mpx）整幅渲染后测量；帧内测量则是对 S4 之前的纹理做固定步长的网格取样（256 长边 ≈ 0.29 MB），两者域相同，只差采样误差（`RenderGraph.swift:107`、`:123`）。

## 2.4 渲染：图、键、脏组、队列

### 一张图

`RenderGraph.render(edit:options:)` 是唯一入口（`RenderGraph.swift:1982`）。它把文档与选项折成一份 `Plan`（画布、内容、窗口、S0 的快速路径），然后按 `RenderStage.pipeline(...)` 给出的阶段列表走：每个阶段读上一张纹理，写下一张；条件不成立就整段跳过，而不是「跑一遍再乘 0」（`Stage.swift:204`）。

### 键是链，不是集合

每个阶段有自己的键材料：S1 是几何键 + 黑电平/曝光/白平衡/高光恢复；S3.6 是 24 个 HSL 数；S3.10 是四个锐化数（`Sources/PhotonsCore/EditModel.swift:1957`、`:2451`）。链式组合：

$$
K_i = H\left(K_{i-1} \,\|\, M_i\right)
$$

因此「链尾相等」蕴含「整条链相等」；`compositeKey` 把链尾与环境的两个后缀（tiling、语义蒙版）拼起来，一次比较就能跳过一次完整的走图（`RenderGraph.swift:1925`）。条件 stage 被跳过时，它的链接**整条不写**，而不是写一个中性值——这是中性零变化能逐字节成立的原因（`Stage.swift:15`）。

### 脏组

历史记录按**组**比较：`light`、`curve`、`color`、`masks`、`effects`、`geometry`……浮点容差 `1e-6`，蒙版 `1e-5`（`docs/STATUS.md`）。拖动一个滑杆只把对应组标脏，下一次渲染只需要从该组最早的阶段重跑。文档级相等不参与这个判断；否则「改了一个像素的暗角」会重跑解码。

### 两条队列

解码与渲染分属两条队列（`Sources/PhotonsCore/DecodeQueue.swift`、`docs/STATUS.md` 第 10 轮）：

- 解码队列串行、同键去重、可取消；解码在锁外进行（`RAWDecoder.swift:1032`）。
- 渲染队列只使用**已驻留**的 rung；新窗口到达时合并到下一帧，不排队。
- 全屏解码期间平移 20 帧从 5.8 s 串联降到 render p50 4.0–4.5 ms（`docs/STATUS.md`）。

### present

present 是一个 render pass：清成 `#0F0F0F`，按次序画背景 quad 与照片 quad，`framebufferOnly = true`（读不回来，也对——屏幕上的东西不该被 CPU 采样）。着色器只做一件事：按窗口取样，并按目标存储做编码↔线性的转换（`CanvasPresenter.swift:547`）。

## 2.5 显示编码与 HDR

S4 是管线里唯一写「显示值」的地方，只有四步（`Sources/PhotonsCore/Kernels/s4_display.metal:38`）：

1. 基色矩阵：工作基色（线性 Rec.2020）→ 输出基色（sRGB / Display P3 / Rec.2020）；
2. **矩阵之后**取 `max(v, 0)`；
3. `min(v, headroom)`；
4. sRGB 分段 OETF。

第 2 步的位置是修出来的：`Rec.2020 → sRGB` 的最小系数是 `−0.5876`，纯 Rec.2020 绿会算出 `R = −0.5876`；如果先钳再乘矩阵，这个负数会以「负的光」进入 16 位 drawable，直方图把它放到轴的负区（同文件 `:16`）。测试 `testS4ClampsAfterThePrimariesMatrix` 会在这一行被挪回矩阵之前时变红。

**两条存储路径**，由图层能接受什么决定（`CanvasPresenter.swift:340`）：

| 路径 | 像素格式 / 色彩空间 | 取值 | 何时 |
|---|---|---|---|
| `linear16` | `rgba16Float` + `extendedLinearDisplayP3` | 线性光，可以 > 1 | 首选，EDR 前提 |
| `srgb8` | `bgra8Unorm` + sRGB | 显示编码，钳在 `0…1` | 首帧拿不到 16 位 drawable 时降级一次，之后不再重试 |

**headroom 是乘数，不是差值。** AppKit 报的 `maximumExtendedDynamicRangeColorComponentValue` 是「SDR 白的倍数」，所以给 S4 的上限是 `1 + (max − 1)`，再夹到 `[1, 16]`（`Sources/PhotonsUI/DisplayHeadroom.swift:59`）。写成 `max − 1` 会把 1.2 变成 0.2、钳回 SDR，让 EDR 在唯一支持它的屏幕上变成空操作。

三个必须知道的边界：

- 屏幕亮度变化**没有通知**。macOS 不发「亮度变了」，只改 `maximumEDR` 属性；所以上限是**每次问**，不是启动时缓存（`DisplayHeadroom.swift:129`）。
- 8 位图层不能承载 > 1 的值，所以 `layerAcceptsEDR == false` 时，headroom 必须在渲染**之前**降回 1，而不是看到颜色不对再降（同文件 `:66`）。
- 导出永远是 `headroom = 1`；HDR 导出走 S4 的线性出口（`s4_display.metal:65`），因为增益图需要的是 HDR/SDR 的线性比，不是编码值。

## 2.6 帧预算、时序与故障

**预算。** 60 fps 是 16.7 ms。当前 release 构建在 4.10 Mpx 画布上全链 p95 为 **4.7–6.4 ms**；平移 3.95–5.5 ms；进入 1:1 的首帧在 0.5 档已驻留时 **24–26 ms**（含一次全分辨率解码时是 526–744 ms，`docs/STATUS.md`）。这些数字会随代码变，本文只记录它们对应的测量口径：`--viewport 2560x1600`、`--iterations 60`。

**数字不会每帧都测。** 直方图在手势中不采集，停手 60 ms 后用一帧专用测量帧补上：平移额外成本从 +8.2 ms 降到约 0（`docs/STATUS.md` 已知待修 1）。

**故障模式**（都是显式的，不靠重试掩盖）：

| 现象 | 实际发生的事 | 位置 |
|---|---|---|
| 无 drawable（无头会话/窗口关闭） | present 返回 false，记 `lastFailure`，不重试 | `CanvasPresenter.swift:454` |
| 16 位 drawable 被拒 | 降级到 8-bit sRGB **一次**并记住；不降的话每帧都失败 | `:447` |
| 画布尺寸与 drawable 不符 | 该帧被拒，`droppedStaleFrameCount += 1` | `:435` |
| 1:1 窗口边缘的羽化/引导滤波 | 半径按整帧算，边界按窗口钳制，最多 `feather + guided` 像素宽 | `RenderGraph.swift:80` |

---

到这里，屏幕上的图有了来处。下一章把镜头拉远：这些 pass 为什么按这个顺序排，每个参数为什么属于某个域。
