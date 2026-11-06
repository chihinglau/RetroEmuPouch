import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../widgets/feature_card.dart';

import '../../data/cloud/cloud_client.dart'
    show CloudClient, CloudSaveSummary, CloudException;
import '../../data/cloud/cloud_save_service.dart';
import '../../data/cloud/cloud_save_sync.dart';
import '../../data/rom_library.dart';
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
  CloudClient? _client;
  List<CloudSaveSummary> _saves = const [];
  bool _busy = false;
  bool _entitled = false;
  String? _passphrase;
  String? _error;

  /// 云存档服务（密码读取/写入与启动检查、退出自动上传共用同一套兜底逻辑）。
  CloudSaveService? _svc;

  /// 系统安全存储不可用（鸿蒙等无 flutter_secure_storage 插件实现的平台）
  /// 时置 true：密码回退到账号 KV 存储（与应用私有文件同一沙盒）。
  bool get _passViaFallback => _svc?.passViaFallback ?? false;

  // ── 真实游戏存档（saves/<CRC>.sav|.state|.slotN.state）──
  CloudSaveSync? _sync;
  List<LocalSave> _localSaves = const [];
  List<CloudSave> _cloudSaves = const [];
  SaveDiff? _diff;
  Map<String, String> _romTitles = const {};
  bool _syncing = false;
  String? _syncProgress;
  bool _restoring = false;
  String? _restoreProgress;

  /// 密码读写统一走 [CloudSaveService]：与启动检查、退出自动上传共用同一份
  /// 「安全存储 → 账号 KV 文件」兜底逻辑，避免两处实现漂移。
  Future<CloudSaveService> _service() async =>
      _svc ??= await CloudSaveService.of(widget.pal);

  Future<String?> _readPass() async => (await _service()).passphrase();

  Future<void> _writePass(String pwd) async =>
      (await _service()).setPassphrase(pwd);

  /// 进程内保留上一次成功渲染的派生状态：反复进出「网络」页时不必等本地
  /// 扫描，也不会闪一下「正在读取本机存档…」。按 userId 区分，避免换号后串数据。
  static String? _lastUserId;
  static List<CloudSaveSummary>? _lastSaves;
  static List<LocalSave>? _lastLocalSaves;
  static List<CloudSave>? _lastCloudSaves;
  static SaveDiff? _lastDiff;
  static Map<String, String>? _lastRomTitles;

  void _saveSnapshot() {
    _lastUserId = widget.userId;
    _lastSaves = _saves;
    _lastLocalSaves = _localSaves;
    _lastCloudSaves = _cloudSaves;
    _lastDiff = _diff;
    _lastRomTitles = _romTitles;
  }

  @override
  void initState() {
    super.initState();
    if (_lastUserId == widget.userId && _lastDiff != null) {
      _saves = _lastSaves ?? const [];
      _localSaves = _lastLocalSaves ?? const [];
      _cloudSaves = _lastCloudSaves ?? const [];
      _diff = _lastDiff;
      _romTitles = _lastRomTitles ?? const {};
    }
    _init();
  }

  Future<void> _init() async {
    try {
      final store = await openAccountStore();
      _client = CloudClient(store);
      final m = await Membership.instance;
      _entitled = m.entitlement.current.cloudSaveEnabled;
      _passphrase = await _readPass();
      if (_entitled && _passphrase != null) {
        // 命中本地缓存时不闪加载态：列表与差异直接从磁盘/内存恢复。
        await _refresh(silent: true);
        await _loadGameSaves();
      }
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() {});
  }

  /// 扫描本地存档 + 拉云端列表，算出差异（用于「未同步 N 份」提示）。
  Future<void> _loadGameSaves() async {
    final client = _client;
    if (client == null) return;
    try {
      final dir = await widget.pal.filesDir();
      final sync = _sync ??= CloudSaveSync(filesDir: dir, client: client);
      final local = sync.scanLocal();
      final cloud = await sync.listCloud();
      // ROM 标题只是锦上添花：库索引损坏/为空时不能让整个存档列表消失。
      var titles = const <String, String>{};
      try {
        final roms = await RomLibrary(dir).load();
        titles = {for (final r in roms) r.crcKey: r.displayTitle};
      } catch (e) {
        debugPrint('cloud save: rom titles unavailable: $e');
      }
      if (!mounted) return;
      setState(() {
        _localSaves = local;
        _cloudSaves = cloud;
        _diff = sync.diff(local, cloud);
        _romTitles = titles;
      });
      _saveSnapshot();
    } on CloudException catch (e) {
      if (mounted) _snack('读取云端存档失败：$e', error: true);
    } catch (e) {
      if (mounted) _snack('扫描本地存档失败：$e', error: true);
    }
  }

  /// 从云端恢复存档（[items] 为空表示云端全部）。
  ///
  /// 覆盖本地前会自动生成 `<存档>.bak-<时间戳>`，失败时不动本地文件。
  Future<void> _restoreSaves({List<CloudSave>? items}) async {
    final sync = _sync;
    final pwd = _passphrase;
    if (sync == null || pwd == null || _restoring || _syncing) return;
    setState(() {
      _restoring = true;
      _restoreProgress = null;
    });
    try {
      final report = await sync.restore(
        passphrase: pwd,
        items: items,
        onProgress: (done, total) {
          if (mounted) setState(() => _restoreProgress = '$done/$total');
        },
      );
      if (!mounted) return;
      final bak = report.backups.length;
      if (report.hasError) {
        _snack('已恢复 ${report.ok} 份，失败 ${report.failed.length} 份'
            '（${report.failed.first.error}）');
      } else {
        _snack('已恢复 ${report.ok} 份存档'
            '${bak > 0 ? '，覆盖前已备份 $bak 个文件' : ''}');
      }
      await _loadGameSaves();
    } on CloudException catch (e) {
      if (mounted) _snack('恢复失败：$e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _restoring = false;
          _restoreProgress = null;
        });
      }
    }
  }

  /// 上传游戏存档（[only] 为空表示所有未同步的）。
  Future<void> _uploadSaves({SaveKey? only}) async {
    final sync = _sync;
    final pwd = _passphrase;
    if (sync == null || pwd == null || _syncing) return;
    setState(() {
      _syncing = true;
      _syncProgress = null;
    });
    try {
      final report = await sync.uploadLocal(
        passphrase: pwd,
        only: only == null ? null : [only],
        onProgress: (done, total) {
          if (mounted) setState(() => _syncProgress = '$done/$total');
        },
      );
      if (!mounted) return;
      if (report.hasError) {
        _snack('已上传 ${report.ok} 个，失败 ${report.failed.length} 个'
            '（${report.failed.first.error}）');
      } else {
        _snack('已上传 ${report.ok} 个文件（含槽位缩略图）');
      }
      await _loadGameSaves();
    } on CloudException catch (e) {
      if (mounted) _snack('上传失败：$e', error: true);
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
          _syncProgress = null;
        });
      }
    }
  }

  /// [silent] 用于页面初始化：命中本地缓存时不要闪一下进度圈。
  Future<void> _refresh({bool silent = false}) async {
    if (_client == null || _passphrase == null) return;
    if (!silent && mounted) setState(() => _busy = true);
    try {
      _saves = await _client!.listSaves();
      _error = null;
    } on CloudException catch (e) {
      _error = e.toString();
    } finally {
      if (!silent && mounted) setState(() => _busy = false);
    }
  }

  /// 用户主动同步另一台设备新上传的存档时，绕过 TTL 强制拉一次。
  Future<void> _forceRefresh() async {
    final client = _client;
    if (client == null || _busy) return;
    if (mounted) setState(() => _busy = true);
    try {
      await client.invalidateSavesCache();
      await _refresh(silent: true);
      await _loadGameSaves();
      if (mounted) _snack('云端列表已刷新');
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
          await _writePass(pwd);
          _passphrase = pwd;
        },
      ),
    );
    if (ok == true && mounted) {
      await _refresh();
      await _loadGameSaves();
    }
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
        // 稳定 clientKey：重复「备份当前库设置」会覆盖同一份云端 blob，
        // 不会每点一次就多出一行（后端按 user+client_key 覆盖）。
        clientKey: 'library-backup',
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
        FeatureCard(
          icon: Icons.cloud_upload_outlined,
          title: '库设置备份',
          accent: const Color(0xFF22B8A6),
          child: Column(
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
                        child: CircularProgressIndicator(strokeWidth: 2))
                  else
                    IconButton(
                      tooltip: '刷新云端列表',
                      onPressed: _forceRefresh,
                      icon: const Icon(Icons.refresh, size: 18),
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      constraints: const BoxConstraints(),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy ? null : _upload,
                icon: const Icon(Icons.cloud_upload_outlined),
                label: const Text('备份当前库设置'),
              ),
              if (_passViaFallback)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('本机无系统安全存储，云存档密码保存在应用私有目录。',
                      style: TextStyle(fontSize: 11, color: Colors.grey)),
                ),
              const SizedBox(height: 10),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              if (_backupBlobs.isEmpty && _error == null)
                const Text('暂无云端备份。', style: TextStyle(color: Colors.grey))
              else
                ..._backupBlobs.map((s) => _saveTile(s)),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FeatureCard(
          icon: Icons.sports_esports_outlined,
          title: '游戏存档',
          accent: const Color(0xFF3E7BFA),
          child: _gameSavesSection(),
        ),
      ],
    );
  }

  /// 云端 blob 里排除游戏存档（`<CRC>.sav` 等）后的备份列表。
  List<CloudSaveSummary> get _backupBlobs => _saves
      .where((s) => CloudSaveSync.parseCloudName(s.saveName) == null)
      .toList();

  // ------------------------------------------------------------ 游戏存档区块

  Widget _gameSavesSection() {
    final diff = _diff;
    if (diff == null) {
      // 不该静默消失：读不到就说清楚，否则用户以为「云存档页面没做」。
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text('正在读取本机存档…（若一直停在这里，说明读不到 files/saves 目录）',
            style: TextStyle(fontSize: 12, color: Colors.grey)),
      );
    }
    final theme = Theme.of(context);
    final cloudTotal = _cloudSaves.where((c) => !c.isThumb).length;
    final cloudOnly = diff.cloudOnly.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '本机 ${_localSaves.length} 份 · '
                '云端 $cloudTotal 份',
                style: theme.textTheme.labelLarge,
              ),
            ),
            if (_syncing)
              Text(_syncProgress ?? '上传中…',
                  style: theme.textTheme.labelSmall)
            else if (_restoring)
              Text(_restoreProgress ?? '恢复中…',
                  style: theme.textTheme.labelSmall),
          ],
        ),
        const SizedBox(height: 6),
        if (_localSaves.isEmpty)
          const Text('本机还没有存档文件（先玩一局并存档，再回来同步，'
              '或从下方云端列表恢复）。',
              style: TextStyle(fontSize: 12, color: Colors.grey))
        else ...[
          if (diff.remoteNewer.isNotEmpty)
            FilledButton.tonalIcon(
              onPressed: (_restoring || _syncing)
                  ? null
                  : () => _restoreSaves(
                        items: [for (final p in diff.remoteNewer) p.cloud],
                      ),
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              label: Text('恢复云端较新的 ${diff.remoteNewer.length} 份'),
            ),
          if (diff.remoteNewer.isNotEmpty) const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: (_syncing || _restoring || diff.pendingUpload == 0)
                ? null
                : () => _uploadSaves(),
            icon: const Icon(Icons.cloud_upload_outlined, size: 18),
            label: Text(diff.pendingUpload == 0
                ? (diff.remoteNewer.isEmpty ? '存档已全部同步' : '本机没有待上传的存档')
                : '上传本地较新的 ${diff.pendingUpload} 份'),
          ),
          if (diff.pendingUpload > 0)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('上传会覆盖云端的旧版本；恢复会覆盖本机，且自动备份为 .bak-<时间戳>。',
                  style: TextStyle(fontSize: 11, color: Colors.grey)),
            ),
          const SizedBox(height: 4),
          ..._localSaves.map(_saveRow),
        ],
        if (cloudOnly > 0) ...[
          const Divider(height: 20),
          Row(
            children: [
              Expanded(
                child: Text('云端有 $cloudOnly 份本机没有的存档',
                    style: theme.textTheme.labelMedium),
              ),
              TextButton.icon(
                onPressed: (_restoring || _syncing)
                    ? null
                    : () => _restoreSaves(items: diff.cloudOnly),
                icon: const Icon(Icons.cloud_download_outlined, size: 16),
                label: const Text('全部恢复'),
              ),
            ],
          ),
          ...diff.cloudOnly.map(_cloudSaveRow),
        ],
      ],
    );
  }

  /// 云端独有存档的一行（带单条恢复按钮）。
  Widget _cloudSaveRow(CloudSave c) {
    final title = _romTitles[c.key.crc] ?? c.key.crc;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.cloud_download_outlined, size: 18),
      title: Text('$title · ${c.key.label}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${(c.sizeBytes / 1024).toStringAsFixed(1)} KB · 云端 ${_fmt(c.updatedAt)}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: IconButton(
        tooltip: '恢复到本机（覆盖前自动备份）',
        iconSize: 18,
        onPressed: (_restoring || _syncing)
            ? null
            : () => _restoreSaves(items: [c]),
        icon: const Icon(Icons.download_outlined),
      ),
    );
  }

  Widget _saveRow(LocalSave l) {
    final theme = Theme.of(context);
    final diff = _diff;
    final title = _romTitles[l.key.crc] ?? l.key.crc;
    var status = '已同步';
    var color = theme.colorScheme.outline;
    CloudSave? remote;
    if (diff != null) {
      if (diff.localOnly.any((e) => e.key.id == l.key.id)) {
        status = '未上传';
        color = theme.colorScheme.error;
      } else if (diff.localNewer.any((e) => e.key.id == l.key.id)) {
        status = '本地较新';
        color = theme.colorScheme.tertiary;
      } else {
        for (final p in diff.remoteNewer) {
          if (p.local.key.id == l.key.id) {
            remote = p.cloud;
            status = '云端较新';
            color = theme.colorScheme.primary;
            break;
          }
        }
      }
    }
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        switch (l.key.kind) {
          SaveKind.battery => Icons.battery_std,
          SaveKind.auto => Icons.autorenew,
          SaveKind.slot => Icons.bookmark_outline,
        },
        size: 18,
      ),
      title: Text('$title · ${l.key.label}',
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${(l.size / 1024).toStringAsFixed(1)} KB · ${_fmt(l.modified)} · $status'
        '${remote != null ? '（${_fmt(remote.updatedAt)}）' : ''}'
        '${l.thumb != null ? ' · 含缩略图' : ''}',
        style: TextStyle(fontSize: 12, color: color),
      ),
      trailing: remote != null
          // 冲突决策：云端更新 → 一键用云端覆盖本机（自动留 .bak）
          ? IconButton(
              tooltip: '用云端版本覆盖本机（自动备份）',
              iconSize: 18,
              onPressed: (_restoring || _syncing)
                  ? null
                  : () => _restoreSaves(items: [remote!]),
              icon: const Icon(Icons.download_outlined),
            )
          : IconButton(
              tooltip: '上传这一份（覆盖云端旧版）',
              iconSize: 18,
              onPressed: (_syncing || _restoring)
                  ? null
                  : () => _uploadSaves(only: l.key),
              icon: const Icon(Icons.upload_outlined),
            ),
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
