import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../data/cloud/cloud_client.dart'
    show CloudClient, CloudSaveSummary, CloudException;
import '../../features/account/account_backend.dart' show openAccountStore;
import '../../features/cloud/cloud_crypto.dart';
import '../../features/membership/membership.dart' show Membership;
import '../../pal/platform_pal.dart' show PlatformPal;

/// 云存档 UI（会员专属）：列表 / 上传 / 下载 / 删除。
///
/// 合规红线：存档在客户端以 [CloudCrypto]（AES-256-GCM）加密后上传，服务端不解密。
/// 加密密码由用户设定，按 userId 存于 [FlutterSecureStorage]（同设备免重复输入；
/// 换设备重新输入同一密码即可还原密钥，实现跨设备恢复）。
class CloudSaveSection extends StatefulWidget {
  const CloudSaveSection({
    super.key,
    required this.userId,
    required this.pal,
  });

  final String userId;
  final PlatformPal pal;

  @override
  State<CloudSaveSection> createState() => _CloudSaveSectionState();
}

class _CloudSaveSectionState extends State<CloudSaveSection> {
  static const _sec = FlutterSecureStorage();

  CloudClient? _client;
  List<CloudSaveSummary> _saves = const [];
  bool _busy = false;
  bool _entitled = false;
  String? _passphrase;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final store = await openAccountStore();
      _client = CloudClient(store);
      final m = await Membership.instance;
      _entitled = m.entitlement.current.cloudSaveEnabled;
      _passphrase =
          await _sec.read(key: 'cloud_save_pwd_${widget.userId}');
      if (_entitled && _passphrase != null) await _refresh();
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (_client == null || _passphrase == null) return;
    setState(() => _busy = true);
    try {
      _saves = await _client!.listSaves();
      _error = null;
    } on CloudException catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ensurePassphrase() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PassphraseDialog(
        onSet: (pwd) async {
          await _sec.write(
              key: 'cloud_save_pwd_${widget.userId}', value: pwd);
          _passphrase = pwd;
        },
      ),
    );
    if (ok == true && mounted) await _refresh();
  }

  Future<void> _upload() async {
    if (_client == null || _passphrase == null) return;
    setState(() => _busy = true);
    try {
      final dir = await widget.pal.filesDir();
      final meta = File('$dir/library/cloud_metadata.json');
      final cheats = File('$dir/library/cloud_cheats.json');
      final payload = <String, dynamic>{
        'app': 'RetroEmuPouch',
        'exportedAt': DateTime.now().toIso8601String(),
        'note': '客户端 AES-256-GCM 加密后上传，服务端不解密',
      };
      if (await meta.exists()) {
        payload['cloud_metadata'] =
            jsonDecode(await meta.readAsString());
      }
      if (await cheats.exists()) {
        payload['cloud_cheats'] =
            jsonDecode(await cheats.readAsString());
      }
      final saveName =
          'retroemupouch_backup_${DateTime.now().millisecondsSinceEpoch}.json';
      // 先写明文临时文件，uploadSave 内部会加密后再上传。
      final tmp = File('$dir/cloud_saves/.upload_tmp');
      await tmp.parent.create(recursive: true);
      await tmp.writeAsBytes(utf8.encode(jsonEncode(payload)));
      final id = await _client!.uploadSave(
        saveName: saveName,
        clientKey: saveName,
        file: tmp,
        passphrase: _passphrase!,
      );
      await tmp.delete();
      if (mounted) _snack('已加密上传（id=$id）');
      await _refresh();
    } on CloudException catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(CloudSaveSummary s) async {
    if (_client == null || _passphrase == null) return;
    setState(() => _busy = true);
    try {
      final dir = await widget.pal.filesDir();
      final name = s.saveName.contains('.')
          ? s.saveName
          : '${s.saveName}.bin';
      final dest = File('$dir/cloud_saves/$name');
      await _client!.downloadSave(s.id, dest: dest, passphrase: _passphrase!);
      if (mounted) _snack('已下载并解密：$name');
    } on CloudException catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(CloudSaveSummary s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除云存档'),
        content: Text('确定删除「${s.saveName}」？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || _client == null) return;
    setState(() => _busy = true);
    try {
      await _client!.deleteSave(s.id);
      if (mounted) _snack('已删除 ${s.saveName}');
      await _refresh();
    } on CloudException catch (e) {
      _snack(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          error ? Theme.of(context).colorScheme.errorContainer : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!_entitled) {
      return const Text('云存档是会员核心权益之一，升级会员后即可解锁'
          '（进度、设置、金手指随身加密同步到你的私有云）。');
    }
    if (_passphrase == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('首次使用云存档需设置「云存档密码」：用于在客户端加密你的存档，'
              '服务端无法解密，请务必牢记（换设备重新输入同一密码即可恢复）。'),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _busy ? null : _ensurePassphrase,
            icon: const Icon(Icons.lock_outline),
            label: const Text('设置云存档密码'),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('已加密同步 · 服务端不解密',
                  style: Theme.of(context).textTheme.labelSmall),
            ),
            if (_busy)
              const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _upload,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('备份当前库设置'),
        ),
        const SizedBox(height: 10),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(_error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error)),
          ),
        if (_saves.isEmpty && _error == null)
          const Text('暂无云端存档。', style: TextStyle(color: Colors.grey))
        else
          ..._saves.map((s) => _saveTile(s)),
      ],
    );
  }

  Widget _saveTile(CloudSaveSummary s) {
    final size = (s.sizeBytes / 1024).toStringAsFixed(1);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.save_outlined),
      title: Text(s.saveName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('${size} KB · ${_fmt(s.updatedAt)}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '下载并解密',
            onPressed: _busy ? null : () => _download(s),
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: _busy ? null : () => _delete(s),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// 设置云存档密码（两次输入一致）。
class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({required this.onSet});
  final Future<void> Function(String pwd) onSet;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _c1 = TextEditingController();
  final _c2 = TextEditingController();
  var _busy = false;
  String? _err;

  Future<void> _submit() async {
    final p1 = _c1.text;
    if (p1.length < 6 || p1.length > 64) {
      setState(() => _err = '密码需 6~64 位');
      return;
    }
    if (p1 != _c2.text) {
      setState(() => _err = '两次输入的密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await widget.onSet(p1);
      if (!mounted) return;
      Navigator.pop(context, true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('设置云存档密码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('该密码用于在客户端加密你的存档，服务端无法解密。'
              '忘记密码将无法恢复已加密的存档。',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 12),
          TextField(
            controller: _c1,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '云存档密码（6~64 位）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _c2,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '确认密码',
              border: OutlineInputBorder(),
            ),
          ),
          if (_err != null) ...[
            const SizedBox(height: 8),
            Text(_err!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消')),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('确定'),
        ),
      ],
    );
  }
}
