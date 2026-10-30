#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把本地库的 ROM / 金手指 / BIOS 推送到手机上的趣玩匣 App
======================================================

手机 App 不会自动扫描 ``files/roms``, 游戏库完全来自 ``files/rom_index.json``,
金手指来自 ``files/library/cheats.json``(按 CRC32 键控), BIOS 来自
``files/system/``。所以「同步」要做三件事:

    1. 把选中的 ROM 推到 ``files/roms/<平台>/<文件名>``;
    2. 生成/合并 ``files/rom_index.json``(字段与 App 的 RomEntry 一致);
    3. 合并 ``files/library/cheats.json``、复制 BIOS 到 ``files/system/``。

写入方式
--------
``/data/data/<pkg>`` 对 ``adb shell`` 不可写, 因此走「暂存 + run-as」两步:

    adb push <暂存目录> /data/local/tmp/gpsync_<ts>/
    adb shell run-as com.retroemupouch.app sh /data/local/tmp/gpsync_<ts>/install.sh

``run-as`` 只在 debuggable 包上可用; 本模块会在开始前探测, 不可用时给出
明确提示(换 debug 包, 或用局域网「伙伴」模式由手机主动拉取)。

CRC32 与 App 完全一致: 整个文件的 IEEE 802.3 CRC32, 大写 8 位十六进制键。
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

PKG = 'com.retroemupouch.app'
STAGE_PREFIX = 'gpsync_'

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, '..', 'chatsync')))
from sync_cheats import crc32_file  # noqa: E402


# ------------------------------------------------------------------ adb

def find_adb(extra: str = '') -> str:
    """定位 adb.exe: 显式路径 > ANDROID_HOME/ANDROID_SDK_ROOT > 仓库 .tools > PATH。"""
    if extra and os.path.isfile(extra):
        return extra
    for env in ('ANDROID_HOME', 'ANDROID_SDK_ROOT'):
        root = os.environ.get(env) or ''
        if root:
            p = os.path.join(root, 'platform-tools',
                             'adb.exe' if os.name == 'nt' else 'adb')
            if os.path.isfile(p):
                return p
    repo = os.path.abspath(os.path.join(_HERE, '..', '..'))
    p = os.path.join(repo, '.tools', 'android-sdk', 'platform-tools',
                     'adb.exe' if os.name == 'nt' else 'adb')
    if os.path.isfile(p):
        return p
    which = shutil.which('adb')
    return which or ''


class Adb:
    def __init__(self, path: str = ''):
        self.path = path or find_adb()

    def ok(self) -> bool:
        return bool(self.path) and os.path.isfile(self.path)

    def _run(self, args, timeout=60):
        return subprocess.run([self.path] + list(args), capture_output=True,
                              text=True, encoding='utf-8', errors='replace',
                              timeout=timeout)

    def devices(self) -> list:
        """[{'serial','model','product','state'}]"""
        if not self.ok():
            return []
        try:
            r = self._run(['devices', '-l'], timeout=30)
        except Exception:
            return []
        out = []
        for line in (r.stdout or '').splitlines():
            parts = line.split()
            if len(parts) < 2 or parts[0] in ('List', '*'):
                continue
            d = {'serial': parts[0], 'state': parts[1], 'model': '',
                 'product': ''}
            for kv in parts[2:]:
                if ':' in kv:
                    k, _, v = kv.partition(':')
                    if k in ('model', 'product'):
                        d[k] = v
            out.append(d)
        return out

    # -- 便捷封装 ----------------------------------------------------
    def shell(self, serial: str, *args, timeout=120):
        return self._run(['-s', serial, 'shell'] + list(args), timeout=timeout)

    def run_as(self, serial: str, *args, timeout=120):
        return self._run(['-s', serial, 'shell', 'run-as', PKG] + list(args),
                         timeout=timeout)

    def push(self, serial: str, local: str, remote: str, timeout=1800):
        return self._run(['-s', serial, 'push', local, remote],
                         timeout=timeout)


# ------------------------------------------------------------------ 计划

class SyncItem:
    """一条待推送的 ROM。

    ``name`` 是落盘文件名(只做 Android 非法字符消毒, 中文原样保留);
    ``display_name`` 是用户库里的原始文件名(展示用, 写进索引 originalName)。
    旧版 ``safe_name`` 把非 ASCII 字符(含中文)一律替换成 ``_``, 导致手机上
    游戏库显示 ``__.gba`` / ``____ .nes`` 这类乱码名, 且同名碰撞还会静默
    覆盖/丢条目 —— 现已改为与 App 端 Kotlin ``sanitize`` 同策略。
    """
    __slots__ = ('path', 'name', 'display_name', 'platform', 'crc', 'size',
                 'rel')

    def __init__(self, path, name, platform, crc='', size=0, rel='',
                 display_name=''):
        self.path = path
        self.name = name
        self.display_name = display_name or name
        self.platform = platform
        self.crc = crc
        self.size = size
        self.rel = rel

    def to_entry(self) -> dict:
        return {
            'name': self.name,
            'originalName': self.display_name,
            'relativePath': self.rel,
            'size': self.size,
            'crc32': int(self.crc, 16) if self.crc else 0,
            'platform': self.platform,
            'importedAt': time.strftime('%Y-%m-%dT%H:%M:%S'),
            'lastPlayedAt': None,
            'genre': None, 'developer': None, 'publisher': None,
            'releaseDate': None, 'region': None, 'players': None,
            'description': None, 'category': None, 'coverRelative': None,
        }


#: App 侧的 PlatformKind 取值
PLATFORM_KIND = {
    'gba': 'gba', 'nes': 'nes', 'neogeo': 'neogeo',
    'cps1': 'mame', 'cps2': 'mame', 'arcade': 'mame',
    'snes': 'snes', 'n64': 'n64', 'nds': 'nds', 'ps1': 'ps1',
}
#: 目标子目录(街机 zip 靠子目录名让 App 判定平台)
PLATFORM_SUBDIR = {
    'gba': 'gba', 'nes': 'nes', 'neogeo': 'neogeo',
    'cps1': 'cps1', 'cps2': 'cps2', 'arcade': 'arcade',
}


#: Android(ext4/f2fs)文件系统非法字符 —— 与 App 端 Kotlin ``sanitize`` 完全一致。
#: 只替换这些字符, 中文等 Unicode 字符原样保留(App 的 SAF 导入本来就允许中文
#: 文件名, 手机私有目录存 UTF-8 名没有问题; adb push / run-as cp 走字节透传)。
_ILLEGAL_NAME_RE = re.compile(r'[\\/:*?"<>|\x00-\x1f]+')


def safe_name(name: str) -> str:
    """Android 文件名消毒: 只替换非法字符, 保留中文。

    历史坑: 旧实现 ``[^0-9A-Za-z._()\\[\\] +-]`` 把所有非 ASCII(含中文)换成
    ``_``, 于是 ``CT特种部队.gba`` 落盘成 ``CT____.gba``、索引 originalName
    同样被抹掉, 手机游戏库满屏 ``__.gba``; 且不同中文名会碰撞到同一目标名,
    后者静默覆盖前者(索引按 relativePath 去重还会丢条目)。
    """
    cleaned = _ILLEGAL_NAME_RE.sub('_', str(name)).strip()
    return cleaned or 'rom'


def _unique_rel(used: set, sub: str, name: str) -> str:
    """同一平台目录内重名时追加 `` (n)``(与 App 端 uniqueName 同风格)。"""
    rel = 'roms/%s/%s' % (sub, name)
    if rel not in used:
        return rel
    stem, ext = os.path.splitext(name)
    n = 2
    while rel in used:
        rel = 'roms/%s/%s (%d)%s' % (sub, stem, n, ext)
        n += 1
    return rel


def build_plan(games: list, bios: list, cheats_by_crc: dict,
               compute_crc=None) -> dict:
    """由本地库记录构造推送计划(不触碰手机)。"""
    items = []
    used_rels = set()
    for g in games:
        src = g.get('path') or ''
        if not src or not os.path.isfile(src):
            continue
        plat = g.get('platform', '')
        sub = PLATFORM_SUBDIR.get(plat, 'other')
        raw = g.get('file') or os.path.basename(src)
        name = safe_name(raw)
        crc = g.get('crc') or ''
        if not crc and compute_crc:
            crc = compute_crc(src)
        if not crc:
            crc = crc32_file(src)
        rel = _unique_rel(used_rels, sub, name)
        used_rels.add(rel)
        items.append(SyncItem(src, name, PLATFORM_KIND.get(plat, 'unknown'),
                              crc.upper(), os.path.getsize(src), rel, raw))
    return {
        'items': items,
        'bios': [{'name': safe_name(os.path.basename(b['path'])),
                  'path': b['path']} for b in bios],
        'cheats': cheats_by_crc or {},
    }


# ------------------------------------------------------------------ 落地

class RepairResult:
    def __init__(self):
        self.total = 0
        self.matched = 0
        self.fixed = 0
        self.renamed = 0
        self.unmatched = 0
        self.ops = 0
        self.log = []

    def as_text(self) -> str:
        return ('索引 %d 条: 匹配本地 %d, 修复名字 %d(重命名文件 %d), '
                '未匹配 %d'
                % (self.total, self.matched, self.fixed, self.renamed,
                   self.unmatched))


def plan_repairs(remote_index: list, local_by_crc: dict) -> tuple:
    """按 CRC 把手机索引里被 ``safe_name`` 抹成下划线的名字修回本地真实文件名。

    纯函数(不碰设备), 便于离线自测。返回 ``(new_index, ops, stats)``:

    * ``new_index``  —— 修复后的索引(原顺序, 修改了 name/originalName/
      relativePath; 不匹配本地库的条目原样保留);
    * ``ops``        —— ``[(old_rel, new_rel), ...]`` 需要在设备上 ``mv`` 的文件;
    * ``stats``      —— :class:`RepairResult`(字段已填好, 仅 ``log`` 未用)。

    ``local_by_crc``: 大写 CRC hex -> 游戏记录(至少含 ``file``; 否则退而取
    ``path`` 的 basename)。
    """
    new_index = []
    ops = []
    used_recent = set()
    stats = RepairResult()
    stats.total = len(remote_index)
    for entry in remote_index:
        if not isinstance(entry, dict):
            new_index.append(entry)
            continue
        crc32 = entry.get('crc32')
        crc = None
        if isinstance(crc32, int):
            crc = '%08X' % (crc32 & 0xFFFFFFFF)
        g = local_by_crc.get(crc) if crc else None
        if g is None:
            stats.unmatched += 1
            new_index.append(entry)
            continue
        stats.matched += 1
        raw = g.get('file') or os.path.basename(g.get('path') or '')
        name = safe_name(raw)
        old_rel = str(entry.get('relativePath') or '')
        d, _base = os.path.split(old_rel)
        new_rel = ('%s/%s' % (d, name)) if d else name
        # 同一批次内再次出现同一目标名时追加 (n) 去重
        if new_rel in used_recent:
            stem, ext = os.path.splitext(name)
            n = 2
            while new_rel in used_recent:
                new_rel = ('%s/%s (%d)%s' % (d, stem, n, ext)) if d \
                    else ('%s (%d)%s' % (stem, n, ext))
                n += 1
        used_recent.add(new_rel)

        changed = (entry.get('name') != name
                   or entry.get('originalName') != raw
                   or old_rel != new_rel)
        if changed:
            e = dict(entry)
            e['name'] = name
            e['originalName'] = raw
            e['relativePath'] = new_rel
            new_index.append(e)
            stats.fixed += 1
            if old_rel != new_rel and old_rel:
                ops.append((old_rel, new_rel))
                stats.renamed += 1
        else:
            new_index.append(entry)
    return new_index, ops, stats


def _sh_quote(s: str) -> str:
    return "'" + str(s).replace("'", "'\\''") + "'"


def _sh_dquote(s: str) -> str:
    """双引号包裹(用于 ``$F/...`` 这种需要变量展开的上下文)。

    注意: 不能用 :func:`_sh_quote` 把整段再塞进双引号里 —— 单引号在双引号内会变成
    字面量, 导致路径形如 ``"$F/'roms/__.gba'"`` 匹配不到文件(修复脚本曾因此静默跳过
    全部 mv, 索引改了名但磁盘文件没动)。这里只转义 ``\\ " ```(文件名经 safe_name
    后本就不会含这些, 但多一层保险), ``$`` 保留交给 shell 展开。
    """
    return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') \
        .replace('`', '\\`') + '"'


class SyncResult:
    def __init__(self):
        self.pushed_roms = 0
        self.skipped_roms = 0
        self.bios = 0
        self.cheat_crcs = 0
        self.index_count = 0
        self.log = []

    def as_text(self) -> str:
        return ('ROM 新增 %d / 已存在 %d; BIOS %d; 金手指 CRC %d; '
                '索引合计 %d 条'
                % (self.pushed_roms, self.skipped_roms, self.bios,
                   self.cheat_crcs, self.index_count))


def _read_remote_json(adb: Adb, serial: str, rel: str):
    """用 run-as cat 读取手机私有目录里的 JSON。"""
    r = adb.run_as(serial, 'cat', rel, timeout=60)
    if r.returncode != 0 or not (r.stdout or '').strip():
        return None
    try:
        return json.loads(r.stdout)
    except Exception:
        return None


class PhoneSync:
    def __init__(self, adb: Adb, serial: str):
        self.adb = adb
        self.serial = serial

    # -- 环境探测 ----------------------------------------------------
    def probe(self) -> dict:
        """返回 {'ok':bool,'msg':str,'roms':int,'index':int,'bios':int}"""
        if not self.adb.ok():
            return {'ok': False, 'msg': '未找到 adb, 请在设置里指定 adb 路径'}
        r = self.adb.run_as(self.serial, 'ls', 'files', timeout=30)
        if r.returncode != 0:
            return {'ok': False,
                    'msg': ('run-as 失败(%s)。请安装 debuggable 的调试包, '
                            '或改用局域网「伙伴」模式由手机主动拉取。'
                            % (r.stderr or r.stdout or '').strip()[:120])}
        idx = _read_remote_json(self.adb, self.serial, 'files/rom_index.json')
        n_roms = 0
        if isinstance(idx, list):
            n_roms = len(idx)
        r2 = self.adb.run_as(self.serial, 'ls', 'files/system', timeout=30)
        n_bios = len([x for x in (r2.stdout or '').split() if x.endswith('.zip')])
        return {'ok': True, 'msg': '已连接', 'roms': n_roms,
                'index': n_roms, 'bios': n_bios}

    def remote_index(self) -> list:
        idx = _read_remote_json(self.adb, self.serial, 'files/rom_index.json')
        return idx if isinstance(idx, list) else []

    # -- 修复中文名 ---------------------------------------------------
    def repair_names(self, games: list, on_log=print) -> RepairResult:
        """按 CRC 把手机游戏库里被 ``safe_name`` 抹成下划线的名字修回真实中文名。

        流程: 读索引 -> 按 CRC 对照本地库 -> 在设备端 ``mv`` 重命名文件 ->
        回写 ``rom_index.json``(先备份 .bak)。不推送任何游戏内容。
        """
        local_by_crc = {}
        for g in games:
            crc = str(g.get('crc') or '').upper()
            if not crc and g.get('path') and os.path.isfile(g['path']):
                crc = crc32_file(g['path']).upper()
            if crc:
                local_by_crc[crc] = g
        remote = self.remote_index()
        new_index, ops, stats = plan_repairs(remote, local_by_crc)
        on_log('手机索引 %d 条; 本地对照命中 %d, 需修复 %d(重命名 %d)'
               % (stats.total, stats.matched, stats.fixed, stats.renamed))

        if not stats.fixed:
            on_log('无需修复(名字都正常)。')
            return stats

        stage_local = tempfile.mkdtemp(prefix='gpsync_')
        tag = STAGE_PREFIX + str(int(time.time()))
        payload = os.path.join(stage_local, 'payload')
        try:
            os.makedirs(payload, exist_ok=True)
            with open(os.path.join(payload, 'rom_index.json'), 'w',
                      encoding='utf-8') as f:
                json.dump(new_index, f, ensure_ascii=False, indent=1)
            script = ['set -e', 'F=files',
                      'if [ -f "$F/rom_index.json" ]; then cp -f '
                      '"$F/rom_index.json" "$F/rom_index.json.bak"; fi']
            for old_rel, new_rel in ops:
                # 仅当源存在、目标不存在时才重命名, 避免误删/覆盖。
                # 注意: 这里必须用 _sh_dquote(双引号内可让 $F 展开), 不能用
                # _sh_quote(单引号在双引号内变成字面量, 路径匹配不到文件)。
                script.append(
                    'if [ -f %s ] && [ ! -e %s ]; then mv -f %s %s; fi'
                    % (_sh_dquote('$F/' + old_rel),
                       _sh_dquote('$F/' + new_rel),
                       _sh_dquote('$F/' + old_rel),
                       _sh_dquote('$F/' + new_rel)))
            script.append('cp -f %s "$F/rom_index.json"'
                          % _sh_quote('/data/local/tmp/%s/payload/'
                                      'rom_index.json' % tag))
            with open(os.path.join(stage_local, 'install.sh'), 'w',
                      encoding='utf-8', newline='\n') as f:
                f.write('\n'.join(script) + '\n')

            remote_dir = '/data/local/tmp/' + tag
            on_log('推送修复脚本 -> %s' % remote_dir)
            r = self.adb.push(self.serial, stage_local, remote_dir)
            if r.returncode != 0:
                raise RuntimeError('adb push 失败: %s'
                                   % (r.stderr or r.stdout).strip()[:200])
            on_log('在手机端重命名并写回索引…')
            r = self.adb.run_as(self.serial, 'sh', remote_dir + '/install.sh',
                                timeout=1800)
            if r.returncode != 0:
                raise RuntimeError('修复失败: %s'
                                   % (r.stderr or r.stdout).strip()[:300])
            on_log('修复完成。')
        finally:
            try:
                self.adb.shell(self.serial, 'rm', '-rf',
                               '/data/local/tmp/' + tag, timeout=60)
            except Exception:
                pass
            shutil.rmtree(stage_local, ignore_errors=True)
        return stats

    # -- 推送 --------------------------------------------------------
    def push(self, plan: dict, overwrite_cheats: bool = False,
             on_log=print, on_progress=None) -> SyncResult:
        res = SyncResult()
        stage_local = tempfile.mkdtemp(prefix='gpsync_')
        tag = STAGE_PREFIX + str(int(time.time()))
        payload = os.path.join(stage_local, 'payload')
        try:
            # 1) 现有索引(用于去重)
            remote = self.remote_index()
            have_crc = set()
            for e in remote:
                if isinstance(e, dict) and e.get('crc32') is not None:
                    try:
                        have_crc.add('%08X' % (int(e['crc32']) & 0xFFFFFFFF))
                    except Exception:
                        pass
            on_log('手机端现有索引: %d 条' % len(remote))

            # 2) 组织暂存目录
            os.makedirs(os.path.join(payload, 'roms'), exist_ok=True)
            os.makedirs(os.path.join(payload, 'library'), exist_ok=True)
            os.makedirs(os.path.join(payload, 'system'), exist_ok=True)
            script = ['set -e', 'F=files', 'mkdir -p "$F/roms" "$F/library" '
                      '"$F/system"']
            entries = list(remote)
            known = {str(e.get('relativePath') or '') for e in entries
                     if isinstance(e, dict)}

            todo = [it for it in plan['items'] if it.crc not in have_crc]
            for i, it in enumerate(todo):
                dst_dir = os.path.join(payload, os.path.dirname(it.rel))
                os.makedirs(dst_dir, exist_ok=True)
                shutil.copy2(it.path, os.path.join(payload, it.rel))
                script.append(
                    'mkdir -p "$F/%s"' % os.path.dirname(it.rel))
                script.append('cp -f %s "$F/%s"'
                              % (_sh_quote('/data/local/tmp/%s/payload/%s'
                                           % (tag, it.rel)), it.rel))
                if it.rel not in known:
                    entries.append(it.to_entry())
                    known.add(it.rel)
                if on_progress:
                    on_progress(i + 1, len(todo), it.name)
            res.pushed_roms = len(todo)
            res.skipped_roms = len(plan['items']) - len(todo)
            on_log('ROM: 新增 %d, 手机已有 %d'
                   % (res.pushed_roms, res.skipped_roms))

            # 3) 金手指: 拉旧 -> 合并 -> 回写
            old = _read_remote_json(self.adb, self.serial,
                                    'files/library/cheats.json') or {}
            by_crc = dict(old.get('byCrc') or {})
            added = 0
            for crc, cmds in (plan.get('cheats') or {}).items():
                k = str(crc).upper()
                if k in by_crc and not overwrite_cheats:
                    continue
                if not cmds:
                    continue
                by_crc[k] = cmds
                added += 1
            res.cheat_crcs = added
            if by_crc:
                with open(os.path.join(payload, 'library', 'cheats.json'),
                          'w', encoding='utf-8') as f:
                    json.dump({'version': 1, 'byCrc': by_crc}, f,
                              ensure_ascii=False, indent=1)
                script.append('cp -f %s "$F/library/cheats.json"'
                              % _sh_quote('/data/local/tmp/%s/payload/'
                                          'library/cheats.json' % tag))
            on_log('金手指: 合并 %d 个 CRC(原有 %d)'
                   % (added, len(old.get('byCrc') or {})))

            # 4) BIOS
            for b in plan.get('bios') or []:
                shutil.copy2(b['path'], os.path.join(payload, 'system',
                                                     b['name']))
                script.append('cp -f %s "$F/system/%s"'
                              % (_sh_quote('/data/local/tmp/%s/payload/'
                                           'system/%s' % (tag, b['name'])),
                                 b['name']))
                res.bios += 1
            on_log('BIOS: %d 个' % res.bios)

            # 5) rom_index.json(先备份)
            with open(os.path.join(payload, 'rom_index.json'), 'w',
                      encoding='utf-8') as f:
                json.dump(entries, f, ensure_ascii=False, indent=1)
            res.index_count = len(entries)
            script.append('if [ -f "$F/rom_index.json" ]; then cp -f '
                          '"$F/rom_index.json" "$F/rom_index.json.bak"; fi')
            script.append('cp -f %s "$F/rom_index.json"'
                          % _sh_quote('/data/local/tmp/%s/payload/'
                                      'rom_index.json' % tag))

            with open(os.path.join(stage_local, 'install.sh'), 'w',
                      encoding='utf-8', newline='\n') as f:
                f.write('\n'.join(script) + '\n')

            # 6) 推到手机并执行
            remote_dir = '/data/local/tmp/' + tag
            on_log('推送暂存目录 -> %s' % remote_dir)
            r = self.adb.push(self.serial, stage_local, remote_dir)
            if r.returncode != 0:
                raise RuntimeError('adb push 失败: %s'
                                   % (r.stderr or r.stdout).strip()[:200])
            on_log('以 App 身份写入私有目录…')
            r = self.adb.run_as(self.serial, 'sh', remote_dir + '/install.sh',
                                timeout=1800)
            if r.returncode != 0:
                raise RuntimeError('写入失败: %s'
                                   % (r.stderr or r.stdout).strip()[:300])
            on_log('写入完成。')
        finally:
            try:
                self.adb.shell(self.serial, 'rm', '-rf',
                               '/data/local/tmp/' + tag, timeout=60)
            except Exception:
                pass
            shutil.rmtree(stage_local, ignore_errors=True)
        return res

    def launch_app(self) -> bool:
        r = self.adb.shell(
            self.serial, 'monkey', '-p', PKG,
            '-c', 'android.intent.category.LAUNCHER', '1', timeout=60)
        return r.returncode == 0


# ------------------------------------------------------------------ CLI

def _main(argv):  # pragma: no cover
    import argparse
    ap = argparse.ArgumentParser(description='推送本地库到手机')
    ap.add_argument('--adb', default='')
    ap.add_argument('--serial', default='')
    ap.add_argument('--repair', action='store_true',
                    help='按 CRC 把手机游戏库里被抹成下划线的中文名修回真实名')
    ap.add_argument('--root', default='',
                    help='--repair 时本地库根(含 roms/), 默认仓库内 .tools/gstest')
    args = ap.parse_args(argv)
    adb = Adb(args.adb)
    if not adb.ok():
        print('未找到 adb:', find_adb())
        return 1
    devs = adb.devices()
    if not devs:
        print('没有设备')
        return 1
    for d in devs:
        print(d)
    serial = args.serial or devs[0]['serial']
    ps = PhoneSync(adb, serial)
    if args.repair:
        root = os.path.abspath(args.root or
                               os.path.join(_HERE, '..', '..', '.tools',
                                            'gstest'))
        print('本地库根:', root)
        games = []
        roms_dir = os.path.join(root, 'roms')
        if os.path.isdir(roms_dir):
            for dirpath, _dirs, files in os.walk(roms_dir):
                for f in files:
                    p = os.path.join(dirpath, f)
                    plat = os.path.basename(os.path.dirname(p)).lower()
                    games.append({'path': p, 'file': f, 'platform': plat,
                                  'crc': ''})
        res = ps.repair_names(games, on_log=print)
        print(res.as_text())
        return 0
    print(ps.probe())
    return 0


if __name__ == '__main__':  # pragma: no cover
    raise SystemExit(_main(sys.argv[1:]))
