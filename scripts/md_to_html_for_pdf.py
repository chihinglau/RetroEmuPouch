#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把软著文档鉴别材料(Markdown)转成带打印样式的 HTML，便于用 Edge 无头打印为 PDF。

分页策略（与「源程序鉴别材料」一致，避免 fixed 页眉在 Edge 分页时与正文重叠）：
- 按估算行数把内容切成每页约 PAGE_LINES 行的 .page 块；
- 每个 .page 顶部是一个普通文档流的 .head（flex 左右布局，不会塌陷重叠）；
- 页眉含软件名称+版本号，右上角为「第 X 页 / 共 N 页」。
- 行距/字号保证每打印页约 30+ 行；含图页天然较少(合规允许)。
"""
import os
import re
import html
import base64

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "docs", "soft-copyright", "02_用户操作手册.md")
OUT = os.path.join(ROOT, "docs", "soft-copyright", "用户操作手册.html")

SOFT_NAME = "趣玩匣(RetroEmuPouch)复古游戏模拟器软件"
VERSION = "V1.8.4"
PAGE_LINES = 36          # 每页目标行数（留出页眉与余量，实际 30~45 行均合规）
CHARS_PER_LINE = 40      # A4 正文宽度约可容纳的 CJK 字符数（估算用）


def inline(t):
    t = html.escape(t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", t)
    return t


def weight_of(tag, text):
    """估算一个块占多少“行”。"""
    if tag == "h1":
        return 3
    if tag in ("h2", "h3"):
        return 2
    if tag == "hr":
        return 1
    if tag == "code":
        return max(1, text.count("\n") + 1)
    if tag in ("ul", "ol"):
        # text 内含每个 <li>，按条目数估算
        n = text.count("<li>")
        return max(1, n) + 1
    if tag == "blockquote":
        return max(1, (len(re.sub(r"<[^>]+>", "", text)) // CHARS_PER_LINE) + 1)
    # p / default
    plain = re.sub(r"<[^>]+>", "", text)
    return max(1, (len(plain) // CHARS_PER_LINE) + 1)


def convert(md):
    """返回 [(html, weight), ...] 块列表。"""
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
            out.append(("<hr/>", weight_of("hr", "")))
            i += 1
            continue
        if ln.startswith("### "):
            t = inline(ln[4:]); out.append(("<h3>%s</h3>" % t, weight_of("h3", t)))
            i += 1; continue
        if ln.startswith("## "):
            t = inline(ln[3:]); out.append(("<h2>%s</h2>" % t, weight_of("h2", t)))
            i += 1; continue
        if ln.startswith("# "):
            t = inline(ln[2:]); out.append(("<h1>%s</h1>" % t, weight_of("h1", t)))
            i += 1; continue
        if ln.startswith(">"):
            buf = []
            while i < n and lines[i].startswith(">"):
                buf.append(inline(lines[i][1:].strip())); i += 1
            blk = "<blockquote>%s</blockquote>" % " ".join(buf)
            out.append((blk, weight_of("blockquote", blk))); continue
        if re.match(r"^\s*[-*]\s+", ln):
            buf = []
            while i < n and re.match(r"^\s*[-*]\s+", lines[i]):
                buf.append("<li>%s</li>" % inline(re.sub(r"^\s*[-*]\s+", "", lines[i]))); i += 1
            blk = "<ul>%s</ul>" % "".join(buf)
            out.append((blk, weight_of("ul", blk))); continue
        if re.match(r"^\s*\d+\.\s+", ln):
            buf = []
            while i < n and re.match(r"^\s*\d+\.\s+", lines[i]):
                buf.append("<li>%s</li>" % inline(re.sub(r"^\s*\d+\.\s+", "", lines[i]))); i += 1
            blk = "<ol>%s</ol>" % "".join(buf)
            out.append((blk, weight_of("ol", blk))); continue
        m = re.match(r"^!\[([^\]]*)\]\(([^)]+)\)$", ln.strip())
        if m:
            cap, rel = m.group(1), m.group(2)
            img_path = os.path.join(os.path.dirname(SRC), rel)
            with open(img_path, "rb") as f:
                b64 = base64.b64encode(f.read()).decode("ascii")
            blk = ('<figure class="fig"><img src="data:image/jpeg;base64,%s"/>'
                   '<figcaption>%s</figcaption></figure>' % (b64, html.escape(cap)))
            out.append((blk, 24))   # 58mm 宽竖屏截图约 131mm 高 ≈ 23 行 + 图注
            i += 1; continue
        buf = [inline(ln.strip())]; i += 1
        while i < n and lines[i].strip() != "" and not lines[i].startswith(("#", ">", "-", "*")) \
                and not re.match(r"^\s*\d+\.\s+", lines[i]) and lines[i].strip() != "---":
            buf.append(inline(lines[i].strip())); i += 1
        blk = "<p>%s</p>" % " ".join(buf)
        out.append((blk, weight_of("p", blk)))
    return out


def paginate(blocks):
    pages = []
    cur = []
    cur_w = 0
    for blk, w in blocks:
        # 单个块自身就超页也允许（整块落一页）
        if cur and cur_w + w > PAGE_LINES:
            pages.append(cur); cur = []; cur_w = 0
        cur.append(blk); cur_w += w
    if cur:
        pages.append(cur)
    return pages


def main():
    with open(SRC, "r", encoding="utf-8") as f:
        md = f.read()
    blocks = convert(md)
    pages = paginate(blocks)
    total = len(pages)

    head_tmpl = ('<div class="head"><span class="name">%s  %s</span>'
                 '<span class="pg">第 %d 页 / 共 %d 页</span></div>')

    parts = []
    parts.append("""<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>%s 用户操作手册</title>
<style>
@page { size: A4; margin: 16mm 14mm; }
* { box-sizing: border-box; }
body { font-family: "Microsoft YaHei", "SimSun", "Songti SC", serif; font-size: 11pt; line-height: 1.5; color: #000; }
.page { page-break-after: always; }
.page:last-child { page-break-after: auto; }
.head { display: flex; justify-content: space-between; align-items: baseline;
  border-bottom: 1px solid #000; padding-bottom: 2px; margin-bottom: 4px; font-size: 9pt; }
h1 { font-size: 17pt; text-align: center; margin: 4mm 0 3mm; }
h2 { font-size: 13pt; margin: 4mm 0 2mm; border-left: 4px solid #000; padding-left: 6px; }
h3 { font-size: 11.5pt; margin: 3mm 0 1mm; }
p { margin: 1.2mm 0; text-align: justify; }
ul, ol { margin: 1.2mm 0; padding-left: 22px; }
li { margin: 0.8mm 0; }
blockquote { border-left: 3px solid #999; margin: 1.5mm 0; padding: 1mm 6px; color: #333; background: #f6f6f6; }
code { background: #eee; padding: 0 3px; border-radius: 3px; font-family: Consolas, monospace; }
hr { border: none; border-top: 1px solid #000; margin: 3mm 0; }
.fig { text-align: center; margin: 2mm 0 3mm; page-break-inside: avoid; }
.fig img { width: 58mm; border: 1px solid #999; }
.fig figcaption { font-size: 9pt; margin-top: 1mm; }
img { max-width: 100%%; }
</style></head><body>""" % html.escape(SOFT_NAME))

    for idx, pg in enumerate(pages, 1):
        parts.append('<div class="page">%s%s</div>' % (
            head_tmpl % (html.escape(SOFT_NAME), VERSION, idx, total),
            "".join(pg)))

    parts.append("</body></html>")
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))
    print("wrote", OUT, "pages=", total)


if __name__ == "__main__":
    main()
