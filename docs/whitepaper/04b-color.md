# 4.7–4.9 色彩：饱和、色带、分级

这三节包五个 pass、四种互补的选择器：S3 按「全体像素」选，S3.6 按「色相」选，S3.6b 按「一个采样色附近的一块区域」选，S3.8 按「亮度」选；S3.4 是 S3.6 的灰度版，共用后者的色带。它们全部跑在显示参考域，位置在 S2.5 之后（`Sources/PhotonsCore/Stage.swift:190`–`:192`）。五个 pass 之间没有共享算式，只有两份共享的定义：`color_hsl.metal` 的 RGB↔HSL（S3 与 S3.5），`oklch_bands.metal` 的 OKLCh 与八色带几何（S3.6 与 S3.4）。

判据仍是第 3 章那一句：对象是「显示出来的样子」，就必须待在显示域。

---

## 4.7 自然饱和度与饱和度（S3）

**它解决什么问题**

一条全局饱和对「已经很鲜艳」和「刚有一点颜色」的像素一视同仁：+30 把正红顶到夹位（$s$ 夹在 1），却几乎不改变一片灰蓝天。自然饱和度要的是相反的加权——离灰越近的像素动得越多，已经饱和的像素不动。这两条滑杆必须是两个算子，而不是一条滑杆的两个名字。

**算法**

先把像素读成 HSL（`Kernels/color_hsl.metal:21`–`:39`）：

$$
m_x=\max(r,g,b),\qquad m_n=\min(r,g,b),\qquad l=\tfrac12(m_x+m_n)
$$

$$
s=\begin{cases} d/(2-m_x-m_n), & l>0.5\\ d/(m_x+m_n), & \mathrm{otherwise}\end{cases},\qquad d=m_x-m_n
$$

也就是说 $s=d/(1-\lvert 2l-1\rvert)$：一个纯粹由显示码算出的「距灰多远」，和亮度、和感知都无关（`color_hsl.metal:29`）。

自然饱和度是一条**加性、按剩余空间加权**的增益，$v$ 是滑杆值：

$$
s_1=\mathrm{clamp}\Bigl(s+\frac{v}{100}\cdot\tfrac12\,(1-s),\ 0,\ 1\Bigr)
$$

饱和是**乘性**的，$u$ 是滑杆值，两条依次施加，先自然饱和再饱和（`Kernels/s3_color.metal:73`–`:78`）：

$$
s_2=\mathrm{clamp}\bigl(s_1\,(1+u/100),\ 0,\ 1\bigr)
$$

$\tfrac12$ 是斜率，不是可调参数：$v=+100$ 把 $s=0.5$ 的像素送到 $0.75$，$s=0.9$ 的送到 $0.95$，而 $s=0$（灰）恒为 0——自然饱和度对灰色没有任何作用，是算术事实。$u=+100$ 则把距离翻倍，$-100$ 得到纯灰。

HDR 余量绕着 HSL 走，不穿过它。先按峰值归一，再进 HSL，出来再乘回去（`Kernels/s3_color.metal:66`–`:68`、`:81`）：

$$
k=\max\Bigl(1,\ \frac{p}{0.9}\Bigr),\qquad p=\max(r,g,b),\qquad \mathrm{out}=k\cdot\mathrm{hsl2rgb}(s_2,\,l,\,h)
$$

目标是 0.9 而不是 1.0：`rgb_to_hsl` 对峰值恰好为 1 的颜色恒返回 $s=1$（$s=(1-m_n)/(1-m_n)$），那样饱和滑杆在任何 HDR 像素上都是空操作（`:62`–`:65`）。归一化保住色度比例，`+` 方向仍有行程。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 | 出处 |
|---|---|---|---|---|
| `vibrance` | −100…100 | 0 | 滑杆单位（÷100 进公式，斜率 1/2） | `Sources/PhotonsCore/EditModel.swift:1832` |
| `saturation` | −100…100 | 0 | 滑杆单位（÷100 = 乘性系数 − 1） | `Sources/PhotonsCore/EditModel.swift:1833` |

两个都为 0 时 CPU 侧把身份位置 1：S3 仍在链上（它是无条件 pass），但整段直写（`Kernels/s3_color.metal:24`、`:33`）。身份位只看这两个数（`Sources/PhotonsCore/RenderGraph.swift:3507`–`:3509`）。

**实现**

`Kernels/s3_color.metal`，一个全分辨率 pass，三处早退：身份位（`:33`）、alpha 为 0 的黑边（`:43`）、内容矩形之外（`:50`）。后两处是「matte 不是阴影」：S0 用 alpha 0 标记「这里没有照片」，否则一次提黑会把黑边一起提亮。

HSL 的算式不在这份文件里，而在 `color_hsl.metal`，由 S3 与 S3.5 **各自 include**（`Kernels/s3_color.metal:21`、`Kernels/color_hsl.metal:78`–`:81`）。这是 056 的硬要求：一张全画布蒙版在饱和 +40 上必须与全局滑杆 +40 得到同一张图，不是「看起来差不多」。

**开源对照**

- **darktable · `colorbalancergb.c` 的 global vibrance** — 同一件事的另一种写法：增益是 $v\,(1-C^{\lvert v\rvert})$，$C$ 是 Filmlight Ych 的彩度，再并进一个总的 `chroma_factor`（<https://github.com/darktable-org/darktable/blob/master/src/iop/colorbalancergb.c>，第 718–719 行）。差别在权重函数与空间：darktable 的指数随滑杆值变化，Photons 的斜率恒为 1/2；darktable 在 Ych，Photons 在 HSL 饱和上。
- **darktable · `vibrance.c`** — 这个独立模块已被标为弃用，模块提示让用户改用 color balance rgb 里的 vibrance 滑杆（<https://github.com/darktable-org/darktable/blob/master/src/iop/vibrance.c>，第 59 行）。Photons 保留独立 pass 是为了共享算式，不是沿革。
- **RawTherapee · `ipvibrance.cc`** — `ImProcFunctions::vibrance` 工作在 `LabImage` 上，用 pastel / saturated 两个阈值区加一条肤色保护曲线（<https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/ipvibrance.cc>，第 64、99–110 行）。Photons 没有肤色保护，也没有分区阈值：一条连续斜率取代了三个经验分界。

**取舍**

两条滑杆、一个常数斜率换来可复现：自然饱和度的增益只由 $s$ 决定。代价是它分不清「皮肤的红」和「夕阳的红」——两者在同一 $s$ 上得到同一增益。RawTherapee 的肤色曲线正为此存在，代价是一张按色相索引的表——写错就是可见的边界。

还有一处必须说清：S3 的饱和与 S3.6 的饱和**不是同一个量**。前者乘 HSL 的 $s$（显示码的距离），后者乘 OKLCh 的 $C$（感知彩度）。同一个像素在两张卡上各 +50 不是 +100，这是有意的分工，不是漏改。

---

## 4.8 HSL 八色带与黑白混合（S3.6 / S3.4）

**它解决什么问题**

「只把天空的蓝压暗」需要一条按色相索引的通道；「把红苹果压成深灰、把蓝天提成浅灰」需要同一张索引表去决定每个色相在灰里的分量。前者是 HSL 卡，后者是黑白混合，两者必须共用同一组色相中心——否则同一个「蓝」在两张卡上落在不同位置。

亮度轴的定义是这里的关键。HSL 的 $l=(m_x+m_n)/2$ 是对**交给它的那三个数**取的，与光量无关：在线性光上，纯蓝与纯黄的 $l$ 都是 0.5，而它们的亮度相差 6.9×（0.0722 对 0.500）；在 OKLab 上同样的两个颜色读出 0.452 与 0.968（`Sources/PhotonsCore/HSLBands.swift:18`–`:21`、`Sources/PhotonsCore/Stage.swift:94`–`:95`）。这就是 079 结论 4，也是八色带从 S3 搬进 S3.6 的全部理由。

**算法**

空间是 OKLCh，折叠矩阵不是 Ottosson 发表的那组 sRGB 字面量，而是**用工作基色重新推导**的：`M1 · toXYZ(Rec.2020)`，每行归一到和为 1（白必须折成 $L=1,a=b=0$），九个结果字面量写死在 kernel 里（`Kernels/oklch_bands.metal:36`–`:40`；推导在 `Sources/PhotonsCore/Masks.swift:588`–`:601`）。

$$
\begin{bmatrix}l\\m\\s\end{bmatrix}=M_1\begin{bmatrix}r\\g\\b\end{bmatrix},
\qquad
\begin{bmatrix}L\\a\\b\end{bmatrix}=M_2
\begin{bmatrix}l^{1/3}\\m^{1/3}\\s^{1/3}\end{bmatrix}
$$

$M_2$ 是发表的 OKLab 矩阵（`oklch_bands.metal:42`–`:44`）。逆向是 $M_2^{-1}$、立方、$M_1^{-1}$，同样十八个字面量逐个写出（`:56`–`:62`）。色相与彩度：

$$
C=\sqrt{a^2+b^2},\qquad h=\frac{180}{\pi}\operatorname{atan2}(b,a)\ \ (\mathrm{mod}\ 360)
$$

中性门是必须的：折叠矩阵的行只在 $10^{-10}$ 的精度上求和为 1，一个数学上的灰会带着 $C\approx10^{-8}$ 和一个任意角度回来，足够让灰走过一遍转换、改掉最后一位。所以门在 $10^{-6}$ 处**恰好**为 0，在 0.02 处为 1，中间是 smoothstep（`oklch_bands.metal:81`–`:83`）。

八条带各自的权重是一个局部支撑的三次多项式，$r$ 是该侧到邻中心的角距：

$$
w_i=1-t^2(3-2t),\qquad t=\frac{\lvert \Delta h_i\rvert}{r_i},\qquad \lvert\Delta h_i\rvert\ge r_i\Rightarrow w_i=0
$$

（`oklch_bands.metal:68`–`:73`）。$r$ 不是八分之一圈，而是**到那一侧邻居的实际间距**（`Sources/PhotonsCore/HSLBands.swift:150`–`:159`）：中心在 OKLCh 角度上并不等距——红 24.78°、橙 80.03°、黄 109.42°、绿 143.00°、青 195.00°、蓝 274.46°、紫 320.84°、品红 335.01°，相邻间距从 14.17°（紫→品红）到 79.46°（青→蓝）（`Sources/PhotonsCore/HSLBands.swift:81`–`:90`）。每个间隙由两侧的带共同覆盖，两边的权重是一对互补的 smoothstep（$S(t)+S(1-t)=1$），因此 $\sum w_i=1$ 在**每一个**色相上成立，缝上也是。除法仍然无条件做一次（`Kernels/s3_6_hsl.metal:160`），那是把「恰好为 1」变成保证，而不是修正。

三条滑杆：色相是偏移，饱和乘 $C$，亮度乘 $L$：

$$
h'=h+0.3\,s_h,\qquad C'=C\Bigl(1+\frac{s_s}{100}\Bigr),\qquad L'=L\cdot 2^{s_l/100}
$$

（`Kernels/s3_6_hsl.metal:170`–`:172`）。$\pm100$ 对应 $\pm30°$、$\times2$ / $\times0$、$\pm1$ 档感知亮度。第九个选择器「全局」是同一组三轴，加在带偏移**之后**，单位相同；它的色相与饱和走同一道中性门，明度不走（灰没有色相可转，但可以被提亮）（`:116`–`:118`）。它由编译期模板参数分成两个 kernel 入口，所以 076 的默认实例里根本没有那段算术（`:46`–`:49`、`:181`–`:195`）。

黑白混合在同一张表上只读一个数（`HSLBand.mix`，主机侧塞进 `.v.x`：`Sources/PhotonsCore/RenderGraph.swift:6100`）：

$$
g=\mathrm{smoothstep}(10^{-6},\,0.02,\,C),\qquad
m=\frac{\sum_i w_i\,m_i}{\sum_i w_i}\,g,\qquad
\mathrm{grey}=L^3\cdot 2^{m/100}
$$

（`Kernels/s3_4_bw.metal:90`、`:112`、`:118`、`:120`、`:145`）。三件事值得拆开看：

- **$L^3$ 而不是 $L$。** 灰要的是「这个感知亮度在线性光里的值」，而 $M_2^{-1}M_1^{-1}$ 的三行和为 1，所以 $\mathrm{OKLCh}^{-1}(L,0,h)$ 恰好是 $L^3$ 的三个相同分量。写成三次乘法而不是走矩阵，是为了三个通道**逐位相同**，不是「在容差内相同」（`:139`–`:146`）。
- **$\pm1$ 档线性光，不是感知亮度。** 混合说的是「这个颜色在相纸里沉积多少光」，是密度，密度是线性的；S3.6 的亮度说的是「这个颜色看起来多亮」，两者差 8 倍光量。混用会让「绿 +100」把一片中调的叶子推成高光（`Kernels/s3_4_bw.metal:28`–`:33`）。
- **乘性，所以黑仍是黑。** $0\cdot 2^k=0$：一条影调里没有的颜色，滑杆抬不动它。

转换本身不看混合值：开关打开、八个 mix 全 0，画面照样变灰，灰落在像素自己的 $L$ 上（`:40`–`:44`）。**stage 是条件的**——只有开关为真才进链（`Sources/PhotonsCore/EditModel.swift:396`），所以彩色文档根本没编码这个 pass。

**参数与范围**

范围与默认全部来自 `HSLBand`（`Sources/PhotonsCore/EditModel.swift:1985`–`:1996`）与 `ColorGroup`（`:1831`–`:1857`）：

| 参数 | 范围 | 默认 | 单位 | 出处 |
|---|---|---|---|---|
| `bands[i].hue` ×8 | −100…100 | 0 | 滑杆单位（0.3°/单位） | `Sources/PhotonsCore/EditModel.swift:1986` |
| `bands[i].saturation` ×8 | −100…100 | 0 | 乘性系数 − 1，÷100 | `Sources/PhotonsCore/EditModel.swift:1987` |
| `bands[i].luminance` ×8 | −100…100 | 0 | 感知亮度档，$2^{x/100}$ | `Sources/PhotonsCore/EditModel.swift:1988` |
| `bands[i].mix` ×8 | −100…100 | 0 | 线性光档，$2^{x/100}$ | `Sources/PhotonsCore/EditModel.swift:1996` |
| `global.hue/saturation/luminance` | −100…100 | 0 | 同上三轴 | `Sources/PhotonsCore/EditModel.swift:1852` |
| `blackAndWhite` | Bool | false | — | `Sources/PhotonsCore/EditModel.swift:1842` |

24 个数（8×3）是 S3.6 的全部材料，`hasBands` 逐个查值（`Sources/PhotonsCore/EditModel.swift:1933`）；`mix` 不算在 24 里——S3.6 只读三轴，只带 mix 的文档不该为它编一个 pass（`:1930`–`:1932`）。全局三轴另有谓词（`:1937`）。

**实现**

`Kernels/oklch_bands.metal` 是唯一的几何定义：中心、间距、权重函数、中性门，全部一份，由 S3.6 与 S3.4 两个 kernel 各自 `#include`（`Kernels/oklch_bands.metal:3`–`:10`）。CPU 侧 `HSLBands` 是同一份代数在 `Double` 上的参考实现，`HSLTests` 拿两者对跑（`Sources/PhotonsCore/HSLBands.swift:9`–`:13`）。

中心不是手写的度数，而是**用 Lightroom 的 HSL 角度反算出来的**：取 `hsl(0/30/60/120/180/240/285/315, 0.85, 0.5)` 这八个物理颜色，转到工作基色，再量它们的 OKLCh 色相（`Sources/PhotonsCore/HSLBands.swift:136`–`:145`）。所以「红」这个带作用的是那只红苹果，不是 sRGB 色环上的 0°。

上传一份八元结构体数组，每个元素带三轴值与中心、两侧间距（`Sources/PhotonsCore/RenderGraph.swift:6072`–`:6088`）。S3.4 用**同一张表**，只把 `mix` 放在 `.v.x`、其余两轴置 0（`:6094`–`:6109`）。

顺序上 S3.4 在 S3.6 之前（`Sources/PhotonsCore/Stage.swift:191`）。这不是随便排的：黑白写出的灰 $C=0$，S3.6 的中性门会让它整段直写，两个 stage 的唯一交互因此是「下游自动失效」而不是「下游再算一遍」。

**开源对照**

- **darktable · `colorzones.c`** — 最接近的邻居：八个控制节点落在 Lab/LCh 的色相轴上，本质是**一条色相曲线**（<https://github.com/darktable-org/darktable/blob/master/src/iop/colorzones.c>）。差别在归一化：076 之前 Photons 的旧方案只在八顶帐篷之和超过 1 时才归一，于是绿 +100 在自己中心给出 100、在 90°/150° 只剩 25.93，形成 4 倍波纹（`Sources/PhotonsCore/HSLBands.swift:99`–`:101`、`Kernels/s3_6_hsl.metal:20`–`:26`）。现在是构造性的单位和。
- **RawTherapee · HSV Equalizer（`improcfun.cc`）** — 正是 076 搬离的那种构造：在 HSV 里对 H / S / V 各挂一条 FlatCurve，按色相查表（<https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/improcfun.cc>，第 2162–2193 行）。差别是空间与门：HSV 是设备空间的 $l$，没有色度门，灰的色相是任意的——把它当索引去查曲线，结果取决于浮点噪声。
- **darktable · `colorbalancergb.c` 的 hue/chroma 轴** — 绝对色相角加彩度乘数，没有「带」的概念：一串叠加的绝对值没有「所有带同值 = 全局同值」这个性质，而局部支撑的带权重有。 <https://github.com/darktable-org/darktable/blob/master/src/iop/colorbalancergb.c>

**取舍**

八段局部支撑换来两件事：可预测（一个带在自己中心恰好给 100）与可加（八个带同值时处处相同）。代价是它无法把「高光里的蓝」与「阴影里的蓝」分开——那是亮度轴的事，属于 S3.8，不属于这里。

黑白混合挂在同一张表上，省掉第二套色相中心，代价是它只能在开关打开时读：关掉后 mix 仍留在文档里但不渲染（`Sources/PhotonsCore/EditModel.swift:1993`–`:1996`），切回彩色因此逐位可复现。

---

## 4.9 点颜色与三向色彩分级（S3.6b / S3.8）

**它解决什么问题**

八色带只认色相，所以一片枯草和一块肤色在同一个橙带里得到同一处理。人眼区分「同一材质」靠的是三件事一起：亮度接近、色度接近、色相接近。点颜色要的是一个**区域**——围绕一个采样点的盒子，不是一条色相线。三向分级要的是另一个维度：同一个颜色在阴影里该偏冷、在高光里该偏暖，这与它是什么颜色无关。

**算法**

点颜色的窗口建在 Rec.709 full-range YCbCr 上。输入是显示参考域的线性工作基色，所以先转 sRGB 基色、过 sRGB 传递函数，再用**工作基色自己的**亮度权重求 $Y$（`Kernels/s3_6b_point_colour.metal:59`–`:66`）：

$$
Y=w\cdot \mathrm{enc}(M_{\mathrm{w\to sRGB}}\,v),\qquad
U=\frac{B-Y}{1.8556}+0.5,\qquad
V=\frac{R-Y}{1.5748}+0.5
$$

权重是三条软盒之积，$d_a$ 是半宽、$s_a=\tfrac12 d_a f$ 是肩宽：

$$
w_a=1-\mathrm{smoothstep}\bigl(d_a,\ d_a+s_a,\ \lvert x_a-m_a\rvert\bigr),\qquad
w=w_Y\,w_U\,w_V
$$

（`:164`–`:167`）。三条轴**等权相乘**，不是加权和：盒子是一个区域，不是一个评分。半宽是 $d_Y=0.06$（约 ±15/255）、$d_U=d_V=0.10$（约 ±13/255），肩宽是半宽的一半，所以盒子在边界上 $C^1$ 且恰好归零（`Sources/PhotonsCore/PointColor.swift:54`–`:58`）。亮度盒最紧，因为亮度携带「是不是同一块材质」的信息；色度盒更宽，因为人眼的色度分辨率低得多。

另有一道硬地板：像素自身的 YUV 色度若低于 $0.5\,c_0$，权重直接为 0（`Kernels/s3_6b_point_colour.metal:132`、`Sources/PhotonsCore/PointColor.swift:60`）。灰因此逐位不变，接近灰的渐变也不会被误染。

一个文档最多八个采样色，**按数组顺序全部渲染**，每个都看前一个的输出（`Kernels/s3_6b_point_colour.metal:149`–`:177`、`Sources/PhotonsCore/PointColor.swift:313`）。三个调整量与 HSL 卡同单位：

$$
H\mathrel{+}=w\,a_h\,0.3,\qquad
C\mathrel{*}=\Bigl(1+w\frac{a_s}{100}\Bigr),\qquad
L\mathrel{*}=2^{\,w a_l/100}
$$

（`Kernels/s3_6b_point_colour.metal:172`–`:174`）。注意每个量都乘 $w$，所以在肩上三条一起归零，穿过盒子边界的渐变不会有台阶。

三向分级用 S2 的亮度窗口决定「哪个轮子管这个像素」：

$$
w_{sh}=1-\mathrm{smoothstep}(-5.9,-3.9,L),\qquad
w_{hi}=\mathrm{smoothstep}(-3.2,-1.2,L),\qquad
w_{mid}=1-w_{sh}-w_{hi}
$$

（`Kernels/tone_shape.metal:53`–`:57`、`Kernels/s3_8_grade.metal:77`–`:81`），其中 $L=\log_2 Y$，$Y$ 按工作基色的权重求（`:54`）。两个窗口不重叠（$-3.9<-3.2$），第三个数是余量，所以三者和恒为 1，且这个 stage 没有自己的窗口表。

参数**先混后算**，这是「中性轮在自己区域里给出恰好零」的原因：

$$
\delta h=0.3\sum_i w_i h_i,\qquad
\kappa=1+\frac{1}{100}\sum_i w_i s_i,\qquad
\delta l=\frac{1}{100}\sum_i w_i l_i
$$

（`Kernels/s3_8_grade.metal:107`–`:113`）。然后：

$$
v_1=\mathrm{OKLCh}^{-1}\bigl(L,\ \kappa C,\ h+\delta h\cdot g\bigr),\qquad
v_2=v_1\cdot\mathrm{clamp}\Bigl(\frac{Y_{\mathrm{in}}}{Y(v_1)},\ 0.125,\ 8\Bigr),\qquad
\mathrm{out}=v_2\cdot 2^{\delta l}
$$

（`:136`–`:138`、`:165`–`:169`、`:172`–`:174`）。三步各有理由：

- 色相旋转在 $L$ 与 $C$ 不动的前提下做，**亮度不跟着动**；饱和改 $C$ 会改 $Y$（同 $L$ 下更鲜艳的像素亮度不同），所以第三步把 $Y$ 乘回输入值。这个恢复是一次**均匀增益**，而均匀增益不会移动 OKLCh 色相——折叠对 RGB 线性、立方根把增益变成 $(\ell,m,s)$ 上的标量，$(L,a,b)$ 同乘 $g^{1/3}$，$\operatorname{atan2}(b,a)$ 不变（`Sources/PhotonsCore/ColorGrade.swift:33`–`:38`）。「饱和不动色相」因此是算术性质，不是容差。
- 工作基色装不下的彩度会回来一个负通道，硬剪会转色相（阴影片上实测 8.4°）并丢掉刚恢复的亮度，所以**缩短这次移动**：在输入彩度与请求彩度之间二分六步，停在装得下的最宽处（`Kernels/s3_8_grade.metal:152`–`:160`）。
- 亮度是纯增益 $2^{\delta l}$，$\pm100$ 就是该区域 $\pm1$ 档光，与曝光同一个单位——档（`Sources/PhotonsCore/ColorGrade.swift:64`–`:65`）。

**参数与范围**

| 参数 | 范围 | 默认 | 单位 | 出处 |
|---|---|---|---|---|
| `point.sampleY/U/V` | 0…1（U/V 以 0.5 为中性） | 0.5 / 0.5 / 0.5 | Rec.709 full-range 码 | `Sources/PhotonsCore/PointColor.swift:68`–`:70` |
| `point.range` | 0…120 | 30（= 上面的半宽） | 倍数，÷30 | `Sources/PhotonsCore/PointColor.swift:73` |
| `point.feather` | 0…120 | 30（= 半宽的 1/2） | 倍数，÷30 | `Sources/PhotonsCore/PointColor.swift:75` |
| `point.hue` | −100…100 | 0 | 0.3°/单位 | `Sources/PhotonsCore/PointColor.swift:77` |
| `point.saturation` | −100…100 | 0 | 乘性系数 − 1，÷100 | `Sources/PhotonsCore/PointColor.swift:79` |
| `point.luminance` | −100…100 | 0 | 感知亮度档 | `Sources/PhotonsCore/PointColor.swift:81` |
| 采样色个数 | 1…8 | —（空 = 无此 pass） | 个 | `Sources/PhotonsCore/PointColor.swift:313` |
| `shadows/midtones/highlights.(hue,sat,light)` | −100…100 ×9 | 全 0 | 0.3° / 乘性 / 光档 | `Sources/PhotonsCore/EditModel.swift:2062`–`:2075` |

分级的九个 0 是 `hasGrade`（`Sources/PhotonsCore/EditModel.swift:402`），点颜色的谓词是「至少一个采样色**且**有非零调整」（`:1943`、`Sources/PhotonsCore/PointColor.swift:177`）——只有采样没有调整不构成 stage，只有调整没有采样也不构成。

**实现**

`Kernels/s3_6b_point_colour.metal` 与 `Kernels/s3_8_grade.metal`，两个全分辨率 pass，都在 S3.6 之后、S3.9 之前（`Sources/PhotonsCore/Stage.swift:191`）。两者都带同样的三道早退：空内容窗口、alpha 0、内容矩形之外。

内核按成本排序：$Y$ 只依赖三行矩阵与三条 OETF，先算一次，把绝大多数像素挡在循环外（`Kernels/s3_6b_point_colour.metal:112`–`:126`）；$U/V$、色度地板与 OKLab 都推迟到某个盒子放行之后。像素在各盒子之间保持 OKLCh 形态，只有前一个采样色真的写了东西才重折 YUV（`:139`–`:160`）。

分级的主机侧把「混参数」定义成 `Effective`（色相度、彩度乘数、光档），与 kernel 同一顺序：先混、再转换、再恢复亮度、再加增益（`Sources/PhotonsCore/ColorGrade.swift:110`–`:134`）。

> **一处 α 期文档债。** `Kernels/tone_shape.metal` 里现在有两个窗口函数：074 R2 的两窗 `region_weights`（`:53`）与 085 的三窗链 `region_weights3`（`:98`），S2 的全局段用后者，分级仍 include 前者（`s3_8_grade.metal:10`–`:16`）。两套在 $-3.9$ 以下、$-1.2$ 以上一致，中间的过渡不同；`Sources/PhotonsCore/ColorGrade.swift:45`–`:52` 的注释还写着「S2 自己的窗口」，严格说只对 074 成立。改窗口时两处必须一起改，否则「高光」在两张卡上会重新变成两个区域。

**开源对照**

- **darktable · `colorbalancergb.c`** — 三只轮子加一个全局段，工作在 Filmlight Ych，每只轮存**绝对色相角**（<https://github.com/darktable-org/darktable/blob/master/src/iop/colorbalancergb.c>）。Photons 存的是**偏移**：交叉淡化时偏移是普通数，直接线性插值即可；绝对角需要圆环插值（350° 与 10° 相差 20°，不是 340°），而且「阴影是橙色」会变成「把所有阴影像素旋到橙色」，抹掉画面自己的颜色差异（`Sources/PhotonsCore/EditModel.swift:2050`–`:2061`）。
- **RawTherapee · Color Toning（`improcfun.cc`）** — 阴影/中间调/高光各三个 RGB 数，外加饱和度保护与一条强度曲线（<https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/improcfun.cc>，第 2281–2296 行）。它直接加在通道上，因此会同时改亮度与色相；Photons 先转色相、再恢复 $Y$、最后才乘亮度，三个量互不串。
- **LightZone · `ColorBalanceOperation.java`** — 三条互补轴（Cyan-Red / Magenta-Green / Yellow-Blue）加一个 midpoint，Highlights / Midtones / Shadows 三个选项把 midpoint 设成 0.62 / 0.18 / 0.04，最后生成每通道一条 B 样条 LUT（<https://github.com/ktgw0316/LightZone/blob/master/lightcrafts/src/main/java/com/lightcrafts/model/ImageEditor/ColorBalanceOperation.java>，第 83–140 行）。差别是维度：它一次只作用一个影调档、靠通道加减；Photons 三个档同时按权重混合，且旋转的是 OKLCh 色相。

**取舍**

点颜色的盒子是**矩形**：三个轴独立，所以它抓不住「同一个色相、不同明度」斜着穿过盒子的那种颜色（一条从亮到暗的渐变会有一半在盒外）。换成椭球能贴合得更好，但每个采样色要多存一个方向，八个的上限立刻变成负担。

这套系统按「一个维度一个 stage」组织，每个 stage 只有一个划分；代价是组合靠链序——先黑白再色带再分级，顺序变了结果就变，而链序不开放给用户。

分级的窗口只有一套，所以 18 % 灰（码 118）读作 $-2.44$ EV，落在 $(0,\ 0.70,\ 0.30)$：中间调轮占七成，高光轮已经开始碰它（`Sources/PhotonsCore/EditModel.swift:2122`–`:2123`）。这是一张表的代价，也是「高光」这个滑杆自 074 R2 起就有的同一个重叠。

校准（`CalibrationGroup`，七个 ±100 的数）在 S1 的线性光上做矩阵，改的是「哪个通道算红」，不在这一章展开（`Sources/PhotonsCore/EditModel.swift:2636`、`:363`）。
