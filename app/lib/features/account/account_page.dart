import 'package:flutter/material.dart';
import '../../pal/platform_pal.dart';
import '../peer/peers_page.dart';
import '../settings/settings_sheet.dart';
import 'mock_account.dart';

/// 「网络」模块：云端账号（仅云端登录，不连本地 PC）、云存档（会员权益占位）、
/// 手机面对面互传。会员 / 去广告管理见设置页。
/// 账号后端当前为本地桩（MockAccountService），后端就绪后替换实现即可。
class AccountPage extends StatefulWidget {
  const AccountPage({super.key, required this.pal, required this.onSynced});

  final PlatformPal pal;

  /// Called after a network sync changed the on-device library.
  final Future<void> Function() onSynced;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _svc = MockAccountService();
  AccountUser? _user;
  final _busy = false;

  @override
  void initState() {
    super.initState();
    _svc.load().then((u) {
      if (mounted) setState(() => _user = u);
    });
  }

  Future<void> _openLogin() async {
    final u = await showDialog<AccountUser>(
      context: context,
      builder: (_) => _LoginDialog(service: _svc),
    );
    if (u != null && mounted) setState(() => _user = u);
  }

  Future<void> _logout() async {
    await _svc.logout();
    if (mounted) setState(() => _user = null);
  }

  Future<void> _changePassword() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _ChangePasswordDialog(service: _svc),
    );
    if (ok == true && mounted) _snack('密码已修改（演示）');
  }

  Future<void> _deregister() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('账户注销'),
        content: const Text('注销后该账号的云端数据将被清除且不可恢复，确定继续？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('注销')),
        ],
      ),
    );
    if (ok == true) {
      await _svc.deregister();
      if (!mounted) return;
      setState(() => _user = null);
      _snack('账户已注销（演示）');
    }
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

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          error ? Theme.of(context).colorScheme.errorContainer : null,
    ));
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网络')),
      body: _buildProfile(),
    );
  }

  Widget _section(
      {required IconData icon,
      required String title,
      required Widget child}) {
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

  Widget _buildProfile() {
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 10),
      children: [
        _accountSection(),
        _cloudSaveSection(),
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
                onPressed: _openPeers,
                icon: const Icon(Icons.connect_without_contact),
                label: const Text('发现伙伴'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text('趣玩匣 GamePouch',
              style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }

  /// 我的账号（云端登录，不连本地 PC）：登录态显示用户信息与在线状态及操作入口；
  /// 未登录态弹出登录界面（一键快捷登录 / 账号密码）。
  Widget _accountSection() {
    if (_user == null) {
      return _section(
        icon: Icons.account_circle_outlined,
        title: '我的账号',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('登录云端账号后可同步存档与设置，并解锁会员权益。'),
            const SizedBox(height: 10),
            FilledButton.icon(
              onPressed: _busy ? null : _openLogin,
              icon: const Icon(Icons.login),
              label: const Text('登录'),
            ),
          ],
        ),
      );
    }
    final u = _user!;
    return _section(
      icon: Icons.account_circle,
      title: '我的账号',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                child: Text(
                  u.name.isNotEmpty ? u.name[0].toUpperCase() : '?',
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.name,
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: [
                        _chip(u.online ? '在线' : '离线'),
                        _chip('ID: ${u.id}', mono: true),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _logout,
                icon: const Icon(Icons.logout),
                label: const Text('退出登录'),
              ),
              OutlinedButton.icon(
                onPressed: () => SettingsSheet.show(
                  context,
                  pal: widget.pal,
                  deepLink: 'membership',
                ),
                icon: const Icon(Icons.workspace_premium_outlined),
                label: const Text('会员服务'),
              ),
              OutlinedButton.icon(
                onPressed: _changePassword,
                icon: const Icon(Icons.key_outlined),
                label: const Text('修改密码'),
              ),
              OutlinedButton.icon(
                onPressed: _deregister,
                icon: const Icon(Icons.delete_forever_outlined),
                label: const Text('账户注销'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(String text, {bool mono = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: mono
            ? const TextStyle(fontSize: 11, fontFamily: 'monospace')
            : Theme.of(context).textTheme.labelSmall,
      ),
    );
  }

  /// 云存档（会员专属权益）占位：把"云服务"显式绑定到会员 / 去广告。
  /// 后端就绪后此区接入开发者云空间。
  Widget _cloudSaveSection() {
    return _section(
      icon: Icons.cloud_queue_outlined,
      title: '云存档（会员专属）',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('云存档让进度、设置、金手指随身同步到你的私有云，'
              '是会员核心权益之一，正在接入中。'),
          const SizedBox(height: 8),
          _chip('即将上线 · 会员解锁', mono: false),
        ],
      ),
    );
  }
}

/// 登录界面：支持「一键快捷登录」与「账号密码」两种方式。
class _LoginDialog extends StatefulWidget {
  const _LoginDialog({required this.service});
  final MockAccountService service;

  @override
  State<_LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<_LoginDialog> {
  var _mode = 'quick'; // quick | password
  final _nameCtl = TextEditingController();
  final _passCtl = TextEditingController();
  var _busy = false;
  String? _err;

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      final u = _mode == 'quick'
          ? await widget.service.quickLogin()
          : await widget.service.login(
              _nameCtl.text.trim(), _passCtl.text);
      if (!mounted) return;
      Navigator.pop(context, u);
    } catch (e) {
      setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('登录'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'quick', label: Text('一键快捷登录')),
              ButtonSegment(value: 'password', label: Text('账号密码')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 12),
          if (_mode == 'password') ...[
            TextField(
              controller: _nameCtl,
              decoration: const InputDecoration(
                labelText: '用户名',
                prefixIcon: Icon(Icons.person_outline),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _passCtl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '密码',
                prefixIcon: Icon(Icons.lock_outline),
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
          ] else
            const Text('演示环境：一键快捷登录将使用内置演示账号直接登录。',
                style: TextStyle(fontSize: 12)),
          if (_err != null) ...[
            const SizedBox(height: 8),
            Text(_err!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('取消')),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('登录'),
        ),
      ],
    );
  }
}

/// 修改密码（演示）：校验两次输入一致与长度，调用桩服务。
class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog({required this.service});
  final MockAccountService service;

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _oldCtl = TextEditingController();
  final _new1Ctl = TextEditingController();
  final _new2Ctl = TextEditingController();
  var _busy = false;
  String? _err;

  Future<void> _submit() async {
    final newPw = _new1Ctl.text;
    if (newPw.length < 6 || newPw.length > 64) {
      setState(() => _err = '新密码需 6~64 位');
      return;
    }
    if (newPw != _new2Ctl.text) {
      setState(() => _err = '两次输入的新密码不一致');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await widget.service.changePassword(_oldCtl.text, newPw);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      setState(() => _err = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('修改密码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _oldCtl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '当前密码',
              prefixIcon: Icon(Icons.lock_outline),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _new1Ctl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '新密码（6~64 位）',
              prefixIcon: Icon(Icons.key_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _new2Ctl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '确认新密码',
              prefixIcon: Icon(Icons.key_outlined),
              border: OutlineInputBorder(),
            ),
          ),
          if (_err != null) ...[
            const SizedBox(height: 10),
            Text(_err!,
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
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
