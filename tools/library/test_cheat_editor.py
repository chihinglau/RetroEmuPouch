#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自测: PC 金手指编辑器(新增/保存) + 金手指经局域网正确下发。"""
import os
import sys
import json
import tempfile
import shutil

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, '..', 'chatsync'))

import library_manager as lm  # noqa: E402
import peer_host  # noqa: E402
import sync_cheats  # noqa: E402

# 测试环境里 messagebox 会弹模态框阻塞, 这里改成空操作。
lm.messagebox.showwarning = lambda *a, **k: None
lm.messagebox.showinfo = lambda *a, **k: None

FAIL = []


def check(name, cond, extra=''):
    print(('  OK   ' if cond else '  FAIL ') + name + ('  ' + extra if extra else ''))
    if not cond:
        FAIL.append(name)


# 1) 对话框产出正确的 CheatInfo 结构
app = lm.App()
try:
    app.withdraw()
    dlg = lm.CheatCmdDialog(app, None)
    dlg.name.insert(0, '无限金币')
    dlg.code.insert('1.0', '1234 5678\n9ABC DEF0')
    dlg.enabled.set(True)
    dlg._ok()
    r = dlg.result
    check('对话框返回结果', r is not None)
    check('name 正确', r['name'] == '无限金币')
    check('code 多行保留', r['code'] == '1234 5678\n9ABC DEF0')
    check('enabled=True', r['enabled'] is True)
    check('含 options/selected', 'options' in r and 'selected' in r)
    dlg.destroy()

    # 2) 空代码应被拒绝
    dlg2 = lm.CheatCmdDialog(app, None)
    dlg2._ok()
    check('空代码被拒绝(result=None)', dlg2.result is None)
    dlg2.destroy()

    # 3) _merge_cheats_json 写入 app 兼容格式
    tmp = tempfile.mkdtemp(prefix='gp_cheat_')
    app.root_dir.set(tmp)
    chats = os.path.join(tmp, 'chats')
    os.makedirs(chats, exist_ok=True)
    game = {'stem': 'T', 'cheat_file': '', 'crc': '0AA11AA2', 'path': 'x',
            'platform': 'gba',
            'cheats': [{'name': '无限生命', 'code': '1111 2222',
                        'enabled': False, 'options': [], 'selected': -1}]}
    app.cur_cheat_target = ('G', game)
    app.cur_cheat_items = game['cheats']
    app._save_cheat_target()

    cht = os.path.join(chats, 'T.cht')
    check('.cht 已生成', os.path.isfile(cht))
    back = sync_cheats.parse_cht_text(open(cht, encoding='utf-8').read())
    check('.cht 回读一致', back and back[0]['name'] == '无限生命'
          and back[0]['code'] == '1111 2222', str(back))

    cj = os.path.join(chats, 'cheats.json')
    cjobj = json.load(open(cj, encoding='utf-8'))
    check('cheats.json 含 byCrc', 'byCrc' in cjobj)
    check('byCrc[CRC] 内容正确', cjobj['byCrc']['0AA11AA2'][0]['name']
          == '无限生命')
    # app 兼容: 字段 name/code/enabled
    e = cjobj['byCrc']['0AA11AA2'][0]
    check('字段 app 兼容', all(k in e for k in ('name', 'code', 'enabled')))

    # 4) 局域网下发: 游戏含金手指时 payload.hasCheats=True 且 cheats 可达
    games = [dict(game)]
    lib = peer_host.build_library(games, [], {})
    check('库 cheats 映射含该 CRC', bool(lib['cheats'].get('0AA11AA2')))
    host = peer_host.PeerHost(library=lib, log=lambda s: None)
    port = host.start()
    payload = host.build_library_payload()
    g0 = payload['games'][0]
    check('payload.hasCheats=True', g0['hasCheats'] is True)

    # 5) 模拟手机配对后拉取 cheats 端点(需 token)
    import urllib.request
    import urllib.error
    import secrets

    def _req(method, path, body=None, token=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            'http://127.0.0.1:%d%s' % (port, path), data=data, method=method)
        if data is not None:
            req.add_header('Content-Type', 'application/json')
        if token is not None:
            req.add_header('Authorization', 'Peer ' + token)
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                return r.status, r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode()

    pid = secrets.token_hex(16)
    st, _ = _req('POST', '/api/peer/pair/start', {
        'pairId': pid, 'code': '123456', 'deviceId': 'phone-x',
        'name': '测试机', 'tokenA': secrets.token_hex(32)})
    check('pair/start 200', st == 200, str(st))
    host.confirm_pair(pid)
    st, body = _req('POST', '/api/peer/pair/confirm',
                    {'pairId': pid, 'code': '123456'})
    check('pair/confirm 200', st == 200, str(st))
    token = json.loads(body).get('token')
    st, body = _req('GET', '/api/peer/cheats/0AA11AA2', token=token)
    check('带 token 拉取 cheats 200', st == 200, str(st))
    data = json.loads(body)
    check('拉取 cheats 含命令', data['cheats'][0]['name'] == '无限生命')
    host.stop()
finally:
    app.destroy()
    shutil.rmtree(tmp, ignore_errors=True)

print('\n' + ('全部通过' if not FAIL else '失败: %s' % FAIL))
raise SystemExit(1 if FAIL else 0)
