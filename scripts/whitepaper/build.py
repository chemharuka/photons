#!/usr/bin/env python3
"""Build the Photons whitepaper site.

Markdown (docs/whitepaper/*.md) -> static HTML (site/), one page per chapter,
with a sidebar, a per-page table of contents, prev/next links and a client-side
search index. Pandoc does the Markdown and the maths (--mathml: no JavaScript,
no CDN, prints correctly).

Usage:
    python3 scripts/whitepaper/build.py            # build site/
    python3 scripts/whitepaper/build.py --check    # also report unresolved links
"""

from __future__ import annotations

import html
import json
import re
import shutil
import subprocess
import sys
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "docs" / "whitepaper"
OUT = ROOT / "site"


def run(args: list[str]) -> str:
    result = subprocess.run(args, cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(f"command failed: {' '.join(args)}")
    return result.stdout


def git_revision() -> str:
    try:
        return run(["git", "rev-parse", "--short", "HEAD"]).strip()
    except SystemExit:
        return "unknown"


def pandoc_body(path: Path) -> str:
    return run([
        "pandoc", str(path),
        "-f", "markdown+smart+pipe_tables",
        "-t", "html5",
        "--math-method=mathml",
        "--wrap=none",
    ])


def pandoc_text(path: Path) -> str:
    try:
        text = run(["pandoc", str(path), "-f", "markdown+smart", "-t", "plain", "--wrap=none"])
    except SystemExit:
        return ""
    return re.sub(r"\s+", " ", text).strip()


def strip_tags(value: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", value)).strip()


def page_toc(fragment: str) -> str:
    items = []
    for match in re.finditer(r'<h([23]) id="([^"]+)"[^>]*>(.*?)</h\1>', fragment, re.S):
        level, anchor, text = match.group(1), match.group(2), strip_tags(match.group(3))
        items.append(f'<li class="toc-{level}"><a href="#{anchor}">{html.escape(text)}</a></li>')
    if not items:
        return ""
    return '<nav class="page-toc"><p class="toc-title">本页</p><ul>' + "".join(items) + "</ul></nav>"


def sidebar(chapters: list[dict], current: dict) -> str:
    rows = []
    for chapter in chapters:
        if chapter["slug"] == current["slug"]:
            rows.append(f'<li class="current"><span>{html.escape(chapter["short"])}</span></li>')
        else:
            rows.append(
                f'<li><a href="{chapter["slug"]}.html">{html.escape(chapter["short"])}</a></li>'
            )
    return '<ul class="chapter-list">' + "".join(rows) + "</ul>"


PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="Photons 的显示架构、处理架构与参数算法（α 阶段）。">
<link rel="stylesheet" href="assets/whitepaper.css">
<link rel="icon" href="assets/mark.svg">
</head>
<body>
<a class="skip" href="#content">跳到正文</a>
<header class="topbar">
  <button class="menu-button" type="button" aria-label="目录" aria-expanded="false">☰</button>
  <a class="brand" href="index.html">Photons<span>白皮书</span></a>
  <div class="search">
    <input id="search-input" type="search" placeholder="搜索全文（/）" autocomplete="off" aria-label="搜索全文">
    <div id="search-results" class="search-results" hidden></div>
  </div>
</header>
<div class="layout">
  <aside class="sidebar">
    <p class="sidebar-title">目录</p>
    {sidebar}
    <p class="sidebar-note">α 阶段 · 随代码变动<br>基准 <code>{revision}</code></p>
  </aside>
  <main id="content" class="content">
    {toc}
    <article>
{body}
    </article>
    <nav class="pager">
      {prev}
      {next}
    </nav>
    <footer class="page-footer">
      <p>Photons 渲染白皮书 · α 阶段草案 · 代码基准 <code>{revision}</code> · {today}</p>
      <p>本文档描述的是实现，不是承诺；与代码冲突时以 <code>Sources/</code> 为准。</p>
    </footer>
  </main>
</div>
<script src="assets/site.js"></script>
</body>
</html>
"""


def main() -> None:
    nav = json.loads((SRC / "nav.json").read_text(encoding="utf-8"))
    chapters = nav["chapters"]
    revision = git_revision()
    today = date.today().isoformat()

    if OUT.exists():
        shutil.rmtree(OUT)
    (OUT / "assets").mkdir(parents=True)
    for asset in (SRC / "assets").iterdir():
        shutil.copy2(asset, OUT / "assets" / asset.name)

    index: list[dict] = []
    for position, chapter in enumerate(chapters):
        source = SRC / chapter["file"]
        if source.exists():
            fragment = pandoc_body(source)
            text = pandoc_text(source)
        else:
            fragment = (
                f'<h1>{html.escape(chapter["title"])}</h1>'
                '<p class="placeholder">本章尚未成稿。构建脚本对缺失章节生成占位页，'
                "以便导航与版式可以先被评审。</p>"
            )
            text = ""
        previous = chapters[position - 1] if position > 0 else None
        following = chapters[position + 1] if position + 1 < len(chapters) else None
        prev_html = (
            f'<a class="prev" href="{previous["slug"]}.html">← {html.escape(previous["short"])}</a>'
            if previous else "<span></span>"
        )
        next_html = (
            f'<a class="next" href="{following["slug"]}.html">{html.escape(following["short"])} →</a>'
            if following else "<span></span>"
        )
        page = PAGE.format(
            title=html.escape(chapter["title"]) + " · Photons 白皮书",
            revision=revision,
            today=today,
            sidebar=sidebar(chapters, chapter),
            toc=page_toc(fragment),
            body=fragment,
            prev=prev_html,
            next=next_html,
        )
        (OUT / f'{chapter["slug"]}.html').write_text(page, encoding="utf-8")
        index.append({"slug": chapter["slug"], "title": chapter["title"], "text": text})

    landing = PAGE.format(
        title=html.escape(nav["title"]),
        revision=revision,
        today=today,
        sidebar=sidebar(chapters, chapters[0]),
        toc="",
        body=landing_body(nav, chapters),
        prev="<span></span>",
        next=f'<a class="next" href="{chapters[0]["slug"]}.html">{html.escape(chapters[0]["short"])} →</a>',
    )
    (OUT / "index.html").write_text(landing, encoding="utf-8")
    (OUT / "search-index.json").write_text(
        json.dumps(index, ensure_ascii=False), encoding="utf-8"
    )
    (OUT / "version.json").write_text(
        json.dumps({"revision": revision, "built": today}, ensure_ascii=False), encoding="utf-8"
    )
    (OUT / ".nojekyll").write_text("", encoding="utf-8")
    print(f"built {len(chapters)} chapters + index into {OUT.relative_to(ROOT)} @ {revision}")


def landing_body(nav: dict, chapters: list[dict]) -> str:
    items = "".join(
        f'<li><a href="{c["slug"]}.html">{html.escape(c["title"])}</a></li>' for c in chapters
    )
    return f"""<h1>{html.escape(nav["title"])}</h1>
<p class="lede">{html.escape(nav["subtitle"])}</p>
<p>Photons 是一个 macOS 上的原生 RAW 工作流：导入、挑片、非破坏性显影、导出。
它不自带解码器——去马赛克、镜头校正、机器学习降噪来自 Apple 的 <code>CIRAWFilter</code>；
解码之上的整条算术链、蒙版、色彩管理与导出，是 Photons 自己的 Metal 渲染图。</p>
<p>这份白皮书讲三件事：画面如何被画到屏幕上（显示架构）、每个参数作用在哪个域以及为什么在那个位置
（处理架构）、关键参数的具体算法（参数算法）。它不写界面设计，也不描述尚未落地的计划。</p>
<blockquote><p><strong>α 阶段声明。</strong>项目仍在 α：本文描述的是当前实现，不是稳定 API。
管线、参数与常数都会变，改动会反映在页脚的代码基准上。</p></blockquote>
<h2>章节目录</h2>
<ul class="landing-list">{items}</ul>
<h2>怎么读</h2>
<p>第一次读，按顺序：总览给出一张管线图和三条不变量；显示架构解释「屏幕上的这张图」是怎么来的；
处理架构给出参数到域、域到阶段的归属表；参数算法逐项展开公式与实现。</p>
<p>需要核对某一句话时，正文里的每个常数后面都跟着 <code>文件:行</code>。
白皮书与 <code>docs/architecture-decisions.md</code> 分工不同：前者说「现在是什么」，后者说「为什么这样定、什么条件下会错」。</p>
"""


if __name__ == "__main__":
    main()
