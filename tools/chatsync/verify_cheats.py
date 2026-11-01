#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""校验 cheats/ 产物: 汇总 + 抽样, 结果写入 UTF-8 文本便于查看。"""
import os, json, io

GSTEST = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                      '..', '..', '.tools', 'gstest'))
CH = os.path.join(GSTEST, 'cheats')
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'verify_report.txt')

buf = io.StringIO()
w = buf.write

with open(os.path.join(CH, 'report.json'), 'r', encoding='utf-8') as f:
    rep = json.load(f)

w('=== 汇总 ===\n')
w('ROM 总数        : %d\n' % rep['romsTotal'])
w('命中(已生成 .cht): %d\n' % rep['matched'])
w('无金手指        : %d\n' % rep['missing'])
w('孤立金手指      : %d\n' % rep['orphans'])
w('命令总数        : %d\n' % rep['commandsTotal'])
w('\n=== 分平台 ===\n')
for p, v in sorted(rep['byPlatform'].items()):
    w('  %-8s 命中 %3d / %3d\n' % (p, v['matched'], v['total']))

w('\n=== 孤立金手指(无对应游戏, 已保留到 _orphans/) ===\n')
for o in sorted(rep['orphanList'], key=lambda x: (x['kind'], x['name'])):
    w('  [%-6s] %s\n' % (o['kind'], o['name']))

w('\n=== 命中抽样(前 8) ===\n')
for m in rep['matchedList'][:8]:
    w('  %-28s %-7s crc=%s  %d 条  <- %s\n'
      % (m['rom'], m['platform'], m['crc'], m['cheats'], m['source']))

# 实际文件一致性
files = [f for f in os.listdir(CH) if f.endswith('.cht')]
w('\n=== 磁盘 ===\n')
w('  cheats/*.cht 实际数量: %d (报告命中 %d)\n' % (len(files), rep['matched']))

sample = sorted(files)[0]
with open(os.path.join(CH, sample), 'r', encoding='utf-8') as f:
    txt = f.read()
w('\n=== 抽样 .cht 内容: %s ===\n' % sample)
w(txt[:700])

# cheats.json 结构
with open(os.path.join(CH, 'cheats.json'), 'r', encoding='utf-8') as f:
    cj = json.load(f)
w('\n=== cheats.json ===\n')
w('  version=%s  byCrc 键数=%d\n' % (cj.get('version'), len(cj.get('byCrc', {}))))
k = sorted(cj['byCrc'])[0]
w('  首键=%s  命令数=%d\n' % (k, len(cj['byCrc'][k])))
w('  首条=%s\n' % json.dumps(cj['byCrc'][k][0], ensure_ascii=False))

# _orphans
od = os.path.join(CH, '_orphans')
if os.path.isdir(od):
    w('\n=== _orphans ===\n')
    w('  文件数: %d\n' % len(os.listdir(od)))

with open(OUT, 'w', encoding='utf-8') as f:
    f.write(buf.getvalue())
print('written: %s' % OUT)
