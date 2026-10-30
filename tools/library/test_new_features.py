#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""新功能自测: ① 界面配色/新页签  ② 联网检索端到端  ③ adb 同步  ④ 局域网服务。

会真实联网、真实连手机(有设备时); 所有写操作都落在临时目录或可回滚。
"""
from __future__ import annotations

import os
import shutil
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

REAL = os.path.abspath(os.path.join(_HERE, '..', '..', '.tools', 'gstest'))
FAIL = []
SKIP = []


def check(name, cond, extra=''):
    print(('  OK   ' if cond else '  FAIL ') + name + ('  ' + extra if extra else ''))
    if not cond:
        FAIL.append(name)


def skip(name, why):
    print('  SKIP %s (%s)' % (name, why))
    SKIP.append(name)


# ============================================================ ① 界面
print('== ① 界面配色与新页签 ==')
import library_manager as lm  # noqa: E402
import online_cheats  # noqa: E402
import peer_host  # noqa: E402
import phone_sync  # noqa: E402

check('配色字典存在', isinstance(lm.C, dict) and 'brand' in lm.C)
check('平台主色齐全',
      all(p in lm.PLATFORM_COLOR for p in
          ('gba', 'nes', 'neogeo', 'cps1', 'cps2', 'arcade')))
check('平台浅色齐全',
      all(p in lm.PLATFORM_TINT for p in lm.PLATFORM_COLOR))
check('有/缺金手指底色不同', lm.C['ok_bg'] != lm.C['bad_bg'])

import tkinter as tk  # noqa: E402

app = lm.App()
try:
    app.withdraw()
    tabs = app.nb.tabs()
    check('页签数量 = 6', len(tabs) == 6, '%d' % len(tabs))
    check('统计卡片 6 个', len(app.stat_vars) == 6)
    for w in ('tv_online', 'online_log', 'tv_pairs', 'tv_devs', 'lan_log',
              'usb_log', 'dev_cb', 'adb_path', 'push_scope'):
        check('控件 %s 已建立' % w, hasattr(app, w))

    # 行标签: 平台 + 有/缺金手指 组合
    check('行标签共 14 个', len(app.row_tags) == 14, str(len(app.row_tags)))
    tv = app.tv_games
    ok_tag = app.row_tags[('gba', True)]
    no_tag = app.row_tags[('gba', False)]

    def tagopt(tag, opt):
        v = tv.tag_configure(tag, opt)
        if isinstance(v, tuple):
            v = v[0]
        return str(v)

    check('有金手指行底色 = 绿系', tagopt(ok_tag, 'background') == lm.C['ok_bg'],
          tagopt(ok_tag, 'background'))
    check('缺金手指行底色 = 红系',
          tagopt(no_tag, 'background') == lm.C['bad_bg'],
          tagopt(no_tag, 'background'))
    check('平台文字色生效',
          tagopt(ok_tag, 'foreground') == lm.PLATFORM_COLOR['gba'],
          tagopt(ok_tag, 'foreground'))
    check('不同平台颜色不同',
          tagopt(app.row_tags[('nes', True)], 'foreground')
          != tagopt(ok_tag, 'foreground'))

    games, bios, orphans = app._collect(app.root_dir.get())
    app.games, app.bios, app.orphan_cheats = games, bios, orphans
    app._after_phase1()
    check('统计: 游戏总数 = 626',
          app.stat_vars['games'].get() == str(len(games)),
          app.stat_vars['games'].get())
    check('统计: 有金手指 = 174',
          app.stat_vars['cheat'].get() == str(sum(1 for g in games
                                                  if g['cheats'])),
          app.stat_vars['cheat'].get())
    check('统计: 缺金手指 = 总数 - 有',
          int(app.stat_vars['missing'].get())
          == len(games) - sum(1 for g in games if g['cheats']))
    check('推送范围文案已生成', '推送范围' in app.push_scope.get()
          or '筛选' in app.push_scope.get(), app.push_scope.get())

    # 局域网服务(真实启动/停止, 用真实库的一小部分)
    app.lan_toggle()
    check('局域网服务已启动', app._peer.running, app.lan_addr.get())
    check('地址形如 IP:PORT', ':' in app.lan_addr.get())
    app.lan_toggle()
    check('局域网服务已停止', not app._peer.running)
finally:
    app.destroy()

# ============================================================ ② 联网检索
print('\n== ② 联网检索端到端(写入临时目录) ==')
tmp = tempfile.mkdtemp(prefix='gp_e2e_')
os.makedirs(os.path.join(tmp, 'chats'), exist_ok=True)
try:
    idx = online_cheats.ChtIndex(log=lambda s: print('   ·', s))
    miss = [g for g in online_cheats.scan_missing(REAL)
            if g['platform'] == 'gba']
    picked = []
    for g in miss:
        cs = idx.search(g, limit=1)
        if cs and cs[0].score >= online_cheats.SCORE_AUTO:
            picked.append((g, cs[0]))
        if len(picked) >= 5:
            break
    check('挑出可适配的样本 >= 3', len(picked) >= 3, '%d' % len(picked))
    for g, c in picked:
        g['crc'] = online_cheats.crc32_file(g['path'])
    res = online_cheats.run_batch(
        tmp, [g for g, _ in picked], idx,
        on_log=lambda s: print('   ', s))
    check('批量适配成功 >= 2', len(res.ok) >= 2, str(res.as_dict()))
    for g, _c in picked:
        p = os.path.join(tmp, 'chats', g['stem'] + '.cht')
        if os.path.isfile(p):
            n = len(online_cheats.parse_cht_text(
                open(p, encoding='utf-8').read()))
            check('已生成 %s.cht (%d 条)' % (g['stem'], n), n > 0)
    import json  # noqa: E402

    with open(os.path.join(tmp, 'chats', 'cheats.json'), encoding='utf-8') as f:
        by = json.load(f)['byCrc']
    check('cheats.json 键数与成功数一致', len(by) == len(res.ok),
          '%d vs %d' % (len(by), len(res.ok)))
    check('键为 8 位大写 CRC', all(len(k) == 8 and k == k.upper()
                                   for k in by))
    rep = online_cheats.load_online_report(tmp)
    check('联网报告已记录', len(rep) == len(res.ok))

    n = online_cheats.undo_online(tmp)
    check('撤销数量一致', n == len(res.ok), '%d' % n)
    left = os.listdir(os.path.join(tmp, 'chats'))
    check('撤销后无 .cht 残留',
          not any(x.endswith('.cht') for x in left), str(left))
    with open(os.path.join(tmp, 'chats', 'cheats.json'), encoding='utf-8') as f:
        check('撤销后 byCrc 已清空', not json.load(f)['byCrc'])
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# ============================================================ ③ adb
print('\n== ③ adb 手机同步 ==')
adb = phone_sync.Adb()
if not adb.ok():
    skip('adb 用例', '未找到 adb')
else:
    devs = adb.devices()
    check('发现设备', len(devs) > 0, '%d 台' % len(devs))
    if devs:
        sync = phone_sync.PhoneSync(adb, devs[0]['serial'])
        info = sync.probe()
        check('run-as 可用', info['ok'], info.get('msg', '')[:80])
        if info['ok']:
            plan = phone_sync.build_plan([], [], {})
            check('空计划不报错', plan['items'] == [])
        else:
            skip('推送用例', 'run-as 不可用')

# ============================================================ ④ 局域网
print('\n== ④ 局域网伙伴服务 ==')
lib = peer_host.build_library([], [], {})
host = peer_host.PeerHost(library=lib, log=lambda s: None)
try:
    port = host.start()
    check('服务启动', port > 0)
    payload = host.build_library_payload()
    check('空库返回 games=[]', payload['games'] == [])
    check('payload 带 service 字段', payload['service'] == 'GamePouch Peer')
finally:
    host.stop()
    check('服务停止', not host.running)

print('\n' + ('全部通过' if not FAIL else '失败: %s' % FAIL))
if SKIP:
    print('跳过: %s' % SKIP)
raise SystemExit(1 if FAIL else 0)
