#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对真实根目录做一次全量扫描, 验证完整数据路径并预热 CRC 缓存。"""
import io
import json
import os
import queue
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tkinter as tk  # noqa: E402
import library_manager as lm  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'prime_result.txt')
buf = io.StringIO()
w = buf.write

app = lm.App()
try:
    app.withdraw()
    root = app.root_dir.get()
    w('root = %s\n' % root)
    t0 = time.time()
    app._scan_worker(root, rescan=False)
    dt = time.time() - t0
    while True:
        try:
            m = app._q.get_nowait()
            if m[0] == 'phase1':
                app.games, app.bios, app.orphan_cheats = m[1], m[2], m[3]
        except queue.Empty:
            break
    w('scan worker elapsed: %.1f s\n' % dt)

    from collections import Counter
    c = Counter(g['platform'] for g in app.games)
    w('games=%d by platform=%s\n' % (len(app.games), dict(c)))
    bad = [g for g in app.games if len(g.get('crc', '')) != 8]
    w('games missing CRC: %d\n' % len(bad))

    withc = [g for g in app.games if g['cheats']]
    w('games with cheats: %d  commands: %d\n'
      % (len(withc), sum(len(g['cheats']) for g in withc)))
    w('bios=%d orphans=%d\n' % (len(app.bios), len(app.orphan_cheats)))

    app._after_phase1()
    w('table rows=%d cheat rows=%d bios rows=%d\n'
      % (len(app.tv_games.get_children()),
         len(app.tv_cheats.get_children()),
         len(app.tv_bios.get_children())))

    # 与 sync_cheats 写出的 report.json 对照
    rp = os.path.join(root, 'cheats', 'report.json')
    if os.path.isfile(rp):
        with open(rp, 'r', encoding='utf-8') as f:
            rep = json.load(f)
        w('\n[对照 report.json] matched=%d  missing=%d  orphans=%d\n'
          % (rep['matched'], rep['missing'], rep['orphans']))
        w('  管理器关联到的有金手指游戏数 = %d  ->  %s\n'
          % (len(withc), '一致' if len(withc) == rep['matched'] else '不一致!'))
finally:
    app.destroy()

with open(OUT, 'w', encoding='utf-8') as f:
    f.write(buf.getvalue())
print('written: %s' % OUT)
