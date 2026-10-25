#!/usr/bin/env bash
# `make ui-smoke` — the M3 acceptance harness that needs a real window.
#
#   1000 synthetic photos + 1 real RAW  →  library  →  Photons --ui-smoke
#
# The app asserts, in order: grid item count == library rows; three window widths produce the
# columns/row height of the pure layout function; the grid draws real thumbnails from
# `ThumbnailCache` (tier = cell edge × DPR, warm pass = memory hits only, off-screen loads
# cancelled, worker queue bounded); the filmstrip mirrors the library and shares the selection
# **and draws its own real thumbnails** (74 × 50 pt cells at the DPR tier, every cell the sweep
# showed has an image, ≥ 36 of them, nothing left queued for cells that scrolled away); the grid
# and the strip turn out to share one `ThumbnailProvider`/`ThumbnailService` (no cache key — and
# no `contentHash` — is ever generated twice, and re-asking from the other view is a memory hit);
# a `t1024` DNG request is downgraded to `t512` with `skipReason= dngCeiling` and leaves no
# `t1024` file behind (006 §6.1); the loupe renders a frame through RenderGraph; a slider drag
# changes the presented frame hash, ⌘Z returns it to the previous hash and ⇧⌘Z returns it again;
# the undo/redo menu items validate to disabled with an empty history.
#
# M5 (export + presets) is driven through the shipped commands, not through the model:
#   · 文件 ▸ 导出… opens a real window sheet (`NSHostingController`), which reports "将导出 3 张";
#   · running it writes 3 JPEGs whose pixel size is exactly what `ExportSizing` forecasts for the
#     preset (long edge 512 does not upscale a 320 px fixture), named by the `{seq}-{name}` template;
#   · one source file is then overwritten with junk: the other two still export, and the sheet shows
#     exactly one failure row with the decode error — a batch is not all-or-nothing;
#   · 从当前照片新建预设 → 应用预设 changes the loupe's pixel hash and adds exactly one history
#     snapshot and one `asset_history` row, and ⌘Z puts the pre-apply hash back;
#   · the 导出… menu item validates to disabled with an empty selection.
#
# Masks (Q22) are driven through the shipped event path — synthesised mouse events into
# `LoupeCanvasView` → `LoupeController` → `MaskCanvasController` → the document:
#   · a new mask covers nothing and its `showMask` overlay changes no pixel at all;
#   · one 42-event drag is sampled down to ~21 points, one stroke and one history snapshot;
#   · the stroke makes the measured overlay coverage go 0 → ~0.12 and the frame hash change;
#   · toggling 显示蒙版 never grows the history (it is view state, not an edit);
#   · ⌘Z returns to the pre-stroke pixels *and leaves the overlay on* (the QUEUE 第 5 轮 #1 fix);
#   · the document is written to the catalog on every commit (`develop_version`, `asset_history`
#     rows), and a **brand-new session** reading the same library renders the same pixel hash;
#   · deleting the mask returns the frame to the hash it had with no mask.
#
# Rating / flag / colour label + the filter strip (catalog metadata — never an edit):
#   · a real "3" key event through `AssetCollectionView.keyDown` writes `assets.rating` = 3, read
#     back from a second `Catalog` on the same library, and the cell paints `stars:3` (read back
#     from the card that actually drew, via `lastDrawnBadges`);
#   · five selected photos + one "P" = **one** transaction and five rows (`db.changesCount`), and
#     ⌥3 adds `color_label = yellow` to the same five with stars + flag + colour on one badge;
#   · "≥3 星" narrows the grid to exactly the rows the same `AssetFilter` query returns, as a chip;
#   · selecting another photo keeps the filter; clicking the chip clears it and the library returns;
#   · a rating grows neither `EditHistory` nor `editRevision`, and ⌘Z stays grey / a no-op
#     (a rating is library metadata, so it must not be undoable).
# 直方图卡片 + 高光警告 (005f 的 UI 一半):
#   · 检查器里有一张 直方图 卡片，画的是**这一帧自己的**测量（R/G/B/luma、256 bin），四个通道的
#     bin 和都等于采样像素数；
#   · 卡片上的削顶百分比就是 Core 的 `clippedHigh`，两边各证一次：一次对
#     `HistogramCardFormat`，一次对同一帧像素的独立重数（0.999 阈值、Rec.709 权重）；
#   · 点削顶数字武装画布上的高光警告（64×48 的削顶网格，品红叠色），且**不动文档**：文档 hash、
#     开发历史、editRevision、写库次数全都不变。
#
# 蒙版形状 (M4 的六种形状，全部补齐):
#   · 线性渐变 / 径向渐变是**在画布上画出来的**（按下→拖动→抬起 ⇒ 一个蒙版、一条历史），选中后
#     再拖一次就是调整（中心→边缘），每次手势 ⌘Z 一次撤销；
#   · 颜色范围 / 亮度范围 / 语义 从 新建 菜单创建，覆盖面积按渲染出来的叠加实测（颜色样本取自
#     画面、亮度 0…1、语义按 OS 能力表选路线）；
#   · 一张纯色合成源证明颜色范围蒙版能选中它 ~100 %。
#
# 蒙版参数面板 (Q28 — 蒙版级 + 局部调整 + 改名/排序)，全部实测像素与历史条数：
#   · 不透明度 100 % → 50 %：Δ 峰 0.4977 → 0.3603，覆盖面积不动（0.1868 → 0.1866），history 一次快照；
#   · 反转：覆盖面积 0.1868 → 0.8131（4.4×），两者互补（和 0.9999 = 内容区），history +1；
#   · 羽化 0 → 0.40 变软，在**无结构纯色源**上量（照片里 +2 EV 的差值随像素值变化，最尖的跳变是图像
#     内容而不是边缘，实测羽化前后都是 0.4526 —— 那是统计量不对，不是模糊没生效）：单像素最大跳变
#     0.2881 → 0.0237（0.08×）、半覆盖像素占比 0.016 → 0.230（13.95×），50 % 等值线只漂 3.75 %；
#   · 精修 0 → 0.90 是导向滤波而不是模糊：无结构源上退化为对称平滑（跳变 0.2881 → 0.0391，等值线漂
#     1.59 %），真实照片上把覆盖拉向图像结构（2 % 尾面积 0.1868 → 0.2894）；两者都进历史；
#   · 曝光滑杆 ±2 EV：画面均值 +2 0.4081 > 0 0.3577 > −2 0.3293，且 0 EV 与“完全没有蒙版”位精确相等
#     （M1-6 恒等分支）；
#   · 混合模式：第二个组件 add 时并集不变（0.1868），改 subtract 后中心被擦掉（0.1578）；
#   · 改名不重渲（像素 hash、selectionKey、applyKey 三者都不变）但产生 1 条历史——Core 的
#     isSemanticallyIdentical 按值比 masks、名字在内，所以这是“不重渲的文档变更”，不是渲染参数；
#   · 上/下移改变文档数组与落盘 JSON、面板列表跟着变、history +1；键材质不变，因为 Core 的组合顺序与
#     键都按 id 字典序（D6）——上下移是文档顺序，不是渲染顺序；
#   · 面板的 16 个控件真的在活视图树里（MaskPanelProbe 读回，SwiftUI 的 Slider 不是 NSSlider），
#     列表行写“径向渐变 · 局部 2 项”；
#   · 滑杆拖动中 10 次写入 → 1 个快照 + 1 次渲染（50 ms 防抖 + 单飞），松手才 commit。
#
# 倍率 (显示 菜单):
#   · 适应窗口 / 1:1 / 2:1 / 4:1 / 8:1，勾选跟着相机走，⌘= / ⌘− 走真实快捷键；每一档都要求
#     canvas == 视口、渲染倍率 == 档位、可见窗口 == 视口/倍率，且不改文档。
#
# Screenshots land in local/out/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
RAW="${RAW:-$HOME/Desktop/test/L1030433.dng}"
OUT="$ROOT/local/out"
BIN="$ROOT/.build/$CONFIG/photonsctl"
APP="$ROOT/.build/Photons.app"
LIB="$OUT/ui-smoke.photonslibrary"
SRC="$OUT/ui-smoke-src"
COUNT="${COUNT:-1000}"

[ -x "$BIN" ] || { echo "ui-smoke: build first (make build)" >&2; exit 1; }
[ -x "$APP/Contents/MacOS/Photons" ] || { echo "ui-smoke: no app bundle (make app)" >&2; exit 1; }

mkdir -p "$OUT"
rm -rf "$LIB" "$SRC"
mkdir -p "$SRC"

echo "fixtures    $COUNT synthetic photos → $SRC"
"$BIN" fixtures "$SRC" --count "$COUNT" --dupes 0 --size 320x240 >/dev/null

# The loupe needs one real RAW (the fixtures are JPEGs), and it must be imported from the *same*
# directory as the fixtures: a reference import takes its source root from the first import of the
# volume (roots are volume-identified, not path-identified — the M2 rule), so a second directory on
# the same disk would attach its rows to the first root and every relPath would point at nothing.
if [ -f "$RAW" ]; then
    cp "$RAW" "$SRC/$(basename "$RAW")"
else
    echo "ui-smoke: no RAW at $RAW — the loupe will have no real photo to render" >&2
fi

"$BIN" library create "$LIB" >/dev/null
"$BIN" library import "$LIB" "$SRC" --mode reference --json >/dev/null

ROWS="$("$BIN" library stats "$LIB" --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["assets"])')"
echo "library     $LIB"
echo "rows        $ROWS"

set +e
"$APP/Contents/MacOS/Photons" --ui-smoke "$LIB" --expect-rows "$ROWS" --shots "$OUT"
CODE=$?
set -e

if [ $CODE -ne 0 ]; then
    echo "ui-smoke    FAIL (exit $CODE)" >&2
    exit $CODE
fi
echo "ui-smoke    PASS  (screenshots in $OUT/ui-smoke-*.png)"
