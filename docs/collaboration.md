# 协作与环境（人 + 多个 agent 共用一个仓库）

> 这份文档回答"下一个 session 怎么在这台机器上干活"，不回答"项目做什么"——后者在
> `docs/STATUS.md` 与 `docs/architecture-decisions.md`。
> 更新：2026-10-25 · 由主线 session 整理

## 环境（实测，别猜）

| 项 | 值 |
|---|---|
| 机器 | Apple **M1 Pro**，统一内存，arm64 |
| 系统 | macOS **27.2**（26B118） |
| 工具链 | Xcode **27.1**，Swift **6.4**，SDK macOS 27.0 |
| Metal 工具链 | **已安装**（cryptex 挂载的 MobileAsset）。`xcodebuild -downloadComponent MetalToolchain` 会网络失败，**不要重试** |
| 系统 python3 | **3.9**（`/usr/bin/python3`）——脚本必须 3.9 兼容 |
| 测试样本 | `~/Desktop/test/L1030433.dng`（Leica SL3 60MP）、`~/Desktop/US/_1274394.dng`（Sony 24MP）、`~/Desktop/US/DJI_air3_2250_D.dng` |

## 三条铁律

1. **`make verify` 绿了才提交。** 它是唯一判据：build + 单测 + L1 跨进程确定性 + L2 golden（+ M1 起 L3 图与 bench）。
2. **结论进 `docs/`，过程进 `local/`。** `local/*` 被 gitignore；任何必须活过 `git clone` 的东西不能只写在 `local/`。
3. **一个任务一个 worktree**，任何并行都在 worktree 里做，不在主工作区抢文件。

## 外部 worker：opencode CLI

本机已装（桌面 app 只是 Electron 壳，**不含** CLI）：

```
/opt/homebrew/bin/opencode            1.19.4
默认模型写在 ~/.config/opencode/opencode.jsonc → opencode-go/deepseek-v4.1-flash
凭据复用桌面 app：~/.local/share/opencode/auth.json（OpenAI / DeepSeek / OpenCode Go / SiliconFlow）
```

用法（非交互，不需要 pty）：

```bash
opencode run 'Follow the spec in docs/tasks/NNN.md exactly. Run its acceptance command before finishing.' \
  -f docs/tasks/NNN.md
```

| 模型 | 状态 |
|---|---|
| `opencode-go/deepseek-v4.1-flash` | ✓ 默认，便宜，够写胶水与测试 |
| `openai/gpt-5.2` | ✓ 贵但强，用于"一次要做对"的模块（Metal kernel、并发、色彩） |
| `opencode-go/kimi-k2.7-code` | ✓ go 计划内 |
| `opencode-go/gpt-5.6-luna` | ✗ **地区受限**（Country/region not supported） |
| `opencode/deepseek-v4.1-flash-free` | ✗ 实测无返回 |
| 裸跑不带 `--model` | 会落到 LM Studio（未启动 → ECONNREFUSED），已在配置里 disable |

规矩：**规格先写、验收命令写进规格**。没有验收命令的任务不许派给 worker——否则回来的是"看起来做完了"。

## Hermes 自己的 `delegate_task` 用在哪

适合：**并行调研**（7–10 路读源码、写报告、不碰代码）、跑验证、交叉审查。
不适合：**实现任务**。三个硬限制——① 默认**扁平等**（子 agent 不能再派孙 agent，可配到 2–3 层但要 orchestrator role）② 生命周期**绑在本 session**（`/new`、崩溃、压缩都会杀掉）③ 每个子 agent 的摘要**一定回到父上下文**，30 个任务就会把上下文撑爆。

所以：**调研走 delegate_task，写代码走 opencode worker，主线 session 只做架构与验收。**

## 跨 session 状态

用 skill `photons-session-bus`（`~/.hermes/skills/photons/photons-session-bus/`），数据在
`~/.hermes/bus/photons-0985eb/`。

```bash
S=~/.hermes/skills/photons/photons-session-bus/scripts/bus.py
eval "$($S register --purpose '<本 session 的活>')"   # 每 session 一次
$S sync                                               # 每个 session 第一步
$S claim --task NNN && … && $S post --kind done --summary '…' --ref docs/…
```

**共用终端时务必带不同的 `--purpose` 或 `--id`**：会话 id 走 env 变量，同终端的另一个 agent 会继承它，事件就记到别人名下（已踩过）。看到 `sync` 里的 `you` 不对，就重新 `register --id <名字>`。

## 一个功能一个 session：派单 → 实现 → 审阅 → 合入

> 2026-10-26 定稿。**铁律在仓库根 `AGENTS.md`**（每个 session 自动注入，含 opencode/codex）；
> 角色流程在 skill `photons-feature-dev`（实现）/ `photons-code-review`（审阅）/ `photons-session-bus`（总线）。

| 步 | 谁做 | 命令 / 产物 |
|---|---|---|
| 1 派单 | 用户或主线 | session 开场写明「用 skill `photons-feature-dev`，任务 NNN」；规格落 `docs/tasks/NNN-*.md`，**必须含可执行验收** |
| 2 实现 | 新 session（自己的 worktree） | `git worktree add --detach /tmp/photons-wt-<主题> main` + 播种 `.build` → 实现 → `make verify` 绿 → 本地 commit |
| 3 交接 | 实现 session | `bus.py --path … post --kind handoff`：**分支名 + 基线 commit + 规格路径 + 验收摘要** |
| 4 审阅 | 另一个 session | `photons-code-review`：基线对齐 → 自己重跑 verify（不采信摘录）→ 项目检查表 → 结论写 `docs/reviews/NNN-<主题>-review.md` |
| 5 合入 | 审阅 session | `git merge --no-ff` → 主线再跑一次 `make verify` → 删两个 worktree → bus `post --kind done` |

三条容易漏的：

- **worktree 里的 bus 命令必须带 `--path ~/Documents/GitHub/photons`**。slug 由 git root 绝对路径算出
  （`bus.py:59-63`），`/tmp/photons-wt-x` 会得到另一条**空总线**，`sync` 全空却不报错。
- 本机到 github 不通（`SSL_ERROR_SYSCALL`，2026-10-26 实测）：所谓"push 到本地"实际就是**本地 commit + 分支**；
  同机审阅不需要远端，直接 `git diff main...feat/x`。要留档再建本地裸仓库当第二 remote
  （`git init --bare ~/git/photons.git` + `git remote add local`），**不要动 origin**。
- **不要"复制一份项目代码"**：复制出来的目录是一条新总线，还丢 `.build/checkouts`（GRDB 的 `SQLiteCustom/src`
  子模块要重下）。要用 worktree。审阅完立刻 `git worktree remove --force`（每个 ~1.2 GB）。

## 已知的环境坑

| 坑 | 结论 |
|---|---|
| 会话 id 漂移 | 旧 shell 继承的 `HERMES_BUS_SESSION` 优先级高于 `sessions/current` 文件；重钉即可 |
| `CGColorSpace(name:)` | 必须传 CFString 常量，传友好名静默返回 nil |
| `createCGImage` 计时 | 不等 GPU，会测出上万 Mpx/s 的假数字；用 `render(to:)` + `waitUntilCompleted()` |
| 解码版本 | per-file（DNG 给 `9.dng`，非 DNG 才可能给 `9`）；必须对 `supportedDecoderVersions` 校验 |
| `.metal` 构建 | SwiftPM 没有可靠构建步骤；kernel 作为资源随包发布，运行时 `MTLLibrary(source:)` 编译（首次 ~0.2 s） |
| 磁盘 | `local/` 会到几个 GB（样本 + 克隆）。`du -sh local/`；克隆可随时重来 |

## 提交约定

- 一个里程碑一个提交，消息首行 `<M>: <做了什么>`，正文列证据（测试数、p50/p95、哈希前缀）。
- 提交前 `git status` 确认 `local/` 只出现 `local/README.md`。
- golden 基线随 OS 大版本会变：`GoldenRecord.osVersion` 用来区分"系统变了"与"我们改坏了"。
