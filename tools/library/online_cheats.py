#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
联网检索金手指并适配到本地游戏库
================================

本地库 (随仓库内置的元数据索引那一份) 只能覆盖一部分游戏, 仍有大量 ROM 没有
金手指。本模块负责「一键」把它们补齐:

    1. 读取 libretro/libretro-database 仓库 ``cht/`` 目录的文件清单
       (GitHub contents API, 按平台目录分次拉取, 结果本地缓存 7 天)。
    2. 用归一化名字 + 前缀 + 相似度三级打分, 为 ROM 找到候选 .cht。
    3. 下载候选 .cht, 解析成 GamePouch 的 CheatInfo 列表。
    4. 落地:  ``chats/<ROM 主干>.cht``  +  合并进 ``chats/cheats.json``
       (按 ROM 的 CRC32 键控, 与手机端完全一致)。

数据源
------
* API   https://api.github.com/repos/libretro/libretro-database/contents/cht/<目录>
* 原始  https://raw.githubusercontent.com/libretro/libretro-database/master/cht/<路径>

未认证 GitHub API 限额 60 次/小时; 本模块每个平台目录只请求 1 次并缓存,
一次全库检索通常只消耗 4~6 次配额。原始文件的下载不走 API 限额。

离线可测试: 所有网络入口都收在 ``_http_get`` 里, 测试可注入假的响应。
"""
from __future__ import annotations

import difflib
import json
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, '..', 'chatsync')))
from sync_cheats import (  # noqa: E402
    cht_base_name, crc32_file, gba_internal_title, norm, parse_cht_text,
    to_cht_text,
)

# ------------------------------------------------------------------ 常量

API_ROOT = ('https://api.github.com/repos/libretro/libretro-database'
            '/contents/cht/')
RAW_ROOT = ('https://raw.githubusercontent.com/libretro/libretro-database'
            '/master/cht/')

#: 本地平台 -> 仓库里要检索的 cht 子目录(按优先级排序)
PLATFORM_DIRS = {
    'gba': ['Nintendo - Game Boy Advance'],
    'nes': ['Nintendo - Nintendo Entertainment System',
            'Nintendo - Family Computer Disk System'],
    'neogeo': ['FBNeo - Arcade Games',
               'SNK - Neo Geo Pocket', 'SNK - Neo Geo Pocket Color'],
    'cps1': ['FBNeo - Arcade Games'],
    'cps2': ['FBNeo - Arcade Games'],
    'arcade': ['FBNeo - Arcade Games'],
    '': [],
}

#: 打分阈值: >= 该值才认为「稳了」, 直接采用
SCORE_AUTO = 84
#: 低于该值的候选直接丢弃
SCORE_MIN = 70

CACHE_TTL = 7 * 24 * 3600
UA = {'User-Agent': 'GamePouch-LibraryManager/1.0',
      'Accept': 'application/vnd.github+json'}


# ------------------------------------------------------------------ 工具

def _http_get(url: str, timeout: int = 25) -> bytes:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def title_norm(s: str) -> str:
    """比 sync_cheats.norm 更适合跨库匹配的归一化。

    额外去掉 ``(USA)`` / ``[!]`` / ``(Rev A)`` 之类的括号尾巴与副标题,
    例如 ``"CT Special Forces (USA) (Code Breaker)"`` -> ``CTSPECIALFORCES``。
    """
    b = os.path.splitext(str(s or ''))[0]
    b = re.sub(r'[(\[].*?[)\]]', ' ', b)
    b = b.split(' - ')[0]
    return norm(b)


def _ratio(a: str, b: str) -> float:
    return difflib.SequenceMatcher(None, a, b).ratio()


def score_pair(a: str, b: str) -> float:
    """两个归一化名字的相似度打分 (0~100)。"""
    if not a or not b:
        return 0.0
    if a == b:
        return 100.0
    lo, hi = (a, b) if len(a) <= len(b) else (b, a)
    # 短名(街机的 samsho5 / samsho, GBA 的 METROID / METROIDZERO)只差一两个
    # 字符, 模糊比对必然误伤成「续作配到前作」。短名只认完全相等。
    if len(lo) <= 8:
        return 0.0
    if len(lo) >= 4 and hi.startswith(lo):
        # 前缀命中: 越接近等长越可信
        return 82.0 + 16.0 * (len(lo) / len(hi))
    if lo and lo in hi:
        return 74.0
    return round(_ratio(a, b) * 100.0, 1)


class Candidate:
    """一个联网候选金手指文件。"""

    __slots__ = ('name', 'path', 'dir', 'size', 'score', 'url')

    def __init__(self, name, path, dir_name, size=0, score=0.0, url=''):
        self.name = name
        self.path = path
        self.dir = dir_name
        self.size = size
        self.score = score
        rel = path[4:] if path.startswith('cht/') else path
        self.url = url or (RAW_ROOT + urllib.parse.quote(rel))

    def as_dict(self) -> dict:
        return {'name': self.name, 'path': self.path, 'dir': self.dir,
                'size': self.size, 'score': self.score, 'url': self.url}

    def __repr__(self):  # pragma: no cover - 调试用
        return 'Candidate(%r, %.1f)' % (self.name, self.score)


# ------------------------------------------------------------------ 索引

class ChtIndex:
    """libretro-database ``cht/`` 目录索引(带本地磁盘缓存)。"""

    def __init__(self, cache_dir: str | None = None, timeout: int = 25,
                 log=print, offline: bool = False):
        self.cache_dir = cache_dir or os.path.join(_HERE, '.cht_index')
        self.timeout = timeout
        self.log = log
        self.offline = offline
        self.dirs: dict[str, list[dict]] = {}
        os.makedirs(self.cache_dir, exist_ok=True)

    # -- 缓存 ---------------------------------------------------------
    def _cache_file(self, dir_name: str) -> str:
        safe = re.sub(r'[^0-9A-Za-z._-]+', '_', dir_name)
        return os.path.join(self.cache_dir, safe + '.json')

    def _load_cache(self, dir_name: str):
        p = self._cache_file(dir_name)
        if not os.path.isfile(p):
            return None
        try:
            if time.time() - os.path.getmtime(p) > CACHE_TTL:
                return None
            with open(p, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            return None

    def _save_cache(self, dir_name: str, entries: list):
        try:
            with open(self._cache_file(dir_name), 'w', encoding='utf-8') as f:
                json.dump({'dir': dir_name, 'fetchedAt': int(time.time()),
                           'entries': entries}, f)
        except Exception:
            pass

    # -- 拉取 ---------------------------------------------------------
    def fetch_dir(self, dir_name: str, force: bool = False) -> list:
        """返回 [{'name','path','size'}]。失败时返回 []。"""
        if dir_name in self.dirs:
            return self.dirs[dir_name]
        if not force:
            c = self._load_cache(dir_name)
            if c is not None:
                self.dirs[dir_name] = c.get('entries', [])
                return self.dirs[dir_name]
        if self.offline:
            self.dirs[dir_name] = []
            return []
        url = API_ROOT + urllib.parse.quote(dir_name)
        try:
            raw = _http_get(url, self.timeout).decode('utf-8', 'replace')
            j = json.loads(raw)
            entries = [{'name': it.get('name', ''),
                        'path': it.get('path', ''),
                        'size': it.get('size', 0)}
                       for it in j
                       if isinstance(it, dict)
                       and str(it.get('name', '')).lower().endswith('.cht')]
            self._save_cache(dir_name, entries)
            self.dirs[dir_name] = entries
            self.log('索引已更新: %s (%d 个文件)' % (dir_name, len(entries)))
        except urllib.error.HTTPError as ex:
            self.log('索引失败 %s: HTTP %s (配额或未联网)' % (dir_name, ex.code))
            self.dirs[dir_name] = []
        except Exception as ex:  # noqa: BLE001
            self.log('索引失败 %s: %s' % (dir_name, ex))
            self.dirs[dir_name] = []
        return self.dirs[dir_name]

    def ensure(self, platforms, force: bool = False) -> int:
        """为给定平台集合拉取目录清单, 返回总文件数。"""
        wanted = []
        for p in platforms:
            for d in PLATFORM_DIRS.get(p, []):
                if d not in wanted:
                    wanted.append(d)
        total = 0
        for d in wanted:
            total += len(self.fetch_dir(d, force=force))
        return total

    # -- 检索 ---------------------------------------------------------
    def search(self, game: dict, limit: int = 5) -> list:
        """为一条游戏记录找候选 .cht, 按得分降序。"""
        plat = game.get('platform', '')
        keys = []
        for k in (game.get('internal') or '', game.get('stem') or '',
                  game.get('name') or ''):
            n = title_norm(k)
            if n and n not in keys:
                keys.append(n)
        if not keys:
            return []

        buckets = []
        for d in PLATFORM_DIRS.get(plat, []):
            entries = self.fetch_dir(d)
            if entries:
                buckets.append((d, entries))

        out = []
        seen = set()
        for d, entries in buckets:
            for e in entries:
                base = title_norm(cht_base_name(e['name']))
                if not base:
                    continue
                best = 0.0
                for k in keys:
                    s = score_pair(k, base)
                    # 内部标题常常是截断的(12 字节), 给一点加成
                    if k == keys[0] and game.get('internal'):
                        s = min(100.0, s + 3.0)
                    if s > best:
                        best = s
                if best < SCORE_MIN:
                    continue
                if e['path'] in seen:
                    continue
                seen.add(e['path'])
                out.append(Candidate(e['name'], e['path'], d,
                                     e.get('size', 0), best))
        out.sort(key=lambda c: (-c.score, c.name.lower()))
        return out[:limit]

    def fetch_text(self, cand: Candidate) -> str:
        return _http_get(cand.url, self.timeout).decode('utf-8', 'replace')


# ------------------------------------------------------------------ 落地

def load_cheats_json(path: str) -> dict:
    if os.path.isfile(path):
        try:
            with open(path, 'r', encoding='utf-8') as f:
                j = json.load(f)
            if isinstance(j, dict):
                j.setdefault('version', 1)
                j.setdefault('byCrc', {})
                return j
        except Exception:
            pass
    return {'version': 1, 'byCrc': {}}


def save_cheats_json(path: str, data: dict):
    tmp = '%s.%d.tmp' % (path, os.getpid())
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


#: 并发适配时 cheats.json / 联网报告都是「读-改-写」, 必须串行
_SAVE_LOCK = threading.Lock()


def adapt(root: str, game: dict, text: str, source: str = '') -> dict:
    """把下载到的 .cht 文本落地到本地库。

    写入 ``<root>/chats/<ROM 主干>.cht`` 并把命令合并进
    ``<root>/chats/cheats.json`` 的 ``byCrc[CRC32]``。
    返回 {'ok':bool, 'count':int, 'crc':str, 'cht':str, 'reason':str}
    """
    cheats = parse_cht_text(text)
    if not cheats:
        return {'ok': False, 'count': 0, 'reason': '空文件或无法解析'}

    crc = game.get('crc') or ''
    if not crc and game.get('path'):
        crc = crc32_file(game['path'])
        game['crc'] = crc
    if not crc:
        return {'ok': False, 'count': 0, 'reason': '缺少 CRC32'}

    chats = os.path.join(root, 'chats')
    os.makedirs(chats, exist_ok=True)
    cht_path = os.path.join(chats, (game.get('stem') or 'game') + '.cht')
    with open(cht_path, 'w', encoding='utf-8') as f:
        f.write(to_cht_text(cheats))

    # 以下两处都是「读-改-写」, 多线程批量适配时必须串行,
    # 否则会出现条目丢失 / 临时文件互相踩踏。
    with _SAVE_LOCK:
        cj = os.path.join(chats, 'cheats.json')
        data = load_cheats_json(cj)
        data['byCrc'][str(crc).upper()] = cheats
        save_cheats_json(cj, data)

        # 记录来源, 便于回溯与撤销
        try:
            rep = os.path.join(chats, '_online_report.json')
            repd = {}
            if os.path.isfile(rep):
                with open(rep, 'r', encoding='utf-8') as f:
                    repd = json.load(f)
            repd[game.get('stem', '')] = {
                'crc': crc, 'count': len(cheats), 'source': source,
                'at': time.strftime('%Y-%m-%d %H:%M:%S'),
            }
            tmp = '%s.%d.tmp' % (rep, os.getpid())
            with open(tmp, 'w', encoding='utf-8') as f:
                json.dump(repd, f, ensure_ascii=False, indent=1)
            os.replace(tmp, rep)
        except Exception:
            pass

    return {'ok': True, 'count': len(cheats), 'crc': crc, 'cht': cht_path}


def game_display(game: dict) -> str:
    return game.get('stem') or game.get('name') or '?'


def online_report_path(root: str) -> str:
    return os.path.join(root, 'chats', '_online_report.json')


def load_online_report(root: str) -> dict:
    p = online_report_path(root)
    if os.path.isfile(p):
        try:
            with open(p, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception:
            return {}
    return {}


def undo_online(root: str, stems=None) -> int:
    """撤销联网适配: 删除对应 .cht 与 cheats.json 里的条目。

    ``stems`` 为空表示撤销全部。返回撤销条数。
    """
    rep = load_online_report(root)
    if not rep:
        return 0
    targets = [s for s in rep if (stems is None or s in stems)]
    chats = os.path.join(root, 'chats')
    with _SAVE_LOCK:
        cj = os.path.join(chats, 'cheats.json')
        data = load_cheats_json(cj)
        n = 0
        for s in targets:
            crc = str(rep[s].get('crc', '')).upper()
            if crc:
                data['byCrc'].pop(crc, None)
            p = os.path.join(chats, s + '.cht')
            if os.path.isfile(p):
                try:
                    os.remove(p)
                except Exception:
                    pass
            rep.pop(s, None)
            n += 1
        save_cheats_json(cj, data)
        try:
            rp = online_report_path(root)
            tmp = '%s.%d.tmp' % (rp, os.getpid())
            with open(tmp, 'w', encoding='utf-8') as f:
                json.dump(rep, f, ensure_ascii=False, indent=1)
            os.replace(tmp, rp)
        except Exception:
            pass
    return n


# ------------------------------------------------------------------ 批量

class BatchResult:
    def __init__(self):
        self.total = 0
        self.ok = []       # [(game, count)]
        self.skipped = []  # [(game, reason)]
        self.failed = []   # [(game, reason)]

    def as_dict(self) -> dict:
        return {'total': self.total, 'ok': len(self.ok),
                'skipped': len(self.skipped), 'failed': len(self.failed)}


def run_batch(root: str, games: list, index: ChtIndex,
              on_progress=None, on_log=print, min_score: float = SCORE_AUTO,
              workers: int = 4, stop=None) -> BatchResult:
    """为一批缺金手指的游戏联网检索并适配。

    ``games`` 为 library_manager 的游戏记录字典列表(需含 stem/platform/crc/path)。
    ``on_progress(done, total, game, status, detail)`` 由工作线程回调。
    """
    res = BatchResult()
    res.total = len(games)
    if not games:
        return res

    plats = sorted({g.get('platform', '') for g in games})
    dirs = [d for p in plats for d in (PLATFORM_DIRS.get(p) or ['(无)'])]
    on_log('拉取在线索引: %s' % ', '.join(dirs))
    index.ensure(plats)
    on_log('索引就绪, 共 %d 个候选文件。开始逐个检索…'
           % sum(len(v) for v in index.dirs.values()))

    # 阶段1: 打分(纯 CPU, 顺序即可)
    claims: dict[str, list] = {}    # candidate.path -> [(score, game, cand)]
    no_hit = []
    for g in games:
        cands = index.search(g, limit=1)
        if not cands or cands[0].score < min_score:
            no_hit.append(g)
            continue
        claims.setdefault(cands[0].path, []).append(
            (cands[0].score, g, cands[0]))

    # 同一个在线文件被多个 ROM 争抢(如「口袋妖怪叶绿/绿宝石」都只解析出
    # "Pokemon")时无法判定归属, 全部放弃, 宁缺勿错。
    conflicted = set()
    for path, lst in claims.items():
        if len(lst) > 1:
            for _s, g, _c in lst:
                conflicted.add(id(g))
                no_hit.append(g)
    plan = [(lst[0][1], lst[0][2]) for _p, lst in claims.items()
            if len(lst) == 1]
    for g in sorted(no_hit, key=lambda x: x['stem']):
        reason = ('多个游戏争抢同一文件, 已放弃' if id(g) in conflicted
                  else '未找到可信匹配')
        res.skipped.append((g, reason))
        if on_progress:
            on_progress(len(res.skipped), res.total, g, 'skipped', reason)

    def work(item):
        g, cand = item
        if stop is not None and stop.is_set():
            return (g, cand, None, '已中止')
        try:
            text = index.fetch_text(cand)
        except Exception as ex:  # noqa: BLE001
            return (g, cand, None, '下载失败: %s' % ex)
        try:
            r = adapt(root, g, text, source=cand.path)
        except Exception as ex:  # noqa: BLE001
            return (g, cand, None, '写入失败: %s' % ex)
        if not r.get('ok'):
            return (g, cand, None, r.get('reason', '失败'))
        return (g, cand, r, '')

    done = 0
    with ThreadPoolExecutor(max_workers=max(1, workers)) as pool:
        for g, cand, r, err in pool.map(work, plan):
            done += 1
            if r:
                res.ok.append((g, r['count'], cand.name))
                on_log('✔ %s  <- %s  (%d 条, 得分 %.0f)'
                       % (game_display(g), cand.name, r['count'], cand.score))
                if on_progress:
                    on_progress(done + len(res.skipped), res.total, g, 'ok',
                                '%d 条 · %s' % (r['count'], cand.name))
            else:
                res.failed.append((g, err))
                on_log('✘ %s  %s' % (game_display(g), err))
                if on_progress:
                    on_progress(done + len(res.skipped), res.total, g,
                                'failed', err)
            if stop is not None and stop.is_set():
                break
    return res


# ------------------------------------------------------------------ CLI

DIR_PLATFORM = {
    'gba': 'gba', 'nes': 'nes', 'neogeo': 'neogeo',
    'cps1': 'cps1', 'cps2': 'cps2',
}


def scan_missing(root: str, platform: str = '', limit: int = 0) -> list:
    """扫出本地库里「没有对应 .cht」的游戏(命令行用, 不依赖 GUI)。"""
    roms_root = os.path.join(root, 'roms')
    chats = os.path.join(root, 'chats')
    have = set()
    if os.path.isdir(chats):
        for n in os.listdir(chats):
            if n.lower().endswith('.cht'):
                have.add(os.path.splitext(n)[0].lower())
    try:
        with open(os.path.join(chats, 'cheats.json'), 'r',
                  encoding='utf-8') as f:
            by_crc = (json.load(f) or {}).get('byCrc', {})
    except Exception:
        by_crc = {}

    out = []
    bases = []
    if os.path.isdir(roms_root):
        for sub in sorted(os.listdir(roms_root)):
            p = os.path.join(roms_root, sub)
            if os.path.isdir(p):
                bases.append((p, DIR_PLATFORM.get(sub.lower(), '')))
    else:
        bases.append((root, ''))
    for base, plat in bases:
        if platform and plat != platform:
            continue
        for name in sorted(os.listdir(base)):
            if not name.lower().endswith(('.gba', '.nes', '.zip', '.fds')):
                continue
            stem = os.path.splitext(name)[0]
            if stem.lower() in have:
                continue
            p = os.path.join(base, name)
            internal = ''
            if plat == 'gba':
                internal = gba_internal_title(p)
            out.append({'stem': stem, 'file': name, 'platform': plat,
                        'path': p, 'crc': '', 'internal': internal,
                        'cheats': []})
            if limit and len(out) >= limit:
                return out
    out.sort(key=lambda g: g['stem'].lower())
    return out


def _main(argv):
    import argparse
    ap = argparse.ArgumentParser(description='联网检索并适配缺失的金手指')
    ap.add_argument('--root', default=os.path.abspath(
        os.path.join(_HERE, '..', '..', '.tools', 'gstest')))
    ap.add_argument('--limit', type=int, default=8, help='最多处理多少个')
    ap.add_argument('--platform', default='', help='只处理该平台')
    ap.add_argument('--min-score', type=float, default=SCORE_AUTO)
    ap.add_argument('--dry-run', action='store_true', help='只检索不落盘')
    args = ap.parse_args(argv)

    games = scan_missing(args.root, args.platform, args.limit)
    print('待补全: %d 个' % len(games))
    idx = ChtIndex()
    idx.ensure(sorted({g['platform'] for g in games}))
    for g in games:
        cands = idx.search(g, limit=3)
        if not cands:
            print('  --  %s' % g['stem'])
            continue
        top = cands[0]
        print('  %-34s -> %-52s %.0f' % (g['stem'], top.name, top.score))
        if not args.dry_run and top.score >= args.min_score:
            if not g['crc']:
                g['crc'] = crc32_file(g['path'])
            r = adapt(args.root, g, idx.fetch_text(top), source=top.path)
            print('      %s (%s 条)' % ('已写入' if r['ok'] else r['reason'],
                                        r.get('count', 0)))
    return 0


if __name__ == '__main__':  # pragma: no cover
    raise SystemExit(_main(sys.argv[1:]))
