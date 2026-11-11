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
| `DNG/` | 把像素写回一个合法的 DNG（AI 降噪那条路）——`RawLosslessJPEG.swift`（SOF3 编码）、`DNGRawWriter.swift`（容器写入，tag 全量复制）、`SourceDNG.swift` / `SourceDNGDecode.swift`。**这些文件在 `~/photons-wt/raw-dng` 分支里，尚未合并到本工作区**，所以 `Package.swift` 目前只编 `HDR/`。 |

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
  见 `Vendor/hdrmerge-swift/README-VENDOR.md` 与 `~/Documents/GitHub/hdrmerge-swift/LICENSE-SCOPE.md`。

## DNG/ — 把像素写回一个合法的 DNG

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

### 三条不变量（改动这个模块前请先读）

1. **tag 默认全量复制。** `preserved` 从"源文件的所有 tag"开始，然后减掉 `layoutTags`。所以没被想到的 tag 是被**保留**的，而不是被漏掉。必须逐字节保住的包括黑电平/白电平、`ActiveArea`、`DefaultCrop*`、两套 ColorMatrix、两套 ForwardMatrix、`AsShotNeutral`、**`OpcodeList2`（暗角）**、**`OpcodeList3`（WarpRectilinear 镜头畸变）**、XMP、`DNGPrivateData`、EXIF/GPS 子 IFD、预览页。几何一旦改变（裁切/缩放），`ActiveArea`/`DefaultCrop*`/`OpcodeList*` 必须一起重算——只改像素值的写入器不能用来改尺寸。
2. **压缩用 `Compression = 7`（SOF3）。** Core Image 不接受 `Compression = 8`（Deflate）：`CIRAWFilter.nativeSize` 会返回 `0×0`、`outputImage` 为 nil。同一份 60 MP 数据：未压缩 121 MB / Deflate 86 MB / SOF3 57–80 MB。
3. **SOS 的选择子字节是 `Td << 4 | Ta`。** 写成 `[componentID, tableID]` 会把表号放进 AC 半字节，第二个分量就用 0 号表解码、熵流失步。**libraw 忽略这个选择子（按分量序号取表）所以能正确解出；Core Image 严格遵守，结果是一张"渲染成功"的全黑图。** 验收必须统计渲染出来的像素，而且两个解码器都要过。

### 测试

```bash
swift build --build-tests
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest \
  .build/out/Products/Debug/PhotonsExtensionsTests.xctest
```

> `swift test --filter` 在这台机器上会 `signal code 5` 崩溃并**执行 0 个测试**
> （输出 "Executed 0 tests, with 0 failures" 容易被误读成通过）。用上面的 xctest 直跑。

- `HDRMergeServiceTests` — 真跑 `hdrmerge-swift` 合成三帧 60 MP 包围曝光：产物是 CFA DNG、白电平 65535、
  RGGB 相位不变、ImageIO 可解、命名 `<最暗帧>-merged.dng`、取消不留半截文件、错误码稳定。
  工具或样例不在时跳过（不是失败）。
- `DNG/` 那三个测试（`RawLosslessJPEGTests` / `DNGRawWriterTests` / `DNGRawWriterFullSizeTests`）
  随 `DNG/` 一起在 `raw-dng` 分支里。它们的 fixture 元数据全部取自真实 Leica SL3 文件
  （真 XMP、真 OpcodeList2/3），只有像素与几何是合成的——手写的假 XMP 会让 Core Image 直接拒收整个文件。
