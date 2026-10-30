import 'dart:io';

import 'package:flutter/material.dart';

import '../../main.dart';
import '../../data/play/library_search.dart';
import '../../data/play/multiplayer_catalog.dart';
import '../../data/rom_library.dart';
import '../../data/package/game_package.dart';
import '../../domain/rom_entry.dart';
import '../../pal/platform_pal.dart';
import '../../system_files.dart';
import '../account/account_page.dart';
import '../settings/settings_sheet.dart';
import 'missing_bios_dialog.dart';

enum _SortBy { title, releaseDate, size, recent }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.pal});

  final PlatformPal pal;

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with WidgetsBindingObserver, RouteAware {
  RomLibrary? _library;
  String? _filesDir;
  List<RomEntry> _entries = [];
  /// CRC / arcade-driver keys with a real save file; powers 「存档」 keyword.
  Set<String> _saveKeys = {};
  /// Offline-share selection mode: when true, tapping a card toggles its
  /// inclusion in the exported game resource package.
  bool _selecting = false;
  final Set<String> _selected = {}; // keyed by RomEntry.relativePath
  bool _loading = true;
  String? _error;
  /// BIOS/system blobs (e.g. neogeo.zip) required by installed arcade cores
  /// but missing from `<filesDir>/system`. `null` until the first scan
  /// completes. Drives the first-screen "缺少系统文件" banner so users know
  /// which file to load before launching an arcade game.
  Set<String>? _missingBios;

  String _query = '';
  late final TextEditingController _searchCtl;
  String? _genreFilter;
  String? _categoryFilter;
  PlatformKind? _platformFilter;
  _SortBy _sortBy = _SortBy.title;

  /// Whether we've subscribed to [appRouteObserver] for our own route. Guarded
  /// so the subscribe in [didChangeDependencies] runs exactly once.
  bool _routeSubscribed = false;

  /// Library display order for platform sections (playable platforms first).
  static const _platformOrder = <PlatformKind>[
    PlatformKind.nes,
    PlatformKind.gameBoy,
    PlatformKind.gba,
    PlatformKind.masterSystem,
    PlatformKind.genesis,
    PlatformKind.atari2600,
    PlatformKind.snes,
    PlatformKind.ps1,
    PlatformKind.n64,
    PlatformKind.nds,
    PlatformKind.psp,
    PlatformKind.neogeo,
    PlatformKind.mame,
    PlatformKind.saturn,
    PlatformKind.wii,
  ];

  /// Platforms actually present in the library, in display order.
  List<PlatformKind> get _presentPlatforms {
    final set = _entries.map((e) => e.platform).toSet();
    return [
      ..._platformOrder.where(set.contains),
      ...set.where((p) => !_platformOrder.contains(p)),
    ];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _searchCtl = TextEditingController();
    _searchCtl.addListener(_onSearchChanged);
    _bootstrap();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to route notifications once we have a route in the tree, so a
    // pop back to this (root) page can refresh disk-derived state. Guarded
    // because didChangeDependencies fires more than once.
    if (_routeSubscribed) return;
    final route = ModalRoute.of(context);
    if (route != null) {
      appRouteObserver.subscribe(this, route);
      _routeSubscribed = true;
    }
  }

  @override
  void dispose() {
    if (_routeSubscribed) appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _searchCtl.dispose();
    super.dispose();
  }

  /// The emulator Activity returns immediately (the platform channel does
  /// not wait for emulation to end), so save files created inside a session
  /// are picked up when the app resumes to the library rather than after
  /// `launchEmulator` awaits.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshOnVisible();
  }

  /// A route pushed above us (设置 / 账号 / 发现·伙伴 / 模拟器 …) was popped, so
  /// this page is visible again. Refresh disk-derived state so a BIOS landed by
  /// an external PC 手机同步 (adb) push or an in-app peer import is reflected in
  /// the "缺少系统文件" banner and the ROM grid immediately.
  @override
  void didPopNext() {
    _refreshOnVisible();
  }

  /// Re-reads entries / saves / BIOS from disk after the page becomes visible
  /// again. The root [LibraryPage] route never re-runs initState, so without
  /// this a BIOS (or ROM) pushed externally stays invisible until a cold
  /// restart — exactly the "导入 BIOS 后仍提示缺少" bug.
  Future<void> _refreshOnVisible() async {
    final lib = _library;
    if (lib == null) return; // bootstrap not finished yet
    try {
      final entries = await lib.load();
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (_) {/* best effort */}
    _scanSaves();
    _scanBios();
  }

  void _scanSaves() {
    final dir = _filesDir;
    if (dir == null) return;
    final next = LibrarySearch.scanSaveKeysSync(dir);
    final changed =
        next.length != _saveKeys.length || next.difference(_saveKeys).isNotEmpty;
    _saveKeys = next;
    // Avoid needless rebuilds on every resume when nothing was saved.
    if (changed && mounted) setState(() {});
  }

  /// Syncs `_query` from the search field. Driven by a controller listener
  /// instead of `TextField.onChanged` because some Chinese IMEs (Huawei/
  /// Sogou/Baidu) do not deliver onChanged('') when the last characters are
  /// backspaced inside an active composing region — the field looks empty but
  /// the list stays filtered. The explicit 「清除」suffix button (which calls
  /// `controller.clear()`) always goes through this listener.
  void _onSearchChanged() {
    final v = _searchCtl.value;
    var q = v.text;
    // While typing pinyin the composing (marked) letters live inside text;
    // filter on the committed part only so raw pinyin never hijacks results.
    final c = v.composing;
    if (c.isValid && !c.isCollapsed && c.end <= q.length) {
      q = q.replaceRange(c.start, c.end, '');
    }
    if (q != _query) setState(() => _query = q);
  }

  Future<void> _bootstrap() async {
    try {
      final dir = await widget.pal.filesDir();
      final lib = RomLibrary(dir);
      final entries = await lib.load();
      if (!mounted) return;
      setState(() {
        _filesDir = dir;
        _library = lib;
        _entries = entries;
        _loading = false;
      });
      _scanSaves();
      _scanBios();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Refreshes [_missingBios] by scanning `<filesDir>/system` for the BIOS
  /// blobs every arcade core on this device may need. Safe to call any time;
  /// storage errors are swallowed so the banner simply stays hidden.
  Future<void> _scanBios() async {
    try {
      // Mirror any user-supplied BIOS (e.g. neogeo.zip) into the per-core
      // locations cores actually read (MAME needs <system>/mame/roms, FBA/FBNeo
      // the root) before re-checking, so a one-time import boots every core.
      await SystemFiles.syncAll(widget.pal);
      final missing = await SystemFiles.checkMissing(widget.pal);
      if (!mounted) return;
      setState(() => _missingBios = missing);
    } catch (e) {
      debugPrint('BIOS scan failed: $e');
      if (!mounted) return;
      setState(() => _missingBios = const {});
    }
  }

  /// Opens the system-file picker and copies the chosen BIOS blob into
  /// `<filesDir>/system`, then re-scans so the banner/dialog clear once the
  /// file is in place.
  Future<void> _importBios() async {
    try {
      final name = await widget.pal.importBiosViaSaf();
      if (name == null) return;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入系统文件：$name')),
      );
      await _scanBios();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _import() async {
    try {
      final imported = await widget.pal.importRomViaSaf();
      if (imported == null) return;
      final next = _library!.upsert(_entries, imported.toEntry());
      await _library!.save(next);
      // reload so the new entry picks up synced metadata/cover
      final reloaded = await _library!.load();
      if (!mounted) return;
      setState(() => _entries = reloaded);
      _scanBios();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入：${imported.name}')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  void _enterSelection() {
    if (_library == null) return;
    setState(() => _selecting = true);
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelect(RomEntry e) {
    setState(() {
      if (_selected.contains(e.relativePath)) {
        _selected.remove(e.relativePath);
      } else {
        _selected.add(e.relativePath);
      }
    });
  }

  void _toggleSelectAll() {
    final visiblePaths = _visible.map((e) => e.relativePath).toSet();
    if (visiblePaths.isEmpty) return;
    setState(() {
      if (visiblePaths.every(_selected.contains)) {
        _selected.removeAll(visiblePaths);
      } else {
        _selected.addAll(visiblePaths);
      }
    });
  }

  List<RomEntry> get _selectedEntries =>
      _entries.where((e) => _selected.contains(e.relativePath)).toList();

  /// Exports the selected games (ROM + optional 金手指/存档/封面) as a single
  /// ZIP the user saves via SAF, for offline copy to another phone.
  Future<void> _exportSelected() async {
    if (_selected.isEmpty || _library == null || _filesDir == null) return;
    final options = await showDialog<PackageOptions>(
      context: context,
      builder: (ctx) {
        var cheats = true;
        var saves = true;
        var covers = true;
        var includeBios = true;
        // BIOS blobs actually installed under <filesDir>/system (any core
        // location). Only these can be bundled; list them so the user picks
        // which to carry without leaving for 设置 → 系统文件（BIOS）.
        final installedBios = SystemFiles.biosNames()
            .where((n) => SystemFiles.hasBios('$_filesDir/system', n))
            .toList();
        final biosSel = <String>{...installedBios};
        return AlertDialog(
          title: const Text('导出游戏资源包'),
          content: StatefulBuilder(
            builder: (ctx2, setSt) {
              Widget row(String label, bool v, void Function(bool?)? onChanged) =>
                  CheckboxListTile(
                    dense: true,
                    title: Text(label),
                    value: v,
                    onChanged: onChanged,
                  );
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    row('ROM 游戏文件（必含）', true, null),
                    row('金手指', cheats, (v) => setSt(() => cheats = v ?? false)),
                    row('存档', saves, (v) => setSt(() => saves = v ?? false)),
                    row('封面', covers, (v) => setSt(() => covers = v ?? false)),
                    row('BIOS 系统文件', includeBios,
                        (v) => setSt(() => includeBios = v ?? false)),
                    if (includeBios)
                      if (installedBios.isEmpty)
                        const Padding(
                          padding: EdgeInsets.only(left: 16, bottom: 4),
                          child: Text('未安装任何 BIOS（可在 设置 → 系统文件 导入）',
                              style: TextStyle(fontSize: 12)),
                        )
                      else
                        ...installedBios.map((n) => CheckboxListTile(
                              dense: true,
                              contentPadding: const EdgeInsets.only(left: 32),
                              title: Text(n),
                              value: biosSel.contains(n),
                              onChanged: (v) => setSt(() {
                                if (v == true) {
                                  biosSel.add(n);
                                } else {
                                  biosSel.remove(n);
                                }
                              }),
                            )),
                  ],
                ),
              );
            },
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            TextButton(
              onPressed: () => Navigator.pop(
                  ctx,
                  PackageOptions(
                    includeCheats: cheats,
                    includeSaves: saves,
                    includeCovers: covers,
                    includeBios: includeBios && installedBios.isNotEmpty,
                    biosNames:
                        includeBios ? biosSel.toList() : const <String>[],
                  )),
              child: const Text('导出'),
            ),
          ],
        );
      },
    );
    if (options == null) return;

    // Live progress so the (blocking) zip build never looks like a freeze.
    StateSetter? refresh;
    var progDone = 0;
    var progTotal = _selected.length;
    var progLabel = '正在准备…';
    var saving = false;

    if (!mounted) return;
    // Capture the navigator before any async gap so we can dismiss the
    // progress dialog in `finally` without touching a BuildContext across awaits.
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setSt) {
          refresh = setSt;
          return AlertDialog(
            title: const Text('正在导出资源包'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: progTotal > 0 ? progDone / progTotal : null,
                ),
                const SizedBox(height: 12),
                Text(saving ? '打包完成，请在系统弹窗中选择保存位置…' : progLabel),
                const SizedBox(height: 6),
                Text('$progDone / $progTotal',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          );
        },
      ),
    );

    File? tmp;
    try {
      final now = DateTime.now();
      final stamp =
          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}';
      tmp = File('$_filesDir/export_cache/gamepouch-package-$stamp.zip');
      await tmp.parent.create(recursive: true);
      final out = await GamePackage(_filesDir!).buildPackage(
        _selectedEntries,
        tmp.path,
        options,
        appVersion: (await widget.pal.appVersion()).versionName,
        onProgress: (done, total, label) {
          refresh?.call(() {
            progDone = done;
            if (total > 0) progTotal = total;
            if (label != null) progLabel = label;
          });
        },
      );
      refresh?.call(() {
        saving = true;
        progLabel = '打包完成，请在系统弹窗中选择保存位置…';
      });
      final ok = await widget.pal.exportPackageViaSaf(
        sourcePath: out.path,
        suggestedName: '游戏资源包-${_selected.length}个游戏-$stamp.zip',
      );
      if (!mounted) return;
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已导出资源包（${_selected.length} 个游戏），'
                '可通过文件管理器 / USB / 蓝牙拷贝分享')));
      } else {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('导出已取消')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (navigator.canPop()) navigator.pop();
      try {
        if (tmp != null && tmp.existsSync()) await tmp.delete();
      } catch (_) {/* best effort */}
      _exitSelection();
    }
  }

  /// Imports a picked ZIP, auto-detecting a gamepouch resource package (with
  /// manifest) vs a plain ROM zip, and merging everything in one shot.
  Future<void> _importPackage() async {
    try {
      final pkg = await widget.pal.importPackageViaSaf();
      if (pkg == null) return;
      // [pkg.path] is relative (`import_cache/<name>`). The OHOS native side
      // writes the picked file under <filesDir>/import_cache/, so resolve against
      // [_filesDir] explicitly — relying on the process CWD (as the previous
      // relative `File(pkg.path)` did) only worked on Android and silently broke
      // the package import on HarmonyOS.
      final zip = File('${_filesDir}/${pkg.path}');
      final result = await GamePackage(_filesDir!).importPackage(zip);
      var next = _entries;
      for (final e in result.entries) {
        next = _library!.upsert(next, e);
      }
      await _library!.save(next);
      final reloaded = await _library!.load();
      if (!mounted) return;
      setState(() => _entries = reloaded);
      _scanBios();
      _scanSaves();
      if (result.wasPackage) {
        final parts = <String>[
          '${result.entries.length} 个游戏',
          '金手指 ${result.cheatCount}',
          '存档 ${result.saveCount}',
        ];
        if (result.biosCount > 0) parts.add('BIOS ${result.biosCount}');
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已导入资源包：${parts.join(' / ')}')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已导入 ${result.entries.length} 个 ROM')));
      }
      try {
        if (zip.existsSync()) await zip.delete();
      } catch (_) {/* best effort */}
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _reload() async {
    if (_library == null) return;
    final reloaded = await _library!.load();
    if (!mounted) return;
    setState(() => _entries = reloaded);
    _scanBios();
  }

  Future<void> _openAccount() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AccountPage(pal: widget.pal, onSynced: _reload),
      ),
    );
  }

  Future<void> _launch(RomEntry entry) async {
    final core = entry.platform.coreId;
    if (core == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.platform.label} 核心将在后续里程碑提供')),
      );
      return;
    }
    // Compliance gate: arcade cores need a user-supplied BIOS (e.g.
    // neogeo.zip). Block the launch with a guidance dialog — instead of a raw
    // core error overlay — so the user knows which file to load and how.
    try {
      // Mirror the BIOS into every per-core location (MAME needs
      // <system>/mame/roms) before checking, so a file the user supplied once
      // is found wherever the core actually reads it from.
      await SystemFiles.syncAll(widget.pal);
      final missing = await SystemFiles.missingForCore(widget.pal, core);
      if (missing.isNotEmpty) {
        final resolved = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => MissingBiosDialog(
            pal: widget.pal,
            coreId: core,
            missing: missing,
            gameTitle: entry.displayTitle,
          ),
        );
        if (resolved != true) return;
      }
    } catch (e) {
      // If the pre-check can't run, fail open and let the core report — but
      // never block the user on a storage-access error.
      debugPrint('BIOS pre-check failed: $e');
    }
    await widget.pal.launchEmulator(
      relativePath: entry.relativePath,
      coreId: core,
      platform: entry.platform.name,
    );
    setState(() => entry.lastPlayedAt = DateTime.now());
    await _library?.save(_entries);
  }

  Future<void> _confirmDelete(RomEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除游戏'),
        content: Text('将同时删除游戏文件与索引记录：\n${entry.displayTitle}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || _library == null) return;
    final next = _library!.remove(_entries, entry);
    await _library!.save(next);
    if (!mounted) return;
    setState(() => _entries = next);
  }

  /// The most recently played game, pinned for one-tap 「继续游戏」.
  RomEntry? get _continueEntry {
    RomEntry? best;
    DateTime? bestTime;
    for (final e in _entries) {
      final t = e.lastPlayedAt;
      if (t != null && (bestTime == null || t.isAfter(bestTime))) {
        best = e;
        bestTime = t;
      }
    }
    return best;
  }

  List<RomEntry> get _visible {
    final q = _query.trim().toLowerCase();
    final list = _entries.where((e) {
      if (_platformFilter != null && e.platform != _platformFilter) {
        return false;
      }
      if (_genreFilter != null && e.genre != _genreFilter) return false;
      if (_categoryFilter != null && e.category != _categoryFilter) return false;
      if (q.isNotEmpty) {
        final hay = [
          e.displayTitle, e.genre, e.developer, e.publisher,
          e.description, e.region, e.name,
          LibrarySearch.attrTags(
            mode: LibrarySearch.modeForRomEntry(MultiplayerCatalog.instance, e),
            hasCheats: e.cheats.isNotEmpty,
            hasSave: _saveKeys.contains(e.crcKey) ||
                _saveKeys
                    .contains(MultiplayerCatalog.driverFromFileName(e.name)),
          ),
        ].whereType<String>().join(' ').toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();
    int dateKey(RomEntry e) {
      final d = e.releaseDate ?? '';
      final y = int.tryParse(d.length >= 4 ? d.substring(0, 4) : '') ?? 0;
      final m = d.length >= 7 ? int.tryParse(d.substring(5, 7)) ?? 0 : 0;
      return y * 100 + m;
    }

    switch (_sortBy) {
      case _SortBy.title:
        list.sort((a, b) =>
            a.displayTitle.toLowerCase().compareTo(b.displayTitle.toLowerCase()));
      case _SortBy.releaseDate:
        list.sort((a, b) => dateKey(b).compareTo(dateKey(a)));
      case _SortBy.size:
        list.sort((a, b) => b.size.compareTo(a.size));
      case _SortBy.recent:
        list.sort((a, b) =>
            (b.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
                .compareTo(a.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0)));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final genres = _entries
        .map((e) => e.genre)
        .whereType<String>()
        .toSet()
        .toList()
      ..sort();
    final categories = _entries.map((e) => e.category).whereType<String>().toSet().toList()
      ..sort();

    // Landscape phones: the IME (plus its suggestion strip) can consume more
    // than half of the short screen edge. Resizing the body leaves less room
    // than the fixed filter row needs, so let the keyboard cover the list
    // instead — the header stays put and the list scrolls beneath it.
    final landscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      resizeToAvoidBottomInset: !landscape,
      appBar: AppBar(
        title: _selecting
            ? Text('已选 ${_selected.length} 个')
            : const Text('趣玩匣游戏库'),
        leading: _selecting
            ? IconButton(
                tooltip: '退出选择',
                icon: const Icon(Icons.close),
                onPressed: _exitSelection,
              )
            : null,
        actions: _selecting
            ? [
                IconButton(
                  tooltip: '全选 / 取消全选',
                  icon: const Icon(Icons.select_all),
                  onPressed: _toggleSelectAll,
                ),
              ]
            : [
                IconButton(
                  tooltip: '账号 / 云服务 / 升级',
                  onPressed: _openAccount,
                  icon: const Icon(Icons.cloud_outlined),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  onSelected: (v) {
                    if (v == 'rom') {
                      _import();
                    } else if (v == 'pkg') {
                      _importPackage();
                    } else if (v == 'export') {
                      _enterSelection();
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                        value: 'rom', child: Text('导入 ROM（单文件）')),
                    PopupMenuItem(
                        value: 'pkg',
                        child: Text('导入游戏资源包 / ZIP（自动识别）')),
                    PopupMenuItem(
                        value: 'export',
                        child: Text('选择游戏并导出资源包')),
                  ],
                ),
                IconButton(
                  tooltip: '设置',
                  onPressed: () => SettingsSheet.show(context, pal: widget.pal),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
      ),
      floatingActionButton: _selecting
          ? FloatingActionButton.extended(
              onPressed: _selected.isEmpty ? null : _exportSelected,
              icon: const Icon(Icons.archive_outlined),
              label: Text('导出资源包（${_selected.length}）'),
            )
          : null,
      body: _buildBody(genres, categories),
    );
  }

  Widget _buildBody(List<String> genres, List<String> categories) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text('初始化失败：$_error', textAlign: TextAlign.center),
        ),
      );
    }
    if (_entries.isEmpty) return _buildEmptyState();

    final visible = _visible;
    final landscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final banner = _biosBanner();
    final pgmBanner = _pgmBanner();
    Widget? clearButton;
    if (_searchCtl.text.isNotEmpty) {
      clearButton = IconButton(
        tooltip: '清除搜索词',
        iconSize: 18,
        visualDensity: VisualDensity.compact,
        onPressed: _searchCtl.clear,
        icon: const Icon(Icons.cancel_outlined),
      );
    }
    InputDecoration searchDecoration(double iconSize) => InputDecoration(
          isDense: true,
          hintText: '搜索名称 / 双人 / 金手指 / 存档…',
          prefixIcon: Icon(Icons.search, size: iconSize),
          suffixIcon: clearButton,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 0),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pgmBanner != null) pgmBanner,
        if (banner != null) banner,
        if (landscape)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: SizedBox(
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 38,
                      child: TextField(
                        controller: _searchCtl,
                        decoration: searchDecoration(19),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${visible.length}/${_entries.length}',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(width: 4),
                  if (genres.isNotEmpty)
                    SizedBox(
                      width: 104,
                      height: 38,
                      child: _FilterDropdown(
                        icon: Icons.category_outlined,
                        value: _genreFilter,
                        hint: '类型',
                        items: genres,
                        compact: true,
                        onChanged: (v) => setState(() => _genreFilter = v),
                      ),
                    ),
                  if (categories.isNotEmpty)
                    SizedBox(
                      width: 104,
                      height: 38,
                      child: _FilterDropdown(
                        icon: Icons.folder_outlined,
                        value: _categoryFilter,
                        hint: '分类',
                        items: categories,
                        compact: true,
                        onChanged: (v) => setState(() => _categoryFilter = v),
                      ),
                    ),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: _SortMenu(
                      value: _sortBy,
                      compact: true,
                      onChanged: (v) => setState(() => _sortBy = v),
                    ),
                  ),
                ],
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 40,
                    child: TextField(
                      controller: _searchCtl,
                      decoration: searchDecoration(20),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                _SortMenu(
                  value: _sortBy,
                  onChanged: (v) => setState(() => _sortBy = v),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Text('共 ${visible.length}/${_entries.length} 个游戏',
                    style: Theme.of(context).textTheme.bodySmall),
                const Spacer(),
                if (genres.isNotEmpty)
                  _FilterDropdown(
                    icon: Icons.category_outlined,
                    value: _genreFilter,
                    hint: '类型',
                    items: genres,
                    onChanged: (v) => setState(() => _genreFilter = v),
                  ),
                const SizedBox(width: 8),
                if (categories.isNotEmpty)
                  _FilterDropdown(
                    icon: Icons.folder_outlined,
                    value: _categoryFilter,
                    hint: '分类',
                    items: categories,
                    onChanged: (v) => setState(() => _categoryFilter = v),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
        ],
        _PlatformChipBar(
          platforms: _presentPlatforms,
          counts: {
            for (final p in _presentPlatforms)
              p: _entries.where((e) => e.platform == p).length,
          },
          selected: _platformFilter,
          onChanged: (p) => setState(() => _platformFilter = p),
        ),
        if (_query.trim().isEmpty &&
            _genreFilter == null &&
            _categoryFilter == null &&
            _platformFilter == null &&
            _continueEntry != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: _ContinueCard(
              entry: _continueEntry!,
              filesDir: _filesDir,
              onTap: () => _launch(_continueEntry!),
            ),
          ),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('没有符合筛选条件的游戏'))
              : Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
                  child: CustomScrollView(
                    slivers: _buildSlivers(visible, landscape),
                  ),
                ),
        ),
      ],
    );
  }

  /// First-screen banner shown when one or more arcade BIOS blobs are missing
  /// from `<filesDir>/system` (e.g. `neogeo.zip`). Lists the missing files and
  /// offers a one-tap import so the user isn't surprised by a core error later.
  Widget? _biosBanner() {
    final missing = _missingBios;
    if (missing == null || _entries.isEmpty) return null;
    // pgm.zip gets its own dedicated banner (see [_pgmBanner]) — don't list it
    // twice here.
    final files = missing.where((f) => f != 'pgm.zip').toList()..sort();
    if (files.isEmpty) return null;
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  color: theme.colorScheme.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('缺少系统文件（BIOS）',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onErrorContainer,
                    )),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '部分街机 / NeoGeo 游戏需要对应的 BIOS 文件才能运行。'
            '本应用不内置受版权保护的 BIOS，请导入你合法拥有的备份'
            '（例如 neogeo.zip）。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onErrorContainer),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final f in files)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onErrorContainer
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(f,
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 12.5)),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: _importBios,
              icon: const Icon(Icons.file_upload_outlined, size: 18),
              label: const Text('导入 BIOS 文件'),
            ),
          ),
        ],
      ),
    );
  }

  /// Dedicated banner for the IGS PolyGame Master (PGM) BIOS. PGM titles run on
  /// the libretro MAME core and fail at boot without `pgm.zip`, so they get a
  /// clearer, separate callout from the generic missing-BIOS banner. Shown only
  /// when `pgm.zip` is absent and the library contains at least one MAME game.
  Widget? _pgmBanner() {
    final missing = _missingBios;
    if (missing == null ||
        missing.isEmpty ||
        _entries.isEmpty ||
        !missing.contains('pgm.zip')) {
      return null;
    }
    if (!_entries.any((e) => e.platform?.coreId == 'mame')) return null;
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.colorScheme.error.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.memory_outlined,
                  color: theme.colorScheme.error, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text('PGM 游戏缺少系统 BIOS（pgm.zip）',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: theme.colorScheme.onErrorContainer,
                    )),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'IGS PolyGame Master（PGM）街机游戏（knights、oriental、kov 等）'
            '需要 pgm.zip 基板 BIOS 才能启动。本应用不内置受版权保护的 BIOS，'
            '请导入你合法拥有的备份（设置 → 系统文件（BIOS））。',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onErrorContainer),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: _importBios,
              icon: const Icon(Icons.file_upload_outlined, size: 18),
              label: const Text('导入 pgm.zip'),
            ),
          ),
        ],
      ),
    );
  }

  /// Friendly first screen shown when the library has no games yet: explains
  /// that the app ships no ROM/BIOS and provides direct import entry points.
  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 72, color: theme.hintColor),
            const SizedBox(height: 16),
            Text('游戏库为空',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Text(
              '点击下方按钮导入游戏即可开始游玩。\n'
              '本应用不内置任何游戏 ROM 与受版权保护的 BIOS 文件，'
              '请导入你合法拥有的游戏与系统文件备份。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _library == null ? null : () => _import(),
                  icon: const Icon(Icons.file_open_outlined),
                  label: const Text('导入 ROM（单文件）'),
                ),
                OutlinedButton.icon(
                  onPressed: _library == null ? null : () => _importPackage(),
                  icon: const Icon(Icons.archive_outlined),
                  label: const Text('导入资源包 / ZIP'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('也可在 PC 端游戏库管理器一键同步游戏到手机',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.hintColor)),
          ],
        ),
      ),
    );
  }

  /// Whether the list is shown flat (search / genre / category filter
  /// active) instead of grouped by platform.
  bool get _flatView =>
      _query.trim().isNotEmpty ||
      _genreFilter != null ||
      _categoryFilter != null ||
      _platformFilter != null;

  List<Widget> _buildSlivers(List<RomEntry> visible, bool landscape) {
    Widget header(PlatformKind p, int count) => Padding(
          padding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
          child: Row(
            children: [
              Icon(platformIcon(p), size: 17),
              const SizedBox(width: 6),
              Text(p.label,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w800)),
              const SizedBox(width: 8),
              Text('$count',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: Colors.white54)),
              const Expanded(child: Divider(indent: 10, height: 1)),
            ],
          ),
        );

    SliverGrid grid(List<RomEntry> items) => SliverGrid(
          gridDelegate:
              const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 168,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.66,
          ),
          delegate: SliverChildBuilderDelegate(
            (ctx, i) => _GameCard(
              entry: items[i],
              filesDir: _filesDir,
              onTap: () => _openDetail(items[i]),
              selected: _selected.contains(items[i].relativePath),
              onToggle: _selecting ? () => _toggleSelect(items[i]) : null,
            ),
            childCount: items.length,
          ),
        );

    SliverList rows(List<RomEntry> items) => SliverList(
          delegate: SliverChildBuilderDelegate(
            (ctx, i) {
              if (i.isOdd) return const SizedBox(height: 8);
              final e = items[i ~/ 2];
              return _GameRow(
                entry: e,
                filesDir: _filesDir,
                onTap: () => _openDetail(e),
                selected: _selected.contains(e.relativePath),
                onToggle: _selecting ? () => _toggleSelect(e) : null,
              );
            },
            childCount: items.length * 2 - 1,
          ),
        );

    if (_flatView) {
      return [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('共 ${visible.length} 个游戏',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
        landscape ? rows(visible) : grid(visible),
      ];
    }

    final groups = <PlatformKind, List<RomEntry>>{};
    for (final e in visible) {
      groups.putIfAbsent(e.platform, () => []).add(e);
    }
    final ordered = _presentPlatforms.where(groups.containsKey).toList();
    return [
      for (final p in ordered) ...[
        SliverToBoxAdapter(child: header(p, groups[p]!.length)),
        landscape ? rows(groups[p]!) : grid(groups[p]!),
      ],
    ];
  }

  Future<void> _openDetail(RomEntry e) async {
    final landscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (landscape) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: _DetailContent(
              entry: e,
              filesDir: _filesDir,
              showClose: true,
              onLaunch: () {
                Navigator.pop(ctx);
                _launch(e);
              },
              onDelete: () async {
                Navigator.pop(ctx);
                await _confirmDelete(e);
              },
            ),
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _DetailContent(
        entry: e,
        filesDir: _filesDir,
        onLaunch: () {
          Navigator.pop(ctx);
          _launch(e);
        },
        onDelete: () async {
          Navigator.pop(ctx);
          await _confirmDelete(e);
        },
      ),
    );
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)}MB';
  }
}

// ----------------------------------------------------------------- widgets

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.value, required this.onChanged, this.compact = false});
  final _SortBy value;
  final ValueChanged<_SortBy> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_SortBy>(
      tooltip: '排序',
      initialValue: value,
      onSelected: onChanged,
      padding: EdgeInsets.all(compact ? 0 : 8),
      icon: Icon(Icons.sort, size: compact ? 20 : null),
      itemBuilder: (ctx) => const [
        PopupMenuItem(value: _SortBy.title, child: Text('按名称排序')),
        PopupMenuItem(value: _SortBy.releaseDate, child: Text('按发行日期排序')),
        PopupMenuItem(value: _SortBy.size, child: Text('按文件大小排序')),
        PopupMenuItem(value: _SortBy.recent, child: Text('按最近游玩排序')),
      ],
    );
  }
}

IconData platformIcon(PlatformKind p) => switch (p) {
      PlatformKind.nes => Icons.sports_esports_outlined,
      PlatformKind.gameBoy => Icons.smart_toy_outlined,
      PlatformKind.gba => Icons.gamepad_outlined,
      PlatformKind.masterSystem || PlatformKind.genesis => Icons.sports_esports,
      PlatformKind.atari2600 => Icons.radio_button_checked_outlined,
      PlatformKind.ps1 => Icons.casino_outlined,
      PlatformKind.psp => Icons.videogame_asset_outlined,
      PlatformKind.n64 => Icons.adjust_outlined,
      PlatformKind.nds => Icons.menu_book_outlined,
      PlatformKind.neogeo || PlatformKind.mame => Icons.memory_outlined,
      _ => Icons.help_outline,
    };

/// Horizontally scrollable platform selector (全部 + each present platform).
class _PlatformChipBar extends StatelessWidget {
  const _PlatformChipBar({
    required this.platforms,
    required this.counts,
    required this.selected,
    required this.onChanged,
  });

  final List<PlatformKind> platforms;
  final Map<PlatformKind, int> counts;
  final PlatformKind? selected;
  final ValueChanged<PlatformKind?> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('全部平台'),
              selected: selected == null,
              onSelected: (_) => onChanged(null),
              visualDensity: VisualDensity.compact,
            ),
          ),
          for (final p in platforms)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                avatar: Icon(platformIcon(p), size: 16),
                label: Text('${p.label} ${counts[p] ?? 0}'),
                selected: selected == p,
                onSelected: (_) => onChanged(p),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.icon,
    required this.value,
    required this.hint,
    required this.items,
    required this.onChanged,
    this.compact = false,
  });
  final IconData icon;
  final String? value;
  final String hint;
  final List<String> items;
  final ValueChanged<String?> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final style = compact
        ? Theme.of(context).textTheme.labelLarge
        : null;
    Widget label(String text) => compact
        ? FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(text, style: style),
          )
        : Text(text);
    return DropdownButton<String?>(
      value: value,
      underline: const SizedBox.shrink(),
      isDense: true,
      iconSize: compact ? 16 : 24,
      icon: Icon(icon, size: compact ? 16 : 18),
      hint: compact
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(hint,
                  style: Theme.of(context).textTheme.labelLarge),
            )
          : Text(hint, style: Theme.of(context).textTheme.bodySmall),
      items: [
        DropdownMenuItem<String?>(
            value: null, child: label(compact ? '全部' : '全部$hint')),
        ...items.map((v) => DropdownMenuItem<String?>(value: v, child: label(v))),
      ],
      onChanged: onChanged,
    );
  }
}

/// Deterministic colour from the title, matching the PC page placeholder.
HSLColor _titleHsl(String title) {
  var h = 0;
  for (final c in title.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  final hue = (h % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.45, 0.32);
}

class _CoverArt extends StatelessWidget {
  const _CoverArt({required this.entry, required this.filesDir});
  final RomEntry entry;
  final String? filesDir;

  @override
  Widget build(BuildContext context) {
    final rel = entry.coverRelative;
    if (filesDir != null && rel != null) {
      final f = File('$filesDir/$rel');
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.file(
          f,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (context, error, stack) => _placeholder(),
        ),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    final ch = entry.displayTitle.trim().isEmpty
        ? '?'
        : entry.displayTitle.trim().substring(0, 1);
    final hue = _titleHsl(entry.displayTitle);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            hue.toColor(),
            hue.withLightness(0.18).toColor(),
          ],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        ch.toUpperCase(),
        style: const TextStyle(
          color: Colors.white, fontSize: 44, fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _GameCard extends StatelessWidget {
  const _GameCard({
    required this.entry,
    required this.filesDir,
    required this.onTap,
    this.selected = false,
    this.onToggle,
  });
  final RomEntry entry;
  final String? filesDir;
  final VoidCallback onTap;
  final bool selected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onToggle ?? onTap,
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.all(7),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SizedBox(
                      width: double.infinity,
                      child: _CoverArt(entry: entry, filesDir: filesDir),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    entry.displayTitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      entry.releaseDate ?? '',
                      _LibraryPageState.formatSize(entry.size),
                    ].where((s) => s.isNotEmpty).join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.hintColor),
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 4,
                    runSpacing: 2,
                    children: [
                      if (entry.genre != null)
                        _MiniChip(label: entry.genre!),
                      _MiniChip(label: entry.platform.label),
                      if (entry.category != null)
                        _MiniChip(label: entry.category!),
                    ],
                  ),
                ],
              ),
            ),
            if (selected)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.check,
                      size: 16, color: theme.colorScheme.onPrimary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelSmall),
    );
  }
}

/// Read-only cheat summary on the detail sheet; management happens in the
/// emulator menu and the PC library manager.
class _CheatSection extends StatelessWidget {
  const _CheatSection({required this.cheats});
  final List<CheatInfo> cheats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (cheats.isEmpty) return const SizedBox.shrink();
    final active = cheats.where((c) => c.isActive).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 14),
        Row(children: [
          Icon(Icons.vpn_key_outlined, size: 16, color: theme.hintColor),
          const SizedBox(width: 6),
          Text('金手指命令（$active/${cheats.length} 生效）',
              style: theme.textTheme.titleSmall),
        ]),
        const SizedBox(height: 6),
        ...cheats.map((c) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    c.isActive
                        ? Icons.toggle_on_outlined
                        : Icons.toggle_off_outlined,
                    size: 18,
                    color: c.isActive
                        ? theme.colorScheme.primary
                        : theme.hintColor,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(c.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall),
                  ),
                  const SizedBox(width: 8),
                  Text(c.statusLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: c.isActive
                            ? theme.colorScheme.primary
                            : theme.hintColor,
                      )),
                ],
              ),
            )),
        Text('游戏中可在菜单「金手指」直接开关/选择；命令在 PC 端配置',
            style:
                theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
      ],
    );
  }
}

/// Pinned "continue last game" banner shown at the top of the library.
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.entry,
    required this.filesDir,
    required this.onTap,
  });
  final RomEntry entry;
  final String? filesDir;
  final VoidCallback onTap;

  String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = entry.lastPlayedAt;
    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      color: theme.colorScheme.primaryContainer,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: _CoverArt(entry: entry, filesDir: filesDir),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Row(children: [
                      Icon(Icons.history,
                          size: 14, color: theme.colorScheme.primary),
                      const SizedBox(width: 4),
                      Text('继续游戏',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          )),
                    ]),
                    const SizedBox(height: 2),
                    Text(entry.displayTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    if (last != null)
                      Text('上次游玩 ${_formatTime(last)} · 进入即恢复进度',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onPrimaryContainer
                                  .withValues(alpha: 0.75))),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                radius: 22,
                backgroundColor: theme.colorScheme.primary,
                child: Icon(Icons.play_arrow,
                    color: theme.colorScheme.onPrimary, size: 26),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact horizontal card used in landscape (short viewport height).
class _GameRow extends StatelessWidget {
  const _GameRow({
    required this.entry,
    required this.filesDir,
    required this.onTap,
    this.selected = false,
    this.onToggle,
  });
  final RomEntry entry;
  final String? filesDir;
  final VoidCallback onTap;
  final bool selected;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 88,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        child: InkWell(
          onTap: onToggle ?? onTap,
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 76,
                      height: 76,
                      child: _CoverArt(entry: entry, filesDir: filesDir),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            entry.displayTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            [
                              entry.releaseDate ?? '',
                              _LibraryPageState.formatSize(entry.size),
                            ].where((s) => s.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.hintColor),
                          ),
                          const SizedBox(height: 5),
                          Wrap(
                            spacing: 6,
                            runSpacing: 2,
                            children: [
                              if (entry.genre != null)
                                _MiniChip(label: entry.genre!),
                              _MiniChip(label: entry.platform.label),
                              if (entry.category != null)
                                _MiniChip(label: entry.category!),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.white38),
                  ],
                ),
              ),
              if (selected)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.check,
                        size: 16, color: theme.colorScheme.onPrimary),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailContent extends StatelessWidget {
  const _DetailContent({
    required this.entry,
    required this.filesDir,
    required this.onLaunch,
    required this.onDelete,
    this.showClose = false,
  });
  final RomEntry entry;
  final String? filesDir;
  final VoidCallback onLaunch;
  final VoidCallback onDelete;

  /// true inside the landscape dialog (shows an explicit close button and
  /// uses a smaller cover).
  final bool showClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mq = MediaQuery.of(context);
    final coverSize = showClose ? 92.0 : 132.0;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: mq.size.height * 0.88),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: showClose ? 10 : 4,
            bottom: mq.viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showClose)
                Align(
                  alignment: Alignment.centerRight,
                  child: IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.close),
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: coverSize,
                    height: coverSize,
                    child: _CoverArt(entry: entry, filesDir: filesDir),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(entry.displayTitle,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (entry.genre != null) _MiniChip(label: entry.genre!),
                            _MiniChip(label: entry.platform.label),
                  if (entry.category != null)
                    _MiniChip(label: entry.category!),
                            if (entry.region != null) _MiniChip(label: entry.region!),
                            if (entry.players != null)
                              _MiniChip(label: '${entry.players} 人'),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          [
                            entry.releaseDate ?? '',
                            entry.publisher ?? entry.developer ?? '',
                          ].where((s) => s.isNotEmpty).join(' · '),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.hintColor),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _kv('平台', entry.platform.label),
              _kv('开发商', entry.developer),
              _kv('发行商', entry.publisher),
              _kv('发行日期', entry.releaseDate),
              _kv('游戏人数', entry.players == null ? null : '${entry.players} 人'),
              _kv('文件大小', _LibraryPageState.formatSize(entry.size)),
              _kv(
                'CRC32',
                entry.crcKey,
                mono: true,
              ),
              if (entry.lastPlayedAt != null)
                _kv('最近游玩',
                    '${entry.lastPlayedAt!.year}-${entry.lastPlayedAt!.month.toString().padLeft(2, '0')}-${entry.lastPlayedAt!.day.toString().padLeft(2, '0')}'),
              if (entry.description != null) ...[
                const SizedBox(height: 10),
                Text(entry.description!, style: theme.textTheme.bodyMedium),
              ],
              _CheatSection(cheats: entry.cheats),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onLaunch,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('开始游戏'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.outlined(
                    tooltip: '删除',
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kv(String k, String? v, {bool mono = false}) {
    if (v == null || v.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Builder(builder: (context) {
              return Text(k,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Theme.of(context).hintColor));
            }),
          ),
          Expanded(
            child: Text(v,
                style: mono
                    ? const TextStyle(fontFamily: 'monospace', fontSize: 12.5)
                    : null),
          ),
        ],
      ),
    );
  }
}
