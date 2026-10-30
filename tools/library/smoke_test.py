#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""冒烟测试: 构建 UI + 跑一遍采集逻辑, 验证无异常且数据合理。"""
import io
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tkinter as tk  # noqa: E402
import library_manager as lm  # noqa: E402

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   'smoke_result.txt')
buf = io.StringIO()
w = buf.write

app = lm.App()
try:
    app.withdraw()
    root = app.root_dir.get()
    w('root = %s\n' % root)
    games, bios, orphans = app._collect(root)
    w('games=%d  bios=%d  orphans=%d\n' % (len(games), len(bios), len(orphans)))

    from collections import Counter
    c = Counter(g['platform'] for g in games)
    w('by platform: %s\n' % dict(c))

    withc = [g for g in games if g['cheats']]
    w('games with cheats: %d\n' % len(withc))
    w('total commands: %d\n' % sum(len(g['cheats']) for g in withc))

    w('\n--- sample games with cheats ---\n')
    for g in withc[:8]:
        w('  %-24s %-7s %2d 条  internal=%s\n'
          % (g['stem'], g['platform'], len(g['cheats']), g['internal'] or '-'))

    w('\n--- BIOS ---\n')
    for b in bios:
        w('  %-14s %8s  %s\n' % (b['name'], lm.human_size(b['size']), b['desc']))

    w('\n--- sample orphans ---\n')
    for o in orphans[:6]:
        w('  %-46s %d 条\n' % (o['name'], len(o['cheats'])))

    # 表格/报告刷新路径(不计算 CRC)
    app.games, app.bios, app.orphan_cheats = games, bios, orphans
    app._after_phase1()
    app.refresh_table()
    app.refresh_cheat_tab()
    app.refresh_bios_tab()
    app.refresh_report()
    w('\nUI refresh OK\n')
    w('visible rows after filters: %d\n' % len(app.tv_games.get_children()))
    w('cheat tab rows: %d\n' % len(app.tv_cheats.get_children()))
    w('bios tab rows: %d\n' % len(app.tv_bios.get_children()))
finally:
    app.destroy()

with open(OUT, 'w', encoding='utf-8') as f:
    f.write(buf.getvalue())
print('written: %s' % OUT)
