# 018 保留黑点以下的（负值）信号，只在 S4 夹断

## 目标（一句）

解码缓存里本来就有黑点以下的负值信号，`s2_tone_map` 把它夹成 0，导致暗部细节再也拉不起来；
改成**保符号地走完 S2/S3，只在 S4 显示编码时夹断**。

## 为什么（实测，`_1274394.dng`，Photons 自己的解码缓存 6000×4000 rgba16Float）

```
min −0.0390   max 1.8086   负值样本 32,845,930
luma < 1e−6 的像素占 43.0%          p0.1 −0.00297   p1 −0.00280
这些"0"的 32×32 块均值 std = 5.7e−4，而纯噪声只该有 2.5e−5 → 强 23 倍（真画面信号）
宽容映射 [−0.004,+0.004] → [0,1] 后画面 std 0.31（确实拉得出东西）
```

格式不是瓶颈：Adobe ACR 缓存与 Photons 同为 **16-bit float / 通道**（我们 4 通道带 alpha，它 3 通道）。

## 改动（四处夹断，逐处处理）

`Sources/PhotonsCore/Kernels/s2_tone_map.metal`

| 行 | 现在 | 改成 |
|---|---|---|
| 55 | `float3 v = max(c.rgb, 0.0);` | `float3 v = c.rgb;`（保符号） |
| 61 | `v = max((v - blk)/(wht - blk), 0.0);` | 去掉外层 `max`（仿射重映射，负值合法） |
| 65 | `v = pivot * pow(max(v,1e-6)/pivot, gamma);` | 保符号幂：`v = sign(v) * pivot * pow(max(abs(v)/pivot, 1e-6), gamma);` |
| 78 | `dst.write(float4(max(v,0.0), c.a), gid);` | `dst.write(float4(v, c.a), gid);`（交给 S4） |

同时检查 `s3_curve.metal` / `s3_color.metal`，若也有 `max(v,0)` 或 `pow()` 假设非负，按同样方式放宽；
`s4_display.metal` 的 `max(c.rgb, 0.0)` **保留**——它是唯一合法的夹断点（显示编码前）。

## 不变量（必须逐条为真，写进断言）

1. **恒等路径不变**：所有滑杆为 0 时 `p.b.z > 0.5` 提前走出，中性文档的中间纹理与现在逐字节一致。
2. **最终像素不变**（除非大幅提亮）：负值在 S4 仍被夹成 0，所以"普通编辑"的成片像素应与改动前一致。
   → 用现有 golden 直接验证：`make verify` 里的 L2 golden 全绿即证明。
3. **matte 仍为 0**：alpha==0 的早退在 clamp 之前，不受影响。
4. **单调性不变**：每个 Light 滑杆在各自的域内仍单调（现有测试）。

## 验收命令

```bash
cd /tmp/photons-wt-subblack
swift build -c release --disable-automatic-resolution
swift test --filter 'Tone|Curve|Render|Matte|ColorHDR'      # 目标测试
make verify                                                # 唯一判据（含 L1 跨进程确定性 + L2 golden）
```

外加新增测试（`Tests/PhotonsCoreTests/SubBlackSignalTests.swift`）：

- 构造一张有负值（−0.003…+0.002 阶梯）的合成图，`exposure = +4`：
  断言 `blacks=0` 时输出里**能看到该阶梯的层次**（相邻台阶差 > 1 码值），而改动前它全被压成 0；
- 同一张图 `exposure = 0`：断言最终像素与"输入已夹到 0"的结果**完全一致**（证明默认观感不变）；
- 断言 `blacks` 从 −100 到 +100 时输出单调不降。

## 不做

- 不改成 Float32 工作缓冲（实测 16-bit half 在 1e−5 量级的相对误差 ~0.1%，够用；只有"blacks −100 + 曝光 +5"这种极端提亮才会出条带，留作后续）。
- 不动 S0/S1 的黑电平与白平衡。
- 不动 `docs/architecture-decisions.md`（若需记录，先问用户）。
