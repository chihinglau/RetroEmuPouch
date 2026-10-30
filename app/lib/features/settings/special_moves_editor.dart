import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/play/special_moves.dart';
import '../../pal/platform_pal.dart';

/// Editor page for the user-configurable fight-assist palette (波 / 升 / 旋
/// / 超 …). Each preset is a `SpecialMoveProfile`; the editor mutates the
/// profile in memory and atomically writes `library/moves.json` on Save.
///
/// The page is reached from `SettingsSheet` via the "招式按键" tile. It
/// also doubles as the user-facing hook for SAF import / export so a
/// KOF97 / KOF98 / custom preset can be carried between phones (Sharing a
/// `.json` through 蓝牙 / 微信文件 / USB).
class SpecialMovesEditorPage extends StatefulWidget {
  const SpecialMovesEditorPage({
    super.key,
    required this.filesDir,
    required this.pal,
  });

  final String filesDir;
  final PlatformPal pal;

  @override
  State<SpecialMovesEditorPage> createState() => _SpecialMovesEditorPageState();
}

class _SpecialMovesEditorPageState extends State<SpecialMovesEditorPage> {
  late SpecialMovesConfig _config;
  late TextEditingController _newProfileLabel;
  bool _dirty = false;
  String? _errorMessage;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _config = SpecialMovesFile.tryLoad(widget.filesDir) ??
        SpecialMovesConfig.fromJsonString(assetsDefaultMovesJson);
    _newProfileLabel = TextEditingController();
  }

  @override
  void dispose() {
    _newProfileLabel.dispose();
    super.dispose();
  }

  SpecialMoveProfile get _activeProfile => _config.activeProfile();

  void _setError(String? msg) {
    if (_errorMessage != msg) setState(() => _errorMessage = msg);
  }

  // ---- preset / slot editing ----

  void _switchProfile(String id) {
    if (_config.profiles.containsKey(id)) {
      setState(() {
        _config = _config.copyWith(activeProfileId: id);
        _dirty = true;
      });
    }
  }

  void _renameProfile(String id, String newLabel) {
    final p = _config.profiles[id];
    if (p == null) return;
    setState(() {
      _config = _config.copyWith(
        profiles: {..._config.profiles, id: p.copyWith(label: newLabel)},
      );
      _dirty = true;
    });
  }

  void _addProfile() {
    final label = _newProfileLabel.text.trim();
    if (label.isEmpty) {
      _setError('新预设需要一个名称');
      return;
    }
    var id = 'p${DateTime.now().millisecondsSinceEpoch}';
    var newProfile = SpecialMoveProfile(
      id: id,
      label: label,
      gameHints: const [],
      moves: List.generate(6, (_) => SpecialMove(label: '?', script: '')),
    );
    setState(() {
      _config = _config.copyWith(
        profiles: {..._config.profiles, id: newProfile},
        activeProfileId: id,
      );
      _newProfileLabel.clear();
      _dirty = true;
      _setError(null);
    });
  }

  void _deleteActiveProfile() {
    if (_config.profiles.length <= 1) {
      _setError('至少需要保留一个预设');
      return;
    }
    final id = _config.activeProfileId;
    final next = {..._config.profiles}..remove(id);
    setState(() {
      _config = _config.copyWith(
        profiles: next,
        activeProfileId: next.keys.first,
      );
      _dirty = true;
    });
  }

  void _updateMove(int index, {String? label, String? script}) {
    final p = _activeProfile;
    final newMoves = [...p.moves];
    if (index < 0 || index >= newMoves.length) return;
    final old = newMoves[index];
    newMoves[index] = old.copyWith(label: label, script: script);
    setState(() {
      _config = _config.copyWith(
        profiles: {
          ..._config.profiles,
          p.id: p.copyWith(moves: newMoves),
        },
      );
      _dirty = true;
    });
  }

  // ---- save / import / export / reset ----

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      // Validate every script before persisting; refuse to save on any
      // error so the user can fix typos without losing their edits.
      for (final m in _activeProfile.moves) {
        final err = ScriptCompiler.validate(m.script);
        if (err != null) {
          _setError('「${m.label}」脚本无效：$err');
          // Surface the error prominently — the in-page red card lives
          // at the bottom and is easy to miss on tall phones, so we
          // also raise a SnackBar so the user knows the save was
          // rejected (and *why*) without scrolling.
          if (mounted) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text('保存失败：$err'),
                  backgroundColor: Theme.of(context).colorScheme.error,
                  duration: const Duration(seconds: 6),
                  action: SnackBarAction(
                    label: '好',
                    textColor: Theme.of(context).colorScheme.onError,
                    onPressed: () => ScaffoldMessenger.of(context)
                        .hideCurrentSnackBar(),
                  ),
                ),
              );
          }
          return;
        }
      }
      SpecialMovesFile.save(widget.filesDir, _config);
      setState(() {
        _dirty = false;
        _setError(null);
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: const Row(
                children: [
                  Icon(Icons.check_circle_outline,
                      color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('招式按键已保存'),
                ],
              ),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 6),
              action: SnackBarAction(
                label: '好的',
                textColor: Colors.white,
                onPressed: () =>
                    ScaffoldMessenger.of(context).hideCurrentSnackBar(),
              ),
            ),
          );
      }
    } catch (e) {
      _setError('保存失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('保存失败：$e'),
              backgroundColor: Theme.of(context).colorScheme.error,
              duration: const Duration(seconds: 6),
            ),
          );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _importFromSaf() async {
    try {
      final picked = await widget.pal.importMovesConfigViaSaf();
      if (picked == null) return; // user cancelled
      if (!picked.ok) {
        _setError('所选文件不是合法的招式配置 JSON');
        return;
      }
      final raw = await File(picked.path).readAsString();
      SpecialMovesConfig parsed;
      try {
        parsed = SpecialMovesConfig.fromJsonString(raw);
      } catch (e) {
        _setError('JSON 解析失败：$e');
        return;
      }
      // Merge: every profile id from the imported file overrides the local
      // one; the imported activeProfileId wins if it exists, otherwise the
      // current one is preserved. Profiles that the user never touched are
      // left intact, so importing a single preset doesn't wipe the rest.
      final mergedProfiles = {..._config.profiles, ...parsed.profiles};
      final mergedActive = mergedProfiles.containsKey(parsed.activeProfileId)
          ? parsed.activeProfileId
          : _config.activeProfileId;
      setState(() {
        _config = _config.copyWith(
          profiles: mergedProfiles,
          activeProfileId: mergedActive,
        );
        _dirty = true;
        _setError(null);
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('已导入「${parsed.activeProfile().label}」 — 请点保存'),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: '好',
                onPressed: () =>
                    ScaffoldMessenger.of(context).hideCurrentSnackBar(),
              ),
            ),
          );
      }
    } on PlatformException catch (e) {
      _setError('导入失败：${e.message ?? e.code}');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('导入失败：${e.message ?? e.code}'),
              backgroundColor: Theme.of(context).colorScheme.error,
              duration: const Duration(seconds: 6),
              action: SnackBarAction(
                label: '好',
                textColor: Theme.of(context).colorScheme.onError,
                onPressed: () =>
                    ScaffoldMessenger.of(context).hideCurrentSnackBar(),
              ),
            ),
          );
      }
    } catch (e) {
      _setError('导入失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('导入失败：$e'),
              backgroundColor: Theme.of(context).colorScheme.error,
              duration: const Duration(seconds: 6),
            ),
          );
      }
    }
  }

  Future<void> _exportToSaf() async {
    if (_dirty) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('尚未保存'),
          content: const Text('当前修改还没保存，先保存再导出吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存并导出'),
            ),
          ],
        ),
      );
      if (confirm != true) return;
      await _save();
    }
    try {
      // Materialise the live config to a stable temp path so the SAF
      // channel can stream it into the user-picked document without
      // racing against future saves.
      final cacheDir = Directory('${widget.filesDir}/library/exports')
        ..createSync(recursive: true);
      final cachePath =
          '${cacheDir.path}/moves-${DateTime.now().millisecondsSinceEpoch}.json';
      SpecialMovesFile.save(widget.filesDir, _config);
      await File('${widget.filesDir}/library/moves.json').copy(cachePath);
      final ok = await widget.pal.exportMovesConfigViaSaf(
        sourcePath: cachePath,
        suggestedName:
            'moves-${_activeProfile.id}.json',
      );
      if (!ok && mounted) {
        _setError('导出失败：用户取消或权限被拒');
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: const Text('导出失败：用户取消或权限被拒'),
              backgroundColor: Theme.of(context).colorScheme.error,
              duration: const Duration(seconds: 6),
            ),
          );
      } else if (ok && mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Row(
                children: const [
                  Icon(Icons.check_circle_outline,
                      color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text('已导出招式配置'),
                ],
              ),
              backgroundColor: Colors.green.shade700,
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: '好',
                textColor: Colors.white,
                onPressed: () =>
                    ScaffoldMessenger.of(context).hideCurrentSnackBar(),
              ),
            ),
          );
      }
    } catch (e) {
      _setError('导出失败：$e');
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text('导出失败：$e'),
              backgroundColor: Theme.of(context).colorScheme.error,
              duration: const Duration(seconds: 6),
            ),
          );
      }
    }
  }

  Future<void> _resetToDefault() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置为默认'),
        content: const Text('将覆盖当前所有自定义预设，恢复为内置的 KOF97/空白模板。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('重置')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() {
      _config =
          SpecialMovesConfig.fromJsonString(assetsDefaultMovesJson);
      _dirty = true;
      _setError(null);
    });
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = _activeProfile;
    return Scaffold(
      appBar: AppBar(
        title: const Text('招式按键'),
        actions: [
          IconButton(
            tooltip: '导入',
            icon: const Icon(Icons.file_download_outlined),
            onPressed: _importFromSaf,
          ),
          IconButton(
            tooltip: '导出',
            icon: const Icon(Icons.file_upload_outlined),
            onPressed: _exportToSaf,
          ),
          IconButton(
            tooltip: '恢复默认',
            icon: const Icon(Icons.restart_alt_outlined),
            onPressed: _resetToDefault,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.icon(
              onPressed: _saving || !_dirty ? null : _save,
              icon: const Icon(Icons.save_outlined),
              label: Text(_dirty ? '保存' : '已保存'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            // ----- active profile picker + add -----
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.bookmark_outline,
                            color: theme.colorScheme.primary),
                        const SizedBox(width: 8),
                        Text('当前预设', style: theme.textTheme.titleMedium),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      initialValue: _config.activeProfileId,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: _config.profiles.values
                          .map((p) => DropdownMenuItem(
                                value: p.id,
                                child: Text('${p.label}  (${p.moves.length} 个按键)'),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) _switchProfile(v);
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _newProfileLabel,
                            decoration: const InputDecoration(
                              labelText: '新增预设名称',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: (_) => _addProfile(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton.tonalIcon(
                          icon: const Icon(Icons.add),
                          label: const Text('添加'),
                          onPressed: _addProfile,
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    TextButton.icon(
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('删除当前预设'),
                      onPressed: _deleteActiveProfile,
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ----- profile label editor -----
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('预设名称', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    TextFormField(
                      initialValue: active.label,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (v) => _renameProfile(active.id, v),
                    ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ----- per-slot editors -----
            Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('招式槽（6 个）', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      '脚本语法：方向用数字 1-9，按键用 P/H/L/K（轻拳/重拳/轻踢/重踢），'
                      '数字串是紧凑指令（如 236 = ↓↘→），多个按键用 + 连接（如 236+P）。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.hintColor,
                      ),
                    ),
                    const SizedBox(height: 10),
                    // Visual 3×3 numpad so the user can map directions
                    // without re-reading the small-print above. Each cell
                    // shows the digit on top and the matching arrow
                    // underneath; 5 is the neutral / no-direction frame.
                    const _DirectionKeyMap(),
                    const SizedBox(height: 10),
                    // Per-slot editors (label + script).
                    for (var i = 0; i < active.moves.length; i++)
                      _SlotEditor(
                        index: i,
                        move: active.moves[i],
                        onLabel: (s) => _updateMove(i, label: s),
                        onScript: (s) => _updateMove(i, script: s),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ----- error surface -----
            if (_errorMessage != null)
              Card(
                color: theme.colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline,
                          color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_errorMessage!,
                            style: TextStyle(
                                color: theme.colorScheme.onErrorContainer)),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SlotEditor extends StatefulWidget {
  const _SlotEditor({
    required this.index,
    required this.move,
    required this.onLabel,
    required this.onScript,
  });

  final int index;
  final SpecialMove move;
  final ValueChanged<String> onLabel;
  final ValueChanged<String> onScript;

  @override
  State<_SlotEditor> createState() => _SlotEditorState();
}

class _SlotEditorState extends State<_SlotEditor> {
  late final TextEditingController _label;
  late final TextEditingController _script;
  String? _scriptError;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.move.label);
    _script = TextEditingController(text: widget.move.script);
    _script.addListener(_validate);
    _validate();
  }

  @override
  void didUpdateWidget(_SlotEditor old) {
    super.didUpdateWidget(old);
    // Re-sync when the parent swaps the underlying move (e.g. after import).
    if (widget.move.label != _label.text) _label.text = widget.move.label;
    if (widget.move.script != _script.text) _script.text = widget.move.script;
  }

  @override
  void dispose() {
    _label.dispose();
    _script.dispose();
    super.dispose();
  }

  void _validate() {
    final err = ScriptCompiler.validate(_script.text);
    if (err != _scriptError) setState(() => _scriptError = err);
  }

  @override
  Widget build(BuildContext context) {
    final hasError = _scriptError != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 48,
                child: TextFormField(
                  controller: _label,
                  maxLength: 2,
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    counterText: '',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: widget.onLabel,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextFormField(
                  controller: _script,
                  decoration: InputDecoration(
                    border: const OutlineInputBorder(),
                    isDense: true,
                    errorText: hasError ? _scriptError : null,
                    hintText: '例：236+P',
                  ),
                  onChanged: widget.onScript,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 40,
                child: Text('${widget.index + 1}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Visual 3×3 numpad showing how the script digits 1–9 map to the eight
/// cardinal / diagonal directions plus the neutral "5" (which produces
/// a no-direction frame). Rendered inside the "招式槽" card so the user
/// can pick directions at a glance without re-reading the small-print
/// grammar description.
class _DirectionKeyMap extends StatelessWidget {
  const _DirectionKeyMap();

  // 3 rows × 3 columns: each entry is a named record so the type
  // stays self-documenting and the cell builder can pick fields by
  // name. The numpad visual mirrors a phone's dialling pad — 7-8-9
  // on top — which is the convention every KOF / SF tutorial uses.
  static const List<List<({String digit, String arrow})>> _layout = [
    [(digit: '7', arrow: '↖'), (digit: '8', arrow: '↑'), (digit: '9', arrow: '↗')],
    [(digit: '4', arrow: '←'), (digit: '5', arrow: '·'), (digit: '6', arrow: '→')],
    [(digit: '1', arrow: '↙'), (digit: '2', arrow: '↓'), (digit: '3', arrow: '↘')],
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dashboard_customize_outlined,
                  size: 16, color: theme.hintColor),
              const SizedBox(width: 6),
              Text(
                '方向键参考（小键盘布局）',
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (var r = 0; r < _layout.length; r++) ...[
            if (r > 0) const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final cell in _layout[r])
                  _DirKey(digit: cell.digit, arrow: cell.arrow),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Text(
            '数字 5 = 中性（无方向）；连续数字按从左到右的顺序逐段按下。',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}

class _DirKey extends StatelessWidget {
  const _DirKey({required this.digit, required this.arrow});

  final String digit;
  final String arrow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: 56,
      height: 48,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            digit,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              color: theme.hintColor,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            arrow,
            style: theme.textTheme.titleMedium?.copyWith(height: 1.0),
          ),
        ],
      ),
    );
  }
}