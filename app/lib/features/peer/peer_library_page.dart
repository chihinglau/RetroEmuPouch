import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../data/peer/peer_client.dart';
import '../../data/peer/peer_discovery.dart';
import '../../data/peer/peer_sync.dart';
import '../../data/play/library_search.dart';
import '../../data/play/multiplayer_catalog.dart';
import '../../data/play/netplay_capability.dart';
import '../../data/play/play_session.dart';
import '../../data/rom_library.dart';
import '../../domain/rom_entry.dart';
import '../../config/app_channel.dart';
import '../../system_files.dart';
import '../../pal/platform_pal.dart';
import '../play/play_lobby_page.dart';

/// Browses one partner's library over an authenticated [PeerClient]:
/// search / platform filter / multi-select, then the 4-step import flow
/// (resources → conflicts → progress → summary).
class PeerLibraryPage extends StatefulWidget {
  const PeerLibraryPage({
    super.key,
    required this.pal,
    required this.client,
    required this.filesDir,
    required this.peerName,
    this.peerDeviceId,
    this.onLibraryChanged,
    this.onPeerRevoked,
    this.plays,
    this.selfName = '本机',
    this.selfDeviceId = '',
  });

  final PlatformPal pal;
  final PeerClient client;
  final String filesDir;
  final String peerName;

  /// Partner device id; used by the 401 view to offer local revocation.
  final String? peerDeviceId;

  /// Netplay signaling owner; when null the 「联机玩」 entries are hidden.
  final PlaySessionManager? plays;
  final String selfName;
  final String selfDeviceId;

  final Future<void> Function()? onLibraryChanged;

  /// Called after the user drops the local (stale) partner record from the
  /// credentials-expired view.
  final Future<void> Function(String deviceId)? onPeerRevoked;

  @override
  State<PeerLibraryPage> createState() => _PeerLibraryPageState();
}

class _PeerLibraryPageState extends State<PeerLibraryPage> {
  List<RemoteGame> _games = [];
  Set<String> _localCrcs = {};
  final Map<String, RomEntry> _localByCrc = {};
  String? _localVersionName;
  String? _peerVersionName;
  bool _inviteBusy = false;
  String? _runningCrc;
  bool _loading = true;
  bool _authFailed = false;
  String? _error;
  final _selected = <String>{};
  String _query = '';
  String? _platform;
  late final TextEditingController _searchCtl;

  @override
  void initState() {
    super.initState();
    _searchCtl = TextEditingController()
      ..addListener(() => setState(() => _query = _searchCtl.text));
    _load();
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  Set<String> _readLocalCrcs() {
    try {
      final f = File('${widget.filesDir}/rom_index.json');
      final j = jsonDecode(f.readAsStringSync());
      if (j is! List) return {};
      return j.whereType<Map>().map((e) {
        final v = (e['crc32'] as num?)?.toInt() ?? 0;
        return (v & 0xFFFFFFFF)
            .toRadixString(16)
            .padLeft(8, '0')
            .toUpperCase();
      }).toSet();
    } catch (_) {
      return {};
    }
  }

  /// Reload the on-device ROM inventory (CRC set + full entry map).
  /// Importing from a partner adds local entries, and both the netplay gate
  /// (owned-CRC map) and the arcade driver-name lookup need this refreshed,
  /// not just the CRC set — otherwise 「联机玩」 only appears after re-entry.
  Future<void> _refreshLocalInventory() async {
    final entries = await RomLibrary(widget.filesDir).load();
    if (!mounted) return;
    setState(() {
      _localCrcs = _readLocalCrcs();
      _localByCrc
        ..clear()
        ..addEntries(entries.map((e) => MapEntry(e.crcKey, e)));
    });
  }

  Future<void> _load() async {
    try {
      final payload = await widget.client.library();
      final games = RemoteGame.parseLibrary(payload);
      String? running;
      try {
        final k = (await widget.pal.runningSaveKey())?.toUpperCase();
        if (k != null && RegExp(r'^[0-9A-F]{8}$').hasMatch(k)) running = k;
      } catch (_) {/* running-lock lookup is best effort */}
      // Local inventory + both sides' version names power the netplay gate.
      await _refreshLocalInventory();
      String? localVer;
      String? peerVer;
      try {
        localVer = (await widget.pal.appVersion()).versionName;
      } catch (_) {/* gate then reports mismatch conservatively */}
      try {
        final info = await widget.client.info();
        peerVer = info['appVersion'] as String?;
      } catch (_) {/* peer version unknown → gate stays conservative */}
      if (!mounted) return;
      setState(() {
        _games = games;
        _localVersionName = localVer;
        _peerVersionName = peerVer;
        _runningCrc = running;
        _loading = false;
      });
    } on PeerUnauthorizedException {
      if (mounted) {
        setState(() {
          _authFailed = true;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  List<RemoteGame> get _visible {
    final q = _query.trim().toLowerCase();
    return _games.where((g) {
      if (_platform != null && g.platform != _platform) return false;
      if (q.isNotEmpty) {
        final mode = MultiplayerCatalog.instance?.modeFor(
          coreId: NetplayCapability.coreForPlatform(g.platform) ?? '',
          romCrc: g.crc,
          driverName: _arcadeDriverName(g),
        );
        final hay = [
          g.title, g.nameCn, g.name, g.platform,
          (g.metadata?['developer'] ?? '').toString(),
          (g.metadata?['publisher'] ?? '').toString(),
          LibrarySearch.attrTags(
            mode: mode,
            hasCheats: g.hasCheats,
            hasSave: g.hasBattery || g.hasAuto || g.slots.isNotEmpty,
          ),
        ].join(' ').toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList()
      ..sort((a, b) =>
          a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  /// 仅按搜索词过滤(不参与平台筛选), 用于给平台标签计算数量。
  List<RemoteGame> get _searchFiltered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _games;
    return _games.where((g) {
      final mode = MultiplayerCatalog.instance?.modeFor(
        coreId: NetplayCapability.coreForPlatform(g.platform) ?? '',
        romCrc: g.crc,
        driverName: _arcadeDriverName(g),
      );
      final hay = [
        g.title, g.nameCn, g.name, g.platform,
        (g.metadata?['developer'] ?? '').toString(),
        (g.metadata?['publisher'] ?? '').toString(),
        LibrarySearch.attrTags(
          mode: mode,
          hasCheats: g.hasCheats,
          hasSave: g.hasBattery || g.hasAuto || g.slots.isNotEmpty,
        ),
      ].join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  Future<void> _openImport() async {
    final picked = _games
        .where((g) => _selected.contains(g.crc))
        .toList(growable: false);
    if (picked.isEmpty) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _ImportFlowPage(
          pal: widget.pal,
          client: widget.client,
          filesDir: widget.filesDir,
          peerName: widget.peerName,
          games: picked,
          localCrcs: _localCrcs,
          runningCrc: _runningCrc,
          onLibraryChanged: widget.onLibraryChanged,
        ),
      ),
    );
    if (changed == true && mounted) {
      // Full inventory reload (not just the CRC set) so newly imported games
      // immediately satisfy the netplay owned-gate and arcade driver lookup.
      await _refreshLocalInventory();
      if (mounted) setState(_selected.clear);
    }
  }

  // --------------------------------------------------------------- netplay

  bool get _sameVersion =>
      _localVersionName != null &&
      _peerVersionName != null &&
      _localVersionName == _peerVersionName;

  /// Resolve the arcade driver stem used to key the multiplayer catalog for
  /// [g]. Library-imported ROMs store the humanised display name in
  /// [RomEntry.name] (e.g. `拳皇97.zip`), which never matches the catalog
  /// driver key `kof97` — so partner-owned arcade games silently lost their
  /// 「联机玩」 entry. Prefer [RomEntry.originalName] (the real driver file
  /// name, e.g. `kof97.zip`); fall back to the display name, then the
  /// partner-advertised name. `driverFromFileName` strips trailing archive
  /// extensions, so `<driver>.zip.zip` peer imports also resolve.
  String? _arcadeDriverName(RemoteGame g) {
    final local = _localByCrc[g.crc];
    final candidates = <String?>[
      local?.originalName,
      local?.name,
      g.name,
    ];
    for (final c in candidates) {
      if (c == null || c.isEmpty) continue;
      final d = MultiplayerCatalog.driverFromFileName(c);
      if (d.isNotEmpty) return d;
    }
    return null;
  }

  /// Catalog lookup for [g]: null means single-player / unknown, and such
  /// games never render a netplay entry. Arcade games key off the local
  /// zip's driver name when owned, else the partner-advertised file name.
  MultiplayerMode? _multiplayerMode(RemoteGame g) {
    final cat = MultiplayerCatalog.instance;
    if (cat == null) return null;
    final coreId = NetplayCapability.coreForPlatform(g.platform);
    if (coreId == null) return null;
    // Both arcade cores key off the zip's driver name: FBA-2012 in the
    // community build, MAME in the store build (dual-licensed). Handle both
    // so store-build arcade games still resolve their multiplayer mode.
    final driverName =
        (coreId == 'fbalpha2012' || coreId == 'mame') ? _arcadeDriverName(g) : null;
    return cat.modeFor(
        coreId: coreId, romCrc: g.crc, driverName: driverName);
  }

  /// Rejection code for inviting [g], or null when the invite is allowed.
  /// Non-owned games never render an entry, so that branch is defensive.
  String? _inviteBlock(RemoteGame g, {required bool isMultiplayer}) {
    return NetplayCapability.rejectReason(
      coreId: NetplayCapability.coreForPlatform(g.platform),
      localOwned: _localByCrc.containsKey(g.crc),
      sameVersion: _sameVersion,
      paired: widget.client.token != null &&
          (widget.peerDeviceId?.isNotEmpty ?? false),
      isMultiplayer: isMultiplayer,
    );
  }

  Future<void> _invite(RemoteGame g) async {
    final pm = widget.plays;
    final mode = _multiplayerMode(g);
    final block = _inviteBlock(g, isMultiplayer: mode != null);
    if (block != null) {
      _snack(NetplayCapability.reasonText(block));
      return;
    }
    if (pm == null) {
      _snack('联机服务未开启');
      return;
    }
    if (pm.current != null || _inviteBusy) {
      _snack('已有一个联机邀请或对局在进行');
      return;
    }
    final coreId = NetplayCapability.coreForPlatform(g.platform)!;
    final hostUdpPort = 42000 + Random.secure().nextInt(20000);
    setState(() => _inviteBusy = true);
    PlaySession? session;
    // This page may have been open since before the partner reopened their
    // peers page (new random HTTP port). Resolve the live endpoint with a
    // unicast PING before posting; fall back to the cached URL when UDP is
    // filtered but the saved TCP endpoint is still reachable.
    var baseUrl = widget.client.baseUrl;
    final peerDeviceId = widget.peerDeviceId;
    if (peerDeviceId != null && peerDeviceId.isNotEmpty) {
      try {
        final fresh = await PeerScanner().probeOne(
          InternetAddress(Uri.parse(baseUrl).host),
          selfDeviceId: widget.selfDeviceId,
          expectDeviceId: peerDeviceId,
        );
        if (fresh != null) baseUrl = fresh.baseUrl;
      } catch (_) {/* keep the cached base URL */}
    }
    final signaling = PlaySignalingClient(
        baseUrl: baseUrl, peerToken: widget.client.token!);
    try {
      session = pm.createHost(
        peerDeviceId: widget.peerDeviceId!,
        peerName: widget.peerName,
        peerIp: Uri.parse(baseUrl).host,
        coreId: coreId,
        romCrc: g.crc,
        romName: g.title,
        hostUdpPort: hostUdpPort,
      );
      await signaling.invite(
        roomId: session.roomId,
        coreId: coreId,
        romCrc: g.crc,
        romName: g.title,
        versionCode: pm.localVersionCode,
        proto: PlayProtocol.netplayProtoVersion,
        hostUdpPort: hostUdpPort,
        hostName: pm.selfName,
      );
    } catch (e) {
      if (session != null) pm.failLocal('invite_failed', session.roomId);
      _snack('邀请发送失败：$e', error: true);
      return;
    } finally {
      signaling.close();
      if (mounted) setState(() => _inviteBusy = false);
    }
    if (!mounted) return;
    final coverUrl = g.hasCover && widget.client.token != null
        ? '$baseUrl/api/peer/cover/${g.crc}'
        : null;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayLobbyPage(
          pal: widget.pal,
          plays: pm,
          session: session!,
          filesDir: widget.filesDir,
          peerBaseUrl: baseUrl,
          peerToken: widget.client.token!,
          romCrc: g.crc,
          coverUrl: coverUrl,
        ),
      ),
    );
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor:
          error ? Theme.of(context).colorScheme.errorContainer : null,
    ));
  }

  /// Drop the stale local partner record after a 401 so the peers list
  /// offers pairing again instead of pretending the link still exists.
  Future<void> _revokeLocally() async {
    final deviceId = widget.peerDeviceId;
    if (deviceId == null || widget.onPeerRevoked == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除本地伙伴记录'),
        content: const Text('将删除本机保存的该伙伴凭据，删除后可在列表中重新配对。'),
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
    if (ok != true || !mounted) return;
    await widget.onPeerRevoked!(deviceId);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.peerName} 的游戏库'),
        actions: [
          if (!_loading && !_authFailed && _error == null && _games.isNotEmpty)
            TextButton(
              onPressed: () => setState(() {
                if (_selected.length == _games.length) {
                  _selected.clear();
                } else {
                  _selected.addAll(_games.map((g) => g.crc));
                }
              }),
              child: Text(
                  _selected.length == _games.length ? '清除选择' : '全选'),
            ),
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: FilledButton.icon(
                  onPressed: _openImport,
                  icon: const Icon(Icons.download_outlined),
                  label: Text('导入所选（${_selected.length}）'),
                ),
              ),
            ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('正在读取伙伴的游戏库…', textAlign: TextAlign.center),
              SizedBox(height: 6),
              Text('伙伴游戏较多时，首次加载可能需要几十秒，请稍候',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            ],
          ),
        ),
      );
    }
    if (_authFailed) {
      return _hint(
        icon: Icons.no_encryption_outlined,
        title: '伙伴凭据已失效',
        body: '对方可能已解除与你的伙伴关系，请返回列表重新配对后再试。',
        action: (widget.peerDeviceId != null &&
                widget.onPeerRevoked != null)
            ? OutlinedButton.icon(
                onPressed: _revokeLocally,
                icon: const Icon(Icons.link_off),
                label: const Text('解除本地伙伴记录'),
              )
            : null,
      );
    }
    if (_error != null) {
      return _hint(
        icon: Icons.cloud_off,
        title: '无法读取对方游戏库',
        body: '$_error\n\n请确认双方仍在同一 Wi-Fi / 热点且停留在发现伙伴页面。',
      );
    }
    if (_games.isEmpty) {
      return _hint(
        icon: Icons.inbox_outlined,
        title: '对方的游戏库是空的',
        body: '伙伴还没有导入任何游戏。',
      );
    }

    final searchFiltered = _searchFiltered;
    final platforms = searchFiltered.map((g) => g.platform).toSet().toList()
      ..sort();
    final counts = <String, int>{};
    for (final g in searchFiltered) {
      counts[g.platform] = (counts[g.platform] ?? 0) + 1;
    }
    final visible = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: TextField(
            controller: _searchCtl,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索对方游戏名 / 双人 / 金手指 / 存档…',
              prefixIcon: const Icon(Icons.search, size: 20),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
              contentPadding: const EdgeInsets.symmetric(vertical: 0),
            ),
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text('全部 (${searchFiltered.length})'),
                  selected: _platform == null,
                  visualDensity: VisualDensity.compact,
                  onSelected: (_) => setState(() => _platform = null),
                ),
              ),
              for (final p in platforms)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${platformLabel(p)} (${counts[p] ?? 0})'),
                    selected: _platform == p,
                    visualDensity: VisualDensity.compact,
                    onSelected: (_) => setState(() => _platform = p),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('没有符合搜索的游戏'))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final landscape =
                        MediaQuery.of(context).size.width >
                            MediaQuery.of(context).size.height;
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 16),
                      gridDelegate: _gridDelegate(
                          constraints.maxWidth, landscape),
                      itemCount: visible.length,
                      itemBuilder: (_, i) {
                        final g = visible[i];
                        final owned = _localByCrc.containsKey(g.crc);
                        // Multiplayer gate: single-player / unknown games get
                        // no netplay entry at all, but still show a mode badge
                        // when the catalog classifies them.
                        final mode = _multiplayerMode(g);
                        final block = owned &&
                                widget.plays != null &&
                                mode != null
                            ? _inviteBlock(g, isMultiplayer: true)
                            : null;
                        return _RemoteGameCard(
                          game: g,
                          client: widget.client,
                          localExists: _localCrcs.contains(g.crc),
                          selected: _selected.contains(g.crc),
                          landscape: landscape,
                          multiplayerLabel: mode == null
                              ? null
                              : MultiplayerCatalog.labelOf(mode),
                          showInvite: owned &&
                              widget.plays != null &&
                              mode != null,
                          inviteBlock: block,
                          inviteBusy: _inviteBusy,
                          onInvite: () => _invite(g),
                          onTap: () => setState(() {
                            if (!_selected.remove(g.crc)) {
                              _selected.add(g.crc);
                            }
                          }),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _hint(
      {required IconData icon,
      required String title,
      required String body,
      Widget? action}) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 54, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
            if (action != null) ...[
              const SizedBox(height: 18),
              action,
            ],
          ],
        ),
      ),
    );
  }

  /// Grid geometry per orientation.
  ///
  /// Portrait keeps the dense tall poster cards (3 columns on phones). In
  /// landscape the grid viewport is short: a tall poster card would push its
  /// footer — the 联机玩 invite chip — below the visible row where it is
  /// clipped and untappable. Landscape therefore uses compact horizontal
  /// cards (cover on the left, title/badges/invite on the right) whose height
  /// is fixed independently of the column width, so the chip always lands in
  /// the visible area. Column count is derived from the measured width rather
  /// than a hard orientation breakpoint.
  static SliverGridDelegate _gridDelegate(double maxWidth, bool landscape) {
    const spacing = 10.0;
    if (!landscape) {
      return const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: 0.56,
      );
    }
    const cols = 2;
    // Compact rows: landscape viewports are short (as little as ~174dp on
    // 1260px-wide panels), so two full rows must fit with a peek sliver.
    const cellHeight = 80.0;
    const horizontalPadding = 24.0; // GridView left+right padding (12 each)
    final colWidth =
        (maxWidth - horizontalPadding - (cols - 1) * spacing) / cols;
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: cols,
      mainAxisSpacing: spacing,
      crossAxisSpacing: spacing,
      childAspectRatio: colWidth / cellHeight,
    );
  }
}

// ============================================================ remote card

class _RemoteGameCard extends StatelessWidget {
  const _RemoteGameCard({
    required this.game,
    required this.client,
    required this.localExists,
    required this.selected,
    required this.onTap,
    required this.showInvite,
    required this.inviteBlock,
    required this.inviteBusy,
    required this.onInvite,
    required this.landscape,
    this.multiplayerLabel,
  });

  final RemoteGame game;
  final PeerClient client;
  final bool localExists;
  final bool selected;
  final VoidCallback onTap;

  /// Landscape renders a compact horizontal card (cover left, meta right);
  /// portrait renders the tall poster card.
  final bool landscape;

  /// 「双人合作 / 双人对战 / 轮流上场」 badge; null for single-player games.
  final String? multiplayerLabel;

  /// Whether to render a netplay entry at all (game is locally owned and a
  /// play manager is attached).
  final bool showInvite;

  /// Null = invite allowed; otherwise a stable [NetplayCapability] reject
  /// code (the chip stays tappable so the reason text can be explained).
  final String? inviteBlock;
  final bool inviteBusy;
  final VoidCallback onInvite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final token = client.token;
    final title = Text(game.title,
        maxLines: landscape ? 1 : 2,
        overflow: TextOverflow.ellipsis,
        style:
            theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700));
    final badges = Wrap(spacing: 4, runSpacing: 2, children: [
      if (multiplayerLabel != null)
        _badge(theme, multiplayerLabel!, multiplayer: true),
      if (game.hasCheats) _badge(theme, '金手指'),
      if (game.hasBattery || game.hasAuto || game.slots.isNotEmpty)
        _badge(theme, '存档'),
      if (localExists) _badge(theme, '本机已有', highlight: true),
    ]);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      shape: selected
          ? RoundedRectangleBorder(
              side: BorderSide(color: theme.colorScheme.primary, width: 2.5),
              borderRadius: BorderRadius.circular(12),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(7),
          child: landscape
              ? _landscapeBody(theme, token, title, badges)
              : _portraitBody(theme, token, title, badges),
        ),
      ),
    );
  }

  /// Tall poster card used in portrait: large flexible cover, footer below.
  Widget _portraitBody(
      ThemeData theme, String? token, Widget title, Widget badges) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: _cover(theme, token)),
      const SizedBox(height: 6),
      title,
      const SizedBox(height: 4),
      badges,
      if (showInvite) ...[
        const SizedBox(height: 5),
        _inviteChip(theme),
      ],
    ]);
  }

  /// Compact horizontal card used in landscape: narrow cover on the left,
  /// title on the first line, invite chip + badges wrapped on the second line.
  /// Everything lives in the top ~70dp so two rows fit in a short landscape
  /// viewport and the invite chip is never clipped.
  Widget _landscapeBody(
      ThemeData theme, String? token, Widget title, Widget badges) {
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: 88, child: _cover(theme, token)),
      const SizedBox(width: 8),
      Expanded(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              title,
              const SizedBox(height: 2),
              Wrap(
                spacing: 4,
                runSpacing: 0,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Chip first so it stays on the visible run even when the
                  // badges wrap onto a second line.
                  if (showInvite) _inviteChip(theme),
                  ..._landscapeBadgeWidgets(theme),
                ],
              ),
            ]),
      ),
    ]);
  }

  /// Badge widgets for the landscape wrap. Mirrors the badge list built in
  /// [build] without re-wrapping them in another [Wrap].
  List<Widget> _landscapeBadgeWidgets(ThemeData theme) {
    return [
      if (multiplayerLabel != null)
        _badge(theme, multiplayerLabel!, multiplayer: true),
      if (game.hasCheats) _badge(theme, '金手指'),
      if (game.hasBattery || game.hasAuto || game.slots.isNotEmpty)
        _badge(theme, '存档'),
      if (localExists) _badge(theme, '本机已有', highlight: true),
    ];
  }

  Widget _cover(ThemeData theme, String? token) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: game.hasCover && token != null
              ? Image.network(
                  '${client.baseUrl}/api/peer/cover/${game.crc}',
                  headers: {HttpHeaders.authorizationHeader: 'Peer $token'},
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) =>
                      _placeholder(theme),
                )
              : _placeholder(theme),
        ),
        Positioned(
          top: 4,
          right: 4,
          child: Icon(
            selected ? Icons.check_circle : Icons.radio_button_unchecked,
            color: selected ? theme.colorScheme.primary : Colors.white70,
          ),
        ),
      ],
    );
  }

  Widget _inviteChip(ThemeData theme) {
    final blocked = inviteBlock != null;
    final label = blocked ? '暂不可联机' : '联机玩';
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(
        message: blocked
            ? NetplayCapability.reasonText(inviteBlock!)
            : '邀请伙伴一起玩（你作为主机 / 1P）',
        child: blocked
            ? OutlinedButton.icon(
                onPressed: inviteBusy ? null : onInvite,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: theme.textTheme.labelSmall,
                ),
                icon: const Icon(Icons.lock_outline, size: 13),
                label: Text(label),
              )
            : FilledButton.tonalIcon(
                onPressed: inviteBusy ? null : onInvite,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: theme.textTheme.labelSmall,
                ),
                icon: const Icon(Icons.wifi, size: 14),
                label: Text(label),
              ),
      ),
    );
  }

  Widget _badge(ThemeData theme, String text,
      {bool highlight = false, bool multiplayer = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: highlight
            ? theme.colorScheme.primaryContainer
            : multiplayer
                ? theme.colorScheme.secondaryContainer
                : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }

  Widget _placeholder(ThemeData theme) {
    var h = 0;
    for (final c in game.title.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    final hue = HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.45, 0.32);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [hue.toColor(), hue.withLightness(0.18).toColor()],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        game.title.trim().isEmpty ? '?' : game.title.trim().substring(0, 1),
        style: const TextStyle(
            color: Colors.white, fontSize: 40, fontWeight: FontWeight.w900),
      ),
    );
  }
}

String platformLabel(String p) {
  const labels = {
    'nes': 'NES/FC',
    'fds': 'FDS',
    'gameBoy': 'Game Boy',
    'gba': 'GBA',
    'snes': 'SNES',
    'masterSystem': 'Master System',
    'genesis': 'MD',
    'atari2600': 'Atari 2600',
    'neogeo': 'NEOGEO',
    'mame': 'MAME',
    'ps1': 'PS1',
    'n64': 'N64',
    'nds': 'NDS',
    'psp': 'PSP',
  };
  return labels[p] ?? p.toUpperCase();
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

String _formatTime(int? ms) {
  if (ms == null) return '未知时间';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

// ============================================================== import flow

enum _Stage { configure, conflicts, progress, summary }

class _ImportFlowPage extends StatefulWidget {
  const _ImportFlowPage({
    required this.pal,
    required this.client,
    required this.filesDir,
    required this.peerName,
    required this.games,
    required this.localCrcs,
    required this.runningCrc,
    this.onLibraryChanged,
  });

  final PlatformPal pal;
  final PeerClient client;
  final String filesDir;
  final String peerName;
  final List<RemoteGame> games;
  final Set<String> localCrcs;
  final String? runningCrc;
  final Future<void> Function()? onLibraryChanged;

  @override
  State<_ImportFlowPage> createState() => _ImportFlowPageState();
}

class _ImportFlowPageState extends State<_ImportFlowPage> {
  late final Map<String, PeerGameSelection> _sel = {
    for (final g in widget.games)
      g.crc: PeerGameSelection(
        crc: g.crc,
        rom: appChannel.canPeerRom && !widget.localCrcs.contains(g.crc),
        // Explicit mutable set: the default is an unmodifiable const set.
        saveKinds: <String>{},
      ),
  };
  late final PeerImporter _importer =
      PeerImporter(filesDir: widget.filesDir, client: widget.client);

  _Stage _stage = _Stage.configure;
  List<PeerPlanItem> _plan = [];
  final Map<String, PeerItemAction> _decisions = {};
  bool _allCheatsOverwrite = false;
  bool _allSavesOverwrite = false;

  PeerProgress? _progress;
  double _bytesPerSec = 0;
  int? _lastBytes;
  DateTime? _lastTime;
  bool _cancelling = false;
  String? _fatal;
  int? _freeBytes;
  bool _notifiedLibrary = false;

  /// BIOS blobs the partner advertises in their `system/` dir ({name,size}).
  List<Map<String, dynamic>> _peerBios = const [];

  /// BIOS names the selected games require AND the partner actually has.
  final Set<String> _neededBios = {};

  /// BIOS names the user chose to sync (a subset of [_neededBios]).
  final Set<String> _selectedBios = {};

  /// Whether the user acknowledged the infringement-risk notice for this flow.
  bool _riskAcked = false;

  bool _saveLocked(String crc) => widget.runningCrc == crc;

  @override
  void initState() {
    super.initState();
    _initBios();
  }

  /// Fetch the partner's BIOS availability and auto-offer a sync for every
  /// BIOS the selected games need but the partner actually has; pre-select
  /// only the ones missing on this device so imports become playable at once.
  Future<void> _initBios() async {
    try {
      final list = await widget.client.biosList();
      if (!mounted) return;
      final available = <String>{};
      for (final m in list) {
        final n = m['name'];
        if (n is String && n.isNotEmpty) available.add(n);
      }
      final need = <String>{};
      for (final g in widget.games) {
        final sel = _sel[g.crc];
        if (sel == null || !sel.rom) continue;
        final coreId = NetplayCapability.coreForPlatform(g.platform);
        if (coreId == null) continue;
        for (final name in SystemFiles.requiredBiosFor(coreId)) {
          if (available.contains(name)) need.add(name);
        }
      }
      setState(() {
        _peerBios = list;
        _neededBios
          ..clear()
          ..addAll(need);
        for (final name in need) {
          if (!SystemFiles.hasBios('${widget.filesDir}/system', name)) {
            _selectedBios.add(name);
          }
        }
      });
    } catch (_) {/* BIOS list is best-effort; import still works without it */}
  }

  int _peerBiosSizeBytes(String name) {
    for (final m in _peerBios) {
      if (m['name'] == name && m['size'] is num) {
        return (m['size'] as num).toInt();
      }
    }
    return 0;
  }

  int get _estimatedBytes {
    var total = 0;
    for (final g in widget.games) {
      final s = _sel[g.crc]!;
      if (s.rom) {
        total += g.romSize;
        if (g.hasCover) total += g.coverSize;
      }
      if (s.cheats) total += 0; // JSON text, negligible
      if (s.saveKinds.contains('battery')) total += g.batterySize;
      if (s.saveKinds.contains('auto')) total += g.autoSize;
      for (final slot in g.slots) {
        if (s.saveKinds.contains('slot${slot.slot}')) total += slot.size;
      }
    }
    for (final name in _selectedBios) {
      total += _peerBiosSizeBytes(name);
    }
    return total;
  }

  int get _selectedCount =>
      _sel.values.where((s) => s.rom || s.cheats || s.saveKinds.isNotEmpty).length;

  Future<void> _buildConflictPlan() async {
    final plan = await _importer.buildPlan(
      games: widget.games,
      selections: _sel.values.toList(),
      runningCrcs: widget.runningCrc == null
          ? const {}
          : {widget.runningCrc!},
      biosToSync: {
        for (final n in _selectedBios) n: _peerBiosSizeBytes(n)
      },
    );
    for (final i in plan) {
      if (i.conflict && i.action == PeerItemAction.skip) {
        _decisions[_key(i)] = PeerItemAction.skip;
      }
    }
    setState(() {
      _plan = plan;
      _stage = _Stage.conflicts;
    });
  }

  String _key(PeerPlanItem i) =>
      '${i.crc}:${i.kind.name}:${i.slot ?? "-"}';

  PeerItemAction _effectiveAction(PeerPlanItem i) {
    if (i.blocked) return PeerItemAction.skip;
    if (i.kind == PeerResourceKind.cheats && _allCheatsOverwrite) {
      return PeerItemAction.overwrite;
    }
    if (i.isSave && _allSavesOverwrite) return PeerItemAction.overwrite;
    return _decisions[_key(i)] ?? i.action;
  }

  /// 违规/侵权风险提示：每次导入流程在真正开始传输前必须显式确认一次。
  ///
  /// Partner ROM transfer is enabled on every channel, so this acknowledgement
  /// is the compliance guard rail: nothing is downloaded until the user states
  /// they only transfer dumps they lawfully own. Asked once per flow, right
  /// before the first byte moves (re-tries reuse the earlier answer).
  Future<bool> _confirmCompliance() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('合规风险提示'),
            content: const SingleChildScrollView(
              child: Text(
                '伙伴互传功能仅限传输你依法拥有备份权的游戏 ROM / BIOS 等系统文件。\n\n'
                '请勿使用本功能传播未经权利人授权的游戏或 BIOS（盗版/破解），'
                '该类行为可能违反著作权法及相关平台规则。\n\n'
                '本功能为两台设备之间的点对点直接传输：本应用不提供、不中转、'
                '也不存储任何游戏内容。因你传输的内容所产生的纠纷与法律责任，'
                '由你自行承担。',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('我已知悉风险并继续'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _startTransfer() async {
    if (!_riskAcked) {
      final ok = await _confirmCompliance();
      if (ok != true) return;
      _riskAcked = true;
    }
    for (final i in _plan) {
      i.action = _effectiveAction(i);
    }
    int? free;
    try {
      free = await widget.pal.availableBytes();
    } catch (_) {
      free = null;
    }
    _freeBytes = free;
    setState(() {
      _stage = _Stage.progress;
      _cancelling = false;
      _fatal = null;
    });
    try {
      await _importer.execute(
        _plan,
        availableBytes: () => _freeBytes,
        isCancelled: () => _cancelling,
        onProgress: (p) {
          final now = DateTime.now();
          if (_lastTime != null) {
            final dt = now.difference(_lastTime!).inMilliseconds;
            if (dt > 0 && _lastBytes != null) {
              final inst = (p.received - _lastBytes!) * 1000 / dt;
              _bytesPerSec = _bytesPerSec == 0
                  ? inst
                  : _bytesPerSec * 0.7 + inst * 0.3;
            }
          }
          _lastTime = now;
          _lastBytes = p.received;
          if (mounted) setState(() => _progress = p);
        },
      );
      if (_counts().added + _counts().overwritten > 0) {
        _notifiedLibrary = true;
        await widget.onLibraryChanged?.call();
      }
      if (mounted) setState(() => _stage = _Stage.summary);
    } on PeerSpaceException catch (e) {
      if (mounted) {
        setState(() {
          _fatal = '空间不足，导入已中止：\n'
              '需要约 ${formatBytes(e.required)}（含 16MB 安全余量），'
              '本机剩余 ${formatBytes(e.available)}。\n请清理空间后重试，已完成的项目不会重传。';
        });
      }
    } catch (e) {
      if (mounted) setState(() => _fatal = '导入出错：$e');
    }
  }

  ({int added, int overwritten, int skipped, int failed, int bytes})
      _counts() {
    var added = 0, overwritten = 0, skipped = 0, failed = 0, bytes = 0;
    for (final i in _plan) {
      switch (i.status) {
        case PeerItemStatus.done:
          if (i.conflict && i.action == PeerItemAction.overwrite) {
            overwritten++;
          } else {
            added++;
          }
          bytes += i.remoteSize;
        case PeerItemStatus.skipped:
          skipped++;
        case PeerItemStatus.failed:
          failed++;
        case PeerItemStatus.pending:
          skipped++; // cancellation leftovers
      }
    }
    return (
      added: added,
      overwritten: overwritten,
      skipped: skipped,
      failed: failed,
      bytes: bytes
    );
  }

  Future<void> _retryFailed() async {
    setState(() {
      _stage = _Stage.progress;
      _fatal = null;
    });
    for (final i in _plan) {
      if (i.status == PeerItemStatus.failed) i.status = PeerItemStatus.pending;
    }
    try {
      await _importer.execute(
        _plan,
        availableBytes: () => _freeBytes,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!_notifiedLibrary &&
          _counts().added + _counts().overwritten > 0) {
        _notifiedLibrary = true;
        await widget.onLibraryChanged?.call();
      }
      if (mounted) setState(() => _stage = _Stage.summary);
    } on PeerSpaceException catch (e) {
      if (mounted) {
        setState(() =>
            _fatal = '空间不足：需要 ${formatBytes(e.required)}，'
                '剩余 ${formatBytes(e.available)}');
      }
    } catch (e) {
      if (mounted) setState(() => _fatal = '导入出错：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _stage != _Stage.progress || _cancelling,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_stage == _Stage.configure
              ? '选择要导入的内容'
              : _stage == _Stage.conflicts
                  ? '确认覆盖冲突'
                  : _stage == _Stage.progress
                      ? '正在从 ${widget.peerName} 导入'
                      : '导入完成'),
          automaticallyImplyLeading:
              _stage != _Stage.progress || _cancelling,
        ),
        body: switch (_stage) {
          _Stage.configure => _configureBody(),
          _Stage.conflicts => _conflictsBody(),
          _Stage.progress => _progressBody(),
          _Stage.summary => _summaryBody(),
        },
      ),
    );
  }

  // ------------------------------------------------------------- configure

  Widget _configureBody() {
    return Column(
      children: [
        // Compliance reminder. Partner ROM transfer is allowed on every
        // channel, so this is informational rather than blocking — the hard
        // acknowledgement happens right before bytes start moving.
        Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.secondaryContainer,
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.onSecondaryContainer),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '请仅传输你拥有合法备份的游戏与 BIOS。未经授权的游戏或 BIOS 可能侵犯著作权，'
                  '相关法律责任由你自行承担。',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_neededBios.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: _biosCard(),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            children: [
              for (final g in widget.games) _gameConfigCard(g),
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '已选 $_selectedCount 款游戏 · 预计 ${formatBytes(_estimatedBytes)}'
                  '（另保留 16MB 安全余量）',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 6),
                FilledButton(
                  onPressed:
                      _selectedCount == 0 ? null : _buildConflictPlan,
                  child: const Text('下一步：检查冲突'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _gameConfigCard(RemoteGame g) {
    final s = _sel[g.crc]!;
    final locked = _saveLocked(g.crc);
    final localHas = widget.localCrcs.contains(g.crc);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(g.title,
                style: Theme.of(context)
                    .textTheme
                    .titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            Text('${platformLabel(g.platform)} · ${formatBytes(g.romSize)}',
                style: Theme.of(context).textTheme.bodySmall),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: s.rom,
              onChanged: (v) =>
                  setState(() => s.rom = v ?? false),
              title: Text(localHas ? 'ROM（本机已有相同游戏）' : 'ROM（含封面与游戏资料）'),
            ),
            if (g.hasCheats)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: s.cheats,
                onChanged: (v) =>
                    setState(() => s.cheats = v ?? false),
                title: const Text('金手指'),
                subtitle: const Text('写入云同步快照层，不改动本机开关',
                            style: TextStyle(fontSize: 11)),
              ),
            if (g.hasBattery || g.hasAuto || g.slots.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 10),
                child: Text('存档',
                    style: Theme.of(context).textTheme.labelMedium),
              ),
              if (locked)
                Padding(
                  padding: const EdgeInsets.only(left: 10, top: 2, bottom: 2),
                  child: Text('该游戏正在模拟器中运行，请先退出游戏后才能导入存档',
                      style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error)),
                ),
              if (g.hasBattery)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  enabled: !locked,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: s.saveKinds.contains('battery'),
                  onChanged: (v) => setState(() =>
                      _toggleKind(s, 'battery', v ?? false)),
                  title: const Text('电池存档（.sav）'),
                  subtitle: Text('对方修改于 ${_formatTime(g.batteryMtime)}',
                      style: const TextStyle(fontSize: 11)),
                ),
              if (g.hasAuto)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  enabled: !locked,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: s.saveKinds.contains('auto'),
                  onChanged: (v) =>
                      setState(() => _toggleKind(s, 'auto', v ?? false)),
                  title: const Text('自动快照'),
                  subtitle: Text('对方修改于 ${_formatTime(g.autoMtime)}',
                      style: const TextStyle(fontSize: 11)),
                ),
              for (final slot in g.slots)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  enabled: !locked,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: s.saveKinds.contains('slot${slot.slot}'),
                  onChanged: (v) => setState(() =>
                      _toggleKind(s, 'slot${slot.slot}', v ?? false)),
                  title: Text('手动槽位 ${slot.slot}'
                      '${slot.hasThumb ? '（含缩略图）' : ''}'),
                  subtitle: Text('对方修改于 ${_formatTime(slot.mtimeMs)}',
                      style: const TextStyle(fontSize: 11)),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Card shown above the per-game list: the BIOS blobs the selected games
  /// need and the partner can provide. Toggling here adds/removes them from
  /// the sync plan; ones already on this device are pre-unticked.
  Widget _biosCard() {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('街机 BIOS 同步',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(
              '所选游戏需要以下 BIOS 文件，将从伙伴处同步，确保导入后即可游玩。',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            for (final name in _neededBios)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                value: _selectedBios.contains(name),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    _selectedBios.add(name);
                  } else {
                    _selectedBios.remove(name);
                  }
                }),
                title: Text(name),
                subtitle: SystemFiles.hasBios('${widget.filesDir}/system', name)
                    ? const Text('本机已有，将自动跳过',
                        style: TextStyle(fontSize: 11))
                    : Text('伙伴提供 · ${formatBytes(_peerBiosSizeBytes(name))}',
                        style: const TextStyle(fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }

  void _toggleKind(PeerGameSelection s, String kind, bool on) {
    setState(() {
      if (on) {
        s.saveKinds.add(kind);
      } else {
        s.saveKinds.remove(kind);
      }
    });
  }

  // ------------------------------------------------------------- conflicts

  Widget _conflictsBody() {
    final conflicts =
        _plan.where((i) => i.conflict && !i.blocked).toList();
    final blocked = _plan.where((i) => i.blocked).toList();
    final additions = _plan
        .where((i) => !i.conflict && !i.blocked)
        .toList();
    final romConflicts =
        conflicts.where((i) => i.kind == PeerResourceKind.rom).toList();
    final cheatConflicts =
        conflicts.where((i) => i.kind == PeerResourceKind.cheats).toList();
    final saveConflicts = conflicts.where((i) => i.isSave).toList();
    final transferBytes = _plan
        .where((i) => _effectiveAction(i) != PeerItemAction.skip)
        .fold<int>(0, (sum, i) => sum + i.remoteSize);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
            children: [
              _sectionTitle('新增内容（${additions.length} 项）'),
              if (additions.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(left: 10, bottom: 6),
                  child: Text('没有需要新增下载的内容。'),
                )
              else
                for (final i in additions) _plainRow(i),
              if (romConflicts.isNotEmpty) ...[
                _sectionTitle('ROM（本机已有，${romConflicts.length} 项）'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
                  child: Text(
                    '相同 CRC 视为同一游戏，默认跳过；若本机文件损坏或无法加载，'
                    '选「覆盖」从伙伴处重新下载并做完整性校验。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                for (final i in romConflicts) _conflictTile(i, enabled: true),
              ],
              if (cheatConflicts.isNotEmpty) ...[
                _sectionTitle('金手指冲突（${cheatConflicts.length} 项）'),
                SwitchListTile(
                  contentPadding: const EdgeInsets.only(left: 10),
                  dense: true,
                  title: const Text('对全部金手指冲突选择「覆盖」'),
                  subtitle: const Text('只覆盖云同步快照层，本机金手指开关不受影响',
                      style: TextStyle(fontSize: 11)),
                  value: _allCheatsOverwrite,
                  onChanged: (v) =>
                      setState(() => _allCheatsOverwrite = v),
                ),
                for (final i in cheatConflicts)
                  _conflictTile(i, enabled: !_allCheatsOverwrite),
              ],
              if (saveConflicts.isNotEmpty) ...[
                _sectionTitle('存档冲突（${saveConflicts.length} 项）'),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '⚠ 覆盖存档会永久丢失本机对应进度，且无法恢复。请仅在确认要用伙伴的进度替换本机进度时选择覆盖。',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: Theme.of(context).colorScheme.onErrorContainer),
                  ),
                ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.only(left: 10),
                  dense: true,
                  title: const Text('对全部存档冲突选择「覆盖」（危险）'),
                  value: _allSavesOverwrite,
                  onChanged: (v) =>
                      setState(() => _allSavesOverwrite = v),
                ),
                for (final i in saveConflicts)
                  _conflictTile(i,
                      enabled: !_allSavesOverwrite, strong: true),
              ],
              if (blocked.isNotEmpty) ...[
                _sectionTitle('已拦截（${blocked.length} 项）'),
                for (final i in blocked)
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                    child: Text('· ${i.title} ${i.kindLabel}：游戏运行中，'
                        '请先退出模拟器后再导入',
                        style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(context).colorScheme.error)),
                  ),
              ],
            ],
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('待传输约 ${formatBytes(transferBytes)}（另保留 16MB 余量）',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 6),
                FilledButton(
                  onPressed: additions.isEmpty &&
                          conflicts.every((i) =>
                              _effectiveAction(i) == PeerItemAction.skip)
                      ? null
                      : _startTransfer,
                  child: const Text('开始导入'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
        child: Text(t,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w800)),
      );

  Widget _plainRow(PeerPlanItem i) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      child: Row(
        children: [
          const Icon(Icons.download_for_offline_outlined, size: 16),
          const SizedBox(width: 6),
          Expanded(
            child: Text('${i.title} · ${i.kindLabel}',
                maxLines: 2,
                style: Theme.of(context).textTheme.bodySmall),
          ),
          Text(formatBytes(i.remoteSize),
              style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }

  Widget _conflictTile(PeerPlanItem i,
      {required bool enabled, bool strong = false}) {
    final action = _effectiveAction(i);
    return Opacity(
      opacity: enabled ? 1 : 0.6,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${i.title} · ${i.kindLabel}',
                  style: Theme.of(context).textTheme.bodySmall),
              if (i.isSave)
                Text(
                  '本机：${_formatTime(i.localMtime)} ｜ '
                  '伙伴：${_formatTime(i.remoteMtime)}',
                  style: TextStyle(
                      fontSize: 11,
                      color: strong
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).hintColor),
                ),
              // RadioGroup.onChanged is non-nullable, so disabled tiles are
              // blocked structurally with IgnorePointer (plus the 0.6 opacity
              // on the parent card).
              IgnorePointer(
                ignoring: !enabled,
                child: RadioGroup<PeerItemAction>(
                  groupValue: action,
                  onChanged: (v) => setState(() {
                        if (v != null) _decisions[_key(i)] = v;
                      }),
                  child: Row(
                    children: [
                      const Radio<PeerItemAction>(
                          value: PeerItemAction.skip),
                      const Text('跳过（默认）'),
                      const SizedBox(width: 12),
                      Radio<PeerItemAction>(
                          value: PeerItemAction.overwrite),
                      Text('覆盖',
                          style: strong
                              ? TextStyle(
                                  color: Theme.of(context).colorScheme.error)
                              : null),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- progress

  Widget _progressBody() {
    if (_fatal != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 48, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 12),
              Text(_fatal!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () =>
                    setState(() => _stage = _Stage.summary),
                child: const Text('查看已完成项目'),
              ),
            ],
          ),
        ),
      );
    }
    final p = _progress;
    final ratio = (p?.total ?? 0) > 0
        ? (p!.received / p.total!).clamp(0.0, 1.0)
        : null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p == null ? '准备开始…' : '游戏 ${p.gameIndex}/${p.gameCount}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Text(p?.label ?? '正在连接伙伴',
                textAlign: TextAlign.center,
                maxLines: 2,
                style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 18),
            LinearProgressIndicator(value: ratio),
            const SizedBox(height: 8),
            Text(
              p == null
                  ? ''
                  : '${formatBytes(p.received)}'
                      '${p.total == null ? '' : ' / ${formatBytes(p.total!)}'}'
                      '${_bytesPerSec > 0 ? ' · ${formatBytes(_bytesPerSec.round())}/s' : ''}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 24),
            OutlinedButton(
              onPressed: _cancelling
                  ? null
                  : () {
                      setState(() => _cancelling = true);
                    },
              child: Text(_cancelling ? '正在停止…' : '停止（已完成的项目会保留）'),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- summary

  Widget _summaryBody() {
    final c = _counts();
    final failedItems =
        _plan.where((i) => i.status == PeerItemStatus.failed).toList();
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.task_alt, size: 52),
            const SizedBox(height: 12),
            Text('导入结束', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            _summaryRow('新增', c.added),
            _summaryRow('覆盖', c.overwritten),
            _summaryRow('跳过', c.skipped),
            _summaryRow('失败', c.failed,
                color: c.failed > 0
                    ? Theme.of(context).colorScheme.error
                    : null),
            _summaryRow('传输字节', 0,
                raw: formatBytes(c.bytes)),
            if (failedItems.isNotEmpty) ...[
              const SizedBox(height: 14),
              SizedBox(
                height: 120,
                child: ListView(
                  children: [
                    for (final i in failedItems)
                      Text('· ${i.title} ${i.kindLabel}：'
                          '${i.error ?? '传输失败'}',
                          style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _retryFailed,
                icon: const Icon(Icons.refresh),
                label: const Text('重试失败项（已完成的不重传）'),
              ),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop(c.added + c.overwritten > 0),
              child: const Text('完成'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _summaryRow(String label, int value,
      {Color? color, String? raw}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(width: 80, child: Text(label)),
          Text(raw ?? '$value',
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontSize: 16)),
        ],
      ),
    );
  }
}
