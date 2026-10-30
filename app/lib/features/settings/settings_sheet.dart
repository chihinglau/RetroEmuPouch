import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gamepouch/features/legal/legal_constants.dart';

import '../../main.dart';
import '../../features/legal/privacy_policy_page.dart';
import '../../pal/platform_pal.dart';
import '../../system_files.dart';
import 'app_settings.dart';
import 'special_moves_editor.dart';

/// Modal bottom sheet that combines the app's "About" content (name +
/// version + open-source licence info) and runtime configuration options
/// (FPS overlay, refresh rate, etc.) into a single place reachable from
/// the library AppBar.
///
/// Configurable settings are loaded on open and saved on every toggle
/// change, so closing the sheet (or the app) never loses work.
class SettingsSheet extends StatefulWidget {
  const SettingsSheet({super.key, required this.hostCtx, required this.pal});

  static Future<void> show(BuildContext context, {required PlatformPal pal}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => SettingsSheet(hostCtx: context, pal: pal),
    );
  }

  /// Outer context (the page that opened the sheet) — needed so we can
  /// reach the parent [GamePouchApp] for live theme updates without
  /// requiring the settings sheet itself to rebuild the whole app.
  final BuildContext hostCtx;

  /// Used to read the real installed version for the App-info card.
  final PlatformPal pal;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  late AppSettings _settings;
  late final BuildContext _ctx;
  AppVersion? _version;

  @override
  void initState() {
    super.initState();
    _ctx = widget.hostCtx;
    _settings = AppSettings.current;
    widget.pal.appVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
  }

  void _patch(void Function(AppSettings s) mutator) {
    final before = _settings.clone();
    setState(() => mutator(_settings));
    // Fire-and-forget — saves are tiny and SharedPreferences handles
    // concurrent writes internally.
    _settings.save();
    // Side effects that need to happen synchronously alongside the
    // toggle so the change is visible without an app restart.
    _applySideEffects(before, _settings);
  }

  /// Reflect a setting change in the running app without restarting.
  ///
  ///  - Toggling `rememberLastGame` off clears the `lastSaveSlot`
  ///    pointer so the next emulator entry won't auto-load.
  ///  - Toggling `darkTheme` flips the app theme live via the
  /// [GamePouchApp]'s shared key.
  Future<void> _applySideEffects(
      AppSettings before, AppSettings after) async {
    // Resolve the app state *before* awaiting: touching a BuildContext across
    // an async gap is unsafe (the widget may have been disposed).
    final app = GamePouchApp.of(_ctx);
    if (before.rememberLastGame && !after.rememberLastGame) {
      await AppSettings.clearLastSaveSlot();
    }
    if (before.darkTheme != after.darkTheme) {
      app?.setBrightness(after.darkTheme);
    }
  }

  Future<void> _showLicenses() async {
    final text = await rootBundle.loadString('assets/OSS_LICENSES.md');
    if (!mounted || !context.mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('开源许可'),
        scrollable: true,
        content: SelectableText(
          text,
          style: Theme.of(ctx)
              .textTheme
              .bodySmall
              ?.copyWith(fontFamily: 'monospace'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 16),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
                child: Text(
                  '设置',
                  style: theme.textTheme.titleLarge,
                ),
              ),

              // ----- App info (the former About content) -----
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.videogame_asset_outlined,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Text('趣玩匣 RetroEmuPouch',
                              style: theme.textTheme.titleMedium),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _version == null
                                  ? '加载中…'
                                  : '${_version!.versionName} (${_version!.versionCode})',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onPrimaryContainer,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '本应用不内置任何游戏 ROM 或 BIOS，请自行导入合法备份。',
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '模拟核心：FCEUmm / Gambatte / mGBA / PicoDrive / '
                        'Stella（libretro），GPL-2.0 / MPL-2.0；完整源码与'
                        '构建脚本随项目仓库提供。',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),
              Text('游戏体验',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 4),

              _SettingTile(
                icon: Icons.speed_outlined,
                title: '显示 FPS / xruns 浮窗',
                subtitle: '在游戏画面正中央叠加性能指示器',
                value: _settings.showFpsHud,
                onChanged: (v) => _patch((s) => s.showFpsHud = v),
              ),
              _SettingTile(
                icon: Icons.refresh_outlined,
                title: '高刷新率（120 Hz）',
                subtitle: '支持时优先使用最高刷新率以降低拖影',
                value: _settings.highRefreshRate,
                onChanged: (v) => _patch((s) => s.highRefreshRate = v),
              ),
              _SettingTile(
                icon: Icons.fast_forward_outlined,
                title: '加速时同步音频',
                subtitle: '关闭后加速时静音，换取更稳定的帧率',
                value: _settings.fastForwardAudio,
                onChanged: (v) => _patch((s) => s.fastForwardAudio = v),
              ),

              const SizedBox(height: 16),
              Text('控制',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 4),

              _StickSettingsCard(
                mode: _settings.stickMode,
                deadzone: _settings.stickDeadzone,
                useDpadUi: _settings.useDpadUi,
                onModeChanged: (m) => _patch((s) => s.stickMode = m),
                onDeadzoneChanged: (d) => _patch((s) => s.stickDeadzone = d),
                onUseDpadUiChanged: (v) => _patch((s) => s.useDpadUi = v),
              ),

              const SizedBox(height: 4),
              _PadLayoutCard(
                settings: _settings,
                pal: widget.pal,
                patch: _patch,
              ),

              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.bolt_outlined),
                  title: const Text('招式按键（格斗游戏一键大招）'),
                  subtitle: const Text(
                      '配置 6 个槽位的招式脚本，支持导入 / 导出，方便按游戏加载'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final filesDir = await widget.pal.filesDir();
                    if (!widget.hostCtx.mounted) return;
                    // Push via the host context so the editor lands on the
                    // underlying navigator (the settings sheet's own context
                    // pops with the sheet and would discard the route).
                    Navigator.of(widget.hostCtx).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SpecialMovesEditorPage(
                          filesDir: filesDir,
                          pal: widget.pal,
                        ),
                      ),
                    );
                  },
                ),
              ),

              const SizedBox(height: 16),
              Text('系统文件（BIOS）',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 4),
              _BiosManagerCard(pal: widget.pal),

              const SizedBox(height: 16),
              Text('应用',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: theme.colorScheme.primary)),
              const SizedBox(height: 4),

              _SettingTile(
                icon: Icons.history_outlined,
                title: '记住上次游戏',
                subtitle: '启动时自动恢复上次运行的游戏进度',
                value: _settings.rememberLastGame,
                onChanged: (v) => _patch((s) => s.rememberLastGame = v),
              ),
              _SettingTile(
                icon: Icons.dark_mode_outlined,
                title: '深色主题',
                subtitle: '深色 Material 配色，省电且夜间友好',
                value: _settings.darkTheme,
                onChanged: (v) => _patch((s) => s.darkTheme = v),
              ),
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('开源许可'),
                  subtitle: const Text('内嵌模拟器核心的许可证与源码出处'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showLicenses,
                ),
              ),
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('隐私政策 / 用户协议'),
                  subtitle: const Text('我们如何收集、使用与保护您的数据'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const PrivacyPolicyPage()),
                  ),
                ),
              ),
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.language_outlined),
                  title: const Text('网页版隐私政策'),
                  subtitle: const Text(
                      'https://chihinglau.github.io/GamePouch/privacy'),
                  trailing: const Icon(Icons.copy_outlined),
                  onTap: () async {
                    await Clipboard.setData(
                      ClipboardData(text: LegalConstants.privacyPolicyUrl),
                    );
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                          content: Text('已复制隐私政策链接，可在浏览器打开')),
                    );
                  },
                ),
              ),
              Card(
                margin: const EdgeInsets.symmetric(vertical: 4),
                child: ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text('备案号'),
                  subtitle: Text(
                    LegalConstants.filingNumber.isEmpty
                        ? '（备案中，待工信部备案后回填）'
                        : LegalConstants.filingNumber,
                  ),
                ),
              ),

              const SizedBox(height: 12),
              Center(
                child: Text(
                  '趣玩匣 RetroEmuPouch · 让历史更安心',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.hintColor),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: SwitchListTile(
        secondary: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        value: value,
        onChanged: onChanged,
      ),
    );
  }
}

/// BIOS / system-file manager. Lists every BIOS the app knows about
/// (neogeo.zip / qsound.zip / …), shows installed vs missing, and lets the
/// user batch-import via SAF, export the lot as a single zip, or delete
/// an individual blob. The list reflects the on-disk state under
/// `<filesDir>/system/` plus the per-core subdir `system/mame/roms/`.
class _BiosManagerCard extends StatefulWidget {
  const _BiosManagerCard({required this.pal});
  final PlatformPal pal;

  @override
  State<_BiosManagerCard> createState() => _BiosManagerCardState();
}

class _BiosManagerCardState extends State<_BiosManagerCard> {
  /// All supported BIOS names (see `SystemFiles.supportedBios`). Mirrors the
  /// app-side registry so the list stays in lockstep with import validation,
  /// the peer `bios` API and the on-launch mirror step.
  List<String> get _knownBios =>
      List<String>.from(SystemFiles.biosNames())..sort();

  /// Names actually present under `<filesDir>/system/`. Reads the disk
  /// directly (no platform channel round-trip) — this UI opens on the
  /// settings sheet which already needs the file system to be available.
  Set<String> _present = <String>{};
  bool _busy = false;
  String? _msg;
  bool _msgIsError = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final sysPath = '${await widget.pal.filesDir()}/system';
    final present = <String>{};
    // Two source dirs are authoritative for "is this BIOS installed":
    //  1. `<filesDir>/system/` — where importBios writes the user-picked
    //     blobs. This is also the "Other" list (root-level files only).
    //  2. `<filesDir>/system/mame/roms/` — the per-core MAME subdir the
    //     `LockedRom` mirror step stages BIOS into on every launch.
    // The per-core subdir may also hold game ROMs the user pushed there
    // manually (it isn't a sanctioned "BIOS" location), so we only credit
    // it for the names in `SystemFiles.requiredBios` — never surface a
    // stray `1944.zip` as "other installed BIOS".
    final root = Directory(sysPath);
    if (root.existsSync()) {
      for (final f in root.listSync()) {
        if (f is File) present.add(f.uri.pathSegments.last.toLowerCase());
      }
    }
    final knownLower = _knownBios.map((n) => n.toLowerCase()).toSet();
    final mame = Directory('$sysPath/mame/roms');
    if (mame.existsSync()) {
      for (final f in mame.listSync()) {
        if (f is! File) continue;
        final name = f.uri.pathSegments.last.toLowerCase();
        if (knownLower.contains(name)) present.add(name);
      }
    }
    if (!mounted) return;
    setState(() => _present = present);
  }

  void _setMsg(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _msg = text;
      _msgIsError = error;
    });
  }

  Future<void> _importBatch() async {
    setState(() => _busy = true);
    try {
      final names = await widget.pal.importBiosBatchViaSaf();
      // Mirror every newly imported blob into each per-core location.
      await SystemFiles.syncAll(widget.pal);
      await _refresh();
      if (names.isEmpty) {
        _setMsg('已取消');
      } else {
        _setMsg('已导入 ${names.length} 个文件：${names.join(', ')}');
      }
    } catch (e) {
      _setMsg('导入失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportAll() async {
    setState(() => _busy = true);
    try {
      final ok = await widget.pal.exportBiosZipViaSaf();
      _setMsg(ok == true ? '已导出' : '已取消');
    } catch (e) {
      _setMsg('导出失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteOne(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除 $name？'),
        content: const Text(
            '该 BIOS 将从本机移除。再次游玩需要它的游戏前必须重新导入。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await widget.pal.deleteBios(name);
      await _refresh();
      _setMsg('已删除 $name');
    } catch (e) {
      _setMsg('删除失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = _knownBios;
    final present = _present;
    final installed = known.where((n) => present.contains(n.toLowerCase())).toList();
    final missing = known.where((n) => !present.contains(n.toLowerCase())).toList();
    // Files the user dropped in that aren't in the known list (e.g. a
    // stray region BIOS). They still live under <system>/ so we surface
    // them with a "其他" tag so the user can manage them.
    final knownLower = known.map((n) => n.toLowerCase()).toSet();
    final others = present.where((n) => !knownLower.contains(n)).toList()..sort();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.developer_board_outlined,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('系统文件（BIOS）管理',
                    style: theme.textTheme.titleMedium),
                const Spacer(),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '本应用不内置任何 BIOS。请从你的合法备份中导入；'
              'MAME 街机需要 neogeo.zip（NeoGeo）、qsound.zip / qsound_hle.zip'
              '（Capcom CPS-1/2 Q-Sound）、pgm.zip（IGS PGM）等 BIOS。',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            if (installed.isNotEmpty) ...[
              _BiosSectionHeader(
                icon: Icons.check_circle_outline,
                color: Colors.green,
                text: '已安装（${installed.length}）',
              ),
              for (final n in installed) _BiosRow(
                name: n,
                installed: true,
                onDelete: _busy ? null : () => _deleteOne(n),
              ),
              const SizedBox(height: 8),
            ],
            if (missing.isNotEmpty) ...[
              _BiosSectionHeader(
                icon: Icons.warning_amber_rounded,
                color: Colors.orange,
                text: '缺失（${missing.length}）',
              ),
              for (final n in missing)
                _BiosRow(name: n, installed: false, onDelete: null),
              const SizedBox(height: 8),
            ],
            if (others.isNotEmpty) ...[
              _BiosSectionHeader(
                icon: Icons.folder_outlined,
                color: theme.colorScheme.onSurfaceVariant,
                text: '其他（${others.length}）',
              ),
              for (final n in others) _BiosRow(
                name: n,
                installed: true,
                onDelete: _busy ? null : () => _deleteOne(n),
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _importBatch,
                    icon: const Icon(Icons.file_open),
                    label: const Text('批量导入'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _exportAll,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('导出全部'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            if (_msg != null) ...[
              const SizedBox(height: 10),
              Text(
                _msg!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _msgIsError
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _BiosSectionHeader extends StatelessWidget {
  const _BiosSectionHeader({
    required this.icon,
    required this.color,
    required this.text,
  });
  final IconData icon;
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 2),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Text(text,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _BiosRow extends StatelessWidget {
  const _BiosRow({
    required this.name,
    required this.installed,
    required this.onDelete,
  });
  final String name;
  final bool installed;
  final VoidCallback? onDelete;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            installed ? Icons.check : Icons.error_outline,
            size: 16,
            color: installed ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontFamily: 'monospace'),
            ),
          ),
          if (onDelete != null)
            IconButton(
              tooltip: '删除',
              onPressed: onDelete,
              icon: const Icon(Icons.delete_outline, size: 18),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }
}

/// Virtual stick / d-pad configuration card. Three controls:
/// - **Mode** (STICK / DPAD8 / DPAD4): how the analog stick resolves to
///   digital d-pad bits.
/// - **Dead-zone** slider (0.0–0.45): fraction of the knob's travel below
///   which the stick reads as centred.
/// - **虚拟十字键** switch: render a 4-button + centre d-pad in place of
///   the round stick. Best for action / platformer titles that don't
///   understand diagonal input.
class _StickSettingsCard extends StatelessWidget {
  const _StickSettingsCard({
    required this.mode,
    required this.deadzone,
    required this.useDpadUi,
    required this.onModeChanged,
    required this.onDeadzoneChanged,
    required this.onUseDpadUiChanged,
  });

  final String mode;
  final double deadzone;
  final bool useDpadUi;
  final ValueChanged<String> onModeChanged;
  final ValueChanged<double> onDeadzoneChanged;
  final ValueChanged<bool> onUseDpadUiChanged;

  String _modeLabel(String m) => switch (m) {
        'STICK' => '全向（适合 ACT / 平台）',
        'DPAD4' => '4 方向（适合平台跳跃）',
        _ => '8 方向（适合格斗）',
      };

  String _modeHint(String m) => switch (m) {
        'STICK' => '保留模拟量，死区最大，斜方向全部输出',
        'DPAD4' => '每个方向按键只出一个方位，斜方向吸附到最近',
        _ => '8 方向精准，斜方向可出（KOF97 推荐）',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.gamepad_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('摇杆 / 方向键', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            // Mode picker — three-way segmented button.
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'STICK', label: Text('全向')),
                ButtonSegment(value: 'DPAD8', label: Text('8 向')),
                ButtonSegment(value: 'DPAD4', label: Text('4 向')),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: (set) => onModeChanged(set.first),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                _modeHint(mode),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ),
            const SizedBox(height: 14),
            // Dead-zone slider.
            Row(
              children: [
                const Icon(Icons.adjust, size: 18),
                const SizedBox(width: 8),
                Text('死区', style: theme.textTheme.bodyMedium),
                const Spacer(),
                Text(
                  deadzone.toStringAsFixed(2),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            Slider(
              value: deadzone.clamp(0.0, 0.45),
              min: 0.0,
              max: 0.45,
              divisions: 45,
              label: deadzone.toStringAsFixed(2),
              onChanged: onDeadzoneChanged,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '小于此偏移视为回中（格斗建议 0.10–0.15，简单游戏 0.20–0.30）',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
              ),
            ),
            const SizedBox(height: 4),
            // D-pad UI toggle.
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.control_camera_outlined),
              title: const Text('使用虚拟十字键（替代摇杆）'),
              subtitle: const Text(
                  '隐藏摇杆，显示 4 个方向大按钮，适合 ACT / 平台跳跃'),
              value: useDpadUi,
              onChanged: onUseDpadUiChanged,
            ),
          ],
        ),
      ),
    );
  }
}

/// 虚拟手柄整体布局：在默认大小/位置基础上，整体缩放 + 整体平移（左右上下）。
/// 适配不同手机屏幕与握持习惯；支持导入/导出布局配置（JSON）。
class _PadLayoutCard extends StatefulWidget {
  const _PadLayoutCard({
    required this.settings,
    required this.pal,
    required this.patch,
  });

  final AppSettings settings;
  final PlatformPal pal;
  final void Function(void Function(AppSettings)) patch;

  @override
  State<_PadLayoutCard> createState() => _PadLayoutCardState();
}

class _PadLayoutCardState extends State<_PadLayoutCard> {
  bool _busy = false;
  String? _msg;
  bool _msgIsError = false;

  void _setMsg(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _msg = text;
      _msgIsError = error;
    });
  }

  Future<void> _reset() async {
    widget.patch((s) {
      s.padScale = 1.0;
      s.padOffsetX = 0.0;
      s.padOffsetY = 0.0;
    });
    _setMsg('已恢复默认布局');
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final r = await widget.pal.importPadConfigViaSaf();
      if (r == null) {
        _setMsg('已取消');
        return;
      }
      if (!r.ok) {
        _setMsg('文件不是有效的 JSON', error: true);
        return;
      }
      final json = jsonDecode(await File(r.path).readAsString()) as Map<String, dynamic>;
      final scale = (json['scale'] as num?)?.toDouble();
      final ox = (json['offsetX'] as num?)?.toDouble();
      final oy = (json['offsetY'] as num?)?.toDouble();
      if (scale == null && ox == null && oy == null) {
        _setMsg('缺少 scale / offsetX / offsetY 字段', error: true);
        return;
      }
      widget.patch((s) {
        if (scale != null) s.padScale = scale.clamp(0.5, 2.5);
        if (ox != null) s.padOffsetX = ox.clamp(-0.45, 0.45);
        if (oy != null) s.padOffsetY = oy.clamp(-0.45, 0.45);
      });
      _setMsg('已导入布局（缩放 ${scale ?? widget.settings.padScale}，'
          'X ${ox ?? 0} Y ${oy ?? 0}）');
    } catch (e) {
      _setMsg('导入失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final dir = await widget.pal.filesDir();
      final src =
          File('$dir/library/pad_layout_export.json');
      // OHOS/Android both keep `library/` around, but a fresh sandbox may not
      // have it yet — create it so the export never fails with ENOENT.
      await src.parent.create(recursive: true);
      await src.writeAsString(jsonEncode({
        'scale': widget.settings.padScale,
        'offsetX': widget.settings.padOffsetX,
        'offsetY': widget.settings.padOffsetY,
      }));
      final ok = await widget.pal.exportPadConfigViaSaf(
        sourcePath: src.path,
        suggestedName: 'gamepouch_pad_layout.json',
      );
      _setMsg(ok ? '已导出' : '已取消');
    } catch (e) {
      _setMsg('导出失败：$e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = widget.settings;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.tune_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('虚拟手柄布局', style: theme.textTheme.titleMedium),
                const Spacer(),
                TextButton(
                  onPressed: _busy ? null : _reset,
                  child: const Text('恢复默认'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('整体缩放', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Slider(
              value: s.padScale.clamp(0.5, 2.5),
              min: 0.5,
              max: 2.5,
              divisions: 40,
              label: s.padScale.toStringAsFixed(2),
              onChanged: (v) => widget.patch((x) => x.padScale = v),
            ),
            Text('以默认大小为基准，0.5–2.5 倍',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 10),
            Text('水平平移', style: TextStyle(fontWeight: FontWeight.w600)),
            Slider(
              value: s.padOffsetX.clamp(-0.45, 0.45),
              min: -0.45,
              max: 0.45,
              divisions: 90,
              label: s.padOffsetX.toStringAsFixed(2),
              onChanged: (v) => widget.patch((x) => x.padOffsetX = v),
            ),
            Text('负值向左、正值向右（相对屏幕宽度）',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 10),
            Text('垂直平移', style: TextStyle(fontWeight: FontWeight.w600)),
            Slider(
              value: s.padOffsetY.clamp(-0.45, 0.45),
              min: -0.45,
              max: 0.45,
              divisions: 90,
              label: s.padOffsetY.toStringAsFixed(2),
              onChanged: (v) => widget.patch((x) => x.padOffsetY = v),
            ),
            Text('负值向上、正值向下（相对屏幕高度）',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.file_open),
                    label: const Text('导入配置'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _export,
                    icon: const Icon(Icons.ios_share),
                    label: const Text('导出配置'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 10),
              const LinearProgressIndicator(),
            ],
            if (_msg != null) ...[
              const SizedBox(height: 10),
              Text(
                _msg!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _msgIsError
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}