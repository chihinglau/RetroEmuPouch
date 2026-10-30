#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""peer_host 自测: 用 Python 模拟「手机端」走完发现 → 配对 → 拉取全流程。

不需要真手机; 客户端严格按 app/lib/data/peer/*.dart 的协议发报文。
"""
from __future__ import annotations

import json
import os
import secrets
import socket
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
import peer_host as ph  # noqa: E402

FAIL = []


def check(name, cond, extra=''):
    print(('  OK   ' if cond else '  FAIL ') + name + ('  ' + extra if extra else ''))
    if not cond:
        FAIL.append(name)


def http(method, url, body=None, token=None):
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    if token:
        headers['Authorization'] = 'Peer ' + token
    req = urllib.request.Request(url, data=data, headers=headers,
                                 method=method)
    def parse(raw):
        if not raw:
            return {}
        try:
            return json.loads(raw.decode('utf-8'))
        except Exception:
            return raw

    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            ct = (r.headers.get('Content-Type') or '')
            raw = r.read()
            return r.status, (parse(raw) if 'json' in ct else raw)
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, parse(raw)


def get_json(url, token=None):
    st, raw = http('GET', url, token=token)
    if isinstance(raw, bytes):
        raw = json.loads(raw.decode('utf-8')) if raw else {}
    return st, raw


# ---------------------------------------------------------------- 造数据
tmp = tempfile.mkdtemp(prefix='gp_peer_')
rom = os.path.join(tmp, 'demo.gba')
with open(rom, 'wb') as f:
    f.write(b'FAKE-ROM' + bytes(range(256)) * 40)
bios = os.path.join(tmp, 'neogeo.zip')
with open(bios, 'wb') as f:
    f.write(b'PK\3\4' + b'\0' * 64)
import zlib  # noqa: E402

CRC = '%08X' % (zlib.crc32(open(rom, 'rb').read()) & 0xFFFFFFFF)
CHEATS = [{'name': '无限生命', 'kind': 'switch', 'code': '00A2:09',
           'enabled': False}]

print('== 1. 组装 library ==')
lib = ph.build_library(
    [{'path': rom, 'file': 'demo.gba', 'stem': 'demo', 'platform': 'gba',
      'size': os.path.getsize(rom), 'crc': CRC, 'cheats': CHEATS}],
    [{'path': bios, 'name': 'neogeo.zip'}],
    {CRC: CHEATS})
check('games 一条', len(lib['games']) == 1)
check('roms 索引含 CRC', lib['roms'].get(CRC) == rom, CRC)
check('bios 一条', len(lib['bios']) == 1)
payload_games = lib['games'][0]
check('platform 映射 gba', payload_games['platform'] == 'gba')
check('relativePath', payload_games['relativePath'] == 'roms/gba/demo.gba',
      payload_games['relativePath'])

print('\n== 2. 启动服务 ==')
host = ph.PeerHost(name='测试用 PC 库', library=lib, log=lambda s: print('   ·', s))
port = host.start()
check('HTTP 端口已分配', port > 0, str(port))
ip = ph.local_ip()
check('取到局域网 IP', ip not in ('', '127.0.0.1'), ip)

print('\n== 3. UDP 发现(PING/PONG) ==')
try:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(('127.0.0.1', 0))
    s.settimeout(4)
    s.sendto(ph.PING_MAGIC.encode('utf-8'), ('127.0.0.1', ph.UDP_PORT))
    data, _ = s.recvfrom(2048)
    msg = data.decode('utf-8')
    check('收到 PONG 前缀', msg.startswith(ph.PONG_PREFIX))
    j = json.loads(msg[len(ph.PONG_PREFIX):])
    check('service 正确', j.get('service') == ph.SERVICE_TAG)
    check('httpPort 与本机一致', j.get('httpPort') == port, str(j.get('httpPort')))
    check('protocolVersion=1', j.get('protocolVersion') == 1)
    s.close()
except Exception as ex:
    check('UDP 发现', False, repr(ex))

base = 'http://127.0.0.1:%d' % port
print('\n== 4. GET /api/peer/info ==')
st, j = get_json(base + '/api/peer/info')
check('200', st == 200, str(st))
check('service 字段', j.get('service') == ph.SERVICE_TAG)
check('deviceId 存在', bool(j.get('deviceId')))

print('\n== 5. 未授权访问被拒 ==')
st, j = get_json(base + '/api/peer/library')
check('401', st == 401, str(st))
st, j = get_json(base + '/api/peer/library', token='deadbeef')
check('错误 token 也是 401', st == 401, str(st))

print('\n== 6. 配对流程(模拟手机) ==')
pair_id = 'pair-' + secrets.token_hex(6)
code = '481902'
token_a = secrets.token_hex(32)
st, j = http('POST', base + '/api/peer/pair/start',
             {'pairId': pair_id, 'code': code, 'deviceId': 'phone-test-1',
              'name': '测试手机', 'tokenA': token_a})
check('pair/start 200', st == 200, str(j))
check('返回 ttlMs', isinstance(j.get('ttlMs'), int) if hasattr(j, 'get') else False)
pending = host.pending_pairs()
check('UI 收到待确认请求', any(p.pair_id == pair_id for p in pending))
check('请求里带 6 位码', pending and pending[0].code == code)

# 未确认 -> 202 responder_pending(需要并发等待)
result = {}

def call_confirm():
    result['r'] = http('POST', base + '/api/peer/pair/confirm',
                       {'pairId': pair_id, 'code': code})

t = threading.Thread(target=call_confirm, daemon=True)
t.start()
time.sleep(0.6)
st2, j2 = http('POST', base + '/api/peer/pair/confirm',
               {'pairId': pair_id, 'code': '000000'})
check('错误码 -> bad_code', st2 == 400 and j2.get('error') == 'bad_code',
      str(j2))
host.confirm_pair(pair_id)
t.join(30)
st3, j3 = result.get('r', (0, {}))
check('确认后返回 200', st3 == 200, str(j3))
token_b = j3.get('token') if isinstance(j3, dict) else None
check('签发 tokenB(64 hex)', bool(token_b) and len(token_b) == 64)
check('返回本端 deviceId', j3.get('deviceId') == host.device_id)
check('设备已记录', 'phone-test-1' in host.devices)

print('\n== 7. 已授权拉取 ==')
st, j = get_json(base + '/api/peer/library', token=token_a)
check('library 200', st == 200, str(st))
check('games 一条', len(j.get('games', [])) == 1)
g = j['games'][0]
check('crc 大写 8 位', g.get('crc') == CRC, str(g.get('crc')))
check('hasCheats=True', g.get('hasCheats') is True)
check('hasBattery/hasAuto 为 false',
      g.get('hasBattery') is False and g.get('hasAuto') is False)
check('slots 为数组', isinstance(g.get('slots'), list))

st, j = get_json(base + '/api/peer/cheats/' + CRC, token=token_a)
check('cheats 200', st == 200, str(st))
check('cheats 内容一致', j.get('cheats') == CHEATS)

st, raw = http('GET', base + '/api/peer/rom/' + CRC, token=token_a)
check('rom 下载 200', st == 200, str(st))
check('rom 字节一致', raw == open(rom, 'rb').read(), '%d 字节' % len(raw))

st, j = get_json(base + '/api/peer/bios', token=token_a)
check('bios 列表 200', st == 200)
check('bios 含 neogeo.zip',
      any(b['name'] == 'neogeo.zip' for b in j.get('bios', [])))
st, raw = http('GET', base + '/api/peer/bios/neogeo.zip', token=token_a)
check('bios 下载 200', st == 200, '%d 字节' % len(raw))

st, j = get_json(base + '/api/peer/rom/00000000', token=token_a)
check('不存在的 CRC -> 404', st == 404, str(st))

print('\n== 8. 停止服务 ==')
host.stop()
try:
    st, j = get_json(base + '/api/peer/info')
    check('停止后不可访问', False)
except Exception:
    check('停止后不可访问', True)

print('\n' + ('全部通过' if not FAIL else '失败: %s' % FAIL))
raise SystemExit(1 if FAIL else 0)
