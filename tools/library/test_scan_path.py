#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""小规模端到端验证: 后台扫描线程 + CRC 缓存 + 按文件名关联金手指。"""
import io
import json
import os
import queue
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tkinter as tk  # noqa: E402
import library_manager as lm  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'scan_path_result.txt')
buf = io.StringIO()
w = buf.write

SRC = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   '..', '..', '.tools', 'gstest'))
tmp = tempfile.mkdtemp(prefix='gslib_')
try:
    # 构造小规模根目录: 12 个 NES(小文件) + bios + chats
    nes_src = os.path.join(SRC, 'roms', 'NES')
    tmp_nes = os.path.join(tmp, 'roms', 'NES')
    os.makedirs(tmp_nes)
    names = sorted(os.listdir(nes_src))[:12]
    for n in names:
        shutil.copy2(os.path.join(nes_src, n), os.path.join(tmp_nes, n))

    tmp_bios = os.path.join(tmp, 'bios')
    os.makedirs(tmp_bios)
    for n in sorted(os.listdir(os.path.join(SRC, 'bios'))):
        shutil.copy2(os.path.join(SRC, 'bios', n), os.path.join(tmp_bios, n))

    # 只放 5 个 chats, 避免孤立数被放大
    tmp_ch = os.path.join(tmp, 'chats')
    os.makedirs(tmp_ch)
    src_ch = os.path.join(SRC, 'chats')
    for n in sorted(os.listdir(src_ch))[:5]:
        if n.lower().endswith('.cht'):
            shutil.copy2(os.path.join(src_ch, n), os.path.join(tmp_ch, n))

    app = lm.App()
    try:
        app.withdraw()
        app.root_dir.set(tmp)
        app.crc_cache = {}
        app._q = queue.Queue()

        # 跑真实 worker, 再按 _pump 的方式消费队列(phase1 会装填 self.games)
        app._scan_worker(tmp, rescan=True)
        msgs = []
        while True:
            try:
                msgs.append(app._q.get_nowait())
            except queue.Empty:
                break
        kinds = [m[0] for m in msgs]
        w('worker messages: %s\n' % kinds)
        for m in msgs:
            if m[0] == 'phase1':
                app.games, app.bios, app.orphan_cheats = m[1], m[2], m[3]
        w('collect: games=%d bios=%d orphans=%d\n'
          % (len(app.games), len(app.bios), len(app.orphan_cheats)))

        # 缓存文件是否落盘且可回填
        cache_file = app._cache_path()
        w('cache file exists: %s\n' % os.path.isfile(cache_file))
        if os.path.isfile(cache_file):
            with open(cache_file, 'r', encoding='utf-8') as f:
                raw = json.load(f)
            w('cache entries: %d\n' % len(raw))

        w('\n--- 12 个 NES 的 CRC(应为 8 位大写十六进制) ---\n')
        ok = True
        for g in app.games:
            c = g.get('crc', '')
            good = len(c) == 8 and all(ch in '0123456789ABCDEF' for ch in c)
            if not good:
                ok = False
            w('  %-42s crc=%s  size=%d\n'
              % (g['stem'], c or '(空)', g['size']))
        w('all CRC valid: %s\n' % ok)

        # 二次扫描应命中缓存(不再重算)
        before = len(app.crc_cache)
        app.crc_cache = {}
        app._load_crc_cache()
        w('cache reload entries: %d (写入 %d)\n' % (len(app.crc_cache), before))
        app._scan_worker(tmp, rescan=False)
        while True:
            try:
                m = app._q.get_nowait()
                if m[0] == 'phase1':
                    app.games = m[1]
            except queue.Empty:
                break
        w('rescan=False 重跑后 CRC 仍有效: %s\n'
          % all(len(g.get('crc', '')) == 8 for g in app.games))

        app._after_phase1()
        w('table rows: %d\n' % len(app.tv_games.get_children()))
    finally:
        app.destroy()
finally:
    shutil.rmtree(tmp, ignore_errors=True)

with open(OUT, 'w', encoding='utf-8') as f:
    f.write(buf.getvalue())
print('written: %s' % OUT)
