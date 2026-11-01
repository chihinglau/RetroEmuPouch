#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""peer_host.py 存档/设置同步端点单测(网络无关, 直接调 handle)。"""
import os
import tempfile
import types

import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from peer_host import PeerHost  # noqa: E402


def _host():
    tmp = tempfile.mkdtemp(prefix='peer_sync_test_')
    h = PeerHost(name='test', library={}, log=lambda *a, **k: None)
    h.devices = {'dev1': {'token': 'tok123'}}
    # 把同步目录重定向到临时目录, 避免污染仓库
    h._sync_root = types.MethodType(lambda self: tmp, h)
    return h


def _auth():
    return {'Authorization': 'Peer tok123'}


def test_save_roundtrip():
    h = _host()
    st, pl = h.handle(None, 'PUT', '/api/peer/sync/save/ABCD1234/save1.sav',
                      b'hello', _auth())
    assert st == 200 and pl.get('ok'), pl
    st, pl = h.handle(None, 'GET', '/api/peer/sync/save', b'', _auth())
    assert st == 200 and len(pl['saves']) == 1, pl
    assert pl['saves'][0]['name'] == 'save1.sav', pl
    st, pl = h.handle(None, 'GET',
                      '/api/peer/sync/save/ABCD1234/save1.sav', b'', _auth())
    assert st == 200, (st, pl)  # _FileResponse
    # 目录穿越必须被拒
    st, pl = h.handle(None, 'GET',
                      '/api/peer/sync/save/ABCD1234/..%2f..%2fx', b'', _auth())
    assert st != 200, pl
    # 坏 crc
    st, pl = h.handle(None, 'GET',
                      '/api/peer/sync/save/ZZZZ/save1.sav', b'', _auth())
    assert st == 400, pl


def test_settings_roundtrip():
    h = _host()
    st, pl = h.handle(None, 'PUT', '/api/peer/sync/settings',
                      b'{"padScale":1.2}', _auth())
    assert st == 200, pl
    st, pl = h.handle(None, 'GET', '/api/peer/sync/settings', b'', _auth())
    assert st == 200 and pl.get('padScale') == 1.2, pl
    h2 = _host()
    st, pl = h2.handle(None, 'GET', '/api/peer/sync/settings', b'', _auth())
    assert st == 404, pl


def test_unauthorized():
    h = _host()
    st, pl = h.handle(None, 'GET', '/api/peer/sync/save', b'', {})
    assert st == 401, pl
    st, pl = h.handle(None, 'PUT', '/api/peer/sync/settings',
                      b'{}', {})
    assert st == 401, pl


if __name__ == '__main__':
    test_save_roundtrip()
    test_settings_roundtrip()
    test_unauthorized()
    print('ALL OK')
