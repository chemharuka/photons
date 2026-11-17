#!/usr/bin/env python3
"""把界面中文字面量包成 `Loc.t(...)`，**中文原文就是 key**（不用哈希）。

与 PR1 的 `scripts/localization/extract.py` 的区别只有一处，但很关键：
PR1 把模板交给 `hashlib.sha256(...)[:12]` 生成 key，代码里于是出现 `L10n.tr("35ce8e8e8945")`，
读代码时看不出这是「效果卡」。这里直接 `Loc.t("效果卡")`，翻译表就是「中文原文 = 译文」。

用法（在仓库根目录）：

    python3 scripts/localization/extract_zh.py            # 只报告，不改文件
    python3 scripts/localization/extract_zh.py --write    # 真改文件

它做的事：

* 扫描 `Sources/<target>/*.swift`，跳过注释、原始串与三引号多行串；
* 只处理**含中文**的字符串字面量（其余保持原样）；
* 跳过 **enum case 的裸值**（`case light = "明暗"`）—— 那是 Codable/磁盘格式的一部分，不是文案；
* 跳过 `UISmokeRunner.swift` 与 `*Probe*.swift`（验收探针，必须钉死中文原文）；
* 插值写成 反斜杠+括号 的形式时，变成 `{n}` 占位 + 位置参数 `String(describing: (expr))`；
  `specifier: "%.1f"` 那种变成 `String(format: "%.1f", expr)`；
* 已经是 `Loc.t(...)` 的调用原样跳过（脚本可重复运行）；
* 生成/补齐 `Sources/PhotonsLocalization/Resources/zh-Hans.lproj/Localizable.strings`，
  并在 `en.lproj` 里为**新**模板留空占位 `""`（交给翻译那一棒，绝不机翻顶数）。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ["PhotonsUI", "PhotonsCore", "PhotonsExport", "PhotonsCatalog", "PhotonsExtensions", "PhotonsApp"]
SKIP_FILES = {"UISmokeRunner.swift"}
SKIP_SUFFIX = ("Probe.swift",)
ZH = re.compile(r"[\u3400-\u9fff]")
RES = ROOT / "Sources/PhotonsLocalization/Resources"


def has_zh(s: str) -> bool:
    return bool(ZH.search(s))


def unescape(s: str) -> str:
    return (
        s.replace('\\n', '\n').replace('\\t', '\t').replace('\\"', '"').replace('\\\\', '\\')
    )


def escape(s: str) -> str:
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\t', '\\t')


def arg_expr(raw: str) -> str:
    """单参数与带 specifier 的插值都折成 Swift 表达式，结果是一个 String。"""
    m = re.fullmatch(r'(.*?),\s*specifier:\s*("(?:\\\\.|[^"\\\\])*")\s*', raw, re.S)
    if m:
        return "String(format: %s, %s)" % (m.group(2), m.group(1).strip())
    return "String(describing: (%s))" % raw.strip()


def scan(text: str, path: str) -> tuple[str, list[tuple[str, list[str]]]]:
    """返回 (改写后的源码, [(模板, [参数表达式])])。"""
    out = []
    found = []
    i = 0
    n = len(text)
    while i < n:
        if text.startswith('//', i):
            j = text.find('\n', i)
            j = n if j < 0 else j
            out.append(text[i:j])
            i = j
            continue
        if text.startswith('/*', i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith('/*', j):
                    depth += 1
                    j += 2
                elif text.startswith('*/', j):
                    depth -= 1
                    j += 2
                else:
                    j += 1
            out.append(text[i:j])
            i = j
            continue
        if text.startswith('#"', i):
            j = text.find('"#', i + 2)
            j = n if j < 0 else j + 2
            out.append(text[i:j])
            i = j
            continue
        if text[i] != '"':
            out.append(text[i])
            i += 1
            continue
        if text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            out.append(text[i:j])
            i = j
            continue

        # 普通字符串字面量
        start = i
        i += 1
        parts = ['']
        args = []
        while i < n:
            if text[i] == '"':
                i += 1
                break
            if text.startswith('\\(', i):
                j, depth, inq = i + 2, 1, False
                begin = j
                while j < n and depth:
                    if text[j] == '\\':
                        j += 2
                        continue
                    if text[j] == '"':
                        inq = not inq
                    elif not inq:
                        if text[j] == '(':
                            depth += 1
                        elif text[j] == ')':
                            depth -= 1
                    j += 1
                args.append(text[begin:j - 1])
                parts.append('')
                i = j
                continue
            if text[i] == '\\' and i + 1 < n:
                parts[-1] += text[i:i + 2]
                i += 2
                continue
            parts[-1] += text[i]
            i += 1

        raw = text[start:i]
        if not any(has_zh(p) for p in parts):
            out.append(raw)
            continue

        line_start = text.rfind('\n', 0, start) + 1
        prefix = text[line_start:start]
        # enum case 的裸值是 Codable/磁盘格式的一部分，不是文案 → 原样保留，也不进表
        if re.search(r'\bcase\s+\w+\s*=\s*$', prefix):
            out.append(raw)
            continue

        template = parts[0]
        for k, part in enumerate(parts[1:]):
            template += '{%d}' % k + part
        template = unescape(template)

        # 已经包过 Loc.t/Loc.f 的调用：**不重写，但照样收进表**。
        # （否则手写的 `Loc.t("设置…")` 永远进不了 .strings，en 下会悄悄回落成中文。）
        if re.search(r'Loc\.(t|f)\(\s*$', prefix):
            found.append((template, []))
            out.append(raw)
            continue

        found.append((template, [arg_expr(a) for a in args]))
        call = 'Loc.t("%s"' % escape(template)
        if args:
            call += ', ' + ', '.join(arg_expr(a) for a in args)
        out.append(call + ')')
    return ''.join(out), found


def main() -> int:
    write = '--write' in sys.argv
    catalog: dict[str, set[str]] = {}
    changed_files = 0
    occurrences = 0
    for target in TARGETS:
        for path in sorted((ROOT / 'Sources' / target).rglob('*.swift')):
            if path.name in SKIP_FILES or path.name.endswith(SKIP_SUFFIX):
                continue
            text = path.read_text(encoding='utf-8')
            new, found = scan(text, str(path))
            for template, _ in found:
                catalog.setdefault(template, set()).add(str(path.relative_to(ROOT)))
            if not found:
                continue
            occurrences += len(found)
            changed_files += 1
            rel = path.relative_to(ROOT)
            print('%4d  %s' % (len(found), rel))
            if write:
                if 'import PhotonsLocalization' not in new:
                    new = 'import PhotonsLocalization\n' + new
                path.write_text(new, encoding='utf-8')

    zh_path = RES / 'zh-Hans.lproj/Localizable.strings'
    en_path = RES / 'en.lproj/Localizable.strings'
    existing_en = {}
    if en_path.exists():
        for line in en_path.read_text(encoding='utf-8').splitlines():
            m = re.fullmatch(r'"((?:[^"\\]|\\.)*)" = "(.*)";', line)
            if m:
                existing_en[unescape(m.group(1))] = unescape(m.group(2))

    new_keys = sorted(k for k in catalog if k not in existing_en)
    print('\n模板 %d 个（已有译文 %d，缺译文 %d）· 改写 %d 处 / %d 文件'
          % (len(catalog), len(catalog) - len(new_keys), len(new_keys), occurrences, changed_files))
    for k in new_keys[:20]:
        print('  缺译文: %s' % k[:90])

    if write:
        RES.mkdir(parents=True, exist_ok=True)
        both = dict(existing_en)
        for k in catalog:
            both.setdefault(k, '')
        order = sorted(both)
        for lang in ('zh-Hans', 'en'):
            d = RES / ('%s.lproj' % lang)
            d.mkdir(parents=True, exist_ok=True)
            with open(d / 'Localizable.strings', 'w', encoding='utf-8') as f:
                f.write('/* Photons — key 是中文原文；本文件由 scripts/localization/extract_zh.py 维护。 */\n\n')
                for k in order:
                    value = k if lang == 'zh-Hans' else both[k]
                    f.write('"%s" = "%s";\n' % (escape(k), escape(value)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
