# photons — agent 契约

macOS 原生 RAW 摄影工作流（目录库 + 非破坏性编辑 + 导出），Swift/SwiftPM，MIT。
解码只走 Apple 的 `CIRAWFilter` / `RawCamera.bundle`，不自己写 demosaic。

本文件对**所有**在仓库里干活的 agent 生效（Hermes session、`delegate_task` 子代理、opencode、codex）。
它只写"必须每次都遵守的约束"；具体流程在 skill 里，见下面的角色路由。

## 三条铁律

1. **`make verify` 绿了才算做完**（build + 单测 + L1 跨进程确定性 + L2 golden + L3 graph + catalog + bench）。
   红了不许提交、不许报 done。只动 UI 的活另跑 `make ui-smoke`。
2. **结论进 `docs/`，过程进 `local/`。** `local/*` 被 gitignore；必须活过 `git clone` 的东西不能只写在 `local/`。
3. **一个功能一个 worktree**，不在主工作区并行改文件。分支名 `feat/<主题>` 或 `fix/<主题>`。

## 不许做的事（要动先改 `docs/architecture-decisions.md` 并说明理由）

- 不引第三方包（LibRaw / Exiv2 / libheif / x265 / lensfun 一律不行；GRDB 是唯一豁免）。要加包先问用户。
- 不重写 demosaic / 降噪；不做多帧 HDR 合成、超解析、自写 demosaic。
- 同一套渲染器只能有一份实现（缩略图 / 预览 / 导出只差输入 scale 与输出格式）。
- 数据库是唯一真相；XMP 只导出不回读。
- 解码能力、v8/v9 选择、EDR 余量、`boostAmount` 这类数值：**只以 `docs/architecture-decisions.md` 与
  `docs/STATUS.md` 为准，不要在别处复述**——复述过的副本都已过期（曾两次把 v9 和 EDR 1.019 当现状）。

## 角色路由（先读 skill 再动手）

| 你的活 | 第一步 |
|---|---|
| 实现一个功能 / 修一个 bug | `skill_view('photons-feature-dev')` |
| 审阅别人的分支 | `skill_view('photons-code-review')` |
| 要跨 session 状态 / 占位 / 交接 | `skill_view('photons-session-bus')` |

派单方必须在任务文字里点明用哪个 skill；不要指望 description 自动命中。

## 环境硬约束（实测，别猜）

- 并行编译一律 `swift build --scratch-path /tmp/<独立目录>`；两个进程共用同一 checkout 的 `.build` 必产生假红。
- 新 worktree 的 `.build` 是空的：从主 checkout 拷 `checkouts` / `repositories` / `workspace-state.json`
  （含 GRDB 的 `SQLiteCustom/src` 子模块）再 `swift build -c release --disable-automatic-resolution`。冷编约 80 s。
- 同一分支不能在两个 worktree 同时检出：要干净基线用 `git worktree add --detach /tmp/<path> main`。
- 本机到 github 不通（`SSL_ERROR_SYSCALL`）：`git push` / `git ls-remote` 会失败，**不要重试**；只做本地 commit。
- 异步 UI 测试一律带超时的 `XCTestExpectation`（5 s 量级）；跑前 `pgrep -fl xctest` 查孤儿窗口，跑后确认退出。
- 断言结构性质（如 `firstPrefetchAdmission == visibleCount`），不要断言壁钟先后顺序（3 worker 下必 flaky）。
- 测试样本：`~/Desktop/test/L1030433.dng`（60 MP Leica SL3）、`~/Desktop/US/_1274394.dng`（Sony 24 MP）。

## 提交

- 一个工作单元一个提交；首行 `feat(ui): …` / `fix(render): …`，正文列证据（测试数、p50/p95、hash 前缀）。
- 提交前 `git status` 确认 `local/` 只出现 `local/README.md`。
- 只提交自己分支的改动；不要 merge 别人分支，不要 `push`（无远端凭据）。

## 文档面

| 文件 | 是什么 |
|---|---|
| `docs/architecture-decisions.md` | 唯一技术裁决来源（含解码链路的硬事实与实测值） |
| `docs/STATUS.md` | 里程碑现状与最新实测指标 |
| `docs/tasks/QUEUE.md` | 并行队列、每项的文件所有权与验收结果 |
| `docs/collaboration.md` | 本机环境 + 多 agent 协作流程（含"一个功能一个 session"的固定命令序列） |
| `docs/tasks/NNN-*.md` | 任务规格；派给 worker 时它只读规格 |
| `docs/reviews/NNN-*.md` | 审阅结论（审阅 session 写，实现 session 不改） |
