import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/peer/peer_client.dart';
import '../../pal/platform_pal.dart';
import 'my_pc_service.dart';

/// Lists the user's paired PCs (from [MyPcService]) and offers save/settings
/// synchronisation buttons. Data stays inside the LAN — nothing leaves the
/// device except to the user's own paired PC.
class MyPcSection extends StatefulWidget {
  const MyPcSection({super.key, required this.pal});
  final PlatformPal pal;

  @override
  State<MyPcSection> createState() => _MyPcSectionState();
}

class _MyPcSectionState extends State<MyPcSection> {
  late final MyPcService _svc;
  List<MyPc> _pcs = const [];
  bool _loading = true;
  final Map<String, bool> _busy = {};

  @override
  void initState() {
    super.initState();
    _svc = MyPcService(widget.pal);
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      _pcs = await _svc.list();
    } catch (_) {
      _pcs = const [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _key(MyPc pc, String k) => '${pc.record.deviceId}:$k';

  Future<void> _run(MyPc pc, String label, Future<int> Function() op,
      {bool isSettings = false}) async {
    setState(() => _busy[_key(pc, label)] = true);
    try {
      final n = await op();
      if (mounted) {
        _snack(isSettings
            ? '「${pc.name}」$label 完成'
            : '「${pc.name}」$label 完成：$n 项');
      }
    } on PeerUnauthorizedException {
      if (mounted) {
        _snack('「${pc.name}」凭据已失效，请在「发现伙伴」重新配对', error: true);
      }
    } catch (e) {
      if (mounted) _snack('「${pc.name}」$label 失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy.remove(_key(pc, label)));
    }
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.redAccent : null,
    ));
  }

  Widget _btn(String label, MyPc pc, String kind, VoidCallback onTap) {
    final busy = _busy[_key(pc, kind)] == true;
    return busy
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2))
        : OutlinedButton(
            onPressed: pc.ready ? onTap : null, child: Text(label));
  }

  Widget _card(MyPc pc) {
    final addr = pc.record.lastIp != null
        ? '${pc.record.lastIp}:${pc.record.lastHttpPort}'
        : '地址未知';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(pc.ready ? Icons.computer : Icons.computer_outlined,
                  color: pc.ready ? Colors.green : Colors.orange),
              const SizedBox(width: 8),
              Expanded(
                  child: Text(pc.name,
                      style: const TextStyle(fontWeight: FontWeight.bold))),
              Text(addr, style: Theme.of(context).textTheme.bodySmall),
            ]),
            if (!pc.ready) ...[
              const SizedBox(height: 6),
              const Text('连接信息不完整（缺地址或访问凭据），请在「发现伙伴」重新配对。',
                  style: TextStyle(color: Colors.orange)),
            ],
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              _btn('上传设置', pc, 'pushS',
                  () => _run(pc, '上传设置', () async {
                        await _svc.pushSettings(pc);
                        return 0;
                      }, isSettings: true)),
              _btn('下载设置', pc, 'pullS',
                  () => _run(pc, '下载设置', () async {
                        await _svc.pullSettings(pc);
                        return 0;
                      }, isSettings: true)),
              _btn('上传存档', pc, 'pushV',
                  () => _run(pc, '上传存档', () => _svc.pushSaves(pc))),
              _btn('下载存档', pc, 'pullV',
                  () => _run(pc, '下载存档', () => _svc.pullSaves(pc))),
            ]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_pcs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Text('尚未配对任何 PC。请在「发现伙伴」中把你的电脑配对后，'
            '即可在这里同步存档与设置（数据仅在局域网内传输，ROM 不出本机）。'),
      );
    }
    return Column(children: _pcs.map(_card).toList());
  }
}
