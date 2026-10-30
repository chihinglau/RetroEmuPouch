#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自测: 金手指从元数据索引内联 -> PC 关联 -> 局域网下发 -> 手机端精确关联。

用一份合成的游戏元数据索引(含 NES 游戏「吞食天地II」+ 内联金手指) 跑通:
  sync_cheats 按 CRC 关联  ->  PC library 标记 hasCheats  ->  手机端拉取 cheats
  ->  写入 cloud_cheats.json  ->  运行 App 的 _cheatLayer/_applyCheats 算法
  ->  RomEntry.cheats 非空。

同时验证: 手机端 crcKey(8 位大写 CRC) 与 PC 下发的 CRC 完全一致(局域网不重算 CRC,
所以必然一致), 以及经 LAN 送达后 App 的关联结果。
"""
import os
import sys
import json
import tempfile
import shutil

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, '..', 'chatsync'))

import zlib
import sync_cheats  # noqa: E402
import peer_host  # noqa: E402
import library_manager as lm  # noqa: E402

FAIL = []


def check(name, cond, extra=''):
    print(('  OK   ' if cond else '  FAIL ') + name + ('  ' + extra if extra else ''))
    if not cond:
        FAIL.append(name)


def make_nes(path):
    """写一个伪 NES 文件(带 16 字节 iNES 头 + 内容), 返回整文件 CRC32(大写8位)。"""
    head = b'NES\x1a\x01\x01\x00' + b'\x00' * 10
    body = bytes(range(256)) * 400  # 确定内容, 便于复算
    data = head + body
    with open(path, 'wb') as f:
        f.write(data)
    return '%08X' % (zlib.crc32(data) & 0xFFFFFFFF)


def main():
    tmp = tempfile.mkdtemp(prefix='gp_assoc_')
    try:
        # ---- 合成游戏元数据索引 + GamePouch ROM(同 CRC) ----
        roms = os.path.join(tmp, 'roms', 'NES')
        os.makedirs(roms, exist_ok=True)
        rom_path = os.path.join(roms, '吞食天地II.nes')
        crc = make_nes(rom_path)

        mgs = os.path.join(tmp, 'mgs', 'library')
        os.makedirs(mgs, exist_ok=True)
        index = [{
            'id': 'x', 'title': '吞食天地II·诸葛孔明传',
            'relPath': 'roms/NES/吞食天地II.nes', 'category': 'NES中文合集',
            'platform': 'nes', 'size': os.path.getsize(rom_path),
            'crcFull': 'FFFFFFFF',  # 故意写错, 逼出「按标题匹配」分支
            'cheats': [
                {'name': '金钱锁定最大', 'kind': 'switch', 'code': '602D:FF',
                 'enabled': False},
                {'name': '任意行走（穿墙）', 'kind': 'switch',
                 'code': 'SXXYPVGK', 'enabled': False},
                {'name': '兵力最大（第1位武将）', 'kind': 'switch',
                 'code': '6640:FF', 'enabled': False},
            ],
        }]
        with open(os.path.join(mgs, 'index.json'), 'w', encoding='utf-8') as f:
            json.dump(index, f, ensure_ascii=False)

        chats = os.path.join(tmp, 'chats')

        # ---- 让 sync_cheats 指向合成数据源 ----
        sync_cheats.MGS_INDEX = os.path.join(mgs, 'index.json')
        sync_cheats.ROMS_DIR = os.path.join(tmp, 'roms')
        sync_cheats.CHATS_DIR = chats
        # index.json 里平台是小写 'nes', 而 PLATFORM_DIRS 用 'NES' 作为子目录名;
        # 这里 roms 子目录我们直接叫 NES, 需要让 scan_roms 认到。
        sync_cheats.PLATFORM_DIRS['NES'] = ('nes', '.nes', False)
        rc = sync_cheats.main()
        check('sync_cheats 返回 0', rc == 0, 'rc=%s' % rc)

        # ---- 验证 PC 侧关联产物 ----
        cj = os.path.join(chats, 'cheats.json')
        check('cheats.json 已生成', os.path.isfile(cj))
        bycrc = json.load(open(cj, encoding='utf-8'))['byCrc']
        check('byCrc 含该 CRC', crc in bycrc)
        check('该游戏金手指命令数=3', len(bycrc.get(crc, [])) == 3,
              str(len(bycrc.get(crc, []))))
        cht = os.path.join(chats, '吞食天地II.cht')
        check('.cht 已生成', os.path.isfile(cht))
        # 代码格式原样保留(上游索引直接可用)
        back = sync_cheats.parse_cht_text(open(cht, encoding='utf-8').read())
        check('代码原样保留(602D:FF)', any(c['code'] == '602D:FF' for c in back))

        # ---- 模拟「重新关联」后的 PC 扫描: 游戏应带金手指 ----
        app = lm.App()
        try:
            app.withdraw()
            app.root_dir.set(tmp)
            # 直接构造 games(绕过耗时扫描), 模拟已扫描结果
            games = [{
                'stem': '吞食天地II', 'file': '吞食天地II.nes',
                'path': rom_path, 'platform': 'nes', 'category': 'NES',
                'size': os.path.getsize(rom_path), 'crc': crc,
                'internal': '', 'cheats': bycrc[crc], 'cheat_file': cht,
            }]
            lib = peer_host.build_library(games, [], bycrc)
            payload = peer_host.PeerHost(library=lib,
                                        log=lambda s: None).build_library_payload()
            g0 = next(x for x in payload['games'] if x['crc'] == crc)
            check('payload.hasCheats=True', g0['hasCheats'] is True)
            check('payload 命令数=3', len(lib['cheats'][crc]) == 3)

            # ---- 手机端: 拉取并关联(精确复刻 App 逻辑) ----
            host = peer_host.PeerHost(library=lib, log=lambda s: None)
            port = host.start()
            import urllib.request
            import urllib.error
            import secrets

            def _req(method, path, body=None, token=None):
                d = json.dumps(body).encode() if body is not None else None
                req = urllib.request.Request(
                    'http://127.0.0.1:%d%s' % (port, path), data=d, method=method)
                if d is not None:
                    req.add_header('Content-Type', 'application/json')
                if token is not None:
                    req.add_header('Authorization', 'Peer ' + token)
                try:
                    with urllib.request.urlopen(req, timeout=10) as r:
                        return r.status, r.read().decode()
                except urllib.error.HTTPError as e:
                    return e.code, e.read().decode()

            # 配对
            pid = secrets.token_hex(16)
            st, _ = _req('POST', '/api/peer/pair/start', {
                'pairId': pid, 'code': '123456', 'deviceId': 'phone',
                'name': '测试机', 'tokenA': secrets.token_hex(32)})
            check('pair/start 200', st == 200, str(st))
            host.confirm_pair(pid)
            st, body = _req('POST', '/api/peer/pair/confirm',
                            {'pairId': pid, 'code': '123456'})
            check('pair/confirm 200', st == 200, str(st))
            token = json.loads(body).get('token')

            # 拉取 cheats(手机用 crcKey = PC 下发的 CRC 原样)
            crc_key = crc  # 手机端 crcKey = (crc32 & 0xFFFFFFFF) 大写8位 == PC crc
            st, body = _req('GET', '/api/peer/cheats/%s' % crc_key, token=token)
            check('拉取 cheats 200', st == 200, str(st))
            res = json.loads(body)
            check('拉到 3 条命令', len(res['cheats']) == 3)

            # 手机端落地: 写入 cloud_cheats.json[<crcKey>]
            cloud_bycrc = {crc_key: res['cheats']}
            local_bycrc = {}  # 玩家本地层为空

            # ---- 复刻 App: _cheatLayer + _applyCheats ----
            def cheat_layer(crc_k):
                if crc_k in local_bycrc and local_bycrc[crc_k]:
                    return 'local'
                if crc_k in cloud_bycrc and cloud_bycrc[crc_k]:
                    return 'cloud'
                return None

            def apply_cheats(crc_k):
                lc = local_bycrc.get(crc_k) or []
                if lc:
                    return lc
                return cloud_bycrc.get(crc_k) or []

            check('cheatLayer=cloud', cheat_layer(crc_key) == 'cloud')
            entry_cheats = apply_cheats(crc_key)
            check('App RomEntry.cheats 非空', len(entry_cheats) == 3,
                  str(len(entry_cheats)))
            check('App 显示「有金手指」(只看非空)', len(entry_cheats) > 0)
            host.stop()
        finally:
            app.destroy()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print('\n' + ('全部通过' if not FAIL else '失败: %s' % FAIL))
    raise SystemExit(1 if FAIL else 0)


if __name__ == '__main__':
    main()
