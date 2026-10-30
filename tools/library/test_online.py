#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""online_cheats 自测: 打分函数 + 真实索引检索 + 落地(写入临时目录)。"""
from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

import online_cheats as oc  # noqa: E402

ROOT = os.path.abspath(os.path.join(_HERE, '..', '..', '.tools', 'gstest'))
FAIL = []


def check(name, cond, extra=''):
    print(('  OK   ' if cond else '  FAIL ') + name + ('  ' + extra if extra else ''))
    if not cond:
        FAIL.append(name)


print('== 1. 打分函数 ==')
cases = [
    ('CTSPECIALF', 'CTSPECIALFORCES', True),
    ('1944', '1944', True),
    ('SUPERMARIOBROS', 'SUPERMARIOBROS', True),
    ('METROID', 'METROIDZERO', False),   # 短名只认全等, 避免续作错配
    ('AAAA', 'ZZZZ', False),
]
for a, b, hi in cases:
    s = oc.score_pair(a, b)
    check('score(%s,%s)=%.1f' % (a, b, s), (s >= oc.SCORE_AUTO) == hi)

print('\n== 2. title_norm ==')
check('去括号', oc.title_norm('CT Special Forces (USA) (Code Breaker)')
      == 'CTSPECIALFORCES')
check('去副标题', oc.title_norm('Metal Slug - Super Vehicle (Rev A)')
      == 'METALSLUG')
check('去扩展名', oc.title_norm('1944.zip') == '1944')

print('\n== 3. 真实索引(GitHub) ==')
idx = oc.ChtIndex(log=lambda s: print('   ·', s))
n = idx.ensure(['gba', 'nes', 'neogeo', 'cps1', 'cps2'])
check('索引文件总数 > 1000', n > 1000, 'n=%d' % n)
for d, lst in sorted(idx.dirs.items()):
    print('   %-52s %5d' % (d, len(lst)))

print('\n== 4. 检索若干缺失游戏 ==')
probes = [
    {'stem': 'CT Special Forces', 'internal': 'CT SPECIAL F',
     'platform': 'gba'},
    {'stem': '1944', 'internal': '', 'platform': 'cps1'},
    {'stem': 'mslug', 'internal': '', 'platform': 'neogeo'},
    {'stem': 'Super Mario Bros.', 'internal': '', 'platform': 'nes'},
    {'stem': 'zzzz-not-a-real-game-xyz', 'internal': '', 'platform': 'gba'},
]
for g in probes:
    cs = idx.search(g, limit=2)
    top = cs[0] if cs else None
    print('   %-22s -> %s' % (g['stem'],
                              ('%s (%.0f)' % (top.name, top.score))
                              if top else '(无)'))
check('GBA 内部标题能命中', bool(idx.search(probes[0])), )
check('街机短名精确命中 mslug',
      (idx.search(probes[2]) or [None])[0] is not None)
check('街机短名不误命中 1944', not idx.search(probes[1]))
check('不存在的游戏不误命中',
      not idx.search(probes[4]) or idx.search(probes[4])[0].score < oc.SCORE_AUTO)

print('\n== 5. 下载 + 落地(临时目录) ==')
tmp = tempfile.mkdtemp(prefix='gp_online_')
try:
    os.makedirs(os.path.join(tmp, 'chats'), exist_ok=True)
    g = dict(probes[0])
    g['crc'] = 'DEADBEEF'
    g['path'] = ''
    cs = idx.search(g, limit=1)
    check('找到候选', bool(cs))
    if cs:
        text = idx.fetch_text(cs[0])
        check('下载到内容', 'cheat0_desc' in text, '%d 字节' % len(text))
        r = oc.adapt(tmp, g, text, source=cs[0].path)
        check('adapt 成功', r['ok'], str(r))
        cht = os.path.join(tmp, 'chats', 'CT Special Forces.cht')
        check('生成 .cht 文件', os.path.isfile(cht))
        with open(os.path.join(tmp, 'chats', 'cheats.json'), 'r',
                  encoding='utf-8') as f:
            j = json.load(f)
        check('cheats.json 按 CRC 键控', 'DEADBEEF' in j['byCrc'],
              '%d 条' % len(j['byCrc']['DEADBEEF']))
        check('回读可解析', len(oc.parse_cht_text(open(
            cht, encoding='utf-8').read())) == r['count'])
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print('\n== 6. scan_missing(本地库) ==')
miss = oc.scan_missing(ROOT, limit=0)
print('   缺金手指: %d' % len(miss))
check('能扫出缺失项', len(miss) > 0)

print('\n' + ('全部通过' if not FAIL else '失败: %s' % FAIL))
raise SystemExit(1 if FAIL else 0)
