#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""模拟手机端完整走一遍伙伴协议, 验证 PC 服务端可用(自测局域网功能)。"""
import os
import sys
import time
import json
import secrets
import threading
import urllib.request
import urllib.error

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import peer_host as ph  # noqa: E402

FAIL = []


def check(name, cond, extra=''):
    print(('  OK   ' if cond else '  FAIL ') + name + ('  ' + extra if extra else ''))
    if not cond:
        FAIL.append(name)


def http(method, url, body=None, token=None, timeout=30):
    data = None
    if body is not None:
        data = json.dumps(body).encode('utf-8')
    req = urllib.request.Request(url, data=data, method=method)
    if data is not None:
        req.add_header('Content-Type', 'application/json')
    if token is not None:
        req.add_header('Authorization', 'Peer ' + token)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')


def main():
    # ---- 构造一个内存库
    root = os.path.join(_HERE, 'sample_lib')
    os.makedirs(root, exist_ok=True)
    games = [
        {'crc': '0AA11AA2', 'relativePath': 'roms/gba/sample.gba', 'name': 'sample.gba',
         'originalName': '示例游戏', 'platform': 'gba', 'size': 12345, 'has_cheats': True},
    ]
    by_crc = {'0AA11AA2': [
        {'name': '无限生命', 'kind': 'switch', 'code': '12345678 9ABCDEF0', 'enabled': False},
    ]}
    bios = [{'name': 'neogeo.zip', 'path': os.path.join(root, 'bios', 'neogeo.zip'), 'size': 10}]
    os.makedirs(os.path.join(root, 'bios'), exist_ok=True)
    with open(bios[0]['path'], 'wb') as f:
        f.write(b'BIOSDATA')

    host = ph.PeerHost(name='测试 PC', library={
        'games': games, 'cheats': by_crc, 'bios': bios, 'roms': {
            '0AA11AA2': os.path.join(root, 'sample.gba')},
    }, log=lambda s: None)
    port = host.start()
    base = 'http://127.0.0.1:%d' % port
    check('服务启动', port > 0, str(port))

    # ---- 发现(PONG)
    info = http('GET', base + '/api/peer/info')[1]
    info = json.loads(info)
    check('info.service 正确', info.get('service') == 'GamePouch Peer')
    check('info.deviceId 非空', bool(info.get('deviceId')))
    # 注意: /api/peer/info 不返回 httpPort(由 UDP PONG 告知), 故此处不校验。

    # ---- 配对: 手机发起 start
    pair_id = secrets.token_hex(16)        # 32 hex
    code = '042917'
    token_a = secrets.token_hex(32)        # 64 hex
    st, body = http('POST', base + '/api/peer/pair/start', {
        'pairId': pair_id, 'code': code, 'deviceId': 'phone-xyz',
        'name': '我的手机', 'tokenA': token_a})
    check('pair/start 返回 200', st == 200, str(st))
    check('pair/start 含 ttlMs', 'ttlMs' in json.loads(body))

    # ---- 未确认时 confirm 应返回 202 responder_pending
    st, body = http('POST', base + '/api/peer/pair/confirm',
                    {'pairId': pair_id, 'code': code})
    check('未确认 confirm 返回 202', st == 202, str(st))
    check('202 带 responder_pending', json.loads(body).get('error') == 'responder_pending')

    # ---- PC 用户确认
    host.confirm_pair(pair_id)
    # 稍等确保 gate 已释放
    time.sleep(0.1)
    st, body = http('POST', base + '/api/peer/pair/confirm',
                    {'pairId': pair_id, 'code': code})
    check('确认后 confirm 返回 200', st == 200, str(st))
    tok = json.loads(body).get('token')
    check('confirm 返回 token', bool(tok), str(tok))

    # ---- 用拿到的 token 拉库
    st, body = http('GET', base + '/api/peer/library', token=tok)
    check('library 返回 200', st == 200, str(st))
    lib = json.loads(body)
    check('library.games 含 1 个', len(lib.get('games') or []) == 1)
    g0 = lib['games'][0]
    check('game.crc 8 位大写', g0.get('crc') == '0AA11AA2', str(g0.get('crc')))
    check('game.hasCheats=True', g0.get('hasCheats') is True)
    check('game.platform=gba', g0.get('platform') == 'gba')

    # ---- 拉金手指
    st, body = http('GET', base + '/api/peer/cheats/0AA11AA2', token=tok)
    check('cheats 返回 200', st == 200, str(st))
    ch = json.loads(body)
    check('cheats 含 1 条', len(ch.get('cheats') or []) == 1)
    check('cheat 名=无限生命', ch['cheats'][0].get('name') == '无限生命')

    # ---- 拉 BIOS 列表 + 单文件
    st, body = http('GET', base + '/api/peer/bios', token=tok)
    check('bios 列表 200', st == 200, str(st))
    bios_list = json.loads(body).get('bios') or []
    check('bios 列表含 neogeo.zip', any(b['name'] == 'neogeo.zip' for b in bios_list))
    st, _ = http('GET', base + '/api/peer/bios/' + 'neogeo.zip', token=tok)
    check('bios 单文件 200', st == 200, str(st))

    # ---- 用错 token 应 401
    st, _ = http('GET', base + '/api/peer/library', token='deadbeef' * 8)
    check('错 token -> 401', st == 401, str(st))

    # ---- 未带 token 应 401
    st, _ = http('GET', base + '/api/peer/library')
    check('无 token -> 401', st == 401, str(st))

    host.stop()
    print('\n' + ('全部通过' if not FAIL else '失败: %s' % FAIL))
    raise SystemExit(1 if FAIL else 0)


if __name__ == '__main__':
    main()
