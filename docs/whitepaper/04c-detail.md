# 4.10–4.15 细节与效果

这一章讲六个作用在成品图上的算子：纹理与清晰度、锐化、两套降噪、去雾、暗角、颗粒。它们分散在链的两端。去雾和暗角在场景线性域，其余四组在显示参考域。判据还是第 3 章那句话：**操作必须待在它的量所在的域里**。

---

## 4.10 纹理与清晰度（S3.9）

**它解决什么问题**

一张照片的细节不在一个尺度上。皮肤毛孔、织物纹理落在 2–8 px 的细带；云层的体积、建筑的明暗关系落在画幅几个百分点的中带（`Sources/PhotonsCore/EditModel.swift:2461`、`:2487`）。普通 unsharp mask 两个尺度一起放大，代价是每条强边两侧各留一圈 3–6 px 的光环。纹理与清晰度要的是同一件事的两个尺度，但不要光环。

**算法**

用的是引导滤波（He/Sun/Tang 2010）。引导图取画面自己的亮度，`p = I` 自引导，滤波输出就是基底层：

$$
I=\langle \mathrm{rgb},\,w\rangle,\qquad w=(0.2126,\ 0.7152,\ 0.0722)
$$

统计量在 `q × q` 块上求（`q = 4`）：每块写入 $(\bar I,\ \overline{I^2})$。块平均会把 2 px 级的纹理从回归里抹掉，阶梯边抹不掉（`Sources/PhotonsCore/RenderGraph.swift:4460`、`Kernels/s3_8_detail_fx.metal:96`）。再对这两张统计图做半径 $r$ 的可分离盒均值，得到窗口均值：

$$
\mu_I=\mathrm{box}_r(\bar I),\qquad \mu_{II}=\mathrm{box}_r(\overline{I^2})
$$

系数逐块求解（`Kernels/s3_8_detail_fx.metal:207`–`:210`）：

$$
\sigma^2=\max(\mu_{II}-\mu_I^2,\ 0),\qquad
a=\frac{\sigma^2}{\sigma^2+\varepsilon},\qquad
b=\mu_I\,(1-a)
$$

$\varepsilon$ 是幅度阈值。0.05 的纹理（方差 2.5e-3）保留约 60 % 残差，边缘块（方差约 5e-2）只留 8 %（`Kernels/s3_8_detail_fx.metal:28`）。系数图另存第三个通道，也就是梯度门，取窗口均值的一阶差分：

$$
g=\max\bigl(\lvert \partial_x \mu_I\rvert,\ \lvert \partial_y \mu_I\rvert\bigr),\qquad
\mathrm{gate}=1-\mathrm{smoothstep}(g_0,\ g_1,\ g)
$$

门不能省。`base` 是窗口均值，强边两侧 3–6 px 处 $I-\mathrm{base}$ 仍然很大，而 $a$ 已经落下，引导滤波的经典光环就出在这里。门把残差在阶梯处关掉（`Kernels/s3_8_detail_fx.metal:33`–`:36`）。同一阶梯上实测，本实现过冲 0.00 码，同半径 unsharp 是 32.26 码（`Kernels/s3_8_detail_fx.metal:36`）。

全分辨率重建把两条带合进一个 pass（系数图双线性上采样）：

$$
\mathrm{base}_k=\mathrm{clamp}(a_k I+b_k,\ 0,\ 2),\qquad
\Delta=\sum_{k\in\{\mathrm{tex},\mathrm{cla}\}} A_k\cdot \mathrm{gate}_k\cdot (I-\mathrm{base}_k)
$$

$$
\mathrm{out}=\mathrm{clamp}\bigl(\mathrm{rgb}+\Delta,\ 0,\ c_{\text{ceil}}\bigr)
$$

（`Kernels/s3_8_detail_fx.metal:332`–`:337`、`:415`）。$c_{\text{ceil}}$ 是画面天花板（320）。传 `0` 表示「这一版之前的调用方」，这时退回旧字面量 4.0。残差等量加到三个通道，所以增益只动亮度，不动色度比例（`:232`）。

**参数与范围**

| 参数 | 范围 | 默认 | 出处 |
|---|---|---|---|
| `texture` | −100…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2486` |
| `clarity` | −100…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2491` |
| `nonBayerLuminanceNR` | 0…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2500` |
| `nonBayerColorNR` | 0…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2503` |

实现常数不进文档，改了就等于改渲染：块 `q = 4`，$\varepsilon_{\mathrm{tex}}=4\times10^{-3}$、$\varepsilon_{\mathrm{cla}}=10^{-2}$，门膝 $g_0=0.015$、$g_1=0.06$（`Sources/PhotonsCore/RenderGraph.swift:4684`、`:4508`）。两条带的半径都按**画幅短边的比例**给，在 `1/q` 域取整：纹理 0.15 %、上限 4 texel；清晰度 2 %、上限 24 texel（`Sources/PhotonsCore/RenderGraph.swift:4486`–`:4487`）。短边 2731 px 时分别是约 4 px 与 55 px。所以 25 % 预览和 1:1 窗口锐化的是同一处细节（`Sources/PhotonsCore/EditModel.swift:2397`）。

清晰度的量先乘 0.8。取 1.0 时，加性增益会把全幅均值推移约 1.1 %，而这条滑杆的约定是不改亮度。0.8 把高通增益留在 +67 %，均值落在 1 % 内（`Sources/PhotonsCore/RenderGraph.swift:4601`–`:4605`）。

**实现**

编码在 `Kernels/s3_8_detail_fx.metal`。CPU 侧按「一个 pack、每条带一对盒均值、一张系数图、一个 apply」组织，两条带的系数图分别绑到 apply 的槽 1、槽 2（`Sources/PhotonsCore/RenderGraph.swift:4674`–`:4699`）。统计图用 `rgba32Float`，半精度解不出纹理那种 1e-4 的方差；系数图用 `rgba16Float`，它要被线性采样，而 Metal 不过滤 32 位格式（`Sources/PhotonsCore/RenderGraph.swift:4635`–`:4637`）。盒均值用滑动和，一次种子加每像素两读，半径 55 px 与 4 px 一个价（`Kernels/s3_8_detail_fx.metal:132`–`:134`）。apply 是唯一的全分辨率 pass。`g.x == 0` 时，局部蒙版那段循环整段不存在（`:355`）。

**开源对照**

- **darktable · 局部对比（`contrastntexture.c`）** — 同样是引导滤波残差，不过分 coarse/medium/fine 三级增益，另有一个连续的 `halo_control`；Photons 只有两条固定带和一个硬阈值门。 <https://github.com/darktable-org/darktable/blob/master/src/iop/contrastntexture.c>
- **vkdt · `llap`** — 用局部拉普拉斯金字塔做 clarity，尺度由金字塔层数决定；Photons 是单尺度的引导滤波残差，没有金字塔。 <https://github.com/hanatos/vkdt/blob/master/src/pipe/modules/llap/llap.glsl>
- **RawTherapee · 小波（`ipwavelet.cc`）** — 十来级小波分解，局部对比在残差图上按 level 调；Photons 只暴露两条带，换不到中间层。 <https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/ipwavelet.cc>
- **LightZone · 模糊（`GaussianBlurOperation.java`）** — 整图高斯模糊，是 USM「基底层」最朴素的形式。没有边缘感知，也就没有门可用。 <https://github.com/ktgw0316/LightZone/blob/master/lightcrafts/src/main/java/com/lightcrafts/model/ImageEditor/GaussianBlurOperation.java>

**取舍**

两条带、一个门、一个 $\varepsilon$，换来的是可预测：同一个滑杆在任何缩放下动同一处细节。代价是没有 per-level 控制，半径编译进 CPU，用户碰不到。门也有代价：一条低对比但真实的边（天空与远山）会被判成渐变跟着放大，只能把 clarity 收小。

---

## 4.11 锐化（S3.10）

**它解决什么问题**

`DetailGroup.sharpening` 是解码参数，交给 `CIRAWFilter`。它改一次就要重新解码，滑杆拖不动（`Sources/PhotonsCore/EditModel.swift:2639`–`:2642`）。成品图需要一条能实时预览的锐化：四个数（数量、半径、细节、蒙版），一个 USM，两种尺度，外加一个不许出光环的限制器。

**算法**

亮度与两个高斯（`Kernels/s3_10_sharpen.metal:16`–`:25`）：

$$
I=\langle \mathrm{rgb},w\rangle,\qquad
G_{\mathrm{fine}}=\mathrm{gauss}(I,\ \sigma/2),\qquad
G_{\mathrm{wide}}=\mathrm{gauss}(I,\ \sigma)
$$

$$
d_{\mathrm{wide}}=G_{\mathrm{fine}}-G_{\mathrm{wide}},\qquad
d_{\mathrm{fine}}=I-G_{\mathrm{fine}},\qquad
d=d_{\mathrm{wide}}+t\,d_{\mathrm{fine}},\quad t=\frac{\mathrm{detail}}{100}
$$

$t=0$ 时 1–2 px 那一层权重恰好是 0。所以「细节 = 0 只放大 ≥ σ/2 的结构」是算术结果，不算近似。$t=1$ 退化成普通 USM，$d=I-G_{\mathrm{wide}}$（`Kernels/s3_10_sharpen.metal:27`–`:29`）。

蒙版取的是模糊后亮度的梯度。噪声先被高斯平均掉，门就开不起来：

$$
m=\mathrm{smoothstep}(g_0,\ g_1,\ \max(\lvert\partial_x G_{\mathrm{wide}}\rvert,\lvert\partial_y G_{\mathrm{wide}}\rvert)),\qquad
\omega=\mathrm{mix}(1,\ m,\ \mathrm{masking}/100)
$$

0.44 的阶梯读出 0.44，2 码噪声读出约 0.008，落在 $g_0$ 之下（`Kernels/s3_10_sharpen.metal:368`–`:377`）。增益与限制器：

$$
\Delta_{\mathrm{raw}}=A\,\omega\,d,\qquad
\mathrm{allow}=A\cdot\mathrm{mix}\Bigl(\tfrac12(h_i-l_o),\ \mathrm{codes}(8),\ m\Bigr)
$$

$$
\Delta=\mathrm{clamp}(\Delta_{\mathrm{raw}},\ -\mathrm{allow},\ +\mathrm{allow}),\qquad
\mathrm{out}=\mathrm{clamp}(\mathrm{rgb}+\Delta,\ 0,\ c_{\text{ceil}})
$$

（`Kernels/s3_10_sharpen.metal:400`、`:408`）。出口的 $c_{\text{ceil}}$ 是画面天花板（320，默认 +2.3 EV，可调），不再是字面量 4.0（`:407`）。$l_o,h_i$ 是 4×4 块的亮度范围，双线性上采样后与本像素取并（`:395`–`:396`）。平坦块上 $h_i=l_o$，range 那一半为 0，锐化在那里动不了。光环被画面自己的局部电平夹住，不靠一个常数（`:398`）。边上那一半用码预算，因为「过冲 ≤ 8 码」这句验收的原话就是 8 码：

$$
\mathrm{codes}(k)=\frac{k/255}{0.4396\,v^{-0.5833}},\qquad v=\max(I,\ 0.0031308)
$$

对 sRGB 传递函数的斜率求逆，8 码因此在暗部和高光都还是 8 码（`Kernels/s3_10_sharpen.metal:125`–`:128`）。

**参数与范围**

| 参数 | 范围 | 默认 | 出处 |
|---|---|---|---|
| `amount` | 0…150 | **50** | `Sources/PhotonsCore/EditModel.swift:2644`、`:2655` |
| `radius`（σ，内容像素） | 0.5…3.0 | **2.0** | `Sources/PhotonsCore/EditModel.swift:2645`、`:2655` |
| `detail` | 0…100 | 25 | `Sources/PhotonsCore/EditModel.swift:2646`、`:2656` |
| `masking` | 0…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2647`、`:2656` |

**314 之后锐化是默认开的。** 用户的原话是「默认使用 50 锐化 + 2.0 半径，该数值不写入文件，除非修改为其他值」。`SharpenGroup.init` 的静止值就是 50 / 2.0 / 25 / 0，`isIdentity` 也跟着这一组走，默认文档于是整组不落盘（`Sources/PhotonsCore/EditModel.swift:2663`）。后果是中性文档不再等于「解码 + OETF」。S3.10 的谓词是 `amount > 0`，50 > 0 恒真，每个文档都要过一遍 USM。L3 那条「中性 == 解码 + OETF」因此改成在锐化归零的文档上成立（`Tests/PhotonsCoreTests/BeforeAfterTests.swift:174`）。

`detail` 与 `masking` 默认非零，因为它们只是一个不存在的 pass 的形状参数，没法把 pass 召唤出来。stage 存不存在只看 `amount > 0`（`Sources/PhotonsCore/EditModel.swift:406`）。

**实现**

代码在 `Kernels/s3_10_sharpen.metal`，五个 pass：半分辨率亮度平面（`:192`–`:222`）；块范围（`:139`–`:170`），从半分辨率平面读，省掉一次 11 M texel 的步长读（`:145`–`:148`）；水平双向高斯（`:227`–`:256`），两个尺度共用抽头；垂直双向高斯（`:264`–`:317`），32×8 tile 过线程组内存，把每像素十五次跨行读变成一次装载；最后是 apply（`:326`–`:409`）。

半径的单位是内容像素，CPU 侧换算一次：$\sigma_{\mathrm{canvas}}=\mathrm{clamp}(r,0.5,3)\cdot S$。这里没有 σ 地板（192 删掉了旧的 `max(…, 0.5)`：半个画布像素在 0.2 的适应视图里等于 2.5 个图像像素，还把三个小半径折成同一个核）。基面 stride $p=\max(1,\mathrm{round}(2S))$，一个 texel 两个图像像素；限制器块宽 $q=\max(2,\mathrm{round}(4S))$；门膝 $0.01/S$…$0.04/S$（`Sources/PhotonsCore/RenderGraph.swift:4815`–`:4853`）。亚像素 σ 靠 `s3_10_tap` 的矩匹配核承担，方差为 $\sigma^2$、权重和为 1，不靠夹取（`Sources/PhotonsCore/Kernels/s3_10_sharpen.metal:86`–`:111`）。这次改动把 `StageAlgorithmVersion.sharpen` 推到 3（`Sources/PhotonsCore/AlgorithmVersion.swift:337`）。191 之前 σ 被当成画布像素读，fit 预览因此比同一文档的 1:1 强 3.45 倍（`Kernels/s3_10_sharpen.metal:47`–`:51`）。

**开源对照**

- **darktable · 锐化（`sharpen.c`）** — L 通道上的 USM，半径 0…99、默认 2，阈值 0…100、默认 0.5（`src/iop/sharpen.c` 的参数块）。没有细节/蒙版拆分，也没有码预算限制器。 <https://github.com/darktable-org/darktable/blob/master/src/iop/sharpen.c>
- **RawTherapee · 锐化（`ipsharpen.cc`）** — USM（半径/数量/阈值）之外还有 Richardson–Lucy 反卷积一路，可选迭代与阻尼；Photons 只有 USM。 <https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/ipsharpen.cc>
- **vkdt · `usm`** — 两个数：`amount` 与 `thrs`，基底来自 mip 采样，低于阈值的差被整段折回。没有分带，也没有上限。 <https://github.com/hanatos/vkdt/blob/master/src/pipe/modules/usm/main.comp>

**取舍**

四根滑杆用可用性换可控：`detail` 把「只锐结构 / 全锐」变成一个连续量，`masking` 把噪声从锐化里摘出去。限制器让 8 码成为能测的事实，代价写在代码里：纯平坦块不许动，低对比的纹理只能靠 `detail` 的细带补，`amount` 拧到底也救不回来。所以强锐化在磨砂质感上会显得「只在边上响」。

---

## 4.12 降噪：解码域与显示域

**它解决什么问题**

噪声有两个来源，处理的地方也不同。传感器噪声归解码器：去马赛克、白平衡、噪声模型都在 `CIRAWFilter` 里，Apple 的模型比任何显示域后处理都准，代价是改一次要重新解码（`Sources/PhotonsCore/RenderGraph.swift:146`–`:147`）。解码之后还剩一点，来自压缩、锐化、机内处理，这部分轮到显示域。它得能实时预览，也得能被蒙版局部加权。

**算法**

解码域是四个转发参数。三个 0…1，`detailAmount` 0…3，滑杆位置除以 100 或 10。`nil` 表示「停在这个机身的默认位置」，等价于不赋值（`Sources/PhotonsCore/DetailSettings.swift:30`–`:35`、`:54`–`:58`）。留这个 `nil` 有原因：`colorNoiseReductionAmount` 的基线实测是 0.5，`sharpnessAmount` 也是 0.5（Canon 机身读到 1.0）。把 0 显式写进去，等于关掉 Apple 的一半降噪（`Sources/PhotonsCore/RAWDecoder.swift:619`–`:621`）。

显示域是联合双边网格（Paris/Durand，Halide 的 `apps/bilateral_grid` 形状）：splat、五抽模糊、slice。第三根轴是亮度，保边就靠它，只有落进同一亮度 bin 的邻居才互相平均（`Kernels/s3_9_denoise.metal:8`–`:12`）。

噪声强度先由画面自己估：64×64 点阵上取 3×3 高通的中位绝对偏差，直方图 256 个 bin 覆盖 $|D|\in[0,0.25]$，中位数乘 1.572 换成高斯 σ（`Kernels/s3_9_denoise.metal:39`–`:43`、`:90`）：

$$
\sigma=1.572\cdot\mathrm{median}\bigl(\lvert L-\mathrm{mean}_{3\times3}L\rvert\bigr)
$$

格子的 z 尺度随强度走：

$$
r=\mathrm{clamp}\bigl((0.4+0.6\,\alpha_L)\,\sigma,\ 0.010,\ 0.050\bigr),\qquad
z=\mathrm{clamp}\bigl(\mathrm{round}(L/r),\ 0,\ 39\bigr)
$$

（`Kernels/s3_9_denoise.metal:120`、`:139`）。splat 用**整数**原子加、定点 65535。浮点原子加的次序会改变结果，整数不会，同一帧永远得到同一张网格（`:18`–`:21`、`:145`–`:148`）。z 轴五抽 $[1,4,6,4,1]/16$ 在 splat 的线程组内做完。色度用更宽的七抽 $[1,2,3,4,3,2,1]/16$，因为一条轴上只有一个 bin 宽，「色度容忍 1.5× 更宽的值窗」只能写成更宽的核（`:155`–`:162`）。

slice 在 apply 里做手工三线性插值（`texture3d` 的线性过滤在部分设备上静默退化成最近邻，`:278`–`:280`）：

$$
\bar L=\frac{\sum_c w_c L_c}{\sum_c w_c},\qquad
\Delta_L=\alpha_L\,(\bar L-L)
$$

色度把 OKLab 的 $a,b$ 朝网格均值混合，再把 Rec.709 亮度用一个公共增益放回去：

$$
a'=(1-\alpha_C)a+\alpha_C\bar a,\qquad
b'=(1-\alpha_C)b+\alpha_C\bar b,\qquad
\mathrm{out}=\mathrm{oklch2lin}(L',C',h)\cdot\frac{Y_0}{Y_1}
$$

（`Kernels/s3_8_detail_fx.metal:421`–`:436`）。$C\le10^{-6}$ 的像素整段跳过，灰卡不会被舍入染上色（`:424`）。

**参数与范围**

| 参数 | 组 | 范围 | 默认 | 出处 |
|---|---|---|---|---|
| `noiseLuminance` | `DetailGroup`（解码） | 0…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2413`、`:2419` |
| `noiseColor` | `DetailGroup`（解码） | 0…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2414`、`:2419` |
| `sharpening` | `DetailGroup`（解码） | 0…150 | 0 | `Sources/PhotonsCore/EditModel.swift:2411`、`:2419` |
| `sharpeningRadius` | `DetailGroup`（解码） | 0.5…3 | 1.0 | `Sources/PhotonsCore/EditModel.swift:2412`、`:2419` |
| `nonBayerLuminanceNR` | `EffectsGroup`（S3.9） | 0…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2500` |
| `nonBayerColorNR` | `EffectsGroup`（S3.9） | 0…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2503` |

这两组数在面板上是两张卡，在文档里是两个组，在缓存键里是两个阶段。改解码组要重新 develop，改显示组只重跑 S3.9（`Sources/PhotonsCore/EditModel.swift:2534`–`:2538`）。

**实现**

`Kernels/s3_9_denoise.metal` 里有三个 pass：估 σ、splat、x/y 一次模糊。slice 放在 `s3_8_detail_fx.metal` 的 apply 里，和纹理/清晰度共用一次全分辨率读（`Kernels/s3_8_detail_fx.metal:53`–`:55`）。格子边长 8 px，40 个 z bin（`Sources/PhotonsCore/RenderGraph.swift:4463`–`:4464`）。网格从阶段输入建，不读纹理/清晰度残差，所以 σ 是这个帧的事实，跟滑杆无关（`Sources/PhotonsCore/RenderGraph.swift:4529`–`:4531`）。只拖色度时，引导滤波那条带链整段不建（`:4662`–`:4664`）。

**开源对照**

- **darktable · `bilat`** — 同一套双边网格，另有本地拉普拉斯模式，参数是空间/值域 σ 与 detail；Photons 只有 grid，且亮度与色度用不同宽度的 z 核。 <https://github.com/darktable-org/darktable/blob/master/src/iop/bilat.c>
- **darktable · `denoiseprofile`** — profiled 非局部均值与小波，靠相机噪声剖面把噪声建模到传感器层面；Photons 单帧估一个标量 σ，没有剖面。 <https://github.com/darktable-org/darktable/blob/master/src/iop/denoiseprofile.c>
- **vkdt · `denoise`** — 下采样加协方差估计的分层降噪；Photons 的 σ 是全帧一个数，不分层。 <https://github.com/hanatos/vkdt/blob/master/src/pipe/modules/denoise/main.c>

**取舍**

单帧 σ 省掉了 profile 依赖，打开一张没见过的图就能用。代价是混合内容只有一个 $r$：暗部噪声大、亮部干净的一张图，$r$ 要么放过暗部，要么磨平亮部。色度用更宽的 z 核而不换 bin 宽，因为一条轴只能有一个 bin 宽，这是网格结构的硬限制，不是调参。显示域降噪也替代不了解码域，它没有噪声模型，只会在已经错了的样本上求平均。

---

## 4.13 去雾（S1.9）

**它解决什么问题**

雾是加性的空气光。一个像素收到的，是物体反射的光被透过率衰减之后，再加一层雾幕。要去掉它得知道两件事：幕有多亮（$A$）、有多厚（$t$）。减法必须在光上做，显示码上的「白」不等于场景里的空气光。117 之前这一条在显示域，$A$ 固定为 1，公式退化成 $J=(I-1)/t+1$。对 $I>1$ 的样本它变成加光：去雾越强，HDR 高光越亮（`Kernels/s1_9_dehaze.metal:8`–`:15`）。

**算法**

模型（`Kernels/s1_9_dehaze.metal:17`–`:21`）：

$$
I=t\,J+A\,(1-t),\qquad J=\frac{I-A(1-t)}{t}
$$

暗通道与空气光，$\Omega$ 是 4×4 的块（`Kernels/s1_9_dehaze.metal:147`–`:204`、`Sources/PhotonsCore/RenderGraph.swift:4787`）：

$$
D(p)=\min_c\ \min_{q\in\Omega(p)} I_c(q),\qquad
A=\mathrm{clamp}\Bigl(\max_{\mathrm{blocks}} D,\ 10^{-4},\ 8\Bigr)
$$

$A$ 的估计是一个线程组扫过整张块纹理取最大，这是 He 那个「最亮 0.1 %」的确定性替身（`Kernels/s1_9_dehaze.metal:206`–`:212`）。再上一道物理上限：$A$ 只在明显高于画面亮端时被压到 $\kappa\cdot p_{99}(L)$，$\kappa=0.95$，死区 2 %（`:311`–`:316`）。这条来自实测：+2 EV 的 DJI 帧 $A_{\mathrm{raw}}=2.283$ 而 $p_{99}=2.035$，不压的话 46.8 % 的像素会被写成黑（`:236`–`:243`）。

雾幕不直接取块最小值，先对它做一次引导滤波。引导图是块平均亮度 $l$，被平滑的是 $D$：

$$
a=\frac{\mathrm{cov}(l,D)}{\mathrm{var}(l)+\varepsilon},\qquad b=\mu_D-a\,\mu_l,\qquad \varepsilon=4\times10^{-4}A^2
$$

$$
\mathrm{veil}=a\,l+b
$$

两次盒均值先作用在统计量上，再作用在 $(a,b)$ 上，所以边缘在平滑里保住了，纯低通做不到这一点（`Kernels/s1_9_dehaze.metal:395`–`:419`、`:424`–`:432`）。$\varepsilon\propto A^2$ 让浓雾比淡雾被抹得更狠，淡雾的量化块最小值才不会被当成结构（`:400`、`:412`）。

透过率取两个估计，再按膝宽混合：

$$
t_{\mathrm{smooth}}=\max\bigl(1-\omega\,\mathrm{veil}_R,\ t_0\bigr),\qquad
t_{\mathrm{pixel}}=\mathrm{clamp}\bigl(1-\omega\,\min_c(I_c/A),\ t_0,\ 1\bigr)
$$

$$
\chi=\frac{\max(\mathrm{knee}-\lvert t_{\mathrm{smooth}}-t_{\mathrm{pixel}}\rvert,\ 0)}{\mathrm{knee}},\qquad
t=\min\Bigl(\max(t_{\mathrm{smooth}},t_{\mathrm{pixel}})+\chi^2\,\frac{\mathrm{knee}}{4},\ 1\Bigr)
$$

其中 $\mathrm{veil}_R=\min(\mathrm{veil}/A,\ \min_c I_c/A)$，$\omega=0.95$、$t_0=0.1$、$\mathrm{knee}=0.15$（`Kernels/s1_9_dehaze.metal:533`–`:546`、`Sources/PhotonsCore/RenderGraph.swift:4796`、`:5172`）。取 $\max$ 是防过度恢复，避免把一条暗边压成黑。膝项只在两个估计一致时轻轻抬一点。

恢复只在亮度上做，三个通道乘同一个增益，色相与色度按构造不变。参与度是一段对称的淡出，两端都以空气光估计自己的分辨率为界：130 定下侧，280 定上侧。

$$
J_L=\frac{L-A(1-t)}{t},\qquad
\sigma=2\%\cdot A,\qquad
w=\bigl[1-\mathrm{smoothstep}(A,\ A+2\sigma,\ L)\bigr]\cdot\mathrm{smoothstep}(2\sigma,\ k\cdot2\sigma,\ \lvert L-A\rvert)
$$

$$
L_{\mathrm{out}}=\mathrm{mix}(L,\ J_L,\ w),\qquad
\mathrm{out}=I\cdot\frac{\max(L_{\mathrm{out}},0)}{\max(L,10^{-6})}
$$

（`Sources/PhotonsCore/Kernels/s1_9_dehaze.metal:580`–`:590`。）$A$ 是测量值，本身有 ±4 % 的误差带（引导滤波的 $\varepsilon$ 折出来 $\sigma=2\%A$），比它更小的差不构成证据。下侧的处理是：天空在 $t\approx0.12$ 时只比 $A$ 低 3 %，没有这一项就会被压掉 20 % 的光（`Kernels/s1_9_dehaze.metal:558`–`:570`）。

**280 改的是上侧。** 原来上界是 $2A$：$L$ 落在 $A$ 与 $2A$ 之间时拿满 $1/t$，而对称淡出早就结束了，只比空气光高 20–50 % 的像素于是被乘了 1.6–2.2 倍。实测 `L1030433`、`dehaze = 20` 时，p99–p99.9 段 1.11×、p99.9–p100 段 1.20×（最大 1.23×）；100 时同两段到 1.55×/2.00×（最大 2.17×）。用户说的「去雾把高光抬亮」就是这一段。现在上界也是 $A+2\sigma$，$L\ge A$ 的权重恒为 0，$L<A$ 的部分逐字节不变（`Kernels/s1_9_dehaze.metal:75`–`:86`）。

负值把同一个模型反过来用：$\mathrm{hazy}=0.6I+0.4A$，$\mathrm{out}=\mathrm{mix}(I,\mathrm{hazy},-\mathrm{amount})$（`:592`）。所有估计都在 $I/g$ 上做，恢复完再乘回 $g$，$g=2^{EV}$ 是 S1 的曝光增益，所以 $render(E,D)=2^E\cdot render(0,D)$ 精确成立（`:125`–`:138`、`:595`）。

**参数与范围**

| 参数 | 范围 | 默认 | 出处 |
|---|---|---|---|
| `dehaze` | −100…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2492`、`:2549` |

实现常数：$\omega=0.95$、$t_0=0.1$、$\mathrm{knee}=0.15$、$k=2$、$\kappa=0.95$、无雾阈值 $A<0.02$（`Sources/PhotonsCore/RenderGraph.swift:5179`、`:5186`、`:5191`；`Kernels/s1_9_dehaze.metal:520`）。

**实现**

代码在 `Kernels/s1_9_dehaze.metal`，一共十一个 pass：暗通道、空气光、上限、统计、盒均值 ×2、系数、盒均值 ×2、雾幕、雾幕上采样、apply（`Sources/PhotonsCore/RenderGraph.swift:5087`–`:5099`）。第 4–10 个跑在块分辨率上，q = 4 时是全幅的十六分之一。七个块分辨率 pass 加起来，还不到夹在中间那两个全分辨率 pass 之一（`Sources/PhotonsCore/RenderGraph.swift:5082`–`:5086`）。盒半径取画幅长边的 2 % 再除以 q，24 MP 时约 30 块 ≈ 120 px（`Sources/PhotonsCore/RenderGraph.swift:5168`–`:5170`）。全部在 GPU 上，$A$ 停在 1×1 纹理里，不用回读（`Kernels/s1_9_dehaze.metal:211`）。

**开源对照**

- **darktable · 去雾（`hazeremoval.c`）** — 同一篇论文的暗通道 + 引导滤波，参数是 strength / distance / adaptive；Photons 多一个像素级 $t$ 下界与膝混合，且 $A$ 有 $p_{99}$ 上限、按曝光归一。 <https://github.com/darktable-org/darktable/blob/master/src/iop/hazeremoval.c>
- **RawTherapee · 去雾（`ipdehaze.cc`）** — 暗通道后用 guided filter 做 soft matting，逐通道估 ambient；Photons 只在亮度上反演再乘公共增益，所以不改色相。 <https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/ipdehaze.cc>
- **vkdt · `dehaze`** — 模块自带 `depth.comp`，可以用深度图引导透过率；Photons 在 175 删掉了深度项，$t$ 只是关于画面的事实。 <https://github.com/hanatos/vkdt/blob/master/src/pipe/modules/dehaze/main.c>

**取舍**

保色相加双重淡出，换来的是天空不会被去雾压暗，彩色边缘也不会转色。代价是去雾本身不加饱和度：浓雾去掉之后画面发灰，得靠饱和或分级补回来。这是刻意的，一条滑杆只做一件事，比同时改色相可靠。另一个代价是 $A$ 只有一个全局值，画面里两种雾（远山与近地蒸汽）只能取一个折中。

---

## 4.14 暗角（S3c）

**它解决什么问题**

镜头照度沿半径衰减，角落比中心暗，校正就是乘一个随半径上升的增益。它也能反着用：压暗角落，把视线收回中心。两件事都乘在光上。所以它虽然叫 S3c、参数也放在效果卡里，执行却排在 S2 之前的线性链末尾（`Sources/PhotonsCore/Stage.swift:151`–`:154`、`:190`）。

**算法**

先把画布像素换到整幅画面的坐标，再取一个度量（`Kernels/s3_vignette.metal:45`–`:57`）：

$$
\mathrm{px}=(\mathrm{uv}-0.5)\cdot\mathrm{size},\qquad
\mathrm{norm}=0.5\cdot\lVert\mathrm{size}\rVert,\qquad
d=\frac{\lVert \mathrm{px}\rVert}{\mathrm{norm}}
$$

归一用半对角线，所以任何画幅比例的**角落都恰好是 1.0**。旧实现按短边一半归一，3:2 的角落是 1.803，`inner` 最大 1.05，永远够不到（`:10`–`:16`）。

衰减曲线是一个可调宽度的 smoothstep：

$$
w=\max\Bigl(\frac{\mathrm{feather}}{100}\cdot0.5\,(1-\mathrm{mid}),\ 0.002\Bigr),\qquad
t=\mathrm{smoothstep}(\mathrm{mid}-w,\ \mathrm{mid}+w,\ d)
$$

$$
\mathrm{gain}=\mathrm{clamp}\Bigl(1+\frac{\mathrm{amount}}{100}\,t,\ 0,\ 4\Bigr),\qquad
\mathrm{out}=\mathrm{rgb}\cdot\mathrm{gain}
$$

（`Kernels/s3_vignette.metal:59`–`:72`）。`mid` 是 50 % 点，0 在中心（全幅变暗），1 在角落。宽度在角落处自动收窄。不收窄的话，midpoint = 100 时过渡带会从 0.75 开始，把长边中点也压暗。下限 0.2 % 是因为零宽台阶在 1.0 处碰不到任何像素中心，角落会一点都不暗（`:62`–`:68`）。

**参数与范围**

| 参数 | 范围 | 默认 | 出处 |
|---|---|---|---|
| `vignetteAmount` | −100…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2470`、`:2545` |
| `vignetteMidpoint` | 0…100 | 50 | `Sources/PhotonsCore/EditModel.swift:2471`、`:2545` |
| `vignetteFeather` | 0…100 | 50 | `Sources/PhotonsCore/EditModel.swift:2472`、`:2546` |

内核把 feather 夹到 2…100 %，gain 夹到 0…4（`Kernels/s3_vignette.metal:60`、`:71`）。

**实现**

一个全分辨率 pass，在 `Kernels/s3_vignette.metal`，读帧尺寸和窗口原点，不读画布。1:1 窗口必须看到和整幅同一物理位置的衰减，留黑边不参与（`Sources/PhotonsCore/RenderGraph.swift:4275`–`:4277`）。形状恒为圆，因为镜头旋转对称，衰减也对称。134 之后没有「圆度」这个字段，旧文档里那个键会被当成未知键忽略（`Sources/PhotonsCore/EditModel.swift:2453`–`:2455`）。

**开源对照**

- **darktable · 暗角（`vignette.c`）** — fall-off start/radius 加 brightness/saturation 与 shape/ratio，是显示域的创作暗角，还能顺手去饱和；Photons 只乘光、不改饱和，形状恒圆。 <https://github.com/darktable-org/darktable/blob/master/src/iop/vignette.c>
- **vkdt · `vignette`** — 四次多项式加 sigmoid 的光学模型，带 center、cx/cy 与旋转角，能表达椭圆与偏轴衰减；Photons 是单一圆、半对角线归一，没有角度。 <https://github.com/hanatos/vkdt/blob/master/src/pipe/modules/vignette/main.comp>

**取舍**

圆加半对角线，让「角落 = 1」成了与画幅无关的事实，导出和预览因此一致，参数也只剩三个。代价是做不了椭圆暗角和偏轴暗角，那属于镜头剖面的活，硬塞进这条滑杆只会让 corner = 1 失效。另一处代价：因为在光域乘，$amount>0$ 时角落会被推到 $1.0$ 以上，实际能提亮多少由 S2 与 S4 的 headroom 决定，滑杆自己说了不算。

---

## 4.15 颗粒（S3.7）

**它解决什么问题**

成品图需要一层胶片式的颗粒：均匀、单色、尺度可调，盖在已经画好的画面上。它必须是确定的：同一份文档每次渲染出同样的字节，否则缓存键、导出和预览三者对不上（`Kernels/s3_7_grain.metal:20`–`:23`）。

**算法**

位置先换到整幅画面的归一坐标，格子尺寸按画幅比例给（`Kernels/s3_7_grain.metal:103`–`:108`）：

$$
\mathrm{cell}=\mathrm{mix}\Bigl(\frac{1}{1500},\ \frac{1}{200},\ \frac{\mathrm{size}}{100}\Bigr),\qquad
q=\frac{\mathrm{uv}}{\mathrm{cell}}
$$

$$
n=\bigl[\mathrm{mix}\bigl(V(q,s),\ V(2q,\ s\oplus \mathtt{0x9E3779B9}),\ \rho\bigr)\bigr]\cdot2-1
$$

$V$ 是 smoothstep 插值的值噪声，格点值来自 32 位雪崩哈希（`Kernels/s3_7_grain.metal:48`–`:77`）：

$$
h=(x\cdot\mathtt{0x9E3779B1})\oplus(y\cdot\mathtt{0x85EBCA77})\oplus(\mathrm{seed}\cdot\mathtt{0xC2B2AE3D})
$$

再做三轮 `h ^= h >> k; h *= C`，取高 24 位当尾数、除以 $2^{24}$，值严格落在 $[0,1)$，相邻格点的低位不相关（`:57`–`:62`）。最后按幅度叠加：

$$
\sigma=\frac{\mathrm{amount}}{100}\cdot0.055,\qquad
\mathrm{out}=\mathrm{clamp}(\mathrm{rgb}+n\,\sigma,\ 0,\ c_{\text{ceil}})
$$

（`Kernels/s3_7_grain.metal:111`–`:113`、`:116`）。$c_{\text{ceil}}$ 同样是画面天花板，颗粒不许把像素推过用户设的上限。0.055 在 0…1 单位里约等于 8 位输出的 14 码，和 Lightroom 自己 100 的位置一样（`:110`）。

哈希必须是**标量**的。第一版写成 `uint3(x,y,seed)`，每个算子都逐分量，seed 只进 `.z`，又从不回写 `.x`，两个不同种子给出同一张图（`:43`–`:47`）。

**参数与范围**

| 参数 | 范围 | 默认 | 出处 |
|---|---|---|---|
| `grain`（amount） | 0…100 | 0 | `Sources/PhotonsCore/EditModel.swift:2456`、`:2547` |
| `grainSize` | 0…100 | 25 | `Sources/PhotonsCore/EditModel.swift:2458`、`:2547` |
| `grainRoughness` | 0…100 | 50 | `Sources/PhotonsCore/EditModel.swift:2459`、`:2548` |
| `grainSeed` | 0…999 | 0 | `Sources/PhotonsCore/EditModel.swift:2460`、`:2548` |

种子在进内核前被量化并夹紧，缓存键与 uniform 因此不会对不上（`Sources/PhotonsCore/EditModel.swift:2509`–`:2512`）。

**实现**

一个全分辨率 pass，在 `Kernels/s3_7_grain.metal`，位置在暗角之后、S4 之前。颗粒盖在已完成的画面上，之后只剩编码（`Sources/PhotonsCore/Stage.swift:155`–`:162`、`:190`–`:196`）。`amount = 0` 时整条 stage 不编码，不会先编码再乘 0（`Sources/PhotonsCore/EditModel.swift:2517`）。缓存键里带种子，两份只差种子的文档不能共享缓存（`:2614`–`:2618`）。格子按画幅比例给，不按画布像素，1:1 窗口和 9504 px 的导出拿到的是同一颗颗粒（`Kernels/s3_7_grain.metal:12`–`:16`）。

**开源对照**

- **darktable · 颗粒（`grain.c`）** — 有 scale、strength 与中间调偏置，内部还有亮度/色相/饱和三个强度常数，颗粒不只作用在亮度上；Photons 单色、无中间调加权，第二倍频由一个 roughness 权重控制。 <https://github.com/darktable-org/darktable/blob/master/src/iop/grain.c>
- **RawTherapee · 胶片颗粒（`ipgrain.cc`）** — 按 ISO 与尺寸查表，颗粒强度随感光度走，作用在 Lab 的 L 上；Photons 与 ISO 无关，纯程序化。 <https://github.com/RawTherapee/RawTherapee/blob/dev/rtengine/ipgrain.cc>
- **vkdt · `grain`** — size / magnitude / decay / octaves，哈希里带帧号，所以颗粒逐帧变化，适合动画；Photons 的种子只由文档决定，同一文档每一帧都是同一张。 <https://github.com/hanatos/vkdt/blob/master/src/pipe/modules/grain/main.comp>

**取舍**

单色加两个倍频加一个标量种子，换来的是便宜、可缓存、可复现：颗粒不需要读邻居，一个 pass 结束，种子一改就是另一张图，不动别的键。代价有三处：没有色度颗粒，在高饱和区域看起来比胶片「干」；没有按亮度加权，暗部和亮部同一个 $\sigma$，暗部颗粒视觉上更明显；尺度只有两档（主格加半格），再细的结构只能靠 `size` 一个人扛。

---

六组算子之间有一条共同的线：域决定公式，公式决定参数，参数的范围由内核能兑现的算术决定。去雾和暗角在光域，所以能和曝光交换，能保留大于 1 的高光。纹理、锐化、两种降噪在显示域，半径和预算都按画幅或码取值。颗粒站在链尾，是唯一只做加法、不读邻居的算子。
