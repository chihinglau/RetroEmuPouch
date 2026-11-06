#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把「许可明确、允许商用再分发」的开源 ROM 从 GamePouch 引入本项目。

设计要点（隔离管控）：
- 本项目 .tools/ 是指向 GamePouch/.tools 的 junction（共享），故不使用它；
- 素材本体集中到项目根下独立目录 freeroms/，由 .gitignore 排除，不入库、不进包；
- 授权留痕写入 docs/freeroms/，入库，供软著/法务审阅；
- 只复制 manifest 中 commercial_use 以 commercial:yes 开头的条目，
  授权未取得的 UniBIOS(15)、unknown 的 minicraft-gba_2.0.zip 一律不引入。

用法：py scripts/import_freeroms.py
"""
import os
import re
import json
import shutil
import hashlib

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = r"D:\ai\prj\trae\HuaWei\GamePouch\.tools\freeroms"
DST = os.path.join(REPO, "freeroms")
DOC = os.path.join(REPO, "docs", "freeroms")
GITIGNORE = os.path.join(REPO, ".gitignore")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_gitignore():
    raw = open(GITIGNORE, "rb").read()
    enc = None
    for cand in ("utf-8-sig", "utf-8", "gbk"):
        try:
            raw.decode(cand)
            enc = cand
            break
        except UnicodeDecodeError:
            continue
    if enc is None:
        raise RuntimeError("cannot decode .gitignore")
    text = raw.decode(enc)
    if "/freeroms/" in text:
        return "already present"
    block = (
        "\n# ===== 开源 ROM 素材本体：独立目录集中存放，隔离管控，不入库、不进安装包 =====\n"
        "# 留痕与许可证见 docs/freeroms/（入库）；复现方式见 docs/freeroms/NOTICE.md\n"
        "/freeroms/\n"
    )
    with open(GITIGNORE, "wb") as f:
        f.write((text.rstrip("\r\n") + "\n" + block).encode(enc))
    return "added (/freeroms/)"


def main():
    manifest = json.load(open(os.path.join(SRC, "_manifest.json"), encoding="utf-8-sig"))

    # 只保留授权明确、允许商用再分发的条目
    keep = [e for e in manifest
            if e.get("commercial_use", "").startswith("commercial:yes")]
    skipped = [e for e in manifest if e not in keep]

    for sub in ("nes", "gba", "bios", "_licenses"):
        os.makedirs(os.path.join(DST, sub), exist_ok=True)
    os.makedirs(os.path.join(DOC, "licenses"), exist_ok=True)

    records = []
    sums = []
    for e in keep:
        rel = e["path"].replace("/", os.sep)
        src = os.path.join(SRC, rel)
        if not os.path.isfile(src):
            raise RuntimeError("missing source: " + src)
        actual = sha256(src)
        if actual.lower() != e["sha256"].lower():
            raise RuntimeError("sha256 mismatch: " + rel)
        if os.path.getsize(src) != e["bytes"]:
            raise RuntimeError("size mismatch: " + rel)
        dst = os.path.join(DST, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)
        rec = dict(e)
        rec["path"] = "freeroms/" + e["path"]
        rec["verified_sha256"] = actual
        records.append(rec)
        sums.append("%s  freeroms/%s" % (actual, e["path"]))

    # 许可证原文：本体目录 + 留痕目录各一份
    lic_src = os.path.join(SRC, "_licenses")
    lic_names = sorted(os.listdir(lic_src))
    for name in lic_names:
        s = os.path.join(lic_src, name)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(DST, "_licenses", name))
            shutil.copy2(s, os.path.join(DOC, "licenses", name))

    with open(os.path.join(DST, "SHA256SUMS.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(sums) + "\n")
    with open(os.path.join(DOC, "SHA256SUMS.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(sums) + "\n")

    doc = {
        "_note": "RetroEmuPouch 收录的开源/自由素材留痕清单；仅列授权明确、允许商用再分发者。"
                 "素材本体位于项目根 freeroms/（.gitignore 排除，不入库、不进安装包）。",
        "_source_project": "GamePouch (D:/ai/prj/trae/HuaWei/GamePouch) .tools/freeroms",
        "_excluded": [
            "UniBIOS 15 份：免费软件但授权文本未取得，仅本地测试，不引入、不分发",
            "minicraft-gba_2.0.zip：license=unknown，授权不可核验，不引入",
            "全部商业/街机 ROM dump、qsound.zip、pgm.zip、SNK 官方 BIOS：不引入",
        ],
        "items": records,
    }
    with open(os.path.join(DOC, "manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")
    with open(os.path.join(DST, "manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)
        f.write("\n")

    gi = ensure_gitignore()
    print("copied ROM items :", len(records))
    print("license texts    :", len(lic_names))
    print("skipped (unclear):", len(skipped))
    for s in skipped:
        print("  -", s["path"], "|", s.get("license"), "|", s.get("commercial_use"))
    print("gitignore        :", gi)


if __name__ == "__main__":
    main()
