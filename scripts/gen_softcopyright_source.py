#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成软著「源程序鉴别材料」(一般交存)。

规则(中国版权保护中心)：
  - 提交源程序连续的前 30 页和连续的最后 30 页；不足 60 页的，提交全部源程序。
  - 每页有效代码行不少于 50 行；页眉标注软件名称与版本号，右上角标注页码。
  - 源程序指申请人自己开发的代码，不含第三方库(本工程 third_party/ 已排除)。

注意(2026-11-07)：LINES_PER_PAGE 由 50 提到 60。原按 50 个物理行/页排版时，
源码里的空行在 PDF 文本层不产生文字，若审查口径为「去掉非代码空行后每页 ≥50 行」，
实测 60 页里有 31 页会被判不足。改为 60 个物理行/页后，即便某页含 10 个空行，
有效代码行仍 ≥50；A4 纵向(8.2pt / 1.18 行高)可容纳，不影响 60 页交存规则。

输出：docs/soft-copyright/源程序鉴别材料.html
用法：py scripts/gen_softcopyright_source.py
然后用 Chrome / Edge / WPS 打开该 HTML，「打印 -> 另存为 PDF」(A4、纵向、默认边距)。
"""
import os
import html
import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "app")

# 与「软件著作权登记申请表」中的软件名称/版本号必须完全一致
SOFT_NAME = "趣玩匣(RetroEmuPouch)复古游戏模拟器软件"
VERSION = "V1.8.4"
LINES_PER_PAGE = 60

# 自有源码范围(排除构建产物与第三方)
INCLUDES = [
    (os.path.join(APP, "lib"), [".dart"]),
    (os.path.join(APP, "ohos", "entry", "src", "main", "cpp"), [".cpp", ".h", ".hpp", ".c"]),
    (os.path.join(APP, "ohos", "entry", "src", "main", "ets"), [".ets"]),
    (os.path.join(APP, "android"), [".kt", ".java"]),
]
EXCLUDE_DIRS = ["build", ".dart_tool", ".gradle", "ohosTest", "generated", "captures", "release"]


def collect():
    files = []
    for base, exts in INCLUDES:
        if not os.path.isdir(base):
            continue
        for root, dirs, names in os.walk(base):
            dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
            for n in sorted(names):
                if any(n.endswith(e) for e in exts):
                    files.append(os.path.join(root, n))
    return sorted(files)


def main():
    files = collect()
    lines = []
    for f in files:
        rel = os.path.relpath(f, ROOT).replace("\\", "/")
        lines.append("// ===== FILE: %s =====" % rel)
        try:
            with open(f, "r", encoding="utf-8", errors="replace") as fh:
                for ln in fh.read().splitlines():
                    lines.append(ln)
        except Exception as e:  # noqa
            lines.append("// read error: %s" % e)
        lines.append("")  # 文件间空行

    pages = [lines[i:i + LINES_PER_PAGE] for i in range(0, len(lines), LINES_PER_PAGE)]
    # 末尾不足 10 行的残页并入前一页：否则「连续最后 30 页」里会出现一张只有
    # 页眉的空白页（2026-11-07 实测 39661 = 661*60 + 1 时第 60 页全空），
    # 空白页会被要求补正。合并后该页 61 行，A4 仍可容纳且有效行 ≥50。
    if len(pages) > 1 and len(pages[-1]) < 10:
        pages[-2].extend(pages[-1])
        pages.pop()
    total = len(pages)
    if total <= 60:
        sel = list(range(total))
    else:
        sel = list(range(30)) + list(range(total - 30, total))

    out_dir = os.path.join(ROOT, "docs", "soft-copyright")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, "源程序鉴别材料.html")

    parts = []
    parts.append("""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>%s 源程序鉴别材料</title>
<style>
@page { size: A4; margin: 15mm 13mm; }
* { box-sizing: border-box; }
body { font-family: "Courier New", Consolas, monospace; font-size: 8.2pt; line-height: 1.18; color: #000; }
.page { page-break-after: always; }
.page:last-child { page-break-after: auto; }
.head { display: flex; justify-content: space-between; align-items: baseline;
  border-bottom: 1px solid #000; padding-bottom: 2px; margin-bottom: 4px; font-size: 8pt; }
pre { white-space: pre; margin: 0; font-family: inherit; }
</style></head><body>""" % html.escape(SOFT_NAME))

    for idx, pno in enumerate(sel, 1):
        chunk = pages[pno]
        body = html.escape("\n".join(chunk))
        parts.append(
            '<div class="page">'
            '<div class="head"><span class="name">%s  %s</span>'
            '<span class="pg">第 %d 页 / 共 %d 页（源程序实际 %d 页）</span></div>'
            '<pre>%s</pre></div>' % (
                html.escape(SOFT_NAME), VERSION, idx, len(sel), total, body))

    parts.append("</body></html>")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write("\n".join(parts))
    print("files=%d  total_lines=%d  pages=%d  selected=%d -> %s" %
          (len(files), len(lines), total, len(sel), out))


if __name__ == "__main__":
    main()
