# 4.1–4.6 影调：白平衡、曝光、端点、对比、曲线

第 3 章讲了参数该待在哪个域，这一章给算式：白平衡、曝光、三个影调窗口、两个端点、对比、曲线。每节的骨架一样：解决什么问题、算式、参数、实现、开源对照、已知取舍。

常数都抄自 `Sources/PhotonsCore/Kernels/`，范围和默认值抄自 `Sources/PhotonsCore/EditModel.swift`。两边打架时以 kernel 为准，哪里打架就在哪一节点出来。

## 4.1 白平衡、色调与黑电平

**它解决什么问题**

先定下这张图的光是什么颜色，再把用户想要的偏移叠上去。白平衡决定中性色落在哪，tint 修绿/品红的偏移，黑电平决定「0」在哪。三个量的共同要求：没碰过的时候必须逐字节不变。

**算法**

白平衡分两段走：落定的时候写回解码器，拖动的时候走自己算的矩阵。文档里的 (K, tint) 不是 `nil`，下一次开发就把它写进 `CIRAWFilter.neutralTemperature/neutralTint`，解码器照这个出图。所以它决定的是「哪张缓冲」，不是渲染（`Sources/PhotonsCore/EditModel.swift:1521`、`Sources/PhotonsCore/RAWDecoder.swift:587`）。`nil` 表示 as shot，这时完全不碰 filter，因为把读到的 as-shot 值再赋回去不是恒等。写回要做读回校验：`CIRAWFilter` 对越界的中性值不报错，实测 99999 K 和 100 K 都照收。所以钳制放在 Photons 这一侧，读回对不上就抛错，不会静默退回 as shot（`Sources/PhotonsCore/RAWDecoder.swift:587`）。

拖动期间不重新解码。S1 用一条自算的 3×3 矩阵，把画面从缓冲自己的白平衡搬到文档要的白平衡（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:273`、`Sources/PhotonsCore/RenderGraph.swift:1715`）。这条矩阵不是 von Kries 对角：194 的拖动版只乘三个通道数，实测在 3200 K 与解码器的完整 3×3 差 97 码（ΔE00 8.9），松手会跳一下。195 换成完整积，交叉项补的就是这一块。

请求先落成 CIE 1960 uv 上的一个点。普朗克轨迹用 Kim 的解析拟合，再把 6500 K 平移到位，与工作白 D65 重合。tint 沿轨迹法线位移，幅度 0.000343 uv/单位。这个数是从解码器上量出来的（240），不是 `5×10⁻⁵` 那类显示域猜测：旧的猜法把白点移动少了 6.86 倍，6500 K 下 ±150 的请求会偏离落定帧 31–54 码，4000 K 下约 139 码（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:297`）。uv 转成 XYZ 之后做 Bradford 适应到工作白，再折成工作基色里的 3×3（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:503`）。

矩阵是锚点相对的：`M(document) · M(buffer)⁻¹`，在 6000 K / tint 0 的锚点上恰好是恒等（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:428`）。这样一段短拖动只承担模型在它走过的那段距离上的误差，而首帧 `document == buffer` 时逐字节是恒等。外推会失控，实测 2850 K/+60 给出 4.06× 蓝、218 码。所以有一道阀：任何一项 |m| > 3 就退回对角增益（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:496`、`Sources/PhotonsCore/RenderGraph.swift:1715`）。

吸管有两级。首选 `CIRAWFilter.neutralLocation`，系统自己的吸管，在 RAW 域解中性，出来的直接就是文档存的那两个数，没有迭代（`Sources/PhotonsCore/WhiteBalanceNativeDropper.swift:35`）。文件被拒或者答案越界，退回迭代精修器。

黑电平是加法，而且排在增益之前：

$$
v \leftarrow v+o,\qquad o=\text{blackOffset}\in[-0.01,\,+0.01]
$$

位置是 071 定下的。加法量必须被同一个增益缩放，负样本才能和正样本一起被抬过零（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:267`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `temperature` | 2000…50000 | `nil`（as shot） | K，滑杆按 mired 均匀（`Sources/PhotonsCore/TemperatureScale.swift:20`） |
| `tint` | −150…150 | `nil` | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1523`） |
| 色温量化步 | 1 | — | mired（`Sources/PhotonsCore/TemperatureScale.swift:28`） |
| tint 位移 | 0.000343 | — | uv / 单位（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:297`） |
| 预览矩阵阀 | \|m\| ≤ 3 | — | 无量纲（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:496`） |
| `blackOffset` | −0.01…+0.01 | 0 | 线性光（`Sources/PhotonsCore/EditModel.swift:1552`） |
| `blackOffset` 滑杆 | −10…+10，整数 | 0 | 1/1000（`Sources/PhotonsCore/EditModel.swift:1554`） |

色温滑杆按 mired（10⁶/K）均匀：0 端是 2000 K，1 端是 50000 K。要是按 Kelvin 线性排，视觉上分不出的 12000–50000 K 会占掉 80 % 的行程，改成 mired 之后只剩最右 13 %。一格 1 mired，在 5000 K 大约 25 K，在 20000 K 大约 400 K，两端都低于可见阈值（`Sources/PhotonsCore/TemperatureScale.swift:3`）。文档里存的仍然是 Kelvin，老文档不用迁移。

**实现**

落定时 CPU 把两个数写进 filter 并读回（`Sources/PhotonsCore/RAWDecoder.swift:587`）。拖动时 GPU 收到的是整整 3×3 三行：`p.e.z` 是「这一帧的白平衡是一个矩阵」的开关，`w0/w1/w2` 是行主序的三行。行和归一到 1，中性灰因此保持电平（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:164`）。as shot 文档写恒等三行、`e.z = 0`，kernel 就原样走 195 之前的那条表达式（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:279`）。

**开源对照**

- darktable `temperature`（`src/iop/temperature.c`）：系数来自相机矩阵，再按文件里记的照度选表，走的是「查表 + 相机模型」。这里落定交给 Apple 的色彩引擎，拖动是自己算的 Bradford 3×3。链接：https://github.com/darktable-org/darktable/blob/master/src/iop/temperature.c
- RawTherapee 的 RAW 阶段白平衡（`rtengine/rawimagesource.cc`）：乘子乘在去马赛克之前的马赛克上，以 `refwb_*` 的 as-shot 为参考。这里乘在已经去马赛克的线性图上，参考是「这张缓冲当年按哪一对解码的」。链接：https://github.com/Beep6581/RawTherapee/blob/dev/rtengine/rawimagesource.cc

**取舍**

- 拖动与落定在 3200 K 还差十几码。预览矩阵是模型的完整积，解码器用它自己的适应；195 把差从 97 码压到十几码，没说会归零。规则因此写成「预览是近似、落定是真值」。
- 外推有阀：|m| > 3 退回对角增益（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:496`）。极端请求在这个边界上退化，不会给出一张烧掉高光的图。
- 吸管首选系统实现，答案就依赖 `CIRAWFilter` 的 RAW 域模型。迭代精修器留着，但它已经不是主路径。

## 4.2 曝光

**它解决什么问题**

给整幅画面加减光。它必须是一次纯增益，而且必须在任何压缩之前完成。一旦压在显示域，被压掉的高光就再拿不回来。它也是 S1 里唯一不带窗口的增益：不改斜率、不改色度、不动任何端点。

**算法**

$$
v \leftarrow v\cdot 2^{E}
$$

$E$ 是文档的 EV。没有夹取、没有端点、没有曲线参与（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:280`）。位置是固定的：在加法微调之后、两个端点之前（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:267`、`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:295`）。

有一条配套约定让曝光可交换：`whites` 的窗口读「没加曝光的亮度」$L_0$，不读画面当前的 $L$：

$$
L_0=L-\log_2 2^{E}
$$

（`Sources/PhotonsCore/Kernels/tone_shape.metal:337`。）于是曝光平移画面、不平移窗口，同一个 `whites` 数值在 E0 和 E+2 下作用在同一批场景影调上（`Sources/PhotonsCore/Kernels/tone_shape.metal:311`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `exposure` | −5…+5 | 0 | EV（`Sources/PhotonsCore/EditModel.swift:1428`） |
| 增益 `2^E` | 1/32…32 | 1 | 倍（`Sources/PhotonsCore/EditModel.swift:1667`） |
| `highlightRecovery` | 0…1 | 0 | 无量纲（`Sources/PhotonsCore/EditModel.swift:1525`） |

**实现**

增益在 CPU 上算：`exposureGain = pow(2, exposure)`（`Sources/PhotonsCore/EditModel.swift:1667`），作为 `S1Params.a.x` 传进去（`Sources/PhotonsCore/RenderGraph.swift:3980`）。只有 `kKnee` 打开时，它才额外作为参数交给端点函数（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:292`），因为 $L_0$ 要用到它；`g = 1` 时 $L_0=L$ 逐位成立（`Sources/PhotonsCore/Kernels/tone_shape.metal:316`）。

高光恢复在同一次 dispatch 的最后：膝 0.8，`amount=0` 是精确恒等，`amount=1` 渐近 1.0（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:299`）。它永远排在端点之后：`whites` 说白点在哪，恢复说肩怎么压（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:145`）。

**开源对照**

- darktable `exposure`（`src/iop/exposure.c`）：同一个模块里还有黑点和 deflicker，而且黑点被约束在白点之下。这里的曝光只有一个数，黑电平是另一个加法量，排在增益之前。链接：https://github.com/darktable-org/darktable/blob/master/src/iop/exposure.c
- darktable `filmicrgb`（`src/iop/filmicrgb.c`）：那边「曝光」是相对曝光的范围归一化，先定白/黑相对 EV 再上曲线。这里的曝光是乘在光上的纯增益，范围由 `whites` 的 EV 窗口另行表达。链接：https://github.com/darktable-org/darktable/blob/master/src/iop/filmicrgb.c

**取舍**

- kernel 不夹取 `p.a.x`。−5…+5 只是文档声明的范围（`Sources/PhotonsCore/EditModel.swift:1428`），手改文档能超出滑杆。
- 高光恢复吃的是 S1 出口的值，也就是已经过 `blacks`/`whites` 的值。想把肩放在端点之前，目前没有位置。

## 4.3 高光、中间调、阴影

**它解决什么问题**

三个滑杆分别抬或压暗部、中间调、亮部。判据有两条。第一，每个亮度都得有主人，中间不能留死带。第二，一个滑杆动自己的区段时还要带动邻居。用户的原话是「中间调调节以中间区域为主，但也能带动阴影和高光。其他的也类似，避免局部对比度的损失」。085 用两条互补的 smoothstep 链，问题是它们互斥：相邻控件被带动的量严格是 0，单拉中间调时窗口缝隙上的输出斜率只剩 0.30。306 把权重换成三个归一化重叠高斯。

**算法**

坐标仍是 $L=\log_2 Y$（相对显示白的 EV，直方图自己的轴）。三个中心坐在参考帧的阴影 / 中位 / 高光上，宽度 1.9 EV：

$$
c_s=-6.8,\quad c_m=-3.6,\quad c_h=+0.2\ \text{EV},\qquad \sigma=1.9\ \text{EV}
$$

$$
b_i=\exp\!\left(-\frac{((L-c_i)/\sigma)^2}{2}\right),\qquad
w_i=\frac{b_i}{\sum_j b_j}\qquad\Longrightarrow\qquad \sum_i w_i\equiv 1
$$

归一化是硬条件。不归一的高斯（darktable `toneequal` 走的老路）在相邻区会出现反号瓣；凸组合永远落在三个滑杆值之间，不会振铃。权重是 $C^\infty$、全轴支撑，所以每个控件都能带动另外两个。中档的峰值权重是 0.726（$L=-3.6$），另两档中心看到的中间调权重分别是 0.195 / 0.119。全局增益是

$$
v\leftarrow v\cdot 2^{\,w_s d_s+w_m d_m+w_h d_h+S(L)}
$$

$d_s,d_m,d_h$ 是已经过门的 EV 位移。306b 把高光也放进凸组合：$L=0$ 处 $w_h=0.856$，白点附近的 SDR 因此也跟高光走，$h=-100$ 时 $L=0$ 会动 $-0.71$ EV，用户那句「其他的也类似」说的正是这一条。权重直接用 $L$，不在白点冻结：$L\to+\infty$ 时 $w_h\to1$，band 项趋于常数 $d_h$；299 的 HDR 尾由差额肩 $S$ 补（下面再说）。蒙版路径（`s1_6_local`）还是 074 的两窗口加第三个 EV 行程。

**行程重标定。** 高斯峰值只有 0.726，要是沿用旧行程（0.90 / 0.70 / 0.60），每个档位中心的实际位移会掉 27 %。所以满行程乘 $1/0.726=1.378$：

$$
\Delta_s=1.24,\qquad \Delta_m=0.96,\qquad \Delta_h=0.83\ \text{EV}
$$

单拉中间调时，阴影中心（−6.8 EV）被动抬 $0.195\cdot0.96=+0.187$ EV，高光中心（+0.2 EV）被动抬 $0.119\cdot0.96=+0.115$ EV；$L=0$ 处的中间调权重是 0.143，主导但不独占，「以中间为主」指的就是这个比例。

**单调性门。** 归一化保证不了 $d(\text{out})/dL$ 不折。精确判据放在 CPU：

$$
\frac{d(\log_2 v')}{dL}=1+\sum_i w_i'(L)\,\Delta_i
$$

在 $L\in[-12,0]$、步长 0.05 EV 上取最小值。只有低于 `minSlope = 0.500` 时，才按 `scale = (1 − minSlope)/(1 − min)` 等比压缩三个 $\Delta$。默认行程下实测最坏 0.5287（$L=-5.35$，$+1.24/-0.96/+0.83$ 的反号角），门从不触发；单个滑杆的斜率地板是阴影 0.717、中间调 0.765、高光 0.774（高光进了 band，不再是 1.000）。085 的 0.30 因此成了历史。

**高光 = band + 白点以上的差额肩（306b）。** 记 $h=\mathrm{clamp}(\text{highlights},-100,100)/100$，滑杆仍然设定渐近斜率：

$$
k(h)=1+c\,h,\qquad c=0.579214093\ldots
$$

$c$ 由 $h=-100$、$L=+4$ 时总位移 $=-3.0$ 数值解出（`S2Regions.highSlopeCoefficient` 用二分；解析式 $c=(3.0-w_h(+4)\cdot0.83)/3.75$）。于是 $k(-100)=0.420786$、$k(0)=1$、$k(+100)=1.579214$。差额肩是

$$
S(L)=
\begin{cases}
0, & L\le 0\\
(k-1)\left(L-w\left(1-e^{-L/w}\right)\right), & L>0
\end{cases}
\qquad w=0.25\ \text{EV}
$$

$S(0)=0$、$S'(0)=0$，所以白点是 $C^1$。$L=+4$、$h=-100$：band 贡献 $w_h(+4)\cdot(-0.83)=-0.827947$，肩补 $-2.172053$，合计 $-3.0$，输出 $y=+1.000$ EV。$L=+8$ 用同一个 $k$ 得 $y=+2.681$ EV，与 299 的 1.798 差 0.88，这是高光进 band 之后的真实结果，不重录旧数。实测的 $y$（EV）：

| L (EV) | h=−100 | h=−50 | h=0 | h=+50 | h=+100 |
|---|---|---|---|---|---|
| 0.5 | −0.419 | 0.040 | 0.500 | 0.960 | 1.419 |
| 1 | −0.221 | 0.389 | 1.000 | 1.611 | 2.221 |
| 2 | 0.173 | 1.087 | 2.000 | 2.914 | 3.827 |
| 2.3 | 0.295 | 1.297 | 2.300 | 3.303 | 4.305 |
| 4 | 1.000 | 2.500 | 4.000 | 5.500 | 7.000 |
| 8 | 2.681 | 5.341 | 8.000 | 10.659 | 13.319 |

SDR 的局部斜率由 band 决定，单杆地板就是 0.717 / 0.765 / 0.774。白点以上，肩的渐近斜率是 $k$，$h=-100$ 时是 0.421。这是**有意的** HDR 尾压缩，所以不进单调性门，门的域仍然是 $L\in[-12,0]$。$h=0$ 且 $L\le0$ 仍然逐位恒等；$h\ne0$ 时高光会动到 SDR 的近白，「高光只压 HDR 尾」这句旧口径已经被 306b 取代。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `shadows` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1435`） |
| `midtones` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1434`） |
| `highlights` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1430`） |
| 波段中心 $c$ | −6.8 / −3.6 / +0.2 | — | EV（`Sources/PhotonsCore/S2Regions.swift:57`） |
| 波段宽度 $\sigma$ | 1.9 | 1.9 | EV（`Sources/PhotonsCore/S2Regions.swift:58`） |
| 全局满行程 | 1.24 / 0.96 / 0.83 | — | EV（`Sources/PhotonsCore/S2Regions.swift:45`、`:46`、`:49`） |
| 蒙版满行程 | 0.90 / 0.70 / 0.60 | — | EV（074，`Sources/PhotonsCore/S2Regions.swift:52`、`:53`、`:54`） |
| 高光斜率 $k$ | 0.421…1.579 | 1（恒等） | — （`Sources/PhotonsCore/S2Regions.swift:80`） |
| 高光膝宽 $w$ | 0.25 | 0.25 | EV（`Sources/PhotonsCore/S2Regions.swift:71`） |
| 最小斜率 | 0.500 | 0.500 | — （`Sources/PhotonsCore/S2Regions.swift:119`） |
| **画面天花板** | 0…+4 EV | **+2.3 EV**（线性 4.925） | EV（`Sources/PhotonsCore/HighlightCeiling.swift:32`） |

**画面天花板（320）。** 整幅画面的上限只由 S2 出口负责：`min(max(v,0), ceiling)`，两条分支都夹（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:67`、`:117`）。这个值以前不存在。那时三个显示域阶段各自写死了 `clamp(…, 0, 4.0)`，锐化、纹理、颗粒各一份，于是「+2 EV 以上全黑掉」看起来像管线行为，实际是锐化默认 50 一直在跑，把它的字面量带了进来。现在天花板是 S2 上的一个数：默认 +2.3 EV，0…+4 EV 可调，存在偏好里而不是文档里。它回答的是「这张照片允许带多少光到屏幕上」，属于显示决定，像画布底色一样，不该由某张照片携带，也不该被预设导入（`Sources/PhotonsCore/HighlightCeiling.swift:25`）。上限停在 +4 EV 是因为直方图的尾巴只画到那里（`Histogram.maxStops = 4`），再往上就是画不出来的控制。

**实现**

kernel 做归一化高斯的三个权重、`dot(w, d)`、`high_shoulder_ev` 差额肩和一次 `exp2`（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:101`、`Sources/PhotonsCore/Kernels/tone_shape.metal`）；行程、斜率 $k$ 和单调性门都在 CPU（`S2Regions.weights` / `travelEV` / `highSlopeCoefficient` / `highSlope` / `highShoulderEV`）。kernel 收到的是三个 EV、$k$ 和天花板，不是滑杆位置。「图不会折」因此是可算的，不是靠把窗口宽度挑得刚好。蒙版路径用 `S2Regions.maskTravelEV` 保留 074 的旧数值，`s1_6_local` 的像素不动。

S2 在入口不夹取：`v = c.rgb` 直接进权重（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:95`），只在本阶段末尾取 `max(v, 0)` 和天花板（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:117`）。原因是解码器会给零以下的样本，而抬暗部已经把另一些像素拉过零，那些是真画面。alpha 0 和内容矩形两道守卫在像素运算之前（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:78`、`:85`），否则抬暗部会把黑边一起点亮。

**开源对照**

- darktable `toneequal`（`src/iop/toneequal.c`）：在场景线性相机 RGB 上做八度高斯权重加线性解法；它不归一化，所以相邻区有反号瓣。这里是显示参考域的三个归一化高斯，没有空间项，也没有解法。链接：https://github.com/darktable-org/darktable/blob/master/src/iop/toneequal.c
- RawTherapee / ART 的 `shadows/highlights`：固定分母的钟形权重（$\sum g(0)=1.7726$），凸组合因此不振铃。这里的分母是逐像素精确的 $\sum b_i$，$\sum w\equiv1$ 是浮点事实，不是常数近似。链接：https://github.com/Beep6581/RawTherapee/blob/dev/rtengine/ipshadowshighlights.cc
- LightZone 的分割 B 样条（`Spline.java`）：用精确的单位分割保证各段权重和恒为 1。这里用高斯做同一件事，换来 $C^\infty$ 和全轴支撑。

**取舍**

- 单个 `shadows +100` / `midtones +100` / `highlights +100` 的满行程 1.24 / 0.96 / 0.83 EV 在中心成立，但接缝上的局部斜率会降到 0.717 / 0.765 / 0.774（085 是 0.30）。派单里 0.80 那个数字是用重标定前的 0.90 / 0.70 / 0.60 行程测的，那时是 0.795 / 0.828 / 0.836。要同时保住中心行程和 0.80 地板，得用更大的 $\sigma$ 或更远的中心，两者都会改动用户已经认可的区段位置。
- 高光进了 band，但在 $\sigma=1.9$ 的归一化三高斯里，它对阴影中心的带动只有 0.00075 EV，对中间调中心是 0.0815 EV。要让高光把阴影中心抬到 0.03 EV，需要 $\sigma\approx2.8$，而那时中间调对阴影的带动会变成 0.447，破坏验收 2 的 0.187±0.02 和「以中间为主」。这是有意取舍，不是漏项。
- $L=+8$、$h=-100$ 的输出从 299 的 1.798 EV 变成 2.681 EV：高光现在先作为 band 压 SDR 近白，肩只补差额。旧数字依赖「高光不进 band」，留不住。
- 蒙版内的阴影/高光仍用 074 的两窗口 `region_weights` / `region_weights3`（`Sources/PhotonsCore/Kernels/tone_shape.metal`），与全局的三段故意不同步。同一次拖动，全局和蒙版的响应因此不完全同形，等「两套体统一」的单独任务。
- 权重中心和宽度是固定常数，不随画幅、不随内容自适应。动态范围很窄的图会整幅落在同一组权重上，三个滑杆于是都动它。

## 4.4 白点与黑点

**它解决什么问题**

把最暗和最亮钉住。纯乘法做不到：`0 → 0` 对任何增益都成立，黑点既压不到 0，也浮不起来；纯加法又会造灰。所以用「EV 膝 + 电平」的混合，两半按行程掺在一起。

**算法**

记 $t=\text{blacks}/100$，$a=|t|$，$L$ 是端点的坐标（BT.709 亮度取对数）。这里的 `blacks` 是 kernel 单位，不是滑杆位置。滑杆先过一条映射：0…30 → 0…50，30…100 → 50…100（`Sources/PhotonsCore/EditModel.swift:1497`）。所以新 −30 渲的不是新 −30 的行程，而是旧 −50 的字节；新 −100 才到 kernel 的满行程。这条映射让「0–30 调 EV、30–100 调电平」变成分派事实：机制开关落在 kernel ±50，正好是滑杆 ±30（`Sources/PhotonsCore/RenderGraph.swift:3744`、`Sources/PhotonsCore/EditModel.swift:1509`）。

前 20 % kernel 行程是纯乘：

$$
w_b=1-\mathrm{ss}(-12,-1,L),\qquad v\leftarrow v\cdot 2^{3.0\,t\,w_b}
$$

超过 0.2 之后电平进场：

$$
m=\mathrm{ss}(0.2,1,a),\qquad w_l=1-\mathrm{ss}(-6,-1,L),\qquad \text{off}=0.006\,t\,m\,w_l
$$

压暗侧还有 342 的第二级电平。它只对 $t<0$ 生效，在 $a\le0.5$（kernel，即滑杆 −50）时恰好是 0，零点斜率也是 0，所以前半个行程逐字节还是 073C：

$$
w_{l2}=1-\mathrm{ss}(0.020,\,0.135,\,\text{luma}),\qquad
\text{off}\mathrel{-}=0.060\,a\,m_5\,w_{l2},\quad m_5=\mathrm{ss}(0.5,1,a)
$$

$$
\text{off}<0:\ v\leftarrow T(v+\text{off})\cdot g,\qquad \text{off}>0:\ v\leftarrow T(v\cdot g+\text{off}),\qquad g=2^{3.0\,t\,w_b}
$$

（`Sources/PhotonsCore/Kernels/tone_shape.metal:350`、`Sources/PhotonsCore/Kernels/tone_shape.metal:353`、`Sources/PhotonsCore/Kernels/tone_shape.metal:358`、`Sources/PhotonsCore/Kernels/tone_shape.metal:376`。）顺序看符号，单调性就是这么来的：压暗时电平和增益都往暗走，先电平后增益；提亮时电平必须骑在增益外面，否则 ±0.006 在 8× 增益里被放大八倍，最暗的那一格反而最亮（`Sources/PhotonsCore/Kernels/tone_shape.metal:368`）。

342 为什么要第二级，而不是把 `B_LEV` 加倍：文档的规模是「−100 能让亮度 64/255 变 0」，而 `B_LEV` 满行程只把黑点搬到 0.006 线性（码 17.9），叠加它自己的窗口权重（码 64 处 0.73）后落在码 48.3。一个系数只能对应一个黑点，想往 64 走就得牺牲 ±50 那一带的旧字节。第二级用 0.060 的幅度、0.020…0.135 的线性光窗口（码 39…103）拿到码 64→0，而 18 % 灰处窗口权重恰好是 0，中间调逐位不动（`Sources/PhotonsCore/Kernels/tone_shape.metal:201`、`:226`）。窗口取线性光而不是 EV，因为压暗是一次黑点移动：`off(v)` 必须在码 64 到码 103 之间落下。对数窗口会把这个下降挤到 `v` 最小的地方，`d(off)/dv > 1` 就折了；线性光里 `|d(off)/dv| \le 1.5·0.060/0.115 = 0.78 < 1`，单调是构造出来的，`BlacksTravelTests` 逐码检查 0…255。

$T$ 是 C¹ 整流器，膝 $k=10^{-3}$：

$$
T(x)=\begin{cases}x, & x\ge k\\ 0, & x\le -k\\ \dfrac{(x+k)^2}{4k}, & \text{otherwise}\end{cases}
$$

（`Sources/PhotonsCore/Kernels/tone_shape.metal:282`。）改电平的意思是允许压到 0，压暗一侧确实压到了 0。提亮一侧 `off ≥ 0` 不夹取，所以 `t=+1` 不会把正的样本压到 0。

白点用同一个函数的后半段，但读 $L_0$：

$$
u=\frac{\text{whites}}{100},\qquad w_w=\mathrm{ss}(-2,2,L_0),\qquad \lambda=\frac{1}{1-0.20\,u\,|u|},\qquad v\leftarrow v\cdot 2^{1.2\,u\,w_w}\cdot\lambda
$$

（`Sources/PhotonsCore/Kernels/tone_shape.metal:389`、`Sources/PhotonsCore/Kernels/tone_shape.metal:390`。）$\lambda$ 是乘法电平、没有窗口，所以它缩放每一档亮度（含 HDR 尾）；$u=0$ 时 $\lambda=1$，中性文档逐字节不变（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:119`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `blacks` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1474`） |
| `whites` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1440`） |
| 滑杆 → kernel | 0…30 → 0…50；30…100 → 50…100 | — | 倍（`Sources/PhotonsCore/EditModel.swift:1497`） |
| 电平入场点（滑杆） | 30 | — | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1509`） |
| 电平入场点（kernel） | 50 | — | kernel 单位（`Sources/PhotonsCore/RenderGraph.swift:3744`） |
| 黑 EV 满行程 $B_{EV}$ | 3.0 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:184`） |
| 黑膝窗口 | −12…−1 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:185`、`Sources/PhotonsCore/Kernels/tone_shape.metal:186`） |
| 电平幅度 $B_{LEV}$ | 0.006 | — | 线性光（`Sources/PhotonsCore/Kernels/tone_shape.metal:196`） |
| 电平窗口 | −6…−1 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:197`、`Sources/PhotonsCore/Kernels/tone_shape.metal:198`） |
| 电平膝 | 1e-3 | — | 线性光（`Sources/PhotonsCore/Kernels/tone_shape.metal:199`） |
| 压暗侧电平 $B_{LEV\_CRUSH}$ | 0.060 | — | 线性光（`Sources/PhotonsCore/Kernels/tone_shape.metal:226`） |
| 压暗侧窗口 | 0.020…0.135 | — | 线性光（码 39…103）（`Sources/PhotonsCore/Kernels/tone_shape.metal:227`、`:228`） |
| 白 EV 满行程 $W_{EV}$ | 1.2 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:266`） |
| 白电平 $W_{LEV}$ | 0.20 | — | 无量纲（`Sources/PhotonsCore/Kernels/tone_shape.metal:267`） |
| 白点窗口 | −2…+2 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:268`、`Sources/PhotonsCore/Kernels/tone_shape.metal:269`） |

**实现**

一个模板函数，七个入口。`kKnee`/`kHybrid`/`kTrim`/`kCalib` 都是编译期常量（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:233`），CPU 按值挑名字（`Sources/PhotonsCore/RenderGraph.swift:3764`）：`|blacks| ≥ 50`（kernel，滑杆 ±30，含 30）才进 `_hybrid`（`Sources/PhotonsCore/RenderGraph.swift:3744`、`:3751`），否则走 073B 那一支。50 是闭区间的起点，因为那正好是旧 ±50 渲染的那条曲线（342 的电平混合在 |k|=50 处是 0.316 而不是 0），「新 −30 ≡ 旧 −50」要求在这里就切到 hybrid。真要两个滑杆都是 0，`p.b.y` 让整段拷贝直接返回（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:243`）。

**开源对照**

- darktable `levels`（`src/iop/levels.c`）：黑、中间、白三个把手，作用在显示参考的 0…1 上，是一次跨度的仿射重映射。这里的黑白点是场景线性域的两个端点，动的是膝和电平，不改整幅斜率。链接：https://github.com/darktable-org/darktable/blob/master/src/iop/levels.c
- RawTherapee 的 RAW 黑白电平（`rtengine/rawimage.cc`）：逐通道从遮罩/元数据求黑电平，是解码域的钳位。这里的端点在解码之后，是用户可以拖的量。链接：https://github.com/Beep6581/RawTherapee/blob/dev/rtengine/rawimage.cc

**取舍**

- 端点亮度用的是 BT.709 权重（`Sources/PhotonsCore/Kernels/tone_shape.metal:277`），不是工作基色 Rec.2020。S1 还没迁移，因为 `BwLevelsTests` 的数都钉在这三个数上（`Sources/PhotonsCore/Kernels/tone_shape.metal:271`）。
- `whites` 的电平是全局乘法，物理上限很小：p1 只动 2–5 码（`Sources/PhotonsCore/Kernels/tone_shape.metal:241`）。要让暗部明显变亮，它是错的工具，`blacks` 的 EV 膝或 `exposure` 才对。
- 滑杆 ±30 处有一个小台阶：电平以 `m(0.5) ≈ 0.32` 的权重加入，坡底约 1.4 码。这是为「−30 ≡ 旧 −50」付的价，用户明确要了这个切分（`Sources/PhotonsCore/RenderGraph.swift:3744`）。
- 342 的压暗侧电平只作用于 `t < 0`：提亮侧最多把黑点抬 0.006（码 17.9），再往上就是造灰，`B_LEV` 的物理上限就在那里（`Sources/PhotonsCore/Kernels/tone_shape.metal:275`）。

## 4.5 全局对比度

**它解决什么问题**

把整幅画面的反差拉大，同时不动色相和饱和，也不动整幅的亮度锚点。它必须和曝光可交换：先加曝光再上对比，和先上对比再加曝光，得是同一张图。

**算法**

只算亮度 $Y$（显示参考、白 = 1 = 0 EV，HDR 上不设上限），一个标量增益乘三个通道：

$$
Y=\max\bigl(\langle\max(\mathrm{rgb},0)\rangle_w,\ 10^{-9}\bigr),\qquad
G=\log_2\!\left(\frac{Y}{g_{E}}\right)
$$

$$
\gamma=2^{\,\text{contrast}/100\ \cdot\ \tau},\qquad
G'=P+\gamma\,(G-P),\qquad
\Delta G=G'-G=\ln\!\Bigl[\Bigl(\tfrac{Y/g_E}{p}\Bigr)^{\gamma-1}\Bigr]/\ln 2
$$

$$
\mathrm{rgb}\leftarrow \max(\mathrm{rgb},0)\cdot 2^{\Delta G}
$$

（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:79`、`Sources/PhotonsCore/GlobalContrast.swift:60`。）$P=\log_2 0.18$ 是中灰枢轴（`Sources/PhotonsCore/GlobalContrast.swift:52`）。τ 没有新造常数，借的是色调映射自己的轴归一化 `S2Contrast.travelEV = 8/(whiteEV − blackEV) = 8/(0−(−8)) = 1`（`Sources/PhotonsCore/ContrastCurve.swift:99`、`Sources/PhotonsCore/GlobalContrast.swift:57`），所以这里的 ±100 与它取代的那个全局弯折同一行程。$g_E$ 是 S1 的曝光增益，从 $G$ 里除掉、再乘回像素上。「与曝光可交换」说的就是这一件事：中性曲线下 $Y(E)=2^E Y(0)$，增益场与 $E$ 无关，于是 $\mathrm{render}(E)=2^E\cdot\mathrm{render}(0)$（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:28`）。

**两个方向互为反函数。** $\gamma(c)$ 与 $\gamma(-c)=1/\gamma(c)$ 是同一枢轴的幂，所以 $f_{-}(f_{+}(Y))=Y$；同一条斜坡上 $\log_2(\text{out}/\text{in})$ 大小相等、符号相反。

**没有夹取。** 这里是幂乘，不是带白点的 S 曲线：$Y>1$ 的 HDR 段走同一套算术扩张，没有哪里让增益在白点处淡出。159 的显示域肩就是这么做的，也是它让 HDR 段原样通过的原因。黑地板也一并没了：159 的 A5 地板跟着局部算子一起删掉（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:32`）。

**枢轴要量化到缓冲的格点。** E-1 段读的是 16 位浮点纹理，文档说的 0.18 存进去是 `half(0.18) = 0.1800537`。枢轴要是还取 Double 的 0.18，平场就落在自己枢轴上方 4.3e-4 EV，$\gamma<1$ 一侧的增益是 0.99985，而 float→half 的隐式写是向零截断：负向对比度下平场会整个丢掉一码（实测 1474/1475）。所以 kernel 取枢轴之前先过一遍 `half()`。`s2_5_global_gain` 里那一行是把产生这个偏差的偏移量减掉，不是另外补一个数（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:81`）。

**蒙版是同一条曲线的覆盖加权。** 蒙版没有自己的对比算子：全局路径绑一张空图集、`maskCount == 0`，循环体因此不执行，穷尽的是同一份编译出来的算术（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:89`）。蒙版自身的线性增益先折进 $Y$ 的曝光项，否则同一个 `contrast` 在蒙版内外是两套算子。增益恰好为 1 时跳过不乘，因为 Rec.2020 权重和是 `0.99999994`，`mix(1, 1, w)` 会移动一码。覆盖率为 1 的蒙版直接用增益本身而不是 `mix`，`1+(g−1)` 在这里会舍入（`:139`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `contrast` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1429`） |
| 枢轴 $p$ | 0.18 | — | 线性光（`Sources/PhotonsCore/GlobalContrast.swift:52`） |
| 行程 $\tau$ | 1 | — | EV / 100 单位（`Sources/PhotonsCore/ContrastCurve.swift:99`） |
| 蒙版行程 | 同 τ | — | —（`Sources/PhotonsCore/GlobalContrast.swift:57`） |

**实现**

一个全分辨率 pass，`Kernels/s1_8_contrast.metal`，入口 `s1_8_g_contrast_apply_masked`（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:89`）。159 的 `_pack`/`_box_h`/`_box_v`/`_coeff` 四个 pass、1024 长边代理、系数图缓存全部删掉，已经没有需要分解的东西。`contrast == 0` 在 `s2_5_global_gain` 的第一行就返回 1.0，还没走到任何 `log2`，所以中性文档是**精确恒等**，连 1 码误差都没有（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:79`）。

**开源对照**

- darktable `colorbalance` / `toneequal` 的对比段：都在 Lab 或 log 亮度上做带窗口的局部对比。这里是全局幂律，与清晰度/纹理不竞争，228 换掉 159 就是为了这个。链接：https://github.com/darktable-org/darktable/blob/master/src/iop/toneequal.c
- RawTherapee `local contrast`（`rtengine/iplocalcontrast.cc`）：对 Lab 的 $L$ 做 FFT 高斯模糊，按半径与明暗三参数做非锐化式局部对比。这里在显示对数上做一次标量幂乘，没有空间半径。链接：https://github.com/Beep6581/RawTherapee/blob/dev/rtengine/iplocalcontrast.cc
- Lightroom 的「对比度」/「去朦胧」分离：这里与它同一分工，全局对比不带空间项。链接：https://helpx.adobe.com/lightroom-cc/using/contrast.html

**取舍**

- 159 的多尺度残差是整段删掉的，不是收紧参数：实测在 30 级 EV 斜坡上 `contrast = ±100`，每个 `out/in` 比都是 0.9985…1.0004，那个算子根本没有全局斜率，它做的是清晰度的近亲，与用户的预期不符（`Sources/PhotonsCore/GlobalContrast.swift:8`）。
- 没有白点淡出，所以 `contrast = +100` 会把 HDR 尾一起扩张到画面上限。上限由 S2 的画面天花板负责（+2.3 EV 默认，可调），不由对比度负责。
- 幂律在 $Y\to0$ 处的斜率趋于 0（$\gamma>1$）或无穷（$\gamma<1$），黑位以下的样本靠 `max(Y, 1e-9)` 兜底；没有为暗部另设软膝。

## 4.6 HDR 曲线

**它解决什么问题**

一条曲线要同时弯 SDR 的 0–255 和显示白以上的 +0…+4 EV，还得跟它上面的直方图同轴：左半是显示码，右半是 stops。管线里只有它一个算子是用户直接画形状的，它不解释画面，只执行点列。

**算法**

横轴 $u$ 是分段函数，SDR 半边用 sRGB 编码，HDR 半边用 $\log_2$：

$$
u(x)=\begin{cases}0.5\,\mathrm{sRGB}(x), & 0<x\le 1\\ 0.5+0.125\log_2 x, & x>1\end{cases}
\qquad
x(u)=\begin{cases}\mathrm{sRGB}^{-1}(2u), & u\le 0.5\\ 2^{8(u-0.5)}, & u>0.5\end{cases}
$$

（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:15`。）于是 $u(0.18)=0.2307$、$u(1)=0.5$、$u(4)=0.75$、$u(16)=1$（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:20`）。白点位置 $0.5$ 和每档宽度 $0.125$ 都从 uniform 来，不写死在 kernel 里（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:100`），CPU 的参考实现与 GPU 的整形器因此漂不起来。

表里存的是 $v\in[0,1]$，插值在 $u$ 上做（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:117`）。W 曲线是亮度增益，不是逐通道查表：

$$
v\leftarrow v\cdot 2^{\Delta},\qquad \Delta=\mathrm{clamp}\left(\log_2\frac{x(v)}{x(u)},\,-12,\,+12\right)
$$

（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:228`。）$\Delta$ 是两束光的比，不是 $u$ 差乘常数。SDR 半边上 1 个 $u$ 是 12–100 个 stops，乘常数会让中间调弱 40 %（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:222`）。R/G/B 是可分表，各自独立：

$$
v_c\leftarrow x\left(\mathrm{LUT}_c\big(u(v_c)\big)+\max(u-1,0)\cdot\mathrm{clamp}(s_c,-2,2)\right)
$$

（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:171`、`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:234`。）顺序是 W → R → G → B：先整幅影调，再偏色（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:91`）。

四条边界规则没有一条是可选的：① 恒等表直接拷贝（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:183`）；② alpha 0 与内容矩形的守卫（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:189`、`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:196`）；③ $x\le0$ 原样穿过、保号，除非黑点被抬过（这时落进表的常值段，负样本一起被夹）（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:166`）；④ $u>1$ 按末段斜率继续，不夹取（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:171`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| 控制点 $x$ | 0…2 | 0 | 轴坐标 $u=x/2$（`Sources/PhotonsCore/EditModel.swift:1970`、`Sources/PhotonsCore/EditModel.swift:1981`） |
| 控制点 $y$ | 0…2 | — | 同上（`Sources/PhotonsCore/EditModel.swift:1987`） |
| 恒等点列 | — | (0,0),(2,2) | （`Sources/PhotonsCore/EditModel.swift:2053`） |
| 表长 $N$ | 4096 | 4096 | 采样点（`Sources/PhotonsCore/EditCurve.swift:28`） |
| 表数 | 4（W/R/G/B） | 4 | 张（`Sources/PhotonsCore/EditCurve.swift:35`） |
| 末段斜率 | 0…+2 | 由末两点算 | EV/u（`Sources/PhotonsCore/HDRCurve.swift:190`、`Sources/PhotonsCore/HDRCurve.swift:194`） |
| 曲线格式 | version 2、`double`、`max: 2` | 同 | （`Sources/PhotonsCore/EditModel.swift:1779`） |
| `processVersion` | 2 | 2 | （`Sources/PhotonsCore/EditModel.swift:141`） |

**实现**

一张 4×4096 的 float 表放在 GPU 缓冲里，kernel 只读（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:178`）。恒等表按位掩码跳过（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:209`、`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:218`），因为整形器往返会带 ~5e-7 的误差，在 fp16 边界上就是 1 bit。末段斜率由表尾两点算（`Sources/PhotonsCore/EditCurve.swift:89`），夹取的两端是同一个数：`tailSlopeLimit = 2`、`tailSlopeFloor = 0`（`Sources/PhotonsCore/HDRCurve.swift:190`、`Sources/PhotonsCore/HDRCurve.swift:194`）。

**开源对照**

- darktable `tonecurve`（`src/iop/tonecurve.c`）：表的末段用拟合出的幂律外推，不夹取。这里的末段是线性外推加 0…+2 的斜率夹取，斜率直接就是 +4 EV 以上的对数对比。链接：https://github.com/darktable-org/darktable/blob/master/src/iop/tonecurve.c
- darktable `AgX`（`src/iop/agx.c`）：基色压缩 + log + sigmoid 的整幅色调映射，形状由模块给。这里的曲线形状由用户点列给，模块只负责轴和边界。链接：https://github.com/darktable-org/darktable/blob/master/src/iop/agx.c
- Filmulator 的胶片曲线（`filmulator-gui/Halide/applyfilmlikecurve.cpp`）：先把 RGB 排序，逐通道查表，中间通道按低/高两条的差线性插值以保序。这里的 W 曲线是亮度增益，三通道按同一个 $\Delta$ 缩放，保的是色相和饱和。链接：https://github.com/CarVac/filmulator-gui/blob/master/filmulator-gui/Halide/applyfilmlikecurve.cpp

**取舍**

- 曲线必须非递减：下降的点列不是这台引擎会建的表。文档里要是已经存着一条（137 曾一度允许、357 撤销后留下的旧文档），`buildOne` 排序去重后看见一段下降，就落回恒等表。它不报错，也不反相，所以「反相／负片」不多带一个开关，也不多带一条渲染路径（`Sources/PhotonsCore/EditCurve.swift:271`、`Sources/PhotonsCore/EditCurve.swift:191`）。
- $u>1$ 是线性外推，一段之外没有第二道形状。斜率夹在 0…+2 是防手改文档，不是画面决定（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:71`）。
- $\Delta$ 夹在 ±12 EV 是 fp16 保护：把白点从 0.5 拖到 1.0 是 +9 EV，200 级的像素在 half float 里已经接近 inf（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:226`、`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:229`）。所以极端的点列会被截断，而且不会有提示。

---

曲线之后 S2 交出 `0…1`，S2.5 的对比和 S3 的色彩才有坐标可用。这六节讲下来，每个滑杆都待在自己的域里，也都能用一行算式复述。
