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


def _inside_print(text: str, pos: int) -> bool:
    """`pos` 处这个字符串字面量是否在某个尚未闭合的 `print(` 调用里。

    从 `pos` 往回找最后一个 `print(`，然后从它的开括号扫到 `pos`，数括号深度：
    深度仍 > 0 就说明字面量还在这次调用内（跨行拼接串因此也能挡住）。
    往回最多找 4000 字符，足够覆盖一个长的 `print(String(format: ...))`。
    """
    window_start = max(0, pos - 4000)
    window = text[window_start:pos]
    m = None
    for m in re.finditer(r'\bprint\s*\(', window):
        pass
    if m is None:
        return False
    depth = 0
    i = window_start + m.end() - 1     # 指向那个 '('
    n = len(text)
    while i < pos and i < n:
        ch = text[i]
        if ch == '"':                  # 跳过字符串字面量内部
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
        elif ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
            if depth == 0:
                return False           # 这次 print 已在 pos 之前闭合
        i += 1
    return depth > 0


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
        # `print(...)` 是诊断输出，不是界面文案 —— 不进表、也不包 `Loc.t`。
        # （2026-11-18: 505 搬 422 时，`LoupeController.autoLight()` 里那个跨行的
        #  `print(String(format: \"…\" + \"…\" + \"…\", …))` 被拆开包装，第二三段进了「缺译文」。
        #  只查「本行有没有 print(」不够 —— 拼接串的第二行、第三行看不见 print。）
        # 判法：从该字面量往回找最近的 `print(`，再看它的括号到本字面量处是否还没闭合。
        if _inside_print(text, start):
            out.append(raw)
            continue
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
    skipped_texts: dict[Path, str] = {}
    changed_files = 0
    occurrences = 0
    for target in TARGETS:
        for path in sorted((ROOT / 'Sources' / target).rglob('*.swift')):
            if path.name in SKIP_FILES or path.name.endswith(SKIP_SUFFIX):
                # 被跳过的文件**不重写**（验收探针要钉死中文原文）。但它们里面出现的
                # 中文字面量如果**表里已有**，那就是真实界面文案的复用，不能当死条目删掉。
                # 2026-11-18 实测：`EffectsRowProbe.swift:20` 的 `static let cardID = "效果卡"`
                # 是 `Loc.t("效果卡")` 的同一文案，删了它
                # `LocalizationTableTests.testEnglishTakesEffectThroughTheEnvironmentSwitch` 就红。
                #
                # 注意：**只做「保留」不做「新增」** —— 探针里还有断言串、诊断串，
                # 整文件扫进 catalog 会多收 200 条噪音（实测 928 → 1130）。
                skipped_texts[path] = path.read_text(encoding='utf-8')
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
    # 死条目：表里有、源码里已经没有的 key。**必须剔掉**，否则 `both` 会把它原样写回，
    # 表就只增不减（2026-11-18 实测：511 建表时源码 927 条模板却写出 1541 条，
    # 多出的 614 条来自 PR1 的 catalog.json，一次污染之后每跑一次脚本都继承下来）。
    # 「被跳过文件里出现过」的已有条目不算死条目（见上面 skipped_texts 的说明）。
    revived = set()
    for k in set(existing_en) - set(catalog):
        if any(k in text for text in skipped_texts.values()):
            revived.add(k)
    if revived:
        print('\n保留 %d 条「仅出现在被跳过文件里」的条目（探针复用真实文案，不是死条目）' % len(revived))
        for k in sorted(revived)[:10]:
            print('    留: %s' % k[:90])
    dead_keys = sorted(set(existing_en) - set(catalog) - revived)
    print('\n模板 %d 个（已有译文 %d，缺译文 %d，死条目 %d）· 改写 %d 处 / %d 文件'
          % (len(catalog), len(catalog) - len(new_keys), len(new_keys),
             len(dead_keys), occurrences, changed_files))
    for k in new_keys[:20]:
        print('  缺译文: %s' % k[:90])
    if dead_keys:
        print('  死条目 %d 条（源码里已无此文案，--write 时会从两张表删掉）' % len(dead_keys))
        for k in dead_keys[:10]:
            print('    死: %s' % k[:90])

    if write:
        RES.mkdir(parents=True, exist_ok=True)
        # 只写「源码里还存在的模板」—— 这正是上一步算出的 dead_keys 的反面。
        # 旧写法 `both = dict(existing_en); for k in catalog: both.setdefault(k, '')`
        # 把表里每一条都留下，于是死条目永远删不掉。
        both = {}
        for k in catalog:
            both[k] = existing_en.get(k, '')
        for k in revived:
            both[k] = existing_en.get(k, k)
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
