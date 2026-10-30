import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../data/play/play_session.dart';
import '../../data/rom_library.dart';
import '../../domain/rom_entry.dart';
import '../../pal/platform_pal.dart';

/// Pre-game lobby: shows both slots, runs a 50(+)-packet Dart UDP RTT probe
/// on the very ports the native frame channel will use, gates host start on
/// guest readiness, and launches [EmulatorActivity] with netplay extras on
/// both sides.
class PlayLobbyPage extends StatefulWidget {
  const PlayLobbyPage({
    super.key,
    required this.pal,
    required this.plays,
    required this.session,
    required this.filesDir,
    required this.peerBaseUrl,
    required this.peerToken,
    required this.romCrc,
    required this.coverUrl,
    this.signalingClient,
  });

  final PlatformPal pal;
  final PlaySessionManager plays;
  final PlaySession session;
  final String filesDir;

  /// Test-only injection point for the signaling client; production code
  /// always lets the page build one from [peerBaseUrl]/[peerToken].
  final PlaySignalingClient? signalingClient;

  /// Partner PeerServer base URL (cover art + signaling target).
  final String peerBaseUrl;
  final String peerToken;

  final String romCrc;

  /// Authenticated partner cover URL, or null when the game has no cover.
  final String? coverUrl;

  @override
  State<PlayLobbyPage> createState() => _PlayLobbyPageState();
}

class _PlayLobbyPageState extends State<PlayLobbyPage> {
  late final PlaySignalingClient _signaling;
  StreamSubscription<PlaySession>? _sub;
  _LobbyPing? _ping;

  RomEntry? _localEntry;
  bool _busy = false;
  bool _launching = false;
  bool _popping = false;
  bool _guestReadySent = false;
  String? _fatal;

  PlaySession get s => widget.session;

  @override
  void initState() {
    super.initState();
    _signaling = widget.signalingClient ??
        PlaySignalingClient(
            baseUrl: widget.peerBaseUrl, peerToken: widget.peerToken);
    _sub = widget.plays.changes.listen(_onChange);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    try {
      final entries = await RomLibrary(widget.filesDir).load();
      final ownPort = s.role == PlayRole.host
          ? s.hostUdpPort
          : s.guestUdpPort;
      for (final e in entries) {
        if (e.crcKey == widget.romCrc) {
          _localEntry = e;
          break;
        }
      }
      if (!mounted) return;
      setState(() {});
      // Host is created before the guest accepts, so guestUdpPort is still
      // null here; _onChange starts the probe once accept arrives.
      final peerPort =
          s.role == PlayRole.host ? s.guestUdpPort : s.hostUdpPort;
      if (ownPort != null && s.peerIp != null && peerPort != null) {
        final probe = _LobbyPing(
          ownPort: ownPort,
          peerIp: s.peerIp!,
          peerPort: peerPort,
          onUpdate: () {
            if (mounted) setState(() {});
          },
        );
        _ping = probe;
        await probe.start();
      }
    } catch (_) {/* lobby stays usable; probe is best effort */}
  }

  void _onChange(PlaySession sess) {
    if (!mounted || sess.roomId != s.roomId) return;
    if (sess.isTerminal) {
      setState(() {});
      _schedulePop();
      return;
    }
    setState(() {});
    // Guest: host opened the gate → launch immediately.
    if (s.role == PlayRole.guest &&
        sess.state == PlayState.starting &&
        sess.bootstrapPort != null) {
      _launchGuest();
    }
    // Host: the peer's port may appear only on accept — (re)start probe.
    if (s.role == PlayRole.host &&
        sess.state == PlayState.lobby &&
        _ping == null &&
        s.guestUdpPort != null &&
        s.peerIp != null) {
      final probe = _LobbyPing(
        ownPort: s.hostUdpPort!,
        peerIp: s.peerIp!,
        peerPort: s.guestUdpPort,
        onUpdate: () {
          if (mounted) setState(() {});
        },
      );
      _ping = probe;
      probe.start();
    }
  }

  Future<void> _schedulePop() async {
    if (_popping) return;
    _popping = true;
    await Future<void>.delayed(const Duration(milliseconds: 1800));
    if (mounted) Navigator.of(context).maybePop();
  }

  // -------------------------------------------------------------- actions

  Future<void> _guestReady() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _signaling.ready(s.roomId);
      _guestReadySent = true;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        _snack('准备失败：$e', error: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _hostStart() async {
    if (_busy || _launching) return;
    setState(() => _busy = true);
    final bootPort = 42000 + Random.secure().nextInt(20000);
    try {
      widget.plays.dispatchStartLocally(bootPort, s.roomId);
      // Signal first so the guest activity boots while the host activity is
      // still coming up; the Dart isolate keeps running during the switch.
      await _signaling.start(s.roomId, bootPort);
      await _launchHost(bootPort);
    } catch (e) {
      widget.plays.failLocal('start_failed', s.roomId);
      if (mounted) _snack('开始失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Map<String, dynamic> _extras({
    required int role,
    required int localPort,
    required int? peerPort,
    required String peerIp,
    required int bootstrapPort,
  }) {
    return {
      'role': role,
      'peerIp': peerIp,
      'peerPort': peerPort ?? 0,
      'localPort': localPort,
      'sessionKey': s.sessionKey!,
      'roomId': s.roomId32,
      'initialD': s.initialD,
      'adaptive': true,
      'bootstrapPort': bootstrapPort,
      'saveKey': s.romCrc,
    };
  }

  Future<void> _launchHost(int bootstrapPort) async {
    final e = _localEntry;
    if (e == null || s.sessionKey == null || s.guestUdpPort == null) {
      _snack('本机游戏数据缺失，无法开始', error: true);
      return;
    }
    _launching = true;
    await _ping?.close();
    await widget.pal.launchEmulator(
      relativePath: e.relativePath,
      coreId: s.coreId,
      platform: e.platform.name,
      netplay: _extras(
        role: 0,
        localPort: s.hostUdpPort!,
        peerPort: s.guestUdpPort,
        peerIp: s.peerIp!,
        bootstrapPort: bootstrapPort,
      ),
    );
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _launchGuest() async {
    if (_launching) return;
    final e = _localEntry;
    if (e == null ||
        s.sessionKey == null ||
        s.hostUdpPort == null ||
        s.guestUdpPort == null ||
        s.bootstrapPort == null ||
        s.peerIp == null) {
      if (mounted) {
        setState(() => _fatal = '启动数据不完整，请取消后重新发起');
      }
      return;
    }
    _launching = true;
    if (mounted) setState(() {});
    await _ping?.close();
    await widget.pal.launchEmulator(
      relativePath: e.relativePath,
      coreId: s.coreId,
      platform: e.platform.name,
      netplay: _extras(
        role: 1,
        localPort: s.guestUdpPort!,
        peerPort: s.hostUdpPort,
        peerIp: s.peerIp!,
        bootstrapPort: s.bootstrapPort!,
      ),
    );
    if (mounted) Navigator.of(context).maybePop();
  }

  Future<void> _cancel() async {
    if (_busy) return;
    try {
      await _signaling.cancel(s.roomId);
    } catch (_) {/* best effort */}
    widget.plays.cancelLocally(s.roomId);
  }

  @override
  void dispose() {
    _sub?.cancel();
    unawaited(_ping?.close());
    _signaling.close();
    super.dispose();
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          error ? Theme.of(context).colorScheme.errorContainer : null,
    ));
  }

  // ------------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isHost = s.role == PlayRole.host;
    final terminal = s.isTerminal;
    return PopScope(
      canPop: !_launching,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('联机大厅'),
          automaticallyImplyLeading: false,
          actions: [
            if (!terminal && !_launching)
              TextButton(
                onPressed: _busy ? null : _cancel,
                child: const Text('取消'),
              ),
          ],
        ),
        body: SafeArea(
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                children: [
                  _gameHeader(theme),
                  const SizedBox(height: 14),
                  _slotCard(
                    theme,
                    slot: 'P1',
                    name: isHost ? widget.plays.selfName : s.peerName,
                    isSelf: isHost,
                    badge: isHost ? '主机' : '对方',
                    ready: true,
                  ),
                  const SizedBox(height: 8),
                  _slotCard(
                    theme,
                    slot: 'P2',
                    name: isHost ? s.peerName : widget.plays.selfName,
                    isSelf: !isHost,
                    badge: isHost ? '对方' : '客机',
                    ready: isHost
                        ? s.guestReady
                        : (_guestReadySent || s.state == PlayState.starting),
                  ),
                  const SizedBox(height: 14),
                  _networkCard(theme),
                  const SizedBox(height: 14),
                  _statusLine(theme),
                  const SizedBox(height: 12),
                  if (_fatal != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(_fatal!,
                          style: TextStyle(
                              color: theme.colorScheme.error, fontSize: 13)),
                    ),
                  _actionArea(theme),
                  const SizedBox(height: 14),
                  const Text(
                    '请双方连接同一 Wi-Fi（或同一热点）并靠近路由；'
                    '数据仅两台手机直连，不经过任何服务器。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              if (terminal) _terminalOverlay(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gameHeader(ThemeData theme) {
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: 72,
            height: 72,
            child: widget.coverUrl != null
                ? Image.network(
                    widget.coverUrl!,
                    headers: {
                      HttpHeaders.authorizationHeader: 'Peer ${widget.peerToken}'
                    },
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _coverFallback(theme),
                  )
                : _coverFallback(theme),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.romName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text('${_coreLabel()} · 双人联机',
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }

  String _coreLabel() {
    // Store builds use the MAME core for arcade; community uses FBA-2012.
    // Both are arcade — only the NES/FC core should fall through to "NES / FC".
    switch (s.coreId) {
      case 'fbalpha2012':
        return '街机（FBA）';
      case 'mame':
      case 'neogeo':
        return '街机（MAME）';
      default:
        return 'NES / FC';
    }
  }

  Widget _coverFallback(ThemeData theme) => Container(
        color: theme.colorScheme.surfaceContainerHighest,
        alignment: Alignment.center,
        child: const Icon(Icons.sports_esports, size: 30),
      );

  Widget _slotCard(
    ThemeData theme, {
    required String slot,
    required String name,
    required bool isSelf,
    required String badge,
    required bool ready,
  }) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isSelf
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          child: Text(slot,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(name,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(badge, style: theme.textTheme.labelSmall),
            ),
          ],
        ),
        trailing: ready
            ? Icon(Icons.check_circle, color: Colors.green.shade600)
            : const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    );
  }

  Widget _networkCard(ThemeData theme) {
    final p = _ping;
    final samples = p?.samples.length ?? 0;
    final done = p?.done ?? false;
    final med = p?.medianMs;
    final p95 = p?.p95Ms;
    final suggestD = p?.suggestedD;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.wifi, size: 18),
                const SizedBox(width: 6),
                const Text('直连网络探测',
                    style: TextStyle(fontWeight: FontWeight.w800)),
                const Spacer(),
                Text(
                  done
                      ? (samples == 0
                          ? '无响应'
                          : '$samples 个样本')
                      : '探测中… $samples',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _stat(theme, 'RTT 中位', med == null ? '—' : '${med.toStringAsFixed(1)} ms'),
                const SizedBox(width: 18),
                _stat(theme, 'RTT P95', p95 == null ? '—' : '${p95.toStringAsFixed(1)} ms'),
                const SizedBox(width: 18),
                _stat(
                  theme,
                  '建议延迟 D',
                  suggestD == null ? '—' : '$suggestD 帧',
                  highlight: suggestD != null,
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'D = 每方额外等待的帧数（1 帧≈17ms）；网络越好 D 越小，'
              '对局中会按实测延迟自动在 1~2 帧间调整。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(ThemeData theme, String label, String value,
      {bool highlight = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall),
        const SizedBox(height: 2),
        Text(value,
            style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
                color: highlight ? theme.colorScheme.primary : null)),
      ],
    );
  }

  Widget _statusLine(ThemeData theme) {
    String text;
    IconData icon = Icons.hourglass_top;
    Color? color = theme.hintColor;
    switch (s.state) {
      case PlayState.inviting:
        text = '正在等待 ${s.peerName} 接受邀请（60 秒内有效）…';
      case PlayState.lobby:
        if (s.role == PlayRole.host) {
          text = s.guestReady ? '客机已准备，可以开始游戏' : '等待客机点「准备」…';
          if (s.guestReady) {
            icon = Icons.arrow_circle_right;
            color = Colors.green.shade700;
          }
        } else {
          text = _guestReadySent
              ? '已准备，等待主机开始游戏…'
              : '请点「准备」告知主机可以开始';
        }
      case PlayState.starting:
        text = '正在同步存档并启动…';
        icon = Icons.sync;
      case PlayState.playing:
        text = '对局进行中';
      case PlayState.ended:
      case PlayState.failed:
      case PlayState.idle:
        text = '';
    }
    if (text.isEmpty) return const SizedBox.shrink();
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Flexible(child: Text(text, style: TextStyle(color: color, fontSize: 13))),
      ],
    );
  }

  Widget _actionArea(ThemeData theme) {
    if (s.state == PlayState.starting) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(8),
          child: Column(
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 10),
              Text('正在启动模拟器…'),
            ],
          ),
        ),
      );
    }
    final isHost = s.role == PlayRole.host;
    if (isHost) {
      return FilledButton.icon(
        onPressed: (s.guestReady && !_busy) ? _hostStart : null,
        icon: const Icon(Icons.play_arrow),
        label: Text(_busy ? '正在开始…' : '开始游戏'),
      );
    }
    if (s.state != PlayState.lobby) {
      return FilledButton.icon(
        onPressed: null,
        icon: const Icon(Icons.hourglass_top),
        label: Text(s.state == PlayState.starting ? '主机已开始，正在启动…' : '等待进入大厅…'),
      );
    }
    return FilledButton.icon(
      onPressed: (!_busy && !_guestReadySent) ? _guestReady : null,
      icon: Icon(_guestReadySent ? Icons.check : Icons.sports_esports),
      label: Text(_busy
          ? '正在提交…'
          : _guestReadySent
              ? '已准备，等待主机开始'
              : '准备'),
    );
  }

  Widget _terminalOverlay(ThemeData theme) {
    final (icon, text) = switch (s.endReason) {
      PlayEndReason.declined => (Icons.person_remove_alt_1, '对方拒绝了邀请'),
      PlayEndReason.timedOut => (Icons.timer_off, '邀请已超时'),
      PlayEndReason.cancelled => (Icons.cancel, '会话已取消'),
      PlayEndReason.remoteBye => (Icons.logout, '对方已结束会话'),
      PlayEndReason.finished => (Icons.task_alt, '对局已结束'),
      _ => (Icons.error_outline, '会话异常结束：${s.errorCode ?? ''}'),
    };
    return Positioned.fill(
      child: Container(
        color: theme.scaffoldBackgroundColor.withValues(alpha: 0.92),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(text, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            const Text('即将返回…', style: TextStyle(color: Colors.grey)),
          ],
        ),
      ),
    );
  }
}

// ================================================================= UDP probe

/// Lobby RTT probe over the exact UDP ports the native channel will bind.
///
/// Wire format (17 bytes): 'GPNP' + u8 type(1=ping 2=pong) + u32 seq BE +
/// u64 clientSendMicros BE. Pongs echo the ping payload.
class _LobbyPing {
  _LobbyPing({
    required this.ownPort,
    required this.peerIp,
    required this.peerPort,
    this.onUpdate,
  });

  final int ownPort;
  final String peerIp;
  final int? peerPort;
  final VoidCallback? onUpdate;

  static const int _count = 150; // 150 * 20ms = 3s of continuous traffic
  static const Duration _interval = Duration(milliseconds: 20);

  RawDatagramSocket? _sock;
  Timer? _sender;
  final List<int> samples = [];
  bool done = false;

  Future<void> start() async {
    final port = peerPort;
    if (port == null) return;
    final RawDatagramSocket sock;
    try {
      sock = await RawDatagramSocket.bind(
          InternetAddress.anyIPv4, ownPort);
    } catch (_) {
      // Port busy (should not happen) — probe is advisory only.
      done = true;
      onUpdate?.call();
      return;
    }
    _sock = sock;
    final peer = InternetAddress(peerIp);
    sock.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = sock.receive();
      if (dg == null) return;
      final d = dg.data;
      if (d.length != 17 ||
          d[0] != 0x47 || d[1] != 0x50 || d[2] != 0x4e || d[3] != 0x50) {
        return;
      }
      if (d[4] == 1) {
        final pong = Uint8List.fromList([...d.sublist(0, 4), 2, ...d.sublist(5)]);
        sock.send(pong, dg.address, dg.port);
      } else if (d[4] == 2) {
        final t0 = _readU64(d, 9);
        final rtt = DateTime.now().microsecondsSinceEpoch - t0;
        if (rtt >= 0 && rtt < 1000000) samples.add(rtt);
        onUpdate?.call();
      }
    });
    var seq = 0;
    _sender = Timer.periodic(_interval, (t) {
      if (seq >= _count) {
        t.cancel();
        done = true;
        onUpdate?.call();
        return;
      }
      final b = BytesBuilder()
        ..add([0x47, 0x50, 0x4e, 0x50, 1])
        ..add(_u32(seq))
        ..add(_u64(DateTime.now().microsecondsSinceEpoch));
      sock.send(b.takeBytes(), peer, port);
      seq++;
    });
  }

  Future<void> close() async {
    _sender?.cancel();
    _sock?.close();
    _sock = null;
  }

  double? get medianMs => _pct(50);
  double? get p95Ms => _pct(95);

  /// Lobby recommendation only; the native layer owns the running D.
  int? get suggestedD {
    final p = p95Ms;
    if (p == null) return null;
    return p <= 12 ? 1 : 2;
  }

  double? _pct(int pct) {
    if (samples.isEmpty) return null;
    final v = [...samples]..sort();
    final idx = (v.length * pct / 100).round().clamp(0, v.length - 1);
    return v[idx] / 1000.0;
  }

  static List<int> _u32(int v) => [
        (v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff,
      ];

  static List<int> _u64(int v) => [
        for (var shift = 56; shift >= 0; shift -= 8) (v >> shift) & 0xff,
      ];

  static int _readU64(List<int> d, int off) {
    var v = 0;
    for (var i = 0; i < 8; i++) {
      v = (v << 8) | d[off + i];
    }
    return v;
  }
}
