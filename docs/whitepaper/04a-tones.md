# 4.1–4.6 影调：白平衡、曝光、端点、对比、曲线

第 3 章说参数该待在哪个域。这一章给算式：白平衡、曝光、三个影调窗口、两个端点、对比、曲线。每一节按同一结构写——解决什么问题、算式、参数、实现、开源对照、已知取舍。

常数一律抄自 `Sources/PhotonsCore/Kernels/`，范围与默认值一律抄自 `Sources/PhotonsCore/EditModel.swift`。两者冲突时以 kernel 为准，冲突本身在哪一节都会点名。

## 4.1 白平衡、色调与黑电平

**它解决什么问题**

把「这张图的光是什么颜色」定下来，再把用户想要的偏移叠上去。白平衡决定中性色落在哪，色调（tint）修绿/品红偏移，黑电平决定「0」在哪。三者的共同要求是：没碰过时必须逐字节不变。

**算法**

白平衡是解码参数：文档里的 (K, tint) 写回 `CIRAWFilter.neutralTemperature/neutralTint`，解码器据此出图（`Sources/PhotonsCore/EditModel.swift:1284`）。拖拽期间为了实时，另用本节这套**场景线性估计**给出等效增益预览——下面算的是估计器，不是解码器的模型。请求先落成 CIE 1960 uv 上的一个点：普朗克轨迹用 Kim 的解析拟合，并把 6500 K 平移到位，使它与工作白 D65 重合（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:240`）；tint 沿轨迹法线位移，幅度 $5\times10^{-5}$ uv/单位（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:287`）。uv → XYZ 后做 Bradford 适应到工作白，得到 3×3 矩阵（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:349`），但过 CPU/GPU 边界的不是矩阵，是三个归一化通道数。

记 $W(T)$ 为求解器在温度 $T$ 给出的线性白光，$T_{\text{ref}},\tau_{\text{ref}}$ 为参考对，则增益是通道比、绿归一：

$$
r=\frac{W_r(T_{\text{ref}})}{W_r(T)},\quad g=\frac{W_g(T_{\text{ref}})}{W_g(T)},\quad b=\frac{W_b(T_{\text{ref}})}{W_b(T)},\qquad (r,g,b)\leftarrow\left(\frac{r}{g},\,1,\,\frac{b}{g}\right)
$$

色调是编码域上的二次项，转到线性域就是一次乘与一次开方：

$$
s=\left(1+\frac{\tau-\tau_{\text{ref}}}{600}\right)^{2},\qquad g\leftarrow \frac{g}{s},\quad r\leftarrow \sqrt{s}\,r,\quad b\leftarrow \sqrt{s}\,b
$$

参考对不写死成 6500 K / 0。先从解码缓冲估出画面自己的照度：三个估计器（白块 p99.5、1 %–99 % 截尾的灰世界均值、梯度加权的灰边）各给一个答案，逐通道取中位数（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:91`、`Sources/PhotonsCore/WhiteBalanceEstimate.swift:98`）；测出的色度 ≤ 0.02 时退回名义值（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:364`）。所以「as shot」与「显式 6500 K」在已平衡的画面上互为恒等，而偏色画面上的请求是相对它自己的偏色。

黑电平是加法，且在增益之前：

$$
v \leftarrow v+o,\qquad o=\text{blackOffset}\in[-0.01,\,+0.01]
$$

位置是 071 定的：加法量要被同一个增益缩放，负样本才和正样本一起被抬过零（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:237`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `temperature` | 2000…12000 | `nil`（as shot） | K（`Sources/PhotonsCore/EditModel.swift:1291`） |
| `tint` | −150…150 | `nil` | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1293`） |
| `blackOffset` | −0.01…+0.01 | 0 | 线性光（`Sources/PhotonsCore/EditModel.swift:1322`） |
| `blackOffset` 滑杆 | −10…+10，整数 | 0 | 1/1000（`Sources/PhotonsCore/EditModel.swift:1324`） |
| 照度采样上限 | 120 000 | 120 000 | 像素（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:91`） |
| 增益夹取 | 1/20…20 | — | 倍（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:420`） |

**实现**

预览路径上，GPU 侧只有一行：`v *= p.a.x * p.a.yzw`（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:245`），`a` 的四个分量就是曝光增益与 wbR/wbG/wbB（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:150`）。as shot（不写回、也不加增益）时三个数是字面量 1（`Sources/PhotonsCore/RenderGraph.swift:3371`）；「未改动」还要求 `blackOffset == 0` 等条件同时成立，才走整段拷贝的分支（`Sources/PhotonsCore/RenderGraph.swift:3376`）。照度估计在 CPU、每个缓冲一次并缓存（`Sources/PhotonsCore/RenderGraph.swift:1548`），GPU 只拿到三个数——没有矩阵、没有查表。

**开源对照**

- darktable `temperature`（`src/iop/temperature.c`）：系数来自相机矩阵与按文件记录的照度选表，是「查表 + 相机模型」；本实现是在解码后的线性缓冲上自己估照度再算增益——https://github.com/darktable-org/darktable/blob/master/src/iop/temperature.c
- RawTherapee 的 RAW 阶段白平衡（`rtengine/rawimagesource.cc`）：乘子乘在去马赛克之前的马赛克上，以 `refwb_*` 的 as-shot 为参考；本实现乘在已去马赛克的线性图上，参考来自画面估计而不是文件记录——https://github.com/Beep6581/RawTherapee/blob/dev/rtengine/rawimagesource.cc

**取舍**

- 估计是抽样的：至多 12 万像素、确定性步长（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:118`）。一张大面积单色的画面，三个估计器会一起错。
- 增益夹在 1/20…20（`Sources/PhotonsCore/WhiteBalanceEstimate.swift:420`），极端请求在这个边界上饱和，而不是报错。
- `LightGroup.whiteBalanceGains` 还留着，但它是编码域拟合、约弱 2.2 倍，管线不用它（`Sources/PhotonsCore/EditModel.swift:1446`）。读代码的人容易把它当成实现。
- 预览与落定的关系：预览是增益、落定是解码器的模型，两者不承诺逐像素相同；一致的是请求的白点，不是实现。143 暂时删掉了写回，所以当前 `main` 上落定也走增益——核对清楚后再定这条取舍怎么写。

## 4.2 曝光

**它解决什么问题**

给整幅画面加减光。它必须是一次纯增益，必须在任何压缩之前完成——一旦压在显示域，被压掉的高光就再拿不回来。它也是 S1 里唯一不带窗口的增益：不改斜率、不改色度、不动任何端点。

**算法**

$$
v \leftarrow v\cdot 2^{E}
$$

$E$ 是文档的 EV。没有夹取、没有端点、没有曲线参与（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:245`）。位置固定：在加法微调之后、两个端点之前（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:239`、`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:251`）。

有一条配套约定让曝光可交换：`whites` 的窗口读「没加曝光的亮度」$L_0$，而不是画面当前的 $L$：

$$
L_0=L-\log_2 2^{E}
$$

（`Sources/PhotonsCore/Kernels/tone_shape.metal:233`。）于是曝光平移画面、不平移窗口，同一个 `whites` 数值在 E0 与 E+2 下作用在同一批场景影调上（`Sources/PhotonsCore/Kernels/tone_shape.metal:207`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `exposure` | −5…+5 | 0 | EV（`Sources/PhotonsCore/EditModel.swift:1245`） |
| 增益 `2^E` | 1/32…32 | 1 | 倍（`Sources/PhotonsCore/EditModel.swift:1437`） |
| `highlightRecovery` | 0…1 | 0 | 无量纲（`Sources/PhotonsCore/EditModel.swift:1295`） |

**实现**

增益在 CPU 上算：`exposureGain = pow(2, exposure)`（`Sources/PhotonsCore/EditModel.swift:1437`），作为 `S1Params.a.x` 传入（`Sources/PhotonsCore/RenderGraph.swift:3388`）。只有 `kKnee` 打开时，它才额外作为参数交给端点函数（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:257`），因为 $L_0$ 要用到它；`g = 1` 时 $L_0=L$ 逐位成立（`Sources/PhotonsCore/Kernels/tone_shape.metal:212`）。

高光恢复在同一次 dispatch 的最后：膝 0.8，`amount=0` 是精确恒等，`amount=1` 渐近 1.0（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:262`）。它永远排在端点之后——`whites` 说白点在哪，恢复说肩怎么压（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:139`）。

**开源对照**

- darktable `exposure`（`src/iop/exposure.c`）：同一模块里还有黑点与 deflicker，且黑点被约束在白点之下；本实现的曝光只有一个数，黑电平是另一个加法量、在增益之前——https://github.com/darktable-org/darktable/blob/master/src/iop/exposure.c
- darktable `filmicrgb`（`src/iop/filmicrgb.c`）：那里「曝光」是相对曝光的范围归一化，先定白/黑相对 EV 再上曲线；本实现的曝光是乘在光上的纯增益，范围由 `whites` 的 EV 窗口另行表达——https://github.com/darktable-org/darktable/blob/master/src/iop/filmicrgb.c

**取舍**

- kernel 不夹取 `p.a.x`。−5…+5 只是文档声明的范围（`Sources/PhotonsCore/EditModel.swift:1245`），手改文档能超出滑杆。
- 高光恢复吃的是 S1 出口的值，也就是已经过 `blacks`/`whites` 的值；想把肩放在端点之前，目前没有位置。

## 4.3 高光、中间调、阴影

**它解决什么问题**

三个滑杆分别抬或压暗部、中间调、亮部，而互不打架。判据有两条：每个亮度必须有一个满权主人，中间不能有死带（两个滑杆都不作用的带）。

**算法**

权重是两条互补的 smoothstep 链，坐标是 $L=\log_2 Y$（相对显示白的 EV，直方图自己的轴）：

$$
a=\mathrm{ss}(-5.4,-3.9,L),\quad b=\mathrm{ss}(-2.4,-0.9,L),\quad c=\mathrm{ss}(4.0,6.0,L)
$$

$$
w_s=1-a,\qquad w_m=a(1-b),\qquad w_h=b(1-c)
$$

$a$ 在 $b$ 起步之前就已到 1，所以 $L<+4$ 时 $w_s+w_m+w_h=1$：没有哪个亮度是没人管的（`Sources/PhotonsCore/Kernels/tone_shape.metal:98`、`Sources/PhotonsCore/Kernels/tone_shape.metal:104`）。增益只有一个 `exp2`：

$$
v \leftarrow v\cdot 2^{\,w_s d_s+w_m d_m+w_h d_h}
$$

$d_i$ 是**已经过门**的 EV 位移，在 CPU 上算：

$$
d_i=\frac{s_i}{100}\Delta_i,\qquad \Delta_s=0.90,\ \Delta_m=0.70,\ \Delta_h=0.60
$$

（`Sources/PhotonsCore/S2Regions.swift:40`。）三个行程反号时会把局部斜率压穿，所以有一道公共压缩：

$$
\text{deficit}=\max\left\{|d_m-d_s|,\ |d_h-d_m|,\ \tfrac{1.5}{2.0}|d_h|\right\},\qquad \text{deficit}>1-\sigma\ \Rightarrow\ d\leftarrow d\cdot\frac{\sigma}{\text{deficit}}
$$

$\sigma=0.500$（`Sources/PhotonsCore/S2Regions.swift:52`、`Sources/PhotonsCore/S2Regions.swift:82`）。方向照 Lightroom：`+` 提亮该区，`−` 压暗（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:31`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `shadows` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1252`） |
| `midtones` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1251`） |
| `highlights` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1247`） |
| 满行程 | 0.90 / 0.70 / 0.60 | — | EV（`Sources/PhotonsCore/S2Regions.swift:40`） |
| 最小斜率 $\sigma$ | 0.500 | 0.500 | — （`Sources/PhotonsCore/S2Regions.swift:52`） |
| 窗口边界 | −5.4/−3.9，−2.4/−0.9，+4.0/+6.0 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:90`、`Sources/PhotonsCore/Kernels/tone_shape.metal:95`） |

**实现**

分工很清楚：kernel 只做权重与一次 `exp2`（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:90`、`Sources/PhotonsCore/Kernels/s2_tone_map.metal:92`），行程和单调性门都在 CPU 的 `S2Regions.travelEV`（`Sources/PhotonsCore/S2Regions.swift:73`）——kernel 收到的是 EV，不是滑杆位置（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:26`）。“图不会折”因此是一个可计算的属性，而不是窗口宽度选得巧。

S2 在入口**不夹取**：`v = c.rgb` 直接进权重（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:83`），只在本阶段末尾取 `max(v, 0)`（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:97`）。原因是解码器会给零以下的样本，抬升已把它们拉过零的像素是真画面（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:78`）。alpha 0 与内容矩形两道守卫在像素运算之前（`Sources/PhotonsCore/Kernels/s2_tone_map.metal:66`、`Sources/PhotonsCore/Kernels/s2_tone_map.metal:73`），否则抬暗部会把黑边一起点亮。

**开源对照**

- darktable `toneequal`（`src/iop/toneequal.c`）：在场景线性相机 RGB 上按曝光八度建高斯权重系，解线性系统得到各区增益；本实现是显示参考域的三个互补窗口，没有空间项、没有解法——https://github.com/darktable-org/darktable/blob/master/src/iop/toneequal.c
- RawTherapee `shadows/highlights`（`rtengine/ipshadowshighlights.cc`）：带半径的 Lab 亮度分带，是局部算子；本实现是逐像素、无半径的窗口，作用域只由蒙版决定——https://github.com/Beep6581/RawTherapee/blob/dev/rtengine/ipshadowshighlights.cc

**取舍**

- 单个 `shadows +100` 拿不到 0.90 EV：门会把它压到 0.50（`Sources/PhotonsCore/S2Regions.swift:44`）。三个滑杆的满行程是标称值，不是保证值。
- 两条接缝都是钉死的 1.5 EV（`Sources/PhotonsCore/S2Regions.swift:83`），不随画幅、不随内容自适应；动态范围很窄的图可能整幅落在某条接缝上，三个滑杆于是都动它。
- 蒙版内的阴影/高光仍用 074 的两窗口 `region_weights`（`Sources/PhotonsCore/Kernels/tone_shape.metal:53`），与全局的三段**故意**不同步（`Sources/PhotonsCore/Kernels/tone_shape.metal:30`）。同一次拖动，全局与蒙版的响应因此不完全同形。

## 4.4 白点与黑点

**它解决什么问题**

把最暗与最亮钉在哪。纯乘法做不到：`0 → 0` 对任何增益都成立，所以黑点既压不到 0 也浮不起来；纯加法会造灰。答案是「EV 膝 + 电平」的混合，两半按行程混合。

**算法**

记 $t=\text{blacks}/100$，$a=|t|$，$L$ 是端点的坐标（BT.709 亮度取对数）：

$$
w_b=1-\mathrm{ss}(-12,-1,L),\qquad v\leftarrow v\cdot 2^{3.0\,t\,w_b}
$$

这就是前半段，也是整个 $|t|\le 0.2$ 时的全部算术（`Sources/PhotonsCore/Kernels/tone_shape.metal:237`、`Sources/PhotonsCore/Kernels/tone_shape.metal:267`）。超过 0.2 之后电平进场：

$$
m=\mathrm{ss}(0.2,1,a),\qquad w_l=1-\mathrm{ss}(-6,-1,L),\qquad \text{off}=0.006\,t\,m\,w_l
$$

$$
\text{off}<0:\ v\leftarrow T(v+\text{off})\cdot g,\qquad \text{off}>0:\ v\leftarrow T(v\cdot g+\text{off}),\qquad g=2^{3.0\,t\,w_b}
$$

（`Sources/PhotonsCore/Kernels/tone_shape.metal:245`、`Sources/PhotonsCore/Kernels/tone_shape.metal:250`、`Sources/PhotonsCore/Kernels/tone_shape.metal:262`。）**顺序看符号**，这是单调性的来源：压暗时两件事都变暗，先电平后增益；提亮时电平必须骑在增益**外面**，否则 ±0.006 在 8× 增益里会被放大八倍，最暗的那一格反而最亮（`Sources/PhotonsCore/Kernels/tone_shape.metal:254`）。

$T$ 是 C¹ 整流器，膝 $k=10^{-3}$：

$$
T(x)=\begin{cases}x, & x\ge k\\ 0, & x\le -k\\ \dfrac{(x+k)^2}{4k}, & \text{otherwise}\end{cases}
$$

（`Sources/PhotonsCore/Kernels/tone_shape.metal:186`。）压暗一侧真的会到 0——那就是「改电平」的意思；提亮一侧 `off ≥ 0` 不夹取，所以 `t=+1` 不会把正的样本压到 0。

白点用同一个函数的后半段，但读 $L_0$：

$$
u=\frac{\text{whites}}{100},\qquad w_w=\mathrm{ss}(-2,2,L_0),\qquad \lambda=\frac{1}{1-0.20\,u\,|u|},\qquad v\leftarrow v\cdot 2^{1.2\,u\,w_w}\cdot\lambda
$$

（`Sources/PhotonsCore/Kernels/tone_shape.metal:275`、`Sources/PhotonsCore/Kernels/tone_shape.metal:276`。）$\lambda$ 是乘法电平、没有窗口，所以它缩放每一档亮度（含 HDR 尾）；$u=0$ 时 $\lambda=1$，中性文档逐字节不变（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:113`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `blacks` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1275`） |
| `whites` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1257`） |
| 黑 EV 满行程 $B_{EV}$ | 3.0 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:117`） |
| 黑膝窗口 | −12…−1 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:118`、`Sources/PhotonsCore/Kernels/tone_shape.metal:119`） |
| 电平幅度 $B_{LEV}$ | 0.006 | — | 线性光（`Sources/PhotonsCore/Kernels/tone_shape.metal:129`） |
| 电平窗口 | −6…−1 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:130`、`Sources/PhotonsCore/Kernels/tone_shape.metal:131`） |
| 电平膝 | 1e-3 | — | 线性光（`Sources/PhotonsCore/Kernels/tone_shape.metal:132`） |
| 电平入场点 | \|blacks\| > 20 | — | 滑杆单位（`Sources/PhotonsCore/RenderGraph.swift:3196`） |
| 白 EV 满行程 $W_{EV}$ | 1.2 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:170`） |
| 白电平 $W_{LEV}$ | 0.20 | — | 无量纲（`Sources/PhotonsCore/Kernels/tone_shape.metal:171`） |
| 白点窗口 | −2…+2 | — | EV（`Sources/PhotonsCore/Kernels/tone_shape.metal:172`、`Sources/PhotonsCore/Kernels/tone_shape.metal:173`） |

**实现**

一个模板函数、七个入口。`kKnee`/`kHybrid`/`kTrim`/`kCalib` 都是编译期常量（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:209`），CPU 按值选名字（`Sources/PhotonsCore/RenderGraph.swift:3213`）：`|blacks| > 20` 才进 `_hybrid`（`Sources/PhotonsCore/RenderGraph.swift:3196`），否则是 073B 的那一支。分派阈值与 $m$ 的零点重合，所以两支在边界上逐位相等（`Sources/PhotonsCore/Kernels/tone_shape.metal:196`）。真要两个滑杆都是 0，`p.b.y` 让整段拷贝直接返回（`Sources/PhotonsCore/Kernels/s1_scene_linear.metal:216`）。

**开源对照**

- darktable `levels`（`src/iop/levels.c`）：黑、中间、白三个把手，作用在显示参考的 0…1 上，是一次跨度的仿射重映射；本实现的黑白点是场景线性域的两个端点，动的是膝与电平，不改整幅斜率——https://github.com/darktable-org/darktable/blob/master/src/iop/levels.c
- RawTherapee 的 RAW 黑白电平（`rtengine/rawimage.cc`）：逐通道从遮罩/元数据求黑电平，是解码域的钳位；本实现的端点在解码之后，是用户可以拖的量——https://github.com/Beep6581/RawTherapee/blob/dev/rtengine/rawimage.cc

**取舍**

- 端点亮度用的是 BT.709 权重（`Sources/PhotonsCore/Kernels/tone_shape.metal:181`），不是工作基色 Rec.2020；S1 还没迁移，因为 `BwLevelsTests` 的数都钉在这三个数上（`Sources/PhotonsCore/Kernels/tone_shape.metal:175`）。
- `whites` 的电平是全局乘法，物理上限很小：p1 只动 2–5 码（`Sources/PhotonsCore/Kernels/tone_shape.metal:145`）。要暗部明显变亮，它是错的工具，`blacks` 的 EV 膝或 `exposure` 才对。
- `EditModel` 的注释还写着旧常数：$m=\mathrm{ss}(0.5,1,a)$、0.005、窗口 −6.9…−4.4（`Sources/PhotonsCore/EditModel.swift:1263`），而 kernel 是 0.2 / 0.006 / −6…−1。以 `tone_shape.metal` 为准；`EditModel.blacksEVToLevelSplit = 50`（`Sources/PhotonsCore/EditModel.swift:1283`）也已经不是实际阈值。

## 4.5 全局对比度

**它解决什么问题**

让局部反差变大，同时不动整体亮度。乘一个幂律斜率做不到这件事：它把中间调一起推上顶，细节与整体分不开。还有一条硬条件——它必须与曝光可交换：先加曝光再加对比，与先对比再加曝光，必须是同一张图。

**算法**

只分解亮度 $Y$（显示参考、白 = 1 = 0 EV），一切增益都是**残差**，没有绝对锚点：

$$
Y=\max(\langle\max(\mathrm{rgb},0)\rangle_w,\,10^{-6}),\qquad G=\log_2 Y
$$

$$
B_c=\mathrm{GF}(G;r_c,\varepsilon_c),\quad D_1=G-B_c,\quad B_m=\mathrm{GF}(D_1;r_m,\varepsilon_m),\quad D_f=D_1-B_m
$$

$$
G'=G+\gamma\left(k_mB_m+k_fD_f\right),\qquad \mathrm{rgb}'=\max(\mathrm{rgb},0)\cdot 2^{G'-G}
$$

（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:17`。）$\mathrm{GF}$ 是自引导滤波，$a=\mathrm{var}/(\mathrm{var}+\varepsilon)$、$b=\bar I(1-a)$（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:266`）。$\gamma$ 是梯度门，读的是窗口均值的梯度：

$$
\gamma=1-\mathrm{ss}(0.05,\,2.00,\,|\nabla \bar D_1|)
$$

（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:274`。）门只乘两条细节带，所以强边附近不会被放大成晕。

权重两段不同律（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:300`）：

$$
t\ge 0:\ k_m=7.50\,t,\ k_f=3.75\,t;\qquad t<0:\ k_m=k_f=2^{0.75t}-1
$$

负向是**收缩**，不是反号的行程：残差最小乘到 0.59，恒为正（`Sources/PhotonsCore/ContrastMultiscale.swift:184`）。正向到白点要淡出，并给一个上限：

$$
d>0:\quad d\leftarrow d\left(1-\mathrm{ss}(-1,0,G)\right),\qquad G<\log_2 0.98\ \Rightarrow\ d\le\log_2 0.98-G
$$

（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:327`。）所以白点以下没有像素能被推上顶；而已经大于 1 的 HDR 样本照常扩张（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:329`）。黑地板 0.00110 保证「清过地板」的像素不会被压到地板以下（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:341`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| `contrast` | −100…100 | 0 | 滑杆单位（`Sources/PhotonsCore/EditModel.swift:1246`） |
| 中带权重 $W_m$ | 7.50 | 7.50 | EV/EV（`Sources/PhotonsCore/ContrastMultiscale.swift:72`） |
| 细带权重 $W_f$ | 3.75 | 3.75 | EV/EV（`Sources/PhotonsCore/ContrastMultiscale.swift:77`） |
| 粗/中 $\varepsilon$ | 0.80 / 0.32 | — | $\log_2^2$（`Sources/PhotonsCore/ContrastMultiscale.swift:59`、`Sources/PhotonsCore/ContrastMultiscale.swift:62`） |
| 门膝 | 0.05 / 2.00 | — | $\log_2$/texel（`Sources/PhotonsCore/ContrastMultiscale.swift:92`、`Sources/PhotonsCore/ContrastMultiscale.swift:93`） |
| 统计块 $q$ | 4 | 4 | 像素（`Sources/PhotonsCore/ContrastMultiscale.swift:103`） |
| 粗/中半径 | 短边 6 % / 2 %，上限 96 / 24 | — | 1/q texel（`Sources/PhotonsCore/ContrastMultiscale.swift:118`、`Sources/PhotonsCore/ContrastMultiscale.swift:121`） |
| 统计代理长边 | 1024 | 1024 | 像素（`Sources/PhotonsCore/ContrastMultiscale.swift:115`） |
| 负向收缩指数 | 0.75 | 0.75 | — （`Sources/PhotonsCore/ContrastMultiscale.swift:184`） |
| 黑地板 | 0.00110 | — | 线性光（`Sources/PhotonsCore/ContrastMultiscale.swift:99`） |

**实现**

统计不在全分辨率上做。系数图在长边 1024 的**整幅代理**上建一次并缓存（`Sources/PhotonsCore/ContrastMultiscale.swift:115`、`Sources/PhotonsCore/RenderGraph.swift:3732`），所以适应、25 %、1:1、平移中的 1:1 窗口取样的是同一张图——一个物理像素的增益不能取决于窗口在哪。kernel 分五个 pass：pack（每 $q\times q$ 块写均值与平方均值）→ 水平盒 → 垂直盒 → 系数 → apply，带蒙版时 apply 换成 masked 变体。

一个细节让曝光与对比可交换：分解读的是**没加曝光的显示对数** $G=\log_2(Y/2^{E})$（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:386`），曝光只是把画面平移过同一张系数图。带蒙版时，蒙版自己的线性增益要先折进 $G$（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:451`），否则同一个 `contrast` 在蒙版内外是两套算子。

**开源对照**

- RawTherapee `local contrast`（`rtengine/iplocalcontrast.cc`）：对 Lab 的 $L$ 做 FFT 高斯模糊，按半径与明暗三参数做非锐化式局部对比；本实现是显示对数上的引导滤波多尺度残差，且残差增益与曝光无关——https://github.com/Beep6581/RawTherapee/blob/dev/rtengine/iplocalcontrast.cc
- darktable `local contrast`（`src/iop/bilat.c`）：双边网格或局部拉普拉斯滤波，跑在 Lab 亮度上，带空间半径；本实现的分解是 $q=4$ 块统计上的自引导滤波，没有双边权重，也不做边缘保持的显式项——https://github.com/darktable-org/darktable/blob/master/src/iop/bilat.c

**取舍**

- 负向只能把残差压到 0.59×，永远不是 0：`2^t` 会把画面均值拉走 −1.21 码，超出「±1 码」的预算，所以取了 0.75（`Sources/PhotonsCore/Kernels/s1_8_contrast.metal:306`）。
- 门的 0.05/2.00 不在「显示域是场景域 1/4 宽」的 ×4 规则上，是这组常数里唯一的例外，理由是门的输入是 $q$ 域的窗口均值梯度（`Sources/PhotonsCore/ContrastMultiscale.swift:89`）。
- 系数图固定 1024 长边：画面小于 1024 时它就是自己（逐位复用旧系数），大于它时 1:1 拿到的是上采样结果（`Sources/PhotonsCore/ContrastMultiscale.swift:105`）。

## 4.6 HDR 曲线

**它解决什么问题**

一条曲线，要同时弯 SDR 的 0–255 与显示白以上的 +0…+4 EV，而且必须与它上面的直方图同轴——左半是显示码，右半是 stops。它是管线里唯一一个用户直接画形状的算子：不解释画面，只执行点列。

**算法**

横轴 $u$ 是分段函数，SDR 半边用 sRGB 编码，HDR 半边用 $\log_2$：

$$
u(x)=\begin{cases}0.5\,\mathrm{sRGB}(x), & 0<x\le 1\\ 0.5+0.125\log_2 x, & x>1\end{cases}
\qquad
x(u)=\begin{cases}\mathrm{sRGB}^{-1}(2u), & u\le 0.5\\ 2^{8(u-0.5)}, & u>0.5\end{cases}
$$

（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:15`。）于是 $u(0.18)=0.2307$、$u(1)=0.5$、$u(4)=0.75$、$u(16)=1$（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:20`）。白点位置 $0.5$ 与每档宽度 $0.125$ 都从 uniform 来，不写死在 kernel 里（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:109`），CPU 的参考实现与 GPU 的整形器因此不可能漂移。

表里存的是 $v\in[0,1]$，插值在 $u$ 上做（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:126`）。W 曲线是**亮度增益**，不是逐通道查表：

$$
v\leftarrow v\cdot 2^{\Delta},\qquad \Delta=\mathrm{clamp}\left(\log_2\frac{x(v)}{x(u)},\,-12,\,+12\right)
$$

（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:237`。）$\Delta$ 是两束**光**的比，不是 $u$ 差乘常数——SDR 半边上 1 个 $u$ 是 12–100 个 stops，乘常数会让中间调弱 40 %（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:231`）。R/G/B 是可分表，各自独立：

$$
v_c\leftarrow x\left(\mathrm{LUT}_c\big(u(v_c)\big)+\max(u-1,0)\cdot\mathrm{clamp}(s_c,-2,2)\right)
$$

（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:180`、`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:243`。）顺序 W → R → G → B：先整幅影调，再偏色（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:94`）。

四条边界规则都不 Optional：① 恒等表直接拷贝（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:192`）；② alpha 0 与内容矩形的守卫（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:198`、`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:205`）；③ $x\le0$ 原样穿过、保号，**除非**黑点被抬过（此时落进表的常值段，负样本一起被夹）（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:175`）；④ $u>1$ 按末段斜率继续，不夹取（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:180`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 |
|---|---|---|---|
| 控制点 $x$ | 0…2 | 0 | 轴坐标 $u=x/2$（`Sources/PhotonsCore/EditModel.swift:1740`、`Sources/PhotonsCore/EditModel.swift:1751`） |
| 控制点 $y$ | 0…2 | — | 同上（`Sources/PhotonsCore/EditModel.swift:1757`） |
| 恒等点列 | — | (0,0),(2,2) | （`Sources/PhotonsCore/EditModel.swift:1823`） |
| 表长 $N$ | 4096 | 4096 | 采样点（`Sources/PhotonsCore/EditCurve.swift:45`） |
| 表数 | 4（W/R/G/B） | 4 | 张（`Sources/PhotonsCore/EditCurve.swift:52`） |
| 末段斜率 | −2…+2 | 由末两点算 | EV/u（`Sources/PhotonsCore/HDRCurve.swift:190`、`Sources/PhotonsCore/HDRCurve.swift:200`） |
| 曲线格式 | version 2、`double`、`max: 2` | 同 | （`Sources/PhotonsCore/EditModel.swift:1549`） |
| `processVersion` | 2 | 2 | （`Sources/PhotonsCore/EditModel.swift:141`） |

**实现**

一张 4×4096 的 float 表在 GPU 缓冲里，kernel 只读（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:187`）。恒等表按位掩码跳过（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:218`、`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:227`）——整形器往返会带 ~5e-7 的误差，在 fp16 边界上就是 1 bit。末段斜率由表尾两点算（`Sources/PhotonsCore/EditCurve.swift:126`），夹取的两端是同一个数：`tailSlopeLimit = 2`、`tailSlopeFloor = -2`（`Sources/PhotonsCore/HDRCurve.swift:190`、`Sources/PhotonsCore/HDRCurve.swift:200`）。

**开源对照**

- darktable `tonecurve`（`src/iop/tonecurve.c`）：表的末段用拟合出的幂律外推，不夹取；本实现的末段是线性外推加 ±2 的斜率夹取，斜率直接就是 +4 EV 以上的对数对比——https://github.com/darktable-org/darktable/blob/master/src/iop/tonecurve.c
- darktable `AgX`（`src/iop/agx.c`）：基色压缩 + log + sigmoid 的整幅色调映射，形状由模块给；本实现的曲线形状由用户点列给，模块只负责轴与边界——https://github.com/darktable-org/darktable/blob/master/src/iop/agx.c
- Filmulator 的胶片曲线（`filmulator-gui/Halide/applyfilmlikecurve.cpp`）：先把 RGB 排序，逐通道查表，中间通道按低/高两条的差线性插值以保序；本实现的 W 曲线是亮度增益，三通道按同一 $\Delta$ 缩放，保的是色相与饱和——https://github.com/CarVac/filmulator-gui/blob/master/filmulator-gui/Halide/applyfilmlikecurve.cpp

**取舍**

- W 曲线永远不会被反相：下降的 W 点列到了 kernel 就是恒等表（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:97`）。负片的下降只能交给 R/G/B 三张表，它们各自可以整体下降（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:99`）。
- $u>1$ 是线性外推，一段之外没有第二道形状；斜率夹在 ±2 是防手改文档，不是画面决定（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:71`）。
- $\Delta$ 夹在 ±12 EV 是 fp16 保护：把白点从 0.5 拖到 1.0 是 +9 EV，200 级的像素在 half float 里已经接近 inf（`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:235`、`Sources/PhotonsCore/Kernels/s1_7_hdr_curve.metal:238`）。所以极端的点列会被截断，而且不会有提示。

---

曲线之后，S2 交出 `0…1`，S2.5 的对比与 S3 的色彩才有可用的坐标。这六节加起来只说明一件事：每个滑杆都待在自己的域里，而且都能被一行算式复述。
