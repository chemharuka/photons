# ansel-denoise-swift

把 [aurelienpierreeng/ansel-denoise](https://github.com/aurelienpierreeng/ansel-denoise)（Ansel 的
`rawdenoiseai` 模块）用 Swift + Metal 重写，在 Apple Silicon 上对相机 RAW 做 CFA 域降噪。

**输出仍是 RGGB mosaic**（不是 RGB），黑点/白电平不变，只改像素值。这是它和绝大多数
「AI 降噪」的根本区别。

## 为什么是这个模型

| | ansel | nonlocal-matchfilter |
|---|---|---|
| 参数 | 0.48 M | 15.3 M |
| 60 MP 耗时 | 78 s | 83 s |
| σ 降幅 | 90–92% | 97% |
| **换相机** | **测噪声 profile 即可，无需重训** | 需重标定/重训 |
| 许可 | GPL-3.0 | MIT |

设计上它把 CFA 布局和噪声电平都做成**输入平面**而不是烘进权重，所以一套权重覆盖所有相机、
所有 ISO。这是它最值得用的地方。

## 快速开始

```bash
# 构建
swift build -c release --scratch-path /tmp/ansel-rel
EXE=/tmp/ansel-rel/release/ansel-denoise-swift

# 看模型信息
$EXE info denoise-quarter-single-v1.anselnn

# 单块（float32 裸文件，宽高按像素数）
$EXE tile MODEL.anselnn in.f32 --width 256 --height 256 \
     --a "0.0004,0.0003,0.0004" --b "3e-6,1e-6,1e-6" \
     --cfa rggb --gpu --out out.f32

# 批量（60 MP 用这个：一次进程处理所有块）
$EXE batch MODEL.anselnn tiles.f32 --tile 256 --count 1426 \
     --a "..." --b "..." --cfa rggb --gpu --out out.f32

# 速度对比
$EXE bench MODEL.anselnn --compare-cpu --tiles 256,512,1024
```

配套 Python：`run_gpu_variants.py`（真实 RAW 全流程）、`to_dng.py`（写 DNG）、
`ref_forward.py`（独立 numpy 参考实现，用于对拍）。

## 权重

不随本仓库分发（GPL 与体积原因）。从上游 manifest 拉取并校验：

```bash
curl -sL -o manifest.json \
  https://raw.githubusercontent.com/aurelienpierreeng/ansel-denoise/master/models/manifest.json
# 按 manifest 里的 sha256 下载并校验，例如：
curl -sL -O https://raw.githubusercontent.com/aurelienpierreeng/ansel-denoise/master/models/denoise-quarter-single-v1.anselnn
shasum -a 256 denoise-quarter-single-v1.anselnn   # 与 manifest 比对
```

六个变体：`quarter/half/large` × `single/multi`。**只用 `single`**（`multi` 需要
superpixel binning，本实现未包含）。

| 变体 | base | 参数 | 256² 耗时 | σ 降幅 |
|---|---|---|---|---|
| `quarter-single` | 8 | 0.48 M | 50.6 ms | 88% |
| `half-single` | 16 | 1.90 M | 216.0 ms | 92% |
| `large-single` | 32 | 7.59 M | 881.9 ms | 93% |

`quarter` 是默认选择。除了性价比，它还有个稳健性优势：**对 σ 估计误差最不敏感**
（见下面 σ 校准那条）。

## 三个必须知道的坑

### 1. σ 图要乘校准系数，否则降噪严重不足（且不报错）

`σ = sqrt(a·y + b)` 不能直接喂。还要乘逐通道系数：

```
R 2.82 = 2 × 1.41      G 3.94 = 2 × 1.97      B 2.96 = 2 × 1.48
        ↑                                      ↑
        └ lifting-Haar 归一化（std(HH)=σ/2，profile 存了 1/4 方差）
                  └ 去马赛克衰减中位数（profile 在已去马赛克像素上拟合）
```

漏掉它：quarter 从 88% 掉到 78%，**large 从 93% 掉到 46%** —— 大模型退化更严重，
看起来像「模型越大越差」。**σ 校准错的时候比较模型规模是无效的。**

`--sigma-scale` 可调（默认 `2.82,3.94,2.96`）。代码里是乘系数的平方到 a/b 上，
等价于 σ 乘系数（因为 σ 是开方出来的）。

### 2. Metal 内核必须统一用 channels-last

卷积按 NHWC 交错读写。曾经有三个辅助内核（`concat_channels`、`upsample2x_nearest`、
`sub_planes`）按平面（NCHW）实现，全部静默出错。

**检测方法：常量输入探针。** 常量 0.2 的 32² 输入：

```
CPU  mean=0.199862  min=0.190150  max=0.207067   ← 合理
GPU  mean=0.217140  min=-0.781539 max=2.174546   ← 明显错
```

真实图上看不出来（画质本来就模糊），常量探针几分钟就能定位。

### 3. 尺寸取 `raw_image` 而不是 `raw_image_visible`

Leica SL3：`raw_image` 9536×6344，`raw_image_visible` 9524×6344。用后者构造 mosaic 写出
的 DNG，**libraw 能读但 Core Image 报 `nativeSize 0×0` 拒收**（差 12 px 导致数据长度与
`ActiveArea` 不一致）。visible 之外的行列要从源文件原样复制。

## 验收标准

一个都不能省：

1. **与独立 numpy 实现逐值对拍**，`max|Δ| < 1e-5`（实测 1.9e-7）
2. **CPU ↔ GPU 逐值对拍**，`max|Δ| < 1e-5`（实测 4.2e-7）
3. **双解码器**：Core Image 与 libraw 都要能开，且显影亮度接近源
4. 黑点、白点、尺寸与源文件一致

```bash
swift test -c release --scratch-path /tmp/ansel-rel   # 7 个用例
```

## 实测结果（M1 Max，60.4 MP，ISO 3200）

```
1426 块（31×46），tile 256，overlap 48
77.9 s，54.7 ms/块
σ 降幅 R 90% / G1 92% / B 92% / G2 90%
输出 59.1 MB 无损压缩 RGGB DNG，黑点 512 不变

Core Image  nativeSize 9520×6336，mean 100.86（源 101.44）
libraw      黑点 [512,512,512,512]，显影 mean 70.36（源 70.54）
```

GPU 相对 CPU 的加速：64² 18.6×、128² 35.1×、256² 32.9×、512² 30.9×、1024² 30.4×。

## 网络结构（`.anselnn` 格式）

```
8 字节   magic "ANSELDN1"
4 字节   JSON 头长度（uint32 LE）
JSON     {"cfg": {...}, "tensors": [{name, shape, offset, size}, ...]}
payload  裸 float32；offset 相对 payload 起点
```

5 平面输入 `[mosaic, R one-hot, G one-hot, B one-hot, σ]` → 残差预测噪声 → `输出 = 输入 − 噪声`。
UNet，depth=4，每层 `[conv3x3→GELU]×2` + 2×2/2 下采样；decoder 2× 最近邻上采样 → 1×1 conv
→ concat skip → `[conv3x3→GELU]×2`。无归一化层（否则 tiling 会改变结果）。

**块边长必须是 16 的倍数**（`2^depth`），否则 bottleneck 坍到 1×1。overlap 取 48
（Ansel 文档给出冲激响应 r=32 时衰减到 1e-6、r=96 归零）。

## 许可

本组件是 **GPL-3.0**（衍生自 ansel-denoise）。使用方式是**编译成独立可执行文件、
由 MIT 许可的主程序通过 `Process` 调用，不链接**——两者是聚集体（aggregate）而非单一作品。

这与项目里 `Vendor/hdrmerge-swift`（同样 GPLv3）的既有做法一致。文件头的版权与来源
标注不可删。
