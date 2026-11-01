import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../membership/membership_card.dart';
import 'my_pc_section.dart';

import '../../data/cloud/cloud_client.dart';
import '../../data/cloud/cloud_config.dart';
import '../../data/cloud/cloud_discovery.dart';
import '../../pal/platform_pal.dart';
import '../cloud/cloud_actions.dart';
import '../cloud/cloud_library_page.dart';
import '../peer/peers_page.dart';
import '../../config/app_channel.dart';
import '../../data/peer/peer_crypto.dart';

/// Account + server settings + OTA entry. Also hosts the "sync now" action.
class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.pal, required this.onSynced});

  final PlatformPal pal;

  /// Called after a network sync changed the on-device library.
  final Future<void> Function() onSynced;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _serverCtl = TextEditingController();
  final _nameCtl = TextEditingController();
  final _passCtl = TextEditingController();

  String? _filesDir;
  CloudConfig? _config;
  CloudClient? _client;
  AppVersion? _version;
  var _mode = 'login'; // login | register
  var _busy = false;
  var _editingServer = false;
  var _checkingUpdate = false;
  var _downloadingUpdate = false;
  var _discovering = false;
  String _channel = 'stable';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _serverCtl.dispose();
    _nameCtl.dispose();
    _passCtl.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    final dir = await widget.pal.filesDir();
    final cfg = await CloudConfig.load(dir);
    final ver = await widget.pal.appVersion();
    if (!mounted) return;
    setState(() {
      _filesDir = dir;
      _config = cfg;
      _client = CloudClient(cfg);
      _version = ver;
      _serverCtl.text = cfg.baseUrl;
    });
    if (cfg.isLoggedIn) {
      unawaited(_validateSession());
    } else if (!cfg.isConfigured) {
      // First run / never configured: try zero-touch discovery in the
      // background; the login page stays usable meanwhile.
      unawaited(_runDiscovery(manual: false));
    }
  }

  /// Re-validates a cached session against /me.
  ///  - 401/403 from the server: session is truly dead -> sign out locally
  ///  - network failure / timeout: keep the cached session (offline-first,
  ///    a flaky network must never log the user out)
  Future<void> _validateSession() async {
    final cfg = _config;
    final client = _client;
    if (cfg == null || client == null) return;
    try {
      final r = await client.me();
      final u = (r['user'] as Map?)?.cast<String, dynamic>() ?? const {};
      cfg
        ..userName = u['name'] as String?
        ..role = u['role'] as String?
        ..userId = u['id'] as String?;
      await cfg.save();
      if (mounted) setState(() {});
    } on CloudException catch (e) {
      if (e.statusCode != 401 && e.statusCode != 403) return;
      final banned = e.statusCode == 403;
      cfg.clearSession();
      await cfg.save();
      if (!mounted) return;
      setState(() {});
      _snack(banned ? '账号已被停用，请联系管理员' : '登录已失效，请重新登录',
          error: true);
    } catch (_) {
      // Offline: trust cached session.
    }
  }

  Future<void> _runDiscovery({required bool manual}) async {
    if (_discovering) return;
    setState(() => _discovering = true);
    try {
      final found =
          await CloudDiscovery.discover(previousUrl: _config?.baseUrl);
      if (!mounted) return;
      if (found == null) {
        if (manual) {
          _snack('未发现局域网内的服务器：请确认电脑端已启动、手机与电脑连同一 Wi-Fi',
              error: true);
        }
        return;
      }
      _serverCtl.text = found;
      final cfg = _config;
      if (cfg != null && cfg.baseUrl != found) {
        // Adopt the discovered address. The token is kept: when a PC's IP
        // changes via DHCP it is the same server and the session survives.
        // If it is genuinely another server, its 401 triggers sign-out.
        cfg.baseUrl = found;
        await cfg.save();
      }
      setState(() => _editingServer = false);
      if (manual) _snack('已发现服务器：$found');
    } finally {
      if (mounted) setState(() => _discovering = false);
    }
  }

  Future<void> _changePassword() async {
    final oldCtl = TextEditingController();
    final newCtl = TextEditingController();
    final confirmCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改密码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: oldCtl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '当前密码'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: newCtl,
              obscureText: true,
              decoration:
                  const InputDecoration(labelText: '新密码（6~64 位）'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: confirmCtl,
              obscureText: true,
              decoration: const InputDecoration(labelText: '确认新密码'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) return;
    final oldPw = oldCtl.text;
    final newPw = newCtl.text;
    if (oldPw.isEmpty || newPw.isEmpty) {
      _snack('请填写完整', error: true);
      return;
    }
    if (newPw.length < 6 || newPw.length > 64) {
      _snack('新密码需 6~64 位', error: true);
      return;
    }
    if (newPw != confirmCtl.text) {
      _snack('两次输入的新密码不一致', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _client!.changePassword(oldPw, newPw);
      if (!mounted) return;
      setState(() => _busy = false);
      _snack('密码已修改');
    } on CloudException catch (e) {
      setState(() => _busy = false);
      _snack(e.message, error: true);
    } catch (e) {
      setState(() => _busy = false);
      _snack('$e', error: true);
    }
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Theme.of(context).colorScheme.errorContainer : null,
    ));
  }

  Future<void> _submitAuth() async {
    final url = CloudConfig.normalize(_serverCtl.text);
    final name = _nameCtl.text.trim();
    final password = _passCtl.text;
    if (url.isEmpty || !url.startsWith('http')) {
      _snack('请填写服务器地址，如 http://192.168.1.10:8848', error: true);
      return;
    }
    if (name.isEmpty || password.isEmpty) {
      _snack('请填写用户名和密码', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      _config!
        ..baseUrl = url
        ..clearSession();
      final api = CloudClient(_config!);
      final r = _mode == 'login'
          ? await api.login(name, password)
          : await api.register(name, password);
      _config!.setSession(
        token: r['token'] as String? ?? '',
        user: (r['user'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
      await _config!.save();
      _nameCtl.clear();
      _passCtl.clear();
      if (!mounted) return;
      setState(() {
        _editingServer = false;
        _busy = false;
      });
      _snack(_mode == 'login' ? '登录成功' : '注册成功，已自动登录');
    } on CloudException catch (e) {
      setState(() => _busy = false);
      _snack(e.message, error: true);
    } catch (e) {
      setState(() => _busy = false);
      _snack('$e', error: true);
    }
  }

  Future<void> _logout() async {
    await _client?.logout();
    _config?.clearSession();
    await _config?.save();
    if (mounted) setState(() {});
  }

  Future<void> _saveServerUrl() async {
    final url = CloudConfig.normalize(_serverCtl.text);
    if (url.isEmpty || !url.startsWith('http')) {
      _snack('服务器地址无效', error: true);
      return;
    }
    // A different server means the old token is meaningless.
    if (url != _config!.baseUrl) {
      _config!
        ..baseUrl = url
        ..clearSession();
      await _config!.save();
    }
    setState(() => _editingServer = false);
  }

  Future<void> _openPeers() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => PeersPage(
          pal: widget.pal,
          onLibraryChanged: widget.onSynced,
        ),
      ),
    );
    if (changed == true) await widget.onSynced();
  }

  Future<void> _openCloudLibrary() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CloudLibraryPage(config: _config!, filesDir: _filesDir!),
      ),
    );
    if (changed == true) await _doSync(silentOpen: true);
  }

  Future<void> _doSync({bool silentOpen = false}) async {
    final report = await runCloudSync(context,
        config: _config!, filesDir: _filesDir!);
    if (report != null) {
      await widget.onSynced();
      if (!mounted) return;
      setState(() {}); // 刷新"上次同步目录版本"标签
      _snack('同步完成：${report.games} 款游戏信息，新增 ROM ${report.romsAdded} 个'
          '（下载 ${formatBytes(report.bytesDownloaded)}）');
    }
  }

  Future<void> _openStorePage() async {
    try {
      await widget.pal.openStore();
    } catch (e) {
      if (mounted) _snack('无法打开应用商店：$e', error: true);
    }
  }

  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    _checkingUpdate = true;
    setState(() => _busy = true);
    try {
      final r = await _client!.checkUpdate(
          _version?.versionCode ?? 1, _channel);
      if (!mounted) return;
      setState(() => _busy = false);
      _checkingUpdate = false;
      if (r == null) {
        _snack('当前已是最新版本（${_version?.versionName}）');
        return;
      }
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('发现新版本 v${r.versionName}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('版本号：${r.versionCode} · 渠道：${r.channel}'
                  ' · 大小：${formatBytes(r.size)}'),
              if (r.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(r.notes.trim()),
              ],
              if (r.mandatory) ...[
                const SizedBox(height: 8),
                Text('该版本为强制更新',
                    style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('稍后')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('立即更新')),
          ],
        ),
      );
      if (go == true) await _downloadAndInstall(r);
    } on CloudException catch (e) {
      if (mounted) setState(() => _busy = false);
      _checkingUpdate = false;
      _snack(e.message, error: true);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      _checkingUpdate = false;
      _snack('$e', error: true);
    }
  }

  Future<void> _downloadAndInstall(ReleaseInfo r) async {
    if (_downloadingUpdate) return;
    _downloadingUpdate = true;
    try {
      await _runDownloadDialog(r);
    } finally {
      _downloadingUpdate = false;
    }
  }

  Future<void> _runDownloadDialog(ReleaseInfo r) async {
    final apkDir = Directory('$_filesDir/updates');
    await apkDir.create(recursive: true);
    if (!mounted) return;
    final apk = File('${apkDir.path}/update-v${r.versionCode}.apk');
    String stage = '正在下载更新…';
    double? progress;
    var failed = '';
    // StatefulBuilder 会随进度反复重建，下载只能启动一次。
    var started = false;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          void start() {
            if (started) return;
            started = true;
            _client!
                .downloadRelease(r.downloadUrl, dest: apk,
                    onProgress: (p, got, total) {
              setDlg(() {
                progress = p;
                stage =
                    '正在下载更新 ${formatBytes(got)}${total == null ? '' : ' / ${formatBytes(total)}'}';
              });
            }).then((_) async {
              if (!await apk.exists()) {
                if (ctx.mounted) setDlg(() => failed = '安装包下载失败');
                return;
              }
              // P0-2: verify integrity + prevent downgrade before installing.
              if (r.sha256.isEmpty) {
                if (ctx.mounted) {
                  setDlg(() => failed = '服务端未提供校验值，已取消安装');
                }
                return;
              }
              final digest = PeerCrypto.hex(PeerCrypto.sha256(await apk.readAsBytes()));
              if (digest != r.sha256.toLowerCase()) {
                try { await apk.delete(); } catch (_) {/* ignore */}
                if (ctx.mounted) {
                  setDlg(() => failed = '安装包校验失败（sha256 不匹配），已删除');
                }
                return;
              }
              if (r.versionCode <= (_version?.versionCode ?? 0)) {
                if (ctx.mounted) {
                  setDlg(() => failed = '安装包版本不高于当前版本');
                }
                return;
              }
              if (ctx.mounted) Navigator.of(ctx).pop();
            }).catchError((Object e) {
              if (ctx.mounted) setDlg(() => failed = '$e');
            });
          }

          WidgetsBinding.instance.addPostFrameCallback((_) => start());
          return PopScope(
            canPop: failed.isNotEmpty,
            child: Dialog(
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(stage, style: Theme.of(ctx).textTheme.titleSmall),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: progress),
                    if (failed.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text('下载失败：$failed',
                          style: TextStyle(
                              color: Theme.of(ctx).colorScheme.error)),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.of(ctx).pop(),
                          child: const Text('关闭'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );

    if (failed.isNotEmpty) {
      _snack(failed, error: true);
      return;
    }
    _snack('下载完成，即将打开系统安装器');
    await widget.pal.installApk(apk.absolute.path);
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final cfg = _config;
    return Scaffold(
      appBar: AppBar(title: const Text('账号与云服务')),
      body: cfg == null
          ? const Center(child: CircularProgressIndicator())
          : cfg.isLoggedIn && !_editingServer
              ? _buildProfile(cfg)
              : _buildLogin(cfg),
    );
  }

  Widget _section(
      {required IconData icon, required String title, required Widget child}) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, size: 19),
              const SizedBox(width: 8),
              Text(title, style: Theme.of(context).textTheme.titleSmall),
            ]),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildProfile(CloudConfig cfg) {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 10),
      children: [
        _section(
          icon: Icons.account_circle,
          title: '当前账号',
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                child: Text(
                  (cfg.userName ?? '?').isNotEmpty
                      ? cfg.userName!.substring(0, 1).toUpperCase()
                      : '?',
                  style: const TextStyle(fontSize: 20),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(cfg.userName ?? '',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Wrap(
                      spacing: 6,
                      children: [
                        _chip(cfg.isAdmin ? '管理员' : '普通用户'),
                        _chip(cfg.baseUrl, mono: true),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _section(
          icon: Icons.cloud_outlined,
          title: '云文件库',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('浏览服务端已发布的游戏，订阅后通过网络同步到本机。'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _openCloudLibrary,
                    icon: const Icon(Icons.video_library_outlined),
                    label: const Text('浏览 / 订阅文件库'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _doSync(),
                    icon: const Icon(Icons.cloud_sync),
                    label: const Text('立即网络同步'),
                  ),
                ],
              ),
              if (cfg.lastRevision > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('上次同步目录版本：r${cfg.lastRevision}',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ],
          ),
        ),
        _section(
          icon: Icons.computer,
          title: '我的 PC（局域网存档/设置同步）',
          child: MyPcSection(pal: widget.pal),
        ),
        const MembershipSection(),
        _section(
          icon: Icons.swap_horiz,
          title: '发现伙伴（手机面对面互传）',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('同一 Wi-Fi / 热点下与另一台趣玩匣手机直连，'
                  '经双方核对 6 位码配对后互传 ROM、金手指与存档；不经任何服务器。'),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _busy ? null : _openPeers,
                icon: const Icon(Icons.connect_without_contact),
                label: const Text('发现伙伴'),
              ),
            ],
          ),
        ),
        _section(
          icon: Icons.system_update,
          title: '应用升级（OTA）',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                children: [
                  for (final c in const [
                    ['stable', '稳定版'],
                    ['beta', '测试版'],
                  ])
                    ChoiceChip(
                      label: Text(c[1]),
                      selected: _channel == c[0],
                      onSelected: (_) => setState(() => _channel = c[0]),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (appChannel.canSelfUpdate) ...[
                FilledButton.icon(
                  onPressed: _busy ? null : _checkUpdate,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('检查更新'),
                ),
              ] else ...[
                FilledButton.icon(
                  onPressed: _busy ? null : _openStorePage,
                  icon: const Icon(Icons.store_outlined),
                  label: const Text('前往应用商店'),
                ),
                const SizedBox(height: 8),
                Text('商店版不支持应用内更新，请从应用市场获取新版本。',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ],
          ),
        ),
        _section(
          icon: Icons.settings,
          title: '服务器与登录',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              OutlinedButton.icon(
                onPressed: _discovering
                    ? null
                    : () => _runDiscovery(manual: true),
                icon: _discovering
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.travel_explore),
                label: Text(_discovering ? '正在探测局域网…' : '重新探测服务器'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _editingServer = true;
                  _serverCtl.text = cfg.baseUrl;
                }),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('更换服务器地址'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _changePassword,
                icon: const Icon(Icons.key_outlined),
                label: const Text('修改密码'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : _logout,
                icon: const Icon(Icons.logout),
                label: const Text('退出登录'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text('趣玩匣 GamePouch · 局域网私有云服务',
              style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }

  Widget _chip(String text, {bool mono = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: mono
              ? const TextStyle(fontSize: 11, fontFamily: 'monospace')
              : Theme.of(context).textTheme.labelSmall),
    );
  }

  Widget _buildLogin(CloudConfig cfg) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.cloud, size: 52),
              const SizedBox(height: 8),
              Text('趣玩匣云服务',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('请输入 PC 端文件库服务的地址（手机需与电脑同一局域网）',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 18),
              TextField(
                controller: _serverCtl,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: '服务器地址',
                  hintText: 'http://192.168.1.10:8848',
                  prefixIcon: const Icon(Icons.dns_outlined),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: '自动探测局域网内的服务器',
                    onPressed: _discovering
                        ? null
                        : () => _runDiscovery(manual: true),
                    icon: _discovering
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.travel_explore),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _discovering
                      ? null
                      : () => _runDiscovery(manual: true),
                  icon: const Icon(Icons.travel_explore, size: 18),
                  label: Text(_discovering ? '正在探测局域网…' : '不知道地址？自动探测'),
                ),
              ),
              const SizedBox(height: 4),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'login', label: Text('登录')),
                  ButtonSegment(value: 'register', label: Text('注册')),
                ],
                selected: {_mode},
                onSelectionChanged: (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _nameCtl,
                decoration: const InputDecoration(
                  labelText: '用户名',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passCtl,
                obscureText: true,
                onSubmitted: (_) => _busy ? null : _submitAuth(),
                decoration: const InputDecoration(
                  labelText: '密码（6~64 位）',
                  prefixIcon: Icon(Icons.lock_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _busy ? null : _openPeers,
                icon: const Icon(Icons.connect_without_contact),
                label: const Text('发现伙伴：手机面对面互传文件'),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _busy ? null : _submitAuth,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login),
                label: Text(_mode == 'login' ? '登录' : '注册并登录'),
              ),
              if (_editingServer) ...[
                const SizedBox(height: 10),
                TextButton(
                  onPressed: _saveServerUrl,
                  child: const Text('仅保存服务器地址'),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                '拾忆，重拾欢喜',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
