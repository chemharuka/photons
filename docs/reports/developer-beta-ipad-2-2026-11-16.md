# TF-IPAD-02 — iPad Developer Beta 0.1.0 (2)

## 需求、结果和范围

- 需求：让现有 Developer Beta 使用最新 iPad 构建，保留正在进行的外部审核。
- 完成时间：2026-11-16 23:15 EST。
- App：Photons Studio Preview，`com.leoaokma.photons.ipad-preview`，Apple ID `6835653664`。
- 构建：`0.1.0 (2)`，Apple build ID `8e8ca148-9085-49c1-b923-632c2f78c923`。
- 结果：Apple 处理完成；Codex 内置浏览器保存英文 What to Test 并仅加入现有 **Developer Beta** 内部组。组页面显示 **Testing / 3 Testers / 2 Builds**，旧 build 1 保留。
- 外部 build `0.1.0 (1)` 仍为 **Waiting for Review**；没有撤回、替换或再次提交审核，没有增删测试者，也没有发送独立邀请。
- 本次 Git 改动仅为本报告和 `docs/ipad-testflight.md`，包含新构建说明、复现命令和 Full resolution 文档更新。版本通过 Xcode 参数指定，没有修改应用源码或 PR 2。
- 此项独立提交标题含 `TF-IPAD-02`；可用 `git log --all --grep=TF-IPAD-02` 查询实际 commit。Mac 独立发布记录为 `66176fb`（TF-MAC-06），不是本构建的源码依赖。

## 源码与依赖

- 构建时干净源码：`e5364464338660305b25ff6a6d705131316b4789`，分支 `codex/main-panorama-controls`。
- 基于 upstream main `b93ae1f`，包含共享全景色调 `d0717e7`、Mac 控件 `e9f7567`、iPad 控件和测试 `0eb3ec9`、提交规则和整合文档。
- 应用代码与 [PR 2](https://github.com/chemharuka/photons/pull/2) 的 `a5cf5eb68ea688d73ad0c773e81e59bdf5431a32` 一致；不代表 PR 2 已合并。功能和移植详情见 [main 整合记录](main-panorama-integration-2026-11-16.md)。
- 使用已有 Apple Distribution 证书、匹配的 App Store profile 和已登录 Xcode。签名资料、账号联系信息及导出选项保留在 Git 外。

## 本次验证与上传

1. `xcodebuild archive`：`Apps/iPad/PhotonsIPad.xcodeproj`、scheme `Photons iPad Preview`、Release、generic iOS、手动分发签名、`CURRENT_PROJECT_VERSION=2`、`MARKETING_VERSION=0.1.0`、`PHOTONS_INCLUDE_BOSTON_SAMPLES=NO`；结果 **ARCHIVE SUCCEEDED**。不自动解析或更新包依赖。
2. 验证 bundle ID、版本/build、`UIDeviceFamily=[2]`，确认仅 iPad；严格代码签名通过，分发 profile 为 `get-task-allow=false` 且没有设备列表。
3. 可执行文件与 dSYM UUID 均为 `998E272E-9120-3154-A102-AFF17165A488`。
4. 43XL LCC、隐私清单和第三方许可存在；BostonSamples 目录为空，没有私有 `.3FR` 或其他样本文件。
5. 通过 `INFOPLIST_KEY_PhotonsGitRevision` 传入的自定义值未写入最终 Info.plist，因此源码追踪记录在本报告和本地验证 JSON；不宣称 app 内含该键。初次本地验证对该键及空目录的预期过严，调整为以上实际条件后验证通过；未改动已签名 archive。
6. `.build/ipad-testflight/Photons-iPad-0.1.0-2.xcarchive` 使用本地 `ExportOptions.plist` 执行 `xcodebuild -exportArchive ... -allowProvisioningUpdates`：23:09:40 EST 返回 **Upload succeeded / EXPORT SUCCEEDED**。
7. 内置浏览器核对 Apple 处理完成、测试说明保存、只有 Developer Beta 组，最终组内 **0.1.0 (2) / Testing**。

## 测试说明

已保存英文说明，要求测试全景 Exposure、HDR highlight brightness、Reset，预览/直方图/导出一致性，中心及偏移帧拖动、Revert、对齐/导出状态、四方向与 LCC 裁剪；比较 HDR/SDR 与重新导出的 DNG 接缝，检查 Full resolution 和 2048/4096/6000 px 导出、元数据、自动回导和 Files 分享。

## 证据、限制和回退

- 本机忽略目录 `local/build-logs/developer-beta-refresh/`：`ipad-archive.log`、`ipad-upload.log`、`ipad-validation.json`、`ipad-what-to-test.txt`、`ipad-developer-beta-2.png`。
- [Developer Beta 组](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835653664/testflight/groups/bf208e19-5d77-4e4b-9a23-65e7a81ec2db/builds)。网页状态为记录时间的快照。
- 本次分发没有重跑全部功能测试。同源码之前的色调预览/直方图/导出 engine 测试及 UI 流程测试通过，详见整合报告。实体 iPad 的性能、内存和 HDR 显示仍需 beta 验证；未确认测试者已安装新 build。
- 回退本报告的 Git commit 不会撤销 TestFlight 分发。若需停止 build 2，应另行从内部组移除或停止测试；旧 build 1 与原分支保留。本次未执行这些回退操作。
