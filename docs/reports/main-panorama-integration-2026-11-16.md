# 最新 main 与全景亮度功能整合记录

日期：2026-11-16（America/New_York）。

## 基线与已有 PR

- 新工作分支：`codex/main-panorama-controls`。
- 上游基线：`b93ae1f16a0ed568f701630d9c130414e8c54698`。
- 移植来源：`a5cf5eb68ea688d73ad0c773e81e59bdf5431a32`。
- [PR #2](https://github.com/chemharuka/photons/pull/2) 已提交同一个源提交，目标为上游 `main`。本次核对时为 OPEN、MERGEABLE、CLEAN，没有 review 或修改评论，也没有自动 CI 检查结果。
- PR2 已完整包含此项功能，无需再为它修改代码、重写已发布提交或重复创建 PR。本地拆分提交没有推送到 PR2 的 `codex/lcc-profiles` 源分支。
- 原个人开发分支 `codex/ipad-development-preview` 保持在 `a5cf5eb`。本地新分支的应用源代码、测试和配置与该源提交一致；额外增加开发规则及本记录。

## 逐项实现信息

### PAN-TONE-01 — 共享曝光与高光处理

- Commit：`d0717e7197dc263008631a4b946aeace2633e1ea`。
- 需求：保留前景曝光，同时控制全景中的 HDR 高光；预览与输出使用一致参数。
- 修改前：LCC 高光保护按最亮区域的分位数选择全局曝光，可能使整幅图像变暗。
- 修改后：场景线性曝光与保色相的局部高光压缩共用处理路径；缓存调整不重复解码、配准或求解 LCC。导出快照和接片元数据保留参数，旧快照缺少参数时保持中性。
- 文件：`Sources/PhotonsPanorama/PanoramaTone.swift`、`PanoramaEngine.swift`、`PanoramaModel.swift`、`PanoramaManifest.swift`、`PanoramaSnapshot.swift`，以及 `Tests/PhotonsPanoramaTests/PanoramaToneTests.swift`。
- 依赖：上游基线；后续 Mac 和 iPad 控件依赖本提交。
- 验证：`PanoramaToneTests` 3 项通过、1 项可选外部 RAW 测试跳过、0 项失败；Mac Release 构建和签名检查通过。
- 限制：本轮没有重复真实 Boston RAW 性能测试。回退本提交前应先回退依赖它的两个平台控件。

### PAN-TONE-02 — Mac 全景亮度控件

- Commit：`e9f7567a30f7cc223e3a0d0fd9b386924129a76d`。
- 需求：在 Mac 全景预览下方提供曝光、高光亮度和重置。
- 行为：曝光 -4 至 +4 EV，高光上限为 SDR 白点之上 0 至 4 档；松开滑块后更新缓存预览，参数尚未应用时禁止导出。旧 LCC 面板的重复控件统一到全景亮度区域。
- 文件：`Sources/PhotonsUI/PanoramaWindowController.swift`，以及 `Sources/PhotonsLocalization/Resources/en.json`、`zh-Hans.json`。
- 依赖：PAN-TONE-01。
- 验证：Mac Release 构建、签名检查以及共享处理测试通过。
- 限制：本轮没有重新运行 Mac 控件交互测试或实体 HDR 屏幕检查。本提交可单独回退，不影响共享处理和 iPad 控件。

### PAN-TONE-03 — iPad 全景亮度控件

- Commit：`0eb3ec9bc140978f4a25abb8198694a4e82428fb`。
- 需求：iPad 使用相同的曝光、高光和重置操作，并保持预览、直方图与导出一致。
- 行为：100 ms 合并连续滑动，取消过时更新，保留配准和 LCC，参数未应用时禁止导出旧结果。
- 文件：`Sources/PhotonsMobile/MobileEngine.swift`、`MobilePanoramaWorkspace.swift`、`MobileWorkspaceModel.swift`，以及 `Apps/iPad/Tests/IPadEngineTests.swift`、`IPadUITests.swift`。
- 依赖：PAN-TONE-01。
- 验证：iPad 模拟器构建成功；`testPanoramaToneUpdatesPreviewHistogramAndExport` 和 `testGridInspectorSelectionAndPanoramaWorkflow` 共 2 项通过、0 项失败。
- 限制：本轮未重复可选 Boston RAW 场景，未验证实体 iPad 的 HDR 显示、内存、能耗和温度。本提交可单独回退，不影响共享处理和 Mac 控件。

### WORKFLOW-01 — 独立提交与完整追踪规则

- Commit：`5220055f20bb86eea3ddfc7b974a2e2f7793d5ee`。
- 需求：每个复合 implementation 中的独立改动完成后单独 commit，提供完整信息。
- 文件：根目录 `AGENTS.md`。
- 行为：先拆分验收项，再按依赖逐项实现、验证、记录、提交；提交正文和交付记录必须包含需求、行为、范围、依赖、验证、限制和来源。
- 验证：规则核对及 `git diff --cached --check` 通过。
- 限制：本地项目工作规则；不自动改写已经发布的 PR2 历史。

### DOC-TONE-01 — 说明与本次整合记录

- Commit：本记录所属提交，可通过 `git log -1 --format=fuller -- docs/reports/main-panorama-integration-2026-11-16.md` 查询。
- 需求：同步源提交的使用说明，并记录拆分、实际验证、PR2 状态和清理范围。
- 文件：`README.md`、`docs/ipad-preview.md`、`docs/reports/ipad-preview-validation.md`、本记录。
- 验证：说明与源提交对比、提交哈希核对及空白检查。
- 依赖：以上功能提交和 WORKFLOW-01；仅文档，无运行时行为改变。

## 本轮验证证据

测试运行在拆分之前的整合代码树。拆分只改变提交组织；随后通过 Git 对比确认应用代码与测试逐字一致。没有逐个 checkout 三个历史提交重新构建，也没有声称完整历史验收套件通过。

Mac：

```sh
swift build --package-path Vendor/hdrmerge-swift -c release --product hdrmerge-swift
swift build --package-path Vendor/ansel-denoise-swift -c release --product ansel-denoise-swift
make app
PHOTONS_LANGUAGE=zh-Hans swift test -c release --filter PanoramaToneTests
```

结果：Release 构建、Info.plist 和 codesign 检查通过；上述测试组 3 项通过、1 项外部素材测试跳过、0 项失败。日志在工作目录的 `local/build-logs/main-panorama-build.log` 和 `main-panorama-tests.log`。

iPad：使用 `xcodebuild`、`Photons iPad Preview` scheme、Debug 模拟器构建，关闭签名和 Boston 原片打包，选中上述引擎与界面两个测试。两项均通过；界面测试覆盖曝光、高光滑块、Reset、导出状态和既有全景操作。日志为 `local/build-logs/main-panorama-ipad-tests.log`，结果包为 `.build/main-panorama-ipad.xcresult`。

源提交附带的历史验证记录包含更广的 RAW 和设备构建检查；它们属于之前的验证，不是本轮重跑结果。

## 本地清理与保留

- 保留 `Photons 2` 原开发目录及 `codex/ipad-development-preview`，保留 `Photons Main` 新整合目录。
- 本地 `main` 更新为 `b93ae1f`，跟踪 `upstream/main`。
- 删除已被上游包含的本地临时分支：`codex/dev`、`codex/histogram-cache`、`codex/lcc-profiles`、`codex/shift-panorama`、`codex/testflight-distribution`。
- 旧 `codex/upstream-main`（`dd06bf4`）有独有历史，先完整归档后移除本地分支。
- 移除 shift-panorama 与 testflight 两个旧工作目录及其可重建缓存。已先保留发布产物、历史应用归档及截图。
- 顶层空 `Photons` 目录已移除，其 Git 元数据也已归档。
- 归档位于原开发目录的 `local/archives/main-integration-2026-11-16/`，包括已验证的 `branches.bundle`、`manifest.json`、TestFlight 产物和其他保留资料。
- 没有删除 GitHub 分支、修改 PR2、上传 TestFlight 或推送本地拆分提交。
