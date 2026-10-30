import 'package:flutter/material.dart';

import '../../data/cloud/cloud_client.dart';
import '../../data/cloud/cloud_config.dart';
import '../../data/play/library_search.dart';
import '../../data/play/multiplayer_catalog.dart';

/// Browse the server-published catalog and manage the subscription set.
/// Pops `true` when subscriptions changed (caller may kick off a sync).
class CloudLibraryPage extends StatefulWidget {
  const CloudLibraryPage({
    super.key,
    required this.config,
    required this.filesDir,
  });

  final CloudConfig config;
  final String filesDir;

  @override
  State<CloudLibraryPage> createState() => _CloudLibraryPageState();
}

class _CloudLibraryPageState extends State<CloudLibraryPage> {
  final _queryCtl = TextEditingController();
  late final CloudClient _client = CloudClient(widget.config);

  List<Map<String, dynamic>> _catalog = const [];
  Set<String> _saved = {};
  Set<String> _pending = {};
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _queryCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _client.catalog(),
        _client.subscriptions(),
      ]);
      final items = results[0] as List<Map<String, dynamic>>;
      final subs = results[1] as Set<String>;
      if (!mounted) return;
      setState(() {
        _catalog = items;
        _saved = subs;
        _pending = {...subs};
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  bool get _dirty =>
      _pending.length != _saved.length || _pending.difference(_saved).isNotEmpty;

  Future<void> _save({bool popAfter = false}) async {
    setState(() => _saving = true);
    try {
      final crcs = _pending.toList()..sort();
      await _client.setSubscriptions(crcs);
      if (!mounted) return;
      setState(() {
        _saved = {..._pending};
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('订阅已保存（${crcs.length} 款游戏）')),
      );
      if (popAfter) Navigator.of(context).pop(true);
    } on CloudException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }

  /// Effective search text: while a Chinese IME holds a pinyin composing
  /// region, ignore the marked letters and filter on committed text only.
  String get _queryText {
    final v = _queryCtl.value;
    var q = v.text;
    final c = v.composing;
    if (c.isValid && !c.isCollapsed && c.end <= q.length) {
      q = q.replaceRange(c.start, c.end, '');
    }
    return q.trim().toLowerCase();
  }

  /// Multiplayer attribute of a published catalog item. Prefers the server
  /// snapshot's `mp` field (covers both FC and arcade); snapshots published
  /// before that field shipped still resolve locally for FC by CRC — arcade
  /// entries need one re-publish on the PC manager.
  MultiplayerMode? _modeOf(Map<String, dynamic> g) {
    switch (g['mp']) {
      case 'coop':
        return MultiplayerMode.coop;
      case 'versus':
        return MultiplayerMode.versus;
      case 'turn':
        return MultiplayerMode.turn;
    }
    final crc = g['crc'];
    return crc is String
        ? MultiplayerCatalog.instance?.modeFor(coreId: 'fceumm', romCrc: crc)
        : null;
  }

  List<Map<String, dynamic>> get _visible {
    final q = _queryText;
    if (q.isEmpty) return _catalog;
    return _catalog.where((g) {
      final hay = [
        g['title'], g['genre'], g['developer'], g['publisher'], g['crc'],
        LibrarySearch.attrTags(
          mode: _modeOf(g),
          hasCheats: ((g['cheatCount'] as num?) ?? 0).toInt() > 0,
          hasSave: g['battery'] == true,
        ),
      ].whereType<String>().join(' ').toLowerCase();
      return hay.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('云游戏库'),
          actions: [
            IconButton(
              tooltip: '保存订阅并立即同步',
              onPressed: _saving || !_dirty ? null : () => _save(popAfter: true),
              icon: const Icon(Icons.cloud_sync),
            ),
            IconButton(
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh)),
          ],
        ),
        floatingActionButton: _loading || _error != null
            ? null
            : FloatingActionButton.extended(
                onPressed: _saving || !_dirty
                    ? null
                    : () => _save(),
                icon: const Icon(Icons.bookmark_added),
                label: Text(_dirty
                    ? '保存订阅（${_pending.length}）'
                    : '已订阅 ${_pending.length} 款'),
              ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 10),
              Text('加载失败：$_error', textAlign: TextAlign.center),
              const SizedBox(height: 14),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    if (_catalog.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text('服务器还没有发布任何游戏。\n请在 PC 管理台「发布管理」中发布游戏。',
              textAlign: TextAlign.center),
        ),
      );
    }
    final items = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            controller: _queryCtl,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索云游戏库 / 双人 / 金手指 / 存档…',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: _queryCtl.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索词',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        // clear() notifies the controller; setState also
                        // covers IME builds that swallow the change event.
                        _queryCtl.clear();
                        setState(() {});
                      },
                      icon: const Icon(Icons.cancel_outlined),
                    ),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('共 ${items.length} 款，已订阅 ${_pending.length} 款',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 92),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 4),
            itemBuilder: (ctx, i) => _tile(items[i]),
          ),
        ),
      ],
    );
  }

  Widget _tile(Map<String, dynamic> g) {
    final crc = (g['crc'] as String? ?? '').toUpperCase();
    final sub = _pending.contains(crc);
    final cheatCount = (g['cheatCount'] as num?)?.toInt() ?? 0;
    final meta = [
      g['platform'] as String?,
      g['genre'] as String?,
      g['releaseDate'] as String?,
      if (cheatCount > 0) '金手指 $cheatCount',
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    return CheckboxListTile(
      value: sub,
      onChanged: _saving
          ? null
          : (v) => setState(() {
                if (v == true) {
                  _pending.add(crc);
                } else {
                  _pending.remove(crc);
                }
              }),
      title: Text(g['title'] as String? ?? crc,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(meta,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall),
      secondary: Icon(
        Icons.videogame_asset_outlined,
        color: sub ? Theme.of(context).colorScheme.primary : null,
      ),
    );
  }
}
