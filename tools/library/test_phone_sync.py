#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""phone_sync 自测: adb 定位 / 设备列表 / 私有目录探测 / 真实推送 + 回滚。

需要一台 usb 调试已授权、且装了 debuggable 版趣玩匣的手机。
没有设备时前面的用例仍会跑(会明确跳过), 不算失败。
"""
from __future__ import annotations

import json
import os
import sys
import tempfile

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import phone_sync as ps  # noqa: E402

FAIL = []
SKIP = []


def check(name, cond, extra=''):
    print(('  OK   ' if cond else '  FAIL ') + name + ('  ' + extra if extra else ''))
    if not cond:
        FAIL.append(name)


def skip(name, why):
    print('  SKIP %s (%s)' % (name, why))
    SKIP.append(name)


print('== 0. 纯离线单元测试(无需设备) ==')

# --- safe_name: 保留中文, 只替换 Android 非法字符 ---
check('safe_name 保留中文', ps.safe_name('CT特种部队.gba') == 'CT特种部队.gba')
check('safe_name 保留空格/点/括号',
      ps.safe_name('成龙 (美版).nes') == '成龙 (美版).nes')
check('safe_name 替换非法字符',
      ps.safe_name('a/b\\c:d*e?f"g<h>i|j.k') == 'a_b_c_d_e_f_g_h_i_j.k')
check('safe_name 控制字符替换', ps.safe_name('foo\x01\x1fbar.zip') == 'foo_bar.zip')
check('safe_name 空/纯非法 -> rom', ps.safe_name('') == 'rom')
check('safe_name 纯非法 -> 下划线(合法文件名)', ps.safe_name('///') == '_')

# --- build_plan 需要真实文件(内部会读 CRC) ---
_td = tempfile.mkdtemp(prefix='gp_t0_')
_cn1 = os.path.join(_td, '上海.gba')
_cn2 = os.path.join(_td, '街霸2.zip')
with open(_cn1, 'wb') as f:
    f.write(b'GBA' + b'\0' * 50)
with open(_cn2, 'wb') as f:
    f.write(b'CPS' + b'\0' * 50)
# --- build_plan: 中文名原样进索引, 且不会变成下划线 ---
plan_cn = ps.build_plan(
    [{'path': _cn1, 'file': '上海.gba', 'platform': 'gba', 'crc': ''},
     {'path': _cn2, 'file': '街霸2.zip', 'platform': 'cps1', 'crc': ''}],
    [], {})
check('build_plan 含 2 个 ROM', len(plan_cn['items']) == 2, str(len(plan_cn['items'])))
check('build_plan 中文名进 name', plan_cn['items'][0].name == '上海.gba')
check('build_plan 中文名进 originalName',
      plan_cn['items'][0].to_entry()['originalName'] == '上海.gba')
check('build_plan rel 含真实中文名',
      plan_cn['items'][0].rel == 'roms/gba/上海.gba')
check('build_plan 街机子目录', plan_cn['items'][1].rel == 'roms/cps1/街霸2.zip')
check('build_plan 不再是下划线乱码',
      '_' not in plan_cn['items'][0].name)

# --- build_plan: 同一目录内重名去重(追加 (n)) ---
_d1 = os.path.join(_td, '拳皇.gba')
_d2 = os.path.join(_td, '拳皇.gba')
with open(_d1, 'wb') as f:
    f.write(b'KOF1' + b'\0' * 10)
with open(_d2, 'wb') as f:
    f.write(b'KOF2' + b'\0' * 10)
plan_dup = ps.build_plan(
    [{'path': _d1, 'file': '拳皇.gba', 'platform': 'gba', 'crc': ''},
     {'path': _d2, 'file': '拳皇.gba', 'platform': 'gba', 'crc': ''}], [], {})
rels = [it.rel for it in plan_dup['items']]
check('build_plan 重名去重', rels == ['roms/gba/拳皇.gba', 'roms/gba/拳皇 (2).gba'],
      str(rels))

# --- plan_repairs: 按 CRC 把下划线名修回中文名 ---
remote_index = [
    {'name': '__.gba', 'originalName': '__.gba',
     'relativePath': 'roms/gba/__.gba', 'crc32': 0x12345678,
     'platform': 'gba'},
    {'name': '1941r1.zip', 'originalName': '1941r1.zip',
     'relativePath': 'roms/cps1/1941r1.zip', 'crc32': 0xDEADBEEF,
     'platform': 'mame'},  # 本就不是下划线, 不动
    {'name': 'nope.gba', 'originalName': 'nope.gba',
     'relativePath': 'roms/gba/nope.gba', 'crc32': 0x0BADF00D,
     'platform': 'gba'},  # 本地库无此 CRC, 不动
]
local_by_crc = {
    '12345678': {'file': '上海.gba', 'platform': 'gba'},
    'DEADBEEF': {'file': '1941r1.zip', 'platform': 'cps1'},
}
new_index, ops, stats = ps.plan_repairs(remote_index, local_by_crc)
check('plan_repairs 修复 1 条', stats.fixed == 1, str(stats.fixed))
check('plan_repairs 重命名 1 个文件', stats.renamed == 1, str(stats.renamed))
check('plan_repairs 未匹配 1 条', stats.unmatched == 1, str(stats.unmatched))
e0 = next(e for e in new_index if e['relativePath'] == 'roms/gba/上海.gba')
check('plan_repairs 名字修回中文', e0['name'] == '上海.gba')
check('plan_repairs 生成 mv 操作', ops == [('roms/gba/__.gba', 'roms/gba/上海.gba')],
      str(ops))
# 第二次修复应当幂等(名字已对, 不再产生 ops)
_, ops2, stats2 = ps.plan_repairs(new_index, local_by_crc)
check('plan_repairs 幂等(无新 ops)', ops2 == [] and stats2.fixed == 0, str(ops2))

print('\n== 1. adb 定位 ==')
adb = ps.Adb()
check('找到 adb', adb.ok(), adb.path)
if not adb.ok():
    raise SystemExit(1)

print('\n== 2. 设备列表 ==')
devs = adb.devices()
for d in devs:
    print('   %-20s %-8s %s' % (d['serial'], d['state'], d['model']))
check('至少一台设备', len(devs) > 0, '%d 台' % len(devs))
if not devs:
    skip('后续用例', '无设备')
    raise SystemExit(0)

serial = devs[0]['serial']
sync = ps.PhoneSync(adb, serial)

print('\n== 3. 探测私有目录 ==')
info = sync.probe()
print('   ', info)
check('run-as 可用', info['ok'], info.get('msg', ''))
if not info['ok']:
    skip('推送用例', 'run-as 不可用')
    raise SystemExit(0)
print('   手机端已有索引: %d 条, system 下 zip: %d'
      % (info['roms'], info['bios']))

print('\n== 4. build_plan(纯本地) ==')
tmp = tempfile.mkdtemp(prefix='gp_phone_')
fake_rom = os.path.join(tmp, 'gp_test_rom.gba')
with open(fake_rom, 'wb') as f:
    f.write(b'GP-PHONE-SYNC-TEST' + b'\0' * 200)
fake_bios = os.path.join(tmp, 'gp_test_bios.zip')
with open(fake_bios, 'wb') as f:
    f.write(b'PK\3\4' + b'\0' * 40)

plan = ps.build_plan(
    [{'path': fake_rom, 'file': 'gp_test_rom.gba', 'platform': 'gba',
      'crc': ''}],
    [{'path': fake_bios, 'name': 'gp_test_bios.zip'}],
    {'11223344': [{'name': '测试金手指', 'code': '00A2:09',
                   'enabled': False}]})
check('计划含 1 个 ROM', len(plan['items']) == 1)
it = plan['items'][0]
check('relativePath 形如 roms/gba/xxx', it.rel.startswith('roms/gba/'), it.rel)
check('platform 映射为 gba', it.platform == 'gba', it.platform)
check('CRC 为 8 位大写', len(it.crc) == 8 and it.crc == it.crc.upper(), it.crc)
check('索引条目 crc32 为整数',
      isinstance(it.to_entry()['crc32'], int), str(it.to_entry()['crc32']))

print('\n== 5. 真实推送 ==')
# 幂等: 先清掉上次可能遗留的测试痕迹(条目 / 文件 / 金手指)
adb.run_as(serial, 'rm', '-f', 'files/roms/gba/gp_test_rom.gba',
           'files/system/gp_test_bios.zip',
           'files/library/cheats.json',
           'files/library/cheats.json.gptestbak')
_before = sync.remote_index()
_clean = [e for e in _before if isinstance(e, dict)
          and str(e.get('relativePath')) != 'roms/gba/gp_test_rom.gba']
if len(_clean) != len(_before):
    _td = tempfile.mkdtemp(prefix='gp_cln_')
    with open(os.path.join(_td, 'rom_index.json'), 'w', encoding='utf-8') as f:
        json.dump(_clean, f, ensure_ascii=False, indent=1)
    adb.push(serial, _td, '/data/local/tmp/gp_cln')
    adb.run_as(serial, 'cp', '-f',
               '/data/local/tmp/gp_cln/rom_index.json',
               'files/rom_index.json')
    adb.shell(serial, 'rm', '-rf', '/data/local/tmp/gp_cln')

had_cheats = adb.run_as(serial, 'ls', 'files/library/cheats.json').returncode == 0
if had_cheats:
    adb.run_as(serial, 'cp', '-f', 'files/library/cheats.json',
               'files/library/cheats.json.gptestbak')
before = sync.remote_index()
n_before = len(before)
res = sync.push(plan, on_log=lambda s: print('   ·', s))
print('   ', res.as_text())
check('ROM 已推送', res.pushed_roms == 1)
check('BIOS 已推送', res.bios == 1)
check('金手指已合并', res.cheat_crcs == 1)

after = sync.remote_index()
check('索引条数 +1', len(after) == n_before + 1, '%d -> %d'
      % (n_before, len(after)))
entry = next((e for e in after if e.get('relativePath') == it.rel), None)
check('索引里有新条目', entry is not None)
if entry:
    check('索引 CRC 与本地一致',
          '%08X' % (entry['crc32'] & 0xFFFFFFFF) == it.crc,
          '%08X vs %s' % (entry['crc32'] & 0xFFFFFFFF, it.crc))

r = adb.run_as(serial, 'cat', 'files/library/cheats.json')
try:
    got = json.loads(r.stdout or '{}')
    check('手机 cheats.json 含新键', '11223344' in (got.get('byCrc') or {}))
except Exception as ex:
    check('手机 cheats.json 可读', False, str(ex))
r = adb.run_as(serial, 'ls', 'files/system/gp_test_bios.zip')
check('BIOS 落盘', 'gp_test_bios.zip' in (r.stdout or ''))

print('\n== 6. 回滚(清理测试痕迹) ==')
adb.run_as(serial, 'rm', '-f', 'files/' + it.rel)
adb.run_as(serial, 'rm', '-f', 'files/system/gp_test_bios.zip')
adb.run_as(serial, 'cp', '-f', 'files/rom_index.json.bak',
           'files/rom_index.json')
final = sync.remote_index()
check('索引已还原', len(final) == n_before, '%d -> %d' % (len(final), n_before))
if had_cheats:
    adb.run_as(serial, 'cp', '-f', 'files/library/cheats.json.gptestbak',
               'files/library/cheats.json')
else:
    adb.run_as(serial, 'rm', '-f', 'files/library/cheats.json')
adb.run_as(serial, 'rm', '-f', 'files/library/cheats.json.gptestbak')
print('   (手机端 cheats.json 已还原: 原有=%s)' % had_cheats)

print('\n' + ('全部通过' if not FAIL else '失败: %s' % FAIL))
if SKIP:
    print('跳过: %s' % SKIP)
raise SystemExit(1 if FAIL else 0)
