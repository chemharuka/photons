# 4.16–4.17 几何与蒙版

这一篇讲两块：几何（S0）和蒙版权重（S1.5 / S1.6 / S3.5）。几何决定每个画布像素去源图的哪个点取样，也决定画布多大；蒙版决定一次调整覆盖画面的多少。两块的要求是同一条：没碰过的文档必须逐字节不变。

## 4.16 几何：裁切、拉直、翻转、90°、透视与横向色差（S0）

S0 是唯一动像素网格本身的阶段。它把画布上的每个像素映射回源文件的一个采样点，后面所有按像素走的运算都拿它的输出当输入（`Sources/PhotonsCore/Kernels/s0_geometry.metal:9`）。这一节只回答两件事：**读哪个点**，**画布多大**。

**它解决什么问题**

裁切定输出框，拉直把地平线转正，翻转和 90° 管整幅的方向，透视把建筑照里汇聚的竖线拉回平行，横向色差收回红蓝相对绿的径向放大（`Sources/PhotonsCore/EditModel.swift:2692`）。五件事共用一套结构：都在固定的参考系里重采样，都能写成一条「画布 → 源像素」的映射。

代价是它得精确到最后一位。快速路径、八个入口、θ = 0 时不出现一次乘法，全是为了让没碰过几何的文档逐字节等于没有几何（`Sources/PhotonsCore/Kernels/s0_geometry.metal:105`）。

**算法**

#### 裁切框的表示

文档里裁切矩形只有一份真值，两种拼法。`crop` 是原点加尺寸；`cropRect` 是同一个矩形的四条边，`right`/`bottom` 存的是**绝对边界**，不是宽高，所以 `full` 写出来是 `(0, 0, 1, 1)` 而不是 `(0, 0, 0, 0)`（`Sources/PhotonsCore/EditModel.swift:1314`、`Sources/PhotonsCore/CropMath.swift:12`）。坐标是未裁切源图的归一化坐标，原点在左上（`Sources/PhotonsCore/Masks.swift:5`）。

#### 从画布到源像素：一条仿射链

把画布像素记作 $x$，像素中心在 $\mathit{gid} + \frac{1}{2}$。其余记号：内容原点 $o_{c}$、帧原点 $o_{f}$、帧尺寸 $s_{f}$、裁切原点 $c_{0}$ 与跨度 $c_{w}$、源尺寸 $s$、翻转符号 $\sigma \in \left\{ \pm 1 \right\}^{2}$、顺时针四分之一转的置换 $T_{q}$。整条链写出来是这样：

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
\end{bmatrix}$，$y$ 向下，正角度就是屏幕上的顺时针（`Sources/PhotonsCore/CropGeometry.swift:60`）。

第三行只有一项要解释：$R$ 乘的是**像素偏移** $\left( u' - \frac{1}{2} \right) \odot s_{f}$。如果直接旋转归一化坐标，拿到的是 $s_{f}^{- 1}Rs_{f}$，非对角项差 $s_{x}/s_{y}$ 倍。3:2 的帧会被剪切 1.5 倍，拉直出来是歪的，不是转出来的（`Sources/PhotonsCore/Kernels/s0_geometry.metal:118`）。固定 $q$ 和 $\theta$ 时，整条链是仿射的：$T_{q}$ 是带符号置换，剩下的是缩放、平移和旋转。

#### 90°：置换而不是旋转

`quarterTurns` 只存一个 0…3 的整数，含义是「图像被顺时针转了几个 90°」。导出写 `tiff:Orientation` 读的也是这一个数。两处各存一份，「哪边算顺时针」就会有两种答案（`EditModel.swift:1085`）。帧转 $q \cdot 90^{\circ}$，奇数时宽高互换。`crop` 量在转过的帧里，所以转帧时裁切框跟着转，盖住的仍是照片上同一块像素（`:1096`、`CropMath.swift:872`）：

$$
(l,t,r,b)\mapsto(1 - b,l,1 - t,r)
$$

转四次回到原位是精确的。$1 - x$ 在 $x \in \lbrack 0,1\rbrack$ 上对二进制浮点没有误差，这个映射又只是四个数的排列（`CropMath.swift:876`）。核心里的顺序是「先拉直、再反解 90°、最后走裁切框」。照片的像素没被真正转过，转的只是位置（`s0_geometry.metal:238`）。

#### 画布：两个角色，一个数

301 之后，画布**就是裁切框自己**。转角不改变矩形的范围，所以任何角度下输出画布都等于裁切框的像素尺寸，一个像素不多（`Sources/PhotonsCore/CropMath.swift:791`、`Sources/PhotonsCore/CropMath.swift:805`）。162 用的是「旋转后包围盒」，用户报的那圈黑边就是它：整幅 9° 拉直的画布有 25.4 % 是背景。直角处两种算法逐位相同，所以老文档一个像素都没动。

只有**透视**还留着包围盒。变形后的画面是四边形，它的 AABB 就是诚实的输出（`Sources/PhotonsCore/CropMath.swift:817`、`Sources/PhotonsCore/CropMath.swift:671`）。

307 把「哪个画布」写成了类型，不再是一个 Bool。`CanvasRole.export` 是文件真正拿到的那张，等于裁切框；`CanvasRole.document` 是用户**画裁切框时**看到的盒子，等于转过之后的整张照片的 AABB，裁切框居中放在里面，照片没盖到的角落涂 `000000`（`Sources/PhotonsCore/CropGeometry.swift:22`、`Sources/PhotonsCore/CanvasSpaces.swift:151`）。裁切框可以拖进那圈黑角，但不能离开盒子。这是 219 之后唯一的硬边界。

所以「输出尺寸」读的是 `outputPixels`，它走 `canvasSize` 的 `.export` 角色（`Sources/PhotonsCore/EditModel.swift:1272`）；屏幕上的取景走 `.document`。直角、满幅时两者是同一个数，它们被混着说就是这么来的。

#### 透视：一台单应，锚在中线

两个滑杆各对应一个梯形强度 $p_{v},p_{h}\in[-400,400]$（353）。强度按**固定的 100 单位**折算，不按行程折算：

$$
v_{k}=-\frac{p_{k}}{100}\cdot 0.21,\qquad
M_{v}=\begin{bmatrix}1 & -\tfrac{v_v}{2} & \tfrac{v_v}{4}\\ 0 & 1-\tfrac{v_v}{2} & \tfrac{v_v}{4}\\ 0 & -v_v & 1+\tfrac{v_v}{2}\end{bmatrix},\qquad H=M_{h}M_{v}
$$

（`Sources/PhotonsCore/CropMath.swift:283`、`Sources/PhotonsCore/CropMath.swift:367`。）$H$ 是「帧 → 变形后的帧」，核心里用它的逆把采样点送回帧归一化坐标：$z'=\pi(H^{-1}(z,1))$，$\pi(x,y,w)=(x/w,y/w)$（`Sources/PhotonsCore/Kernels/s0_geometry.metal:290`）。

**锚在画框中线（338）**，不在角上。每个轴都是一台投影缩放，分母随距固定线线性变化：$w=1-v\,Y$、$Y=y-\tfrac12$。所以 $+v$ 一端放大，另一端同量缩小；$-v$ 刚好是 $+v$ **关于中线的镜像**，$P(-v)=A\,P(+v)\,A$ 逐元素成立。338 之前锚在角上 $(0,1)$，近端钉住，于是 $+100$ 和 $-100$ 互为倒数，不是镜像。用户报的「+100 和 −100 行为不一致」说的就是这个（`Sources/PhotonsCore/CropMath.swift:248`）。

强度常数 $0.21$ 是方形画幅上的 $2\tan 6^\circ$。滑杆 100 是 6.06° 的收敛，50 是 3.03°。353 之后行程到 ±400（$v=0.84$，$w\ge0.58$，四边形仍然凸，没有极点），但**分母写死 100**。要是按行程折，把 limit 从 100 改到 400，每份现有文档的强度都会被除 4。那是重新参数化，不是加行程。所以 `|p| ≤ 100` 的字节跟旧版逐位相同，400 只表示四倍于今天的变形（`Sources/PhotonsCore/CropMath.swift:303`、`:311`）。

**画布是变形后裁切框的包围盒（246），不是内接矩形。** 变形后的画面是四边形，它的 AABB 就是诚实的输出。`perspectiveCanvas` 把裁切框四角过一遍 $P$，再绕照片中心转 $R$，拿这四点的 min/max 当画布，同时把整条 `canvas → 照片` 的采样矩阵（含 AABB 原点）合成一个 3×3（`Sources/PhotonsCore/CropMath.swift:671`、`:717`）。183 取的是四边形里**最大内接矩形**，闭式，对称梯形的最优解是窄端整高。246 换成 AABB，因为内接矩形会把用户框外的画面裁掉，跟「裁切框就是输出」这条规则冲突。`inscribedRect()` 还留在 `PerspectiveMap` 上，给代理尺寸和测试用（`Sources/PhotonsCore/CropMath.swift:451`）。

#### 横向色差：一个比例，不是位移

$\alpha$ 是**无量纲的径向比例**。$\alpha_{R} > 0$ 表示红通道的像比绿通道大，校正这么做：

$$
p_{c} = a + (p - a)\left( 1 + \alpha_{c} \right),\quad a = \frac{s}{2},\quad c \in \left\{ R,B \right\}
$$

只重采样红和蓝，绿原样读（`Sources/PhotonsCore/Kernels/s0_geometry.metal:384`–`:387`）。这里最关键的设计是「比例」而不是像素位移：400 px 预览和 9504 px 导出校正的是同一段半径比例。换成像素值，同一个滑杆在两种尺寸下就变成两件事（`EditModel.swift:2696`）。中心取**源图**中心，不取裁切框中心。色差是光轴的性质，裁切和旋转不该把无像差的点挪走（`:385`）。满行程 ±0.005，面板 ±100，步长 0.1（`EditModel.swift:2708`、`:2750`）。

**参数与范围**

| 参数 | 范围 / 默认 | 单位 | 作用 |
|---|---|---|---|
| `crop` | 0…1，默认 `full` | 源归一化 | 输出框，四边是绝对边界（`Sources/PhotonsCore/EditModel.swift:1075`、`:1314`） |
| `aspectLock` | `.original` = 无约束 | 像素比 | 锁定时重写矩形（`:1082`、`:1352`） |
| `straightenDegrees` | ±45°，默认 0 | 度，正 = 顺时针 | S0 读钳过的值（`:1073`、`:1332`） |
| `flipHorizontal` / `flipVertical` | `false` | — | 帧内镜像（`:1080`） |
| `quarterTurns` | 0…3，默认 0 | 90° 计数 | `n % 4` 归一（`:1109`、`:1175`） |
| `perspectiveVertical` / `perspectiveHorizontal` | **±400**，默认 0 | 强度（÷100 折算） | 0/0 时 `perspective` 为 `nil`（`:1128`、`:1341`） |
| `caRed` / `caBlue` | ±0.005，默认 0 | 径向比例 α（`:2711`） | 横向色差 |
| `alphaPerSliderUnit` / `sliderStep` | 5×10⁻⁵、0.1 | α / 单位 | 滑杆 ±100 恰映射到 ±0.005（`:2754`、`:2759`） |

`isIdentity` 和键都按值判定。`caRed == caBlue == 0` 是快速路径的判据（`:2731`）。`quarterTurns`、`perspectiveV/H` 为 0 时连 JSON 键都不写，老文档重存一遍还是逐字节不变（`:1224`）。

**实现**

`Kernels/s0_geometry.metal` 是一个模板体，加四组模板参数 `HAS_ROTATION`、`HAS_TURN`、`HAS_LENS_WARP`、`HAS_FLIP`，八个内核乘翻转与否，一共十六个入口。`RenderGraph` 按 `straightenDegrees != 0`、`quarterTurns != 0`、镜头剖面和翻转位来选（`Sources/PhotonsCore/Kernels/s0_geometry.metal:130`、`:468`、`Sources/PhotonsCore/RenderGraph.swift:3822`）。翻转做成编译期参数，不用体内的运行时 `if`，这样不翻转的实例能保留 248 之前逐字节相同的机器码。一个 ulp 的移动就会改掉中性 golden。

**三条快速路径**，各自解决一个「本来不该有算术」的场景：

- **identity**：满幅、无旋转无翻转、无窗口、画布等于源尺寸，逐 texel 拷贝。出口矩阵照跑，「恒等」说的是采样，不是色彩空间（`s0_geometry.metal:140`、`:38`）。
- **pure-CA**：在上面那条的基础上再加 $\alpha \neq 0$。绿按 texel 直读，只有红蓝重采样，这一帧的绿跟 identity 逐字节相同（`:202`）。
- **pure-turn**：只转了 90°。通用路径会先算 ${uv} = f/s_{f}$ 再乘回源尺寸，在 9504 px 上是一次约 10⁻³ texel 的往返。这等于给一个没有算术的操作加了一层插值，转四次就回不到原字节。这里把源索引放到 `int` 里算：源 $(i,j)$ 出现在转过一档的帧的 $(H - 1 - j,i)$（`:151`）。

三个标志都在 `RenderGraph.plan` 一处判定。`untransformed` 是 pre-029 的恒等条件，`s0PureTurn` 再要求满幅、1:1、无窗口、无 CA（`RenderGraph.swift:2125`、`:2138`、`:2152`）。顺序也钉死了：**先反解旋转、再走单应、最后反解 90°**（`s0_geometry.metal:276`）。

镜头 warp 也在这个核里。文件带 `WarpRectilinear` 三平面时，逐通道做 $p_{c} = {center} + ({px} - {center}) \cdot s_{c}(r)$，$s_{c}$ 是 `kr0 + kr1·r² + kr2·r⁴ + kr3·r⁶`，全是**偶次幂**。写成奇次幂，在系数全零时跟规范一致，合成测试抓不到，但在真实文件上会把整幅图移动约 0.4 % 的半径（`:340`）。顺序是先 warp、后手动 α（`:306`）。

**开源对照**

- **darktable 的「裁剪」**：可拖拽矩形加一张宽高比列表（`freehand`、`original image`、`square`、`golden cut` 等预设）（<https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/crop/>）。Photons 拆成「归一化四边 + 具名 `AspectLock`」，锁定跟矩形对不上时锁定胜出（`Sources/PhotonsCore/EditModel.swift:1352`）。画布两边一致，都是输出框本身（301）；只有带透视时才不同，那是变形四边形的包围盒（`Sources/PhotonsCore/CropMath.swift:805`）。
- **darktable 的「旋转与透视」**：用检测或手画的线段做**拟合**反推参数，机制源自 ShiftN（<https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/rotate-perspective/>）。Photons 的两个滑杆是直接参数：±400 强度、分母 100、6° 一档，不拟合。337 的「引导线」是**单独一层**。用户画两条本该平行的边，它解出能让这组线互相平行的 $(v,h)$，再把方向差写进 `straighten`。参数还是那两个滑杆，只是这次由求解器写（`Sources/PhotonsUI/GuideLinesSolve.swift:1`）。
- **darktable 的「镜头校正」**：畸变和 TCA 来自 lensfun 剖面或文件内嵌的元数据，走的是「按型号查表」的路线（<https://docs.darktable.org/usermanual/4.6/en/module-reference/processing-modules/lens-correction/>）。Photons 两条腿都有：文件里有 DNG 三平面就用它自己的 `WarpRectilinear`，没有就用 Apple 的，再叠一层手动 α（`Sources/PhotonsCore/EditModel.swift:2700`、`Sources/PhotonsCore/Kernels/s0_geometry.metal:318`），手动这层是留给没有剖面的镜头的。

**取舍**

**先变形、后裁切。** 裁切框就是输出框，所以拉直不会自动「放大填满」，转过的角是背景，不是黑边（`Sources/PhotonsCore/Kernels/s0_geometry.metal:23`）。要自动填满，得先替用户决定裁掉多少；代价是拉完角度通常还得再收一次框。

**画布就是裁切框（301）。** 旋转不改变矩形的范围，所以输出画布恒等于裁切框的像素尺寸。162 的包围盒只会多出黑边，整幅 9° 拉直时 25.4 % 是背景。唯一例外还是透视：变形后的四边形用它自己的 AABB（`Sources/PhotonsCore/CropMath.swift:791`、`:817`）。

**透视：强度分母写死 100，行程放到 ±400。** 这样加行程不会重画老文档。400 对应 `0.84`，`w ≥ 0.58`，四边形仍然凸，没有极点（`Sources/PhotonsCore/CropMath.swift:305`）。锚在中线上，$+v$ 和 $-v$ 精确互为镜像，四边形的包围盒与内接矩形都能直接算出来，不用搜索（`Sources/PhotonsCore/CropMath.swift:248`）。

---

## 4.17 蒙版权重：画笔、渐变、颜色范围、亮度范围、语义（S1.5 / S1.6 / S3.5）

蒙版不是位图，是一个**覆盖率函数**。文档里存形状参数，渲染时才求值。坐标归一化到未裁切的源图，距离一律除以 `min(W, H)`，所以同一份文档在缩略图、1:1 和导出尺寸下给出同一个形状（`Sources/PhotonsCore/Masks.swift:5`）。

**它解决什么问题**

一张蒙版回答的是「这个像素被这个操作影响多少」，取值 0…1。它本身**没有域**，域属于被加权的那次运算。所以局部曝光和色温在 S1.6，也就是场景线性；色相和饱和在 S3.5，也就是显示参考（`Sources/PhotonsCore/Kernels/s1_6_local.metal:6`、`s3_5_local_color.metal:4`）。

用户要三种「选」：按几何选，就是渐变和画笔；按值选，就是颜色和亮度；按内容选，就是语义。再加一层组合和两级羽化。难点不在单个形状，在这些权重得能相加、能取反，还得在四种画布尺寸下保持一致。

**算法**

#### 一个分量的覆盖率

六种形状各自给出一个 $\alpha_{i} \in [0,1]$。分量级 `invert` 记作 $\iota_{i}$，它让 $a_{i} = \iota_{i}?\left( 1 - \alpha_{i} \right):\alpha_{i}$。取反发生在**组合之前**（`Masks.swift:754`、`:875`）。

#### 组合、取反、透明度

第一个分量的 `op` 会被忽略（`Masks.swift:873`）：

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

$o$ 是蒙版级的 `opacity`，$I$ 是蒙版级的 `invert`，两者都作用在组合后的选择上。`add` 用 `max`，不是相加，所以关节处不会双重曝光。这跟画笔在一笔内的累加是同一条规则（`Masks.swift:18`、`s1_5_mask_atlas.metal:476`）。

#### 羽化：在形状外，按短边量

形状羽化用短边百分比表示，宽度花在边界的**外侧**，衰减是二次的。内部保持 1，越过边界后按半径平方回落到 0（`Sources/PhotonsCore/Kernels/s1_5_mask_atlas.metal:230`）：

$$
g = \frac{f \cdot 0.1 \cdot \min(W,H)}{\min\left( r_{x},r_{y} \right)},\quad r_{out} = 1 + g,\quad\alpha_{\text{rad}} = \left\lbrack \frac{r_{out}^{2} - r^{2}}{r_{out}^{2} - 1} \right\rbrack^{2}
$$

$f$ 是分量的 `feather`，范围 0…1，也就是短边的 0…10 %；$r$ 是椭圆的归一化半径（`:241`）。以短边为单位，物理宽度就不随画布变化：缩略图和导出拿到同一个数。图集级和形状级的 `feather` 因此是同一个量，只是两个算子（`Masks.swift:1536`）。

有一个例外，而且是故意的：线性渐变的 `feather` 是**跨度**的比例。215 之后，斜坡是整段的线性覆盖，羽化则是两条线**外侧**各半宽的带（`s1_5_mask_atlas.metal:42`、`:208`）：

$$
t=\operatorname{clamp}\!\left(\frac{\langle p-p_{0},d\rangle}{\langle d,d\rangle},0,1\right),\quad
t'=t^{\log\frac12/\log m},\quad
\alpha_{\text{lin}}=\mathrm{clamp}\!\left(\frac{t' + f/2}{1+f},\ 0,\ 1\right)
$$

$m$ 是 `midpoint`，$m=\frac12$ 时是恒等；$f=0$ 退化成 `clamp(t', 0, 1)`，也就是整段线性。079 A4 一度把径向那条规则套到线性渐变上，102 又改回以 $t'=\frac12$ 为中心的 `smoothstep` 斜坡。在默认 `midpoint = 0.5` 下，起点就有半个羽化带是平的，用户报的「一半之内没有强度」说的就是这个。215 把斜坡拉回整段线性，羽化挪到线外（`Masks.swift:237`、`:1590`）。

#### 画笔：胶囊链

一笔是一串线段。覆盖率按到线段的距离给，半径沿线插值，这样压感能带上（`s1_5_mask_atlas.metal:265`）：

$$
\alpha_{\text{seg}} = 1 - \operatorname{smoothstep}\left( r(1 - f),r,{dist}\left( p,\overline{ab} \right) \right)
$$

一笔之内取 `max`，于是关节是并集，不是双重曝光，然后再乘 `flow`。笔与笔之间是 ${src} + {dst}(1 - {src})$，橡皮是 ${dst}(1 - {src})$（`:300`、`:316`）。半径用短边单位，由笔画自带，`size` 只在没有半径时做回退（`Masks.swift:347`）。

#### 颜色范围：OKLab 里的最近距离

取分量内最接近的那个采样色，距离在归一化的 OKLab 度量里量：

$$
\Delta = \min\limits_{i}\sqrt{\left( L - L_{i} \right)^{2} + \left( \frac{a - a_{i}}{0.4} \right)^{2} + \left( \frac{b - b_{i}}{0.4} \right)^{2}},\quad\alpha = 1 - \operatorname{smoothstep}\left( \tau,\tau + \sigma(0.5 - \tau),\Delta \right)
$$

$\tau$ 是 `tolerance`，$\sigma$ 是 `smoothness`（`s1_5_mask_atlas.metal:351`）。`a`/`b` 要除以 0.4，那是 sRGB 的自然半跨度，这样一个容差数字在两条轴上才同义（`Masks.swift:576`）。采样最多 8 个，超了丢最旧的那个（`:389`、`:431`）。这里的折叠矩阵用的是**工作基色**（Rec.2020）的：Ottosson 发表的 sRGB 九系数在饱和红上误差 0.1252，占容差跨度的 31 %，而且是渐进式的错，golden 看不出来（`:589`）。

#### 亮度范围：一条两端羽化的窗口

$$
\alpha = \operatorname{smoothstep}\left( {lo} - f_{lo},{lo} + f_{lo},L \right) \cdot \left\lbrack 1 - \operatorname{smoothstep}\left( {hi} - f_{hi},{hi} + f_{hi},L \right) \right\rbrack
$$

$L$ 是**未钳**线性光算出的 OKLab 亮度，轴一直到 $16^{1/3} \approx 2.5198$，也就是 +4 EV（`Masks.swift:465`、`s1_5_mask_atlas.metal:382`）。167 之前折的是 `clamp(linearRGB, 0, 1)`，显示白以上全变成 $L = 1$，窗口上半段没有分辨率。v1 文档按原值读，只升代次：把 `high = 1.0` 改成 `hdrMax` 会改掉用户刻意切的位置（`:503`）。边界倒置时，两边**连带羽化**一起交换（`:447`）。

#### 语义：一个意图加一张系统栅格

`semantic` 是「意图 + 操作系统产出的栅格」。位图不进文档，进的只有一个 SHA-256 摘要（`Masks.swift:709`）。路线有两条：`CIRAWFilter` 的只读 matte（sky、hair、skin、teeth、glasses、person），和 Vision 的前景实例蒙版。本机的 Leica DNG 上六个 matte 全是 `nil`，实际只有 subject 能用（`Sources/PhotonsCore/MaskSemantics.swift:12`、`:15`）。模型跑在长边 ≤ 1024 的副本上，核心里先做双线性上采样，再按 `softEdge` 收边：

$$
\alpha = \operatorname{smoothstep}\left( \frac{1}{2} - \frac{s}{2},\frac{1}{2} + \frac{s}{2},{raw} \right)
$$

没有栅格时，这个分量贡献 0 覆盖，同时记一条原因，不做近似（`s1_5_mask_atlas.metal:395`）。

#### amount / opacity / invert 各管什么

三个都乘进权重里，只是位置不同。`invert` 翻转覆盖率（$1 - a$），`opacity` 缩放整个选择，`amount` 是这次调整的整体强度，存的时候 0…100，用的时候 0…1（`Masks.swift:929`、`:37`）。每个消费阶段都在算同一个权重：

$$
w = \operatorname{clamp}\left( C \cdot \frac{\text{amount}}{100},0,1 \right),\quad v' = \operatorname{mix}\left( v,f(v),w \right)
$$

`amount = 0` 时 $w = 0$，这张蒙版就不渲染了。它连 $f(v)$ 都不调用，不是渲染成恒等，所以就算滑杆那边会产出 NaN，结果也逐字节等于没有蒙版（`s1_6_local.metal:137`、`s3_5_local_color.metal:65`）。`mix` 在 RGB 上做，$w = 1$ 时像素恰好是 $f(v)$，「全画布蒙版等于全局滑杆」就是这么逐字节成立的（`s3_5_local_color.metal:81`）。

#### 图集级羽化与 refine

点式覆盖率算完，还有两个**邻域**算子。蒙版级 `feather` 是可分离盒式模糊，半径是 $f \cdot 0.1 \cdot \min(W,H)$ 画布像素。`refine` 是以 S1 亮度为引导的引导滤波（`Sources/PhotonsCore/Kernels/s1_7_mask_neighbourhood.metal:1`）：

$$
a = \frac{{cov}(I,p)}{{var}(I) + \varepsilon},\quad b = \overline{p} - a\overline{I},\quad{out} = aI + b,\quad\varepsilon = 0.01 \cdot 10^{- {refine}}
$$

核直径取 `odd(clamp(2·round(max(W,H)/30) + 1, 3, 65))`，系数在 1/q 分辨率上求解，上采样后重建（`Masks.swift:1542`、`:1557`）。两个算子对 `opacity`/`invert` 都仿射不变，所以图集可以先写最终覆盖率，再跑这两步（`s1_7_mask_neighbourhood.metal:13`）。

**参数与范围**

| 量 | 范围 / 默认 | 单位 | 作用 |
|---|---|---|---|
| `id` | `"m-<uuid>"` | — | 图集身份，进键（`Masks.swift:924`） |
| `name` | 自由文本 | — | **不进任何键**，改名不重渲（`:926`） |
| `isEnabled` | `true` | — | 假则不参与（`:928`） |
| `opacity` | 0…1，默认 1 | — | 组合后整体缩放（`:929`） |
| `invert` | `false` | — | $1 - A$（`:931`） |
| `feather` | 0…0.1（UI 0…1），默认 0 | 短边比例 | 盒式模糊半径（`:933`、`:1536`） |
| `refine` | 0…1，默认 0 | — | 引导滤波强度（`:937`） |
| `components[].op` | `add` / `subtract` / `intersect` | — | 首个分量的 op 忽略（`:16`、`:873`） |
| `components[].invert` | `false` | — | 组合前取反（`:875`） |
| `components[].feather` | 0…1，默认 0.5 | 短边 0…10 %；线性为跨度比例 | 形状边缘（`:877`–`:886`、`:887`） |
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
| 线性渐变 | `start`、`end`、`midpoint` | (0.5,0)→(0.5,1)，中点 0.5（`Masks.swift:249`） |
| 径向渐变 | `center`、`radius`、`angle` | (0.5,0.5)、(0.25,0.25)、0（`:280`） |
| 画笔 | `size`、`strokes[]`（`radius`、`feather`、`flow`、`erase`、`closed`） | size 0.06、半径 0.06、羽化 0.5、flow 1（`:322`–`:330`） |
| 颜色范围 | `samples` ≤ 8、`tolerance`、`smoothness` | 容差 0.30、平滑 0.50（`:389`、`:400`） |
| 亮度范围 | `low`、`high`、`lowFeather`、`highFeather` | 0 / 2.5198 / 0.10 / 0.10（`:491`） |
| 语义 | `kind`、`provider`、`softEdge`、`rasterDigest` | `foreground` / Vision，软边 0.20（`:719`） |
| 上限 | `Mask.maxCount` | 12（`:922`） |

**实现**

**图集是一张纹理数组**，每张启用的蒙版占一片，R16F，画布分辨率，写的是 `opacity · combine(components) · invert`（`s1_5_mask_atlas.metal:7`、`:489`）。坐标走 S0 的反向：画布 → 内容 → 帧 → 翻转 → 旋转 → 裁切 → 反解 90°，最后乘源尺寸（`:142`）。旋转同样在**帧像素**里做，也同样有两个模板实例。080 之前这里转的是归一化坐标，S0 转的是像素，7° 拉直在 9504×6336 上能把蒙版挪开 273 px（`:31`）。

**只依赖形状。** 图集的身份是 `selectionKey`：`id | 分量（op、invert、feather、shape…）| invert | opacity | feather | refine | isEnabled`，**不含任何滑杆**。局部量走另一个键 `applyKey`（`Masks.swift:996`、`:1005`）。所以拖局部曝光只重跑 S1.6 一个 pass，图集不动（`:29`）。

**只算该算的像素。** 每片带一个画布盒子。支撑集按两级邻域半径 $r_{\text{feather}} + r_{\text{guided}}$ 长大，再裁到画布。倒置蒙版和按值谓词答整幅，因为它们的支撑集是画面的性质，不是参数的性质（`s1_5_mask_atlas.metal:104`、`Masks.swift:1585`）。盒外的覆盖率恒为 0，但**还是要写**：图集纹理跨重建复用，留着上一帧的 texel 就是泄漏（`:101`）。外层的 tile 是另一件事，三档输出必须逐字节相同（`RenderGraph.swift:369`）。

**两个消费阶段读的是同一份数。** S1.6 逐像素读覆盖率，`mix` 进场景线性结果，唯一一处钳位在出口（`s1_6_local.metal:127`、`:145`）。S3.5 读同一片，在 RGB 上 `mix`，色相旋转前按峰值归一化，顺带照看 HDR（`s3_5_local_color.metal:72`）。两边都跳过「覆盖率 0」和「未启用」，所以只有曝光滑杆的蒙版在 S3.5 上一分钱不花（`:21`）。

**按值谓词读 S1 的输出，但得先除掉全局曝光。** 同一张 `luminanceRange 0.55…1.0`，E0 下选 17 %，E+2 下选 55 %（IoU 0.196）。所以采样前先除以 $g = 2^{EV}$，让谓词看到解码器的光（`s1_5_mask_atlas.metal:15`）。

**开源对照**

- **darktable 的绘制蒙版**：形状以矢量存在**原图坐标系**，随后续变形模块一起被变换，「永远作用在同一块画面区域」（<https://docs.darktable.org/usermanual/4.6/en/darkroom/masking-and-blending/masks/drawn/>）。Photons 守同一条纪律，只是把它写成了坐标规则：形状归一化到未裁切的源图，距离除以短边（`Masks.swift:5`）。羽化的定义两边不同。darktable 是「边缘的模糊」，Photons 是**边界外侧的二次衰减**。这条是 079 A4 从 darktable 的 `masks/ellipse.c` 学来的，因为它不吃掉形状的实心面积（`s1_5_mask_atlas.metal:56`）。
- **darktable 的参数化蒙版**：每个数据通道（Lab、RGB、Jzazbz 及 hue/saturation 这类虚拟通道）各给一条不透明度函数，最后**逐像素相乘**再乘全局不透明度；HDR 用 `boost factor` 把量程往外推（<https://docs.darktable.org/usermanual/4.6/en/darkroom/masking-and-blending/masks/parametric/>）。Photons 只给两个谓词、一个固定的度量空间，再加一条「最近采样色距离 vs 容差」；HDR 靠把 $L$ 轴延到 +4 EV（`Masks.swift:465`）。表达力少一截，换来的是每条谓词只有三个数，闭式期望值写得出来。
- **一个数走两个域**：darktable 的混合是「模块只跑一个 `process()`，蒙版只决定 alpha」，带与不带蒙版不可能长出两套算法（`s1_6_local.metal:20`）。S1.6 也是这个办法：它调的不是某个「局部版本」，而是全局阶段自己的函数体（`:24`）。

**取舍**

**解析形状，不存位图。** 这样形状在任何尺寸下都精确，文档只有几百字节，改画布也不用重采样蒙版。代价是画笔成本随点数线性增长，只能靠笔画包围盒先拒把它压住：一笔 300 点就是 299 次距离计算（`s1_5_mask_atlas.metal:279`）。语义蒙版是唯一的例外。

**两种羽化单位。** 径向和画笔按短边，线性按跨度。这是 102 特意改的：把径向规则套到开放形状上，斜坡就不再经过中点（`:213`）。代价是同一张蒙版里两个同名参数的语义不一样。

**颜色范围只有一个度量空间。** 固定 OKLab 之后，「容差 0.3」在两张照片上同义，CPU 取色器和 GPU 像素也走同一条 `fromLinear`（`Masks.swift:670`）。代价是不能换坐标系去贴合某类画面。

**语义蒙版依赖操作系统。** 本机只有 subject 能用。缺能力时给 0 覆盖再加一条原因，不猜近似（`MaskSemantics.swift:12`、`s1_5_mask_atlas.metal:79`）。摘要进文档，是为了「系统模型换了」这件事下次打开时看得见（`Masks.swift:699`）。
