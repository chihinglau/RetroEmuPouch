import 'package:flutter/material.dart';

import '../../pal/platform_pal.dart';
import '../../system_files.dart';

/// Shown before launching an arcade game whose libretro core needs a BIOS /
/// system blob the app does not ship (e.g. `neogeo.zip` for NeoGeo on
/// mame/FBA). Instead of letting the core fail with a raw "missing
/// neogeo.zip" overlay, this guides the user to import the file from their
/// own legitimate copy and re-checks until the launch can proceed.
class MissingBiosDialog extends StatefulWidget {
  const MissingBiosDialog({
    super.key,
    required this.pal,
    required this.coreId,
    required this.missing,
    required this.gameTitle,
  });

  final PlatformPal pal;
  final String coreId;
  final Set<String> missing;
  final String gameTitle;

  @override
  State<MissingBiosDialog> createState() => _MissingBiosDialogState();
}

class _MissingBiosDialogState extends State<MissingBiosDialog> {
  late Set<String> _missing;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _missing = {...widget.missing};
  }

  Future<void> _importOne() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // Multi-select SAF picker: the user can drop in every required BIOS
      // (neogeo.zip + qsound.zip + …) in a single round-trip instead of
      // bouncing back and forth through this dialog. The picker accepts
      // both the modern EXTRA_ALLOW_MULTIPLE shape (clipData) and the
      // single-pick fallback some OEM file managers still use.
      final names = await widget.pal.importBiosBatchViaSaf();
      if (names.isEmpty) {
        // User cancelled the picker — keep the dialog open so they can try
        // again or fall back to the settings page's manual import.
        setState(() => _busy = false);
        return;
      }
      // Mirror every newly imported blob into each per-core location
      // (MAME needs <system>/mame/roms) before re-checking.
      await SystemFiles.syncAll(widget.pal);
      // Re-check: importing the right file clears it; a wrong pick leaves
      // it. If everything is now present we close; otherwise the dialog
      // stays open with the remaining list.
      final still = await SystemFiles.missingForCore(widget.pal, widget.coreId);
      setState(() => _missing = still);
      if (still.isEmpty && mounted) {
        Navigator.of(context).pop(true);
      } else {
        setState(() => _busy = false);
      }
    } catch (e) {
      setState(() {
        _busy = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final single = _missing.length == 1;
    return AlertDialog(
      title: const Text('缺少系统文件（BIOS）'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '运行「${widget.gameTitle}」需要以下系统/BIOS 文件。'
              '本应用不内置任何受版权保护的文件（合规要求），请导入你自己的合法备份：',
            ),
            const SizedBox(height: 10),
            ..._missing.map(
              (f) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        size: 18, color: Colors.orange),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(f,
                          style: const TextStyle(fontFamily: 'monospace')),
                    ),
                  ],
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _importOne,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.file_open),
          // One pick, many files: the SAF picker shows checkboxes so the
          // user can drop in neogeo.zip + qsound.zip in one go.
          label: const Text('批量选择'),
        ),
      ],
    );
  }
}
