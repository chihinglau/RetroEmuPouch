#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把软著文档鉴别材料(Markdown)转成带打印样式的 HTML，便于用 Edge 无头打印为 PDF。
- A4 纵向、固定页眉(软件名+版本号，每页重复)、CJK 字体。
- 行距/字号保证每打印页约 30+ 行；含图页天然少于 30 行(合规允许)。
"""
import os
import re
import html

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "docs", "soft-copyright", "02_用户操作手册.md")
OUT = os.path.join(ROOT, "docs", "soft-copyright", "用户操作手册.html")

SOFT_NAME = "趣玩匣(RetroEmuPouch)复古游戏模拟器软件"
VERSION = "V1.8.4"


def inline(t):
    t = html.escape(t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    return t


def convert(md):
    lines = md.splitlines()
    out = []
    i = 0
    n = len(lines)
    while i < n:
        ln = lines[i]
        if ln.strip() == "":
            i += 1
            continue
        if ln.strip() == "---":
            out.append("<hr/>")
            i += 1
            continue
        if ln.startswith("### "):
            out.append("<h3>%s</h3>" % inline(ln[4:]))
            i += 1
            continue
        if ln.startswith("## "):
            out.append("<h2>%s</h2>" % inline(ln[3:]))
            i += 1
            continue
        if ln.startswith("# "):
            out.append("<h1>%s</h1>" % inline(ln[2:]))
            i += 1
            continue
        if ln.startswith(">"):
            # blockquote, possibly multiple lines
            buf = []
            while i < n and lines[i].startswith(">"):
                buf.append(inline(lines[i][1:].strip()))
                i += 1
            out.append("<blockquote>%s</blockquote>" % " ".join(buf))
            continue
        if re.match(r"^\s*[-*]\s+", ln):
            buf = []
            while i < n and re.match(r"^\s*[-*]\s+", lines[i]):
                buf.append("<li>%s</li>" % inline(re.sub(r"^\s*[-*]\s+", "", lines[i])))
                i += 1
            out.append("<ul>%s</ul>" % "".join(buf))
            continue
        if re.match(r"^\s*\d+\.\s+", ln):
            buf = []
            while i < n and re.match(r"^\s*\d+\.\s+", lines[i]):
                buf.append("<li>%s</li>" % inline(re.sub(r"^\s*\d+\.\s+", "", lines[i])))
                i += 1
            out.append("<ol>%s</ol>" % "".join(buf))
            continue
        # plain paragraph (merge consecutive non-special lines)
        buf = [inline(ln.strip())]
        i += 1
        while i < n and lines[i].strip() != "" and not lines[i].startswith(("#", ">", "-", "*")) \
                and not re.match(r"^\s*\d+\.\s+", lines[i]) and lines[i].strip() != "---":
            buf.append(inline(lines[i].strip()))
            i += 1
        out.append("<p>%s</p>" % " ".join(buf))
    return "\n".join(out)


def main():
    with open(SRC, "r", encoding="utf-8") as f:
        md = f.read()
    body = convert(md)
    doc = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>%s 用户操作手册</title>
<style>
@page { size: A4; margin: 18mm 15mm; }
* { box-sizing: border-box; }
body { font-family: "Microsoft YaHei", "SimSun", "Songti SC", serif; font-size: 11pt; line-height: 1.55; color: #000; }
.fixed-head { position: fixed; top: -14mm; left: 0; right: 0; font-size: 9pt;
  border-bottom: 1px solid #000; padding-bottom: 2px; }
h1 { font-size: 17pt; text-align: center; margin: 6mm 0 4mm; }
h2 { font-size: 13pt; margin: 5mm 0 2mm; border-left: 4px solid #000; padding-left: 6px; }
h3 { font-size: 11.5pt; margin: 3mm 0 1mm; }
p { margin: 1.2mm 0; text-align: justify; }
ul, ol { margin: 1.2mm 0; padding-left: 22px; }
li { margin: 0.8mm 0; }
blockquote { border-left: 3px solid #999; margin: 1.5mm 0; padding: 1mm 6px; color: #333; background: #f6f6f6; }
code { background: #eee; padding: 0 3px; border-radius: 3px; font-family: Consolas, monospace; }
hr { border: none; border-top: 1px solid #000; margin: 3mm 0; }
img { max-width: 100%%; }
</style></head><body>
<div class="fixed-head">%s  %s</div>
%s
</body></html>""" % (html.escape(SOFT_NAME), html.escape(SOFT_NAME), VERSION, body)
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(doc)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
