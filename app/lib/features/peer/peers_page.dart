import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../data/peer/peer_client.dart';
import '../../data/peer/peer_server.dart';
import '../../data/peer/peer_store.dart';
import '../../data/peer/peers_controller.dart';
import '../../pal/pairing_pal.dart';
import '../../data/play/play_session.dart';
import '../../pal/platform_pal.dart';
import 'pair_dialog.dart';
import 'peer_library_page.dart';
import '../play/play_invite_dialog.dart';
import '../play/play_lobby_page.dart';

/// 「发现伙伴」入口页. Foreground-only lifecycle lives in [PeersController]:
/// entering starts the HTTP server / UDP responder / scanner; leaving stops
/// everything and releases the multicast lock (FR-1, AC-13).
class PeersPage extends StatefulWidget {
  const PeersPage({
    super.key,
    required this.pal,
    this.controller,
    this.onLibraryChanged,
  });

  final PlatformPal pal;

  /// Optional injected controller (widget tests provide a fake-backed one).
  final PeersController? controller;

  /// Called after an import changed the local ROM library.
  final Future<void> Function()? onLibraryChanged;

  @override
  State<PeersPage> createState() => _PeersPageState();
}

class _PeersPageState extends State<PeersPage> {
  late final PeersController _c;
  bool _ownsController = false;
  StreamSubscription? _pairSub;
  StreamSubscription<PlayInvite>? _inviteSub;
  bool _pairDialogOpen = false;
  bool _inviteDialogOpen = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final injected = widget.controller;
    if (injected != null) {
      _c = injected;
    } else {
      _c = PeersController(pal: widget.pal, pairingPal: createPairingPal());
      _ownsController = true;
    }
    unawaited(_start());
  }

  Future<void> _start() async {
    // An injected controller (widget tests) is expected to be pre-started.
    if (_ownsController) await _c.start();
    if (!mounted) return;
    _pairSub = _c.pairRequests.listen(_onIncomingPair);
    _inviteSub = _c.plays?.invitations.listen(_onIncomingInvite);
    _c.addListener(_onController);
    // The HTTP server is already live (started inside _c.start()); an invite
    // arriving in that gap was answered 200 but its broadcast event had no
    // listener. Drain the manager's buffered copy.
    final buffered = _c.plays?.drainPendingInvite();
    if (buffered != null) unawaited(_onIncomingInvite(buffered));
  }

  void _onController() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pairSub?.cancel();
    _inviteSub?.cancel();
    _c.removeListener(_onController);
    if (_ownsController) unawaited(_c.stop());
    super.dispose();
  }

  // ------------------------------------------------------- netplay invites

  Future<void> _onIncomingInvite(PlayInvite inv) async {
    if (_inviteDialogOpen || !mounted) return;
    final pm = _c.plays;
    if (pm == null) return;
    _inviteDialogOpen = true;
    try {
      final res = await PlayInviteDialog.show(context, invite: inv);
      if (!mounted) return;
      final view = _c.byId(inv.fromDeviceId);
      // Reply to the endpoint the invite itself proved reachable: its source
      // IP plus the host's live signalling port. The scanned [PeerView] can
      // be arbitrarily stale (our broadcast pings are often filtered, and
      // the host's HTTP port rotates on every page open), which made the
      // accept POST target a dead address and the host lobby wait forever —
      // fatal for "OHOS host + Android guest" where only the invite
      // direction happened to route.
      final hostBase =
          inv.hostBaseUrl ?? view?.baseUrl;
      if (res == null) {
        // Dismissed via system back: decline so the host stops waiting
        // instead of hanging until its 60 s invite TTL.
        try {
          await _postToPeer(view, (c) => c.decline(inv.roomId),
              baseUrlOverride: hostBase);
        } catch (_) {/* best effort; local retirement below is enough */}
        if (mounted) pm.declineLocally(inv.roomId);
        return;
      }

      if (res == PlayInviteResult.decline) {
        await _postToPeer(view, (c) => c.decline(inv.roomId),
            baseUrlOverride: hostBase);
        pm.declineLocally(inv.roomId);
        return;
      }
      if (res == PlayInviteResult.timeout) {
        // The manager's own TTL timer retires the session; nothing to send.
        return;
      }

      final outboundToken =
          view?.outboundToken ?? _c.store?.get(inv.fromDeviceId)?.outboundToken;
      if (hostBase == null ||
          outboundToken == null ||
          _c.filesDir == null) {
        pm.declineLocally(inv.roomId);
        _snack('伙伴已离线或本机凭据缺失，无法接受邀请', error: true);
        return;
      }
      final guestUdpPort = 42000 + Random.secure().nextInt(20000);
      PlaySession session;
      try {
        final answer = await _postToPeer(
          view,
          (c) => c.accept(roomId: inv.roomId, guestUdpPort: guestUdpPort),
          baseUrlOverride: hostBase,
        );
        session = pm.completeLocalAccept(
          roomId: inv.roomId,
          guestUdpPort: guestUdpPort,
          sessionKey: answer.sessionKey,
        );
        session.initialD = answer.initialD;
      } catch (e) {
        _snack('接受邀请失败：$e', error: true);
        return;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => PlayLobbyPage(
            pal: widget.pal,
            plays: pm,
            session: session,
            filesDir: _c.filesDir!,
            peerBaseUrl: hostBase,
            peerToken: outboundToken,
            romCrc: inv.romCrc,
            coverUrl: '$hostBase/api/peer/cover/${inv.romCrc}',
          ),
        ),
      );
    } finally {
      _inviteDialogOpen = false;
    }
  }

  /// Runs [call] against a short-lived signaling client pointed at [view],
  /// or at [baseUrlOverride] when the invite carried a fresher endpoint
  /// (the token still comes from [view]/the pairing record).
  Future<T> _postToPeer<T>(
    PeerView? view,
    Future<T> Function(PlaySignalingClient) call, {
    String? baseUrlOverride,
  }) async {
    if (view == null && baseUrlOverride == null) {
      throw StateError('peer offline or credentials missing');
    }
    final token = view?.outboundToken;
    if (token == null) {
      throw StateError('peer offline or credentials missing');
    }
    final client = PlaySignalingClient(
        baseUrl: baseUrlOverride ?? view!.baseUrl, peerToken: token);
    try {
      return await call(client);
    } finally {
      client.close();
    }
  }

  // ------------------------------------------------------------- responder

  Future<void> _onIncomingPair(PeerPairRequest request) async {
    if (_pairDialogOpen || !mounted) return;
    final server = _c.server;
    final store = _c.store;
    if (server == null || store == null) return;
    _pairDialogOpen = true;
    try {
      await ResponderPairDialog.show(
        context,
        request: request,
        server: server,
        store: store,
      );
    } finally {
      _pairDialogOpen = false;
    }
    unawaited(_c.refresh());
  }

  // ------------------------------------------------------------- initiator

  Future<void> _pairWith(PeerView v) async {
    if (_busy) return;
    setState(() => _busy = true);
    final client = PeerClient(
        baseUrl: v.baseUrl, selfDeviceId: _c.selfDeviceId);
    try {
      final result = await InitiatorPairDialog.show(
        context,
        client: client,
        selfName: _c.selfName,
        peerName: v.name,
      );
      if (result == null) return;
      if (result.ok &&
          result.deviceId != null &&
          result.remoteToken != null &&
          result.outboundToken != null) {
        await _c.savePaired(
          deviceId: result.deviceId!,
          name: result.name ?? v.name,
          remoteToken: result.remoteToken!,
          outboundToken: result.outboundToken!,
          ip: v.ip,
          httpPort: v.port,
        );
        if (!mounted) return;
        _snack('已与「${result.name ?? v.name}」建立伙伴关系');
        final updated = _c.byId(result.deviceId!);
        if (updated != null) unawaited(_openLibrary(updated));
      } else if (!result.cancelled && result.message != null && mounted) {
        _snack(result.message!, error: true);
      }
    } finally {
      client.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openLibrary(PeerView v) async {
    final token = v.outboundToken;
    if (token == null) {
      _snack('本地缺少访问凭据，请重新配对', error: true);
      return;
    }
    final client = PeerClient(
      baseUrl: v.baseUrl,
      selfDeviceId: _c.selfDeviceId,
      token: token,
    );
    try {
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PeerLibraryPage(
            pal: widget.pal,
            client: client,
            filesDir: _c.filesDir!,
            peerName: v.name,
            peerDeviceId: v.id,
            plays: _c.plays,
            selfName: _c.selfName,
            selfDeviceId: _c.selfDeviceId,
            onLibraryChanged: widget.onLibraryChanged,
            onPeerRevoked: (deviceId) => _c.unpair(deviceId),
          ),
        ),
      );
      if (changed == true) unawaited(_c.refresh());
    } finally {
      client.close();
    }
  }

  Future<void> _unpair(PeerView v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除伙伴'),
        content: Text('解除后，「${v.name}」对本机的访问将立即失效（需重新配对）。\n'
            '本机也将无法再直接访问对方。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('解除')),
        ],
      ),
    );
    if (ok == true) {
      await _c.unpair(v.id);
      if (mounted) _snack('已解除伙伴关系');
    }
  }

  Future<void> _renameDevice() async {
    final ctl = TextEditingController(text: _c.selfName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改本机设备名'),
        content: TextField(
          controller: ctl,
          maxLength: 24,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如：小玩的手机'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok == true && ctl.text.trim().isNotEmpty) {
      await _c.rename(ctl.text.trim());
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

  // -------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现伙伴'),
        actions: [
          IconButton(
            tooltip: '重新扫描',
            onPressed: _c.scanning ? null : () => _c.refresh(),
            icon: _c.scanning
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _selfCard(theme),
          if (!_c.responderListening)
            Container(
              color: theme.colorScheme.errorContainer,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(
                '发现端口被占用：本机可浏览/配对对方，但对方暂时扫不到本机（可能有另一个趣玩匣实例）',
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.onErrorContainer),
              ),
            ),
          Expanded(child: _buildList(theme)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              '仅可分享你拥有合法备份的文件；数据为两台手机直连，不经过任何服务器。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _selfCard(ThemeData theme) {
    return Card(
      margin: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            CircleAvatar(
              child: Text(_c.selfName.isNotEmpty
                  ? _c.selfName.substring(0, 1)
                  : '?'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本机：${_c.selfName}',
                      style: theme.textTheme.titleSmall),
                  Text(
                    _c.scanning
                        ? '正在局域网内寻找伙伴…'
                        : '服务已开启，对同一 Wi-Fi / 热点下的伙伴可见',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: '修改设备名',
              onPressed: _renameDevice,
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme) {
    final online = _c.peers;
    final offline = _c.offlinePaired;

    if (online.isEmpty && _c.lastCycleFound == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: [
        if (online.isNotEmpty) _header('在线伙伴（${online.length}）'),
        for (final v in online) _peerTile(theme, v),
        if (offline.isNotEmpty) _header('已配对 · 当前离线（${offline.length}）'),
        for (final r in offline) _offlineTile(theme, r),
        if (online.isEmpty) _emptyState(theme),
      ],
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: Theme.of(context).hintColor)),
      );

  Widget _peerTile(ThemeData theme, PeerView v) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: v.paired
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          child: Icon(v.paired ? Icons.link : Icons.device_unknown,
              color: v.paired ? theme.colorScheme.primary : theme.hintColor),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(v.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            _tag(theme, v.paired ? '已配对' : '未配对',
                v.paired ? Icons.verified_outlined : Icons.fiber_manual_record,
                strong: v.paired),
          ],
        ),
        subtitle: Text(v.ip,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        trailing: v.paired
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => _openLibrary(v),
                    child: const Text('文件库'),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (v2) {
                      if (v2 == 'unpair') _unpair(v);
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'unpair', child: Text('解除伙伴')),
                    ],
                  ),
                ],
              )
            : FilledButton(
                onPressed: _busy ? null : () => _pairWith(v),
                child: const Text('配对连接'),
              ),
      ),
    );
  }

  Widget _offlineTile(ThemeData theme, PeerRecord r) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: ListTile(
        enabled: false,
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.surfaceContainerHighest,
          child: Icon(Icons.link_off, color: theme.hintColor),
        ),
        title: Text(r.name),
        subtitle: Text(r.lastIp ?? '地址未知',
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        trailing: TextButton(
          onPressed: () async {
            await _c.unpair(r.deviceId);
            if (mounted) _snack('已解除伙伴关系');
          },
          child: const Text('解除'),
        ),
      ),
    );
  }

  Widget _tag(ThemeData theme, String text, IconData icon,
      {bool strong = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: strong
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon,
            size: 12,
            color: strong ? theme.colorScheme.primary : theme.hintColor),
        const SizedBox(width: 3),
        Text(text, style: theme.textTheme.labelSmall),
      ]),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_find, size: 56, color: theme.hintColor),
            const SizedBox(height: 14),
            Text('暂未发现附近的伙伴',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            Text(
              '请确认：\n'
              '1. 两台手机连接同一个 Wi-Fi，或其中一台开启个人热点并让另一台加入；\n'
              '2. 对方手机也打开了本页面（离开页面即停止被发现）；\n'
              '3. 路由器没有开启「AP 隔离 / 访客网络隔离」。',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _c.scanning ? null : () => _c.refresh(),
              icon: const Icon(Icons.refresh),
              label: Text(_c.scanning ? '正在扫描…' : '重新扫描'),
            ),
          ],
        ),
      ),
    );
  }
}
