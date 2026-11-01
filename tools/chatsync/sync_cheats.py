#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
sync_cheats.py — 把游戏元数据索引里的金手指搬运到 GamePouch 的 `.tools/gstest/cheats`,
以 `roms/` 里的真实游戏文件为基准做关联, 并输出可直接被 GamePouch 消费的
`cheats.json`(按 ROM 的 zlib CRC32 键控)。

数据源
------
默认读**仓库内置**的 `tools/library/metadata/game_index.json`(随仓库分发, 自包含,
不需要旁边还有别的项目)。要覆盖:
  GAMEPOUCH_META_DIR=<含 game_index.json 或 library/index.json 的目录>
  GAMEPOUCH_CHT_DIR=<library/cache/cheat_db_cht 目录>   # 可选的 .cht 补充源

设计要点
--------
1. 金手指有两个来源(两边格式完全不同):
   * 街机(CPS1/CPS2/NeoGeo): 内联在索引条目的 `cheats[]` 里,
     以**街机 zip 名**(即 MAME 驱动名)为键 —— 与 GamePouch 街机 ROM 命名一致,
     可直接主干匹配。
   * GBA/NES: `library/cache/cheat_db_cht/**/*.cht`, RetroArch 文本格式,
     文件名是**英文全称**(`CT Special Forces (USA, Europe) (Code Breaker).cht`),
     而 GamePouch 的 ROM 是中文名(`CT特种部队.gba`), 字面匹配必然为 0。
     -> GBA 通过读 ROM 内部 12 字节 ASCII 标题(偏移 0xA0)桥接到英文金手指名。
2. 输出与 ROM 一一对应: `cheats/<ROM 主干>.cht`。
3. 妥善处理两端:
   * 无金手指的游戏 -> 不建文件, 计入 `report.missing`
   * 无对应游戏的金手指 -> 保留到 `cheats/_orphans/`, 绝不静默丢弃
4. 额外产出 `cheats/cheats.json`, 结构与 GamePouch `library/cheats.json` 完全一致
   (`{"version":1,"byCrc":{"<8位大写CRC32>":[{name,code,enabled,options,selected}]}}`),
   可直接 push 到手机使用。

用法
----
  python tools/chatsync/sync_cheats.py            # 实际执行
  python tools/chatsync/sync_cheats.py --dry-run  # 只统计不写盘
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import zlib
from collections import OrderedDict

# ---------------------------------------------------------------- 路径配置

HERE = os.path.dirname(os.path.abspath(__file__))
GSTEST = os.path.abspath(os.path.join(HERE, '..', '..', '.tools', 'gstest'))

# 金手指数据源。默认用仓库内置的 tools/library/metadata(随仓库分发, 自包含);
# 需要覆盖时设 GAMEPOUCH_META_DIR 指向含 library/index.json 的目录(旧
# MyGameSim 布局), 或设 GAMEPOUCH_CHT_DIR 指向 library/cache/cheat_db_cht。
# 历史上数据源是同级的 MyGameSim 项目, 该项目已移除 —— 绝不再硬编码兄弟路径。
_META_ROOT = os.environ.get('GAMEPOUCH_META_DIR') or os.path.abspath(
    os.path.join(HERE, '..', '..', 'tools', 'library', 'metadata'))
MGS = os.path.abspath(_META_ROOT)
_CHT_DIR = os.environ.get('GAMEPOUCH_CHT_DIR')
if _CHT_DIR:
    MGS_CHT_DIR = os.path.abspath(_CHT_DIR)
elif os.path.isdir(os.path.join(MGS, 'library', 'cache', 'cheat_db_cht')):
    MGS_CHT_DIR = os.path.join(MGS, 'library', 'cache', 'cheat_db_cht')
else:
    # 内置布局只搬了索引(索引里已内联金手指), 没有 .cht 目录
    MGS_CHT_DIR = os.path.join(MGS, 'library', 'cache', 'cheat_db_cht')

ROMS_DIR = os.path.join(GSTEST, 'roms')
BIOS_DIR = os.path.join(GSTEST, 'bios')
CHEATS_DIR = os.path.join(GSTEST, 'cheats')

# 索引: 内置布局 game_index.json, 旧布局 library/index.json
MGS_INDEX = os.path.join(MGS, 'game_index.json')
if not os.path.isfile(MGS_INDEX):
    MGS_INDEX = os.path.join(MGS, 'library', 'index.json')

# ROM 子目录 -> (platform, 扩展名, 是否街机)
PLATFORM_DIRS = OrderedDict([
    ('GBA',     ('gba',    '.gba', False)),
    ('NES',     ('nes',    '.nes', False)),
    ('NeoGeo',  ('neogeo', '.zip', True)),
    ('Cps1',    ('cps1',   '.zip', True)),
    ('Cps2',    ('cps2',   '.zip', True)),
])

# 街机分类 -> GamePouch 子目录(索引里的 category 字段值)
ARCADE_CATEGORY_TO_PLATFORM = {
    '街机 NeoGeo 经典': 'neogeo',
    '街机 CPS1 经典': 'cps1',
    '街机 CPS2 经典': 'cps2',
}

GBA_TITLE_OFF = 0xA0
GBA_TITLE_LEN = 12


# ---------------------------------------------------------------- 工具函数

def crc32_file(path: str) -> str:
    """整个文件的 IEEE 802.3 CRC32, 与 GamePouch `_crc32OfFile` 完全一致
    (不剥 NES 的 16 字节 iNES 头)。8 位大写十六进制。"""
    crc = 0
    with open(path, 'rb') as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            crc = zlib.crc32(chunk, crc)
    return '%08X' % (crc & 0xFFFFFFFF)


def norm(s: str) -> str:
    """归一化用于匹配: 只保留字母数字并大写。"""
    return ''.join(ch for ch in s.upper() if ch.isalnum())


def gba_internal_title(path: str) -> str:
    """GBA ROM 内部标题(0xA0 起 12 字节 ASCII), 例如 'CT SPECIAL F'。"""
    try:
        with open(path, 'rb') as f:
            f.seek(GBA_TITLE_OFF)
            raw = f.read(GBA_TITLE_LEN)
        if len(raw) < GBA_TITLE_LEN:
            return ''
        return raw.split(b'\x00')[0].decode('ascii', 'ignore').strip()
    except Exception:
        return ''


def cht_base_name(filename: str) -> str:
    """'CT Special Forces (USA, Europe) (Code Breaker).cht' -> 'CT Special Forces'"""
    b = filename
    if b.lower().endswith('.cht'):
        b = b[:-4]
    i = b.find(' (')
    return (b[:i] if i > 0 else b).strip()


def parse_cht_text(text: str) -> list:
    """解析 RetroArch .cht 文本 -> GamePouch CheatInfo 列表。

    .cht 形如:
        cheats = 2

        cheat0_desc = "Infinite Health"
        cheat0_code = "12345678 90AB"
        cheat0_enable = false
    多个 code 行(cheat0_code / cheat0_code2 ...)会合并成一条命令。
    """
    # 先按 cheatN_ 前缀聚合
    entries = {}
    order = []
    for line in text.splitlines():
        line = line.strip()
        if not line or '=' not in line:
            continue
        key, _, val = line.partition('=')
        key = key.strip()
        val = val.strip().strip('"')
        if not key.startswith('cheat'):
            continue
        idx = key[len('cheat'):].split('_')[0]
        if not idx.isdigit():
            continue
        field = key.split('_', 1)[1] if '_' in key else ''
        if idx not in entries:
            entries[idx] = {'name': '', 'code': '', 'enabled': False,
                            'options': [], 'selected': -1}
            order.append(idx)

    # 重新扫描以按顺序收集 code / codeN
    codes = {}
    for line in text.splitlines():
        line = line.strip()
        if '=' not in line:
            continue
        key, _, val = line.partition('=')
        key = key.strip()
        val = val.strip().strip('"')
        if not key.startswith('cheat'):
            continue
        rest = key[len('cheat'):]
        idx = rest.split('_')[0]
        if not idx.isdigit():
            continue
        field = rest.split('_', 1)[1] if '_' in rest else ''
        if field == 'desc':
            entries[idx]['name'] = val
        elif field == 'enable':
            entries[idx]['enabled'] = val.lower() in ('true', '1', 'yes')
        elif field.startswith('code'):
            # code / code2 / code3 ... 同一条命令的多行
            if val:
                codes.setdefault(idx, []).append(val)

    out = []
    for idx in sorted(order, key=lambda x: int(x)):
        e = entries[idx]
        parts = codes.get(idx, [])
        if parts:
            e['code'] = '\n'.join(parts)
        if e['name'] or e['code']:
            out.append(e)
    return out


def to_cht_text(cheats: list) -> str:
    """GamePouch CheatInfo 列表 -> RetroArch .cht 文本。"""
    lines = ['cheats = %d' % len(cheats), '']
    for i, c in enumerate(cheats):
        lines.append('cheat%d_desc = "%s"' % (i, c.get('name', '')))
        code = c.get('code', '') or ''
        if code:
            for j, part in enumerate(code.split('\n')):
                suffix = '' if j == 0 else str(j + 1)
                lines.append('cheat%d_code%s = "%s"' % (i, suffix, part))
        lines.append('cheat%d_enable = %s'
                     % (i, 'true' if c.get('enabled') else 'false'))
        lines.append('')
    return '\n'.join(lines) + '\n'


def arcade_cheats_to_infos(cheats: list) -> list:
    """索引内联街机金手指 -> GamePouch CheatInfo 列表。

    内联形态:
      {"name","kind":"switch","code","enabled"}
      {"name","kind":"choice","options":[{"label","code"}],"selected"}
    choice 型展开成多条独立命令(_desc 用 "父名 / 选项名"), 与 RetroArch 惯例一致。
    """
    out = []
    for c in cheats:
        if not isinstance(c, dict):
            continue
        kind = c.get('kind')
        if kind == 'choice':
            opts = c.get('options') or []
            if not isinstance(opts, list):
                continue
            for o in opts:
                if not isinstance(o, dict):
                    continue
                out.append({
                    'name': '%s / %s' % (c.get('name', ''), o.get('label', '')),
                    'code': o.get('code', ''),
                    'enabled': False,
                    'options': [],
                    'selected': -1,
                })
        else:
            out.append({
                'name': c.get('name', ''),
                'code': c.get('code', ''),
                'enabled': bool(c.get('enabled')),
                'options': [],
                'selected': -1,
            })
    return out


# ---------------------------------------------------------------- 扫描

def scan_roms(roms_dir: str) -> list:
    """扫描 GamePouch roms/, 返回游戏记录列表。"""
    roms = []
    for sub, (platform, ext, _arc) in PLATFORM_DIRS.items():
        d = os.path.join(roms_dir, sub)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            p = os.path.join(d, name)
            if not os.path.isfile(p):
                continue
            if os.path.splitext(name)[1].lower() != ext:
                continue
            stem = os.path.splitext(name)[0]
            title = ''
            if platform == 'gba':
                title = gba_internal_title(p)
            roms.append({
                'stem': stem,
                'file': name,
                'sub': sub,
                'platform': platform,
                'size': os.path.getsize(p),
                'crc': crc32_file(p),
                'internalTitle': title,
                'path': p,
            })
    return roms


def load_arcade_cheats() -> dict:
    """{normalized zip stem: {"infos":[...], "platform":..., "src":...}}"""
    if not os.path.isfile(MGS_INDEX):
        return {}
    with open(MGS_INDEX, 'r', encoding='utf-8') as f:
        data = json.load(f)
    out = {}
    for e in data:
        if not isinstance(e, dict):
            continue
        cheats = e.get('cheats')
        if not cheats:
            continue
        cat = e.get('category')
        platform = ARCADE_CATEGORY_TO_PLATFORM.get(cat)
        if not platform:
            continue  # NES 测试ROM 等不属于街机三平台
        rel = e.get('relPath', '')
        stem = os.path.splitext(os.path.basename(rel))[0]
        if not stem:
            continue
        key = norm(stem)
        out[key] = {
            'infos': arcade_cheats_to_infos(cheats),
            'platform': platform,
            'src': 'index.json:%s' % rel,
            'display': stem,
        }
    return out


def load_cht_files() -> dict:
    """{platform: {normalized base name: {"path","base","src"}}}"""
    out = {'gba': {}, 'nes': {}}
    if not os.path.isdir(MGS_CHT_DIR):
        return out
    for plat in ('gba', 'nes'):
        d = os.path.join(MGS_CHT_DIR, plat)
        if not os.path.isdir(d):
            continue
        for root, _dirs, files in os.walk(d):
            for name in files:
                if not name.lower().endswith('.cht'):
                    continue
                p = os.path.join(root, name)
                base = cht_base_name(name)
                out[plat][norm(base)] = {
                    'path': p,
                    'base': base,
                    'file': name,
                    'src': os.path.relpath(p, MGS_CHT_DIR),
                }
    return out


def load_inline_cheats():
    """从游戏元数据索引提取**所有非街机**平台的内联金手指, 返回两份键控:

      - `by_crc`:    {crcFull(8位大写) -> info}   精确但要求 ROM 字节一致
      - `by_title`:  {规范化 title -> info}         按游戏名匹配, 跨不同 dump 也稳

    为什么需要它: 上游索引把大量金手指**内联**在条目的 `cheats[]` 里
    (例如 NES 的「吞食天地II·诸葛孔明传」就有 18 条), 而几乎没有对应的 RetroArch
    `.cht` 文本文件。原流程只从 `cheat_db_cht/*.cht` 按文件名匹配 NES/GBA, 对中文
    名的 NES ROM 必然落空 —— 于是这些游戏永远关联不上金手指。

    匹配策略(在 main 里): 先按 CRC 精确匹配(同一份 dump), 落空再按规范化标题匹配
    (ROM 文件名主干 vs 索引 title, 例如 `吞食天地II·诸葛孔明传`)。NES 没有可读的
    内部标题, 标题匹配是它关联金手指的主要途径。

    街机(CPS1/CPS2/NeoGeo)的内联金手指已由 `load_arcade_cheats` 按 zip 主干匹配,
    这里跳过它们, 避免重复计入。
    """
    if not os.path.isfile(MGS_INDEX):
        return {}, {}
    with open(MGS_INDEX, 'r', encoding='utf-8') as f:
        data = json.load(f)
    by_crc, by_title = {}, {}
    for e in data:
        if not isinstance(e, dict):
            continue
        cheats = e.get('cheats')
        if not isinstance(cheats, list) or not cheats:
            continue
        if ARCADE_CATEGORY_TO_PLATFORM.get(e.get('category')):
            continue  # 街机交给 load_arcade_cheats
        infos = arcade_cheats_to_infos(cheats)
        if not infos:
            continue
        crc = str(e.get('crcFull', '')).upper()
        if len(crc) == 8:
            by_crc[crc] = {
                'infos': infos, 'platform': e.get('platform'),
                'src': 'index.json:%s' % (e.get('relPath') or ''),
                'display': e.get('title', ''),
            }
        title = norm(e.get('title', ''))
        if title:
            # 同名多条目(如不同版本)时, 后者覆盖; 一般中文名不会撞
            by_title[title] = {
                'infos': infos, 'platform': e.get('platform'),
                'src': 'index.json:%s' % (e.get('relPath') or e.get('title') or ''),
                'display': e.get('title', ''),
            }
    return by_crc, by_title


# ---------------------------------------------------------------- 匹配

def match_arcade(rom: dict, arcade: dict):
    return arcade.get(norm(rom['stem']))


def match_gba(rom: dict, chts: dict):
    """GBA: 用 ROM 内部标题做规范化前缀匹配。

    ROM 内部标题被截断到 12 字符(如 'CT SPECIAL F'), 而金手指名是全称
    ('CT Special Forces'), 归一化后前者是后者的前缀。取最长命中的那个,
    并要求唯一, 避免短标题误伤。
    """
    title = rom.get('internalTitle', '')
    t = norm(title)
    if len(t) < 5:
        return None
    cands = []
    for key, info in chts.get('gba', {}).items():
        k = norm(info['base'])
        if k.startswith(t) or t.startswith(k):
            cands.append((abs(len(k) - len(t)), key, info))
    if not cands:
        return None
    cands.sort(key=lambda c: c[0])
    # 若最优差距并列, 视为歧义, 拒绝猜测
    if len(cands) > 1 and cands[0][0] == cands[1][0]:
        return None
    return chts['gba'][cands[0][1]]


def match_nes(rom: dict, chts: dict):
    """NES: 先用文件名的 ASCII 部分做规范化匹配(少数英文命名 ROM),
    再退化为对英文金手指名的包含匹配。"""
    # NES 文件名里提取 ASCII 片段
    stem = rom['stem']
    # 形如 'Super Mario Bros (J)' -> 取 ASCII 部分
    ascii_bits = ''.join(ch for ch in stem if ord(ch) < 128).strip()
    keys = [norm(ascii_bits)] if ascii_bits else []
    # 中文名无法直接对应, 仅在 ASCII 片段有意义时尝试
    for k in keys:
        if len(k) < 5:
            continue
        for ck, info in chts.get('nes', {}).items():
            nk = norm(info['base'])
            if nk.startswith(k) or k.startswith(nk):
                return info
    return None


# ---------------------------------------------------------------- 主流程

def main():
    ap = argparse.ArgumentParser(description='同步游戏元数据索引金手指到 GamePouch cheats/')
    ap.add_argument('--dry-run', action='store_true', help='只统计不写盘')
    ap.add_argument('--roms', default=ROMS_DIR, help='ROM 根目录')
    ap.add_argument('--out', default=CHEATS_DIR, help='输出 cheats 目录')
    args = ap.parse_args()

    roms_dir = args.roms
    cheats_dir = args.out

    if not os.path.isdir(roms_dir):
        print('[!] ROM 目录不存在: %s' % roms_dir)
        return 2

    print('[1/4] 扫描 ROM ...')
    roms = scan_roms(roms_dir)
    by_plat = {}
    for r in roms:
        by_plat.setdefault(r['platform'], 0)
        by_plat[r['platform']] += 1
    print('      共 %d 个游戏: %s'
          % (len(roms), ', '.join('%s=%d' % (k, v) for k, v in sorted(by_plat.items()))))

    print('[2/4] 载入金手指源 ...')
    arcade = load_arcade_cheats()
    chts = load_cht_files()
    inline_crc, inline_title = load_inline_cheats()
    n_cht = sum(len(v) for v in chts.values())
    print('      街机内联: %d 条 | .cht 文件: %d 个 (gba=%d nes=%d)'
          ' | 内联(按CRC): %d 条 | 内联(按标题): %d 条'
          % (len(arcade), n_cht, len(chts['gba']), len(chts['nes']),
             len(inline_crc), len(inline_title)))

    print('[3/4] 匹配 ...')
    matched = {}        # rom stem -> info dict
    used_cheat_keys = set()

    for r in roms:
        hit = None
        if r['platform'] in ('neogeo', 'cps1', 'cps2'):
            a = match_arcade(r, arcade)
            if a:
                hit = {'kind': 'arcade', 'infos': a['infos'],
                       'src': a['src'], 'srcName': a['display']}
                used_cheat_keys.add(('arcade', norm(r['stem'])))
        elif r['platform'] == 'gba':
            c = match_gba(r, chts)
            if c:
                with open(c['path'], 'r', encoding='utf-8', errors='replace') as f:
                    infos = parse_cht_text(f.read())
                if infos:
                    hit = {'kind': 'cht', 'infos': infos,
                           'src': c['src'], 'srcName': c['base']}
                    used_cheat_keys.add(('gba', norm(c['base'])))
        elif r['platform'] == 'nes':
            c = match_nes(r, chts)
            if c:
                with open(c['path'], 'r', encoding='utf-8', errors='replace') as f:
                    infos = parse_cht_text(f.read())
                if infos:
                    hit = {'kind': 'cht', 'infos': infos,
                           'src': c['src'], 'srcName': c['base']}
                    used_cheat_keys.add(('nes', norm(c['base'])))
        # 内联金手指(街机已由 load_arcade_cheats 处理): 先按 CRC 精确匹配,
        # 落空再按规范化标题精确匹配(ROM 文件名主干 vs 索引 title),
        # 仍落空则用「主干是标题的前缀/后缀」放宽(如 `吞食天地II` vs
        # `吞食天地II·诸葛孔明传`), 仅当唯一命中时采纳, 避免误配。
        inl = inline_crc.get(r['crc'])
        if inl is None:
            nt = norm(r['stem'])
            inl = inline_title.get(nt)
            if inl is None:
                cands = [v for k, v in inline_title.items()
                         if k and (k.startswith(nt) or nt.startswith(k))]
                if len(cands) == 1:
                    inl = cands[0]
        if inl:
            if hit is None:
                hit = {'kind': 'inline', 'infos': inl['infos'],
                       'src': inl['src'], 'srcName': inl['display']}
            else:
                hit = dict(hit)
                hit['infos'] = hit['infos'] + inl['infos']
                hit['src'] = (hit.get('src') or '') + ' + ' + inl['src']
        if hit:
            matched[r['stem']] = hit

    missing = [r for r in roms if r['stem'] not in matched]

    # 孤立金手指: 没有任何游戏用到的
    orphans = []
    for key, a in arcade.items():
        if ('arcade', key) not in used_cheat_keys:
            orphans.append({'kind': 'arcade', 'name': a['display'],
                            'src': a['src'], 'platform': a['platform'],
                            'count': len(a['infos'])})
    for plat in ('gba', 'nes'):
        for key, c in chts[plat].items():
            if (plat, key) not in used_cheat_keys:
                orphans.append({'kind': 'cht', 'name': c['base'],
                                'src': c['src'], 'platform': plat,
                                'count': 0})

    n_cmds = sum(len(v['infos']) for v in matched.values())
    print('      命中游戏: %d / %d  (命令合计 %d 条)'
          % (len(matched), len(roms), n_cmds))
    print('      无金手指游戏: %d' % len(missing))
    print('      孤立金手指: %d' % len(orphans))

    if args.dry_run:
        print('\n(--dry-run 未写盘)')
        return 0

    print('[4/4] 写出 ...')
    # 清空 cheats 旧内容(保留目录本身), 保证一一对应、不留陈旧文件
    if os.path.isdir(CHEATS_DIR):
        for n in os.listdir(CHEATS_DIR):
            p = os.path.join(cheats_dir, n)
            if os.path.isdir(p):
                shutil.rmtree(p)
            else:
                os.remove(p)
    else:
        os.makedirs(cheats_dir, exist_ok=True)

    # 每个命中游戏一个 .cht
    crc_map = OrderedDict()
    for r in roms:
        hit = matched.get(r['stem'])
        if not hit:
            continue
        out = os.path.join(cheats_dir, r['stem'] + '.cht')
        with open(out, 'w', encoding='utf-8') as f:
            f.write(to_cht_text(hit['infos']))
        crc_map[r['crc']] = hit['infos']

    # GamePouch 原生格式: 按 CRC32 键控, 值必须是「金手指命令列表」(App 的
    # `_readByCrc` / PC 端 library_manager 都按 list 解析)。完整导出: 把「所有
    # 索引内联金手指(by crcFull)」与「已按 ROM 关联的金手指」合并写入 byCrc。
    # 注意 inline_crc 的值是带元信息的 dict, 这里只取其中的 infos 列表, 否则 App
    # 端会把整个 dict 当成一条命令而解析失败。
    bycrc_out = {c: v['infos'] for c, v in inline_crc.items()}
    bycrc_out.update(crc_map)      # ROM 已匹配的优先(用的是真实 ROM 的 CRC)
    with open(os.path.join(cheats_dir, 'cheats.json'), 'w', encoding='utf-8') as f:
        json.dump({'version': 1, 'byCrc': bycrc_out}, f,
                  ensure_ascii=False, indent=2)
    print('      cheats.json byCrc 共 %d 条(含内联 %d + 已匹配 %d)'
          % (len(bycrc_out), len(inline_crc), len(crc_map)))

    # 孤立金手指保留, 不静默丢弃
    if orphans:
        od = os.path.join(cheats_dir, '_orphans')
        os.makedirs(od, exist_ok=True)
        for o in orphans:
            if o['kind'] == 'cht':
                src = None
                for plat in ('gba', 'nes'):
                    for _k, c in chts[plat].items():
                        if c['src'] == o['src']:
                            src = c['path']
                if src and os.path.isfile(src):
                    dst = os.path.join(od, os.path.basename(src))
                    i = 1
                    while os.path.exists(dst):
                        dst = os.path.join(od, '%s_%d.cht'
                                           % (os.path.splitext(os.path.basename(src))[0], i))
                        i += 1
                    shutil.copy2(src, dst)
            else:
                # 街机内联也导出成 .cht, 便于日后补 ROM 直接使用
                base = o['name']
                dst = os.path.join(od, base + '.cht')
                i = 1
                while os.path.exists(dst):
                    dst = os.path.join(od, '%s_%d.cht' % (base, i))
                    i += 1
                info = None
                for _k, a in arcade.items():
                    if a['display'] == base:
                        info = a
                if info:
                    with open(dst, 'w', encoding='utf-8') as f:
                        f.write(to_cht_text(info['infos']))

    # 报告
    report = {
        'romsTotal': len(roms),
        'matched': len(matched),
        'missing': len(missing),
        'orphans': len(orphans),
        'commandsTotal': n_cmds,
        'byPlatform': {},
        'matchedList': [
            {'rom': r['stem'], 'platform': r['platform'], 'crc': r['crc'],
             'cheats': len(matched[r['stem']]['infos']),
             'source': matched[r['stem']]['srcName']}
            for r in roms if r['stem'] in matched
        ],
        'missingList': [
            {'rom': r['stem'], 'platform': r['platform'], 'crc': r['crc']}
            for r in missing
        ],
        'orphanList': orphans,
    }
    for plat in sorted(set(r['platform'] for r in roms)):
        tot = sum(1 for r in roms if r['platform'] == plat)
        hit = sum(1 for r in roms if r['platform'] == plat and r['stem'] in matched)
        report['byPlatform'][plat] = {'total': tot, 'matched': hit}

    with open(os.path.join(cheats_dir, 'report.json'), 'w', encoding='utf-8') as f:
        json.dump(report, f, ensure_ascii=False, indent=2)

    print('      写出 %d 个 .cht + cheats.json + report.json' % len(matched))
    print('\n完成。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
