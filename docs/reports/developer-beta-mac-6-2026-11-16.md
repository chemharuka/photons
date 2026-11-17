# TF-MAC-06 — Mac Developer Beta 0.3.0 (6)

## 需求、结果和范围

- 需求：让现有 Developer Beta 使用最新 Mac 构建，保留正在进行的外部审核。
- 完成时间：2026-11-16 23:13 EST。
- App：Photons Studio，`com.leoaokma.photons`，Apple ID `6835570029`。
- 构建：`0.3.0 (6)`，Apple build ID `93f54a8e-7d1a-4c37-83a5-3a3397a7e1da`。
- 结果：Apple 处理完成；Codex 内置浏览器保存英文 What to Test 并加入现有内部组 **Developer Beta**。组页面显示 **Testing / 3 Testers / 2 Builds**。组内旧 build 5 保留，新 build 6 只有该内部组。
- 外部 build `0.3.0 (5)` 仍为 **In Review**；没有撤回、替换或再次提交外部审核，没有增删测试者，也没有发送独立邀请。
- 本次 Git 改动仅为本报告和 `docs/testflight.md`；版本通过现有 prepare 参数指定，没有修改应用源码、PR 2 或分支历史。
- 此项独立提交标题含 `TF-MAC-06`；可用 `git log --all --grep=TF-MAC-06` 查询实际 commit。

## 源码与依赖

- 构建时干净源码：`e5364464338660305b25ff6a6d705131316b4789`，分支 `codex/main-panorama-controls`。
- 基于 upstream main `b93ae1f`，并包含共享全景色调 `d0717e7`、Mac 控件 `e9f7567`、iPad 控件 `0eb3ec9`、提交规则和整合文档。
- 应用代码与 [PR 2](https://github.com/chemharuka/photons/pull/2) 的 `a5cf5eb68ea688d73ad0c773e81e59bdf5431a32` 一致；这不代表 PR 2 已被合并。详细移植和功能验证见 [main 整合记录](main-panorama-integration-2026-11-16.md)。
- 依赖已有分发证书、安装包证书、匹配的 App Store provisioning profile 和已登录 Xcode。签名资料、账号联系信息及导出选项不进入 Git。

## 本次验证与上传

1. `python3 -m unittest discover -s scripts/tests -p test_testflight.py`：10 项通过。
2. `python3 scripts/testflight.py prepare --version 0.3.0 --build 6 --skip-build`：成功。复用本次会话刚从同一源码编译的 Release 产品；之后没有应用代码改动。
3. `python3 scripts/testflight.py package`：使用本机分发签名配置成功；严格应用签名、profile 匹配及安装包签名校验通过。
4. 沙盒诊断：sandbox=true；bookmarkRoundTrip=true；Apple M5 Pro GPU；降噪协议 2，输出 16384 bytes；HDR 协议 1；后台全景 640×320，成功回导 1 张，metadataRoundTrip=true。
5. 验证 bundle ID、`0.3.0 (6)` 和源码标记；可执行文件与 dSYM UUID 均为 `C757B1EE-36BE-3841-BDCB-82D2E2AD9D42`。
6. 以 `.build/testflight/Photons-Studio-0.3.0-6.xcarchive` 执行 `xcodebuild -exportArchive`，使用本地 `XcodeUploadOptions.plist` 和 `-allowProvisioningUpdates`：23:08:14 EST 返回 **Upload succeeded / EXPORT SUCCEEDED**。Apple 页面显示上传时间 23:09。
7. 内置浏览器核对服务器处理、保存测试说明、仅选择 Developer Beta，然后核对组内 **0.3.0 (6) / Testing**。

本次打包的 `.build/testflight/Photons-Studio.pkg` SHA-256：
`6e3e842b1f3992cdd1f8e35e8a04b2a77e6e964baa44ecc6dde8b9c4c04ff5d1`。
该哈希是本地打包产物的校验值；Apple 可能重新签名分发文件。

## 测试说明

已保存英文说明，要求测试全景 Exposure、HDR highlight brightness、Reset，预览与 HEIC/TIFF/lossless linear DNG 导出一致性、后台导出与元数据、重新导出的 DNG 接缝、LCC 裁剪与拖动，以及常规导入编辑导出。旧 DNG 需要重新导出才能包含接缝修复。

## 证据、限制和回退

- 本机忽略目录 `local/build-logs/developer-beta-refresh/`：`mac-prepare.log`、`mac-package.log`、`mac-upload.log`、`mac-validation.json`、`mac-what-to-test.txt`、`mac-developer-beta-6.png`。
- [Developer Beta 组](https://appstoreconnect.apple.com/teams/a2137f83-9ab5-439c-b535-cc9bbff7703c/apps/6835570029/testflight/groups/80db453c-65e8-44c3-a63e-7a1e5f461aa9/builds)。网页状态为记录时间的快照。
- 本次没有重跑整个历史功能测试集；先前同源码功能验证见整合报告。真实外部目录首次授权仍需交互测试；未验证 Intel 或所有显示器。未确认三位测试者已安装新 build。
- 回退本报告的 Git commit 不会撤销 TestFlight 分发。若需停止 build 6，应另行从内部组移除或停止测试；旧 build 5 和原分支均保留。本次未执行这些回退操作。
