# Photons Studio：macOS TestFlight 分发

当前工程使用 SwiftPM，可以通过签名的 `.pkg` 上传 App Store Connect，暂时不需要迁移到 Xcode 工程。准备脚本位于 `scripts/testflight.py`，所有构建、签名产物及描述文件副本均写入被 Git 忽略的 `.build/testflight/`。

默认标识为 `com.leoaokma.photons`，显示名称为 Photons Studio，版本为 `0.3.0 (5)`。创建 App Store Connect 记录前，应确认名称和标识属于自己的账号。之后每次上传使用新的 build number。

## 当前状态

- 本机已安装 Xcode 27.2，Apple Developer Program 已激活，应用及安装包分发证书已创建且通过本机信任校验。显式 App ID `com.leoaokma.photons`、App Store Connect 应用记录及 Mac App Store provisioning profile 均已创建，证书／描述文件匹配检查通过。
- 应用首次启动默认英语，设置中的默认选项保持一致；用户保存的中文选择会保留。App Store Connect 的主要语言为 English (U.S.)。
- `0.3.0 (5)` 已包含功能分支 `86d58dc` 的更新，以及英语默认语言修正；上传包的源码标记为 `17dc9cd`。release 主程序与 helper 编译成功，10 项签名门禁测试和沙盒诊断通过。沙盒诊断覆盖书签往返、GPU、降噪、HDR 及全景任务回导；真实外部目录的首次授权仍需交互验证。
- 2026-11-16 已通过 Xcode 使用登录账号上传，Apple 返回 **Upload succeeded**。App Store Connect 应用记录为 `6835570029`；服务器处理和 Beta App Review 是后续独立状态，上传成功不代表已允许外部测试。
- 同日服务器处理完成，内部组 `Developer Beta` 中的构建状态为 **Ready to Test**，图标已显示；外部组 `Private Beta` 已提交 Beta App Review，状态为 **Waiting for Review**。英文测试说明及审核联系信息已保存。两个组尚未添加测试者，未发送邀请；外部构建自动通知关闭。
- `prepare` 生成的是**本机临时签名的沙盒测试应用**，不会上传，也不是可交给 TestFlight 的正式分发包。
- `package` 只有在证书、私钥、Team、显式 App ID、描述文件及有效期检查通过后才创建签名 `.pkg`。本轮 Apple 上传验证已通过；后续构建仍需实际运行服务器验证，不能用本地签名校验代替。
- 首轮构建只支持 Apple Silicon / macOS 14+。Intel 版本尚未编译和测试。
- 本轮 beta 不启用订阅限制或应用内邀请码。使用 TestFlight 邮箱定向邀请，不启用公开链接；构建自身的有效期是 90 天。

## 开通后的一次性配置

1. 使用开启双重认证的 Apple Account 加入 [Apple Developer Program](https://developer.apple.com/programs/enroll/)。普通会员为每年 99 美元或当地币种价格。个人会员在商店展示个人法定姓名，组织会员展示组织法定名称。[Apple 入会说明](https://developer.apple.com/help/account/membership/program-enrollment)
2. 在 Xcode → Settings → Apple Accounts 登录，确认付费 Team 出现。密码、验证码及私钥不应进入聊天、仓库或脚本。
3. 在 Certificates, Identifiers & Profiles 注册 macOS 显式 App ID `com.leoaokma.photons`；在 App Store Connect 新建 macOS App，关联同一 Bundle ID。若被占用，先设置 `PHOTONS_BUNDLE_ID` 并重新 prepare。
4. 创建含私钥的 Mac App Store 应用分发证书（Apple Distribution 或 3rd Party Mac Developer Application）及 **3rd Party Mac Developer Installer** 证书。Developer ID 是商店外分发证书，不用于这里。
5. 为上述 App ID 和应用分发证书创建 **Mac App Store Connect** provisioning profile，并下载到仓库外。TestFlight 的 macOS 应用必须含该 profile 和匹配的 application identifier。[Apple 描述文件说明](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/)

## 准备与签名

在仓库根目录运行：

```sh
python3 scripts/testflight.py prepare --version 0.3.0 --build 5
```

这会构建主程序与三个独立 helper，生成独立的 `.build/testflight/Photons Studio.app`，加入隐私清单和第三方许可／源码，执行沙盒诊断并保存 dSYM。不会替换现有的 Photons Sandbox.app。仅在刚刚构建过相同源码的 release 产品时，才使用 `--skip-build`。

`PHOTONS_ANSEL_MODEL` 可以指定打包时的本地模型路径。沙盒诊断会移除这个环境变量并读取包内模型，避免误用没有授权的构建机路径。

证书安装后，以下变量填自己的值；不要把带个人信息的配置提交到 Git：

```sh
export PHOTONS_APP_SIGN_IDENTITY='Apple Distribution: Your Legal Name (TEAMID)'
export PHOTONS_INSTALLER_SIGN_IDENTITY='3rd Party Mac Developer Installer: Your Legal Name (TEAMID)'
export PHOTONS_PROVISIONING_PROFILE="$HOME/Downloads/Photons_AppStore.provisionprofile"
python3 scripts/testflight.py preflight
python3 scripts/testflight.py package
```

签名从 helper 和资源 bundle 向主 app 进行；helper 只携带沙盒继承权限，不复制主 app 的 application identifier。GPL 对应源码记录和二进制哈希会在重新签名后更新。结果为 `.build/testflight/Photons-Studio.pkg`，可以交给 [Transporter](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)。本机临时签名应用不能直接上传。

App Store 分发时，Xcode 和 Apple 还会重新签名二进制。此版本把 GPL 来源说明中的可执行文件哈希明确标为**打包时记录**，并移除会因重新签名失效的 helper 全文件 `.sha256`；安装后的代码完整性由平台签名校验。模型和源码压缩包的校验值保留。普通本地构建的校验文件不受影响。

应用图标由 Icon Composer 源文件编译进 `Assets.car`，包含 1024×1024 图标，并附带 `.icns`。App Store Connect 的应用图标随构建提交；首次上传完成前后台可能仍显示占位图。

## 上传与邀请

本轮使用已登录的 Xcode 完成上传，没有创建 App Store Connect API key。对应 `.xcarchive`、导出选项和符号保存在本机 `.build/testflight/`。`xcodebuild -exportArchive` 使用 `method=app-store-connect`、`destination=upload`、显式描述文件和手动分发签名；关闭自动修改 build number，保留符号上传。不要把包含个人签名配置的选项文件提交到仓库。

也可以用 Transporter 登录并上传脚本生成的 `.pkg`，或使用 App Store Connect API key：

```sh
# 私钥保存在 ~/.appstoreconnect/private_keys/AuthKey_KEYID.p8，不能放进仓库。
export PHOTONS_ASC_KEY_ID='KEYID'
export PHOTONS_ASC_ISSUER_ID='ISSUER-UUID'
python3 scripts/testflight.py validate
python3 scripts/testflight.py upload
```

另一种方式是设置 `PHOTONS_APPLE_ID` 和 `PHOTONS_PASSWORD_KEYCHAIN_ITEM`，后者仅为已保存应用专用密码的 Keychain 项目名称，脚本以 `@keychain:` 引用它。脚本不会打印或读取明文密码。命令语法按本机 Xcode 27.2 的 `altool --help` 编写；`upload` 会先验证再上传并等待 Apple 处理。

构建处理完成后，在 App Store Connect → TestFlight 创建一个内部测试组，先加入开发团队成员和该构建。内部测试者必须是有相应访问权限的 App Store Connect 用户，最多 100 人。给普通体验用户使用外部测试组，不必给他们后台账号；首个外部构建需 Beta App Review，通过后按邮箱定向邀请。本轮不启用公开链接；邀请前由开发者指定收件人，脚本不会自动邀请任何人。[Apple TestFlight 说明](https://developer.apple.com/testflight/)

外部测试前填好 Beta App Description、What to Test、反馈邮箱和审核联系人；这些真实联系信息应在 App Store Connect 中由负责人填写。首轮建议测试：首次文件夹授权与重启后的访问、HDR/SDR 映射、全景任务取消及完成回导、各导出格式、LCC 文件识别、语言切换和照片库管理。

中英文测试说明和审核备注草稿见 [testflight-beta-notes.md](testflight-beta-notes.md)。

## 本轮分发边界

- 当前应用不上传照片，也没有自有遥测或跟踪。隐私清单描述本地偏好、文件元数据及交互计时；加入账号、反馈上传、订阅或联网服务后，需要重新核对清单和 App Store Connect 隐私答案。
- `ITSAppUsesNonExemptEncryption=false` 对应当前使用哈希进行本地缓存／文件完整性检查的实现。未来加入其他密码功能时重新评估。
- 独立 GPL helper 随包带许可证和对应源码；这不等于 Apple 分发条款与第三方许可已得到法律确认，也不保证审核通过。现有第三方声明中仍要求确认降噪模型权重的分发条款，正式外部分发时应保留相应授权依据。LCC 仍是可查看、可分享的用户文件。
- 完整验收的失败项需见上游 PR 的最新验证记录。本地沙盒冒烟测试通过，不等于所有功能和所有机型已验证，也不等于已获得 TestFlight 签名。
