# iPad 内容更新：逐项追踪

一个主题 PR，各独立验收项分别 commit。基线为 `1db8fe3`；应用基线等同 PR 2 的 `a5cf5eb`，PR 2 当前未合并。本分支保留原有分支，不改写已发布历史。现已合入上游 main `737f92d`；统一 PR： https://github.com/chemharuka/photons/pull/3 。

| 编号 | 独立验收项 | 依赖 |
|---|---|---|
| IPAD-01 | Close 清理临时全景、恢复进入前视图，导出继续完成 | 基线 |
| IPAD-02 | 网格关闭所选照片侧栏时取消选中 | 基线 |
| IPAD-03 | 网格双击进入大图、大图左右翻页 | IPAD-02 |
| IPAD-04 | Fit/指定倍率双击切换、50/100/200/自定义、局部像素渲染 | IPAD-03 |
| IPAD-05 | 单图片库中的文件夹管理与筛选 | IPAD-03 |
| IPAD-06 | 对齐 Mac 信息结构的直方图 | 基线 |
| IPAD-07 | 有界、可复用的 HDR/SDR 预览缓存 | IPAD-04 |
| IPAD-08 | 设置中的缓存大小与清理 | IPAD-07 |
| IPAD-09 | 综合验证、PR 更新日志、iPad Developer Beta build 4 | 以上各项 |

## IPAD-01

- 原问题：临时拼接 plan/frame 在 Close 后留在主大图，直到选中另一照片。
- 变更：显式记录进入全景前的网格/大图状态；退出清空 plan/manifest/临时预览、使待完成预览失效，恢复原照片。导出先捕获 plan，退出不会取消已确认的导出。对齐任务取消后不再回填预览。
- 文件：MobileWorkspaceModel.swift、MobileWorkspaceView.swift、MobilePanoramaWorkspace.swift、IPadEngineTests.swift。
- 验证：iPad Pro 13-inch (M5) 模拟器 `testClosingPanoramaDiscardsTransientPreviewAndRestoresView` 通过，1 项 / 0 失败；日志 `local/build-logs/ipad-content-update/01-close.log`。
- 限制：物理设备 HDR/内存待 beta 验证；回退需同时回退视图与模型生命周期入口。
- Commit：以 `IPAD-01` 查询提交标题；无移植代码。

## IPAD-02

- 原问题：再次单击当前照片会关闭侧栏，但勾选与橙色高亮残留。
- 变更：单击当前照片、关闭网格侧栏或收起窄屏信息面板时清空单选；取消过期选中/渲染任务，避免错误照片回填。多选模式不受侧栏开关影响。缩略图增加明确的无障碍选中状态。
- 文件：MobileWorkspaceModel.swift、MobileWorkspaceView.swift、IPadUITests.swift。
- 验证：`testGridInspectorToggleDeselectsPhoto` 模拟器 UI 测试通过，1 项 / 0 失败，覆盖两次单击、重新选中及侧栏按钮关闭；日志 `02-selection.log`。
- 依赖：基线；提交标题含 `IPAD-02`，无移植。限制：窄屏分支已编译，完整横竖屏手动检查留待最终验收；回退模型方法与调用方一起回退。

## IPAD-03

- 变更：网格双击直接打开大图；单击和长按仍分别负责信息/多选。Fit 下左右滑动按当前搜索结果翻页，首尾停止，不循环；放大后的拖动留给平移。大图另有上一张/下一张按钮与文件名。
- 文件：MobileWorkspaceView.swift、MobileWorkspaceModel.swift、IPadUITests.swift。
- 验证：`testDoubleTapOpensPhotoAndSwipesNavigate`、`testGridInspectorToggleDeselectsPhoto` 通过，2 项 / 0 失败；日志 `03-navigation.log`。初次边界断言受到旧样例导出污染，测试现以 `--demo --reset-demo` 重置专用 Generated Samples 库；正常用户库不受影响。单击断言等待系统双击识别窗口结束。
- 依赖：IPAD-02 (`1ad56ac`)；提交标题含 `IPAD-03`。限制：缩放导航规则将在 IPAD-04 延续；物理触屏最终体验由 beta 验证。无移植，回退需同步恢复手势与 UI 测试。

## IPAD-04

- 变更：大图右上角显示当前倍率、Fit 和双击目标；50/100/200% 及 10–800% 自定义倍率持久保存。双击在 Fit 与目标间切换，手势缩放/平移保留；100% 按图像像素对屏幕物理像素计算。缩放或平移结束后的可见区域以 180 ms 去抖请求实际像素，不再只拉伸 Fit 预览。
- 渲染：使用共享 RenderGraph 的 outputWindow，包含编辑后裁剪/旋转坐标，额外 64 px 邻域支持防止窗口边界影响锐化；全景/LCC 使用共享线性 composite 的可见区域。旧请求在切图、编辑、HDR 切换、退出全景及内存警告后失效。空间不足保留预览并给出提示，不虚称已有完整细节。
- 文件：新增 MobilePhotoCanvas.swift；MobileEngine/WorkspaceModel/WorkspaceView/PanoramaWorkspace，engine/UI 测试。
- 验证：`testZoomDetailMatchesEditedFullResolutionPixels` 通过，比较裁剪、旋转、曝光后的局部和完整渲染；最初无邻域余量时边缘差异暴露了锐化边界问题，修复后通过。模拟器内存预算使用物理内存的受限比例，实体机使用可用进程内存。
- UI 验证：`testDoubleTapTogglesFitAndSelectedMagnification` 最终通过，覆盖 Fit↔200%、Fit↔50%、自定义150%和 Fit 按钮；自定义输入改为带固定顶部操作栏的 sheet，避免键盘遮住确认按钮。导航在新视口实现上已通过。日志 `04-zoom.log`、`04-zoom-ui.log`。
- 依赖：IPAD-03 (`e886f58`)。提交标题含 IPAD-04。限制：原始文件解码仍可能需要整幅源图；局部输出避免整幅后处理/显示缓冲，但不声称 RAW 解码完全分块。全景多源高倍率受内存预算限制。无移植；回退需同步回退新视口、引擎区域入口和模型请求失效逻辑。

## 补充需求

- IPAD-10：iPad 简体中文界面，独立 commit，与其余功能同一 PR/build。
- IPAD-11：Lens profiles 详情（相机/光圈/标定机身/备注、方向与覆盖范围、各标定帧参数），独立 commit，与其余功能同一 PR/build。
- IPAD-09 的最终交付还依赖 IPAD-10、IPAD-11。

## IPAD-05

- 变更：固定单一 iPad 图片库，明确拒绝把另一 `.photonslibrary` 当照片导入。库内增加 All photographs / Unfiled / 自建文件夹、计数、创建/重命名/移除、移动选中照片及当前文件夹导入。大图翻页使用当前文件夹与搜索结果。
- 数据：文件夹是库内的归类目录，一张照片最多属于一个文件夹；索引原子保存在该库的 MobileFolders.json。整理文件夹不搬动或复制原片，移除文件夹只使成员返回 Unfiled，保留编辑历史。已有图库自动以未归类方式兼容，不创建第二用户库。
- 文件：MobileLibraryFolders.swift、MobileEngine/WorkspaceModel/WorkspaceView、engine/UI 测试。
- 验证：`testSingleLibraryFoldersPersistWithoutChangingOriginalsOrEdits` 和 `testFoldersFilterMoveAndPersist` 通过，2 项 / 0 失败；验证重开持久化、原片字节/编辑不变、名称冲突、跨库导入拒绝、UI 创建/移动/筛选。日志 `05-folders.log`。
- 依赖：IPAD-03；提交标题含 IPAD-05。限制：本轮为库内单层归类，不把 Files 中的物理文件夹变成第二库；移除文件夹有明确保留照片的确认。无移植。回退代码不会删除索引或原片。

## IPAD-06

- 变更：侧栏直方图增加 HDR/SDR 与色域、输出尺寸、0–255 代码坐标、HDR +1…+4 EV 轴、当前显示上限、过白/削顶/削底、采样数和触摸代码/档位/RGB bin 读数。采用 Mac 的 SDR/HDR 各半宽、线性高度、排除端点尖峰的每通道归一化与 RGB 加色叠加；无额外白色曲线。
- 文件：新增 MobileHistogram.swift，Inspector 调整，engine/UI 验证。
- 来源：参考当前基线的 Sources/PhotonsUI/HistogramPlot.swift、HistogramCard.swift；测量仍来自共享 Histogram/HistogramSnapshot。未改 Mac 行为。
- 验证：`testHistogramAxisAndDisplayClippingMatchMacSemantics`、`testHistogramShowsClippingAndTouchReadout` 通过，2 项 / 0 失败；显示上限改变不改变 bins，触摸读数和统计行可见。日志 `06-histogram.log`，UI 测试保留截图。
- 依赖：共享直方图基线；提交标题含 IPAD-06。限制：触摸直方图显示 bin 计数，不是照片上触点的逐像素 RGB；真实 HDR 显示仍需设备验证。回退新视图和 Inspector 调用即可。

## IPAD-07

- 变更：一次场景线性渲染生成 HDR/SDR 配对预览与直方图；切换模式复用大图、缩略图、局部细节和全景预览。全景切换不再调用调色/重新合成入口。照片预览持久化为半浮点 LZFSE 无损配对记录，重启可复用，损坏记录自动重新生成。
- 预算：大图 96 MiB、缩略图 16 MiB、局部细节 48 MiB 独立 LRU；磁盘预览最多 512 MiB。缓存键包含源文件路径/大小/修改时间、编辑参数、尺寸和视口；磁盘解压使用固定尺寸缓冲，避免无界解压。收到内存警告释放工作缓存。
- 文件：MobilePreviewCache.swift、MobileEngine.swift、MobileWorkspaceModel.swift、IPadEngineTests.swift。依赖 IPAD-04；无移植代码。
- 验证：HDR 高光/持久化、局部像素一致性、全景切换复用均通过；配对缓存测试覆盖切换与缩略图隔离、重启零渲染、编辑/源文件失效、局部复用、LRU 和损坏回退。初次测试发现 URL 元数据缓存使修改时间失效未触发，改为实时文件属性后重测通过。日志 `07-cache.log`、`07-cache-recheck.log`；4 个测试最终通过。
- 限制：为首次渲染增加一次轻量显示投影，以换取首个 HDR/SDR 切换也无需重跑开发流程；尚未测实体机耗电。内存预算指引擎预览缓存，不包含解码器、UI 当前图像和系统 GPU。提交标题含 IPAD-07；IPAD-08 依赖此缓存目录/结构。

## IPAD-08

- 变更：General / Photo library 设置显示预览磁盘大小、文件数、引擎预览内存，提供刷新和带确认的清理。清理先使待完成预览失效，等待当前照片的编辑加载完成，再删除 MobilePreviews 并释放引擎工作缓存；屏幕正在显示的图像保留，下次按需重建。
- 文件：MobileCacheSettings.swift、MobileTools.swift、MobileEngine.swift、MobileWorkspaceModel.swift、engine/UI tests。依赖 IPAD-07 (`461f7d5`)；无移植代码。
- 验证：`testClearCacheKeepsLibraryOriginalsEditsFoldersAndProfiles`、`testSettingsMeasuresAndClearsPreviewCache` 最终通过（2 项 / 0 失败），覆盖清理后磁盘/内存归零、照片字节/编辑/归类/配置/导出保留、再次请求重建，以及 UI 确认/计数/返回网格。早期 UI 断言受系统重复按钮节点与组合内容可访问性影响，修正定位并提供明确文件数无障碍值后通过。最终日志 `08-cache-settings-final.log`。
- 限制：内存行统计引擎预览缓存，并非整个应用占用；确认说明原片和编辑不被删除。回退时同步回退 UI/模型/引擎入口，磁盘缓存可由 IPAD-07 继续使用。提交标题含 IPAD-08。

## IPAD-11

- 变更：Lens profiles 列表可进入完整详情，显示相机、光圈、标定机身、创建日期、格式版本、标定帧数、备注、共享配置。按方向展示 Mac 同规则的测量覆盖矩形/中心点和 X/Y 移轴范围；展开帧可查看文件名、位置、传感器/像素尺寸、ISO、曝光时间、拍摄日期、机身方向、测量与渲染网格尺寸/通道/空间。
- 文件：MobileProfileDetails.swift、MobileTools.swift、MobileEngine.swift、engine/UI tests。来源：参考当前 Mac LCCProfileLibraryView 覆盖图与说明，复用共享 LCCProfileStore/Codec/校验；不修改配置原始数据。
- 验证：`testLensProfileDetailsPreserveCaptureMetadataAndCoverage`、`testLensProfileOpensMetadataCoverageAndCaptureDetails` 均通过（2 项 / 0 失败），内置配置的元数据/覆盖区域校验、设置进入详情和展开帧。日志 `11-lens-details.log`，UI 保留详情截图。
- 限制：仅显示文件实际包含的可选元数据，缺失机身显示 Not recorded；不同配置的备注/文件名作为用户数据不自动翻译。无新增依赖；IPAD-10 将翻译新增界面。提交标题含 IPAD-11；回退视图与导航入口一起进行。

## IPAD-10

- 变更：iPad 增加简体中文，覆盖浏览/编辑/全景/LCC/导出/文件夹/直方图/缓存/镜头详情及本地状态错误。复用共享 L10n，新增 273 条中英文资源；当前移动代码引用的 348 个 key 均有双语文本且插值/格式占位符一致。日期等控件继承所选 locale。
- 设置：General → Language 提供 English / 简体中文，沿用 Mac 的进程内固定语言策略，明确提示重启后生效。系统选择器/系统错误随 iPadOS 语言；文件名、相机型号、用户备注不自动翻译。原有偏好键、文件路径和控件 ID 保留。
- 文件：PhotonsMobile 界面/本地状态字符串、共享 en/zh-Hans.json、Info.plist、UI 测试；新增资源不修改 Mac 既有词条。依赖本轮其他界面改动，尤其 IPAD-11。
- 验证：中文网格/直方图/自定义倍率/设置/镜头详情 UI 通过；英文缩放回归通过；实际语言偏好切换、退出重开中文、再切回英文并重开通过。日志 `10-chinese-ui.log`、`10-language-preference.log`、最终 `10-chinese-final.log`。静态校验所有 key/参数匹配，既有技术标识不变。
- 截图：改用 XCUIScreen 捕获完整横屏，避免模拟器 app.screenshot 的方向裁切。检查中文网格、缓存设置和镜头详情布局；发现共享 Light 词条语义不适合明暗面板，改为独立词条。最终截图位于 `local/build-logs/ipad-content-update/chinese-final-screenshots/`，镜头日期显示为中文。
- 限制：中文为简体；不翻译用户数据。物理设备可访问性字号/系统面板体验留待 beta；回退时同时移除界面调用和本轮新增资源，勿改写原有共享词条。提交标题含 IPAD-10。

## 提交索引与更新日志

| 编号 | Commit | 用户可见结果 |
|---|---|---|
| IPAD-01 | `07bacd0` | Close 丢弃临时全景，恢复原照片/网格；已确认导出继续 |
| IPAD-02 | `1ad56ac` | 关闭所选照片侧栏同时清除勾选和高亮 |
| IPAD-03 | `e886f58` | 网格双击打开大图，Fit 下左右滑动翻页 |
| IPAD-04 | `1eecec9` | 右上倍率栏、Fit 双击切换、局部像素重新渲染 |
| IPAD-05 | `69ea7e5` | 单图片库中的文件夹管理、移动、导入与筛选 |
| IPAD-06 | `999b511` | Mac 规则的详细直方图与触摸读数 |
| IPAD-07 | `461f7d5` | 配对 HDR/SDR 缓存、持久化与独立内存预算 |
| IPAD-08 | `bace29a` | 设置内查看缓存大小并清理 |
| IPAD-11 | `dcec753` | 查看镜头配置、方向覆盖和标定帧细节 |
| IPAD-10 | `f2176a1` | 简体中文界面、语言偏好与重启切换 |

每项实现、验证、限制和回退说明见对应章节及 commit 正文。使用 `git show <commit>` 可独立审查。上述 10 项统一进入 iPad 内容更新 PR。没有 squash、强推、删除旧分支或改写 PR 2。

## IPAD-09-QA — 综合验收与文档

- 2026-11-17，iPad Pro 13-inch (M5) / iOS 27.2 模拟器，全量引擎 20 项：19 通过、1 跳过、0 失败。`testOptionalBostonSixFrameTone` 使用本地六张 100 MP RAW 实际通过（87.591 秒），输出画布 21330 × 20255，调整前后 HDR headroom 2.7793 → 1.8125。
- 跳过项为 `testOptionalRealRAWWorkflow`，其对应 ValidationInputs 顶层 RAW fixture 未提供；六张测试是另一独立 fixture，不能将两者混为同一覆盖。
- 全量 UI 10 项初次为 9 通过、1 失败：旧完整流程在单击后即时断言侧栏消失，没有等待新增双击识别的失败窗口。仅将该断言改为等待实际关闭，`testGridInspectorSelectionAndPanoramaWorkflow` 复测通过（74.532 秒），包含移轴、透视、曝光/高光、机身方向、拖动/Revert、LCC 裁剪开关、完整分辨率导出、自动回导和设置。应用代码未因这个测试调整改变。
- 结果：本轮 30 个不同测试最终覆盖 **29 通过、1 明确跳过**。不把初次失败的全量命令记成成功；证据分别为 `09-full-suite.log`、`09-workflow-recheck.log`。
- 分发归档：0.1.0 (3) Release archive 成功，应用源码 `f2176a1599771306f76eb71837a57c8ab25dd812`，构建时应用文件无未提交修改，只有文档在整理。严格签名、仅 iPad、en/zh-Hans、App Store profile、dSYM UUID、隐私/许可/标定资源及私有 RAW 排除均通过。源码图标 1024×1024、无 alpha。归档验证 JSON：`09-archive-validation.json`。
- 本节记录当时的归档验收，后续上传和最终 build 4 分发见发布记录。实体 iPad 的 HDR、可用内存、持续温度/耗电尚待 beta 验证。
- 本项修改完整流程的手势等待断言、更新 `docs/ipad-preview.md` 与本追踪记录；不修改应用逻辑。依赖 IPAD-01…08、10、11。提交标题含 IPAD-09-QA。

## IPAD-09-MAIN — 同步新上游 main

- 来源：上游 `737f92d54056bf4f77fe93daa1c366e6bae639a1`，包含解码自动版本、去雾、透视、Mac 直方图与 NLMF 依赖更新。以普通 merge 保留新 main 和全部独立 iPad 提交。PR： https://github.com/chemharuka/photons/pull/3 。
- 冲突只涉及 en/zh-Hans JSON 尾部；按三方逐 key 合并并验证无同 key 不同值冲突，保留双方全部翻译。iPad Package.resolved 重新解析，GRDB 保持 7.11.1，新增 NonlocalMatchFilter 1.0.0 / `52a6e4f4edd48f6b9b34882327e3a838a0f69d54`，与上游锁定一致。
- 验证：合并后的 Debug app 与测试目标已编译成功，正在运行完整引擎/UI 回归；首批 Close、HDR、直方图、导入持久化、LCC、镜头详情测试已通过。最初固定依赖解析因新 package 缺少 iPad pin 而失败，重新解析后构建通过。最终完整结果在后续验收记录中追加，不将运行中测试记为通过。日志 `09-main-resolve.log`、`09-main-full-suite.log`。
- build 3 已上传，但不加入测试组；它使用旧 main。最终发布改为合并后 build 4。需要追加预览缓存算法版本失效修正，并同步最新 Mac 直方图绘制规则，各自单独提交。
- 依赖：IPAD-09-BASE (`5644147`)；无历史改写。回退此 merge 需要明确第一父提交并评估依赖新引擎的后续修正，不自动删除分支。

## IPAD-07-UPGRADE — 引擎升级时刷新预览缓存

- 新 main 的 RAW/去雾算法改变了同参数对应的像素。磁盘配对预览键现在同时包含共享 `DecodeRecipe.current` 和 `StageAlgorithmVersion.graphVersion`，以后引擎版本变化自动失效，不需要用户手工清缓存。原片/编辑不变；旧预览由既有大小预算淘汰。
- 文件：MobileEngine.swift、IPadEngineTests.swift。依赖 IPAD-07、IPAD-09-MAIN (`835e1dd`)，沿用共享版本标识，无移植实现。
- 验证：iPad Pro 11-inch (M5) / iOS 27.2，`testLegacyPreviewIsRegeneratedAfterEngineUpgrade` 与原配对缓存切换/重启/失效测试均通过（2 项 / 0 失败），日志 `09-cache-generation.log`。升级测试将有效旧记录放在真实旧版键名下，验证重渲染一次、后续重开/HDR 切换复用新缓存。
- 限制：算法维护者仍需按共享引擎既有契约更新版本标识；这不是源文件内容 hash。回退会恢复旧键规则，可能命中旧像素，不宜单独回退并保留新引擎。

## IPAD-06-MAIN — 对齐最新 Mac 直方图规则

- 来源：`737f92d` 的 HistogramCardView / HistogramPlot，406c/413 修正。iPad 同步采用固定 SDR/HDR 各半宽轴；SDR 模式显示上限位于白点。每个物理像素条取完整覆盖区间的曲线最大值，避免单 bin 窄峰高度随位置漂移。
- 用 sRGB 通道存在位构造白/黄/青/品红/R/G/B 填充，普通合成替代在未知 P3/EDR 空间 plusLighter 相加，避免中性重叠偏粉。用户的 HDR/SDR 显示选项与实际 bins 保持独立。
- 文件：MobileHistogram.swift、IPadEngineTests.swift；依赖 IPAD-06 与 main merge `835e1dd`。
- 验证：轴/显示削顶、叠加色带/窄峰覆盖两项引擎测试，英文触摸直方图及中文浏览/设置/镜头详情两项 UI 测试通过，4 项 / 0 失败；iPad Pro 11-inch M5 / iOS27.2，`09-histogram-main.log`。检查完整中文网格/直方图截图，白色重叠与坐标显示正确，截图在 `main-chinese-screenshots/`。
- 限制：实体 EDR 面板仍待 beta；回退视图与对应测试可一起进行，不改库数据。

## IPAD-09-NOTICES — 同步新增共享依赖的分发说明

- 新 main 把 NonlocalMatchFilter 1.0.0 和模型资源加入 PhotonsExtensions，iPad 静态 notices 原先只列 GRDB，且宣称没有模型。更新 Apps/iPad/ThirdPartyNotices.txt 的依赖 pin 和资源范围，纳入锁定 Swift 包 LICENSE 以及仓库模型 MIT notice 的完整原文。未新增移动端 AI 功能入口。
- 来源：上游 `737f92d` THIRD_PARTY_NOTICES.md 和锁定 `52a6e4f` 包 LICENSE。依赖 IPAD-09-MAIN；文档/打包资源修改，不改变运行逻辑。
- 验证：脚本确认两份许可原文逐字包含，过时无模型说明已移除。后续 build 4 归档检查会验证资源实际被打包；不为文案复制增加同构测试。回退必须同时考虑新增包与模型是否仍在发布包中。

## 最终综合验收 — 最新 main 上的结果

- `09-main-full-suite.log`：iPad Pro 13-inch M5 / iOS27.2，完整引擎 20 项，19 通过、1 缺少可选顶层 RAW fixture 跳过；UI 10 项全部通过，命令结果 TEST SUCCEEDED。六张 100 MP Boston RAW 流程通过（85.956 秒），没有被跳过。
- 后续独立修正：`09-cache-generation.log` 2/2 通过；`09-histogram-main.log` 4/4 通过（包括最新中文浏览/设置/镜头详情）。去重后共 32 项：**31 通过、1 明确跳过**。完整测试在 merge 版本运行，之后仅缓存版本键与直方图有行为修改，并以相应定向回归验证。
- 双语检查：移动界面引用 348 个 key，中英文都有值且格式参数一致；合并保留上游每种语言全部 1460 个词条及其值，最终各 1736 个词条。中文布局还在 11-inch 模拟器检查。
- Release build 4 从应用源码 `dfebb54e0db4c3de9630b9f34212afeada31fb96` 归档成功；112.5 MiB 未压缩 app。严格签名、App Store profile、iPad-only、en/zh-Hans、dSYM UUID、隐私声明、许可、43XL 标定、NLMF 模型与私有 RAW 排除验证通过。上游新增共享模型占 64,386,304 字节；移动端尚无该降噪入口。验证 JSON 为 `09-archive-4-validation.json`。
- 实体机 HDR 表现、长时间内存/温度和实际耗电不在模拟器证明范围，列为 Developer Beta 验证项。

## 集成与交付提交索引

| 编号 | Commit | 用途 |
|---|---|---|
| IPAD-09-QA | `9951100` | 综合验收、旧单击测试等待、说明文档 |
| IPAD-09-BASE | `5644147` | 核对应用树等价后记录原 PR 2 祖先；树内容不变 |
| IPAD-09-MAIN | `835e1dd` | 合入上游 737f92d，翻译合并、iPad 依赖 pin |
| IPAD-07-UPGRADE | `074d036` | 缓存随共享解码/渲染算法升级失效 |
| IPAD-06-MAIN | `be73c42` | 最新 Mac 固定直方图轴、叠加色与窄峰绘制 |
| IPAD-09-NOTICES | `dfebb54` | 新增共享模型/包的完整分发许可说明 |

IPAD-09-BASE 的依据：`git diff a5cf5eb 1db8fe3` 只有 AGENTS.md 和 5 份文档，应用/测试/构建输入等价；合并 `a5cf5eb` 的提交树与第一父提交完全相同。原 PR 2 保留并仍应先合并，以便 PR 3 自动排除前置功能。完整来源、验证和回退说明在 `5644147` 正文中。

## IPAD-09-RELEASE — PR 与 Developer Beta 完成

- [PR 3](https://github.com/chemharuka/photons/pull/3) 已创建并更新详细日志；分支 `codex/ipad-content-update`，最新应用源码 `dfebb54`，上游 main `737f92d` 已合入。GitHub 显示可合并，未配置状态检查；原 PR 2 仍开放且作为前置合并。
- 0.1.0 (4) 上传成功，Apple 处理完成，2384 字符测试说明已保存。通过 Codex 内置浏览器加入现有 Developer Beta，00:35 EST 验证 **Testing / 4 testers / 3 builds**。build 3 保留未分发；外部 build 1 仍 Waiting for Review。没有新增测试者、发送邀请或改动 Mac 分发。
- 本项仅更新发布与验收文档，依赖所有功能/集成提交，未修改已归档应用源码。所有独立 commit 保留，原 Photons 2 工作区在 `a5cf5eb` 且干净，旧分支未删除或改写。
- 完整构建来源、签名/资源验证、hash、服务器状态、测试说明及回退限制见 [build 4 发布记录](developer-beta-ipad-4-2026-11-17.md)。本提交标题含 `IPAD-09-RELEASE`，可用 `git log --grep=IPAD-09-RELEASE` 定位。
