# 022 — 右侧信息栏：文件名 / 像素数 / 尺寸 三行（左·中·右）

状态：已定（用户 2026-10-26）：信息栏里原来只有一行文件名，改成三行，**只有值、不写任何中文标签**：

```
L100000.dng          60 MP            9000×6000
└ 左对齐              └ 居中            └ 右对齐
```

## 现状

`Sources/PhotonsUI/InspectorView.swift:161` `infoCard`，现在是一个 `VStack(alignment: .leading, spacing: 2)`：

```
MarqueeText(filename)                       ← 第 1 行（要保留：长名字截断 + 悬停线性滚动）
[MissingFileNotice]（仅缺失时）
InspectorParameterRow(iso/focal/aperture/shutter)
MarqueeText(equipment)
```

## 改法

第 1 行以下、`InspectorParameterRow` 之前，插入两行，形成「左 / 中 / 右」三行：

```swift
HStack { MarqueeText(text: filename); Spacer() }              // 左：保持 MarqueeText 的既有行为
HStack { Spacer(); Text(pixelCount); Spacer() }               // 中
HStack { Spacer(); Text(pixelDimensions) }                    // 右
```

数据来源：`asset.width` / `asset.height`（`Sources/PhotonsCatalog/Models.swift:111-112`，可能为 `nil`）。

格式化（写成一个可单测的纯函数，放 `MarqueeText.swift` 里的 `InspectorPhotoInfo` 旁边）。
**三行都只有值，不许出现任何中文标签**（用户 2026-10-26：「不要写中文 就 L100000.dng   60 MP    9000×6000」）：

| 输入 | 像素数 | 尺寸 |
|---|---|---|
| `9000 × 6000` | `54 MP` | `9000×6000` |
| `6000 × 4000` | `24 MP` | `6000×4000` |
| `2000 × 1000` | `2 MP` | `2000×1000` |
| `1000 × 900`（< 1 MP） | `0.9 MP` | `1000×900` |
| `width`/`height` 为 `nil` | `—` | `—` |

- 像素数格式：`round(w·h/1e6)` 后**数字与 `MP` 之间留一个空格**（`60 MP`，不是 `60MP`）；< 1 MP 保留一位小数。
- 尺寸格式：`宽×高`，`×` 用 U+00D7，**不留空格**。
- 未选择照片：文件名沿用现有 `未选择照片`（既有行为，不要动），另两行 `—`。

行高：三行都必须固定行高（未选择照片时也不许塌），沿用卡片里既有的 spacing / 字号约定（`MarqueeText` 用的字号），
不许让第 2/3 行在缺值时占位变化。

`MissingFileNotice` 的位置保持在**三行之后、拍摄参数之前**（它说的是原文件状态，不是照片规格）。

## 验收（子代理自己跑，`make verify` 由主线跑）

```bash
cd /tmp/photons-wt-inspector
PHOTONS_TEST_RAW=/Users/luyao/Desktop/test/L1030433.dng swift test --filter Inspector
```

必须新增/更新的断言：

1. **内容**：三行文本分别是 `文件名` / `NMp` / `W×H`，取自测试库里的那张 fixture（现有 `InspectorMetadataTests` 已建库，沿用）。
2. **对齐**（几何断言，不靠肉眼）：`line1.frame.minX ≈ 卡片内容区 minX`、`line2.frame.midX ≈ 内容区 midX`、
   `line3.frame.maxX ≈ 内容区 maxX`，容差 1 pt。
3. **缺值**：`width/height = nil` 时两行都是 `—`，且行高与有值时一致。
4. **既有断言怎么改**：`InspectorMetadataTests.swift:121` 现在断言「两行是 MarqueeText（文件名 + 器材）」，
   加了两行普通 `Text` 后要改这条计数 —— **在注释里写明原因**，不许顺手放宽别的断言。

## 边界

- 只动：`Sources/PhotonsUI/InspectorView.swift`、`Sources/PhotonsUI/MarqueeText.swift`（放格式化纯函数）、
  `Tests/PhotonsUITests/InspectorMetadataTests.swift`，若 `UISmokeRunner.swift` 有信息卡片项则同步。
- 不动：直方图卡、蒙版、白平衡卡、`CatalogSession`、任何渲染/解码代码。
- 不跑 `make verify`、不 `git commit`、不开新分支。
