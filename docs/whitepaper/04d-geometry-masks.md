# 4.16–4.17 几何与蒙版

两节：几何（S0）与蒙版权重（S1.5 / S1.6 / S3.5）。前者决定每个画布像素读源图的哪个点、画布多大；后者决定一次调整覆盖画面的多少。两者的共同要求还是那句话——没碰过的文档必须逐字节不变。

## 4.16 几何：裁切、拉直、翻转、90°、透视与横向色差（S0）

S0 是唯一改变像素网格本身的阶段：它把画布上每个像素映射回源文件的一个采样点，之后所有按像素做的运算都以它的输出为准（`Sources/PhotonsCore/Kernels/s0_geometry.metal:9`）。这一节只回答两件事：**读哪个点**，**画布多大**。

**它解决什么问题**

裁切决定输出框，拉直把地平线转正，翻转与 90° 管整幅方向，透视把建筑照里汇聚的竖线拉回平行，横向色差收回红蓝相对绿的径向放大（`Sources/PhotonsCore/EditModel.swift:2457`）。五件事共用一个结构：都是**在固定参考系里重采样**，可写成一条「画布 → 源像素」的映射。

代价是它必须精确到最后一位：快速路径、八个入口、「θ = 0 时不出现一次乘法」，都是为了让没碰过几何的文档逐字节等于没有几何（`Sources/PhotonsCore/Kernels/s0_geometry.metal:105`）。

**算法**

#### 裁切框的表示

文档只有一个裁切矩形的真值，两种拼法：`crop` 是原点加尺寸，`cropRect` 是同一矩形的四条边，`right`/`bottom` 是**绝对边界**而非宽高，所以 `full` 是 `(0, 0, 1, 1)` 而不是 `(0, 0, 0, 0)`（`Sources/PhotonsCore/EditModel.swift:1157`、`Sources/PhotonsCore/CropMath.swift:12`）。坐标是未裁切源图的归一化坐标，原点左上（`Sources/PhotonsCore/Masks.swift:5`）。

#### 从画布到源像素：一条仿射链

记画布像素 $x$（像素中心在 $\mathit{gid} + \frac{1}{2}$），内容原点 $o_{c}$、帧原点 $o_{f}$、帧尺寸 $s_{f}$、裁切原点 $c_{0}$ 与跨度 $c_{w}$、源尺寸 $s$、翻转符号 $\sigma \in \left\{ \pm 1 \right\}^{2}$、顺时针四分之一转的置换 $T_{q}$：

$$
\begin{array}{l}
{x_{1} = x + \frac{1}{2} - o_{c},\quad x_{2} = x_{1} + o_{f},\quad u = x_{2} \oslash s_{f}} \\
{u' = \sigma \odot u + \frac{1 - \sigma}{2}} \\
{r = \frac{1}{2} + s_{f}^{- 1} \odot \left\lbrack R(\theta)\left( \left( u' - \frac{1}{2} \right) \odot s_{f} \right) \right\rbrack} \\
{z = c_{0} + c_{w} \odot r,\quad w = T_{q}z,\quad p = s \odot w}
\end{array}
$$

$R(\theta) = \begin{bmatrix}
{\cos\theta} & {- \sin\theta} \\
{\sin\theta} & {\cos\theta}
\end{bmatrix}$，$y$ 向下，正角度即屏幕上的顺时针（`Sources/PhotonsCore/CropGeometry.swift:35`）。

第三行是唯一要解释的一项：$R$ 乘的是**像素偏移** $\left( u' - \frac{1}{2} \right) \odot s_{f}$。直接旋转归一化坐标得到的是 $s_{f}^{- 1}Rs_{f}$，非对角项差 $s_{x}/s_{y}$ 倍——3:2 的帧剪切 1.5 倍，拉直出来是歪的不是转的（`Sources/PhotonsCore/Kernels/s0_geometry.metal:118`）。固定 $q$、$\theta$ 时整条链是仿射的：$T_{q}$ 是带符号置换，其余是缩放、平移与旋转。

#### 90°：置换而不是旋转

`quarterTurns` 只存一个 0…3 的整数：「图像被顺时针转了几个 90°」。导出写 `tiff:Orientation` 用的是同一个数，两处各存一份会让「哪边是顺时针」有两种答案（`EditModel.swift:970`）。帧转 $q \cdot 90^{\circ}$（奇数时宽高互换），`crop` 量在转过的帧里，所以转帧时裁切框跟着转、仍覆盖照片上同一块像素（`:981`、`CropMath.swift:683`）：

$$
(l,t,r,b)\mapsto(1 - b,l,1 - t,r)
$$

四次转回原位是精确的：$1 - x$ 对 $x \in \lbrack 0,1\rbrack$ 在二进制浮点里无误差，映射又只是四个数的排列（`CropMath.swift:687`）。核心里顺序是「先拉直、再反解 90°、最后走裁切框」：照片的像素没被转过，转的只是位置（`s0_geometry.metal:238`）。

#### 画布：包围盒，且只在真的旋转时变大

直角处（0/90/180/270）画布就是裁切框的像素尺寸，一个像素都不多；其它角度是旋转后裁切框的**精确包围盒**，只向上取整一次（`CropMath.swift:580`）：

$$
W = \left\lceil w \vert \cos\theta \vert + h \vert \sin\theta \vert \right\rceil,\quad H = \left\lceil w \vert \sin\theta \vert + h \vert \cos\theta \vert \right\rceil
$$

用 `ceil` 而非 `round`：5400×3600 的裁切框在 1° 下是 5462.006 宽，`round` 给 5462，画布就切掉了旋转后的角（`:591`）。所以「输出尺寸」报的是 `canvasSize` 而不是裁切框尺寸（`EditModel.swift:1111`）；多出来的部分写透明，不是把边缘拖出去（`s0_geometry.metal:275`）。

#### 透视：一台单应，近端不动

两个滑杆各是一个梯形强度 $p_{v},p_{h} \in \lbrack - 100,100\rbrack$：

$$
v_{k} = - \frac{p_{k}}{100} \cdot 0.21,\quad M_{v} = \begin{bmatrix}
1 & {- \frac{v_{v}}{2}} & \frac{v_{v}}{2} \\
0 & {1 - v_{v}} & v_{v} \\
0 & {- v_{v}} & {1 + v_{v}}
\end{bmatrix},\quad H = M_{h}M_{v}
$$

$H$ 是「帧 → 变形后的帧」，核心里用它的逆把采样点送回帧归一化坐标：$z' = \pi\left( H^{- 1}(z,1) \right)$，$\pi(x,y,w) = (x/w,y/w)$（`CropMath.swift:325`、`s0_geometry.metal:265`）。

满行程是方形画幅上 6° 的收敛，即 $2\tan 6^{\circ} \approx 0.21$，±50 是 3°（`EditModel.swift:1004`、`CropMath.swift:283`）。符号让 $w = 1 + vs$ 随离近端距离变大：远端展开、近端收住，「+」修的是从下往上拍的照片（`:306`）。画布取变形四边形里**保住不动角**的最大内接矩形，闭式求解：每条边给一条 $\alpha w + \beta h \leq c$，最优解在至多十个候选里取面积最大者（`:359`）。

#### 横向色差：一个比例，不是位移

$\alpha$ 是**无量纲的径向比例**：$\alpha_{R} > 0$ 表示红通道的像比绿通道大，校正按

$$
p_{c} = a + (p - a)\left( 1 + \alpha_{c} \right),\quad a = \frac{s}{2},\quad c \in \left\{ R,B \right\}
$$

只重采样红与蓝，绿原样读（`s0_geometry.metal:344`）。比例而非像素位移是这里唯一重要的设计：400 px 预览与 9504 px 导出校正同一段半径比例；换成像素值，同一个滑杆在两种尺寸下就是两件事（`EditModel.swift:2461`）。中心取**源图**中心而非裁切框中心——色差是光轴的性质，裁切与旋转不该把无像差的点挪走（`s0_geometry.metal:346`）。满行程 ±0.005，面板 ±100、步长 0.1（`EditModel.swift:2473`、`:2515`）。

**参数与范围**

| 参数 | 范围 / 默认 | 单位 | 作用 |
|---|---|---|---|
| `crop` | 0…1，默认 `full` | 源归一化 | 输出框，四边是绝对边界（`EditModel.swift:960`、`:1157`） |
| `aspectLock` | `.original` = 无约束 | 像素比 | 锁定时重写矩形（`:967`、`:1195`） |
| `rotationDegrees` | ±45°，默认 0 | 度，正 = 顺时针 | S0 读钳过的 `straightenDegrees`（`:958`、`:1175`） |
| `flipHorizontal` / `flipVertical` | `false` | — | 帧内镜像（`:965`） |
| `quarterTurns` | 0…3，默认 0 | 90° 计数 | `n % 4` 归一（`:994`、`:1036`） |
| `perspectiveVertical` / `perspectiveHorizontal` | ±100，默认 0 | 强度 | 0/0 时 `perspective` 为 `nil`（`:1010`、`:1184`） |
| `caRed` / `caBlue` | ±0.005，默认 0 | 径向比例 α（`:2476`） | 横向色差 |
| `alphaPerSliderUnit` / `sliderStep` | 5×10⁻⁵、0.1 | α / 单位 | 滑杆 ±100 恰映射到 ±0.005（`:2519`、`:2524`） |

`isIdentity` 与键都按值判定：`caRed == caBlue == 0` 是快速路径的判据（`:2496`）；`quarterTurns`、`perspectiveV/H` 为 0 时连 JSON 键都不写，老文档重存逐字节不变（`:1078`）。

**实现**

`Kernels/s0_geometry.metal` 是一个模板体加三组模板参数 `HAS_ROTATION`、`HAS_TURN`、`HAS_LENS_WARP`（共八个入口），由 `RenderGraph` 按 `straightenDegrees != 0`、`quarterTurns != 0` 与镜头剖面选择（`s0_geometry.metal:130`、`RenderGraph.swift:1863`）。

**三条快速路径**，各解决一个「本来不该有算术」的场景：

- **identity**：满幅、无旋转无翻转、无窗口、画布等于源尺寸，逐 texel 拷贝；出口矩阵仍跑，「恒等」说的是采样而不是色彩空间（`s0_geometry.metal:140`、`:38`）。
- **pure-CA**：上面再加 $\alpha \neq 0$。绿按 texel 直读，只有红蓝重采样，这一帧的绿与 identity 逐字节相同（`:192`）。
- **pure-turn**：只转了 90°。通用路径会做 ${uv} = f/s_{f}$ 再乘回源尺寸，在 9504 px 上是约 10⁻³ texel 的往返，等于给没有算术的操作加插值，四次就回不到原字节；源索引改在 `int` 里算：源 $(i,j)$ 出现在转过一档的帧的 $(H - 1 - j,i)$（`:151`）。

三个标志由 `RenderGraph.plan` 一处判定：`untransformed` 是 pre-029 的恒等条件，`s0PureTurn` 再加满幅、1:1、无窗口、无 CA（`RenderGraph.swift:1863`、`:1876`、`:1890`）。顺序也被钉住：**先反解旋转、再走单应、最后反解 90°**（`s0_geometry.metal:251`）。

镜头 warp 也在这里：有 `WarpRectilinear` 三平面时逐通道做 $p_{c} = {center} + ({px} - {center}) \cdot s_{c}(r)$，$s_{c}$ 是 `kr0 + kr1·r² + kr2·r⁴ + kr3·r⁶`——**偶次幂**。写成奇次幂在系数全零时与规范一致，合成测试抓不到，真实文件上却把整幅图移动约 0.4 % 的半径（`:315`）；顺序是先 warp、后手动 α（`:306`）。

**开源对照**

- **darktable 的「裁剪」**：可拖拽矩形加宽高比列表（`freehand`、`original image`、`square`、`golden cut` 等预设）（<https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/crop/>）。Photons 拆成「归一化四边 + 具名 `AspectLock`」，锁定与矩形不一致时锁定胜出（`EditModel.swift:1195`）。差别在画布：darktable 的裁剪就是输出框，Photons 在非直角下是包围盒（`CropMath.swift:580`）。
- **darktable 的「旋转与透视」**：用检测或手画的线段做**拟合**反推参数，机制源自 ShiftN（<https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/rotate-perspective/>）。Photons 不拟合：两个 ±100 的强度直接给出 6° 满行程，能被一句公式说清、被一个测试钉住（`CropMath.swift:283`）。
- **darktable 的「镜头校正」**：畸变与 TCA 来自 lensfun 剖面或文件内嵌元数据，是「按型号查表」的路线（<https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/lens-correction/>）。Photons 两条腿都有：有 DNG 三平面时用文件自己的 `WarpRectilinear`，否则用 Apple 的，再叠一层手动 α（`EditModel.swift:2465`、`s0_geometry.metal:293`）——手动那层是给没有剖面的镜头准备的。

**取舍**

**先变形、后裁切。** 裁切框是输出框，所以拉直不会自动「放大填满」，转过的角是背景而不是黑边（`s0_geometry.metal:23`）。自动填满得先替用户决定裁多少；代价是拉完角度通常还要再收一次框。

**画布尺寸与裁切框尺寸不是同一个数。** 直角处相等，别的角度画布更大（`CropMath.swift:613`）。这条写错，信息栏尺寸与 loupe 取景会同时错位（188 就是为这个加的，`EditModel.swift:1111`）。

**透视固定 6°，不做自动拟合。** 6° 覆盖多数手持建筑照的收敛量，与「近端不动」一起使画布有闭式解（`CropMath.swift:270`）。超出 6° 需先裁再校，或接受远端被放大。

---

## 4.17 蒙版权重：画笔、渐变、颜色范围、亮度范围、语义（S1.5 / S1.6 / S3.5）

蒙版不是位图，是一个**覆盖率函数**：文档存形状参数，渲染时求值。坐标归一化到未裁切源图，距离一律除以 `min(W, H)`，所以同一份文档在缩略图、1:1 与导出尺寸下给出同一形状（`Sources/PhotonsCore/Masks.swift:5`）。

**它解决什么问题**

一张蒙版回答「这个像素被这个操作影响多少」，取值 0…1。它本身**没有域**：域属于被加权的那次运算，所以局部曝光与色温在 S1.6（场景线性），色相与饱和在 S3.5（显示参考）（`Sources/PhotonsCore/Kernels/s1_6_local.metal:6`、`s3_5_local_color.metal:4`）。

要三种「选」：几何选（渐变、画笔）、按值选（颜色、亮度）、按内容选（语义），再加一层组合与两级羽化。难点不在任一形状，而在这些权重必须能相加、能取反、在四种画布尺寸下一致。

**算法**

#### 一个分量的覆盖率

六种形状各给出 $\alpha_{i} \in \lbrack 0,1\rbrack$，分量级 `invert` $\iota_{i}$ 使 $a_{i} = \iota_{i}?\left( 1 - \alpha_{i} \right):\alpha_{i}$，取反在**组合之前**发生（`Masks.swift:744`、`:865`）。

#### 组合、取反、透明度

第一个分量的 `op` 被忽略（`Masks.swift:863`）：

$$
A = a_{1},\quad A\leftarrow\left\{ \begin{matrix}
{\max\left( A,a_{i} \right)} & \text{add} \\
{A\left( 1 - a_{i} \right)} & \text{subtract} \\
{Aa_{i}} & \text{intersect}
\end{matrix}
$$

$$
C = \operatorname{clamp}\left( o \cdot \left\lbrack (1 - I)A + I(1 - A) \right\rbrack,0,1 \right)
$$

$o$ 是蒙版级 `opacity`，$I$ 是蒙版级 `invert`，两者都作用在组合后的选择上；`add` 用 `max` 而非相加，关节处不会双重曝光——与画笔在一笔内的累加同一条规则（`Masks.swift:18`、`s1_5_mask_atlas.metal:465`）。

#### 羽化：在形状外，按短边量

形状羽化是「以短边百分比表示、花在边界**外侧**」的二次衰减：内部保持 1，越过边界后按半径平方回落到 0（`s1_5_mask_atlas.metal:238`）：

$$
g = \frac{f \cdot 0.1 \cdot \min(W,H)}{\min\left( r_{x},r_{y} \right)},\quad r_{out} = 1 + g,\quad\alpha_{\text{rad}} = \left\lbrack \frac{r_{out}^{2} - r^{2}}{r_{out}^{2} - 1} \right\rbrack^{2}
$$

$f$ 是分量 `feather`（0…1，即短边 0…10 %），$r$ 是椭圆归一化半径（`s1_5_mask_atlas.metal:220`）。以短边为单位，物理宽度不随画布变：缩略图与导出拿到同一个数，图集级与形状级的 `feather` 也因此是同一个量、两个算子（`Masks.swift:1528`）。

**一个例外，且是故意的**：线性渐变的 `feather` 是**跨度**的比例，斜坡以 $t' = \frac{1}{2}$ 为中心对称（`s1_5_mask_atlas.metal:203`）：

$$
t = \operatorname{clamp}\left( \frac{\left\langle p - p_{0},d \right\rangle}{\left\langle d,d \right\rangle},0,1 \right),\quad t' = t^{\log\frac{1}{2}/\log m},\quad\alpha_{\text{lin}} = \operatorname{smoothstep}\left( \frac{1}{2} - \frac{f}{2},\frac{1}{2} + \frac{f}{2},t' \right)
$$

$m$ 是 `midpoint`，$m = \frac{1}{2}$ 为恒等。079 A4 一度把径向那条规则套到线性渐变上，斜坡一侧变窄、十倍短、且不再经过中点；现在是 102 恢复的原契约（`:203`、`Masks.swift:874`）。

#### 画笔：胶囊链

一笔是一串线段，覆盖按到线段的距离给，半径沿线插值以支持压感（`s1_5_mask_atlas.metal:254`）：

$$
\alpha_{\text{seg}} = 1 - \operatorname{smoothstep}\left( r(1 - f),r,{dist}\left( p,\overline{ab} \right) \right)
$$

一笔之内取 `max`（关节是并集，不是双重曝光）再乘 `flow`；笔与笔之间是 ${src} + {dst}(1 - {src})$，橡皮是 ${dst}(1 - {src})$（`:289`、`:305`）。半径是短边单位、笔画自带，`size` 只是没有半径时的回退（`Masks.swift:337`）。

#### 颜色范围：OKLab 里的最近距离

取分量内最接近的采样色，距离在归一化 OKLab 度量里量：

$$
\Delta = \min\limits_{i}\sqrt{\left( L - L_{i} \right)^{2} + \left( \frac{a - a_{i}}{0.4} \right)^{2} + \left( \frac{b - b_{i}}{0.4} \right)^{2}},\quad\alpha = 1 - \operatorname{smoothstep}\left( \tau,\tau + \sigma(0.5 - \tau),\Delta \right)
$$

$\tau$ 是 `tolerance`，$\sigma$ 是 `smoothness`（`s1_5_mask_atlas.metal:340`）。`a`/`b` 除以 0.4（sRGB 的自然半跨度），一个容差数字才在两条轴上同义（`Masks.swift:566`）。最多 8 个采样，超出丢最旧的一个（`:379`、`:421`）。这里折叠用的是**工作基色**（Rec.2020）的矩阵：Ottosson 发表的 sRGB 九系数在饱和红上误差 0.1252，占容差跨度的 31 %，且是渐进错、golden 看不出来（`:579`）。

#### 亮度范围：一条两端羽化的窗口

$$
\alpha = \operatorname{smoothstep}\left( {lo} - f_{lo},{lo} + f_{lo},L \right) \cdot \left\lbrack 1 - \operatorname{smoothstep}\left( {hi} - f_{hi},{hi} + f_{hi},L \right) \right\rbrack
$$

$L$ 是**未钳**线性光的 OKLab 亮度，轴到 $16^{1/3} \approx 2.5198$，即 +4 EV（`Masks.swift:455`、`s1_5_mask_atlas.metal:371`）。167 之前折的是 `clamp(linearRGB, 0, 1)`，显示白以上全变成 $L = 1$，窗口上半段没有分辨率。v1 文档按原值读、只升代次：把 `high = 1.0` 改成 `hdrMax` 会改掉用户刻意切的位置（`:492`）。边界倒置时两边**连带羽化**一起交换（`:436`）。

#### 语义：一个意图加一张系统栅格

`semantic` 是「意图 + 操作系统产出的栅格」，位图不进文档，只进一个 SHA-256 摘要（`Masks.swift:689`）。两条路线：`CIRAWFilter` 的只读 matte（sky、hair、skin、teeth、glasses、person）与 Vision 前景实例蒙版；本机的 Leica DNG 上六个 matte 全是 `nil`，实际只有 subject 可用（`Sources/PhotonsCore/MaskSemantics.swift:12`、`:15`）。模型跑在长边 ≤ 1024 的副本上，核心里双线性上采样再按 `softEdge` 收边：

$$
\alpha = \operatorname{smoothstep}\left( \frac{1}{2} - \frac{s}{2},\frac{1}{2} + \frac{s}{2},{raw} \right)
$$

没有栅格时该分量贡献 0 覆盖并记一条原因，不做近似（`s1_5_mask_atlas.metal:384`）。

#### amount / opacity / invert 各管什么

三者都乘进权重，位置不同：`invert` 翻转覆盖率（$1 - a$），`opacity` 缩放整个选择，`amount` 是这次调整的整体强度，0…100 存、0…1 用（`Masks.swift:913`、`:37`）。每个消费阶段算同一个权重：

$$
w = \operatorname{clamp}\left( C \cdot \frac{\text{amount}}{100},0,1 \right),\quad v' = \operatorname{mix}\left( v,f(v),w \right)
$$

`amount = 0` 时 $w = 0$，该蒙版不渲染——不是「渲染成恒等」，而是连 $f(v)$ 都不调用，所以即使滑杆会产出 NaN 也逐字节等于无蒙版（`s1_6_local.metal:136`、`s3_5_local_color.metal:65`）。`mix` 在 RGB 上做，$w = 1$ 时像素恰好是 $f(v)$——「全画布蒙版等于全局滑杆」由此逐字节成立（`s3_5_local_color.metal:81`）。

#### 图集级羽化与 refine

点式覆盖率之后是两个**邻域**算子：蒙版级 `feather` 是可分离盒式模糊，半径 $f \cdot 0.1 \cdot \min(W,H)$ 画布像素；`refine` 是以 S1 亮度为引导的引导滤波（`Sources/PhotonsCore/Kernels/s1_7_mask_neighbourhood.metal:1`）：

$$
a = \frac{{cov}(I,p)}{{var}(I) + \varepsilon},\quad b = \overline{p} - a\overline{I},\quad{out} = aI + b,\quad\varepsilon = 0.01 \cdot 10^{- {refine}}
$$

核直径取 `odd(clamp(2·round(max(W,H)/30) + 1, 3, 65))`，系数在 1/q 分辨率求解、上采样后重建（`Masks.swift:1534`、`:1549`）。两个算子对 `opacity`/`invert` 都仿射不变，所以图集可先写最终覆盖率、再跑这两步（`s1_7_mask_neighbourhood.metal:13`）。

**参数与范围**

| 量 | 范围 / 默认 | 单位 | 作用 |
|---|---|---|---|
| `id` | `"m-<uuid>"` | — | 图集身份，进键（`Masks.swift:908`） |
| `name` | 自由文本 | — | **不进任何键**，改名不重渲（`:910`） |
| `isEnabled` | `true` | — | 假则不参与（`:912`） |
| `opacity` | 0…1，默认 1 | — | 组合后整体缩放（`:913`） |
| `invert` | `false` | — | $1 - A$（`:915`） |
| `feather` | 0…0.1（UI 0…1），默认 0 | 短边比例 | 盒式模糊半径（`:917`、`:1528`） |
| `refine` | 0…1，默认 0 | — | 引导滤波强度（`:921`） |
| `components[].op` | `add` / `subtract` / `intersect` | — | 首个分量的 op 忽略（`:16`、`:863`） |
| `components[].invert` | `false` | — | 组合前取反（`:865`） |
| `components[].feather` | 0…1，默认 0.5 | 短边 0…10 %；线性为跨度比例 | 形状边缘（`:867`、`:874`） |
| `amount` | 0…100，默认 100 | — | 0 = 该蒙版不渲染（`:37`） |
| `exposure` | −4…+4 EV，默认 0 | EV | 场景线性增益（`:39`） |
| `temperature` / `tint` | ±100，默认 0 | 6500 K + 30 K/单位 | 场景线性白平衡（`:42`） |
| `highlights` / `shadows` | ±100，默认 0 | — | S2 的三个窗口，中间调钉 0（`:49`） |
| `whites` / `blacks` | ±100，默认 0 | — | S1 的端点，同一函数（`:51`） |
| `contrast` | ±100，默认 0 | — | 实际在 S2.5 执行（`:48`） |
| `hue` / `saturation` | ±100，默认 0 | — | 显示域，S3.5（`:54`） |
| `texture` / `sharpen` | ±100 / 0…100，默认 0 | — | S3.9（`:63`、`:68`） |

形状字段：

| 形状 | 字段 | 范围 / 默认 |
|---|---|---|
| 线性渐变 | `start`、`end`、`midpoint` | (0.5,0)→(0.5,1)，中点 0.5（`Masks.swift:239`） |
| 径向渐变 | `center`、`radius`、`angle` | (0.5,0.5)、(0.25,0.25)、0（`:270`） |
| 画笔 | `size`、`strokes[]`（`radius`、`feather`、`flow`、`erase`、`closed`） | size 0.06、半径 0.06、羽化 0.5、flow 1（`:312`、`:359`） |
| 颜色范围 | `samples` ≤ 8、`tolerance`、`smoothness` | 容差 0.30、平滑 0.50（`:379`、`:390`） |
| 亮度范围 | `low`、`high`、`lowFeather`、`highFeather` | 0 / 2.5198 / 0.10 / 0.10（`:481`） |
| 语义 | `kind`、`provider`、`softEdge`、`rasterDigest` | `foreground` / Vision，软边 0.20（`:709`） |
| 上限 | `Mask.maxCount` | 12（`:906`） |

**实现**

**图集是一张纹理数组**：每张启用的蒙版一片，R16F，画布分辨率，写 `opacity · combine(components) · invert`（`s1_5_mask_atlas.metal:7`、`:478`）。坐标走 S0 的反向：画布 → 内容 → 帧 → 翻转 → 旋转 → 裁切 → 反解 90°，最后乘源尺寸（`:135`）。旋转同样在**帧像素**里做、同样两个模板实例：080 之前这里转归一化坐标而 S0 转像素，7° 拉直在 9504×6336 上把蒙版挪开 273 px（`:31`）。

**只依赖形状。** 图集身份是 `selectionKey`：`id | 分量（op、invert、feather、shape…）| invert | opacity | feather | refine | isEnabled`，**不含任何滑杆**；局部量走另一个键 `applyKey`（`Masks.swift:980`、`:989`）。拖局部曝光只重跑 S1.6 一个 pass，不重建图集（`:29`）。

**只算该算的像素。** 每片带一个画布盒子：支撑集按两级邻域半径 $r_{\text{feather}} + r_{\text{guided}}$ 长大、裁到画布；倒置蒙版与按值谓词答整幅，因为它们的支撑集是画面的性质而不是参数的（`s1_5_mask_atlas.metal:97`、`Masks.swift:1577`）。盒外覆盖率恒为 0，但**仍要写**：图集纹理跨重建复用，留着上一帧的 texel 就是泄漏（`:101`）。外层的 tile 是另一件事，三档输出必须逐字节相同（`RenderGraph.swift:290`）。

**两个消费阶段读同一份数。** S1.6 逐像素读覆盖率、`mix` 进场景线性结果，唯一钳位在出口（`s1_6_local.metal:126`、`:144`）；S3.5 读同一片、在 RGB 上 `mix`，色相旋转前按峰值归一化以照看 HDR（`s3_5_local_color.metal:72`）。两者都跳过「覆盖率 0」与「未启用」，只有曝光滑杆的蒙版在 S3.5 上一分钱不花（`:21`）。

**按值谓词读 S1 的输出，但要除掉全局曝光**：同一张 `luminanceRange 0.55…1.0` 在 E0 下选 17 %、E+2 下选 55 %（IoU 0.196），所以采样前除以 $g = 2^{EV}$，谓词看到的是解码器的光（`s1_5_mask_atlas.metal:15`）。

**开源对照**

- **darktable 的绘制蒙版**：形状以矢量存在**原图坐标系**，随后续变形模块一起被变换，「永远作用在同一块画面区域」（<https://docs.darktable.org/usermanual/4.6/en/darkroom/masking-and-blending/masks/drawn/>）。Photons 同一条纪律，但写成了坐标契约：形状归一化到未裁切源图、距离除以短边（`Masks.swift:5`）。羽化的定义不同：darktable 是「边缘的模糊」，Photons 是**边界外侧的二次衰减**——这条正是 079 A4 从 darktable 的 `masks/ellipse.c` 学来的，因为它不吃掉形状的实心面积（`s1_5_mask_atlas.metal:56`）。
- **darktable 的参数化蒙版**：每个数据通道（Lab、RGB、Jzazbz 及 hue/saturation 这类虚拟通道）各给一条不透明度函数，最后**逐像素相乘**再乘全局不透明度；HDR 用 `boost factor` 把量程往外推（<https://docs.darktable.org/usermanual/4.6/en/darkroom/masking-and-blending/masks/parametric/>）。Photons 只给两个谓词、一个固定度量空间、一条「最近采样色距离 vs 容差」，HDR 靠把 $L$ 轴延到 +4 EV（`Masks.swift:455`）。表达力少一截，换来每条谓词只有三个数、能写出闭式期望值。
- **一个数走两个域**：darktable 的混合是「模块只跑一个 `process()`，蒙版只决定 alpha」，带与不带蒙版不可能长出两套算法（`s1_6_local.metal:20`）。S1.6 同法：调的不是「局部版本」，而是全局阶段自己的函数体（`:24`）。

**取舍**

**解析形状，不存位图。** 形状在任何尺寸下精确、文档只有几百字节、改画布不必重采样蒙版；代价是画笔成本随点数线性增长，靠笔画包围盒先拒（一笔 300 点等于 299 次距离计算）压住（`s1_5_mask_atlas.metal:268`）。语义蒙版是唯一例外。

**两种羽化单位。** 径向与画笔按短边、线性按跨度。这是 102 的结论而非疏忽：把径向规则套到开放形状上，斜坡不再经过中点（`:203`）。代价是同一张蒙版里两个同名参数语义不同。

**颜色范围只有一个度量空间。** 固定 OKLab 让「容差 0.3」在两张照片上同义，也让 CPU 取色器与 GPU 像素走同一条 `fromLinear`（`Masks.swift:660`）；代价是不能换坐标系去贴合某类画面。

**语义蒙版依赖操作系统。** 本机只有 subject 可用；缺能力时给 0 覆盖加一条原因而不猜近似（`MaskSemantics.swift:12`、`s1_5_mask_atlas.metal:72`）。摘要进文档，为了让「系统模型换了」下次打开时可见（`Masks.swift:699`）。
