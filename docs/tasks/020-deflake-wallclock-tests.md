# 020 — 挂钟计时测试去 flaky（判据改成结构不变量）

状态：已派（2026-10-26）。依据：`local/HANDOFF-2026-10-26.md` §4 第 3 项；实际观测到
`ThumbnailServiceTests` 在主线上真红过一次（2026-10-26 20:46，`/tmp/verify-main-baseline.log`）。

## 病根

四个测试套件用**壁钟时间/完成顺序**做断言，靠 `Task.sleep` 或"谁先完成"判断调度行为。
在 8 核机器上并行编译时 CPU 被抢，完成顺序与耗时都会抖 → 随机红。**不是产品 bug。**

| 套件 | 文件 |
|---|---|
| `ThumbnailServiceTests` | `Tests/PhotonsCatalogTests/ThumbnailServiceTests.swift` |
| `LoupeQueueTests` | `Tests/PhotonsUITests/LoupeQueueTests.swift` |
| `HistogramCadenceTests` | `Tests/PhotonsUITests/HistogramCadenceTests.swift` |
| `LoupeZoomTransitionTests` | `Tests/PhotonsUITests/LoupeZoomTransitionTests.swift` |

## 定案

1. **断言改结构性质**，只记录耗时：
   - 顺序 → 断言**准入顺序**（入队/出队序、`firstAdmission == visibleCount` 这类在锁里定下的量），
     完成顺序只 `print` 不断言。
   - 预算 → 用 `PHOTONS_BENCH=1` 门控；未门控时只 print 实测值，不做断言。
2. **不许调阈值放水**（不许把 5 ms 改成 50 ms），不许 `XCTSkip`，不许删用例。
3. 所有异步等待必须有超时（`XCTestExpectation` 5 s 量级），**不许** `awaitPendingDevelopments(timeout:)`
   叠在循环里；跑前 `pgrep -fl xctest` 清孤儿。
4. 若为了可测性必须在生产代码里加一个"可观测点"（如队列出队事件回调），只加**只读诊断**，
   不改行为；在报告里单列出来。

## 验收（子代理自己跑）

```bash
cd <自己的 worktree>
PHOTONS_TEST_RAW=/Users/luyao/Desktop/test/L1030433.dng \
  swift test --filter ThumbnailService      # 自己的套件名，单名字，别写多个
```

判据：**空载连跑 20 轮全绿**；再在**有并行编译负载**时（另开 `swift build --scratch-path /tmp/x`）
跑 5 轮全绿。跑不满 20 轮不许报 done；报 done 时贴「20 轮 + 5 轮」的计数与最后一轮的原始输出尾部。

反证要求（必须做）：故意把断言写反一次，确认测试能红（证明断言不是空转），再改回来。

## 边界

- 只动上表里**属于自己的那 1–2 个测试文件**（外加必要的只读诊断点）。
- 不跑全量 `make verify`、不 `git commit`、不改别人的测试文件。
