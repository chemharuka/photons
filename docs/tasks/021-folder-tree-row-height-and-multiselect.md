# 021 — 左侧文件夹树：行高缩小 + ⌘ 多选（多选即筛选）

状态：已定（用户 2026-10-26）：「文件夹高度太高了，不需要那么多 px，缩小一些」+「加入文件夹的多选功能，
例如按住 command 可以自由选择文件夹，这样等于筛选功能」。

## A. 行高

`Sources/PhotonsUI/WorkspaceLayout.swift:61` 的 `browserRowHeight = 46` 被**两处**共用：
文件夹树 `sourcesOutline.rowHeight`（`BrowserPaneController.swift:195`）与下方照片行 `photosTable.rowHeight`
（`:133`）。用户指的是**文件夹**那一列。

做法：拆成两个常量 —— `browserTreeRowHeight: CGFloat = 28`（文件夹树）、`browserRowHeight = 46` 保持不变
（照片行带缩略图与说明文字，不动）。`browserTreeHeight(rowCount:panelHeight:)` 里的 `rows × rowHeight`
一并换成树的行高；`browserTreeMinHeight = 180` 的注释说「至少三行」——按 28 pt 三行是 84 pt，
**floor 是否跟着下调由实现者判断并在报告里说明理由**（`FolderTreeTests` 里有针对 180 pt floor 的用例，
若下调必须说明为什么不再是回归）。

`Tests/PhotonsUITests/FolderTreeTests.swift:93/:103` 钉的是 `WorkspaceLayout.browserRowHeight`，改为树常量。

## B. 多选 = 筛选

### 现在的模型
`AssetFilter.folderPath: String?` 是**单个**子树（`""`/`nil` = 整个 root），SQL 在
`Sources/PhotonsCatalog/CatalogAPI.swift:266` 附近拼一个组件感知的前缀谓词；`sourceRootId` 也是单个。
UI 侧 `CatalogSession.swift:234` 传 `folderPath: selectedFolderPath`。

### 目标模型
多选要能跨 root，所以：

```swift
public struct FolderSelection: Sendable, Hashable {
    public var rootId: String?   // nil = 全部照片
    public var path: String?     // nil/"" = 该 root 的全部；否则子树路径，如 "day2"
}
public struct AssetFilter {
    public var folders: [FolderSelection]   // 空 = 不加文件夹约束（等价于全部）
    // 旧的 folderPath / sourceRootId 若仍被别的调用点用到，保留但要让 folders 优先；
    // 能干净替换就直接替换（调用点不多，见 grep）
}
```

语义（必须写进单测）：

| 选择 | 结果 |
|---|---|
| 空选择 / 只有「全部照片」 | 整库 |
| 一个 root | 该 root 全部照片 |
| `day2` + `day2/sub` | 两者并集（子集被父覆盖，结果不重复、不去重两次） |
| `day2` + `day2x` | 并集，且 `day2x` 不被 `day2` 前缀吞掉（组件感知前缀照旧） |
| 两个 root 各选一个子文件夹 | 跨 root 并集 |
| 「全部照片」与其它项同时被选 | 按整库处理（其它项忽略），或让 UI 阻止这种组合 —— 二选一，**在报告里说明选了哪个** |

SQL：把单个前缀谓词换成 `(root match AND path prefix)` 的 **OR 组**，仍用参数绑定，不许拼字符串。
`limit` 语义不变。

### UI
- `sourcesOutline.allowsMultipleSelection = true`；AppKit 默认 ⌘ 点选自由多选、⇧ 连选，不要自己实现按键。
- 选中集合变化 → 汇成 `[FolderSelection]` 交给 `CatalogSession` → 重算筛选；选中项在界面上要看得出来
  （source list 的选中高亮，别自己画）。
- **`allowsEmptySelection` 保持不可清空**：交接里踩过「`allowsEmptySelection = false` 会让 `reloadData()`
  自动选第 0 行并清掉用户筛选」的坑，别把它打开；reload 后要**保住用户的选中集合**（按 rootId+path 恢复，
  不是按下标）。
- 取消选择（⌘ 点掉最后一项）→ 回到「全部照片」= 整库。

## C. 验收（子代理自己跑，`make verify` 由主线跑）

```bash
cd /tmp/photons-wt-foldertree
PHOTONS_TEST_RAW=/Users/luyao/Desktop/test/L1030433.dng swift test --filter FolderFilter   # 并集/前缀语义
PHOTONS_TEST_RAW=/Users/luyao/Desktop/test/L1030433.dng swift test --filter FolderTree     # 行高 + 多选状态
```

新增/更新的单测至少覆盖上表六行语义 + 行高从 46 变 28 后**标题仍居中且不被裁**（`FolderTreeTests` 已有这条，
改常量即可继续生效）。UI 侧若 `UISmokeRunner` 有文件夹筛选项，要同步更新并在报告里贴新计数。

## D. 边界

- 只动：`Sources/PhotonsUI/WorkspaceLayout.swift`、`BrowserPaneController.swift`、`CatalogSession.swift`、
  `Sources/PhotonsCatalog/CatalogAPI.swift`（筛选 SQL）、`UISmokeRunner.swift`（如涉及）、
  `Tests/PhotonsCatalogTests/FolderFilterTests.swift`、`Tests/PhotonsUITests/FolderTreeTests.swift`。
- 不动：缩略图/解码/渲染管线、`AssetFilter` 里与文件夹无关的字段。
- 不跑 `make verify`、不 `git commit`、不开新分支。
