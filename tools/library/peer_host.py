#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
局域网「伙伴」服务端 —— 让手机主动把本地库拉走
==============================================

手机端 GamePouch 自带「发现伙伴」(``peers_page``) 功能, 但它只会**主动拉取**,
不提供任何上传接口。好在协议是开放的: 任何设备只要

  1. 在 UDP 43801 上应答 ``GP-PEER-PING`` 广播,
  2. 起一个 HTTP 服务实现 ``/api/peer/*`` 那几条路由,

就能被手机发现、配对、并被当作「游戏库来源」导入。本模块就是这个服务端的
Python 实现, 于是不用 USB、不用 adb、release 包也能同步:

    手机: 我的 → 发现伙伴 → 看到「GamePouch 库管理(PC)」→ 配对 → 导入

协议要点(与 app/lib/data/peer/*.dart 严格对齐)
---------------------------------------------
* PING: 手机向 255.255.255.255:43801 广播纯文本 ``GP-PEER-PING``
* PONG: 单播回 ``GP-PEER-PONG {"service":"GamePouch Peer","deviceId":...,
  "name":...,"httpPort":...,"protocolVersion":1}`` (IP 以 UDP 源地址为准)
* HTTP: ``GET /api/peer/info`` 公开; 配对三条 POST 公开; 其余需要
  ``Authorization: Peer <token>``
* 配对: 手机 POST ``/pair/start``(自带 6 位 code 与 tokenA) → 本端弹确认 →
  手机轮询 ``/pair/confirm``(未确认返回 202 ``responder_pending``) →
  本端签发 tokenB 回传。
* 文件: ``GET /api/peer/rom/{crc8}`` / ``cheats/{crc8}`` / ``bios`` /
  ``bios/{name}`` / ``cover/{crc8}``
"""
from __future__ import annotations

import json
import os
import re
import secrets
import socket
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UDP_PORT = 43801
PING_MAGIC = 'GP-PEER-PING'
PONG_PREFIX = 'GP-PEER-PONG '
SERVICE_TAG = 'GamePouch Peer'
PROTOCOL_VERSION = 1
PAIR_TTL = 120.0          # 与 Dart 侧 pairTtl 一致
RESPONDER_WAIT = 20.0     # 与 Dart 侧 responderWait 一致
MAX_CODE_ATTEMPTS = 5

_PAIR_ID_RE = re.compile(r'^[A-Za-z0-9_-]{8,64}$')
_CODE_RE = re.compile(r'^\d{6}$')
_TOKEN_RE = re.compile(r'^[0-9a-f]{64}$')
_CRC_RE = re.compile(r'^[0-9A-F]{8}$')


def _safe_name(name: str):
    """解码并拒绝任何可能穿越目录的名字(拒绝 / \\ 与 . / ..)。"""
    name = urllib.parse.unquote(name)
    if not name or '/' in name or '\\' in name or name in ('.', '..'):
        return None
    if len(name) > 200:
        return None
    return name


_HERE = os.path.dirname(os.path.abspath(__file__))
DEVICES_FILE = os.path.join(_HERE, '.peer_devices.json')


def local_ip() -> str:
    """取一个能出网的局域网 IPv4(不会真的发包)。"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(0.2)
        s.connect(('223.5.5.5', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        try:
            return socket.gethostbyname(socket.gethostname())
        except Exception:
            return '127.0.0.1'


def crc8(raw: str) -> str:
    u = str(raw or '').upper()
    if not _CRC_RE.match(u):
        raise ValueError('bad crc: %r' % raw)
    return u


class PairRequest:
    __slots__ = ('pair_id', 'device_id', 'name', 'code', 'expires')

    def __init__(self, pair_id, device_id, name, code, expires):
        self.pair_id = pair_id
        self.device_id = device_id
        self.name = name
        self.code = code
        self.expires = expires


class PeerHost:
    """PC 端伙伴服务。library 为一个 dict, 见模块尾部 build_library()。"""

    def __init__(self, name: str = '', library: dict | None = None,
                 log=print, enable_mdns: bool = True):
        self.name = name or ('GamePouch 库管理 (%s)' % socket.gethostname())
        # mDNS 广播让手机端用 LAN mDNS 发现本服务(服务类型 _retroemupouch._tcp.local),
        #作为现有 UDP 43801 广播发现的补充; AP 隔离/广播被过滤时仍能发现。
        # 未装 zeroconf 时自动降级为仅 UDP 发现, 不影响其它功能。
        self.enable_mdns = enable_mdns
        self._mdns = None
        # device_id 必须跨进程重启保持稳定, 否则手机端保存的配对会失效,
        # 每次重启 PC 都要重新配对(手机会把它当成全新未配对设备)。
        self.device_id = self._load_or_create_self_id()
        self.library = library or {}
        self.log = log
        self.http_port = 0
        self._httpd = None
        self._udp_sock = None
        self._udp_thread = None
        self._sessions: dict[str, dict] = {}
        self.devices: dict[str, dict] = {}
        self.pair_requests: list[PairRequest] = []
        self._lock = threading.Lock()
        self._load_devices()

    # ---------------------------------------------------------- 生命周期
    @property
    def running(self) -> bool:
        return self._httpd is not None

    def start(self) -> int:
        if self._httpd:
            return self.http_port
        httpd = ThreadingHTTPServer(('0.0.0.0', 0), _make_handler(self))
        self._httpd = httpd
        self.http_port = httpd.server_address[1]
        threading.Thread(target=httpd.serve_forever, daemon=True).start()

        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(('', UDP_PORT))
            self._udp_sock = s
            self._udp_thread = threading.Thread(target=self._udp_loop,
                                                daemon=True)
            self._udp_thread.start()
        except Exception as ex:  # noqa: BLE001
            self.log('UDP %d 绑定失败: %s(手机将无法自动发现, 但仍可手动连接)'
                     % (UDP_PORT, ex))
        self._start_mdns()
        self.log('伙伴服务已启动: %s:%d' % (local_ip(), self.http_port))
        return self.http_port

    def stop(self):
        self._stop_mdns()
        if self._udp_sock:
            try:
                self._udp_sock.close()
            except Exception:
                pass
            self._udp_sock = None
        if self._httpd:
            try:
                self._httpd.shutdown()
                self._httpd.server_close()
            except Exception:
                pass
            self._httpd = None
        self.log('伙伴服务已停止')

    # ---------------------------------------------------------- mDNS 广播
    def _start_mdns(self):
        """Advertise over LAN mDNS so phones can discover us without UDP
        broadcast (works behind AP isolation). Degrades silently when
        `zeroconf` is not installed."""
        if not self.enable_mdns:
            return
        try:
            from zeroconf import Zeroconf, ServiceInfo  # lazy: optional dep
        except Exception as ex:  # noqa: BLE001
            self.log('mDNS 跳过(未装 zeroconf; pip install zeroconf 可启用): %s' % ex)
            return
        try:
            ip = local_ip()
            info = ServiceInfo(
                '_retroemupouch._tcp.local.',
                '%s._retroemupouch._tcp.local.' % self.device_id,
                addresses=[socket.inet_aton(ip)],
                port=self.http_port,
                properties={
                    'deviceId': self.device_id,
                    'name': self.name,
                    'protocolVersion': str(PROTOCOL_VERSION),
                },
                server='%s.local.' % self.device_id,
            )
            zc = Zeroconf()
            zc.register_service(info)
            self._mdns = zc
            self.log('mDNS 已广播: _retroemupouch._tcp.local → http://%s:%d'
                     % (ip, self.http_port))
        except Exception as ex:  # noqa: BLE001
            self.log('mDNS 广播失败(不影响 UDP 发现): %s' % ex)

    def _stop_mdns(self):
        zc = self._mdns
        self._mdns = None
        if zc is None:
            return
        try:
            zc.unregister_all_services()
        except Exception:
            pass
        try:
            zc.close()
        except Exception:
            pass

    # ---------------------------------------------------------- UDP 发现
    def _udp_loop(self):
        s = self._udp_sock
        pong = None
        while s is not None:
            try:
                data, addr = s.recvfrom(1024)
            except OSError:
                return
            try:
                msg = data.decode('utf-8').strip()
            except Exception:
                continue
            if msg != PING_MAGIC:
                continue
            if pong is None or pong[1] != self.http_port:
                body = json.dumps({'service': SERVICE_TAG,
                                   'deviceId': self.device_id,
                                   'name': self.name,
                                   'httpPort': self.http_port,
                                   'protocolVersion': PROTOCOL_VERSION},
                                  ensure_ascii=False)
                pong = ((PONG_PREFIX + body).encode('utf-8'), self.http_port)
            try:
                s.sendto(pong[0], addr)
                self.log('发现广播 <- %s' % addr[0])
            except OSError:
                pass

    # ---------------------------------------------------------- 配对状态
    def _load_or_create_self_id(self) -> str:
        """读取/生成本机稳定 deviceId(跨重启不变)。"""
        f = os.path.join(_HERE, '.peer_self.json')
        try:
            if os.path.isfile(f):
                j = json.load(open(f, 'r', encoding='utf-8'))
                did = str(j.get('deviceId') or '')
                if did:
                    return did
        except Exception:
            pass
        did = 'pc-' + secrets.token_hex(8)
        try:
            with open(f, 'w', encoding='utf-8') as fp:
                json.dump({'deviceId': did}, fp)
        except Exception:
            pass
        return did

    def _load_devices(self):
        if os.path.isfile(DEVICES_FILE):
            try:
                with open(DEVICES_FILE, 'r', encoding='utf-8') as f:
                    self.devices = json.load(f)
            except Exception:
                self.devices = {}

    def _save_devices(self):
        try:
            with open(DEVICES_FILE, 'w', encoding='utf-8') as f:
                json.dump(self.devices, f, ensure_ascii=False, indent=1)
        except Exception:
            pass

    def pending_pairs(self) -> list:
        now = time.time()
        with self._lock:
            self.pair_requests = [p for p in self.pair_requests
                                  if p.expires > now]
            return list(self.pair_requests)

    def confirm_pair(self, pair_id: str):
        with self._lock:
            s = self._sessions.get(pair_id)
            self.pair_requests = [p for p in self.pair_requests
                                  if p.pair_id != pair_id]
        if s:
            s['confirmed'] = True
            s['gate'].set()

    def reject_pair(self, pair_id: str):
        with self._lock:
            self._sessions.pop(pair_id, None)
            self.pair_requests = [p for p in self.pair_requests
                                  if p.pair_id != pair_id]

    def forget(self, device_id: str):
        self.devices.pop(device_id, None)
        self._save_devices()

    # ---------------------------------------------------------- 库数据
    def _game_entry(self, crc: str):
        for g in self.library.get('games') or []:
            if str(g.get('crc', '')).upper() == crc:
                return g
        return None

    def build_library_payload(self) -> dict:
        games = []
        for g in self.library.get('games') or []:
            crc = str(g.get('crc', '')).upper()
            if not _CRC_RE.match(crc):
                continue
            e = dict(g)
            e['crc'] = crc
            e.setdefault('name', os.path.basename(
                g.get('relativePath') or ''))
            e.setdefault('originalName', e['name'])
            e.setdefault('relativePath', 'roms/%s' % e['name'])
            e.setdefault('platform', 'nes')
            e.setdefault('size', 0)
            cheats = (self.library.get('cheats') or {}).get(crc)
            e['hasCheats'] = bool(cheats)
            e['hasBattery'] = False
            e['batterySize'] = 0
            e['batteryMtime'] = None
            e['hasAuto'] = False
            e['autoSize'] = 0
            e['autoMtime'] = None
            e['slots'] = []
            cov = (self.library.get('covers') or {}).get(crc)
            e['hasCover'] = bool(cov)
            e['coverSize'] = os.path.getsize(cov) if cov and os.path.isfile(
                cov) else 0
            e['metadata'] = None
            games.append(e)
        return {'service': SERVICE_TAG, 'deviceId': self.device_id,
                'name': self.name, 'protocolVersion': PROTOCOL_VERSION,
                'games': games}

    # ---------------------------------------------------------- HTTP 路由
    def handle(self, h: BaseHTTPRequestHandler, method: str, path: str,
               body: bytes, headers) -> tuple:
        """返回 (status, payload)。payload 为 dict/list 时按 JSON 发送。"""
        self.log('HTTP %s %s' % (method, path))
        if method == 'GET' and path == '/api/peer/info':
            return 200, {'service': SERVICE_TAG, 'deviceId': self.device_id,
                         'name': self.name, 'appVersion': 'library-manager',
                         'protocolVersion': PROTOCOL_VERSION}
        if method == 'POST' and path == '/api/peer/pair/start':
            return self._pair_start(body)
        if method == 'POST' and path == '/api/peer/pair/confirm':
            return self._pair_confirm(body, h)
        if method == 'POST' and path == '/api/peer/pair/cancel':
            try:
                pid = (json.loads(body or b'{}') or {}).get('pairId')
            except Exception:
                pid = None
            if isinstance(pid, str):
                self.reject_pair(pid)
            return 200, {'ok': True}

        # ---- 以下需要 Peer token
        auth = (headers.get('Authorization') or '')
        if not auth.startswith('Peer '):
            return 401, {'error': 'unauthorized'}
        token = auth[5:].strip()
        dev = next((d for d in self.devices.values()
                    if d.get('token') == token
                    or d.get('outboundToken') == token), None)
        if dev is None:
            return 401, {'error': 'unauthorized'}

        if method == 'GET' and path == '/api/peer/library':
            return 200, self.build_library_payload()
        if method == 'GET' and path.startswith('/api/peer/rom/'):
            return self._send_rom(path[len('/api/peer/rom/'):])
        if method == 'GET' and path.startswith('/api/peer/cover/'):
            return self._send_cover(path[len('/api/peer/cover/'):])
        if method == 'GET' and path.startswith('/api/peer/cheats/'):
            try:
                crc = crc8(path[len('/api/peer/cheats/'):])
            except ValueError:
                return 400, {'error': 'bad_crc'}
            cmds = (self.library.get('cheats') or {}).get(crc)
            if not cmds:
                return 404, {'error': 'no_cheats'}
            return 200, {'crc': crc, 'cheats': cmds}
        if method == 'GET' and path == '/api/peer/bios':
            return 200, {'bios': [{'name': b['name'], 'size': b.get('size', 0)}
                                  for b in self.library.get('bios') or []]}
        if method == 'GET' and path.startswith('/api/peer/bios/'):
            name = urllib.parse.unquote(path[len('/api/peer/bios/'):])
            for b in self.library.get('bios') or []:
                if b['name'] == name and os.path.isfile(b['path']):
                    return 200, _FileResponse(b['path'],
                                              'application/octet-stream')
            return 404, {'error': 'not_found'}

        # ---- 存档/设置同步 (Phase 1: 仅用户数据, 不含 ROM/BIOS 二进制) ----
        if method == 'GET' and path == '/api/peer/sync/save':
            return self._sync_save_list()
        if (method == 'GET' or method == 'PUT') and path.startswith(
                '/api/peer/sync/save/'):
            parts = path[len('/api/peer/sync/save/'):].split('/')
            if len(parts) != 2:
                return 400, {'error': 'bad_path'}
            try:
                crc = crc8(parts[0])
            except ValueError:
                return 400, {'error': 'bad_crc'}
            safe = _safe_name(parts[1])
            if safe is None:
                return 400, {'error': 'bad_name'}
            if method == 'GET':
                return self._send_save(crc, safe)
            return self._recv_save(crc, safe, body)
        if method == 'GET' and path == '/api/peer/sync/settings':
            return self._send_settings()
        if method == 'PUT' and path == '/api/peer/sync/settings':
            return self._recv_settings(body)

        return 404, {'error': 'not_found'}

    def _pair_start(self, body: bytes):
        try:
            j = json.loads(body or b'{}')
        except Exception:
            return 400, {'error': 'bad_json'}
        pid, code = j.get('pairId'), j.get('code')
        did, name, token_a = j.get('deviceId'), j.get('name'), j.get('tokenA')
        checks = {
            'pairId': isinstance(pid, str) and bool(_PAIR_ID_RE.match(pid)),
            'code': isinstance(code, str) and bool(_CODE_RE.match(code)),
            'deviceId': isinstance(did, str) and bool(did),
            'name': isinstance(name, str) and bool(name.strip()),
            'tokenA': isinstance(token_a, str) and bool(_TOKEN_RE.match(token_a)),
        }
        if not all(checks.values()):
            self.log('配对请求被拒(400): 失败字段=%s 收到=%r'
                     % ([k for k, v in checks.items() if not v],
                        {k: (v[:8] + '...' if isinstance(v, str) and len(v) > 12 else v)
                         for k, v in j.items()}))
            return 400, {'error': 'bad_request'}
        if did == self.device_id:
            return 400, {'error': 'is_self'}
        with self._lock:
            if pid in self._sessions:
                return 409, {'error': 'duplicate_pair_id'}
            self._sessions[pid] = {
                'code': code, 'initiatorId': did, 'initiatorName': name.strip(),
                'tokenA': token_a, 'expires': time.time() + PAIR_TTL,
                'gate': threading.Event(), 'confirmed': False,
                'attempts': 0, 'finished': False}
            self.pair_requests.append(
                PairRequest(pid, did, name.strip(), code,
                            time.time() + PAIR_TTL))
        self.log('配对请求: %s (code %s)' % (name.strip(), code))
        return 200, {'ok': True, 'ttlMs': int(PAIR_TTL * 1000)}

    def _pair_confirm(self, body: bytes, h):
        try:
            j = json.loads(body or b'{}')
        except Exception:
            return 400, {'error': 'bad_json'}
        pid, code = j.get('pairId'), j.get('code')
        if not (isinstance(pid, str) and isinstance(code, str)):
            return 400, {'error': 'bad_request'}
        with self._lock:
            s = self._sessions.get(pid)
        if s is None or s.get('finished'):
            return 410, {'error': 'unknown_session'}
        if s['expires'] < time.time():
            self.reject_pair(pid)
            return 410, {'error': 'expired'}
        if code != s['code']:
            s['attempts'] += 1
            if s['attempts'] >= MAX_CODE_ATTEMPTS:
                self.reject_pair(pid)
                return 403, {'error': 'too_many_attempts'}
            return 400, {'error': 'bad_code',
                         'message': str(MAX_CODE_ATTEMPTS - s['attempts'])}
        if not s['confirmed']:
            s['gate'].wait(RESPONDER_WAIT)
            if not s['confirmed']:
                with self._lock:
                    alive = pid in self._sessions
                return (403, {'error': 'cancelled'}) if not alive else (
                    202, {'error': 'responder_pending'})
        with self._lock:
            if s['finished'] or s['expires'] < time.time():
                self._sessions.pop(pid, None)
                return 410, {'error': 'expired'}
            s['finished'] = True
            self._sessions.pop(pid, None)
            token_b = secrets.token_hex(32)
            self.devices[s['initiatorId']] = {
                'deviceId': s['initiatorId'], 'name': s['initiatorName'],
                'token': s['tokenA'], 'outboundToken': token_b,
                'lastIp': (h.client_address[0] if h.client_address else ''),
                'pairedAt': time.strftime('%Y-%m-%d %H:%M:%S')}
            self._save_devices()
        self.log('配对完成: %s' % s['initiatorName'])
        return 200, {'ok': True, 'token': token_b,
                     'deviceId': self.device_id, 'name': self.name}

    def _send_rom(self, crc_raw: str):
        try:
            crc = crc8(crc_raw)
        except ValueError:
            return 400, {'error': 'bad_crc'}
        p = (self.library.get('roms') or {}).get(crc)
        if not p or not os.path.isfile(p):
            return 404, {'error': 'not_found'}
        return 200, _FileResponse(p, 'application/octet-stream')

    def _send_cover(self, crc_raw: str):
        try:
            crc = crc8(crc_raw)
        except ValueError:
            return 400, {'error': 'bad_crc'}
        p = (self.library.get('covers') or {}).get(crc)
        if not p or not os.path.isfile(p):
            return 404, {'error': 'not_found'}
        return 200, _FileResponse(p, 'image/png')


    # -------------------------------------------------- 存档/设置同步 (Phase 1)
    def _sync_root(self) -> str:
        d = os.path.join(_HERE, '.peer_sync')
        if not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        return d

    def _sync_save_dir(self, crc: str) -> str:
        d = os.path.join(self._sync_root(), 'save', crc)
        if not os.path.isdir(d):
            os.makedirs(d, exist_ok=True)
        return d

    def _sync_save_list(self):
        sdir = os.path.join(self._sync_root(), 'save')
        saves = []
        if os.path.isdir(sdir):
            for crc in os.listdir(sdir):
                cd = os.path.join(sdir, crc)
                if not os.path.isdir(cd):
                    continue
                for fn in os.listdir(cd):
                    fp = os.path.join(cd, fn)
                    if os.path.isfile(fp):
                        saves.append({'crc': crc, 'name': fn,
                                      'size': os.path.getsize(fp),
                                      'mtime': int(os.path.getmtime(fp))})
        return 200, {'saves': saves}

    def _send_save(self, crc: str, name: str):
        fp = os.path.join(self._sync_save_dir(crc), name)
        if not os.path.isfile(fp):
            return 404, {'error': 'not_found'}
        return 200, _FileResponse(fp, 'application/octet-stream')

    def _recv_save(self, crc: str, name: str, body: bytes):
        if not body:
            return 400, {'error': 'empty'}
        fp = os.path.join(self._sync_save_dir(crc), name)
        try:
            with open(fp, 'wb') as f:
                f.write(body)
        except Exception as ex:  # noqa: BLE001
            return 500, {'error': 'write_failed', 'message': str(ex)}
        return 200, {'ok': True, 'size': len(body)}

    def _send_settings(self):
        fp = os.path.join(self._sync_root(), 'settings.json')
        if not os.path.isfile(fp):
            return 404, {'error': 'no_settings'}
        try:
            with open(fp, 'r', encoding='utf-8') as f:
                return 200, json.load(f)
        except Exception as ex:  # noqa: BLE001
            return 500, {'error': 'read_failed', 'message': str(ex)}

    def _recv_settings(self, body: bytes):
        try:
            data = json.loads(body or b'{}')
        except Exception:
            return 400, {'error': 'bad_json'}
        if not isinstance(data, dict):
            return 400, {'error': 'bad_shape'}
        fp = os.path.join(self._sync_root(), 'settings.json')
        try:
            with open(fp, 'w', encoding='utf-8') as f:
                json.dump(data, f, ensure_ascii=False, indent=1)
        except Exception as ex:  # noqa: BLE001
            return 500, {'error': 'write_failed', 'message': str(ex)}
        return 200, {'ok': True}

class _FileResponse:
    """标记"直接把文件流回去"。"""

    def __init__(self, path: str, content_type: str):
        self.path = path
        self.content_type = content_type


# ------------------------------------------------------------------ HTTP

def _make_handler(host: PeerHost):

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, fmt, *args):  # 静音默认日志
            pass

        def _read_body(self) -> bytes:
            # Dart 的 HttpClientRequest.write() 在未显式设置 contentLength 时
            # 会用 `Transfer-Encoding: chunked` 发送(没有 Content-Length 头)。
            # 手机端 PeerClient._postJson 正是这么发的, 因此这里必须支持
            # chunked, 否则所有 POST(/pair/start 等)都会被当成空 body 而 400。
            te = (self.headers.get('Transfer-Encoding') or '').lower()
            if 'chunked' in te:
                chunks = []
                while True:
                    line = self.rfile.readline(64)
                    if not line:
                        break  # 连接断开
                    line = line.strip()
                    if b';' in line:
                        line = line.split(b';', 1)[0]
                    try:
                        size = int(line or b'0', 16)
                    except ValueError:
                        break  # 非法 chunk 头, 防御性退出
                    if size == 0:
                        # 终结块后的尾随 CRLF / trailer
                        while True:
                            trailer = self.rfile.readline(1024)
                            if trailer in (b'\r\n', b'\n', b''):
                                break
                        break
                    chunks.append(self.rfile.read(size))
                    self.rfile.readline(64)  # 每个 chunk 后的 CRLF
                return b''.join(chunks)
            n = int(self.headers.get('Content-Length') or 0)
            return self.rfile.read(n) if n else b''

        def _respond(self):
            body = self._read_body()
            try:
                status, payload = host.handle(self, self.command,
                                              self.path.split('?')[0], body,
                                              self.headers)
            except Exception as ex:  # noqa: BLE001
                host.log('处理 %s 出错: %s' % (self.path, ex))
                status, payload = 500, {'error': 'server_error'}
            self.send_response(status)
            if isinstance(payload, _FileResponse):
                try:
                    size = os.path.getsize(payload.path)
                except OSError:
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                self.send_header('Content-Type', payload.content_type)
                self.send_header('Content-Length', str(size))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                try:
                    with open(payload.path, 'rb') as f:
                        while True:
                            chunk = f.read(1 << 20)
                            if not chunk:
                                break
                            self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            data = json.dumps(payload, ensure_ascii=False).encode('utf-8')
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self._respond()

        def do_POST(self):
            self._respond()

    return Handler


# ------------------------------------------------------------------ 组装

def build_library(games: list, bios: list, cheats_by_crc: dict,
                  crc_of=None) -> dict:
    """由本地库记录组装 peer 服务所需的 library dict。

    ``games`` 为 library_manager 的游戏记录(需 path/crc/platform/stem)。
    """
    entries, roms, cheats, covers = [], {}, {}, {}
    for g in games:
        crc = str(g.get('crc') or (crc_of(g['path']) if crc_of and
                                   g.get('path') else '')).upper()
        if not _CRC_RE.match(crc):
            continue
        ext = os.path.splitext(g.get('file') or '')[1].lower()
        sub = {'gba': 'gba', 'nes': 'nes', 'neogeo': 'neogeo',
               'cps1': 'cps1', 'cps2': 'cps2'}.get(g.get('platform'), 'other')
        name = os.path.basename(g.get('file') or g.get('path') or 'rom')
        icon = g.get('icon') or ''
        has_cover = bool(icon) and os.path.isfile(icon)
        if has_cover:
            covers[crc] = icon
        entries.append({
            'name': name, 'originalName': g.get('stem') or name,
            'name_cn': g.get('name_cn') or '',
            'relativePath': 'roms/%s/%s' % (sub, name),
            'size': g.get('size') or 0,
            'crc32': int(crc, 16),
            'platform': {'gba': 'gba', 'nes': 'nes', 'neogeo': 'neogeo',
                         'cps1': 'mame', 'cps2': 'mame',
                         'arcade': 'mame'}.get(g.get('platform'), 'unknown'),
            'crc': crc, 'hasCover': has_cover,
        })
        roms[crc] = g.get('path') or ''
        if g.get('cheats'):
            cheats[crc] = g['cheats']
    for crc, cmds in (cheats_by_crc or {}).items():
        k = str(crc).upper()
        if cmds:
            cheats.setdefault(k, cmds)
    return {
        'games': entries,
        'roms': roms,
        'cheats': cheats,
        'covers': covers,
        'bios': [{'name': os.path.basename(b['path']),
                  'size': b.get('size') or os.path.getsize(b['path'])
                  if os.path.isfile(b.get('path', '')) else 0,
                  'path': b['path']}
                 for b in bios],
    }
