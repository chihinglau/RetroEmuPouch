#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""一次性探测: 全库缺失金手指的游戏里, 联网能命中多少(只打分不下载)。"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import online_cheats as oc  # noqa: E402

ROOT = os.path.abspath(os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', '..', '.tools', 'gstest'))

games = oc.scan_missing(ROOT)
print('missing:', len(games))
idx = oc.ChtIndex(log=lambda s: None)
idx.ensure(sorted({g['platform'] for g in games}))

claims = {}
byplat = collections.Counter()
tot = collections.Counter()
samples = []
for g in games:
    tot[g['platform']] += 1
    cs = idx.search(g, limit=1)
    if cs and cs[0].score >= oc.SCORE_AUTO:
        c = cs[0]
        prev = claims.get(c.path)
        if prev is None or c.score > prev[0]:
            claims[c.path] = (c.score, g['stem'])
        byplat[g['platform']] += 1
        samples.append((g['stem'], c.name, c.score))

print('scored-hit: %d   unique-after-dedupe: %d'
      % (sum(byplat.values()), len(claims)))
for k in sorted(tot):
    print('  %-8s %3d / %3d' % (k, byplat[k], tot[k]))
print('\n样例:')
for s in samples[:25]:
    print('  %-28s -> %-52s %.0f' % s)
