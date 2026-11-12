# PhotonsExtensions

可选的后处理扩展：**产出新文件**，不编辑当前打开的照片。第一次使用是 AI 降噪——软件调用它生成一个降噪后的 DNG，再把那个文件加入库。

与 `PhotonsCore` 的分工是有意划的：

- `PhotonsCore` 是每张照片都要走的解码/编辑/渲染路径。
- `PhotonsExtensions` 是一条**可选**的往返：读原始 mosaic → 交给外部模型/外部程序 → 写回一个新 DNG。
- 两者之间**没有依赖**。这个模块自己解析 TIFF/IFD、自己编 SOF3，不 import `PhotonsCore`。
  这样核心的解码路径怎么演进都不会波及它，核心也不必长出第二个图像写入器。

## 目录

| 目录 | 职责 |
|---|---|
| `HDR/` | 包围曝光合成：`HDRMergeClient.swift`（驱动外部 `hdrmerge-swift` 子进程）、`HDRMergeService.swift`（多帧 → 一张 CFA DNG，含命名/预检/错误词表） |
| `Denoise/` | AI 降噪那条路：模型推理（`AnselDenoiseClient` / `AnselDenoiseService`，走 GPL 子进程）＋ 把像素写回合法 DNG（`RawLosslessJPEG` / `DNGRawWriter` / `SourceDNG` / `SourceDNGDecode`）。详见下面「Denoise/」一节。 |

## HDR/ — 多帧包围曝光 → 一张 Bayer DNG

```swift
let service = HDRMergeService()                 // 或用 HDRMergeClient(executableURL:) 指定
guard service.isAvailable else { … }            // 二分：菜单项置灰，而不是等 15 秒后报错

// 可选预检：尺寸/CFA 相位是否一致
if let issue = try service.compatibilityIssue(frames) { … }

let outcome = try service.merge(frames) { line in print(line) }
// outcome.output       = …/L1030664-merged.dng（以最欠曝帧命名，紧挨源文件）
// outcome.width/height, .whiteLevel, .metadataFrom, .report
```

要点：

- **输出仍是 RGGB mosaic**（`PhotometricInterpretation = 32803`），不去马赛克；CFA 相位、黑/白电平、
  ColorMatrix、AsShotNeutral、XMP、OpcodeList、EXIF/GPS 全部从源帧继承。
- 默认 `bits = 16`、`headroom = 4`：容器上限 = 4 × 输入白电平，16 位里输入标尺逐位不变，顶上多出
  2 档高光（`WhiteLevel = 65535`）。要浮点精度就设 `bits = 32`（ImageIO 读 float CFA DNG 会拒收，
  这种给 darktable / RawTherapee 用）。
- **`compress = true` 用 SOF3 无损 JPEG**（`Compression = 7`，256×256 分块）：60 MP 一帧
  121.2 MB → **49.9 MB**，像素逐位不变。三个坑（与我们 `DNG/` 那套完全同源）写在
  `Vendor/hdrmerge-swift/Sources/HDRMergeCore/LosslessJPEGEncoder.swift` 顶部：
  SOS 选择子是 `Td << 4 | Ta`（写错则 libraw 能解、Core Image 全黑且报成功）、
  马赛克要拆成两个列交错分量（同一预测器只比同色样本）、边缘 tile 用重复行列而非补零。
  `bits = 32` 与压缩互斥——SOF3 只装整数样本，浮点 DNG 一律不压缩。
  Deflate（`Compression = 8`）更小但 Core Image 直接拒收，所以没有提供。
- **本模块不入库**。合并完调用 `onOutput` 把 URL 交回来，由持有 `PhotonsCatalog` 的一侧走
  `ImportService`（或用户手动导入）。这样 `HDR/` 保持零核心依赖，CLI、测试、未来的面板都能直接用。
- **合成靠外部可执行文件**：`hdrmerge-swift`（GPLv3，源码在 `Vendor/`）作为独立子进程运行，路径解析顺序为
  `$HDRMERGE_SWIFT` → `Contents/Resources/bin/hdrmerge-swift` → `/opt/homebrew/bin` → `/usr/local/bin`。
  没有任何 GPL 代码被链接进 Photons（GPLv3 §5 的 aggregate 条款）——
  GPLv3 源码以**嵌套包**形式放在 `Vendor/hdrmerge-swift/`（根 `Package.swift` 不引用它，
  `swift package describe` 里看不到任何 hdrmerge target），由 `scripts/build-hdrmerge.sh`
  单独 `swift build` 出可执行文件。工具缺失时 `isAvailable == false`，调用方据此把入口置灰。
  见 `VENDOR-hdrmerge-swift.md` 与 `~/Documents/GitHub/hdrmerge-swift/LICENSE-SCOPE.md`。

## Denoise/ — 把像素写回一个合法的 DNG

| 文件 | 职责 |
|---|---|
| `RawLosslessJPEG.swift` | SOF3（lossless JPEG）编码器：建表、位打包、`0xFF` 字节填充 |
| `DNGRawWriter.swift` | DNG 容器写入：tag 全量复制，只重写布局类 tag |
| `SourceDNG.swift` | TIFF/IFD 读取（IFD0、RAW SubIFD、EXIF、GPS、预览页） |
| `SourceDNGDecode.swift` | RAW mosaic 解码（未压缩 + SOF3），供改值后的往返验证 |

### 用法

```swift
// denoisedSamples: 行优先 uint16，width*height 个，CFA 顺序与源文件一致
let result = try DNGRawWriter.write(
    samples: denoisedSamples,
    width: w, height: h,
    from: originalURL,   // 元数据全部从这里复制
    to: outputURL
)
// result.byteCount / tileCount / compressedFraction
```

要读回 mosaic（例如先取像素再送模型）：`SourceDNG(data:).readMosaic(data:)`。

### 降噪：模型推理（GPLv3 子进程）

模型推理走 `ansel-denoise-swift`（`Vendor/ansel-denoise-swift/`，**GPL-3.0**），
与 `hdrmerge-swift` 同样处理：编译成独立可执行文件、由这里 `Process` 调用，**不链接**。

```swift
let client = try AnselDenoiseClient()               // 或 AnselDenoiseClient(executableURL:)
guard try client.protocolVersion() == 1 else { … }

let service = AnselDenoiseService(client: client, modelURL: modelURL)
var opts = AnselDenoiseOptions()                   // variant .quarter, tile 256, overlap 48
opts.cfa      = "rggb"
opts.noiseA   = [0.0004, 0.0003, 0.0004]           // Var = a·x + b，逐通道
opts.noiseB   = [3e-6, 1e-6, 1e-6]
opts.useGPU   = true                               // Metal，约快 30×

let out = try service.denoise(mosaic: normalized, width: w, height: h, options: opts)
// out.mosaic 是**降噪后的 mosaic**，配合上面的 DNGRawWriter 写出 DNG
```

**分工**：GPL 那一侧只知道「N 个 tile 的 float32 缓冲区」，不知道图像是什么；tiling、CFA 相位、
羽化拼接、反归一化全在这里（MIT）。这样上游更新时改动面很小。

#### 三个会导致「能跑但结果不对」的点

1. **σ 必须乘校准系数。** 默认 `sigmaScale = [2.82, 3.94, 2.96]`（R/G/B），等于 Ansel 的
   「×2（lifting-Haar 归一化）× 逐通道去马赛克衰减（1.41/1.97/1.48）」。漏掉它网络会认为噪声
   比实际小 3–4 倍、降噪严重不足——而且**大模型退化得比小模型更厉害**（实测 large 从 93% 掉到
   46%，看起来像「模型越大越差」）。降噪偏弱时先查 σ 量级，别先换模型。
2. **块边长必须是 16 的倍数**（网络下采样 4 次）。否则 bottleneck 坍成 1×1。
3. **重叠窗不能用「线性 ramp 乘四条边」。** 那样角点会被乘两次降为 0，四块交界处
   `acc/wsum` 变成 `0/0`，每 4 块交界一颗黑点。正确做法是一维 `sin²/cos²` 互补锥形窗再取外积
   （重叠带权重和恒为 1）。

模型权重不随仓库分发，按上游 `models/manifest.json` 的 sha256 拉取；变体 `quarter/half/large`
对应 0.48 M / 1.90 M / 7.59 M 参数，`quarter` 是默认（60 MP 全图约 78 s、σ 降 90%）。

### 三条不变量（改动这个模块前请先读）

1. **tag 默认全量复制。** `preserved` 从"源文件的所有 tag"开始，然后减掉 `layoutTags`。所以没被想到的 tag 是被**保留**的，而不是被漏掉。必须逐字节保住的包括黑电平/白电平、`ActiveArea`、`DefaultCrop*`、两套 ColorMatrix、两套 ForwardMatrix、`AsShotNeutral`、**`OpcodeList2`（暗角）**、**`OpcodeList3`（WarpRectilinear 镜头畸变）**、XMP、`DNGPrivateData`、EXIF/GPS 子 IFD、预览页。几何一旦改变（裁切/缩放），`ActiveArea`/`DefaultCrop*`/`OpcodeList*` 必须一起重算——只改像素值的写入器不能用来改尺寸。
2. **压缩用 `Compression = 7`（SOF3）。** Core Image 不接受 `Compression = 8`（Deflate）：`CIRAWFilter.nativeSize` 会返回 `0×0`、`outputImage` 为 nil。同一份 60 MP 数据：未压缩 121 MB / Deflate 86 MB / SOF3 57–80 MB。
3. **SOS 的选择子字节是 `Td << 4 | Ta`。** 写成 `[componentID, tableID]` 会把表号放进 AC 半字节，第二个分量就用 0 号表解码、熵流失步。**libraw 忽略这个选择子（按分量序号取表）所以能正确解出；Core Image 严格遵守，结果是一张"渲染成功"的全黑图。** 验收必须统计渲染出来的像素，而且两个解码器都要过。

### 测试

```bash
swift build --build-tests
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  -XCTest PhotonsExtensionsTests .build/out/Products/Debug/PhotonsExtensionsTests.xctest
```

> `swift test --filter` 在这台机器上会 `signal code 5` 崩溃并**执行 0 个测试**
> （输出 "Executed 0 tests, with 0 failures" 容易被误读成通过）。用上面的 xctest 直跑。

- `HDRMergeServiceTests` — 真跑 `hdrmerge-swift` 合成三帧 60 MP 包围曝光：产物是 CFA DNG、白电平 65535、
  RGGB 相位不变、ImageIO 可解、命名 `<最暗帧>-merged.dng`、取消不留半截文件、错误码稳定。
  工具或样例不在时跳过（不是失败）。
- `AnselDenoiseClientTests` — 真跑 `ansel-denoise-swift`：协议版本、缺可执行文件时的错误码、
  合成噪声图降噪后残差确实下降、小于一个 tile 的图靠补齐正常工作。工具/权重不在时跳过。
- `Denoise/` 那三个测试（`RawLosslessJPEGTests` / `DNGRawWriterTests` / `DNGRawWriterFullSizeTests`）。
  它们的 fixture 元数据全部取自真实 Leica SL3 文件
  （真 XMP、真 OpcodeList2/3），只有像素与几何是合成的——手写的假 XMP 会让 Core Image 直接拒收整个文件。
