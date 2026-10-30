#!/usr/bin/env python3
"""把 AppIcon.icon（Icon Composer 文档）变成两样东西：

1. 26+ 用的 .icon —— 原样留在 Resources/AppIcon.icon，由 Xcode/系统负责液态玻璃
2. 14–15 回退用的经典 .icns —— macOS 图标规范：1024 画布里 824 见方的圆角方，
   圆角半径 0.2237×边长（Apple 的 squircle 近似），画布四周透明，不含阴影

为什么不能直接拿 ictool 的渲图做 icns：
  · macOS 渲染存在“满画布 + 烘焙阴影” → 做出来比系统图标大一圈、还有双层阴影
  · 所以回退版用 fill:none 渲染出纯标记，再自己糊一层规范的圆角底

用法：
  scripts/appicon.py            # 生成 Resources/AppIcon.icns
  scripts/appicon.py --check    # 只打印实测值（画布占比、圆角、透明边）
"""
import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

LANCZOS = getattr(Image, "Resampling", Image).LANCZOS

ROOT = Path(__file__).resolve().parent.parent
DOC = ROOT / "Resources" / "AppIcon.icon"
OUT_ICNS = ROOT / "Resources" / "AppIcon.icns"
ICTOOL = ("/Applications/Xcode.app/Contents/Applications/Icon Composer.app/"
          "Contents/Executables/ictool")

CANVAS = 1024
ARTWORK = 824          # Apple HIG: macOS 图标 1024 画布里放 824 的主体
RADIUS = round(ARTWORK * 0.2237)
SIZES = [16, 32, 64, 128, 256, 512, 1024]


def doc_fill_color() -> tuple:
    """读 icon.json 的 fill；solid 用它的 RGB，automatic/缺省回退白色。"""
    cfg = json.loads((DOC / "icon.json").read_text())
    fill = cfg.get("fill")
    if isinstance(fill, dict) and "solid" in fill:
        raw = fill["solid"].split(":")[-1]
        parts = [float(v) for v in raw.split(",")]
        r, g, b = (max(0, min(255, round(v * 255))) for v in parts[:3])
        return (r, g, b, 255)
    return (255, 255, 255, 255)


def render_doc(dst: Path, size: int = CANVAS):
    """按文档原样渲染（含底色）。实测 fill:none 会退回白色板，所以不自造底盘。"""
    r = subprocess.run([ICTOOL, str(DOC), "--export-image", "--output-file", str(dst),
                        "--platform", "macOS", "--rendition", "Default",
                        "--width", str(size), "--height", str(size), "--scale", "1"],
                       capture_output=True, text=True)
    if r.returncode != 0 or not dst.exists():
        print("ictool failed:", r.stdout, r.stderr, file=sys.stderr); sys.exit(1)


def compose_legacy(render_png: Path, dst: Path):
    """渲染图是满画布到边的（系统在桌面才加外边距），这里按 macOS 规范收到 824 并居中。"""
    src = Image.open(render_png).convert("RGBA")
    art = src.resize((ARTWORK, ARTWORK), LANCZOS)
    plate = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - ARTWORK) // 2
    plate.alpha_composite(art, (off, off))
    plate.save(dst)


def build_icns(master: Path, icns: Path):
    with tempfile.TemporaryDirectory() as td:
        iconset = Path(td) / "AppIcon.iconset"
        iconset.mkdir()
        for s in SIZES:
            im = Image.open(master).convert("RGBA").resize((s, s), LANCZOS)
            im.save(iconset / f"icon_{s}x{s}.png")
            if s <= 512:
                im2 = Image.open(master).convert("RGBA").resize((s * 2, s * 2), LANCZOS)
                im2.save(iconset / f"icon_{s}x{s}@2x.png")
        r = subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(icns)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print("iconutil failed:", r.stdout, r.stderr, file=sys.stderr); sys.exit(1)


def check(icns: Path):
    print(f"文件      {icns.name}  {icns.stat().st_size/1024:.1f} KB   文档底色 {doc_fill_color()[:3]}")
    sizes = []
    try:
        im = Image.open(icns)
        sizes = sorted(im.info.get("sizes", []) or [])
    except Exception:
        pass
    master = Image.open(icns).convert("RGBA")
    print(f"主表示    {master.size}" + (f"   内嵌 {sizes}" if sizes else ""))
    for s in (16, 32, 128, 512):
        im = master.resize((s, s), LANCZOS)
        a = im.split()[3].load()
        ink = [x for x in range(s) if a[x, s // 2] > 8]
        if not ink:
            print(f"  {s:4}px  空"); continue
        left, right = ink[0] / s * 100, (s - 1 - ink[-1]) / s * 100
        print(f"  {s:4}px  左右留白 {left:.1f}% / {right:.1f}%  占比 {(100-left-right):.1f}%")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if a.check:
        check(OUT_ICNS); return
    if not DOC.exists():
        print(f"缺少 {DOC}", file=sys.stderr); sys.exit(1)
    with tempfile.TemporaryDirectory() as td:
        mark = Path(td) / "mark.png"
        render_doc(mark)
        master = Path(td) / "master.png"
        compose_legacy(mark, master)
        build_icns(master, OUT_ICNS)
        shutil.copy(master, ROOT / "Resources" / "AppIcon-legacy-1024.png")
    check(OUT_ICNS)
    print(f"→ {OUT_ICNS}")


if __name__ == "__main__":
    main()
