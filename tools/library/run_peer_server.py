#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""头less 启动「伙伴」服务端, 用于真机(手机)同步联调。

等价于 PC 工具「手机同步」页背后的 PeerHost: 在 UDP 43801 应答发现广播,
起 HTTP 服务实现 /api/peer/*, 让手机「发现伙伴」发现并拉取本地库。

用法:
    python run_peer_server.py [--root .tools/gstest] [--port 0]

* --root 指向含 roms/ cheats/ bios/ 的本地库根(默认项目内 gstest)。
* 配对请求自动确认(联调用; 正式 GUI 需人工确认)。
* 日志写入同目录 peer_server.log 并在控制台打印。
"""
from __future__ import annotations
import argparse
import json
import os
import sys
import threading
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import peer_host as ph  # noqa: E402

_HERE = os.path.dirname(os.path.abspath(__file__))
ROOT_DEFAULT = os.path.normpath(os.path.join(_HERE, '..', '..', '.tools', 'gstest'))

_PLATFORM_BY_DIR = {'nes': 'nes', 'gba': 'gba', 'neogeo': 'neogeo',
                    'cps1': 'cps1', 'cps2': 'cps2'}


def scan_games(root: str):
    games = []
    roms_dir = os.path.join(root, 'roms')
    if not os.path.isdir(roms_dir):
        return games
    for sub in sorted(os.listdir(roms_dir)):
        plat = _PLATFORM_BY_DIR.get(sub.lower())
        d = os.path.join(roms_dir, sub)
        if not plat or not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            p = os.path.join(d, name)
            if not os.path.isfile(p):
                continue
            try:
                with open(p, 'rb') as f:
                    data = f.read()
                crc = '%08X' % (zlib.crc32(data) & 0xFFFFFFFF)
            except OSError:
                continue
            games.append({
                'path': p, 'file': name, 'stem': os.path.splitext(name)[0],
                'platform': plat, 'size': len(data), 'crc': crc,
                'cheats': [],
            })
    return games


def load_cheats(root: str):
    p = os.path.join(root, 'cheats', 'cheats.json')
    if not os.path.isfile(p):
        return {}
    try:
        j = json.load(open(p, 'r', encoding='utf-8'))
    except Exception:
        return {}
    return {k.upper(): v for k, v in (j.get('byCrc') or {}).items()}


def load_bios(root: str):
    out = []
    bios_dir = os.path.join(root, 'bios')
    if os.path.isdir(bios_dir):
        for name in os.listdir(bios_dir):
            p = os.path.join(bios_dir, name)
            if os.path.isfile(p):
                out.append({'name': name, 'path': p, 'size': os.path.getsize(p)})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default=ROOT_DEFAULT)
    ap.add_argument('--name', default='')
    ap.add_argument('--no-mdns', action='store_true',
                    help='禁用 mDNS 广播(仅 UDP 43801 发现)')
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    print('本地库根: %s' % root)
    games = scan_games(root)
    cheats = load_cheats(root)
    bios = load_bios(root)
    # 从仓库内置元数据索引补全中文名与封面(按 CRC 优先, 平台+英文名 次之)
    import library_meta
    meta = library_meta.GameMeta()
    if meta.available:
        meta.enrich(games)
        print('元数据补全: 中文名 %d, 封面 %d'
              % (sum(1 for g in games if g.get('name_cn')),
                 sum(1 for g in games if g.get('icon'))))
    else:
        print('提示: 未找到元数据索引(tools/library/metadata), 中文名/封面列为空; '
              '可用 GAMEPOUCH_META_DIR 指定数据源')
    print('扫描到游戏 %d 个, 金手指 %d 条(按CRC), BIOS %d 个'
          % (len(games), len(cheats), len(bios)))

    library = ph.build_library(games, bios, cheats)

    log_path = os.path.join(_HERE, 'peer_server.log')
    logf = open(log_path, 'a', encoding='utf-8')

    def log(msg):
        ts = time.strftime('%H:%M:%S')
        line = '[%s] %s' % (ts, msg)
        print(line, flush=True)
        logf.write(line + '\n')
        logf.flush()

    host = ph.PeerHost(name=args.name, library=library, log=log,
                       enable_mdns=not args.no_mdns)
    port = host.start()
    ip = ph.local_ip()
    log('服务地址: http://%s:%d  (UDP 43801 应答发现)' % (ip, port))

    confirmed = set()

    def auto_confirm_loop():
        while True:
            try:
                for pr in host.pending_pairs():
                    if pr.pair_id not in confirmed:
                        confirmed.add(pr.pair_id)
                        log('自动确认配对: %s' % pr.name)
                        host.confirm_pair(pr.pair_id)
            except Exception as ex:
                log('auto_confirm 异常: %s' % ex)
            time.sleep(0.5)

    threading.Thread(target=auto_confirm_loop, daemon=True).start()
    log('按 Ctrl+C 停止。')

    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        host.stop()
        log('已停止。')


if __name__ == '__main__':
    main()
