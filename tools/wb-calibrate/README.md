# tools/wb-calibrate — 合成 RAW 图卡与解码器体检

**这套工具不参与 `swift build`，不需要任何 Swift 包依赖。** 它只在需要重建图卡或复核解码器时手工跑；
`Tests/PhotonsCoreTests/ChartCalibrateTests.swift` 默认 skip，打开 `PHOTONS_CHART_CALIBRATE=1` 才读仓库里的
`chart256.dng`（夹具已固化，测试时不依赖 `dnglab`）。

用途：Apple 的 RAW 解码器会随 macOS 大版本改变中性点/颜色。这里有一张**每个格子的刺激都已知**的合成图卡，
配一组机器判据。升级前后各跑一遍，漂了多少，输出里直接是数字。

## 依赖

| 依赖 | 什么时候要 | 缺了会怎样 |
|---|---|---|
| `dnglab` | 重建图卡（造 Apple 能解的容器） | 脚本本身不调用它；命令直接 `command not found`，README 给安装行 |
| Python 3 + `numpy` / `pillow` / `tifffile` | 造图、判 PNG | 每个脚本 `sys.exit("missing Python dependency (… ) — pip install …")` |
| `exiftool` | 从真机 DNG 读颜色矩阵/机型 | `SystemExit` 点名缺 exiftool，不抛栈 |
| `swift`（macOS 自带工具链） | `probe.swift` / `probe2.swift` | 系统级错误 |

```bash
brew install dnglab exiftool
python3 -m pip install numpy pillow tifffile
```

## 三条命令（全链复跑）

```bash
REAL=$HOME/Desktop/test/L1030433.dng          # 你自己的一张真机 DNG
PY=python3
mkdir -p /tmp/wbc

# 1. 真机 DNG → 合成 512×512 / 256 格 raw → Apple 能解的容器
$PY tools/wb-calibrate/make_chart256.py "$REAL" /tmp/wbc/chart256-raw.dng
dnglab convert -c lossless -f /tmp/wbc/chart256-raw.dng /tmp/wbc/chart256.dng

# 2. 用 Apple 的解码器解出来（6500 K、tint 0），落一张 8-bit sRGB PNG
swift tools/wb-calibrate/probe2.swift /tmp/wbc/chart256.dng 6500 /tmp/wbc/decoded.png

# 3. 机器判据：全绿 exit 0，任一违反打印违反项并 exit 1
$PY tools/wb-calibrate/verify_chart.py /tmp/wbc/decoded.png
```

只想复核当前 macOS 解码器、不想重建：直接跳到第 2 步，把文件换成仓库里的
`tools/wb-calibrate/chart256.dng`。

## 为什么手写 DNG 不行（实测，别重复试）

`CIRAWFilter` 要的是**相机写出的完整 DNG**，不是"带 DNG 标签的 TIFF"。真实文件 207 个标签，
手写的 33 个；缺 profile/opcode/noise 块、tile 结构、厂商私有块。换机型名骗不过：校验发生在机型识别之前。

| 文件 | `CIRAWFilter` |
|---|---|
| 手写 CFA DNG（33 标签，`Make/Model/UniqueCameraModel = LEICA SL3`） | `supportedDecoderVersions [None]`、`nativeSize (0,0)`、`outputImage nil` |
| 手写 **LinearRaw** DNG | 同上，被拒 |
| 只克隆真机 46 个元数据标签、不压缩像素 | 同上，被拒 |
| `dnglab convert -c uncompressed` 写出的容器 | ✅ `nativeSize 9520×6336`、`decoderVersion 8.dng` |
| **dnglab 容器 + 注入合成图案** | ✅ 解码成功，图案逐格可分层 |
| 手写图卡 → `dnglab convert -c lossless` 重包容器 | ✅（本仓库 `chart256.dng` 就是这条链） |

两条可行路线：

- `make_chart256.py` / `make_patch_dng.py` 先写 raw TIFF/DNG，再由 `dnglab convert` 重写容器；
- `inject_raw_ifd.py` 在 `dnglab convert -c uncompressed` 的容器里直接替换 raw strip 字节（元数据一字不动）。

注入前必须 `-c uncompressed`：dnglab 默认写 lossless-JPEG tile，改字节要重新编码 LJPEG。

## 图卡（`chart256.dng`）

512×512 CFA，16×16 = **256 格 × 32 px**，每格取中心 8×8：

- 行 0–1：32 级中性灰阶（sRGB 0.04 → 0.96）；
- 行 2–15：224 个色块 = 8 色相 × 4 饱和 × 7 明度；
- CFA 布局 RGGB；`BlackLevel 0`、`WhiteLevel 16383`。

两条硬约束（都实测过）：

1. **中性色在相机 raw 里不是 R=G=B，而是正比于 `AsShotNeutral`**。判别实验（64×64 单色 CFA，6500 K 解码）：
   统一 raw `8000/8000/8000` → 中心 `255/68/178`（品红，R 已削顶）；按 ASN 比例 `3371/8000/4692` →
   中心 `209/186/130`。解码器乘 `1/AsShotNeutral`，所以 raw 中性必须按 ASN 写。
2. **全图统一比例，不许逐格归一化**：逐格归一化会把亮度台阶抹平，相邻块变成同一色。

当前夹具：152,178 B，`CIRAWFilter` 接受（`nativeSize 512×512`、`decoderVersion 8.dng`），
无 `OpcodeList1/2/3` —— 比"克隆真机容器"干净：真机那份带 `OpcodeList3` + 三个 `OpcodeList2`，
会让灰阶解码不单调。

## 颜色：只接受 A 光源矩阵，白点靠反解 ASN

真机 profile 有两组矩阵：`CalibrationIlluminant1 = A(17) → ColorMatrix1`、
`CalibrationIlluminant2 = D65(21) → ColorMatrix2`。两条"教科书修法"都实测不可用：

| 做法 | 结果 |
|---|---|
| (a) 写两组矩阵（D65 + `ColorMatrix2`） | Apple **拒收**：`nativeSize 120×120`、`supportedDecoderVersions [None]`，退回缩略图 |
| (a') 只留 `ColorMatrix2`、标 D65 | 同样拒收 |
| (a'') 保留 A 矩阵、只把 `CalibrationIlluminant1` 改成 D65 | 同样拒收 → 触发拒收的是 **illuminant 代码**，不是矩阵数值 |
| (b) 保留 A 矩阵，验收温度设 2856 K | 能解码，但中性 32 格色偏 **132/255**，比 6500 K 的 36 更差 |

所以唯一被接受的组合是 **`CalibrationIlluminant1 = A(17)` + `ColorMatrix1`**。颜色问题不在矩阵，在白点：
机身的 `AsShotNeutral = 0.421399 1 0.586483` 与机身矩阵不自洽（`M1 · ASN` 的 X 为负：
`(-0.1665, 1.1537, 0.4449)`）。解码器按 `1/ASN` 做白平衡、矩阵按 A 光源定白，两边错开，
6500 K 解出来中性带 G 通道整体偏高（0.55 灰阶处 `104/127/103`，色偏 max 36/255）。

采用的做法：保留 A 矩阵，**反解 `AsShotNeutral`**，让它等于"这个解码器在 6500 K 真正当中性"的相机空间白。
结果写进 `asn_calibration.json`（`0.51828 / 1 / 0.735308`），`dngmeta.asn_effective()` 给造图脚本读取。
**硬约束 ① 没被推翻**：中性 raw 仍 ∝ ASN，改的是"哪个 ASN 才是解码器认的白"。

为什么锚在 6500 K：温度扫描的极小值正好落在那里（中性 32 格最大色偏）：

```
   T     2856  3200  4000  4500  5000  5500  6000  6500  7000  8000  9000  10000
spread 140.0 125.0  89.0  65.0  44.0  27.0  12.0   1.0  11.0  27.0  39.0   48.0
```

另一条坑：原设计色块明度到 0.97，解码后 8 格某通道削到 255；明度轴改成 `0.22 + 0.10·i`
（上限 0.82）后过曝 0 格，中性灰阶仍到 0.96。

## 取向：identity，偏移 0

用 4×4 标记图（每格一个互不相同的灰阶；`(0,0)` 纯黑、`(0,1)` 纯白、`(1,0)` 0.85，
于是 `x=128` / `y=128` 处各有一条硬边）解码后按**秩**对齐设计：

```
  design→decoded transform: identity
  rank match: exact (distinct levels in design 16/16)
  vertical edges   at x = [128, 256, 384] → dx per edge [0, 0, 0]
  horizontal edges at y = [128, 256, 384] → dy per edge [0, 0, 0]
```

四条都定住：

1. **无 x 镜像、无 y 翻转、无转置** —— 8 个对称变换里只有 `identity` 命中 16/16 个秩。
2. **像素偏移 0** —— 三条竖边、三条横边都精确落在 128/256/384，`dx = dy = 0`。
   16 px `DefaultCropOrigin` 的担忧在本文件上不成立（我们的容器 `DefaultCropOrigin 0 0`、
   `DefaultCropSize 512 512`）。
3. PNG 行序 = CFA 文件行序（第 0 行就是文件第 0 行）；`probe2.swift` 的 CGContext 绘制不需要再翻 y。
4. `primaries` 模式复核四角：`(0,0)=164/0/24`、`(0,3)=132/230/0`、`(3,0)=0/0/0`、`(3,3)=246/246/245`。

图卡本身也钉同一件事：中性坡必须行优先，当前夹具实测
`TL 0 < TR 94 < BL 108 < BR 244`，最暗格 `(0,0)` —— x 镜像、y 翻转、转置、整格 crop 偏移
都会破其中至少一条。每格中心 8×8 的 σ = 0.00；格宽 32 px，偏移超过约 12 px 就会让 8×8 采样跨到邻格，
σ 立刻变大。`verify_chart.py` 把这两条都做成断言。

## 机器判据（`verify_chart.py`）

```
usage: verify_chart.py <decoded.png> [--grid 16] [--inner 8] [--quiet]
```

只看 PNG，不看元数据。七条断言，任一失败 exit 1 并打印违反项：

1. 256 格全部找到（网格整除、格大于采样窗）；
2. 中性 32 格：`max(R,G,B) − min(R,G,B) ≤ 8`，亮度单调不减（允许 −1 抖动）；
3. 224 个色块量化到 8-bit 三元组后 ≥200 个互不相同；
4. 每格中心 8×8 的 σ ≤ 2；
5. 任一通道 =255 的格 ≤ 2；
6. 取向：`TL < TR < BL < BR`、最暗格 `(0,0)`、最亮中性格是第 32 格；
7. 色相顺序：224 格分成 8 组 × 28 格，组间色相严格前进且 8 步绕满 360°（只判顺序，不判绝对值——
   相机矩阵会把设计 135° 转到实测 93°）。

当前夹具全绿：色偏 max 1（patch 16）、亮度 `0 → 244` 零下降、色块 **219/224** 互异、σ 0.00、过曝 0、
色相步长 `43/37/22/78/52/18/46/64`（和 360°，组内离散 ≤18°）。

**反证**（同一命令必须能判红）：

```bash
$PY - <<'PY'
from PIL import Image
im = Image.open("/tmp/wbc/decoded.png")
for name, t in [("flipud", Image.FLIP_TOP_BOTTOM), ("fliplr", Image.FLIP_LEFT_RIGHT),
                ("rot90", Image.ROTATE_90)]:
    im.transpose(t).save(f"/tmp/wbc/{name}.png")
PY
$PY tools/wb-calibrate/verify_chart.py /tmp/wbc/flipud.png --quiet; echo $?   # 1
```

实测三张都 exit 1：y 翻转 → 最暗格跑到 `(3,7)`、色偏 max 150；x 镜像 → 最暗格 `(0,14)`、
29 个负台阶；转置 → 色相步长和 `2160°`。

## 夹具与重建

`tools/wb-calibrate/chart256.dng`（152,178 B）是用 `L1030433.dng`（LEICA SL3）经
`make_chart256.py` → `dnglab convert -c lossless` 生成的成品，直接提交当夹具；
测试与 `verify_chart.py` 只读它，**不依赖 `dnglab`、不依赖真机 DNG**。

重建会用到真机 DNG 里的 `Make/Model/ColorMatrix1/ColorMatrix2/CalibrationIlluminant1/2/AsShotNeutral`，
所以真机 DNG 不入库（`.gitignore` 里 `*.dng`，本夹具用一条 negation 例外）。换机身重建时，
重建前先确认 `asn_calibration.json` 与目标机身匹配，否则中性带会带色偏。

## 文件

| 文件 | 作用 |
|---|---|
| `README.md` | 本文：依赖、结论、取向/颜色数字、判据 |
| `chart256.dng` | 256 格图卡成品夹具（152,178 B） |
| `make_chart256.py` | 造 512×512 / 16×16 图卡 raw（之后交给 `dnglab convert`） |
| `dngmeta.py` | DNG 元数据单一真源：颜色矩阵对、`AsShotNeutral`、CFA 标签 |
| `asn_calibration.json` | 6500 K 下反解出的 ASN（`0.51828 / 1 / 0.735308`） |
| `inject_raw_ifd.py` | 在 `dnglab -c uncompressed` 容器里替换 raw strip 字节（旧的 18 档灰阶 + 24 色块探针） |
| `make_patch_dng.py` | 48 色块 + 21 级灰阶的 raw（另一个探针图） |
| `probe.swift` | `CIRAWFilter` 接受性 + 3500…9000 K 的 R/G/B 均值 |
| `probe2.swift` | 解码后采样 + 落盘 PNG（`verify_chart.py` 的输入） |
| `verify_chart.py` | 机器验收：色偏/单调/去重/σ/过曝/取向/色相，exit code 可判 |
